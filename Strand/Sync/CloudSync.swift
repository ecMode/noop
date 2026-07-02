import Foundation
import CloudKit
import WhoopStore

/// macOS ⇄ iOS sync over the user's private CloudKit database (one user, their own iCloud).
///
/// Slice 1 syncs **workouts + their GPS routes** end-to-end; the machinery (engine, deterministic
/// record ids, JSON-blob mapping, state persistence, inbound-apply, conflict-safe sends, first-sync
/// bulk upload) is general and later slices add the other rollup types by mapping more `StoreChange`
/// kinds. See CLOUDKIT_SYNC_DESIGN.md.
///
/// Ships INERT until `cloudSync.enabled` is set — constructing the engine begins talking to iCloud.
/// CKSyncEngine requires macOS 14 / iOS 17, both the project minimums, so no `@available` guard.
@MainActor
final class CloudSync {
    static let shared = CloudSync()
    private init() {}

    /// Master gate (UserDefaults). Sync stays off until this is true. Read live so it can be flipped
    /// without a rebuild during testing; later a Settings toggle sets it.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static let enabledKey = "cloudSync.enabled"

    private var engine: CKSyncEngine?
    private var repo: Repository?
    private let meta = RecordMetadataCache()

    private static let stateKey = "cloudSync.stateSerialization"
    private static let zoneCreatedKey = "cloudSync.zoneCreated"
    private static let bulkDoneKey = "cloudSync.bulkUploaded"

    /// Shared CloudKit container id from the `ICloudContainerIdentifier` Info.plist key (NOT
    /// `CKContainer.default()`, whose id derives from the bundle id and differs across the two apps).
    var containerIdentifier: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "ICloudContainerIdentifier") as? String,
              !id.isEmpty, id != "$(ICLOUD_CONTAINER_ID)" else { return nil }
        return id
    }

    // MARK: - Lifecycle

    /// Stand up the engine (no-op unless enabled / already running / container missing). Wires the
    /// store's change sink to enqueue outbound pushes, ensures the record zone exists, and kicks the
    /// one-time bulk upload of existing workouts.
    func startIfEnabled(repo: Repository) {
        guard Self.isEnabled else { NSLog("CloudSync: disabled; not starting."); return }
        guard engine == nil else { return }
        guard let id = containerIdentifier else {
            NSLog("CloudSync: no ICloudContainerIdentifier; cannot start."); return
        }
        self.repo = repo
        let container = CKContainer(identifier: id)
        let config = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: loadState(),
            delegate: self)
        engine = CKSyncEngine(config)
        NSLog("CloudSync: engine started for container \(id).")

        Task { [weak self] in
            guard let self, let store = await repo.storeHandle() else { return }
            await store.setChangeSink { [weak self] changes in
                Task { @MainActor in self?.enqueue(changes) }
            }
            await self.ensureZone()
            await self.bulkUploadIfNeeded(store: store)
        }
    }

    /// Foreground pull (iOS scenePhase `.active`, macOS didBecomeActive). Safe to call when off.
    func fetchChangesInBackground() {
        guard let engine else { return }
        Task { try? await engine.fetchChanges() }
    }

    // MARK: - Outbound enqueue

    /// Turn store change notifications into pending CloudKit record changes (every synced kind).
    private func enqueue(_ changes: [StoreChange]) {
        guard let engine else { return }
        let pending: [CKSyncEngine.PendingRecordZoneChange] = changes.map { c in
            let id = SyncSchema.recordID(kind: c.kind, deviceId: c.deviceId, key: c.key)
            return c.isDelete ? .deleteRecord(id) : .saveRecord(id)
        }
        guard !pending.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: pending)
    }

    private func ensureZone() async {
        guard let engine, !UserDefaults.standard.bool(forKey: Self.zoneCreatedKey) else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncSchema.zoneID))])
    }

    /// One-time push of the existing history across every synced type (the Mac is the data-rich side
    /// that seeds sync). Wide date ranges enumerate all rows; metricSeries + labMarker need a
    /// keys/days-first walk. Idempotent by natural key, so re-running is harmless.
    private func bulkUploadIfNeeded(store: WhoopStore) async {
        guard let engine, !UserDefaults.standard.bool(forKey: Self.bulkDoneKey) else { return }
        let dayLo = "0000-01-01", dayHi = "9999-12-31", bigLimit = 1_000_000
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        func save(_ kind: StoreChange.Kind, _ deviceId: String, _ key: String) {
            pending.append(.saveRecord(SyncSchema.recordID(kind: kind, deviceId: deviceId, key: key)))
        }

        for dev in (try? await store.distinctDeviceIds(.workout)) ?? [] {
            for r in (try? await store.workouts(deviceId: dev, from: 0, to: Int.max, limit: bigLimit)) ?? [] {
                save(.workout, dev, "\(r.startTs)|\(r.sport)")
            }
        }
        for dev in (try? await store.distinctDeviceIds(.sleepSession)) ?? [] {
            for s in (try? await store.sleepSessions(deviceId: dev, from: 0, to: Int.max, limit: bigLimit)) ?? [] {
                save(.sleep, dev, "\(s.startTs)")
            }
        }
        for dev in (try? await store.distinctDeviceIds(.dailyMetric)) ?? [] {
            for d in (try? await store.dailyMetrics(deviceId: dev, from: dayLo, to: dayHi)) ?? [] {
                save(.daily, dev, d.day)
            }
        }
        for dev in (try? await store.distinctDeviceIds(.appleDaily)) ?? [] {
            for a in (try? await store.appleDaily(deviceId: dev, from: dayLo, to: dayHi)) ?? [] {
                save(.appleDaily, dev, a.day)
            }
        }
        for dev in (try? await store.distinctDeviceIds(.journal)) ?? [] {
            for j in (try? await store.journalEntries(deviceId: dev, from: dayLo, to: dayHi)) ?? [] {
                save(.journal, dev, "\(j.day)|\(j.question)")
            }
        }
        for dev in (try? await store.distinctDeviceIds(.metricSeries)) ?? [] {
            for day in (try? await store.metricSeriesDays(deviceId: dev)) ?? [] {
                save(.metricSeries, dev, day)
            }
        }
        for dev in (try? await store.distinctDeviceIds(.labMarker)) ?? [] {
            for k in (try? await store.markerKeysPresent(deviceId: dev)) ?? [] {
                for m in (try? await store.labMarkers(deviceId: dev, markerKey: k)) ?? [] {
                    save(.labMarker, dev, m.id)
                }
            }
        }

        if !pending.isEmpty { engine.state.add(pendingRecordZoneChanges: pending) }
        UserDefaults.standard.set(true, forKey: Self.bulkDoneKey)
        NSLog("CloudSync: queued \(pending.count) existing records for first-sync upload.")
    }

    // MARK: - State persistence

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = UserDefaults.standard.data(forKey: Self.stateKey) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func persistState(_ s: CKSyncEngine.State.Serialization) {
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: Self.stateKey) }
    }

    private func resetLocalSyncState() {
        meta.removeAll()
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.stateKey)
        d.set(false, forKey: Self.zoneCreatedKey)
        d.set(false, forKey: Self.bulkDoneKey)
    }

    // MARK: - Build outbound records

    /// Build CKRecords for pending save ids by reading the current local row (+ route). Records the
    /// row was deleted for since queueing are skipped (engine drops that save). Uses the metadata cache
    /// as the base so an update carries the last-known change tag and saves on the first try.
    private func buildRecords(for ids: [CKRecord.ID]) async -> [CKRecord.ID: CKRecord] {
        guard let store = await repo?.storeHandle() else { return [:] }
        var out: [CKRecord.ID: CKRecord] = [:]
        for id in ids {
            guard let (kind, deviceId, key) = SyncSchema.decodeRecordName(id.recordName) else { continue }
            let base = meta.record(for: id) ?? CKRecord(recordType: kind.recordType, recordID: id)
            switch kind {
            case .workout:
                guard let (startTs, sport) = WorkoutRecord.parseKey(key),
                      let row = try? await store.workout(deviceId: deviceId, startTs: startTs, sport: sport) else { continue }
                let route = RouteStore.load(startTs: startTs, sport: sport)
                out[id] = WorkoutRecord.make(row: row, deviceId: deviceId, route: route, base: base)
            case .sleep:
                guard let startTs = Int(key),
                      let row = try? await store.sleepSession(deviceId: deviceId, startTs: startTs) else { continue }
                out[id] = Payload.encode(row, deviceId: deviceId, into: base)
            case .daily:
                guard let row = try? await store.dailyMetric(deviceId: deviceId, day: key) else { continue }
                out[id] = Payload.encode(row, deviceId: deviceId, into: base)
            case .appleDaily:
                guard let row = try? await store.appleDailyRow(deviceId: deviceId, day: key) else { continue }
                out[id] = Payload.encode(row, deviceId: deviceId, into: base)
            case .journal:
                guard let (day, question) = SyncSchema.splitPipe(key),
                      let row = try? await store.journalEntry(deviceId: deviceId, day: day, question: question) else { continue }
                out[id] = Payload.encode(row, deviceId: deviceId, into: base)
            case .metricSeries:
                let pts = (try? await store.metricSeriesForDay(deviceId: deviceId, day: key)) ?? []
                guard !pts.isEmpty else { continue }   // day cleared since queued → skip
                let dict = Dictionary(pts.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
                out[id] = Payload.encode(dict, deviceId: deviceId, into: base)
            case .labMarker:
                guard let row = try? await store.labMarkerById(key) else { continue }
                out[id] = Payload.encode(row, deviceId: deviceId, into: base)
            }
        }
        return out
    }

    // MARK: - Apply inbound

    private func applyFetched(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        guard let store = await repo?.storeHandle() else { return }
        var touched = false
        for mod in event.modifications {
            let record = mod.record
            meta.update(record)
            guard let (kind, deviceId, key) = SyncSchema.decodeRecordName(record.recordID.recordName) else { continue }
            switch kind {
            case .workout:
                guard let (dev, row, route) = WorkoutRecord.decode(record) else { continue }
                await store.applyingRemoteChanges { _ = try? await store.upsertWorkouts([row], deviceId: dev) }
                if let route { RouteStore.store(route, startTs: row.startTs, sport: row.sport) }
            case .sleep:
                guard let row = Payload.decode(CachedSleepSession.self, from: record) else { continue }
                await store.applyingRemoteChanges { _ = try? await store.upsertSleepSessions([row], deviceId: deviceId) }
            case .daily:
                guard let row = Payload.decode(DailyMetric.self, from: record) else { continue }
                await store.applyingRemoteChanges { _ = try? await store.upsertDailyMetrics([row], deviceId: deviceId) }
            case .appleDaily:
                guard let row = Payload.decode(AppleDaily.self, from: record) else { continue }
                await store.applyingRemoteChanges { _ = try? await store.upsertAppleDaily([row], deviceId: deviceId) }
            case .journal:
                guard let row = Payload.decode(JournalEntry.self, from: record) else { continue }
                await store.applyingRemoteChanges { _ = try? await store.upsertJournal([row], deviceId: deviceId) }
            case .metricSeries:
                guard let dict = Payload.decode([String: Double].self, from: record) else { continue }
                let pts = dict.map { MetricPoint(day: key, key: $0.key, value: $0.value) }
                await store.applyingRemoteChanges { _ = try? await store.upsertMetricSeries(pts, deviceId: deviceId) }
            case .labMarker:
                guard let row = Payload.decode(LabMarkerRow.self, from: record) else { continue }
                await store.applyingRemoteChanges { _ = try? await store.upsertLabMarkers([row]) }
            }
            touched = true
        }
        for del in event.deletions {
            meta.remove(del.recordID)
            guard let (kind, deviceId, key) = SyncSchema.decodeRecordName(del.recordID.recordName) else { continue }
            switch kind {
            case .workout:
                guard let (startTs, sport) = WorkoutRecord.parseKey(key) else { continue }
                await store.applyingRemoteChanges { _ = try? await store.deleteWorkouts(deviceId: deviceId, sport: sport, from: startTs, to: startTs) }
                RouteStore.remove(startTs: startTs, sport: sport)
            case .sleep:
                guard let startTs = Int(key) else { continue }
                await store.applyingRemoteChanges { _ = try? await store.deleteSleepSession(deviceId: deviceId, startTs: startTs) }
            case .journal:
                guard let (day, question) = SyncSchema.splitPipe(key) else { continue }
                await store.applyingRemoteChanges { _ = try? await store.deleteJournal(deviceId: deviceId, day: day, question: question) }
            case .labMarker:
                await store.applyingRemoteChanges { _ = try? await store.deleteLabMarker(id: key) }
            case .daily, .appleDaily, .metricSeries:
                break   // no user-delete path for these; deletes aren't emitted for them
            }
            touched = true
        }
        if touched { await repo?.refresh() }
    }

    private func handleSent(_ event: CKSyncEngine.Event.SentRecordZoneChanges) async {
        for saved in event.savedRecords { meta.update(saved) }
        for fail in event.failedRecordSaves {
            let record = fail.record
            if fail.error.code == .serverRecordChanged, let server = fail.error.serverRecord {
                // Last-write-wins: keep our local values, re-base on the server's change tag, re-queue.
                meta.update(server)
                engine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            } else if fail.error.code == .zoneNotFound {
                UserDefaults.standard.set(false, forKey: Self.zoneCreatedKey)
                await ensureZone()
                engine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            } else {
                NSLog("CloudSync: save failed \(record.recordID.recordName): \(fail.error.localizedDescription)")
            }
        }
        for id in event.deletedRecordIDs { meta.remove(id) }
    }

    private func handleSentDatabase(_ event: CKSyncEngine.Event.SentDatabaseChanges) {
        if !event.savedZones.isEmpty { UserDefaults.standard.set(true, forKey: Self.zoneCreatedKey) }
    }

    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) {
        switch event.changeType {
        case .signIn:
            break
        case .signOut, .switchAccounts:
            // Different iCloud account: drop local sync bookkeeping so we don't mix data. Local DB rows
            // stay; they'll re-upload to the new account on the next bulk pass.
            resetLocalSyncState()
        @unknown default:
            break
        }
    }
}

extension CloudSync: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let e):
            await persistState(e.stateSerialization)
        case .accountChange(let e):
            await handleAccountChange(e)
        case .fetchedRecordZoneChanges(let e):
            await applyFetched(e)
        case .sentRecordZoneChanges(let e):
            await handleSent(e)
        case .sentDatabaseChanges(let e):
            await handleSentDatabase(e)
        case .fetchedDatabaseChanges, .willFetchChanges, .didFetchChanges,
             .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .willSendChanges, .didSendChanges:
            break
        @unknown default:
            break
        }
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let changes = syncEngine.state.pendingRecordZoneChanges
        guard !changes.isEmpty else { return nil }
        let saveIDs: [CKRecord.ID] = changes.compactMap {
            if case .saveRecord(let id) = $0 { return id } else { return nil }
        }
        let built = await buildRecords(for: saveIDs)
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { built[$0] }
    }
}
