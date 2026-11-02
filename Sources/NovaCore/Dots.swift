import Foundation

/// Un Dot = un agent permanent : rôle, outils autorisés (liste blanche appliquée à l'exécution), cerveau préféré, horaire facultatif.
public final class Dots {
    let router: Router, tools: Tools, settings: Settings
    let store = JSONFile("dots.json"), runs = JSONFile("dots_runs.json")
    /// SPARK8-D : sérialise les séquences lire-modifier-écrire de dots_runs.json (départ et complétion).
    private static let runsLock = NSLock()

    // MARK: arrêt réel d'une exécution (VAGUE 2 FIABILITÉ, 24/10)
    // Registre des runs EN VOL (runId → Éclat, départ) et jetons d'arrêt par runId. Le jeton est lu par
    // le `cancel` passé à Agent.run (vérifié entre chaque étape, et par le flux du cerveau) : un Stop
    // interrompt réellement l'agent au prochain point de contrôle. Le registre est vidé à la fin du run
    // (defer) : aucun jeton ne survit à son exécution (l'ancien DotScheduler.cancelled n'était jamais vidé).
    static let liveLock = NSLock()
    nonisolated(unsafe) static var liveRuns: [String: (dot: String, since: String)] = [:]
    nonisolated(unsafe) static var stopAsked: Set<String> = []
    static func liveBegin(runId: String, dot: String) {
        liveLock.lock(); liveRuns[runId] = (dot: dot, since: nowISO()); liveLock.unlock()
    }
    static func liveEnd(runId: String) {
        liveLock.lock(); liveRuns.removeValue(forKey: runId); stopAsked.remove(runId); liveLock.unlock()
    }
    static func isStopAsked(_ runId: String) -> Bool {
        liveLock.lock(); defer { liveLock.unlock() }
        return stopAsked.contains(runId)
    }
    /// Runs en vol d'un Éclat (vide = rien ne tourne pour lui).
    public static func liveRunIds(dot: String) -> [String] {
        liveLock.lock(); defer { liveLock.unlock() }
        var out: [String] = []
        for (rid, v) in liveRuns where v.dot == dot { out.append(rid) }
        return out.sorted()
    }
    /// Demande l'arrêt d'un run précis (`run`) ou de tous les runs en vol d'un Éclat (`dot`). Retourne les runIds visés (vide = rien en vol).
    public static func requestStop(run: String, dot: String) -> [String] {
        liveLock.lock(); defer { liveLock.unlock() }
        var targets: [String] = []
        if !run.isEmpty, liveRuns[run] != nil { targets.append(run) }
        if !dot.isEmpty {
            for (rid, v) in liveRuns where v.dot == dot && !targets.contains(rid) { targets.append(rid) }
        }
        for rid in targets { stopAsked.insert(rid) }
        return targets.sorted()
    }

    public init(router: Router, tools: Tools, settings: Settings) {
        self.router = router; self.tools = tools; self.settings = settings
        Tools.assistHook = { [weak self] q in self?.askAssistant(q) ?? "Assistant indisponible." }   // un Dot bloqué sollicite l'assistant principal
    }

    /// Méthode de travail commune à tous les Dots : expertise du domaine, outils d'abord, plan B, puis appel à l'assistant avant d'abandonner.
    static let method = "MÉTHODE DE PRO : (1) Tu es un expert senior de ton domaine : applique les usages et critères du métier, pas des généralités. (2) Choisis d'abord les outils les mieux adaptés (liste ci-dessus) et obtiens des FAITS réels. (3) Si un outil échoue ou ne donne rien, change d'approche (autre requête, autre source, autre outil) — au moins 2 essais différents. (4) Si tu restes bloqué, si tu ignores COMMENT faire, ou si la tâche dépasse tes outils : appelle ask_assistant avec une question précise (ce que tu cherches, ce que tu as déjà essayé) ; l'assistant principal de Nova a tous les outils et l'administration complète de Nova ; reprends sa réponse et termine ton rapport avec le résultat. (5) Ne conclus jamais « impossible » ni « non disponible » sans avoir sollicité l'assistant. (6) QUESTION DE SUIVI : l'essentiel est déjà dans le contexte fourni — réponds d'abord DIRECTEMENT à partir de ce contexte (c'est rapide) ; n'utilise des outils que si la réponse n'y est pas."

    /// Méthode, carte de Nova, tableau de bord de l'équipe, ordres du chef d'orchestre : tout ce qu'un Dot doit savoir avant d'agir.
    func chefBlock(_ d: [String: Any]) -> String {
        var s: String = Dots.method + "\n" + NovaMap.text + NovaMap.dashboard()
        if let o = d["directive"] as? String, !o.isEmpty { s += "\nORDRE PERMANENT DU CHEF D'ORCHESTRE (assistant) pour toi : " + o }
        let g: String = settings.get("chef_consignes", "")
        if !g.isEmpty { s += "\nCONSIGNE GÉNÉRALE (assistant/utilisateur) pour tous les Dots : " + g }
        s += "\nTU RENDS COMPTE à l'assistant : ton rapport final est lu par lui ; tu peux lire l'état de Nova avec l'outil app (lecture seule : status, dots, equipe, runs, settings…). Pour toute modification, passe par ask_assistant.\n"
        return s
    }

    nonisolated(unsafe) static var assistBusy = false   // PHASE 1 (relu, protégé) : sous Dots.assistLock (askAssistant)
    static let assistLock = NSLock()
    /// L'assistant principal travaille pour un Dot (un seul appel à la fois, pas de récursion, 100 s maximum).
    func askAssistant(_ q: String) -> String {
        let question = q.trimmingCharacters(in: .whitespacesAndNewlines); if question.isEmpty { return "Question vide : précise ce dont tu as besoin." }
        Dots.assistLock.lock(); if Dots.assistBusy { Dots.assistLock.unlock(); return "L'assistant est déjà sollicité par un autre Dot : réessaie dans un instant ou conclus avec ce que tu as." }
        Dots.assistBusy = true; Dots.assistLock.unlock()
        defer { Dots.assistLock.lock(); Dots.assistBusy = false; Dots.assistLock.unlock() }
        let sys = Persona.system(assistantName: "Nova", title: settings.get("user_title", "Capitaine"), memory: tools.memory.promptBlock(max: 25, query: question), voice: false, tools: true,
                                 extra: "Un DOT (agent spécialisé) est bloqué et te sollicite. " + NovaMap.text + " Tu es l'assistant principal : tu as les outils de lecture, de recherche, d'écriture locale et `app` (pas de shell, d'AppleScript, d'écran ni d'envoi pour un Dot) (lecture et administration de Nova : état, Dots, réglages, historique, mémoire). Résous TOI-MÊME sa question avec tes outils et rends une réponse CONCRÈTE et COMPLÈTE : le résultat, ou la méthode exacte étape par étape s'il doit finir lui-même. Ne pose pas de question en retour ; n'envoie rien, ne paie rien. Sans préambule, 12 lignes maximum.")
        var text = ""; let deadline = Date().addingTimeInterval(180)
        let agent = Agent(router: router, tools: tools)
        // WP5 (B/M) : l'appui d'un Dot n'élève pas ses droits — mêmes capacités qu'un passage sans surveillance (pas de shell,
        // d'AppleScript, d'écran ni d'envoi), liste d'outils réduite en conséquence (Agent.run).
        agent.run(messages: [ChatMsg("user", question)], system: sys, mode: "deep", preferred: nil, maxTokens: 1200, useTools: true, maxSteps: 8,
                  allowed: nil, actor: "Assistant (appui d'un Dot)", cancel: { Date() > deadline }, capabilities: ToolCapabilities.unattended) { ev in
            switch ev { case .delta(let t): text += t; case .draftReset: text = ""; case .tool: text = ""; default: break }
        }
        for mark in ["<｜DSML", "<|DSML", "<tool_call", "<function_calls"] { if let r = text.range(of: mark) { text = String(text[..<r.lowerBound]) } }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "L'assistant n'a pas pu répondre (délai ou cerveau indisponible). Conclus avec ce que tu as, en précisant ce qui manque." : text
    }

    /// WP5 (B) : capacités d'un passage de Dot. Planifié = sans surveillance (lecture, écriture locale, réseau) ; à la main ou
    /// inscrit par Ahadi dans « dots_shell_sans_surveillance » (réglage réservé au propriétaire) = + exécution.
    public static func runCapabilities(id: String, ordered: Bool, optIn: [String]) -> Set<ToolCapability> {
        var c: Set<ToolCapability> = ToolCapabilities.unattended
        if ordered || optIn.contains(id) { c.insert(.exec) }
        return c
    }

    public static let defaults: [[String: Any]] = baseDefaults + extraDefaults
    static let extraDefaults: [[String: Any]] = [
        ["id": "analytics", "name": "Analytique", "emoji": "📊", "color": "#84cc16", "role": "Suit les indicateurs, analyse les données et les fichiers, repère les opportunités, prépare des rapports chiffrés.",
         "tools": ["know", "recall", "read_file", "web_search", "web_fetch", "system"], "brain": "auto", "schedule": "lun-ven 18:15",
         "prompt": "Analyse ce que tu peux MESURER : fichiers lisibles du dossier suivi (know), mémoire (recall), état du Mac (system), cours/indicateurs publics (web_search + web_fetch). Donne 3 constats chiffrés avec source et date, 1 opportunité, 1 risque. Aucun chiffre inventé."],
        ["id": "contenu", "name": "Contenu", "emoji": "✍️", "color": "#facc15", "role": "Articles, pages, contenus sociaux, optimisation SEO — en brouillon, dans ton ton.",
         "tools": ["know", "recall", "web_search", "web_fetch", "draft_reply", "cafu_format_document"], "brain": "auto", "schedule": "lun-ven 10:00",
         "prompt": "Propose UN contenu utile aujourd'hui (idée tirée de la mémoire, de know ou d'une actualité vérifiée par web_search) : titre, accroche, plan en 4 points, premier paragraphe rédigé à mon ton, 3 mots-clés SEO. Enregistre le brouillon avec draft_reply. Ne publie rien."],
        ["id": "social", "name": "Social", "emoji": "💬", "color": "#f472b6", "role": "Prépare publications, réponses et planning pour tes réseaux ; suit les résultats. Ne publie jamais seul.",
         "tools": ["know", "recall", "web_search", "draft_reply"], "brain": "auto", "schedule": "lun-ven 11:00",
         "prompt": "Prépare 2 publications (LinkedIn / Facebook) alignées sur mon activité connue (recall, know), avec heure de publication proposée. Livre-les comme brouillons (draft_reply). Rappelle que je publie moi-même."],
        ["id": "code", "name": "Code", "emoji": "💻", "color": "#6366f1", "role": "Lit les projets, repère les bugs et la dette, propose des correctifs et des automatisations. Lecture seule.",
         "tools": ["read_file", "know", "recall", "web_search", "web_fetch"], "brain": "deep", "schedule": "lun-ven 09:00",
         "prompt": "Parcours le dossier suivi (know sur « projet », « erreur », « TODO ») et lis les fichiers pertinents. Signale 1 à 3 problèmes RÉELS (fichier, ligne si connue, cause probable) et la correction proposée. Ne modifie aucun fichier."],
        ["id": "projet", "name": "Projet", "emoji": "✅", "color": "#fb923c", "role": "Planifie, suit l'avancement, coordonne les échéances et te tient au courant.",
         "tools": ["calendar", "reminders", "recall", "remember", "know", "cafu_format_document"], "brain": "auto", "schedule": "08:30",
         "prompt": "Fais le point projets : échéances des 7 prochains jours (calendar, reminders), ce qui est bloqué, la prochaine action pour chaque projet connu (recall, know). Liste courte, priorisée."],
        ["id": "ops", "name": "Opérations", "emoji": "⚙️", "color": "#38bdf8", "role": "Processus, fichiers, données, apps du Mac : surveille et range ce qui peut l'être. Rien n'est supprimé.",
         "tools": ["system", "processes", "read_file", "recall"], "brain": "auto", "schedule": "21:00",
         "prompt": "Vérifie l'état du Mac et les processus gourmands (system, processes). Propose au plus 3 actions de maintenance concrètes, sans rien exécuter. Si tout va bien, réponds « RAS ».", "quiet_ok": true],
    ]
    static let baseDefaults: [[String: Any]] = [
        ["id": "courrier", "name": "Courrier", "emoji": "✉️", "color": "#8b5cf6", "role": "Lit les mails non lus, classe par urgence, prépare des brouillons. N'envoie jamais.",
         "tools": ["mail_unread", "draft_reply", "recall", "remember", "cafu_format_email"], "brain": "auto", "schedule": "lun-ven 08:00,12:30,17:00",
         "prompt": "Utilise mail_unread. Classe les mails en URGENT / À TRAITER / INFO selon des critères que tu expliques (expéditeur connu en mémoire, mot « urgent », échéance datée). Pour les 3 plus importants, prépare un brouillon de réponse AU GABARIT avec cafu_format_email et \"brouillon\": true (le formateur applique le gabarit verrouillé et calcule la coche ; corrige tout item en échec qu'il signale et régénère). Résume : combien, lesquels, ce qui est prêt à valider."],
        ["id": "agenda", "name": "Agenda", "emoji": "📅", "color": "#3b82f6", "role": "Plan du jour : rendez-vous, rappels, conflits.",
         "tools": ["calendar", "reminders", "recall"], "brain": "auto", "schedule": "07:45,13:00",
         "prompt": "Lis calendar et reminders. Donne le plan des prochaines 24 h, signale les chevauchements d'horaires que tu constates réellement, et ce qu'il faut préparer."],
        ["id": "veille", "name": "Veille", "emoji": "📡", "color": "#10b981", "role": "Cherche et synthétise l'actualité sur les sujets suivis, avec sources datées.",
         "tools": ["web_search", "web_fetch", "recall", "remember"], "brain": "auto", "schedule": "07:30,18:00",
         "prompt": "Pour chaque sujet suivi (cherche d'abord recall « sujets suivis »; sinon BRVM, Burkina Faso, IA), fais une web_search puis ouvre au besoin la meilleure page avec web_fetch. Résume en puces avec source ET date. Aucun chiffre sans source."],
        ["id": "chercheur", "name": "Chercheur", "emoji": "🔎", "color": "#f59e0b", "role": "Recherche approfondie sur une question, rapport sourcé.",
         "tools": ["web_search", "web_fetch", "read_file", "recall"], "brain": "deep", "schedule": "lun-ven 17:00",
         "prompt": "Réponds à la tâche donnée par une recherche rigoureuse : plusieurs requêtes, lecture des pages utiles, recoupement. Conclus par les sources."],
        ["id": "brvm", "name": "BRVM", "emoji": "📈", "color": "#22c55e", "role": "Veille factuelle du marché BRVM et des sociétés cotées. Aucun conseil d'investissement.", "quiet_ok": false,
         "tools": ["web_search", "web_fetch", "recall", "know"], "brain": "auto", "schedule": "lun-ven 09:30,16:30",
         "prompt": "Fais le point FACTUEL sur la BRVM : indice BRVM Composite et BRVM 10, plus fortes hausses/baisses, annonces de sociétés cotées (dividendes, résultats). Utilise web_search puis web_fetch sur la meilleure source. Chaque chiffre porte sa source ET sa date ; si un cours n'est pas trouvé, dis-le, ne l'invente jamais. Si recall ou know révèlent les valeurs suivies par l'utilisateur, commence par elles. Pas de conseil d'achat ou de vente : des faits."],
        ["id": "mac", "name": "Santé du Mac", "emoji": "🩺", "color": "#06b6d4", "role": "Surveille batterie, mémoire, disque, charge. Ne se manifeste que s'il y a un problème.", "quiet_ok": true,
         "tools": ["system"], "brain": "auto", "schedule": "08:00,14:00,20:00",
         "prompt": "Appelle l'outil system. S'il n'y a RIEN d'anormal (batterie > 20 % ou sur secteur, disque > 10 % libre, mémoire < 90 %), réponds uniquement « RAS ». Sinon, annonce en 2 phrases le problème mesuré et une action concrète. Ne signale que ce qui est mesuré."],
        ["id": "redacteur", "name": "Rédacteur", "emoji": "✍️", "color": "#ec4899", "role": "Rédige messages Teams et mails dans TA charte (salutation, contexte, points clés, action en gras, clôture). Brouillon uniquement.", "quiet_ok": false,
         "tools": ["know", "recall", "draft_reply", "web_search", "cafu_format_document", "cafu_format_email"], "brain": "auto", "schedule": "lun-ven 17:30",
         "prompt": "Rédige le message Teams demandé AU STANDARD VERROUILLÉ : bloc fluide (pas de liste pour un message court), une phrase de contexte, la demande s'il y en a une — avec un opt-out explicite —, signé « — Ahadi ». Ni HTML, ni en-tête de mail, ni « Best, ». Produis le brouillon avec cafu_format_email {\"type\":\"teams\",\"destinataire\":<nom exact de la conversation>,\"brouillon\":true} : il entre dans la file avec channel=teams et sa coche mécanique (corrige tout item en échec signalé). N'ENVOIE RIEN : l'utilisateur valide et envoie lui-même depuis la carte Messages."],
    ]
    public func list() -> [[String: Any]] {
        var l = store.read(default: [[String: Any]]()); if l.isEmpty { store.write(Dots.defaults); l = Dots.defaults }
        // Migration unique : les Dots rédactionnels déjà enregistrés reçoivent les outils de la charte (mise en forme HTML locale, rien n'est envoyé).
        let cafu: [String: [String]] = ["contenu": ["cafu_format_document"], "projet": ["cafu_format_document"], "courrier": ["cafu_format_email"], "redacteur": ["cafu_format_document", "cafu_format_email"]]
        var changed = false
        for i in l.indices where l[i]["cafu_tools_v1"] == nil {
            guard let id = l[i]["id"] as? String, let add = cafu[id] else { continue }
            var t = (l[i]["tools"] as? [String]) ?? []; for x in add where !t.contains(x) { t.append(x) }
            l[i]["tools"] = t; l[i]["cafu_tools_v1"] = true; changed = true
        }
        // LOT ACL-DOTS (23/10) — héritage de fusion non réconcilié : la table DotMerge annonçait
        // pour « boites » les outils de son rôle courrier (draft_reply, cafu_format_email), mais
        // l'entrée vivante du magasin, créée avant cette table, ne les a jamais reçus — d'où le
        // refus « Outil non autorisé pour cet agent » du run du 23/10 07:08 (skill, cafu_format_email
        // et draft_reply refusés pendant la préparation du brouillon Amina Muse). Restitution
        // unique, par Dot, des outils de PRÉPARATION de son rôle : « skill » = lecture des méthodes
        // maison (gabarits) chargées avant de rédiger ; draft_reply et cafu_format_email ne font
        // qu'enregistrer un brouillon « à valider » (rien n'est envoyé : l'envoi reste l'action
        // séparée d'Ahadi, règle d'or n°2). Aucun outil d'envoi ou irréversible n'est accordé.
        let heritage: [String: [String]] = ["boites": ["draft_reply", "cafu_format_email", "skill"]]
        for i in l.indices where l[i]["acl_tools_v1"] == nil {
            guard let id = l[i]["id"] as? String, let add = heritage[id] else { continue }
            var t = (l[i]["tools"] as? [String]) ?? []; for x in add where !t.contains(x) { t.append(x) }
            l[i]["tools"] = t; l[i]["acl_tools_v1"] = true; changed = true
            _ = BlackBox.record(["tool": "acl_dots", "actor": "Dot " + ((l[i]["name"] as? String) ?? id), "why": "ACL-DOTS : héritage restitué (\(add.joined(separator: ", "))) — outils de préparation, aucun droit d'envoi", "ok": true, "effect": "migration"])
        }
        if !settings.get("evo_dots_v1", false) {   // deux Dots d'entretien : le gardien surveille, la croissance apprend ; ils n'écrivent jamais de code
            let have = Set(l.compactMap { $0["id"] as? String })
            let extra: [[String: Any]] = [
                ["id": "gardien", "name": "Gardien", "emoji": "🛡️", "color": "#0ea5e9", "role": "Surveille la santé de Nova : Dots en échec, cerveaux IA indisponibles, résultats oubliés. Ne se manifeste que s'il y a un problème.", "quiet_ok": true,
                 "tools": ["app", "recall", "ask_assistant"], "brain": "auto", "schedule": "08:20,11:20,14:20,17:20,20:20",
                 "prompt": "Appelle app avec « equipe » puis « cerveaux » et « status ». Cherche un problème RÉEL et mesuré : Dot dont le dernier passage est ÉCHEC, cerveau indisponible, planification coupée, résultat en attente depuis longtemps. S'il n'y a rien : réponds « RAS ». Sinon : 2 phrases (quoi, depuis quand) et, si tu peux en trouver la cause avec app (runs, actions, code-chercher), consigne la leçon avec « apprendre … ». Si une réparation exige une action, demande-la avec ask_assistant en décrivant précisément le problème."],
                ["id": "croissance", "name": "Croissance", "emoji": "🌱", "color": "#84cc16", "role": "Fait grandir Nova : apprend des erreurs, cherche des innovations utiles, propose des améliorations. Ne modifie jamais rien : il propose.", "quiet_ok": true,
                 "tools": ["app", "web_search", "web_fetch", "recall", "remember", "know", "ask_assistant"], "brain": "deep", "schedule": "21:30",
                 "prompt": "1) app « actions » et « runs » : repère ce qui a échoué ces dernières 24 h ; si tu comprends pourquoi, consigne « apprendre <leçon> ». 2) web_search : une pratique ou technologie RÉCENTE (assistants IA locaux, agents, mémoire, voix, productivité sur Mac, outils pour Burkina/Afrique de l'Ouest) qui améliorerait Nova ; vérifie-la avec web_fetch. 3) Consigne au plus 2 idées concrètes avec « idee <quoi, pourquoi, bénéfice> » (ou « proposer » avec un correctif précis si tu as lu le code avec code-lire). Réponds par 5 lignes maximum : ce que tu as appris, ce que tu proposes. Tu ne modifies rien."]]
            for e in extra where !have.contains(e["id"] as? String ?? "") { l.append(e); changed = true }
            settings.set(["evo_dots_v1": true])
        }
        if !settings.get("dots_activation_v1", false) {   // activation : chaque Dot de la charte a un horaire réel et n'est plus en pause (une seule fois ; l'utilisateur garde la main ensuite)
            let plan: [String: String] = ["capdujour": "lun-sam 07:15", "sahel": "lun-sam 07:20", "radar-humanitaire": "07:30", "brief-audio": "lun-sam 07:45", "brvm-dividendes": "lun-ven 10:00", "momo-releve": "lun-sam 08:00",
                                          "imp-rapport-matin": "07:10", "imp-bulletin-afrique": "07:40", "imp-veille-messages": "08:00,13:00,18:00", "imp-arbitrage-cafu-brvm": "lun-ven 12:30", "imp-fin-journee": "18:00", "brvm": "lun-ven 09:30,16:30"]
            for i in l.indices {
                guard let id = l[i]["id"] as? String, let sch = plan[id] else { continue }
                if ((l[i]["schedule"] as? String) ?? "").isEmpty { l[i]["schedule"] = sch }
                l[i]["paused"] = false; changed = true
            }
            settings.set(["dots_activation_v1": true, "dots_auto": true])
        }
        if !settings.get("dots_fusion_v1", false) {   // fusion : 17 Dots → 6 Dots multi-rôles (anciens en pause, réversible)
            if DotMerge.migrate(&l) { changed = true }
            settings.set(["dots_fusion_v1": true])
        }
        if settings.get("dots_fusion_v1", false), !settings.get("dots_fusion_v2", false) {   // fusion, 2e temps : anciens rôles + doublons → corbeille (récupérable)
            DotMerge.cleanup(&l, settings); changed = true; settings.set(["dots_fusion_v2": true])
        }
        if settings.get("dots_fusion_v2", false), !settings.get("dots_fusion_v3", false) {
            DotMerge.restoreCode(&l, settings); changed = true; settings.set(["dots_fusion_v3": true])
        }
        var seenIds = Set<String>(); let before = l.count   // identifiants uniques (le Dot « brvm » existait en double)
        l = l.filter { seenIds.insert(($0["id"] as? String) ?? UUID().uuidString).inserted }
        if l.count != before { changed = true }
        // NETTOYAGE-BRIEFS (23/10, ordre d'Ahadi) — un seul produit par créneau :
        // migration unique « briefs_cleanup_v1 », idempotente (drapeau de réglage),
        // appliquée au premier list() après le build groupé, journalisée au blackbox.
        //  S2 : le Dot « brief-audio » (lun-sam 07:30) doublait le Brief du matin à la
        //       même minute — définition SUPPRIMÉE, archivée avant retrait dans
        //       dots_archives_briefs.json (récupérable) ;
        //  F1 : le Dot « bilan » (18:30) est mis en pause — la Fermeture du soir
        //       (moteur Briefs, 18:00) absorbe ses entrées (runs du jour, Briefs.dotsToday) ;
        //  F2 : le Dot « capdujour » (lun-sam 07:15) est mis en pause — ses « 3 priorités
        //       prouvées » deviennent la section CAP DU JOUR du Brief du matin ;
        //  A1 : le rituel « imp-rituel-fermeture » passe de ven 18:00 à ven 18:45
        //       (même nom et même minute que la Fermeture du soir, chaque vendredi) ;
        //  A2 : le Dot « veille » (en pause, fusionné dans veille-radar) perd son
        //       horaire résiduel « 07:30,18:00 » — une réactivation accidentelle ne
        //       doit pas recréer un doublon aux créneaux des briefs ;
        //  A3 : le Dot « chercheur », dit « fusionné (à la demande) » mais actif
        //       (lun-ven 17:00, run du 22/10 prouvé) : branche réversible — pause
        //       journalisée, définition et merged_into intacts ;
        //  S3 : les entrées d'état de dots_etat.json sans définition vivante sont
        //       purgées (calculées sur les définitions finales, brief-audio inclus
        //       après S2) — DotScheduler relit ce fichier à chaque tic, la purge
        //       tient dès le tic suivant.
        if !settings.get("briefs_cleanup_v1", false) {
            var notes: [String] = []
            if let i = l.firstIndex(where: { ($0["id"] as? String) == "brief-audio" }) {
                let arch = JSONFile("dots_archives_briefs.json")
                var a = arch.read(default: [[String: Any]]()); a.append(l[i]); arch.write(a)
                l.remove(at: i); changed = true; notes.append("S2 brief-audio supprimé (définition archivée)")
            }
            for i in l.indices {
                guard let id = l[i]["id"] as? String else { continue }
                if id == "bilan" || id == "capdujour" {
                    if (l[i]["paused"] as? Bool) != true { l[i]["paused"] = true; changed = true; notes.append((id == "bilan" ? "F1 bilan mis en pause" : "F2 capdujour mis en pause")) }
                }
                if id == "imp-rituel-fermeture", (l[i]["schedule"] as? String) == "ven 18:00" {
                    l[i]["schedule"] = "ven 18:45"; changed = true; notes.append("A1 imp-rituel-fermeture ven 18:00 → ven 18:45")
                }
                if id == "veille", (l[i]["schedule"] as? String) == "07:30,18:00" {
                    l[i]["schedule"] = ""; changed = true; notes.append("A2 veille : horaire résiduel retiré")
                }
                if id == "chercheur", (l[i]["paused"] as? Bool) != true {
                    l[i]["paused"] = true; changed = true; notes.append("A3 chercheur mis en pause (dit fusionné, encore actif)")
                }
            }
            let liveIds = Set(l.compactMap { $0["id"] as? String })
            let etatFile = JSONFile("dots_etat.json")
            var etat = etatFile.read(default: [String: Any]())
            let orphans = etat.keys.filter { !liveIds.contains($0) }.sorted()
            if !orphans.isEmpty {
                for k in orphans { etat.removeValue(forKey: k) }
                etatFile.write(etat); notes.append("S3 état purgé : " + orphans.joined(separator: ", "))
            }
            settings.set(["briefs_cleanup_v1": true])
            _ = BlackBox.record(["tool": "briefs_cleanup", "actor": "Nova", "why": "NETTOYAGE-BRIEFS (ordre d'Ahadi 23/10) : " + (notes.isEmpty ? "rien à appliquer (déjà propre)" : notes.joined(separator: " · ")), "ok": true, "effect": "migration"])
        }
        // DRAFTS-OFF (23/10, ordre d'Ahadi 07:56) : « arrête la production auto de
        // brouillon ; tous les mails doivent être traités à la même enseigne ; un
        // brouillon n'est fait que si je le demande explicitement, peu importe de
        // qui il s'agit ; les brouillons sont mal faits ». Renverse l'acceptation
        // du lot ACL du matin : les outils restent disponibles pour l'assistant
        // en conversation (demande explicite d'Ahadi), mais plus aucun Dot ne
        // les détient, et leurs chartes n'ordonnent plus de rédiger.
        //  1) draft_reply + cafu_format_email retirés des outils de TOUS les Dots.
        //  2) Chartes amendées : les clauses qui ORDONNAIENT un brouillon (paires
        //     relevées au texte près dans les chartes vivantes du 23/10) sont
        //     remplacées par l'ordre de SIGNALER le mail et le besoin de réponse ;
        //     un ordre permanent contraire est ajouté à la consigne de chaque Dot
        //     qui détenait un outil de brouillon.
        // Durabilité : la porte d'exécution de Tools.run (refus de draft_reply et
        // de cafu_format_email « brouillon » pour tout acteur ≠ « Nova »,
        // journalisé) couvre ce que la liste ne peut pas : récréations de Dots et
        // escalades ask_assistant — l'appui tourne sous l'acteur « Assistant
        // (appui d'un Dot) », distinct de l'assistant de conversation.
        if !settings.get("drafts_off_v1", false) {
            var notes: [String] = []
            let rider = "\nORDRE PERMANENT D'AHADI (23/10/2026 — drafts_off_v1) : aucun brouillon en automatique, pour personne. Si un mail ou un message attend une réponse, signale-le dans ton rapport (expéditeur, objet, pourquoi une réponse peut être attendue) avec la mention « brouillon possible — en attente de demande explicite » ; ne rédige que si Ahadi le demande explicitement en conversation."
            let swaps: [(String, String)] = [
                ("BROUILLON : au plus 1 par passage, SEULEMENT si un mail est marqué urgent ET attend une réponse d'une personne connue (recall sur son nom) ET qu'aucun brouillon n'existe déjà pour cet objet (recall « brouillon <objet> ») ; après l'avoir fait, remember « brouillon <objet> <date> ». Sinon aucun brouillon. Une ALERTE reçue ne change pas cette règle.",
                 "BROUILLON : INTERDIT en automatique (ordre d'Ahadi 23/10/2026) — aucun brouillon, pour personne : ni urgent, ni personne connue, ni alerte. Si un mail attend une réponse, signale-le dans la sortie URGENT (expéditeur — objet — échéance) avec la mention « brouillon possible — en attente de demande explicite » ; la rédaction n'a lieu que sur demande explicite d'Ahadi en conversation."),
                ("Pour les 3 plus importants, prépare un brouillon de réponse avec draft_reply. Résume : combien, lesquels, ce qui est prêt à valider.",
                 "Pour les 3 plus importants, signale ceux qui attendent une réponse (« brouillon possible — en attente de demande explicite ») : aucun brouillon en automatique (ordre d'Ahadi 23/10/2026). Résume : combien, lesquels, ce qui attend une réponse."),
                ("(3) rédige le brouillon avec draft_reply ;",
                 "(3) signale le besoin (« brouillon possible — en attente de demande explicite »), sans rédiger (drafts_off_v1) ;"),
                ("brouillons enregistrés (chemins)",
                 "brouillons signalés (aucun enregistré : drafts_off_v1)"),
                ("4) draft_reply (un seul).",
                 "4) les textes rédigés, livrés dans le rapport (aucun draft_reply : drafts_off_v1)."),
                ("BROUILLON : exactement 1 draft_reply par passage (to vide, objet « Publication <date> »), contenant l'article et les 2 posts ; jamais de brouillon de réponse à un mail ; rien publié.",
                 "BROUILLON : INTERDIT (ordre d'Ahadi 23/10/2026) — aucun draft_reply ; l'article et les 2 posts sont livrés dans le rapport, à valider ; jamais de brouillon de réponse à un mail ; rien publié."),
                ("Enregistre le brouillon avec draft_reply. Ne publie rien.",
                 "Ne l'enregistre PAS comme brouillon (drafts_off_v1) : livre le texte dans ton rapport, à valider. Ne publie rien."),
                ("Livre-les comme brouillons (draft_reply).",
                 "Livre-les dans ton rapport (drafts_off_v1 : aucun brouillon enregistré)."),
                ("prépare UN brouillon avec draft_reply (JSON {\"to\",\"subject\",\"body\"}) au format : salutation, une phrase de contexte, points clés en liste, action demandée en gras, ligne de clôture.",
                 "signale le besoin (« brouillon possible — en attente de demande explicite »), sans rédiger (drafts_off_v1)."),
                ("brouillons préparés, décisions qui reviennent à Ahadi",
                 "brouillons signalés, décisions qui reviennent à Ahadi"),
                (" : brouillons seulement, Ahadi valide et envoie lui-même.",
                 " : signalements seulement, Ahadi décide et envoie lui-même."),
                ("brouillons uniquement via draft_reply",
                 "aucun brouillon (drafts_off_v1 : signaler seulement)"),
            ]
            let directiveSwaps: [(String, String)] = [
                ("(4) rédiger les réponses visa thaïlandais e-Visa et mentoring Soudan.",
                 "(4) signaler les réponses à préparer (visa thaïlandais e-Visa, mentoring Soudan) — rédaction uniquement sur demande explicite d'Ahadi (drafts_off_v1)."),
            ]
            for i in l.indices {
                guard let id = l[i]["id"] as? String else { continue }
                var t = (l[i]["tools"] as? [String]) ?? []
                let held = t.filter { $0 == "draft_reply" || $0 == "cafu_format_email" }
                if !held.isEmpty {
                    t.removeAll { $0 == "draft_reply" || $0 == "cafu_format_email" }
                    l[i]["tools"] = t; changed = true
                    notes.append("\(id) : outils retirés (\(held.joined(separator: ", ")))")
                }
                if var p = l[i]["prompt"] as? String {
                    let before = p
                    for (a, b) in swaps { p = p.replacingOccurrences(of: a, with: b) }
                    if !held.isEmpty, !p.contains("drafts_off_v1") { p += rider }
                    if p != before { l[i]["prompt"] = p; changed = true; notes.append("\(id) : charte amendée (ordre de rédiger supprimé)") }
                }
                if var dir = l[i]["directive"] as? String {
                    let before = dir
                    for (a, b) in directiveSwaps { dir = dir.replacingOccurrences(of: a, with: b) }
                    if dir != before { l[i]["directive"] = dir; changed = true; notes.append("\(id) : directive amendée") }
                }
                if !held.isEmpty { l[i]["drafts_off_v1"] = true }
            }
            settings.set(["drafts_off_v1": true])
            _ = BlackBox.record(["tool": "drafts_off", "actor": "Nova", "why": "DRAFTS-OFF (ordre d'Ahadi 23/10 07:56 : arrêt de toute production automatique de brouillons — demandes explicites seulement) : " + (notes.isEmpty ? "rien à appliquer (déjà propre)" : notes.joined(separator: " · ")), "ok": true, "effect": "migration"])
        }
        // FLOTTE V1 (25/10/2026, demande d'Ahadi) : flotte resserrée, horaires étalés, doublons retirés
        // (jamais supprimés) — détail et justification : conseil_24-10/V5_X_ECLATS_AUDIT.md, code : DotMerge.applyFleetV1.
        if !settings.get("eclats_flotte_v1", false) {
            let notes: [String] = DotMerge.applyFleetV1(&l)
            DotMerge.resetCareV1()
            changed = true
            settings.set(["eclats_flotte_v1": true])
            let why: String = "FLOTTE V1 (demande d'Ahadi 25/10) : " + notes.joined(separator: " · ")
            _ = BlackBox.record(["tool": "eclats_flotte", "actor": "Nova", "why": String(why.prefix(1800)), "ok": true, "effect": "migration"])
        }
        if changed { store.write(l) }
        return l.map { var d = $0; d["persona"] = DotPersonas.persona(for: d); return d }
    }
    public func save(_ d: [String: Any]) {
        var l = list(); let id = d["id"] as? String ?? UUID().uuidString.prefix(8).lowercased().description
        var n = d; n["id"] = id
        if let i = l.firstIndex(where: { ($0["id"] as? String) == id }) { l[i] = n } else { l.append(n) }
        store.write(l)
    }
    public func remove(_ id: String) { store.write(list().filter { ($0["id"] as? String) != id }) }
    public func history(_ id: String? = nil) -> [[String: Any]] {
        let r = runs.read(default: [[String: Any]]()); return (id == nil ? r : r.filter { ($0["dot"] as? String) == id }).reversed()
    }

    @discardableResult
    public func run(id: String, task: String, ordered: Bool = false, cancel: @escaping () -> Bool, onEvent: @escaping (BrainEvent) -> Void) -> [String: Any]? {   // A1 : ordered = lancé à la main par le Capitaine (piste entière) ; false = passage planifié (bornes de fond inchangées)
        // WP3-J/M : contexte d'exécution PROPRE au Dot (arrière-plan, aucune approbation d'envoi, confirmations à sa portée) —
        // même lancé depuis le thread d'une conversation (Orchestre « dot-run »), il n'hérite rien du run d'Ahadi.
        let wp3Prev: ExecContext? = ExecContext.enter(ExecContext.dot(id))
        defer { ExecContext.restore(wp3Prev) }
        guard let d = list().first(where: { ($0["id"] as? String) == id }) else { onEvent(.error("Dot introuvable")); return nil }
        // 25/10 : l'Éclat « Podcast hebdo » produit un VRAI épisode audio (Feat_Podcast.swift) au lieu d'un texte d'agent.
        if PodcastKit.dotIds.contains(id), !task.hasPrefix("[SUIVI]"), PodcastKit.dotHook != nil {
            return runPodcastDot(id: id, d: d, task: task, onEvent: onEvent)
        }
        let plusPrep: EclatPlus.Prep = EclatPlus.prepare(d, followUp: task.hasPrefix("[SUIVI]"))   // V6 ÉCLATS : leçons d'Ahadi + priorité « Réorienter » (Feat_EclatsDots.swift)
        let followUp = task.hasPrefix("[SUIVI]")   // question de suivi : le Dot peut chercher (web, mémoire, savoir) pour compléter
        // Socle commun en LECTURE (types explicites : évite l'explosion du vérificateur de types Swift)
        var allowedArr: [String] = (d["tools"] as? [String]) ?? []
        let base: [String] = ["ask_assistant", "app", "nova_self", "web_search", "web_fetch", "recall", "know", "read_file", "mail_unread", "mail_week", "mail_corps", "mail_pj", "calendar", "reminders", "teams_read", "system", "processes", "brvm_cours", "flux_titres"]   // 25/10 : mail_corps entre au socle de lecture — sans lui, aucun Éclat ne pouvait ouvrir un corps (« corps non ouverts »)
        allowedArr += base
        if id.contains("brvm") || id == "brief-audio" || id == "capdujour" { allowedArr += ["brvm_cours", "web_search", "web_fetch"] }
        // Quota de brouillons (anti-boucle) : N par jour et par Dot, comptés dans brouillons.json via le champ « dot »
        let draftMax: Int = settings.get("dots_brouillons_max", 3)
        let draftsToday: Int = draftCountToday(id)
        var allowedSet: Set<String> = Set(allowedArr)
        if draftsToday >= draftMax { allowedSet.remove("draft_reply"); _ = BlackBox.record(["tool": "draft_reply", "actor": "Dot " + ((d["name"] as? String) ?? id), "why": "ACL : draft_reply retiré pour ce passage — quota de brouillons DU DOT atteint (\(draftsToday)/\(draftMax) aujourd'hui, réglage dots_brouillons_max) ; un refus « non autorisé » qui suivrait vient de ce quota, pas de la liste du Dot", "ok": false, "effect": "refusé"]) }
        // Garde-fou global : au-delà de N brouillons créés aujourd'hui par TOUS les Dots (ou sans auteur), plus aucun Dot n'en crée.
        let totalMax: Int = settings.get("dots_brouillons_max_total", 10)
        if draftCountToday(nil) >= totalMax { allowedSet.remove("draft_reply"); _ = BlackBox.record(["tool": "draft_reply", "actor": "Dot " + ((d["name"] as? String) ?? id), "why": "ACL : draft_reply retiré pour ce passage — quota GLOBAL de brouillons des Dots atteint (\(draftCountToday(nil))/\(totalMax) aujourd'hui, réglage dots_brouillons_max_total) ; un refus « non autorisé » qui suivrait vient de ce quota, pas de la liste du Dot", "ok": false, "effect": "refusé"]) }
        // WP5 (B/M) : capacités de CE passage. Sans surveillance (planifié), un Dot n'a PAS l'exécution générique (shell,
        // AppleScript, open, raccourcis, forge) — même si sa liste d'outils la contient. Lancé à la main (ordered) ou inscrit par
        // Ahadi dans le réglage réservé « dots_shell_sans_surveillance » : l'exécution revient, les cartes de confiance restent.
        let runCaps: Set<ToolCapability> = Dots.runCapabilities(id: id, ordered: ordered, optIn: settings.get("dots_shell_sans_surveillance", [String]()))
        allowedSet = allowedSet.filter { ToolCapabilities.required(tool: $0, arg: "").isSubset(of: runCaps) }
        let allowed: Set<String> = allowedSet
        let draftRoom: Int = max(0, draftMax - draftsToday)
        var draftsMade: Int = 0
        let draftIdsBefore: Set<String> = Set(tools.drafts.read(default: [[String: Any]]()).compactMap { $0["id"] as? String })
        let sys = Persona.system(assistantName: d["name"] as? String ?? "Dot", title: settings.get("user_title", "Capitaine"), memory: tools.memory.promptBlock(max: 25, query: ((d["prompt"] as? String) ?? "") + " " + ((d["role"] as? String) ?? "")), voice: false, tools: true,
                                 extra: "TU ES LE DOT « \(d["name"] ?? "") ». RÔLE : \(d["role"] ?? ""). Outils autorisés : \(allowed.sorted().joined(separator: ", ")). LECTURE SEULE (garantie dans le code, Feat_Trust) : écrire, piloter une app, lancer une commande ou changer un réglage passe par une carte d'Ahadi ; envoi, publication, paiement, suppression et secrets te sont refusés. Consigne permanente : \(d["prompt"] ?? "")\nRÈGLE : réponds de façon COMPLÈTE et termine toujours tes phrases ; si une information manque, cherche-la avec tes outils (web_search, web_fetch, recall, know, brvm_cours pour la Bourse) avant d'écrire « non disponible ». FRAÎCHEUR : pour un fait daté ou un dossier en cours, la source la plus récente fait foi — ne conclus jamais « aucune donnée » ni « non vérifié » depuis une source plus vieille que le fait ou l'échéance en jeu ; rapporte le fait le plus récent trouvé, avec sa date ; si un point reste sans donnée après recherche, nomme la source la plus fraîche consultée et sa date. Dans une question de suivi, réponds directement à la question posée.\n" + chefBlock(d) + DotPersonas.prompt(DotPersonas.persona(for: d)) + "\nFORMAT DE SORTIE : ne raconte JAMAIS ta démarche (« je commence par », « je vérifie »). Entre les appels d'outils, n'écris rien. Livre UNIQUEMENT le rapport final au format du contrat (STATUT, sections « ## », À TOI) : chiffres réels, sources et dates, puces courtes.")
        var text = ""; var steps: [[String: String]] = []; var brain = ""
        var stepsTotal = 0   // SPARK8-D : cumul des outils sur toutes les tentatives (le message d'échec dit vrai)
        var usageIn = 0; var usageOut = 0   // MN2-6 : jetons réels du run (événements usage de l'agent) — 0 événement = « inconnu », jamais un faux 0 affiché
        let t0 = Date()
        let runId = String(UUID().uuidString.prefix(8)).lowercased()   // SPARK8-D : un run est visible pendant qu'il vole
        // SPARK8-D : entrée de départ immédiate (même forme que l'item final), remplacée à la complétion.
        do {
            Dots.runsLock.lock(); defer { Dots.runsLock.unlock() }
            let startItem: [String: Any] = ["id": runId, "dot": id, "task": task, "ts": nowISO(), "result": "", "steps": [[String: String]](), "usage_in": 0, "usage_out": 0, "brain": "", "ok": false, "status": "", "statut": "en_cours", "ms": 0, "read": false]
            var rh = runs.read(default: [[String: Any]]()); rh.append(Dots.lighten(startItem))
            runs.write(Array(rh.suffix(120)).map { Dots.lighten($0) })
        }
        // VAGUE 2 FIABILITÉ : run inscrit au registre des runs en vol ; stopNow = annulation de l'appelant OU Stop demandé (POST /api/dots/stop).
        Dots.liveBegin(runId: runId, dot: id)
        defer { Dots.liveEnd(runId: runId) }
        let stopNow: () -> Bool = { cancel() || Dots.isStopAsked(runId) }
        Amplitude.track("dot_run_started", ["ordered": ordered, "follow_up": followUp])   // AMPLITUDE (CRÉDITS 23/10) : début de run — jamais la tâche ni le nom du Dot
        // « go », « ok », « vas-y »… : ce n'est pas une tâche, c'est l'ordre de lancer la mission du Dot
        let tk = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let trivial = ["go", "ok", "oui", "vas-y", "vas y", "allez", "lance", "lancer", "start", "run", "c'est parti", "fonce", "!"].contains(tk.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "!. ")))
        let baseTask: String = (tk.isEmpty || trivial) ? DotCharter.scheduledTask(for: d) : task
        // FLOTTE V1 : un passage planifié connaît son passage précédent — il ne répète pas, il signale le NOUVEAU (fin des 3 « Partiel » quasi identiques).
        let wantsPrev: Bool = !followUp && (tk.isEmpty || trivial) && !DotCharter.isInteractive(id)
        let prevNote: String = wantsPrev ? previousNote(id) : ""
        let missionTask: String = baseTask + prevNote + plusPrep.suffix
        let baseSys = sys + (followUp ? "" : DotCharter.block(for: d))   // charte verrouillée : contrat commun + fiche de mission (hors questions de suivi)
        let agent = Agent(router: router, tools: tools)
        // Sobriété : 8 étapes maximum, jetons réduits (Dot fusionné un peu plus large)
        var tokCap: Int = 1500
        if DotMerge.isMerged(id) { tokCap = 2400 }
        if followUp { tokCap = 1200 }
        let stepCap: Int = DotMerge.isMerged(id) ? 14 : 8   // 25/10 : un Éclat fusionné (5 sources) épuisait ses 8 étapes avant d'ouvrir le corps des mails (mail_corps)
        let actorName: String = "Dot " + (d["name"] as? String ?? "")
        let runCancel: () -> Bool = { stopNow() || (draftsMade > 0 && draftsMade >= draftRoom) }   // quota de brouillons atteint : on arrête l'agent
        // AUDIT-24/10: le cerveau PROPRE au Dot (champ « brain » = id du catalogue, posé par dot-set) est honoré ;
        // les valeurs de mode historiques (« auto », « deep », « bulk », vide) gardent le cerveau des Dots (dots_brain = [tiers]).
        let dotBrainPref: String? = {
            let own: String = (d["brain"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !own.isEmpty, !["auto", "deep", "bulk"].contains(own), self.router.spec(own) != nil { return own }
            let b: String = Settings().get("dots_brain", ""); return b.isEmpty ? nil : b
        }()
        func attempt(_ mode: String, _ system: String) {
            text = ""; steps = []
            agent.run(messages: [ChatMsg("user", missionTask)], system: system,
                      mode: mode, preferred: dotBrainPref, maxTokens: tokCap, useTools: true, maxSteps: stepCap, allowed: allowed, actor: actorName, ordered: ordered, cancel: runCancel, capabilities: runCaps) { ev in
                switch ev {
                case .delta(let t): text += t
                case .draftReset: text = ""   // VÉRITÉ-3 (E3, 23/10) : frontière de génération — même remplacement que sur .tool, les versions d'un même passage ne se soudent plus dans le rapport
                case .tool(let n, let i, let o):
                    text = ""; steps.append(["tool": n, "input": String(i.prefix(200)), "output": String(o.prefix(400))])
                    if n == "draft_reply" && o.hasPrefix("Brouillon enregistré") { draftsMade += 1 }
                case .start(_, let l): brain = l
                case .usage(let i, let o): usageIn += i; usageOut += o
                default: break
                }
                onEvent(ev)
            }
            for mark in ["<｜DSML", "<|DSML", "< | DSML", "<｜ DSML", "<tool_call", "<function_calls"] { if let r = text.range(of: mark) { text = String(text[..<r.lowerBound]) } }   // balises d'appel d'outil mal formées ([tiers]) : jamais dans un rapport
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            stepsTotal += steps.count   // SPARK8-D : cumul pour le compteur d'outils (la supervision n'est pas comptée)
        }
        // Décision du Capitaine : cloud pour tous les Dots — AUDIT-24/10: cerveau du Dot ([tiers] par défaut) → [tiers] → [tiers] (Router.plan), local en dernier secours.
        let wantedMode = "deep"
        attempt(wantedMode, baseSys)
        // FIX-RADAR R3 (trou T3) : pour veille-radar seul, le texte de repli de
        // l'Agent (« Les outils ont tourné … mais aucun cerveau n'a rédigé la
        // synthèse ») n'est PAS un rapport — les filets ci-dessous, gardés par
        // text.isEmpty, ne le voient jamais, et la dérivation de statut le
        // reclassait « STATUT : OK ». La synthèse est donc refaite ici aux
        // paramètres des briefs (cerveau des Réglages épinglé solo, 4 000 jetons,
        // 120 s, patron Briefs.swift) ; si elle échoue encore, le run porte un
        // ÉCHEC nommé avec son motif et les constats bruts bornés — jamais un OK
        // sur un repli. Garde !followUp : une question de suivi rend son texte à
        // l'utilisateur, elle ne reçoit jamais un tampon de statut de ce filet.
        if id == "veille-radar", !followUp, !stopNow(), text.hasPrefix("Les outils ont tourné") {
            let found = steps.map { "• \($0["tool"] ?? "") (\($0["input"] ?? "")) → \($0["output"] ?? "")" }.joined(separator: "\n")
            let det = router.completeDetailed(messages: [ChatMsg("user", "Mission : \(missionTask)\n\nRésultats de tes outils :\n\(found)\n\nRédige maintenant ta réponse finale complète à partir de ces résultats. Si une donnée manque, dis précisément laquelle et ce que tu ferais pour l'obtenir.")], system: sys, mode: "bulk",
                                              preferred: settings.get("brain", "spark-1.3"), maxTokens: 4000, deadline: 120, solo: true)
            if let r = det.result, !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if brain.isEmpty { brain = router.spec(r.brain)?.label ?? r.brain }
                onEvent(.delta(text))
            } else {
                text = "STATUT : ÉCHEC — synthèse non produite : \(det.error ?? "motif inconnu")\n" + steps.suffix(4).map { "• \($0["tool"] ?? "") : \(($0["output"] ?? "").prefix(300))" }.joined(separator: "\n") + "\nÀ TOI : rien (Nova relance au prochain créneau)."
            }
        }
        // Rapport vide, ÉCHEC ou cerveau local défaillant : un second passage sur le meilleur cerveau (cloud), avec rappel du contrat
        if !followUp, !stopNow(), text.isEmpty {   // sobriété : un ÉCHEC motivé n'est plus relancé en entier (l'anti-boucle et Santé des Dots s'en chargent)
            let first = text
            attempt("deep", baseSys + "\nRAPPEL : ton premier passage n'a pas abouti" + (first.isEmpty ? " (rapport vide)" : " (« \(first.prefix(160)) »)") + ". Reprends la mission depuis le début avec d'autres voies d'accès, et livre un rapport au format du contrat.")
            if text.isEmpty { text = first }
        }
        // Les outils ont tourné mais l'agent n'a rien rédigé (pas d'étape restante) : on lui demande la synthèse finale à partir de ce qu'il a trouvé
        if text.isEmpty, !steps.isEmpty, !stopNow() {
            let found = steps.map { "• \($0["tool"] ?? "") (\($0["input"] ?? "")) → \($0["output"] ?? "")" }.joined(separator: "\n")
            if let r = router.complete(messages: [ChatMsg("user", "Mission : \(missionTask)\n\nRésultats de tes outils :\n\(found)\n\nRédige maintenant ta réponse finale complète à partir de ces résultats. Si une donnée manque, dis précisément laquelle et ce que tu ferais pour l'obtenir.")], system: sys, mode: "deep", maxTokens: 1600) {
                text = r.text.trimmingCharacters(in: .whitespacesAndNewlines); if brain.isEmpty { brain = router.spec(r.brain)?.label ?? r.brain }
                if !text.isEmpty { onEvent(.delta(text)) }
            }
        }
        // Dernier filet : aucun cerveau n'a rédigé, mais les outils ont répondu → rapport PARTIEL avec les données brutes plutôt qu'un ÉCHEC muet
        if text.isEmpty, !steps.isEmpty, !stopNow() {
            text = "STATUT : PARTIEL — synthèse indisponible (cerveaux muets), données brutes des outils ci-dessous.\n" + steps.suffix(4).map { "• \($0["tool"] ?? "") : \(($0["output"] ?? "").prefix(300))" }.joined(separator: "\n") + "\nÀ TOI : rien (Nova relance au prochain créneau)."
        }
        // Le rapport porte toujours son STATUT ; un rapport vide est un ÉCHEC explicite (jamais un silence)
        // LOT2 P-R225 : le STATUT se DÉDUIT des résultats d'outils réels (succès/échecs comptés séparément) — plus de « OK » automatique sur un rapport non vide.
        // VAGUE 2 FIABILITÉ : un run arrêté à la demande porte le statut ARRÊTÉ (ni succès, ni échec : DotCare et l'anti-boucle l'ignorent).
        let wasStopped: Bool = Dots.isStopAsked(runId)
        if wasStopped {
            let dejaRedige: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = "STATUT : ARRÊTÉ — exécution interrompue à ta demande après \(stepsTotal) outil(s)." + (dejaRedige.isEmpty ? "" : "\nCe qui était déjà rédigé :\n" + String(dejaRedige.prefix(1500)))
            _ = BlackBox.record(["tool": "dots_stop", "actor": "Nova", "why": "run \(runId) de l'Éclat \(id) interrompu à la demande après \(stepsTotal) outil(s) en \(Int(Date().timeIntervalSince(t0) * 1000)) ms", "ok": true, "effect": "arrêt"])
        }
        // 26/10 : un cerveau renvoyait son format interne (<|start|>assistant<|channel|>commentary … <|call|>) comme rapport.
        if text.contains("<|") { text = Dots.stripHarmony(text) }
        if !followUp, !wasStopped {
            let echecs = steps.filter { Dots.toolFailed($0["output"] ?? "") }.count
            let succes = steps.count - echecs
            if text.isEmpty { text = "STATUT : ÉCHEC — aucun cerveau n'a produit de rapport (\(stepsTotal) outil(s) appelé(s)). Relance depuis l'onglet Dots ou demande à l'assistant de diagnostiquer." }   // SPARK8-D : compteur vrai
            else if DotCharter.status(of: text) == "OK", !steps.isEmpty, succes == 0 {
                // Le Dot s'est déclaré OK alors que TOUS ses outils ont échoué : statut rétrogradé, jamais validé.
                let corps = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
                text = "STATUT : ÉCHEC — tous les outils ont échoué (\(echecs)/\(steps.count)) ; le rapport du Dot n'est pas un succès.\n" + corps
            }
            else if DotCharter.status(of: text) == nil, !DotCharter.isInteractive(id) {
                if steps.isEmpty { text = "STATUT : PARTIEL — aucun outil exécuté : résultat non vérifiable.\n" + text }
                else if succes == 0 { text = "STATUT : ÉCHEC — tous les outils ont échoué (\(echecs)/\(steps.count)).\n" + text }
                else if echecs > 0 { text = "STATUT : PARTIEL — \(succes) outil(s) réussi(s), \(echecs) en échec.\n" + text }
                else { text = "STATUT : OK\n" + text }
            }
        }
        // SUPERVISION PAR NOVA (le double d'Ahadi) : si le Dot pose une question, attend une décision ou n'a qu'un résultat partiel,
        // Nova répond à sa place, complète avec ses outils, corrige et valide — sans rien afficher à l'écran ni déranger Ahadi.
        // FLOTTE V1 : seule une VRAIE décision (envoyer, payer, supprimer, publier, choisir…) entre en file ; une demande de lecture ou d'accès n'en est pas une.
        let rawQ: String? = (followUp || wasStopped) ? nil : Dots.decisionLine(text)
        var decisionQ: String? = nil
        if let q = rawQ, Dots.isRealDecision(q) { decisionQ = q }
        let missingTool: Bool = Dots.isMissingTool(text, steps)
        var supervision: String = ""
        if !followUp, !stopNow(), !text.isEmpty, settings.get("dots_supervision", true) {
            let low: String = text.lowercased()
            var asks: Bool = decisionQ != nil
            if low.contains("veux-tu") || low.contains("souhaites-tu") || low.contains("dois-je") || low.contains("confirme") { asks = true }
            if low.contains("statut : partiel") || low.contains("statut : echec") || low.contains("statut : échec") { asks = true }
            let isEchec: Bool = DotCharter.status(of: text) == "ECHEC"
            if isEchec && missingTool { asks = false }   // outil manquant : la supervision n'y changerait rien
            if asks, let hook = Tools.assistHook {
                let q: String = "SUPERVISION DU DOT « \(d["name"] ?? id) » (mission : \(missionTask.prefix(300))). Voici son rapport :\n\(text.prefix(3500))\n\nEn tant que double d'Ahadi : réponds toi-même aux questions du Dot quand une hypothèse raisonnable suffit, va chercher avec tes outils ce qui manque, corrige les erreurs, puis livre le résultat final validé (court). Travaille en arrière-plan, n'ouvre rien à l'écran. N'envoie, ne paie et ne supprime rien : prépare seulement."
                let sup: String = hook(q)
                if !sup.isEmpty { supervision = sup; text += "\n\n— SUPERVISION NOVA —\n" + sup; steps.append(["tool": "supervision_nova", "input": "rapport du Dot", "output": String(sup.prefix(400))]) }
            }
        }
        let st: String? = wasStopped ? "ARRETE" : DotCharter.status(of: text)
        var item: [String: Any] = ["id": runId, "dot": id, "task": task, "ts": nowISO(), "result": text, "steps": steps, "usage_in": usageIn, "usage_out": usageOut,
                                   "brain": brain, "ok": !text.isEmpty && st != "ECHEC" && !wasStopped && !text.hasPrefix("STATUT : PARTIEL — synthèse indisponible"), "status": st ?? "", "ms": Int(Date().timeIntervalSince(t0) * 1000), "read": false]
        if wasStopped { item["arrete"] = true; item["statut"] = "arrete" }
        if let q = decisionQ { item["decision"] = true; item["question"] = q }
        if !supervision.isEmpty { item["supervision"] = String(supervision.prefix(400)) }
        if missingTool { item["missing_tool"] = true }
        // AUTONOMIE A3 (22/10) : run ÉCHEC/PARTIEL sur DÉPENDANCE ABSENTE → reprise
        // enregistrée ; le Dot se relancera UNE fois au retour de la dépendance
        // (Reprise.swift), sans doublon (succès postérieur = fermeture sans tir).
        // Marqueurs = textes d'échec RÉELS des outils : calendrier refusé
        // (Tools.swift, « Agenda illisible… pas accordé ») et volet Teams déconnecté
        // (teams_read : « le volet Teams de Nova n'a pas encore livré de contenu »).
        // Les sources mail ne sont pas enregistrées : elles dégradent en douceur
        // (Mail.app + volets + repli nommé) et DotCare couvre déjà la réparation.
        if !followUp, !wasStopped, st == "ECHEC" || st == "PARTIEL" {
            let outs = steps.map { $0["output"] ?? "" }.joined(separator: "\n")
            if outs.contains("pas accordé") || outs.contains("Agenda illisible") {
                Reprise.note(producer: "dot", key: id, dep: "calendar", label: (d["name"] as? String) ?? id)
            } else if steps.contains(where: { $0["tool"] == "teams_read" }) && (outs.contains("volet Teams de Nova n'a pas encore livré") || outs.contains("session non connectée")) {
                Reprise.note(producer: "dot", key: id, dep: "pane:tm", label: (d["name"] as? String) ?? id)
            }
        }
        item = Dots.lighten(item)
        if draftsMade > 0 || draftRoom == 0 { tagDrafts(id, before: draftIdsBefore) }
        Dots.runsLock.lock()   // SPARK8-D : sérialise départ/complétion
        var r = runs.read(default: [[String: Any]]())
        if let i = r.firstIndex(where: { ($0["id"] as? String) == runId }) { r[i] = item } else { r.append(item) }   // SPARK8-D : remplace l'entrée en_cours
        let kept: [[String: Any]] = Array(r.suffix(120)).map { Dots.lighten($0) }
        runs.write(kept)
        Dots.runsLock.unlock()
        Amplitude.track("dot_run_finished", ["status": st, "steps": steps.count, "ms": Int(Date().timeIntervalSince(t0) * 1000)])   // AMPLITUDE (CRÉDITS 23/10) : fin de run — statut et compteurs seuls
        if !followUp, !wasStopped { checkLoop(id, kept) }
        if !followUp, !wasStopped { EclatPlus.afterRun(id, prep: plusPrep, dots: self) }   // V6 ÉCLATS : « Réorienter » servi une fois puis effacé
        return item
    }
    /// 25/10 : passage de l'Éclat « Podcast hebdo » — pipeline audio réel, run enregistré « Fait » (lien) ou « Échec » (cause réelle).
    func runPodcastDot(id: String, d: [String: Any], task: String, onEvent: @escaping (BrainEvent) -> Void) -> [String: Any]? {
        let t0: Date = Date()
        let runId: String = String(UUID().uuidString.prefix(8)).lowercased()
        do {
            Dots.runsLock.lock(); defer { Dots.runsLock.unlock() }
            let startItem: [String: Any] = ["id": runId, "dot": id, "task": task, "ts": nowISO(), "result": "", "steps": [[String: String]](), "usage_in": 0, "usage_out": 0, "brain": "", "ok": false, "status": "", "statut": "en_cours", "ms": 0, "read": false]
            var rh: [[String: Any]] = runs.read(default: [[String: Any]]())
            rh.append(Dots.lighten(startItem))
            runs.write(Array(rh.suffix(120)).map { Dots.lighten($0) })
        }
        Dots.liveBegin(runId: runId, dot: id)
        defer { Dots.liveEnd(runId: runId) }
        onEvent(.start(id: "podcast", label: "Podcast hebdo"))
        var steps: [[String: String]] = []
        let progressFn: (String) -> Void = { (step: String) -> Void in
            steps.append(["tool": "podcast", "input": "", "output": String(step.prefix(200))])
        }
        var r: [String: Any] = ["ok": false, "error": "pipeline podcast non branché"]
        if let hook = PodcastKit.dotHook { r = hook("eclat", progressFn) }
        let ok: Bool = (r["ok"] as? Bool) == true
        var text: String = ""
        if ok {
            let name: String = (r["name"] as? String) ?? ""
            let path: String = (r["path"] as? String) ?? ""
            let resume: String = (r["resume"] as? String) ?? ""
            let chars: Int = (r["tts_chars"] as? Int) ?? 0
            let brainL: String = (r["brain"] as? String) ?? ""
            text = "STATUT : OK — Fait. Épisode de la semaine prêt : " + resume + "\n"
            text += "## Écouter\n- Livrables → « " + name + " » (/api/livrables/file?name=" + name + ")\n- Fichier : " + path + "\n"
            text += "## Coût\n- " + String(chars) + " caractères rendus par la voix système (plafond " + String(settings.get("podcast_tts_max_chars", 6000)) + ") · script : " + brainL + "\n"
            text += "À TOI : rien — écoute quand tu veux. Rien n'a été envoyé ni publié."
        } else {
            let cause: String = (r["error"] as? String) ?? "cause inconnue"
            text = "STATUT : ÉCHEC — podcast non produit : " + cause + "\nÀ TOI : rien (Nova relance au prochain créneau)."
        }
        onEvent(.delta(text))
        let st: String = ok ? "OK" : "ECHEC"
        var item: [String: Any] = ["id": runId, "dot": id, "task": task, "ts": nowISO(), "result": text, "steps": steps, "usage_in": 0, "usage_out": 0,
                                   "brain": (r["brain"] as? String) ?? "", "ok": ok, "status": st, "ms": Int(Date().timeIntervalSince(t0) * 1000), "read": false]
        if ok { item["livrable"] = (r["name"] as? String) ?? "" }
        item = Dots.lighten(item)
        Dots.runsLock.lock()
        var rr: [[String: Any]] = runs.read(default: [[String: Any]]())
        if let i = rr.firstIndex(where: { ($0["id"] as? String) == runId }) { rr[i] = item } else { rr.append(item) }
        runs.write(Array(rr.suffix(120)).map { Dots.lighten($0) })
        Dots.runsLock.unlock()
        onEvent(.done(id: "podcast", label: "Podcast hebdo"))
        return item
    }

    // MARK: sobriété des passages (runs légers)
    /// Run allégé : résultat ≤ 6 000 caractères, 10 dernières étapes, sortie d'étape ≤ 400 caractères (format inchangé).
    static func lighten(_ run: [String: Any]) -> [String: Any] {
        var r: [String: Any] = run
        if let t = r["result"] as? String, t.count > 6000 { r["result"] = String(t.prefix(6000)) + "\n[…tronqué]" }
        if let st = r["steps"] as? [[String: Any]] {
            var out: [[String: Any]] = []
            for s in st.suffix(10) {
                var e: [String: Any] = s
                if let o = e["output"] as? String, o.count > 400 { e["output"] = String(o.prefix(400)) }
                if let i = e["input"] as? String, i.count > 200 { e["input"] = String(i.prefix(200)) }
                out.append(e)
            }
            r["steps"] = out
        }
        return r
    }

    // MARK: brouillons (quota par Dot)
    func draftCountToday(_ id: String?) -> Int {
        let day: String = String(nowISO().prefix(10))
        var n: Int = 0
        for d in tools.drafts.read(default: [[String: Any]]()) {
            if let want = id { guard (d["dot"] as? String) == want else { continue } }
            let ts: String = (d["ts"] as? String) ?? ""
            if ts.hasPrefix(day) { n += 1 }
        }
        return n
    }
    /// Ajoute le champ « dot » aux brouillons créés pendant ce passage (draft_reply ne connaît pas son auteur).
    func tagDrafts(_ id: String, before: Set<String>) {
        var l: [[String: Any]] = tools.drafts.read(default: [[String: Any]]())
        var changed: Bool = false
        for i in l.indices {
            guard let did = l[i]["id"] as? String, !before.contains(did), l[i]["dot"] == nil else { continue }
            l[i]["dot"] = id; changed = true
        }
        if changed { tools.drafts.write(l) }
    }

    // MARK: chef d'orchestre
    /// Ligne « À TOI : … » du rapport quand une décision humaine est attendue (nil si « rien » ou absente).
    static func decisionLine(_ text: String) -> String? {
        for raw in text.split(separator: "\n") {
            let line: String = String(raw)
            guard let r = line.range(of: "à toi :", options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let rest: String = String(line[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " *_:-\t"))
            if rest.isEmpty { continue }
            if rest.lowercased().hasPrefix("rien") { return nil }
            return String(rest.prefix(200))
        }
        return nil
    }
    /// FLOTTE V1 (25/10) : la ligne « À TOI » est-elle une VRAIE décision d'Ahadi ? Non quand l'Éclat propose une
    /// lecture (« veux-tu que je relise / relance… », « lecture seule », « voir si… ») ou un réglage d'accès, sans
    /// rien à envoyer, payer, supprimer, publier, signer ni trancher. Mots cherchés sans accents ni majuscules.
    static let decisionWords: [String] = ["envoy", "envoi", "payer", "paie", "paiement", "virement", "transf", "credit", "supprim", "effac", "publi", "signer", "signature", "valid", "accept", "refus", "choisi", "choix", "tranch", "arbitr", "achet", "vendre", "inscri", "postul", "soumet", "soumission", "repondre a", "reponds a", "ecrire a", "par mail", "un mail", "un message", "confirme ta", "decid", "approuv", "budget", "rendez-vous", "rdv"]
    static let readOnlyWords: [String] = ["veux-tu que je", "souhaites-tu que je", "voulez-vous que je", "dois-je ", "relanc", "relis", "relire", "relise", "relecture", "lecture seule", "lire ", "verifi", "voir si", "passage dedie", "consulte", "regarde", "reessai", "retest", "diagnost", "coche", "autoris", "reglages systeme", "acces", "reconnect"]
    static func isRealDecision(_ q: String) -> Bool {
        let low: String = q.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        if low.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        var real: Bool = false
        for w in Dots.decisionWords where low.contains(w) { real = true; break }
        if real { return true }
        for w in Dots.readOnlyWords where low.contains(w) { return false }
        return true
    }
    /// Passage précédent (planifié, abouti) d'un Éclat, en note pour le passage suivant ; vide s'il n'y en a pas ou s'il a échoué.
    func previousNote(_ id: String) -> String {
        for r in history(id) {
            if (r["statut"] as? String) == "en_cours" { continue }
            if (r["arrete"] as? Bool) == true { continue }
            let t: String = (r["task"] as? String) ?? ""
            if t.hasPrefix("[SUIVI]") { continue }
            if (r["status"] as? String) == "ECHEC" { return "" }
            let res: String = ((r["result"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if res.isEmpty { return "" }
            let ts: String = String(((r["ts"] as? String) ?? "").prefix(16)).replacingOccurrences(of: "T", with: " ")
            let cut: String = String(res.prefix(700))
            return "\n\nTON PASSAGE PRÉCÉDENT (\(ts) UTC) disait :\n\(cut)\nNe répète pas ce qui y figurait déjà, sauf changement réel : signale seulement le NOUVEAU. Si rien n'a changé et que ta fiche prévoit « RAS », réponds « RAS »."
        }
        return ""
    }
    /// Échec dû à un outil absent ou non autorisé : la supervision ne servirait à rien.
    static func isMissingTool(_ text: String, _ steps: [[String: String]]) -> Bool {
        for s in steps {
            let o: String = s["output"] ?? ""
            if o.hasPrefix("Outil inconnu") || o.contains("non autorisé pour cet agent") { return true }
        }
        let low: String = text.lowercased()
        if low.contains("outil manquant") || low.contains("outil inconnu") || low.contains("outil non autorisé") { return true }
        return false
    }

    /// LOT2 P-R225 : un résultat d'outil est un échec s'il porte une marque d'échec explicite (même famille que Agent.looksFailed, Tools+Agent.swift:46).
    /// Une sortie vide compte comme échec (choix conservateur : rien de vérifiable n'en est sorti).
    static func toolFailed(_ output: String) -> Bool {
        let o = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if o.isEmpty { return true }
        if o.hasPrefix("Refusé") || o.hasPrefix("Échec") || o.hasPrefix("CONFIRMATION REQUISE") || o.hasPrefix("Outil inconnu") || o.hasPrefix("DÉJÀ EXÉCUTÉ") { return true }
        return o.range(of: "a échoué|délai dépassé|indisponible|introuvable|ne répond pas|erreur|not authorized|non autorisé", options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: anti-boucle
    /// Deux passages consécutifs sans résultat utile (vide, ÉCHEC, ou identique à > 90 % au précédent) → pause automatique 24 h avec motif.
    func checkLoop(_ id: String, _ all: [[String: Any]]) {
        var mine: [[String: Any]] = []
        for r in all.reversed() {
            if (r["statut"] as? String) == "en_cours" { continue }   // SPARK8-D : ignore les runs en vol
            if (r["arrete"] as? Bool) == true { continue }   // VAGUE 2 FIABILITÉ : un run arrêté à la demande n'est ni utile ni inutile
            if (r["dot"] as? String) != id { continue }
            let t: String = (r["task"] as? String) ?? ""
            if t.hasPrefix("[SUIVI]") { continue }
            mine.append(r)
            if mine.count >= 3 { break }
        }
        guard mine.count >= 2 else { return }
        var older: [String: Any]? = nil
        if mine.count >= 3 { older = mine[2] }
        guard let a = Dots.uselessReason(mine[0], prev: mine[1]) else { return }
        guard let b = Dots.uselessReason(mine[1], prev: older) else { return }
        guard let d = list().first(where: { ($0["id"] as? String) == id }) else { return }
        var n: [String: Any] = d
        n.removeValue(forKey: "persona")
        n["paused"] = true
        n["pause_auto"] = true
        n["paused_until"] = Date().addingTimeInterval(24 * 3600).timeIntervalSince1970
        n["paused_at"] = nowISO()
        n["pause_motif"] = "Pause automatique 24 h (anti-boucle) : 2 passages sans résultat utile (" + b + ", puis " + a + ")."
        save(n)
    }
    static func uselessReason(_ r: [String: Any], prev: [String: Any]?) -> String? {
        let text: String = ((r["result"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "rapport vide" }
        let st: String = (r["status"] as? String) ?? ""
        if st == "ECHEC" { return "échec" }
        if st == "RAS" { return nil }   // « rien à signaler » est un résultat utile
        guard let p = prev else { return nil }
        let pt: String = ((p["result"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if pt.isEmpty { return nil }
        let sim: Double = Dots.similarity(String(text.prefix(400)), String(pt.prefix(400)))
        if sim > 0.9 { return "résultat identique au précédent" }
        return nil
    }
    /// Similarité 0…1 (distance d'édition normalisée).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x: [Unicode.Scalar] = Array(a.unicodeScalars)
        let y: [Unicode.Scalar] = Array(b.unicodeScalars)
        let n: Int = x.count
        let m: Int = y.count
        if n == 0 && m == 0 { return 1 }
        if n == 0 || m == 0 { return 0 }
        var prev: [Int] = Array(0...m)
        var cur: [Int] = Array(repeating: 0, count: m + 1)
        for i in 1...n {
            cur[0] = i
            for j in 1...m {
                var cost: Int = 1
                if x[i - 1] == y[j - 1] { cost = 0 }
                let del: Int = prev[j] + 1
                let ins: Int = cur[j - 1] + 1
                let sub: Int = prev[j - 1] + cost
                cur[j] = min(del, min(ins, sub))
            }
            swap(&prev, &cur)
        }
        let dist: Double = Double(prev[m])
        let longest: Double = Double(max(n, m))
        return 1.0 - dist / longest
    }

    // MARK: résumé pour le prompt de l'assistant (lot B)
    nonisolated(unsafe) static var summaryCache: (Date, String)? = nil
    static let summaryLock = NSLock()
    /// État des Dots en ≤ 600 caractères : actifs / en pause, dernier passage, échecs 24 h, décisions en attente. Lecture seule, cache 60 s.
    public static func summaryForPrompt() -> String {
        summaryLock.lock()
        if let c = summaryCache, Date().timeIntervalSince(c.0) < 60 { summaryLock.unlock(); return c.1 }
        summaryLock.unlock()
        let s: String = buildSummary()
        summaryLock.lock(); summaryCache = (Date(), s); summaryLock.unlock()
        return s
    }
    static func buildSummary() -> String {
        let all: [[String: Any]] = JSONFile("dots.json").read(default: [[String: Any]]())
        let hist: [[String: Any]] = JSONFile("dots_runs.json").read(default: [[String: Any]]()).filter { ($0["statut"] as? String) != "en_cours" }   // SPARK8-D : ignore les runs en vol
        let pend: [[String: Any]] = JSONFile("dots_attente.json").read(default: [[String: Any]]())
        var names: [String: String] = [:]
        var active: Int = 0
        var paused: Int = 0
        var autoPaused: Int = 0
        var retiredN: Int = 0
        for d in all {
            guard let id = d["id"] as? String else { continue }
            names[id] = (d["name"] as? String) ?? id
            if (d["retired"] as? Bool) == true && (d["paused"] as? Bool) == true { retiredN += 1; continue }   // FLOTTE V1 : un retiré n'est ni actif ni « en pause »
            if (d["paused"] as? Bool) == true {
                paused += 1
                if (d["pause_auto"] as? Bool) == true { autoPaused += 1 }
            } else {
                active += 1
            }
        }
        var s: String = "DOTS : " + String(active) + " actifs, " + String(paused) + " en pause"
        if autoPaused > 0 { s += " (dont " + String(autoPaused) + " en pause auto anti-boucle)" }
        if retiredN > 0 { s += ", \(retiredN) retirés" }
        s += "."
        if let last = hist.last {
            let did: String = (last["dot"] as? String) ?? ""
            let nm: String = names[did] ?? did
            let ts: String = String(((last["ts"] as? String) ?? "").prefix(16)).replacingOccurrences(of: "T", with: " ")
            var st: String = (last["status"] as? String) ?? ""
            if st.isEmpty { st = "?" }
            s += " Dernier passage : " + nm + " (" + ts + " UTC, " + st + ")."
        }
        let cutoff: String = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86400))
        var failed: [String] = []
        for r in hist {
            let ts: String = (r["ts"] as? String) ?? ""
            if ts < cutoff { continue }
            if (r["ok"] as? Bool) != false { continue }
            let did: String = (r["dot"] as? String) ?? "?"
            let nm: String = names[did] ?? did
            if !failed.contains(nm) { failed.append(nm) }
        }
        if failed.isEmpty { s += " Aucun échec sur 24 h." } else { s += " Échecs 24 h : " + failed.prefix(5).joined(separator: ", ") + "." }
        let now: Double = Date().timeIntervalSince1970
        var waiting: Int = 0
        var decisions: [String] = []
        for p in pend {
            if let u = p["until"] as? Double, u > now { continue }
            waiting += 1
            guard (p["decision"] as? Bool) == true else { continue }
            let did: String = (p["dot"] as? String) ?? "?"
            let nm: String = names[did] ?? did
            let q: String = String(((p["question"] as? String) ?? "").prefix(90))
            if q.isEmpty { decisions.append(nm) } else { decisions.append(nm + " : " + q) }
        }
        s += " Résultats non ouverts : " + String(waiting) + "."
        if decisions.isEmpty {
            s += " Aucune décision en attente."
        } else {
            s += " Décisions en attente (" + String(decisions.count) + ") : " + decisions.prefix(3).joined(separator: " | ") + "."
        }
        if s.count > 600 { s = String(s.prefix(599)) + "…" }
        return s
    }
}


extension Dots {
    /// 26/10 : retire le balisage « harmony » qui fuyait dans les rapports d'Éclats ; vide si ce n'était qu'un appel d'outil avorté.
    static func stripHarmony(_ t: String) -> String {
        var s: String = t
        // un appel d'outil en clair : <|start|>assistant<|channel|>commentary to=… <|constrain|>json<|message|>{…}<|call|>
        s = s.replacingOccurrences(of: #"<\|start\|>[\s\S]*?<\|call\|>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<\|channel\|>\s*(analysis|commentary|final)?"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<\|[a-z_]+\|>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
