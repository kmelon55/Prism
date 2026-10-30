import Foundation
import Testing
@testable import PrismLibrary

@Suite struct LibraryTemplateTests {
    func entry(_ kind: LibraryEntry.Kind, _ value: String) -> LibraryEntry {
        LibraryEntry(id: "entry", kind: kind, title: "Example", value: value)
    }

    @Test func quicklinkQueryIsEncodedWithoutChangingURLAuthority() throws {
        let template = entry(.link, "https://example.com/search?q={query}&source=prism")
        try LibraryValidation.validate(template)
        #expect(try LibraryTemplate.expand(template, query: "가 &x=#", date: "", time: "", clipboard: "")
            == "https://example.com/search?q=%EA%B0%80%20%26x%3D%23&source=prism")
        #expect(throws: LibraryError.emptyQuery) { try LibraryTemplate.expand(template, query: " ", date: "", time: "", clipboard: "") }
        for value in ["https://{query}/", "https://example.com/{query}", "https://example.com/?q=a#{query}", "javascript:{query}"] {
            #expect(throws: (any Error).self, "\(value)") { try LibraryValidation.validate(entry(.link, value)) }
        }
    }

    @Test func snippetPlaceholdersExpandOnceWithBoundedOutput() throws {
        let template = entry(.snippet, "{date} {time} {clipboard} {unknown}")
        #expect(try LibraryTemplate.expand(template, query: nil, date: "2026-09-09", time: "15:00", clipboard: "{date}")
            == "2026-09-09 15:00 {date} {unknown}")
        #expect(throws: LibraryError.expandedTooLong) {
            try LibraryTemplate.expand(template, query: nil, date: "", time: "", clipboard: String(repeating: "a", count: 128 * 1024))
        }
    }

    @Test func dynamicEntriesNeedAPreview() {
        #expect(entry(.link, "https://example.com/?q={query}").isDynamic)
        #expect(entry(.snippet, "Today is {date}").isDynamic)
        #expect(!entry(.snippet, "plain {other}").isDynamic)
        #expect(!entry(.note, "{date}").isDynamic)
        #expect(!entry(.path, "/tmp/{query}").isDynamic)
    }

    @Test func localDateTimeUsesPaddedLocalFormat() {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 4; components.hour = 5; components.minute = 6
        let date = Calendar.current.date(from: components)!
        let formatted = LibraryTemplate.localDateTime(date)
        #expect(formatted.date == "2026-03-04")
        #expect(formatted.time == "05:06")
    }

    /// `validSnippetKeyword` in `snippets/copy.ts` and `valid_keyword` in `snippet_expansion.rs`.
    @Test func invalidAndUnboundedKeywordsRejected() {
        for keyword in ["", ";", "email", ";한글", ";a b", ";a\n", ";a👋"] {
            #expect(!LibraryValidation.isValidKeyword(keyword), "\(keyword)")
        }
        #expect(LibraryValidation.isValidKeyword(";Email_2-x"))
        #expect(LibraryValidation.isValidKeyword(";" + String(repeating: "a", count: 47)))
        #expect(!LibraryValidation.isValidKeyword(";" + String(repeating: "a", count: 48)))
        #expect(LibraryValidation.isValidOptionalKeyword(nil))
        #expect(LibraryValidation.isValidOptionalKeyword(""))
        #expect(!LibraryValidation.isValidOptionalKeyword("abc"))
    }
}
