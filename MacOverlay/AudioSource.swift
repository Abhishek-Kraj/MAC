enum AudioSource: Int, CaseIterable {
    case microphone = 0
    case systemAudio = 1
    case both = 2

    var label: String {
        switch self {
        case .microphone:  return "Mic"
        case .systemAudio: return "System"
        case .both:        return "You + Them"
        }
    }

    /// Which feed owns the questions, and which one is just you.
    ///
    /// `.both` is the split: the call's audio is the other side of the
    /// conversation and owns the questions — nothing from the mic may
    /// trigger an answer — while the mic is transcribed separately so the
    /// transcript can label who said what. Single-source modes keep their
    /// old meaning: the chosen feed alone is the interview's ears.
    var capturePlan: (primary: AudioSource, secondary: AudioSource?) {
        switch self {
        case .microphone:  return (.microphone, nil)
        case .systemAudio: return (.systemAudio, nil)
        case .both:        return (.systemAudio, .microphone)
        }
    }
}
