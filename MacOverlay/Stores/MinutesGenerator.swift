import Foundation

/// Builds meeting minutes from a session transcript.
///
/// The transcript is what was heard: mic (you) and system audio (them) feed a
/// single recognizer, so nothing in it is labelled by speaker. The model is
/// told to infer speakers only from what the transcript itself states — a
/// name being addressed, a self-introduction — and to write "unassigned"
/// rather than invent an owner. Minutes that claim things the call did not
/// say are worse than minutes with a gap.
enum MinutesGenerator {
    /// Characters of transcript sent to the model. A long call overflows any
    /// useful input, and the end of a call is where the action items land, so
    /// the tail is kept — and the drop is stated in the text rather than
    /// silent, so nobody mistakes missing minutes for a quiet call.
    static let maxTranscriptChars = 60_000

    static let marker = "(Earlier part of the transcript omitted — the minutes cover the end of the call.)"

    static let systemPrompt = """
    You write meeting minutes from a raw transcript of a call. The speakers are \
    not labelled: the transcript mixes everything both sides said, without \
    speaker turns. Infer who said what only from what the transcript itself \
    states (people addressing each other by name, self-introductions). Never \
    invent a name.

    Output exactly this Markdown, with these headings and no others:

    ## Summary
    3–5 sentences: what the call was about and where it landed.

    ## Participants
    Names that actually appear in the transcript. If none do, write "Not identifiable from the transcript."

    ## Decisions
    Bullet points. Write "None noted." if none were made.

    ## Action items
    Bullet points in the form "task — owner — due date". When the transcript does not state who owns a task write "unassigned"; when it does not state a date write "no date". Never guess either.

    ## Open questions
    Anything raised and left unresolved. Write "None noted." if nothing was.

    Rules: use only what the transcript states. No pleasantries, no invented \
    owners, dates, or decisions.

    Language: write the minutes in the language the conversation was mainly \
    conducted in. If it was not English, do not translate it into English — a \
    Hindi call gets Hindi minutes. Use English only when the conversation was \
    itself in English. Keep proper nouns, product names and any quoted phrase \
    exactly as they were spoken, in their original script.
    """

    /// The session's user turns are the transcript. A call's assistant turns
    /// are the app's own suggested answers — not something anyone said — so
    /// they are excluded, or the minutes would attribute the copilot's advice
    /// to a participant.
    ///
    /// The user's own speech IS included: in a call they are half the
    /// conversation, and commitments they make ("I'll send it by Friday") are
    /// exactly the action items the summary exists to catch.
    static func transcript(from turns: [ChatTurn]) -> String {
        let lines = turns
            .filter { $0.role == .user }
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return truncated(lines.joined(separator: "\n\n"))
    }

    /// Keep the tail of an over-long transcript, with the omission stated in
    /// front of it. The end of a call holds the action items.
    static func truncated(_ text: String) -> String {
        guard text.count > maxTranscriptChars else { return text }
        let tail = String(text.suffix(maxTranscriptChars))
        return marker + "\n\n" + tail
    }

    static func userPrompt(turns: [ChatTurn], sessionTitle: String) -> String {
        """
        Session: \(sessionTitle)

        Transcript:
        \(transcript(from: turns))
        """
    }
}
