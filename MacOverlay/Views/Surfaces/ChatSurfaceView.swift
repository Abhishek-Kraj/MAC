import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Default primary surface. Shows the active session as chat bubbles with
/// live transcription pinned at top while recording. Empty state offers
/// mode-specific starters so the user knows what to do.
struct ChatSurfaceView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var isDropTargeted = false
    /// Hover over the Live Focus area — reveals the Copy/Retry/model row.
    @State private var focusHovering = false
    /// Measured height of the focus answer content, so the card hugs it.
    @State private var focusContentHeight: CGFloat = 0
    /// How many Q&A pairs back from the latest the focus view is showing.
    /// 0 = live pair; the ‹ › arrows step through history and any new
    /// question snaps it back to 0.
    @State private var focusPairOffset = 0
    /// Whether the transcript strip's drop-down is open, showing every
    /// previous question with a per-row copy button.
    @State private var transcriptExpanded = false
    /// Measured height of the transcript-history rows so the drop-down
    /// hugs a short history instead of claiming its full cap.
    @State private var historyContentHeight: CGFloat = 0

    var body: some View {
        @Bindable var vm = vm
        let session = vm.sessionStore.activeSession
        VStack(spacing: 0) {
            content(session: session)
        }
            .overlay {
                if isDropTargeted {
                    dropOverlay
                }
            }
            .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: Design.Radius.lg)
            .stroke(Design.Accent.brand, style: StrokeStyle(lineWidth: 2, dash: [6]))
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.lg)
                    .fill(Design.Accent.brand.opacity(0.08))
            )
            .overlay {
                VStack(spacing: Design.Space.sm) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 26, weight: .medium))
                    Text("Drop to attach")
                        .font(Design.Font.title)
                    Text("PDF · DOCX · RTF · TXT · MD · image")
                        .font(Design.Font.small)
                        .foregroundColor(Design.Ink.secondary)
                }
                .foregroundColor(Design.Accent.brand)
            }
            .padding(Design.Space.sm)
            .allowsHitTesting(false)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // Files on disk arrive as URLs
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    attachDroppedFile(url: url)
                }
            }
            return true
        }

        // In-memory image drops (e.g. from Preview, Photos)
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { img, _ in
                guard let image = img as? NSImage else { return }
                DispatchQueue.main.async {
                    vm.pendingScreenshot = image
                }
            }
            return true
        }
        return false
    }

    private func attachDroppedFile(url: URL) {
        let ext = url.pathExtension.lowercased()

        // Images → pending screenshot
        if ["png", "jpg", "jpeg", "gif", "tiff", "bmp", "heic"].contains(ext) {
            if let img = NSImage(contentsOf: url) {
                vm.pendingScreenshot = img
            } else {
                vm.statusMessage = "Could not read image"
            }
            return
        }

        // Documents → extract text, attach as a chip. The full extracted
        // text rides along to the AI on send; only the file name shows in
        // the chat bubble (and as a pending chip in the input bar).
        if ResumeImporter.supportedExtensions.contains(ext) {
            do {
                let text = try ResumeImporter.importFile(url: url)
                let name = url.lastPathComponent
                vm.showManualInput = true
                vm.pendingAttachments.append(
                    OverlayViewModel.PendingAttachment(name: name, extractedText: text)
                )
            } catch {
                vm.statusMessage = "Error reading \(url.lastPathComponent): \(error.localizedDescription)"
            }
            return
        }

        vm.statusMessage = "Unsupported file type: .\(ext)"
    }

    @ViewBuilder
    private func content(session: ChatSession) -> some View {
        VStack(spacing: 0) {
            if (vm.isRecording || vm.isInterviewSession || !vm.transcription.isEmpty)
                && (vm.showLiveTranscript || !vm.isInterviewSession) {
                liveTranscriptStrip
                Divider().opacity(0.4)
            }

            if !vm.peerMessage.isEmpty {
                PeerMessagePanelView()
                Divider().opacity(0.4)
            }

            // Always show error-shaped status messages inline so the user
            // sees e.g. missing permissions or key setup issues. Regular
            // "Recording" / "Starting..." status is suppressed when recording
            // so it doesn't duplicate the live strip.
            if !vm.statusMessage.isEmpty
                && (vm.statusMessage.hasPrefix("Error")
                    || vm.statusMessage.hasPrefix("Screen Recording")
                    || (!vm.isRecording && !vm.isInterviewSession && vm.transcription.isEmpty)) {
                StatusRowView()
                Divider().opacity(0.4)
            }

            if vm.isRegularCallSession && !vm.isInterviewTextOnly {
                // A call is not a quiz. The interview live view is built
                // around discrete question→answer pairs with a ‹ n/n ›
                // pager — correct when someone asks you one question at a
                // time, wrong for a conversation, which is why a call kept
                // arriving as "question, answer" instead of a transcript
                // that grows as people talk. A call shows the running
                // transcript instead.
                liveCallTranscript(session: session)
            } else if vm.isInterviewSession && !vm.isInterviewTextOnly && vm.interviewFocusMode {
                // Live Focus: during a live interview only the current
                // exchange matters — the full conversation stays one
                // toggle away (list button on the strip).
                liveFocusView(session: session)
            } else if session.turns.isEmpty && !vm.isSendingToAI && vm.aiResponse.isEmpty {
                if offersResumeInsteadOfStarters(session: session) {
                    // Empty session that's still resumable (a previously-
                    // started interview / call that never got a message).
                    // Replace the starter cards with the continue
                    // affordance — the cards don't apply once a session
                    // has a kind tied to a live flow.
                    resumableEmptyState(session: session)
                } else {
                    emptyState
                }
            } else {
                conversationView(session: session)
            }
        }
    }

    // MARK: - Live call (continuous transcript)

    /// The Regular call live view: one growing transcript.
    ///
    /// Deliberately NOT the interview's one-pair-at-a-time card. In a call
    /// nobody is quizzing the user — people talk over each other, back off,
    /// change the subject, and the useful thing on screen is simply the
    /// conversation so far, newest at the bottom, with whatever the assistant
    /// said sitting under the line that prompted it. It follows people
    /// talking, rather than asking them to page through a Q&A deck.
    ///
    /// The user's own speech is included and labelled YOU: on a call you are
    /// half the conversation, and seeing your own words back is how you catch
    /// the ASR getting a name wrong before it reaches your notes.
    private func liveCallTranscript(session: ChatSession) -> some View {
        let liveThem = vm.transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveYou  = (vm.isSplitCapture ? vm.liveYourSpeech : "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if session.turns.isEmpty && liveThem.isEmpty && liveYou.isEmpty {
                        callWaitingState
                    }

                    ForEach(session.turns) { turn in
                        if turn.role == .user {
                            // A spoken question, in the same lane styling the
                            // strip uses, so the card reads as one transcript
                            // with the strip rather than two different UIs.
                            laneLine("THEM", turn.content, primary: true)
                                .padding(.horizontal, 22)
                                .padding(.top, 12)
                                .padding(.bottom, 2)
                        } else {
                            callAnswer(turn)
                        }
                    }

                    // Anything still being spoken right now, so the
                    // transcript visibly continues rather than freezing
                    // between turns.
                    if !liveThem.isEmpty {
                        laneLine("THEM", liveThem, primary: true)
                            .padding(.horizontal, 22)
                            .padding(.top, 12)
                            .padding(.bottom, 2)
                    }
                    if !liveYou.isEmpty {
                        laneLine("YOU", liveYou, primary: false)
                            .padding(.horizontal, 22)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                    }

                    Color.clear.frame(height: 1).id("call-bottom")
                }
                .padding(.bottom, 14)
                .background(GeometryReader { g in
                    Color.clear.preference(key: FocusHeightKey.self, value: g.size.height)
                })
            }
            .hiddenScrollGutter()
            .onPreferenceChange(FocusHeightKey.self) { callContentHeight = $0 }
            // Hug the transcript up to a cap, then scroll — pinned to the
            // newest line, which is the only one that matters while talking.
            .frame(height: min(max(callContentHeight, 56), Self.callTranscriptMaxHeight),
                   alignment: .top)
            .onAppear { proxy.scrollTo("call-bottom", anchor: .bottom) }
            .onChange(of: session.turns.count) { _, _ in
                proxy.scrollTo("call-bottom", anchor: .bottom)
            }
            // Follow the live partials, but not on every character — a
            // coarse bucket keeps the scroll from chasing a layout that
            // hasn't settled.
            .onChange(of: (liveThem.count + liveYou.count) / 32) { _, _ in
                proxy.scrollTo("call-bottom", anchor: .bottom)
            }
            .animation(vm.isUserResizingPanel ? nil : .easeOut(duration: 0.18),
                       value: callContentHeight)
        }
    }

    /// Cap on the call transcript before it starts scrolling.
    private static let callTranscriptMaxHeight: CGFloat = 460

    @State private var callContentHeight: CGFloat = 0

    /// One assistant answer inside the call transcript. Indented and quieter
    /// than the transcript itself so the two are never confused — the user
    /// reads the conversation, and glances at what the assistant made of it.
    private func callAnswer(_ turn: ChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Labelled, inset and quieter than the transcript. Unlabelled
            // bullets directly under a transcript read as more of what the
            // person said — and on a call the whole point is telling "them"
            // and "the assistant" apart at a glance.
            // The label sits ABOVE the answer rather than in a narrow left column:
                // lane labels are 28pt wide because they hold two letters, and
                // "Assistant" does not fit there — it wrapped to "Assis /
                // tant". Same visual grammar, sized for its content.
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 8, weight: .semibold))
                    Text("Assistant")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(Design.Ink.tertiary)
                .padding(.top, 2)

            if vm.isStreaming(turnID: turn.id) && turn.content.isEmpty {
                StreamingPlaceholderRow()
                    .frame(height: Self.placeholderRowHeight)
            } else {
                MarkdownResponseView(text: turn.content,
                                     baseSize: 12.5 * vm.textScale,
                                     codeSize: 10 * vm.textScale)
            }
            FocusCopyButton(text: turn.content)
                .opacity(focusHovering ? 1 : 0.55)
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A faint wash rather than a hard edge: it groups the assistant's
        // words without drawing a second card inside the transcript.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Design.Surface.previewFill.opacity(0.35))
                .padding(.horizontal, 14)
        )
    }

    /// Before anyone has said anything on a live call: say what is happening,
    /// instead of the interview's "waiting for the first question" — nothing
    /// was asked, and nothing is being waited for.
    private var callWaitingState: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Design.Ink.tertiary)
            Text("Listening")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Design.Ink.secondary)
            Text("The conversation appears here as it's spoken.")
                .font(.caption2)
                .foregroundColor(Design.Ink.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.vertical, 26)
    }

    // MARK: - Live Focus (interview)

    /// One question + its answer, as the focus view shows them.
    private struct QAPair {
        let question: ChatTurn
        let answer: ChatTurn?
    }

    private func qaPairs(in session: ChatSession) -> [QAPair] {
        var out: [QAPair] = []
        var i = 0
        let turns = session.turns
        while i < turns.count {
            if turns[i].role == .user {
                if i + 1 < turns.count, turns[i + 1].role == .assistant {
                    out.append(QAPair(question: turns[i], answer: turns[i + 1]))
                    i += 2
                } else {
                    out.append(QAPair(question: turns[i], answer: nil))
                    i += 1
                }
            } else {
                i += 1
            }
        }
        return out
    }

    /// Focused live-interview layout: one Q&A at a time, with ‹ › arrows
    /// to flip through earlier questions. While generating, streamed text
    /// renders directly; the animated loading row is intentionally omitted
    /// in this compact view so the answer stays calm once it starts moving.
    private func liveFocusView(session: ChatSession) -> some View {
        let pairs   = qaPairs(in: session)
        let clamped = pairs.isEmpty ? 0 : min(focusPairOffset, pairs.count - 1)
        let pair    = pairs.isEmpty ? nil : pairs[pairs.count - 1 - clamped]
        let isLatest = clamped == 0
        // Per-answer streaming state: a non-latest pair can still be
        // generating (answers now run concurrently), so key off the turn,
        // not the global flag.
        let streaming = (pair?.answer?.id).map { vm.isStreaming(turnID: $0) } ?? false

        return VStack(alignment: .leading, spacing: 0) {
            if let pair {
                focusQuestionLine(pair: pair,
                                  position: pairs.count - clamped,
                                  total: pairs.count,
                                  offset: clamped,
                                  maxOffset: pairs.count - 1,
                                  streamingTurnID: streaming ? pair.answer?.id : nil)

                if streaming {
                    streamingAnswer(pair.answer)
                } else if let a = pair.answer, !a.content.isEmpty {
                    completedAnswer(a, isLatest: isLatest)
                } else {
                    Text("No answer for this question.")
                        .font(.system(size: 11))
                        .foregroundColor(Design.Ink.secondary)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                }
            } else {
                focusEmptyState
            }
        }
        .onHover { focusHovering = $0 }
        // A new question arrived — snap back to the live pair.
        .onChange(of: pairs.last?.question.id) { _, _ in focusPairOffset = 0 }
    }

    /// The question of the focused pair, drawn the way the transcript strip
    /// draws its lanes — a labelled flow line ("THEM …"), not a titled
    /// question card — so the whole live view reads as one transcript with
    /// the answer attached underneath it. ‹ › navigation sits quietly at the
    /// trailing edge once there is more than one exchange.
    private func focusQuestionLine(pair: QAPair, position: Int, total: Int,
                                   offset: Int, maxOffset: Int,
                                   streamingTurnID: UUID?) -> some View {
        HStack(alignment: .top, spacing: 7) {
            laneLine("THEM", pair.question.content, primary: true)
            if total > 1 || streamingTurnID != nil {
                HStack(spacing: 3) {
                    if total > 1 {
                        focusArrow(icon: "chevron.left",
                                   enabled: offset < maxOffset,
                                   help: "Previous question") {
                            focusPairOffset = min(offset + 1, maxOffset)
                            vm.onResumeFocusTracking?()
                        }
                        Text("\(position)/\(total)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Design.Ink.tertiary)
                            .monospacedDigit()
                        focusArrow(icon: "chevron.right",
                                   enabled: offset > 0,
                                   help: "Next question") {
                            focusPairOffset = max(offset - 1, 0)
                            vm.onResumeFocusTracking?()
                        }
                    }
                    if let streamingTurnID {
                        focusHeaderStopButton(turnID: streamingTurnID)
                    }
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func focusArrow(icon: String, enabled: Bool, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(enabled ? Design.Ink.secondary : Design.Ink.muted)
                .frame(width: 18, height: 18)
                .background(Circle().fill(enabled ? Design.Surface.controlFill : Design.Surface.shellFill))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private func focusHeaderStopButton(turnID: UUID) -> some View {
        Button {
            vm.cancelStream(turnID: turnID)
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(Design.Accent.red)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Design.Accent.red.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help("Stop generating")
    }

    /// The answer while it streams. The user is mid-interview — they need
    /// the first line the moment it exists, not after the whole answer
    /// lands. This renders the partial text live but WITHOUT the
    /// height-measuring ScrollView used for completed answers: the text
    /// hugs naturally up to the cap, then clips at the bottom with the
    /// top (the say-this-now line) pinned visible. No GeometryReader /
    /// preference feedback loop, so per-flush layout stays as cheap as a
    /// normal chat bubble — the churn that made the old token-by-token
    /// focus card lag came from re-measuring the card per token, not from
    /// laying out the text.
    private func streamingAnswer(_ turn: ChatTurn?) -> some View {
        let hasText = !(turn?.content ?? "").isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            if let turn, hasText {
                MarkdownResponseView(text: turn.content, baseSize: 13.5 * vm.textScale,
                                     codeSize: 11 * vm.textScale)
            } else {
                // Waiting on the first token: pin to ONE line's worth of
                // height. Growing the panel for "Thinking…" was pure noise
                // — the window should only start moving once real answer
                // text is actually arriving.
                StreamingPlaceholderRow()
                    .frame(height: Self.placeholderRowHeight)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        // Hug the partial text and grow with it line by line as tokens
        // land, without a separate animated loading row.
        // `fixedSize` hugs WITHOUT the GeometryReader/preference feedback
        // loop that made the old token-by-token focus card lag; the cap +
        // clip keep a very long partial from overflowing the panel.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: Self.focusMaxHeight, alignment: .top)
        .clipped()
        // Glide, don't step: each ~30Hz flush that adds a wrapped line
        // animates the card's growth instead of snapping — matching the
        // panel's own animated resize (AppDelegate tracks this height).
        // Only animate once text exists; the placeholder→first-token swap
        // shouldn't lerp through an intermediate height. Suspended during
        // a grip drag so the card tracks the cursor without lag.
        .animation(hasText && !vm.isUserResizingPanel
                   ? .easeOut(duration: 0.15) : nil,
                   value: turn?.content ?? "")
    }

    /// Fixed height of the "Thinking…" row, so waiting for the first token
    /// never resizes the panel.
    private static let placeholderRowHeight: CGFloat = 20

    /// A finished answer. Measured ONCE (the text is static now), so the
    /// card hugs short answers and caps + scrolls long ones — none of the
    /// per-token measurement churn that made streaming laggy.
    private func completedAnswer(_ turn: ChatTurn, isLatest: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                MarkdownResponseView(text: turn.content, baseSize: 13.5 * vm.textScale,
                                     codeSize: 11 * vm.textScale)
                focusActionRow(for: turn, isLatest: isLatest)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { g in
                Color.clear.preference(key: FocusHeightKey.self, value: g.size.height)
            })
        }
        .hiddenScrollGutter()
        .onPreferenceChange(FocusHeightKey.self) { focusContentHeight = $0 }
        .frame(height: min(max(focusContentHeight, 56), Self.focusMaxHeight),
               alignment: .top)
        // Smooth the streaming→completed swap and ‹ › navigation between
        // answers of different lengths — the card glides to the measured
        // height instead of snapping. Suspended during a grip drag: the
        // drag is the animation, and easing the card's height behind the
        // cursor (every width change rewraps the text and re-measures)
        // made the bottom edge visibly bounce while resizing.
        .animation(vm.isUserResizingPanel ? nil : .easeOut(duration: 0.18),
                   value: focusContentHeight)
        // Re-created per answer so the preference re-reports on appear
        // (and the scroll position starts at the top of each answer).
        // Resetting the height state on turn change instead raced the
        // preference: the new height could land first, never fire again,
        // and strand the card — and the panel — at the 56pt floor.
        .id(turn.id)
    }

    /// Cap on the focus answer area before it starts scrolling.
    private static let focusMaxHeight: CGFloat = 460

    @ViewBuilder
    private func focusActionRow(for turn: ChatTurn, isLatest: Bool) -> some View {
        // Copy / Retry / model picker reveal on hover only — invisible
        // while the user is reading. Retry + model switch only make
        // sense on the live (latest) answer.
        let actionsVisible = focusHovering
        HStack(spacing: 8) {
            FocusCopyButton(text: turn.content)
            if isLatest {
                focusChip(icon: "arrow.clockwise", label: "Retry",
                          help: "Regenerate this answer") {
                    vm.retryLastResponse()
                }
                // Same question + full context, different model: picking
                // one switches the default AND regenerates immediately.
                // Uses the shared picker so this, Settings and the interview
                // setup screen list the same models.
                ModelPickerButton(
                    currentModelName: currentModelName,
                    onSelect: { _ in vm.retryLastResponse() }
                )
                .help("Re-ask the same question with a different model")
            }
            Spacer()
        }
        .opacity(actionsVisible ? 1 : 0)
        .allowsHitTesting(actionsVisible)
        .animation(.easeInOut(duration: 0.15), value: actionsVisible)
    }

    private var currentModelName: String {
        OverlayViewModel.availableModels.first { $0.id == vm.selectedModel }?.name ?? "Model"
    }

    private func focusChip(icon: String, label: String, help: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(Design.Ink.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Design.Surface.controlFill))
            .overlay(Capsule().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var focusEmptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Design.Ink.tertiary)
            Text("Waiting for the first question")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Design.Ink.secondary)
            Text("The answer appears here the moment the interviewer finishes asking.")
                .font(.caption2)
                .foregroundColor(Design.Ink.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    /// Hero header + Continue-session button for empty sessions tagged as
    /// interview / regular-call. Lets the user immediately re-enter the
    /// paused-live state without having to type anything first.
    private func resumableEmptyState(session: ChatSession) -> some View {
        VStack(spacing: Design.Space.lg) {
            heroHeader
            continueSessionRow(session: session)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Design.Space.xl)
        .padding(.vertical, Design.Space.lg)
    }

    // MARK: - Live transcript

    private var liveTranscriptStrip: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // Inline timer sits flush against the transcription
                    // text — same line as the words being captured —
                    // instead of in its own row. Stays visible while
                    // paused so the user sees the frozen duration. A
                    // text-only chat never records, so it has none.
                    if vm.isInterviewSession && !vm.isInterviewTextOnly {
                        LiveSessionTimer()
                    }
                    // A call shows the live lanes at the BOTTOM of its
                    // growing transcript, so the strip would be showing the
                    // same words twice — the strip's own job here is the
                    // timer and the controls, not a second copy of the speech.
                    if vm.isRegularCallSession {
                        Text("Live")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Design.Ink.tertiary)
                            .padding(.top, 2)
                        Spacer(minLength: 0)
                    } else if vm.isSplitCapture {
                        // During an interview the transcript stays on ONE line
                        // and scrolls — head truncation keeps the newest words
                        // visible — so it never pushes the answer around. In a
                        // "You + Them" session the call and the mic are
                        // transcribed separately, so each gets its own labelled
                        // line and the transcript reads as a conversation —
                        // with the call lane owning the answers, per the
                        // capture plan.
                        VStack(alignment: .leading, spacing: 2) {
                            laneLine("THEM", vm.transcription, primary: true)
                            if !vm.liveYourSpeech.isEmpty {
                                laneLine("YOU", vm.liveYourSpeech, primary: false)
                            }
                        }
                        .animation(.easeInOut(duration: 0.12), value: vm.transcription)
                        .animation(.easeInOut(duration: 0.12), value: vm.liveYourSpeech)
                    } else {
                        Text(placeholderOrTranscription)
                            .font(.system(size: 12 * vm.textScale))
                            .foregroundStyle(vm.transcription.isEmpty
                                             ? AnyShapeStyle(Design.Ink.tertiary)
                                             : AnyShapeStyle(Design.Ink.primary))
                            .lineLimit(vm.isInterviewSession ? 1 : 4)
                            .truncationMode(vm.isInterviewSession ? .head : .tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .animation(.easeInOut(duration: 0.12), value: vm.transcription)
                    }
                    Spacer(minLength: 6)
                    if !vm.transcription.isEmpty {
                        TranscriptCopyButton()
                    }
                    // A call's transcript IS the main view — a drop-down of the same thing
                    // would be a second copy of the page.
                    if !vm.isRegularCallSession
                        && (!previousQuestions.isEmpty || !vm.transcription.isEmpty) {
                        transcriptExpandToggle
                    }
                    if !vm.isInterviewSession {
                        backendBadge
                    }
                    if vm.isInterviewSession && !vm.isInterviewTextOnly {
                        // The focus toggle switches between the single-pair
                        // card and the full conversation. A call has no
                        // single-pair card to switch to — its transcript is
                        // always the full one — so the button would be a
                        // dead control there.
                        if !vm.isRegularCallSession {
                            focusToggle
                        }
                        hideTranscriptButton
                    }
                }

                // The drop-down is the interview's way of reaching the full
                // conversation. On a call the main view already IS that.
                if transcriptExpanded && !vm.isRegularCallSession {
                    transcriptHistoryPanel
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, Design.Space.lg)
        .padding(.vertical, Design.Space.md)
        .background(
            (vm.isRecording || vm.isInterviewSession)
                ? Design.Surface.previewFill.opacity(0.65)
                : Design.Surface.previewFill.opacity(0.45)
        )
    }

    /// Flip between Live Focus (current Q + A only) and the full
    /// conversation during a live interview.
    private var focusToggle: some View {
        Button {
            withAnimation(Design.Motion.fast) { vm.interviewFocusMode.toggle() }
        } label: {
            Image(systemName: vm.interviewFocusMode
                  ? "list.bullet"
                  : "rectangle.compress.vertical")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Design.Ink.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Design.Surface.controlFill))
                .overlay(Circle().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(vm.interviewFocusMode
              ? "Show the full conversation"
              : "Focus on the current answer")
    }

    /// Hide the transcript strip entirely so only the question + answer
    /// remain. Bring it back from the session ⋯ menu.
    private var hideTranscriptButton: some View {
        Button {
            withAnimation(Design.Motion.fast) { vm.showLiveTranscript = false }
        } label: {
            Image(systemName: "eye.slash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Design.Ink.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Design.Surface.controlFill))
                .overlay(Circle().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Hide the transcript — bring it back from the ⋯ menu")
    }

    // MARK: - Transcript history drop-down

    /// Questions already sent to the AI (the session's user turns) — the
    /// transcript history behind the drop-down. The live partial renders
    /// as its own row at the bottom of the panel.
    private var previousQuestions: [ChatTurn] {
        vm.sessionStore.activeSession.turns.filter { $0.role == .user }
    }

    /// Chevron on the strip that opens / closes the full-transcript panel.
    private var transcriptExpandToggle: some View {
        Button {
            withAnimation(Design.Motion.fast) { transcriptExpanded.toggle() }
            // The drop-down changes the focus card's height — resume
            // content tracking so the panel makes room for it even after
            // a manual drag-resize froze the height.
            vm.onResumeFocusTracking?()
        } label: {
            Image(systemName: transcriptExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(transcriptExpanded ? Design.Ink.primary : Design.Ink.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Design.Surface.controlFill))
                .overlay(Circle().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(transcriptExpanded
              ? "Hide the full transcript"
              : "Show the full transcript — previous questions, each with a copy button")
    }

    /// The expanded transcript: every question and every stretch of the
    /// user's own speech in time order, each with its own copy button, the
    /// live partials pinned last, and a Copy-all chip in the header. Height
    /// hugs the rows up to a cap, then scrolls — pinned to the newest entry.
    private var transcriptHistoryPanel: some View {
        let rows = TranscriptTimeline.rows(questions: previousQuestions,
                                           spoken: vm.mySpeechSegments)
        let liveThem = vm.transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveYou  = (vm.isSplitCapture ? vm.liveYourSpeech : "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let copyRows: [(label: String, text: String)] = {
            var out = rows.map { (label: $0.label, text: $0.text) }
            if !liveThem.isEmpty { out.append((label: "LIVE", text: liveThem)) }
            if !liveYou.isEmpty  { out.append((label: "YOU",  text: liveYou)) }
            return out
        }()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Full transcript")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Design.Ink.tertiary)
                Spacer(minLength: 0)
                if !copyRows.isEmpty {
                    TranscriptCopyAllButton(rows: copyRows)
                    GenerateMinutesButton()
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(rows) { row in
                            transcriptHistoryRow(label: row.label,
                                                 text: row.text,
                                                 isLive: false,
                                                 isQuestion: row.isQuestion)
                        }
                        if !liveThem.isEmpty {
                            transcriptHistoryRow(label: "LIVE", text: liveThem,
                                                 isLive: true, isQuestion: true)
                        }
                        if !liveYou.isEmpty {
                            transcriptHistoryRow(label: "YOU", text: liveYou,
                                                 isLive: true, isQuestion: false)
                        }
                        Color.clear.frame(height: 1).id("transcript-bottom")
                    }
                    .background(GeometryReader { g in
                        Color.clear.preference(key: HistoryHeightKey.self,
                                               value: g.size.height)
                    })
                }
                .hiddenScrollGutter()
                .onPreferenceChange(HistoryHeightKey.self) { historyContentHeight = $0 }
                .frame(height: min(max(historyContentHeight, 22), Self.historyMaxHeight))
                .onAppear { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
                .onChange(of: rows.count) { _, _ in
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
                .onChange(of: liveThem) { _, _ in
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
                .onChange(of: liveYou) { _, _ in
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
            }
        }
        .padding(.top, 4)
    }

    /// Cap on the transcript drop-down before it scrolls.
    private static let historyMaxHeight: CGFloat = 220

    private func transcriptHistoryRow(label: String,
                                      text: String,
                                      isLive: Bool,
                                      isQuestion: Bool) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(label)
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(isLive
                                 ? (isQuestion
                                    ? AnyShapeStyle(Design.Accent.red)
                                    : AnyShapeStyle(Design.Accent.brand))
                                 : AnyShapeStyle(Design.Ink.tertiary))
                .frame(width: 28, alignment: .leading)
                .padding(.top, 3)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(isQuestion ? Design.Ink.primary : Design.Ink.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HistoryRowCopyButton(text: text)
        }
    }

    private var backendBadge: some View {
        let cloud = vm.transcriptionBackend != .apple
        return HStack(spacing: 3) {
            Image(systemName: cloud ? "bolt.fill" : "apple.logo")
                .font(.system(size: 8))
            Text(vm.transcriptionBackend.rawValue)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(cloud ? Design.Accent.brand : Design.Ink.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background((cloud ? Design.Accent.brand : Design.Ink.secondary).opacity(0.12))
        .clipShape(Capsule())
        .help(cloud
              ? "Using \(vm.transcriptionBackend.rawValue) for live transcription."
              : "Using Apple on-device speech recognition. Add an ElevenLabs or xAI key in Settings → AI for higher accuracy.")
    }

    private var placeholderOrTranscription: String {
        if !vm.transcription.isEmpty { return vm.transcription }
        if vm.isInterviewSession     { return "Listening… speak anytime." }
        if vm.isRecording            { return "Listening…" }
        return "—"
    }

    /// One labelled line of the split transcript. The call lane ("THEM")
    /// owns the questions and renders in the brand accent; the mic lane
    /// ("YOU") is context and renders quieter.
    private func laneLine(_ label: String, _ text: String, primary: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(primary
                                 ? AnyShapeStyle(Design.Accent.brand)
                                 : AnyShapeStyle(Design.Ink.tertiary))
                .frame(width: 34, alignment: .leading)
            Text(text.isEmpty && primary ? "Listening…" : text)
                .font(.system(size: 12 * vm.textScale))
                .foregroundStyle(text.isEmpty && primary
                                 ? AnyShapeStyle(Design.Ink.tertiary)
                                 : (primary
                                    ? AnyShapeStyle(Design.Ink.primary)
                                    : AnyShapeStyle(Design.Ink.secondary)))
                .lineLimit(vm.isInterviewSession ? 2 : 3)
                .truncationMode(vm.isInterviewSession ? .head : .tail)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Empty state (mode-aware starter cards)

    private var emptyState: some View {
        VStack(spacing: Design.Space.lg) {
            heroHeader
            starterCards
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Design.Space.xl)
    }

    private var heroHeader: some View {
        VStack(spacing: Design.Space.xs) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Design.Ink.secondary)
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .padding(.bottom, 2)

            Text(modeHeadline)
                .font(Design.Font.hero)
                .foregroundColor(Design.Ink.primary)
            Text(modeSubtitle)
                .font(Design.Font.small)
                .foregroundColor(Design.Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var starterCards: some View {
        let cards = starters
        VStack(spacing: Design.Space.sm) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                starterCard(title: card.title, subtitle: card.subtitle, prompt: card.prompt)
            }
        }
    }

    private func starterCard(title: String, subtitle: String, prompt: String) -> some View {
        @Bindable var vm = vm
        return Button {
            vm.showManualInput = true
            vm.manualInput = prompt
        } label: {
            HStack(alignment: .top, spacing: Design.Space.md) {
                Image(systemName: "arrow.up.forward.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Design.Ink.secondary)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Design.Font.bodyBold).foregroundColor(Design.Ink.primary)
                    Text(subtitle).font(Design.Font.small).foregroundColor(Design.Ink.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, Design.Space.md)
            .padding(.vertical, 8)
            .background(Design.Surface.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.md)
                    .stroke(Design.Surface.hairline, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift()
    }

    private var modeHeadline: String {
        switch vm.sessionMode {
        case .interview: return "Ready for your interview"
        case .meeting:   return "Ready for the meeting"
        case .call:      return "Ready for the call"
        case .general:   return "What can I help with?"
        }
    }

    private var modeSubtitle: String {
        switch vm.sessionMode {
        // Not "Start Interview up top": the only Start lives on the Interview
        // surface, and the top strip that mentions is hover-revealed, so
        // pointing at it sent the user looking for a control that was not on
        // screen.
        case .interview: return "Pick a starter below, or just type."
        case .meeting:   return "Record the conversation, or pick a starter below."
        case .call:      return "Record the call, or pick a starter below."
        case .general:   return "Pick a starter or just type below."
        }
    }

    private var starters: [(title: String, subtitle: String, prompt: String)] {
        switch vm.sessionMode {
        case .interview:
            return [
                ("STAR answer",
                 "Walk me through a strong STAR answer",
                 "Walk me through a strong STAR answer for a question about a time I handled a difficult stakeholder."),
                ("Technical gaps",
                 "Suggest topics to brush up before the interview",
                 "Given my background, suggest 5 technical topics I should brush up on before my interview."),
                ("Smart question",
                 "Give me a thoughtful question for the interviewer",
                 "Give me one thoughtful, specific question I can ask the interviewer about the role and team.")
            ]
        case .meeting:
            return [
                ("Summarise so far",
                 "Bullet summary of the last chunk",
                 "Summarise the last 10 minutes of the meeting in concise bullets."),
                ("Action items",
                 "Extract owners and deadlines",
                 "Extract the action items, owners, and deadlines from the meeting so far."),
                ("Decisions",
                 "What was decided?",
                 "List the decisions that have been made in this meeting.")
            ]
        case .call:
            return [
                ("Summarise the call",
                 "What was covered?",
                 "Summarise what we've covered in this call so far in 5 bullets."),
                ("Follow-up email",
                 "Draft a clean recap",
                 "Draft a follow-up email summarising this call and listing any next steps."),
                ("Commitments",
                 "What did I commit to?",
                 "List anything I committed to during this call.")
            ]
        case .general:
            return [
                ("Explain",
                 "Break something down in plain terms",
                 "Explain the following in simple terms so a beginner can follow:\n\n"),
                ("Draft",
                 "Help me write a message",
                 "Help me draft a concise, professional message about:\n\n"),
                ("Next step",
                 "What should I do next?",
                 "Given the context above, what should I focus on next and why?")
            ]
        }
    }

    // MARK: - Conversation

    private func conversationView(session: ChatSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(session.turns) { turn in
                        TurnBubble(turn: turn,
                                   isStreaming: vm.isStreaming(turnID: turn.id),
                                   onRetry: { vm.retryLastResponse() })
                            .id(turn.id)
                    }
                    if showsContinueButton(session: session) {
                        continueSessionRow(session: session)
                    }
                    // Sentinel pinned to the bottom of the stack. Streaming
                    // scroll snaps to this fixed id once per turn instead of
                    // chasing a moving id every chunk — which was the source
                    // of the visible "breaking" jitter.
                    Color.clear.frame(height: 1).id("bottom-anchor")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
            .hiddenScrollGutter()
            .onChange(of: session.turns.count) { _, _ in
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
            // Throttle streaming-scroll to once every ~120ms via a coarse
            // length bucket. Per-character scrollTo runs faster than the
            // layout settles, which is what made the text look like it was
            // tearing during streaming.
            .onChange(of: (session.turns.last?.content.count ?? 0) / 32) { _, _ in
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
            // Floating control while a reply streams: ↓ snaps back to the
            // live tail. Stop lives in the compact bar/header so the answer
            // area stays quiet while text is moving.
            .overlay(alignment: .bottomTrailing) {
                if vm.isSendingToAI {
                    streamChipButton(icon: "arrow.down", label: nil,
                                     help: "Jump to latest") {
                        proxy.scrollTo("bottom-anchor", anchor: .bottom)
                    }
                    .padding(10)
                    .transition(.opacity)
                }
            }
        }
    }

    private func streamChipButton(icon: String, label: String?,
                                  help: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                if let label {
                    Text(label).font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundColor(Design.Ink.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Design.Surface.raisedFill))
            .overlay(Capsule().strokeBorder(Design.Surface.strongHairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Whether to render the inline "Continue session" affordance.
    /// Shows when the session is a resumable kind (interview /
    /// regular-call / legacy normal) and no live session is currently
    /// running — applies to both empty sessions (resumable shell with
    /// no turns yet) and sessions with prior messages.
    private func showsContinueButton(session: ChatSession) -> Bool {
        guard !vm.isInterviewSession else { return false }
        switch session.kind {
        case .interview, .regularCall, .normal: return true
        case .quickAsk:                          return false
        }
    }

    /// Whether an *empty* session should offer "Continue call" instead of the
    /// starter cards.
    ///
    /// `showsContinueButton` is true for `.normal` so that legacy call
    /// sessions can be resumed from the end of their transcript. Using it for
    /// an empty session as well meant every brand-new chat — which is always
    /// `.normal` — showed the mode headline, a "Continue call" button, and no
    /// starter cards at all. The cards are the only useful thing on that
    /// screen, and nothing could reach them.
    private func offersResumeInsteadOfStarters(session: ChatSession) -> Bool {
        session.kind != .normal && showsContinueButton(session: session)
    }

    /// "Continue session" affordance pinned after the last assistant
    /// turn. Clicking goes live on this session again straight away,
    /// the same as Start on the setup screen, with the timer counting
    /// from 00:00.
    private func continueSessionRow(session: ChatSession) -> some View {
        let label: String = {
            switch session.kind {
            case .interview:                 return "Continue interview"
            case .regularCall, .normal:      return "Continue call"
            case .quickAsk:                  return "Continue"
            }
        }()
        return HStack {
            Spacer()
            Button {
                vm.startInterviewSession()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(Design.Ink.inverse)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Design.Ink.primary))
                .overlay(Capsule().strokeBorder(Design.Surface.strongHairline, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("Reopen the call controls in the bar — the mic stays off until you hit play.")
            Spacer()
        }
        .padding(.top, 12)
    }
}

// MARK: - Turn bubble

private struct TurnBubble: View {
    @Environment(OverlayViewModel.self) private var vm
    let turn: ChatTurn
    var isStreaming = false
    var onRetry: () -> Void = {}
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if turn.role == .user {
                Spacer(minLength: 40)
                userContent
            } else {
                assistantContent
                Spacer(minLength: 0)
            }
        }
    }

    /// User message: ChatGPT-style monochrome grey pill, right-aligned.
    /// Attachments render as small file chips above the text. No metadata
    /// row — the bubble stands on its own, matching the reference UI.
    private var userContent: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let names = turn.attachments, !names.isEmpty {
                FlowAttachmentRow(names: names, alignment: .trailing)
            }
            if !turn.content.isEmpty {
                Text(turn.content)
                    .font(.system(size: 12 * vm.textScale))
                    .foregroundColor(Design.Ink.primary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Design.Surface.userBubbleFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Design.Surface.hairline, lineWidth: 0.5)
                    )
            }
        }
    }

    /// Assistant: plain markdown text on the surface, with a ChatGPT-style
    /// row of action icons underneath — copy, read-aloud, thumbs up/down,
    /// regenerate. The row is always visible once the reply has content.
    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if turn.content.isEmpty {
                if isStreaming {
                    StreamingPlaceholderRow()
                }
            } else {
                MarkdownResponseView(text: turn.content, baseSize: 12 * vm.textScale,
                                     codeSize: 11 * vm.textScale)
                actionRow
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 6) {
            actionButton(copied ? "checkmark" : "square.on.square",
                         help: copied ? "Copied" : "Copy",
                         active: copied) { copy() }
            actionButton("arrow.clockwise", help: "Regenerate") { onRetry() }
        }
        .animation(Design.Motion.fast, value: copied)
    }

    /// One icon in the assistant action row. Hover brightens; `active`
    /// paints it in the primary tint (e.g. while reading aloud).
    private func actionButton(_ icon: String,
                              help: String,
                              active: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(active ? Design.Ink.primary : Design.Ink.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(Design.Surface.controlHoverFill)
        .help(help)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(turn.content, forType: .string)
        withAnimation(Design.Motion.fast) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(Design.Motion.fast) { copied = false }
        }
    }
}

private struct StreamingPlaceholderRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.72)
            Text("Thinking...")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Design.Ink.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Reports the laid-out height of the Live Focus content so the card can
/// hug it instead of claiming the whole panel.
private struct FocusHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Same measuring trick for the transcript-history drop-down, so it hugs
/// a short history instead of always claiming its full cap.
private struct HistoryHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Icon-only copy button for one transcript-history row.
private struct HistoryRowCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(t, forType: .string)
            withAnimation(Design.Motion.fast) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(Design.Motion.fast) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundColor(copied ? Design.Accent.green : .secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy this question")
    }
}

/// "Copy all" chip in the transcript-history header — joins every
/// question (plus the live partial) into one numbered block.
private struct TranscriptCopyAllButton: View {
    let rows: [(label: String, text: String)]
    @State private var copied = false

    var body: some View {
        Button {
            let joined = rows
                .map { "\($0.label): \($0.text)" }
                .joined(separator: "\n\n")
            guard !joined.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(joined, forType: .string)
            withAnimation(Design.Motion.fast) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(Design.Motion.fast) { copied = false }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 8, weight: .semibold))
                Text(copied ? "Copied" : "Copy all")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(copied ? Design.Accent.green : Design.Ink.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Design.Surface.controlFill))
            .overlay(Capsule().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Copy the full transcript")
    }
}

/// Turns this session's transcript into meeting minutes. Sits beside Copy all
/// because it is the same kind of action — something done to the transcript —
/// and the transcript panel is exactly where the user opens it from.
private struct GenerateMinutesButton: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        Button {
            vm.generateMinutes()
        } label: {
            HStack(spacing: 3) {
                if vm.isGeneratingMinutes {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: "list.clipboard")
                        .font(.system(size: 8, weight: .semibold))
                }
                Text(vm.isGeneratingMinutes ? "Writing…" : "Minutes")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(Design.Ink.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Design.Surface.controlFill))
            .overlay(Capsule().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(vm.isGeneratingMinutes)
        .help("Write meeting minutes from this transcript — saved to Session notes")
    }
}

/// The generated minutes: markdown, selectable, with a copy button. The note
/// itself is already in Session notes (export from the notes panel); this
/// sheet is for reading and copying the text right away.
/// The generated summary, as a full panel surface.
///
/// It used to be a SwiftUI `.sheet`. A sheet is its own fixed-size window
/// attached to the panel: it cannot be moved, cannot be resized, and it
/// covers the conversation behind it — so the one artifact a user wants to
/// read at their own pace was the one thing they could not control. As a
/// primary surface it inherits the panel's own drag handle and the
/// eight-edge resize every other surface has.
struct SummarySurfaceView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sits under the shell's own header strip, so it repeats only
            // what the header does not already say: what this document is,
            // and that it is saved.
            HStack(spacing: 8) {
                Image(systemName: "list.clipboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Design.Accent.brand)
                Text(vm.minutesTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Design.Ink.primary)
                Spacer(minLength: 6)
                Text("Saved to Session notes")
                    .font(.system(size: 10))
                    .foregroundColor(Design.Ink.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Rectangle().fill(Design.Surface.hairline).frame(height: 0.5)

            // The summary is the scrollable body. Hard-sizing the document
            // instead (as the old sheet did) meant a long summary ran past
            // the bottom edge with no way to reach the rest of it.
            ScrollView {
                MarkdownResponseView(text: vm.minutesText ?? "", baseSize: 12.5 * vm.textScale,
                                     codeSize: 10.5 * vm.textScale)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
            }
            .hiddenScrollGutter()

            Rectangle().fill(Design.Surface.hairline).frame(height: 0.5)

            HStack {
                Button {
                    let text = vm.minutesText ?? ""
                    guard !text.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    withAnimation(Design.Motion.fast) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        withAnimation(Design.Motion.fast) { copied = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(copied ? Design.Accent.green : Design.Ink.primary)
                }
                .buttonStyle(.plain)

                Spacer()

                // Back to the conversation, not a bare Close: the summary was
                // generated FROM this session, so they are two views of the
                // same thing and the user switches between them.
                Button {
                    vm.primarySurface = .chat
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Conversation")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(Design.Ink.primary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Tiny copy button on the live transcript strip — copies whatever is
/// currently transcribed so the user can grab the interviewer's question
/// mid-session (paste into notes, a search, another tool) without waiting
/// for it to become a chat turn.
private struct TranscriptCopyButton: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var copied = false

    var body: some View {
        Button {
            let text = vm.transcription.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(Design.Motion.fast) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(Design.Motion.fast) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(copied ? Design.Accent.green : .secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy transcript")
    }
}

/// Compact copy chip for the Live Focus action row — mirrors the bubble
/// action button but stands alone (TurnBubble's row is private state).
private struct FocusCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(Design.Motion.fast) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(Design.Motion.fast) { copied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "square.on.square")
                    .font(.system(size: 9, weight: .semibold))
                Text(copied ? "Copied" : "Copy")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(Design.Ink.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Design.Surface.controlFill))
            .overlay(Capsule().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Copy answer")
    }
}

// MARK: - Attachment chip row

/// Compact row of file chips shown above a user message. Each chip just
/// shows the file icon + name — the actual extracted text was sent to the
/// AI as part of the prompt but is intentionally NOT rendered here.
struct FlowAttachmentRow: View {
    let names: [String]
    let alignment: HorizontalAlignment

    var body: some View {
        HStack(spacing: 6) {
            if alignment == .trailing { Spacer(minLength: 0) }
            ForEach(names, id: \.self) { name in
                HStack(spacing: 5) {
                    Image(systemName: iconFor(name))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Design.Ink.secondary)
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Design.Ink.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Design.Surface.controlFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Design.Surface.hairline, lineWidth: 0.5)
                )
            }
            if alignment == .leading { Spacer(minLength: 0) }
        }
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
}

// MARK: - Live session timer (inline)

/// Tiny mm:ss / h:mm:ss counter shown on the live transcript strip while
/// an interview / call session is active. Reads `interviewElapsedSeconds`
/// + the current running phase off the view model so pause/resume keeps
/// the value frozen at its current state instead of restarting from 0.
private struct LiveSessionTimer: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var tick = Date()
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let paused = vm.isInterviewPaused
        return HStack(spacing: 4) {
            Circle()
                .fill(paused ? Design.Ink.secondary : Design.Accent.red)
                .frame(width: 5, height: 5)
                .opacity(0.9)
            Text(formatted)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Design.Ink.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background((paused ? Design.Ink.secondary : Design.Accent.red).opacity(0.10))
        .clipShape(Capsule())
        .onReceive(ticker) { d in tick = d }
    }

    private var formatted: String {
        let liveSlice: TimeInterval
        if let started = vm.interviewRunningSince {
            liveSlice = tick.timeIntervalSince(started)
        } else {
            liveSlice = 0
        }
        let secs = Int(vm.interviewElapsedSeconds + liveSlice)
        let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
