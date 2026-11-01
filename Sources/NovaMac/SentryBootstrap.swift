import Foundation
import NovaCore
import Sentry

/// SENTRY — bootstrap du SDK Sentry (sentry-cocoa), cible NovaMac uniquement (la coquille app).
/// Lot du 22/10/2026 (phase 1 : fichiers seuls — aucun build ni aucune relance dans ce lot).
///
/// Règles :
/// - AUCUNE valeur de DSN dans le code. Résolution, dans l'ordre :
///   1. Trousseau « nova-sentry-dsn » (ou variable d'environnement SENTRY_DSN) via `KnownKeys.sentryDSN`
///      et `KeychainStore` — le pattern maison des clés (Keys.swift) ;
///   2. clé « sentry_dsn » de settings.json, dans le magasin (~/Library/Application Support/Nova/) —
///      le pattern maison de configuration par fichier (`Settings`), et le seul emplacement
///      inscriptible sans interface : c'est là que la valeur est déposée côté Mac.
/// - Aucun DSN configuré → le SDK n'est PAS démarré : comportement de l'app strictement inchangé.
/// - Le DSN ne doit apparaître ni dans ce fichier, ni dans aucun fichier destiné au dépôt public Nova-public.
/// - Déclencheurs de test : arguments de lancement UNIQUEMENT (`--sentry-test-message`,
///   `--sentry-test-crash`), inatteignables depuis l'interface.
enum SentryBootstrap {
    private static var started = false

    static func start() {
        guard !started else { return }
        Credits.installLocalCrashJournal()   // V5-I : repli toujours actif — journal local des exceptions (crash_local.jsonl), posé AVANT Sentry pour que Sentry chaîne dessus
        guard let dsn = resolveDSN() else { return }   // pas de DSN → SDK éteint, silence total
        started = true

        #if DEBUG
        let environment = "dev"
        #else
        let environment = "prod"
        #endif
        let release = bundleRelease()

        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environment
            options.releaseName = release
            options.tracesSampleRate = NSNumber(value: 0.2)   // tracing modéré : 20 % des transactions
            options.enableAutoSessionTracking = true          // release health (sessions, taux crash-free)
            options.sendDefaultPii = false                    // aucune donnée personnelle par défaut
            // CREDITS-SENTRY (23/10/2026, stagé — classification NOVA2-1) : hygiène de capture des
            // échecs 5xx de récupération de playlist HLS. Ces événements naissent dans le SDK
            // lui-même (SentryNetworkTracker.captureFailedRequest : Event niveau .error,
            // exception de type « HTTPClientError », plage par défaut 500–599 — Options.swift du
            // SDK 9.31.0, enableCaptureFailedRequests=true par défaut) quand le relais TV
            // (TVStreamRelay, NovaCore/App.swift) ou le lecteur récupère un manifeste .m3u8 chez
            // un tiers d'ad-stitching en panne (504 CloudFront SSAI, 500 stitcher Pluto, 23/10
            // 02:02–02:03 UTC). Une indisponibilité de chaîne n'est PAS une erreur de l'app :
            // niveau abaissé à .warning + mécanisme marqué handled. Périmètre strict : type
            // HTTPClientError ET URL de requête se terminant par .m3u8 — tout le reste traverse
            // inchangé (les vrais crashs restent des crashs, les autres HTTPClientError restent
            // des erreurs). L'échec reste visible côté app : journal du relais + état mesuré TV.
            options.beforeSend = { event in
                Credits.count("sentry", n: 1, units: 1, unit: "événements")   // V5-I : usage mesuré par Nova — événement remis au SDK pour envoi (aucun n'est jeté ici)
                guard let exc = event.exceptions?.first, exc.type == "HTTPClientError" else { return event }
                let rawURL = event.request?.url ?? ""
                let pathOnly = URL(string: rawURL)?.path.lowercased() ?? rawURL.lowercased()
                guard pathOnly.hasSuffix(".m3u8") else { return event }
                event.level = .warning
                exc.mechanism?.handled = NSNumber(value: true)
                var tags = event.tags ?? [:]
                tags["origine"] = "hls_amont"
                tags["playlist_5xx"] = "handled_warning"
                event.tags = tags
                return event
            }
        }
        installRouterIncidentHook()   // CREDITS-SENTRY (23/10) : voir ci-dessous — posé APRÈS le démarrage effectif du SDK, jamais si le DSN manque (start() est déjà sorti plus haut dans ce cas)
        _ = BlackBox.record(["tool": "sentry_bootstrap", "actor": "Nova", "why": "démarrage du SDK Sentry", "ok": true, "effect": "config", "result": "environment=\(environment) release=\(release)"])   // le DSN n'est jamais journalisé
        runLaunchArgTestsIfNeeded()
    }

    private static func resolveDSN() -> String? {
        if let v = KeychainStore().value(KnownKeys.sentryDSN), !v.isEmpty { return v }
        let s = Settings().get("sentry_dsn", "")
        return s.isEmpty ? nil : s
    }

    /// Release = version du bundle, au format Sentry « identifiant@version+build »
    /// (Info.plist du bundle, posé par tools/package_app.sh : 2.0.0 au 22/10/2026).
    private static func bundleRelease() -> String {
        let info: [String: Any] = Bundle.main.infoDictionary ?? [:]
        let id = info["CFBundleIdentifier"] as? String ?? "NovaMac"
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? version
        return "\(id)@\(version)+\(build)"
    }

    /// CREDITS-SENTRY (23/10/2026, stagé) — journalisation Sentry des incidents routeur
    /// (timeout / HTTP 504 d'un cerveau). Le routeur vit dans NovaCore, qui ne dépend PAS du
    /// SDK Sentry (lié à la seule cible NovaMac, cf. phase 1) : NovaCore émet donc via
    /// `Router.incidentHook`, nil par défaut (= no-op strict, zéro coût, zéro dépendance).
    /// Ici, côté NovaMac, on installe le hook réel. Discipline de dégradation : l'émission est
    /// renvoyée sur une file d'arrière-plan bornée (.utility) — le routeur n'attend jamais
    /// Sentry ; le hook n'existe que si le SDK a démarré (DSN résolu) ; la charge utile ne
    /// contient NI contenu de conversation, NI clé, NI corps d'erreur brut au-delà du type
    /// d'échec déjà journalisé dans cerveaux_journal.jsonl (brain, modèle, type, durée ms,
    /// chaîne tentée). Niveau .warning, argumenté : le routeur ABSORBE l'incident par bascule
    /// sur le cerveau suivant — c'est un incident à tracer, pas une erreur applicative ; en
    /// .error, chaque 504 amont rouvrirait une issue « High » et recréerait le bruit NOVA2-1.
    /// Tag de discipline des incidents (ordre 23/10) : `remede_subventionne` = le remède
    /// subventionné visé pour cette fragilité (Together AI / Nebius, couture Brains.swift).
    private static func installRouterIncidentHook() {
        Router.incidentHook = { payload in
            DispatchQueue.global(qos: .utility).async {
                let brain = payload["brain"] as? String ?? "?"
                let model = payload["model"] as? String ?? "?"
                let kind = payload["kind"] as? String ?? "?"
                let ms = payload["ms"] as? Int ?? 0
                _ = SentrySDK.capture(message: "Routeur — timeout/504 : \(model) après \(ms) ms (\(kind))") { scope in
                    scope.setLevel(.warning)
                    scope.setTag(value: "aucun", key: "remede_subventionne")
                    scope.setTag(value: "timeout_504", key: "incident_routeur")
                    scope.setTag(value: brain, key: "brain")
                    scope.setTag(value: model, key: "model")
                    scope.setContext(value: payload, key: "routeur")
                    scope.setFingerprint(["routeur-timeout-504", brain])
                }
            }
        }
    }

    /// Tests de bout en bout, gardés par arguments de lancement — jamais exposés dans l'UI.
    private static func runLaunchArgTestsIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--sentry-test-message") {
            _ = SentrySDK.capture(message: "Nova2 — événement de test Sentry (--sentry-test-message)")
        }
        if args.contains("--sentry-test-crash") {
            // Délai : laisser le SDK achever son démarrage. Le rapport de crash est écrit sur
            // disque par le SDK pendant le crash, puis ENVOYÉ AU LANCEMENT SUIVANT de l'app.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                fatalError("Nova2 — crash de test Sentry (--sentry-test-crash)")
            }
        }
    }
}
