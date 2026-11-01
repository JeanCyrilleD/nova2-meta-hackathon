import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 01/11 (Meta AI Developer Hackathon) — MODE « meta_only », VRAI EN DUR dans la version soumise.
/// Aucun modèle d'IA non Meta n'existe dans ce code (catalogue Brains.swift : API Meta Model, Muse Code, Spark Open via
/// Baseten / Hugging Face). Ce fichier garde une défense en profondeur et la PREUVE visible des appels :
///  - Routeur : seuls les cerveaux de la famille Meta sont « utilisables » (Router.usable/plan/chat) ; aucun filet local.
///  - Voix : reconnaissance et synthèse vocales système macOS (SFSpeechRecognizer / AVSpeechSynthesizer, pas des modèles
///    génératifs appelés par Nova), Muse Voice Transcribe pour la dictée.
///  - Barrière réseau : HTTPStream.run passe par `gate` — un appel vers un hôte de modèle connu qui ne sert pas un modèle
///    Meta est bloqué AVANT l'envoi. Les services non-IA (Algolia, Tavily, Gmail, flux…) passent.
///  - Journal de preuve : releves/diag/meta_only_journal.jsonl (Paths.diagFile) — fournisseur, modèle, meta, statut.
public enum MetaOnly {
    public static let settingKey: String = "meta_only"
    public static let journalName: String = "meta_only_journal.jsonl"
    static let metaProviders: Set<String> = ["meta"]
    static let metaFamilies: Set<String> = ["muse", "llama", "meta"]
    static let metaModelPrefixes: [String] = ["muse-", "meta-models/", "meta-llama/", "meta/"]

    final class State: @unchecked Sendable {
        let lock = NSLock()
        var cached: (value: Bool, at: Date)? = nil
        var override: Bool? = nil
        let journalLock = NSLock()
    }
    static let state = State()

    /// Mode actif : TOUJOURS vrai dans la version hackathon (aucun réglage ne peut le couper).
    public static var enabled: Bool { true }
    /// Conservé pour l'API (après un changement de réglage) : sans effet, le mode est fixe.
    public static func invalidate() {}

    // MARK: famille

    public static func isMetaModel(_ model: String) -> Bool {
        let m: String = model.lowercased()
        return metaModelPrefixes.contains { m.hasPrefix($0) }
    }
    /// Fournisseur déduit de l'hôte (nom court, sinon l'hôte lui-même).
    public static func provider(host: String, port: Int? = nil) -> String {
        let h: String = host.lowercased()
        let table: [(String, String)] = [("api.meta.ai", "meta"), ("baseten.co", "baseten"), ("huggingface.co", "huggingface")]
        for (suffix, name) in table where h == suffix || h.hasSuffix("." + suffix) { return name }
        if h == "127.0.0.1" || h == "localhost" { return "local" }
        return h
    }
    /// Le cerveau est-il de la famille Meta ? Registre (Config/brains.json) d'abord, puis fournisseur de l'hôte, puis modèle.
    public static func isMeta(_ spec: BrainSpec) -> Bool {
        if let reg = RoutingV2.registry(), let e = reg.brains.values.first(where: { $0.novaSpec == spec.id }) {
            return metaProviders.contains(e.provider) || metaFamilies.contains(e.family)
        }
        if let u = URL(string: spec.baseURL), let h = u.host, metaProviders.contains(provider(host: h, port: u.port)) { return true }
        return isMetaModel(spec.model)
    }
    public static func providerName(_ spec: BrainSpec) -> String {
        if let reg = RoutingV2.registry(), let e = reg.brains.values.first(where: { $0.novaSpec == spec.id }) { return e.provider }
        if spec.baseURL.hasPrefix("cli://muse") { return "meta" }
        if let u = URL(string: spec.baseURL), let h = u.host { return provider(host: h, port: u.port) }
        return spec.baseURL
    }

    // MARK: classification réseau

    struct ModelCall { let provider: String; let model: String; let meta: Bool; let host: String }

    /// Hôtes de MODÈLES : ceux du catalogue de cerveaux (Brains.swift), tous Meta.
    /// Clé « hôte » (ou « hôte:port » en boucle locale).
    static func hostKey(_ u: URL) -> String {
        let h: String = (u.host ?? "").lowercased()
        if h == "127.0.0.1" || h == "localhost" { return "127.0.0.1:" + String(u.port ?? 80) }
        return h
    }
    static let catalogHosts: (all: Set<String>, metaServing: Set<String>) = {
        var all: Set<String> = [], meta: Set<String> = []
        for s in Catalog.defaults() {
            guard let u = URL(string: s.baseURL), u.host != nil, let sc = u.scheme, sc.hasPrefix("http") else { continue }
            let k: String = hostKey(u)
            all.insert(k)
            if isMetaModel(s.model) || metaProviders.contains(provider(host: u.host ?? "", port: u.port)) { meta.insert(k) }
        }
        return (all, meta)
    }()

    static func modelOf(url: URL, body: Data?) -> String {
        if let b = body, b.count < 4_000_000, b.first == UInt8(ascii: "{"), let o = parseJSON(b), let m = o["model"] as? String { return m }
        if let c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for q in c.queryItems ?? [] where q.name == "model_id" || q.name == "model" || q.name == "speech_model" { return q.value ?? "" }
        }
        let p: String = url.path
        if let r = p.range(of: "/models/") {
            let rest: String = String(p[r.upperBound...])
            return String(rest.split(separator: ":").first ?? Substring(rest))
        }
        return ""
    }

    /// nil = pas un appel de modèle (service non-IA, ou lecture GET de métadonnées comme /v1/models).
    /// Version Meta : en plus des hôtes du catalogue, TOUT envoi dont le corps JSON nomme un « model », et toute WebSocket hors
    /// API Meta, sont traités comme des appels de modèle — Meta seulement si le fournisseur ou le modèle est Meta (liste blanche).
    static func classify(url: URL, method: String, body: Data?) -> ModelCall? {
        let k: String = hostKey(url)
        let sc: String = (url.scheme ?? "").lowercased()
        let ws: Bool = sc == "ws" || sc == "wss"
        let prov: String = provider(host: url.host ?? "", port: url.port)
        let model: String = modelOf(url: url, body: body)
        let bodyNamesModel: Bool = {
            guard let b = body, b.count < 4_000_000, b.first == UInt8(ascii: "{"), let o = parseJSON(b) else { return false }
            return (o["model"] as? String).map { !$0.isEmpty } ?? false
        }()
        let isModelHost: Bool = catalogHosts.all.contains(k) || catalogHosts.metaServing.contains(k) || prov == "meta"
        guard isModelHost || bodyNamesModel || ws else { return nil }
        guard ws || method.uppercased() != "GET" && method.uppercased() != "HEAD" else { return nil }
        var meta: Bool = metaProviders.contains(prov)
        if !meta, catalogHosts.metaServing.contains(k), isMetaModel(model) { meta = true }   // passerelle (Baseten, Hugging Face…) : Meta seulement si le modèle l'est
        return ModelCall(provider: prov, model: model, meta: meta, host: url.host ?? "")
    }

    // MARK: barrières

    /// Barrière d'une requête HTTP (HTTPStream.run). nil = laisser partir ; sinon raison du blocage (rien n'est envoyé).
    public static func gate(_ req: URLRequest, source: String) -> String? {
        guard enabled, let url = req.url else { return nil }
        return gate(url: url, method: req.httpMethod ?? "GET", body: req.httpBody, source: source)
    }
    public static func gate(url: URL, method: String = "POST", body: Data? = nil, source: String) -> String? {
        guard enabled, let c = classify(url: url, method: method, body: body) else { return nil }
        if c.meta {
            record(provider: c.provider, model: c.model, meta: true, status: "envoye", source: source, host: c.host)
            return nil
        }
        let why: String = "meta_only : appel au modèle non Meta « \(c.provider)\(c.model.isEmpty ? "" : " / " + c.model) » bloqué avant l'envoi"
        record(provider: c.provider, model: c.model, meta: false, status: "bloque", source: source, host: c.host, reason: why)
        return why
    }
    /// Barrière d'un cerveau (BrainRunner.stream, CLI Muse Code). nil = autorisé.
    /// Les cerveaux HTTP autorisés sont journalisés par la barrière réseau ; les autres (CLI) ici, quand `logAllowed`.
    public static func gate(spec: BrainSpec, source: String, logAllowed: Bool = false) -> String? {
        guard enabled else { return nil }
        if isMeta(spec) {
            if logAllowed { record(provider: providerName(spec), model: spec.model, meta: true, status: "envoye", source: source, host: "", brain: spec.id) }
            return nil
        }
        let why: String = "meta_only : cerveau non Meta « \(spec.label) » (\(providerName(spec))) bloqué avant l'envoi"
        record(provider: providerName(spec), model: spec.model, meta: false, status: "bloque", source: source, host: "", reason: why, brain: spec.id)
        return why
    }
    /// Un composant non Meta coupé par le mode (voix, images…) — journalisé comme bloqué, rien n'est envoyé.
    public static func blocked(provider: String, model: String, source: String, reason: String) {
        record(provider: provider, model: model, meta: false, status: "bloque", source: source, host: "", reason: reason)
    }

    // MARK: journal

    public static var journalURL: URL { Paths.diagFile(journalName) }

    static func record(provider: String, model: String, meta: Bool, status: String, source: String, host: String, reason: String = "", brain: String = "",
                       specialite: String = "", chain: [String] = [], extra: [String: Any] = [:]) {
        var e: [String: Any] = ["ts": nowISO(), "fournisseur": provider, "modele": model, "meta": meta, "statut": status, "source": source]
        if !host.isEmpty { e["hote"] = host }
        if !brain.isEmpty { e["cerveau"] = brain }
        if !reason.isEmpty { e["raison"] = String(reason.prefix(300)) }
        if !specialite.isEmpty { e["specialite"] = specialite }   // 01/11 : routage par spécialité (MetaSpecialites)
        if !chain.isEmpty { e["chaine"] = chain.joined(separator: ">") }
        for (k, v) in extra where e[k] == nil { e[k] = v }
        let line: Data = jsonData(e) + Data("\n".utf8)
        state.journalLock.lock(); defer { state.journalLock.unlock() }
        let url: URL = journalURL
        if let a = try? FileManager.default.attributesOfItem(atPath: url.path), let n = a[.size] as? NSNumber, n.intValue > 5_000_000 {
            let old: URL = url.deletingLastPathComponent().appendingPathComponent(journalName + ".1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }
    /// Dernières lignes du journal (diagnostic, tests).
    public static func journalTail(_ n: Int = 200) -> [[String: Any]] {
        guard let d = try? Data(contentsOf: journalURL), let s = String(data: d, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").suffix(n).compactMap { parseJSON(Data($0.utf8)) }
    }
    /// État servi au diagnostic et à l'interface.
    public static func snapshot(router: Router?) -> [String: Any] {
        var o: [String: Any] = ["meta_only": enabled, "journal": journalURL.path]
        if let r = router {
            let ids: [String] = r.brains.filter { isMeta($0) }.map { $0.id }
            o["cerveaux_meta"] = ids
            o["cerveaux_meta_utilisables"] = ids.filter { r.usable($0) }
        }
        return o
    }
}
