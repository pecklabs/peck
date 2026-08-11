import Foundation
import SwiftUI
import AppKit
import ReviewLogic
#if canImport(Sparkle)
import Sparkle
#endif

extension ThemeMode {
    /// The AppKit appearance to force, or nil to follow the macOS setting.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

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

    /// Demo/preview runs (PECK_DEMO=1): submitReview keeps the optimistic removal
    /// but skips the GitHub call + sync, so the card-dismissal animation can be
    /// seen against mock data without touching a real repo. Inert in normal use.
    var demoMode = false
    /// PECK_DEMO_FAIL=1: make demo submissions fail, to exercise the rollback +
    /// error path (card restored, errorMessage shown) without a real repo.
    var demoFails = false

    /// Optimistic review submissions: a PR is marked reviewed the instant its
    /// verdict is submitted (the card clears at once) and held here until a
    /// server fetch confirms it, so a lagging read can't resurrect the card and
    /// a double-click can't fire a second submission. See ReviewLogic tests.
    private var optimistic = OptimisticReviews()

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
    /// GitHub login the persisted self-review store belongs to.
    private var selfReviewOwner: String?

    /// Snoozed PRs of mine: id → the feedback fingerprint captured when it was
    /// snoozed. Keys are the snoozed set (hidden from the queue, tray count, and
    /// banners); Peck keeps polling them and wakes one the moment its fingerprint
    /// changes — i.e. a reviewer leaves feedback. Persisted, account-scoped.
    @Published private(set) var snoozed: [String: String] = [:]
    /// GitHub login the snooze store belongs to.
    private var snoozeOwner: String?

    /// Last-seen feedback fingerprint per PR id, for detecting feedback on *awake*
    /// PRs (the snooze path handles snoozed ones). Persisted so feedback that
    /// arrives while the app is closed is still caught on the next launch. nil
    /// until the first baseline, so the initial sync doesn't fire a backlog.
    private var lastFingerprints: [String: String]?
    /// GitHub login the fingerprint baseline belongs to.
    private var feedbackOwner: String?

    /// PR id → head commit oid we last AUTO-submitted a review at. Persisted so a
    /// relaunch doesn't re-post, and keyed by head so a new commit re-arms review.
    /// Guards the auto-review loop against re-firing after its own post bumps
    /// `updatedAt` (and, for COMMENT verdicts, never clears server `reviewed`).
    private var autoSubmittedHeads: [String: String] = [:]
    /// GitHub login the auto-submit latch belongs to.
    private var autoSubmitOwner: String?

    private let settingsKey = "settings"
    private let selfReviewSeenKey = "selfReviewSeen"
    private let selfReviewDraftsKey = "selfReviewDrafts"
    private let selfReviewOwnerKey = "selfReviewOwner"
    private let autoSubmittedHeadsKey = "autoSubmittedHeads"
    private let autoSubmitOwnerKey = "autoSubmitOwner"
    private let snoozedPrsKey = "snoozedPrs"
    private let snoozeOwnerKey = "snoozeOwner"
    private let lastFingerprintsKey = "lastFingerprints"
    private let feedbackOwnerKey = "feedbackOwner"
    private let fingerprintVersionKey = "fingerprintFormatVersion"
    /// The fingerprint format version the persisted baselines were written with
    /// (nil = never stamped). Compared against the current version each sync;
    /// reconcileFeedback re-bases and re-stamps atomically on a mismatch.
    private var storedFingerprintVersion: Int?

    init() {
        loadSettings()
        I18n.lang = settings.uiLanguage
        skills = Skills.info()
        hasAnthropicKey = Keychain.has(.anthropicKey)
        loadSelfReviewStore()
        loadAutoReviewStore()
        loadSnoozeStore()
        loadFeedbackStore()
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
        selfReviewOwner = UserDefaults.standard.string(forKey: selfReviewOwnerKey)
    }

    private func persistSelfReviewStore() {
        if let seen = seenMyPrIds, let data = try? JSONEncoder().encode(seen) {
            UserDefaults.standard.set(data, forKey: selfReviewSeenKey)
        }
        if let data = try? JSONEncoder().encode(storedSelfReviews) {
            UserDefaults.standard.set(data, forKey: selfReviewDraftsKey)
        }
        UserDefaults.standard.set(selfReviewOwner, forKey: selfReviewOwnerKey)
    }

    private func loadSnoozeStore() {
        if let data = UserDefaults.standard.data(forKey: snoozedPrsKey),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            snoozed = map
        }
        snoozeOwner = UserDefaults.standard.string(forKey: snoozeOwnerKey)
    }

    private func persistSnoozeStore() {
        if let data = try? JSONEncoder().encode(snoozed) {
            UserDefaults.standard.set(data, forKey: snoozedPrsKey)
        }
        UserDefaults.standard.set(snoozeOwner, forKey: snoozeOwnerKey)
    }

    private func loadFeedbackStore() {
        if let data = UserDefaults.standard.data(forKey: lastFingerprintsKey),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            lastFingerprints = map
        }
        feedbackOwner = UserDefaults.standard.string(forKey: feedbackOwnerKey)
        storedFingerprintVersion = UserDefaults.standard.object(forKey: fingerprintVersionKey) as? Int
    }

    private func persistFeedbackStore() {
        if let prints = lastFingerprints, let data = try? JSONEncoder().encode(prints) {
            UserDefaults.standard.set(data, forKey: lastFingerprintsKey)
        }
        UserDefaults.standard.set(feedbackOwner, forKey: feedbackOwnerKey)
    }

    private func loadAutoReviewStore() {
        if let data = UserDefaults.standard.data(forKey: autoSubmittedHeadsKey),
           let heads = try? JSONDecoder().decode([String: String].self, from: data) {
            autoSubmittedHeads = heads
        }
        autoSubmitOwner = UserDefaults.standard.string(forKey: autoSubmitOwnerKey)
    }

    private func persistAutoReviewStore() {
        if let data = try? JSONEncoder().encode(autoSubmittedHeads) {
            UserDefaults.standard.set(data, forKey: autoSubmittedHeadsKey)
        }
        UserDefaults.standard.set(autoSubmitOwner, forKey: autoSubmitOwnerKey)
    }

    func bootstrap() {
        AppPaths.ensure()
        applyThemeMode()
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
        let themeChanged = next.themeMode != settings.themeMode
        persist(next)
        if intervalChanged && connected { schedulePolling() }
        if themeChanged { applyThemeMode() }
    }

    /// Force the app's appearance from the saved preference. Our GitHub-Primer
    /// colors are AppKit *dynamic* NSColors that resolve against the current
    /// `NSApp.appearance`, so setting it here recolors the popover, the window,
    /// and any other host in one shot. `.system` (nil) hands control back to macOS.
    func applyThemeMode() {
        NSApp.appearance = settings.themeMode.nsAppearance
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
            reconcileFeedback()
            connected = true
            errorMessage = nil
            lastSync = Date()
            recomputeTray()
            // Passing visibleMyPrs (not myPrs) is deliberate: a snoozed PR stays
            // fully quiet — no conflict / all-approved alerts either, not just no
            // feedback ping. "Snooze" means silent until a reviewer responds; a
            // merge conflict on a snoozed PR intentionally waits until it wakes.
            // (This also means a woken PR re-entering here can't double-fire, since
            // handleNotifications posts no "feedback" alert of its own.)
            handleNotifications(queue: reviewQueue, myPrs: visibleMyPrs)
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
            // submitting is a local in-flight flag, not server content, so keep it
            // regardless of updatedAt: a sync landing mid-beat (even one that also
            // brings new PR activity) must not flicker the spinner off. submitReview
            // clears it when the beat ends (or on rollback).
            if let old = prev[r.id], old.submitting { r.submitting = true }
            // Keep an optimistically-submitted PR reviewed until the server
            // confirms it, so a fetch landing before the review propagates
            // doesn't resurrect the card. Confirmation clears the pending mark.
            r.reviewed = optimistic.reconcile(id: r.id, serverReviewed: r.reviewed)
            return r
        }
        // Forget pending marks for PRs that dropped out of the queue entirely.
        optimistic.retain(ids: Set(incoming.map(\.id)))
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
        guard let login = user?.login else { return }
        // The persisted store belongs to one GitHub account. On a different
        // login, start over — otherwise the stale baseline would mass-trigger
        // agent runs on every open PR of the new account.
        if selfReviewOwner != login {
            selfReviewOwner = login
            seenMyPrIds = nil
            storedSelfReviews = [:]
        }

        let ready = Set(myPrs.filter { !$0.isDraft }.map(\.id))
        if seenMyPrIds == nil {
            // Very first sync for this account: baseline, don't review-bomb
            // existing PRs.
            seenMyPrIds = ready
        } else if settings.selfReview && agentAvailable {
            for p in myPrs where !p.isDraft && !(seenMyPrIds?.contains(p.id) ?? false)
                && p.selfReview == nil && !p.selfReviewing {
                Task { await self.runSelfReview(id: p.id) }
            }
            seenMyPrIds?.formUnion(ready)
        }
        // Drop stored results for PRs that are no longer open — but never on an
        // empty list, where a degenerate (yet "successful") sync would wipe
        // every stored result at once.
        if !myPrs.isEmpty {
            let openIds = Set(myPrs.map(\.id))
            storedSelfReviews = storedSelfReviews.filter { openIds.contains($0.key) }
        }
        persistSelfReviewStore()
    }

    // MARK: Snooze (mute a PR until a reviewer touches it)

    /// My PRs currently visible in the queue — snoozed ones are held aside.
    var visibleMyPrs: [MyPullRequest] { myPrs.filter { snoozed[$0.id] == nil } }
    /// My PRs the user has snoozed and Peck is watching quietly.
    var snoozedMyPrs: [MyPullRequest] { myPrs.filter { snoozed[$0.id] != nil } }

    /// Snooze a PR: drop it from the queue and record its current feedback
    /// fingerprint as the baseline to wake against.
    func snooze(id: String) {
        guard let pr = myPrs.first(where: { $0.id == id }) else { return }
        snoozed[id] = pr.feedbackFingerprint
        persistSnoozeStore()
        recomputeTray()
    }

    /// Wake a PR back into the queue (manual un-snooze).
    func unsnooze(id: String) {
        guard snoozed.removeValue(forKey: id) != nil else { return }
        persistSnoozeStore()
        recomputeTray()
    }

    /// Empty the whole snooze list — every snoozed PR returns to the queue.
    func unsnoozeAll() {
        guard !snoozed.isEmpty else { return }
        snoozed = [:]
        persistSnoozeStore()
        recomputeTray()
    }

    /// Run each sync after `myPrs` is merged: handle the account switch and the
    /// fingerprint-format migration (both AppModel-stateful), then apply the pure
    /// reconciliation (`ReviewLogic.reconcileSync`) and fire its notifications —
    /// a wake ping for snoozed PRs a reviewer touched, and (when the toggle is on)
    /// a feedback ping for awake PRs. See `ReviewLogic.reconcileSync` for the
    /// ordering / skip / first-sync guarantees.
    private func reconcileFeedback() {
        guard let login = user?.login else { return }

        // Each store belongs to one account; a switch starts fresh so a previous
        // user's baselines can't suppress or falsely wake this user's PRs.
        if snoozeOwner != login {
            snoozeOwner = login
            if !snoozed.isEmpty { snoozed = [:] }
        }
        if feedbackOwner != login {
            feedbackOwner = login
            lastFingerprints = nil
        }

        let current = Dictionary(uniqueKeysWithValues: myPrs.map { ($0.id, $0.feedbackFingerprint) })
        let result = ReviewLogic.reconcileSync(
            snoozed: snoozed,
            previousFingerprints: lastFingerprints,
            current: current,
            notifyAwakeFeedback: settings.notifications && settings.notifyMyPrFeedback,
            storedFormatVersion: storedFingerprintVersion,
            currentFormatVersion: ReviewLogic.fingerprintFormatVersion)

        snoozed = result.newSnoozed
        lastFingerprints = result.newFingerprints
        persistSnoozeStore()
        persistFeedbackStore()
        // Stamp the format version LAST, only once the re-based baselines are
        // persisted — so a crash between the two just re-migrates next launch
        // (the re-base is idempotent) instead of leaving stale baselines under a
        // fresh version number.
        if result.migratedFormat {
            storedFingerprintVersion = ReviewLogic.fingerprintFormatVersion
            UserDefaults.standard.set(ReviewLogic.fingerprintFormatVersion, forKey: fingerprintVersionKey)
        }

        postMyPrFeedback(result.woke)          // snoozed → woke: always ping (hidden PRs)
        postMyPrFeedback(result.awakeFeedback) // awake → already gated on the toggle
    }

    private func recomputeTray() {
        tray = TrayStatus.derive(connected: connected, queue: reviewQueue, myPrs: visibleMyPrs)
        updateDockBadge()
    }

    /// Mirror the menu-bar counts onto the Dock icon's badge: PRs awaiting my
    /// review plus my PRs that need action. Peck only has a Dock icon while its
    /// window is open, so this only shows there — a no-op the rest of the time.
    ///
    /// `badgeLabel` only paints if the app requested `.badge` notification
    /// authorization at least once (macOS 12+ silently drops it otherwise) — see
    /// `Notifier.requestAuthorization`.
    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = ReviewLogic.dockBadgeLabel(
            needsReview: tray.needsReview, needAction: tray.needAction)
    }

    // MARK: Dock presence

    /// Whether the standalone window is currently on screen. PeckWindow keeps
    /// this in sync so the Dock policy has a single source of truth.
    private var windowVisible = false

    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        applyDockPolicy()
    }

    /// A Dock icon (and its badge) only while the window is up; otherwise Peck is
    /// a menu-bar-only accessory with no Dock presence.
    func applyDockPolicy() {
        let showsIcon = ReviewLogic.showsDockIcon(windowVisible: windowVisible)
        NSApp.setActivationPolicy(showsIcon ? .regular : .accessory)
        // The Dock tile may have just appeared; stamp the current count so the
        // badge is right the instant the icon shows.
        updateDockBadge()
    }

    /// Ping the user that a reviewer left feedback on their PR — used for both a
    /// snoozed PR waking and an awake PR getting feedback (same message; tapping
    /// it opens My PRs on that PR).
    private func postMyPrFeedback(_ ids: [String]) {
        guard settings.notifications, !ids.isEmpty else { return }
        for id in ids {
            guard let pr = myPrs.first(where: { $0.id == id }) else { continue }
            Notifier.post(title: I18n.isKorean ? "💬 내 PR에 피드백" : "💬 Feedback on your PR",
                          body: pr.title, subtitle: pr.nameWithNumber,
                          userInfo: ["focusMyPr": id])
        }
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
        // Auto-submit latch maintenance runs OUTSIDE the autoReview gate: the
        // latch is written by ANY successful auto-submit — including a manual
        // review with auto-submit on while autoReview is off — so its account
        // scoping and bounding must not depend on autoReview being enabled.
        // - Reset on a different login so a stale latch can't suppress the new
        //   account's PRs.
        // - Prune to the current queue so merged / closed PRs don't accumulate
        //   forever; never on an empty queue (see prunedLatch).
        if let login = user?.login, autoSubmitOwner != login {
            autoSubmitOwner = login
            autoSubmittedHeads = [:]
        }
        autoSubmittedHeads = ReviewLogic.prunedLatch(
            autoSubmittedHeads, keepingIds: Set(queue.map(\.id)))
        persistAutoReviewStore()

        if settings.autoReview {
            for r in queue where ReviewLogic.shouldAutoReview(
                reviewed: r.reviewed, isDraft: r.isDraft, hasDraft: r.draft != nil,
                reviewing: r.reviewing, latchedHead: autoSubmittedHeads[r.id], currentHead: r.headOid) {
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
                // In-flight lock so an overlapping sync can't fire a second POST.
                // If a new commit lands mid-run, mergeQueue wipes the `reviewing`
                // guard; this lock (which mergeQueue can't touch) still holds.
                // A manual submit in flight for the same PR also takes it, so the
                // two never double-post. Dropped runs leave state intact (the
                // draft is already set above); the holder posts.
                guard optimistic.begin(id) else { return }
                do {
                    try await github.submitReview(owner: pr.owner, repo: pr.repo, number: pr.number,
                                                  verdict: draft.verdict, body: draft.body, comments: draft.comments)
                    if let i = reviewQueue.firstIndex(where: { $0.id == id }) {
                        reviewQueue[i].reviewed = true
                        // Latch the posted head so the loop won't re-post at this
                        // commit even after the post bumps updatedAt / a COMMENT
                        // leaves reviewed == false. Only after a *successful* post,
                        // so a failed post is retried on a later sync. A missing
                        // oid still latches (unknownHead) so it can't re-open the
                        // loop — it just won't re-arm until a known head lands.
                        autoSubmittedHeads[id] = reviewQueue[i].headOid ?? ReviewLogic.unknownHead
                        persistAutoReviewStore()
                    }
                    optimistic.finish(id)
                } catch {
                    optimistic.rollback(id)
                    throw error
                }
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
        } catch is CancellationError {
            // Selection changed and .task cancelled us — not a failure.
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            commentsFailed.insert(id)
        }
    }

    /// A deliberate beat between hitting a verdict and the card leaving. An
    /// instant clear read as a flicker — too fast to register as "submitted" —
    /// so the card holds a spinner for this long, then animates out. The real
    /// submit + sync still run afterwards in the background; the card never waits
    /// on the network round trip (that's the optimistic part).
    ///
    /// Randomized per submission so the hold doesn't feel mechanically uniform;
    /// each verdict picks a fresh duration within this range.
    private let submitBeatRange: ClosedRange<UInt64> = 400_000_000...800_000_000

    func submitReview(id: String, verdict: Verdict, body: String, comments: [InlineComment]) async {
        guard let idx = reviewQueue.firstIndex(where: { $0.id == id }) else { return }
        // A Comment review doesn't fulfill the request — GitHub keeps you a
        // requested reviewer and the server stays reviewed == false — so the card
        // must remain. Only Approve / Request changes retire the card.
        let retires = verdict != .comment
        // Drop duplicate submissions (double-clicks, or a click that slips through
        // before the button's disabled state renders).
        guard optimistic.begin(id) else { return }
        // Show the loading spinner and hold the card for a deliberate beat. No
        // pending mark yet, so a background sync landing during the beat can't
        // clear the card early — it stays put, spinner and all.
        reviewQueue[idx].submitting = true
        let pr = reviewQueue[idx]

        try? await Task.sleep(nanoseconds: UInt64.random(in: submitBeatRange))

        // Beat elapsed: drop the spinner and, for a fulfilling verdict, clear the
        // card optimistically. retire() marks it pending only now, so mergeQueue
        // holds it reviewed until the server confirms and a lagging read can't
        // resurrect it.
        if let i = reviewQueue.firstIndex(where: { $0.id == id }) {
            reviewQueue[i].submitting = false
            if retires { reviewQueue[i].reviewed = true }
        }
        if retires { optimistic.retire(id) }

        if demoMode {
            if demoFails {
                rollbackReview(id: id, retires: retires, message: "Demo: submission failed")
            } else {
                optimistic.finish(id) // no server in demo — release the lock like a success
            }
            return
        }
        do {
            try await github.submitReview(owner: pr.owner, repo: pr.repo, number: pr.number,
                                          verdict: verdict, body: body, comments: comments)
            await sync()
            optimistic.finish(id)
        } catch {
            rollbackReview(id: id, retires: retires, message: error.localizedDescription)
        }
    }

    /// Undo a failed optimistic submission: release the locks, drop the spinner,
    /// restore the card (only verdicts that retired it flipped `reviewed`), and
    /// surface the error.
    private func rollbackReview(id: String, retires: Bool, message: String) {
        optimistic.rollback(id)
        if let i = reviewQueue.firstIndex(where: { $0.id == id }) {
            reviewQueue[i].submitting = false
            if retires { reviewQueue[i].reviewed = false }
        }
        errorMessage = message
    }
}
