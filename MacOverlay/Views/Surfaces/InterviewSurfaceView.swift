import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Primary surface for the Interview flow. Two states:
///   - `vm.isInterviewSession == false` → setup form (pick new/previous
///     session, optional resume, optional context, system prompt, Start).
///   - `vm.isInterviewSession == true`  → live interview view — reuses
///     `ChatSurfaceView` so the running session looks identical to the
///     chat surface (transcript strip + Live Focus card / bubbles).
struct InterviewSurfaceView: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        Group {
            if vm.interviewSurfaceShowsChat {
                ChatSurfaceView()
            } else {
                setupForActiveMode
            }
        }
    }

    /// Pick the setup form by mode tab. Both forms render a shared mode
    /// bar at the top so toggling between them feels like swapping tabs
    /// rather than navigating to a new screen.
    @ViewBuilder
    private var setupForActiveMode: some View {
        switch vm.interviewSurfaceMode {
        case .interview:   InterviewSetupForm()
        case .regularCall: RegularCallSetupForm()
        }
    }
}

// MARK: - Mode bar (shared header)

/// Pills at the top of either setup form: Interview / Regular call.
/// Toggles `vm.interviewSurfaceMode` which drives both the setup body
/// and the kind of session that gets resumed when the user re-enters
/// the surface.
private struct InterviewModeBar: View {
    @Environment(OverlayViewModel.self) private var vm

    private let modes = OverlayViewModel.InterviewSurfaceMode.available

    var body: some View {
        if modes.count > 1 {
            bar
        }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            ForEach(modes, id: \.self) { mode in
                Button {
                    vm.switchInterviewSurfaceMode(mode)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(mode.displayName)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .setupChip(selected: vm.interviewSurfaceMode == mode)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

// MARK: - Setup form

/// The primary action, pinned below the scrolling part of a setup form.
///
/// Every setup form used to end with it as the final row of the `ScrollView`,
/// which meant that once the Context box held a whole job description the one
/// action the screen exists for was below the fold. A hairline and the shell
/// fill keep it legible while the form scrolls under it.
private struct PinnedSetupAction<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Design.Surface.separator)
                .frame(height: 0.5)
            content
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
        }
        .background(Design.Surface.shellFill)
    }
}

private struct InterviewSetupForm: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var showCreatePrompt = false

    var body: some View {
        @Bindable var vm = vm
        // Start is pinned below the scroll rather than being the form's last
        // row. With a whole job description in the Context box it fell below
        // the fold, so the one action this screen exists for needed a scroll
        // to reach.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    InterviewModeBar()
                    header
                    sessionPicker
                    languagePicker
                    resumePicker
                    contextEditor
                    nameRow
                    // Directly under the inputs it consumes. The order now
                    // reads as a sequence: add a resume, add context, then
                    // prepare.
                    PrepPanelView()
                    promptPicker
                    autoGenerateRow
                    modelPickerRow
                    depthRow
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
            .hiddenScrollGutter()

            PinnedSetupAction { startRow }
        }
        .sheet(isPresented: $showCreatePrompt) {
            CreatePromptSheet(mode: .interview, isPresented: $showCreatePrompt)
        }
    }

    /// Auto-generate suggestion checkbox. When ON, the AI streams a
    /// suggested response into the chat as the interview transcript
    /// updates. When OFF, the user controls send via the bar's Send
    /// button — useful when the interviewer is still mid-question.
    private var autoGenerateRow: some View {
        @Bindable var vm = vm
        return HStack(spacing: 8) {
            Toggle(isOn: $vm.interviewAutoGenerate) {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Design.Ink.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto-generate responses")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Answers each real question as it's asked.")
                            .font(.system(size: 10))
                            .foregroundColor(Design.Ink.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Spacer()
        }
    }

    // MARK: Sections

    private var header: some View {
        Text("Set up your interview")
            .font(.system(size: 18, weight: .semibold))
    }

    private var languagePicker: some View {
        SetupSection(title: "Language") {
            TranscriptionLanguagePicker()
        }
    }

    private var sessionPicker: some View {
        SetupSection(title: "Session") {
            HStack(spacing: 6) {
                SetupChipButton(
                    title: "New interview",
                    icon: "plus.circle",
                    selected: vm.interviewResumeSessionID == nil
                ) {
                    vm.interviewResumeSessionID = nil
                }

                Menu {
                    Button("New interview") {
                        vm.interviewResumeSessionID = nil
                    }
                    Divider()
                    let recents = vm.sessionStore.sortedSessions.prefix(20)
                    if recents.isEmpty {
                        Text("No past sessions yet").font(.caption)
                    } else {
                        ForEach(Array(recents), id: \.id) { s in
                            Button(s.displayTitle) {
                                vm.interviewResumeSessionID = s.id
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .medium))
                        Text(previousSessionLabel)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Design.Ink.secondary)
                    }
                    .setupChip(selected: vm.interviewResumeSessionID != nil)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private var previousSessionLabel: String {
        if let id = vm.interviewResumeSessionID,
           let s = vm.sessionStore.sessions.first(where: { $0.id == id }) {
            return s.displayTitle
        }
        return "Previous session"
    }

    private var resumePicker: some View {
        SetupSection(title: "Resume", optional: true) {
            HStack(spacing: 6) {
                if let url = vm.interviewResumeFileURL {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Design.Ink.secondary)
                        Text(url.lastPathComponent)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(-1)
                        Button {
                            vm.interviewResumeFileURL = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Design.Ink.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove resume")
                    }
                    .setupChip()
                }

                Button {
                    pickResumeFile()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .medium))
                        Text(vm.interviewResumeFileURL == nil ? "Upload file" : "Replace")
                    }
                    .setupChip()
                }
                .buttonStyle(.plain)
                // A whole word beats half of one: without this both the
                // filename and this button truncate, so the row reads
                // "A...pdf  Repla..." and neither says what it does.
                .fixedSize()
                .help("PDF · DOCX · RTF · TXT · MD")

                // Resume text is extracted in the background the moment the
                // file is picked, so Start doesn't block on parsing. All three
                // states have to be visible: a failure that renders nothing
                // is indistinguishable from no file having been chosen, and
                // that is exactly how a scanned PDF used to look.
                //
                // One line, always. The status used to wrap to two lines and
                // sat beside a chip and a button of two different heights, so
                // the row read as broken rather than as a row.
                if vm.interviewResumeFileURL != nil {
                    if vm.isPreparingResume {
                        status("Reading…")
                    } else if let problem = vm.interviewResumeError {
                        // The reason, in full, and a way out. Truncating this
                        // hides the only actionable sentence in it.
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                            Text(problem)
                                .font(.system(size: 11))
                                .foregroundColor(Design.Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if !vm.interviewResumeText.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.green)
                            Text("Ready")
                                .font(.system(size: 11))
                                .foregroundColor(Design.Ink.secondary)
                                .lineLimit(1)
                                .help("\(vm.interviewResumeText.count) characters read from the CV")
                        }
                        .fixedSize()
                    }
                }

                Spacer()
            }
        }
    }

    /// A spinner and its label, on the row's own height so the row cannot grow
    /// taller than the chips beside it.
    private func status(_ text: String) -> some View {
        HStack(spacing: 5) {
            ProgressView().controlSize(.mini)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(Design.Ink.secondary)
                .lineLimit(1)
        }
        .fixedSize()
    }

    private var contextEditor: some View {
        @Bindable var vm = vm
        return ContextSection(
            placeholder: "Role, company, JD, talking points…",
            help: "PDF · DOCX · RTF · TXT · MD — text is extracted and sent as context.",
            text: $vm.interviewContext,
            files: $vm.interviewContextFiles
        )
    }

    /// The name substituted for `{NAME}` in prompts — and the greeting name on
    /// calendar reminders. It lived in Settings → Profile beside Role and
    /// Company, neither of which any prompt asked for; the one field that does
    /// something moved here, next to the context it personalises.
    private var nameRow: some View {
        @Bindable var vm = vm
        return SetupSection(title: "Your name", optional: true) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Alex", text: $vm.userProfile.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 220)
                Text("Fills {NAME} in your prompts, and greets you on calendar reminders.")
                    .font(.system(size: 11))
                    .foregroundColor(Design.Ink.secondary)
            }
        }
    }

    /// The prompt the interview runs. Resolved for `.interview`, so the call tab
    /// showing the interview's prompt is no longer possible.
    private var promptPicker: some View {
        PromptPickerRow(mode: .interview, defaultLabel: "Default (Interview)") {
            showCreatePrompt = true
        }
    }
    /// Which model answers the interview. The setup screen had no model
    /// control at all, so the only way to change it was after starting, from
    /// the bar. Now it sits directly above Start and uses the same shared
    /// picker as Settings and the bar, so all four surfaces agree.
    /// How much each answer should say. The prompt used to hard-code "at most
    /// 3 short bullets" for every question, which suited a yes/no question
    /// and starved a design question. Chosen per interview, because nobody is
    /// picking this mid-answer.
    private var depthRow: some View {
        @Bindable var vm = vm
        return SetupSection(title: "Answer depth") {
            HStack(spacing: 10) {
                Picker("", selection: $vm.answerDepth) {
                    ForEach(AnswerDepth.allCases) { d in
                        Text(d.displayName).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .help("How much each answer should say")

                Text(vm.answerDepth.blurb)
                    .font(.system(size: 11))
                    .foregroundColor(Design.Ink.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private var modelPickerRow: some View {
        SetupSection(title: "Answer model") {
            HStack(spacing: 10) {
                Text("Used for every answer in this interview. Switchable mid-session.")
                    .font(.system(size: 11))
                    .foregroundColor(Design.Ink.secondary)
                Spacer(minLength: 8)
                ModelPickerButton(
                    currentModelName: OverlayViewModel.availableModels
                        .first { $0.id == vm.selectedModel }?.name ?? "Model"
                )
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var startRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !vm.missingRequiredKeys.isEmpty {
                MissingKeyWarning()
            }
            HStack {
                Spacer()
                Button {
                    vm.beginInterviewFromSetup()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("Start interview")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(Design.Ink.inverse)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Design.Ink.primary))
                    .overlay(Capsule().strokeBorder(Design.Surface.strongHairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(!vm.missingRequiredKeys.isEmpty)
                .opacity(vm.missingRequiredKeys.isEmpty ? 1 : 0.45)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Start interview (⌘↩)")
            }
        }
    }

    // MARK: Helpers

    private func pickResumeFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .pdf, .plainText,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "rtf")  ?? .data,
            UTType(filenameExtension: "md")   ?? .plainText,
        ]
        if panel.runModal() == .OK, let url = panel.url {
            vm.interviewResumeFileURL = url
        }
    }

}

// MARK: - Regular call setup form

/// Lighter setup form for the "Regular call" mode tab. No resume, no JD —
/// just a system prompt picker, free-text + file context, and a Call/Chat
/// toggle that picks between starting a live mic session (Call) or a
/// text-only chat (Chat).
private struct RegularCallSetupForm: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var showCreatePrompt = false

    var body: some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    InterviewModeBar()
                    header
                    contextEditor
                    promptPicker
                    modeToggleRow
                    if vm.regularCallAsCall { languagePicker }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
            .hiddenScrollGutter()

            PinnedSetupAction { startRow }
        }
        .sheet(isPresented: $showCreatePrompt) {
            CreatePromptSheet(mode: promptMode, isPresented: $showCreatePrompt)
        }
    }

    private var header: some View {
        Text("Set up a call")
            .font(.system(size: 18, weight: .semibold))
    }

    private var languagePicker: some View {
        SetupSection(title: "Language") {
            TranscriptionLanguagePicker()
        }
    }

    private var contextEditor: some View {
        @Bindable var vm = vm
        return ContextSection(
            placeholder: "Who is the call with? What's the goal? Any background…",
            help: "PDF · DOCX · RTF · TXT · MD — text extracted into context.",
            // The call's own field. It used to be the interview's, so this tab
            // opened holding a job description.
            text: $vm.callContext,
            files: $vm.callContextFiles
        )
    }

    private var promptPicker: some View {
        PromptPickerRow(mode: promptMode, defaultLabel: "Default (Call)") {
            showCreatePrompt = true
        }
    }

    /// The mode this form's session will actually run: a live call is `.call`,
    /// a text chat is `.general`. The prompt picker resolves for it, so a call
    /// cannot display the interview's prompt.
    private var promptMode: SessionMode {
        vm.regularCallAsCall ? .call : .general
    }

    /// Call vs Chat segmented control. Call = live mic + transcription
    /// (same engine as Interview, just with a different system prompt).
    /// Chat = text-only, the user types in the bar.
    private var modeToggleRow: some View {
        @Bindable var vm = vm
        return SetupSection(title: "Mode") {
            HStack(spacing: 6) {
                SetupChipButton(title: "Call (live)",
                            icon: "phone.fill",
                            selected: vm.regularCallAsCall) {
                    vm.regularCallAsCall = true
                }
                SetupChipButton(title: "Chat (text)",
                            icon: "bubble.left.and.bubble.right.fill",
                            selected: !vm.regularCallAsCall) {
                    vm.regularCallAsCall = false
                }
                Spacer()
            }
        }
    }

    private var startRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !vm.missingRequiredKeys.isEmpty {
                MissingKeyWarning()
            }
            startButtonRow
        }
    }

    private var startButtonRow: some View {
        HStack {
            Spacer()
            Button {
                vm.beginRegularCallFromSetup()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: vm.regularCallAsCall ? "phone.fill" : "paperplane.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(vm.regularCallAsCall ? "Start call" : "Start chat")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(Design.Ink.inverse)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Capsule().fill(Design.Ink.primary))
                .overlay(Capsule().strokeBorder(Design.Surface.strongHairline, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(!vm.missingRequiredKeys.isEmpty)
            .opacity(vm.missingRequiredKeys.isEmpty ? 1 : 0.45)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Start (⌘↩)")
        }
    }
}

// MARK: - Missing-key warning

/// Amber banner shown above Start when the selected model has no API key
/// configured. Without it, the session starts, the mic records, and every
/// answer silently never arrives — the single most confusing failure a
/// new user can hit. Tapping it jumps straight to the key fields.
private struct MissingKeyWarning: View {
    @Environment(OverlayViewModel.self) private var vm

    /// "Add your OpenCode key to start" reads as "the app requires OpenCode",
    /// which sends the user hunting for a key they never needed — the key is
    /// only asked for because of the model currently chosen, and some models
    /// live on OpenCode's catalogue. When that model's own gateway key is the
    /// missing one, name the model and the way out (switch models); keep the
    /// generic wording for everything else (transcription keys).
    private var warningText: String {
        if !vm.hasModelAccess {
            let provider = vm.keyForSelectedModel.provider
            let name = OpenRouterCatalog.shared.model(id: vm.selectedModel)?.name
                ?? vm.selectedModel
            return "\(name) runs on \(provider). Add your \(provider) key, or pick another model."
        }
        let keys = vm.missingRequiredKeys.joined(separator: " and ")
        return "Add your \(keys) key\(vm.missingRequiredKeys.count > 1 ? "s" : "") to start. Click to open API keys."
    }

    var body: some View {
        Button {
            (NSApp.delegate as? AppDelegate)?.showPreferences()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Design.Accent.amber)
                Text(warningText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Design.Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Design.Accent.amber.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Design.Accent.amber.opacity(0.35), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Settings → AI to add your API keys")
    }
}
