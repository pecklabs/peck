import SwiftUI
import AppKit

// Renders the real app views with mock data to PNGs — used for README screenshots.
// Triggered by launching with PECK_SNAPSHOT=1 (see AppDelegate). Output dir from
// PECK_SNAPSHOT_OUT (defaults to a temp dir).
@MainActor
enum Snapshot {
    static var isRendering = false

    static func run(outDir: String) {
        isRendering = true
        I18n.lang = "English"
        let model = mockModel()
        render(SnapScreen(active: .myPrs, tray: model.tray) { myPrsBody(model) },
               model: model, to: outDir + "/my-prs.png")
        render(SnapScreen(active: .reviews, tray: model.tray) { reviewsBody(model) },
               model: model, to: outDir + "/reviews.png")
        exit(0)
    }

    // ScrollView content isn't rendered by ImageRenderer, so rebuild the lists as
    // plain VStacks of the real row views.
    @ViewBuilder static func myPrsBody(_ m: AppModel) -> some View {
        let sorted = m.myPrs.sorted { a, b in
            a.approvedButConflicted != b.approvedButConflicted ? a.approvedButConflicted : a.updatedAt > b.updatedAt
        }
        VStack(alignment: .leading, spacing: 10) {
            BannerView(color: GH.severe, icon: "exclamationmark.triangle.fill",
                       text: "1 approved PR blocked by merge conflicts")
            ForEach(sorted) { MyPrRow(pr: $0) }
        }
        .padding(12)
    }

    @ViewBuilder static func reviewsBody(_ m: AppModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(m.reviewQueue) { ReviewCard(req: $0) }
        }
        .padding(12)
    }

    static func mockModel() -> AppModel {
        let m = AppModel()
        var s = m.settings; s.uiLanguage = "English"; m.settings = s
        m.connected = true
        m.user = GithubUser(login: "sasha1107", name: "Soohyun Jung", avatarUrl: "")
        let now = Date()
        func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

        m.myPrs = [
            MyPullRequest(id: "acme/web#142", owner: "acme", repo: "web", number: 142,
                title: "feat(auth): OAuth device-flow login", url: "", isDraft: false,
                reviewDecision: .approved, mergeable: .conflicting, checks: .success,
                approvedCount: 2, changesRequestedCount: 0, pendingReviewers: [],
                updatedAt: ago(900), requiredApprovals: 2, commentedCount: 1, reviewedCount: 2, botReviewCount: 1),
            MyPullRequest(id: "acme/api#88", owner: "acme", repo: "api", number: 88,
                title: "fix(api): handle null user on /v2 submission", url: "", isDraft: false,
                reviewDecision: nil, mergeable: .mergeable, checks: .pending,
                approvedCount: 1, changesRequestedCount: 0, pendingReviewers: ["dana"],
                updatedAt: ago(3600), requiredApprovals: 2, commentedCount: 0, reviewedCount: 1, botReviewCount: 0,
                selfReview: ReviewDraft(
                    summary: "Guards the /v2 submission handler against a null user and returns 401 instead of crashing. Small and focused; the fix matches the linked issue.",
                    verdict: .requestChanges, body: "",
                    risks: ["The new guard isn't covered by a test — add one for the anonymous-user path",
                            "Leftover debug print in SubmissionHandler.swift"],
                    comments: [], model: "claude-cli", skillsApplied: ["default-review"],
                    generatedAt: now, error: nil)),
            MyPullRequest(id: "acme/ios#231", owner: "acme", repo: "ios", number: 231,
                title: "chore: bump dependencies", url: "", isDraft: false,
                reviewDecision: .approved, mergeable: .mergeable, checks: .success,
                approvedCount: 2, changesRequestedCount: 0, pendingReviewers: [],
                updatedAt: ago(7200), requiredApprovals: 2, commentedCount: 0, reviewedCount: 2, botReviewCount: 0),
            MyPullRequest(id: "acme/web#150", owner: "acme", repo: "web", number: 150,
                title: "feat(i18n): RTL support for Arabic", url: "", isDraft: true,
                reviewDecision: nil, mergeable: .mergeable, checks: .none,
                approvedCount: 0, changesRequestedCount: 0, pendingReviewers: ["lee", "dana"],
                updatedAt: ago(120), requiredApprovals: 2, commentedCount: 0, reviewedCount: 0, botReviewCount: 0),
        ]

        m.reviewQueue = [
            ReviewRequest(id: "acme/web#137", owner: "acme", repo: "web", number: 137,
                title: "feat(cache): add TTL-based eviction to the response cache", url: "",
                author: GithubUser(login: "octocat", name: nil, avatarUrl: ""),
                isDraft: false, additions: 120, deletions: 44, changedFiles: 8,
                createdAt: ago(3600), updatedAt: ago(1800), reviewed: false,
                draft: ReviewDraft(
                    summary: "Adds time-based expiry to the in-memory response cache. The eviction timer isn't cancelled on clear(), so a stale timer can fire after a manual flush and revive evicted entries.",
                    verdict: .requestChanges,
                    body: "A couple of things before this is good to merge:\n\n- Cancel the eviction timer in clear() so a stale fire can't resurrect entries.\n- Add a test for clear() during the TTL window.",
                    risks: ["clear() doesn't cancel the pending eviction timer → entries can reappear",
                            "No test covering clear() during the TTL window"],
                    comments: [], model: "claude-cli", skillsApplied: ["default-review"],
                    generatedAt: now, error: nil)),
            ReviewRequest(id: "acme/api#92", owner: "acme", repo: "api", number: 92,
                title: "refactor(config): load settings from a single typed source", url: "",
                author: GithubUser(login: "monalisa", name: nil, avatarUrl: ""),
                isDraft: false, additions: 64, deletions: 7, changedFiles: 4,
                createdAt: ago(1200), updatedAt: ago(600), reviewed: false,
                draft: ReviewDraft(
                    summary: "Consolidates scattered config reads into one typed Settings struct with sane defaults. Pure, well-scoped refactor; every call site lines up with the new accessors.",
                    verdict: .approve, body: "",
                    risks: [], comments: [], model: "claude-cli",
                    skillsApplied: ["default-review"], generatedAt: now, error: nil)),
        ]
        m.tray = TrayStatus.derive(connected: true, queue: m.reviewQueue, myPrs: m.myPrs)
        return m
    }

    static func render<V: View>(_ view: V, model: AppModel, to file: String) {
        let renderer = ImageRenderer(content: view.environmentObject(model))
        renderer.scale = 2
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: file))
        FileHandle.standardError.write(Data("wrote \(file)\n".utf8))
    }
}

/// App-window chrome (header + tab bar) around a screen, for snapshots.
private struct SnapScreen<Content: View>: View {
    var active: Tab
    var tray: TrayStatus
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 384, height: 560)
        .background(GH.canvas)
        .foregroundStyle(GH.fg)
        .tint(GH.accent)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Peck").font(.system(size: 13, weight: .bold))
            Circle().fill(GH.success).frame(width: 7, height: 7)
            Spacer()
            Text("just now").font(.system(size: 10)).foregroundStyle(GH.muted)
            Image(systemName: "arrow.clockwise").foregroundStyle(GH.muted)
            Image(systemName: "ellipsis.circle").foregroundStyle(GH.muted)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tab("My PRs", .myPrs, count: tray.needAction)
            tab("Reviews", .reviews, count: tray.needsReview)
            tab("Settings", .settings, count: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func tab(_ title: String, _ value: Tab, count: Int) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 12, weight: active == value ? .semibold : .regular))
            if count > 0 {
                Text("\(count)").font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(GH.danger, in: Capsule()).foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 7)
        .background(active == value ? GH.fg.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .foregroundStyle(active == value ? GH.fg : GH.muted)
    }
}
