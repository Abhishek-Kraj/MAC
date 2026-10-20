import SwiftUI
import AppKit

/// ChatGPT-desktop-style composer. Layout:
///   ┌──────────────────────────────────────────────────┐
///   │ [multi-line text area]                           │
///   │                                                  │
///   │ [+]  [mode ▼]              [model ▼]  [🎤]  [↑]  │
///   └──────────────────────────────────────────────────┘
/// Plus button captures a screenshot, mode menu picks the session mode /
/// custom prompt, model menu picks the LLM, mic toggles recording (or
/// stops streaming), send fires the message.
struct InputBarView: View {
    /// True when the bar is a ROW of the live-focus card instead of its
    /// own floating capsule: no fill, stroke, clip or shadow — the card
    /// around it is the surface — and full-width internal padding so the
    /// row lines up with the header and the answer above it.
    var inline: Bool = false

    /// The synthesized memberwise init is inaccessible outside this file —
    /// the state properties below are private — so spell out the one knob
    /// the shell needs.
    init(inline: Bool = false) {
        self.inline = inline
    }

    @Environment(OverlayViewModel.self) private var vm
    @FocusState private var inputFocused: Bool

    /// The bar's own text size, set in Settings → General → Appearance.
    @AppStorage("bar.fontSize") private var barFontSize = 13.0

    /// Tracks whether the user has actively engaged with the expanded
    /// shell (clicked a button, focused the text field, opened a
    /// surface). When `false` and the mouse leaves the bar, the shell
    /// auto-collapses back to `.pill` — "hover to preview, click to
    /// commit". When `true`, the shell stays open until the user
    /// explicitly collapses it.
    @State private var engaged = false
    /// Pending auto-collapse task. Cancelled if the mouse re-enters or
    /// the user engages before it fires.
    @State private var autoCollapseTask: Task<Void, Never>?
    /// Pending focus-grab task. Stored so a rapid stage flip cancels the
    /// previous focus attempt — otherwise repeated expand/collapse cycles
    /// queue up multiple delayed focus grabs that fire after the user has
    /// moved on.
    @State private var focusTask: Task<Void, Never>?
    /// Logo hover state — drives the subtle scale/brightness lift so the
    /// brand button visibly responds the instant the cursor lands on it,
    /// even before the dwell-debounced expansion fires.
    @State private var brandHovered = false
    /// Set while a drag on the brand pill is moving the panel, so the
    /// button's own click action can stand down. Cleared when it reads it.
    @State private var brandDidDrag = false
    /// Pending hover-to-expand task. A short dwell (`brandHoverDwell`)
    /// debounces the expansion so a quick mouse-cross doesn't pop the
    /// bar open. Cancelled if the cursor leaves before it elapses.
    @State private var brandHoverTask: Task<Void, Never>?

    /// Mouse must rest on the brand logo this long before the bar
    /// expands. Short enough to feel instant on intent, long enough that
    /// sweeping past on the way to something else doesn't fire it.
    private let brandHoverDwell: Duration = .milliseconds(140)

    var body: some View {
        @Bindable var vm = vm
        // Single-row layout: brand logo always present on the left; in
        // `.pill` we render only the logo. In any other stage the rest of
        // the bar (buttons + text field + send) appears INLINE next to it
        // so the brand logo never leaves its position — the capsule just
        // grows wider to accommodate.
        VStack(alignment: .leading, spacing: 6) {
            // Attachments float in their own tray ABOVE the bar capsule.
            // Stacking them inside the capsule stretched it into a tall
            // pill with bulging rounded ends — this keeps the bar a bar.
            if (vm.pendingScreenshot != nil || !vm.pendingAttachments.isEmpty)
                && vm.shellStage != .pill {
                attachmentTray
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            Group {
                if inline {
                    // Row of the live-focus card: the card owns the
                    // surface, so no fill / stroke / clip / shadow — just
                    // the controls on the card's own glass, full-width
                    // padding so the row aligns with the header above.
                    barRow
                        .frame(maxWidth: .infinity)
                        .background(PanelDragArea())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    barRow
                        // The bar spans the panel, not its own buttons. Without
                        // this the capsule sized to its content — 225pt inside a
                        // 440pt panel — so expanding left a stub hanging off the
                        // bottom-left corner with empty space beside it, which is
                        // what "the expansion is not aligned" was.
                        //
                        // Collapsed is the exception: there the row must hug the
                        // brand button so the capsule is a small dot, not a
                        // full-width bar with the logo at one end.
                        .frame(maxWidth: vm.shellStage == .pill ? nil : CGFloat.infinity)
                        // Drag handle behind the row — this is the only chrome on
                        // screen in `.pill`, so without it the collapsed overlay
                        // can't be moved by mouse at all. In front of the capsule
                        // fill (which would otherwise swallow the drag) and behind
                        // the controls, which keep their own clicks.
                        .background(PanelDragArea())
                        // Constant horizontal padding across stages — animating
                        // padding 4 → 8 during expansion shifts the brand pill 4pt
                        // right mid-flight, which reads as the icon "twitching" as
                        // the bar grows. Lock it.
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        .background(barShape.fill(Design.Surface.shellFill).opacity(vm.backgroundOpacity))
                        .overlay(barShape.stroke(Design.Surface.hairline, lineWidth: 0.75))
                        // Clip transitioning content (inner HStack sliding in from
                        // the leading edge) to the capsule outline so the controls
                        // visibly emerge from inside the bar.
                        .clipShape(barShape)
                        .designShadow(Design.Shadow.raised)
                }
            }
        }
        .animation(Design.Motion.fast, value: vm.pendingAttachments.count)
        .animation(Design.Motion.fast, value: vm.pendingScreenshot != nil)
        .animation(Design.Motion.expand, value: vm.shellStage)
        // Hover-preview tracking: when the bar expanded purely from a
        // hover (no click yet), watch for the mouse leaving the panel.
        // If it leaves and the user hasn't actually clicked anything,
        // schedule a collapse back to `.pill` after a short dwell.
        // Re-entering cancels. Applies to every non-pill stage so that
        // a hover-induced expansion never gets stranded open just
        // because some unrelated state transition flipped the stage.
        //
        // The signal is the WHOLE-PANEL hover, not this view's own
        // region. Watching just the bar meant moving the cursor up to
        // read the answer counted as "left", so the shell collapsed
        // mid-interview — and since collapsing lands the pill under the
        // cursor, hovering it re-opened the panel, which collapsed again
        // one dwell later: the close/open flap. The panel is one surface;
        // the pointer is either on it or it isn't.
        //
        // A live interview or call never auto-collapses at all — the
        // user committed when they started it, and assistance vanishing
        // mid-question is always wrong.
        .onChange(of: vm.isPointerInPanel) { _, inside in
            if inside {
                autoCollapseTask?.cancel()
                autoCollapseTask = nil
            } else if vm.shellStage != .pill && !engaged && !vm.isInterviewSession {
                scheduleAutoCollapse()
            }
        }
        // Tap anywhere inside the bar (not on a button) is enough to
        // engage. simultaneousGesture so it doesn't swallow button taps.
        .simultaneousGesture(
            TapGesture().onEnded { engaged = true }
        )
        .onChange(of: vm.manualInput) { _, _ in
            // User typed something — clearly engaged.
            if !vm.manualInput.isEmpty { engage() }
        }
        .onChange(of: vm.shellStage) { _, newStage in
            // Cancel any in-flight focus grab — a new stage transition
            // supersedes the previous one.
            focusTask?.cancel()
            focusTask = nil
            // Auto-focus the text field once the bar expands beyond the
            // pill — but only if the user actually engaged (clicked).
            // Otherwise a pure hover would auto-focus the field and feel
            // like the bar is grabbing focus on every mouse-cross.
            if newStage != .pill && engaged {
                focusTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    inputFocused = true
                }
            }
            // Returning to .pill resets the engagement flag for next preview.
            if newStage == .pill {
                engaged = false
                autoCollapseTask?.cancel()
                autoCollapseTask = nil
            }
        }
    }

    /// Mark the user as actively engaged with the open bar. Cancels any
    /// pending auto-collapse so a "hover ended" signal that arrived just
    /// before the click doesn't fire after the user has clearly committed.
    private func engage() {
        engaged = true
        autoCollapseTask?.cancel()
        autoCollapseTask = nil
    }

    /// Schedule a collapse back to `.pill` after a short dwell. If the
    /// user re-enters, engages, or a live session is running, the task
    /// is cancelled (or never starts) and the bar stays open.
    private func scheduleAutoCollapse() {
        guard !vm.debugSuppressAutoCollapse, !vm.isInterviewSession else { return }
        autoCollapseTask?.cancel()
        autoCollapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            // The flags are re-checked here as well as on the way in: the
            // snapshot harness sets the debug one, but a hover-exit can
            // already have been scheduled by the time it does, and that one
            // collapse is enough to fight every programmatic expansion
            // afterwards. The live-session check is re-read for the same
            // reason — Start can be clicked inside the dwell.
            guard !Task.isCancelled,
                  !vm.debugSuppressAutoCollapse,
                  vm.shellStage != .pill,
                  !engaged,
                  !vm.isInterviewSession else { return }
            withAnimation(Design.Motion.spring) {
                vm.shellStage = .pill
            }
        }
    }

    /// One horizontal row: the brand, the "ask anything" field, and the
    /// surface buttons — or, during a live interview, the field and its send
    /// button. (An earlier version offered a per-button visibility set through
    /// Settings → Panel; the bar has since been consolidated to the controls
    /// that matter mid-interview and that tab gated nothing.)
    ///
    /// The text input is the flexible element — it expands to fill any
    /// extra horizontal space the user gives the panel by dragging it
    /// wider. Everything else stays at its natural width.
    @ViewBuilder
    private var barRow: some View {
        @Bindable var vm = vm
        // `alignment: .center` + a fixed minimum row height keeps the
        // brand pill at exactly the same Y across every stage. Without
        // this, the row's intrinsic height fluctuates as buttons / the
        // text field appear-disappear, and the brand visibly drifts up
        // or down during the stage animation.
        // The brand is rendered as a leading-anchored OVERLAY rather than
        // as the first HStack child. Reason: even with `.transition(.opacity)`
        // on the controls and a unified animation curve, SwiftUI re-runs the
        // HStack's layout pass during the stage transition. Anything that
        // shifts in that pass (the inserted sibling's intrinsic sizing, the
        // spacing slot growing from 0→4, the row's measured min-height
        // settling) drags the brand a pixel or two with it — that's the
        // wobble. Lifting the brand out of the flow into an overlay anchored
        // to .leading makes its position purely a function of the bar
        // capsule's leading edge, which never moves. The HStack just grows
        // wider to the right behind it.
        HStack(alignment: .center, spacing: 4) {
            // Reserve the slot the brand used to occupy so the controls
            // start at the same X they did before. Same width as the
            // brand button's frame (44pt) so nothing else in the row
            // shifts when this refactor lands.
            Color.clear
                .frame(width: 44, height: 44)

            if vm.shellStage != .pill {
                // Two layouts depending on whether an interview is running:
                //   - Idle: brand pill + the bar's icons (Interview, and the
                //     flags below). Flows start from a surface.
                //   - Active interview: text field + model picker + stop
                //     button. The surface icons disappear so the user can
                //     focus on the live conversation; they come back the
                //     moment the interview ends.
                HStack(alignment: .center, spacing: 4) {
                    divider
                    if vm.isInterviewSession {
                        // Live row: the field + send, then Pause/Resume, End
                        // and Settings. They lived only in the session ⋯
                        // menu, and with nothing on screen saying how to
                        // pause or stop, a live call read as a window that
                        // could not be closed. The model picker stays in ⋯.
                        textInputField
                        if vm.isInterviewTextOnly {
                            sendButton
                        } else {
                            // Manual send: push whatever's typed — or the
                            // accumulated live transcription — to the AI
                            // right now (also ⌘⏎), without waiting for a
                            // silence boundary. The mic keeps running.
                            liveSendButton
                        }
                        if !vm.isInterviewTextOnly {
                            pauseResumeButton
                        }
                        endSessionButton
                        settingsButton
                    } else if vm.showsConversationComposer {
                        // A conversation is open (a past one from History
                        // included): ask about it here, with the bar's
                        // buttons still to hand.
                        textInputField
                        sendButton
                        surfaceButtons
                    } else {
                        surfaceButtons
                    }
                }
                .padding(.trailing, 12)
                .clipped()
                .transition(.opacity)
            }
        }
        // Lock the row height to the brand-button height — the brand is
        // the tallest stable element in every stage. Pinning it here
        // means the row never gets shorter when only the brand is shown
        // (`.pill`) or taller when an unrelated control happens to draw
        // a few extra pixels.
        .frame(minHeight: 44)
        // Brand pinned to the leading edge, outside the HStack flow. Its
        // X is fixed regardless of what the row does mid-animation.
        .overlay(alignment: .leading) {
            brandLogoButton
        }
    }

    /// The "ask anything" field. Sits right after the brand pill so it's
    /// the first thing the user's eye lands on — primary affordance for
    /// just typing a prompt without navigating any surface.
    private var textInputField: some View {
        @Bindable var vm = vm
        return TextField("Ask anything", text: $vm.manualInput, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: CGFloat(barFontSize)))
            .foregroundColor(Design.Ink.primary)
            .lineLimit(1...3)
            .focused($inputFocused)
            .onSubmit { send() }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 140, maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Design.Surface.inputFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Design.Surface.strongHairline, lineWidth: 0.5)
            )
    }

    /// Bar background shape. Always a full Capsule — the bar reads as
    /// its own floating glass element in every stage. The narrower top
    /// card in expanded-with-surface floats slightly above it.
    private var barShape: Capsule {
        Capsule(style: .continuous)
    }

    /// Vertical hairline that visually separates the brand pill from the
    /// rest of the row when the bar is expanded.
    private var divider: some View {
        Rectangle()
            .fill(Design.Surface.separator)
            .frame(width: 0.5, height: 20)
            .padding(.horizontal, 4)
    }

    /// Brand logo lives at the leading edge in every stage, so SwiftUI
    /// keeps the same view identity across stage changes — no re-render,
    /// no jump. Click toggles between `.pill` and `.expanded`. Hovering
    /// while collapsed expands too; both reopen the last surface
    /// (`expandShell`), not a bare bar.
    private var brandLogoButton: some View {
        Button {
            // A press that turned into a drag moved the panel; it must not
            // also toggle the shell. The window follows the cursor, so the
            // pointer is still on the brand at mouse-up and this action
            // fires at the end of every drag without the guard. The gesture
            // clears the flag itself on the next runloop turn.
            if brandDidDrag { return }
            cancelBrandHoverDwell()
            withAnimation(Design.Motion.expand) {
                if vm.shellStage == .pill {
                    vm.expandShell()
                } else {
                    vm.shellStage = .pill
                }
            }
        } label: {
            WaveformLogo()
                .frame(width: 26, height: 26)
                .frame(width: 44, height: 44)
                .overlay(alignment: .bottom) { ChannelBadge() }
                // No scaleEffect on hover — center-anchored scaling makes
                // the brand visibly grow in both directions, which reads as
                // the icon "shifting right then snapping back" once the
                // hover state ends. Bar expansion + the brightness lift
                // below are enough hover feedback on their own.
                .brightness(brandHovered ? 0.04 : 0)
                .animation(.easeOut(duration: 0.14), value: brandHovered)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // In `.pill` the brand IS the overlay — 44×44 of button with no
        // background left to grab — so the pill itself has to be the drag
        // handle or the collapsed overlay can't be moved by mouse at all.
        .panelDraggable(didDrag: $brandDidDrag)
        .onHover { isHovering in
            brandHovered = isHovering
            if isHovering, vm.shellStage == .pill {
                scheduleBrandHoverExpand()
            } else {
                cancelBrandHoverDwell()
            }
        }
        .help(vm.shellStage == .pill ? "Drag to move · click to open" : "Click to collapse")
    }

    private func scheduleBrandHoverExpand() {
        cancelBrandHoverDwell()
        brandHoverTask = Task { @MainActor in
            try? await Task.sleep(for: brandHoverDwell)
            guard !Task.isCancelled, vm.shellStage == .pill else { return }
            withAnimation(Design.Motion.expand) {
                vm.expandShell()
            }
        }
    }

    private func cancelBrandHoverDwell() {
        brandHoverTask?.cancel()
        brandHoverTask = nil
    }

    // MARK: - Left utilities

    /// Parked — not rendered anywhere. `composeButton` in the top strip is
    /// what actually binds ⌘N; this one deliberately has no shortcut so
    /// reviving it cannot create a second registration for the same key.

    /// History button — sits immediately next to "+" so the two are read
    /// as a related pair. Brings up History; preserves the current panel
    /// state if a top panel is already open.

    @ViewBuilder
    private var surfaceButtons: some View {
        // Bar surface set: Interview, then Settings — which is not a surface
        // at all but the standalone Settings window. Resumes and Browser sit
        // behind flags (`resumesEnabled` is false, `browserEnabled` is true).
        // The rest (mode picker, model picker, history, mic) is parked —
        // flows start by clicking one of these icons.
        surfaceButton(.interview, icon: "desktopcomputer", label: "Interview")
        // History lived only in the header's ⋯ menu, which exists only once a
        // surface is open — users couldn't find their past calls.
        surfaceButton(.sessions, icon: "clock.arrow.circlepath", label: "History")
        if FeatureFlags.resumesEnabled {
            surfaceButton(.resumes, icon: "doc.richtext", label: "Resumes")
        }
        if FeatureFlags.browserEnabled {
            surfaceButton(.browser, icon: "globe", label: "Browser")
        }
        settingsButton

        // Quit, in the bar itself rather than only inside Settings or the
        // overlay's "…" menu. The overlay floats above every window and hides
        // itself from screen sharing, so getting out of it meant opening a
        // surface first, or hunting for the menu bar icon. Set apart by a
        // divider so it is not struck while reaching for Settings.
        divider

        Button {
            NSApp.terminate(nil)
        } label: {
            SurfaceIcon(systemName: "power",
                        tint: Design.Ink.secondary,
                        active: false,
                        attention: false)
        }
        .buttonStyle(.plain)
        .help("Quit TheCloser")
        .accessibilityLabel(Text("Quit TheCloser"))
    }

    /// Opens the Settings window.
    ///
    /// Settings are not a surface of this panel — they are their own window
    /// (see `AppDelegate.showPreferences`). So this does not set
    /// `primarySurface`: it brings a window forward and tints while that
    /// window is up, which is where the state lives.
    /// Pause and resume in one button, as in the ⋯ menu.
    private var pauseResumeButton: some View {
        let paused = vm.isInterviewPaused
        let noun = vm.isRegularCallSession ? "call" : "interview"
        return Button {
            if paused {
                vm.resumeInterviewSession()
            } else {
                vm.pauseInterviewSession()
            }
        } label: {
            SurfaceIcon(systemName: paused ? "play.fill" : "pause.fill",
                        tint: paused ? Design.Accent.amber : Design.Ink.secondary,
                        active: paused, attention: false)
        }
        .buttonStyle(.plain)
        .help(paused ? "Resume \(noun)" : "Pause \(noun)")
        .accessibilityLabel(Text(paused ? "Resume \(noun)" : "Pause \(noun)"))
    }

    /// Ends the live session: the same action as ⋯ → End call.
    private var endSessionButton: some View {
        let label = vm.isRegularCallSession ? "End call" : "End interview"
        return Button {
            vm.stopInterviewSession()
        } label: {
            SurfaceIcon(systemName: "stop.fill", tint: Design.Accent.red,
                        active: false, attention: false)
        }
        .buttonStyle(.plain)
        .help(vm.isRegularCallSession
              ? "End call: stop recording and write the summary"
              : "End interview: stop and write the summary")
        .accessibilityLabel(Text(label))
    }

    private var settingsButton: some View {
        let attention = !vm.missingRequiredKeys.isEmpty || vm.lacksCloudTranscriptionKey
        let active = vm.preferencesWindowOpen
        return Button {
            // A toggle, like the other bar buttons.
            if active {
                vm.closeSurface()
            } else {
                (NSApp.delegate as? AppDelegate)?.showPreferences()
            }
        } label: {
            SurfaceIcon(systemName: "gearshape.fill",
                        tint: attention ? Design.Accent.amber
                              : (active ? Design.Ink.primary : Design.Ink.secondary),
                        active: active,
                        attention: attention)
        }
        .buttonStyle(.plain)
        .help(attention ? "Add your API keys in Settings" : "Settings")
        .accessibilityLabel(Text("Settings"))
    }

    private func surfaceButton(_ surface: OverlayViewModel.PrimarySurface,
                               icon: String,
                               label: String,
                               attention: Bool = false) -> some View {
        let active = vm.primarySurface == surface && vm.shellStage != .pill
        let tint = attention ? Design.Accent.amber
                  : (active ? Design.Ink.primary : Design.Ink.secondary)
        return Button {
            // Use `.expand` (easeOut 0.32s) so the SwiftUI state change
            // animates with the exact same curve as the AppKit panel
            // resize fired off by `onPrimarySurfaceChange`. The previous
            // `.spring` had a subtle overshoot that didn't match the
            // panel's smooth easeOut — that desync was one source of
            // the bar visibly bouncing on surface open.
            withAnimation(Design.Motion.expand) {
                if active {
                    vm.goHome()
                } else if surface == .interview {
                    // Interview icon resumes the most-recent interview /
                    // regular-call session when one exists, rather than
                    // dumping the user onto the setup form every time.
                    vm.openInterviewSurface()
                    if vm.shellStage == .pill { vm.shellStage = .expanded }
                } else {
                    vm.primarySurface = surface
                    if vm.shellStage == .pill { vm.shellStage = .expanded }
                }
            }
        } label: {
            SurfaceIcon(systemName: icon, tint: tint, active: active, attention: attention)
        }
        .buttonStyle(.plain)
        // Surface buttons are static fixtures in the bar — their position
        // must NEVER lerp when primarySurface/shellStage changes. The
        // SurfaceIcon's internal `.animation(value: active)` handles the
        // color transition; these opt-outs make sure no inherited
        // `withAnimation(.expand)` from the click can animate the
        // button's layout/position.
        .animation(nil, value: vm.primarySurface)
        .animation(nil, value: vm.shellStage)
        .help(label)
    }






    // MARK: - Right utilities


    /// The bar's quick list. This popup widget cannot host a search field, so
    /// it stays a short list — but it is driven by the same
    /// `ModelFilterStore` as every other surface, so whatever filter is active
    /// elsewhere applies here too. "More models…" opens the full shared picker.


    /// A paused live session (Pause in the ⋯ menu). Text-only chats also
    /// count as paused, but have no microphone to resume.



    // Pause/resume, End session, and the model picker moved to the
    // session ⋯ menu (TopStripView) — the live bar stays minimal.

    private var sendButton: some View {
        let enabled = vm.canSend || !vm.manualInput.isEmpty
        return Button { send() } label: {
            ZStack {
                Circle().fill(enabled ? Design.Ink.primary : Design.Surface.controlFill)
                Circle().strokeBorder(
                    enabled ? Color.white.opacity(0.22) : Design.Surface.hairline,
                    lineWidth: 0.5
                )
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(enabled ? Design.Ink.inverse : Design.Ink.muted)
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Send (⏎ or ⌘⏎)")
    }

    /// Manual "send now" shown alongside pause during a live (voice)
    /// interview. Pushes the typed draft — or, if nothing's typed, the
    /// accumulated transcription — to the AI immediately, instead of
    /// waiting for a silence boundary / auto-generate. The mic keeps
    /// running; the transcript clears so the next utterance starts fresh.
    private var liveSendButton: some View {
        let enabled = (!vm.manualInput.isEmpty || !vm.transcription.isEmpty)
            && !vm.isSendingToAI
        return Button { vm.sendTranscriptManually() } label: {
            ZStack {
                Circle().fill(enabled ? Design.Ink.primary : Design.Surface.controlFill)
                Circle().strokeBorder(
                    enabled ? Color.white.opacity(0.22) : Design.Surface.hairline,
                    lineWidth: 0.5
                )
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(enabled ? Design.Ink.inverse : Design.Ink.muted)
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Send the live transcript now (⌘⏎) — it also sends automatically when the speaker pauses")
    }

    // MARK: - Helpers


    // MARK: - Attachment tray

    /// The tray holding everything queued for the next send — screenshot
    /// thumbnail + file chips. Renders as its own glass card so the bar
    /// capsule keeps its shape; scrolls horizontally when there are many
    /// files. `inline` drops the card (the live-focus card is the
    /// surface) and lines the chips up with the rest of the card's rows.
    /// The extracted text is already in `vm.pendingAttachments[i]
    /// .extractedText` and merges into the AI prompt at send time.
    @ViewBuilder
    private var attachmentTray: some View {
        if inline {
            trayScroll
                .padding(.horizontal, 4)
        } else {
            trayScroll
                .glassCard(cornerRadius: 14, opacity: vm.backgroundOpacity)
        }
    }

    private var trayScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let img = vm.pendingScreenshot {
                    trayChip(remove: { vm.pendingScreenshot = nil }) {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 34, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
                        Text("Screenshot")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Design.Ink.primary)
                    }
                }
                ForEach(vm.pendingAttachments) { att in
                    trayChip(remove: {
                        vm.pendingAttachments.removeAll { $0.id == att.id }
                    }) {
                        Image(systemName: iconFor(att.name))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Design.Accent.blue)
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Design.Accent.blue.opacity(0.14)))
                        Text(att.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Design.Ink.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 150, alignment: .leading)
                    }
                }
            }
            .padding(8)
        }
    }

    /// One chip in the tray: leading content + remove ✕.
    private func trayChip<Content: View>(remove: @escaping () -> Void,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            content()
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Design.Surface.controlFill))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
    }

    private func iconFor(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":          return "doc.richtext.fill"
        case "docx", "doc":  return "doc.text.fill"
        case "rtf":          return "doc.text.fill"
        case "md", "txt":    return "doc.plaintext.fill"
        default:             return "doc.fill"
        }
    }

    private func send() {
        if !vm.manualInput.isEmpty { vm.showManualInput = true }
        vm.sendToAI()
    }
}

/// "DEV" / "BETA" tag under the brand logo. The app has no Dock icon, so
/// this is the only way to tell side-by-side builds apart at a glance.
/// Production renders nothing.
private struct ChannelBadge: View {
    var body: some View {
        if let label = AppChannel.current.badge {
            Text(label)
                .font(.system(size: 7, weight: .heavy, design: .rounded))
                .tracking(0.4)
                .foregroundColor(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Capsule().fill(
                    AppChannel.current == .dev ? Design.Accent.amber : Design.Accent.purple
                ))
                .offset(y: -3)
                .allowsHitTesting(false)
        }
    }
}

/// Slightly bigger / more readable bar icon. Two visual states:
///   - hover lifts brightness so each icon visibly responds before click;
///   - active state paints the whole circle in the accent tint with a
///     stronger stroke so the current surface reads at a glance.
/// Sizing stays 30×30 so the bar height doesn't shift.
private struct SurfaceIcon: View {
    let systemName: String
    let tint: Color
    let active: Bool
    let attention: Bool
    @State private var hovering = false

    var body: some View {
        ZStack {
            Circle()
                .fill(fillColor)
            Circle()
                .strokeBorder(strokeColor, lineWidth: 0.5)
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(tint)
        }
        .frame(width: 30, height: 30)
        // Visual state changes are PAINT-only (fill color, stroke color,
        // tint). No scaleEffect, no font-weight swap, no stroke-width
        // swap — those all caused the icon to subtly shift in size on
        // click/hover, which read as the icon "jumping." Keeping the
        // visual feedback to color animation only means the icon's
        // bounding glyph stays pixel-stable across every state.
        .brightness(hovering && !active ? 0.06 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.18), value: active)
        .contentShape(Circle())
        .onHover { hovering = $0 }
    }

    private var fillColor: Color {
        if active {
            return Color.white.opacity(0.12)
        }
        if attention {
            return Design.Accent.amber.opacity(0.14)
        }
        return hovering ? Design.Surface.controlHoverFill : Design.Surface.controlFill
    }

    private var strokeColor: Color {
        if active {
            return Color.white.opacity(0.22)
        }
        if attention {
            return Design.Accent.amber.opacity(0.40)
        }
        return Design.Surface.hairline
    }
}
