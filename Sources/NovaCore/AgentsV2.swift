import Foundation

// PHASE 3 (31/10) — AGENTS À ÉTATS EXPLICITES, derrière le réglage `agents_v2` (défaut false : rien ne change).
// Machine à états : draft → awaiting_approval → running → verifying → done | failed | cancelled | paused | unknown.
//   • « done » exige un reçu d'outil (ex. ID de message) ; sans reçu → unknown (effet non prouvé), jamais done.
//   • Approbation liée au SHA-256 (Sha, BlackBox.swift) des octets UTF-8 exacts du contenu montré ; un octet change → annulée.
//   • Reprise : chaque étape porte une clé d'idempotence ; une étape « started » non soldée (interruption) est
//     d'abord RAPPROCHÉE de l'état réel (executor.lookup) avant toute relance — jamais de double envoi.
//   • Par agent : plafond ≤ 0,75 $ (micro-dollars entiers), échéance, max étapes / relances, liste blanche d'outils,
//     portée de classe de données. Budget global, routage et politique fournisseurs = Phase 2 (AgentContracts.swift).
// Réutilise : Sha (SHA-256), BlackBox.record (journal des transitions, moteur partagé seulement), SendQueue.uiSecret
// (provenance d'interface pour l'approbation), Settings. Ne touche ni Dots / DotScheduler / DotCharter ni Agent.run :
// l'adaptateur réel (AgentToolExecutor → Tools.run / SendQueue / Agent.run) se branche après la fusion Phase 2.
// COUPER : réglage `agents_v2` = false (défaut) → routes en 403, moteur partagé jamais exécuté ; DenyAllCostGate
// refuse toute dépense tant que la Phase 2 n'est pas branchée.

public enum AgentState: String, Codable, CaseIterable, Sendable {
    case draft, running, verifying, done, failed, cancelled, paused, unknown
    case awaitingApproval = "awaiting_approval"

    public var isTerminal: Bool { self == .done || self == .failed || self == .cancelled }

    /// Transitions permises — toute autre est refusée (AgentError.forbiddenTransition).
    static let allowed: [AgentState: Set<AgentState>] = [
        .draft: [.awaitingApproval, .running, .cancelled],
        .awaitingApproval: [.running, .draft, .cancelled],
        .running: [.verifying, .awaitingApproval, .paused, .failed, .cancelled, .unknown],
        .verifying: [.done, .failed, .running, .unknown],
        .paused: [.running, .cancelled, .unknown],
        .unknown: [.running, .verifying, .failed, .cancelled],
        .done: [], .failed: [], .cancelled: [],
    ]
    public func canMove(to next: AgentState) -> Bool { AgentState.allowed[self]?.contains(next) ?? false }
}

public enum AgentError: Error, Equatable {
    case unknownAgent(String)
    case dataClassOutOfScope(String)
    case toolNotAllowed(String)
    case tooManySteps(Int)
    case capExceeded(Int64)
    case forbiddenTransition(String, String)
    case notFound
    case approvalMismatch
    case receiptMissing
    case busy
}

/// Définition fermée d'un agent (données, pas code exécutable).
public struct AgentSpec: Sendable {
    public let id: String
    public let label: String
    public let profiles: [AgentRoutingProfile]
    public let tools: Set<String>
    /// Outils à effet externe : exigent une approbation valide (SHA-256) ET un reçu pour finir en done.
    public let approvalTools: Set<String>
    public let dataClasses: Set<AgentDataClass>
    public let capMicros: Int64
    public let deadlineSeconds: TimeInterval
    public let maxSteps: Int
    public let maxRetries: Int
    public let note: String
}

public enum AgentStepStatus: String, Codable, Sendable { case pending, started, done, failed }

public struct AgentStep: Codable, Sendable {
    public let index: Int
    public let tool: String
    public let arg: String
    public let estimateMicros: Int64
    public let idempotencyKey: String
    public var status: AgentStepStatus
    public var attempts: Int
    public var receipt: String?
    public var output: String?
}

public struct AgentTransition: Codable, Sendable {
    public let from: AgentState
    public let to: AgentState
    public let at: Date
    public let why: String
}

public struct AgentTask: Codable, Sendable {
    public let id: String
    public let agent: String
    public let dataClass: AgentDataClass
    public let createdAt: Date
    public var state: AgentState
    /// Contenu exact montré à Ahadi (brouillon, diff, texte à dire…) — l'approbation porte sur ses octets.
    public var content: String
    public var approvalSha: String?
    public var approvedAt: Date?
    public var steps: [AgentStep]
    public var spentMicros: Int64
    public var reason: String
    public var history: [AgentTransition]

    public var contentSha: String { AgentsV2.sha256(content) }
    public var approvalValid: Bool { approvalSha != nil && approvalSha == contentSha }
}

/// Résultat d'un outil. `receipt` = preuve fournie par l'outil (ID de message, SHA de commit, chemin du cache audio…).
public struct AgentToolResult: Sendable {
    public let ok: Bool
    public let output: String
    public let receipt: String?
    public let costMicros: Int64?
    public init(ok: Bool, output: String, receipt: String?, costMicros: Int64?) {
        self.ok = ok; self.output = output; self.receipt = receipt; self.costMicros = costMicros
    }
}

/// Interruption (plantage, coupure, annulation brutale) pendant un appel : l'effet a pu avoir lieu ou non.
public struct AgentInterrupted: Error { public init() {} }

/// Exécuteur d'outils. Les tests utilisent un simulateur ; l'adaptateur réel arrive après la fusion Phase 2.
public protocol AgentToolExecutor: AnyObject {
    func execute(tool: String, arg: String, idempotencyKey: String) throws -> AgentToolResult
    /// État RÉEL : l'effet portant cette clé a-t-il déjà eu lieu ? (ex. message à cet en-tête présent dans Envoyés).
    func lookup(idempotencyKey: String) -> AgentToolResult?
}

public protocol AgentTaskStore: AnyObject {
    func load() -> [String: AgentTask]
    func save(_ tasks: [String: AgentTask])
}

public final class MemoryAgentTaskStore: AgentTaskStore, @unchecked Sendable {
    let lock = NSLock()
    var data: [String: AgentTask] = [:]
    public init() {}
    public func load() -> [String: AgentTask] { lock.lock(); defer { lock.unlock() }; return data }
    public func save(_ tasks: [String: AgentTask]) { lock.lock(); data = tasks; lock.unlock() }
}

/// Persistance disque (écriture atomique) — survit aux plantages et redémarrages.
public final class FileAgentTaskStore: AgentTaskStore, @unchecked Sendable {
    let url: URL
    let lock = NSLock()
    public init(name: String = "agents_v2_tasks.json") { url = Paths.file(name) }
    public func load() -> [String: AgentTask] {
        lock.lock(); defer { lock.unlock() }
        guard let d = try? Data(contentsOf: url) else { return [:] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: AgentTask].self, from: d)) ?? [:]
    }
    public func save(_ tasks: [String: AgentTask]) {
        lock.lock(); defer { lock.unlock() }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(tasks) { try? d.write(to: url, options: .atomic) }
    }
}

/// Brief sourcé : faits, hypothèses, scénarios et recommandations séparés ; une affirmation sans source → « non disponible ».
public struct AgentClaim: Codable, Sendable {
    public let text: String
    public let source: String?
    public init(_ text: String, source: String?) { self.text = text; self.source = source }
    public var sourced: Bool { !((source ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
}

public struct AgentBrief: Codable, Sendable {
    public static let unavailable = "non disponible"
    public var facts: [AgentClaim] = []
    public var hypotheses: [AgentClaim] = []
    public var scenarios: [AgentClaim] = []
    public var recommendations: [AgentClaim] = []
    public init() {}
    public var unsourced: [AgentClaim] { (facts + hypotheses + scenarios + recommendations).filter { !$0.sourced } }
    public func render() -> String {
        func block(_ title: String, _ items: [AgentClaim]) -> String {
            let lines = items.isEmpty ? ["- " + AgentBrief.unavailable]
                : items.map { $0.sourced ? "- \($0.text) [source : \($0.source ?? "")]" : "- " + AgentBrief.unavailable }
            return "## " + title + "\n" + lines.joined(separator: "\n")
        }
        return [block("Faits", facts), block("Hypothèses", hypotheses), block("Scénarios", scenarios), block("Recommandations", recommendations)].joined(separator: "\n\n")
    }
}

public enum AgentsV2 {
    /// Plafond dur par agent / tâche (brief 2.1 per_task_cap_usd = 0,75).
    public static let maxCapMicros: Int64 = 750_000

    public static var enabled: Bool { Settings().get("agents_v2", false) }

    public static func sha256(_ s: String) -> String { Sha.hex(Sha.sha256(Array(s.utf8))) }

    public static func idempotencyKey(task: String, index: Int, tool: String, arg: String) -> String {
        sha256("\(task)\u{1F}\(index)\u{1F}\(tool)\u{1F}\(arg)")
    }

    /// Coder : seul un worktree dédié (…/Nova2-wt/<nom>/…) est permis — jamais le dossier de l'app en service.
    public static func coderWorkspaceAllowed(_ path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        guard p.hasPrefix("/"), !p.contains("/../") else { return false }
        guard let r = p.range(of: "/Nova2-wt/") else { return false }
        return !p[r.upperBound...].isEmpty
    }

    public static let specs: [String: AgentSpec] = {
        let all: [AgentSpec] = [
            AgentSpec(id: "triage", label: "Triage", profiles: [.triage],
                      tools: ["mail_unread", "mail_week", "teams_read", "mail_label"], approvalTools: [],
                      dataClasses: [.personal], capMicros: 100_000, deadlineSeconds: 600, maxSteps: 6, maxRetries: 1,
                      note: "étiquettes et tri seulement ; mail_label = outil à fournir par l'adaptateur réel"),
            AgentSpec(id: "morning_brief", label: "Brief du matin", profiles: [.bulkPublic, .main],
                      tools: ["flux_titres", "web_search", "web_fetch", "calendar", "mail_unread", "brief_save"], approvalTools: [],
                      dataClasses: [.publicData, .personal], capMicros: 300_000, deadlineSeconds: 1800, maxSteps: 10, maxRetries: 1,
                      note: "brouillon seulement ; chaque affirmation sourcée sinon « non disponible »"),
            AgentSpec(id: "research", label: "Recherche", profiles: [.longPublic, .main],
                      tools: ["web_search", "web_fetch", "know", "recall"], approvalTools: [],
                      dataClasses: [.publicData, .personal], capMicros: 500_000, deadlineSeconds: 1800, maxSteps: 12, maxRetries: 2,
                      note: "lecture seule (Search/Fetch)"),
            AgentSpec(id: "mail", label: "Mail", profiles: [.main],
                      tools: ["mail_unread", "mail_corps", "mail_brouillon", "mail_envoyer"], approvalTools: ["mail_envoyer"],
                      dataClasses: [.personal], capMicros: 300_000, deadlineSeconds: 3600, maxSteps: 6, maxRetries: 1,
                      note: "brouillon → approbation (SHA-256) → envoi ; jamais d'envoi sans approbation ; reçu = Message-ID"),
            AgentSpec(id: "cafu_analyst", label: "Analyste CAFU", profiles: [.deep, .verify],
                      tools: ["web_search", "web_fetch", "know", "cafu_format_document", "brief_save"], approvalTools: [],
                      dataClasses: [.publicData, .sciInternal], capMicros: 750_000, deadlineSeconds: 7200, maxSteps: 14, maxRetries: 1,
                      note: "brouillons sourcés : Annual Global Humanitarian Outlook, Quarterly Horizon Brief, Thematic Briefing Papers, Framing Sessions ; sci_internal soumis à sciPolicyConfirmed (Phase 2)"),
            AgentSpec(id: "checker", label: "Vérificateur", profiles: [.verify],
                      tools: ["know", "recall"], approvalTools: [],
                      dataClasses: [.publicData, .personal, .sciInternal], capMicros: 200_000, deadlineSeconds: 900, maxSteps: 4, maxRetries: 1,
                      note: "autre fournisseur que le rédacteur ; signale seulement, ne modifie rien"),
            AgentSpec(id: "coder", label: "Codeur", profiles: [.main],
                      tools: ["read_file", "write_file", "edit_file", "git_diff", "run_tests", "git_push"], approvalTools: ["git_push"],
                      dataClasses: [.publicData], capMicros: 750_000, deadlineSeconds: 7200, maxSteps: 20, maxRetries: 2,
                      note: "worktree isolé (coderWorkspaceAllowed) ; diff + tests ; push seulement sur approbation"),
            AgentSpec(id: "voice", label: "Voix", profiles: [.reflex],
                      tools: ["tts_systeme", "audio_cache"], approvalTools: ["tts_systeme"],
                      dataClasses: [.publicData, .personal], capMicros: 100_000, deadlineSeconds: 300, maxSteps: 3, maxRetries: 1,
                      note: "reflex → approbation → voix système macOS ; audio en cache local"),
        ]
        var d: [String: AgentSpec] = [:]
        for s in all { d[s.id] = s }
        return d
    }()

    /// Moteur partagé de l'app : disque + journal BlackBox ; DenyAllCostGate et aucun exécuteur tant que la Phase 2 n'est pas branchée.
    public static let shared: AgentEngine = {
        let e = AgentEngine(store: FileAgentTaskStore(), costGate: DenyAllCostGate(), executor: nil)
        e.onTransition = { t, from, to, why in
            _ = BlackBox.record(["id": t.id, "tool": "agents_v2", "actor": t.agent, "effect": "lecture", "ok": true,
                                 "why": "\(from.rawValue) → \(to.rawValue) : \(why)", "result": "sha=\(t.contentSha.prefix(12))"])
        }
        return e
    }()

    /// Point de branchement Phase 2 (voir AgentContracts.swift).
    public static func installCostGate(_ g: AgentCostGate) { shared.setCostGate(g) }
}

public final class AgentEngine: @unchecked Sendable {
    let lock = NSLock()
    var tasks: [String: AgentTask]
    var active: Set<String> = []
    var pauseAsked: Set<String> = []
    let store: AgentTaskStore
    var costGate: AgentCostGate
    var executor: AgentToolExecutor?
    let specs: [String: AgentSpec]
    let now: () -> Date
    public var onTransition: ((AgentTask, AgentState, AgentState, String) -> Void)?

    public init(store: AgentTaskStore, costGate: AgentCostGate, executor: AgentToolExecutor?,
                specs: [String: AgentSpec] = AgentsV2.specs, now: @escaping () -> Date = { Date() }) {
        self.store = store; self.costGate = costGate; self.executor = executor; self.specs = specs; self.now = now
        self.tasks = store.load()
    }

    public func setCostGate(_ g: AgentCostGate) { lock.lock(); costGate = g; lock.unlock() }
    public func setExecutor(_ x: AgentToolExecutor?) { lock.lock(); executor = x; lock.unlock() }

    public func task(_ id: String) -> AgentTask? { lock.lock(); defer { lock.unlock() }; return tasks[id] }
    public func all() -> [AgentTask] { lock.lock(); defer { lock.unlock() }; return tasks.values.sorted { $0.createdAt > $1.createdAt } }

    // MARK: création

    @discardableResult
    public func create(agent: String, inputClasses: [AgentDataClass?], content: String,
                       steps: [(tool: String, arg: String, estimateMicros: Int64)]) throws -> AgentTask {
        guard let spec = specs[agent] else { throw AgentError.unknownAgent(agent) }
        let dc = AgentDataClass.strictest(inputClasses)
        guard spec.dataClasses.contains(dc) else { throw AgentError.dataClassOutOfScope(dc.rawValue) }
        guard steps.count <= spec.maxSteps else { throw AgentError.tooManySteps(steps.count) }
        for s in steps where !spec.tools.contains(s.tool) { throw AgentError.toolNotAllowed(s.tool) }
        let total = steps.reduce(Int64(0)) { $0 + max(0, $1.estimateMicros) }
        let cap = min(spec.capMicros, AgentsV2.maxCapMicros)
        guard total <= cap else { throw AgentError.capExceeded(total) }
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
        var list: [AgentStep] = []
        for (i, s) in steps.enumerated() {
            list.append(AgentStep(index: i, tool: s.tool, arg: s.arg, estimateMicros: max(0, s.estimateMicros),
                                  idempotencyKey: AgentsV2.idempotencyKey(task: id, index: i, tool: s.tool, arg: s.arg),
                                  status: .pending, attempts: 0, receipt: nil, output: nil))
        }
        let t = AgentTask(id: id, agent: agent, dataClass: dc, createdAt: now(), state: .draft, content: content,
                          approvalSha: nil, approvedAt: nil, steps: list, spentMicros: 0, reason: "", history: [])
        lock.lock(); tasks[id] = t; store.save(tasks); lock.unlock()
        return t
    }

    // MARK: transitions

    /// Transition explicite (sous verrou). « done » exige les reçus ; toute transition hors table est refusée.
    func moveLocked(_ id: String, to next: AgentState, why: String) throws {
        guard var t = tasks[id] else { throw AgentError.notFound }
        guard t.state.canMove(to: next) else { throw AgentError.forbiddenTransition(t.state.rawValue, next.rawValue) }
        if next == .done && !receiptsComplete(t) { throw AgentError.receiptMissing }
        let from = t.state
        t.state = next
        if next == .failed || next == .cancelled || next == .unknown || next == .awaitingApproval || next == .paused { t.reason = why }
        t.history.append(AgentTransition(from: from, to: next, at: now(), why: why))
        tasks[id] = t
        store.save(tasks)
        onTransition?(t, from, next, why)
    }

    public func move(_ id: String, to next: AgentState, why: String) throws {
        lock.lock(); defer { lock.unlock() }
        try moveLocked(id, to: next, why: why)
    }

    /// Au moins un reçu, et un reçu pour chaque étape à effet externe.
    func receiptsComplete(_ t: AgentTask) -> Bool {
        let approvalTools = specs[t.agent]?.approvalTools ?? []
        func has(_ s: AgentStep) -> Bool { s.status == .done && !((s.receipt ?? "").isEmpty) }
        guard t.steps.contains(where: has) else { return false }
        for s in t.steps where approvalTools.contains(s.tool) && !has(s) { return false }
        return true
    }

    func needsApproval(_ t: AgentTask) -> Bool {
        let approvalTools = specs[t.agent]?.approvalTools ?? []
        return t.steps.contains { approvalTools.contains($0.tool) && $0.status != .done }
    }

    // MARK: approbation

    /// Approuve le contenu dont l'empreinte a été MONTRÉE (shownSha) ; refusé si elle ne correspond plus au contenu.
    public func approve(_ id: String, shownSha: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard var t = tasks[id] else { throw AgentError.notFound }
        guard t.state == .awaitingApproval else { throw AgentError.forbiddenTransition(t.state.rawValue, "approve") }
        guard shownSha.lowercased() == t.contentSha else { throw AgentError.approvalMismatch }
        t.approvalSha = t.contentSha; t.approvedAt = now()
        tasks[id] = t; store.save(tasks)
    }

    /// Modifie le contenu : toute différence (même d'un octet) annule l'approbation et ramène à l'attente.
    public func updateContent(_ id: String, _ newContent: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard var t = tasks[id] else { throw AgentError.notFound }
        guard !t.state.isTerminal else { throw AgentError.forbiddenTransition(t.state.rawValue, "edit") }
        guard !active.contains(id) else { throw AgentError.busy }
        let changed = newContent != t.content
        t.content = newContent
        if changed { t.approvalSha = nil; t.approvedAt = nil }
        tasks[id] = t; store.save(tasks)
        // Pas de transition ici : la boucle d'exécution revérifie l'approbation juste avant chaque étape à effet
        // externe (running → awaiting_approval si l'empreinte ne correspond plus).
    }

    public func cancel(_ id: String, why: String = "annulé par Ahadi") throws {
        lock.lock(); defer { lock.unlock() }
        if active.contains(id) { pauseAsked.insert(id) }
        try moveLocked(id, to: .cancelled, why: why)
    }

    /// Pause coopérative : prise en compte avant l'étape suivante.
    public func pause(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard tasks[id] != nil else { throw AgentError.notFound }
        if active.contains(id) { pauseAsked.insert(id); return }
        try moveLocked(id, to: .paused, why: "pause demandée")
    }

    // MARK: exécution / reprise

    /// Lance ou reprend une tâche. Renvoie l'état final atteint par ce passage.
    @discardableResult
    public func run(_ id: String) throws -> AgentTask {
        lock.lock()
        guard let t0 = tasks[id] else { lock.unlock(); throw AgentError.notFound }
        guard let spec = specs[t0.agent] else { lock.unlock(); throw AgentError.unknownAgent(t0.agent) }
        guard !active.contains(id) else { lock.unlock(); throw AgentError.busy }
        guard let exec = executor else { lock.unlock(); throw AgentError.forbiddenTransition(t0.state.rawValue, "run (aucun exécuteur)") }
        do {
            switch t0.state {
            case .draft:
                if needsApproval(t0) {
                    try moveLocked(id, to: .awaitingApproval, why: "approbation requise avant tout effet externe")
                    let r = tasks[id]!; lock.unlock(); return r
                }
                try moveLocked(id, to: .running, why: "démarrage")
            case .awaitingApproval:
                guard t0.approvalValid || !needsApproval(t0) else { throw AgentError.approvalMismatch }   // le catch déverrouille
                try moveLocked(id, to: .running, why: "approuvé (sha \(t0.contentSha.prefix(12)))")
            case .paused, .unknown:
                try moveLocked(id, to: .running, why: "reprise après \(t0.state.rawValue) : rapprochement de l'état réel")
            case .running:
                break   // reprise après plantage : l'état disque dit running
            case .verifying:
                break
            case .done, .failed, .cancelled:
                throw AgentError.forbiddenTransition(t0.state.rawValue, "running")   // le catch déverrouille
            }
        } catch { lock.unlock(); throw error }
        active.insert(id); pauseAsked.remove(id)
        let gate = costGate
        lock.unlock()
        defer { lock.lock(); active.remove(id); pauseAsked.remove(id); lock.unlock() }

        let cap = min(spec.capMicros, AgentsV2.maxCapMicros)
        var i = 0
        while true {
            lock.lock()
            guard var t = tasks[id] else { lock.unlock(); throw AgentError.notFound }
            if t.state == .cancelled { lock.unlock(); return t }
            if t.state == .verifying { lock.unlock(); break }
            if pauseAsked.contains(id) { try? moveLocked(id, to: .paused, why: "pause demandée"); let r = tasks[id]!; lock.unlock(); return r }
            if now().timeIntervalSince(t.createdAt) > spec.deadlineSeconds {
                try? moveLocked(id, to: .failed, why: "échéance dépassée (\(Int(spec.deadlineSeconds)) s)"); let r = tasks[id]!; lock.unlock(); return r
            }
            guard let idx = t.steps.firstIndex(where: { $0.status != .done }) else {
                try? moveLocked(id, to: .verifying, why: "toutes les étapes soldées"); lock.unlock(); break
            }
            var step = t.steps[idx]
            guard spec.tools.contains(step.tool) else {
                try? moveLocked(id, to: .failed, why: "outil hors liste blanche : \(step.tool)"); let r = tasks[id]!; lock.unlock(); return r
            }
            // Rapprochement avant relance : une étape « started » a peut-être déjà produit son effet.
            if step.status == .started {
                if let real = exec.lookup(idempotencyKey: step.idempotencyKey), real.ok {
                    step.status = .done; step.receipt = real.receipt; step.output = real.output
                    t.steps[idx] = step; tasks[id] = t; store.save(tasks); lock.unlock(); continue
                }
                step.status = .pending
            }
            if spec.approvalTools.contains(step.tool) && !t.approvalValid {
                t.steps[idx] = step; tasks[id] = t
                try? moveLocked(id, to: .awaitingApproval, why: "approbation absente ou annulée (contenu modifié) pour \(step.tool)")
                let r = tasks[id]!; lock.unlock(); return r
            }
            if t.spentMicros + step.estimateMicros > cap {
                t.steps[idx] = step; tasks[id] = t
                try? moveLocked(id, to: .failed, why: "plafond de l'agent atteint (\(t.spentMicros) + \(step.estimateMicros) > \(cap) µ$)")
                let r = tasks[id]!; lock.unlock(); return r
            }
            i += 1
            if i > spec.maxSteps * (spec.maxRetries + 1) {
                try? moveLocked(id, to: .failed, why: "nombre maximal d'étapes atteint"); let r = tasks[id]!; lock.unlock(); return r
            }
            lock.unlock()
            // Réservation globale (Phase 2) hors verrou moteur.
            guard let resv = gate.reserve(taskId: id, profile: spec.profiles.first ?? .main, dataClass: t.dataClass, estimateMicros: step.estimateMicros) else {
                lock.lock(); try? moveLocked(id, to: .failed, why: "garde de coûts : réservation refusée"); let r = tasks[id]!; lock.unlock(); return r
            }
            // Marquer « started » AVANT l'appel (persisté) : base de la reprise idempotente.
            lock.lock()
            step.status = .started; step.attempts += 1
            if var tt = tasks[id] { tt.steps[idx] = step; tasks[id] = tt; store.save(tasks) }
            lock.unlock()
            let result: AgentToolResult
            do {
                result = try exec.execute(tool: step.tool, arg: step.arg, idempotencyKey: step.idempotencyKey)
            } catch {
                gate.settle(resv, actualMicros: nil)   // usage inconnu : la réservation reste comptée
                lock.lock()
                if var tt = tasks[id] { tt.spentMicros += step.estimateMicros; tasks[id] = tt; store.save(tasks) }
                try? moveLocked(id, to: .unknown, why: "interruption pendant \(step.tool) : effet non déterminé, rapprochement requis avant relance")
                let r = tasks[id]!; lock.unlock(); return r
            }
            gate.settle(resv, actualMicros: result.costMicros)
            lock.lock()
            guard var tt = tasks[id] else { lock.unlock(); throw AgentError.notFound }
            tt.spentMicros += result.costMicros ?? step.estimateMicros
            if result.ok {
                step.status = .done; step.receipt = result.receipt; step.output = String(result.output.prefix(4000))
                tt.steps[idx] = step; tasks[id] = tt; store.save(tasks); lock.unlock()
            } else if step.attempts <= spec.maxRetries {
                step.status = .pending; step.output = String(result.output.prefix(400))
                tt.steps[idx] = step; tasks[id] = tt; store.save(tasks); lock.unlock()
            } else {
                step.status = .failed; step.output = String(result.output.prefix(400))
                tt.steps[idx] = step; tasks[id] = tt; store.save(tasks)
                try? moveLocked(id, to: .failed, why: "\(step.tool) en échec après \(step.attempts) tentative(s)")
                let r = tasks[id]!; lock.unlock(); return r
            }
        }
        // Vérification : done seulement avec reçus.
        lock.lock(); defer { lock.unlock() }
        guard let t = tasks[id] else { throw AgentError.notFound }
        if receiptsComplete(t) { try moveLocked(id, to: .done, why: "reçus d'outil présents") }
        else { try moveLocked(id, to: .unknown, why: "aucun reçu d'outil : effet non prouvé, pas de « done »") }
        return tasks[id]!
    }

    /// Vue JSON pour l'interface (Phase 4 : panneau d'approbation).
    public static func summary(_ t: AgentTask) -> [String: Any] {
        var steps: [[String: Any]] = []
        for st in t.steps {
            var d: [String: Any] = [:]
            d["tool"] = st.tool; d["status"] = st.status.rawValue; d["attempts"] = st.attempts; d["receipt"] = st.receipt ?? ""
            steps.append(d)
        }
        var o: [String: Any] = [:]
        o["id"] = t.id; o["agent"] = t.agent; o["state"] = t.state.rawValue; o["dataClass"] = t.dataClass.rawValue
        o["content"] = t.content; o["contentSha256"] = t.contentSha; o["approved"] = t.approvalValid
        o["spentMicros"] = t.spentMicros; o["reason"] = t.reason; o["createdAt"] = ISO8601DateFormatter().string(from: t.createdAt)
        o["steps"] = steps
        return o
    }

    public static func specSummary(_ s: AgentSpec) -> [String: Any] {
        var d: [String: Any] = [:]
        d["id"] = s.id; d["label"] = s.label; d["note"] = s.note
        d["profiles"] = s.profiles.map { p in p.rawValue }
        d["tools"] = s.tools.sorted(); d["approvalTools"] = s.approvalTools.sorted()
        d["dataClasses"] = s.dataClasses.map { c in c.rawValue }.sorted()
        d["capMicros"] = s.capMicros; d["deadlineSeconds"] = Int(s.deadlineSeconds); d["maxSteps"] = s.maxSteps; d["maxRetries"] = s.maxRetries
        return d
    }
}

extension NovaApp {
    /// Routes Phase 3 (réglage `agents_v2`, défaut false → 403). Lecture, approbation (provenance UI exigée), annulation.
    func agentsV2Routes() {
        let s = server
        s.on("GET", "/api/agents2") { _, res in
            let specs: [[String: Any]] = AgentsV2.specs.keys.sorted().compactMap { k in AgentsV2.specs[k].map { AgentEngine.specSummary($0) } }
            guard AgentsV2.enabled else { res.json(["ok": true, "enabled": false, "agents": specs, "tasks": [Any]()]); return }
            res.json(["ok": true, "enabled": true, "agents": specs, "tasks": AgentsV2.shared.all().map { AgentEngine.summary($0) }])
        }
        s.on("POST", "/api/agents2/approve") { req, res in
            guard AgentsV2.enabled else { res.json(["ok": false, "code": "agents_v2_off", "error": "agents v2 désactivés (réglage agents_v2)"], status: 403); return }
            guard req.headers[SendQueue.headerName] == SendQueue.uiSecret else {
                res.json(["ok": false, "code": "provenance_invalide", "error": "approbation acceptée seulement depuis l'interface de Nova"], status: 403); return
            }
            let j = req.json
            let id = (j["id"] as? String) ?? "", sha = (j["sha256"] as? String) ?? ""
            do { try AgentsV2.shared.approve(id, shownSha: sha); res.json(["ok": true, "id": id, "sha256": sha]) }
            catch AgentError.approvalMismatch { res.json(["ok": false, "code": "modifie_depuis_apercu", "error": "le contenu a changé depuis l'aperçu — relis puis réapprouve"], status: 409) }
            catch { res.json(["ok": false, "error": "\(error)"], status: 409) }
        }
        s.on("POST", "/api/agents2/cancel") { req, res in
            guard AgentsV2.enabled else { res.json(["ok": false, "code": "agents_v2_off", "error": "agents v2 désactivés (réglage agents_v2)"], status: 403); return }
            let id = (req.json["id"] as? String) ?? ""
            do { try AgentsV2.shared.cancel(id); res.json(["ok": true, "id": id]) }
            catch { res.json(["ok": false, "error": "\(error)"], status: 409) }
        }
    }
}
