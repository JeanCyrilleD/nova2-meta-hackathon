import Foundation

// Nova Plus — SANTÉ DES DOTS (réparation automatique + discrétion par Dot).
// (A) Toutes les 5 min (1er tir à 240 s) : un Dot actif dont les 2 derniers passages sont en ÉCHEC est mis en pause (champ existant « paused »,
//     respecté par DotScheduler.tick), puis UN diagnostic en arrière-plan (router.complete, mode deep) classe la cause et propose une consigne corrigée.
//     La consigne est posée dans le champ « directive » du Dot (ordre permanent lu par Dots.chefBlock) — jamais dans « prompt » (champ verrouillé par la charte).
//     L'ancienne directive est gardée dans dot_care.json (réversible : POST /api/dotcare/revert). Puis UNE relance (scheduler.launch) :
//     si elle réussit, le Dot est réactivé ; sinon il reste en pause. Compte rendu : UNE ligne dans dot_care.jsonl + évènement SSE « dotcare ».
// (B) Discrétion par Dot (silencieux | resume | notification) dans dot_discretion.json ; appliquée par l'interface (web/addons/dotcare.js).
// Aucune modification de Dots.swift / DotScheduler.swift. Rien n'est envoyé, payé ni supprimé.

final class DotCareEngine: @unchecked Sendable {
    nonisolated(unsafe) static var timer: DispatchSourceTimer? = nil     // référence forte : un minuteur relâché s'arrête
    nonisolated(unsafe) static var shared: DotCareEngine? = nil
    nonisolated(unsafe) static var busy: Bool = false   // PHASE 1 (relu, protégé) : sous DotCareEngine.busyLock
    static let busyLock = NSLock()
    static let levels: [String] = ["silencieux", "resume", "notification"]

    let dots: Dots
    let scheduler: DotScheduler
    let router: Router
    let publish: (String, Any) -> Void
    let care: JSONFile = JSONFile("dot_care.json")                 // { dotId: { paused_by_care, seen, cause, consigne, old_directive, has_old, relaunch, line, … } }
    let discretion: JSONFile = JSONFile("dot_discretion.json")     // { dotId: "silencieux" | "resume" | "notification" }
    let journal: Journal = Journal("dot_care.jsonl")
    let stateLock = NSLock()

    init(dots: Dots, scheduler: DotScheduler, router: Router, publish: @escaping (String, Any) -> Void) {
        self.dots = dots; self.scheduler = scheduler; self.router = router; self.publish = publish
    }

    // MARK: état
    func readState() -> [String: Any] { return care.read(default: [String: Any]()) }
    func entry(_ id: String) -> [String: Any] {
        let st: [String: Any] = readState()
        return (st[id] as? [String: Any]) ?? [String: Any]()
    }
    /// Fusionne des champs dans l'entrée d'un Dot (verrou : le minuteur et les routes peuvent écrire en même temps).
    func patch(_ id: String, _ fields: [String: Any]) {
        stateLock.lock(); defer { stateLock.unlock() }
        var st: [String: Any] = readState()
        var e: [String: Any] = (st[id] as? [String: Any]) ?? [String: Any]()
        for (k, v) in fields { e[k] = v }
        st[id] = e
        care.write(st)
    }

    static func isFailure(_ r: [String: Any]) -> Bool {
        if let ok = r["ok"] as? Bool, ok == false { return true }
        let s: String = (r["status"] as? String) ?? ""
        return s == "ECHEC"
    }
    static func isFollowUp(_ r: [String: Any]) -> Bool {
        let t: String = (r["task"] as? String) ?? ""
        return t.hasPrefix("[SUIVI]")
    }

    /// Passages récents d'un Dot (du plus récent au plus ancien), hors questions de suivi, plus récents que `after`.
    func recentRuns(_ id: String, after: String) -> [[String: Any]] {
        let all: [[String: Any]] = dots.history(id)
        var out: [[String: Any]] = []
        for r in all {
            if DotCareEngine.isFollowUp(r) { continue }
            if (r["arrete"] as? Bool) == true { continue }   // VAGUE 2 FIABILITÉ : un run arrêté à la demande n'est pas un échec
            if (r["statut"] as? String) == "en_cours" { continue }   // run encore en vol : ni succès ni échec
            let ts: String = (r["ts"] as? String) ?? ""
            if !after.isEmpty && ts <= after { continue }
            out.append(r)
        }
        return out
    }
    static func consecutiveFailures(_ runs: [[String: Any]]) -> Int {
        var n: Int = 0
        for r in runs { if isFailure(r) { n += 1 } else { break } }
        return n
    }

    func cleanDot(_ d: [String: Any]) -> [String: Any] {
        var n: [String: Any] = d
        n.removeValue(forKey: "persona")   // champ calculé par Dots.list(), jamais stocké
        return n
    }
    func findDot(_ id: String) -> [String: Any]? {
        return dots.list().first(where: { ($0["id"] as? String) == id })
    }
    func setPaused(_ id: String, _ paused: Bool) -> Bool {
        guard let d = findDot(id) else { return false }
        var n: [String: Any] = cleanDot(d)
        n["paused"] = paused
        dots.save(n)
        return true
    }

    // MARK: minuteur
    func scan() {
        if !dots.settings.get("dots_auto", true) { return }   // planification coupée : pas de diagnostic ni de relance automatiques
        DotCareEngine.busyLock.lock()
        if DotCareEngine.busy { DotCareEngine.busyLock.unlock(); return }
        DotCareEngine.busy = true
        DotCareEngine.busyLock.unlock()
        defer { DotCareEngine.busyLock.lock(); DotCareEngine.busy = false; DotCareEngine.busyLock.unlock() }

        for d in dots.list() {
            guard let id = d["id"] as? String else { continue }
            if (d["paused"] as? Bool) == true { continue }                 // déjà en pause (utilisateur, assistant ou nous)
            let e: [String: Any] = entry(id)
            let seen: String = (e["seen"] as? String) ?? ""
            let runs: [[String: Any]] = recentRuns(id, after: seen)
            if DotCareEngine.consecutiveFailures(runs) < 2 { continue }
            repair(d, id: id, failed: Array(runs.prefix(2)))
            break   // sobriété : un seul diagnostic par passage du minuteur
        }
    }

    // MARK: réparation
    func repair(_ d: [String: Any], id: String, failed: [[String: Any]]) {
        let name: String = (d["name"] as? String) ?? id
        let newestTs: String = (failed.first?["ts"] as? String) ?? nowISO()
        // 1) pause (champ existant « paused », lu par DotScheduler.tick)
        _ = setPaused(id, true)
        patch(id, ["paused_by_care": true, "paused_at": nowISO(), "seen": newestTs, "relaunch": "", "line": ""])
        publish("dotcare", ["phase": "paused", "dot": id, "name": name])

        // 2) diagnostic unique
        let diag: [String: String] = diagnose(d, failed: failed)
        let cause: String = diag["cause"] ?? "indéterminée"
        let why: String = diag["explication"] ?? ""
        let fix: String = diag["consigne"] ?? ""
        patch(id, ["cause": cause, "explication": why, "consigne": fix, "diagnosed_at": nowISO()])

        // 3) consigne corrigée → champ « directive » (l'ancienne est gardée, réversible)
        var applied: Bool = false
        if !fix.isEmpty, let cur = findDot(id) {
            let old: String = (cur["directive"] as? String) ?? ""
            let e: [String: Any] = entry(id)
            let alreadySaved: Bool = (e["has_old"] as? Bool) ?? false
            let original: String = alreadySaved ? ((e["old_directive"] as? String) ?? "") : old   // garde la VRAIE directive d'origine si une correction précédente n'a pas été annulée
            var n: [String: Any] = cleanDot(cur)
            let day: String = String(nowISO().prefix(10))
            var dir: String = "CORRECTION SANTÉ DES DOTS (" + day + ") : " + fix
            if !original.isEmpty { dir += "\n" + original }
            n["directive"] = dir
            dots.save(n)
            patch(id, ["old_directive": original, "has_old": true, "applied": true])
            applied = true
        }

        // 4) une seule relance (attend au plus 2 min que la file se libère : un seul Dot à la fois)
        var waited: Int = 0
        while waited < 120 {
            let active: [String] = scheduler.activeIds()
            if active.isEmpty { break }
            Thread.sleep(forTimeInterval: 10); waited += 10
        }
        let active: [String] = scheduler.activeIds()
        guard let fresh = findDot(id), active.isEmpty else {
            finish(id: id, name: name, cause: cause, why: why, applied: applied, relaunch: "reportée (Dots occupés) — reprise manuelle possible")
            return
        }
        patch(id, ["relaunch": "en cours"])
        let appliedFinal: Bool = applied
        scheduler.launch(fresh, task: "", manual: false) { [self] text in
            let st: String? = DotCharter.status(of: text)
            let stoppedByUser: Bool = text.hasPrefix("STATUT : ARRÊTÉ")   // VAGUE 2 FIABILITÉ : relance arrêtée à la main — ni réussite, ni échec
            let ok: Bool = !text.isEmpty && st != "ECHEC" && !stoppedByUser
            if stoppedByUser {
                self.patch(id, ["seen": nowISO()])
                self.finish(id: id, name: name, cause: cause, why: why, applied: appliedFinal, relaunch: "arrêtée à ta demande, Dot laissé en pause")
            } else if ok {
                _ = self.setPaused(id, false)
                self.patch(id, ["paused_by_care": false, "seen": nowISO()])
                self.finish(id: id, name: name, cause: cause, why: why, applied: appliedFinal, relaunch: "OK, Dot réactivé")
            } else {
                self.patch(id, ["seen": nowISO()])
                self.finish(id: id, name: name, cause: cause, why: why, applied: appliedFinal, relaunch: "nouvel échec, Dot laissé en pause")
            }
        }
    }

    /// UNE ligne de compte rendu (journal + SSE « dotcare »).
    func finish(id: String, name: String, cause: String, why: String, applied: Bool, relaunch: String) {
        var line: String = name + " : 2 échecs consécutifs → pause. Cause : " + cause
        if !why.isEmpty { line += " (" + String(why.prefix(140)) + ")" }
        line += applied ? ". Consigne corrigée appliquée (réversible)" : ". Consigne inchangée"
        line += ". Relance : " + relaunch + "."
        patch(id, ["relaunch": relaunch, "line": line, "done_at": nowISO()])
        journal.add(["dot": id, "name": name, "cause": cause, "applied": applied, "relaunch": relaunch, "line": line])
        publish("dotcare", ["phase": "report", "dot": id, "name": name, "line": line])
    }

    func diagnose(_ d: [String: Any], failed: [[String: Any]]) -> [String: String] {
        let name: String = (d["name"] as? String) ?? ""
        let role: String = (d["role"] as? String) ?? ""
        let prompt: String = (d["prompt"] as? String) ?? ""
        let tools: [String] = (d["tools"] as? [String]) ?? []
        var reports: String = ""
        var k: Int = 1
        for r in failed {
            let ts: String = (r["ts"] as? String) ?? ""
            let brain: String = (r["brain"] as? String) ?? ""
            let res: String = String(((r["result"] as? String) ?? "").prefix(1200))
            reports += "\n--- Passage " + String(k) + " (" + ts + ", cerveau : " + brain + ") ---\nRapport : " + res + "\nÉtapes d'outils :\n"
            let steps: [[String: Any]] = (r["steps"] as? [[String: Any]]) ?? []
            if steps.isEmpty { reports += "(aucun outil appelé)\n" }
            for s in steps.suffix(8) {
                let t: String = (s["tool"] as? String) ?? ""
                let i: String = String(((s["input"] as? String) ?? "").prefix(150))
                let o: String = String(((s["output"] as? String) ?? "").prefix(300))
                reports += "• " + t + " (" + i + ") → " + o + "\n"
            }
            k += 1
        }
        let sys: String = "Tu es le mécanicien des Dots (agents) de l'app Nova sur macOS. Tu analyses des échecs et tu réponds UNIQUEMENT par un objet JSON, sans texte autour."
        var q: String = "Le Dot « " + name + " » a échoué deux fois de suite.\nRôle : " + role + "\nOutils autorisés : " + tools.joined(separator: ", ")
        q += "\nConsigne permanente : " + String(prompt.prefix(1200)) + "\n" + reports
        q += "\nClasse la cause principale parmi : cerveau (IA indisponible, délai, réponse vide), outil (outil en erreur ou mal utilisé), droit (autorisation macOS manquante : Automatisation, Calendrier, Rappels, Mail, Accessibilité…), consigne (consigne ambiguë, irréaliste ou contradictoire), donnee (donnée absente ou introuvable)."
        q += "\nPropose une consigne corrigée COURTE (3 phrases max) qui complète la mission pour éviter cet échec (autre outil, autre source, critère de repli, accepter un résultat PARTIEL). Rien qui envoie, paie ou supprime."
        q += "\nRéponds exactement : {\"cause\":\"cerveau|outil|droit|consigne|donnee\",\"explication\":\"une phrase\",\"consigne\":\"…\"}"
        guard let r = router.complete(messages: [ChatMsg("user", q)], system: sys, mode: "deep", maxTokens: 700) else {
            return ["cause": "cerveau", "explication": "diagnostic impossible : aucun cerveau n'a répondu", "consigne": ""]
        }
        guard let o = DotCareEngine.extractJSON(r.text) else {
            return ["cause": "indéterminée", "explication": String(r.text.replacingOccurrences(of: "\n", with: " ").prefix(160)), "consigne": ""]
        }
        let rawCause: String = ((o["cause"] as? String) ?? "").lowercased()
        let expl: String = String(((o["explication"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ").prefix(240))
        let fix: String = String(((o["consigne"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
        return ["cause": DotCareEngine.label(rawCause), "explication": expl, "consigne": fix]
    }

    static func label(_ c: String) -> String {
        if c.contains("cerveau") { return "cerveau" }
        if c.contains("outil") { return "outil" }
        if c.contains("droit") { return "droit macOS" }
        if c.contains("consigne") { return "consigne" }
        if c.contains("donn") { return "donnée absente" }
        return "indéterminée"
    }
    static func extractJSON(_ s: String) -> [String: Any]? {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return nil }
        let sub: String = String(s[a...b])
        return parseJSON(Data(sub.utf8))
    }

    // MARK: vues
    func overview() -> [String: Any] {
        let st: [String: Any] = readState()
        let disc: [String: Any] = discretion.read(default: [String: Any]())
        var items: [[String: Any]] = []
        for d in dots.list() {
            guard let id = d["id"] as? String else { continue }
            let runs: [[String: Any]] = recentRuns(id, after: "")
            let e: [String: Any] = (st[id] as? [String: Any]) ?? [String: Any]()
            var it: [String: Any] = [:]
            it["id"] = id
            it["name"] = (d["name"] as? String) ?? id
            it["emoji"] = (d["emoji"] as? String) ?? "●"
            it["color"] = (d["color"] as? String) ?? "#D93226"
            it["paused"] = (d["paused"] as? Bool) ?? false
            it["schedule"] = (d["schedule"] as? String) ?? ""
            it["fails"] = DotCareEngine.consecutiveFailures(runs)
            if let last = runs.first {
                let ok: Bool = !DotCareEngine.isFailure(last)
                it["last_ok"] = ok
                it["last_status"] = (last["status"] as? String) ?? ""
                it["last_ts"] = (last["ts"] as? String) ?? ""
            }
            it["discretion"] = (disc[id] as? String) ?? "resume"
            it["care"] = e
            items.append(it)
        }
        return ["items": items, "journal": Array(journal.tail(30).reversed()), "levels": DotCareEngine.levels]
    }
}

extension NovaApp {
    func dotCareRoutes() {
        let s = server
        let b: Bus = bus
        let eng: DotCareEngine = DotCareEngine(dots: dots, scheduler: scheduler, router: router, publish: { (ev: String, o: Any) in b.publish(ev, o) })
        DotCareEngine.shared = eng
        if DotCareEngine.timer == nil {
            let t: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "nova.bg.dotcare", qos: .utility))
            t.schedule(deadline: .now() + 240, repeating: 300, leeway: .seconds(5))
            t.setEventHandler { DotCareEngine.shared?.scan() }
            DotCareEngine.timer = t
            t.resume()
        }

        s.on("GET", "/api/dotcare") { req, res in
            res.json(eng.overview())
        }
        s.on("POST", "/api/dotcare/resume") { req, res in
            let id: String = (req.json["id"] as? String) ?? ""
            guard !id.isEmpty, eng.setPaused(id, false) else { res.json(["error": "Dot introuvable"], status: 404); return }
            eng.patch(id, ["paused_by_care": false, "seen": nowISO()])   // repart d'un compteur d'échecs à zéro
            eng.journal.add(["dot": id, "line": "Reprise manuelle du Dot « " + id + " »."])
            eng.publish("dotcare", ["phase": "resumed", "dot": id])
            res.json(["ok": true])
        }
        s.on("POST", "/api/dotcare/pause") { req, res in
            let id: String = (req.json["id"] as? String) ?? ""
            guard !id.isEmpty, eng.setPaused(id, true) else { res.json(["error": "Dot introuvable"], status: 404); return }
            eng.journal.add(["dot": id, "line": "Pause manuelle du Dot « " + id + " »."])
            eng.publish("dotcare", ["phase": "paused", "dot": id])
            res.json(["ok": true])
        }
        s.on("POST", "/api/dotcare/revert") { req, res in
            let id: String = (req.json["id"] as? String) ?? ""
            let e: [String: Any] = eng.entry(id)
            guard !id.isEmpty, (e["has_old"] as? Bool) == true, let d = eng.findDot(id) else { res.json(["error": "aucune consigne d'origine à restaurer"], status: 400); return }
            let old: String = (e["old_directive"] as? String) ?? ""
            var n: [String: Any] = eng.cleanDot(d)
            if old.isEmpty { n.removeValue(forKey: "directive") } else { n["directive"] = old }
            eng.dots.save(n)
            eng.patch(id, ["has_old": false, "applied": false, "reverted_at": nowISO()])
            eng.journal.add(["dot": id, "line": "Consigne d'origine restaurée pour « " + id + " »."])
            eng.publish("dotcare", ["phase": "reverted", "dot": id])
            res.json(["ok": true])
        }
        s.on("GET", "/api/dotcare/discretion") { req, res in
            let m: [String: Any] = eng.discretion.read(default: [String: Any]())
            res.json(["levels": m, "choices": DotCareEngine.levels])
        }
        s.on("POST", "/api/dotcare/discretion") { req, res in
            let id: String = (req.json["id"] as? String) ?? ""
            let level: String = (req.json["level"] as? String) ?? ""
            guard !id.isEmpty, DotCareEngine.levels.contains(level) else { res.json(["error": "id ou niveau invalide (silencieux | resume | notification)"], status: 400); return }
            var m: [String: Any] = eng.discretion.read(default: [String: Any]())
            m[id] = level
            eng.discretion.write(m)
            eng.publish("dotcare", ["phase": "discretion", "dot": id, "level": level])
            res.json(["ok": true, "levels": m])
        }
    }
}
