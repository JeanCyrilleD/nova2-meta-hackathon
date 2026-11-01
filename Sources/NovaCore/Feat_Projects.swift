import Foundation

// Feat_Projects.swift — Mémoire de projets (CAFU, GHO, BRVM, Mentorat Angelica…).
// Stockage : projects.json = {"items": [projet], "last_scan": iso, "last_note": str}
// projet = {id, nom, alias[], personnes[], echeances[], decisions[], documents[] (chemins), notes, maj}
// Enrichissement automatique 2×/jour (mémoire, conversations, commitments.json, decisions.json, Spotlight en lecture seule) via router.complete(mode:"fast").
// Rien n'est envoyé ni supprimé automatiquement ; les notes saisies par le Capitaine ne sont jamais écrasées par l'IA.

final class ProjectsState: @unchecked Sendable {
    static let shared: ProjectsState = ProjectsState()
    let lock: NSLock = NSLock()
    var timer: DispatchSourceTimer? = nil
    var started: Bool = false
    var scanning: Bool = false
    let file: JSONFile = JSONFile("projects.json")
    let queue: DispatchQueue = DispatchQueue(label: "nova.projects", qos: .utility)
}

public enum ProjectMemory {
    static func items() -> [[String: Any]] {
        let o: [String: Any] = ProjectsState.shared.file.read(default: [String: Any]())
        return (o["items"] as? [[String: Any]]) ?? []
    }
    static func save(_ items: [[String: Any]], note: String? = nil, scanned: Bool = false) {
        var o: [String: Any] = ProjectsState.shared.file.read(default: [String: Any]())
        o["items"] = items
        if scanned { o["last_scan"] = nowISO() }
        if let n = note { o["last_note"] = n }
        ProjectsState.shared.file.write(o)
    }
    static func strs(_ v: Any?) -> [String] {
        if let a = v as? [String] { return a.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        if let a = v as? [Any] { return a.compactMap { x -> String? in
            if let s = x as? String { return s }
            if let d = x as? [String: Any] {
                let parts: [String] = d.values.compactMap { $0 as? String }
                return parts.joined(separator: " — ")
            }
            return nil
        }.filter { !$0.isEmpty } }
        if let s = v as? String, !s.isEmpty { return [s] }
        return []
    }
    static func norm(_ s: String) -> String {
        return s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func names(_ p: [String: Any]) -> [String] {
        var out: [String] = []
        if let n = p["nom"] as? String, !n.isEmpty { out.append(n) }
        out.append(contentsOf: strs(p["alias"]))
        return out
    }
    static func mergeList(_ a: [String], _ b: [String], limit: Int) -> [String] {
        var out: [String] = a
        var seen: Set<String> = Set(a.map { norm($0) })
        for x in b {
            let k: String = norm(x)
            if k.isEmpty || seen.contains(k) { continue }
            seen.insert(k); out.append(x)
        }
        if out.count > limit { out = Array(out.suffix(limit)) }
        return out
    }
    static func findIndex(_ items: [[String: Any]], names ns: [String]) -> Int? {
        let keys: Set<String> = Set(ns.map { norm($0) }.filter { !$0.isEmpty })
        if keys.isEmpty { return nil }
        for (i, p) in items.enumerated() {
            let pk: Set<String> = Set(names(p).map { norm($0) })
            if !pk.isDisjoint(with: keys) { return i }
        }
        return nil
    }

    /// Score de pertinence d'un projet pour une requête (0 = hors sujet).
    static func score(_ p: [String: Any], query: String) -> Int {
        let q: String = " " + norm(query) + " "
        var s: Int = 0
        for n in names(p) {
            let k: String = norm(n)
            if k.count >= 2 && q.contains(k) { s += 10 }
        }
        for person in strs(p["personnes"]) {
            let first: String = norm(person).components(separatedBy: CharacterSet(charactersIn: " ,(—-")).first ?? ""
            if first.count >= 4 && q.contains(first) { s += 3 }
        }
        return s
    }

    static func block(_ p: [String: Any]) -> String {
        var lines: [String] = []
        let nom: String = (p["nom"] as? String) ?? "?"
        let al: [String] = strs(p["alias"])
        lines.append("■ " + nom + (al.isEmpty ? "" : " (alias : " + al.joined(separator: ", ") + ")"))
        if (p["archive"] as? Bool) == true { lines.append("  ARCHIVÉ (projet clos le " + String(((p["archive_ts"] as? String) ?? "").prefix(10)) + ", deuil validé par Ahadi) — ne le traite plus comme actif") }   // V5-P (Feat_Deuil.swift)
        let pe: [String] = strs(p["personnes"])
        if !pe.isEmpty { lines.append("  Personnes : " + pe.prefix(8).joined(separator: " ; ")) }
        let ec: [String] = strs(p["echeances"])
        if !ec.isEmpty { lines.append("  Échéances : " + ec.prefix(6).joined(separator: " ; ")) }
        let de: [String] = strs(p["decisions"])
        if !de.isEmpty { lines.append("  Décisions : " + de.suffix(5).joined(separator: " ; ")) }
        let docs: [String] = strs(p["documents"])
        if !docs.isEmpty {
            let short: [String] = docs.prefix(5).map { ($0 as NSString).lastPathComponent }
            lines.append("  Documents : " + short.joined(separator: " ; "))
        }
        let notes: String = (p["notes"] as? String) ?? ""
        if !notes.isEmpty { lines.append("  Notes : " + String(notes.prefix(400))) }
        return lines.joined(separator: "\n")
    }

    /// Bloc texte compact des projets pertinents pour `query` (vide si rien). À ajouter au prompt système.
    public static func promptBlock(for query: String) -> String {
        let q: String = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return "" }
        let all: [[String: Any]] = items()
        var scored: [(Int, [String: Any])] = []
        for p in all {
            let sc: Int = score(p, query: q)
            if sc > 0 { scored.append((sc, p)) }
        }
        if scored.isEmpty { return "" }
        scored.sort { $0.0 > $1.0 }
        let blocks: [String] = scored.prefix(3).map { block($0.1) }
        return "Mémoire de projets (contexte du Capitaine) :\n" + blocks.joined(separator: "\n")
    }

    static func extractJSON(_ t: String) -> [String: Any]? {
        guard let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}"), a < b else { return nil }
        let sub: String = String(t[a...b])
        guard let d = sub.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// Spotlight en lecture seule : fichiers dont le nom contient le nom/alias (max 8).
    static func spotlight(_ ns: [String]) -> [String] {
        var out: [String] = []
        for n in ns.prefix(3) {
            let t: String = n.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count < 3 { continue }
            let r: (Int32, String) = runProcess("/usr/bin/mdfind", ["-onlyin", NSHomeDirectory(), "-name", t], timeout: 8)
            if r.0 != 0 { continue }
            let paths: [String] = r.1.split(separator: "\n").map { String($0) }.filter { p in
                !p.contains("/Library/") && !p.contains("/.") && !p.contains("/node_modules/") && !p.contains(".app/")
            }
            out.append(contentsOf: paths.prefix(6))
            if out.count >= 8 { break }
        }
        return Array(out.prefix(8))
    }
}

extension NovaApp {
    func projectsGather() -> String {
        var parts: [String] = []
        let mem: [[String: Any]] = memory.list()
        let memTxt: [String] = mem.suffix(80).compactMap { $0["text"] as? String }.map { String($0.prefix(240)) }
        if !memTxt.isEmpty { parts.append("MÉMOIRE :\n- " + memTxt.joined(separator: "\n- ")) }
        var conv: [String] = []
        for c in convs.list().prefix(15) {
            guard let id = c["id"] as? String, let full = convs.get(id) else { continue }
            let title: String = (full["title"] as? String) ?? ""
            let msgs: [[String: Any]] = (full["messages"] as? [[String: Any]]) ?? []
            let us: [String] = msgs.filter { ($0["role"] as? String) == "user" }.suffix(3).compactMap { $0["content"] as? String }.map { String($0.prefix(200)) }
            conv.append(title + " : " + us.joined(separator: " | "))
        }
        if !conv.isEmpty { parts.append("CONVERSATIONS RÉCENTES :\n- " + conv.joined(separator: "\n- ")) }
        let co: [String: Any] = JSONFile("commitments.json").read(default: [String: Any]())
        let citems: [[String: Any]] = (co["items"] as? [[String: Any]]) ?? []
        let ctx: [String] = citems.suffix(30).map { d in
            let vals: [String] = d.compactMap { (k, v) -> String? in
                if k == "id" { return nil }
                if let s = v as? String, !s.isEmpty, s.count < 200 { return k + "=" + s }
                return nil
            }
            return vals.joined(separator: ", ")
        }
        if !ctx.isEmpty { parts.append("ENGAGEMENTS :\n- " + ctx.joined(separator: "\n- ")) }
        let dec: [[String: Any]] = JSONFile("decisions.json").read(default: [[String: Any]]())
        let dtx: [String] = dec.suffix(25).map { d in
            let q: String = (d["question"] as? String) ?? ""
            let c: String = (d["choix"] as? String) ?? ""
            return String(q.prefix(160)) + " → " + String(c.prefix(120))
        }
        if !dtx.isEmpty { parts.append("DÉCISIONS :\n- " + dtx.joined(separator: "\n- ")) }
        let known: [String] = ProjectMemory.items().map { ProjectMemory.names($0).joined(separator: " / ") }
        if !known.isEmpty { parts.append("PROJETS DÉJÀ CONNUS : " + known.joined(separator: " ; ")) }
        let all: String = parts.joined(separator: "\n\n")
        return String(all.prefix(14000))
    }

    /// Détection/enrichissement des projets. Retourne une note lisible.
    @discardableResult func projectsScan() -> String {
        let st: ProjectsState = ProjectsState.shared
        st.lock.lock()
        if st.scanning { st.lock.unlock(); return "déjà en cours" }
        st.scanning = true
        st.lock.unlock()
        defer { st.lock.lock(); st.scanning = false; st.lock.unlock() }

        let material: String = projectsGather()
        if material.isEmpty { ProjectMemory.save(ProjectMemory.items(), note: "aucune donnée source", scanned: true); return "aucune donnée source" }
        let sys: String = "Tu extrais les PROJETS suivis par l'utilisateur (ex. CAFU, GHO, BRVM, Mentorat Angelica). Réponds UNIQUEMENT en JSON strict, sans texte autour : {\"projets\":[{\"nom\":\"\",\"alias\":[],\"personnes\":[],\"echeances\":[],\"decisions\":[],\"notes\":\"\"}]}. Échéances au format « AAAA-MM-JJ — objet » si possible. N'invente rien ; ignore les sujets ponctuels. Maximum 12 projets."
        guard let r = router.complete(messages: [ChatMsg("user", material)], system: sys, mode: "fast", maxTokens: 2500) else {
            ProjectMemory.save(ProjectMemory.items(), note: "cerveau indisponible", scanned: true); return "cerveau indisponible"
        }
        guard let obj = ProjectMemory.extractJSON(r.text), let found = obj["projets"] as? [[String: Any]] else {
            ProjectMemory.save(ProjectMemory.items(), note: "réponse non JSON", scanned: true); return "réponse non JSON"
        }
        var items: [[String: Any]] = ProjectMemory.items()
        var added: Int = 0
        var updated: Int = 0
        for f in found.prefix(12) {
            let nom: String = ((f["nom"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if nom.isEmpty { continue }
            let ns: [String] = [nom] + ProjectMemory.strs(f["alias"])
            let docs: [String] = ProjectMemory.spotlight(ns)
            if let i = ProjectMemory.findIndex(items, names: ns) {
                var p: [String: Any] = items[i]
                if (p["auto_off"] as? Bool) == true { continue }
                p["alias"] = ProjectMemory.mergeList(ProjectMemory.strs(p["alias"]), ProjectMemory.strs(f["alias"]), limit: 10)
                p["personnes"] = ProjectMemory.mergeList(ProjectMemory.strs(p["personnes"]), ProjectMemory.strs(f["personnes"]), limit: 20)
                p["echeances"] = ProjectMemory.mergeList(ProjectMemory.strs(p["echeances"]), ProjectMemory.strs(f["echeances"]), limit: 20)
                p["decisions"] = ProjectMemory.mergeList(ProjectMemory.strs(p["decisions"]), ProjectMemory.strs(f["decisions"]), limit: 25)
                p["documents"] = ProjectMemory.mergeList(ProjectMemory.strs(p["documents"]), docs, limit: 20)
                let n: String = (p["notes"] as? String) ?? ""
                if n.isEmpty, let fn = f["notes"] as? String { p["notes"] = fn }
                p["maj"] = nowISO()
                items[i] = p; updated += 1
            } else {
                var p: [String: Any] = [:]
                p["id"] = String(UUID().uuidString.prefix(8)).lowercased()
                p["nom"] = nom
                p["alias"] = ProjectMemory.strs(f["alias"])
                p["personnes"] = ProjectMemory.strs(f["personnes"])
                p["echeances"] = ProjectMemory.strs(f["echeances"])
                p["decisions"] = ProjectMemory.strs(f["decisions"])
                p["documents"] = docs
                p["notes"] = (f["notes"] as? String) ?? ""
                p["maj"] = nowISO()
                p["source"] = "auto"
                items.append(p); added += 1
            }
        }
        let note: String = String(added) + " nouveau(x), " + String(updated) + " enrichi(s)"
        ProjectMemory.save(items, note: note, scanned: true)
        bus.publish("projects", ["note": note])
        return note
    }

    func projectsStartTimer() {
        let st: ProjectsState = ProjectsState.shared
        st.lock.lock()
        if st.started { st.lock.unlock(); return }
        st.started = true
        st.lock.unlock()
        let t: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: st.queue)
        t.schedule(deadline: .now() + 900, repeating: 12 * 3600, leeway: .seconds(120))
        t.setEventHandler { [weak self] in
            guard let me = self else { return }
            me.projectsScan()
        }
        st.timer = t
        t.resume()
    }

    func projectsRoutes() {
        let s = server
        projectsStartTimer()

        s.on("GET", "/api/projects") { req, res in
            let o: [String: Any] = ProjectsState.shared.file.read(default: [String: Any]())
            let items: [[String: Any]] = ((o["items"] as? [[String: Any]]) ?? []).sorted { (($0["nom"] as? String) ?? "") < (($1["nom"] as? String) ?? "") }
            ProjectsState.shared.lock.lock(); let running: Bool = ProjectsState.shared.scanning; ProjectsState.shared.lock.unlock()
            res.json(["items": items, "last_scan": o["last_scan"] ?? "", "last_note": o["last_note"] ?? "", "running": running])
        }
        s.on("GET", "/api/projects/context") { req, res in
            let q: String = req.query["q"] ?? ""
            res.json(["q": q, "text": ProjectMemory.promptBlock(for: q)])
        }
        // Création ou mise à jour (champs fournis seulement).
        s.on("POST", "/api/projects/save") { req, res in
            let b: [String: Any] = req.json
            var items: [[String: Any]] = ProjectMemory.items()
            let id: String = (b["id"] as? String) ?? ""
            var idx: Int? = nil
            if !id.isEmpty { idx = items.firstIndex(where: { ($0["id"] as? String) == id }) }
            var p: [String: Any] = idx.map { items[$0] } ?? [:]
            if idx == nil {
                let nom: String = ((b["nom"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if nom.isEmpty { res.json(["error": "nom requis"], status: 400); return }
                p["id"] = String(UUID().uuidString.prefix(8)).lowercased()
                p["source"] = "manuel"
                for k in ["alias", "personnes", "echeances", "decisions", "documents"] { p[k] = [String]() }
                p["notes"] = ""
            }
            if let n = b["nom"] as? String, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { p["nom"] = n.trimmingCharacters(in: .whitespacesAndNewlines) }
            for k in ["alias", "personnes", "echeances", "decisions", "documents"] {
                if b[k] != nil { p[k] = ProjectMemory.strs(b[k]) }
            }
            if let n = b["notes"] as? String { p["notes"] = n }
            if let a = b["auto_off"] as? Bool { p["auto_off"] = a }
            p["maj"] = nowISO()
            if let i = idx { items[i] = p } else { items.append(p) }
            ProjectMemory.save(items)
            res.json(["ok": true, "item": p])
        }
        // Suppression : uniquement sur demande explicite de l'interface (confirmée par le Capitaine).
        s.on("POST", "/api/projects/delete") { req, res in
            let id: String = (req.json["id"] as? String) ?? ""
            let items: [[String: Any]] = ProjectMemory.items()
            let kept: [[String: Any]] = items.filter { ($0["id"] as? String) != id }
            ProjectMemory.save(kept)
            res.json(["ok": kept.count != items.count])
        }
        s.on("POST", "/api/projects/scan") { [self] req, res in
            ProjectsState.shared.queue.async { [weak self] in
                guard let me = self else { return }
                me.projectsScan()
            }
            res.json(["ok": true, "started": true])
        }
        // Ouvre un document d'un projet en arrière-plan (open -g), seulement s'il est listé dans un projet.
        s.on("POST", "/api/projects/open") { req, res in
            let path: String = (req.json["path"] as? String) ?? ""
            let listed: Bool = ProjectMemory.items().contains { ProjectMemory.strs($0["documents"]).contains(path) }
            if path.isEmpty || !listed || !FileManager.default.fileExists(atPath: path) { res.json(["ok": false, "error": "document inconnu"], status: 404); return }
            let reveal: Bool = (req.json["reveal"] as? Bool) == true
            let args: [String] = reveal ? ["-g", "-R", path] : ["-g", path]
            let r: (Int32, String) = runProcess("/usr/bin/open", args, timeout: 5)
            res.json(["ok": r.0 == 0])
        }
    }
}
