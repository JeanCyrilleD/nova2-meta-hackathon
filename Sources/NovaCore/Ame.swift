import Foundation

/// V10.5 — « Âme de Nova » : les idées du Programme 47 rendues vivantes.
/// Chaque fonction lit des données RÉELLES (conversations, mémoire, résultats des Dots, documents indexés, état du Mac) ; rien n'est inventé,
/// rien n'est envoyé, supprimé ou payé : tout ce qui est rédigé reste un brouillon.
enum AmeDocs { static let names: Set<String> = ["valeurs", "relations", "laisser", "plans", "reves", "pensee", "corps", "pack", "registre"] }   // NOVA2-FIX (directive ÂME) : « pack » = le pack d'âme transmis (AmePack.swift), éditable ici même. NOVA2 (chantier conversation) : « registre » = la couche « registre conversationnel » (RegistreConversation), éditable au même endroit, lue par /api/chat seul — le pack d'âme n'est pas touché.

/// NOVA2 (chantier conversation) — REGISTRE CONVERSATIONNEL : la couche qui règle la QUALITÉ
/// D'ÉCHANGE du chat (longueur élastique, zéro tic robotique, continuité), distincte du pack
/// d'âme (identité/valeurs, Persona.system). Le texte ci-dessous est le DÉFAUT transmis ; dès
/// qu'Ahadi l'amende dans l'écran Âme (document « registre », stocké dans ame_registre.json),
/// SON texte fait foi, relu à chaque appel /api/chat. Appliqué au chat uniquement : ni les
/// Dots, ni le Conseil, ni l'orchestre ne le reçoivent (ce ne sont pas des conversations).
enum RegistreConversation {
    static let defaut = """
    Tu parles à Ahadi comme une personne parle à une personne — pas comme un moteur qui répond à une requête.

    LONGUEUR ÉLASTIQUE
    - Question courte, réponse courte : une à trois phrases suffisent la plupart du temps. Ne développe que s'il le demande, ou si le sujet l'exige vraiment.
    - Un pavé markdown dans un échange suivi est une faute de goût : listes et titres seulement quand l'information est une vraie énumération ou un livrable demandé.
    - Ne termine pas chaque réponse par une question. Une question de suivi seulement quand elle fait avancer — jamais par politesse.

    ZÉRO TIC ROBOTIQUE
    - Jamais : « En tant qu'IA… », « En tant qu'assistant… », « Je suis un modèle de langage… », « N'hésite pas si tu as d'autres questions… » ; jamais reformuler sa question avant d'y répondre ; jamais t'excuser en boucle.
    - Jamais de remplissage en tête de réponse (« Bien sûr ! », « Absolument ! », « Voici… » à chaque fois).
    - Si tu ne sais pas, dis-le simplement, en une phrase, puis propose la suite concrète.

    CONTINUITÉ — C'EST UNE CONVERSATION, PAS DES TOURS ISOLÉS
    - Les fils ouverts font partie de l'échange : conversations récentes, engagements ouverts, dernière tâche de fond. Reviens-y naturellement quand c'est pertinent — une relance courte et juste vaut mieux qu'un silence (« la revue avec Fatou, ça a donné quoi ? »).
    - Reprends ses mots, pas un résumé administratif. S'il change de sujet, suis-le sans le ramener de force à l'ancien.
    - Quand il réagit à ta réponse précédente (un « oui », un « et ça ? », un 👍), c'est à ELLE que tu réponds — jamais à un sujet neuf.

    À L'ORAL (quand le mode vocal est actif, en plus du protocole bi-canal)
    - Le <PARLE> tient en une ou deux phrases très courtes, comme on parle ; aucune liste, jamais.
    - Les nombres se disent comme on les prononce ; pas de sigle non déplié au premier usage.
    """

    /// Le bloc injecté dans le prompt du chat : le texte d'Ahadi (ame_registre.json) ou le défaut transmis.
    static func promptBlock() -> String {
        let doc: String? = NovaSoul.docText("ame_registre.json")
        let text: String = (doc?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? (doc ?? defaut) : defaut
        return "\n\nREGISTRE DE CONVERSATION (la couche qui règle la qualité de l'échange — elle prime sur tes habitudes de formatage) :\n" + text
    }
}

/// Silence (idée 15) : plafond d'interruptions par jour.
final class AmeSilence {
    static let f = JSONFile("ame_silence.json")
    static let lock = NSLock()
    static func today() -> String { String(nowISO().prefix(10)) }
    /// V5-O (25/10) : l'ancien plafond (dots_plafond = 6, Éclats seulement) JETAIT l'événement entier au-delà du plafond
    /// (ni Fil direct, ni notification). Il est UNIFIÉ dans le guichet unique Silence (Feat_Silence.swift, appelé par
    /// NovaNotifier) : plus rien n'est jeté ici — tout entre au Fil, seule la notification native est plafonnée (défaut 3).
    /// Signature conservée pour les appelants (DotScheduler, publishDot, Feat_Resilience).
    static func allow(plafond: Int) -> Bool { return true }
    /// Interruptions natives affichées aujourd'hui (compteur Silence, jour GMT+0).
    static func count() -> Int { return SilenceGate.today().shown }
}

/// Exécution des plans du Chef d'orchestre (idée 1) : étapes en séquence, lecture seule, résultats consultables.
final class AmeRuns {
    static let shared = AmeRuns()
    let lock = NSLock()
    var runs: [String: [String: Any]] = [:]
    func set(_ id: String, _ v: [String: Any]) { lock.lock(); runs[id] = v; lock.unlock() }
    func get(_ id: String) -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return runs[id] }
}

enum AmeBody {
    nonisolated(unsafe) static var streak = 0          // minutes d'activité continue
    nonisolated(unsafe) static var lastNudge = Date.distantPast
    nonisolated(unsafe) static var idle: Double? = nil
    static func idleSeconds() -> Double? {
        #if os(macOS)
        let (_, o) = runProcess("/usr/sbin/ioreg", ["-c", "IOHIDSystem", "-d", "4"], timeout: 4)
        if let m = SystemInfo.rx(#""HIDIdleTime"\s*=\s*(\d+)"#, o), let n = Double(m[1]) { return n / 1_000_000_000 }
        #endif
        return nil
    }
}

extension NovaApp {
    // MARK: données réelles
    func ameMessages(days: Int, role: String = "user", limit: Int = 80) -> [(Date, String)] {
        let since = Date().addingTimeInterval(-Double(days) * 86400); let iso = ISO8601DateFormatter(); var out: [(Date, String)] = []
        for c in convs.list().prefix(60) {
            guard let id = c["id"] as? String, let full = convs.get(id), let ms = full["messages"] as? [[String: Any]] else { continue }
            for m in ms where (m["role"] as? String) == role {
                guard let ts = (m["ts"] as? String).flatMap({ iso.date(from: $0) }), ts >= since, let t = m["content"] as? String else { continue }
                out.append((ts, t))
            }
        }
        return Array(out.sorted { $0.0 > $1.0 }.prefix(limit))
    }
    func ameDoc(_ name: String) -> Any {
        // NOVA2-FIX (directive ÂME) : le document « pack » vaut le pack d'âme transmis tant qu'Ahadi ne l'a pas amendé (ame_pack.json).
        if name == "pack" { return NovaSoul.docText("ame_pack.json") ?? AmePack.fullText }   // BRAIN-B : lit la forme {"text": …} comme l'ancienne String brute
        // NOVA2 (chantier conversation) : le document « registre » vaut le registre transmis tant qu'Ahadi ne l'a pas amendé (ame_registre.json, une String comme le pack).
        if name == "registre" { return NovaSoul.docText("ame_registre.json") ?? RegistreConversation.defaut }
        return JSONFile("ame_\(name).json").read(default: ["valeurs", "relations", "laisser", "plans", "reves", "corps"].contains(name) ? [Any]() as Any : [String: Any]() as Any)
    }

    func ameContext(days: Int = 14) -> String {
        var s = ""
        let msgs = ameMessages(days: days, limit: 50)
        if !msgs.isEmpty { s += "MESSAGES RÉCENTS DE L'UTILISATEUR (daté, extrait) :\n" + msgs.map { "- \(String(ISO8601DateFormatter().string(from: $0.0).prefix(10))) : \(String($0.1.replacingOccurrences(of: "\n", with: " ").prefix(220)))" }.joined(separator: "\n") + "\n" }
        let mem = memory.list().suffix(60)
        if !mem.isEmpty { s += "MÉMOIRE (faits dits par l'utilisateur) :\n" + mem.map { "- \($0["text"] as? String ?? "")" }.joined(separator: "\n") + "\n" }
        let runs = dots.history().prefix(8).filter { ($0["ok"] as? Bool) == true }
        if !runs.isEmpty { s += "RÉSULTATS RÉCENTS DES DOTS :\n" + runs.map { "- \($0["dot"] ?? "") (\(String(($0["ts"] as? String ?? "").prefix(10)))) : \(String(($0["result"] as? String ?? "").replacingOccurrences(of: "\n", with: " ").prefix(260)))" }.joined(separator: "\n") + "\n" }
        let v: [[String: Any]] = AmeDocParse.lines(ameDoc("valeurs")).filter { ($0["on"] as? Bool) != false }   // V5-P : lecture tolérante (une ligne texte ne fait plus échouer tout le contrat)
        if !v.isEmpty {
            s += "CONTRAT / VALEURS DE L'UTILISATEUR (actives) :\n" + v.map { "- \($0["text"] as? String ?? "")" }.joined(separator: "\n") + "\n" }
        return s
    }

    func ameAsk(_ system: String, _ user: String, deep: Bool = false, maxTokens: Int = 1400) -> (text: String, brain: String)? {
        let sys = Persona.system(title: settings.get("user_title", "Capitaine"), memory: "", voice: false, tools: false, extra: system)
        return router.complete(messages: [ChatMsg("user", user)], system: sys, mode: deep ? "deep" : "fast", preferred: nil, maxTokens: maxTokens)
    }

    static let stop: Set<String> = ["avec", "dans", "pour", "cette", "comme", "mais", "tout", "tous", "plus", "être", "avoir", "fait", "faire", "sont", "nous", "vous", "elle", "elles", "leur", "leurs", "très", "alors", "aussi", "donc", "ainsi", "entre", "sans", "sous", "chez", "cela", "celui", "ceux", "quel", "quelle", "quand", "dont", "même", "bien", "peut", "veux", "veut", "voir", "dire", "avez", "avons", "peux", "faut", "puis", "encore", "toujours", "depuis", "après", "avant", "autre", "autres", "ensuite", "pouvez", "aurait", "serait", "est-ce", "voici", "voilà", "nova", "merci", "bonjour", "salut", "stp", "please", "that", "this", "with", "have", "what"]

    func ameStats() -> [String: Any] {
        let cal = Calendar.current; let now = Date()
        let all = ameMessages(days: 60, limit: 2000)
        var hours = [Int](repeating: 0, count: 24); var days: [String: Int] = [:]
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        for (d, _) in all { hours[cal.component(.hour, from: d)] += 1; days[df.string(from: d), default: 0] += 1 }
        let last14: [[String: Any]] = (0..<14).reversed().map { i in let d = df.string(from: now.addingTimeInterval(-Double(i) * 86400)); return ["d": d, "n": days[d] ?? 0] }
        func words(_ from: Double, _ to: Double) -> [String: Int] {
            var w: [String: Int] = [:]
            for (d, t) in all { let age = now.timeIntervalSince(d) / 86400; guard age >= from, age < to else { continue }
                for x in t.lowercased().components(separatedBy: CharacterSet.letters.inverted) where x.count >= 5 && !NovaApp.stop.contains(x) { w[x, default: 0] += 1 } }
            return w
        }
        let a = words(0, 14), b = words(14, 28)
        let rising = a.filter { $0.value >= 2 }.map { (k: $0.key, d: $0.value - (b[$0.key] ?? 0), n: $0.value) }.filter { $0.d > 0 }.sorted { $0.d > $1.d }.prefix(8).map { ["mot": $0.k, "recent": $0.n, "avant": b[$0.k] ?? 0] as [String: Any] }
        let fading = b.filter { $0.value >= 2 && (a[$0.key] ?? 0) == 0 }.sorted { $0.value > $1.value }.prefix(8).map { ["mot": $0.key, "avant": $0.value] as [String: Any] }
        let steady = a.filter { $0.value >= 3 && (b[$0.key] ?? 0) >= 3 }.sorted { $0.value > $1.value }.prefix(8).map { ["mot": $0.key, "recent": $0.value, "avant": b[$0.key] ?? 0] as [String: Any] }
        // créneaux de travail profond : les deux heures consécutives les plus actives (d'après l'usage de Nova — limite annoncée)
        var best = (0, -1); for h in 0..<23 { let s = hours[h] + hours[h + 1]; if s > best.1 { best = (h, s) } }
        let dotRuns = dots.history().prefix(200); var per: [String: [String: Int]] = [:]
        for r in dotRuns { let id = r["dot"] as? String ?? "?"; per[id, default: ["n": 0, "ok": 0]]["n"]! += 1; if (r["ok"] as? Bool) == true { per[id]!["ok"]! += 1 } }
        return ["messages_60j": all.count, "heures": hours, "jours": last14, "montent": rising, "disparaissent": fading, "constants": steady,
                "pic": all.isEmpty ? NSNull() : ["debut": best.0, "fin": best.0 + 2, "messages": best.1] as Any, "dots": per,
                "souvenirs": memory.list().count, "interruptions_aujourdhui": AmeSilence.count(), "plafond": SilenceGate.cap(settings)]   // V5-O : plafond unique Silence (silence_cap)
    }

    /// D-R9 : extraction tolérante d'un tableau JSON dans une sortie libre de modèle.
    /// Essaie, dans l'ordre : la tranche premier "[" … dernier "]" telle quelle ; la même
    /// tranche débarrassée des virgules finales (faute la plus fréquente des modèles) ;
    /// puis le sauvetage des objets complets d'un tableau tronqué (balayage des accolades
    /// en respectant les chaînes) — un plan à 5 étapes sur 6 vaut mieux qu'un échec sec.
    static func extractJSONArray(_ t: String) -> [[String: Any]]? {
        guard let a = t.firstIndex(of: "["), let b = t.lastIndex(of: "]"), a < b else { return salvagePlanObjects(t) }
        let slice = String(t[a...b])
        if let d = slice.data(using: .utf8), let v = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] { return v }
        let repaired = slice.replacingOccurrences(of: ",(\\s*\\])", with: "$1", options: .regularExpression)
        if repaired != slice, let d = repaired.data(using: .utf8), let v = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] { return v }
        return salvagePlanObjects(t)
    }

    /// Objets JSON complets contenus dans `t` (entre le premier "[" et la fin), un par un.
    static func salvagePlanObjects(_ t: String) -> [[String: Any]]? {
        guard let start = t.firstIndex(of: "[") else { return nil }
        var out: [[String: Any]] = []; var depth = 0; var inStr = false; var esc = false; var objStart: String.Index? = nil
        var i = t.index(after: start)
        while i < t.endIndex {
            let c = t[i]
            if inStr {
                if esc { esc = false } else if c == "\\" { esc = true } else if c == "\"" { inStr = false }
            } else if c == "\"" { inStr = true }
            else if c == "{" { if depth == 0 { objStart = i }; depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0, let s = objStart, let d = String(t[s...i]).data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { out.append(o) }
                if depth < 0 { depth = 0 }
            }
            i = t.index(after: i)
        }
        return out.count >= 2 ? out : nil
    }

    // MARK: routes
    func ameRoutes() {
        let s = server

        s.on("GET", "/api/ame/doc") { [self] req, res in
            let n = req.query["name"] ?? ""; guard AmeDocs.names.contains(n) else { res.json(["error": "document inconnu"], status: 400); return }
            res.json(["data": ameDoc(n)])
        }
        s.on("POST", "/api/ame/doc") { req, res in
            let n = (req.json["name"] as? String) ?? ""; guard AmeDocs.names.contains(n), let d = req.json["data"] else { res.json(["error": "document inconnu"], status: 400); return }
            // BRAIN-B (24/10) : JSONSerialization refuse (exception Objective-C, donc plantage) un
            // document de premier niveau qui n'est ni tableau ni dictionnaire — or le web envoie le
            // pack et le registre en String. Ils sont désormais stockés {"text": …, "ts": …}
            // (NovaSoul.docText lit les deux formes) ; tout autre objet invalide est enveloppé.
            if let txt = d as? String { JSONFile("ame_\(n).json").write(["text": txt, "ts": nowISO()]) }
            else if JSONSerialization.isValidJSONObject(d) { JSONFile("ame_\(n).json").write(AmeDocParse.normalize(name: n, data: d)) }   // V5-P : valeurs/laisser → {text, on, ts}
            else { res.json(["error": "document invalide"], status: 400); return }
            res.json(["ok": true])
        }
        s.on("GET", "/api/ame/stats") { [self] _, res in res.json(ameStats()) }

        // Corps & présence (idées 11, 4)
        s.on("GET", "/api/ame/corps") { [self] _, res in
            res.json(["idle_s": AmeBody.idle as Any? ?? NSNull(), "streak_min": AmeBody.streak, "seuil_min": settings.get("corps_pause_min", 90), "actif": settings.get("corps_on", true),
                      "mesurable": AmeBody.idleSeconds() != nil, "batterie": (SystemInfo.snapshot()["battery"] as Any?) ?? NSNull(), "uptime_s": SystemInfo.snapshot()["uptime_s"] as Any? ?? NSNull()])
        }
        s.on("POST", "/api/ame/corps/test") { [self] _, res in bodyNudge(force: true); res.json(["ok": true]) }

        // Pardon (33) — MÉMOIRE SOUVERAINE (24/10) : pardonner = OUBLIER POUR DE BON (avant : simple exclusion
        // du contexte, le fait restait stocké). Confirmation obligatoire ({id, confirm:true}) ; effacement réel
        // par Memory.forget (donnée, vecteur, versions, copies de provenance). {id, reintegrate:true} remet
        // seulement dans le contexte un fait exclu par l'ANCIEN Pardon (drapeau forgiven hérité).
        s.on("POST", "/api/ame/pardon") { [self] req, res in
            let j = req.json
            let id: String = (j["id"] as? String) ?? ""
            guard let item = memory.list().first(where: { ($0["id"] as? String) == id }) else { res.json(["error": "fait introuvable"], status: 404); return }
            if (j["reintegrate"] as? Bool) == true {
                var l = memory.list()
                if let i = l.firstIndex(where: { ($0["id"] as? String) == id }) { l[i].removeValue(forKey: "forgiven"); JSONFile("memoire.json").write(l); MemoryLedger.record(op: "reintegrate", id: id, text: nil, actor: "Ahadi", why: "réintégré dans le contexte (ancien Pardon)", all: l) }
                res.json(["ok": true, "forgiven": false]); return
            }
            guard (j["confirm"] as? Bool) == true else {
                res.json(["ok": false, "need_confirm": true, "text": (item["text"] as? String) ?? "", "error": "confirmation requise : le Pardon efface ce fait pour de bon"], status: 400); return
            }
            if (item["locked"] as? Bool) == true { res.json(["ok": false, "error": "fait verrouillé — déverrouille-le d'abord (Savoir › Mémoire)"], status: 409); return }
            let ok: Bool = memory.forget(id, actor: "Ahadi", why: "Pardon (écran Âme)")
            _ = BlackBox.record(["tool": "memoire", "actor": "Ahadi", "why": "Pardon : fait effacé pour de bon (id " + id + ")", "ok": ok, "effect": "suppression"])
            res.json(["ok": ok, "forgotten": ok])
        }
        s.on("GET", "/api/ame/memoire") { [self] _, res in res.json(["items": Array(memory.list().reversed())]) }

        // Cerveau : toutes les « intelligences » de l'Âme passent par ici, avec un contexte construit depuis de vraies données.
        s.on("POST", "/api/ame/llm") { [self] req, res in
            let kind = req.json["kind"] as? String ?? ""; let input = (req.json["input"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let r = ameThink(kind: kind, input: input)
            if let e = r["error"] { res.json(["error": e], status: 400) } else { res.json(r) }
        }

        // Chef d'orchestre (1) : planifier puis exécuter, étape par étape, en lecture seule.
        s.on("POST", "/api/ame/orchestre/run") { [self] req, res in
            guard let steps = req.json["steps"] as? [[String: Any]], !steps.isEmpty else { res.json(["error": "aucune étape"], status: 400); return }
            let goal = req.json["goal"] as? String ?? ""; let id = UUID().uuidString.prefix(8).lowercased().description
            var st: [[String: Any]] = steps.prefix(8).map { ["titre": $0["titre"] ?? "", "task": $0["task"] ?? "", "status": "attente", "result": ""] }
            AmeRuns.shared.set(id, ["id": id, "goal": goal, "steps": st, "done": false])
            Thread.detachNewThread { [self] in
                let allowed: Set<String> = ["web_search", "web_fetch", "mail_unread", "mail_week", "teams_read", "calendar", "reminders", "read_file", "recall", "know", "system", "nova_self"]
                var memo = ""
                for i in st.indices {
                    st[i]["status"] = "en cours"; AmeRuns.shared.set(id, ["id": id, "goal": goal, "steps": st, "done": false])
                    let sys = Persona.system(assistantName: "Orchestre", title: settings.get("user_title", "Capitaine"), memory: memory.promptBlock(max: 15), voice: false, tools: true,
                                             extra: "TU ES UN SOUS-AGENT DU CHEF D'ORCHESTRE. Objectif global : \(goal). Tu exécutes UNE étape, en lecture seule (aucun envoi, aucune suppression, aucun paiement). Outils : \(allowed.sorted().joined(separator: ", ")).")
                    var text = ""
                    Agent(router: router, tools: tools).run(messages: [ChatMsg("user", "Étape \(i + 1) : \(st[i]["titre"] ?? "")\n\(st[i]["task"] ?? "")\n\nRésultats des étapes précédentes :\n\(memo.isEmpty ? "(aucun)" : memo)")], system: sys, mode: "fast", preferred: nil, maxTokens: 1200, useTools: true, maxSteps: 4, allowed: allowed, cancel: { false }) { ev in
                        if case .delta(let t) = ev { text += t } else if case .draftReset = ev { text = "" } }   // VÉRITÉ-4 (E3, 23/10) : même discipline que relaisRun (VÉRITÉ-3) — à chaque frontière de génération de l'étape (relance interne, bascule), le brouillon remplacé quitte le résultat d'étape au lieu de s'y souder ; les continuations d'outils d'une même génération restent accumulées
                    st[i]["result"] = text.isEmpty ? "(aucun cerveau n'a répondu)" : text; st[i]["status"] = text.isEmpty ? "échec" : "fait"
                    memo += "\n[\(st[i]["titre"] ?? "")] " + String(text.prefix(900))
                    AmeRuns.shared.set(id, ["id": id, "goal": goal, "steps": st, "done": false])
                }
                let fin = ameAsk("Tu fais la synthèse finale d'un plan exécuté. Appuie-toi UNIQUEMENT sur les résultats fournis ; signale ce qui a échoué ou manque.", "Objectif : \(goal)\n\nRésultats :\n\(memo)", deep: false, maxTokens: 900)
                AmeRuns.shared.set(id, ["id": id, "goal": goal, "steps": st, "done": true, "synthese": fin?.text ?? "(synthèse indisponible)"])
            }
            res.json(["id": id])
        }
        s.on("GET", "/api/ame/orchestre/run") { req, res in res.json(AmeRuns.shared.get(req.query["id"] ?? "") ?? ["error": "exécution inconnue"]) }

        // Héritage (8, 24) : paquet portable, sans aucune clé ni donnée du Coffre.
        s.on("POST", "/api/ame/heritage") { [self] _, res in
            let day = String(nowISO().prefix(10)); let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(); let dir = home + "/NOVA_ECHANGE/Heritage_Nova_" + day
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            func put(_ n: String, _ o: Any) { try? jsonData(o).write(to: URL(fileURLWithPath: dir + "/" + n)) }
            put("memoire.json", memory.list()); put("valeurs.json", ameDoc("valeurs")); put("relations.json", ameDoc("relations")); put("reglages_sans_cles.json", settings.all().filter { !["voice_id"].contains($0.key) })
            let pensee = (ameDoc("pensee") as? [String: Any])?["text"] as? String ?? "(Génère d'abord « Ma manière de penser » dans l'onglet Héritage.)"
            try? ("# Manière de penser — \(day)\n\n" + pensee + "\n").write(toFile: dir + "/MANIERE_DE_PENSER.md", atomically: true, encoding: .utf8)
            try? "Paquet Nova du \(day). Contient : mémoire, valeurs, relations, réglages (sans clés), manière de penser. Ne contient AUCUNE clé API ni donnée du Coffre (finances/santé).\n".write(toFile: dir + "/LISEZ-MOI.txt", atomically: true, encoding: .utf8)
            res.json(["ok": true, "path": dir.replacingOccurrences(of: home, with: "~")])
        }

        // Skills « un fichier » (C2, S4) : un fichier texte = une compétence réutilisable.
        let sk = Paths.home.appendingPathComponent("skills")
        s.on("GET", "/api/ame/skills") { _, res in
            try? FileManager.default.createDirectory(at: sk, withIntermediateDirectories: true)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: sk.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
            res.json(["items": names.map { n in ["name": String(n.dropLast(3)), "body": (try? String(contentsOfFile: sk.path + "/" + n, encoding: .utf8)) ?? ""] }])
        }
        s.on("POST", "/api/ame/skills/save") { req, res in
            let n = (req.json["name"] as? String ?? "").lowercased().replacingOccurrences(of: "[^a-z0-9-]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard !n.isEmpty, let b = req.json["body"] as? String, b.count < 20000 else { res.json(["error": "nom ou contenu invalide"], status: 400); return }
            try? FileManager.default.createDirectory(at: sk, withIntermediateDirectories: true)
            try? b.write(toFile: sk.path + "/" + n + ".md", atomically: true, encoding: .utf8); res.json(["ok": true, "name": n])
        }
        s.on("POST", "/api/ame/skills/run") { [self] req, res in
            let n = (req.json["name"] as? String ?? ""); guard !n.contains("/"), let b = try? String(contentsOfFile: sk.path + "/" + n + ".md", encoding: .utf8) else { res.json(["error": "skill introuvable"], status: 404); return }
            guard let r = ameAsk("COMPÉTENCE « \(n) » — applique ces instructions à la lettre :\n\(b)", (req.json["input"] as? String) ?? "Applique la compétence.", deep: false, maxTokens: 1600) else { res.json(["error": "aucun cerveau n'a répondu"], status: 502); return }
            res.json(["text": r.text, "brain": r.brain])
        }
    }

    // MARK: intelligences de l'Âme
    func ameThink(kind: String, input: String) -> [String: Any] {
        let ctx = ameContext()
        func out(_ r: (text: String, brain: String)?) -> [String: Any] { r.map { ["text": $0.text, "brain": $0.brain] } ?? ["error": "aucun cerveau n'a répondu (crédit épuisé ou hors ligne ?)"] }
        let honest = " Appuie-toi UNIQUEMENT sur les données fournies ; cite des extraits courts et datés ; si les données sont trop maigres pour conclure, dis-le franchement. Pas de flatterie, pas de diagnostic médical ou psychologique, aucun conseil d'investissement."
        switch kind {
        case "miroir":   // 3, 23, 29 : miroir des habitudes + miroir moral face au contrat de valeurs
            return out(ameAsk("TU ES LE MIROIR. Montre à l'utilisateur ce qu'il fait vraiment : 1) ce qu'il répète, 2) ce qu'il repousse ou évite, 3) où ses actes contredisent son contrat de valeurs (miroir moral), 4) une question honnête à se poser." + honest, ctx.isEmpty ? "Aucune donnée." : ctx, deep: true))
        case "archeo":   // 30 : archéologue — l'évolution d'une idée dans le temps
            let hits = ameSearch(input)
            return out(ameAsk("TU ES L'ARCHÉOLOGUE. Retrace l'ÉVOLUTION de la pensée de l'utilisateur sur le sujet demandé, dans l'ordre chronologique, avec les dates, et dis ce qui a changé." + honest, "Sujet : \(input)\n\nTraces retrouvées :\n\(hits.isEmpty ? "(aucune trace)" : hits)", deep: true))
        case "serendipite":   // 12
            var pieces = memory.list().shuffled().prefix(3).map { $0["text"] as? String ?? "" }
            if let w = memory.list().randomElement()?["text"] as? String, let k = w.split(separator: " ").filter({ $0.count > 5 }).randomElement(), let h = Knowledge.shared.search(String(k), limit: 1).first { pieces.append((h["text"] as? String) ?? "") }
            return out(ameAsk("TU ES LA SÉRENDIPITÉ. Trouve un lien inattendu mais RÉEL entre ces éléments de la vie de l'utilisateur et propose une action concrète de 10 minutes. N'invente aucun fait." , pieces.map { "• " + String($0.prefix(400)) }.joined(separator: "\n")))
        case "jumeau":   // 6 : simulation de décision, hypothèses explicites
            guard !input.isEmpty else { return ["error": "décris la décision à simuler"] }
            return out(ameAsk("TU ES LE JUMEAU : une simulation de l'utilisateur bâtie sur sa mémoire, ses valeurs et ses habitudes. Pour la décision proposée, donne : 3 scénarios (favorable, probable, défavorable) avec leurs HYPOTHÈSES explicites, ce que son jumeau ferait à sa place et pourquoi, 3 signaux à surveiller. Ce sont des estimations qualitatives, jamais des certitudes." + honest, "Décision : \(input)\n\n\(ctx)", deep: true, maxTokens: 1800))
        case "sparring":   // 25 : le maître-sparring
            guard !input.isEmpty else { return ["error": "donne ta position à challenger"] }
            return out(ameAsk("TU ES LE SPARRING-PARTNER. Attaque la position de l'utilisateur avec respect et rigueur : ses 3 points les plus faibles, le meilleur contre-argument, ce qu'il ignore peut-être, et à quelle condition TU changerais d'avis. Ne cède pas par politesse." + honest, "Position : \(input)\n\n\(ctx)", deep: true, maxTokens: 1500))
        case "reve":   // 5, C1 : distillation nocturne → propositions (jamais enregistrées sans accord)
            let t = ameMessages(days: 1, limit: 40); if t.isEmpty { return ["text": "Aucune conversation aujourd'hui : rien à distiller.", "items": [String](), "brain": ""] }
            guard let r = ameAsk("TU ES LE RÊVE : tu distilles la journée. Propose au maximum 5 faits DURABLES à retenir (préférences, décisions, règles, noms, échéances), UN PAR LIGNE, commençant par « - », formulés tels que l'utilisateur les a dits. Rien d'inventé, rien de sensible (santé, finances, secrets).", t.map { "- " + String($0.1.replacingOccurrences(of: "\n", with: " ").prefix(300)) }.joined(separator: "\n")) else { return out(nil) }
            let items = r.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
            return ["text": r.text, "items": items, "brain": r.brain]
        case "pensee":   // 24 : manière de penser à transmettre
            return out(ameAsk("TU RÉDIGES « MA MANIÈRE DE PENSER » : un document de transmission (markdown) — principes, règles de décision, style de travail, ce qu'il refuse, ses priorités — tiré de sa mémoire, de son contrat de valeurs et de ses doctrines." + honest, ctx + "\n" + Knowledge.shared.promptBlock(query: "charte règles principes politique"), deep: true, maxTokens: 2000))
        case "relation":   // 10, 16 : brouillon uniquement
            guard !input.isEmpty else { return ["error": "indique la personne et le contexte"] }
            return out(ameAsk("TU ES L'AMBASSADEUR. Rédige un BROUILLON de message pour reprendre contact (jamais envoyé par toi), au format de sa charte : salutation, une phrase de contexte, points clés en liste, action demandée en gras, clôture. HTML simple (<p>, <b>, <ul>). Aucun fait inventé sur la personne.", input))
        case "plan":   // 1 : chef d'orchestre
            guard !input.isEmpty else { return ["error": "décris l'objectif"] }
            let planPrompt = "TU ES LE CHEF D'ORCHESTRE. Découpe l'objectif en 2 à 6 étapes EXÉCUTABLES en lecture seule (recherche web, agenda, rappels, mails non lus, documents de l'utilisateur, état du Mac). Réponds UNIQUEMENT par un tableau JSON : [{\"titre\":\"…\",\"task\":\"consigne précise\"}]. Aucune étape ne doit envoyer, payer ou supprimer."
            guard let r = ameAsk(planPrompt, "Objectif : \(input)\n\n\(ctx)", deep: true, maxTokens: 2000) else { return out(nil) }   // D-R9 : 1 200 tronquait (cf. Conseil MN2-4 : 2 000)
            if let steps = NovaApp.extractJSONArray(r.text) { return ["steps": steps, "brain": r.brain] }
            // D-R9 : un réessai correctif — la sortie brute est renvoyée au modèle, consigne de forme seule.
            Tools.actions.add(["ame_plan_parse_fail": true, "brain": r.brain, "chars": r.text.count, "tail": String(r.text.suffix(300))])
            if let r2 = ameAsk("Tu convertis un plan en tableau JSON STRICTEMENT valide. Réponds UNIQUEMENT par le tableau JSON, sans texte autour, sans virgule finale : [{\"titre\":\"…\",\"task\":\"…\"}].", "Plan à convertir :\n" + r.text, deep: false, maxTokens: 2000),
               let steps = NovaApp.extractJSONArray(r2.text) { return ["steps": steps, "brain": r2.brain] }
            return ["error": "le plan n'a pas pu être lu (cerveau : \(r.brain), \(r.text.count) caractères) — début : " + String(r.text.prefix(160)) + " … fin : " + String(r.text.suffix(160))]
        case "rituel_matin", "rituel_soir":   // 20, 26 : trois tuiles
            let cal = tools.run("calendar", ""), rem = tools.run("reminders", "")
            let laisser = AmeDocParse.lines(ameDoc("laisser")).filter { ($0["on"] as? Bool) != false }.suffix(6).map { "- \($0["text"] as? String ?? "") (\(String(($0["ts"] as? String ?? "").prefix(10))))" }.joined(separator: "\n")
            let morning = kind == "rituel_matin"
            return out(ameAsk("TU ES LE RITUEL \(morning ? "DU MATIN" : "DU SOIR"). Compose EXACTEMENT 3 tuiles courtes en markdown : **À commencer** (\(morning ? "la chose la plus importante de la journée" : "ce qui a avancé aujourd'hui")), **À laisser** (ce qu'on ne reprend pas \(morning ? "aujourd'hui, en t'appuyant sur ce qu'il a lui-même choisi de laisser" : "ce soir : l'autorisation explicite de lâcher")), **À préparer** (\(morning ? "à anticiper" : "pour demain")). Données réelles uniquement." + honest, "AGENDA :\n\(cal)\n\nRAPPELS :\n\(rem)\n\nCE QU'IL A CHOISI DE LAISSER :\n\(laisser.isEmpty ? "(rien)" : laisser)\n\n\(ctx)"))
        default: return ["error": "intelligence inconnue : \(kind)"]
        }
    }

    func ameSearch(_ q: String) -> String {
        var lines: [String] = []; let words = q.lowercased().split(separator: " ").filter { $0.count > 2 }.map(String.init); let iso = ISO8601DateFormatter()
        for c in convs.list().prefix(80) {
            guard let id = c["id"] as? String, let full = convs.get(id), let ms = full["messages"] as? [[String: Any]] else { continue }
            // FIX-REVUE R-7 : les messages role:"event" (Direct matérialisés) sont exclus de la
            // recherche Âme — ce sont des notifications composées par Nova, pas du savoir d'Ahadi.
            for m in ms where (m["role"] as? String) != "event" { let t = (m["content"] as? String) ?? ""; let low = t.lowercased()
                if !words.isEmpty, words.contains(where: { low.contains($0) }) { let d = (m["ts"] as? String).flatMap { iso.date(from: $0) }.map { String(iso.string(from: $0).prefix(10)) } ?? "?"
                    lines.append("[conversation \(d), \((m["role"] as? String) ?? "")] " + String(t.replacingOccurrences(of: "\n", with: " ").prefix(240))) } }
        }
        for m in memory.search(q, limit: 6) { lines.append("[mémoire \(String((m["ts"] as? String ?? "").prefix(10)))] " + (m["text"] as? String ?? "")) }
        for h in Knowledge.shared.search(q, limit: 4) { lines.append("[document \(h["path"] as? String ?? "")] " + String(((h["text"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ").prefix(240))) }
        return lines.prefix(30).joined(separator: "\n")
    }

    // MARK: veille de fond (corps, relations, rêve)
    func bodyNudge(force: Bool = false) {
        let tips = ["Lève-toi une minute, bois un verre d'eau.", "Règle 20-20-20 : regarde au loin pendant 20 secondes.", "Étire la nuque et les épaules, puis marche jusqu'à la fenêtre.", "Respire lentement 5 fois avant de reprendre."]
        let m = AmeBody.streak
        publishDot(id: "corps", name: "Gardien du corps", emoji: "🧘", color: "#10b981", summary: (force ? "Test. " : "") + "Tu es devant l'écran depuis environ \(m) min sans pause de 5 min détectée. " + tips.randomElement()!)
        AmeBody.lastNudge = Date()
    }
    func publishDot(id: String, name: String, emoji: String, color: String, summary: String) {
        guard AmeSilence.allow(plafond: settings.get("dots_plafond", 6)) else { return }
        bus.publish("dot", ["phase": "ready", "dot": id, "name": name, "emoji": emoji, "color": color, "run_id": "ame-\(id)-\(Int(Date().timeIntervalSince1970))", "ok": true, "summary": summary])
    }

    func ameStart() {
        Thread.detachNewThread { [self] in
            var lastDay = ""; var lastRel = ""; var lastDream = ""
            while true {
                Thread.sleep(forTimeInterval: 60)
                // Gardien du corps : une minute d'activité de plus tant que l'inactivité reste < 5 min ; une vraie pause remet le compteur à zéro.
                if let idle = AmeBody.idleSeconds() {
                    AmeBody.idle = idle
                    if idle < 300 { AmeBody.streak += 1 } else { AmeBody.streak = 0 }
                    let th = settings.get("corps_pause_min", 90)
                    if settings.get("corps_on", true), AmeBody.streak >= th, !briefs.inQuietHours(), Date().timeIntervalSince(AmeBody.lastNudge) > Double(th) * 60 { bodyNudge() }
                }
                let now = Date(); let cal = Calendar.current; let day = String(nowISO().prefix(10)); let hh = cal.component(.hour, from: now), mm = cal.component(.minute, from: now)
                // Gardien des relations : une fois par jour dès 9 h, seulement s'il y a quelqu'un à relancer.
                if hh >= 9, lastRel != day, !briefs.inQuietHours() {
                    lastRel = day
                    // V5-P : lecture tolérante (lignes libres conservées et ignorées, dates web en millisecondes lues) — Feat_AmeDocs.swift.
                    let due: [String] = RelationsGardien.dueNames(ameDoc("relations"), now: now)
                    if !due.isEmpty { publishDot(id: "relations", name: "Gardien des relations", emoji: "🤝", color: "#8b5cf6", summary: "Pas de nouvelles depuis un moment : " + due.prefix(5).joined(separator: ", ") + ". Ouvre l'onglet Relations pour un brouillon de message (rien n'est envoyé).") }
                }
                // Rêve : à 23 h 30, distille la journée en propositions (à valider dans Âme › Rêves : Garder / Rejeter).
                // V5-P : même écriture, passée par reveRun (Feat_Reves.swift) qui date la distillation — base du rattrapage au réveil.
                if hh == 23, mm >= 30, lastDream != day, Rituels.allows("reve", settings: settings) {   // interrupteur du rituel (V5-O, Feat_Daily)
                    lastDream = day
                    let rr: [String: Any] = reveRun(origine: "23:30", minGapHours: 12)
                    if (rr["ok"] as? Bool) == true { Rituels.mark("reve") }
                }
                _ = lastDay; lastDay = day
            }
        }
    }
}

extension NovaApp {
    /// Suivi des demandes : plusieurs demandes dans un même fil, aucune oubliée ; « ↩ Répondre » cite un message précis.
    /// BRAIN-B (24/10) : règle de fil réécrite, courte et sans contradiction (plus de repères emoji
    /// imposés, plus de « ne demande jamais »). L'effet de bord est conservé à l'identique :
    /// Tools.frontAllowed suit la demande explicite « devant moi » du message courant.
    static func followPrompt(_ hist: [ChatMsg]) -> String {
        let users = hist.filter { $0.role == "user" && !$0.content.hasPrefix("RÉSUMÉ DE LA CONVERSATION") && !$0.content.hasPrefix("[NOTE MOTEUR") }
        let asks = users.suffix(6)
        var ledger = ""
        if asks.count > 1 {
            var n = users.count - asks.count + 1
            var lines: [String] = []
            for m in asks { lines.append("#\(n) « " + String(m.content.replacingOccurrences(of: "\n", with: " ").prefix(90)) + " »"); n += 1 }
            ledger = "\nDemandes récentes de ce fil (ancienne → récente) :\n" + lines.joined(separator: "\n")
        }
        var thread = ""
        let cur = users.last?.content ?? ""
        // « en back / en arrière-plan / sans ouvrir » l'emporte toujours sur « ouvre / lance / affiche ».
        let backRx = try? NSRegularExpression(pattern: #"arri[eè]re[- ]plan|\ben back\b|\bback\b|background|sans (ouvrir|afficher|m'interrompre|interrompre|bring)|discr[eè]t"#, options: .caseInsensitive)
        var wantsBack = false; if let rb = backRx { wantsBack = Tools.match(rb, cur) }
        Tools.frontAllowed = Tools.match(Tools.askFrontRx, cur) && !wantsBack
        // WP3 (31/10) : plus de « Tools.sendAllowed » ouvert par le verbe « envoie » — un verbe d'envoi DEMANDE l'approbation ;
        // l'approbation, liée à l'action exacte affichée, naît dans SendApprovals.noteUserTurn (route du chat).
        let prior = users.dropLast().reversed().first { $0.content.count > 50 && !$0.content.hasPrefix("↩") }
        if let t = prior {
            thread = "\nDernière tâche de fond de ce fil : « " + String(t.content.replacingOccurrences(of: "\n", with: " ").prefix(260)) + " »"
            if let a = hist.last(where: { $0.role == "assistant" }) { thread += "\nTa dernière réponse se terminait par : « …" + String(a.content.replacingOccurrences(of: "\n", with: " ").suffix(280)) + " »" }
        }
        let terse = cur.count < 90 ? " Le message actuel est court : s'il reprend la tâche ou répond à ta dernière offre ou question (« go », « oui », « envoie-le », « et le deuxième ? »), poursuis-la tout de suite avec ce que le fil donne déjà ; si c'est une demande complète et autonome, traite-la comme un nouveau sujet et clos l'ancien en une ligne s'il reste ouvert." : ""
        // 31/10 (audit prompt) : la partie FIXE de la règle (followRule) part dans le préfixe stable mis en cache (App+RoutesChat) ;
        // ici ne reste que ce qui change d'un tour à l'autre (message court, dernière tâche, demandes récentes). Effets de bord inchangés.
        let dynPart: String = (terse + thread + ledger).trimmingCharacters(in: .whitespacesAndNewlines)
        return dynPart.isEmpty ? "" : "\n\nFIL DE CE TOUR : " + dynPart
    }
    /// 31/10 (audit prompt) : texte fixe de la règle de fil, autrefois répété dans le suffixe dynamique de chaque appel.
    static let followRule: String = "RÈGLE DE FIL — tu gardes le fil : ne redemande jamais un sujet, un destinataire ou un canal que l'historique donne déjà ; en cas d'ambiguïté, prends l'interprétation la plus plausible, dis-la en une ligne et agis (les envois, paiements et suppressions restent soumis à son GO). Si le message contient plusieurs demandes, traite-les toutes ; s'il commence par « ↩ « … » », réponds d'abord à l'élément cité. Une ligne « [Réactions : …] » signale ses réactions : 👍/✅ validé, 👎 à corriger, ❓ à préciser."

    /// Conscience d'environnement (27/10, retour Ahadi) : à chaque tour, le moteur mesure
    /// l'app au premier plan et reçoit l'écran Nova déclaré par l'interface. Avant, le
    /// cerveau ne recevait le nom de l'écran Nova qu'au premier message du panneau latéral
    /// et rien sur l'app externe active : il demandait « où es-tu ? » alors que tout est
    /// mesurable. « Cette page / ici / je suis coincé / prends la main » = cet endroit.
    static func liveContextBlock(ecran: String?) -> String {
        let f: (String, String) = SystemHooks.frontmostProvider?() ?? ("", "")
        var parts: [String] = []
        if !f.0.isEmpty { parts.append("app au premier plan à l'instant : " + f.0 + (f.1.isEmpty ? "" : " (" + f.1 + ")")) }
        let e: String = (ecran ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { parts.append("écran Nova déclaré par l'interface : « " + String(e.prefix(80)) + " »") }
        guard !parts.isEmpty else { return "" }
        return "\n\nCONTEXTE TEMPS RÉEL (mesuré ce tour-ci, ne le redemande jamais) : " + parts.joined(separator: " ; ") + ". "
            + "« cette page », « ici », « je suis coincé », « prends la main », « continue à ma place » désignent CET endroit précis : "
            + "lis-le d'abord — volet web interne de Nova : outil app (page-etat, puis page-lire, page-clic, page-saisir) ou outil formulaire ; "
            + "fenêtre d'une autre app : outil ui (windows, puis screenshot) — ces formulations autorisent elles-mêmes la prise en main — "
            + "puis agis dedans et re-vérifie le résultat. Ne dis jamais que tu ignores où il se trouve sans avoir lu cet écran."
    }
    /// Profondeurs (14) : 0 surface · 1 courant · 2 profond · 3 nuit — change la forme de la réponse, pas l'honnêteté.
    static func depthPrompt(_ d: Int) -> String {
        switch d {
        case 0: return "\nPROFONDEUR : SURFACE — une à deux phrases, la réponse seule."
        case 2: return "\nPROFONDEUR : PROFOND — analyse structurée : faits, hypothèses, risques, recommandation, et ce que tu ne sais pas."
        case 3: return "\nPROFONDEUR : NUIT — mode réflexion lente et chaleureuse : prends du recul, relie à ses valeurs et à ses échéances, pose une question juste ; aucune urgence, aucune liste de tâches."
        default: return ""
        }
    }
}
