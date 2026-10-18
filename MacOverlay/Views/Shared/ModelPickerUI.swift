import SwiftUI

/// One row in a model list. Shared so the picker and Settings cannot drift
/// apart in how a model is labelled.
struct ModelRow: View {
    let model: OpenRouterModel
    var isSelected: Bool = false
    /// The picker is a narrow popover; Settings has room for the full id.
    var showsID: Bool = true
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? Design.Accent.brand : .secondary.opacity(0.5))
                Text(model.name)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                ModelTierBadge(tier: model.tier)
                if model.supportsImages {
                    Image(systemName: "camera")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                Spacer(minLength: 4)
                if showsID {
                    Text(model.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Coloured tier marker. Free is loudest because that is what people scan
/// for; the paid tiers stay quiet.
struct ModelTierBadge: View {
    let tier: ModelTier

    var body: some View {
        Text(tier == .unpriced ? "AUTO" : tier.label.uppercased())
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(color.opacity(0.22))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help(tier.help)
    }

    private var color: Color {
        switch tier {
        case .free:     return .green
        case .light:    return .teal
        case .moderate: return .blue
        case .frontier: return .orange
        case .unpriced: return .secondary
        }
    }
}

/// Search box + tier drop-down + tier counts + images toggle.
///
/// Identical in both places on purpose — that is the whole point.
struct ModelFilterBar: View {
    @Bindable var store = ModelFilterStore.shared
    var showsReset: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Search models", text: $store.search)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))

                Picker("", selection: $store.tier) {
                    Text("All tiers").tag(ModelTier?.none)
                    ForEach(ModelTier.allCases) { t in
                        Text(t.label).tag(ModelTier?.some(t))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 120)
                .help("Narrow by price tier. Light models answer fastest.")

                Toggle("Images", isOn: $store.imagesOnly)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("Only models that accept image input, so ⌘⇧⏎ screenshots work")
            }

            HStack(spacing: 8) {
                ForEach(ModelTier.allCases) { t in
                    let n = OverlayViewModel.availableModels.filter { $0.tier == t }.count
                    if n > 0 {
                        Button {
                            store.tier = (store.tier == t) ? nil : t
                        } label: {
                            Text("\(t.label) \(n)")
                                .font(.system(size: 10,
                                              weight: store.tier == t ? .semibold : .regular))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(store.tier == t ? Design.Accent.brand.opacity(0.25)
                                          : Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .help(t.help)
                    }
                }
                Spacer()
                if showsReset && store.isFiltering {
                    Button("Reset") { store.reset() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

/// The model list itself, grouped by provider, with the empty and no-match
/// states handled.
struct ModelListView: View {
    @Bindable var store = ModelFilterStore.shared
    var selectedID: String?
    var showsID: Bool = true
    var onSelect: (OpenRouterModel) -> Void

    var body: some View {
        let groups = store.groupedModels
        if groups.isEmpty {
            Text(store.isFiltering
                 ? "No models match these filters."
                 : "No models available.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.vertical, 8)
        } else {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(groups, id: \.provider) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.provider)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.85))
                            .textCase(.uppercase)
                            .kerning(0.4)
                        LazyVStack(spacing: 1) {
                            ForEach(group.models, id: \.id) { m in
                                ModelRow(model: m,
                                         isSelected: m.id == selectedID,
                                         showsID: showsID) {
                                    onSelect(m)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
/// The overlay's model control: a popover holding the same filter bar and
/// list as Settings → AI, plus a field for adding a model by hand.
struct ModelPickerButton: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var isOpen = false
    @State private var customDraft = ""

    let currentModelName: String
    /// Fired after the selection is applied. The chat surface uses it to
    /// re-ask the same question with the newly chosen model.
    var onSelect: ((OpenRouterModel) -> Void)?

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            Label("Model: \(currentModelName)", systemImage: "cpu")
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            pickerBody
                .frame(width: 460, height: 420)
        }
    }

    private var pickerBody: some View {
        @Bindable var store = ModelFilterStore.shared
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Add model id, e.g. qwen/qwen3-235b:free", text: $customDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit(addCustom)
                Button("Add", action: addCustom)
                    .buttonStyle(.secondaryCompact)
                    .disabled(customDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ModelFilterBar(store: store)

            Divider().opacity(0.4)

            ScrollView {
                ModelListView(store: store,
                              selectedID: vm.selectedModel,
                              showsID: true) { m in
                    vm.selectedModel = m.id
                    onSelect?(m)
                    isOpen = false
                }
                .padding(.vertical, 2)
            }
        }
        .padding(10)
    }

    private func addCustom() {
        let draft = customDraft
        if OpenRouterCatalog.shared.addCustom(slug: draft) {
            customDraft = ""
            ModelFilterStore.shared.reset()
        }
    }
}
