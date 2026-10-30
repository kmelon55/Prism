import Foundation
import Testing
@testable import PrismScripts

@Test func parsesPrismAndRaycastMetadata() {
    let metadata = ScriptMetadataParser.parse("""
    #!/bin/bash

    # Required parameters:
    # @raycast.schemaVersion 1
    # @raycast.title Open   Session
    # @raycast.mode compact

    # Optional parameters:
    # @raycast.icon 🤖
    # @raycast.packageName Developer Utils
    # @raycast.needsConfirmation true
    # @raycast.refreshTime 5m
    # @raycast.currentDirectoryPath ~/Projects
    # @raycast.description Opens a session
    # @raycast.author Someone
    # prism:keywords=one, , two ,three
    echo hi
    """)
    #expect(metadata.schemaVersion == 1)
    #expect(metadata.name == "Open   Session")
    #expect(metadata.mode == .compact)
    #expect(metadata.icon == "🤖")
    #expect(metadata.packageName == "Developer Utils")
    #expect(metadata.needsConfirmation)
    #expect(metadata.refreshSeconds == 300)
    #expect(metadata.currentDirectoryPath == "~/Projects")
    #expect(metadata.description == "Opens a session")
    #expect(metadata.author == "Someone")
    #expect(metadata.keywords == ["one", "two", "three"])
    #expect(metadata.argumentError == nil)
}

@Test func acceptsRaycastCommentStylesForOtherLanguages() {
    let javascript = ScriptMetadataParser.parse("#!/usr/bin/env node\n// @raycast.title Node Tool\n// @raycast.mode inline\n")
    #expect(javascript.name == "Node Tool")
    #expect(javascript.mode == .inline)
    let applescript = ScriptMetadataParser.parse("#!/usr/bin/osascript\n-- @raycast.title Mail\n")
    #expect(applescript.name == "Mail")
}

@Test func laterTitleWinsAndNameAliasesTitle() {
    #expect(ScriptMetadataParser.parse("# prism:name=First\n# @raycast.title Second\n").name == "Second")
}

@Test func rejectsControlCharactersAndOverlongValues() {
    let long = String(repeating: "a", count: 121)
    let metadata = ScriptMetadataParser.parse("# prism:name=\(long)\n# prism:description=bad\u{7}\n")
    #expect(metadata.name == nil)
    #expect(metadata.description == nil)
    #expect(ScriptMetadataParser.parse("# prism:name=\(String(repeating: "한", count: 120))\n").name?.count == 120)
}

@Test func metadataIsBoundedToTheFirst64Lines() {
    let text = String(repeating: "echo\n", count: 64) + "# prism:name=Late\n"
    #expect(ScriptMetadataParser.parse(text).name == nil)
    let early = String(repeating: "echo\r\n", count: 63) + "# prism:name=Edge\r\n"
    #expect(ScriptMetadataParser.parse(early).name == "Edge")
}

@Test func metadataIsBoundedToTheFirst8KiB() throws {
    let directory = TestDirectory()
    let padding = "#" + String(repeating: "x", count: 8_200) + "\n"
    directory.executable("big.sh", "#!/bin/sh\n" + padding + "# prism:name=Hidden\n")
    #expect(ScriptMetadataParser.read(url: directory.url.appending(path: "big.sh")).name == nil)
}

@Test func argumentsMustBeNumberedFromOneUpToThree() {
    let valid = ScriptMetadataParser.parse("""
    # @raycast.argument2 { "type": "text", "placeholder": "Second", "optional": true }
    # @raycast.argument1 { "type": "password", "placeholder": "First" }
    """)
    #expect(valid.argumentError == nil)
    #expect(valid.arguments.map(\.placeholder) == ["First", "Second"])
    #expect(valid.arguments[1].optional)

    let duplicate = ScriptMetadataParser.parse("""
    # prism:argument1={"type":"text","placeholder":"A"}
    # prism:argument1={"type":"text","placeholder":"B"}
    """)
    #expect(duplicate.argumentError == "Duplicate script argument metadata.")
    #expect(ScriptMetadataParser.parse(#"# prism:argument4={"type":"text","placeholder":"A"}"#).argumentError == "Invalid script argument metadata.")
    #expect(ScriptMetadataParser.parse(#"# prism:argument2={"type":"text","placeholder":"A"}"#).argumentError == "Script arguments must be numbered consecutively from 1.")
    #expect(ScriptMetadataParser.parse(#"# prism:argument1={"type":"dropdown","placeholder":"A"}"#).argumentError != nil, "dropdown needs data")
    #expect(ScriptMetadataParser.parse(#"# prism:argument1={"type":"text","placeholder":" "}"#).argumentError != nil)
    #expect(ScriptMetadataParser.parse(#"# prism:argument1={"type":"text","placeholder":"A","optional":"yes"}"#).argumentError != nil)
}

@Test func ignoresUnknownArgumentKeysLikeSerde() {
    let metadata = ScriptMetadataParser.parse(#"# @raycast.argument1 { "type": "text", "placeholder": "Query", "secure": false }"#)
    #expect(metadata.argumentError == nil)
    #expect(metadata.arguments.count == 1)
}

@Test func invalidRaycastExtrasNeverBlockExecution() {
    let metadata = ScriptMetadataParser.parse("# @raycast.mode loud\n# @raycast.refreshTime 5s\n# @raycast.schemaVersion x\n")
    #expect(metadata.mode == nil)
    #expect(metadata.refreshSeconds == nil)
    #expect(metadata.schemaVersion == nil)
    #expect(metadata.argumentError == nil)
}

@Test func refreshIntervalsFollowRaycastUnits() {
    #expect(ScriptMetadataParser.refreshInterval("10s") == 10)
    #expect(ScriptMetadataParser.refreshInterval("2h") == 7_200)
    #expect(ScriptMetadataParser.refreshInterval("1d") == 86_400)
    #expect(ScriptMetadataParser.refreshInterval("9s") == nil)
    #expect(ScriptMetadataParser.refreshInterval("1w") == nil)
    #expect(ScriptMetadataParser.refreshInterval("m") == nil)
}

@Test func percentEncodingMatchesRust() {
    #expect(ScriptArgumentValidation.percentEncode("a-b_c.d!e~f*g'h(i)j") == "a-b_c.d!e~f*g'h(i)j")
    #expect(ScriptArgumentValidation.percentEncode("a b/c?d=e&f") == "a%20b%2Fc%3Fd%3De%26f")
    #expect(ScriptArgumentValidation.percentEncode("é") == "%C3%A9")
}

@Test func emptyOptionalArgumentsKeepTheirPositionalSlot() throws {
    var summary = ScriptCommandSummary(
        id: "sc_0000000000000001", title: "T", keywords: [],
        arguments: [ScriptArgument(type: "text", placeholder: "A", optional: true),
                    ScriptArgument(type: "dropdown", placeholder: "B", optional: true, data: [ScriptArgumentOption(title: "X", value: "x")])],
        timeoutSeconds: 10, mode: .fullOutput, needsConfirmation: false
    )
    #expect(try ScriptArgumentValidation.validate(summary, []) == ["", ""])
    #expect(try ScriptArgumentValidation.validate(summary, ["", "x"]) == ["", "x"])
    #expect(throws: ScriptError("Argument 2 must be one of the listed choices.")) { try ScriptArgumentValidation.validate(summary, ["", "y"]) }
    #expect(throws: ScriptError("Argument 1 is invalid or too long.")) {
        try ScriptArgumentValidation.validate(summary, [String(repeating: "a", count: 8_193)])
    }
    summary.argumentError = "Invalid script argument metadata."
    #expect(throws: ScriptError("Invalid script argument metadata.")) { try ScriptArgumentValidation.validate(summary, []) }
}

@Test func resolvesRaycastIcons() throws {
    let directory = TestDirectory()
    directory.file("icon.png", "png")
    #expect(ScriptRegistry.icon("🤖", root: directory.path) == .emoji("🤖"))
    #expect(ScriptRegistry.icon("icon.png", root: directory.path) == .image(path: directory.path + "/icon.png"))
    #expect(ScriptRegistry.icon("missing.png", root: directory.path) == nil)
    #expect(ScriptRegistry.icon("https://example.com/icon.png", root: directory.path) == nil)
}
