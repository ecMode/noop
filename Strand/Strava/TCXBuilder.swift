import Foundation

/// Minimal TCX (Garmin Training Center Database v2) writer used to export a finished workout to
/// Strava's `/uploads` endpoint. TCX is the sweet spot for this app: it carries a GPS track, per-point
/// heart rate, AND per-point timestamps in one simple XML document that Strava ingests directly (FIT is
/// binary and fiddly to author; GPX carries HR only via a vendor extension).
///
/// Pure value-in / Data-out, no I/O — unit-tested in StrandTests. The caller is responsible for merging
/// the workout's timestamped HR samples and GPS fixes into the `Point` stream (see `points`).
enum TCXBuilder {

    /// One trackpoint. `time` is required; `lat`/`lon` and `hr` are each optional so the same writer
    /// handles a GPS run with HR, a GPS-only walk, or an HR-only indoor session.
    struct Point {
        let time: Date
        let lat: Double?
        let lon: Double?
        let hr: Int?
    }

    /// TCX's `Sport` attribute only recognizes Running / Biking / Other — map everything else to Other.
    static func tcxSport(_ sport: String) -> String {
        let s = sport.lowercased()
        if s.contains("run") { return "Running" }
        if s.contains("cycl") || s.contains("bike") || s.contains("ride") { return "Biking" }
        return "Other"
    }

    /// UTC ISO-8601 (`2026-07-01T13:00:00Z`) — the timestamp format TCX requires.
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Serialize a single-lap TCX document. `totalSeconds`/`distanceMeters` populate the lap summary;
    /// Strava also re-derives distance from the GPS positions when present.
    static func build(sport: String, start: Date, totalSeconds: Double,
                      distanceMeters: Double, calories: Int?, points: [Point]) -> Data {
        let startStr = iso.string(from: start)
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
         <Activities>
          <Activity Sport="\(tcxSport(sport))">
           <Id>\(startStr)</Id>
           <Lap StartTime="\(startStr)">
            <TotalTimeSeconds>\(String(format: "%.1f", max(0, totalSeconds)))</TotalTimeSeconds>
            <DistanceMeters>\(String(format: "%.1f", max(0, distanceMeters)))</DistanceMeters>
            <Calories>\(max(0, calories ?? 0))</Calories>
            <Intensity>Active</Intensity>
            <TriggerMethod>Manual</TriggerMethod>
            <Track>

        """
        for p in points {
            xml += "     <Trackpoint>\n"
            xml += "      <Time>\(iso.string(from: p.time))</Time>\n"
            if let lat = p.lat, let lon = p.lon {
                xml += "      <Position>\n"
                xml += "       <LatitudeDegrees>\(String(format: "%.6f", lat))</LatitudeDegrees>\n"
                xml += "       <LongitudeDegrees>\(String(format: "%.6f", lon))</LongitudeDegrees>\n"
                xml += "      </Position>\n"
            }
            if let hr = p.hr, hr > 0 {
                xml += "      <HeartRateBpm><Value>\(hr)</Value></HeartRateBpm>\n"
            }
            xml += "     </Trackpoint>\n"
        }
        xml += """
            </Track>
           </Lap>
          </Activity>
         </Activities>
        </TrainingCenterDatabase>

        """
        return Data(xml.utf8)
    }
}
