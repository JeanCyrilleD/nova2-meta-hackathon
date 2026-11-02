import Foundation

// Cerveaux & entretien (Nova Plus).
//  (A) Classement des cerveaux PAR PREUVE : statistiques tirées du journal réel du routeur (cerveaux_journal.jsonl).
//      BrainRank.reorder ne fait que RÉORDONNER de façon stable l'ordre du mode : il ne retire jamais un cerveau,
//      n'agit pas sous 3 essais, et le cerveau imposé par l'utilisateur reste en tête (Router.plan l'ajoute avant).
//  (B) Purge / rotation : minuteur (1er tir à 10 min, puis toutes les 6 h) dans le dossier de données de Nova.
//      Jamais touchés : mémoire, Dots, réglages, clés, brouillons, coffre, constitution, BlackBox (blackbox.jsonl + blackbox.key).
//      Les conversations ne sont jamais supprimées : elles sont ARCHIVÉES (archive/conversations-AAAA-MM.json).

// MARK: - (A) Classement des cerveaux

struct BrainStatAcc {
    var calls: Int = 0
    var ok: Int = 0
    var totals: [Int] = []
    var firsts: [Int] = []
    var tokIn: Int = 0
    var tokOut: Int = 0
}

struct BrainRankKey {
    let key: Double
    let idx: Int
    let id: String
}

struct BrainSpecInfo {
    let label: String
    let cost: String      // "gratuit" | "payant" | "premium"
}

final class BrainRankState: @unchecked Sendable {
    static let shared: BrainRankState = BrainRankState()
    let lock: NSLock = NSLock()
    var active: Bool = false                      // vrai seulement une fois maintenanceRoutes() appelée
    var enabled: Bool = true                      // réglage « brain_rank » (défaut : vrai)
    var specs: [String: BrainSpecInfo] = [:]
    var cacheAt: Date = Date.distantPast
    var scores: [String: Double] = [:]
    var rows: [[String: Any]] = []
    var computing: Bool = false
}

public enum BrainRank {
    static let minSamples: Int = 3
    static let windowDays: Double = 30
    static let maxBytes: Int = 2_000_000          // on ne lit que la fin du journal (sobriété)
    static let cacheSeconds: TimeInterval = 120

    /// Classe de coût d'un cerveau d'après sa spécification (aucun tarif réel n'est connu : estimation par catégorie).
    static func costClass(_ s: BrainSpec) -> String {
        if s.kind == .local { return "gratuit" }
        let blob: String = (s.id + " " + s.label + " " + s.note + " " + s.model).lowercased()
        if blob.contains("gratuit") || blob.contains(":free") || blob.contains("-free") || blob.contains("best-free") { return "gratuit" }
        if s.baseURL.contains("127.0.0.1") || s.baseURL.contains("localhost") { return "gratuit" }
        let m: String = s.model.lowercased()
        let premium: [String] = ["-sol", "fable", "argon"]
        for p in premium where m.contains(p) { return "premium" }
        return "payant"
    }
    static func costPenalty(_ c: String) -> Double {
        if c == "gratuit" { return 0.0 }
        if c == "premium" { return 0.15 }
        return 0.08
    }

    static func configure(brains: [BrainSpec], enabled: Bool) {
        var m: [String: BrainSpecInfo] = [:]
        for s in brains { m[s.id] = BrainSpecInfo(label: s.label, cost: costClass(s)) }
        m["local"] = BrainSpecInfo(label: "Local (aucun en version Meta)", cost: "gratuit")
        let st: BrainRankState = BrainRankState.shared
        st.lock.lock()
        st.specs = m
        st.enabled = enabled
        st.active = true
        st.cacheAt = Date.distantPast
        st.lock.unlock()
    }

    /// Lit les dernières lignes du journal sans prendre son verrou (une ligne partielle en cours d'écriture est simplement ignorée).
    static func tailLines(_ url: URL, maxBytes: Int) -> [String] {
        guard let fh: FileHandle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        let size: UInt64 = fh.seekToEndOfFile()
        let want: UInt64 = UInt64(maxBytes)
        let start: UInt64 = size > want ? size - want : 0
        fh.seek(toFileOffset: start)
        var data: Data = fh.readDataToEndOfFile()
        if start > 0 {
            // Première ligne probablement coupée (peut-être au milieu d'un caractère UTF-8) : on la jette AVANT de décoder.
            guard let nl: Data.Index = data.firstIndex(of: UInt8(10)) else { return [] }
            data = Data(data[data.index(after: nl)...])
        }
        let text: String = String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: "\n")
    }

    static func median(_ a: [Int]) -> Int? {
        if a.isEmpty { return nil }
        let s: [Int] = a.sorted()
        return s[s.count / 2]
    }

    static func intOf(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }

    /// Calcule (et met en cache 2 min) les statistiques et scores. Renvoie (scores des cerveaux ≥ 3 essais, lignes détaillées).
    static func compute(force: Bool) -> ([String: Double], [[String: Any]]) {
        let st: BrainRankState = BrainRankState.shared
        st.lock.lock()
        let fresh: Bool = Date().timeIntervalSince(st.cacheAt) < cacheSeconds
        if (fresh && !force) || st.computing {
            let s: [String: Double] = st.scores
            let r: [[String: Any]] = st.rows
            st.lock.unlock()
            return (s, r)
        }
        st.computing = true
        let specs: [String: BrainSpecInfo] = st.specs
        st.lock.unlock()

        let url: URL = Paths.file("cerveaux_journal.jsonl")
        let lines: [String] = tailLines(url, maxBytes: maxBytes)
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        let isoFrac: ISO8601DateFormatter = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let limit: Date = Date().addingTimeInterval(-windowDays * 86400)
        var acc: [String: BrainStatAcc] = [:]
        for line in lines {
            if line.isEmpty { continue }
            guard let o: [String: Any] = parseJSON(Data(line.utf8)) else { continue }
            guard let id: String = o["brain"] as? String, !id.isEmpty else { continue }
            if let ts: String = o["ts"] as? String {
                let d: Date? = iso.date(from: ts) ?? isoFrac.date(from: ts)
                if let dd: Date = d, dd < limit { continue }
            }
            var a: BrainStatAcc = acc[id] ?? BrainStatAcc()
            a.calls += 1
            let ok: Bool = (o["ok"] as? Bool) ?? false
            if ok {
                a.ok += 1
                if let ms: Int = intOf(o["ms"]), ms > 0 { a.totals.append(ms) }
                if let f: Int = intOf(o["first_ms"]), f > 0 { a.firsts.append(f) }
            }
            a.tokIn += intOf(o["in"]) ?? 0
            a.tokOut += intOf(o["out"]) ?? 0
            acc[id] = a
        }

        var scores: [String: Double] = [:]
        var rows: [[String: Any]] = []
        for (id, a) in acc {
            let info: BrainSpecInfo? = specs[id]
            let cost: String = info?.cost ?? "payant"
            let rate: Double = a.calls > 0 ? Double(a.ok) / Double(a.calls) : 0
            let weighted: Double = (Double(a.ok) + 1.0) / (Double(a.calls) + 2.0)   // réussite lissée (Laplace) : peu d'essais = prudence
            let medTotal: Int? = median(a.totals)
            let medFirst: Int? = median(a.firsts)
            var latPen: Double = 0
            if let mt: Int = medTotal { latPen = min(0.30, Double(mt) / 100_000.0) }          // 10 s = 0,10 ; plafond 0,30
            if let mf: Int = medFirst { latPen += min(0.10, Double(mf) / 60_000.0) }          // premier mot (si mesuré)
            let cPen: Double = costPenalty(cost)
            let counted: Bool = a.calls >= minSamples
            let score: Double = weighted - latPen - cPen
            if counted { scores[id] = score }
            var row: [String: Any] = [
                "id": id,
                "label": info?.label ?? id,
                "cout": cost,
                "appels": a.calls,
                "reussites": a.ok,
                "taux_reussite": (rate * 1000).rounded() / 1000,
                "jetons_entree": a.tokIn,
                "jetons_sortie": a.tokOut,
                "penalite_latence": (latPen * 1000).rounded() / 1000,
                "penalite_cout": cPen,
                "compte": counted,
                "connu": info != nil,
            ]
            if let v: Int = medFirst { row["mediane_premier_ms"] = v } else { row["mediane_premier_ms"] = NSNull() }
            if let v: Int = medTotal { row["mediane_totale_ms"] = v } else { row["mediane_totale_ms"] = NSNull() }
            if counted {
                let rounded: Double = (score * 1000).rounded() / 1000
                row["score"] = rounded
            } else {
                row["score"] = NSNull()
            }
            rows.append(row)
        }
        rows.sort { (x: [String: Any], y: [String: Any]) -> Bool in
            let sx: Double? = x["score"] as? Double
            let sy: Double? = y["score"] as? Double
            if let a: Double = sx, let b: Double = sy { return a > b }
            if sx != nil { return true }
            if sy != nil { return false }
            let cx: Int = (x["appels"] as? Int) ?? 0
            let cy: Int = (y["appels"] as? Int) ?? 0
            return cx > cy
        }
        var rank: Int = 0
        for i in 0..<rows.count {
            if let _ = rows[i]["score"] as? Double {
                rank += 1
                rows[i]["rang"] = rank
            }
        }

        st.lock.lock()
        st.scores = scores
        st.rows = rows
        st.cacheAt = Date()
        st.computing = false
        st.lock.unlock()
        return (scores, rows)
    }

    /// Réordonne de façon STABLE une liste d'identifiants : un cerveau bien noté remonte de quelques places (6 au plus),
    /// un cerveau mal noté descend d'autant. Rien n'est retiré (même nombre d'éléments, doublons compris).
    /// Sans aucun cerveau à ≥ 3 essais, ou si le réglage « brain_rank » est faux, la liste est rendue telle quelle.
    public static func reorder(_ ids: [String]) -> [String] {
        if ids.count < 2 { return ids }
        let st: BrainRankState = BrainRankState.shared
        st.lock.lock()
        let on: Bool = st.active && st.enabled
        st.lock.unlock()
        if !on { return ids }
        let (scores, _) = compute(force: false)
        if scores.isEmpty { return ids }
        var keyed: [BrainRankKey] = []
        keyed.reserveCapacity(ids.count)
        for (i, id) in ids.enumerated() {
            var k: Double = Double(i)
            if let sc: Double = scores[id] {
                let shift: Double = max(-6.0, min(6.0, (sc - 0.5) * 12.0))
                k = Double(i) - shift
            }
            keyed.append(BrainRankKey(key: k, idx: i, id: id))
        }
        keyed.sort { (a: BrainRankKey, b: BrainRankKey) -> Bool in
            if a.key != b.key { return a.key < b.key }
            return a.idx < b.idx
        }
        let out: [String] = keyed.map { (k: BrainRankKey) -> String in k.id }
        return out.count == ids.count ? out : ids
    }
}

// MARK: - (B) Purge / rotation

final class MaintenanceState: @unchecked Sendable {
    static let shared: MaintenanceState = MaintenanceState()
    let lock: NSLock = NSLock()
    var running: Bool = false
    var timer: DispatchSourceTimer? = nil          // référence statique forte : le minuteur vit tant que l'app vit
    var nextAt: Date? = nil
}

enum NovaMaintenance {
    static let maxJournalLines: Int = 5000
    static let cacheMaxAge: TimeInterval = 7 * 86400
    static let convMaxAge: TimeInterval = 90 * 86400
    static let state: JSONFile = JSONFile("maintenance_etat.json")
    static let period: Int = 6 * 3600

    /// Fichiers jamais touchés par la purge (mémoire, Dots, réglages, clés, brouillons, coffre, BlackBox…).
    static func isProtected(_ name: String) -> Bool {
        let n: String = name.lowercased()
        let words: [String] = ["blackbox", "memoire", "memory", "dot", "settings", "reglage", "réglage", "key", "keys", "trousseau",
                               "brouillon", "draft", "vault", "coffre", "constitution", "secret", "permits", "relais", "bridge", "session"]
        for w in words where n.contains(w) { return true }
        return false
    }

    static func fileSize(_ path: String) -> Int64 {
        let attrs: [FileAttributeKey: Any]? = try? FileManager.default.attributesOfItem(atPath: path)
        if let n: NSNumber = attrs?[.size] as? NSNumber { return n.int64Value }
        return 0
    }
    static func mtime(_ path: String) -> Date? {
        let attrs: [FileAttributeKey: Any]? = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.modificationDate] as? Date
    }
    static func treeSize(_ path: String) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return fileSize(path) }
        var total: Int64 = 0
        if let en: FileManager.DirectoryEnumerator = FileManager.default.enumerator(atPath: path) {
            while let rel: String = en.nextObject() as? String {
                total += fileSize(path + "/" + rel)
            }
        }
        return total
    }

    /// Garde les `keep` dernières lignes d'un journal JSONL (écriture atomique). Renvoie (lignes avant, octets libérés), nil si rien à faire.
    static func truncate(_ url: URL, keep: Int, dryRun: Bool) -> (Int, Int64)? {
        guard let data: Data = try? Data(contentsOf: url) else { return nil }
        let bytes: [UInt8] = [UInt8](data)
        if bytes.isEmpty { return nil }
        var total: Int = 0
        for b in bytes where b == 10 { total += 1 }
        if bytes[bytes.count - 1] != 10 { total += 1 }
        if total <= keep { return nil }
        var idx: Int = bytes.count - 1
        if bytes[idx] == 10 { idx -= 1 }
        var seen: Int = 0
        var cut: Int = -1
        while idx >= 0 {
            if bytes[idx] == 10 {
                seen += 1
                if seen == keep { cut = idx + 1; break }
            }
            idx -= 1
        }
        if cut <= 0 { return nil }
        let freed: Int64 = Int64(cut)
        if dryRun { return (total, freed) }
        let tail: Data = Data(bytes[cut..<bytes.count])
        do { try tail.write(to: url, options: .atomic) } catch { return nil }
        return (total, freed)
    }

    /// Exécute une purge. `dryRun` = aperçu sans rien modifier.
    static func run(convs: Conversations, journals: [String: Journal], reason: String, dryRun: Bool) -> [String: Any] {
        let ms: MaintenanceState = MaintenanceState.shared
        ms.lock.lock()
        if ms.running { ms.lock.unlock(); return ["ok": false, "error": "une purge est déjà en cours"] }
        ms.running = true
        ms.lock.unlock()
        defer { ms.lock.lock(); ms.running = false; ms.lock.unlock() }

        let t0: Date = Date()
        let fm: FileManager = FileManager.default
        let home: URL = Paths.home
        var freed: Int64 = 0
        var journalRows: [[String: Any]] = []
        var deleted: [[String: Any]] = []
        var errors: [String] = []

        // 1) Journaux *.jsonl à la racine du dossier de données (BlackBox et fichiers protégés exclus).
        let names: [String] = ((try? fm.contentsOfDirectory(atPath: home.path)) ?? []).sorted()
        for n in names where n.hasSuffix(".jsonl") {
            if isProtected(n) { continue }
            let url: URL = home.appendingPathComponent(n)
            let j: Journal? = journals[n]
            j?.lock.lock()                                   // journal connu : aucun ajout perdu pendant la réécriture
            let r: (Int, Int64)? = truncate(url, keep: maxJournalLines, dryRun: dryRun)
            j?.lock.unlock()
            if let rr: (Int, Int64) = r {
                let before: Int = rr.0
                let f: Int64 = rr.1
                freed += f
                journalRows.append(["fichier": n, "lignes_avant": before, "lignes_apres": maxJournalLines, "octets": f])
            }
        }

        // 2) Caches et fichiers temporaires de plus de 7 jours.
        let now: Date = Date()
        var candidates: [String] = []
        //  a) vignettes Quick Look des documents CAFU (cafu/<doc>.png, régénérées à la demande) — les documents eux-mêmes ne sont jamais touchés.
        let cafu: String = home.appendingPathComponent("cafu", isDirectory: true).path
        for n in (try? fm.contentsOfDirectory(atPath: cafu)) ?? [] where n.hasSuffix(".png") {
            let base: String = String(n.dropLast(4))
            let lower: String = base.lowercased()
            let isThumb: Bool = lower.hasSuffix(".pptx") || lower.hasSuffix(".docx") || lower.hasSuffix(".xlsx") || lower.hasSuffix(".pdf") || lower.hasSuffix(".html")
            if isThumb { candidates.append(cafu + "/" + n) }
        }
        //  b) fichiers *.tmp oubliés à la racine du dossier de données.
        for n in names where n.hasSuffix(".tmp") && !isProtected(n) { candidates.append(home.path + "/" + n) }
        //  c) fichiers temporaires de Nova dans le dossier temporaire système (nova-ql-*, nova-forge-*, nova-stt-*, nova-*.wav, nova-selftest-*).
        let tmpDir: String = NSTemporaryDirectory()
        for n in (try? fm.contentsOfDirectory(atPath: tmpDir)) ?? [] where n.hasPrefix("nova-") {
            let p: String = tmpDir.hasSuffix("/") ? tmpDir + n : tmpDir + "/" + n
            candidates.append(p)
        }
        for p in candidates {
            guard let m: Date = mtime(p), now.timeIntervalSince(m) > cacheMaxAge else { continue }
            let size: Int64 = treeSize(p)
            if !dryRun {
                do { try fm.removeItem(atPath: p) } catch { errors.append("suppression impossible : " + (p as NSString).lastPathComponent); continue }
            }
            freed += size
            deleted.append(["fichier": (p as NSString).lastPathComponent, "octets": size])
        }

        // 3) Conversations de plus de 90 jours : ARCHIVÉES (jamais supprimées) dans archive/conversations-AAAA-MM.json.
        var archived: Int = 0
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        let month: DateFormatter = DateFormatter()
        month.locale = Locale(identifier: "en_US_POSIX")
        month.dateFormat = "yyyy-MM"
        convs.lock.lock()
        var live: [String: Any] = convs.load()
        var byMonth: [String: [String: Any]] = [:]
        for (id, v) in live {
            guard let c: [String: Any] = v as? [String: Any] else { continue }
            guard let up: String = c["updated"] as? String, let d: Date = iso.date(from: up) else { continue }   // date illisible : on ne touche pas
            if now.timeIntervalSince(d) <= convMaxAge { continue }
            let key: String = month.string(from: d)
            var bucket: [String: Any] = byMonth[key] ?? [:]
            bucket[id] = c
            byMonth[key] = bucket
        }
        if !byMonth.isEmpty {
            let adir: URL = home.appendingPathComponent("archive", isDirectory: true)
            if !dryRun { try? fm.createDirectory(at: adir, withIntermediateDirectories: true) }
            for (key, bucket) in byMonth {
                let aurl: URL = adir.appendingPathComponent("conversations-" + key + ".json")
                let bytes: Int64 = Int64(jsonData(bucket).count)
                if dryRun { archived += bucket.count; freed += bytes; continue }
                var merged: [String: Any] = [:]
                if let d: Data = try? Data(contentsOf: aurl), let o: [String: Any] = parseJSON(d) { merged = o }
                for (k, v) in bucket { merged[k] = v }
                do { try jsonData(merged).write(to: aurl, options: .atomic) } catch { errors.append("archive impossible : conversations-" + key + ".json"); continue }
                // Vérification avant de retirer quoi que ce soit du fichier vivant.
                guard let check: Data = try? Data(contentsOf: aurl), let co: [String: Any] = parseJSON(check) else { errors.append("archive illisible : " + key); continue }
                var allThere: Bool = true
                for k in bucket.keys where co[k] == nil { allThere = false }
                if !allThere { errors.append("archive incomplète : " + key); continue }
                for k in bucket.keys { live.removeValue(forKey: k) }
                archived += bucket.count
                freed += bytes
            }
            if !dryRun && archived > 0 { convs.f.write(live) }
        }
        convs.lock.unlock()

        let ms2: Int = Int(Date().timeIntervalSince(t0) * 1000)
        var result: [String: Any] = [
            "ok": true,
            "at": nowISO(),
            "raison": reason,
            "apercu": dryRun,
            "octets_liberes": freed,
            "journaux": journalRows,
            "fichiers_supprimes": deleted.count,
            "fichiers": Array(deleted.prefix(40)),
            "conversations_archivees": archived,
            "duree_ms": ms2,
            "erreurs": errors,
        ]
        if !dryRun {
            var st: [String: Any] = state.read(default: [String: Any]())
            var hist: [[String: Any]] = (st["historique"] as? [[String: Any]]) ?? []
            var short: [String: Any] = result
            short.removeValue(forKey: "fichiers")
            hist.insert(short, at: 0)
            st["historique"] = Array(hist.prefix(10))
            st["derniere"] = short
            state.write(st)
        }
        result["protege"] = "mémoire, Dots, réglages, clés, brouillons, coffre, constitution, BlackBox (blackbox.jsonl, blackbox.key)"
        return result
    }
}

extension NovaApp {
    func maintenanceRoutes() {
        let s: HTTPServer = server
        let routerRef: Router = router
        let settingsRef: Settings = settings
        let convsRef: Conversations = convs
        let busRef: Bus = bus
        let journals: [String: Journal] = [
            "cerveaux_journal.jsonl": router.journal,
            "actions.jsonl": Tools.actions,
            "voix_journal.jsonl": voice.journal,
            "briefs_journal.jsonl": briefs.log,
        ]

        BrainRank.configure(brains: routerRef.brains, enabled: settingsRef.get("brain_rank", true))

        // Minuteur de purge : 1er tir à 10 min, puis toutes les 6 h. Réglage « maintenance_auto » = false pour le suspendre.
        let ms: MaintenanceState = MaintenanceState.shared
        ms.lock.lock()
        if ms.timer == nil {
            let q: DispatchQueue = DispatchQueue(label: "nova.maintenance", qos: .utility)
            let t: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + .seconds(600), repeating: .seconds(NovaMaintenance.period), leeway: .seconds(60))
            t.setEventHandler {
                let st: MaintenanceState = MaintenanceState.shared
                st.lock.lock(); st.nextAt = Date().addingTimeInterval(TimeInterval(NovaMaintenance.period)); st.lock.unlock()
                let auto: Bool = Settings().get("maintenance_auto", true)
                if !auto { return }
                let r: [String: Any] = NovaMaintenance.run(convs: convsRef, journals: journals, reason: "minuteur", dryRun: false)
                busRef.publish("maintenance", r)
            }
            ms.timer = t
            ms.nextAt = Date().addingTimeInterval(600)
            t.resume()
        }
        ms.lock.unlock()

        s.on("GET", "/api/brains/rank") { req, res in
            BrainRank.configure(brains: routerRef.brains, enabled: settingsRef.get("brain_rank", true))
            let (_, rows) = BrainRank.compute(force: req.query["force"] == "1")
            let body: [String: Any] = [
                "classement": rows,
                "actif": settingsRef.get("brain_rank", true),
                "echantillon_min": BrainRank.minSamples,
                "fenetre_jours": Int(BrainRank.windowDays),
                "source": "cerveaux_journal.jsonl",
                "formule": "score = réussite lissée (ok+1)/(appels+2) − pénalité latence (médiane totale/100 s, max 0,30 ; + premier mot/60 s, max 0,10) − pénalité coût (gratuit 0, payant 0,08, premium 0,15)",
                "note": "Le premier mot n'est mesuré que pour le modèle local en mode souverain ; le coût est une estimation par catégorie (aucun tarif réel).",
                "at": nowISO(),
            ]
            res.json(body)
        }

        s.on("GET", "/api/maintenance") { req, res in
            if req.query["apercu"] == "1" {
                let r: [String: Any] = NovaMaintenance.run(convs: convsRef, journals: journals, reason: "aperçu", dryRun: true)
                res.json(r)
                return
            }
            let st: [String: Any] = NovaMaintenance.state.read(default: [String: Any]())
            let m: MaintenanceState = MaintenanceState.shared
            m.lock.lock()
            let running: Bool = m.running
            let next: Date? = m.nextAt
            m.lock.unlock()
            var body: [String: Any] = [
                "derniere": st["derniere"] ?? NSNull(),
                "historique": st["historique"] ?? [Any](),
                "en_cours": running,
                "auto": settingsRef.get("maintenance_auto", true),
                "seuils": ["journal_lignes": NovaMaintenance.maxJournalLines, "cache_jours": 7, "conversations_jours": 90, "periode_h": 6],
                "protege": "mémoire, Dots, réglages, clés, brouillons, coffre, constitution, BlackBox (blackbox.jsonl, blackbox.key)",
            ]
            if let n: Date = next { body["prochaine"] = ISO8601DateFormatter().string(from: n) }
            res.json(body)
        }

        s.on("POST", "/api/maintenance/run") { req, res in
            let dry: Bool = (req.json["apercu"] as? Bool) ?? false
            let r: [String: Any] = NovaMaintenance.run(convs: convsRef, journals: journals, reason: "manuel", dryRun: dry)
            if !dry { busRef.publish("maintenance", r) }
            res.json(r)
        }
    }
}

// MARK: - (C) Gouverneur de performance RÉEL (VAGUE 2 FIABILITÉ, 24/10)
//
// Remplace NovaApp.perfBusy (jamais écrit par l'interface) par des MESURES NATIVES, sans dépendance :
//   - état thermique : ProcessInfo.thermalState ;
//   - charge CPU système : SystemInfo.cpuLoadPercent (host_processor_info, cache 15 s) ;
//   - pression mémoire : sysctl kern.memorystatus_vm_pressure_level (1 normal, 2 avertissement, 4 critique) ;
//   - batterie : pmset -g batt (toutes les 2 min seulement) + mode économie d'énergie.
// Niveaux : normal → tendu → critique, avec HYSTÉRÉSIS : on monte après 2 mesures consécutives (≈ 1 min ;
// immédiatement pour un état critique), on redescend d'UN cran après 4 mesures plus calmes (≈ 2 min).
// Effets : tendu = Éclats planifiés espacés ×3 et tri du Fil espacé (≥ 30 s entre deux tris) ;
// critique = Éclats planifiés différés (le créneau reste ouvert 3 h) et tri espacé ≥ 90 s.
// Les lancements manuels (bouton Lancer, demande à Nova) ne sont jamais freinés. Une mesure illisible ne
// compte pas (jamais d'état inventé) : « mesures » ne contient que ce qui a été réellement lu.
// Exposé dans GET /api/state (champ « perf »).
public final class PerfGovernor: @unchecked Sendable {
    public static let shared: PerfGovernor = PerfGovernor()
    public static let normal: String = "normal"
    public static let tendu: String = "tendu"
    public static let critique: String = "critique"
    static let names: [String] = [PerfGovernor.normal, PerfGovernor.tendu, PerfGovernor.critique]

    let lock: NSLock = NSLock()
    var cur: Int = 0
    var curMotif: String = ""
    var since: String = nowISO()
    var upCount: Int = 0
    var downCount: Int = 0
    var lastSample: [String: Any] = [:]
    var lastAt: String = ""
    var started: Bool = false
    var timer: DispatchSourceTimer? = nil
    var batteryAt: Date = Date.distantPast
    var batteryPct: Int = -1
    var onBattery: Bool = false
    var lastTriAt: Date = Date.distantPast

    public func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        let t: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 20, repeating: 30)
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        lock.lock(); timer = t; lock.unlock()
    }

    public func level() -> String {
        lock.lock(); defer { lock.unlock() }
        return PerfGovernor.names[max(0, min(2, cur))]
    }
    public func motif() -> String {
        lock.lock(); defer { lock.unlock() }
        return curMotif.isEmpty ? "aucune contrainte mesurée" : curMotif
    }
    /// 31/10 (diag Éclats) : vrai si le niveau critique tient à autre chose que la seule mémoire du Mac (chaleur, batterie
    /// très faible…). La mémoire seule n'ajourne plus les Éclats planifiés : elle les espace (DotScheduler.autoBlocker).
    public func critiqueHorsMemoire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cur < 2 { return false }
        let parts: [String] = curMotif.components(separatedBy: ", ").filter { !$0.isEmpty }
        if parts.isEmpty { return true }
        return parts.contains { !$0.contains("mémoire") }
    }
    /// Multiplicateur de l'espacement des Éclats planifiés (non urgents). 31/10 : n'est plus lu par DotScheduler (facteurs réglables
    /// « dots_gouv_facteur_avert » / « dots_gouv_facteur_critique », plafond « dots_espacement_max_s ») ; gardé pour compatibilité.
    public func spacingFactor() -> Double {
        lock.lock(); defer { lock.unlock() }
        if cur >= 2 { return 6 }
        if cur == 1 { return 3 }
        return 1
    }
    public func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let lv: String = PerfGovernor.names[max(0, min(2, cur))]
        var effets: String = "aucun frein"
        if cur == 1 { effets = "Éclats planifiés espacés (×1,5 par défaut, plafond 45 min), tri du Fil espacé (≥ 30 s)" }
        if cur >= 2 { effets = "Éclats planifiés espacés ×3 si la cause est la mémoire seule, sinon différés ; tri du Fil espacé (≥ 90 s)" }
        return ["niveau": lv, "motif": curMotif, "depuis": since, "effets": effets, "mesure_a": lastAt, "mesures": lastSample,
                "actif": started, "source": "mesures natives : thermalState, host_processor_info, kern.memorystatus_vm_pressure_level (Mac entier), task_info phys_footprint (Nova, info), pmset"]
    }

    /// Une mesure brute : niveau 0…2, motifs lisibles (stables, sans chiffre qui varie), valeurs lues.
    func measure() -> (Int, [String], [String: Any]) {
        var lv: Int = 0
        var motifs: [String] = []
        var info: [String: Any] = [:]
        #if os(macOS)
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: info["thermique"] = "nominal"
        case .fair: info["thermique"] = "modéré"
        case .serious: info["thermique"] = "élevé"; lv = max(lv, 1); motifs.append("Mac chaud (état thermique élevé)")
        case .critical: info["thermique"] = "critique"; lv = max(lv, 2); motifs.append("Mac très chaud (état thermique critique)")
        @unknown default: break
        }
        var pressure: Int32 = 0
        var size: Int = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0 {
            info["pression_memoire"] = pressure == 4 ? "critique" : (pressure == 2 ? "avertissement" : "normale")
            // 31/10 (voix/mémoire/Live) : ce niveau est celui du Mac ENTIER (noyau macOS), pas de Nova — le motif le dit.
            if pressure == 2 { lv = max(lv, 1); motifs.append("mémoire du Mac sous pression") }
            if pressure == 4 { lv = max(lv, 2); motifs.append("mémoire du Mac en pression critique") }
        }
        // 31/10 (voix/mémoire/Live) : empreinte RÉELLE de Nova (phys_footprint, la valeur du Moniteur d'activité) et RAM du Mac,
        // lues pour le diagnostic seulement — elles ne changent pas le niveau. Permet de dire si la pression vient de Nova.
        var vmInfo: task_vm_info_data_t = task_vm_info_data_t()
        var vmCount: mach_msg_type_number_t = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &vmInfo) { (ptr: UnsafeMutablePointer<task_vm_info_data_t>) -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { (ip: UnsafeMutablePointer<integer_t>) -> kern_return_t in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), ip, &vmCount)
            }
        }
        if kr == KERN_SUCCESS { info["nova_memoire_mo"] = Int(vmInfo.phys_footprint / 1_048_576) }
        info["mac_ram_mo"] = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        if ProcessInfo.processInfo.isLowPowerModeEnabled { info["economie_energie"] = true; lv = max(lv, 1); motifs.append("mode économie d'énergie") }
        // Batterie : sous-processus pmset au plus toutes les 2 min (cache).
        lock.lock(); let battOld: Bool = Date().timeIntervalSince(batteryAt) > 120; lock.unlock()
        if battOld {
            let out: String = runProcess("/usr/bin/pmset", ["-g", "batt"], timeout: 4).1
            var pct: Int = -1
            if let m = SystemInfo.rx(#"(\d+)%"#, out), m.count > 1 { pct = Int(m[1]) ?? -1 }
            let onBatt: Bool = out.contains("Battery Power")
            lock.lock(); batteryAt = Date(); batteryPct = pct; onBattery = onBatt; lock.unlock()
        }
        lock.lock(); let bp: Int = batteryPct; let ob: Bool = onBattery; lock.unlock()
        if bp >= 0 {
            info["batterie_pct"] = bp
            info["sur_batterie"] = ob
            if ob && bp <= 10 { lv = max(lv, 2); motifs.append("batterie très faible") }
            else if ob && bp <= 20 { lv = max(lv, 1); motifs.append("batterie faible") }
        }
        #endif
        let cpu: Double = SystemInfo.cpuLoadPercent()
        if cpu >= 0 {
            info["cpu_pct"] = (cpu * 10).rounded() / 10
            if cpu >= 90 { lv = max(lv, 1); motifs.append("CPU saturé (≥ 90 %)") }
        }
        return (lv, motifs, info)
    }

    func sample() {
        let m: (Int, [String], [String: Any]) = measure()
        let raw: Int = m.0
        lock.lock()
        lastSample = m.2
        lastAt = nowISO()
        let before: Int = cur
        if raw > cur {
            downCount = 0
            upCount += 1
            if upCount >= 2 || raw == 2 { cur = raw; upCount = 0; since = nowISO(); curMotif = m.1.joined(separator: ", ") }
        } else if raw < cur {
            upCount = 0
            downCount += 1
            if downCount >= 4 { cur -= 1; downCount = 0; since = nowISO(); if cur == 0 { curMotif = "" } }
        } else {
            upCount = 0; downCount = 0
            if raw > 0 { curMotif = m.1.joined(separator: ", ") }
        }
        let after: Int = cur
        let motifNow: String = curMotif
        lock.unlock()
        if after != before {
            let why: String = "gouverneur de performance : " + PerfGovernor.names[before] + " → " + PerfGovernor.names[after] + (motifNow.isEmpty ? "" : " (" + motifNow + ")")
            _ = BlackBox.record(["tool": "perf", "actor": "Nova", "why": why, "ok": true, "effect": "lecture"])
        }
    }

    /// Espace le tri du Fil (cerveau sur les arrivées) quand le Mac est sous contrainte. Bloque la file sérielle
    /// appelante au plus 90 s ; sans contrainte, ne fait que noter l'heure du tri.
    public func paceFeedTri() {
        let lv: String = level()
        let minGap: Double = lv == PerfGovernor.critique ? 90 : (lv == PerfGovernor.tendu ? 30 : 0)
        if minGap > 0 {
            lock.lock(); let last: Date = lastTriAt; lock.unlock()
            let wait: Double = minGap - Date().timeIntervalSince(last)
            if wait > 0 { Thread.sleep(forTimeInterval: min(wait, minGap)) }
        }
        lock.lock(); lastTriAt = Date(); lock.unlock()
    }
}

// MARK: - (D) Mémoire du chat : seulement les faits PERTINENTS (VAGUE 2 FIABILITÉ, 24/10)
//
// Constat : promptItems(query:) injectait les 15 faits les plus récents + 10 « trouvés » (un seul mot commun
// suffisait), soit ~22 faits à CHAQUE réponse, quelle que soit la question — d'où la puce « 22 souvenirs ».
// Le chat utilise désormais chatItems(query:) : faits dont le score dépasse un seuil (mots significatifs communs
// et/ou similarité sémantique sur vecteurs déjà calculés), 8 au plus, + au plus 2 faits appris dans les 6
// dernières heures (continuité d'un sujet en cours). Le profil reste servi par son bloc stable (inchangé) ;
// tous les autres faits restent accessibles par l'outil recall. promptItems/promptBlock (Dots, Conseil…) inchangés.
extension Memory {
    static let chatStop: Set<String> = ["les", "des", "une", "est", "que", "qui", "quoi", "pour", "par", "pas", "plus", "avec", "dans", "sur", "sous", "mais",
                                        "mon", "ton", "son", "mes", "tes", "ses", "nos", "vos", "leur", "leurs", "ce", "cet", "cette", "ces", "moi", "toi",
                                        "nous", "vous", "ils", "elles", "elle", "lui", "aux", "du", "au", "et", "ou", "en", "un", "le", "la", "je", "tu",
                                        "il", "on", "ne", "se", "sa", "ta", "ma", "fait", "faire", "fais", "peux", "veux", "dois", "peut", "faut", "tout",
                                        "tous", "toute", "toutes", "bien", "tres", "comme", "quand", "comment", "quel", "quelle", "quels", "quelles",
                                        "est-ce", "estce", "avoir", "etre", "suis", "sont", "ont", "donc", "alors", "aussi", "encore", "deja",
                                        "nova", "stp", "merci", "bonjour", "salut", "oui", "non", "the", "and", "for", "you", "what", "how"]
    static func foldChat(_ s: String) -> String {
        return s.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
    }
    static func chatWords(_ q: String) -> [String] {
        let parts: [String] = foldChat(q).components(separatedBy: CharacterSet.alphanumerics.inverted)
        var out: [String] = []
        for p in parts where p.count >= 3 && !chatStop.contains(p) && !out.contains(p) { out.append(p) }
        return out
    }

    public func chatItems(query: String, maxRelevant: Int = 8, maxFresh: Int = 2) -> [[String: Any]] {
        if isOff { return [] }
        warmAllOnce()
        let all: [[String: Any]] = list().filter { (m: [String: Any]) -> Bool in
            (m["forgiven"] as? Bool) != true && (m["kind"] as? String) != "profil" && !(((m["text"] as? String) ?? "").isEmpty)
        }
        if all.isEmpty { return [] }
        var out: [[String: Any]] = []
        var seen: Set<String> = []
        let q: String = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let words: [String] = Memory.chatWords(q)
        if !q.isEmpty {
            var qv: [Double]? = nil
            #if canImport(NaturalLanguage)
            if all.count <= 800 { qv = Memory.vec(q) }
            #endif
            let needLex: Int = words.count <= 2 ? 1 : 2
            var scored: [(Double, [String: Any])] = []
            for m in all {
                let raw: String = (m["text"] as? String) ?? ""
                let low: String = Memory.foldChat(raw)
                var lex: Int = 0
                for w in words where low.contains(w) { lex += 1 }
                let sem: Double = Memory.semanticCached(qv, raw)
                var score: Double = 0
                if lex >= needLex { score = Double(lex) + sem }
                else if lex >= 1 && sem >= 0.5 { score = Double(lex) + sem }
                else if sem >= 0.66 { score = sem }
                if score > 0 { scored.append((score, m)) }
            }
            scored.sort { (a: (Double, [String: Any]), b: (Double, [String: Any])) -> Bool in a.0 > b.0 }
            for e in scored.prefix(maxRelevant) {
                let id: String = (e.1["id"] as? String) ?? ""
                if !id.isEmpty { seen.insert(id) }
                out.append(e.1)
            }
        }
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        var fresh: Int = 0
        for m in all.reversed() {
            if fresh >= maxFresh { break }
            guard let ts = m["ts"] as? String, let d = iso.date(from: ts) else { continue }
            if Date().timeIntervalSince(d) > 6 * 3600 { break }
            let id: String = (m["id"] as? String) ?? ""
            if !id.isEmpty && seen.contains(id) { continue }
            if !id.isEmpty { seen.insert(id) }
            out.append(m)
            fresh += 1
        }
        return out
    }
}
