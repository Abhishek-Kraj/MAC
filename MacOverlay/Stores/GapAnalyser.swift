import Foundation

/// Works out what the question bank does not cover.
///
/// Asked for twice and not built until now: "if I upload my mock interview,
/// will it understand what I know and what I don't?" Importing a bank answers
/// the first half only. It records what you already handled well. It says
/// nothing about the capability areas in the posting that nothing in the bank
/// touches, which is exactly where an interview goes wrong — you are never
/// surprised by a question you prepared for; you are surprised by one you
/// didn't.
///
/// The model is asked to judge coverage rather than to generate, because the
/// useful output is a gap list, not more questions. Questions for the gaps
/// come from the ordinary research path, which already knows how to write them
/// and how to avoid duplicating what exists.
enum GapAnalyser {

    /// One capability area from the posting, and how well the bank covers it.
    struct Gap: Identifiable, Equatable, Codable {
        var id: String { area }
        /// The capability, as the posting names it.
        let area: String
        /// Priority as the posting states it, if it says.
        let priority: String?
        /// Questions already in the bank that touch this area. Filled in from
        /// the bank, never returned by the model.
        let covered: [String]
        /// What is missing, in the model's words.
        let gap: String
        /// How exposed the candidate is, 0–3.
        let risk: Int

        /// Judged by the model's own risk score rather than by scanning its
        /// prose for the word "None" — it says "well covered" as often as it
        /// says "None", and every area looked like a gap because of it.
        var isCovered: Bool { risk == 0 }

        /// Plain-language summary for the sheet.
        var line: String {
            let mark = isCovered ? "✓" : (risk >= 3 ? "!!" : "!")
            let pri = priority.map { " (\($0))" } ?? ""
            return "\(mark) \(area)\(pri) — \(covered.count) prepared"
        }
    }

    struct Report {
        var gaps: [Gap]
        /// Areas the model rates as exposing, worst first.
        var needsWork: [Gap] { gaps.filter { !$0.isCovered }.sorted { $0.risk > $1.risk } }
        /// Areas fully covered.
        var solid: [Gap] { gaps.filter(\.isCovered) }
    }

    static func analyse(jd: String, role: String, bank: [PrepQuestion],
                        key: String) async -> Report {
        let areas = Dictionary(grouping: bank, by: { $0.topic ?? "" })
            .filter { !$0.key.isEmpty }
        let covered = areas
            .map { "\($0.key): \($0.value.count) questions — "
                 + $0.value.prefix(4).map(\.question).joined(separator: " | ") }
            .joined(separator: "\n")

        let user = """
        JOB DESCRIPTION for \(role):
        \(String(jd.prefix(6_000)))

        QUESTIONS THE CANDIDATE HAS ALREADY PREPARED:
        \(covered.isEmpty ? "(none)" : covered)

        If the posting contains a table of capability areas with a priority
        column, use exactly those rows as your areas and at most 15 of them.
        Otherwise use the headings of its main sections. Never use a single
        sentence of prose as an area name — an area is a capability, such as
        "Capacity planning", not a requirement sentence.

        For each area, say how well the prepared questions above cover it.

        Reply with a JSON array only. Each element:
        {"area":"<capability area>",
         "priority":"<Essential|Desirable, or empty>",
         "gap":"<what is not covered, or the word None if fully covered>",
         "risk":<0 to 3: how exposed the candidate would be on this>}

        Be honest. An area with no prepared question is risk 3 even if it sounds
        easy, because being unprepared is what costs an interview.
        """
        let body: [String: Any] = [
            "model": "google/gemini-2.5-flash",
            "temperature": 0.2,
            "messages": [["role": "user", "content": user]],
            "max_tokens": 3_000,
        ]
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (json["choices"] as? [[String: Any]])?.first?["message"]
                  as? [String: Any],
              let raw = content["content"] as? String
        else { return Report(gaps: []) }

        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"),
              start < end else { return Report(gaps: []) }

        // Decoded through a payload rather than `Gap` itself. `Gap` carries
        // `covered`, which comes from the bank and not from the model, so
        // decoding `Gap` directly always failed on a missing key — which is
        // why this returned nothing at all while the model was answering
        // perfectly well.
        let payload = (try? JSONDecoder().decode([Payload].self,
                       from: String(raw[start...end]).data(using: .utf8) ?? Data())) ?? []
        // `covered` is worked out here, not asked of the model: the model was
        // given the questions and reports prose, and prose cannot say "you have
        // three questions on this". Counting the overlap locally is both
        // cheaper and the only version that agrees with the bank.
        return Report(gaps: payload.map { p in
            Gap(area: p.area, priority: p.priority,
                covered: Self.matchingQuestions(for: p, in: bank),
                gap: p.gap, risk: p.risk)
        })
    }

    /// Bank questions that plausibly belong to an area.
    ///
    /// Counted on shared content words rather than asked of the model. The
    /// area name is short and the model's prose is long, so matching on the
    /// gap text as well as the name is what makes this land — an area called
    /// "Capacity planning" with a gap about "chargeback and cost allocation"
    /// needs the questions that mention chargeback, not the ones that
    /// literally contain both words of the name.
    static func matchingQuestions(for gap: Payload, in bank: [PrepQuestion]) -> [String] {
        let seeds = Set((gap.area + " " + gap.gap)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count > 4 })
        guard !seeds.isEmpty else { return [] }

        var scored: [(String, Int)] = []
        for q in bank {
            let words = Set(q.question.lowercased()
                .split(whereSeparator: { !$0.isLetter }).map(String.init))
            let hits = seeds.filter { words.contains($0) }.count
            if hits > 0 { scored.append((q.question, hits)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(6).map(\.0)
    }

    /// What the model is actually asked for.
    struct Payload: Decodable {
        let area: String
        let priority: String?
        let gap: String
        let risk: Int
    }
}