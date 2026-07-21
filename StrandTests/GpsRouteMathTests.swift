import XCTest
import Foundation
import CloudKit
import WhoopProtocol
import WhoopStore
@testable import Strand

/// Pins the Apple GPS workout recorder's pure pieces (#524): distance accumulation, the precision-5
/// polyline codec (which must round-trip AND match Android `RouteMath` byte-for-byte so a route is
/// cross-platform), the untrusted-fix `TrackFilter` gate, and the on-device `RouteStore` round-trip.
/// All pure / UserDefaults-backed — no CoreLocation — so they run headless, mirroring the Android
/// `RouteMathTest` case for case.
final class GpsRouteMathTests: XCTestCase {

    // Two points ~451 m apart near the Thames (the SAME fixtures Android `RouteMathTest` uses).
    private let a = RouteMath.LatLng(51.5033, -0.1196)
    private let b = RouteMath.LatLng(51.5007, -0.1246)

    // MARK: - Distance + pace (Android parity)

    func testHaversineKnownDistance() {
        XCTAssertEqual(RouteMath.haversineMeters(a, b), 451.0, accuracy: 20.0)
    }

    func testTotalDistanceSumsSegments() {
        let total = RouteMath.totalMeters([a, b, a])
        XCTAssertEqual(total, RouteMath.haversineMeters(a, b) * 2, accuracy: 1.0)
    }

    func testTotalDistanceEmptyOrSingleIsZero() {
        XCTAssertEqual(RouteMath.totalMeters([]), 0.0, accuracy: 0.0)
        XCTAssertEqual(RouteMath.totalMeters([a]), 0.0, accuracy: 0.0)
    }

    /// Distance accumulation as the recorder folds in fixes: a 4-point track's total equals the sum of
    /// its consecutive legs (the exact thing `GpsWorkoutRecorder.ingest` recomputes per batch).
    func testDistanceAccumulatesAcrossGrowingTrack() {
        let c = RouteMath.LatLng(51.4995, -0.1357)
        let d = RouteMath.LatLng(51.4980, -0.1400)
        var track: [RouteMath.LatLng] = []
        var running = 0.0
        for p in [a, b, c, d] {
            if let prev = track.last { running += RouteMath.haversineMeters(prev, p) }
            track.append(p)
            // The running sum kept incrementally must always equal a fresh full recompute.
            XCTAssertEqual(RouteMath.totalMeters(track), running, accuracy: 1e-6)
        }
        XCTAssertGreaterThan(running, 0)
    }

    func testPaceSecPerKm() {
        XCTAssertEqual(RouteMath.paceSecPerKm(meters: 1000, seconds: 300)!, 300.0, accuracy: 0.001)
        XCTAssertNil(RouteMath.paceSecPerKm(meters: 0, seconds: 300))
    }

    // MARK: - Polyline codec (round-trip + cross-platform golden)

    func testPolylineRoundTrips() {
        let pts = [a, b, RouteMath.LatLng(51.4995, -0.1357)]
        let decoded = RouteMath.decode(RouteMath.encode(pts))
        XCTAssertEqual(decoded.count, pts.count)
        for i in pts.indices {
            XCTAssertEqual(decoded[i].lat, pts[i].lat, accuracy: 1e-5)
            XCTAssertEqual(decoded[i].lon, pts[i].lon, accuracy: 1e-5)
        }
    }

    func testEncodeEmptyIsEmptyString() {
        XCTAssertTrue(RouteMath.encode([]).isEmpty)
        XCTAssertTrue(RouteMath.decode("").isEmpty)
    }

    /// The canonical Google "Encoded Polyline Algorithm Format" reference example. Our encoder MUST
    /// produce this EXACT string — it's the contract that the Android encoder (same algorithm) and any
    /// external decoder agree on, so a route stored on one platform reads on the other.
    func testPolylineMatchesGoogleReferenceGolden() {
        let pts = [
            RouteMath.LatLng(38.5, -120.2),
            RouteMath.LatLng(40.7, -120.95),
            RouteMath.LatLng(43.252, -126.453),
        ]
        XCTAssertEqual(RouteMath.encode(pts), "_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        let back = RouteMath.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        XCTAssertEqual(back.count, 3)
        XCTAssertEqual(back[0].lat, 38.5, accuracy: 1e-5)
        XCTAssertEqual(back[2].lon, -126.453, accuracy: 1e-5)
    }

    /// A truncated / corrupt polyline must decode to whatever it can parse and stop cleanly — never crash
    /// or read past the buffer (the string is read back from disk, so it's untrusted).
    func testDecodeTruncatedStopsCleanly() {
        let good = RouteMath.encode([a, b])
        let truncated = String(good.dropLast())
        // Doesn't crash; yields at most the points it could fully parse.
        let decoded = RouteMath.decode(truncated)
        XCTAssertLessThanOrEqual(decoded.count, 2)
    }

    func testDecodeGarbageDoesNotCrash() {
        _ = RouteMath.decode("not-a-polyline-!!!")
        _ = RouteMath.decode("\u{0}\u{1}\u{2}")
    }

    // MARK: - TrackFilter (untrusted-fix gate; Android parity)

    private func fix(_ lat: Double, _ lon: Double, acc: Double, t: Int64) -> RawFix {
        RawFix(lat: lat, lon: lon, accuracyM: acc, tMs: t)
    }

    func testFilterDropsLowAccuracyFixes() {
        let f = TrackFilter()
        XCTAssertNil(f.accept(fix(51.50, -0.12, acc: 80, t: 0)))   // > 50 m gate
        XCTAssertNotNil(f.accept(fix(51.50, -0.12, acc: 10, t: 0))) // good
    }

    func testFilterDropsInvalidNegativeAccuracy() {
        // CoreLocation reports a negative horizontalAccuracy for an invalid fix — must be rejected.
        XCTAssertNil(TrackFilter().accept(fix(51.50, -0.12, acc: -1, t: 0)))
    }

    func testFilterDropsTeleportJumps() {
        let f = TrackFilter()
        XCTAssertNotNil(f.accept(fix(51.5000, -0.1200, acc: 5, t: 0)))
        // ~450 m in 1 s = 450 m/s — far above the ~12 m/s gate, so it's a GPS jump and is rejected.
        XCTAssertNil(f.accept(fix(51.5007, -0.1246, acc: 5, t: 1000)))
        // The same move over 60 s (~7.5 m/s) is a believable run pace and is accepted.
        XCTAssertNotNil(f.accept(fix(51.5007, -0.1246, acc: 5, t: 60_000)))
    }

    func testFilterRejectsOutOfRangeCoordinates() {
        XCTAssertNil(TrackFilter().accept(fix(120, 0, acc: 5, t: 0)))      // lat > 90
        XCTAssertNil(TrackFilter().accept(fix(0, 200, acc: 5, t: 0)))      // lon > 180
    }

    // MARK: - RouteStore (on-device side-store round-trip)

    private func freshDefaults() -> UserDefaults {
        let name = "test.workoutRoutes.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testRouteStoreRoundTrip() {
        let defaults = freshDefaults()
        XCTAssertNil(RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults))
        let route = WorkoutRoute(polyline: RouteMath.encode([a, b]),
                                 distanceM: RouteMath.totalMeters([a, b]))
        RouteStore.store(route, startTs: 1_700_000_000, sport: "Running", into: defaults)
        XCTAssertEqual(RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults), route)
        // Removing it leaves no orphan.
        RouteStore.remove(startTs: 1_700_000_000, sport: "Running", from: defaults)
        XCTAssertNil(RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults))
    }

    func testRouteStoreKeysBySportAndStart() {
        let defaults = freshDefaults()
        let run = WorkoutRoute(polyline: RouteMath.encode([a, b]), distanceM: 1)
        let walk = WorkoutRoute(polyline: RouteMath.encode([b, a]), distanceM: 2)
        // Same start second, different sport — must NOT collide.
        RouteStore.store(run, startTs: 1_700_000_000, sport: "Running", into: defaults)
        RouteStore.store(walk, startTs: 1_700_000_000, sport: "Walking", into: defaults)
        XCTAssertEqual(RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults), run)
        XCTAssertEqual(RouteStore.load(startTs: 1_700_000_000, sport: "Walking", from: defaults), walk)
    }

    func testRouteStoreRejectsEmptyPolyline() {
        let defaults = freshDefaults()
        // An honest "no route" must never be stored as an empty placeholder.
        RouteStore.store(WorkoutRoute(polyline: "", distanceM: 0),
                         startTs: 1_700_000_000, sport: "Running", into: defaults)
        XCTAssertNil(RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults))
    }

    func testRouteStoreDropsNonFiniteDistanceOnDecode() {
        // A corrupt blob with a non-finite distance is dropped on read — never trust the persisted value.
        let dirty: [String: WorkoutRoute] = [
            RouteStore.key(startTs: 1, sport: "Running"): WorkoutRoute(polyline: "abc", distanceM: .nan),
            RouteStore.key(startTs: 2, sport: "Cycling"): WorkoutRoute(polyline: "def", distanceM: 1234),
        ]
        let data = RouteStore.encodeMap(dirty)
        let decoded = RouteStore.decodeMap(data)
        XCTAssertNil(decoded[RouteStore.key(startTs: 1, sport: "Running")])
        XCTAssertNotNil(decoded[RouteStore.key(startTs: 2, sport: "Cycling")])
    }

    func testRouteStoreEvictsOldestPastCap() {
        let defaults = freshDefaults()
        // Store cap + 5 routes; the oldest 5 (lowest startTs) must be evicted, newest kept.
        let total = RouteStore.maxRoutes + 5
        for i in 0..<total {
            RouteStore.store(WorkoutRoute(polyline: "abc", distanceM: Double(i)),
                             startTs: 1_000_000 + i, sport: "Running", into: defaults)
        }
        let map = RouteStore.loadMap(from: defaults)
        XCTAssertEqual(map.count, RouteStore.maxRoutes)
        // The 5 oldest are gone; a recent one survives.
        XCTAssertNil(map[RouteStore.key(startTs: 1_000_000, sport: "Running")])
        XCTAssertNotNil(map[RouteStore.key(startTs: 1_000_000 + total - 1, sport: "Running")])
    }

    // MARK: - Re-key on edit (#10)

    /// #10: editing a GPS workout's sport or start re-keys its DB row, so its route must move to the new
    /// natural key too or the detail view loses the route + distance. This pins the exact re-key sequence
    /// Repository.saveManualWorkout runs in the changed-key branch (load old, store new, remove old): the
    /// route ends up under the NEW key only, byte-identical, with no orphan left behind.
    func testRouteStoreReKeyOnNaturalKeyChangePreservesRoute() {
        let defaults = freshDefaults()
        let route = WorkoutRoute(polyline: RouteMath.encode([a, b]),
                                 distanceM: RouteMath.totalMeters([a, b]))
        // The original session's route, keyed by its old (startTs, sport).
        RouteStore.store(route, startTs: 1_700_000_000, sport: "Running", into: defaults)

        // Re-key to a new sport AND a new start, exactly as the save path does on an edit.
        if let old = RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults) {
            RouteStore.store(old, startTs: 1_700_000_500, sport: "Walking", into: defaults)
            RouteStore.remove(startTs: 1_700_000_000, sport: "Running", from: defaults)
        }

        // Route lives under the NEW key, unchanged; the OLD key is clear (no orphan, no distance ghost).
        XCTAssertEqual(RouteStore.load(startTs: 1_700_000_500, sport: "Walking", from: defaults), route)
        XCTAssertNil(RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults))
        XCTAssertEqual(RouteStore.loadMap(from: defaults).count, 1)
    }

    /// #10 guard: a workout with NO recorded route stays a clean no-op on edit. The load returns nil, so
    /// the save path's `if let` never stores or removes anything, and the side-store stays empty.
    func testRouteStoreReKeyNoRouteIsNoOp() {
        let defaults = freshDefaults()
        if let old = RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults) {
            RouteStore.store(old, startTs: 1_700_000_500, sport: "Walking", into: defaults)
            RouteStore.remove(startTs: 1_700_000_000, sport: "Running", from: defaults)
        }
        XCTAssertNil(RouteStore.load(startTs: 1_700_000_500, sport: "Walking", from: defaults))
        XCTAssertTrue(RouteStore.loadMap(from: defaults).isEmpty)
    }

    // MARK: - TrackTimeStore (per-point times round-trip)

    func testTrackTimeStoreRoundTripAndCap() {
        let defaults = freshDefaults()
        XCTAssertNil(TrackTimeStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults))
        TrackTimeStore.store([100, 110, 125], startTs: 1_700_000_000, sport: "Running", into: defaults)
        XCTAssertEqual(TrackTimeStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults), [100, 110, 125])
        // Fewer than two points is not storable (no timing to split on).
        TrackTimeStore.store([1], startTs: 42, sport: "Running", into: defaults)
        XCTAssertNil(TrackTimeStore.load(startTs: 42, sport: "Running", from: defaults))
        // Removal leaves no orphan.
        TrackTimeStore.remove(startTs: 1_700_000_000, sport: "Running", from: defaults)
        XCTAssertNil(TrackTimeStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults))
    }

    // MARK: - HRTrackStore (synced per-run HR track round-trip)

    func testHRTrackStoreRoundTripAndKeying() {
        let defaults = freshDefaults()
        XCTAssertNil(HRTrackStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults))
        let track = [HRSample(ts: 1_700_000_000, bpm: 120),
                     HRSample(ts: 1_700_000_006, bpm: 132),
                     HRSample(ts: 1_700_000_012, bpm: 145)]
        HRTrackStore.store(track, startTs: 1_700_000_000, sport: "Running", into: defaults)
        XCTAssertEqual(HRTrackStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults), track)
        // Same start second, different sport — must NOT collide (matches RouteStore's keying).
        let cyc = [HRSample(ts: 1_700_000_000, bpm: 90)]
        HRTrackStore.store(cyc, startTs: 1_700_000_000, sport: "Cycling", into: defaults)
        XCTAssertEqual(HRTrackStore.load(startTs: 1_700_000_000, sport: "Cycling", from: defaults), cyc)
        XCTAssertEqual(HRTrackStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults), track)
        // An empty track is an honest "no HR" — never stored as a placeholder.
        HRTrackStore.store([], startTs: 42, sport: "Running", into: defaults)
        XCTAssertNil(HRTrackStore.load(startTs: 42, sport: "Running", from: defaults))
        // Removal leaves no orphan.
        HRTrackStore.remove(startTs: 1_700_000_000, sport: "Running", from: defaults)
        XCTAssertNil(HRTrackStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults))
    }

    // MARK: - WorkoutRecord CKRecord round-trip (HR track rides along)

    func testWorkoutRecordCarriesHRTrackThroughCKRecord() {
        let row = WorkoutRow(startTs: 1_700_000_000, endTs: 1_700_003_600, sport: "Running", source: "whoop",
                             durationS: 3600, energyKcal: 500, avgHr: 136, maxHr: 165, strain: 12.3,
                             distanceM: 10_000, zonesJSON: nil, notes: nil)
        let route = WorkoutRoute(polyline: RouteMath.encode([a, b]), distanceM: RouteMath.totalMeters([a, b]))
        let track = [HRSample(ts: 1_700_000_000, bpm: 120), HRSample(ts: 1_700_000_060, bpm: 150)]
        let base = CKRecord(recordType: WorkoutRecord.recordType,
                            recordID: WorkoutRecord.recordID(deviceId: "my-whoop", startTs: row.startTs, sport: row.sport))
        let rec = WorkoutRecord.make(row: row, deviceId: "my-whoop", route: route, hrTrack: track, base: base)
        let decoded = WorkoutRecord.decode(rec)
        XCTAssertEqual(decoded?.deviceId, "my-whoop")
        XCTAssertEqual(decoded?.row, row)
        XCTAssertEqual(decoded?.route, route)
        XCTAssertEqual(decoded?.hrTrack, track)
        // A record with no HR track decodes to nil (older records / indoor HR-less runs) — no crash.
        let noHR = WorkoutRecord.make(row: row, deviceId: "my-whoop", route: route, hrTrack: nil, base: CKRecord(
            recordType: WorkoutRecord.recordType,
            recordID: WorkoutRecord.recordID(deviceId: "my-whoop", startTs: row.startTs, sport: row.sport)))
        XCTAssertNil(WorkoutRecord.decode(noHR)?.hrTrack)
    }

    // MARK: - RunSplits (per-mile/km split math)

    /// A straight eastward track along the equator — each 0.001° lon step is ~111 m — at constant pace.
    /// Splits must partition the whole track: every full split is exactly one unit, the leftover is the
    /// final partial, the split distances sum back to the total, and the elapsed times sum to the run's.
    func testSplitsPartitionTrackByUnit() {
        let pts = (0..<20).map { RouteMath.LatLng(0.0, Double($0) * 0.001) }
        let times = (0..<20).map { Double($0 * 10) }                       // 10 s/leg → constant pace
        let track = zip(times, pts).map { (t: $0, pt: $1) }
        let total = RouteMath.totalMeters(pts)
        let unit = 1000.0
        let splits = RunSplits.compute(track: track, hr: [], unitMeters: unit)

        let fullCount = Int(total / unit)                                  // ~2 for a ~2.1 km track
        XCTAssertEqual(splits.filter { $0.distanceM >= unit - 0.5 }.count, fullCount)
        for s in splits.prefix(fullCount) { XCTAssertEqual(s.distanceM, unit, accuracy: 0.5) }
        XCTAssertEqual(splits.map(\.distanceM).reduce(0, +), total, accuracy: 1.0)
        XCTAssertEqual(splits.map(\.elapsedSec).reduce(0, +), times.last! - times.first!, accuracy: 0.01)
        XCTAssertNil(splits.first?.avgHr)                                  // no HR supplied
    }

    /// HR is averaged into the split whose time window it falls in: a run that runs harder in its second
    /// half must show a higher avg HR on the later split than the earlier one.
    func testSplitAvgHrFollowsTimeWindow() {
        let pts = (0..<20).map { RouteMath.LatLng(0.0, Double($0) * 0.001) }
        let times = (0..<20).map { Double($0 * 10) }                       // 0…190 s
        let track = zip(times, pts).map { (t: $0, pt: $1) }
        // 140 bpm for the first ~half of the run, 160 bpm for the second.
        let hr = stride(from: 0, through: 190, by: 5).map { HRSample(ts: $0, bpm: $0 < 95 ? 140 : 160) }
        let splits = RunSplits.compute(track: track, hr: hr, unitMeters: 1000.0)

        XCTAssertGreaterThanOrEqual(splits.count, 2)
        XCTAssertNotNil(splits.first?.avgHr)
        XCTAssertNotNil(splits.last?.avgHr)
        XCTAssertLessThan(splits.first!.avgHr!, splits.last!.avgHr!)
    }

    func testSplitsEmptyForDegenerateTrack() {
        XCTAssertTrue(RunSplits.compute(track: [], hr: [], unitMeters: 1000).isEmpty)
        let one = [(t: 0.0, pt: RouteMath.LatLng(0, 0))]
        XCTAssertTrue(RunSplits.compute(track: one, hr: [], unitMeters: 1000).isEmpty)
    }

    /// A single long segment that straddles several unit boundaries must still cut a split at each one
    /// (the inner while-loop), not just the first.
    func testSplitsCutMultipleBoundariesInOneSegment() {
        // Two points ~3.3 km apart (0.03° lon at the equator) in one 300 s leg.
        let track = [(t: 0.0, pt: RouteMath.LatLng(0.0, 0.0)),
                     (t: 300.0, pt: RouteMath.LatLng(0.0, 0.03))]
        let splits = RunSplits.compute(track: track, hr: [], unitMeters: 1000.0)
        // ~3.3 km → 3 full 1-km splits + a partial.
        XCTAssertEqual(splits.filter { $0.distanceM >= 999.5 }.count, 3)
        XCTAssertEqual(splits.map(\.distanceM).reduce(0, +), RouteMath.totalMeters([track[0].pt, track[1].pt]), accuracy: 1.0)
    }
}
