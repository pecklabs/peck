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
