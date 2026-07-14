import AppKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !model.connected { onboarding } else { connectedSettings }
            }
            .padding(14)
        }
        .task { notifyStatus = await Notifier.authorizationStatus() }
        // The user may have just flipped the switch over in System Settings; re-read on
        // the way back so the warning below clears itself.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { notifyStatus = await Notifier.authorizationStatus() }
        }
    }

    // MARK: Onboarding

    @State private var token = ""
    @State private var anthropicKey = ""
    @State private var connecting = false
    @State private var showTokenField = false

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Connect GitHub")).font(.system(size: 14, weight: .bold))

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
            }

            Divider().padding(.vertical, 4)

            Text(tr("Review agent")).font(.system(size: 14, weight: .bold))
            backendPicker
            backendStatus
            languageControls
            if model.settings.agentBackend == .anthropicAPI {
                SecureField("sk-ant-…", text: $anthropicKey).textFieldStyle(.roundedBorder)
                Button(tr("Save key")) { model.setAnthropicKey(anthropicKey); anthropicKey = "" }
                    .controlSize(.small).disabled(anthropicKey.isEmpty)
                if model.hasAnthropicKey {
                    Label(tr("Key saved"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(GH.success)
                }
            }
        }
    }

    // MARK: Agent backend controls (shared)

    private var backendPicker: some View {
        Picker("Backend", selection: Binding(
            get: { model.settings.agentBackend },
            set: { var s = model.settings; s.agentBackend = $0; model.saveSettings(s) })) {
            ForEach(AgentBackend.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private var languageControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            languagePicker(tr("Explanation (shown to you)"), \.explanationLanguage)
            languagePicker(tr("Review posted to GitHub"), \.reviewLanguage)
        }
    }

    private func languagePicker(_ title: String, _ keyPath: WritableKeyPath<AppSettings, String>) -> some View {
        HStack {
            Text(title).font(.system(size: 11))
            Spacer()
            Picker("", selection: Binding(
                get: { model.settings[keyPath: keyPath] },
                set: { var s = model.settings; s[keyPath: keyPath] = $0; model.saveSettings(s) })) {
                ForEach(supportedLanguages, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        }
    }

    @ViewBuilder private var backendStatus: some View {
        switch model.settings.agentBackend {
        case .claudeCLI, .codexCLI:
            if model.agentAvailable {
                Label(tr("Using your existing login — no API key needed."), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10)).foregroundStyle(GH.success)
            } else {
                Label(tr("CLI not found on PATH. Install it or pick another backend."), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(GH.attention)
            }
        case .anthropicAPI:
            Text(tr("Calls the Anthropic API directly. Requires a key (billed to your account)."))
                .font(.system(size: 10)).foregroundStyle(GH.muted)
        }
    }

    // MARK: Connected settings

    @State private var replaceKey = ""
    @State private var showReplaceKey = false

    private var connectedSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            section(tr("GitHub")) {
                HStack(spacing: 8) {
                    avatar
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.user?.login ?? "—").font(.system(size: 12, weight: .semibold))
                        Text(model.settings.useGhAuth ? tr("via gh CLI login") : tr("via personal access token"))
                            .font(.system(size: 10)).foregroundStyle(GH.muted)
                    }
                    Spacer()
                    Button(tr("Disconnect")) { model.disconnectGitHub() }
                        .controlSize(.small).tint(GH.danger)
                }
            }

            section(tr("Review agent")) {
                backendPicker
                backendStatus
                languageControls
                if model.settings.agentBackend == .anthropicAPI {
                    HStack {
                        Label(model.hasAnthropicKey ? tr("Key saved") : tr("Not set"),
                              systemImage: model.hasAnthropicKey ? "checkmark.circle.fill" : "xmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(model.hasAnthropicKey ? GH.success : GH.muted)
                        Spacer()
                        Button(showReplaceKey ? tr("Cancel") : (model.hasAnthropicKey ? tr("Replace") : tr("Add key"))) {
                            showReplaceKey.toggle()
                        }.controlSize(.small).buttonStyle(.borderless)
                    }
                    if showReplaceKey {
                        HStack {
                            SecureField("sk-ant-…", text: $replaceKey).textFieldStyle(.roundedBorder)
                            Button(tr("Save")) {
                                model.setAnthropicKey(replaceKey); replaceKey = ""; showReplaceKey = false
                            }.controlSize(.small).disabled(replaceKey.isEmpty)
                        }
                    }
                    LabeledContent(tr("Model")) {
                        TextField("model", text: Binding(
                            get: { model.settings.model },
                            set: { var s = model.settings; s.model = $0; model.saveSettings(s) }))
                            .textFieldStyle(.roundedBorder).frame(width: 170)
                    }
                }
            }

            section(tr("Behavior")) {
                languagePicker(tr("App language"), \.uiLanguage)
                Stepper(value: Binding(
                    get: { model.settings.pollIntervalSec },
                    set: { var s = model.settings; s.pollIntervalSec = $0; model.saveSettings(s) }),
                    in: 15...600, step: 15) {
                    Text(I18n.isKorean ? "\(model.settings.pollIntervalSec)\u{cd08}\u{b9c8}\u{b2e4} \u{d655}\u{c778}" : "Poll every \(model.settings.pollIntervalSec)s").font(.system(size: 12))
                }
                toggle(tr("Auto-review new requests"), \.autoReview)
                toggle(tr("Auto-submit agent verdict"), \.autoSubmit)
                notificationControls
            }

            section(tr("Review skills")) {
                ForEach(model.skills) { skill in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: skill.enabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(skill.enabled ? GH.success : GH.muted).font(.system(size: 11))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(skill.name).font(.system(size: 11, weight: .semibold))
                            Text(skill.description).font(.system(size: 10)).foregroundStyle(GH.muted).lineLimit(2)
                        }
                        Spacer()
                    }
                }
                Text(tr("Skills are *.md files in ~/Library/Application Support/PRAgent/skills. Add `enabled: false` to a file's frontmatter to disable it."))
                    .font(.system(size: 10)).foregroundStyle(GH.muted)
                HStack {
                    Button(tr("Reload skills")) { model.reloadSkills() }.controlSize(.small)
                    Button(tr("Open skills folder")) { Open.url(AppPaths.skillsDir.absoluteString) }
                        .controlSize(.small).buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: Notifications

    @State private var notifyStatus: UNAuthorizationStatus?

    /// macOS blocks a denied app's notifications outright, so on its own our toggle is a
    /// switch wired to nothing: flipping it changes a boolean and the user still sees no
    /// banners. When the OS is the one saying no, say so and hand them the one place that
    /// can undo it — an app can't grant itself the permission back.
    @ViewBuilder private var notificationControls: some View {
        let blocked = notifyStatus == .denied

        Toggle(tr("Desktop notifications"), isOn: Binding(
            get: { model.settings.notifications },
            set: { on in
                var s = model.settings
                s.notifications = on
                model.saveSettings(s)
                guard on else { return }
                Task {
                    if notifyStatus == .notDetermined { notifyStatus = await Notifier.requestAuthorization() }
                    if notifyStatus == .denied { Notifier.openSystemSettings() }
                }
            }))
            .font(.system(size: 12))

        if model.settings.notifications, blocked {
            VStack(alignment: .leading, spacing: 6) {
                Label(tr("macOS is blocking Peck's notifications. Allow them in System Settings and this goes away."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(GH.attention)
                Button(tr("Open System Settings")) { Notifier.openSystemSettings() }
                    .controlSize(.small)
            }
        }

        Button(tr("Send test notification")) {
            Notifier.post(title: "Peck", body: "Test notification ✅",
                          subtitle: "If you see this, notifications work")
        }
        .controlSize(.small)
        .disabled(blocked)
    }

    @ViewBuilder private var avatar: some View {
        let placeholder = Image(systemName: "person.crop.circle.fill")
            .font(.system(size: 22)).foregroundStyle(GH.muted)
        if let s = model.user?.avatarUrl, let url = URL(string: s), !s.isEmpty {
            AsyncImage(url: url) { phase in
                if let img = phase.image {
                    img.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
            .frame(width: 24, height: 24)
            .clipShape(Circle())
        } else {
            placeholder
        }
    }

    private func toggle(_ title: String, _ keyPath: WritableKeyPath<AppSettings, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { var s = model.settings; s[keyPath: keyPath] = $0; model.saveSettings(s) }))
            .font(.system(size: 12))
    }

    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(GH.muted)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GH.subtle, in: RoundedRectangle(cornerRadius: 10))
    }
}
