import Foundation
import Testing
@testable import BallastCore

@Suite("Image references")
struct ImageReferenceTests {

    @Test("a bare name is a Docker Hub official image")
    func officialImage() throws {
        let reference = try #require(ImageReference("redis:7"))
        #expect(reference.registry == "registry-1.docker.io")
        #expect(reference.repository == "library/redis")
        #expect(reference.tag == "7")
        #expect(reference.webURL?.absoluteString == "https://hub.docker.com/_/redis/tags")
    }

    @Test("no tag means latest")
    func defaultTag() throws {
        let reference = try #require(ImageReference("linuxserver/sonarr"))
        #expect(reference.tag == "latest")
        #expect(reference.repository == "linuxserver/sonarr")
        #expect(reference.isDockerHub)
    }

    @Test("docker.io spellings all mean Docker Hub")
    func hubAliases() throws {
        for image in ["docker.io/linuxserver/sonarr:latest", "index.docker.io/linuxserver/sonarr:latest"] {
            let reference = try #require(ImageReference(image))
            #expect(reference.registry == "registry-1.docker.io")
            #expect(reference.repository == "linuxserver/sonarr")
        }
        #expect(ImageReference("docker.io/nginx")?.repository == "library/nginx")
    }

    @Test("LinuxServer images link to Docker Hub whichever registry they came from")
    func linuxServerLinksToHub() throws {
        for image in ["lscr.io/linuxserver/sonarr:latest", "ghcr.io/linuxserver/sonarr", "linuxserver/sonarr"] {
            let reference = try #require(ImageReference(image))
            #expect(reference.isLinuxServer)
            #expect(reference.hubRepository == "linuxserver/sonarr")
            #expect(reference.webURL?.absoluteString == "https://hub.docker.com/r/linuxserver/sonarr/tags")
            #expect(reference.webSiteName == "Docker Hub")
        }
        #expect(ImageReference("lscr.io/linuxserver/sonarr:develop")?.registry == "lscr.io")
    }

    @Test("other ghcr.io images link to their GitHub package")
    func ghcrLinksToGitHub() throws {
        let reference = try #require(ImageReference("ghcr.io/immich-app/immich-server:release"))
        #expect(!reference.isLinuxServer)
        #expect(reference.hubRepository == nil)
        #expect(reference.repository == "immich-app/immich-server")
        #expect(reference.tag == "release")
        #expect(reference.webURL?.absoluteString == "https://ghcr.io/immich-app/immich-server")
    }

    @Test("a registry port is not mistaken for a tag")
    func registryPort() throws {
        let reference = try #require(ImageReference("registry:5000/team/app:1.2"))
        #expect(reference.registry == "registry:5000")
        #expect(reference.repository == "team/app")
        #expect(reference.tag == "1.2")
        #expect(reference.webURL == nil)

        #expect(ImageReference("registry:5000/app")?.tag == "latest")
    }

    @Test("a digest pin can't move, so there's nothing to check")
    func digestPin() {
        #expect(ImageReference("nginx@sha256:abc") == nil)
        #expect(ImageReference("nginx:1.27@sha256:abc") == nil)
        #expect(ImageReference("") == nil)
    }
}

@Suite("Image update status")
struct ImageUpdateResolverTests {

    private let remote = RemoteImage(digest: "sha256:new", versionTag: "4.0.20.3014-ls1")

    @Test("the digest running is the digest published")
    func upToDate() {
        let status = ImageUpdateResolver.status(
            localDigests: ["sha256:old", "sha256:new"],
            remote: remote,
            runningVersion: "4.0.20.3014-ls1"
        )
        #expect(status == .upToDate)
        #expect(!status.isUpdate)
    }

    @Test("a new app release is an update")
    func newVersion() {
        let status = ImageUpdateResolver.status(
            localDigests: ["sha256:old"], remote: remote, runningVersion: "4.0.19.2979-ls300"
        )
        #expect(status == .newVersion(running: "4.0.19.2979-ls300", available: "4.0.20.3014-ls1"))
        #expect(status.isUpdate)
        #expect(status.summary == "Version 4.0.20.3014 available — running 4.0.19.2979")
    }

    @Test("a LinuxServer rebuild of the same release isn't an update")
    func rebuild() {
        let status = ImageUpdateResolver.status(
            localDigests: ["sha256:old"],
            remote: RemoteImage(digest: "sha256:new", versionTag: "4.0.20.3014-ls2"),
            runningVersion: "4.0.20.3014-ls1"
        )
        #expect(status == .rebuild(available: "4.0.20.3014-ls2"))
        #expect(!status.isUpdate)
    }

    @Test("a changed image with no version to name is still an update")
    func unnamedImage() {
        let status = ImageUpdateResolver.status(
            localDigests: ["sha256:old"],
            remote: RemoteImage(digest: "sha256:new", versionTag: nil),
            runningVersion: "1.32.0"
        )
        #expect(status == .newImage)
        #expect(status.isUpdate)
    }

    @Test("an unknown running version can't hide a release")
    func unknownRunningVersion() {
        let status = ImageUpdateResolver.status(localDigests: ["sha256:old"], remote: remote, runningVersion: nil)
        #expect(status == .newVersion(running: nil, available: "4.0.20.3014-ls1"))
        #expect(status.summary == "Version 4.0.20.3014 available")
    }

    @Test("an image with no registry digest can't be compared")
    func builtLocally() {
        let status = ImageUpdateResolver.status(localDigests: [], remote: remote, runningVersion: nil)
        guard case .unavailable = status else {
            Issue.record("expected unavailable, got \(status)")
            return
        }
    }

    @Test("packaging is stripped before versions are compared")
    func appVersion() {
        #expect(ImageUpdateResolver.appVersion("4.0.20.3014-ls1") == "4.0.20.3014")
        #expect(ImageUpdateResolver.appVersion("version-4.0.20.3014") == "4.0.20.3014")
        #expect(ImageUpdateResolver.appVersion("develop-5.0.0.2742-ls200") == "5.0.0.2742")
        #expect(ImageUpdateResolver.appVersion("v1.32.0") == "1.32.0")
        #expect(ImageUpdateResolver.appVersion("pg14-v0.2.0") == "pg14-v0.2.0")
    }

    @Test("the LinuxServer build tag names a digest, not the arch or channel tags")
    func picksLinuxServerTag() {
        // The shape of Docker Hub's tag list for linuxserver/sonarr.
        let tags: [(name: String, digest: String?)] = [
            ("amd64-4.0.20.3014-ls1", "sha256:amd64"),
            ("4.0.20", "sha256:index"),
            ("version-4.0.20.3014", "sha256:index"),
            ("4.0.20.3014-ls1", "sha256:index"),
            ("latest", "sha256:index"),
            ("4.0.19.2979-ls300", "sha256:older"),
            ("develop", "sha256:develop"),
        ]
        #expect(ImageUpdateResolver.versionTag(among: tags, matching: "sha256:index") == "4.0.20.3014-ls1")
        #expect(ImageUpdateResolver.versionTag(among: tags, matching: "sha256:develop") == nil)
        #expect(ImageUpdateResolver.versionTag(among: tags, matching: "sha256:missing") == nil)
    }

    @Test("without build tags, the most specific version wins")
    func picksMostSpecific() {
        let tags: [(name: String, digest: String?)] = [
            ("1", "sha256:a"), ("1.27", "sha256:a"), ("1.27.2", "sha256:a"),
            ("mainline", "sha256:a"), ("latest", "sha256:a"), ("arm64v8-1.27.2", "sha256:a"),
            ("1.27.2-bookworm", "sha256:a"),
        ]
        #expect(ImageUpdateResolver.versionTag(among: tags, matching: "sha256:a") == "1.27.2")
    }

    @Test("the running version comes from the image's labels before its tag")
    func runningVersion() {
        var container = makeContainer("sonarr")
        container.image = "lscr.io/linuxserver/sonarr:latest"
        #expect(container.runningImageVersion == nil)

        container.labels["build_version"] = "Linuxserver.io version:- 4.0.20.3014-ls1 Build-date:- 2026-10-20T19:02:49+00:00"
        #expect(container.runningImageVersion == "4.0.20.3014-ls1")

        container.labels["org.opencontainers.image.version"] = "4.0.20.3014-ls2"
        #expect(container.runningImageVersion == "4.0.20.3014-ls2")

        var pinned = makeContainer("jellyfin")
        pinned.image = "jellyfin/jellyfin:10.9.11"
        #expect(pinned.runningImageVersion == "10.9.11")
    }

    @Test("a registry's auth challenge is read into its parts")
    func challenge() {
        let parameters = RegistryClient.challengeParameters(
            #"Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:linuxserver/sonarr:pull""#
        )
        #expect(parameters["realm"] == "https://ghcr.io/token")
        #expect(parameters["service"] == "ghcr.io")
        #expect(parameters["scope"] == "repository:linuxserver/sonarr:pull")
        #expect(RegistryClient.challengeParameters(#"Basic realm="x""#).isEmpty)
    }
}

@Suite("Agent images output")
struct AgentImagesParserTests {

    private let sample = """
    #ballast 1
    "container"\t"c1"\t"sha256:img1"
    "container"\t"c2"\t"sha256:img2"
    "container"\t"c3"\t"sha256:img1"
    "container"\t"c4"\t"sha256:gone"
    "image"\t"sha256:img1"\t["linuxserver/sonarr@sha256:aaa","lscr.io/linuxserver/sonarr@sha256:aaa"]
    "image"\t"sha256:img2"\tnull
    #end 6
    """

    @Test("joins each container to its image's digests")
    func joins() throws {
        let images = try AgentOutputParser.parseImages(sample)
        #expect(images["c1"] == ContainerImage(imageID: "sha256:img1", digests: ["sha256:aaa"]))
        #expect(images["c3"]?.digests == ["sha256:aaa"])
        // A locally built image has no RepoDigests at all.
        #expect(images["c2"] == ContainerImage(imageID: "sha256:img2", digests: []))
        // An image that couldn't be inspected leaves its container out.
        #expect(images["c4"] == nil)
    }

    @Test("checks the same header and terminator as the list")
    func framing() {
        #expect(throws: AgentParseError.missingHeader) {
            try AgentOutputParser.parseImages("\"container\"\t\"c1\"\t\"sha256:img1\"\n#end 1")
        }
        #expect(throws: AgentParseError.truncated(declared: 3, received: 1)) {
            try AgentOutputParser.parseImages("#ballast 1\n\"container\"\t\"c1\"\t\"sha256:img1\"\n#end 3")
        }
        #expect(throws: AgentParseError.missingTerminator) {
            try AgentOutputParser.parseImages("#ballast 1\n\"container\"\t\"c1\"\t\"sha256:img1\"")
        }
    }

    @Test("an empty NAS has no images")
    func empty() throws {
        #expect(try AgentOutputParser.parseImages("#ballast 1\n#end 0").isEmpty)
    }
}

/// Container images whose id follows their digests, so a different digest
/// is also a different image.
func stubImages(_ digests: [String: [String]]) -> [String: ContainerImage] {
    digests.mapValues { ContainerImage(imageID: "image:" + $0.joined(separator: ","), digests: $0) }
}

/// Answers from a table, and counts how often it was asked.
final class StubRegistry: ImageRegistry, @unchecked Sendable {
    var digests: [String: String] = [:]
    var versionTags: [String: String] = [:]
    var failure: RegistryError?
    private(set) var digestCalls = 0
    private(set) var versionCalls = 0

    func digest(for reference: ImageReference) async throws(RegistryError) -> String {
        digestCalls += 1
        if let failure { throw failure }
        guard let digest = digests[reference.repository] else { throw .notFound }
        return digest
    }

    func versionTag(for reference: ImageReference, digest: String) async -> String? {
        versionCalls += 1
        return versionTags[reference.repository]
    }
}

@MainActor
@Suite("Update checks")
struct UpdateCheckTests {

    private func makeStore(
        _ containers: [Container],
        images: [String: [String]]
    ) -> (ContainerStore, StubSource, StubRegistry, AppSettings) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "ballast-tests-\(UUID().uuidString)")!)
        settings.sshDestination = "test@nas"
        let source = StubSource(containers: containers)
        source.imagesResult = .success(stubImages(images))
        let registry = StubRegistry()
        let store = ContainerStore(settings: settings, registry: registry) { _ in source }
        return (store, source, registry, settings)
    }

    private func sonarr(id: String = "sonarr", version: String = "4.0.19.2979-ls300") -> Container {
        var container = makeContainer("sonarr", id: id, labels: ["org.opencontainers.image.version": version])
        container.image = "lscr.io/linuxserver/sonarr:latest"
        return container
    }

    @Test("a refresh checks images, and names the release")
    func refreshChecks() async {
        let (store, _, registry, _) = makeStore([sonarr()], images: ["sonarr": ["sha256:old"]])
        registry.digests["linuxserver/sonarr"] = "sha256:new"
        registry.versionTags["linuxserver/sonarr"] = "4.0.20.3014-ls1"

        await store.refresh()
        await store.updateCheckTask?.value

        #expect(store.imageUpdates["sonarr"] == .newVersion(running: "4.0.19.2979-ls300", available: "4.0.20.3014-ls1"))
        #expect(store.availableUpdateCount == 1)
        #expect(store.lastUpdateCheck != nil)
    }

    @Test("an image already running isn't looked up by version")
    func noVersionLookupWhenCurrent() async {
        let (store, _, registry, _) = makeStore([sonarr()], images: ["sonarr": ["sha256:new"]])
        registry.digests["linuxserver/sonarr"] = "sha256:new"

        await store.refresh()
        await store.updateCheckTask?.value

        #expect(store.imageUpdates["sonarr"] == .upToDate)
        #expect(registry.versionCalls == 0)
    }

    @Test("containers sharing an image ask the registry once")
    func sharedImages() async {
        let (store, _, registry, _) = makeStore(
            [sonarr(id: "a"), sonarr(id: "b")],
            images: ["a": ["sha256:new"], "b": ["sha256:new"]]
        )
        registry.digests["linuxserver/sonarr"] = "sha256:new"

        await store.refresh()
        await store.updateCheckTask?.value

        #expect(registry.digestCalls == 1)
    }

    @Test("a container recreated onto the new image clears without asking again")
    func recreationRechecksLocally() async {
        let (store, source, registry, _) = makeStore([sonarr()], images: ["sonarr": ["sha256:old"]])
        registry.digests["linuxserver/sonarr"] = "sha256:new"
        await store.refresh()
        await store.updateCheckTask?.value
        #expect(store.imageUpdates["sonarr"]?.isUpdate == true)
        let asked = registry.digestCalls

        // What Watchtower leaves behind: same name, new id, new image.
        source.result = .success(AgentListOutput(protocolVersion: 1, containers: [sonarr(id: "sonarr-2")]))
        source.imagesResult = .success(stubImages(["sonarr-2": ["sha256:new"]]))
        await store.refresh()
        await store.updateCheckTask?.value

        #expect(store.imageUpdates["sonarr-2"] == .upToDate)
        #expect(store.imageUpdates["sonarr"] == nil)
        #expect(registry.digestCalls == asked)
    }

    @Test("an agent too old for images asks to be redeployed, and the list still works")
    func outdatedAgent() async {
        let (store, source, _, _) = makeStore([sonarr()], images: [:])
        source.imagesResult = .failure(.agentOutdated)

        await store.refresh()
        await store.updateCheckTask?.value

        #expect(store.updateCheckError == .agentOutdated)
        #expect(store.lastError == nil)
        #expect(store.containers.count == 1)
    }

    @Test("opted-out, pinned and locally built images get no icon")
    func exclusions() async {
        var optedOut = makeContainer("private", labels: ["ballast.updates": "false"])
        optedOut.image = "linuxserver/sonarr:latest"
        var pinned = makeContainer("pinned")
        pinned.image = "nginx@sha256:abc"
        let local = makeContainer("homemade")

        let (store, _, registry, _) = makeStore(
            [optedOut, pinned, local],
            images: ["private": ["sha256:old"], "pinned": ["sha256:abc"], "homemade": []]
        )
        registry.digests["linuxserver/sonarr"] = "sha256:new"

        await store.refresh()
        await store.updateCheckTask?.value

        #expect(store.imageUpdates["private"] == nil)
        #expect(store.imageUpdates["pinned"]?.isUpdate == false)
        #expect(store.imageUpdates["homemade"]?.isUpdate == false)
        #expect(registry.digestCalls == 0)
    }

    @Test("turning checks off hides what was found")
    func disabling() async {
        let (store, _, registry, settings) = makeStore([sonarr()], images: ["sonarr": ["sha256:old"]])
        registry.digests["linuxserver/sonarr"] = "sha256:new"
        await store.refresh()
        await store.updateCheckTask?.value
        #expect(store.availableUpdateCount == 1)

        settings.imageUpdateChecksEnabled = false
        #expect(store.availableUpdateCount == 0)
        #expect(store.updateStatus(for: sonarr()) == nil)
    }

    @Test("a registry that can't be reached shows why, not an update")
    func registryFailure() async {
        let (store, _, registry, _) = makeStore([sonarr()], images: ["sonarr": ["sha256:old"]])
        registry.failure = .network("offline")

        await store.refresh()
        await store.updateCheckTask?.value

        #expect(store.imageUpdates["sonarr"] == .unavailable(reason: "offline"))
    }
}

@MainActor
@Suite("Update history")
struct UpdateHistoryTests {

    private func sonarr(id: String, version: String) -> Container {
        var container = makeContainer("sonarr", id: id, labels: ["org.opencontainers.image.version": version])
        container.image = "lscr.io/linuxserver/sonarr:latest"
        container.startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        return container
    }

    private func makeStore(updateChecks: Bool = true) -> (ContainerStore, StubSource) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "ballast-tests-\(UUID().uuidString)")!)
        settings.sshDestination = "test@nas"
        settings.imageUpdateChecksEnabled = updateChecks
        let source = StubSource(containers: [sonarr(id: "a", version: "4.0.19.2979-ls300")])
        source.imagesResult = .success(["a": ContainerImage(imageID: "sha256:old", digests: ["sha256:d1"])])
        let store = ContainerStore(settings: settings, registry: StubRegistry()) { _ in source }
        return (store, source)
    }

    /// What Watchtower leaves behind: same name, new id, new image.
    private func recreate(_ source: StubSource, imageID: String, version: String) {
        source.result = .success(AgentListOutput(protocolVersion: 1, containers: [sonarr(id: "b", version: version)]))
        source.imagesResult = .success(["b": ContainerImage(imageID: imageID, digests: ["sha256:d2"])])
    }

    private func poll(_ store: ContainerStore) async {
        await store.refresh()
        await store.updateCheckTask?.value
    }

    @Test("a container recreated onto a new image is logged as updated")
    func logsUpdate() async throws {
        let (store, source) = makeStore()
        await poll(store)
        #expect(store.history.isEmpty, "the first look has nothing to compare with")

        recreate(source, imageID: "sha256:new", version: "4.0.20.3014-ls1")
        await poll(store)

        let event = try #require(store.history.last)
        #expect(event.kind == .updated)
        #expect(event.containerName == "sonarr")
        #expect(event.fromVersion == "4.0.19.2979-ls300")
        #expect(event.toVersion == "4.0.20.3014-ls1")
        #expect(event.at == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(event.summary == "Updated 4.0.19.2979 → 4.0.20.3014")
        #expect(!event.isNotifiable)
        #expect(store.lastExit(for: "sonarr") == nil, "an update isn't an exit")
    }

    @Test("recreated on the same image is not an update")
    func sameImage() async {
        let (store, source) = makeStore()
        await poll(store)

        recreate(source, imageID: "sha256:old", version: "4.0.19.2979-ls300")
        await poll(store)

        #expect(store.history.isEmpty)
    }

    @Test("updates are logged with update checks turned off")
    func loggedWithoutChecks() async {
        let (store, source) = makeStore(updateChecks: false)
        await poll(store)

        recreate(source, imageID: "sha256:new", version: "4.0.20.3014-ls1")
        await poll(store)

        #expect(store.history.map(\.kind) == [.updated])
        #expect(store.imageUpdates.isEmpty)
    }

    @Test("an update is worded by what changed")
    func wording() {
        func summary(_ from: String?, _ to: String?) -> String {
            DowntimeEvent(containerName: "x", kind: .updated, at: Date(), fromVersion: from, toVersion: to).summary
        }
        #expect(summary("4.0.20.3014-ls1", "4.0.20.3014-ls2") == "Updated to a new build of 4.0.20.3014")
        #expect(summary(nil, "1.37.4") == "Updated to 1.37.4")
        #expect(summary("1.37.3", nil) == "Updated to a new image")
        #expect(summary(nil, nil) == "Updated to a new image")
    }

    @Test("an update between an exit and a start doesn't break the downtime pairing")
    func downtimePairing() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let exit = DowntimeEvent(containerName: "a", kind: .exited, at: base, exitCode: 0)
        let update = DowntimeEvent(containerName: "a", kind: .updated, at: base + 30)
        let start = DowntimeEvent(containerName: "a", kind: .started, at: base + 60)
        #expect(DowntimeEvent.downtimes(in: [exit, update, start])[exit.id] == 60)
    }
}
