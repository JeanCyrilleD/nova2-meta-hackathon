import Foundation
// MUSE-PARTOUT (26/10, ordre d'Ahadi) : defauts de ce fichier sur Muse (voir ordres dans Brains.swift).

// VAGUE 1 (24/10/2026) — Confiance graduée — approbations à 4 niveaux, autonomie apprise, relecteur.
//
// 1) POLITIQUE PAR TYPE D'ACTION (4 niveaux) : « seul » (agir seule) / « regle » (agir si pré-approuvé :
//    seule quand la demande vient de la conversation avec Ahadi, carte sinon) / « demander » (carte à chaque
//    fois) / « jamais » (rendre la main). Les INTERDITS FIXES (envoi, publication, argent/BRVM, suppression
//    définitive, secrets) sont « jamais », non modifiables. La couche est appliquée dans Agent.runGuarded
//    (Feat_Checkpoints) APRÈS « block » et AVANT toutes les gardes existantes, qu'elle ne remplace jamais :
//    elle ne peut qu'ajouter une carte ou un refus — jamais lever une garde (tool_policy, gate(), Permis, ACL).
// 2) AUTONOMIE APPRISE : registre des décisions réelles des cartes (approuvé / modifié / refusé / expiré) ;
//    un type réversible au niveau « demander » qui cumule 20 approbations et 0 refus sur 30 jours fait l'objet
//    d'une PROPOSITION (jamais automatique) de passage en « regle », annulable en un clic.
// 3) RELECTEUR INDÉPENDANT : chaque brouillon d'envoi en attente est relu par [tiers] (appel bref, épinglé) contre
//    la demande et la charte ; remarques rangées à part (confiance_relectures.json), servies par /api/trust/review.
//    Il ne bloque rien et ne réécrit rien.
// 4) DOTS EN LECTURE SEULE : un acteur Dot / Relais / « Assistant (appui d'un Dot) » ne peut exécuter qu'un type
//    lecture / mémoire interne / préparation ; tout autre type passe par la carte d'Ahadi (code, pas prompt).

public enum Trust {
    public struct Category {
        public let id: String
        public let label: String
        public let desc: String
        public let defaultLevel: String
        public let fixed: Bool
        public let fixedReason: String
        public let reversible: Bool
        public let dotOK: Bool
    }
    public struct Verdict {
        public let action: String      // "run" | "ask" | "refuse"
        public let category: String
        public let level: String
        public let reason: String      // court, pour le journal
        public let message: String     // renvoyé au modèle en cas de refus
        public let cardKind: String    // libellé de la carte de confirmation
    }

    public static let levels: [String] = ["seul", "regle", "demander", "jamais"]
    static let levelLabels: [String: String] = ["seul": "Agir seule", "regle": "Si pré-approuvé", "demander": "Demander à chaque fois", "jamais": "Jamais — rendre la main"]
    static func rank(_ l: String) -> Int { levels.firstIndex(of: l) ?? 2 }

    public static let categories: [Category] = [
        Category(id: "lecture_locale", label: "Lire sur le Mac", desc: "Mails, agenda, rappels, fichiers, notes, état de Nova : lire sans rien changer.", defaultLevel: "seul", fixed: false, fixedReason: "", reversible: false, dotOK: true),
        Category(id: "lecture_web", label: "Lire le web", desc: "Recherches, pages publiques, flux de veille, cours BRVM.", defaultLevel: "seul", fixed: false, fixedReason: "", reversible: false, dotOK: true),
        Category(id: "memoire", label: "Retenir", desc: "Carnet interne de Nova : souvenirs, leçons, idées. Rien ne sort du Mac.", defaultLevel: "seul", fixed: false, fixedReason: "", reversible: true, dotOK: true),
        Category(id: "brouillon", label: "Préparer un brouillon", desc: "Brouillons et livrables mis en forme. Rien n'est envoyé.", defaultLevel: "regle", fixed: false, fixedReason: "", reversible: true, dotOK: true),
        Category(id: "ecriture_locale", label: "Écrire sur le Mac", desc: "Créer ou modifier un fichier, un événement, un rappel, une note — avec point de restauration.", defaultLevel: "regle", fixed: false, fixedReason: "", reversible: true, dotOK: false),
        Category(id: "pilotage", label: "Piloter une app ou l'écran", desc: "Ouvrir, cliquer, saisir, AppleScript, raccourcis, téléphone. Les gardes de l'écran restent actives.", defaultLevel: "regle", fixed: false, fixedReason: "", reversible: false, dotOK: false),
        Category(id: "shell", label: "Commandes Terminal", desc: "Commandes hors liste de lecture. Les gardes du shell (filtres d'analyse, pas un bac à sable) restent actives.", defaultLevel: "regle", fixed: false, fixedReason: "", reversible: false, dotOK: false),
        Category(id: "reglages", label: "Réglages de Nova et du système", desc: "Réglages, Dots, code de Nova, réglages macOS.", defaultLevel: "demander", fixed: false, fixedReason: "", reversible: false, dotOK: false),
        Category(id: "envoi", label: "Envoyer un message", desc: "Mail, Teams, WhatsApp, SMS.", defaultLevel: "jamais", fixed: true, fixedReason: "Règle d'or n°2 : rien ne part sans ton GO sur le contenu exact. L'envoi ne part que de la carte Messages, après ENVOYER.", reversible: false, dotOK: false),
        Category(id: "publication", label: "Publier", desc: "Réseaux, sites, dépôts publics.", defaultLevel: "jamais", fixed: true, fixedReason: "Règle d'or n°2 : rien n'est publié sans ton GO. Nova prépare, tu publies.", reversible: false, dotOK: false),
        Category(id: "paiement", label: "Argent, paiement, ordres BRVM", desc: "Paiements, virements, mobile money, ordres de bourse.", defaultLevel: "jamais", fixed: true, fixedReason: "Nova ne paie jamais, ne transfère rien et ne passe aucun ordre de bourse : elle te rappelle et prépare.", reversible: false, dotOK: false),
        Category(id: "suppression", label: "Supprimer définitivement", desc: "Effacer un fichier, vider la Corbeille, effacer un disque.", defaultLevel: "jamais", fixed: true, fixedReason: "Aucune suppression définitive par Nova : elle te rend la main (la Corbeille reste ton geste).", reversible: false, dotOK: false),
        Category(id: "secrets", label: "Mots de passe et secrets", desc: "Clés, jetons, trousseau, mots de passe.", defaultLevel: "jamais", fixed: true, fixedReason: "Clés, mots de passe et trousseau ne sont jamais lus ni saisis par Nova : tu les tapes toi-même.", reversible: false, dotOK: false),
    ]
    static func category(_ id: String) -> Category? { categories.first(where: { $0.id == id }) }

    static let policyFile: JSONFile = JSONFile("confiance_politique.json")
    static let decisionsFile: JSONFile = JSONFile("confiance_decisions.json")
    static let proposalsFile: JSONFile = JSONFile("confiance_propositions.json")
    static let reviewsFile: JSONFile = JSONFile("confiance_relectures.json")
    static let seenFile: JSONFile = JSONFile("confiance_brouillons_vus.json")
    static let lock: NSLock = NSLock()
    public static let proposalApprovals: Int = 20
    public static let proposalDays: Int = 30
    nonisolated(unsafe) static var notify: ((String, [String: Any]) -> Void)? = nil
    /// Cerveau du relecteur (system, prompt) → texte. Branché par trustRoutes ([tiers] épinglé, appel bref).
    nonisolated(unsafe) static var reviewer: ((String, String) -> (text: String, brain: String)?)? = nil
    static let kickSem: DispatchSemaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) static var watching: Bool = false   // PHASE 1 (relu, protégé) : sous watchLock
    static let watchLock: NSLock = NSLock()

    // MARK: classification

    static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: .caseInsensitive) }
    static let deleteShellRx: NSRegularExpression = rx(#"(^|[\s;|&(])(rm|rmdir|unlink|shred|srm)(\s|$)|\bfind\s[^\n]*-delete\b|\bdiskutil\s+(erase|zerodisk|secureerase|reformat)|\btmutil\s+delete\b|\bgit\s+clean\s+-[a-z]*f"#)
    static let deleteScriptRx: NSRegularExpression = rx(#"empty\s+(the\s+)?trash|\berase\b|\bdelete\b"#)
    static let finderRx: NSRegularExpression = rx(#"tell\s+(application|app)\s+\\?"Finder\\?""#)
    static let systemShellRx: NSRegularExpression = rx(#"\bdefaults\s+(write|delete|import)\b|\bnetworksetup\s+-set|\bpmset\s+(?!-g)|\blaunchctl\s+(load|unload|bootstrap|bootout|enable|disable|kickstart)\b|\bsystemsetup\b|\bscutil\s+--set\b|\bspctl\b|\bsoftwareupdate\s+(-i|--install)|\btmutil\s+(enable|disable|setdestination)\b|\bdscl\b|\bchsh\b|\bcrontab\b"#)
    static let publishRx: NSRegularExpression = rx(#"\bnpm\s+publish\b|\bgh\s+release\s+create\b|\btwine\s+upload\b|\bgem\s+push\b|\bpod\s+trunk\s+push\b|\bvercel\s+[^\n]*--prod\b|\bnetlify\s+deploy\s+[^\n]*--prod\b"#)
    static let payRx: NSRegularExpression = rx(#"(stripe|paypal|virement|\bpaiement\b|\bpayer\b|\bpay\s+now\b|\bpayment\b|orange\s*money|moov\s*money|wave\s+(transfer|transfert)|ordre\s+(d'achat|de\s+vente|de\s+bourse|au\s+march[ée])|passer\s+(un\s+|l'|cet\s+)?ordre|place\s+order|\bcheckout\b|acheter\s+\d+\s+(actions?|titres?)|vendre\s+\d+\s+(actions?|titres?))"#)
    static let sendClickRx: NSRegularExpression = rx(#"\b(envoyer|send|r[ée]pondre\s+[àa]\s+tous|reply\s+all|transf[ée]rer|forward)\b"#)
    static let publishClickRx: NSRegularExpression = rx(#"\b(publier|publish|poster|tweet(er)?|partager\s+publiquement)\b"#)
    static let appReadVerbs: Set<String> = ["status", "etat", "état", "dots", "equipe", "équipe", "dot-info", "info", "runs", "historique", "settings", "reglages", "réglages", "cerveaux", "brains", "attente", "briefs", "boite", "boîte", "permis", "memoire", "mémoire", "actions", "carte", "map", "evolution", "radar", "dot", "brief", "meeting", "consulter", "dot-run"]
    static let appSettingVerbs: Set<String> = ["set", "dot-set", "dot-pause", "dot-reprendre", "dot-supprimer", "dot-delete"]
    static let pilotReadVerbs: Set<String> = ["ui-etat", "ui-lire", "page-etat", "page-lire", "page-messages", "page-absence", "relais-liste", "relais-etat", "media-etat", "onglets", "ax-lire", "ax-chercher"]

    static func jsonPath(_ arg: String) -> String {
        guard let o = parseJSON(Data(arg.utf8)) else { return arg }
        return (o["path"] as? String) ?? arg
    }

    /// Type d'action d'un appel d'outil (nom + argument). Toute action inconnue tombe dans « pilotage ».
    public static func classify(tool: String, arg: String) -> String {
        let a: String = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tool {
        case "web_search", "web_fetch", "flux_titres", "brvm_cours":
            return "lecture_web"
        case "read_file":
            return Tools.isSensitivePath(jsonPath(a)) ? "secrets" : "lecture_locale"
        case "mail_unread", "mail_week", "mail_corps", "mail_pj", "teams_read", "calendar", "reminders", "notes", "contacts", "find", "clipboard", "today", "system", "processes", "nova_self", "recall", "know", "skill", "transcribe", "ask_assistant",
             "bibliotheque", "lire_fichier_bibliotheque":   // 31/10 (Algolia biblio) : lectures (exclusions sensibles codées dans Feat_AlgoliaBiblio)
            return "lecture_locale"
        case "media", "nova_ui":   // 25/10 : lecteur et écrans de Nova elle-même — local, sans effet hors de Nova, aucune carte
            return "lecture_locale"
        case "formulaire":   // 25/10 : lire = lecture ; remplir / soumettre = pilotage (soumettre exige EN PLUS la carte needConfirm, codée dans NovaForm)
            let fv: String = (a.split(separator: "|", maxSplits: 1).first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            return fv == "lire" ? "lecture_locale" : "pilotage"
        case "remember":
            return "memoire"
        case "draft_reply", "mail_brouillon", "cafu_format_document", "cafu_format_email", "cafu_format_docx", "cafu_format_deck", "cafu_format_pdf", "cafu_format_table":
            return "brouillon"
        case "write_file", "edit_file":
            return Tools.isSensitivePath(jsonPath(a)) ? "secrets" : "ecriture_locale"
        case "calendar_add", "reminder_add", "note_add":
            return "ecriture_locale"
        case "momo":
            let v: String = (a.split(separator: "|", maxSplits: 1).first.map(String.init) ?? "").lowercased()
            return ["add", "done", "remove"].contains(v) ? "ecriture_locale" : "lecture_locale"
        case "forge_tool":
            return "reglages"
        case "ui":
            if Tools.match(payRx, a) { return "paiement" }
            let act: String = (a.split(separator: "|", maxSplits: 1).first.map(String.init) ?? "").lowercased()
            if act == "click" && Tools.match(publishClickRx, a) { return "publication" }
            if act == "click" && Tools.match(sendClickRx, a) { return "envoi" }
            return "pilotage"
        case "applescript":
            return scriptCategory(a)
        case "shell":
            return shellCategory(a)
        case "app":
            let v: String = (a.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? "").lowercased()
            if appReadVerbs.contains(v) { return "lecture_locale" }
            if NovaApp.learnVerbs.contains(v) { return "memoire" }
            if appSettingVerbs.contains(v) || NovaApp.evoWriteVerbs.contains(v) { return "reglages" }
            if pilotReadVerbs.contains(v) { return "lecture_locale" }
            if Tools.match(payRx, a) { return "paiement" }
            if v == "page-clic" || v == "ui-clic" {
                if Tools.match(publishClickRx, a) { return "publication" }
                if Tools.match(sendClickRx, a) { return "envoi" }
            }
            return "pilotage"
        default:
            return "pilotage"
        }
    }
    static func scriptCategory(_ a: String) -> String {
        if Tools.shellMentionsSensitive(a) || Tools.match(Tools.forbiddenRx, a) { return "secrets" }
        if Tools.match(payRx, a) { return "paiement" }
        if Tools.match(Tools.mailPayRx, a) || Tools.match(Tools.sendEvasionRx, a) { return "envoi" }
        if Tools.match(deleteScriptRx, a) {
            let low: String = a.lowercased()
            if low.contains("trash") || !Tools.match(finderRx, a) { return "suppression" }
        }
        return "pilotage"
    }
    static func shellCategory(_ raw: String) -> String {
        let sa: ShellAssessment = Tools.shellAssessment(raw)
        let a: String = raw + "\n" + sa.normalized   // WP5 : les filtres lisent aussi la forme déguillemetée (cu''rl, s\\endmail…)
        if Tools.shellMentionsSensitive(a) || Tools.match(Tools.forbiddenRx, a) || !sa.sensitive.isEmpty { return "secrets" }
        if Tools.match(payRx, a) { return "paiement" }
        if Tools.match(Tools.mailPayRx, a) || (Tools.match(Tools.sendEvasionRx, a) && !Tools.loopbackCurlOnly(raw)) { return "envoi" }
        if Tools.match(publishRx, a) { return "publication" }
        if Tools.match(deleteShellRx, a) || Tools.match(Tools.catastrophicRx, a) || !sa.destructive.isEmpty { return "suppression" }
        if Tools.match(systemShellRx, a) { return "reglages" }
        if sa.readOnly { return "lecture_locale" }
        return "shell"
    }

    // MARK: politique

    static func defaultLevel(_ c: Category) -> String {
        // autorisation_totale (A2) déjà choisie par Ahadi : l'écriture locale réversible reste à « si pré-approuvé »
        // tant qu'il n'a pas fixé lui-même un niveau ici — jamais un défaut plus large que son choix.
        if c.id == "ecriture_locale" && Tools.fullAuto() { return "regle" }
        return c.defaultLevel
    }
    static func explicitLevels() -> [String: String] {
        let p: [String: Any] = policyFile.read(default: [String: Any]())
        let lv: [String: Any] = (p["levels"] as? [String: Any]) ?? [:]
        var out: [String: String] = [:]
        for (k, v) in lv { if let s = v as? String, levels.contains(s) { out[k] = s } }
        return out
    }
    public static func level(_ cat: String) -> String {
        guard let c = category(cat) else { return "demander" }
        if c.fixed { return "jamais" }
        if let v = explicitLevels()[cat] { return v }
        return defaultLevel(c)
    }
    @discardableResult
    public static func setLevel(_ cat: String, _ level: String, by: String) -> (ok: Bool, message: String) {
        guard let c = category(cat) else { return (false, "Type d'action inconnu : " + cat) }
        if c.fixed { return (false, "Interdit fixe, non modifiable : " + c.fixedReason) }
        guard levels.contains(level) else { return (false, "Niveau inconnu : " + level) }
        let before: String = self.level(cat)
        lock.lock()
        var p: [String: Any] = policyFile.read(default: [String: Any]())
        var lv: [String: Any] = (p["levels"] as? [String: Any]) ?? [:]
        lv[cat] = level
        p["levels"] = lv
        var hist: [[String: Any]] = (p["history"] as? [[String: Any]]) ?? []
        hist.append(["ts": nowISO(), "type": cat, "from": before, "to": level, "by": by])
        p["history"] = Array(hist.suffix(100))
        policyFile.write(p)
        lock.unlock()
        let lb: String = levelLabels[level] ?? level
        _ = BlackBox.record(["tool": "confiance", "actor": by.hasPrefix("Ahadi") ? "Ahadi" : "Nova", "why": "Confiance : « " + c.label + " » " + (levelLabels[before] ?? before) + " → " + lb + " (" + by + ")", "ok": true, "effect": "écrit"])
        return (true, "« " + c.label + " » : " + lb + ".")
    }

    static func isDotLike(_ actor: String) -> Bool {
        actor.hasPrefix("Dot ") || actor.hasPrefix("Relais ") || actor == "Assistant (appui d'un Dot)"
    }
    static func isDirect(_ actor: String, _ why: String) -> Bool {
        (actor == "Nova" || actor == "Toi") && !why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Décision de la couche Confiance pour un appel d'outil. Elle ne fait que DURCIR : « run » laisse
    /// la main aux gardes existantes (tool_policy, gate, Permis), « ask » ajoute une carte, « refuse » arrête.
    public static func verdict(tool: String, arg: String, actor: String, why: String) -> Verdict {
        let cat: String = classify(tool: tool, arg: arg)
        guard let c = category(cat) else { return Verdict(action: "run", category: cat, level: "seul", reason: "", message: "", cardKind: "") }
        if c.fixed {
            return Verdict(action: "refuse", category: cat, level: "jamais", reason: "interdit fixe « " + c.label + " »",
                           message: "JAMAIS — interdit fixe « " + c.label + " » : " + c.fixedReason + " L'action n'a PAS été exécutée. Rends la main à Ahadi en une phrase (ce qu'il lui reste à faire) ; ne cherche aucun contournement.", cardKind: "")
        }
        let lv: String = level(cat)
        if lv == "jamais" {
            return Verdict(action: "refuse", category: cat, level: lv, reason: "politique « jamais » pour « " + c.label + " »",
                           message: "JAMAIS — la politique de confiance d'Ahadi rend la main pour « " + c.label + " » (écran Confiance). L'action n'a PAS été exécutée. Dis-lui en une phrase ce qu'il reste à faire, par lui.", cardKind: "")
        }
        if isDotLike(actor) && !c.dotOK {
            return Verdict(action: "ask", category: cat, level: lv, reason: "lecture seule des Dots",
                           message: "", cardKind: "action « " + c.label + " » demandée par « " + actor + " » — un Dot travaille en lecture seule : rien ne se fait sans ton accord")
        }
        if lv == "demander" {
            return Verdict(action: "ask", category: cat, level: lv, reason: "politique « demander »", message: "", cardKind: "action « " + c.label + " » (Confiance : demander à chaque fois)")
        }
        if lv == "regle" && !isDirect(actor, why) {
            return Verdict(action: "ask", category: cat, level: lv, reason: "hors conversation (« si pré-approuvé »)", message: "", cardKind: "action « " + c.label + " » lancée hors conversation par « " + actor + " » (Confiance : si pré-approuvé)")
        }
        return Verdict(action: "run", category: cat, level: lv, reason: "", message: "", cardKind: "")
    }

    // MARK: registre de fiabilité

    public static func record(_ cat: String, outcome: String, tool: String, source: String) {
        guard ["approuve", "modifie", "refuse", "expire"].contains(outcome) else { return }
        lock.lock()
        var l: [[String: Any]] = decisionsFile.read(default: [[String: Any]]())
        l.append(["ts": nowISO(), "type": cat, "outcome": outcome, "tool": tool, "source": source])
        if l.count > 3000 { l.removeFirst(l.count - 3000) }
        decisionsFile.write(l)
        lock.unlock()
        evaluate(cat)
    }
    /// Décision d'une carte de confirmation (runGuarded). Sans réponse = « expire » (jamais compté comme un refus).
    public static func recordCard(category cat: String, answered: Bool, ok: Bool, tool: String, source: String) {
        record(cat, outcome: !answered ? "expire" : (ok ? "approuve" : "refuse"), tool: tool, source: source)
    }
    /// Compteurs par type : fenêtre de 30 jours + total depuis le début.
    static func allStats() -> [String: [String: Int]] {
        let since: Date = Date().addingTimeInterval(-Double(proposalDays) * 86400)
        let f: ISO8601DateFormatter = ISO8601DateFormatter()
        var out: [String: [String: Int]] = [:]
        let l: [[String: Any]] = decisionsFile.read(default: [[String: Any]]())
        for e in l {
            guard let cat = e["type"] as? String, let o = e["outcome"] as? String else { continue }
            var s: [String: Int] = out[cat] ?? ["approuve": 0, "modifie": 0, "refuse": 0, "expire": 0, "total": 0, "approuve_total": 0, "modifie_total": 0, "refuse_total": 0]
            s["total"] = (s["total"] ?? 0) + 1
            s[o + "_total"] = (s[o + "_total"] ?? 0) + 1
            if let t = e["ts"] as? String, let d = f.date(from: t), d >= since { s[o] = (s[o] ?? 0) + 1 }
            out[cat] = s
        }
        return out
    }

    /// Proposition d'autonomie : type réversible, au niveau « demander », ≥ 20 approbations et 0 refus sur 30 jours,
    /// aucune proposition en attente ni décidée pour ce type dans les 30 derniers jours. JAMAIS pour un interdit fixe.
    static func evaluate(_ cat: String) {
        guard let c = category(cat), c.reversible, !c.fixed else { return }
        guard level(cat) == "demander" else { return }
        let s: [String: Int] = allStats()[cat] ?? [:]
        let ap: Int = s["approuve"] ?? 0
        let rf: Int = s["refuse"] ?? 0
        guard ap >= proposalApprovals, rf == 0 else { return }
        let since: Date = Date().addingTimeInterval(-Double(proposalDays) * 86400)
        let f: ISO8601DateFormatter = ISO8601DateFormatter()
        lock.lock()
        var ps: [[String: Any]] = proposalsFile.read(default: [[String: Any]]())
        let blocked: Bool = ps.contains(where: { (x: [String: Any]) -> Bool in
            guard (x["type"] as? String) == cat else { return false }
            if (x["status"] as? String) == "en_attente" { return true }
            if let t = x["decidedAt"] as? String, let d = f.date(from: t), d >= since { return true }
            return false
        })
        if blocked { lock.unlock(); return }
        let prop: [String: Any] = ["id": String(UUID().uuidString.prefix(8)).lowercased(), "type": cat, "label": c.label, "from": "demander", "to": "regle", "status": "en_attente", "ts": nowISO(),
                                   "evidence": ["approuve": ap, "modifie": s["modifie"] ?? 0, "refuse": rf, "jours": proposalDays],
                                   "text": "Tu as approuvé « " + c.label + " » \(ap) fois sans refus en \(proposalDays) jours. Passer ce type en « si pré-approuvé » : Nova agit seule quand tu le demandes en conversation, carte sinon. Réversible en un clic."]
        ps.append(prop)
        if ps.count > 100 { ps.removeFirst(ps.count - 100) }
        proposalsFile.write(ps)
        lock.unlock()
        _ = BlackBox.record(["tool": "confiance", "actor": "Nova", "why": "Proposition d'autonomie : « " + c.label + " » (\(ap) approbations, 0 refus sur \(proposalDays) j) — en attente de ta décision", "ok": true, "effect": "proposition"])
        notify?("trust_proposal", prop)
    }

    /// Accepter / refuser une proposition en attente ; « accept:false » sur une proposition acceptée = retour arrière (un clic).
    public static func decideProposal(_ id: String, accept: Bool) -> (ok: Bool, message: String, status: Int) {
        lock.lock()
        let ps: [[String: Any]] = proposalsFile.read(default: [[String: Any]]())
        let found: [String: Any]? = ps.first(where: { ($0["id"] as? String) == id })
        lock.unlock()
        guard let p = found, let cat = p["type"] as? String else { return (false, "Proposition introuvable.", 404) }
        guard let c = category(cat), !c.fixed else { return (false, "Interdit fixe : aucune autonomie possible.", 403) }
        let st: String = (p["status"] as? String) ?? ""
        var newStatus: String = ""
        var msg: String = ""
        if st == "en_attente" {
            if accept {
                let r: (ok: Bool, message: String) = setLevel(cat, (p["to"] as? String) ?? "regle", by: "Ahadi — proposition acceptée")
                guard r.ok else { return (false, r.message, 409) }
                newStatus = "acceptee"; msg = "Accepté. " + r.message + " Réversible en un clic."
            } else { newStatus = "refusee"; msg = "Proposition refusée : « " + c.label + " » reste à « demander à chaque fois »." }
        } else if st == "acceptee" && !accept {
            let r: (ok: Bool, message: String) = setLevel(cat, (p["from"] as? String) ?? "demander", by: "Ahadi — retour arrière de la proposition")
            guard r.ok else { return (false, r.message, 409) }
            newStatus = "annulee"; msg = "Retour arrière. " + r.message
        } else { return (false, "Proposition déjà traitée.", 409) }
        lock.lock()
        var l2: [[String: Any]] = proposalsFile.read(default: [[String: Any]]())
        if let i = l2.firstIndex(where: { ($0["id"] as? String) == id }) { l2[i]["status"] = newStatus; l2[i]["decidedAt"] = nowISO(); proposalsFile.write(l2) }
        lock.unlock()
        return (true, msg, 200)
    }

    // MARK: relecteur indépendant

    static let attachRx: NSRegularExpression = rx(#"(ci-joint|ci joint|en pi[èe]ce jointe|pi[èe]ces? jointes?|\ben pj\b|je (vous |te )?joins|vous trouverez joint|attached|attachment|please find enclosed|enclosed (is|are))"#)
    static let secretWordsRx: NSRegularExpression = rx(#"(mot de passe|password|passcode|code pin|code secret|code de v[ée]rification|\botp\b|identifiants? de connexion)"#)
    static let cardRx: NSRegularExpression = try! NSRegularExpression(pattern: #"\b\d{4}[ -]?\d{4}[ -]?\d{4}[ -]?\d{1,7}\b|\b[A-Z]{2}\d{2}(?:\s?[A-Z0-9]{4}){3,7}\b"#, options: [])
    static func plainText(_ html: String) -> String {
        var t: String = html.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "</p>", with: "\n").replacingOccurrences(of: "</li>", with: "\n")
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "**", with: "")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Demande d'Ahadi à l'origine du brouillon : action journalisée qui l'a créé (undo.id), sinon le dernier
    /// draft_reply / cafu_format_email journalisé à moins de 3 minutes du brouillon. Vide si inconnue.
    static func requestFor(_ d: [String: Any]) -> String {
        let id: String = (d["id"] as? String) ?? ""
        let acts: [[String: Any]] = Tools.actions.tail(400)
        if let e = acts.last(where: { (($0["undo"] as? [String: Any])?["id"] as? String) == id }), let w = e["why"] as? String, !w.isEmpty { return w }
        let f: ISO8601DateFormatter = ISO8601DateFormatter()
        guard let ts = d["ts"] as? String, let dt = f.date(from: ts) else { return "" }
        let near: [String: Any]? = acts.last(where: { (e: [String: Any]) -> Bool in
            let tl: String = (e["tool"] as? String) ?? ""
            guard tl == "draft_reply" || tl == "cafu_format_email", let t = e["ts"] as? String, let et = f.date(from: t) else { return false }
            return abs(et.timeIntervalSince(dt)) <= 180
        })
        return (near?["why"] as? String) ?? ""
    }
    static let reviewSystem: String = "Tu es le RELECTEUR INDÉPENDANT de Nova, l'assistant d'Ahadi. Tu ne réécris rien et tu ne bloques rien : avant qu'Ahadi approuve un envoi, tu signales les écarts CONCRETS entre le brouillon, sa demande et sa charte. Vérifie : (1) destinataire cohérent avec la demande ; (2) ton et forme conformes à la charte — mail : salutation, une phrase de contexte, points clés, demande en gras, clôture ; Teams : bloc fluide et court, une phrase de contexte, la demande avec une porte de sortie, signé « — Ahadi », ni HTML ni en-tête de mail ; (3) faits, chiffres, dates ou noms qui n'apparaissent pas dans la demande (non sourcés) ; (4) pièce jointe annoncée ; (5) données sensibles (mot de passe, numéro de compte ou de carte, santé, montants personnels) ; (6) écart avec ce qui était demandé. Ne signale que des problèmes réels et précis, en citant le passage en cause ; si la demande est inconnue, juge seulement la forme et les données sensibles. Réponds UNIQUEMENT par un JSON strict, sans texte autour : {\"points\":[{\"type\":\"destinataire|ton|faits|piece_jointe|sensible|demande\",\"texte\":\"…\"}]} — tableau vide si tout va bien. 5 points au plus, 160 caractères chacun, en français, tutoiement."

    /// Relit un brouillon : contrôles mécaniques + avis bref de [tiers]. Ne modifie jamais le brouillon.
    static func review(_ d: [String: Any]) -> [String: Any] {
        let id: String = (d["id"] as? String) ?? ""
        let channel: String = (d["channel"] as? String) ?? "mail"
        let dest: String = channel == "teams" ? ((d["target"] as? String) ?? "") : ((d["to"] as? String) ?? "")
        let subject: String = (d["subject"] as? String) ?? ""
        let body: String = plainText((d["body"] as? String) ?? "")
        let request: String = requestFor(d)
        var points: [[String: String]] = []
        let atts: [Any] = (d["attachments"] as? [Any]) ?? []
        if Tools.match(attachRx, body) && atts.isEmpty { points.append(["type": "piece_jointe", "texte": "Le brouillon annonce une pièce jointe, mais aucune n'y est attachée."]) }
        if Tools.match(secretWordsRx, body) { points.append(["type": "sensible", "texte": "Le corps mentionne un mot de passe ou un code : vérifie qu'aucun secret ne part."]) }
        if Tools.match(cardRx, body) { points.append(["type": "sensible", "texte": "Le corps contient une suite qui ressemble à un numéro de carte ou de compte (IBAN)."]) }
        if channel != "teams" && !dest.contains("@") { points.append(["type": "destinataire", "texte": "Aucune adresse e-mail valide dans le destinataire."]) }
        var statut: String = "indisponible"
        var brain: String = ""
        if let rv = reviewer {
            var prompt: String = "DEMANDE D'AHADI : " + (request.isEmpty ? "(inconnue — juge la forme et les données sensibles seulement)" : String(request.prefix(1200)))
            prompt += "\n\nCANAL : " + (channel == "teams" ? "Teams" : "mail")
            prompt += "\nDESTINATAIRE : " + String(dest.prefix(200))
            if !subject.isEmpty { prompt += "\nOBJET : " + String(subject.prefix(200)) }
            prompt += "\nCORPS :\n" + String(body.prefix(4000))
            if let r = rv(reviewSystem, prompt), let o = DailyCal.jsonSlice(r.text, open: "{", close: "}") as? [String: Any] {
                statut = "fait"; brain = r.brain
                for x in ((o["points"] as? [Any]) ?? []).prefix(5) {
                    guard let p = x as? [String: Any] else { continue }
                    let tx: String = ((p["texte"] as? String) ?? (p["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if tx.isEmpty { continue }
                    points.append(["type": (p["type"] as? String) ?? "demande", "texte": String(tx.prefix(200))])
                }
            }
        }
        let ok: Bool = statut == "fait" && points.isEmpty
        let line: String = statut != "fait" ? "Relecture : indisponible (cerveau correcteur injoignable)" + (points.isEmpty ? "" : " — contrôles mécaniques : \(points.count) point(s)") : (ok ? "Relecture : ✓" : "Relecture : \(points.count) point(s) à voir")
        return ["id": id, "hash": DraftLint.hash(d), "ts": nowISO(), "ok": ok, "statut": statut, "brain": brain, "points": points, "ligne": line,
                "demande_connue": !request.isEmpty, "channel": channel, "dest": String(dest.prefix(120)), "subject": String(subject.prefix(160))]
    }
    static func storeReview(_ r: [String: Any], attempts: Int) {
        guard let id = r["id"] as? String, !id.isEmpty else { return }
        var rr: [String: Any] = r
        rr["attempts"] = attempts
        lock.lock()
        var all: [String: Any] = reviewsFile.read(default: [String: Any]())
        all[id] = rr
        if all.count > 200 {
            let ordered: [String] = all.keys.sorted { (((all[$0] as? [String: Any])?["ts"] as? String) ?? "") < (((all[$1] as? [String: Any])?["ts"] as? String) ?? "") }
            for k in ordered.prefix(all.count - 200) { all.removeValue(forKey: k) }
        }
        reviewsFile.write(all)
        lock.unlock()
    }
    public static func reviewFor(_ id: String) -> [String: Any]? {
        let all: [String: Any] = reviewsFile.read(default: [String: Any]())
        return all[id] as? [String: Any]
    }
    public static func kick() { kickSem.signal() }

    /// Veille des brouillons (toutes les 5 s, ou sur kick) : décisions réelles des cartes d'envoi
    /// (envoyé tel quel / après modification / retiré) et relecture des brouillons en attente (récents : 48 h).
    static func tick(_ store: JSONFile) {
        let drafts: [[String: Any]] = store.read(default: [[String: Any]]())
        let f: ISO8601DateFormatter = ISO8601DateFormatter()
        var outcomes: [(String, String)] = []
        var toReview: [([String: Any], Int)] = []
        lock.lock()
        let raw: [String: Any] = seenFile.read(default: [String: Any]())
        var seen: [String: [String: Any]] = [:]
        for (k, v) in raw { if let dv = v as? [String: Any] { seen[k] = dv } }
        let reviews: [String: Any] = reviewsFile.read(default: [String: Any]())
        var present: Set<String> = []
        for d in drafts {
            guard let id = d["id"] as? String, !id.isEmpty else { continue }
            present.insert(id)
            let h: String = DraftLint.hash(d)
            let sent: Bool = ((d["status"] as? String) ?? "").lowercased().hasPrefix("envoy")
            let ch: String = (d["channel"] as? String) ?? "mail"
            if var s = seen[id] {
                if s["done"] == nil && sent {
                    let o: String = ((s["h0"] as? String) ?? "") == h ? "approuve" : "modifie"
                    s["done"] = o; s["doneAt"] = nowISO(); outcomes.append((o, ch))
                }
                if !sent { s["pendingSeen"] = true }
                seen[id] = s
            } else {
                var s: [String: Any] = ["h0": h, "first": nowISO(), "channel": ch]
                if sent { s["done"] = "preexistant"; s["doneAt"] = nowISO() } else { s["pendingSeen"] = true }
                seen[id] = s
            }
            guard !sent else { continue }
            let recent: Bool = { () -> Bool in
                guard let t = d["ts"] as? String, let dt = f.date(from: t) else { return false }
                return Date().timeIntervalSince(dt) < 48 * 3600
            }()
            guard recent else { continue }
            let rv: [String: Any]? = reviews[id] as? [String: Any]
            let att: Int = (rv?["attempts"] as? Int) ?? 0
            if (rv?["hash"] as? String) != h { toReview.append((d, 1)); continue }
            if (rv?["statut"] as? String) == "indisponible", att < 3, let t = rv?["ts"] as? String, let rt = f.date(from: t), Date().timeIntervalSince(rt) > 600 { toReview.append((d, att + 1)) }
        }
        for (id, s) in seen where !present.contains(id) && s["done"] == nil {
            var s2: [String: Any] = s
            if (s["pendingSeen"] as? Bool) == true { s2["done"] = "refuse"; outcomes.append(("refuse", (s["channel"] as? String) ?? "mail")) } else { s2["done"] = "disparu" }
            s2["doneAt"] = nowISO()
            seen[id] = s2
        }
        if seen.count > 400 {
            let old: [String] = seen.filter { !present.contains($0.key) }.map { $0.key }.sorted { ((seen[$0]?["doneAt"] as? String) ?? "") < ((seen[$1]?["doneAt"] as? String) ?? "") }
            for k in old.prefix(seen.count - 400) { seen.removeValue(forKey: k) }
        }
        seenFile.write(seen)
        lock.unlock()
        for (o, ch) in outcomes { record("envoi", outcome: o, tool: ch == "teams" ? "teams" : "mail", source: "carte d'envoi (Messages)") }
        if let first = toReview.first {
            let r: [String: Any] = review(first.0)
            storeReview(r, attempts: first.1)
            notify?("draft_review", r)
        }
    }
    static func startWatcher(_ store: JSONFile) {
        watchLock.lock()
        if watching { watchLock.unlock(); return }
        watching = true
        watchLock.unlock()
        DispatchQueue(label: "nova.trust.watch", qos: .utility).async {
            while true {
                Trust.tick(store)
                _ = Trust.kickSem.wait(timeout: .now() + 5)
            }
        }
    }

    // MARK: instantané pour l'écran

    public static func snapshot() -> [String: Any] {
        let st: [String: [String: Int]] = allStats()
        let explicit: [String: String] = explicitLevels()
        var cats: [[String: Any]] = []
        for c in categories {
            let s: [String: Int] = st[c.id] ?? [:]
            var stats: [String: Int] = [:]
            for k in ["approuve", "modifie", "refuse", "expire", "total", "approuve_total", "modifie_total", "refuse_total"] { stats[k] = s[k] ?? 0 }
            var row: [String: Any] = ["id": c.id, "label": c.label, "desc": c.desc, "level": level(c.id)]
            row["default"] = c.fixed ? "jamais" : defaultLevel(c)
            row["explicit"] = explicit[c.id] != nil
            row["fixed"] = c.fixed
            row["reason"] = c.fixedReason
            row["reversible"] = c.reversible
            row["dot_ok"] = c.dotOK
            row["stats"] = stats
            cats.append(row)
        }
        let ps: [[String: Any]] = proposalsFile.read(default: [[String: Any]]())
        let pending: [[String: Any]] = ps.filter { ($0["status"] as? String) == "en_attente" }
        let accepted: [[String: Any]] = ps.filter { ($0["status"] as? String) == "acceptee" && level(($0["type"] as? String) ?? "") == (($0["to"] as? String) ?? "") }
        let p: [String: Any] = policyFile.read(default: [String: Any]())
        let hist: [[String: Any]] = (p["history"] as? [[String: Any]]) ?? []
        let rv: [String: Any] = reviewsFile.read(default: [String: Any]())
        let allReviews: [[String: Any]] = rv.values.compactMap { $0 as? [String: Any] }
        let sortedReviews: [[String: Any]] = allReviews.sorted { (a: [String: Any], b: [String: Any]) -> Bool in ((a["ts"] as? String) ?? "") > ((b["ts"] as? String) ?? "") }
        let recentReviews: [[String: Any]] = Array(sortedReviews.prefix(8))
        let lv: [[String: Any]] = levels.map { (l: String) -> [String: Any] in ["id": l, "label": levelLabels[l] ?? l] }
        let forbidden: [[String: Any]] = categories.filter { $0.fixed }.map { (c: Category) -> [String: Any] in ["id": c.id, "label": c.label, "reason": c.fixedReason] }
        let threshold: [String: Int] = ["approuve": proposalApprovals, "refuse": 0, "jours": proposalDays]
        var out: [String: Any] = ["levels": lv, "categories": cats, "forbidden": forbidden]
        out["proposals"] = pending
        out["accepted"] = Array(accepted.suffix(10))
        out["history"] = Array(hist.suffix(20).reversed())
        out["reviews"] = recentReviews
        out["threshold"] = threshold
        out["full_auto"] = Tools.fullAuto()
        return out
    }
}

extension NovaApp {
    func trustRoutes() {
        let s: HTTPServer = server
        let tl: Tools = tools
        let rt: Router = router
        let bs: Bus = bus
        Trust.notify = { ev, o in bs.publish(ev, o) }
        Trust.reviewer = { sys, prompt in
            let r: (result: (text: String, brain: String)?, error: String?) = rt.completeDetailed(messages: [ChatMsg("user", prompt)], system: sys, mode: "fast", preferred: "spark-1.3", maxTokens: 500, deadline: 35, solo: true)
            return r.result
        }
        Trust.startWatcher(tl.drafts)

        s.on("GET", "/api/trust") { _, res in
            let body: [String: Any] = Trust.snapshot()
            res.json(body)
        }
        // Durcir est toujours permis ; ASSOUPLIR (niveau moins strict) exige la provenance d'interface
        // (même secret que l'envoi) : ni un Dot, ni un curl, ni l'agent ne peuvent s'accorder de l'autonomie.
        s.on("POST", "/api/trust/policy") { req, res in
            let j: [String: Any] = req.json
            let cat: String = (j["type"] as? String) ?? ""
            let lvl: String = (j["niveau"] as? String) ?? (j["level"] as? String) ?? ""
            guard let c = Trust.category(cat) else { let bad: [String: Any] = ["ok": false, "error": "type d'action inconnu"]; res.json(bad, status: 400); return }
            if c.fixed { let bad: [String: Any] = ["ok": false, "error": "Interdit fixe, non modifiable : " + c.fixedReason]; res.json(bad, status: 403); return }
            guard Trust.levels.contains(lvl) else { let bad: [String: Any] = ["ok": false, "error": "niveau inconnu (seul, regle, demander, jamais)"]; res.json(bad, status: 400); return }
            let fromUI: Bool = req.headers[SendQueue.headerName] == SendQueue.uiSecret
            if Trust.rank(lvl) < Trust.rank(Trust.level(cat)) && !fromUI {
                let bad: [String: Any] = ["ok": false, "code": "provenance", "error": "Assouplir la confiance n'est possible que depuis l'écran Confiance de Nova."]
                res.json(bad, status: 403); return
            }
            let r: (ok: Bool, message: String) = Trust.setLevel(cat, lvl, by: fromUI ? "Ahadi — écran Confiance" : "durcissement hors interface")
            let body: [String: Any] = ["ok": r.ok, "message": r.message, "level": Trust.level(cat)]
            res.json(body, status: r.ok ? 200 : 400)
        }
        s.on("POST", "/api/trust/proposal") { req, res in
            let j: [String: Any] = req.json
            let id: String = (j["id"] as? String) ?? ""
            let accept: Bool = (j["accept"] as? Bool) ?? false
            guard !id.isEmpty else { let bad: [String: Any] = ["ok": false, "error": "id requis"]; res.json(bad, status: 400); return }
            if accept && req.headers[SendQueue.headerName] != SendQueue.uiSecret {
                let bad: [String: Any] = ["ok": false, "code": "provenance", "error": "Accepter une proposition d'autonomie n'est possible que depuis l'écran Confiance de Nova."]
                res.json(bad, status: 403); return
            }
            let r: (ok: Bool, message: String, status: Int) = Trust.decideProposal(id, accept: accept)
            let body: [String: Any] = ["ok": r.ok, "message": r.message]
            res.json(body, status: r.status)
        }
        s.on("GET", "/api/trust/review") { req, res in
            let id: String = req.query["id"] ?? ""
            guard !id.isEmpty, let r = Trust.reviewFor(id) else { let none: [String: Any] = ["ok": false, "error": "aucune relecture pour ce brouillon"]; res.json(none, status: 404); return }
            res.json(r)
        }
        // Relecture à la demande (brouillon ancien ou relecture à refaire) — ne modifie jamais le brouillon.
        s.on("POST", "/api/trust/review") { req, res in
            let id: String = (req.json["id"] as? String) ?? ""
            let l: [[String: Any]] = tl.drafts.read(default: [[String: Any]]())
            guard let d = l.first(where: { ($0["id"] as? String) == id }) else { let bad: [String: Any] = ["ok": false, "error": "brouillon introuvable"]; res.json(bad, status: 404); return }
            let r: [String: Any] = Trust.review(d)
            Trust.storeReview(r, attempts: 1)
            res.json(r)
        }
    }
}
