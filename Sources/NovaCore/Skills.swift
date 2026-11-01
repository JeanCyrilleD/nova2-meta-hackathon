import Foundation

/// NOVA2-FIX (vague 3 — directive SKILLS d'Ahadi, 20/10/2026 : « donne-lui nos skills ») :
/// les méthodes de la maison deviennent les skills de Nova.
/// Magasin : <données Nova>/skills/<nom>/SKILL.md + index.json (nom, titre, déclencheur, description).
/// Trois surfaces, un seul magasin :
/// - le catalogue (nom + déclencheur de chaque skill) est injecté par Persona.system dans le prompt ;
/// - l'outil « skill » (Tools) charge le SKILL.md complet dans le contexte quand la tâche correspond ;
/// - les routes /api/skills* servent l'écran Savoir › « Ses skills » (liste, lecture, édition).
public enum NovaSkills {
    public struct Entry {
        public let name: String
        public let title: String
        public let trigger: String
        public let summary: String
    }

    public static var dir: URL { Paths.home.appendingPathComponent("skills", isDirectory: true) }
    static var indexURL: URL { dir.appendingPathComponent("index.json") }

    /// Nom de skill sûr : minuscules, chiffres, tirets — jamais de chemin.
    static func safeName(_ raw: String) -> String? {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !n.isEmpty, n.count <= 60, n.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return n
    }

    /// En-tête d'un SKILL.md : bloc entre deux lignes « --- », paires « clé: valeur »
    /// (nom / titre / declencheur / description). Tolérant : absent → dictionnaire vide.
    static func frontMatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let c = line.firstIndex(of: ":") else { continue }
            let k = line[..<c].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = v }
        }
        return out
    }

    static func entry(name: String, text: String) -> Entry {
        let fm = frontMatter(text)
        return Entry(name: name,
                     title: fm["titre"] ?? name,
                     trigger: fm["declencheur"] ?? "",
                     summary: fm["description"] ?? "")
    }

    /// Scan du magasin (source de vérité de secours et de reconstruction d'index).
    static func scan() -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [Entry] = []
        for n in names.sorted() {
            guard let safe = safeName(n), safe == n else { continue }
            let p = dir.appendingPathComponent(n).appendingPathComponent("SKILL.md").path
            if let t = try? String(contentsOfFile: p, encoding: .utf8) { out.append(entry(name: n, text: t)) }
        }
        return out
    }

    /// Index effectif : index.json fait foi ; absent ou illisible → scan des SKILL.md.
    public static func entries() -> [Entry] {
        if let d = try? Data(contentsOf: indexURL),
           let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]], !arr.isEmpty {
            let list = arr.compactMap { o -> Entry? in
                guard let n = o["name"] as? String, let safe = safeName(n) else { return nil }
                return Entry(name: safe,
                             title: (o["title"] as? String) ?? safe,
                             trigger: (o["trigger"] as? String) ?? "",
                             summary: (o["description"] as? String) ?? "")
            }
            if !list.isEmpty { return list }
        }
        return scan()
    }

    static func writeIndex(_ list: [Entry]) {
        let arr: [[String: Any]] = list.map { ["name": $0.name, "title": $0.title, "trigger": $0.trigger, "description": $0.summary, "file": "\($0.name)/SKILL.md", "updated": nowISO()] }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? jsonData(arr).write(to: indexURL, options: .atomic)
    }

    public static func content(_ rawName: String) -> String? {
        guard let n = safeName(rawName) else { return nil }
        let p = dir.appendingPathComponent(n).appendingPathComponent("SKILL.md").path
        return try? String(contentsOfFile: p, encoding: .utf8)
    }

    /// Écriture depuis l'écran Savoir : remplace le SKILL.md puis reconstruit l'index par scan.
    @discardableResult
    public static func save(name rawName: String, content text: String) -> Bool {
        guard let n = safeName(rawName), !text.isEmpty else { return false }
        let d = dir.appendingPathComponent(n, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try text.write(to: d.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        } catch { return false }
        writeIndex(scan())
        return true
    }

    /// Catalogue injecté dans le prompt système (Persona) : une ligne par skill, nom + déclencheur.
    /// BRAIN-B (24/10) : index COMPACT (déclencheur borné à 200 caractères, signalé « … » s'il est
    /// coupé) — le contenu complet arrive soit par l'outil « skill », soit automatiquement quand le
    /// message d'Ahadi correspond à un skill (relevantBlock, suffixe dynamique, budget borné).
    public static func catalog(cap: Int = 6000) -> String {
        let list = entries()
        guard !list.isEmpty else { return "" }
        var s = "TES SKILLS — méthodes de la maison (écran Savoir › « Ses skills »). Quand une tâche correspond à un skill, charge-le avec l'outil « skill » (argument = son nom exact) AVANT d'agir et applique sa méthode jusqu'au bout. Un skill déjà joint plus bas (bloc SKILL JOINT) n'a pas besoin d'être rechargé. Les skills marqués (posture) sont déjà résumés dans tes règles ; charge-les en cas de doute."
        var shown: Int = 0
        for e in list {
            var t: String = e.trigger.isEmpty ? e.summary : e.trigger
            t = t.replacingOccurrences(of: "\n", with: " ")
            if t.count > 160 { t = String(t.prefix(160)) + "…" }
            let tag: String = postureNames.contains(e.name) ? " (posture)" : ""
            let line: String = "\n- \(e.name)\(tag) — \(t)"
            if s.count + line.count > cap { break }
            s += line; shown += 1
        }
        if shown < list.count { s += "\n(+\(list.count - shown) autre(s) skill(s) : liste complète avec l'outil « skill » et l'argument « liste ».)" }
        return s
    }

    /// BRAIN-B (24/10) : skills dont le déclencheur correspond au message d'Ahadi — leur contenu
    /// complet est joint au suffixe dynamique du tour, pour que les skills installés servent
    /// vraiment sans dépendre de l'initiative du cerveau.
    /// 31/10 (compétences) : sélection resserrée. Avant : un skill entrait dès 2 mots communs
    /// (≥ 5 lettres), 2 skills, budget 9 000 car. (jusqu'à ~8 200 car. relevés par message).
    /// Maintenant : score PONDÉRÉ (nom 3 > titre 2,5 > déclencheur 2 > description 1, multiplié
    /// par la rareté du mot dans le magasin), mots vides FR/EN ignorés, tri décroissant,
    /// au plus « competences_max » skills (défaut 3) dans « competences_budget_car » (défaut 4 000).
    /// Un skill nommé/invoqué explicitement par Ahadi passe toujours en premier, même au-delà
    /// du budget ; les autres se partagent ce qui reste, tronqués proprement.
    public static func relevantBlock(for message: String, budget: Int? = nil) -> String {
        let maxCount: Int = min(max(intSetting("competences_max", 3), 1), 6)
        let total: Int = min(max(budget ?? intSetting("competences_budget_car", 4000), 1000), 20_000)
        let ranked: [Ranked] = rank(message: message, among: entries())
        if ranked.isEmpty { return "" }
        return assemble(ranked, maxCount: maxCount, budget: total, content: { (n: String) -> String? in content(n) })
    }

    /// 31/10 (compétences) : un skill candidat, son score et s'il a été nommé explicitement.
    struct Ranked {
        let entry: Entry
        let score: Double
        let explicit: Bool
    }

    /// 31/10 (compétences) : seuil minimal (hors skill explicite) et coupure relative au meilleur.
    static let minScore: Double = 3.0
    static let relativeCut: Double = 0.4
    static let invocationCues: Set<String> = ["skill", "skills", "competence", "competences", "methode", "methodes"]

    /// 31/10 (compétences) : réglage entier tolérant (nombre JSON ou texte « 3 »).
    static func intSetting(_ key: String, _ def: Int) -> Int {
        let st = Settings()
        let n: Int = st.get(key, Int.min)
        if n != Int.min { return n }
        let d: Double = st.get(key, Double.nan)
        if !d.isNaN { return Int(d) }
        let s: String = st.get(key, "")
        return Int(s.trimmingCharacters(in: .whitespaces)) ?? def
    }

    /// 31/10 (compétences) : classement pur (sans disque) — testable.
    /// Explicite = nom composé cité (« analyse-brvm » ou « analyse brvm »), titre complet cité,
    /// ou nom d'un seul mot cité avec un mot d'invocation (« skill », « compétence », « méthode »).
    static func rank(message: String, among list: [Entry]) -> [Ranked] {
        let msg: String = fold(message)
        if msg.count < 4 { return [] }
        let mw: Set<String> = words(msg)
        let toks: Set<String> = Set(msg.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        let cued: Bool = !toks.intersection(invocationCues).isEmpty
        let pool: [Entry] = list.filter { !postureNames.contains($0.name) }
        if pool.isEmpty { return [] }
        // Poids par champ : un mot garde le poids du champ le plus fort où il apparaît.
        var fields: [(Entry, [String: Double])] = []
        for e in pool {
            var w: [String: Double] = [:]
            let parts: [(String, Double)] = [(e.summary, 1.0), (e.trigger, 2.0), (e.title, 2.5), (e.name, 3.0)]
            for (txt, wt) in parts {
                for t in words(fold(txt)) { w[t] = max(w[t] ?? 0, wt) }
            }
            fields.append((e, w))
        }
        // Rareté : un mot présent dans peu de skills pèse plus (idf = ln(1 + N / df)).
        var df: [String: Int] = [:]
        for (_, w) in fields { for t in w.keys { df[t, default: 0] += 1 } }
        let n: Double = Double(pool.count)
        var out: [Ranked] = []
        for (e, w) in fields {
            let fname: String = fold(e.name)
            let spaced: String = fname.replacingOccurrences(of: "-", with: " ")
            let title: String = fold(e.title)
            var explicit: Bool = false
            if fname.contains("-") {
                explicit = msg.contains(fname) || (spaced.count >= 6 && msg.contains(spaced))
            } else if fname.count >= 4 && toks.contains(fname) && cued {
                explicit = true
            }
            if !explicit && title.count >= 8 && title != fname && msg.contains(title) { explicit = true }
            var sc: Double = 0
            var hits: Int = 0
            for t in mw {
                guard let wt = w[t] else { continue }
                sc += wt * log(1.0 + n / Double(max(df[t] ?? 1, 1)))
                hits += 1
            }
            if explicit || (hits >= 2 && sc >= minScore) { out.append(Ranked(entry: e, score: sc, explicit: explicit)) }
        }
        out.sort { (a: Ranked, b: Ranked) -> Bool in
            if a.explicit != b.explicit { return a.explicit }
            if a.score != b.score { return a.score > b.score }
            return a.entry.name < b.entry.name
        }
        let best: Double = out.first(where: { !$0.explicit })?.score ?? 0
        return out.filter { $0.explicit || $0.score >= best * relativeCut }
    }

    /// 31/10 (compétences) : assemblage pur sous budget. Le skill explicite en tête reçoit
    /// au moins 6 000 car. même si le budget est plus petit ; les suivants se partagent le reste
    /// (chacun garde au moins sa part égale, ou laisse 700 car. par skill encore à placer ; ce qu'un
    /// skill court n'utilise pas passe aux suivants), et un corps < 400 car. n'est pas joint.
    static func assemble(_ ranked: [Ranked], maxCount: Int, budget: Int, content: (String) -> String?) -> String {
        let picked: [Ranked] = Array(ranked.prefix(max(1, maxCount)))
        var out: String = ""
        var left: Int = budget
        for (i, r) in picked.enumerated() {
            guard let c = content(r.entry.name), !c.isEmpty else { continue }
            let sep: String = out.isEmpty ? "" : "\n\n"
            let header: String = "SKILL JOINT « \(r.entry.name) » (" + (r.explicit ? "nommé par Ahadi" : "le message d'Ahadi correspond à son déclencheur") + " — applique sa méthode) :\n"
            let cap: Int
            if r.explicit && out.isEmpty {
                cap = max(left, 6000) - header.count
            } else {
                let after: Int = picked.count - i - 1
                let share: Int = max(left / (after + 1), left - after * 700)
                cap = share - sep.count - header.count
            }
            if cap < 400 { continue }
            let block: String = sep + header + clip(c, cap: cap, name: r.entry.name)
            out += block
            left -= block.count
        }
        return out
    }

    /// 31/10 (compétences) : troncature propre — garde le début (en-tête du SKILL.md compris),
    /// coupe à une fin de ligne si possible, et signale la suite récupérable par l'outil « skill ».
    static func clip(_ text: String, cap: Int, name: String) -> String {
        if text.count <= cap { return text }
        let marker: String = "\n[… (suite disponible sur demande) : outil « skill » avec l'argument « \(name) » …]"
        let keep: Int = max(cap - marker.count, 0)
        var head: Substring = text.prefix(keep)
        if let nl = head.lastIndex(of: "\n"), head.distance(from: head.startIndex, to: nl) >= keep * 6 / 10 {
            head = head[..<nl]
        }
        return String(head) + marker
    }

    static func fold(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
    }
    /// 31/10 (compétences) : mots vides FR/EN élargis (formes sans accents, ≥ 4 lettres), mots
    /// d'invocation compris — ils ne doivent pas faire correspondre un skill à eux seuls.
    static let stopWords: Set<String> = ["avant", "apres", "quand", "toute", "toutes", "chaque", "cette", "votre", "notre", "faire", "comme", "aussi", "alors", "encore", "depuis", "entre", "leurs", "elles", "skill", "nova", "ahadi", "demande", "message", "messages",
        "skills", "competence", "competences", "methode", "methodes",
        "pour", "dans", "avec", "sans", "mais", "tout", "tous", "plus", "moins", "bien", "fait", "faits", "elle", "nous", "vous", "sont", "etre", "avoir", "avez", "avons", "cela", "ceci", "celui", "celle", "ceux", "quoi", "quel", "quelle", "quels", "quelles", "comment", "pourquoi", "donc", "puis", "tres", "trop", "peux", "peut", "veux", "veut", "faut", "fais", "dois", "doit", "merci", "bonjour", "salut", "juste", "maintenant", "aujourd", "leur", "chose", "choses", "quelque", "autre", "autres", "meme", "sous", "vers", "chez", "voici", "voila", "ainsi", "deja", "vraiment", "besoin", "donne", "dire", "avais", "avait", "etait", "suis", "sera", "serait", "ton", "tes", "mes", "moi", "toi", "lui", "aux", "ici", "oui", "non", "stp", "svp",
        "this", "that", "with", "from", "have", "what", "your", "will", "when", "then", "them", "they", "just", "like", "want", "need", "please", "about", "there", "their", "which", "would", "could", "should", "into", "been", "were", "also", "some", "more", "make", "help", "here", "only", "very", "than", "does", "doing"]
    static func words(_ s: String) -> Set<String> {
        var out = Set<String>()
        for w in s.components(separatedBy: CharacterSet.alphanumerics.inverted) where w.count >= 4 && !stopWords.contains(w) { out.insert(w) }
        return out
    }

    /// BRAIN-B (24/10) : postureBlock n'est plus injecté par Persona.system (24 k caractères à
    /// chaque étape) — l'essentiel de ces quatre skills est condensé dans NovaSoul (règles dures,
    /// posture solution, continuité) ; le contenu complet reste chargeable par l'outil « skill ».
    /// Historique — DIAG2-AME : skills de POSTURE en chargement permanent. Leur contenu intégral entre
    /// dans le préfixe stable de Persona.system (chaque run, chaque surface), parce que le
    /// chargement volontaire par l'outil « skill » ne les atteint jamais — preuve BlackBox
    /// du 21/10 : 7 appels « skill » dans tout l'historique, 0 pour ces quatre-là.
    /// Ensemble minimal de conduite : prouver (preuve-avant-annonce), ne jamais refuser
    /// sec (zero-echec), verrouiller les sorties (validation-sorties), écrire la mémoire
    /// (gestion-memoire). Lu depuis le magasin vivant à chaque construction de prompt :
    /// un amendement d'Ahadi au magasin prend effet au run suivant. Plafond global nommé ;
    /// au-delà, la troncature est SIGNALÉE dans le bloc, jamais silencieuse.
    public static let postureNames: [String] = ["preuve-avant-annonce", "zero-echec", "validation-sorties", "gestion-memoire"]

    public static func postureBlock() -> String {
        var parts: [String] = []
        for n in postureNames {
            if let c = content(n) { parts.append("—— SKILL DE POSTURE « \(n) » (chargement permanent) ——\n" + c) }
        }
        guard !parts.isEmpty else { return "" }
        var s = "SKILLS DE POSTURE — méthodes de conduite chargées EN PERMANENCE : elles s'appliquent à chaque run, sans que tu aies à les appeler :\n" + parts.joined(separator: "\n")
        let cap = 24_000
        if s.count > cap { s = String(s.prefix(cap)) + "\n[… bloc posture tronqué à \(cap) caractères : le magasin a grossi, relever le plafond dans Skills.swift (postureBlock) …]" }
        return s
    }

    /// Outil « skill » : « liste » (ou vide) → catalogue ; un nom → le SKILL.md complet.
    public static func tool(_ arg: String) -> String {
        let a = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty || a.lowercased() == "liste" || a.lowercased() == "list" {
            let c = catalog(cap: 200_000)
            return c.isEmpty ? "Aucun skill installé pour le moment (magasin vide : écran Savoir › « Ses skills »)." : c + "\nCharge le contenu complet d'un skill : appelle l'outil « skill » avec son nom exact."
        }
        guard let n = safeName(a) else { return "Nom de skill invalide : « \(a) ». Demande la liste avec l'argument « liste »." }
        guard let c = content(n) else {
            let names = entries().map { $0.name }.joined(separator: ", ")
            return "Skill inconnu : « \(n) ». Skills installés : \(names.isEmpty ? "aucun" : names)."
        }
        let cap = 32_000
        return "SKILL « \(n) » — applique cette méthode :\n\n" + (c.count > cap ? String(c.prefix(cap)) + "\n[… skill tronqué à \(cap) caractères …]" : c)
    }
}
