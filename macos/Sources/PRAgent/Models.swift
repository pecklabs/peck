import Foundation

enum Verdict: String, Codable, CaseIterable {
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
    case comment = "COMMENT"

    var label: String {
        switch self {
        case .approve: return tr("Approve")
        case .requestChanges: return tr("Request changes")
        case .comment: return tr("Comment")
        }
    }

}

enum ReviewDecision: String, Codable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

enum Mergeable: String, Codable {
    case mergeable = "MERGEABLE"
    case conflicting = "CONFLICTING"
    case unknown = "UNKNOWN"
}

enum ChecksState: String, Codable {
    case success = "SUCCESS"
    case failure = "FAILURE"
    case pending = "PENDING"
    case none = "NONE"
}

struct GithubUser: Codable, Equatable {
    var login: String
    var name: String?
    var avatarUrl: String
}

struct InlineComment: Codable, Equatable {
    var path: String
    var line: Int
    var body: String
}

struct ReviewDraft: Codable, Equatable {
    var summary: String
    var verdict: Verdict
    var body: String
    var risks: [String]
    var comments: [InlineComment]
    var model: String
    var skillsApplied: [String]
    var generatedAt: Date
    var error: String?
}

struct ReviewRequest: Identifiable, Equatable {
    var id: String  // owner/repo#number
    var owner: String
    var repo: String
    var number: Int
    var title: String
    var url: String
    var author: GithubUser
    var isDraft: Bool
    var additions: Int
    var deletions: Int
    var changedFiles: Int
    var createdAt: Date
    var updatedAt: Date
    var reviewed: Bool
    var draft: ReviewDraft?
    var reviewing: Bool = false

    var nameWithNumber: String { "\(owner)/\(repo) #\(number)" }
}

/// One reviewer's latest state on a PR of mine.
struct ReviewerStatus: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case approved, changesRequested, commented, pending
    }
    var id: String { login }
    var login: String
    var state: State
    var isBot: Bool = false
    var avatarUrl: String = ""
}

/// A comment on a PR: discussion comment, inline review comment (has a path),
/// or a review summary (has a verdict).
struct PrComment: Identifiable, Equatable {
    var id: String
    var author: String
    var avatarUrl: String
    var body: String
    var createdAt: Date
    /// File the comment is anchored to, for inline review comments.
    var path: String?
    /// Review state (APPROVED / CHANGES_REQUESTED / …) when this is a review summary.
    var verdict: String?
}

struct MyPullRequest: Identifiable, Equatable {
    var id: String
    var owner: String
    var repo: String
    var number: Int
    var title: String
    var url: String
    var isDraft: Bool
    var reviewDecision: ReviewDecision?
    var mergeable: Mergeable
    var checks: ChecksState
    var approvedCount: Int
    var changesRequestedCount: Int
    var pendingReviewers: [String]
    var updatedAt: Date
    /// Approvals required by branch protection (>=1; defaults to 1 if unknown).
    var requiredApprovals: Int = 1
    /// Reviewers who left a comment-only review.
    var commentedCount: Int = 0
    /// Distinct reviewers who have submitted any review (approve/changes/comment).
    var reviewedCount: Int = 0
    /// Reviews left by bots (shown separately, excluded from human counts).
    var botReviewCount: Int = 0
    /// Per-reviewer latest state (humans first, then pending, bots last).
    var reviewers: [ReviewerStatus] = []
    /// One-shot agent self-review, generated when the PR is first uploaded.
    var selfReview: ReviewDraft? = nil
    var selfReviewing: Bool = false

    var nameWithNumber: String { "\(owner)/\(repo) #\(number)" }

    /// Fully approved: every requested reviewer has signed off (no one still
    /// pending) and nobody requested changes. Note GitHub reports `reviewDecision
    /// == APPROVED` once the *required count* is met even if extra reviewers were
    /// requested and haven't responded — we additionally require none pending.
    var allApproved: Bool {
        guard pendingReviewers.isEmpty, changesRequestedCount == 0 else { return false }
        return reviewDecision == .approved || (reviewDecision == nil && approvedCount > 0)
    }

    /// Approved AND no merge conflict — clear to merge.
    var readyToMerge: Bool { allApproved && mergeable == .mergeable }

    /// Approved but blocked by a conflict — the special state to highlight.
    var approvedButConflicted: Bool { allApproved && mergeable == .conflicting }

    // MARK: Gamified review progress

    /// Denominator for the quest = every reviewer involved (those still pending
    /// plus those who already reviewed), so a comment-only reviewer still counts
    /// toward the total. Branch protection's required count wins if it's higher.
    var questTarget: Int {
        if allApproved { return max(approvedCount, requiredApprovals, 1) }
        let totalReviewers = pendingReviewers.count + reviewedCount
        return max(requiredApprovals, totalReviewers, approvedCount + 1, 1)
    }
    /// Approvals collected so far (capped at target).
    var questGot: Int { min(approvedCount, questTarget) }

    enum QuestStage {
        case blocked        // changes requested
        case conflict       // approved but conflicting
        case start          // 0 approvals
        case progressing    // some approvals
        case almost         // one away
        case cleared        // all approvals in

        /// A little mascot that levels up with the review.
        var mascot: String {
            switch self {
            case .blocked: return "🛠️"
            case .conflict: return "🧱"
            case .start: return "🥚"
            case .progressing: return "🐣"
            case .almost: return "🐥"
            case .cleared: return "🐔"
            }
        }
        var rankName: String {
            switch self {
            case .blocked: return tr("Needs work")
            case .conflict: return tr("Boss: conflict")
            case .start: return tr("Laid")
            case .progressing: return tr("Hatching")
            case .almost: return tr("Grown")
            case .cleared: return tr("Chicken dinner!")
            }
        }
    }

    /// Custom mascot image asset name for the current state.
    /// Base stage (egg → chick → fledgling → chicken, or fried = changes requested),
    /// with a "-conflict" variant when the PR has a merge conflict.
    var mascotAsset: String {
        let base: String
        if changesRequestedCount > 0 && !allApproved {
            base = "friedegg"                      // 🍳 changes requested — didn't hatch
        } else if questGot >= questTarget {
            base = "friedchicken"                  // 🍗 fully approved — 치킨!
        } else if questGot == 0 {
            base = "egg"                           // 🥚
        } else if questGot >= questTarget - 1 {
            base = "chicken"                        // 🐔 one away — grown hen
        } else {
            base = "chick"                          // 🐣
        }
        return mergeable == .conflicting ? base + "-conflict" : base
    }

    var questStage: QuestStage {
        if approvedButConflicted { return .conflict }
        if changesRequestedCount > 0 && !allApproved { return .blocked }
        if allApproved { return .cleared }          // authoritative: GitHub says fully approved
        if questGot == 0 { return .start }
        if questGot >= questTarget - 1 { return .almost }
        return .progressing
    }
}

enum TrayState: String {
    case disconnected
    case idle
    case needsReview
    case allApproved
    case conflict

    /// SF Symbol name driving the menu bar icon.
    var symbolName: String {
        switch self {
        case .disconnected: return "circle.dashed"
        case .idle: return "checkmark.circle"
        case .needsReview: return "eye.circle.fill"
        case .allApproved: return "checkmark.seal.fill"
        case .conflict: return "exclamationmark.triangle.fill"
        }
    }
}

struct TrayStatus: Equatable {
    var state: TrayState
    var needsReview: Int      // PRs awaiting my review
    var needAction: Int       // my PRs ready to merge OR with a conflict to fix
    var myOpen: Int
    var approved: Int
    var conflicts: Int        // my approved PRs blocked by a conflict
    var tooltip: String

    static func derive(connected: Bool, queue: [ReviewRequest], myPrs: [MyPullRequest]) -> TrayStatus {
        let needsReview = queue.filter { !$0.reviewed && !$0.isDraft }.count
        let myOpen = myPrs.count
        let approved = myPrs.filter { $0.allApproved }.count
        let conflicts = myPrs.filter { $0.approvedButConflicted }.count
        // My PRs that need action from me: mergeable now, or a conflict to resolve.
        let needAction = myPrs.filter { $0.readyToMerge || $0.mergeable == .conflicting }.count

        let state: TrayState
        if !connected { state = .disconnected }
        else if conflicts > 0 { state = .conflict }
        else if needsReview > 0 { state = .needsReview }
        else if myOpen > 0 && approved == myOpen { state = .allApproved }
        else { state = .idle }

        let tooltip: String
        if !connected {
            tooltip = "PR Agent — not connected"
        } else if needsReview == 0 && needAction == 0 {
            tooltip = "PR Agent — all clear"
        } else {
            var parts: [String] = []
            if needsReview > 0 { parts.append("\(needsReview) to review") }
            if needAction > 0 { parts.append("\(needAction) need action") }
            tooltip = parts.joined(separator: " · ")
        }
        return TrayStatus(state: state, needsReview: needsReview, needAction: needAction,
                          myOpen: myOpen, approved: approved, conflicts: conflicts, tooltip: tooltip)
    }
}

enum AgentBackend: String, Codable, CaseIterable, Identifiable {
    case claudeCLI = "claude"
    case codexCLI = "codex"
    case anthropicAPI = "api"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .claudeCLI: return I18n.isKorean ? "Claude Code (로그인)" : "Claude Code (login)"
        case .codexCLI: return I18n.isKorean ? "Codex / ChatGPT (로그인)" : "Codex / ChatGPT (login)"
        case .anthropicAPI: return I18n.isKorean ? "Anthropic API 키" : "Anthropic API key"
        }
    }
    /// Whether this backend needs an Anthropic API key in the keychain.
    var needsApiKey: Bool { self == .anthropicAPI }
}

struct AppSettings: Codable, Equatable {
    var model: String = "claude-opus-4-8"
    var pollIntervalSec: Int = 60
    var autoReview: Bool = true
    /// Self-review each PR the user uploads and show the result in My PRs.
    var selfReview: Bool = true
    var autoSubmit: Bool = false
    var notifications: Bool = true
    var agentBackend: AgentBackend = .claudeCLI
    var useGhAuth: Bool = false
    /// Language for the explanation shown to you (summary + risks).
    var explanationLanguage: String = "한국어"
    /// Language for the review body posted to GitHub.
    var reviewLanguage: String = "English"
    /// Language of the app's own UI.
    var uiLanguage: String = "English"

    // Tolerate older persisted settings that lack the newer keys.
    enum CodingKeys: String, CodingKey {
        case model, pollIntervalSec, autoReview, selfReview, autoSubmit, notifications, agentBackend, useGhAuth
        case explanationLanguage, reviewLanguage, uiLanguage
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "claude-opus-4-8"
        pollIntervalSec = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSec) ?? 60
        autoReview = try c.decodeIfPresent(Bool.self, forKey: .autoReview) ?? true
        selfReview = try c.decodeIfPresent(Bool.self, forKey: .selfReview) ?? true
        autoSubmit = try c.decodeIfPresent(Bool.self, forKey: .autoSubmit) ?? false
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? true
        agentBackend = try c.decodeIfPresent(AgentBackend.self, forKey: .agentBackend) ?? .claudeCLI
        useGhAuth = try c.decodeIfPresent(Bool.self, forKey: .useGhAuth) ?? false
        explanationLanguage = try c.decodeIfPresent(String.self, forKey: .explanationLanguage) ?? "한국어"
        reviewLanguage = try c.decodeIfPresent(String.self, forKey: .reviewLanguage) ?? "English"
        uiLanguage = try c.decodeIfPresent(String.self, forKey: .uiLanguage) ?? "English"
    }
}

/// Languages offered in the picker (the value is sent verbatim to the agent).
let supportedLanguages = ["한국어", "English"]

struct SkillInfo: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var description: String
    var enabled: Bool
    var path: String
}
