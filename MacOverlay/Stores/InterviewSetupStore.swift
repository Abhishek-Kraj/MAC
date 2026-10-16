import Foundation

/// Persistence for the interview setup form.
///
/// Split out of `OverlayViewModel` for one reason: the form is filled in by
/// hand — a posting pasted in, a résumé attached, which can take ten minutes —
/// and none of it survived the process. A rebuild, a crash or a plain quit
/// returned you to a blank form that looked as though you had never done the
/// work. Keeping it in a small standalone type also keeps it testable, which
/// the view model is not (it drags in the whole AppKit surface).
enum InterviewSetupStore {

    private enum Key {
        static let resumePath   = "interviewResumeFilePath"
        static let context     = "interviewContext"
        static let autoGen     = "interviewAutoGenerate"
        static let focusMode   = "interviewFocusMode"
    }

    private static var defaults: UserDefaults { .standard }

    // MARK: - Writing

    static func setResumeURL(_ url: URL?) {
        defaults.set(url?.path, forKey: Key.resumePath)
    }

    static func setContext(_ text: String) {
        defaults.set(text, forKey: Key.context)
    }

    static func setAutoGenerate(_ on: Bool) {
        defaults.set(on, forKey: Key.autoGen)
    }

    static func setFocusMode(_ on: Bool) {
        defaults.set(on, forKey: Key.focusMode)
    }

    // MARK: - Reading

    /// The stored posting, or `""`.
    static var context: String {
        defaults.string(forKey: Key.context) ?? ""
    }

    /// Defaults to on. Absent is treated as "never set", not as off, so an
    /// existing user does not silently lose auto-generate.
    static var autoGenerate: Bool {
        defaults.object(forKey: Key.autoGen) as? Bool ?? true
    }

    static var focusMode: Bool {
        defaults.object(forKey: Key.focusMode) as? Bool ?? true
    }

    /// The stored résumé, but only if the file is still there.
    ///
    /// Best-effort by design: a path pointing at a file that has since been
    /// moved, renamed or emptied out of Trash is dropped, because a chip
    /// showing a filename that cannot be opened is worse than no chip at all.
    /// The stale key is cleared so it cannot fail again on the next launch.
    static var resumeURLIfPresent: URL? {
        guard let path = defaults.string(forKey: Key.resumePath), !path.isEmpty else {
            return nil
        }
        guard fileExists(path) else {
            defaults.removeObject(forKey: Key.resumePath)
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// Distinguishes "a regular file that exists" from a directory and from
    /// nothing at all — `-e` would accept a directory as a résumé.
    private static func fileExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        else { return false }
        return !isDirectory.boolValue
    }

    /// Everything restored in one go, for launch.
    struct Restored {
        var context: String = ""
        var resumeURL: URL?
        var autoGenerate: Bool = true
        var focusMode: Bool = true
    }

    static func restore() -> Restored {
        Restored(context: context,
                 resumeURL: resumeURLIfPresent,
                 autoGenerate: autoGenerate,
                 focusMode: focusMode)
    }

    /// Test and "clear this app's state" support.
    static func reset() {
        for k in [Key.resumePath, Key.context, Key.autoGen, Key.focusMode] {
            defaults.removeObject(forKey: k)
        }
    }
}