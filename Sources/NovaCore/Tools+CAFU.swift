import Foundation
#if os(macOS)
import AppKit
#endif
#if canImport(EventKit) && os(macOS)
import EventKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Découpé de Tools.swift (19/10) : enum CAFU (charte) — déplacé à l'identique.
// MARK: - Charte CAFU Save the Children (Phase 10)
/// Mise en forme aux couleurs de la charte CAFU. Produit UNIQUEMENT du texte et un fichier HTML local : jamais d'envoi, jamais d'écriture dans le presse-papiers.
enum CAFU {
    static let font = "Aptos, 'Segoe UI', Calibri, Arial, sans-serif"
    static let sand = "#ECE9E3", red = "#C00000", cream = "#F5F3EE", footerRed = "#AD1F23"

    // MARK: utilitaires
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    /// Échappe puis convertit **gras** en <b>.
    static func rich(_ s: String) -> String {
        var h = esc(s).replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<b>$1</b>", options: .regularExpression)
        // [[PASTILLE]] : rouge (solide, prêt) ou orange (à vérifier, à confirmer, nuance) — modèle Peer Review
        if let rx = try? NSRegularExpression(pattern: #"\[\[(.+?)\]\]"#) {
            let ns = h as NSString
            for m in rx.matches(in: h, range: NSRange(location: 0, length: ns.length)).reversed() {
                let tag = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces).uppercased()
                let orange = ["NUANCE", "INCERTAIN"].contains(tag) || tag.contains("CHECK") || tag.contains("CONFIRM") || tag.contains("VALID") || tag.contains("VÉRIF") || tag.contains("VERIF")
                h = (h as NSString).replacingCharacters(in: m.range, with: "<span class=\"pill \(orange ? "orange" : "red")\">\(tag)</span>")
            }
        }
        return h
    }
    static func plain(_ s: String) -> String { s.replacingOccurrences(of: "**", with: "") }
    static func str(_ v: Any?) -> String { (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    static func strs(_ v: Any?) -> [String] {
        if let s = v as? String { return s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        return ((v as? [Any]) ?? []).compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    static func firstStr(_ o: [String: Any], _ keys: [String]) -> String { for k in keys { let s = str(o[k]); if !s.isEmpty { return s } }; return "" }
    /// Groupes capturés (groupe 0 exclu) si le motif correspond, sinon nil.
    static func cap(_ pattern: String, _ s: String) -> [String]? {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).dropFirst().map { let r = m.range(at: $0); return r.location == NSNotFound ? "" : ns.substring(with: r) }
    }
    static func object(_ a: String) -> [String: Any]? {
        var t = a.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: #"^```[a-zA-Z]*\s*"#, with: "", options: .regularExpression).replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        guard t.hasPrefix("{") else { return nil }
        return parseJSON(Data(t.utf8))
    }
    static func frDate(_ d: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "d MMMM yyyy"; return f.string(from: d)
    }
    static func save(_ html: String, prefix: String) -> String? {
        let dir = Paths.home.appendingPathComponent("cafu", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("\(prefix)-\(f.string(from: Date())).html")
        do { try html.write(to: url, atomically: true, encoding: .utf8); return url.path } catch { return nil }
    }
    /// Commande à lancer par l'utilisateur dans Terminal : met le HTML dans SON presse-papiers (format riche). Nova ne l'exécute jamais.
    static func clipboardCommand(_ path: String) -> String {
        let q = path.replacingOccurrences(of: "'", with: "'\\''")
        return "osascript -e \"set the clipboard to «data HTML$(xxd -p '\(q)' | tr -d '\\n')»\""
    }

    // MARK: note d'analyse
    struct Section { var heading = ""; var paras: [String] = []; var points: [String] = []; var ordered = false }
    struct Doc { var title = ""; var subtitle = ""; var sections: [Section] = []; var callout = ""; var calloutTitle = "À retenir"; var footer = ""; var status = ""; var limits: [String] = []; var limitsTitle = ""; var missing: [String] = [] }

    static func docFromObject(_ o: [String: Any]) -> Doc {
        var d = Doc()
        d.title = firstStr(o, ["titre", "title"]); d.subtitle = firstStr(o, ["sous_titre", "sous-titre", "subtitle"])
        d.callout = firstStr(o, ["encadre", "encadré", "callout"]); let ct = firstStr(o, ["encadre_titre", "callout_title"]); if !ct.isEmpty { d.calloutTitle = ct }
        d.footer = firstStr(o, ["pied", "footer", "reference", "source"]); d.status = firstStr(o, ["statut", "status"]); d.limits = strs(o["limites"] ?? o["limits"]); d.limitsTitle = firstStr(o, ["limites_titre", "limits_title"])
        for case let s as [String: Any] in (o["sections"] as? [Any]) ?? [] {
            var sec = Section(); sec.heading = firstStr(s, ["titre", "heading", "title"])
            sec.paras = strs(s["texte"] ?? s["body"] ?? s["paragraphes"]); sec.points = strs(s["points"] ?? s["bullets"]); sec.ordered = (s["ordonne"] as? Bool) ?? false
            if !sec.heading.isEmpty || !sec.paras.isEmpty || !sec.points.isEmpty { d.sections.append(sec) }
        }
        if d.sections.isEmpty {
            let body = strs(o["texte"] ?? o["body"] ?? o["contenu"]); let pts = strs(o["points"])
            if !body.isEmpty || !pts.isEmpty { var sec = Section(); sec.paras = body; sec.points = pts; d.sections.append(sec) }
        }
        return d
    }
    static func docFromText(_ t: String) -> Doc {
        var d = Doc(); var cur = Section()
        func flush() { if !cur.heading.isEmpty || !cur.paras.isEmpty || !cur.points.isEmpty { d.sections.append(cur) }; cur = Section() }
        for raw in t.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces); if l.isEmpty { continue }
            if d.title.isEmpty && d.sections.isEmpty && cur.heading.isEmpty && cur.paras.isEmpty && cur.points.isEmpty {
                d.title = l.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression).replacingOccurrences(of: "**", with: ""); continue }
            if let g = cap(#"^#{1,4}\s+(.+)$"#, l) { flush(); cur.heading = plain(g[0]); continue }
            if let g = cap(#"^(?:à retenir|a retenir|encadré|encadre|en bref|point d'attention)\s*:\s*(.+)$"#, l) { d.callout += (d.callout.isEmpty ? "" : " ") + g[0]; continue }
            if let g = cap(#"^>\s*(.+)$"#, l) { d.callout += (d.callout.isEmpty ? "" : " ") + g[0]; continue }
            if let g = cap(#"^\d+[.)]\s+(.+)$"#, l) { cur.points.append(g[0]); cur.ordered = true; continue }
            if let g = cap(#"^[-•–*]\s+(.+)$"#, l) { cur.points.append(g[0]); continue }
            let short = l.count <= 80 && !l.hasSuffix(".") && (l.hasSuffix(":") || l == l.uppercased())
            if short && l.rangeOfCharacter(from: .letters) != nil { flush(); cur.heading = plain(l).trimmingCharacters(in: CharacterSet(charactersIn: ": ")); continue }
            cur.paras.append(l)
        }
        flush()
        return d
    }
    /// GABARIT CAFU MAÎTRE (verrouillé 10/10, réadopté 14/10) : CSS recopié à l'identique de GABARIT_CAFU_MASTER_verrouille.html — palette {#D93226,#C00000,#F0A22E,#ECE9E3,#000,#666}, zéro emoji. Le logo SCI n'est pas embarqué.
    static let masterCSS = #"""
  :root{--cafu-red:#D93226;--cafu-deep:#C00000;--cafu-orange:#F0A22E;--cafu-page:#ECE9E3;--cafu-text:#000000;--cafu-muted:#666666;--cafu-font:Helvetica,"Helvetica Neue",Arial,sans-serif}
  *{box-sizing:border-box}
  body{margin:0;background:var(--cafu-page);color:var(--cafu-text);font-family:var(--cafu-font);line-height:1.55}
  .page{max-width:880px;margin:0 auto;padding:40px 44px 56px}
  .header-box{border:2px solid var(--cafu-orange);padding:14px 18px;margin-bottom:10px;background:rgba(255,255,255,.35);display:flex;align-items:center;justify-content:space-between;gap:16px}
  .header-text .l1{font-weight:700;letter-spacing:.06em}
  .header-text .l2{margin-top:4px}
  .header-text .l3{margin-top:4px;font-style:italic;color:var(--cafu-muted)}
  .meta{text-align:right;font-size:12px;color:var(--cafu-muted);margin:8px 0 18px}
  .meta .draft{font-weight:700;color:var(--cafu-red)}
  h1{color:var(--cafu-red);font-size:34px;margin:0 0 6px;letter-spacing:-.01em}
  .subtitle{font-style:italic;color:var(--cafu-muted);margin:0 0 22px;font-size:15px}
  .bluf{border-left:5px solid var(--cafu-red);background:rgba(255,255,255,.55);padding:14px 18px;margin:0 0 28px;font-size:16px}
  .bluf strong{color:var(--cafu-red)}
  h2{color:var(--cafu-deep);font-size:20px;margin:30px 0 10px;display:flex;align-items:center;gap:10px}
  h3{font-size:16px;margin:18px 0 8px;display:flex;align-items:center;gap:10px}
  .pill{display:inline-block;color:#fff;font-weight:700;font-size:11px;letter-spacing:.08em;text-transform:uppercase;padding:2px 9px;border-radius:3px;line-height:1.5;white-space:nowrap}
  .pill.red{background:var(--cafu-red)}.pill.orange{background:var(--cafu-orange)}
  .logo{width:76px;height:76px;flex:none}
  p{margin:8px 0}
  ul{margin:6px 0 14px;padding-left:4px;list-style:none}
  ul li{position:relative;padding-left:22px;margin:7px 0}
  ul li::before{content:"";position:absolute;left:2px;top:9px;width:8px;height:8px;background:var(--cafu-red)}
  ol{margin:6px 0 14px;padding-left:24px}ol li{margin:7px 0}
  .limits{border:2px solid var(--cafu-orange);padding:14px 18px;margin-top:30px;background:rgba(255,255,255,.35)}
  .limits h2{margin-top:0}
  .footer{margin-top:36px;padding-top:12px;border-top:2px solid var(--cafu-red);font-style:italic;color:var(--cafu-red);font-size:13px;text-align:center}
  @media (max-width:640px){.page{padding:24px 18px 40px}h1{font-size:27px}}
  @page{size:A4;margin:0}
  @media print{body{background:var(--cafu-page) !important;-webkit-print-color-adjust:exact;print-color-adjust:exact}.page{max-width:none;padding:34px 44px 50px !important}.limits{break-inside:avoid}}
"""#
    static func renderDoc(_ d: Doc) -> String {
        let title = d.title.isEmpty ? "Note d'analyse" : d.title
        var h = "<!doctype html>\n<html lang=\"fr\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>\(esc(title))</title>\n<style>\n" + masterCSS + "</style></head><body>\n<div class=\"page\">\n"
        h += "<div class=\"header-box\"><div class=\"header-text\"><div class=\"l1\">FOR INTERNAL USE ONLY</div><div class=\"l2\">Context Analysis and Foresight Unit (CAFU)</div><div class=\"l3\">Strategic Analysis</div></div><img class=\"logo\" alt=\"Save the Children\" src=\"data:image/png;base64,\(CAFULogo.b64)\"></div>\n"
        h += "<div class=\"meta\">\(esc(frDate())) &nbsp;·&nbsp; <span class=\"draft\">\(esc(d.status.isEmpty ? "DRAFT — working document" : d.status))</span></div>\n"
        h += "<h1>\(esc(title))</h1>\n"
        if !d.subtitle.isEmpty { h += "<p class=\"subtitle\">\(rich(d.subtitle))</p>\n" }
        if !d.callout.isEmpty { h += "<div class=\"bluf\">\(rich(d.callout))</div>\n" }
        for s in d.sections {
            if !s.heading.isEmpty { let t = s.heading.trimmingCharacters(in: .whitespaces).hasPrefix("[[") ? "h3" : "h2"; h += "<\(t)>\(rich(s.heading))</\(t)>\n" }
            for p in s.paras { h += "<p>\(rich(p))</p>\n" }
            if !s.points.isEmpty { let tag = s.ordered ? "ol" : "ul"; h += "<\(tag)>\n" + s.points.map { "<li>\(rich($0))</li>\n" }.joined() + "</\(tag)>\n" }
        }
        if !d.limits.isEmpty { h += "<div class=\"limits\"><h2>\(esc(d.limitsTitle.isEmpty ? "Limits and verification" : d.limitsTitle))</h2><ul>\n" + d.limits.map { "<li>\(rich($0))</li>\n" }.joined() + "</ul></div>\n" }
        h += "<div class=\"footer\">\(esc(d.footer.isEmpty ? "For feedback or questions, please contact: Ahadi Dahani" : d.footer))</div>\n</div>\n</body></html>\n"
        return h
    }
    static func textOfDoc(_ d: Doc) -> String {
        var o = [d.title.isEmpty ? "Note d'analyse" : d.title]
        if !d.subtitle.isEmpty { o.append(d.subtitle) }
        for s in d.sections {
            if !s.heading.isEmpty { o.append("\n" + s.heading.uppercased()) }
            o += s.paras.map { plain($0) }
            o += s.points.enumerated().map { (s.ordered ? "\($0.offset + 1). " : "- ") + plain($0.element) }
        }
        if !d.callout.isEmpty { o.append("\n[" + d.calloutTitle + "] " + plain(d.callout)) }
        return o.joined(separator: "\n")
    }
    static func document(_ arg: String) -> String {
        let a = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return "cafu_format_document : argument vide (JSON {\"titre\",\"sections\":[…]} ou texte brut de la note)." }
        var d = object(a).map(docFromObject) ?? docFromText(a)
        if d.sections.isEmpty && d.callout.isEmpty { return "cafu_format_document : aucun contenu exploitable (ni section, ni paragraphe, ni point)." }
        if d.title.isEmpty { d.missing.append("titre") }
        if d.callout.isEmpty { d.missing.append("encadré de synthèse") }
        let html = renderDoc(d)
        guard let path = save(html, prefix: "cafu-note") else { return "cafu_format_document : écriture du fichier impossible (dossier de données de Nova non inscriptible)." }
        var out = "Note mise en forme sur le GABARIT CAFU MAÎTRE (fond #ECE9E3, en-tête orange, titre #D93226, BLUF, puces carrées, boîte limites, pied rouge ; export PDF : Chrome headless). Rien n'a été envoyé.\nFichier HTML : \(path)\n"
        if !d.missing.isEmpty { out += "Éléments absents du contenu fourni (non inventés) : \(d.missing.joined(separator: ", ")).\n" }
        out += "Pour mettre cette version riche dans TON presse-papiers, lance toi-même dans Terminal :\n\(clipboardCommand(path))\n(Le presse-papiers n'est pas chargé tant que tu ne l'as pas lancée et confirmé.)\n\n--- Aperçu texte ---\n" + String(textOfDoc(d).prefix(2500))
        return out
    }

    // MARK: email / message Teams
    struct Mail { var kind = "email"; var to = ""; var subject = ""; var objective = ""; var greeting = ""; var politeness = ""; var context = ""; var points: [String] = []; var ordered = false; var action = ""; var closing = ""; var signature = ""; var missing: [String] = [] }

    static func mailFromObject(_ o: [String: Any]) -> Mail {
        var m = Mail()
        let k = firstStr(o, ["type", "kind", "canal"]).lowercased(); m.kind = k.contains("team") ? "teams" : "email"
        m.to = firstStr(o, ["destinataire", "to"]); m.subject = firstStr(o, ["objet", "subject"]); m.objective = firstStr(o, ["objectif", "objective"]); m.greeting = firstStr(o, ["salutation", "greeting"])
        m.politeness = firstStr(o, ["politesse", "politeness"]); m.context = firstStr(o, ["contexte", "context"]); m.points = strs(o["points"]); m.ordered = (o["ordonne"] as? Bool) ?? false
        m.action = firstStr(o, ["action", "action_demandee"]); m.closing = firstStr(o, ["cloture", "clôture", "closing"]); m.signature = firstStr(o, ["signature"])
        return m
    }
    static let closingRx = #"(cordialement|salutations|bien à vous|bien a vous|bonne journée|bonne journee|bonne soirée|respectueusement|dans l'attente|thanks|regards|merci d'avance|merci beaucoup)"#
    static func mailFromText(_ t: String) -> Mail {
        var m = Mail(); var paras: [String] = []
        for raw in t.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces); if l.isEmpty { continue }
            if m.subject.isEmpty, let g = cap(#"^(?:objet|subject)\s*:\s*(.+)$"#, l) { m.subject = g[0]; continue }
            if m.to.isEmpty, let g = cap(#"^(?:à|a|to|destinataire)\s*:\s*(.+)$"#, l) { m.to = g[0]; continue }
            if let g = cap(#"^\d+[.)]\s+(.+)$"#, l) { m.points.append(g[0]); m.ordered = true; continue }
            if let g = cap(#"^[-•–*]\s+(.+)$"#, l) { m.points.append(g[0]); continue }
            paras.append(l)
        }
        if let f = paras.first, cap(#"^(bonjour|bonsoir|cher|chère|chere|madame|monsieur|hello|salut|dear)\b"#, f) != nil { m.greeting = f; paras.removeFirst() }
        if let l = paras.last, l.count <= 80, cap(closingRx, l) != nil { m.closing = l; paras.removeLast() }
        if let i = paras.lastIndex(where: { $0.contains("**") || cap(#"^(action|merci de|veuillez|pouvez-vous|pourriez-vous|je vous demande|prière de|priere de)"#, $0) != nil }) {
            m.action = paras.remove(at: i).replacingOccurrences(of: #"^\**\s*action(?: demandée| demandee)?\s*:?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        m.context = paras.joined(separator: " ")
        return m
    }
    static func boldLead(_ p: String) -> String {
        if p.contains("**") { return rich(p) }
        if let r = p.range(of: " : "), p.distance(from: p.startIndex, to: r.lowerBound) <= 60 { return "<b>" + esc(String(p[..<r.lowerBound])) + "</b> : " + esc(String(p[r.upperBound...])) }
        return esc(p)
    }
    static let ff = "font-family:'Aptos',Calibri,Arial,Helvetica,sans-serif;"
    /// Charte mail/Teams du 05/10/2026 : en-tête à bordure rouge, blocs numérotés 01/02 (le dernier = action requise), « Best, » + prénom. Style inline sur chaque élément, jamais de <body>, pas de surlignage jaune, pas de signature institutionnelle.
    static func renderMail(_ m: Mail) -> String {
        func block(_ n: Int, _ title: String, _ body: String) -> String {
            let num: String = String(format: "%02d", n)
            var r: String = "<div style=\"border-left:3px solid #D93226;padding-left:10px;margin:14px 0;\">\n"
            r += "<div style=\"" + ff + "font-size:10pt;font-weight:bold;color:#404040;\">" + num + "</div>\n"
            r += "<div style=\"" + ff + "font-size:11pt;font-weight:bold;color:#000000;margin:2px 0 4px 0;\">" + title + "</div>\n"
            if !body.isEmpty { r += "<div style=\"" + ff + "font-size:11pt;line-height:1.45;color:#000000;\">" + body + "</div>\n" }
            r += "</div>\n"
            return r
        }
        var h = "<meta charset=\"utf-8\">\n<div style=\"\(ff)font-size:11pt;line-height:1.45;color:#000000;\">\n"
        let topic = "[" + (m.subject.isEmpty ? "CAFU" : esc(m.subject.uppercased())) + "] - CAFU"
        h += "<div style=\"border-left:3px solid #D93226;padding-left:10px;margin:0 0 14px 0;\">\n<div style=\"\(ff)font-size:10pt;font-weight:bold;color:#404040;letter-spacing:0.4px;\">\(topic)</div>\n"
        if !m.subject.isEmpty { h += "<div style=\"\(ff)font-size:13pt;font-weight:bold;color:#000000;margin:2px 0;\">\(esc(m.objective.isEmpty ? m.subject : m.objective))</div>\n" }
        h += "</div>\n<p style=\"\(ff)font-size:11pt;line-height:1.45;color:#000000;margin:0 0 10px 0;\">\(esc(m.greeting))</p>\n"
        if !m.politeness.isEmpty { h += "<p style=\"\(ff)font-size:11pt;line-height:1.45;color:#000000;margin:0 0 10px 0;\">\(esc(m.politeness))</p>\n" }
        if !m.context.isEmpty { h += "<p style=\"\(ff)font-size:11pt;line-height:1.45;color:#000000;margin:0 0 10px 0;\">\(rich(m.context))</p>\n" }
        var n = 0
        for p in m.points {
            n += 1
            if let r = p.range(of: " : "), p.distance(from: p.startIndex, to: r.lowerBound) <= 60 { h += block(n, esc(plain(String(p[..<r.lowerBound]))), rich(String(p[r.upperBound...]))) }
            else { h += block(n, rich(p), "") }
        }
        if !m.action.isEmpty { n += 1; h += block(n, esc(plain(m.action)), "") }
        let sig: String = m.signature.isEmpty ? "Ahadi" : m.signature
        h += "<p style=\"" + ff + "font-size:11pt;line-height:1.45;color:#000000;margin:14px 0 0 0;\">" + esc(m.closing) + "<br><br>" + esc(sig) + "</p>\n</div>\n"
        return h
    }
    /// P-DRAFT-5 — Texte CANONIQUE du mail (gabarit verrouillé) : c'est ce texte qui est stocké
    /// dans le brouillon, montré sur la carte et envoyé en texte brut. En-tête « [SUJET] - CAFU »
    /// + objectif en une ligne (l'ancien « Objet : » disparaît : l'objet vit dans le champ du
    /// brouillon), politesse après la salutation, points « 01 » seuls sur leur ligne suivis du
    /// titre puis du texte, action = dernier point numéroté (plus de préfixe « Action demandée : »).
    static func textOfMail(_ m: Mail) -> String {
        if m.kind == "teams" { return textOfTeams(m) }
        var o: [String] = []
        if !m.subject.isEmpty { o.append("[" + m.subject.uppercased() + "] - CAFU"); o.append(m.objective.isEmpty ? m.subject : m.objective); o.append("") }
        o.append(m.greeting)
        if !m.politeness.isEmpty { o.append(m.politeness) }
        if !m.context.isEmpty { o.append("\n" + plain(m.context)) }
        var n = 0
        func bloc(_ titreEtTexte: String) {
            n += 1; o.append(""); o.append(String(format: "%02d", n))
            let t = plain(titreEtTexte)
            if let r = t.range(of: " : "), t.distance(from: t.startIndex, to: r.lowerBound) <= 60 { o.append(String(t[..<r.lowerBound])); o.append(String(t[r.upperBound...])) } else { o.append(t) }
        }
        for p in m.points { bloc(p) }
        if !m.action.isEmpty { bloc(m.action) }
        o.append("\n" + m.closing + (m.signature.isEmpty ? "" : "\n" + m.signature))
        return o.joined(separator: "\n")
    }
    /// P-DRAFT-5 — Standard Teams verrouillé : bloc fluide (paragraphes sobres, pas de
    /// numérotation pour un message court), signé « — Ahadi ». Ni en-tête, ni objet, ni « Best, ».
    static func textOfTeams(_ m: Mail) -> String {
        var paras: [String] = []
        if !m.context.isEmpty { paras.append(plain(m.context)) }
        paras += m.points.map { plain($0) }
        if !m.action.isEmpty { paras.append(plain(m.action)) }
        let t = paras.joined(separator: "\n\n")
        return (t.isEmpty ? "" : t + "\n\n") + "— Ahadi"
    }
    static func email(_ arg: String) -> String {
        let a = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return "cafu_format_email : argument vide (JSON {\"type\",\"destinataire\",\"objet\",\"contexte\",\"points\",\"action\",\"cloture\"} ou texte brut du message)." }
        var m = object(a).map(mailFromObject) ?? mailFromText(a)
        if m.context.isEmpty && m.points.isEmpty && m.action.isEmpty { return "cafu_format_email : aucun contenu exploitable (ni contexte, ni point, ni action)." }
        if m.greeting.isEmpty {
            let body = (m.context + " " + m.action + " " + m.subject).lowercased()
            let en = [" the ", " is ", " are ", " your ", " please ", " before ", " by ", " for ", " and ", " will ", " have "].filter { (" " + body + " ").contains($0) }.count >= 2
            let hello = en ? "Dear" : "Bonjour"
            m.greeting = m.to.isEmpty ? hello + "," : hello + " \(m.to),"
        }
        if !m.greeting.hasSuffix(",") && !m.greeting.hasSuffix("!") { m.greeting += "," }
        if m.politeness.isEmpty && m.kind == "email" { m.politeness = m.greeting.lowercased().hasPrefix("dear") ? "I hope you're well." : "J'espère que vous allez bien." }
        if m.closing.isEmpty { m.closing = "Best," }
        if m.signature.isEmpty { m.signature = Settings().get("name", "Ahadi") }
        if m.context.isEmpty { m.missing.append("phrase de contexte") }
        if m.points.isEmpty { m.missing.append("points clés") }
        if m.action.isEmpty { m.missing.append("action demandée") }
        if m.kind == "email" && !m.action.isEmpty && !DraftLint.hasOptOut(m.action) { m.missing.append("opt-out explicite dans le point d'action (l'envoi sera refusé par la coche tant qu'il manque)") }
        if m.kind == "email" && m.subject.isEmpty { m.missing.append("objet") }
        // P-DRAFT-5 — MODE BROUILLON : le texte canonique entre dans la file de validation de Nova
        // (même magasin que Tools.drafts : brouillons.json) avec sa coche calculée. C'est CE texte
        // qui sera montré sur la carte Messages et, après ENVOYER d'Ahadi, envoyé par le canal réel.
        if let o = object(a), (o["brouillon"] as? Bool) == true {
            let text = textOfMail(m)
            var d: [String: Any] = ["id": "d\(Int(Date().timeIntervalSince1970 * 1000))",
                                     "channel": m.kind == "teams" ? "teams" : "mail",
                                     "to": m.to, "target": m.kind == "teams" ? m.to : "",
                                     "subject": m.kind == "teams" ? "" : m.subject,
                                     "body": text, "ts": ISO8601DateFormatter().string(from: Date()), "status": "à valider"]
            DraftLint.refresh(&d)
            let store = JSONFile("brouillons.json")
            var l = store.read(default: [[String: Any]]())
            l.append(d); store.write(l)
            let fails = DraftLint.hardFailures(d)
            var out = "Brouillon enregistré dans la file de validation de Nova (canal \(m.kind == "teams" ? "Teams" : "mail")). RIEN n'a été envoyé : Ahadi le relit sur la carte Messages et confirme lui-même par ENVOYER.\n"
            out += "Coche gabarit : " + (fails.isEmpty ? "tout est vert." : "à corriger avant envoi — " + fails.map { $0.label }.joined(separator: " · ") + ".") + "\n"
            if !m.missing.isEmpty { out += "Éléments absents du contenu fourni (non inventés) : \(m.missing.joined(separator: ", ")).\n" }
            out += "\n--- Brouillon ---\n" + text
            return out
        }
        let html = renderMail(m)
        guard let path = save(html, prefix: "cafu-" + m.kind) else { return "cafu_format_email : écriture du fichier impossible (dossier de données de Nova non inscriptible)." }
        var out = "\(m.kind == "teams" ? "Message Teams" : "Email") rédigé aux normes CAFU (salutation, contexte, points clés en liste, action demandée en gras, clôture). RIEN n'a été envoyé : l'utilisateur relit puis envoie lui-même, après son GO.\nFichier HTML : \(path)\n"
        if !m.missing.isEmpty { out += "Éléments absents du contenu fourni (non inventés, à compléter) : \(m.missing.joined(separator: ", ")).\n" }
        out += "Pour mettre cette version HTML dans TON presse-papiers, lance toi-même dans Terminal :\n\(clipboardCommand(path))\n(Le presse-papiers n'est pas chargé tant que tu ne l'as pas lancée et confirmé.)\n\n--- Aperçu texte ---\n" + String(textOfMail(m).prefix(2500))
        return out
    }
}
