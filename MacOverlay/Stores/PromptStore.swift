import Foundation
import Observation

@Observable
@MainActor
final class PromptStore {
    static let shared = PromptStore()
    private static let filename = "prompts.json"

    var presets: [PromptPreset] {
        didSet { persist() }
    }

    /// The conversation preset chosen for each session mode.
    ///
    /// Keyed by mode rather than held as one value. One shared "active" preset
    /// was how the Regular call tab came to display — and run — the Interview
    /// copilot prompt: the tab switched, the prompt did not.
    private(set) var activeConversationIDs: [String: UUID] = [:] {
        didSet { persistActiveConversationIDs() }
    }
    private static let activeConversationKey = "activeConversationPresetIDs"
    /// Currently-active resume generation preset (overrides the default gen prompt).
    var activeResumeGenerationID: UUID? {
        didSet {
            UserDefaults.standard.set(activeResumeGenerationID?.uuidString,
                                      forKey: "activeResumeGenerationPresetID")
        }
    }
    /// Currently-active resume scoring preset.
    var activeResumeScoringID: UUID? {
        didSet {
            UserDefaults.standard.set(activeResumeScoringID?.uuidString,
                                      forKey: "activeResumeScoringPresetID")
        }
    }

    private init() {
        var loaded = JSONStore.load([PromptPreset].self, from: Self.filename) ?? PromptStore.seeded()

        // One-time migration: if the user had a legacy single customSystemPrompt
        // before the library existed, import it as "Custom" so nothing is lost.
        let legacy = UserDefaults.standard.string(forKey: "customSystemPrompt") ?? ""
        let migrated = UserDefaults.standard.bool(forKey: "customSystemPromptMigrated")
        var restoredActive: UUID?
        if !legacy.isEmpty && !migrated {
            let imported = PromptPreset(name: "Custom", content: legacy)
            loaded.append(imported)
            UserDefaults.standard.set(true, forKey: "customSystemPromptMigrated")
            restoredActive = imported.id
        }

        self.presets = loaded

        // Which conversation preset each mode runs. The single value this
        // replaced is folded into the mode it belongs to — a preset linked to
        // Interview becomes the interview's, rather than one every tab shares.
        // An unlinked preset was the user's "use this everywhere" pick, so it
        // is kept for every mode.
        let storedActive = UserDefaults.standard.dictionary(forKey: Self.activeConversationKey) ?? [:]
        if storedActive.isEmpty {
            let legacyID = restoredActive
                ?? UserDefaults.standard.string(forKey: "activePromptPresetID")
                    .flatMap(UUID.init(uuidString:))
            if let legacyID,
               let preset = loaded.first(where: { $0.id == legacyID && $0.kind == .conversation }) {
                if let mode = preset.linkedMode {
                    self.activeConversationIDs = [mode.rawValue: legacyID]
                } else {
                    self.activeConversationIDs = Dictionary(
                        uniqueKeysWithValues: SessionMode.allCases.map { ($0.rawValue, legacyID) })
                }
            }
        } else {
            self.activeConversationIDs = storedActive.compactMapValues { value in
                (value as? String).flatMap(UUID.init(uuidString:))
            }
        }

        if let raw = UserDefaults.standard.string(forKey: "activeResumeGenerationPresetID"),
           let uuid = UUID(uuidString: raw),
           loaded.contains(where: { $0.id == uuid && $0.kind == .resumeGeneration }) {
            self.activeResumeGenerationID = uuid
        } else {
            self.activeResumeGenerationID = nil
        }

        if let raw = UserDefaults.standard.string(forKey: "activeResumeScoringPresetID"),
           let uuid = UUID(uuidString: raw),
           loaded.contains(where: { $0.id == uuid && $0.kind == .resumeScoring }) {
            self.activeResumeScoringID = uuid
        } else {
            self.activeResumeScoringID = nil
        }

        // Write the per-mode choices back now, so the migration above happens
        // once rather than on every launch.
        persistActiveConversationIDs()
    }

    // MARK: - Filtered views

    var conversationPresets: [PromptPreset] {
        presets.filter { $0.kind == .conversation }
    }
    var resumeGenerationPresets: [PromptPreset] {
        presets.filter { $0.kind == .resumeGeneration }
    }
    var resumeScoringPresets: [PromptPreset] {
        presets.filter { $0.kind == .resumeScoring }
    }

    // MARK: - CRUD

    @discardableResult
    func add(name: String,
             content: String,
             kind: PromptPreset.Kind = .conversation,
             icon: String = "text.bubble.fill",
             colorHex: String? = nil,
             linkedMode: SessionMode? = nil) -> PromptPreset {
        let preset = PromptPreset(
            name: name, content: content, kind: kind,
            icon: icon, colorHex: colorHex, linkedMode: linkedMode
        )
        presets.append(preset)
        return preset
    }

    func update(_ preset: PromptPreset) {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        var updated = preset
        updated.updatedAt = Date()
        presets[idx] = updated
    }

    func delete(id: UUID) {
        presets.removeAll { $0.id == id }
        activeConversationIDs = activeConversationIDs.filter { $0.value != id }
        if activeResumeGenerationID == id { activeResumeGenerationID = nil }
        if activeResumeScoringID == id    { activeResumeScoringID = nil }
    }

    // MARK: - Active-preset accessors

    /// The preset a session running `mode` will use.
    ///
    /// The choice made for that mode wins — scoped per mode, so a pick always
    /// takes effect and never leaks to another tab. Otherwise the preset the
    /// library links to the mode, which until now the editor wrote and nothing
    /// read. Nil means the built-in `SessionMode.systemPrompt` runs.
    func activePreset(for mode: SessionMode) -> PromptPreset? {
        activeConversationIDs[mode.rawValue].flatMap(conversationPreset)
            ?? linkedPreset(for: mode)
    }

    /// What `mode` will actually run, as an id — so a picker can tick the entry
    /// in force rather than the one last stored.
    func activePresetID(for mode: SessionMode) -> UUID? {
        activePreset(for: mode)?.id
    }

    /// Choose a preset for one mode. `nil` clears the choice, leaving the mode
    /// on its linked preset or the built-in prompt.
    func setActivePresetID(_ id: UUID?, for mode: SessionMode) {
        if let id {
            activeConversationIDs[mode.rawValue] = id
        } else {
            activeConversationIDs.removeValue(forKey: mode.rawValue)
        }
    }

    private func conversationPreset(_ id: UUID) -> PromptPreset? {
        presets.first { $0.id == id && $0.kind == .conversation }
    }

    var activeResumeGenerationPreset: PromptPreset? {
        guard let id = activeResumeGenerationID else { return nil }
        return presets.first { $0.id == id && $0.kind == .resumeGeneration }
    }
    var activeResumeScoringPreset: PromptPreset? {
        guard let id = activeResumeScoringID else { return nil }
        return presets.first { $0.id == id && $0.kind == .resumeScoring }
    }

    /// The preset the library links to `mode` — the seeded default for that
    /// mode, editable like any other preset. `activePreset(for:)` falls back to
    /// it when no preset was chosen for the mode.
    func linkedPreset(for mode: SessionMode) -> PromptPreset? {
        presets.first { $0.linkedMode == mode && $0.kind == .conversation }
    }

    // MARK: - Persistence

    private func persistActiveConversationIDs() {
        UserDefaults.standard.set(activeConversationIDs.mapValues { $0.uuidString },
                                  forKey: Self.activeConversationKey)
    }

    private func persist() {
        JSONStore.save(presets, to: Self.filename)
    }

    // MARK: - Seed

    private static func seeded() -> [PromptPreset] {
        // Ship a conversation preset per built-in mode so the library isn't empty.
        SessionMode.allCases.map { mode in
            PromptPreset(
                name: mode.displayName,
                content: mode.systemPrompt,
                kind: .conversation,
                icon: mode.icon,
                linkedMode: mode
            )
        }
    }
}
