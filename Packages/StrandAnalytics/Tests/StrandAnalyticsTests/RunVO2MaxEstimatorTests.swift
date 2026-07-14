import XCTest
@testable import StrandAnalytics

/// Pins the submaximal run-derived VO₂max math: the ACSM O₂ cost, the %HRR→%VO₂R inversion, the trusted
/// %HRR band gate, and the multi-segment median/spread. All pure — no run, no GPS.
final class RunVO2MaxEstimatorTests: XCTestCase {

    private let rhr = 45.0, hrMax = 200.0   // reserve = 155

    // MARK: - Single-segment known values (chosen to divide cleanly)

    func testSegmentVO2maxExactAtHalfReserve() {
        // speed 100 m/min → cost 23.5; HR at 50% reserve (122.5) → VO₂max = 3.5 + 20/0.5 = 43.5.
        let s = RunVO2MaxEstimator.Segment(speedMetersPerMin: 100, avgHR: 122.5)
        XCTAssertEqual(RunVO2MaxEstimator.segmentVO2max(s, restingHR: rhr, maxHR: hrMax)!, 43.5, accuracy: 1e-6)
    }

    func testSegmentVO2maxExactAtEightyPercent() {
        // speed 200 m/min → cost 43.5; HR at 80% reserve (169) → VO₂max = 3.5 + 40/0.8 = 53.5.
        let s = RunVO2MaxEstimator.Segment(speedMetersPerMin: 200, avgHR: 169)
        XCTAssertEqual(RunVO2MaxEstimator.segmentVO2max(s, restingHR: rhr, maxHR: hrMax)!, 53.5, accuracy: 1e-6)
    }

    func testACSMCost() {
        XCTAssertEqual(RunVO2MaxEstimator.acsmVO2Cost(speedMetersPerMin: 200), 43.5, accuracy: 1e-9)
        XCTAssertEqual(RunVO2MaxEstimator.acsmVO2Cost(speedMetersPerMin: 0), 3.5, accuracy: 1e-9)
    }

    // MARK: - Grade term

    func testUphillAddsCost() {
        // 200 m/min at 5% → +0.9·200·0.05 = +9 over the flat 43.5.
        XCTAssertEqual(RunVO2MaxEstimator.acsmVO2Cost(speedMetersPerMin: 200, gradeFraction: 0.05),
                       52.5, accuracy: 1e-9)
    }

    func testDownhillGivesPartialCredit() {
        // 200 m/min at −5% → 0.3·200·(−0.05) = −3 (a smaller change than the +9 uphill: the asymmetry).
        XCTAssertEqual(RunVO2MaxEstimator.acsmVO2Cost(speedMetersPerMin: 200, gradeFraction: -0.05),
                       40.5, accuracy: 1e-9)
    }

    func testGradeIsClamped() {
        // A wild 50% grade (bad altitude sample) clamps to 30%.
        XCTAssertEqual(RunVO2MaxEstimator.acsmVO2Cost(speedMetersPerMin: 200, gradeFraction: 0.50),
                       RunVO2MaxEstimator.acsmVO2Cost(speedMetersPerMin: 200, gradeFraction: 0.30),
                       accuracy: 1e-9)
    }

    func testUphillSegmentReadsFitterThanFlat() {
        // Same pace + HR, but run UPHILL, means you're fitter than a flat reading implies → higher VO₂max.
        let flat = RunVO2MaxEstimator.segmentVO2max(
            .init(speedMetersPerMin: 200, avgHR: 169, gradeFraction: 0), restingHR: rhr, maxHR: hrMax)!
        let uphill = RunVO2MaxEstimator.segmentVO2max(
            .init(speedMetersPerMin: 200, avgHR: 169, gradeFraction: 0.05), restingHR: rhr, maxHR: hrMax)!
        XCTAssertGreaterThan(uphill, flat)
    }

    // MARK: - Band gate

    func testSegmentRejectedBelowBand() {
        // 40% reserve → HR 107, below the 45% floor → not trusted (too easy).
        let s = RunVO2MaxEstimator.Segment(speedMetersPerMin: 120, avgHR: 45 + 0.40 * 155)
        XCTAssertNil(RunVO2MaxEstimator.segmentVO2max(s, restingHR: rhr, maxHR: hrMax))
    }

    func testSegmentRejectedAboveBand() {
        // 96% reserve → essentially maxed, above the 95% ceiling → not trusted.
        let s = RunVO2MaxEstimator.Segment(speedMetersPerMin: 250, avgHR: 45 + 0.96 * 155)
        XCTAssertNil(RunVO2MaxEstimator.segmentVO2max(s, restingHR: rhr, maxHR: hrMax))
    }

    func testDegenerateReserveIsNil() {
        let s = RunVO2MaxEstimator.Segment(speedMetersPerMin: 200, avgHR: 150)
        XCTAssertNil(RunVO2MaxEstimator.segmentVO2max(s, restingHR: 200, maxHR: 200))  // zero reserve
    }

    // MARK: - Run-level estimate

    func testEstimateNeedsMinimumSegments() {
        // Two valid segments but minSegments 3 → nil (too short / too little steady evidence).
        let segs = [RunVO2MaxEstimator.Segment(speedMetersPerMin: 200, avgHR: 169),
                    RunVO2MaxEstimator.Segment(speedMetersPerMin: 180, avgHR: 160)]
        XCTAssertNil(RunVO2MaxEstimator.estimate(segments: segs, restingHR: rhr, maxHR: hrMax, minSegments: 3))
    }

    func testEstimateMedianAndSpread() {
        // Three segments engineered (via known HRs) to yield 43.5, 48.5, 53.5 → median 48.5, spread 10.
        let segs = [
            RunVO2MaxEstimator.Segment(speedMetersPerMin: 100, avgHR: 122.5),   // 43.5
            RunVO2MaxEstimator.Segment(speedMetersPerMin: 200, avgHR: 169),     // 53.5
            RunVO2MaxEstimator.Segment(speedMetersPerMin: 150, avgHR: 148),     // ~48.x
        ]
        let est = RunVO2MaxEstimator.estimate(segments: segs, restingHR: rhr, maxHR: hrMax, minSegments: 3)!
        XCTAssertEqual(est.segmentCount, 3)
        XCTAssertGreaterThan(est.spread, 0)
        // Median is the middle of the three sorted values.
        XCTAssertGreaterThan(est.vo2max, 43.5)
        XCTAssertLessThan(est.vo2max, 53.5)
    }

    /// The core validity check: segments at DIFFERENT submaximal paces that reflect the SAME fitness must
    /// agree — a tight spread. Built by back-solving HR for a true VO₂max of 52 at three speeds.
    func testConsistentFitnessGivesTightSpread() {
        let trueVO2 = 52.0, reserve = hrMax - rhr
        func hrFor(_ speed: Double) -> Double {
            let cost = RunVO2MaxEstimator.acsmVO2Cost(speedMetersPerMin: speed)
            let pctHRR = (cost - 3.5) / (trueVO2 - 3.5)
            return rhr + pctHRR * reserve
        }
        let segs = [150.0, 175.0, 200.0].map {
            RunVO2MaxEstimator.Segment(speedMetersPerMin: $0, avgHR: hrFor($0))
        }
        let est = RunVO2MaxEstimator.estimate(segments: segs, restingHR: rhr, maxHR: hrMax, minSegments: 3)!
        XCTAssertEqual(est.vo2max, trueVO2, accuracy: 0.01)   // recovers the true value
        XCTAssertLessThan(est.spread, 0.01)                   // and the segments agree
    }

    // MARK: - Pace → speed

    func testSpeedFromPace() {
        // 5:00/km = 300 s/km → 200 m/min.
        XCTAssertEqual(RunVO2MaxEstimator.speedMetersPerMin(secPerKm: 300), 200, accuracy: 1e-9)
        XCTAssertEqual(RunVO2MaxEstimator.speedMetersPerMin(secPerKm: 0), 0, accuracy: 1e-9)
    }
}
