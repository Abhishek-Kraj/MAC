import Foundation
import PDFKit
import AppKit

/// Extracts plain text from resume files (PDF, DOCX, RTF, TXT, MD).
/// Used both by the "Upload" button and the drag-and-drop handler.
enum ResumeImporter {

    enum ImportError: LocalizedError {
        case unsupportedType(String)
        case unreadable
        case empty
        /// A PDF that opens cleanly and has pages, but not one of them carries
        /// a text layer — a scan, or an image re-wrapped as PDF. Worth naming
        /// separately: it is by far the most common resume failure and the fix
        /// is different from every other error here.
        case scannedPDF

        var errorDescription: String? {
            switch self {
            case .unsupportedType(let ext): return "Unsupported file type: .\(ext)"
            case .unreadable:               return "Could not read file contents"
            case .empty:                    return "File contained no text"
            case .scannedPDF:               return "Scanned PDF — it has no selectable text"
            }
        }

        /// What to actually do about it. A bare "could not read" leaves the
        /// user stuck; this is the step that unblocks them.
        var recovery: String? {
            switch self {
            case .scannedPDF:
                return "Open it in Preview or Acrobat and use File › Export as PDF with text, or paste the text into Context."
            case .unsupportedType(let ext):
                return "Export it as PDF, DOCX, RTF, TXT or MD — .\(ext) is not one of those."
            case .unreadable:
                return "The file may be locked, password-protected, or a cloud placeholder that has not downloaded yet."
            case .empty:
                return "The file parsed but contained no text. Try re-exporting it."
            }
        }
    }

    static let supportedExtensions: Set<String> = ["pdf", "docx", "rtf", "txt", "md", "markdown"]

    /// Best-effort name from file (filename without extension, truncated).
    static func suggestedName(for url: URL) -> String {
        let raw = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return String(raw.prefix(40))
    }

    static func importFile(url: URL) throws -> String {
        try importFileWithSource(url: url).text
    }

    /// Extracts text, plus the original DOCX bytes when the input is a .docx.
    /// Having the raw bytes lets the resume generator rewrite text in-place
    /// while keeping fonts, styles, and layout from the original document.
    static func importFileWithSource(url: URL) throws -> (text: String, originalDOCX: Data?) {
        let ext = url.pathExtension.lowercased()
        let text: String
        var original: Data? = nil
        switch ext {
        case "pdf":
            text = try extractPDF(url: url)
        case "docx":
            text = try extractDOCX(url: url)
            original = try? Data(contentsOf: url)
        case "rtf":
            text = try extractRTF(url: url)
        case "txt", "md", "markdown":
            text = (try? String(contentsOf: url, encoding: .utf8))
                 ?? (try? String(contentsOf: url, encoding: .isoLatin1))
                 ?? ""
        default:
            throw ImportError.unsupportedType(ext)
        }
        let cleaned = normalizeWhitespace(text)
        if cleaned.isEmpty { throw ImportError.empty }
        return (cleaned, original)
    }

    // MARK: - PDF

    private static func extractPDF(url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw ImportError.unreadable }
        var buffer = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let pageText = page.string {
                buffer += pageText
                if !pageText.hasSuffix("\n") { buffer += "\n" }
            }
        }
        // Opens fine, has pages, but no text anywhere: a scan, or an image
        // re-wrapped as PDF. Named explicitly because "no text" on its own
        // reads as "your file is broken" rather than "this format carries no
        // text and needs re-exporting" — and re-exporting is the whole fix.
        if buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ImportError.scannedPDF
        }
        return buffer
    }

    // MARK: - DOCX

    /// DOCX = ZIP archive. We extract `word/document.xml` and pull text from
    /// `<w:t>` elements, treating `<w:p>` (paragraph) as a newline.
    private static func extractDOCX(url: URL) throws -> String {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", url.path, "-d", tempDir.path]
        let errPipe = Pipe()
        unzip.standardError = errPipe
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw ImportError.unreadable }

        let docXML = tempDir.appendingPathComponent("word/document.xml")
        guard let data = try? Data(contentsOf: docXML) else { throw ImportError.unreadable }

        let delegate = DOCXTextParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return delegate.buffer
    }

    // MARK: - RTF

    private static func extractRTF(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let attr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else { throw ImportError.unreadable }
        return attr.string
    }

    // MARK: - Cleanup

    /// Collapses runs of blank lines and trims.
    private static func normalizeWhitespace(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        var blanks = 0
        for line in lines {
            if line.isEmpty {
                blanks += 1
                if blanks <= 1 { out.append("") }
            } else {
                blanks = 0
                out.append(line)
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - DOCX XML parser delegate

private final class DOCXTextParserDelegate: NSObject, XMLParserDelegate {
    var buffer = ""
    private var inTextElement = false
    private var paragraphBuffer = ""

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "w:t" { inTextElement = true }
        if elementName == "w:tab" { paragraphBuffer += "\t" }
        if elementName == "w:br" { paragraphBuffer += "\n" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTextElement { paragraphBuffer += string }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == "w:t" {
            inTextElement = false
        } else if elementName == "w:p" {
            buffer += paragraphBuffer + "\n"
            paragraphBuffer = ""
        }
    }
}
