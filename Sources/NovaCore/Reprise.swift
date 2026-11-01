import Foundation
#if canImport(EventKit)
import EventKit
#endif

/// AUTONOMIE A3 (22/10) — REPRISE DES PRODUCTEURS SUR DÉPENDANCE ABSENTE.
///
/// Problème traité : quand un producteur (brief, passe radar du Feed, Dot) échoue
/// parce qu'une DÉPENDANCE est absente — cerveau épinglé en panne, accès Calendrier
/// refusé, volet de messagerie déconnecté — l'échec était terminal : le créneau du
/// brief était consommé jusqu'au lendemain, la passe radar marquait son lot comme
/// traité, le Dot attendait son prochain créneau. Rien ne relançait le producteur
/// quand la dépendance revenait.
///
/// Mécanisme : le producteur enregistre son échec ici (producer, key, dep). Une
/// sonde (tic de 20 s, même patron que Briefs.startScheduler, + déclenchement
/// immédiat au retour d'un volet via WebMail.onPaneBack) lit l'ÉTAT RÉEL de la
/// dépendance — jamais une minuterie aveugle : cerveau sorti de quarantaine
/// (Router.isDead), accès Calendrier accordé (EventKit), instantané de volet
/// frais (WebMail, seuil du rapport : 45 min). Au retour de l'état, l'entrée est
/// marquée terminée AVANT le tir (aucun doublon possible), puis :
///   • si le producteur a déjà réussi depuis l'échec (horodatage du dernier
///     succès postérieur à failed_at, vérifié par le crochet `recovered`), on
///     ferme sans tirer — idempotence ;
///   • sinon on re-déclenche le producteur UNE fois (crochet `fire`, câblé par App).
/// Chaque étape est journalisée (reprises_journal.jsonl + blackbox).
///
/// Les producteurs d'ÉVÉNEMENTS (WebMail → ProactiveFeed → fil Direct) ne passent
/// PAS par ici : leurs arrivées manquées se rattrapent d'elles-mêmes au retour du
/// volet (diff contre `seen` persistant), et re-déclencher la composition créerait
/// un doublon dans le fil. La sonde « volet » sert aux producteurs qui CONSOMMENT
/// un volet (Dots via teams_read), pas à celui qui le produit.
public enum Reprise {
    struct Handlers {
        var brainAlive: (String) -> Bool
        var paneFresh: (String) -> Bool
        var recovered: (_ producer: String, _ key: String, _ sinceISO: String) -> Bool
        var fire: (_ producer: String, _ key: String, _ label: String) -> Void
    }
    private static var handlers: Handlers?
    private static let store = JSONFile("reprises.json")
    private static let log = Journal("reprises_journal.jsonl")
    private static let lock = NSLock()
    private static let tickLock = NSLock()
    private static var started = false

    /// Câblage par App au démarrage (les crochets portent les instances vivantes :
    /// routeur, briefs, dots, planificateur — Reprise ne connaît que des noms).
    public static func configure(brainAlive: @escaping (String) -> Bool,
                                 paneFresh: @escaping (String) -> Bool,
                                 recovered: @escaping (_ producer: String, _ key: String, _ sinceISO: String) -> Bool,
                                 fire: @escaping (_ producer: String, _ key: String, _ label: String) -> Void) {
        lock.lock(); handlers = Handlers(brainAlive: brainAlive, paneFresh: paneFresh, recovered: recovered, fire: fire); lock.unlock()
    }

    /// Enregistre un échec de producteur sur dépendance absente. Dédupliqué : une
    /// entrée ouverte pour le même (producer, key, dep) n'est jamais dupliquée —
    /// les échecs répétés d'un même épisode ne créent qu'une seule reprise.
    public static func note(producer: String, key: String, dep: String, label: String) {
        lock.lock(); defer { lock.unlock() }
        var all = store.read(default: [[String: Any]]())
        if all.contains(where: { ($0["producer"] as? String) == producer && ($0["key"] as? String) == key && ($0["dep"] as? String) == dep && ($0["done"] as? Bool) != true }) { return }
        all.append(["producer": producer, "key": key, "dep": dep, "label": label, "failed_at": nowISO(), "done": false])
        store.write(Array(all.suffix(50)))
        log.add(["event": "note", "producer": producer, "key": key, "dep": dep])
    }

    /// État réel d'une dépendance. Formats : « brain:<id> », « calendar », « pane:<id> ».
    static func depReady(_ dep: String) -> Bool {
        lock.lock(); let h = handlers; lock.unlock()
        guard let h = h else { return false }
        if dep == "calendar" {
            #if canImport(EventKit) && os(macOS)
            let st = EKEventStore.authorizationStatus(for: .event)
            if #available(macOS 14.0, *) { return st == .fullAccess }
            return st == .authorized
            #else
            return false   // sans EventKit, l'état n'est pas observable : on ne tire pas à l'aveugle
            #endif
        }
        if dep.hasPrefix("brain:") { return h.brainAlive(String(dep.dropFirst(6))) }
        if dep.hasPrefix("pane:") { return h.paneFresh(String(dep.dropFirst(5))) }
        return false
    }

    public static func start() {
        lock.lock(); if started { lock.unlock(); return }; started = true; lock.unlock()
        Thread.detachNewThread { while true { Thread.sleep(forTimeInterval: 20); tick() } }
    }

    /// Déclenchement immédiat (retour d'un volet signalé par WebMail) : la sonde
    /// repasse sans attendre le tic — le déclencheur reste l'état, pas l'horloge.
    public static func kick() { Thread.detachNewThread { tick() } }

    static func tick() {
        guard tickLock.try() else { return }   // deux sondes ne se marchent jamais dessus
        defer { tickLock.unlock() }
        lock.lock(); let h = handlers; lock.unlock()
        guard let h = h else { return }
        // FIX-B1 (revue-gate finale du 22/10) : `lock` n'est tenu QUE pour lire ou
        // écrire le magasin. L'ancienne boucle le tenait d'un bout à l'autre et
        // appelait depReady — qui acquiert ce même NSLock non récursif pour lire
        // `handlers` — dès la première entrée ouverte : le fil de sonde se bloquait
        // sur lui-même, `lock` et `tickLock` restaient tenus, et note() gelait les
        // producteurs. Désormais : (1) photographie des entrées ouvertes sous
        // verrou ; (2) depReady/recovered évalués HORS section critique ;
        // (3) réacquisition pour marquer `done` et écrire — toujours AVANT tout
        // tir. Registre, déduplication, idempotence et ordre des effets inchangés.
        lock.lock()
        let open = store.read(default: [[String: Any]]()).filter { ($0["done"] as? Bool) != true }
        lock.unlock()
        var verdicts: [(producer: String, key: String, label: String, dep: String, failedAt: String, recovered: Bool)] = []
        for e in open {
            let dep = (e["dep"] as? String) ?? ""
            guard depReady(dep) else { continue }
            let producer = (e["producer"] as? String) ?? ""
            let key = (e["key"] as? String) ?? ""
            let failedAt = (e["failed_at"] as? String) ?? ""
            verdicts.append((producer, key, (e["label"] as? String) ?? key, dep, failedAt, h.recovered(producer, key, failedAt)))
        }
        if !verdicts.isEmpty {
            // Marquées terminées AVANT tout tir : même si le tir échoue, il ne sera
            // pas doublé — le producteur ré-enregistrera un échec neuf s'il échoue
            // encore. Relecture fraîche sous verrou : un note() concurrent a pu
            // ajouter une entrée pendant l'évaluation hors section — elle ne doit
            // pas être écrasée par cette écriture.
            lock.lock()
            var all = store.read(default: [[String: Any]]())
            var changed = false
            for v in verdicts {
                for i in all.indices where (all[i]["done"] as? Bool) != true
                    && ((all[i]["producer"] as? String) ?? "") == v.producer
                    && ((all[i]["key"] as? String) ?? "") == v.key
                    && ((all[i]["dep"] as? String) ?? "") == v.dep
                    && ((all[i]["failed_at"] as? String) ?? "") == v.failedAt {
                    all[i]["done"] = true; all[i]["done_at"] = nowISO(); changed = true
                    if v.recovered { all[i]["done_reason"] = "déjà récupéré : succès du producteur postérieur à l'échec" }
                    break
                }
            }
            if changed { store.write(all) }
            lock.unlock()
        }
        for v in verdicts where v.recovered {
            log.add(["event": "close", "producer": v.producer, "key": v.key, "dep": v.dep, "reason": "recovered"])
        }
        for v in verdicts where !v.recovered {
            log.add(["event": "fire", "producer": v.producer, "key": v.key, "dep": v.dep])
            _ = BlackBox.record(["tool": "reprise", "actor": "Nova", "why": "A3 : reprise du producteur « \(v.producer) » (\(v.key)) — dépendance « \(v.dep) » de retour", "ok": true, "effect": "relance producteur"])
            h.fire(v.producer, v.key, v.label)
        }
    }
}
