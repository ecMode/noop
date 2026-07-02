import Foundation
import CloudKit

/// Remembers each synced record's CloudKit system fields (record id + change tag) so an outbound save
/// starts from the last-known server version. Without this, every update would build a tag-less record,
/// CloudKit would reject it as `serverRecordChanged`, and we'd need a second round-trip. With it, an
/// update saves on the first try.
///
/// Only system fields are stored (via `CKRecord.encodeSystemFields`), never the row data — that's read
/// live from the store when a record is built. Backed by a single JSON file in Application Support
/// (rollup volumes are small; a few hundred bytes per record). Main-actor: only CloudSync touches it.
@MainActor
final class RecordMetadataCache {
    private var byName: [String: Data] = [:]
    private let fileURL: URL

    init(filename: String = "cloudSyncRecordMeta.json") {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.fileURL = base.appendingPathComponent(filename)
        load()
    }

    /// The last-known server record (system fields only) for this id, or nil if we've never seen it.
    func record(for id: CKRecord.ID) -> CKRecord? {
        guard let data = byName[id.recordName] else { return nil }
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        let record = CKRecord(coder: coder)
        coder.finishDecoding()
        return record
    }

    /// Remember (or refresh) a record's system fields — call on every fetched + saved + server-conflict
    /// record so the change tag stays current.
    func update(_ record: CKRecord) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        byName[record.recordID.recordName] = coder.encodedData
        save()
    }

    func remove(_ id: CKRecord.ID) {
        if byName.removeValue(forKey: id.recordName) != nil { save() }
    }

    func removeAll() {
        byName.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Data].self, from: data) else { return }
        byName = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(byName) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
