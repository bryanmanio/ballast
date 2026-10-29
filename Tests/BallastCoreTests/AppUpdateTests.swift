import Foundation
import Testing
@testable import BallastCore

@Suite("App versions")
struct AppVersionTests {

    @Test("release tags and bundle versions both parse")
    func parsing() throws {
        #expect(try #require(AppVersion("v1.2")).components == [1, 2])
        #expect(try #require(AppVersion("1.1.1")).components == [1, 1, 1])
        #expect(try #require(AppVersion(" 2 ")).components == [2])
        #expect(AppVersion("") == nil)
        #expect(AppVersion("v") == nil)
        #expect(AppVersion("1.2-beta") == nil)
        #expect(AppVersion("1..2") == nil)
    }

    @Test("versions compare numerically, with missing parts as zero")
    func ordering() throws {
        let v = { (text: String) in AppVersion(text)! }
        #expect(v("1.1.1") < v("1.2"))
        #expect(v("1.10") > v("1.9"))
        #expect(v("1.2") == v("1.2.0"))
        #expect(!(v("1.2") < v("1.2.0")))
        #expect(v("2") > v("1.99.99"))
        #expect(v("v1.2").description == "1.2")
    }
}

@Suite("GitHub release decoding")
struct GitHubReleaseDecodingTests {

    @Test("reads the tag, name, page and date from releases/latest")
    func decodesLatest() throws {
        let json = """
        {
          "url": "https://api.github.com/repos/bryanmanio/ballast/releases/1",
          "html_url": "https://github.com/bryanmanio/ballast/releases/tag/v1.2",
          "tag_name": "v1.2",
          "name": "Ballast 1.2",
          "draft": false,
          "prerelease": false,
          "published_at": "2026-10-22T21:08:24Z",
          "assets": []
        }
        """
        let release = try GitHubReleaseChecker.decode(Data(json.utf8))
        #expect(release.version == AppVersion("1.2"))
        #expect(release.name == "Ballast 1.2")
        #expect(release.pageURL.absoluteString == "https://github.com/bryanmanio/ballast/releases/tag/v1.2")
        #expect(release.publishedAt != nil)
    }

    @Test("a tag that isn't a version is an error, not a release")
    func rejectsOddTags() {
        let json = #"{"html_url": "https://example.com", "tag_name": "nightly"}"#
        #expect(throws: AppUpdateError.unreadable) {
            try GitHubReleaseChecker.decode(Data(json.utf8))
        }
    }
}

// MARK: - Updater

private struct StubChecker: AppUpdateChecking {
    var result: Result<AppRelease, AppUpdateError>
    func latestRelease() async throws(AppUpdateError) -> AppRelease { try result.get() }
}

private final class RecordingNotifier: ExitNotifying, @unchecked Sendable {
    var authorization: NotificationAuthorization = .authorized
    private(set) var updates: [AppRelease] = []
    func authorizationStatus() async -> NotificationAuthorization { authorization }
    func requestAuthorization() async -> Bool { true }
    func post(_ events: [DowntimeEvent]) async {}
    func post(appUpdate release: AppRelease) async { updates.append(release) }
}

private func release(_ version: String) -> AppRelease {
    AppRelease(
        version: AppVersion(version)!,
        name: "Ballast \(version)",
        pageURL: URL(string: "https://github.com/bryanmanio/ballast/releases/tag/v\(version)")!,
        publishedAt: nil
    )
}

@MainActor
private func makeSettings() -> AppSettings {
    AppSettings(defaults: UserDefaults(suiteName: "AppUpdateTests-\(UUID().uuidString)")!)
}

@MainActor
@Suite("App updater")
struct AppUpdaterTests {

    @Test("a newer release is an update and notifies once")
    func notifiesOnce() async {
        let settings = makeSettings()
        let notifier = RecordingNotifier()
        let updater = AppUpdater(
            settings: settings,
            checker: StubChecker(result: .success(release("1.3"))),
            notifier: notifier,
            currentVersion: "1.2",
            currentBuild: "4"
        )
        await updater.checkIfDue()
        #expect(updater.availableUpdate?.version == AppVersion("1.3"))
        #expect(updater.showsBanner)
        #expect(updater.lastChecked != nil)
        #expect(notifier.updates.count == 1)
        #expect(settings.lastNotifiedAppVersion == "1.3")

        // Due again a day later, and still the same release.
        await updater.checkIfDue(now: Date().addingTimeInterval(AppUpdater.checkInterval + 1))
        #expect(notifier.updates.count == 1)
    }

    @Test("the same or an older release is not an update")
    func notNewer() async {
        for latest in ["1.2", "1.2.0", "1.1.1"] {
            let notifier = RecordingNotifier()
            let updater = AppUpdater(
                settings: makeSettings(),
                checker: StubChecker(result: .success(release(latest))),
                notifier: notifier,
                currentVersion: "1.2"
            )
            await updater.checkIfDue()
            #expect(updater.availableUpdate == nil)
            #expect(!updater.showsBanner)
            #expect(notifier.updates.isEmpty)
        }
    }

    @Test("without notification permission nothing is posted, or marked as told")
    func unauthorized() async {
        let settings = makeSettings()
        let notifier = RecordingNotifier()
        notifier.authorization = .notDetermined
        let updater = AppUpdater(
            settings: settings,
            checker: StubChecker(result: .success(release("1.3"))),
            notifier: notifier,
            currentVersion: "1.2"
        )
        await updater.checkIfDue()
        #expect(updater.availableUpdate != nil)
        #expect(notifier.updates.isEmpty)
        #expect(settings.lastNotifiedAppVersion == nil)
    }

    @Test("automatic checks can be turned off; Check Now still works and doesn't notify")
    func manualCheck() async {
        let settings = makeSettings()
        settings.appUpdateChecksEnabled = false
        let notifier = RecordingNotifier()
        let updater = AppUpdater(
            settings: settings,
            checker: StubChecker(result: .success(release("1.3"))),
            notifier: notifier,
            currentVersion: "1.2"
        )
        await updater.checkIfDue()
        #expect(updater.lastChecked == nil)

        await updater.checkNow()
        #expect(updater.availableUpdate != nil)
        #expect(notifier.updates.isEmpty)
        #expect(settings.lastNotifiedAppVersion == "1.3")
    }

    @Test("a failed check keeps the error and finds no update")
    func failure() async {
        let updater = AppUpdater(
            settings: makeSettings(),
            checker: StubChecker(result: .failure(.network("offline"))),
            currentVersion: "1.2"
        )
        await updater.checkIfDue()
        #expect(updater.error == .network("offline"))
        #expect(updater.lastChecked == nil)
        #expect(updater.availableUpdate == nil)
    }

    @Test("dismissing hides the banner until a newer version")
    func dismiss() async {
        let settings = makeSettings()
        let updater = AppUpdater(
            settings: settings,
            checker: StubChecker(result: .success(release("1.3"))),
            currentVersion: "1.2"
        )
        await updater.checkNow()
        updater.dismissBanner()
        #expect(!updater.showsBanner)
        #expect(updater.availableUpdate != nil)

        let later = AppUpdater(
            settings: settings,
            checker: StubChecker(result: .success(release("1.4"))),
            currentVersion: "1.2"
        )
        await later.checkNow()
        #expect(later.showsBanner)
    }

    @Test("the version label carries the build number")
    func versionLabel() {
        let updater = AppUpdater(settings: makeSettings(), currentVersion: "1.2", currentBuild: "4")
        #expect(updater.currentVersionLabel == "1.2 (4)")
    }
}
