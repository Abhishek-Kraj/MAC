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

    enum Stage: Equatable {
        case idle
        case researching
        case embedding
        case done(count: Int)
        case failed(String)
    }

    private(set) var stage: Stage = .idle

    /// The role name is the bank key. Deliberately not the posting: a bank
    /// scoped to one JD has to be regenerated for every interview and never
    /// compounds, while a role bank is reused and grows.
    var roleName = ""

    /// What the questions are generated *from*. Left empty on purpose: the
    /// panel reads the interview's existing Context field instead, so the JD
    /// is typed once rather than pasted into two boxes.
    var jobDescription = ""
    var questionCount = 40

    /// Takes the posting from the interview setup's Context field.
    func useContext(_ context: String) {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        // Same floor as `canGenerate`: a phrase is not a posting.
        guard trimmed.count > 40, trimmed.count > jobDescription.count else { return }
        jobDescription = trimmed
    }

    var isRunning: Bool { stage == .researching || stage == .embedding }

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

    func generate() async {
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
                user: Self.prompt(role: role, jd: jd, count: questionCount))
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

            stage = .embedding
            await PreparedAnswerLookup.shared.embedBank(role)
            if let error = PreparedAnswerLookup.shared.lastError {
                stage = .failed("Bank saved, but matching is not ready: \(error)")
                return
            }
            _ = PrepBankBackup.snapshot()
            stage = .done(count: parsed.count)
        } catch {
            stage = .failed((error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription)
        }
    }

    // MARK: - Model call

    struct Generated: Decodable {
        let q: String, a: String, topic: String?
    }

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
    static func debugPrompt(role: String, jd: String, count: Int) -> String {
        prompt(role: role, jd: jd, count: count)
    }

    private static func prompt(role: String, jd: String, count: Int) -> String {
        """
        Research this role and write the questions an interviewer would actually ask.

        Role: \(role)

        The candidate's own context — the posting, the company, and whatever
        they have written about their experience and talking points:
        \(jd)

        Use that twice: to work out what the role will probe, and to ground each
        answer in what the candidate has actually done, written in the first
        person. Do not invent employers, projects, metrics or employers' names
        that are not in the context above — if the context is thin, keep the
        answer general rather than specific and fictional.

        Return ONLY a JSON array. Each element:
        {"q":"<the interviewer's question, one line>",
         "topic":"<capacity|governance|migration|cost|pipelines|modelling|leadership>",
         "a":"<the answer to say out loud, 40-70 words, first person>"}
        Write \(count) questions. Mix scenario questions with technical deep-dives. Be
        specific to this posting — not advice anyone could give for any job.
        """
    }

    /// Models often wrap JSON in prose or a fenced block, so the array is
    /// located rather than assumed.
    static func parse(_ raw: String) -> [Generated] {
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"), start < end else { return [] }
        let slice = String(raw[start...end])
        guard let data = slice.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Generated].self, from: data)) ?? []
    }
}