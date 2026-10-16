import Foundation

/// Shortens an answer so it can actually be said out loud.
///
/// Imported mock-interview answers are the full written thing: the user's own
/// account of a project, complete with caveats and detail. Measured on a real
/// import, the median answer was 230 characters and the longest was 12,908 —
/// 2,581 words. Nobody reads that in the gap between two interview questions,
/// and an answer you cannot read in time is the same as no answer.
///
/// The long text is never destroyed. It is kept as the reference and the short
/// form is what gets shown live, so what you say is your own material,
/// trimmed, rather than something a model wrote about you.
enum AnswerCondenser {

    /// Above this, an answer is a written document rather than something
    /// spoken. Calibrated against the real import: ordinary spoken answers
    /// landed between 100 and 450 characters; the two unusable ones were 8,625
    /// and 12,908.
    static let longAnswerThreshold = 1_500

    /// Roughly a minute and a half of speaking. Long enough to carry the
    /// substance, short enough to read before you are asked the next thing.
    static let targetWordCount = 90

    struct Failure: LocalizedError {
        var errorDescription: String? { "Could not shorten the answer." }
    }

    /// Returns a speakable version, or nil when the original is already short
    /// enough or the model could not do it. Callers must treat nil as "keep
    /// the original" rather than as a failure.
    static func condense(_ answer: String, question: String, key: String) async -> String? {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > longAnswerThreshold else { return nil }

        let body: [String: Any] = [
            "model": "google/gemini-2.5-flash",
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content":
                    "You turn a long written answer into what someone says out loud "
                  + "in an interview. First person, plain words, no lists, no "
                  + "markdown, no preamble. Keep every concrete fact: employers, "
                  + "systems, numbers. Drop hedging, background and caveats. "
                  + "Never invent anything not in the original."],
                ["role": "user", "content":
                    "Interview question: \(question)\n\n"
                  + "Their written answer:\n\(trimmed)\n\n"
                  + "Rewrite as at most \(targetWordCount) words, spoken aloud."],
            ],
            "max_tokens": 400,
        ]
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let content = (json["choices"] as? [[String: Any]])?
            .first?["message"] as? [String: Any]
        var out = (content?["content"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Models wrap prose regardless. Strip fences and a leading label, and
        // refuse anything that is obviously still a document.
        out = out.replacingOccurrences(of: "```[a-zA-Z]*\\n?", with: "",
                                       options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = out.firstIndex(of: ":"),
           out.distance(from: out.startIndex, to: colon) < 40,
           out[..<colon].lowercased().contains("answer") {
            out = String(out[out.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A rewrite that is not meaningfully shorter is not a rewrite.
        guard out.count > 80, out.count < trimmed.count else { return nil }
        return out
    }
}