import CoreGraphics
import Foundation
import Testing
@testable import PrismSystem

/// A window that accepts writes like a well-behaved app, optionally with a minimum size or a refusal.
@MainActor
final class FakeWindow: ManagedWindow {
    let identity: WindowIdentity
    var bounds: CGRect
    var minimumSize = CGSize.zero
    /// The next N size writes fail, like an app that rejects a geometry once.
    var failingSizeWrites = 0

    init(_ bounds: CGRect, id: UInt = 1) {
        self.bounds = bounds
        identity = WindowIdentity(pid: 7, element: id)
    }

    func frame() throws -> CGRect { bounds }

    func setSize(_ size: CGSize) throws {
        if failingSizeWrites > 0 {
            failingSizeWrites -= 1
            throw WindowActionError.make(.refused)
        }
        bounds.size = CGSize(width: max(size.width, minimumSize.width), height: max(size.height, minimumSize.height))
    }

    func setPosition(_ point: CGPoint) throws {
        bounds.origin = point
    }
}

@MainActor
struct WindowManagerTests {
    let main = CGRect(x: 0, y: 25, width: 1200, height: 875)
    let side = CGRect(x: 1200, y: 0, width: 800, height: 600)

    func manager(_ options: WindowOptions = WindowOptions(), areas: [CGRect]? = nil) -> WindowManager {
        let areas = areas ?? [main]
        return WindowManager(options: { options }, workAreas: { areas })
    }

    @Test func repeatedLeftHalfCyclesThroughSizes() throws {
        let manager = manager()
        let window = FakeWindow(CGRect(x: 300, y: 200, width: 500, height: 400))
        var widths: [CGFloat] = []
        for _ in 0..<4 { widths.append(try manager.apply(.leftHalf, to: window).width) }
        #expect(widths == [600, 400, 800, 600])
        #expect(window.bounds.minX == 0 && window.bounds.minY == 25 && window.bounds.height == 875)
    }

    @Test func cyclingCanBeTurnedOff() throws {
        let manager = manager(WindowOptions(cycle: false))
        let window = FakeWindow(CGRect(x: 300, y: 200, width: 500, height: 400))
        try manager.apply(.leftHalf, to: window)
        try manager.apply(.leftHalf, to: window)
        #expect(window.bounds.width == 600)
    }

    @Test func restoreReturnsToTheFrameBeforeTheFirstPrismLayoutOnce() throws {
        let manager = manager()
        let original = CGRect(x: 300, y: 200, width: 500, height: 400)
        let window = FakeWindow(original)
        try manager.apply(.leftHalf, to: window)
        try manager.apply(.leftHalf, to: window)
        try manager.apply(.maximize, to: window)
        // Continuing a cycle keeps the first checkpoint; Maximize records the cycled frame.
        try manager.apply(.restorePreviousLayout, to: window)
        #expect(window.bounds == CGRect(x: 0, y: 25, width: 400, height: 875))
        #expect(throws: WindowActionError.make(.noPreviousLayout)) { try manager.apply(.restorePreviousLayout, to: window) }
    }

    @Test func restoreIsPerWindow() throws {
        let manager = manager()
        let first = FakeWindow(CGRect(x: 100, y: 100, width: 300, height: 300), id: 1)
        let second = FakeWindow(CGRect(x: 200, y: 200, width: 300, height: 300), id: 2)
        try manager.apply(.maximize, to: first)
        #expect(throws: WindowActionError.make(.noPreviousLayout)) { try manager.apply(.restorePreviousLayout, to: second) }
        try manager.apply(.restorePreviousLayout, to: first)
        #expect(first.bounds == CGRect(x: 100, y: 100, width: 300, height: 300))
    }

    @Test func nextDisplayNeedsASecondDisplayAndWrapsAround() throws {
        let single = manager()
        let window = FakeWindow(CGRect(x: 100, y: 100, width: 400, height: 300))
        #expect(throws: WindowActionError.make(.noOtherDisplay)) { try single.apply(.nextDisplay, to: window) }

        let dual = manager(areas: [side, main])
        try dual.apply(.nextDisplay, to: window)
        #expect(side.contains(window.bounds))
        try dual.apply(.nextDisplay, to: window)
        #expect(main.contains(window.bounds))
        try dual.apply(.previousDisplay, to: window)
        #expect(side.contains(window.bounds))
    }

    @Test func layoutsUseTheDisplayHoldingMostOfTheWindow() throws {
        let manager = manager(areas: [main, side])
        let window = FakeWindow(CGRect(x: 1500, y: 100, width: 400, height: 300))
        try manager.apply(.leftHalf, to: window)
        #expect(window.bounds == CGRect(x: 1200, y: 0, width: 400, height: 600))
    }

    @Test func refusedWritesRestoreGeometryAndHistory() throws {
        let manager = manager()
        let window = FakeWindow(CGRect(x: 100, y: 100, width: 300, height: 300))
        try manager.apply(.maximize, to: window)
        window.failingSizeWrites = 1
        #expect(throws: WindowActionError.make(.refused)) { try manager.apply(.leftHalf, to: window) }
        try manager.apply(.restorePreviousLayout, to: window)
        #expect(window.bounds == CGRect(x: 100, y: 100, width: 300, height: 300))
    }

    @Test func aResizeFailureAfterAMoveRestoresThePosition() {
        let manager = manager()
        let original = CGRect(x: 600, y: 300, width: 300, height: 300)
        let window = FakeWindow(original)
        window.failingSizeWrites = 1
        #expect(throws: WindowActionError.make(.refused)) { try manager.apply(.leftHalf, to: window) }
        #expect(window.bounds == original)
        #expect(throws: WindowActionError.make(.noPreviousLayout)) { try manager.apply(.restorePreviousLayout, to: window) }
    }

    @Test func unchangedFramesReportThatTheAppDidNotAcceptTheLayout() {
        let manager = manager()
        let window = FakeWindow(CGRect(x: 100, y: 100, width: 300, height: 300))
        window.minimumSize = CGSize(width: 1300, height: 1000)
        window.bounds = CGRect(x: 0, y: 25, width: 1300, height: 1000)
        #expect(throws: WindowActionError.make(.notAccepted)) { try manager.apply(.leftHalf, to: window) }
    }

    @Test func minimumSizesStillApply() throws {
        let manager = manager()
        let window = FakeWindow(CGRect(x: 100, y: 100, width: 300, height: 300))
        window.minimumSize = CGSize(width: 700, height: 0)
        let actual = try manager.apply(.leftHalf, to: window)
        #expect(actual.width == 700)
        #expect(actual.minX == 0)
    }

    @Test func gapsFromOptionsAreApplied() throws {
        let manager = manager(WindowOptions(gap: 10, edgeGap: 8))
        let window = FakeWindow(CGRect(x: 100, y: 100, width: 300, height: 300))
        try manager.apply(.rightHalf, to: window)
        #expect(window.bounds == CGRect(x: 605, y: 33, width: 587, height: 859))
    }
}

struct WindowOptionsStoreTests {
    func temporaryStore() throws -> (WindowOptionsStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "prism-window-options-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (WindowOptionsStore(url: directory.appending(path: WindowOptionsStore.fileName)), directory)
    }

    @Test func missingFileMeansDefaults() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try store.load() == WindowOptions())
        #expect(WindowOptions().cycle && !WindowOptions().reverseCycle && WindowOptions().almostMaximize == 90)
    }

    @Test func rejectInvalidOptionsAndPreserveMalformedData() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: WindowOptionsError.invalid) { try store.save(WindowOptions(gap: 65)) }
        #expect(throws: WindowOptionsError.invalid) { try store.save(WindowOptions(almostMaximize: 49)) }
        try Data("broken".utf8).write(to: store.url)
        #expect(throws: WindowOptionsError.invalidSaved) { try store.load() }
        #expect(throws: WindowOptionsError.invalidSaved) { try store.save(WindowOptions()) }
        #expect(try Data(contentsOf: store.url) == Data("broken".utf8))
        #expect(store.loadOrDefault() == WindowOptions())
        try store.reset()
        #expect(try store.load() == WindowOptions())
    }

    @Test func readsAndWritesTheTauriFormat() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"cycle":false,"reverseCycle":true,"gap":8,"edgeGap":4,"almostMaximize":85}"#.utf8).write(to: store.url)
        #expect(try store.load() == WindowOptions(cycle: false, reverseCycle: true, gap: 8, edgeGap: 4, almostMaximize: 85))
        try store.save(WindowOptions(gap: 12))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any]
        #expect(Set(object?.keys ?? [:].keys) == ["cycle", "reverseCycle", "gap", "edgeGap", "almostMaximize"])
        #expect(object?["gap"] as? Int == 12)
    }

    @Test func outOfRangeSavedValuesAreRejected() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"cycle":true,"reverseCycle":false,"gap":100,"edgeGap":0,"almostMaximize":90}"#.utf8).write(to: store.url)
        #expect(throws: WindowOptionsError.invalid) { try store.load() }
        try Data(#"{"cycle":true}"#.utf8).write(to: store.url)
        #expect(throws: WindowOptionsError.invalidSaved) { try store.load() }
    }

    @Test func oversizedFilesAreNotRead() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 0x20, count: 5000).write(to: store.url)
        #expect(throws: WindowOptionsError.unreadable) { try store.load() }
    }
}
