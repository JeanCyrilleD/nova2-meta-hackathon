import Foundation

/// Marché de Dots : paquets prêts à installer (Pack Sahel…), export/import de Dots signés par empreinte, Cap du jour, relevé mobile money en lecture seule.
enum DotPacks {
    static let sahel: [[String: Any]] = [
        ["id": "capdujour", "name": "Cap du jour", "emoji": "🧭", "color": "#f5c542", "role": "Chaque matin, tes 3 priorités du jour tirées de tes mails, de ton agenda, de tes rappels et de tes Dots. Lecture seule.",
         "tools": ["mail_unread", "calendar", "reminders", "recall", "know", "momo"], "brain": "auto", "schedule": "lun-sam 07:15",
         "prompt": "Prépare le CAP DU JOUR à partir de DONNÉES RÉELLES uniquement. Étape 1 : appelle mail_unread, calendar, reminders, momo, recall (un appel chacun). Si un outil renvoie une erreur, un délai dépassé ou rien, note-le : « source indisponible : <nom> » ; ne comble jamais le vide. Étape 2 : si au moins une source contient des éléments, donne jusqu'à 3 priorités numérotées (moins de 3 s'il n'y a pas matière). Chaque priorité doit CITER sa preuve entre crochets : [mail : expéditeur — objet exact] ou [agenda : titre — heure] ou [rappel : titre] ou [momo : libellé — échéance] ou [mémoire : fait]. Une priorité sans preuve citée est interdite. Format : verbe d'action + pourquoi maintenant (uniquement ce que la preuve dit) + prochaine action de 10 minutes réalisable avec les seules données lues (n'invente ni site, ni outil, ni contact, ni chiffre). Étape 3 : ligne « Sources lues : … / indisponibles : … ». Si TOUTES les sources sont vides ou indisponibles, réponds seulement : « Cap du jour impossible : <raisons>. » Aucun conseil d'investissement ni d'achat. N'envoie rien."],
        ["id": "radar-humanitaire", "name": "Radar humanitaire", "emoji": "🛰️", "color": "#38bdf8", "role": "Veille des alertes et appels d'offres humanitaires (Sahel, Burkina Faso) : ReliefWeb, OCHA, ONU. Sources datées, aucun envoi.",
         "tools": ["web_search", "web_fetch", "recall", "remember", "flux_titres"], "brain": "auto", "schedule": "lun-ven 07:00,16:00",
         "prompt": "Radar humanitaire Sahel / Burkina Faso — faits datés uniquement. Étape 1 : flux_titres avec « Burkina Faso Sahel humanitaire » (flux ReliefWeb/OCHA déjà classés par date). Étape 2 : web_search puis web_fetch sur reliefweb.int, unocha.org ou humanitarianresponse.info pour les appels à propositions / offres ouverts et les mouvements de population. Règles : ne retiens une alerte que si sa date figure dans la source ET date de moins de 72 h (compare à la date du jour fournie par l'outil) ; les liens viennent EXCLUSIVEMENT des résultats d'outils, jamais de ta mémoire ; un fait sans date ou sans lien est écarté. Pour chaque point : titre, date, lien, en une phrase pourquoi cela compte pour une ONG basée à Ouagadougou. Maximum 6 points classés par urgence. Si une source est injoignable, dis-le ; si rien de récent : « RAS (sources lues : …) »."],
        ["id": "brief-audio", "name": "Brief audio du matin", "emoji": "🎧", "color": "#a78bfa", "role": "Ton brief du matin rédigé pour être ÉCOUTÉ : court, parlé, sans symboles. Lu à voix haute par Nova.",
         "tools": ["mail_unread", "calendar", "reminders", "recall", "web_search"], "brain": "auto", "schedule": "lun-sam 07:30", "speak": true,
         "prompt": "Rédige un brief oral de 90 secondes maximum (environ 220 mots), en phrases courtes, sans listes, sans symboles, sans URL, comme si tu parlais à Capitaine au café. Lis d'abord calendar, mail_unread et reminders. Ordre : la date du jour, l'agenda du jour, les mails urgents (expéditeur et sujet réels), UN point de veille important trouvé par web_search (avec son média et sa date dite à l'oral). Pas de météo sauf si web_search la donne ; ne cite aucun chiffre non lu. Si une source est indisponible, dis-le en une phrase courte au lieu de l'inventer. Termine par « Voici ton cap : » suivie de la première priorité fondée sur ce que tu as lu. Aucun conseil d'investissement."],
        ["id": "brvm-dividendes", "name": "BRVM & dividendes", "emoji": "💹", "color": "#22c55e", "role": "Alertes factuelles BRVM : variations fortes, dividendes annoncés, dates de détachement. Information seulement, jamais d'ordre ni de conseil.",
         "tools": ["brvm_cours", "web_search", "web_fetch", "recall", "know", "momo"], "brain": "auto", "schedule": "lun-ven 09:45,16:45",
         "prompt": "Alertes BRVM — FAITS, jamais de conseil. Étape 1 : brvm_cours (cours officiels du bandeau brvm.org, éventuellement différés : cite l'heure « quotes_at » et l'erreur éventuelle). Étape 2 : signale les titres dont la variation du jour est de ±5 % ou plus, en priorité ceux de la liste « watch » de l'outil ou de ma mémoire (recall). Étape 3 : dividendes — d'abord ceux enregistrés par l'utilisateur dans l'outil (champ dividends, à dire « saisi par toi »), puis ceux annoncés dans les 30 jours trouvés par web_search + web_fetch (brvm.org, sikafinance.com, richbourse.com) : titre, montant, date de détachement et de paiement, SOURCE avec lien tiré des résultats. Un chiffre qui ne vient pas d'un outil est interdit ; si brvm_cours échoue, dis « cours indisponibles » et arrête les alertes de variation. Format : titre, fait, date, source. Aucun ordre, aucun « acheter/vendre/renforcer/conserver », aucune cible de prix. Si rien de notable : « RAS »."],
        ["id": "momo-releve", "name": "Relevé mobile money", "emoji": "📲", "color": "#fb923c", "role": "Analyse en lecture seule un relevé mobile money que TU colles ou importes (Orange, Moov, Wave) : entrées, sorties, frais, plus grosses dépenses. Ne se connecte à rien et ne fait aucun ordre.",
         "tools": ["recall", "momo"], "brain": "auto", "schedule": "",
         "prompt": "Quand l'utilisateur te donne un relevé (SMS ou CSV), appelle l'outil momo avec l'argument « releve|<texte exact du relevé> » : il calcule lui-même entrées, sorties, frais et plus grosses sorties ; recopie CES chiffres, ne recalcule rien de tête. Résume : total entrées, total sorties, frais payés, 3 plus grosses opérations, tendance. Jamais d'opération, jamais de code secret."],
    ]
    static let packs: [[String: Any]] = [
        ["id": "sahel", "name": "Pack Sahel", "desc": "Cap du jour, radar humanitaire, brief audio, BRVM & dividendes, relevé mobile money. Tout en lecture seule : aucun envoi, aucun paiement, aucun ordre.", "dots": sahel]
    ]
    static let risky: Set<String> = ["shell", "applescript", "app", "open", "read_file", "ui", "forge_tool", "phone"]

    /// Analyse un relevé mobile money collé (SMS ou CSV Orange / Moov / Wave) : lecture seule, rien n'est exécuté ni conservé hors du Mac.
    /// Une ligne = une opération : le montant principal est classé entrée / sortie ; les frais sont comptés à part ; le « solde » n'est jamais un mouvement ;
    /// une DEMANDE (« veuillez envoyer… », code, PIN) n'est pas une opération et est ignorée.
    static func amount(_ raw: String) -> Int? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"[\.,]\d{1,2}$"#, options: .regularExpression) { t = String(t[..<r.lowerBound]) }   // décimales (1 500,50)
        let d = t.filter { $0.isNumber }; guard let v = Int(d), v > 0 else { return nil }; return v
    }
    static func releve(_ text: String) -> [String: Any] {
        var inn = 0, out = 0, fees = 0, ignored = 0; var rows: [[String: Any]] = []
        let amountRx = try! NSRegularExpression(pattern: #"(\d[\d\s\.,]{0,12})\s*(?:FCFA|F\s?CFA|XOF|CFA|F)\b"#, options: .caseInsensitive)
        let numRx = try! NSRegularExpression(pattern: #"^\s*\d[\d\s\.,]*$"#)
        func fold(_ x: String) -> String { x.lowercased().folding(options: .diacriticInsensitive, locale: nil) }
        func classify(_ low: String) -> String {
            if ["recu", "reception", "depot", "entree", "credite", "vous avez recu", "encaisse"].contains(where: { low.contains($0) }) { return "entrée" }
            if ["envoye", "envoi", "transfert", "retrait", "paiement", "achat", "debit", "facture", "sortie", "paye"].contains(where: { low.contains($0) }) { return "sortie" }
            return "autre"
        }
        func add(_ kind: String, _ v: Int, _ fee: Int, _ line: String) {
            if kind == "entrée" { inn += v } else if kind == "sortie" { out += v }
            fees += fee
            rows.append(["type": kind, "montant": v, "frais": fee, "ligne": String(line.prefix(140))])
        }
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // CSV : première ligne d'en-têtes contenant « montant » (ou amount)
        if let h = lines.first, fold(h).contains("montant") || fold(h).contains("amount"), h.contains(",") || h.contains(";") {
            let sep: Character = h.contains(";") ? ";" : ","
            let cols = h.split(separator: sep, omittingEmptySubsequences: false).map { fold(String($0)).trimmingCharacters(in: .whitespaces) }
            let iM = cols.firstIndex { $0.contains("montant") || $0.contains("amount") }, iT = cols.firstIndex { $0.contains("type") || $0.contains("operation") || $0.contains("libelle") || $0.contains("description") }
            let iF = cols.firstIndex { $0.contains("frais") || $0.contains("fee") }, iS = cols.firstIndex { $0.contains("sens") || $0.contains("direction") }
            for l in lines.dropFirst() {
                let f = l.split(separator: sep, omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
                guard let m = iM, m < f.count, let v = amount(f[m].replacingOccurrences(of: "FCFA", with: "").replacingOccurrences(of: "XOF", with: "")) else { continue }
                var low = fold([iT, iS].compactMap { $0 }.filter { $0 < f.count }.map { f[$0] }.joined(separator: " "))
                if low.isEmpty { low = fold(l) }
                let fee = (iF.flatMap { $0 < f.count ? amount(f[$0]) : nil }) ?? 0
                if low.contains("frais") || low.contains("commission") { add("frais", v, 0, l); fees += v; rows[rows.count - 1]["frais"] = 0; inn += 0; continue }
                add(classify(low), v, fee, l)
            }
        } else {
            for l in lines where l.count > 6 {
                let low = fold(l)
                if ["veuillez", "saisissez", "composez", "code secret", "votre code", "pin ", "confirmez", "cliquez", "gagnez", "promo"].contains(where: { low.contains($0) }) { ignored += 1; continue }
                let ns = l as NSString
                var ms = amountRx.matches(in: l, range: NSRange(location: 0, length: ns.length))
                ms = ms.filter { m in   // le solde n'est pas un mouvement
                    let pre = ns.substring(to: m.range.location).lowercased().folding(options: .diacriticInsensitive, locale: nil); return !pre.suffix(18).contains("solde")
                }
                guard let first = ms.first else { continue }
                let cut = low.range(of: #"frais|commission"#, options: .regularExpression)
                if let c = cut, low.distance(from: low.startIndex, to: c.lowerBound) <= 2 {   // ligne de frais pure
                    if let v = amount(ns.substring(with: first.range(at: 1))) { fees += v; rows.append(["type": "frais", "montant": v, "frais": 0, "ligne": String(l.prefix(140))]) }
                    continue
                }
                guard let v = amount(ns.substring(with: first.range(at: 1))) else { continue }
                var fee = 0
                if let c = cut {   // montant de frais cité après le mot « frais » / « commission »
                    let off = low.distance(from: low.startIndex, to: c.upperBound)
                    if let fm = ms.first(where: { $0.range.location >= off }), let fv = amount(ns.substring(with: fm.range(at: 1))) { fee = fv }
                }
                let head = cut.map { String(low[..<$0.lowerBound]) } ?? low
                add(classify(head.isEmpty ? low : head), v, fee, l)
            }
        }
        _ = numRx
        let top = rows.filter { $0["type"] as? String == "sortie" }.sorted { ($0["montant"] as? Int ?? 0) > ($1["montant"] as? Int ?? 0) }.prefix(3)
        return ["lignes": rows.count, "ignorees": ignored, "entrees": inn, "sorties": out, "frais": fees, "solde_periode": inn - out - fees, "plus_grosses_sorties": Array(top), "devise": "FCFA",
                "note": "Lecture seule : Nova n'effectue aucune opération et ne se connecte à aucun opérateur. Les demandes (« veuillez envoyer… », codes) sont ignorées."]
    }
}

extension NovaApp {
    /// Met à jour (une seule fois par révision) la consigne, le rôle et les outils des Dots du Pack déjà installés ; l'horaire et le cerveau choisis par l'utilisateur sont conservés.
    func refreshPackDots() {
        let rev = 2
        for d in DotPacks.sahel {
            guard let id = d["id"] as? String, var cur = dots.list().first(where: { ($0["id"] as? String) == id }), (cur["pack_rev"] as? Int ?? 0) < rev else { continue }
            cur.removeValue(forKey: "persona")
            for k in ["prompt", "role", "tools"] { if let v = d[k] { cur[k] = v } }
            cur["pack_rev"] = rev; dots.save(cur)
        }
    }
    func packRoutes() {
        let s = server
        refreshPackDots()
        s.on("GET", "/api/packs") { [self] _, res in
            let have = Set(dots.list().compactMap { $0["id"] as? String })
            res.json(["items": DotPacks.packs.map { p -> [String: Any] in
                let ds = (p["dots"] as? [[String: Any]]) ?? []
                return ["id": p["id"] as Any, "name": p["name"] as Any, "desc": p["desc"] as Any,
                        "dots": ds.map { ["id": $0["id"] as Any, "name": $0["name"] as Any, "emoji": $0["emoji"] as Any, "role": $0["role"] as Any, "installed": have.contains($0["id"] as? String ?? ""), "tools": $0["tools"] as Any] }]
            }])
        }
        s.on("POST", "/api/packs/install") { [self] req, res in
            guard let p = DotPacks.packs.first(where: { ($0["id"] as? String) == (req.json["id"] as? String) }) else { res.json(["error": "Pack inconnu"], status: 404); return }
            let have = Set(dots.list().compactMap { $0["id"] as? String }); var added: [String] = []
            for d in (p["dots"] as? [[String: Any]]) ?? [] { if let id = d["id"] as? String, !have.contains(id) { dots.save(d); added.append(id) } }
            BlackBox.record(["id": String(UUID().uuidString.prefix(8)).lowercased(), "tool": "pack_install", "input": p["id"] as? String ?? "", "actor": "Toi", "effect": "écrit", "ok": true, "result": "installés : " + added.joined(separator: ", ")])
            res.json(["ok": true, "added": added])
        }
        // Export d'un Dot partageable (.novadot) : empreinte SHA-256 du contenu, outils à risque signalés ; l'import existant (/api/dots/import) ne remplace jamais sans accord.
        s.on("GET", "/api/dots/export") { [self] req, res in
            guard var d = dots.list().first(where: { ($0["id"] as? String) == (req.query["id"] ?? "") }) else { res.json(["error": "Dot introuvable"], status: 404); return }
            d.removeValue(forKey: "persona")
            let tools = (d["tools"] as? [String]) ?? []
            res.json(["format": "novadot-v1", "exported": nowISO(), "dot": d, "sha256": Sha.hash(BlackBox.canonical(d)), "risky_tools": tools.filter { DotPacks.risky.contains($0) }])
        }
        // Import d'un Dot partagé (.novadot) : l'empreinte doit correspondre ; le Dot arrive sous l'id « imp-… », jamais en remplacement, outils à risque signalés à l'écran.
        s.on("POST", "/api/dots/importpack") { [self] req, res in
            guard (req.json["format"] as? String) == "novadot-v1", var d = req.json["dot"] as? [String: Any], let sum = req.json["sha256"] as? String else { res.json(["error": "Fichier .novadot invalide."], status: 400); return }
            guard Sha.hash(BlackBox.canonical(d)) == sum else { res.json(["error": "Empreinte incorrecte : le fichier a été modifié depuis son export. Import refusé."], status: 400); return }
            var id = (d["id"] as? String) ?? "dot"; if !id.hasPrefix("imp-") { id = "imp-" + id }
            if dots.list().contains(where: { ($0["id"] as? String) == id }) { res.json(["error": "Un Dot « \(id) » existe déjà : rien n'est remplacé."], status: 409); return }
            d["id"] = id; d["imported"] = nowISO()
            let risky = ((d["tools"] as? [String]) ?? []).filter { DotPacks.risky.contains($0) }
            dots.save(d)
            BlackBox.record(["id": String(UUID().uuidString.prefix(8)).lowercased(), "tool": "dot_import", "input": id, "actor": "Toi", "effect": "écrit", "ok": true, "result": "outils à risque : " + (risky.isEmpty ? "aucun" : risky.joined(separator: ", "))])
            res.json(["ok": true, "id": id, "risky_tools": risky])
        }
        s.on("POST", "/api/momo/releve") { req, res in res.json(DotPacks.releve((req.json["text"] as? String) ?? "")) }
        // Cap du jour : dernier résultat du Dot « capdujour »
        s.on("GET", "/api/cap") { [self] _, res in
            let installed = dots.list().contains { ($0["id"] as? String) == "capdujour" }
            let last = dots.history("capdujour").first
            res.json(["installed": installed, "last": last as Any? ?? NSNull()])
        }
        // Dots actifs maintenant (anneaux dorés de Singularity)
        s.on("GET", "/api/dots/active") { [self] _, res in res.json(["items": scheduler.activeIds(), "all": dots.list().compactMap { $0["id"] as? String }]) }
    }
}
