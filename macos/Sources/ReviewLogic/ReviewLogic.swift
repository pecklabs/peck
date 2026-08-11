import Foundation

/// Pure decision logic for the review queue, split out so it can be unit-tested
/// without hitting the GitHub API.
public enum ReviewLogic {
    /// Whether a PR returned by the `review-requested:@me` search should count as
    /// already reviewed (and thus be hidden from the queue / auto-review / auto-submit).
    ///
    /// A viewer currently in the pending requested-reviewers list always owes a
    /// review — even a re-request at the same head commit (e.g. a `COMMENTED`
    /// reviewer re-requested after replying to threads). Only when the viewer is
    /// *not* currently requested do we fall back to head-commit matching, which
    /// hides stale search results after we've actually reviewed the current head.
    ///
    /// - Parameters:
    ///   - reviewNodes: `reviews` nodes, each `{ author { login }, state, commit { oid } }`.
    ///   - pendingReviewerLogins: logins currently in the PR's `reviewRequests` list.
    ///   - headOid: the PR head commit oid (nil if unknown — then any prior review counts).
    ///   - viewerLogin: the signed-in user's login.
    public static func isAlreadyReviewed(
        reviewNodes: [[String: Any]],
        pendingReviewerLogins: [String],
        headOid: String?,
        viewerLogin: String
    ) -> Bool {
        if pendingReviewerLogins.contains(viewerLogin) { return false }
        return reviewNodes.contains { r in
            let login = (r["author"] as? [String: Any])?["login"] as? String
            let state = r["state"] as? String
            let oid = (r["commit"] as? [String: Any])?["oid"] as? String
            return login == viewerLogin && state != "PENDING" && (headOid == nil || oid == headOid)
        }
    }

    /// Latch value recorded when a review is auto-submitted for a PR whose head
    /// commit oid is unknown (a malformed GraphQL response — a real open PR
    /// always has a commit). A git oid is never empty, so this can't collide with
    /// a real head. It still marks the PR as auto-submitted, so a missing oid
    /// degrades to "review once, don't re-post" rather than re-opening the loop.
    public static let unknownHead = ""

    /// Whether the auto-review loop should generate + auto-submit a review for a
    /// pending PR this sync.
    ///
    /// Beyond the obvious guards (already reviewed, draft PR, a draft already
    /// exists, a run in flight) this consults an *auto-submit latch*: the head
    /// commit we last auto-submitted a review at (`unknownHead` if the oid was
    /// missing). It closes a re-post loop — submitting a review bumps the PR's
    /// `updatedAt`, which makes `mergeQueue` drop the local `draft`/`reviewing`
    /// guards, and a `COMMENT` verdict never clears the server `reviewed` flag;
    /// without the latch the loop would re-post the same review every sync.
    ///
    /// Once latched, we re-review only when the head has advanced to a *known,
    /// different* commit. If either side is unknown (nil / `unknownHead`) we stay
    /// put — a missing oid must never re-open the loop we're closing here.
    public static func shouldAutoReview(
        reviewed: Bool, isDraft: Bool, hasDraft: Bool, reviewing: Bool,
        latchedHead: String?, currentHead: String?
    ) -> Bool {
        guard !reviewed, !isDraft, !hasDraft, !reviewing else { return false }
        // Not yet auto-submitted for this PR → review it.
        guard let latchedHead else { return true }
        // Already auto-submitted; re-review only on a known head advance.
        guard let currentHead, currentHead != unknownHead else { return false }
        return currentHead != latchedHead
    }

    /// Prune the auto-submit latch (PR id → head oid) to the PRs still in the
    /// fetched queue, so it can't grow without bound as PRs merge / close.
    /// Never prunes on an empty id set — a degenerate but "successful" sync would
    /// otherwise wipe every latch at once and let the whole queue re-post.
    public static func prunedLatch(
        _ latch: [String: String], keepingIds ids: Set<String>
    ) -> [String: String] {
        guard !ids.isEmpty else { return latch }
        return latch.filter { ids.contains($0.key) }
    }

    // MARK: Dock badge & presence

    /// The Dock icon's badge text for the current counts: PRs awaiting my review
    /// plus my PRs that need action (the same figures the menu bar shows). `nil`
    /// — no badge — when nothing is pending, so a cleared queue leaves a plain
    /// icon rather than a "0".
    public static func dockBadgeLabel(needsReview: Int, needAction: Int) -> String? {
        let count = needsReview + needAction
        return count > 0 ? "\(count)" : nil
    }

    /// Whether Peck should show a Dock icon (and therefore its badge). Peck is a
    /// menu-bar-only app: it has a Dock presence only while its window is open,
    /// and drops back to a menu-bar accessory once the window closes.
    public static func showsDockIcon(windowVisible: Bool) -> Bool {
        windowVisible
    }

    // MARK: Snooze / feedback detection

    /// The identity of one submitted review: who left it and when. `submittedAt`
    /// stays put when a review is later dismissed (e.g. a stale-approval dismissal
    /// from the author's own push), which is what keeps the fingerprint stable
    /// across the author's pushes.
    public struct ReviewSignal: Equatable {
        public let login: String
        /// When the review was submitted (raw ISO string). A follow-up review by
        /// the same reviewer advances this even at the same verdict; a dismissal
        /// leaves it unchanged.
        public let submittedAt: String?
        public let isBot: Bool
        public init(login: String, submittedAt: String?, isBot: Bool) {
            self.login = login; self.submittedAt = submittedAt; self.isBot = isBot
        }
    }

    /// Version of the fingerprint string format. Persisted alongside snooze /
    /// feedback baselines; bump whenever `feedbackFingerprint`'s output shape
    /// changes so stale baselines from an older format are re-based silently
    /// instead of mass-waking every PR. (v1: counts + login:state. v2: added
    /// per-reviewer submittedAt. v3: identity-only — login:submittedAt of every
    /// non-bot review, no verdict counts/state.)
    public static let fingerprintFormatVersion = 3

    /// A signature of *others'* review activity on a PR: the identity of every
    /// submitted non-bot review, as `login:submittedAt`. Used to tell when a
    /// snoozed PR should wake, or when an awake PR just got feedback.
    ///
    /// Keyed on review *identity*, deliberately NOT on verdict counts or reviewer
    /// state, so nothing the author controls can move it:
    ///   • You can't review your own PR — a new entry means someone else acted.
    ///   • A re-request only adds a *pending* reviewer (no submitted review), so
    ///     it contributes nothing.
    ///   • A stale-approval dismissal from your own push flips a review's state to
    ///     DISMISSED but keeps its `submittedAt` (and it stays in latestReviews),
    ///     so its `login:submittedAt` is unchanged — the fingerprint holds and the
    ///     PR doesn't falsely wake. (Verdict counts would drop here; that's the
    ///     bug this identity keying avoids.)
    /// A genuine new or follow-up review advances that reviewer's `submittedAt`,
    /// which does move the fingerprint.
    ///
    /// Known gap: this sees *reviews*, not plain PR discussion comments, which
    /// aren't in the base sync. A maintainer who only leaves a conversation
    /// comment — without submitting a review — won't move this fingerprint, so a
    /// snoozed PR won't wake on that alone. Reviews and review-comments (the
    /// common case) do wake.
    public static func feedbackFingerprint(reviews: [ReviewSignal]) -> String {
        reviews
            .filter { !$0.isBot }
            .map { "\($0.login):\($0.submittedAt ?? "")" }
            .sorted()
            .joined(separator: ",")
    }

    /// Diff snooze baselines against the current fingerprints. `woke` = snoozed
    /// PRs whose fingerprint changed (a reviewer responded → bring them back);
    /// `closed` = snoozed ids no longer open (merged/closed → stop tracking).
    public static func snoozeChanges(
        baselines: [String: String], current: [String: String]
    ) -> (woke: [String], closed: [String]) {
        var woke: [String] = []
        var closed: [String] = []
        for (id, base) in baselines {
            guard let now = current[id] else { closed.append(id); continue }
            if now != base { woke.append(id) }
        }
        return (woke, closed)
    }

    /// Ids whose fingerprint changed since the previous sync, excluding a skip
    /// set (snoozed PRs and ones that just woke, so a feedback ping never
    /// duplicates the wake ping). Ids absent from `prev` are new PRs, not
    /// feedback, so they never count — which also makes the first sync (empty
    /// `prev`) silent.
    public static func changedIds(
        prev: [String: String], current: [String: String], skipping: Set<String>
    ) -> [String] {
        current.compactMap { id, fp in
            guard !skipping.contains(id), let old = prev[id], old != fp else { return nil }
            return id
        }
    }

    /// The result of reconciling one sync's fingerprints against the stored
    /// baselines — see `reconcileSync`.
    public struct SyncReconciliation: Equatable {
        /// Snoozed PRs a reviewer touched → bring them back and ping.
        public let woke: [String]
        /// Snoozed ids no longer open (merged/closed) → stop tracking.
        public let closedSnoozed: [String]
        /// Awake PRs that got feedback → ping (already excludes woke/snoozed).
        public let awakeFeedback: [String]
        /// Snooze baselines after this sync (woke + closed removed).
        public let newSnoozed: [String: String]
        /// Awake-feedback baseline after this sync (always the current prints).
        public let newFingerprints: [String: String]
        /// This sync re-based stale-format baselines: the caller should persist
        /// the stores AND stamp the current format version (atomically, so a crash
        /// before the stamp just re-migrates next launch — the re-base is
        /// idempotent). No wake / feedback is reported on a migration sync.
        public let migratedFormat: Bool
        public init(woke: [String], closedSnoozed: [String], awakeFeedback: [String],
                    newSnoozed: [String: String], newFingerprints: [String: String],
                    migratedFormat: Bool = false) {
            self.woke = woke; self.closedSnoozed = closedSnoozed; self.awakeFeedback = awakeFeedback
            self.newSnoozed = newSnoozed; self.newFingerprints = newFingerprints
            self.migratedFormat = migratedFormat
        }
    }

    /// The steady-state feedback reconciliation for one sync, kept pure so the
    /// ordering AND the format migration that AppModel relies on are unit-testable.
    /// Only the account switch is handled by the caller (it's about user identity).
    ///
    /// Given the snooze baselines, the previous awake baseline (`nil` on the very
    /// first sync), the freshly computed fingerprints, and the stored vs current
    /// fingerprint-format versions, it decides:
    ///   • FORMAT MIGRATION first: if the stored baselines predate the current
    ///     fingerprint format, they'd all mismatch and mass-wake. Re-base the
    ///     snoozed set in place (drop closed), reset the awake baseline to current,
    ///     report nothing, and flag `migratedFormat` so the caller stamps the
    ///     version. Done atomically with the persist, so a crash before stamping
    ///     just re-migrates (idempotent) instead of comparing stale baselines.
    ///   • else STEADY STATE: which snoozed PRs wake (fingerprint moved) or drop
    ///     (no longer open); which *awake* PRs to ping — only when
    ///     `notifyAwakeFeedback`, never for anything snoozed or just-woken (no
    ///     double ping), and never on the first sync (`nil` prev). The awake
    ///     baseline advances every sync even with the toggle off, so enabling it
    ///     later doesn't dump a backlog.
    public static func reconcileSync(
        snoozed: [String: String],
        previousFingerprints: [String: String]?,
        current: [String: String],
        notifyAwakeFeedback: Bool,
        storedFormatVersion: Int?,
        currentFormatVersion: Int
    ) -> SyncReconciliation {
        if storedFormatVersion != currentFormatVersion {
            // Re-base the still-open snoozed PRs to their current fingerprint and
            // reset the awake baseline — silently. Nothing is "feedback" here.
            let rebased = snoozed.reduce(into: [String: String]()) { acc, kv in
                if let fp = current[kv.key] { acc[kv.key] = fp }
            }
            return SyncReconciliation(
                woke: [], closedSnoozed: [], awakeFeedback: [],
                newSnoozed: rebased, newFingerprints: current, migratedFormat: true)
        }

        let (woke, closed) = snoozeChanges(baselines: snoozed, current: current)
        var newSnoozed = snoozed
        for id in woke { newSnoozed[id] = nil }
        for id in closed { newSnoozed[id] = nil }

        let awake: [String]
        if notifyAwakeFeedback, let prev = previousFingerprints {
            // Skip everything that was snoozed (woke ⊆ snoozed) — the snooze path
            // owns those pings.
            awake = changedIds(prev: prev, current: current, skipping: Set(snoozed.keys))
        } else {
            awake = []
        }

        return SyncReconciliation(
            woke: woke, closedSnoozed: closed, awakeFeedback: awake,
            newSnoozed: newSnoozed, newFingerprints: current)
    }
}

/// Optimistic-submission bookkeeping for the review queue, kept pure so the
/// queue-reconciliation rules can be unit-tested without the GitHub API.
///
/// Two concerns are tracked separately:
///   • `inFlight` — any submission in progress, so a double-click is dropped.
///     Taken at `begin`, the instant a verdict is hit.
///   • `pending`  — PRs shown reviewed optimistically, awaiting server
///                  confirmation. Marked at `retire`, only *after* the
///                  deliberate loading beat elapses and only for verdicts that
///                  fulfill the request (Approve / Request changes). A Comment
///                  review does NOT retire the card: GitHub keeps you a
///                  requested reviewer and the server stays `reviewed == false`,
///                  so forcing it would hide a PR you still owe a verdict on.
///
/// Splitting `begin` (lock now) from `retire` (mark pending later) matters: the
/// card is held on screen with a spinner during the beat, so marking it pending
/// up front would let a background sync landing mid-beat clear the card early.
///
/// The rules ensure that a lagging server read can't resurrect a retired card
/// mid-submit, yet a genuine re-request (reviewed goes false *after* the server
/// confirmed the review) is still honored.
public struct OptimisticReviews {
    /// Ids with a submission in flight — drives double-click dedup.
    public private(set) var inFlight: Set<String> = []
    /// Ids shown reviewed optimistically until a server fetch confirms them.
    public private(set) var pending: Set<String> = []
    public init() {}

    /// Take the in-flight lock for a submission. Returns false when one is
    /// already in flight for this id — the caller should drop the duplicate.
    /// Every verdict (including Comment) takes the lock so double-clicks are
    /// dropped; retiring the card is a separate step (`retire`).
    @discardableResult
    public mutating func begin(_ id: String) -> Bool {
        inFlight.insert(id).inserted
    }

    /// Optimistically mark a PR reviewed once its loading beat has elapsed, so a
    /// lagging server read can't resurrect the card. Called only for verdicts
    /// that fulfill the request (Approve / Request changes); a Comment leaves
    /// the card and never retires. Deferred until after the beat so a background
    /// sync during the beat doesn't clear the card early.
    public mutating func retire(_ id: String) {
        pending.insert(id)
    }

    /// Release the in-flight lock after a submission succeeds. Any optimistic
    /// `pending` mark stays until a server fetch confirms it, so a later
    /// submission for the same PR (e.g. a re-request) is allowed again.
    public mutating func finish(_ id: String) {
        inFlight.remove(id)
    }

    /// Undo a submission that failed; the card reappears and re-submit is allowed.
    public mutating func rollback(_ id: String) {
        inFlight.remove(id)
        pending.remove(id)
    }

    /// Reconcile a freshly fetched `reviewed` flag for one PR.
    ///
    /// While a submission is pending we force `true` so a stale read can't
    /// resurrect the card. The moment the server confirms `reviewed == true`
    /// we drop the pending mark, so a later re-request (which fetches as
    /// `false`) is passed through unchanged. PRs that were never optimistically
    /// retired (Comment reviews, untracked PRs) always pass through as-is.
    public mutating func reconcile(id: String, serverReviewed: Bool) -> Bool {
        guard pending.contains(id) else { return serverReviewed }
        if serverReviewed { pending.remove(id) } // confirmed by the server
        return true
    }

    /// Drop marks for ids no longer present in the fetched queue (merged /
    /// closed / fulfilled) so the sets can't grow unbounded and a PR that later
    /// returns is reconciled from the server's flag again.
    public mutating func retain(ids: Set<String>) {
        pending.formIntersection(ids)
        inFlight.formIntersection(ids)
    }
}

/// Renders a review as plain text for copy-to-clipboard: a title line, the
/// summary, then a bulleted fix list (omitted when there are no risks). Kept
/// UI-free so the formatting can be unit-tested.
public func reviewPlainText(
    title: String,
    summary: String,
    risks: [String],
    fixesHeader: String
) -> String {
    var lines = [title, "", summary]
    if !risks.isEmpty {
        lines.append("")
        lines.append("\(fixesHeader):")
        for risk in risks { lines.append("• \(risk)") }
    }
    return lines.joined(separator: "\n")
}
