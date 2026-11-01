import Foundation

// LOT J (28/10/2026) — CARTE DES SIGNAUX SAHEL SCORÉS.
//
// Les articles du radar (VeillePole.radar) sont géolocalisés par nom de lieu
// sur un répertoire sahélien (capitales + foyers suivis, coordonnées de
// référence) puis scorés de façon MÉCANIQUE et relisible : gravité lexicale
// du titre (attaque, morts, déplacés…) × fraîcheur × nombre de signaux.
// Aucun cerveau, aucune coordonnée inventée : un lieu absent du répertoire
// n'apparaît pas sur la carte (il reste dans le fil et la carte par pays).
// Repli pays : si seul le pays est cité, le point tombe sur sa capitale,
// marqué « pays ». Route : GET /api/veille/carte?jours=14.

public enum CarteSahel {
    // (nom, pays, lat, lon) — ordre : les noms longs d'abord à la recherche.
    static let lieux: [(String, String, Double, Double)] = [
        ("Ouagadougou", "Burkina Faso", 12.37, -1.52), ("Bobo-Dioulasso", "Burkina Faso", 11.18, -4.29),
        ("Ouahigouya", "Burkina Faso", 13.58, -2.42), ("Djibo", "Burkina Faso", 14.10, -1.63),
        ("Gorom-Gorom", "Burkina Faso", 14.45, -0.23), ("Dori", "Burkina Faso", 14.03, -0.03),
        ("Kaya", "Burkina Faso", 13.09, -1.08), ("Fada N'Gourma", "Burkina Faso", 12.06, 0.36),
        ("Barsalogho", "Burkina Faso", 13.41, -1.05), ("Titao", "Burkina Faso", 13.77, -2.08),
        ("Bogandé", "Burkina Faso", 12.97, -0.14), ("Dédougou", "Burkina Faso", 12.47, -3.47),
        ("Bamako", "Mali", 12.64, -8.00), ("Tombouctou", "Mali", 16.77, -3.01),
        ("Gao", "Mali", 16.27, -0.04), ("Ménaka", "Mali", 15.92, 2.40),
        ("Kidal", "Mali", 18.44, 1.41), ("Mopti", "Mali", 14.48, -4.18),
        ("Sévaré", "Mali", 14.53, -4.10), ("Bandiagara", "Mali", 14.35, -3.61),
        ("Douentza", "Mali", 15.00, -2.95), ("Ansongo", "Mali", 15.67, 0.50),
        ("Sikasso", "Mali", 11.32, -5.67), ("Koutiala", "Mali", 12.39, -5.46),
        ("Niamey", "Niger", 13.51, 2.11), ("Agadez", "Niger", 16.97, 7.99),
        ("Diffa", "Niger", 13.32, 12.61), ("Tillabéri", "Niger", 14.21, 1.45),
        ("Tahoua", "Niger", 14.89, 5.26), ("Maradi", "Niger", 13.50, 7.10),
        ("Zinder", "Niger", 13.80, 8.99), ("Téra", "Niger", 14.01, 0.75),
        ("Ayorou", "Niger", 14.73, 0.92), ("Ouallam", "Niger", 14.32, 2.09),
        ("Banibangou", "Niger", 15.04, 2.71), ("Abala", "Niger", 14.93, 3.43),
        ("N'Djamena", "Tchad", 12.13, 15.06), ("Abéché", "Tchad", 13.83, 20.83),
        ("Bol", "Tchad", 13.46, 14.71), ("Baga Sola", "Tchad", 13.54, 14.31),
        ("Maiduguri", "Nigéria", 11.83, 13.15), ("Sokoto", "Nigéria", 13.06, 5.24),
        ("Kano", "Nigéria", 12.00, 8.52), ("Kaduna", "Nigéria", 10.51, 7.44),
        ("Abuja", "Nigéria", 9.08, 7.40), ("Gusau", "Nigéria", 12.17, 6.66),
        ("Khartoum", "Soudan", 15.59, 32.53), ("Port-Soudan", "Soudan", 19.62, 37.22),
        ("El Fasher", "Soudan", 13.62, 25.35), ("Nyala", "Soudan", 12.05, 24.88),
        ("Geneina", "Soudan", 13.45, 22.45), ("Abyei", "Soudan", 9.60, 28.42),
        ("Juba", "Soudan du Sud", 4.86, 31.57), ("Dakar", "Sénégal", 14.72, -17.47),
        ("Nouakchott", "Mauritanie", 18.09, -15.95), ("Cotonou", "Bénin", 6.37, 2.43),
        ("Abidjan", "Côte d'Ivoire", 5.36, -4.01), ("Accra", "Ghana", 5.60, -0.19),
    ]
    // Capitale de repli quand seul le pays est cité.
    static let capitales: [String: (String, Double, Double)] = [
        "Burkina Faso": ("Ouagadougou", 12.37, -1.52), "Mali": ("Bamako", 12.64, -8.00),
        "Niger": ("Niamey", 13.51, 2.11), "Tchad": ("N'Djamena", 12.13, 15.06),
        "Nigéria": ("Abuja", 9.08, 7.40), "Nigeria": ("Abuja", 9.08, 7.40),
        "Soudan": ("Khartoum", 15.59, 32.53), "Soudan du Sud": ("Juba", 4.86, 31.57),
        "Sénégal": ("Dakar", 14.72, -17.47), "Mauritanie": ("Nouakchott", 18.09, -15.95),
        "Bénin": ("Cotonou", 6.37, 2.43), "Côte d'Ivoire": ("Abidjan", 5.36, -4.01),
        "Ghana": ("Accra", 5.60, -0.19), "Cameroun": ("Yaoundé", 3.85, 11.50),
        "Centrafrique": ("Bangui", 4.39, 18.56), "Éthiopie": ("Addis-Abeba", 9.03, 38.74),
        "Kenya": ("Nairobi", -1.29, 36.82), "Somalie": ("Mogadiscio", 2.04, 45.34),
    ]
    static let gravite: [(String, Double)] = [
        ("massacre", 3.0), ("attentat", 3.0), ("attaque", 2.6), ("tuent", 2.6), ("tues", 2.6),
        ("morts", 2.6), ("kill", 2.6), ("dead", 2.2), ("famine", 2.4), ("deplaces", 2.2),
        ("displaced", 2.2), ("enlevement", 2.2), ("kidnap", 2.2), ("epidemie", 2.0),
        ("ebola", 2.2), ("cholera", 2.0), ("affrontement", 1.8), ("clash", 1.8),
        ("blesses", 1.6), ("inondation", 1.8), ("flood", 1.8), ("secheresse", 1.6),
        ("crise", 1.2), ("aide humanitaire", 0.8), ("distribution", 0.6), ("accord", 0.5),
    ]

    static func foldKey(_ s: String) -> String { VeillePole.fold(s) }

    public static func carte(settings: Settings, jours: Int) -> [String: Any] {
        let r: [String: Any] = VeillePole.radar(settings: settings, days: jours)
        let items: [[String: Any]] = (r["items"] as? [[String: Any]]) ?? []
        let nowTs: Double = Date().timeIntervalSince1970
        let lieuxTries: [(String, String, Double, Double)] = lieux.sorted { $0.0.count > $1.0.count }
        var agg: [String: [String: Any]] = [:]   // clé = lieu
        var sansLieu: Int = 0
        for it in items {
            let title: String = (it["title"] as? String) ?? ""
            let brief: String = (it["brief"] as? String) ?? ""
            let hay: String = foldKey(title + " " + String(brief.prefix(300)))
            let ts: Double = (it["ts"] as? Double) ?? ((it["ts"] as? NSNumber)?.doubleValue ?? 0)
            // Gravité lexicale (titre surtout, sur le texte plié).
            var g: Double = 1.0
            for (mot, poids) in gravite where hay.contains(mot) { g += poids }
            // Fraîcheur.
            let ageJ: Double = ts > 0 ? max(0, (nowTs - ts) / 86400) : 7
            let frais: Double = ageJ <= 3 ? 1.5 : (ageJ <= 7 ? 1.2 : 1.0)
            let poidsSignal: Double = g * frais
            // Lieu : nom le plus long présent ; sinon capitale du premier pays cité.
            var found: (String, String, Double, Double, Bool)? = nil
            for (nom, pays, lat, lon) in lieuxTries where hay.contains(foldKey(nom)) {
                found = (nom, pays, lat, lon, false); break
            }
            if found == nil {
                for c in (it["countries"] as? [String]) ?? [] {
                    if let cap = capitales[c] { found = (cap.0, c, cap.1, cap.2, true); break }
                }
            }
            guard let f = found else { sansLieu += 1; continue }
            let cle: String = f.0
            var a: [String: Any] = agg[cle] ?? ["lieu": f.0, "pays": f.1, "lat": f.2, "lon": f.3, "pays_seul": f.4,
                                                "signaux": 0, "score_brut": 0.0, "dernier_ts": 0.0, "titres": [String]()] as [String: Any]
            a["signaux"] = ((a["signaux"] as? Int) ?? 0) + 1
            a["score_brut"] = ((a["score_brut"] as? Double) ?? 0) + poidsSignal
            if ts > ((a["dernier_ts"] as? Double) ?? 0) { a["dernier_ts"] = ts }
            var titres: [String] = (a["titres"] as? [String]) ?? []
            if titres.count < 3 && !title.isEmpty { titres.append(String(title.prefix(140))); a["titres"] = titres }
            agg[cle] = a
        }
        let maxBrut: Double = agg.values.map { ($0["score_brut"] as? Double) ?? 0 }.max() ?? 0
        var points: [[String: Any]] = agg.values.map { a in
            var p: [String: Any] = a
            let brut: Double = (a["score_brut"] as? Double) ?? 0
            p["score"] = maxBrut > 0 ? Int((brut / maxBrut * 100).rounded()) : 0
            p.removeValue(forKey: "score_brut")
            return p
        }
        points.sort { (($0["score"] as? Int) ?? 0) > (($1["score"] as? Int) ?? 0) }
        let okSrc: Int = ((r["sources"] as? [[String: Any]]) ?? []).filter { ($0["ok"] as? Bool) == true }.count
        return ["generated": nowISO(), "window_days": jours, "points": Array(points.prefix(40)),
                "signaux_lus": items.count, "signaux_sans_lieu": sansLieu, "sources_ok": okSrc,
                "bbox": ["lon_min": -20.0, "lon_max": 40.0, "lat_min": -3.0, "lat_max": 28.0],
                "note": "Score mécanique : gravité des mots du titre × fraîcheur × nombre de signaux, normalisé à 100. Lieux du répertoire sahélien de Nova ; repli sur la capitale quand seul le pays est cité. Carte schématique en grille lat/long, sans frontières."] as [String: Any]
    }

    static func nowISO() -> String { ISO8601DateFormatter().string(from: Date()) }
}

extension NovaApp {
    func carteSahelRoutes() {
        server.on("GET", "/api/veille/carte") { [self] req, res in
            let jours: Int = min(30, max(3, Int(req.query["jours"] ?? "") ?? 14))
            res.json(CarteSahel.carte(settings: settings, jours: jours))
        }
    }
}
