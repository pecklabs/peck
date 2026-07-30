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
}

/// Optimistic-submission bookkeeping for the review queue, kept pure so the
/// queue-reconciliation rules can be unit-tested without the GitHub API.
///
/// When a reviewer submits a verdict we mark the PR reviewed immediately (the
/// card leaves at once) and record it here as *pending* — locally reviewed but
/// not yet confirmed by a server fetch. The rules below decide how a freshly
/// fetched `reviewed` flag reconciles against those pending marks so that:
///   • a duplicate submission (double-click) is dropped,
///   • a lagging server read can't resurrect a card mid-submit, yet
///   • a genuine re-request (reviewed goes false *after* we saw it confirmed)
///     is still honored.
public struct OptimisticReviews {
    /// PR ids marked reviewed locally, awaiting server confirmation.
    public private(set) var pending: Set<String> = []
    public init() {}

    /// Register an in-flight submission. Returns false when one is already in
    /// flight for this id — the caller should drop the duplicate.
    @discardableResult
    public mutating func begin(_ id: String) -> Bool {
        pending.insert(id).inserted
    }

    /// Undo a submission that failed; the card should reappear.
    public mutating func rollback(_ id: String) {
        pending.remove(id)
    }

    /// Reconcile a freshly fetched `reviewed` flag for one PR.
    ///
    /// While a submission is pending we force `true` so a stale read can't
    /// resurrect the card. The moment the server confirms `reviewed == true`
    /// we drop the pending mark, so a later re-request (which fetches as
    /// `false`) is passed through unchanged.
    public mutating func reconcile(id: String, serverReviewed: Bool) -> Bool {
        guard pending.contains(id) else { return serverReviewed }
        if serverReviewed { pending.remove(id) } // confirmed by the server
        return true
    }

    /// Drop pending marks for ids no longer present in the fetched queue
    /// (merged / closed / fulfilled) so the set can't grow unbounded and a
    /// PR that later returns is reconciled from the server's flag again.
    public mutating func retain(ids: Set<String>) {
        pending.formIntersection(ids)
    }
}
