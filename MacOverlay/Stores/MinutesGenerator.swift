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

    Output Markdown in this shape, and nothing else:

    First, 2–3 sentences with no heading: what the call was about and where \
    it landed.

    Then one "### " section per topic discussed, in the order it came up, \
    headed with a short name for that topic. Under each, bullet points of \
    what was said, agreed or raised; name the person only when the \
    transcript does. Nest a bullet for a supporting detail.

    ### Next steps
    One bullet per action, owner first: "(Name) task — due date". Write \
    "(Unassigned)" when the transcript does not say who owns it, and leave \
    the date out when none was stated. Write "None noted." if there were none.

    ### Decisions
    Bullet points. Write "None noted." if none were made.

    ### Open questions
    Only when something was raised and left unresolved; otherwise leave this \
    section out.

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

    /// An interview's end-of-session debrief, for the candidate — not
    /// meeting minutes: what was asked, how it went, and what to do next.
    static let interviewSystemPrompt = """
    You write a short debrief for a job candidate, from what was said in their \
    interview. You get the interviewer's questions in order and, when it was \
    recorded, what the candidate said. Never invent a question, a fact, an \
    answer or an outcome; leave a point out rather than guess.

    Output Markdown in this shape, and nothing else:

    One sentence with no heading: the main takeaway.

    ### Questions asked
    The interviewer's questions in order, cleaned up; nest a follow-up under \
    the question it followed.

    ### What they cared about
    Themes they kept coming back to, and anything they said about the team, \
    role, process or next steps.

    ### How you answered
    Only from the candidate's own recorded words: per question, what landed \
    and what was thin. If the candidate's words were not recorded, write \
    "Not captured — only the interviewer was recorded." and nothing else here.

    ### Strengths
    What went well, with the evidence. "None noted." if there is nothing to go on.

    ### Gaps
    Questions that went badly or were not answered, and topics that were not \
    shown. "None noted." if there are none.

    ### To research
    Topics, terms or technologies worth reading up on before the next round.

    ### Thank-you email
    A short draft (3–5 sentences) that mentions one specific thing discussed.

    Language: write in the language the interview was mainly conducted in, and \
    keep names, products and quoted phrases exactly as spoken.
    """

    /// The debrief's input: the interviewer's questions (the user turns —
    /// the copilot's suggestions are not something anyone said) and the
    /// candidate's own captured words, or a plain note that they weren't.
    static func debriefUserPrompt(turns: [ChatTurn], yourSpeech: [String], sessionTitle: String) -> String {
        let spoken = yourSpeech
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let you = spoken.isEmpty
            ? "(The candidate's words were not captured.)"
            : truncated(spoken.joined(separator: "\n\n"))
        return """
        Interview: \(sessionTitle)

        Interviewer's questions, in order:
        \(transcript(from: turns))

        What the candidate said:
        \(you)
        """
    }
}
