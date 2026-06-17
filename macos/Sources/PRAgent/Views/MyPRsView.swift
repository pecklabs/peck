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
        Button { Open.url(pr.url) } label: {
            HStack(spacing: 0) {
                if pr.approvedButConflicted {
                    Rectangle()
                        .fill(GH.severe)
                        .frame(width: 3)
                }
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
                .padding(10)
            }
            .background(
                pr.approvedButConflicted
                    ? GH.severe.opacity(0.08)
                    : GH.subtle,
                in: RoundedRectangle(cornerRadius: 9)
            )
        }
        .buttonStyle(.plain)
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
