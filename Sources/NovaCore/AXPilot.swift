import Foundation
#if os(macOS)
import AppKit
import ApplicationServices
#endif

// VAGUE 3 (24/10/2026) — PILOTAGE DU MAC EN ARRIÈRE-PLAN PAR L'ACCESSIBILITÉ (API AX).
// Lecture et action sur l'interface d'une AUTRE app, sans jamais l'activer ni la passer au premier plan :
// - lecture : AXUIElementCreateApplication(pid) → fenêtre → arbre borné (profondeur ≤ 12, ≤ 1 500 nœuds, ≤ 6 s),
//   liste numérotée (index réutilisable 3 min) ; recherche par rôle / titre / texte ; lecture du focus.
// - actions : AXPress (ou sélection d'une ligne), mise de valeur d'un champ texte (AXValue), menu par AXMenuBar.
// - interdits codés : jamais d'activation d'app ; AXRaise seulement si Ahadi a demandé « devant moi » (Tools.frontAllowed) ;
//   jamais de saisie dans un champ mot de passe (AXSecureTextField → refus) ; un clic dont le libellé évoque
//   envoyer / publier / supprimer passe par la carte d'approbation existante (Tools.needConfirm), payer = refus dur.
// - chaque action AX est journalisée dans la Boîte noire (tool « ax » : app, rôle, titre, effet).
// Rien ici ne contourne la politique Confiance : ces verbes passent par l'outil « app », donc par Agent.runGuarded,
// Trust.verdict, Permits et la garde du premier plan de Tools.run, avant d'arriver ici.
public enum AXPilot {
    public static let verbs: Set<String> = ["ax-lire", "ax-chercher", "ax-cliquer", "ax-saisir", "ax-menu"]
    public static let maxDepth: Int = 12
    public static let maxNodes: Int = 1500
    public static let maxListed: Int = 140
    static let cacheTTL: TimeInterval = 180
    static let readSeconds: TimeInterval = 6
    static let lock: NSLock = NSLock()

    static func appDisplayName() -> String {
        let n: String = (Bundle.main.infoDictionary?["CFBundleName"] as? String) ?? ""
        return n.isEmpty ? "Nova" : n
    }
    /// Message exact quand le droit manque. Nova n'ouvre JAMAIS la fenêtre des Réglages d'elle-même.
    public static func permissionMessage() -> String {
        return "ACCESSIBILITÉ NON ACCORDÉE : Nova ne peut ni lire ni piloter l'interface des autres apps. Pour l'activer, ouvre toi-même Réglages Système › Confidentialité et sécurité › Accessibilité, puis active « " + appDisplayName() + " » (bouton + s'il n'est pas dans la liste). Nova n'ouvre pas cette fenêtre d'elle-même. Rien n'a été fait."
    }
    public static func trusted() -> Bool {
        #if os(macOS)
        return AXIsProcessTrusted()
        #else
        return false
        #endif
    }
    public static func status() -> [String: Any] {
        let ok: Bool = trusted()
        #if os(macOS)
        let plat: Bool = true
        #else
        let plat: Bool = false
        #endif
        return ["trusted": ok, "macos": plat, "front_autorise": Tools.frontAllowed,
                "message": ok ? "Accessibilité accordée : Nova lit et pilote les apps en arrière-plan, sans les activer." : permissionMessage(),
                "chemin": "Réglages Système › Confidentialité et sécurité › Accessibilité",
                "verbes": ["ax-lire <app> [| fenêtre]", "ax-chercher <app> | <texte>", "ax-cliquer <app> | <index ou libellé>", "ax-saisir <app> | <index ou libellé> | <texte>", "ax-menu <app> | <Menu > Élément>"]]
    }

    // MARK: journal (Boîte noire)

    static func axLog(_ verb: String, app: String, role: String, title: String, effect: String, ok: Bool, actor: String, detail: String = "") {
        var why: String = verb + " · " + app
        if !role.isEmpty { why += " · " + role }
        if !title.isEmpty { why += " « " + String(title.prefix(80)) + " »" }
        why += " → " + effect
        let input: String = "app=" + app + " ; rôle=" + role + " ; titre=" + String(title.prefix(80))
        _ = BlackBox.record(["tool": "ax", "actor": actor, "input": String(input.prefix(240)), "why": String(why.prefix(240)), "ok": ok, "effect": effect, "result": String(detail.prefix(200))])
    }
    /// Dernières actions AX lues dans la Boîte noire (persistant, signé).
    public static func journalItems(_ n: Int = 20) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for r in BlackBox.tail(900).reversed() {
            guard let e = r["entry"] as? [String: Any], (e["tool"] as? String) == "ax" else { continue }
            out.append(["ts": r["ts"] ?? "", "why": e["why"] ?? "", "ok": e["ok"] ?? false, "effect": e["effect"] ?? "", "actor": e["actor"] ?? "", "seq": r["seq"] ?? 0])
            if out.count >= n { break }
        }
        return out
    }

    // MARK: classement des libellés sensibles

    static func mkRx(_ p: String) -> NSRegularExpression { return try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    static let deleteRx: NSRegularExpression = mkRx(#"\b(supprimer|suppression|effacer|delete|remove|erase|d[ée]truire|destroy|vider\s+la\s+corbeille|empty\s+trash|placer\s+dans\s+la\s+corbeille|mettre\s+[àa]\s+la\s+corbeille|move\s+to\s+trash|jeter)\b"#)
    static let payExtraRx: NSRegularExpression = mkRx(#"\b(pay|payer|acheter|buy\s+now|purchase|commander|confirmer\s+l'achat|confirmer\s+la\s+commande|place\s+order|transf[ée]rer\s+de\s+l'argent|send\s+money)\b"#)
    static let sendExtraRx: NSRegularExpression = mkRx(#"\b(envoyer|send|soumettre|submit|r[ée]pondre\s+[àa]\s+tous|reply\s+all|transf[ée]rer|forward)\b"#)
    static let secretLabelRx: NSRegularExpression = mkRx(#"(mot\s+de\s+passe|password|passcode|code\s+pin|\bpin\b|code\s+secret|code\s+de\s+v[ée]rification|\botp\b|cl[ée]\s+api|api\s+key|token|jeton)"#)

    /// Type sensible d'un libellé d'élément : paiement / publication / envoi / suppression, ou nil.
    static func sensitive(_ label: String) -> String? {
        if label.isEmpty { return nil }
        if Tools.match(Trust.payRx, label) || Tools.match(payExtraRx, label) { return "paiement" }
        if Tools.match(Trust.publishClickRx, label) { return "publication" }
        if Tools.match(Trust.sendClickRx, label) || Tools.match(sendExtraRx, label) { return "envoi" }
        if Tools.match(deleteRx, label) { return "suppression" }
        return nil
    }

    static func fold(_ s: String) -> String {
        return s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func clip(_ s: String, _ n: Int) -> String {
        let one: String = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return one.count > n ? String(one.prefix(n)) + "…" : one
    }

    // MARK: point d'entrée des verbes (outil « app »)

    public static func run(_ verb: String, _ arg: String, actor: String = "Assistant") -> String {
        #if os(macOS)
        guard trusted() else {
            axLog(verb, app: "", role: "", title: "", effect: "refusé (Accessibilité non accordée)", ok: false, actor: actor)
            return permissionMessage()
        }
        switch verb {
        case "ax-lire": return lire(arg, actor: actor)
        case "ax-chercher": return chercher(arg, actor: actor)
        case "ax-cliquer": return cliquer(arg, actor: actor)
        case "ax-saisir": return saisir(arg, actor: actor)
        case "ax-menu": return menu(arg, actor: actor)
        default: return "Verbe AX inconnu. Verbes : ax-lire <app> [| fenêtre] · ax-chercher <app> | <texte> · ax-cliquer <app> | <index|libellé> · ax-saisir <app> | <index|libellé> | <texte> · ax-menu <app> | <Menu > Élément>."
        }
        #else
        return "Pilotage par l'Accessibilité indisponible hors macOS."
        #endif
    }

    #if os(macOS)

    // MARK: modèle

    struct Node {
        let el: AXUIElement
        let role: String
        let subrole: String
        let title: String
        let value: String
        let desc: String
        let ident: String
        let help: String
        let depth: Int
        let focused: Bool
        let enabled: Bool
        var secure: Bool { return subrole == "AXSecureTextField" || role == "AXSecureTextField" }
        var label: String {
            for s in [title, desc, secure ? "" : value, help, ident] where !s.isEmpty { return s }
            return ""
        }
        var allText: String { return [title, desc, secure ? "" : String(value.prefix(400)), help, ident].filter { !$0.isEmpty }.joined(separator: " ") }
    }
    struct Snap {
        let at: Date
        let pid: pid_t
        let nodes: [Node]
    }
    nonisolated(unsafe) static var snaps: [pid_t: Snap] = [:]
    nonisolated(unsafe) static var manualAX: Set<pid_t> = []

    static func remember(_ pid: pid_t, _ nodes: [Node]) {
        lock.lock(); snaps[pid] = Snap(at: Date(), pid: pid, nodes: nodes); lock.unlock()
    }
    static func cached(_ pid: pid_t, _ index: Int) -> Node? {
        lock.lock(); defer { lock.unlock() }
        guard let s = snaps[pid], Date().timeIntervalSince(s.at) < cacheTTL, index >= 1, index <= s.nodes.count else { return nil }
        return s.nodes[index - 1]
    }

    // MARK: accès AX bas niveau

    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef? = nil
        let err: AXError = AXUIElementCopyAttributeValue(el, name as CFString, &v)
        return err == .success ? v : nil
    }
    static func str(_ el: AXUIElement, _ name: String) -> String {
        guard let v = attr(el, name) else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let u = v as? URL { return u.path }
        return ""
    }
    static func bool(_ el: AXUIElement, _ name: String, fallback d: Bool) -> Bool {
        guard let v = attr(el, name) else { return d }
        if let n = v as? NSNumber { return n.boolValue }
        return d
    }
    static func element(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v = v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let v = attr(el, name) else { return [] }
        if let a = v as? [AXUIElement] { return a }
        return []
    }
    static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray? = nil
        guard AXUIElementCopyActionNames(el, &names) == .success, let a = names as? [String] else { return [] }
        return a
    }
    static func frame(_ el: AXUIElement) -> (x: Int, y: Int, w: Int, h: Int)? {
        var p: CGPoint = CGPoint.zero
        var sz: CGSize = CGSize.zero
        guard let pv = attr(el, "AXPosition"), CFGetTypeID(pv) == AXValueGetTypeID(),
              let sv = attr(el, "AXSize"), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        let okP: Bool = AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        let okS: Bool = AXValueGetValue(sv as! AXValue, .cgSize, &sz)
        guard okP && okS else { return nil }
        return (Int(p.x), Int(p.y), Int(sz.width), Int(sz.height))
    }
    static func settable(_ el: AXUIElement, _ name: String) -> Bool {
        var s: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(el, name as CFString, &s) == .success else { return false }
        return s.boolValue
    }
    static func same(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        guard let a = a, let b = b else { return false }
        return CFEqual(a, b)
    }

    // MARK: apps

    static let aliases: [String: String] = [
        "outlook": "com.microsoft.Outlook", "teams": "com.microsoft.teams2", "word": "com.microsoft.Word", "excel": "com.microsoft.Excel",
        "powerpoint": "com.microsoft.Powerpoint", "notes": "com.apple.Notes", "finder": "com.apple.finder", "mail": "com.apple.mail",
        "calendrier": "com.apple.iCal", "calendar": "com.apple.iCal", "rappels": "com.apple.reminders", "reminders": "com.apple.reminders",
        "messages": "com.apple.MobileSMS", "safari": "com.apple.Safari", "chrome": "com.google.Chrome", "reglages": "com.apple.systempreferences",
        "reglages systeme": "com.apple.systempreferences", "system settings": "com.apple.systempreferences", "preview": "com.apple.Preview",
        "apercu": "com.apple.Preview", "slack": "com.tinyspeck.slackmacgap", "whatsapp": "net.whatsapp.WhatsApp", "pages": "com.apple.iWork.Pages",
        "numbers": "com.apple.iWork.Numbers", "keynote": "com.apple.iWork.Keynote", "terminal": "com.apple.Terminal", "musique": "com.apple.Music", "music": "com.apple.Music"]
    /// Apps Chromium/Electron : l'arbre web n'est exposé qu'avec AXManualAccessibility.
    static let electronLike: Set<String> = ["com.microsoft.teams2", "com.tinyspeck.slackmacgap", "com.microsoft.VSCode", "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "net.whatsapp.WhatsApp", "com.hnc.Discord", "notion.id"]

    static func findApp(_ name: String) -> NSRunningApplication? {
        let q: String = fold(name)
        guard !q.isEmpty else { return nil }
        let apps: [NSRunningApplication] = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
        if let x = apps.first(where: { fold($0.localizedName ?? "") == q || fold($0.bundleIdentifier ?? "") == q }) { return x }
        if let b = aliases[q], let x = apps.first(where: { $0.bundleIdentifier == b }) { return x }
        let partial: [NSRunningApplication] = apps.filter { fold($0.localizedName ?? "").contains(q) }
        return partial.count == 1 ? partial[0] : nil
    }
    /// Sépare « <app> | reste » ; sans « | », reconnaît le plus long nom d'app lancée en tête (« Microsoft Outlook 3 »), sinon le premier mot.
    static func splitApp(_ arg: String) -> (name: String, app: NSRunningApplication?, rest: String) {
        let a: String = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = a.range(of: "|") {
            let name: String = String(a[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rest: String = String(a[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (name, findApp(name), rest)
        }
        let fa: String = fold(a)
        var bestApp: NSRunningApplication? = nil
        var bestLen: Int = 0
        for ra in NSWorkspace.shared.runningApplications where ra.activationPolicy != .prohibited {
            let n: String = ra.localizedName ?? ""
            if n.isEmpty { continue }
            let fn: String = fold(n)
            if (fa == fn || fa.hasPrefix(fn + " ")) && n.count > bestLen { bestApp = ra; bestLen = n.count }
        }
        if let b = bestApp {
            let rest: String = String(a.dropFirst(bestLen)).trimmingCharacters(in: .whitespaces)
            return (b.localizedName ?? "", b, rest)
        }
        let t: [String] = a.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let name: String = t.first ?? ""
        return (name, findApp(name), t.count > 1 ? t[1] : "")
    }
    /// Lance une app CACHÉE et sans la passer devant (open -g -j), puis attend qu'elle apparaisse (≤ 5 s).
    static func launchHidden(_ name: String) -> NSRunningApplication? {
        let q: String = fold(name)
        if let b = aliases[q] { _ = runProcess("/usr/bin/open", ["-g", "-j", "-b", b], timeout: 10) }
        else { _ = runProcess("/usr/bin/open", ["-g", "-j", "-a", name], timeout: 10) }
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.5)
            if let x = findApp(name) { Thread.sleep(forTimeInterval: 1.0); return x }
        }
        return nil
    }
    static func appElement(_ app: NSRunningApplication) -> AXUIElement {
        let el: AXUIElement = AXUIElementCreateApplication(app.processIdentifier)
        let bid: String = app.bundleIdentifier ?? ""
        if electronLike.contains(bid) {
            lock.lock(); let first: Bool = manualAX.insert(app.processIdentifier).inserted; lock.unlock()
            if first {
                _ = AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                Thread.sleep(forTimeInterval: 0.4)
            }
        }
        return el
    }
    static func windows(_ appEl: AXUIElement) -> [AXUIElement] { return elements(appEl, "AXWindows") }
    static func pickWindow(_ appEl: AXUIElement, _ q: String) -> (AXUIElement?, Int, Int) {
        let ws: [AXUIElement] = windows(appEl)
        let wq: String = q.trimmingCharacters(in: .whitespaces)
        if !wq.isEmpty {
            if let i = Int(wq), i >= 1, i <= ws.count { return (ws[i - 1], i, ws.count) }
            let f: String = fold(wq)
            if let i = ws.firstIndex(where: { fold(str($0, "AXTitle")).contains(f) }) { return (ws[i], i + 1, ws.count) }
            return (nil, 0, ws.count)
        }
        let focused: AXUIElement? = element(attr(appEl, "AXFocusedWindow")) ?? element(attr(appEl, "AXMainWindow"))
        if let fw = focused {
            let i: Int = (ws.firstIndex(where: { same($0, fw) }) ?? 0) + 1
            return (fw, i, ws.count)
        }
        return (ws.first, ws.isEmpty ? 0 : 1, ws.count)
    }

    // MARK: parcours borné

    static let containerRoles: Set<String> = ["AXGroup", "AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXUnknown", "AXScrollBar", "AXValueIndicator", "AXSplitter", "AXList", "AXOutline", "AXTable", "AXBrowser", "AXColumn", "AXLayoutItem", "AXMatte", "AXGrowArea"]
    static let actionRoles: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXComboBox", "AXLink", "AXMenuItem", "AXTab", "AXRow", "AXCell", "AXSlider", "AXDisclosureTriangle", "AXIncrementor", "AXWindow", "AXSheet", "AXSecureTextField", "AXSearchField", "AXDateField"]

    static func childText(_ el: AXUIElement, depth: Int) -> String {
        if depth <= 0 { return "" }
        for k in elements(el, "AXChildren").prefix(8) {
            let r: String = str(k, "AXRole")
            if r == "AXStaticText" || r == "AXTextField" { let v: String = str(k, "AXValue"); if !v.isEmpty { return v } }
            let t: String = str(k, "AXTitle"); if !t.isEmpty { return t }
            let deeper: String = childText(k, depth: depth - 1); if !deeper.isEmpty { return deeper }
        }
        return ""
    }
    static func makeNode(_ el: AXUIElement, depth: Int, focus: AXUIElement?) -> Node {
        let role: String = str(el, "AXRole")
        let subrole: String = str(el, "AXSubrole")
        let secure: Bool = subrole == "AXSecureTextField" || role == "AXSecureTextField"
        var title: String = str(el, "AXTitle")
        let value: String = secure ? "" : str(el, "AXValue")
        let desc: String = str(el, "AXDescription")
        let ident: String = str(el, "AXIdentifier")
        let help: String = str(el, "AXHelp")
        if title.isEmpty && desc.isEmpty && (role == "AXRow" || role == "AXCell") { title = childText(el, depth: 2) }
        return Node(el: el, role: role, subrole: subrole, title: title, value: value, desc: desc, ident: ident, help: help, depth: depth,
                    focused: same(el, focus), enabled: bool(el, "AXEnabled", fallback: true))
    }
    static func interesting(_ n: Node) -> Bool {
        if n.secure { return true }
        if n.role == "AXStaticText" { return !n.value.isEmpty || !n.title.isEmpty }
        if actionRoles.contains(n.role) { return true }
        return !n.label.isEmpty && !containerRoles.contains(n.role)
    }
    /// Parcours en profondeur, borné (profondeur, nœuds, durée). Aucun attribut n'est écrit.
    static func collect(_ roots: [AXUIElement], focus: AXUIElement?, budget: Int = AXPilot.maxNodes, seconds: TimeInterval = AXPilot.readSeconds) -> (nodes: [Node], visited: Int, truncated: Bool) {
        var out: [Node] = []
        var stack: [(AXUIElement, Int)] = []
        for r in roots.reversed() { stack.append((r, 0)) }
        var visited: Int = 0
        var truncated: Bool = false
        let deadline: Date = Date().addingTimeInterval(seconds)
        while let top = stack.popLast() {
            if visited >= budget || Date() > deadline { truncated = true; break }
            visited += 1
            let n: Node = makeNode(top.0, depth: top.1, focus: focus)
            out.append(n)
            if top.1 < maxDepth && !n.secure {
                let kids: [AXUIElement] = elements(top.0, "AXChildren")
                for k in kids.prefix(300).reversed() { stack.append((k, top.1 + 1)) }
            }
        }
        return (out, visited, truncated)
    }
    static func line(_ i: Int, _ n: Node, withActions: Bool = true) -> String {
        var s: String = "[\(i)] " + n.role
        if !n.subrole.isEmpty && n.subrole != n.role { s += "/" + n.subrole }
        if n.secure { s += " « " + clip(n.title.isEmpty ? n.desc : n.title, 60) + " » (champ mot de passe : jamais lu ni saisi)" }
        else {
            if !n.title.isEmpty { s += " « " + clip(n.title, 90) + " »" }
            if !n.desc.isEmpty && n.desc != n.title { s += " — " + clip(n.desc, 80) }
            if !n.value.isEmpty && n.value != n.title { s += " = " + clip(n.value, 120) }
        }
        if !n.ident.isEmpty { s += " · id=" + clip(n.ident, 40) }
        if let f = frame(n.el) { s += " · \(f.x),\(f.y) \(f.w)×\(f.h)" }
        if withActions { let a: [String] = actions(n.el).filter { $0 != "AXScrollToVisible" }; if !a.isEmpty { s += " · " + a.prefix(4).joined(separator: ",") } }
        if !n.enabled { s += " · inactif" }
        if n.focused { s += " · ◉ FOCUS" }
        return s
    }
    static func item(_ i: Int, _ n: Node) -> [String: Any] {
        var d: [String: Any] = ["i": i, "role": n.role, "subrole": n.subrole, "title": clip(n.title, 120), "desc": clip(n.desc, 120),
                                "value": n.secure ? "" : clip(n.value, 160), "id": clip(n.ident, 60), "secure": n.secure, "focus": n.focused, "enabled": n.enabled]
        if let f = frame(n.el) { d["frame"] = [f.x, f.y, f.w, f.h] }
        d["actions"] = actions(n.el).filter { $0 != "AXScrollToVisible" }
        return d
    }
    static func focusLine(_ appEl: AXUIElement) -> (AXUIElement?, String) {
        guard let f = element(attr(appEl, "AXFocusedUIElement")) else { return (nil, "Focus : aucun élément (ou non exposé par l'app).") }
        let n: Node = makeNode(f, depth: 0, focus: nil)
        var s: String = "Focus : " + n.role
        if n.secure { s += " (champ mot de passe)" }
        else if !n.label.isEmpty { s += " « " + clip(n.label, 90) + " »" }
        return (f, s)
    }

    // MARK: lecture (ax-lire / ax-chercher) — aussi servie à l'écran Contrôle (test en lecture seule)

    public struct ReadResult {
        public let ok: Bool
        public let text: String
        public let items: [[String: Any]]
        public let app: String
        public let window: String
    }
    /// Lit la fenêtre d'une app en arrière-plan. `launch` : lance l'app cachée (open -g -j) si elle ne tourne pas.
    public static func read(appQuery: String, windowQuery: String, actor: String, launch: Bool, logIt: Bool = true) -> ReadResult {
        guard trusted() else { return ReadResult(ok: false, text: permissionMessage(), items: [], app: appQuery, window: "") }
        var app: NSRunningApplication? = findApp(appQuery)
        if app == nil && launch && !appQuery.isEmpty { app = launchHidden(appQuery) }
        guard let a = app else {
            let why: String = launch ? " et n'a pas pu être lancée en arrière-plan (nom d'app inexact ?)" : ""
            return ReadResult(ok: false, text: "ÉCHEC (réel) : « \(appQuery) » n'est pas lancée" + why + ". Rien n'a été lu.", items: [], app: appQuery, window: "")
        }
        let name: String = a.localizedName ?? appQuery
        let appEl: AXUIElement = appElement(a)
        let (fEl, fLine) = focusLine(appEl)
        let picked: (AXUIElement?, Int, Int) = pickWindow(appEl, windowQuery)
        guard let w = picked.0 else {
            let msg: String = picked.2 == 0
                ? "CONSTAT AX (réel) : \(name) tourne mais n'a aucune fenêtre exposée (app cachée sans fenêtre, ou fenêtre fermée). Ses menus restent lisibles : ax-menu \(name)"
                : "ÉCHEC (réel) : aucune fenêtre de \(name) ne correspond à « \(windowQuery) » (\(picked.2) fenêtre(s) : ax-lire \(name) | 1…\(picked.2))."
            if logIt { axLog("ax-lire", app: name, role: "AXApplication", title: "", effect: "lecture (aucune fenêtre)", ok: picked.2 == 0, actor: actor) }
            return ReadResult(ok: picked.2 == 0, text: msg, items: [], app: name, window: "")
        }
        let wTitle: String = str(w, "AXTitle")
        let c: (nodes: [Node], visited: Int, truncated: Bool) = collect([w], focus: fEl)
        let listed: [Node] = Array(c.nodes.filter { interesting($0) }.prefix(maxListed))
        remember(a.processIdentifier, listed)
        var lines: [String] = []
        var items: [[String: Any]] = []
        for (k, n) in listed.enumerated() { lines.append(line(k + 1, n)); items.append(item(k + 1, n)) }
        let more: Int = c.nodes.filter { interesting($0) }.count - listed.count
        var head: String = "CONSTAT AX (réel, lu en arrière-plan — app NON activée) : \(name) · fenêtre « \(clip(wTitle, 80)) » (\(picked.1)/\(picked.2))"
        head += "\n" + fLine
        head += "\nÉléments (index réutilisable 3 min : ax-cliquer \(name) | <index> · ax-saisir \(name) | <index> | <texte>) :"
        var foot: String = "\n(\(c.visited) nœuds parcourus, \(listed.count) listés"
        if more > 0 { foot += ", \(more) de plus non listés" }
        if c.truncated { foot += ", parcours tronqué par les bornes" }
        foot += (more > 0 || c.truncated) ? " : affine avec ax-chercher \(name) | <texte>)" : ")"
        if logIt { axLog("ax-lire", app: name, role: "AXWindow", title: wTitle, effect: "lecture (\(listed.count) éléments)", ok: true, actor: actor) }
        let body: String = lines.isEmpty ? "(aucun élément exposé)" : lines.joined(separator: "\n")
        return ReadResult(ok: true, text: head + "\n" + body + foot, items: items, app: name, window: wTitle)
    }

    static func lire(_ arg: String, actor: String) -> String {
        let a: String = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty {
            let apps: [NSRunningApplication] = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            var l: [String] = []
            for ra in apps {
                var t: String = ra.localizedName ?? "?"
                if ra.isActive { t += " (premier plan)" }
                if ra.isHidden { t += " (masquée)" }
                l.append(t)
            }
            return "Apps lancées (lisibles par ax-lire <app>) : " + l.joined(separator: " · ")
        }
        let p = splitApp(a)
        return read(appQuery: p.app?.localizedName ?? p.name, windowQuery: p.rest, actor: actor, launch: true).text
    }

    /// Recherche dans TOUTES les fenêtres (et la barre des menus si rien trouvé), par rôle / titre / texte.
    static func search(_ app: NSRunningApplication, _ q: String) -> [Node] {
        let appEl: AXUIElement = appElement(app)
        let (fEl, _) = focusLine(appEl)
        let c: (nodes: [Node], visited: Int, truncated: Bool) = collect(windows(appEl), focus: fEl)
        let f: String = fold(q)
        var hits: [Node] = c.nodes.filter { (n: Node) -> Bool in
            if fold(n.role) == f || fold(n.role) == "ax" + f || fold(n.subrole) == f { return true }
            return !n.allText.isEmpty && fold(n.allText).contains(f)
        }
        if hits.isEmpty, let mb = element(attr(appEl, "AXMenuBar")) {
            hits = collect([mb], focus: nil, budget: 800, seconds: 3).nodes.filter { $0.role == "AXMenuItem" && fold($0.title).contains(f) }
        }
        return hits
    }
    static func chercher(_ arg: String, actor: String) -> String {
        let p = splitApp(arg)
        let q: String = p.rest.trimmingCharacters(in: .whitespaces)
        guard !p.name.isEmpty, !q.isEmpty else { return "ax-chercher <app> | <texte ou rôle> — ex. « ax-chercher Notes | Nouvelle note », « ax-chercher Finder | AXButton »." }
        var app: NSRunningApplication? = p.app
        if app == nil { app = launchHidden(p.name) }
        guard let a = app else { return "ÉCHEC (réel) : « \(p.name) » n'est pas lancée et n'a pas pu être lancée en arrière-plan." }
        let name: String = a.localizedName ?? p.name
        let hits: [Node] = Array(search(a, q).prefix(60))
        remember(a.processIdentifier, hits)
        axLog("ax-chercher", app: name, role: "", title: q, effect: "lecture (\(hits.count) résultat(s))", ok: true, actor: actor)
        if hits.isEmpty { return "CONSTAT AX (réel) : aucun élément de \(name) ne contient « \(q) » (fenêtres et menus parcourus, app non activée)." }
        return "CONSTAT AX (réel, app non activée) : \(hits.count) élément(s) de \(name) pour « \(q) » (index réutilisable 3 min) :\n" + hits.enumerated().map { line($0.offset + 1, $0.element) }.joined(separator: "\n")
    }

    // MARK: résolution d'un élément (index du dernier relevé, ou libellé)

    /// Élément visé : index du dernier ax-lire / ax-chercher de cette app, ou libellé (correspondance exacte d'abord).
    /// Renvoie soit l'élément, soit un message (introuvable / ambigu, avec les candidats indexés).
    static func resolve(_ app: NSRunningApplication, _ q: String, wantText: Bool) -> (Node?, String?) {
        let name: String = app.localizedName ?? ""
        let t: String = q.trimmingCharacters(in: .whitespaces)
        if let i = Int(t) {
            if let n = cached(app.processIdentifier, i) { return (n, nil) }
            return (nil, "ÉCHEC : l'index \(i) n'est plus valable pour \(name) (relevé absent ou de plus de 3 min). Relance ax-lire \(name) puis réessaie.")
        }
        let f: String = fold(t)
        let hits: [Node] = search(app, t).filter { (n: Node) -> Bool in
            if wantText { return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"].contains(n.role) || n.secure }
            return n.role != "AXStaticText"
        }
        let kindTxt: String = wantText ? "de saisie " : "actionnable "
        if hits.isEmpty { return (nil, "ÉCHEC (réel) : aucun élément " + kindTxt + "de \(name) ne correspond à « \(t) ». Liste-les : ax-lire \(name).") }
        let exact: [Node] = hits.filter { (n: Node) -> Bool in
            if fold(n.title) == f || fold(n.desc) == f || fold(n.ident) == f { return true }
            return wantText && fold(n.str("AXPlaceholderValue")) == f
        }
        if exact.count == 1 { return (exact[0], nil) }
        if hits.count == 1 { return (hits[0], nil) }
        let cand: [Node] = Array((exact.isEmpty ? hits : exact).prefix(20))
        remember(app.processIdentifier, cand)
        return (nil, "AMBIGU : \(cand.count) éléments de \(name) correspondent à « \(t) ». Choisis par index (valable 3 min) :\n" + cand.enumerated().map { line($0.offset + 1, $0.element) }.joined(separator: "\n"))
    }

    static func frontPid() -> pid_t { return NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }
    static func frontNote(_ before: pid_t, _ app: NSRunningApplication) -> String {
        let after: pid_t = frontPid()
        if after == before { return "premier plan inchangé" }
        if after == app.processIdentifier { return "ATTENTION : \(app.localizedName ?? "l'app") est passée au premier plan d'elle-même (Nova ne l'a pas activée ; la garde du premier plan rend la main)" }
        return "le premier plan a changé pendant l'action (pas du fait de Nova)"
    }
    /// Carte d'approbation ou refus pour un libellé sensible. nil = on peut agir.
    static func guardSensitive(_ raw: String, _ verb: String, _ app: String, _ n: Node, label: String, actor: String) -> String? {
        guard let cat = sensitive(label) else { return nil }
        if cat == "paiement" {
            axLog(verb, app: app, role: n.role, title: label, effect: "refusé (paiement)", ok: false, actor: actor)
            return "REFUSÉ — « \(clip(label, 80)) » ressemble à un paiement : Nova ne paie jamais, ne transfère rien et ne passe aucun ordre. Rends la main à Ahadi en une phrase. Rien n'a été cliqué."
        }
        let key: String = verb + " " + app + " ⟶ " + n.role + " « " + clip(label, 100) + " »"
        if let m = Tools.needConfirm(key, kind: "action AX sensible (\(cat)) dans \(app) : « \(clip(label, 60)) »") {
            axLog(verb, app: app, role: n.role, title: label, effect: "carte d'approbation (\(cat))", ok: false, actor: actor)
            return m
        }
        return nil
    }

    // MARK: actions

    static func cliquer(_ arg: String, actor: String) -> String {
        let p = splitApp(arg)
        guard !p.name.isEmpty, !p.rest.isEmpty else { return "ax-cliquer <app> | <index de ax-lire ou libellé> — ex. « ax-cliquer Notes | 4 »." }
        guard let a = p.app else { return "ÉCHEC (réel) : « \(p.name) » n'est pas lancée : rien à cliquer. (ax-lire \(p.name) la lance en arrière-plan.)" }
        let name: String = a.localizedName ?? p.name
        let r: (Node?, String?) = resolve(a, p.rest, wantText: false)
        guard let n = r.0 else { return r.1 ?? "ÉCHEC : élément introuvable." }
        let label: String = [n.title, n.desc, n.help, n.ident].filter { !$0.isEmpty }.joined(separator: " ")
        if !n.enabled {
            axLog("ax-cliquer", app: name, role: n.role, title: n.label, effect: "refusé (élément inactif)", ok: false, actor: actor)
            return "ÉCHEC (réel) : l'élément « \(clip(n.label, 80)) » est inactif (grisé) dans \(name). Rien n'a été cliqué."
        }
        if let m = guardSensitive(arg, "ax-cliquer", name, n, label: label.isEmpty ? n.label : label, actor: actor) { return m }
        let acts: [String] = actions(n.el)
        let before: pid_t = frontPid()
        let winBefore: String = str(element(attr(appElement(a), "AXFocusedWindow")) ?? n.el, "AXTitle")
        var done: String = ""
        var err: AXError = .actionUnsupported
        for act in ["AXPress", "AXConfirm", "AXPick"] where acts.contains(act) {
            err = AXUIElementPerformAction(n.el, act as CFString); done = act
            break
        }
        if done.isEmpty && (n.role == "AXRow" || n.role == "AXCell") && settable(n.el, "AXSelected") {
            err = AXUIElementSetAttributeValue(n.el, "AXSelected" as CFString, kCFBooleanTrue); done = "AXSelected=true"
        }
        if done.isEmpty && acts.contains("AXRaise") {
            guard Tools.frontAllowed else {
                axLog("ax-cliquer", app: name, role: n.role, title: n.label, effect: "refusé (AXRaise sans demande « devant moi »)", ok: false, actor: actor)
                return "REFUSÉ : cet élément ne se « clique » qu'en le passant devant (AXRaise). Interdit en arrière-plan : seulement si Ahadi demande explicitement « devant moi ». Rien n'a été fait."
            }
            err = AXUIElementPerformAction(n.el, "AXRaise" as CFString); done = "AXRaise (demande « devant moi »)"
        }
        if done.isEmpty {
            axLog("ax-cliquer", app: name, role: n.role, title: n.label, effect: "échec (aucune action AX)", ok: false, actor: actor)
            return "ÉCHEC (réel) : « \(clip(n.label, 80)) » (\(n.role)) n'expose aucune action cliquable (actions : \(acts.isEmpty ? "aucune" : acts.joined(separator: ",")))."
        }
        let ok: Bool = err == .success
        Thread.sleep(forTimeInterval: 0.5)
        let winAfter: String = str(element(attr(appElement(a), "AXFocusedWindow")) ?? n.el, "AXTitle")
        let fn: String = frontNote(before, a)
        axLog("ax-cliquer", app: name, role: n.role, title: n.label, effect: ok ? "clic (\(done))" : "échec (\(done) : AXError \(err.rawValue))", ok: ok, actor: actor, detail: fn)
        if !ok { return "ÉCHEC (réel) : \(done) refusé par \(name) (AXError \(err.rawValue)) sur « \(clip(n.label, 80)) ». Rien n'est prouvé." }
        var s: String = "CONSTAT AX (réel) : \(done) accepté par \(name) sur \(n.role) « \(clip(n.label, 80)) » — \(fn)."
        s += winAfter != winBefore ? " Fenêtre active : « \(clip(winBefore, 60)) » → « \(clip(winAfter, 60)) »." : " Fenêtre active inchangée (« \(clip(winAfter, 60)) ») : relis avec ax-lire \(name) pour constater l'effet."
        return s
    }

    static func saisir(_ arg: String, actor: String) -> String {
        let p = splitApp(arg)
        var target: String = ""
        var text: String = ""
        if arg.contains("|") {
            let parts: [String] = p.rest.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
            target = parts.first ?? ""
            text = parts.count > 1 ? parts[1] : ""
        } else {
            let r: String = p.rest
            if let q0 = r.first, q0 == "\"" || q0 == "«" {
                let close: Character = q0 == "\"" ? "\"" : "»"
                let body: Substring = r.dropFirst()
                if let e = body.firstIndex(of: close) {
                    target = String(body[..<e]).trimmingCharacters(in: .whitespaces)
                    text = String(body[body.index(after: e)...]).trimmingCharacters(in: .whitespaces)
                }
            } else {
                let t: [String] = r.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
                target = t.first ?? ""
                text = t.count > 1 ? t[1] : ""
            }
        }
        guard !p.name.isEmpty, !target.isEmpty else { return "ax-saisir <app> | <index ou libellé du champ> | <texte> — ex. « ax-saisir Notes | 7 | Liste de courses ». Aucune touche Entrée n'est envoyée." }
        guard let a = p.app else { return "ÉCHEC (réel) : « \(p.name) » n'est pas lancée : aucun champ à remplir." }
        let name: String = a.localizedName ?? p.name
        let r: (Node?, String?) = resolve(a, target, wantText: true)
        guard let n = r.0 else { return r.1 ?? "ÉCHEC : champ introuvable." }
        let label: String = [n.title, n.desc, n.help, n.ident, n.str("AXPlaceholderValue")].filter { !$0.isEmpty }.joined(separator: " ")
        if n.secure || Tools.match(secretLabelRx, label) {
            axLog("ax-saisir", app: name, role: n.role, title: label, effect: "refusé (champ mot de passe / secret)", ok: false, actor: actor)
            return "REFUSÉ : « \(clip(label.isEmpty ? n.role : label, 60)) » est un champ de mot de passe ou de secret. Nova n'y saisit jamais rien : Ahadi le tape lui-même. Rien n'a été saisi."
        }
        if Tools.match(secretLabelRx, text) || Tools.shellMentionsSensitive(text) {
            axLog("ax-saisir", app: name, role: n.role, title: label, effect: "refusé (texte contenant un secret)", ok: false, actor: actor)
            return "REFUSÉ : le texte à saisir ressemble à un secret (mot de passe, clé, jeton). Nova ne saisit jamais de secret. Rien n'a été saisi."
        }
        guard ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(n.role) || n.subrole == "AXSearchField" else {
            return "ÉCHEC : « \(clip(n.label, 60)) » (\(n.role)) n'est pas un champ de texte. Cherche le champ : ax-chercher \(name) | AXTextField."
        }
        guard n.enabled, settable(n.el, "AXValue") else {
            axLog("ax-saisir", app: name, role: n.role, title: n.label, effect: "échec (valeur non modifiable par AX)", ok: false, actor: actor)
            return "ÉCHEC (réel) : \(name) n'autorise pas l'écriture AX de ce champ (« \(clip(n.label, 60)) »). Rien n'a été saisi ; pas de frappe simulée en arrière-plan."
        }
        let before: pid_t = frontPid()
        let err: AXError = AXUIElementSetAttributeValue(n.el, "AXValue" as CFString, text as CFString)
        Thread.sleep(forTimeInterval: 0.3)
        let now: String = str(n.el, "AXValue")
        let verified: Bool = err == .success && now == text
        let fn: String = frontNote(before, a)
        axLog("ax-saisir", app: name, role: n.role, title: n.label, effect: err == .success ? (verified ? "saisie (valeur relue identique)" : "saisie (valeur relue différente)") : "échec (AXError \(err.rawValue))", ok: err == .success, actor: actor, detail: "\(text.count) caractères ; " + fn)
        if err != .success { return "ÉCHEC (réel) : \(name) a refusé la valeur (AXError \(err.rawValue)). Rien n'est prouvé." }
        if verified { return "CONSTAT AX VÉRIFIÉ : champ \(n.role) « \(clip(n.label, 60)) » de \(name) = \(text.count) caractères (valeur relue identique) — aucune touche Entrée envoyée, rien n'est parti — \(fn)." }
        return "CONSTAT AX (partiel) : \(name) a accepté la valeur, mais la relecture diffère (« \(clip(now, 80)) »). L'app a pu la reformater ou l'ignorer : relis avec ax-lire \(name). Aucune touche Entrée envoyée — \(fn)."
    }

    static func menu(_ arg: String, actor: String) -> String {
        let p = splitApp(arg)
        guard !p.name.isEmpty else { return "ax-menu <app> | <Menu > Élément [> Sous-élément]> — ex. « ax-menu Notes | Fichier > Nouvelle note ». Sans chemin : liste les menus." }
        guard let a = p.app else { return "ÉCHEC (réel) : « \(p.name) » n'est pas lancée : aucun menu à lire." }
        let name: String = a.localizedName ?? p.name
        let appEl: AXUIElement = appElement(a)
        guard let mb = element(attr(appEl, "AXMenuBar")) else { return "ÉCHEC (réel) : \(name) n'expose pas sa barre des menus à l'Accessibilité." }
        let path: [String] = p.rest.components(separatedBy: CharacterSet(charactersIn: ">›")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        func titles(_ els: [AXUIElement]) -> [String] { return els.map { str($0, "AXTitle") }.filter { !$0.isEmpty } }
        func norm(_ s: String) -> String { return fold(s.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")) }
        func pick(_ els: [AXUIElement], _ q: String) -> AXUIElement? {
            let f: String = norm(q)
            if let x = els.first(where: { norm(str($0, "AXTitle")) == f }) { return x }
            let part: [AXUIElement] = els.filter { norm(str($0, "AXTitle")).hasPrefix(f) }
            return part.count == 1 ? part[0] : nil
        }
        /// Éléments d'un niveau : barre (AXMenuBarItem) ou contenu du sous-menu (AXMenu → AXMenuItem).
        func level(_ el: AXUIElement) -> [AXUIElement] {
            let kids: [AXUIElement] = elements(el, "AXChildren")
            if str(el, "AXRole") == "AXMenuBar" { return kids }
            if let sub = kids.first(where: { str($0, "AXRole") == "AXMenu" }) { return elements(sub, "AXChildren") }
            return []
        }
        var cur: AXUIElement = mb
        var trail: [String] = []
        for step in path {
            let opts: [AXUIElement] = level(cur)
            guard let nx = pick(opts, step) else {
                axLog("ax-menu", app: name, role: "AXMenu", title: (trail + [step]).joined(separator: " > "), effect: "échec (introuvable)", ok: false, actor: actor)
                let avail: [String] = titles(opts)
                let inTxt: String = trail.isEmpty ? "la barre des menus" : "« " + trail.joined(separator: " > ") + " »"
                let availTxt: String = avail.isEmpty ? "(aucun élément exposé — certains menus ne se remplissent qu'à l'ouverture)" : avail.prefix(40).joined(separator: " · ")
                return "ÉCHEC (réel) : « \(step) » introuvable dans " + inTxt + " de \(name). Disponibles : " + availTxt
            }
            cur = nx; trail.append(str(nx, "AXTitle"))
        }
        let sub: [AXUIElement] = level(cur)
        if path.isEmpty || !sub.isEmpty {
            axLog("ax-menu", app: name, role: "AXMenu", title: trail.joined(separator: " > "), effect: "lecture", ok: true, actor: actor)
            let lst: [String] = sub.map { (e: AXUIElement) -> String in
                let t: String = str(e, "AXTitle")
                let en: Bool = bool(e, "AXEnabled", fallback: true)
                return t.isEmpty ? "—" : t + (en ? "" : " (grisé)")
            }
            let whereTxt: String = trail.isEmpty ? "barre des menus" : "« " + trail.joined(separator: " > ") + " »"
            let listTxt: String = lst.isEmpty ? "(vide ou non exposé)" : lst.prefix(60).joined(separator: " · ")
            let nextTxt: String = trail.isEmpty ? "<Menu> > <Élément>" : trail.joined(separator: " > ") + " > <Élément>"
            var out: String = "CONSTAT AX (réel, app non activée) : menu " + whereTxt
            out += " de \(name) : " + listTxt
            out += "\nPour exécuter un élément : ax-menu \(name) | " + nextTxt
            return out
        }
        let n: Node = makeNode(cur, depth: 0, focus: nil)
        let full: String = trail.joined(separator: " > ")
        if !n.enabled {
            axLog("ax-menu", app: name, role: "AXMenuItem", title: full, effect: "refusé (élément grisé)", ok: false, actor: actor)
            return "ÉCHEC (réel) : « \(full) » est grisé dans \(name) (indisponible dans l'état actuel). Rien n'a été fait."
        }
        if let m = guardSensitive(arg, "ax-menu", name, n, label: full, actor: actor) { return m }
        let before: pid_t = frontPid()
        let err: AXError = AXUIElementPerformAction(cur, "AXPress" as CFString)
        Thread.sleep(forTimeInterval: 0.5)
        let fn: String = frontNote(before, a)
        axLog("ax-menu", app: name, role: "AXMenuItem", title: full, effect: err == .success ? "menu exécuté (AXPress)" : "échec (AXError \(err.rawValue))", ok: err == .success, actor: actor, detail: fn)
        if err != .success { return "ÉCHEC (réel) : \(name) a refusé « \(full) » (AXError \(err.rawValue)). Rien n'est prouvé." }
        return "CONSTAT AX (réel) : menu « \(full) » exécuté dans \(name) (AXPress accepté) — \(fn). Relis avec ax-lire \(name) pour constater l'effet."
    }
    #endif
}

#if os(macOS)
extension AXPilot.Node {
    func str(_ name: String) -> String { return AXPilot.str(el, name) }
}
#endif

// MARK: routes de l'écran Contrôle (lecture seule)

extension NovaApp {
    /// GET /api/ax/etat · POST /api/ax/test {app: "Notes"|"Finder"} (LECTURE SEULE, jamais de lancement) · GET /api/ax/journal
    func axRoutes() {
        let s: HTTPServer = server
        s.on("GET", "/api/ax/etat") { _, res in res.json(AXPilot.status()) }
        s.on("GET", "/api/ax/journal") { _, res in res.json(["items": AXPilot.journalItems(20)]) }
        s.on("POST", "/api/ax/test") { req, res in
            let app: String = (req.json["app"] as? String) ?? "Finder"
            guard ["Notes", "Finder"].contains(app) else { res.json(["ok": false, "error": "Test limité à Notes ou Finder (lecture seule)."], status: 400); return }
            #if os(macOS)
            let r: AXPilot.ReadResult = AXPilot.read(appQuery: app, windowQuery: "", actor: "Toi", launch: false)
            res.json(["ok": r.ok, "app": r.app, "window": r.window, "text": r.text, "items": Array(r.items.prefix(60)), "trusted": AXPilot.trusted()])
            #else
            res.json(["ok": false, "text": "Indisponible hors macOS.", "items": [Any](), "trusted": false])
            #endif
        }
    }
}
