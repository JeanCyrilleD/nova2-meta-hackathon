import Foundation

/// 29/10 (Ahadi : « vas-y pour toutes tes recommandations » — auto-évaluation, inspirée d'ECC agent-self-evaluation).
///
/// Après une réponse de FOND (≥ 500 caractères, pas une question simple, pas la voix), [tiers] relit demande + réponse et note
/// 5 axes (exactitude, complétude, clarté, actionnable, concision) avec des PREUVES : points de la demande non traités,
/// erreurs vérifiables dans le texte (calcul faux, contradiction). Si un manque ou une erreur concrète est trouvé,
/// UNE passe de complément part sur le cerveau principal ([tiers]), qui ne complète/corrige que ce point.
/// Coût : ≈ 0,0005 $ par contrôle ([tiers]). Journal : releves/diag/autoeval.jsonl (notes, jamais le contenu).
/// 31/10 : COUPÉ par défaut (réglage « auto_eval_v2 ») — mesuré : 7 réponses longues sur 10 déclenchaient une 2e passe complète du
/// cerveau principal (≈ 45 000 jetons de contexte, jusqu'à 8 outils), alors que ce commentaire n'annonçait que le coût de [tiers].
/// Réglage « auto_eval » (vrai par défaut) — ancien.
public enum AutoEval {
    public static func eligible(answer: String, simple: Bool, spoken: Bool, settings: Settings) -> Bool {
        settings.get("auto_eval_v2", false) && !simple && !spoken && answer.count >= 500
    }

    static let sys: String = """
    Tu es le contrôleur qualité de Nova, l'assistant d'Ahadi. On te donne la DEMANDE d'Ahadi et la RÉPONSE de Nova.
    Note chaque axe de 1 à 5 : exactitude, completude (tous les points DEMANDÉS sont traités), clarte, actionnable, concision.
    « manques » = points explicitement demandés et NON traités (formulation concrète, max 3) — jamais un ajout que la demande ne contenait pas.
    « erreurs » = erreurs VÉRIFIABLES dans le texte même : calcul faux, contradiction interne, date incohérente (max 3). Pas d'avis de style.
    En cas de doute, ne signale rien. Réponds UNIQUEMENT par un objet JSON :
    {"exactitude":n,"completude":n,"clarte":n,"actionnable":n,"concision":n,"manques":["…"],"erreurs":["…"]}
    """

    /// Renvoie la consigne de complément si une reprise est justifiée, sinon nil. Toujours journalisé.
    public static func review(router: Router, ask: String, answer: String) -> String? {
        let user: String = "DEMANDE :\n" + String(ask.prefix(4000)) + "\n\nRÉPONSE :\n" + String(answer.prefix(12000))
        let t0: Date = Date()
        // 01/11 (routage par spécialité) : le correcteur est un AUTRE modèle que le rédacteur (Wonder ; Spark en relais) — [tiers] sinon (ancien comportement).
        let juge: String = MetaSpecialites.premierUtilisable(.juges, router: router) ?? "wonder-1.0"
        let det = router.completeDetailed(messages: [ChatMsg("user", user)], system: sys, mode: MetaSpecialites.actif ? "juge" : "bulk",
                                          preferred: juge, maxTokens: 400, deadline: 15, solo: true)
        let ms: Int = Int(Date().timeIntervalSince(t0) * 1000)
        guard let txt = det.result?.text, let a = txt.firstIndex(of: "{"), let b = txt.lastIndex(of: "}"),
              let o = parseJSON(Data(String(txt[a...b]).utf8)) else {
            log(["ok": false, "ms": ms, "err": String((det.error ?? "réponse illisible").prefix(120))])
            return nil
        }
        func n(_ k: String) -> Int { (o[k] as? Int) ?? Int((o[k] as? Double) ?? 5) }
        let manques: [String] = ((o["manques"] as? [String]) ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(3).map { String($0.prefix(200)) }
        let erreurs: [String] = ((o["erreurs"] as? [String]) ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(3).map { String($0.prefix(200)) }
        let fix: Bool = (n("completude") <= 3 && !manques.isEmpty) || (n("exactitude") <= 3 && !erreurs.isEmpty)
        log(["ok": true, "ms": ms, "exactitude": n("exactitude"), "completude": n("completude"), "clarte": n("clarte"),
             "actionnable": n("actionnable"), "concision": n("concision"), "manques": manques.count, "erreurs": erreurs.count, "reprise": fix])
        guard fix else { return nil }
        var note: String = "[MOTEUR NOVA — CONTRÔLE QUALITÉ] Ta réponse est relue par le contrôle qualité."
        if !manques.isEmpty { note += " Points demandés non traités : " + manques.joined(separator: " ; ") + "." }
        if !erreurs.isEmpty { note += " Erreurs vérifiables : " + erreurs.joined(separator: " ; ") + "." }
        note += " Ajoute MAINTENANT uniquement ce qui manque et corrige ce qui est faux, sans répéter le reste. Commence par une ligne « **Complément :** » (ou « **Correction :** » s'il s'agit d'une erreur). Si le contrôle se trompe, dis-le en une ligne et ne change rien."
        return note
    }

    static func log(_ row: [String: Any]) {
        var r: [String: Any] = row; r["ts"] = nowISO()
        let path: String = NSHomeDirectory() + "/spark-local/Nova2/releves/diag/autoeval.jsonl"
        let d: Data = jsonData(r)
        guard let line = String(data: d, encoding: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); h.closeFile() }
        else { try? Data((line + "\n").utf8).write(to: URL(fileURLWithPath: path)) }
    }
}
