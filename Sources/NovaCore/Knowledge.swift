import Foundation

/// V10 — Base de connaissances LOCALE : Nova indexe lui-même les documents des dossiers choisis (charte, règles, historiques, cahiers),
/// puis les consulte avant de répondre. Rien ne quitte le Mac pour l'indexation ; seuls les extraits utiles partent vers le cerveau choisi.
/// Garde-fous : fichiers de clés / mots de passe / finances / santé exclus d'office (ils passent par le Coffre), lignes ressemblant à un secret masquées.
public final class Knowledge: @unchecked Sendable {
    public static let shared = Knowledge()

    struct Chunk { let path: String; let text: String; let tf: [String: Int]; let len: Int; let boost: Double }
    private var chunks: [Chunk] = []
    private var df: [String: Int] = [:]
    private var avgLen = 1.0
    private var ftsID = -1      // Phase 8 : numéro d'extraits dont chunks_fts (SQLite FTS5) est l'image complète ; -1 = FTS5 absent / pas prêt
    private var chunksID = 0   // incrémenté à chaque reconstruction : l'index vectoriel n'est utilisé que s'il porte le même numéro
    private let lock = NSLock()
    private let store = JSONFile("knowledge_index.json")
    private let meta = JSONFile("knowledge_meta.json")
    private(set) var scanning = false
    private var progress: [String: Any] = ["state": "idle", "files": 0, "chunks": 0, "skipped": 0, "masked": 0, "current": ""]
    private var doctrine: [[String: String]] = []
    private var indexedPaths: Set<String> = []   // V5-V : fichiers présents dans l'index après la dernière passe (comptes par source)

    public static let defaultRoots = ["~/spark-local", "~/bionic-app", "~/Documents", "~/Desktop", "~/Downloads"]
    public init() { load() }

    // MARK: règles d'exclusion
    static let skipDirs = ["/.git", "/node_modules", "/.build", "/__pycache__", "/library/", "/.trash", "/backups", "/venv", "/site-packages",
                           "sparklocal.app", "nova.app", "/_v1_backup", "/_", "/.bionic-tools", "/.ssh", "/.gnupg", "/.aws", "/.config", "/data-seed", "/build/",
                           "/nova", "/releves",   // Nova ne s'indexe pas lui-même : son arbre (Nova, Nova-public, Nova_v*, NOVA_ECHANGE) et ses relevés de diagnostic sont exclus
                           "/v9-supreme", "/v10-singularity", "/nexus-v8", "/fusion"]   // anciennes interfaces Spark Local (code, pas de connaissance)
    static let sensitiveName = ["secret", "token", "password", "passwd", "motdepasse", "mot_de_passe", "mot-de-passe", "credential", "client_secret", ".env", "id_rsa", ".pem", ".p12", ".key",
                                "keychain", "cookie", "wallet", "recovery", "iban", "rib_", "sbif", "fcp", "banque", "bank", "releve", "relevé", "finance", "sante", "santé", "medic",
                                "ordonnance", "passeport", "passport", "identite", "identité", "cni", "chrome passwords", "logins"]
    static let boostName = ["charte", "regle", "règle", "design", "politique", "manifeste", "cahier", "adn", "instruction", "consigne", "plan", "inventaire", "brief", "architecture", "standard", "teams"]
    static let exts: Set<String> = ["md", "txt", "docx", "html", "htm", "markdown"]
    /// V5-V (25/10) : l'INDEXATION (scan) lit aussi PDF (PDFKit via VaultHooks.pdfText) et JSON (notes d'autres IA) ;
    /// `exts` reste inchangé pour /api/knowledge/recent et les résumés (Feat_Resumes).
    static let scanExts: Set<String> = exts.union(["pdf", "json"])
    static let stop: Set<String> = ["les", "des", "une", "que", "qui", "pour", "pas", "dans", "est", "sur", "avec", "par", "mais", "plus", "the", "and", "for", "that", "this", "with", "aux", "ces", "son", "ses", "leur", "elle", "ils", "nous", "vous", "tout", "tous", "comme", "fait", "être", "avoir"]
    static let secretLine = try! NSRegularExpression(pattern: #"(?i)((api[_ -]?key|secret|token|password|mot de passe|bearer|passphrase)\s*[:=]\s*\S{6,})|(\b(sk|pk|xox[bp]|ghp|gho|AIza|or-v1|eyJ)[-_A-Za-z0-9]{16,})|(\b[A-Za-z0-9+/_-]{40,}\b)|(\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b)|(\b\d{13,19}\b)"#)
    /// Masque les secrets avant écriture dans le journal d'actions et la chaîne signée.
    static func redact(_ t: String) -> String { secretLine.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "[masqué]") }

    static func allowed(_ path: String) -> Bool {
        let l = path.lowercased()
        if skipDirs.contains(where: { l.contains($0) }) { return false }
        let name = (l as NSString).lastPathComponent
        if sensitiveName.contains(where: { name.contains($0) }) { return false }
        return exts.contains((name as NSString).pathExtension)
    }
    /// V5-V : même règle que `allowed`, extensions d'indexation (PDF, JSON en plus) ; `probe` = chemin à tester contre
    /// skipDirs (relatif à la racine quand la racine est une source déclarée sous ~/Library ou un dossier caché).
    static func allowedScan(_ full: String, probe: String) -> Bool {
        let l = probe.lowercased()
        if skipDirs.contains(where: { l.contains($0) }) { return false }
        let name = (full.lowercased() as NSString).lastPathComponent
        if sensitiveName.contains(where: { name.contains($0) }) { return false }
        if SecretsGuard.isCredentialPath(full) { return false }
        return scanExts.contains((name as NSString).pathExtension)
    }

    static func tokens(_ s: String) -> [String] {
        let f = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        return f.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init).filter { $0.count >= 3 && !stop.contains($0) }
    }

    // MARK: lecture d'un document
    static func readText(_ path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        let maxSize: Int = ext == "pdf" ? 25_000_000 : 1_500_000   // V5-V : un PDF de rapport dépasse vite 1,5 Mo ; seul son texte est gardé
        guard let a = try? FileManager.default.attributesOfItem(atPath: path), let sz = (a[.size] as? NSNumber)?.intValue ?? (a[.size] as? UInt64).map({ Int($0) }) ?? (a[.size] as? Int), sz < maxSize else { return nil }
        if ext == "pdf" {   // V5-V : PDFKit fourni par NovaMac (VaultHooks.pdfText, main.swift) ; nil sous Linux ou PDF scanné
            guard let t = VaultHooks.pdfText?(path), !t.isEmpty else { return nil }
            return String(t.prefix(200_000))
        }
        if ext == "docx" {
            #if os(macOS) || os(Linux)
            let (c, o) = runProcess("/usr/bin/unzip", ["-p", path, "word/document.xml"], timeout: 8)
            guard c == 0, !o.isEmpty else { return nil }
            return o.replacingOccurrences(of: "</w:p>", with: "\n").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            #else
            return nil
            #endif
        }
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        var s = String(decoding: d, as: UTF8.self)
        if ext == "html" || ext == "htm" {
            s = s.replacingOccurrences(of: "(?s)<(script|style)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
                 .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        }
        return s
    }

    /// Masque les lignes qui ressemblent à un secret. Retourne le texte nettoyé et le nombre de lignes masquées.
    static func scrub(_ s: String) -> (String, Int) {
        var n = 0; var out: [String] = []
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            if secretLine.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil { n += 1; out.append("[ligne masquée]") } else { out.append(l) }
        }
        return (out.joined(separator: "\n"), n)
    }

    static func split(_ s: String, size: Int = 900) -> [String] {
        var res: [String] = []; var cur = ""
        for para in s.components(separatedBy: "\n\n") {
            let p = para.trimmingCharacters(in: .whitespacesAndNewlines); if p.isEmpty { continue }
            if cur.count + p.count > size, !cur.isEmpty { res.append(cur); cur = "" }
            if p.count > size * 2 { var i = p.startIndex; while i < p.endIndex { let j = p.index(i, offsetBy: size, limitedBy: p.endIndex) ?? p.endIndex; res.append(String(p[i..<j])); i = j } }
            else { cur += (cur.isEmpty ? "" : "\n\n") + p }
        }
        if !cur.isEmpty { res.append(cur) }
        return res
    }

    // MARK: indexation
    public func status() -> [String: Any] { lock.lock(); defer { lock.unlock() }; var p = progress; p["scanning"] = scanning; p["indexed_chunks"] = chunks.count; p["doctrine"] = doctrine.map { $0["name"] ?? "" }; return p }

    /// NOVA2-FIX (bug démarrage 20/10) : instantané d'indexation pour l'interface —
    /// l'écran de démarrage affiche la progression réelle au lieu d'un squelette
    /// muet, et l'écran Système peut brancher le même état. Lecture seule, verrou bref.
    public func statusSnapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["scanning": scanning, "progress": progress]
    }

    public func scan(roots: [String]) {
        // V5-V (25/10) : les « Sources de Nova » activées (Feat_Sources.swift) s'ajoutent aux racines de chaque passe —
        // quel que soit l'appelant (minuterie 6 h, /api/knowledge/scan, passe des Sources toutes les 30 min).
        let allRoots: [String] = NovaSources.mergedRoots(roots)
        lock.lock(); if scanning { lock.unlock(); return }; scanning = true
        progress = ["state": "scan", "files": 0, "chunks": 0, "skipped": 0, "masked": 0, "current": ""]; lock.unlock()
        Thread.detachNewThread { [self] in
            var raw: [[String: Any]] = []; var files = 0, skipped = 0, masked = 0
            var doc: [[String: String]] = []
            let fm = FileManager.default; let home = NSHomeDirectory()
            // Index précédent regroupé par fichier : un fichier dont la mtime n'a pas bougé n'est pas relu.
            var old: [String: (m: Double, chunks: [[String: Any]])] = [:]
            for r in store.read(default: [[String: Any]]()) {
                guard let p = r["p"] as? String else { continue }
                let m = (r["m"] as? NSNumber)?.doubleValue ?? 0
                if var e = old[p] { e.chunks.append(r); old[p] = e } else { old[p] = (m, [r]) }
            }
            var seenPaths = Set<String>(); var reread = 0
            var secretFiles = 0
            for r0 in allRoots {
                let r = r0.hasPrefix("~") ? home + r0.dropFirst() : r0
                guard r == home || r.hasPrefix(home + "/"), !SecretsGuard.isSensitiveRoot(r), let en = fm.enumerator(atPath: r) else { continue }   // jamais hors du dossier personnel ni dans un dossier d'identifiants
                // V5-V : une racine déclarée qui contient elle-même un motif exclu (~/Library/CloudStorage/OneDrive-…,
                // ~/Library/Application Support/Claude) est jugée sur son chemin RELATIF ; les autres, comme avant.
                let relProbe: Bool = !Knowledge.allowedDir(r)
                var rootFiles = 0
                while let rel = en.nextObject() as? String {
                    if files >= 8000 || rootFiles >= 2500 { break }   // V5-V : plafond par passe ET par racine (une grosse source n'affame plus les autres)
                    let full = r + "/" + rel
                    let probe: String = relProbe ? "/" + rel : full
                    var isDir: ObjCBool = false; fm.fileExists(atPath: full, isDirectory: &isDir)
                    if isDir.boolValue { if !Knowledge.allowedDir(probe) || SecretsGuard.isSensitiveRoot(full) { en.skipDescendants() }; continue }
                    guard Knowledge.allowedScan(full, probe: probe), NovaSources.admits(root: r, path: full) else { if Knowledge.scanExts.contains((full as NSString).pathExtension.lowercased()) { skipped += 1 }; continue }
                    #if os(macOS)
                    if let rv = try? URL(fileURLWithPath: full).resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey]), (rv.fileSize ?? 0) > 0, (rv.fileAllocatedSize ?? 1) == 0 { skipped += 1; continue }   // fichier iCloud non téléchargé : on ne force jamais son téléchargement
                    #endif
                    let name = (full as NSString).lastPathComponent
                    let mtime = ((try? fm.attributesOfItem(atPath: full))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    let isDoctrine = Knowledge.boostName.contains(where: { name.lowercased().contains($0) })
                    if mtime > 0, let o = old[full], abs(o.m - mtime) < 0.001, !o.chunks.isEmpty {
                        // Inchangé depuis le dernier index : on réutilise les extraits déjà nettoyés, sans relire le disque.
                        files += 1; rootFiles += 1; seenPaths.insert(full); raw.append(contentsOf: o.chunks)
                        masked += o.chunks.reduce(0) { $0 + (($1["k"] as? NSNumber)?.intValue ?? 0) }
                        if isDoctrine, doc.count < 8 { doc.append(["name": name, "text": String(o.chunks.compactMap { $0["t"] as? String }.joined(separator: "\n\n").prefix(700))]) }
                        if files % 25 == 0 { lock.lock(); progress["files"] = files; progress["chunks"] = raw.count; progress["current"] = name; lock.unlock() }
                        if raw.count > 60000 { break }
                        continue
                    }
                    guard let txt = Knowledge.readText(full) else { continue }
                    if SecretsGuard.containsSecret(txt) { secretFiles += 1; skipped += 1; continue }   // V5-V : un fichier qui contient un secret n'est pas indexé
                    let (clean, m) = Knowledge.scrub(txt); masked += m; files += 1; rootFiles += 1; reread += 1; seenPaths.insert(full)
                    if isDoctrine, doc.count < 8 { doc.append(["name": name, "text": String(clean.prefix(700))]) }
                    for (ci, c) in Knowledge.split(clean).prefix(60).enumerated() { raw.append(["p": full, "t": c, "b": isDoctrine ? 1.35 : 1.0, "m": mtime, "k": ci == 0 ? m : 0]) }
                    if files % 25 == 0 { lock.lock(); progress["files"] = files; progress["chunks"] = raw.count; progress["current"] = name; lock.unlock() }
                    if raw.count > 60000 { break }
                }
            }
            let unchanged = reread == 0 && Set(old.keys) == seenPaths   // rien relu et même liste de fichiers : l'index sur disque et en mémoire est déjà bon
            if !unchanged { store.write(raw) }
            lock.lock(); doctrine = doc; scanning = false; indexedPaths = seenPaths
            progress = ["state": "ok", "files": files, "chunks": raw.count, "skipped": skipped, "masked": masked, "secret_files": secretFiles, "current": "", "ts": nowISO()]; lock.unlock()
            meta.write(["progress": progress, "doctrine": doc, "roots": allRoots])
            if !unchanged { rebuild(from: raw) }
        }
    }

    /// V5-V : nombre de fichiers indexés sous chaque préfixe (Sources de Nova). Avant la première passe de la session :
    /// déduit des extraits chargés depuis le disque.
    public func fileCounts(prefixes: [String]) -> [String: Int] {
        lock.lock()
        let paths: Set<String> = indexedPaths.isEmpty ? Set(chunks.map { (c: Chunk) -> String in c.path }) : indexedPaths
        lock.unlock()
        var out: [String: Int] = [:]
        for p in prefixes { out[p] = paths.filter { (x: String) -> Bool in x == p || x.hasPrefix(p + "/") }.count }
        return out
    }

    static func allowedDir(_ path: String) -> Bool { let l = path.lowercased() + "/"; return !skipDirs.contains(where: { l.contains($0) }) }

    private func load() {
        let raw = store.read(default: [[String: Any]]())
        if let m = meta.read(default: [String: Any]()) as [String: Any]?, let p = m["progress"] as? [String: Any] { progress = p; doctrine = (m["doctrine"] as? [[String: String]]) ?? [] }
        rebuild(from: raw)
    }

    private func rebuild(from raw: [[String: Any]]) {
        var cs: [Chunk] = []; var d: [String: Int] = [:]; var total = 0
        for r in raw {
            guard let p = r["p"] as? String, let t = r["t"] as? String else { continue }
            var tf: [String: Int] = [:]; let tk = Knowledge.tokens(t)
            for w in tk { tf[w, default: 0] += 1 }
            for w in tf.keys { d[w, default: 0] += 1 }
            total += tk.count
            cs.append(Chunk(path: p, text: t, tf: tf, len: max(1, tk.count), boost: (r["b"] as? Double) ?? 1.0))
        }
        lock.lock(); chunks = cs; df = d; avgLen = cs.isEmpty ? 1 : Double(total) / Double(cs.count); chunksID += 1; let cid = chunksID; lock.unlock()
        // Index vectoriel (UltraVectorIndex) construit en arrière-plan ; tant qu'il n'est pas prêt, la recherche reste BM25 seule.
        if UltraVectorIndex.enabled, !cs.isEmpty { UltraVectorIndex.shared.rebuild(id: cid, texts: cs.map { $0.text }) }
        // Phase 8 : image FTS5 des extraits (seulement si NovaSQLite est actif ET que SQLite a FTS5) ; la recherche l'utilise quand ftsID == chunksID.
        lock.lock(); ftsID = -1; lock.unlock()
        if let db = UltraDatabase.active, db.ftsAvailable, !cs.isEmpty {
            let rows = cs.enumerated().map { (id: $0.offset, path: $0.element.path, title: ($0.element.path as NSString).lastPathComponent, content: $0.element.text) }
            db.ftsRebuild(rows: rows) { [self] ok in
                lock.lock(); if ok && chunksID == cid { ftsID = cid }; lock.unlock()
            }
        }
    }

    /// Phase 8 — fusion FTS5 (BM25 natif SQLite) + cosinus : Score = 0,70 × vec + 0,30 × bm25 normalisé, +0,15 si le fragment est dans les deux canaux.
    /// Nil si FTS5 est indisponible/en erreur ou ne donne rien : l'appelant retombe alors sur le BM25 mémoire historique.
    private func searchFTS(_ q: String, tokens qt: Set<String>, chunks cs: [Chunk], limit: Int, chunksID cid: Int) -> [[String: Any]]? {
        guard let db = UltraDatabase.active, db.ftsAvailable else { return nil }
        let match = qt.sorted().map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " OR ")
        guard let fh = db.ftsSearch(match: match, limit: max(limit * 6, 24)) else { return nil }
        var ftsRaw: [Int: Double] = [:]
        for h in fh where h.id >= 0 && h.id < cs.count && h.score > 0 { ftsRaw[h.id] = h.score * cs[h.id].boost }
        let maxF = ftsRaw.values.max() ?? 0
        var simByIndex: [Int: Double] = [:]
        var vecOK = false
        if let v = UltraVectorIndex.shared.search(q, k: max(limit * 6, 24)), v.id == cid, !v.hits.isEmpty {
            vecOK = true
            let floor: Double = v.kind == "hash" ? 0.20 : 0.45
            for (i, sim) in v.hits where i < cs.count {
                let adj = (Double(sim) - floor) / (1 - floor)
                if adj > 0 { simByIndex[i] = adj }
            }
        }
        var fused: [(Double, Double, Chunk)] = []   // (score fusionné, score FTS brut, extrait)
        for i in Set(ftsRaw.keys).union(simByIndex.keys) {
            let raw = ftsRaw[i] ?? 0, sim = simByIndex[i] ?? 0
            let fn = maxF > 0 ? raw / maxF : 0
            if raw == 0 && sim < 0.25 { continue }   // un extrait purement sémantique doit être nettement proche
            let f: Double = vecOK ? (0.70 * sim + 0.30 * fn + (raw > 0 && sim > 0 ? 0.15 : 0)) : fn
            fused.append((f, raw, cs[i]))
        }
        if fused.isEmpty { return nil }
        var seen = Set<String>(); var out: [[String: Any]] = []
        for (f, raw, c) in fused.sorted(by: { $0.0 > $1.0 }) {
            let key = c.path + String(c.text.prefix(40)); if seen.contains(key) { continue }; seen.insert(key)
            out.append(["path": c.path, "file": (c.path as NSString).lastPathComponent, "score": (raw * 100).rounded() / 100, "hybride": (f * 1000).rounded() / 1000,
                        "canal": vecOK ? "fts5+vec" : "fts5", "text": String(c.text.prefix(700))])
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: recherche (BM25)
    public func search(_ q: String, limit: Int = 5) -> [[String: Any]] {
        let qt = Set(Knowledge.tokens(q)); if qt.isEmpty { return [] }
        lock.lock(); let cs = chunks, dfc = df, avg = avgLen, cid = chunksID, fid = ftsID; lock.unlock()
        if fid == cid, let fused = searchFTS(q, tokens: qt, chunks: cs, limit: limit, chunksID: cid) { return fused }   // Phase 8 : FTS5 + vecteurs ; sinon BM25 mémoire ci-dessous
        let n = Double(max(1, cs.count)); var scored: [(Double, Chunk)] = []
        var bmByIndex: [Int: Double] = [:]
        for (ci, c) in cs.enumerated() {
            var s = 0.0
            for w in qt { guard let f = c.tf[w] else { continue }
                let idf = log(1 + (n - Double(dfc[w] ?? 0) + 0.5) / (Double(dfc[w] ?? 0) + 0.5))
                s += idf * (Double(f) * 2.2) / (Double(f) + 1.2 * (0.25 + 0.75 * Double(c.len) / avg)) }
            if s > 0 { scored.append((s * c.boost, c)); bmByIndex[ci] = s * c.boost }
        }
        // Fusion hybride BM25 + cosinus (UltraVectorIndex) si l'index correspond à ces extraits ; sinon BM25 seul (comportement historique).
        if let v = UltraVectorIndex.shared.search(q, k: max(limit * 6, 24)), v.id == cid, !v.hits.isEmpty {
            let floor: Double = v.kind == "hash" ? 0.20 : 0.45   // en dessous : similarité jugée non pertinente
            let maxBM = bmByIndex.values.max() ?? 0
            var simByIndex: [Int: Double] = [:]
            for (i, sim) in v.hits where i < cs.count {
                let adj = (Double(sim) - floor) / (1 - floor)
                if adj > 0 { simByIndex[i] = adj }
            }
            var fused: [(Double, Double, Chunk)] = []   // (score fusionné, score BM25, extrait)
            for i in Set(bmByIndex.keys).union(simByIndex.keys) {
                let bm = bmByIndex[i] ?? 0, sim = simByIndex[i] ?? 0
                if bm == 0 && sim < 0.25 { continue }   // un extrait purement sémantique doit être nettement proche
                let f = 0.7 * (maxBM > 0 ? bm / maxBM : 0) + 0.3 * sim
                fused.append((f, bm, cs[i]))
            }
            var seen = Set<String>(); var out: [[String: Any]] = []
            for (f, bm, c) in fused.sorted(by: { $0.0 > $1.0 }) {
                let key = c.path + String(c.text.prefix(40)); if seen.contains(key) { continue }; seen.insert(key)
                out.append(["path": c.path, "file": (c.path as NSString).lastPathComponent, "score": (bm * 100).rounded() / 100, "hybride": (f * 1000).rounded() / 1000, "text": String(c.text.prefix(700))])
                if out.count >= limit { break }
            }
            return out
        }
        var seen = Set<String>(); var out: [[String: Any]] = []
        for (s, c) in scored.sorted(by: { $0.0 > $1.0 }) {
            let key = c.path + String(c.text.prefix(40)); if seen.contains(key) { continue }; seen.insert(key)
            out.append(["path": c.path, "file": (c.path as NSString).lastPathComponent, "score": (s * 100).rounded() / 100, "text": String(c.text.prefix(700))])
            if out.count >= limit { break }
        }
        return out
    }

    /// Texte renvoyé à l'assistant par l'outil « know ».
    public func toolText(_ q: String) -> String {
        let r = search(q, limit: 4)
        if r.isEmpty { return chunks.isEmpty ? "Base de connaissances vide : demande à l'utilisateur de lancer l'indexation (onglet Mémoire › Connaissances)." : "Rien trouvé dans les documents pour « \(q) »." }
        return r.map { "• [\($0["file"] ?? "")] \($0["text"] ?? "")" }.joined(separator: "\n---\n")
    }

    /// BRAIN-B (24/10) : partie STABLE du contexte documentaire (doctrine), placée avant cacheMark.
    public func doctrineBlock() -> String {
        lock.lock(); let doc = doctrine; let n = chunks.count; lock.unlock()
        if n == 0 { return "" }
        var s = "BASE DE CONNAISSANCES PERSONNELLE (documents réels d'Ahadi, lecture seule ; cite le fichier quand tu t'y appuies ; outil know(requête) pour chercher davantage)."
        if !doc.isEmpty { s += "\nDOCTRINE (extraits de ses chartes/règles) :\n" + doc.prefix(4).map { "- [\($0["name"] ?? "")] " + ($0["text"] ?? "").replacingOccurrences(of: "\n", with: " ").prefix(320) }.joined(separator: "\n") }
        return s
    }
    /// BRAIN-B (24/10) : partie DYNAMIQUE (extraits liés au message), après cacheMark.
    public func hitsBlock(query: String) -> String {
        lock.lock(); let n = chunks.count; lock.unlock()
        if n == 0 || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        let hits = search(query, limit: 3)
        if hits.isEmpty { return "" }
        return "EXTRAITS DE SES DOCUMENTS LIÉS AU MESSAGE :\n" + hits.map { "- [\($0["file"] ?? "")] " + (($0["text"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ").prefix(420) }.joined(separator: "\n")
    }

    /// Contexte injecté dans le prompt à chaque message : doctrine permanente (charte/règles) + extraits liés à la question.
    public func promptBlock(query: String) -> String {
        lock.lock(); let doc = doctrine; let n = chunks.count; lock.unlock()
        if n == 0 { return "" }
        var s = "BASE DE CONNAISSANCES PERSONNELLE (documents réels de l'utilisateur, lecture seule ; cite le fichier quand tu t'y appuies ; outil know(requête) pour chercher davantage)."
        if !doc.isEmpty { s += "\nDOCTRINE (extraits de ses chartes/règles) :\n" + doc.prefix(4).map { "- [\($0["name"] ?? "")] " + ($0["text"] ?? "").replacingOccurrences(of: "\n", with: " ").prefix(320) }.joined(separator: "\n") }
        let hits = search(query, limit: 3)
        if !hits.isEmpty { s += "\nEXTRAITS LIÉS À LA QUESTION :\n" + hits.map { "- [\($0["file"] ?? "")] " + (($0["text"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ").prefix(420) }.joined(separator: "\n") }
        return s
    }
}
