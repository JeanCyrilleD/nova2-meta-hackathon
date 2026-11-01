import Foundation

public struct BrainHealth {
    public var ok = 0, fail = 0
    public var lastLatencyMs: Int? = nil
    public var lastError: String? = nil
    public var lastKind: String? = nil
    public var deadUntil: Date? = nil
    public var lastOK: Date? = nil
}

/// Routeur : essaie les cerveaux dans l'ordre, bascule sur tout échec avant le premier mot,
/// mémorise les pannes (disjoncteur) et finit toujours par le moteur local s'il existe.
public final class Router {
    public let runner: BrainRunner
    // PHASE 1 : écrit seulement dans init (aucune écriture à chaud trouvée) — lecture concurrente sûre. Toute future écriture à chaud doit passer par cfgLock.
    public var brains: [BrainSpec]
    public let journal = Journal("cerveaux_journal.jsonl")
    // CREDITS-SENTRY (23/10/2026, stagé) : crochet d'incident routeur. NovaCore ne dépend pas
    // du SDK Sentry (lié à la seule cible NovaMac) : le routeur ÉMET ici une charge utile
    // minimale, et SentryBootstrap (NovaMac) installe le hook réel quand le SDK a démarré.
    // nil (défaut, DSN absent, tests) = no-op strict. L'émission est asynchrone bornée
    // (file .utility, voir emitRouterIncident) : elle ne bloque ni ne ralentit JAMAIS la
    // bascule — le routeur continue sur le cerveau suivant sans attendre l'accusé Sentry.
    public static var incidentHook: (([String: Any]) -> Void)? = nil
    /// Émet un incident « timeout / 504 » : modèle visé + durée mesurée + chaîne tentée.
    /// Charge utile volontairement pauvre : aucun contenu, aucune clé, aucun corps de réponse.
    func emitRouterIncident(_ s: BrainSpec, kind: String, ms: Int, chain: [BrainSpec]) {
        guard let hook = Router.incidentHook else { return }
        let payload: [String: Any] = ["brain": s.id, "model": s.model, "kind": kind, "ms": ms,
                                      "chain": chain.map { $0.id }.joined(separator: ">"),
                                      "chain_position": chain.firstIndex(where: { $0.id == s.id }) ?? -1]
        DispatchQueue.global(qos: .utility).async { hook(payload) }
    }
    let lock = NSLock()
    var health: [String: BrainHealth] = [:]
    var localCache: (Date, [LocalEngine]) = (.distantPast, [])
    // PHASE 1 (courses de données) : réglages modifiés à chaud par les routes HTTP (POST /api/settings, /api/brains/toggle,
    // syncDemoBrain) et lus par plan()/status() sur les fils de chat. Un SEUL verrou (cfgLock) couvre tous leurs accès ;
    // il n'en prend aucun autre (pas d'interblocage possible avec lock, creditLock ou svLock).
    let cfgLock = NSLock()
    private var cfg = RouterConfig()
    func withCfg<T>(_ f: (inout RouterConfig) -> T) -> T { cfgLock.lock(); defer { cfgLock.unlock() }; return f(&cfg) }
    public var localModelPref: String? { get { withCfg { $0.localModelPref } } set { withCfg { $0.localModelPref = newValue } } }
    public var disabled: Set<String> { get { withCfg { $0.disabled } } set { withCfg { $0.disabled = newValue } } }
    /// PHASE 1 : bascule atomique d'un cerveau (POST /api/brains/toggle) ; rend la liste triée à mémoriser (brains_off).
    @discardableResult public func setDisabled(_ id: String, _ off: Bool) -> [String] {
        withCfg { c in if off { c.disabled.insert(id) } else { c.disabled.remove(id) }; return c.disabled.sorted() }
    }
    public var firstTokenTimeout: TimeInterval { get { withCfg { $0.firstTokenTimeout } } set { withCfg { $0.firstTokenTimeout = newValue } } }   // défaut 9 s : voir RouterConfig
    /// 01/11 (chat abouti) : sortie RÉALISTE d'un appel pour la réservation (journal cerveaux du 01/11 : 60 appels de chat Spark 1.3,
    /// sortie max 1 872 jetons, médiane < 300) — marge ×2. Le pire cas (plafond complet) reste contrôlé sous les plafonds.
    public static let realisticOut: Int = 4000
    /// Cerveaux réservés au coût réaliste (usage toujours rapporté par le fournisseur) : Meta Muse (api.meta.ai).
    public static func reservesRealistic(_ s: BrainSpec) -> Bool { s.model.hasPrefix("muse-") && (URL(string: s.baseURL)?.host ?? "") == "api.meta.ai" }
    public var globalDeadline: TimeInterval = 75     // AUDIT-24/10: 25 → 75 s, sinon [tiers] n'était jamais atteint après un [tiers] lent — NOVA2-DEADLINE : budget total d'une requête chat, tous replis confondus
    public var maxChain: Int = 6                     // NOVA2-PLAFOND : nombre maximal de cerveaux essayés par requête (le local reste ajouté en filet)
    let creditLock = NSLock(); var creditDeadUntil: [String: Date] = [:]

    public init(keys: KeyStore, brains: [BrainSpec] = Catalog.defaults()) {
        runner = BrainRunner(keys: keys); self.brains = brains
    }

    public func engines(force: Bool = false) -> [LocalEngine] {
        lock.lock(); let c = localCache; lock.unlock()
        if !force && Date().timeIntervalSince(c.0) < (c.1.isEmpty ? 60 : 15) { return c.1 }   // aucun moteur local : on ne re-sonde les ports que toutes les 60 s (au lieu de 2 s)
        let e: [LocalEngine] = []   // hackathon Meta : aucun moteur local détecté (aucun modèle non Meta)
        lock.lock(); localCache = (Date(), e); lock.unlock()
        return e
    }

    /// Spécification du cerveau local courant (premier moteur détecté, modèle préféré sinon premier modèle).
    public func localSpec() -> BrainSpec? {
        if MetaOnly.enabled { return nil }   // 01/11 (meta_only) : aucun moteur local (modèles non Meta) — ni souverain, ni hors-ligne, ni filet
        guard let e = engines().first else { return nil }
        let model = (localModelPref.flatMap { e.models.contains($0) ? $0 : nil }) ?? e.models.first!
        return BrainSpec(id: "local", label: "Local · \(model) (\(e.name))", kind: .local,
                         baseURL: e.base + "/v1/chat/completions", model: model, keys: KeyChain([], fallback: "local-sans-cle"), tags: ["local"],   // LOT K (28/10) : sans valeur factice, resolve()=nil écartait le local de TOUT plan (plan l.177) — le hors-ligne ne pouvait jamais servir
                         note: "Fonctionne sans réseau.")
    }

    public func spec(_ id: String) -> BrainSpec? { brains.first { $0.id == id } ?? (id == "local" ? localSpec() : nil) }

    func isDead(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let d = health[id]?.deadUntil, d > Date() { return true }
        return false
    }
    func note(_ id: String, ok: Bool, ms: Int?, err: BrainFailure?) {
        lock.lock(); defer { lock.unlock() }
        var h = health[id] ?? BrainHealth()
        if ok { h.ok += 1; h.lastLatencyMs = ms; h.lastOK = Date(); h.deadUntil = nil; h.lastError = nil; h.lastKind = nil }
        else if let e = err, e.kind != .canceled {
            h.fail += 1; h.lastError = Knowledge.redact(e.message); h.lastKind = e.kind.rawValue   // AUDIT-24/10: message fournisseur masqué (fragments de clé)
            let cool: TimeInterval = e.kind == .credit || e.kind == .auth ? 1800 : (e.kind == .model ? 3600 : (e.kind == .rate ? 45 : 30))
            h.deadUntil = Date().addingTimeInterval(cool)
        }
        health[id] = h
    }
    public func resetHealth(_ id: String? = nil) { lock.lock(); if let i = id { health[i] = nil } else { health.removeAll() }; lock.unlock() }

    public func status(_ s: BrainSpec) -> (String, String) {   // (état, détail)
        // VAGUE-NUIT (item 1) : le cerveau de démo, pendant que le mode démo est actif, n'est
        // jamais servi « désactivé » — le contournement de run l'active à chaque réponse, donc
        // son état reflète sa disponibilité réelle (clé, santé). Sans cela, le sélecteur de démo
        // l'affichait « désactivé » pendant qu'il répondait (anomalie recette 3E).
        if disabled.contains(s.id), s.id != demoBrainId { return ("desactive", "désactivé par vous") }
        if s.kind != .local, s.keys.resolve(runner.keys) == nil { return ("sans_cle", "aucune clé trouvée dans le Trousseau") }
        lock.lock(); let h = health[s.id]; lock.unlock()
        if let d = h?.deadUntil, d > Date() { return ("panne", "\(h?.lastKind ?? "?") : \(h?.lastError ?? "") — nouvel essai dans \(Int(d.timeIntervalSinceNow)) s") }
        if h?.lastOK != nil { return ("ok", "répond (\(h?.lastLatencyMs ?? 0) ms)") }
        // CORR-BATTERIE (écart B-1, R-207) : un cerveau DÉJÀ MESURÉ qui a échoué (cooldown expiré,
        // jamais réussi dans ce processus) n'est pas « pas encore testé ». Sans cet état, il retombait
        // à « non_teste » pour toujours après un échec à cooldown court (ex. réseau, 30 s) et l'Accueil
        // affichait « diagnostic en cours » en permanence, le web lisant « inconnu » comme un diagnostic
        // en cours. On sert l'échec mesuré : « en panne », avec la dernière erreur réelle.
        if let hh = h, hh.fail > 0 {
            return ("panne", "\(hh.lastKind ?? "échec") : \(hh.lastError ?? "échec mesuré") — mesuré, en attente d'un nouvel essai")
        }
        return ("non_teste", "clé présente, pas encore testé")
    }

    /// LOT2 P-E5 : libellés servis au web — français propre, jamais un code interne (non_teste, sans_cle…) à l'écran.
    /// Les codes internes de status() restent inchangés (App.swift:136 s'appuie dessus) ; la traduction se fait ici, à la frontière de service.
    /// « inconnu » (clé présente, pas encore mesuré) est un état distinct de « en panne » (échec mesuré) : ne jamais les confondre.
    public static func etatLibelle(_ code: String) -> String {
        switch code {
        case "ok": return "prêt"
        case "non_teste": return "inconnu"
        case "sans_cle": return "sans clé"
        case "desactive": return "désactivé"
        case "panne": return "en panne"
        case "absent": return "absent"
        default: return "inconnu"
        }
    }

    public func healthSnapshot() -> [[String: Any]] {
        var out: [[String: Any]] = []
        var all = brains
        if let l = localSpec() { all.append(l) }
        (runner.keys as? KeychainStore)?.warm(Array(Set(all.flatMap { $0.keys.refs })))   // lectures du Trousseau en parallèle
        let metaOnly: Bool = MetaOnly.enabled
        for s in all where !Catalog.isHidden(s.id) || s.id == demoBrainId {   // POLITIQUE CERVEAUX (24/10) : cerveaux masqués absents des listes servies (sauf héros du mode démo actif)
            // 01/11 (voix-rapide, défaut d'interface) : en meta_only, les sélecteurs ne listent QUE les cerveaux Meta (ligne « Local »
            // comprise : aucun moteur local en version Meta). Source unique : /api/state « brains ».
            let isMeta: Bool = MetaOnly.isMeta(s)
            if metaOnly && !isMeta { continue }
            let (stBrut, det) = s.id == "local" ? ("ok", "moteur local détecté") : status(s); let st = Router.etatLibelle(stBrut)
            // VAGUE-NUIT (item 1) : si le héros de démo figure dans brains_off, son détail le DIT —
            // l'état n'est plus « désactivé » (voir status()), et le contournement est nommé, pas tu.
            let detFinal: String = (s.id == demoBrainId && disabled.contains(s.id)) ? det + " — désactivé dans ta liste, mais le mode démo l'active pour chaque réponse" : det
            lock.lock(); let h = health[s.id] ?? BrainHealth(); lock.unlock()
            out.append(["id": s.id, "label": s.label, "model": s.model, "kind": "\(s.kind)", "etat": st, "detail": detFinal,
                        "ok": h.ok, "echecs": h.fail, "latence_ms": h.lastLatencyMs as Any? ?? NSNull(), "note": s.note, "tags": Array(s.tags).sorted(),
                        "meta": isMeta])
        }
        if all.last?.id != "local" && !metaOnly { out.append(["id": "local", "label": "Local (aucun moteur détecté)", "model": "", "kind": "local",
                                                 "etat": "absent", "detail": "Aucun moteur local en version Meta.", "ok": 0, "echecs": 0,
                                                 "latence_ms": NSNull(), "note": "", "tags": ["local"]]) }
        return out
    }

    /// Ordre effectif : préféré en tête, puis l'ordre du mode, puis le reste, local à la fin. Les cerveaux sans clé ou en panne sont sautés.
    public var bulkEconomy: Bool { get { withCfg { $0.bulkEconomy } } set { withCfg { $0.bulkEconomy = newValue } } }   // PHASE 1 : sous cfgLock (était nonisolated(unsafe))
    // VAGUE-NUIT (item 1) : mode démo — posés par l'app (NovaApp.syncDemoBrain) quand demo_mode
    // est actif, remis à nil sinon. demoBrainId = le héros de la démo : traité comme DISPONIBLE
    // malgré brains_off (état servi + plans de run), sans jamais réécrire brains_off ni disabled.
    // demoFallbackId = le cerveau par défaut du quotidien : repli du héros dans les plans démo.
    public var demoBrainId: String? { get { withCfg { $0.demoBrainId } } set { withCfg { $0.demoBrainId = newValue } } }
    public var demoFallbackId: String? { get { withCfg { $0.demoFallbackId } } set { withCfg { $0.demoFallbackId = newValue } } }
    public func plan(mode: String, preferred: String?, exempt: String? = nil, outils: Bool = false) -> [BrainSpec] {
        var ids: [String] = []
        // 01/11 (routage par spécialité, MetaSpecialites) : ordre de la spécialité (Meta d'abord, puis 2 secours gratuits) ; nil = ancien ordre.
        // « voice » n'est JAMAIS re-routé (exception absolue de la voix live).
        let specOrder: [String]? = MetaSpecialites.ordre(mode: mode, outils: outils)
        var activeHead: String? = nil
        let exclSet: Set<String> = (mode != "voice" && MetaSpecialites.actif) ? MetaSpecialites.exclus : []   // lu une fois par plan
        if let p = preferred, !p.isEmpty, p != "auto" { ids.append(p) }
        else if specOrder == nil || MetaSpecialites.gardeCerveauActifEnTete(mode: mode) {
            let activeId: String = Settings().get("brain", "spark-1.3")   // 25/10 : sans préférence, le cerveau ACTIF passe en tête de chaîne
            if usable(activeId) { ids.append(activeId); activeHead = activeId }
        }
        // AUDIT-24/10: politique verrouillée — l'ordre fast/deep ([tiers] → [tiers]) n'est plus réordonné par BrainRank (qui pénalisait [tiers]) ;
        // BrainRank ne joue plus que sur l'ordre « bulk » économique. [tiers] épinglé (Dots) : [tiers] passe en secours avant [tiers].
        let bulkEco: Bool = mode == "bulk" && bulkEconomy
        var modeOrder: [String] = mode == "deep" ? Catalog.deepOrder : bulkEco ? Catalog.bulkOrder : Catalog.fastOrder
        if let so = specOrder { modeOrder = so }   // 01/11 : ordre mesuré de la spécialité — jamais réordonné par BrainRank
        ids += (bulkEco && specOrder == nil) ? BrainRank.reorder(modeOrder) : modeOrder
        // AUDIT-24/10: neutralisé — « ids += brains.map { $0.id } » ajoutait tout le catalogue ([tiers], [tiers], [tiers], [tiers], [tiers]…)
        // à la chaîne automatique. Un cerveau choisi explicitement (preferred) reste épinglé en tête ; le local est ajouté en filet par chat().
        var seen = Set<String>(); var out: [BrainSpec] = []
        for i in ids where !seen.contains(i) {
            seen.insert(i)
            // DIAG2-CERVEAUX : un choix EXPLICITE (preferred — défaut des Réglages ou sélecteur de la
            // conversation) n'est jamais écarté par « disabled »/brains_off : la désactivation ne gouverne
            // que la chaîne automatique. « local » se résout via localSpec() : il n'est pas dans brains[].
            let pinned = preferred != nil && preferred != "auto" && i == preferred
            // RÈGLE 1.7 (mission 26/10, audit 27/10 : 8 tours Contributor retrouvés dans des
            // flux personnels de la veille) : Contributor et Muse Code (Contributor Meta par
            // défaut) n'entrent JAMAIS dans une chaîne automatique — choix explicite seulement.
            if (i.hasSuffix("-contributor") || i == "muse-code") && !pinned && exempt != i { continue }
            if Catalog.isHidden(i) && !pinned && exempt != i { continue }
            // 01/11 (ordre d'Ahadi) : sans clé, sans crédit ou conditions non conformes → hors chaînes AUTOMATIQUES (réversible :
            // réglage chaines_auto_exclus ou routage_specialites=false). Choix épinglé, cerveau actif des Réglages et voix live : jamais écartés.
            if i != activeHead && !pinned && exempt != i && exclSet.contains(i) { continue }   // POLITIQUE CERVEAUX (24/10) : un cerveau masqué n'entre jamais dans une chaîne automatique
            guard let s = (i == "local" ? localSpec() : brains.first(where: { $0.id == i })), !disabled.contains(i) || exempt == i || pinned else { continue }   // DIAG2 P1 : exemption de RUN (mode démo) — « disabled » et brains_off ne sont jamais modifiés
            if s.keys.resolve(runner.keys) == nil { continue }
            // 01/11 (meta_only) : seuls les cerveaux de la famille Meta entrent dans une chaîne — y compris un choix explicite.
            if MetaOnly.enabled && !MetaOnly.isMeta(s) { continue }
            out.append(s)
        }
        // VAGUE-NUIT (item 1) : en mode démo (exempt posé par l'app), le repli du héros est le
        // cerveau par défaut du quotidien (demoFallbackId) — il passe juste derrière le héros,
        // avant le reste de la chaîne : si le héros échoue, la bascule NOMMÉE (.failover) tombe
        // sur le défaut d'Ahadi, pas sur un ordre de catalogue.
        if let ex = exempt, let fb = demoFallbackId, fb != ex, let fi = out.firstIndex(where: { $0.id == fb }), fi > 1 {
            let f = out.remove(at: fi); out.insert(f, at: 1)
        }
        let capped: [BrainSpec] = Array(out.prefix(maxChain))
        return capped   // NOVA2-PLAFOND
    }

    /// 25/10 : un cerveau est-il utilisable MAINTENANT ? (catalogue, non coupé, clé présente, pas en panne, hôte non « crédit épuisé »)
    /// 29/10 : pourquoi un cerveau n'est pas utilisable (diagnostic du banc et de la veille) — "" si utilisable.
    public func whyUnusable(_ id: String) -> String {
        guard let sp: BrainSpec = brains.first(where: { (b: BrainSpec) -> Bool in b.id == id }) else { return "inconnu du catalogue" }
        if MetaOnly.enabled && !MetaOnly.isMeta(sp) { return "non Meta : écarté par le mode meta_only" }
        if disabled.contains(id) { return "coupé dans Réglages › Cerveaux actifs" }
        if sp.keys.resolve(runner.keys) == nil { return "clé API absente du Trousseau" }
        if isDead(id) {
            lock.lock(); let h: BrainHealth? = health[id]; lock.unlock()
            return "en panne — " + (h?.lastKind ?? "?") + " : " + String((h?.lastError ?? "").prefix(200))
        }
        let host: String = URL(string: sp.baseURL)?.host ?? sp.baseURL
        creditLock.lock()
        let until: Date? = creditDeadUntil[host]
        creditLock.unlock()
        if let u = until, u > Date() { return "crédit épuisé ou limite atteinte (réessai après " + ISO8601DateFormatter().string(from: u) + ")" }
        return ""
    }
    public func catalogIds() -> [String] { brains.map { (b: BrainSpec) -> String in b.id } }
    /// 01/11 (meta_only) : filtre une chaîne sur la famille Meta ; nil = il reste au moins un cerveau Meta. Un choix explicite
    /// non Meta est journalisé comme bloqué (releves/diag/meta_only_journal.jsonl) ; rien n'est envoyé.
    func metaOnlyRefusal(chain: [BrainSpec], preferred: String?, mode: String) -> String? {
        if let p = preferred, !p.isEmpty, p != "auto", let ps = brains.first(where: { $0.id == p }), !MetaOnly.isMeta(ps) {
            _ = MetaOnly.gate(spec: ps, source: "router.chat")
        }
        if chain.contains(where: { MetaOnly.isMeta($0) }) { return nil }
        let asked: String = (preferred ?? "").isEmpty || preferred == "auto" ? "" : " (demandé : « " + (preferred ?? "") + " »)"
        journal.add(["meta_only": "aucun_cerveau_meta", "mode": mode, "demande": preferred ?? ""])
        return "Mode meta_only : aucun cerveau Meta utilisable" + asked + " — clé Meta absente, cerveau en panne ou crédit épuisé. Aucun repli vers un modèle non Meta."
    }
    /// 01/11 (meta_only) : premier cerveau Meta utilisable — le préféré s'il l'est, sinon l'ordre du catalogue (famille Meta).
    public func firstUsableMeta(preferring p: String? = nil) -> String? {
        if let p = p, let s = brains.first(where: { $0.id == p }), MetaOnly.isMeta(s), usable(p) { return p }
        return brains.first(where: { (b: BrainSpec) -> Bool in MetaOnly.isMeta(b) && !b.id.hasSuffix("-contributor") && b.id != "muse-code" && usable(b.id) })?.id
    }

    /// 31/10 : utilisable si l'on ignore seulement la coupure « Cerveaux actifs » (clé présente, pas en panne, hôte avec crédit).
    func usableIgnoringOff(_ id: String) -> Bool {
        guard let sp: BrainSpec = brains.first(where: { (b: BrainSpec) -> Bool in b.id == id }) else { return false }
        if MetaOnly.enabled && !MetaOnly.isMeta(sp) { return false }   // 01/11 (meta_only)
        if sp.keys.resolve(runner.keys) == nil { return false }
        if isDead(id) { return false }
        let host: String = URL(string: sp.baseURL)?.host ?? sp.baseURL
        creditLock.lock()
        let until: Date? = creditDeadUntil[host]
        creditLock.unlock()
        if let u = until, u > Date() { return false }
        return true
    }
    public func usable(_ id: String) -> Bool {
        if id.isEmpty || id == "auto" { return false }
        if id == "local" { return localSpec() != nil }
        guard let sp: BrainSpec = brains.first(where: { (b: BrainSpec) -> Bool in b.id == id }) else { return false }
        if MetaOnly.enabled && !MetaOnly.isMeta(sp) { return false }   // 01/11 (meta_only) : un cerveau non Meta n'est jamais « utilisable » (relais voix, tri rapide, rebranchement compris)
        if disabled.contains(id) { return false }
        if sp.keys.resolve(runner.keys) == nil { return false }
        if isDead(id) { return false }
        let host: String = URL(string: sp.baseURL)?.host ?? sp.baseURL
        creditLock.lock()
        let until: Date? = creditDeadUntil[host]
        creditLock.unlock()
        if let u = until, u > Date() { return false }
        return true
    }

    /// 25/10 : cerveau demandé → cerveau réellement utilisé. Demandé et utilisable : inchangé. Sinon le cerveau ACTIF
    /// (Réglages « brain », Spark par défaut), sinon le premier utilisable des chaînes. Rien d'utilisable : la demande
    /// d'origine est rendue telle quelle (la chaîne tentera quand même plutôt que de rester muette).
    func resolvePreferred(_ p: String?, onEvent: ((BrainEvent) -> Void)?) -> String? {
        guard let want = p, !want.isEmpty, want != "auto" else { return p }
        if LLMSpend.isBench() { return want }   // WP2 : banc strict — jamais rebranché sur un autre cerveau (l'échec est nommé)
        if usable(want) { return want }
        // 31/10 (Ahadi : « je change de cerveau, ça s'affiche mais rien ne change ») : un cerveau choisi À LA MAIN dans le chat
        // (tour interactif) n'est plus remplacé parce qu'il est seulement « coupé » dans Réglages › Cerveaux actifs — la coupure ne
        // gouverne que la chaîne automatique (règle DIAG2, déjà appliquée par plan()). Sans clé, en panne ou sans crédit : relais comme avant.
        if LLMSpend.isInteractive(), disabled.contains(want), usableIgnoringOff(want) { return want }
        let active: String = Settings().get("brain", "spark-1.3")
        var pick: String? = nil
        if active != want && usable(active) { pick = active }
        if pick == nil {
            let pool: [String] = MetaSpecialites.actif ? (["spark-1.3", "spark-1.2", "wonder-1.0"] + MetaSpecialites.secoursMeta) : (["spark-1.3"] + Catalog.fastOrder)   // 01/11 : Meta, puis Spark Open (Baseten) en secours Meta
            for c in pool where c != want && usable(c) && !MetaSpecialites.exclu(c) { pick = c; break }
        }
        guard let to = pick else { return want }
        journal.add(["rebranche": true, "from": want, "to": to])
        let fromLabel: String = brains.first(where: { (b: BrainSpec) -> Bool in b.id == want })?.label ?? want
        let toLabel: String = brains.first(where: { (b: BrainSpec) -> Bool in b.id == to })?.label ?? to
        let arg: String = fromLabel + " indisponible → branché sur " + toLabel
        onEvent?(.step(kind: "step", info: ["id": String(UUID().uuidString.prefix(8)).lowercased(), "index": 0, "tool": "cerveau", "arg": arg, "state": "ok", "ts": nowISO()]))
        return to
    }

    /// AUDIT-BRAIN-A : consigne de continuation automatique (stop_reason == max_tokens).
    public static let continuePrompt: String = "Continue exactement là où tu t'es arrêté, sans répéter."
    /// AUDIT-BRAIN-A : retire un bloc de prose du système (idempotent ; sans effet s'il est absent).
    public static func stripBlock(_ s: String, _ block: String) -> String {
        guard !block.isEmpty, s.contains(block) else { return s }
        let once: String = s.replacingOccurrences(of: "\n" + block, with: "")
        return once.replacingOccurrences(of: block, with: "")
    }
    /// AUDIT-BRAIN-A : insère un bloc dans le PRÉFIXE STABLE du système (avant Persona.cacheMark, donc en cache) ;
    /// sans marque, en fin de système. Idempotent : jamais ajouté deux fois.
    public static func insertStable(_ s: String, _ block: String) -> String {
        guard !block.isEmpty, !s.contains(block) else { return s }
        if let r = s.range(of: Persona.cacheMark) { return String(s[..<r.lowerBound]) + "\n" + block + String(s[r.lowerBound...]) }
        return s.isEmpty ? block : s + "\n" + block
    }

    @discardableResult
    public func chat(messages: [ChatMsg], system: String?, mode: String = "fast", preferred: String? = nil,
                     exempt: String? = nil, maxTokens: Int = 1500, cancel: @escaping () -> Bool = { false }, deadline: TimeInterval? = nil,
                     solo: Bool = false, toolCtx: ToolCtx? = nil, onEvent: @escaping (BrainEvent) -> Void) -> String? {
        // AUDIT-BRAIN-A : toolCtx (boucle agent avec outils) — par cerveau : [tiers] = tools natifs, autres = protocole texte.
        // Résultat structuré de l'appel qui aboutit déposé dans toolCtx.blocks / toolCtx.stopReason. nil = comportement d'avant.
        toolCtx?.blocks = []; toolCtx?.stopReason = ""; toolCtx?.nativeActive = false
        // 25/10 (ordre d'Ahadi) : AUCUNE fonction ne reste en plan parce que le cerveau sur lequel on l'avait branchée
        // est inactif (coupé, sans crédit, en panne, sans clé) — elle se rebranche seule sur le cerveau ACTIF
        // (défaut des Réglages, sinon le premier disponible). Bascule visible dans le fil et journalisée.
        let preferred: String? = resolvePreferred(preferred, onEvent: onEvent)
        let chatT0 = Date()   // P1-INSTR (23/10) : envoi de l'appel — origine du ttft mesuré au premier fragment (M2)
        var ttftDone = false   // P1-INSTR (23/10) : un seul ask_ttft par appel, au premier fragment reçu
        var chain = plan(mode: mode, preferred: preferred, exempt: exempt, outils: toolCtx != nil)
        // FIX-RADAR : voie producteur ÉPINGLÉE (solo) — la chaîne est réduite au cerveau
        // demandé (celui des Réglages) : aucun parcours du catalogue, et le filet local
        // plus bas est coupé. Sans cela, « preferred » n'était qu'une tête de chaîne : au
        // premier échec, l'appel traversait tout le catalogue puis finissait sur le
        // moteur local — alors même que « local » figure dans brains_off et que
        // brains_lock est actif (le verrou n'est lu que par le handler de chat,
        // App.swift) — jusqu'au piège « raisonnement sans texte » d'un modèle local
        // à réflexion (recette 3F, Bloc 5 : 3 passes radar mortes sur le Local).
        // 29/10 : un cerveau épinglé SANS crédit ou en panne ne bloque plus une tâche de fond : la chaîne de relais prend la suite.
        // 31/10 : au BANC, l'épinglage est STRICT — un cerveau sans crédit échoue sous son nom (avant : [tiers] répondait et notait à
        // la place de [tiers], sous l'étiquette de [tiers]). Hors banc, la règle du 29/10 reste.
        // WP2 : banc STRICT dès qu'un cerveau est épinglé (solo ou non) — chaîne réduite à lui, aucun relais, aucun local, aucun souverain.
        let strictBench: Bool = LLMSpend.isBench() && !(preferred ?? "").isEmpty && preferred != "auto"
        if solo || strictBench, let p = preferred, !p.isEmpty, p != "auto", usable(p) || p == "local" || LLMSpend.isBench() { chain = chain.filter { $0.id == p } }
        // 01/11 (meta_only) : contrôle AVANT toute décision de dépense ou de réseau — sans cerveau Meta, échec visible et nommé.
        if MetaOnly.enabled, let why = metaOnlyRefusal(chain: chain, preferred: preferred, mode: mode) { onEvent(.error(why)); return nil }
        // PHASE2-V2 : registre (Config/brains.json) + politique de données (Config/provider_terms.json) + grand livre (couts_v2.sqlite).
        // Réglage « routage_v2 », FAUX par défaut : rien ne change. Vrai : chaîne du profil filtrée par la classe de données, réservation
        // atomique avant chaque envoi, aucun moteur local (règle 6), échec fermé avec message clair. Voir docs/ROUTAGE_V2.md.
        let v2On: Bool = RoutingV2.enabled
        var v2: RoutingV2.Prepared? = nil
        var v2Refused: String? = nil
        let v2EstIn: Int = TokenEst.of(system ?? "") + TokenEst.of(messages)
        if v2On {
            switch RoutingV2.prepare(router: self, mode: mode, preferred: preferred, estIn: v2EstIn, maxOut: maxTokens, background: !LLMSpend.isInteractive() && mode != "voice") {
            case .blocked(let why):
                journal.add(["v2": "bloque", "mode": mode, "why": Knowledge.redact(shortError(why, 300))])
                onEvent(.error(why)); return nil
            case .ok(let p):
                v2 = p; chain = p.chain
                if solo, let pp = preferred, !pp.isEmpty, pp != "auto" {
                    chain = chain.filter { $0.id == pp }
                    if chain.isEmpty { onEvent(.error("Routage v2 : le cerveau épinglé « \(pp) » n'est pas autorisé pour ces données ou ce budget — échec fermé.")); return nil }
                }
                journal.add(["v2": "plan", "profil": p.profile, "classe": p.cls.rawValue, "chaine": chain.map { $0.id }.joined(separator: ">")])
                onEvent(.step(kind: "step", info: ["id": String(UUID().uuidString.prefix(8)).lowercased(), "index": 0, "tool": "cerveau", "arg": p.disclosure, "state": "ok", "ts": nowISO()]))
            }
        }
        // 29/10 (Ahadi : 120 $ d'API [tiers] consommés) : dépense maîtrisée — le fond ne prend jamais un cerveau premium,
        // plafond du jour pour le fond, budget du mois (alerte 80 %, gratuits seulement à 100 %). Voir Feat_Depense.swift.
        let isBackground: Bool = !LLMSpend.isInteractive() && mode != "voice"
        // WP2 : décision EXPLICITE (eligibleChain / blocked / overrideRequired) — la chaîne d'origine n'est jamais rétablie ;
        // facturation inconnue ≠ gratuit ; réservation atomique avant chaque envoi (grand livre couts_v2.sqlite) plus bas.
        let spendLane: SpendLane = LLMSpend.currentLane(background: isBackground)
        let pinnedPref: String? = (preferred ?? "auto") == "auto" || (preferred ?? "").isEmpty ? nil : preferred
        let brainMaxFor: (BrainSpec) -> Int = { (b: BrainSpec) -> Int in
            b.model.hasPrefix("muse-spark") ? max(maxTokens, 12000) : (b.model.contains("Muse-Spark") ? max(maxTokens, 8000) : maxTokens)
        }
        var v1Refused: String? = nil
        let spendExcl: Set<String> = (mode != "voice" && MetaSpecialites.actif) ? MetaSpecialites.exclus : []   // 01/11
        if !v2On {   // PHASE2-V2 : le budget v2 (grand livre) remplace cette décision
            // Cerveau choisi explicitement : épinglé, sinon (premier plan) le cerveau ACTIF des Réglages — seuls choix qui admettent une facturation inconnue.
            let billingPinned: String? = pinnedPref ?? (spendLane == .interactive ? Settings().get("brain", "") : nil)
            let freeFallback: Bool = !solo && !strictBench && localSpec() != nil
            switch LLMSpend.decideChain(chain, all: brains, usable: { (i: String) -> Bool in self.usable(i) && !spendExcl.contains(i) }, lane: spendLane,   // 01/11 : un cerveau hors chaînes auto n'est pas réinséré par la voie de fond
                                        pinned: spendLane == .bench ? pinnedPref : billingPinned, estIn: v2EstIn, maxOut: maxTokens, freeFallback: freeFallback) {
            case .eligibleChain(let c, let n):
                if let n = n, c.map({ $0.id }) != chain.map({ $0.id }) {
                    journal.add(["depense": n, "avant": chain.first?.id ?? "", "apres": c.first?.id ?? "", "fond": isBackground, "voie": spendLane.rawValue])
                }
                chain = c
            case .blocked(let why):
                journal.add(["depense": "bloque", "voie": spendLane.rawValue, "why": shortError(why, 300)])
                onEvent(.error(why)); return nil
            case .overrideRequired(let why, let est):
                journal.add(["depense": "derogation_requise", "voie": spendLane.rawValue, "estime_usd": Money.usd(est), "why": shortError(why, 300)])
                onEvent(.error(why + " (coût estimé de l'appel : \(Money.format(est)) ; dérogation : POST /api/depense/derogation)")); return nil
            }
        }
        // VAGUE 2 (RÉSILIENCE) : état du réseau mesuré par Feat_Resilience (NetState). Hors ligne : aucun essai
        // cloud (chacun coûterait son délai de premier mot) — le cerveau local répond seul s'il existe ; sinon
        // réponse honnête immédiate (la demande de chat est gardée par le portail /api/chat de Feat_Resilience).
        // Faible : délais allongés (×1,5 premier mot, ×1,4 budget global) et consigne courte de concision.
        let netLevel: String = NetState.levelForRouting()
        var offlineLocal: Bool = false
        if strictBench && netLevel == "hors_ligne" {   // WP2 : banc strict — jamais de substitution locale
            onEvent(.error("Hors ligne : banc strict, « \(preferred ?? "") » n'est remplacé par aucun autre cerveau.")); return nil
        }
        if v2On && netLevel == "hors_ligne" {   // PHASE2-V2 : jamais de repli local (règle 6)
            journal.add(["offline": true, "mode": mode, "v2": true])
            onEvent(.error("Hors ligne : aucun cerveau cloud joignable, et le routage v2 n'utilise jamais de modèle local (règle 6)."))
            return nil
        }
        if netLevel == "hors_ligne" {
            if let l = localSpec(), !solo || preferred == "local" {
                chain = [l]; offlineLocal = true
                journal.add(["offline": true, "mode": mode, "local": l.model])
                onEvent(.step(kind: "step", info: ["id": String(UUID().uuidString.prefix(8)).lowercased(), "index": 0, "tool": "cerveau", "arg": "hors ligne : réponse par le cerveau local (sans réseau)", "state": "ok", "ts": nowISO()]))
            } else {
                journal.add(["offline": true, "mode": mode, "local": false])
                let lastUser: String = messages.last(where: { $0.role == "user" })?.content ?? ""
                onEvent(.error(NetState.offlineMessage(forPrompt: lastUser)))
                return nil
            }
        }
        let weakNet: Bool = netLevel == "faible"
        // Souverain d'abord : le modèle local répond seul si, et seulement si, délai et qualité sont tenus ; sinon le cloud reprend sans que l'utilisateur ait attendu pour rien.
        var sovereignTried = false
        if !offlineLocal, !v2On, !strictBench, sovereignEligible(mode: mode, preferred: preferred, messages: messages, system: system), let l = localSpec() {
            sovereignTried = true
            // AUDIT-BRAIN-A : le local parle le protocole texte — il le reçoit quand le run a des outils.
            let sysSov: String? = toolCtx.map { Router.insertStable(Router.stripBlock(system ?? "", $0.nativeRules), $0.textProtocol) } ?? system
            if let id = trySovereign(l, messages: messages, system: sysSov, maxTokens: maxTokens, mode: mode, cancel: cancel, onEvent: onEvent) { return id }
            if cancel() { onEvent(.error("annulé")); return nil }
        }
        // Un cerveau choisi explicitement par l'utilisateur est toujours essayé en premier, même s'il était en panne.
        let pinned = (preferred ?? "auto") == "auto" ? nil : preferred
        // 25/10 : un hôte « crédit épuisé » (402 < 30 min) compte comme en panne ICI aussi. Avant, Spark/[tiers]
        // (en pause après un échec passager) sortaient de la chaîne alors que [tiers]/[tiers], gardés, étaient
        // ensuite sautés en silence (crédit) : zéro essai, « Tous les cerveaux ont échoué. Dernier : » vide.
        var cdHosts0: Set<String> = []
        creditLock.lock()
        let nowCD: Date = Date()
        for (h, t) in creditDeadUntil where t > nowCD { cdHosts0.insert(h) }
        creditLock.unlock()
        let skipDead: [BrainSpec] = chain.filter { (b: BrainSpec) -> Bool in
            if b.id == pinned { return !isDead(b.id) || chain.count == 1 }   // 29/10 : épinglé en panne → on ne le retente pas à chaque tour, le relais répond
            if isDead(b.id) { return false }
            let host: String = URL(string: b.baseURL)?.host ?? b.baseURL
            if b.kind != .local && cdHosts0.contains(host) { return false }
            return true
        }
        // Si tout est « en panne » (ex. coupure réseau passée), on réessaie quand même plutôt que de rester muet.
        if !skipDead.isEmpty { chain = skipDead }
        if !solo, !v2On, !strictBench, let l = localSpec(), (!sovereignTried || chain.isEmpty) && !chain.contains(where: { $0.id == "local" }) { chain.append(l) }   // POLITIQUE CERVEAUX (24/10) : local TOUJOURS en dernier, y compris en bulk économique (avant : inséré en tête)
        // Tâches de fond sur modèles légers/gratuits : consigne anti-invention stricte (jamais pour le chat et la voix de l'assistant).
        var system = system
        if weakNet && mode != "bulk" { system = (system ?? "") + "\n\n" + NetState.weakNote }   // VAGUE 2 : en fin de système (partie dynamique), jamais dans le préfixe en cache
        if mode == "bulk" { system = (system ?? "") + "\n\nRÈGLES STRICTES (anti-invention) : n'affirme que ce qui figure dans les données fournies ou dans un résultat d'outil. Si une information manque, écris « non disponible » au lieu de deviner. Ne fabrique ni chiffre, ni date, ni nom, ni source. Réponds en français, court et factuel." }
        // 01/11 (meta_only) : dernière passe AVANT tout envoi — chaîne v1 ou v2, épinglage, banc : rien de non Meta ne part.
        if MetaOnly.enabled {
            chain = chain.filter { MetaOnly.isMeta($0) }
            if let why = metaOnlyRefusal(chain: chain, preferred: nil, mode: mode) { onEvent(.error(why)); return nil }
        }
        MetaSpecialites.noterRoutage(mode: mode, outils: toolCtx != nil, chain: chain)   // 01/11 : une ligne « specialite » par requête routée
        if chain.isEmpty {
            onEvent(.error("Aucun cerveau disponible : aucune clé trouvée et aucun moteur local détecté. Ouvre Connexions pour ajouter une clé.")); return nil
        }
        let leadId: String? = chain.first?.id
        var previous: BrainSpec? = nil
        var lastFail = ""
        var attempts: Int = 0   // 25/10 : cerveaux réellement essayés (0 = tous écartés)
        var creditDeadHosts = Set<String>()   // crédit épuisé (402) : inutile d'essayer les autres modèles du même fournisseur
        creditLock.lock(); let now0 = Date(); for (h, t) in creditDeadUntil where t > now0 { creditDeadHosts.insert(h) }; creditLock.unlock()   // et on s'en souvient 30 min : plus de 10 essais perdus à chaque message
        let budget0: TimeInterval = deadline ?? globalDeadline
        let budget1: TimeInterval = weakNet ? budget0 * 1.4 : budget0   // VAGUE 2 : réseau faible → budget global allongé
        // 26/10 : tâche de fond (bulk) menée par Spark → au moins 150 s ; Spark n'est plus coupé au milieu de sa réflexion.
        let sparkLead: Bool = (chain.first?.model ?? "").hasPrefix("muse-spark")
        let budget: TimeInterval = (mode == "bulk" && sparkLead) ? max(budget1, 150) : budget1
        // APPLY-BRIEFS H3 : date-butoir propre à l'appel (tâches de fond : 120 s) ; nil = défaut global (25 s) — pour le chat, rien ne change
        let deadlineDate = Date().addingTimeInterval(budget)   // NOVA2-DEADLINE
        for s in chain {
            if cancel() { onEvent(.error("annulé")); return nil }
            if Date() > deadlineDate { onEvent(.error("Délai global de \(Int(budget)) s dépassé — dernier essai : \(lastFail)")); return nil }   // NOVA2-DEADLINE : échec rapide et expliqué, jamais d'attente en cascade
            if s.kind != .local, s.id != pinned, creditDeadHosts.contains(URL(string: s.baseURL)?.host ?? s.baseURL) { continue }
            var v2Res: String? = nil   // PHASE2-V2 : réservation atomique AVANT l'envoi (plafonds mois / jour / tâche)
            var v1Ticket: SpendTicket? = nil   // WP2 : réservation v1 AVANT l'envoi — suites automatiques (≤ 2) et repli protocole texte compris
            if !v2On {
                // 01/11 (chat abouti) : réservation au coût RÉALISTE d'un appel (sortie ≤ Router.realisticOut, un seul appel) — avant :
                // pire cas engagé (plafond de sortie 12 000–32 000 jetons × 4 appels), ~0,54 $ réservés pour ~0,04 $ réels sur Spark 1.3,
                // et gardés tels quels à chaque annulation. Le pire cas reste EXIGÉ sous les plafonds (worstMaxOut / worstCalls).
                // Limité aux cerveaux Meta (muse-*) : leur usage est TOUJOURS rapporté (60/60 appels du journal du 01/11 avec in/out),
                // donc le solde suit le mesuré ; un fournisseur sans usage rapporté garde la réservation au pire cas (jamais sous-compté).
                let calls: Int = (maxTokens > 600 ? 3 : 1) + (toolCtx != nil ? 1 : 0)
                let realistic: Bool = Router.reservesRealistic(s)
                switch LLMSpend.preflight(spec: s, estIn: v2EstIn, maxOut: realistic ? min(brainMaxFor(s), Router.realisticOut) : brainMaxFor(s), calls: realistic ? 1 : calls,
                                          lane: spendLane, worstMaxOut: realistic ? brainMaxFor(s) : nil, worstCalls: realistic ? calls : nil) {
                case .refused(let why):
                    v1Refused = "Budget : " + why + " — rien n'est envoyé (aucune recharge automatique)."
                    journal.add(["depense": "reservation_refusee", "brain": s.id, "why": shortError(why, 300)])
                    continue
                case .go(let t): v1Ticket = t
                }
            }
            if let p = v2 {
                let calls: Int = (maxTokens > 600 ? 3 : 1) + (toolCtx != nil ? 1 : 0)   // suites automatiques (≤ 2) + repli protocole texte
                switch RoutingV2.reserve(p, specId: s.id, estIn: v2EstIn, maxOut: maxTokens, calls: calls) {
                case .refused(let why):
                    v2Refused = "Budget : " + why + " — rien n'est envoyé (aucune recharge automatique)."
                    journal.add(["v2": "reservation_refusee", "brain": s.id, "why": why])
                    continue
                case .reserved(let rid): v2Res = rid
                }
            }
            attempts += 1   // DIAG2-CERVEAUX : le cerveau choisi par Ahadi est essayé même si son hôte a eu un 402 dans les 30 min — s'il échoue encore, l'échec est journalisé et la bascule est visible, jamais un saut silencieux
            if let p = previous { onEvent(.failover(from: p.label, to: s.label, reason: lastFail, kind: "")) }
            if previous != nil { onEvent(.draftReset) }   // VÉRITÉ-3 (E3, 23/10) : la tentative qui suit une bascule REMPLACE tout texte déjà diffusé par la précédente (filet : le catch générique ci-dessous peut enchaîner après production partielle, sans passer par le garde « produced »)
            onEvent(.start(id: s.id, label: s.label))
            var produced = false; var text = ""
            var stopNote: String = ""   // AUDIT-24/10: « max_tokens » ou « cut » signalé par le flux
            let t0 = Date()
            var inTok = 0, outTok = 0
            // AUDIT-BRAIN-A : système et outils propres à CE cerveau. Natif ([tiers]) : schémas d'outils + règles courtes,
            // la prose du protocole texte est retirée ; texte (autres) : prose du protocole insérée dans le préfixe stable.
            var toolsForBrain: [[String: Any]]? = nil
            var sysForBrain: String? = system
            var textSys: String? = system
            if let tc = toolCtx {
                let ts: String = Router.insertStable(Router.stripBlock(system ?? "", tc.nativeRules), tc.textProtocol)
                textSys = ts
                sysForBrain = ts
            }
            // 29/10 (Ahadi : « pourquoi c'est faux, pas cohérent avec ce qui s'affiche en haut ») : le nom du cerveau qui rédige
            // VRAIMENT cette réponse est posé au moment de l'appel (après les bascules), pas deviné à l'avance.
            if let sb = sysForBrain, sb.contains("⟦SERVI_PAR⟧") { sysForBrain = sb.replacingOccurrences(of: "⟦SERVI_PAR⟧", with: s.label) }
            if let tsb = textSys, tsb.contains("⟦SERVI_PAR⟧") { textSys = tsb.replacingOccurrences(of: "⟦SERVI_PAR⟧", with: s.label) }
            // DIAG2-CONTEXTE P-CTX-7 : l'assemblage a été dimensionné pour le PREMIER cerveau de la
            // chaîne. Si la bascule amène un cerveau à fenêtre plus petite, on ré-ajuste (fin du fil
            // verbatim, résumé conservé, note moteur si besoin) au lieu de laisser le fournisseur
            // rejeter le contexte — le « repreneur qui ne sait pas de quoi on parle » ne doit jamais
            // venir d'un débordement de fenêtre. Le ré-ajustement est journalisé, jamais silencieux.
            var msgsForBrain: [ChatMsg] = messages
            let winBrain: Int = ContextWindow.tokens(for: s.id)
            let sysTok: Int = TokenEst.of(sysForBrain ?? "")
            let estIn: Int = sysTok + TokenEst.of(messages)
            if estIn > winBrain - maxTokens - max(1000, winBrain / 20) {
                msgsForBrain = ChatMsg.refit(messages, tokenBudget: max(2000, winBrain - maxTokens - max(1000, winBrain / 20) - sysTok))
                journal.add(["brain": s.id, "refit": true, "from_tokens": estIn, "window": winBrain])
            }
            // AUDIT-24/10 + AUDIT-BRAIN-A : délai du premier mot calculé à part (types explicites). Local : inchangé (un modèle local lit lentement un gros prompt).
            // [tiers] : max(12 s, 6 s + 1 s par 8 000 jetons d'entrée), plafonné à 45 s pour le cerveau épinglé / de tête, 30 s pour un secours ;
            // message_start, ping et début de bloc sont des signes de vie (le flux accorde alors ×2,5, cf. BrainRunner.stream).
            var ftt: TimeInterval = firstTokenTimeout
            if s.kind == .local {
                let promptChars: Int = messages.reduce((system ?? "").count) { $0 + $1.content.count }
                ftt = promptChars > 3500 ? 160 : 45
            }
            if weakNet && s.kind != .local { ftt = min(60, ftt * 1.5) }   // VAGUE 2 : réseau faible → premier mot attendu plus longtemps
            let cacheHist: Bool = toolCtx != nil || msgsForBrain.count >= 3   // AUDIT-BRAIN-A : points de cache sur l'historique (runs d'agent, conversations)
            var callIn: Int = 0, callOut: Int = 0
            var toolBlocks: [[String: Any]] = []
            var lastStopReason: String = ""
            var cacheRd: Int = 0, cacheWr: Int = 0
            var conts: Int = 0
            var nativeFallback: Bool = false
            func callStream(_ ms: [ChatMsg]) throws {
                toolCtx?.nativeActive = toolsForBrain != nil
                callIn = 0; callOut = 0
                // 26/10 (Ahadi : « enlève ces restrictions bidons ») : Spark réfléchit avant d'écrire — un plafond de sortie
                // court partait entièrement dans la réflexion (réponse vide ou tronquée). Plancher 12 000 jetons pour Spark.
                // 26/10 : « Muse Code (abonnement) » — pas d'HTTP : le CLI officiel « muse exec » (Feat_MuseCode.swift), réponse d'un bloc.
                if let why = MetaOnly.gate(spec: s, source: "router.call", logAllowed: !s.baseURL.hasPrefix("http")) { throw BrainFailure(kind: .other, message: why) }   // 01/11 (meta_only) : barrière par cerveau (Apple, CLI, HTTP)
                if s.baseURL.hasPrefix("cli://muse") {
                    let left: TimeInterval = max(20, deadlineDate.timeIntervalSinceNow)
                    let r: String = try MuseCodeCLI.run(system: sysForBrain, messages: ms, timeout: left, cancel: cancel)
                    produced = true; text += r; onEvent(.delta(r))
                    return
                }
                let brainMax: Int = s.model.hasPrefix("muse-spark") ? max(maxTokens, 12000) : (s.model.contains("Muse-Spark") ? max(maxTokens, 8000) : maxTokens)
                try runner.stream(s, messages: ms, system: sysForBrain, maxTokens: brainMax, mode: mode,
                                  firstTokenTimeout: ftt, cancel: cancel,
                                  onDelta: { if !ttftDone { ttftDone = true; _ = BlackBox.record(["tool": "ask_ttft", "actor": "Nova", "why": "premier jeton de la réponse en flux (M2)", "ok": true, "effect": "lecture", "result": "brain=\(s.id) ttft_ms=\(Int(Date().timeIntervalSince(chatT0) * 1000))"]) }; produced = true; text += $0; onEvent(.delta($0)) },
                                  onUsage: { callIn = $0; callOut = $1 }, onStop: { stopNote = $0 },
                                  tools: toolsForBrain, cacheHistory: cacheHist,
                                  onBlocks: { b, sr in
                                      toolBlocks += b.filter { ($0["type"] as? String) == "tool_use" }
                                      lastStopReason = sr
                                  },
                                  onCache: { cacheRd += $0; cacheWr += $1 })
                inTok += callIn; outTok += callOut
            }
            do {
                do { try callStream(msgsForBrain) }
                catch let f as BrainFailure where toolsForBrain != nil && !produced && f.kind == .other && f.message.contains("HTTP 400") {
                    // AUDIT-BRAIN-A : requête native refusée (schéma, bloc…) — même cerveau, protocole texte, une fois. Jamais muet : journalisé.
                    journal.add(["brain": s.id, "model": s.model, "native_fallback": true, "err": Knowledge.redact(shortError(f.message, 160))])
                    nativeFallback = true
                    toolsForBrain = nil; sysForBrain = textSys
                    try callStream(msgsForBrain)
                }
                // AUDIT-BRAIN-A : continuation automatique sur plafond de sortie (≤ 2 fois), concaténée au même flux — jamais sur un
                // tool_use (un appel tronqué n'est pas rendu : la boucle agent le traite).
                // 26/10 : jamais de « suite automatique » pour une réponse orale courte (≤ 600 jetons) — elle répétait la dernière phrase.
                while stopNote == "max_tokens", maxTokens > 600, conts < 2, toolBlocks.isEmpty, !text.isEmpty, !cancel(), Date() < deadlineDate {
                    conts += 1
                    onEvent(.step(kind: "step", info: ["id": String(UUID().uuidString.prefix(8)).lowercased(), "index": 0, "tool": "cerveau", "arg": "réponse longue : suite automatique \(conts)/2", "state": "ok", "ts": nowISO()]))
                    stopNote = ""
                    let contMsgs: [ChatMsg] = msgsForBrain + [ChatMsg("assistant", text), ChatMsg("user", Router.continuePrompt)]
                    do { try callStream(contMsgs) } catch { stopNote = "max_tokens"; break }
                }
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                note(s.id, ok: true, ms: ms, err: nil)
                LLMSpend.record(s.id, inTok: inTok, outTok: outTok, cacheRead: cacheRd, cacheWrite: cacheWr, background: isBackground, spec: s, ticket: v1Ticket)   // 29/10 : dépense réelle ; WP2 : rapprochement de la réservation
                if let rid = v2Res, let p = v2 { RoutingV2.settle(rid, p, specId: s.id, inTok: inTok, outTok: outTok, cacheRead: cacheRd, cacheWrite: cacheWr) }   // PHASE2-V2 : solde (usage absent → réservation gardée)
                journal.add(["brain": s.id, "model": s.model, "ok": true, "ms": ms, "chars": text.count, "in": inTok, "out": outTok, "truncated": stopNote,
                             "cache_read": cacheRd, "cache_write": cacheWr, "continuations": conts, "native": toolsForBrain != nil, "native_fallback": nativeFallback, "tool_uses": toolBlocks.count])   // AUDIT-BRAIN-A : cache réellement servi, suites, tool use
                // AUDIT-24/10: réponse TRONQUÉE (plafond de sortie ou flux coupé) — signalée dans le fil, jamais un succès silencieux
                if !stopNote.isEmpty {
                    let contNote: String = conts > 0 ? ", après \(conts) suite(s) automatique(s)" : ""
                    let why: String = stopNote == "max_tokens" ? "réponse TRONQUÉE : plafond de sortie atteint (\(maxTokens) jetons\(contNote)) — demande « continue » pour la suite" : "réponse TRONQUÉE : flux coupé en cours de réponse — demande « continue » pour la suite"
                    onEvent(.step(kind: "step", info: ["id": String(UUID().uuidString.prefix(8)).lowercased(), "index": 0, "tool": "cerveau", "arg": why, "state": "err", "truncated": stopNote, "ts": nowISO()]))
                    _ = BlackBox.record(["tool": "ask_truncated", "actor": "Nova", "why": why, "ok": false, "effect": "lecture", "result": "brain=\(s.id) out=\(outTok)"])
                }
                // AUDIT-BRAIN-A : contenu structuré de l'appel abouti (mode natif) — texte agrégé (suites comprises) + tool_use complets
                if let tc = toolCtx, toolsForBrain != nil {
                    var blocks: [[String: Any]] = []
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let tb: [String: Any] = ["type": "text", "text": text]
                        blocks.append(tb)
                    }
                    blocks += toolBlocks
                    tc.blocks = blocks
                    tc.stopReason = stopNote.isEmpty ? lastStopReason : stopNote
                }
                if inTok + outTok > 0 { onEvent(.usage(input: inTok, output: outTok)) }
                onEvent(.done(id: s.id, label: s.label))
                return s.id
            } catch let f as BrainFailure {
                if let rid = v2Res { RoutingV2.failed(rid, kind: f.kind, produced: produced) }   // PHASE2-V2 : libérée seulement si refus avant traitement
                LLMSpend.abandon(v1Ticket, kind: f.kind, produced: produced)   // WP2 : annulé / délai / coupé → réservation gardée
                if f.kind == .canceled { onEvent(.error("annulé")); return nil }
                let failMs = Int(Date().timeIntervalSince(t0) * 1000)   // CREDITS-SENTRY (23/10) : durée mesurée de l'échec (avant ce lot, seuls les succès portaient « ms »)
                note(s.id, ok: false, ms: nil, err: f)
                if f.kind == .network || f.kind == .timeout { NetState.noteRouterFailure() }   // VAGUE 2 : la sonde réseau est avancée
                journal.add(["brain": s.id, "model": s.model, "ok": false, "kind": f.kind.rawValue, "err": Knowledge.redact(shortError(f.message, 160)), "ms": failMs])   // AUDIT-24/10: masqué
                // CREDITS-SENTRY (23/10, stagé) : timeouts et HTTP 504 amont = incidents à tracer
                // dans Sentry, DISTINCTS du bruit 5xx des playlists TV (NOVA2-1, handled/warning
                // côté SentryBootstrap.beforeSend). Un 504 fournisseur arrive en kind .server
                // (classify, HTTPStream.swift : 500...599 → .server) avec « HTTP 504 … » dans le
                // message ; un timeout arrive en kind .timeout. Les autres échecs (auth, crédit,
                // rate, autres 5xx) restent au seul journal cerveaux : pas d'inflation Sentry.
                // Émission asynchrone via le hook (nil = no-op si Sentry non initialisé).
                if f.kind == .timeout || (f.kind == .server && f.message.contains("HTTP 504")) {
                    emitRouterIncident(s, kind: f.kind.rawValue, ms: failMs, chain: chain)
                }
                if produced { onEvent(.error("Le cerveau « \(s.label) » s'est interrompu en cours de réponse.")); return s.id }
                lastFail = "\(s.label) : \(Knowledge.redact(f.message))"   // AUDIT-24/10: masqué (servi au web)
                if f.kind == .credit { let hh = URL(string: s.baseURL)?.host ?? s.baseURL; creditDeadHosts.insert(hh); creditLock.lock(); creditDeadUntil[hh] = Date().addingTimeInterval(1800); creditLock.unlock() }
                previous = s
            } catch { if let rid = v2Res { RoutingV2.failed(rid, kind: nil, produced: produced) }; LLMSpend.abandon(v1Ticket, kind: nil, produced: produced); lastFail = Knowledge.redact("\(error)"); previous = s }   // AUDIT-BRAIN-A : masqué
        }
        if attempts == 0, let why = v2Refused { onEvent(.error(why)); return nil }   // PHASE2-V2 : tout refusé par le budget
        if attempts == 0, let why = v1Refused { onEvent(.error(why)); return nil }   // WP2 : tout refusé par la réservation v1
        if attempts == 0 {
            onEvent(.error("Aucun cerveau n'a pu être essayé : crédits épuisés chez le fournisseur et les autres cerveaux en pause après des échecs récents. Réessaie dans quelques minutes."))
            return nil
        }
        onEvent(.error("Tous les cerveaux ont échoué. Dernier : \(lastFail)"))
        return nil
    }

    // MARK: Souverain d'abord
    /// Réglages : `sovereign` (interrupteur), `sovereignFirstMs` (délai maximal avant le premier mot), `sovereignTotalMs` (durée totale maximale).
    // PHASE 1 : sous cfgLock (étaient nonisolated(unsafe), réécrits par POST /api/settings pendant les chats).
    public var sovereign: Bool { get { withCfg { $0.sovereign } } set { withCfg { $0.sovereign = newValue } } }   // cloud d'abord (décision du Capitaine) ; le local reste le secours
    public var sovereignFirstMs: Int { get { withCfg { $0.sovereignFirstMs } } set { withCfg { $0.sovereignFirstMs = newValue } } }
    public var sovereignTotalMs: Int { get { withCfg { $0.sovereignTotalMs } } set { withCfg { $0.sovereignTotalMs = newValue } } }
    let svLock = NSLock()
    var svServed = 0, svEscalated = 0, svLastReason = ""
    var svLat: [Int] = []          // dernières latences locales réussies (ms, durée totale)
    var svFirst: [Int] = []        // dernières latences au premier mot
    var svProbeAt = Date.distantPast, svProbing = false

    /// Garde-fou de délai : au moins 3 mesures récentes, médiane du premier mot sous le seuil. Sans mesure, une sonde silencieuse est lancée et le cloud répond en attendant.
    func sovereignQualified() -> Bool {
        svLock.lock(); let f = svFirst, t = svLat; svLock.unlock()
        guard f.count >= 3 else { return false }
        let mf = f.sorted()[f.count / 2], mt = t.sorted()[t.count / 2]
        return mf <= sovereignFirstMs && mt <= sovereignTotalMs
    }
    func sovereignEligible(mode: String, preferred: String?, messages: [ChatMsg], system: String?) -> Bool {
        guard sovereign, mode != "deep", (preferred ?? "auto") == "auto" || preferred == "local", engines().first != nil else { return false }
        if preferred == "local" { return true }          // choix explicite : toujours local
        let size = messages.reduce((system ?? "").count) { $0 + $1.content.count }
        if size > 6000 { return false }                  // gros contexte : trop lent en local, on ne parie pas sur le délai
        if !sovereignQualified() { sovereignProbe(); return false }
        return true
    }
    /// Sonde en arrière-plan : 3 appels minimaux pour mesurer le délai réel du modèle local (au plus une fois toutes les 10 min).
    func sovereignProbe() {
        svLock.lock(); if svProbing || Date().timeIntervalSince(svProbeAt) < 600 { svLock.unlock(); return }; svProbing = true; svProbeAt = Date(); svLock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { svLock.lock(); svProbing = false; svLock.unlock() }
            guard let l = localSpec() else { return }
            for _ in 0..<3 {
                let t0 = Date(); var first = 0; var txt = ""
                do {
                    try runner.stream(l, messages: [ChatMsg("user", "Résume en une phrase : le soleil se lève à l'est.")], system: nil, maxTokens: 40, mode: "fast", firstTokenTimeout: 20, cancel: { false },
                                      onDelta: { if first == 0 { first = Int(Date().timeIntervalSince(t0) * 1000) }; txt += $0 }, onUsage: { _, _ in })
                    let tot = Int(Date().timeIntervalSince(t0) * 1000)
                    svLock.lock(); svFirst.append(first); svLat.append(tot); svFirst = Array(svFirst.suffix(8)); svLat = Array(svLat.suffix(8)); svLock.unlock()
                } catch { svLock.lock(); svLastReason = "sonde locale échouée"; svLock.unlock(); return }
            }
        }
    }
    /// Garde-fou de qualité : refuse le vide, les boucles, les caractères corrompus et les réponses tronquées sans fin de phrase sur une demande longue.
    static func qualityOK(_ text: String, asked: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "réponse vide" }
        if t.contains("\u{FFFD}") { return "caractères corrompus" }
        if asked.count > 60 && t.count < 4 { return "réponse trop courte" }
        let chars = Array(t); if chars.count > 120 {
            let tail = String(chars.suffix(30)); let body = String(chars.dropLast(30))
            if body.components(separatedBy: tail).count > 4 { return "boucle de répétition" }
        }
        let low = t.lowercased()
        for bad in ["as an ai language model", "en tant que modèle de langage", "i cannot assist", "je ne peux pas vous aider avec cela"] where low.hasPrefix(bad) { return "refus générique" }
        return nil
    }
    func trySovereign(_ l: BrainSpec, messages: [ChatMsg], system: String?, maxTokens: Int, mode: String, cancel: @escaping () -> Bool, onEvent: @escaping (BrainEvent) -> Void) -> String? {
        let t0 = Date(); var first = 0; var text = ""; var inTok = 0, outTok = 0; var reason = ""
        let asked = messages.last?.content ?? ""
        do {
            try runner.stream(l, messages: ChatMsg.refit(messages, tokenBudget: max(2000, ContextWindow.tokens(for: "local") - maxTokens - 1000 - TokenEst.of(system ?? ""))), system: system, maxTokens: maxTokens, mode: mode, firstTokenTimeout: TimeInterval(sovereignFirstMs) / 1000,
                              cancel: { cancel() || Date().timeIntervalSince(t0) * 1000 > Double(self.sovereignTotalMs) },
                              onDelta: { if first == 0 { first = Int(Date().timeIntervalSince(t0) * 1000); _ = BlackBox.record(["tool": "ask_ttft", "actor": "Nova", "why": "premier jeton de la réponse en flux (M2)", "ok": true, "effect": "lecture", "result": "brain=\(l.id) ttft_ms=\(first)"]) }; text += $0 }, onUsage: { inTok = $0; outTok = $1 })
        } catch let f as BrainFailure { if f.kind == .canceled && cancel() { return nil }; reason = "local : " + shortError(f.message, 80) } catch { reason = "local : \(error)" }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if reason.isEmpty, ms > sovereignTotalMs { reason = "délai dépassé (\(ms) ms)" }
        if reason.isEmpty, let q = Router.qualityOK(text, asked: asked) { reason = q }
        svLock.lock()
        if reason.isEmpty { svServed += 1; svFirst.append(first); svLat.append(ms); svFirst = Array(svFirst.suffix(8)); svLat = Array(svLat.suffix(8)) }
        else { svEscalated += 1; svLastReason = reason; svFirst.append(sovereignFirstMs * 2); svFirst = Array(svFirst.suffix(8)) }   // un échec pèse sur la médiane : le local est écarté tant qu'il ne se réhabilite pas
        svLock.unlock()
        journal.add(["brain": "local", "sovereign": true, "ok": reason.isEmpty, "ms": ms, "first_ms": first, "reason": reason])
        guard reason.isEmpty else { return nil }
        onEvent(.start(id: l.id, label: l.label)); onEvent(.delta(text))
        if inTok + outTok > 0 { onEvent(.usage(input: inTok, output: outTok)) }
        onEvent(.done(id: l.id, label: l.label)); return l.id
    }
    public func sovereignStatus() -> [String: Any] {
        svLock.lock(); defer { svLock.unlock() }
        let f = svFirst.sorted(), t = svLat.sorted()
        return ["enabled": sovereign, "local": engines().first?.name as Any? ?? NSNull(), "served_local": svServed, "escalated_cloud": svEscalated, "last_reason": svLastReason,
                "median_first_ms": f.isEmpty ? NSNull() : f[f.count / 2] as Any, "median_total_ms": t.isEmpty ? NSNull() : t[t.count / 2] as Any,
                "max_first_ms": sovereignFirstMs, "max_total_ms": sovereignTotalMs, "qualified": svFirst.count >= 3 && (f[f.count / 2] <= sovereignFirstMs) && (t.isEmpty ? false : t[t.count / 2] <= sovereignTotalMs)]
    }

    /// Réponse complète en texte (briefs, dots, etc.).
    public func complete(messages: [ChatMsg], system: String?, mode: String = "deep", preferred: String? = nil, maxTokens: Int = 1800, deadline: TimeInterval? = nil) -> (text: String, brain: String)? {
        return completeDetailed(messages: messages, system: system, mode: mode, preferred: preferred, maxTokens: maxTokens, deadline: deadline).result
    }

    /// APPLY-BRIEFS H4 : comme complete(), mais l'échec REMONTE avec son motif réel
    /// (dernier échec de la chaîne, délai dépassé, réponse vide) au lieu d'être jeté
    /// (`_ = err` avant ce correctif) — à l'appelant de le journaliser. C'est ce nil
    /// muet qui faisait écrire aux briefs un faux diagnostic d'indisponibilité
    /// pendant que les cerveaux répondaient (diagnostic du 21/10/2026).
    public func completeDetailed(messages: [ChatMsg], system: String?, mode: String = "deep", preferred: String? = nil, maxTokens: Int = 1800, deadline: TimeInterval? = nil, solo: Bool = false) -> (result: (text: String, brain: String)?, error: String?) {
        var text = ""; var err: String? = nil
        let id = chat(messages: messages, system: system, mode: mode, preferred: preferred, maxTokens: maxTokens, deadline: deadline, solo: solo) { ev in
            switch ev { case .delta(let d): text += d; case .draftReset: text = ""; case .error(let e): err = e; default: break }
        }
        // 29/10 (audit n°2) : une réponse COUPÉE en cours de flux n'est plus rendue comme un succès aux briefs, Dots et tris.
        if let id = id, !text.isEmpty, err == nil { return ((text, id), nil) }
        return (nil, err ?? (id != nil ? "réponse vide" : "aucun cerveau n'a répondu"))
    }

    /// Libellés d'erreur affichés dans le détail des cerveaux (Réglages) —
    /// miroir d'ERRKIND_LBL (web/js/core.js, lot U5/U6) : jamais le rawValue à l'écran.
    static let errKindLabels: [ErrKind: String] = [
        .auth: "authentification", .credit: "crédit épuisé", .rate: "limite de débit",
        .timeout: "délai dépassé", .network: "réseau", .server: "serveur",
        .model: "modèle", .cut: "flux coupé", .canceled: "annulé", .other: "autre erreur",
    ]

    /// Diagnostic réel : un vrai appel minimal par cerveau, en parallèle. Aucune simulation.
    public func diagnose(ids: [String]? = nil) -> [[String: Any]] {
        var targets = brains
        if let l = localSpec() { targets.append(l) }
        if let ids = ids { targets = targets.filter { ids.contains($0.id) } }
        var out: [[String: Any]] = []; let lock2 = NSLock(); let g = DispatchGroup()
        let diagLane: SpendLane = LLMSpend.currentLane(background: !LLMSpend.isInteractive())   // WP2 : voie de l'appelant (les fils du pool n'héritent pas de son contexte)
        for s in targets {
            g.enter()
            DispatchQueue.global().async {
                defer { g.leave() }
                var row: [String: Any] = ["id": s.id, "label": s.label, "model": s.model]
                if MetaOnly.enabled && !MetaOnly.isMeta(s) {
                    row["etat"] = "non testé (meta_only)"; row["detail"] = "cerveau non Meta : aucun appel en mode meta_only"
                } else if s.kind != .local, s.keys.resolve(self.runner.keys) == nil {
                    row["etat"] = "sans clé"; row["detail"] = "aucune clé dans le Trousseau (\(s.keys.refs.map { $0.service }.joined(separator: ", ")))"
                } else {
                    // WP2 : un diagnostic réel est un appel facturé — réservé avant envoi, rapproché de l'usage rapporté (avant : jamais compté).
                    switch LLMSpend.preflight(spec: s, estIn: 32, maxOut: 24, lane: diagLane) {
                    case .refused(let why):
                        row["etat"] = "non testé (budget)"; row["detail"] = shortError(why, 200)
                    case .go(let tk):
                        let t0 = Date(); var text = ""
                        var dIn: Int = 0, dOut: Int = 0
                        do {
                            try self.runner.stream(s, messages: [ChatMsg("user", "Réponds uniquement par le mot : ok")], system: nil, maxTokens: 24, mode: "fast",
                                                   firstTokenTimeout: 20, cancel: { false }, onDelta: { text += $0 }, onUsage: { dIn = $0; dOut = $1 })
                            let ms = Int(Date().timeIntervalSince(t0) * 1000)
                            LLMSpend.record(s.id, inTok: dIn, outTok: dOut, cacheRead: 0, cacheWrite: 0, background: diagLane == .background, spec: s, ticket: tk)
                            self.note(s.id, ok: true, ms: ms, err: nil)
                            row["etat"] = "prêt"; row["detail"] = "répond en \(ms) ms : « \(shortError(text.trimmingCharacters(in: .whitespacesAndNewlines), 40)) »"; row["latence_ms"] = ms
                        } catch let f as BrainFailure {
                            LLMSpend.abandon(tk, kind: f.kind, produced: !text.isEmpty)
                            self.note(s.id, ok: false, ms: nil, err: f)
                            row["etat"] = "en panne"; row["detail"] = "\(Router.errKindLabels[f.kind] ?? "autre erreur") : \(Knowledge.redact(shortError(f.message, 180)))"   // AUDIT-24/10: masqué
                        } catch { LLMSpend.abandon(tk, kind: nil, produced: !text.isEmpty); row["etat"] = "en panne"; row["detail"] = "\(error)" }
                    }
                }
                lock2.lock(); out.append(row); lock2.unlock()
            }
        }
        g.wait()
        return out.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
    }
}

/// PHASE 1 : réglages à chaud du routeur, protégés ensemble par Router.cfgLock.
struct RouterConfig {
    var localModelPref: String? = nil
    var disabled: Set<String> = []
    var firstTokenTimeout: TimeInterval = 9   // AUDIT-24/10 : plancher pour [tiers] relevé dans chat() (≥ 20 s, adaptatif, ≤ 40 s) ; NOVA2-FIX 20/10 : 6 → 9 s
    var bulkEconomy = true
    var demoBrainId: String? = nil
    var demoFallbackId: String? = nil
    var sovereign = false
    var sovereignFirstMs = 6000
    var sovereignTotalMs = 30000
}
