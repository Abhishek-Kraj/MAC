import Foundation

/// Local backups of the prepared-question bank.
///
/// The bank is something you build in the half hour before an interview, and
/// it is the one piece of preparation that cannot be regenerated at the drop
/// of a hat when there is no signal — the research pass needs the network and
/// the embedding pass needs an OpenRouter key. So it gets backed up locally
/// automatically, and can also be exported next to the interview notes.
///
/// Snapshots are kept in the channel's own data directory, so Dev, Beta and
/// Production never read each other's backups.
@MainActor
enum PrepBankBackup {

    /// One encoder/decoder pair, used by every read and write here.
    ///
    /// The first version wrote with `.iso8601` and read with a bare decoder,
    /// so restoring a snapshot threw a type mismatch on `createdAt` and every
    /// snapshot silently reported zero questions. Sharing the pair makes that
    /// class of drift impossible.
    static func makeEncoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        if pretty { e.outputFormatting = [.prettyPrinted, .sortedKeys] }
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// How many automatic snapshots to keep. Enough to walk back through a
    /// few sessions of editing without filling the disk.
    static let keep = 12

    static var directory: URL {
        let dir = JSONStore.appDirectory.appendingPathComponent("prepBackups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A single point-in-time copy, on disk.
    struct Snapshot: Identifiable {
        let url: URL
        let createdAt: Date
        let questionCount: Int
        var id: URL { url }
        var name: String {
            let f = DateFormatter()
            f.dateFormat = "d MMM HH:mm:ss"
            return "\(questionCount) questions · \(f.string(from: createdAt))"
        }
    }

    /// Snapshots, newest first.
    static func snapshots() -> [Snapshot] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let urls = names
            .filter { $0.hasSuffix(".json") }
            .map { directory.appendingPathComponent($0) }
        return urls.compactMap { url in
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let created = attrs[.creationDate] as? Date else { return nil }
            let count = (try? makeDecoder().decode([PrepQuestion].self,
                                                   from: Data(contentsOf: url)))?.count ?? 0
            return Snapshot(url: url, createdAt: created, questionCount: count)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// Writes a snapshot and prunes the oldest beyond `keep`.
    ///
    /// Called on changes that matter — a research run finishing, the user
    /// editing or accepting captured questions — not on every keystroke.
    @discardableResult
    static func snapshot() -> Snapshot? {
        let questions = PrepBank.shared.questions
        guard !questions.isEmpty else { return nil }

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = directory.appendingPathComponent("prep-\(f.string(from: Date())).json")

        guard let data = try? makeEncoder().encode(questions) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }

        let all = snapshots()
        for old in all.dropFirst(keep) {
            try? FileManager.default.removeItem(at: old.url)
        }
        return snapshots().first
    }

    /// Replaces the live bank with a snapshot's contents.
    /// Returns the number of questions restored.
    @discardableResult
    static func restore(from url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let questions = try makeDecoder().decode([PrepQuestion].self, from: data)
        guard !questions.isEmpty else { return 0 }

        // Snapshot first: a restore is itself a destructive change.
        snapshot()
        PrepBank.shared.replaceAll(with: questions)
        return questions.count
    }

    /// Writes a copy to a user-chosen location, for keeping alongside interview
    /// notes or moving to another Mac.
    @discardableResult
    static func export(to url: URL) -> Bool {
        let questions = PrepBank.shared.questions
        guard !questions.isEmpty else { return false }
        // Pretty-printed: this file is meant to be readable and hand-editable,
        // unlike the working copy.
        guard let data = try? makeEncoder(pretty: true).encode(questions) else { return false }
        do { try data.write(to: url, options: .atomic) } catch { return false }
        return true
    }

    /// Reads a bank from an exported or snapshotted file.
    static func load(from url: URL) throws -> [PrepQuestion] {
        let data = try Data(contentsOf: url)
        return try makeDecoder().decode([PrepQuestion].self, from: data)
    }

    /// Total bytes the snapshots occupy, for display in Settings.
    static func totalSize() -> Int {
        snapshots().reduce(0) { total, snap in
            let size = (try? FileManager.default.attributesOfItem(atPath: snap.url.path)[.size] as? Int) ?? 0
            return total + (size ?? 0)
        }
    }
}