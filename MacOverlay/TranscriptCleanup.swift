import Foundation

/// Deterministic polish for live speech, applied on its way into a turn.
///
/// Transcription is what the interviewer actually said, and what a speech
/// recogniser returns is full of the artifacts of speech: "um", a word
/// repeated while the speaker finds it, no space before a comma. None of
/// that helps the model answer well, and all of it makes the strip the user
/// reads harder to parse mid-interview.
///
/// This is a pure function — no model, no network, no allocation-heavy work
/// — so it costs nothing on the path between the speaker finishing and the
/// answer starting. It is intentionally conservative: it removes noise and
/// tidies spacing, but never rewrites, reorders or "fixes" what was said.
/// Anything that changes meaning is the answer model's job, not a regex.
///
/// Deliberately NOT done here:
///   - adding a final full stop. The Interview prompt uses a bare trailing
///     comma (or nothing) as its "still talking" signal; stamping a period
///     on would make every half-sentence look finished and the model would
///     answer mid-thought.
///   - fixing grammar or rephrasing. "Their going to send it" is the user's
///     data; the answer model reads it and understands it.
enum TranscriptCleanup {

    /// Filler sounds that carry no content. Matched as whole words only,
    /// case-insensitively, so "umm" inside a name ("Summit") survives.
    private static let fillers: Set<String> = [
        "um", "uh", "er", "erm", "ah", "hm", "hmm", "mhm",
    ]

    /// Words that are legitimately repeated and must never be stutter-folded:
    /// "very very good" is emphasis, not a stutter.
    private static let keepDoubles: Set<String> = [
        "very", "really", "just", "no", "yes", "ha", "he", "she", "bye",
    ]

    /// Polish `text` for display and for the model. Returns trimmed output;
    /// empty in, empty out — the caller decides what an empty result means.
    static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return "" }

        var out = text
            // Whitespace first: newlines from a chunked recogniser and runs
            // of spaces are pure noise, and every rule below is simpler once
            // there is exactly one kind of separator.
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        // Standalone fillers: " um," and "(um)" and "um " all go; "Summit"
        // stays. Runs before punctuation spacing so a filler sitting next to
        // a comma doesn't leave ", ," behind.
        let fillerPattern = "(?i)(?<![A-Za-z])(?:\(fillers.sorted().joined(separator: "|")))(?![A-Za-z])"
        out = out.replacingOccurrences(of: fillerPattern, with: " ",
                                        options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        // A filler that was the only thing between two commas leaves a run
        // ("Well , um, I think" -> "Well , , I think"). Collapse the run
        // back to one mark, then let the punctuation pass below attach it to
        // the word it belongs to.
        out = out.replacingOccurrences(of: "([,;:])\\s+(?=[,;:])",
                                        with: "", options: .regularExpression)

        // Stutter folds: an immediately repeated word collapses, unless it is
        // one of the words people repeat on purpose.
        var previous = ""
        let words = out.split(separator: " ", omittingEmptySubsequences: true)
        var folded: [String] = []
        folded.reserveCapacity(words.count)
        for word in words {
            let bare = word.trimmingCharacters(in: .punctuationCharacters
                .union(.symbols)).lowercased()
            if bare == previous && !keepDoubles.contains(bare) && !bare.isEmpty {
                continue
            }
            previous = bare
            folded.append(String(word))
            // A word that ends a sentence closes the stutter window: in
            // "we built it. it shipped", the two "it"s are on either side of
            // a full stop and folding them would swallow a real word.
            if let last = word.last, last == "." || last == "!" || last == "?" {
                previous = ""
            }
        }
        out = folded.joined(separator: " ")

        // Punctuation spacing, in the order that keeps the cases independent:
        //   "word .next" -> "word. next"   then   "word ," -> "word,"
        //   then   "word,next" -> "word, next".
        // Only a mark the recogniser detached is re-spaced before a digit or
        // after a dot: a mark inside a token stays put, or "Node.js", "3.5",
        // "10:30" and "1,000" would split.
        for mark in [",", ".", "!", "?", ";", ":"] {
            let escaped = NSRegularExpression.escapedPattern(for: mark)
            out = out.replacingOccurrences(of: "\\s+\(escaped)(?=[A-Za-z0-9])",
                                            with: "\(mark) ", options: .regularExpression)
            out = out.replacingOccurrences(of: "\\s+\(escaped)", with: mark,
                                            options: .regularExpression)
            if mark != "." {
                out = out.replacingOccurrences(of: "\(escaped)(?=[A-Za-z])",
                                                with: "\(mark) ", options: .regularExpression)
            }
        }

        // Leading space an edge filler may have left at the very start.
        while out.hasPrefix(" ") { out.removeFirst() }
        while out.hasSuffix(" ") { out.removeLast() }

        // Collapse any space that a punctuation pass introduced next to a
        // space that was already there (".  next" -> ". next").
        out = out.replacingOccurrences(of: "\\s{2,}", with: " ",
                                        options: .regularExpression)
        while out.hasPrefix(" ") { out.removeFirst() }
        while out.hasSuffix(" ") { out.removeLast() }

        return capitalizeSentenceStarts(out)
    }

    /// Uppercase the first letter of the text and of anything after a
    /// sentence-ending mark, so a run-on of recogniser fragments still reads
    /// as sentences. The very first character is handled by Swift's own
    /// `uppercased` so a leading quote or digit doesn't hide the first word.
    private static func capitalizeSentenceStarts(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        // The very first character is uppercased in the same pass as the
        // rest, so a leading quote or digit doesn't hide the first word.
        // A mark ends a sentence only when a space follows it; "Node.js" and
        // "3.5" are one token.
        var result = ""
        var pendingCap = true
        var afterMark = false
        for ch in text {
            if ch == "." || ch == "!" || ch == "?" {
                afterMark = true
                result.append(ch)
            } else if ch.isWhitespace {
                if afterMark { pendingCap = true }
                afterMark = false
                result.append(ch)
            } else if pendingCap {
                result.append(contentsOf: String(ch).uppercased())
                pendingCap = false
                afterMark = false
            } else {
                afterMark = false
                result.append(ch)
            }
        }
        return result
    }
}