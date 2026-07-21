import XCTest
import Foundation
import WhoopProtocol
@testable import Strand

/// Pins the durable manual-workout codec (#529): the persist -> rehydrate round-trip that lets a
/// manually-started session survive iOS killing the app mid-session so it can still be ended and saved.
/// Pure + `UserDefaults`-backed, mirroring the Android `ActiveWorkoutPersistenceTest` case for case.
final class ActiveWorkoutPersistenceTests: XCTestCase {

    private func sample(_ ts: Int, _ bpm: Int) -> HRSample { HRSample(ts: ts, bpm: bpm) }

    private func snapshot(
        startSec: Int = 1_700_000_000,
        sport: String = "Tennis",
        samples: [HRSample] = [HRSample(ts: 1_700_000_001, bpm: 120), HRSample(ts: 1_700_000_061, bpm: 145)],
        avgHr: Int = 133,
        peakHr: Int = 145,
        liveStrain: Double = 8.4
    ) -> ActiveWorkoutPersistence.Snapshot {
        ActiveWorkoutPersistence.Snapshot(startSec: startSec, sport: sport, samples: samples,
                                          avgHr: avgHr, peakHr: peakHr, liveStrain: liveStrain)
    }

    /// A throwaway, isolated defaults suite so the test never touches the real store.
    private func freshDefaults() -> UserDefaults {
        let name = "test.activeWorkout.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: - pure codec round-trip

    func testEncodeDecodeRoundTripsEveryField() {
        let original = snapshot()
        let decoded = ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testRoundTripWithNoSamples() {
        // A session that started but hasn't captured a sample yet (strap not streaming) must still
        // persist + rehydrate — otherwise a kill right after Start loses the start time.
        let decoded = ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(samples: [], avgHr: 0, peakHr: 0, liveStrain: 0)))
        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded!.samples.isEmpty)
        XCTAssertEqual(decoded!.startSec, 1_700_000_000)
        XCTAssertEqual(decoded!.sport, "Tennis")
    }

    func testRoundTripSportNameWithSpacesPreserved() {
        let decoded = ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(sport: "Traditional Strength Training")))
        XCTAssertEqual(decoded!.sport, "Traditional Strength Training")
    }

    // MARK: - UserDefaults store / load / clear

    func testStoreLoadClearRoundTrip() {
        let defaults = freshDefaults()
        XCTAssertNil(ActiveWorkoutPersistence.load(from: defaults))   // nothing yet
        let snap = snapshot()
        ActiveWorkoutPersistence.store(snap, into: defaults)
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults), snap)
        // Ending the session clears it — a relaunch then rehydrates nothing.
        ActiveWorkoutPersistence.clear(from: defaults)
        XCTAssertNil(ActiveWorkoutPersistence.load(from: defaults))
    }

    func testStoreOverwritesPreviousSnapshot() {
        // Each captured sample re-stores; the latest write wins (mirrors the per-sample persist).
        let defaults = freshDefaults()
        ActiveWorkoutPersistence.store(snapshot(samples: [sample(1_700_000_001, 120)], avgHr: 120, peakHr: 120),
                                       into: defaults)
        let later = snapshot(samples: [sample(1_700_000_001, 120), sample(1_700_000_061, 150)],
                             avgHr: 135, peakHr: 150, liveStrain: 9.1)
        ActiveWorkoutPersistence.store(later, into: defaults)
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults), later)
    }

    // MARK: - honest failure (no revived bogus card)

    func testDecodeNilOrEmptyIsNil() {
        XCTAssertNil(ActiveWorkoutPersistence.decode(nil))
        XCTAssertNil(ActiveWorkoutPersistence.decode(Data()))
    }

    func testDecodeGarbageIsNil() {
        XCTAssertNil(ActiveWorkoutPersistence.decode(Data("not json".utf8)))
        XCTAssertNil(ActiveWorkoutPersistence.decode(Data("{\"unexpected\":1}".utf8)))
    }

    func testDecodeRejectsNonPositiveStart() {
        let bad = snapshot(startSec: 0)
        XCTAssertNil(ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(bad)))
    }

    // MARK: - bound-checked untrusted samples

    func testDecodeDropsOutOfRangeSamples() {
        // A corrupt blob with a bpm=0, bpm=400, and ts<=0 sample — only the in-range one survives.
        let dirty = snapshot(samples: [
            sample(1_700_000_001, 150),   // good
            sample(1_700_000_002, 0),     // bpm 0 — rejected
            sample(1_700_000_003, 400),   // bpm out of range — rejected
            sample(0, 120),               // ts <= 0 — rejected
        ])
        let decoded = ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(dirty))
        XCTAssertEqual(decoded?.samples, [sample(1_700_000_001, 150)])
    }

    func testDecodeClampsNegativeDerivedStats() {
        let dirty = snapshot(samples: [], avgHr: -5, peakHr: -9, liveStrain: -3)
        let decoded = ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(dirty))
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded!.avgHr, 0)
        XCTAssertEqual(decoded!.peakHr, 0)
        XCTAssertEqual(decoded!.liveStrain, 0, accuracy: 1e-9)
    }

    // MARK: - pause fields (relaunch-while-paused durability)

    func testPauseFieldsRoundTrip() {
        var s = snapshot()
        s.pausedAccumulatedSec = 42.5
        s.pauseStartedSec = 1_700_000_300
        let decoded = ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(s))
        XCTAssertEqual(decoded?.pausedAccumulatedSec, 42.5)
        XCTAssertEqual(decoded?.pauseStartedSec, 1_700_000_300)
    }

    /// A snapshot written before pause shipped has no pause keys; it must still decode (nil pause fields =
    /// "was never paused"), never fail the whole rehydrate.
    func testLegacySnapshotWithoutPauseKeysDecodes() {
        let legacy = #"{"startSec":1700000000,"sport":"Tennis","samples":[],"avgHr":0,"peakHr":0,"liveStrain":0}"#
        let decoded = ActiveWorkoutPersistence.decode(Data(legacy.utf8))
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.pausedAccumulatedSec)
        XCTAssertNil(decoded?.pauseStartedSec)
    }

    /// A corrupt pause accumulator / non-positive pause-start is sanitised so it can't freeze a rehydrated
    /// session forever.
    func testDecodeSanitisesCorruptPauseFields() {
        var s = snapshot()
        s.pausedAccumulatedSec = -10
        s.pauseStartedSec = 0
        let decoded = ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(s))
        XCTAssertNil(decoded?.pausedAccumulatedSec)   // negative → dropped (0 active-time offset)
        XCTAssertNil(decoded?.pauseStartedSec)        // non-positive → "was running"
    }

    // MARK: - ActiveWorkout.activeElapsed (moving time)

    func testActiveElapsedRunningIsWallClock() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let w = AppModel.ActiveWorkout(start: start, sport: "Running")
        XCTAssertEqual(w.activeElapsed(now: start.addingTimeInterval(600)), 600, accuracy: 1e-6)
    }

    func testActiveElapsedFreezesWhilePaused() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var w = AppModel.ActiveWorkout(start: start, sport: "Running")
        // Paused 300s in; the clock must read 300 no matter how much wall-clock passes during the pause.
        w.pauseStartedAt = start.addingTimeInterval(300)
        XCTAssertEqual(w.activeElapsed(now: start.addingTimeInterval(300)), 300, accuracy: 1e-6)
        XCTAssertEqual(w.activeElapsed(now: start.addingTimeInterval(900)), 300, accuracy: 1e-6)
    }

    func testActiveElapsedSubtractsCompletedPauses() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var w = AppModel.ActiveWorkout(start: start, sport: "Running")
        w.pausedAccumulated = 120   // resumed after a 2-min stop
        // 900s wall-clock, minus 120s paused = 780s moving.
        XCTAssertEqual(w.activeElapsed(now: start.addingTimeInterval(900)), 780, accuracy: 1e-6)
    }

    func testActiveElapsedNeverNegative() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var w = AppModel.ActiveWorkout(start: start, sport: "Running")
        w.pausedAccumulated = 10_000   // absurd, but must clamp not go negative
        XCTAssertEqual(w.activeElapsed(now: start.addingTimeInterval(60)), 0, accuracy: 1e-6)
    }
}
