import SwiftUI

func timeAgo(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86400 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
}

struct Pill: View {
    var text: String
    var color: Color
    var filled: Bool = false
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(filled ? Color.white : color)
        .background(filled ? color : color.opacity(0.14), in: Capsule())
    }
}

struct ReviewDecisionBadge: View {
    var decision: ReviewDecision?
    var body: some View {
        switch decision {
        case .approved: Pill(text: "Approved", color: GH.success, systemImage: "checkmark")
        case .changesRequested: Pill(text: "Changes requested", color: GH.danger, systemImage: "xmark")
        case .reviewRequired: Pill(text: "Review required", color: GH.muted, systemImage: "clock")
        case nil: Pill(text: "No reviews", color: GH.muted)
        }
    }
}

struct ChecksBadge: View {
    var state: ChecksState
    var body: some View {
        switch state {
        case .success: Pill(text: tr("Checks"), color: GH.success, systemImage: "checkmark.circle")
        case .failure: Pill(text: tr("Checks"), color: GH.danger, systemImage: "xmark.octagon")
        case .pending: Pill(text: tr("Checks"), color: GH.attention, systemImage: "clock")
        case .none: EmptyView()
        }
    }
}

struct ConflictBadge: View {
    var body: some View {
        Pill(text: tr("Conflict"), color: GH.severe,
             filled: true, systemImage: "exclamationmark.triangle.fill")
    }
}

struct VerdictBadge: View {
    var verdict: Verdict
    var body: some View {
        switch verdict {
        case .approve: Pill(text: tr("Approve"), color: GH.success, filled: true, systemImage: "checkmark")
        case .requestChanges: Pill(text: tr("Request changes"), color: GH.danger, filled: true, systemImage: "exclamationmark")
        case .comment: Pill(text: tr("Comment"), color: GH.accent, filled: true, systemImage: "text.bubble")
        }
    }
}

/// Verdict pill for a self-review of the user's own PR — reads as a readiness
/// call ("ready" / "fix first"), not as a review to submit.
struct SelfVerdictBadge: View {
    var verdict: Verdict
    var body: some View {
        switch verdict {
        case .approve: Pill(text: verdict.selfLabel, color: GH.success, systemImage: "checkmark.seal")
        case .requestChanges: Pill(text: verdict.selfLabel, color: GH.attention, systemImage: "wrench.and.screwdriver")
        case .comment: Pill(text: verdict.selfLabel, color: GH.accent, systemImage: "text.bubble")
        }
    }
}

enum Open {
    static func url(_ s: String) {
        guard let u = URL(string: s) else { return }
        NSWorkspace.shared.open(u)
    }
}
