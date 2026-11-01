// swift-tools-version: 5.9
// Banc Nova (Phase 6) — fixture du cas « correctif_swift ». Paquet autonome, sans dépendance, hors du paquet Nova2.
import PackageDescription

let package = Package(
    name: "MontantsEval",
    targets: [
        .target(name: "MontantsEval"),
        .testTarget(name: "MontantsEvalTests", dependencies: ["MontantsEval"]),
    ]
)
