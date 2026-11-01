import Foundation
import NovaFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// 31/10 (Algolia biblio) : BIBLIOTHÈQUE UNIQUE « nova-bibliotheque » (demande d'Ahadi du 31/10, périmètre « Mac sauf sensible »).
// Toutes les bibliothèques de Nova + les fichiers du Mac (hors finances et secrets) versés dans UN index Algolia, champ « source »
// (memoire, cafu, fundings, savoir, competences, projets, briefs, dossiers, mac) en facette, interrogeable par TOUS les cerveaux
// via les outils « bibliotheque » et « lire_fichier_bibliotheque » (Tools.swift).
// Règles :
//  - enregistrements ≤ 8 Ko (morceaux : titre, chemin, date, type, numéro de morceau) ; objectID stable = FNV-1a(chemin) + "-" + morceau ;
//  - ingestion INCRÉMENTALE (état : <données Nova>/algolia_biblio.json, signature mtime-taille ou empreinte du texte) ; suppression des
//    enregistrements des fichiers disparus ou devenus exclus — seulement si la source a été parcourue EN ENTIER (jamais sur un dossier
//    refusé par macOS, un plafond atteint ou une passe interrompue) ;
//  - envois par lots de 50 avec pause de 1,5 s ; plafond par passe (réglage algolia_plafond_par_passe, 2 000 par défaut) ;
//  - tâche de fond basse priorité (Thread .background), au plus une passe par heure, jamais dans les 10 min qui suivent un message du
//    chat, jamais quand PerfGovernor est en tension critique, jamais disjoncteur ouvert ; première passe ≥ 10 min après le démarrage ;
//  - iCloud : un fichier non local (ubiquitousItemDownloadingStatus ≠ current, ou « dataless ») n'est JAMAIS lu (aucun téléchargement) ;
//  - EXCLUSIONS SENSIBLES (Ahadi : « mots de passe et finances restent chez moi ») : mots du chemin (sans accents, insensible à la casse),
//    extensions de clés, chemins d'identifiants, puis contrôle du CONTENU (IBAN mod 97, carte Luhn, clé privée, clés d'API, mot de passe).
//    Seuls des COMPTES par motif sont journalisés (releves/diag/algolia_mac_etat.json), jamais un contenu ni un nom de fichier.
//  - aucune valeur de clé n'est écrite nulle part (seulement présence / statut HTTP).
public enum AlgoliaBiblio {
    public static let index: String = "nova-bibliotheque"
    static let stateFile: JSONFile = JSONFile("algolia_biblio.json")
    static let root: String = NSHomeDirectory() + "/spark-local/Nova2"
    static let diagDir: String = NSHomeDirectory() + "/spark-local/Nova2/releves/diag"
    static let maxRecordBytes: Int = 8000
    static let chunkBytes: Int = 6200
    static let maxChunksPerFile: Int = 40
    static let maxFileBytes: Int = 20 * 1024 * 1024
    static let maxEntriesPerRoot: Int = 40000
    static let batchSize: Int = 50
    static let passInterval: TimeInterval = 3600
    static let chatQuiet: TimeInterval = 600
    static let sources: [String] = ["memoire", "cafu", "fundings", "savoir", "competences", "projets", "briefs", "dossiers", "mac"]
    static let defaultMacDirs: [String] = ["~/Documents", "~/Desktop", "~/Downloads", "~/Library/Mobile Documents/com~apple~CloudDocs"]
    static let lock: NSLock = NSLock()
    nonisolated(unsafe) static var running: Bool = false
    nonisolated(unsafe) static var lastPassAt: Date = Date.distantPast
    nonisolated(unsafe) static var lastDiagAt: Date = Date.distantPast
    nonisolated(unsafe) static var bootAt: Date? = nil

    struct Doc {
        let key: String        // chemin absolu, ou nova://<source>/<id>
        let source: String
        let type: String
        let title: String
        let mtime: Double
        let sig: String
        let load: () -> String?
    }

    // MARK: outils communs

    static func fnv(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
    static func fold(_ s: String) -> String {
        return s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).lowercased()
    }
    static func tokens(_ s: String) -> [String] {
        return fold(s).split(whereSeparator: { (c: Character) -> Bool in !(c.isLetter || c.isNumber) }).map { (x: Substring) -> String in String(x) }
    }
    static func expand(_ p: String) -> String {
        let h: String = NSHomeDirectory()
        let e: String = p.hasPrefix("~") ? h + String(p.dropFirst()) : p
        return (e as NSString).standardizingPath
    }
    static func display(_ p: String) -> String {
        let h: String = NSHomeDirectory()
        return p.hasPrefix(h + "/") ? "~" + String(p.dropFirst(h.count)) : p
    }
    static func isoTime(_ ts: String) -> Double {
        if ts.isEmpty { return 0 }
        if let d = ISO8601DateFormatter().date(from: ts) { return d.timeIntervalSince1970 }
        if let d = ISO8601DateFormatter().date(from: String(ts.prefix(19)) + "Z") { return d.timeIntervalSince1970 }
        return 0
    }
    static func dateString(_ t: Double) -> String {
        if t <= 0 { return "" }
        let f: ISO8601DateFormatter = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.string(from: Date(timeIntervalSince1970: t))
    }
    static func normalize(_ raw: String) -> String {
        var t: String = String(raw.prefix(400_000))
        t = t.replacingOccurrences(of: "\r\n", with: "\n")
        t = t.replacingOccurrences(of: "[ \\t\\u00A0]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\n[ ]*\\n[\\n ]*", with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func confiance(_ src: String) -> String {
        switch src {
        case "mac": return "document du Mac d'Ahadi (fichier local, non vérifié)"
        case "cafu": return "livrable CAFU de Nova — faits à revérifier avant reprise"
        case "memoire": return "mémoire de Nova (fait retenu, daté)"
        case "savoir": return "document indexé du savoir de Nova"
        case "competences": return "méthode de la maison (skill)"
        default: return "magasin interne de Nova (" + src + ")"
        }
    }

    // MARK: exclusions sensibles

    static let stemTerms: [String] = ["financ", "banque", "bancaire", "bank", "brvm", "portefeuille", "portfolio", "bourse", "releve", "impot",
                                      "salaire", "payslip", "factur", "invoice", "iban", "passeport", "passport", "identite", "password", "motdepasse",
                                      "secret", "credential", "token", "wallet", "crypto", "keychain"]
    static let exactTerms: Set<String> = ["sgi", "tax", "taxe", "taxes", "paie", "rib", "cni", "permis", "mdp", "pwd", "seed", "seeds"]
    static let phraseTerms: [[String]] = [["carte", "bancaire"], ["credit", "card"], ["mot", "de", "passe"], ["mots", "de", "passe"], ["id", "card"]]
    static let sensitiveExts: Set<String> = ["key", "pem", "p12", "pfx", "kdbx", "keychain", "keychain-db", "ovpn", "env", "ppk", "gpg", "asc", "jks", "keystore"]

    static func extras() -> [String] { return Settings().get("algolia_exclusions_supp", [String]()) }

    static func hasSeq(_ tk: [String], _ ph: [String]) -> Bool {
        if ph.isEmpty || tk.count < ph.count { return false }
        var i: Int = 0
        while i + ph.count <= tk.count {
            if Array(tk[i..<(i + ph.count)]) == ph { return true }
            i += 1
        }
        return false
    }

    /// Mot sensible dans un chemin, un nom ou un texte court : le terme trouvé (compté), sinon nil.
    static func termHit(_ s: String, extra: [String]) -> String? {
        let tk: [String] = tokens(s)
        if tk.isEmpty { return nil }
        for t in tk {
            if exactTerms.contains(t) { return t }
            for st in stemTerms where t.hasPrefix(st) { return st }
        }
        for ph in phraseTerms where hasSeq(tk, ph) { return ph.joined(separator: " ") }
        for e in extra {
            let et: [String] = tokens(e)
            if et.count > 1 { if hasSeq(tk, et) { return "supp:" + et.joined(separator: " ") } }
            else if let w = et.first {
                for t in tk where t == w || (w.count >= 4 && t.hasPrefix(w)) { return "supp:" + w }
            }
        }
        return nil
    }

    static let contentRules: [(String, NSRegularExpression)] = SecretsGuard.rules.compactMap { (r: SecretRule) -> (String, NSRegularExpression)? in
        guard let rx = try? NSRegularExpression(pattern: r.pattern, options: r.ci ? [.caseInsensitive] : []) else { return nil }
        return (r.name, rx)
    }

    /// Contrôle du CONTENU avant envoi : nom du motif trouvé (IBAN, carte, clé privée, clé d'API, mot de passe…), sinon nil.
    static func contentHit(_ s: String) -> String? {
        if s.isEmpty { return nil }
        let ns: NSString = s as NSString
        let full: NSRange = NSRange(location: 0, length: ns.length)
        for (n, rx) in contentRules where rx.firstMatch(in: s, options: [], range: full) != nil { return n }
        for m in SecretsGuard.ibanRx.matches(in: s, options: [], range: full) where SecretsGuard.ibanOK(ns.substring(with: m.range)) { return "iban" }
        for m in SecretsGuard.cardRx.matches(in: s, options: [], range: full) where SecretsGuard.luhnOK(ns.substring(with: m.range)) { return "carte_luhn" }
        return nil
    }

    // MARK: extraction du texte

    static let docExts: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "html", "htm", "rtf", "rtfd", "doc", "docx", "pages", "odt", "pdf", "xlsx", "pptx"]
    static let skipDirNames: Set<String> = ["node_modules", "build", "deriveddata", "caches", "cache", "library", "applications", "pods", "vendor",
                                            "venv", "__pycache__", "site-packages", "dist", "target", "backups", "nova-pj"]
    static let packageDocExts: Set<String> = ["rtfd", "pages"]

    /// Texte d'un document. RTF/DOC/ODT/RTFD : textutil (moteur NSAttributedString de macOS, dans un processus séparé : un document
    /// corrompu ne peut pas faire tomber Nova) ; DOCX : XML Word puis textutil ; PDF : PDFKit ; XLSX : texte partagé + 1re feuille
    /// (sinon ignoré) ; PPTX : texte des diapositives ; PAGES : aperçu PDF intégré s'il existe (sinon ignoré).
    static func fileText(_ path: String, ext: String) -> String? {
        switch ext {
        case "txt", "md", "markdown", "csv", "tsv", "json": return PiecesJointes.plainText(path)
        case "html", "htm":
            guard let s = PiecesJointes.plainText(path) else { return nil }
            return Tools.htmlToText(s, limit: 400_000)
        case "pdf": return PiecesJointes.pdfText(path)
        case "docx": return PiecesJointes.docxText(path)
        case "rtf", "rtfd", "doc", "odt": return PiecesJointes.textutilText(path)
        case "pages": return pagesText(path)
        case "xlsx": return PiecesJointes.xlsxText(path)
        case "pptx": return pptxText(path)
        default: return nil
        }
    }
    static func pptxText(_ path: String) -> String? {
        let r: (Int32, String) = runProcess("/usr/bin/unzip", ["-p", path, "ppt/slides/slide*.xml"], timeout: 30)
        guard r.0 == 0, !r.1.isEmpty else { return nil }
        var t: String = r.1.replacingOccurrences(of: "</a:p>", with: "\n").replacingOccurrences(of: "</p:sld>", with: "\n\n")
        t = PiecesJointes.xmlEntities(PiecesJointes.stripTags(t))
        return t
    }
    static func pagesText(_ path: String) -> String? {
        let fm: FileManager = FileManager.default
        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: path, isDirectory: &isDir)
        if isDir.boolValue {
            let p: String = path + "/QuickLook/Preview.pdf"
            return fm.fileExists(atPath: p) ? PiecesJointes.pdfText(p) : nil
        }
        let tmp: String = NSTemporaryDirectory() + "nova-biblio-" + UUID().uuidString + ".pdf"
        defer { try? fm.removeItem(atPath: tmp) }
        let r: (Int32, String) = runProcess("/bin/sh", ["-c", "/usr/bin/unzip -p \"$1\" QuickLook/Preview.pdf > \"$2\" 2>/dev/null", "sh", path, tmp], timeout: 30)
        let sz: Int = ((try? fm.attributesOfItem(atPath: tmp))?[.size] as? NSNumber)?.intValue ?? 0
        guard r.0 == 0, sz > 0 else { return nil }
        return PiecesJointes.pdfText(tmp)
    }

    /// Découpe en morceaux de ≤ maxBytes octets UTF-8, de préférence aux fins de ligne.
    static func splitText(_ t: String, maxBytes: Int) -> [String] {
        var out: [String] = []
        var cur: String = ""
        var curBytes: Int = 0
        for para in t.components(separatedBy: "\n") {
            if out.count >= maxChunksPerFile { break }
            let p: String = para + "\n"
            let pb: Int = p.utf8.count
            if curBytes + pb > maxBytes && !cur.isEmpty { out.append(cur); cur = ""; curBytes = 0 }
            if pb > maxBytes {
                for ch in p {
                    let cb: Int = String(ch).utf8.count
                    if curBytes + cb > maxBytes { out.append(cur); cur = ""; curBytes = 0; if out.count >= maxChunksPerFile { break } }
                    cur.append(ch)
                    curBytes += cb
                }
            } else {
                cur += p
                curBytes += pb
            }
        }
        if out.count < maxChunksPerFile && !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(cur) }
        return out
    }

    static func record(_ d: Doc, chunk: String, index i: Int, total n: Int) -> [String: Any] {
        let isFile: Bool = d.key.hasPrefix("/")
        var r: [String: Any] = ["objectID": fnv(d.key) + "-" + String(i), "source": d.source, "type": d.type,
                                "title": String(d.title.prefix(200)), "chemin": String(display(d.key).prefix(500)), "date": dateString(d.mtime),
                                "mtime": Int(d.mtime), "morceau": i + 1, "morceaux": n, "confiance": confiance(d.source),
                                "text": chunk.trimmingCharacters(in: .whitespacesAndNewlines), "genere": isGenerated(d.title)]   // 31/10 (biblio 4) : fichier produit automatiquement (scan_*, draft_bulletin_*, exports JSON) — se remplit au fil des versements
        if isFile { r["url"] = "file://" + String(d.key.prefix(500)) }
        var t: String = (r["text"] as? String) ?? ""
        while jsonData(r).count > maxRecordBytes && t.count > 200 {
            t = String(t.prefix(t.count * 4 / 5))
            r["text"] = t
        }
        return r
    }
    static func deletes(_ key: String, from a: Int, to b: Int) -> [[String: Any]] {
        if b <= a { return [] }
        return (a..<b).map { (i: Int) -> [String: Any] in ["action": "deleteObject", "body": ["objectID": fnv(key) + "-" + String(i)]] }
    }

    // MARK: sources Nova (magasins JSON)

    static func flatten(_ v: Any, depth: Int = 0) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let a = v as? [Any] {
            let parts: [String] = a.prefix(80).map { (x: Any) -> String in flatten(x, depth: depth + 1) }.filter { (s: String) -> Bool in !s.isEmpty }
            return parts.joined(separator: depth == 0 ? "\n" : " ; ")
        }
        if let o = v as? [String: Any], depth < 4 {
            var lines: [String] = []
            for k in o.keys.sorted() {
                guard let x = o[k] else { continue }
                let t: String = flatten(x, depth: depth + 1)
                if !t.isEmpty { lines.append(k + " : " + t) }
            }
            return lines.joined(separator: "\n")
        }
        return ""
    }
    static func pickTitle(_ o: [String: Any]) -> String {
        for k in ["titre", "title", "nom", "name", "programme", "label", "objet", "sujet", "id"] {
            if let s = o[k] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return String(s.prefix(160)) }
        }
        return "(sans titre)"
    }
    static func pickTime(_ o: [String: Any]) -> Double {
        for k in ["maj", "updated", "updated_at", "ts", "at", "date", "cree", "created"] {
            if let s = o[k] as? String { let t: Double = isoTime(s); if t > 0 { return t } }
        }
        return 0
    }

    static func memoryDocs(_ p: BiblioPass) -> [Doc] {
        var out: [Doc] = []
        for m in JSONFile("memoire.json").read(default: [[String: Any]]()) {
            let t: String = (m["text"] as? String) ?? ""
            if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if Memory.isSensitive(t) { p.exclude("memoire", "memoire_sensible"); continue }
            if let h = termHit(t, extra: p.extra) { p.exclude("memoire", "mot:" + h); continue }
            let ts: String = (m["ts"] as? String) ?? ""
            let id: String = (m["id"] as? String) ?? fnv(t)
            var body: String = t
            if !ts.isEmpty { body += "\n(retenu le " + String(ts.prefix(10)) + ")" }
            if let s = m["source"] as? String, !s.isEmpty { body += "\nsource : " + s }
            let fixed: String = body
            out.append(Doc(key: "nova://memoire/" + id, source: "memoire", type: "fait", title: String(t.prefix(90)),
                           mtime: isoTime(ts), sig: fnv(fixed), load: { () -> String? in fixed }))
        }
        return out
    }

    /// Éléments d'un magasin JSON → documents. bodyTerms : les mots sensibles sont aussi cherchés dans le texte (pas seulement le titre).
    static func itemDocs(_ src: String, type: String, items: [[String: Any]], bodyTerms: Bool, p: BiblioPass) -> [Doc] {
        var out: [Doc] = []
        for it in items.prefix(3000) {
            let title: String = pickTitle(it)
            let body: String = String(flatten(it).prefix(80_000))
            if body.count < 20 { continue }
            if let h = termHit(title, extra: p.extra) { p.exclude(src, "nom:" + h); continue }
            if bodyTerms, let h = termHit(body, extra: p.extra) { p.exclude(src, "mot:" + h); continue }
            var id: String = (it["id"] as? String) ?? ((it["id"] as? NSNumber)?.stringValue ?? "")
            if id.isEmpty { id = fnv(title + "|" + String(body.prefix(300))) }
            let fixed: String = title + "\n" + body
            out.append(Doc(key: "nova://" + src + "/" + id, source: src, type: type, title: title, mtime: pickTime(it),
                           sig: fnv(fixed), load: { () -> String? in fixed }))
        }
        return out
    }

    static func skillDocs(_ p: BiblioPass) -> [Doc] {
        var out: [Doc] = []
        let fm: FileManager = FileManager.default
        let dir: String = NovaSkills.dir.path
        for n in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() {
            if n.hasPrefix("_") || n.hasPrefix(".") { continue }
            let path: String = dir + "/" + n + "/SKILL.md"
            guard let at = try? fm.attributesOfItem(atPath: path) else { continue }
            if let h = termHit(n, extra: p.extra) { p.exclude("competences", "nom:" + h); continue }
            let mt: Double = (at[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let sz: Int = (at[.size] as? NSNumber)?.intValue ?? 0
            out.append(Doc(key: path, source: "competences", type: "skill", title: n, mtime: mt, sig: String(Int(mt)) + "-" + String(sz),
                           load: { () -> String? in PiecesJointes.plainText(path) }))
        }
        return out
    }

    static func novaDocs(_ src: String, p: BiblioPass) -> [Doc] {
        switch src {
        case "memoire": return memoryDocs(p)
        case "competences": return skillDocs(p)
        case "fundings":
            let o: [String: Any] = JSONFile("fundings_campaign.json").read(default: [String: Any]())
            return itemDocs("fundings", type: "programme", items: (o["programmes"] as? [[String: Any]]) ?? [], bodyTerms: false, p: p)
        case "projets":
            let o: [String: Any] = JSONFile("projects.json").read(default: [String: Any]())
            return itemDocs("projets", type: "projet", items: (o["items"] as? [[String: Any]]) ?? [], bodyTerms: true, p: p)
        case "briefs":
            return itemDocs("briefs", type: "brief", items: JSONFile("briefs.json").read(default: [[String: Any]]()), bodyTerms: true, p: p)
        case "dossiers":
            let o: [String: Any] = JSONFile("dossiers.json").read(default: [String: Any]())
            return itemDocs("dossiers", type: "dossier", items: (o["items"] as? [[String: Any]]) ?? [], bodyTerms: true, p: p)
        default: return []
        }
    }

    // MARK: sources fichiers (cafu, savoir, mac)

    static func macDirs() -> [String] {
        let raw: [String] = Settings().get("algolia_mac_dossiers", defaultMacDirs)
        let h: String = NSHomeDirectory()
        var out: [String] = []
        for r in raw {
            let p: String = expand(r)
            guard p.hasPrefix(h + "/"), !SecretsGuard.isSensitiveRoot(p), !out.contains(p) else { continue }
            out.append(p)
        }
        return out
    }
    static func savoirDirs(excluding mac: [String]) -> [String] {
        let raw: [String] = Settings().get("knowledge_roots", ["~/spark-local", "~/bionic-app"])
        let h: String = NSHomeDirectory()
        var out: [String] = []
        for r in raw {
            let p: String = expand(r)
            guard p.hasPrefix(h + "/"), !SecretsGuard.isSensitiveRoot(p), !out.contains(p) else { continue }
            if mac.contains(where: { (m: String) -> Bool in p == m || p.hasPrefix(m + "/") || m.hasPrefix(p + "/") }) { continue }
            out.append(p)
        }
        return out
    }

    #if os(macOS)
    static let resKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .fileAllocatedSizeKey,
                                            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
    #else
    static let resKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
    #endif

    /// Parcourt les racines d'une source fichier ; vrai si TOUTES les racines lisibles ont été parcourues en entier.
    static func scanFiles(_ src: String, roots: [String], exts: Set<String>, knowledgeRules: Bool, guardNova: Bool, p: BiblioPass) -> Bool {
        let fm: FileManager = FileManager.default
        var complete: Bool = true
        let resolvedRoots: [String] = roots.map { (r: String) -> String in URL(fileURLWithPath: r).resolvingSymlinksInPath().path }
        for (ri, r) in roots.enumerated() {
            if p.stopped { return false }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: r, isDirectory: &isDir), isDir.boolValue else { p.bump(src, "dossier_absent"); continue }
            guard (try? fm.contentsOfDirectory(atPath: r)) != nil else {
                p.bump(src, "dossier_refuse_macos"); p.rootErrors.append(display(r)); complete = false; continue
            }
            let others: Set<String> = Set(resolvedRoots.enumerated().filter { (e: (offset: Int, element: String)) -> Bool in e.offset != ri }.map { (e: (offset: Int, element: String)) -> String in e.element })
            guard let en = fm.enumerator(at: URL(fileURLWithPath: r), includingPropertiesForKeys: resKeys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { (_: URL, _: Error) -> Bool in true }) else {
                complete = false; continue
            }
            var entries: Int = 0
            while let obj = en.nextObject() {
                if p.stopped { return false }
                guard let u = obj as? URL else { continue }
                entries += 1
                if entries > maxEntriesPerRoot { p.bump(src, "plafond_parcours"); complete = false; break }
                let path: String = u.path
                let rel: String = path.hasPrefix(r) ? String(path.dropFirst(r.count)) : path
                let name: String = u.lastPathComponent
                let ext: String = u.pathExtension.lowercased()
                let rv: URLResourceValues? = try? u.resourceValues(forKeys: Set(resKeys))
                let isDirectory: Bool = rv?.isDirectory ?? false
                var isPkg: Bool = false
                var notLocal: Bool = false
                #if os(macOS)
                isPkg = rv?.isPackage ?? false
                if rv?.isUbiquitousItem == true, let s = rv?.ubiquitousItemDownloadingStatus, s != URLUbiquitousItemDownloadingStatus.current { notLocal = true }
                if (rv?.fileSize ?? 0) > 0, (rv?.fileAllocatedSize ?? 1) == 0 { notLocal = true }
                #endif
                if isDirectory && !isPkg {
                    if skipDirNames.contains(name.lowercased()) || name.hasPrefix(".") || name.hasPrefix("_") { en.skipDescendants(); continue }
                    if ["app", "photoslibrary", "musiclibrary", "tvlibrary", "bundle", "framework", "xcodeproj", "xcworkspace", "xcarchive", "sparsebundle"].contains(ext) { en.skipDescendants(); continue }
                    if guardNova && SecretsGuard.isSensitiveRoot(path) { p.exclude(src, "chemin_identifiants"); en.skipDescendants(); continue }
                    if knowledgeRules && !Knowledge.allowedDir(path) { en.skipDescendants(); continue }
                    if others.contains(u.resolvingSymlinksInPath().path) { en.skipDescendants(); continue }   // même dossier vu par deux racines (iCloud Bureau/Documents)
                    if let h = termHit(name, extra: p.extra) { p.exclude(src, "nom:" + h); en.skipDescendants(); continue }
                    continue
                }
                if isDirectory && isPkg && !packageDocExts.contains(ext) { continue }
                if sensitiveExts.contains(ext) { p.exclude(src, "extension:" + ext); continue }
                guard exts.contains(ext) else { continue }
                if SecretsGuard.isCredentialPath(path) { p.exclude(src, "chemin_identifiants"); continue }
                if knowledgeRules && !Knowledge.allowedScan(path, probe: path) { continue }
                if let h = termHit(rel, extra: p.extra) { p.exclude(src, "nom:" + h); continue }
                if notLocal { p.bump(src, "icloud_non_local"); continue }
                let size: Int = rv?.fileSize ?? 0
                if size > maxFileBytes { p.bump(src, "trop_gros"); continue }
                let mt: Double = rv?.contentModificationDate?.timeIntervalSince1970 ?? 0
                let fixedPath: String = path
                let fixedExt: String = ext
                p.process(Doc(key: path, source: src, type: ext, title: name, mtime: mt, sig: String(Int(mt)) + "-" + String(size),
                              load: { () -> String? in AlgoliaBiblio.fileText(fixedPath, ext: fixedExt) }))
            }
        }
        return complete && !p.stopped
    }

    // MARK: réseau

    static func call(_ method: String, app: String, key: String, path: String, body: [String: Any]?, timeout: TimeInterval) -> (Int, Data) {
        guard let u = URL(string: "https://" + app + "-dsn.algolia.net" + path) else { return (0, Data()) }
        var rq: URLRequest = URLRequest(url: u)
        rq.httpMethod = method
        rq.setValue(app, forHTTPHeaderField: "X-Algolia-Application-Id")
        rq.setValue(key, forHTTPHeaderField: "X-Algolia-API-Key")
        rq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let b = body { rq.httpBody = jsonData(b) }
        return syncGet(rq, timeout: timeout)
    }

    static func ensureSettings(app: String, admin: String) -> Bool {
        // 31/10 (biblio 4) : TITRE (nom de fichier) puis chemin, puis texte ; le critère « attribute » passe avant la proximité ;
        // la date (customRanking) ne départage plus qu'à pertinence égale (critère « custom » en dernier) ; noms en CamelCase découpés.
        let body: [String: Any] = ["searchableAttributes": ["unordered(title)", "unordered(chemin)", "text"],
                                   "attributesForFaceting": ["searchable(source)", "type", "filterOnly(genere)"],
                                   "attributesToSnippet": ["text:60"],
                                   "ranking": ["words", "filters", "typo", "attribute", "proximity", "exact", "custom"],
                                   "customRanking": ["desc(mtime)"], "camelCaseAttributes": ["title"],
                                   "removeWordsIfNoResults": "allOptional", "ignorePlurals": ["fr", "en"],
                                   // 31/10 (biblio 3) : pertinence — langues FR/EN, mots vides retirés, UN résultat par fichier (distinct sur chemin)
                                   "queryLanguages": ["fr", "en"], "removeStopWords": ["fr", "en"], "attributeForDistinct": "chemin", "distinct": true,
                                   "typoTolerance": "min", "minWordSizefor1Typo": 4]
        let (st, d): (Int, Data) = call("PUT", app: app, key: admin, path: "/1/indexes/" + index + "/settings", body: body, timeout: 15)
        if st == 200 { Credits.count("algolia", n: 1); return true }
        if st > 0 { AlgoliaRelay.failed(status: st, detail: String(decoding: d.prefix(300), as: UTF8.self), op: "write", adminKey: true) }
        return false
    }

    /// Recherche dans nova-bibliotheque. hits nil = indisponible (raison dans err).
    static func query(_ q: String, source: String, k: Int, page: Int = 0, optionalWords: [String] = []) -> (hits: [[String: Any]]?, err: String) {   // 31/10 (biblio 4) : optionalWords (requête en langage naturel)   // 31/10 (biblio 2) : page + jusqu'à 100 résultats
        if Credits.isOpen("algolia") { return (nil, "disjoncteur Algolia ouvert (échecs récents)") }
        let c = AlgoliaRelay.creds(KeychainStore())
        if c.app.isEmpty { return (nil, "Application ID Algolia absent du Trousseau (nova-algolia-app)") }
        let useAdmin: Bool = c.search.isEmpty
        let key: String = useAdmin ? c.admin : c.search
        if key.isEmpty { return (nil, "aucune clé Algolia au Trousseau (nova-algolia-search)") }
        if useAdmin && AlgoliaRelay.searchDeniedForAdmin() { return (nil, "la clé d'écriture n'a pas le droit search : ajoute la Search-only key nova-algolia-search") }
        var body: [String: Any] = ["query": String(q.prefix(400)), "hitsPerPage": max(1, min(100, k)), "page": max(0, page),
                                   "attributesToRetrieve": ["title", "chemin", "date", "source", "type", "morceau", "morceaux", "url"],
                                   "attributesToSnippet": ["text:60"], "attributesToHighlight": [String](), "removeWordsIfNoResults": "allOptional"]
        if !source.isEmpty { body["filters"] = "source:" + source }
        if !optionalWords.isEmpty { body["optionalWords"] = optionalWords }
        let (st, d): (Int, Data) = AlgoliaRelay.request(app: c.app, key: key, path: "/1/indexes/" + index + "/query", body: body, timeout: 6)
        if st == 200 {
            Credits.count("algolia", n: 1, units: 1, unit: "requête")
            return ((parseJSON(d)?["hits"] as? [[String: Any]]) ?? [], "")
        }
        if st == 404 { return (nil, "index nova-bibliotheque pas encore créé (premier versement en attente)") }
        if st > 0 { AlgoliaRelay.failed(status: st, detail: String(decoding: d.prefix(300), as: UTF8.self), op: "search", adminKey: useAdmin) }
        if st == 403 && useAdmin { return (nil, "la clé d'écriture n'a pas le droit search : ajoute la Search-only key nova-algolia-search") }
        return (nil, st > 0 ? "HTTP " + String(st) : "Algolia injoignable (réseau)")
    }

    // MARK: 31/10 (biblio 4) : PERTINENCE — requête nettoyée, repli « mots optionnels », reclassement titre / nom de fichier,
    // fichiers générés pénalisés, regroupement des copies d'un même fichier. Mesure : releves/diag/biblio_eval.json (dormant/BIBLIO_EVAL).

    static let settingsVersion: Int = 4
    nonisolated(unsafe) static var evalRunning: Bool = false

    /// Mots de liaison et mots « de demande » retirés avant l'envoi à Algolia (formes repliées : sans accents, minuscules).
    static let fillerWords: Set<String> = [
        "fichier", "fichiers", "document", "documents", "doc", "docs", "lie", "lies", "liee", "liees", "relatif", "relatifs", "relative",
        "relatives", "concernant", "concerne", "propos", "sur", "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses", "notre", "nos",
        "boulot", "chez", "trouve", "trouver", "retrouve", "retrouver", "cherche", "chercher", "recherche", "rechercher", "montre", "montrer",
        "donne", "donner", "affiche", "afficher", "liste", "lister", "ouvre", "ouvrir", "tous", "toutes", "tout", "les", "des", "du", "de",
        "la", "le", "au", "aux", "pour", "avec", "et", "ou", "en", "dans", "un", "une", "qui", "que", "quoi", "ce", "ces", "cet", "cette",
        "moi", "je", "ai", "est", "sont", "stp", "svp", "please", "files", "file", "related", "relating", "regarding", "my", "me", "about",
        "find", "show", "the", "of", "at", "for", "to", "in", "with", "all", "any", "and", "or", "an"]
    /// Mots qui DEMANDENT des fichiers générés (aucune pénalité alors).
    static let generatedWords: Set<String> = ["scan", "scans", "veille", "bulletin", "bulletins", "draft", "drafts", "brouillon", "brouillons", "journal", "journaux", "json", "export", "exports"]
    static let generatedRx: NSRegularExpression? = try? NSRegularExpression(pattern: "^(scan_\\d{4}-\\d{2}-\\d{2}|draft_bulletin_|bulletin_\\d{4}|journal-\\d{4}-\\d{2}-\\d{2}|c-[0-9a-f]{6,}\\.json$|veille\\.json$)", options: [])
    static let sidecarRx: NSRegularExpression? = try? NSRegularExpression(pattern: "\\.(docx|pdf|md|html|txt|pptx|xlsx)\\.json$", options: [])

    static func rxHit(_ rx: NSRegularExpression?, _ s: String) -> Bool {
        guard let r = rx else { return false }
        return r.firstMatch(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
    /// Fichier produit automatiquement (scans et bulletins de veille, journaux datés, exports JSON, fiches .docx.json des livrables).
    static func isGenerated(_ title: String) -> Bool {
        let f: String = fold(title)
        return rxHit(generatedRx, f) || rxHit(sidecarRx, f)
    }
    static func cleanTokens(_ s: String) -> [String] {
        return tokens(s).filter { (t: String) -> Bool in !fillerWords.contains(t) && (t.count > 1 || t.first?.isNumber == true) }
    }
    /// Requête envoyée à Algolia : jetons utiles seulement ; si tout est retiré, la requête d'origine.
    static func cleanQuery(_ q: String) -> String {
        let kept: [String] = cleanTokens(q)
        return kept.isEmpty ? q.trimmingCharacters(in: .whitespacesAndNewlines) : kept.joined(separator: " ")
    }
    /// Jetons d'un nom de fichier ou d'un dossier (« UNICEF_CoverLetter.docx » → unicef, cover, letter, coverletter, docx).
    static func nameTokens(_ s: String) -> Set<String> {
        let spaced: String = s.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        return Set(tokens(spaced) + tokens(s))
    }
    /// Concepts de la requête : chaque concept = ses formes équivalentes (suites de jetons), d'après les synonymes.
    static func concepts(_ cleaned: String) -> [[[String]]] {
        let qt: [String] = tokens(cleaned)
        let groups: [[[String]]] = synonymGroups().map { (g: [String]) -> [[String]] in
            g.map { (w: String) -> [String] in cleanTokens(w) }.filter { (x: [String]) -> Bool in !x.isEmpty }
        }
        var used: [Bool] = Array(repeating: false, count: qt.count)
        var out: [[[String]]] = []
        var phrases: [([String], [[String]])] = []
        for g in groups { for a in g where a.count > 1 { phrases.append((a, g)) } }
        phrases.sort { (x: ([String], [[String]]), y: ([String], [[String]])) -> Bool in x.0.count > y.0.count }
        for (ph, g) in phrases {
            var i: Int = 0
            while i + ph.count <= qt.count {
                if !used[i..<(i + ph.count)].contains(true) && Array(qt[i..<(i + ph.count)]) == ph {
                    for j in i..<(i + ph.count) { used[j] = true }
                    out.append(g)
                    i += ph.count
                } else { i += 1 }
            }
        }
        for (i, t) in qt.enumerated() where !used[i] {
            var alts: [[String]] = [[t]]
            for g in groups where g.contains(where: { (a: [String]) -> Bool in a == [t] }) {
                for a in g where a != [t] && !alts.contains(a) { alts.append(a) }
            }
            out.append(alts)
        }
        return out
    }
    static func conceptIn(_ alts: [[String]], _ tk: Set<String>) -> Bool {
        if tk.isEmpty { return false }
        for a in alts {
            let ok: Bool = a.allSatisfy { (w: String) -> Bool in
                if tk.contains(w) { return true }
                if w.count < 4 { return false }
                return tk.contains(w + "s") || tk.contains(w + "x") || (w.hasSuffix("s") && tk.contains(String(w.dropLast())))
            }
            if ok { return true }
        }
        return false
    }

    /// Reclassement côté Nova : ordre Algolia (≤ 60 pts) + concepts présents dans le NOM (≤ 110) et le dossier (≤ 15) ;
    /// fichier généré −70 (fiche .docx.json −40), sauf si la requête les demande (scan, veille, bulletin, journal…).
    static func rerank(_ hits: [[String: Any]], cleaned: String) -> [[String: Any]] {
        let cs: [[[String]]] = concepts(cleaned)
        let wantsGen: Bool = !Set(tokens(cleaned)).isDisjoint(with: generatedWords)
        var scored: [(Double, Int, [String: Any])] = []
        for (i, h0) in hits.enumerated() {
            var h: [String: Any] = h0
            let title: String = (h["title"] as? String) ?? ""
            let chemin: String = (h["chemin"] as? String) ?? ""
            let tk: Set<String> = nameTokens(title)
            let fk: Set<String> = chemin.hasPrefix("nova://") ? Set<String>() : nameTokens((chemin as NSString).deletingLastPathComponent)
            var s: Double = Double(max(0, 60 - i))
            if !cs.isEmpty {
                let n: Double = Double(cs.count)
                let tHit: Int = cs.filter { (c: [[String]]) -> Bool in conceptIn(c, tk) }.count
                let fHit: Int = cs.filter { (c: [[String]]) -> Bool in conceptIn(c, fk) }.count
                s += 80 * Double(tHit) / n
                if tHit == cs.count { s += 30 }
                s += 15 * Double(fHit) / n
            }
            let gen: Bool = isGenerated(title)
            if gen && !wantsGen { s -= rxHit(sidecarRx, fold(title)) ? 40 : 70 }
            h["genere"] = gen
            h["score_nova"] = Int(s.rounded())
            scored.append((s, i, h))
        }
        scored.sort { (a: (Double, Int, [String: Any]), b: (Double, Int, [String: Any])) -> Bool in a.0 != b.0 ? a.0 > b.0 : a.1 < b.1 }
        return scored.map { (x: (Double, Int, [String: Any])) -> [String: Any] in x.2 }
    }

    /// UN résultat par fichier : même nom de base (sans extension ni « .json » de fiche) ET même dossier ou même date
    /// → regroupés (copie iCloud/Documents, jumeau .md d'un .docx, fiche .docx.json). « copies », « formats », « autres_chemins », « dossier ».
    static func groupFiles(_ hits: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var at: [String: Int] = [:]
        for h in hits {
            let title: String = (h["title"] as? String) ?? ""
            let chemin: String = (h["chemin"] as? String) ?? ""
            var base: String = fold(title)
            if rxHit(sidecarRx, base) { base = String(base.dropLast(5)) }
            let bext: String = (base as NSString).pathExtension
            if !bext.isEmpty && bext.count <= 5 { base = (base as NSString).deletingPathExtension }
            let isNova: Bool = chemin.hasPrefix("nova://") || chemin.isEmpty
            let folderName: String = ((chemin as NSString).deletingLastPathComponent as NSString).lastPathComponent
            let date: String = (h["date"] as? String) ?? ""
            var keys: [String] = []
            if !isNova && !base.isEmpty {
                keys.append(base + "|d:" + fold(folderName))
                if !date.isEmpty { keys.append(base + "|t:" + date) }
            }
            let ext: String = (title as NSString).pathExtension.lowercased()
            if let j = keys.compactMap({ (k: String) -> Int? in at[k] }).first {
                var g: [String: Any] = out[j]
                var autres: [String] = (g["autres_chemins"] as? [String]) ?? []
                if autres.count < 5 && !chemin.isEmpty { autres.append(chemin) }
                g["autres_chemins"] = autres
                g["copies"] = ((g["copies"] as? Int) ?? 1) + 1
                var formats: [String] = (g["formats"] as? [String]) ?? []
                if !ext.isEmpty && !formats.contains(ext) { formats.append(ext) }
                g["formats"] = formats
                out[j] = g
                for k in keys where at[k] == nil { at[k] = j }
                continue
            }
            var g: [String: Any] = h
            g["copies"] = 1
            g["formats"] = ext.isEmpty ? [String]() : [ext]
            g["dossier"] = isNova ? "" : (chemin as NSString).deletingLastPathComponent
            for k in keys { at[k] = out.count }
            out.append(g)
        }
        return out
    }

    /// Recherche « intelligente » (outil bibliotheque, palette ⌘K, BIBLIO_TEST/EVAL) : 1 requête de 50 fichiers sur la requête
    /// nettoyée ; si moins de 10 fichiers et plusieurs mots, 2e requête où tous les mots sont optionnels (langage naturel) ;
    /// puis reclassement et regroupement. Au plus 2 requêtes Algolia (NeuralSearch NON utilisé : option payante).
    static func smartSearch(_ q: String, source: String, k: Int) -> (hits: [[String: Any]]?, err: String, cleaned: String, tries: Int) {
        let cq: String = cleanQuery(q)
        let r1 = query(cq, source: source, k: 50)
        guard var pool = r1.hits else { return (nil, r1.err, cq, 1) }
        var tries: Int = 1
        let words: [String] = cq.split(separator: " ").map { (x: Substring) -> String in String(x) }
        if pool.count < 10 && words.count > 1 {
            tries += 1
            if let more = query(cq, source: source, k: 50, optionalWords: words).hits {
                var seen: Set<String> = Set(pool.compactMap { (h: [String: Any]) -> String? in h["chemin"] as? String })
                for h in more {
                    let c: String = (h["chemin"] as? String) ?? ""
                    if c.isEmpty || seen.contains(c) { continue }
                    seen.insert(c)
                    pool.append(h)
                }
            }
        }
        let grouped: [[String: Any]] = groupFiles(rerank(pool, cleaned: cq))
        return (Array(grouped.prefix(max(1, k))), "", cq, tries)
    }

    static func hitLabel(_ h: [String: Any]) -> String {
        var s: String = "[" + ((h["source"] as? String) ?? "") + "] " + ((h["title"] as? String) ?? "")
        let n: Int = (h["copies"] as? Int) ?? 1
        if n > 1 { s += " (+" + String(n - 1) + ")" }
        return s
    }

    // MARK: 31/10 (biblio 4) : banc de pertinence — dormant/BIBLIO_EVAL (vide) → lit releves/diag/biblio_eval.json
    // {"requetes":[{"q","attendus":[morceaux de nom attendus]}]} → releves/diag/biblio_eval_resultats.json :
    // position du 1er bon fichier dans le top 10, brut (Algolia seul) et nouveau (smartSearch), fichiers générés et top 10. En fond.

    static func evalPoll(root: String) {
        let req: String = root + "/dormant/BIBLIO_EVAL"
        guard FileManager.default.fileExists(atPath: req) else { return }
        try? FileManager.default.removeItem(atPath: req)
        lock.lock()
        if evalRunning { lock.unlock(); return }
        evalRunning = true
        lock.unlock()
        let t: Thread = Thread {
            AlgoliaBiblio.runEval()
            AlgoliaBiblio.lock.lock(); AlgoliaBiblio.evalRunning = false; AlgoliaBiblio.lock.unlock()
        }
        t.qualityOfService = .utility
        t.start()
    }
    static func firstPos(_ hits: [[String: Any]], _ att: [String]) -> Any {
        if att.isEmpty { return NSNull() }
        let a: [String] = att.map { (x: String) -> String in fold(x) }
        for (i, h) in hits.prefix(10).enumerated() {
            let t: String = fold((h["title"] as? String) ?? "")
            if a.contains(where: { (x: String) -> Bool in t.contains(x) }) { return i + 1 }
        }
        return NSNull()
    }
    static func runEval() {
        let d: Data = (try? Data(contentsOf: URL(fileURLWithPath: diagDir + "/biblio_eval.json"))) ?? Data()
        let o: [String: Any] = parseJSON(d) ?? [:]
        let reqs: [[String: Any]] = (o["requetes"] as? [[String: Any]]) ?? []
        var rows: [[String: Any]] = []
        for r in reqs.prefix(30) {
            let q: String = (r["q"] as? String) ?? ""
            if q.isEmpty { continue }
            let att: [String] = (r["attendus"] as? [String]) ?? []
            let brut: [[String: Any]] = Array((query(q, source: "", k: 10).hits ?? []).prefix(10))
            let nv = smartSearch(q, source: "", k: 10)
            let hits: [[String: Any]] = nv.hits ?? []
            var row: [String: Any] = ["q": q, "attendus": att, "requete_nettoyee": nv.cleaned, "requetes_algolia": nv.tries + 1, "erreur": nv.err]
            row["position_brut"] = firstPos(brut, att)
            row["position_nouveau"] = firstPos(hits, att)
            let genB: Int = brut.filter { (h: [String: Any]) -> Bool in isGenerated((h["title"] as? String) ?? "") }.count
            let genN: Int = hits.filter { (h: [String: Any]) -> Bool in (h["genere"] as? Bool) == true }.count
            row["generes_top10_brut"] = genB
            row["generes_top10_nouveau"] = genN
            row["top10_brut"] = brut.map { (h: [String: Any]) -> String in hitLabel(h) }
            row["top10_nouveau"] = hits.map { (h: [String: Any]) -> String in hitLabel(h) }
            rows.append(row)
            Thread.sleep(forTimeInterval: 0.3)
        }
        let out: [String: Any] = ["mesure_le": nowISO(), "reglages_v": settingsVersion, "resultats": rows]
        try? jsonData(out).write(to: URL(fileURLWithPath: diagDir + "/biblio_eval_resultats.json"))
    }

    // MARK: outils pour les cerveaux

    static func stripTags(_ s: String) -> String { return s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }

    /// 31/10 (biblio 2) : TOUS les fichiers correspondants (pages de 100, un résultat par fichier), au plus maxFiles.
    static func queryAll(_ q: String, source: String, maxFiles: Int) -> (files: [[String: Any]]?, err: String, truncated: Bool) {
        var seen: Set<String> = []
        var files: [[String: Any]] = []
        var page: Int = 0
        let cq: String = cleanQuery(q)   // 31/10 (biblio 4) : mots de liaison retirés (« fichiers liés à mon boulot chez DRC » → « DRC »)
        while page < 20 {
            let r = query(cq, source: source, k: 100, page: page)
            guard let hits = r.hits else { return page == 0 ? (nil, r.err, false) : (files, "", false) }
            for h in hits {
                let key: String = (h["chemin"] as? String) ?? ((h["title"] as? String) ?? "")
                if key.isEmpty || seen.contains(key) { continue }
                seen.insert(key); files.append(h)
                if files.count >= maxFiles { return (files, "", true) }
            }
            if hits.count < 100 { break }
            page += 1
        }
        return (files, "", false)
    }

    /// 31/10 (biblio 2) : SYNONYMES Algolia (taper l'un trouve les autres). Réglage « algolia_synonymes » = [[mot, mot…], …].
    // 31/10 (biblio 4) : synonymes FR↔EN GÉNÉRAUX (pays, codes ISO3 des noms de fichiers CAFU, types de documents). Le réglage
    // « algolia_synonymes » S'AJOUTE désormais à cette liste (avant : la remplaçait). Volontairement absent : DRC = RDC (Congo) — ambigu.
    static let defaultSynonyms: [[String]] = [
        ["DRC", "Danish Refugee Council", "Conseil danois pour les réfugiés", "Dansk Flygtningehjælp"],
        ["MMC", "Mixed Migration Centre", "Mixed Migration Center", "Centre pour les migrations mixtes"],
        ["Soudan", "Sudan"], ["Soudan du Sud", "South Sudan"], ["Tchad", "Chad", "TCD"], ["Burkina", "Burkina Faso", "BFA"],
        ["Mali", "MLI"], ["Niger", "NER"], ["Côte d'Ivoire", "Ivory Coast", "CIV"], ["Cameroun", "Cameroon"], ["Éthiopie", "Ethiopia"],
        ["Somalie", "Somalia"], ["Libye", "Libya"], ["Mauritanie", "Mauritania"], ["Guinée", "Guinea"],
        ["Centrafrique", "République centrafricaine", "Central African Republic", "RCA"],
        ["RDC", "République démocratique du Congo", "DR Congo", "Democratic Republic of the Congo"],
        ["ONG", "NGO"], ["ONGI", "INGO", "ONG internationale", "international NGO"],
        ["lettre de motivation", "cover letter", "coverletter", "motivation letter"],
        ["appel d'offres", "tender", "RFP", "request for proposals", "invitation to bid"],
        ["offre technique", "proposition technique", "technical proposal", "technical bid", "bid technique"],
        ["termes de référence", "TDR", "ToR", "terms of reference"],
        ["rapport", "report"], ["consultance", "consultancy", "consulting"], ["candidature", "job application"],
        ["CV", "curriculum vitae"], ["réfugiés", "refugees"], ["déplacés", "displaced", "PDI", "IDP"],
        ["humanitaire", "humanitarian"], ["accès humanitaire", "humanitarian access"], ["sécurité", "security"],
        ["analyse", "analysis"], ["décret", "decree"], ["évaluation", "assessment", "evaluation"], ["proposition", "proposal"],
        ["contrat", "contract"], ["recommandation", "recommendation"]]
    /// Groupes envoyés à Algolia : défauts + réglage, chaque expression doublée de sa forme SANS mots de liaison
    /// (« lettre de motivation » → aussi « lettre motivation »), puisque la requête est nettoyée avant envoi.
    static func synonymGroups() -> [[String]] {
        let user: [[String]] = Settings().get("algolia_synonymes", [[String]]())
        var out: [[String]] = []
        for g in defaultSynonyms + user {
            var seen: Set<String> = []
            var grp: [String] = []
            for w0 in g {
                let w: String = w0.trimmingCharacters(in: .whitespaces)
                if w.isEmpty { continue }
                let fw: String = fold(w)
                if !seen.contains(fw) { seen.insert(fw); grp.append(w) }
                let v: String = cleanTokens(w).joined(separator: " ")
                if !v.isEmpty && !seen.contains(v) { seen.insert(v); grp.append(v) }
            }
            if grp.count >= 2 { out.append(grp) }
        }
        return out
    }
    static func ensureSynonyms(app: String, admin: String, meta: inout [String: Any]) {
        let groups: [[String]] = synonymGroups()
        let sig: String = groups.map { (g: [String]) -> String in g.joined(separator: "|") }.joined(separator: "||")
        if (meta["synonymes_sig"] as? String) == sig { return }
        var body: [[String: Any]] = []
        for (i, g) in groups.enumerated() { body.append(["objectID": "nova-syn-\(i)", "type": "synonym", "synonyms": g]) }
        let (st, d): (Int, Data) = callArray("POST", app: app, key: admin, path: "/1/indexes/" + index + "/synonyms/batch?replaceExistingSynonyms=true", body: body, timeout: 15)
        if st == 200 { Credits.count("algolia", n: 1); meta["synonymes_sig"] = sig; meta["synonymes_groupes"] = groups.count }
        else if st > 0 { AlgoliaRelay.failed(status: st, detail: String(decoding: d.prefix(300), as: UTF8.self), op: "write", adminKey: true) }
    }
    static func callArray(_ method: String, app: String, key: String, path: String, body: [[String: Any]], timeout: TimeInterval) -> (Int, Data) {
        guard let u = URL(string: "https://" + app + "-dsn.algolia.net" + path) else { return (0, Data()) }
        var rq: URLRequest = URLRequest(url: u)
        rq.httpMethod = method
        rq.setValue(app, forHTTPHeaderField: "X-Algolia-Application-Id")
        rq.setValue(key, forHTTPHeaderField: "X-Algolia-API-Key")
        rq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        rq.httpBody = jsonData(body)
        return syncGet(rq, timeout: timeout)
    }

    /// 31/10 (biblio 2) : ouvrir un document de la bibliothèque (palette ⌘K) — seulement un chemin INDEXÉ, via /usr/bin/open (sans shell).
    static func openIndexed(_ chemin: String, reveal: Bool) -> (ok: Bool, msg: String) {
        let a: String = chemin.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.hasPrefix("nova://") { return (false, "élément interne de Nova : demande-le dans le chat") }
        let path: String = expand(a)
        let docs: [String: Any] = (stateFile.read(default: [String: Any]())["docs"] as? [String: Any]) ?? [:]
        guard let o = docs[path] as? [String: Any], ((o["n"] as? Int) ?? 0) > 0, FileManager.default.fileExists(atPath: path) else { return (false, "fichier absent de la bibliothèque") }
        let p: Process = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = reveal ? ["-R", path] : [path]
        do { try p.run() } catch { return (false, "ouverture impossible") }
        return (true, display(path))
    }

    /// Outil « bibliotheque » : arg = requête, ou JSON {"requete","source","k"}.
    public static func toolSearch(_ arg: String) -> String {
        var q: String = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        var src: String = ""
        var k: Int = 5
        var tous: Bool = false   // 31/10 (biblio 2) : liste complète, un fichier par ligne
        if q.hasPrefix("{"), let o = parseJSON(Data(q.utf8)) {
            q = ((o["requete"] as? String) ?? (o["query"] as? String) ?? (o["q"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            src = fold(((o["source"] as? String) ?? "").trimmingCharacters(in: .whitespaces))
            if let n = o["k"] as? Int { k = n } else if let s = o["k"] as? String, let n = Int(s) { k = n }
            if (o["tous"] as? Bool) == true || ((o["tous"] as? String) ?? "") == "true" { tous = true }
        }
        k = max(1, min(10, k))   // 31/10 (biblio 2) : 10 au plus en mode extraits ; « tous » pour la liste complète
        if q.isEmpty { return "bibliotheque : requête vide (texte, ou JSON {\"requete\",\"source\",\"k\"})." }
        if src == "competence" { src = "competences" }
        if src == "projet" { src = "projets" }
        if !src.isEmpty && !sources.contains(src) { return "bibliotheque : source inconnue « " + src + " » (" + sources.joined(separator: ", ") + ")." }
        if tous {
            let all = queryAll(q, source: src, maxFiles: 200)
            guard let files = all.files else { return "Bibliothèque Algolia indisponible (" + all.err + ")." }
            if files.isEmpty { return "Rien dans la bibliothèque pour « " + q + " »" + (src.isEmpty ? "" : " (source " + src + ")") + "." }
            var out: [String] = ["Bibliothèque Nova — liste COMPLÈTE : \(files.count) fichier(s) pour « \(q) »" + (all.truncated ? " (limite de 200 atteinte : affine la requête)" : "") + " ; texte : lire_fichier_bibliotheque avec le chemin."]
            for (i, f) in files.enumerated() {
                let d: String = (f["date"] as? String) ?? ""
                out.append("\(i + 1). [\((f["source"] as? String) ?? "")] \((f["title"] as? String) ?? "(sans titre)") — \((f["chemin"] as? String) ?? "")" + (d.isEmpty ? "" : " · " + d))
            }
            return out.joined(separator: "\n")
        }
        let r = smartSearch(q, source: src, k: k)   // 31/10 (biblio 4) : requête nettoyée, repli mots optionnels, reclassement, regroupement
        guard let hits = r.hits else {
            return "Bibliothèque Algolia indisponible (" + r.err + ") — repli sur le savoir local :\n" + Knowledge.shared.toolText(q)
        }
        if hits.isEmpty {
            return "Rien dans la bibliothèque pour « " + q + " »" + (src.isEmpty ? "" : " (source " + src + ")") + " (mots cherchés : " + r.cleaned + ") — repli sur le savoir local :\n" + Knowledge.shared.toolText(q)
        }
        var lines: [String] = ["Bibliothèque Nova (Algolia) — " + String(hits.count) + " fichier(s) pour « " + q + " »" + (fold(r.cleaned) == fold(q) ? "" : " (mots cherchés : " + r.cleaned + ")") + " ; classés nom de fichier d'abord, scans/exports automatiques relégués ; texte complet : lire_fichier_bibliotheque avec le chemin."]
        for (i, h) in hits.enumerated() {
            let title: String = (h["title"] as? String) ?? "(sans titre)"
            let chemin: String = (h["chemin"] as? String) ?? ""
            let date: String = (h["date"] as? String) ?? ""
            let s: String = (h["source"] as? String) ?? ""
            let m: Int = (h["morceau"] as? Int) ?? 1
            let n: Int = (h["morceaux"] as? Int) ?? 1
            let snip: String = (((h["_snippetResult"] as? [String: Any])?["text"] as? [String: Any])?["value"] as? String) ?? ""
            var head: String = String(i + 1) + ". [" + s + "] " + title + " — " + chemin
            if !date.isEmpty { head += " · " + date }
            if n > 1 { head += " · morceau " + String(m) + "/" + String(n) }
            if (h["genere"] as? Bool) == true { head += " · généré automatiquement" }
            let autres: [String] = (h["autres_chemins"] as? [String]) ?? []
            if !autres.isEmpty { head += " · aussi : " + autres.prefix(3).joined(separator: " ; ") }
            lines.append(head)
            let ex: String = stripTags(snip).replacingOccurrences(of: "\n", with: " ")
            if !ex.isEmpty { lines.append("   « " + String(ex.prefix(400)) + " »") }
        }
        return lines.joined(separator: "\n")
    }

    /// Outil « lire_fichier_bibliotheque » : arg = chemin (rendu par bibliotheque) ou JSON {"chemin","morceau"} ou « chemin|morceau ».
    /// Seuls les documents présents dans la bibliothèque (déjà passés par les exclusions) sont lus ; contrôles refaits à la lecture.
    public static func toolRead(_ arg: String) -> String {
        var a: String = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        var part: Int = 1
        if a.hasPrefix("{"), let o = parseJSON(Data(a.utf8)) {
            a = ((o["chemin"] as? String) ?? (o["path"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = o["morceau"] as? Int { part = n } else if let s = o["morceau"] as? String, let n = Int(s) { part = n }
        } else if let bar = a.lastIndex(of: "|"), let n = Int(a[a.index(after: bar)...].trimmingCharacters(in: .whitespaces)) {
            part = n
            a = String(a[..<bar]).trimmingCharacters(in: .whitespaces)
        }
        if a.isEmpty { return "lire_fichier_bibliotheque : chemin vide (chemin rendu par bibliotheque)." }
        let st: [String: Any] = stateFile.read(default: [String: Any]())
        let docs: [String: Any] = (st["docs"] as? [String: Any]) ?? [:]
        let extra: [String] = extras()
        var text: String = ""
        var label: String = a
        if a.hasPrefix("nova://") {
            let comps: [String] = a.dropFirst(7).split(separator: "/", maxSplits: 1).map { (x: Substring) -> String in String(x) }
            let src: String = comps.first ?? ""
            let pp: BiblioPass = BiblioPass(c: ("", "", ""), cap: 0, extra: extra)
            guard let d = novaDocs(src, p: pp).first(where: { (x: Doc) -> Bool in x.key == a }), let t = d.load() else {
                return "lire_fichier_bibliotheque : élément absent de la bibliothèque (supprimé, exclu ou sensible)."
            }
            text = t
            label = d.title + " — " + a
        } else {
            let path: String = expand(a)
            guard let o = docs[path] as? [String: Any], ((o["n"] as? Int) ?? 0) > 0 else {
                return "lire_fichier_bibliotheque : fichier absent de la bibliothèque (non indexé, exclu ou sensible) — pour un autre fichier du dossier personnel : read_file."
            }
            if SecretsGuard.isCredentialPath(path) || termHit(display(path), extra: extra) != nil { return "lire_fichier_bibliotheque : fichier désormais exclu (règle sensible) — contenu non renvoyé." }
            #if os(macOS)
            let rv: URLResourceValues? = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            if rv?.isUbiquitousItem == true, let s = rv?.ubiquitousItemDownloadingStatus, s != URLUbiquitousItemDownloadingStatus.current {
                return "lire_fichier_bibliotheque : fichier iCloud non présent sur le Mac — Nova ne le télécharge pas."
            }
            #endif
            let ext: String = (path as NSString).pathExtension.lowercased()
            guard let t = fileText(path, ext: ext) else { return "lire_fichier_bibliotheque : fichier illisible ou disparu (" + display(path) + ")." }
            text = t
            label = display(path)
        }
        let clean: String = normalize(text)
        if contentHit(clean) != nil { return "lire_fichier_bibliotheque : contenu sensible détecté (secret ou donnée bancaire) — non renvoyé." }
        let parts: [String] = splitText(clean, maxBytes: chunkBytes)
        if parts.isEmpty { return "lire_fichier_bibliotheque : document vide (" + label + ")." }
        let m: Int = max(1, min(parts.count, part))
        var out: String = label + " — morceau " + String(m) + "/" + String(parts.count) + "\n" + parts[m - 1]
        if m < parts.count { out += "\n(suite : morceau " + String(m + 1) + ")" }
        return out
    }

    // MARK: diagnostic du disjoncteur et réarmement (dormant/ALGOLIA_REARM)

    static func breakerInfo() -> [String: Any] {
        let o: [String: Any] = Credits.usageFile.read(default: [String: Any]())
        let b: [String: Any] = ((o["breakers"] as? [String: Any])?["algolia"] as? [String: Any]) ?? [:]
        let p: [String: Any] = ((o["providers"] as? [String: Any])?["algolia"] as? [String: Any]) ?? [:]
        var d: [String: Any] = ["ouvert": Credits.isOpen("algolia"), "pose": !b.isEmpty]
        for k in ["status", "reason", "since", "until", "hits", "last_status", "last_ts"] { if let v = b[k] { d[k] = v } }
        for k in ["calls", "errors", "last_error", "last"] { if let v = p[k] { d["usage_" + k] = v } }
        return d
    }

    static func writeBreakerDiag() {
        var d: [String: Any] = breakerInfo()
        d["generated"] = nowISO()
        let rs: [String: Any] = AlgoliaRelay.state.read(default: [String: Any]())
        for k in ["derniere_erreur", "derniere_erreur_http", "derniere_erreur_detail", "derniere_erreur_op", "derniere_erreur_ts", "recherche_refusee_cle_ecriture"] {
            if let v = rs[k] { d[k] = v }
        }
        let c = AlgoliaRelay.creds(KeychainStore())
        d["app_id_present"] = !c.app.isEmpty; d["cle_ecriture_presente"] = !c.admin.isEmpty; d["cle_recherche_presente"] = !c.search.isEmpty
        let s: Int = (d["status"] as? Int) ?? ((d["last_status"] as? Int) ?? 0)
        let detail: String = ((d["derniere_erreur_detail"] as? String) ?? "").lowercased()
        var lecture: String = "aucun échec enregistré"
        switch s {
        case 401: lecture = "HTTP 401 : clé refusée par Algolia (invalide, révoquée ou d'une autre application)"
        case 402: lecture = "HTTP 402 : plan ou paiement Algolia (crédits à vérifier sur le portail)"
        case 403: lecture = detail.contains("quota") || detail.contains("blocked") ? "HTTP 403 : application bloquée ou quota dépassé (portail Algolia)" : "HTTP 403 : la clé n'a pas le droit demandé (ACL : search / addObject) ou l'index lui est interdit — si c'est la recherche avec la clé d'écriture : ajoute la Search-only key nova-algolia-search"
        case 429: lecture = "HTTP 429 : limite de débit (pause automatique 15 min)"
        case 400: lecture = "HTTP 400 : requête refusée (souvent « record too big … extended quota ») — ce cas n'ouvre plus le disjoncteur depuis le 31/10"
        case 0: lecture = (d["pose"] as? Bool) == true ? "disjoncteur posé sans statut HTTP (mot « quota/crédit » dans la réponse)" : "aucun échec enregistré"
        default: lecture = "HTTP " + String(s)
        }
        d["lecture"] = lecture
        try? jsonData(d).write(to: URL(fileURLWithPath: diagDir + "/algolia_disjoncteur.json"))
    }

    static func rearmPoll(root: String) {
        let req: String = root + "/dormant/ALGOLIA_REARM"
        guard FileManager.default.fileExists(atPath: req) else { return }
        try? FileManager.default.removeItem(atPath: req)
        var out: [String: Any] = ["generated": nowISO(), "disjoncteur_avant": breakerInfo()]
        out["rearme"] = Credits.rearm("algolia")
        AlgoliaRelay.clearSearchDenied()
        let c = AlgoliaRelay.creds(KeychainStore())
        let useAdmin: Bool = c.search.isEmpty
        let key: String = useAdmin ? c.admin : c.search
        out["cle"] = useAdmin ? "clé d'écriture (clé de recherche absente)" : "clé de recherche"
        out["index"] = AlgoliaRelay.index
        if c.app.isEmpty || key.isEmpty {
            out["resultat"] = c.app.isEmpty ? "Application ID absent du Trousseau (nova-algolia-app)" : "aucune clé Algolia au Trousseau"
        } else {
            let (st, d): (Int, Data) = AlgoliaRelay.request(app: c.app, key: key, path: "/1/indexes/" + AlgoliaRelay.index + "/query", body: ["query": "", "hitsPerPage": 1], timeout: 8)
            out["statut_http"] = st
            if st == 200 {
                Credits.count("algolia", n: 1, units: 1, unit: "requête")
                out["nb_hits"] = (parseJSON(d)?["nbHits"] as? Int) ?? 0
                out["resultat"] = "recherche OK"
            } else {
                out["detail"] = String(SecretsGuard.redact(String(decoding: d.prefix(200), as: UTF8.self)))
                if st == 403 && useAdmin { out["message"] = "la clé d'écriture n'a pas le droit search : ajoute la Search-only key nova-algolia-search" }
                out["resultat"] = st > 0 ? "échec HTTP " + String(st) : "Algolia injoignable (réseau)"
                if st > 0 { AlgoliaRelay.failed(status: st, detail: String(decoding: d.prefix(300), as: UTF8.self), op: "search", adminKey: useAdmin) }
            }
        }
        out["disjoncteur_apres"] = breakerInfo()
        try? jsonData(out).write(to: URL(fileURLWithPath: diagDir + "/algolia_test.json"))
        writeBreakerDiag()
        _ = BlackBox.record(["tool": "algolia", "actor": "Ahadi", "ok": (out["statut_http"] as? Int) == 200, "effect": "config",
                             "why": "dormant/ALGOLIA_REARM : disjoncteur Algolia réarmé + 1 requête de test (31/10)", "result": (out["resultat"] as? String) ?? ""])
        lock.lock(); lastPassAt = Date.distantPast; lock.unlock()
    }

    // MARK: passe d'ingestion

    static func mustYield() -> String? {
        if PerfGovernor.shared.level() == PerfGovernor.critique { return "gouverneur : tension critique" }
        if Date().timeIntervalSince(NovaApp.lastChatAt) < chatQuiet { return "chat récent" }
        if Credits.isOpen("algolia") { return "disjoncteur Algolia ouvert" }
        return nil
    }

    /// Appelée par la boucle de 30 s (Feat_BancAgent) : réarmement, diag du disjoncteur (5 min), passe d'ingestion (1 h) en fond.
    public static func tick(root: String) {
        rearmPoll(root: root)
        evalPoll(root: root)   // 31/10 (biblio 4) : banc de pertinence (dormant/BIBLIO_EVAL)
        // 31/10 (biblio 2) : dormant/BIBLIO_TEST (texte = requête, défaut « DRC ») → releves/diag/biblio_test.json (comptes, titres ; pas de contenu)
        let bt: String = root + "/dormant/BIBLIO_TEST"
        if FileManager.default.fileExists(atPath: bt) {
            let q0: String = ((try? String(contentsOfFile: bt, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(atPath: bt)
            let q: String = q0.isEmpty ? "DRC" : q0
            do {   // 31/10 (biblio 3) : applique les réglages v3 et les synonymes sans attendre la passe horaire
                let c = AlgoliaRelay.creds(KeychainStore())
                var meta: [String: Any] = stateFile.read(default: [String: Any]())
                if !c.app.isEmpty && !c.admin.isEmpty && !Credits.isOpen("algolia") {
                    if (meta["settings_v"] as? Int) != settingsVersion, ensureSettings(app: c.app, admin: c.admin) { meta["settings_ok"] = true; meta["settings_v"] = settingsVersion }
                    ensureSynonyms(app: c.app, admin: c.admin, meta: &meta)
                    stateFile.write(meta)
                }
            }
            let r = smartSearch(q, source: "", k: 20)   // 31/10 (biblio 4) : même chemin que l'outil et la palette ; « titres_brut » = Algolia seul
            let brut = query(q, source: "", k: 10)
            let all = queryAll(q, source: "", maxFiles: 200)
            let top: [[String: Any]] = Array((r.hits ?? []).prefix(10))
            let titres: [String] = top.map { (h: [String: Any]) -> String in "[\((h["source"] as? String) ?? "")] \((h["title"] as? String) ?? "")" }
            let regroupes: [String] = top.map { (h: [String: Any]) -> String in hitLabel(h) }
            let chemins: [String] = top.map { (h: [String: Any]) -> String in (h["chemin"] as? String) ?? "" }
            let titresBrut: [String] = (brut.hits ?? []).map { (h: [String: Any]) -> String in "[\((h["source"] as? String) ?? "")] \((h["title"] as? String) ?? "")" }
            let o: [String: Any] = ["generated": nowISO(), "requete": q, "requete_nettoyee": r.cleaned, "requetes_algolia": r.tries, "ok": r.hits != nil, "erreur": r.err, "nb_hits": r.hits?.count ?? -1,
                                    "titres": titres, "titres_regroupes": regroupes, "chemins": chemins, "titres_brut": titresBrut,
                                    "reglages_v": settingsVersion, "liste_complete_fichiers": all.files?.count ?? -1, "liste_erreur": all.err,
                                    "disjoncteur": Credits.isOpen("algolia"), "recherche_refusee_cle_ecriture": AlgoliaRelay.searchDeniedForAdmin()]
            try? jsonData(o).write(to: URL(fileURLWithPath: diagDir + "/biblio_test.json"))
        }
        lock.lock()
        if bootAt == nil { bootAt = Date() }
        let boot: Date = bootAt ?? Date()
        let diagDue: Bool = Date().timeIntervalSince(lastDiagAt) > 300
        if diagDue { lastDiagAt = Date() }
        let due: Bool = !running && Date().timeIntervalSince(lastPassAt) >= passInterval && Date().timeIntervalSince(boot) >= 600
        lock.unlock()
        if diagDue { writeBreakerDiag() }
        if !due || mustYield() != nil { return }
        lock.lock(); lastPassAt = Date(); running = true; lock.unlock()
        let t: Thread = Thread {
            let d: [String: Any] = AlgoliaBiblio.pass()
            try? jsonData(d).write(to: URL(fileURLWithPath: AlgoliaBiblio.diagDir + "/algolia_mac_etat.json"))
            AlgoliaBiblio.lock.lock(); AlgoliaBiblio.running = false; AlgoliaBiblio.lock.unlock()
        }
        t.qualityOfService = .background
        t.start()
    }

    static func pass() -> [String: Any] {
        let t0: Date = Date()
        var diag: [String: Any] = ["generated": nowISO(), "index": index]
        let c = AlgoliaRelay.creds(KeychainStore())
        if c.app.isEmpty || c.admin.isEmpty { diag["statut"] = "non versé : Application ID ou clé d'écriture Algolia absente"; return diag }
        if Credits.isOpen("algolia") { diag["statut"] = "non versé : disjoncteur Algolia ouvert"; return diag }
        var meta: [String: Any] = stateFile.read(default: [String: Any]())
        if (meta["settings_v"] as? Int) != settingsVersion {   // 31/10 (biblio 4) : réglages d'index (v4 : titre d'abord, ranking) réappliqués une fois
            if ensureSettings(app: c.app, admin: c.admin) { meta["settings_ok"] = true; meta["settings_v"] = settingsVersion; stateFile.write(meta) }
        }
        do { let before: String? = meta["synonymes_sig"] as? String; ensureSynonyms(app: c.app, admin: c.admin, meta: &meta); if (meta["synonymes_sig"] as? String) != before { stateFile.write(meta) } }   // 31/10 (biblio 2)
        let cap: Int = max(50, min(20000, Settings().get("algolia_plafond_par_passe", 2000)))
        let p: BiblioPass = BiblioPass(c: c, cap: cap, extra: extras())
        p.docs = (meta["docs"] as? [String: Any]) ?? [:]
        p.meta = meta
        let macOn: Bool = Settings().get("algolia_mac_index", true)
        let mac: [String] = macDirs()
        // 1) magasins de Nova (petits) ; 2) fichiers de Nova ; 3) savoir ; 4) Mac.
        for src in ["memoire", "fundings", "projets", "briefs", "dossiers", "competences"] {
            if p.stopped { break }
            let list: [Doc] = novaDocs(src, p: p)
            for d in list { if p.stopped { break }; p.process(d) }
            p.complete[src] = !p.stopped
        }
        if !p.stopped { p.complete["cafu"] = scanFiles("cafu", roots: [Livrables.dir.path], exts: docExts, knowledgeRules: false, guardNova: false, p: p) }
        if !p.stopped { p.complete["savoir"] = scanFiles("savoir", roots: savoirDirs(excluding: mac), exts: Knowledge.scanExts, knowledgeRules: true, guardNova: true, p: p) }
        if !p.stopped {
            if macOn { p.complete["mac"] = scanFiles("mac", roots: mac, exts: docExts, knowledgeRules: false, guardNova: true, p: p) }
            else { p.complete["mac"] = true }   // indexation du Mac coupée : ses enregistrements sont retirés de l'index
        }
        if !p.stopped { p.purgeMissing() }
        if !p.stopped { _ = p.flush() }
        var chunksBySrc: [String: Int] = [:]
        var docsBySrc: [String: Int] = [:]
        for (_, v) in p.docs {
            guard let o = v as? [String: Any], let s = o["src"] as? String else { continue }
            let n: Int = (o["n"] as? Int) ?? 0
            if n > 0 { chunksBySrc[s, default: 0] += n; docsBySrc[s, default: 0] += 1 }
        }
        diag["statut"] = p.stopReason.isEmpty ? "passe complète" : "passe interrompue : " + p.stopReason
        diag["duree_s"] = Int(Date().timeIntervalSince(t0))
        diag["operations_envoyees"] = p.sent
        diag["plafond_par_passe"] = cap
        diag["sources"] = p.stats
        diag["exclusions_par_motif"] = p.exclusions
        diag["sources_parcourues_en_entier"] = p.complete
        diag["mac_actif"] = macOn
        diag["dossiers_mac"] = mac.map { (x: String) -> String in display(x) }
        diag["dossiers_savoir"] = savoirDirs(excluding: mac).map { (x: String) -> String in display(x) }
        diag["dossiers_refuses_macos"] = p.rootErrors
        diag["documents_dans_index"] = docsBySrc
        diag["morceaux_dans_index"] = chunksBySrc
        diag["morceaux_total"] = chunksBySrc.values.reduce(0, +)
        diag["exclusions_supp"] = p.extra.count
        return diag
    }
}

/// État d'une passe (compteurs, file d'envoi, état incrémental).
final class BiblioPass {
    let c: (app: String, search: String, admin: String)
    let cap: Int
    let extra: [String]
    var docs: [String: Any] = [:]
    var meta: [String: Any] = [:]
    var seen: Set<String> = []
    var pending: [[String: Any]] = []
    var pendingState: [(String, [String: Any]?)] = []
    var sent: Int = 0
    var stopReason: String = ""
    var stats: [String: [String: Int]] = [:]
    var exclusions: [String: Int] = [:]
    var complete: [String: Bool] = [:]
    var rootErrors: [String] = []
    var sinceCheck: Int = 0

    init(c: (app: String, search: String, admin: String), cap: Int, extra: [String]) {
        self.c = c
        self.cap = cap
        self.extra = extra
    }
    var stopped: Bool { return !stopReason.isEmpty }

    func bump(_ src: String, _ k: String, _ n: Int = 1) {
        var s: [String: Int] = stats[src] ?? [:]
        s[k, default: 0] += n
        stats[src] = s
    }
    func exclude(_ src: String, _ motif: String) {
        exclusions[motif, default: 0] += 1
        bump(src, "exclus")
    }
    func saveState() {
        var m: [String: Any] = meta
        m["docs"] = docs
        m["at"] = nowISO()
        m["operations_total"] = ((meta["operations_total"] as? Int) ?? 0) + sent
        AlgoliaBiblio.stateFile.write(m)
    }
    @discardableResult
    func flush() -> Bool {
        if pending.isEmpty { return true }
        let (code, d): (Int, Data) = AlgoliaRelay.request(app: c.app, key: c.admin, path: "/1/indexes/" + AlgoliaBiblio.index + "/batch", body: ["requests": pending], timeout: 30)
        if code != 200 {
            if code > 0 { AlgoliaRelay.failed(status: code, detail: String(decoding: d.prefix(300), as: UTF8.self), op: "write", adminKey: true) }
            stopReason = code > 0 ? "échec d'envoi HTTP " + String(code) : "Algolia injoignable (réseau)"
            pending = []
            pendingState = []
            return false
        }
        Credits.count("algolia", n: 1)
        sent += pending.count
        for (k, v) in pendingState { if let v = v { docs[k] = v } else { docs.removeValue(forKey: k) } }
        pending = []
        pendingState = []
        saveState()
        Thread.sleep(forTimeInterval: 1.5)
        if sent >= cap { stopReason = "plafond par passe atteint (" + String(cap) + " opérations)" }
        else if let y = AlgoliaBiblio.mustYield() { stopReason = y }
        return true
    }
    func queue(_ reqs: [[String: Any]], state: (String, [String: Any]?)) {
        pending.append(contentsOf: reqs)
        pendingState.append(state)
        if pending.count >= AlgoliaBiblio.batchSize { flush() }
    }

    func process(_ d: AlgoliaBiblio.Doc) {
        if stopped { return }
        seen.insert(d.key)
        bump(d.source, "vus")
        let old: [String: Any] = (docs[d.key] as? [String: Any]) ?? [:]
        let oldN: Int = (old["n"] as? Int) ?? 0
        if (old["sig"] as? String) == d.sig {
            if let x = old["x"] as? String, x.hasPrefix("contenu:") { exclusions[x, default: 0] += 1; bump(d.source, "exclus") }
            return
        }
        sinceCheck += 1
        if sinceCheck >= 20 {
            sinceCheck = 0
            if let y = AlgoliaBiblio.mustYield() { stopReason = y; return }
        }
        let raw: String = d.load() ?? ""
        let text: String = AlgoliaBiblio.normalize(raw)
        var reason: String = ""
        if raw.isEmpty { reason = "illisible" }
        else if text.count < 40 { reason = "vide" }
        else if let hit = AlgoliaBiblio.contentHit(text) { reason = "contenu:" + hit }
        if !reason.isEmpty {
            if reason.hasPrefix("contenu:") { exclusions[reason, default: 0] += 1; bump(d.source, "exclus") } else { bump(d.source, reason) }
            let st: [String: Any] = ["sig": d.sig, "n": 0, "src": d.source, "x": reason]
            if oldN > 0 { queue(AlgoliaBiblio.deletes(d.key, from: 0, to: oldN), state: (d.key, st)) } else { docs[d.key] = st }
            return
        }
        let parts: [String] = AlgoliaBiblio.splitText(text, maxBytes: AlgoliaBiblio.chunkBytes)
        var reqs: [[String: Any]] = []
        for (i, p) in parts.enumerated() {
            reqs.append(["action": "updateObject", "body": AlgoliaBiblio.record(d, chunk: p, index: i, total: parts.count)])
        }
        if oldN > parts.count { reqs += AlgoliaBiblio.deletes(d.key, from: parts.count, to: oldN) }
        bump(d.source, "nouveaux_ou_modifies")
        bump(d.source, "morceaux_envoyes", parts.count)
        queue(reqs, state: (d.key, ["sig": d.sig, "n": parts.count, "src": d.source]))
    }

    /// Documents disparus (ou devenus exclus) d'une source parcourue EN ENTIER : leurs enregistrements sont retirés de l'index.
    func purgeMissing() {
        for (k, v) in docs {
            if stopped { return }
            guard let o = v as? [String: Any], let src = o["src"] as? String, complete[src] == true, !seen.contains(k) else { continue }
            let n: Int = (o["n"] as? Int) ?? 0
            bump(src, "supprimes")
            if n > 0 { queue(AlgoliaBiblio.deletes(k, from: 0, to: n), state: (k, nil)) } else { docs.removeValue(forKey: k) }
        }
    }
}

extension Tools {
    /// 31/10 (Algolia biblio) : partout où « recall » ou « know » est permis (Dots, Éclats, Conseil, sous-agents), la bibliothèque
    /// l'est aussi ; « read_file » seul ouvre « lire_fichier_bibliotheque ». nil (tous les outils) reste nil.
    static func withLibraryTools(_ a: Set<String>?) -> Set<String>? {
        guard var s = a else { return nil }
        if s.contains("recall") || s.contains("know") { s.insert("bibliotheque"); s.insert("lire_fichier_bibliotheque") }
        else if s.contains("read_file") { s.insert("lire_fichier_bibliotheque") }
        return s
    }
}
