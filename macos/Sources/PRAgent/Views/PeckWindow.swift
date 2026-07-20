import SwiftUI
import AppKit

private struct PeckWindowModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the UI is hosted in the standalone app window rather than the
    /// menu-bar popover. Window mode has room to spare, so content the popover
    /// only badges (e.g. a self-review) renders in full and selectable.
    var peckWindowMode: Bool {
        get { self[PeckWindowModeKey.self] }
        set { self[PeckWindowModeKey.self] = newValue }
    }
}

/// ScrollView, except while snapshotting (ImageRenderer skips ScrollView content).
struct SnapScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if Snapshot.isRendering {
            content
        } else {
            ScrollView { content }
        }
    }
}

/// The whole app as a resizable window, kept alive across close/reopen so
/// size, section, and selection survive. Unlike the popover it has a sidebar
/// (My PRs / Reviews / Settings), and each PR section is a master-detail
/// split: compact list on the left, the full content on the right — so no
/// single column ever scrolls forever.
@MainActor
enum PeckWindow {
    private static var window: NSWindow?

    static func open(model: AppModel) {
        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            win.title = "Peck"
            win.isReleasedWhenClosed = false
            win.collectionBehavior.insert(.fullScreenPrimary) // green button → real fullscreen
            win.center()
            win.contentView = NSHostingView(
                rootView: PeckWindowRoot()
                    .environmentObject(model)
                    .environment(\.peckWindowMode, true)
                    .frame(minWidth: 780, minHeight: 520))
            // While the window is up, behave like a normal app (Dock icon,
            // Cmd+Tab); drop back to menu-bar-only when it closes.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: win, queue: .main
            ) { _ in
                DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
            }
            window = win
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum WindowSection: Hashable { case myPrs, reviews, settings }

struct PeckWindowRoot: View {
    @EnvironmentObject var model: AppModel
    @State private var section: WindowSection = .myPrs
    @State private var selectedMyPr: String?
    @State private var selectedReview: String?

    private var effectiveSection: WindowSection { model.connected ? section : .settings }

    var body: some View {
        Group {
            if model.connected || model.hasGitHubAuth {
                HStack(spacing: 0) {
                    sidebar
                    Divider()
                    content
                }
            } else {
                // Fresh install: onboard right here in the window.
                OnboardingView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(GH.canvas)
        .foregroundStyle(GH.fg)
        .tint(GH.accent)
        .id(model.settings.uiLanguage)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("Peck").font(.system(size: 14, weight: .bold))
                Circle()
                    .fill(model.connected ? GH.success : GH.muted)
                    .frame(width: 7, height: 7)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 10)

            sideItem(tr("My PRs"), icon: "arrow.triangle.branch", .myPrs, count: model.tray.needAction)
            sideItem(tr("Reviews"), icon: "eye", .reviews, count: model.tray.needsReview)
            sideItem(tr("Settings"), icon: "gearshape", .settings, count: 0)

            Spacer()

            HStack(spacing: 6) {
                if let last = model.lastSync {
                    Text(timeAgo(last)).font(.system(size: 10)).foregroundStyle(GH.muted)
                }
                Spacer()
                Button { Task { await model.sync() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(model.syncing ? 360 : 0))
                        .animation(model.syncing
                            ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                            value: model.syncing)
                }
                .buttonStyle(.borderless)
                .help("Sync now")
            }
            .padding(.horizontal, 10).padding(.bottom, 12)
        }
        .padding(.horizontal, 6)
        .frame(width: 168)
        .background(GH.subtle)
    }

    private func sideItem(_ title: String, icon: String, _ value: WindowSection, count: Int) -> some View {
        Button { section = value } label: {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 16)
                Text(title).font(.system(size: 12, weight: effectiveSection == value ? .semibold : .regular))
                Spacer()
                if count > 0 { CountBadge(count: count) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(effectiveSection == value ? GH.fg.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(effectiveSection == value ? GH.fg : GH.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch effectiveSection {
        case .myPrs: MyPrsSplitView(selection: $selectedMyPr)
        case .reviews: ReviewsSplitView(selection: $selectedReview)
        case .settings:
            SettingsView()
        }
    }
}

struct CountBadge: View {
    var count: Int
    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(GH.danger, in: Capsule())
            .foregroundStyle(.white)
    }
}

// MARK: - My PRs (list left, detail right)

struct MyPrsSplitView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: String?

    private var sorted: [MyPullRequest] {
        model.myPrs.sorted { a, b in
            if a.approvedButConflicted != b.approvedButConflicted { return a.approvedButConflicted }
            return a.updatedAt > b.updatedAt
        }
    }

    private var selected: MyPullRequest? {
        sorted.first { $0.id == selection } ?? sorted.first
    }

    var body: some View {
        HStack(spacing: 0) {
            SnapScroll {
                VStack(alignment: .leading, spacing: 8) {
                    if sorted.isEmpty {
                        EmptyState(icon: "tray", title: tr("No open PRs"),
                                   subtitle: tr("PRs you author will show up here with their review status."))
                    } else {
                        ForEach(sorted) { pr in
                            MyPrListRow(pr: pr, isSelected: pr.id == selected?.id) {
                                selection = pr.id
                            }
                        }
                    }
                }
                .padding(10)
            }
            .frame(width: 330)
            .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            if let pr = selected {
                SnapScroll { MyPrDetail(pr: pr) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct MyPrListRow: View {
    var pr: MyPullRequest
    var isSelected: Bool
    var select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 0) {
                if pr.approvedButConflicted {
                    Rectangle().fill(GH.severe).frame(width: 3)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(pr.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Text(pr.nameWithNumber).font(.system(size: 10)).foregroundStyle(GH.muted)
                    ReviewQuest(pr: pr)
                    PrStatusBadges(pr: pr)
                    if let draft = pr.selfReview {
                        SelfReviewBadgeRow(draft: draft)
                    }
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true) // keep the conflict bar from stretching the row
            .background(
                pr.approvedButConflicted ? GH.severe.opacity(0.08) : GH.subtle,
                in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isSelected ? GH.accent : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MyPrDetail: View {
    @EnvironmentObject var model: AppModel
    var pr: MyPullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pr.title).font(.system(size: 15, weight: .bold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(pr.nameWithNumber).font(.system(size: 11)).foregroundStyle(GH.muted)
                if !Snapshot.isRendering {
                    Button { Open.url(pr.url) } label: {
                        Label(tr("Open on GitHub"), systemImage: "arrow.up.right.square")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                }
                Spacer()
            }
            ReviewQuest(pr: pr)
            if !pr.reviewers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Reviewers"))
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(GH.muted)
                    ForEach(pr.reviewers) { ReviewerRow(reviewer: $0) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GH.subtle, in: RoundedRectangle(cornerRadius: 8))
            }
            PrStatusBadges(pr: pr)
            Divider()
            SelfReviewSection(pr: pr)
            Divider()
            CommentsSection(owner: pr.owner, repo: pr.repo, number: pr.number,
                            prId: pr.id, updatedAt: pr.updatedAt)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Conversation on the selected PR — discussion comments, inline review
/// comments (with the file they're anchored to), and review summaries.
/// Loaded lazily per selection; refreshed when the PR gets new activity.
struct CommentsSection: View {
    @EnvironmentObject var model: AppModel
    var owner: String
    var repo: String
    var number: Int
    var prId: String
    var updatedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(tr("Comments"))
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(GH.muted)
                if model.commentsLoading.contains(prId) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
                Spacer()
            }
            let comments = model.prComments[prId] ?? []
            if comments.isEmpty {
                if !model.commentsLoading.contains(prId) {
                    Text(tr("No comments yet.")).font(.system(size: 11)).foregroundStyle(GH.muted)
                }
            } else {
                ForEach(comments) { CommentRow(comment: $0) }
            }
        }
        // updatedAt in the id → refetch when the PR sees new activity.
        .task(id: "\(prId)-\(updatedAt.timeIntervalSince1970)") {
            await model.loadComments(owner: owner, repo: repo, number: number, id: prId)
        }
    }
}

struct CommentRow: View {
    var comment: PrComment

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                AvatarView(url: comment.avatarUrl, size: 16)
                Text(comment.author).font(.system(size: 11, weight: .semibold))
                verdictPill
                Spacer()
                Text(timeAgo(comment.createdAt)).font(.system(size: 9)).foregroundStyle(GH.muted)
            }
            if let path = comment.path {
                Text(path)
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(GH.accent)
                    .lineLimit(1).truncationMode(.middle)
            }
            Text(markdownBody)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GH.subtle, in: RoundedRectangle(cornerRadius: 8))
    }

    private var markdownBody: AttributedString {
        (try? AttributedString(
            markdown: comment.body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(comment.body)
    }

    @ViewBuilder private var verdictPill: some View {
        switch comment.verdict {
        case "APPROVED":
            Pill(text: tr("Approved"), color: GH.success, systemImage: "checkmark")
        case "CHANGES_REQUESTED":
            Pill(text: tr("Requested changes"), color: GH.danger, systemImage: "plusminus")
        default:
            EmptyView()
        }
    }
}

// MARK: - Reviews (list left, draft right)

struct ReviewsSplitView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: String?

    private var pending: [ReviewRequest] {
        model.reviewQueue.filter { !$0.reviewed }
    }

    private var selected: ReviewRequest? {
        pending.first { $0.id == selection } ?? pending.first
    }

    var body: some View {
        HStack(spacing: 0) {
            SnapScroll {
                VStack(alignment: .leading, spacing: 8) {
                    if pending.isEmpty {
                        EmptyState(icon: "eye", title: tr("No reviews requested"),
                                   subtitle: tr("When someone requests your review, the agent drafts an explanation and a verdict here."))
                    } else {
                        ForEach(pending) { req in
                            ReviewListRow(req: req, isSelected: req.id == selected?.id) {
                                selection = req.id
                            }
                        }
                    }
                }
                .padding(10)
            }
            .frame(width: 330)
            .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            if let req = selected {
                SnapScroll {
                    VStack(alignment: .leading, spacing: 10) {
                        ReviewCard(req: req)
                            .id(req.id) // new selection → fresh editor state
                        CommentsSection(owner: req.owner, repo: req.repo, number: req.number,
                                        prId: req.id, updatedAt: req.updatedAt)
                    }
                    .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct ReviewListRow: View {
    var req: ReviewRequest
    var isSelected: Bool
    var select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                Text(req.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Text("\(req.nameWithNumber) · @\(req.author.login)")
                    .font(.system(size: 10)).foregroundStyle(GH.muted)
                HStack(spacing: 8) {
                    Label("+\(req.additions)", systemImage: "plus").foregroundStyle(GH.success)
                    Label("\(req.deletions)", systemImage: "minus").foregroundStyle(GH.danger)
                    Label("\(req.changedFiles)", systemImage: "doc")
                    Text(timeAgo(req.createdAt))
                    Spacer()
                }
                .font(.system(size: 10)).foregroundStyle(GH.muted)
                if req.reviewing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(tr("Peck is reviewing…")).font(.system(size: 10)).foregroundStyle(GH.muted)
                    }
                } else if let draft = req.draft {
                    if draft.error != nil {
                        Pill(text: tr("Retry"), color: GH.attention, systemImage: "exclamationmark.triangle")
                    } else {
                        VerdictBadge(verdict: draft.verdict)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GH.subtle, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isSelected ? GH.accent : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
