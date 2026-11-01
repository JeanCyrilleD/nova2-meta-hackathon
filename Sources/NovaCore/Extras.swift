import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// TRACE-MIROIR (SPARK8-B2) : journal d'observabilité du miroir Direct, écrit par la route ci-dessous, lu par la batterie.
let directMirrorJournal = Journal("direct_mirror_journal.jsonl")

/// V10 — routes des onglets « outils » : chaque onglet de l'interface s'appuie sur une route réelle ici.
extension NovaApp {
    func extraRoutes() {
        mediaRoutes()
        blackBoxRoutes()
        packRoutes()
        vaultRoutes()
        vaultBiometricRoutes()   // PHASE 4 : clé du coffre derrière Touch ID au Trousseau (VaultBiometric.swift)
        ameRoutes()
        Livrables.register(on: server)   // NOVA2-DOC : production documentaire CAFU (/api/livrables/*)
        metaRoutes()               // META-MUSE (26/10) : /api/meta/status|image|segment (MetaCapabilities.swift)
        veilleRoutes()
        carteSahelRoutes()          // LOT J (28/10) : carte des signaux Sahel scorés (/api/veille/carte, Feat_CarteSahel)
        feedRoutes()   // BUILD-FEED-DIRECT vague 1 : GET /api/feed/units, POST /api/feed/read|dismiss (DirectFeed.swift)
        novaPlusRoutes()   // NovaPlus.swift
        visionPredictRoutes()   // Phase 7/8 : /api/temoin/vision, /api/predict/next (Temoin.swift)
        trustRoutes()              // VAGUE 1 : Feat_Trust.swift
        sovereignMemoryRoutes()    // VAGUE 1 : Feat_MemoireSouveraine.swift
        engagementsRoutes()        // VAGUE 1 : Feat_Engagements.swift
        pulseRoutes()              // VAGUE 1 : Feat_Pulse.swift
        voix2Routes()              // VAGUE 2 : Feat_Voix2.swift
        demoReplayRoutes()         // 01/11 : mode démo sans clé (DemoReplay.swift, demo/traces)
        resilienceRoutes()         // VAGUE 2 : Feat_Resilience.swift
        axRoutes()                 // VAGUE 3 : AXPilot.swift (Contrôle : état Accessibilité, test lecture seule, journal AX)
        voixAhadiRoutes()          // VAGUE 3 : Feat_Voix_Ahadi.swift (réponses dans la voix d'Ahadi)
        brouillonBoiteRoutes()     // 29/10 : Feat_Brouillons.swift (dépôt dans la boîte depuis le Fil direct)
        sfSymbolRoutes()           // 30/10 : vrais SF Symbols d'Apple servis à l'interface (Feat_SFSymbols.swift)
        agentBenchStart()          // 31/10 : banc agent — cerveaux en principal sur de vraies demandes en lecture seule (Feat_BancAgent.swift)
        autonomieRoutes()          // 25/10 : Feat_Autonomie.swift (brouillons prêts, fiche de la veille 20:30, « on me doit une réponse »)
        server.on("POST", "/api/notify/test") { _, res in   // 24/10 : essai du circuit de notification natif (Réglages)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
                NovaNotifier.send(source: "essai", title: "Nova — notification d'essai", body: "Le circuit fonctionne. « Voir » ouvre les Réglages de Nova.", target: ["module": "settings", "id": ""], sound: true, urgent: true, enabled: true, quiet: false)
            }
            let ok: [String: Any] = ["ok": true, "in_s": 8]
            res.json(ok)
        }
        // 28/10 (Ahadi) : une tâche de conversation terminée pendant qu'il est ailleurs
        // (autre écran, autre app) le prévient — notification macOS cliquable vers le fil.
        server.on("POST", "/api/notify/taskdone") { [self] req, res in
            let cid: String = String(((req.json["cid"] as? String) ?? "").prefix(40))
            let tache: String = String(((req.json["tache"] as? String) ?? "").prefix(140))
            let extrait: String = String(((req.json["extrait"] as? String) ?? "").prefix(220))
            NovaNotifier.send(source: "taskdone:" + cid, title: "Nova — tâche terminée",
                              body: (tache.isEmpty ? extrait : "« " + tache + " » — " + extrait),
                              target: ["module": "conversations", "id": cid],
                              enabled: settings.get("notify", true), quiet: briefs.inQuietHours())
            res.json(["ok": true])
        }
        // 28/10 (Ahadi) : les réactions emoji ont un SENS journalisé côté moteur
        // (utile / pas ça / pas clair…) — matière des leçons, pas juste un autocollant local.
        server.on("POST", "/api/feedback/reaction") { req, res in
            let emo: String = String(((req.json["emoji"] as? String) ?? "").prefix(8))
            let sens: String = String(((req.json["sens"] as? String) ?? "").prefix(24))
            let cid: String = String(((req.json["cid"] as? String) ?? "").prefix(40))
            if !emo.isEmpty {
                _ = BlackBox.record(["tool": "reaction", "actor": "Ahadi", "why": "réaction à une réponse de Nova", "ok": true, "effect": "lecture",
                                     "result": "emoji=\(emo) sens=\(sens) conv=\(cid)"])
            }
            res.json(["ok": true])
        }
        server.on("POST", "/api/credits/count") { req, res in   // 24/10 : comptage d'un appel fournisseur fait côté interface (Algolia : requête directe depuis la palette)
            let j: [String: Any] = req.json
            let prov: String = ((j["provider"] as? String) ?? "").lowercased()
            let st: Int = (j["status"] as? Int) ?? 200
            guard ["algolia"].contains(prov) else { let bad: [String: Any] = ["ok": false, "error": "fournisseur non suivi"]; res.json(bad, status: 400); return }
            if st >= 200 && st < 300 { Credits.count(prov) } else { Credits.providerFailed(prov, status: st, detail: "requête interface") }
            let ok: [String: Any] = ["ok": true]
            res.json(ok)
        }
        fundingsRoutes()           // V4 (24/10) : Fundings.swift (campagne de financement — /api/fundings, /api/fundings/event)
        zohoRoutes()               // V5-S (25/10) : Feat_Zoho.swift (lecture directe IMAP de la boîte campagne — /api/zoho/*)
        gmailRoutes()              // 25/10 : Feat_Gmail.swift (lecture directe IMAP de Gmail, lecture seule — /api/gmail/*)
        autotestRoutes()           // 25/10 : Feat_Autotest.swift (autotest de la nuit 03:30 — /api/autotest/run, /api/autotest/last)
        proactiviteStart()         // 26/10 : Feat_Proactivite.swift (Initiatives à intervalles irréguliers — /api/proactivite)
        preparationsRoutes()       // 27/10 : Feat_Preparations.swift (Anticipation — /api/preparations)
        graphRoutes()              // 27/10 : Feat_Graph.swift (Microsoft Graph lecture seule — /api/graph/*)
        auditRoutes()              // 27/10 : Feat_Audit.swift (Export d'audit conversations, lecture seule — /api/audit/conversations)
        _ = convs.finalizeStalePartials()   // 27/10 : refermer les réponses interrompues avant la fin (bulles « en cours… » fantômes)
        voixConversationRoutes()   // 27/10 : Feat_VoixConversation.swift (porte de relecture voix — /api/voix-conversation)
        ameViveRoutes()            // V5-P (25/10) : Relations /api/relations/*, Rêves /api/reves*, Boucle /api/boucle*, Archéologue /api/archeo, Deuil /api/projects/deuil/* (Feat_AmeDocs.swift)
        suggestionsRoutes()        // V5-U (25/10) : « Nova te propose » — /api/suggestions, /now, /feedback + créneaux 08:15 / 13:00 / 18:30 (dim. 10:00) (Feat_Suggestions.swift)
        podcastRoutes()            // 25/10 : Podcast hebdo réel — POST /api/podcast/make, GET /api/podcast/latest (Feat_Podcast.swift)
        eclatsDotsRoutes()         // V6 ÉCLATS (25/10) : retours /api/dots/feedback(+/delete), /api/dots/reorient (Feat_EclatsDots.swift)
        brvmAlertesRoutes(); journalSoirRoutes(); convArchiveRoutes()   // LOT3 (25/10) : /api/brvm/alertes|historique (Feat_BRVMAlertes), /api/journal-soir* (Feat_JournalSoir), /api/conversations/archive (Feat_ConvArchive)
        dossiersRoutes()            // LOT F (28/10) : suivi de dossiers pièces/échéances (/api/dossiers, Feat_Dossiers)
        reunionsRoutes()            // LOT H (28/10) : réunion -> CR -> engagements (/api/reunions/*, Feat_Reunions)
        v5oRoutes()                // V5-O (25/10) : Silence /api/silence (Feat_Silence.swift), Chronobiologie /api/chrono* (Feat_Chrono.swift), Rituels /api/rituels* (Feat_Daily.swift)
        evalRoutes()               // CHANTIER 2 (27/10) : Feat_Eval.swift (GET /api/eval, POST /api/eval/run borne)
        memoireTemporelleRoutes()  // CHANTIER 2 (27/10) : Feat_MemoireTemporelle.swift (GET /api/memoire-temporelle, POST /api/memoire-temporelle/fait)
        sousAgentsRoutes()         // CHANTIER 2 (27/10) : Feat_SousAgents.swift (POST /api/sous-agents/run borne, GET /api/sous-agents)
        agentsV2Routes()           // PHASE 3 (31/10) : AgentsV2.swift (GET /api/agents2, POST /api/agents2/approve|cancel) — réglage agents_v2, défaut false → 403
        mcpRoutes()                // CHANTIER 2 (27/10) : Feat_MCP.swift (GET /api/mcp, POST /api/mcp/list|call, liste blanche)
        let s = server
        let notes = JSONFile("notes.json")

        // Outils en lecture (jamais d'envoi, de suppression ni d'écriture) — utilisables directement depuis les onglets.
        // Instantané texte d'une boîte web (Outlook « ol », Gmail « gm ») envoyé par l'interface ; sert à mail_unread quand Mail.app ne répond pas.
        // SPARK6 (22/10) : relaie aussi les items structurés {de, objet, heure, apercu} déjà extraits par le pilote, plafonnés à 25.
        s.on("POST", "/api/webmail") { req, res in
            var mailItems: [WebMail.MailItem] = []
            if let raw = req.json["items"] as? [Any] {
                for e in raw.prefix(25) {
                    guard let d = e as? [String: Any] else { continue }
                    mailItems.append(WebMail.MailItem(de: (d["de"] as? String) ?? "", objet: (d["objet"] as? String) ?? "", heure: (d["heure"] as? String) ?? "", apercu: (d["apercu"] as? String) ?? ""))
                }
            }
            WebMail.put(id: (req.json["id"] as? String) ?? "", text: (req.json["text"] as? String) ?? "", items: mailItems)
            // 26/10 : forme du DOM Teams (longueurs, pas de contenu) → releves/diag/teams_dom.json, pour régler l'extracteur sans prendre l'écran.
            if let dg = req.json["diag"] as? [Any], !dg.isEmpty {
                let dir: String = NSHomeDirectory() + "/spark-local/Nova2/releves/diag"
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? jsonData(["ts": nowISO(), "items": dg]).write(to: URL(fileURLWithPath: dir + "/teams_dom.json"))
            }
            if let ti = req.json["titre"] as? String { MailCounts.setTitle((req.json["id"] as? String) ?? "", ti) }   // 24/10 : compteur de non-lus du titre du volet
            res.json(["ok": true])
        }
        s.on("GET", "/api/mail/counts") { _, res in res.json(MailCounts.snapshot()) }   // 24/10 : non-lus par service (Teams, Outlook, Gmail, + Zoho V5-S) pour l'Accueil
        s.on("POST", "/api/webchats") { req, res in WebMail.putChats((req.json["text"] as? String) ?? ""); res.json(["ok": true]) }
        s.on("POST", "/api/tool") { [self] req, res in
            let name = (req.json["name"] as? String) ?? "", arg = (req.json["arg"] as? String) ?? ""
            guard ["web_search", "web_fetch", "mail_unread", "mail_week", "teams_read", "calendar", "reminders", "read_file", "recall", "know", "bibliotheque", "system", "nova_self", "remember", "draft_reply", "transcribe", "notes", "contacts", "find", "clipboard", "today", "shortcut", "ui", "momo", "cafu_format_document", "cafu_format_email", "cafu_format_docx", "cafu_format_deck", "cafu_format_pdf", "cafu_format_table"].contains(name),
                  !(name == "momo" && !["", "list"].contains(arg.trimmingCharacters(in: .whitespaces).lowercased())),
                  !(name == "shortcut" && arg.trimmingCharacters(in: .whitespaces).lowercased() != "list"),
                  !(name == "ui" && !["windows", "screens"].contains(arg.trimmingCharacters(in: .whitespaces).lowercased())) else {
                res.json(["error": "outil inconnu ou non autorisé"], status: 400); return }
            let out = tools.run(name, arg, why: "Demande directe depuis l'interface", actor: "Toi")
            res.json(["name": name, "output": out])
        }

        // Veille : articles réels des flux RSS configurés
        s.on("GET", "/api/feed") { [self] _, res in
            var items: [[String: Any]] = []; var errs: [String] = []
            let g = DispatchGroup(); let lock = NSLock()
            for f in settings.get("feeds", [String]()) {
                g.enter()
                Thread.detachNewThread {
                    defer { g.leave() }
                    let (st, body) = Tools.get(f, timeout: 10)
                    guard st == 200, let d = body.data(using: .utf8) else { lock.lock(); errs.append("\(f) (HTTP \(st))"); lock.unlock(); return }
                    let p = RSSParser(); let x = XMLParser(data: d); x.delegate = p; x.parse()
                    let host = URL(string: f)?.host ?? f
                    lock.lock()
                    for it in p.items.prefix(12) { items.append(["title": it.0, "link": it.1, "date": it.2, "source": host]) }
                    lock.unlock()
                }
            }
            _ = g.wait(timeout: .now() + 14)
            res.json(["items": items, "errors": errs])
        }

        s.on("GET", "/api/ls") { req, res in
            var path = req.query["path"] ?? "~"; if path.hasPrefix("~") { path = NSHomeDirectory() + path.dropFirst() }
            let home = NSHomeDirectory()
            path = (URL(fileURLWithPath: path).standardized.resolvingSymlinksInPath().path)   // « .. » et liens symboliques résolus avant le contrôle
            let bad = ["/.ssh", "/.gnupg", "/library", "/.bionic-tools", "/.aws", "/.config", "/nova-finances"]
            guard (path == home || path.hasPrefix(home + "/")), !bad.contains(where: { path.lowercased().contains($0) }) else { res.json(["error": "dossier refusé (hors de ton espace personnel ou sensible)"]); return }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { res.json(["error": "dossier illisible ou inexistant"]); return }
            let items: [[String: Any]] = names.filter { !$0.hasPrefix(".") }.sorted().prefix(300).map { n in
                var isDir: ObjCBool = false; let full = path + "/" + n; FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
                let a = (try? FileManager.default.attributesOfItem(atPath: full)) ?? [:]
                return ["name": n, "dir": isDir.boolValue, "size": (a[.size] as? NSNumber)?.intValue ?? 0, "mtime": ((a[.modificationDate] as? Date).map { ISO8601DateFormatter().string(from: $0) }) ?? ""] }
            res.json(["path": path, "items": items])
        }
        // Connaissances : indexation locale + recherche
        s.on("GET", "/api/knowledge/status") { [self] _, res in
            res.json(["status": Knowledge.shared.status(), "roots": settings.get("knowledge_roots", Knowledge.defaultRoots)])
        }
        s.on("POST", "/api/knowledge/roots") { [self] req, res in
            let r = (req.json["roots"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(12)
            settings.set(["knowledge_roots": Array(r)]); res.json(["ok": true, "roots": Array(r)])
        }
        s.on("POST", "/api/knowledge/scan") { [self] _, res in
            Knowledge.shared.scan(roots: settings.get("knowledge_roots", Knowledge.defaultRoots)); res.json(["ok": true])
        }
        s.on("GET", "/api/knowledge/recent") { [self] _, res in
            // Lecture seule : documents des dossiers de connaissance modifiés depuis 7 jours (cache 10 min). Rien n'est envoyé ni modifié.
            let now = Date()
            if let c = KnowledgeRecentCache.get(now) { res.json(["items": resumesMerge(c)]); return }   // + champ « resume » (Feat_Resumes.swift)
            let since = now.addingTimeInterval(-7 * 86400)
            var out: [[String: Any]] = []
            let iso = ISO8601DateFormatter()
            let roots = (settings.get("knowledge_roots", Knowledge.defaultRoots) as [String])
            for r in roots {
                let base = URL(fileURLWithPath: (r as NSString).expandingTildeInPath)
                guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
                for case let u as URL in en {
                    if out.count >= 60 { break }
                    let p = u.path
                    guard Knowledge.allowedDir(p), Knowledge.allowed(p), Knowledge.exts.contains(u.pathExtension.lowercased()) else { continue }
                    guard let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d > since else { continue }
                    out.append(["name": u.lastPathComponent, "path": p, "date": iso.string(from: d)])
                }
            }
            out.sort { ($0["date"] as? String ?? "") > ($1["date"] as? String ?? "") }
            KnowledgeRecentCache.set(out, now)
            res.json(["items": resumesMerge(out)]) }
        resumesDocsStart()   // file de fond des résumés (Feat_Resumes.swift) : un fil, 1 doc / 20 s max, jamais pendant une conversation
        s.on("GET", "/api/knowledge/search") { req, res in res.json(["items": Knowledge.shared.search(req.query["q"] ?? "", limit: 8)]) }
        s.on("GET", "/api/system") { _, res in res.json(SystemInfo.snapshot()) }
        s.on("GET", "/api/engines") { [self] _, res in
            res.json(["items": router.engines(force: true).map { ["name": $0.name, "base": $0.base, "models": $0.models] as [String: Any] }, "preferred": settings.get("local_model", "")])
        }
        // Notes
        s.on("GET", "/api/notes") { _, res in res.json(["items": notes.read(default: [[String: Any]]())]) }
        // TRACE-MIROIR (SPARK8-B2) : le web y dépose une ligne par point de décision du miroir Direct (preuve par construction).
        s.on("POST", "/api/direct-mirror/log") { req, res in
            let feed = String((((req.json["feed"] as? String) ?? "").prefix(64)))
            let conv = String((((req.json["conv"] as? String) ?? "").prefix(64)))
            let cible = String((((req.json["cible"] as? String) ?? "").prefix(64)))
            let motif = String((((req.json["motif"] as? String) ?? "").prefix(32)))
            let detail = String((((req.json["detail"] as? String) ?? "").prefix(120)))
            directMirrorJournal.add(["feed": feed, "conv": conv, "cible": cible, "motif": motif, "detail": detail])
            res.json(["ok": true])
        }
        // P1-INSTR (23/10) : première peinture d'un écran, déposée par le web (shell.js, navigate) — ligne BlackBox « first_paint » (M1/M4), même patron que la trace-miroir ci-dessus.
        s.on("POST", "/api/perf/first-paint") { req, res in
            let ecran = String(((req.json["ecran"] as? String) ?? "?").prefix(32))
            let deltaBrut = (req.json["delta_ms"] as? Int) ?? -1
            let delta = (deltaBrut >= 0 && deltaBrut <= 300000) ? deltaBrut : -2   // hors plage = mesure invalide, jamais un delta absurde
            _ = BlackBox.record(["tool": "first_paint", "actor": "Nova", "why": "première peinture de l'écran \(ecran) (M1/M4)", "ok": true, "effect": "lecture", "result": "ecran=\(ecran) delta_ms=\(delta)"])
            res.json(["ok": true])
        }
        s.on("POST", "/api/notes/save") { req, res in
            var l = notes.read(default: [[String: Any]]())
            let id = (req.json["id"] as? String) ?? String(UUID().uuidString.prefix(8)).lowercased()
            let n: [String: Any] = ["id": id, "title": (req.json["title"] as? String) ?? "", "body": (req.json["body"] as? String) ?? "", "updated": nowISO(),
                                  "kind": (req.json["kind"] as? String) ?? "note", "done": (req.json["done"] as? Bool) ?? false]
            if let i = l.firstIndex(where: { ($0["id"] as? String) == id }) { l[i] = n } else { l.insert(n, at: 0) }
            notes.write(l); res.json(["item": n])
        }
        s.on("POST", "/api/notes/remove") { req, res in
            let id = (req.json["id"] as? String) ?? ""
            notes.write(notes.read(default: [[String: Any]]()).filter { ($0["id"] as? String) != id }); res.json(["ok": true])
        }

    }
}

final class PodParser: NSObject, XMLParserDelegate {
    var eps: [[String: String]] = []; var channelTitle = ""
    var cur = "", title = "", url = "", date = "", dur = "", inItem = false
    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        cur = ""; if e == "item" { inItem = true; title = ""; url = ""; date = ""; dur = "" }
        if e == "enclosure", inItem, let u = attributes["url"] { url = u }
    }
    func parser(_ p: XMLParser, foundCharacters s: String) { cur += s }
    func parser(_ p: XMLParser, foundCDATA b: Data) { cur += String(decoding: b, as: UTF8.self) }
    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem { if e == "title" { title = t } else if e == "pubDate" { date = t } else if e == "itunes:duration" { dur = t } }
        else if e == "title", channelTitle.isEmpty { channelTitle = t }
        if e == "item" { inItem = false; if !url.isEmpty { eps.append(["title": title, "url": url, "date": date, "duration": dur]) } }
    }
}

extension NovaApp {
    func mediaRoutes() {
        let s = server
        func publicHost(_ u: URL) -> Bool { guard let h = u.host, u.scheme == "https" else { return false }
            return !(["localhost", "127.0.0.1", "0.0.0.0"].contains(h) || h.hasPrefix("192.168.") || h.hasPrefix("10.") || h.hasPrefix("172.16.") || h.hasPrefix("169.254.") || h.hasSuffix(".local")) }
        s.on("GET", "/api/podcast/search") { req, res in
            // D-R11 : la source historique (iTunes Search) ne renvoie plus feedUrl — vérifié en
            // direct le 21/10/2026 : 12 résultats pour « France Culture », 0 champ feedUrl, donc
            // l'ancien compactMap jetait 100 % des résultats et l'annuaire paraissait vide.
            // Source remplacée par l'annuaire fyyd (API publique sans clé), qui expose xmlURL
            // (le flux RSS). Contrat web inchangé : {items:[{name, artist, feed, art}]}.
            let q = (req.query["q"] ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let (st, body) = Tools.get("https://api.fyyd.de/0.2/search/podcast/?title=" + q, timeout: 10)
            guard st == 200, let o = parseJSON(Data(body.utf8)), let arr = o["data"] as? [[String: Any]] else { res.json(["error": "recherche indisponible (HTTP \(st))", "items": [] as [Any]]); return }
            let items: [[String: Any]] = arr.compactMap { r -> [String: Any]? in
                guard let f = r["xmlURL"] as? String, !f.isEmpty, let n = r["title"] as? String, !n.isEmpty else { return nil }
                return ["name": n, "artist": (r["author"] as? String) ?? "", "feed": f, "art": (r["imgURL"] as? String) ?? ""]
            }
            // Honnêteté : des résultats amont existent mais aucun n'a de flux exploitable →
            // échec NOMMÉ, jamais un faux « aucun podcast trouvé ».
            if !arr.isEmpty && items.isEmpty { res.json(["error": "annuaire joignable mais aucun flux RSS exploitable dans ses résultats", "items": [] as [Any]]); return }
            res.json(["items": Array(items.prefix(12))])
        }
        s.on("GET", "/api/podcast/episodes") { req, res in
            guard let f = req.query["feed"], let u = URL(string: f), publicHost(u) else { res.json(["error": "flux refusé"], status: 400); return }
            let (st, body) = Tools.get(f, timeout: 12)
            guard st == 200, let d = body.data(using: .utf8) else { res.json(["error": "flux illisible (HTTP \(st))", "items": [] as [Any]]); return }
            let p = PodParser(); let x = XMLParser(data: d); x.delegate = p; x.parse()
            res.json(["title": p.channelTitle, "items": Array(p.eps.prefix(25))])
        }
    }
}

extension NovaApp {
    /// Boîte noire, reçus signés, Permis d'agir.
    func blackBoxRoutes() {
        let s = server
        s.on("GET", "/api/blackbox") { _, res in res.json(["items": Array(BlackBox.tail(200).reversed()), "verify": BlackBox.verify()]) }
        s.on("GET", "/api/blackbox/verify") { _, res in res.json(BlackBox.verify()) }
        s.on("GET", "/api/blackbox/receipt") { req, res in
            if let r = BlackBox.receipt(forAction: req.query["id"] ?? "") { res.json(r) } else { res.json(["error": "Reçu introuvable."], status: 404) }
        }
        s.on("GET", "/api/permits") { _, res in res.json(["items": Permits.list()]) }
        s.on("POST", "/api/permits") { req, res in
            if let r = Permits.add((req.json["text"] as? String) ?? "") { res.json(["ok": true, "rule": r]) }
            else { res.json(["ok": false, "error": "Je n'ai pas compris cette règle. Exemples : « pas plus de 10 actions par heure », « jamais de shell », « ne touche jamais à ~/Documents/Contrats »."], status: 400) }
        }
        s.on("POST", "/api/permits/toggle") { req, res in Permits.toggle((req.json["id"] as? String) ?? "", (req.json["on"] as? Bool) ?? true); res.json(["ok": true]) }
        s.on("POST", "/api/permits/remove") { req, res in Permits.remove((req.json["id"] as? String) ?? ""); res.json(["ok": true]) }
    }
}


/// Cache de la veille documentaire (10 minutes, protégé par verrou).
enum KnowledgeRecentCache {
    static let lock = NSLock()
    nonisolated(unsafe) static var items: [[String: Any]] = []   // PHASE 1 (relu, protégé) : sous lock (get/set de KnowledgeRecentCache)
    nonisolated(unsafe) static var at = Date.distantPast   // PHASE 1 (relu, protégé) : sous lock (get/set)
    static func get(_ now: Date) -> [[String: Any]]? { lock.lock(); defer { lock.unlock() }; return now.timeIntervalSince(at) < 600 ? items : nil }
    static func set(_ v: [[String: Any]], _ now: Date) { lock.lock(); items = v; at = now; lock.unlock() }
}
