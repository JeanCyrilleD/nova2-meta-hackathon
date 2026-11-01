import Foundation
// MUSE-PARTOUT (26/10, ordre d'Ahadi) : defauts de ce fichier sur Muse (voir ordres dans Brains.swift).

/// BRAIN-B (24/10) — MÉMOIRE ENTRE CONVERSATIONS (AUDIT_BRAIN P1-6).
/// Après chaque tour terminé (chat écrit ou voix live), en ARRIÈRE-PLAN — jamais sur le chemin de
/// la réponse —, le cerveau économique ([tiers], réglage dots_brain) extrait d'un échange :
///   {faits:[{texte, type: profil|contexte}], engagements:[{quoi, qui, dir, echeance}]}
/// Les faits sont dédoublonnés contre la mémoire (Memory.addDistilled) et vectorisés à l'écriture ;
/// les engagements rejoignent commitments.json (même schéma et même clé de dédoublonnage que le
/// scan quotidien, Feat_Daily). Rien de secret n'est jamais écrit (filtre isPrivate en plus de la
/// consigne). Une file série : un seul appel à la fois, aucun empilement.
public enum MemoryDistiller {
    static let q = DispatchQueue(label: "nova.memoire.distillation", qos: .utility)

    /// Secrets et identifiants : mots-clés + toute suite d'au moins 9 chiffres (carte, compte, IBAN…).
    static let secretRx: NSRegularExpression? = try? NSRegularExpression(pattern: "mot de passe|mdp\\b|password|passcode|\\bpin\\b|\\bcvv\\b|\\bcvc\\b|\\biban\\b|\\bbic\\b|code secret|code (de )?(confirmation|vérification|verification)|\\botp\\b|token|api[ _-]?key|cl[ée] (d'api|api|secr[eè]te|priv[ée]e)|identifiant de connexion|num[ée]ro de (carte|compte)|(\\d[ .\\-]?){9,}", options: [.caseInsensitive])

    public static func isPrivate(_ t: String) -> Bool {
        guard let rx = secretRx else { return false }
        return rx.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil
    }

    /// Planifie l'extraction d'un échange. Ne bloque jamais l'appelant.
    /// MÉMOIRE SOUVERAINE (24/10) : `conversationId` = fil d'origine (gardé sur chaque fait retenu) ;
    /// un fil « Hors mémoire » ne déclenche jamais l'extraction.
    public static func schedule(router: Router, memory: Memory, user: String, assistant: String, title: String = "", tools: [String] = [], conversationId: String = "") {
        if memory.isOff { return }
        if !conversationId.isEmpty && MemoryLedger.isIncognito(conversationId) { return }
        let u: String = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let a: String = assistant.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty { return }
        if u.count < 15 && a.count < 200 { return }   // « oui », « go » : rien de durable à apprendre
        if a.hasPrefix("(sans réponse") || a.hasPrefix("(interrompu") { return }
        let cid: String = conversationId
        q.async { run(router: router, memory: memory, user: u, assistant: a, title: title, tools: tools, conversationId: cid) }
    }

    static func run(router: Router, memory: Memory, user: String, assistant: String, title: String, tools: [String], conversationId: String = "") {
        if !conversationId.isEmpty && MemoryLedger.isIncognito(conversationId) { return }   // basculé « Hors mémoire » entre-temps
        let known: [String] = memory.list().suffix(40).compactMap { $0["text"] as? String }.map { String($0.prefix(160)) }
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        let today: String = df.string(from: Date())
        let sys: String = "Tu es le greffier de la mémoire de Nova, l'assistant personnel d'Ahadi (analyste humanitaire CAFU, Save the Children, Ouagadougou). À partir d'UN échange, tu extrais uniquement : "
            + "(1) des faits DURABLES sur Ahadi — préférences, décisions, règles de travail, personnes et leur rôle, projets, échéances, habitudes — chacun en une phrase autonome à la 3e personne (« Ahadi … »), datée si une date est dite ; "
            + "type « profil » pour ce qui le définit durablement (rôle, préférences, proches, façons de travailler), « contexte » pour le reste ; "
            + "(2) des engagements explicites (promesse d'Ahadi, ou promesse faite à Ahadi). "
            + "EXCLUS : banalités, détails de la tâche du moment sans portée durable, ce que Nova dit d'elle-même, suppositions, faits déjà connus, et TOUT secret (mot de passe, code, numéro de carte ou de compte, IBAN, clé), toute donnée de santé, tout montant financier personnel. "
            + "Réponds UNIQUEMENT par un JSON strict, sans texte autour : {\"faits\":[{\"texte\":\"…\",\"type\":\"profil|contexte\"}],\"engagements\":[{\"quoi\":\"…\",\"qui\":\"…\",\"dir\":\"moi|eux\",\"echeance\":\"AAAA-MM-JJ ou vide\"}]} — tableaux vides s'il n'y a rien. 5 faits et 3 engagements au plus."
        var p: String = "Aujourd'hui : " + today + "."
        if !title.isEmpty { p += "\nConversation : « " + String(title.prefix(80)) + " »" }
        if !known.isEmpty { p += "\n\nFAITS DÉJÀ CONNUS (ne pas répéter) :\n" + known.map { "- " + $0 }.joined(separator: "\n") }
        p += "\n\n=== AHADI ===\n" + String(user.prefix(3000))
        p += "\n\n=== NOVA ===\n" + String(assistant.prefix(3500))
        if !tools.isEmpty { p += "\n\n(Outils utilisés dans ce tour : " + tools.prefix(8).joined(separator: ", ") + ")" }
        let brain: String = Settings().get("dots_brain", "spark-1.3")
        guard let r = router.complete(messages: [ChatMsg("user", p)], system: sys, mode: "fast", preferred: brain.isEmpty ? "spark-1.3" : brain, maxTokens: 700, deadline: 45) else {
            _ = BlackBox.record(["tool": "memoire", "actor": "Nova", "why": "extraction de mémoire : aucun cerveau n'a répondu (tour ignoré, rien d'écrit)", "ok": false, "effect": "aucun"])
            return
        }
        guard let o = DailyCal.jsonSlice(r.text, open: "{", close: "}") as? [String: Any] else {
            _ = BlackBox.record(["tool": "memoire", "actor": "Nova", "why": "extraction de mémoire : réponse non JSON de " + r.brain + " (rien d'écrit)", "ok": false, "effect": "aucun"])
            return
        }
        var addedFacts: [String] = []
        for x in ((o["faits"] as? [Any]) ?? []).prefix(5) {
            var texte: String = ""
            var kind: String = "contexte"
            if let d = x as? [String: Any] {
                texte = (d["texte"] as? String) ?? (d["text"] as? String) ?? ""
                kind = ((d["type"] as? String) ?? "contexte") == "profil" ? "profil" : "contexte"
            } else if let sx = x as? String { texte = sx }
            texte = texte.trimmingCharacters(in: .whitespacesAndNewlines)
            if texte.isEmpty || isPrivate(texte) { continue }
            if memory.addDistilled(texte, kind: kind, conversation: conversationId) != nil { addedFacts.append(texte) }
        }
        let eng: [[String: Any]] = ((o["engagements"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
        let addedEng: Int = addCommitments(Array(eng.prefix(3)), title: title)
        if !addedFacts.isEmpty || addedEng > 0 {
            _ = BlackBox.record(["tool": "memoire", "actor": "Nova", "why": "extraction de mémoire (" + r.brain + ") : \(addedFacts.count) fait(s), \(addedEng) engagement(s) retenus — " + addedFacts.map { String($0.prefix(80)) }.joined(separator: " | "), "ok": true, "effect": "écriture"])
        }
    }

    /// Engagements → commitments.json, même clé de dédoublonnage que Feat_Daily (dir|quoi|qui simplifiés).
    static func addCommitments(_ list: [[String: Any]], title: String) -> Int {
        if list.isEmpty { return 0 }
        let st: DailyState = DailyState.shared
        st.lock.lock(); defer { st.lock.unlock() }
        var o: [String: Any] = st.commitFile.read(default: [String: Any]())
        var items: [[String: Any]] = (o["items"] as? [[String: Any]]) ?? []
        var keys = Set<String>()
        for it in items {
            let kd: String = (it["dir"] as? String) ?? ""
            let kq: String = String(DailyCal.simplify((it["quoi"] as? String) ?? "").prefix(60))
            let kw: String = DailyCal.simplify((it["qui"] as? String) ?? "")
            keys.insert(kd + "|" + kq + "|" + kw)
        }
        var added: Int = 0
        for c in list {
            let quoi: String = String(((c["quoi"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))
            if quoi.count < 6 || isPrivate(quoi) { continue }
            let qui: String = String(((c["qui"] as? String) ?? "").prefix(80))
            let dir: String = ((c["dir"] as? String) ?? "moi") == "eux" ? "eux" : "moi"
            var ech: String = (c["echeance"] as? String) ?? ""
            if DailyCal.deadline(ech) == nil { ech = "" }
            let k: String = dir + "|" + String(DailyCal.simplify(quoi).prefix(60)) + "|" + DailyCal.simplify(qui)
            if keys.contains(k) { continue }
            keys.insert(k)
            let src: String = "conversation" + (title.isEmpty ? "" : " : " + String(title.prefix(120)))
            items.append(["id": String(UUID().uuidString.prefix(8)).lowercased(), "qui": qui, "quoi": quoi, "echeance": ech, "dir": dir,
                          "source": src, "status": "ouvert", "created": nowISO(), "seen": nowISO(), "alerted": false])
            added += 1
        }
        if added > 0 { o["items"] = items; st.commitFile.write(o) }
        return added
    }
}
