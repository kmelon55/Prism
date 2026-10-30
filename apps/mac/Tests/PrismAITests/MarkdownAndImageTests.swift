import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PrismAI

struct MarkdownTests {
    @Test func parsesHeadingsParagraphsAndRules() {
        let blocks = MarkdownParser.parse("# Title ##\n\nFirst line\nsecond line\n\n---\nSetext\n===")
        #expect(blocks == [.heading(level: 1, text: "Title"), .paragraph("First line\nsecond line"), .rule, .heading(level: 1, text: "Setext")])
    }

    @Test func parsesFencedCodeIncludingUnclosedStreamingFences() {
        #expect(MarkdownParser.parse("```swift\nlet a = 1\n\nprint(a)\n```\nafter") == [.code(language: "swift", code: "let a = 1\n\nprint(a)"), .paragraph("after")])
        #expect(MarkdownParser.parse("~~~\nstill streaming") == [.code(language: "", code: "still streaming")])
        #expect(MarkdownParser.parse("````\n```\ninner\n```\n````") == [.code(language: "", code: "```\ninner\n```")])
    }

    @Test func parsesNestedAndOrderedListsWithTasks() {
        let blocks = MarkdownParser.parse("1. One\n2. Two\n   - nested **bold**\n   - [x] done\n3. Three\n\n- a\n- b")
        guard case .list(true, 1, let items) = blocks.first else { Issue.record("expected ordered list: \(blocks)"); return }
        #expect(items.count == 3)
        #expect(items[1].blocks == [.paragraph("Two"), .list(ordered: false, start: 1, items: [
            MarkdownListItem(checked: nil, blocks: [.paragraph("nested **bold**")]),
            MarkdownListItem(checked: true, blocks: [.paragraph("done")]),
        ])])
        guard case .list(false, _, let bullets) = blocks.last else { Issue.record("expected bullets"); return }
        #expect(bullets.count == 2)
        #expect(MarkdownParser.parse("3) Start\n4) Next").first == .list(ordered: true, start: 3, items: [
            MarkdownListItem(checked: nil, blocks: [.paragraph("Start")]), MarkdownListItem(checked: nil, blocks: [.paragraph("Next")]),
        ]))
    }

    @Test func parsesQuotesWithNestedBlocks() {
        let blocks = MarkdownParser.parse("> Quote\n> - item\n\nafter")
        #expect(blocks == [.quote([.paragraph("Quote"), .list(ordered: false, start: 1, items: [MarkdownListItem(checked: nil, blocks: [.paragraph("item")])])]), .paragraph("after")])
    }

    @Test func parsesTablesWithAlignmentAndEscapedPipes() {
        let blocks = MarkdownParser.parse("| Name | Value |\n|:-----|------:|\n| a \\| b | `x|y` |\n| c |")
        #expect(blocks == [.table(header: ["Name", "Value"], alignments: [.leading, .trailing], rows: [["a | b", "`x|y`"], ["c", ""]])])
        #expect(MarkdownParser.parse("a | b\nnot a delimiter") == [.paragraph("a | b\nnot a delimiter")])
    }

    @Test func skipsRawHTMLBlocks() {
        #expect(MarkdownParser.parse("<div class=\"x\">\ntext\n</div>") == [.paragraph("text")])
    }

    @MainActor
    @Test func inlineRenderingDropsImagesTagsAndLinksBareURLs() {
        let text = MarkdownInline.attributed("**Bold** and `code` ![chart](https://example.com/a.png) <b>x</b> see https://example.com/docs.")
        let plain = String(text.characters)
        #expect(plain.contains("Bold and code [Image: chart] x see https://example.com/docs."))
        #expect(text.runs.contains { $0.link == URL(string: "https://example.com/docs") })
        #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }
}

struct ImageTests {
    @Test func acceptsSmallJPEGAndRejectsExternalOrInvalidImages() throws {
        try ChatImageCodec.validate(Fixture.image())
        for url in ["https://example.com/private.jpg", "data:image/jpeg;base64,AAAA", "data:image/svg+xml;base64,AAAA"] {
            #expect(throws: AIError.self, "\(url)") { try ChatImageCodec.validate(ChatImage(dataUrl: url)) }
        }
        #expect(throws: AIError.self) { try ChatImageCodec.validate(ChatImage(dataUrl: ChatImageCodec.prefix + String(repeating: "A", count: ChatImageCodec.maxDataURL))) }
        let png = ChatImage(dataUrl: ChatImageCodec.prefix + Fixture.encode(width: 2, height: 2, type: .png).base64EncodedString())
        #expect(throws: AIError.self) { try ChatImageCodec.validate(png) }
    }

    @Test func compressesLargeImagesAndRejectsInvalidFiles() throws {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "region.png")
        try Fixture.encode(width: 2400, height: 900, type: .png).write(to: file)
        let image = try ChatImageCodec.encode(fileAt: file)
        try ChatImageCodec.validate(image)
        #expect(ChatImageCodec.decodedSize(image) == CGSize(width: 1600, height: 600))
        try Data("not an image".utf8).write(to: file)
        #expect(throws: AIError.self) { try ChatImageCodec.encode(fileAt: file) }
        let text = directory.appending(path: "notes.txt")
        try Data("text".utf8).write(to: text)
        #expect(throws: AIError.self) { try ChatImageCodec.encode(fileAt: text) }
    }
}
