import Foundation

/// Accès COMPLET de l'assistant à Nova lui-même (outil « app ») : tout ce que Nova contient est lisible, presque tout est administrable.
/// Lecture : état global, chaque Dot (état, horaire, prochain passage, dernières exécutions), réglages, cerveaux IA, briefs, Boîte noire, permis.
/// Écriture : réglages (liste noire : clés, jeton, pont téléphone, dossiers), Dots (horaire, cerveau, pause, consigne), lancement, briefs.
/// Jamais : mots de passe, clés API, envoi de mails/messages, paiements — ceux-là restent à l'utilisateur.
extension NovaApp {
    static let secretWords = ["key", "token", "secret", "password", "passwd", "cle", "clé", "bridge", "knowledge_roots", "ui_prefs"]
    static func isSecretSetting(_ k: String) -> Bool { let l = k.lowercased(); return secretWords.contains { l.contains($0) } }
    /// AUDIT-24/10: P0 — réglages RÉSERVÉS À AHADI : l'assistant (chat, Conseil, relais, appui d'un Dot) ne peut jamais les modifier
    /// par `app set` ni `nova_self set` (auto-élévation : autorisation_totale lève les confirmations ; brains_lock / brain / dots_brain = politique verrouillée).
    /// Seul l'écran Réglages (route web de l'interface) les change.
    public static let ownerOnlySettings: Set<String> = ["autorisation_totale", "brains_lock", "brain", "dots_brain", "brains_off", "tool_policy", "souverain", "bridge_enabled", "demo_mode", "demo_brain",
                                                       "mcp_serveurs", "dots_shell_sans_surveillance"]   // WP5 : commande d'un serveur MCP = exécution ; shell des Dots planifiés = opt-in d'Ahadi seul
    static func isOwnerOnlySetting(_ k: String) -> Bool { ownerOnlySettings.contains(k.trimmingCharacters(in: .whitespaces).lowercased()) }

    static func fmtDate(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "EEE d MMM HH:mm"; f.locale = Locale(identifier: "fr_FR"); return f.string(from: d) }

    /// Prochain créneau planifié d'un horaire (« lun-ven 08:00,12:30 »), cherché sur 8 jours.
    func nextSlot(_ schedule: String, from now: Date = Date()) -> Date? {
        let cal = Calendar.current
        for off in 0...8 {
            guard let day = cal.date(byAdding: .day, value: off, to: now) else { continue }
            for s in DotScheduler.slots(schedule, now: day).sorted() {
                let p = s.split(separator: ":"); guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { continue }
                if let t = cal.date(bySettingHour: h, minute: m, second: 0, of: day), t > now { return t }
            }
        }
        return nil
    }

    func dotLine(_ d: [String: Any], active: Set<String>) -> String {
        let id = d["id"] as? String ?? "?"
        let last = dots.history(id).first
        let sched = d["schedule"] as? String ?? ""
        let paused = (d["paused"] as? Bool) == true
        var etat = active.contains(id) ? "EN COURS" : (paused ? "EN PAUSE" : (sched.isEmpty ? "manuel" : "planifié"))
        if !settings.get("dots_auto", true) && !paused && !sched.isEmpty { etat += " (planification globale coupée)" }
        let next = paused ? "—" : (nextSlot(sched).map { NovaApp.fmtDate($0) } ?? "aucun")
        var l = "• \(id) · \(d["name"] ?? "") · \(etat) · horaire « \(sched.isEmpty ? "aucun" : sched) » · prochain : \(next) · cerveau : \(d["brain"] ?? "auto") · \(((d["tools"] as? [String]) ?? []).count) outils"
        if let r = last { l += " · dernier : \((r["ts"] as? String) ?? "?") \((r["ok"] as? Bool) == true ? "réussi" : "ÉCHEC") (\(((r["ms"] as? Int) ?? 0) / 1000) s)" } else { l += " · jamais exécuté" }
        return l
    }

    /// Retourne nil si la commande n'est pas une commande d'administration (le crochet d'origine continue alors).
    /// CHANTIER 2 (26/10) : cas « status » extrait d'adminCommand (880 ms de type-check) —
    /// extraction mecanique, comportement inchange.
    func adminStatus(active: Set<String>) -> String {
            let all = dots.list()
            let planifies = all.filter { !(($0["schedule"] as? String) ?? "").isEmpty && ($0["paused"] as? Bool) != true }.count
            let pauses = all.filter { ($0["paused"] as? Bool) == true }.count
            var o = ["Nova \(NovaApp.version) — état au \(nowISO())"]
            o.append("Dots : \(all.count) au total · \(planifies) planifiés · \(pauses) en pause · \(active.count) en cours\(active.isEmpty ? "" : " (" + active.sorted().joined(separator: ", ") + ")")")
            o.append("Planification automatique : \(settings.get("dots_auto", true) ? "active" : "COUPÉE") · heures calmes : \(briefs.inQuietHours() ? "oui (silence)" : "non") · plafond d'interruptions/jour : \(settings.get("dots_plafond", 6))")
            o.append("Résultats en attente d'ouverture : \(scheduler.waiting().count)")
            let hs = router.healthSnapshot()
            o.append("Cerveaux IA : " + hs.map { "\($0["label"] ?? $0["id"] ?? "?"): \($0["state"] ?? $0["status"] ?? "?")" }.joined(separator: " · "))
            let bb = BlackBox.verify(); o.append("Boîte noire : \((bb["ok"] as? Bool) == true ? "chaîne intacte" : "ALTÉRÉE") (\(bb["count"] ?? 0) actions) · permis actifs : \(Permits.list().count)")
            let sv = router.sovereignStatus(); o.append("Souverain d'abord : \(sv["enabled"] ?? sv["actif"] ?? "?")")
            o.append("Commandes détaillées : dots · dot-info <id> · runs [id] · settings · cerveaux · attente · briefs · boite · permis · memoire · actions · dot-set <id> <champ> <valeur> (réécrire role/prompt/name sur ordre du Capitaine : texte précis ≥ 40 car., ancienne version gardée) · dot-supprimer <id> confirme (sur ordre, corbeille) · dot-pause <id> · dot-reprendre <id> · set <réglage> <valeur> · dot <id> [consigne] · brief <type> · go <onglet>")
            return o.joined(separator: "\n")
    }
    func adminFindDot(_ q: String) -> [String: Any]? { dots.list().first { ($0["id"] as? String) == q || ($0["name"] as? String)?.lowercased() == q.lowercased() } }

    /// CHANTIER 2 (suite) : cas de lecture extraits d'adminCommand — mécanique, comportement inchangé.
    /// CHANTIER 2 (suite) : cas système extraits d'adminRead — mécanique.
    func adminReadSys(_ verb: String, _ p: [String]) -> String? {
        switch verb {
        case "attente":
            let w = scheduler.waiting(); return w.isEmpty ? "Aucun Dot en attente d'ouverture." : w.map { "• \($0["dot"] ?? "") · \($0["ts"] ?? "")" }.joined(separator: "\n")
        case "briefs":
            let b = settings.get("briefs", [[String: Any]]()); return b.isEmpty ? "Aucun brief configuré." : b.map { "• \($0["kind"] ?? "") · \($0["label"] ?? "") · \($0["time"] ?? $0["at"] ?? "") · \(($0["on"] as? Bool) == false ? "désactivé" : "actif")" }.joined(separator: "\n")
        case "boite", "boîte":
            let v = BlackBox.verify(); var o = ["Chaîne : \((v["ok"] as? Bool) == true ? "intacte" : "ALTÉRÉE") · \(v["count"] ?? 0) actions"]
            for e in BlackBox.tail(8) { o.append("• #\(e["seq"] ?? "") \(e["ts"] ?? "") \(e["tool"] ?? "") (\(e["actor"] ?? "")) \(String("\(e["why"] ?? "")".prefix(80)))") }
            return o.joined(separator: "\n")
        case "permis":
            let l = Permits.list(); return l.isEmpty ? "Aucun permis d'agir défini." : l.map { "• \($0["id"] ?? "") · \($0["text"] ?? $0["rule"] ?? "") · \(($0["on"] as? Bool) == false ? "désactivé" : "actif")" }.joined(separator: "\n")
        case "memoire", "mémoire":
            let m = tools.memory.list(); return "\(m.count) faits en mémoire. Derniers : " + m.suffix(10).map { String("\($0["text"] ?? $0["fact"] ?? "")".prefix(90)) }.joined(separator: " | ")
        case "actions":
            return Tools.actions.tail(12).map { "• \($0["ts"] ?? "") \($0["tool"] ?? "") (\($0["actor"] ?? "")) \(($0["ok"] as? Bool) == true ? "OK" : "échec")" }.joined(separator: "\n")        default: return nil
        }
    }

    func adminRead(_ verb: String, _ p: [String], active: Set<String>) -> String? {
        switch verb {
        case "dots":
            return dots.list().map { dotLine($0, active: active) }.joined(separator: "\n")
        case "dot-info", "info":
            guard p.count > 1, let d = adminFindDot(p[1]) else { return "dot-info <id> — Dots : " + dots.list().compactMap { $0["id"] as? String }.joined(separator: ", ") }
            let id = d["id"] as? String ?? ""
            var o = [dotLine(d, active: active), "Rôle : \(d["role"] ?? "")", "Consigne : \(String("\(d["prompt"] ?? "")".prefix(600)))", "Outils : \(((d["tools"] as? [String]) ?? []).joined(separator: ", "))"]
            for r in dots.history(id).prefix(3) { o.append("— \((r["ts"] as? String) ?? "") \((r["ok"] as? Bool) == true ? "OK" : "ÉCHEC") : \(String("\(r["result"] ?? "")".replacingOccurrences(of: "\n", with: " ").prefix(300)))") }
            return o.joined(separator: "\n")
        case "runs", "historique":
            let id = p.count > 1 ? adminFindDot(p[1])?["id"] as? String : nil
            let h = dots.history(id).prefix(12)
            return h.isEmpty ? "Aucune exécution enregistrée." : h.map { "• \($0["ts"] ?? "") · \($0["dot"] ?? "") · \(($0["ok"] as? Bool) == true ? "OK" : "ÉCHEC") · \(($0["brain"] as? String) ?? "") · \(String("\($0["result"] ?? "")".replacingOccurrences(of: "\n", with: " ").prefix(160)))" }.joined(separator: "\n")
        case "settings", "reglages", "réglages":
            let a = settings.all().filter { !NovaApp.isSecretSetting($0.key) }.sorted { $0.key < $1.key }
            return a.map { "\($0.key) = \(String("\($0.value)".prefix(120)))" }.joined(separator: "\n") + "\n(clés, jeton, pont téléphone et dossiers suivis masqués : réservés à l'utilisateur)"
        case "cerveaux", "brains":
            return router.healthSnapshot().map { "• " + $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " · ") }.joined(separator: "\n")
        default: return nil
        }
    }
    func adminCommand(_ cmd: String) -> String? {
        let p = cmd.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
        guard let verb = p.first?.lowercased() else { return nil }
        let active = Set(scheduler.activeIds())
        if let r = adminRead(verb, p, active: active) { return r }
        if let r = adminReadSys(verb, p) { return r }
        switch verb {
        case "status", "etat", "état":
            return adminStatus(active: active)
        case "set":
            guard p.count > 2 else { return "set <réglage> <valeur>" }
            // PILOTAGE 01/11 : mêmes refus (secrets, réservés à Ahadi — AUDIT-24/10, pas d'auto-élévation), puis valeur convertie au type réel,
            // écrite, RELUE sur disque et appliquée à la fenêtre (Pilotage.swift). Avant : « Réglage x = y » sans relecture.
            return NovaPilot.setSetting(p[1], p.dropFirst(2).joined(separator: " "), settings: settings, actor: "Assistant", tool: "app")
        case "dot-pause", "dot-reprendre":
            guard p.count > 1, var d = adminFindDot(p[1]) else { return "\(verb) <id>" }
            d.removeValue(forKey: "persona"); d["paused"] = (verb == "dot-pause"); dots.save(d)
            return "Dot « \(d["name"] ?? "") » \(verb == "dot-pause" ? "mis en pause (plus aucune exécution planifiée ; lancement manuel possible)" : "repris").\n" + dotLine(d, active: active)
        case "dot-supprimer", "dot-delete":
            guard p.count > 1, let d = adminFindDot(p[1]) else { return "dot-supprimer <id> confirme — Dots : " + dots.list().compactMap { $0["id"] as? String }.joined(separator: ", ") }
            guard p.last?.lowercased() == "confirme" else { return "Suppression de « \(d["name"] ?? "") » : à n'exécuter que sur ordre explicite du Capitaine. Relance « dot-supprimer \(p[1]) confirme ». Une copie est gardée dans dots_corbeille (restaurable)." }
            var bin = settings.get("dots_corbeille", [[String: Any]]())
            bin.append(d); settings.set(["dots_corbeille": Array(bin.suffix(30))])
            dots.remove(p[1])
            _ = BlackBox.record(["tool": "app", "actor": "Assistant", "why": "dot-supprimer \(p[1])", "ok": true, "effect": "supprimé (corbeille)"])
            return "Dot « \(d["name"] ?? "") » supprimé (copie en corbeille)."
        case "dot-set":
            guard p.count > 3, var d = adminFindDot(p[1]) else { return "dot-set <id> <schedule|brain|role|prompt|name> <valeur>" }
            let field = p[2].lowercased(), val = p[3]
            guard ["schedule", "brain", "role", "prompt", "name", "emoji", "quiet_ok"].contains(field) else { return "Champ « \(field) » non modifiable ici (schedule, brain, role, prompt, name, emoji, quiet_ok)." }
            if field == "brain", !["auto", "deep", "bulk"].contains(val), router.spec(val) == nil { return "brain : auto | deep | bulk | id d'un cerveau du catalogue (ex. spark-1.3, wonder-1.0)" }   // AUDIT-24/10: un id de cerveau est accepté et honoré par Dots.run
            if DotCharter.lockedFields.contains(field), DotCharter.isLocked(id: d["id"] as? String ?? "", settings: settings) {
                // Réécriture autorisée sur ORDRE du Capitaine, avec garde-fous : texte précis, ancienne version sauvegardée, contrat de mission conservé.
                if field != "name", val.count < 40 { return "Réécriture refusée : un rôle/une consigne doit être précis (≥ 40 caractères) : mission, livrable attendu, critère de succès, que faire en cas d'échec. Reformule puis relance dot-set. (Le contrat de mission STATUT/sources/« À TOI » est ajouté automatiquement.) N'utilise ceci que sur ordre explicite du Capitaine." }
                d["prev_\(field)"] = d[field] ?? ""
            }
            if field == "schedule", !val.isEmpty, val != "aucun", DotScheduler.slots(val, now: Date()).isEmpty, val.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) == nil { return "Horaire invalide. Exemples : « 08:00 », « lun-ven 08:00,12:30 »." }
            d.removeValue(forKey: "persona")
            d[field] = field == "quiet_ok" ? (val == "true") : (field == "schedule" && val == "aucun" ? "" : val)
            dots.save(d)
            _ = BlackBox.record(["tool": "app", "actor": "Assistant", "why": "dot-set \(p[1]) \(field)", "ok": true, "effect": "écrit"])
            return "Dot « \(d["name"] ?? "") » : \(field) modifié.\n" + dotLine(d, active: active)
        default: return orchestre(verb, cmd, active: active)
        }
    }
}
