import SwiftUI
import AppKit

/// Slim header strip inside the unified expanded panel. Always shows the
/// editable session title on the left, a session overflow menu, and a
/// chevron on the right that closes the body back to the bar-only layout.
struct TopStripView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var editingTitle = false
    @State private var draftTitle = ""
    @AppStorage(KeywordStyle.defaultsKey) private var keywordStyle = KeywordStyle.standard

    var body: some View {
        HStack(spacing: 8) {
            closeButton
            titleField
            Spacer()
            browserPopOutButton
            composeButton
            sessionMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // The header doubles as the panel's title bar: empty space in it
        // drags the whole overlay. Behind the row, so the ✕, the title, and
        // the right-hand buttons keep taking their own clicks.
        .background(PanelDragArea())
    }

    @ViewBuilder
    private var titleField: some View {
        if editingTitle {
            TextField("Session title", text: $draftTitle, onCommit: commitTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Design.Ink.primary)
                .frame(maxWidth: 320)
                .onExitCommand(perform: cancelEdit)
        } else {
            Button {
                draftTitle = vm.sessionStore.activeSession.displayTitle
                editingTitle = true
            } label: {
                Text(headerTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundColor(Design.Ink.primary)
                    .lineLimit(1)
                    .help("Click to rename")
            }
            .buttonStyle(.plain)
        }
    }

    /// Header label — names the active surface so the user always knows
    /// what they're looking at.
    private var headerTitle: String {
        switch vm.primarySurface {
        case .chat?:      return vm.sessionStore.activeSession.displayTitle
        case .interview?:
            // Show the actual session title whenever a session is being
            // hosted (live OR resumed-from-History); only fall back to
            // the mode label when the setup form is on screen.
            return vm.interviewSurfaceShowsChat
                ? vm.sessionStore.activeSession.displayTitle
                : vm.interviewSurfaceMode.displayName
        case .sessions?:  return "History"
        case .summary?:   return vm.minutesTitle
        case .resumes?:   return "Resumes"
        case .prompts?:   return "Prompts"
        case .calendar?:  return "Calendar"
        case .browser?:   return "Browser"
        case .none:       return vm.sessionStore.activeSession.displayTitle
        }
    }

    /// The reference UI's top-left ✕: closes the surface (`closeSurface` —
    /// the summary returns to its conversation, a live session minimizes,
    /// anything else goes to the home bar). Esc always collapses the whole
    /// shell, so it has its own hidden button, except while the title is
    /// being edited (Esc cancels the edit then).
    @ViewBuilder
    private var closeButton: some View {
        let button = Button {
            // Match the panel's easeOut resize curve — see surfaceButton
            // in InputBarView for the rationale (spring overshoot vs the
            // AppKit resize was visibly bouncing the bar).
            withAnimation(Design.Motion.expand) {
                vm.closeSurface()
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Design.Ink.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Design.Surface.controlFill))
                .overlay(Circle().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(vm.primarySurface == .summary ? "Back to conversation"
              : vm.isInterviewSession ? "Minimize (Esc)" : "Close")

        if editingTitle {
            button
        } else {
            button.background {
                Button {
                    withAnimation(Design.Motion.expand) {
                        vm.collapseShell()
                    }
                } label: { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
    }

    /// Compose / new-chat button — the reference UI's top-right pencil.
    /// Context-aware: on the Interview surface it returns to the setup
    /// form; everywhere else it mints a fresh chat session.
    /// Pops the browser out into its own window, so the shell is free to
    /// show the interview panel while a page stays open next to it.
    ///
    /// It lives in the header — not only in the browser's tab bar — because
    /// the tab bar doesn't exist until a tab does: with no tabs open the
    /// surface is the quick-start empty state, and the only pop-out control
    /// would have been on a strip that isn't on screen yet.
    @ViewBuilder
    private var browserPopOutButton: some View {
        if vm.primarySurface == .browser && !vm.browserDetached {
            Button {
                vm.detachBrowser()
            } label: {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Design.Ink.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Design.Surface.controlFill))
                    .overlay(Circle().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("Open the browser in its own window")
        }
    }

    private var composeButton: some View {
        Button {
            withAnimation(Design.Motion.spring) {
                vm.requestNewSession()
            }
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Design.Ink.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Design.Surface.controlFill))
                .overlay(Circle().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .command)
        // Off the Interview surface a new chat can't start under a live session.
        .disabled(vm.isInterviewSession && vm.primarySurface != .interview)
        .help(vm.primarySurface == .interview ? "New interview setup" : "New chat (⌘N)")
    }

    private func keywordStyleButton(_ style: KeywordStyle) -> some View {
        Button {
            keywordStyle = style
        } label: {
            HStack {
                Text(style.displayName)
                if keywordStyle == style { Image(systemName: "checkmark") }
            }
        }
    }

    /// "Pause call" on the call tab, "Pause interview" on the interview tab.
    private var pauseVerb: String { vm.isRegularCallSession ? "Pause call" : "Pause interview" }
    private var resumeVerb: String { vm.isRegularCallSession ? "Resume call" : "Resume interview" }

    private var sessionMenu: some View {
        Menu {
            // Live-session controls first — pause/resume and End moved
            // here from the input bar so the bar stays minimal during
            // an interview.
            if vm.isInterviewSession {
                if !vm.isInterviewTextOnly {
                    Button {
                        if vm.isInterviewPaused {
                            vm.resumeInterviewSession()
                        } else {
                            vm.pauseInterviewSession()
                        }
                    } label: {
                        Label(vm.isInterviewPaused ? resumeVerb : pauseVerb,
                              systemImage: vm.isInterviewPaused ? "play.fill" : "pause.fill")
                    }
                }
                Button(role: .destructive) {
                    vm.stopInterviewSession()
                } label: {
                    // "End call" on the call tab, "End interview" on the
                    // interview tab. The user should never have to translate
                    // the app's terminology back into what they were doing.
                    Label(vm.isRegularCallSession ? "End call" : "End interview",
                          systemImage: "stop.circle")
                }
                .help(vm.isRegularCallSession
                      ? "Stop recording and write the call summary"
                      : "Stop the session and write the summary")
                Divider()
            }

            // Same switch as on the setup screen; it applies straight
            // away, mid-interview included.
            Menu {
                ForEach([true, false], id: \.self) { on in
                    Button {
                        vm.interviewAutoGenerate = on
                    } label: {
                        HStack {
                            Text(on ? "On" : "Off")
                            if vm.interviewAutoGenerate == on { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Label("Auto-generate responses: \(vm.interviewAutoGenerate ? "On" : "Off")",
                      systemImage: "wand.and.sparkles")
            }

            // Model picker. A popover rather than a Menu because it shares
            // the filter bar, tier badges and search with Settings -> AI; a
            // Menu cannot host a search field, which is why the two screens
            // used to disagree about which models existed.
            ModelPickerButton(currentModelName: currentModelName)


            Divider()

            Button {
                // Context-aware new session: on the Interview surface,
                // flip back to the setup form rather than minting a new
                // chat session right away. Elsewhere, behaves like before.
                withAnimation(Design.Motion.spring) {
                    vm.requestNewSession()
                }
            } label: {
                // No `.keyboardShortcut` here. `composeButton` in this same
                // strip already binds ⌘N, and two registrations for one key
                // equivalent make which one fires implementation-defined.
                // The label carries the hint instead.
                Label(vm.primarySurface == .interview
                      ? "New interview setup (⌘N)"
                      : "New Session (⌘N)",
                      systemImage: "square.and.pencil")
            }

            Button {
                withAnimation(Design.Motion.spring) {
                    vm.primarySurface = .sessions
                }
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }

            Button {
                draftTitle = vm.sessionStore.activeSession.displayTitle
                editingTitle = true
            } label: {
                Label("Rename…", systemImage: "pencil")
            }

            // The way back from a size the user does not want. A manual
            // resize is sticky on purpose, so this has to be reachable
            // without hunting — a squashed panel with the bar cut in half
            // is otherwise only fixable by restarting the app.
            Button {
                vm.onResetPanelSize?()
            } label: {
                Label("Reset panel size", systemImage: "arrow.up.left.and.arrow.down.right")
            }

            Divider()

            Menu {
                Button("Copy as Markdown") { vm.copyActiveSessionAsMarkdown() }
                Button("Save as Markdown…") { vm.exportActiveSessionToDisk() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }

            Menu {
                ForEach(AudioSource.allCases, id: \.self) { src in
                    Button { vm.audioSource = src } label: {
                        HStack {
                            Text(src.label)
                            if vm.audioSource == src { Image(systemName: "checkmark") }
                        }
                    }
                }
                Divider()
                Text("You + Them hears the call and you separately: answers fire on the call only.")
            } label: {
                Label("Audio source: \(vm.audioSource.label)", systemImage: "waveform")
            }

            // Quick transparency presets — reachable mid-interview so the
            // overlay can fade over the call window without a trip to
            // Preferences (which also has the fine-grained sliders).
            Menu {
                ForEach([1.0, 0.85, 0.7, 0.55, 0.4], id: \.self) { level in
                    Button {
                        vm.opacity = level
                    } label: {
                        HStack {
                            Text("\(Int(level * 100))%")
                            if abs(vm.opacity - level) < 0.01 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Transparency: \(Int(vm.opacity * 100))%",
                      systemImage: "circle.lefthalf.filled")
            }

            Menu {
                ForEach([1.0, 0.8, 0.6, 0.4, 0.2], id: \.self) { level in
                    Button {
                        vm.backgroundOpacity = level
                    } label: {
                        HStack {
                            Text("\(Int(level * 100))%")
                            if abs(vm.backgroundOpacity - level) < 0.01 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Background: \(Int(vm.backgroundOpacity * 100))%",
                      systemImage: "rectangle.on.rectangle")
            }

            // Answer text size — the same setting as the slider in
            // Settings → General.
            Menu {
                ForEach([0.9, 1.0, 1.15, 1.3, 1.5], id: \.self) { level in
                    Button {
                        vm.textScale = level
                    } label: {
                        HStack {
                            Text("\(Int((level * 100).rounded()))%")
                            if abs(vm.textScale - level) < 0.01 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Text size: \(Int((vm.textScale * 100).rounded()))%",
                      systemImage: "textformat.size")
            }

            // How keywords in answers stand out — the same setting as
            // Settings → General → Keywords. Coloured text first, then the
            // highlighter styles.
            Menu {
                ForEach(KeywordStyle.allCases.filter { !$0.isHighlight }) { keywordStyleButton($0) }
                Divider()
                ForEach(KeywordStyle.allCases.filter(\.isHighlight)) { keywordStyleButton($0) }
            } label: {
                Label("Keywords: \(keywordStyle.displayName)", systemImage: "highlighter")
            }

            // Which speech engine is doing the transcribing — switchable
            // here so the strip doesn't need a badge for it.
            Menu {
                ForEach(OverlayViewModel.TranscriptionPreference.allCases) { pref in
                    Button {
                        vm.transcriptionPreference = pref
                    } label: {
                        HStack {
                            Text(pref.displayName)
                            if vm.transcriptionPreference == pref {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Transcription: \(vm.transcriptionBackend.rawValue)",
                      systemImage: "waveform.badge.mic")
            }

            if vm.isInterviewSession && !vm.isInterviewTextOnly {
                Divider()

                Button {
                    vm.showLiveTranscript.toggle()
                } label: {
                    HStack {
                        Text("Show live transcript")
                        if vm.showLiveTranscript { Image(systemName: "checkmark") }
                    }
                }

                Button {
                    vm.interviewFocusMode.toggle()
                } label: {
                    HStack {
                        Text("Focus mode (current Q&A only)")
                        if vm.interviewFocusMode { Image(systemName: "checkmark") }
                    }
                }
            }

            Divider()

            Button(role: .destructive) {
                vm.sessionStore.delete(id: vm.sessionStore.activeSessionID)
            } label: {
                Label("Delete Session", systemImage: "trash")
            }
            // Deleting the session a recording is writing into.
            .disabled(vm.isInterviewSession)

            Divider()

            // App-level controls. The menu-bar icon hides during calls (the
            // menu bar is in every screen share), so these live here too.
            Button {
                (NSApp.delegate as? AppDelegate)?.resetPosition()
            } label: {
                Label("Reset overlay position", systemImage: "arrow.uturn.backward")
            }

            Button {
                (NSApp.delegate as? AppDelegate)?.closeToMenuBar()
            } label: {
                Label("Close to menu bar", systemImage: "menubar.arrow.up.rectangle")
            }

            // Troubleshooting: the overlay floats above everything and the
            // window under it is unreachable, so a layout problem cannot be
            // photographed and there is nothing to look at but this menu.
            // These two make the app inspectable and gettable-out-of.
            Button {
                (NSApp.delegate as? AppDelegate)?.toggleInspector()
            } label: {
                Label("Show / hide app window (troubleshooting)",
                      systemImage: "macwindow.on.rectangle")
            }

            Button {
                (NSApp.delegate as? AppDelegate)?.showPreferences()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }

            Button {
                (NSApp.delegate as? AppDelegate)?.saveSnapshotsAndReveal()
            } label: {
                Label("Save a picture of this window", systemImage: "camera")
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit TheCloser", systemImage: "power")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Design.Ink.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Design.Surface.controlFill))
                .overlay(Circle().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var currentModelName: String {
        OverlayViewModel.availableModels.first { $0.id == vm.selectedModel }?.name ?? "Model"
    }

    private func commitTitle() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            vm.sessionStore.rename(id: vm.sessionStore.activeSessionID, to: trimmed)
        }
        editingTitle = false
    }

    private func cancelEdit() {
        editingTitle = false
        draftTitle = ""
    }
}
