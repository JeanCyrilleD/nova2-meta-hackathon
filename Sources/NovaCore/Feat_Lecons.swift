import Foundation
// MUSE-PARTOUT (26/10, ordre d'Ahadi) : defauts de ce fichier sur Muse (voir ordres dans Brains.swift).

// Leçons d'outils (auto-réparation) : quand un outil échoue puis réussit peu après chez le même acteur, Nova retient
// « outil X échoue quand … → faire … » et le rappelle dans chaque prompt (suffixe dynamique, via Persona.envProvider).
// Aussi : branchement du résumé glissant des conversations (Store.swift, Conversations.summarizer).

struct LeconPending {
    let tool: String
    let key: String
    var remaining: Int
}

public enum Lecons {
    static let store = JSONFile("lecons_outils.json")
    static let lock = NSLock()
    nonisolated(unsafe) static var pending: [String: LeconPending] = [:]   // dernier échec par acteur (Nova, Dot …) : fenêtre de 3 appels
    nonisolated(unsafe) static var started: Bool = false
    static let maxItems: Int = 60

    /// Clé d'une leçon : outil + début normalisé de l'erreur (chiffres retirés), pour regrouper les échecs semblables.
    static func key(_ tool: String, _ error: String) -> String {
        let low: String = error.lowercased()
        let noDigits: String = String(low.filter { !$0.isNumber })
        let head: String = String(noDigits.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        return tool + "|" + head
    }

    static func clean(_ t: String, _ n: Int) -> String {
        let one: String = t.replacingOccurrences(of: "\n", with: " ")
        return Knowledge.redact(String(one.prefix(n)))
    }

    /// Point d'entrée unique, appelé par Tools.run après chaque outil (une ligne).
    public static func observe(tool: String, arg: String, out: String, ok: Bool, actor: String) {
        if out.hasPrefix("Refusé") { return }   // refus de politique : pas une leçon d'outil
        let lowOut: String = out.lowercased()
        let failed: Bool = !ok || lowOut.hasPrefix("erreur") || lowOut.hasPrefix("échec") || lowOut.hasPrefix("error")
        if failed {
            record(tool: tool, arg: arg, error: out)
            lock.lock()
            pending[actor] = LeconPending(tool: tool, key: key(tool, out), remaining: 3)
            lock.unlock()
            return
        }
        lock.lock()
        var fixKey: String? = nil
        if var p = pending[actor] {
            if p.tool == tool {
                fixKey = p.key
                pending.removeValue(forKey: actor)
            } else {
                p.remaining -= 1
                if p.remaining <= 0 { pending.removeValue(forKey: actor) } else { pending[actor] = p }
            }
        }
        lock.unlock()
        if let k = fixKey { record(tool: tool, arg: arg, fixed: k) }
    }

    /// Échec d'un outil : nouvelle leçon ou compteur incrémenté.
    public static func record(tool: String, arg: String, error: String) {
        let k: String = key(tool, error)
        lock.lock(); defer { lock.unlock() }
        var items: [[String: Any]] = store.read(default: [[String: Any]]())
        if let i = items.firstIndex(where: { ($0["key"] as? String) == k }) {
            var it: [String: Any] = items[i]
            let n: Int = (it["count"] as? Int) ?? 1
            it["count"] = n + 1
            it["ts"] = nowISO()
            it["arg"] = clean(arg, 120)
            items[i] = it
        } else {
            let it: [String: Any] = ["key": k, "tool": tool, "arg": clean(arg, 120), "error": clean(error, 160), "count": 1, "ts": nowISO()]
            items.append(it)
        }
        if items.count > maxItems { items = Array(items.suffix(maxItems)) }
        store.write(items)
    }

    /// Réussite du même outil dans les 3 appels suivants : la leçon reçoit l'argument qui a marché.
    public static func record(tool: String, arg: String, fixed k: String) {
        lock.lock(); defer { lock.unlock() }
        var items: [[String: Any]] = store.read(default: [[String: Any]]())
        guard let i = items.firstIndex(where: { ($0["key"] as? String) == k }) else { return }
        var it: [String: Any] = items[i]
        it["fix"] = clean(arg, 120)
        it["fixed_ts"] = nowISO()
        it["ts"] = nowISO()
        items[i] = it
        store.write(items)
    }

    /// Bloc court (≤ 700 caractères) pour le suffixe dynamique du prompt : 8 leçons récentes et fréquentes.
    public static func promptBlock() -> String {
        lock.lock()
        let items: [[String: Any]] = store.read(default: [[String: Any]]())
        lock.unlock()
        if items.isEmpty { return "" }
        let recent: [[String: Any]] = Array(items.sorted { ($0["ts"] as? String ?? "") > ($1["ts"] as? String ?? "") }.prefix(20))
        let top: [[String: Any]] = Array(recent.sorted { (($0["count"] as? Int) ?? 1) > (($1["count"] as? Int) ?? 1) }.prefix(8))
        var s: String = "LEÇONS RÉCENTES (tes échecs d'outils passés) :"
        var added: Int = 0
        for it in top {
            let tool: String = it["tool"] as? String ?? "?"
            let arg: String = String((it["arg"] as? String ?? "").prefix(60))
            let err: String = String((it["error"] as? String ?? "").prefix(70))
            let fix: String = String((it["fix"] as? String ?? "").prefix(60))
            var line: String = "\n- outil " + tool + " échoue quand « " + arg + " » (" + err + ")"
            if fix.isEmpty { line += " → essayer une autre voie" } else { line += " → faire : « " + fix + " »" }
            if s.count + line.count > 700 { break }
            s += line
            added += 1
        }
        return added == 0 ? "" : s
    }
}

extension NovaApp {
    /// À appeler une fois au démarrage, APRÈS l'installation de Persona.envProvider (App.swift, init).
    /// Compose le fournisseur d'environnement existant avec les leçons, et branche le résumé glissant des conversations.
    func leconsStart() {
        Lecons.lock.lock()
        let already: Bool = Lecons.started
        Lecons.started = true
        Lecons.lock.unlock()
        if already { return }
        let old: (() -> String)? = Persona.envProvider
        Persona.envProvider = {
            let a: String = old?() ?? ""
            let b: String = Lecons.promptBlock()
            if b.isEmpty { return a }
            if a.isEmpty { return b }
            return a + "\n" + b
        }
        let r: Router = router
        Conversations.summarizer = { txt in
            let sys: String = "Tu résumes une conversation entre Ahadi et son assistant Nova. Écris en français un résumé factuel et DENSE, de 600 à 4 000 caractères selon la matière fournie (plus la suite fournie est longue, plus le résumé est long) : décisions prises, faits établis — en gardant les NOMS, les CHIFFRES et les DATES exacts — demandes en cours, préférences exprimées. Aucune invention, aucun préambule."
            guard let res = r.complete(messages: [ChatMsg("user", txt)], system: sys, mode: "fast", preferred: "spark-1.3", maxTokens: 1400) else { return nil }
            return res.text
        }
    }
}
