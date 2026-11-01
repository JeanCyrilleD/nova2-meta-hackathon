import Foundation

/// PILOTAGE DE L'INTERFACE ET RELAIS D'ARRIÈRE-PLAN (outil « app », réservé à l'assistant principal).
/// - Pont : chaque ordre d'interface part en événement SSE « ui » vers la fenêtre de Nova, qui exécute et renvoie un constat RÉEL (POST /api/ui/result).
///   Aucune réponse = « injoignable » : l'assistant ne dit jamais « fait » sans preuve.
/// - Navigateur : mêmes gestes sur la page ouverte dans un volet web de Nova (page-aller / page-lire / page-clic / page-saisir).
/// - Relais : un objectif confié à l'assistant continue en arrière-plan (plusieurs tours, journal, arrêt possible) pendant que l'utilisateur fait autre chose ;
///   il revient quand c'est terminé ou quand une décision humaine est nécessaire. Garde-fous inchangés : jamais d'envoi de message, de paiement, de mot de passe ni de clé.
public final class UIPilot: @unchecked Sendable {
    public static let shared = UIPilot()
    private let lock = NSLock()
    private var waits: [String: (DispatchSemaphore, [String: Any]?)] = [:]
    nonisolated(unsafe) public static var publish: ((String, Any) -> Void)? = nil

    /// PRO-4 : ops qui MODIFIENT l'interface — pour elles, ok:true sans champ « effet » (relecture par la fenêtre)
    /// ne vaut pas exécution. `page` est jugée sur son sous-ordre (args["sub"]).
    static func exigeEffet(_ op: String, _ args: [String: Any]) -> Bool {
        if op == "clic" || op == "saisir" { return true }
        if op == "page" { return ["clic", "saisir", "aller", "absence"].contains((args["sub"] as? String) ?? "") }
        return false
    }
    func request(_ op: String, _ args: [String: Any], timeout: TimeInterval = 12) -> [String: Any]? {
        let id = String(UUID().uuidString.prefix(10)).lowercased(); let sem = DispatchSemaphore(value: 0)
        lock.lock(); waits[id] = (sem, nil); lock.unlock()
        var m = args; m["id"] = id; m["op"] = op
        UIPilot.publish?("ui", m)
        _ = sem.wait(timeout: .now() + timeout)
        lock.lock(); var r = waits.removeValue(forKey: id)?.1; lock.unlock()
        // PRO-4 : ordre modifiant sans preuve d'effet → un aller-retour de vérification (« etat ») est joint au constat.
        if var rr = r, (rr["ok"] as? Bool) == true, UIPilot.exigeEffet(op, args), rr["effet"] == nil {
            if let v = request(op == "page" ? "page" : "etat", op == "page" ? ["pane": args["pane"] ?? "navigateur", "sub": "etat"] : [:], timeout: 8) {
                rr["verification_etat"] = v; r = rr
            }
        }
        return r
    }
    /// LOT2 P-E1b : retourne false si aucun ordre n'attend ce constat (id inconnu ou expiré) — l'appelant répond alors une erreur explicite au lieu d'un faux ok.
    @discardableResult
    public func deliver(_ id: String, _ r: [String: Any]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var w = waits[id] else { return false }
        w.1 = r; waits[id] = w; w.0.signal(); return true
    }
    static func render(_ r: [String: Any]?) -> String {
        guard let r = r else { return "INJOIGNABLE : la fenêtre de Nova2 n'a pas répondu (fermée, en veille ou en rechargement). Rien n'est prouvé : ne dis pas que c'est fait. Relance exactement ce paquet — \(Bundle.main.bundlePath) — jamais une app nommée « Nova », puis réessaie." }
        guard let d = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]), let s = String(data: d, encoding: .utf8) else { return "Réponse illisible." }
        let ok = (r["ok"] as? Bool) == true
        if !ok { return "ÉCHEC (réel) : " + String(s.prefix(3800)) }
        // PRO-4 : trois niveaux de vérité, jamais confondus dans le libellé rendu à l'agent.
        if r["effet"] != nil { return "CONSTAT VÉRIFIÉ (effet relu par la fenêtre) : " + String(s.prefix(3800)) }
        if r["verification_etat"] != nil { return "CONSTAT (reçu, effet non relu directement — état joint) : " + String(s.prefix(3800)) }
        return "CONSTAT (réel) : " + String(s.prefix(3800))
    }
    /// VÉRITÉ-MAGASIN (23/10) : un échec de volet mail (Outlook/Gmail)
    /// n'est PAS un échec de lecture du message — le pipeline Direct a pu
    /// lire le corps par le pont Mail.app et le persister
    /// (webmail_bodies.json) pendant que le volet échouait (cas Plan
    /// International, 23/10 : corps lu 10:53, « analyse impossible »
    /// déclaré à 11:21 après 3 clics ratés). Tout échec page-* sur un
    /// volet mail rappelle donc la voie du magasin AVANT toute
    /// conclusion de l'acteur.
    /// VÉRITÉ-2 (E4, 23/10) : le lot 1 ne couvrait que les échecs PORTÉS
    /// par un volet mail nommé (@gmail/@outlook dans l'appel). Un échec
    /// NON porté — verbe de lecture de message sans @, donc pane resté
    /// « navigateur » — restait nu (scénario point 4 : seq 12074 et
    /// 12077 sans bloc, seq 12081 porté avec bloc). La couverture suit
    /// donc le CONTEXTE, pas le seul libellé du volet : volet mail nommé
    /// (tout verbe page-*) OU verbe de lecture de message (les sites
    /// d'appel passent message: true). Jamais de double bloc.
    static func renderPage(_ r: [String: Any]?, pane: String, message: Bool = false) -> String {
        let s = render(r)
        guard (r?["ok"] as? Bool) != true else { return s }
        guard pane == "outlook" || pane == "gmail" || message else { return s }
        guard !s.contains("VÉRITÉ-MAGASIN :") else { return s }
        return s + "\n\nVÉRITÉ-MAGASIN : cet échec est celui du VOLET web, pas du magasin de Nova. Avant toute phrase sur ce mail, appelle mail_corps (expéditeur et/ou objet) : si le pipeline Direct a déjà lu le corps par le pont, il est servi depuis le magasin ; sinon mail_corps rapporte l'état réel de la récupération. Ne conclus JAMAIS « corps inaccessible » depuis un volet."
    }
}

extension NovaApp {
    public static let pilotVerbs: Set<String> = ["go", "onglet", "onglets", "ui-etat", "ui-lire", "ui-clic", "ui-saisir", "ui-touche", "ui-defiler",
                                                 "page-aller", "page-etat", "page-lire", "page-messages", "page-clic", "page-saisir", "page-touche", "page-absence", "media-radio", "media-stop", "media-etat", "media-volume",
                                                 "relais", "relais-liste", "relais-etat", "relais-stop",
                                                 "ax-lire", "ax-chercher", "ax-cliquer", "ax-saisir", "ax-menu"]   // VAGUE 3 : pilotage des apps du Mac en arrière-plan par l'Accessibilité (AXPilot.swift)
    static var relaisFile: JSONFile { JSONFile("relais.json") }
    static let relaisLock = NSLock()
    nonisolated(unsafe) static var relaisStopped: Set<String> = []   // PHASE 1 (relu, protégé) : sous NovaApp.relaisLock

    /// CHANTIER 2 (26/10, 3e passe) : verbes page-* extraits de pilotage (784 ms) — mecanique.
    func pilotagePage(_ verb: String, _ arg: String, _ pane: String, _ parg: String, _ raw: String) -> String? {
        func log(_ why: String) { _ = BlackBox.record(["tool": "app", "actor": "Assistant", "why": why, "ok": true, "effect": "interface"]) }
        func call(_ op: String, _ a: [String: Any] = [:], timeout: TimeInterval = 12) -> [String: Any]? { UIPilot.shared.request(op, a, timeout: timeout) }
        func parts() -> [String] { parg.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) } }
        _ = log; _ = parts
        switch verb {
        case "page-aller":
            guard let u = URL(string: parg.contains("://") ? parg : "https://" + parg), ["http", "https"].contains(u.scheme ?? ""), u.host != nil else { return "page-aller <adresse http(s)>" }
            log("page-aller " + u.host!)
            // Arrière-plan par défaut : le volet est piloté hors écran. Il n'est affiché que si Ahadi l'a demandé explicitement (« devant moi »).
            let devant: Bool = Tools.frontAllowed
            return UIPilot.renderPage(call("page", ["pane": pane, "sub": "aller", "url": u.absoluteString, "devant": devant], timeout: 25), pane: pane)
        case "page-etat": return UIPilot.renderPage(call("page", ["pane": pane, "sub": "etat"], timeout: 15), pane: pane)
        case "page-lire": return UIPilot.renderPage(call("page", ["pane": pane, "sub": "lire", "q": parg], timeout: 40), pane: pane, message: true)
        case "page-absence":   // Outlook : réponses automatiques (absence) on/off, hors écran. Ex. : page-absence @outlook off
            log("page-absence " + parg)
            let urlAbs: String = "https://outlook.office.com/mail/options/automaticReplies"
            _ = call("page", ["pane": pane, "sub": "aller", "url": urlAbs, "devant": false], timeout: 40)
            var last: [String: Any]? = nil
            for _ in 0..<5 {   // la page des options se construit après le chargement : on réessaie jusqu'à 5 × 3 s
                last = call("page", ["pane": pane, "sub": "absence", "value": parg.isEmpty ? "off" : parg], timeout: 30)
                if let ok = last?["ok"] as? Bool, ok { break }
                Thread.sleep(forTimeInterval: 3)
            }
            return UIPilot.render(last)
        case "page-messages": return UIPilot.renderPage(call("page", ["pane": pane == "navigateur" ? "outlook" : pane, "sub": "messages"], timeout: 40), pane: pane == "navigateur" ? "outlook" : pane, message: true)
        case "page-clic":
            guard !parg.isEmpty else { return "page-clic <libellé ou index de page-lire>" }
            log("page-clic " + parg)
            var r = call("page", ["pane": pane, "sub": "clic", "q": parg], timeout: 20)
            if (r?["confirmation"] as? Bool) == true {   // AUDIT-24/10: uibridge.js renvoie désormais confirmation:true pour un bouton Envoyer/Send/Supprimer… sur TOUS les volets
                if let m = Tools.needConfirm("page-clic " + parg, kind: "clic sensible sur une page web (Envoyer, Supprimer, Payer…)") { return m }
                r = call("page", ["pane": pane, "sub": "clic", "q": parg, "confirmed": true], timeout: 20)
            }
            return UIPilot.renderPage(r, pane: pane, message: true)
        case "page-saisir":
            let p = parts(); guard p.count >= 2, !p[0].isEmpty else { return "page-saisir <champ> | <valeur> [| entree]" }
            let withEnter: Bool = p.count > 2 && p[2].lowercased().hasPrefix("ent")
            // AUDIT-24/10: Entrée dans un volet web = envoi possible (Teams, WhatsApp, Outlook…) : carte de confirmation d'Ahadi AVANT toute frappe.
            if withEnter, let m = Tools.needConfirm(raw, kind: "saisie + Entrée dans un volet web (peut ENVOYER un message)") { return m }
            log("page-saisir " + p[0])
            return UIPilot.renderPage(call("page", ["pane": pane, "sub": "saisir", "q": p[0], "value": p[1], "enter": withEnter, "confirmed": withEnter], timeout: 20), pane: pane, message: true)
        case "page-touche":
            guard !parg.isEmpty else { return "page-touche <Enter|Tab|…>" }
            // AUDIT-24/10: une touche Entrée/Retour dans un volet web peut ENVOYER un message : carte de confirmation d'Ahadi obligatoire.
            let sendKey: Bool = parg.lowercased().range(of: #"enter|return|retour|entr[ée]e"#, options: .regularExpression) != nil
            if sendKey, let m = Tools.needConfirm(raw, kind: "touche Entrée dans un volet web (peut ENVOYER un message)") { return m }
            log("page-touche " + parg)
            return UIPilot.renderPage(call("page", ["pane": pane, "sub": "touche", "q": parg, "confirmed": sendKey], timeout: 15), pane: pane)
        // Médias en ARRIÈRE-PLAN : aucun changement d'onglet, l'écran de l'utilisateur n'est pas touché.
        default: return nil
        }
    }

    /// CHANTIER 2 (suite) : verbes go/ui-* extraits de pilotage — mécanique, aucun changement de comportement.
    func pilotageUI(_ verb: String, _ arg: String, _ raw: String) -> String? {
        func log(_ why: String) { _ = BlackBox.record(["tool": "app", "actor": "Assistant", "why": why, "ok": true, "effect": "interface"]) }
        func call(_ op: String, _ a: [String: Any] = [:], timeout: TimeInterval = 12) -> [String: Any]? { UIPilot.shared.request(op, a, timeout: timeout) }
        func parts() -> [String] { arg.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) } }
        switch verb {
        case "go", "onglet":
            guard !arg.isEmpty else { return "go <onglet ou réglage> [| section] — ex. « go systeme | Connexions ». Liste : onglets." }
            let p = parts(); log("go " + arg)
            return UIPilot.render(call("go", ["q": p[0], "section": p.count > 1 ? p[1] : ""]))
        case "onglets": return UIPilot.render(call("onglets"))
        case "ui-etat": return UIPilot.render(call("etat"))
        case "ui-lire": return UIPilot.render(call("lire", ["q": arg]))
        case "ui-clic":
            guard !arg.isEmpty else { return "ui-clic <libellé ou index de ui-lire>" }
            log("ui-clic " + arg)
            var r = call("clic", ["q": arg])
            if (r?["confirmation"] as? Bool) == true {
                if let m = Tools.needConfirm("ui-clic " + arg, kind: "action d'interface sensible") { return m }
                r = call("clic", ["q": arg, "confirmed": true])
            }
            return UIPilot.render(r)
        case "ui-saisir":
            let p = parts(); guard p.count >= 2, !p[0].isEmpty else { return "ui-saisir <champ> | <valeur> [| entree]" }
            log("ui-saisir " + p[0])
            return UIPilot.render(call("saisir", ["q": p[0], "value": p[1], "enter": p.count > 2 && p[2].lowercased().hasPrefix("ent")]))
        case "ui-touche": return arg.isEmpty ? "ui-touche <Enter|Escape|Tab|cmd+k|…>" : UIPilot.render(call("touche", ["q": arg]))
        case "ui-defiler": return UIPilot.render(call("defiler", ["q": arg.isEmpty ? "bas" : arg]))
        default: return nil
        }
    }

    /// CHANTIER 2 (suite) : verbes media-* extraits de pilotage — mécanique.
    func pilotageMedia(_ verb: String, _ arg: String) -> String? {
        func log(_ why: String) { _ = BlackBox.record(["tool": "app", "actor": "Assistant", "why": why, "ok": true, "effect": "interface"]) }
        func call(_ op: String, _ a: [String: Any] = [:], timeout: TimeInterval = 12) -> [String: Any]? { UIPilot.shared.request(op, a, timeout: timeout) }
        switch verb {
        case "media-radio":
            guard !arg.isEmpty else { return "media-radio <nom de la station> (ex. « Horizon FM 104.4 », « France Info »)" }
            log("media-radio " + arg); return UIPilot.render(call("media", ["act": "radio", "q": arg], timeout: 20))
        case "media-stop": log("media-stop"); return UIPilot.render(call("media", ["act": "stop"]))
        case "media-etat": return UIPilot.render(call("media", ["act": "etat"]))
        case "media-volume": log("media-volume " + arg); return UIPilot.render(call("media", ["act": "volume", "q": arg]))
        default: return nil
        }
    }

    /// CHANTIER 2 (suite) : verbes relais-* extraits de pilotage — mécanique.
    func pilotageRelais(_ verb: String, _ arg: String) -> String? {
        func log(_ why: String) { _ = BlackBox.record(["tool": "app", "actor": "Assistant", "why": why, "ok": true, "effect": "interface"]) }
        switch verb {
        case "relais":
            guard arg.count >= 8 else { return "relais <objectif complet> : l'assistant continue seul en arrière-plan (plusieurs tours) et revient quand c'est fini ou qu'une décision est nécessaire." }
            log("relais " + String(arg.prefix(120)))
            return relaisStart(goal: arg)
        case "relais-liste", "relais-etat":
            return pilotageRelaisLecture(verb, arg)
        case "relais-stop":
            NovaApp.relaisLock.lock(); NovaApp.relaisStopped.insert(arg); NovaApp.relaisLock.unlock()
            relaisPatch(arg) { $0["status"] = "arrete" }; return "Relais \(arg) : arrêt demandé (effectif à la fin de l'étape en cours)."
        default: return nil
        }
    }

    /// CHANTIER 2 (suite) : lectures relais extraites de pilotageRelais — mécanique.
    func pilotageRelaisLecture(_ verb: String, _ arg: String) -> String? {
        switch verb {
        case "relais-liste":
            let l: [[String: Any]] = NovaApp.relaisFile.read(default: [[String: Any]]())
            if l.isEmpty { return "Aucun relais." }
            let lignes: [String] = l.suffix(12).map { (j: [String: Any]) -> String in
                let id: String = (j["id"] as? String) ?? ""
                let st: String = (j["status"] as? String) ?? ""
                let tours: String = String(describing: j["rounds"] ?? 0)
                let but: String = String(((j["goal"] as? String) ?? "").prefix(90))
                return id + " · " + st + " · tour " + tours + " · " + but
            }
            return lignes.joined(separator: "\n")
        case "relais-etat":
            guard let j: [String: Any] = NovaApp.relaisFile.read(default: [[String: Any]]()).first(where: { ($0["id"] as? String) == arg }) else { return "relais-etat <id> (voir relais-liste)" }
            let logs: [[String: Any]] = (j["log"] as? [[String: Any]]) ?? []
            let lignes: [String] = logs.suffix(6).map { (e: [String: Any]) -> String in
                let ts: String = (e["ts"] as? String) ?? ""
                let tx: String = String(((e["text"] as? String) ?? "").prefix(400))
                return "[" + ts + "] " + tx
            }
            let id: String = (j["id"] as? String) ?? ""
            let st: String = (j["status"] as? String) ?? ""
            let tours: String = String(describing: j["rounds"] ?? 0)
            let but: String = (j["goal"] as? String) ?? ""
            return "Relais " + id + " — " + st + " — tour " + tours + "\nObjectif : " + but + "\n" + lignes.joined(separator: "\n")
        default: return nil
        }
    }

    func pilotage(_ verb: String, _ raw: String) -> String? {
        guard NovaApp.pilotVerbs.contains(verb) else { return nil }
        let arg = String(raw.dropFirst(verb.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        var pane = "navigateur"; var parg = arg
        if verb.hasPrefix("page-"), arg.hasPrefix("@") { let t = arg.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init); pane = t.first ?? pane; parg = t.count > 1 ? t[1] : "" }
        // VAGUE 3 : verbes AX — apps tierces lues et pilotées SANS activation ; journal « ax » tenu par AXPilot (app, rôle, titre, effet).
        if AXPilot.verbs.contains(verb) { return AXPilot.run(verb, arg, actor: "Assistant") }
        if verb.hasPrefix("page-") { return pilotagePage(verb, arg, pane, parg, raw) }
        if let r = pilotageUI(verb, arg, raw) { return r }
        if let r = pilotageMedia(verb, arg) { return r }
        return pilotageRelais(verb, arg)
    }

    // MARK: relais d'arrière-plan
    func relaisPatch(_ id: String, _ f: (inout [String: Any]) -> Void) {
        NovaApp.relaisLock.lock(); defer { NovaApp.relaisLock.unlock() }
        var l = NovaApp.relaisFile.read(default: [[String: Any]]())
        if let i = l.firstIndex(where: { ($0["id"] as? String) == id }) { f(&l[i]) }
        NovaApp.relaisFile.write(Array(l.suffix(60)))
    }
    func relaisStart(goal: String) -> String {
        let id = String(UUID().uuidString.prefix(6)).lowercased()
        NovaApp.relaisLock.lock()
        var l = NovaApp.relaisFile.read(default: [[String: Any]]())
        if l.filter({ ($0["status"] as? String) == "en_cours" }).count >= 2 { NovaApp.relaisLock.unlock(); return "Déjà 2 relais en cours : attends la fin de l'un (relais-liste) ou arrête-en un (relais-stop <id>)." }
        l.append(["id": id, "goal": goal, "status": "en_cours", "created": nowISO(), "rounds": 0, "log": [[String: Any]]()]); NovaApp.relaisFile.write(Array(l.suffix(60)))
        NovaApp.relaisLock.unlock()
        Thread.detachNewThread { [self] in relaisRun(id, goal) }
        return "RELAIS \(id) LANCÉ : j'avance seul en arrière-plan sur « \(String(goal.prefix(100))) ». Suivi : relais-etat \(id) · arrêt : relais-stop \(id). Je préviens à la fin ou si une décision est nécessaire."
    }
    func relaisRun(_ id: String, _ goal: String) {
        var memo = ""
        func stopped() -> Bool { NovaApp.relaisLock.lock(); defer { NovaApp.relaisLock.unlock() }; return NovaApp.relaisStopped.contains(id) }
        func say(_ t: String) { bus.publish("relais", ["id": id, "text": t]) }
        for round in 1...6 {
            if stopped() { say("Relais \(id) arrêté."); return }
            let extra = NovaMap.text + "\nTU TRAVAILLES EN ARRIÈRE-PLAN, tour \(round)/6, pendant que l'utilisateur fait autre chose : il ne te répond pas, ne lui pose aucune question. Objectif confié : \(goal). Tu NE pilotes PAS l'écran de l'utilisateur : aucun changement d'onglet, aucun clic, aucune page ouverte devant lui (app go / ui-* / page-* te sont refusés). Travaille avec tes outils de lecture en arrière-plan : mail_unread (Outlook, Gmail, Teams lus par Nova sans rien afficher), calendar, reminders, web_search, web_fetch, read_file, find, recall, know ; draft_reply UNIQUEMENT si l'objectif confié demande explicitement un brouillon (sinon : Signale uniquement : brouillon possible sur demande) ; vérifie chaque constat. Jamais d'envoi de message/mail, de paiement, de mot de passe ou de clé. Termine par UNE dernière ligne : « STATUT: terminee » (objectif atteint, avec le résultat avant), « STATUT: en_cours » (il reste des étapes) ou « STATUT: decision » (avec avant elle « QUESTION: … » : seule une décision humaine peut débloquer)."
            let sys = Persona.system(assistantName: "Nova", title: settings.get("user_title", "Capitaine"), memory: memory.promptBlock(max: 15), voice: false, tools: true, extra: extra)
            var text = ""
            Agent(router: router, tools: tools).run(messages: [ChatMsg("user", "OBJECTIF : \(goal)\n\nJournal des tours précédents :\n\(memo.isEmpty ? "(premier tour)" : memo)\n\nAvance maintenant : enchaîne les outils sans annoncer, puis rapport de 6 lignes max.")],
                                                    system: sys, mode: "fast", preferred: nil, maxTokens: 1800, useTools: true, maxSteps: 14, actor: "Relais \(id)", cancel: { stopped() }) { ev in if case .delta(let t) = ev { text += t } else if case .draftReset = ev { text = "" } }   // VÉRITÉ-3 (E3, 23/10) : même discipline que le handler — la dernière génération du tour fait foi, le journal du relais ne soude plus les versions
            if stopped() { say("Relais \(id) arrêté."); return }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = clean.range(of: #"STATUT:\s*(terminee|terminée|decision|décision|en_cours)"#, options: [.regularExpression, .caseInsensitive]).map { String(clean[$0]).lowercased() } ?? ""
            relaisPatch(id) { j in
                j["rounds"] = round
                var lg = (j["log"] as? [[String: Any]]) ?? []; lg.append(["ts": nowISO(), "text": String(clean.prefix(1500))]); j["log"] = Array(lg.suffix(20))
            }
            memo += "\n[tour \(round)] " + String(clean.prefix(700))
            if status.contains("termin") { relaisPatch(id) { $0["status"] = "termine" }; say("Relais terminé — " + String(clean.replacingOccurrences(of: "\n", with: " ").prefix(220))); return }
            if status.contains("decision") || status.contains("décision") { relaisPatch(id) { $0["status"] = "decision" }; say("Relais en attente de ta décision — " + String(clean.replacingOccurrences(of: "\n", with: " ").prefix(220))); return }
            if clean.isEmpty { relaisPatch(id) { $0["status"] = "echec" }; say("Relais \(id) : aucun cerveau n'a répondu."); return }
        }
        relaisPatch(id) { $0["status"] = "limite" }
        say("Relais \(id) : 6 tours effectués, objectif non terminé — relais-etat \(id).")
    }
}
