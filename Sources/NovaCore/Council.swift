import Foundation

/// NOVA OMEGA (Phase 6) — Conseil parallèle : les membres délibèrent en même temps (DispatchGroup, au plus `maxParallel`),
/// chacun diffuse ses jetons au fil de l'eau ; la synthèse du président reste séquentielle, après les membres.
/// Les appels réseau restent ceux de BrainRunner.stream (bloquants, avec leurs délais habituels) : ils tournent sur des threads
/// GCD, jamais sur le pool coopératif de Swift Concurrency, qui n'est donc pas bloqué.
/// V3 CONSEIL (24/10) — délibération en 3 temps : (a) avis indépendants structurés (position, 3 arguments, confiance,
/// ce qui ferait changer d'avis) ; (b) tour de RÉFUTATION court (chaque membre lit les autres et attaque le point le plus
/// faible ou révise) ; (c) le président rend recommandation BLUF, carte des désaccords, vote motivé par membre, risques,
/// ce qu'il faudrait savoir pour trancher autrement, puis « Décidé » (appliqué sous les gardes inchangées).
public enum Council {
    /// Plafond de requêtes simultanées (le Mac est lent) : au-delà, les membres attendent qu'une place se libère.
    public static let maxParallel = 4
    /// V3 : composition automatique limitée à 3 membres (coût) ; 4 au plus si Ahadi les choisit lui-même.
    public static let defaultMembers: Int = 3

    /// Rôles par place (ordre d'arrivée). Ils s'ajoutent à la fin du système : le préfixe mis en cache reste identique.
    public static let roles: [(label: String, prompt: String)] = [
        ("Analyste", "Analyste rigoureux : faits, données chiffrées, risques mesurables."),
        ("Stratège", "Stratège : vision long terme, leviers d'action concrets."),
        ("Avocat du diable", "Avocat du diable : angles morts, failles logiques, contre-arguments."),
        ("Créatif", "Architecte créatif : solutions hors cadre, idées de rupture."),
    ]
    public static func roleLabel(_ i: Int) -> String { i >= 0 && i < roles.count ? roles[i].label : "Membre \(i + 1)" }
    /// Vérité (24/10) : si le cerveau prévu a été relayé par un autre (repli du routeur), le président le sait —
    /// « [tiers] (relayé par [tiers]) » au lieu d'attribuer l'avis au mauvais cerveau.
    public static func whoAnswered(_ planned: String, _ actual: String) -> String {
        let a: String = actual.trimmingCharacters(in: .whitespaces)
        if a.isEmpty || a == planned || planned.lowercased().contains(a.lowercased()) || a.lowercased().contains(planned.lowercased()) { return planned }
        return "\(planned) (relayé par \(a))"
    }

    /// V3 : le président est [tiers] quand il est joignable ; les membres secondaires sont d'abord [tiers] puis [tiers] (moins chers).
    public static let chairPreferred: [String] = ["wonder-1.0"]   // MUSE-PARTOUT (26/10, ordre d'Ahadi) : le président du Conseil est Muse Wonder
    public static let secondaryPreferred: [String] = ["spark-1.3", "spark-1.2"]   // CONFIDENTIALITE (mission 26/10 regle 7) : le Conseil lit du contenu personnel — Standard uniquement

    /// Indices de famille (fournisseur réel du modèle), cherchés dans « modèle + URL » en minuscules — l'ordre compte.
    static let familyHints: [(String, String)] = [
        ("meta.ai", "meta"), ("meta-llama", "meta"), ("meta-models", "meta"), ("muse-spark", "meta"), ("muse-wonder", "meta"),
    ]

    /// Famille d'un cerveau : deux membres d'une même famille ne siègent pas ensemble en composition automatique.
    public static func family(_ b: BrainSpec) -> String {
        let hay: String = (b.model + " " + b.baseURL).lowercased()
        for (needle, fam) in familyHints where hay.contains(needle) { return fam }
        if b.model.contains("/") { return b.model.split(separator: "/").first.map(String.init) ?? b.id }
        return b.id
    }

    static func usable(_ router: Router, _ b: BrainSpec) -> Bool {
        if router.disabled.contains(b.id) || router.isDead(b.id) || b.kind == .local { return false }
        // 24/10 : un cerveau servi par un démon local ([tiers]…) n'est pas pris d'office : « Connexion au serveur impossible »
        // dès que le démon dort — il siège seulement si Ahadi le choisit.
        let u: String = b.baseURL.lowercased()
        if u.contains("localhost") || u.contains("127.0.0.1") || u.contains(":11434") { return false }
        return b.keys.resolve(router.runner.keys) != nil
    }

    /// Choisit les membres : ceux demandés (4 au plus), sinon jusqu'à 3 cerveaux joignables de familles différentes,
    /// [tiers] et [tiers] d'abord, le cerveau du président ([tiers]) en dernier recours seulement.
    public static func pick(router: Router, wanted: [String]) -> [BrainSpec] {
        if !wanted.isEmpty {
            return Array(wanted.compactMap { id in router.brains.first { $0.id == id } }.prefix(maxParallel))
        }
        var ordered: [BrainSpec] = []
        for id in secondaryPreferred {
            if let b = router.brains.first(where: { $0.id == id }) { ordered.append(b) }
        }
        for b in router.brains where !secondaryPreferred.contains(b.id) && !chairPreferred.contains(b.id) { ordered.append(b) }
        for id in chairPreferred {
            if let b = router.brains.first(where: { $0.id == id }) { ordered.append(b) }
        }
        var seen = Set<String>()
        var out: [BrainSpec] = []
        for b in ordered where usable(router, b) {
            if seen.insert(family(b)).inserted { out.append(b) }
            if out.count >= defaultMembers { break }
        }
        // 24/10 : jamais un conseil à une seule voix — si les familles distinctes manquent ([tiers]/[tiers] injoignables),
        // un second cerveau joignable siège quand même (ex. [tiers] + [tiers]), plutôt qu'un avis solitaire sans réfutation.
        if out.count < 2 {
            for b in ordered where usable(router, b) && !out.contains(where: { $0.id == b.id }) {
                out.append(b)
                if out.count >= 2 { break }
            }
        }
        return out
    }

    /// Cerveau préféré du président ([tiers] si joignable) ; nil = routage automatique habituel.
    public static func chairBrain(router: Router) -> String? {
        for id in chairPreferred {
            if let b = router.brains.first(where: { $0.id == id }), usable(router, b) { return b.id }
        }
        return nil
    }
}

// MARK: - LOT G : conseil conscient de lui-même, outillé en lecture, mémorisé, relançable ; le président applique ses décisions.

extension Council {
    /// Outils de LECTURE ouverts aux membres (l'acteur « Dot … » restreint en plus `app` à la lecture et interdit le pilotage d'écran).
    public static let readTools: Set<String> = ["recall", "know", "read_file", "mail_unread", "mail_week", "calendar", "reminders", "app", "web_search", "web_fetch", "today", "notes", "brvm_cours"]
    public static let memberSteps: Int = 4
    public static let chairSteps: Int = 10
    public static let memberDeadline: TimeInterval = 150
    public static let execDeadline: TimeInterval = 300
    /// V3 : plafonds de jetons de sortie par appel et durées max par temps de la délibération.
    public static let memberMaxTokens: Int = 2000      // MN2-4 (R-224) : 900 tronquait raisonnement + avis — inchangé
    public static let rebuttalMaxTokens: Int = 1500   // 24/10 : 600 — [tiers] épuisait le plafond en réflexion (« raisonnement sans texte »)
    public static let chairMaxTokens: Int = 2400
    public static let rebuttalDeadline: TimeInterval = 75
    public static let chairDeadline: TimeInterval = 150

    /// Plafonds annoncés à l'écran (événement members) et archivés avec chaque tour.
    static func limits() -> [String: Any] {
        let l: [String: Any] = [
            "member_tokens": memberMaxTokens, "rebuttal_tokens": rebuttalMaxTokens, "chair_tokens": chairMaxTokens,
            "member_s": Int(memberDeadline), "rebuttal_s": Int(rebuttalDeadline), "chair_s": Int(chairDeadline), "exec_s": Int(execDeadline),
        ]
        return l
    }

    /// Composition du conseil, lue par chaque membre et par le président.
    static func roster(_ specs: [BrainSpec]) -> String {
        var lines: [String] = []
        for (i, sp) in specs.enumerated() {
            let role: String = i < roles.count ? roles[i].prompt : "Membre du conseil."
            lines.append("\(i + 1). \(sp.label) — \(roleLabel(i)) : \(role)")
        }
        return lines.joined(separator: "\n")
    }

    static let sparringNote: String = "\nMODE SPARRING : Ahadi te demande d'ATTAQUER sa position, pas de la conseiller. Ta « Position » est ta critique principale de sa position ; tes arguments sont ses failles, du plus grave au moins grave."

    static func memberExtra(index: Int, specs: [BrainSpec], sparring: Bool = false) -> String {
        let me: String = index < specs.count ? specs[index].label : "membre"
        let toolList: String = readTools.sorted().joined(separator: ", ")
        var s: String = "\n\nTU SIÈGES AU CONSEIL DES IA DE NOVA. Membres du conseil :\n" + roster(specs)
        s += "\nTu es le membre n° \(index + 1) (\(me)), rôle « \(roleLabel(index)) ». TEMPS 1 — AVIS INDÉPENDANT : les autres membres reçoivent la même question en parallèle ; tu ne vois pas leurs avis (ceux des tours précédents figurent dans le fil s'il y en a : réponds-leur nommément). Un tour de réfutation suivra, puis le président (Nova) tranchera et appliquera lui-même les décisions dans Nova."
        s += "\nAVANT DE DONNER TON AVIS, consulte Nova si c'est utile, avec au plus 3 outils de LECTURE parmi : " + toolList + ". Pour l'outil app : seulement « status », « dots », « runs » ou « memoire » (lecture). Aucun autre outil, aucune écriture, aucun envoi."
        if sparring { s += sparringNote }
        s += "\nPuis rends ton avis, 170 mots au plus, sans préambule, avec EXACTEMENT ces titres :\n## Position\nune phrase nette.\n## Arguments\n1. …\n2. …\n3. … (trois arguments, faits avec leur source : outil ou site ; n'invente aucun chiffre)\n## Confiance\nNN/100\n## Ce qui me ferait changer d'avis\nune ou deux conditions vérifiables."
        return s
    }

    /// TEMPS 2 — réfutation : court, sans outil, chaque membre lit les autres avis.
    static func rebuttalSystem(index: Int, specs: [BrainSpec], sparring: Bool = false) -> String {
        let me: String = index < specs.count ? specs[index].label : "membre"
        var s: String = "Tu es \(me), membre n° \(index + 1) du Conseil des IA de Nova (rôle « \(roleLabel(index)) »). Membres :\n" + roster(specs)
        s += "\nTEMPS 2 — TOUR DE RÉFUTATION. Tu as donné ton avis ; tu lis maintenant ceux des autres membres. Attaque le point le plus faible d'UN autre membre, nommé (une faille précise : fait non sourcé, raisonnement circulaire, risque oublié), ou reconnais qu'un argument adverse t'oblige à réviser ta position."
        if sparring { s += " Mode sparring : la cible reste la position d'Ahadi ; attaque aussi les critiques trop complaisantes envers elle." }
        s += " Réponds en français, 110 mots au plus, sans préambule, avec EXACTEMENT ces titres :\n## Réfutation\nle membre visé et la faille.\n## Position finale\n« maintenue » ou « révisée », puis ta position en une phrase.\n## Confiance\nNN/100\nN'invente aucun fait."
        return s
    }

    static func chairSystemFull(name: String, count: Int, roster: String, act: Bool, sparring: Bool = false) -> String {
        var s: String = "Tu es Nova, PRÉSIDENT du Conseil des IA de \(name). Membres :\n" + roster + "\nTu reçois leurs \(count) avis indépendants, puis le tour de réfutation (et le fil des tours précédents s'il existe)."
        if sparring { s += " Séance en MODE SPARRING : la recommandation dit si la position d'Ahadi tient après les attaques, et ce qu'il doit corriger." }
        s += " Rends, en français, avec EXACTEMENT ces titres et dans cet ordre :"
        s += "\n## Recommandation\n2 phrases au plus : la réponse recommandée, nette (BLUF)."
        s += "\n## Désaccords\nune ligne par désaccord de fond : « - **Sujet** : Membre A (sa position) ↔ Membre B (sa position) — pourquoi ils divergent ». S'il n'y en a aucun, écris « Aucun désaccord de fond. »"
        s += "\n## Vote\nune ligne par membre, avec son nom EXACT tel qu'il figure dans la liste des membres : « - Nom : POUR | CONTRE | ABSTENTION — motif tiré de sa position finale ». Le vote porte sur ta recommandation ; ABSTENTION si le membre n'a pas répondu ou si sa position ne permet pas de trancher."
        s += "\n## Risques\n2 à 4 puces."
        s += "\n## Pour trancher autrement\nce qu'il faudrait savoir ou vérifier pour changer la recommandation."
        s += "\n## Décidé\nla liste numérotée des décisions concrètes, une par ligne, formulées comme des actions."
        if act { s += " Ces décisions seront appliquées juste après par toi avec les outils de Nova : marque [GO] celles qui impliquent un envoi, un paiement ou une suppression (elles attendront l'accord d'Ahadi)." }
        s += " N'invente rien qui ne figure ni dans les avis ni dans ta connaissance sûre."
        return s
    }

    static let execRules: String = "\n\nMANDAT DU PRÉSIDENT DU CONSEIL — EXÉCUTION EN ARRIÈRE-PLAN. Applique maintenant toi-même, avec tes outils, les décisions de la rubrique « Décidé » qui sont à ta portée (réglages et Dots via app, rappels, notes, brouillons, fichiers…), sans mettre d'application au premier plan et sans piloter l'écran. RÈGLES INCHANGÉES : jamais d'envoi de mail ou de message, jamais de paiement ni d'ordre, aucune suppression sans GO explicite d'Ahadi : pour ces actions, prépare (brouillon) et classe-les « en attente ». LECTURES : pour lire l'agenda, les rappels, les mails ou les notes, utilise UNIQUEMENT les outils dédiés (calendar, reminders, mail_unread, mail_week, notes, recall) — jamais shell, sqlite ni AppleScript pour une simple lecture : chaque appel shell/AppleScript bloque sur une carte d'approbation d'Ahadi. Réserve shell/AppleScript à une écriture décidée qu'aucun outil dédié ne couvre. Si un outil dédié ne donne pas un détail (durée exacte d'un événement…), dis-le dans « Non fait » plutôt que de contourner. Si une décision ne demande aucune action dans Nova, dis-le. Termine OBLIGATOIREMENT par ce compte rendu, titres exacts :\n## Appliqué\n- action faite (outil utilisé, résultat vérifié)\n## En attente de ton GO\n- action préparée, ce qu'il faut valider\n## Non fait\n- action et raison"
}

// MARK: - V3 : lecture des textes structurés (position, confiance, cible de réfutation, vote) — jamais de valeur inventée : absent = absent.

public enum CouncilParse {
    static func fold(_ s: String) -> String { s.lowercased().folding(options: .diacriticInsensitive, locale: nil) }

    /// Première ligne utile d'un texte (puces, titres et gras retirés).
    static func firstLine(_ s: String, max: Int = 280) -> String {
        for raw in s.components(separatedBy: "\n") {
            var t: String = raw.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            while let c = t.first, "-*•>#".contains(c) { t.removeFirst(); t = t.trimmingCharacters(in: .whitespaces) }
            if !t.isEmpty { return String(t.prefix(max)) }
        }
        return ""
    }

    public static func position(_ text: String) -> String {
        let p: String = firstLine(CouncilStore.section(text, "position"))
        if !p.isEmpty { return p }
        // 24/10 : avis sans rubrique « Position » → première phrase utile (jamais « position non formulée » quand il y a un avis).
        for raw in text.components(separatedBy: "\n") {
            let t: String = raw.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " -*•>#\t"))
            if t.count >= 12 && !t.hasSuffix(":") { return String(t.prefix(240)) }
        }
        return ""
    }

    /// Confiance 0…100 lue dans la rubrique « Confiance » (ou la ligne qui la nomme) : « 70/100 », « 70 % », « 7/10 ». nil si absente.
    public static func confidence(_ text: String) -> Int? {
        let lines: [String] = text.components(separatedBy: "\n")
        let line: String = lines.first { fold($0).contains("confiance") } ?? ""
        let candidates: [String] = [CouncilStore.section(text, "confiance"), line]
        guard let re = try? NSRegularExpression(pattern: "(\\d{1,3})\\s*(/\\s*100|%|/\\s*10)?", options: []) else { return nil }
        for src in candidates where !src.isEmpty {
            let ns: NSString = src as NSString
            guard let m = re.firstMatch(in: src, options: [], range: NSRange(location: 0, length: ns.length)) else { continue }
            let num: Int = Int(ns.substring(with: m.range(at: 1))) ?? -1
            var unit: String = ""
            let r2: NSRange = m.range(at: 2)
            if r2.location != NSNotFound { unit = ns.substring(with: r2).replacingOccurrences(of: " ", with: "") }
            let v: Int = unit == "/10" ? num * 10 : num
            if v >= 0 && v <= 100 { return v }
        }
        return nil
    }

    static func shortName(_ label: String) -> String {
        var s: String = label
        if let r = s.range(of: " (") { s = String(s[..<r.lowerBound]) }
        if let r = s.range(of: " · ") { s = String(s[..<r.lowerBound]) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Fragments qui désignent un membre dans un texte (nom court, mots distinctifs du nom, rôle).
    static func needles(_ m: [String: Any]) -> [String] {
        let label: String = (m["label"] as? String) ?? ""
        let role: String = (m["role"] as? String) ?? ""
        var out: [String] = []
        let sn: String = fold(shortName(label))
        if !sn.isEmpty { out.append(sn) }
        let generic: Set<String> = ["claude", "direct", "cloud", "model", "membre", "local"]
        for t in sn.split(separator: " ") {
            let w: String = String(t)
            if w.count >= 4 && !generic.contains(w) && !w.contains(".") { out.append(w) }
        }
        if !role.isEmpty { out.append(fold(role)) }
        return out
    }

    /// Indice du membre nommé le plus tôt dans `low` (texte déjà replié), `exclude` = id à ignorer.
    static func matchMember(_ low: String, members: [[String: Any]], exclude: String) -> Int? {
        var bestPos: Int = Int.max
        var best: Int? = nil
        for (i, m) in members.enumerated() {
            if !exclude.isEmpty, (m["id"] as? String) == exclude { continue }
            for n in needles(m) {
                if let r = low.range(of: n) {
                    let p: Int = low.distance(from: low.startIndex, to: r.lowerBound)
                    if p < bestPos { bestPos = p; best = i }
                }
            }
        }
        return best
    }

    static func earliest(_ s: String, _ tokens: [(String, String)]) -> (vote: String, end: String.Index)? {
        var bestPos: Int = Int.max
        var best: (vote: String, end: String.Index)? = nil
        for (tok, v) in tokens {
            if let r = s.range(of: tok) {
                let p: Int = s.distance(from: s.startIndex, to: r.lowerBound)
                if p < bestPos { bestPos = p; best = (vote: v, end: r.upperBound) }
            }
        }
        return best
    }

    /// Vote d'une ligne « - Nom : POUR — motif » → ("pour" | "contre" | "abstention" | "", motif).
    static func voteOf(_ line: String) -> (vote: String, why: String) {
        let upper: [(String, String)] = [("ABSTENTION", "abstention"), ("CONTRE", "contre"), ("POUR", "pour")]
        var vote: String = ""
        var tail: String = ""
        if let b = earliest(line, upper) {
            vote = b.vote
            tail = String(line[b.end...])
        } else {
            let low: String = fold(line)
            let after: String = low.range(of: ":").map { String(low[$0.upperBound...]) } ?? low
            let lower: [(String, String)] = [("abst", "abstention"), ("contre", "contre"), ("pour", "pour")]
            if let b = earliest(after, lower) { vote = b.vote }
            if let r = line.range(of: "—") ?? line.range(of: "–") { tail = String(line[r.upperBound...]) }
        }
        let why: String = tail.trimmingCharacters(in: CharacterSet(charactersIn: " :—–-,.*"))
        return (vote: vote, why: String(why.prefix(300)))
    }

    /// Vote motivé par membre, lu dans la rubrique « Vote » du président. Membre absent de la rubrique = vote "" (non attribué).
    public static func votes(_ decision: String, members: [[String: Any]]) -> [[String: Any]] {
        let sec: String = CouncilStore.section(decision, "vote")
        var found: [String: (vote: String, why: String)] = [:]
        for raw in sec.components(separatedBy: "\n") {
            let line: String = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let mi = matchMember(fold(line), members: members, exclude: "") else { continue }
            let mid: String = (members[mi]["id"] as? String) ?? ""
            if found[mid] != nil { continue }
            let v = voteOf(line)
            if v.vote.isEmpty { continue }
            found[mid] = v
        }
        var out: [[String: Any]] = []
        for m in members {
            let id: String = (m["id"] as? String) ?? ""
            var row: [String: Any] = ["id": id, "label": (m["label"] as? String) ?? id, "role": (m["role"] as? String) ?? ""]
            if let f = found[id] { row["vote"] = f.vote; row["why"] = f.why } else { row["vote"] = ""; row["why"] = "" }
            out.append(row)
        }
        return out
    }

    /// Champs lus dans une réfutation : cible (membre visé), position finale (maintenue/révisée), confiance.
    public static func rebuttal(_ text: String, selfID: String, members: [[String: Any]]) -> [String: Any] {
        var d: [String: Any] = [:]
        let refut: String = CouncilStore.section(text, "refut")
        if let ti = matchMember(fold(refut.isEmpty ? text : refut), members: members, exclude: selfID) {
            d["target"] = (members[ti]["id"] as? String) ?? ""
            d["target_label"] = (members[ti]["label"] as? String) ?? ""
        }
        let pos: String = CouncilStore.section(text, "position")
        let low: String = fold(pos)
        if low.contains("revis") { d["stance"] = "révisée" } else if low.contains("maintenu") { d["stance"] = "maintenue" }
        d["position"] = firstLine(pos)
        if let c = confidence(text) { d["confidence"] = c }
        return d
    }
}

/// Collecteur verrouillé des membres (ils tournent sur des threads parallèles).
final class CouncilMemberBox: @unchecked Sendable {
    let lock = NSLock()
    var texts: [String: String] = [:]
    var tools: [String: [String]] = [:]
    var fin: [String: (ok: Bool, error: String, brain: String)] = [:]
    var usage: [String: [Int]] = [:]
    func add(_ id: String, _ t: String) { lock.lock(); texts[id, default: ""] += t; lock.unlock() }
    /// Un outil vient d'être appelé : le texte d'annonce qui le précédait est jeté (l'avis final vient après).
    func reset(_ id: String, tool: String) { lock.lock(); texts[id] = ""; tools[id, default: []].append(tool); lock.unlock() }
    /// Frontière de génération SANS outil (relance interne d'Agent.run, VÉRITÉ-5) : le brouillon remplacé est jeté, sans enregistrer de faux outil dans la liste du tour (différence avec reset, qui consigne l'outil séparateur).
    func clear(_ id: String) { lock.lock(); texts[id] = ""; lock.unlock() }
    func text(_ id: String) -> String { lock.lock(); defer { lock.unlock() }; return texts[id] ?? "" }
    func finish(_ id: String, ok: Bool, error: String, brain: String) { lock.lock(); fin[id] = (ok: ok, error: error, brain: brain); lock.unlock() }
    /// V3 : jetons réels (événements usage du routeur), [entrée, sortie] par membre — information de coût, jamais estimée.
    func addUsage(_ id: String, _ i: Int, _ o: Int) { lock.lock(); var u: [Int] = usage[id] ?? [0, 0]; u[0] += i; u[1] += o; usage[id] = u; lock.unlock() }
    func usageOf(_ id: String) -> [Int] { lock.lock(); defer { lock.unlock() }; return usage[id] ?? [0, 0] }
    func state(_ id: String) -> (text: String, ok: Bool, error: String, brain: String, tools: [String]) {
        lock.lock(); defer { lock.unlock() }
        let t: String = (texts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tl: [String] = tools[id] ?? []
        if let f = fin[id] { return (text: t, ok: f.ok, error: f.error, brain: f.brain, tools: tl) }
        return (text: t, ok: !t.isEmpty, error: "délai dépassé", brain: "", tools: tl)
    }
}

/// V3 : séances en cours, annulables par POST /api/council/cancel {run}. Quitter l'écran n'annule pas l'exécution du président
/// (comportement LOT G inchangé) ; le bouton « Annuler » arrête tout, exécution comprise.
final class CouncilRunRegistry: @unchecked Sendable {
    static let shared: CouncilRunRegistry = CouncilRunRegistry()
    let lock = NSLock()
    var live: Set<String> = []
    var cancelled: Set<String> = []
    func begin(_ id: String) { lock.lock(); live.insert(id); lock.unlock() }
    func end(_ id: String) { lock.lock(); live.remove(id); cancelled.remove(id); lock.unlock() }
    func cancel(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; guard live.contains(id) else { return false }; cancelled.insert(id); return true }
    func isCancelled(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled.contains(id) }
}

extension NovaApp {
    /// LOT G — routes du Conseil. À appeler dans App.swift juste après `coutsRoutes(); leconsStart()`.
    /// POST /api/council/stream {question, members?, act?, followup?, sparring?} (SSE) — événements : members, phase, mbrain, mtool, mdelta, mdone,
    ///   rbrain, rdelta, rdone, chair, chairbrain, delta, votes, usage, saved, exec, xtool, xdelta, step, confirm, report, cancelled, error, done.
    ///   Sans `act`, pas d'exécution (salle de décision inchangée).
    /// POST /api/council/followup {id, question, act?} (SSE) — relance avec le fil complet. GET /api/council/history · GET /api/council/get?id=
    /// POST /api/council/cancel {run} — V3 : annule la séance en cours (membres, réfutation, président, exécution).
    func councilRoutes() {
        let s: HTTPServer = server
        s.on("POST", "/api/council/stream") { [self] req, res in
            let j: [String: Any] = req.json
            let fid: String = (j["followup"] as? String) ?? ""
            councilSession(j, followupID: fid, res: res)
        }
        s.on("POST", "/api/council/followup") { [self] req, res in
            let j: [String: Any] = req.json
            let fid: String = (j["id"] as? String) ?? ""
            guard CouncilStore.get(fid) != nil else { let bad: [String: Any] = ["error": "conseil introuvable"]; res.json(bad, status: 404); return }
            councilSession(j, followupID: fid, res: res)
        }
        s.on("POST", "/api/council/cancel") { req, res in
            let j: [String: Any] = req.json
            let run: String = (j["run"] as? String) ?? ""
            let ok: Bool = CouncilRunRegistry.shared.cancel(run)
            let body: [String: Any] = ["ok": ok]
            res.json(body)
        }
        s.on("GET", "/api/council/history") { _, res in
            let body: [String: Any] = ["items": CouncilStore.summaries()]
            res.json(body)
        }
        s.on("GET", "/api/council/get") { req, res in
            let id: String = req.query["id"] ?? ""
            guard let rec = CouncilStore.get(id) else { let bad: [String: Any] = ["error": "conseil introuvable"]; res.json(bad, status: 404); return }
            res.json(rec)
        }
    }

    /// Une séance (ou une relance si `followupID` désigne une séance enregistrée) :
    /// avis indépendants outillés en lecture → réfutation → décision (désaccords, vote) → exécution → mémoire.
    func councilSession(_ j: [String: Any], followupID: String, res: Response) {
        let q: String = ((j["question"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { let bad: [String: Any] = ["error": "question vide"]; res.json(bad, status: 400); return }
        let prev: [String: Any]? = CouncilStore.get(followupID)
        let sessionID: String = prev == nil ? "" : followupID
        var wanted: [String] = (j["members"] as? [String]) ?? []
        if wanted.isEmpty, let p = prev {
            let pm: [[String: Any]] = (p["members"] as? [[String: Any]]) ?? []
            wanted = pm.compactMap { $0["id"] as? String }
        }
        var specs: [BrainSpec] = Council.pick(router: router, wanted: wanted)
        if specs.isEmpty && !wanted.isEmpty { specs = Council.pick(router: router, wanted: []) }
        let act: Bool = (j["act"] as? Bool) ?? false
        let sparring: Bool = (j["sparring"] as? Bool) ?? false
        let t0: Date = Date()
        let runID: String = "r" + String(Int(t0.timeIntervalSince1970 * 1000)) + String(UUID().uuidString.prefix(4)).lowercased()
        let reg: CouncilRunRegistry = CouncilRunRegistry.shared
        res.sseStart()
        let wlock = NSLock()
        func emit(_ ev: String, _ o: Any) { wlock.lock(); _ = res.sse(ev, o); wlock.unlock() }
        if specs.isEmpty {
            emit("error", ["message": "Aucun membre du conseil n'est joignable (voir Routeur & santé)."])
            emit("done", ["ok": false]); return
        }
        reg.begin(runID)
        defer { reg.end(runID) }
        let chairID: String? = Council.chairBrain(router: router)
        let chairPlanned: String = chairID.flatMap { router.spec($0)?.label } ?? "routage automatique"
        var memberRows: [[String: Any]] = []
        for (i, sp) in specs.enumerated() {
            let row: [String: Any] = ["id": sp.id, "label": sp.label, "role": Council.roleLabel(i), "model": sp.model, "family": Council.family(sp)]
            memberRows.append(row)
        }
        let limits: [String: Any] = Council.limits()
        let membersEv: [String: Any] = ["items": memberRows, "run": runID, "chair": chairPlanned, "limits": limits, "sparring": sparring]
        emit("members", membersEv)
        Amplitude.track("council_deliberation_started", ["members": specs.count, "act": act])   // AMPLITUDE (CRÉDITS 23/10) : déclenchement — jamais la question

        let name: String = settings.get("name", "Ahadi")
        let title: String = settings.get("user_title", "Capitaine")
        let thread: String = prev.map { CouncilStore.context($0) } ?? ""
        let questionPart: String = "QUESTION POSÉE AU CONSEIL :\n" + q
        let followPart: String = "FIL DU CONSEIL (tours précédents : avis nommés, réfutations, votes, décisions, actions) :\n" + thread + "\nRELANCE D'AHADI :\n" + q
        // 24/10 : un nouveau conseil connaît les séances passées (titres, décisions, ce qui attend le GO d'Ahadi) ;
        // s'il est question du conseil précédent / des décisions passées, le fil complet de la dernière séance est joint.
        var pastPart: String = ""
        if thread.isEmpty {
            let past: [[String: Any]] = Array(CouncilStore.summaries().prefix(6))
            if !past.isEmpty {
                var lines: [String] = []
                for p in past {
                    let t: String = (p["title"] as? String) ?? ""
                    let d: String = String(((p["updated"] as? String) ?? (p["created"] as? String) ?? "").prefix(16))
                    let dec: String = (p["decided"] as? String) ?? ""
                    let pend: String = (p["pending"] as? String) ?? ""
                    var l: String = "- [" + ((p["id"] as? String) ?? "") + "] " + d + " — « " + t + " »"
                    if !dec.isEmpty { l += "\n  Décidé : " + dec }
                    if !pend.isEmpty { l += "\n  En attente du GO d'Ahadi : " + pend }
                    lines.append(l)
                }
                pastPart = "\n\nSÉANCES PRÉCÉDENTES DU CONSEIL (archivées par Nova, de la plus récente à la plus ancienne) :\n" + lines.joined(separator: "\n")
                let fq: String = q.lowercased()
                let refersPast: Bool = ["précédent", "precedent", "dernier conseil", "derniere seance", "dernière séance", "décisions passées", "decisions passees", "conseil d'avant", "dernières décisions"].contains(where: { fq.contains($0) })
                if refersPast, let lastID = past.first?["id"] as? String, let lastRec = CouncilStore.get(lastID) {
                    pastPart += "\n\nFIL COMPLET DE LA DERNIÈRE SÉANCE (référence pour « le conseil précédent ») :\n" + CouncilStore.context(lastRec, limit: 6000)
                }
            }
        }
        let userMsg: String = (thread.isEmpty ? questionPart : followPart) + pastPart
        let memBlock: String = memory.promptBlock(max: 15, query: q)
        let mrows: [[String: Any]] = memberRows
        let noRows: [[String: Any]] = []
        let noActions: [[String: Any]] = []

        /// Annulation : le tour partiel est archivé tel quel (traçabilité), statut « cancelled ».
        func stopHere(_ stage: String, _ r: [String: Any]) {
            var rr: [String: Any] = r
            rr["exec"] = "cancelled"
            rr["cancelled_at"] = stage
            rr["duration_s"] = Int(Date().timeIntervalSince(t0))
            let sid0: String = CouncilStore.appendRound(id: sessionID, title: q, members: mrows, round: rr)
            let sv: [String: Any] = ["id": sid0]
            emit("saved", sv)
            let ce: [String: Any] = ["stage": stage, "id": sid0]
            emit("cancelled", ce)
            let de: [String: Any] = ["ok": false, "cancelled": true, "id": sid0]
            emit("done", de)
        }

        // 1) TEMPS 1 — avis indépendants, en parallèle, chacun avec ses outils de lecture (4 étapes au plus).
        let ph1: [String: Any] = ["name": "avis", "limit_s": Int(Council.memberDeadline)]
        emit("phase", ph1)
        let box = CouncilMemberBox()
        let group = DispatchGroup()
        let stopAt: Date = Date().addingTimeInterval(Council.memberDeadline)
        let stop: () -> Bool = { res.clientGone || Date() > stopAt || reg.isCancelled(runID) }
        for (i, sp) in specs.enumerated() {
            let extra: String = Council.memberExtra(index: i, specs: specs, sparring: sparring)
            let sys: String = Persona.system(assistantName: sp.label, title: title, memory: memBlock, voice: false, tools: true, extra: extra)
            let role: String = Council.roleLabel(i)
            let mid: String = sp.id
            let agent = Agent(router: router, tools: tools)
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                var err: String = ""
                var brainLabel: String = ""
                _ = agent.run(messages: [ChatMsg("user", userMsg)], system: sys, mode: "deep", preferred: mid, maxTokens: Council.memberMaxTokens, useTools: true,
                              maxSteps: Council.memberSteps, allowed: Council.readTools, actor: "Dot Conseil · " + role, cancel: stop) { ev in
                    switch ev {
                    case .delta(let t):
                        box.add(mid, t)
                        emit("mdelta", ["id": mid, "t": t])
                    case .tool(let n, let inp, _):
                        box.reset(mid, tool: n)
                        let shortIn: String = String(inp.prefix(120))
                        emit("mtool", ["id": mid, "name": n, "input": shortIn])
                    case .start(_, let l):
                        brainLabel = l
                        emit("mbrain", ["id": mid, "label": l])
                    case .usage(let a, let b): box.addUsage(mid, a, b)
                    case .draftReset: box.clear(mid)   // VÉRITÉ-5 (E3, 23/10) : relance interne sans .tool intermédiaire — le brouillon du membre quitte l'avis persisté
                    case .error(let m): err = m
                    default: break
                    }
                }
                let txt: String = box.text(mid).trimmingCharacters(in: .whitespacesAndNewlines)
                let ok: Bool = !txt.isEmpty
                let why: String = err.isEmpty ? "réponse vide" : err
                box.finish(mid, ok: ok, error: ok ? "" : why, brain: brainLabel)
                if ok {
                    var done: [String: Any] = ["id": mid, "ok": true, "text": txt, "position": CouncilParse.position(txt)]
                    if let c = CouncilParse.confidence(txt) { done["confidence"] = c }
                    emit("mdone", done)
                } else {
                    let done: [String: Any] = ["id": mid, "ok": false, "error": why]
                    emit("mdone", done)
                }
            }
        }
        _ = group.wait(timeout: .now() + Council.memberDeadline + 5)

        var avis: [[String: Any]] = []
        var digestParts: [String] = []
        var okIdx: [Int] = []
        for (i, sp) in specs.enumerated() {
            let st = box.state(sp.id)
            let role: String = Council.roleLabel(i)
            var row: [String: Any] = ["id": sp.id, "label": sp.label, "role": role, "brain": st.brain, "model": sp.model, "family": Council.family(sp),
                                      "text": st.text, "ok": st.ok, "error": st.error, "tools": st.tools]
            let u: [Int] = box.usageOf(sp.id)
            row["usage_in"] = u[0]
            row["usage_out"] = u[1]
            if st.ok {
                row["position"] = CouncilParse.position(st.text)
                if let c = CouncilParse.confidence(st.text) { row["confidence"] = c }
                row["change_mind"] = CouncilParse.firstLine(CouncilStore.section(st.text, "changer"))
                digestParts.append("### \(Council.whoAnswered(sp.label, st.brain)) — \(role)\n\(st.text)")
                okIdx.append(i)
            }
            avis.append(row)
        }
        var round: [String: Any] = ["ts": CouncilStore.nowISO(), "question": q, "avis": avis, "run": runID, "sparring": sparring, "limits": limits]
        round["refutations"] = noRows; round["votes"] = noRows; round["decision"] = ""; round["decided"] = ""
        round["applied"] = ""; round["pending"] = ""; round["notdone"] = ""; round["report"] = ""
        round["actions"] = noActions; round["exec"] = "none"
        if reg.isCancelled(runID) { stopHere("avis", round); return }
        if digestParts.isEmpty {
            emit("error", ["message": "Aucun membre du conseil n'a pu répondre (voir Routeur & santé)."])
            emit("done", ["ok": false]); return
        }

        // 2) TEMPS 2 — réfutation : court, sans outil, chaque membre sur SON cerveau (solo) ; seulement s'il y a au moins deux avis.
        let rbox = CouncilMemberBox()
        var refutRows: [[String: Any]] = []
        var refutDigest: [String] = []
        if okIdx.count >= 2 {
            let ph2: [String: Any] = ["name": "refutation", "limit_s": Int(Council.rebuttalDeadline)]
            emit("phase", ph2)
            let rgroup = DispatchGroup()
            let rStop: Date = Date().addingTimeInterval(Council.rebuttalDeadline)
            let rCancel: () -> Bool = { res.clientGone || Date() > rStop || reg.isCancelled(runID) }
            let rr: Router = router
            for i in okIdx {
                let sp: BrainSpec = specs[i]
                let mid: String = sp.id
                var others: [String] = []
                for k in okIdx where k != i {
                    let other: String = (avis[k]["text"] as? String) ?? ""
                    others.append("### " + specs[k].label + " — " + Council.roleLabel(k) + "\n" + String(other.prefix(1100)))
                }
                let mine: String = String(((avis[i]["text"] as? String) ?? "").prefix(1100))
                let rMsg: String = "QUESTION : " + q + "\n\nTON AVIS INITIAL :\n" + mine + "\n\nAVIS DES AUTRES MEMBRES :\n" + others.joined(separator: "\n\n")
                let rSys: String = Council.rebuttalSystem(index: i, specs: specs, sparring: sparring)
                rgroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { rgroup.leave() }
                    var err: String = ""
                    var lab: String = ""
                    _ = rr.chat(messages: [ChatMsg("user", rMsg)], system: rSys, mode: "deep", preferred: mid, maxTokens: Council.rebuttalMaxTokens,
                                cancel: rCancel, deadline: Council.rebuttalDeadline, solo: true) { ev in
                        switch ev {
                        case .start(_, let l):
                            lab = l
                            emit("rbrain", ["id": mid, "label": l])
                        case .delta(let t):
                            rbox.add(mid, t)
                            emit("rdelta", ["id": mid, "t": t])
                        case .draftReset: rbox.clear(mid)
                        case .usage(let a, let b): rbox.addUsage(mid, a, b)
                        case .error(let m): err = m
                        default: break
                        }
                    }
                    let txt: String = rbox.text(mid).trimmingCharacters(in: .whitespacesAndNewlines)
                    let ok: Bool = !txt.isEmpty
                    let why: String = err.isEmpty ? "réponse vide" : err
                    rbox.finish(mid, ok: ok, error: ok ? "" : why, brain: lab)
                    if ok {
                        var d: [String: Any] = CouncilParse.rebuttal(txt, selfID: mid, members: mrows)
                        d["id"] = mid; d["ok"] = true; d["text"] = txt
                        emit("rdone", d)
                    } else {
                        let d: [String: Any] = ["id": mid, "ok": false, "error": why]
                        emit("rdone", d)
                    }
                }
            }
            _ = rgroup.wait(timeout: .now() + Council.rebuttalDeadline + 5)
            for i in okIdx {
                let sp: BrainSpec = specs[i]
                let st = rbox.state(sp.id)
                var row: [String: Any] = ["id": sp.id, "label": sp.label, "role": Council.roleLabel(i), "brain": st.brain, "text": st.text, "ok": st.ok, "error": st.error]
                let u: [Int] = rbox.usageOf(sp.id)
                row["usage_in"] = u[0]
                row["usage_out"] = u[1]
                if st.ok {
                    let parsed: [String: Any] = CouncilParse.rebuttal(st.text, selfID: sp.id, members: mrows)
                    for (k, v) in parsed { row[k] = v }
                    refutDigest.append("### \(Council.whoAnswered(sp.label, st.brain)) — \(Council.roleLabel(i))\n\(st.text)")
                }
                refutRows.append(row)
            }
            round["refutations"] = refutRows
            if reg.isCancelled(runID) { stopHere("refutation", round); return }
        }

        // 3) TEMPS 3 — le président tranche : recommandation, désaccords, vote, risques, « Décidé ».
        let ph3: [String: Any] = ["name": "president", "limit_s": Int(Council.chairDeadline)]
        emit("phase", ph3)
        let roster: String = Council.roster(specs)
        let chairSys: String = Council.chairSystemFull(name: name, count: digestParts.count, roster: roster, act: act, sparring: sparring)
        let threadPart: String = thread.isEmpty ? "" : "FIL DES TOURS PRÉCÉDENTS :\n" + thread + "\n"
        let refutPart: String = refutDigest.isEmpty ? "\n\n(Pas de tour de réfutation : un seul avis disponible.)" : "\n\nTOUR DE RÉFUTATION :\n" + refutDigest.joined(separator: "\n\n")
        let chairMsg: String = threadPart + "QUESTION / RELANCE : " + q + "\n\nAVIS INDÉPENDANTS DU CONSEIL :\n" + digestParts.joined(separator: "\n\n") + refutPart
        let chairEv: [String: Any] = ["start": true, "planned": chairPlanned]
        emit("chair", chairEv)
        var decision: String = ""
        var chairLabel: String = ""
        var chairIn: Int = 0
        var chairOut: Int = 0
        let chairStop: Date = Date().addingTimeInterval(Council.chairDeadline)
        _ = router.chat(messages: [ChatMsg("user", chairMsg)], system: chairSys, mode: "deep", preferred: chairID, maxTokens: Council.chairMaxTokens,
                        cancel: { res.clientGone || Date() > chairStop || reg.isCancelled(runID) }, deadline: Council.chairDeadline) { ev in
            switch ev {
            case .start(_, let l):
                chairLabel = l
                emit("chairbrain", ["label": l])
            case .delta(let t): decision += t; emit("delta", ["t": t])
            case .draftReset: decision = ""   // VÉRITÉ-4 (E3, 23/10) : bascule du routeur pendant la synthèse — la décision persistée puis exécutée est la dernière génération
            case .usage(let a, let b): chairIn += a; chairOut += b
            case .error(let m): emit("error", ["message": m])
            default: break
            }
        }
        decision = decision.trimmingCharacters(in: .whitespacesAndNewlines)
        let decidedSec: String = CouncilStore.section(decision, "decid")
        let decided: String = decidedSec.isEmpty ? decision : decidedSec
        let votes: [[String: Any]] = decision.isEmpty ? noRows : CouncilParse.votes(decision, members: mrows)
        if !votes.isEmpty {
            let ve: [String: Any] = ["items": votes]
            emit("votes", ve)
        }
        var totIn: Int = chairIn
        var totOut: Int = chairOut
        for sp in specs {
            let a: [Int] = box.usageOf(sp.id)
            let b: [Int] = rbox.usageOf(sp.id)
            totIn += a[0] + b[0]
            totOut += a[1] + b[1]
        }
        let usage: [String: Any] = ["in": totIn, "out": totOut, "chair_in": chairIn, "chair_out": chairOut]
        emit("usage", usage)
        let chairInfo: [String: Any] = ["id": chairID ?? "", "label": chairLabel, "planned": chairPlanned]
        round["decision"] = decision; round["decided"] = decided; round["votes"] = votes
        round["chair"] = chairInfo; round["usage"] = usage
        round["duration_s"] = Int(Date().timeIntervalSince(t0))
        if reg.isCancelled(runID) { stopHere("president", round); return }
        let willAct: Bool = act && !decision.isEmpty
        round["exec"] = willAct ? "running" : "none"
        let sid: String = CouncilStore.appendRound(id: sessionID, title: q, members: mrows, round: round)
        Amplitude.track("council_verdict", ["members": digestParts.count, "will_act": willAct, "decision_chars": decision.count])   // AMPLITUDE (CRÉDITS 23/10) : verdict — compteurs seuls, jamais la décision
        emit("saved", ["id": sid])
        if !willAct {
            let rep: [String: Any] = ["id": sid, "decided": decided, "applied": "", "pending": "", "notdone": "", "exec": "none"]
            emit("report", rep)
            emit("done", ["ok": true, "members": digestParts.count, "id": sid]); return
        }

        // 4) Le président applique en arrière-plan (outils complets, 10 étapes, gardes Règle d'or n°2 inchangées) ;
        //    il continue même si l'interface est fermée — seul le bouton « Annuler » (POST /api/council/cancel) l'arrête.
        let ph4: [String: Any] = ["name": "application", "limit_s": Int(Council.execDeadline)]
        emit("phase", ph4)
        emit("exec", ["start": true, "id": sid])
        let execSys: String = Persona.system(assistantName: "Nova", title: title, memory: memBlock, voice: false, tools: true, extra: NovaMap.text + Council.execRules)
        let threadTail: String = thread.isEmpty ? "" : "\n\nFIL PRÉCÉDENT (GO éventuels déjà donnés par Ahadi dans sa relance) :\n" + String(thread.suffix(4000))
        let execMsg: String = "QUESTION DU CONSEIL : " + q + "\n\nDÉCISION DU PRÉSIDENT (à appliquer) :\n" + String(decision.prefix(5000)) + threadTail
        let execStop: Date = Date().addingTimeInterval(Council.execDeadline)
        var report: String = ""
        var actions: [[String: Any]] = []
        var refused: [String] = []
        let chairAgent = Agent(router: router, tools: tools)
        _ = chairAgent.run(messages: [ChatMsg("user", execMsg)], system: execSys, mode: "deep", preferred: nil, maxTokens: 2000, useTools: true,   // MN2-4 : le livrable final du Conseil est son plus long texte — 1 500 → 2 000
                           maxSteps: Council.chairSteps, allowed: nil, actor: "Relais Conseil (président)", cancel: { Date() > execStop || reg.isCancelled(runID) }) { ev in
            switch ev {
            case .delta(let t): report += t; emit("xdelta", ["t": t])
            case .tool(let n, let inp, let outp):
                report = ""
                let xi: [String: Any] = ["name": n, "input": String(inp.prefix(300)), "output": String(outp.prefix(600))]
                emit("xtool", xi)
            case .step(let k, let info):
                let state: String = (info["state"] as? String) ?? ""
                if k == "step", state == "ok" || state == "err" {
                    let a: [String: Any] = ["tool": (info["tool"] as? String) ?? "", "arg": (info["arg"] as? String) ?? "", "ok": state == "ok"]
                    actions.append(a)
                }
                let resolved: Bool = (info["resolved"] as? Bool) ?? false
                let accepted: Bool = (info["ok"] as? Bool) ?? false
                if k == "confirm", resolved, !accepted { refused.append((info["tool"] as? String) ?? "action") }
                emit(k, info)
            case .draftReset: report = ""   // VÉRITÉ-5 (E3, 23/10) : relance interne sans .tool intermédiaire — le brouillon remplacé quitte le rapport persisté puis parsé
            case .error(let m): emit("error", ["message": m])
            default: break
            }
        }
        report = report.trimmingCharacters(in: .whitespacesAndNewlines)
        var applied: String = CouncilStore.section(report, "appliqu")
        var pending: String = CouncilStore.section(report, "attente")
        let notDone: String = CouncilStore.section(report, "non fait")
        if !refused.isEmpty {
            let lines: [String] = refused.map { "- \($0) : refusé ou sans réponse sous 60 s — à refaire avec ton GO" }
            let more: String = lines.joined(separator: "\n")
            pending = pending.isEmpty ? more : pending + "\n" + more
        }
        if applied.isEmpty && pending.isEmpty && notDone.isEmpty { applied = report }
        let execEnd: String = reg.isCancelled(runID) ? "cancelled" : (Date() > execStop ? "timeout" : "done")
        let patch: [String: Any] = ["applied": applied, "pending": pending, "notdone": notDone, "report": report, "actions": actions, "exec": execEnd,
                                    "duration_s": Int(Date().timeIntervalSince(t0))]
        CouncilStore.patchLastRound(id: sid, patch)
        let rep: [String: Any] = ["id": sid, "decided": decided, "applied": applied, "pending": pending, "notdone": notDone, "actions": actions, "exec": execEnd]
        emit("report", rep)
        emit("done", ["ok": true, "members": digestParts.count, "id": sid])
    }
}
