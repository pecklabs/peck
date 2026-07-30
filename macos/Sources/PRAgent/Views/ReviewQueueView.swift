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
                    ForEach(pending) { req in
                        ReviewCard(req: req)
                            .transition(.asymmetric(
                                insertion: .opacity,
                                // Fade-led so the card dissolves in place; a gentle
                                // shrink lets the rows below close the gap smoothly.
                                removal: .opacity.combined(with: .scale(scale: 0.95))
                            ))
                    }
                }
            }
            .padding(12)
            .animation(.easeInOut(duration: 0.3), value: pending.map(\.id))
        }
    }
}

/// The floating "Submitting…" indicator shown over a card during its optimistic
/// loading beat. Uses the system Liquid Glass material on macOS 26+.
///
/// macOS desaturates every system material (Liquid Glass included) to flat gray
/// whenever its host window isn't active — and the menu-bar popover is a
/// non-active accessory panel, so the glass there is *always* inactive/gray. A
/// plain translucent capsule underlays the pill so that in the popover (or on
/// older systems, deployment target is macOS 14) it still reads as a soft
/// translucent capsule instead of dead gray; where the window is active (the
/// detached window) the real glass renders on top.
struct SubmittingPill: View {
    // A plain colour — not a system material — so it keeps the same translucent
    // look whether or not the host window is active.
    private var fill: Color { GH.dyn(0xFFFFFF, 0x2D333B).opacity(0.62) }
    private var stroke: Color { GH.dyn(0xFFFFFF, 0xFFFFFF).opacity(0.35) }

    var body: some View {
        let content = HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text(tr("Submitting…"))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(GH.fg)
        }
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(fill, in: .capsule)
        .overlay(Capsule().strokeBorder(stroke, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 1)

        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
        }
    }
}

/// A TextEditor that grows with its content and never scrolls internally, so it
/// can't chain/propagate scroll to the enclosing list.
struct AutoTextEditor: View {
    @Binding var text: String
    private let font = Font.system(size: 11, design: .monospaced)

    var body: some View {
        let base = Text(text.isEmpty ? " " : text)
            .font(font)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .padding(.horizontal, 6)
            .padding(.vertical, 12)
        Group {
            if Snapshot.isRendering {
                base // ImageRenderer can't draw TextEditor — show static text for snapshots
            } else {
                base.opacity(0).overlay(
                    TextEditor(text: $text)
                        .font(font)
                        .scrollDisabled(true)
                        .scrollContentBackground(.hidden)
                        .padding(.top, 7)
                        .padding(.horizontal, 1)
                )
            }
        }
        .background(GH.canvas, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct ReviewCard: View {
    @EnvironmentObject var model: AppModel
    var req: ReviewRequest
    @State private var editedBody: String

    init(req: ReviewRequest) {
        self.req = req
        _editedBody = State(initialValue: req.draft?.body ?? "")
    }

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

            if !Snapshot.isRendering {
                HStack {
                    Button { Open.url(req.url) } label: { Label(tr("Open on GitHub"), systemImage: "arrow.up.right.square") }
                        .controlSize(.small).buttonStyle(.borderless)
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(GH.subtle, in: RoundedRectangle(cornerRadius: 10))
        // Whole-card loading: while a verdict is submitting, the card dims
        // slightly (still fully readable, just receding) so a floating Liquid
        // Glass "Submitting…" pill on top stands out — the deliberate beat reads
        // as "this card is being submitted" before it animates away. Disabled so
        // nothing underneath is clickable.
        .opacity(req.submitting ? 0.6 : 1)
        .overlay {
            if req.submitting {
                SubmittingPill().transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .disabled(req.submitting)
        .animation(.easeInOut(duration: 0.2), value: req.submitting)
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
                if !Snapshot.isRendering {
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
            }
            .onChange(of: draft.generatedAt) { _, _ in editedBody = draft.body }
            Text(reviewExplanation(summary: draft.summary, risks: draft.risks))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

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
            }
        }
    }

    private func submitButton(_ title: String, _ verdict: Verdict, _ color: Color) -> some View {
        Button {
            Task {
                await model.submitReview(id: req.id, verdict: verdict,
                                         body: editedBody, comments: req.draft?.comments ?? [])
            }
        } label: {
            Text(title).font(.system(size: 10, weight: .semibold))
        }
        .controlSize(.small)
        .tint(color)
        .disabled(req.submitting)
    }
}
