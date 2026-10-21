import Foundation
import Testing
@testable import BallastCore

@Suite("Setup commands")
struct BundledScriptsTests {

    /// Stands in for the app bundle's Resources directory, with the scripts
    /// the build phase would have copied there.
    private func makeBundle(
        scripts: [String] = ["deploy.sh", "deploy-key.sh"],
        named: String = "ballast-tests"
    ) throws -> URL {
        let base = URL.temporaryDirectory.appending(path: "\(named)-\(UUID().uuidString)")
        let nas = base.appending(path: "nas")
        try FileManager.default.createDirectory(at: nas, withIntermediateDirectories: true)
        for script in scripts {
            try Data("#!/bin/sh\n".utf8).write(to: nas.appending(path: script))
        }
        return base
    }

    private func emptyDirectory() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "ballast-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Installing

    @Test("the scripts are copied out of the bundle, and made runnable")
    func installsScripts() throws {
        let bundle = try makeBundle(scripts: BundledScripts.scripts)
        let destination = try emptyDirectory().appending(path: "nas")

        let result = BundledScripts.install(from: bundle, to: destination)
        #expect(result == destination)

        for script in BundledScripts.scripts {
            let path = destination.appending(path: script).path
            #expect(FileManager.default.fileExists(atPath: path))
            let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            #expect(mode?.int16Value == 0o755)
        }
    }

    /// It runs at every launch, so a second pass over an existing install has
    /// to replace rather than fail.
    @Test("installing twice replaces the previous copy")
    func installIsIdempotent() throws {
        let bundle = try makeBundle(scripts: ["deploy.sh"])
        let destination = try emptyDirectory().appending(path: "nas")

        #expect(BundledScripts.install(from: bundle, to: destination) == destination)
        #expect(BundledScripts.install(from: bundle, to: destination) == destination)
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "deploy.sh").path))
    }

    @Test("a build with no bundled scripts installs nothing and says so")
    func installWithoutResources() {
        #expect(BundledScripts.install(from: nil, to: URL.temporaryDirectory) == nil)
    }

    // MARK: Resolving

    @Test("the installed copy is preferred over the one in the bundle")
    func prefersInstalledCopy() throws {
        let bundle = try makeBundle()
        let installed = try emptyDirectory()
        try Data().write(to: installed.appending(path: "deploy.sh"))

        let path = BundledScripts.path(for: "deploy.sh", installed: installed, inBundle: bundle)
        #expect(path == installed.appending(path: "deploy.sh").path)
    }

    /// The bundle is the fallback for the window between first launch and a
    /// successful install — and for when the install fails outright.
    @Test("the bundle is used when nothing has been installed")
    func fallsBackToBundle() throws {
        let bundle = try makeBundle()
        let path = BundledScripts.path(for: "deploy.sh", installed: nil, inBundle: bundle)
        #expect(path == bundle.appending(path: "nas").appending(path: "deploy.sh").path)
    }

    @Test("a script in neither place resolves to nothing")
    func missingScript() throws {
        let bundle = try makeBundle(scripts: [])
        #expect(BundledScripts.path(for: "deploy.sh", installed: nil, inBundle: bundle) == nil)
        #expect(BundledScripts.path(for: "deploy.sh", installed: nil, inBundle: nil) == nil)
    }

    // MARK: Commands

    @Test("the destination the user typed is what the commands carry")
    func destinationSubstituted() throws {
        let bundle = try makeBundle()
        let command = BundledScripts.command(
            .installAgent, destination: "me@nas.local", installed: nil, resourceURL: bundle
        )
        #expect(command.hasSuffix("'me@nas.local'"))
        #expect(command.contains("nas/deploy.sh"))
    }

    @Test("an empty destination still produces a readable example")
    func emptyDestinationFallsBack() throws {
        let bundle = try makeBundle()
        let command = BundledScripts.command(
            .installAgent, destination: "   ", installed: nil, resourceURL: bundle
        )
        #expect(command.contains(BundledScripts.placeholderDestination))
    }

    @Test("surrounding whitespace doesn't travel into the command")
    func destinationTrimmed() throws {
        let bundle = try makeBundle()
        let command = BundledScripts.command(
            .verify, destination: "  me@nas  ", installed: nil, resourceURL: bundle
        )
        #expect(command.contains("'me@nas'"))
    }

    @Test("the verify command checks the agent path the app actually uses")
    func verifyUsesAgentPath() throws {
        let bundle = try makeBundle()
        let command = BundledScripts.command(
            .verify, destination: "me@nas", installed: nil, resourceURL: bundle
        )
        #expect(command.contains("sudo -n \(SSHContainerSource.defaultAgentPath) check"))
    }

    @Test("the key is made without a passphrase, since nothing can type one")
    func keygenIsUnattended() {
        let command = BundledScripts.command(.keygen, destination: "me@nas", installed: nil, resourceURL: nil)
        #expect(command.contains("-t ed25519"))
        #expect(command.contains("~/.ssh/id_ballast"))
    }

    @Test("commands still read correctly when nothing is installed or bundled")
    func fallsBackWithoutResources() {
        let command = BundledScripts.command(
            .installAgent, destination: "me@nas", installed: nil, resourceURL: nil
        )
        #expect(command.contains("Ballast.app/Contents/Resources/nas/deploy.sh"))
        #expect(command.hasSuffix("'me@nas'"))
    }

    // MARK: Quoting

    /// A Debug build lives under a DerivedData path, and an app can be
    /// dragged anywhere; an unquoted path with a space in it would silently
    /// become two arguments.
    @Test("a path with a space in it survives the trip through a shell")
    func quotesSpaces() throws {
        let bundle = try makeBundle(named: "ballast tests with spaces")
        let command = BundledScripts.command(
            .installAgent, destination: "me@nas", installed: nil, resourceURL: bundle
        )
        #expect(command.hasPrefix("'"))
        #expect(command.contains("ballast tests with spaces"))
        // The quoted path must be one argument: no bare space outside quotes.
        #expect(command.split(separator: "'").count == 3)
    }

    @Test("a quote in the destination can't break out of its quoting")
    func quotesEmbeddedQuote() throws {
        let bundle = try makeBundle()
        let command = BundledScripts.command(
            .verify, destination: "me'@nas", installed: nil, resourceURL: bundle
        )
        #expect(command.contains(#"'me'\''@nas'"#))
    }

    @Test("a path under the home directory is written against $HOME")
    func shortensHomePaths() {
        let shortened = BundledScripts.shellPath(
            "/Users/someone/Library/Application Support/Ballast/nas/deploy.sh",
            home: "/Users/someone"
        )
        #expect(shortened == #""$HOME/Library/Application Support/Ballast/nas/deploy.sh""#)
    }

    @Test("a path outside the home directory is quoted whole")
    func leavesOtherPathsAlone() {
        let path = BundledScripts.shellPath("/Applications/Ballast.app/x.sh", home: "/Users/someone")
        #expect(path == "'/Applications/Ballast.app/x.sh'")
    }

    /// `$HOME` only expands inside double quotes, which expand other things
    /// too — so a path that contains any of them has to go back to the
    /// literal form.
    @Test("a path a double-quoted string would mangle stays single-quoted")
    func refusesUnsafeHomePaths() {
        let path = BundledScripts.shellPath("/Users/someone/we$rd/x.sh", home: "/Users/someone")
        #expect(path == "'/Users/someone/we$rd/x.sh'")
    }

    @Test("a home path that only prefixes the real one isn't shortened")
    func doesNotMatchPartialHome() {
        let path = BundledScripts.shellPath("/Users/someone-else/x.sh", home: "/Users/someone")
        #expect(path == "'/Users/someone-else/x.sh'")
    }
}
