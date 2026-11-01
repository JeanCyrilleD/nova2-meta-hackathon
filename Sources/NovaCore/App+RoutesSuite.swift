import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import ApplicationServices
#endif
import NovaFoundation

/* DÉCOUPAGE App.swift (29/10, engagement de découpage honoré) : routes de la suite (forge, journal, outils).
   Méthode extraite telle quelle de App.swift — extension du même type NovaApp, même module :
   ZÉRO changement de comportement. Recette : swift build + swift test + verify.sh verts. */

extension NovaApp {
    func routesSuite(_ s: HTTPServer) {
        s.on("POST", "/api/confirm") { req, res in let okFlag = req.json["ok"] as? Bool ?? false; Amplitude.track(okFlag ? "approval_gate_approved" : "approval_gate_rejected"); res.json(["message": Tools.decide(id: req.json["id"] as? String ?? "", ok: okFlag, freeMinutes: req.json["free_minutes"] as? Int ?? 0, workspace: req.json["espace"] as? String)]) }   // WP5 : fenêtre et espace d'ingénierie liés au run de la demande   // AMPLITUDE (CRÉDITS 23/10) : verdict du gate — booléen seul
        s.on("GET", "/api/conversations") { [self] _, res in res.json(["items": convs.list()]) }
        // 26/10 : l'interface signale la conversation ouverte — les directs y arrivent (Feat_DirectActif.swift).
        // 29/10 (Claude) : témoin de démarrage de l'interface → releves/diag/ui_boot.txt (vérifié après chaque mise à jour).
        s.on("POST", "/api/ui/booted") { _, res in
            let dir: String = NSHomeDirectory() + "/spark-local/Nova2/releves/diag"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? ("UI OK " + nowISO() + "\n").write(toFile: dir + "/ui_boot.txt", atomically: true, encoding: .utf8)
            res.json(["ok": true])
        }
        // 29/10 (Claude) : trace des pauses de volets (prise / remise de main) → releves/diag/ui_events.txt
        s.on("POST", "/api/ui/trace") { req, res in
            let line: String = nowISO() + " " + ((req.json["ev"] as? String) ?? "") + " " + ((req.json["pid"] as? String) ?? "") + " " + ((req.json["why"] as? String) ?? "") + "\n"
            let path: String = NSHomeDirectory() + "/spark-local/Nova2/releves/diag/ui_events.txt"
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
            else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
            res.json(["ok": true])
        }
        s.on("POST", "/api/ui/conv-active") { req, res in DirectActif.setActive((req.json["cid"] as? String) ?? ""); res.json(["ok": true]) }
        // Télé en ligne (IPTV) : listes publiques iptv-org (GitHub) par pays ou par langue ; on les lit à la demande, rien n'est stocké.
        s.on("GET", "/api/tv/channels") { req, res in
            let key = (req.query["country"] ?? "bf").lowercased()
            let isCat = TVCatalog.isCatalogKey(key)   // NOVA2-FIX (vague 3) : clés du catalogue TV intégré (afrique, monde, infos, sport, musique, jeunesse, tout)
            if !isCat { guard key.range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil else { res.json(["error": "pays invalide"], status: 400); return } }
            let path = key == "xxx" ? "categories/xxx" : key == "fra" || key == "eng" || key == "por" || key == "ara" ? "languages/\(key)" : "countries/\(key)"
            var r = URLRequest(url: URL(string: "https://iptv-org.github.io/iptv/\(path).m3u")!); r.setValue("Nova/1.0", forHTTPHeaderField: "User-Agent")
            let (st, d) = isCat ? (200, Data()) : syncGet(r, timeout: 15)   // NOVA2-FIX (vague 3) : catalogue = aucun appel GitHub, items fournis par TVCatalog plus bas
            guard st == 200, let txt = String(data: d, encoding: .utf8) else {
                _ = BlackBox.record([
                    "tool": "tv_channels", "actor": "Nova",
                    "why": "liste TV : liste de chaînes injoignable",
                    "ok": false, "effect": "lecture",
                    "result": "HTTP \(st)"
                ])
                res.json(["error": "Liste de chaînes injoignable (HTTP \(st))", "items": [Any]()], status: 502); return
            }
            var items: [[String: Any]] = []; var meta: [String: String]? = nil
            func attr(_ l: String, _ k: String) -> String { guard let r = l.range(of: k + "=\"[^\"]*\"", options: .regularExpression) else { return "" }; return String(l[r].dropFirst(k.count + 2).dropLast()) }
            for raw in txt.split(whereSeparator: \.isNewline) {
                let l = raw.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("#EXTINF") { meta = ["name": l.split(separator: ",", maxSplits: 1).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "", "logo": attr(l, "tvg-logo"), "group": attr(l, "group-title")] }
                else if l.hasPrefix("http"), let m = meta { items.append(["name": m["name"] ?? "", "logo": m["logo"] ?? "", "group": m["group"] ?? "", "url": l]); meta = nil }
            }
            if key == "bf" {   // Favoris Burkina épinglés (liens GitHub iptv-org vérifiés), toujours en tête
                let pins: [(String, String)] = [("RTB (Télévision nationale)", "https://edge12.vedge.infomaniak.com/livecast/ik:rtblive1_8/manifest.m3u8"), ("RTB 3", "https://edge13.vedge.infomaniak.com/livecast/ik:rtb3-1/manifest.m3u8"), ("Savane TV", "https://savane24.tv:5443/LiveApp/streams/Y4fyif69Q0ll6MeH2190896734859843.m3u8"), ("Filinfo TV", "https://d2iqjnqfr8pv3b.cloudfront.net/out/v1/d09d2fc718404cd8bccd3eba2444dd70/index.m3u8"), ("Canal 3", "https://cs2.push2stream.com/CANAL3BENIN/playlist.m3u8")]   // NOVA2-FIX (vague 2) : Impact TV retirée — flux prouvé mort (HTTP 404 aux tests du 20/10/2026, deux sessions). Depuis SPEC TV LISTE D'ABORD (21/10), les épingles sont servies SANS test : leur santé se lit au badge de la liste (route /api/tv/check) et une chaîne morte reste listée et lançable.
                for p in pins.reversed() { items.removeAll { ($0["url"] as? String) == p.1 }; items.insert(["name": p.0, "logo": "", "group": "Burkina", "url": p.1], at: 0) }
            }
            if isCat { items = TVCatalog.items(forKey: key) }   // NOVA2-FIX (vague 3) : catalogue intégré (iptv-org, vérifié le 20/10/2026)
            else { for p in TVCatalog.pins(forCountry: key).reversed() { items.removeAll { ($0["url"] as? String) == (p["url"] as? String) }; items.insert(p, at: 0) } }
            let qf = (req.query["q"] ?? "").trimmingCharacters(in: .whitespaces)
            if !qf.isEmpty, let rx = try? NSRegularExpression(pattern: String(qf.prefix(200)), options: .caseInsensitive) {
                items = items.filter { o in let n = ((o["name"] as? String) ?? "") + " " + ((o["group"] as? String) ?? ""); return rx.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil }
            }
            // SPEC TV LISTE D'ABORD (21/10) : la liste est une DONNÉE, elle se sert sans tester.
            // L'ancien test groupé (80–120 candidats × manifeste+variante+segment, attente de 24 s)
            // dépassait le délai web de 20 s et ne cachait jamais un échec total (rien n'était écrit
            // si aucune chaîne ne survivait) : l'écran restait sur « Test des flux… » à chaque
            // ouverture. La santé devient unitaire et paresseuse : GET /api/tv/check?u= plus bas.
            let ck = key + "|" + qf
            let srcLabel = isCat ? "Catalogue Nova TV (iptv-org)" : "iptv-org (GitHub)"
            Self.tvCacheLock.lock(); let tvHit: (Date, [[String: Any]])? = Self.tvCache[ck]; Self.tvCacheLock.unlock()   // 31/10 (voix/mémoire/Live)
            if let c = tvHit, Date().timeIntervalSince(c.0) < 600 { res.json(["items": c.1, "tested": false, "source": srcLabel]); return }
            let fav = try? NSRegularExpression(pattern: "france ?24|tv5|africa ?24|africanews|euronews|rtb|bf1|rti|canal ?3|savane|filinfo|impact|2m|ortm|crtv|lcm|tele ?sahel|tm1|bbc|cnn|al ?jazeera|dw", options: .caseInsensitive)
            items.sort { a, b in
                func f(_ o: [String: Any]) -> Int { let n = (o["name"] as? String) ?? ""; return fav?.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil ? 0 : 1 }
                return f(a) < f(b)
            }
            // Hunk B de la spec : chaque racine servie devient relayable dès la construction de la
            // liste (avant : seules les racines testées vivantes l'étaient — le relais aurait refusé
            // en 403 toute chaîne non testée). L'autorisation ne préjuge pas de la santé.
            for o in items { if let u = o["url"] as? String { TVStreamRelay.authorizeRoot(u) } }
            // 31/10 (voix/mémoire/Live) : purge des entrées expirées + 12 au plus (une liste complète par filtre tapé, avant : sans fin).
            Self.tvCacheLock.lock()
            let tvNow: Date = Date()
            Self.tvCache = Self.tvCache.filter { (kv: (key: String, value: (Date, [[String: Any]]))) -> Bool in tvNow.timeIntervalSince(kv.value.0) < 600 }
            if Self.tvCache.count >= 12, let oldest = Self.tvCache.min(by: { $0.value.0 < $1.value.0 })?.key { Self.tvCache.removeValue(forKey: oldest) }
            Self.tvCache[ck] = (Date(), items)
            Self.tvCacheLock.unlock()
            res.json(["items": items, "tested": false, "source": srcLabel])
        }
        // SPEC TV LISTE D'ABORD (21/10) : santé UNITAIRE d'une chaîne, à la demande du
        // vérificateur paresseux du web. Même rigueur que l'ancien test groupé (manifeste →
        // variante → premier segment, tvPlaysDetail) mais bornée (10 s par saut) et mémorisée
        // 600 s en succès, 30 s en échec : la réponse NOMME l'étape fautive au lieu d'éliminer la chaîne de la liste.
        s.on("GET", "/api/tv/check") { req, res in
            let u = (req.query["u"] ?? "").trimmingCharacters(in: .whitespaces)
            guard u.hasPrefix("http"), URL(string: u) != nil else { res.json(["u": u, "ok": false, "reason": "URL invalide"], status: 400); return }
            Self.tvCheckLock.lock()
            if let c = Self.tvCheckCache[u], Date().timeIntervalSince(c.0) < (c.1 ? 600 : 30) { Self.tvCheckLock.unlock(); res.json(["u": u, "ok": c.1, "reason": c.2]); return }
            Self.tvCheckLock.unlock()
            let (st, d) = Self.tvFetch(u, timeout: 10)
            var ok = false, reason = ""
            if st == 0 { reason = "manifeste injoignable" }
            else if st != 200 { reason = "manifeste HTTP \(st)" }
            else if d.count <= 7 || String(data: d.prefix(7), encoding: .utf8) != "#EXTM3U" { reason = "manifeste invalide" }
            else { let r = Self.tvPlaysDetail(u, firstData: d, timeout: 10); ok = r.ok; reason = r.reason }
            Self.tvCheckLock.lock(); Self.tvCheckCache[u] = (Date(), ok, reason); Self.tvCheckLock.unlock()
            res.json(["u": u, "ok": ok, "reason": reason])
        }
        // FIXPREP D-R4 : relais vidéo local canonique. L'ancien chemin reste un alias
        // pour les favoris déjà enregistrés, mais les deux routes exécutent le même code.
        s.on("GET", "/api/stream") { req, res in TVStreamRelay.serve(req, res) }
        s.on("GET", "/api/tv/stream") { req, res in TVStreamRelay.serve(req, res) }
        // Radios du monde (annuaire communautaire radio-browser.info) : recherche par pays (code ISO) et/ou nom ; on ne garde que les flux qui répondent bien.
        s.on("GET", "/api/radio/search") { req, res in
            func enc(_ v: String) -> String { v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.replacingOccurrences(of: "&", with: "%26") ?? "" }
            var q = "hidebroken=true&order=clickcount&reverse=true&limit=\(min(120, Int(req.query["limit"] ?? "") ?? 60))"
            let cc = (req.query["country"] ?? "").uppercased(), name = req.query["name"] ?? "", tag = req.query["tag"] ?? ""
            if cc.count == 2 { q += "&countrycode=" + enc(cc) }
            if !name.isEmpty { q += "&name=" + enc(name) }
            if !tag.isEmpty { q += "&tag=" + enc(tag) }
            if let off = Int(req.query["offset"] ?? ""), off > 0 { q += "&offset=\(off)" }
            var items: [[String: Any]]? = nil; var err = ""
            for host in ["de1", "de2", "nl1", "at1"] {
                guard let u = URL(string: "https://\(host).api.radio-browser.info/json/stations/search?" + q) else { continue }
                var r = URLRequest(url: u); r.setValue("Nova/1.0", forHTTPHeaderField: "User-Agent")
                let (st, d) = syncGet(r, timeout: 10)
                if st == 200, let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] { items = arr; break }
                err = "HTTP \(st)"
            }
            guard let arr = items else {
                _ = BlackBox.record([
                    "tool": "radio_search", "actor": "Nova",
                    "why": "annuaire radio : recherche injoignable",
                    "ok": false, "effect": "lecture",
                    "result": err
                ])
                res.json(["error": "Annuaire radio injoignable (\(err))", "items": [Any]()], status: 502); return
            }
            var seen = Set<String>()
            let out: [[String: Any]] = arr.compactMap { o in
                let url = ((o["url_resolved"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? (o["url"] as? String) ?? ""
                guard url.hasPrefix("http"), let n = (o["name"] as? String)?.trimmingCharacters(in: .whitespaces), !n.isEmpty, seen.insert(n.lowercased()).inserted else { return nil }
                return ["name": n, "url": url, "country": o["country"] ?? "", "cc": o["countrycode"] ?? "", "tags": o["tags"] ?? "", "codec": o["codec"] ?? "", "bitrate": o["bitrate"] ?? 0, "votes": o["votes"] ?? 0, "favicon": o["favicon"] ?? ""]
            }
            res.json(["items": out])
        }
        s.on("GET", "/api/conversation") { [self] req, res in res.json(convs.get(req.query["id"] ?? "") ?? [:]) }
        s.on("POST", "/api/conversation/delete") { [self] req, res in convs.delete(req.json["id"] as? String ?? ""); res.json(["ok": true]) }

        // Aperçu des fichiers Word / PowerPoint CAFU générés
        s.on("GET", "/api/office/meta") { req, res in res.json(CAFUOffice.meta(req.query["name"] ?? "")) }
        s.on("GET", "/api/office/thumb") { req, res in
            if let d = CAFUOffice.thumb(req.query["name"] ?? "") { res.data(d, type: "image/png") } else { res.json(["error": "aperçu indisponible"], status: 404) }
        }
        s.on("POST", "/api/office/open") { req, res in res.json(["ok": CAFUOffice.openFile((req.json["name"] as? String) ?? "")]) }

        // Voix
        s.on("POST", "/api/tts") { [self] req, res in voice.speak(text: (req.json["text"] as? String) ?? "", res: res, accept: req.headers["accept"]) }
        s.on("POST", "/api/stt") { [self] req, res in
            // FIX-STT (22/10) : le corps Blob d'un fetch() se perd dans le transport
            // nova:// (readBody rend 0 octet) ; les corps TEXTE traversent sans perte.
            // Le web envoie donc l'audio en base64 dans un corps JSON ; le chemin
            // binaire brut reste accepté en repli (autres clients, NovaIPC désactivé).
            var audio = req.body
            var mime = req.headers["content-type"] ?? "audio/wav"
            var via = "binaire"
            if let b64 = req.json["audio_b64"] as? String {
                guard let d = Data(base64Encoded: b64) else {
                    res.json(["error": "audio_b64 illisible (base64 invalide)", "audio_bytes": 0, "audio_type": mime], status: 400); return
                }
                audio = d
                if let t = req.json["type"] as? String, !t.isEmpty { mime = t }
                via = "json-b64"
            }
            voice.journal.add(["stt": "recu", "bytes": audio.count, "via": via])
            // Garde 0 octet : rejet AVANT les moteurs (avant : le vide était expédié
            // à Meta/[tiers]/[tiers], qui accusaient le fichier, pas le transport).
            guard !audio.isEmpty else {
                voice.journal.add(["stt": "garde-vide", "bytes": 0, "via": via])
                res.json(["error": "enregistrement vide (0 octet) — le son n'est pas parvenu à Nova", "audio_bytes": 0, "audio_type": mime], status: 400); return
            }
            let r = voice.transcribe(audio: audio, mime: mime)
            if let t = r.text { res.json(["text": t, "via": r.via ?? "inconnu"]) }
            else { res.json(["error": r.error ?? "échec", "audio_bytes": audio.count, "audio_type": mime], status: 502) }
        }

        // Mémoire
        routesMemorySkills(s)
        routesDots(s)
        Tools.forgeHook = { [forge = self.forge] a in   // Phase 9 : l'agent crée un outil → vérifié en bac à sable avant d'être enregistré
            let j = parseJSON(Data(a.utf8)) ?? [:]; let r = forge.verifyAndHealTool(name: j["name"] as? String ?? "outil", kind: j["kind"] as? String ?? "sh", source: j["source"] as? String ?? "", why: j["why"] as? String ?? "")
            return r.ok ? "Outil « \(r.name) » vérifié et enregistré (\(r.attempts) essai(s))." : "Outil refusé après \(r.attempts) essai(s) : \(r.error ?? "échec")" }
        s.on("GET", "/api/forge/outils") { [self] _, res in res.json(["items": forge.registry.read(default: [[String: Any]]())]) }   // Phase 9 : outils forgés opérationnels
        s.on("POST", "/api/forge/verify") { [self] req, res in   // test de santé en bac à sable + auto-guérison (≤ 3 essais) ; n'enregistre qu'un outil sain
            let j = req.json; let r = forge.verifyAndHealTool(name: j["name"] as? String ?? "outil", kind: j["kind"] as? String ?? "sh", source: j["source"] as? String ?? "", why: j["why"] as? String ?? "")
            var d = r.dict; d["source"] = r.ok ? nil : String(r.source.prefix(4000)); res.json(d)
        }
        s.on("GET", "/api/journal") { [self] _, res in res.json(["cerveaux": router.journal.tail(60), "voix": voice.journal.tail(40)]) }
    }
}
