import Foundation
import Combine
import WhoopProtocol

/// The orchestrator for the Strava integration: owns credentials, runs the OAuth connect flow, and
/// auto-uploads finished workouts as TCX with a durable retry queue. A single shared instance so the
/// `endWorkout` hook (AppModel) and the Settings UI both talk to the same state without threading a
/// dependency through app init. On-device, opt-in, bring-your-own Strava app.
@MainActor
final class StravaService: ObservableObject {

    static let shared = StravaService()

    // Published state the Settings UI binds to.
    @Published private(set) var hasApp = false        // client id + secret configured
    @Published private(set) var isConnected = false   // holds usable tokens
    @Published private(set) var busy = false
    @Published private(set) var status = ""           // last human-readable outcome
    @Published var autoUpload: Bool {
        didSet { UserDefaults.standard.set(autoUpload, forKey: Keys.autoUpload) }
    }

    private var creds: StravaCredentials?
    private var authFlow: StravaAuthFlow?
    private let session = URLSession.shared

    private enum Keys {
        static let autoUpload = "strava.autoUpload"
        static let queue = "strava.uploadQueue"
    }

    private init() {
        autoUpload = UserDefaults.standard.object(forKey: Keys.autoUpload) as? Bool ?? false
        creds = StravaCredentialStore.load()
        refreshFlags()
        // Flush anything left queued by a previous session (e.g. a run recorded with no signal) once we're
        // connected. Fires when the singleton is first touched (opening Settings or ending a workout).
        if isConnected { Task { await processQueue() } }
    }

    private func refreshFlags() {
        hasApp = creds?.hasApp ?? false
        isConnected = creds?.isConnected ?? false
    }

    // MARK: Configuration

    /// Store the user's own Strava app id/secret (from strava.com/settings/api). Clears any existing
    /// tokens if the app changed, since old tokens belong to the old app.
    func saveApp(clientId: String, clientSecret: String) {
        let id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        var c = creds ?? StravaCredentials(clientId: "", clientSecret: "")
        let changed = c.clientId != id || c.clientSecret != secret
        c.clientId = id
        c.clientSecret = secret
        if changed { c.accessToken = nil; c.refreshToken = nil; c.expiresAt = nil }
        persist(c)
        status = "Strava app saved."
    }

    /// Remove everything (tokens + app id/secret) from the Keychain.
    func forget() {
        StravaCredentialStore.clear()
        creds = nil
        refreshFlags()
        status = "Disconnected from Strava."
    }

    /// Drop just the OAuth tokens (keep the app config so reconnect is one tap).
    func disconnect() {
        guard var c = creds else { return }
        c.accessToken = nil; c.refreshToken = nil; c.expiresAt = nil
        persist(c)
        status = "Disconnected from Strava."
    }

    // MARK: Connect (OAuth)

    /// Present the Strava consent screen and store the resulting tokens.
    func connect() async {
        guard let c = creds, c.hasApp else { status = "Add your Strava app first."; return }
        busy = true; defer { busy = false }
        let flow = StravaAuthFlow()
        authFlow = flow
        do {
            let code = try await flow.authorize(clientId: c.clientId)
            let tokens = try await StravaClient.exchange(clientId: c.clientId, clientSecret: c.clientSecret,
                                                         code: code, session: session)
            var updated = c
            updated.accessToken = tokens.accessToken
            updated.refreshToken = tokens.refreshToken
            updated.expiresAt = tokens.expiresAt
            persist(updated)
            status = "Connected to Strava."
            await processQueue()   // flush anything that queued while disconnected
        } catch {
            status = error.localizedDescription
        }
        authFlow = nil
    }

    /// A valid access token, refreshing (and persisting the rotated tokens) if it's expired/near-expiry.
    private func validAccessToken() async throws -> String {
        guard var c = creds, c.isConnected else { throw StravaClient.StravaError.badResponse }
        if c.needsRefresh(now: Date().timeIntervalSince1970) {
            let t = try await StravaClient.refresh(clientId: c.clientId, clientSecret: c.clientSecret,
                                                   refreshToken: c.refreshToken ?? "", session: session)
            c.accessToken = t.accessToken; c.refreshToken = t.refreshToken; c.expiresAt = t.expiresAt
            persist(c)
        }
        return creds?.accessToken ?? ""
    }

    // MARK: Auto-upload (called from AppModel.endWorkout)

    /// Build a TCX for a finished workout and queue it for upload if auto-upload is on and we're
    /// connected. Safe to call for every workout — it no-ops when disabled/disconnected.
    func autoUploadIfEnabled(sport: String, start: Date, end: Date, distanceMeters: Double,
                             calories: Int, samples: [HRSample],
                             track: [(tMs: Int64, lat: Double, lon: Double)]) {
        guard autoUpload, isConnected else { return }
        let points = Self.buildPoints(hr: samples, track: track)
        guard !points.isEmpty else { return }
        let tcx = TCXBuilder.build(sport: sport, start: start, totalSeconds: end.timeIntervalSince(start),
                                   distanceMeters: distanceMeters, calories: calories, points: points)
        let externalId = "noop-\(Int(start.timeIntervalSince1970))"
        enqueue(tcx: tcx, name: sport, externalId: externalId)
        Task { await processQueue() }
    }

    // MARK: Durable upload queue

    /// One pending upload: metadata in UserDefaults, the TCX bytes in a sidecar file so a large run
    /// doesn't bloat the defaults plist.
    private struct QueueEntry: Codable {
        let externalId: String
        let name: String
        let file: String        // filename under the queue directory
    }

    private static var queueDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("StravaQueue", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadQueue() -> [QueueEntry] {
        guard let data = UserDefaults.standard.data(forKey: Keys.queue),
              let q = try? JSONDecoder().decode([QueueEntry].self, from: data) else { return [] }
        return q
    }

    private func saveQueue(_ q: [QueueEntry]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(q), forKey: Keys.queue)
    }

    private func enqueue(tcx: Data, name: String, externalId: String) {
        var q = loadQueue()
        guard !q.contains(where: { $0.externalId == externalId }) else { return }   // de-dup
        let file = "\(externalId).tcx"
        try? tcx.write(to: Self.queueDir.appendingPathComponent(file))
        q.append(QueueEntry(externalId: externalId, name: name, file: file))
        saveQueue(q)
    }

    private func remove(_ entry: QueueEntry) {
        try? FileManager.default.removeItem(at: Self.queueDir.appendingPathComponent(entry.file))
        saveQueue(loadQueue().filter { $0.externalId != entry.externalId })
    }

    /// Try to upload every queued workout. Successes and permanent rejections are removed; transient
    /// failures (offline, token) stay queued for the next call (connect / app foreground). Public so the
    /// app can flush on launch/foreground.
    func processQueue() async {
        guard isConnected else { return }
        for entry in loadQueue() {
            let url = Self.queueDir.appendingPathComponent(entry.file)
            guard let tcx = try? Data(contentsOf: url) else { remove(entry); continue }
            do {
                let token = try await validAccessToken()
                let uploadId = try await StravaClient.upload(tcx: tcx, name: entry.name,
                                                             externalId: entry.externalId,
                                                             accessToken: token, session: session)
                try await pollUntilDone(uploadId: uploadId, token: token)
                remove(entry)
                status = "Uploaded \(entry.name) to Strava."
            } catch StravaClient.StravaError.uploadRejected(let msg) {
                // A bad file will never succeed — drop it rather than retry forever, but surface why.
                remove(entry)
                status = "Strava skipped \(entry.name): \(msg)"
            } catch {
                // Transient (offline / auth) — keep it queued and stop this pass.
                status = "Strava upload pending (will retry): \(error.localizedDescription)"
                break
            }
        }
    }

    /// Poll an upload a handful of times until Strava finishes processing it. A still-processing upload
    /// after the budget is treated as accepted (it usually completes server-side) so we don't re-queue.
    private func pollUntilDone(uploadId: Int, token: String) async throws {
        for _ in 0..<6 {
            let s = try await StravaClient.uploadStatus(id: uploadId, accessToken: token, session: session)
            if let err = s.error { throw StravaClient.StravaError.uploadRejected(err) }
            if s.activityId != nil { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)   // 2s between polls
        }
    }

    // MARK: TCX point merge

    /// Merge timestamped HR samples with the timestamped GPS track into TCX trackpoints. GPS is the
    /// spatial spine (one point per fix, nearest HR attached by second); with no GPS we emit HR-only
    /// points so an indoor run still uploads a heart-rate trace.
    static func buildPoints(hr: [HRSample],
                            track: [(tMs: Int64, lat: Double, lon: Double)]) -> [TCXBuilder.Point] {
        if track.isEmpty {
            return hr.sorted { $0.ts < $1.ts }.map {
                TCXBuilder.Point(time: Date(timeIntervalSince1970: Double($0.ts)), lat: nil, lon: nil, hr: $0.bpm)
            }
        }
        var hrBySecond: [Int: Int] = [:]
        for s in hr { hrBySecond[s.ts] = s.bpm }
        func nearestHR(_ second: Int) -> Int? {
            for delta in 0...10 {
                if let v = hrBySecond[second] { return v }
                if let v = hrBySecond[second - delta] { return v }
                if let v = hrBySecond[second + delta] { return v }
            }
            return nil
        }
        return track.map { p in
            let sec = Int((Double(p.tMs) / 1000.0).rounded())
            return TCXBuilder.Point(time: Date(timeIntervalSince1970: Double(p.tMs) / 1000.0),
                                    lat: p.lat, lon: p.lon, hr: nearestHR(sec))
        }
    }

    // MARK: Storage

    private func persist(_ c: StravaCredentials) {
        creds = c
        StravaCredentialStore.save(c)
        refreshFlags()
    }
}
