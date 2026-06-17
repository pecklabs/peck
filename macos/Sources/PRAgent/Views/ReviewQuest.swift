import SwiftUI
import AppKit

/// Shows a custom mascot image for the asset name, falling back to an emoji
/// while the PNG hasn't been added to Resources/mascots yet.
struct MascotView: View {
    var asset: String
    var size: CGFloat = 24

    var body: some View {
        if let img = MascotImages.image(asset) {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
        } else {
            Text(MascotImages.emoji(asset)).font(.system(size: size))
        }
    }
}

enum MascotImages {
    static func image(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "mascots")
            ?? Bundle.module.url(forResource: name, withExtension: "png")
        else { return nil }
        return NSImage(contentsOf: url)
    }

    static func emoji(_ name: String) -> String {
        switch name {
        case "egg", "egg-conflict": return "🥚"
        case "chick": return "🐣"
        case "chick-conflict": return "😢"
        case "chicken", "chicken-conflict": return "🐔"
        case "friedchicken", "friedchicken-conflict": return "🍗"
        case "friedegg", "friedegg-conflict": return "🍳"
        default: return "🥚"
        }
    }
}

/// A little "review quest" progress strip: a mascot that levels up as approvals
/// come in, plus a dot/XP bar toward the number of approvals the PR needs.
struct ReviewQuest: View {
    var pr: MyPullRequest

    private var stage: MyPullRequest.QuestStage { pr.questStage }

    private var color: Color {
        switch stage {
        case .conflict: return GH.severe
        case .blocked: return GH.danger
        case .cleared: return GH.success
        case .almost: return GH.accent
        default: return GH.accent
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            MascotView(asset: pr.mascotAsset, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(stage.rankName).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
                    Spacer()
                    Text(I18n.isKorean
                        ? "승인 \(pr.questGot)/\(pr.questTarget)"
                        : "\(pr.questGot)/\(pr.questTarget) approvals")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(GH.muted)
                }
                progress
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var progress: some View {
        if pr.questTarget <= 6 {
            HStack(spacing: 4) {
                ForEach(0..<pr.questTarget, id: \.self) { i in
                    Capsule()
                        .fill(i < pr.questGot ? color : GH.muted.opacity(0.22))
                        .frame(height: 6)
                }
            }
        } else {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(GH.muted.opacity(0.22))
                    Capsule().fill(color)
                        .frame(width: geo.size.width * CGFloat(pr.questGot) / CGFloat(pr.questTarget))
                }
            }
            .frame(height: 6)
        }
    }
}
