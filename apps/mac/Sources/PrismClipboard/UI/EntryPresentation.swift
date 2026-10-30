import AppKit
import SwiftUI

/// How a history entry reads in the list and preview: a one-line title, and whether stored text is a link
/// or a color so it can get a matching icon. Stored data is unchanged; this is display only.
struct EntryPresentation {
    enum Style: Equatable {
        case text
        case link(URL)
        case color(NSColor)
        case image
        case files(paths: [String])
    }

    let entry: ClipboardEntry

    var style: Style {
        switch entry.kind {
        case .image: return .image
        case .files: return .files(paths: entry.text.split(separator: "\n").map(String.init))
        case .text:
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let color = Self.color(trimmed) { return .color(color) }
            if let url = Self.link(trimmed) { return .link(url) }
            return .text
        }
    }

    var title: String {
        switch style {
        case .image:
            let format = entry.mimeType.map { $0.replacingOccurrences(of: "image/", with: "").uppercased() } ?? ""
            let size = entry.width.flatMap { w in entry.height.map { "\(w) × \($0)" } } ?? ""
            return [ClipboardText.localize("Image"), format, size].filter { !$0.isEmpty }.joined(separator: " · ")
        case .files(let paths):
            let names = paths.map { URL(filePath: $0).lastPathComponent }
            guard let first = names.first else { return ClipboardText.localize("Files") }
            if names.count == 1 { return first }
            return String(format: ClipboardText.localize("%@ and %lld more"), first, Int64(entry.fileCount - 1))
        case .text, .link, .color:
            let line = entry.text.split(whereSeparator: \.isNewline)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return collapsed.isEmpty ? ClipboardText.localize("Empty clipboard entry") : String(collapsed.prefix(200))
        }
    }

    var kindTitle: String {
        switch style {
        case .text: ClipboardText.localize("Text")
        case .link: ClipboardText.localize("Link")
        case .color: ClipboardText.localize("Color")
        case .image: ClipboardText.localize("Image")
        case .files: ClipboardText.localize("File references")
        }
    }

    var symbol: String {
        switch style {
        case .text: "text.alignleft"
        case .link: "link"
        case .color: "paintpalette"
        case .image: "photo"
        case .files: "doc"
        }
    }

    /// `#RGB`, `#RRGGBB` or `#RRGGBBAA`.
    static func color(_ text: String) -> NSColor? {
        guard text.hasPrefix("#"), [4, 7, 9].contains(text.count) else { return nil }
        var hex = String(text.dropFirst())
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        return NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        )
    }

    /// A single web or mail link with no surrounding text.
    static func link(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https": return url.host() == nil ? nil : url
        case "mailto": return url
        default: return nil
        }
    }
}

enum ClipboardFormat {
    static var locale: Locale {
        Bundle.module.preferredLocalizations.first.map(Locale.init(identifier:)) ?? .current
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        if now.timeIntervalSince(date) < 60 { return ClipboardText.localize("Just now") }
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
