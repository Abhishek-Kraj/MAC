import Cocoa
import SwiftUI
import ScreenCaptureKit

// Always shows the arrow cursor over the overlay, even over text fields.
// Prevents the I-beam cursor from appearing during screen share (the overlay is hidden
// from capture but the cursor shape is still visible to the interviewer).
final class OverlayHostingView: NSHostingView<AnyView> {
    /// The border strips that should advertise a resize cursor, in this view's
    /// own coordinate space. Set by `AppDelegate`; empty when nothing on the
    /// panel is resizable (the pill).
    var resizeBands: (() -> [(PanelResizeEdge, NSRect)])?

    override func resetCursorRects() {
        // Do NOT call super — that would let SwiftUI register I-beam rects for text fields.
        addCursorRect(bounds, cursor: .arrow)
        // The resize borders are added AFTER the arrow, which is what makes
        // them win: where two cursor rects overlap, the one added last takes
        // precedence. This is also the only mechanism that works during an
        // interview — the panel is a nonactivating panel and mouse-moved
        // events follow the ACTIVE application, so a hover handler never fires
        // while another app is frontmost, even though dragging the border
        // works fine. Cursor rects are tracked by the window server per window
        // and do not care who is active.
        for (edge, rect) in resizeBands?() ?? [] {
            addCursorRect(rect, cursor: edge.cursor)
        }
    }
}

// NSPanel subclass that keeps the overlay inside the visible screen in real time
// (so drag can never push it off-screen) while still allowing the panel to sit
// flush with the screen's absolute bottom — our window level is above the Dock,
// so the Dock area is a legitimate resting spot for the pill.
//
// `canBecomeKey` is overridden so text fields inside the nonactivating panel
// still accept keyboard input.
class UnconstrainedPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        var f = frameRect

        // Enforce minSize ourselves. Borderless / nonactivating panels
        // don't always get the standard AppKit min-size clamping during
        // user-initiated drag-resize, which lets the user shrink the
        // panel small enough to clip its contents. Re-enforce it here so
        // every code path (programmatic AND drag) honors the minimum.
        f.size.width  = max(f.size.width,  self.minSize.width)
        f.size.height = max(f.size.height, self.minSize.height)

        // Position constraint — keep the panel on a connected screen
        // (full frame so the bottom can reach the absolute edge; the
        // visibleFrame caps the top to leave room for the menu bar).
        //
        // This used to fall back to `NSScreen.main`, which is the screen
        // holding key focus. On a multi-display setup that is the wrong
        // display for a drag in progress, so the panel was clamped back to
        // the focused screen and could not be pulled onto the second one.
        // The target is now resolved from the frame being requested, which is
        // the ground truth of where the panel is going.
        guard let target = ScreenPlacement.screen(for: f, hint: screen) else { return f }
        return ScreenPlacement.clamp(f, to: target)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Told whenever the panel is shown or hidden, whichever call did it.
    var onVisibilityChange: ((Bool) -> Void)?

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        onVisibilityChange?(isVisible)
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        onVisibilityChange?(isVisible)
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        onVisibilityChange?(isVisible)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var overlayPanel: NSPanel!
    var vm: OverlayViewModel!

    private var localKeyMonitor: Any?
    private var optionKeyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var fnKeyDown        = false   // tracks Fn/Globe key for quick-ask push-to-talk
    private var dictationKeyDown = false   // tracks Option key for dictation push-to-talk
    private var dictationManager: DictationManager?
    private var sigtermSource: DispatchSourceSignal?
    private var lastFrontAppPID: pid_t = 0
    private let callDetector = CallDetector()
    private var callPrompt: CallPromptPanel?
    private var menuBar: MenuBarController?
    private var isOnCall = false
    private let moveStep:   CGFloat = 20
    private let resizeStep: CGFloat = 20

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .utility).async { LegacyLaunchShortcutCleanup.removeIfInstalled() }
        vm = OverlayViewModel()
        // Re-attach the résumé and posting typed last session. Cheap, and it
        // stops a rebuild from wiping the slowest part of setup.
        vm.restoreInterviewSetup()
        NSApp.setActivationPolicy(.accessory)
        // Seed the screen-share gate BEFORE any window is created so the
        // panel (and the swizzle) pick up the persisted preference.
        NSWindow.screenShareInvisible = vm.screenShareInvisible
        setupOverlayPanel()

        // `open -a "TheCloser Dev.app" --args -troubleshoot` opens the
        // inspector at launch. The app has no windows of its own and the
        // overlay hides itself from screen sharing, so there was previously no
        // way to get to an inspectable window from outside the process — and
        // that is exactly what you need when you cannot drive the UI.
        if CommandLine.arguments.contains("-troubleshoot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.toggleInspector()
            }
        }

        // `--args -probescreen [file]` asks for Screen Recording at launch —
        // even when the once-per-install guard in
        // prewarmScreenRecordingIfNeeded has already fired — and writes the
        // outcome to `file`. macOS only lists an app in the Privacy pane
        // after the app itself has asked, so a `tccutil reset` leaves the app
        // invisible there until it asks again; this flag does the asking and
        // lets a shell read the answer back without anyone watching a screen.
        if let probeIdx = CommandLine.arguments.firstIndex(of: "-probescreen") {
            let next = probeIdx + 1
            let out = CommandLine.arguments.indices.contains(next)
                && !CommandLine.arguments[next].hasPrefix("-")
                ? URL(fileURLWithPath: CommandLine.arguments[next])
                : URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("thecloser-screen-probe.txt")
            Task { @MainActor in
                let grantedBefore = CGPreflightScreenCaptureAccess()
                if !grantedBefore { _ = CGRequestScreenCaptureAccess() }
                var content = "ok"
                do { _ = try await SCShareableContent.current }
                catch { content = "error: \((error as NSError).localizedDescription)" }
                let grantedAfter = CGPreflightScreenCaptureAccess()
                self.vm.needsScreenRecordingPermission = !grantedAfter
                let report = [
                    "granted-before: \(grantedBefore)",
                    "shareable-content: \(content)",
                    "granted-after: \(grantedAfter)",
                ].joined(separator: "\n")
                try? report.write(to: out, atomically: true, encoding: .utf8)
                NSLog("[ScreenProbe] %@", report.replacingOccurrences(of: "\n", with: " | "))
            }
        }

        // `--args -snapshot [dir]` writes a picture of the app's own windows at
        // launch, and `-surface <name>` (e.g. `-surface settings`) opens that
        // surface first so a specific screen can be photographed. Together they
        // are how the interface gets looked at from outside the process, which
        // is otherwise impossible: the overlay is excluded from capture and the
        // app has no windows macOS knows how to show.
        if let snapIdx = CommandLine.arguments.firstIndex(of: "-snapshot") {
            // The bar's hover auto-collapse would undo every expansion, and
            // there is no pointer when this is driven from a shell.
            vm.debugSuppressAutoCollapse = true
            let next = snapIdx + 1
            let dir = CommandLine.arguments.indices.contains(next)
                && !CommandLine.arguments[next].hasPrefix("-")
                ? URL(fileURLWithPath: CommandLine.arguments[next])
                : nil

            // `-surface none` expands the shell with no surface open — the
            // bar-only row, which is where the surface buttons live.
            // `-surface settings` opens the Settings window instead, since
            // settings are no longer a surface of this panel.
            var forceExpanded = false
            var surface: OverlayViewModel.PrimarySurface?
            // `-seedcall` photographs a Regular call IN PROGRESS. The call
            // live view (a growing transcript) is otherwise unreachable from
            // a shell: starting one needs the mic, which a scripted run has
            // no permission to use.
            var didSeedCall = false
            var didSeedMinutes = false
            // The seeds write turns and `-fresh` starts a session. Both go into
            // one throwaway session, deleted once the picture is taken: they
            // used to land in whatever session was active, and runs had left
            // 52 fixture exchanges across 8 real sessions. The store is used
            // directly because the view model's startNewSession also asks the
            // AI to retitle the session being closed — the user's own.
            let originalSessionID = vm.sessionStore.activeSessionID
            var throwawaySessionID: UUID?
            func useThrowawaySession(kind: ChatSession.Kind) {
                guard throwawaySessionID == nil else { return }
                self.vm.sessionStore.startNewSession(mode: self.vm.sessionMode, kind: kind)
                throwawaySessionID = self.vm.sessionStore.activeSessionID
            }
            func discardThrowawaySession() {
                guard let id = throwawaySessionID else { return }
                throwawaySessionID = nil
                let store = self.vm.sessionStore
                store.delete(id: id)
                store.continueSession(id: originalSessionID)
                store.flushPendingPersist()
            }
            func seedLiveCallIfRequested(_ seed: () -> Void) {
                guard CommandLine.arguments.contains("-seedcall"), !didSeedCall else { return }
                didSeedCall = true
                useThrowawaySession(kind: .regularCall)
                seed()
            }
            if let surfIdx = CommandLine.arguments.firstIndex(of: "-surface"),
               CommandLine.arguments.indices.contains(surfIdx + 1) {
                let raw = CommandLine.arguments[surfIdx + 1]
                if raw == "none" {
                    forceExpanded = true
                } else if raw == "regularCall" {
                    // The Interview surface's other tab. It only switches by
                    // clicking the mode bar, so without this the Regular call
                    // setup form cannot be photographed at all. `-fresh` alone
                    // is not enough: it starts a plain session, which the
                    // regular-call tab treats as a live call and renders as
                    // the chat.
                    vm.interviewSurfaceMode = .regularCall
                    vm.forceInterviewSetup = !CommandLine.arguments.contains("-seedcall")
                    seedLiveCallIfRequested {
                        vm.audioSource        = .both
                        vm.sessionMode        = .call
                        vm.isInterviewSession = true
                        vm.showLiveTranscript = true
                        // Mid-sentence on both lanes: this is what makes the
                        // photograph show a call in progress rather than a
                        // finished exchange.
                        vm.transcription      = "and the rollout across the other three entities starts in March"
                        vm.mySpeech           = "that works, I will share the capacity numbers before then"
                        // Two exchanges already behind us, so the growing
                        // transcript layout can be photographed without a
                        // live call (and its permissions).
                        for (q, a) in [
                            ("Hey, quick update on the Fabric rollout — are we still on track for the March window?",
                             "- They're checking whether the rollout is still on the original timeline.\n- Say yes, with the caveat that two of four entities are already in production."),
                            ("We should be, yes. The throttling issue from last month is fixed and CU consumption is stable.",
                             "- They're confirming the throttle fix held and consumption is steady.\n- Follow-up: send the utilisation numbers so they can verify independently."),
                        ] {
                            self.vm.sessionStore.appendTurn(user: q, assistant: a)
                        }
                    }
                    surface = .interview
                } else {
                    if raw == "interview" { vm.interviewSurfaceMode = .interview }
                    surface = OverlayViewModel.PrimarySurface(rawValue: raw)
                }
            }

            // Open the surface AND resize the panel. Setting the stage alone
            // is not enough at launch: the panel is created at the pill size
            // (80x64) and expands through the stage-change callback, so
            // assigning the stage without animating left the surface drawn
            // into an 80pt-tall window.
            //
            // Then re-asserted on a tick. InputBarView collapses itself back
            // to the pill 350ms after the pointer is not over it, and driven
            // from a shell there is no pointer at all — so a single
            // programmatic expand is undone before anything can be drawn.
            // The capture happens inside that 350ms window, right after a
            // final assertion, so the stage it draws is the one asked for.
            var didFresh = false
            var didSeed  = false
            func openSurface() {
                // `-seedminutes` opens the summary surface with sample content.
                // Keep the requested mode (e.g. regularCall) for its title.
                if CommandLine.arguments.contains("-seedminutes"), !didSeedMinutes {
                    didSeedMinutes = true
                    vm.minutesText = """
                    The call covered the Fabric rollout across four legal entities. The \
                    March window holds as long as the throttling fix does, and \
                    utilisation numbers go out before the next sync.

                    ### Rollout schedule
                    - Two of four entities are already in production.
                    - The March window stays; no change to the per-entity order.

                    ### Capacity and throttling
                    - The throttling issue from last month is fixed; CU use is stable.
                    - Keep the 20% headroom for month-end reporting spikes.
                        - Throttling only appeared below 10% headroom.

                    ### Next steps
                    - (Abhishek) Send the CU utilisation numbers — before the next sync
                    - (Gokul) Confirm the remaining two entities are production-ready
                    - (Rucha) Re-check throttling after the March workloads land — March

                    ### Decisions
                    - Keep the March rollout window.
                    - Hold the 20% headroom buffer.

                    ### Open questions
                    - Whether the overflow pool stays shared or is split per entity.
                    """
                    vm.showMinutesSheet = true
                    vm.primarySurface = .summary
                    // Also photograph what the panel looks like AFTER the
                    // sheet closes: the "bare bar with no surface above it"
                    // state that ending a call used to leave behind.
                    if CommandLine.arguments.contains("-seedafter") {
                        vm.showMinutesSheet = false
                        vm.stopInterviewSession()
                        vm.primarySurface = .summary
                    }
                }
                guard surface != nil || forceExpanded || didSeedMinutes else { return }
                // `-fresh` clears the active session once, so the Interview
                // surface draws its setup form rather than resuming whatever
                // session was last open. That setup form is the screen the
                // user actually starts from, and it is otherwise impossible to
                // photograph from a shell — the app always resumes. Once only:
                // this runs on every tick, and starting a session per tick
                // would litter the store with empty sessions.
                if CommandLine.arguments.contains("-fresh"), !didFresh {
                    didFresh = true
                    useThrowawaySession(kind: .normal)
                }
                // `-seedtranscript` puts a fixed You + Them exchange in the
                // strip and transcript panel so the split layout can be
                // photographed without a live call (and its permissions).
                // Once only, like -fresh.
                if CommandLine.arguments.contains("-seedtranscript"), !didSeed {
                    didSeed = true
                    useThrowawaySession(kind: .interview)
                    self.vm.audioSource        = .both
                    self.vm.sessionMode        = .interview
                    self.vm.interviewSurfaceMode = .interview
                    self.vm.isInterviewSession = true
                    self.vm.showLiveTranscript = true
                    self.vm.transcription      = "Walk me through how you set the Fabric capacity plan across the entities."
                    self.vm.mySpeech           = "We started with a single F64 and tracked CU consumption per entity."
                    self.vm.mySpeechSegments = [
                        SpokenSegment(text: "I led the platform rollout for four legal entities.",
                                      at: Date(timeIntervalSinceNow: -120)),
                        SpokenSegment(text: "We only split capacity once throttling showed up in the metrics app.",
                                      at: Date(timeIntervalSinceNow: -40)),
                    ]
                    // Two completed exchanges so the Live Focus question
                    // line + answer photograph with real content, and the
                    // ‹ 2/2 › navigation shows. The seeded live transcription
                    // above matches the newest question, as it would right
                    // after the interviewer finished asking it.
                    self.vm.sessionStore.appendTurn(
                        user: "Sorry, then you have to update everybody that you are on top of it, build it up.",
                        assistant: """
                        - They're noting a past miscommunication where the discussion went off-track, and want everyone kept updated.
                        - Suggested reply: "Understood — I'll make sure updates go to everyone on the thread so we stay aligned this time."
                        - Follow-up: send a status update to the group.
                        """)
                    self.vm.sessionStore.appendTurn(
                        user: "Walk me through how you set the Fabric capacity plan across the entities.",
                        assistant: """
                        - Consolidated four entities onto one F64 capacity after profiling CU usage per workload.
                        - Left a 20% headroom buffer for month-end reporting spikes; throttling only appeared once we dropped below 10%.
                        - Split billing back out per entity with a shared overflow pool for peak windows.
                        """)
                }
                self.vm.primarySurface = didSeedMinutes ? .summary : surface
                self.vm.shellStage = .expanded
                self.animateShellFrame(stage: .expanded)
            }

            func capture() {
                // Printed so a shell driving the app can find the files
                // without guessing the timestamp.
                for url in self.saveSnapshots(to: dir) {
                    print("SNAPSHOT \(url.path)")
                }
                if CommandLine.arguments.contains("-dumpviews") {
                    let dump = (self.viewGeometryDump() + self.dumpWindowFrontage())
                        .joined(separator: "\n") + "\n"
                    let target = (dir ?? Self.snapshotDirectory)
                        .appendingPathComponent("geometry.txt")
                    try? dump.write(to: target, atomically: true, encoding: .utf8)
                }
            }

            var ticks = 8
            func tick() {
                openSurface()
                ticks -= 1
                guard ticks > 0 else {
                    // Final assertion, then draw before the dwell fires.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        capture()
                        discardThrowawaySession()
                        if CommandLine.arguments.contains("-resizeprobe") {
                            self.probePanelResize()
                        }
                    }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { tick() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { tick() }
        }
        // No menu-bar status item: the icon next to the clock/battery is
        // visible to other people during screen shares (the menu bar IS
        // captured, unlike our capture-excluded panel) and defeats the
        // app's discretion. Quit / Reset position moved into the session
        // ⋯ menu inside the overlay.
        setupKeyboardShortcuts()
        installTerminationSignalHandler()

        // With @Observable the ViewModel no longer publishes a Combine $opacity.
        // Use a direct callback so we only do the work that matters.
        vm.onOpacityChange = { [weak self] val in
            self?.overlayPanel.alphaValue = val
        }
        overlayPanel.alphaValue = vm.opacity

        // Flip every app window's capture exclusion when the user toggles
        // screen-share visibility in Settings.
        vm.onScreenShareVisibilityChange = { [weak self] invisible in
            self?.applyScreenShareVisibility(invisible)
        }

        vm.onRecordingChange = { [weak self] recording in
            HotkeyManager.shared.setLiveSessionHotkeys(recording)
            self?.updateMenuBarVisibility()
        }

        // Calls. The detector always runs: besides the "start your
        // interview?" prompt, it's what hides the menu-bar icon during calls,
        // and that has to happen even with the prompt switched off.
        callPrompt = CallPromptPanel()
        callDetector.onChange = { [weak self] app in
            guard let self else { return }
            self.isOnCall = app != nil
            self.vm.callAppDidChange(app)
            self.updateMenuBarVisibility()
        }
        vm.onDetectedCallAppChange = { [weak self] app in
            guard let self else { return }
            if let app {
                self.callPrompt?.show(appName: app, vm: self.vm,
                                     onStart: { [weak self] in self?.startInterviewFromCallPrompt() },
                                     onDismiss: { [weak self] in self?.vm.dismissCallPrompt() })
            } else {
                self.callPrompt?.hide()
            }
        }
        callDetector.start()

        // Dev and Beta only: `open -a "TheCloser Dev" --args -simulateCall Zoom`
        // fakes a call, to check the prompt and the menu-bar icon without
        // joining one.
        if AppChannel.current != .production,
           let app = UserDefaults.standard.string(forKey: "simulateCall") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.callDetector.onChange?(app)
            }
        }

        menuBar = MenuBarController(
            onOpen: { [weak self] in self?.showOverlay() },
            isCallPromptOn: { [weak self] in self?.vm.suggestSessionOnCall ?? false },
            setCallPrompt: { [weak self] on in self?.vm.suggestSessionOnCall = on })
        // Set explicitly: macOS remembers a status item's visibility across
        // launches, so a quit mid-call would otherwise start it hidden.
        updateMenuBarVisibility()

        // Animate the NSPanel between pill and expanded sizes whenever
        // the VM transitions stage. The bottom edge stays pinned so the
        // bar doesn't visibly jump as the panel grows / shrinks.
        vm.onShellStageChange = { [weak self] stage in
            if stage.isOnScreen { self?.updatePillAnchor() }
            self?.animateShellFrame(stage: stage)
        }

        // Re-fire the resize whenever the floating pill popup
        // (resume score / generated resume / quick-ask) appears or
        // disappears in pill mode — the panel needs to grow tall enough
        // to host the popup above the brand pill.
        vm.onPillPopupChange = { [weak self] _ in
            guard let self, let stage = self.vm?.shellStage else { return }
            self.animateShellFrame(stage: stage)
        }
        // The expanded panel adapts to whether a surface is open
        // (compact bar-only vs. full body). Surface changes need to
        // re-fire the same resize so the panel matches.
        vm.onPrimarySurfaceChange = { [weak self] _ in
            guard let self, let stage = self.vm?.shellStage else { return }
            self.animateShellFrame(stage: stage)
        }

        // Drag handles behind the header strip and the input bar.
        vm.onResetPanelSize = { [weak self] in
            MainActor.assumeIsolated { self?.resetPanelSize() }
        }

        vm.onPanelDrag = { [weak self] dx, dy, ended in
            self?.handlePanelDrag(dx: dx, dy: dy, ended: ended)
        }

        // Live Focus reports its content height; track the panel to it so
        // the window grows/shrinks smoothly with the streamed answer.
        vm.onFocusContentHeight = { [weak self] h in
            self?.handleFocusContentHeight(h)
        }

        // Stepping to another Q&A pair (or toggling the transcript
        // drop-down) re-checks the fit — but a manual size holds: the
        // panel no longer snaps back to the content height when the
        // user flips through answers or toggles the strip.
        vm.onResumeFocusTracking = { [weak self] in
            guard let self else { return }
            self.applyFocusPanelHeight()
        }

        // Watch the panel's position so the shell can flip the sidebar to the
        // correct side as the user drags the overlay around the screen.
        updatePillAnchor()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidMove),
            name: NSWindow.didMoveNotification,
            object: overlayPanel
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidMove),
            name: NSWindow.didResizeNotification,
            object: overlayPanel
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onCaptureScreenshot),
            name: .captureScreenshot,
            object: nil
        )

        // Screen Recording permission for system-audio capture. This used to
        // call `SCShareableContent.current` unconditionally at every launch
        // "to pre-warm the dialog". If the user had not granted it, macOS
        // showed the system prompt again on every single start, which read
        // as the app nagging — and could not be dismissed permanently.
        //
        // Now: ask once, and if it is not granted afterwards, stop asking and
        // point at System Settings from inside the app instead.
        Task { await prewarmScreenRecordingIfNeeded() }

        // Accessibility permission is needed for Option-key dictation, which
        // pastes into the active app. We DON'T prompt at launch — the system
        // dialog stalls applicationDidFinishLaunching and most users never
        // touch dictation. The prompt is shown lazily on first dictation
        // attempt; see ensureAccessibilityPrompted().

        // Track which app was frontmost before any hotkey fires
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontAppChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // ── Screen-share / screenshot protection ──────────────────────────────
        // Notifications and timers are async — a screen-sharing tool can capture
        // a menu window in the gap before they fire.  Swizzling NSWindow's three
        // "order on screen" methods is the only synchronous hook that runs in the
        // SAME call-stack as the window appearing, before any capture frame occurs.
        NSWindow.installScreenShareProtection()
    }

    // MARK: - Overlay Panel

    /// `.pill` — the brand dot. Just big enough for the logo capsule (a
    /// 52pt circle) plus the panel's own 6pt padding, so the window and the
    /// visible dot are the SAME size: a transparent margin would be window
    /// area that swallows clicks meant for whatever is underneath, which
    /// defeats the point of a collapsed overlay. Small so the pill can reach
    /// any screen edge.
    static let collapsedSize = NSSize(width: 80, height: 64)
    /// `.pill` with a floating result popup (resume score / generated
    /// resume / quick-ask) anchored above the brand. Grows the panel
    /// tall and wide enough to host the popup without expanding the
    /// shell — the user still sees only the pill + the popup card.
    static let pillWithPopupSize = NSSize(width: 480, height: 360)
    /// `.expanded` with no `primarySurface` — InputBar only, single row.
    static let expandedCompactSize = NSSize(width: 440, height: 84)
    /// `.expanded` with a `primarySurface` set — full shell: top header
    /// + body + InputBar. Narrow + tall ChatGPT-companion proportions.
    /// Tall enough for the interview setup form, which stacks ten sections
    /// — resume, context, prep, prompt, auto-generate, model, depth, start —
    /// into a scrolling column. At 600 it scrolled, but the fold sat mid-form
    /// so Start and the depth control were below it with nothing indicating
    /// there was more, which reads as a layout that "is not coming properly".
    ///
    /// The live views do not use this height: they compute their own (see
    /// `responseExpandedSize`, `expandedCompactSize`, and the focus-hug path),
    /// so raising it costs nothing during an interview.
    ///
    /// One size for every screen (user's call, 2026-10-20): 640 wide fits
    /// Settings' sidebar and keys, so switching tabs never resizes the panel.
    static let expandedSize  = NSSize(width: 640, height: 720)
    /// `.expanded` while showing chat/interview answers. Fixed compact
    /// height keeps streaming stable; long answers scroll inside the card
    /// instead of resizing the native window on every token.
    static let responseExpandedSize = NSSize(width: 440, height: 360)
    /// Settings can't be dragged narrower than this: keys and the model
    /// catalogue need the room.
    static let settingsMinSize = NSSize(width: 640, height: 520)

    /// Last-known full-state size. Captured whenever the user transitions
    /// from full → mini so we can restore exactly what they had on expand,
    /// and so the mini state preserves the user's manual panel width.
    private var lastFullSize: NSSize = expandedSize

    @MainActor
    func setupOverlayPanel() {
        // If the user lands on the welcome / sign-in flow at launch, the
        // hero content needs the full panel — starting at the pill size
        // (80×64) leaves the content clipped out the bottom of the
        // window. Decide the initial stage + size BEFORE the panel goes
        // on screen so there's no visible resize jump.
        let needsHeroLayout = !vm.hasCompletedOnboarding || vm.showOnboarding
        if needsHeroLayout {
            vm.shellStage = .expanded
        }
        let initial = needsHeroLayout ? Self.expandedSize : Self.collapsedSize
        let w: CGFloat = initial.width, h: CGFloat = initial.height
        guard let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame
        let frame = NSRect(x: sf.midX - w / 2, y: sf.maxY - h - 20, width: w, height: h)

        let panel = UnconstrainedPanel(
            contentRect: frame,
            // No .fullSizeContentView — that lets us resize height freely
            styleMask:   [.nonactivatingPanel, .resizable],
            backing:     .buffered,
            defer:       false
        )
        // ⌘⇧ + arrows move the overlay only while it's showing.
        panel.onVisibilityChange = { HotkeyManager.shared.setMoveHotkeys($0) }
        // Dragging the panel's edges goes through `windowWillResize`.
        panel.delegate = self
        overlayPanel = panel
        // `isFloatingPanel` forces the panel's level to `.floating`, so it has
        // to be set BEFORE the level we actually want — the other order looked
        // right and silently left the overlay at level 3, below Control Center
        // and anything else floating. Verified via the window list: the panel
        // reported `layer=3` where `.statusBar + 1` is 26.
        overlayPanel.isFloatingPanel            = true
        // Pin the panel to dark at the AppKit level, not just via
        // `.preferredColorScheme(.dark)` on its content view. A SwiftUI sheet
        // is presented in its OWN window, outside the presenting view's
        // modifier chain — so the colour scheme did not reach it. On a Mac in
        // light mode that rendered every sheet (call summary, create prompt,
        // prep setup, bank, backups, editor, new workspace) light-on-light:
        // a washed-out grey title on near-white, unreadable against this dark
        // app. Setting appearance on the panel makes every attached sheet
        // inherit it, so this class of bug cannot come back per-sheet.
        overlayPanel.appearance                 = NSAppearance(named: .darkAqua)
        overlayPanel.level                      = .statusBar + 1
        overlayPanel.collectionBehavior         = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        overlayPanel.isOpaque                   = false
        overlayPanel.backgroundColor            = .clear
        overlayPanel.hasShadow                  = true
        overlayPanel.titlebarAppearsTransparent = true
        overlayPanel.titleVisibility            = .hidden
        overlayPanel.isMovableByWindowBackground = true
        overlayPanel.hidesOnDeactivate          = false
        overlayPanel.becomesKeyOnlyIfNeeded     = true
        // Deliberately no `acceptsMouseMovedEvents`: hover feedback cannot be
        // used for the border cursor, because mouse-moved events go to the
        // active application and during an interview that is never this one.
        // `OverlayHostingView.resetCursorRects` owns the cursor instead.
        overlayPanel.sharingType                = NSWindow.desiredSharingType
        // Initial minSize matches the launch stage; `animateShellFrame`
        // updates it on every stage transition so the user can never
        // shrink the panel below what's visible.
        overlayPanel.minSize                    = needsHeroLayout ? Self.expandedMinSize : Self.pillMinSize
        overlayPanel.alphaValue                 = 1.0  // synced via opacityObserver after setup

        let hosting = OverlayHostingView(rootView: AnyView(OverlayView().environment(vm)))
        // Disable intrinsic-size constraints so the panel controls its own size
        hosting.sizingOptions = []
        // The border cursors are the hosting view's cursor rects, refreshed
        // whenever the panel's geometry or stage changes.
        hosting.resizeBands = { [weak self] in self?.currentResizeBands() ?? [] }
        overlayHostingView = hosting
        overlayPanel.contentView = hosting

        // Restore last-used position (constrainFrameRect will clamp if the saved
        // origin is on a monitor that's no longer connected).
        restorePanelOrigin()

        // Resizing from any edge or corner is taken by an event monitor rather
        // than by views inside the shell — see `installPanelResizeMonitor`.
        installPanelResizeMonitor()

        // The window can launch already expanded (the last stage is restored),
        // in which case no stage transition runs to register the bands.
        refreshResizeCursors()

        overlayPanel.orderFrontRegardless()
    }

    // MARK: - Keyboard Shortcuts

    func setupKeyboardShortcuts() {
        // Carbon RegisterEventHotKey: global, no Accessibility needed, never auto-disabled
        HotkeyManager.shared.onAction = { [weak self] action, isPressed in
            guard let self else { return }
            // Every action fires on press
            switch action {
            case .moveLeft:    if isPressed { self.movePanel(dx: -self.moveStep, dy: 0) }
            case .moveRight:   if isPressed { self.movePanel(dx:  self.moveStep, dy: 0) }
            case .moveUp:      if isPressed { self.movePanel(dx: 0, dy:  self.moveStep) }
            case .moveDown:    if isPressed { self.movePanel(dx: 0, dy: -self.moveStep) }
            case .resizeLeft:  if isPressed { self.resizePanel(dw: -self.resizeStep, dh: 0) }
            case .resizeRight: if isPressed { self.resizePanel(dw:  self.resizeStep, dh: 0) }
            case .resizeUp:    if isPressed { self.resizePanel(dw: 0, dh:  self.resizeStep) }
            case .resizeDown:  if isPressed { self.resizePanel(dw: 0, dh: -self.resizeStep) }
            case .screenshotSendLive:
                                  if isPressed { self.captureAndSendScreenshot() }
            case .answerNow:      if isPressed { self.answerNow() }
            case .clipboard:   if isPressed { self.explainClipboard() }
            case .toggle:      if isPressed { self.toggleOverlay() }
            case .sendSelection:  if isPressed { self.sendSelection() }
            case .resumeGenerate: if isPressed { self.resumeFromClipboard() }
            case .resumeScore:    if isPressed { self.scoreResumeFromClipboard() }
            case .quickAsk:       break   // handled via Fn flagsChanged monitor
            }
        }
        HotkeyManager.shared.register()

        // Fn/Globe + Option key monitoring via both global and local flagsChanged monitors.
        // Global fires when another app is frontmost; local fires when overlay panel is key.
        // Both call the same shared handler so nothing is missed.
        let flagsHandler: (NSEvent) -> Void = { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        optionKeyMonitor  = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler)
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)  { event in
            flagsHandler(event); return event
        }

        // Local monitor as fallback when overlay panel is key
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Handle ⌘N for new session while the overlay is key. Return
            // nil to consume the event so it doesn't propagate to text
            // fields.
            // Exactly ⌘N, and only in the overlay — not ⌘⇧N, not Settings.
            if let self,
               event.window === self.overlayPanel,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "n" {
                Task { @MainActor [weak self] in
                    self?.vm.requestNewSession()
                }
                return nil
            }
            self?.handleKey(event)
            return event
        }

    }

    // MARK: - Send selection (Ctrl+Opt+A)

    func sendSelection() {
        // Use the tracked PID of the app that was active before our hotkey fired
        let pid = lastFrontAppPID
        guard pid != 0 else { return }

        let src     = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags   = .maskCommand
        keyDown?.postToPid(pid)
        keyUp?.postToPid(pid)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            guard let text = NSPasteboard.general.string(forType: .string),
                  !text.isEmpty else { return }
            if !overlayPanel.isVisible { overlayPanel.orderFrontRegardless() }
            Task { @MainActor in
                self.vm.showManualInput = true
                self.vm.manualInput     = text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.vm.sendToAI()
            }
        }
    }

    /// ⌘⏎ during a live session: answer what's been heard so far without
    /// waiting for the speaker to pause. Same as the bar's send button.
    func answerNow() {
        DispatchQueue.main.async { [self] in
            if !overlayPanel.isVisible { overlayPanel.orderFrontRegardless() }
            Task { @MainActor in self.vm.sendTranscriptManually() }
        }
    }

    func resumeFromClipboard() {
        DispatchQueue.main.async { [self] in
            if !overlayPanel.isVisible { overlayPanel.orderFrontRegardless() }
            Task { @MainActor in self.vm.generateResumeFromClipboard() }
        }
    }

    func scoreResumeFromClipboard() {
        DispatchQueue.main.async { [self] in
            if !overlayPanel.isVisible { overlayPanel.orderFrontRegardless() }
            Task { @MainActor in self.vm.scoreResumeFromClipboard() }
        }
    }

    // MARK: - Flags changed (Fn + Option) — shared by global + local monitors

    private func handleFlagsChanged(_ event: NSEvent) {
        let mods    = event.modifierFlags.intersection([.option, .control, .shift, .command, .function])
        let fnDown  = FeatureFlags.quickAskEnabled && mods.contains(.function)
        let optDown = FeatureFlags.dictationEnabled
                      && mods.contains(.option) && !mods.contains(.control)
                                              && !mods.contains(.shift)
                                              && !mods.contains(.command)

        // ── Fn/Globe: push-to-talk quick ask ────────────────────────
        // Hold Fn → start recording; release Fn → stop & send to AI
        if fnDown && !fnKeyDown {
            fnKeyDown = true
            if !overlayPanel.isVisible { overlayPanel.orderFrontRegardless() }
            Task { @MainActor in
                if !vm.isQuickAsking && !vm.isQuickAskSending { vm.toggleQuickAsk() }
            }
        } else if !fnDown && fnKeyDown {
            fnKeyDown = false
            Task { @MainActor in
                if vm.isQuickAsking { vm.toggleQuickAsk() }
            }
        }

        // ── Option alone: push-to-talk dictation into active app ────
        if optDown && !dictationKeyDown {
            dictationKeyDown = true
            ensureAccessibilityPrompted()
            let pid = lastFrontAppPID
            let mgr = DictationManager()
            dictationManager = mgr

            Task { @MainActor in
                if !overlayPanel.isVisible { overlayPanel.orderFrontRegardless() }
                vm.isDictating   = true
                vm.dictationText = ""
            }
            mgr.onTranscript = { [weak self] text in
                Task { @MainActor in self?.vm.dictationText = text }
            }
            mgr.onPasted = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.vm.isDictating   = false
                    self.vm.dictationText = ""
                    self.vm.statusMessage = "✓ Dictation pasted"
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if self.vm.statusMessage == "✓ Dictation pasted" { self.vm.statusMessage = "" }
                }
            }
            mgr.onStatus = { [weak self] msg in
                Task { @MainActor in self?.vm.statusMessage = msg }
            }
            Task { @MainActor [weak self, weak mgr] in
                guard let self else { return }
                mgr?.start(targetPID: pid, elevenLabsAPIKey: self.vm.elevenLabsAPIKey)
            }

        } else if !optDown && dictationKeyDown {
            dictationKeyDown = false
            dictationManager?.stop()
            dictationManager = nil
            Task { @MainActor in
                vm.isDictating   = false
                vm.dictationText = ""
            }
        }
    }

    private func handleKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let code  = event.keyCode
        if flags == [.command, .shift] {
            switch code {
            case 123: movePanel(dx: -moveStep, dy: 0)
            case 124: movePanel(dx:  moveStep, dy: 0)
            case 125: movePanel(dx: 0, dy: -moveStep)
            case 126: movePanel(dx: 0, dy:  moveStep)
            default: break
            }
        } else if flags == [.control, .option] {
            switch code {
            case 8 where FeatureFlags.clipboardShortcutsEnabled:
                explainClipboard()                     // C
            case 49:  toggleOverlay()                  // Space
            default: break
            }
        } else if flags == [.control, .shift] {
            switch code {
            case 123: resizePanel(dw: -resizeStep, dh: 0)
            case 124: resizePanel(dw:  resizeStep, dh: 0)
            case 125: resizePanel(dw: 0, dh: -resizeStep)
            case 126: resizePanel(dw: 0, dh:  resizeStep)
            default: break
            }
        }
    }

    private func movePanel(dx: CGFloat, dy: CGFloat) {
        DispatchQueue.main.async { [self] in
            overlayPanel.setFrameOrigin(onScreen(overlayPanel.frame.offsetBy(dx: dx, dy: dy)).origin)
        }
    }

    /// `frame` moved fully onto the screen it mostly overlaps.
    private func onScreen(_ frame: NSRect) -> NSRect {
        guard let screen = ScreenPlacement.screen(for: frame, hint: overlayPanel?.screen) else { return frame }
        return ScreenPlacement.clamp(frame, to: screen)
    }

    private func resizePanel(dw: CGFloat, dh: CGFloat) {
        DispatchQueue.main.async { [self] in
            // The pill is a fixed-size dot; ⌃⇧ + arrows must not inflate it
            // into a bigger transparent window that would swallow clicks meant
            // for whatever is underneath. Nothing is readable at that size
            // anyway.
            guard vm.shellStage != .pill else { return }
            let f  = overlayPanel.frame
            let minimum = minimumPanelSize(for: vm.shellStage)
            let nw = max(minimum.width,  f.width  + dw)
            let nh = max(minimum.height, f.height + dh)
            // Anchor top edge: when height grows, origin moves down; when shrinks, moves up
            let newOriginY = f.origin.y + (f.height - nh)
            overlayPanel.setFrame(
                NSRect(x: f.origin.x, y: newOriginY, width: nw, height: nh),
                display: true, animate: false
            )
            // Same precedence as a drag-resize: a manual resize outranks
            // content tracking. Without this the next Live Focus height
            // report animated the panel straight back — a visible
            // grow-then-snap flicker on every keyboard resize.
            if vm.shellStage == .expanded { lastFullSize = overlayPanel.frame.size }
            panelSizePreference.record(overlayPanel.frame.size)
            vm.panelHasManualSize = true
            // Placed by hand, so a resize that was still animating is no longer
            // the frame the panel is heading for.
            forgetPendingPanelResize()
            refreshResizeCursors()
        }
    }

    // MARK: - Drag-to-move (panel drag handles)

    /// Origin captured at the start of a handle drag — same stable-base
    /// reasoning as `panelResizeBaseFrame`.
    private var panelDragBaseOrigin: NSPoint?

    /// Drag-to-move from a `PanelDragArea`. `setFrame` rather than
    /// `setFrameOrigin` so `UnconstrainedPanel.constrainFrameRect` still
    /// clamps the panel to a connected screen — dragging must not be able to
    /// strand the overlay off the edge of the desktop.
    @MainActor
    private func handlePanelDrag(dx: CGFloat, dy: CGFloat, ended: Bool) {
        guard let panel = overlayPanel else { return }
        let base: NSPoint
        if let b = panelDragBaseOrigin {
            base = b
        } else {
            base = panel.frame.origin
            panelDragBaseOrigin = base
        }
        panel.setFrame(NSRect(origin: NSPoint(x: base.x + dx, y: base.y + dy),
                              size: panel.frame.size),
                       display: true)
        // `panelDidMove` persists the origin and re-evaluates the pill
        // anchor on its own — it fires for every move, however caused.
        if ended { panelDragBaseOrigin = nil }
    }

    // MARK: - Drag-to-resize (any edge or corner)

    /// Local mouse monitor that owns the panel's border.
    ///
    /// This replaced eight invisible SwiftUI zones with `DragGesture`s. They
    /// were the obvious way to do it and they did not work, for a reason worth
    /// writing down: every surface body is an AppKit `NSScrollView`, and the
    /// leading and trailing edge strips run straight through it. An AppKit view
    /// hit-tested under the press gets the mouse-down before SwiftUI's gesture
    /// recognition ever runs, so the zone never fired — and because the panel
    /// is `isMovableByWindowBackground`, the press it did not get MOVED the
    /// panel instead.
    ///
    /// A local monitor is the one hook that runs before an event reaches any
    /// view, so the border belongs to the resize and nothing else gets to
    /// interpret the press. It also gives the resize cursors a home that a
    /// scroll view's cursor rects cannot stomp on.
    private var panelResizeMonitor: Any?

    /// The border the in-flight resize grabbed, if any.
    private var activeResizeEdge: PanelResizeEdge?

    /// Absolute screen point the resize began at. Absolute because the window
    /// moves under the cursor as it grows — a window-relative delta would be
    /// polluted by the resize it just caused (the same feedback loop that made
    /// the old grip flicker).
    private var panelResizeAnchor: NSPoint?

    /// The frame the panel's resize animation is heading for, or nil once it
    /// has settled. `panel.frame` reports where the window is *now*, which
    /// during an animation is still the old size — see the shortcut in
    /// `animateShellFrame` for why that matters.
    private var panelResizeTarget: NSRect?

    /// The hosting view whose cursor rects advertise the resize borders.
    private var overlayHostingView: OverlayHostingView?

    /// The border strips that should show a resize cursor right now — empty
    /// except on an expanded panel, since the pill cannot be resized.
    @MainActor
    private func currentResizeBands() -> [(PanelResizeEdge, NSRect)] {
        guard vm.shellStage == .expanded, let hosting = overlayHostingView else { return [] }
        return PanelResizeEdge.bands(in: hosting.bounds.size, flipped: hosting.isFlipped)
    }

    /// Re-register the border cursors. Called wherever the panel's geometry or
    /// stage changes, because the bands are measured from the current size.
    @MainActor
    private func refreshResizeCursors() {
        guard let hosting = overlayHostingView else { return }
        hosting.window?.invalidateCursorRects(for: hosting)
    }

    /// Claim the panel's border for resizing. Installed with the panel so the
    /// monitor exists for exactly as long as the window it serves.
    ///
    /// Which edge a press falls on is decided by `PanelResizeEdge.at(point:in:)`
    /// rather than here. That decision is exactly what broke the first time —
    /// it used to be eight transparent SwiftUI zones, and not one of them ever
    /// received a press — so it lives in a pure function with tests on it.
    ///
    /// The cursor is NOT set from here. It is the hosting view's cursor rects,
    /// for the reason spelled out on `OverlayHostingView.resetCursorRects`.
    @MainActor
    private func installPanelResizeMonitor() {
        panelResizeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            // Local monitors fire on the main thread; the handler type just
            // isn't annotated, which is why every AppKit callback in this file
            // reaches main-actor state the same way.
            return MainActor.assumeIsolated { self.handlePanelResizeEvent(event) }
        }
    }

    /// Which edge or corner is under `point`, in window coordinates, or nil
    /// for the interior.
    @MainActor
    private func panelResizeEdge(atWindowPoint point: NSPoint) -> PanelResizeEdge? {
        guard let panel = overlayPanel else { return nil }
        return PanelResizeEdge.at(point: point, in: panel.frame.size)
    }

    /// Absolute screen point of `event`, in screen coordinates (y up).
    ///
    /// Derived from the event itself rather than `NSEvent.mouseLocation`: the
    /// global read lags the real cursor and does not move at all for a
    /// synthesised drag, and the window's own frame is what the event was
    /// measured against, so adding it back gives an exact absolute point even
    /// though the panel moves under the cursor as it resizes.
    @MainActor
    private func screenPoint(of event: NSEvent) -> NSPoint {
        guard let panel = overlayPanel else { return event.locationInWindow }
        return NSPoint(x: panel.frame.minX + event.locationInWindow.x,
                       y: panel.frame.minY + event.locationInWindow.y)
    }

    /// One mouse event, on its way to a view. Returns nil to swallow it.
    @MainActor
    private func handlePanelResizeEvent(_ event: NSEvent) -> NSEvent? {
        // A resize in flight keeps the drag even after the pointer leaves the
        // panel — same as dragging the edge of any window past the screen.
        if event.type == .leftMouseDragged || event.type == .leftMouseUp {
            guard let edge = activeResizeEdge else { return event }
            let anchor = panelResizeAnchor ?? screenPoint(of: event)
            let now = screenPoint(of: event)
            // Screen y grows upward; the edge arithmetic wants "down is
            // positive" like every other drag in the app.
            handlePanelResize(edge: edge,
                              dx: now.x - anchor.x,
                              dy: anchor.y - now.y,
                              ended: event.type == .leftMouseUp)
            if event.type == .leftMouseUp {
                activeResizeEdge = nil
                panelResizeAnchor = nil
            }
            return nil
        }

        guard event.type == .leftMouseDown, event.window === overlayPanel else { return event }
        // The pill is a fixed-size dot on purpose: its window is exactly the
        // visible circle, so letting it grow would leave a transparent margin
        // that swallows clicks aimed at whatever is underneath.
        guard vm.shellStage == .expanded else { return event }
        guard let edge = panelResizeEdge(atWindowPoint: event.locationInWindow) else {
            return event
        }
        if CommandLine.arguments.contains("-resizeprobe") {
            print("PROBE down point=\(event.locationInWindow) size=\(overlayPanel.frame.size) edge=\(edge)")
        }
        activeResizeEdge = edge
        panelResizeAnchor = screenPoint(of: event)
        panelResizeBaseFrame = overlayPanel.frame
        return nil
    }

    // MARK: - Drag-to-resize (edge and corner geometry)

    /// Frame captured at the start of a resize drag. The drag reports deltas
    /// cumulative from its start, so we apply them against this stable base
    /// rather than compounding per-event deltas.
    private var panelResizeBaseFrame: NSRect?

    /// Set by any manual resize, regardless of the surface it started on.
    private var panelSizePreference = PanelSizePreference()

    /// Edge / corner drag-resize. `dx` grows to the right, `dy` grows
    /// downward; the edge the user grabbed decides which sides of the frame
    /// those move, so the opposite edge stays pinned exactly the way a normal
    /// window's does. Remembers both dimensions in `lastFullSize` so
    /// pill ↔ expanded transitions restore the user's size.
    @MainActor
    private func handlePanelResize(edge: PanelResizeEdge,
                                   dx: CGFloat, dy: CGFloat, ended: Bool) {
        guard let panel = overlayPanel else { return }
        if ended {
            panelResizeBaseFrame = nil
            persistPanelOrigin()
            if vm.isUserResizingPanel { vm.isUserResizingPanel = false }
            // The bands are measured from the panel's size, so they have just
            // moved.
            refreshResizeCursors()
            return
        }
        let base: NSRect
        if let b = panelResizeBaseFrame {
            base = b
        } else {
            base = panel.frame
            panelResizeBaseFrame = base
        }
        // Flag only on transition — re-setting it per mouse event would
        // invalidate observers 60+ times a second for no layout change.
        if !vm.isUserResizingPanel { vm.isUserResizingPanel = true }
        let frame = edge.resizedFrame(from: base, dx: dx, dy: dy,
                                      minimum: minimumPanelSize(for: vm.shellStage))
        // Unanimated + no implicit animation: the drag IS the animation.
        // Letting an implicit animation chase each mouse event puts the
        // panel a frame behind the cursor, which reads as lag/judder.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        panel.setFrame(frame, display: true)
        NSAnimationContext.endGrouping()
        // A drag is authoritative: nothing is on its way anywhere else.
        forgetPendingPanelResize()
        lastFullSize = panel.frame.size
        // The user's hand outranks content tracking from here on.
        panelSizePreference.record(panel.frame.size)
        vm.panelHasManualSize = true
    }

    /// Latest content-height report from the Live Focus stack (the header
    /// slot + card). Drives the dynamic panel height below.
    private var lastFocusContentHeight: CGFloat = 0

    /// Extra vertical space the panel needs beyond the focus stack. The
    /// stack now INCLUDES the composer and attachment tray (the live view
    /// is one card), so the only thing outside it is the shell's own 8pt
    /// padding above and below.
    private static let focusPanelChrome: CGFloat = 16

    /// Track the panel height to the Live Focus content so the window
    /// grows and shrinks with the answer in realtime. Short implicit
    /// animation per retarget — successive streaming reports land ~lines
    /// apart, so the panel glides instead of stepping. Skipped while a
    /// grip drag is in flight (the user's hand wins) and outside the
    /// hugging layout (fixed-height response mode keeps its behaviour).
    @MainActor
    private func handleFocusContentHeight(_ h: CGFloat) {
        lastFocusContentHeight = h
        // The report arrives from onPreferenceChange, which can fire inside
        // a SwiftUI layout pass — defer the AppKit resize to the next
        // runloop turn. Stale queued applies converge on the same target
        // and no-op via the Δ<2 guard.
        DispatchQueue.main.async { [weak self] in self?.applyFocusPanelHeight() }
    }

    @MainActor
    private func applyFocusPanelHeight() {
        let h = lastFocusContentHeight
        guard h > 0,
              let panel = overlayPanel,
              vm.focusHuggingActive,
              vm.shellStage == .expanded,
              panelSizePreference.manualSize == nil,
              panelResizeBaseFrame == nil else { return }

        let targetH = min(max(h + Self.focusPanelChrome,
                              Self.expandedCompactMinSize.height),
                          Self.expandedSize.height + 80)
        let cur = panel.frame
        guard abs(cur.height - targetH) >= 2 else { return }

        // Top edge pinned — the card and its first line never move; the
        // panel's bottom edge is what glides as text streams in.
        let target = NSRect(x: cur.origin.x,
                            y: cur.maxY - targetH,
                            width: cur.width,
                            height: targetH)
        if CommandLine.arguments.contains("-snapshot") {
            panel.setFrame(target, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(target, display: true)
            }
        }
        // Content tracking owns the frame now, so `animateShellFrame` must not
        // compare its next request against a size that is no longer coming.
        forgetPendingPanelResize()
    }

    // MARK: - Clipboard explain

    func explainClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        // Show overlay if hidden
        if !overlayPanel.isVisible { overlayPanel.orderFrontRegardless() }
        Task { @MainActor in
            vm.showManualInput  = true
            vm.manualInput      = "Explain this: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
            vm.sendToAI()
        }
    }

    // MARK: - Screenshot

    @objc func onCaptureScreenshot() { captureAndAttachScreenshot() }

    func captureAndAttachScreenshot() {
        DispatchQueue.main.async { [self] in
            overlayPanel.alphaValue = 0
        }
        // Wait for the overlay to hide itself, capture via ScreenCaptureKit,
        // restore alpha, and attach the image on the main actor.
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            let img = await self.captureScreen()
            self.overlayPanel.alphaValue = self.vm.opacity
            if let img { self.vm.pendingScreenshot = img }
        }
    }

    /// Capture the screen and ask the AI about it immediately — the
    /// companion to `captureAndAttachScreenshot`, which only stages the
    /// image in the bar for the user to type alongside. When the question
    /// simply IS "what's on my screen" (a coding problem, an error dialog,
    /// a slide), typing anything is friction, so this one sends straight
    /// away.
    func captureAndSendScreenshot() {
        DispatchQueue.main.async { [self] in
            overlayPanel.alphaValue = 0
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            let img = await self.captureScreen()
            self.overlayPanel.alphaValue = self.vm.opacity
            guard let img else {
                // captureScreen swallows the reason; the most common one by
                // far is the permission not being granted yet.
                self.vm.statusMessage = "Error: screen capture failed — check System Settings → Privacy & Security → Screen Recording."
                if !self.overlayPanel.isVisible { self.overlayPanel.orderFrontRegardless() }
                return
            }
            if !self.overlayPanel.isVisible { self.overlayPanel.orderFrontRegardless() }
            self.vm.sendScreenshotToAI(img)
        }
    }

    /// Async capture via ScreenCaptureKit. Full-screen shot of the main
    /// display, excluding no windows. Returns nil on permission denial or
    /// any SCStream error — users see a silent no-op which matches the
    /// previous behaviour.
    private func captureScreen() async -> NSImage? {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width  = Int(display.width)
            cfg.height = Int(display.height)
            cfg.capturesAudio = false
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: cfg
            )
            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        } catch {
            return nil
        }
    }

    @objc private func frontAppChanged(_ n: Notification) {
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastFrontAppPID = app.processIdentifier
        }
    }

    private var anchorUpdateTask: Task<Void, Never>?

    private static let savedOriginDefaultsKey = "MacOverlay.savedPanelOrigin"

    @objc private func panelDidMove(_ n: Notification) {
        anchorUpdateTask?.cancel()
        anchorUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self = self else { return }
            // Only update sidebar order when expanded — no visual change when collapsed.
            if self.vm?.isShellExpanded == true { self.updatePillAnchor() }
            self.persistPanelOrigin()
        }
    }

    private func persistPanelOrigin() {
        guard let panel = overlayPanel else { return }
        let p = panel.frame.origin
        UserDefaults.standard.set([p.x, p.y], forKey: Self.savedOriginDefaultsKey)
    }

    private func restorePanelOrigin() {
        guard let panel = overlayPanel,
              let arr = UserDefaults.standard.array(forKey: Self.savedOriginDefaultsKey) as? [CGFloat],
              arr.count == 2 else { return }
        let saved = NSPoint(x: arr[0], y: arr[1])
        // Only restore if the saved point lies on a currently-connected screen.
        // Otherwise the pill would land on a detached monitor and vanish.
        let onAScreen = NSScreen.screens.contains { $0.frame.contains(saved) }
        guard onAScreen else {
            UserDefaults.standard.removeObject(forKey: Self.savedOriginDefaultsKey)
            return
        }
        // A position saved half below the screen (the old open/close drift)
        // must come back fully visible.
        panel.setFrameOrigin(onScreen(NSRect(origin: saved, size: panel.frame.size)).origin)
    }

    /// Update which screen quadrant the panel is in so the sidebar can flip
    /// its vertical item order. Never repositions the panel.
    @MainActor
    func updatePillAnchor() {
        guard let panel = overlayPanel,
              let screen = panel.screen ?? NSScreen.main,
              let vm else { return }
        let frame  = panel.frame
        let bounds = screen.visibleFrame
        let isTrailing = frame.midX > bounds.midX
        let isBottom   = frame.midY < bounds.midY
        let newAnchor: OverlayViewModel.PillAnchor
        switch (isTrailing, isBottom) {
        case (false, false): newAnchor = .topLeading
        case (true,  false): newAnchor = .topTrailing
        case (false, true):  newAnchor = .bottomLeading
        case (true,  true):  newAnchor = .bottomTrailing
        }
        // Direct set — no animation. Collapsed view doesn't read pillAnchor,
        // and expanded sidebar just reorders instantly (transitions are off).
        vm.pillAnchor = newAnchor
    }

    /// Put the panel back to its default size, discarding any manual resize.
    ///
    /// Manual sizing is sticky on purpose (the panel must not fight the user),
    /// which means a size reached by accident — a stray drag while trying to
    /// move the panel, a double-click caught by the border — used to be
    /// permanent until the app was restarted. This is the way back.
    @MainActor
    func resetPanelSize() {
        panelSizePreference.reset()
        vm.panelHasManualSize = false
        lastFullSize = Self.expandedSize
        // Re-derive the size the current stage would have picked with no
        // manual size in play, so this works in the pill, the bar-only shell
        // and a live focus card alike.
        let cur = overlayPanel?.frame ?? .zero
        let surfaceOpen = vm.primarySurface != nil
        var target = Self.expandedSize
        if vm.shellStage == .pill {
            target = vm.hasPillPopup ? Self.pillWithPopupSize : Self.collapsedSize
        } else if !surfaceOpen {
            target = NSSize(width: Self.expandedSize.width, height: Self.expandedCompactMinSize.height)
        }
        guard let panel = overlayPanel else { return }
        panel.setFrame(NSRect(x: cur.origin.x,
                              y: cur.origin.y + (cur.height - target.height),
                              width: target.width, height: target.height),
                       display: true, animate: true)
        forgetPendingPanelResize()
        refreshResizeCursors()
        // Let the content measurement reassert itself now that the manual
        // override is gone, or a focus card would keep the height it had.
        applyFocusPanelHeight()
    }

    /// MINIMUM panel size — the user can manually resize, but never below
    /// this. Two values: pill (just the brand dot) and expanded (wide enough
    /// for every visible bar element).
    static let pillMinSize             = collapsedSize
    static let expandedCompactMinSize  = NSSize(width: 360, height: 160)
    /// With a surface open the width can't go below the width the layouts
    /// are designed for: narrower, and the setup screen's buttons wrap one
    /// letter per line. Settings used to be the other example here, but it is
    /// its own window now (min 720x520) and this panel minimum cannot clip it.
    static let expandedMinSize         = NSSize(width: 440, height: 420)

    /// The smallest the panel may be right now. Every way of resizing
    /// uses it: stage changes, the resize edges, ⌃⇧ + arrows, and dragging
    /// the panel's edges (`windowWillResize`). It's worked out from the
    /// current screen each time rather than read from `minSize`, which is
    /// only updated on stage and surface changes.
    @MainActor
    func minimumPanelSize(for stage: OverlayViewModel.ShellStage) -> NSSize {
        switch stage {
        case .pill:
            return Self.pillMinSize
        case .expanded:
            guard vm.primarySurface != nil else { return Self.expandedCompactMinSize }
            if vm.primarySurface == .settings { return Self.settingsMinSize }
            // An answer hugs its text, so it can be short, but it's never
            // narrower than the other screens: going back to setup from an
            // answer doesn't resize the panel.
            return vm.focusHuggingActive
                ? NSSize(width: Self.expandedMinSize.width, height: Self.expandedCompactMinSize.height)
                : Self.expandedMinSize
        }
    }

    /// Resize the panel for the given shell stage. Within `.expanded`
    /// the height also adapts to whether a `primarySurface` is open:
    ///   - no surface  → bar-only height (compact)
    ///   - surface set → full height (top card + body + bar)
    /// Anchor: bottom is always pinned, so the bar stays put as the
    /// panel grows or shrinks above it. The pill itself is the same
    /// physical affordance — keeping the bottom edge fixed means the
    /// brand icon doesn't visibly jump as the shell expands or collapses.
    @MainActor
    func animateShellFrame(stage: OverlayViewModel.ShellStage) {
        guard let panel = overlayPanel else { return }
        // A manual size now holds for the whole run: a stage or surface
        // transition keeps the panel where the user put it, instead of
        // handing height control back to content tracking. Content
        // hugging is the default only until the first drag of an edge.
        let cur = panel.frame
        let surfaceOpen = vm.primarySurface != nil
        // Only the live focus card tracks its content's height (so it covers
        // as little of the call as possible); every other screen shares one
        // size, so switching tabs never resizes the panel.
        let responseHugging = stage == .expanded && surfaceOpen && vm.focusHuggingActive
        let minForStage = minimumPanelSize(for: stage)
        panel.minSize = minForStage
        // The size every screen uses: the user's manual size if they dragged
        // one, otherwise `expandedSize`. A screen's minimum may enlarge it
        // without erasing the choice.
        let shared = panelSizePreference.expandedSize(automatic: Self.expandedSize,
                                                      minimum: minForStage)

        var target: NSSize
        switch stage {
        case .pill:
            target = vm.hasPillPopup ? Self.pillWithPopupSize : Self.collapsedSize
        case .expanded:
            if surfaceOpen && responseHugging {
                // Live Focus: the shared width, the content's height (see
                // handleFocusContentHeight); a manual height wins.
                let h: CGFloat
                if let manual = panelSizePreference.manualSize {
                    h = max(manual.height, minForStage.height)
                } else if lastFocusContentHeight > 0 {
                    h = min(max(lastFocusContentHeight + Self.focusPanelChrome,
                                Self.expandedCompactMinSize.height),
                            Self.expandedSize.height + 80)
                } else {
                    h = Self.responseExpandedSize.height
                }
                target = NSSize(width: shared.width, height: h)
            } else if surfaceOpen {
                target = shared
            } else {
                // Home: the bar alone, as wide as the screens it opens.
                target = NSSize(width: shared.width, height: minForStage.height)
            }
        }
        // The resize bands are measured from the panel's size and only exist on
        // an expanded panel, so a stage change moves them even when the frame
        // itself does not move.
        refreshResizeCursors()

        // Response-sized panels are fixed-height and top-anchored: the
        // answer card's top edge stays visually locked, and streamed text
        // scrolls inside the card instead of resizing the native window.
        // The rest of the shell keeps the original bottom anchor so the
        // compact bar/pill still expands from its resting affordance.
        // Top-pinning applies only within the expanded shell. Opening from the
        // pill pins the bottom, like collapsing does — mixing the two moved
        // the pill down by (panel height − 64) on every open/close, until it
        // sat below the screen.
        let newX = cur.origin.x
        let curIsExpandedLayout = cur.size.width >= Self.expandedCompactMinSize.width
        let newY: CGFloat = responseHugging && curIsExpandedLayout
            ? cur.maxY - target.height
            : cur.origin.y
        // AppKit runs `constrainFrameRect` for its own moves only, not for
        // `setFrame`, so the frame is kept on screen here.
        let target_ = onScreen(NSRect(x: newX, y: newY, width: target.width, height: target.height))
        // `cur` is where the panel is *now*, which during the 0.18s window
        // animation below is still the old size. A second request for the size
        // already on its way would therefore look already satisfied and return
        // without animating — and the move that was in flight would finish and
        // leave the panel at the old size while `shellStage` says expanded. A
        // collapsed dot with an expanded shell is the visible result, and it
        // needs two requests in one animation to happen, which is why it read
        // as flaky. Compare against the frame the panel is heading for.
        let settled = panelResizeTarget ?? cur
        if abs(settled.width - target_.width) < 1,
           abs(settled.height - target_.height) < 1,
           abs(settled.origin.x - target_.origin.x) < 1,
           abs(settled.origin.y - target_.origin.y) < 1 {
            return
        }

        // Drive the panel resize through NSAnimationContext so the
        // duration / curve match the SwiftUI spring inside the panel.
        // `setFrame(animate: true)` uses NSWindow.animationResizeTime
        // (proportional to delta) which runs slower on big size changes
        // and visibly desyncs from SwiftUI — content jitters because the
        // panel is still resizing while SwiftUI has already settled.

        // A screenshot harness run is unattended: nothing activates the app, and
        // a window-frame ANIMATION started in that state does not run at all —
        // no intermediate frames, no completion handler, the frame simply stays
        // where it was. The shell was left standing at 80x64 while the stage
        // said expanded, and the shortcut above then read that stranded target
        // as "already on its way" and declined to ask again. Apply the frame
        // outright when there is nobody to animate for.
        if CommandLine.arguments.contains("-snapshot") {
            panel.setFrame(target_, display: true)
            panelResizeTarget = nil
            return
        }

        panelResizeTarget = target_
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(target_, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Stand down only if this is still the move we started. A
                // newer request has taken over the target, and clearing it
                // here would make the next comparison fall back to
                // `panel.frame` mid-flight — the bug above, restored.
                guard let self, self.panelResizeTarget == target_ else { return }
                self.panelResizeTarget = nil
            }
        }
    }

    /// Stop trusting a resize that is still animating, because something else
    /// has just moved the panel. The drag below and content-height tracking
    /// both set the frame directly rather than through `animateShellFrame`,
    /// and a stale target would make its next request look already satisfied.
    @MainActor
    private func forgetPendingPanelResize() {
        panelResizeTarget = nil
    }

    // Screen share protection is handled by NSWindow.installScreenShareProtection()
    // called at launch — see the extension below AppDelegate.

    /// Apply the screen-share visibility toggle live. Updates the global
    /// gate the swizzle reads, then re-stamps the sharingType on the
    /// overlay panel and every other window currently on screen (popovers,
    /// menus) so the change takes effect immediately, not just on the next
    /// time a window is shown.
    func applyScreenShareVisibility(_ invisible: Bool) {
        NSWindow.screenShareInvisible = invisible
        let type = NSWindow.desiredSharingType
        overlayPanel?.sharingType = type
        for window in NSApp.windows {
            // The troubleshooting window exists to be photographed, so it is
            // deliberately never excluded — including here, or toggling the
            // privacy setting would quietly put it back out of reach.
            guard !(window is InspectorWindow) else { continue }
            window.sharingType = type
        }
    }

    // MARK: - Menu actions

    @objc func toggleOverlay() {
        let showing = overlayPanel.isVisible
        if showing { overlayPanel.orderOut(nil) }
        else       { overlayPanel.orderFrontRegardless() }
        // The detached browser window goes with it. ⌃⌥Space is the key you
        // hit when someone walks up; leaving a browser on screen because it
        // happens to live in its own window would defeat the whole point.
        //
        // `assumeIsolated` rather than a `Task`: this method already drives
        // AppKit directly, so it only ever runs on the main thread (the
        // hotkey path hops through `DispatchQueue.main.async` first), and
        // hopping to a later runloop turn would let the two windows
        // disappear one frame apart.
        MainActor.assumeIsolated { BrowserWindow.shared.setVisible(!showing) }
    }

    @objc func resetPosition() {
        guard let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame, pf = overlayPanel.frame
        overlayPanel.setFrameOrigin(NSPoint(x: sf.midX - pf.width / 2, y: sf.maxY - pf.height - 20))
    }

    /// "Close" in the ⋯ menu: hide everything but keep running in
    /// the menu bar, so calls are still noticed. Quitting for real lives in
    /// the menu-bar menu.
    @objc func closeToMenuBar() {
        overlayPanel.orderOut(nil)
        MainActor.assumeIsolated { BrowserWindow.shared.setVisible(false) }
    }

    // MARK: - Troubleshooting

    /// A plain window holding the same interface as the overlay.
    ///
    /// The overlay is a floating panel that sits above every other window and
    /// hides itself from screen sharing, which makes it impossible to
    /// photograph and impossible to show anyone. When something is laid out
    /// wrongly there is then no way to see it or describe it. This is that
    /// window: ordinary, focusable, screenshot-able, and never hidden from
    /// screen capture.
    final class InspectorWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private var inspector: InspectorWindow?

    /// Shows or hides the troubleshooting window. Safe to call from anywhere.
    @objc func toggleInspector() {
        MainActor.assumeIsolated {
            if let w = inspector, w.isVisible {
                w.orderOut(nil)
                return
            }
            let w = inspector ?? makeInspector()
            inspector = w
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func makeInspector() -> InspectorWindow {
        let size = NSSize(width: 480, height: 760)
        let w = InspectorWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        w.title = "TheCloser — troubleshooting"
        w.titlebarAppearsTransparent = false
        w.isReleasedWhenClosed = false
        w.isOpaque = true
        w.backgroundColor = .windowBackgroundColor
        // The overlay hides itself from screen sharing so it does not appear
        // in the other person's view. That is right for an interview and
        // wrong for a bug report, so this window is explicitly visible to
        // capture — which is the entire reason it exists.
        w.sharingType = .readWrite
        w.setFrameAutosaveName("TheCloserInspector")

        let root = InspectorRootView(
            onQuit: { NSApp.terminate(nil) },
            onSnapshot: { [weak self] in
                MainActor.assumeIsolated { self?.saveSnapshots(to: nil) ?? [] }
            },
            onClose: { [weak w] in w?.orderOut(nil) })
        let host = NSHostingController(rootView: root)
        w.contentViewController = host
        // Set explicitly after installing the controller. Without this the
        // window opens at `contentMinSize` rather than at the size asked for,
        // because the hosting controller's fitting size wins.
        w.contentMinSize = NSSize(width: 400, height: 560)
        w.setContentSize(size)
        return w
    }

    // MARK: - Settings

    /// Settings open inside the overlay (`PrimarySurface.settings`), at the
    /// same size as every other screen; the overlay is brought back if hidden.
    @objc func showPreferences() {
        MainActor.assumeIsolated {
            if !overlayPanel.isVisible { overlayPanel.orderFrontRegardless() }
            vm.openSettings()
        }
    }

    // MARK: - Pictures of the app

    /// Renders the app's own windows to PNGs and returns the paths written.
    ///
    /// `cacheDisplay(in:to:)` asks the views to draw themselves into a bitmap
    /// rather than reading the screen, so this needs **no Screen Recording
    /// permission**. That is the whole point. The overlay floats above every
    /// window and hides itself from screen sharing, so it is not merely hard
    /// to photograph — the capture APIs return a hole where it is. Anyone
    /// reporting a layout bug then has nothing to show. Now the app can show
    /// itself.
    @discardableResult
    @MainActor
    func saveSnapshots(to directory: URL? = nil) -> [URL] {
        let dir = directory ?? Self.snapshotDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var views: [(String, NSView)] = []
        if let v = overlayPanel?.contentView, v.bounds.width > 1, v.bounds.height > 1 {
            views.append(("overlay", v))
        }
        if let w = inspector, w.isVisible,
           let v = w.contentView, v.bounds.width > 1, v.bounds.height > 1 {
            views.append(("inspector", v))
        }
        // Sheets (prep setup, minutes, editors) are separate attached
        // windows, so the panel's contentView never contains them — without
        // this they cannot be photographed at all.
        if let sheet = overlayPanel?.attachedSheet,
           let v = sheet.contentView, v.bounds.width > 1, v.bounds.height > 1 {
            // Sheet windows are vibrant and inherit their look from whatever
            // is behind them, which a detached bitmap draw doesn't have —
            // force the app's dark aqua so the picture matches the screen.
            sheet.appearance = NSAppearance(named: .darkAqua)
            views.append(("sheet", v))
        }

        let stamp = Self.snapshotStamp()
        var written: [URL] = []
        for (name, view) in views {
            // Let any pending layout land before drawing, or the picture
            // shows the previous frame.
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let url = dir.appendingPathComponent("thecloser-\(name)-\(stamp).png")
            guard (try? png.write(to: url)) != nil else { continue }
            written.append(url)
        }
        lastSnapshotURL = written.first
        return written
    }

    /// Where snapshots go when no directory is given. Desktop, because the
    /// next step is always dragging the file into a message.
    private static var snapshotDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    private static func snapshotStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    /// Writes the pictures and selects them in Finder, so they can be dragged
    /// straight into a message. Beeps if there was nothing to draw.
    @objc func saveSnapshotsAndReveal() {
        MainActor.assumeIsolated {
            let urls = saveSnapshots(to: nil)
            guard !urls.isEmpty else { NSSound.beep(); return }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    /// The most recent snapshot path, for the troubleshooting window to show.
    @MainActor private(set) var lastSnapshotURL: URL?

    /// Prints the panel's geometry and its view tree, to stdout.
    ///
    /// A debug aid for alignment problems: a picture shows that something is
    /// off, these numbers say by how much and in which coordinate space —
    /// which is the difference between guessing at padding and fixing it.
    @MainActor
    func viewGeometryDump() -> [String] {
        guard let panel = overlayPanel, let content = panel.contentView else {
            return ["GEOM no panel"]
        }
        var out: [String] = []
        out.append("stage=\(vm.shellStage.rawValue) surface=\(vm.primarySurface?.rawValue ?? "none")")
        out.append("visibleFrame=\(NSScreen.main?.visibleFrame.debugDescription ?? "?")")
        out.append("panel.frame=\(panel.frame)")
        out.append("content.frame=\(content.frame) bounds=\(content.bounds)")
        out.append("panel.minSize=\(panel.minSize) scale=\(panel.backingScaleFactor)")
        out.append("lastFullSize=\(lastFullSize) manualSize=\(String(describing: panelSizePreference.manualSize))")

        func walk(_ v: NSView, _ depth: Int) {
            guard depth <= 4 else { return }
            let indent = String(repeating: "  ", count: depth)
            out.append("\(indent)\(String(describing: type(of: v))) frame=\(v.frame)")
            for sub in v.subviews { walk(sub, depth + 1) }
        }
        walk(content, 1)
        return out
    }

    /// Drags each border of the panel and prints the frame it produced.
    ///
    /// `--args -snapshot <dir> -surface interview -resizeprobe`. This exists
    /// because the pointer cannot be driven from outside the process — posting
    /// events at the session tap needs Accessibility, which is not granted —
    /// so a change to how the border is grabbed is otherwise unverifiable from
    /// a shell. Posting into this app's own queue exercises the real path:
    /// event → local monitor → `handlePanelResize` → `setFrame`.
    ///
    /// Events are posted one per run-loop turn so each is created against the
    /// frame the previous one produced; batched, they would all carry the
    /// pre-resize window frame and report inflated deltas.
    ///
    /// `NSEvent.mouseEvent`'s location is in the WINDOW's coordinates when a
    /// windowNumber is given, not the screen's — the first run of this passed
    /// screen points and only two borders resized.
    @MainActor
    func probePanelResize() {
        guard let panel = overlayPanel else { return }
        print("PROBE stage=\(vm.shellStage) surface=\(vm.primarySurface?.rawValue ?? "none") frame=\(panel.frame)")

        func post(_ type: NSEvent.EventType, _ location: NSPoint) {
            guard let e = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ) else {
                print("PROBE could not build \(type)")
                return
            }
            NSApp.postEvent(e, atStart: false)
        }

        let originalFrame = panel.frame
        let originalPreference = panelSizePreference
        let originalFullSize = lastFullSize
        let originalSurface = vm.primarySurface
        let originalStage = vm.shellStage
        let args = CommandLine.arguments
        let directory = args.firstIndex(of: "-snapshot").flatMap { i in
            args.indices.contains(i + 1) && !args[i + 1].hasPrefix("-")
                ? URL(fileURLWithPath: args[i + 1]) : nil
        } ?? Self.snapshotDirectory

        func photograph(_ name: String) {
            let dir = directory.appendingPathComponent(name)
            _ = self.saveSnapshots(to: dir)
            try? self.viewGeometryDump().joined(separator: "\n")
                .write(to: dir.appendingPathComponent("geometry.txt"), atomically: true, encoding: .utf8)
        }

        // Check all surfaces at a real manual minimum, then close/reopen.
        // This caught sizes being overwritten by tab defaults and pill frames.
        let surfaces = OverlayViewModel.PrimarySurface.allCases
        func checkSurface(_ index: Int) {
            guard index < surfaces.count else {
                self.vm.shellStage = .pill
                self.animateShellFrame(stage: .pill)
                self.vm.primarySurface = originalSurface
                self.vm.shellStage = .expanded
                self.animateShellFrame(stage: .expanded)
                print("PROBE reopen \(panel.frame.size == Self.expandedMinSize ? "PASS" : "FAIL") frame=\(panel.frame)")
                self.panelSizePreference = originalPreference
                self.vm.panelHasManualSize = originalPreference.manualSize != nil
                self.lastFullSize = originalFullSize
                self.vm.primarySurface = originalSurface
                self.vm.shellStage = originalStage
                self.animateShellFrame(stage: originalStage)
                panel.setFrame(originalFrame, display: true)
                print("PROBE done")
                return
            }
            let surface = surfaces[index]
            self.vm.primarySurface = surface
            self.animateShellFrame(stage: .expanded)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                // Settings can't go below its own minimum.
                let expected = surface == .settings ? Self.settingsMinSize : Self.expandedMinSize
                print("PROBE surface=\(surface.rawValue) \(panel.frame.size == expected ? "PASS" : "FAIL") frame=\(panel.frame)")
                photograph("minimum-" + surface.rawValue)
                checkSurface(index + 1)
            }
        }

        let w = panel.frame.width, h = panel.frame.height
        let cases: [(String, NSPoint, NSPoint, PanelResizeEdge?)] = [
            ("trailing", NSPoint(x: w - 5, y: h / 2), NSPoint(x: 100, y: 0), .trailing),
            ("leading", NSPoint(x: 5, y: h / 2), NSPoint(x: -100, y: 0), .leading),
            ("top", NSPoint(x: w / 2, y: h - 5), NSPoint(x: 0, y: 100), .top),
            ("bottom", NSPoint(x: w / 2, y: 5), NSPoint(x: 0, y: -100), .bottom),
            ("topLeading", NSPoint(x: 5, y: h - 5), NSPoint(x: -100, y: 100), .topLeading),
            ("topTrailing", NSPoint(x: w - 5, y: h - 5), NSPoint(x: 100, y: 100), .topTrailing),
            ("bottomLeading", NSPoint(x: 5, y: 5), NSPoint(x: -100, y: -100), .bottomLeading),
            ("bottomTrailing", NSPoint(x: w - 5, y: 5), NSPoint(x: 100, y: -100), .bottomTrailing),
            ("interior", NSPoint(x: w / 2, y: h / 2), NSPoint(x: 100, y: 0), nil),
        ]

        func run(_ index: Int) {
            guard index < cases.count else {
                self.panelSizePreference.record(Self.expandedMinSize)
                self.vm.panelHasManualSize = true
                checkSurface(0)
                return
            }
            let (name, start, delta, edge) = cases[index]
            let before = panel.frame
            let anchor = NSPoint(x: before.minX + start.x, y: before.minY + start.y)
            func drag(_ fraction: CGFloat, type: NSEvent.EventType) {
                post(type, NSPoint(x: anchor.x + delta.x * fraction - panel.frame.minX,
                                   y: anchor.y + delta.y * fraction - panel.frame.minY))
            }
            let requested = edge?.resizedFrame(from: before, dx: delta.x, dy: -delta.y,
                                                minimum: self.minimumPanelSize(for: self.vm.shellStage)) ?? before
            let expected = panel.constrainFrameRect(requested, to: panel.screen)
            post(.leftMouseDown, start)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                drag(0.5, type: .leftMouseDragged)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    drag(1, type: .leftMouseDragged)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        drag(1, type: .leftMouseUp)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            print("PROBE \(name) \(panel.frame == expected ? "PASS" : "FAIL") expected=\(expected) actual=\(panel.frame)")
                            photograph("edge-" + name)
                            panel.setFrame(before, display: true)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { run(index + 1) }
                        }
                    }
                }
            }
        }
        run(0)
    }

    /// Every window this app has on screen, with the level and alpha that
    /// decide what is actually in front.
    ///
    /// Added while chasing a border that would not resize. It earned its place
    /// immediately: it reported `level=3` for a panel set to `.statusBar + 1`,
    /// because `isFloatingPanel = true` was being applied after the level and
    /// forcing `.floating`.
    ///
    /// It does NOT try to work out which window a press at a given point would
    /// reach. `windowNumber(at:belowWindowWithWindowNumber:)` looks tidier than
    /// it behaves — its search starts below the window you name, so passing 0
    /// answered with windows underneath the panel and sent the investigation
    /// after the wrong culprit entirely. A press can also be taken by a view
    /// inside the shell before any window-level question about it is
    /// meaningful, which is exactly how the border came to be unreachable while
    /// this dump looked healthy.
    @MainActor
    func dumpWindowFrontage() -> [String] {
        guard let panel = overlayPanel else { return ["FRONTAGE no panel"] }
        var out: [String] = []
        out.append("FRONTAGE panel #\(panel.windowNumber) level=\(panel.level.rawValue) "
            + "(expect \(NSWindow.Level.statusBar.rawValue + 1)) "
            + "alpha=\(panel.alphaValue) visible=\(panel.isVisible) frame=\(panel.frame)")
        for w in NSApp.orderedWindows {
            out.append("FRONTAGE window #\(w.windowNumber) "
                + "\(String(describing: type(of: w))) level=\(w.level.rawValue) "
                + "alpha=\(w.alphaValue) visible=\(w.isVisible) "
                + "ignoresMouse=\(w.ignoresMouseEvents) frame=\(w.frame)")
        }
        // The resize cursor cannot be photographed, so report the regions the
        // window was told to use instead of a claim that they work. A cursor
        // rect is not observable from outside the process, which is why this is
        // the only way to see them without relying on the pointer.
        if let hosting = overlayHostingView {
            let bands = currentResizeBands()
            out.append("FRONTAGE cursor bands: \(bands.count) "
                + "(stage=\(vm.shellStage.rawValue) flipped=\(hosting.isFlipped) "
                + "bounds=\(hosting.bounds.size))")
            for (edge, rect) in bands {
                out.append("FRONTAGE   \(edge) \(rect)")
            }
        } else {
            out.append("FRONTAGE cursor bands: no hosting view")
        }
        return out
    }

    func showOverlay() {
        overlayPanel.orderFrontRegardless()
        MainActor.assumeIsolated { BrowserWindow.shared.setVisible(true) }
    }

    /// Opening the app while it's already running (Finder, Spotlight, the
    /// Dock's Applications folder) brings the overlay back. The app has no
    /// Dock icon or windows macOS knows to show, so without this a closed or
    /// hidden overlay made the app look like it wouldn't open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showOverlay()
        return false
    }

    /// Triggers the Screen Recording prompt at most once per install.
    ///
    /// `CGPreflightScreenCaptureAccess` answers without prompting, so a
    /// granted permission short-circuits and the system dialog never appears
    /// again. Once we have asked and the answer is still "not granted", we
    /// stop: the user has the row in System Settings → Privacy & Security →
    /// Screen Recording, and re-asking every launch does not help.
    private func prewarmScreenRecordingIfNeeded() async {
        guard !CGPreflightScreenCaptureAccess() else { return }

        let askedKey = "screenRecording.promptedOnce"
        guard !UserDefaults.standard.bool(forKey: askedKey) else {
            // Already asked and still not granted — don't nag.
            await MainActor.run { self.vm.needsScreenRecordingPermission = true }
            return
        }
        UserDefaults.standard.set(true, forKey: askedKey)
        await MainActor.run { self.vm.needsScreenRecordingPermission = true }
        _ = try? await SCShareableContent.current
    }

    private func startInterviewFromCallPrompt() {
        showOverlay()
        MainActor.assumeIsolated { vm.startInterviewFromCallPrompt() }
    }

    /// The menu-bar icon shows only while idle: the menu bar is part of
    /// every screen share, so it hides during calls and interviews.
    private func updateMenuBarVisibility() {
        MainActor.assumeIsolated { menuBar?.setHidden(isOnCall || vm.isRecording) }
    }

    /// Quit cleanly on SIGTERM instead of dying where we stand. The default
    /// SIGTERM disposition would skip applicationWillTerminate — losing
    /// whatever the session store hasn't flushed yet.
    private func installTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigtermSource = source
    }

    /// Show the Accessibility permission dialog the first time the user
    /// actually invokes dictation. Idempotent: subsequent invocations
    /// short-circuit once the system reports trust.
    private var didPromptForAccessibility = false
    private func ensureAccessibilityPrompted() {
        if AXIsProcessTrusted() { return }
        if didPromptForAccessibility { return }
        didPromptForAccessibility = true
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The session store debounces token-driven writes; flush whatever
        // hasn't been written yet so a mid-stream quit doesn't lose
        // the last few chunks.
        SessionStore.shared.flushPendingPersist()
    }

    deinit {
        if let m = localKeyMonitor    { NSEvent.removeMonitor(m) }
        if let m = optionKeyMonitor   { NSEvent.removeMonitor(m) }
        if let m = localFlagsMonitor  { NSEvent.removeMonitor(m) }
        if let m = panelResizeMonitor { NSEvent.removeMonitor(m) }
        HotkeyManager.shared.unregister()
        dictationManager?.stop()
    }
}

// MARK: - NSWindow screen-share protection (swizzle)
//
// Swizzling the three "order on screen" entry points guarantees that EVERY
// window this app creates — overlay panel, SwiftUI popovers, NSMenu dropdowns,
// tooltips, sheets — has sharingType = .none before it ever appears on screen.
// Notifications and timers fire too late (after capture can already occur);
// swizzling runs synchronously in the same call-stack as the window appearing.

import ObjectiveC.runtime

extension NSWindow {

    /// Global gate for the order-front swizzle. When true (default) every
    /// window is forced to `.none` (excluded from screen capture) right
    /// before it appears; when false, windows use `.readOnly` and ARE
    /// visible to screen shares. AppDelegate seeds this from the persisted
    /// user setting at launch and updates it when the toggle flips.
    static var screenShareInvisible = true

    /// The sharing type implied by the current `screenShareInvisible` gate.
    static var desiredSharingType: NSWindow.SharingType {
        screenShareInvisible ? .none : .readOnly
    }

    static func installScreenShareProtection() {
        let pairs: [(Selector, Selector)] = [
            (#selector(NSWindow.orderFront(_:)),
             #selector(NSWindow._sp_orderFront(_:))),
            (#selector(NSWindow.orderFrontRegardless),
             #selector(NSWindow._sp_orderFrontRegardless)),
            (#selector(NSWindow.makeKeyAndOrderFront(_:)),
             #selector(NSWindow._sp_makeKeyAndOrderFront(_:))),
            // Sheets and popovers never pass through the three above; a probe
            // of an alert sheet and a popover found both capturable.
            (#selector(NSWindow.order(_:relativeTo:)),
             #selector(NSWindow._sp_order(_:relativeTo:))),
        ]
        for (orig, swiz) in pairs {
            guard
                let origMethod = class_getInstanceMethod(NSWindow.self, orig),
                let swizMethod = class_getInstanceMethod(NSWindow.self, swiz)
            else { continue }
            method_exchangeImplementations(origMethod, swizMethod)
        }
    }

    @objc func _sp_orderFront(_ sender: Any?) {
        sharingType = NSWindow.desiredSharingType
        _sp_orderFront(sender)            // calls original after swap
    }

    @objc func _sp_orderFrontRegardless() {
        sharingType = NSWindow.desiredSharingType
        _sp_orderFrontRegardless()        // calls original after swap
    }

    @objc func _sp_makeKeyAndOrderFront(_ sender: Any?) {
        sharingType = NSWindow.desiredSharingType
        _sp_makeKeyAndOrderFront(sender)  // calls original after swap
    }

    @objc func _sp_order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out { sharingType = NSWindow.desiredSharingType }
        _sp_order(place, relativeTo: otherWin)  // calls original after swap
    }
}

// MARK: - Resizing by the panel's edges

extension AppDelegate: NSWindowDelegate {
    /// Dragging an edge of the panel. AppKit doesn't reliably hold a
    /// borderless panel to `minSize` here, which let it be dragged narrow
    /// enough to break every layout, so the minimum is applied directly.
    ///
    /// The pill is pinned outright instead of clamped: its window is
    /// deliberately the same size as the visible dot, so letting it grow
    /// would leave a transparent margin that swallows clicks aimed at the
    /// app underneath — the one thing a collapsed overlay must never do.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === overlayPanel else { return frameSize }
        return MainActor.assumeIsolated {
            let minimum = minimumPanelSize(for: vm.shellStage)
            if vm.shellStage == .pill {
                return vm.hasPillPopup ? Self.pillWithPopupSize : Self.collapsedSize
            }
            return NSSize(width: max(frameSize.width, minimum.width),
                          height: max(frameSize.height, minimum.height))
        }
    }
}
