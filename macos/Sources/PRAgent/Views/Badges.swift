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

/// Verdict pill for the agent's pre-flight self-review: the ✨ + "Self-review"
/// prefix says who produced it, the tinted (unfilled) style keeps it visually
/// distinct from real reviewers' verdicts.
struct SelfReviewBadge: View {
    var verdict: Verdict

    var body: some View {
        Pill(text: "\(tr("Self-review")) · \(verdict.label)", color: color, systemImage: "sparkles")
    }

    private var color: Color {
        switch verdict {
        case .approve: return GH.success
        case .requestChanges: return GH.danger
        case .comment: return GH.accent
        }
    }
}

extension ReviewerStatus.State {
    var label: String {
        switch self {
        case .approved: return tr("Approved")
        case .changesRequested: return tr("Requested changes")
        case .commented: return tr("Commented")
        case .pending: return tr("Pending")
        }
    }
}

/// A GitHub avatar, falling back to a person glyph while loading / when absent.
struct AvatarView: View {
    var url: String
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let u = URL(string: url), !url.isEmpty {
                AsyncImage(url: u) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .foregroundStyle(GH.muted)
    }
}

/// One reviewer, GitHub-sidebar style: avatar + login, status as an icon on
/// the trailing edge (✓ approved, ± changes, 💬 commented, ● pending).
struct ReviewerRow: View {
    var reviewer: ReviewerStatus

    var body: some View {
        HStack(spacing: 7) {
            AvatarView(url: reviewer.avatarUrl)
            Text(reviewer.login).font(.system(size: 11, weight: .semibold))
            if reviewer.isBot {
                Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(GH.done)
            }
            Spacer()
            statusIcon.help(reviewer.state.label)
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch reviewer.state {
        case .approved:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(GH.success)
        case .changesRequested:
            Image(systemName: "plusminus")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(GH.danger)
        case .commented:
            Image(systemName: "bubble.left")
                .font(.system(size: 11)).foregroundStyle(GH.muted)
        case .pending:
            Circle().fill(GH.attention).frame(width: 8, height: 8)
        }
    }
}

/// Summary + risk/fix list as ONE selectable text block. Separate Text views
/// each get their own selection, so the cursor would break between paragraphs —
/// a single AttributedString keeps the whole explanation selectable in one drag.
func reviewExplanation(summary: String, header: String? = nil, risks: [String]) -> AttributedString {
    var out = AttributedString(summary)
    out.font = .system(size: 11)
    guard !risks.isEmpty else { return out }
    if let header {
        var h = AttributedString("\n\n\(header)")
        h.font = .system(size: 9, weight: .semibold)
        h.foregroundColor = GH.muted
        out += h
    }
    for risk in risks {
        var bullet = AttributedString("\n•  ")
        bullet.font = .system(size: 11, weight: .bold)
        bullet.foregroundColor = GH.attention
        out += bullet
        var r = AttributedString(risk)
        r.font = .system(size: 11)
        r.foregroundColor = GH.muted
        out += r
    }
    return out
}

enum Open {
    static func url(_ s: String) {
        guard let u = URL(string: s) else { return }
        NSWorkspace.shared.open(u)
    }
}
