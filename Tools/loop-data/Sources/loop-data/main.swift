import Foundation

// loop-data — a read-only exporter for the Loop app's on-device store (whoop.sqlite).
// Emits workouts / sleeps / daily metrics as JSON (default), NDJSON, or a markdown table.
// The JSON shape here is the stable contract for companion projects; see docs/DATA_ACCESS.md.

// MARK: - Defaults & helpers

/// Where the sandboxed macOS Loop build keeps its store. Overridable with --db.
let defaultDBPath = NSString(string:
    "~/Library/Containers/com.ecmode.loop/Data/Library/Application Support/OpenWhoop/whoop.sqlite"
).expandingTildeInPath

let localCal: Calendar = {
    var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c
}()

let isoOut: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = .current
    return f
}()

let dayParser: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"
    return f
}()

/// A `yyyy-MM-dd` string → local start-of-day unix seconds.
func startOfDayEpoch(_ day: String) throws -> Int64 {
    guard let d = dayParser.date(from: day) else { throw CLIError("bad date '\(day)' (use yyyy-MM-dd)") }
    return Int64(localCal.startOfDay(for: d).timeIntervalSince1970)
}

/// unix seconds → local ISO8601, or NSNull if the value is missing.
func isoOrNull(_ v: Any?) -> Any {
    guard let ts = (v as? Int64) ?? (v as? Int).map(Int64.init) else { return NSNull() }
    return isoOut.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
}

/// Parse an embedded JSON string column (zonesJSON / stagesJSON) into inline JSON; NSNull if absent/invalid.
func inlineJSON(_ v: Any?) -> Any {
    guard let s = v as? String, let data = s.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
    return obj
}

// MARK: - Arg parsing

struct Args {
    var command = ""
    var flags: [String: String] = [:]
    var flagSet: Set<String> = []
    func str(_ k: String) -> String? { flags[k] }
    func has(_ k: String) -> Bool { flagSet.contains(k) }
}

func parseArgs(_ argv: [String]) -> Args {
    var a = Args()
    var it = argv.makeIterator()
    _ = it.next() // executable path
    var rest: [String] = []
    while let t = it.next() { rest.append(t) }
    var i = 0
    while i < rest.count {
        let t = rest[i]
        if t.hasPrefix("--") {
            let key = String(t.dropFirst(2))
            // boolean flags (no value): pretty, compact, help
            if ["pretty", "compact", "help"].contains(key) {
                a.flagSet.insert(key)
            } else if i + 1 < rest.count, !rest[i + 1].hasPrefix("--") {
                a.flags[key] = rest[i + 1]; a.flagSet.insert(key); i += 1
            } else {
                a.flagSet.insert(key) // valueless unknown flag
            }
        } else if a.command.isEmpty {
            a.command = t
        }
        i += 1
    }
    return a
}

// MARK: - Output

enum Format { case json, ndjson, markdown }

func emit(_ rows: [[String: Any]], columns: [String], format: Format, pretty: Bool) throws {
    switch format {
    case .json:
        var opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { opts.insert(.prettyPrinted) }
        let data = try JSONSerialization.data(withJSONObject: rows, options: opts)
        FileHandle.standardOutput.write(data)
        print()
    case .ndjson:
        for r in rows {
            let data = try JSONSerialization.data(withJSONObject: r, options: [.sortedKeys, .withoutEscapingSlashes])
            FileHandle.standardOutput.write(data); print()
        }
    case .markdown:
        print("| " + columns.joined(separator: " | ") + " |")
        print("|" + columns.map { _ in " --- " }.joined(separator: "|") + "|")
        for r in rows {
            let cells = columns.map { col -> String in
                switch r[col] {
                case let s as String: return s.replacingOccurrences(of: "|", with: "\\|")
                case let i as Int64:  return String(i)
                case let d as Double: return String(format: "%g", d)
                case is NSNull, nil:  return ""
                default:              return "\(r[col]!)"
                }
            }
            print("| " + cells.joined(separator: " | ") + " |")
        }
    }
}

// MARK: - Commands

func timeRange(_ args: Args) throws -> (from: Int64, to: Int64) {
    let from = try args.str("since").map(startOfDayEpoch) ?? 0
    // --until is inclusive of that whole day, so advance to next midnight and use `< to`.
    let to = try args.str("until").map { try startOfDayEpoch($0) + 86_400 } ?? Int64(Date().timeIntervalSince1970) + 86_400
    return (from, to)
}

func whereSource(_ args: Args, _ sql: inout String, _ params: inout [Any]) {
    if let src = args.str("source") { sql += " AND source = ?"; params.append(src) }
    if let dev = args.str("device") { sql += " AND deviceId = ?"; params.append(dev) }
}

func runWorkouts(_ db: SQLiteReader, _ args: Args) throws -> ([[String: Any]], [String]) {
    let (from, to) = try timeRange(args)
    var sql = """
        SELECT deviceId, startTs, endTs, sport, source, durationS, energyKcal, avgHr, maxHr,
               strain, distanceM, zonesJSON, notes FROM workout
        WHERE startTs >= ? AND startTs < ?
        """
    var params: [Any] = [from, to]
    whereSource(args, &sql, &params)
    sql += " ORDER BY startTs ASC LIMIT ?"
    params.append(Int(args.str("limit") ?? "100000") ?? 100_000)

    let rows = try db.rows(sql, params).map { r -> [String: Any] in
        var o = r
        o["start"] = isoOrNull(r["startTs"]); o["end"] = isoOrNull(r["endTs"])
        o["zones"] = inlineJSON(r["zonesJSON"]); o.removeValue(forKey: "zonesJSON")
        return o
    }
    let cols = ["start", "sport", "source", "durationS", "distanceM", "avgHr", "maxHr", "strain"]
    return (rows, cols)
}

func runSleeps(_ db: SQLiteReader, _ args: Args) throws -> ([[String: Any]], [String]) {
    let (from, to) = try timeRange(args)
    var sql = """
        SELECT deviceId, startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON,
               userEdited, startTsAdjusted FROM sleepSession
        WHERE startTs >= ? AND startTs < ?
        """
    var params: [Any] = [from, to]
    if let dev = args.str("device") { sql += " AND deviceId = ?"; params.append(dev) }
    sql += " ORDER BY startTs ASC LIMIT ?"
    params.append(Int(args.str("limit") ?? "100000") ?? 100_000)

    let rows = try db.rows(sql, params).map { r -> [String: Any] in
        var o = r
        o["start"] = isoOrNull(r["startTs"]); o["end"] = isoOrNull(r["endTs"])
        if let s = r["startTs"] as? Int64, let e = r["endTs"] as? Int64 {
            o["durationMin"] = Double(e - s) / 60.0
        }
        o["userEdited"] = ((r["userEdited"] as? Int64) ?? 0) != 0
        o["stages"] = inlineJSON(r["stagesJSON"]); o.removeValue(forKey: "stagesJSON")
        return o
    }
    let cols = ["start", "end", "durationMin", "efficiency", "restingHr", "avgHrv", "userEdited"]
    return (rows, cols)
}

func runDaily(_ db: SQLiteReader, _ args: Args) throws -> ([[String: Any]], [String]) {
    let since = args.str("since") ?? "0000-00-00"
    let until = args.str("until") ?? "9999-99-99"
    var sql = """
        SELECT deviceId, day, totalSleepMin, efficiency, deepMin, remMin, lightMin, disturbances,
               restingHr, avgHrv, recovery, strain, exerciseCount, spo2Pct, skinTempDevC,
               respRateBpm, steps, activeKcalEst FROM dailyMetric
        WHERE day >= ? AND day <= ?
        """
    var params: [Any] = [since, until]
    if let dev = args.str("device") { sql += " AND deviceId = ?"; params.append(dev) }
    sql += " ORDER BY day ASC LIMIT ?"
    params.append(Int(args.str("limit") ?? "100000") ?? 100_000)

    let rows = try db.rows(sql, params)
    let cols = ["day", "deviceId", "recovery", "strain", "avgHrv", "restingHr", "totalSleepMin", "steps"]
    return (rows, cols)
}

/// Discover what device ids / sources exist, so `--source`/`--device` filters can be chosen.
func runDevices(_ db: SQLiteReader) throws -> ([[String: Any]], [String]) {
    var out: [[String: Any]] = []
    for (table, hasSource) in [("workout", true), ("sleepSession", false), ("dailyMetric", false)] {
        let group = hasSource ? "deviceId, source" : "deviceId"
        let cols = hasSource ? "deviceId, source" : "deviceId, NULL AS source"
        let rows = try db.rows("SELECT \(cols), count(*) AS rows FROM \(table) GROUP BY \(group) ORDER BY rows DESC")
        for r in rows {
            out.append(["table": table, "deviceId": r["deviceId"] ?? NSNull(),
                        "source": r["source"] ?? NSNull(), "rows": r["rows"] ?? NSNull()])
        }
    }
    return (out, ["table", "deviceId", "source", "rows"])
}

// MARK: - Main

let usage = """
loop-data — read-only exporter for the Loop app's on-device store

USAGE:
  loop-data <command> [options]

COMMANDS:
  workouts   Export workouts (sport, times, HR, strain, distance, zones)
  sleeps     Export sleep sessions (efficiency, RHR, HRV, stages)
  daily      Export daily metrics (recovery, strain, HRV, RHR, sleep, steps)
  devices    List device ids / sources present, with row counts
  help       Show this help

OPTIONS:
  --since YYYY-MM-DD   Start of range (inclusive). Default: earliest.
  --until YYYY-MM-DD   End of range (inclusive). Default: today.
  --source NAME        Filter workouts by source column (see `devices`).
  --device ID          Filter by deviceId (see `devices`).
  --limit N            Max rows (default 100000).
  --format FMT         json (default) | ndjson | markdown
  --pretty / --compact Pretty-print JSON (default) or single-line.
  --db PATH            Store path. Default: the Loop sandbox container.

The JSON output is the stable contract — see docs/DATA_ACCESS.md.
"""

func main() -> Int32 {
    let args = parseArgs(CommandLine.arguments)
    if args.command.isEmpty || args.command == "help" || args.has("help") {
        print(usage); return args.command.isEmpty ? 1 : 0
    }
    let format: Format = {
        switch args.str("format") {
        case "ndjson": return .ndjson
        case "markdown", "md": return .markdown
        default: return .json
        }
    }()
    let pretty = !args.has("compact")

    do {
        let db = try SQLiteReader(path: args.str("db") ?? defaultDBPath)
        let (rows, cols): ([[String: Any]], [String])
        switch args.command {
        case "workouts": (rows, cols) = try runWorkouts(db, args)
        case "sleeps":   (rows, cols) = try runSleeps(db, args)
        case "daily":    (rows, cols) = try runDaily(db, args)
        case "devices":  (rows, cols) = try runDevices(db)
        default:
            FileHandle.standardError.write(Data("unknown command '\(args.command)'. Try `loop-data help`.\n".utf8))
            return 2
        }
        try emit(rows, columns: cols, format: format, pretty: pretty)
        return 0
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 1
    }
}

exit(main())
