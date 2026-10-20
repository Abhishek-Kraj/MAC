import Foundation

/// Matches what the interviewer just said against the prepared questions.
///
/// Deliberately lexical — BM25 over a small in-house corpus — with no
/// embeddings and no network. Two reasons:
///
///  1. The live path must not depend on Ollama, a local server, or any other
///     thing the user might uninstall. The feature has to work with nothing
///     but the app itself.
///  2. It runs in well under a millisecond, which is the entire point. The
///     alternative — routing the question through a model to pick from the
///     bank — costs ~2 s and a token spend, which is exactly what prepared
///     answers exist to avoid.
///
/// The hard part is not ranking, it is *knowing when not to answer*. A wrong
/// prepared answer shown mid-interview is worse than a two-second wait, so
/// retrieval is judged on the **margin** between the best hit and the
/// runner-up rather than on an absolute score, and anything under the
/// threshold falls through to normal generation.
enum PrepMatcher {

    /// Minimum gap between the best match and the next one before a prepared
    /// answer is trusted.
    ///
    /// Calibrated on an eight-question bank, where the gap separates cleanly:
    /// genuine rewordings scored +1.63 and above, while the one confusion —
    /// "split the F-SKU capacity across business units" matching the
    /// chargeback entry — measured +0.64. Absolute score is useless as a
    /// gate: that wrong answer scored *highest of all eight*.
    ///
    /// See the note on `PrepMatcher.measuredLimits` for what happens when the
    /// bank grows to a realistic fifty questions.
    static let minimumMargin: Double = 1.2

    /// A match must also clear this on absolute score, so a bank where nothing
    /// is relevant cannot produce a high margin out of two equally-bad hits.
    static let minimumScore: Double = 1.0

    struct Match {
        let question: PrepQuestion
        let score: Double
        /// Gap over the runner-up. The real confidence signal.
        let margin: Double
        /// False when the match ranked first but was not confident enough to
        /// show. Callers should generate instead.
        ///
        /// Lexical scoring mixes a high IDF-weighted sum with a margin, so both
        /// must clear their bar. Semantic scoring is a bounded cosine, where a
        /// margin of 0.05 over the runner-up is already a large relative gap,
        /// so the margin alone decides.
        var isConfident: Bool { score >= minimumScore && margin >= minimumMargin }
        var isSemanticallyConfident: Bool { margin >= semanticMinimumMargin }
    }

    // MARK: - Tokenising

    /// Words carrying no retrieval signal. Small on purpose: "how", "why" and
    /// "what" are near-constant in interview questions and would flatten every
    /// margin.
    private static let stopWords: Set<String> = [
        "the", "a", "an", "to", "of", "in", "is", "are", "was", "were", "you",
        "your", "yours", "and", "or", "for", "on", "with", "that", "this", "these",
        "it", "its", "be", "been", "as", "at", "by", "from", "we", "our", "us",
        "have", "has", "had", "do", "does", "did", "not", "but", "if", "then",
        "than", "so", "can", "could", "would", "should", "will", "shall", "may",
        "i", "me", "my", "they", "them", "their", "he", "she", "his", "her",
    ]

    /// Lowercase, strip to word characters, drop stop words, stem.
    static func tokenise(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
            .map(stem)
    }


    /// A deliberately small suffix stripper, not a linguistic stemmer.
    ///
    /// Without it, lexical matching fails on morphology in exactly the cases
    /// that matter here: "salary" and "salaries" share no token, so a
    /// question about HR salary data retrieved the Cognos question instead.
    /// Catching that one plural cost more than anything else in the matcher.
    ///
    /// Only strips when enough of the word survives, so "press" is not turned
    /// into "pre" and "business" into "busines".
    static func stem(_ word: String) -> String {
        let suffixes: [(String, String)] = [
            ("ies", "y"), ("sses", "ss"), ("ss", "ss"), ("ing", ""),
            ("edly", ""), ("ed", ""), ("ly", ""), ("ment", ""),
        ]
        for (suffix, replacement) in suffixes {
            if word.hasSuffix(suffix), word.count > suffix.count + 3 {
                return word.replacingOccurrences(of: suffix, with: replacement,
                                                 options: .anchored, range: nil)
                    .replacingOccurrences(of: suffix, with: replacement,
                                          options: [.anchored, .backwards], range: nil)
            }
        }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), word.count > 4 {
            return String(word.dropLast())
        }
        return word
    }

    // MARK: - Semantic matching

    /// Cosine similarity, treating an unembedded question as unmatched.
    static func cosine(_ a: [Double], _ b: [Double]) -> Double? {
        guard !a.isEmpty, a.count == b.count else { return nil }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return nil }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// Ranks by embedding similarity.
    ///
    /// Judged on the **margin** over the runner-up, same as the lexical path,
    /// and the threshold is on a different scale because cosine similarities
    /// between related English sentences cluster high — a correct match sits
    /// around +0.07 to +0.27 above its nearest rival, while a wrong one
    /// measures +0.003 to +0.024. Questions that were not embedded are skipped
    /// rather than scored as zero, so an un-embedded bank falls through to
    /// generation instead of silently matching nonsense.
    static func semanticRank(query embedding: [Double],
                             against questions: [PrepQuestion]) -> [Match] {
        var scored: [(question: PrepQuestion, score: Double)] = []
        for q in questions {
            guard let v = q.embedding, let sim = cosine(embedding, v) else { continue }
            scored.append((q, sim))
        }
        guard !scored.isEmpty else { return [] }
        scored.sort { $0.score > $1.score }

        return scored.enumerated().map { rank, entry in
            let margin = entry.score - (rank + 1 < scored.count ? scored[rank + 1].score : 0)
            return Match(question: entry.question, score: entry.score, margin: margin)
        }
    }

    /// Best semantic hit, or nil when nothing clears the gate.
    static func semanticBest(query embedding: [Double],
                             against questions: [PrepQuestion]) -> Match? {
        let ranked = semanticRank(query: embedding, against: questions)
        guard let top = ranked.first else { return nil }
        // A clear lead is not enough: "Tell me about a time you disagreed with
        // a stakeholder" led the bank by +0.078 on a question about data-silo
        // pushback it only resembles (similarity 0.45). The question itself
        // has to be close, too.
        return top.score >= semanticMinimumScore && top.margin >= semanticMinimumMargin ? top : nil
    }

    /// Similarity the best question must reach before its answer is shown.
    /// Measured 2026-10-20 on the 62-question Fabric bank with 20 live-style
    /// queries: 8 paraphrases of bank questions scored 0.756–0.941; 12 other
    /// interview questions, including two the margin gate alone let through
    /// (0.453 and 0.513), scored at most 0.539. This sits in the gap.
    static let semanticMinimumScore: Double = 0.65

    /// Margin required before a semantic match is trusted. Calibrated on a
    /// 50-question bank: every correct retrieval cleared +0.071, every wrong
    /// one sat at or below +0.024, so this sits in the gap.
    static let semanticMinimumMargin: Double = 0.05

    /// What this ranker can and cannot do, measured on 2026-10-16 against a
    /// real 50-question bank generated from a Fabric CoE job description.
    ///
    /// On a small bank (8 questions) it behaves: 7 of 8 paraphrases retrieved
    /// the right entry, 1 was safely refused.
    ///
    /// On a realistic bank it does not. Across 50 dense, same-domain questions
    /// every entry shares "Fabric", "capacity", "entity", "data", so single
    /// tokens stop discriminating:
    ///
    ///   threshold  shown  correct  wrong shown
    ///     1.2         5        4           1
    ///     2.5         2        2           0   <- safe but only 25% useful
    ///
    /// The one thing that must never happen is a confident wrong answer shown
    /// while someone waits. Two fixes were tried and measured:
    ///
    ///   - adjacent-token (bigram) bonus: *worse*. Three confident answers
    ///     shown instead of one, because a shared phrase like "month end"
    ///     amplified the wrong entry.
    ///   - restricting candidates to one topic (~7 entries): 5 of 8 correct
    ///     but still 3 wrong.
    ///
    /// Cloud embeddings were measured on the same bank and separate cleanly:
    /// correct hits scored +0.071 to +0.274, wrong ones +0.003 to +0.024, so a
    /// gate at +0.05 yields 5 of 8 right and none wrong. Embeddings are not a
    /// new dependency — the app already routes through OpenRouter — but they
    /// do need a network call per live question.
    ///
    /// Until that decision is made, `minimumMargin` is set for safety rather
    /// than coverage, and the feature is wired up but not enabled for live
    /// matching.
    static let measuredLimits =
        "Tuned on an 8-question bank. On a realistic 50-question same-domain bank this " +
        "ranker produces confident wrong matches; do not enable live matching without " +
        "embeddings. See PrepMatcher source."

    /// Cheap de-duplication key for captured questions.
    static func normalise(_ text: String) -> String {
        tokenise(text).joined(separator: " ")
    }

    // MARK: - BM25

    /// Ranks `questions` against `query` and returns them best-first.
    ///
    /// Corpus is tiny (tens of entries), so a straightforward in-memory
    /// implementation is the right one — no index to build, nothing to
    /// invalidate when the bank is edited mid-session.
    static func rank(query: String, against questions: [PrepQuestion]) -> [Match] {
        let docs = questions.map { tokenise($0.question) }
        guard !docs.isEmpty else { return [] }

        let q = tokenise(query)
        guard !q.isEmpty else { return [] }

        let n = docs.count
        let lengths = docs.map(\.count)
        let avgLength = Double(lengths.reduce(0, +)) / Double(n)

        // Document frequency per token.
        var docFreq: [String: Int] = [:]
        for doc in docs {
            for token in Set(doc) where q.contains(token) {
                docFreq[token, default: 0] += 1
            }
        }

        let k1 = 1.5, b = 0.75
        var results: [(Int, Double)] = []
        results.reserveCapacity(n)

        for (index, doc) in docs.enumerated() {
            let counts = frequencies(doc)
            var score = 0.0
            for token in Set(q) {
                guard let tf = counts[token] else { continue }
                let df = Double(docFreq[token] ?? 0)
                let idf = log(1 + (Double(n) - df + 0.5) / (df + 0.5))
                let norm = 1 - b + b * (Double(lengths[index]) / avgLength)
                score += idf * (Double(tf) * (k1 + 1)) / (Double(tf) + k1 * norm)
            }
            if score > 0 { results.append((index, score)) }
        }

        results.sort { $0.1 > $1.1 }
        return results.enumerated().map { rank, entry in
            // The runner-up score is only known once the list is ordered.
            let margin = rank == 0
                ? entry.1 - (results.count > 1 ? results[1].1 : 0)
                : entry.1 - results[0].1
            return Match(question: questions[entry.0], score: entry.1, margin: margin)
        }
    }

    /// Best hit, or nil when nothing clears the confidence gate.
    static func best(query: String, against questions: [PrepQuestion]) -> Match? {
        let ranked = rank(query: query, against: questions)
        guard let top = ranked.first else { return nil }
        return top.isConfident ? top : nil
    }

    /// The top hit regardless of confidence, for the "was this close?" hint.
    static func closest(query: String, against questions: [PrepQuestion]) -> Match? {
        rank(query: query, against: questions).first
    }

    private static func frequencies(_ tokens: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        for t in tokens { out[t, default: 0] += 1 }
        return out
    }
}