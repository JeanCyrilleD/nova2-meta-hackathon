import Foundation

/// Téléphone = télécommande de Nova (lecture + brouillons, JAMAIS d'envoi, de paiement ni de suppression).
/// - Page mobile servie par le pont (Bridge.port, adresse Tailscale uniquement) : GET /api/m (page statique sans aucune donnée : seul chemin ouvert).
/// - Toutes les données passent par des routes /api/phone/* qui exigent le jeton de l'appareil appairé (Bridge.device(for:)).
/// - « Traité » ne supprime rien : l'identifiant du brouillon est simplement noté dans phone_drafts_done.json.
enum PhoneRemote {
    static let done = JSONFile("phone_drafts_done.json")
    static let requests = Journal("phone_requests.jsonl")

    static func doneIds() -> [String] { done.read(default: [String]()) }

    static func clip(_ v: Any?, _ n: Int) -> String {
        let s: String = (v as? String) ?? ""
        return String(s.prefix(n))
    }
}

extension NovaApp {
    /// Routes côté Mac (serveur principal, local) : demandes reçues du téléphone.
    func phoneRoutes() {
        let s = server
        s.on("GET", "/api/phone/requests") { _, res in
            let items: [[String: Any]] = Array(PhoneRemote.requests.tail(30).reversed())
            res.json(["items": items])
        }
    }

    /// Routes du pont (appelée par bridgeStart avant le démarrage du second serveur).
    func phoneBridgeRoutes(_ b: HTTPServer) {
        b.openPaths.insert("/api/m")   // page vide de données : l'appairage se fait ensuite par /api/pair (code à usage unique)
        let web: String? = server.staticDir
        let tl = tools
        let dt = dots
        let bs = bus

        b.on("GET", "/api/m") { _, res in
            guard let dir = web, let d = FileManager.default.contents(atPath: dir + "/phone/m.html") else {
                res.json(["error": "page mobile introuvable"], status: 404); return
            }
            let extra: [String: String] = ["Cache-Control": "no-store", "Content-Security-Policy": "object-src 'none'; base-uri 'self'; frame-ancestors 'none'"]
            res.data(d, type: "text/html; charset=utf-8", extra: extra)
        }

        // File de validation : brouillons (lecture seule + « Traité », jamais d'envoi).
        b.on("GET", "/api/phone/drafts") { req, res in
            guard Bridge.device(for: req) != nil else { res.json(["error": "?"], status: 401); return }
            let doneSet: Set<String> = Set(PhoneRemote.doneIds())
            let all: [[String: Any]] = tl.drafts.read(default: [[String: Any]]())
            var out: [[String: Any]] = []
            for dr in all.reversed() {
                let id: String = (dr["id"] as? String) ?? ""
                if id.isEmpty || doneSet.contains(id) { continue }
                let item: [String: Any] = ["id": id, "to": PhoneRemote.clip(dr["to"], 200), "subject": PhoneRemote.clip(dr["subject"], 300),
                                           "body": PhoneRemote.clip(dr["body"], 8000), "ts": PhoneRemote.clip(dr["ts"], 40), "status": PhoneRemote.clip(dr["status"], 40)]
                out.append(item)
                if out.count >= 40 { break }
            }
            res.json(["items": out])
        }
        b.on("POST", "/api/phone/drafts/done") { req, res in
            guard Bridge.device(for: req) != nil else { res.json(["error": "?"], status: 401); return }
            let id: String = String(((req.json["id"] as? String) ?? "").prefix(40))
            guard !id.isEmpty else { res.json(["error": "id manquant"], status: 400); return }
            var l: [String] = PhoneRemote.doneIds()
            if !l.contains(id) { l.append(id) }
            PhoneRemote.done.write(Array(l.suffix(500)))
            res.json(["ok": true])
        }
        b.on("POST", "/api/phone/drafts/undo") { req, res in
            guard Bridge.device(for: req) != nil else { res.json(["error": "?"], status: 401); return }
            let id: String = (req.json["id"] as? String) ?? ""
            let l: [String] = PhoneRemote.doneIds().filter { $0 != id }
            PhoneRemote.done.write(l)
            res.json(["ok": true])
        }

        // Fil des Dots : statut des derniers passages (texte tronqué).
        b.on("GET", "/api/phone/dots") { req, res in
            guard Bridge.device(for: req) != nil else { res.json(["error": "?"], status: 401); return }
            var names: [String: String] = [:]
            for d in dt.list() {
                let id: String = (d["id"] as? String) ?? ""
                let nm: String = (d["name"] as? String) ?? id
                let em: String = (d["emoji"] as? String) ?? ""
                names[id] = em.isEmpty ? nm : em + " " + nm
            }
            let runs: [[String: Any]] = Array(dt.history().prefix(25))
            var out: [[String: Any]] = []
            for r in runs {
                let did: String = (r["dot"] as? String) ?? ""
                let item: [String: Any] = ["id": PhoneRemote.clip(r["id"], 20), "dot": did, "name": names[did] ?? did, "ts": PhoneRemote.clip(r["ts"], 40),
                                           "ok": (r["ok"] as? Bool) ?? false, "status": PhoneRemote.clip(r["status"], 40), "result": PhoneRemote.clip(r["result"], 1200)]
                out.append(item)
            }
            res.json(["items": out])
        }

        // LOT L (28/10) — GO à distance : file « En attente » lisible et DÉCIDABLE depuis
        // le téléphone (préparations approuvées/rejetées = même décision que sur le Mac,
        // crée au plus un engagement interne ; jamais d'envoi, jamais de suppression).
        b.on("GET", "/api/phone/attente") { req, res in
            guard Bridge.device(for: req) != nil else { res.json(["error": "?"], status: 401); return }
            let preps: [[String: Any]] = Preparations.all()
                .filter { ($0["statut"] as? String) == "en_attente" }
                .map { (p: [String: Any]) -> [String: Any] in
                    ["id": PhoneRemote.clip(p["id"], 20), "titre": PhoneRemote.clip(p["titre"], 300),
                     "pourquoi": PhoneRemote.clip(p["pourquoi"], 600), "cree": PhoneRemote.clip(p["cree"], 40)]
                }
            let doneSet: Set<String> = Set(PhoneRemote.doneIds())
            let draftsCount: Int = (tl.drafts.read(default: [[String: Any]]()) as [[String: Any]])
                .filter { let id: String = ($0["id"] as? String) ?? ""; return !id.isEmpty && !doneSet.contains(id)
                    && ((($0["status"] as? String) ?? "").lowercased().hasPrefix("à valider") || (($0["status"] as? String) ?? "").lowercased().hasPrefix("a valider")) }.count
            res.json(["preparations": Array(preps.suffix(30).reversed()), "brouillons": draftsCount])
        }
        b.on("POST", "/api/phone/preparations/statut") { req, res in
            guard let dev = Bridge.device(for: req) else { res.json(["error": "?"], status: 401); return }
            let id: String = String(((req.json["id"] as? String) ?? "").prefix(16))
            let statut: String = (req.json["statut"] as? String) ?? ""
            guard !id.isEmpty, ["approuvee", "rejetee"].contains(statut) else { res.json(["error": "id et statut (approuvee|rejetee) requis"], status: 400); return }
            let decided: (prep: [String: Any]?, engagementCree: String) = Preparations.decider(id: id, statut: statut)
            guard decided.prep != nil else { res.json(["error": "préparation introuvable"], status: 404); return }
            _ = BlackBox.record(["tool": "phone_go", "actor": "Ahadi (téléphone)", "effect": "écriture", "ok": true,
                                 "why": "décision à distance sur une préparation : " + statut,
                                 "result": "preparation=" + id + " appareil=" + ((dev["name"] as? String) ?? "Téléphone") + (decided.engagementCree.isEmpty ? "" : " engagement=" + decided.engagementCree)])
            res.json(["ok": true, "statut": statut, "engagement_cree": decided.engagementCree])
        }

        // Mode « demande » : rien ne s'exécute ; la demande s'affiche sur le Mac (évènement + journal) pour validation.
        b.on("POST", "/api/phone/request") { req, res in
            guard let dev = Bridge.device(for: req) else { res.json(["error": "?"], status: 401); return }
            let text: String = String(((req.json["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
            guard !text.isEmpty else { res.json(["error": "texte vide"], status: 400); return }
            let ev: [String: Any] = ["id": UUID().uuidString.prefix(8).lowercased().description, "device": (dev["name"] as? String) ?? "Téléphone", "text": text, "status": "à valider"]
            PhoneRemote.requests.add(ev)
            bs.publish("phone_request", ev)
            res.json(["ok": true, "message": "Demande transmise au Mac : elle attend ta validation là-bas."])
        }
    }
}
