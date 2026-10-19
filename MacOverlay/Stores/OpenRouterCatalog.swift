import Foundation
import Observation

/// OpenRouter quotes prices as USD per token, as strings.
struct Pricing: Decodable {
    let prompt: String?
    let completion: String?
}

/// How heavy a model is, used to narrow a 465-entry catalogue down to
/// something you can pick from mid-interview.
///
/// Tiered on OpenRouter's own `pricing` rather than on the model name, which
/// is the only signal that is both authoritative and current. Price tracks
/// capability closely enough to be a good lightness proxy, and it avoids
/// hardcoding "7b is light, 70b is heavy" — a guess that breaks whenever the
/// vendor ships something new.
///
/// Measured distribution across the live catalogue (USD per 1M blended
/// tokens, 450 paid models): p10 $0.27, p25 $0.70, p50 $2.40, p75 $8.23.
/// The thresholds below sit near those quartiles.
enum ModelTier: String, CaseIterable, Identifiable {
    /// `:free`, or priced at zero.
    case free
    /// Small and quick. The ones you want for a fast first answer.
    case light
    /// The middle of the range.
    case moderate
    /// Frontier models: the slowest and most expensive.
    case frontier
    /// No usable price. OpenRouter's own routers (`openrouter/auto`) report a
    /// large negative figure that is an internal accounting artefact, not a
    /// price, so they are kept out of the tiers rather than guessed at.
    case unpriced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free:      return "Free"
        case .light:     return "Light"
        case .moderate:  return "Moderate"
        case .frontier:  return "Frontier"
        case .unpriced:  return "Router / unpriced"
        }
    }

    var help: String {
        switch self {
        case .free:     return "No charge against your key"
        case .light:    return "Cheapest and quickest tier"
        case .moderate: return "Balanced cost and speed"
        case .frontier: return "Most capable, slowest and dearest"
        case .unpriced: return "Auto-routers with no listed price"
        }
    }

    /// `blended` is USD per 1M prompt+completion tokens.
    static func tier(isFree: Bool, blended: Double?) -> ModelTier {
        if isFree { return .free }
        guard let blended, blended.isFinite, blended >= 0 else { return .unpriced }
        if blended == 0 { return .free }
        if blended <= 0.75 { return .light }
        if blended <= 5.0  { return .moderate }
        return .frontier
    }
}

/// The two ids the app reaches for when nothing better is chosen. They live
/// here rather than on `OverlayViewModel` so the guarantee "these are always
/// selectable" is testable without dragging in the AppKit-heavy view model.
///
/// Both are deliberately flash-class: the default answer model runs on
/// every question of an interview, and the utility model runs the response
/// gate on the critical path before an answer starts. A frontier model as
/// the fallback default meant a fresh install quietly burned frontier
/// prices per question — these are cents-per-thousand-questions instead.
/// Both ids are also in `OpenRouterCatalog.builtins`, so they stay
/// selectable before the first catalogue fetch and pass
/// `testOpenRouterBuiltinsCoverDefaults`.
enum OpenRouterDefaults {
    static let defaultModel = "openrouter/google/gemini-3.8-flash"
    /// Cheapest fast model for background jobs (the response gate, session
    /// titles). Reached through OpenRouter like everything else.
    static let utilityModel = "openrouter/google/gemini-3.5-flash-lite"
}

extension OpenRouterModel {
    /// Which tier this model falls into. See `ModelTier` for the thresholds
    /// and why price is used rather than a guess at parameter count.
    var tier: ModelTier {
        ModelTier.tier(isFree: isFree, blended: blendedPrice)
    }
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
    /// What OpenRouter says this model accepts. Optional because the cached
    /// catalogue predates this field and `decodeIfPresent` keeps old caches
    /// readable without a migration.
    let supportedParameters: [String]?
    /// USD per 1M prompt+completion tokens, summed. nil when OpenRouter did
    /// not quote a usable price. See `ModelTier`.
    let blendedPrice: Double?

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
            supportsImages: true,
            isFree: bare.hasSuffix(":free"),
            contextLength: nil,
            supportedParameters: nil,   // unknown until fetched
            blendedPrice: nil
        )
    }

    /// An OpenCode Console entry.
    ///
    /// Unlike OpenRouter's, the id is the app's own `opencode/<slug>` — the
    /// gateway itself takes the bare slug — and the provider is a fixed group
    /// rather than one derived from a `vendor/` head.
    ///
    /// `supportsImages` is false across the board on purpose. A wrong "yes"
    /// offers ⌘⇧⏎ (screenshot to the AI) to a model that cannot read it, and the
    /// request fails mid-interview; a wrong "no" only hides a shortcut.
    /// `blended` is nil wherever OpenCode does not publish a machine-readable
    /// price, which is everywhere: `GET /inference/v1/models` returns bare
    /// ids and nothing else. A nil price shows as *unpriced* rather than as a
    /// fabricated number — a wrong "cheap" badge is worse than no badge.
    static func openCode(_ slug: String, _ name: String,
                         free: Bool = false, blended: Double? = nil) -> OpenRouterModel {
        OpenRouterModel(
            id: "opencode/\(slug)",
            name: name,
            provider: "OpenCode",
            supportsImages: false,
            isFree: free,
            contextLength: nil,
            supportedParameters: nil,
            blendedPrice: blended
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
    private static let schemaKey = "openRouterCatalog.schemaVersion"

    /// Bump whenever the cached shape changes. A cache written by an older
    /// build is missing fields the current code reads (per-model pricing,
    /// supported_parameters), so it must be refetched even when it is only
    /// hours old — age alone would let a stale schema masquerade as fresh.
    /// v2: added supportedParameters + blendedPrice.
    private static let schemaVersion = 2
    private static let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!

    /// Ids OpenRouter advertises as honouring `reasoning_effort`, as a
    /// nonisolated mirror of the cached catalogue. `AIManager.reasoning(for:)`
    /// is consulted on the request path, which is not main-actor isolated, so
    /// it reads this rather than hopping actors for every request.
    nonisolated(unsafe) static var reasoningEffortIDs: Set<String> = []
    /// Models downloaded from OpenRouter, newest catalogue first.
    private(set) var fetched: [OpenRouterModel] = []
    /// How old the cache may get before the app refreshes it on its own.
    /// OpenRouter's free tier turns over constantly — models are added and
    /// retired — so a week-old snapshot lists models that no longer exist.
    nonisolated private static let staleAfter: TimeInterval = 24 * 60 * 60

    /// True when the catalogue is old enough to be worth refetching, or has
    /// never been fetched at all.
    var isStale: Bool {
        Self.isStale(fetchedAt: lastFetchedAt,
                     schema: UserDefaults.standard.integer(forKey: Self.schemaKey))
    }

    /// Pure so the staleness rule can be tested directly. A cache is stale if
    /// it was never fetched, was written by an older build, or has aged past
    /// `staleAfter`.
    static func isStale(fetchedAt: Date?, schema: Int,
                        now: Date = Date(),
                        staleAfter: TimeInterval = staleAfter) -> Bool {
        guard let fetchedAt else { return true }
        guard schema == schemaVersion else { return true }
        return now.timeIntervalSince(fetchedAt) > staleAfter
    }

    /// Short human age, e.g. "just now", "6h ago", "3d ago".
    var ageDescription: String {
        Self.ageDescription(since: lastFetchedAt)
    }

    /// Pure so the wording can be tested without waiting a day for a fetch.
    static func ageDescription(since date: Date?) -> String {
        guard let date else { return "never fetched" }
        let seconds = Date().timeIntervalSince(date)
        switch seconds {
        case ..<60:      return "just now"
        case ..<3600:    return "\(Int(seconds / 60)) min ago"
        case ..<86_400:  return "\(Int(seconds / 3600))h ago"
        case ..<604_800: return "\(Int(seconds / 86_400))d ago"
        default:         return "over a week ago"
        }
    }

    /// Refetches only if the cache has gone stale. Safe to call on every
    /// launch: it is a no-op while the data is fresh, and it never blocks.
    func refreshIfStale() async {
        guard isStale, !isFetching else { return }
        await fetchCatalogue()
    }

    /// Models the user added by hand. Always visible; never hidden.
    private(set) var custom: [OpenRouterModel] = []
    private(set) var isFetching = false
    private(set) var lastError: String?
    private(set) var lastFetchedAt: Date?
    /// Ids that were in the previous catalogue but are gone from the new one.
    /// Only set when the fetch actually succeeded, so a failed request never
    /// makes it look like the vendor deleted everything.
    private(set) var retired: Set<String> = []

    /// Lets a caller acknowledge a retired id so it is not reported twice.
    func acknowledgeRetired(_ id: String) { retired.remove(id) }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let decoded = try? JSONDecoder().decode([OpenRouterModel].self, from: data) {
            fetched = decoded
            rebuildReasoningIndex()
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

    /// OpenCode Console's curated set.
    ///
    /// Every entry here speaks OpenCode's OpenAI-compatible endpoint
    /// (`/inference/openai/v1/chat/completions`) and was probed live against it
    /// on 2026-10-18 with a real key. Three whole families are deliberately
    /// absent, each for a reason that would otherwise surface as a failure in
    /// the middle of an interview:
    ///
    ///  · **The free tier.** `deepseek-v4.1-flash-free`, `glm-5.3-flash-free`,
    ///    `big-pickle`, the Nemotron / MiMo / LongCat / Space Bunny / Beam
    ///    entries — every one answers `HTTP 403 FreeTierError`, "OpenCode's
    ///    free tier can only be used from within OpenCode". Spoofing a client
    ///    User-Agent does not change it. Free models therefore come from
    ///    OpenRouter's own `:free` tier, which *does* work from this app.
    ///  · **The other protocols.** `claude-*` speak Anthropic's messages API,
    ///    `gpt-5.4-nano` and friends speak the OpenAI *responses* API, and
    ///    `gemini-3.5-flash-lite` speaks Google's — all answer `HTTP 400
    ///    ModelProtocolUnsupported` on chat/completions. Reaching them would
    ///    mean three more request builders, which is not worth it while
    ///    OpenRouter already carries the same models.
    ///  · **Advertised but broken.** `kimi-k2.6`, `kimi-k2.7-code` and
    ///    `minimax-m2.7` are listed by `/models` yet answered 403/410
    ///    `server_error` on every probe.
    ///
    /// Prices are only given where the provider publishes one at all; the
    /// rest show as unpriced rather than as a number this app made up.
    nonisolated static let openCodeBuiltins: [OpenRouterModel] = [
        // Cheap and fast — the ones worth reaching for during a live interview.
        .openCode("qwen3.8-flash",       "Qwen3.8 Flash",       blended: 0.62),
        .openCode("glm-5.3-flash",       "GLM 5.3 Flash",       blended: 0.65),
        .openCode("deepseek-v4.1-flash", "DeepSeek V4.1 Flash", blended: 1.50),
        // Stronger, and priced by request rather than published per token.
        .openCode("glm-5.3",             "GLM 5.3"),
        .openCode("deepseek-v4-pro",     "DeepSeek V4 Pro"),
        .openCode("minimax-m3",          "MiniMax M3"),
        .openCode("kimi-k3",             "Kimi K3"),
        .openCode("mistral-large-4",     "Mistral Large 4"),
        .openCode("qwen3.8-max",         "Qwen3.8 Max"),
    ]

    /// OpenCode models that accept `reasoning_effort` AND measurably shorten
    /// their thinking when given it, probed 2026-10-18. GLM 5.3 Flash went
    /// from 456 characters of `reasoning_content` to 33. Most OpenCode models
    /// answer `HTTP 400 invalid_request_error` when the field is sent at all,
    /// so this is an allowlist — see `AIManager.openCodeReasoningEffort(for:)`.
    nonisolated static let openCodeReasoningEffortIDs: Set<String> = [
        "glm-5.3-flash", "glm-5.3", "qwen3.8-flash",
    ]

    /// Everything selectable: custom first, then built-ins, then the fetched
    /// catalogue. De-duplicated by id, earliest definition winning.
    nonisolated static func merged(custom: [OpenRouterModel], fetched: [OpenRouterModel]) -> [OpenRouterModel] {
        var seen = Set<String>()
        return (custom + builtins + openCodeBuiltins + fetched).filter { seen.insert($0.id).inserted }
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
            let previous = Set(fetched.map(\.id))
            retired = previous.subtracting(Set(parsed.map(\.id)))
            fetched = parsed
            rebuildReasoningIndex()
            lastFetchedAt = Date()
            UserDefaults.standard.set(try? JSONEncoder().encode(parsed), forKey: Self.cacheKey)
            UserDefaults.standard.set(lastFetchedAt, forKey: Self.fetchedOnKey)
            UserDefaults.standard.set(Self.schemaVersion, forKey: Self.schemaKey)
            hideNewlyFetched(parsed)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Rebuilds the nonisolated reasoning index from the cached catalogue.
    private func rebuildReasoningIndex() {
        Self.reasoningEffortIDs = Set(
            fetched
                .filter { $0.supportedParameters?.contains("reasoning_effort") == true }
                .map(\.id)
        )
    }

    /// Sums OpenRouter's per-token prices into USD per 1M blended tokens.
    /// Returns nil when either half is missing or unparseable, so a partial
    /// price never becomes a bogus tier.
    nonisolated static func blended(from pricing: Pricing?) -> Double? {
        guard let pricing,
              let p = Double(pricing.prompt ?? ""),
              let c = Double(pricing.completion ?? ""),
              p.isFinite, c.isFinite
        else { return nil }
        return (p + c) * 1_000_000
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
                let supportedParameters: [String]?
                let pricing: Pricing?
                enum CodingKeys: String, CodingKey {
                    case id, name, architecture, pricing
                    case contextLength = "context_length"
                    case supportedParameters = "supported_parameters"
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
                contextLength: m.contextLength,
                supportedParameters: m.supportedParameters,
                blendedPrice: blended(from: m.pricing)
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Adds freshly fetched ids to `ModelVisibility`'s hidden set so the
    /// picker menu does not explode to several hundred rows. Built-ins and
    /// anything the user already chose stay visible.
    /// Test seam for `hideNewlyFetched`.
    func hideForTesting(_ models: [OpenRouterModel]) { hideNewlyFetched(models) }

    func hideNewlyFetched(_ models: [OpenRouterModel]) {
        let visibility = ModelVisibility.shared
        // Keep hand-added models, the built-in defaults, and whatever the
        // user has currently selected — hiding that one would leave them
        // pointed at a model the picker no longer offers.
        //
        // Note the previous version derived `known` from
        // `merged(custom:fetched:)`, which already contained every fetched id,
        // so the difference was always empty and nothing was ever hidden.
        var keep = Set(custom.map(\.id))
        keep.formUnion(Self.builtins.map(\.id))
        keep.formUnion(Self.openCodeBuiltins.map(\.id))
        if let selected = UserDefaults.standard.string(forKey: "selectedModel") {
            keep.insert(selected)
        }
        for id in models.map(\.id) where !keep.contains(id) { visibility.hide(id) }
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
    /// True when OpenRouter advertises that this model honours a reasoning
    /// effort level, which is the only safe signal that turning thinking down
    /// will actually take effect. Models that advertise `reasoning` without
    /// `reasoning_effort` (deepseek-r1 and friends) still *compute* their
    /// reasoning when `exclude` is set — measured at 197 s to first token —
    /// so they are deliberately left alone.
    func supportsReasoningEffort(_ id: String) -> Bool {
        Self.reasoningEffortIDs.contains(OpenRouterModel.make(slug: id).id)
    }

    func supportsImages(_ id: String) -> Bool {
        model(id: id)?.supportsImages ?? true
    }
}