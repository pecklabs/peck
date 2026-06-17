import SwiftUI
import AppKit
import UserNotifications

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        if env["PECK_SNAPSHOT"] != nil {
            Snapshot.run(outDir: env["PECK_SNAPSHOT_OUT"] ?? NSTemporaryDirectory())
            return
        }
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        model.bootstrap()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
