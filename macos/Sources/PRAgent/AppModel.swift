import Foundation
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class AppModel: ObservableObject {
    @Published var connected = false
    @Published var user: GithubUser?
    @Published var hasAnthropicKey = false
    @Published var reviewQueue: [ReviewRequest] = []
    @Published var myPrs: [MyPullRequest] = []
    @Published var settings = AppSettings()
    @Published var tray = TrayStatus.derive(connected: false, queue: [], myPrs: [])
    @Published var lastSync: Date?
    @Published var syncing = false
    @Published var errorMessage: String?
    @Published var skills: [SkillInfo] = []
    /// Conversation per PR id, loaded lazily for the window's detail pane.
    @Published var prComments: [String: [PrComment]] = [:]
    @Published var commentsLoading: Set<String> = []
    /// PR ids whose last comment fetch failed (distinct from "no comments").
    @Published var commentsFailed: Set<String> = []

    private let github = GitHubClient.shared
    private var pollTask: Task<Void, Never>?
    private var notifTask: Task<Void, Never>?
    private var isSyncing = false

    #if canImport(Sparkle)
    // Created only once a real Sparkle feed + public key are configured in
    // Info.plist, so unconfigured/dev runs don't crash on startUpdater().
    private var updaterController: SPUStandardUpdaterController?
    #endif
    var canCheckForUpdates: Bool {
        #if canImport(Sparkle)
        return updaterController != nil
        #else
        return false
        #endif
    }

    // Notification dedup.
    private var notifiedReviews: Set<String> = []
    private var notifiedConflicts: Set<String> = []
    private var prevAllApproved = false

    /// My non-draft PR ids already baselined or self-reviewed. Persisted across
    /// launches so restarting the app doesn't re-baseline (which would silently
    /// skip PRs uploaded between runs). nil only on the very first sync ever —
    /// that one records a baseline instead of review-bombing every open PR.
    private var seenMyPrIds: Set<String>?
    /// Successful self-review drafts, persisted so results survive a relaunch.
    private var storedSelfReviews: [String: ReviewDraft] = [:]

    private let settingsKey = "settings"
    private let selfReviewSeenKey = "selfReviewSeen"
    private let selfReviewDraftsKey = "selfReviewDrafts"

    init() {
        loadSettings()
        I18n.lang = settings.uiLanguage
        skills = Skills.info()
        hasAnthropicKey = Keychain.has(.anthropicKey)
        loadSelfReviewStore()
    }

    private func loadSelfReviewStore() {
        if let data = UserDefaults.standard.data(forKey: selfReviewSeenKey),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: data) {
            seenMyPrIds = ids
        }
        if let data = UserDefaults.standard.data(forKey: selfReviewDraftsKey),
           let drafts = try? JSONDecoder().decode([String: ReviewDraft].self, from: data) {
            storedSelfReviews = drafts
        }
    }

    private func persistSelfReviewStore() {
        if let seen = seenMyPrIds, let data = try? JSONEncoder().encode(seen) {
            UserDefaults.standard.set(data, forKey: selfReviewSeenKey)
        }
        if let data = try? JSONEncoder().encode(storedSelfReviews) {
            UserDefaults.standard.set(data, forKey: selfReviewDraftsKey)
        }
    }

    func bootstrap() {
        AppPaths.ensure()
        Task { await Notifier.requestAuthorization() }
        startUpdaterIfConfigured()
        skills = Skills.info()
        if settings.useGhAuth {
            github.auth = .gh
            start()
        } else if Keychain.has(.githubToken) {
            start()
        }
    }

    private func startUpdaterIfConfigured() {
        #if canImport(Sparkle)
        guard Bundle.main.bundleIdentifier != nil,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let feedURL = URL(string: feed),
              feedURL.scheme != nil,
              feedURL.host != nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty, !key.hasPrefix("REPLACE") else { return }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }

    func checkForUpdates() {
        #if canImport(Sparkle)
        updaterController?.updater.checkForUpdates()
        #endif
    }

    var hasGitHubAuth: Bool { settings.useGhAuth || Keychain.has(.githubToken) }

    /// Whether the review agent can run with the current backend.
    var agentAvailable: Bool {
        switch settings.agentBackend {
        case .anthropicAPI: return hasAnthropicKey
        case .claudeCLI: return Shell.resolve("claude") != nil
        case .codexCLI: return Shell.resolve("codex") != nil
        }
    }

    // MARK: Settings

    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = s
        }
    }

    /// Persist settings without disturbing the poll loop.
    private func persist(_ next: AppSettings) {
        settings = next
        I18n.lang = next.uiLanguage
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    func saveSettings(_ next: AppSettings) {
        let intervalChanged = next.pollIntervalSec != settings.pollIntervalSec
        persist(next)
        if intervalChanged && connected { schedulePolling() }
    }

    // MARK: Connection

    func start() {
        github.resetViewerCache()
        Task { await self.loadViewerThenSync() }
        schedulePolling()
        startNotificationsWatch()
    }

    /// Cheap conditional poll of GitHub's Notifications API; fires an immediate
    /// sync the moment a review is requested (near-real-time push without a server).
    private func startNotificationsWatch() {
        notifTask?.cancel()
        notifTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let signal = await self.github.pollReviewNotifications()
                if Task.isCancelled { break }
                if signal.newReviewRequest { await self.sync() }
                let wait = max(30, signal.pollAfterSec)
                try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            }
        }
    }

    func restart() {
        schedulePolling()
        Task { await sync() }
    }

    private func loadViewerThenSync() async {
        do {
            user = try await github.fetchViewer()
            connected = true
        } catch {
            connected = false
            errorMessage = error.localizedDescription
        }
        await sync()
    }

    private func schedulePolling() {
        pollTask?.cancel()
        let interval = max(15, settings.pollIntervalSec)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                if Task.isCancelled { break }
                await self?.sync()
            }
        }
    }

    func connectGitHub(token: String) async {
        do {
            let u = try await github.validateToken(token)
            Keychain.set(.githubToken, token)
            github.useKeychain()
            var s = settings; s.useGhAuth = false; persist(s)
            user = u
            connected = true
            errorMessage = nil
            schedulePolling()
            startNotificationsWatch()
            await sync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reuse the `gh` CLI's existing login.
    func connectGitHubCLI() async {
        do {
            let u = try await github.useGitHubCLI()
            var s = settings; s.useGhAuth = true; persist(s)
            user = u
            connected = true
            errorMessage = nil
            schedulePolling()
            startNotificationsWatch()
            await sync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnectGitHub() {
        Keychain.delete(.githubToken)
        github.useKeychain()
        var s = settings; s.useGhAuth = false; persist(s)
        pollTask?.cancel()
        notifTask?.cancel()
        user = nil
        connected = false
        reviewQueue = []
        myPrs = []
        recomputeTray()
    }

    func setAnthropicKey(_ key: String) {
        Keychain.set(.anthropicKey, key)
        hasAnthropicKey = true
    }

    func clearAnthropicKey() {
        Keychain.delete(.anthropicKey)
        hasAnthropicKey = false
    }

    func reloadSkills() {
        skills = Skills.info()
    }

    // MARK: Sync

    func sync() async {
        guard hasGitHubAuth else {
            connected = false
            errorMessage = "Not connected to GitHub"
            return
        }
        if isSyncing { return }
        isSyncing = true
        syncing = true
        defer { isSyncing = false; syncing = false }
        do {
            async let q = github.fetchReviewRequests()
            async let m = github.fetchMyPullRequests()
            let (queue, prs) = try await (q, m)
            mergeQueue(queue)
            mergeMyPrs(prs)
            connected = true
            errorMessage = nil
            lastSync = Date()
            recomputeTray()
            handleNotifications(queue: reviewQueue, myPrs: myPrs)
            triggerSelfReviews()
        } catch {
            connected = false
            errorMessage = error.localizedDescription
        }
    }

    /// Preserve existing drafts across refreshes when the PR hasn't changed.
    private func mergeQueue(_ incoming: [ReviewRequest]) {
        let prev = Dictionary(uniqueKeysWithValues: reviewQueue.map { ($0.id, $0) })
        reviewQueue = incoming.map { r in
            var r = r
            if let old = prev[r.id], old.updatedAt == r.updatedAt {
                r.draft = old.draft
                r.reviewing = old.reviewing
            }
            return r
        }
    }

    /// Preserve self-review results across refreshes (and restore persisted ones
    /// after a relaunch). A self-review runs once per upload (not per update),
    /// so it's kept even when the PR has new activity.
    private func mergeMyPrs(_ incoming: [MyPullRequest]) {
        let prev = Dictionary(uniqueKeysWithValues: myPrs.map { ($0.id, $0) })
        myPrs = incoming.map { p in
            var p = p
            if let old = prev[p.id] {
                p.selfReview = old.selfReview
                p.selfReviewing = old.selfReviewing
            }
            if p.selfReview == nil { p.selfReview = storedSelfReviews[p.id] }
            return p
        }
    }

    /// Self-review each PR the user uploads. Draft PRs don't count until they're
    /// marked ready for review. PRs are only marked seen when self-review is
    /// actually on and runnable, so enabling it (or fixing the agent) later
    /// still picks up what was uploaded in the meantime.
    private func triggerSelfReviews() {
        let ready = Set(myPrs.filter { !$0.isDraft }.map(\.id))
        if seenMyPrIds == nil {
            // Very first sync ever: baseline, don't review-bomb existing PRs.
            seenMyPrIds = ready
        } else if settings.selfReview && agentAvailable {
            for p in myPrs where !p.isDraft && !(seenMyPrIds?.contains(p.id) ?? false)
                && p.selfReview == nil && !p.selfReviewing {
                Task { await self.runSelfReview(id: p.id) }
            }
            seenMyPrIds?.formUnion(ready)
        }
        // Drop stored results for PRs that are no longer open.
        let openIds = Set(myPrs.map(\.id))
        storedSelfReviews = storedSelfReviews.filter { openIds.contains($0.key) }
        persistSelfReviewStore()
    }

    private func recomputeTray() {
        tray = TrayStatus.derive(connected: connected, queue: reviewQueue, myPrs: myPrs)
    }

    private func handleNotifications(queue: [ReviewRequest], myPrs: [MyPullRequest]) {
        let notify = settings.notifications

        for r in queue where !r.reviewed && !r.isDraft {
            if notifiedReviews.contains(r.id) { continue }
            notifiedReviews.insert(r.id)
            if notify {
                Notifier.post(title: "New review request", body: r.title,
                              subtitle: "\(r.owner)/\(r.repo) · @\(r.author.login)")
            }
        }
        notifiedReviews = notifiedReviews.filter { id in queue.contains { $0.id == id } }

        // Auto-generate a draft for every pending review that doesn't have one yet.
        // Decoupled from the notification dedup so it also runs on launch / after
        // restart. An errored draft is left alone (manual retry) to avoid loops.
        if settings.autoReview {
            for r in queue where !r.reviewed && !r.isDraft && r.draft == nil && !r.reviewing {
                Task { await self.runReview(id: r.id) }
            }
        }

        for p in myPrs {
            if p.approvedButConflicted && !notifiedConflicts.contains(p.id) {
                notifiedConflicts.insert(p.id)
                if notify {
                    Notifier.post(title: "Merge conflict",
                                  body: "\(p.title) is approved but has conflicts",
                                  subtitle: "\(p.owner)/\(p.repo)")
                }
            }
            if !p.approvedButConflicted { notifiedConflicts.remove(p.id) }
        }

        let allApproved = !myPrs.isEmpty && myPrs.allSatisfy { $0.allApproved }
            && !myPrs.contains { $0.approvedButConflicted }
        if allApproved && !prevAllApproved && notify {
            Notifier.post(title: "All approved", body: "All of your open PRs are approved 🎉")
        }
        prevAllApproved = allApproved
    }

    // MARK: Review actions

    func runReview(id: String) async {
        guard let idx = reviewQueue.firstIndex(where: { $0.id == id }) else { return }
        if reviewQueue[idx].reviewing { return }
        reviewQueue[idx].reviewing = true
        let pr = reviewQueue[idx]
        do {
            let draft = try await ReviewAgent.review(pr, settings: settings)
            if let i = reviewQueue.firstIndex(where: { $0.id == id }) {
                reviewQueue[i].draft = draft
                reviewQueue[i].reviewing = false
            }
            if settings.notifications {
                Notifier.post(title: "Peck reviewed · \(draft.verdict.label)", body: pr.title,
                              subtitle: pr.nameWithNumber)
            }
            if settings.autoSubmit {
                try await github.submitReview(owner: pr.owner, repo: pr.repo, number: pr.number,
                                              verdict: draft.verdict, body: draft.body, comments: draft.comments)
                if let i = reviewQueue.firstIndex(where: { $0.id == id }) { reviewQueue[i].reviewed = true }
            }
        } catch {
            if let i = reviewQueue.firstIndex(where: { $0.id == id }) {
                reviewQueue[i].reviewing = false
                reviewQueue[i].draft = ReviewDraft(
                    summary: "", verdict: .comment, body: "", risks: [], comments: [],
                    model: settings.model, skillsApplied: [], generatedAt: Date(),
                    error: error.localizedDescription)
            }
        }
    }

    func runSelfReview(id: String) async {
        guard let idx = myPrs.firstIndex(where: { $0.id == id }) else { return }
        if myPrs[idx].selfReviewing { return }
        myPrs[idx].selfReviewing = true
        let pr = myPrs[idx]
        do {
            let draft = try await ReviewAgent.selfReview(pr, settings: settings)
            if let i = myPrs.firstIndex(where: { $0.id == id }) {
                myPrs[i].selfReview = draft
                myPrs[i].selfReviewing = false
            }
            storedSelfReviews[id] = draft
            seenMyPrIds?.insert(id)
            persistSelfReviewStore()
            if settings.notifications {
                Notifier.post(title: "Peck self-review · \(draft.verdict.label)", body: pr.title,
                              subtitle: pr.nameWithNumber, userInfo: ["selfReviewPr": id])
            }
        } catch {
            if let i = myPrs.firstIndex(where: { $0.id == id }) {
                myPrs[i].selfReviewing = false
                myPrs[i].selfReview = ReviewDraft(
                    summary: "", verdict: .comment, body: "", risks: [], comments: [],
                    model: settings.model, skillsApplied: [], generatedAt: Date(),
                    error: error.localizedDescription)
            }
        }
    }

    func loadComments(owner: String, repo: String, number: Int, id: String) async {
        if commentsLoading.contains(id) { return }
        commentsLoading.insert(id)
        defer { commentsLoading.remove(id) }
        do {
            prComments[id] = try await github.fetchPrComments(owner: owner, repo: repo, number: number)
            commentsFailed.remove(id)
        } catch {
            commentsFailed.insert(id)
        }
    }

    func submitReview(id: String, verdict: Verdict, body: String, comments: [InlineComment]) async {
        guard let pr = reviewQueue.first(where: { $0.id == id }) else { return }
        do {
            try await github.submitReview(owner: pr.owner, repo: pr.repo, number: pr.number,
                                          verdict: verdict, body: body, comments: comments)
            if let i = reviewQueue.firstIndex(where: { $0.id == id }) { reviewQueue[i].reviewed = true }
            await sync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
