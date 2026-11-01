import Foundation

/// Portefeuilles titres (relevés SBIF en PDF) + cours BRVM publics. Aucun identifiant, aucune connexion à la plateforme :
/// Nova lit les relevés PDF que tu déposes dans ~/Nova-Finances et rafraîchit les cours depuis le site public de la BRVM.
public enum PortfolioParser {
    public struct Position { public var name: String; public var qty: Double; public var cmp: Double; public var cours: Double; public var pl: Double; public var pond: Double; public var value: Double }
    public struct Parsed { public var account = ""; public var kind = ""; public var asOf = ""; public var cash = 0.0; public var total = 0.0; public var positions: [Position] = [] }

    static let isInt1 = try! NSRegularExpression(pattern: #"^-?\d{1,3}$"#), isGrp = try! NSRegularExpression(pattern: #"^\d{3}$"#)
    static func m(_ r: NSRegularExpression, _ s: String) -> Bool { r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
    static let plain = try! NSRegularExpression(pattern: #"^-?\d+(\.\d+)?$"#), last = try! NSRegularExpression(pattern: #"^\d{3}(\.\d+)?$"#)

    /// Façons de lire `a[i...]` comme exactement `k` nombres consécutifs ; renvoie les valeurs et l'indice suivant.
    /// Les milliers sont séparés par des espaces (« 1 557.796 ») : un nombre peut occuper 1 à 3 atomes.
    static func numbers(_ a: [String], _ i: Int, _ k: Int) -> [([Double], Int)] {
        if k == 0 { return [([], i)] }
        guard i < a.count else { return [] }
        var out: [([Double], Int)] = []
        if m(plain, a[i]), let v = Double(a[i]) { for (r, n) in numbers(a, i + 1, k - 1) { out.append(([v] + r, n)) } }
        if m(isInt1, a[i]) {
            var s = a[i]; var j = i + 1
            while j < a.count, j - i <= 3, m(isGrp, a[j]) || m(last, a[j]) {
                s += a[j]
                if m(last, a[j]), let v = Double(s) { for (r, n) in numbers(a, j + 1, k - 1) { out.append(([v] + r, n)) } }
                if !m(isGrp, a[j]) { break }
                j += 1
            }
        }
        return out
    }
    static func isNum(_ t: String) -> Bool { m(plain, t) }
    static let stop: Set<String> = ["titre", "quantité", "quantite", "cmp", "cours", "+/-value", "pondération", "ponderation", "(%)", "valeur", "cotées", "cotees", "liquidités", "réservée", "reservee", "disponible", "s/total", ":", "total", "page", "de", "client(e)", "obligations", "actions"]
    static func atoms(_ t: String) -> [String] { t.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{00A0}\u{202F}\u{2009}"))).filter { !$0.isEmpty } }

    /// Lecture indépendante de la mise en page : on repère « 6 nombres cohérents » (qté × cours ≈ valeur), le nom est ce qui les précède.
    static func positions(_ a: [String]) -> [Position] {
        var out: [Position] = []; var floor = 0; var j = 0
        while j < a.count {
            guard isNum(a[j]) || m(isInt1, a[j]), j > floor else { j += 1; continue }
            guard !isNum(a[j - 1]) || false else { j += 1; continue }
            var found: ([Double], Int)? = nil
            for (n, nx) in numbers(a, j, 6) where n[0] > 0 && n[2] > 0 && n[5] > 0 && n[4] <= 100 && abs(n[0] * n[2] - n[5]) <= max(1, n[5] * 0.015) { found = (n, nx); break }
            guard let (n, nx) = found else { j += 1; continue }
            var k = j; var name: [String] = []
            while k > floor, name.count < 7 { let t = a[k - 1]; if isNum(t) || stop.contains(t.lowercased()) || t.hasSuffix(":") || t.range(of: #"^\d"#, options: .regularExpression) != nil { break }; name.insert(t, at: 0); k -= 1 }
            if !name.isEmpty { out.append(Position(name: name.joined(separator: " "), qty: n[0], cmp: n[1], cours: n[2], pl: n[3], pond: n[4], value: n[5])); floor = nx; j = nx } else { j += 1 }
        }
        return out
    }

    static func after(_ a: [String], _ key: String, last lastOne: Bool = false) -> Double? {
        let idx = a.indices.filter { a[$0].lowercased() == key }; guard let i = lastOne ? idx.last : idx.first else { return nil }
        for k in (i + 1)..<min(a.count, i + 4) { if let r = numbers(a, k, 1).max(by: { $0.1 < $1.1 }) { return r.0[0] } }
        return nil
    }


    // ── Mise en page « colonne par colonne » (PDFKit de macOS : tous les noms, puis toutes les quantités, etc.) ──
    static let dec3 = try! NSRegularExpression(pattern: #"^-?\d{1,3}\.\d{3}$"#), dec2 = try! NSRegularExpression(pattern: #"^\d{1,3}\.\d{2}$"#), intA = try! NSRegularExpression(pattern: #"^-?\d{1,3}$"#)
    static let known: Set<String> = ["NEI-CEDA CI", "NSIA CI", "NESTLE CI", "ORANGE COTE D`IVOIRE", "ONATEL BF", "ORAGROUP", "VIVO ENERGY CI", "SIB CI", "SICOR CI", "PALM CI", "TRACTAFRIC MOTORS CI", "SAFCA CI", "SIEM CI", "SONATEL SN", "SOGB CI", "SETAO CI", "UNIWAX CI", "BIIC", "FILTISAC CI", "BERNABE CI", "BANK OF AFRICA BN", "BANK OF AFRICA BURKI", "BANK OF AFRICA CI", "BANK OF AFRICA MALI", "BANK OF AFRICA SN", "SICABLE CI", "CORIS BANK INTERNATI", "CIE CI", "ECOBANK CI", "AIR LIQUIDE COTE D I", "SUCRIVOIRE", "BOLLORE AFRICA LOGIS", "CFAO CI", "ETIT", "SERVAIR ABIDJAN CI", "BRIDGE BANK GROUP COTE D`IVOIR", "SOLIBRA CI", "SMB CI", "SAPH CI", "SITAB CI", "SODECI CI", "TOTAL CI", "UNILEVER CI", "SOCIETE GENERALE CI", "BICI CI", "BANK OF AFRICA NIGER", "ECOBANK TG", "ORANGE BF"]
    static let tails: Set<String> = ["CI", "SN", "BF", "BN", "TG", "ML", "NE", "BURKI", "MALI", "INTERNATI", "LOGIS", "BENIN", "IVOIRE", "IVOIR"]

    /// Découpe « NEI-CEDA CI NSIA CI … » en exactement n noms (dictionnaire + suffixes pays), par programmation dynamique.
    static func splitNames(_ t: [String], _ n: Int) -> [String]? {
        let L = t.count; guard n >= 1, L >= n else { return nil }
        func score(_ i: Int, _ j: Int) -> Int { let c = t[i..<j].joined(separator: " ").uppercased(); var sc = 0
            if known.contains(c) { sc += 10 } else if j - i >= 2, tails.contains(t[j - 1].uppercased()) { sc += 3 }
            if j - i == 1, tails.contains(t[i].uppercased()) { sc -= 20 }
            if j - i > 5 { sc -= 20 }; return sc }
        var best = [[Int?]](repeating: [Int?](repeating: nil, count: n + 1), count: L + 1), from = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: L + 1)
        best[0][0] = 0
        for j in 1...L { for k in 1...min(n, j) { for i in (k - 1)..<j { if let b = best[i][k - 1] { let v = b + score(i, j); if best[j][k] == nil || v > best[j][k]! { best[j][k] = v; from[j][k] = i } } } } }
        guard best[L][n] != nil else { return nil }
        var out: [String] = []; var j = L, k = n
        while k > 0 { let i = from[j][k]; out.insert(t[i..<j].joined(separator: " "), at: 0); j = i; k -= 1 }
        return out
    }

    /// n quantités entières à partir d'atomes (« 10 122 » = un seul nombre), validées par qté × cours ≈ valeur.
    static func qtys(_ a: [String], _ n: Int, cours: [Double], val: [Double], fixed: [Int: Double] = [:]) -> [Double]? {
        func go(_ p: Int, _ i: Int) -> [Double]? {
            if i == n { return p == a.count ? [] : nil }
            if let f = fixed[i] { return abs(f * cours[i] - val[i]) <= max(1, val[i] * 0.015) ? go(p, i + 1).map { [f] + $0 } : nil }
            guard p < a.count else { return nil }
            var s = ""; var q = p
            while q < a.count, q - p < 3 {
                if q > p && !m(isGrp, a[q]) { break }
                s += a[q]; q += 1
                if let v = Double(s), v > 0, abs(v * cours[i] - val[i]) <= max(1, val[i] * 0.015), let r = go(q, i + 1) { return [v] + r }
            }
            return nil
        }
        return go(0, 0)
    }

    /// Valeur « 1 011 400.000 » : jusqu'à deux groupes de milliers avant l'atome décimal.
    static func moneyPrefix(_ pend: [String]) -> String {
        var pre = ""; var k = pend.count
        while k > 0, pre.count < 8 { let x = pend[k - 1]
            if m(isGrp, x), k >= 2, m(intA, pend[k - 2]) { pre = pend[k - 2] + x + pre; k -= 2; break }
            if m(intA, x) { pre = x + pre; k -= 1; break }; break }
        return pre
    }
    static func page(_ block: String) -> (pos: [Position], before: [Double], after: [Double])? {
        let lines0 = block.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let hv = lines0.lastIndex(where: { $0 == "Valeur" }) else { return nil }
        let endI = lines0.indices.first(where: { $0 > hv && lines0[$0].hasPrefix("Date d") }) ?? lines0.count
        let lines = Array(lines0[..<endI])
        var i = hv + 1
        let isLabel = { (l: String) in l.hasPrefix("Liquidit") || l.lowercased().hasSuffix("cotées") || l.lowercased().hasSuffix("cotees") || l.isEmpty }
        while i < lines.count, isLabel(lines[i]) { i += 1 }
        let labels = lines[(hv + 1)..<min(i, lines.count)].joined(separator: " ").lowercased()
        let dispoFirst = (labels.range(of: "disponible")?.lowerBound ?? labels.endIndex) < (labels.range(of: "réservée")?.lowerBound ?? labels.endIndex)
        guard i < lines.count else { return nil }
        func pure(_ l: String) -> Bool { let a = atoms(l).filter { $0.lowercased() != "total" && $0 != "S/Total" && $0 != ":" }; return !a.isEmpty && a.allSatisfy { isNum($0) } }
        var region: [String] = []; var j = i
        while j < lines.count { if pure(lines[j]) && region.contains(where: { isNum($0) }) { break }; region += atoms(lines[j]); j += 1 }
        let ra = region.filter { $0 != "S/Total" && $0 != ":" }
        let firstNum = ra.firstIndex(where: { isNum($0) }) ?? ra.count
        let names = Array(ra[..<firstNum]); let S = Array(ra[firstNum...])
        let n = S.filter { m(dec2, $0) }.count; guard n > 0, let nm = splitNames(names, n) else { return nil }
        // nombres décimaux : valeur = (groupe de milliers précédent) + atome décimal ; les entiers restants sont des quantités égarées
        var decs: [(tok: String, v: Double, two: Bool)] = []; var pending: [String] = []; var strays: [Int: Double] = [:]; var head: [String] = []; var first = true
        for t in S {
            if m(dec3, t) || m(dec2, t) {
                if first { head = pending; first = false; pending = []; decs.append((t, Double(t) ?? 0, m(dec2, t))); continue }
                var pre = ""
                if decs.filter({ $0.two }).count == n { pre = moneyPrefix(pending); pending = [] }
                else if let l = pending.last, m(intA, l) { pre = l; pending.removeLast() }
                for x in pending { if m(intA, x), decs.count <= n, let sv = Double(x) { strays[decs.count] = sv } }; pending = []
                guard let v = Double(pre + t) else { return nil }; decs.append((t, v, m(dec2, t)))
            } else { pending.append(t) }
        }
        let d3 = decs.prefix { !$0.two }; guard d3.count == 3 * n else { return nil }
        let cours = d3[(d3.startIndex + n)..<(d3.startIndex + 2 * n)].map { $0.v }, pl = d3[(d3.startIndex + 2 * n)...].map { $0.v }
        let pond = decs.filter { $0.two }.map { $0.v }; guard pond.count == n else { return nil }
        var T: [Double] = []; var seen = 0
        for d in decs { if d.two { seen += 1 } else if seen == n { T.append(d.v) } }
        for l in lines[j...] { var pend: [String] = []
            for t in atoms(l) where t.lowercased() != "total" && t != "S/Total" && t != ":" {
                if m(dec3, t) { let pre = moneyPrefix(pend); pend = []; if let v = Double(pre + t) { T.append(v) } } else { pend.append(t) } } }
        guard T.count >= n else { return nil }
        for w in 0...(T.count - n) {
            let val = Array(T[w..<(w + n)])
            for t in [1, 0] where head.count >= t {
                let qa = Array(head.dropLast(t))
                guard let q = qtys(qa, n, cours: cours, val: val, fixed: strays) else { continue }
                var cmp = d3[d3.startIndex..<(d3.startIndex + n)].map { $0.v }
                if t == 1, let v = Double(head.last! + decs[0].tok) { cmp[0] = v }
                let pos = (0..<n).map { Position(name: nm[$0], qty: q[$0], cmp: cmp[$0], cours: cours[$0], pl: pl[$0], pond: pond[$0], value: val[$0]) }
                var cash = Array(T[0..<w].prefix(2)); if !dispoFirst { cash.reverse() }
                return (pos, cash, Array(T[(w + n)...]))
            }
        }
        return nil
    }

    public static func parse(_ text: String) -> Parsed? {
        var p = Parsed(); let a = atoms(text)
        if let r = text.range(of: #"\b\d{10}\b"#, options: .regularExpression) { p.account = String(text[r]) }
        if let r = text.range(of: #"\(([^)]*(?:TITRES|titres|Compte)[^)]*)\)"#, options: .regularExpression) { p.kind = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: "()")) }
        if let r = text.range(of: #"situation au (\d{1,2} \S+ \d{4})"#, options: .regularExpression) { p.asOf = String(text[r]).replacingOccurrences(of: "situation au ", with: "") }
        // 1) mise en page « lignes » (pdftotext -layout)
        var rowPos = positions(a); var cashRow = 0.0
        if let i = a.firstIndex(where: { $0.lowercased() == "disponible" }) { for k in (i + 1)..<min(a.count, i + 4) { if let r = numbers(a, k, 1).max(by: { $0.1 < $1.1 }) { cashRow = r.0[0]; break } } }
        // 2) mise en page « colonnes » (PDFKit) : une page à la fois
        var colPos: [Position] = []; var colCash = 0.0; var lastAfter: [Double] = []
        for blk in text.components(separatedBy: "VERSION WEB") { if let r = page(blk) { colPos += r.pos; if !r.before.isEmpty { colCash = r.before[0] }; lastAfter = r.after } }
        if colPos.count > rowPos.count { rowPos = colPos; cashRow = colCash }
        p.positions = rowPos; p.cash = cashRow
        p.total = lastAfter.last ?? after(a, "total", last: true) ?? 0
        guard !p.positions.isEmpty, !p.account.isEmpty else { return nil }
        if p.kind.isEmpty { p.kind = "Compte titres" }
        let sum = p.positions.reduce(0) { $0 + $1.value } + p.cash
        if p.total == 0 || abs(p.total - sum) > max(1, sum * 0.001) { p.total = sum }
        return p
    }

    /// Nom SBIF → symbole BRVM (les noms du relevé sont tronqués ; on garde l'ordre le plus spécifique d'abord).
    static let symbols: [(String, String)] = [
        ("BANK OF AFRICA BURK", "BOABF"), ("BANK OF AFRICA BN", "BOAB"), ("BANK OF AFRICA BENIN", "BOAB"), ("BANK OF AFRICA CI", "BOAC"), ("BANK OF AFRICA MALI", "BOAM"),
        ("BANK OF AFRICA SN", "BOAS"), ("BANK OF AFRICA NIGER", "BOAN"), ("NEI-CEDA", "NEIC"), ("NSIA", "NSBC"), ("NESTLE", "NTLC"), ("ORANGE COTE", "ORAC"), ("ONATEL", "ONTBF"),
        ("ORAGROUP", "ORGT"), ("VIVO", "SHEC"), ("SIB CI", "SIBC"), ("SICOR", "SICC"), ("PALM", "PALC"), ("TRACTAFRIC", "PRSC"), ("SAFCA", "SAFC"), ("SIEM", "SEMC"),
        ("SONATEL", "SNTS"), ("SOGB", "SOGC"), ("SETAO", "STAC"), ("UNIWAX", "UNXC"), ("BIIC", "BICB"), ("FILTISAC", "FTSC"), ("BERNABE", "BNBC"), ("SICABLE", "CABC"),
        ("CORIS", "CBIBF"), ("CIE CI", "CIEC"), ("ECOBANK CI", "ECOC"), ("AIR LIQUIDE", "SIVC"), ("SUCRIVOIRE", "SCRC"), ("BOLLORE", "SDSC"), ("CFAO", "CFAC"),
        ("ETIT", "ETIT"), ("SERVAIR", "ABJC"), ("BRIDGE", "BBGC"), ("TOTAL", "TTLC"), ("SOCIETE GENERALE", "SGBC"), ("SMB", "SMBC"), ("SOLIBRA", "SLBC"), ("SAPH", "SPHC"),
        ("SITAB", "STBC"), ("SDCC", "SDCC"), ("BICICI", "BICC"), ("LOGISTIQUE", "SDSC"), ("TOTALENERGIES", "TTLC"), ("UNILEVER", "UNLC")]
    public static func symbol(_ name: String) -> String? { let n = name.uppercased(); return (symbols.first { n.hasPrefix($0.0) } ?? symbols.filter { n.contains($0.0) }.max { $0.0.count < $1.0.count })?.1 }

    /// Page publique BRVM : bandeau « SYMBOLE cours variation » de toutes les valeurs.
    public static func parseQuotes(_ html: String) -> [String: (price: Double, var: Double)] {
        var out: [String: (Double, Double)] = [:]
        guard let re = try? NSRegularExpression(pattern: #"<div class="item"><span>(\w+)</span>&nbsp;<span>([\d\s&nbsp;]+)</span>&nbsp;<span>(-?[\d,]+)%"#) else { return [:] }
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let a = Range(m.range(at: 1), in: html), let b = Range(m.range(at: 2), in: html), let c = Range(m.range(at: 3), in: html) else { continue }
            let price = Double(html[b].filter { $0.isNumber }) ?? 0, v = Double(html[c].replacingOccurrences(of: ",", with: ".")) ?? 0
            if price > 0 { out[String(html[a])] = (price, v) }
        }
        return out
    }
}

extension NovaApp {
    func portfolioRoutes(valid: @escaping (Request) -> Bool) {
        let s = server
        let file = VaultFile("vault_portefeuilles.json")   // V3 COFFRE : chiffré au repos (Vault.swift), lisible seulement coffre ouvert
        let lock = NSLock()
        let home = NSHomeDirectory()
        let watch = home + "/Nova-Finances"
        func nowISO() -> String { ISO8601DateFormatter().string(from: Date()) }

        func note(_ msg: String?) { lock.lock(); var d = file.read(default: [String: Any]()); if let m = msg { d["last_error"] = m } else { d.removeValue(forKey: "last_error") }; file.write(d); lock.unlock()
            if let m = msg, FileManager.default.fileExists(atPath: home + "/spark-local/Nova2/releves") { try? m.write(toFile: home + "/spark-local/Nova2/releves/_ingest.log", atomically: true, encoding: .utf8) } }
        func ingest(path: String) -> String? {   // nil = ok, sinon message d'erreur
            let name = (path as NSString).lastPathComponent
            guard let hook = VaultHooks.pdfText else { note("\(name) : lecteur PDF absent"); return "lecteur PDF absent" }
            guard let t = hook(path), !t.isEmpty else { note("\(name) : PDF illisible (vide)"); return "PDF illisible (scan ?)" }
            if ProcessInfo.processInfo.environment["NOVA_DIAG_RELEVES"] == "1", FileManager.default.fileExists(atPath: home + "/spark-local/Nova2/releves") { try? t.write(toFile: home + "/spark-local/Nova2/releves/_dernier-extrait.txt", atomically: true, encoding: .utf8) }   // diagnostic EN CLAIR : seulement sur demande explicite (V3 COFFRE)
            guard let p = PortfolioParser.parse(t) else { note("\(name) : relevé SBIF non reconnu (\(t.count) caractères lus)"); return "relevé SBIF non reconnu" }
            lock.lock(); defer { lock.unlock() }
            let cur: (value: Any?, error: String?) = file.readChecked()
            if let e = cur.error { return "coffre : " + e }
            var d: [String: Any] = (cur.value as? [String: Any]) ?? [:]
            var accs = (d["accounts"] as? [String: Any]) ?? [:]
            let pos: [[String: Any]] = p.positions.map { ["name": $0.name, "sym": PortfolioParser.symbol($0.name) ?? "", "qty": $0.qty, "cmp": $0.cmp, "cours_releve": $0.cours, "valeur_releve": $0.value, "pond": $0.pond] }
            accs[p.account] = ["account": p.account, "kind": p.kind, "as_of": p.asOf, "cash": p.cash, "total_releve": p.total, "positions": pos, "source": name, "imported": nowISO()]
            d["accounts"] = accs; d.removeValue(forKey: "last_error")
            guard file.write(d) else { return "coffre : écriture refusée (" + VaultCrypto.errorText() + ")" }
            return nil
        }
        /// Compte saisi/déposé en JSON (ex. Africam, sans export PDF) : {"account","kind","cash","total_releve","invested","positions":[{"name","sym","qty","cmp"}]}
        func storeManual(_ j: [String: Any], source: String) -> String? {
            guard let acc = (j["account"] as? String), !acc.isEmpty else { return "champ « account » manquant" }
            func num(_ v: Any?) -> Double { if let d = v as? Double { return d }; if let i = v as? Int { return Double(i) }; if let s = v as? String { return Double(s.filter { $0.isNumber || $0 == "." }) ?? 0 }; return 0 }
            var pos: [[String: Any]] = []
            for p in (j["positions"] as? [[String: Any]]) ?? [] {
                let nm = (p["name"] as? String) ?? (p["sym"] as? String) ?? ""; if nm.isEmpty { continue }
                let sym = (p["sym"] as? String) ?? PortfolioParser.symbol(nm) ?? ""
                let q = num(p["qty"]), cmp = num(p["cmp"]), c = num(p["cours"])
                pos.append(["name": nm, "sym": sym, "qty": q, "cmp": cmp, "cours_releve": c > 0 ? c : cmp, "valeur_releve": q * (c > 0 ? c : cmp), "pond": 0])
            }
            lock.lock(); defer { lock.unlock() }
            let cur: (value: Any?, error: String?) = file.readChecked()
            if let e = cur.error { return "coffre : " + e }
            var d: [String: Any] = (cur.value as? [String: Any]) ?? [:]; var accs = (d["accounts"] as? [String: Any]) ?? [:]
            let cash = num(j["cash"]); let sum = pos.reduce(0.0) { $0 + (($1["valeur_releve"] as? Double) ?? 0) } + cash
            let tot = num(j["total_releve"]) > 0 ? num(j["total_releve"]) : sum
            accs[acc] = ["account": acc, "kind": (j["kind"] as? String) ?? "Compte", "as_of": (j["as_of"] as? String) ?? String(nowISO().prefix(10)), "cash": cash, "total_releve": tot, "invested": num(j["invested"]), "positions": pos, "source": source, "imported": nowISO()] as [String: Any]
            d["accounts"] = accs
            guard file.write(d) else { return "coffre : écriture refusée (" + VaultCrypto.errorText() + ")" }
            return nil
        }
        func refresh() -> (Int, String?) {
            let (st, html) = Tools.get("https://www.brvm.org/fr/cours-actions/0", timeout: 20)
            guard st == 200 else { return (0, "BRVM injoignable (HTTP \(st))") }
            let q = PortfolioParser.parseQuotes(html); guard !q.isEmpty else { return (0, "cours BRVM illisibles") }
            lock.lock(); defer { lock.unlock() }
            let cur: (value: Any?, error: String?) = file.readChecked()
            if let e = cur.error { return (0, "coffre : " + e) }
            var d: [String: Any] = (cur.value as? [String: Any]) ?? [:]
            d["quotes"] = q.mapValues { ["price": $0.price, "var": $0.var] as [String: Any] }; d["quotes_at"] = nowISO()
            guard file.write(d) else { return (0, "coffre : écriture refusée (" + VaultCrypto.errorText() + ")") }
            return (q.count, nil)
        }
        // LOT E (28/10) — CLÔTURE AUTOMATIQUE vs PRIX DE REVIENT.
        // Quand le coffre est ouvert et que les cours stockés sont d'un jour de séance
        // (lun–ven GMT) relevés à ≥ 15:30, la valorisation de clôture est figée dans le
        // coffre (clé « cloture ») : valeur, coût (qté × PRU), plus/moins-value latente,
        // variation du jour, lignes ordonnées par |P/V|. Un Direct annonce le relevé —
        // POURCENTAGES SEULS : aucun montant ni quantité ne sort du coffre chiffré.
        // Rattrapage : si le coffre était fermé après la clôture, le relevé se fait à la
        // première ouverture suivante à partir des cours stockés du jour de séance.
        func gmtCal() -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "GMT") ?? TimeZone(secondsFromGMT: 0)!; return c }
        func clotureNum(_ v: Any?) -> Double { if let d = v as? Double { return d }; if let i = v as? Int { return Double(i) }; if let n = v as? NSNumber { return n.doubleValue }; return 0 }
        func computeCloture(_ d: [String: Any], day: String, manuel: Bool) -> [String: Any]? {
            let accs: [String: Any] = (d["accounts"] as? [String: Any]) ?? [:]
            if accs.isEmpty { return nil }
            let quotes: [String: Any] = (d["quotes"] as? [String: Any]) ?? [:]
            var lignes: [[String: Any]] = []
            var valeur: Double = 0, cout: Double = 0, cash: Double = 0, dayDelta: Double = 0, prevVal: Double = 0
            var costKnown: Bool = true, dayKnown: Bool = false, stale: Int = 0
            for (_, v) in accs.sorted(by: { $0.key < $1.key }) {
                let a: [String: Any] = (v as? [String: Any]) ?? [:]
                cash += clotureNum(a["cash"])
                for p in (a["positions"] as? [[String: Any]]) ?? [] {
                    let sym: String = (p["sym"] as? String) ?? ""
                    let qty: Double = clotureNum(p["qty"]); let cmp: Double = clotureNum(p["cmp"])
                    let q: [String: Any] = (quotes[sym] as? [String: Any]) ?? [:]
                    let qPrice: Double = clotureNum(q["price"]); let qVar: Double = clotureNum(q["var"])
                    var cours: Double = qPrice > 0 ? qPrice : clotureNum(p["cours_releve"])
                    if cours <= 0 { cours = cmp }
                    if qPrice <= 0 { stale += 1 }
                    let val: Double = qty * cours
                    valeur += val
                    var ligne: [String: Any] = ["sym": sym, "name": (p["name"] as? String) ?? sym, "qty": qty,
                                                "pru": cmp, "cours": cours, "valeur": val, "cotation": qPrice > 0]
                    if cmp > 0 { cout += qty * cmp; let pv: Double = qty * (cours - cmp); ligne["pv"] = pv; ligne["pv_pct"] = (cours / cmp - 1) * 100 } else { costKnown = false }
                    if qPrice > 0 { ligne["var_jour"] = qVar; let veille: Double = cours / (1 + qVar / 100); dayDelta += qty * (cours - veille); prevVal += qty * veille; dayKnown = true }
                    lignes.append(ligne)
                }
            }
            if lignes.isEmpty { return nil }
            lignes.sort { abs(clotureNum($0["pv"])) > abs(clotureNum($1["pv"])) }
            var out: [String: Any] = ["day": day, "ts": nowISO(), "quotes_at": (d["quotes_at"] as? String) ?? "",
                                      "manuel": manuel, "valeur_titres": valeur, "cash": cash, "valeur_totale": valeur + cash,
                                      "lignes": lignes, "lignes_sans_cotation": stale,
                                      "note": "Cours : dernier relevé brvm.org stocké ; P/V latente = valeur au cours − qté × PRU. Information uniquement — ni conseil ni ordre."]
            if cout > 0 { out["cout"] = cout; out["pv"] = valeur - cout; out["pv_pct"] = (valeur / cout - 1) * 100; out["cout_partiel"] = !costKnown }
            if dayKnown && prevVal > 0 { out["jour_delta"] = dayDelta; out["jour_pct"] = dayDelta / prevVal * 100 }
            return out
        }
        func publishCloture(_ c: [String: Any]) {
            func pct(_ v: Any?) -> String { let x = clotureNum(v); return (x > 0 ? "+" : "") + String(format: "%.2f", x).replacingOccurrences(of: ".", with: ",") + " %" }
            let day: String = (c["day"] as? String) ?? ""
            var bits: [String] = []
            if c["jour_pct"] != nil { bits.append("séance " + pct(c["jour_pct"])) }
            if c["pv_pct"] != nil { bits.append("latente " + pct(c["pv_pct"]) + " vs prix de revient") }
            if let top = (c["lignes"] as? [[String: Any]])?.first, let sym = top["sym"] as? String, !sym.isEmpty, top["pv_pct"] != nil {
                bits.append("plus fort écart au PRU : " + sym + " " + pct(top["pv_pct"]))
            }
            let stale: Int = Int(clotureNum(c["lignes_sans_cotation"]))
            if stale > 0 { bits.append(String(stale) + " ligne(s) au cours du relevé") }
            let text: String = "Clôture BRVM du " + day + (bits.isEmpty ? "" : " — " + bits.joined(separator: " · ")) + ".\nDétail chiffré dans Finance (coffre) : valeur, prix de revient et plus/moins-value ligne par ligne. Information uniquement — ni conseil ni ordre."
            ProactiveFeed.append(kind: "brvm.cloture", box: "brvm", title: "BRVM — clôture du jour relevée", text: text, urgent: false, who: "", extra: ["day": day])
            _ = BlackBox.record(["tool": "brvm_cloture", "actor": "Nova", "effect": "lecture", "ok": true,
                                 "why": "clôture BRVM figée dans le coffre (valorisation vs prix de revient)",
                                 "result": "day=" + day + (c["pv_pct"] != nil ? " pv_pct=" + String(format: "%.2f", clotureNum(c["pv_pct"])) : "")])
        }
        /// Fige la clôture si les cours stockés sont un relevé de fin de séance non encore figé. Renvoie le relevé si figé.
        func maybeCloture(force: Bool) -> [String: Any]? {
            lock.lock(); defer { lock.unlock() }
            let cur: (value: Any?, error: String?) = file.readChecked()
            if cur.error != nil { return nil }
            var d: [String: Any] = (cur.value as? [String: Any]) ?? [:]
            guard let qa = (d["quotes_at"] as? String), let qd = ISO8601DateFormatter().date(from: qa) else { return nil }
            let cal: Calendar = gmtCal()
            let wd: Int = cal.component(.weekday, from: qd)
            let mins: Int = cal.component(.hour, from: qd) * 60 + cal.component(.minute, from: qd)
            let df: DateFormatter = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "GMT"); df.dateFormat = "yyyy-MM-dd"
            let day: String = df.string(from: qd)
            if !force {
                if wd < 2 || wd > 6 || mins < 15 * 60 + 30 { return nil }   // jour de séance, relevé ≥ 15:30 GMT
                if let old = d["cloture"] as? [String: Any], (old["day"] as? String) == day { return nil }
            }
            guard let c = computeCloture(d, day: day, manuel: force) else { return nil }
            d["cloture"] = c
            guard file.write(d) else { return nil }
            publishCloture(c)
            return c
        }
        func scan() -> Int {
            try? FileManager.default.createDirectory(atPath: watch, withIntermediateDirectories: true)
            let mark = VaultFile("vault_portefeuilles_vus.json"); var seen = mark.read(default: [String: Double]())
            var n = 0
            let dirs = [watch] + (FileManager.default.fileExists(atPath: home + "/spark-local/Nova2/releves") ? [home + "/spark-local/Nova2/releves"] : [])
            for dir in dirs { for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where (f.lowercased().hasSuffix(".pdf") || f.lowercased().hasSuffix(".json")) && !f.hasPrefix("_") {
                let p = dir + "/" + f; let mt = ((try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                if seen[f] == mt { continue }
                if f.lowercased().hasSuffix(".json") {
                    if let dt = FileManager.default.contents(atPath: p), let j = (try? JSONSerialization.jsonObject(with: dt)) as? [String: Any], storeManual(j, source: f) == nil { n += 1; seen[f] = mt }
                } else if ingest(path: p) == nil { n += 1; seen[f] = mt }
            } }
            mark.write(seen); return n
        }
        // mise à jour continue : dossier toutes les 60 s, cours BRVM toutes les 60 s en séance (lun–ven 9h–16h UTC), 30 min sinon
        Thread.detachNewThread {
            var tick = 0
            while true {
                Thread.sleep(forTimeInterval: 60); tick += 1
                guard VaultSession.shared.isOpen() else { continue }   // V3 COFFRE : coffre fermé = ni lecture ni écriture ; les relevés déposés entre-temps sont lus à la prochaine ouverture
                _ = scan()
                var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
                let w = c.component(.weekday, from: Date()), h = c.component(.hour, from: Date())
                let session = w >= 2 && w <= 6 && h >= 9 && h < 16
                if tick % (session ? 1 : 30) == 0 { _ = refresh() }   // séance : cours BRVM toutes les 60 s ; hors séance : toutes les 30 min
                _ = maybeCloture(force: false)   // LOT E : fige la clôture dès qu'un relevé de fin de séance est en coffre
            }
        }
        s.on("GET", "/api/portfolio") { req, res in
            guard valid(req) else { res.json(["error": "coffre verrouillé"], status: 423); return }
            let cur: (value: Any?, error: String?) = file.readChecked()
            if let e = cur.error { res.json(["error": "coffre : " + e, "watch": watch], status: 500); return }
            var d: [String: Any] = (cur.value as? [String: Any]) ?? [:]; d["watch"] = watch; res.json(d)
        }
        s.on("POST", "/api/portfolio/import") { req, res in
            guard valid(req) else { res.json(["error": "coffre verrouillé"], status: 423); return }
            var path = (req.json["path"] as? String) ?? ""; if path.hasPrefix("~") { path = home + path.dropFirst() }
            guard path.hasPrefix(home + "/"), path.lowercased().hasSuffix(".pdf") else { res.json(["error": "chemin refusé (PDF dans ton dossier personnel)"], status: 400); return }
            if let e = ingest(path: path) { res.json(["error": e], status: 400); return }
            _ = refresh(); res.json(["ok": true])
        }
        s.on("POST", "/api/portfolio/manual") { req, res in
            guard valid(req) else { res.json(["error": "coffre verrouillé"], status: 423); return }
            if let e = storeManual(req.json, source: "saisie") { res.json(["error": e], status: 400); return }
            _ = refresh(); res.json(["ok": true])
        }
        s.on("POST", "/api/portfolio/refresh") { req, res in
            guard valid(req) else { res.json(["error": "coffre verrouillé"], status: 423); return }
            let n = scan(); let (q, e) = refresh(); if let e = e { res.json(["error": e], status: 502) } else { res.json(["ok": true, "quotes": q, "new_files": n] as [String: Any]) }
        }
        s.on("POST", "/api/portfolio/cloture") { req, res in   // LOT E : relevé manuel (fige depuis les cours stockés), coffre seulement
            guard valid(req) else { res.json(["error": "coffre verrouillé"], status: 423); return }
            _ = refresh()
            if let c = maybeCloture(force: true) { res.json(["ok": true, "cloture": c] as [String: Any]) }
            else { res.json(["error": "relevé impossible (aucun cours stocké ou aucune position)"], status: 400) }
        }
        s.on("POST", "/api/portfolio/remove") { req, res in
            guard valid(req) else { res.json(["error": "coffre verrouillé"], status: 423); return }
            lock.lock()
            let cur: (value: Any?, error: String?) = file.readChecked()
            if let e = cur.error { lock.unlock(); res.json(["error": "coffre : " + e], status: 500); return }
            var d: [String: Any] = (cur.value as? [String: Any]) ?? [:]; var a = (d["accounts"] as? [String: Any]) ?? [:]; a.removeValue(forKey: (req.json["account"] as? String) ?? ""); d["accounts"] = a
            let ok: Bool = file.write(d); lock.unlock()
            if !ok { res.json(["error": "coffre : écriture refusée (" + VaultCrypto.errorText() + ")"], status: 500); return }
            res.json(["ok": true])
        }
    }
}
