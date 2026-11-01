import Foundation

/// Croissance de Nova SOUS CONTRÔLE HUMAIN : l'assistant et les Dots lisent le code, consignent des leçons, des idées et des PROPOSITIONS de correctif.
/// Aucune de ces commandes ne modifie le code ni les réglages : une proposition n'est qu'un texte « à valider » ; c'est l'utilisateur qui décide de l'appliquer.
extension NovaApp {
    static let learnExts: Set<String> = ["swift", "js", "css", "html", "json", "md"]
    /// Verbes de lecture/consignation accessibles aussi aux Dots.
    public static let learnVerbs: Set<String> = ["idee", "idees", "idee-statut", "apprendre", "lecons", "code-lire", "code-chercher", "proposer", "propositions"]
    static var learnLog: JSONFile { JSONFile("evolution.json") }
    static let learnLock = NSLock()

    static func projectRootDir() -> URL? {
        let fm = FileManager.default
        for c in [fm.homeDirectoryForCurrentUser.path + "/spark-local/Nova2", fm.currentDirectoryPath] where fm.fileExists(atPath: c + "/Package.swift") && fm.fileExists(atPath: c + "/Sources/NovaCore") { return URL(fileURLWithPath: c) }
        return nil
    }
    static func learnAdd(_ e: [String: Any]) -> String {
        learnLock.lock(); defer { learnLock.unlock() }
        var l = learnLog.read(default: [[String: Any]]()); var x = e
        let id = String(UUID().uuidString.prefix(6)).lowercased(); x["id"] = id; x["ts"] = nowISO(); l.append(x); learnLog.write(Array(l.suffix(300)))
        return id
    }
    static func relPath(_ raw: String) -> String? {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = projectRootDir()?.path, p.hasPrefix(r + "/") { p = String(p.dropFirst(r.count + 1)) }
        if p.hasPrefix("./") { p = String(p.dropFirst(2)) }
        guard !p.isEmpty, !p.hasPrefix("/"), !p.contains(".."), ["Sources/", "web/", "tests/", "docs/"].contains(where: { p.hasPrefix($0) }), learnExts.contains((p as NSString).pathExtension.lowercased()) else { return nil }
        return p
    }
    static func balancedCode(_ s: String) -> Bool {
        var st: [Character] = []; let a = Array(s); var i = 0; let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        while i < a.count {
            let c = a[i]
            if c == "/", i + 1 < a.count, a[i + 1] == "/" { while i < a.count, a[i] != "\n" { i += 1 }; continue }
            if c == "/", i + 1 < a.count, a[i + 1] == "*" { i += 2; while i + 1 < a.count, !(a[i] == "*" && a[i + 1] == "/") { i += 1 }; i += 2; continue }
            if c == "\"" || c == "'" || c == "`" { i += 1; while i < a.count, a[i] != c, a[i] != "\n" || c == "`" { if a[i] == "\\" { i += 1 }; i += 1 }; i += 1; continue }
            if "([{".contains(c) { st.append(c) } else if let o = pairs[c] { guard st.last == o else { return false }; st.removeLast() }
            i += 1
        }
        return st.isEmpty
    }

    /// CHANTIER 2 (26/10) : cas extraits d'apprentissage() (453 ms) — mecanique, inchange.
    func appCodeLire(_ rest: String) -> String? {
            let a = rest.split(separator: " ").map(String.init); guard let p = a.first, let rel = NovaApp.relPath(p) else { return "code-lire <chemin relatif : Sources/NovaCore/…, web/…> [début-fin]" }
            var s: String? = NovaApp.projectRootDir().flatMap { try? String(contentsOf: $0.appendingPathComponent(rel), encoding: .utf8) }
            if s == nil, rel.hasPrefix("web/"), let w = server.staticDir { s = try? String(contentsOfFile: w + "/" + rel.dropFirst(4), encoding: .utf8) }
            guard let src = s else { return "Fichier introuvable : \(rel)" }
            let all = src.components(separatedBy: "\n"); var lo = 1, hi = min(all.count, 200)
            if a.count > 1 { let q = a[1].split(separator: "-").compactMap { Int($0) }; if q.count == 2 { lo = max(1, q[0]); hi = min(all.count, max(lo, min(q[1], lo + 249))) } }
            return "\(rel) — \(all.count) lignes (affichées \(lo)-\(hi)) :\n" + String((lo...max(lo, hi)).map { "\($0)| \(all[$0 - 1])" }.joined(separator: "\n").prefix(14000))
    }

    func appCodeChercher(_ rest: String) -> String? {
            let q = rest.trimmingCharacters(in: .whitespaces); guard q.count >= 2 else { return "code-chercher <motif>" }
            var bases: [(String, URL)] = []
            if let r = NovaApp.projectRootDir() { for d in ["Sources", "web"] { bases.append((d, r.appendingPathComponent(d))) } } else if let w = server.staticDir { bases.append(("web", URL(fileURLWithPath: w))) }
            var hits: [String] = []
            outer: for (pre, base) in bases {
                guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
                for case let u as URL in en {
                    guard NovaApp.learnExts.contains(u.pathExtension.lowercased()), let s = try? String(contentsOf: u, encoding: .utf8) else { continue }
                    for (i, l) in s.components(separatedBy: "\n").enumerated() where l.range(of: q, options: .caseInsensitive) != nil {
                        hits.append("\(pre)\(u.path.dropFirst(base.path.count)):\(i + 1): " + String(l.trimmingCharacters(in: .whitespaces).prefix(140))); if hits.count >= 40 { break outer }
                    }
                }
            }
            return hits.isEmpty ? "Aucune occurrence de « \(q) »." : hits.joined(separator: "\n")
    }

    func apprentissage(_ verb: String, _ raw: String) -> String? {
        let lines = raw.components(separatedBy: "\n"); let hp = (lines.first ?? "").split(separator: " ", maxSplits: 1).map(String.init); let rest = hp.count > 1 ? hp[1] : ""
        switch verb {
        case "code-lire":
            return appCodeLire(rest)
        case "code-chercher":
            return appCodeChercher(rest)
        case "proposer":
            let head = rest.components(separatedBy: " | "); guard let rel = NovaApp.relPath(head[0]) else { return "proposer <chemin> | <raison>, puis blocs « <<<< ancien ==== nouveau >>>> »" }
            let why = head.dropFirst().joined(separator: " | ")
            var blocks: [(String, String)] = []; var mode = 0; var o: [String] = [], n: [String] = []
            for l in lines.dropFirst() { let t = l.trimmingCharacters(in: .whitespaces)
                if t == "<<<<" { mode = 1; o = []; n = []; continue }; if t == "====", mode == 1 { mode = 2; continue }
                if t == ">>>>", mode == 2 { blocks.append((o.joined(separator: "\n"), n.joined(separator: "\n"))); mode = 0; continue }
                if mode == 1 { o.append(l) } else if mode == 2 { n.append(l) } }
            guard !blocks.isEmpty else { return "Aucun bloc. Format : <<<<\\nancien exact\\n====\\nnouveau\\n>>>>" }
            if let root = NovaApp.projectRootDir(), let cur = try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) {
                var s = cur
                for (i, b) in blocks.enumerated() { let c = s.components(separatedBy: b.0).count - 1; guard !b.0.isEmpty, c == 1 else { return "Bloc \(i + 1) : l'ancien texte doit apparaître exactement une fois dans \(rel) (trouvé \(c) fois). Proposition non enregistrée." }; s = s.replacingOccurrences(of: b.0, with: b.1) }
                if NovaApp.balancedCode(cur), !NovaApp.balancedCode(s) { return "Proposition refusée : le résultat déséquilibre les accolades/parenthèses." }
            }
            let id = NovaApp.learnAdd(["kind": "proposition", "path": rel, "why": String(why.prefix(300)), "status": "à valider", "blocks": blocks.map { ["old": $0.0, "new": $0.1] }])
            return "Proposition #\(id) enregistrée pour \(rel) (« à valider »). Rien n'a été modifié : l'utilisateur décide de l'appliquer."
        case "propositions":
            let l = NovaApp.learnLog.read(default: [[String: Any]]()).filter { ($0["kind"] as? String) == "proposition" }.suffix(15)
            return l.isEmpty ? "Aucune proposition." : l.map { "• #\($0["id"] ?? "") · \($0["status"] ?? "") · \($0["path"] ?? "") · \(String("\($0["why"] ?? "")".prefix(100)))" }.joined(separator: "\n")
        case "apprendre":
            let t = rest.trimmingCharacters(in: .whitespacesAndNewlines); guard t.count > 8 else { return "apprendre <leçon : ce qui a échoué, pourquoi, la bonne méthode>" }
            tools.memory.add("LEÇON (Nova) : " + String(t.prefix(400)), source: "assistant"); _ = NovaApp.learnAdd(["kind": "lecon", "why": String(t.prefix(300)), "status": "retenue"]); return "Leçon retenue."
        case "lecons":
            let m = tools.memory.list().filter { (($0["text"] as? String) ?? "").hasPrefix("LEÇON (Nova)") }.suffix(15)
            return m.isEmpty ? "Aucune leçon retenue." : m.map { "• " + String("\($0["text"] ?? "")".dropFirst(14)) }.joined(separator: "\n")
        case "idee":
            let t = rest.trimmingCharacters(in: .whitespacesAndNewlines); guard t.count > 12 else { return "idee <amélioration : quoi, pourquoi, bénéfice>" }
            return "Idée #\(NovaApp.learnAdd(["kind": "idee", "why": String(t.prefix(500)), "status": "proposée"])) consignée : à valider par l'utilisateur."
        case "idees":
            let l = NovaApp.learnLog.read(default: [[String: Any]]()).filter { ($0["kind"] as? String) == "idee" }.suffix(20)
            return l.isEmpty ? "Aucune idée consignée." : l.map { "• #\($0["id"] ?? "") · \(String(("\($0["ts"] ?? "")").prefix(10))) · \($0["status"] ?? "") · \($0["why"] ?? "")" }.joined(separator: "\n")
        case "idee-statut":
            let a = rest.split(separator: " ", maxSplits: 1).map(String.init); guard a.count == 2 else { return "idee-statut <id> <proposée|en cours|appliquée|rejetée>" }
            NovaApp.learnLock.lock(); var l = NovaApp.learnLog.read(default: [[String: Any]]()); if let i = l.firstIndex(where: { ($0["id"] as? String) == a[0] }) { l[i]["status"] = a[1]; NovaApp.learnLog.write(l) }; NovaApp.learnLock.unlock()
            return "#\(a[0]) : \(a[1])."
        default: return nil
        }
    }
}
