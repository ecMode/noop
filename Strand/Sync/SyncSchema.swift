import Foundation
import CloudKit
import WhoopStore

/// Maps the store's natural-keyed rows to CloudKit records and back. Two design choices keep this small
/// and robust (see CLOUDKIT_SYNC_DESIGN.md):
///
/// 1. **Deterministic record ids from the natural key.** Two devices that compute the same row produce
///    the SAME record id, so they converge instead of duplicating. The id is a reversible hex encoding
///    of "kind\ndeviceId\nkey" — hex because CloudKit record names allow only `[A-Za-z0-9._-]` (no
///    spaces/pipes, which sport names and some keys contain). Reversible so `nextRecordZoneChangeBatch`
///    can turn a pending id back into the row to read.
///
/// 2. **Model stored as a JSON blob in one field.** The models are already `Codable`; a blob avoids
///    hand-mapping ~90 fields and tolerates upstream adding optional fields (old records still decode).
///    We never query by field — CKSyncEngine fetches the whole zone — so nothing is lost.
enum SyncSchema {
    /// One custom zone holds every synced record type. A custom zone (not the default zone) is required
    /// for CKSyncEngine's change-tracking on the private database.
    static let zoneName = "NoopSync"
    static var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName) }

    // MARK: Record name <-> natural key

    /// Reversible, CloudKit-safe record name for a natural-keyed row.
    static func recordName(kind: StoreChange.Kind, deviceId: String, key: String) -> String {
        let joined = "\(kind.rawValue)\n\(deviceId)\n\(key)"
        return Data(joined.utf8).map { String(format: "%02x", $0) }.joined()
    }

    /// Reverse `recordName` back to (kind, deviceId, key). Returns nil on any malformed name.
    static func decodeRecordName(_ name: String) -> (kind: StoreChange.Kind, deviceId: String, key: String)? {
        let chars = Array(name)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i]) + String(chars[i + 1]), radix: 16) else { return nil }
            bytes.append(b); i += 2
        }
        guard let joined = String(bytes: bytes, encoding: .utf8) else { return nil }
        let parts = joined.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let kind = StoreChange.Kind(rawValue: parts[0]) else { return nil }
        return (kind, parts[1], parts[2])
    }

    static func recordID(kind: StoreChange.Kind, deviceId: String, key: String) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName(kind: kind, deviceId: deviceId, key: key), zoneID: zoneID)
    }

    /// Split a "day|question" (journal) key on its FIRST pipe. Day is yyyy-MM-dd (no pipe); the question
    /// takes the remainder, so a question containing a pipe still round-trips.
    static func splitPipe(_ key: String) -> (String, String)? {
        guard let sep = key.firstIndex(of: "|") else { return nil }
        return (String(key[key.startIndex..<sep]), String(key[key.index(after: sep)...]))
    }
}

extension StoreChange.Kind {
    /// CloudKit record type per kind. Cosmetic (we decode by parsing the record name, which embeds the
    /// kind) but CloudKit requires a type string per record.
    var recordType: String {
        switch self {
        case .sleep: return "Sleep"
        case .daily: return "Daily"
        case .metricSeries: return "MetricSeries"
        case .workout: return "Workout"
        case .journal: return "Journal"
        case .appleDaily: return "AppleDaily"
        case .labMarker: return "LabMarker"
        }
    }
}

/// Dismiss-tombstone kinds. Unlike the natural-keyed rows, these are user-INTENT sets ("I deleted this
/// auto-detected sleep/workout") kept in Repository/WorkoutSource UserDefaults, NOT the store. Each
/// syncs as ONE singleton CKRecord holding the "startTs:endTs" token array; the merge is a UNION (a
/// tombstone never un-happens), so a deletion of a re-derivable item sticks across devices instead of
/// being resurrected by the other device's detector.
enum TombstoneKind: CaseIterable {
    case sleep, workout

    /// Fixed, ASCII-safe record name (not the hex natural-key scheme — these are singletons).
    var recordName: String {
        switch self {
        case .sleep: return "tombstone_sleep"
        case .workout: return "tombstone_workout"
        }
    }
    var recordType: String {
        switch self {
        case .sleep: return "DismissedSleep"
        case .workout: return "DismissedWorkout"
        }
    }
    /// The UserDefaults key holding the "startTs:endTs" token array this record mirrors.
    var defaultsKey: String {
        switch self {
        case .sleep: return Repository.dismissedSleepDefaultsKey
        case .workout: return WorkoutSource.dismissedDefaultsKey
        }
    }
    var recordID: CKRecord.ID { CKRecord.ID(recordName: recordName, zoneID: SyncSchema.zoneID) }

    init?(recordName: String) {
        switch recordName {
        case "tombstone_sleep": self = .sleep
        case "tombstone_workout": self = .workout
        default: return nil
        }
    }
}

/// Generic JSON-blob payload for the rollup record types whose whole model is `Codable` (everything
/// except workouts, which also carry a route). `deviceId` is a top-level field for readability; the
/// model itself is one `payload` string.
enum Payload {
    static func encode<T: Encodable>(_ model: T, deviceId: String, into base: CKRecord) -> CKRecord {
        base["deviceId"] = deviceId as CKRecordValue
        if let data = try? JSONEncoder().encode(model) {
            base["payload"] = String(decoding: data, as: UTF8.self) as CKRecordValue
        }
        return base
    }

    static func decode<T: Decodable>(_ type: T.Type, from record: CKRecord) -> T? {
        guard let payload = record["payload"] as? String,
              let model = try? JSONDecoder().decode(T.self, from: Data(payload.utf8)) else { return nil }
        return model
    }
}

// MARK: - Workout record (slice 1)

/// Encode/decode a workout row (+ its GPS route polyline) to a CKRecord. The route lives in
/// `RouteStore` (UserDefaults), keyed by the same (startTs, sport), so we join it here on the way out
/// and re-store it on the way in — that's how a phone run's map reaches the Mac.
enum WorkoutRecord {
    static let recordType = "Workout"

    static func recordID(deviceId: String, startTs: Int, sport: String) -> CKRecord.ID {
        SyncSchema.recordID(kind: .workout, deviceId: deviceId, key: "\(startTs)|\(sport)")
    }

    /// Parse a workout record name's key ("startTs|sport") into its parts.
    static func parseKey(_ key: String) -> (startTs: Int, sport: String)? {
        guard let sep = key.firstIndex(of: "|") else { return nil }
        guard let startTs = Int(key[key.startIndex..<sep]) else { return nil }
        let sport = String(key[key.index(after: sep)...])
        return (startTs, sport)
    }

    /// Build the CKRecord onto `base` (which carries the last-known server change tag when we have it).
    static func make(row: WorkoutRow, deviceId: String, route: WorkoutRoute?, base: CKRecord) -> CKRecord {
        base["deviceId"] = deviceId as CKRecordValue
        if let json = try? JSONEncoder().encode(row) {
            base["payload"] = String(decoding: json, as: UTF8.self) as CKRecordValue
        }
        if let route {
            base["routePolyline"] = route.polyline as CKRecordValue
            base["routeDistanceM"] = route.distanceM as CKRecordValue
        } else {
            base["routePolyline"] = nil
            base["routeDistanceM"] = nil
        }
        return base
    }

    static func decode(_ record: CKRecord) -> (deviceId: String, row: WorkoutRow, route: WorkoutRoute?)? {
        guard let deviceId = record["deviceId"] as? String,
              let payload = record["payload"] as? String,
              let row = try? JSONDecoder().decode(WorkoutRow.self, from: Data(payload.utf8)) else { return nil }
        var route: WorkoutRoute?
        if let poly = record["routePolyline"] as? String, let dist = record["routeDistanceM"] as? Double {
            route = WorkoutRoute(polyline: poly, distanceM: dist)
        }
        return (deviceId, row, route)
    }
}
