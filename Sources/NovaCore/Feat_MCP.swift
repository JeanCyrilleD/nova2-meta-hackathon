import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// CHANTIER 2 (27/10) — (d) CLIENT MCP LISTE BLANCHE.
// Client MCP minimal (JSON-RPC tools/list + tools/call) pour serveurs declares par Ahadi dans le
// reglage mcp_serveurs : [{nom, commande|url, outils_autorises:[...], plafond?}]. Plafond d'appels
// par session (processus), journal de chaque appel (mcp_journal.jsonl). AUCUN serveur actif par
// defaut : reglage vide = desactive proprement. Demo locale : dormant/mcp-demo/ (donnees fictives).
// Routes : GET /api/mcp · POST /api/mcp/list {serveur} · POST /api/mcp/call {serveur, outil, arguments}.

public enum MCPClient {
    public static let settingKey = "mcp_serveurs"
    public static let defaultSessionCap = 20
    public static let journal = Journal("mcp_journal.jsonl")
    static let capLock = NSLock()
    nonisolated(unsafe) static var sessionCounts: [String: Int] = [:]

    public struct Server: Equatable {
        public let nom: String; public let commande: String; public let url: String
        public let outilsAutorises: [String]; public let plafond: Int
    }

    /// Lecture fermee du reglage : entrees invalides ignorees, plafond borne 1...100.
    public static func parseServers(_ raw: Any?) -> [Server] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { d -> Server? in
            let nom = ((d["nom"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nom.isEmpty else { return nil }
            let cmd = ((d["commande"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let url = ((d["url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty || !url.isEmpty else { return nil }
            let tools = (d["outils_autorises"] as? [String]) ?? []
            let plafond = max(1, min(100, (d["plafond"] as? Int) ?? defaultSessionCap))
            return Server(nom: nom, commande: cmd, url: url, outilsAutorises: tools, plafond: plafond)
        }
    }

    public static func isToolAllowed(_ server: Server, _ tool: String) -> Bool {
        !tool.isEmpty && server.outilsAutorises.contains(tool)
    }

    public static func request(id: Int, method: String, params: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    }

    /// Consomme une unite du plafond de session ; false = plafond atteint.
    public static func consumeQuota(server: Server) -> Bool {
        capLock.lock(); defer { capLock.unlock() }
        let n = (sessionCounts[server.nom] ?? 0) + 1
        guard n <= server.plafond else { return false }
        sessionCounts[server.nom] = n; return true
    }
    public static func sessionCount(_ nom: String) -> Int { capLock.lock(); defer { capLock.unlock() }; return sessionCounts[nom] ?? 0 }
    public static func resetSessionCounts() { capLock.lock(); sessionCounts = [:]; capLock.unlock() }

    static func httpCall(url: String, payload: [String: Any], timeout: TimeInterval = 15) -> [String: Any] {
        guard let u = URL(string: url) else { return ["error": ["message": "URL invalide"]] }
        var req = URLRequest(url: u); req.httpMethod = "POST"; req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData(payload)
        var out: [String: Any] = ["error": ["message": "pas de reponse"]]
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, err in
            defer { sem.signal() }
            if let err = err { out = ["error": ["message": shortError(err.localizedDescription, 160)]]; return }
            if let data = data, let parsed = parseJSON(data) { out = parsed }
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return out
    }

    /// Transport stdio : une ligne JSON-RPC sur stdin, une ligne JSON sur stdout (serveur local).
    /// WP5 (A) : la commande d'un serveur stdio doit désigner un exécutable de CHEMIN ABSOLU existant, jamais un shell ni un
    /// interpréteur en ligne (sh -c, python -c…) : sinon refus. nil = acceptée.
    public static func stdioRefusal(_ commande: String) -> String? {
        let parts = commande.split(separator: " ").map(String.init)
        guard let exe = parts.first, !exe.isEmpty else { return "commande vide" }
        guard exe.hasPrefix("/") else { return "exécutable sans chemin absolu (\(exe)) : chemin fixe exigé" }
        let name = (exe as NSString).lastPathComponent.lowercased()
        if ["sh", "bash", "zsh", "dash", "ksh", "fish", "env", "osascript", "xargs", "sudo"].contains(name) { return "shell ou enveloppe (\(name)) refusé comme serveur MCP" }
        let inline: Set<String> = ["-c", "-e", "--eval", "-E", "--command"]
        if parts.dropFirst().contains(where: { inline.contains($0) }) { return "code en ligne (-c/-e) refusé" }
        guard FileManager.default.isExecutableFile(atPath: exe) else { return "exécutable introuvable : \(exe)" }
        return nil
    }
    static func stdioCall(commande: String, payload: [String: Any], timeout: TimeInterval = 15) -> [String: Any] {
        if let why = stdioRefusal(commande) { return ["error": ["message": "serveur MCP refusé : " + why]] }
        let parts = commande.split(separator: " ").map(String.init)
        guard let exe = parts.first else { return ["error": ["message": "commande vide"]] }
        let line = jsonString(payload) + "\n"
        let r: BoundedResult = BoundedProcess.run(exe, Array(parts.dropFirst()), timeout: timeout, maxOutput: 2 * 1024 * 1024, stdin: Data(line.utf8))
        let code: Int32 = r.code; let stdout: String = r.out
        guard code == 0 else { return ["error": ["message": "serveur MCP local en echec (code \(code))" + (r.err.isEmpty ? "" : " : " + shortError(BoundedProcess.sanitize(r.err), 200))]] }
        for l in stdout.split(separator: "\n") {
            if let parsed = parseJSON(Data(l.utf8)) { return parsed }
        }
        return ["error": ["message": "reponse MCP illisible"]]
    }

    static func dispatch(server: Server, method: String, params: [String: Any]) -> [String: Any] {
        let payload = request(id: 1, method: method, params: params)
        return server.url.isEmpty ? stdioCall(commande: server.commande, payload: payload) : httpCall(url: server.url, payload: payload)
    }

    public static func listTools(server: Server) -> [String: Any] {
        guard consumeQuota(server: server) else {
            journal.add(["serveur": server.nom, "action": "tools/list", "ok": false, "motif": "plafond_session"])
            return ["ok": false, "error": "plafond d'appels de session atteint pour \(server.nom)"]
        }
        let r = dispatch(server: server, method: "tools/list", params: [:])
        let tools = ((r["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let names = tools.compactMap { $0["name"] as? String }
        journal.add(["serveur": server.nom, "action": "tools/list", "ok": r["error"] == nil, "outils": names])
        return ["ok": r["error"] == nil, "serveur": server.nom, "outils": names, "brut": r]
    }

    public static func callTool(server: Server, tool: String, arguments: [String: Any]) -> [String: Any] {
        guard isToolAllowed(server, tool) else {
            journal.add(["serveur": server.nom, "action": "tools/call", "outil": tool, "ok": false, "motif": "outil_non_autorise"])
            return ["ok": false, "error": "outil « \(tool) » non autorise pour le serveur \(server.nom) (liste blanche)"]
        }
        guard consumeQuota(server: server) else {
            journal.add(["serveur": server.nom, "action": "tools/call", "outil": tool, "ok": false, "motif": "plafond_session"])
            return ["ok": false, "error": "plafond d'appels de session atteint pour \(server.nom)"]
        }
        let r = dispatch(server: server, method: "tools/call", params: ["name": tool, "arguments": arguments])
        journal.add(["serveur": server.nom, "action": "tools/call", "outil": tool, "ok": r["error"] == nil])
        return ["ok": r["error"] == nil, "serveur": server.nom, "outil": tool, "resultat": r["result"] as Any? ?? NSNull(), "brut": r]
    }
}

extension NovaApp {
    func mcpRoutes() {
        let s = server; let st = settings
        func servers() -> [MCPClient.Server] { MCPClient.parseServers(st.all()[MCPClient.settingKey]) }
        s.on("GET", "/api/mcp") { _, res in
            let list = servers()
            res.json(["actif": !list.isEmpty,
                      "serveurs": list.map { ["nom": $0.nom, "transport": $0.url.isEmpty ? "stdio" : "http", "outils_autorises": $0.outilsAutorises, "plafond": $0.plafond, "appels_session": MCPClient.sessionCount($0.nom)] as [String: Any] },
                      "journal": Array(MCPClient.journal.tail(50).reversed())])
        }
        s.on("POST", "/api/mcp/list") { req, res in
            let nom = (req.json["serveur"] as? String) ?? ""
            guard let srv = servers().first(where: { $0.nom == nom }) else {
                res.json(["ok": false, "error": servers().isEmpty ? "aucun serveur MCP declare (reglage mcp_serveurs vide) : MCP desactive" : "serveur MCP inconnu : \(nom)"], status: 404); return
            }
            DispatchQueue.global(qos: .utility).async { res.json(MCPClient.listTools(server: srv)) }
        }
        s.on("POST", "/api/mcp/call") { req, res in
            let nom = (req.json["serveur"] as? String) ?? ""
            let tool = (req.json["outil"] as? String) ?? ""
            let args = (req.json["arguments"] as? [String: Any]) ?? [:]
            guard let srv = servers().first(where: { $0.nom == nom }) else {
                res.json(["ok": false, "error": servers().isEmpty ? "aucun serveur MCP declare (reglage mcp_serveurs vide) : MCP desactive" : "serveur MCP inconnu : \(nom)"], status: 404); return
            }
            DispatchQueue.global(qos: .utility).async { res.json(MCPClient.callTool(server: srv, tool: tool, arguments: args)) }
        }
    }
}
