// swift-tools-version:5.9
import PackageDescription

// A standalone, read-only exporter for the Loop app's on-device SQLite store.
// Deliberately dependency-free: it links only the system SQLite3, so it builds
// offline with `swift build` and never pulls in WhoopStore/GRDB (whose opener
// runs migrations and can quarantine the file — unsafe for a reader). The JSON
// it emits is the stable contract; see docs/DATA_ACCESS.md.
let package = Package(
    name: "loop-data",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "loop-data",
            path: "Sources/loop-data",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
