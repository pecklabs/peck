import XCTest
@testable import ReviewLogic

/// Regression coverage for the "re-requested review dropped at the same head
/// commit" bug. `reviewed == true` hides a PR from the queue, auto-review, and
/// auto-submit, so these cases pin down exactly when that may happen.
final class ReviewLogicTests: XCTestCase {
    let me = "jinyungChoi"
    let head = "2b3c1c0"

    private func review(_ login: String, _ state: String, _ oid: String) -> [String: Any] {
        ["author": ["login": login], "state": state, "commit": ["oid": oid]]
    }

    // Fresh request, nothing reviewed yet: viewer is pending → owes a review.
    func testFreshRequestIsNotReviewed() {
        let reviewed = ReviewLogic.isAlreadyReviewed(
            reviewNodes: [],
            pendingReviewerLogins: [me],
            headOid: head, viewerLogin: me)
        XCTAssertFalse(reviewed)
    }

    // The bug: a COMMENTED review at head, then re-requested with no new commit.
    // Old review oid == head, but viewer is back in the pending list → must NOT
    // be treated as reviewed.
    func testReRequestAtSameHeadIsNotReviewed() {
        let reviewed = ReviewLogic.isAlreadyReviewed(
            reviewNodes: [review(me, "COMMENTED", head)],
            pendingReviewerLogins: [me],
            headOid: head, viewerLogin: me)
        XCTAssertFalse(reviewed)
    }

    // Re-requested after a new commit was pushed: old review is on a stale oid
    // and viewer is pending → owes a review.
    func testReRequestAfterNewCommitIsNotReviewed() {
        let reviewed = ReviewLogic.isAlreadyReviewed(
            reviewNodes: [review(me, "COMMENTED", "old111")],
            pendingReviewerLogins: [me],
            headOid: head, viewerLogin: me)
        XCTAssertFalse(reviewed)
    }

    // Already reviewed the current head and NOT re-requested: the search result
    // is just stale → hide it. This is the fallback we must preserve.
    func testReviewedHeadWhenNotPendingIsReviewed() {
        let reviewed = ReviewLogic.isAlreadyReviewed(
            reviewNodes: [review(me, "APPROVED", head)],
            pendingReviewerLogins: [],
            headOid: head, viewerLogin: me)
        XCTAssertTrue(reviewed)
    }

    // Reviewed only an old commit and not currently pending → not reviewed at head.
    func testReviewedOldCommitWhenNotPendingIsNotReviewed() {
        let reviewed = ReviewLogic.isAlreadyReviewed(
            reviewNodes: [review(me, "APPROVED", "old111")],
            pendingReviewerLogins: [],
            headOid: head, viewerLogin: me)
        XCTAssertFalse(reviewed)
    }

    // Someone else being pending doesn't make my stale-at-head review re-open.
    func testAnotherReviewerPendingDoesNotAffectMe() {
        let reviewed = ReviewLogic.isAlreadyReviewed(
            reviewNodes: [review(me, "APPROVED", head)],
            pendingReviewerLogins: ["kyo504"],
            headOid: head, viewerLogin: me)
        XCTAssertTrue(reviewed)
    }

    // A PENDING (unsubmitted) review never counts as reviewed.
    func testPendingReviewDoesNotCount() {
        let reviewed = ReviewLogic.isAlreadyReviewed(
            reviewNodes: [review(me, "PENDING", head)],
            pendingReviewerLogins: [],
            headOid: head, viewerLogin: me)
        XCTAssertFalse(reviewed)
    }
}
