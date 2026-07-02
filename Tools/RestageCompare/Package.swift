// swift-tools-version:5.9
import PackageDescription

// Throwaway diagnostic: re-stage a stored sleep window through BOTH the shipped V1 `SleepStager`
// and the experimental V2 `SleepStagerV2` from the SAME raw streams, and print the two hypnograms
// side by side. Read-only — opens the store, never writes. Not part of the app build.
let package = Package(
    name: "restage-compare",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/StrandAnalytics"),
        .package(path: "../../Packages/WhoopStore"),
        .package(path: "../../Packages/WhoopProtocol"),
    ],
    targets: [
        .executableTarget(name: "restage-compare",
                          dependencies: ["StrandAnalytics", "WhoopStore", "WhoopProtocol"]),
    ]
)
