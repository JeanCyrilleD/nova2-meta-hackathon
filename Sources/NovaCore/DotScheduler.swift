import Foundation

// MARK: WP1 (31/10/2026) — ordonnancement des Éclats : une seule opération atomique de réservation
//
// Constat de l'audit (vérifié le 31/10) : tick() réservait l'id dans « running » puis appelait launch(), dont le garde
// anti-relance rejetait cet id « déjà en cours » — le créneau était noté « lancé » sans qu'aucun run parte. Correctif
// minimal du 31/10 (reserve: true) remplacé ici par un cycle de vie explicite :
// • UNE opération (claim, sous verrou) décide de la propriété d'un run : tick, lancement manuel, alerte et écran
//   (POST /api/dots/run) passent tous par elle — plus de contrôle dupliqué entre tick / launch / begin.
// • identité du CRÉNEAU (« 2026-10-31T07:30 ») ≠ identité du RUN (runID) ; le créneau n'est consommé qu'APRÈS
//   l'acceptation du lancement par l'exécuteur (un lancement refusé ou en échec le laisse ouvert au rattrapage).
// • états : accepté → démarré → terminé | échoué | annulé | livraison en attente de décision ; « interrompu » à la
//   reprise si Nova s'est arrêtée pendant un run (registre persisté dots_runs_etat.json).
// • chien de garde PAR runID : il DEMANDE l'arrêt (jeton du run + Dots.requestStop) ; il ne libère jamais en silence.
//   Sans effet après « dots_arret_grace_min », le run est déclaré ORPHELIN (tracé) : la file est rendue aux AUTRES
//   Éclats, mais le sien reste bloqué jusqu'à la fin réelle du thread, et sa fin tardive ne livre rien.
// • une fin tardive (runID périmé) ne peut effacer qu'elle-même — jamais un run plus récent.
// • un seul fuseau explicite (« dots_fuseau », sinon le fuseau du Mac) pour l'heure, le jour ET la clé du créneau
//   (avant : jour en UTC, minutes en heure locale) ; rattrapage au-delà de minuit (créneau de la veille).
// • horaires validés (heures 0–23, minutes 0–59, préfixe de jours connu) ; un horaire invalide est tracé, pas deviné.
// • horloge et exécuteur injectables (tests XCTest sans thread réel ni cerveau).

/// Issue d'une demande de lancement d'Éclat.
public enum LaunchResult: Equatable, Sendable {
    /// Lancement accepté par l'exécuteur ; `runID` identifie CE run (pas l'Éclat, pas le créneau).
    case started(runID: String)
    /// L'Éclat a déjà un run en vol (ou orphelin) : rien n'est lancé par-dessus lui.
    case alreadyRunning
    /// Une porte refuse (file occupée…) : rien n'est consommé.
    case blocked(reason: String)
    /// L'exécuteur a refusé le départ : la réservation est rendue, le créneau reste ouvert.
    case failedToStart(reason: String)

    public var runID: String? { if case .started(let r) = self { return r }; return nil }
    public var isStarted: Bool { return runID != nil }
    /// Libellé court (réponses d'API, journal).
    public var label: String {
        switch self {
        case .started: return "lancé"
        case .alreadyRunning: return "déjà en cours"
        case .blocked(let r): return "bloqué : " + r
        case .failedToStart(let r): return "échec du lancement : " + r
        }
    }
}

/// États d'un run d'Éclat (valeurs persistées).
public enum DotRunPhase: String, Sendable {
    case accepted = "accepte"
    case started = "demarre"
    case completed = "termine"
    case failed = "echoue"
    case cancelled = "annule"
    case awaitingDecision = "livraison_en_attente"
    case interrupted = "interrompu"
}

/// Origine d'un run (plafond du chien de garde, espacement, journal).
public enum DotRunOrigin: String, Sendable {
    case scheduled = "planifie"   // créneau horaire (tick)
    case manual = "manuel"        // bouton, outil de l'app, route
    case alert = "alerte"         // relevé sur alerte courrier (badge, mail urgent) — plafonné, ne réarme pas l'espacement
    case automatic = "auto"       // relance automatique hors créneau (DotCare, réveil…)
    case external = "ecran"       // run exécuté par l'appelant (flux SSE de l'écran Éclats)
}

/// Exécuteur injectable : départ du travail et exécution de l'Éclat. Par défaut : un thread détaché et Dots.run.
public struct DotExecutor {
    /// Fait partir `work` hors du fil appelant ; faux = départ refusé (aucun run ne part, la réservation est rendue).
    public var dispatch: (@escaping @Sendable () -> Void) -> Bool
    /// Exécute l'Éclat (bloquant). `cancel` est lu par l'agent entre deux étapes.
    public var run: (_ dot: String, _ task: String, _ ordered: Bool, _ cancel: @escaping () -> Bool) -> [String: Any]?
    /// Chemin spécial « Journal du soir » : ouvre la carte au Fil direct au lieu d'un run de cerveau.
    public var openJournal: (_ origine: String) -> Void
    public init(dispatch: @escaping (@escaping @Sendable () -> Void) -> Bool,
                run: @escaping (_ dot: String, _ task: String, _ ordered: Bool, _ cancel: @escaping () -> Bool) -> [String: Any]?,
                openJournal: @escaping (_ origine: String) -> Void) {
        self.dispatch = dispatch; self.run = run; self.openJournal = openJournal
    }
}

/// Un run réservé (en vol). Persisté dans le registre pour la reprise.
struct DotRunClaim {
    let runID: String
    let dot: String
    let slot: String            // clé du créneau planifié (vide hors planification)
    let origin: DotRunOrigin
    var phase: DotRunPhase
    let acceptedAt: Date
    var startedAt: Date? = nil
    var stopRequestedAt: Date? = nil
    var orphaned: Bool = false
    func dict(_ iso: (Date) -> String) -> [String: Any] {
        var o: [String: Any] = ["run_id": runID, "eclat": dot, "creneau": slot, "origine": origin.rawValue, "etat": phase.rawValue,
                                "accepte_a": iso(acceptedAt), "orphelin": orphaned]
        if let s = startedAt { o["demarre_a"] = iso(s) }
        if let s = stopRequestedAt { o["arret_demande_a"] = iso(s) }
        return o
    }
}

/// V10 — Planificateur de Dots : à l'heure prévue le Dot s'exécute, puis « apparaît » dans l'interface (événement SSE « dot »),
/// livre son résultat et ATTEND : ouvrir, attendre, ou reporter (plus tard). Un Dot n'envoie jamais rien tout seul.
public final class DotScheduler: @unchecked Sendable {
    let dots: Dots, settings: Settings, briefs: Briefs
    let publish: (String, Any) -> Void
    let state: JSONFile      // { dotId: { "last": ["YYYY-MM-DDTHH:MM"], "expired": [...] } } — clés dans le fuseau des créneaux
    let pending: JSONFile    // dots livrés, pas encore acquittés : [{run_id, dot, until?}]
    let ledger: JSONFile     // WP1 : registre des runs { "actifs": [claim], "recents": [claim terminé] } — reprise après arrêt
    /// WP1 : horloge, exécuteur, fuseau et liste des Éclats injectables (tests).
    let clock: () -> Date
    let executor: DotExecutor
    let tzProvider: () -> TimeZone
    let dotList: () -> [[String: Any]]

    private let lock = NSLock()
    /// WP1 : runs réservés, par runID — SEULE source de vérité de « qui tourne ». Un Éclat n'a jamais deux runs réservés.
    private var claims: [String: DotRunClaim] = [:]
    /// WP1 : arrêts demandés (par runID), lus par le `cancel` du run.
    private var cancelAsked: Set<String> = []
    /// WP1 : derniers runs terminés (persistés, 40 au plus).
    private var recents: [[String: Any]] = []
    /// Fin (ou début) du dernier passage : base de l'espacement minimal entre deux passages automatiques. Initialisé au démarrage : pas de rafale au lancement de Nova.
    private var lastAutoAt: Date
    /// tick() est sérialisé (anti-volume, état des créneaux) ; jamais pris sous `lock`.
    private let tickLock = NSLock()
    /// SPARK8-D : anti-volume des « différé » (clé "<id>|<clé>" → dernier motif journalisé). Sous tickLock.
    private var deferLogged: [String: String] = [:]
    /// WP1 : horaires invalides déjà signalés (id → horaire). Sous tickLock.
    private var invalidLogged: [String: String] = [:]
    /// 31/10 (diag Éclats) : dernier passage de l'expiration des délégations (au plus toutes les 15 min). Sous tickLock.
    private var delegCheckAt: Date = .distantPast

    /// Dots en cours d'exécution à l'instant (anneaux dorés de Singularity) — orphelins compris (leur thread vit encore).
    public func activeIds() -> [String] { lock.lock(); defer { lock.unlock() }; return Array(Set(claims.values.map { $0.dot })).sorted() }

    public init(dots: Dots, settings: Settings, briefs: Briefs, publish: @escaping (String, Any) -> Void,
                clock: @escaping () -> Date = { Date() }, executor: DotExecutor? = nil, timeZone: (() -> TimeZone)? = nil,
                dotList: (() -> [[String: Any]])? = nil, storePrefix: String = "") {
        self.dots = dots; self.settings = settings; self.briefs = briefs; self.publish = publish
        self.clock = clock
        self.state = JSONFile(storePrefix + "dots_etat.json")
        self.pending = JSONFile(storePrefix + "dots_attente.json")
        self.ledger = JSONFile(storePrefix + "dots_runs_etat.json")
        self.executor = executor ?? DotExecutor(
            dispatch: { work in Thread.detachNewThread(work); return true },
            run: { [dots] id, task, ordered, cancel in dots.run(id: id, task: task, ordered: ordered, cancel: cancel) { _ in } },
            openJournal: { origine in _ = JournalSoir.openCard(origine: origine) })
        self.tzProvider = timeZone ?? { [settings] in DotScheduler.configuredTimeZone(settings) }
        self.dotList = dotList ?? { [dots] in dots.list() }
        self.lastAutoAt = clock()
        migrate()
        tidyPending()   // FLOTTE V1 : la file ne garde que de vraies décisions, une par Éclat
        recoverInterrupted()
    }

    static let defaultSchedules: [String: String] = ["veille": "07:30", "agenda": "07:45", "courrier": "lun-ven 12:30", "bilan": "18:30"]
    static let bilan: [String: Any] = [
        "id": "bilan", "name": "Bilan du jour", "emoji": "🌙", "color": "#f59e0b", "role": "Fait le bilan de fin de journée : ce qui s'est passé, ce qui reste, ce qu'il faut préparer pour demain.",
        "tools": ["calendar", "reminders", "recall", "remember", "know", "today"], "brain": "auto", "schedule": "18:30",
        "prompt": "Fais le bilan de la journée de l'utilisateur en 3 blocs courts : 1) CE QUI S'EST PASSÉ (appuie-toi UNIQUEMENT sur les résultats des Dots du jour fournis dans la tâche et sur la mémoire), 2) CE QUI RESTE (rappels, agenda de demain via les outils), 3) À PRÉPARER POUR DEMAIN (3 points max). Ne dis rien que tu ne puisses pas appuyer sur ces données. Termine par une phrase chaleureuse."]

    /// Ajoute le Dot « bilan » et des horaires par défaut (une seule fois ; l'utilisateur peut tout modifier ensuite).
    private func migrate() {
        if !settings.get("dots_migrated_v21b", false) {   // v21 : TOUS les Dots deviennent actifs (horaires par défaut), sans écraser un horaire choisi
            var l = dots.list(); let defs = Dictionary(Dots.defaults.compactMap { d in (d["id"] as? String).map { ($0, d["schedule"] as? String ?? "") } }, uniquingKeysWith: { first, _ in first })
            for i in l.indices { if let id = l[i]["id"] as? String, (l[i]["schedule"] as? String ?? "").isEmpty, let s = defs[id], !s.isEmpty { l[i]["schedule"] = s } }
            for i in l.indices { l[i].removeValue(forKey: "persona") }
            for nd in Dots.defaults where !l.contains(where: { ($0["id"] as? String) == (nd["id"] as? String) }) { l.append(nd) }
            dots.store.write(l); settings.set(["dots_migrated_v21b": true])
        }
        if !settings.get("dots_migrated_v47", false) {   // v47 : ajoute le Dot BRVM, sans toucher aux Dots existants
            var l = dots.list()
            for nd in Dots.defaults where !l.contains(where: { ($0["id"] as? String) == (nd["id"] as? String) }) { l.append(nd) }
            dots.store.write(l); settings.set(["dots_migrated_v47": true])
        }
        if !settings.get("dots_migrated_pro1", false) {   // PRO-3 (21/10) : aucun Dot mort en silence.
            var l = dots.list()
            let defs = Dictionary(Dots.defaults.compactMap { d in (d["id"] as? String).map { ($0, d["schedule"] as? String ?? "") } }, uniquingKeysWith: { first, _ in first })
            for i in l.indices {
                guard let id = l[i]["id"] as? String else { continue }
                let sch = (l[i]["schedule"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                if id == "croissance", sch == "22:30" { l[i]["schedule"] = "21:30" }   // créneau mort : heures calmes 22:00–07:00
                else if sch.isEmpty, let s = defs[id] ?? DotScheduler.defaultSchedules[id], !s.isEmpty { l[i]["schedule"] = s }
            }
            dots.store.write(l); settings.set(["dots_migrated_pro1": true])
        }
        guard !settings.get("dots_migrated_v10b", false) else { return }
        var l = dots.list()
        for i in l.indices { if let id = l[i]["id"] as? String, (l[i]["schedule"] as? String ?? "").isEmpty, let s = DotScheduler.defaultSchedules[id] { l[i]["schedule"] = s } }
        for d in Dots.defaults + [DotScheduler.bilan] { if !l.contains(where: { ($0["id"] as? String) == (d["id"] as? String) }) { l.append(d) } }
        dots.store.write(l)
        settings.set(["dots_migrated_v10b": true])
    }

    // MARK: horaires — fuseau unique, validation

    /// WP1 : fuseau des créneaux — réglage « dots_fuseau » (identifiant IANA, ex. « Africa/Ouagadougou »), sinon celui du Mac.
    static func configuredTimeZone(_ settings: Settings) -> TimeZone {
        let id: String = settings.get("dots_fuseau", "").trimmingCharacters(in: .whitespaces)
        if !id.isEmpty, let tz = TimeZone(identifier: id) { return tz }
        return TimeZone.autoupdatingCurrent
    }
    static func calendar(_ tz: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c
    }
    /// Calendrier des créneaux de CE planificateur (fuseau injecté ou configuré).
    func scheduleCalendar() -> Calendar { return DotScheduler.calendar(tzProvider()) }
    /// Jour « YYYY-MM-DD » dans le fuseau du calendrier (avant : jour UTC alors que l'heure était locale).
    static func dayKey(_ date: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static let dayNames: [String] = ["lun", "mar", "mer", "jeu", "ven", "sam", "dim"]
    /// WP1 : analyse d'un horaire « 07:30 » / « 07:30,12:00 » avec préfixe facultatif « lun-ven », « sam », « we ».
    /// `days` nil = tous les jours (0 = lundi). Les jetons invalides sont rendus dans `errors` (jamais devinés).
    static func parseSchedule(_ schedule: String) -> (days: Set<Int>?, times: [String], errors: [String]) {
        var s = schedule.lowercased().trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return (nil, [], []) }
        var days: Set<Int>? = nil
        var errors: [String] = []
        if let r = s.range(of: #"^([a-zé]{2,3}(-[a-zé]{2,3})?)\s+"#, options: .regularExpression) {
            let d = String(s[r]).trimmingCharacters(in: .whitespaces); s = String(s[r.upperBound...])
            let p = d.split(separator: "-").map(String.init)
            if d == "we" { days = [5, 6] }
            else if p.count == 2, let a = dayNames.firstIndex(of: p[0]), let b = dayNames.firstIndex(of: p[1]) {
                var set: Set<Int> = []
                var i = a
                while true { set.insert(i); if i == b { break }; i = (i + 1) % 7 }
                days = set
            } else if p.count == 1, let a = dayNames.firstIndex(of: p[0]) { days = [a] }
            else { errors.append("jours inconnus « " + d + " »"); return (nil, [], errors) }
        }
        var times: [String] = []
        for raw in s.split(separator: ",") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            let p = t.split(separator: ":")
            if t.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil, p.count == 2,
               let h = Int(p[0]), let m = Int(p[1]), (0...23).contains(h), (0...59).contains(m) { times.append(t) }
            else { errors.append("heure invalide « " + t + " »") }
        }
        return (days, times, errors)
    }
    /// Erreurs d'un horaire (vide = valide) — pour l'interface et l'assistant.
    public static func scheduleErrors(_ schedule: String) -> [String] { return parseSchedule(schedule).errors }

    /// "07:30" ou "07:30,12:00" ; préfixe facultatif "lun-ven " / "we ". Créneaux VALIDES du jour de `now` (fuseau du calendrier).
    static func slots(_ schedule: String, now: Date, calendar: Calendar? = nil) -> [String] {
        let cal: Calendar = calendar ?? DotScheduler.calendar(DotScheduler.configuredTimeZone(Settings()))
        let parsed = parseSchedule(schedule)
        if let days = parsed.days {
            let wd = (cal.component(.weekday, from: now) + 5) % 7   // 0 = lundi
            if !days.contains(wd) { return [] }
        }
        return parsed.times
    }

    /// WP1 : créneau candidat (clé, échéance réelle, retard en minutes).
    struct SlotCandidate { let key: String; let slot: String; let day: String; let due: Date; let retard: Int; let today: Bool }
    /// Créneaux non tenus et non abandonnés d'un Éclat, d'hier et d'aujourd'hui (rattrapage au-delà de minuit),
    /// du plus ancien au plus récent. Ceux d'hier ne sont rendus que s'ils sont encore dans la fenêtre.
    func candidates(id: String, schedule: String, now: Date, cal: Calendar, window: Int, st: [String: Any]) -> [SlotCandidate] {
        let last: [String] = ((st[id] as? [String: Any])?["last"] as? [String]) ?? []
        let expired: [String] = ((st[id] as? [String: Any])?["expired"] as? [String]) ?? []
        var out: [SlotCandidate] = []
        for offset in [-1, 0] {
            guard let date = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            let day: String = DotScheduler.dayKey(date, cal)
            for slot in DotScheduler.slots(schedule, now: date, calendar: cal) {
                let p = slot.split(separator: ":"); guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { continue }
                guard let due = cal.date(bySettingHour: h, minute: m, second: 0, of: date) else { continue }
                let key: String = day + "T" + slot
                if last.contains(key) || expired.contains(key) { continue }
                let secs: Double = now.timeIntervalSince(due)
                if secs < 0 { continue }
                let retard: Int = Int(secs / 60)
                if offset < 0 && retard > window { continue }   // la veille, hors fenêtre : oublié comme avant (pas de rafale d'abandons à minuit)
                out.append(SlotCandidate(key: key, slot: slot, day: day, due: due, retard: retard, today: offset == 0))
            }
        }
        return out.sorted { $0.due < $1.due }
    }

    /// WP1 : un horaire invalide est tracé une fois (par horaire), jamais deviné. Sous tickLock.
    private func reportInvalid(_ id: String, _ schedule: String) {
        let errs = DotScheduler.parseSchedule(schedule).errors
        if errs.isEmpty { invalidLogged.removeValue(forKey: id); return }
        if invalidLogged[id] == schedule { return }
        invalidLogged[id] = schedule
        let motif: String = "horaire invalide ignoré (" + errs.joined(separator: " ; ") + ") — corrige l'horaire de l'Éclat"
        _ = BlackBox.record(["tool": "dots_scheduler", "actor": "Nova", "ok": false, "effect": "lecture", "why": "Dot \(id) : " + motif])
        DotScheduler.mirror(["eclat": id, "creneau": "", "decision": "horaire invalide", "motif": motif, "retard_min": 0])
    }

    // MARK: portes et tick

    /// À appeler toutes les ~20 s. Rattrape un créneau manqué (Mac en veille) jusqu'à 3 h après l'heure.
    /// Garde-fou de charge : renseigné par App (pas de Dots planifiés pendant que l'utilisateur discute, ni quand seul le moteur local est disponible).
    nonisolated(unsafe) public static var shouldPause: () -> Bool = { false }
    /// SPARK8-D : motif lisible de la pause (nil = pas de pause), renseigné par App à côté de shouldPause.
    nonisolated(unsafe) public static var pauseMotif: (() -> String?)? = nil

    public func isRunning(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return claims.values.contains { $0.dot == id } }
    /// Un Éclat est-il en train de travailler ? (garde anti-coupe du matérialiseur Direct)
    public func anyRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return !claims.isEmpty }
    /// WP1 : état d'un run (nil = inconnu ou terminé et sorti des récents).
    public func runPhase(_ runID: String) -> DotRunPhase? {
        lock.lock(); defer { lock.unlock() }
        if let c = claims[runID] { return c.phase }
        if let r = recents.last(where: { ($0["run_id"] as? String) == runID }), let e = r["etat"] as? String { return DotRunPhase(rawValue: e) }
        return nil
    }
    /// WP1 : runID réservé d'un Éclat (nil = rien).
    public func activeRunID(_ dot: String) -> String? { lock.lock(); defer { lock.unlock() }; return claims.values.first { $0.dot == dot }?.runID }
    func isOrphaned(_ runID: String) -> Bool { lock.lock(); defer { lock.unlock() }; return claims[runID]?.orphaned ?? false }

    public func tick(now nowIn: Date? = nil) {
        let now: Date = nowIn ?? clock()
        tickLock.lock(); defer { tickLock.unlock() }
        // inQuietHours couvre aussi le mode concentration (« focus_until »)
        if !settings.get("dots_auto", true) { logDeferredByGate(now: now, motif: "Dots automatiques désactivés (dots_auto)"); releaseSnoozed(now); return }
        if briefs.inQuietHours(now) { logDeferredByGate(now: now, motif: "heures calmes"); releaseSnoozed(now); return }
        if now.timeIntervalSince(delegCheckAt) > 900 { delegCheckAt = now; InnovDeleg.expireDue() }   // 31/10 : une délégation échue est close (avant : seulement à l'ouverture de l'écran Délégations)
        if DotScheduler.shouldPause() { logDeferredByGate(now: now, motif: DotScheduler.pauseMotif?() ?? "pause"); releaseSnoozed(now); return }
        // 31/10 (diag Éclats) : un Éclat en retard de plus de « dots_retard_prioritaire_min » (60 min) passe au prochain
        // créneau libre — l'espacement ne le retient plus (la file, le CPU et le gouverneur critique, si).
        let lateMin: Int = settings.get("dots_retard_prioritaire_min", 60)
        let prioritaire: Bool = oldestOverdueMin(now) >= lateMin
        if let gateMotif = autoBlocker(now, prioritaire: prioritaire) { logDeferredByGate(now: now, motif: gateMotif); releaseSnoozed(now); return }   // sobriété : un seul Dot, espacement, CPU, conversation
        let window: Int = rattrapageMin()
        let cal: Calendar = scheduleCalendar()
        var st = state.read(default: [String: Any]())
        scan: for d in dotList() {
            guard let id = d["id"] as? String else { continue }
            if DotScheduler.isUnscheduled(d) { continue }   // FLOTTE V1 : retiré ou « à la demande » — jamais planifié, rien à journaliser
            let schedule: String = d["schedule"] as? String ?? ""
            reportInvalid(id, schedule)
            if (d["paused"] as? Bool) == true {   // Dot mis en pause par l'utilisateur, l'assistant ou l'anti-boucle
                if !resumeIfExpired(d, now) {
                    // SPARK8-D : créneaux dus d'un Dot en pause, journalisés sans écrire d'état.
                    for c in candidates(id: id, schedule: schedule, now: now, cal: cal, window: window, st: st) {
                        logDecision(id: id, key: c.key, decision: "différé", motif: DotScheduler.pauseLabel(d), retard: c.retard)
                    }
                    continue
                }
            }
            for c in candidates(id: id, schedule: schedule, now: now, cal: cal, window: window, st: st) {
                if c.retard > window {
                    // SPARK8-D : fenêtre de rattrapage dépassée, le créneau est abandonné et tracé.
                    abandon(id: id, key: c.key, retard: c.retard, window: window, st: &st)
                    continue
                }
                if id == JournalSoir.dotId {
                    // LOT3 (25/10) : « Journal du soir » — le créneau ouvre la carte « 2 minutes pour ta journée ? »
                    // au Fil direct (Feat_JournalSoir.swift) au lieu d'un run de cerveau à vide. Même file que les runs :
                    // il attend qu'aucun Éclat planifié ne tourne, et réarme l'espacement.
                    let busy: [String] = busyQueue()
                    if !busy.isEmpty {
                        logDecision(id: id, key: c.key, decision: "différé", motif: "file occupée par " + busy.joined(separator: ", "), retard: c.retard)
                        break scan
                    }
                    markConsumed(id: id, key: c.key, st: &st)
                    logDecision(id: id, key: c.key, decision: "lancé", motif: "créneau dû : carte du Journal du soir", retard: c.retard)
                    lock.lock(); lastAutoAt = now; lock.unlock()
                    executor.openJournal("rituel")
                    break scan
                }
                // WP1 : UNE opération réserve, lance et ne consomme le créneau qu'une fois le départ accepté.
                let r: LaunchResult = launchInternal(d, task: id == "bilan" ? bilanTask(now) : "", manual: false, alerte: false, slot: c.key, then: nil)
                switch r {
                case .started(let rid):
                    st = state.read(default: [String: Any]())   // relu : un run synchrone (tests) a pu écrire entre-temps
                    markConsumed(id: id, key: c.key, st: &st)
                    let motifLance: String = (prioritaire && c.retard >= lateMin) ? "créneau dû, en retard : prioritaire (espacement levé)" : "créneau dû, portes ouvertes"
                    logDecision(id: id, key: c.key, decision: "lancé", motif: motifLance + " — run " + rid, retard: c.retard)
                case .alreadyRunning:
                    logDecision(id: id, key: c.key, decision: "différé", motif: "l'Éclat tourne déjà (lancement manuel, alerte ou écran) — créneau gardé ouvert", retard: c.retard)
                case .blocked(let why):
                    logDecision(id: id, key: c.key, decision: "différé", motif: why, retard: c.retard)
                case .failedToStart(let why):
                    logDecision(id: id, key: c.key, decision: "différé", motif: "échec du lancement (" + why + ") — créneau gardé ouvert au rattrapage", retard: c.retard)
                }
                break scan   // file sérialisée : un seul Dot planifié par passage
            }
        }
        releaseSnoozed(now)
    }

    /// Créneau tenu (n'est appelé qu'APRÈS l'acceptation du départ).
    private func markConsumed(id: String, key: String, st: inout [String: Any]) {
        let last: [String] = ((st[id] as? [String: Any])?["last"] as? [String]) ?? []
        let expired: [String] = ((st[id] as? [String: Any])?["expired"] as? [String]) ?? []
        st[id] = ["last": Array((last + [key]).suffix(32)), "expired": expired]
        state.write(st)
    }

    /// SPARK8-D : journalise une décision de l'ordonnanceur (lancé / différé / abandon) avec son motif. Sous tickLock.
    func logDecision(id: String, key: String, decision: String, motif: String, retard: Int) {
        let k = "\(id)|\(key)"
        if decision == "différé" {
            if deferLogged[k] == motif { return }   // anti-volume : un tick toutes les 20 s
            deferLogged[k] = motif
        } else {
            deferLogged.removeValue(forKey: k)   // lancé / abandon : purge, toujours journalisé
        }
        _ = BlackBox.record(["tool": "dots_scheduler", "actor": "Nova",
                             "why": "créneau \(key) · Dot \(id): \(decision) — \(motif)",
                             "ok": decision == "lancé", "effect": "lecture",
                             "result": "retard \(retard) min"])
        var ev: [String: Any] = ["eclat": id, "creneau": key, "decision": decision, "motif": motif, "retard_min": retard]
        DotScheduler.addGovernor(&ev)
        DotScheduler.mirror(ev)
    }

    /// 31/10 (diag Éclats) : quand le gouverneur freine, la ligne du miroir porte ses mesures — pression mémoire du Mac
    /// ENTIER (noyau) et empreinte réelle de Nova (phys_footprint, Mo) — pour dire si la pression vient de Nova.
    static func addGovernor(_ ev: inout [String: Any]) {
        let snap: [String: Any] = PerfGovernor.shared.snapshot()
        let niv: String = (snap["niveau"] as? String) ?? PerfGovernor.normal
        if niv == PerfGovernor.normal { return }
        ev["gouverneur"] = niv
        if let m = snap["mesures"] as? [String: Any] {
            for k in ["pression_memoire", "nova_memoire_mo", "mac_ram_mo", "thermique", "cpu_pct"] { if let v = m[k] { ev[k] = v } }
        }
    }

    /// 31/10 (diag Éclats) : fenêtre de rattrapage d'un créneau manqué (« dots_rattrapage_min », 180 min par défaut, 30…720).
    func rattrapageMin() -> Int { return max(30, min(720, settings.get("dots_rattrapage_min", 180))) }

    /// 31/10 (diag Éclats) : abandon tracé d'un créneau trop en retard — avec le DERNIER motif de report (plus de report infini).
    func abandon(id: String, key: String, retard: Int, window: Int, st: inout [String: Any]) {
        let k: String = "\(id)|\(key)"
        let lastWhy: String = deferLogged[k] ?? ""
        var motif: String = "abandonné : en retard de \(retard) min > fenêtre de rattrapage de \(window) min"
        if !lastWhy.isEmpty { motif += " — dernier blocage : " + lastWhy }
        logDecision(id: id, key: key, decision: "abandon", motif: motif, retard: retard)
        let last: [String] = ((st[id] as? [String: Any])?["last"] as? [String]) ?? []
        let expired: [String] = ((st[id] as? [String: Any])?["expired"] as? [String]) ?? []
        st[id] = ["last": last, "expired": Array((expired + [key]).suffix(32))]
        state.write(st)
    }

    /// 31/10 (diag Éclats) : retard (min) du plus vieux créneau dû, non tenu, d'un Éclat actif (0 = aucun).
    func oldestOverdueMin(_ now: Date) -> Int {
        let cal: Calendar = scheduleCalendar()
        let window: Int = rattrapageMin()
        let st: [String: Any] = state.read(default: [String: Any]())
        var worst: Int = 0
        for d in dotList() {
            guard let id = d["id"] as? String else { continue }
            if DotScheduler.isUnscheduled(d) || (d["paused"] as? Bool) == true { continue }
            for c in candidates(id: id, schedule: d["schedule"] as? String ?? "", now: now, cal: cal, window: window, st: st) where c.retard <= window {
                worst = max(worst, c.retard)
            }
        }
        return worst
    }

    /// 31/10 (diag Éclats) : « Dot en pause » dit QUI l'a mis en pause et pourquoi (champs posés par les différents chemins).
    static func pauseLabel(_ d: [String: Any]) -> String {
        var who: String = "origine non tracée (bouton Pause / outil de l'assistant / ancienne fusion)"
        if (d["pause_auto"] as? Bool) == true { who = "anti-boucle (pause auto 24 h)" }
        else if let b = d["paused_by"] as? String, !b.isEmpty { who = "interrupteur « " + b + " »" }
        else if let mi = d["merged_into"] as? String, !mi.isEmpty { who = "fusion des Éclats (→ " + mi + ")" }
        else if (d["delegation"] as? Bool) == true { who = "délégation arrêtée ou échue (écran Délégations)" }
        let why: String = String(((d["pause_motif"] as? String) ?? "").prefix(160))
        return "Dot en pause — " + who + (why.isEmpty ? "" : " : " + why)
    }

    /// 31/10 (audit : la plupart des Éclats planifiés ne tournaient plus, sans trace lisible hors BlackBox) — miroir des
    /// décisions dans <relevés de diagnostic>/eclats_ordonnanceur.jsonl (≤ 1 Mo, la moitié la plus ancienne est retirée au-delà).
    /// WP1 : chemin centralisé (Paths.diagFile) — un test (NOVA_HOME) n'écrit jamais dans les relevés de l'app en service.
    static let mirrorLock: NSLock = NSLock()
    static func mirror(_ ev: [String: Any]) {
        let url: URL = Paths.diagFile("eclats_ordonnanceur.jsonl")
        let path: String = url.path
        var e: [String: Any] = ev; e["ts"] = nowISO()
        let line: Data = jsonData(e) + Data("\n".utf8)
        mirrorLock.lock(); defer { mirrorLock.unlock() }
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 1_000_000,
           let d = try? Data(contentsOf: url) {
            let keep: Data = d.suffix(d.count / 2)
            let cut: Data = keep.firstIndex(of: 10).map { keep.suffix(from: $0 + 1) } ?? keep
            try? cut.write(to: url)
        }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }

    /// SPARK8-D : journalise en lecture seule les créneaux dus bloqués par une porte globale (rien lancé ; seul un abandon écrit l'état).
    func logDeferredByGate(now: Date, motif: String) {
        let cal: Calendar = scheduleCalendar()
        var st = state.read(default: [String: Any]())
        let window: Int = rattrapageMin()
        for d in dotList() {
            guard let id = d["id"] as? String else { continue }
            if DotScheduler.isUnscheduled(d) { continue }
            let paused: Bool = (d["paused"] as? Bool) == true
            for c in candidates(id: id, schedule: d["schedule"] as? String ?? "", now: now, cal: cal, window: window, st: st) {
                // 31/10 (diag Éclats) : un Dot EN PAUSE n'est pas « différé par la porte » (avant : 92 lignes fantômes pour
                // une délégation en pause depuis la veille) ; un créneau hors fenêtre est abandonné ici aussi (avant :
                // seulement quand toutes les portes étaient ouvertes — report sans fin).
                if paused { logDecision(id: id, key: c.key, decision: "différé", motif: DotScheduler.pauseLabel(d), retard: c.retard); continue }
                if c.retard > window { abandon(id: id, key: c.key, retard: c.retard, window: window, st: &st); continue }
                logDecision(id: id, key: c.key, decision: "différé", motif: motif, retard: c.retard)
            }
        }
    }

    /// Éclats qui tiennent la file automatique (orphelins exclus : leur file a été rendue, eux restent bloqués).
    private func busyQueue() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(Set(claims.values.filter { !$0.orphaned }.map { $0.dot })).sorted()
    }

    /// SPARK8-D : motif de blocage sobriété (nil = passage autorisé). Mêmes tests, même ordre que readyForAuto.
    func autoBlocker(_ now: Date, prioritaire: Bool = false) -> String? {
        watchdog(now)
        let ids: [String] = busyQueue()
        lock.lock(); let last: Date = lastAutoAt; lock.unlock()
        if !ids.isEmpty { return "file occupée par " + ids.joined(separator: ", ") }
        let gapBase: Int = settings.get("dots_espacement_s", 600)
        // VAGUE 2 FIABILITÉ : gouverneur de performance réel (Feat_Maintenance) — Mac chaud, mémoire sous pression ou
        // batterie faible : les passages planifiés (non urgents) sont espacés ; état critique : différés (créneau ouvert 3 h).
        // 31/10 (diag Éclats) : gradué et plafonné — avertissement ×« dots_gouv_facteur_avert » (1,5), critique
        // ×« dots_gouv_facteur_critique » (3), jamais au-delà de « dots_espacement_max_s » (2700 s = 45 min). Le critique ne
        // diffère plus en bloc que s'il vient d'autre chose que la mémoire (chaleur, batterie très faible).
        let gov: PerfGovernor = PerfGovernor.shared
        let lvl: String = gov.level()
        if lvl == PerfGovernor.critique && gov.critiqueHorsMemoire() { return "gouverneur de performance : " + gov.motif() }
        let fAvert: Double = max(1, min(6, settings.get("dots_gouv_facteur_avert", 1.5)))
        let fCrit: Double = max(1, min(6, settings.get("dots_gouv_facteur_critique", 3.0)))
        let factor: Double = lvl == PerfGovernor.critique ? fCrit : (lvl == PerfGovernor.tendu ? fAvert : 1)
        let capS: Int = max(gapBase, settings.get("dots_espacement_max_s", 2700))
        let gap: Int = min(capS, Int(Double(gapBase) * factor))
        if !prioritaire, now.timeIntervalSince(last) < Double(gap) {
            let df = DateFormatter(); df.dateFormat = "HH:mm:ss"; df.timeZone = tzProvider()
            let fTxt: String = String(format: "%.1f", factor).replacingOccurrences(of: ".", with: ",")
            let why: String = gap > gapBase ? " (espacement élargi ×" + fTxt + " par le gouverneur : " + gov.motif() + ")" : ""
            return "espacement jusqu'à " + df.string(from: last.addingTimeInterval(Double(gap))) + why
        }
        let sinceChat = Int(now.timeIntervalSince(NovaApp.lastChatAt))
        if now.timeIntervalSince(NovaApp.lastChatAt) < 90 { return "chat récent (il y a \(sinceChat) s < 90 s)" }
        let cpuMax: Int = settings.get("dots_cpu_max", 60)
        let cpu: Double = SystemInfo.cpuLoadPercent()   // -1 si inconnue : on ne bloque pas
        if cpu > Double(cpuMax) { return String(format: "CPU %.1f %% > %d %%", cpu, cpuMax) }
        return nil
    }

    /// Conditions d'un passage automatique : aucun Dot en cours, espacement « dots_espacement_s » (600 s) écoulé,
    /// pas de conversation depuis 90 s, CPU système ≤ « dots_cpu_max » (60 %).
    func readyForAuto(_ now: Date) -> Bool {
        return autoBlocker(now) == nil
    }

    /// Fin d'une pause automatique (anti-boucle) arrivée à échéance : le Dot redevient actif. Une pause posée par l'utilisateur n'est jamais levée ici.
    func resumeIfExpired(_ d: [String: Any], _ now: Date) -> Bool {
        guard (d["pause_auto"] as? Bool) == true, let until = d["paused_until"] as? Double else { return false }
        if until > now.timeIntervalSince1970 { return false }
        var n: [String: Any] = d
        n.removeValue(forKey: "persona")
        n["paused"] = false
        n["pause_auto"] = false
        n.removeValue(forKey: "paused_until")
        n["pause_motif"] = ""
        n["resumed_at"] = nowISO()
        dots.save(n)
        return true
    }

    // MARK: WP1 — réservation, cycle de vie, chien de garde, reprise

    private func iso(_ d: Date) -> String { return ISO8601DateFormatter().string(from: d) }
    private func newRunID() -> String { return "r-" + String(UUID().uuidString.prefix(8)).lowercased() }

    /// LA réservation : sous un seul verrou, refuse si l'Éclat a déjà un run (même orphelin) ou, pour un créneau planifié,
    /// si la file automatique est tenue ; sinon inscrit un run « accepté » et le persiste.
    private func claim(dot: String, origin: DotRunOrigin, slot: String, exclusiveQueue: Bool, now: Date) -> LaunchResult {
        lock.lock(); defer { lock.unlock() }
        if claims.values.contains(where: { $0.dot == dot }) { return .alreadyRunning }
        if exclusiveQueue {
            let busy: [String] = Array(Set(claims.values.filter { !$0.orphaned }.map { $0.dot })).sorted()
            if !busy.isEmpty { return .blocked(reason: "file occupée par " + busy.joined(separator: ", ")) }
        }
        let rid: String = newRunID()
        claims[rid] = DotRunClaim(runID: rid, dot: dot, slot: slot, origin: origin, phase: .accepted, acceptedAt: now)
        persistLocked()
        return .started(runID: rid)
    }
    private func markStarted(_ rid: String) {
        lock.lock(); defer { lock.unlock() }
        guard claims[rid] != nil else { return }
        claims[rid]?.phase = .started; claims[rid]?.startedAt = clock()
        persistLocked()
    }
    /// Fin d'un run : ne retire QUE ce runID (une fin périmée ne touche jamais un run plus récent). Rend la réservation retirée.
    @discardableResult private func finish(_ rid: String, phase: DotRunPhase, motif: String = "") -> DotRunClaim? {
        lock.lock(); defer { lock.unlock() }
        guard var c = claims.removeValue(forKey: rid) else { return nil }
        cancelAsked.remove(rid)
        if c.origin != .alert && !c.orphaned && c.startedAt != nil { lastAutoAt = clock() }   // 31/10 : un relevé sur alerte ne repousse plus les Éclats planifiés ; WP1 : un départ refusé non plus
        c.phase = phase
        var rec: [String: Any] = c.dict(iso); rec["fin_a"] = iso(clock())
        if !motif.isEmpty { rec["motif"] = motif } else if c.orphaned { rec["motif"] = "fin tardive d'un run orphelin — rien livré" }
        recents.append(rec); if recents.count > 40 { recents.removeFirst(recents.count - 40) }
        persistLocked()
        return c
    }
    private func persistLocked() {
        let actifs: [[String: Any]] = claims.values.sorted { $0.acceptedAt < $1.acceptedAt }.map { $0.dict(iso) }
        ledger.write(["actifs": actifs, "recents": recents])
    }
    func isCancelRequested(_ rid: String) -> Bool { lock.lock(); defer { lock.unlock() }; return cancelAsked.contains(rid) }

    /// WP1 : reprise au démarrage — un run « actif » du registre appartenait à un Nova arrêté : il est classé « interrompu ».
    /// S'il n'avait jamais démarré, son créneau est rouvert (rattrapage dans la fenêtre) ; s'il avait démarré, il n'est pas rejoué.
    private func recoverInterrupted() {
        let o: [String: Any] = ledger.read(default: [String: Any]())
        let actifs: [[String: Any]] = (o["actifs"] as? [[String: Any]]) ?? []
        lock.lock(); recents = Array(((o["recents"] as? [[String: Any]]) ?? []).suffix(40)); lock.unlock()
        if actifs.isEmpty { return }
        var st = state.read(default: [String: Any]())
        var notes: [[String: Any]] = []
        for a in actifs {
            let dot: String = (a["eclat"] as? String) ?? ""
            let slot: String = (a["creneau"] as? String) ?? ""
            let before: String = (a["etat"] as? String) ?? ""
            var reopened: Bool = false
            if before == DotRunPhase.accepted.rawValue, !dot.isEmpty, !slot.isEmpty,
               var e = st[dot] as? [String: Any], var last = e["last"] as? [String], let i = last.firstIndex(of: slot) {
                last.remove(at: i); e["last"] = last; st[dot] = e; reopened = true
            }
            var x: [String: Any] = a
            x["etat_avant"] = before; x["etat"] = DotRunPhase.interrupted.rawValue; x["fin_a"] = iso(clock())
            x["motif"] = "Nova s'est arrêtée pendant le run" + (reopened ? " — créneau rouvert au rattrapage" : "")
            notes.append(x)
        }
        if notes.contains(where: { (($0["motif"] as? String) ?? "").contains("rouvert") }) { state.write(st) }
        lock.lock(); recents = Array((recents + notes).suffix(40)); persistLocked(); lock.unlock()
        for x in notes {
            DotScheduler.mirror(["eclat": x["eclat"] ?? "", "creneau": x["creneau"] ?? "", "decision": "interrompu",
                                 "motif": "run \((x["run_id"] as? String) ?? "?") (\((x["etat_avant"] as? String) ?? "?")) : " + ((x["motif"] as? String) ?? ""), "retard_min": 0])
        }
    }

    /// CHIEN DE GARDE PAR RUN (31/10 : « Sparring anglais » lancé à 07:45 tenait encore la file à 09:28). Un run occupé depuis
    /// plus de « dots_run_max_min » (20 min ; « dots_alerte_max_min », 6 min, pour un relevé sur alerte) reçoit une DEMANDE
    /// d'arrêt — il garde la file tant qu'il n'a pas rendu la main. Sans effet après « dots_arret_grace_min » (3 min), il est
    /// déclaré ORPHELIN, tracé : la file revient aux autres Éclats ; le sien reste bloqué jusqu'à la fin réelle du thread.
    func watchdog(_ now: Date) {
        let runMax: Int = max(1, settings.get("dots_run_max_min", 20))
        let alertMax: Int = max(2, min(runMax, settings.get("dots_alerte_max_min", 6)))
        let grace: Int = max(1, min(30, settings.get("dots_arret_grace_min", 3)))
        var asked: [(String, String, Int, Int)] = []
        var orphans: [(String, String, Int)] = []
        lock.lock()
        for (rid, c) in claims where !c.orphaned {
            if let sr = c.stopRequestedAt {
                let waited: Int = Int(now.timeIntervalSince(sr) / 60)
                if waited >= grace {
                    claims[rid]?.orphaned = true
                    if c.origin != .alert { lastAutoAt = now }
                    orphans.append((rid, c.dot, waited))
                }
                continue
            }
            let since: Date = c.startedAt ?? c.acceptedAt
            let mins: Int = Int(now.timeIntervalSince(since) / 60)
            let maxMin: Int = c.origin == .alert ? alertMax : runMax
            if mins >= maxMin {
                claims[rid]?.stopRequestedAt = now
                cancelAsked.insert(rid)
                asked.append((rid, c.dot, mins, maxMin))
            }
        }
        if !asked.isEmpty || !orphans.isEmpty { persistLocked() }
        lock.unlock()
        for (rid, id, mins, maxMin) in asked {
            _ = Dots.requestStop(run: "", dot: id)   // un seul run par Éclat : le jeton de Dots.run de CE run
            _ = BlackBox.record(["tool": "dots_scheduler", "actor": "Nova", "ok": false, "effect": "arrêt",
                                 "why": "chien de garde : run \(rid) de l'Éclat \(id) occupé depuis \(mins) min (max \(maxMin)) — arrêt demandé, la file reste tenue jusqu'à sa fin"])
            DotScheduler.mirror(["eclat": id, "creneau": "", "run_id": rid, "decision": "arrêt demandé", "motif": "chien de garde : occupé depuis \(mins) min (max \(maxMin))", "retard_min": 0])
        }
        for (rid, id, waited) in orphans {
            _ = BlackBox.record(["tool": "dots_scheduler", "actor": "Nova", "ok": false, "effect": "config",
                                 "why": "chien de garde : run \(rid) de l'Éclat \(id) sans réponse \(waited) min après la demande d'arrêt — déclaré orphelin : file rendue aux autres Éclats, \(id) reste bloqué jusqu'à la fin réelle du run, rien ne sera livré"])
            DotScheduler.mirror(["eclat": id, "creneau": "", "run_id": rid, "decision": "orphelin", "motif": "arrêt demandé sans effet depuis \(waited) min — file rendue aux autres Éclats", "retard_min": 0])
        }
    }

    /// Arrête réellement les runs en vol de cet Éclat (jeton du run réservé + Dots.requestStop). Retourne les runIds visés (vide = rien ne tournait).
    /// PHASE 1 : l'ancien registre `cancelled` est supprimé ; VAGUE 2 FIABILITÉ : jeton par run dans Dots.
    @discardableResult public func stop(_ id: String) -> [String] {
        let now: Date = clock()
        lock.lock()
        let mine: [String] = claims.values.filter { $0.dot == id }.map { $0.runID }.sorted()
        for r in mine { cancelAsked.insert(r); if claims[r]?.stopRequestedAt == nil { claims[r]?.stopRequestedAt = now } }
        if !mine.isEmpty { persistLocked() }
        lock.unlock()
        let t: [String] = Dots.requestStop(run: "", dot: id)
        return t.isEmpty ? mine : t
    }

    /// WP1 : un run exécuté par l'appelant (POST /api/dots/run, flux SSE de l'écran) réserve l'Éclat par la MÊME opération :
    /// halo « en cours », file automatique en attente, et pas de second run du même Éclat. `.started(runID)` = à terminer par finishExternal.
    public func claimExternal(_ id: String) -> LaunchResult {
        if id.isEmpty { return .failedToStart(reason: "Éclat sans identifiant") }
        let r: LaunchResult = claim(dot: id, origin: .external, slot: "", exclusiveQueue: false, now: clock())
        if let rid = r.runID { markStarted(rid) }
        return r
    }
    /// Fin d'un run externe (par SON runID : une fin en double ou périmée ne libère rien d'autre).
    public func finishExternal(_ runID: String, result r: [String: Any]?) {
        let text: String = (r?["result"] as? String) ?? ""
        let phase: DotRunPhase = DotScheduler.phase(of: r, text: text)
        finish(runID, phase: phase)
    }

    /// État final d'un run d'après son résultat.
    static func phase(of r: [String: Any]?, text: String) -> DotRunPhase {
        if (r?["arrete"] as? Bool) == true { return .cancelled }
        if text.isEmpty || DotCharter.status(of: text) == "ECHEC" { return .failed }
        if (r?["decision"] as? Bool) == true && !DotScheduler.isRAS(text) { return .awaitingDecision }
        return .completed
    }

    /// Lancement manuel (bouton « Faire apparaître ») ou automatique hors créneau.
    /// 31/10 (diag Éclats) : « alerte » = relevé déclenché par une alerte courrier (badge du Dock, mail urgent) — plafond
    /// « dots_alerte_max_min » et pas de réarmement de l'espacement des Éclats planifiés à la fin.
    /// 27/10 (Ahadi : « un Direct arrive pendant ma tâche, la coupe ») : un Éclat déjà en cours n'est JAMAIS relancé par-dessus
    /// lui-même (→ .alreadyRunning, `then("")`). WP1 : la décision est prise par la réservation unique (claim).
    @discardableResult
    public func launch(_ d: [String: Any], task: String, manual: Bool = false, alerte: Bool = false, then: ((String) -> Void)? = nil) -> LaunchResult {
        return launchInternal(d, task: task, manual: manual, alerte: alerte, slot: "", then: then)
    }

    private func launchInternal(_ d: [String: Any], task: String, manual: Bool, alerte: Bool, slot: String, then: ((String) -> Void)?) -> LaunchResult {
        let id = d["id"] as? String ?? ""
        if id.isEmpty { then?(""); return .failedToStart(reason: "Éclat sans identifiant") }
        let origin: DotRunOrigin = !slot.isEmpty ? .scheduled : (alerte ? .alert : (manual ? .manual : .automatic))
        let r: LaunchResult = claim(dot: id, origin: origin, slot: slot, exclusiveQueue: origin == .scheduled, now: clock())
        guard let rid = r.runID else {
            if r == .alreadyRunning, slot.isEmpty {
                _ = BlackBox.record(["tool": "dots_scheduler", "actor": "Nova", "why": "relance ignorée : l'Éclat " + id + " est déjà en cours — la tâche en vol finit d'abord", "ok": true, "effect": "aucun"])
            }
            then?("")
            return r
        }
        if !manual { Tools.frontAllowed = false }   // tâche non ordonnée : toujours en arrière-plan
        let accepted: Bool = executor.dispatch { [self] in self.execute(rid, d: d, id: id, task: task, manual: manual, origin: origin, then: then) }
        if !accepted {
            finish(rid, phase: .failed, motif: "départ refusé par l'exécuteur")
            _ = BlackBox.record(["tool": "dots_scheduler", "actor": "Nova", "ok": false, "effect": "aucun",
                                 "why": "lancement de l'Éclat \(id) refusé par l'exécuteur — réservation rendue" + (slot.isEmpty ? "" : ", créneau \(slot) gardé ouvert")])
            then?("")
            return .failedToStart(reason: "départ refusé par l'exécuteur")
        }
        return .started(runID: rid)
    }

    /// Corps d'un run accepté (thread de l'exécuteur).
    private func execute(_ rid: String, d: [String: Any], id: String, task: String, manual: Bool, origin: DotRunOrigin, then: ((String) -> Void)?) {
        markStarted(rid)
        publish("dot", ["phase": "working", "dot": id, "name": d["name"] ?? "", "emoji": d["emoji"] ?? "●", "color": d["color"] ?? "#D93226"])
        let t0: Date = clock()
        // VAGUE 2 FIABILITÉ : l'arrêt est porté par le jeton du run (Dots.requestStop) ; WP1 : et par celui de CE run (chien de garde, stop).
        // A1 : manual (bouton Lancer, relais d'alerte, outil app) = run ordonné ; planifié = fond.
        let r = executor.run(id, task, manual, { [weak self] in self?.isCancelRequested(rid) ?? true })
        let text = (r?["result"] as? String) ?? ""
        let phase: DotRunPhase = DotScheduler.phase(of: r, text: text)
        guard let claimDone = finish(rid, phase: phase) else {
            // Réservation déjà retirée (ne devrait pas arriver) : rien n'est livré, rien d'autre n'est touché.
            DotScheduler.mirror(["eclat": id, "creneau": "", "run_id": rid, "decision": "fin ignorée", "motif": "run inconnu du registre", "retard_min": 0])
            then?(""); return
        }
        let orphan: Bool = claimDone.orphaned   // lu dans la MÊME section critique que le retrait (pas de course avec le chien de garde)
        // 31/10 (diag Éclats) : fin de passage au miroir (origine, durée réelle, statut) — aucun contenu.
        let statutFin: String = (r?["arrete"] as? Bool) == true ? "arrêté" : (text.isEmpty ? "vide" : (DotCharter.status(of: text) ?? "?"))
        let origineTxt: String = origin == .alert ? "alerte courrier" : (origin == .scheduled ? "planifié" : (manual ? "manuel" : "automatique"))
        var fin: [String: Any] = ["eclat": id, "creneau": claimDone.slot, "run_id": rid, "decision": orphan ? "fin tardive" : "fin",
                                  "motif": "fin de passage (" + origineTxt + ")" + (orphan ? " — run orphelin, rien livré" : ""),
                                  "retard_min": 0, "duree_s": Int(clock().timeIntervalSince(t0)), "statut": statutFin, "etat": phase.rawValue]
        DotScheduler.addGovernor(&fin)
        DotScheduler.mirror(fin)
        if orphan { then?(""); publish("dot", ["phase": "idle", "dot": id, "stopped": true]); return }
        if (r?["arrete"] as? Bool) == true {   // VAGUE 2 FIABILITÉ : arrêté à la demande — ni notification, ni file de décision, ni échec journalisé
            then?(text)
            publish("dot", ["phase": "idle", "dot": id, "stopped": true])
            return
        }
        deliver(r, text: text, d: d, id: id, manual: manual, then: then)
    }

    /// Livraison d'un run terminé (inchangée sur le fond : RAS discret, file de décision, résumé borné).
    private func deliver(_ r: [String: Any]?, text: String, d: [String: Any], id: String, manual: Bool, then: ((String) -> Void)?) {
        let ok = !text.isEmpty && DotCharter.status(of: text) != "ECHEC"
        if !ok {
            // LOT-CORR (nuit 22→23/10) : un échec — surtout éclair (< 1 s) — est journalisé AVEC sa cause
            // (statut, durée, sorties des étapes) ; avant, seul le texte générique « aucun cerveau n'a
            // répondu » partait et la cause restait innommable, y compris pour Nova.
            let stepsTxt = ((r?["steps"] as? [[String: Any]]) ?? []).map { stp -> String in
                let t = (stp["tool"] as? String) ?? "?"
                let o = String(((stp["output"] as? String) ?? "").prefix(200))
                return o.isEmpty ? t : "\(t): \(o)"
            }.joined(separator: " · ")
            _ = BlackBox.record(["tool": "dots_scheduler", "actor": "Nova",
                                 "why": "échec du Dot \(id) (\((d["name"] as? String) ?? id)) — statut \((r?["status"] as? String) ?? "?") en \((r?["ms"] as? Int) ?? -1) ms",
                                 "ok": false, "effect": "lecture",
                                 "result": stepsTxt.isEmpty ? "aucune étape enregistrée" : String(stepsTxt.prefix(600))])
        }
        then?(text)
        // FLOTTE V1 (25/10) : « RAS » = discret pour TOUT Éclat (avant : seulement ceux marqués quiet_ok) — ni carte, ni notification, ni file.
        if DotScheduler.isRAS(text) { publish("dot", ["phase": "idle", "dot": id]); return }
        let rid = (r?["id"] as? String) ?? UUID().uuidString.prefix(8).lowercased().description
        // File d'attente du chef d'orchestre : SEULEMENT une vraie décision (FLOTTE V1) — un compte rendu se lit dans Exécutions et au Fil direct.
        var entry: [String: Any] = ["run_id": rid, "dot": id, "ts": nowISO()]
        let decision: Bool = (r?["decision"] as? Bool) ?? false
        if decision { entry["decision"] = true; entry["question"] = (r?["question"] as? String) ?? "" }
        if let sup = r?["supervision"] as? String, !sup.isEmpty { entry["supervision"] = String(sup.prefix(400)) }
        if decision {
            if !manual, !AmeSilence.allow(plafond: settings.get("dots_plafond", 6)) {   // silence : plafond d'interruptions atteint — la décision reste en file, sans notification
                appendPending(entry)
                publish("dot", ["phase": "idle", "dot": id]); return
            }
            appendPending(entry)
        }
        // FIX-RADAR R4 / LOT-DIRECT-FIL ② : le résumé publié est borné à 600 caractères (seuil du Feed ≥ 280, §A.5.3).
        // FLOTTE V1 : « notify » — la notification macOS n'accompagne qu'une vraie décision ; le reste entre au Fil sans sonner.
        let sumCap = 600
        let flat: String = text.replacingOccurrences(of: "\n", with: " ")
        let summary: String = ok ? String(flat.prefix(sumCap)) : "Je n'ai pas pu produire de résultat (aucun cerveau n'a répondu)."
        var ev: [String: Any] = ["phase": "ready", "dot": id, "run_id": rid, "ok": ok, "summary": summary, "notify": decision]
        ev["name"] = d["name"] ?? ""
        ev["emoji"] = d["emoji"] ?? "●"
        ev["color"] = d["color"] ?? "#D93226"
        publish("dot", ev)
    }

    /// FLOTTE V1 : un Éclat n'a qu'UNE entrée en file — la plus récente ; les précédentes sont classées « remplacées » (jamais perdues).
    func appendPending(_ entry: [String: Any]) {
        let p: [[String: Any]] = pending.read(default: [[String: Any]]())
        let dot: String = (entry["dot"] as? String) ?? ""
        var keep: [[String: Any]] = []
        var filed: [[String: Any]] = []
        for e in p {
            if !dot.isEmpty && (e["dot"] as? String) == dot {
                var x: [String: Any] = e
                x["classe_motif"] = "remplacé par un passage plus récent du même Éclat"
                filed.append(x)
            } else {
                keep.append(e)
            }
        }
        if !filed.isEmpty { DotScheduler.fileAway(filed) }
        keep.append(entry)
        pending.write(Array(keep.suffix(30)))
    }

    // MARK: FLOTTE V1 (25/10/2026) — discrétion et file d'attente
    /// Retiré ou « à la demande » : le planificateur ne le lance jamais (lancement manuel possible).
    static func isUnscheduled(_ d: [String: Any]) -> Bool {
        if (d["on_demand"] as? Bool) == true { return true }
        // 31/10 (diag Éclats) : délégation échue et en pause — terminée, plus rien à planifier ni à journaliser.
        if (d["delegation"] as? Bool) == true, (d["paused"] as? Bool) == true, let u = d["until"] as? String,
           let ud = ISO8601DateFormatter().date(from: u), ud < Date() { return true }
        return (d["retired"] as? Bool) == true && (d["paused"] as? Bool) == true
    }
    /// Rien à signaler : « RAS » en tête (ou « STATUT : RAS », « STATUT : OK — RAS »).
    static func isRAS(_ text: String) -> Bool {
        let t: String = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let heads: [String] = ["RAS", "STATUT : RAS", "STATUT: RAS", "STATUT : OK — RAS", "STATUT : OK - RAS", "STATUT : OK RAS"]
        for h in heads where t.hasPrefix(h) { return true }
        return false
    }
    /// Entrées sorties de la file : CLASSÉES ici avec leur motif (consultables, jamais supprimées).
    static let filedStore: JSONFile = JSONFile("dots_attente_classees.json")
    static func fileAway(_ items: [[String: Any]]) {
        var a: [[String: Any]] = filedStore.read(default: [[String: Any]]())
        let stamp: String = nowISO()
        for it in items {
            var x: [String: Any] = it
            x["classe_ts"] = stamp
            a.append(x)
        }
        filedStore.write(Array(a.suffix(300)))
    }
    /// Remet la file aux règles actuelles (idempotent, à chaque démarrage) : seulement de vraies décisions, une par Éclat (la plus récente).
    func tidyPending() {
        let p: [[String: Any]] = pending.read(default: [[String: Any]]())
        if p.isEmpty { return }
        var keep: [[String: Any]] = []
        var filed: [[String: Any]] = []
        var seen: Set<String> = []
        for e in p.reversed() {
            let dot: String = (e["dot"] as? String) ?? ""
            let isDecision: Bool = (e["decision"] as? Bool) == true
            let q: String = (e["question"] as? String) ?? ""
            var motif: String = ""
            if !isDecision { motif = "compte rendu sans décision — consultable dans Exécutions" }
            else if !Dots.isRealDecision(q) { motif = "demande de lecture ou d'accès — l'Éclat la fait lui-même, ce n'est pas une décision" }
            else if !dot.isEmpty && seen.contains(dot) { motif = "remplacé par un passage plus récent du même Éclat" }
            if motif.isEmpty {
                if !dot.isEmpty { seen.insert(dot) }
                keep.insert(e, at: 0)
            } else {
                var x: [String: Any] = e
                x["classe_motif"] = motif
                filed.append(x)
            }
        }
        if filed.isEmpty { return }
        pending.write(keep)
        DotScheduler.fileAway(filed)
        let why: String = "FLOTTE V1 : file d'attente remise aux règles — \(filed.count) entrée(s) classée(s), \(keep.count) vraie(s) décision(s) gardée(s)"
        _ = BlackBox.record(["tool": "dots_attente", "actor": "Nova", "why": why, "ok": true, "effect": "migration"])
    }

    /// WP1 : « aujourd'hui » dans le fuseau des créneaux (avant : jour UTC).
    func bilanTask(_ now: Date? = nil) -> String {
        let today: String = DotScheduler.dayKey(now ?? clock(), scheduleCalendar())
        let cal: Calendar = scheduleCalendar(); let isoF = ISO8601DateFormatter()
        let runs = dots.history().filter { h -> Bool in
            guard let ts = h["ts"] as? String, let t = isoF.date(from: ts), DotScheduler.dayKey(t, cal) == today else { return false }
            return (h["dot"] as? String) != "bilan" && (h["ok"] as? Bool) == true
        }
        let body = runs.prefix(8).map { "• \($0["dot"] ?? "") (\(String((($0["ts"] as? String) ?? "").dropFirst(11).prefix(5)))) : " + String(($0["result"] as? String ?? "").replacingOccurrences(of: "\n", with: " ").prefix(500)) }.joined(separator: "\n")
        return "Fais le bilan de la journée du \(today). Résultats des Dots d'aujourd'hui :\n" + (body.isEmpty ? "(aucun Dot n'a livré de résultat aujourd'hui)" : body)
    }

    // MARK: attente / report
    public func snooze(runId: String, minutes: Int) {
        var p = pending.read(default: [[String: Any]]())
        if let i = p.firstIndex(where: { ($0["run_id"] as? String) == runId }) { p[i]["until"] = Date().addingTimeInterval(Double(max(1, min(minutes, 24 * 60)) * 60)).timeIntervalSince1970; pending.write(p) }
    }
    public func ack(runId: String) { pending.write(pending.read(default: [[String: Any]]()).filter { ($0["run_id"] as? String) != runId }) }
    public func waiting() -> [[String: Any]] {
        let now = Date().timeIntervalSince1970
        let pend: [[String: Any]] = pending.read(default: [[String: Any]]())
        if pend.isEmpty { return [] }
        let hist: [[String: Any]] = dots.history()   // lus UNE fois (avant : historique relu pour chaque entrée)
        let all: [[String: Any]] = dots.list()
        return pend.compactMap { p -> [String: Any]? in
            if let u = p["until"] as? Double, u > now { return nil }
            guard let rid = p["run_id"] as? String, let run = hist.first(where: { ($0["id"] as? String) == rid }),
                  let d = all.first(where: { ($0["id"] as? String) == (p["dot"] as? String) }) else { return nil }
            var o: [String: Any] = ["run_id": rid, "dot": p["dot"] ?? "", "name": d["name"] ?? "", "emoji": d["emoji"] ?? "●", "color": d["color"] ?? "#D93226",
                    "summary": String(((run["result"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ").prefix(240)), "ts": run["ts"] ?? ""]
            if (p["decision"] as? Bool) == true { o["decision"] = true; o["question"] = p["question"] ?? "" }
            if let sup = p["supervision"] as? String { o["supervision"] = sup }
            return o
        }
    }
    private func releaseSnoozed(_ now: Date) {
        var p = pending.read(default: [[String: Any]]()); var changed = false
        var ready: [[String: Any]]? = nil
        for i in p.indices { if let u = p[i]["until"] as? Double, u <= now.timeIntervalSince1970 {
            p[i].removeValue(forKey: "until"); changed = true
            if ready == nil { ready = waiting() }
            if let w = ready?.first(where: { ($0["run_id"] as? String) == (p[i]["run_id"] as? String) }) { var e = w; e["phase"] = "ready"; e["snoozed"] = true; publish("dot", e) } } }
        if changed { pending.write(p) }
    }
}
