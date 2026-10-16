import Foundation

/// How much an interview answer should say.
///
/// The interview prompt used to hard-code "at most 3 short bullets" for
/// every question. That suits a yes/no question and starves a design
/// question: "Isn't Fabric just Synapse renamed?" genuinely needs two
/// points, while "how would you migrate ten legal entities onto one capacity"
/// needs reasoning, trade-offs and failure modes.
///
/// Depth is chosen per interview rather than per question, because the user
/// is mid-answer and cannot be asked to pick.
enum AnswerDepth: String, CaseIterable, Identifiable, Codable {
    /// Fastest to read on a phone screen. For warm-ups and quick follow-ups.
    case brief
    /// The default. One verbatim opener, then a few points and one example.
    case standard
    /// Full reasoning, including trade-offs and what could go wrong.
    case deep

    static let storageKey = "interviewAnswerDepth"
    static let `default`: AnswerDepth = .standard

    var id: String { rawValue }

    /// The saved choice, used when building the system prompt.
    static var current: AnswerDepth {
        UserDefaults.standard.string(forKey: storageKey)
            .flatMap(AnswerDepth.init(rawValue:)) ?? .default
    }

    var displayName: String {
        switch self {
        case .brief:    return "Brief"
        case .standard: return "Standard"
        case .deep:     return "Deep"
        }
    }

    var blurb: String {
        switch self {
        case .brief:
            return "Opener plus two points. Fastest to read."
        case .standard:
            return "Opener, a few points, and one real example."
        case .deep:
            return "Full reasoning: claim, trade-off, risk."
        }
    }

    /// The block spliced into the interview system prompt. Only the depth
    /// clause changes — everything else about the interview prompt is
    /// unchanged, so turning depth up does not alter the persona.
    var instruction: String {
        switch self {
        case .brief:
            return """
            - FIRST LINE: the direct opening sentence the user can say verbatim, immediately. \
            No preamble, no "Great question", no headings, never restate the question.
            - Then at most 2 short bullets. One point, done. Bold the keyword that matters. \
            No example, no caveat — the user is running out of time.
            """
        case .standard:
            return """
            - FIRST LINE: the direct opening sentence the user can say verbatim, immediately. \
            No preamble, no "Great question", no headings, never restate the question.
            - Then 2-4 short bullets: the reasoning, then one concrete detail from the user's \
            own work (a real project, employer, or metric) so the answer is not generic. \
            Bold the 2-3 keywords that matter so they pop while skimming.
            - If the claim has a real weakness, name it in one clause rather than hiding it. \
            Do not pad to reach a count.
            """
        case .deep:
            return """
            - FIRST LINE: the direct opening sentence the user can say verbatim, immediately. \
            No preamble, no "Great question", no headings, never restate the question.
            - Then develop it properly, in prose or tight bullets, in this order: the claim; \
            why it holds; the trade-off it accepts; what the user would actually do first; \
            what could go wrong and how they would catch it.
            - Ground each step in the user's real projects, employers and stack. \
            Weigh the alternatives you rejected and say why — "I would not do X because…".
            - Bold the 2-3 keywords that carry the answer.
            - Length is earned by the question, not by a quota. A simple question still gets \
            a short answer; a design question earns a real one.
            """
        }
    }
}