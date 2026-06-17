import SwiftUI
import AppKit

enum Tab: Hashable { case myPrs, reviews, settings }

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab: Tab = .myPrs

    private var effectiveTab: Tab { model.connected ? tab : .settings }

    static let peckLogo: NSImage? = Bundle.module
        .url(forResource: "peck-mark", withExtension: "png", subdirectory: "brand")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.connected {
                tabBar
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(GH.canvas)
        .foregroundStyle(GH.fg)
        .tint(GH.accent)
        .id(model.settings.uiLanguage) // rebuild the tree when UI language changes
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Peck").font(.system(size: 13, weight: .bold))
            Circle()
                .fill(model.connected ? GH.success : GH.muted)
                .frame(width: 7, height: 7)
            Spacer()
            if model.connected {
                if let last = model.lastSync {
                    Text(timeAgo(last)).font(.system(size: 10)).foregroundStyle(GH.muted)
                }
                Button { Task { await model.sync() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(model.syncing ? 360 : 0))
                        .animation(model.syncing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                                   value: model.syncing)
                }
                .buttonStyle(.borderless)
                .help("Sync now")
            }
            Menu {
                Button(tr("Settings")) { tab = .settings }
                Button(tr("Sync now")) { Task { await model.sync() } }
                if model.canCheckForUpdates {
                    Button(tr("Check for Updates…")) { model.checkForUpdates() }
                }
                Divider()
                Button(tr("Quit Peck")) { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(tr("My PRs"), .myPrs, count: model.tray.needAction, countColor: GH.danger)
            tabButton(tr("Reviews"), .reviews, count: model.tray.needsReview, countColor: GH.danger)
            tabButton(tr("Settings"), .settings, count: 0, countColor: .clear)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func tabButton(_ title: String, _ value: Tab, count: Int, countColor: Color) -> some View {
        Button { tab = value } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: effectiveTab == value ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(countColor, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(effectiveTab == value ? GH.fg.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(effectiveTab == value ? GH.fg : GH.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        switch effectiveTab {
        case .myPrs: MyPRsView()
        case .reviews: ReviewQueueView()
        case .settings: SettingsView()
        }
    }
}
