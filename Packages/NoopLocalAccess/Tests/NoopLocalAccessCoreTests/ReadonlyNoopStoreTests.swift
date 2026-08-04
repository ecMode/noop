import GRDB
import XCTest
@testable import NoopLocalAccessCore

final class ReadonlyNoopStoreTests: XCTestCase {
    func testReadsSeededNoopStoreWithoutOpeningWritableHandle() throws {
        let url = try TemporaryDatabase.seeded()
        let store = try ReadonlyNoopStore(path: url.path)

        XCTAssertTrue(try store.isReadOnlyForTest())
        XCTAssertEqual(try store.latestHRSampleTs(deviceId: "my-whoop"), 102)
        XCTAssertEqual(try store.metricKeys(deviceId: "my-whoop"), ["hrv"])

        let daily = try store.dailyMetrics(deviceId: "my-whoop", from: "2026-06-01", to: "2026-06-30")
        XCTAssertEqual(daily.map(\.day), ["2026-06-10"])
        XCTAssertEqual(daily.first?.recovery, 67)

        let stats = try store.storageStats()
        XCTAssertEqual(stats.decodedRows, 4)
        XCTAssertEqual(stats.rawBatches, 1)
        XCTAssertEqual(stats.rawBytes, 12)
    }

    func testWorkoutSummaryInlinesPersistedSplits() throws {
        let url = try TemporaryDatabase.seeded()
        let access = NoopDataAccess(store: try ReadonlyNoopStore(path: url.path))
        // A window wide enough to reach the seeded run (its startTs is early-epoch, far before "now").
        let summary = try access.workoutSummary(days: 25_000)

        guard case .array(let workouts)? = summary.objectValue?["workouts"],
              let run = workouts.first?.objectValue else {
            return XCTFail("Expected a workout in the summary")
        }
        guard case .array(let splits)? = run["splits"] else {
            return XCTFail("Expected splits inlined as an array")
        }
        XCTAssertEqual(splits.count, 2)
        XCTAssertEqual(splits.first?.objectValue?["index"]?.intValue, 1)
        XCTAssertEqual(splits.first?.objectValue?["distanceM"]?.intValue, 1000)
        XCTAssertEqual(splits.first?.objectValue?["avgHr"]?.intValue, 150)
        XCTAssertEqual(splits.last?.objectValue?["paceSecPerKm"]?.intValue, 320)
    }

    func testForeignNoopLikeDatabaseIsRejectedWithoutQuarantine() throws {
        let url = try TemporaryDatabase.foreignNoopLike()

        XCTAssertThrowsError(try ReadonlyNoopStore(path: url.path)) { error in
            guard case .databaseUnavailable(let message) = error as? LocalAccessError else {
                return XCTFail("Expected LocalAccessError.databaseUnavailable")
            }
            XCTAssertTrue(message.contains("without GRDB migration metadata"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
