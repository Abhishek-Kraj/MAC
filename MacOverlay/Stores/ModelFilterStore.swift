import Foundation
import Observation

/// Filters shared by every screen that shows a model list — Settings → AI and
/// the overlay's model picker.
///
/// These were separate before, which is why the two screens disagreed: the
/// picker showed only whatever was un-hidden while Settings showed all 465
/// with search and tiers. One store means one answer to "which models am I
/// looking at", no matter where the question is asked.
@Observable
@MainActor
final class ModelFilterStore {
    static let shared = ModelFilterStore()

    var search = ""
    /// nil means no tier filter.
    var tier: ModelTier? = nil
    var imagesOnly = false

    /// Clears everything and shows the full catalogue again.
    func reset() {
        search = ""
        tier = nil
        imagesOnly = false
    }

    var isFiltering: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tier != nil || imagesOnly
    }

    func matches(_ m: OpenRouterModel) -> Bool {
        if let tier, m.tier != tier { return false }
        if imagesOnly && !m.supportsImages { return false }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return m.name.lowercased().contains(q)
            || m.id.lowercased().contains(q)
            || m.provider.lowizedContains(q)
    }

    /// Models passing the filter, grouped by provider in first-appearance
    /// order. One pass — re-filtering the catalogue per provider was
    /// 465 × ~60 comparisons per render.
    var groupedModels: [(provider: String, models: [OpenRouterModel])] {
        let filtered = OpenRouterCatalog.shared.allModels.filter { matches($0) }
        var order: [String] = []
        var map: [String: [OpenRouterModel]] = [:]
        for m in filtered {
            if map[m.provider] == nil { order.append(m.provider) }
            map[m.provider, default: []].append(m)
        }
        return order.map { (provider: $0, models: map[$0] ?? []) }
    }

    var matchingCount: Int {
        OpenRouterCatalog.shared.allModels.filter { matches($0) }.count
    }

    var matchingIDs: [String] {
        OpenRouterCatalog.shared.allModels.filter { matches($0) }.map(\.id)
    }
}

private extension String {
    /// `m.provider.lowizedContains(q)` — provider names are ASCII in practice
    /// but can carry accents from vendor names.
    func lowizedContains(_ other: String) -> Bool {
        range(of: other, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
