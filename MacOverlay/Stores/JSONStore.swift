import Foundation

/// Thin JSON-on-disk persistence. Stores live in
/// ~/Library/Application Support/MacOverlay/ (with a " Dev" or " Beta"
/// suffix for those builds, so they never touch production data). Writes
/// are atomic.
enum JSONStore {
    /// Redirects every store to a scratch directory.
    ///
    /// The test binary carries no `TCChannel` in its Info.plist, so
    /// `AppChannel.current` resolves to Production and the suite would read
    /// and write the real `~/Library/Application Support/MacOverlay` folder —
    /// clobbering real app data. Tests set this before touching any store.
    private static var directoryOverride: URL?

    static func setDirectoryOverride(_ url: URL?) { directoryOverride = url }

    static var appDirectory: URL = {
        if let directoryOverride { return directoryOverride }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent(AppChannel.current.dataDirectoryName, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Serial queue for all disk writes — encoding + atomic write happen off
    /// the main thread so streaming-driven persists don't stall the UI.
    private static let writeQueue = DispatchQueue(label: "JSONStore.write", qos: .utility)

    static func url(for filename: String) -> URL {
        appDirectory.appendingPathComponent(filename)
    }

    static func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        let url = url(for: filename)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    /// Asynchronous save: encoding and atomic write happen on a background
    /// queue. Pretty-printing is dropped (it doubled file size and slowed
    /// encoding for no end-user benefit — the file is read by code, not humans).
    static func save<T: Encodable>(_ value: T, to filename: String) {
        let url = url(for: filename)
        writeQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Block until every queued write has hit the disk. Call on app
    /// terminate (and in tests) — `save` is asynchronous, so without a
    /// flush the process can exit with the last write still in flight.
    static func flush() {
        writeQueue.sync {}
    }
}
