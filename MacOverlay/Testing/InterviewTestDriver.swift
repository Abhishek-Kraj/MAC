import AppKit
import Foundation

/// Drives a live interview from outside the app, to test it end to end.
///
/// `-scriptedinterview <script.json> <outdir>`: feeds the script's interviewer
/// lines through `handleThemSilence` — the path a finished THEM line takes —
/// with real model calls and no audio, in a throwaway session.
///
/// `-livetest <outdir>`: starts a real interview from the setup form, writes
/// `<outdir>/ready` once recording, and ends it when `<outdir>/end` appears.
/// The interviewer's audio comes from Tests/live/run_live_interview.sh.
///
/// Both write `<outdir>/result.json` and quit. Tests/live/score.py scores it.
@MainActor
final class InterviewTestDriver {
    struct Line: Decodable {
        let speaker: String
        let text: String
        let expect: String?
        let pause: Double?
    }

    struct Script: Decodable {
        let lines: [Line]
    }

    struct Decision: Encodable {
        let at: Date
        let text: String
    }

    struct LineResult: Encodable {
        let speaker: String
        let text: String
        let expect: String?
        let sentText: String?
        let decisions: [String]
        let answer: String?
    }

    struct TurnOut: Encodable {
        let role: String
        let content: String
        let at: Date
    }

    struct Result: Encodable {
        let mode: String
        let status: String
        let model: String
        let depth: String
        let autoAnswer: Bool
        let lines: [LineResult]
        let turns: [TurnOut]
        let yourSpeech: [String]
        let decisions: [Decision]
        let minutes: String?
    }

    private let vm: OverlayViewModel
    private let out: URL
    private var decisions: [Decision] = []

    private init(vm: OverlayViewModel, out: URL) {
        self.vm = vm
        self.out = out
    }

    /// Starts a run when the launch arguments ask for one.
    static func startIfRequested(vm: OverlayViewModel) -> InterviewTestDriver? {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-scriptedinterview"), args.indices.contains(i + 2) {
            let driver = InterviewTestDriver(vm: vm, out: URL(fileURLWithPath: args[i + 2]))
            let scriptURL = URL(fileURLWithPath: args[i + 1])
            Task { await driver.runScripted(scriptURL: scriptURL) }
            return driver
        }
        if let i = args.firstIndex(of: "-livetest"), args.indices.contains(i + 1) {
            let driver = InterviewTestDriver(vm: vm, out: URL(fileURLWithPath: args[i + 1]))
            Task { await driver.runLive() }
            return driver
        }
        return nil
    }

    // MARK: - Scripted

    private func runScripted(scriptURL: URL) async {
        try? await Task.sleep(for: .seconds(1.5))
        guard let data = try? Data(contentsOf: scriptURL),
              let script = try? JSONDecoder().decode(Script.self, from: data) else {
            finish(Result.failure(mode: "scripted", status: "unreadable script at \(scriptURL.path)", vm: vm))
            return
        }

        let store = vm.sessionStore
        let originalSession = store.activeSessionID
        let savedMode = vm.sessionMode
        let savedAutoAnswer = vm.interviewAutoGenerate
        // The store directly: the view model's startNewSession asks the AI to
        // retitle the session being closed, which is the user's own.
        store.startNewSession(mode: .interview, kind: .interview)
        let sessionID = store.activeSessionID
        vm.sessionMode = .interview
        vm.interviewSurfaceMode = .interview
        vm.interviewAutoGenerate = true
        vm.isInterviewSession = true
        vm.isRecording = true
        // The résumé, context and files the setup form would send, so the
        // answers are judged against what a real interview has. The form
        // itself is left as it was.
        vm.pendingAttachments.append(contentsOf: vm.interviewSetupAttachments())
        vm.testObserver = { [weak self] text in
            self?.decisions.append(Decision(at: Date(), text: text))
        }

        var lines: [LineResult] = []
        for line in script.lines {
            if line.speaker == "you" {
                vm.mySpeechSegments.append(SpokenSegment(text: line.text, at: Date()))
                lines.append(LineResult(speaker: "you", text: line.text, expect: nil,
                                        sentText: nil, decisions: [], answer: nil))
                continue
            }
            let firstDecision = decisions.count
            let answersBefore = assistantTurns(in: sessionID).count
            // An unanswered line stays in the strip and the next one is
            // judged with it in front, as the engines compose it.
            vm.transcription = vm.transcription.isEmpty ? line.text : vm.transcription + " " + line.text
            let sentText = vm.transcription
            vm.handleThemSilence()

            let decided = await waitUntil(seconds: 15) {
                self.decisions[firstDecision...].contains { Self.isTerminal($0.text) }
            }
            let sent = decisions[firstDecision...].contains { $0.text == "sent" }
            var answer: String?
            if decided && sent {
                answer = await finishedAnswer(in: sessionID, after: answersBefore)
            }
            lines.append(LineResult(
                speaker: "them", text: line.text, expect: line.expect,
                sentText: sent ? sentText : nil,
                decisions: decided ? decisions[firstDecision...].map(\.text) : ["no decision in 15s"],
                answer: answer))
        }

        let minutes = await endAndWaitForMinutes(sessionID: sessionID)
        let turns = turnsOut(sessionID)
        let speech = vm.mySpeechSegments.map(\.text)

        vm.testObserver = nil
        store.delete(id: sessionID)
        store.continueSession(id: originalSession)
        vm.sessionMode = savedMode
        vm.interviewAutoGenerate = savedAutoAnswer
        store.flushPendingPersist()

        finish(Result(mode: "scripted", status: minutes == nil ? "no debrief: \(vm.statusMessage)" : "ok",
                      model: vm.selectedModel, depth: vm.answerDepth.displayName,
                      autoAnswer: true, lines: lines, turns: turns, yourSpeech: speech,
                      decisions: decisions, minutes: minutes))
    }

    // MARK: - Live audio

    private func runLive() async {
        try? await Task.sleep(for: .seconds(2))
        vm.interviewSurfaceMode = .interview
        vm.primarySurface = .interview
        vm.shellStage = .expanded
        vm.testObserver = { [weak self] text in
            self?.decisions.append(Decision(at: Date(), text: text))
        }
        vm.beginInterviewFromSetup()

        guard await waitUntil(seconds: 20, { self.vm.isRecording }) else {
            finish(Result.failure(mode: "live", status: "recording did not start: \(vm.statusMessage)", vm: vm))
            return
        }
        let sessionID = vm.sessionStore.activeSessionID
        try? "ready".write(to: out.appendingPathComponent("ready"), atomically: true, encoding: .utf8)

        let endFile = out.appendingPathComponent("end").path
        _ = await waitUntil(seconds: 1800) { FileManager.default.fileExists(atPath: endFile) }
        let minutes = await endAndWaitForMinutes(sessionID: sessionID)
        vm.testObserver = nil
        vm.sessionStore.flushPendingPersist()

        finish(Result(mode: "live", status: minutes == nil ? "no debrief: \(vm.statusMessage)" : "ok",
                      model: vm.selectedModel, depth: vm.answerDepth.displayName,
                      autoAnswer: vm.interviewAutoGenerate, lines: [],
                      turns: turnsOut(sessionID), yourSpeech: vm.mySpeechSegments.map(\.text),
                      decisions: decisions, minutes: minutes))
    }

    // MARK: - Helpers

    /// A decision after which nothing more happens for this line.
    private static func isTerminal(_ text: String) -> Bool {
        text == "sent" || text.hasSuffix("skipped") || text == "filler, dropped"
            || text.hasSuffix("action=ignore") || text.hasSuffix("action=wait")
    }

    /// The answer to the line just sent, once it has stopped changing. The
    /// turn exists (empty) before streaming starts, so neither its presence
    /// nor `isSendingToAI` alone says it is done.
    private func finishedAnswer(in sessionID: UUID, after count: Int) async -> String? {
        var last = ""
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let current = assistantTurns(in: sessionID).dropFirst(count).last?.content ?? ""
            if current != last {
                last = current
                stableSince = Date()
            } else if !current.isEmpty, !vm.isSendingToAI, Date().timeIntervalSince(stableSince) > 1.0 {
                return current
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return last.isEmpty ? nil : last
    }

    private func endAndWaitForMinutes(sessionID: UUID) async -> String? {
        _ = await waitUntil(seconds: 120) { !self.vm.isSendingToAI }
        vm.stopInterviewSession()
        _ = await waitUntil(seconds: 150) {
            self.session(sessionID)?.minutes != nil
                || self.vm.statusMessage.hasPrefix("Summary failed")
                || self.vm.statusMessage == "The model returned no summary"
        }
        return session(sessionID)?.minutes
    }

    private func session(_ id: UUID) -> ChatSession? {
        vm.sessionStore.sessions.first { $0.id == id }
    }

    private func assistantTurns(in id: UUID) -> [ChatTurn] {
        (session(id)?.turns ?? []).filter { $0.role == .assistant }
    }

    private func turnsOut(_ id: UUID) -> [TurnOut] {
        (session(id)?.turns ?? []).map { TurnOut(role: $0.role.rawValue, content: $0.content, at: $0.timestamp) }
    }

    private func waitUntil(seconds: Double, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    private func finish(_ result: Result) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if let data = try? encoder.encode(result) {
            try? data.write(to: out.appendingPathComponent("result.json"))
        }
        print("INTERVIEWTEST DONE \(result.status)")
        NSApp.terminate(nil)
    }
}

private extension InterviewTestDriver.Result {
    @MainActor
    static func failure(mode: String, status: String, vm: OverlayViewModel) -> Self {
        Self(mode: mode, status: status, model: vm.selectedModel, depth: vm.answerDepth.displayName,
             autoAnswer: vm.interviewAutoGenerate, lines: [], turns: [], yourSpeech: [],
             decisions: [], minutes: nil)
    }
}
