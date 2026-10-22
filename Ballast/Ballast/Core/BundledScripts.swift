import Foundation

/// The setup commands onboarding hands over, built against copies of the
/// `nas/` scripts installed alongside the app's other data.
///
/// A copy button is only worth having if what it copies runs. Pointing at
/// `./nas/deploy.sh` assumes a repo checkout and a particular working
/// directory; pointing into the app bundle assumes the bundle stays where it
/// is, which it doesn't — a downloaded app runs translocated from a random
/// read-only path until it's moved to Applications, and the path a user
/// copied yesterday is gone today.
///
/// So the scripts are copied out to Application Support once at launch, and
/// the commands name that stable location. It also reads as something a
/// person can understand, which `…/DerivedData/Ballast-hghimpblia…` does not.
enum BundledScripts {
    /// Shown in a command when the user hasn't given a destination yet, so the
    /// line still reads as a complete example.
    ///
    /// An IP rather than a hostname: it teaches the `account@address` shape
    /// without anyone having to wonder whether `nas.local` is a literal they
    /// are supposed to already have.
    static let placeholderDestination = "\(placeholderUser)@\(placeholderHost)"
    /// The two halves, for setup, which asks for them separately. The user is
    /// also the name setup asks for the DSM account to be given, so the field
    /// can start filled in rather than as an example.
    static let placeholderUser = "ballast-user"
    static let placeholderHost = "192.168.1.10"

    /// Everything `nas/` needs to work: `deploy.sh` and `deploy-key.sh` stream
    /// their siblings over the connection, so the directory only works whole.
    static let scripts = ["ballast-agent", "install.sh", "install-key.sh", "deploy.sh", "deploy-key.sh"]

    enum SetupStep {
        case keygen, deployKey, installAgent, verify
    }

    static func defaultInstallDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Ballast", directoryHint: .isDirectory)
            .appending(path: "nas", directoryHint: .isDirectory)
    }

    /// Copies the bundled scripts somewhere they'll still be tomorrow.
    ///
    /// Idempotent and cheap — a few tens of kilobytes — so it simply runs at
    /// every launch, which also means an app update replaces the scripts
    /// rather than leaving a stale pair behind.
    @discardableResult
    static func install(
        from resources: URL? = Bundle.main.resourceURL,
        to directory: URL = defaultInstallDirectory()
    ) -> URL? {
        guard let source = resources?.appending(path: "nas", directoryHint: .isDirectory) else { return nil }

        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            for script in scripts {
                let from = source.appending(path: script)
                guard manager.fileExists(atPath: from.path) else { continue }

                let to = directory.appending(path: script)
                if manager.fileExists(atPath: to.path) {
                    try manager.removeItem(at: to)
                }
                try manager.copyItem(at: from, to: to)
                // The bundle's copy is read-only when the app is; these have
                // to be runnable.
                try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: to.path)
            }
        } catch {
            // The commands fall back to the bundle path, which still works
            // for as long as the app stays put.
            return nil
        }
        return directory
    }

    /// Absolute path to one of the scripts — the installed copy for choice,
    /// the bundle's otherwise — or nil if neither is there.
    static func path(
        for script: String,
        installed: URL? = defaultInstallDirectory(),
        inBundle resources: URL? = Bundle.main.resourceURL
    ) -> String? {
        let candidates = [
            installed?.appending(path: script),
            resources?.appending(path: "nas", directoryHint: .isDirectory).appending(path: script),
        ]
        return candidates
            .compactMap(\.self)
            .first { FileManager.default.fileExists(atPath: $0.path) }?
            .path
    }

    static func command(
        _ step: SetupStep,
        destination: String,
        installed: URL? = defaultInstallDirectory(),
        resourceURL: URL? = Bundle.main.resourceURL
    ) -> String {
        let target = resolved(destination)

        switch step {
        case .keygen:
            // No passphrase, and that is deliberate: Ballast polls unattended
            // and has no way to answer a prompt.
            return #"ssh-keygen -t ed25519 -f ~/.ssh/id_ballast -C "ballast""#
        case .deployKey:
            return "\(script("deploy-key.sh", installed, resourceURL)) \(shellQuoted(target)) ~/.ssh/id_ballast.pub"
        case .installAgent:
            return "\(script("deploy.sh", installed, resourceURL)) \(shellQuoted(target))"
        case .verify:
            // The same check the app itself makes, with the key setup made —
            // which ssh wouldn't offer unprompted.
            return "ssh -i \(SSHContainerSource.setupKeyPath) \(shellQuoted(target)) sudo -n \(SSHContainerSource.defaultAgentPath) check"
        }
    }

    /// Safe to paste into a shell: single quotes stop everything, and an
    /// embedded quote is closed, escaped and reopened.
    static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// A path for a human to read as well as a shell to run: anything under
    /// the home directory is written against `$HOME`, which keeps the line
    /// short and makes it portable between accounts.
    static func shellPath(
        _ path: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        guard !home.isEmpty, path.hasPrefix(home + "/") else { return shellQuoted(path) }

        let remainder = String(path.dropFirst(home.count))
        // Double quotes are what let `$HOME` expand, so the rest of the path
        // has to be free of everything else a double-quoted string expands.
        guard !remainder.contains(where: { #"$`\""#.contains($0) }) else { return shellQuoted(path) }
        return "\"$HOME\(remainder)\""
    }

    /// Falls back to where the script *would* be, so the command is still
    /// readable and copyable from a build where the resources are missing.
    private static func script(_ name: String, _ installed: URL?, _ resources: URL?) -> String {
        guard let found = path(for: name, installed: installed, inBundle: resources) else {
            return shellQuoted("/Applications/Ballast.app/Contents/Resources/nas/\(name)")
        }
        return shellPath(found)
    }

    private static func resolved(_ destination: String) -> String {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? placeholderDestination : trimmed
    }
}
