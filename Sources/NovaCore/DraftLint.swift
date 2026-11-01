import Foundation

/// P-DRAFT-1 — Coche MÉCANIQUE des brouillons (formats verrouillés d'Ahadi : gabarit mail CAFU
/// du 05/10 + politesse du 12/10, standard Teams, posture opt-out). Aucune appréciation : des
/// règles de forme testables sur le corps stocké, le même d'un bout à l'autre (création →
/// aperçu → envoi). Un item « dur » en échec n'empêche ni la création ni l'édition du
/// brouillon — il bloque l'ENVOI (P-DRAFT-3) et s'affiche sur la carte (P-DRAFT-6).
/// L'empreinte (hash) lie l'aperçu montré à ce qui part : FNV-1a, même fonction que
/// Constitution.hash, sur destinataire/cible + objet + corps.
public enum DraftLint {

    public struct Item {
        public let key: String
        public let label: String
        public let ok: Bool
        public let hard: Bool
        public let detail: String
        public func dict() -> [String: Any] { ["key": key, "label": label, "ok": ok, "hard": hard, "detail": detail] }
    }

    // ── Empreinte ────────────────────────────────────────────────────────────
    public static func hash(_ d: [String: Any]) -> String {
        let who = (d["channel"] as? String) == "teams" ? ((d["target"] as? String) ?? "") : ((d["to"] as? String) ?? "")
        return Constitution.hash(who + "\u{1F}" + ((d["subject"] as? String) ?? "") + "\u{1F}" + ((d["body"] as? String) ?? ""))
    }

    /// Recalcule lint + hash d'un brouillon (dict) et les y inscrit. Renvoie le dict enrichi.
    @discardableResult
    public static func refresh(_ d: inout [String: Any]) -> [String: Any] {
        let items = items(of: d)
        d["lint"] = ["items": items.map { $0.dict() }, "ok": !items.contains { $0.hard && !$0.ok }]
        d["hash"] = hash(d)
        return d
    }

    public static func hardFailures(_ d: [String: Any]) -> [Item] { items(of: d).filter { $0.hard && !$0.ok } }

    // ── Lexiques (forme, pas de jugement de fond) ────────────────────────────
    static let optOuts = ["no obligation", "feel free", "whenever suits", "whenever useful", "say the word", "no rush",
                          "please let me know", "let me know if", "does not suit", "not suit you", "at your convenience", "no pressure",
                          "sans obligation", "libre de refuser", "libre de dire non", "à ta convenance",
                          "a ta convenance", "si ta capacité", "si votre capacité", "si ton agenda"]
    static let politesses = ["i hope you're well", "i hope you are well", "j'espère que vous allez bien",
                             "j'espère que tu vas bien", "en espérant que vous allez bien"]
    // FIX-LINT : l'action requise du gabarit peut être un engagement de l'expéditeur
    // (« je t'envoie … avant 18 h ») quand le prochain pas est côté Ahadi — formes attestées
    // en magasin (recette 3E) que l'infinitif « envoyer » ne couvrait pas.
    static let actionMarks = ["please", "merci de", "avant le", "avant la", "d'ici", "pour le", "pour la",
                              "échéance", "deadline", "confirm", "valider", "signer", "envoyer", "partager", "revenir vers",
                              "je t'envoie", "je vous envoie", "je t'enverrai", "je vous enverrai"]
    // FIX-REVUE R-3 : éléments de SORTIE réelle, exigés en plus du couple préférence +
    // invitation dans la branche construite d'optOutForme — refus, arrêt des envois ou du
    // canal (« ne passent plus par mail » = forme attestée en magasin, d1792616916013),
    // alternative de format/horaire/canal. Sans l'un d'eux, « si tu préfères le matin ou
    // l'après-midi, dis-le-moi » n'offre qu'un choix d'horaire, pas une porte de sortie.
    static let optOutExits = ["ne pas recevoir", "ne plus recevoir", "autre format", "autre horaire", "autre canal",
                              "autre moyen", "refuser", "refus", "ne convient pas", "te convient pas", "vous convient pas",
                              "arrêter", "arreter", "arrête", "arrete", "ne passent plus", "ne passe plus"]

    // ── Utilitaires de lignes ────────────────────────────────────────────────
    static func lines(_ body: String) -> [String] {
        body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    static func isNumbered(_ s: String) -> Bool { s.count == 2 && s.allSatisfy { $0.isNumber } && s != "00" }
    static func hasBullet(_ body: String) -> Bool {
        body.components(separatedBy: "\n").contains { let t = $0.trimmingCharacters(in: .whitespaces); return t.hasPrefix("• ") || t.hasPrefix("- ") || t.hasPrefix("* ") }
    }
    static func hasEmoji(_ body: String) -> Bool {
        body.unicodeScalars.contains { $0.value >= 0x1F000 || (0x2600...0x27BF).contains(Int($0.value)) }
    }
    /// FIX-LINT2 (recette 3F, Bloc 9) — Repli des apostrophes typographiques : les corps
    /// rédigés en français soigné portent U+2019 (« J'espère ») là où les lexiques portent
    /// l'ASCII U+0027 (« j'espère », « d'ici ») — sans repli, `politesse` échoue sur la forme
    /// correcte (prouvé à l'octet : H30 0x2019 ✗ contre A1 0x27 ✓) et toute marque de
    /// lexique à apostrophe est exposée au même échec. On replie les DEUX côtés (texte et
    /// lexique) avant comparaison : l'opération est idempotente sur les entrées déjà ASCII
    /// et ne peut ni créer ni détruire un mot du lexique.
    static func folded(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2BC}", with: "'")
    }
    static func containsAny(_ s: String, _ lex: [String]) -> Bool { let l = folded(s); return lex.contains { l.contains(folded($0)) } }

    /// FIX-LINT (recette 3E, 21/10) — Reconnaissance d'un opt-out : le lexique canonique OU la
    /// forme construite attestée en magasin (optOutForme). Une seule règle pour la coche mail,
    /// la coche Teams et l'avertissement du formateur (Tools+CAFU) : sinon le formateur annonce
    /// « opt-out manquant » sur une forme que la coche accepte — ou l'inverse — et la porte se
    /// contredit elle-même (7 brouillons bloqués le 21/10 malgré des opt-out explicites).
    static func hasOptOut(_ s: String) -> Bool { containsAny(s, optOuts) || optOutForme(s) }

    /// Forme FR produite par le rédacteur, conforme à la charte (porte de sortie explicite) :
    /// construite en DEUX moitiés — une préférence énoncée (« si tu préfères… », « si vous
    /// préférez… ») ET l'invitation à le dire (« dis-le-moi », « dites-le-moi ») — ou un opt-out
    /// ÉTIQUETÉ « Opt-out : » porteur d'un refus ou d'une alternative (ne pas / ne plus recevoir,
    /// autre format, autre horaire, autre canal). Aucune moitié seule ne suffit : une simple
    /// préférence d'horaire sans porte de sortie, ou une étiquette sans contenu, échouent toujours.
    /// FIX-REVUE R-3 : le couple préférence + invitation ne suffit plus à lui seul — il faut
    /// AUSSI un élément de sortie réel (optOutExits) dans le même bloc, sinon un simple choix
    /// d'horaire traverse la coche (contre-exemple A1 de la revue). Et une alternative NIÉE
    /// n'est pas une sortie (« aucun autre format n'est possible », A2) : les formes niées
    /// sont neutralisées avant le test des éléments de sortie.
    /// FIX-LINT2 : le texte est replié (folded) avant tout test — une forme niée écrite avec
    /// l'apostrophe typographique (« pas d'autre… », U+2019) est neutralisée exactement comme
    /// son équivalent ASCII, et les littéraux de la fonction restent comparables au texte.
    static func optOutForme(_ s: String) -> Bool {
        let l = folded(s)
        let pref = l.contains("si tu préfères") || l.contains("si tu preferes") || l.contains("si vous préférez") || l.contains("si vous preferez")
        let dire = l.contains("dis-le-moi") || l.contains("dites-le-moi") || l.contains("dis-moi") || l.contains("dites-moi")
        let propre = l.replacingOccurrences(of: "aucun autre", with: "aucun")
                      .replacingOccurrences(of: "aucune autre", with: "aucune")
                      .replacingOccurrences(of: "pas d'autre", with: "pas de")
                      .replacingOccurrences(of: "nul autre", with: "nul")
        let sortie = containsAny(propre, optOutExits)
        if pref && dire && sortie { return true }
        if l.contains("opt-out") && (pref || sortie) { return true }
        return false
    }

    // ── La coche ─────────────────────────────────────────────────────────────
    public static func items(of d: [String: Any]) -> [Item] {
        let body = (d["body"] as? String) ?? ""
        if ((d["channel"] as? String) ?? "mail") == "teams" { return teamsItems(body: body, subject: (d["subject"] as? String) ?? "") }
        // 27/10 (cas vécu, plateforme anonymisée) : le gabarit CAFU complet était exigé pour TOUT mail,
        // y compris un courrier personnel externe en anglais validé tel quel par Ahadi —
        // l'envoi tournait en boucle sur « Action en dernier + opt-out » (5 brouillons).
        // Le gabarit CAFU dur ne s'applique que s'il est revendiqué (objet ou corps
        // « - CAFU » / en-tête [SUJET]) ; sinon coche « courrier libre » ci-dessous.
        let subject = (d["subject"] as? String) ?? ""
        let firstLine = lines(body).first ?? ""
        let cafuClaimed = subject.uppercased().contains("- CAFU") || firstLine.range(of: #"^\[.+\] - CAFU"#, options: .regularExpression) != nil
        return cafuClaimed ? mailItems(body: body) : freeMailItems(body: body)
    }

    /// Coche « courrier libre » (mail externe/perso non CAFU) : forme minimale sûre —
    /// corps non vide, salutation, demande identifiable, clôture signée, zéro emoji.
    /// Aucune exigence de gabarit CAFU (en-tête, points 01/02) : Ahadi a validé le texte.
    static func freeMailItems(body: String) -> [Item] {
        let ls = lines(body)
        var out: [Item] = []
        out.append(Item(key: "corps", label: "Corps non vide", ok: !ls.isEmpty, hard: true,
                        detail: ls.isEmpty ? "corps vide" : ""))
        let salOK = ls.contains { $0.range(of: #"^(Dear|Cher|Chère|Bonjour|Hello|Hi)\b"#, options: [.regularExpression, .caseInsensitive]) != nil }
        out.append(Item(key: "politesse", label: "Salutation présente", ok: salOK, hard: true,
                        detail: salOK ? "" : "aucune salutation (Dear…, Bonjour…)"))
        let actOK = containsAny(body, actionMarks) || hasOptOut(body)
        out.append(Item(key: "action", label: "Demande identifiable", ok: actOK, hard: false,
                        detail: actOK ? "" : "aucune demande identifiable (please, merci de…) — informatif seulement"))
        let tail = ls.suffix(4).joined(separator: " ")
        let closeOK = containsAny(tail, ["best,", "best regards", "regards", "cordialement", "kind regards", "sincerely"])
        out.append(Item(key: "cloture", label: "Clôture signée", ok: closeOK, hard: true,
                        detail: closeOK ? "" : "le corps doit finir par une formule (Best regards, Cordialement…) et un nom"))
        out.append(Item(key: "emoji", label: "Aucun emoji", ok: !hasEmoji(body), hard: true, detail: hasEmoji(body) ? "emoji détecté dans le corps" : ""))
        return out
    }

    static func mailItems(body: String) -> [Item] {
        let ls = lines(body)
        var out: [Item] = []
        // 1. En-tête [SUJET] - CAFU + ligne objectif distincte
        let headOK = ls.count >= 2 && ls[0].range(of: #"^\[.+\] - CAFU$"#, options: .regularExpression) != nil && ls[1] != ls[0]
        out.append(Item(key: "entete", label: "En-tête [SUJET] - CAFU + objectif", ok: headOK, hard: true,
                        detail: headOK ? "" : "première ligne « [SUJET / PAYS] - CAFU », deuxième ligne = l'objectif en une phrase"))
        // 2. Salutation « Dear X, » + ligne de politesse juste après
        var salOK = false, salDetail = "salutation « Dear Nom, » (ou Cher/Chère/Bonjour) suivie de la ligne de politesse"
        if let gi = ls.firstIndex(where: { $0.range(of: #"^(Dear|Cher|Chère|Bonjour)\s+.+,$"#, options: .regularExpression) != nil }) {
            salOK = gi + 1 < ls.count && containsAny(ls[gi + 1], politesses)
            if salOK { salDetail = "" }
        }
        out.append(Item(key: "politesse", label: "Salutation + politesse", ok: salOK, hard: true, detail: salDetail))
        // 3. Points 01/02 sur leur ligne, séquentiels, titrés, zéro puce
        let nums = ls.enumerated().filter { isNumbered($0.element) }
        var ptsOK = !nums.isEmpty && !hasBullet(body)
        var ptsDetail = ptsOK ? "" : "au moins un point « 01 » seul sur sa ligne, aucun « • »"
        if ptsOK {
            for (k, n) in nums.enumerated() {
                if n.element != String(format: "%02d", k + 1) { ptsOK = false; ptsDetail = "numérotation non séquentielle (01, 02…)"; break }
                if n.offset + 1 >= ls.count { ptsOK = false; ptsDetail = "point \(n.element) sans titre"; break }
            }
        }
        out.append(Item(key: "points", label: "Points 01/02 sur leur ligne", ok: ptsOK, hard: true, detail: ptsDetail))
        // 4. Dernier point = action (marqueur ou échéance) + opt-out explicite
        var actOK = false, actDetail = "le dernier point numéroté doit porter l'action et un opt-out (« no obligation », « à ta convenance »…)"
        if let last = nums.last {
            let block = ls[(last.offset + 1)...].prefix { !isNumbered($0) && $0 != "Best," }.joined(separator: " ")
            let hasDate = block.range(of: #"\b\d{1,2}/\d{1,2}\b"#, options: .regularExpression) != nil
            // FIX-LINT : l'échéance du gabarit peut être une heure (« avant 18 h »), pas
            // seulement une date chiffrée — les brouillons du magasin butaient sur les deux.
            // FIX-REVUE R-3(c) : les minutes collées à l'heure comptent aussi (« avant 18h30 »).
            let hasHeure = block.range(of: #"\bavant\s+\d{1,2}\s?h(?:\s?\d{2})?\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            actOK = hasOptOut(block) && (containsAny(block, actionMarks) || hasDate || hasHeure)
            if actOK { actDetail = "" }
        }
        out.append(Item(key: "action_optout", label: "Action en dernier + opt-out", ok: actOK, hard: true, detail: actDetail))
        // 5. Clôture exacte « Best, / Ahadi », aucune signature institutionnelle inventée
        let tailOK = ls.count >= 2 && ls[ls.count - 2] == "Best," && ls[ls.count - 1] == "Ahadi"
        let sigInv = body.contains("Strategic Humanitarian Analyst") || body.contains("Save the Children International")
        out.append(Item(key: "cloture", label: "Clôture Best, / Ahadi", ok: tailOK && !sigInv, hard: true,
                        detail: (tailOK && !sigInv) ? "" : (sigInv ? "bloc signature institutionnel présent — la signature du client mail suffit" : "le corps doit finir par « Best, » puis « Ahadi »")))
        // 6. Aucun emoji dans le corps
        out.append(Item(key: "emoji", label: "Aucun emoji", ok: !hasEmoji(body), hard: true, detail: hasEmoji(body) ? "emoji détecté dans le corps" : ""))
        return out
    }

    static func teamsItems(body: String, subject: String) -> [Item] {
        let ls = lines(body)
        var out: [Item] = []
        // 1. Forme : court = bloc fluide (ni numérotation ni puces) ; long = structure assumée
        let structured = ls.contains { isNumbered($0) } || hasBullet(body)
        let formeOK = ls.count > 5 || !structured
        out.append(Item(key: "forme", label: "Forme Teams (fluide si court)", ok: formeOK, hard: true,
                        detail: formeOK ? (structured ? "message long : structure assumée" : "") : "message court : ni points numérotés ni puces — un bloc fluide"))
        // 2. Signé « — Ahadi »
        let signOK = ls.last?.hasSuffix("— Ahadi") == true
        out.append(Item(key: "signe", label: "Signé — Ahadi", ok: signOK, hard: true, detail: signOK ? "" : "dernière ligne signée « — Ahadi »"))
        // 3. Opt-out si une demande est détectée
        let ask = containsAny(body, ["peux-tu", "pourrais-tu", "pourriez-vous", "pouvez-vous", "merci de", "please", "est-ce que", "avant le"]) || body.contains("?")
        let ooOK = !ask || hasOptOut(body)
        out.append(Item(key: "optout", label: "Opt-out si demande", ok: ooOK, hard: true,
                        detail: ooOK ? (ask ? "" : "aucune demande détectée") : "une demande sans porte de sortie explicite"))
        // 4. Aucun élément mail (ni en-tête CAFU, ni objet, ni « Best, »)
        let mailElt = ls.contains { $0.range(of: #"^\[.+\] - CAFU$"#, options: .regularExpression) != nil } || ls.contains { $0 == "Best," } || !subject.isEmpty
        out.append(Item(key: "aucun_mail", label: "Aucun élément mail", ok: !mailElt, hard: true,
                        detail: mailElt ? "en-tête/objet/clôture de mail dans un message Teams" : ""))
        return out
    }
}
