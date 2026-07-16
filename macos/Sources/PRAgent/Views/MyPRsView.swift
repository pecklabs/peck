import SwiftUI

struct MyPRsView: View {
    @EnvironmentObject var model: AppModel

    private var sorted: [MyPullRequest] {
        model.myPrs.sorted { a, b in
            if a.approvedButConflicted != b.approvedButConflicted { return a.approvedButConflicted }
            return a.updatedAt > b.updatedAt
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                banner
                if model.myPrs.isEmpty {
                    EmptyState(icon: "tray", title: tr("No open PRs"),
                               subtitle: tr("PRs you author will show up here with their review status."))
                } else {
                    ForEach(sorted) { pr in MyPrRow(pr: pr) }
                }
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
    }
}

/// The agent's one-shot pre-flight review of the user's own PR, shown inside
/// the PR card. Runs automatically when a PR is uploaded; can be re-run here.
struct SelfReviewSection: View {
    @EnvironmentObject var model: AppModel
    var pr: MyPullRequest

    var body: some View {
        if pr.selfReviewing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(tr("Peck is self-reviewing…")).font(.system(size: 11)).foregroundStyle(GH.muted)
            }
        } else if let draft = pr.selfReview {
            if let err = draft.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(GH.attention)
                    Text(err).font(.system(size: 11)).foregroundStyle(GH.muted).lineLimit(3)
                    Spacer()
                    Button(tr("Retry")) { Task { await model.runSelfReview(id: pr.id) } }
                        .controlSize(.small)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        SelfVerdictBadge(verdict: draft.verdict)
                        Text(tr("Self-review")).font(.system(size: 9, weight: .semibold)).foregroundStyle(GH.muted)
                        Spacer()
                        if !Snapshot.isRendering {
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
                    Text(draft.summary).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    if !draft.risks.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(draft.risks.enumerated()), id: \.offset) { _, risk in
                                HStack(alignment: .top, spacing: 5) {
                                    Image(systemName: "exclamationmark.circle").font(.system(size: 9))
                                        .foregroundStyle(GH.attention).padding(.top, 2)
                                    Text(risk).font(.system(size: 11)).foregroundStyle(GH.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GH.canvas, in: RoundedRectangle(cornerRadius: 7))
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
