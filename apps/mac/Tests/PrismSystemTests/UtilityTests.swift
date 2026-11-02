import Foundation
import Testing
@testable import PrismSystem

@MainActor
struct KeepAwakeTests {
    @Test func expiresOnceAndExtensionReusesTheAssertion() {
        var acquired = 0, released = 0
        let model = KeepAwakeModel(acquire: { acquired += 1 }, release: { released += 1 })
        let now = Date()
        #expect(!model.isActive)
        model.start(minutes: 25, now: now)
        model.start(minutes: 60, now: now)
        #expect(acquired == 1)
        model.refresh(now: now + 1500)
        #expect(model.isActive)
        model.refresh(now: now + 3600)
        model.refresh(now: now + 7200)
        #expect(!model.isActive)
        #expect(released == 1)
    }

    @Test func failedAcquisitionAndReleaseNeverReportFalseSuccess() {
        let unavailable = KeepAwakeModel(acquire: { throw UtilityError("denied") }, release: {})
        #expect(!unavailable.start(minutes: 25))
        #expect(!unavailable.isActive)
        #expect(unavailable.error != nil)
        var failRelease = true
        let model = KeepAwakeModel(acquire: {}, release: { if failRelease { throw UtilityError("denied") } })
        model.start(minutes: 25)
        #expect(!model.stop())
        #expect(model.isActive)
        failRelease = false
        #expect(model.stop())
        #expect(!model.isActive)
    }

    @Test func shutdownReleasesAndNewInstanceStartsOff() {
        var releases = 0
        let model = KeepAwakeModel(acquire: {}, release: { releases += 1 })
        model.start(minutes: 25)
        model.observeLifecycle()
        model.shutdown()
        #expect(releases == 1)
        #expect(!model.isActive)
        #expect(!KeepAwakeModel(acquire: {}, release: {}).isActive)
    }
}

@MainActor
struct AudioOutputTests {
    private let speakers = AudioOutputDevice(id: 1, name: "Speakers")
    private let headphones = AudioOutputDevice(id: 2, name: "Headphones")

    @Test func switchingReadsBackAndDisconnectedDeviceNeverReachesWrite() {
        var snapshot = AudioOutputSnapshot(devices: [speakers, headphones], selectedID: 1)
        var writes: [UInt32] = []
        let model = AudioOutputModel(read: { snapshot }, select: { writes.append($0); snapshot.selectedID = $0 }, observe: { _ in {} })
        model.refresh()
        model.choose(2)
        #expect(model.selectedID == 2)
        #expect(model.error == nil)
        snapshot = AudioOutputSnapshot(devices: [speakers], selectedID: 1)
        model.choose(2)
        #expect(writes == [2])
        #expect(model.selectedID == 1)
        #expect(model.devices == [speakers])
        #expect(model.error != nil)
    }

    @Test func noOpWriteAndFailedWriteDoNotClaimTheRequestedOutput() {
        let snapshot = AudioOutputSnapshot(devices: [speakers, headphones], selectedID: 1)
        for fail in [false, true] {
            let model = AudioOutputModel(read: { snapshot }, select: { _ in if fail { throw UtilityError("denied") } }, observe: { _ in {} })
            model.choose(2)
            #expect(model.selectedID == 1)
            #expect(model.error != nil)
        }
    }

    @Test func failedReadClearsStaleChoices() {
        var fails = false
        let snapshot = AudioOutputSnapshot(devices: [speakers], selectedID: 1)
        let model = AudioOutputModel(read: {
            if fails { throw UtilityError("unavailable") }
            return snapshot
        }, select: { _ in Issue.record("Read failure must not write") }, observe: { _ in {} })
        model.refresh()
        fails = true
        model.choose(1)
        #expect(model.devices.isEmpty)
        #expect(model.selectedID == nil)
        #expect(model.error != nil)
    }

    @Test func multipleVisibleSurfacesShareListenersAndReleaseAfterLastClose() {
        var subscriptions = 0, cancellations = 0
        var changed: (@MainActor () -> Void)?
        var snapshot = AudioOutputSnapshot(devices: [speakers, headphones], selectedID: 1)
        let model = AudioOutputModel(read: { snapshot }, select: { _ in }, observe: { callback in
            subscriptions += 1; changed = callback
            return { cancellations += 1 }
        })
        model.appear(); model.appear()
        #expect(subscriptions == 1)
        snapshot.selectedID = 2
        changed?()
        #expect(model.selectedID == 2)
        model.disappear()
        #expect(cancellations == 0)
        model.disappear()
        #expect(cancellations == 1)
    }

    @Test func utilitiesAreAvailableInSearchAndNotchWithoutStartingThem() async {
        let awake = KeepAwakeModel(acquire: { Issue.record("Browsing must not acquire power assertion") }, release: {})
        let audio = AudioOutputModel(read: { .init(devices: [], selectedID: nil) },
                                     select: { _ in Issue.record("Browsing must not change output") }, observe: { _ in {} })
        let rows = await UtilitiesProvider(awake: awake, audio: audio).results(for: "")
        #expect(Set(rows.map(\.id)) == ["utilities:keep-awake", "utilities:audio-output", "utilities:keep-awake-stop"])
        let widgets = SystemFeature.utilityWidgets(awake: awake, audio: audio)
        #expect(widgets.map(\.id) == ["keep-awake", "audio-output"])
        #expect(widgets.allSatisfy { $0.activity() == nil })
    }
}
