// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PokeBattleKit",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "PokeBattleKit", targets: ["PokeBattleKit"]),
    ],
    targets: [
        .target(name: "PokeBattleKit", path: "Sources/PokeBattleKit"),
        .testTarget(name: "PokeBattleKitTests", dependencies: ["PokeBattleKit"], path: "Tests/PokeBattleKitTests"),
    ]
)
