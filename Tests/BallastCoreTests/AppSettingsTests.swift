import Foundation
import Testing
@testable import BallastCore

/// Settings live in the `com.mediumrare.ballast` defaults domain, outside the
/// app bundle, so replacing Ballast.app with a new version keeps them — as
/// long as each setting is still read from the key it was written under.
/// These keys and value formats are what earlier versions left on disk;
/// renaming one would quietly reset that setting for everyone who updates.
@MainActor
@Suite("Settings survive an update")
struct AppSettingsCompatibilityTests {

    @Test("every setting is read from the key earlier versions wrote")
    func readsExistingKeys() throws {
        let suite = "AppSettingsCompatibilityTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Written with literal keys, the way a 1.x install has them on disk.
        defaults.set("ballast-nas", forKey: "sshDestination")
        defaults.set("192.168.4.79", forKey: "lanHost")
        defaults.set("100.123.69.35", forKey: "remoteHost")
        defaults.set("/opt/ballast/agent", forKey: "agentPath")
        defaults.set(2222, forKey: "reachabilityPort")
        defaults.set(false, forKey: "autoRefreshEnabled")
        defaults.set(60.0, forKey: "refreshInterval")
        defaults.set("1966080:11", forKey: "hotkey")
        defaults.set(true, forKey: "probeEnabled")
        defaults.set(false, forKey: "hideProjectNames")
        defaults.set("name", forKey: "sortOrder")
        defaults.set(["whisparr"], forKey: "hiddenContainers")
        defaults.set(true, forKey: "notifyOnUnexpectedExit")
        defaults.set(["plex"], forKey: "mutedContainers")
        defaults.set(false, forKey: "imageUpdateChecksEnabled")
        defaults.set(true, forKey: "hasCompletedOnboarding")
        defaults.set(false, forKey: "appUpdateChecksEnabled")
        defaults.set("1.3", forKey: "lastNotifiedAppVersion")
        defaults.set("1.3", forKey: "dismissedAppVersion")

        let settings = AppSettings(defaults: defaults)
        #expect(settings.sshDestination == "ballast-nas")
        #expect(settings.lanHost == "192.168.4.79")
        #expect(settings.remoteHost == "100.123.69.35")
        #expect(settings.agentPath == "/opt/ballast/agent")
        #expect(settings.reachabilityPort == 2222)
        #expect(settings.autoRefreshEnabled == false)
        #expect(settings.refreshInterval == 60)
        #expect(settings.hotkey == HotkeyBinding(storageValue: "1966080:11"))
        #expect(settings.probeEnabled == true)
        #expect(settings.hideProjectNames == false)
        #expect(settings.sortOrder == .name)
        #expect(settings.hiddenContainers == ["whisparr"])
        #expect(settings.notifyOnUnexpectedExit == true)
        #expect(settings.mutedContainers == ["plex"])
        #expect(settings.imageUpdateChecksEnabled == false)
        #expect(settings.hasCompletedOnboarding == true)
        #expect(settings.appUpdateChecksEnabled == false)
        #expect(settings.lastNotifiedAppVersion == "1.3")
        #expect(settings.dismissedAppVersion == "1.3")
    }

    @Test("a setting written by this version reads back after a relaunch")
    func roundTrips() throws {
        let suite = "AppSettingsCompatibilityTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppSettings(defaults: defaults)
        first.sshDestination = "nas"
        first.hiddenContainers = ["a", "b"]
        first.hotkey = nil
        first.dismissedAppVersion = "2.0"

        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.sshDestination == "nas")
        #expect(relaunched.hiddenContainers == ["a", "b"])
        #expect(relaunched.hotkey == nil)
        #expect(relaunched.dismissedAppVersion == "2.0")
    }
}
