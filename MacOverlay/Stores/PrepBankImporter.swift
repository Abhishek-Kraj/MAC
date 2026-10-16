import Foundation

/// Reads a question bank from somewhere that is not this app.
///
/// The realistic case is a mock interview done with another tool — you already
/// have the questions, and the answers that came back. Those are worth more
/// than anything a fresh research pass produces, because they are the ones a
/// real interviewer actually asked.
///
/// Everything else in prep assumes one machine wrote the text in one shape.
/// Pasted and exported material arrives as anything at all, so this is a
/// ladder of increasingly forgiving formats, tried in order.
enum PrepBankImporter {

    struct Pair: Equatable {
        var question: String
        var answer: String
        var topic: String?
    }

    enum Format: Equatable {
        case json
        case labelled      // "Q:" / "A:" per line
        case markdown      // headings and bullets
        case transcript    // alternating prose blocks
    }

    /// What the text turned out to be, for telling the user what was found.
    struct Result {
        var pairs: [Pair]
        var format: Format
    }

    // MARK: - Entry point

    static func parse(_ text: String) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Result(pairs: [], format: .labelled) }

        if trimmed.first == "[" || trimmed.first == "{",
           !parseJSON(trimmed).isEmpty {
            return Result(pairs: parseJSON(trimmed), format: .json)
        }
        let labelled = parseLabelled(trimmed)
        if !labelled.isEmpty { return Result(pairs: labelled, format: .labelled) }
        let markdown = parseMarkdown(trimmed)
        if !markdown.isEmpty { return Result(pairs: markdown, format: .markdown) }
        return Result(pairs: parseTranscript(trimmed), format: .transcript)
    }

    /// Files a user is likely to reach for. Deliberately generous: this is
    /// their own text, and refusing it teaches them nothing.
    static func readFile(at url: URL) throws -> String {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        if let s = try? String(contentsOf: url, encoding: .isoLatin1) { return s }
        // A file in a script we do not read, or binary. Said plainly rather
        // than as a code the caller would have to look up.
        throw CocoaError(.fileReadInapplicableStringEncoding,
                         userInfo: [NSLocalizedDescriptionKey:
                            "Could not read \(url.lastPathComponent) as text. Save it as .txt, .md or .json."])
    }

    // MARK: - JSON

    /// Reuses the same tolerance as the generator: models rename keys, and a
    /// file exported by another tool will have been through a model too.
    private static func parseJSON(_ text: String) -> [Pair] {
        guard let data = locateArray(in: text) else { return [] }
        guard let top = try? JSONSerialization.jsonObject(with: data) else { return [] }

        let objects: [[String: Any]]
        if let arr = top as? [[String: Any]] {
            objects = arr
        } else if let dict = top as? [String: Any] {
            guard let first = dict.values
                .compactMap({ $0 as? [[String: Any]] }).first else { return [] }
            objects = first
        } else { return [] }

        let qKeys = ["q", "question", "prompt", "ask"]
        let aKeys = ["a", "answer", "response", "model_answer"]
        let tKeys = ["topic", "category", "theme", "area"]

        var out: [Pair] = []
        for o in objects {
            var f: [String: Any] = [:]
            for (k, v) in o { f[k.lowercased()] = v }
            guard let q = pick(f, qKeys), let a = pick(f, aKeys) else { continue }
            out.append(Pair(question: q, answer: a, topic: pick(f, tKeys)))
        }
        return out
    }

    private static func pick(_ fields: [String: Any], _ keys: [String]) -> String? {
        for k in keys {
            if let v = fields[k] as? String,
               !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// String-aware bracket scan: a `]` inside an answer must not cut the
    /// array short. Same reason as the generator's.
    private static func locateArray(in raw: String) -> Data? {
        guard let start = raw.firstIndex(of: "[") else {
            return raw.data(using: .utf8)
        }
        var depth = 0, inString = false, escaped = false
        var i = start
        while i < raw.endIndex {
            let ch = raw[i]
            if escaped { escaped = false }
            else if ch == "\\" { escaped = true }
            else if ch == "\"" { inString.toggle() }
            else if !inString {
                if ch == "[" { depth += 1 }
                if ch == "]" {
                    depth -= 1
                    if depth == 0 { return String(raw[start...i]).data(using: .utf8) }
                }
            }
            i = raw.index(after: i)
        }
        return nil
    }

    // MARK: - Labelled lines

    /// The commonest shape, and the one a chat tool exports: every question
    /// and answer on its own line with a marker. Markers are optional and can
    /// be numbered, because every tool styles them differently.
    /// Leading noise a chat tool may add: bullets, blockquotes, markdown,
    /// a number, then the word itself.
    private static let noise = "[ \\t>*#\\-–—•]*"
    /// The marker must be followed by a delimiter. Without that requirement,
    /// "Quite a lot of context here" begins with a Q and is read as a
    /// question — which silently truncates whatever answer preceded it.
    private static let delim = "[\\t :.)\\-–—]"
    private static let qMarker = "^\(noise)[Qq](uestion)?[ \\t]*[0-9]{0,3}[ \\t]*\(delim)[ \\t]*"
    private static let aMarker = "^\(noise)[Aa](nswer)?[ \\t]*[0-9]{0,3}[ \\t]*\(delim)[ \\t]*"

    private static func parseLabelled(_ text: String) -> [Pair] {
        var out: [Pair] = []
        var q: String?
        var a: String?

        func flush() {
            if let question = q, !question.isEmpty {
                let answer = (a ?? "").trimmingCharacters(
                    in: .whitespacesAndNewlines)
                // A question with no answer is not importable. Admitting it
                // puts a blank slot in the bank that the live matcher will
                // happily match and then display as nothing.
                guard answer.count > 8 else { return }
                out.append(Pair(question: question, answer: answer, topic: nil))
            }
            q = nil; a = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }   // blank lines separate, never end

            /// Checked before the answer branch and regardless of `q`: a new
            // question starts a new pair. Testing `q == nil` first meant a
            // "Q:" line after a completed answer was appended to that answer.
            if let m = line.leadingMatch(qMarker) {
                flush()
                q = line.strippingLeading(qMarker)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if q != nil, a == nil, let m = line.leadingMatch(aMarker) {
                a = line.strippingLeading(aMarker)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            // Continuation of whichever half we are in.
            if q != nil, a == nil { q! += " " + line }
            else if a != nil { a! += " " + line }
        }
        flush()
        return out
    }

    // MARK: - Markdown

    /// `## Question` followed by prose, or `- **Q:** …`. Headings are the
    /// reliable signal; bullets are not, so they are only used when no
    /// heading-based question was found.
    /// Every heading starts a question; the prose under it is the answer.
    ///
    /// Simpler than trying to recognise which headings are "questions": a
    /// heading with no prose under it produces nothing, so a document title
    /// drops out on its own without needing to be told apart from a question.
    private static func parseMarkdown(_ text: String) -> [Pair] {
        var out: [Pair] = []
        var current: String?
        var body: [String] = []

        func flush() {
            defer { current = nil; body = [] }
            guard let q = current, !q.isEmpty else { return }
            let answer = body.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A heading with nothing under it is a title, not a question.
            guard answer.count > 8 else { return }
            out.append(Pair(question: q, answer: answer, topic: nil))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let isHeading = line.hasPrefix("#") || line.hasPrefix("===")
                || (line.count > 3 && line.allSatisfy { $0 == "=" })

            if isHeading {
                flush()
                let cleaned = line.strippingLeading("^[#=\\s>\\-–—•*\\d.]+")
                if cleaned.count > 8 { current = cleaned }
                continue
            }
            if current != nil, !line.isEmpty { body.append(line) }
        }
        flush()
        return out
    }

    // MARK: - Transcript

    /// Last resort, and the one most likely to be what you actually have: a
    /// mock interview exported as prose. Question and answer alternate, so
    /// odd paragraphs are questions and even ones are answers. Used only when
    /// nothing better matched, because it is a guess.
    private static func parseTranscript(_ text: String) -> [Pair] {
        let blocks = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 12 }
        var out: [Pair] = []
        var i = 0
        while i + 1 < blocks.count {
            out.append(Pair(question: blocks[i],
                            answer: blocks[i + 1], topic: nil))
            i += 2
        }
        return out
    }
}

// MARK: - Small helpers

private extension String {
    /// Strips a leading match, leaving the line otherwise untouched. Used to
    /// remove list bullets and markdown noise before deciding what a line is.
    func strippingLeading(_ pattern: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return self }
        let ns = self as NSString
        guard let m = re.firstMatch(in: self, range: NSRange(location: 0,
                                                            length: ns.length)),
              m.range.location == 0
        else { return self }
        return ns.replacingCharacters(in: m.range, with: "")
    }

    /// The leading match of an anchored pattern, if there is one.
    func leadingMatch(_ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = self as NSString
        guard let m = re.firstMatch(in: self, range: NSRange(location: 0,
                                                            length: ns.length))
        else { return nil }
        return ns.substring(with: m.range)
    }
}
