import Foundation
import Observation

/// Builds a prepared-question bank from a job description.
///
/// Two calls, in order, because they do different jobs:
///   1. `:online` — the model researches the role and writes questions that are
///      specific to it, rather than a generic list of "tell me about
///      yourself".
///   2. Plain — the bank is embedded afterwards, so live matching works.
///
/// Measured: 50 questions from a real Fabric CoE posting took 75 s and cost
/// $0.027. That is a once-per-role cost, not a per-answer one.
@Observable
@MainActor
final class PrepGenerator {

    /// Shared, because preparation takes minutes and the sheet it starts from
    /// can be closed while it runs. Held in view state it would be torn down
    /// with the sheet and the work would be lost mid-flight.
    static let shared = PrepGenerator()

    enum Stage: Equatable {
        case idle
        case researching
        case embedding
        case done(count: Int)
        case failed(String)

        var isFailure: Bool { if case .failed = self { return true }; return false }
        var failureReason: String? { if case .failed(let why) = self { return why }; return nil }
    }

    private(set) var stage: Stage = .idle
    /// Cancels an in-flight run, since preparation takes minutes and may turn
    /// out to be the wrong posting.
    @ObservationIgnored private var run: Task<Void, Never>?

    func cancel() {
        run?.cancel()
        run = nil
        stage = .idle
    }

    /// The role name is the bank key. Deliberately not the posting: a bank
    /// scoped to one JD has to be regenerated for every interview and never
    /// compounds, while a role bank is reused and grows.
    var roleName = ""

    /// What the questions are generated *from*. Left empty on purpose: the
    /// panel reads the interview's existing Context field instead, so the JD
    /// is typed once rather than pasted into two boxes.
    var jobDescription = ""
    /// Extracted text of the résumé attached on the setup screen. Supplied by
    /// the caller rather than read here, so the generator has no opinion about
    /// where a résumé comes from.
    var resumeText = ""
    var questionCount = 40

    /// Takes the posting from the interview setup's Context field.
    func useContext(_ context: String) {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        // Same floor as `canGenerate`: a phrase is not a posting.
        guard trimmed.count > 40, trimmed.count > jobDescription.count else { return }
        jobDescription = trimmed
    }

    var isRunning: Bool { stage == .researching || stage == .embedding }

    /// True when the last run failed. Exposed so the card can tell "never
    /// started" apart from "started and broke" — they look identical
    /// otherwise, and only one of them is worth retrying.
    var stageFailed: Bool { stage.isFailure }

    var canGenerate: Bool {
        !isRunning
            && roleName.trimmingCharacters(in: .whitespacesAndNewlines).count > 2
            && jobDescription.trimmingCharacters(in: .whitespacesAndNewlines).count > 40
    }

    /// Why the button is disabled, shown under it rather than left as a dead
    /// control.
    var guidance: String? {
        guard !isRunning else { return nil }
        if roleName.trimmingCharacters(in: .whitespacesAndNewlines).count <= 2 {
            return "Name the role — this is how the bank is filed and reused."
        }
        if jobDescription.trimmingCharacters(in: .whitespacesAndNewlines).count <= 40 {
            return "Paste the job description, or at least the responsibilities."
        }
        return nil
    }

    // MARK: - Generate

    /// Starts a run and returns immediately. Use this from a button: the work
    /// belongs to the generator, not to whatever sheet started it.
    func start(context: String, resume: String) {
        guard canGenerate else { return }
        jobDescription = jobDescription.isEmpty ? context : jobDescription
        resumeText = resume
        run?.cancel()
        run = Task { await generate() }
    }

    private func generate() async {
        guard canGenerate else { return }
        let role = roleName.trimmingCharacters(in: .whitespacesAndNewlines)
        stage = .researching

        let key = UserDefaults.standard.string(forKey: "openRouterAPIKey")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            stage = .failed("Add your OpenRouter key in Settings → AI first.")
            return
        }

        do {
            // No separate JD box: whatever the interview setup already holds in
            // Context is the posting, unless one was pasted in specifically.
            let jd = jobDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = try await Self.ask(
                key: key,
                system: "You write interview questions and model answers. You reply with JSON only.",
                user: Self.prompt(role: role, jd: jd,
                                  resume: resumeText, count: questionCount))
            let parsed = Self.parse(raw)
            guard !parsed.isEmpty else {
                stage = .failed("The model returned no usable questions. Try again.")
                return
            }

            let bank = PrepBank.shared
            bank.activeBankID = role
            // Anything the bank already had for this role is kept: regenerating
            // should top it up, not throw away questions the user has since
            // captured from a real interview.
            bank.add(questions: parsed.map {
                PrepQuestion(question: $0.q, answer: $0.a,
                             source: .researched, topic: $0.topic, bankID: role)
            })

            try Task.checkCancellation()
            stage = .embedding
            await PreparedAnswerLookup.shared.embedBank(role)
            if let error = PreparedAnswerLookup.shared.lastError {
                stage = .failed("Bank saved, but matching is not ready: \(error)")
                return
            }
            _ = PrepBankBackup.snapshot()
            stage = .done(count: parsed.count)
        } catch is CancellationError {
            stage = .idle
        } catch {
            stage = .failed((error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription)
        }
    }

    // MARK: - Model call

    struct Generated: Decodable {
        let q: String, a: String, topic: String?
    }

    /// Key spellings seen in the wild. Gemini's `:online` variant does not
    /// return the schema it was given — asked for `{"q":…,"topic":…,"a":…}` it
    /// replies with `{"category":…,"question":…,"interviewer_intent":…,
    /// "answer":…}` and wraps the array in an object. Strict decoding turned a
    /// perfectly good answer into zero questions.
    private static let questionKeys = ["q", "question", "prompt", "ask"]
    private static let answerKeys   = ["a", "answer", "response", "model_answer"]
    private static let topicKeys    = ["topic", "category", "theme", "area"]

    private static func ask(key: String, system: String, user: String) async throws -> String {
        let body: [String: Any] = [
            "model": "google/gemini-3.8-flash:online",
            "temperature": 0.4,
            "messages": [["role": "system", "content": system],
                         ["role": "user", "content": user]],
            "max_tokens": 8000,
        ]
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure("no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw Failure("HTTP \(http.statusCode) \(text.prefix(160))")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = (json?["choices"] as? [[String: Any]])?
            .first?["message"] as? [String: Any]
        return (content?["content"] as? String) ?? ""
    }

    private struct Failure: LocalizedError {
        let detail: String
        init(_ d: String) { detail = d }
        var errorDescription: String? { detail }
    }

    /// Exposed so the prompt can be asserted in tests without a network call.
    static func debugPrompt(role: String, jd: String,
                            resume: String = "", count: Int) -> String {
        prompt(role: role, jd: jd, resume: resume, count: count)
    }

    private static func prompt(role: String, jd: String,
                               resume: String, count: Int) -> String {
        let cv = resume.trimmingCharacters(in: .whitespacesAndNewlines)
        let grounding: String
        if cv.count > 80 {
            let body = cv.count > 6000 ? String(cv.prefix(6000)) + "\n[truncated]" : cv
            grounding = """
            The candidate's résumé. Every answer must be grounded in something \
            that appears here — their employers, projects, stack and numbers. \
            Quote nothing that is not in this résumé or the context above.

            \(body)
            """
        } else {
            grounding = """
            No résumé is attached. Keep answers to method and judgement rather \
            than to invented projects, employers or metrics.
            """
        }
        return """
        Research this role and write the questions an interviewer would actually ask.

        Role: \(role)

        The candidate's own context — the posting, the company, and whatever
        they have written about their experience and talking points:
        \(jd)

        Use that twice: to work out what the role will probe, and to ground each
        answer in what the candidate has actually done, written in the first
        person.

        \(grounding)

        Return ONLY a JSON array. Each element:
        {"q":"<the interviewer's question, one line>",
         "topic":"<capacity|governance|migration|cost|pipelines|modelling|leadership>",
         "a":"<the answer to say out loud, 40-70 words, first person>"}
        Write \(count) questions. Mix scenario questions with technical deep-dives. Be
        specific to this posting — not advice anyone could give for any job.
        """
    }

    /// Models wrap JSON in prose, in a fenced block, or in an object with the
    /// array under a key of its own. So the array is located rather than
    /// assumed, and each element is read tolerantly.
    static func parse(_ raw: String) -> [Generated] {
        guard let data = locateArray(in: raw) else { return [] }
        let objects: [[String: Any]]
        if let wrapped = try? JSONSerialization.jsonObject(with: data) {
            if let arr = wrapped as? [[String: Any]] {
                objects = arr
            } else if let dict = wrapped as? [String: Any] {
                // Find the first array-of-objects value, whatever it is called.
                let arrays = dict.values.compactMap { $0 as? [[String: Any]] }
                guard let first = arrays.first else { return [] }
                objects = first
            } else {
                return []
            }
        } else {
            return []
        }

        var out: [Generated] = []
        for o in objects {
            // Lowercased key map: case varies between models and revisions.
            var fields: [String: Any] = [:]
            for (k, v) in o { fields[k.lowercased()] = v }

            let q = (questionKeys.lazy.compactMap { fields[$0] as? String })
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let a = (answerKeys.lazy.compactMap { fields[$0] as? String })
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            // An element missing either half is unusable; skipping it is better
            // than admitting a blank question with a real answer attached.
            guard let q, let a else { continue }
            out.append(Generated(
                q: q.trimmingCharacters(in: .whitespacesAndNewlines),
                a: a.trimmingCharacters(in: .whitespacesAndNewlines),
                topic: topicKeys.lazy.compactMap { fields[$0] as? String }.first))
        }
        return out
    }

    /// Returns the bytes of the outermost `[ … ]`, or of the whole string when
    /// the model returned a bare object instead.
    private static func locateArray(in raw: String) -> Data? {
        guard let start = raw.firstIndex(of: "[") else {
            return raw.data(using: .utf8)   // object-wrapped, no array text
        }
        // Scan for the matching close bracket, respecting strings and escapes,
        // so a `]` inside an answer cannot truncate the array.
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < raw.endIndex {
            let ch = raw[idx]
            if escaped { escaped = false }
            else if ch == "\\" { escaped = true }
            else if ch == "\"" { inString.toggle() }
            else if !inString {
                if ch == "[" { depth += 1 }
                if ch == "]" {
                    depth -= 1
                    if depth == 0 { return String(raw[start...idx]).data(using: .utf8) }
                }
            }
            idx = raw.index(after: idx)
        }
        return nil
    }
}