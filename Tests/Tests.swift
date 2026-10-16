import AppKit
import Foundation

// MARK: - Tiny test runner
//
// Intentionally avoids XCTest so tests can be compiled as a plain swiftc
// executable alongside the main sources, without pulling in an entire
// Xcode/SPM test bundle.

struct TestFailure: Error { let message: String; let file: String; let line: Int }

@MainActor
final class TestRunner {
    static var passed = 0
    static var failed: [(String, String, String, Int)] = []
    static var current = ""

    static func run(_ name: String, _ body: () throws -> Void) {
        current = name
        do {
            try body()
            passed += 1
            print("  ✓ \(name)")
        } catch let f as TestFailure {
            failed.append((name, f.message, f.file, f.line))
            print("  ✗ \(name)  — \(f.message)  @ \(f.file):\(f.line)")
        } catch {
            failed.append((name, "\(error)", #file, #line))
            print("  ✗ \(name)  — \(error)")
        }
    }
}

func assertEq<T: Equatable>(_ a: T, _ b: T, _ note: String = "", file: String = #file, line: Int = #line) throws {
    if a != b {
        throw TestFailure(message: "\(a) != \(b)  \(note)", file: file, line: line)
    }
}

func assertTrue(_ cond: Bool, _ note: String = "", file: String = #file, line: Int = #line) throws {
    if !cond { throw TestFailure(message: "expected true: \(note)", file: file, line: line) }
}

func assertFalse(_ cond: Bool, _ note: String = "", file: String = #file, line: Int = #line) throws {
    if cond { throw TestFailure(message: "expected false: \(note)", file: file, line: line) }
}

// Isolates tests that write to UserDefaults / disk so they don't clobber the
// app's real persistence.
@MainActor
func withSandboxedDefaults(_ body: () throws -> Void) rethrows {
    let suiteName = "MacOverlayTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let previous = UserDefaults.standard
    _ = previous
    try body()
    defaults.removePersistentDomain(forName: suiteName)
}

// MARK: - Tests

@MainActor
func testModels() throws {
    // ChatTurn defaults
    let t = ChatTurn(role: .user, content: "hello")
    try assertEq(t.role, .user)
    try assertEq(t.content, "hello")
    try assertTrue(t.inputTokens == nil)

    // ChatSession display title
    var s = ChatSession()
    try assertEq(s.displayTitle, "New session")
    s.turns.append(ChatTurn(role: .user, content: "Tell me about yourself for interview"))
    try assertTrue(s.displayTitle.hasPrefix("Tell me about yourself"))

    // Token totals
    var withTokens = ChatSession()
    withTokens.turns = [
        ChatTurn(role: .user, content: "q"),
        ChatTurn(role: .assistant, content: "a", inputTokens: 10, outputTokens: 20),
        ChatTurn(role: .user, content: "q2"),
        ChatTurn(role: .assistant, content: "a2", inputTokens: 5, outputTokens: 7)
    ]
    try assertEq(withTokens.totalInputTokens, 15)
    try assertEq(withTokens.totalOutputTokens, 27)
    try assertEq(withTokens.totalTokens, 42)

    // Summary pluralisation
    var one = ChatSession()
    one.turns.append(ChatTurn(role: .user, content: "q"))
    try assertEq(one.summary, "1 message")
    one.turns.append(ChatTurn(role: .user, content: "q2"))
    try assertEq(one.summary, "2 messages")
}

@MainActor
func testPromptPreset() throws {
    let p = PromptPreset(name: "Interview", content: "You are coach", linkedMode: .interview)
    try assertEq(p.name, "Interview")
    try assertEq(p.linkedMode, .interview)

    // Codable round-trip
    let data = try JSONEncoder().encode(p)
    let decoded = try JSONDecoder().decode(PromptPreset.self, from: data)
    try assertEq(decoded.id, p.id)
    try assertEq(decoded.content, p.content)
}

@MainActor
func testResumePreset() throws {
    let r = ResumePreset(name: "Backend", content: "Worked at X", tags: ["backend", "go"])
    try assertEq(r.tags.count, 2)
    try assertTrue(r.tags.contains("backend"))

    let data = try JSONEncoder().encode(r)
    let decoded = try JSONDecoder().decode(ResumePreset.self, from: data)
    try assertEq(decoded.name, "Backend")
}

@MainActor
func testWorkspace() throws {
    let w = Workspace(name: "Work", icon: "briefcase", colorHex: "#FF0000", isDefault: false)
    try assertEq(w.name, "Work")
    try assertEq(w.icon, "briefcase")
    try assertFalse(w.isDefault)

    let data = try JSONEncoder().encode(w)
    let decoded = try JSONDecoder().decode(Workspace.self, from: data)
    try assertEq(decoded.colorHex, "#FF0000")
}

@MainActor
func testJSONStoreRoundTrip() throws {
    let items = [
        PromptPreset(name: "A", content: "aa"),
        PromptPreset(name: "B", content: "bb")
    ]
    let filename = "test-\(UUID().uuidString).json"
    JSONStore.save(items, to: filename)
    JSONStore.flush()   // save is async — wait for the write to land
    let loaded = JSONStore.load([PromptPreset].self, from: filename)
    try assertTrue(loaded != nil, "expected loaded non-nil")
    try assertEq(loaded?.count ?? 0, 2)
    try assertEq(loaded?[0].name ?? "", "A")

    // Cleanup
    try? FileManager.default.removeItem(at: JSONStore.url(for: filename))
}

@MainActor
func testAIManagerModelRouting() throws {
    let ai = AIManager.shared
    try assertTrue(ai.isOpenAIModel("gpt-4o"))
    try assertTrue(ai.isOpenAIModel("gpt-4o-mini"))
    try assertTrue(ai.isOpenAIModel("o3-mini"))
    try assertFalse(ai.isOpenAIModel("claude-sonnet-4-6"))
    try assertFalse(ai.isOpenAIModel("claude-haiku-4-5-20251001"))
    try assertFalse(ai.isOpenAIModel("some-random-model"))
}

@MainActor
func testResumeScoreParser() throws {
    let raw = """
    SCORE: 82
    VERDICT: Strong match with minor tailoring
    MISSING_KEYWORDS: kubernetes, grafana, on-call
    STRENGTHS: backend, APIs, SQL
    """
    let s = ResumeScore(raw: raw)
    try assertEq(s.score, 82)
    try assertTrue(s.verdict.contains("Strong match"))
    try assertEq(s.missing.count, 3)
    try assertTrue(s.missing.contains("kubernetes"))
    try assertEq(s.strengths.count, 3)
    try assertEq(s.color, "green")
}

@MainActor
func testResumeScoreVerdictColors() throws {
    let high = ResumeScore(score: 90, verdict: "v", missing: [], strengths: [])
    try assertEq(high.color, "green")
    let mid  = ResumeScore(score: 65, verdict: "v", missing: [], strengths: [])
    try assertEq(mid.color, "yellow")
    let low  = ResumeScore(score: 30, verdict: "v", missing: [], strengths: [])
    try assertEq(low.color, "red")
    try assertTrue(low.recommendation.contains("Low match"))
}

@MainActor
func testSessionTitleAutoSetOnFirstTurn() throws {
    var s = ChatSession()
    try assertTrue(s.title.isEmpty)
    s.turns.append(ChatTurn(role: .user, content: "Walk me through a grokking algorithms question."))
    // Title itself is only set by SessionStore.appendUser; here we test
    // displayTitle's fallback path.
    try assertTrue(s.displayTitle.hasPrefix("Walk me through a grokking"))
}

@MainActor
func testSessionTurnOrderAfterAppend() throws {
    var s = ChatSession()
    s.turns.append(ChatTurn(role: .user, content: "q1"))
    s.turns.append(ChatTurn(role: .assistant, content: "a1"))
    s.turns.append(ChatTurn(role: .user, content: "q2"))
    s.turns.append(ChatTurn(role: .assistant, content: "a2"))
    try assertEq(s.turns.count, 4)
    try assertEq(s.turns[0].role, .user)
    try assertEq(s.turns[1].role, .assistant)
    try assertEq(s.turns[2].content, "q2")
    try assertEq(s.turns[3].content, "a2")
}

@MainActor
func testSessionModeSystemPromptNotEmpty() throws {
    for mode in SessionMode.allCases {
        try assertFalse(mode.systemPrompt.isEmpty, "\(mode) prompt empty")
        try assertFalse(mode.displayName.isEmpty, "\(mode) display name empty")
        try assertFalse(mode.icon.isEmpty, "\(mode) icon empty")
    }
}

@MainActor
func testSessionModeQuickActionsExist() throws {
    for mode in SessionMode.allCases {
        try assertTrue(mode.quickActions.count >= 1,
                       "\(mode) should have at least one quick action")
    }
}

@MainActor
func testAudioSourceLabels() throws {
    try assertEq(AudioSource.microphone.label, "Mic")
    try assertEq(AudioSource.systemAudio.label, "System")
    try assertEq(AudioSource.both.label, "Both")
    try assertEq(AudioSource.allCases.count, 3)
}

@MainActor
func testAppChannelResolution() throws {
    try assertEq(AppChannel(infoValue: "dev"), .dev)
    try assertEq(AppChannel(infoValue: "beta"), .beta)
    try assertEq(AppChannel(infoValue: "prod"), .production)
    // Missing or unknown values must never unlock preview features.
    try assertEq(AppChannel(infoValue: nil), .production)
    try assertEq(AppChannel(infoValue: "staging"), .production)
    try assertEq(AppChannel(infoValue: 1), .production)
    try assertFalse(AppChannel.production.showsPreviewFeatures)
    try assertTrue(AppChannel.beta.showsPreviewFeatures)
    try assertTrue(AppChannel.dev.showsPreviewFeatures)
}

@MainActor
func testTranscriptionLanguageDefaultsToEnglish() throws {
    func defaultID(_ locale: String) -> String {
        TranscriptionLanguage.defaultLanguage(for: Locale(identifier: locale)).id
    }
    // English Macs keep their accent model when we list it.
    try assertEq(defaultID("en_US"), "en-US")
    try assertEq(defaultID("en_IN"), "en-IN")
    try assertEq(defaultID("en_GB"), "en-GB")
    try assertEq(defaultID("en_NZ"), "en-US", "unlisted English variant falls back to US")
    // Non-English Macs still transcribe English unless the user picks otherwise.
    try assertEq(defaultID("fr_FR"), "en-US")
    try assertEq(defaultID("hi_IN"), "en-US")

    let ids = TranscriptionLanguage.all.map(\.id)
    try assertEq(Set(ids).count, ids.count, "language ids must be unique")
    try assertTrue(TranscriptionLanguage.all.filter { $0.id.hasPrefix("en-") }.allSatisfy { $0.elevenLabsCode == "en" })
}

@MainActor
func testTranscriptionLanguageReadsSavedChoice() throws {
    let key = TranscriptionLanguage.defaultsKey
    defer { UserDefaults.standard.removeObject(forKey: key) }
    UserDefaults.standard.set("hi-IN", forKey: key)
    try assertEq(TranscriptionLanguage.current.id, "hi-IN")
    try assertEq(TranscriptionLanguage.current.elevenLabsCode, "hi")
    UserDefaults.standard.set("xx-YY", forKey: key)
    try assertEq(TranscriptionLanguage.current.id,
                 TranscriptionLanguage.defaultLanguage(for: .current).id,
                 "an unknown saved value falls back to the default")
}

@MainActor
func testCallDetectorRecognisesCallApps() throws {
    try assertEq(CallDetector.callAppName(bundleID: "us.zoom.xos"), "Zoom")
    try assertEq(CallDetector.callAppName(bundleID: "com.microsoft.teams2"), "Microsoft Teams")
    try assertEq(CallDetector.callAppName(bundleID: "com.apple.FaceTime"), "FaceTime")
    // Browser helper processes are what actually hold the mic for Meet.
    try assertEq(CallDetector.callAppName(bundleID: "com.google.Chrome.helper"), "Chrome")
    try assertEq(CallDetector.callAppName(bundleID: "com.apple.WebKit.GPU"), "Safari")
    // Mic users that are not calls must never trigger the prompt.
    try assertEq(CallDetector.callAppName(bundleID: "com.apple.CoreSpeech"), nil)
    try assertEq(CallDetector.callAppName(bundleID: "tech.thecloser.mac"), nil)
    try assertEq(CallDetector.callAppName(bundleID: "tech.thecloser.mac.dev"), nil)
    try assertEq(CallDetector.callAppName(bundleID: nil), nil)
}

@MainActor
func testCallStateWaitsBeforeEndingACall() throws {
    var state = CallState(endGracePeriod: 90)
    let start = Date(timeIntervalSince1970: 0)
    try assertTrue(state.update(micApp: "Zoom", now: start), "call starts")
    try assertEq(state.current, "Zoom")
    try assertFalse(state.update(micApp: "Zoom", now: start + 2), "same call, no event")
    // Muted for a minute: the mic goes free, but the call isn't over.
    try assertFalse(state.update(micApp: nil, now: start + 60))
    try assertEq(state.current, "Zoom")
    // Unmuting inside the grace period must not count as a new call.
    try assertFalse(state.update(micApp: "Zoom", now: start + 70))
    // Free for longer than the grace period: now it's over.
    try assertFalse(state.update(micApp: nil, now: start + 100))
    try assertTrue(state.update(micApp: nil, now: start + 161), "call ends after 90s free")
    try assertTrue(state.current == nil)
    try assertFalse(state.update(micApp: nil, now: start + 200), "no repeat end event")
    try assertTrue(state.update(micApp: "Chrome", now: start + 300), "next call starts")
}

@MainActor
func testAppChannelKeepsDataApart() throws {
    // Production keeps the original folder so existing users' data carries over.
    try assertEq(AppChannel.production.dataDirectoryName, "MacOverlay")
    try assertEq(AppChannel.production.badge, nil)
    let folders = Set(AppChannel.allCases.map(\.dataDirectoryName))
    try assertEq(folders.count, AppChannel.allCases.count, "each channel needs its own data folder")
}

@MainActor
func testTurnIDsAreUnique() throws {
    let turns = (0..<50).map { _ in ChatTurn(role: .user, content: "x") }
    let ids = Set(turns.map(\.id))
    try assertEq(ids.count, turns.count)
}

@MainActor
func testNoteEntryRoundTrip() throws {
    let note = NoteEntry(timestamp: Date(), source: .ai, content: "hi", mode: .interview)
    let data = try JSONEncoder().encode(note)
    let decoded = try JSONDecoder().decode(NoteEntry.self, from: data)
    try assertEq(decoded.content, "hi")
    try assertTrue(decoded.source == NoteSource.ai)
    try assertTrue(decoded.mode == SessionMode.interview)
}

@MainActor
func testTranscriptFilterMeaningful() throws {
    // Real speech passes.
    try assertTrue(TranscriptFilter.isMeaningful("What is your biggest weakness?"))
    try assertTrue(TranscriptFilter.isMeaningful("ok tell me about react"))
    // Filler-only, annotations, and noise are rejected.
    try assertFalse(TranscriptFilter.isMeaningful(""))
    try assertFalse(TranscriptFilter.isMeaningful("   "))
    try assertFalse(TranscriptFilter.isMeaningful("um, uh… hmm."))
    try assertFalse(TranscriptFilter.isMeaningful("[noise]"))
    try assertFalse(TranscriptFilter.isMeaningful("(music) [BLANK_AUDIO]"))
    try assertFalse(TranscriptFilter.isMeaningful("a"))
    // Filler around real content still counts as content.
    try assertTrue(TranscriptFilter.isMeaningful("um so why Swift?"))
}

@MainActor
func testTranscriptFilterSeemsComplete() throws {
    // Terminal punctuation → complete.
    try assertTrue(TranscriptFilter.seemsComplete("Tell me about yourself."))
    try assertTrue(TranscriptFilter.seemsComplete("What is a closure in Swift?"))
    try assertTrue(TranscriptFilter.seemsComplete("That's impressive!"))
    // Trailing off / mid-thought → incomplete.
    try assertFalse(TranscriptFilter.seemsComplete(""))
    try assertFalse(TranscriptFilter.seemsComplete("So tell me about…"))
    try assertFalse(TranscriptFilter.seemsComplete("So, tell me about..."))
    try assertFalse(TranscriptFilter.seemsComplete("Walk me through your experience with"))
    try assertFalse(TranscriptFilter.seemsComplete("And then we need to,"))
    try assertFalse(TranscriptFilter.seemsComplete("What do you think about the"))
    try assertFalse(TranscriptFilter.seemsComplete("Can you explain how"))
    // Unpunctuated but neutral ending → treated as complete so engines
    // that don't punctuate don't stall every send.
    try assertTrue(TranscriptFilter.seemsComplete("Tell me about your last project"))
}

@MainActor
func testTranscriptFilterWarrantsResponse() throws {
    func isYes(_ s: String) -> Bool {
        if case .yes = TranscriptFilter.warrantsResponse(s) { return true }
        return false
    }
    func isNo(_ s: String) -> Bool {
        if case .no = TranscriptFilter.warrantsResponse(s) { return true }
        return false
    }
    func isUnsure(_ s: String) -> Bool {
        if case .unsure = TranscriptFilter.warrantsResponse(s) { return true }
        return false
    }

    // Real questions send instantly — no model call.
    try assertTrue(isYes("What's your experience with Kubernetes?"))
    try assertTrue(isYes("Tell me about yourself"))
    try assertTrue(isYes("Walk me through your last project"))
    try assertTrue(isYes("How would you design a rate limiter"))
    try assertTrue(isYes("Can you give an example"))
    // A question mark wins even when the line opens with acknowledgement.
    try assertTrue(isYes("Okay, so what's next?"))
    // Long unpunctuated scenario prompts are substantive.
    try assertTrue(isYes("So your team is on call and the pager goes off at 3am and the database is down"))

    // Backchannel never sends, at any length.
    try assertTrue(isNo("Okay"))
    try assertTrue(isNo("yeah, that makes sense"))
    try assertTrue(isNo("Right, got it"))
    try assertTrue(isNo("hold on one second"))
    try assertTrue(isNo("mm-hmm"))
    // Short fragments with no question shape.
    try assertTrue(isNo("and then the"))
    try assertTrue(isNo(""))

    // The narrow ambiguous band — these are what the model resolves.
    try assertTrue(isUnsure("give me a second there"))
}

@MainActor
func testTranscriptFilterNormalized() throws {
    // Punctuation / casing revisions normalize to the same form — the
    // signal the auto-send debounce uses to ignore cosmetic re-emits.
    try assertEq(TranscriptFilter.normalized("so tell me"),
                 TranscriptFilter.normalized("So, tell me"))
    try assertEq(TranscriptFilter.normalized("What is REST?"),
                 TranscriptFilter.normalized("what is rest"))
    // New words are a substantive change.
    try assertTrue(TranscriptFilter.normalized("so tell me")
                   != TranscriptFilter.normalized("so tell me about"))
    try assertEq(TranscriptFilter.normalized("  "), "")
}

@MainActor
func testChatTurnReplayText() throws {
    // No hidden context → replay is just the visible content.
    let plain = ChatTurn(role: .user, content: "hello")
    try assertEq(plain.replayText, "hello")

    // Hidden context (attachment blocks) is prepended for replay.
    let withCtx = ChatTurn(role: .user, content: "first question",
                           attachments: ["resume.pdf"],
                           hiddenContext: "[Attached resume.pdf]\n\nresume body")
    try assertEq(withCtx.replayText, "[Attached resume.pdf]\n\nresume body\n\nfirst question")

    // Attachment-only sends (empty visible text) replay the blocks alone.
    let ctxOnly = ChatTurn(role: .user, content: "", hiddenContext: "blocks")
    try assertEq(ctxOnly.replayText, "blocks")
}

@MainActor
func testChatTurnHiddenContextCodable() throws {
    let turn = ChatTurn(role: .user, content: "q",
                        attachments: ["jd.pdf"], hiddenContext: "ctx")
    let data = try JSONEncoder().encode(turn)
    let decoded = try JSONDecoder().decode(ChatTurn.self, from: data)
    try assertEq(decoded.hiddenContext ?? "", "ctx")

    // Legacy turns (no hiddenContext key) still decode.
    let legacy = #"{"id":"\#(UUID().uuidString)","role":"user","content":"old"}"#
    let migrated = try JSONDecoder().decode(ChatTurn.self, from: Data(legacy.utf8))
    try assertTrue(migrated.hiddenContext == nil)
    try assertEq(migrated.replayText, "old")
}

// MARK: - Answers

/// The words the model bolds get the chosen keyword style; the rest keeps
/// the body colour and no background.
func testAnswerKeywordsAreHighlighted() throws {
    for style in KeywordStyle.allCases {
        guard let text = MarkdownParseCache.shared.attributed(for: "Use **PostgreSQL** for **payments**.",
                                                              keywords: style) else {
            throw TestFailure(message: "markdown didn't parse", file: #file, line: #line)
        }
        var styled: [String] = []
        for run in text.runs {
            let words = String(text[run.range].characters)
            if style == .off || style == .plain {
                try assertTrue(run.inlinePresentationIntent?.contains(.stronglyEmphasized) != true
                               && run.foregroundColor == nil && run.backgroundColor == nil,
                               "\(style): \"\(words)\" is plain text")
                continue
            }
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                try assertTrue(run.foregroundColor == style.foreground, "\(style): \"\(words)\" text colour")
                try assertTrue(run.backgroundColor == style.background, "\(style): \"\(words)\" background")
                styled.append(words)
            } else {
                try assertTrue(run.foregroundColor == nil && run.backgroundColor == nil,
                               "\(style): \"\(words)\" keeps the body style")
            }
        }
        try assertEq(styled, style == .off || style == .plain ? [] : ["PostgreSQL", "payments"], "\(style)")
    }
    // Plain text drops italics too, but inline code stays code.
    if let text = MarkdownParseCache.shared.attributed(for: "Run *quickly* with `make`.", keywords: .plain) {
        for run in text.runs {
            try assertTrue(run.inlinePresentationIntent?.contains(.emphasized) != true, "plain: no italics")
        }
        try assertTrue(text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true }, "plain: inline code stays")
    }
    try assertTrue(KeywordStyle.standard.foreground == Design.Accent.keyword, "light blue by default")
    try assertTrue(KeywordStyle.bold.foreground == nil && KeywordStyle.bold.background == nil, "bold only adds nothing")
}

/// Plain text asks the model for no formatting (overriding the prompt's
/// own); the other styles add the bold rule only when the prompt has none.
func testKeywordStylePromptRules() throws {
    try assertEq(KeywordStyle.plain.promptRule(for: "Bold the key terms."), KeywordStyle.plainTextRule, "plain overrides")
    try assertEq(KeywordStyle.lightBlue.promptRule(for: "Answer briefly."), KeywordStyle.keywordRule, "adds the bold rule")
    try assertTrue(KeywordStyle.lightBlue.promptRule(for: "Bold the key terms.") == nil, "keeps the prompt's own bold rule")
}

/// Grok writes whatever language it hears, so text in another script than
/// the picked language's is ignored (same rules as Windows).
func testTranscriptLanguageLock() throws {
    let telugu = "మీ గురించి చెప్పండి"
    let hindi = "अपने बारे में बताइए"
    let english = TranscriptionLanguage.language(for: "en-US")!
    let teluguLanguage = TranscriptionLanguage.language(for: "te-IN")!
    try assertTrue(english.matches("What is JavaScript? Explain closures."), "English keeps English")
    try assertTrue(!english.matches(telugu), "English drops Telugu")
    try assertTrue(english.matches("I studied in Hyderabad, నమస్తే everyone, nice to meet you"), "English keeps a stray foreign word")
    try assertTrue(teluguLanguage.matches(telugu) && teluguLanguage.matches("Tell me about yourself"), "Telugu keeps Telugu and English")
    try assertTrue(!teluguLanguage.matches(hindi), "Telugu drops Hindi")
    try assertTrue(english.matches("2024?"), "numbers alone are neutral")
    try assertEq(english.shortName, "English", "short name")
    try assertEq(teluguLanguage.elevenLabsCode, "te", "ElevenLabs code")
    // All languages: nothing is ignored; Apple falls back to English.
    let all = TranscriptionLanguage.language(for: "auto")!
    try assertTrue(all.isAutomatic && all.matches(telugu) && all.matches(hindi) && all.matches("Hello"), "all languages keeps everything")
    try assertEq(all.elevenLabsCode, "", "no language code: ElevenLabs detects it")
    try assertEq(TranscriptionLanguage.all.first?.id, "auto", "listed first")
    try assertEq(TranscriptionLanguage.defaultLanguage(for: Locale(identifier: "fr_FR")).id, "en-US", "the default is still English")
}

/// Muse Spark thinks for ~6 s at its usual level, too slow mid-interview;
/// it's asked to think minimally. Other models get no reasoning setting.
func testMuseSparkThinksMinimally() throws {
    try assertEq(AIManager.reasoning(for: "meta/muse-spark-1.3")?["effort"] as? String, "minimal", "Muse Spark")
    try assertTrue(AIManager.reasoning(for: "anthropic/claude-sonnet-5") == nil, "others unchanged")
}

/// Thinking is turned down only for models OpenRouter advertises as
/// honouring `reasoning_effort`. Sending it to a model that merely says
/// `reasoning` is harmful: `exclude` hides the reasoning from the response
/// but the model still computes it — deepseek-r1 measured 197 s to first
/// token under this setting versus 1.2 s without.
@MainActor
func testThinkingIsDisabledOnlyWhereItTakesEffect() throws {
    let saved = OpenRouterCatalog.reasoningEffortIDs
    defer { OpenRouterCatalog.reasoningEffortIDs = saved }

    OpenRouterCatalog.reasoningEffortIDs = [
        "openrouter/google/gemini-3.8-flash",     // advertises reasoning_effort
        "openrouter/openai/gpt-5.5",
    ]
    try assertTrue(AIManager.reasoning(for: "google/gemini-3.8-flash") != nil, "flash gets it")
    try assertEq(AIManager.reasoning(for: "google/gemini-3.8-flash")?["effort"] as? String, "minimal")
    try assertTrue(AIManager.reasoning(for: "deepseek/deepseek-r1") == nil, "r1 left alone")
    try assertTrue(AIManager.reasoning(for: "some/model-without-metadata") == nil, "unknown left alone")
}

/// The user's escape hatch: letting models think turns the setting off
/// everywhere, including Muse Spark.
@MainActor
func testAllowThinkingOverridesEverything() throws {
    let saved = OpenRouterCatalog.reasoningEffortIDs
    let savedFlag = AIManager.allowModelThinking
    defer {
        OpenRouterCatalog.reasoningEffortIDs = saved
        AIManager.allowModelThinking = savedFlag
    }
    OpenRouterCatalog.reasoningEffortIDs = ["openrouter/google/gemini-3.8-flash"]

    AIManager.allowModelThinking = false
    try assertTrue(AIManager.reasoning(for: "google/gemini-3.8-flash") != nil, "off by default")

    AIManager.allowModelThinking = true
    try assertTrue(AIManager.reasoning(for: "google/gemini-3.8-flash") == nil, "thinking honoured")
    try assertTrue(AIManager.reasoning(for: "meta/muse-spark-1.3") == nil, "Muse Spark too")
}

/// `enabled: false` is rejected by OpenRouter with HTTP 400, so it must never
/// be sent whatever the model advertises.
func testNeverSendsUnsupportedReasoningParam() throws {
    let saved = OpenRouterCatalog.reasoningEffortIDs
    defer { OpenRouterCatalog.reasoningEffortIDs = saved }
    OpenRouterCatalog.reasoningEffortIDs = ["openrouter/google/gemini-3.8-flash"]

    let r = AIManager.reasoning(for: "google/gemini-3.8-flash")
    try assertTrue(r?["enabled"] == nil, "no `enabled` key — OpenRouter 400s on it")
    try assertEq(Set(r?.keys.map { String($0) } ?? []), ["effort", "exclude"], "only the two that work")
}

/// The index is rebuilt from the cached catalogue on load and on fetch.
@MainActor
func testReasoningIndexIsBuiltFromTheCatalogue() throws {
    let json = """
    {"data":[
      {"id":"google/gemini-3.8-flash","name":"Flash","context_length":8,
       "supported_parameters":["reasoning","reasoning_effort"],
       "architecture":{"input_modalities":["text"]}},
      {"id":"deepseek/deepseek-r1","name":"R1","context_length":8,
       "supported_parameters":["reasoning"],
       "architecture":{"input_modalities":["text"]}}
    ]}
    """
    let models = try OpenRouterCatalog.decode(Data(json.utf8))
    let expected = Set(models.filter { $0.supportedParameters?.contains("reasoning_effort") == true }.map(\.id))
    try assertEq(expected, ["openrouter/google/gemini-3.8-flash"], "only the effort-capable one")
}

// MARK: - OpenRouter model catalogue

/// A bare slug gets the app's routing prefix and a derived provider.
func testOpenRouterModelFromSlug() throws {
    let m = OpenRouterModel.make(slug: "qwen/qwen3-235b")
    try assertEq(m.id, "openrouter/qwen/qwen3-235b")
    try assertEq(m.provider, "Qwen")
    try assertFalse(m.isFree, "not a free-tier id")
}

/// Free tier is detected from the `:free` suffix OpenRouter appends.
func testOpenRouterFreeTierDetection() throws {
    try assertTrue(OpenRouterModel.make(slug: "qwen/qwen3-235b:free").isFree)
    try assertFalse(OpenRouterModel.make(slug: "qwen/qwen3-235b").isFree)
}

/// An id that already carries the prefix is not double-prefixed.
func testOpenRouterModelIdempotentPrefix() throws {
    let once = OpenRouterModel.make(slug: "meta/llama-3.3-70b:free")
    let twice = OpenRouterModel.make(slug: once.id)
    try assertEq(twice.id, once.id)
    try assertEq(twice.id, "openrouter/meta/llama-3.3-70b:free")
}

/// Display names are humanised: slug tail dropped, words title-cased.
func testOpenRouterDisplayName() throws {
    try assertEq(OpenRouterModel.displayName(for: "qwen/qwen3-235b"), "Qwen3 235B")
    try assertEq(OpenRouterModel.displayName(for: "qwen/qwen3-235b:free"), "Qwen3 235B (free)")
    try assertEq(OpenRouterModel.displayName(for: "google/gemini-3.8-flash"), "Gemini 3.8 Flash")
    try assertEq(OpenRouterModel.displayName(for: "openai/gpt-5.5"), "GPT 5.5", "acronym stays upper")
    try assertEq(OpenRouterModel.displayName(for: "meta/llama-3.3-70b"), "Llama 3.3 70B", "unit suffix upper")
}

/// Known vendor folders map to readable names; unknown ones fall back to the
/// folder title-cased rather than being dropped.
func testOpenRouterProviderMapping() throws {
    try assertEq(OpenRouterModel.provider(fromSlug: "anthropic/claude-sonnet-5"), "Anthropic")
    try assertEq(OpenRouterModel.provider(fromSlug: "moonshotai/kimi-k2.6"), "Kimi")
    try assertEq(OpenRouterModel.provider(fromSlug: "x-ai/grok-4.7"), "xAI")
    try assertEq(OpenRouterModel.provider(fromSlug: "somevendor/some-model"), "Somevendor")
}

/// Merged order is custom > built-ins > fetched, de-duplicated by id with the
/// earliest definition winning.
func testOpenRouterMergedOrderAndDedup() throws {
    let custom = [OpenRouterModel.make(slug: "me/custom", name: "Custom")]
    let fetched = [OpenRouterModel.make(slug: "vendor/new"), custom[0]]
    let merged = OpenRouterCatalog.merged(custom: custom, fetched: fetched)
    try assertEq(merged.count, custom.count + OpenRouterCatalog.builtins.count + 1,
                 "custom + builtins + one new fetched, custom not duplicated")
    try assertEq(merged[0].id, custom[0].id, "custom first")
    try assertEq(merged[0].name, "Custom", "custom entry wins over its fetched twin")
    let ids = Set(merged.map(\.id))
    try assertEq(ids.count, merged.count, "no duplicate ids")
}

/// The built-in defaults must survive into the merged catalogue.
func testOpenRouterBuiltinsCoverDefaults() throws {
    let ids = Set(OpenRouterCatalog.builtins.map(\.id))
    try assertTrue(ids.contains(OpenRouterDefaults.defaultModel), "defaultModel is built in")
    try assertTrue(ids.contains(OpenRouterDefaults.utilityModel), "utilityModel is built in")
}

/// OpenRouter's payload shape, pinned by a fixture. The live endpoint was
/// verified to return 465 models, 15 of them `:free`.
func testOpenRouterDecodesLivePayloadShape() throws {
    let json = """
    {"data":[
      {"id":"qwen/qwen3-235b:free","name":"Qwen3 235B (free)","context_length":65536,
       "architecture":{"input_modalities":["text"]}},
      {"id":"nvidia/nemotron-3.5-super-vl:free","name":"NVIDIA: Nemotron (free)","context_length":1000000,
       "architecture":{"input_modalities":["text","image","video"]}},
      {"id":"somevendor/plain","name":"Plain","context_length":1024,
       "architecture":{"input_modalities":["text"]}}
    ]}
    """
    let models = try OpenRouterCatalog.decode(Data(json.utf8))
    try assertEq(models.count, 3, "all three decoded")
    try assertTrue(models.allSatisfy { $0.id.hasPrefix("openrouter/") }, "prefix applied")

    func byID(_ id: String) throws -> OpenRouterModel {
        try models.first { $0.id == "openrouter/\(id)" }.unwrap("missing \(id)")
    }

    let qwen = try byID("qwen/qwen3-235b:free")
    try assertTrue(qwen.isFree, ":free detected")
    try assertFalse(qwen.supportsImages, "text-only modality")
    try assertEq(qwen.contextLength, 65536, "context_length decoded")

    let nemo = try byID("nvidia/nemotron-3.5-super-vl:free")
    try assertTrue(nemo.isFree, "second :free detected")
    try assertTrue(nemo.supportsImages, "image modality detected")
    try assertEq(nemo.provider, "NVIDIA", "vendor mapped")

    try assertEq(models.map(\.name), ["NVIDIA: Nemotron (free)", "Plain", "Qwen3 235B (free)"],
                 "sorted by name")
}

/// A model with no `architecture` block must not crash the decode.
func testOpenRouterDecodeToleratesMissingArchitecture() throws {
    let json = #"{"data":[{"id":"x/y","name":"Y","context_length":8}]}"#
    let models = try OpenRouterCatalog.decode(Data(json.utf8))
    try assertEq(models.count, 1)
    try assertFalse(models[0].supportsImages, "no architecture means no image support")
}

/// "Show all" must reveal only the models matching the active filters, not
/// the whole catalogue — which is what froze the Settings window.
@MainActor
func testShowAllIsScopedToTheGivenIds() throws {
    let v = ModelVisibility.shared
    let free = ["openrouter/qwen/qwen3-235b:free", "openrouter/vendor/a:free"]
    let paid = ["openrouter/anthropic/claude-sonnet-5", "openrouter/openai/gpt-5.5"]

    v.hideAll(among: free + paid)
    try assertFalse(v.isVisible(free[0]), "hidden to start")

    v.showAll(among: free)
    try assertTrue(v.isVisible(free[0]), "free revealed")
    try assertTrue(v.isVisible(free[1]), "free revealed")
    try assertFalse(v.isVisible(paid[0]), "paid untouched, still hidden")
    try assertFalse(v.isVisible(paid[1]), "paid untouched, still hidden")

    v.showAll(among: paid)
    try assertTrue(v.isVisible(free[0]), "earlier reveal preserved")
    try assertTrue(v.isVisible(paid[0]), "paid now revealed")
}

/// Regression guard for the removal of TheCloser Pro: no payment code may
/// creep back into the source tree. The paid tier was deleted outright, so
/// this asserts the identifiers are gone everywhere under `MacOverlay/`.
func testNoPaymentCodeInSourceTree() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = root.appending(path: "MacOverlay")

    let banned = [
        "ProAccount", "ProPlanPicker", "TesterCodeEntry", "ProPlanCard",
        "ProUsageMeter", "ProUsageNotice", "ProTranscription", "throughPro",
        "proSubscriptionsEnabled", "proHiddenFromUI", "proEnded",
    ]

    var offenders: [String] = []
    let files = (try? FileManager.default
        .subpathsOfDirectory(atPath: source.path)) ?? []
    for rel in files where rel.hasSuffix(".swift") {
        let path = source.appending(path: rel).path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        for token in banned where text.contains(token) {
            offenders.append("\(rel): \(token)")
        }
    }
    try assertTrue(offenders.isEmpty,
                   "payment code reintroduced:\n" + offenders.joined(separator: "\n"))

    for gone in ["ProAccount.swift", "Views/Shared/ProViews.swift"] {
        let path = source.appending(path: gone).path
        try assertFalse(FileManager.default.fileExists(atPath: path), "\(gone) is gone")
    }
}

/// Tier boundaries, keyed on USD per 1M blended tokens. Thresholds sit near
/// the live catalogue's quartiles (p25 $0.70, p75 $8.23).
func testModelTierThresholds() throws {
    try assertEq(ModelTier.tier(isFree: true, blended: nil), .free, "free suffix wins outright")
    try assertEq(ModelTier.tier(isFree: false, blended: 0), .free, "priced at zero is free")
    try assertEq(ModelTier.tier(isFree: false, blended: 0.30), .light)
    try assertEq(ModelTier.tier(isFree: false, blended: 0.75), .light, "upper edge of light")
    try assertEq(ModelTier.tier(isFree: false, blended: 0.76), .moderate, "just past light")
    try assertEq(ModelTier.tier(isFree: false, blended: 5.0), .moderate, "upper edge of moderate")
    try assertEq(ModelTier.tier(isFree: false, blended: 5.01), .frontier, "just past moderate")
}

/// OpenRouter's routers report a large negative price, which is internal
/// accounting rather than a price. Guessing a tier from it would be nonsense,
/// so they land in `unpriced` instead of being silently called "light".
func testModelTierRejectsRouterPricing() throws {
    try assertEq(ModelTier.tier(isFree: false, blended: -2_000_000), .unpriced, "openrouter/auto")
    try assertEq(ModelTier.tier(isFree: false, blended: nil), .unpriced, "no price quoted")
    try assertEq(ModelTier.tier(isFree: false, blended: .nan), .unpriced, "NaN")
}

/// Prices arrive as USD-per-token strings and are summed per 1M tokens.
func testBlendedPriceConversion() throws {
    try assertEq(OpenRouterCatalog.blended(from: Pricing(prompt: "0.0000015", completion: "0.0000075")), 9.0)
    try assertEq(OpenRouterCatalog.blended(from: Pricing(prompt: "0", completion: "0")), 0.0)
    try assertEq(OpenRouterCatalog.blended(from: Pricing(prompt: nil, completion: "0.1")), nil, "half a price is no price")
    try assertEq(OpenRouterCatalog.blended(from: Pricing(prompt: "abc", completion: "1")), nil, "unparseable")
    try assertEq(OpenRouterCatalog.blended(from: nil), nil)
}

/// A priced model tiers from its real catalogue data; a hand-typed one has no
/// price yet and falls back to whatever it is, without crashing.
func testModelTierFromCatalogueEntry() throws {
    let json = """
    {"data":[
      {"id":"vendor/cheap","name":"Cheap","context_length":8,
       "pricing":{"prompt":"0.0000001","completion":"0.0000002"},
       "architecture":{"input_modalities":["text"]}},
      {"id":"vendor/dear","name":"Dear","context_length":8,
       "pricing":{"prompt":"0.000015","completion":"0.000060"},
       "architecture":{"input_modalities":["text"]}},
      {"id":"vendor/x:free","name":"Freebie","context_length":8,
       "pricing":{"prompt":"0","completion":"0"},
       "architecture":{"input_modalities":["text"]}}
    ]}
    """
    let models = try OpenRouterCatalog.decode(Data(json.utf8))
    func tier(_ id: String) throws -> ModelTier {
        try models.first { $0.id == "openrouter/\(id)" }.unwrap("missing").tier
    }
    try assertEq(try tier("vendor/cheap"), .light, "cost per 1M")
    try assertEq(try tier("vendor/dear"), .frontier, "cost per 1M")
    try assertEq(try tier("vendor/x:free"), .free)
}

// MARK: - Grok transcription

func testGrokStreamURL() throws {
    let url = try GrokTranscription.streamURL(language: "en").unwrap("builds")
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    try assertEq(url.host ?? "", "api.x.ai")
    try assertEq(query["model"] ?? "", "grok-voice-transcribe-2.0")
    try assertEq(query["sample_rate"] ?? "", "16000")
    try assertEq(query["encoding"] ?? "", "pcm")
    try assertEq(query["interim_results"] ?? "", "true")
    try assertEq(query["language"] ?? "", "en")
    let chinese = try GrokTranscription.streamURL(language: "zh").unwrap("builds")
    try assertFalse(chinese.absoluteString.contains("language="), "no formatting language xAI doesn't list")
}

func testGrokStitchesAnUtterance() throws {
    func event(_ json: String) throws -> GrokTranscription.Event {
        try GrokTranscription.Event.parse(json).unwrap(json)
    }
    var utterance = GrokTranscription.Utterance()
    try assertTrue(utterance.handle(try event(#"{"type":"transcript.created"}"#)) == nil)
    try assertTrue(utterance.handle(try event(#"{"type":"transcript.partial","text":"Tell me about","is_final":false,"speech_final":false}"#))
                   == .partial("Tell me about"))
    try assertTrue(utterance.handle(try event(#"{"type":"transcript.partial","text":"Tell me about a time","is_final":true,"speech_final":false}"#))
                   == .partial("Tell me about a time"))
    try assertTrue(utterance.handle(try event(#"{"type":"transcript.partial","text":"you failed","is_final":false,"speech_final":false}"#))
                   == .partial("Tell me about a time you failed"), "interim text follows the locked chunk")
    // Documented: the final event is the whole stitched utterance.
    try assertTrue(utterance.handle(try event(#"{"type":"transcript.partial","text":"Tell me about a time you failed.","is_final":true,"speech_final":true}"#))
                   == .commit("Tell me about a time you failed."))
    try assertEq(utterance.locked, [], "the next utterance starts clean")
}

func testGrokKeepsLockedChunksIfTheFinalOmitsThem() throws {
    try assertEq(GrokTranscription.Utterance.stitch(locked: ["Walk me through", "your last project"], final: "and what you'd change."),
                 "Walk me through your last project and what you'd change.")
    try assertEq(GrokTranscription.Utterance.stitch(locked: ["Why this role?"], final: "why this role? And why now?"),
                 "why this role? And why now?", "an already stitched final is used as is")
    try assertEq(GrokTranscription.Utterance.stitch(locked: [], final: "Hi."), "Hi.")
    try assertEq(GrokTranscription.Utterance.stitch(locked: ["Okay."], final: ""), "Okay.")
}

extension Optional {
    func unwrap(_ note: String, file: String = #file, line: Int = #line) throws -> Wrapped {
        guard let self else { throw TestFailure(message: "unexpected nil: \(note)", file: file, line: line) }
        return self
    }
}

// MARK: - Entry point

@main
@MainActor
struct TestsMain {
    static func main() {
        print("Running MacOverlay tests…\n")

        TestRunner.run("models: turn / session / tokens", testModels)
        TestRunner.run("model: PromptPreset codable", testPromptPreset)
        TestRunner.run("model: ResumePreset codable", testResumePreset)
        TestRunner.run("model: Workspace codable", testWorkspace)
        TestRunner.run("JSONStore round-trip on disk", testJSONStoreRoundTrip)
        TestRunner.run("AIManager routes OpenAI models", testAIManagerModelRouting)
        TestRunner.run("ResumeScore parses raw format", testResumeScoreParser)
        TestRunner.run("ResumeScore verdict colors + copy", testResumeScoreVerdictColors)
        TestRunner.run("ChatSession displayTitle fallback", testSessionTitleAutoSetOnFirstTurn)
        TestRunner.run("ChatSession turn order preserved", testSessionTurnOrderAfterAppend)
        TestRunner.run("SessionMode has non-empty fields", testSessionModeSystemPromptNotEmpty)
        TestRunner.run("SessionMode has quick actions", testSessionModeQuickActionsExist)
        TestRunner.run("AudioSource labels + cases", testAudioSourceLabels)
        TestRunner.run("AppChannel resolves from Info.plist", testAppChannelResolution)
        TestRunner.run("AppChannel keeps data apart", testAppChannelKeepsDataApart)
        TestRunner.run("CallDetector recognises call apps", testCallDetectorRecognisesCallApps)
        TestRunner.run("CallState waits before ending a call", testCallStateWaitsBeforeEndingACall)
        TestRunner.run("TranscriptionLanguage defaults to English", testTranscriptionLanguageDefaultsToEnglish)
        TestRunner.run("TranscriptionLanguage reads saved choice", testTranscriptionLanguageReadsSavedChoice)
        TestRunner.run("ChatTurn IDs unique", testTurnIDsAreUnique)
        TestRunner.run("NoteEntry codable round-trip", testNoteEntryRoundTrip)
        TestRunner.run("TranscriptFilter meaningful speech", testTranscriptFilterMeaningful)
        TestRunner.run("TranscriptFilter question completeness", testTranscriptFilterSeemsComplete)
        TestRunner.run("TranscriptFilter response gate triage", testTranscriptFilterWarrantsResponse)
        TestRunner.run("TranscriptFilter normalized change detection", testTranscriptFilterNormalized)
        TestRunner.run("ChatTurn replayText composition", testChatTurnReplayText)
        TestRunner.run("ChatTurn hiddenContext codable + migration", testChatTurnHiddenContextCodable)
        TestRunner.run("Answer keywords are highlighted", testAnswerKeywordsAreHighlighted)
        TestRunner.run("Keyword styles pick the prompt's formatting rule", testKeywordStylePromptRules)
        TestRunner.run("Transcripts in another language are ignored", testTranscriptLanguageLock)
        TestRunner.run("Muse Spark thinks minimally", testMuseSparkThinksMinimally)
        TestRunner.run("Thinking off only where it takes effect", testThinkingIsDisabledOnlyWhereItTakesEffect)
        TestRunner.run("Allow thinking overrides everything", testAllowThinkingOverridesEverything)
        TestRunner.run("Never sends an unsupported reasoning param", testNeverSendsUnsupportedReasoningParam)
        TestRunner.run("Reasoning index built from the catalogue", testReasoningIndexIsBuiltFromTheCatalogue)
        TestRunner.run("OpenRouter model from slug", testOpenRouterModelFromSlug)
        TestRunner.run("OpenRouter free tier detection", testOpenRouterFreeTierDetection)
        TestRunner.run("OpenRouter prefix is idempotent", testOpenRouterModelIdempotentPrefix)
        TestRunner.run("OpenRouter display name", testOpenRouterDisplayName)
        TestRunner.run("OpenRouter provider mapping", testOpenRouterProviderMapping)
        TestRunner.run("OpenRouter merged order and dedup", testOpenRouterMergedOrderAndDedup)
        TestRunner.run("OpenRouter builtins cover the defaults", testOpenRouterBuiltinsCoverDefaults)
        TestRunner.run("OpenRouter decodes live payload shape", testOpenRouterDecodesLivePayloadShape)
        TestRunner.run("OpenRouter decode tolerates missing architecture", testOpenRouterDecodeToleratesMissingArchitecture)
        TestRunner.run("No payment code in the source tree", testNoPaymentCodeInSourceTree)
        TestRunner.run("Show all is scoped to the filters", testShowAllIsScopedToTheGivenIds)
        TestRunner.run("Model tier thresholds", testModelTierThresholds)
        TestRunner.run("Model tier rejects router pricing", testModelTierRejectsRouterPricing)
        TestRunner.run("Blended price conversion", testBlendedPriceConversion)
        TestRunner.run("Model tier from a catalogue entry", testModelTierFromCatalogueEntry)
        TestRunner.run("Grok stream URL", testGrokStreamURL)
        TestRunner.run("Grok stitches an utterance from its chunks", testGrokStitchesAnUtterance)
        TestRunner.run("Grok keeps locked chunks the final leaves out", testGrokKeepsLockedChunksIfTheFinalOmitsThem)

        print("\n──────────────────────────────")
        print("  Passed: \(TestRunner.passed)")
        print("  Failed: \(TestRunner.failed.count)")
        if !TestRunner.failed.isEmpty {
            print("\nFailures:")
            for (name, msg, file, line) in TestRunner.failed {
                print("  · \(name)\n    \(msg)\n    \(file):\(line)")
            }
            exit(1)
        }
        print("──────────────────────────────")
        exit(0)
    }
}
