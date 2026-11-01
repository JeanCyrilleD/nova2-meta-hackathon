import Foundation

// 27/10 (Ahadi : plan de déblocage validé) — MICROSOFT GRAPH EN LECTURE SEULE.
// Objectif : lire Outlook (et demain Teams) par l'API officielle de Microsoft au lieu de
// photographier l'écran (volets web, « page-clic », statuts de présence). Périmètre strict :
//   • flux OAuth « device code » : Ahadi se connecte lui-même chez Microsoft, aucun mot de
//     passe ne transite par Nova ;
//   • jetons au Trousseau (service « nova-graph »), jamais loggés, jamais renvoyés ;
//   • scopes Mail.Read + offline_access uniquement ; les GET Graph ne marquent rien comme lu ;
//   • aucun envoi, aucune écriture — ce module ne sait que lire.
// Prérequis côté Ahadi (une fois) : enregistrer une application dans Azure
// (type « application mobile et de bureau », URI de redirection device code) et coller son
// identifiant client dans le réglage « graph_client_id ». Sans lui, /api/graph/status le dit.

public enum GraphMS {
    static let keyService: String = "nova-graph"
    static let scope: String = "Mail.Read offline_access"
    nonisolated(unsafe) static var pendingDevice: [String: Any]? = nil
    static let lock: NSLock = NSLock()

    static func refreshToken() -> String? {
        return KeychainStore().value(KeyRef(service: keyService, accounts: ["$USER"]))
    }

    static func formPost(_ urlS: String, _ fields: [String: String], timeout: TimeInterval = 30) -> (Int, [String: Any]) {
        guard let url = URL(string: urlS) else { return (0, [:]) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body: String = fields.map { (k: String, v: String) -> String in
            let ek: String = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
            let ev: String = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            return ek + "=" + ev
        }.joined(separator: "&")
        req.httpBody = body.data(using: .utf8)
        let (status, data) = syncPost(req, timeout: timeout)
        let obj: [String: Any] = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, obj)
    }

    static func accessToken(clientId: String) -> String? {
        guard let rt: String = refreshToken(), !rt.isEmpty else { return nil }
        let (st, obj) = formPost("https://login.microsoftonline.com/common/oauth2/v2.0/token",
            ["client_id": clientId, "grant_type": "refresh_token", "refresh_token": rt, "scope": scope])
        guard st >= 200 && st < 300, let at: String = obj["access_token"] as? String, !at.isEmpty else { return nil }
        if let nrt: String = obj["refresh_token"] as? String, !nrt.isEmpty {
            _ = KeychainStore.save(service: keyService, value: nrt)
        }
        return at
    }

    static func getJSON(_ urlS: String, token: String) -> (Int, [String: Any]) {
        guard let url = URL(string: urlS) else { return (0, [:]) }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (status, data) = syncPost(req, timeout: 30)
        let obj: [String: Any] = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, obj)
    }
}

extension NovaApp {
    func graphRoutes() {
        let s = server
        s.on("GET", "/api/graph/status") { [self] _, res in
            let cid: String = settings.get("graph_client_id", "")
            res.json(["connecte": GraphMS.refreshToken() != nil, "client_id_present": !cid.isEmpty,
                      "scopes": GraphMS.scope,
                      "etape_suivante": cid.isEmpty ? "Enregistre une application Azure (mobile/bureau) et colle son identifiant client dans le réglage graph_client_id." : (GraphMS.refreshToken() == nil ? "Lance POST /api/graph/connect puis saisis le code chez Microsoft." : "Connecté — GET /api/graph/mail lit Outlook sans rien marquer.")])
        }
        s.on("POST", "/api/graph/connect") { [self] _, res in
            let cid: String = settings.get("graph_client_id", "")
            guard !cid.isEmpty else { res.json(["error": "graph_client_id absent : enregistre d'abord l'application Azure."], status: 400); return }
            let (st, obj) = GraphMS.formPost("https://login.microsoftonline.com/common/oauth2/v2.0/devicecode",
                ["client_id": cid, "scope": GraphMS.scope])
            guard st >= 200 && st < 300, let code: String = obj["user_code"] as? String,
                  let uri: String = obj["verification_uri"] as? String else {
                res.json(["error": "devicecode refusé (" + String(st) + ") : " + ((obj["error_description"] as? String) ?? "réponse Microsoft illisible")], status: 502); return
            }
            GraphMS.lock.lock(); GraphMS.pendingDevice = obj; GraphMS.lock.unlock()
            res.json(["user_code": code, "verification_uri": uri,
                      "message": "Ouvre " + uri + " et saisis le code " + code + " avec ton compte Microsoft — Nova ne voit jamais ton mot de passe. Puis POST /api/graph/poll."])
        }
        s.on("POST", "/api/graph/poll") { [self] _, res in
            let cid: String = settings.get("graph_client_id", "")
            GraphMS.lock.lock(); let pend: [String: Any]? = GraphMS.pendingDevice; GraphMS.lock.unlock()
            guard let dc: String = pend?["device_code"] as? String else { res.json(["error": "aucune connexion en cours : POST /api/graph/connect d'abord"], status: 400); return }
            let (st, obj) = GraphMS.formPost("https://login.microsoftonline.com/common/oauth2/v2.0/token",
                ["client_id": cid, "grant_type": "urn:ietf:params:oauth:grant-type:device_code", "device_code": dc])
            if let err: String = obj["error"] as? String, err == "authorization_pending" {
                res.json(["status": "en_attente", "message": "Code pas encore validé chez Microsoft — réessaie dans quelques secondes."]); return
            }
            guard st >= 200 && st < 300, let rt: String = obj["refresh_token"] as? String, !rt.isEmpty else {
                res.json(["error": "échange refusé (" + String(st) + ") : " + ((obj["error_description"] as? String) ?? ((obj["error"] as? String) ?? "illisible"))], status: 502); return
            }
            let okSave: Bool = KeychainStore.save(service: GraphMS.keyService, value: rt)
            GraphMS.lock.lock(); GraphMS.pendingDevice = nil; GraphMS.lock.unlock()
            res.json(["status": okSave ? "connecte" : "jeton_non_stocke", "message": okSave ? "Jeton de lecture au Trousseau. GET /api/graph/mail pour vérifier." : "Jeton reçu mais écriture Trousseau refusée."])
        }
        // Lecture Outlook par l'API officielle : en-têtes + aperçu, aucun marquage (GET Graph = lecture pure).
        s.on("GET", "/api/graph/mail") { [self] req, res in
            let cid: String = settings.get("graph_client_id", "")
            guard let at: String = GraphMS.accessToken(clientId: cid) else {
                res.json(["error": "non connecté : /api/graph/connect puis /api/graph/poll"], status: 401); return
            }
            let top: Int = min(50, max(1, Int(req.query["top"] ?? "15") ?? 15))
            let urlS: String = "https://graph.microsoft.com/v1.0/me/messages?$top=" + String(top)
                + "&$orderby=receivedDateTime%20desc&$select=subject,from,receivedDateTime,bodyPreview,isRead"
            let (st, obj) = GraphMS.getJSON(urlS, token: at)
            guard st >= 200 && st < 300 else {
                res.json(["error": "Graph mail refusé (" + String(st) + ")"], status: 502); return
            }
            let vals: [[String: Any]] = (obj["value"] as? [[String: Any]]) ?? []
            let items: [[String: Any]] = vals.map { (m: [String: Any]) -> [String: Any] in
                let from: [String: Any] = (m["from"] as? [String: Any]) ?? [:]
                let addr: [String: Any] = (from["emailAddress"] as? [String: Any]) ?? [:]
                return ["objet": ((m["subject"] as? String) ?? ""), "de": ((addr["name"] as? String) ?? ((addr["address"] as? String) ?? "")),
                        "recu": ((m["receivedDateTime"] as? String) ?? ""), "apercu": String(((m["bodyPreview"] as? String) ?? "").prefix(280)),
                        "lu": ((m["isRead"] as? Bool) ?? false)]
            }
            res.json(["messages": items, "nombre": items.count, "source": "Microsoft Graph (lecture seule, rien marqué)"])
        }
    }
}
