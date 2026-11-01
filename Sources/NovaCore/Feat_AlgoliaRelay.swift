import Foundation
import NovaFoundation

// 29/10 (Ahadi : « branche Algolia aussi en relais auto de [tiers] ») — RELAIS DE LA MÉMOIRE SÉMANTIQUE.
// Chaîne : [tiers] → Algolia → copie locale. Algolia ne sert que si ses clés sont au Trousseau :
//   nova-algolia-app (Application ID), nova-algolia-search (clé de RECHERCHE), nova-algolia-admin (clé d'écriture,
//   pour verser une fois la copie de la mémoire). Index « nova-memoire ». Règle crédits (23/10) : disjoncteur Credits
//   « algolia », compteur, journal ; tout échec rend la main au relais suivant, rien ne bloque Nova.
// Contenu versé : la copie locale de l'index [tiers] (pinecone_export.json), à la demande explicite d'Ahadi (29/10).
public enum AlgoliaRelay {
    static let adminKey: KeyRef = KeyRef(service: "nova-algolia-admin", accounts: ["$USER"], envVars: ["ALGOLIA_ADMIN_KEY"])
    static let index: String = "nova-memoire"
    static let state: JSONFile = JSONFile("algolia_relay.json")

    static func creds(_ ks: KeyStore) -> (app: String, search: String, admin: String) {
        let app: String = ks.value(KnownKeys.algoliaApp) ?? ""
        let search: String = ks.value(KnownKeys.algoliaSearch) ?? ""
        let admin: String = ks.value(adminKey) ?? ""
        return (app.trimmingCharacters(in: .whitespacesAndNewlines), search.trimmingCharacters(in: .whitespacesAndNewlines), admin.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func request(app: String, key: String, path: String, body: [String: Any], timeout: TimeInterval) -> (Int, Data) {
        guard let u = URL(string: "https://" + app + "-dsn.algolia.net" + path) else { return (0, Data()) }
        var rq: URLRequest = URLRequest(url: u)
        rq.httpMethod = "POST"
        rq.setValue(app, forHTTPHeaderField: "X-Algolia-Application-Id")
        rq.setValue(key, forHTTPHeaderField: "X-Algolia-API-Key")
        rq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        rq.httpBody = jsonData(body)
        return syncGet(rq, timeout: timeout)
    }

    /// Recherche (relais de [tiers]). nil = Algolia indisponible (non configuré, index vide, disjoncteur, échec).
    public static func search(_ q: String, k: Int = 5) -> [[String: Any]]? {
        if Credits.isOpen("algolia") { return nil }
        let c = creds(KeychainStore())
        let skey: String = c.search.isEmpty ? c.admin : c.search   // 29/10 : la clé d'écriture suffit si la clé de recherche n'est pas fournie
        if c.app.isEmpty || skey.isEmpty { return nil }
        if c.search.isEmpty && searchDeniedForAdmin() { return nil }   // 31/10 (Algolia biblio) : clé d'écriture sans droit search → on n'insiste pas (6 h)
        let st0: [String: Any] = state.read(default: [String: Any]())
        if ((st0["versés"] as? Int) ?? 0) == 0 { return nil }
        let body: [String: Any] = ["query": q, "hitsPerPage": k]
        let (st, d): (Int, Data) = request(app: c.app, key: skey, path: "/1/indexes/" + index + "/query", body: body, timeout: 4)
        if st != 200 { if st > 0 { failed(status: st, detail: String(data: d.prefix(300), encoding: .utf8) ?? "", op: "search", adminKey: c.search.isEmpty) }; return nil }   // 31/10 (Algolia biblio) : filtre avant disjoncteur
        Credits.count("algolia", n: 1, units: 1, unit: "requête")
        guard let o = parseJSON(d), let hits = o["hits"] as? [[String: Any]], !hits.isEmpty else { return nil }
        return hits.map { (h: [String: Any]) -> [String: Any] in
            let txt: String = (h["text"] as? String) ?? ""
            let r: [String: Any] = ["id": (h["objectID"] as? String) ?? "", "type": (h["type"] as? String) ?? "",
                                    "title": (h["title"] as? String) ?? "(sans titre)", "snippet": String(txt.prefix(220)),
                                    "score": 0, "ts": (h["ts"] as? Int) ?? 0, "ref": (h["ref"] as? String) ?? ""]
            return r
        }
    }

    // 31/10 (Algolia biblio) : FILTRE DES ÉCHECS avant le disjoncteur Crédits. Le détail (expurgé, 240 car., jamais de clé) est gardé
    // dans algolia_relay.json → releves/diag/algolia_disjoncteur.json. Seuls 401/402/403/429 ouvrent le disjoncteur : un 400 « record too
    // big … extended quota » (le mot « quota » l'ouvrait à tort) et un 404 (index absent) ne coupent plus Algolia. Un 403 sur une RECHERCHE
    // faite avec la clé d'écriture (pas de clé de recherche) n'ouvre pas non plus le disjoncteur — l'écriture marche peut-être : on note
    // « recherche_refusee_cle_ecriture » et la recherche se tait 6 h (ou jusqu'à dormant/ALGOLIA_REARM).
    static func failed(status: Int, detail: String, op: String, adminKey: Bool) {
        var st: [String: Any] = state.read(default: [String: Any]())
        st["derniere_erreur_http"] = status
        st["derniere_erreur_detail"] = String(SecretsGuard.redact(String(detail.prefix(240))))
        st["derniere_erreur_op"] = op
        st["derniere_erreur_ts"] = nowISO()
        if op == "search" && adminKey && status == 403 {
            st["recherche_refusee_cle_ecriture"] = nowISO()
            state.write(st)
            return
        }
        state.write(st)
        guard [401, 402, 403, 429].contains(status) else { return }
        Credits.providerFailed("algolia", status: status, detail: detail)
    }
    static func searchDeniedForAdmin() -> Bool {
        let st: [String: Any] = state.read(default: [String: Any]())
        guard let ts = st["recherche_refusee_cle_ecriture"] as? String, let d = ISO8601DateFormatter().date(from: ts) else { return false }
        return Date().timeIntervalSince(d) < 6 * 3600
    }
    static func clearSearchDenied() {
        var st: [String: Any] = state.read(default: [String: Any]())
        if st.removeValue(forKey: "recherche_refusee_cle_ecriture") != nil { state.write(st) }
    }

    /// Versement unique (puis à chaque nouvel export) de la copie locale de la mémoire vers l'index Algolia.
    /// État lisible (diag) : présence des clés (oui/non), versement, disjoncteur — jamais une valeur de clé.
    static func writeDiag(_ extra: [String: Any] = [:]) {
        let c = creds(KeychainStore())
        var o: [String: Any] = state.read(default: [String: Any]())
        o["generated"] = nowISO(); o["app_id_present"] = !c.app.isEmpty; o["cle_ecriture_presente"] = !c.admin.isEmpty
        o["cle_recherche_presente"] = !c.search.isEmpty; o["disjoncteur_ouvert"] = Credits.isOpen("algolia")
        for (k, v) in extra { o[k] = v }
        try? jsonData(o).write(to: URL(fileURLWithPath: NSHomeDirectory() + "/spark-local/Nova2/releves/diag/algolia_etat.json"))
    }

    static func syncIfNeeded() {
        let c = creds(KeychainStore())
        defer { writeDiag() }
        if c.app.isEmpty || c.admin.isEmpty || Credits.isOpen("algolia") { return }
        let ex: [String: Any] = Credits.exportFile.read(default: [String: Any]())
        let recs: [[String: Any]] = (ex["records"] as? [[String: Any]]) ?? []
        if recs.isEmpty { return }
        var st: [String: Any] = state.read(default: [String: Any]())
        if ((st["versés"] as? Int) ?? 0) == recs.count { return }
        var sent: Int = 0
        var i: Int = 0
        while i < recs.count {
            let chunk: [[String: Any]] = Array(recs[i..<min(i + 100, recs.count)])
            let reqs: [[String: Any]] = chunk.map { (r: [String: Any]) -> [String: Any] in
                var b: [String: Any] = ["objectID": (r["id"] as? String) ?? UUID().uuidString, "text": (r["text"] as? String) ?? ""]
                if let t = r["title"] as? String { b["title"] = t }
                if let t = r["type"] as? String { b["type"] = t }
                if let t = r["ref"] as? String { b["ref"] = t }
                let one: [String: Any] = ["action": "updateObject", "body": b]
                return one
            }
            let (code, d): (Int, Data) = request(app: c.app, key: c.admin, path: "/1/indexes/" + index + "/batch", body: ["requests": reqs], timeout: 20)
            if code != 200 {
                st["derniere_erreur"] = "HTTP " + String(code) + " : " + String(SecretsGuard.redact(String(decoding: d.prefix(200), as: UTF8.self)))
                failed(status: code, detail: String(data: d.prefix(300), encoding: .utf8) ?? "", op: "write", adminKey: true)   // 31/10 (Algolia biblio)
                break
            }
            sent += chunk.count
            i += 100
        }
        for (k, v) in state.read(default: [String: Any]()) where k.hasPrefix("derniere_erreur_") || k == "recherche_refusee_cle_ecriture" { st[k] = v }   // 31/10 (Algolia biblio) : garde le détail posé par failed()
        st["versés"] = sent
        st["total"] = recs.count
        st["at"] = nowISO()
        state.write(st)
        var rec: [String: Any] = [:]
        rec["tool"] = "algolia"; rec["actor"] = "Ahadi"; rec["ok"] = sent == recs.count; rec["effect"] = "écrit"
        rec["why"] = "relais mémoire : copie de la mémoire versée dans l'index Algolia nova-memoire (demande d'Ahadi 29/10)"
        rec["result"] = String(sent) + "/" + String(recs.count)
        _ = BlackBox.record(rec)
    }
}
