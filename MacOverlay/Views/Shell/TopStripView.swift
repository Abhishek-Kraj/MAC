import SwiftUI
import AppKit

/// Slim header strip inside the unified expanded panel. Always shows the
/// editable session title on the left, a session overflow menu, and a
/// chevron on the right that closes the body back to the bar-only layout.
struct TopStripView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var editingTitle = false
    @State private var draftTitle = ""

    var body: some View {
        HStack(spacing: 8) {
            closeButton
            titleField
            Spacer()
            browserPopOutButton
            minimizeButton
            composeButton
            sessionMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // The header doubles as the panel's title bar: it drags the whole
        // overlay, title included, and a double-click renames. Behind the
        // row, so the ✕ and the right-hand buttons keep their own clicks.
        .background(PanelDragArea(onDoubleClick: beginRename))
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
            // Not a button: a click-to-rename title covered most of the
            // header, so a press on it renamed instead of dragging, and with
            // a long session title there was almost nothing left to grab.
            Text(headerTitle)
                .font(.system(size: 14, weight: .semibold))
                .tracking(-0.2)
                .foregroundColor(Design.Ink.primary)
                .lineLimit(1)
                .allowsHitTesting(false)
        }
    }

    private func beginRename() {
        draftTitle = vm.sessionStore.activeSession.displayTitle
        editingTitle = true
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
        case .settings?:  return "Settings"
        case .none:       return vm.sessionStore.activeSession.displayTitle
        }
    }

    /// What ✕ will do here, said plainly: it only ever closes this screen.
    private var closeHelp: String {
        switch vm.primarySurface {
        case .summary?:  return "Back to the conversation"
        case .settings?: return "Close Settings"
        default:
            return vm.isInterviewSession
                ? "Minimize — the session keeps going (Esc)"
                : "Close this screen"
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
        .help(closeHelp)

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

    /// Down to the pill, like Esc; a live session keeps running and
    /// reopening comes back to it. ✕ already did this while live, but read
    /// as "close", so it was not something anyone reached for.
    private var minimizeButton: some View {
        Button {
            // The panel's own resize curve, like ✕ and the pill: a spring
            // overshoots the AppKit resize and the bar visibly bounces.
            withAnimation(Design.Motion.expand) { vm.collapseShell() }
        } label: {
            Image(systemName: "minus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Design.Ink.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Design.Surface.controlFill))
                .overlay(Circle().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Minimize (Esc)")
        .accessibilityLabel(Text("Minimize"))
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
        // A live session has to be ended first, from the bar: one slip on
        // this button used to end the interview.
        .disabled(vm.isInterviewSession)
        .help(vm.isInterviewSession ? "End the session first"
              : (vm.primarySurface == .interview ? "New interview setup" : "New chat (⌘N)"))
    }

    /// The session menu: things you do to this session, then the window.
    /// Pause, End and the gear sit on the bar; what is set once (audio,
    /// engine, answers, appearance) lives in Settings, and what is changed
    /// mid-session is in the live gear's popover. The menu ran to 24 items
    /// while it held all of them.
    private var sessionMenu: some View {
        Menu {
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
            // A live session has to be ended first, from the bar.
            .disabled(vm.isInterviewSession)

            Button {
                withAnimation(Design.Motion.spring) {
                    vm.primarySurface = .sessions
                }
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }

            Button(action: beginRename) {
                Label("Rename…", systemImage: "pencil")
            }

            Menu {
                Button("Copy as Markdown") { vm.copyActiveSessionAsMarkdown() }
                Button("Save as Markdown…") { vm.exportActiveSessionToDisk() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }

            // The way back after the strip's eye button hides it.
            if vm.isInterviewSession && !vm.isInterviewTextOnly && !vm.showLiveTranscript {
                Button {
                    vm.showLiveTranscript = true
                } label: {
                    Label("Show live transcript", systemImage: "eye")
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
            Menu {
                // The way back from a size the user does not want. A manual
                // resize is sticky on purpose, so this has to be reachable
                // without hunting — a squashed panel with the bar cut in half
                // is otherwise only fixable by restarting the app.
                Button {
                    vm.onResetPanelSize?()
                } label: {
                    Label("Reset panel size", systemImage: "arrow.up.left.and.arrow.down.right")
                }

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

                Button {
                    (NSApp.delegate as? AppDelegate)?.saveSnapshotsAndReveal()
                } label: {
                    Label("Save a picture of this window", systemImage: "camera")
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
            } label: {
                Label("Window", systemImage: "macwindow")
            }

            Button {
                (NSApp.delegate as? AppDelegate)?.showPreferences()
            } label: {
                Label("Settings…", systemImage: "gearshape")
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
