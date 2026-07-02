#if os(iOS)
import Foundation
import ActivityKit

/// Live Activity attributes for an active live-HR / workout session. Shared between the app (which
/// starts/updates the activity) and the widget extension (which renders it on the Lock Screen and in
/// the Dynamic Island).
public struct NOOPActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var bpm: Int?
        public var recovery: Int?
        public var bonded: Bool
        // Effort / strain on NOOP's 0–100 axis (#446) — one more stat in the Dynamic Island expanded
        // region. OPTIONAL with a nil default so an activity started by an older build still decodes.
        public var effort: Int?

        // Active GPS distance-workout metrics (outdoor run / walk / hike / ride). Carried PRE-FORMATTED
        // as display strings, not raw numbers, because the miles-vs-km unit preference lives in the app's
        // UserDefaults.standard — which a widget extension can't read — so the app resolves units and
        // formats before pushing. All nil (the default) when no GPS workout is active, which is the flag
        // the widget keys "show run stats" off; nil also keeps an activity from an older build decodable.
        /// Localised sport label, e.g. "Running" — the workout's name, shown in place of the HR title.
        public var sport: String?
        /// Total distance so far, unit-formatted, e.g. "3.1 mi" / "5.0 km".
        public var distanceText: String?
        /// Whole-run average pace, unit-formatted, e.g. "8:30 /mi"; nil until distance is non-zero.
        public var avgPaceText: String?
        /// Rolling current pace, unit-formatted, e.g. "7:58 /mi"; nil when stopped / pace undefined.
        public var curPaceText: String?

        public init(bpm: Int?, recovery: Int?, bonded: Bool, effort: Int? = nil,
                    sport: String? = nil, distanceText: String? = nil,
                    avgPaceText: String? = nil, curPaceText: String? = nil) {
            self.bpm = bpm
            self.recovery = recovery
            self.bonded = bonded
            self.effort = effort
            self.sport = sport
            self.distanceText = distanceText
            self.avgPaceText = avgPaceText
            self.curPaceText = curPaceText
        }
    }

    /// Static title shown for the session.
    public var title: String

    public init(title: String = "Live HR") {
        self.title = title
    }
}
#endif
