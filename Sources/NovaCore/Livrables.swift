import Foundation

/// Crochet de rendu PDF : fourni par NovaMac (l'application) via WebKit hors écran + pagination
/// PDFKit. NovaCore seul (serveur sans interface) ne sait pas rendre de PDF — la génération
/// PDF renvoie alors une erreur NOMMÉE plutôt qu'un faux fichier. Même patron que VaultHooks.
public enum LivrableHooks {
    nonisolated(unsafe) public static var htmlToPDF: ((String, String) -> Bool)?
}

/// NOVA2-DOC — Production documentaire CAFU intégrée à Nova.
/// Formats et voies RÉELLES :
///  · PDF  : gabarit maître CAFU (CAFU.renderDoc, le même HTML que cafu_format_document)
///           rendu par WebKit via LivrableHooks → pied paginé « Page X of Y » (hook NovaMac).
///  · HTML : le même gabarit maître, écrit tel quel.
///  · DOCX / PPTX : CAFUOffice (python-docx / python-pptx, charte verrouillée par empreinte
///           SHA-256 sur le Mac) — réutilisé, jamais réimplémenté.
///  · XLSX : OOXML généré directement en Swift (aucune dépendance), styles charte
///           (Aptos, titre #D93226, en-têtes blancs sur #C00000), validé mécaniquement.
/// Historique : le dossier ~/cafu — chaque livrable cafu-* est listé, son sidecar .json
/// (contenu source) sert d'aperçu structuré. RIEN n'est jamais envoyé.
enum Livrables {
    static var dir: URL { Paths.home.appendingPathComponent("cafu", isDirectory: true) }
    static let nameRx = #"^cafu-(note|deck|doc|table|img|pod)-[0-9]{8}-[0-9]{6}\.(docx|pptx|pdf|xlsx|html|webp|png|m4a|wav)$"#   // 25/10 : « pod » = épisode du Podcast hebdo (audio m4a, repli wav)
    static func validName(_ n: String) -> Bool { n.range(of: nameRx, options: .regularExpression) != nil }
    static func path(_ n: String) -> String? { validName(n) ? dir.appendingPathComponent(n).path : nil }
    static func stamp() -> String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }

    /// MN2-2 : dépose une image générée (Muse Image) comme livrable réel, avec sidecar
    /// (titre = le prompt, source = le modèle). Retourne le nom du livrable, ou nil si l'écriture échoue.
    static func saveImage(_ data: Data, ext: String, titre: String, source: String) -> String? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "cafu-img-\(stamp()).\(ext)"
        guard let p = path(name), (try? data.write(to: URL(fileURLWithPath: p))) != nil else { return nil }
        let sc: [String: Any] = ["titre": String(titre.prefix(160)), "source": source, "format": ext]
        try? jsonData(sc).write(to: URL(fileURLWithPath: p + ".json"))
        return name
    }

    // MARK: - Historique (scan du dossier des livrables)

    static func sidecar(_ name: String) -> [String: Any]? {
        guard let p = path(name), let d = FileManager.default.contents(atPath: p + ".json") else { return nil }
        return parseJSON(d)
    }
    static func itemFor(name: String) -> [String: Any]? {
        guard let p = path(name), FileManager.default.fileExists(atPath: p) else { return nil }
        let at = (try? FileManager.default.attributesOfItem(atPath: p)) ?? [:]
        let ext = (name as NSString).pathExtension.lowercased()
        let kind = (name as NSString).lastPathComponent.components(separatedBy: "-").dropFirst().first ?? ""
        let sc = sidecar(name)
        let titre = (sc?["titre"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        let mtime = (at[.modificationDate] as? Date) ?? Date()
        return ["name": name, "path": p, "format": ext, "kind": kind, "titre": titre,
                "size": ((at[.size] as? NSNumber)?.intValue ?? 0),
                "date": ISO8601DateFormatter().string(from: mtime),
                "preview": Livrables.previewKind(ext),
                "structure": sc != nil]
    }
    // 25/10 : type d'aperçu — l'audio (épisodes du podcast) a son lecteur, pas de vignette QuickLook.
    static func previewKind(_ ext: String) -> String {
        if ext == "pdf" { return "pdf" }
        if ext == "html" { return "html" }
        if ext == "m4a" || ext == "wav" { return "audio" }
        return "thumb"
    }
    static func scan() -> [[String: Any]] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { validName($0) }
        return names.compactMap { itemFor(name: $0) }.sorted { ($0["date"] as? String ?? "") > ($1["date"] as? String ?? "") }
    }

    // MARK: - Résolution du contenu

    static func docObject(_ payload: [String: Any]) -> [String: Any]? {
        if let d = payload["doc"] as? [String: Any] { return d }
        if let a = payload["arg"] as? String, let o = CAFU.object(a) { return o }
        var rest = payload
        for k in ["format", "texte"] { rest.removeValue(forKey: k) }
        return rest.isEmpty ? nil : rest
    }
    static func buildDoc(_ payload: [String: Any]) -> CAFU.Doc? {
        if let o = docObject(payload) {
            let d = CAFU.docFromObject(o)
            if !(d.sections.isEmpty && d.callout.isEmpty) { return d }
            // FIXPREP D-R6 / R6-1 — durcissement demandé par FIXPREP-WEB :
            // docObject() retire format/texte et peut donc renvoyer un objet
            // réduit à des métadonnées, typiquement le seul reste {titre}.
            // docFromObject() n'en tire ni section ni encadré : cet objet ne
            // doit plus masquer le repli payload.texte des autres appelants.
            // On ne conclut donc à l'échec qu'après la branche texte ci-dessous.
        }
        if let t = payload["texte"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let tt = (payload["titre"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            // FIXPREP D-R6 / R6-2a : l'UI annonce un JSON du gabarit dans le
            // champ texte. Le lire comme un objet d'abord ; un JSON compact
            // ne doit pas être consommé comme ligne de titre par docFromText().
            if let o = CAFU.object(t) {
                var dj = CAFU.docFromObject(o)
                if !tt.isEmpty { dj.title = tt }
                if !(dj.sections.isEmpty && dj.callout.isEmpty) { return dj }
            }
            // FIXPREP D-R6 / R6-2b : quand le titre est fourni à part, le poser
            // en première ligne pour que docFromText() ne consomme pas la
            // première ligne du corps comme titre avant qu'elle soit écrasée.
            var d = CAFU.docFromText(tt.isEmpty ? t : tt + "\n" + t)
            if !tt.isEmpty { d.title = tt }
            return (d.sections.isEmpty && d.callout.isEmpty) ? nil : d
        }
        return nil
    }

    // MARK: - Génération

    static func generate(format: String, payload: [String: Any]) -> [String: Any] {
        let fmt = format.lowercased().trimmingCharacters(in: .whitespaces)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        switch fmt {
        case "docx", "pptx":
            guard let o = docObject(payload) else { return ["ok": false, "error": "contenu JSON manquant (même structure que cafu_format_docx / cafu_format_deck)"] }
            let arg = (payload["arg"] as? String) ?? jsonString(o)
            let kind = fmt == "pptx" ? "deck" : "docx"
            let r = CAFUOffice.run(kind: kind, arg: arg)
            guard let p = createdPath(r), let item = itemFor(name: (p as NSString).lastPathComponent) else {
                return ["ok": false, "error": shortError(r)]
            }
            var out = item; out["ok"] = true
            let lines = r.components(separatedBy: "\n").dropFirst()
            let audit = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !audit.isEmpty { out["audit"] = audit }
            return out
        case "pdf":
            guard let render = LivrableHooks.htmlToPDF else {
                return ["ok": false, "error": "rendu PDF indisponible : il vit dans l'application macOS Nova (WebKit). Lance Nova.app plutôt que le serveur seul — le HTML, lui, peut être produit tout de suite (format « html »)."]
            }
            guard let d = buildDoc(payload) else { return ["ok": false, "error": "contenu inexploitable : ni section, ni paragraphe, ni encadré (fournir « sections »/« texte » comme cafu_format_document)"] }
            let name = "cafu-doc-\(stamp()).pdf"
            let p = dir.appendingPathComponent(name).path
            let html = CAFU.renderDoc(d)
            try? html.write(toFile: p + ".htmlsrc", atomically: true, encoding: .utf8)   // source du rendu, traçabilité
            if let o = docObject(payload) { try? jsonString(o).write(toFile: p + ".json", atomically: true, encoding: .utf8) }
            guard render(html, p), let data = FileManager.default.contents(atPath: p), data.count > 4,
                  String(bytes: data.prefix(4), encoding: .ascii) == "%PDF" else {
                try? FileManager.default.removeItem(atPath: p)
                return ["ok": false, "error": "le rendu WebKit n'a pas produit de PDF valide (fichier absent ou en-tête non PDF)"]
            }
            guard var item = itemFor(name: name) else { return ["ok": false, "error": "PDF écrit mais illisible à la relecture"] }
            item["ok"] = true
            return item
        case "html":
            guard let d = buildDoc(payload) else { return ["ok": false, "error": "contenu inexploitable : ni section, ni paragraphe, ni encadré"] }
            let name = "cafu-doc-\(stamp()).html"
            let p = dir.appendingPathComponent(name).path
            do { try CAFU.renderDoc(d).write(toFile: p, atomically: true, encoding: .utf8) }
            catch { return ["ok": false, "error": "écriture du HTML impossible : \(error.localizedDescription)"] }
            if let o = docObject(payload) { try? jsonString(o).write(toFile: p + ".json", atomically: true, encoding: .utf8) }
            guard var item = itemFor(name: name) else { return ["ok": false, "error": "HTML écrit mais illisible à la relecture"] }
            item["ok"] = true
            return item
        case "xlsx":
            let sheets = sheetsOf(payload)
            guard !sheets.isEmpty else { return ["ok": false, "error": "aucune feuille exploitable : fournir « feuilles » [{nom, entetes, lignes}], ou « entetes » + « lignes », ou un texte CSV (séparateur ; )"] }
            let titre = (docObject(payload)?["titre"] as? String) ?? (payload["titre"] as? String) ?? ""
            let name = "cafu-table-\(stamp()).xlsx"
            let p = dir.appendingPathComponent(name).path
            if let err = makeXLSX(sheets: sheets, titre: titre, outPath: p) { return ["ok": false, "error": err] }
            if let o = docObject(payload) { try? jsonString(o).write(toFile: p + ".json", atomically: true, encoding: .utf8) }
            guard var item = itemFor(name: name) else { return ["ok": false, "error": "XLSX écrit mais illisible à la relecture"] }
            item["ok"] = true
            return item
        default:
            return ["ok": false, "error": "format inconnu « \(fmt) » — formats produits : pdf, docx, pptx, xlsx, html"]
        }
    }

    /// Extrait le chemin créé du message texte de CAFUOffice (« … créé : /chemin »).
    static func createdPath(_ r: String) -> String? {
        let ns = r as NSString
        guard let rx = try? NSRegularExpression(pattern: #"créé : ([^\n]+)"#),
              let m = rx.firstMatch(in: r, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let p = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    // MARK: - XLSX : OOXML direct (zéro dépendance)

    static func cellStr(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let b = v as? Bool { return b ? "oui" : "non" }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }
    static func sheetsOf(_ payload: [String: Any]) -> [(nom: String, entetes: [String], lignes: [[String]])] {
        let o = docObject(payload) ?? payload
        if let fs = (o["feuilles"] as? [Any]) ?? (o["sheets"] as? [Any]) {
            let out: [(String, [String], [[String]])] = fs.compactMap { f in
                guard let f = f as? [String: Any] else { return nil }
                let nom = sheetName(cellStr(f["nom"] ?? f["name"] ?? f["titre"]))
                let entetes = ((f["entetes"] as? [Any]) ?? (f["headers"] as? [Any]) ?? []).map { cellStr($0) }
                let lignes = ((f["lignes"] as? [Any]) ?? (f["rows"] as? [Any]) ?? []).map { row in ((row as? [Any]) ?? []).map { cellStr($0) } }
                return (nom, entetes, lignes)
            }
            if !out.isEmpty { return out }
        }
        let entetes = ((o["entetes"] as? [Any]) ?? (o["headers"] as? [Any]) ?? []).map { cellStr($0) }
        let lignes = ((o["lignes"] as? [Any]) ?? (o["rows"] as? [Any]) ?? []).map { row in ((row as? [Any]) ?? []).map { cellStr($0) } }
        if !entetes.isEmpty || !lignes.isEmpty { return [(sheetName(cellStr(o["titre"])), entetes, lignes)] }
        if let t = payload["texte"] as? String {
            let rows = t.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .map { line -> [String] in line.components(separatedBy: line.contains("\t") ? "\t" : ";").map { $0.trimmingCharacters(in: .whitespaces) } }
            if let first = rows.first { return [(sheetName(cellStr(payload["titre"])), first, Array(rows.dropFirst()))] }
        }
        return []
    }
    static func sheetName(_ s: String) -> String {
        var n = s.replacingOccurrences(of: #"[\[\]:*?/\\]"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if n.isEmpty { n = "Données" }
        return String(n.prefix(31))
    }
    static func xesc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func colName(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
        return s
    }
    static func isNum(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?$"#, options: .regularExpression) != nil else { return false }
        return Double(t) != nil
    }
    static func cellXML(ref: String, value: String, style: Int?) -> String {
        let sAttr = style.map { " s=\"\($0)\"" } ?? ""
        if isNum(value) { return "<c r=\"\(ref)\"\(sAttr)><v>\(value.trimmingCharacters(in: .whitespaces))</v></c>" }
        let sp = (value.hasPrefix(" ") || value.hasSuffix(" ")) ? " xml:space=\"preserve\"" : ""
        return "<c r=\"\(ref)\"\(sAttr) t=\"inlineStr\"><is><t\(sp)>\(xesc(value))</t></is></c>"
    }
    static func sheetXML(nom: String, entetes: [String], lignes: [[String]], titre: String) -> String {
        let width = max(entetes.count, lignes.map { $0.count }.max() ?? 0, 1)
        var rows: [String] = []
        var r = 0
        if !titre.isEmpty {
            r += 1
            rows.append("<row r=\"\(r)\">" + cellXML(ref: "A\(r)", value: titre, style: 2) + "</row>")
        }
        if !entetes.isEmpty {
            r += 1
            rows.append("<row r=\"\(r)\">" + entetes.enumerated().map { cellXML(ref: "\(colName($0.offset))\(r)", value: $0.element, style: 1) }.joined() + "</row>")
        }
        for line in lignes {
            r += 1
            rows.append("<row r=\"\(r)\">" + line.enumerated().map { cellXML(ref: "\(colName($0.offset))\(r)", value: $0.element, style: nil) }.joined() + "</row>")
        }
        let cols = (0..<width).map { i -> String in
            let w = max(12, min(46, (0..<lignes.count).map { lignes[$0].count > i ? lignes[$0][i].count : 0 }.max() ?? 12))
            return "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(entetes.count > i ? max(w, entetes[i].count + 2) : w)\" customWidth=\"1\"/>"
        }.joined()
        let merge = (!titre.isEmpty && width > 1) ? "<mergeCells count=\"1\"><mergeCell ref=\"A1:\(colName(width - 1))1\"/></mergeCells>" : ""
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><dimension ref=\"A1:\(colName(width - 1))\(max(r, 1))\"/><sheetViews><sheetView workbookViewId=\"0\"/></sheetViews><sheetFormatPr defaultRowHeight=\"15\"/><cols>\(cols)</cols><sheetData>\(rows.joined())</sheetData>\(merge)</worksheet>"
    }
    /// Construit le classeur dans un dossier temporaire, le zippe à outPath, puis VALIDE
    /// (signature PK, intégrité zip, workbook relisible). Renvoie nil si tout passe, sinon l'erreur.
    static func makeXLSX(sheets: [(nom: String, entetes: [String], lignes: [[String]])], titre: String, outPath: String) -> String? {
        let fm = FileManager.default
        let stage = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nova-xlsx-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        do {
            for sub in ["_rels", "xl/_rels", "xl/worksheets", "docProps"] { try fm.createDirectory(at: stage.appendingPathComponent(sub), withIntermediateDirectories: true) }
            func w(_ rel: String, _ content: String) throws { try content.write(to: stage.appendingPathComponent(rel), atomically: true, encoding: .utf8) }
            var overrides = "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/><Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
            for i in sheets.indices { overrides += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }
            try w("[Content_Types].xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>\(overrides)</Types>")
            try w("_rels/.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
            let sheetEls = sheets.enumerated().map { "<sheet name=\"\(xesc($0.element.nom))\" sheetId=\"\($0.offset + 1)\" r:id=\"rId\($0.offset + 1)\"/>" }.joined()
            try w("xl/workbook.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>\(sheetEls)</sheets></workbook>")
            var rels = sheets.enumerated().map { "<Relationship Id=\"rId\($0.offset + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0.offset + 1).xml\"/>" }.joined()
            rels += "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
            try w("xl/_rels/workbook.xml.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)</Relationships>")
            try w("xl/styles.xml", stylesXML)
            let now = ISO8601DateFormatter().string(from: Date())
            try w("docProps/core.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>\(xesc(titre.isEmpty ? "Livrable CAFU" : titre))</dc:title><dc:creator>Nova — CAFU</dc:creator><dcterms:created xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:type=\"dcterms:W3CDTF\">\(now)</dcterms:created></cp:coreProperties>")
            for (i, sh) in sheets.enumerated() { try w("xl/worksheets/sheet\(i + 1).xml", sheetXML(nom: sh.nom, entetes: sh.entetes, lignes: sh.lignes, titre: i == 0 ? titre : "")) }
        } catch { return "préparation du classeur impossible : \(error.localizedDescription)" }
        let zip = runProcess("/bin/zsh", ["-fc", "cd -- \"$1\" && /usr/bin/zip -q -r \"$2\" .", "zsh", stage.path, outPath], timeout: 30)   // WP5 (A) : chemins passés en arguments, jamais interpolés dans le script
        guard zip.0 == 0, let data = fm.contents(atPath: outPath), data.count > 22 else {
            return "compression du classeur en échec (zip code \(zip.0))"
        }
        guard data.count >= 2, data[0] == 0x50, data[1] == 0x4B else { return "classeur produit sans signature ZIP (PK) — rejeté" }
        guard runProcess("/usr/bin/unzip", ["-t", outPath], timeout: 20).0 == 0 else { return "classeur produit mais illisible (unzip -t en échec) — rejeté" }
        let wb = runProcess("/usr/bin/unzip", ["-p", outPath, "xl/workbook.xml"], timeout: 10)
        guard wb.0 == 0, wb.1.contains("<sheet") else { return "classeur produit mais workbook.xml absent — rejeté" }
        return nil
    }
    static let stylesXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="3"><font><sz val="11"/><name val="Aptos"/><color rgb="FF000000"/></font><font><b/><sz val="11"/><name val="Aptos"/><color rgb="FFFFFFFF"/></font><font><b/><sz val="15"/><name val="Aptos"/><color rgb="FFD93226"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFC00000"/><bgColor rgb="FFC00000"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/><xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
"""

    // MARK: - Aperçus, fichiers, ouverture

    static func contentType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "html": return "text/html; charset=utf-8"
        case "webp": return "image/webp"
        case "png": return "image/png"
        case "m4a": return "audio/mp4"   // 25/10 : podcast hebdo
        case "wav": return "audio/wav"
        default: return "application/octet-stream"
        }
    }
    static func thumb(_ n: String) -> Data? {
        if n.hasSuffix(".docx") || n.hasSuffix(".pptx") { return CAFUOffice.thumb(n) }   // noms cafu-note-/cafu-deck- : QuickLook existant
        guard let p = path(n), FileManager.default.fileExists(atPath: p) else { return nil }
        let cache = p + ".png"
        if let d = FileManager.default.contents(atPath: cache), d.count > 500 { return d }
        let tmp = NSTemporaryDirectory() + "nova-ql-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        _ = runProcess("/usr/bin/qlmanage", ["-t", "-s", "1400", "-o", tmp, p], timeout: 30)
        guard let d = FileManager.default.contents(atPath: tmp + "/" + n + ".png"), d.count > 500 else { return nil }
        try? d.write(to: URL(fileURLWithPath: cache))
        return d
    }
    static func meta(_ n: String) -> [String: Any] {
        if n.hasSuffix(".docx") || n.hasSuffix(".pptx") { return CAFUOffice.meta(n) }
        guard let p = path(n), FileManager.default.fileExists(atPath: p) else { return ["error": "livrable introuvable"] }
        var out: [String: Any] = ["name": n, "kind": n.hasSuffix(".pdf") ? "doc" : (n.hasSuffix(".xlsx") ? "table" : "doc"),
                                  "path": p, "data": sidecar(n) ?? [String: Any](), "structure_source": "sidecar"]
        if n.hasSuffix(".pdf"), let t = VaultHooks.pdfText?(p), !t.isEmpty { out["texte_extrait"] = String(t.prefix(1600)) }
        return out
    }
    static func openFile(_ n: String) -> Bool {
        guard let p = path(n), FileManager.default.fileExists(atPath: p) else { return false }
        return runProcess("/usr/bin/open", [p], timeout: 10).0 == 0
    }

    /// 25/10 : « bytes=a-b », « bytes=a- » ou « bytes=-n » → bornes incluses ; nil si invalide.
    static func byteRange(_ h: String, total: Int) -> (lo: Int, hi: Int)? {
        guard total > 0, h.lowercased().hasPrefix("bytes=") else { return nil }
        let spec: String = String(h.dropFirst(6)).components(separatedBy: ",").first ?? ""
        let parts: [String] = spec.components(separatedBy: "-")
        guard parts.count == 2 else { return nil }
        let a: String = parts[0].trimmingCharacters(in: .whitespaces)
        let b: String = parts[1].trimmingCharacters(in: .whitespaces)
        var lo: Int = 0
        var hi: Int = total - 1
        if a.isEmpty {
            guard let n = Int(b), n > 0 else { return nil }
            lo = max(0, total - n)
        } else {
            guard let x = Int(a) else { return nil }
            lo = x
            if !b.isEmpty, let y = Int(b) { hi = min(y, total - 1) }
        }
        if lo > hi || lo >= total { return nil }
        return (lo: lo, hi: hi)
    }

    // MARK: - Routes

    static func register(on s: HTTPServer) {
        s.on("POST", "/api/livrables/generate") { req, res in
            let r = generate(format: (req.json["format"] as? String) ?? "", payload: req.json)
            res.json(r, status: (r["ok"] as? Bool) == true ? 200 : 422)
        }
        s.on("GET", "/api/livrables") { _, res in res.json(["items": scan()]) }
        s.on("GET", "/api/livrables/file") { req, res in
            let n = req.query["name"] ?? ""
            guard let p = path(n), let d = FileManager.default.contents(atPath: p) else { res.json(["error": "livrable introuvable"], status: 404); return }
            let dl = req.query["dl"] == "1"
            let disp: String = (dl ? "attachment" : "inline") + "; filename=\"" + n + "\""
            // 25/10 : WebKit lit l'audio par plages (Range) — on répond 206 pour que <audio> joue et se déplace.
            let rangeHdr: String = req.headers["range"] ?? ""
            if !dl, !rangeHdr.isEmpty, let part = Livrables.byteRange(rangeHdr, total: d.count) {
                let slice: Data = d.subdata(in: part.lo..<(part.hi + 1))
                let cr: String = "bytes " + String(part.lo) + "-" + String(part.hi) + "/" + String(d.count)
                let ex: [String: String] = ["Content-Disposition": disp, "Accept-Ranges": "bytes", "Content-Range": cr]
                res.data(slice, type: contentType(n), status: 206, extra: ex)
                return
            }
            res.data(d, type: contentType(n), extra: ["Content-Disposition": disp, "Accept-Ranges": "bytes"])
        }
        s.on("GET", "/api/livrables/thumb") { req, res in
            if let d = thumb(req.query["name"] ?? "") { res.data(d, type: "image/png") } else { res.json(["error": "aperçu indisponible"], status: 404) }
        }
        s.on("GET", "/api/livrables/meta") { req, res in res.json(meta(req.query["name"] ?? "")) }
        s.on("POST", "/api/livrables/open") { req, res in res.json(["ok": openFile((req.json["name"] as? String) ?? "")]) }
    }

    // MARK: - Outils du chat

    static func jsonEsc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
    static func cardInstruction(_ item: [String: Any]) -> String {
        let name = item["name"] as? String ?? "", titre = item["titre"] as? String ?? name
        let format = item["format"] as? String ?? "", size = (item["size"] as? NSNumber)?.intValue ?? 0
        return "\nPour afficher la carte du livrable dans la conversation, ajoute à ta réponse ce bloc exact :\n```nova-livrable\n{\"name\":\"\(jsonEsc(name))\",\"titre\":\"\(jsonEsc(titre))\",\"format\":\"\(jsonEsc(format))\",\"size\":\(size)}\n```"
    }
    /// Ajoute l'instruction de carte aux résultats des outils CAFUOffice / CAFU.document existants.
    static func withCard(_ result: String) -> String {
        let ns = result as NSString
        let patterns = [#"créé : ([^\n]+)"#, #"Fichier HTML : ([^\n]+)"#]
        for pat in patterns {
            guard let rx = try? NSRegularExpression(pattern: pat),
                  let m = rx.firstMatch(in: result, range: NSRange(location: 0, length: ns.length)) else { continue }
            let p = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let name = (p as NSString).lastPathComponent
            if validName(name), let item = itemFor(name: name) { return result + cardInstruction(item) }
        }
        return result
    }
    static func toolPDF(arg: String) -> String {
        guard let o = CAFU.object(arg) else { return "cafu_format_pdf : argument = JSON {\"titre\",\"sous_titre\",\"encadre\",\"sections\":[{\"titre\",\"texte\",\"points\":[…]}],\"limites\":[…]} (même contenu que cafu_format_document)." }
        let r = generate(format: "pdf", payload: ["doc": o])
        guard (r["ok"] as? Bool) == true else { return "cafu_format_pdf : " + ((r["error"] as? String) ?? "échec inconnu") }
        return "Document PDF CAFU créé : \(r["path"] as? String ?? "")\nGabarit maître CAFU (fond #ECE9E3, en-tête orange + logo SCI, titre #D93226, sections #C00000, BLUF, boîte limites, pied paginé « Page X of Y »). RIEN n'a été envoyé." + cardInstruction(r)
    }
    static func toolTable(arg: String) -> String {
        guard let o = CAFU.object(arg) else { return "cafu_format_table : argument = JSON {\"titre\",\"feuilles\":[{\"nom\",\"entetes\":[…],\"lignes\":[[…]]}]} ou {\"titre\",\"entetes\":[…],\"lignes\":[[…]]}." }
        let r = generate(format: "xlsx", payload: ["doc": o])
        guard (r["ok"] as? Bool) == true else { return "cafu_format_table : " + ((r["error"] as? String) ?? "échec inconnu") }
        return "Classeur Excel CAFU créé : \(r["path"] as? String ?? "")\nOOXML direct (Aptos, titre #D93226, en-têtes blancs sur fond #C00000), intégrité vérifiée (signature ZIP + workbook relisible). RIEN n'a été envoyé." + cardInstruction(r)
    }
}
