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

    /// Whether the auto-review loop should generate + auto-submit a review for a
    /// pending PR this sync.
    ///
    /// Beyond the obvious guards (already reviewed, draft PR, a draft already
    /// exists, a run in flight) this consults an *auto-submit latch*: the head
    /// commit we last auto-submitted a review at. It closes a re-post loop —
    /// submitting a review bumps the PR's `updatedAt`, which makes `mergeQueue`
    /// drop the local `draft`/`reviewing` guards, and a `COMMENT` verdict never
    /// clears the server `reviewed` flag; without the latch the loop would re-post
    /// the same review every sync. Keying the latch by head commit means a real
    /// new push (head advances) still re-arms review.
    public static func shouldAutoReview(
        reviewed: Bool, isDraft: Bool, hasDraft: Bool, reviewing: Bool,
        latchedHead: String?, currentHead: String?
    ) -> Bool {
        guard !reviewed, !isDraft, !hasDraft, !reviewing else { return false }
        // Already auto-submitted at this exact head commit → don't re-post.
        if let latched = latchedHead, latched == currentHead { return false }
        return true
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
