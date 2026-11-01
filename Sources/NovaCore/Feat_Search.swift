import Foundation

/// « Partout » (palette ⌘K) : recherche universelle en parallèle sur les conversations, la mémoire, les Dots (et leurs rapports),
/// les brouillons, les instantanés mails/Teams déjà en mémoire (WebMail) et les fichiers (Spotlight, lecture seule).
/// + « Annuler » : liste légère des actions réversibles récentes pour le toast de l'interface (l'annulation passe par POST /api/actions/undo).
/// Rien n'est envoyé ni supprimé ici ; seule action visible : POST /api/search/reveal (clic explicite de l'utilisateur → Finder).

final class SearchBucket: @unchecked Sendable {
    let lock: NSLock = NSLock()
    var open: Bool = true
    var bySource: [String: [[String: Any]]] = [:]
    func put(_ src: String, _ items: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        if open { bySource[src] = items }
    }
    func close() -> [String: [[String: Any]]] {
        lock.lock(); defer { lock.unlock() }
        open = false
        return bySource
    }
}

private let srchOpts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

private func srchMatch(_ text: String, _ words: [String]) -> Bool {
    if words.isEmpty || text.isEmpty { return false }
    for w in words {
        if text.range(of: w, options: srchOpts) == nil { return false }
    }
    return true
}

private func srchSnippet(_ text: String, _ word: String, radius: Int = 70) -> String {
    let flat: String = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
    guard !word.isEmpty, let r = flat.range(of: word, options: srchOpts) else {
        let head: String = String(flat.prefix(radius * 2))
        return flat.count > radius * 2 ? head + "…" : head
    }
    let before: Int = flat.distance(from: flat.startIndex, to: r.lowerBound)
    let startOff: Int = max(0, before - radius)
    let start: String.Index = flat.index(flat.startIndex, offsetBy: startOff)
    let end: String.Index = flat.index(r.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
    var s: String = String(flat[start..<end])
    if startOff > 0 { s = "…" + s }
    if end < flat.endIndex { s = s + "…" }
    return s
}

private func srchItem(_ source: String, _ title: String, _ snippet: String, _ action: [String: Any], ts: String = "") -> [String: Any] {
    let t: String = String(title.replacingOccurrences(of: "\n", with: " ").prefix(120))
    var o: [String: Any] = ["source": source, "title": t.isEmpty ? "(sans titre)" : t, "snippet": String(snippet.prefix(220)), "action": action]
    if !ts.isEmpty { o["ts"] = ts }
    return o
}

extension NovaApp {
    func searchUndoRoutes() {
        let s = server

        s.on("GET", "/api/search/all") { [self] req, res in
            let raw: String = (req.query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let q: String = String(raw.prefix(120))
            let words: [String] = q.split(separator: " ").map { String($0) }.filter { $0.count >= 2 }
            if words.isEmpty {
                let empty: [String: Any] = ["q": q, "items": [Any](), "sources": [String: Int](), "late": [String]()]
                res.json(empty)
                return
            }
            let t0: Date = Date()
            let bucket: SearchBucket = SearchBucket()
            let g: DispatchGroup = DispatchGroup()
            let order: [String] = ["conversations", "memoire", "dots", "brouillons", "mails", "fichiers"]
            let jobs: [String: () -> [[String: Any]]] = [
                "conversations": { self.srchConversations(words) },
                "memoire": { self.srchMemory(q, words) },
                "dots": { self.srchDots(words) },
                "brouillons": { self.srchDrafts(words) },
                "mails": { self.srchMails(words) },
                "fichiers": { self.srchFiles(q) },
            ]
            for name in order {
                guard let job = jobs[name] else { continue }
                g.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let r: [[String: Any]] = job()
                    bucket.put(name, r)
                    g.leave()
                }
            }
            _ = g.wait(timeout: .now() + 3.0)   // délai maximal : une source lente est simplement absente (« late »)
            let got: [String: [[String: Any]]] = bucket.close()
            var items: [[String: Any]] = []
            var counts: [String: Int] = [:]
            var late: [String] = []
            for name in order {
                guard let l = got[name] else { late.append(name); continue }
                counts[name] = l.count
                for it in l where items.count < 40 { items.append(it) }
            }
            let ms: Int = Int(Date().timeIntervalSince(t0) * 1000)
            let body: [String: Any] = ["q": q, "items": items, "sources": counts, "late": late, "ms": ms]
            res.json(body)
        }

        // ALGOLIA (23/10) : config de la recherche d'index de la palette ⌘K, servie au web par le
        // canal magasin. Trousseau d'abord (KnownKeys.algoliaApp / algoliaSearch), repli fichier
        // algolia_config.json du magasin. Seuls l'app_id et la clé de RECHERCHE sont servis ;
        // la clé Admin n'existe pas côté app et ne transite jamais ici.
        s.on("GET", "/api/search/algolia-config") { [self] _, res in
            let f: [String: Any] = JSONFile("algolia_config.json").read(default: [String: Any]())
            var appId: String = (f["app_id"] as? String) ?? ""
            var searchKey: String = (f["search_key"] as? String) ?? ""
            let index: String = (f["index"] as? String) ?? "nova"
            if let v = keys.value(KnownKeys.algoliaApp), !v.isEmpty { appId = v }
            if let v = keys.value(KnownKeys.algoliaSearch), !v.isEmpty { searchKey = v }
            res.json(["app_id": appId, "search_key": searchKey, "index": index, "configured": !appId.isEmpty && !searchKey.isEmpty])
        }

        // 31/10 (biblio 2) : palette ⌘K → bibliothèque Nova (nova-bibliotheque : Mac + bibliothèques), côté moteur :
        // la clé ne quitte jamais Swift. q = texte, k ≤ 30. Ouverture : seulement un chemin indexé (open / open -R).
        s.on("GET", "/api/search/bibliotheque") { req, res in
            let q: String = String((req.query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            let k: Int = max(1, min(30, Int(req.query["k"] ?? "") ?? 20))
            if q.isEmpty { res.json(["ok": true, "hits": [Any]()]); return }
            let r = AlgoliaBiblio.smartSearch(q, source: "", k: k)   // 31/10 (biblio 4) : requête nettoyée, reclassement nom de fichier d'abord, copies regroupées
            let pal: [String: Any] = ["generated": nowISO(), "longueur_requete": q.count, "ok": r.hits != nil, "erreur": r.err, "nb_hits": r.hits?.count ?? -1, "requetes_algolia": r.tries]   // 31/10 (biblio 2) : diag palette (jamais la requête)
            try? jsonData(pal).write(to: URL(fileURLWithPath: AlgoliaBiblio.diagDir + "/biblio_palette.json"))
            guard let hits = r.hits else { res.json(["ok": false, "erreur": r.err]); return }
            let out: [[String: Any]] = hits.map { (h: [String: Any]) -> [String: Any] in
                let snip: String = (((h["_snippetResult"] as? [String: Any])?["text"] as? [String: Any])?["value"] as? String) ?? ""
                return ["id": (h["objectID"] as? String) ?? "", "title": (h["title"] as? String) ?? "(sans titre)",
                        "chemin": (h["chemin"] as? String) ?? "", "source": (h["source"] as? String) ?? "",
                        "date": (h["date"] as? String) ?? "", "type": (h["type"] as? String) ?? "",
                        "dossier": AlgoliaBiblio.display((h["dossier"] as? String) ?? ""), "copies": (h["copies"] as? Int) ?? 1,
                        "formats": (h["formats"] as? [String]) ?? [String](), "genere": (h["genere"] as? Bool) ?? false,
                        "extrait": AlgoliaBiblio.stripTags(snip).replacingOccurrences(of: "\n", with: " ")]
            }
            res.json(["ok": true, "hits": out])
        }
        s.on("POST", "/api/bibliotheque/ouvrir") { req, res in
            let j: [String: Any] = req.json
            let r = AlgoliaBiblio.openIndexed((j["chemin"] as? String) ?? "", reveal: (j["reveal"] as? Bool) == true)
            res.json(["ok": r.ok, "message": r.msg], status: r.ok ? 200 : 404)
        }
        // Mémoire sémantique de la palette ⌘K — version hackathon Meta : AUCUN service d'embedding tiers.
        // Relais Algolia (recherche plein texte, pas un modèle), puis copie locale (index vectoriel sur le Mac).
        s.on("GET", "/api/search/pinecone-config") { _, res in
            res.json(["configured": false, "enabled": false, "circuit_open": false, "index": "", "note": "retiré de la version Meta"])
        }
        s.on("POST", "/api/search/semantic") { req, res in
            let q: String = String(((req.json["q"] as? String) ?? "").prefix(300))
            if q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                res.json(["configured": true, "degraded": true, "reason": "empty_query", "hits": [Any]()]); return
            }
            if let al = AlgoliaRelay.search(q, k: 5) {
                res.json(["configured": true, "degraded": false, "fallback": "algolia", "provider": "algolia", "hits": al]); return
            }
            if let local = Credits.localSemanticSearch(q, k: 5) {
                res.json(["configured": true, "degraded": false, "fallback": "local", "provider": "local", "hits": local]); return
            }
            res.json(["configured": false, "degraded": true, "reason": "aucun index", "hits": [Any]()])
        }

        // Révèle un fichier dans le Finder (clic explicite de l'utilisateur dans la palette). Lecture seule, chemin limité au dossier personnel.
        s.on("POST", "/api/search/reveal") { req, res in
            let p0: String = (req.json["path"] as? String) ?? ""
            let home: String = NSHomeDirectory()
            let p: String = (p0 as NSString).standardizingPath
            if p.isEmpty || !p.hasPrefix(home + "/") || !FileManager.default.fileExists(atPath: p) {
                let bad: [String: Any] = ["ok": false, "message": "Fichier introuvable ou hors du dossier personnel."]
                res.json(bad, status: 400)
                return
            }
            let r: (Int32, String) = runProcess("/usr/bin/open", ["-R", p], timeout: 5)
            let ok: Bool = (r.0 == 0)
            let msg: String = ok ? "Affiché dans le Finder." : "Le Finder n'a pas pu l'afficher."
            let body: [String: Any] = ["ok": ok, "message": msg]
            res.json(body)
        }

        // Actions réversibles récentes (léger : 60 dernières lignes du journal, fenêtre de 120 s) pour le toast « Annuler ».
        s.on("GET", "/api/search/undoable") { _, res in
            let tail: [[String: Any]] = Tools.actions.tail(60)
            var undone: Set<String> = []
            for e in tail { if let u = e["undoes"] as? String { undone.insert(u) } }
            let fmt: ISO8601DateFormatter = ISO8601DateFormatter()
            let now: Date = Date()
            var out: [[String: Any]] = []
            for e in tail.reversed() {
                guard let id = e["id"] as? String, e["undo"] is [String: Any] else { continue }
                if undone.contains(id) || (e["undone"] as? Bool) == true { continue }
                let ts: String = (e["ts"] as? String) ?? ""
                guard let d = fmt.date(from: ts), now.timeIntervalSince(d) < 120 else { continue }
                var kind: String = ""
                if let u = e["undo"] as? [String: Any] { kind = (u["kind"] as? String) ?? "" }
                let item: [String: Any] = ["id": id, "tool": (e["tool"] as? String) ?? "", "kind": kind,
                                           "input": String(((e["input"] as? String) ?? "").prefix(120)),
                                           "actor": (e["actor"] as? String) ?? "", "ts": ts]
                out.append(item)
            }
            let body: [String: Any] = ["items": out]
            res.json(body)
        }
    }

    // MARK: - Sources

    func srchConversations(_ words: [String]) -> [[String: Any]] {
        let all: [String: Any] = convs.load()
        var rows: [(String, [String: Any])] = []
        for (k, v) in all {
            if let c = v as? [String: Any] { rows.append((k, c)) }
        }
        rows.sort { (a: (String, [String: Any]), b: (String, [String: Any])) -> Bool in
            let ua: String = (a.1["updated"] as? String) ?? ""
            let ub: String = (b.1["updated"] as? String) ?? ""
            return ua > ub
        }
        var out: [[String: Any]] = []
        for (id, c) in rows {
            if out.count >= 8 { break }
            let title: String = (c["title"] as? String) ?? "(sans titre)"
            let updated: String = (c["updated"] as? String) ?? ""
            let msgs: [[String: Any]] = (c["messages"] as? [[String: Any]]) ?? []
            var snippet: String = ""
            var hit: Bool = false
            for m in msgs.reversed() {
                let t: String = (m["content"] as? String) ?? ""
                if srchMatch(t, words) { snippet = srchSnippet(t, words[0]); hit = true; break }
            }
            if !hit && srchMatch(title, words) {
                hit = true
                let first: String = (msgs.first?["content"] as? String) ?? ""
                snippet = srchSnippet(first, "")
            }
            if hit {
                let action: [String: Any] = ["type": "conversation", "id": id]
                out.append(srchItem("conversations", title, snippet, action, ts: updated))
            }
        }
        return out
    }

    func srchMemory(_ q: String, _ words: [String]) -> [[String: Any]] {
        var hits: [[String: Any]] = memory.search(q, limit: 8)
        if hits.isEmpty {
            hits = memory.list().reversed().filter { (m: [String: Any]) -> Bool in srchMatch((m["text"] as? String) ?? "", words) }
        }
        var out: [[String: Any]] = []
        for m in hits {
            if out.count >= 6 { break }
            if (m["forgiven"] as? Bool) == true { continue }
            let text: String = (m["text"] as? String) ?? ""
            if text.isEmpty { continue }
            let action: [String: Any] = ["type": "tab", "tab": "memoire", "hint": String(text.prefix(40))]
            out.append(srchItem("memoire", String(text.prefix(90)), srchSnippet(text, words[0]), action, ts: (m["ts"] as? String) ?? ""))
        }
        return out
    }

    func srchDots(_ words: [String]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        let list: [[String: Any]] = dots.list()
        var names: [String: String] = [:]
        for d in list {
            let id: String = (d["id"] as? String) ?? ""
            let name: String = (d["name"] as? String) ?? id
            names[id] = name
            if out.count >= 4 { continue }
            let role: String = (d["role"] as? String) ?? ""
            let prompt: String = (d["prompt"] as? String) ?? ""
            let hay: String = name + " " + role + " " + id + " " + prompt
            if srchMatch(hay, words) {
                let emoji: String = (d["emoji"] as? String) ?? ""
                let title: String = emoji.isEmpty ? name : emoji + " " + name
                var snip: String = role
                if role.isEmpty || !srchMatch(role, words) {
                    if srchMatch(prompt, words) { snip = srchSnippet(prompt, words[0]) }
                }
                let action: [String: Any] = ["type": "tab", "tab": "dots", "hint": name]
                out.append(srchItem("dots", title, snip, action))
            }
        }
        var reports: Int = 0
        for r in dots.history().prefix(80) {
            if reports >= 4 || out.count >= 7 { break }
            let task: String = (r["task"] as? String) ?? ""
            let result: String = (r["result"] as? String) ?? ""
            if !srchMatch(task + " " + result, words) { continue }
            let dotId: String = (r["dot"] as? String) ?? ""
            let dname: String = names[dotId] ?? dotId
            let title: String = "Rapport · " + dname + (task.isEmpty ? "" : " — " + String(task.prefix(60)))
            let snip: String = srchMatch(result, words) ? srchSnippet(result, words[0]) : srchSnippet(result, "")
            let action: [String: Any] = ["type": "tab", "tab": "dots", "hint": dname]
            out.append(srchItem("dots", title, snip, action, ts: (r["ts"] as? String) ?? ""))
            reports += 1
        }
        return out
    }

    func srchDrafts(_ words: [String]) -> [[String: Any]] {
        let l: [[String: Any]] = tools.drafts.read(default: [[String: Any]]())
        var out: [[String: Any]] = []
        for d in l.reversed() {
            if out.count >= 5 { break }
            let subject: String = (d["subject"] as? String) ?? ""
            let to: String = (d["to"] as? String) ?? ""
            let body: String = (d["body"] as? String) ?? ""
            if !srchMatch(subject + " " + to + " " + body, words) { continue }
            let title: String = (to.isEmpty ? "" : "À " + to + " — ") + (subject.isEmpty ? "(sans objet)" : subject)
            let snip: String = srchMatch(body, words) ? srchSnippet(body, words[0]) : srchSnippet(body, "")
            let action: [String: Any] = ["type": "tab", "tab": "brouillons", "hint": subject.isEmpty ? to : subject]
            out.append(srchItem("brouillons", title, snip, action, ts: (d["ts"] as? String) ?? ""))
        }
        return out
    }

    /// Instantanés texte déjà en mémoire (aucune lecture d'écran, aucune app lancée). Contenu non fiable : simple affichage.
    func srchMails(_ words: [String]) -> [[String: Any]] {
        let boxes: [(String, String, String)] = [("ol", "Outlook", "outlook"), ("gm", "Gmail", "gmail"), ("tm", "Teams", "teams"), ("wa", "WhatsApp", "whatsapp")]
        var out: [[String: Any]] = []
        for (id, label, tab) in boxes {
            guard let snap = WebMail.snapshot(id) else { continue }
            var n: Int = 0
            for line in snap.split(separator: "\n") {
                if n >= 3 || out.count >= 8 { break }
                let l: String = String(line).trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("===") || l.count < 3 { continue }
                if !srchMatch(l, words) { continue }
                let action: [String: Any] = ["type": "tab", "tab": tab]
                out.append(srchItem("mails", label + " · " + String(l.prefix(70)), srchSnippet(l, words[0]), action))
                n += 1
            }
        }
        return out
    }

    /// Spotlight (lecture seule) dans le dossier personnel. La requête est passée comme argument (pas de shell) et nettoyée.
    func srchFiles(_ q: String) -> [[String: Any]] {
        #if os(macOS)
        let allowed: CharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_.@'’"))
        let scalars: [Unicode.Scalar] = q.unicodeScalars.filter { allowed.contains($0) }
        var view: String.UnicodeScalarView = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        var clean: String = String(view)
        while clean.hasPrefix("-") || clean.hasPrefix(" ") || clean.hasPrefix(".") { clean.removeFirst() }
        clean = clean.trimmingCharacters(in: .whitespaces)
        if clean.count < 2 { return [] }
        let home: String = NSHomeDirectory()
        let r: (Int32, String) = runProcess("/usr/bin/mdfind", ["-onlyin", home, clean], timeout: 2.8)
        if r.0 != 0 { return [] }
        var out: [[String: Any]] = []
        for line in r.1.split(separator: "\n") {
            if out.count >= 15 { break }
            let p: String = String(line)
            if !p.hasPrefix(home + "/") { continue }
            if p.contains("/Library/") || p.contains("/.") { continue }   // dossiers système / cachés : jamais proposés
            let name: String = (p as NSString).lastPathComponent
            let parent: String = (p as NSString).deletingLastPathComponent
            let short: String = parent.hasPrefix(home) ? "~" + String(parent.dropFirst(home.count)) : parent
            let action: [String: Any] = ["type": "file", "path": p]
            out.append(srchItem("fichiers", name, short, action))
        }
        return out
        #else
        return []
        #endif
    }
}
