import Foundation

/// 29/10 (chantier 3, Ahadi : « toujours pas autonome, pas capable, ne livre pas directement ») — porte de sortie de mission.
/// Avant que la réponse parte, deux contrôles DÉTERMINISTES (sans cerveau) sur le texte et le journal des outils du tour :
/// 1) ABANDON PRÉMATURÉ : la réponse conclut sur un blocage (403, accès restreint, « je n'ai pas pu », « pas lu »…) alors que
///    moins de 2 voies alternatives ont été tentées après le premier échec → une passe de continuation impose 2 voies réelles.
/// 2) AFFIRMATION SANS PREUVE : la réponse dit avoir créé / envoyé / enregistré / ajouté quelque chose sans qu'aucun outil
///    correspondant n'ait réussi dans le tour → la passe exige d'exécuter l'action OU de corriger la phrase.
/// Une seule passe par tour. Journalisé (BlackBox « mission »).
public enum MissionGate {
    struct Step { let name: String; let failed: Bool }

    static let blockRx: NSRegularExpression? = try? NSRegularExpression(pattern:
        "je n'ai pas pu|je ne peux pas acc[ée]der|impossible d'acc[ée]der|inaccessible|acc[èe]s restreint|acc[èe]s refus[ée]|bloqu[ée]|HTTP (401|402|403|404|202|429|5\\d\\d)|pas de compte|je ne l'ai pas (lu|t[ée]l[ée]charg[ée]|ouvert)|non (lu|t[ée]l[ée]charg[ée])|introuvable|aucun r[ée]sultat|n'a rien renvoy[ée]",
        options: [.caseInsensitive])
    /// Sans aucun outil lancé, seules ces formules (refus d'essayer) ferment la porte.
    static let strongRx: NSRegularExpression? = try? NSRegularExpression(pattern:
        "je n'ai pas pu|je ne peux pas acc[ée]der|impossible d'acc[ée]der|je n'ai pas acc[èe]s", options: [.caseInsensitive])
    /// (affirmation, outils qui la prouvent)
    static let claims: [(NSRegularExpression, [String])] = [
        ("j'ai (envoy[ée]|transmis)|(mail|message) envoy[ée]", ["send_mail", "mail_send", "teams_send", "send"]),
        ("j'ai (cr[ée]{1,2}|[ée]crit|enregistr[ée]|sauvegard[ée]) (le|un|ton|la|une) (fichier|document|note|word|docx|pdf|tableau)|fichier cr[ée]{1,2}", ["write_file", "cafu_format", "docx", "pdf", "xlsx", "deck", "livrable"]),
        ("j'ai (ajout[ée]|cr[ée]{1,2}|plac[ée]|programm[ée]) .{0,30}(agenda|calendrier|rendez-vous|r[ée]union)", ["calendar_add", "calendar"]),
        ("j'ai (cr[ée]{1,2}|ajout[ée]|programm[ée]) .{0,20}rappel|rappel (cr[ée]{1,2}|programm[ée])", ["reminder_add", "reminder", "rappel"]),
        ("brouillon (cr[ée]{1,2}|pos[ée]|pr[êe]t dans)", ["draft", "brouillon"]),
    ].compactMap { (p: (String, [String])) -> (NSRegularExpression, [String])? in
        guard let rx = try? NSRegularExpression(pattern: p.0, options: [.caseInsensitive]) else { return nil }
        return (rx, p.1)
    }

    static func first(_ rx: NSRegularExpression?, _ s: String) -> String? {
        guard let rx = rx, let m = rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s) else { return nil }
        return String(s[r])
    }

    /// Consigne de continuation si la porte se ferme, sinon nil.
    static func check(answer: String, steps: [Step]) -> String? {
        var notes: [String] = []
        // 1) Abandon prématuré
        let strong: Bool = first(strongRx, answer) != nil
        if let hit = first(blockRx, answer), !steps.isEmpty || strong {
            let firstFail: Int? = steps.firstIndex(where: { $0.failed })
            let attemptsAfter: Int = firstFail.map { (i: Int) -> Int in steps.count - i - 1 } ?? steps.count
            let research: Bool = steps.contains { ["web_search", "web_fetch"].contains($0.name) }
            if attemptsAfter < 2 && (research || steps.isEmpty || firstFail != nil) {
                notes.append("Tu conclus sur un blocage (« \(hit) ») après seulement \(attemptsAfter) tentative(s) alternative(s). Avant de conclure, essaie MAINTENANT au moins deux autres voies réelles avec tes outils (autre source qui reprend la même donnée — OCHA, ReliefWeb, agence de presse, rapport officiel —, fichier de téléchargement direct CSV/XLSX/PDF, version archivée archive.org, recherche du titre exact), puis remplace la partie « bloqué » par ce que tu as trouvé. Ne garde en « bloqué » que ce qui l'est encore après ces essais.")
            }
        }
        // 2) Affirmation sans preuve
        let okNames: [String] = steps.filter { !$0.failed }.map { $0.name.lowercased() }
        for (rx, tools) in claims {
            if let hit = first(rx, answer) {
                let proved: Bool = okNames.contains { (n: String) -> Bool in tools.contains { n.contains($0) } }
                if !proved {
                    notes.append("Ta réponse affirme « \(hit) » mais aucun outil correspondant n'a réussi dans ce tour. Exécute l'action maintenant avec l'outil adéquat (sauf envoi : jamais d'envoi sans le GO d'Ahadi — prépare seulement), ou corrige la phrase pour dire exactement ce qui a été fait.")
                    break
                }
            }
        }
        guard !notes.isEmpty else { return nil }
        _ = BlackBox.record(["tool": "mission", "actor": "Nova", "ok": false, "effect": "lecture",
                             "why": "porte de mission : " + notes.map { String($0.prefix(90)) }.joined(separator: " | "), "result": "continuation"])
        return "[MOTEUR NOVA — PORTE DE MISSION] " + notes.joined(separator: " ") + " Livre ensuite la réponse complète mise à jour, BLUF en tête, sans annoncer tes étapes."
    }
}
