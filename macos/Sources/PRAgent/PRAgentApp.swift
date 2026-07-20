import SwiftUI
import AppKit
import UserNotifications
import Combine

@main
struct PRAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environmentObject(appDelegate.model)
                .frame(width: 384, height: 540)
        } label: {
            MenuBarLabel()
                .environmentObject(appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        if env["PECK_SNAPSHOT"] != nil {
            Snapshot.run(outDir: env["PECK_SNAPSHOT_OUT"] ?? NSTemporaryDirectory())
            return
        }
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        model.bootstrap()

        // Menu-bar apps have no window or Dock icon, so a fresh install looks like
        // "nothing happened". Open the app window (which shows onboarding while
        // disconnected) when there's no stored auth. Gated on hasGitHubAuth (not
        // just !connected) so a configured user doesn't see it flash while the
        // saved login is still validating asynchronously at launch.
        // ($connected delivers its current value on subscribe.)
        model.$connected
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self else { return }
                if !connected && !self.model.hasGitHubAuth {
                    PeckWindow.open(model: self.model)
                }
            }
            .store(in: &cancellables)
    }

    /// Clicking the app icon (Dock, Launchpad, Finder) while running opens the
    /// main window — what a normal app would do.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        PeckWindow.open(model: model)
        return false
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking a self-review notification opens the app window on My PRs.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard info["selfReviewPr"] is String else { return }
        await MainActor.run { PeckWindow.open(model: self.model) }
    }
}
