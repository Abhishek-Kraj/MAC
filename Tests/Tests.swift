import AppKit
import CoreText
import Foundation
import PDFKit

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

/// Float comparison with an absolute tolerance. Plain `assertEq` on doubles
/// is almost always the wrong tool — cosine similarities are never exact.
func assertClose(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9,
                 _ note: String = "", file: String = #file, line: Int = #line) throws {
    if !(abs(a - b) <= tolerance) {
        throw TestFailure(message: "\(a) != \(b) within \(tolerance)  \(note)", file: file, line: line)
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

/// The catalogue refreshes itself, so a stale snapshot cannot silently sit
/// there listing free models OpenRouter has already retired.
@MainActor
func testCatalogueStartsStale() throws {
    let c = OpenRouterCatalog.shared
    try assertTrue(c.fetched.isEmpty, "test starts from an empty cache")
    try assertTrue(c.isStale, "never fetched counts as stale")
    try assertEq(c.ageDescription, "never fetched")
    try assertTrue(c.retired.isEmpty, "nothing retired before any fetch")
}

/// Age wording drives the "list may be out of date" warning, so the
/// thresholds are pinned here rather than left to a live fetch.
@MainActor
func testCatalogueAgeWording() throws {
    let hour: TimeInterval = 3600
    let day = hour * 24
    let now = Date()
    func at(_ ago: TimeInterval) -> String {
        OpenRouterCatalog.ageDescription(since: now.addingTimeInterval(-ago))
    }
    try assertEq(at(0),    "just now")
    try assertEq(at(300),  "5 min ago")
    try assertEq(at(hour * 6), "6h ago")
    try assertEq(at(day * 3),  "3d ago")
    try assertEq(at(day * 30), "over a week ago")
    try assertEq(OpenRouterCatalog.ageDescription(since: nil), "never fetched")
}

/// A malformed body must fail loudly rather than quietly emptying the
/// catalogue — which would read as "OpenRouter retired all 465 models".
@MainActor
func testMalformedCatalogueFailsRatherThanEmptying() throws {
    var threw = false
    do { _ = try OpenRouterCatalog.decode(Data("not json".utf8)) }
    catch { threw = true }
    try assertTrue(threw, "garbage body throws instead of decoding to empty")
    try assertTrue(OpenRouterCatalog.shared.retired.isEmpty, "a failed fetch retires nothing")
}

/// A cache written by an older build is missing fields the current code
/// reads, so it must be refetched even when it is only hours old. Without
/// this the tier badges and reasoning index stay empty against a cache that
/// looks current — which is exactly what happened in the field.
@MainActor
func testCatalogueSchemaInvalidatesOldCaches() throws {
    let now = Date()
    let hour: TimeInterval = 3600
    let current = 2, older = 1

    // Never fetched.
    try assertTrue(OpenRouterCatalog.isStale(fetchedAt: nil, schema: current, now: now))
    // Fresh, but written by a build whose shape differs.
    try assertTrue(OpenRouterCatalog.isStale(fetchedAt: now, schema: older, now: now),
                   "older schema is stale regardless of age")
    // Current schema and recent.
    try assertFalse(OpenRouterCatalog.isStale(fetchedAt: now.addingTimeInterval(-hour),
                                              schema: current, now: now))
    // Current schema but older than the threshold.
    try assertTrue(OpenRouterCatalog.isStale(fetchedAt: now.addingTimeInterval(-hour * 30),
                                             schema: current, now: now))
    // No schema recorded at all reads as older, not current.
    try assertTrue(OpenRouterCatalog.isStale(fetchedAt: now, schema: 0, now: now),
                   "absent schema must not be treated as current")
}

/// Fetched models are hidden from the picker by default so 465 rows do not
/// become the menu — but the built-ins, hand-added models and the current
/// selection must survive that.
@MainActor
func testFetchedModelsAreHiddenButSelectionSurvives() throws {
    let v = ModelVisibility.shared
    defer { v.showAll() }

    v.showAll()
    UserDefaults.standard.set("openrouter/anthropic/claude-sonnet-5", forKey: "selectedModel")

    let catalog = OpenRouterCatalog.shared
    let fetched = [
        OpenRouterModel(id: "openrouter/vendor/new", name: "New", provider: "Vendor",
                        supportsImages: false, isFree: true,
                        contextLength: 8, supportedParameters: [], blendedPrice: 0),
        OpenRouterModel(id: "openrouter/anthropic/claude-sonnet-5", name: "Sonnet",
                        provider: "Anthropic", supportsImages: true, isFree: false,
                        contextLength: 8, supportedParameters: [], blendedPrice: 9),
    ]
    catalog.hideForTesting(fetched)

    try assertFalse(v.isVisible("openrouter/vendor/new"), "new fetched model hidden")
    try assertTrue(v.isVisible("openrouter/anthropic/claude-sonnet-5"), "the selected model stays visible")
    try assertTrue(v.isVisible("openrouter/openai/gpt-5.5"), "built-in defaults stay visible")
}

/// Settings -> AI and the overlay's picker read the same `ModelFilterStore`,
/// which is what stopped them disagreeing about which models exist. Filtering
/// itself must also match on provider, or typing a vendor name in the picker
/// would find nothing.
@MainActor
func testSharedModelFilterStore() throws {
    let store = ModelFilterStore.shared
    defer { store.reset() }

    store.reset()
    try assertFalse(store.isFiltering, "a fresh store filters nothing")

    // Not free: a `:free` model is tiered `.free` regardless of price, so a
    // fixture marked free would never appear under a Light filter.
    let cheap = OpenRouterModel(id: "openrouter/v/cheap", name: "Cheap Thing",
                                provider: "Vendor", supportsImages: false, isFree: false,
                                contextLength: 8, supportedParameters: nil, blendedPrice: 0.2)
    let pricey = OpenRouterModel(id: "openrouter/v/dear", name: "Dear Thing",
                                 provider: "Vendor", supportsImages: true, isFree: false,
                                 contextLength: 8, supportedParameters: nil, blendedPrice: 40)
    let all = [cheap, pricey]

    func countMatching() -> Int { all.filter { store.matches($0) }.count }

    try assertEq(countMatching(), 2, "no filter passes both")

    store.tier = .light
    try assertEq(countMatching(), 1, "tier narrows it")
    try assertTrue(store.isFiltering)

    store.tier = nil
    store.imagesOnly = true
    try assertEq(countMatching(), 1, "images-only keeps the one that reads images")

    store.imagesOnly = false
    store.reset()
    store.tier = .free
    let freeModel = OpenRouterModel(id: "openrouter/v/free", name: "Freebie",
                                    provider: "Vendor", supportsImages: false, isFree: true,
                                    contextLength: 8, supportedParameters: nil, blendedPrice: 0)
    try assertTrue(store.matches(freeModel), "a :free model is tiered free")
    try assertFalse(store.matches(cheap), "a cheap paid model is not free")

    store.reset()
    store.search = "cheap"
    try assertEq(countMatching(), 1, "search by name")

    store.search = "vendor"
    try assertEq(countMatching(), 2, "search by provider is case- and accent-insensitive")

    store.search = "dear"
    try assertEq(countMatching(), 1, "search by the other name")

    store.reset()
    try assertEq(countMatching(), 2, "reset clears everything")
}

/// The panel could not be dragged onto a second display because
/// `constrainFrameRect` fell back to `NSScreen.main` — the screen holding
/// key focus — and clamped the frame back to it. The target is now resolved
/// from the frame being requested.
///
/// Uses synthetic screen rects, so this runs without a second display
/// attached.
func testPanelCanMoveBetweenDisplays() throws {
    // Built-in on the left, external 1920x1080 to its right.
    let builtIn  = NSRect(x: 0,    y: 0, width: 1512, height: 945)
    let external = NSRect(x: 1512, y: 0, width: 1920, height: 1080)
    let screens = [builtIn, external]

    // Sitting on the built-in display.
    let onBuiltIn = NSRect(x: 100, y: 400, width: 400, height: 200)
    try assertEq(ScreenPlacement.bestScreenIndex(for: onBuiltIn, screens: screens), 0,
                 "starts on the built-in display")

    // Straddling the boundary. 1200..1600 overlaps the built-in by 312pt and
    // the external by only 88pt, so the built-in display wins on area.
    let mostlyBuiltIn = NSRect(x: 1200, y: 400, width: 400, height: 200)
    try assertEq(ScreenPlacement.bestScreenIndex(for: mostlyBuiltIn, screens: screens), 0,
                 "mostly on the built-in display while straddling")

    // The same boundary, tipped the other way: 1400..1800 gives 112pt to the
    // built-in and 288pt to the external, so the external now wins. This is
    // the rule doing real work, not a tie-break.
    let mostlyExternal = NSRect(x: 1400, y: 400, width: 400, height: 200)
    try assertEq(ScreenPlacement.bestScreenIndex(for: mostlyExternal, screens: screens), 1,
                 "crossed the midpoint while straddling")

    // Dragged well onto the external display — the case that used to snap back.
    let onExternal = NSRect(x: 2000, y: 400, width: 400, height: 200)
    try assertEq(ScreenPlacement.bestScreenIndex(for: onExternal, screens: screens), 1,
                 "fully on the external display resolves to it")

    // Nudged off the right-hand edge: nearest screen, not the focused one.
    let pastEdge = NSRect(x: 3900, y: 400, width: 400, height: 200)
    try assertEq(ScreenPlacement.bestScreenIndex(for: pastEdge, screens: screens), 1,
                 "off-screen frame snaps to the nearest display")

    // Off the left edge of the leftmost display.
    let pastLeft = NSRect(x: -900, y: 400, width: 400, height: 200)
    try assertEq(ScreenPlacement.bestScreenIndex(for: pastLeft, screens: screens), 0,
                 "off the left edge snaps to the leftmost display")

    // A single display is unaffected.
    try assertEq(ScreenPlacement.bestScreenIndex(for: onExternal, screens: [builtIn]), 0,
                 "single display always wins")
    try assertEq(ScreenPlacement.bestScreenIndex(for: onBuiltIn, screens: []), nil,
                 "no screens, no answer")
}

/// Displays stacked vertically rather than side by side — the same clamp
/// must not pin the panel to the focused screen there either.
func testPanelMovesBetweenVerticallyStackedDisplays() throws {
    let top = NSRect(x: 0, y: 1080, width: 1920, height: 1080)
    let bottom = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    let screens = [bottom, top]

    try assertEq(ScreenPlacement.bestScreenIndex(
        for: NSRect(x: 100, y: 1500, width: 400, height: 200), screens: screens), 1, "on the top display")
    try assertEq(ScreenPlacement.bestScreenIndex(
        for: NSRect(x: 100, y: 100,  width: 400, height: 200), screens: screens), 0, "on the bottom display")
}

/// The interview prompt used to hard-code "at most 3 short bullets" for every
/// question. Depth must now be what varies, and the shared skeleton — the
/// verbatim opener in particular — must survive all three levels, because a
/// user still has to be able to read the first line at a glance.
func testAnswerDepthScalesThePrompt() throws {
    let depths = AnswerDepth.allCases
    try assertEq(depths.count, 3, "three depths offered")

    for d in depths {
        let text = d.instruction
        try assertTrue(text.contains("FIRST LINE"),
                      "\(d.rawValue) keeps the verbatim opener")
        try assertTrue(text.lowercased().contains("verbatim"),
                       "\(d.rawValue) tells the model it is sayable")
        try assertFalse(text.contains("at most 3"),
                        "\(d.rawValue) no longer carries the old fixed cap")
        try assertTrue(text.contains("Bold"), "\(d.rawValue) still bolds keywords")
    }

    // Brief is the tightest, deep the loosest.
    try assertTrue(AnswerDepth.brief.instruction.contains("at most 2"),
                   "brief caps at two bullets")
    try assertTrue(AnswerDepth.standard.instruction.contains("2-4"),
                   "standard gives a small range")
    for marker in ["claim", "trade-off", "go wrong"] {
        try assertTrue(AnswerDepth.deep.instruction.contains(marker),
                       "deep asks for \(marker)")
    }
    // Depth must never be a length quota — that was the original sin.
    try assertTrue(AnswerDepth.deep.instruction.contains("not by a quota"),
                   "deep explicitly refuses a quota")
    try assertTrue(AnswerDepth.standard.instruction.contains("Do not pad"),
                   "standard refuses padding")

    // Distinct text per level, so the switch is doing real work.
    try assertTrue(AnswerDepth.brief.instruction != AnswerDepth.standard.instruction)
    try assertTrue(AnswerDepth.standard.instruction != AnswerDepth.deep.instruction)
}

/// The choice has to survive relaunch, and the interview prompt has to pick it
/// up — otherwise the segmented control would lie.
@MainActor
func testAnswerDepthPersistsAndFeedsThePrompt() throws {
    let key = AnswerDepth.storageKey
    let saved = UserDefaults.standard.string(forKey: key)
    defer {
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    // Default when unset.
    UserDefaults.standard.removeObject(forKey: key)
    try assertEq(AnswerDepth.current, .standard, "standard is the default")

    UserDefaults.standard.set(AnswerDepth.deep.rawValue, forKey: key)
    try assertEq(AnswerDepth.current, .deep, "saved choice is read back")

    // And the interview prompt reflects it.
    let prompt = SessionMode.interview.systemPrompt
    try assertTrue(prompt.contains("go wrong"), "interview prompt uses the deep clause")
    try assertFalse(prompt.contains("at most 2"), "not the brief clause")

    UserDefaults.standard.set(AnswerDepth.brief.rawValue, forKey: key)
    try assertTrue(SessionMode.interview.systemPrompt.contains("at most 2"),
                   "brief clause now")
}

// MARK: - Prepared question bank

/// Builds a bank from realistic Fabric-coE questions. Kept as a helper so
/// the matcher tests below all score against the same corpus.
private func sampleBank() -> [PrepQuestion] {
    let bankID = "Fabric Platform Lead"
    return [
        PrepQuestion(question: "Why move to Microsoft Fabric instead of Synapse when Synapse already does warehousing?", bankID: bankID),
        PrepQuestion(question: "How would you allocate Fabric capacity across ten legal entities with different budgets?", bankID: bankID),
        PrepQuestion(question: "How do you retire an existing Cognos estate without disrupting Finance reporting?", bankID: bankID),
        PrepQuestion(question: "When would you choose a star schema over a flat table, and why does it matter at scale?", bankID: bankID),
        PrepQuestion(question: "How do you put data pipelines in CI/CD when a pipeline run costs real money?", bankID: bankID),
        PrepQuestion(question: "A contractor needs one gold table with HR salary data. How do you deliver it safely?", bankID: bankID),
        PrepQuestion(question: "How do you chargeback compute cost to the business units that cause it?", bankID: bankID),
        PrepQuestion(question: "Walk me through your bronze, silver and gold layers and where CDC fits.", bankID: bankID),
    ]
}

/// The live matcher is judged by whether it retrieves the RIGHT bank entry
/// from a reworded question. A wrong prepared answer shown mid-interview is
/// worse than a two-second wait, so this table is the real specification.
func testPrepMatcherRetrievesTheRightQuestion() throws {
    let bank = sampleBank()
    // (what the interviewer says, the bank entry it must find)
    let cases: [(String, String)] = [
        ("Isn't Fabric just Synapse with a new name?", "Why move to Microsoft Fabric instead of Synapse when Synapse already does warehousing?"),
        ("You have ten business units with separate P&Ls, how would you split the F-SKU capacity?", "How would you allocate Fabric capacity across ten legal entities with different budgets?"),
        ("We have a big Cognos estate. How do you get rid of it without breaking month-end close?", "How do you retire an existing Cognos estate without disrupting Finance reporting?"),
        ("When is a star schema better than one big flat table?", "When would you choose a star schema over a flat table, and why does it matter at scale?"),
        ("How do you version and test data pipelines automatically?", "How do you put data pipelines in CI/CD when a pipeline run costs real money?"),
        ("How do you let an outside contractor see HR salaries without leaking it?", "A contractor needs one gold table with HR salary data. How do you deliver it safely?"),
        ("How do you make teams pay for the compute they burn?", "How do you chargeback compute cost to the business units that cause it?"),
        ("Explain bronze silver gold, and where change data capture sits.", "Walk me through your bronze, silver and gold layers and where CDC fits."),
    ]
    // The contract that matters: a prepared answer is shown only when it is
    // the RIGHT one. Refusing to answer is always acceptable; answering with
    // the wrong bank entry never is.
    var shown = 0, refused = 0
    for (heard, expected) in cases {
        guard let hit = PrepMatcher.best(query: heard, against: bank) else {
            refused += 1
            continue
        }
        shown += 1
        try assertEq(hit.question.question, expected,
                     "showed the WRONG prepared answer for: \(heard)")
    }
    try assertTrue(shown >= 6,
                  "ranker should answer most of these (got \(shown), refused \(refused))")
    print("  shown \(shown)/8, safely refused \(refused)/8")
}

/// Below the confidence gate the matcher must return nothing, so the app
/// generates an answer instead of showing a weak guess.
func testPrepMatcherRefusesWeakMatches() throws {
    let bank = sampleBank()
    // Nothing in the bank is about onboarding a new hire.
    for unrelated in [
        "How do you onboard a new engineer onto the team?",
        "What is your favourite holiday destination?",
        "Tell me about your university dissertation.",
    ] {
        try assertTrue(PrepMatcher.best(query: unrelated, against: bank) == nil,
                       "should have refused: \(unrelated)")
    }
    // And a genuine question still gets through.
    let hit = PrepMatcher.best(query: "When is a star schema better than one big flat table?",
                               against: bank)
    try assertTrue(hit != nil, "a real question must still match")
}

/// The one confusion this design has to survive: two bank entries about
/// overlapping subject matter — allocating capacity, and charging it back —
/// share enough vocabulary to rank either way. Asked about capacity
/// allocation, the chargeback entry scored *higher* than the right one, and
/// beat it by only a small margin. This must refuse rather than guess.
func testPrepMatcherRefusesAdjacentTopics() throws {
    let bank = sampleBank()
    let heard = "You have ten business units with separate P&Ls, how would you split the F-SKU capacity?"
    let right = "How would you allocate Fabric capacity across ten legal entities with different budgets?"

    // Ranking may well put the wrong entry first — the point is that it must
    // not be *trusted*.
    let hit = PrepMatcher.best(query: heard, against: bank)
    if let hit {
        try assertEq(hit.question.question, right,
                     "capacity question must never yield the chargeback answer")
    }

    // And whatever it decides, the decision has to be on margin, not score:
    // the wrong answer here outscores the right one.
    let ranked = PrepMatcher.rank(query: heard, against: bank)
    try assertTrue(ranked.first?.margin ?? 0 < PrepMatcher.minimumMargin,
                   "this case is below the gate by construction")
}

/// Morphology is why this needed a stemmer at all: "salary" and "salaries"
/// share no token, and without stemming that question retrieved the Cognos
/// entry instead of the PII one.
func testPrepMatcherHandlesMorphology() throws {
    try assertEq(PrepMatcher.stem("salaries"), "salary")
    try assertEq(PrepMatcher.stem("salary"),  "salary")
    try assertEq(PrepMatcher.stem("migrations"), "migration")
    try assertEq(PrepMatcher.stem("policies"), "policy")
    // Short words must survive: over-stripping turns "press" into "pre".
    try assertEq(PrepMatcher.stem("press"), "press")
    try assertEq(PrepMatcher.stem("business"), "business")
    try assertEq(PrepMatcher.stem("less"), "less")

    // And the PII question, phrased with the plural, finds the PII entry.
    let bank = sampleBank()
    let hit = PrepMatcher.closest(
        query: "How do you let an outside contractor see HR salaries without leaking it?",
        against: bank)
    try assertTrue(hit?.question.question.contains("HR salary") == true,
                   "plural 'salaries' must reach the singular 'salary' entry")
}

/// An empty or nonsense bank must not crash or match.
func testPrepMatcherHandlesEmptyAndOddInput() throws {
    try assertTrue(PrepMatcher.rank(query: "anything", against: []).isEmpty, "empty bank")
    try assertTrue(PrepMatcher.best(query: "", against: sampleBank()) == nil, "empty query")
    try assertTrue(PrepMatcher.best(query: "   ", against: sampleBank()) == nil, "blank query")
    try assertTrue(PrepMatcher.best(query: "?!?!", against: sampleBank()) == nil, "punctuation only")
    try assertTrue(PrepMatcher.best(query: "the a of to", against: sampleBank()) == nil, "stop words only")
}

/// The bank has to survive a relaunch, or a prepared answer prepared this
/// morning is gone by the interview.
@MainActor
func testPrepBankPersistsAndGroupsByRole() throws {
    let bank = PrepBank.shared
    let before = bank.questions.count

    let added = PrepQuestion(question: "Test: how would you split capacity?",
                             bankID: "ZZ Test Role")
    bank.add(added)
    defer {
        bank.delete(added)
        try? assertTrue(bank.questions.count == before, "cleaned up")
    }

    try assertEq(PrepBank.shared.questions(inBank: "ZZ Test Role").count, 1, "grouped by role")
    try assertTrue(PrepBank.shared.banks.contains { $0.id == "ZZ Test Role" }, "bank listed")
    try assertTrue(bank.hasBank(forRole: "ZZ Test Role"), "hasBank true for the role")
    try assertFalse(bank.hasBank(forRole: "A Role That Does Not Exist"), "hasBank false otherwise")
}

/// A bank is scoped to a role, not a posting — that is what makes it compound.
@MainActor
func testBankIsKeyedByRoleNotByPosting() throws {
    let bank = PrepBank.shared
    let tag = UUID().uuidString.prefix(8)
    let q1 = PrepQuestion(question: "ZZJDA \(tag) capacity split?", bankID: "Fabric Platform Lead")
    let q2 = PrepQuestion(question: "ZZJDB \(tag) capacity split?", bankID: "Fabric Platform Lead")
    bank.add(questions: [q1, q2])
    defer {
        bank.delete(q1); bank.delete(q2)
    }
    let hits = bank.questions(inBank: "Fabric Platform Lead").filter { $0.question.contains("\(tag) capacity split") }
    try assertEq(hits.count, 2, "two postings' questions share one role bank")
}

/// Match bookkeeping is how the user learns which questions actually get
/// asked — without it the bank can never be pruned.
@MainActor
func testBankRecordsMatches() throws {
    let bank = PrepBank.shared
    let q = PrepQuestion(question: "ZZ counted question", bankID: "ZZ Count Role")
    bank.add(q)
    defer { bank.delete(q) }

    try assertEq(q.timesMatched, 0)
    bank.recordMatch(q.id)
    let updated = try bank.questions.first { $0.id == q.id }.unwrap("still there")
    try assertEq(updated.timesMatched, 1)
    try assertTrue(updated.lastMatchedAt != nil)
}

/// Questions the matcher missed are held, not silently banked — the user
/// decides whether a miss earns a permanent place.
@MainActor
func testMissedQuestionsAreCapturedNotAutoBanked() throws {
    let bank = PrepBank.shared
    let role = "ZZ Capture Role"
    let start = bank.pendingCaptureCount

    bank.captureMissed(question: "What about multi-cloud failover?", bankID: role)
    try assertEq(bank.pendingCaptureCount, start + 1, "held as pending")
    try assertEq(bank.questions(inBank: role).count, 0, "not in the bank yet")

    // Repeating the same miss must not stack duplicates.
    bank.captureMissed(question: "what about MULTI-CLOUD failover", bankID: role)
    try assertEq(bank.pendingCaptureCount, start + 1, "duplicate miss ignored")

    // Too short to be a question.
    bank.captureMissed(question: "why?", bankID: role)
    try assertEq(bank.pendingCaptureCount, start + 1, "too-short text ignored")

    let accepted = bank.acceptPendingCaptures(into: role)
    try assertEq(accepted, 1)
    try assertEq(bank.pendingCaptureCount, start, "pending cleared")
    try assertEq(bank.questions(inBank: role).first?.source, .captured, "marked as captured")
    defer { bank.deleteBank(role) }
}


/// Cosine similarity: identical vectors match exactly, orthogonal ones do
/// not, and a mismatched dimension is refused rather than silently truncated.
func testCosineSimilarity() throws {
    let a: [Double] = [1, 0, 0]
    try assertClose(PrepMatcher.cosine(a, a) ?? 0, 1.0, 1e-9, "identical")
    try assertClose(PrepMatcher.cosine(a, [0, 1, 0]) ?? 0, 0.0, 1e-9, "orthogonal")
    try assertTrue(PrepMatcher.cosine(a, [1, 0]) == nil, "dimension mismatch is nil")
    try assertTrue(PrepMatcher.cosine([], []) == nil, "empty vectors are nil")
    try assertTrue(PrepMatcher.cosine([0, 0, 0], a) == nil, "zero vector is nil")
}

/// The semantic gate must be margin-based and must ignore questions that were
/// never embedded — an un-embedded bank has to fall through to generation, not
/// match on a zero score.
@MainActor
func testSemanticRankingSkipsUnembeddedAndGatesOnMargin() throws {
    func q(_ text: String, _ v: [Double]) -> PrepQuestion {
        PrepQuestion(question: text, bankID: "B", embedding: v)
    }
    // Two candidates; the query points far more strongly at the first.
    // Mirrored about the diagonal, so a [1, 1] query sits exactly between them.
    let strong = q("strong", [1.0, 0.2])
    let weak   = q("weak",   [0.2, 1.0])
    let none   = PrepQuestion(question: "never embedded", bankID: "B")
    let bank = [strong, weak, none]

    let ranked = PrepMatcher.semanticRank(query: [1.0, 0.0], against: bank)
    try assertEq(ranked.count, 2, "the un-embedded question is skipped entirely")
    try assertEq(ranked.first?.question.question, "strong", "best first")

    // A clear winner clears the gate.
    try assertTrue(PrepMatcher.semanticBest(query: [1.0, 0.0], against: bank) != nil,
                   "a decisive match is trusted")

    // A query sitting exactly between them must be refused, however high the
    // absolute score is — both score about 0.83.
    let between = PrepMatcher.semanticBest(query: [1.0, 1.0], against: bank)
    try assertTrue(between == nil, "an ambiguous query must not pick one")
}

/// A snapshot has to restore byte-for-byte: an interview 20 minutes away
/// cannot be rebuilt from the network.
@MainActor
func testBankBackupSnapshotsAndRestores() throws {
    let bank = PrepBank.shared
    let role = "ZZ Backup Role"
    bank.deleteBank(role)

    let originals = [
        PrepQuestion(question: "How do we size Fabric capacity?", answer: "By entity.",
                     bankID: role, embedding: [0.1, 0.2, 0.3]),
        PrepQuestion(question: "How is HR salary data protected?", answer: "Purview labels.",
                     topic: "governance", bankID: role),
    ]
    bank.add(questions: originals)

    // Adding triggers a snapshot.
    try assertTrue(PrepBankBackup.snapshots().contains { snap in
        snap.questionCount >= originals.count
    }, "a snapshot was written")

    // Wreck it, then restore.
    bank.deleteBank(role)
    try assertEq(bank.questions(inBank: role).count, 0, "bank emptied")

    let latest = try PrepBankBackup.snapshots().first
        .unwrap("a snapshot to restore")
    let restored = try PrepBankBackup.restore(from: latest.url)

    try assertTrue(restored >= originals.count, "restored a snapshot")
    let after: [PrepQuestion] = bank.questions(inBank: role)
    try assertEq(after.count, originals.count, "all questions back")
    try assertEq(after.map(\.question).sorted(), originals.map(\.question).sorted(), "questions match")
    try assertEq(after.first(where: { $0.topic == "governance" })?.answer, "Purview labels.",
                 "answers survive the round trip")
    // Vectors must survive too, or a restore still needs the network.
    try assertTrue(after.contains { $0.embedding != nil }, "embeddings survive")
    defer { bank.deleteBank(role) }
}

/// Export writes a readable, hand-editable copy; import reads it back.
@MainActor
func testBankExportRoundTrip() throws {
    let bank = PrepBank.shared
    let role = "ZZ Export Role"
    bank.deleteBank(role)
    bank.add(questions: [PrepQuestion(question: "Exported question?", answer: "Yes.",
                                      bankID: role)])
    defer { bank.deleteBank(role) }

    let dir = JSONStore.appDirectory.appendingPathComponent("zz-export.json")
    try assertTrue(PrepBankBackup.export(to: dir), "export succeeded")
    defer { try? FileManager.default.removeItem(at: dir) }

    let loaded = try PrepBankBackup.load(from: dir)
    try assertEq(loaded.count, 1, "one question exported")
    try assertEq(loaded.first?.question, "Exported question?")
    // Pretty-printed so a person can open and edit it.
    let text = try String(contentsOf: dir, encoding: .utf8)
    try assertTrue(text.contains("\n"), "exported file is pretty-printed")
}

/// Pruning must bound the snapshot count, or a long editing session fills the
/// disk.
@MainActor
func testBankBackupPrunesOldSnapshots() throws {
    for _ in 0..<(PrepBankBackup.keep + 3) { PrepBankBackup.snapshot() }
    try assertTrue(PrepBankBackup.snapshots().count <= PrepBankBackup.keep,
                   "snapshots are capped at \(PrepBankBackup.keep)")
}

/// The generator's output arrives wrapped in prose or a fenced block often
/// enough that assuming it is bare JSON would break real runs.
@MainActor
func testPrepGeneratorParsesWrappedJSON() throws {
    let clean = #"[{"q":"Q1","a":"A1","topic":"cost"}]"#
    try assertEq(PrepGenerator.parse(clean).count, 1, "bare JSON")

    let wrapped = """
    Sure! Here are your questions:
    ```json
    [{"q":"Q1","a":"A1","topic":"cost"},{"q":"Q2","a":"A2","topic":"capacity"}]
    ```
    Let me know if you want more.
    """
    let parsed = PrepGenerator.parse(wrapped)
    try assertEq(parsed.count, 2, "fenced block recovered")
    try assertEq(parsed.first?.q, "Q1")
    try assertEq(parsed.last?.topic, "capacity")

    // Garbage in must not produce phantom questions.
    try assertTrue(PrepGenerator.parse("no json here").isEmpty, "prose only")
    try assertTrue(PrepGenerator.parse("").isEmpty, "empty")
    try assertTrue(PrepGenerator.parse("[broken").isEmpty, "unterminated")
}

/// A prepared answer must be on screen the instant a question matches, and
/// the model's answer must still be reachable. Getting either half wrong is
/// bad in opposite directions: showing nothing means the cost of preparing was
/// never recovered, and showing only the prepared answer means a wrong match
/// is never discovered.
@MainActor
func testPreparedAnswerSlotArbitratesCorrectly() throws {
    let slot = PreparedAnswerSlot()

    // With nothing prepared, the slot is the ordinary streaming path.
    slot.setStreamed("Th")
    slot.setStreamed("Thinking about it")
    try assertEq(slot.displayed, "Thinking about it", "streams normally")
    try assertFalse(slot.hasPrepared, "and is not treated as prepared")

    // A match lands. The stream's opening clear happens first, as it always
    // does — and must not become the "generated alternative".
    slot.clear()
    slot.showPrepared("Start with two pilot entities.", source: "How do you start?")
    slot.setStreamed("")          // the stream's first act
    try assertEq(slot.displayed, "Start with two pilot entities.",
                 "the prepared answer is up immediately")
    try assertFalse(slot.canShowGenerated,
                    "and nothing to switch to yet — a dead control would lie")

    // The model answers. The prepared answer stays on screen; the generated
    // one is held, not discarded.
    slot.setStreamed("I would begin")
    try assertEq(slot.displayed, "Start with two pilot entities.",
                 "the prepared answer keeps the screen while generation finishes")
    try assertTrue(slot.canShowGenerated, "and the alternative is now available")
    try assertTrue(slot.isShowingPrepared, "still showing prepared by default")

    // Later chunks grow the same alternative rather than replacing it.
    slot.setStreamed("I would begin by")
    try assertEq(slot.generated, "I would begin", "only the first write is captured")

    // The user can check the match.
    slot.toggle()
    try assertFalse(slot.isShowingPrepared, "switches to the generated answer")
    try assertEq(slot.displayed, "I would begin", "which is shown")
    slot.toggle()
    try assertEq(slot.displayed, "Start with two pilot entities.",
                 "and switching back returns to the prepared one")

    // Clearing is total — a stale prepared answer must not survive into the
    // next question.
    slot.clear()
    try assertFalse(slot.hasPrepared, "clear drops the prepared answer")
    try assertEq(slot.generated, "", "and the alternative")
    try assertEq(slot.displayed, "", "and what is on screen")
    try assertFalse(slot.canShowGenerated, "and offers no toggle")

    // An empty match is not a match.
    slot.showPrepared("   ", source: "ignored")
    try assertFalse(slot.hasPrepared, "whitespace is not a prepared answer")

    // Toggling with nothing generated does nothing rather than blanking.
    slot.showPrepared("Real answer", source: "Q")
    slot.toggle()
    try assertEq(slot.displayed, "Real answer", "toggle is inert until there is an alternative")
}

/// Role detection must not use a reasoning model.
///
/// `gemini-3.8-flash:online` reasons before answering, and reasoning counts
/// against `max_tokens`. Asked for a job title it spent the entire budget
/// thinking and returned `content: null` — or the truncated string
/// "Microsoft". The role then resolved to empty with no error, the bank stayed
/// filed under its placeholder, and every question in it sat inert. Measured
/// twice each against the real posting: 3.8-flash:online got 1 of 2,
/// gemini-2.5-flash got 2 of 2 in 0.8s.
func testRoleDetectionDoesNotUseAReasoningModel() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    let src = try String(contentsOf: root.appending(path:
        "MacOverlay/Stores/PrepGenerator.swift"), encoding: .utf8)

    guard let fn = src.range(of: "func askRole(") else {
        try assertTrue(false, "askRole not found"); return
    }
    let tail = src[fn.lowerBound...]
    let end = tail.range(of: "\n    }")?.lowerBound ?? tail.endIndex
    let body = String(tail[fn.lowerBound ..< end])

    try assertTrue(body.contains("roleModel"),
                   "askRole uses the dedicated role model, not the writing model")
    // Read the value, not the prose: the comment explains why the reasoning
    // model was rejected and names it.
    let sendsRoleModel = body.contains("\"model\": roleModel")
    try assertTrue(sendsRoleModel, "askRole sends the role model")

    // And the two models must actually differ, or the indirection is a lie.
    try assertFalse(PrepGenerator.roleModel
                    .contains(PrepGenerator.researchModelSuffix),
                    "role extraction does not reuse the question-writing model")
}

/// Role detection used a token budget smaller than the model's reasoning.
///
/// `google/gemini-3.8-flash:online` spends completion tokens thinking before
/// it answers, and reasoning counts against `max_tokens`. At 24 the entire
/// budget went to reasoning — 19 reasoning tokens, `content: null` — and the
/// role resolved to empty, silently, with no error anywhere. The failure was
/// invisible because the code handled nil correctly and simply had nothing to
/// report.
func testRoleDetectionBudgetLeavesRoomForReasoning() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    let src = try String(contentsOf: root.appending(path:
        "MacOverlay/Stores/PrepGenerator.swift"), encoding: .utf8)

    // The role call must not be budgeted like a two-word completion.
    guard let fnStart = src.range(of: "func askRole(") else {
        try assertTrue(false, "askRole not found")
        return
    }
    let tail = src[fnStart.lowerBound...]
    let fnEnd = tail.range(of: "\n    }")?.lowerBound ?? tail.endIndex
    let body = String(tail[fnStart.lowerBound ..< fnEnd])

    // Match the assignment, not a number quoted in the comment explaining why
    // the old budget was wrong.
    let pattern = "\"max_tokens\":"
    guard let tok = body.range(of: pattern) else {
        try assertTrue(false, "askRole sets no max_tokens")
        return
    }
    let after = body[tok.upperBound...]
    var digits = ""
    for ch in after {
        if ch.isNumber { digits.append(ch) }
        else if digits.isEmpty { continue } else { break }
    }
    let n = Int(digits) ?? 0
    try assertTrue(n >= 32,
                   "role detection has a usable token budget, got \(n)")

    // And a nil content must be "could not tell", not a silent empty answer.
    try assertTrue(body.contains(#"?? """#),
                   "a nil content falls through to the empty-string guard")
}

/// The card must name where its questions came from. "22 questions" with no
/// source reads as a finished state, which is exactly how a bank of imported
/// questions gets mistaken for a researched one.
func testPreparedBannerBreaksDownSources() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    let panel = try String(contentsOf: root.appending(path:
        "MacOverlay/Views/Panels/PrepPanelView.swift"), encoding: .utf8)
    for fragment in ["importedCount", "researchedCount", "capturedCount",
                     "isPlaceholderBank", "breakdown"] {
        try assertTrue(panel.contains(fragment), "the banner uses \(fragment)")
    }
    try assertTrue(panel.contains("Filed as"),
                   "and says so plainly when the bank is still a placeholder")
}

/// A match must not be thrown away because the answer is too long to use.
///
/// The premise of a question bank is that the answer is already there, so the
/// live path returns it without calling a model. That only holds if what is
/// stored is sayable. Measured on a real import: median answer 230 characters,
/// and two answers of 12,908 and 8,626 characters — 1,965 and 1,102 words.
/// Returned live, those are unreadable in the gap between questions, which is
/// the one moment there is.
func testLongAnswersGetASpeakableFormAndTheOriginalIsKept() throws {
    try assertTrue(AnswerCondenser.longAnswerThreshold > 400,
                   "ordinary spoken answers are not treated as long")
    try assertTrue(AnswerCondenser.longAnswerThreshold < 5_000,
                   "but a written document is")
    try assertTrue(AnswerCondenser.targetWordCount <= 150,
                   "and the spoken form is short enough to read at a glance")

    // The lookup must prefer the spoken form when there is one.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    let lookup = try String(contentsOf: root.appending(path:
        "MacOverlay/Stores/PreparedAnswerLookup.swift"), encoding: .utf8)
    try assertTrue(lookup.contains("spokenAnswer ?? hit.question.answer"),
                   "the live path prefers the speakable form")
    try assertTrue(lookup.contains("hit.question.spokenAnswer"),
                   "and falls back to the full answer when there is none")

    // The original is never overwritten — it is the reference.
    let bankSrc = try String(contentsOf: root.appending(path:
        "MacOverlay/Stores/PrepBank.swift"), encoding: .utf8)
    try assertTrue(bankSrc.contains("var answer: String"),
                   "the full answer is still stored")
    try assertTrue(bankSrc.contains("var spokenAnswer: String?"),
                   "alongside the speakable form")

    // Round-trip: a question with both keeps both.
    let q = PrepQuestion(question: "Backup and DR?", answer: String(repeating: "x", count: 9_000),
                         spokenAnswer: "Git is our source of truth.",
                         bankID: "b")
    try assertEq(q.answer.count, 9_000, "full text survives")
    try assertEq(q.spokenAnswer, "Git is our source of truth.", "so does the short form")

    // And it encodes, so it survives a restart.
    let data = try JSONEncoder().encode(q)
    let back = try JSONDecoder().decode(PrepQuestion.self, from: data)
    try assertEq(back.spokenAnswer, "Git is our source of truth.", "persisted")
    try assertEq(back.answer.count, 9_000, "with the original intact")
}

/// Coverage, judged by risk rather than by scanning prose for "None".
///
/// The model says "well covered" as readily as it says "None", so classifying
/// on the word marked all nine areas of a real posting as gaps. The risk score
/// is the model's own verdict and is what the sheet should trust.
@MainActor
func testGapClassificationUsesRiskNotProse() throws {
    let covered = GapAnalyser.Gap(area: "Capacity planning", priority: "Essential",
                                  covered: ["a", "b"], gap: "This area is well covered.",
                                  risk: 0)
    let thin = GapAnalyser.Gap(area: "Semantic models", priority: "Essential",
                               covered: ["c"], gap: "DAX depth not explored.", risk: 1)
    let urgent = GapAnalyser.Gap(area: "Data quality and lineage", priority: "Essential",
                                 covered: [], gap: "Not covered at all.", risk: 3)

    try assertTrue(covered.isCovered, "risk 0 is covered even when it says 'well covered'")
    try assertFalse(thin.isCovered, "risk 1 is not")
    try assertFalse(urgent.isCovered, "risk 3 is not")

    let report = GapAnalyser.Report(gaps: [covered, thin, urgent])
    try assertEq(report.needsWork.count, 2, "two areas need work")
    try assertEq(report.needsWork.first?.area, "Data quality and lineage",
                 "worst first, so the sheet leads with what costs the interview")
    try assertEq(report.solid.count, 1, "and one is solid")

    // `covered` is counted locally, never asked of the model — the model was
    // given the questions and returns prose, and prose cannot say "you have
    // three questions on this".
    let bank = [
        PrepQuestion(question: "How do you build a cost chargeback model?",
                     answer: "", bankID: "b"),
        PrepQuestion(question: "Tell me about governance.",
                     answer: "", bankID: "b"),
    ]
    let hits = GapAnalyser.matchingQuestions(
        for: .init(area: "Capacity planning",
                   priority: "Essential",
                   gap: "chargeback and cost allocation", risk: 1),
        in: bank)
    try assertEq(hits.count, 1, "the chargeback question matches")
    try assertTrue(hits[0].contains("chargeback"), "and it is the right one")

    let noOverlap = GapAnalyser.matchingQuestions(
        for: .init(area: "Quantum entanglement", priority: nil,
                   gap: "spin states", risk: 3),
        in: bank)
    try assertEq(noOverlap.count, 0, "an unrelated area matches nothing")
}

/// The Settings panel must end inside itself, and only say things once.
///
/// Two defects reported from a screenshot: a sample sentence under the
/// keyword picker ("Lead with the key point…") that restated the options and
/// cost a third of the section, and a last row sitting flush against the
/// panel's bottom edge so it read as clipped.
func testSettingsPanelIsNotClippedAndKeepsNoSampleBlock() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    let prefs = try String(
        contentsOf: root.appending(path: "MacOverlay/Views/Preferences/PreferencesView.swift"),
        encoding: .utf8)
    let markdown = try String(
        contentsOf: root.appending(path: "MacOverlay/Views/Shared/MarkdownResponseView.swift"),
        encoding: .utf8)

    try assertTrue(!prefs.contains("KeywordStyle.sample"),
                   "the sample answer block is gone")
    try assertTrue(!markdown.contains("Let the key point\\n" ) && !markdown.contains("Lead with the"),
                   "and its constant no longer exists")

    try assertTrue(prefs.contains(".padding(.bottom, tab == .prompts ? 0 : 20)"),
                   "the scroll content has bottom padding so the last row is not flush")

    // The transcription row: the label must be given the leftover width
    // rather than collapsing to its longest word.
    try assertTrue(prefs.contains("Transcription engine"),
                   "the transcription row still exists")
    let row = prefs
        .components(separatedBy: "Transcription engine").dropFirst().first?
        .components(separatedBy: "needsScreenRecordingPermission").first ?? ""
    try assertTrue(row.contains(".frame(maxWidth: .infinity, alignment: .leading)"),
                   "its label takes the remaining width")
    try assertTrue(!row.contains(".layoutPriority(1)"),
                   "and is no longer squeezed by the old layout priority")
}

/// Quitting must not require finding the overlay's "\u{2026}" menu.
///
/// The overlay floats above every window and hides itself from screen
/// sharing. Quit lived only in that menu, so with the overlay hidden — or
/// while in Settings, where the menu is not on screen — there was no way
/// out short of the menu bar icon.
func testSettingsHasAQuitThatWorks() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    let prefs = try String(
        contentsOf: root.appending(path: "MacOverlay/Views/Preferences/PreferencesView.swift"),
        encoding: .utf8)

    try assertTrue(prefs.contains("private var quitRow"),
                   "Settings has a quit row")
    try assertTrue(prefs.contains("NSApp.terminate(nil)"),
                   "wired to actually terminate")
    try assertTrue(prefs.contains("quitRow\n                    .padding"),
                   "pinned into the rail rather than tucked inside one tab")
    // On every tab: it belongs to the rail, not to a tab's content. The
    // rail is `body`, so body has to reference it — and the General tab's
    // own content must not be the only place it lives.
    let body = prefs.components(separatedBy: "private var sidebarHeader").first ?? ""
    try assertTrue(body.contains("quitRow"),
                   "the rail in body renders the quit row, so every tab has it")
    let general = prefs
        .components(separatedBy: "private var generalTab").dropFirst().first?
        .components(separatedBy: "private var quickAskTab").first ?? ""
    try assertTrue(!general.contains("quitRow"),
                   "and it is not tucked inside the General tab alone")
}

/// The app must be inspectable, and gettable-out-of.
///
/// The overlay is a floating panel above every window that hides itself from
/// screen sharing — correct during an interview, and exactly what makes a
/// layout bug impossible to photograph or describe. Quitting was buried in a
/// menu bar item and behind the overlay's own "…" menu, so with the overlay
/// hidden there was no reachable way out.
func testAppCanBeInspectedAndQuitFromInsideIt() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    func read(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    let inspector = try read("MacOverlay/Views/Shell/InspectorRootView.swift")
    let appDelegate = try read("MacOverlay/AppDelegate.swift")
    let menu = try read("MacOverlay/MenuBarController.swift")
    let strip = try read("MacOverlay/Views/Shell/TopStripView.swift")

    // The window has to exist and be reachable from more than one place —
    // the overlay menu disappears when the overlay is hidden.
    try assertTrue(appDelegate.contains("func toggleInspector"),
                   "the inspector can be toggled")
    try assertTrue(menu.contains("Troubleshooting window"),
                   "and is reachable from the menu bar when the overlay is hidden")
    try assertTrue(strip.contains("troubleshooting"),
                   "and from the overlay's own menu")

    // It must be a real, screenshot-able window: opaque, not floating, and
    // explicitly not excluded from screen sharing.
    try assertTrue(appDelegate.contains("w.sharingType = .readWrite"),
                   "the inspector is visible to screen capture, unlike the overlay")
    try assertTrue(appDelegate.contains("[.titled, .closable, .resizable]"),
                   "and is an ordinary resizable window")

    // Quitting has to be one click in that window. The button lives in the
    // view; the terminate call lives where the closure is built.
    try assertTrue(inspector.contains("Button(\"Quit\""),
                   "the inspector has a Quit button")
    try assertTrue(appDelegate.contains("onQuit: { NSApp.terminate(nil) }"),
                   "wired to actually quit")
    try assertTrue(inspector.contains("ScrollView"),
                   "and its contents scroll rather than clip")

    // The setup form has to fit, or Start sits below a fold with no hint.
    let height = try Int(appDelegate
        .components(separatedBy: "static let expandedSize  = NSSize(width: 440, height: ")[1]
        .prefix(3)) ?? 0
    try assertTrue(height >= 760,
                   "the setup panel is tall enough for its ten sections, got \(height)")
    // And it must still fit this screen.
    try assertTrue(height <= 940, "and not taller than the display")
}

/// A bank filed under a placeholder is a bank that has stopped working.
///
/// Questions imported before the role could be detected were filed under
/// "Imported", which is not a role. It never gets selected, never gets matched
/// against, and never grows — the questions sit there looking saved while
/// doing nothing. The user has exactly this bank.
@MainActor
func testPlaceholderBankAdoptsTheDetectedRole() throws {
    let bank = PrepBank.shared
    let saved = bank.questions
    defer { bank.replaceAll(with: saved) }

    bank.replaceAll(with: [
        PrepQuestion(question: "Q1", answer: "A1", bankID: PrepBank.placeholderBankID),
        PrepQuestion(question: "Q2", answer: "A2", bankID: PrepBank.placeholderBankID),
        PrepQuestion(question: "Q3", answer: "A3", bankID: "Some Other Role"),
    ])

    try assertTrue(bank.hasBank(forRole: PrepBank.placeholderBankID), "placeholder exists")
    try assertFalse(PrepBank.placeholderBankID.contains(" "),
                    "the placeholder is not a plausible role name")

    let moved = bank.renameBank(from: PrepBank.placeholderBankID, to: "Fabric CoE Lead")
    try assertEq(moved, 2, "both placeholder questions moved")
    try assertFalse(bank.hasBank(forRole: PrepBank.placeholderBankID),
                    "and the placeholder is gone")
    try assertEq(bank.questions(inBank: "Fabric CoE Lead").count, 2, "now under the role")
    try assertEq(bank.questions(inBank: "Some Other Role").count, 1,
                 "other banks untouched")

    // The active bank follows a rename, or the card shows an empty bank.
    bank.replaceAll(with: [
        PrepQuestion(question: "Q9", answer: "A9", bankID: PrepBank.placeholderBankID),
    ])
    try assertEq(bank.activeBankID, PrepBank.placeholderBankID,
                 "replacing the set points the active bank at what is there")
    bank.renameBank(from: PrepBank.placeholderBankID, to: "Data Platform Lead")
    try assertEq(bank.activeBankID, "Data Platform Lead",
                 "the active bank follows the rename")

    // Nonsense renames are refused rather than destroying the bank.
    try assertEq(bank.renameBank(from: "Nothing", to: "Whatever"), 0,
                 "renaming a bank that does not exist moves nothing")
    try assertEq(bank.renameBank(from: "Data Platform Lead", to: "   "), 0,
                 "a blank name is refused")
    try assertEq(bank.questions(inBank: "Data Platform Lead").count, 1,
                 "and the bank is still intact")
}

/// Generated questions have to be reachable. They are produced, embedded and
/// saved — and then, for one build, there was no control anywhere that opened
/// them. A sheet declared and never presented, because renaming the one button
/// that opened it removed the only `showBank = true` in the file.
///
/// This is a source-level guard because the failure is a wiring gap, not a
/// logic error: nothing crashed, every other test passed, and the questions
/// existed on disk the whole time.
func testPreparedQuestionsAreReachableFromTheSetupScreen() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    let panel = try String(contentsOf: root.appending(path:
        "MacOverlay/Views/Panels/PrepPanelView.swift"), encoding: .utf8)

    // Something must actually open the bank, and something the other bank.
    try assertTrue(panel.contains("showBank = true"),
                   "a control opens the question bank")
    try assertTrue(panel.contains("showBackups = true"),
                   "a control opens the backups")

    // And it must not be the declaration or a reset being counted as the
    // only occurrence.
    let opens = panel.components(separatedBy: "showBank = true").count - 1
    try assertTrue(opens >= 1, "the bank is opened from the card or the sheet")

    // The success state has to say so, with a count and a way in — a run that
    // finishes looking exactly as it started is indistinguishable from one
    // that failed.
    try assertTrue(panel.contains("Prepared —"),
                   "the card confirms the run finished")
    try assertTrue(panel.contains("View \\(questionCount) questions"),
                   "and the count is on the control that opens the bank")

    // Every generated question must be findable, and the prepared path must be
    // reachable from the send flow too.
    let vm = try String(contentsOf: root.appending(path:
        "MacOverlay/OverlayViewModel.swift"), encoding: .utf8)
    try assertTrue(vm.contains("preparedAnswer(for:"),
                   "the send path actually calls the matcher")
    try assertTrue(vm.contains("sessionMode == .interview"),
                   "and only in an interview, where a bank exists")
}

/// One vector in, one vector out.
///
/// The bug this pins was two independent casts in the response reader: on
/// Apple platforms a JSON `[Double]` also satisfies `as? [NSNumber]`, so every
/// vector was appended a second time. The count check then failed on every
/// bank, embedding never completed, and the live matcher had nothing to match
/// against — so the entire prepared-answer path was dead while every test that
/// did not touch the network passed.
func testEmbeddingResponseYieldsOneVectorPerRow() throws {
    // A row as JSONSerialization actually produces it.
    let rows: [[String: Any]] = [
        ["embedding": [0.1, 0.2, 0.3] as [Double]],
        ["embedding": [0.4, 0.5, 0.6] as [Double]],
        ["embedding": [0.7, 0.8, 0.9] as [Double]],
    ]
    let got = EmbeddingService.vectors(in: rows)
    try assertEq(got.count, 3, "three rows give three vectors, not six")
    try assertEq(got[1], [0.4, 0.5, 0.6], "and the right one is in the right place")

    // A single row must not double either — that was the smallest case that
    // still failed.
    try assertEq(EmbeddingService.vectors(in: [["embedding": [1.0, 2.0] as [Double]]]).count, 1,
                 "one row gives one vector")

    // Rows that genuinely carry NSNumber still work.
    let nsRows: [[String: Any]] = [["embedding": [1, 2, 3] as [NSNumber]]]
    try assertEq(EmbeddingService.vectors(in: nsRows).count, 1,
                 "an NSNumber row gives one vector")
    try assertEq(EmbeddingService.vectors(in: nsRows).first ?? [], [1.0, 2.0, 3.0],
                 "and keeps its values")

    // A malformed row is skipped rather than crashing, and the count check
    // upstream is what catches the shortfall.
    try assertEq(EmbeddingService.vectors(in: [["embedding": "not a vector" as Any],
                                              ["embedding": [1.0] as [Double]]]).count, 1,
                 "a bad row is skipped")
}

/// A question bank from another tool has to come in whatever shape it
/// arrives. The realistic input is a mock interview exported from a different
/// AI, so every one of these is a format that tool has actually produced.
func testPrepBankImporterReadsTheShapesRealToolsExport() throws {
    // 1. Labelled lines, the most common export and the easiest to paste.
    let labelled = """
    Q: How would you structure the Centre of Excellence?
    A: Federated hub and spoke, with the hub setting guardrails.

    Q2: What happens after the engagement ends?
    A: The CoE owns the standards, so teams extend the platform themselves.
    """
    let l = PrepBankImporter.parse(labelled)
    try assertEq(l.format, .labelled, "recognised as labelled")
    try assertEq(l.pairs.count, 2, "both questions found")
    try assertTrue(l.pairs[0].question.contains("Centre of Excellence"), "q kept")
    try assertTrue(l.pairs[0].answer.contains("Federated"), "a kept")
    try assertEq(l.pairs[1].question, "What happens after the engagement ends?",
                 "a numbered marker is stripped like a plain one")

    // 2. Multi-line answers — the most common thing to get wrong, because a
    //    naive reader treats every line as a new record.
    let wrapped = """
    Q: Walk me through the migration.
    A: I started by inventorying every estate.
    Then I grouped them by platform.
    Finally I migrated in waves.
    """
    let w = PrepBankImporter.parse(wrapped)
    try assertEq(w.pairs.count, 1, "a wrapped answer is one question, not three")
    try assertTrue(w.pairs[0].answer.contains("waves"), "the last line survives")

    // 3. JSON, using another model's key names.
    let json = #"{"qa":[{"question":"Why Fabric?","answer":"Governance.","category":"fit"}]}"#
    let j = PrepBankImporter.parse(json)
    try assertEq(j.format, .json, "recognised as JSON")
    try assertEq(j.pairs.count, 1, "wrapped JSON object read")
    try assertEq(j.pairs[0].topic, "fit", "topic from `category`")

    // 4. JSON with a bracket inside an answer.
    let tricky = #"[{"q":"Indexing?","a":"Use [0] through [2], not [3]."}]"#
    let t2 = PrepBankImporter.parse(tricky)
    try assertEq(t2.pairs.count, 1, "brackets inside strings do not truncate")
    try assertTrue(t2.pairs[0].answer.contains("[3]"), "answer intact")

    // 5. Markdown headings.
    let md = """
    # Mock interview — Fabric CoE

    ## How do you govern a shared platform?
    I publish golden paths and enforce them with pipeline tests.

    ## What is your biggest risk?
    Adoption. I run office hours and track workspace activation weekly.
    """
    let m = PrepBankImporter.parse(md)
    try assertEq(m.pairs.count, 2, "both markdown questions found")
    try assertTrue(m.pairs[0].answer.contains("golden paths"), "first answer")
    try assertTrue(m.pairs[1].question.contains("biggest risk"), "second question")

    // 6. Prose transcript — the fallback, and the least certain, so it is only
    //    reached when nothing better matched.
    let prose = """
    So, tell me about the Centre of Excellence you set up.

    I ran a hub and spoke model with a central standards team.

    And how did you handle adoption across legal entities?

    Office hours, plus activation metrics per entity each week.
    """
    let pr = PrepBankImporter.parse(prose)
    try assertEq(pr.format, .transcript, "falls back to transcript")
    try assertEq(pr.pairs.count, 2, "alternating blocks become two pairs")
    try assertTrue(pr.pairs[1].question.contains("adoption"), "second question kept")

    // 7. A question with no answer is not importable — a blank slot in the
    //    bank would match live and show nothing.
    try assertEq(PrepBankImporter.parse("Q: Something").pairs.count, 0,
                 "a question with no answer is dropped")

    // 8. Empty and junk input fail quietly rather than throwing.
    try assertEq(PrepBankImporter.parse("").pairs.count, 0, "empty is empty")
    try assertEq(PrepBankImporter.parse("Just a note to self.").pairs.count, 0,
                 "a single stray line yields nothing")
}

/// The parser must survive whatever shape the model actually replies in.
///
/// This is a regression on real output, not a hypothetical: asked for
/// `{"q":…,"topic":…,"a":…}`, Gemini's `:online` variant replied with an
/// object wrapping the array under `interview_questions_and_answers`, and with
/// `category` / `question` / `interviewer_intent` / `answer` in each element.
/// Strict decoding turned 7 good questions into zero, and the run reported
/// "the model returned no usable questions".
@MainActor
func testPrepParserAcceptsRealModelShapes() throws {
    // The exact shape observed, trimmed.
    let real = """
    Here you go:
    ```json
    {"interview_questions_and_answers": [
      {"category": "Capacity Planning",
       "question": "How do you approach capacity sizing across legal entities?",
       "interviewer_intent": "Tests hands-on understanding of F-SKUs.",
       "answer": "I establish a federated model with automated chargeback."},
      {"category": "Governance",
       "question": "How do you enforce data isolation across entities?",
       "answer": "I built RLS and OLS governance at Prudential."}
    ]}
    ```
    """
    let got = PrepGenerator.parse(real)
    try assertEq(got.count, 2, "both questions recovered from the wrapped object")
    try assertEq(got[0].q, "How do you approach capacity sizing across legal entities?",
                 "question picked up from `question`")
    try assertTrue(got[0].a.contains("federated"), "answer picked up from `answer`")
    try assertEq(got[0].topic, "Capacity Planning", "topic picked up from `category`")
    try assertEq(got[1].q, "How do you enforce data isolation across entities?",
                 "and the second one too")

    // The schema as asked for must still work — this is the regression guard
    // for loosening the parser.
    let literal = #"[{"q":"Why Fabric?","topic":"leadership","a":"Because of governance."}]"#
    let lit = PrepGenerator.parse(literal)
    try assertEq(lit.count, 1, "the documented shape still parses")
    try assertEq(lit[0].q, "Why Fabric?", "and q is still q")

    // A bracket inside a string must not truncate the array.
    let bracketed = #"[{"q":"A?","a":"use [0] and ] here","topic":"x"}]"#
    let br = PrepGenerator.parse(bracketed)
    try assertEq(br.count, 1, "brackets inside strings do not end the array early")
    try assertTrue(br[0].a.contains("[0]"), "and the answer survives intact")

    // An element missing its answer is dropped, not admitted as a blank.
    let partial = #"[{"q":"Has a question","a":"And an answer","topic":"x"},{"q":"No answer here"}]"#
    try assertEq(PrepGenerator.parse(partial).count, 1,
                 "an element with no answer is skipped")

    // Case differences are tolerated.
    try assertEq(PrepGenerator.parse(#"[{"Question":"Cap Q","Answer":"Cap A"}]"#).count, 1,
                 "capitalised keys still parse")

    // Genuinely unusable input yields nothing rather than crashing.
    try assertEq(PrepGenerator.parse("I'm sorry, I cannot help with that.").count, 0,
                 "prose yields no questions")
    try assertEq(PrepGenerator.parse("").count, 0, "empty yields no questions")
    try assertEq(PrepGenerator.parse(#"[{"q":"only a question"}]"#).count, 0,
                 "a question with no answer is not usable")
}

/// A run that failed must never read as "nothing prepared yet".
///
/// The card is where the user is standing after the sheet closes — and the
/// sheet closed itself on submit, so every error message was rendered into a
/// window that had already gone. The card then said "No questions prepared
/// yet", which points at the résumé (never the problem) instead of at the
/// failure that actually happened.
@MainActor
func testPreparationFailureIsDistinguishableFromNeverStarting() throws {
    let g = PrepGenerator()

    // Never attempted: the blocker is what is missing, not a failure.
    g.jobDescription = "Fabric CoE role posting with plenty of detail here."
    try assertTrue(g.stage == .idle, "starts idle")
    try assertFalse(g.stage.isFailure, "idle is not a failure")
    try assertFalse(g.canGenerate, "cannot generate without a role")

    g.roleName = "Fabric Platform Lead"
    try assertTrue(g.canGenerate, "role plus posting is enough")
    try assertEq(g.guidance, nil, "and there is then nothing to tell the user")

    // Failed: distinguishable, with the reason recoverable.
    try assertEq(PrepGenerator.Stage.failed("HTTP 429 rate limited").failureReason,
                 "HTTP 429 rate limited", "the reason survives")
    try assertTrue(PrepGenerator.Stage.failed("x").isFailure, "and it is flagged")
    try assertFalse(PrepGenerator.Stage.done(count: 40).isFailure, "success is not")

    // The two never-asked questions must not read the same.
    try assertTrue(g.guidance != nil || !g.stage.isFailure,
                   "a run that never started never claims to have failed")
}

/// The prompt must reach the model as written. A scripted edit collapsed the
/// line continuations in the résumé block, leaving runs of spaces mid-sentence
/// inside the text sent to the model.
@MainActor
func testPrepPromptHasNoCollapsedWhitespace() throws {
    for (name, resume) in [("with CV", String(repeating: "Led a lakehouse. ", count: 40)),
                           ("without CV", "")] {
        let p = PrepGenerator.debugPrompt(role: "Fabric Lead", jd: String(repeating: "x", count: 80),
                                          resume: resume, count: 10)
        for line in p.split(separator: "\n", omittingEmptySubsequences: false) {
            try assertFalse(line.contains("     "),
                           "\(name): collapsed line continuation in \(line.prefix(60))")
        }
    }
    // And the sentences still read as sentences.
    let withCV = PrepGenerator.debugPrompt(role: "R", jd: String(repeating: "x", count: 80),
                                           resume: String(repeating: "Led a lakehouse. ", count: 40),
                                           count: 10)
    try assertTrue(withCV.contains("grounded in something that appears here"),
                   "the résumé instruction is one clean sentence")
}

/// The setup form's contents must outlive the process. Everything on it is
/// typed by hand — a posting pasted in, a CV attached — and none of it was
/// stored, so a rebuild or a crash returned you to a blank form that looked as
/// though the work had never been done.
func testInterviewSetupSurvivesRelaunch() throws {
    let d = UserDefaults.standard
    InterviewSetupStore.reset()
    defer { InterviewSetupStore.reset() }

    let posting = "Fabric CoE interview loop — platform lead, lakehouse, cost governance."
    InterviewSetupStore.setContext(posting)
    try assertEq(InterviewSetupStore.context, posting,
                 "the posting is written through as it is typed")
    try assertEq(d.string(forKey: "interviewContext"), posting,
                 "under the documented key, not a private one")

    // A résumé is re-attached only if the file is still there — a chip
    // pointing at a moved file is worse than no chip.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("setup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cv = dir.appendingPathComponent("cv.txt")
    try ("Abhishek K — Fabric CoE. " + String(repeating: "experience. ", count: 40))
        .write(to: cv, atomically: true, encoding: .utf8)

    InterviewSetupStore.setResumeURL(cv)
    try assertEq(InterviewSetupStore.resumeURLIfPresent?.path, cv.path,
                 "the résumé is recovered after a relaunch")

    // Delete it underneath, and the stale path is dropped rather than restored
    // as an unreadable attachment.
    try FileManager.default.removeItem(at: cv)
    try assertEq(InterviewSetupStore.resumeURLIfPresent?.path, nil,
                 "a résumé that has since been deleted is not restored")
    try assertTrue(d.string(forKey: "interviewResumeFilePath") == nil,
                   "and its stale path is cleared so it cannot fail again")
    try assertEq(InterviewSetupStore.context, posting,
                 "while the posting, which is still good, is kept")

    // A directory is not a résumé, however much it is pointed at.
    let dirOnly = dir.appendingPathComponent("weird.txt")
    try FileManager.default.createDirectory(at: dirOnly,
                                            withIntermediateDirectories: true)
    d.set(dirOnly.path, forKey: "interviewResumeFilePath")
    try assertEq(InterviewSetupStore.resumeURLIfPresent?.path, nil,
                 "a directory is not accepted as a résumé")

    // restore() carries everything at once, as launch does.
    InterviewSetupStore.reset()
    d.removeObject(forKey: "interviewAutoGenerate")
    try "a résumé that is genuinely there".write(to: cv, atomically: true, encoding: .utf8)
    InterviewSetupStore.setContext("second posting")
    InterviewSetupStore.setResumeURL(cv)
    let state = InterviewSetupStore.restore()
    try assertEq(state.context, "second posting", "restore returns the posting")
    try assertEq(state.resumeURL?.path, cv.path, "restore returns the résumé")

    // Absent means "never set", not "off" — an existing user must not lose
    // auto-generate just because a newer build added the key.
    InterviewSetupStore.reset()
    try assertTrue(InterviewSetupStore.autoGenerate,
                   "auto-generate defaults on when never set")
    try assertTrue(InterviewSetupStore.focusMode,
                   "focus mode defaults on when never set")
    InterviewSetupStore.setAutoGenerate(false)
    try assertFalse(InterviewSetupStore.autoGenerate, "and honours an explicit off")
}

/// A resume that cannot be parsed must fail loudly. The importer's error used
/// to be discarded into `""`, which made a scanned PDF indistinguishable from
/// no file at all: the card showed nothing, prep reported "none attached", and
/// the answers came out generic with no hint why. These two PDFs are the exact
/// pair that got confused — one is readable, one is not.
func testScannedResumeFailsLoudlyInsteadOfSilently() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("resume-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    /// Writes a genuine PDF via CoreGraphics. With text it gets a real text
    /// layer (what a digitally-produced résumé has); without, the page is a
    /// bitmap (what a scanner or an ATS re-export produces).
    func pdf(text: String?) -> URL {
        let url = dir.appendingPathComponent(text == nil ? "scan.pdf" : "typed.pdf")
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            fatalError("test could not create a PDF at \(url.path)")
        }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(box)
        if let text {
            // CoreText with Helvetica, deliberately. Drawing with NSString and
            // a *system* font also produces a PDF, but its embedded subset has
            // no usable encoding and `page.string` comes back empty — which is
            // the very failure mode this test exists to distinguish from a scan.
            let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [
                    .init(kCTFontAttributeName as String): font,
                ]))
            ctx.textPosition = CGPoint(x: 50, y: 500)
            CTLineDraw(line, ctx)
        } else {
            ctx.draw(makeBitmap(), in: box)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    func makeBitmap() -> CGImage {
        let image = NSImage(size: NSSize(width: 612, height: 792))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 612, height: 792).fill()
        ("Abhishek K — Fabric CoE" as NSString).draw(
            at: NSPoint(x: 50, y: 500),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.black])
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    // The readable one must keep working — this is the regression guard for
    // tightening the importer.
    let typed = try ResumeImporter.importFile(url: pdf(text: "Abhishek K — Fabric CoE"))
    try assertTrue(typed.contains("Abhishek"),
                   "a PDF with a text layer still imports (got \(typed.count) chars)")

    // The scanned one must throw a named, recoverable error — not return "".
    var thrown: ResumeImporter.ImportError?
    do {
        _ = try ResumeImporter.importFile(url: pdf(text: nil))
        try assertTrue(false, "a scanned PDF must not import silently")
    } catch let e as ResumeImporter.ImportError {
        thrown = e
    }
    try assertTrue({
        if case .scannedPDF = thrown { return true }
        return false
    }(), "expected .scannedPDF, got \(String(describing: thrown))")
    try assertTrue(ResumeImporter.ImportError.scannedPDF.recovery?
        .contains("Export as PDF") == true,
                   "the error tells the user how to fix it")

    // Every importer error must carry recovery text — an unfixable error
    // message is the same failure mode as no message.
    for e: ResumeImporter.ImportError in [.scannedPDF, .unreadable, .empty,
                                          .unsupportedType("pages")] {
        try assertTrue(e.recovery?.isEmpty == false,
                       "\(e) explains how to recover")
    }
}

/// The posting must be typed once. Prep used to have its own JD box on the
/// same screen as Context, so the same description was pasted into two
/// places. `useContext` takes the interview's Context instead, and never
/// overwrites something pasted deliberately.
@MainActor
func testPrepGeneratorTakesPostingFromInterviewContext() throws {
    let g = PrepGenerator()
    try assertTrue(g.jobDescription.isEmpty, "starts empty")

    g.useContext("Fabric role")
    try assertTrue(g.jobDescription.isEmpty, "a stub context is not worth using")

    let context = "Fabric Platform Lead. " + String(repeating: "responsibility ", count: 12)
    g.useContext(context)
    try assertEq(g.jobDescription,
                 context.trimmingCharacters(in: .whitespacesAndNewlines),
                 "context adopted as the posting, trimmed")

    let mine = "A different posting that I typed in deliberately."
    g.jobDescription = mine
    g.useContext("short context")
    try assertEq(g.jobDescription, mine, "an explicit paste is never overwritten")
}

/// Answers must never be invented. The setup screen already holds a Context
/// field and a résumé, and prep reads both rather than asking for either a
/// second time — so the prompt has to make its stance explicit in both cases:
/// ground answers in the CV when there is one, and keep them general when
/// there is not.
@MainActor
func testPrepGeneratorGroundingDependsOnTheResume() throws {
    func flat(_ role: String, _ jd: String, _ resume: String) -> String {
        PrepGenerator.debugPrompt(role: role, jd: jd, resume: resume, count: 10)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
    let jd = String(repeating: "x", count: 60)

    // One field has to do both jobs: pick the questions and ground the answers.
    let none = flat("R", jd, "")
    try assertTrue(none.contains("twice"), "context is explicitly used for both")
    try assertFalse(none.contains("background:"), "no second background field to fill in")

    // No résumé: say so, and steer away from specifics.
    try assertTrue(none.contains("no résumé is attached"),
                   "states plainly that no CV was supplied")
    try assertTrue(none.contains("invented projects, employers or metrics"),
                   "and warns against inventing them")

    // With a résumé: it must actually reach the prompt, unedited.
    let cv = String(repeating: "Led a lakehouse migration at Contoso. ", count: 12)
    let some = flat("R", jd, cv)
    try assertTrue(some.contains("candidate's résumé"), "the CV section is present")
    try assertTrue(some.contains("contoso"), "the actual CV text reaches the prompt")
    try assertTrue(some.contains("quote nothing that is not in this résumé"),
                   "and answers are restricted to it")
    try assertFalse(some.contains("no résumé is attached"),
                    "the no-CV warning is gone once there is one")

    // A pathologically long CV is truncated rather than sent whole.
    let huge = flat("R", jd, String(repeating: "experience detail. ", count: 900))
    try assertTrue(huge.contains("truncated"), "a very long CV is truncated")

    // A token-sized string is treated as no CV at all.
    try assertTrue(flat("R", jd, "hi").contains("no résumé is attached"),
                   "a stub string is not a résumé")
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

        // This binary has no TCChannel in its Info.plist, so AppChannel
        // resolves to Production and JSONStore would otherwise read and write
        // the real ~/Library/Application Support/MacOverlay folder. Point it at
        // a scratch directory for the whole run.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macoverlay-tests-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        JSONStore.setDirectoryOverride(scratch)

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
        TestRunner.run("Shared model filter store", testSharedModelFilterStore)
        TestRunner.run("Prep matcher retrieves the right question", testPrepMatcherRetrievesTheRightQuestion)
        TestRunner.run("Prep matcher refuses weak matches", testPrepMatcherRefusesWeakMatches)
        TestRunner.run("Prep matcher handles morphology", testPrepMatcherHandlesMorphology)
        TestRunner.run("Prep matcher handles empty and odd input", testPrepMatcherHandlesEmptyAndOddInput)
        TestRunner.run("Prep bank persists and groups by role", testPrepBankPersistsAndGroupsByRole)
        TestRunner.run("Bank is keyed by role not by posting", testBankIsKeyedByRoleNotByPosting)
        TestRunner.run("Bank records matches", testBankRecordsMatches)
        TestRunner.run("Missed questions are captured, not auto-banked", testMissedQuestionsAreCapturedNotAutoBanked)
        TestRunner.run("Prepared answer arbitration", testPreparedAnswerSlotArbitratesCorrectly)
        TestRunner.run("Role detection avoids reasoning models", testRoleDetectionDoesNotUseAReasoningModel)
        TestRunner.run("Role detection budgets for reasoning", testRoleDetectionBudgetLeavesRoomForReasoning)
        TestRunner.run("Prepared banner breaks down sources", testPreparedBannerBreaksDownSources)
        TestRunner.run("App is inspectable and quittable", testAppCanBeInspectedAndQuitFromInsideIt)
        TestRunner.run("Settings has a working Quit", testSettingsHasAQuitThatWorks)
        TestRunner.run("Settings is not clipped", testSettingsPanelIsNotClippedAndKeepsNoSampleBlock)
        TestRunner.run("Gap classification uses risk", testGapClassificationUsesRiskNotProse)
        TestRunner.run("Long answers get a speakable form", testLongAnswersGetASpeakableFormAndTheOriginalIsKept)
        TestRunner.run("Placeholder bank adopts the detected role", testPlaceholderBankAdoptsTheDetectedRole)
        TestRunner.run("Prepared questions are reachable", testPreparedQuestionsAreReachableFromTheSetupScreen)
        TestRunner.run("Embedding response gives one vector per row", testEmbeddingResponseYieldsOneVectorPerRow)
        TestRunner.run("Question bank importer reads real exports", testPrepBankImporterReadsTheShapesRealToolsExport)
        TestRunner.run("Prep parser accepts real model shapes", testPrepParserAcceptsRealModelShapes)
        TestRunner.run("Preparation failure is distinguishable", testPreparationFailureIsDistinguishableFromNeverStarting)
        TestRunner.run("Prep prompt has no collapsed whitespace", testPrepPromptHasNoCollapsedWhitespace)
        TestRunner.run("Interview setup survives a relaunch", testInterviewSetupSurvivesRelaunch)
        TestRunner.run("A scanned resume fails loudly", testScannedResumeFailsLoudlyInsteadOfSilently)
        TestRunner.run("Prep generator takes posting from interview context", testPrepGeneratorTakesPostingFromInterviewContext)
        TestRunner.run("Prep generator parses wrapped JSON", testPrepGeneratorParsesWrappedJSON)
        TestRunner.run("Prep generator takes posting from interview context", testPrepGeneratorTakesPostingFromInterviewContext)
        TestRunner.run("Prep generator grounding depends on the resume", testPrepGeneratorGroundingDependsOnTheResume)
        TestRunner.run("Cosine similarity", testCosineSimilarity)
        TestRunner.run("Semantic ranking skips unembedded and gates on margin", testSemanticRankingSkipsUnembeddedAndGatesOnMargin)
        TestRunner.run("Bank backup snapshots and restores", testBankBackupSnapshotsAndRestores)
        TestRunner.run("Bank export round trip", testBankExportRoundTrip)
        TestRunner.run("Bank backup prunes old snapshots", testBankBackupPrunesOldSnapshots)
        TestRunner.run("Answer depth scales the prompt", testAnswerDepthScalesThePrompt)
        TestRunner.run("Answer depth persists and feeds the prompt", testAnswerDepthPersistsAndFeedsThePrompt)
        TestRunner.run("Panel can move between displays", testPanelCanMoveBetweenDisplays)
        TestRunner.run("Panel moves between stacked displays", testPanelMovesBetweenVerticallyStackedDisplays)
        TestRunner.run("Model tier rejects router pricing", testModelTierRejectsRouterPricing)
        TestRunner.run("Blended price conversion", testBlendedPriceConversion)
        TestRunner.run("Model tier from a catalogue entry", testModelTierFromCatalogueEntry)
        TestRunner.run("Catalogue starts stale", testCatalogueStartsStale)
        TestRunner.run("Catalogue schema invalidates old caches", testCatalogueSchemaInvalidatesOldCaches)
        TestRunner.run("Fetched models hidden, selection survives", testFetchedModelsAreHiddenButSelectionSurvives)
        TestRunner.run("Catalogue age wording", testCatalogueAgeWording)
        TestRunner.run("Malformed catalogue fails rather than emptying", testMalformedCatalogueFailsRatherThanEmptying)
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
            try? FileManager.default.removeItem(at: scratch)
            exit(1)
        }
        print("──────────────────────────────")
        // main() ends in exit(), so a `defer` would never run — clean up here.
        try? FileManager.default.removeItem(at: scratch)
        exit(0)
    }
}
