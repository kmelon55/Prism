import AppKit
import Testing
@testable import PrismSystem

@MainActor private final class TestMixerSession: MixerSession {
    var isApplied = false
    var gains: [Float] = []
    var stopped = 0
    var fails = false
    func setGain(_ gain: Float) { gains.append(gain) }
    func poll() throws { if fails { throw UtilityError("test failure") } }
    func stop() { stopped += 1; isApplied = false }
}

@MainActor
struct AudioMixerTests {
    private let speakers = MixerOutput(id: "speakers", objectID: 1, name: "Speakers", sampleRate: 48000)
    private let headphones = MixerOutput(id: "headphones", objectID: 2, name: "Headphones", sampleRate: 48000)
    private var snapshot: MixerSnapshot {
        MixerSnapshot(apps: [.init(id: "music", name: "Music", processIDs: [30], isPlaying: true),
                             .init(id: "browser", name: "Browser", processIDs: [40, 41], isPlaying: true)],
                      outputs: [speakers, headphones], defaultOutputUID: "speakers")
    }

    @Test func browsingOrLoadingSavedRulesNeverStartsCapture() {
        let snapshot = snapshot
        let model = AudioMixerModel(initial: .init(rules: ["music": .init(volume: 0.5)]), read: { snapshot }, save: { _ in },
                                    makeSession: { _, _, _ in Issue.record("Unexpected capture"); return TestMixerSession() })
        model.appear(); model.disappear()
        #expect(!model.enabled)
        #expect(model.apps.count == 2)
        #expect(!model.hasSessions)
    }

    @Test func initialCaptureMustProveSignalBeforeReportingAppliedAndSlidersReuseIt() {
        let snapshot = snapshot, session = TestMixerSession()
        var starts = 0
        let model = AudioMixerModel(read: { snapshot }, save: { _ in }, makeSession: { app, output, gain in
            #expect(app.id == "music" && output.id == "speakers" && gain == 0.5)
            starts += 1; return session
        })
        defer { model.shutdown() }
        model.setEnabled(true)
        #expect(starts == 0) // Unity/default apps keep native playback.
        model.change("music") { $0.volume = 0.5 }
        #expect(model.applied.isEmpty)
        session.isApplied = true
        model.refresh()
        #expect(model.applied == ["music"])
        model.change("music") { $0.volume = 0.2 }
        model.change("music") { $0.muted = true }
        #expect(starts == 1)
        #expect(session.gains.last == 0)
        model.reset("music")
        #expect(session.stopped == 1)
        #expect(!model.hasSessions)
    }

    @Test func explicitRouteSurvivesDefaultChangesAndMissingOutputNeverFallsBack() {
        var snapshot = snapshot
        var routes: [String] = []
        let session = TestMixerSession()
        let model = AudioMixerModel(read: { snapshot }, save: { _ in }, makeSession: { _, output, _ in
            routes.append(output.id); return session
        })
        defer { model.shutdown() }
        model.setEnabled(true)
        model.change("music") { $0.outputUID = "headphones" }
        snapshot.defaultOutputUID = "headphones"
        model.refresh()
        #expect(routes == ["headphones"])
        snapshot.outputs = [speakers]
        snapshot.defaultOutputUID = "speakers"
        model.refresh(); model.refresh()
        #expect(session.stopped == 1)
        #expect(routes == ["headphones"])
        #expect(model.failures["music"] != nil)
        snapshot.outputs.append(headphones)
        model.retry("music")
        #expect(routes == ["headphones", "headphones"])
    }

    @Test func newHelperProcessesRebuildOnlyTheirOwnRouteAndAppExitStopsIt() {
        var snapshot = snapshot
        var sessions: [String: [TestMixerSession]] = [:]
        let model = AudioMixerModel(initial: .init(rules: ["music": .init(volume: 0.5), "browser": .init(volume: 0.7)]),
                                    read: { snapshot }, save: { _ in }, makeSession: { app, _, _ in
            let session = TestMixerSession(); sessions[app.id, default: []].append(session); return session
        })
        defer { model.shutdown() }
        model.setEnabled(true)
        snapshot.apps[1].processIDs.append(42)
        model.refresh()
        #expect(sessions["music"]?.count == 1)
        #expect(sessions["browser"]?.count == 2)
        #expect(sessions["browser"]?.first?.stopped == 1)
        snapshot.apps.removeAll { $0.id == "browser" }
        model.refresh()
        #expect(sessions["browser"]?.last?.stopped == 1)
    }

    @Test func failedSaveCannotChangeAppliedAudioAndFailedSetupWaitsForExplicitRetry() {
        let snapshot = snapshot
        var failSave = true, starts = 0
        let model = AudioMixerModel(read: { snapshot }, save: { _ in if failSave { throw UtilityError("disk full") } },
                                    makeSession: { _, _, _ in starts += 1; throw UtilityError("denied") })
        defer { model.shutdown() }
        model.setEnabled(true)
        model.change("music") { $0.volume = 0.5 }
        #expect(starts == 0 && model.rules.isEmpty)
        #expect(model.error != nil)
        failSave = false
        model.change("music") { $0.volume = 0.5 }
        model.refresh(); model.refresh()
        #expect(starts == 1 && model.failures["music"] != nil)
        model.retry("music")
        #expect(starts == 2)
    }

    @Test func suspensionAndDisablingReleaseRoutesAndRestartDoesNotAutoEnable() throws {
        let snapshot = snapshot
        var saved = MixerPreferences(), sessions: [TestMixerSession] = []
        let model = AudioMixerModel(read: { snapshot }, save: { saved = $0 }, makeSession: { _, _, _ in
            let session = TestMixerSession(); sessions.append(session); return session
        })
        model.setEnabled(true)
        model.change("music") { $0.volume = 0.4; $0.outputUID = "headphones" }
        model.suspend()
        #expect(sessions[0].stopped == 1 && model.enabled)
        model.resume()
        #expect(sessions.count == 2)
        model.setEnabled(false)
        #expect(sessions[1].stopped == 1)
        model.shutdown()
        let restored = try JSONDecoder().decode(MixerPreferences.self, from: JSONEncoder().encode(saved))
        #expect(restored.rules["music"]?.volume == 0.4 && restored.rules["music"]?.outputUID == "headphones")
        #expect(restored.isValid)
    }

    @Test func inventoryAndStreamFailuresReleaseAudioInsteadOfClaimingSuccess() {
        let snapshot = snapshot, session = TestMixerSession()
        var fails = false
        let model = AudioMixerModel(initial: .init(rules: ["music": .init(volume: 0.5)]), read: {
            if fails { throw UtilityError("hardware unavailable") }; return snapshot
        }, save: { _ in }, makeSession: { _, _, _ in session })
        model.setEnabled(true)
        session.fails = true
        model.refresh()
        #expect(session.stopped == 1 && model.applied.isEmpty)
        #expect(model.failures["music"] != nil)
        fails = true
        model.refresh()
        #expect(!model.enabled)
        model.shutdown()
    }

    @Test func nestedHelpersResolveToTheOwningApplication() {
        let url = URL(fileURLWithPath: "/Applications/Example.app/Contents/Frameworks/Example Helper.app")
        #expect(MixerHAL.owningApp(url)?.path == "/Applications/Example.app")
        #expect(MixerHAL.owningApp(URL(fileURLWithPath: "/usr/bin/afplay")) == nil)
        #expect(!MixerRule(volume: .nan).isValid)
        #expect(!MixerRule(volume: 1.1).isValid)
        #expect(!MixerPreferences(version: 99).isValid)
    }
}
