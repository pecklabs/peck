import SwiftUI

/// Shown in a standalone window on first launch (and whenever disconnected), so a
/// freshly-installed menu-bar app doesn't look like "nothing happened". Mirrors
/// the connect actions in SettingsView and points the user at the menu bar.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @State private var token = ""
    @State private var connecting = false
    @State private var showTokenField = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("🐤 \(tr("Welcome to Peck"))").font(.system(size: 20, weight: .bold))
                Text(tr("Peck lives in your menu bar. Connect GitHub to start reviewing PRs."))
                    .font(.system(size: 12)).foregroundStyle(GH.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text(tr("Connect GitHub")).font(.system(size: 13, weight: .semibold))

            Button {
                connecting = true
                Task { await model.connectGitHubCLI(); connecting = false }
            } label: {
                HStack {
                    if connecting { ProgressView().controlSize(.small) }
                    else { Image(systemName: "terminal") }
                    Text(tr("Sign in with GitHub CLI"))
                }
            }
            .controlSize(.large)
            .disabled(connecting)

            Text(tr("Reuses your existing `gh auth login`. If you're not logged in, run `gh auth login` in a terminal first."))
                .font(.system(size: 10)).foregroundStyle(GH.muted)

            Button(showTokenField ? tr("Hide token option") : tr("or paste a token instead")) {
                showTokenField.toggle()
            }
            .buttonStyle(.borderless).controlSize(.small)

            if showTokenField {
                Text("Token needs **repo** and **read:org** scopes.")
                    .font(.system(size: 10)).foregroundStyle(GH.muted)
                Button(tr("Create a token on GitHub →")) {
                    Open.url("https://github.com/settings/tokens/new?scopes=repo,read:org&description=PR%20Agent")
                }.buttonStyle(.borderless).controlSize(.small)
                HStack {
                    SecureField("ghp_…", text: $token).textFieldStyle(.roundedBorder)
                    Button(tr("Connect")) {
                        connecting = true
                        Task { await model.connectGitHub(token: token); connecting = false }
                    }.disabled(token.isEmpty || connecting)
                }
            }

            if let err = model.errorMessage {
                Text(err).font(.system(size: 11)).foregroundStyle(GH.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                Image(systemName: "arrow.up.forward")
                Text(tr("Once connected, find Peck in the menu bar at the top-right of your screen."))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 10)).foregroundStyle(GH.muted)
        }
        .padding(20)
        .frame(width: 380, height: 360, alignment: .topLeading)
        .background(GH.canvas)
        .foregroundStyle(GH.fg)
        .tint(GH.accent)
    }
}
