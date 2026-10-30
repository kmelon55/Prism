import AppKit
import QuartzCore
import Testing
@testable import PrismKit

/// The glass blur radius is a private Core Animation filter input; these pin down how it is applied.
@MainActor
struct GlassBlurTests {
    private func blurFilter() throws -> NSObject {
        let type = try #require(NSClassFromString("CAFilter") as? NSObject.Type)
        let filter = type.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?.takeUnretainedValue()
        return try #require(filter as? NSObject)
    }

    @Test func setsTheRadiusOnNestedFiltersAndLeavesMatchingFiltersAlone() throws {
        let child = CALayer()
        child.filters = [try blurFilter()]
        let root = CALayer()
        root.addSublayer(child)

        #expect(PrismGlassView.apply(radius: 12, to: root))
        let applied = try #require(child.filters?.first as? NSObject)
        #expect((applied.value(forKey: "inputRadius") as? NSNumber)?.doubleValue == 12)
        // The same radius again keeps the existing filter, so Core Animation's render cache survives.
        #expect(!PrismGlassView.apply(radius: 12, to: root))
        #expect((child.filters?.first as? NSObject) === applied)
    }

    @Test func ignoresLayersWithoutBlurFilters() {
        let root = CALayer()
        root.addSublayer(CALayer())
        #expect(!PrismGlassView.apply(radius: 8, to: root))
    }
}
