import Foundation

// V5-V (25/10/2026) — « SOURCES DE NOVA » : les dossiers que Nova indexe dans son savoir (Knowledge, outil know).
// Branché dans NovaPlus.novaPlusRoutes() ; les racines activées sont ajoutées à CHAQUE passe de Knowledge.scan
// (Knowledge.swift : NovaSources.mergedRoots), quel que soit l'appelant.
//
// Politique d'Ahadi du 25/10 10:55 : Nova remplace Muse partout et voit tout son travail — SCI compris — et le contenu
// des autres IA du Mac. Limites : les secrets (SecretsGuard) et l'envoi (GO d'Ahadi). Ici :
// • LECTURE SEULE : ce fichier n'écrit JAMAIS dans une source (énumération, lecture, rien d'autre) ; write_file /
//   edit_file refusent en plus d'écrire dans les sources « IA », OneDrive/SharePoint (synchro = publication), Nova 1 et
//   les dossiers ajoutés par Ahadi (NovaSources.writeBlockReason, appelé par Tools.swift).
// • Fichiers d'identifiants (.env, *.pem, id_rsa*, trousseaux, *password*, cookies, Login Data…) jamais lus ; un fichier
//   dont le texte contient un secret n'est pas indexé (Knowledge.scan).
// • Passe incrémentale (mtime : un fichier inchangé n'est pas relu) toutes les 30 min en arrière-plan, plafonnée
//   (8 000 fichiers par passe, 2 500 par racine), suspendue pendant que Ahadi travaille (NovaApp.perfBusyNow).
// • Erreur de permission macOS : jamais de plantage — la source affiche le chemin exact et le geste
//   « Accès complet au disque ».
//
// Routes : GET /api/sources · POST /api/sources/toggle {id, on} · POST /api/sources/add {path} ·
//          POST /api/sources/remove {id} · POST /api/sources/scan {id?}

struct NovaSourceDef {
    let id: String
    let label: String
    let path: String
    let kind: String      // ia | sci | mac | projets | perso
    let note: String
    let filter: String    // "" ou « conversations » (seuls les fichiers de conversation / d'export)
    let custom: Bool
}

struct NovaSourceProbe {
    let exists: Bool
    let readable: Bool
    let denied: Bool
    let error: String
}

enum NovaSources {
    static let store: JSONFile = JSONFile("sources.json")
    static let lock: NSLock = NSLock()            // état de passe + sources.json
    static let detectLock: NSLock = NSLock()      // cache de détection (jamais pris sous `lock` dans l'autre sens)
    nonisolated(unsafe) static var passRunning: Bool = false   // PHASE 1 (relu, protégé) : sous lock (passe, fin de passe, état)
    nonisolated(unsafe) static var rerun: Bool = false
    nonisolated(unsafe) static var schedulerStarted: Bool = false   // PHASE 1 (relu, protégé) : sous lock
    nonisolated(unsafe) static var detectAt: Date = .distantPast
    nonisolated(unsafe) static var detectDefs: [NovaSourceDef] = []
    nonisolated(unsafe) static var museSearched: [String] = []
    static let periodS: TimeInterval = 1800
    static let fdaHint: String = "accès refusé par macOS : accorder l'Accès complet au disque à Nova dans Réglages Système › Confidentialité"

    // MARK: détection

    static func names(_ dir: String) -> [String] {
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
    }
    static func slug(_ s: String) -> String {
        let low: String = s.lowercased()
        var out: String = ""
        for c in low { out.append((c.isASCII && (c.isLetter || c.isNumber)) ? c : "-") }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return String(out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(48))
    }
    static func shortHash(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
        return String(h % 0xFFFFFFFF, radix: 16)
    }

    /// Candidats auto-détectés (liste fixe + dossiers Muse / OneDrive réellement présents). Cache 10 min.
    static func detect(force: Bool = false) -> [NovaSourceDef] {
        detectLock.lock()
        if !force && Date().timeIntervalSince(detectAt) < 600 && !detectDefs.isEmpty { let d: [NovaSourceDef] = detectDefs; detectLock.unlock(); return d }
        detectLock.unlock()
        let h: String = NSHomeDirectory()
        var out: [NovaSourceDef] = []
        func add(_ id: String, _ label: String, _ path: String, _ kind: String, _ note: String, _ filter: String = "") {
            if out.contains(where: { (d: NovaSourceDef) -> Bool in d.path == path || d.id == id }) { return }
            out.append(NovaSourceDef(id: id, label: label, path: path, kind: kind, note: note, filter: filter, custom: false))
        }
        // Muse : chemins plausibles, seulement ceux qui existent.
        var searched: [String] = []
        let appSup: String = h + "/Library/Application Support"
        searched.append(appSup + "/Muse*")
        for n in names(appSup) where n.lowercased().hasPrefix("muse") {
            add("muse-as-" + slug(n), "Muse — " + n, appSup + "/" + n, "ia", "Données de l'app Muse (Application Support).")
        }
        let containers: String = h + "/Library/Containers"
        searched.append(containers + "/*muse*")
        for n in names(containers) where n.lowercased().contains("muse") {
            add("muse-ct-" + slug(n), "Muse — conteneur " + n, containers + "/" + n + "/Data", "ia", "Conteneur macOS de l'app Muse.")
        }
        searched.append(h + "/Documents/Muse*")
        for n in names(h + "/Documents") where n.lowercased().hasPrefix("muse") {
            add("muse-doc-" + slug(n), "Muse — Documents/" + n, h + "/Documents/" + n, "ia", "Dossier Muse dans Documents.")
        }
        add("documents", "Documents", h + "/Documents", "mac", "Documents du Mac.")
        add("desktop", "Bureau", h + "/Desktop", "mac", "Fichiers posés sur le Bureau.")
        add("downloads", "Téléchargements", h + "/Downloads", "mac", "Fichiers téléchargés (rapports, pièces jointes enregistrées).")
        let cloud: String = h + "/Library/CloudStorage"
        for n in names(cloud) where n.hasPrefix("OneDrive") || n.lowercased().contains("sharepoint") {
            add("onedrive-" + slug(n), "OneDrive / SharePoint — " + n, cloud + "/" + n, "sci",
                "Dossiers SCI synchronisés. Les fichiers « en ligne seulement » ne sont jamais téléchargés par Nova ; aucune écriture (la synchro publierait).")
        }
        for n in names(h) where n.hasPrefix("OneDrive") {
            add("onedrive-home-" + slug(n), "OneDrive — ~/" + n, h + "/" + n, "sci", "Dossier OneDrive (ancien emplacement).")
        }
        add("spark-local", "spark-local — projets d'Ahadi", h + "/spark-local", "projets",
            "Projets (Nova 1 dans ~/spark-local/Nova : lecture seule ; les arbres de code de Nova restent hors de l'index).")
        detectLock.lock(); detectDefs = out; detectAt = Date(); museSearched = searched; detectLock.unlock()
        return out
    }

    static func load() -> [String: Any] { return store.read(default: [String: Any]()) }

    static func customDefs(_ doc: [String: Any]) -> [NovaSourceDef] {
        let raw: [[String: Any]] = (doc["custom"] as? [[String: Any]]) ?? []
        return raw.compactMap { (c: [String: Any]) -> NovaSourceDef? in
            guard let id = c["id"] as? String, let p = c["path"] as? String, !id.isEmpty, !p.isEmpty else { return nil }
            return NovaSourceDef(id: id, label: (c["label"] as? String) ?? (p as NSString).lastPathComponent, path: p, kind: "perso",
                                 note: "Dossier ajouté par Ahadi — lecture seule pour Nova.", filter: "", custom: true)
        }
    }

    static func allDefs(_ doc: [String: Any]? = nil) -> [NovaSourceDef] {
        let d: [String: Any] = doc ?? load()
        var out: [NovaSourceDef] = detect()
        for c in customDefs(d) where !out.contains(where: { (x: NovaSourceDef) -> Bool in x.path == c.path }) { out.append(c) }
        return out
    }

    /// Existence et lisibilité réelles ; une erreur de permission macOS est reconnue (jamais de plantage).
    static func probe(_ path: String) -> NovaSourceProbe {
        let fm: FileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return NovaSourceProbe(exists: false, readable: false, denied: false, error: "dossier absent : " + path) }
        guard isDir.boolValue else { return NovaSourceProbe(exists: true, readable: false, denied: false, error: "ce chemin n'est pas un dossier : " + path) }
        do {
            _ = try fm.contentsOfDirectory(atPath: path)
            return NovaSourceProbe(exists: true, readable: true, denied: false, error: "")
        } catch {
            let ns: NSError = error as NSError
            let under: NSError? = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            let denied: Bool = (ns.domain == NSCocoaErrorDomain && ns.code == 257)
                || (ns.domain == NSPOSIXErrorDomain && (ns.code == 1 || ns.code == 13))
                || (under.map { (u: NSError) -> Bool in u.domain == NSPOSIXErrorDomain && (u.code == 1 || u.code == 13) } ?? false)
            if denied { return NovaSourceProbe(exists: true, readable: false, denied: true, error: fdaHint + " — " + path) }
            return NovaSourceProbe(exists: true, readable: false, denied: false, error: "lecture impossible (" + ns.localizedDescription + ") : " + path)
        }
    }

    static func isOn(_ d: NovaSourceDef, _ doc: [String: Any], _ p: NovaSourceProbe) -> Bool {
        guard p.exists && p.readable else { return false }
        let choices: [String: Any] = (doc["choices"] as? [String: Any]) ?? [:]
        if let c = choices[d.id] as? Bool { return c }
        return true   // candidat présent et lisible : activé par défaut
    }

    static func enabledDefs() -> [NovaSourceDef] {
        let doc: [String: Any] = load()
        return allDefs(doc).filter { (d: NovaSourceDef) -> Bool in
            !SecretsGuard.isSensitiveRoot(d.path) && isOn(d, doc, probe(d.path))
        }
    }

    // MARK: branchement Knowledge

    /// Racines d'une passe : racines de connaissance + sources activées, chemins absolus, sans doublon ni racine
    /// incluse dans une autre (une source dans ~/Documents est déjà couverte par ~/Documents).
    static func mergedRoots(_ base: [String]) -> [String] {
        let h: String = NSHomeDirectory()
        func norm(_ p: String) -> String {
            let e: String = p.hasPrefix("~") ? h + String(p.dropFirst()) : p
            return (e as NSString).standardizingPath
        }
        var all: [String] = base.map(norm)
        for d in enabledDefs() { all.append(norm(d.path)) }
        var out: [String] = []
        for p in all where !p.isEmpty {
            if out.contains(where: { (o: String) -> Bool in o == p || p.hasPrefix(o + "/") }) { continue }
            out.removeAll(where: { (o: String) -> Bool in o.hasPrefix(p + "/") })
            out.append(p)
        }
        return out
    }

    /// Filtre fichier par fichier, appelé par Knowledge.scan (en plus de ses propres exclusions).
    static func admits(root: String, path: String) -> Bool {
        if SecretsGuard.isCredentialPath(path) { return false }
        let claude: String = NSHomeDirectory() + "/Library/Application Support/Claude/"
        if path.hasPrefix(claude) {
            let n: String = (path as NSString).lastPathComponent.lowercased()
            return ["conversation", "export", "chat"].contains(where: { (w: String) -> Bool in n.contains(w) })
        }
        return true
    }

    /// Écriture refusée (write_file / edit_file) : sources IA, OneDrive/SharePoint, Nova 1, dossiers ajoutés par Ahadi.
    static func writeBlockReason(_ path: String) -> String? {
        let h: String = NSHomeDirectory()
        var ro: [String] = [h + "/Library/CloudStorage", h + "/spark-local/Nova"]
        for n in names(h) where n.hasPrefix("OneDrive") { ro.append(h + "/" + n) }
        for d in allDefs() where d.kind == "ia" || d.kind == "sci" || d.custom { ro.append(d.path) }
        for r in ro where path == r || path.hasPrefix(r + "/") {
            return "Refusé : « " + r + " » est une source en LECTURE SEULE de Nova (Sources de Nova — autres IA, OneDrive/SharePoint, Nova 1 ou dossier ajouté par Ahadi). Écris ailleurs (ex. ~/Documents) ou demande-lui."
        }
        return nil
    }

    // MARK: état et passes

    static func listJSON() -> [String: Any] {
        let doc: [String: Any] = load()
        let defs: [NovaSourceDef] = allDefs(doc)
        let state: [String: Any] = (doc["state"] as? [String: Any]) ?? [:]
        let counts: [String: Int] = Knowledge.shared.fileCounts(prefixes: defs.map { (d: NovaSourceDef) -> String in d.path })
        var items: [[String: Any]] = []
        for d in defs {
            let p: NovaSourceProbe = probe(d.path)
            let sensitive: Bool = SecretsGuard.isSensitiveRoot(d.path)
            let on: Bool = !sensitive && isOn(d, doc, p)
            let st: String
            if sensitive { st = "exclu" }
            else if !p.exists { st = "absent" }
            else if p.denied { st = "accès refusé" }
            else if !p.readable { st = "illisible" }
            else { st = on ? "actif" : "désactivé" }
            let last: [String: Any] = (state[d.id] as? [String: Any]) ?? [:]
            var it: [String: Any] = ["id": d.id, "label": d.label, "path": d.path, "kind": d.kind, "note": d.note, "custom": d.custom,
                                     "on": on, "exists": p.exists, "readable": p.readable, "status": st, "error": sensitive ? "dossier d'identifiants ou données propres de Nova : jamais indexé" : p.error,
                                     "files": counts[d.path] ?? 0, "read_only": true]
            if !d.filter.isEmpty { it["filter"] = d.filter }
            if let ts = last["last_pass"] as? String { it["last_pass"] = ts }
            items.append(it)
        }
        lock.lock(); let running: Bool = passRunning; lock.unlock()
        detectLock.lock(); let searched: [String] = museSearched; detectLock.unlock()
        let ks: [String: Any] = Knowledge.shared.status()
        var out: [String: Any] = ["sources": items, "pass_running": running, "scanning": (ks["scanning"] as? Bool) ?? false,
                                  "interval_min": Int(periodS / 60), "caps": ["par_passe": 8000, "par_source": 2500], "read_only": true,
                                  "secrets_guard": SecretsGuard.compiledOK, "fda_hint": fdaHint, "muse_searched": searched,
                                  "knowledge": ["files": ks["files"] ?? 0, "chunks": ks["chunks"] ?? 0, "skipped": ks["skipped"] ?? 0, "secret_files": ks["secret_files"] ?? 0, "ts": ks["ts"] ?? ""]]
        if let lp = doc["last_pass"] as? [String: Any] { out["last_pass"] = lp }
        return out
    }

    static func setChoice(_ id: String, _ on: Bool) {
        lock.lock()
        var doc: [String: Any] = load()
        var ch: [String: Any] = (doc["choices"] as? [String: Any]) ?? [:]
        ch[id] = on
        doc["choices"] = ch
        store.write(doc)
        lock.unlock()
    }

    /// Lance une passe en arrière-plan. false = une passe tourne déjà (elle sera relancée une fois à la fin).
    @discardableResult static func runPass(reason: String) -> Bool {
        lock.lock()
        if passRunning { rerun = true; lock.unlock(); return false }
        passRunning = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let t0: Date = Date()
            var waited: Int = 0
            while ((Knowledge.shared.status()["scanning"] as? Bool) ?? false) && waited < 1800 { Thread.sleep(forTimeInterval: 5); waited += 5 }
            _ = detect(force: true)
            let base: [String] = Settings().get("knowledge_roots", Knowledge.defaultRoots)
            Knowledge.shared.scan(roots: base)   // ajoute lui-même les sources activées (mergedRoots)
            Thread.sleep(forTimeInterval: 2)
            waited = 0
            while ((Knowledge.shared.status()["scanning"] as? Bool) ?? false) && waited < 3600 { Thread.sleep(forTimeInterval: 5); waited += 5 }
            let ks: [String: Any] = Knowledge.shared.status()
            let now: String = nowISO()
            lock.lock()
            var doc: [String: Any] = load()
            var state: [String: Any] = (doc["state"] as? [String: Any]) ?? [:]
            for d in allDefs(doc) {
                var e: [String: Any] = (state[d.id] as? [String: Any]) ?? [:]
                e["last_pass"] = now
                state[d.id] = e
            }
            doc["state"] = state
            let ms: Int = Int(Date().timeIntervalSince(t0) * 1000)
            doc["last_pass"] = ["ts": now, "reason": reason, "ms": ms, "files": ks["files"] ?? 0, "chunks": ks["chunks"] ?? 0,
                                "skipped": ks["skipped"] ?? 0, "secret_files": ks["secret_files"] ?? 0] as [String: Any]
            store.write(doc)
            passRunning = false
            let again: Bool = rerun
            rerun = false
            lock.unlock()
            _ = BlackBox.record(["tool": "sources", "actor": "Nova", "why": "Sources de Nova — passe d'indexation (" + reason + ") : " + String(describing: ks["files"] ?? 0) + " fichiers, lecture seule", "ok": true, "effect": "lu"])
            if again { runPass(reason: "relance après changement") }
        }
        return true
    }

    /// Toutes les 30 min ; si Ahadi travaille (stream, Voix Live), nouvel essai dans 5 min.
    static func startScheduler() {
        lock.lock()
        if schedulerStarted { lock.unlock(); return }
        schedulerStarted = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 900) { tick() }
    }
    static func tick() {
        if NovaApp.perfBusyNow {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 300) { tick() }
            return
        }
        runPass(reason: "minuterie (30 min)")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + periodS) { tick() }
    }

    // MARK: ajout d'un dossier choisi par Ahadi

    static func add(path raw: String) -> (body: [String: Any], status: Int) {
        let h: String = NSHomeDirectory()
        var p: String = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("file://"), let u = URL(string: p) { p = u.path }
        if p.hasPrefix("~") { p = h + String(p.dropFirst()) }
        p = (p as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p = String(p.dropLast()) }
        guard p.hasPrefix(h + "/") else { return (["ok": false, "error": "dossier refusé : hors de ton dossier personnel (" + p + ")"], 400) }
        guard !SecretsGuard.isSensitiveRoot(p), !Tools.match(Tools.forbiddenRx, p) else {
            return (["ok": false, "error": "dossier refusé : identifiants, trousseaux ou données propres de Nova (" + p + ")"], 400)
        }
        let pr: NovaSourceProbe = probe(p)
        guard pr.exists else { return (["ok": false, "error": pr.error], 400) }
        lock.lock()
        var doc: [String: Any] = load()
        if let known = allDefs(doc).first(where: { (d: NovaSourceDef) -> Bool in d.path == p }) {
            var ch: [String: Any] = (doc["choices"] as? [String: Any]) ?? [:]
            ch[known.id] = true
            doc["choices"] = ch
            store.write(doc)
            lock.unlock()
            runPass(reason: "source réactivée")
            return (["ok": true, "id": known.id, "deja": true, "error": pr.error], 200)
        }
        var custom: [[String: Any]] = (doc["custom"] as? [[String: Any]]) ?? []
        guard custom.count < 40 else { lock.unlock(); return (["ok": false, "error": "40 dossiers ajoutés au plus"], 400) }
        let id: String = "u-" + shortHash(p)
        custom.append(["id": id, "label": (p as NSString).lastPathComponent, "path": p, "ts": nowISO()])
        doc["custom"] = custom
        var ch: [String: Any] = (doc["choices"] as? [String: Any]) ?? [:]
        ch[id] = true
        doc["choices"] = ch
        store.write(doc)
        lock.unlock()
        _ = BlackBox.record(["tool": "sources", "actor": "Ahadi", "why": "source ajoutée (lecture seule) : " + p, "ok": true, "effect": "écrit sources.json"])
        if pr.readable { runPass(reason: "dossier ajouté") }
        return (["ok": true, "id": id, "error": pr.error], 200)
    }

    static func remove(id: String) -> (body: [String: Any], status: Int) {
        lock.lock()
        var doc: [String: Any] = load()
        var custom: [[String: Any]] = (doc["custom"] as? [[String: Any]]) ?? []
        let before: Int = custom.count
        custom.removeAll(where: { (c: [String: Any]) -> Bool in (c["id"] as? String) == id })
        guard custom.count < before else { lock.unlock(); return (["ok": false, "error": "seuls les dossiers ajoutés se retirent ; un candidat se désactive"], 400) }
        doc["custom"] = custom
        var ch: [String: Any] = (doc["choices"] as? [String: Any]) ?? [:]
        ch.removeValue(forKey: id)
        doc["choices"] = ch
        store.write(doc)
        lock.unlock()
        runPass(reason: "source retirée")
        return (["ok": true], 200)
    }

    // MARK: outil (nova_self « sources ») et préférences (nova_self « prefs|… »)

    static func toolText() -> String {
        let j: [String: Any] = listJSON()
        var l: [String] = ["SOURCES DE NOVA (lecture seule ; indexées dans le savoir — outil know) :"]
        for s in (j["sources"] as? [[String: Any]]) ?? [] {
            let err: String = (s["error"] as? String) ?? ""
            let sLabel: String = (s["label"] as? String) ?? ""
            let sStatus: String = (s["status"] as? String) ?? ""
            let sFiles: Int = (s["files"] as? Int) ?? 0
            let sPath: String = (s["path"] as? String) ?? ""
            let sErr: String = (err.isEmpty || sStatus == "absent") ? "" : " — \(err)"
            l.append("- \(sLabel) [\(sStatus)] · \(sFiles) fichiers · \(sPath)\(sErr)")
        }
        if let lp = j["last_pass"] as? [String: Any] { let lpTs: String = (lp["ts"] as? String) ?? "?"; let lpWhy: String = (lp["reason"] as? String) ?? ""; l.append("Dernière passe : \(lpTs) (\(lpWhy))") }
        l.append("Ce qui n'est pas indexé reste lisible avec read_file, find ou shell (lecture). Accès refusé par macOS → Réglages Système › Confidentialité et sécurité › Accès complet au disque › Nova.")
        return l.joined(separator: "\n")
    }

    /// Préférences en LECTURE SEULE : « » = domaines ; « nova » = réglages de Nova ; un domaine (com.apple.dock,
    /// NSGlobalDomain) ou un nom d'app. Valeurs de secrets masquées (SecretsGuard.redactKeyedLines).
    static func prefsText(_ arg: String) -> String {
        let a: String = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.lowercased() == "nova" {
            let cur: [String: Any] = Settings().all()
            var lines: [String] = []
            for k in cur.keys.sorted() {
                let low: String = k.lowercased()
                if low.contains("key") || low.contains("token") || low.contains("password") || low.contains("secret") { lines.append(k + " = [masqué]"); continue }
                lines.append(k + " = " + String(String(describing: cur[k] ?? "—").prefix(160)))
            }
            return "RÉGLAGES DE NOVA (lecture seule ici ; modification : nova_self « set|clé|valeur » pour les clés autorisées) :\n" + SecretsGuard.redact(lines.joined(separator: "\n"))
        }
        #if os(macOS)
        if a.isEmpty {
            let (c, o) = runProcess("/usr/bin/defaults", ["domains"], timeout: 10)
            guard c == 0 else { return "Lecture des domaines de préférences macOS impossible (code \(c))." }
            let doms: [String] = o.components(separatedBy: ",").map { (x: String) -> String in x.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { (x: String) -> Bool in !x.isEmpty }
            return "PRÉFÉRENCES macOS — \(doms.count) domaines (lecture seule). Lis-en un avec nova_self « prefs|domaine » (ex. com.apple.dock) ou « prefs|Nom de l'app » ; « prefs|nova » = réglages de Nova.\n" + doms.prefix(500).joined(separator: ", ")
        }
        var dom: String = a
        let domRx: NSRegularExpression? = try? NSRegularExpression(pattern: #"^[A-Za-z0-9._-]{1,160}$"#)
        let looksDomain: Bool = (domRx.map { (r: NSRegularExpression) -> Bool in Tools.match(r, a) } ?? false) && (a.contains(".") || a == "NSGlobalDomain")
        if !looksDomain {
            let safe: String = String(a.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "").prefix(80))
            let (c, o) = runProcess("/usr/bin/osascript", ["-e", "id of app \"" + safe + "\""], timeout: 10)
            let bid: String = o.trimmingCharacters(in: .whitespacesAndNewlines)
            guard c == 0, !bid.isEmpty else { return "App « \(safe) » introuvable (identifiant de paquet non résolu). Donne le domaine exact (ex. com.microsoft.teams2) ou appelle nova_self « prefs » pour la liste." }
            dom = bid
        }
        var (c, o) = runProcess("/usr/bin/defaults", ["read", dom], timeout: 15)
        var src: String = "defaults read " + dom
        if c != 0 || o.isEmpty {
            let plist: String = NSHomeDirectory() + "/Library/Containers/" + dom + "/Data/Library/Preferences/" + dom + ".plist"
            if FileManager.default.fileExists(atPath: plist) {
                (c, o) = runProcess("/usr/bin/plutil", ["-p", plist], timeout: 15)
                src = "plutil -p " + plist
            }
        }
        guard c == 0, !o.isEmpty else { return "Préférences de « \(dom) » illisibles (code \(c)). Si macOS refuse : Réglages Système › Confidentialité et sécurité › Accès complet au disque › Nova." }
        let body: String = SecretsGuard.redactKeyedLines(o)
        return "PRÉFÉRENCES « \(dom) » (lecture seule, source : \(src) ; secrets masqués) :\n" + String(body.prefix(12000)) + (body.count > 12000 ? "\n… (tronqué)" : "")
        #else
        return "Préférences macOS : disponibles sur le Mac seulement."
        #endif
    }
}

// MARK: - Routes

extension NovaApp {
    func sourcesRoutes() {
        let s = server
        NovaSources.startScheduler()
        s.on("GET", "/api/sources") { _, res in
            res.json(NovaSources.listJSON())
        }
        s.on("POST", "/api/sources/toggle") { req, res in
            let j: [String: Any] = req.json
            let id: String = (j["id"] as? String) ?? ""
            guard let on = j["on"] as? Bool, NovaSources.allDefs().contains(where: { (d: NovaSourceDef) -> Bool in d.id == id }) else {
                let bad: [String: Any] = ["ok": false, "error": "id de source inconnu ou « on » manquant"]
                res.json(bad, status: 400); return
            }
            NovaSources.setChoice(id, on)
            NovaSources.runPass(reason: on ? "source activée" : "source désactivée")
            var out: [String: Any] = NovaSources.listJSON()
            out["ok"] = true
            res.json(out)
        }
        s.on("POST", "/api/sources/add") { req, res in
            let r: (body: [String: Any], status: Int) = NovaSources.add(path: (req.json["path"] as? String) ?? "")
            res.json(r.body, status: r.status)
        }
        s.on("POST", "/api/sources/remove") { req, res in
            let r: (body: [String: Any], status: Int) = NovaSources.remove(id: (req.json["id"] as? String) ?? "")
            res.json(r.body, status: r.status)
        }
        s.on("POST", "/api/sources/scan") { req, res in
            let id: String = (req.json["id"] as? String) ?? ""
            _ = NovaSources.detect(force: true)
            if !id.isEmpty, !NovaSources.allDefs().contains(where: { (d: NovaSourceDef) -> Bool in d.id == id }) {
                let bad: [String: Any] = ["ok": false, "error": "id de source inconnu"]
                res.json(bad, status: 400); return
            }
            let started: Bool = NovaSources.runPass(reason: id.isEmpty ? "demande d'Ahadi" : "demande d'Ahadi (" + id + ")")
            let out: [String: Any] = ["ok": true, "started": started, "queued": !started, "incremental": true]
            res.json(out)
        }
    }
}
