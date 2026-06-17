import SwiftUI

struct ReviewQueueView: View {
    @EnvironmentObject var model: AppModel

    private var pending: [ReviewRequest] {
        model.reviewQueue.filter { !$0.reviewed }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if pending.isEmpty {
                    EmptyState(icon: "eye", title: tr("No reviews requested"),
                               subtitle: tr("When someone requests your review, the agent drafts an explanation and a verdict here."))
                } else {
                    ForEach(pending) { req in ReviewCard(req: req) }
                }
            }
            .padding(12)
        }
    }
}

/// A TextEditor that grows with its content and never scrolls internally, so it
/// can't chain/propagate scroll to the enclosing list.
struct AutoTextEditor: View {
    @Binding var text: String
    private let font = Font.system(size: 11, design: .monospaced)

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(font)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .padding(.horizontal, 6)
            .padding(.vertical, 12)
            .opacity(0)
            .overlay(
                TextEditor(text: $text)
                    .font(font)
                    .scrollDisabled(true)
                    .scrollContentBackground(.hidden)
                    .padding(.top, 7)
                    .padding(.horizontal, 1)
            )
            .background(GH.canvas, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct ReviewCard: View {
    @EnvironmentObject var model: AppModel
    var req: ReviewRequest
    @State private var editedBody: String = ""
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(req.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Text("\(req.nameWithNumber) · @\(req.author.login)")
                        .font(.system(size: 10)).foregroundStyle(GH.muted)
                }
                Spacer()
                if req.isDraft { Pill(text: tr("Draft"), color: GH.muted, systemImage: "pencil.line") }
            }
            HStack(spacing: 8) {
                Label("+\(req.additions)", systemImage: "plus").foregroundStyle(GH.success)
                Label("\(req.deletions)", systemImage: "minus").foregroundStyle(GH.danger)
                Label("\(req.changedFiles)", systemImage: "doc")
                Text(timeAgo(req.createdAt))
                Spacer()
            }
            .font(.system(size: 10)).foregroundStyle(GH.muted)

            if req.reviewing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(tr("Peck is reviewing…")).font(.system(size: 11)).foregroundStyle(GH.muted)
                }
            } else if let draft = req.draft {
                if let err = draft.error {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(GH.attention)
                        Text(err).font(.system(size: 11)).foregroundStyle(GH.muted).lineLimit(3)
                    }
                    Button(tr("Retry")) { Task { await model.runReview(id: req.id) } }
                        .controlSize(.small)
                } else {
                    draftView(draft)
                }
            } else {
                Button {
                    Task { await model.runReview(id: req.id) }
                } label: {
                    Label(tr("Let Peck review"), systemImage: "sparkles")
                }
                .controlSize(.small)
                .disabled(!model.agentAvailable)
                if !model.agentAvailable {
                    Text(tr("Set up the review agent in Settings to enable reviews."))
                        .font(.system(size: 10)).foregroundStyle(GH.muted)
                }
            }

            HStack {
                Button { Open.url(req.url) } label: { Label(tr("Open on GitHub"), systemImage: "arrow.up.right.square") }
                    .controlSize(.small).buttonStyle(.borderless)
                Spacer()
            }
        }
        .padding(12)
        .background(GH.subtle, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func draftView(_ draft: ReviewDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                VerdictBadge(verdict: draft.verdict)
                Spacer()
                if !draft.skillsApplied.isEmpty {
                    Text(draft.skillsApplied.joined(separator: " · "))
                        .font(.system(size: 9)).foregroundStyle(GH.muted)
                }
                Button {
                    Task { await model.runReview(id: req.id) }
                } label: {
                    if req.reviewing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless).controlSize(.small)
                .disabled(req.reviewing || !model.agentAvailable)
                .help("Regenerate review")
            }
            .onChange(of: draft.generatedAt) { _, _ in editedBody = draft.body }
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

            // Editable review body. Auto-grows and never scrolls internally, so the
            // outer list scroll is never hijacked.
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Review body")).font(.system(size: 9, weight: .semibold)).foregroundStyle(GH.muted)
                AutoTextEditor(text: $editedBody)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(GH.muted.opacity(0.2)))
            }
            .onAppear { if editedBody.isEmpty { editedBody = draft.body } }

            HStack(spacing: 6) {
                submitButton(tr("Approve"), .approve, GH.success)
                submitButton(tr("Request changes"), .requestChanges, GH.danger)
                submitButton(tr("Comment"), .comment, GH.accent)
                if submitting { ProgressView().controlSize(.small) }
            }
        }
    }

    private func submitButton(_ title: String, _ verdict: Verdict, _ color: Color) -> some View {
        Button {
            submitting = true
            Task {
                await model.submitReview(id: req.id, verdict: verdict,
                                         body: editedBody, comments: req.draft?.comments ?? [])
                submitting = false
            }
        } label: {
            Text(title).font(.system(size: 10, weight: .semibold))
        }
        .controlSize(.small)
        .tint(color)
        .disabled(submitting)
    }
}
