import XCTest
@testable import Strand

/// Proves the TCX export (used for Strava upload) is well-formed and carries the three things Strava
/// needs from a run: GPS positions, per-point heart rate, and UTC timestamps — while degrading cleanly
/// to HR-only or GPS-only trackpoints.
final class TCXBuilderTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)   // fixed epoch → deterministic XML

    func testSportMapping() {
        XCTAssertEqual(TCXBuilder.tcxSport("Running"), "Running")
        XCTAssertEqual(TCXBuilder.tcxSport("Trail run"), "Running")
        XCTAssertEqual(TCXBuilder.tcxSport("Cycling"), "Biking")
        XCTAssertEqual(TCXBuilder.tcxSport("Outdoor ride"), "Biking")
        XCTAssertEqual(TCXBuilder.tcxSport("Yoga"), "Other")
    }

    func testFullTrackpointHasPositionAndHR() {
        let pts = [
            TCXBuilder.Point(time: start, lat: 37.7749, lon: -122.4194, hr: 130),
            TCXBuilder.Point(time: start.addingTimeInterval(1), lat: 37.7750, lon: -122.4195, hr: 132),
        ]
        let xml = String(decoding: TCXBuilder.build(sport: "Running", start: start, totalSeconds: 2,
                                                    distanceMeters: 14.2, calories: 3, points: pts), as: UTF8.self)
        XCTAssertTrue(xml.contains("Sport=\"Running\""))
        XCTAssertTrue(xml.contains("<Id>2027-01-15T08:00:00Z</Id>"))       // epoch 1_800_000_000 UTC
        XCTAssertTrue(xml.contains("<LatitudeDegrees>37.774900</LatitudeDegrees>"))
        XCTAssertTrue(xml.contains("<LongitudeDegrees>-122.419500</LongitudeDegrees>"))
        XCTAssertTrue(xml.contains("<HeartRateBpm><Value>130</Value></HeartRateBpm>"))
        XCTAssertTrue(xml.contains("<TotalTimeSeconds>2.0</TotalTimeSeconds>"))
        XCTAssertTrue(xml.contains("<DistanceMeters>14.2</DistanceMeters>"))
        // Two trackpoints emitted.
        XCTAssertEqual(xml.components(separatedBy: "<Trackpoint>").count - 1, 2)
    }

    func testHROnlyOmitsPosition() {
        let pts = [TCXBuilder.Point(time: start, lat: nil, lon: nil, hr: 145)]
        let xml = String(decoding: TCXBuilder.build(sport: "Treadmill run", start: start, totalSeconds: 1,
                                                    distanceMeters: 0, calories: nil, points: pts), as: UTF8.self)
        XCTAssertFalse(xml.contains("<Position>"))
        XCTAssertTrue(xml.contains("<HeartRateBpm><Value>145</Value></HeartRateBpm>"))
        XCTAssertTrue(xml.contains("<Calories>0</Calories>"))              // nil calories → 0
    }

    func testGPSOnlyOmitsHeartRate() {
        let pts = [TCXBuilder.Point(time: start, lat: 51.5, lon: -0.12, hr: nil)]
        let xml = String(decoding: TCXBuilder.build(sport: "Walking", start: start, totalSeconds: 1,
                                                    distanceMeters: 5, calories: 1, points: pts), as: UTF8.self)
        XCTAssertTrue(xml.contains("<Position>"))
        XCTAssertFalse(xml.contains("<HeartRateBpm>"))
    }

    func testZeroHRIsOmitted() {
        // A defensive 0/negative HR must not emit a bogus <HeartRateBpm>0.
        let pts = [TCXBuilder.Point(time: start, lat: 1, lon: 2, hr: 0)]
        let xml = String(decoding: TCXBuilder.build(sport: "Running", start: start, totalSeconds: 1,
                                                    distanceMeters: 1, calories: 0, points: pts), as: UTF8.self)
        XCTAssertFalse(xml.contains("<HeartRateBpm>"))
    }
}
