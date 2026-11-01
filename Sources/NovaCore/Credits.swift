import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// V5-I (24/10/2026) — CRÉDITS ACQUIS : suivi automatique, alertes, et Nova toujours puissant après leur fin.
// Source de vérité : point d'Ahadi « subventions ACQUISES pour Nova » du 24/10/2026 20:13 GMT.
// Routes : NovaApp.fundingsRoutes() (Fundings.swift) — GET /api/credits,
// POST /api/credits/rearm, POST /api/credits/amd/activate (toujours refusé), POST /api/credits/check.
//
// Règles :
//  - « usage mesuré par Nova » = ce que Nova a réellement compté à ses propres appels (compteur local, magasin
//    credits_usage.json). Ce n'est PAS le solde du fournisseur : aucun de ces fournisseurs n'expose ici d'API de solde
//    publique branchée → « solde réel : à vérifier sur le portail ». Aucun chiffre estimé sans coût unitaire public connu.
//  - Disjoncteur par fournisseur : HTTP 401/402/403/429 ou réponse « quota / credit » → ouvert, BlackBox + UNE
//    notification ; Nova bascule sur le repli. 429 seul = pause de 15 min ; sinon réarmement MANUEL (clic d'Ahadi).
//  - AMD : verrou « ne pas activer » — aucun code de Nova n'active AMD, la route d'activation refuse toujours.
//  - Aucun secret ne sort d'ici : seules la PRÉSENCE d'une clé (sonde d'attributs du Trousseau) et des compteurs.

public enum Credits {
    static let usageFile: JSONFile = JSONFile("credits_usage.json")
    static let exportFile: JSONFile = JSONFile("memoire_semantique_export.json")
    static let crashJournal: Journal = Journal("crash_local.jsonl")
    static let lock: NSLock = NSLock()
    static let pointSource: String = "point d'Ahadi du 24/10/2026 20:13 GMT"
    /// Mémoire sémantique LOCALE : index distinct de celui de la base de connaissances.
    static let localSemantic: UltraVectorIndex = UltraVectorIndex(cacheBase: "vec-memoire")
    static let youcomKey: KeyRef = KeyRef(service: "nova-youcom", accounts: ["$USER"], envVars: ["YDC_API_KEY", "YOUCOM_API_KEY"])
    static let githubKey: KeyRef = KeyRef(service: "nova-github", accounts: ["$USER"], envVars: ["GITHUB_TOKEN"])
    static let daytonaKey: KeyRef = KeyRef(service: "nova-daytona", accounts: ["$USER"], envVars: ["DAYTONA_API_KEY"])

    // MARK: - Catalogue (photographie du point d'Ahadi + état de branchement vérifié dans le code le 24/10)

    struct Repli { let cible: String; let etat: String; let detail: String }

    static func credit(_ id: String, fundings: String, programme: String, montant: String, usd: Double?, echeance: String, echeanceLabel: String,
                       approx: Bool = false, sertA: String, usage: String, objectif: String, branchement: String, preuve: String,
                       action: String, dateAlerte: String = "", compteur: String = "", fort: Bool = false) -> [String: Any] {
        var o: [String: Any] = ["id": id, "fundings_id": fundings, "programme": programme, "montant": montant,
                                "echeance": echeance, "echeance_label": echeanceLabel, "approx": approx,
                                "sert_a": sertA, "usage_nova": usage, "objectif": objectif,
                                "branchement": branchement, "branchement_preuve": preuve,
                                "action": action, "date_alerte": dateAlerte, "compteur": compteur, "alerte_forte": fort,
                                "source": pointSource]
        if let u = usd { o["montant_usd"] = u }
        return o
    }

    static let catalog: [[String: Any]] = [
        credit("sentry", fundings: "sentry", programme: "Sentry", montant: "5 000 $ de crédits", usd: 5000,
               echeance: "", echeanceLabel: "non communiquée",
               sertA: "Suivi d'erreurs et de crashs en production (région EU).",
               usage: "SDK Sentry dans la coquille Mac : chaque crash remonte avec son contexte ; incidents routeur en avertissement. NOVA2-1 ouvert, NOVA2-2 clos.",
               objectif: "Fiabilité démontrable à la démo du 03/11 : zéro crash non expliqué.",
               branchement: "branché", preuve: "NovaMac/SentryBootstrap.swift (actif si le DSN est au Trousseau nova-sentry-dsn)",
               action: "Aucune — vérifier que le DSN est bien au Trousseau sur le Mac avant la démo du 03/11.", compteur: "sentry"),
        credit("algolia", fundings: "algolia", programme: "Algolia", montant: "10 000 $", usd: 10000,
               echeance: "2027-10-31", echeanceLabel: "~oct. 2027", approx: true,
               sertA: "Moteur de recherche : indexation et requêtes instantanées.",
               usage: "Recherche dans les contenus de Nova (documents, conversations, mémoire), tolérante aux fautes.",
               objectif: "Retrouver n'importe quelle information en une fraction de seconde.",
               branchement: "partiel", preuve: "web/js/palette.js interroge l'index « nova » depuis le navigateur ; aucun code de Nova ne verse dans l'index",
               action: "Alimenter l'index « nova » (aucun versement automatique dans Nova à ce jour).", compteur: ""),
        credit("amplitude", fundings: "amplitude", programme: "Amplitude", montant: "Plan Growth gratuit 1 an", usd: nil,
               echeance: "2027-10-22", echeanceLabel: "22/10/2027",
               sertA: "Analytics produit : qui utilise quoi, rétention, parcours.",
               usage: "Événements sobres (messages, Éclats, Conseil, GO) sans aucun contenu.",
               objectif: "Mesurer l'usage réel et prouver la traction (YC, Techstars, a16z).",
               branchement: "branché", preuve: "Amplitude.swift + appels track() dans App, Dots, Council (actif si la clé est au Trousseau nova-amplitude-api)",
               action: "Aucune — instrumenter Dots, directs, voix et recherches au fil des lots.", compteur: "amplitude"),
        credit("youcom", fundings: "youcom", programme: "You.com", montant: "100 $ (offre du programme)", usd: 100,
               echeance: "", echeanceLabel: "non communiquée (pas de recharge automatique)",
               sertA: "API de recherche web IA, résultats sourcés.",
               usage: "Second fournisseur de recherche web aux côtés de Tavily (qualité + redondance).",
               objectif: "La recherche sourcée ne dépend jamais d'un seul fournisseur.",
               branchement: "pas branché", preuve: "aucun appel You.com dans Sources/ (grep « you.com », « ydc »)",
               action: "Créer la clé API (Trousseau nova-youcom) + premier appel.", compteur: "youcom"),
        credit("composio", fundings: "composio", programme: "Composio", montant: "Pro 6 mois (valeur 174 $)", usd: 174,
               echeance: "2027-04-23", echeanceLabel: "23/04/2027 (puis 29 $/mois)",
               sertA: "Intégrations d'outils (GitHub connecté).",
               usage: "Chantier INT-C : Nova lit les repos GitHub, alimente le Direct et le brief du matin.",
               objectif: "Nova agit sur des outils réels au lieu de seulement parler.",
               branchement: "partiel", preuve: "Feat_ComposioGitHub.swift (producteur GitHub, interrupteur composio_enabled fermé par défaut)",
               action: "Décider avant le 10/04/2027 : annuler ou payer 29 $/mois.", dateAlerte: "2027-04-10"),
        credit("daytona", fundings: "daytona", programme: "Daytona", montant: "200 $ (offre annoncée du programme)", usd: 200,
               echeance: "", echeanceLabel: "non communiquée",
               sertA: "Sandboxes cloud isolées (exécution de code à distance).",
               usage: "Faire exécuter le code de l'agent dans des sandboxes jetables, sans toucher le Mac.",
               objectif: "Un agent qui code et teste en sécurité.",
               branchement: "pas branché", preuve: "aucun appel Daytona dans Sources/",
               action: "Éclaircir l'écart : le mail annonçait 200 $ automatiques, le portefeuille montre 100 $ (constaté le 24/10 19:39)."),
        credit("digitalocean", fundings: "digitalocean", programme: "DigitalOcean", montant: "5 $", usd: 5,
               echeance: "", echeanceLabel: "non communiquée",
               sertA: "Compute cloud (petits serveurs).",
               usage: "Héberger les petits services de Nova quand le Mac ne doit pas les porter.",
               objectif: "Une infra bon marché, indépendante du Mac.",
               branchement: "pas branché", preuve: "aucun appel DigitalOcean dans Sources/ (compte actif, aucune ressource créée)",
               action: "Aucune tant qu'aucun service ne doit quitter le Mac."),
        credit("neon", fundings: "neon", programme: "Neon", montant: "Plan Launch + 1 000 $ (acquis 27/10)", usd: 1000,
               echeance: "2027-10-27", echeanceLabel: "~27/10/2027",
               sertA: "Base Postgres serverless (projet « Nova »).",
               usage: "Couche données de l'application (utilisateurs, Dots, historiques).",
               objectif: "Une base fiable et scalable.",
               branchement: "pas branché", preuve: "aucun appel Neon dans Sources/ (Nova stocke en local : JSON + SQLite)",
               action: "Spec Temps 1 prête (données DÉMO, 4 tables) : branchement avec repli local, sur ton GO."),
        credit("retool", fundings: "retool", programme: "Retool", montant: "Plan Team 12 $/mois (coût, pas un crédit)", usd: nil,
               echeance: "2026-11-23", echeanceLabel: "1re facture le 23/11/2026",
               sertA: "Constructeur d'outils internes (console web + app mobile).",
               usage: "Console Nova (R1) et Nova Mobile (R2) en ligne ; rien ne part sans relais manuel.",
               objectif: "Piloter Nova depuis une console et un mobile.",
               branchement: "pas branché", preuve: "aucun appel Retool dans Sources/ (console hébergée chez Retool)",
               action: "12 $ débités le 23/11 sauf annulation.", dateAlerte: "2026-11-20"),
        credit("amd", fundings: "amd", programme: "AMD Developer Cloud", montant: "100 $ (en validation, non comptés)", usd: nil,
               echeance: "", echeanceLabel: "30 jours après ACTIVATION",
               sertA: "GPU cloud pour charges lourdes.",
               usage: "Inférences et modèles lourds quand le MacBook Air ne suffit pas.",
               objectif: "Faire tourner des modèles exigeants sans acheter de GPU.",
               branchement: "pas branché", preuve: "aucun appel AMD dans Sources/ — verrou : la route d'activation refuse toujours",
               action: "NE PAS ACTIVER tant que les charges GPU de Nova ne sont pas prêtes. Si rien sous 5 j ouvrés : relance devcloudrequests@amd.com, sur ton GO."),
        // 29/10 (dossier crédits d'Ahadi) : acquis du 27 au 29/10.
        credit("baseten", fundings: "baseten", programme: "Baseten (hackathon Meta)", montant: "100 $ + jusqu'à 2 M jetons/min", usd: 100,
               echeance: "", echeanceLabel: "non communiquée",
               sertA: "Inférence du modèle Muse Spark Open (meta-models/muse-spark-open).",
               usage: "Cerveau « Muse Spark Open (Baseten) » sélectionnable à la main, hors chaînes automatiques.",
               objectif: "Conversations, Conseil, Éclats en fond pendant le hackathon.",
               branchement: "partiel", preuve: "Brains.swift — spark-open-baseten (clé nova-baseten ABSENTE : hors service)",
               action: "GATE : révoquer la clé exposée le 28/10, en créer une neuve et la déposer toi-même au Trousseau nova-baseten. Jamais l'ancienne."),
        credit("runware", fundings: "runware", programme: "Runware", montant: "250 $", usd: 250,
               echeance: "", echeanceLabel: "sans expiration",
               sertA: "Génération d'images IA, tous modèles.",
               usage: "Visuels Nova (Studio, illustrations de brief), démo, marketing.",
               objectif: "Images sans abonnement.",
               branchement: "pas branché", preuve: "aucun appel Runware dans Sources/",
               action: "Déposer la clé API au Trousseau nova-runware ; repli : génération d'image désactivée proprement."),
        credit("mongodb", fundings: "mongodb", programme: "MongoDB Atlas", montant: "500 $ promotionnels", usd: 500,
               echeance: "2027-10-28", echeanceLabel: "28/10/2027",
               sertA: "Base documentaire (conversations, briefs, runs, approbations).",
               usage: "Spec Temps 1 DÉMO prête, non exécutée. Aucun cluster, aucune carte.",
               objectif: "Comparer à Neon sur preuves Temps 1, puis décision d'Ahadi.",
               branchement: "pas branché", preuve: "aucun appel MongoDB dans Sources/",
               action: "Si Atlas exige une carte pour le palier gratuit : STOP et retour à Ahadi."),
        credit("meta", fundings: "meta", programme: "Meta Model API (facturation séparée)", montant: "150 $ (offre initiale du programme)", usd: 150,
               echeance: "", echeanceLabel: "non communiquée",
               sertA: "Muse Spark 1.3 et Wonder 1.0.",
               usage: "Relais général de tous les postes (conversations, tri, briefs) tant que Claude n'est pas crédité.",
               objectif: "Ne jamais laisser Nova sans cerveau.",
               branchement: "branché", preuve: "Brains.swift — spark-1.3 / wonder-1.0 (clé nova-spark présente, réponses mesurées le 29/10)",
               action: "Surveiller le solde sur le portail Meta : c'est aujourd'hui le seul cerveau actif."),
    ]

    /// Alertes d'échéance : (id, libellé, échéance, date d'alerte posée, forte). Zoho n'est pas un crédit mais une décision payante du point.
    static let alertTargets: [(String, String, String, String, Bool)] = [
        ("zoho", "Zoho Mail Premium : renouvellement payant le 06/11 — décision à trancher", "2026-11-06", "2026-11-03", false),
        ("retool", "Retool : 1re facture de 12 $ le 23/11 sauf annulation", "2026-11-23", "2026-11-20", false),
        ("composio", "Composio Pro : gratuit jusqu'au 23/04/2027, puis 29 $/mois — annuler ou payer", "2027-04-23", "2027-04-10", false),
        ("amplitude", "Amplitude Growth gratuit : expiration le 22/10/2027", "2027-10-22", "", false),
        ("algolia", "Algolia 10 000 $ : expiration ~octobre 2027", "2027-10-31", "", false),
    ]
    static let thresholds: [Int] = [1, 7, 30]

    // MARK: - Registre des replis (état réel lu au moment de la demande)

    static func repli(_ id: String) -> Repli {
        switch id {
        case "sentry":
            return Repli(cible: "Journal local de plantages (crash_local.jsonl)", etat: "prêt", detail: "Exceptions non rattrapées écrites sur le Mac, avec ou sans Sentry (les signaux bas niveau restent du ressort de Sentry).")
        case "algolia":
            return Repli(cible: "Recherche locale « Partout » (Feat_Search)", etat: "prêt", detail: "La palette ⌘K interroge toujours conversations, mémoire, Dots, brouillons, mails et fichiers en local ; l'index Algolia n'est qu'un appoint.")
        case "amplitude":
            return Repli(cible: "Compteurs locaux d'événements", etat: "prêt", detail: "Chaque événement est aussi compté en local (credits_usage.json), même sans clé ni réseau.")
        case "youcom":
            let tav: Bool = keyPresent(KnownKeys.tavilyNova)
            return Repli(cible: "web_search existant : Tavily → Brave → DuckDuckGo", etat: "prêt", detail: "You.com n'est pas encore appelé ; la recherche web passe par la chaîne existante" + (tav ? " (clé Tavily présente)." : " (pas de clé Tavily : Brave puis DuckDuckGo)."))
        case "composio":
            let gh: Bool = keyPresent(githubKey)
            return Repli(cible: "GitHub direct", etat: "non disponible", detail: gh ? "Un jeton nova-github est au Trousseau, mais Nova n'a pas encore de client GitHub direct : sans Composio, la lecture des repos s'arrête (honnête, rien d'inventé)." : "Pas de jeton nova-github au Trousseau et pas de client GitHub direct : sans Composio, la lecture des repos s'arrête.")
        case "daytona":
            return Repli(cible: "Bac à sable local (Forge, sandbox-exec)", etat: "prêt", detail: "Nova exécute déjà ses tests d'outils en local, sans réseau, dans le bac à sable macOS.")
        case "digitalocean":
            return Repli(cible: "Le Mac", etat: "prêt", detail: "Aucun service Nova ne tourne chez DigitalOcean : rien ne change si le crédit disparaît.")
        case "neon":
            return Repli(cible: "Stockage local (JSON + SQLite)", etat: "prêt", detail: "Nova n'utilise pas Neon aujourd'hui : ses données vivent sur le Mac.")
        case "retool":
            return Repli(cible: "Interface de Nova sur le Mac", etat: "prêt", detail: "La console Retool est un confort : tout se pilote aussi depuis Nova.")
        case "amd":
            return Repli(cible: "Calcul local (MacBook) et cerveaux existants", etat: "prêt", detail: "AMD n'est jamais activé par Nova.")
        default:
            return Repli(cible: "—", etat: "non disponible", detail: "")
        }
    }

    static func displayName(_ p: String) -> String {
        for c in catalog where (c["id"] as? String) == p { return (c["programme"] as? String) ?? p }
        return p
    }

    // MARK: - Compteurs d'usage (mesurés par Nova)

    /// Compte un appel RÉEL d'un fournisseur (réponse reçue). `units` + `unit` : quantité (secondes d'audio, événements…) ;
    /// `costUSD` : coût calculé au tarif public déjà codé chez l'appelant (0 si aucun tarif connu).
    public static func count(_ provider: String, n: Int = 1, units: Double = 0, unit: String = "", costUSD: Double = 0) {
        lock.lock()
        var o: [String: Any] = usageFile.read(default: [String: Any]())
        var all: [String: Any] = (o["providers"] as? [String: Any]) ?? [:]
        var p: [String: Any] = (all[provider] as? [String: Any]) ?? [:]
        let ts: String = nowISO()
        p["calls"] = ((p["calls"] as? Int) ?? 0) + n
        if units != 0 { p["units"] = ((p["units"] as? Double) ?? 0) + units }
        if !unit.isEmpty { p["unit"] = unit }
        if costUSD > 0 { p["cost_usd"] = (((p["cost_usd"] as? Double) ?? 0) + costUSD * 10000).rounded() / 10000 }
        if p["first"] == nil { p["first"] = ts }
        p["last"] = ts
        all[provider] = p
        o["providers"] = all
        usageFile.write(o)
        lock.unlock()
    }

    /// Repli Amplitude : chaque événement est aussi compté en local (nom fixe, jamais de contenu).
    public static func localEvent(_ name: String) {
        let key: String = String(name.prefix(64))
        lock.lock()
        var o: [String: Any] = usageFile.read(default: [String: Any]())
        var ev: [String: Any] = (o["local_events"] as? [String: Any]) ?? [:]
        if ev[key] == nil && ev.count >= 200 { lock.unlock(); return }
        ev[key] = ((ev[key] as? Int) ?? 0) + 1
        o["local_events"] = ev
        if o["local_events_since"] == nil { o["local_events_since"] = nowISO() }
        usageFile.write(o)
        lock.unlock()
    }

    // MARK: - Disjoncteur par fournisseur

    static func isCreditFailure(status: Int, detail: String) -> Bool {
        if [401, 402, 403, 429].contains(status) { return true }
        let low: String = detail.lowercased()
        return low.contains("quota") || low.contains("credit") || low.contains("crédit") || low.contains("insufficient") || low.contains("billing")
    }

    /// Un appel a échoué. Échec « crédit / quota / clé » → disjoncteur ouvert, BlackBox + UNE notification (à l'ouverture).
    public static func providerFailed(_ provider: String, status: Int, detail: String = "") {
        guard isCreditFailure(status: status, detail: detail) else { return }
        let low: String = detail.lowercased()
        let quotaWord: Bool = low.contains("quota") || low.contains("credit") || low.contains("crédit") || low.contains("insufficient") || low.contains("billing")
        let pauseOnly: Bool = status == 429 && !quotaWord
        let ts: String = nowISO()
        lock.lock()
        var o: [String: Any] = usageFile.read(default: [String: Any]())
        var brs: [String: Any] = (o["breakers"] as? [String: Any]) ?? [:]
        var b: [String: Any] = (brs[provider] as? [String: Any]) ?? [:]
        let wasOpen: Bool = openLocked(b)
        b["hits"] = ((b["hits"] as? Int) ?? 0) + 1
        b["last_status"] = status
        b["last_ts"] = ts
        var newlyOpened: Bool = false
        if !wasOpen {
            b["open"] = true
            b["since"] = ts
            b["status"] = status
            b["reason"] = status > 0 ? "HTTP " + String(status) + (quotaWord ? " (quota / crédit)" : "") : "quota / crédit"
            // 26/10 (Ahadi) : plus de disjoncteur à réarmer à la main — nouvel essai automatique (15 min sur limite de débit, 30 min sinon).
            b["until"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(pauseOnly ? 15 * 60 : 30 * 60))
            newlyOpened = true
        }
        brs[provider] = b
        o["breakers"] = brs
        var all: [String: Any] = (o["providers"] as? [String: Any]) ?? [:]
        var p: [String: Any] = (all[provider] as? [String: Any]) ?? [:]
        p["errors"] = ((p["errors"] as? Int) ?? 0) + 1
        p["last_error"] = status > 0 ? "HTTP " + String(status) : "quota / crédit"
        all[provider] = p
        o["providers"] = all
        usageFile.write(o)
        lock.unlock()
        guard newlyOpened else { return }
        let r: Repli = repli(provider)
        let name: String = displayName(provider)
        let how: String = pauseOnly ? "pause de 15 min (limite de débit)" : "nouvel essai automatique dans 30 min"
        _ = BlackBox.record(["tool": "credits", "actor": "Nova", "ok": false, "effect": "config",
                             "why": "Crédits : disjoncteur ouvert pour \(name) (\(status > 0 ? "HTTP " + String(status) : "quota")) — bascule sur le repli : \(r.cible) ; \(how)",
                             "result": "breaker_open:" + provider])
        NovaNotifier.send(source: "credits-breaker", title: "Nova — " + name + " indisponible",
                          body: (status > 0 ? "HTTP " + String(status) : "Quota / crédit") + " : Nova bascule sur " + r.cible + ". " + (pauseOnly ? "Nouvel essai dans 15 min." : "Nouvel essai automatique dans 30 min."),
                          target: ["module": "veille", "id": "fundings:credit-" + provider], sound: false)
    }

    static func openLocked(_ b: [String: Any]) -> Bool {
        guard (b["open"] as? Bool) == true else { return false }
        if let u: String = b["until"] as? String, let d: Date = ISO8601DateFormatter().date(from: u), Date() >= d { return false }
        return true
    }

    /// Vrai si le disjoncteur Crédits de ce fournisseur est ouvert (une pause 429 échue se referme seule).
    public static func isOpen(_ provider: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let o: [String: Any] = usageFile.read(default: [String: Any]())
        let brs: [String: Any] = (o["breakers"] as? [String: Any]) ?? [:]
        return openLocked((brs[provider] as? [String: Any]) ?? [:])
    }

    /// Réarmement manuel (clic d'Ahadi). Vrai si un disjoncteur était posé.
    static func rearm(_ provider: String) -> Bool {
        lock.lock()
        var o: [String: Any] = usageFile.read(default: [String: Any]())
        var brs: [String: Any] = (o["breakers"] as? [String: Any]) ?? [:]
        let had: Bool = brs[provider] != nil
        brs.removeValue(forKey: provider)
        o["breakers"] = brs
        if had { usageFile.write(o) }
        lock.unlock()
        if had { _ = BlackBox.record(["tool": "credits", "actor": "Ahadi", "ok": true, "effect": "config", "why": "Crédits : disjoncteur de \(displayName(provider)) réarmé sur clic", "result": "rearm:" + provider]) }
        return had
    }

    // MARK: - Journal local de plantages (repli Sentry)

    #if os(macOS)
    static var prevCrashHandler: (@convention(c) (NSException) -> Void)? = nil
    #endif
    static var crashInstalled: Bool = false

    /// Installe le journal local des exceptions non rattrapées. À appeler AVANT SentrySDK.start : Sentry chaîne alors
    /// vers ce gestionnaire, et le gestionnaire précédent éventuel est rappelé ensuite. Idempotent.
    public static func installLocalCrashJournal() {
        #if os(macOS)
        lock.lock()
        if crashInstalled { lock.unlock(); return }
        crashInstalled = true
        lock.unlock()
        prevCrashHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { (e: NSException) in
            Credits.recordCrash(name: e.name.rawValue, reason: e.reason ?? "", symbols: Array(e.callStackSymbols.prefix(16)))
            if let prev = Credits.prevCrashHandler { prev(e) }
        }
        #endif
    }

    static func recordCrash(name: String, reason: String, symbols: [String]) {
        crashJournal.add(["kind": "exception", "name": String(name.prefix(120)), "reason": String(reason.prefix(300)), "stack": symbols])
    }

    static func crashCount() -> Int {
        let u: URL = Paths.file("crash_local.jsonl")
        guard let s: String = try? String(contentsOf: u, encoding: .utf8) else { return 0 }
        return s.split(separator: "\n").count
    }

    // MARK: - Présence des clés (sonde d'attributs, jamais la valeur)

    static func keyPresent(_ ref: KeyRef) -> Bool {
        for v in ref.envVars {
            if let e: String = ProcessInfo.processInfo.environment[v], !e.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        }
        #if os(macOS)
        return KeychainStore.exists(service: ref.service, account: nil)
        #else
        return false
        #endif
    }
    static func fileField(_ file: String, _ field: String) -> String {
        guard let d: Data = try? Data(contentsOf: Paths.file(file)), let o: [String: Any] = parseJSON(d) else { return "" }
        return ((o[field] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func keyState(_ id: String, settings: Settings) -> [String: Any] {
        switch id {
        case "sentry":
            let k: Bool = keyPresent(KnownKeys.sentryDSN) || !settings.get("sentry_dsn", "").isEmpty
            return ["presente": k, "ou": "Trousseau nova-sentry-dsn"]
        case "algolia":
            let k: Bool = (keyPresent(KnownKeys.algoliaApp) || !fileField("algolia_config.json", "app_id").isEmpty) && (keyPresent(KnownKeys.algoliaSearch) || !fileField("algolia_config.json", "search_key").isEmpty)
            return ["presente": k, "ou": "Trousseau nova-algolia-app + nova-algolia-search"]
        case "amplitude":
            let k: Bool = keyPresent(KnownKeys.amplitudeAPI) || !fileField("amplitude_config.json", "api_key").isEmpty
            return ["presente": k, "ou": "Trousseau nova-amplitude-api", "interrupteur": settings.get("amplitude_enabled", true)]
        case "youcom":
            return ["presente": keyPresent(youcomKey), "ou": "Trousseau nova-youcom (à créer)"]
        case "composio":
            return ["presente": keyPresent(ComposioGitHub.keyRef), "ou": "Trousseau nova-composio", "interrupteur": settings.get("composio_enabled", false)]
        case "daytona":
            return ["presente": keyPresent(daytonaKey), "ou": "Trousseau nova-daytona (non utilisé par Nova)"]
        default:
            return [:]
        }
    }

    // MARK: - État servi au web (GET /api/credits)

    static func state(settings: Settings, now: Date = Date()) -> [String: Any] {
        let fund: [String: Any] = Fundings.state()
        let acquisRows: [[String: Any]] = (fund["acquis"] as? [[String: Any]]) ?? []
        var byFund: [String: [String: Any]] = [:]
        for r in acquisRows { if let id = r["id"] as? String { byFund[id] = r } }
        lock.lock()
        let u: [String: Any] = usageFile.read(default: [String: Any]())
        lock.unlock()
        let providers: [String: Any] = (u["providers"] as? [String: Any]) ?? [:]
        let breakers: [String: Any] = (u["breakers"] as? [String: Any]) ?? [:]
        let fired: [String] = (u["alerts_fired"] as? [String]) ?? []
        var out: [[String: Any]] = []
        for c0 in catalog {
            var c: [String: Any] = c0
            let id: String = (c["id"] as? String) ?? ""
            let fid: String = (c["fundings_id"] as? String) ?? ""
            if let row = byFund[fid] {
                c["statut"] = (row["statut"] as? String) ?? ""
                if let a = Fundings.num(row["montant_acquis_usd"]) { c["montant_usd"] = a }
                c["confirme"] = (row["confirme"] as? Bool) ?? (row["montant_acquis_usd"] != nil)
                if let m = row["montant"] as? String, !m.isEmpty { c["montant"] = m }
            }
            if id == "amd" { c["confirme"] = false; c["verrou"] = "NE PAS ACTIVER — crédits valables 30 jours après activation ; aucun code de Nova ne l'active." }
            let ech: String = (c["echeance"] as? String) ?? ""
            if !ech.isEmpty, let n: Int = Fundings.daysLeft(ech, now: now) { c["days_left"] = n }
            let da: String = (c["date_alerte"] as? String) ?? ""
            if !da.isEmpty, let n: Int = Fundings.daysLeft(da, now: now) { c["alerte_days_left"] = n }
            let cp: String = (c["compteur"] as? String) ?? ""
            var usage: [String: Any] = ["mesure": !cp.isEmpty]
            if !cp.isEmpty, let p = providers[cp] as? [String: Any] { for (k, v) in p { usage[k] = v } }
            if cp.isEmpty {
                usage["note"] = id == "algolia" ? "Non mesurable par le moteur : la palette ⌘K interroge Algolia directement depuis l'interface." : "Nova n'appelle pas ce service : rien à compter."
            } else if id == "youcom" {
                usage["note"] = "Compteur prêt ; You.com n'est appelé nulle part dans Nova pour l'instant."
            } else if id == "sentry" {
                usage["note"] = "Événements remis au SDK Sentry pour envoi (crashs, erreurs, incidents routeur)."
            } else if id == "amplitude" {
                usage["note"] = "Événements acceptés par Amplitude (HTTP 200)."
            }
            c["usage"] = usage
            c["solde_reel"] = "à vérifier sur le portail"
            let r: Repli = repli(id)
            c["repli"] = ["cible": r.cible, "etat": r.etat, "detail": r.detail]
            if let b = breakers[cp.isEmpty ? id : cp] as? [String: Any] {
                var bb: [String: Any] = b
                bb["open"] = openLocked(b)
                c["disjoncteur"] = bb
            }
            c["cle"] = keyState(id, settings: settings)
            c["alertes_envoyees"] = fired.filter { $0.hasPrefix(id + ":") }
            out.append(c)
        }
        // Totaux : acquis confirmés seulement ; « en validation » à part ; jamais additionnés.
        var acquis: Double = 0
        for c in out where (c["confirme"] as? Bool) == true { if let v = c["montant_usd"] as? Double { acquis += v } }
        var horsAcquis: [[String: Any]] = []
        for fid in ["nebius", "reducto"] {
            if let row = byFund[fid] {
                horsAcquis.append(["id": fid, "programme": (row["programme"] as? String) ?? fid, "montant": (row["montant"] as? String) ?? "",
                                   "statut": (row["statut"] as? String) ?? "", "note": (row["note"] as? String) ?? "", "compte": false])
            }
        }
        let urgences: [[String: Any]] = [
            ["id": "amd", "titre": "AMD : ne pas activer", "detail": "Les 100 $ s'évaporent 30 jours après activation : attendre que les charges GPU soient prêtes.", "niveau": "verrou"],
            ["id": "composio", "titre": "Composio : trancher avant le 10/04/2027", "detail": "Annuler ou payer 29 $/mois à partir du 23/04/2027.", "days_left": Fundings.daysLeft("2027-04-10", now: now) ?? 0, "niveau": "decision"],
        ]
        let totals: [String: Any] = ["acquis_usd": acquis, "point_usd": 15730, "note": "Acquis confirmés seulement. Nebius, Reducto et AMD : hors acquis, jamais additionnés."]
        let partenaires: [String] = ["LangSmith 100 $", "Tavily 25 $", "Toloka 50 $", "Tandem 50 $"]
        return ["credits": out, "urgences": urgences, "hors_acquis": horsAcquis,
                "partenaires_nebius": partenaires, "totals": totals,
                "local_events": (u["local_events"] as? [String: Any]) ?? [String: Any](),
                "local_events_since": (u["local_events_since"] as? String) ?? "", "crash_local": crashCount(),
                "solde_note": "Usage mesuré par Nova ≠ solde réel du fournisseur : le solde se vérifie sur chaque portail.",
                "source": pointSource, "generated": nowISO()]
    }

    // MARK: - Alertes (J-30 / J-7 / J-1, date d'alerte posée, budget 50/80/95 %)

    static var schedulerStarted: Bool = false

    static func startScheduler() {
        lock.lock()
        if schedulerStarted { lock.unlock(); return }
        schedulerStarted = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) { schedulerTick() }
    }
    static func schedulerTick() {
        _ = checkAlerts()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3600) { schedulerTick() }
    }

    /// Envoie au plus UNE notification par seuil et par échéance. Heures calmes : rien n'est marqué (sauf alerte forte),
    /// l'alerte partira à la vérification suivante. Retourne les alertes envoyées.
    @discardableResult
    static func checkAlerts(now: Date = Date()) -> [[String: Any]] {
        let on: Bool = NovaNotifier.isEnabled?() ?? true
        if !on { return [] }
        let quiet: Bool = NovaNotifier.isQuiet?() ?? false
        lock.lock()
        var o: [String: Any] = usageFile.read(default: [String: Any]())
        var fired: [String] = (o["alerts_fired"] as? [String]) ?? []
        var sendList: [(String, String, String, Bool)] = []
        for (id, label, ech, da, fort) in alertTargets {
            guard let n: Int = Fundings.daysLeft(ech, now: now), n >= 0 else { continue }
            var parts: [String] = []
            var urgent: Bool = false
            var marks: [String] = []
            if let t: Int = thresholds.first(where: { n <= $0 }), !fired.contains(id + ":J-" + String(t)) {
                parts.append(n == 0 ? "c'est aujourd'hui" : (n == 1 ? "c'est demain" : "J-" + String(n)))
                for t2 in thresholds where t2 >= t { marks.append(id + ":J-" + String(t2)) }
                if fort && t <= 7 { urgent = true }
            }
            if !da.isEmpty, let m: Int = Fundings.daysLeft(da, now: now), m <= 0, !fired.contains(id + ":alerte") {
                if parts.isEmpty { parts.append(n == 0 ? "c'est aujourd'hui" : "J-" + String(n)) }
                marks.append(id + ":alerte")
                if fort { urgent = true }
            }
            if parts.isEmpty { continue }
            if quiet && !urgent { continue }
            fired.append(contentsOf: marks)
            sendList.append((id, label, parts.joined(separator: " · "), urgent))
        }
        // Garde-fou budget : seulement si un coût unitaire public permet l'estimation (aucun programme concerné aujourd'hui).
        let providers: [String: Any] = (o["providers"] as? [String: Any]) ?? [:]
        var budgetList: [(String, Int, Double)] = []
        for c in catalog {
            let id: String = (c["id"] as? String) ?? ""
            guard id == "__aucun__", let usd: Double = c["montant_usd"] as? Double, usd > 0 else { continue }
            let cost: Double = ((providers[id] as? [String: Any])?["cost_usd"] as? Double) ?? 0
            let pct: Double = cost / usd * 100
            for t in [95, 80, 50] where pct >= Double(t) {
                let k: String = id + ":budget-" + String(t)
                if fired.contains(k) { break }
                if quiet && t < 95 { break }
                for t2 in [50, 80, 95] where t2 <= t { if !fired.contains(id + ":budget-" + String(t2)) { fired.append(id + ":budget-" + String(t2)) } }
                budgetList.append((id, t, cost))
                break
            }
        }
        let changed: Bool = !sendList.isEmpty || !budgetList.isEmpty
        if changed {
            o["alerts_fired"] = Array(fired.suffix(400))
            usageFile.write(o)
        }
        lock.unlock()
        var sent: [[String: Any]] = []
        for (id, label, when, urgent) in sendList {
            let extra: String = ""
            NovaNotifier.send(source: "credits:" + id, title: "Nova — Crédits · " + (id == "zoho" ? "Zoho Mail" : displayName(id)),
                              body: when + " — " + label + "." + extra, target: ["module": "veille", "id": "fundings:credit-" + id], urgent: urgent)
            sent.append(["id": id, "quand": when, "urgent": urgent])
        }
        for (id, t, cost) in budgetList {
            NovaNotifier.send(source: "credits-budget", title: "Nova — Crédits · " + displayName(id),
                              body: "Usage mesuré par Nova : " + String(format: "%.2f", cost) + " $ (" + String(t) + " % du crédit). Solde réel à vérifier sur le portail.",
                              target: ["module": "veille", "id": "fundings:credit-" + id], urgent: t >= 95)
            sent.append(["id": id, "budget_pct": t])
        }
        if !sent.isEmpty { _ = BlackBox.record(["tool": "credits", "actor": "Nova", "ok": true, "effect": "notification", "why": "Crédits : " + String(sent.count) + " alerte(s) d'échéance ou de budget affichée(s)", "result": "alerts"]) }
        return sent
    }

    /// Recherche sémantique LOCALE dans la copie mémoire (index vectoriel sur le Mac). nil si la copie n'existe pas ou que l'index local n'est pas prêt
    /// (dans ce cas une indexation est lancée en arrière-plan pour la fois suivante).
    static func localSemanticSearch(_ q: String, k: Int = 5) -> [[String: Any]]? {
        let ex: [String: Any] = exportFile.read(default: [String: Any]())
        let records: [[String: Any]] = (ex["records"] as? [[String: Any]]) ?? []
        if records.isEmpty || !UltraVectorIndex.enabled { return nil }
        let st: [String: Any] = localSemantic.status()
        let rows: Int = (st["rows"] as? Int) ?? 0
        if rows == 0 {
            if !((st["building"] as? Bool) ?? false) {
                let texts: [String] = records.map { (r: [String: Any]) -> String in (((r["title"] as? String) ?? "") + "\n" + ((r["text"] as? String) ?? "")) }
                localSemantic.rebuild(id: texts.count, texts: texts)
            }
            return nil
        }
        guard let r = localSemantic.search(q, k: k), r.id == records.count else { return nil }
        var hits: [[String: Any]] = []
        for (idx, score) in r.hits where idx >= 0 && idx < records.count && score > 0 {
            let rec: [String: Any] = records[idx]
            let title: String = (rec["title"] as? String) ?? "(sans titre)"
            hits.append(["id": (rec["id"] as? String) ?? "", "type": (rec["type"] as? String) ?? "",
                         "title": "Copie locale · " + title,
                         "snippet": String(((rec["text"] as? String) ?? "").prefix(220)),
                         "score": Double(score), "ts": (rec["ts"] as? Int) ?? 0, "ref": (rec["ref"] as? String) ?? "", "source": "local"])
        }
        count("memoire-locale", n: 1, units: 1, unit: "requête locale")
        return hits
    }
}
