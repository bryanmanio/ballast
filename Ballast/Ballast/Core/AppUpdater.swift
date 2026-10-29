import Foundation
import Observation

/// Whether a newer Ballast has been released, and telling the user once when
/// one has. Only ever points at the release: nothing is downloaded or
/// installed, the same way image updates are left to the user.
@MainActor
@Observable
final class AppUpdater {
    let currentVersion: AppVersion?
    /// The bundle's version and build, for showing; `currentVersion` is what's compared.
    let currentVersionLabel: String
    private(set) var latestRelease: AppRelease?
    private(set) var lastChecked: Date?
    private(set) var isChecking = false
    /// Why the last check didn't get an answer. Cleared by one that does.
    private(set) var error: AppUpdateError?

    /// Releases come out every few weeks at most, so once a day is plenty.
    static let checkInterval: TimeInterval = 24 * 3_600
    /// Sooner after a failure, so a Mac that woke up offline isn't a day late.
    static let retryInterval: TimeInterval = 3_600
    /// Long enough after launch not to compete with the first NAS poll.
    static let launchDelay: Duration = .seconds(10)
    /// How often the loop wakes to see whether a check is due. Waking and
    /// comparing dates, rather than sleeping a whole day, keeps the schedule
    /// honest across the Mac sleeping and checks being switched off and on.
    static let tick: Duration = .seconds(600)

    private let settings: AppSettings
    private let checker: any AppUpdateChecking
    private let notifier: any ExitNotifying
    private var loopTask: Task<Void, Never>?
    private var nextAutomaticCheck = Date.distantPast

    init(
        settings: AppSettings,
        checker: any AppUpdateChecking = DisabledAppUpdateChecker(),
        notifier: any ExitNotifying = DisabledExitNotifier(),
        currentVersion: String = AppUpdater.bundleVersion,
        currentBuild: String? = AppUpdater.bundleBuild
    ) {
        self.settings = settings
        self.checker = checker
        self.notifier = notifier
        self.currentVersion = AppVersion(currentVersion)
        self.currentVersionLabel = currentBuild.map { "\(currentVersion) (\($0))" } ?? currentVersion
    }

    nonisolated static var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    nonisolated static var bundleBuild: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    /// The latest release, when it's newer than what's running.
    var availableUpdate: AppRelease? {
        guard let latestRelease, let currentVersion, latestRelease.version > currentVersion else { return nil }
        return latestRelease
    }

    /// Whether the menu should mention the update. Settings always does.
    var showsBanner: Bool {
        guard let availableUpdate else { return false }
        return settings.dismissedAppVersion != availableUpdate.version.description
    }

    /// Hides the menu's banner until a newer version than this one comes out.
    func dismissBanner() {
        guard let availableUpdate else { return }
        settings.dismissedAppVersion = availableUpdate.version.description
    }

    /// For the Settings button. Runs even with automatic checks off: asking
    /// is what the button is for.
    func checkNow() async {
        await check(notifies: false)
    }

    func startAutomaticChecks() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            try? await Task.sleep(for: Self.launchDelay)
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(for: Self.tick)
            }
        }
    }

    func stopAutomaticChecks() {
        loopTask?.cancel()
        loopTask = nil
    }

    func checkIfDue(now: Date = Date()) async {
        guard settings.appUpdateChecksEnabled, now >= nextAutomaticCheck else { return }
        await check(notifies: true)
    }

    private func check(notifies: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let now = Date()
        do {
            let release = try await checker.latestRelease()
            latestRelease = release
            lastChecked = now
            error = nil
            nextAutomaticCheck = now.addingTimeInterval(Self.checkInterval)
        } catch {
            self.error = error
            nextAutomaticCheck = now.addingTimeInterval(Self.retryInterval)
            return
        }

        guard let update = availableUpdate else { return }
        let version = update.version.description
        guard settings.lastNotifiedAppVersion != version else { return }
        // A manual check already has the user looking at the answer, so it
        // only marks the version as told rather than notifying as well.
        if notifies {
            // Never prompts: permission is asked for when the user turns
            // exit notifications on, not sprung on them by an update.
            guard await notifier.authorizationStatus() == .authorized else { return }
            await notifier.post(appUpdate: update)
        }
        settings.lastNotifiedAppVersion = version
    }
}
