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
    private var onboardingWindow: NSWindow?
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
        // "nothing happened". Pop an onboarding window when there's no stored auth;
        // close it once connected. We gate "show" on hasGitHubAuth (not just
        // !connected) so a configured user doesn't see it flash while the saved
        // login is still validating asynchronously at launch.
        // ($connected delivers its current value on subscribe.)
        model.$connected
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self else { return }
                if connected { self.closeOnboarding() }
                else if !self.model.hasGitHubAuth { self.showOnboarding() }
            }
            .store(in: &cancellables)
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 360),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false)
            win.title = "Peck"
            win.titlebarAppearsTransparent = true
            win.isReleasedWhenClosed = false
            win.center()
            win.contentView = NSHostingView(rootView: OnboardingView().environmentObject(model))
            onboardingWindow = win
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeOnboarding() {
        onboardingWindow?.close()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
