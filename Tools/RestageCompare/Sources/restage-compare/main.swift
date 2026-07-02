import Foundation
import StrandAnalytics
import WhoopStore
import WhoopProtocol

// Re-detect + re-stage the sleep in the LOCALLY-present raw streams through V1 and V2, from the SAME
// signal, and print both hypnograms. Read-only. CloudKit sync ships computed sessions, not raw streams,
// so the raw signal on this Mac may be a different night than a synced session row — this tool stages
// whatever raw data is actually here (deviceId `my-whoop`, the bare strap partition).
//
//   NOOP_DB_PATH env  — sqlite path
//   argv: <deviceId> <tzOffsetSeconds>   (defaults: my-whoop, -25200 = PDT)

let env = ProcessInfo.processInfo.environment
let home = FileManager.default.homeDirectoryForCurrentUser.path
let dbPath = env["NOOP_DB_PATH"]
    ?? "\(home)/Library/Containers/com.ecmode.loop/Data/Library/Application Support/OpenWhoop/whoop.sqlite"

// argv: <startTs> <endTs> <deviceId>   (defaults: last night's stored window, my-whoop raw partition)
let a = CommandLine.arguments
let start    = a.count > 1 ? Int(a[1])! : 1_782_975_504
let end      = a.count > 2 ? Int(a[2])! : 1_782_997_845
let deviceId = a.count > 3 ? a[3] : "my-whoop"

func totals(_ segs: [StageSegment]) -> (wake: Double, light: Double, deep: Double, rem: Double) {
    var w = 0.0, l = 0.0, d = 0.0, r = 0.0
    for s in segs {
        let m = Double(s.end - s.start) / 60.0
        switch s.stage {
        case "wake", "awake": w += m
        case "light": l += m
        case "deep": d += m
        case "rem": r += m
        default: break
        }
    }
    return (w, l, d, r)
}

func fmtUTC(_ ts: Int) -> String {
    let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: Date(timeIntervalSince1970: Double(ts))) + "Z"
}

func report(_ name: String, _ segs: [StageSegment]) {
    let t = totals(segs)
    let tst = t.light + t.deep + t.rem
    func pct(_ v: Double) -> String { tst > 0 ? String(format: "%5.1f%%", 100 * v / tst) : "  n/a" }
    print("  \(name): TST \(String(format: "%.0f", tst))m  |  " +
          "light \(String(format: "%.0f", t.light))m \(pct(t.light))  " +
          "deep \(String(format: "%.0f", t.deep))m \(pct(t.deep))  " +
          "rem \(String(format: "%.0f", t.rem))m \(pct(t.rem))  " +
          "wake \(String(format: "%.0f", t.wake))m")
}

func longest(_ sessions: [SleepSession]) -> SleepSession? {
    sessions.max { ($0.end - $0.start) < ($1.end - $1.start) }
}

let task = Task { () -> Void in
    let store = try await WhoopStore(path: dbPath)
    // Mirror Repository.restageFromRaw: read [start-1h, end+1h] under the raw partition.
    let lo = start - 3_600, hi = end + 3_600
    let grav = (try? await store.gravitySamples(deviceId: deviceId, from: lo, to: hi, limit: 500_000)) ?? []
    let hr   = (try? await store.hrSamples(deviceId: deviceId, from: lo, to: hi, limit: 500_000)) ?? []
    let rr   = (try? await store.rrIntervals(deviceId: deviceId, from: lo, to: hi, limit: 500_000)) ?? []
    let resp = (try? await store.respSamples(deviceId: deviceId, from: lo, to: hi, limit: 500_000)) ?? []

    print("db: \(dbPath)")
    print("window: \(fmtUTC(start)) … \(fmtUTC(end))  (\(String(format: "%.2f", Double(end-start)/3600))h)  device=\(deviceId)")
    print("streams in [start-1h, end+1h]: grav=\(grav.count) hr=\(hr.count) rr=\(rr.count) resp=\(resp.count)")

    // Stage the SAME fixed window with both engines — isolates the staging recipe from detection.
    let v1 = SleepStager.stageSession(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: resp)
    let v2 = SleepStagerV2.stageSession(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: resp)
    print()
    report("V1 (shipped default)", v1)
    report("V2 (experimental MG)", v2)
}

let sem = DispatchSemaphore(value: 0)
Task { do { try await task.value } catch { print("ERROR: \(error)") }; sem.signal() }
sem.wait()
