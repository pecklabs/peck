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
            languagePicker(tr("Explanation language"), note: tr("Shown only to you."), \.explanationLanguage)
            languagePicker(tr("Review language"), note: tr("Posted to GitHub."), \.reviewLanguage)
        }
    }

    private var themePicker: some View {
        HStack {
            Text(tr("Appearance")).font(.system(size: 11))
            Spacer()
            Picker("", selection: Binding(
                get: { model.settings.themeMode },
                set: { var s = model.settings; s.themeMode = $0; model.saveSettings(s) })) {
                ForEach(ThemeMode.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        }
    }

    private func languagePicker(_ title: String, note: String? = nil, _ keyPath: WritableKeyPath<AppSettings, String>) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11))
            // Inline hint next to the label — same size, muted so it reads as a
            // caption rather than a second label.
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(GH.muted.opacity(0.6))
            }
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
    /// Live poll-interval *preset index* while dragging the slider; nil when not
    /// dragging. Lets the label track the drag but only persist (and reschedule
    /// the poll timer) once, on release — see `pollIntervalRow`.
    @State private var pollDraft: Double? = nil

    private var connectedSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            section(tr("GitHub"), "arrow.triangle.branch") {
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

            section(tr("Review settings"), "sparkles") {
                Text(tr("Review agent")).font(.system(size: 11))
                backendPicker
                backendStatus
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
                subgroupDivider
                languageControls
                subgroupDivider
                // Match the language-picker label style (11pt, regular) so this
                // heading doesn't tower over its section-mates.
                Text(tr("Review skills")).font(.system(size: 11))
                ForEach(Array(model.skills.enumerated()), id: \.element.id) { i, skill in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: skill.enabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(skill.enabled ? GH.success : GH.muted).font(.system(size: 11))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(skill.name).font(.system(size: 11, weight: .semibold))
                            Text(skill.description).font(.system(size: 10)).foregroundStyle(GH.muted).lineLimit(2)
                        }
                        Spacer()
                        // Global skill actions ride the first skill's row.
                        if i == 0 {
                            HStack(spacing: 12) {
                                Button { model.reloadSkills() } label: {
                                    Image(systemName: "arrow.clockwise")
                                }.buttonStyle(.borderless).help(tr("Reload"))
                                Button { Open.url(AppPaths.skillsDir.absoluteString) } label: {
                                    Image(systemName: "folder")
                                }.buttonStyle(.borderless).help(tr("Open folder"))
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            section(tr("AutoPilot"), "airplane") {
                VStack(alignment: .leading, spacing: 8) {
                    subgroup(tr("Self-review"))
                    toggle(tr("Auto-review on open"), \.selfReview)
                    if model.settings.selfReview {
                        toggle(tr("Auto re-review on new commits"), \.selfReviewOnPush)
                    }
                }
                .padding(.top, 6)
                subgroupDivider
                VStack(alignment: .leading, spacing: 8) {
                    subgroup(tr("Review requests"))
                    toggle(tr("Auto-review on request"), \.autoReview)
                    toggle(tr("Auto-submit when done"), \.autoSubmit)
                }
            }

            section(tr("General"), "gearshape") {
                themePicker
                languagePicker(tr("App language"), \.uiLanguage)
                pollIntervalRow
            }

            section(tr("Notifications"), "bell") {
                notificationControls
            }

            section(tr("About"), "info.circle") {
                HStack {
                    Text("\(tr("Version")) \(Self.appVersion)").font(.system(size: 12))
                    Spacer()
                    Button(tr("Check for Updates…")) { model.checkForUpdates() }
                        .controlSize(.small)
                        .disabled(!model.canCheckForUpdates)
                }
                HStack {
                    Button(tr("Quit Peck")) { NSApplication.shared.terminate(nil) }
                        .controlSize(.small)
                        .tint(GH.danger)
                    Spacer()
                }
            }
        }
    }

    private static let appVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    /// The poll cadences the slider snaps between. A short list of meaningful
    /// stops (not a fine continuous range) so the slider reads at a glance and
    /// the six tick marks stay sparse.
    private static let pollPresets: [(secs: Int, ko: String, en: String)] = [
        (30,   "30\u{cd08}", "30s"),
        (60,   "60\u{cd08}", "60s"),
        (300,  "5\u{bd84}",  "5m"),
        (600,  "10\u{bd84}", "10m"),
        (1800, "30\u{bd84}", "30m"),
        (3600, "1\u{c2dc}\u{ac04}", "1h"),
    ]

    /// The preset index nearest the stored cadence — so a legacy value that isn't
    /// exactly on a stop still lands on the closest one.
    private var pollPresetIndex: Int {
        let cur = model.settings.pollIntervalSec
        return Self.pollPresets.enumerated()
            .min { abs($0.element.secs - cur) < abs($1.element.secs - cur) }!.offset
    }

    /// Poll cadence as a native slider snapping across `pollPresets`. The label
    /// tracks the live drag via `pollDraft` (a preset index), but we only persist —
    /// and reschedule the poll timer — when the drag ends, so a drag doesn't
    /// thrash `saveSettings`.
    @ViewBuilder private var pollIntervalRow: some View {
        let idx = Int((pollDraft ?? Double(pollPresetIndex)).rounded())
        let preset = Self.pollPresets[idx]
        settingRow(tr("Refresh interval")) {
            HStack(spacing: 8) {
                // Fixed width + trailing align so the slider doesn't shift as the
                // readout changes width (30초 ↔ 1시간).
                Text(I18n.isKorean ? preset.ko : preset.en)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(GH.muted)
                    .frame(width: 46, alignment: .trailing)
                Slider(value: Binding(
                    get: { pollDraft ?? Double(pollPresetIndex) },
                    set: { pollDraft = $0 }),
                    in: 0...Double(Self.pollPresets.count - 1), step: 1,
                    onEditingChanged: { editing in
                        guard !editing, let v = pollDraft else { return }
                        var s = model.settings
                        s.pollIntervalSec = Self.pollPresets[Int(v.rounded())].secs
                        model.saveSettings(s)
                        pollDraft = nil
                    })
                    .frame(width: 150)
                    .controlSize(.small)
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

        settingRow(tr("Desktop notifications")) {
            Toggle("", isOn: Binding(
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
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }

        if model.settings.notifications, blocked {
            VStack(alignment: .leading, spacing: 6) {
                Label(tr("macOS is blocking Peck's notifications. Allow them in System Settings and this goes away."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(GH.attention)
                Button(tr("Open System Settings")) { Notifier.openSystemSettings() }
                    .controlSize(.small)
            }
        }

        if model.settings.notifications {
            toggle(tr("Notify when my PR gets feedback"), \.notifyMyPrFeedback)
        }

        Button(tr("Send test notification")) {
            Notifier.post(title: I18n.isKorean ? "테스트 알림" : "Test notification",
                          body: I18n.isKorean ? "알림이 정상 작동해요" : "Notifications are working")
        }
        .controlSize(.small)
        .disabled(blocked)
    }

    @ViewBuilder private var avatar: some View {
        let placeholder = Image(systemName: "person.crop.circle.fill")
            .font(.system(size: 28)).foregroundStyle(GH.muted)
        if let s = model.user?.avatarUrl, let url = URL(string: s), !s.isEmpty {
            AsyncImage(url: url) { phase in
                if let img = phase.image {
                    img.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(Circle())
        } else {
            placeholder
        }
    }

    private func toggle(_ title: String, _ keyPath: WritableKeyPath<AppSettings, Bool>) -> some View {
        settingRow(title) {
            Toggle("", isOn: Binding(
                get: { model.settings[keyPath: keyPath] },
                set: { var s = model.settings; s[keyPath: keyPath] = $0; model.saveSettings(s) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    /// Full-width settings row: label on the left, control pinned to the right.
    private func settingRow<C: View>(_ title: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            control()
        }
        .frame(maxWidth: .infinity)
    }

    /// A labeled sub-group heading inside a `section` — e.g. "Self-review" and
    /// "Review requests" under AutoPilot. Uses the primary text color (not the
    /// muted uppercase of the section title) so the two don't read as twin
    /// headers stacked together.
    private func subgroup(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(GH.fg)
    }

    /// A faint separator between sub-groups — lighter than the stock `Divider`
    /// so it recedes behind the content.
    private var subgroupDivider: some View {
        Rectangle().fill(GH.border.opacity(0.4)).frame(height: 1)
    }

    @ViewBuilder private func section<Content: View>(_ title: String, _ systemImage: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
                Text(title.uppercased()).font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(GH.muted)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GH.subtle, in: RoundedRectangle(cornerRadius: 10))
    }
}
