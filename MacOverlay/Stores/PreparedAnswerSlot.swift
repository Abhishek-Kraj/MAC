import Foundation

/// Decides what answer is on screen when a prepared one and the model's are
/// both in play.
///
/// Extracted from `OverlayViewModel` so it can be tested. The rule it
/// encodes is the whole point of preparing: a matched answer appears the
/// instant the question is recognised, because mid-interview the cost of
/// waiting several seconds for generation is exactly what preparation exists
/// to remove. The model's answer is not discarded — it is captured and can be
/// swapped in, so a match can be checked instead of trusted.
///
/// The subtlety is the first write. `setStreamed` is called by the streaming
/// path many times per second, and the stream's very first act is to clear
/// the response. Without capturing only the first *non-empty* write, that
/// clear would become the "generated alternative" and the toggle would offer
/// an empty answer.
@Observable
final class PreparedAnswerSlot {

    /// The matched answer from the bank.
    private(set) var prepared: String = ""
    /// The bank question it matched, so the answer can be attributed.
    private(set) var source: String = ""
    /// The model's answer to the same question, once it has produced one.
    private(set) var generated: String = ""
    /// Whether the user has switched to the generated answer.
    private(set) var usingGenerated = false
    /// The model's answer when nothing was matched — the ordinary path.
    private(set) var streamed: String = ""

    var hasPrepared: Bool { !prepared.isEmpty }

    /// Whether switching would do anything yet. Until the model has produced
    /// something, there is nothing to switch to and offering the control
    /// would be a dead button.
    var canShowGenerated: Bool { !generated.isEmpty }

    var isShowingPrepared: Bool { hasPrepared && !usingGenerated }

    /// What belongs on screen right now.
    var displayed: String {
        guard hasPrepared else { return streamed }
        return (usingGenerated && !generated.isEmpty) ? generated : prepared
    }

    func showPrepared(_ answer: String, source matchedQuestion: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        prepared = trimmed
        source = matchedQuestion
        generated = ""
        usingGenerated = false
    }

    /// Per-send reset. Must run before a stream starts, or the stream's own
    /// opening clear is captured as the generated alternative.
    func clear() {
        prepared = ""
        source = ""
        generated = ""
        usingGenerated = false
        streamed = ""
    }

    func toggle() {
        guard !generated.isEmpty else { return }
        usingGenerated.toggle()
    }

    /// Every write the streaming path makes. With a prepared answer up, the
    /// first non-empty write is the generated answer and later ones grow it;
    /// with none, it is simply the response.
    func setStreamed(_ text: String) {
        if hasPrepared {
            if generated.isEmpty, !text.isEmpty { generated = text }
            return
        }
        streamed = text
    }
}