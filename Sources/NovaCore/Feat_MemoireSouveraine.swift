import Foundation

// VAGUE 1 (24/10/2026) — Mémoire souveraine — provenance, édition, versions, export, incognito.
//
// - PROVENANCE : chaque réponse du chat sait quels faits (mémoire, profil) et quels rappels de
//   conversation ont été injectés ; événement SSE « memory » avant « done », persisté sur le
//   message assistant (clé « memory »).
// - OUBLI RÉEL : Memory.forget efface le fait, son vecteur, le texte de ses versions (journal +
//   instantanés) et ses copies de provenance (Conversations.stripMemoryRef).
// - VERSIONS : MemoryLedger — journal append-only memoire_journal.jsonl (qui/quand/quoi/pourquoi)
//   + instantané quotidien memoire_versions/AAAA-MM-JJ.json (état du jour, réécrit à chaque écriture).
//   Seul l'oubli réécrit le journal : il en retire le texte du fait oublié.
// - EXPORT/IMPORT lisibles (Markdown + JSON), import avec aperçu et fusion dédoublonnée.
// - HORS MÉMOIRE : drapeau « incognito » par conversation — contexte utilisé, rien retenu.

/// Journal des versions de la mémoire. Toutes les écritures disque passent par une file série.
public enum MemoryLedger {
    static let q = DispatchQueue(label: "nova.memoire.versions", qos: .utility)
    static var journalURL: URL { Paths.file("memoire_journal.jsonl") }
    static var versionsDir: URL { Paths.file("memoire_versions") }

    static func day() -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    /// Qui a écrit, d'après la source du fait.
    public static func actorFor(_ source: String) -> String {
        let s: String = source.lowercased()
        if s.hasPrefix("extraction") { return "distillateur" }
        if s == "assistant" { return "Nova (outil)" }
        if s.hasPrefix("import") { return "import" }
        if s.isEmpty || s == "utilisateur" || s == "décision" { return "Ahadi" }
        return source
    }

    /// Ajoute une version (asynchrone, ordonnée) et réécrit l'instantané du jour si `all` est fourni.
    static func record(op: String, id: String, text: String?, prev: String? = nil, actor: String, source: String = "", why: String = "", cid: String = "", all: [[String: Any]]?) {
        var e: [String: Any] = ["v": String(UUID().uuidString.prefix(8)).lowercased(), "ts": nowISO(), "op": op, "id": id, "actor": actor]
        if let t = text { e["text"] = t }
        if let p = prev { e["prev"] = p }
        if !source.isEmpty { e["source"] = source }
        if !why.isEmpty { e["why"] = why }
        if !cid.isEmpty { e["cid"] = cid }
        let snap: [[String: Any]]? = all
        let ev: [String: Any] = e
        MemoryLedger.q.async {
            MemoryLedger.appendLine(ev)
            if let a = snap { MemoryLedger.writeSnapshot(a) }
        }
    }

    /// À appeler DEPUIS la file q uniquement.
    static func appendLine(_ e: [String: Any]) {
        let line: Data = jsonData(e) + Data("\n".utf8)
        let u: URL = journalURL
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: u) }
    }

    /// À appeler DEPUIS la file q uniquement.
    static func writeSnapshot(_ all: [[String: Any]]) {
        let dir: URL = versionsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? jsonData(all).write(to: dir.appendingPathComponent(day() + ".json"), options: .atomic)
    }

    /// À appeler DEPUIS la file q uniquement.
    static func readEntries() -> [[String: Any]] {
        guard let s = try? String(contentsOf: journalURL, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { parseJSON(Data($0.utf8)) }
    }

    /// Versions d'un fait, de la plus récente à la plus ancienne.
    public static func history(_ id: String) -> [[String: Any]] {
        let all: [[String: Any]] = q.sync { readEntries() }
        return Array(all.filter { ($0["id"] as? String) == id }.reversed())
    }

    /// Nombre de versions par fait (pour l'écran Savoir).
    static func versionCounts() -> [String: Int] {
        let all: [[String: Any]] = q.sync { readEntries() }
        var out: [String: Int] = [:]
        for e in all {
            guard let id = e["id"] as? String, !id.isEmpty else { continue }
            out[id, default: 0] += 1
        }
        return out
    }

    static func journalCount() -> Int { q.sync { readEntries().count } }

    static func snapshotDays() -> [String] {
        let files: [String] = (try? FileManager.default.contentsOfDirectory(atPath: versionsDir.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted(by: >)
    }

    /// Oubli réel : retire le texte du fait de toutes ses versions et de tous les instantanés,
    /// puis pose une trace sans texte. Retourne les textes retirés (pour vider le cache de vecteurs).
    static func purge(id: String, actor: String, why: String, all: [[String: Any]]) -> [String] {
        return q.sync { () -> [String] in
            var texts: [String] = []
            if let s = try? String(contentsOf: journalURL, encoding: .utf8) {
                var out: [String] = []
                var changed: Bool = false
                for line in s.split(separator: "\n") {
                    guard var e = parseJSON(Data(line.utf8)) else { out.append(String(line)); continue }
                    if (e["id"] as? String) == id && (e["text"] != nil || e["prev"] != nil) {
                        if let t = e["text"] as? String { texts.append(t) }
                        if let p = e["prev"] as? String { texts.append(p) }
                        e.removeValue(forKey: "text"); e.removeValue(forKey: "prev"); e["efface"] = true
                        changed = true
                        out.append(jsonString(e))
                    } else {
                        out.append(String(line))
                    }
                }
                if changed { try? Data((out.joined(separator: "\n") + "\n").utf8).write(to: journalURL, options: .atomic) }
            }
            let dir: URL = versionsDir
            let files: [String] = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for fn in files where fn.hasSuffix(".json") {
                let u: URL = dir.appendingPathComponent(fn)
                guard let d = try? Data(contentsOf: u), let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { continue }
                let kept: [[String: Any]] = arr.filter { ($0["id"] as? String) != id }
                if kept.count != arr.count { try? jsonData(kept).write(to: u, options: .atomic) }
            }
            var tomb: [String: Any] = ["v": String(UUID().uuidString.prefix(8)).lowercased(), "ts": nowISO(), "op": "forget", "id": id, "actor": actor]
            if !why.isEmpty { tomb["why"] = why }
            appendLine(tomb)
            writeSnapshot(all)
            return texts
        }
    }

    // MARK: Hors mémoire

    static let incLock = NSLock()
    nonisolated(unsafe) static var incCount: Int = 0
    static func beginIncognito() { incLock.lock(); incCount += 1; incLock.unlock() }
    static func endIncognito() { incLock.lock(); incCount = max(0, incCount - 1); incLock.unlock() }
    /// Vrai pendant un tour « Hors mémoire » : l'outil « retenir » de l'assistant n'écrit rien.
    public static func incognitoActive() -> Bool { incLock.lock(); defer { incLock.unlock() }; return incCount > 0 }

    /// Le drapeau vit sur la conversation (clé « incognito » de conversations.json).
    public static func isIncognito(_ cid: String) -> Bool {
        if cid.isEmpty { return false }
        let d: [String: Any] = JSONFile("conversations.json").read(default: [String: Any]())
        return ((d[cid] as? [String: Any])?["incognito"] as? Bool) ?? false
    }

    // MARK: Provenance

    static func provenance(mem: [[String: Any]], profile: [[String: Any]], recall: [[String: Any]], incognito: Bool) -> [String: Any] {
        var items: [[String: Any]] = []
        func push(_ m: [String: Any], _ kind: String) {
            let t: String = (m["text"] as? String) ?? ""
            if t.isEmpty { return }
            var e: [String: Any] = ["id": (m["id"] as? String) ?? "", "kind": kind, "text": Conversations.oneLine(t, 160),
                                    "ts": String(((m["ts"] as? String) ?? "").prefix(10))]
            if let s = m["source"] as? String, !s.isEmpty { e["source"] = s }
            if (m["locked"] as? Bool) == true { e["locked"] = true }
            items.append(e)
        }
        for m in mem { push(m, "memoire") }
        for m in profile { push(m, "profil") }
        for r in recall { items.append(r) }
        return ["items": items, "count": items.count, "incognito": incognito, "ts": nowISO()]
    }

    // MARK: Recherche, export, import

    static func fold(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
    }

    static func exportJSON(memory: Memory, settings: Settings) -> [String: Any] {
        let items: [[String: Any]] = memory.list()
        let full: String = settings.get("full_name", "Ahadi Jean Cyrille Dahani")
        let usage: String = settings.get("name", "Ahadi")
        let titre: String = settings.get("user_title", "Capitaine")
        let ville: String = settings.get("city", "Ouagadougou")
        let bloc: String = NovaSoul.profileBlock(memory: nil)
        let profil: [String: Any] = ["nom_complet": full, "prenom_usage": usage, "titre": titre, "ville": ville, "bloc_profil": bloc]
        return ["format": "nova-memoire", "version": 1, "exported": nowISO(), "compte": items.count,
                "profil": profil, "faits": items, "reglages": memory.settings(),
                "items": items, "settings": memory.settings()]   // clés historiques de GET /api/memory/export
    }

    static func exportMarkdown(memory: Memory, settings: Settings) -> String {
        let items: [[String: Any]] = memory.list()
        let full: String = settings.get("full_name", "Ahadi Jean Cyrille Dahani")
        var s: String = "# Mémoire de Nova — " + full + "\n\n"
        s += "Export du " + String(nowISO().prefix(10)) + " · \(items.count) fait(s). Fichier lisible, sans clé ni secret ; réimportable via le JSON jumeau.\n\n"
        s += "## Profil (stable)\n\n" + NovaSoul.profileBlock(memory: nil) + "\n\n"
        func line(_ m: [String: Any]) -> String {
            var meta: [String] = []
            let ts: String = String(((m["ts"] as? String) ?? "").prefix(10))
            if !ts.isEmpty { meta.append(ts) }
            meta.append(actorFor((m["source"] as? String) ?? ""))
            if (m["locked"] as? Bool) == true { meta.append("verrouillé") }
            if let id = m["id"] as? String { meta.append("id " + id) }
            let t: String = ((m["text"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ")
            return "- " + t + " — _" + meta.joined(separator: " · ") + "_"
        }
        let prof: [[String: Any]] = items.filter { ($0["kind"] as? String) == "profil" && ($0["forgiven"] as? Bool) != true }
        let ctxs: [[String: Any]] = items.filter { ($0["kind"] as? String) != "profil" && ($0["forgiven"] as? Bool) != true }
        let forg: [[String: Any]] = items.filter { ($0["forgiven"] as? Bool) == true }
        s += "## Faits de profil retenus (\(prof.count))\n\n" + (prof.isEmpty ? "_Aucun._" : prof.map(line).joined(separator: "\n")) + "\n\n"
        s += "## Faits de contexte (\(ctxs.count))\n\n" + (ctxs.isEmpty ? "_Aucun._" : ctxs.map(line).joined(separator: "\n")) + "\n"
        if !forg.isEmpty { s += "\n## Exclus du contexte (ancien Pardon) (\(forg.count))\n\n" + forg.map(line).joined(separator: "\n") + "\n" }
        return s
    }

    /// Candidats d'import : export Nova ({faits}), ancien export ({items}), tableau de textes ou d'objets.
    static func importCandidates(_ raw: Any?) -> [[String: Any]] {
        var root: Any? = raw
        if let s = raw as? String, let d = s.data(using: .utf8) { root = try? JSONSerialization.jsonObject(with: d) }
        var arr: [Any] = []
        if let a = root as? [Any] { arr = a }
        else if let o = root as? [String: Any] { arr = (o["faits"] as? [Any]) ?? (o["items"] as? [Any]) ?? (o["memoire"] as? [Any]) ?? [] }
        var out: [[String: Any]] = []
        for x in arr.prefix(2000) {
            if let s = x as? String { out.append(["text": s]); continue }
            guard let d = x as? [String: Any] else { out.append(["text": ""]); continue }
            let t: String = (d["text"] as? String) ?? (d["texte"] as? String) ?? (d["fait"] as? String) ?? ""
            var c: [String: Any] = ["text": t]
            if let k = d["kind"] as? String { c["kind"] = k } else if let k = d["type"] as? String { c["kind"] = k }
            if let so = d["source"] as? String { c["source"] = so }
            if let ts = d["ts"] as? String { c["ts"] = ts }
            if (d["locked"] as? Bool) == true { c["locked"] = true }
            if (d["forgiven"] as? Bool) == true { c["forgiven"] = true }
            out.append(c)
        }
        return out
    }
}

/// Provenance d'un tour de chat, remplie par les tâches parallèles d'assemblage du contexte.
final class MemoryProvBox: @unchecked Sendable {
    private let lock = NSLock()
    private var mem: [[String: Any]] = []
    private var rec: [[String: Any]] = []
    func setMem(_ l: [[String: Any]]) { lock.lock(); mem = l; lock.unlock() }
    func setRecall(_ l: [[String: Any]]) { lock.lock(); rec = l; lock.unlock() }
    func memItems() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return mem }
    func recallItems() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return rec }
}

extension Conversations {
    /// Bascule « Hors mémoire » d'un fil. false si le fil n'existe pas.
    @discardableResult func setIncognito(_ id: String, _ on: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var d = load(); guard var c = d[id] as? [String: Any] else { return false }
        if on { c["incognito"] = true; c["incognito_since"] = nowISO() }
        else { c.removeValue(forKey: "incognito"); c.removeValue(forKey: "incognito_since") }
        d[id] = c; f.write(d); return true
    }
    func isIncognito(_ id: String) -> Bool { (get(id)?["incognito"] as? Bool) ?? false }
    /// Pose la provenance sur le DERNIER message assistant du fil (celui du checkpoint final).
    @discardableResult func attachMemory(_ id: String, _ prov: [String: Any]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var d = load(); guard var c = d[id] as? [String: Any] else { return false }
        var m = (c["messages"] as? [[String: Any]]) ?? []
        guard let i = m.lastIndex(where: { ($0["role"] as? String) == "assistant" }) else { return false }
        m[i]["memory"] = prov; c["messages"] = m; d[id] = c; f.write(d)
        return true
    }
    /// Oubli réel : retire un fait de toutes les provenances persistées. Retourne le nombre de copies retirées.
    @discardableResult func stripMemoryRef(_ factId: String) -> Int {
        if factId.isEmpty { return 0 }
        lock.lock(); defer { lock.unlock() }
        var d = load(); var n: Int = 0
        for (k, v) in d {
            guard var c = v as? [String: Any], var m = c["messages"] as? [[String: Any]] else { continue }
            var changed: Bool = false
            for i in m.indices {
                guard var pv = m[i]["memory"] as? [String: Any], let items = pv["items"] as? [[String: Any]] else { continue }
                let kept: [[String: Any]] = items.filter { (($0["id"] as? String) ?? "") != factId || (($0["kind"] as? String) ?? "") == "rappel" }
                if kept.count == items.count { continue }
                let gone: Int = items.count - kept.count
                pv["items"] = kept; pv["count"] = kept.count; pv["forgotten"] = ((pv["forgotten"] as? Int) ?? 0) + gone
                m[i]["memory"] = pv; changed = true; n += gone
            }
            if changed { c["messages"] = m; d[k] = c }
        }
        if n > 0 { f.write(d) }
        return n
    }
}

extension NovaApp {
    /// Conversations réellement rappelées par recallBlock (même sélection : 3 fils récents non vides).
    func recallProvenance(excluding cid: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        let recent: [[String: Any]] = convs.list().filter { ($0["id"] as? String) != cid }
        for c in recent.prefix(3) {
            guard let id = c["id"] as? String, let full = convs.get(id) else { continue }
            let msgs: [[String: Any]] = (full["messages"] as? [[String: Any]]) ?? []
            let userMsg: [String: Any]? = msgs.last(where: { ($0["role"] as? String) == "user" })
            let botMsg: [String: Any]? = msgs.last(where: { ($0["role"] as? String) == "assistant" && ($0["partial"] as? Bool) != true })
            let lu: String = (userMsg?["content"] as? String) ?? ""
            let la: String = (botMsg?["content"] as? String) ?? ""
            if lu.isEmpty && la.isEmpty { continue }
            let title: String = (c["title"] as? String) ?? "Conversation"
            out.append(["id": id, "kind": "rappel", "text": Conversations.oneLine(title, 80),
                        "ts": String(((c["updated"] as? String) ?? "").prefix(10)), "source": "conversation"])
        }
        return out
    }

    func sovereignMemoryRoutes() {
        let s = server
        let mem: Memory = memory
        let cv: Conversations = convs
        let st: Settings = settings
        Memory.onForget = { id in _ = cv.stripMemoryRef(id) }

        // Liste filtrée : q (texte, sans accents), origine, kind, locked=1, forgiven=1, since/until (AAAA-MM-JJ).
        s.on("GET", "/api/memory/facts") { req, res in
            let all: [[String: Any]] = mem.list()
            let counts: [String: Int] = MemoryLedger.versionCounts()
            let words: [String] = MemoryLedger.fold(req.query["q"] ?? "").split(separator: " ").map { String($0) }.filter { !$0.isEmpty }
            let origine: String = req.query["origine"] ?? req.query["source"] ?? ""
            let kind: String = req.query["kind"] ?? ""
            let onlyLocked: Bool = req.query["locked"] == "1"
            let onlyForgiven: Bool = req.query["forgiven"] == "1"
            let since: String = req.query["since"] ?? ""
            let until: String = req.query["until"] ?? ""
            var out: [[String: Any]] = []
            var origines = Set<String>()
            for m in all {
                var e: [String: Any] = m
                let org: String = MemoryLedger.actorFor((m["source"] as? String) ?? "")
                origines.insert(org)
                let text: String = (m["text"] as? String) ?? ""
                if !words.isEmpty {
                    let ft: String = MemoryLedger.fold(text)
                    if !words.allSatisfy({ ft.contains($0) }) { continue }
                }
                if !origine.isEmpty && org != origine { continue }
                let k: String = (m["kind"] as? String) == "profil" ? "profil" : "contexte"
                if !kind.isEmpty && k != kind { continue }
                if onlyLocked && (m["locked"] as? Bool) != true { continue }
                if onlyForgiven && (m["forgiven"] as? Bool) != true { continue }
                let day: String = String(((m["ts"] as? String) ?? "").prefix(10))
                if !since.isEmpty && day < since { continue }
                if !until.isEmpty && day > until { continue }
                e["origine"] = org
                e["kind"] = k
                e["versions"] = counts[(m["id"] as? String) ?? ""] ?? 0
                out.append(e)
            }
            out.sort { (($0["ts"] as? String) ?? "") > (($1["ts"] as? String) ?? "") }
            let total: Int = all.count
            let prof: Int = all.filter { ($0["kind"] as? String) == "profil" }.count
            let locked: Int = all.filter { ($0["locked"] as? Bool) == true }.count
            let forgiven: Int = all.filter { ($0["forgiven"] as? Bool) == true }.count
            let shown: [[String: Any]] = Array(out.prefix(1000))
            res.json(["items": shown, "matched": out.count, "shown": shown.count,
                      "counts": ["total": total, "profil": prof, "contexte": total - prof, "verrouilles": locked, "exclus": forgiven,
                                 "injectables": total - forgiven, "versions": MemoryLedger.journalCount(), "jours_instantanes": MemoryLedger.snapshotDays().count],
                      "origines": Array(origines).sorted(), "off": mem.isOff])
        }

        // Édition : texte (vecteur recalculé) et/ou verrou.
        s.on("POST", "/api/memory/fact/update") { req, res in
            let j = req.json
            let id: String = (j["id"] as? String) ?? ""
            guard mem.list().contains(where: { ($0["id"] as? String) == id }) else { res.json(["ok": false, "error": "fait introuvable"], status: 404); return }
            let why: String = (j["why"] as? String) ?? "correction d'Ahadi"
            if let t = j["text"] as? String {
                let tt: String = t.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tt.isEmpty, tt.count <= 2000 else { res.json(["ok": false, "error": "texte vide ou trop long (2 000 caractères au plus)"], status: 400); return }
                guard mem.update(id, text: tt, actor: "Ahadi", why: why) else { res.json(["ok": false, "error": "correction impossible"], status: 409); return }
            }
            if let lk = j["locked"] as? Bool { _ = mem.setLocked(id, lk) }
            let item: [String: Any]? = mem.list().first(where: { ($0["id"] as? String) == id })
            res.json(["ok": true, "item": (item as Any?) ?? NSNull()])
        }

        // Oubli réel, confirmé. Un fait verrouillé se déverrouille d'abord.
        s.on("POST", "/api/memory/fact/forget") { req, res in
            let j = req.json
            let id: String = (j["id"] as? String) ?? ""
            guard let item = mem.list().first(where: { ($0["id"] as? String) == id }) else { res.json(["ok": false, "error": "fait introuvable (déjà oublié ?)"], status: 404); return }
            guard (j["confirm"] as? Bool) == true else {
                res.json(["ok": false, "need_confirm": true, "text": (item["text"] as? String) ?? "", "error": "confirmation requise : l'oubli est définitif (fait, vecteur, versions et copies de provenance)"], status: 400); return
            }
            if (item["locked"] as? Bool) == true { res.json(["ok": false, "error": "fait verrouillé — déverrouille-le d'abord"], status: 409); return }
            let ok: Bool = mem.forget(id, actor: "Ahadi", why: (j["why"] as? String) ?? "oubli demandé par Ahadi")
            _ = BlackBox.record(["tool": "memoire", "actor": "Ahadi", "why": "oubli réel d'un fait (id " + id + ") : donnée, vecteur, versions et provenances effacés", "ok": ok, "effect": "suppression"])
            res.json(["ok": ok, "forgotten": ok])
        }

        s.on("GET", "/api/memory/fact/history") { req, res in
            let id: String = req.query["id"] ?? ""
            guard !id.isEmpty else { res.json(["error": "id manquant"], status: 400); return }
            let cur: [String: Any]? = mem.list().first(where: { ($0["id"] as? String) == id })
            res.json(["id": id, "current": (cur as Any?) ?? NSNull(), "versions": MemoryLedger.history(id)])
        }

        s.on("POST", "/api/memory/fact/restore") { req, res in
            let j = req.json
            let id: String = (j["id"] as? String) ?? ""
            let v: String = (j["v"] as? String) ?? ""
            guard mem.list().contains(where: { ($0["id"] as? String) == id }) else { res.json(["ok": false, "error": "fait oublié ou introuvable : ses versions ont été effacées avec lui"], status: 404); return }
            guard let e = MemoryLedger.history(id).first(where: { ($0["v"] as? String) == v }), let t = e["text"] as? String, !t.isEmpty else {
                res.json(["ok": false, "error": "version introuvable ou sans texte"], status: 404); return
            }
            let when: String = String(((e["ts"] as? String) ?? "").prefix(16)).replacingOccurrences(of: "T", with: " ")
            let ok: Bool = mem.update(id, text: t, actor: "Ahadi", why: "restauration de la version du " + when, op: "restore")
            res.json(["ok": ok, "text": t], status: ok ? 200 : 409)
        }

        // Export : sans format → forme historique (JSON) ; format=md|json → {filename, mime, content} ; &download=1 → fichier brut.
        s.on("GET", "/api/memory/export") { req, res in
            let fmt: String = (req.query["format"] ?? "").lowercased()
            let obj: [String: Any] = MemoryLedger.exportJSON(memory: mem, settings: st)
            if fmt.isEmpty { res.json(obj); return }
            let day: String = String(nowISO().prefix(10))
            let isMD: Bool = fmt == "md" || fmt == "markdown"
            let content: String
            if isMD { content = MemoryLedger.exportMarkdown(memory: mem, settings: st) }
            else {
                let d: Data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? jsonData(obj)
                content = String(data: d, encoding: .utf8) ?? "{}"
            }
            let fn: String = "nova-memoire-" + day + (isMD ? ".md" : ".json")
            let mime: String = isMD ? "text/markdown; charset=utf-8" : "application/json; charset=utf-8"
            if req.query["download"] == "1" {
                res.data(Data(content.utf8), type: mime, extra: ["Content-Disposition": "attachment; filename=\"" + fn + "\""]); return
            }
            res.json(["ok": true, "filename": fn, "mime": mime, "content": content, "count": (obj["compte"] as? Int) ?? 0])
        }

        // Import JSON : {data, apply:false} → aperçu ; {data, apply:true} → fusion dédoublonnée.
        s.on("POST", "/api/memory/import") { req, res in
            let j = req.json
            let cands: [[String: Any]] = MemoryLedger.importCandidates(j["data"])
            guard !cands.isEmpty else { res.json(["ok": false, "error": "aucun fait lisible : JSON attendu (export Nova {faits:[…]}, {items:[…]} ou tableau)"], status: 400); return }
            if mem.isOff { res.json(["ok": false, "error": "mémoire coupée (réglage « sans mémoire ») : rien ne peut être importé"], status: 409); return }
            var pool: [[String: Any]] = mem.list()
            var nouveaux: [[String: Any]] = []
            var doublons: [String] = []
            var refuses: [[String: Any]] = []
            var invalides: Int = 0
            for c in cands {
                let t: String = ((c["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count < 3 || t.count > 2000 { invalides += 1; continue }
                if MemoryDistiller.isPrivate(t) { refuses.append(["text": Conversations.oneLine(t, 120), "raison": "ressemble à un secret ou un identifiant"]); continue }
                if (c["forgiven"] as? Bool) == true { refuses.append(["text": Conversations.oneLine(t, 120), "raison": "exclu du contexte dans la source"]); continue }
                if Memory.isNearDuplicate(t, in: pool) { doublons.append(Conversations.oneLine(t, 120)); continue }
                var n: [String: Any] = c; n["text"] = t
                nouveaux.append(n); pool.append(["text": t])
            }
            let apply: Bool = (j["apply"] as? Bool) == true
            var added: Int = 0
            if apply {
                for n in nouveaux {
                    let src0: String = (n["source"] as? String) ?? ""
                    let ts0: String = (n["ts"] as? String) ?? ""
                    let tsOK: String = ISO8601DateFormatter().date(from: ts0) != nil ? ts0 : ""
                    if mem.importFact((n["text"] as? String) ?? "", kind: (n["kind"] as? String) ?? "", source: src0.isEmpty ? "import" : "import · " + src0, ts: tsOK, locked: (n["locked"] as? Bool) == true) != nil { added += 1 }
                }
                _ = BlackBox.record(["tool": "memoire", "actor": "Ahadi", "why": "import de mémoire : \(added) fait(s) ajouté(s), \(doublons.count) doublon(s) écarté(s), \(refuses.count) refusé(s)", "ok": true, "effect": "écriture"])
            }
            var apercu: [[String: Any]] = []
            for n in nouveaux.prefix(300) {
                let nt: String = Conversations.oneLine((n["text"] as? String) ?? "", 200)
                let nk: String = (n["kind"] as? String) ?? ""
                apercu.append(["text": nt, "kind": nk])
            }
            res.json(["ok": true, "applied": apply, "added": added, "lus": cands.count,
                      "nouveaux": apercu,
                      "nouveaux_n": nouveaux.count, "doublons": Array(doublons.prefix(100)), "doublons_n": doublons.count,
                      "refuses": Array(refuses.prefix(100)), "invalides": invalides])
        }

        // Hors mémoire, par conversation.
        s.on("POST", "/api/conversation/incognito") { req, res in
            let j = req.json
            let cid: String = (j["cid"] as? String) ?? (j["conversation_id"] as? String) ?? ""
            let on: Bool = (j["on"] as? Bool) ?? true
            guard !cid.isEmpty else { res.json(["ok": false, "error": "cid manquant"], status: 400); return }
            guard cv.setIncognito(cid, on) else { res.json(["ok": false, "error": "conversation introuvable"], status: 404); return }
            res.json(["ok": true, "cid": cid, "on": on])
        }
    }
}
