import SwiftUI
import AppKit
import UserNotifications
import Combine

/// Demo-only host (PECK_DEMO=1): the Reviews list plus an error banner, so the
/// optimistic rollback path (card restored + errorMessage) is visible — the
/// shipped list view surfaces errorMessage elsewhere (Settings / Onboarding).
private struct DemoReviewsRoot: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            if let err = model.errorMessage {
                Text(err)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GH.danger)
            }
            ReviewQueueView()
        }
    }
}

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
        if env["PECK_DEMO"] != nil {
            runDemo()
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

    /// Interactive demo (PECK_DEMO=1): hosts the real Reviews UI over mock data in
    /// a plain window so the optimistic card-dismissal animation can be seen
    /// without connecting to GitHub. Not part of the shipped app flow.
    private var demoWindow: NSWindow?
    private func runDemo() {
        NSApp.setActivationPolicy(.regular)
        let m = Snapshot.mockModel()
        m.demoMode = true
        m.demoFails = ProcessInfo.processInfo.environment["PECK_DEMO_FAIL"] != nil
        // PECK_DEMO_LOADING=1: freeze the first card in its submitting state so the
        // whole-card loading treatment can be inspected/captured without racing the
        // ~700ms beat.
        if ProcessInfo.processInfo.environment["PECK_DEMO_LOADING"] != nil, !m.reviewQueue.isEmpty {
            m.reviewQueue[0].submitting = true
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 384, height: 560),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        win.title = "Peck — demo (Reviews)"
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView:
            DemoReviewsRoot()
                .environmentObject(m)
                .frame(width: 384, height: 560)
                .background(GH.canvas)
                .foregroundStyle(GH.fg)
                .tint(GH.accent))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        demoWindow = win
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

    /// Clicking a self-review notification opens the app window on My PRs
    /// with that PR selected.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let prId = (info["selfReviewPr"] ?? info["focusMyPr"]) as? String else { return }
        await MainActor.run { PeckWindow.open(model: self.model, focusMyPr: prId) }
    }
}
