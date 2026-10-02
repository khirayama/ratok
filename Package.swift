// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ratok",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Ratok", targets: ["Ratok"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "Ratok", dependencies: ["UsageCore", .product(name: "Sparkle", package: "Sparkle")], swiftSettings: [
            .defaultIsolation(MainActor.self),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault")
        ], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"])
    ]
)
