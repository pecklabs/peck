import AppKit
import Foundation
import UserNotifications

/// Thin wrapper over UNUserNotificationCenter. No-ops gracefully if notification
/// authorization is unavailable (e.g. running unbundled).
enum Notifier {
    /// macOS shows the permission prompt only once, ever. After that this call is a silent
    /// no-op, so a denial can only be undone in System Settings — see `openSystemSettings`.
    @discardableResult
    static func requestAuthorization() async -> UNAuthorizationStatus? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await authorizationStatus()
    }

    /// nil when there is nobody to ask (unbundled `swift run`); callers treat that as "don't warn".
    static func authorizationStatus() async -> UNAuthorizationStatus? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Deep-link to System Settings › Notifications with Peck's row selected. An app cannot
    /// flip its own notification switch, so walking the user to it is as far as we can go.
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let panes = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",  // Ventura and later
            "x-apple.systempreferences:com.apple.preference.notifications?id=\(id)",          // Monterey and earlier
        ]
        for pane in panes {
            if let url = URL(string: pane), NSWorkspace.shared.open(url) { return }
        }
    }

    static func post(title: String, body: String, subtitle: String? = nil) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
