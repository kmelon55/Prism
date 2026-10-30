import AppKit

/// Reads capture candidates from and writes stored payloads to a pasteboard. Ported from
/// `read_capture_candidate` and `write_prepared_clipboard_payload`. Tests pass private named pasteboards.
enum PasteboardIO {
    struct Observation {
        var revision: Int
        var result: Result<ClipboardPayload?, ClipboardError>
    }

    private static let fileURLType = "public.file-url"
    private static let plainTextType = "public.utf8-plain-text"
    private static let imageTypes: [(uti: String, mime: String)] = [
        ("public.png", "image/png"), ("public.jpeg", "image/jpeg"), ("org.webmproject.webp", "image/webp"), ("public.tiff", "image/tiff"),
    ]
    private static let unsupportedTypes: Set<String> = ["public.heic", "com.compuserve.gif", "public.file-url", "NSFilenamesPboardType"]

    /// Reads every privacy marker before any data and rejects torn reads (returns `nil`) when the pasteboard
    /// changes while it is being read. An unchanged revision or the first look only establishes a baseline,
    /// so unchanged images are never re-read.
    static func observe(
        _ board: NSPasteboard, previous: Int?, preferences: ClipboardPreferences, frontmost: () -> String?
    ) -> Observation? {
        let revision = board.changeCount
        let source = frontmost()
        if preferences.excludes(source) { return Observation(revision: revision, result: .success(nil)) }
        guard let previous, previous != revision else { return Observation(revision: revision, result: .success(nil)) }
        guard let types = board.types?.map(\.rawValue), let items = board.pasteboardItems else { return nil }
        if types.contains(where: ClipboardPolicy.isPrivateType)
            || items.contains(where: { $0.types.contains { ClipboardPolicy.isPrivateType($0.rawValue) } }) {
            return Observation(revision: revision, result: .success(nil))
        }
        let result = Result { () throws(ClipboardError) in try candidate(board, types: types, items: items) }
        if source != frontmost() { return Observation(revision: revision, result: .success(nil)) }
        return revision == board.changeCount ? Observation(revision: revision, result: result) : nil
    }

    /// Files first, then supported images, then UTF-8 text. Mixed multi-item content is rejected.
    private static func candidate(_ board: NSPasteboard, types: [String], items: [NSPasteboardItem]) throws(ClipboardError) -> ClipboardPayload? {
        if items.contains(where: { $0.types.contains { $0.rawValue == fileURLType } }) {
            guard items.count <= ClipboardLimits.maxFileReferences else {
                throw ClipboardError("Too many file references. Clipboard history supports up to 64 files per entry.")
            }
            var urls: [String] = []
            var size = 0
            for item in items {
                guard let data = item.data(forType: NSPasteboard.PasteboardType(fileURLType)) else {
                    throw ClipboardError("Mixed clipboard items are unsupported. Copy files together to save references.")
                }
                size += data.count
                guard size <= ClipboardLimits.maxReferenceBytes else { throw .referenceLimit }
                guard let value = String(data: data, encoding: .utf8) else { throw .invalidReference }
                urls.append(value)
            }
            _ = try ClipboardPolicy.validateFileReferences(urls)
            return .files(urls)
        }
        guard items.count <= 1 else {
            throw ClipboardError("Multiple non-file clipboard items are unsupported. Copy one text or image item.")
        }
        for (uti, mime) in imageTypes where types.contains(uti) {
            guard let data = board.data(forType: NSPasteboard.PasteboardType(uti)) else {
                throw ClipboardError("Image clipboard data is unavailable.")
            }
            guard data.count <= ClipboardImages.inputLimit(mimeType: mime) else {
                throw ClipboardError("Image exceeds the clipboard size limit.")
            }
            return try ClipboardImages.payload(bytes: data, mimeType: mime)
        }
        if types.contains(where: unsupportedTypes.contains) { throw .unsupported }
        guard let data = board.data(forType: NSPasteboard.PasteboardType(plainTextType)) else { throw .unsupported }
        guard data.count <= ClipboardLimits.maxTextBytes else {
            throw ClipboardError("Text exceeds the 128 KB clipboard history limit.")
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ClipboardError("Clipboard text is not valid UTF-8.") }
        return ClipboardPolicy.shouldCapture(text) ? .text(text) : nil
    }

    /// Writes a prepared payload and returns the pasteboard revision it produced, which paste compares
    /// immediately before sending ⌘V.
    @discardableResult
    static func write(_ payload: ClipboardPayload, to board: NSPasteboard) throws(ClipboardError) -> Int {
        var items: [NSPasteboardItem] = []
        switch payload {
        case .text(let text):
            let item = NSPasteboardItem()
            guard item.setString(text, forType: NSPasteboard.PasteboardType(plainTextType)) else {
                throw ClipboardError("Prism could not prepare clipboard text.")
            }
            items.append(item)
        case .image(let bytes, let mimeType, let width, let height):
            guard bytes.count <= ClipboardLimits.maxImageBytes, ClipboardPolicy.validDimensions(width: width, height: height) else {
                throw ClipboardError("Stored image exceeds supported limits.")
            }
            guard let uti = imageTypes.first(where: { $0.mime == mimeType && $0.mime != "image/tiff" })?.uti else {
                throw ClipboardError("Unsupported clipboard image format.")
            }
            let item = NSPasteboardItem()
            guard item.setData(bytes, forType: NSPasteboard.PasteboardType(uti)) else {
                throw ClipboardError("Prism could not prepare the clipboard image.")
            }
            items.append(item)
        case .files(let urls):
            for url in urls {
                let item = NSPasteboardItem()
                guard item.setString(url, forType: NSPasteboard.PasteboardType(fileURLType)) else {
                    throw ClipboardError("Prism could not prepare file references.")
                }
                items.append(item)
            }
        }
        board.clearContents()
        guard board.writeObjects(items) else { throw ClipboardError("Prism could not copy that history entry.") }
        return board.changeCount
    }
}

/// Remembers the last pasteboard revision per capture generation. A new generation (enable, clear, delete,
/// privacy change) or a pause starts from a fresh baseline, so content copied meanwhile is never imported.
struct CaptureCursor {
    private var generation: UInt64?
    private var revision: Int?

    func previous(for generation: UInt64) -> Int? {
        self.generation == generation ? revision : nil
    }

    /// Returns true when this is a new revision within the same generation.
    mutating func observe(generation: UInt64, revision: Int) -> Bool {
        let changed = self.generation == generation && self.revision != revision
        self.generation = generation
        self.revision = revision
        return changed
    }

    mutating func pause() {
        generation = nil
        revision = nil
    }
}
