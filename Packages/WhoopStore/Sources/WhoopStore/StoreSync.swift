import Foundation
import GRDB

/// One natural-keyed row that changed in the store, handed to the outbound sync layer so it can push
/// (or delete) the matching CloudKit record. Intentionally tiny + `Sendable`: it carries only what's
/// needed to rebuild a deterministic record id (kind + deviceId + the key-minus-deviceId), never the
/// row's data. The sync layer reads the current row from the store when it actually builds the record.
///
/// `key` is the natural key with `deviceId` removed, joined with `|`:
///   workout      → "<startTs>|<sport>"
///   sleep        → "<startTs>"
///   daily        → "<day>"
///   appleDaily   → "<day>"
///   metricSeries → "<day>"            (packed: one record per (deviceId, day))
///   journal      → "<day>|<question>"
///   labMarker    → "<id>"             (stable client id)
public struct StoreChange: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case sleep, daily, metricSeries, workout, journal, appleDaily, labMarker
    }
    public let kind: Kind
    public let deviceId: String
    public let key: String
    public let isDelete: Bool

    public init(kind: Kind, deviceId: String, key: String, isDelete: Bool) {
        self.kind = kind
        self.deviceId = deviceId
        self.key = key
        self.isDelete = isDelete
    }
}

public extension StoreChange {
    /// Convenience for the workout natural key (deviceId, startTs, sport) minus deviceId.
    static func workout(deviceId: String, startTs: Int, sport: String, isDelete: Bool) -> StoreChange {
        StoreChange(kind: .workout, deviceId: deviceId, key: "\(startTs)|\(sport)", isDelete: isDelete)
    }
}

extension WhoopStore {
    /// Register (or clear) the outbound change sink. Called once by CloudSync at startup when sync is
    /// enabled. `@Sendable` because the closure hops off the actor to the main-actor sync layer.
    public func setChangeSink(_ sink: (@Sendable ([StoreChange]) -> Void)?) {
        self.changeSink = sink
    }

    /// Emit changes to the sink unless we're mid-apply of inbound remote records (which would echo the
    /// row straight back out) or no sink is registered. Called by the upsert/delete methods after a
    /// successful write. Kept internal — only the store's own mutators call it.
    func emitChanges(_ changes: [StoreChange]) {
        guard !Self.suppressChangeEmission, let changeSink, !changes.isEmpty else { return }
        changeSink(changes)
    }

    /// Run `body` (a set of inbound-apply upserts/deletes) with change emission suppressed, so applying
    /// a record fetched from CloudKit does not re-queue it as a local change. The task-local scoping
    /// means only writes on THIS task inside the block are suppressed; concurrent local writes still
    /// emit normally.
    public func applyingRemoteChanges<T>(_ body: () async throws -> T) async rethrows -> T {
        try await Self.$suppressChangeEmission.withValue(true) {
            try await body()
        }
    }

    /// Fetch a single workout row by its full natural key, for building an outbound record on demand.
    /// Returns nil if the row was deleted since it was queued (the sync layer then drops that save).
    public func workout(deviceId: String, startTs: Int, sport: String) async throws -> WorkoutRow? {
        try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT startTs, endTs, sport, source, durationS, energyKcal, avgHr, maxHr,
                       strain, distanceM, zonesJSON, notes FROM workout
                WHERE deviceId = ? AND startTs = ? AND sport = ?
                """, arguments: [deviceId, startTs, sport])
                .map {
                    WorkoutRow(startTs: $0["startTs"], endTs: $0["endTs"], sport: $0["sport"],
                               source: $0["source"], durationS: $0["durationS"],
                               energyKcal: $0["energyKcal"], avgHr: $0["avgHr"], maxHr: $0["maxHr"],
                               strain: $0["strain"], distanceM: $0["distanceM"],
                               zonesJSON: $0["zonesJSON"], notes: $0["notes"])
                }
        }
    }

    /// A syncable table, used for the injection-safe `distinctDeviceIds` enumeration (the raw value is
    /// a fixed table name, never user input).
    public enum SyncTable: String, Sendable {
        case sleepSession, dailyMetric, metricSeries, workout, journal, appleDaily, labMarker
    }

    /// Every distinct deviceId with rows in `table` — the first-sync bulk upload walks each partition
    /// (active strap, computed `-noop`, apple-health, re-added straps) uniformly.
    public func distinctDeviceIds(_ table: SyncTable) async throws -> [String] {
        try syncRead { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT deviceId FROM \(table.rawValue) ORDER BY deviceId ASC")
        }
    }

    // MARK: - By-natural-key reads (build an outbound record for one changed row)

    public func sleepSession(deviceId: String, startTs: Int) async throws -> CachedSleepSession? {
        try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON, userEdited, startTsAdjusted
                FROM sleepSession WHERE deviceId = ? AND startTs = ?
                """, arguments: [deviceId, startTs])
                .map {
                    CachedSleepSession(startTs: $0["startTs"], endTs: $0["endTs"],
                                       efficiency: $0["efficiency"], restingHr: $0["restingHr"],
                                       avgHrv: $0["avgHrv"], stagesJSON: $0["stagesJSON"],
                                       userEdited: ($0["userEdited"] as Int) != 0,
                                       startTsAdjusted: $0["startTsAdjusted"])
                }
        }
    }

    public func dailyMetric(deviceId: String, day: String) async throws -> DailyMetric? {
        try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT day, totalSleepMin, efficiency, deepMin, remMin, lightMin, disturbances,
                       restingHr, avgHrv, recovery, strain, exerciseCount,
                       spo2Pct, skinTempDevC, respRateBpm, steps, activeKcalEst FROM dailyMetric
                WHERE deviceId = ? AND day = ?
                """, arguments: [deviceId, day])
                .map {
                    DailyMetric(day: $0["day"], totalSleepMin: $0["totalSleepMin"],
                                efficiency: $0["efficiency"], deepMin: $0["deepMin"],
                                remMin: $0["remMin"], lightMin: $0["lightMin"],
                                disturbances: $0["disturbances"], restingHr: $0["restingHr"],
                                avgHrv: $0["avgHrv"], recovery: $0["recovery"],
                                strain: $0["strain"], exerciseCount: $0["exerciseCount"],
                                spo2Pct: $0["spo2Pct"], skinTempDevC: $0["skinTempDevC"],
                                respRateBpm: $0["respRateBpm"],
                                steps: $0["steps"], activeKcalEst: $0["activeKcalEst"])
                }
        }
    }

    public func journalEntry(deviceId: String, day: String, question: String) async throws -> JournalEntry? {
        try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT day, question, answeredYes, notes FROM journal
                WHERE deviceId = ? AND day = ? AND question = ?
                """, arguments: [deviceId, day, question])
                .map {
                    JournalEntry(day: $0["day"], question: $0["question"],
                                 answeredYes: ($0["answeredYes"] as Int) != 0, notes: $0["notes"])
                }
        }
    }

    public func appleDailyRow(deviceId: String, day: String) async throws -> AppleDaily? {
        try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT day, steps, activeKcal, basalKcal, vo2max, avgHr, maxHr, walkingHr, weightKg
                FROM appleDaily WHERE deviceId = ? AND day = ?
                """, arguments: [deviceId, day])
                .map {
                    AppleDaily(day: $0["day"], steps: $0["steps"], activeKcal: $0["activeKcal"],
                               basalKcal: $0["basalKcal"], vo2max: $0["vo2max"], avgHr: $0["avgHr"],
                               maxHr: $0["maxHr"], walkingHr: $0["walkingHr"], weightKg: $0["weightKg"])
                }
        }
    }

    public func labMarkerById(_ id: String) async throws -> LabMarkerRow? {
        try syncRead { db in
            try Row.fetchOne(db, sql: "SELECT * FROM labMarker WHERE id = ?", arguments: [id]).map(LabMarkerRow.decode)
        }
    }

    /// All metric-series points for one (deviceId, day) — the day is synced as ONE packed record
    /// carrying every key, so this reads the whole day at once.
    public func metricSeriesForDay(deviceId: String, day: String) async throws -> [MetricPoint] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, key, value FROM metricSeries WHERE deviceId = ? AND day = ?
                """, arguments: [deviceId, day])
                .map { MetricPoint(day: $0["day"], key: $0["key"], value: $0["value"]) }
        }
    }

    /// Distinct days with metric-series rows for a device — the bulk upload enqueues one packed record
    /// per (deviceId, day).
    public func metricSeriesDays(deviceId: String) async throws -> [String] {
        try syncRead { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT day FROM metricSeries WHERE deviceId = ? ORDER BY day ASC
                """, arguments: [deviceId])
        }
    }
}
