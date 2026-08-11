import SwiftUI

struct MyPRsView: View {
    @EnvironmentObject var model: AppModel

    private var sorted: [MyPullRequest] {
        model.visibleMyPrs.sorted { a, b in
            if a.approvedButConflicted != b.approvedButConflicted { return a.approvedButConflicted }
            return a.updatedAt > b.updatedAt
        }
    }

    private var snoozedSorted: [MyPullRequest] {
        model.snoozedMyPrs.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                banner
                if model.myPrs.isEmpty {
                    EmptyState(icon: "tray", title: tr("No open PRs"),
                               subtitle: tr("PRs you author will show up here with their review status."))
                } else if sorted.isEmpty && !snoozedSorted.isEmpty {
                    EmptyState(icon: "moon.zzz", title: tr("All caught up"),
                               subtitle: tr("Your open PRs are snoozed. Peck will wake one the moment a reviewer responds."))
                } else {
                    ForEach(sorted) { pr in MyPrRow(pr: pr) }
                }
                SnoozedSection(prs: snoozedSorted)
            }
            .padding(12)
        }
    }

    @ViewBuilder private var banner: some View {
        let conflicts = model.tray.conflicts
        let approved = model.tray.approved
        let open = model.tray.myOpen
        if conflicts > 0 {
            BannerView(color: GH.severe,
                       icon: "exclamationmark.triangle.fill",
                       text: I18n.isKorean
                        ? "승인됐지만 충돌로 막힌 PR \(conflicts)개"
                        : "\(conflicts) approved PR\(conflicts > 1 ? "s" : "") blocked by merge conflicts")
        } else if open > 0 && approved == open {
            BannerView(color: GH.success, icon: "checkmark.seal.fill",
                       text: I18n.isKorean
                        ? "PR \(open)개 전부 승인됨 🎉"
                        : "All \(open) PR\(open > 1 ? "s" : "") approved 🎉")
        }
    }
}

struct BannerView: View {
    var color: Color
    var icon: String
    var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: 12, weight: .medium))
            Spacer()
        }
        .padding(10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct MyPrRow: View {
    @EnvironmentObject var model: AppModel
    var pr: MyPullRequest

    var body: some View {
        HStack(spacing: 0) {
            if pr.approvedButConflicted {
                Rectangle()
                    .fill(GH.severe)
                    .frame(width: 3)
            }
            VStack(alignment: .leading, spacing: 6) {
                Button { Open.url(pr.url) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(pr.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                            Spacer()
                        }
                        Text(pr.nameWithNumber).font(.system(size: 10)).foregroundStyle(GH.muted)
                        ReviewQuest(pr: pr)
                        PrStatusBadges(pr: pr)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                SelfReviewSection(pr: pr)
            }
            .padding(10)
        }
        .background(
            pr.approvedButConflicted
                ? GH.severe.opacity(0.08)
                : GH.subtle,
            in: RoundedRectangle(cornerRadius: 9)
        )
        .contextMenu {
            Button {
                model.snooze(id: pr.id)
            } label: {
                Label(tr("Snooze until a review"), systemImage: "moon.zzz")
            }
        }
    }
}

/// Collapsed list of PRs the user has snoozed. Peck keeps polling them and wakes
/// one automatically when a reviewer responds; this section is just for a manual
/// peek or an early un-snooze.
struct SnoozedSection: View {
    @EnvironmentObject var model: AppModel
    var prs: [MyPullRequest]
    @State private var expanded = false

    var body: some View {
        if !prs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                            Image(systemName: "moon.zzz").font(.system(size: 11))
                            Text(tr("Snoozed") + " (\(prs.count))").font(.system(size: 11, weight: .medium))
                            Spacer()
                        }
                        .foregroundStyle(GH.muted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button(tr("Wake all")) { model.unsnoozeAll() }
                        .buttonStyle(.borderless).controlSize(.small)
                        .help(tr("Move every snoozed PR back into the queue"))
                }
                if expanded {
                    ForEach(prs) { pr in SnoozedRow(pr: pr) }
                }
            }
            .padding(.top, 4)
        }
    }
}

struct SnoozedRow: View {
    @EnvironmentObject var model: AppModel
    var pr: MyPullRequest

    var body: some View {
        HStack(spacing: 8) {
            Button { Open.url(pr.url) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pr.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(pr.nameWithNumber).font(.system(size: 9)).foregroundStyle(GH.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 6)
            Button { model.unsnooze(id: pr.id) } label: {
                Label(tr("Wake"), systemImage: "bell")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless).controlSize(.small)
            .help(tr("Move back into the queue"))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(GH.subtle.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Status pills + "waiting on" line — shared by the popover card and the
/// self-review window.
struct PrStatusBadges: View {
    var pr: MyPullRequest

    var body: some View {
        HStack(spacing: 5) {
            if pr.isDraft { Pill(text: tr("Draft"), color: GH.muted, systemImage: "pencil.line") }
            if pr.mergeable == .conflicting { ConflictBadge() }
            ChecksBadge(state: pr.checks)
            if pr.commentedCount > 0 {
                Pill(text: "\(pr.commentedCount)", color: GH.muted, systemImage: "bubble.left")
            }
            if pr.botReviewCount > 0 {
                Pill(text: "\(pr.botReviewCount)", color: GH.done, systemImage: "sparkles")
            }
            Spacer(minLength: 6)
            if !pr.pendingReviewers.isEmpty {
                Text(tr("Waiting on:") + " " + pr.pendingReviewers.map { "@\($0)" }.joined(separator: ", "))
                    .font(.system(size: 10)).foregroundStyle(GH.muted)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
    }
}

/// One-line self-review summary at the bottom of a PR card: verdict badge,
/// how many things to fix, and a chevron pointing at the full details.
/// Shared by the popover card and the window's PR list.
struct SelfReviewBadgeRow: View {
    var draft: ReviewDraft

    var body: some View {
        HStack(spacing: 6) {
            if draft.error != nil {
                Pill(text: tr("Self-review failed"), color: GH.attention,
                     systemImage: "exclamationmark.triangle")
            } else {
                SelfReviewBadge(verdict: draft.verdict)
                if !draft.risks.isEmpty {
                    Pill(text: "\(draft.risks.count)", color: GH.attention,
                         systemImage: "exclamationmark.circle")
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(GH.muted)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(GH.canvas, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}

/// The agent's one-shot pre-flight review of the user's own PR. The popover
/// card only shows the verdict badge (+ how many things to fix) — clicking it
/// opens the app window, where the same section renders the full, selectable
/// summary and fix list.
struct SelfReviewSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.peckWindowMode) private var windowMode
    @Environment(\.dismiss) private var dismissPopover
    @State private var copied = false
    @State private var copyGeneration = 0
    var pr: MyPullRequest

    var body: some View {
        if pr.selfReviewing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(tr("Peck is self-reviewing…")).font(.system(size: 11)).foregroundStyle(GH.muted)
            }
        } else if let draft = pr.selfReview {
            if windowMode {
                fullView(draft)
            } else {
                badgeRow(draft)
            }
        } else if !Snapshot.isRendering {
            Button {
                Task { await model.runSelfReview(id: pr.id) }
            } label: {
                Label(tr("Self-review"), systemImage: "sparkles")
                    .font(.system(size: 10))
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .disabled(!model.agentAvailable)
        }
    }

    // Popover: one line — the details live in the app window.
    private func badgeRow(_ draft: ReviewDraft) -> some View {
        Button {
            dismissPopover()
            PeckWindow.open(model: model, focusMyPr: pr.id)
        } label: {
            SelfReviewBadgeRow(draft: draft)
        }
        .buttonStyle(.plain)
    }

    // Window: everything, selectable for copy-paste.
    private func fullView(_ draft: ReviewDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = draft.error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(GH.attention)
                    Text(err).font(.system(size: 11)).foregroundStyle(GH.muted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(tr("Retry")) { Task { await model.runSelfReview(id: pr.id) } }
                    .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    SelfReviewBadge(verdict: draft.verdict)
                    Spacer()
                    if !draft.skillsApplied.isEmpty {
                        Text(draft.skillsApplied.joined(separator: " · "))
                            .font(.system(size: 9)).foregroundStyle(GH.muted)
                    }
                    if !Snapshot.isRendering {
                        Button {
                            Clipboard.copy(selfReviewPlainText(draft))
                            copied = true
                            copyGeneration += 1
                            let gen = copyGeneration
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                // Only the most recent click resets, so a rapid
                                // second click can't be cut short by the first
                                // click's timer firing.
                                if gen == copyGeneration { copied = false }
                            }
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(copied ? GH.success : GH.muted)
                        }
                        .buttonStyle(.borderless).controlSize(.small)
                        .help(tr("Copy self-review"))
                        Button {
                            Task { await model.runSelfReview(id: pr.id) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless).controlSize(.small)
                        .disabled(!model.agentAvailable)
                        .help("Run self-review again")
                    }
                }
                Text(reviewExplanation(summary: draft.summary,
                                       header: tr("Things to fix before requesting review"),
                                       risks: draft.risks))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(draft.model) · \(timeAgo(draft.generatedAt))")
                    .font(.system(size: 9)).foregroundStyle(GH.muted)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GH.canvas, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct EmptyState: View {
    var icon: String
    var title: String
    var subtitle: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(GH.muted)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(GH.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}
