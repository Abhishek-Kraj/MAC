import SwiftUI
import UniformTypeIdentifiers

/// The shape of every control on the setup forms, in one place.
///
/// The height is set on the control rather than left to padding. Padding is how
/// the Context row came out lop-sided: a 6pt-padded file chip sat in the same
/// `HStack` as a 7pt-padded button, and two points is enough for the eye to read
/// the whole row as broken. A row of fixed-height chips cannot drift like that
/// as fonts and padding change.
enum SetupControl {
    /// Chips, pill pickers — everything but the primary action.
    static let height: CGFloat = 26
    static let horizontalPadding: CGFloat = 11
    /// Inset for text that sits inside a bordered box (the Context field), so
    /// the field's own text lines up with the text inside the chips beside it.
    static let boxPadding: CGFloat = 11
}

extension View {
    /// The capsule every chip on the setup forms wears.
    func setupChip(selected: Bool = false) -> some View {
        self
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(selected ? Design.Ink.inverse : Design.Ink.primary)
            .padding(.horizontal, SetupControl.horizontalPadding)
            .frame(height: SetupControl.height)
            .background(Capsule().fill(selected ? Design.Ink.primary : Design.Surface.controlFill))
            .overlay(Capsule().strokeBorder(
                selected ? Color.white.opacity(0.22) : Design.Surface.hairline,
                lineWidth: 0.5
            ))
    }
}

/// A chip that picks one of a few options — every session, mode and prompt
/// choice on these forms wears it, so the two tabs cannot drift into two
/// different chip heights.
struct SetupChipButton: View {
    let title: String
    var icon: String?
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title)
            }
            .setupChip(selected: selected)
        }
        .buttonStyle(.plain)
    }
}

/// One labelled block of a setup form: a title, an optional badge saying the
/// field can be left empty, then the field.
///
/// The title is plain text flush with the content's leading edge. It used to
/// carry a leading icon, which pushed the title 18pt to the right of the very
/// thing it labelled — every section had two left edges, and the labels read as
/// misaligned with their fields. Settings labels its rows with plain text for
/// the same reason, and these screens are meant to match it.
struct SetupSection<Content: View>: View {
    let title: String
    var optional = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Design.Ink.primary)
                if optional {
                    Text("Optional")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Design.Ink.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Design.Surface.controlFill))
                }
            }
            content
        }
    }
}

/// The Context field, shared by both setup forms so the two tabs cannot drift
/// apart.
///
/// Collapsed to two lines of preview by default. A job description pasted in
/// here runs to thousands of characters, and at full height it was a wall of
/// text that pushed the prep bank, the model and Start below the fold. The
/// collapsed box is a preview, not a disabled field: clicking it opens the
/// editor and puts the caret in it.
struct ContextSection: View {
    @Environment(OverlayViewModel.self) private var vm

    /// Shown when the field is empty. The two forms ask for different things —
    /// a role and a job description, or who is on the call.
    let placeholder: String
    let help: String

    @State private var expanded = false
    @FocusState private var editing: Bool

    var body: some View {
        SetupSection(title: "Context", optional: true) {
            VStack(alignment: .leading, spacing: 8) {
                if expanded { editor } else { preview }
                attachRow
                if !vm.interviewContextFiles.isEmpty {
                    FlowChipList(files: vm.interviewContextFiles) { id in
                        vm.interviewContextFiles.removeAll { $0.id == id }
                    }
                }
            }
        }
    }

    // MARK: Collapsed

    private var preview: some View {
        Button {
            expanded = true
            // The editor does not exist yet, so the caret has to be asked for
            // after it does — a `@FocusState` set in the same turn is lost.
            DispatchQueue.main.async { editing = true }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(vm.interviewContext.isEmpty ? placeholder : vm.interviewContext)
                    .font(.system(size: 12))
                    .foregroundColor(vm.interviewContext.isEmpty ? Design.Ink.muted : Design.Ink.primary)
                    // The point of the collapsed state: exactly two lines, so
                    // the section has a fixed height whatever is pasted in.
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Design.Ink.secondary)
                    .padding(.top, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SetupControl.boxPadding)
            .padding(.vertical, 8)
            .background(box)
            // Without this the gaps between the text and the chevron are not
            // part of the button, and a click in them does nothing.
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(vm.interviewContext.isEmpty ? "Add context" : "Edit context")
    }

    // MARK: Expanded

    private var editor: some View {
        @Bindable var vm = vm
        return TextEditor(text: $vm.interviewContext)
            .scrollContentBackground(.hidden)
            .font(.system(size: 12))
            .focused($editing)
            .padding(.horizontal, SetupControl.boxPadding)
            .padding(.vertical, 8)
            // Whole lines only. A text view whose height is not a whole number
            // of lines clips the last one through the middle of its glyphs, and
            // with a whole job description in here that happened on every
            // scroll — the box ended mid-word, which is what "the Context box
            // cuts a line in half" was.
            .frame(height: Self.editorHeight)
            .background(box)
    }

    /// Rounded to whole lines so nothing is ever half-drawn, and one line of
    /// slack so the last line is never touching the border.
    private static var editorHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: 12)
        let line = ceil(font.ascender - font.descender + font.leading)
        return line * 8 + 16
    }

    private var box: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Design.Surface.inputFill)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
    }

    // MARK: Footer

    private var attachRow: some View {
        HStack(spacing: 6) {
            Button(action: pickContextFiles) {
                HStack(spacing: 5) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 11, weight: .medium))
                    Text(vm.interviewContextFiles.isEmpty ? "Attach files" : "Attach more")
                }
                .setupChip()
            }
            .buttonStyle(.plain)
            .help(help)

            Spacer()

            // Only while the editor is open: the way back to the short form,
            // for someone who opened it and did not type anything.
            if expanded {
                Button {
                    editing = false
                    expanded = false
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Done")
                    }
                    .setupChip()
                }
                .buttonStyle(.plain)
                .help("Collapse to two lines")
            }
        }
    }

    /// Reads the chosen files once and holds the text, so the interview's first
    /// turn does not have to wait on five PDFs being parsed.
    private func pickContextFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            .pdf, .plainText,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "rtf")  ?? .data,
            UTType(filenameExtension: "md")   ?? .plainText,
        ]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            // Skip duplicates (same URL already attached).
            if vm.interviewContextFiles.contains(where: { $0.url == url }) { continue }
            let text = (try? ResumeImporter.importFile(url: url)) ?? ""
            guard !text.isEmpty else { continue }
            vm.interviewContextFiles.append(
                .init(url: url, name: url.lastPathComponent, extractedText: text)
            )
        }
    }
}

/// Simple wrapping chip list for attached interview-context files. Each chip
/// shows a file-type icon, the filename (truncated middle), and an `x` to
/// remove. Wraps to multiple lines when the file count exceeds row width.
struct FlowChipList: View {
    let files: [OverlayViewModel.InterviewContextFile]
    let onRemove: (UUID) -> Void

    var body: some View {
        // Lightweight wrap layout: VStack of HStacks built greedily by
        // estimated width. Keeps the dependency footprint low (no custom
        // Layout) and the file counts are small.
        let rows = pack(files, perRow: 3)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    ForEach(rows[i]) { f in chip(f) }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func chip(_ f: OverlayViewModel.InterviewContextFile) -> some View {
        HStack(spacing: 5) {
            Image(systemName: iconFor(f.name))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Design.Ink.secondary)
            Text(f.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Design.Ink.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                onRemove(f.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Design.Ink.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Design.Surface.controlFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Design.Surface.hairline, lineWidth: 0.5)
        )
    }

    private func iconFor(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":          return "doc.richtext.fill"
        case "docx", "doc":  return "doc.text.fill"
        case "rtf":          return "doc.text.fill"
        case "md", "txt":    return "doc.plaintext.fill"
        default:             return "doc.fill"
        }
    }

    private func pack(_ items: [OverlayViewModel.InterviewContextFile],
                      perRow: Int) -> [[OverlayViewModel.InterviewContextFile]] {
        guard perRow > 0 else { return [items] }
        var out: [[OverlayViewModel.InterviewContextFile]] = []
        var bucket: [OverlayViewModel.InterviewContextFile] = []
        for f in items {
            bucket.append(f)
            if bucket.count == perRow {
                out.append(bucket); bucket.removeAll()
            }
        }
        if !bucket.isEmpty { out.append(bucket) }
        return out
    }
}
