import Foundation
// MUSE-PARTOUT (26/10, ordre d'Ahadi) : defauts de ce fichier sur Muse (voir ordres dans Brains.swift).

// RÉSUMÉS DES NOUVEAUX DOCUMENTS — une ligne (2 lignes max) par document récent de /api/knowledge/recent.
// File de fond : un seul fil, un document à la fois, au plus 1 toutes les 20 s, jamais pendant une conversation
// (NovaApp.lastChatAt < 90 s), plafond quotidien `resumes_docs_max` (défaut 30). Stockage : resumes_docs.json
// [{path, mtime, resume, ts}]. Le texte envoyé au cerveau est nettoyé (lignes ressemblant à un secret masquées) et limité à 6 000 caractères.

final class ResumesDocsState: @unchecked Sendable {
    static let shared: ResumesDocsState = ResumesDocsState()
    let lock: NSLock = NSLock()
    var started: Bool = false
}

extension NovaApp {
    /// Démarre la file (une seule fois). Appelée depuis extraRoutes(), au même endroit que la route /api/knowledge/recent.
    func resumesDocsStart() {
        let st: ResumesDocsState = ResumesDocsState.shared
        st.lock.lock()
        if st.started { st.lock.unlock(); return }
        st.started = true
        st.lock.unlock()
        let th: Thread = Thread { [self] in self.resumesDocsLoop() }
        th.name = "nova.resumes-docs"
        th.qualityOfService = .utility
        th.start()
    }

    /// Ajoute `resume` aux éléments de /api/knowledge/recent quand un résumé existe pour la même version (mtime) du fichier.
    func resumesMerge(_ items: [[String: Any]]) -> [[String: Any]] {
        let all: [[String: Any]] = JSONFile("resumes_docs.json").read(default: [[String: Any]]())
        if all.isEmpty { return items }
        var map: [String: [String: Any]] = [:]
        for e in all {
            if let p: String = e["path"] as? String { map[p] = e }
        }
        var out: [[String: Any]] = []
        for it in items {
            var x: [String: Any] = it
            let p: String = (it["path"] as? String) ?? ""
            let d: String = (it["date"] as? String) ?? ""
            if let e: [String: Any] = map[p], let r: String = e["resume"] as? String, !r.isEmpty, ((e["mtime"] as? String) ?? "") == d {
                x["resume"] = r
            }
            out.append(x)
        }
        return out
    }

    /// Même liste que la route (7 jours, dossiers de connaissance, filtres Knowledge), sans toucher au cache de la route.
    func resumesListRecent() -> [[String: Any]] {
        let since: Date = Date().addingTimeInterval(-7 * 86400)
        var out: [[String: Any]] = []
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        let roots: [String] = settings.get("knowledge_roots", Knowledge.defaultRoots)
        for r in roots {
            let base: URL = URL(fileURLWithPath: (r as NSString).expandingTildeInPath)
            guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in en {
                if out.count >= 60 { break }
                let p: String = u.path
                guard Knowledge.allowedDir(p), Knowledge.allowed(p), Knowledge.exts.contains(u.pathExtension.lowercased()) else { continue }
                guard let d: Date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d > since else { continue }
                out.append(["name": u.lastPathComponent, "path": p, "date": iso.string(from: d)])
            }
        }
        out.sort { (($0["date"] as? String) ?? "") > (($1["date"] as? String) ?? "") }
        return out
    }

    func resumesDocsLoop() {
        Thread.sleep(forTimeInterval: 90)   // laisse le démarrage de Nova respirer
        let store: JSONFile = JSONFile("resumes_docs.json")
        var docs: [[String: Any]] = []
        var docsAt: Date = Date.distantPast
        var failedAt: [String: Date] = [:]
        var day: String = String(nowISO().prefix(10))
        var doneToday: Int = 0
        for e in store.read(default: [[String: Any]]()) {
            let ts: String = (e["ts"] as? String) ?? ""
            if ts.hasPrefix(day) { doneToday += 1 }
        }
        while true {
            Thread.sleep(forTimeInterval: 20)
            let now: Date = Date()
            if now.timeIntervalSince(NovaApp.lastChatAt) < 90 { continue }   // jamais pendant une conversation
            let today: String = String(nowISO().prefix(10))
            if today != day { day = today; doneToday = 0 }
            let maxPerDay: Int = settings.get("resumes_docs_max", 30)
            if doneToday >= maxPerDay { continue }
            // Liste : cache de la route s'il est frais, sinon notre propre parcours au plus toutes les 30 min (charge CPU).
            if let c: [[String: Any]] = KnowledgeRecentCache.get(now) {
                docs = c; docsAt = now
            } else if now.timeIntervalSince(docsAt) > 1800 {
                docs = resumesListRecent(); docsAt = now
            }
            let known: [[String: Any]] = store.read(default: [[String: Any]]())
            var have: Set<String> = []
            for e in known {
                let k: String = ((e["path"] as? String) ?? "") + "|" + ((e["mtime"] as? String) ?? "")
                have.insert(k)
            }
            var next: [String: Any]? = nil
            for it in docs {
                let p: String = (it["path"] as? String) ?? ""
                let m: String = (it["date"] as? String) ?? ""
                if p.isEmpty || have.contains(p + "|" + m) { continue }
                if let f: Date = failedAt[p], now.timeIntervalSince(f) < 3600 { continue }
                next = it
                break
            }
            guard let doc: [String: Any] = next else { continue }
            let path: String = (doc["path"] as? String) ?? ""
            let mtime: String = (doc["date"] as? String) ?? ""
            doneToday += 1
            guard let resume: String = resumesSummarize(path: path) else {
                failedAt[path] = Date()   // cerveau indisponible ou conversation commencée : on réessaiera plus tard
                continue
            }
            // resume vide = document illisible ou trop court : mémorisé pour ne pas le retenter.
            var l: [[String: Any]] = store.read(default: [[String: Any]]())
            l.removeAll { (($0["path"] as? String) ?? "") == path }
            let entry: [String: Any] = ["path": path, "mtime": mtime, "resume": resume, "ts": nowISO()]
            l.append(entry)
            if l.count > 400 { l.removeFirst(l.count - 400) }
            store.write(l)
        }
    }

    /// nil = échec (à retenter plus tard) ; "" = document sans texte exploitable.
    func resumesSummarize(path: String) -> String? {
        guard let raw: String = Knowledge.readText(path) else { return "" }
        let scrubbed: (String, Int) = Knowledge.scrub(raw)
        let trimmed: String = scrubbed.0.trimmingCharacters(in: .whitespacesAndNewlines)
        let txt: String = String(trimmed.prefix(6000))
        if txt.count < 40 { return "" }
        let name: String = (path as NSString).lastPathComponent
        let sys: String = "Tu résumes des documents pour Ahadi. Réponds en français, en 2 lignes maximum (40 mots environ), sans introduction, sans puces, sans markdown. N'invente rien : uniquement ce qui figure dans le texte."
        let user: String = "Document : " + name + "\n\n" + txt
        let started: Date = Date()
        let lock: NSLock = NSLock()
        var out: String = ""
        let id: String? = router.chat(messages: [ChatMsg("user", user)], system: sys, mode: "fast", preferred: "spark-1.3", maxTokens: 120,
                                      cancel: { NovaApp.lastChatAt > started }) { (ev: BrainEvent) in
            switch ev {
            case .delta(let d):
                lock.lock(); out += d; lock.unlock()
            case .failover:
                lock.lock(); out = ""; lock.unlock()   // le cerveau suivant repart de zéro
            default:
                break
            }
        }
        if id == nil { return nil }
        lock.lock()
        let rawOut: String = out
        lock.unlock()
        var lines: [String] = []
        for ln in rawOut.components(separatedBy: "\n") {
            let t: String = ln.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { lines.append(t) }
            if lines.count >= 2 { break }
        }
        let joined: String = lines.joined(separator: " ")
        if joined.isEmpty { return nil }
        return String(joined.prefix(320))
    }
}
