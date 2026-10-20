import SwiftUI

struct KeyFieldView: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    /// Optional one-liner under the field — where to get the key, what it
    /// unlocks. Nil for the keys whose labels already say it.
    var hint: String? = nil
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label).font(.caption.weight(.medium)).foregroundColor(.secondary)
                // Saved, not verified: no request is made to check the key.
                let saved = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Text(saved ? "✓ Saved" : "Not set")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(saved ? Design.Accent.green : .secondary)
            }
            HStack(spacing: 4) {
                if visible {
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                } else {
                    SecureField(placeholder, text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
                Button { visible.toggle() } label: {
                    Image(systemName: visible ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(visible ? "Hide" : "Show (enables paste)")
            }
            if let hint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
