import Foundation
import Observation

/// The two ids the app reaches for when nothing better is chosen. They live
/// here rather than on `OverlayViewModel` so the guarantee "these are always
/// selectable" is testable without dragging in the AppKit-heavy view model.
enum OpenRouterDefaults {
    static let defaultModel = "openrouter/anthropic/claude-sonnet-5"
    /// Small fast model for background jobs (the response gate, session
    /// titles). Reached through OpenRouter like everything else.
    static let utilityModel = "openrouter/anthropic/claude-haiku-4.5"
}

/// One selectable model.
///
/// Ids keep the app's `openrouter/` prefix so `AIManager.isOpenRouterModel`
/// routes them to OpenRouter unchanged. The provider is only used to group
/// the pickers — routing is by prefix, never by this field.
struct OpenRouterModel: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let provider: String
    /// Accepts image input, so ⌘⇧⏎ (screenshot to the AI) works with it.
    let supportsImages: Bool
    /// OpenRouter's `:free` tier — no usage charge against the key.
    let isFree: Bool
    let contextLength: Int?

    /// `qwen/qwen3-235b` → `Qwen`.
    static func provider(fromSlug slug: String) -> String {
        let head = slug.split(separator: "/").first.map(String.init) ?? slug
        let names = [
            "anthropic": "Anthropic", "openai": "OpenAI", "google": "Google",
            "x-ai": "xAI", "meta-llama": "Meta", "meta": "Meta",
            "moonshotai": "Kimi", "mistralai": "Mistral", "deepseek": "DeepSeek",
            "qwen": "Qwen", "openbig": "OpenBig", "microsoft": "Microsoft",
            "nvidia": "NVIDIA", "cohere": "Cohere", "perplexity": "Perplexity",
            "amazon": "Amazon", "z-ai": "Z.ai", "minimax": "MiniMax",
            "nousresearch": "Nous", "gryphe": "Grype",
        ]
        if let known = names[head.lowercased()] { return known }
        return head.prefix(1).uppercased() + head.dropFirst()
    }

    /// Accepts either a bare OpenRouter slug (`qwen/qwen3-235b:free`) or one
    /// that already carries the app's `openrouter/` prefix.
    static func make(slug: String, name: String? = nil) -> OpenRouterModel {
        let bare = slug.hasPrefix("openrouter/")
            ? String(slug.dropFirst("openrouter/".count))
            : slug
        return OpenRouterModel(
            id: "openrouter/\(bare)",
            name: name ?? displayName(for: bare),
            provider: provider(fromSlug: bare),
            supportsImages: true,      // assumed; screenshots are opt-out per model below
            isFree: bare.hasSuffix(":free"),
            contextLength: nil
        )
    }

    /// `qwen/qwen3-235b:free` → `Qwen3 235B (free)`.
    static func displayName(for bare: String) -> String {
        var s = bare
        var free = false
        if s.hasSuffix(":free") { s = String(s.dropLast(5)); free = true }
        if let dash = s.lastIndex(of: "-"), s[s.index(after: dash)...].allSatisfy(\.isNumber) {
            s = String(s[..<dash])
        }
        let short = s.split(separator: "/").last.map(String.init) ?? s
        let title = short.split(separator: "-").map(displayToken).joined(separator: " ")
        return free ? "\(title) (free)" : title
    }

    /// Lowercase words that read as acronyms in a model name.
    private static let acronyms: Set<String> = [
        "gpt", "ai", "llm", "vl", "moe", "ocr", "tts", "stt", "it", "tpu", "gpu",
    ]

    /// Humanises one dash-separated slug token. The leading character is
    /// title-cased, and a trailing unit suffix is uppercased so `235b` reads
    /// as `235B`. Both rules apply together, since `qwen3` needs the first and
    /// `235b` needs the second.
    private static func displayToken(_ token: Substring) -> String {
        let t = String(token)
        if acronyms.contains(t.lowercased()) { return t.uppercased() }

        var chars = Array(t)
        if let first = chars.first, first.isLetter {
            chars[0] = Character(String(first).uppercased())
        }
        // Only treat a trailing letter run as a unit suffix when the token
        // actually carries a number, so `235b` becomes `235B` but `gemini`
        // stays `Gemini` rather than becoming `GEMINI`.
        if t.contains(where: \.isNumber) {
            var i = chars.count - 1
            while i >= 0, chars[i].isLetter { i -= 1 }
            if i < chars.count - 1 {
                for j in (i + 1)..<chars.count { chars[j] = Character(String(chars[j]).uppercased()) }
            }
        }
        return String(chars)
    }
}

/// The full OpenRouter catalogue, fetched once and cached, plus any models
/// the user typed in by hand.
///
/// The app used to ship a hardcoded list of eleven models, which meant the
/// only reachable models were the ones the developer happened to pick — the
/// `:free` tier was unreachable entirely. `AIManager` already routes any
/// `openrouter/`-prefixed id straight to OpenRouter, so the lock was purely
/// in the catalogue this type feeds.
///
/// Fetched models are registered as *hidden* in `ModelVisibility` on purpose:
/// the catalogue runs to several hundred entries, and the picker menu is only
/// usable when it stays short. Settings → AI is where you turn on what you
/// actually want.
@Observable
@MainActor
final class OpenRouterCatalog {
    static let shared = OpenRouterCatalog()

    private static let cacheKey = "openRouterCatalog.cached"
    private static let customKey = "openRouterCatalog.custom"
    private static let fetchedOnKey = "openRouterCatalog.fetchedAt"
    private static let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!

    /// Models downloaded from OpenRouter, newest catalogue first.
    private(set) var fetched: [OpenRouterModel] = []
    /// Models the user added by hand. Always visible; never hidden.
    private(set) var custom: [OpenRouterModel] = []
    private(set) var isFetching = false
    private(set) var lastError: String?
    private(set) var lastFetchedAt: Date?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let decoded = try? JSONDecoder().decode([OpenRouterModel].self, from: data) {
            fetched = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.customKey),
           let decoded = try? JSONDecoder().decode([OpenRouterModel].self, from: data) {
            custom = decoded
        }
        lastFetchedAt = UserDefaults.standard.object(forKey: Self.fetchedOnKey) as? Date
    }

    /// True when the app has a key to fetch the catalogue with.
    var hasKey: Bool {
        !(UserDefaults.standard.string(forKey: "openRouterAPIKey") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var freeCount: Int { fetched.filter(\.isFree).count }

    // MARK: - Built-in defaults

    /// The original hardcoded catalogue. Kept as an offline fallback so the
    /// picker is never empty before the first successful fetch, and so the app
    /// still works with no network.
    nonisolated static let builtins: [OpenRouterModel] = [
        ("anthropic/claude-sonnet-5",    "Claude Sonnet 5",       "Anthropic"),
        ("anthropic/claude-opus-5.5",    "Claude Opus 5.5",       "Anthropic"),
        ("anthropic/claude-fable-5.1",   "Claude Fable 5.1",      "Anthropic"),
        ("anthropic/claude-haiku-4.5",   "Claude Haiku 4.5",      "Anthropic"),
        ("openai/gpt-5.5",               "GPT-5.5",               "OpenAI"),
        ("openai/gpt-5.4-mini",          "GPT-5.4 mini",          "OpenAI"),
        ("google/gemini-3.8-flash",      "Gemini 3.8 Flash",      "Google"),
        ("google/gemini-3.5-flash-lite", "Gemini 3.5 Flash Lite", "Google"),
        ("x-ai/grok-4.7",                "Grok 4.7",              "xAI"),
        ("meta/muse-spark-1.3",          "Muse Spark 1.3",        "Meta"),
        ("moonshotai/kimi-k2.6",         "Kimi K2.6",             "Kimi"),
    ].map { OpenRouterModel.make(slug: $0.0, name: $0.1) }
        .map { m in
            OpenRouterModel(id: m.id, name: m.name, provider: m.provider,
                            supportsImages: true, isFree: m.isFree, contextLength: nil)
        }

    /// Everything selectable: custom first, then built-ins, then the fetched
    /// catalogue. De-duplicated by id, earliest definition winning.
    nonisolated static func merged(custom: [OpenRouterModel], fetched: [OpenRouterModel]) -> [OpenRouterModel] {
        var seen = Set<String>()
        return (custom + builtins + fetched).filter { seen.insert($0.id).inserted }
    }

    // MARK: - Fetching

    /// Downloads the catalogue. A key is not strictly required — OpenRouter
    /// serves the public list unauthenticated — but sending one means the list
    /// reflects what this account can actually reach.
    func fetchCatalogue() async {
        guard !isFetching else { return }
        isFetching = true
        lastError = nil
        defer { isFetching = false }

        var request = URLRequest(url: Self.modelsURL)
        request.timeoutInterval = 20
        if let key = UserDefaults.standard.string(forKey: "openRouterAPIKey"),
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                lastError = "OpenRouter returned HTTP \(http.statusCode)."
                return
            }
            let parsed = try Self.decode(data)
            fetched = parsed
            lastFetchedAt = Date()
            UserDefaults.standard.set(try? JSONEncoder().encode(parsed), forKey: Self.cacheKey)
            UserDefaults.standard.set(lastFetchedAt, forKey: Self.fetchedOnKey)
            hideNewlyFetched(parsed)
        } catch {
            lastError = error.localizedDescription
        }
    }

    nonisolated static func decode(_ data: Data) throws -> [OpenRouterModel] {
        struct Envelope: Decodable {
            struct Model: Decodable {
                struct Architecture: Decodable {
                    let inputModalities: [String]?
                    enum CodingKeys: String, CodingKey {
                        case inputModalities = "input_modalities"
                    }
                }
                let id: String
                let name: String
                let contextLength: Int?
                let architecture: Architecture?
                enum CodingKeys: String, CodingKey {
                    case id, name, architecture
                    case contextLength = "context_length"
                }
            }
            let data: [Model]
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return envelope.data.map { m in
            let modalities = m.architecture?.inputModalities ?? []
            return OpenRouterModel(
                id: "openrouter/\(m.id)",
                name: m.name,
                provider: OpenRouterModel.provider(fromSlug: m.id),
                supportsImages: modalities.contains("image"),
                isFree: m.id.hasSuffix(":free"),
                contextLength: m.contextLength
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Adds freshly fetched ids to `ModelVisibility`'s hidden set so the
    /// picker menu does not explode to several hundred rows. Built-ins and
    /// anything the user already chose stay visible.
    private func hideNewlyFetched(_ models: [OpenRouterModel]) {
        let visibility = ModelVisibility.shared
        let known = Set(Self.merged(custom: custom, fetched: models).map(\.id))
        let additions = Set(models.map(\.id)).subtracting(known)
        guard !additions.isEmpty else { return }
        for id in additions { visibility.hide(id) }
    }

    // MARK: - Custom models

    /// Adds a model the user typed in. Returns false if the id is empty or
    /// already present.
    @discardableResult
    func addCustom(slug: String) -> Bool {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let model = OpenRouterModel.make(slug: trimmed)
        guard !allModels.contains(where: { $0.id == model.id }) else { return false }
        custom.append(model)
        persistCustom()
        ModelVisibility.shared.show(model.id)
        return true
    }

    func removeCustom(_ model: OpenRouterModel) {
        custom.removeAll { $0.id == model.id }
        persistCustom()
    }

    private func persistCustom() {
        UserDefaults.standard.set(try? JSONEncoder().encode(custom), forKey: Self.customKey)
    }

    // MARK: - Lookup

    var allModels: [OpenRouterModel] {
        Self.merged(custom: custom, fetched: fetched)
    }

    func model(id: String) -> OpenRouterModel? {
        allModels.first { $0.id == id }
    }

    /// True when a screenshot can be sent to this model. Unknown ids are
    /// allowed — the user typed them in, so they know what they picked.
    func supportsImages(_ id: String) -> Bool {
        model(id: id)?.supportsImages ?? true
    }
}