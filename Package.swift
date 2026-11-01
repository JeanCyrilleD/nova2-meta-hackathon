// swift-tools-version: 5.9
// Nova 2 — package resserré : DEUX cibles produit et c'est tout.
// Nova 1 déclarait 4 produits (NovaCore, nova-server, NovaMac, NovaEngine) et deux architectures
// moteur concurrentes. Nova 2 : le moteur est intégré à NovaMac, point final (voir architecture_nova2.md §1).
import PackageDescription

let package = Package(
    name: "Nova2",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "NovaCore", targets: ["NovaCore"]),
        .executable(name: "NovaMac", targets: ["NovaMac"]),
    ],
    dependencies: [
        // SENTRY (22/10, phase 1) : SDK officiel sentry-cocoa — crash reporting + tracing + release health.
        // Dernière version stable au 22/10/2026 : 9.31.0 (github.com/getsentry/sentry-cocoa/releases/tag/9.31.0).
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "9.31.0"),
    ],
    targets: [
        // NovaFoundation : feuilles sans dépendance montante (Paths/JSONFile/Journal, SystemInfo,
        // TVCatalog) — compilées en parallèle de NovaCore au lieu d'attendre le monolithe.
        .target(name: "NovaFoundation"),
        .target(name: "NovaCore", dependencies: ["NovaFoundation"]),
        .executableTarget(name: "NovaMac", dependencies: ["NovaCore", .product(name: "Sentry", package: "sentry-cocoa")]),
        // NOVA2 : le chemin correspond au dossier réel « Tests/NovaCoreTests » (Nova 1 pointait
        // « Tests/… » alors que le dossier livré s'appelait « tests/ » — cible jamais résolue).
        .testTarget(name: "NovaCoreTests", dependencies: ["NovaCore"], path: "Tests/NovaCoreTests", exclude: ["Fixtures"]),
    ]
)
