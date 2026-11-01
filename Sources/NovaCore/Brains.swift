import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ChatMsg { public var role: String; public var content: String
    /// AUDIT-BRAIN-A : blocs de contenu structurés ([tiers] : text / tool_use / tool_result), posés UNIQUEMENT par
    /// la boucle agent en tool use natif. nil partout ailleurs. `content` reste toujours la vérité textuelle
    /// (estimation de jetons, refit, cerveaux non-[tiers], persistance) : c'est la forme envoyée si les blocs ne le sont pas.
    public var blocks: [[String: Any]]? = nil
    public init(_ r: String, _ c: String) { role = r; content = c }
    public init(_ r: String, _ c: String, blocks b: [[String: Any]]?) { role = r; content = c; blocks = b } }

/// AUDIT-BRAIN-A : contexte d'outils d'un run d'agent, transmis au routeur. Le routeur choisit PAR CERVEAU :
/// [tiers] → `tools` natifs (schémas) + règles courtes `nativeRules` ; autres → protocole texte `textProtocol`
/// inséré dans le préfixe stable du système. Classe (référence) : le routeur y dépose, pour l'appel qui a abouti,
/// les blocs de la réponse (texte + tool_use complets) et le stop_reason ; `nativeActive` dit si la tentative en
/// cours est native (la boucle agent ne retient alors aucun delta). Un run = un objet, un seul fil d'appel.
public final class ToolCtx {
    public let schemas: [[String: Any]]
    public let textProtocol: String
    public let nativeRules: String
    public var nativeActive: Bool = false
    public var blocks: [[String: Any]] = []
    public var stopReason: String = ""
    public init(schemas: [[String: Any]], textProtocol: String, nativeRules: String) {
        self.schemas = schemas; self.textProtocol = textProtocol; self.nativeRules = nativeRules
    }
}

/// AUDIT-BRAIN-A : accumulateur d'un bloc de contenu [tiers] en flux (index → texte ou tool_use + JSON partiel).
struct NativeBlockAcc {
    var type: String
    var text: String
    var id: String
    var name: String
    var json: String
    var closed: Bool
}

/// DIAG2-CONTEXTE P-CTX-7 : estimation de jetons SANS tokenizer (aucun n'existe dans le moteur).
/// ≈ 3 caractères par jeton : le français courant tourne plutôt à 3,5–4 caractères/jeton chez les
/// fournisseurs gardés — l'estimation SURCOMPTE donc légèrement les jetons, c'est-à-dire qu'elle
/// fait rentrer l'assemblage dans la fenêtre avec une marge réelle. Un seul endroit pour ce ratio :
/// si un jour un vrai compteur arrive, c'est ici qu'il se branche.
public enum TokenEst {
    public static func of(_ s: String) -> Int { (s.count + 2) / 3 }
    public static func of(_ msgs: [ChatMsg]) -> Int { msgs.reduce(0) { $0 + of($1.content) } }
}

/// DIAG2-CONTEXTE P-CTX-7 : fenêtre de contexte RÉELLE (jetons) de chaque cerveau de l'ensemble
/// gardé (post-élagage DIAG2-CERVEAUX, 11 lignes). Valeurs publiques des fournisseurs, prises
/// PRUDEMMENT quand la voie d'accès peut les réduire (passerelle, routage auto, moteur local).
/// Un id inconnu retombe sur le plancher : mieux vaut un assemblage court et signalé qu'un
/// contexte rejeté par le fournisseur.
public enum ContextWindow {
    public static let table: [String: Int] = [
        "spark-1.3": 1_000_000,            // muse-spark-1.3, API Meta : contexte 1 M établi (dossier Meta Model API)
        "wonder-1.0": 1_000_000,           // META-MUSE (26/10) : muse-wonder-1.0, 1 048 576 jetons publiés (dev.meta.ai/docs/models) — borne prudente 1 M
        "spark-1.2": 1_000_000,            // META-MUSE (26/10) : muse-spark-1.2, même fenêtre publiée 1 M
        "spark-1.3-contributor": 1_000_000, // META-MUSE (26/10) : variante Contributor, même fenêtre (ACTIVE sur ordre d'Ahadi)
        "spark-1.2-contributor": 1_000_000, // META-MUSE (26/10) : variante Contributor de la 1.2, même fenêtre publiée
        "muse-code": 200_000,              // 26/10 : CLI Muse Code — prompt passé par fichier ; borne prudente
        "spark-open-hf": 128_000,          // 26/10 : Muse Spark Open via Hugging Face — fenêtre servie variable selon le fournisseur → 128 k prudent
        "spark-open-baseten": 128_000,     // 28/10 : Muse Spark Open via Baseten — fenêtre servie non publiée ici → 128 k prudent, comme HF, à confirmer au diagnose
    ]
    public static func tokens(for id: String) -> Int { table[id] ?? 32_000 }
}

/// DIAG2-CONTEXTE P-CTX-7 : du budget de fenêtre au budget d'HISTORIQUE d'un tour.
/// budget = fenêtre − système − réserve de réponse − réserve de croissance (un run avec outils
/// ré-envoie un contexte qui grandit à chaque étape) − marge de sécurité, puis plafond de coût.
/// Le plafond (96 000) est un arbitrage de COÛT assumé et nommé — la fenêtre physique d'un gros
/// cerveau laisserait passer bien plus, mais chaque étape d'un run paie l'assemblage entier
/// (mesuré par DIAG2-FLUX) ; au-delà du plafond, le résumé couvre, jamais le silence.
public enum ContextBudget {
    public static let historyCeiling: Int = 96_000
    public static let lightTokens: Int = 6_000   // mode léger : fenêtre réduite conservée, en jetons (avant : 8 messages plats)
    public static func historyTokens(window: Int, system: String, maxTokens: Int, useTools: Bool) -> Int {
        let sys = TokenEst.of(system)
        let growth = useTools ? min(32_000, window / 5) : 0
        let margin = max(2_000, window / 20)
        return max(4_000, min(historyCeiling, window - sys - maxTokens - growth - margin))
    }
}

extension ChatMsg {
    /// DIAG2-CONTEXTE P-CTX-7 : ré-ajuste un assemblage déjà construit à une fenêtre plus petite
    /// (bascule vers un cerveau à fenêtre réduite, hunk R1). La tête — résumé et/ou note moteur,
    /// avec son faux acquiescement — est conservée ; on garde la FIN du fil verbatim (les échanges
    /// récents) ; si des messages verbatim sautent sans être couverts par un résumé, la note moteur
    /// est créée ou mise à jour avec leur nombre — jamais de coupe nue, même en bascule.
    public static func refit(_ msgs: [ChatMsg], tokenBudget: Int) -> [ChatMsg] {
        if TokenEst.of(msgs) <= tokenBudget { return msgs }
        var head: [ChatMsg] = []; var body: [ChatMsg] = []
        for m in msgs {
            if body.isEmpty, m.role == "user", m.content.hasPrefix("RÉSUMÉ DE LA CONVERSATION") || m.content.hasPrefix("[NOTE MOTEUR :") { head.append(m) }
            else if body.isEmpty, m.role == "assistant", head.count == 1 { head.append(m) }   // faux acquiescement qui suit le résumé/la note
            else { body.append(m) }
        }
        var kept: [ChatMsg] = []; var used = TokenEst.of(head)
        for m in body.reversed() {
            let t = TokenEst.of(m.content)
            if used + t > tokenBudget, !kept.isEmpty { break }
            used += t; kept.append(m)
        }
        let dropped = body.count - kept.count
        if dropped > 0, !head.contains(where: { $0.content.hasPrefix("RÉSUMÉ DE LA CONVERSATION") }) {
            let note = ChatMsg("user", "[NOTE MOTEUR : \(dropped) message(s) plus ancien(s) de ce fil ne sont PAS joints à ce tour (fenêtre du cerveau qui sert ce tour). Tu n'as pas lu le début de cette conversation : si l'utilisateur y fait allusion, dis-le franchement et demande-lui de préciser — n'invente jamais ce qui a pu y être dit ou décidé.]")
            if head.first?.content.hasPrefix("[NOTE MOTEUR :") == true { head[0] = note }
            else {
                head.insert(note, at: 0)
                if kept.first?.role == "user" { head.append(ChatMsg("assistant", "Noté : je sais que le début de ce fil ne m'est pas joint.")) }
            }
        }
        return head + kept.reversed()
    }
}

/// Format de fil : « chat » = Chat Completions (API Meta Model, Baseten, Hugging Face). « local » : réservé, aucun moteur local en version hackathon.
public enum BrainKind { case chat, local }

public struct BrainSpec {
    public var id: String
    public var label: String
    public var kind: BrainKind
    public var baseURL: String           // URL complète du endpoint de chat
    public var model: String
    public var keys: KeyChain
    public var tags: Set<String>         // "rapide", "puissant", "local", "voix"
    public var note: String
    public var extraHeaders: [String: String] = [:]
    public init(id: String, label: String, kind: BrainKind, baseURL: String, model: String, keys: KeyChain,
                tags: Set<String>, note: String = "", extraHeaders: [String: String] = [:]) {
        self.id = id; self.label = label; self.kind = kind; self.baseURL = baseURL; self.model = model
        self.keys = keys; self.tags = tags; self.note = note; self.extraHeaders = extraHeaders
    }
}

public enum BrainEvent {
    case start(id: String, label: String)
    case delta(String)
    /// VÉRITÉ-3 (E3, 23/10) : frontière de génération. Le texte diffusé jusqu'ici était un
    /// brouillon qu'une NOUVELLE génération remplace : relances internes d'Agent.run (nudge,
    /// format étranger, appel tronqué, réponse vide), synthèse de secours, bascule du routeur.
    /// Tout consommateur qui accumule les .delta REMPLACE son accumulation à cet événement
    /// (la dernière génération fait foi — jamais la concaténation de versions).
    case draftReset
    case failover(from: String, to: String, reason: String, kind: String)
    case usage(input: Int, output: Int)
    case done(id: String, label: String)
    case tool(name: String, input: String, output: String)
    /// LOT M : étape visible de l'agent (kind = « step » ou « confirm ») ; info = charge utile JSON envoyée telle quelle en SSE.
    case step(kind: String, info: [String: Any])
    case error(String)
}

public struct BrainFailure: Error { public let kind: ErrKind; public let message: String }

/// Catalogue par défaut — version hackathon Meta : UNIQUEMENT des modèles Meta (API Meta Model, Muse Code, Spark Open via Baseten / Hugging Face).
public enum Catalog {
    public static func defaults() -> [BrainSpec] {
        // META-MUSE (26/10) : chaîne Meta complète — service historique (env MODEL_API_KEY/META_API_KEY),
        // « nova-spark » et « nova-meta ». Avant : seule « nova-spark » était lue, une clé posée par
        // variable d'environnement ou sous l'ancien service restait invisible (faux « sans_cle »).
        let sparkKeys = KeyChain([KnownKeys.spark, KnownKeys.sparkNova, KnownKeys.metaModelAPI])
        return [
            // META-MUSE (26/10, doc officielle dev.meta.ai/docs/models) : Muse Wonder, frontière pour
            // agents longs et computer use, API Standard uniquement (Wonder Full = Muse Code seul,
            // jamais servi ici). 1 M de contexte, raisonnement minimal→max. Coût publié : 4 $/20 $ par M.
            BrainSpec(id: "wonder-1.0", label: "Wonder 1.0 · Muse (Meta)", kind: .chat, baseURL: "https://api.meta.ai/v1/chat/completions",
                      model: "muse-wonder-1.0", keys: sparkKeys, tags: ["puissant"],
                      note: "Frontière Meta pour tâches agentiques longues (mode profond). Actif seulement si une clé Meta Model API est enregistrée. API = Standard uniquement : Meta ne vend pas Wonder en Contributor pay-as-you-go (doc officielle) ; le contenu n'entraîne donc pas les modèles Meta par cette voie."),
            // NOVA2-CATALOGUE : « spark-1.4 » retiré — modèle muse-spark-1.4 prouvé mort (HTTP 404, diag 20/10/2026).
            BrainSpec(id: "spark-1.3", label: "Spark 1.3 · Muse (Meta)", kind: .chat, baseURL: "https://api.meta.ai/v1/chat/completions",
                      model: "muse-spark-1.3", keys: sparkKeys, tags: ["rapide", "puissant"]),
            // META-MUSE (26/10) : Spark 1.2 en repli de la 1.3 — la doc signale l'audio mieux servi
            // en 1.2 (compréhension audio 1.3 « not fully supported ») ; même clé, même endpoint.
            BrainSpec(id: "spark-1.2", label: "Spark 1.2 · Muse (Meta)", kind: .chat, baseURL: "https://api.meta.ai/v1/chat/completions",
                      model: "muse-spark-1.2", keys: sparkKeys, tags: ["rapide"],
                      note: "Repli Meta : compréhension audio mieux servie qu'en 1.3 (doc officielle). Actif seulement si une clé Meta Model API est enregistrée."),
            // META-MUSE (26/10) — COUTURE DÉSACTIVÉE, POLITIQUE A : le mode Contributor coûte ~10× moins
            // mais Meta peut utiliser le contenu pour entraîner ses modèles. Présent au catalogue pour
            // le jour où Ahadi le décidera EN CONNAISSANCE DE CAUSE ; désactivé par code
            // (stagedDisabledByDefault) + masqué (hiddenByDefault) + absent des trois ordres.
            // META-MUSE (26/10) : Spark 1.2 Contributor (variante documentée) — même règle qu'en 1.3 :
            // contenu réutilisable par Meta, tarif réduit. Sélectionnable à la main ; hors chaînes auto
            // (la 1.3 Contributor y tient déjà le rôle économique, la 1.2 Standard garde l'audio sensible).
            BrainSpec(id: "spark-1.2-contributor", label: "Spark 1.2 Contributor · Muse (Meta) — contenu réutilisable par Meta", kind: .chat, baseURL: "https://api.meta.ai/v1/chat/completions",
                      model: "muse-spark-1.2-contributor", keys: sparkKeys, tags: ["rapide"],
                      note: "Variante Contributor de Spark 1.2 (ordre d'Ahadi 26/10 : Contributor par défaut là où il existe). Sélectionnable ; hors chaînes automatiques."),
            BrainSpec(id: "spark-1.3-contributor", label: "Spark 1.3 Contributor · Muse (Meta) — contenu réutilisable par Meta", kind: .chat, baseURL: "https://api.meta.ai/v1/chat/completions",
                      model: "muse-spark-1.3-contributor", keys: sparkKeys, tags: ["repi"],
                      note: "ACTIF sur ordre nommé d'Ahadi (26/10) : mode Contributor — le contenu envoyé à CE cerveau peut servir à l'entraînement Meta, en échange du tarif réduit (~0,10 $/M). Visible et sélectionnable ; en chaîne automatique rapide/bulk après Spark 1.2. Le mode profond reste sur Wonder/Spark Standard."),
            // 26/10 (Ahadi : abonnement Muse Code) : le CLI officiel « muse exec » — couvert par l'abonnement, aucune clé dans Nova.
            BrainSpec(id: "muse-code", label: "Muse Code (abonnement — Contributor Meta par défaut)", kind: .chat, baseURL: "cli://muse",
                      model: "muse-code-cli", keys: KeyChain([], fallback: "cli"), tags: ["puissant"], note: "CLI officiel couvert par l'abonnement : chez Meta, le mode Contributor est ACTIVÉ PAR DÉFAUT pour les abonnés Muse Code (doc officielle) — le contenu peut servir à l'entraînement Meta. Désactivable dans les réglages Muse Code, pas depuis Nova."),
            // 26/10 (Ahadi) : Muse Spark Open 816B-A42B, poids ouverts, servi par Hugging Face Inference Providers (« :fastest » = fournisseur le plus rapide).
            BrainSpec(id: "spark-open-hf", label: "Muse Spark Open 816B (Hugging Face)", kind: .chat, baseURL: "https://router.huggingface.co/v1/chat/completions",
                      model: "meta-models/Muse-Spark-Open-816B-A42B:fastest", keys: KeyChain([KnownKeys.hfNova, KnownKeys.hf]), tags: ["puissant"]),
            // 28/10 (Ahadi) : Muse Spark Open servi par Baseten, sélection hackathon Meta — 100 $ de crédits, clé valable UNIQUEMENT pour ce modèle. Visible et sélectionnable à la main ; hors chaînes automatiques (fast/bulk/deep) : aucun contenu personnel n'y part sans choix explicite. Actif seulement si une clé Baseten est enregistrée (Trousseau « nova-baseten » ou variable BASETEN_API_KEY).
            BrainSpec(id: "spark-open-baseten", label: "Muse Spark Open (Baseten — hackathon)", kind: .chat, baseURL: "https://inference.baseten.co/v1/chat/completions",
                      model: "meta-models/muse-spark-open", keys: KeyChain([KnownKeys.basetenNova]), tags: ["puissant"],
                      note: "01/11 : nom de modèle corrigé (404 « check the model » avec -1026) selon le changelog Baseten — Baseten hackathon 28/10, modèle à raisonnement (259 tok raisonnement sur Hello). Streaming SSE à vérifier, exige max_tokens >=2048. Actif seulement si clé Baseten enregistrée."),
        ]
    }
    /// CREDITS-SENTRY (23/10) : ids désactivés PAR CODE à chaque démarrage (union avec
    /// brains_off dans NovaApp.start, App.swift) — l'interrupteur « off » de la couture crédits.
    /// Contrairement à brains_off (réglage utilisateur, purgé au démarrage des ids hors
    /// catalogue), cette liste survit aux réglages : on n'en retire un id que le jour où le
    /// crédit correspondant est actif et la clé déposée au Trousseau.
    public static let stagedDisabledByDefault: Set<String> = []
    /// Cerveaux MASQUÉS : retirés des listes servies à l'interface et des chaînes automatiques (vide en version hackathon).
    public static let hiddenByDefault: Set<String> = []
    /// Cerveau masqué par la politique (voir hiddenByDefault).
    public static func isHidden(_ id: String) -> Bool { hiddenByDefault.contains(id) }
    /// Ordres de repli par mode — 100 % Meta.
    public static let fastOrder = ["spark-1.3", "spark-1.2", "wonder-1.0"]   // hackathon Meta : 100 % Meta (Spark Open Baseten ajouté en secours par MetaSpecialites)
    /// Mode « bulk » : tâches longues, répétitives, de fond (Dots, briefs).
    public static let bulkOrder = ["spark-1.3", "spark-1.2"]
    public static let deepOrder = ["spark-1.3", "wonder-1.0", "spark-1.2"]
}

public struct LocalEngine { public var name: String; public var base: String; public var models: [String] }

public func syncGet(_ req: URLRequest, timeout: TimeInterval = 5) -> (Int, Data) {
    var out = Data(); var status = 0
    let r = HTTPStream.run(req, firstByteTimeout: timeout, idleTimeout: timeout, totalTimeout: timeout + 2) { out.append($0); return true }
    status = r.status
    if r.status >= 400 { out = r.body }
    return (r.error != nil && r.status == 0 ? 0 : status, out)
}

/// NOVA2-FIX (reco n°18) : POST synchrone borné, même patron que syncGet — pour les
/// appels Meta hors chat (Muse Image, SAM 3.1) dont la réponse n'est pas un flux.
public func syncPost(_ req: URLRequest, timeout: TimeInterval = 60) -> (Int, Data) {
    var out = Data(); var status = 0
    let r = HTTPStream.run(req, firstByteTimeout: timeout, idleTimeout: timeout, totalTimeout: timeout + 30) { out.append($0); return true }
    status = r.status
    if r.status >= 400 { out = r.body }
    return (r.error != nil && r.status == 0 ? 0 : status, out)
}

/// Un appel de cerveau, bloquant, avec événements en direct. Lève BrainFailure si rien n'a abouti.
public final class BrainRunner {
    /// Extrait N de « … can only afford N » / « 1199 finançables ». nil si absent ou N trop petit pour être utile.
    static func affordable(_ body: Data) -> Int? {
        let t = String(data: body, encoding: .utf8) ?? ""
        guard let r = t.range(of: #"afford\s+(\d+)"#, options: .regularExpression) else { return nil }
        let n = Int(t[r].filter { $0.isNumber })
        if let n = n, n >= 150 { return n }
        return nil
    }
    public let keys: KeyStore
    public init(keys: KeyStore) { self.keys = keys }

    static func finalBlocks(_ acc: [Int: NativeBlockAcc]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for k in acc.keys.sorted() {
            guard let b = acc[k] else { continue }
            if b.type == "text" {
                if !b.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let tb: [String: Any] = ["type": "text", "text": b.text]
                    out.append(tb)
                }
            } else if b.type == "tool_use", b.closed, !b.id.isEmpty, !b.name.isEmpty {
                let raw: String = b.json.trimmingCharacters(in: .whitespacesAndNewlines)
                var input: [String: Any] = [:]
                if !raw.isEmpty {
                    guard let p = parseJSON(Data(raw.utf8)) else { _ = BlackBox.record(["tool": "tool_use_invalide", "actor": "Nova", "why": "arguments JSON illisibles pour un appel d'outil — appel ignoré (audit 29/10 n°8)", "ok": false, "effect": "lecture"]); continue }
                    input = p
                }
                let ub: [String: Any] = ["type": "tool_use", "id": b.id, "name": b.name, "input": input]
                out.append(ub)
            }
        }
        return out
    }

    public func stream(_ spec: BrainSpec, messages: [ChatMsg], system: String?, maxTokens: Int, mode: String,
                       firstTokenTimeout: TimeInterval, cancel: @escaping () -> Bool, retried: Bool = false, noCache: Bool = false,
                       onDelta: @escaping (String) -> Void, onUsage: @escaping (Int, Int) -> Void,
                       onStop: ((String) -> Void)? = nil,   // AUDIT-24/10: onStop("max_tokens" | "cut") — réponse tronquée signalée à l'appelant (nil = comportement d'avant)
                       tools: [[String: Any]]? = nil, cacheHistory: Bool = false,
                       onBlocks: (([[String: Any]], String) -> Void)? = nil,
                       onCache: ((Int, Int) -> Void)? = nil,
                       reasoningOverride: String? = nil) throws {   // 31/10 (CAFU) : effort de raisonnement imposé (API Meta : reasoning_effort ∈ minimal…xhigh, max) — nil = comportement d'avant
        // AUDIT-BRAIN-A : tools = schémas natifs ([tiers] seulement, ignorés ailleurs) ; cacheHistory = points de cache sur
        // l'historique ; onBlocks(blocs, stop_reason) = contenu structuré final (mode natif) ; onCache(lus, écrits) = jetons de cache.
        // 01/11 (meta_only) : barrière par cerveau — aussi pour les appels directs hors routeur (CAFU, bancs, diagnostic).
        if let why = MetaOnly.gate(spec: spec, source: "brainrunner") { throw BrainFailure(kind: .other, message: why) }
        // 01/11 (bonus open-weight) : chaque appel réel à Spark Open (Baseten) est journalisé (meta_only_journal.jsonl, tous modes) — preuve vidéo/README.
        if spec.id == "spark-open-baseten" { MetaSpecialites.noterBaseten(statut: "envoye", source: "brainrunner", specialite: MetaSpecialites.specialite(mode: mode, outils: false)?.rawValue ?? mode, mode: mode) }
        var key = spec.keys.resolve(keys) ?? ""
        if spec.kind != .local && key.isEmpty { throw BrainFailure(kind: .auth, message: "clé introuvable dans le Trousseau") }
        if let d = key.data(using: .utf8), d.first == UInt8(ascii: "{"), let o = parseJSON(d) {   // grant OAuth JSON
            key = (o["api_key"] as? String) ?? (o["access_token"] as? String) ?? key
        }
        guard let url = URL(string: spec.baseURL) else { throw BrainFailure(kind: .other, message: "URL invalide") }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in spec.extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        var body: [String: Any]
        // Partage de préfixe : Persona.system sépare un préfixe stable d'un suffixe dynamique par Persona.cacheMark. Le séparateur n'est
        // JAMAIS envoyé tel quel ; sans lui (autres appelants) le comportement est strictement celui d'avant.
        // 29/10 : filet unique — tout appel (routeur, briefs, voix…) reçoit le nom réel du cerveau à la place de ⟦SERVI_PAR⟧.
        let sysIn: String? = system.map { (t: String) -> String in t.contains("⟦SERVI_PAR⟧") ? t.replacingOccurrences(of: "⟦SERVI_PAR⟧", with: spec.label) : t }
        var sysStable = sysIn ?? "", sysDyn = ""; var hasMark = false
        if let s0 = sysIn, let mr = s0.range(of: Persona.cacheMark) { sysStable = String(s0[..<mr.lowerBound]); sysDyn = String(s0[mr.upperBound...]); hasMark = true }
        let sysPlain: String? = (sysIn == nil) ? nil : (hasMark ? (sysDyn.isEmpty ? sysStable : sysStable + "\n" + sysDyn) : sysStable)
        var usedExtras = false   // champs de cache envoyés : si le fournisseur les refuse (400/422), on retente sans
        let native: Bool = false   // hackathon Meta : aucun cerveau Meta en tool use natif ici — protocole texte (ToolCtx.textProtocol)
        switch spec.kind {
        case .chat, .local:
            if !key.isEmpty { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
            var msgs: [[String: String]] = []
            if let s = sysPlain, !s.isEmpty { msgs.append(["role": "system", "content": s]) }
            msgs += messages.map { ["role": $0.role, "content": $0.content] }
            // Les modèles à raisonnement dépensent d'abord des jetons à « réfléchir » : plancher de sortie à la 1re tentative.
            let cap = spec.id == "spark-open-baseten" ? max(maxTokens, 2048) : ((retried || spec.kind == .local) ? maxTokens : max(maxTokens, 320)) // 28/10 contrôle : raisonnement Baseten 259 tok sur Hello, plancher 320 insuffisant
            body = ["model": spec.model, "max_tokens": cap, "stream": true, "messages": msgs]
            if spec.baseURL.contains("api.meta.ai") {
                // 29/10 (journal Live du 27/10 : 3,5 à 6 s entre la fin de la phrase et le 1er mot sur Spark) :
                // la voix live ne réfléchit pas — effort « none » ; profond = « high » ; le reste « low ».
                let eff: String = reasoningOverride ?? MetaSpecialites.effort(mode: mode)   // 01/11 : deep/code high, juge medium, voice none, reste low (valeurs historiques inchangées)   // 31/10 (CAFU) : niveau imposé par le mode CAFU (max → xhigh → high, jamais en silence)
                body["reasoning_effort"] = eff
            }   // META-MUSE (26/10) : profond = effort élevé (Wonder/Spark, niveaux officiels minimal→max) ; sinon bas pour la latence
        }
        req.httpBody = jsonData(body)

        var parser = SSEParser()
        var gotDelta = false
        var modelNoted = false   // 31/10 : preuve du modèle servi — une seule note par appel
        var gotThinking = false   // le modèle « réfléchit » (reasoning) : il est vivant, on lui laisse un peu plus de temps
        var gotTool = false       // AUDIT-BRAIN-A : un bloc tool_use a commencé (réponse « outil seul », sans texte : ce n'est PAS une réponse vide)
        var gotLife = false       // AUDIT-BRAIN-A : message_start / ping / début de bloc = signe de vie avant le premier mot
        var stopReason: String = ""   // AUDIT-24/10: stop_reason ([tiers]) / finish_reason ([tiers]) — « max_tokens » = réponse tronquée
        var failure: BrainFailure? = nil
        var acc: [Int: NativeBlockAcc] = [:]   // AUDIT-BRAIN-A : blocs [tiers] par index
        var msIn: Int = 0                      // AUDIT-BRAIN-A : jetons d'entrée lus dès message_start
        var cRead: Int = 0, cWrite: Int = 0    // AUDIT-BRAIN-A : cache_read_input_tokens / cache_creation_input_tokens
        let started = Date()
        let hardCancel: () -> Bool = {
            if cancel() { return true }
            let produced: Bool = gotDelta || gotTool
            let limit: TimeInterval = (gotThinking || gotLife) ? firstTokenTimeout * 2.5 : firstTokenTimeout
            return !produced && Date().timeIntervalSince(started) > limit
        }
        // AUDIT-24/10 + AUDIT-BRAIN-A : durée totale proportionnelle au plafond de sortie pour tout cerveau cloud ([tiers] ≥ 300 s, ≤ 900 s) — la vivacité reste gardée par le flux muet (25 s).
        var totalT: TimeInterval = mode == "deep" ? 180 : 120
        if spec.kind != .local {
            let prop: TimeInterval = 30 + Double(maxTokens) / 40
            let base: TimeInterval = totalT
            totalT = min(900, max(base, prop))
        }
        let res = HTTPStream.run(req, firstByteTimeout: firstTokenTimeout, idleTimeout: reasoningOverride == nil ? 25 : 180, totalTimeout: totalT, cancel: hardCancel) { chunk in   // 31/10 (CAFU) : idle 180 s si effort imposé — au raisonnement max, le flux peut rester muet longtemps
            for ev in parser.feed(chunk) {
                if ev.data == "[DONE]" { continue }
                guard let o = parseJSON(Data(ev.data.utf8)) else { continue }
                switch spec.kind {
                case .chat, .local:
                    if let e = o["error"] as? [String: Any] {
                        let m = (e["message"] as? String) ?? "erreur fournisseur"
                        failure = BrainFailure(kind: classify(status: (e["code"] as? Int) ?? 0, body: m), message: shortError(m)); return false
                    }
                    if !modelNoted, let sm = o["model"] as? String, !sm.isEmpty { modelNoted = true; ModelProof.note(brain: spec.id, asked: spec.model, served: sm) }   // 31/10 : preuve du modèle servi (une fois par appel)
                    if let u = o["usage"] as? [String: Any] {
                        // 31/10 (audit prompt) : format Chat Completions — prompt_tokens INCLUT les jetons servis par le cache
                        // (prompt_tokens_details.cached_tokens), comptés à part ; l'entrée facturée plein tarif = prompt_tokens − cached_tokens.
                        let ptd: [String: Any] = (u["prompt_tokens_details"] as? [String: Any]) ?? [:]
                        let cachedTok: Int = (ptd["cached_tokens"] as? Int) ?? 0
                        let promptTok: Int = (u["prompt_tokens"] as? Int) ?? 0
                        if cachedTok > 0 { cRead = max(cRead, cachedTok) }
                        onUsage(max(0, promptTok - cachedTok), (u["completion_tokens"] as? Int) ?? 0)
                    }
                    for ch in (o["choices"] as? [[String: Any]]) ?? [] {
                        if let fr = ch["finish_reason"] as? String, fr == "length" { stopReason = "max_tokens" }   // AUDIT-24/10
                        if let d = ch["delta"] as? [String: Any] {
                            if let tx = d["content"] as? String, !tx.isEmpty { gotDelta = true; onDelta(tx) }
                            else if let r = (d["reasoning"] as? String) ?? (d["reasoning_content"] as? String), !r.isEmpty { gotThinking = true }
                        }
                    }
                }
            }
            return true
        }
        if cRead + cWrite > 0 { onCache?(cRead, cWrite) }   // AUDIT-BRAIN-A : le routeur journalise le cache réellement servi
        let errText: String = (String(data: res.body, encoding: .utf8) ?? "").lowercased()
        let cacheRefused: Bool = true || errText.isEmpty
        if usedExtras, !gotDelta, !gotTool, res.status == 400 || res.status == 422, cacheRefused {   // champs de cache non acceptés : repli propre, même requête sans eux
            return try stream(spec, messages: messages, system: system, maxTokens: maxTokens, mode: mode,
                              firstTokenTimeout: firstTokenTimeout, cancel: cancel, retried: retried, noCache: true, onDelta: onDelta, onUsage: onUsage, onStop: onStop,
                              tools: tools, cacheHistory: cacheHistory, onBlocks: onBlocks, onCache: onCache, reasoningOverride: reasoningOverride)
        }
        if let f = failure, !gotDelta { throw f }
        if res.kind == .credit, !gotDelta, !gotTool, !retried, maxTokens > 300, let afford = Self.affordable(res.body) {
            // Fournisseur : « can only afford N » → on redemande avec ce que le solde finance, au lieu d'échouer.
            return try stream(spec, messages: messages, system: system, maxTokens: max(64, afford - 20), mode: mode,
                              firstTokenTimeout: firstTokenTimeout, cancel: cancel, retried: true, noCache: noCache, onDelta: onDelta, onUsage: onUsage, onStop: onStop,
                              tools: tools, cacheHistory: cacheHistory, onBlocks: onBlocks, onCache: onCache, reasoningOverride: reasoningOverride)
        }
        if let e = res.error {
            if res.kind == .canceled && cancel() { throw BrainFailure(kind: .canceled, message: "annulé") }
            if res.kind == .canceled { throw BrainFailure(kind: .timeout, message: "aucun mot reçu après \(Int(firstTokenTimeout)) s") }
            if gotDelta || gotTool {   // coupure en cours de réponse : on garde ce qui est arrivé — AUDIT-24/10: mais la coupure est SIGNALÉE (plus de succès silencieux)
                if native, let ob = onBlocks { ob(BrainRunner.finalBlocks(acc), "cut") }   // AUDIT-BRAIN-A : seuls les tool_use COMPLETS sont rendus
                onStop?("cut"); return
            }
            throw BrainFailure(kind: res.kind ?? .other, message: e)
        }
        if gotDelta || gotTool, stopReason == "max_tokens" { onStop?("max_tokens") }   // AUDIT-24/10: plafond de sortie atteint = réponse tronquée
        if !gotDelta && !gotTool { throw BrainFailure(kind: .other, message: gotThinking ? "raisonnement sans texte (plafond de sortie atteint pendant la réflexion)" : "réponse vide") }   // DIAG2-FLUX P2 : échec nommé par sa cause — le journal cerveaux distingue désormais les deux régimes
        if native, let ob = onBlocks { ob(BrainRunner.finalBlocks(acc), stopReason) }   // AUDIT-BRAIN-A : contenu structuré de la réponse (texte + tool_use complets)
    }
}


/// 31/10 (Ahadi : « comment être sûr que c'est bien [tiers] et pas [tiers], avec une seule clé ? ») — PREUVE DU MODÈLE SERVI.
/// La clé ne choisit pas le modèle : chaque requête nomme son modèle (« model »), et le fournisseur RENVOIE le nom du modèle
/// qui a réellement répondu. Ce nom renvoyé — pas l'étiquette de Nova — est compté ici, par jour :
/// releves/diag/modeles_servis.json {jour: {cerveau Nova: {demande, servi: {modèle renvoyé: nombre}}}}.
enum ModelProof {
    static let lock: NSLock = NSLock()
    static func note(brain: String, asked: String, served: String) {
        lock.lock(); defer { lock.unlock() }
        let path: String = NSHomeDirectory() + "/spark-local/Nova2/releves/diag/modeles_servis.json"
        var o: [String: Any] = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { parseJSON($0) } ?? [:]
        let f: DateFormatter = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let day: String = f.string(from: Date())
        var d: [String: Any] = (o[day] as? [String: Any]) ?? [:]
        var b: [String: Any] = (d[brain] as? [String: Any]) ?? ["demande": asked]
        var sv: [String: Any] = (b["servi"] as? [String: Any]) ?? [:]
        sv[served] = ((sv[served] as? Int) ?? 0) + 1
        b["servi"] = sv; b["dernier"] = nowISO(); d[brain] = b; o[day] = d
        for k in o.keys.sorted().dropLast(14) { o.removeValue(forKey: k) }
        try? jsonData(o).write(to: URL(fileURLWithPath: path))
    }
}
