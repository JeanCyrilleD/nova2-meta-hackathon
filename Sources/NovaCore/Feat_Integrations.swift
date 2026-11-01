import Foundation
import NovaFoundation

// 29/10 (Ahadi : « make Nova the best integrated app ever ») — VEILLE DES INTÉGRATIONS.
// Une intégration qui casse en silence est le pire défaut d'une app intégrée : la session Teams avait expiré
// depuis des jours sans que personne le dise. Nova surveille désormais chaque branchement (boîtes web, voix,
// cerveaux) et le DIT dans tes directs, une fois, avec le geste exact pour réparer — puis confirme le retour.
public enum IntegrationWatch {
    static let file: JSONFile = JSONFile("integrations.json")
    static let lock: NSLock = NSLock()

    static let labels: [String: String] = [
        "ol": "Outlook", "gm": "Gmail", "tm": "Teams", "wa": "WhatsApp", "zm": "Zoho Mail",
        "spark": "Cerveau Spark (Meta)",
    ]

    static func fix(_ src: String, _ code: String) -> String {
        switch src {
        case "ol", "gm", "tm", "wa", "zm":
            let n: String = labels[src] ?? src
            if src == "wa" { return "Ouvre Nova › Messages › WhatsApp et rescanne le code QR depuis ton téléphone (Réglages › Appareils connectés)." }
            return "Ouvre Nova › Messages › " + n + ", clique « Sign in » / « Se connecter » et connecte-toi une fois, puis « Rendre la main à Nova »."
        case "spark":
            return "Vérifie le crédit ou la clé Meta Model API (Réglages › Connexions) ; en attendant Nova bascule sur les autres cerveaux."
        default:
            return ""
        }
    }

    /// Un signal d'état. ok = le branchement marche ; sinon code + message. Publie un direct à la transition.
    public static func signal(_ src: String, ok: Bool, code: String = "", msg: String = "") {
        lock.lock()
        var all: [String: Any] = file.read(default: [String: Any]())
        var cur: [String: Any] = (all[src] as? [String: Any]) ?? [:]
        let wasBad: Bool = (cur["ok"] as? Bool) == false
        let lastAlert: String = (cur["alerted_at"] as? String) ?? ""
        cur["ok"] = ok
        cur["checked_at"] = nowISO()
        var publish: (title: String, text: String)? = nil
        let name: String = labels[src] ?? src
        if ok {
            if wasBad && !lastAlert.isEmpty {
                publish = ("✅ " + name + " rebranché", "✅ **" + name + "** est de nouveau branché — Nova reprend la lecture et les directs normalement.")
            }
            cur["code"] = ""; cur["msg"] = ""; cur["since"] = ""; cur["alerted_at"] = ""
        } else {
            if !wasBad { cur["since"] = nowISO() }
            cur["code"] = code; cur["msg"] = String(msg.prefix(240))
            // 29/10 : anti-clignotement — une page de connexion passagère (rechargement, bandeau) ne déclenche rien ;
            // l'alerte ne part que si la panne dure 15 min (signal confirmé), puis au plus toutes les 12 h.
            let sinceS: String = (cur["since"] as? String) ?? ""
            let lasting: Bool = ISO8601DateFormatter().date(from: sinceS).map { (d: Date) -> Bool in Date().timeIntervalSince(d) >= 15 * 60 } ?? false
            let stale: Bool = lastAlert.isEmpty || (ISO8601DateFormatter().date(from: lastAlert).map { Date().timeIntervalSince($0) > 12 * 3600 } ?? true)
            if stale && lasting {   // 29/10 : règle des 15 min pour TOUTES les intégrations (les redémarrages de Nova faisaient « débranché / rebranché » en rafale)
                cur["alerted_at"] = nowISO()
                var t: String = "⚠️ **" + name + " est débranché** — " + (msg.isEmpty ? "il ne répond plus." : msg)
                let f: String = fix(src, code)
                if !f.isEmpty { t += "\nÀ faire : " + f }
                if ["ol", "gm", "tm", "zm"].contains(src) { t += "\nEn attendant, ses nouveaux messages n'arrivent pas dans tes directs." }
                publish = ("⚠️ " + name + " débranché", t)
            }
        }
        all[src] = cur
        file.write(all)
        lock.unlock()
        if let p = publish {
            ProactiveFeed.append(kind: "muse", box: "integrations", title: p.title, text: p.text, urgent: !ok, extra: ["rituel": "integrations", "source": src])
        }
    }

    public static func state() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return file.read(default: [String: Any]())
    }

    /// Contrôles moteur (toutes les 30 min) : cerveaux Meta principaux.
    static func engineChecks(router: Router) {
        signal("spark", ok: router.usable("spark-1.3"), code: "cerveau", msg: "Spark 1.3 n'est pas utilisable (clé absente, crédit épuisé ou en panne).")
    }

    nonisolated(unsafe) static var started: Bool = false
    static func start(router: Router) {
        lock.lock(); if started { lock.unlock(); return }; started = true; lock.unlock()
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 180)
            while true {
                IntegrationWatch.engineChecks(router: router)
                Thread.sleep(forTimeInterval: 1800)
            }
        }
    }
}

extension NovaApp {
    func integrationsRoutes() {
        let s = server
        IntegrationWatch.start(router: router)
        ABBench.tools = tools
        ABBench.start(router: router)   // 29/10 : banc des cerveaux Meta (Feat_ABTest.swift)
        QualiteNuit.start(router: router)   // 29/10 (chantier 5) : banc qualité nocturne (Feat_QualiteNuit.swift)
        // Signal des volets (uibridge.js) : session expirée / page de connexion / lecture réussie.
        s.on("POST", "/api/integrations/signal") { req, res in
            let src: String = (req.json["pane"] as? String) ?? ""
            guard IntegrationWatch.labels[src] != nil else { res.json(["ok": false]); return }
            let ok: Bool = (req.json["ok"] as? Bool) ?? false
            IntegrationWatch.signal(src, ok: ok, code: (req.json["code"] as? String) ?? "", msg: (req.json["msg"] as? String) ?? "")
            res.json(["ok": true])
        }
        s.on("GET", "/api/integrations") { _, res in res.json(IntegrationWatch.state()) }
    }
}
