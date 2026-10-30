import Foundation

/// One fully-qualified Unicode Emoji 16.0 sequence with CLDR 46 English and Korean names.
/// Decoded from `emoji-data.json`, the same file the Tauri picker bundles.
struct EmojiRecord: Decodable, Sendable, Hashable {
    let emoji: String
    let name: String
    let nameKo: String
    let group: String
    let keywords: [String]
}

enum SkinTone: String, CaseIterable, Sendable, Identifiable {
    case none = ""
    case light = "\u{1F3FB}"
    case mediumLight = "\u{1F3FC}"
    case medium = "\u{1F3FD}"
    case mediumDark = "\u{1F3FE}"
    case dark = "\u{1F3FF}"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "Default", bundle: .module)
        case .light: String(localized: "Light", bundle: .module)
        case .mediumLight: String(localized: "Medium-light", bundle: .module)
        case .medium: String(localized: "Medium", bundle: .module)
        case .mediumDark: String(localized: "Medium-dark", bundle: .module)
        case .dark: String(localized: "Dark", bundle: .module)
        }
    }

    /// A raised hand in this tone, used as the picker's swatch.
    var swatch: String { "✋" + rawValue }
}

/// Browsing categories in Unicode group order. `id` is the group name in the data file.
struct EmojiCategory: Identifiable, Hashable, Sendable {
    let id: String
    let glyph: String
    let english: String
    let korean: String

    static let recent = EmojiCategory(id: "recent", glyph: "◷", english: "Recent", korean: "최근")
    static let all = EmojiCategory(id: "all", glyph: "⊞", english: "All", korean: "전체")

    static let groups: [EmojiCategory] = [
        EmojiCategory(id: "Smileys & Emotion", glyph: "😀", english: "Smileys", korean: "표정"),
        EmojiCategory(id: "People & Body", glyph: "👋", english: "People", korean: "사람"),
        EmojiCategory(id: "Animals & Nature", glyph: "🌿", english: "Nature", korean: "자연"),
        EmojiCategory(id: "Food & Drink", glyph: "🍊", english: "Food", korean: "음식"),
        EmojiCategory(id: "Travel & Places", glyph: "🚀", english: "Travel", korean: "여행"),
        EmojiCategory(id: "Activities", glyph: "⚽", english: "Activities", korean: "활동"),
        EmojiCategory(id: "Objects", glyph: "💡", english: "Objects", korean: "사물"),
        EmojiCategory(id: "Symbols", glyph: "💛", english: "Symbols", korean: "기호"),
        EmojiCategory(id: "Flags", glyph: "🏳️", english: "Flags", korean: "국기"),
    ]

    func title(korean useKorean: Bool) -> String { useKorean ? korean : english }
}

/// The searchable emoji catalog. Building it decodes about 1 MB of JSON, so it is loaded lazily off the
/// main actor and released again a while after the picker closes.
final class EmojiCatalog: Sendable {
    let all: [EmojiRecord]
    /// Records without skin-tone modifiers; the default grid and the search source.
    let base: [EmojiRecord]
    let byEmoji: [String: EmojiRecord]
    /// Homogeneous skin-tone variants keyed by the base sequence without tones or U+FE0F.
    let variants: [String: [SkinTone: EmojiRecord]]
    /// Normalized search text for each record in `base`, computed once.
    private let haystacks: [String]

    /// Hand-maintained Korean and English slang, as in the Tauri catalog.
    static let aliases: [String: String] = [
        "👍": "따봉 좋아 좋아요 굿 good yes +1 thumbs up", "👎": "싫어 별로 아니 no -1",
        "😂": "ㅋㅋ ㅋㅋㅋ 웃음 lol haha", "🤣": "ㅋㅋ ㅋㅋㅋ 웃음 lol lmao", "😭": "ㅠㅠ ㅜㅜ 눈물 슬픔 sad cry",
        "❤️": "하트 사랑 love heart", "🔥": "불 핫 hot fire", "🙏": "감사 고마워 부탁 thank thanks please pray",
        "🎉": "축하 생일 파티 congratulations congrats party", "✅": "완료 확인 체크 done check",
        "👋": "안녕 인사 hello hi bye", "💻": "컴퓨터 노트북 개발 coding laptop",
    ]

    init(records: [EmojiRecord]) {
        all = records
        var base: [EmojiRecord] = []
        var byEmoji: [String: EmojiRecord] = [:]
        var variants: [String: [SkinTone: EmojiRecord]] = [:]
        for record in records {
            if byEmoji[record.emoji] == nil { byEmoji[record.emoji] = record }
            let tones = Array(record.emoji.unicodeScalars.filter(Self.isTone))
            if tones.isEmpty {
                base.append(record)
            } else if tones.allSatisfy({ $0 == tones[0] }), let tone = SkinTone(rawValue: String(tones[0])) {
                variants[Self.stripTone(record.emoji), default: [:]][tone] = record
            }
        }
        self.base = base
        self.byEmoji = byEmoji
        self.variants = variants
        haystacks = base.map { record in
            let category = EmojiCategory.groups.first { $0.id == record.group }
            let labels = category.map { [$0.english, $0.korean] } ?? []
            let parts = [record.name, record.nameKo, record.group] + labels + record.keywords + [Self.aliases[record.emoji] ?? ""]
            return Self.normalize(parts.joined(separator: " "))
        }
    }

    static func load(from url: URL) throws -> EmojiCatalog {
        let data = try Data(contentsOf: url)
        return EmojiCatalog(records: try JSONDecoder().decode([EmojiRecord].self, from: data))
    }

    static var bundledDataURL: URL? { Bundle.module.url(forResource: "emoji-data", withExtension: "json") }

    func withSkinTone(_ record: EmojiRecord, _ tone: SkinTone) -> EmojiRecord {
        guard tone != .none else { return record }
        return variants[Self.stripTone(record.emoji)]?[tone] ?? record
    }

    /// Records matching every whitespace-separated term in any category, or the browsed category when the
    /// query is empty. An exact emoji, including mixed skin tones, returns that exact sequence.
    func search(_ query: String, category: String, tone: SkinTone, recent: [String]) -> [EmojiRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = byEmoji[trimmed] { return [exact] }
        let normalized = Self.normalize(trimmed)
        let tokens = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.isEmpty {
            if category == EmojiCategory.recent.id { return recent.compactMap { byEmoji[$0] } }
            return base.filter { category == EmojiCategory.all.id || $0.group == category }.map { withSkinTone($0, tone) }
        }
        var results: [EmojiRecord] = []
        for (index, haystack) in haystacks.enumerated() where tokens.allSatisfy({ haystack.contains($0) }) {
            results.append(withSkinTone(base[index], tone))
        }
        return results
    }

    static func normalize(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    private static func isTone(_ scalar: Unicode.Scalar) -> Bool { (0x1F3FB...0x1F3FF).contains(scalar.value) }

    static func stripTone(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars where !isTone(scalar) && scalar.value != 0xFE0F { scalars.append(scalar) }
        return String(scalars)
    }
}

/// Loads the catalog once and shares it, releasing it a few minutes after the picker was last used.
@MainActor
final class EmojiCatalogLoader {
    static let shared = EmojiCatalogLoader()

    private var catalog: EmojiCatalog?
    private var loading: Task<EmojiCatalog?, Never>?
    private var release: Task<Void, Never>?
    private let url: URL?

    init(url: URL? = EmojiCatalog.bundledDataURL) {
        self.url = url
    }

    var cached: EmojiCatalog? { catalog }

    func load() async -> EmojiCatalog? {
        release?.cancel()
        if let catalog { return catalog }
        if let loading { return await loading.value }
        let url = url
        let task = Task.detached(priority: .userInitiated) { () -> EmojiCatalog? in
            guard let url else { return nil }
            return try? EmojiCatalog.load(from: url)
        }
        loading = task
        let result = await task.value
        loading = nil
        catalog = result
        return result
    }

    /// Called when the picker closes. Reopening within the grace period reuses the catalog.
    func scheduleRelease(after delay: Duration = .seconds(300)) {
        release?.cancel()
        release = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.catalog = nil
        }
    }
}
