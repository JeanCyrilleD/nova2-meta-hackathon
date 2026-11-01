import Foundation
import NovaFoundation

/// Génération d'images de DESIGN par Muse Image (muse-image-1.0, API Meta Model). Déclencheur : ~/spark-local/Nova2/dormant/IMAGE_GEN.json
///   {"ref": "…", "out": "dormant/design_in/icones", "style": "…texte commun…", "items": [{"name": "messages", "prompt": "…"}]}
/// Règles crédits : plafond 40 images par demande ; disjoncteur après 3 échecs de suite ; aucun repli payant (échec nommé) ;
/// compteur et état par image dans releves/diag/image_gen.json (aucune clé, aucun contenu d'Ahadi). La demande est renommée
/// IMAGE_GEN.done.json avant tout appel (jamais rejouée par erreur).
public enum DesignImageGen {
    nonisolated(unsafe) static var running: Bool = false

    static func tick(root: String) {
        let req: String = root + "/dormant/IMAGE_GEN.json"
        guard !running, FileManager.default.fileExists(atPath: req),
              let d = FileManager.default.contents(atPath: req), let o = parseJSON(d) else { return }
        try? FileManager.default.removeItem(atPath: root + "/dormant/IMAGE_GEN.done.json")
        try? FileManager.default.moveItem(atPath: req, toPath: root + "/dormant/IMAGE_GEN.done.json")
        running = true
        Thread.detachNewThread { DesignImageGen.run(o, root: root); DesignImageGen.running = false }
    }

    /// 01/11 : studio de design servi par Muse Image (POST /v1/images/generations, 0,01 $ par image — dev.meta.ai/docs/pricing-rate-limits).
    /// Même déclencheur, même plafond (40), même disjoncteur (3 échecs), même diagnostic. L'image de référence n'est pas envoyée :
    /// /v1/images/edits existe mais son format n'a pas été vérifié ici (signalé dans le diagnostic).
    static func runMuse(_ o: [String: Any], root: String) {
        var diag: [String: Any] = ["debut": nowISO(), "moteur": "muse-image", "modele": MetaCapabilities.imageModel]
        let diagPath: String = root + "/releves/diag/image_gen.json"
        func save() { try? jsonData(diag).write(to: URL(fileURLWithPath: diagPath)) }
        var key: String = MetaCapabilities.keyChain.resolve(KeychainStore()) ?? ""
        if let d = key.data(using: .utf8), d.first == UInt8(ascii: "{"), let j = parseJSON(d) { key = (j["api_key"] as? String) ?? (j["access_token"] as? String) ?? key }
        guard !key.isEmpty else {
            diag["etat"] = "ÉCHEC : aucune clé Meta Model API (nova-spark / nova-meta)"; save()
            MetaSpecialites.noter(specialite: .image, modele: MetaCapabilities.imageModel, cerveau: "", chaine: [], statut: "echec", source: "image_gen")
            return
        }
        if o["ref"] != nil { diag["note_reference"] = "image de référence non envoyée : /v1/images/edits non câblé (format non vérifié)" }
        let outDir: String = root + "/" + ((o["out"] as? String) ?? "dormant/design_in/icones")
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let style: String = (o["style"] as? String) ?? ""
        let items: [[String: Any]] = Array(((o["items"] as? [[String: Any]]) ?? []).prefix(40))
        var rows: [[String: Any]] = []
        var fails: Int = 0
        let spec = BrainSpec(id: "muse-image", label: "Muse Image (Meta)", kind: .chat, baseURL: MetaCapabilities.apiBase + "/images/generations",
                             model: MetaCapabilities.imageModel, keys: KeyChain([]), tags: [])
        for it in items {
            let name: String = ((it["name"] as? String) ?? "image").replacingOccurrences(of: "/", with: "_")
            let prompt: String = (it["prompt"] as? String) ?? ""
            var row: [String: Any] = ["nom": name]
            if fails >= 3 { row["etat"] = "non lancé (disjoncteur : 3 échecs de suite)"; rows.append(row); continue }
            let text: String = style.isEmpty ? prompt : style.replacingOccurrences(of: "[SUBJECT]", with: prompt)
            let pf: Preflight = LLMSpend.preflight(spec: spec, estIn: TokenEst.of(text), maxOut: 200, lane: .interactive)
            guard let tk = pf.ticket else {
                if case .refused(let why) = pf { row["etat"] = "non lancé (budget) : " + String(why.prefix(200)) }
                rows.append(row); diag["images"] = rows; save(); break
            }
            let t0: Date = Date()
            let (st, obj, raw): (Int, [String: Any], String) = MetaCapabilities.postJSON(path: "/images/generations", payload: MetaCapabilities.imagePayload(prompt: text), key: key, timeout: 120)
            row["http"] = st
            row["ms"] = Int(Date().timeIntervalSince(t0) * 1000)
            var saved: Bool = false
            if st >= 200 && st < 300, let data = obj["data"] as? [[String: Any]], let first = data.first {
                var img: Data? = nil
                if let b64 = first["b64_json"] as? String { img = Data(base64Encoded: b64) }
                else if let u = first["url"] as? String, let url = URL(string: u) { let (gs, gd): (Int, Data) = syncGet(URLRequest(url: url), timeout: 60); if gs == 200 { img = gd } }
                if let im = img, !im.isEmpty {
                    let ext: String = im.starts(with: [0xFF, 0xD8]) ? "jpg" : "png"
                    let path: String = outDir + "/" + name + "." + ext
                    if (try? im.write(to: URL(fileURLWithPath: path))) != nil { saved = true; row["fichier"] = name + "." + ext; row["octets"] = im.count }
                }
            }
            LLMSpend.abandon(tk, kind: (st == 401 || st == 403) ? .auth : nil, produced: saved)
            if saved { fails = 0; row["etat"] = "OK" } else {
                fails += 1; row["etat"] = "ÉCHEC"; row["detail"] = String(SecretsGuard.redact(String(raw.prefix(600))))
            }
            MetaSpecialites.noter(specialite: .image, modele: MetaCapabilities.imageModel, cerveau: "", chaine: [], statut: saved ? "ok" : "echec", source: "image_gen")
            rows.append(row); diag["images"] = rows
            diag["ok"] = rows.filter { ($0["etat"] as? String) == "OK" }.count
            save()
        }
        diag["fin"] = nowISO(); diag["etat"] = "terminé"; save()
        let nOK: Int = (diag["ok"] as? Int) ?? 0
        _ = BlackBox.record(["tool": "design_image_gen", "actor": "Nova", "ok": nOK > 0, "effect": "fichiers locaux",
                             "why": "Images de design (Muse Image, Meta)", "result": "\(nOK)/\(items.count) images, modèle \(MetaCapabilities.imageModel)"])
    }

    static func run(_ o: [String: Any], root: String) {
        runMuse(o, root: root)   // version Meta : Muse Image seul
    }
}
