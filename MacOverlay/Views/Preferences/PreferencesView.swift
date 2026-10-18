import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Tabbed preferences window body. Replaces the cramped gear popover.
struct PreferencesView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var tab: Tab = .general
    @State private var showNewWorkspaceSheet = false
    @State private var isSidebarCollapsed = false

    /// Diagnostic hook: `--args -settings-tab <name>` opens that tab at
    /// launch, so each one can be photographed in turn. Used to compare the
    /// tabs against each other for consistency; harmless otherwise.
    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-settings-tab"),
           args.indices.contains(i + 1),
           let match = Tab.allCases.first(where: {
               $0.rawValue.lowercased() == args[i + 1].lowercased()
           }) {
            _tab = State(initialValue: match)
        }
    }

    // Model catalogue filters (AI tab). The OpenRouter catalogue runs to
    // several hundred entries, so this list needs narrowing controls or it
    // is unusable.
    @State private var customModelDraft = ""
    @AppStorage(KeywordStyle.defaultsKey) private var keywordStyle = KeywordStyle.standard

    enum Tab: String, CaseIterable, Identifiable {        case general    = "General"
        case panel      = "Panel"
        case profile    = "Profile"
        case ai         = "AI"
        case quickAsk   = "Quick Ask"
        case prompts    = "Prompts"
        case memory     = "Memory"
        case workspaces = "Workspaces"
        case peer       = "Peer"
        case shortcuts  = "Shortcuts"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general:    return "gearshape.fill"
            case .panel:      return "rectangle.bottomthird.inset.filled"
            case .profile:    return "person.crop.circle.fill"
            case .ai:         return "sparkles"
            case .quickAsk:   return "bolt.fill"
            case .prompts:    return "text.bubble.fill"
            case .memory:     return "brain.head.profile"
            case .workspaces: return "square.grid.2x2.fill"
            case .peer:       return "person.2.fill"
            case .shortcuts:  return "keyboard.fill"
            }
        }
        /// Whether this tab should be visible in the rail. Gated tabs are
        /// kept in the enum (and their `case` arms below still resolve) so
        /// flipping the corresponding FeatureFlag is a one-line change.
        @MainActor var isVisible: Bool {
            switch self {
            case .panel, .profile:
                return false
            case .memory:     return true
            case .workspaces: return FeatureFlags.workspacesEnabled
            case .peer:       return FeatureFlags.peerControlEnabled
            case .quickAsk:   return FeatureFlags.quickAskEnabled
            default:          return true
            }
        }
    }

    // Wide enough for the tab names to sit beside their icons. This view now
    // lives in a window rather than a 440pt panel, so the labels are the
    // default: an icon-only rail was the reason half of Settings could not be
    // found.
    private var sidebarWidth: CGFloat { isSidebarCollapsed ? 52 : 172 }

    var body: some View {
        HStack(spacing: 0) {
            // Left tab rail.
            VStack(alignment: isSidebarCollapsed ? .center : .leading, spacing: 0) {
                sidebarHeader

                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Tab.allCases.filter(\.isVisible)) { t in
                        tabRow(t)
                    }
                }
                .padding(.horizontal, 6)

                Spacer()

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 0.5)
                    .padding(.horizontal, isSidebarCollapsed ? 8 : 12)

                quitRow
                    .padding(.horizontal, 6)
                    .padding(.bottom, 10)
            }
            .frame(width: sidebarWidth)
            .background(Color.white.opacity(0.03))
            .animation(Design.Motion.fast, value: isSidebarCollapsed)

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 0.5)

            // Content column. The scrolling body fills the column to the
            // right of the rail. The previous top text-size toolbar was
            // removed — font size lives in Panel → Bottom panel and the
            // floating widget on top of every Settings tab was just
            // visual noise.
            VStack(spacing: 0) {
                ScrollView {
                    Group {
                        switch tab {
                        case .general:    generalTab
                        case .panel:      panelTab
                        case .profile:    profileTab
                        case .ai:         aiTab
                        case .quickAsk:   quickAskTab
                        case .prompts:    promptsTab                        case .memory:     memoryTab
                        case .workspaces: workspacesTab
                        case .peer:       peerTab
                        case .shortcuts:  shortcutsTab
                        }
                    }
                    // Same padding on every tab, including Prompts. It used to
                    // be special-cased to zero because its list is built as a
                    // full-bleed surface (it is also the overlay's Prompts
                    // screen) — but in this window that made it the one tab
                    // running edge to edge while all the others sat in an
                    // inset card, which is what "not uniform across the tabs"
                    // was. `promptsTab` now supplies its own card.
                    .padding(14)
                    // Extra room under the last control. At 14 the final row
                    // (Onboarding's button) sat flush against the panel's
                    // bottom edge, which reads as clipped rather than ended.
                    .padding(.bottom, 20)
                    .frame(maxWidth: 640, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .hiddenScrollGutter()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showNewWorkspaceSheet) {
            NewWorkspaceSheet(isPresented: $showNewWorkspaceSheet)
                .environment(vm)
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            if !isSidebarCollapsed {
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundColor(.primary)
                Spacer(minLength: 0)
            }

            Button {
                withAnimation(Design.Motion.fast) {
                    isSidebarCollapsed.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Design.Ink.secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Design.Surface.controlFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Design.Surface.hairline, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help(isSidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
            .accessibilityLabel(Text(isSidebarCollapsed ? "Expand sidebar" : "Collapse sidebar"))
        }
        .padding(.horizontal, isSidebarCollapsed ? 0 : 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: isSidebarCollapsed ? .center : .leading)
    }

    private func tabRow(_ t: Tab) -> some View {
        let active = tab == t
        return Button {
            withAnimation(Design.Motion.fast) { tab = t }
        } label: {
            HStack(spacing: isSidebarCollapsed ? 0 : 8) {
                // Plain SF Symbol — same monochrome treatment as the bar
                // icons. No colored tile, no dark background.
                Image(systemName: t.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(active ? .primary : .secondary)
                    .frame(width: 18, height: 20)

                if !isSidebarCollapsed {
                    Text(t.rawValue)
                        .font(.system(size: 13, weight: active ? .semibold : .regular))
                        .foregroundColor(active ? .primary : .primary.opacity(0.85))
                        .lineLimit(1)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: isSidebarCollapsed ? .center : .leading)
            .padding(.horizontal, isSidebarCollapsed ? 0 : 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? Design.Accent.brand.opacity(0.22) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t.rawValue)
        .accessibilityLabel(Text(t.rawValue))
    }

    /// Quit, pinned to the bottom of the rail so it is present on every tab.
    ///
    /// The overlay floats above every window and hides itself from screen
    /// sharing, and Quit lived only in its ⋯ menu. With the overlay hidden —
    /// or while in Settings, where that menu is not on screen at all — there
    /// was no way out short of hunting for the menu bar icon. `⌘Q` works too,
    /// for as long as this window is key.
    private var quitRow: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            HStack(spacing: isSidebarCollapsed ? 0 : 8) {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Design.Ink.secondary)
                    .frame(width: 18, height: 20)

                if !isSidebarCollapsed {
                    Text("Quit TheCloser")
                        .font(.system(size: 13))
                        .foregroundColor(Design.Ink.secondary)
                        .lineLimit(1)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: isSidebarCollapsed ? .center : .leading)
            .padding(.horizontal, isSidebarCollapsed ? 0 : 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q")
        .help("Quit TheCloser (⌘Q)")
        .accessibilityLabel(Text("Quit TheCloser"))
    }

    // MARK: - Tabs

    @ViewBuilder
    private var promptsTab: some View {
        // The library is built as a full-bleed surface — it is also the
        // overlay's Prompts screen, with its own header row and divider.
        // Now that every tab shares the same outer padding, that header
        // would sit flush against the rail, so this tab supplies the same
        // card treatment the others get from `section`.
        PromptLibraryView()
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.md, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.md, style: .continuous)
                    .fill(Color.white.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.md, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
    }
    /// Panel customisation. Currently scoped to the bottom input bar.
    @ViewBuilder
    private var panelTab: some View {
        @Bindable var bar = vm.barCustomization

        section(title: "Bottom panel",
                icon: "rectangle.bottomthird.inset.filled",
                subtitle: "The input bar at the bottom. Choose which controls appear. The brand logo is always shown.") {
            Toggle(isOn: $bar.showTextField) {
                labelTwoLine(title: "Text field",
                             subtitle: "The “Ask anything” input. Hide it if you mostly drive the overlay by voice or shortcuts.")
            }.toggleStyle(.switch)

            Toggle(isOn: $bar.showNewSession) {
                labelTwoLine(title: "New session (+)",
                             subtitle: "Starts a fresh chat session.")
            }.toggleStyle(.switch)

            Toggle(isOn: $bar.showHistory) {
                labelTwoLine(title: "History",
                             subtitle: "Browse past sessions.")
            }.toggleStyle(.switch)

            Toggle(isOn: $bar.showMode) {
                labelTwoLine(title: "Mode picker",
                             subtitle: "Switch between General, Interview, Meeting, Call modes.")
            }.toggleStyle(.switch)

            Toggle(isOn: $bar.showResume) {
                labelTwoLine(title: "Resumes",
                             subtitle: "Open the resume tailoring panel.")
            }.toggleStyle(.switch)

            Toggle(isOn: $bar.showModel) {
                labelTwoLine(title: "Model picker",
                             subtitle: "Switch between Anthropic / OpenAI models.")
            }.toggleStyle(.switch)

            Toggle(isOn: $bar.showMic) {
                labelTwoLine(title: "Microphone",
                             subtitle: "Start / stop voice recording.")
            }.toggleStyle(.switch)

            Toggle(isOn: $bar.showSend) {
                labelTwoLine(title: "Send button",
                             subtitle: "Submit the typed prompt. (You can always press ⏎.)")
            }.toggleStyle(.switch)
        }

        section(title: "") {
            HStack {
                Spacer()
                Button("Reset to defaults") { bar.resetToDefaults() }
                    .buttonStyle(.secondaryCompact)
            }
        }
    }

    @ViewBuilder
    private var generalTab: some View {
        @Bindable var vm = vm
        section(title: "Appearance") {
            sliderRow("Opacity", value: $vm.opacity, range: 0.2...1.0)
            sliderRow("Background", value: $vm.backgroundOpacity, range: 0.0...1.0,
                      display: { $0 == 0 ? "Off" : "\(Int($0 * 100))%" })
            sliderRow("Text size", value: $vm.textScale, range: 0.8...1.6)
            keywordStyleRow
        }

        section(title: "Recording") {
            Toggle(isOn: $vm.suggestSessionOnCall) {
                labelTwoLine(title: "Offer to start when a call begins",
                             subtitle: "When Zoom, Meet or Teams starts using your mic.")
            }
            .toggleStyle(.switch)

            HStack(alignment: .top, spacing: 12) {
                    labelTwoLine(title: "Transcription engine",
                                 subtitle: "Apple runs on this Mac. ElevenLabs and Grok need a key.")
                        // Takes all the room the picker doesn't. Without this
                        // the label was squeezed to its longest word and the
                        // subtitle wrapped into a five-line sliver with a
                        // hand's width of dead space beside it.
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Picker("", selection: $vm.transcriptionPreference) {
                        ForEach(OverlayViewModel.TranscriptionPreference.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 150)
            }

            // Shown instead of letting the macOS dialog reappear on every
            // launch. `x-apple.systempreferences:` is the supported way to
            // deep-link a Privacy pane.
            if vm.needsScreenRecordingPermission {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Screen Recording is not granted.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.orange)
                    Text("Needed only to capture system audio — for example when the interviewer is on the other side of a Zoom call. Text answers work without it.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Open Screen Recording settings",
                         destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        .font(.system(size: 10))
                    if CGPreflightScreenCaptureAccess() {
                        Text("Granted — this notice will disappear.")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                    }
                }
            }
        }

        section(title: "Privacy") {
            Toggle(isOn: $vm.screenShareInvisible) {
                labelTwoLine(title: "Hide from screen sharing",
                             subtitle: "Keeps the overlay out of screen shares and recordings.")
            }
            .toggleStyle(.switch)
        }

        section(title: "Onboarding") {
            Button("Replay welcome tour") { vm.showOnboarding = true }
                .buttonStyle(.secondaryCompact)
        }
    }

    @ViewBuilder
    private var quickAskTab: some View {
        @Bindable var vm = vm

        section(title: "Custom prompt",
                subtitle: "How Quick Ask should answer. Leave empty to use the built-in concise default.") {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                TextEditor(text: $vm.quickAskCustomPrompt)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 12))
                    .padding(8)
                    .frame(minHeight: 90, maxHeight: 170)
                if vm.quickAskCustomPrompt.isEmpty {
                    Text(OverlayViewModel.defaultQuickAskPrompt)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.5))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
        }

        section(title: "Context files",
                subtitle: "Their text is sent with every Quick Ask — a cheat-sheet, product notes, your bio, etc.") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        pickQuickAskFiles()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "paperclip")
                                .font(.system(size: 11, weight: .medium))
                            Text(vm.quickAskFiles.isEmpty ? "Attach files" : "Attach more")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("PDF · DOCX · RTF · TXT · MD — text is extracted and stored locally. Re-attaching a file with the same name replaces it.")
                    Spacer()
                }

                ForEach(vm.quickAskFiles) { f in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(f.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(charCountLabel(f.extractedText.count))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button {
                            vm.removeQuickAskFile(id: f.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                }
            }
        }

        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.top, 1)
            Text("Quick Ask favours latency: when an Anthropic key is set it answers on Haiku (much faster first token) instead of the chat's selected model.")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Compact "how much text rides along" label for a file chip.
    private func charCountLabel(_ count: Int) -> String {
        count >= 1000 ? "\(count / 1000)k chars" : "\(count) chars"
    }

    /// Open a picker and attach the chosen docs to Quick Ask. Text is
    /// extracted synchronously here (settings adds are infrequent and the
    /// files are usually small) and only the name + text are stored.
    private func pickQuickAskFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            .pdf, .plainText,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "rtf")  ?? .data,
            UTType(filenameExtension: "md")   ?? .plainText,
        ]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let text = (try? ResumeImporter.importFile(url: url)) ?? ""
            vm.appendQuickAskFile(name: url.lastPathComponent, extractedText: text)
        }
    }

    @ViewBuilder
    private var profileTab: some View {
        @Bindable var vm = vm
        section(title: "About you",
                subtitle: "Personalises interview and meeting responses. All optional.") {
            field("Name",    placeholder: "Alex",                text: $vm.userProfile.name)
            field("Role",    placeholder: "Software Engineer",   text: $vm.userProfile.currentRole)
            field("Company", placeholder: "Acme",                text: $vm.userProfile.company)
        }
    }

    @ViewBuilder
    private var aiTab: some View {
        @Bindable var vm = vm
        let store = vm.promptStore


        section(title: "Answer speed",
                subtitle: "Ask models that can to answer without a long thinking block first.") {
            Toggle(isOn: Binding(
                get: { AIManager.allowModelThinking },
                set: { AIManager.allowModelThinking = $0 })) {
                labelTwoLine(title: "Let models think first",
                             subtitle: "Off is faster for interview questions. Turn on for open-ended or maths questions.")
            }
            .toggleStyle(.switch)

            let fast = OpenRouterCatalog.reasoningEffortIDs.count
            Text(fast == 0
                 ? "No model metadata yet — fetch the OpenRouter catalogue to apply this to every model that supports it."
                 : "Applied to \(fast) of \(OpenRouterCatalog.shared.allModels.count) models. Models that still think regardless are left alone.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }

        section(title: "Model picker",
                subtitle: "Choose which models show in the model menu.") {
            modelCatalog
            HStack(spacing: 4) {
                Text("Missing a model?")
                    .foregroundColor(.secondary)
                Link("Request it", destination: modelRequestURL)
            }
            .font(.system(size: 11))
        }

        section(title: "API keys",
                subtitle: "OpenRouter runs the models. ElevenLabs or xAI (Grok) transcribes: add the one you use. Stored only on this Mac.") {
            KeyFieldView(label: "OpenRouter", placeholder: "sk-or-…",     text: $vm.openRouterAPIKey)
            KeyFieldView(label: "ElevenLabs", placeholder: "sk_…",        text: $vm.elevenLabsAPIKey)
            KeyFieldView(label: "xAI (Grok)", placeholder: "xai-…",       text: $vm.grokAPIKey)
        }

        if FeatureFlags.resumesEnabled {
        section(title: "Resume model",
                subtitle: "Which Claude model edits the DOCX. Haiku handles most résumé tweaks well and is roughly 3× cheaper per run.") {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                labelTwoLine(title: "Generation model",
                             subtitle: "Used for the tailoring call(s). Scoring always runs on Haiku.")
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Picker("", selection: $vm.resumeGenerationModel) {
                    ForEach(OverlayViewModel.ResumeGenerationModel.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 200)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                labelTwoLine(title: "Generation mode",
                             subtitle: "Fast does one call. Quality runs an agent loop that verifies each edit but is ~15× more expensive.")
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Picker("", selection: $vm.resumeMode) {
                    ForEach(OverlayViewModel.ResumeMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 200)
            }
            Toggle(isOn: $vm.resumeSkipScoring) {
                labelTwoLine(title: "Skip ATS scoring",
                             subtitle: "Skips the pre- and post-generation score calls. Saves ~25% per run; hides the before/after delta.")
            }
            .toggleStyle(.switch)
        }

        section(title: "Resume prompts",
                subtitle: "Pick a saved prompt, or drop in a one-off override. Save-as-preset to reuse across sessions.") {
            resumePromptPicker(
                kind: .resumeGeneration,
                label: "Generation prompt",
                overrideBinding: $vm.customResumeGenerationPrompt,
                activeIDBinding: Binding(
                    get: { store.activeResumeGenerationID },
                    set: { store.activeResumeGenerationID = $0 }
                ),
                defaultText: OverlayViewModel.defaultResumeGenerationPrompt
            )
            .padding(.bottom, 8)

            resumePromptPicker(
                kind: .resumeScoring,
                label: "Scoring prompt",
                overrideBinding: $vm.customResumeScoringPrompt,
                activeIDBinding: Binding(
                    get: { store.activeResumeScoringID },
                    set: { store.activeResumeScoringID = $0 }
                ),
                defaultText: OverlayViewModel.defaultResumeScoringPrompt
            )
        }
        } // if FeatureFlags.resumesEnabled
    }

    /// The website's model request form. Says which source is asking, and
    /// nothing about who.
    private var modelRequestURL: URL {
        var components = URLComponents(string: "https://www.thecloser.tech/request-model")!
        components.queryItems = [
            URLQueryItem(name: "source", value: "app"),
            URLQueryItem(name: "plan", value: "own_keys"),
        ]
        return components.url!
    }

    /// Kept out of the toolbar body because the string concatenation made
    /// the type-checker give up on the whole view.
    private func retiredNotice(_ catalog: OpenRouterCatalog) -> some View {
        let ids: [String] = catalog.retired
            .prefix(3)
            .map { $0.replacingOccurrences(of: "openrouter/", with: "") }
        let head = ids.joined(separator: ", ")
        let tail = catalog.retired.count > 3 ? "…" : ""
        let noun = catalog.retired.count == 1 ? "model" : "models"
        return Text("\(catalog.retired.count) \(noun) no longer offered: \(head)\(tail). The list has been updated.")
            .font(.system(size: 10))
            .foregroundColor(.orange)
    }

    /// Catalogue of every model the app can reach, grouped by provider.
    ///
    /// Before this existed the list was a hardcoded eleven entries and there
    /// Settings → AI. Filters come from `ModelFilterStore.shared` — the same
    /// store the overlay's picker reads — so both screens answer "which
    /// models am I looking at" identically.
    ///
    /// The rows here toggle whether a model is *reachable* from the picker,
    /// whereas in the picker a row *selects* the model. Different action, one
    /// list.
    @ViewBuilder
    private var modelCatalog: some View {
        let catalog = OpenRouterCatalog.shared
        let visibility = ModelVisibility.shared
        let store = ModelFilterStore.shared
        let filteredIDs = store.matchingIDs
        let allIDs = OverlayViewModel.availableModels.map(\.id)
        let visibleCount = filteredIDs.filter { visibility.isVisible($0) }.count

        LazyVStack(alignment: .leading, spacing: 12) {
            catalogueToolbar(catalog: catalog)

            if let error = catalog.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }

            ModelFilterBar(store: store)

            if store.groupedModels.isEmpty {
                Text(store.isFiltering ? "No models match these filters."
                                      : "No models available.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                Text("\(visibleCount) of \(filteredIDs.count) shown in the model picker")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
            }

            ForEach(store.groupedModels, id: \.provider) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.provider)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.85))
                        .textCase(.uppercase)
                        .kerning(0.4)
                    LazyVStack(spacing: 1) {
                        ForEach(group.models, id: \.id) { m in
                            visibilityToggleRow(model: m, visibility: visibility,
                                                allIDs: allIDs)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                // Scoped to the active filters — see `showAll(among:)`.
                Button("Show all \(filteredIDs.count)") {
                    visibility.showAll(among: filteredIDs)
                }
                .buttonStyle(.secondaryCompact)
                .disabled(filteredIDs.allSatisfy(visibility.isVisible))

                Button("Hide all") { visibility.hideAll(among: filteredIDs) }
                    .buttonStyle(.secondaryCompact)
                    .disabled(filteredIDs.allSatisfy { !visibility.isVisible($0) })

                Spacer()
            }
        }
    }

    /// Fetch / add-custom / search controls above the model list.
    private func catalogueToolbar(catalog: OpenRouterCatalog) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Task { await catalog.fetchCatalogue() }
                } label: {
                    if catalog.isFetching {
                        Text("Fetching…").font(.system(size: 12))
                    } else if catalog.fetched.isEmpty {
                        Text("Fetch OpenRouter models").font(.system(size: 12))
                    } else if catalog.isStale {
                        Text("Refresh — list may be out of date")
                            .font(.system(size: 12, weight: .semibold))
                    } else {
                        Text("Refresh (\(catalog.fetched.count))").font(.system(size: 12))
                    }
                }
                .buttonStyle(.secondaryCompact)
                .disabled(catalog.isFetching)
                .help(catalog.fetched.isEmpty
                      ? "Downloads the full OpenRouter catalogue"
                      : "Last updated \(catalog.ageDescription). OpenRouter's free tier changes often, so this refreshes itself every day.")

                if !catalog.fetched.isEmpty {
                    Text(catalog.isStale
                         ? "Updated \(catalog.ageDescription) — refreshing soon"
                         : "Updated \(catalog.ageDescription)")
                        .font(.system(size: 10))
                        .foregroundColor(catalog.isStale ? .orange : .secondary)
                }

                if catalog.freeCount > 0 {
                    Text("\(catalog.freeCount) free")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }

                Spacer()
            }

            // A model the user had selected was rotated out by OpenRouter.
            if !catalog.retired.isEmpty { retiredNotice(catalog) }

            // Hand-added model. Accepts a bare OpenRouter slug; the
            // "openrouter/" prefix is added for you.
            HStack(spacing: 6) {
                TextField("Add model id, e.g. qwen/qwen3-235b:free",
                          text: $customModelDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit(addCustomModel)
                Button("Add", action: addCustomModel)
                    .buttonStyle(.secondaryCompact)
                    .disabled(customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

        }
    }

    private func addCustomModel() {
        let draft = customModelDraft
        if OpenRouterCatalog.shared.addCustom(slug: draft) {
            customModelDraft = ""
        }
    }


    /// Settings rows toggle whether a model is reachable from the picker.
    /// In the picker itself a row *selects* the model instead — same list,
    /// different action.
    private func visibilityToggleRow(model: OpenRouterModel, visibility: ModelVisibility,
                                     allIDs: [String]) -> some View {
        let id = model.id
        let on = visibility.isVisible(id)
        // The picker has to render at least one option, so we can't let the
        // user hide the last visible model. Disable the row instead of
        // letting the click silently no-op.
        let isLast = visibility.isOnlyVisible(id, allModelIDs: allIDs)
        return Button {
            visibility.toggle(id, allModelIDs: allIDs)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundColor(on ? Design.Accent.brand : .secondary.opacity(0.5))
                Text(model.name)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                ModelTierBadge(tier: model.tier)
                if model.supportsImages {
                    Image(systemName: "camera")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                Spacer()
                Text(id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .opacity(isLast ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isLast)
        .help(isLast ? "At least one model must remain visible"
              : model.supportsImages ? model.id : model.id + " — text only, no screenshots")
    }

    private func modelToggleRow(id: String, name: String,
                                visibility: ModelVisibility,
                                allIDs: [String]) -> some View {
        let on = visibility.isVisible(id)
        // The picker has to render at least one option, so we can't let the
        // user hide the last visible model. Disable the row instead of
        // letting the click silently no-op.
        let isLast = visibility.isOnlyVisible(id, allModelIDs: allIDs)
        return Button {
            visibility.toggle(id, allModelIDs: allIDs)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundColor(on ? Design.Accent.brand : .secondary.opacity(0.5))
                Text(name)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                Spacer()
                Text(id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .opacity(isLast ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isLast)
        .help(isLast ? "At least one model must remain visible" : "")
    }

    @ViewBuilder
    private var memoryTab: some View {
        let store = vm.sessionStore
        section(title: "Within session") {
            Toggle(isOn: Binding(get: { store.memorySyncEnabled },
                                 set: { store.memorySyncEnabled = $0 })) {
                labelTwoLine(title: "Replay previous turns",
                             subtitle: "Include prior user/assistant turns as context.")
            }
            .toggleStyle(.switch)

            if store.memorySyncEnabled {
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(get: { store.memoryIncludeAll },
                                         set: { store.memoryIncludeAll = $0 })) {
                        Text("All turns").font(.system(size: 12))
                    }
                    .toggleStyle(.switch)

                    if !store.memoryIncludeAll {
                        Stepper(value: Binding(get: { store.memoryWindow },
                                               set: { store.memoryWindow = $0 }),
                                in: 1...100) {
                            Text("\(store.memoryWindow) turn\(store.memoryWindow == 1 ? "" : "s")")
                                .font(.system(size: 12).monospacedDigit())
                        }
                    }
                }
                .padding(.leading, 8)
            }
        }

        section(title: "Across sessions") {
            Toggle(isOn: Binding(get: { store.crossSessionMemoryEnabled },
                                 set: { store.crossSessionMemoryEnabled = $0 })) {
                labelTwoLine(title: "Pull from past sessions",
                             subtitle: "Include one recent turn from recent other sessions.")
            }
            .toggleStyle(.switch)
            .disabled(!store.memorySyncEnabled)

            if store.memorySyncEnabled && store.crossSessionMemoryEnabled {
                Stepper(value: Binding(get: { store.crossSessionWindow },
                                       set: { store.crossSessionWindow = $0 }),
                        in: 1...20) {
                    Text("Pull from \(store.crossSessionWindow) session\(store.crossSessionWindow == 1 ? "" : "s")")
                        .font(.system(size: 12).monospacedDigit())
                }
                .padding(.leading, 8)
            }
        }
    }

    @ViewBuilder
    private var workspacesTab: some View {
        @Bindable var vm = vm
        let store = vm.workspaceStore
        section(title: "Active workspace",
                subtitle: "Each workspace has its own sidebar of features.") {
            HStack {
                Spacer()
                Button {
                    showNewWorkspaceSheet = true
                } label: {
                    Label("New workspace", systemImage: "plus")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.bottom, 4)

            VStack(spacing: 6) {
                ForEach(store.workspaces) { w in
                    WorkspaceRow(
                        workspace: w,
                        isActive: w.id == store.activeWorkspaceID,
                        onSelect: { vm.switchWorkspace(to: w.id) },
                        onRename: { newName in
                            var updated = w
                            updated.name = newName
                            store.update(updated)
                        },
                        onToggleFeature: { feature in
                            var updated = w
                            if updated.enabledFeatures.contains(feature) {
                                updated.enabledFeatures.remove(feature)
                            } else {
                                updated.enabledFeatures.insert(feature)
                            }
                            store.update(updated)
                        },
                        onDelete: w.isDefault ? nil : { vm.deleteWorkspace(id: w.id) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var peerTab: some View {
        @Bindable var vm = vm
        section(title: "Peer control",
                subtitle: "Let a colleague view your overlay and send messages to the AI.") {
            Toggle(isOn: $vm.peerControlEnabled) {
                Text("Allow peer access").font(.system(size: 12))
            }
            .toggleStyle(.switch)

            if vm.peerServer.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(vm.peerServer.connectedPeers > 0 ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(vm.peerServer.connectedPeers > 0
                             ? "\(vm.peerServer.connectedPeers) peer\(vm.peerServer.connectedPeers == 1 ? "" : "s") connected"
                             : "No peers connected — share the link below")
                            .font(.caption)
                    }

                    HStack(spacing: 6) {
                        Text(vm.peerServer.connectionURL)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(vm.peerServer.connectionURL, forType: .string)
                        } label: { Image(systemName: "doc.on.doc").font(.caption) }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    Text("Access code: \(vm.peerServer.accessCode)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var shortcutsTab: some View {
        section(title: "Global shortcuts") {
            VStack(spacing: 2) {
                shortcut("⌃⌥Space", "Show / hide overlay")
                shortcut("⌘⏎",       "Get the answer now (during an interview)")
                shortcut("⌘⇧⏎",      "Screenshot → send to AI (during an interview)")
                if FeatureFlags.clipboardShortcutsEnabled {
                    shortcut("⌃⌥A",  "Send selected text to AI")
                    shortcut("⌃⌥C",  "Explain clipboard")
                }
                if FeatureFlags.resumesEnabled {
                    shortcut("⌃⌥R",  "Tailor resume from clipboard JD")
                }
                if FeatureFlags.quickAskEnabled {
                    shortcut("Hold Fn", "Quick Ask by voice")
                }
                if FeatureFlags.dictationEnabled {
                    shortcut("Hold ⌥", "Dictate into the active app")
                }
                shortcut("⌘⇧ ↑↓←→",  "Move overlay (while it's showing)")
                shortcut("⌃⇧ ↑↓←→",  "Resize overlay")
                shortcut("⌘N",        "New session")
            }
        }
    }

    // MARK: - Builders

    @ViewBuilder
    private func section<Content: View>(title: String,
                                        icon: String? = nil,
                                        subtitle: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        }
        .padding(.bottom, 14)
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>,
                           range: ClosedRange<Double>,
                           display: ((Double) -> String)? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            Slider(value: value, in: range, step: 0.05)
            Text(display?(value.wrappedValue) ?? "\(Int(value.wrappedValue * 100))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    /// How keywords in answers stand out. The ⋯ menu has the same setting.
    ///
    /// A sample answer used to sit under this picker to show the colour
    /// against real text. Removed: it restated the options in one fixed
    /// sentence, took a third of the Appearance section, and pushed the
    /// sections below it past the bottom of the panel.
    private var keywordStyleRow: some View {
        HStack(spacing: 8) {
            Text("Keywords")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            Picker("", selection: $keywordStyle) {
                ForEach(KeywordStyle.allCases.filter { !$0.isHighlight }) { Text($0.displayName).tag($0) }
                Divider()
                ForEach(KeywordStyle.allCases.filter(\.isHighlight)) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 160)
            Spacer()
        }
    }

    private func labelTwoLine(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 12))
            Text(subtitle).font(.system(size: 10)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Per-kind resume-prompt picker row. Shows a menu of saved presets (for
    /// that kind), an inline override editor, and a "Save as preset" button
    /// so users can turn a tweaked override into a named library item.
    @ViewBuilder
    private func resumePromptPicker(
        kind: PromptPreset.Kind,
        label: String,
        overrideBinding: Binding<String>,
        activeIDBinding: Binding<UUID?>,
        defaultText: String
    ) -> some View {
        let store = vm.promptStore
        let kindPresets = kind == .resumeGeneration
            ? store.resumeGenerationPresets
            : store.resumeScoringPresets
        let activePreset = kind == .resumeGeneration
            ? store.activeResumeGenerationPreset
            : store.activeResumeScoringPreset

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if !overrideBinding.wrappedValue.isEmpty {
                    Button("Reset override") { overrideBinding.wrappedValue = "" }
                        .font(.caption2).foregroundColor(.orange)
                        .buttonStyle(.plain)
                }
            }

            Menu {
                Button {
                    activeIDBinding.wrappedValue = nil
                } label: {
                    HStack {
                        Text("Default")
                        if activeIDBinding.wrappedValue == nil { Image(systemName: "checkmark") }
                    }
                }
                if !kindPresets.isEmpty {
                    Divider()
                    ForEach(kindPresets) { p in
                        Button {
                            activeIDBinding.wrappedValue = p.id
                        } label: {
                            HStack {
                                Text(p.name)
                                if activeIDBinding.wrappedValue == p.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                Divider()
                Button {
                    let trimmed = overrideBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    let content = trimmed.isEmpty ? defaultText : trimmed
                    let preset = store.add(
                        name: kind == .resumeGeneration ? "New gen prompt" : "New score prompt",
                        content: content,
                        kind: kind,
                        icon: "doc.text"
                    )
                    activeIDBinding.wrappedValue = preset.id
                    overrideBinding.wrappedValue = ""
                } label: {
                    Label("Save override as preset", systemImage: "square.and.arrow.down")
                }
                .disabled(overrideBinding.wrappedValue.isEmpty)
                Button {
                    // Switch to this window's own Prompts tab. This used to
                    // set `vm.primarySurface = .prompts`, which from a
                    // standalone window silently flipped the overlay panel
                    // behind it to a screen the user could not see — the
                    // panel changed for no visible reason.
                    tab = .prompts
                } label: {
                    Label("Manage prompts library", systemImage: "text.bubble")
                }
            } label: {
                HStack {
                    Text(activePreset?.name ?? (overrideBinding.wrappedValue.isEmpty ? "Default" : "Custom override"))
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)

            // Inline override editor — applies when no preset is selected.
            TextEditor(text: overrideBinding)
                .font(.system(size: 11))
                .frame(height: 52)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .disabled(activePreset != nil)
                .opacity(activePreset == nil ? 1.0 : 0.45)

            Group {
                if let preset = activePreset {
                    Text("Using preset “\(preset.name)”")
                        .font(.caption2).foregroundColor(Design.Accent.brand)
                } else {
                    Text(overrideBinding.wrappedValue.isEmpty
                         ? "Default: \(defaultText)"
                         : "Using inline override.")
                        .font(.caption2).foregroundColor(.secondary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func shortcut(_ keys: String, _ desc: String) -> some View {
        HStack {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Spacer()
            Text(desc)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Workspace row (used in Workspaces tab)

private struct WorkspaceRow: View {
    let workspace: Workspace
    let isActive: Bool
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onToggleFeature: (String) -> Void
    let onDelete: (() -> Void)?

    @State private var isEditing = false
    @State private var draftName = ""

    private let allFeatures: [(key: String, label: String, icon: String)] = [
        ("sessions", "History",  "clock.arrow.circlepath"),
        ("prompts",  "Prompts",  "text.bubble"),
        ("resumes",  "Resumes",  "doc.text"),
        ("calendar", "Calendar", "calendar"),
        ("browser",  "Browser",  "globe"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(nsColor: NSColor(hex: workspace.colorHex) ?? .systemPurple))
                    .frame(width: 10, height: 10)

                if isEditing {
                    TextField("Workspace name", text: $draftName, onCommit: commitRename)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, weight: .semibold))
                        .onExitCommand { isEditing = false }
                } else {
                    Text(workspace.name)
                        .font(.system(size: 12, weight: .semibold))
                }

                if isActive {
                    Text("ACTIVE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Design.Accent.brand)
                        .clipShape(Capsule())
                }
                if workspace.isDefault {
                    Text("DEFAULT")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                }

                Spacer()

                if !isActive {
                    Button("Switch") { onSelect() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
                Button {
                    if isEditing { commitRename() }
                    else {
                        draftName = workspace.name
                        isEditing = true
                    }
                } label: {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Feature toggles
            VStack(spacing: 2) {
                ForEach(allFeatures, id: \.key) { f in
                    let on = workspace.enabledFeatures.contains(f.key)
                    Button {
                        onToggleFeature(f.key)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: f.icon)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            Text(f.label)
                                .font(.system(size: 11))
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 13))
                                .foregroundColor(on ? Design.Accent.brand : .secondary.opacity(0.5))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Design.Accent.brand.opacity(0.06) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Design.Accent.brand.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != workspace.name {
            onRename(trimmed)
        }
        isEditing = false
    }
}
