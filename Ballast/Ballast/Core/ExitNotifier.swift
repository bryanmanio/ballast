import Foundation
import UserNotifications

enum NotificationAuthorization: Sendable, Equatable {
    case notDetermined, denied, authorized
}

protocol ExitNotifying: Sendable {
    func authorizationStatus() async -> NotificationAuthorization
    func requestAuthorization() async -> Bool
    /// Posts what it is given; deciding what deserves a notification is the
    /// caller's job.
    func post(_ events: [DowntimeEvent]) async
    /// Says a newer Ballast is out. The caller decides it's worth saying.
    func post(appUpdate release: AppRelease) async
}

/// For anything that isn't the real app. `UNUserNotificationCenter.current()`
/// raises outright in a process with no app bundle, such as the test runner.
struct DisabledExitNotifier: ExitNotifying {
    func authorizationStatus() async -> NotificationAuthorization { .denied }
    func requestAuthorization() async -> Bool { false }
    func post(_ events: [DowntimeEvent]) async {}
    func post(appUpdate release: AppRelease) async {}
}

/// The only file that touches UserNotifications, so the rest can be tested
/// against a stub.
///
/// Notification taps aren't handled: that would need an app delegate, which
/// this app doesn't have yet.
final class UserNotificationsExitNotifier: NSObject, ExitNotifying, UNUserNotificationCenterDelegate,
    @unchecked Sendable
{
    /// More than this in one poll is a NAS reboot, not a run of separate
    /// problems, so it collapses into one notification.
    private static let maxIndividual = 3

    private var center: UNUserNotificationCenter { .current() }

    override init() {
        super.init()
        // Without a delegate macOS holds back notifications for an app it
        // considers frontmost, and the popover being open counts.
        center.delegate = self
    }

    func authorizationStatus() async -> NotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .authorized
        @unknown default: .denied
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(_ events: [DowntimeEvent]) async {
        guard !events.isEmpty else { return }

        if events.count > Self.maxIndividual {
            await add(summary(of: events))
            return
        }
        for event in events {
            await add(request(for: event))
        }
    }

    func post(appUpdate release: AppRelease) async {
        let content = UNMutableNotificationContent()
        content.title = "Ballast \(release.version) is available"
        content.body = "Open the Ballast menu to download it."
        // One per version, so a repeat check can't stack duplicates.
        await add(UNNotificationRequest(
            identifier: "app-update-\(release.version)",
            content: content,
            trigger: nil
        ))
    }

    private func request(for event: DowntimeEvent) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "\(event.containerName) exited"
        content.body = event.notificationBody()
        content.sound = .default
        // Repeats from one container stack together in Notification Centre.
        content.threadIdentifier = event.containerName
        return UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil)
    }

    private func summary(of events: [DowntimeEvent]) -> UNNotificationRequest {
        let names = events.map(\.containerName)
        let content = UNMutableNotificationContent()
        content.title = "\(events.count) containers exited"
        content.body = names.prefix(3).joined(separator: ", ")
            + (names.count > 3 ? " and \(names.count - 3) more" : "")
        content.sound = .default
        return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    }

    private func add(_ request: UNNotificationRequest) async {
        try? await center.add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
