import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// META-MUSE (26/10/2026, ordre d'Ahadi) : capacités Meta Model API HORS chat —
/// Muse Image (génération/édition), SAM 3.1 (segmentation), Muse Voice Transcribe
/// (temps réel uniquement). Les cerveaux conversationnels (Wonder, Spark) vivent dans
/// Brains.swift ; ici, uniquement ce qui n'est pas un cerveau.
///
/// Sources officielles vérifiées le 26/10/2026 : dev.meta.ai/docs/models (IDs et
/// protocoles), /docs/image-generation (POST /v1/images/generations, compatible
/// [tiers] Images), /docs/media-segmentation (SAM 3.1 via Responses API).
///
/// POLITIQUE A : ces appels envoient du contenu vers le cloud Meta. Chaque route
/// exige donc « confirm_cloud: true » dans le corps — le GO explicite d'Ahadi,
/// par appel. Sans clé au Trousseau, les routes répondent une erreur claire :
/// jamais de faux succès, jamais de valeur de clé exposée.
public enum MetaCapabilities {
    public static let apiBase = "https://api.meta.ai/v1"
    public static let imageModel = "muse-image-1.0"
    public static let segmentModel = "sam-3.1"
    public static let voiceModel = "muse-voice-transcribe-1.0"
    public static let voiceRealtimeURL = "wss://api.meta.ai/v1/asr/realtime"

    /// Chaîne de clés Meta : service historique SparkLocal (env MODEL_API_KEY /
    /// META_API_KEY), service Nova « nova-spark », service Nova « nova-meta ».
    public static var keyChain: KeyChain {
        KeyChain([KnownKeys.spark, KnownKeys.sparkNova, KnownKeys.metaModelAPI])
    }

    // MARK: - Charges utiles pures (testées sans réseau)

    /// POST /v1/images/generations — forme [tiers] Images (doc image-generation).
    public static func imagePayload(prompt: String) -> [String: Any] {
        ["model": imageModel, "prompt": prompt]
    }

    /// Responses API — SAM 3.1 : un message utilisateur = texte (concept à
    /// segmenter, groupe nominal court) + image (URL). Doc media-segmentation.
    public static func segmentPayload(prompt: String, imageURL: String) -> [String: Any] {
        ["model": segmentModel,
         "input": [["type": "message", "role": "user",
                    "content": [["type": "input_text", "text": prompt],
                                ["type": "input_image", "image_url": imageURL]]]]]
    }

    /// Descripteur Muse Voice : temps réel seulement (aucun endpoint batch —
    /// doc speech-to-text / LiteLLM). Audio PCM16 mono 16 kHz ou 24 kHz.
    public static func voiceDescriptor(keyPresent: Bool) -> [String: Any] {
        ["model": voiceModel, "transport": "websocket", "url": voiceRealtimeURL,
         "key_present": keyPresent, "batch_supported": false,
         "audio": ["format": "audio/pcm", "rates": [16000, 24000], "channels": 1],
         "note": "Transcription temps réel uniquement : aucun endpoint batch/fichier. La dictée locale de Nova reste le chemin par défaut ; ce canal s'active par session explicite."]
    }

    // MARK: - Transport (synchrone borné, patron syncPost de Brains.swift)

    static func postJSON(path: String, payload: [String: Any], key: String, timeout: TimeInterval = 90) -> (Int, [String: Any], String) {
        guard let url = URL(string: apiBase + path) else { return (0, [:], "URL Meta invalide") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData(payload)
        let (status, data) = syncPost(req, timeout: timeout)
        let text = String(data: data, encoding: .utf8) ?? ""
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, obj, text)
    }
}

// MARK: - Routes (/api/meta/*)

extension NovaApp {
    /// META-MUSE : statut + capacités cloud Meta, derrière le jeton local habituel.
    /// Aucune valeur de clé n'est jamais renvoyée : seulement « présente ou non ».
    func metaRoutes() {
        metaFeatureRoutes()   // nouveautés 26/10 : pré-vol, index PJ Outlook, estimateur
        let s = server
        s.on("GET", "/api/meta/status") { [self] _, res in
            let keyPresent = MetaCapabilities.keyChain.resolve(keys) != nil
            let engines = router.engines().map { ["name": $0.name, "models": $0.models] as [String: Any] }
            res.json([
                "ok": true, "key_present": keyPresent, "api_base": MetaCapabilities.apiBase,
                "chat_models": ["muse-wonder-1.0", "muse-spark-1.3", "muse-spark-1.2", "muse-spark-1.1"],
                "image_model": MetaCapabilities.imageModel,
                "segment_model": MetaCapabilities.segmentModel,
                "voice": MetaCapabilities.voiceDescriptor(keyPresent: keyPresent),
                "open_weights": [
                    "glimmer": "Muse Glimmer (Apache 2.0) : poids ouverts, non branché dans cette version.",
                    "spark_open": "Muse Spark Open : servi par Baseten (spark-open-baseten, meta-models/muse-spark-open) et Hugging Face (spark-open-hf).",
                ],
                "local_engines": engines,
                "pricing": ["wonder": "4 $ / 20 $ par M de jetons (entrée/sortie)", "spark_standard": "1,25 $ / 4,25 $ par M", "spark_contributor": "0,10 $ / 0,20 $ par M — contenu réutilisable par Meta", "image": "par image (grille Meta Model API)", "voice": "à la seconde d'audio"],
                "policy": "Politique A : aucun envoi cloud sans confirm_cloud=true par appel. Mode Contributor ACTIF sur ordre nommé d'Ahadi (26/10) : chaînes rapide/bulk, jamais en profond.",
            ])
        }
        s.on("POST", "/api/meta/image") { [self] req, res in
            guard (req.json["confirm_cloud"] as? Bool) == true else {
                res.json(["ok": false, "error": "Politique A : envoi vers le cloud Meta non confirmé (confirm_cloud=true requis, par appel)."], status: 403); return
            }
            guard let key = MetaCapabilities.keyChain.resolve(keys) else {
                res.json(["ok": false, "error": "Aucune clé Meta Model API au Trousseau (services nova-meta / nova-spark, ou MODEL_API_KEY). Ajoute-la dans Réglages › Connexions."], status: 400); return
            }
            let prompt = ((req.json["prompt"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { res.json(["ok": false, "error": "prompt vide"], status: 400); return }
            let (status, obj, raw) = MetaCapabilities.postJSON(path: "/images/generations", payload: MetaCapabilities.imagePayload(prompt: prompt), key: key)
            if status >= 200 && status < 300 {
                MetaSpecialites.noter(specialite: .image, modele: MetaCapabilities.imageModel, cerveau: "", chaine: [], statut: "ok", source: "api.meta.image")
                _ = BlackBox.record(["tool": "meta_image", "actor": "Ahadi", "why": "génération Muse Image confirmée (prompt \(prompt.count) car.)", "ok": true, "effect": "lecture"])
                res.json(["ok": true, "status": status, "result": obj])
            } else {
                res.json(["ok": false, "status": status, "error": "Meta Model API a répondu \(status)", "detail": String(raw.prefix(600))], status: 502)
            }
        }
        s.on("POST", "/api/meta/segment") { [self] req, res in
            guard (req.json["confirm_cloud"] as? Bool) == true else {
                res.json(["ok": false, "error": "Politique A : envoi vers le cloud Meta non confirmé (confirm_cloud=true requis, par appel)."], status: 403); return
            }
            guard let key = MetaCapabilities.keyChain.resolve(keys) else {
                res.json(["ok": false, "error": "Aucune clé Meta Model API au Trousseau (services nova-meta / nova-spark, ou MODEL_API_KEY)."], status: 400); return
            }
            let prompt = ((req.json["prompt"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let imageURL = ((req.json["image_url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty, !imageURL.isEmpty else { res.json(["ok": false, "error": "prompt et image_url requis (concept court, ex. « glasses »)"], status: 400); return }
            let (status, obj, raw) = MetaCapabilities.postJSON(path: "/responses", payload: MetaCapabilities.segmentPayload(prompt: prompt, imageURL: imageURL), key: key)
            if status >= 200 && status < 300 {
                MetaSpecialites.noter(specialite: .segmentation, modele: MetaCapabilities.segmentModel, cerveau: "", chaine: [], statut: "ok", source: "api.meta.segment")
                _ = BlackBox.record(["tool": "meta_segment", "actor": "Ahadi", "why": "segmentation SAM 3.1 confirmée : « \(prompt) »", "ok": true, "effect": "lecture"])
                res.json(["ok": true, "status": status, "result": obj.isEmpty ? ["raw": String(raw.prefix(4000))] : obj])
            } else {
                res.json(["ok": false, "status": status, "error": "Meta Model API a répondu \(status)", "detail": String(raw.prefix(600))], status: 502)
            }
        }
    }
}

// MARK: - Nouveautés 26/10 (demande d'Ahadi « fais tout ») : pré-vol, index PJ, coûts

extension MetaCapabilities {
    /// Grille publiée Meta (dev.meta.ai/docs/pricing-rate-limits, 26/10) : $ par M de jetons.
    public static func pricePerMTok(_ brain: String) -> (input: Double, output: Double)? {
        switch brain {
        case "wonder-1.0": return (4.0, 20.0)
        case "spark-1.3", "spark-1.2", "spark-1.1": return (1.25, 4.25)
        case "spark-1.3-contributor", "spark-1.2-contributor": return (0.10, 0.20)
        default: return nil
        }
    }
    /// Estimation de coût (USD) — fonction pure, testée. nil si cerveau hors grille Meta.
    public static func estimateUSD(brain: String, inputTokens: Int, outputTokens: Int) -> Double? {
        guard let p = pricePerMTok(brain) else { return nil }
        return (Double(max(0, inputTokens)) * p.input + Double(max(0, outputTokens)) * p.output) / 1_000_000.0
    }

    /// PRÉ-VOL D'ENVOI (fonction pure, testée) : relit un brouillon AVANT le GO
    /// d'Ahadi et signale les écarts classiques. Ne décide rien, n'envoie rien :
    /// la sortie est une liste de contrôles (ok / warn / block) affichée telle quelle.
    public static func preflightChecks(to: String, subject: String, body: String, attachments: [String]) -> [[String: String]] {
        var out: [[String: String]] = []
        let toT = to.trimmingCharacters(in: .whitespacesAndNewlines)
        let subT = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyT = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if toT.isEmpty { out.append(["level": "block", "label": "Aucun destinataire — rien ne peut partir."]) }
        else if !toT.contains("@") { out.append(["level": "warn", "label": "Destinataire sans « @ » : vérifie l'adresse (« \(toT) »)."]) }
        else { out.append(["level": "ok", "label": "Destinataire : \(toT)"]) }
        out.append(subT.isEmpty ? ["level": "warn", "label": "Objet vide — la plupart des lecteurs le signalent comme brouillon."]
                                : ["level": "ok", "label": "Objet présent (\(subT.count) caractères)."])
        if bodyT.isEmpty { out.append(["level": "block", "label": "Corps vide."]) }
        else if bodyT.count < 40 { out.append(["level": "warn", "label": "Corps très court (\(bodyT.count) caractères) : contexte suffisant ?"]) }
        else { out.append(["level": "ok", "label": "Corps présent (\(bodyT.count) caractères)."]) }
        let mentionsPJ = bodyT.range(of: "ci-joint|ci joint|en pièce jointe|piece jointe|pièce jointe|attached|enclosed", options: [.regularExpression, .caseInsensitive]) != nil
        if mentionsPJ && attachments.isEmpty { out.append(["level": "block", "label": "Le texte annonce une pièce jointe, mais aucune n'est listée."]) }
        if mentionsPJ && !attachments.isEmpty { out.append(["level": "ok", "label": "Pièce jointe annoncée et listée (\(attachments.count))."]) }
        if !attachments.isEmpty && attachments.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) { out.append(["level": "warn", "label": "Une pièce jointe a un nom vide."]) }
        if bodyT.range(of: "IBAN|CVV|mot de passe|password", options: [.regularExpression, .caseInsensitive]) != nil {
            out.append(["level": "warn", "label": "Le corps mentionne une donnée sensible (IBAN/mot de passe…) : à relire avant tout GO."])
        }
        return out
    }
}

extension NovaApp {
    /// Routes des nouveautés (pré-vol, index des pièces jointes Outlook, estimateur).
    /// Enregistrées avec les routes Meta (Extras appelle metaRoutes, qui appelle celle-ci).
    func metaFeatureRoutes() {
        let s = server
        s.on("POST", "/api/meta/preflight") { req, res in
            let checks = MetaCapabilities.preflightChecks(
                to: (req.json["to"] as? String) ?? "", subject: (req.json["subject"] as? String) ?? "",
                body: (req.json["body"] as? String) ?? "",
                attachments: (req.json["attachments"] as? [String]) ?? [])
            let blocked = checks.contains { $0["level"] == "block" }
            res.json(["ok": true, "blocked": blocked, "checks": checks])
        }
        s.on("GET", "/api/meta/outlook") { req, res in
            let q = ((req.query["q"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let items = q.isEmpty ? OutlookLocal.inventory(limit: 30) : OutlookLocal.search(q, limit: 30)
            var out: [[String: Any]] = []
            for a in items {
                var d: [String: Any] = ["name": a.name, "ext": a.ext, "size": a.size, "record": a.recordID,
                                        "modified": ISO8601DateFormatter().string(from: a.modified)]
                if a.ext == "pdf", let t = OutlookLocal.pdfText(a, maxChars: 1200) { d["snippet"] = String(t.prefix(600)) }
                out.append(d)
            }
            res.json(["ok": true, "access": OutlookLocal.accessState(), "count": out.count, "items": out])
        }
        s.on("POST", "/api/meta/estimate") { req, res in
            let brain = (req.json["brain"] as? String) ?? ""
            let inp = (req.json["input_tokens"] as? Int) ?? 0
            let outp = (req.json["output_tokens"] as? Int) ?? 0
            if let usd = MetaCapabilities.estimateUSD(brain: brain, inputTokens: inp, outputTokens: outp) {
                res.json(["ok": true, "brain": brain, "usd": (usd * 10000).rounded() / 10000])
            } else {
                res.json(["ok": false, "error": "Cerveau hors grille Meta publiée (Wonder/Spark)."], status: 400)
            }
        }
    }
}
