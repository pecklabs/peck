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

/// Auto-review re-fire guard. Auto-submitting a review bumps the PR's
/// `updatedAt` (wiping the local draft/reviewing guards in mergeQueue) and a
/// COMMENT verdict never clears the server `reviewed` flag — so without a latch
/// the loop re-posts every sync. These pin down exactly when it may re-review.
final class AutoReviewLatchTests: XCTestCase {
    let head = "2b3c1c0"
    let pr = "acme/web#137"

    // Fresh pending PR, never auto-submitted → review it.
    func testFreshPendingPRIsReviewed() {
        XCTAssertTrue(ReviewLogic.shouldAutoReview(
            reviewed: false, isDraft: false, hasDraft: false, reviewing: false,
            latchedHead: nil, currentHead: head))
    }

    // The core fix: already auto-submitted at this exact head → do NOT re-post,
    // even though `reviewed` came back false and the draft/reviewing guards were
    // wiped by the updatedAt bump. This is the COMMENT infinite-loop regression.
    func testLatchedAtSameHeadIsSkipped() {
        XCTAssertFalse(ReviewLogic.shouldAutoReview(
            reviewed: false, isDraft: false, hasDraft: false, reviewing: false,
            latchedHead: head, currentHead: head))
    }

    // A new commit advances the head → latch no longer matches → re-review.
    func testNewHeadReArmsReview() {
        XCTAssertTrue(ReviewLogic.shouldAutoReview(
            reviewed: false, isDraft: false, hasDraft: false, reviewing: false,
            latchedHead: "old111", currentHead: head))
    }

    // Server already reports the PR reviewed → skip regardless of the latch.
    func testReviewedPRIsSkipped() {
        XCTAssertFalse(ReviewLogic.shouldAutoReview(
            reviewed: true, isDraft: false, hasDraft: false, reviewing: false,
            latchedHead: nil, currentHead: head))
    }

    // Draft PRs aren't reviewed until marked ready.
    func testDraftPRIsSkipped() {
        XCTAssertFalse(ReviewLogic.shouldAutoReview(
            reviewed: false, isDraft: true, hasDraft: false, reviewing: false,
            latchedHead: nil, currentHead: head))
    }

    // An existing draft (including an errored one) is left alone — manual retry,
    // so the loop can't spin on a failing agent.
    func testExistingDraftIsSkipped() {
        XCTAssertFalse(ReviewLogic.shouldAutoReview(
            reviewed: false, isDraft: false, hasDraft: true, reviewing: false,
            latchedHead: nil, currentHead: head))
    }

    // A run already in flight → don't dispatch a second.
    func testInFlightReviewIsSkipped() {
        XCTAssertFalse(ReviewLogic.shouldAutoReview(
            reviewed: false, isDraft: false, hasDraft: false, reviewing: true,
            latchedHead: nil, currentHead: head))
    }

    // Prune drops latch entries for PRs no longer in the queue (merged / closed),
    // so the map can't grow without bound.
    func testPruneDropsClosedPRs() {
        let pruned = ReviewLogic.prunedLatch(
            [pr: head, "acme/api#92": "z9"], keepingIds: [pr])
        XCTAssertEqual(pruned, [pr: head])
    }

    // Never prune on an empty queue: a degenerate but "successful" sync would
    // otherwise wipe every latch and let the whole queue re-post.
    func testPruneKeepsAllOnEmptyQueue() {
        let latch = [pr: head]
        XCTAssertEqual(ReviewLogic.prunedLatch(latch, keepingIds: []), latch)
    }
}

/// Optimistic review-submission state machine — mirrors AppModel.submitReview /
/// mergeQueue, so the risky "clear the card before the server confirms" path is
/// covered without the GitHub API.
final class OptimisticReviewsTests: XCTestCase {
    let pr = "acme/web#137"

    // Happy path: an Approve / Request changes retires the card once its beat
    // elapses, marking the PR pending (card cleared optimistically).
    func testRetireMarksPending() {
        var o = OptimisticReviews()
        XCTAssertTrue(o.begin(pr))
        XCTAssertFalse(o.pending.contains(pr)) // not until the beat elapses
        o.retire(pr)
        XCTAssertTrue(o.pending.contains(pr))
    }

    // The loading beat: begin takes the lock but leaves the card visible, so a
    // sync landing mid-beat reconciles from the server flag (card stays).
    func testBeginAloneKeepsCardVisibleDuringBeat() {
        var o = OptimisticReviews()
        o.begin(pr)
        XCTAssertFalse(o.pending.contains(pr))
        XCTAssertFalse(o.reconcile(id: pr, serverReviewed: false)) // card stays
    }

    // Double-click: a second submit while one is in flight is dropped.
    func testBeginDropsDuplicateSubmission() {
        var o = OptimisticReviews()
        XCTAssertTrue(o.begin(pr))
        XCTAssertFalse(o.begin(pr))
    }

    // A Comment review does NOT retire the card: GitHub keeps you a requested
    // reviewer (server stays reviewed == false), so reconcile must pass that
    // through and the card must stay visible. Comment never calls retire.
    func testCommentKeepsCardVisible() {
        var o = OptimisticReviews()
        o.begin(pr)
        XCTAssertFalse(o.pending.contains(pr))
        XCTAssertFalse(o.reconcile(id: pr, serverReviewed: false)) // card stays
    }

    // finish() releases only the in-flight lock, so a later submission (e.g. an
    // Approve after commenting) is allowed while any pending mark survives.
    func testFinishReleasesLockButKeepsPending() {
        var o = OptimisticReviews()
        o.begin(pr)
        o.retire(pr)
        o.finish(pr)
        XCTAssertFalse(o.inFlight.contains(pr))
        XCTAssertTrue(o.pending.contains(pr)) // still awaiting confirmation
        XCTAssertTrue(o.begin(pr))            // re-submit allowed
    }

    // Failure → rollback: after rollback the server flag passes through, so the
    // card reappears (reconcile returns the fetched value, not a forced true).
    func testRollbackRestoresServerFlag() {
        var o = OptimisticReviews()
        o.begin(pr)
        o.retire(pr)
        o.rollback(pr)
        XCTAssertFalse(o.inFlight.contains(pr))
        XCTAssertFalse(o.reconcile(id: pr, serverReviewed: false))
    }

    // The timing window: a fetch that lands after the beat (card retired) but
    // before the review propagates still reports reviewed == false; the pending
    // mark keeps the card cleared.
    func testLaggingServerReadKeepsCardCleared() {
        var o = OptimisticReviews()
        o.begin(pr)
        o.retire(pr)
        XCTAssertTrue(o.reconcile(id: pr, serverReviewed: false))
        XCTAssertTrue(o.pending.contains(pr)) // still awaiting confirmation
    }

    // Confirmation clears the pending mark; a later re-request (fetched false)
    // is then honored, so a re-requested review reopens the card.
    func testConfirmationClearsPendingThenReRequestReopens() {
        var o = OptimisticReviews()
        o.begin(pr)
        o.retire(pr)
        XCTAssertTrue(o.reconcile(id: pr, serverReviewed: true)) // server confirms
        XCTAssertFalse(o.pending.contains(pr))
        XCTAssertFalse(o.reconcile(id: pr, serverReviewed: false)) // re-request honored
    }

    // A PR that drops out of the fetched queue before confirmation is forgotten,
    // so the sets can't leak and a later return is server-driven again.
    func testRetainForgetsDroppedPR() {
        var o = OptimisticReviews()
        o.begin(pr)
        o.retire(pr)
        o.retain(ids: ["acme/api#92"]) // pr no longer in the queue
        XCTAssertFalse(o.pending.contains(pr))
        XCTAssertFalse(o.inFlight.contains(pr))
        XCTAssertFalse(o.reconcile(id: pr, serverReviewed: false))
    }

    // Untracked PRs are pass-through: reconcile never fabricates a reviewed flag
    // for a PR we didn't optimistically retire.
    func testUntrackedPRIsPassThrough() {
        var o = OptimisticReviews()
        XCTAssertFalse(o.reconcile(id: pr, serverReviewed: false))
        XCTAssertTrue(o.reconcile(id: pr, serverReviewed: true))
    }

    // With no risks, the copy text is just the title and summary — no fixes
    // header and no trailing bullets.
    func testReviewPlainTextWithoutRisks() {
        let out = reviewPlainText(
            title: "Self-review · Approve",
            summary: "Looks good.",
            risks: [],
            fixesHeader: "Things to fix before requesting review")
        XCTAssertEqual(out, "Self-review · Approve\n\nLooks good.")
    }

    // With risks, the fixes header and one bullet per risk are appended below
    // the summary.
    func testReviewPlainTextWithRisks() {
        let out = reviewPlainText(
            title: "Self-review · Request changes",
            summary: "Small fix.",
            risks: ["No test for the null path", "Leftover debug print"],
            fixesHeader: "Things to fix before requesting review")
        XCTAssertEqual(out, """
        Self-review · Request changes

        Small fix.

        Things to fix before requesting review:
        • No test for the null path
        • Leftover debug print
        """)
    }
}
