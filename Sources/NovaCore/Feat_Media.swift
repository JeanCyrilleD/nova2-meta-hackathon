import Foundation

// 25/10 : MÉDIAS PILOTÉS PAR L'AGENT + ÉCRANS DE NOVA + « TES POUVOIRS ».
// Constat d'Ahadi : « lance-moi la télé en arrière-plan sur une chaîne » → Spark a planté ; aucun outil ne
// savait jouer une chaîne dans Médias, ni ouvrir un écran de Nova, et le prompt ne disait pas à l'agent ce
// qu'il sait faire.
// - Outil « media » : le MOTEUR résout la chaîne / station / podcast sur le catalogue réel (catalogue Nova TV,
//   playlists iptv-org par pays ou en français, annuaire radio-browser, annuaire fyyd), sonde la santé des flux
//   TV (même test que /api/tv/check, même cache), puis demande à la FENÊTRE de jouer en arrière-plan dans le
//   mini-lecteur / lecteur flottant (pont UIPilot : SSE « ui » op « media » → POST /api/ui/result).
//   « Lecture lancée » n'est rendu QUE sur constat réel de la fenêtre (événement « playing » du média).
// - Outil « nova_ui » : ouvrir un écran de Nova dans sa fenêtre (même pont, ordre « go »), lister les écrans.
//   Jamais de clic dans une app tierce, jamais de fenêtre passée au premier plan.
// - Tools.powersBlock : bloc « TES POUVOIRS » généré depuis le registre réel des outils (nativeToolSpecs),
//   ajouté au préfixe stable (nativeRules et protocolPrompt) — court et constant (cache de prompt).

public enum NovaMedia {
    struct Cand {
        var name: String
        var country: String
        var cc: String
        var urls: [String]
        var score: Int
        var source: String
        var adult: Bool
        var sub: String
    }

    // MARK: normalisation et correspondance floue

    static func norm(_ s: String) -> String {
        let f: String = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "fr_FR")).lowercased()
        var out: String = ""
        for ch in f {
            if ch.isLetter || ch.isNumber { out.append(ch) } else { out.append(" ") }
        }
        let parts: [String] = out.split(separator: " ").map { String($0) }
        return parts.joined(separator: " ")
    }
    static func tokens(_ s: String) -> [String] {
        return norm(s).split(separator: " ").map { String($0) }
    }
    static let stopWords: Set<String> = ["la", "le", "les", "l", "de", "du", "des", "d", "sur", "en", "chaine", "chaines", "television", "tele", "direct",
                                         "live", "arriere", "plan", "mets", "met", "lance", "lancer", "moi", "joue", "jouer", "station", "ecouter", "regarder", "une", "un", "stp", "svp"]

    /// Score 0…100 entre les mots de la demande et un nom de chaîne.
    static func score(_ q: [String], _ name: String) -> Int {
        let n: [String] = tokens(name)
        if q.isEmpty || n.isEmpty { return 0 }
        let qs: String = q.joined(separator: " ")
        let ns: String = n.joined(separator: " ")
        if qs == ns { return 100 }
        let qc: String = q.joined()
        let nc: String = n.joined()
        if qc == nc { return 98 }
        let padded: String = " " + ns + " "
        if padded.contains(" " + qs + " ") {
            let extra: Int = max(0, n.count - q.count) * 3
            return max(70, 90 - extra)
        }
        if qc.count >= 3 && nc.hasPrefix(qc) { return 80 }
        if qc.count >= 3 && nc.contains(qc) { return 72 }
        var hit: Int = 0
        for t in q {
            if n.contains(t) { hit += 1; continue }
            if t.count >= 3 && n.contains(where: { $0.hasPrefix(t) }) { hit += 1 }
        }
        if hit == 0 { return 0 }
        let cover: Int = hit * 65 / q.count
        let extra: Int = max(0, n.count - hit) * 4
        return max(1, cover - extra)
    }

    // MARK: pays (nom français ou anglais, alias usuels)

    static let countryAliases: [String: String] = [
        "cote d ivoire": "CI", "ivoire": "CI", "ivoirienne": "CI", "ivoirien": "CI", "rci": "CI", "burkina": "BF", "burkina faso": "BF", "burkinabe": "BF",
        "rdc": "CD", "congo kinshasa": "CD", "congo brazzaville": "CG", "usa": "US", "etats unis": "US", "angleterre": "GB", "royaume uni": "GB",
        "senegalaise": "SN", "malienne": "ML", "francaise": "FR", "camerounaise": "CM", "nigerienne": "NE", "togolaise": "TG", "beninoise": "BJ",
        "guineenne": "GN", "ghaneenne": "GH", "marocaine": "MA", "tunisienne": "TN", "algerienne": "DZ", "gabonaise": "GA",
    ]
    static let countryTable: [(String, String)] = {
        var out: [(String, String)] = []
        let fr: Locale = Locale(identifier: "fr_FR")
        let en: Locale = Locale(identifier: "en_US")
        for code in Locale.isoRegionCodes {
            if code.count != 2 { continue }
            if let n = fr.localizedString(forRegionCode: code) { out.append((NovaMedia.norm(n), code)) }
            if let n = en.localizedString(forRegionCode: code) { out.append((NovaMedia.norm(n), code)) }
        }
        for (k, v) in NovaMedia.countryAliases { out.append((k, v)) }
        // les noms les plus longs d'abord (« guinee equatoriale » avant « guinee »)
        out.sort { a, b in a.0.count > b.0.count }
        return out
    }()
    /// (code pays détecté, mots de la demande sans le pays).
    static func splitCountry(_ q: String) -> (String, [String]) {
        let base: String = norm(q)
        let toks: [String] = base.split(separator: " ").map { String($0) }
        if toks.count == 1 && toks[0].count == 2 {
            let up: String = toks[0].uppercased()
            if Locale.isoRegionCodes.contains(up) { return (up, []) }
        }
        let padded: String = " " + base + " "
        for (name, code) in countryTable {
            if name.count < 3 { continue }
            if padded.contains(" " + name + " ") {
                let rest: String = padded.replacingOccurrences(of: " " + name + " ", with: " ")
                let rt: [String] = rest.split(separator: " ").map { String($0) }
                return (code, rt)
            }
        }
        return ("", toks)
    }
    static func cleanQuery(_ toks: [String]) -> [String] {
        let kept: [String] = toks.filter { !stopWords.contains($0) }
        return kept.isEmpty ? toks : kept
    }
    static func countryName(_ cc: String) -> String {
        if cc.isEmpty { return "" }
        return Locale(identifier: "fr_FR").localizedString(forRegionCode: cc) ?? cc
    }

    // MARK: catalogue TV (catalogue Nova + playlists iptv-org, cache 1 h)

    nonisolated(unsafe) static var m3uCache: [String: (Date, [[String: String]])] = [:]
    static let cacheLock: NSLock = NSLock()

    static func playlist(_ path: String) -> [[String: String]] {
        cacheLock.lock()
        if let c = m3uCache[path], Date().timeIntervalSince(c.0) < 3600 { cacheLock.unlock(); return c.1 }
        cacheLock.unlock()
        let (st, txt) = Tools.get("https://iptv-org.github.io/iptv/" + path + ".m3u", timeout: 15)
        if st != 200 { return [] }
        var items: [[String: String]] = []
        var meta: [String: String]? = nil
        for raw in txt.split(whereSeparator: \.isNewline) {
            let l: String = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#EXTINF") {
                let pieces: [Substring] = l.split(separator: ",", maxSplits: 1)
                var nm: String = ""
                if let lastPiece = pieces.last { nm = String(lastPiece).trimmingCharacters(in: .whitespaces) }
                meta = ["name": nm, "group": attr(l, "group-title")]
            } else if l.hasPrefix("http"), let m = meta {
                var it: [String: String] = m
                it["url"] = l
                items.append(it)
                meta = nil
            }
        }
        cacheLock.lock(); m3uCache[path] = (Date(), items); cacheLock.unlock()
        return items
    }
    static func attr(_ l: String, _ k: String) -> String {
        guard let r = l.range(of: k + "=\"[^\"]*\"", options: .regularExpression) else { return "" }
        let s: String = String(l[r])
        return String(s.dropFirst(k.count + 2).dropLast())
    }
    /// Retire « (720p) », « [Geo-blocked] » du nom iptv-org.
    static func cleanName(_ n: String) -> String {
        var s: String = n.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func tvCandidates(_ raw: String) -> [Cand] {
        let explicitAdult: Bool = norm(raw).range(of: #"\b(xxx|adulte|adultes|18)\b"#, options: .regularExpression) != nil
        let (cc, rest) = splitCountry(raw)
        let q: [String] = cleanQuery(rest)
        var byKey: [String: Cand] = [:]
        func add(_ name: String, _ ccx: String, _ pays: String, _ url: String, _ src: String, _ adult: Bool) {
            let nm: String = cleanName(name)
            if nm.isEmpty || !url.hasPrefix("http") { return }
            let sameCC: Bool = !cc.isEmpty && ccx.uppercased() == cc
            var s: Int = 0
            if q.isEmpty {
                if !sameCC { return }   // « tv|Burkina » : seules les chaînes du pays, la première jouable est lancée
                s = 85
            } else {
                s = score(q, nm)
                if s <= 0 { return }
                if sameCC { s += 12 }
            }
            if src == "catalogue Nova" { s += 3 }
            let key: String = norm(nm) + "|" + ccx.uppercased()
            if var c = byKey[key] {
                if !c.urls.contains(url) { c.urls.append(url) }
                if s > c.score { c.score = s }
                byKey[key] = c
            } else {
                byKey[key] = Cand(name: nm, country: pays, cc: ccx.uppercased(), urls: [url], score: s, source: src, adult: adult, sub: "")
            }
        }
        for e in TVCatalog.entries {
            let nm: String = (e["name"] as? String) ?? ""
            let u: String = (e["url"] as? String) ?? ""
            let ccx: String = (e["cc"] as? String) ?? ""
            let pays: String = (e["pays"] as? String) ?? ""
            add(nm, ccx, pays, u, "catalogue Nova", false)
        }
        var paths: [String] = []
        if !cc.isEmpty { paths.append("countries/" + cc.lowercased()) }
        let bestSoFar: Int = byKey.values.map { $0.score }.max() ?? 0
        if bestSoFar < 85 && !q.isEmpty { paths.append("languages/fra") }
        for p in paths {
            let pcc: String = p.hasPrefix("countries/") ? cc : ""
            for it in playlist(p) {
                let grp: String = (it["group"] ?? "").lowercased()
                let adult: Bool = grp.contains("xxx") || grp.contains("adult")
                if adult && !explicitAdult { continue }   // 18+ : jamais sans demande explicite (et la fenêtre exige encore le réglage 18+)
                add(it["name"] ?? "", pcc, countryName(pcc), it["url"] ?? "", "iptv-org", adult)
            }
        }
        var list: [Cand] = Array(byKey.values)
        list.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.name.count < b.name.count
        }
        return Array(list.prefix(8))
    }

    /// Santé d'un flux TV : même marche et même cache que la route /api/tv/check (600 s succès, 30 s échec).
    static func tvHealth(_ u: String) -> (Bool, String) {
        NovaApp.tvCheckLock.lock()
        if let c = NovaApp.tvCheckCache[u], Date().timeIntervalSince(c.0) < (c.1 ? 600 : 30) { NovaApp.tvCheckLock.unlock(); return (c.1, c.2) }
        NovaApp.tvCheckLock.unlock()
        let (st, d) = NovaApp.tvFetch(u, timeout: 10)
        var ok: Bool = false
        var reason: String = ""
        if st == 0 { reason = "manifeste injoignable" }
        else if st != 200 { reason = "manifeste HTTP \(st)" }
        else if d.count <= 7 || String(data: d.prefix(7), encoding: .utf8) != "#EXTM3U" { reason = "manifeste invalide" }
        else {
            let r = NovaApp.tvPlaysDetail(u, firstData: d, timeout: 10)
            ok = r.ok
            reason = r.reason
        }
        NovaApp.tvCheckLock.lock(); NovaApp.tvCheckCache[u] = (Date(), ok, reason); NovaApp.tvCheckLock.unlock()
        return (ok, reason)
    }

    /// Sonde en parallèle les flux des meilleures chaînes ; garde les flux joignables en tête, écarte les morts.
    static func healthOrder(_ cands: [Cand]) -> ([Cand], [String]) {
        var jobs: [(Int, String)] = []
        for (i, c) in cands.prefix(3).enumerated() {
            for u in c.urls.prefix(3) { jobs.append((i, u)) }
        }
        let box: HealthBox = HealthBox()
        let g: DispatchGroup = DispatchGroup()
        for j in jobs {
            let u: String = j.1
            g.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let r: (Bool, String) = tvHealth(u)
                box.put(u, r)
                g.leave()
            }
        }
        _ = g.wait(timeout: .now() + 25)
        var notes: [String] = []
        var alive: [Cand] = []
        var unknown: [Cand] = []
        for c in cands.prefix(3) {
            var okU: [String] = []
            var pend: [String] = []
            var why: String = ""
            for u in c.urls {
                let r: (Bool, String)? = box.get(u)
                if let rr = r {
                    if rr.0 { okU.append(u) } else if why.isEmpty { why = rr.1 }
                } else { pend.append(u) }
            }
            var cc2: Cand = c
            if !okU.isEmpty {
                cc2.urls = okU + pend
                alive.append(cc2)
            } else if !pend.isEmpty {
                cc2.urls = pend
                unknown.append(cc2)
            } else {
                notes.append(c.name + " : flux mort (" + (why.isEmpty ? "échec du test" : why) + ")")
            }
        }
        return (alive + unknown, notes)
    }

    /// 25/10 : résultats de sonde partagés entre fils (verrou ; pas de var capturée dans une closure concurrente).
    final class HealthBox: @unchecked Sendable {
        private let lock: NSLock = NSLock()
        private var map: [String: (Bool, String)] = [:]
        func put(_ u: String, _ r: (Bool, String)) { lock.lock(); map[u] = r; lock.unlock() }
        func get(_ u: String) -> (Bool, String)? { lock.lock(); defer { lock.unlock() }; return map[u] }
    }

    // MARK: radio (radio-browser) et podcast (fyyd + flux RSS)

    static func radioCandidates(_ raw: String) -> [Cand] {
        let (cc, rest) = splitCountry(raw)
        let q: [String] = cleanQuery(rest.filter { $0 != "radio" || rest.count == 1 })
        let name: String = q.joined(separator: " ")
        var qs: String = "hidebroken=true&order=clickcount&reverse=true&limit=40"
        if !name.isEmpty { qs += "&name=" + (name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") }
        if !cc.isEmpty { qs += "&countrycode=" + cc }
        if name.isEmpty && cc.isEmpty { return [] }
        var arr: [[String: Any]] = []
        for host in ["de1", "de2", "nl1", "at1"] {
            let (st, body) = Tools.get("https://" + host + ".api.radio-browser.info/json/stations/search?" + qs, timeout: 10)
            if st == 200, let d = body.data(using: .utf8), let a = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] { arr = a; break }
        }
        var out: [Cand] = []
        var seen: Set<String> = []
        for o in arr {
            let nm: String = ((o["name"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            if nm.isEmpty { continue }
            let key: String = norm(nm)
            if seen.contains(key) { continue }
            seen.insert(key)
            var urls: [String] = []
            if let u = o["url_resolved"] as? String, u.hasPrefix("http") { urls.append(u) }
            if let u = o["url"] as? String, u.hasPrefix("http"), !urls.contains(u) { urls.append(u) }
            if urls.isEmpty { continue }
            var s: Int = q.isEmpty ? 40 : score(q, nm)
            if q.isEmpty == false && s == 0 { s = 5 }   // l'annuaire a déjà filtré par nom
            let ccx: String = ((o["countrycode"] as? String) ?? "").uppercased()
            if !cc.isEmpty && ccx == cc { s += 10 }
            out.append(Cand(name: nm, country: (o["country"] as? String) ?? "", cc: ccx, urls: urls, score: s, source: "radio-browser", adult: false, sub: ""))
        }
        out.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.name.count < b.name.count
        }
        return Array(out.prefix(6))
    }

    static func podcastCandidates(_ raw: String) -> [Cand] {
        let q: String = raw.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return [] }
        let enc: String = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let (st, body) = Tools.get("https://api.fyyd.de/0.2/search/podcast/?title=" + enc, timeout: 10)
        guard st == 200, let o = parseJSON(Data(body.utf8)), let arr = o["data"] as? [[String: Any]] else { return [] }
        let qt: [String] = cleanQuery(tokens(q))
        var shows: [(String, String, Int)] = []
        for r in arr {
            guard let f = r["xmlURL"] as? String, f.hasPrefix("https://"), let n = r["title"] as? String, !n.isEmpty else { continue }
            shows.append((n, f, score(qt, n)))
        }
        shows.sort { a, b in a.2 > b.2 }
        var out: [Cand] = []
        for sh in shows.prefix(2) {
            let (fst, fbody) = Tools.get(sh.1, timeout: 12)
            guard fst == 200, let d = fbody.data(using: .utf8) else { continue }
            let p: PodParser = PodParser()
            let x: XMLParser = XMLParser(data: d)
            x.delegate = p
            _ = x.parse()
            let eps: [[String: String]] = p.eps.filter { ($0["url"] ?? "").hasPrefix("http") }
            guard let ep = eps.first else { continue }
            let show: String = p.channelTitle.isEmpty ? sh.0 : p.channelTitle
            var urls: [String] = [ep["url"] ?? ""]
            if eps.count > 1, let u2 = eps[1]["url"] { urls.append(u2) }
            out.append(Cand(name: show, country: "", cc: "", urls: urls, score: max(sh.2, 1), source: "fyyd", adult: false, sub: ep["title"] ?? ""))
        }
        return out
    }

    // MARK: outil « media »

    static let usage: String = "media : tv|<chaîne et/ou pays> · radio|<station [pays]> · podcast|<recherche> · pause · reprendre · stop · etat · volume|<0-100>"

    static func candDict(_ c: Cand) -> [String: Any] {
        return ["name": c.name, "country": c.country, "cc": c.cc, "urls": c.urls, "adult": c.adult, "sub": c.sub, "source": c.source]
    }
    static func listText(_ cands: [Cand]) -> String {
        var lines: [String] = []
        for (i, c) in cands.prefix(3).enumerated() {
            let pays: String = c.country.isEmpty ? countryName(c.cc) : c.country
            let tail: String = pays.isEmpty ? "" : " (" + pays + ")"
            lines.append("\(i + 1)) " + c.name + tail)
        }
        return lines.joined(separator: " · ")
    }

    public static func tool(_ arg: String) -> String {
        let p: [String] = arg.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        let verb: String = norm(p.first ?? "")
        let rest: String = p.count > 1 ? p[1] : ""
        switch verb {
        case "stop", "arret", "arreter", "pause", "reprendre", "play", "etat", "volume":
            var act: String = verb
            if verb == "arret" || verb == "arreter" { act = "stop" }
            if verb == "play" { act = "reprendre" }
            let r: [String: Any]? = UIPilot.shared.request("media", ["act": act, "q": rest], timeout: 10)
            return render(r, kind: act, notes: [])
        case "tv", "tele", "television", "chaine":
            if rest.isEmpty { return "media : précise la chaîne et/ou le pays — ex. « tv|France 24 », « tv|RTI 1 », « tv|Burkina »." }
            let all: [Cand] = tvCandidates(rest)
            if all.isEmpty { return "Aucune chaîne trouvée pour « " + rest + " » (catalogue Nova, iptv-org pays et français). Essaie un autre nom ou le pays seul (tv|<pays>), ou ouvre Médias : nova_ui ouvrir|radio." }
            if let amb = ambiguity(all) { return amb }
            let (ordered, notes) = healthOrder(all)
            if ordered.isEmpty { return "ÉCHEC : chaînes trouvées mais aucun flux joignable depuis le Mac — " + notes.joined(separator: " ; ") + ". Autres pistes : " + listText(Array(all.dropFirst(3))) }
            for c in ordered { for u in c.urls { TVStreamRelay.authorizeRoot(u) } }   // le relais local /api/stream sert ces racines
            let payload: [[String: Any]] = ordered.map { candDict($0) }
            let r: [String: Any]? = UIPilot.shared.request("media", ["act": "play", "kind": "tv", "cands": payload], timeout: 75)
            return render(r, kind: "tv", notes: notes)
        case "radio", "station":
            if rest.isEmpty { return "media : précise la station — ex. « radio|RFI Afrique », « radio|Savane FM Burkina »." }
            let all: [Cand] = radioCandidates(rest)
            if all.isEmpty { return "Aucune station trouvée pour « " + rest + " » (annuaire radio-browser)." }
            if let amb = ambiguity(all) { return amb }
            let payload: [[String: Any]] = all.prefix(4).map { candDict($0) }
            let r: [String: Any]? = UIPilot.shared.request("media", ["act": "play", "kind": "radio", "cands": payload], timeout: 60)
            return render(r, kind: "radio", notes: [])
        case "podcast", "podcasts":
            if rest.isEmpty { return "media : précise le podcast — ex. « podcast|Afrique Économie RFI »." }
            let all: [Cand] = podcastCandidates(rest)
            if all.isEmpty { return "Aucun podcast lisible trouvé pour « " + rest + " » (annuaire fyyd + flux RSS)." }
            let payload: [[String: Any]] = all.map { candDict($0) }
            let r: [String: Any]? = UIPilot.shared.request("media", ["act": "play", "kind": "podcast", "cands": payload], timeout: 50)
            return render(r, kind: "podcast", notes: [])
        default:
            return usage
        }
    }

    /// Demande floue : on liste 3 candidats au lieu de jouer au hasard.
    static func ambiguity(_ all: [Cand]) -> String? {
        guard let best = all.first else { return nil }
        if best.score >= 85 { return nil }
        var weak: Bool = best.score < 55
        if all.count > 1 {
            let second: Cand = all[1]
            if second.score >= best.score - 4 && norm(second.name) != norm(best.name) && best.score < 75 { weak = true }
        }
        if !weak { return nil }
        return "Plusieurs chaînes possibles, aucune sûre : " + listText(all) + ". Rappelle media avec le nom exact (ex. « tv|" + best.name + "») ; si la demande d'Ahadi désigne clairement l'une d'elles, choisis-la toi-même."
    }

    static func render(_ r: [String: Any]?, kind: String, notes: [String]) -> String {
        guard let r = r else {
            return "INJOIGNABLE : la fenêtre de Nova n'a pas répondu (fermée, en veille ou en rechargement) — rien n'est lancé ni prouvé. Ne dis pas que ça joue."
        }
        let ok: Bool = (r["ok"] as? Bool) == true
        let tried: [String] = (r["essais"] as? [String]) ?? []
        let triedTxt: String = tried.isEmpty ? "" : " Essais : " + tried.joined(separator: " ; ") + "."
        let notesTxt: String = notes.isEmpty ? "" : " Écartées au test : " + notes.joined(separator: " ; ") + "."
        if !ok {
            let err: String = (r["erreur"] as? String) ?? "échec sans motif"
            return "ÉCHEC (constaté par la fenêtre) : " + err + "." + triedTxt + notesTxt
        }
        if kind == "tv" || kind == "radio" || kind == "podcast" {
            let name: String = (r["titre"] as? String) ?? "?"
            let sub: String = (r["sous_titre"] as? String) ?? ""
            let where1: String = kind == "tv" ? "lecteur flottant de Nova" : "mini-lecteur de Nova"
            let subTxt: String = sub.isEmpty ? "" : " — " + sub
            return "Lecture lancée : " + name + subTxt + " (" + kind + ", " + where1 + ", en arrière-plan : aucun écran changé, aucune fenêtre au premier plan). Constat : média en lecture." + triedTxt + notesTxt
        }
        guard let d = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]), let s = String(data: d, encoding: .utf8) else { return "Constat illisible." }
        return "CONSTAT (réel) : " + String(s.prefix(1500))
    }

    // MARK: outil « nova_ui »

    public static func uiTool(_ arg: String) -> String {
        let p: [String] = arg.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        let verb: String = norm(p.first ?? "")
        switch verb {
        case "", "pages", "ecrans", "liste", "onglets":
            guard let r = UIPilot.shared.request("onglets", [:], timeout: 8) else { return UIPilot.render(nil) }
            let items: [[String: Any]] = (r["ecrans"] as? [[String: Any]]) ?? []
            if items.isEmpty { return UIPilot.render(r) }
            var lines: [String] = []
            for it in items {
                let id: String = (it["id"] as? String) ?? ""
                let label: String = (it["label"] as? String) ?? id
                let actif: Bool = (it["actif"] as? Bool) == true
                lines.append("- " + label + " [" + id + "]" + (actif ? " (affiché)" : ""))
            }
            return "Écrans de Nova (nova_ui ouvrir|<id ou nom>) :\n" + lines.joined(separator: "\n")
        case "ouvrir", "ouvre", "open", "go", "aller", "afficher":
            let page: String = p.count > 1 ? p[1] : ""
            if page.isEmpty { return "nova_ui : ouvrir|<écran> [| section] — liste : nova_ui pages." }
            let section: String = p.count > 2 ? p[2] : ""
            _ = BlackBox.record(["tool": "nova_ui", "actor": "Assistant", "why": "ouvrir " + page, "ok": true, "effect": "interface"])
            // PILOTAGE 01/11 : la fenêtre résout l'écran (alias, section déduite), navigue, ATTEND le rendu, ouvre la
            // section ou la ligne demandée et renvoie l'état relu. Écart → un second essai sur l'id résolu, puis échec précis.
            var r: [String: Any]? = UIPilot.shared.request("go", ["q": page, "section": section], timeout: 12)
            if let rr = r, (rr["ok"] as? Bool) != true, rr["candidats"] == nil, rr["section"] == nil, let e = rr["ecran"] as? String, !e.isEmpty {
                Thread.sleep(forTimeInterval: 0.5)
                r = UIPilot.shared.request("go", ["q": e, "section": section], timeout: 12)
            }
            return NovaPilot.renderNav(r)
        case "etat", "état", "ecran", "écran":
            return NovaPilot.renderState(UIPilot.shared.request("etat", [:], timeout: 8))
        case "conversation", "conv", "chat":
            let q: String = p.count > 1 ? p.dropFirst().joined(separator: "|") : ""
            return Tools.appHook?("conv-ouvrir " + q) ?? "Commande interne indisponible."
        default:
            return "nova_ui : pages · ouvrir|<écran> [| section ou ligne de réglage] · etat · conversation|<id, titre ou épinglée>. Pour CHANGER un réglage : app set <clé> <valeur>. Jamais de clic dans une autre app (voir app ax-*)."
        }
    }
}

// MARK: « TES POUVOIRS » — généré depuis le registre réel des outils

extension Tools {
    /// Rubrique de chaque outil (les outils absents de la table tombent dans « Autres »).
    static let powerGroups: [(String, [String])] = [
        ("Mac", ["system", "processes", "shell", "applescript", "open", "ui", "notes", "contacts", "find", "clipboard", "today", "shortcut", "calendar", "reminders", "calendar_add", "reminder_add", "note_add", "phone", "momo"]),
        ("Messages", ["mail_unread", "mail_week", "mail_corps", "mail_pj", "teams_read", "mail_brouillon", "draft_reply", "cafu_format_email"]),
        ("Nova elle-même", ["nova_self", "nova_ui", "app", "remember", "recall", "know", "bibliotheque", "lire_fichier_bibliotheque", "skill", "forge_tool", "ask_assistant"]),   // 31/10 (Algolia biblio) : + bibliothèque
        ("Médias", ["media"]),
        ("Fichiers et livrables", ["read_file", "write_file", "edit_file", "transcribe", "cafu_format_document", "cafu_format_docx", "cafu_format_deck", "cafu_format_pdf", "cafu_format_table"]),
        ("Web et marchés", ["web_search", "web_fetch", "formulaire", "flux_titres", "brvm_cours"]),
    ]
    /// Première proposition de la description du registre, bornée (coût en jetons).
    static func powerLine(_ desc: String) -> String {
        var s: String = desc
        for sep in [" (", ". ", " : ", " — ", " ; "] {
            if let r = s.range(of: sep), s.distance(from: s.startIndex, to: r.lowerBound) >= 12 { s = String(s[..<r.lowerBound]) }
        }
        if s.count > 70 { s = String(s.prefix(69)) + "…" }
        return s
    }
    public static let powersBlock: String = Tools.powersBlockCompact(describedElsewhere: { (_: String) -> Bool in false })
    // 31/10 (audit prompt) : variantes compactes de « TES POUVOIRS » — mêmes rubriques, même ordre, même ROUTAGE ; seule la
    // description courte « (…) » d'un outil est omise quand le cerveau la reçoit déjà en entier ailleurs dans le même appel :
    // schéma natif de l'outil ([tiers], nativeRules) ou ligne « nom (…) » du protocole texte (autres cerveaux, protocolPrompt).
    static let powersBlockNative: String = Tools.powersBlockCompact(describedElsewhere: { (_: String) -> Bool in true })
    static let powersBlockText: String = Tools.powersBlockCompact(describedElsewhere: { (n: String) -> Bool in
        Tools.protocolPromptBase.hasPrefix(n + " (") || Tools.protocolPromptBase.contains("\n" + n + " (") || Tools.protocolPromptBase.contains(" " + n + " (")
    })
    static func powersBlockCompact(describedElsewhere: (String) -> Bool) -> String {
        var known: [String: String] = [:]
        var order: [String] = []
        for spec in Tools.nativeToolSpecs { known[spec.0] = Tools.powerLine(spec.1); order.append(spec.0) }
        var placed: Set<String> = []
        var lines: [String] = ["TES POUVOIRS (registre réel de tes outils — consulte-le avant de dire que tu ne peux pas) :"]
        for (title, names) in Tools.powerGroups {
            var parts: [String] = []
            for n in names {
                guard let d = known[n] else { continue }
                parts.append(describedElsewhere(n) ? n : n + " (" + d + ")")   // 31/10 (audit prompt) : description omise si déjà fournie
                placed.insert(n)
            }
            if !parts.isEmpty { lines.append("- " + title + " : " + parts.joined(separator: " · ")) }
        }
        let others: [String] = order.filter { !placed.contains($0) }
        if !others.isEmpty { lines.append("- Autres : " + others.joined(separator: ", ")) }
        lines.append("ROUTAGE : (a) lancer une chaîne TV, une radio ou un podcast → media (« tv|France 24 », « radio|RFI Afrique », « podcast|… », « stop ») : lecture en arrière-plan dans le lecteur de Nova, jamais une app tierce ni un site. (b) ouvrir ou montrer un écran de Nova → nova_ui (« ouvrir|radio », « pages »). (c) changer un réglage de Nova → nova_self set|clé|valeur ; état de Nova, Dots, briefs → app. (d) agir dans une autre app du Mac sans la passer devant → app ax-* ou applescript sans activate ; ui seulement « devant moi ». (e) remplir un formulaire web → formulaire lire puis remplir (valeurs dites par Ahadi ou de son profil, rien d'inventé), jamais soumettre sans carte : soumettre affiche la carte, seul son GO envoie. (g) ouvrir une pièce jointe d'un mail et en rapporter le contenu → mail_pj « expéditeur ou objet | nom de la pièce » (Gmail et Zoho par IMAP ; Outlook : « outlook: | nom de la pièce », fichiers d'Outlook sur le Mac ; tout en lecture seule). (h) « fais le brouillon dans Outlook / Gmail / Teams » → mail_brouillon (boite outlook|gmail|teams) avec le texte final complet : le brouillon arrive DANS la boîte, rien n'est envoyé — jamais la file de validation de Nova à la place. (f) jamais « je ne peux pas » avant d'avoir relu TES POUVOIRS et tenté l'outil qui correspond ; un échec se rapporte avec son motif réel.")
        return lines.joined(separator: "\n")
    }
}
