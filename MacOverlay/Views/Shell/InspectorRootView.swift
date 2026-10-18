import SwiftUI
import AppKit

/// The troubleshooting window's contents.
///
/// Deliberately plain, and deliberately not the overlay: this is a place to
/// look at the interface rather than use it. Two things it has to do well —
/// Quit has to be reachable in one click, because hunting for a menu bar item
/// to escape an app you cannot see the edges of is the single most annoying
/// thing an app can make you do; and everything has to be photographable, so
/// no floating layers and nothing hidden from screen capture.
struct InspectorRootView: View {

    var onQuit: () -> Void
    var onSnapshot: () -> [URL]
    var onClose: () -> Void

    @State private var lastSaved: URL?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            // Scrollable by construction and given room to scroll. A clipped
            // or non-scrolling column is what makes a layout look broken and
            // be impossible to photograph the bottom of.
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    state
                    diagnostics
                    Text("Everything below is the live state of the app. "
                         + "This window is never excluded from screen capture, "
                         + "so screenshots of it work.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
        }
        .frame(minWidth: 380, minHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "stethoscope")
                .foregroundColor(Design.Accent.brand)
            VStack(alignment: .leading, spacing: 1) {
                Text("Troubleshooting").font(.system(size: 13, weight: .semibold))
                Text("Quitting is here. It will not be hard to find again.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
            Button("Quit", action: onQuit)
                .keyboardShortcut("q")
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                lastSaved = onSnapshot().first
            } label: {
                Label("Save a picture of the app", systemImage: "camera")
            }
            .buttonStyle(.borderedProminent)

            if let lastSaved {
                Text(lastSaved.lastPathComponent)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                Text("Goes to your Desktop. No permission needed.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            Spacer()

            Button("Close window", action: onClose)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var state: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Running")
                .font(.system(size: 12, weight: .semibold))
            Label("Process is live — \(ProcessInfo.processInfo.processIdentifier)",
                  systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
            Label("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")"
                  + " · \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")",
                  systemImage: "info.circle")
                .foregroundColor(.secondary)
            Label("Screen-sharing hiding is on in the overlay and deliberately "
                  + "off here.", systemImage: "eye")
                .foregroundColor(.secondary)
        }
        .font(.system(size: 11))
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paths — copy these when reporting a problem")
                .font(.system(size: 12, weight: .semibold))
            Group {
                copyRow("App data",
                        "\(FileManager.default.homeDirectoryForCurrentUser)"
                        + "/Library/Application Support/\(dataDirName)")
                copyRow("Logs",
                        "\(FileManager.default.homeDirectoryForCurrentUser)"
                        + "/Library/Logs/\(dataDirName)")
            }
        }
    }

    private var dataDirName: String {
        // Matches JSONStore's directory, which is where the bank and sessions
        // actually live.
        AppChannel.current.dataDirectoryName
    }

    private func copyRow(_ label: String, _ path: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11, weight: .medium)).frame(width: 70, alignment: .leading)
            Text(path).font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("Copy path")
        }
    }
}