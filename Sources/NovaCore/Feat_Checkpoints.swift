import Foundation

// LOT M : couche agent « visible, contrôlable, annulable ».
// 1) points de restauration avant/après chaque écriture (fichier, événement, rappel, note) + annulation ;
// 2) carte de confirmation : l'agent attend la décision d'Ahadi (60 s max) au lieu de lui faire taper « oui » ;
// 3) politique par outil (réglage `tool_policy` : auto | ask | block). Les garde-fous durs (envoi, paiement, secrets) restent au-dessus.
// 4) VAGUE 1 (24/10) : couche Confiance (Feat_Trust) dans runGuarded — politique par type d'action, interdits fixes, Dots en lecture
//    seule ; elle ne fait que durcir (refus ou carte en plus) et compte chaque décision de carte au registre de fiabilité.
extension Tools {
    static let checkpointFile: JSONFile = JSONFile("checkpoints.json")
    static let ckLock: NSLock = NSLock()
    nonisolated(unsafe) static var pendingConfirms: [String: DispatchSemaphore] = [:]
    nonisolated(unsafe) static var confirmAnswers: [String: Bool] = [:]
    static let pcLock: NSLock = NSLock()
    /// Outils affichés dans Système › Réglages › « Ce que Nova peut faire ».
    static let policyTools: [String] = ["web_search", "web_fetch", "mail_unread", "mail_week", "teams_read", "calendar", "reminders", "read_file", "transcribe", "know", "recall", "remember", "system", "processes", "nova_self", "flux_titres", "brvm_cours", "notes", "contacts", "find", "clipboard", "today", "draft_reply", "write_file", "edit_file", "calendar_add", "reminder_add", "note_add", "cafu_format_document", "cafu_format_email", "cafu_format_docx", "cafu_format_deck", "cafu_format_pdf", "cafu_format_table", "forge_tool", "shortcut", "momo", "phone", "ui", "shell", "applescript", "open", "ask_assistant", "app", "media", "nova_ui", "formulaire"]

    /// Politique effective d'un outil : réglage `tool_policy`, sinon « auto » (sauf forge_tool : « ask »).
    static func policy(for tool: String) -> String {
        let d: [String: Any] = Settings().get("tool_policy", [String: Any]())
        let v: String = (d[tool] as? String) ?? ""
        if v == "auto" || v == "ask" || v == "block" { return v }
        return tool == "forge_tool" ? "ask" : "auto"
    }
    static func effectivePolicy() -> [String: String] {
        var out: [String: String] = [:]
        for t in policyTools { out[t] = policy(for: t) }
        return out
    }

    /// AUTONOMIE A2 (22/10) — outils LOCAUX et RÉVERSIBLES dont la confirmation « Demander »
    /// (politique « ask ») est LEVÉE quand le réglage `autorisation_totale` est actif :
    /// fichiers, brouillons, livrables, navigation, mémoire, lectures et ajouts locaux.
    /// La levée est appliquée dans Agent.runGuarded et journalisée au blackbox — jamais
    /// silencieuse. NE SONT JAMAIS LEVÉS ICI (exceptions explicites, liste fermée) :
    ///   • la politique « block » : un outil bloqué reste bloqué, drapeau ou non ;
    ///   • forge_tool (fabrique du code exécutable neuf), momo (paiement), phone,
    ///     ui (actions d'écran), shell / applescript / shortcut (commandes — régies par
    ///     la garde gate() de Tools+Security, qui a sa propre logique autorisation_totale
    ///     et ses refus durs : secrets, destructif, évasion d'envoi), app (administration
    ///     de Nova elle-même) ;
    ///   • les ENVOIS EXTERNES (mail, Teams, publications) ne passent de toute façon pas
    ///     par cette couche : leur carte d'approbation vit dans la file d'envoi
    ///     (Feat_SendQueue), qui ne consulte pas autorisation_totale — frontière
    ///     constitutionnelle de la maison (règle d'or n°2), hors de portée de ce drapeau.
    static let fullAutoLiftedTools: Set<String> = ["read_file", "write_file", "edit_file", "find",
        "draft_reply", "cafu_format_document", "cafu_format_email", "cafu_format_docx", "cafu_format_deck", "cafu_format_pdf", "cafu_format_table",
        "web_search", "web_fetch", "flux_titres", "brvm_cours", "open",
        "remember", "recall", "know", "notes", "note_add",
        "bibliotheque", "lire_fichier_bibliotheque",   // 31/10 (Algolia biblio)
        "calendar", "calendar_add", "reminders", "reminder_add", "contacts", "today", "system", "processes", "transcribe",
        "mail_unread", "mail_week", "mail_corps", "teams_read", "nova_self", "ask_assistant", "media", "nova_ui",
        // 27/10 (Ahadi : « JE VALIDE LE PLAN DE DEBLOCAGE COMPLET ») : pilotage complet du Mac et de
        // Nova sans fenêtre de confirmation — les refus DURS de gate() restent au-dessus de cette
        // levée : secrets interdits, rm catastrophique, et les envois externes gardent leur propre
        // carte d'approbation (Feat_SendQueue), que autorisation_totale ne contourne pas.
        "shell", "applescript", "app", "mail_brouillon", "skill"]

    // MARK: points de restauration

    /// Enregistre un point de restauration (200 au plus) et range son id sur le fil courant pour l'événement `step`.
    @discardableResult
    static func addCheckpoint(tool: String, path: String, eventId: String, backupPath: String, created: Bool) -> String {
        let id: String = String(UUID().uuidString.prefix(8)).lowercased()
        var e: [String: Any] = ["id": id, "ts": nowISO(), "tool": tool, "created": created]
        if !path.isEmpty { e["path"] = path }
        if !eventId.isEmpty { e["eventId"] = eventId }
        if !backupPath.isEmpty { e["backupPath"] = backupPath }
        ckLock.lock()
        var l: [[String: Any]] = checkpointFile.read(default: [[String: Any]]())
        l.append(e)
        if l.count > 200 { l.removeFirst(l.count - 200) }
        checkpointFile.write(l)
        ckLock.unlock()
        Thread.current.threadDictionary["nova.checkpoint"] = id
        return id
    }
    /// Lit puis efface l'id du dernier point de restauration créé sur ce fil.
    static func takeThreadCheckpoint() -> String? {
        let td: NSMutableDictionary = Thread.current.threadDictionary
        let v: String? = td["nova.checkpoint"] as? String
        td.removeObject(forKey: "nova.checkpoint")
        return v
    }
    static func lastCheckpoints(_ n: Int) -> [[String: Any]] {
        ckLock.lock(); defer { ckLock.unlock() }
        let l: [[String: Any]] = checkpointFile.read(default: [[String: Any]]())
        return Array(l.suffix(max(1, min(n, 200))).reversed())
    }
    static func markUndone(_ id: String) {
        ckLock.lock(); defer { ckLock.unlock() }
        var l: [[String: Any]] = checkpointFile.read(default: [[String: Any]]())
        if let i = l.firstIndex(where: { ($0["id"] as? String) == id }) { l[i]["undone"] = true; l[i]["undoneAt"] = nowISO(); checkpointFile.write(l) }
    }
    static func asQuoted(_ t: String) -> String { t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

    /// Annule un point de restauration. Fichier : version sauvegardée remise en place (la version actuelle est d'abord sauvegardée),
    /// ou fichier créé placé dans la Corbeille. Événement / rappel / note : suppression par identifiant.
    static func undoCheckpoint(_ id: String) -> (ok: Bool, message: String) {
        ckLock.lock()
        let l: [[String: Any]] = checkpointFile.read(default: [[String: Any]]())
        let found: [String: Any]? = l.first(where: { ($0["id"] as? String) == id })
        ckLock.unlock()
        guard let e = found else { return (false, "Point de restauration introuvable.") }
        if (e["undone"] as? Bool) == true { return (false, "Déjà annulé.") }
        let tool: String = (e["tool"] as? String) ?? ""
        let fm: FileManager = FileManager.default
        var ok: Bool = false
        var msg: String = "Rien à annuler."
        if tool == "write_file" || tool == "edit_file" {
            let p: String = (e["path"] as? String) ?? ""
            let b: String = (e["backupPath"] as? String) ?? ""
            let home: String = NSHomeDirectory()
            guard p.hasPrefix(home + "/") else { return (false, "Chemin hors du dossier personnel : annulation refusée.") }
            if !b.isEmpty && fm.fileExists(atPath: b) {
                if let cur = try? String(contentsOfFile: p, encoding: .utf8) {   // la version actuelle reste récupérable
                    let bdir: String = home + "/Library/Application Support/Nova/backups-fichiers"
                    let stamp: String = nowISO().replacingOccurrences(of: ":", with: "-")
                    try? cur.write(toFile: bdir + "/" + stamp + "__avant-annulation__" + (p as NSString).lastPathComponent, atomically: true, encoding: .utf8)
                }
                do {
                    let s: String = try String(contentsOfFile: b, encoding: .utf8)
                    try s.write(toFile: p, atomically: true, encoding: .utf8)
                    ok = true; msg = "Fichier restauré : " + p
                } catch { msg = "Restauration impossible : " + error.localizedDescription }
            } else if (e["created"] as? Bool) == true {
                if !fm.fileExists(atPath: p) { ok = true; msg = "Fichier déjà absent : " + p }
                else {
                    #if os(macOS)
                    do { try fm.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil); ok = true; msg = "Fichier créé placé dans la Corbeille : " + p }
                    catch { msg = "Mise à la Corbeille impossible : " + error.localizedDescription }
                    #else
                    msg = "Corbeille indisponible sur ce système."
                    #endif
                }
            } else { msg = "Sauvegarde introuvable : rien à restaurer pour " + p }
        } else if tool == "calendar_add" || tool == "reminder_add" || tool == "note_add" {
            let eid: String = asQuoted((e["eventId"] as? String) ?? "")
            guard !eid.isEmpty else { return (false, "Identifiant de l'élément inconnu : suppression impossible.") }
            var script: String = ""
            if tool == "calendar_add" {
                script = "tell application \"Calendar\"\nset n to 0\nrepeat with c in calendars\nset evs to (every event of c whose uid is \"" + eid + "\")\nrepeat with ev in evs\ndelete ev\nset n to n + 1\nend repeat\nend repeat\nreturn n as text\nend tell"
            } else if tool == "reminder_add" {
                script = "tell application \"Reminders\"\ndelete (every reminder whose id is \"" + eid + "\")\nreturn \"1\"\nend tell"
            } else {
                script = "tell application \"Notes\"\ndelete note id \"" + eid + "\"\nreturn \"1\"\nend tell"
            }
            let r: (ok: Bool, out: String) = Tools.osa(script, timeout: 30)
            let label: String = tool == "calendar_add" ? "Événement" : (tool == "reminder_add" ? "Rappel" : "Note")
            if r.ok { ok = true; msg = label + " supprimé." } else { msg = "Suppression impossible : " + String(r.out.prefix(200)) }
        } else { msg = "Outil non annulable : " + tool }
        if ok { markUndone(id) }
        let rec: [String: Any] = ["tool": "checkpoint_undo", "actor": "Ahadi", "why": "annulation " + tool, "ok": ok, "effect": ok ? "annulé" : "aucun", "input": id]
        _ = BlackBox.record(rec)
        return (ok, msg)
    }

    // MARK: confirmations en ligne

    /// Aperçu affiché sur la carte de confirmation (edit_file : ancien / nouveau, 400 caractères chacun).
    static func confirmPreview(_ tool: String, _ arg: String) -> String {
        guard tool == "edit_file" || tool == "write_file",
              let d = arg.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return String(arg.prefix(400)) }
        let p: String = (j["path"] as? String) ?? ""
        if tool == "edit_file" {
            let o: String = String(((j["old"] as? String) ?? "").prefix(400))
            let n: String = String(((j["new"] as? String) ?? "").prefix(400))
            return "Fichier : " + p + "\n\nAVANT :\n" + o + "\n\nAPRÈS :\n" + n
        }
        let c: String = String(((j["content"] as? String) ?? "").prefix(400))
        return "Fichier : " + p + "\n\nCONTENU :\n" + c
    }
    /// Demande liée à la politique « ask » : inscrite comme les autres pour que /api/confirm (Tools.decide) la reconnaisse.
    /// VAGUE 1 (Confiance) : `kind` facultatif — libellé de la carte quand c'est la politique de confiance qui la demande.
    static func registerAsk(_ tool: String, _ arg: String, kind: String? = nil) -> (id: String, cmd: String) {
        let n: String = String(UUID().uuidString.prefix(6)).lowercased()
        let cmd: String = "outil " + tool + " : " + String(arg.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        let label: String = kind ?? ("utilisation de l'outil « " + tool + " » (réglage : Demander)")
        let e: [String: Any] = ["id": n, "cmd": cmd, "kind": label, "ts": nowISO()]
        apLock.lock(); pendingConfirm[n] = e; apLock.unlock()
        confirmHook?(e)
        return (n, cmd)
    }
    static func pendingCmd(_ id: String) -> String {
        apLock.lock(); defer { apLock.unlock() }
        return (pendingConfirm[id]?["cmd"] as? String) ?? ""
    }
    static func dropPending(_ id: String) { apLock.lock(); pendingConfirm.removeValue(forKey: id); apLock.unlock() }
    /// Lit puis efface l'id de la dernière confirmation demandée sur ce fil (posé par needConfirm).
    static func takeThreadConfirm() -> String? {
        let td: NSMutableDictionary = Thread.current.threadDictionary
        let v: String? = td["nova.confirm"] as? String
        td.removeObject(forKey: "nova.confirm")
        return v
    }
    /// Attend la décision (60 s au plus, `cancel` respecté). `announce` est appelé une fois l'attente inscrite. true = autorisé.
    static func waitConfirm(_ id: String, cancel: () -> Bool, announce: () -> Void) -> Bool {
        return waitConfirmDetailed(id, cancel: cancel, announce: announce).ok
    }
    /// VAGUE 1 (Confiance) : comme waitConfirm, mais distingue « sans réponse » (answered = false) d'un refus —
    /// le registre de fiabilité ne compte un refus que s'il vient d'Ahadi.
    static func waitConfirmDetailed(_ id: String, cancel: () -> Bool, announce: () -> Void) -> (answered: Bool, ok: Bool) {
        let sem: DispatchSemaphore = DispatchSemaphore(value: 0)
        pcLock.lock(); pendingConfirms[id] = sem; pcLock.unlock()
        announce()
        var answered: Bool = false
        for _ in 0..<120 {
            if sem.wait(timeout: .now() + 0.5) == .success { answered = true; break }
            if cancel() { break }
        }
        pcLock.lock()
        pendingConfirms.removeValue(forKey: id)
        let ans: Bool = confirmAnswers.removeValue(forKey: id) ?? false
        pcLock.unlock()
        return (answered, answered && ans)
    }
    /// Appelé par Tools.decide (POST /api/confirm) : libère l'agent en attente.
    static func signalConfirm(_ id: String, ok: Bool) {
        pcLock.lock()
        let sem: DispatchSemaphore? = pendingConfirms[id]
        if sem != nil { confirmAnswers[id] = ok }
        pcLock.unlock()
        sem?.signal()
    }
}

extension Agent {
    static let refusedMsg: String = "refusé par Ahadi (ou sans réponse sous 60 s) : l'action n'a PAS été exécutée. N'insiste pas et ne relance pas le même appel ; propose une autre voie ou dis-lui ce qui reste à faire."
    /// Exécute un outil sous la politique par outil, avec carte de confirmation en ligne si l'outil le demande.
    /// DIAG2-FLUX P3 : stepId/stepIndex/argShort identifient l'étape « run » déjà émise par l'appelant — le battement
    /// la réémet en « run » avec un compteur « beat » (secondes écoulées) que le web affiche sur la même ligne.
    func runGuarded(_ name: String, _ arg: String, why: String, actor: String, stepId: String = "", stepIndex: Int = 0, argShort: String = "", cancel: @escaping () -> Bool, onEvent: @escaping (BrainEvent) -> Void) -> String {
        let pol: String = Tools.policy(for: name)
        if pol == "block" { return "Outil « " + name + " » bloqué par réglage (Système › Ce que Nova peut faire)." }
        // VAGUE 1 — CONFIANCE GRADUÉE (Feat_Trust) : politique par TYPE D'ACTION, interdits fixes, lecture seule
        // des Dots. Elle ne fait que DURCIR : « refuse » arrête ici, « ask » ajoute une carte (jamais levée par
        // autorisation_totale) ; « run » laisse intactes toutes les gardes qui suivent (tool_policy, gate, Permis).
        let tv: Trust.Verdict = Trust.verdict(tool: name, arg: arg, actor: actor, why: why)
        if tv.action == "refuse" {
            _ = BlackBox.record(["tool": name, "actor": actor, "why": "CONFIANCE : refus — " + tv.reason, "input": Knowledge.redact(String(arg.prefix(160))), "ok": false, "effect": "refusé"])
            return tv.message
        }
        let trustAsk: Bool = tv.action == "ask"
        // AUTONOMIE A2 (22/10) : la levée « ask » sous autorisation_totale (voir
        // Tools.fullAutoLiftedTools pour le périmètre et les exceptions codées).
        let askLifted: Bool = pol == "ask" && !trustAsk && Tools.fullAuto() && Tools.fullAutoLiftedTools.contains(name)
        if askLifted { _ = BlackBox.record(["tool": name, "actor": actor, "why": "A2 : confirmation « Demander » levée par autorisation_totale (action locale et réversible)", "ok": true, "effect": "confirmation levée"]) }
        let preview: String = Tools.confirmPreview(name, arg)
        let argShown: String = String(arg.prefix(400))
        if (pol == "ask" && !askLifted) || trustAsk {
            let reg: (id: String, cmd: String) = Tools.registerAsk(name, arg, kind: trustAsk ? tv.cardKind : nil)
            var info: [String: Any] = ["id": reg.id, "tool": name, "arg": argShown, "preview": preview, "cmd": reg.cmd, "reason": trustAsk ? "confiance" : "politique"]
            if trustAsk { info["trust"] = ["category": tv.category, "level": tv.level, "why": tv.reason, "label": tv.cardKind] }
            let cardInfo: [String: Any] = info
            let dec: (answered: Bool, ok: Bool) = Tools.waitConfirmDetailed(reg.id, cancel: cancel, announce: { onEvent(.step(kind: "confirm", info: cardInfo)) })
            let ok: Bool = dec.ok
            Tools.dropPending(reg.id)
            Trust.recordCard(category: tv.category, answered: dec.answered, ok: dec.ok, tool: name, source: trustAsk ? "carte confiance" : "carte politique")
            let doneInfo: [String: Any] = ["id": reg.id, "tool": name, "resolved": true, "ok": ok]
            onEvent(.step(kind: "confirm", info: doneInfo))
            if !ok { return "Outil « " + name + " » " + Agent.refusedMsg }
        }
        _ = Tools.takeThreadConfirm()
        // DIAG2-FLUX P3 : battement d'étape pendant l'exécution — un outil long (calendar 2 × 120 s, mail 170 s)
        // ne gèle plus le run en silence : toutes les 20 s, l'étape ouverte est réémise avec « beat » (secondes
        // écoulées). Le minuteur vit sur sa propre file et meurt avec le retour de l'outil ; aucun délai interne
        // d'outil n'est modifié (l'anti-gel est la VISIBILITÉ + la conclusion d'étape, pas une coupure sauvage).
        func beatRun() -> String {
            let t0 = Date()
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "nova.tool.heartbeat", qos: .utility))
            if !stepId.isEmpty {
                timer.schedule(deadline: .now() + 20, repeating: 20)
                timer.setEventHandler {
                    onEvent(.step(kind: "step", info: ["id": stepId, "index": stepIndex, "tool": name, "arg": argShort, "state": "run", "beat": Int(Date().timeIntervalSince(t0))]))
                }
                timer.resume()
            }
            let r = tools.run(name, arg, why: why, actor: actor)
            timer.cancel()
            return r
        }
        var out: String = beatRun()
        if out.hasPrefix("CONFIRMATION REQUISE"), let cid = Tools.takeThreadConfirm() {
            let cmd: String = Tools.pendingCmd(cid)
            let info: [String: Any] = ["id": cid, "tool": name, "arg": argShown, "preview": preview, "cmd": cmd, "reason": "garde-fou"]
            let dec: (answered: Bool, ok: Bool) = Tools.waitConfirmDetailed(cid, cancel: cancel, announce: { onEvent(.step(kind: "confirm", info: info)) })
            let ok: Bool = dec.ok
            Trust.recordCard(category: tv.category, answered: dec.answered, ok: dec.ok, tool: name, source: "carte garde-fou")   // VAGUE 1 : décision réelle comptée au registre de fiabilité
            let doneInfo: [String: Any] = ["id": cid, "tool": name, "resolved": true, "ok": ok]
            onEvent(.step(kind: "confirm", info: doneInfo))
            // autorisé : Tools.decide a inscrit la commande comme approuvée ; on rappelle l'outil avec EXACTEMENT le même argument (mécanisme existant, « CONFIRMÉ: » n'autorise rien)
            if ok { out = beatRun() }   // DIAG2-FLUX P3 : la ré-exécution post-confirmation est battue elle aussi
            else { Tools.dropPending(cid); out = "Action « " + name + " » " + Agent.refusedMsg }
        }
        if name == "draft_reply" || name == "cafu_format_email" { Trust.kick() }   // VAGUE 1 : le relecteur lit le nouveau brouillon sans attendre sa veille de 5 s
        return out
    }
}

extension NovaApp {
    func checkpointRoutes() {
        let s: HTTPServer = server
        s.on("GET", "/api/checkpoints") { req, res in
            let n: Int = Int(req.query["last"] ?? "") ?? 10
            let items: [[String: Any]] = Tools.lastCheckpoints(n)
            let body: [String: Any] = ["items": items]
            res.json(body)
        }
        s.on("POST", "/api/checkpoints/undo") { req, res in
            let id: String = (req.json["id"] as? String) ?? ""
            guard !id.isEmpty else { let bad: [String: Any] = ["ok": false, "message": "id requis"]; res.json(bad, status: 400); return }
            let r: (ok: Bool, message: String) = Tools.undoCheckpoint(id)
            let body: [String: Any] = ["ok": r.ok, "message": r.message]
            res.json(body)
        }
        s.on("GET", "/api/tool_policy") { _, res in
            let body: [String: Any] = ["tools": Tools.policyTools, "policy": Tools.effectivePolicy()]
            res.json(body)
        }
        forgeUIRoutes()   // V5-G : /api/forge/recheck et /api/forge/retire (Forge.swift) — branchées ici, App.swift reste intact
        // POST /api/confirm existe déjà (App.swift → Tools.decide) : Tools.decide libère désormais aussi l'agent en attente (signalConfirm).
    }
}
