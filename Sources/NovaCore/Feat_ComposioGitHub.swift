// INT-C1 (23/10) — Producteur GitHub via Composio → Fil Direct (couture FD).
//
// DÉPLOYÉ le 23/10 (lot INT-C 2) dans Sources/NovaCore. Conception :
// conseil-design/INTC_conception.md (§3 mécanisme, §4 format) ; rapport :
// conseil-design/INTC1_impl_rapport.md.
//
// Rôle : sondeur DÉTERMINISTE (aucun cerveau). Toutes les `période` secondes
// (enregistrement every(...) dans App.swift, PATCHES.md-b), lit les événements
// des repos surveillés VIA Composio et fait naître les survivants par
// ProactiveFeed.append — la même porte que WebMail, les Dots et les briefs.
// Doctrine crédits optionnels : interrupteur fermé par défaut, clé absente ou
// service injoignable = producteur dormant ou en backoff, journalisé, jamais
// un crash, jamais un événement fabriqué, jamais un appel bloquant ailleurs.
//
// Alignements faits au déploiement (protocole d'ouverture §6) :
//  1. toolEvents ÉPINGLÉ au catalogue réel (pas 3, 23/10) :
//     GITHUB_LIST_REPOSITORY_EVENTS (« List repository events », version
//     20261014_00). Replis catalogués : GITHUB_LIST_EVENTS_FOR_THE_
//     AUTHENTICATED_USER / GITHUB_LIST_EVENTS_RECEIVED_BY_THE_AUTHENTICATED_
//     USER (bascule « flux utilisateur », conception §3.1).
//  2. Arguments CONFIRMÉS par le schéma d'entrée de l'outil : owner et repo
//     requis, per_page (défaut 30), page (défaut 1) — miroir de
//     GET /repos/{owner}/{repo}/events.
//  3. Appel HTTP aligné sur l'idiome JSON du moteur (Feat_Search.swift) :
//     URLRequest + jsonData/parseJSON (aides globales) + sémaphore borné,
//     tâche annulée au dépassement — aucun second client introduit.
//  RÉSIDU NOMMÉ : l'enveloppe exacte de la réponse d'exécution (data en
//  tableau direct ou data.items) se confirmera à la première exécution
//  réelle — impossible avant la connexion OAuth du compte GitHub (aucun
//  compte connecté relevé le 23/10). Les deux formes sont gérées ; toute
//  autre forme tombe en échec journalisé + backoff (§3.5), jamais en crash.

import Foundation

public enum ComposioGitHub {
    static let toolEvents = "GITHUB_LIST_REPOSITORY_EVENTS"   // épinglé au catalogue le 23/10 (pas 3)
    static let journal = Journal("composio_journal.jsonl")
    static let configFile = JSONFile("composio_config.json")
    static let stateFile = JSONFile("composio_github_state.json")
    static let lock = NSLock()
    static let keyRef = KeyRef(service: "nova-composio", accounts: ["$USER"], envVars: ["COMPOSIO_API_KEY"])
    static var dormantLogged = false   // poll vit sur UNE file (every) : pas de course

    // MARK: - Configuration (non secrète — la clé vit au Trousseau, §2.4)

    struct Cfg { let repos: [String]; let account: String; let userId: String }

    static func cfg() -> Cfg? {
        let c = configFile.read(default: [String: Any]())
        let repos = (c["repos"] as? [String]) ?? []
        let account = (c["account"] as? String) ?? ""
        let userId = (c["user_id"] as? String) ?? ""
        guard !repos.isEmpty, !account.isEmpty else { return nil }
        return Cfg(repos: repos, account: account, userId: userId)
    }

    static func dormant(_ why: String) {
        if dormantLogged { return }
        dormantLogged = true
        journal.add(["ts": nowISO(), "étape": "dormant", "raison": why])
    }

    // MARK: - Tir de sondage

    public static func poll(keys: KeyStore, settings: Settings) {
        guard settings.get("composio_enabled", false) else { dormant("interrupteur composio_enabled fermé"); return }
        guard let key = keys.value(keyRef), !key.isEmpty else { dormant("clé absente (Trousseau nova-composio / env COMPOSIO_API_KEY)"); return }
        guard let c = cfg() else { dormant("composio_config.json absent ou incomplet"); return }
        lock.lock(); defer { lock.unlock() }
        var st = stateFile.read(default: [String: Any]())
        let firstRun = (st["seeded_at"] as? String) == nil
        if firstRun { st["seeded_at"] = nowISO() }
        let seededAt = (st["seeded_at"] as? String) ?? nowISO()
        var repos = (st["repos"] as? [String: Any]) ?? [:]
        for repo in c.repos {
            var rs = (repos[repo] as? [String: Any]) ?? ["seen": [String](), "failures": 0, "next_ok": ""]
            if let nx = rs["next_ok"] as? String, !nx.isEmpty, nx > nowISO() { repos[repo] = rs; continue }   // backoff en cours
            switch fetchEvents(key: key, cfg: c, repo: repo) {
            case .failure(let code):
                let f = ((rs["failures"] as? Int) ?? 0) + 1
                rs["failures"] = f
                if f >= 3 {
                    let back = TimeInterval(4 * settings.get("composio_gh_period_s", 1800))
                    rs["next_ok"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(back))
                }
                journal.add(["ts": nowISO(), "étape": "lecture", "repo": repo, "code": code, "échecs": f])
            case .success(let events):
                rs["failures"] = 0; rs["next_ok"] = ""
                var seenList = (rs["seen"] as? [String]) ?? []
                let seenSet = Set(seenList)
                let fresh = events.filter { !seenSet.contains(idOf($0)) }
                for e in events { let i = idOf(e); if !seenSet.contains(i) { seenList.append(i) } }
                if seenList.count > 600 { seenList = Array(seenList.suffix(600)) }
                rs["seen"] = seenList
                if firstRun {
                    journal.add(["ts": nowISO(), "étape": "amorçage", "repo": repo, "vus": events.count])
                } else {
                    emit(fresh, repoFull: repo, seededAt: seededAt)
                }
            }
            repos[repo] = rs
        }
        st["repos"] = repos
        stateFile.write(st)
    }

    static func idOf(_ e: [String: Any]) -> String {
        // L'id d'événement GitHub est une chaîne dans l'API REST ; si
        // l'enveloppe Composio le sert en nombre, on le normalise — la
        // déduplication ne doit jamais dépendre de ce détail de forme.
        if let s = e["id"] as? String { return s }
        if let n = e["id"] as? Int { return String(n) }
        return ""
    }

    // MARK: - Mappage (vocabulaire fermé v1 — conception §3.4)

    struct Prod { var kind: String; var title: String; var text: String; var who: String; var ref: String; var commits: Int }

    static func lines(fait: String, tri: String, suite: String, lien: String) -> String {
        "Fait : \(fait)\nTri : \(tri)\nSuite : \(suite)\nLien : \(lien)"
    }

    static func map(_ e: [String: Any], repoFull: String) -> Prod? {
        let type = (e["type"] as? String) ?? ""
        let actor = ((e["actor"] as? [String: Any])?["login"] as? String) ?? ""
        let payload = (e["payload"] as? [String: Any]) ?? [:]
        let repoCourt = repoFull.split(separator: "/").last.map(String.init) ?? repoFull
        switch type {
        case "PushEvent":
            let refFull = (payload["ref"] as? String) ?? ""
            let branch = refFull.hasPrefix("refs/heads/") ? String(refFull.dropFirst("refs/heads/".count)) : refFull
            let commitsArr = (payload["commits"] as? [[String: Any]]) ?? []
            let n = (payload["size"] as? Int) ?? commitsArr.count
            let firstMsg = ((commitsArr.first?["message"] as? String) ?? "").split(separator: "\n").first.map(String.init) ?? ""
            let head = (payload["head"] as? String) ?? ""
            let tri = firstMsg.isEmpty
                ? "\(actor) a poussé \(n) commit(s) sur \(branch)."
                : "\(actor) a poussé \(n) commit(s) sur \(branch) : « \(firstMsg) »."
            return Prod(kind: "github.push",
                        title: "\(repoCourt) — push sur \(branch)",
                        text: lines(fait: "push sur \(branch)", tri: tri, suite: "rien",
                                    lien: head.isEmpty ? "" : "https://github.com/\(repoFull)/commit/\(head)"),
                        who: actor, ref: branch, commits: n)
        case "PullRequestEvent":
            let pr = (payload["pull_request"] as? [String: Any]) ?? [:]
            let num = (payload["number"] as? Int) ?? (pr["number"] as? Int) ?? 0
            let titre = (pr["title"] as? String) ?? ""
            let url = (pr["html_url"] as? String) ?? ""
            let action = (payload["action"] as? String) ?? ""
            switch action {
            case "opened", "reopened":
                return Prod(kind: "github.pr", title: "\(repoCourt) — PR #\(num) ouverte",
                            text: lines(fait: "PR #\(num) ouverte", tri: "Nouvelle PR de \(actor) : « \(titre) » — en attente de relecture.", suite: "rien", lien: url),
                            who: actor, ref: "", commits: 0)
            case "closed":
                if (pr["merged"] as? Bool) == true {
                    return Prod(kind: "github.pr", title: "\(repoCourt) — PR #\(num) fusionnée",
                                text: lines(fait: "PR #\(num) fusionnée", tri: "PR « \(titre) » fusionnée par \(actor).", suite: "rien", lien: url),
                                who: actor, ref: "", commits: 0)
                }
                return Prod(kind: "github.pr", title: "\(repoCourt) — PR #\(num) fermée",
                            text: lines(fait: "PR #\(num) fermée", tri: "PR « \(titre) » fermée sans fusion par \(actor).", suite: "rien", lien: url),
                            who: actor, ref: "", commits: 0)
            case "review_requested":
                let reviewer = ((payload["requested_reviewer"] as? [String: Any])?["login"] as? String) ?? ""
                return Prod(kind: "github.pr", title: "\(repoCourt) — relecture demandée sur la PR #\(num)",
                            text: lines(fait: "relecture demandée sur la PR #\(num)", tri: "\(actor) demande une relecture à \(reviewer) sur « \(titre) ».", suite: "github", lien: url),
                            who: actor, ref: "", commits: 0)
            default: return nil
            }
        case "IssuesEvent":
            let iss = (payload["issue"] as? [String: Any]) ?? [:]
            let num = (iss["number"] as? Int) ?? 0
            let titre = (iss["title"] as? String) ?? ""
            let url = (iss["html_url"] as? String) ?? ""
            switch (payload["action"] as? String) ?? "" {
            case "opened":
                return Prod(kind: "github.issue", title: "\(repoCourt) — issue #\(num) ouverte",
                            text: lines(fait: "issue #\(num) ouverte", tri: "Nouvelle issue de \(actor) : « \(titre) ».", suite: actor == "JeanCyrilleD" ? "rien" : "github", lien: url),
                            who: actor, ref: "", commits: 0)
            case "reopened":
                return Prod(kind: "github.issue", title: "\(repoCourt) — issue #\(num) rouverte",
                            text: lines(fait: "issue #\(num) rouverte", tri: "Issue « \(titre) » rouverte par \(actor).", suite: "rien", lien: url),
                            who: actor, ref: "", commits: 0)
            case "closed":
                return Prod(kind: "github.issue", title: "\(repoCourt) — issue #\(num) fermée",
                            text: lines(fait: "issue #\(num) fermée", tri: "Issue « \(titre) » fermée par \(actor).", suite: "rien", lien: url),
                            who: actor, ref: "", commits: 0)
            default: return nil
            }
        default: return nil
        }
    }

    // MARK: - Descente (ordre chronologique, agrégation push, plafond)

    static func emit(_ fresh: [[String: Any]], repoFull: String, seededAt: String) {
        var items: [Prod] = []
        for e in fresh.reversed() {   // GitHub sert du plus récent au plus ancien ; le fil se lit dans l'ordre d'arrivée
            guard let ca = e["created_at"] as? String, ca > seededAt else { continue }
            if let p = map(e, repoFull: repoFull) { items.append(p) }
        }
        var merged: [Prod] = []
        for p in items {
            if p.kind == "github.push", !merged.isEmpty, merged[merged.count - 1].kind == "github.push", merged[merged.count - 1].ref == p.ref {
                merged[merged.count - 1].commits += p.commits
                continue
            }
            merged.append(p)
        }
        for p in merged.suffix(5) {
            ProactiveFeed.append(kind: p.kind, box: "gh", title: p.title, text: p.text, urgent: false, who: p.who)
        }
        if !merged.isEmpty {
            journal.add(["ts": nowISO(), "étape": "descente", "repo": repoFull, "événements": min(merged.count, 5), "vus": fresh.count])
        }
    }

    // MARK: - Appel Composio (aligné — voir l'en-tête)

    enum FetchRes { case success([[String: Any]]); case failure(String) }

    static func fetchEvents(key: String, cfg: Cfg, repo: String) -> FetchRes {
        let parts = repo.split(separator: "/")
        guard parts.count == 2 else { return .failure("repo mal formé") }
        guard let url = URL(string: "https://backend.composio.dev/api/v3.1/tools/execute/\(toolEvents)") else {
            return .failure("URL invalide")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["connected_account_id": cfg.account, "user_id": cfg.userId,
                                   "arguments": ["owner": String(parts[0]), "repo": String(parts[1]), "per_page": 30]]
        req.httpBody = jsonData(body)
        var out: FetchRes = .failure("sans réponse")
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data = data, let obj = parseJSON(data) else {
                out = .failure("HTTP \(code)"); return
            }
            if let ok = obj["successful"] as? Bool, !ok {
                out = .failure("exécution refusée : \((obj["error"] as? String) ?? "erreur non précisée")"); return
            }
            if let arr = obj["data"] as? [[String: Any]] { out = .success(arr); return }
            if let d = obj["data"] as? [String: Any], let arr = d["items"] as? [[String: Any]] { out = .success(arr); return }
            out = .failure("forme de réponse inattendue")
        }
        task.resume()
        if sem.wait(timeout: .now() + 25) == .timedOut {
            task.cancel()
            return .failure("délai dépassé")
        }
        return out
    }
}
