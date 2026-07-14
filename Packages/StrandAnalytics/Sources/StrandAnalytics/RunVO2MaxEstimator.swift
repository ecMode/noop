import Foundation

// RunVO2MaxEstimator.swift — submaximal, run-derived VO₂max (the Firstbeat/Garmin-style approach).
//
// Unlike the non-exercise Nes regression (FitnessAgeEngine), this estimates VO₂max from ACTUAL running:
// a normal 20–30 min GPS run at SUBMAXIMAL effort, no max-effort test required. For each steady segment
// (a mile / km split) it knows the oxygen cost of the pace (ACSM running equation) and how hard that was
// for the runner (%HRR from a personal resting HR + max HR), then inverts the well-established
// %HRR ≈ %VO₂-reserve equivalence to solve for VO₂max. Averaging across a run's steady segments — and how
// tightly they AGREE — gives the estimate and its confidence.
//
// Method (per steady segment):
//   VO₂cost = 3.5 + 0.2 · speed[m/min]                          (ACSM flat-running O₂ cost, ml/kg/min)
//   %HRR    = (HR − restingHR) / (maxHR − restingHR)             (Karvonen heart-rate reserve)
//   VO₂max  = 3.5 + (VO₂cost − 3.5) / %HRR                       (%HRR ≈ %VO₂R ⇒ invert for max)
//
// References: ACSM's Guidelines for Exercise Testing and Prescription (metabolic running equation);
// Swain et al. 1994/1997 (%HRR ≈ %VO₂R equivalence). Pure + deterministic — unit-tested, no I/O.
//
// LIMITATIONS (surfaced honestly, not hidden):
//   • Grade IS handled when the caller supplies elevation (barometric): the O₂ cost carries the ACSM grade
//     term with an up/down asymmetry (see `acsmVO2Cost`). Without elevation it falls back to flat, which
//     biases hilly runs. Grade quality is only as good as the altitude source (barometer ≫ GPS altitude).
//   • Assumes average running economy (the ACSM 0.2 ml/kg/min per m/min). An economical/inefficient runner
//     is systematically over/under-estimated — the main individual error, shared by all such estimators.
//   • Sensitive to the personal maxHR and restingHR (both must be reasonably right).
//   • Cardiac drift over a long run inflates late-segment HR → deflates those segments; the multi-segment
//     median softens it but doesn't remove it.
public enum RunVO2MaxEstimator {

    /// Resting O₂ uptake (ml/kg/min) — one MET, the intercept of the ACSM running equation.
    public static let restVO2 = 3.5
    /// Metres-per-minute → ml/kg/min slope of the ACSM flat-running equation.
    public static let acsmSlope = 0.2
    /// ACSM running GRADE coefficient (uphill): O₂ cost adds `gradeCoeffUp · speed · grade`. Grade is
    /// rise/run (0.05 = 5% incline). This is the term the flat-only v1 was missing — a 5% hill at 180 m/min
    /// adds ~8 ml/kg/min, ~20% of the flat cost, so ignoring it badly biased hilly runs.
    public static let gradeCoeffUp = 0.9
    /// Downhill coefficient — deliberately SMALLER than uphill (partial credit). Running downhill costs less
    /// than flat but far from the mirror of uphill (you can't recover the energy), and a full-magnitude
    /// negative term would over-credit descents and inflate VO₂max. The up/down asymmetry also means rolling
    /// terrain (equal up+down) nets a small POSITIVE cost, which is physiologically correct.
    public static let gradeCoeffDown = 0.3
    /// Clamp on per-segment grade fed to the cost — beyond ±30% isn't real sustained running and usually
    /// means a bad altitude sample; clamping keeps one noisy reading from blowing up a segment's cost.
    public static let maxAbsGrade = 0.30

    /// Steady-effort %HRR band a segment must fall in to be trusted. Below ~0.45 the %HRR→%VO₂R line and a
    /// small denominator make it noisy (an easy jog / walk break); above ~0.95 the runner is essentially
    /// maxed (rare on the runs this targets, and clamping HR near max would bias it). Public so callers /
    /// tests can see the same gate.
    public static let minPctHRR = 0.45
    public static let maxPctHRR = 0.95

    /// A steady running segment reduced to what the inversion needs: the segment's O₂ COST (ml/kg/min,
    /// already grade-adjusted by the caller) and its average HR. Storing the cost — not raw speed — lets the
    /// caller integrate grade over a rolling segment before it gets here.
    public struct Segment: Equatable, Sendable {
        public let vo2Cost: Double
        public let avgHR: Double
        public init(vo2Cost: Double, avgHR: Double) {
            self.vo2Cost = vo2Cost
            self.avgHR = avgHR
        }
        /// Convenience for a single steady speed at a constant grade (flat by default) — the ACSM cost is
        /// computed for you. Used by simpler callers and the tests.
        public init(speedMetersPerMin: Double, avgHR: Double, gradeFraction: Double = 0) {
            self.init(vo2Cost: RunVO2MaxEstimator.acsmVO2Cost(speedMetersPerMin: speedMetersPerMin,
                                                              gradeFraction: gradeFraction),
                      avgHR: avgHR)
        }
    }

    /// The estimate for one run: the VO₂max value plus how it was reached, so callers can present
    /// confidence honestly rather than a bare number.
    public struct Estimate: Equatable, Sendable {
        /// Median per-segment VO₂max (ml/kg/min).
        public let vo2max: Double
        /// How many segments qualified (more = steadier evidence; ties to run length).
        public let segmentCount: Int
        /// Spread (max − min) of the per-segment estimates (ml/kg/min). Small = the segments AGREE, which
        /// is the in-run confidence signal; large = mixed terrain / drift / pacing, treat with caution.
        public let spread: Double
        public init(vo2max: Double, segmentCount: Int, spread: Double) {
            self.vo2max = vo2max; self.segmentCount = segmentCount; self.spread = spread
        }
    }

    /// ACSM running O₂ cost (ml/kg/min) of a speed (m/min) at a grade (rise/run). Grade is clamped to
    /// ±`maxAbsGrade`, and uses the smaller downhill coefficient for negative grade. `gradeFraction: 0`
    /// gives the plain flat-running cost.
    public static func acsmVO2Cost(speedMetersPerMin: Double, gradeFraction: Double = 0) -> Double {
        let speed = max(0, speedMetersPerMin)
        let grade = min(maxAbsGrade, max(-maxAbsGrade, gradeFraction))
        let gradeCoeff = grade >= 0 ? gradeCoeffUp : gradeCoeffDown
        return restVO2 + acsmSlope * speed + gradeCoeff * speed * grade
    }

    /// Per-segment VO₂max, or nil when the segment is outside the trusted %HRR band or the inputs are
    /// degenerate (non-positive reserve, HR at/below rest).
    public static func segmentVO2max(_ s: Segment, restingHR: Double, maxHR: Double) -> Double? {
        let reserve = maxHR - restingHR
        guard reserve > 0 else { return nil }
        let pctHRR = (s.avgHR - restingHR) / reserve
        guard pctHRR >= minPctHRR, pctHRR <= maxPctHRR else { return nil }
        let vo2max = restVO2 + (s.vo2Cost - restVO2) / pctHRR
        return vo2max.isFinite ? vo2max : nil
    }

    /// Estimate a run's VO₂max from its steady segments. Returns nil when fewer than `minSegments` fall in
    /// the trusted band (i.e. the run was too short / too easy / too erratic to trust) — never a fabricated
    /// number. `minSegments` defaults to 3 (≈ a 20–30 min run at 1-mile granularity).
    public static func estimate(segments: [Segment], restingHR: Double, maxHR: Double,
                                minSegments: Int = 3) -> Estimate? {
        let values = segments.compactMap { segmentVO2max($0, restingHR: restingHR, maxHR: maxHR) }
        guard values.count >= minSegments else { return nil }
        let sorted = values.sorted()
        let median: Double
        let n = sorted.count
        if n % 2 == 1 {
            median = sorted[n / 2]
        } else {
            median = (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        }
        return Estimate(vo2max: median, segmentCount: n, spread: sorted.last! - sorted.first!)
    }

    // MARK: - Convenience builders

    /// Metres per minute for a pace expressed as seconds per kilometre (the recorder's native pace unit).
    public static func speedMetersPerMin(secPerKm: Double) -> Double {
        secPerKm > 0 ? 1000.0 / (secPerKm / 60.0) : 0
    }
}
