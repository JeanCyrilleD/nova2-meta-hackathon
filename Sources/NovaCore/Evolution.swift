import Foundation

/// ATELIER D'ÉVOLUTION DE L'INTERFACE — accordé par l'utilisateur (« avec noyau de sécurité hors de portée »).
/// L'assistant corrige ou ajuste l'interface de Nova (dossier web/) en direct, par une surcouche, sans recompilation.
/// Garde-fous : (1) seul l'assistant principal, en réponse à un message de l'utilisateur, peut écrire (contrôlé dans Tools.run : jamais un Dot, un mail ou une page web) ;
/// (2) uniquement web/ — le code Swift (noyau, sécurité, clés, permis, Boîte noire) reste hors de portée : il se corrige par propositions validées par l'utilisateur ;
/// (3) les écrans de consentement, de confidentialité, des clés et des connexions sont protégés ; (4) tout changement est sauvegardé, journalisé (Boîte noire)
/// et annulable (code-annuler) ; (5) équilibre des accolades vérifié avant écriture ; (6) la surcouche s'efface d'elle-même si le fichier d'origine est renouvelé.
extension NovaApp {
    static let evoLock = NSLock()
    static let evoExts: Set<String> = ["js", "css", "html", "json"]
    static let evoProtectedWords = ["confirm", "confidential", "connexion", "permis", "constitution", "boite", "vault", "keys", "cle", "secret", "password", "telephone", "reglages"]
    public static let evoWriteVerbs: Set<String> = ["code-patch", "code-nouveau", "ui-css", "code-annuler", "recharger-ui"]

    static var overlayDir: URL { Paths.home.appendingPathComponent("web_overlay") }
    static var evoDir: URL { Paths.home.appendingPathComponent("evolution") }
    static var evoLog: JSONFile { JSONFile("evolution.json") }
    static var overlayIndex: JSONFile { JSONFile("web_overlay_index.json") }

    static func mtime(_ path: String) -> Double { ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0 }

    /// Chemin web/… sûr ; nil + raison sinon.
    static func evoRel(_ raw: String) -> (String?, String) {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let root = projectRootDir()?.path, p.hasPrefix(root + "/") { p = String(p.dropFirst(root.count + 1)) }
        if p.hasPrefix("./") { p = String(p.dropFirst(2)) }
        if p.hasPrefix("/") || p.contains("..") || p.contains("\n") { return (nil, "Chemin invalide.") }
        guard p.hasPrefix("web/") else { return (nil, "Périmètre : uniquement l'interface (web/…). Le code Swift de Nova n'est pas modifiable par l'assistant : utilise « proposer ».") }
        let name = (p as NSString).lastPathComponent.lowercased()
        guard evoExts.contains((name as NSString).pathExtension) else { return (nil, "Extension non permise.") }
        if let w = evoProtectedWords.first(where: { p.lowercased().contains($0) }) { return (nil, "Écran protégé (« \(w) ») : consentement, confidentialité, clés ou connexions — modifiable uniquement par l'utilisateur.") }
        return (p, "")
    }

    /// Surcouche servie à la place du fichier d'origine, tant que celui-ci n'a pas changé depuis le patch.
    public static func overlayData(_ rel: String, bundleDir: String?) -> Data? {
        guard let d = try? Data(contentsOf: overlayDir.appendingPathComponent(rel)) else { return rel == "custom.css" ? Data() : nil }
        let rec = (overlayIndex.read(default: [String: Any]())[rel] as? Double) ?? 0
        if let b = bundleDir, FileManager.default.fileExists(atPath: b + "/" + rel), abs(mtime(b + "/" + rel) - rec) > 0.5 { return nil }
        return d
    }

    static func evoAdd(_ e: [String: Any]) -> String {
        evoLock.lock(); defer { evoLock.unlock() }
        var l = evoLog.read(default: [[String: Any]]()); var x = e
        let id = String(UUID().uuidString.prefix(6)).lowercased(); x["id"] = id; x["ts"] = nowISO(); l.append(x); evoLog.write(Array(l.suffix(300)))
        return id
    }

    func evoCurrent(_ rel: String) -> String? {
        let r = String(rel.dropFirst(4))
        if let d = NovaApp.overlayData(r, bundleDir: server.staticDir), let s = String(data: d, encoding: .utf8), !(r == "custom.css" && s.isEmpty) { return s }
        if let b = server.staticDir, let s = try? String(contentsOfFile: b + "/" + r, encoding: .utf8) { return s }
        if let root = NovaApp.projectRootDir(), let s = try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) { return s }
        return nil
    }

    func evoSave(_ target: String, _ url: URL, _ content: String, _ snapDir: URL) -> [String: Any]? {
        let fm = FileManager.default; let existed = fm.fileExists(atPath: url.path); var snap = ""
        if existed { try? fm.createDirectory(at: snapDir, withIntermediateDirectories: true); let s = snapDir.appendingPathComponent(target + "_" + url.lastPathComponent); try? fm.removeItem(at: s); if (try? fm.copyItem(at: url, to: s)) != nil { snap = s.path } }
        do { try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try content.write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        return ["target": target, "path": url.path, "snap": snap, "existed": existed]
    }

    func evoApply(rel: String, why: String, content: String, kind: String) -> String {
        let r = String(rel.dropFirst(4)); let snapDir = NovaApp.evoDir.appendingPathComponent(String(UUID().uuidString.prefix(8)).lowercased())
        let oldIdx = NovaApp.overlayIndex.read(default: [String: Any]())
        guard var f = evoSave("overlay", NovaApp.overlayDir.appendingPathComponent(r), content, snapDir) else { return "Écriture impossible." }
        f["idx"] = oldIdx[r] ?? NSNull(); var files = [f]
        var idx = oldIdx; idx[r] = server.staticDir.map { NovaApp.mtime($0 + "/" + r) } ?? 0; NovaApp.overlayIndex.write(idx)
        var note = "actif au rechargement (sans recompilation)"
        if r != "custom.css", let root = NovaApp.projectRootDir(), let g = evoSave("project", root.appendingPathComponent(rel), content, snapDir) { files.append(g); note += " ; source du projet mise à jour" }
        let id = NovaApp.evoAdd(["kind": kind, "path": rel, "why": String(why.prefix(300)), "status": "actif", "files": files])
        _ = BlackBox.record(["tool": "app", "actor": "Assistant", "why": "\(kind) \(rel) — \(why.prefix(120))", "ok": true, "effect": "écrit"])
        return "Changement #\(id) sur \(rel) : \(note). Annulable : code-annuler \(id). Utilise recharger-ui pour le voir."
    }

    func evolution(_ verb: String, _ raw: String) -> String? {
        let lines = raw.components(separatedBy: "\n"); let hp = (lines.first ?? "").split(separator: " ", maxSplits: 1).map(String.init); let rest = hp.count > 1 ? hp[1] : ""
        func split(_ s: String) -> (String, String) { let a = s.components(separatedBy: " | "); return (a[0].trimmingCharacters(in: .whitespaces), a.dropFirst().joined(separator: " | ")) }
        switch verb {
        case "code-patch":
            let (path, why) = split(rest); let (rel, err) = NovaApp.evoRel(path); guard let r = rel else { return err }
            guard let cur = evoCurrent(r) else { return "Fichier introuvable : \(r)" }
            var blocks: [(String, String)] = []; var mode = 0; var o: [String] = [], n: [String] = []
            for l in lines.dropFirst() {
                let t = l.trimmingCharacters(in: .whitespaces)
                if t == "<<<<" { mode = 1; o = []; n = []; continue }
                if t == "====", mode == 1 { mode = 2; continue }
                if t == ">>>>", mode == 2 { blocks.append((o.joined(separator: "\n"), n.joined(separator: "\n"))); mode = 0; continue }
                if mode == 1 { o.append(l) } else if mode == 2 { n.append(l) }
            }
            guard !blocks.isEmpty else { return "Format : « code-patch web/chemin | raison » puis blocs :\n<<<<\nancien texte exact\n====\nnouveau texte\n>>>>" }
            var s = cur
            for (i, b) in blocks.enumerated() {
                let c = s.components(separatedBy: b.0).count - 1
                guard !b.0.isEmpty, c == 1 else { return "Bloc \(i + 1) : l'ancien texte doit apparaître exactement une fois (trouvé \(c)). Rien n'a été modifié." }
                s = s.replacingOccurrences(of: b.0, with: b.1)
            }
            if NovaApp.balancedCode(cur), !NovaApp.balancedCode(s) { return "Refusé : le résultat déséquilibre les accolades/parenthèses de \(r). Rien n'a été modifié." }
            return evoApply(rel: r, why: why, content: s, kind: "web")
        case "code-nouveau":
            let (path, why) = split(rest); let (rel, err) = NovaApp.evoRel(path); guard let r = rel else { return err }
            if evoCurrent(r) != nil { return "\(r) existe déjà : utilise code-patch." }
            let body = lines.dropFirst().joined(separator: "\n"); guard body.count > 10 else { return "code-nouveau web/chemin | raison, puis le contenu du fichier." }
            if !NovaApp.balancedCode(body) { return "Refusé : accolades/parenthèses déséquilibrées." }
            return evoApply(rel: r, why: why.isEmpty ? "nouveau fichier" : why, content: body, kind: "web")
        case "ui-css":
            let css = lines.count > 1 ? lines.dropFirst().joined(separator: "\n") : rest; let cur = evoCurrent("web/custom.css") ?? ""
            if css.trimmingCharacters(in: .whitespaces).lowercased() == "effacer" { return evoApply(rel: "web/custom.css", why: "effacement du CSS personnalisé", content: "", kind: "css") }
            guard !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "ui-css <règles CSS> | ui-css effacer. CSS actuel (\(cur.count) car.) :\n" + String(cur.prefix(1500)) }
            if !NovaApp.balancedCode(css) { return "CSS refusé : accolades déséquilibrées." }
            return evoApply(rel: "web/custom.css", why: "ajustement d'interface", content: cur + (cur.isEmpty ? "" : "\n") + "/* " + nowISO() + " */\n" + css, kind: "css")
        case "recharger-ui":
            bus.publish("reload", ["why": "assistant"]); return "Interface rechargée."
        case "evolution":
            let l = NovaApp.evoLog.read(default: [[String: Any]]()).filter { ["web", "css"].contains(($0["kind"] as? String) ?? "") }.suffix(15)
            return l.isEmpty ? "Aucun changement d'interface enregistré." : l.map { "• #\($0["id"] ?? "") · \($0["ts"] ?? "") · \($0["kind"] ?? "") · \($0["path"] ?? "") · \($0["status"] ?? "") · \(String("\($0["why"] ?? "")".prefix(80)))" }.joined(separator: "\n")
        case "code-annuler":
            let id = rest.trimmingCharacters(in: .whitespaces); NovaApp.evoLock.lock(); defer { NovaApp.evoLock.unlock() }
            var l = NovaApp.evoLog.read(default: [[String: Any]]())
            guard let i = l.firstIndex(where: { ($0["id"] as? String) == id && ["web", "css"].contains(($0["kind"] as? String) ?? "") }) else { return "code-annuler <id> (voir : evolution)" }
            let e = l[i]; if ((e["status"] as? String) ?? "").hasPrefix("annulé") { return "Déjà annulé." }
            let path = e["path"] as? String ?? ""
            let later = l[(i + 1)...].filter { ($0["path"] as? String) == path && !((($0["status"] as? String) ?? "").hasPrefix("annulé")) }.compactMap { $0["id"] as? String }
            if !later.isEmpty { return "Des changements plus récents touchent \(path) : annule-les d'abord (\(later.joined(separator: ", ")))." }
            let fm = FileManager.default; let r = String(path.dropFirst(4))
            for f in (e["files"] as? [[String: Any]]) ?? [] {
                guard let p = f["path"] as? String else { continue }
                if (f["existed"] as? Bool) == true, let sn = f["snap"] as? String, !sn.isEmpty { try? fm.removeItem(atPath: p); try? fm.copyItem(atPath: sn, toPath: p) } else { try? fm.removeItem(atPath: p) }
                if (f["target"] as? String) == "overlay" { var idx = NovaApp.overlayIndex.read(default: [String: Any]()); if let old = f["idx"] as? Double { idx[r] = old } else { idx.removeValue(forKey: r) }; NovaApp.overlayIndex.write(idx) }
            }
            l[i]["status"] = "annulé " + nowISO(); NovaApp.evoLog.write(l)
            _ = BlackBox.record(["tool": "app", "actor": "Assistant", "why": "code-annuler \(id) \(path)", "ok": true, "effect": "écrit"])
            return "Changement #\(id) annulé (\(path) restauré). Utilise recharger-ui."
        default: return nil
        }
    }
}
