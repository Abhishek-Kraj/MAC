import Foundation

/// One stretch of the user's own speech between two questions.
///
/// The mic lane is transcribed separately from the call lane in a
/// "You + Them" session; everything said since the last question became one
/// of these, so the transcript reads as a conversation and the coach (next)
/// has the raw material it judges.
struct SpokenSegment: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let at: Date
}

/// Orders the transcript panel's rows: what was asked and what you said,
/// merged by time. Pure, so the ordering and the question numbering are
/// testable without the view.
enum TranscriptTimeline {
    struct Row: Identifiable {
        let id: UUID
        let label: String      // "Q1", "Q2"… for questions, "YOU" for speech
        let text: String
        let isQuestion: Bool
        let at: Date
    }

    static func rows(questions: [ChatTurn], spoken: [SpokenSegment]) -> [Row] {
        var rows: [Row] = []
        // Numbering counts questions only — a YOU row between Q2 and Q3
        // must not push the next question to Q4.
        for (i, q) in questions.enumerated() {
            rows.append(Row(id: q.id, label: "Q\(i + 1)",
                            text: q.content, isQuestion: true, at: q.timestamp))
        }
        for s in spoken {
            rows.append(Row(id: s.id, label: "YOU",
                            text: s.text, isQuestion: false, at: s.at))
        }
        return rows.sorted {
            if $0.at == $1.at { return $0.isQuestion && !$1.isQuestion }
            return $0.at < $1.at
        }
    }

    /// The part of `current` that comes after `attributed`, comparing whole
    /// words with punctuation and case ignored. Apple's recognizer re-emits
    /// its growing string with retroactive revisions ("so it's" → "So it
    /// is"), so a strict string-prefix test would treat every cosmetic
    /// revision as brand-new speech and duplicate it in the next segment.
    static func speechBeyond(_ current: String, attributed: String) -> String {
        let currentWords = current.split(separator: " ")
        let attributedWords = attributed.split(separator: " ")
        var i = 0
        while i < attributedWords.count, i < currentWords.count,
              TranscriptFilter.normalized(String(currentWords[i]))
                == TranscriptFilter.normalized(String(attributedWords[i])) {
            i += 1
        }
        return currentWords.dropFirst(i).joined(separator: " ")
    }
}
