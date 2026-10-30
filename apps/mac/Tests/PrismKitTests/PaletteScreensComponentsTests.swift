import Testing
@testable import PrismKit

@Test func shortcutCapsSplitModifiersFromTheKey() {
    #expect(PrismShortcutCaps.split("⌘K") == ["⌘", "K"])
    #expect(PrismShortcutCaps.split("⇧⌘C") == ["⇧", "⌘", "C"])
    #expect(PrismShortcutCaps.split("⌥⌘↑↓") == ["⌥", "⌘", "↑↓"])
    #expect(PrismShortcutCaps.split("↵") == ["↵"])
    #expect(PrismShortcutCaps.split("esc") == ["esc"])
}

@MainActor
@Test func glyphsPreferOutlineSymbols() {
    #expect(PrismGlyph.outline("moon.fill") == "moon")
    #expect(PrismGlyph.outline("gearshape") == "gearshape")
    // No outline variant: the name stays as given.
    #expect(PrismGlyph.outline("not.a.symbol.fill") == "not.a.symbol.fill")
}
