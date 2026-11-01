import Foundation

/// FUSION DES DOTS — un Dot « multi-rôles » exécute plusieurs missions proches dans UN passage (moins d'appels, moins de charge).
/// Calibrage anti-confusion : un rôle = une section titrée avec son propre STATUT, ses propres sources, aucune fusion de chiffres entre rôles ;
/// plus d'étapes d'outils et plus de longueur que les Dots simples ; les anciens Dots sont MIS EN PAUSE (jamais supprimés) → retour arrière possible.
public enum DotMerge {
    struct Group {
        let id: String, name: String, emoji: String, color: String
        let roles: [String]            // ids des anciens Dots dont la mission est reprise
        let schedule: String
        let tools: [String]
        let quiet: Bool
    }

    static let groups: [Group] = [
        Group(id: "boites", name: "Boîtes & agenda", emoji: "📬", color: "#8b5cf6", roles: ["courrier", "agenda", "imp-veille-messages"], schedule: "07:45,12:30,17:00",
              tools: ["mail_unread", "draft_reply", "calendar", "reminders", "recall", "remember", "cafu_format_email"], quiet: false),
        Group(id: "portefeuille", name: "Portefeuille BRVM", emoji: "💹", color: "#22c55e", roles: ["brvm", "brvm-dividendes", "momo-releve"], schedule: "lun-ven 09:30,16:30",
              tools: ["brvm_cours", "web_search", "web_fetch", "recall", "know", "momo"], quiet: false),
        Group(id: "veille-radar", name: "Veille & radar", emoji: "📡", color: "#10b981", roles: ["veille", "radar-humanitaire", "imp-bulletin-afrique"], schedule: "07:30,18:00",
              tools: ["web_search", "web_fetch", "flux_titres", "recall", "remember", "know"], quiet: false),
        Group(id: "publication", name: "Publication", emoji: "✍️", color: "#f472b6", roles: ["contenu", "social"], schedule: "lun-ven 10:00",
              tools: ["know", "recall", "web_search", "web_fetch", "draft_reply", "cafu_format_document"], quiet: false),
        Group(id: "systeme", name: "Système & santé", emoji: "🩺", color: "#06b6d4", roles: ["ops", "mac", "gardien"], schedule: "08:20,14:20,20:20",
              tools: ["system", "processes", "app", "recall", "ask_assistant"], quiet: true),
        Group(id: "pilotage", name: "Pilotage & projets", emoji: "🧭", color: "#fb923c", roles: ["projet", "analytics"], schedule: "lun-ven 08:30",
              tools: ["calendar", "reminders", "recall", "remember", "know", "read_file", "system", "web_search", "web_fetch"], quiet: false),
    ]
    /// Dots simplement mis en pause (redondants ou sans tâche planifiable) sans être repris dans un groupe.
    static let retiredOnly: [String] = ["sahel", "chercheur", "redacteur", "code"]
    static let manual = "Les rôles de cette liste ne tournent plus seuls : « sahel » (doublon de Cap du jour), « chercheur » et « rédacteur » (à la demande, avec un sujet)."

    static func group(_ id: String) -> Group? { groups.first { $0.id == id } }
    static func isMerged(_ id: String) -> Bool { group(id) != nil }

    private static let fallbackRole: [String: (String, String)] = [
        "imp-bulletin-afrique": ("Bulletin d'alerte précoce Afrique : alertes politiques, sécuritaires et économiques récentes (Sahel, Afrique de l'Ouest).",
                                 "3 à 5 alertes : fait, pays, date, source ; « aucune alerte vérifiée » sinon."),
        "imp-veille-messages": ("Messagerie : repérer dans Outlook, Gmail et Teams (outil mail_unread, instantanés lus en arrière-plan) ce qui est urgent ou attend une réponse.",
                                "Liste courte par boîte : expéditeur, objet, urgence ; aucun brouillon (sauf UN, si un mail urgent attend une réponse d'Ahadi et qu'aucun brouillon n'existe pour cet objet) ; boîte « NON LU » signalée telle quelle.")
    ]

    /// Fiche de mission composée à partir des fiches verrouillées des anciens Dots : une section par rôle.
    static func spec(for id: String) -> DotCharter.Spec? {
        guard let g = group(id) else { return nil }
        var m: [String] = [], l: [String] = [], s: [String] = []
        for (i, r) in g.roles.enumerated() {
            let sp = DotCharter.specs[r]; let fb = fallbackRole[r]
            let title = "RÔLE \(i + 1) « \(r) »"
            m.append("\(title) — \(sp?.mission ?? fb?.0 ?? r)")
            l.append("\(title) : \(sp?.livrable ?? fb?.1 ?? "rapport factuel")")
            s.append("\(title) : \(sp?.succes ?? "faits sourcés et datés")")
        }
        let n = g.roles.count
        return DotCharter.Spec(
            mission: "Tu cumules \(n) rôles. Exécute-les UN PAR UN, dans l'ordre, sans jamais mélanger leurs données. " + m.joined(separator: " ‖ "),
            livrable: "Ligne 1 : STATUT global. Puis \(n) sections, chacune titrée « ## <nom du rôle> » avec sa propre ligne « STATUT : OK/PARTIEL/ÉCHEC », ses sources et dates, 4 lignes maximum. Contenu par rôle — " + l.joined(separator: " ‖ ") + " Termine par « À TOI : » (une ligne).",
            succes: "STATUT global OK seulement si TOUS les rôles sont OK ; sinon PARTIEL en nommant le(s) rôle(s) incomplet(s). Par rôle — " + s.joined(separator: " ‖ "),
            echec: "Un rôle sans source : écris-le dans SA section (PARTIEL + cause) et passe au rôle suivant : un rôle en panne ne doit jamais bloquer ni faire échouer les autres. ÉCHEC global seulement si tous les rôles échouent. Aucune donnée d'un rôle n'est utilisée dans un autre." + (g.quiet ? " Si TOUS les rôles sont sans anomalie : réponds exactement « RAS »." : ""),
            task: "Exécute maintenant tes \(n) rôles dans l'ordre (" + g.roles.joined(separator: ", ") + "), chacun avec ses outils, puis rends le rapport sectionné selon ta fiche.")
    }

    static func definition(_ g: Group) -> [String: Any] {
        var d: [String: Any] = ["id": g.id, "name": g.name, "emoji": g.emoji, "color": g.color,
            "role": "Dot multi-rôles (\(g.roles.joined(separator: " + "))) : un seul passage, une section et un statut par rôle.",
            "tools": g.tools, "brain": "deep", "schedule": g.schedule, "paused": false, "merged_from": g.roles,
            "prompt": "Tu cumules les rôles : " + g.roles.joined(separator: ", ") + ". Suis ta fiche de mission verrouillée : une section par rôle, un statut par rôle, rien de mélangé."]
        if g.quiet { d["quiet_ok"] = true }
        return d
    }

    /// Migration unique (« dots_fusion_v1 ») : crée les Dots fusionnés, met les anciens en pause. Renvoie true si la liste a changé.
    static func migrate(_ l: inout [[String: Any]]) -> Bool {
        var changed = false
        for g in groups {
            if !l.contains(where: { ($0["id"] as? String) == g.id }) { l.append(definition(g)); changed = true }
            for r in g.roles {
                guard let i = l.firstIndex(where: { ($0["id"] as? String) == r }), r != g.id else { continue }
                l[i]["prev_schedule"] = l[i]["schedule"] ?? ""; l[i]["schedule"] = ""; l[i]["paused"] = true; l[i]["merged_into"] = g.id; changed = true
            }
        }
        for r in retiredOnly {
            if let i = l.firstIndex(where: { ($0["id"] as? String) == r }) { l[i]["prev_schedule"] = l[i]["schedule"] ?? ""; l[i]["schedule"] = ""; l[i]["paused"] = true; l[i]["merged_into"] = "(à la demande)"; changed = true }
        }
        return changed
    }

    /// Doublons retirés pour de bon (mis à la corbeille « dots_corbeille », récupérables) : anciens rôles fusionnés + Dots redondants.
    static let duplicates: [String] = ["sahel", "imp-rapport-matin", "imp-fin-journee"]
    static func cleanup(_ l: inout [[String: Any]], _ settings: Settings) {
        let gone = Set(groups.flatMap { $0.roles } + duplicates)
        var bin = settings.get("dots_corbeille", [[String: Any]]())
        for d in l where gone.contains(d["id"] as? String ?? "") { bin.append(d) }
        l.removeAll { gone.contains($0["id"] as? String ?? "") }
        settings.set(["dots_corbeille": Array(bin.suffix(60))])
    }

    /// 3e temps : « code » n'a accès à aucun fichier → il redevient un Dot à la demande (restauré de la corbeille, en pause).
    static func restoreCode(_ l: inout [[String: Any]], _ settings: Settings) {
        guard !l.contains(where: { ($0["id"] as? String) == "code" }) else { return }
        var bin = settings.get("dots_corbeille", [[String: Any]]())
        guard let i = bin.firstIndex(where: { ($0["id"] as? String) == "code" }) else { return }
        var d = bin.remove(at: i); d["paused"] = true; d["schedule"] = ""; d["merged_into"] = "(à la demande)"; l.append(d)
        settings.set(["dots_corbeille": bin])
    }

    // MARK: FLOTTE V1 — 25/10/2026 (demande d'Ahadi : « vois s'il est pertinent d'en avoir autant… »)
    // Audit complet : conseil_24-10/V5_X_ECLATS_AUDIT.md. Migration unique « eclats_flotte_v1 » (drapeau de
    // réglage, appelée par Dots.list) : 6 Éclats de fond réécrits (mission courte, horaire étalé, sortie au
    // format maison), rituels de l'âme ré-horodatés (seulement s'ils sont au parc, pause d'Ahadi respectée),
    // doublons RETIRÉS (pause + horaire vidé + motif ; définition gardée, réversible), Chercheur à la demande.
    // Les Éclats créés par Ahadi (formulaire « perso-* », imports inconnus) ne sont JAMAIS touchés ; seuls les
    // Éclats créés par l'assistant (created_by = assistant) qui doublonnent un Éclat de fond sont retirés.
    struct FleetMember {
        let id: String
        let name: String
        let emoji: String
        let color: String
        let role: String
        let schedule: String
        let tools: [String]
        let quiet: Bool
        let prompt: String
    }

    static let fleetV1: [FleetMember] = [
        FleetMember(id: "boites", name: "Boîtes & échéances", emoji: "📬", color: "#8b5cf6",
                    role: "Outlook, Gmail, Teams (canal Fundings compris), agenda et rappels : ne remonte que le nouveau qui compte — urgences, réponses attendues, échéances à 7 jours, conflits d'agenda. Silencieux sinon.",
                    schedule: "lun-ven 10:10,14:10,16:50",
                    tools: ["mail_unread", "mail_week", "teams_read", "calendar", "reminders", "recall", "know"], quiet: true,
                    prompt: "Lis les trois boîtes, l'agenda et les rappels ; ne remonte que le NOUVEAU qui demande l'attention d'Ahadi. Rien de nouveau : « RAS »."),
        FleetMember(id: "veille-radar", name: "Veille & radar", emoji: "📡", color: "#10b981",
                    role: "Signaux du jour pour CAFU : Sahel et Afrique de l'Ouest et du Centre (sécurité, humanitaire, déplacements, appels ReliefWeb/OCHA), Burkina Faso, IA utile. Sources de moins de 72 h.",
                    schedule: "lun-ven 08:15,15:15",
                    tools: ["flux_titres", "web_search", "web_fetch", "recall", "know"], quiet: true,
                    prompt: "Veille d'analyste CAFU : signaux nouveaux, datés et sourcés. Rien de nouveau vérifié : « RAS »."),
        FleetMember(id: "portefeuille", name: "Portefeuille BRVM", emoji: "💹", color: "#22c55e",
                    role: "Clôture BRVM : tes lignes SBIF, indices, mouvements de 3 % et plus, dividendes à 30 jours. Faits sourcés, jamais de conseil.",
                    schedule: "lun-ven 16:30",
                    tools: ["brvm_cours", "web_search", "web_fetch", "recall", "know", "momo"], quiet: false,
                    prompt: "Point de clôture factuel de la BRVM centré sur les lignes d'Ahadi. Aucun conseil d'achat ou de vente."),
        FleetMember(id: "systeme", name: "Santé du Mac & de Nova", emoji: "🩺", color: "#06b6d4",
                    role: "Mac (batterie, disque, mémoire, processus) et Nova (Éclats en échec, cerveaux, planification). Silencieux sauf anomalie mesurée.",
                    schedule: "08:50,19:40",
                    tools: ["system", "processes", "app", "recall"], quiet: true,
                    prompt: "Contrôle le Mac et la santé de Nova ; ne parle que d'une anomalie mesurée, sinon « RAS »."),
        FleetMember(id: "pilotage", name: "Projets & financements", emoji: "🧭", color: "#fb923c",
                    role: "Chaque lundi : la semaine en un écran — échéances à 14 jours par projet (CAFU/GHO, financements, hackathon, BRVM, maison), ce qui bloque, la prochaine action, et l'arbitrage du temps de la semaine.",
                    schedule: "lun 08:35",
                    tools: ["calendar", "reminders", "mail_week", "teams_read", "recall", "know", "read_file"], quiet: false,
                    prompt: "Plan de la semaine par projet suivi : échéances datées, blocages, prochaine action de 30 minutes."),
        FleetMember(id: "croissance", name: "Croissance de Nova", emoji: "🌱", color: "#84cc16",
                    role: "Chaque samedi : apprend des échecs de la semaine et propose au plus 2 améliorations vérifiées. Ne modifie jamais rien.",
                    schedule: "sam 11:10",
                    tools: ["app", "web_search", "web_fetch", "recall", "remember", "know"], quiet: true,
                    prompt: "Revue hebdomadaire : leçons des échecs de la semaine (app runs, actions), au plus 2 idées vérifiées. Rien de neuf : « RAS »."),
    ]

    /// Horaires étalés des Éclats de rythme (rituels de l'âme, arbitrage) — appliqués seulement s'ils sont au parc.
    static let rescheduleV1: [String: String] = [
        "imp-rituel-sparring": "lun-ven 07:10",
        "imp-rituel-contact": "lun 09:20",
        "imp-rituel-post-afrique": "mer 09:30",
        "imp-rituel-revue-cash": "ven 17:05",
        "imp-rituel-fermeture": "ven 18:40",
        "imp-rituel-dictee": "21:15",
    ]

    /// Éclats retirés (gardés au parc, en pause, horaire vidé, motif lisible).
    static let retiredV1: [String: String] = [
        "publication": "retiré — aucun brouillon automatique (ordre du 23/10) ; le post de la semaine reste le rituel « Post Afrique » du mercredi",
        "code": "retiré — sans accès utile aux projets ; les améliorations de Nova passent par « Croissance de Nova »",
        "redacteur": "retiré — la rédaction se fait sur demande, en conversation avec Nova (aucun brouillon automatique)",
        "bilan": "retiré — absorbé par la Fermeture du soir (brief de 18:00)",
        "capdujour": "retiré — absorbé par le Brief du matin (section CAP DU JOUR, 07:30)",
        "sahel": "retiré — doublon du Cap du jour",
        "brief-audio": "retiré — doublon du Brief du matin",
        "imp-rapport-matin": "retiré — doublon du Brief du matin",
        "imp-fin-journee": "retiré — doublon de la Fermeture du soir",
        "imp-rituel-brvm": "retiré — c'est « Portefeuille BRVM » (lun-ven 16:30) qui fait la veille BRVM de clôture",
        "imp-rituel-chose-apprise": "retiré — la chose apprise devient la 4e question de « Fermeture de semaine »",
        "imp-arbitrage-cafu-brvm": "retiré — l'arbitrage du temps entre CAFU et BRVM devient la section « Arbitrage » du plan du lundi (« Projets & financements »)",
        "courrier": "retiré — fusionné dans « Boîtes & échéances »",
        "agenda": "retiré — fusionné dans « Boîtes & échéances »",
        "imp-veille-messages": "retiré — fusionné dans « Boîtes & échéances »",
        "veille": "retiré — fusionné dans « Veille & radar »",
        "radar-humanitaire": "retiré — fusionné dans « Veille & radar »",
        "imp-bulletin-afrique": "retiré — fusionné dans « Veille & radar »",
        "brvm": "retiré — fusionné dans « Portefeuille BRVM »",
        "brvm-dividendes": "retiré — fusionné dans « Portefeuille BRVM »",
        "momo-releve": "retiré — à la demande : l'analyse d'un relevé mobile money se fait en conversation",
        "mac": "retiré — fusionné dans « Santé du Mac & de Nova »",
        "ops": "retiré — fusionné dans « Santé du Mac & de Nova »",
        "gardien": "retiré — fusionné dans « Santé du Mac & de Nova »",
        "projet": "retiré — fusionné dans « Projets & financements »",
        "analytics": "retiré — fusionné dans « Projets & financements »",
        "contenu": "retiré — aucun brouillon automatique (ordre du 23/10)",
        "social": "retiré — aucun brouillon automatique (ordre du 23/10)",
    ]

    /// Éclats gardés actifs sans horaire : on les lance à la main, avec un sujet.
    static let onDemandV1: [String] = ["chercheur"]

    /// Éclats créés par l'assistant qui doublonnent un Éclat de fond : mot du NOM → Éclat qui les absorbe.
    static let absorbV1: [(String, [String])] = [
        ("boites", ["mail", "courrier", "boite", "echeance", "agenda", "teams", "inbox"]),
        ("systeme", ["sante", "systeme", "gardien", " mac"]),
        ("veille-radar", ["veille", "radar", "bulletin", "actualite"]),
        ("portefeuille", ["brvm", "bourse", "dividende"]),
    ]

    static func fold(_ s: String) -> String {
        return s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
    }

    /// Retire un Éclat sans le supprimer. Renvoie vrai si quelque chose a changé.
    static func retire(_ d: inout [String: Any], _ why: String, _ stamp: String) -> Bool {
        let already: Bool = (d["retired"] as? Bool) == true && (d["paused"] as? Bool) == true
        if already { return false }
        let sch: String = (d["schedule"] as? String) ?? ""
        if !sch.isEmpty { d["prev_schedule"] = sch }
        d["schedule"] = ""
        d["paused"] = true
        d["retired"] = true
        d["retired_motif"] = why
        d["retired_at"] = stamp
        d.removeValue(forKey: "paused_by")
        d.removeValue(forKey: "persona")
        return true
    }

    /// Ligne « CORRECTION SANTÉ DES DOTS » posée par DotCare pendant la panne de crédits : retirée de l'ordre permanent (le reste est gardé).
    static func stripCareCorrection(_ dir: String) -> String {
        var kept: [String] = []
        for raw in dir.split(separator: "\n", omittingEmptySubsequences: false) {
            let line: String = String(raw)
            if line.hasPrefix("CORRECTION SANTÉ DES DOTS") { continue }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Applique la flotte V1 à la liste du magasin. Renvoie les notes (journal de la boîte noire).
    static func applyFleetV1(_ l: inout [[String: Any]]) -> [String] {
        var notes: [String] = []
        let stamp: String = nowISO()
        let core: Set<String> = Set(fleetV1.map { (m: FleetMember) -> String in m.id })
        // 1) Éclats de fond : réécrits et actifs (créés s'ils manquent).
        for m in fleetV1 {
            let found: Int? = l.firstIndex(where: { ($0["id"] as? String) == m.id })
            var d: [String: Any] = [:]
            if let i = found { d = l[i] } else { d["id"] = m.id; d["brain"] = "auto"; d["created_by"] = "nova" }
            if d["fleet_v0"] == nil {
                var snap: [String: Any] = [:]
                snap["name"] = d["name"] ?? ""
                snap["schedule"] = d["schedule"] ?? ""
                snap["prompt"] = d["prompt"] ?? ""
                snap["role"] = d["role"] ?? ""
                snap["tools"] = d["tools"] ?? [String]()
                snap["paused"] = d["paused"] ?? false
                d["fleet_v0"] = snap
            }
            d["name"] = m.name
            d["emoji"] = m.emoji
            d["color"] = m.color
            d["role"] = m.role
            d["schedule"] = m.schedule
            d["tools"] = m.tools
            d["prompt"] = m.prompt
            d["quiet_ok"] = m.quiet
            d["paused"] = false
            for k in ["pause_auto", "paused_until", "pause_motif", "paused_by", "merged_into", "retired", "retired_motif", "retired_at", "on_demand", "prev_schedule", "persona"] {
                d.removeValue(forKey: k)
            }
            let brain: String = (d["brain"] as? String) ?? ""
            if !brain.isEmpty && !brain.hasPrefix("spark") && !brain.hasPrefix("wonder") && brain != "auto" && brain != "deep" && brain != "bulk" { d["brain"] = "auto" }   // version Meta : un cerveau hors catalogue Meta retombe sur « auto »
            if let dir = d["directive"] as? String { d["directive"] = stripCareCorrection(dir) }
            d["fleet_v1"] = stamp
            if let i = found { l[i] = d } else { l.append(d) }
            notes.append(m.id + " : " + m.schedule)
        }
        // 2) Retraits, à la demande, horaires étalés, absorption des doublons créés par l'assistant.
        for i in l.indices {
            guard let id = l[i]["id"] as? String else { continue }
            if core.contains(id) { continue }
            if let why = retiredV1[id] {
                if retire(&l[i], why, stamp) { notes.append(id + " retiré") }
                continue
            }
            if onDemandV1.contains(id) {
                let sch: String = (l[i]["schedule"] as? String) ?? ""
                if !sch.isEmpty { l[i]["prev_schedule"] = sch }
                l[i]["schedule"] = ""
                l[i]["paused"] = false
                l[i]["on_demand"] = true
                for k in ["merged_into", "retired", "retired_motif", "retired_at", "pause_auto", "paused_until", "pause_motif"] { l[i].removeValue(forKey: k) }
                notes.append(id + " à la demande")
                continue
            }
            if let sch = rescheduleV1[id] {
                let old: String = (l[i]["schedule"] as? String) ?? ""
                if old != sch {
                    if l[i]["fleet_v0_schedule"] == nil { l[i]["fleet_v0_schedule"] = old }
                    l[i]["schedule"] = sch
                    notes.append(id + " : " + old + " → " + sch)
                }
                if id == "imp-rituel-fermeture", let p = l[i]["prompt"] as? String, !fold(p).contains("chose apprise") {
                    l[i]["prompt"] = p + " Ajoute une 4e question : la chose apprise de la semaine (une leçon d'Ahadi, une leçon de Nova, une phrase chacune)."
                }
                continue
            }
            let byAssistant: Bool = (l[i]["created_by"] as? String) == "assistant"
            let isDelegation: Bool = (l[i]["delegation"] as? Bool) == true
            if !byAssistant || isDelegation { continue }
            let nm: String = " " + fold((l[i]["name"] as? String) ?? id)
            for (target, words) in absorbV1 {
                var hit: Bool = false
                for w in words where nm.contains(w) { hit = true; break }
                if !hit { continue }
                let tname: String = fleetV1.first(where: { $0.id == target })?.name ?? target
                if retire(&l[i], "retiré — doublon de « " + tname + " » (créé par l'assistant)", stamp) { notes.append(id + " absorbé par " + target) }
                break
            }
        }
        return notes
    }

    /// DotCare repart de zéro pour les Éclats de fond : les échecs de la panne de crédits du 25/10 ne comptent plus.
    static func resetCareV1() {
        let f: JSONFile = JSONFile("dot_care.json")
        var st: [String: Any] = f.read(default: [String: Any]())
        let stamp: String = nowISO()
        for m in fleetV1 {
            var e: [String: Any] = (st[m.id] as? [String: Any]) ?? [String: Any]()
            e["seen"] = stamp
            e["paused_by_care"] = false
            st[m.id] = e
        }
        f.write(st)
    }

    final class Box: @unchecked Sendable { var out: [[String: Any]] = []; let lock = NSLock() }
    /// Test unique : les 6 Dots fusionnés tournent EN MÊME TEMPS, sans bulle ni interruption ; le bilan est écrit dans ~/spark-local/Nova2/fusion_test.json.
    static func runAllTest(_ dots: Dots, only: [String]? = nil, file: String = "fusion_test.json") {
        let box = Box(); let g = DispatchGroup()
        for gr in groups where only == nil || only!.contains(gr.id) {
            g.enter()
            Thread.detachNewThread {
                let t0 = Date(); let r = dots.run(id: gr.id, task: "", cancel: { false }) { _ in }
                let txt = (r?["result"] as? String) ?? ""
                box.lock.lock()
                box.out.append(["dot": gr.id, "status": DotCharter.status(of: txt) ?? "?", "secondes": Int(Date().timeIntervalSince(t0)), "etapes": (r?["steps"] as? [Any])?.count ?? 0, "brain": r?["brain"] ?? "", "rapport": String(txt.prefix(1800))])
                box.lock.unlock(); g.leave()
            }
        }
        g.notify(queue: .global()) {
            let path = NSHomeDirectory() + "/spark-local/Nova2/" + file
            if let data = try? JSONSerialization.data(withJSONObject: ["ts": nowISO(), "resultats": box.out], options: [.prettyPrinted]) { try? data.write(to: URL(fileURLWithPath: path)) }
        }
    }
}
