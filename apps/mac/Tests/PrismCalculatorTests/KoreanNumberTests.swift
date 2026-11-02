import Testing
@testable import PrismCalculator

@Test(arguments: [
    ("123456789", "1억 2,345만 6,789"), ("120000000", "1억 2천만"), ("4500000", "450만"), ("15000", "1만 5천"),
    ("23000000", "2천3백만"), ("1500000000", "15억"), ("10000", "1만"), ("100000000.5", "1억 0.5"),
    ("12345.67", "1만 2,345.67"), ("-250000", "-25만"), ("1000000000000", "1조"), ("00012345", "1만 2,345"),
])
func readsLargeNumbersWithKoreanUnits(value: String, expected: String) {
    #expect(KoreanNumber.reading(value) == expected)
}

@Test(arguments: ["9999", "0", "1e+21", "abc", "1,000,000", "123456789012345678901"])
func leavesSmallOrUnreadableNumbersAlone(value: String) {
    #expect(KoreanNumber.reading(value) == nil)
}

@Test func currencyReadingsAddWonOnlyForKRW() {
    #expect(KoreanNumber.reading("138000", currency: "KRW") == "13만 8천원")
    #expect(KoreanNumber.reading("138000", currency: "JPY") == "13만 8천")
}
