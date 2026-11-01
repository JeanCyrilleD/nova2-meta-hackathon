#if canImport(AppKit)
import AppKit
import CoreServices
import WebKit
import NovaCore

// NOVA PARTOUT (24/10) — Nova accessible depuis tout le Mac, sans voler le premier plan :
//   • ⌃⌥Espace (Carbon RegisterEventHotKey, aucun droit d'Accessibilité) ouvre / ferme le panneau compact non activant ;
//   • schéma d'URL nova:// (Info.plist › CFBundleURLTypes) : nova://ask?q=…, nova://open?page=…, nova://dictee ;
//   • Services macOS « Demander à Nova », « Résumer avec Nova », « Retenir dans Nova » (NovaServiceProvider, main.swift) ;
//   • menu de la barre : état + halo d'activité en une ligne.
// Règle : une URL ou un Service ne fait QUE pré-remplir / afficher. Aucun envoi, aucune écriture sans geste dans le panneau.
// Le schéma « nova » sert aussi au bus interne WebKit (nova://app/…, NovaSchemeHandler) : ces hôtes sont ignorés ici.

extension AppDelegate {

    /// Pages ouvrables par nova://open?page=… (identifiants des modules de web/js/shell.js). Toute autre valeur → fenêtre seule.
    static let openablePages: Set<String> = [
        "accueil", "veille", "finance", "messages", "dots", "conversations", "conseil", "livrables", "radio", "vie",
        "temps", "savoir", "journal", "ame", "relations", "engagements", "confiance", "controle", "systeme", "settings",
    ]

    /// Masque arrondi étirable pour le verre natif du panneau compact.
    nonisolated static func roundedMask(radius: CGFloat) -> NSImage {
        let side: CGFloat = radius * 2 + 1
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { (rect: NSRect) -> Bool in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    // MARK: - Schéma d'URL

    func installURLHandler() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let u = URL(string: raw) else { return }
        handleNovaURL(u)
    }

    /// nova://ask?q=…  nova://open?page=…  nova://dictee — jamais d'action sensible : afficher, pré-remplir, basculer la dictée.
    func handleNovaURL(_ u: URL) {
        guard (u.scheme ?? "").lowercased() == "nova" else { return }
        guard launchDone, panel != nil, panelView != nil, main != nil else { pendingURLs.append(u); return }
        let host: String = (u.host ?? "").lowercased()
        let comps: URLComponents? = URLComponents(url: u, resolvingAgainstBaseURL: false)
        func param(_ k: String) -> String { comps?.queryItems?.first(where: { (it: URLQueryItem) -> Bool in it.name == k })?.value ?? "" }
        // Journal : l'hôte seul — jamais le texte de la question.
        _ = BlackBox.record(["tool": "url_nova", "actor": "Nova", "why": "URL nova:// reçue", "ok": true, "effect": "lecture", "result": "hote=" + String(host.prefix(20))])
        switch host {
        case "ask", "demander":
            var q: String = param("q")
            if q.isEmpty { q = param("text") }
            showAsk(text: String(q.prefix(4000)), context: "", mode: "ask", source: "url")
        case "open", "ouvrir":
            let page: String = param("page").lowercased()
            if AppDelegate.openablePages.contains(page) { openMainPage(page) } else { showMain() }
        case "dictee", "dictation":
            Dictee.shared.toggle()
        default:
            break   // nova://app/… et nova://api/… : bus interne WebKit, sans objet ici ; hôtes inconnus ignorés
        }
    }

    // MARK: - Scripts vers les pages (attendent la fin de chargement)

    func runJS(_ v: WKWebView?, _ js: String) {
        guard let v = v else { return }
        let key = ObjectIdentifier(v)
        if webReady.contains(key) { v.evaluateJavaScript(js, completionHandler: nil) }
        else { webPending[key, default: []].append(js) }
    }

    nonisolated static func jsonLiteral(_ o: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: []), let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: - Panneau compact

    /// Ouvre le panneau compact (non activant) et le pré-remplit. mode : "ask" | "resume" | "retenir". N'envoie rien.
    func showAsk(text: String, context: String, mode: String, source: String) {
        ask()
        let payload: String = AppDelegate.jsonLiteral(["text": text, "context": context, "mode": mode, "source": source])
        let js: String = "(function(p){var n=0;(function go(){if(window.Nova&&window.Nova.prefill){window.Nova.prefill(p)}else if(n++<40){setTimeout(go,150)}})()})(" + payload + ")"
        runJS(panelView, js)
    }

    /// ⌃⌥Espace : ouvre le panneau, ou le ferme s'il a déjà le clavier.
    @objc func toggleAsk() {
        if panel.isVisible { hideAskPanel(); return }   // 25/10 : un 2e clic sur le compagnon (panneau visible mais non clé) le referme
        ask()
    }

    /// Échap / ✕ : le panneau se retire ; le clavier revient à l'app qui était devant (Nova n'a jamais été activée).
    func hideAskPanel() {
        panelSummonedAt = Date.distantPast
        panelHiddenByUser = true
        panel.orderOut(nil)
    }

    @objc func toggleDictee() { Dictee.shared.toggle() }

    /// nova://open?page=… : fenêtre principale sur le module demandé (geste explicite → Nova passe devant).
    func openMainPage(_ page: String) {
        showMain()
        let lit: String = AppDelegate.jsonLiteral(["p": page])
        runJS(mainView, "(function(o){var n=0;(function go(){var W=window.NovaWorkspace;if(W&&W.navigate){W.navigate(o.p)}else if(n++<40){setTimeout(go,250)}})()})(" + lit + ")")
    }

    /// « Continuer dans Nova » : même conversation ouverte dans la fenêtre principale (module Conversations).
    func continueInMain(cid: String) {
        let ok: Bool = !cid.isEmpty && cid.count <= 120 && cid.unicodeScalars.allSatisfy { (c: Unicode.Scalar) -> Bool in
            CharacterSet.alphanumerics.contains(c) || c == "-" || c == "_" || c == "." || c == ":"
        }
        hideAskPanel()
        showMain()
        guard ok else { return }
        let lit: String = AppDelegate.jsonLiteral(["cid": cid])
        let js: String = "(function(o){try{localStorage.setItem('nova2_pending_conv',o.cid)}catch(e){};var n=0;(function go(){var W=window.NovaWorkspace;if(W&&W.navigate){W.navigate('conversations');setTimeout(function(){try{window.NovaBus&&window.NovaBus.emit('nova:open-conv',{cid:o.cid,id:o.cid})}catch(e){}},150)}else if(n++<40){setTimeout(go,250)}})()})(" + lit + ")"
        runJS(mainView, js)
    }

    // MARK: - Barre de menus

    /// Ouverture du menu : relecture immédiate (même chemin que la relève périodique de V5-E).
    func refreshStatusActivity() {
        refreshStatusLive()
    }

    // MARK: - V5-E : présence vivante (Muse « Charm »)

    /// Relève périodique de l'état : 20 s (tolérance 5 s), trois GET locaux en lecture seule, aucun sondage
    /// pendant qu'une relève est déjà en vol. Première relève 4 s après le lancement.
    func startStatusLive() {
        statusTimer?.invalidate()
        let t: Timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] (_: Timer) in
            self?.refreshStatusLive()
        }
        t.tolerance = 5
        statusTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.refreshStatusLive()
        }
    }

    /// GET local authentifié par le jeton de session (en-tête, jamais journalisé). Réponse rendue sur le fil principal ; échec → nil.
    func statusGet(_ path: String, _ done: @escaping ([String: Any]?) -> Void) {
        guard core != nil, !base.isEmpty, let url = URL(string: base + path) else { done(nil); return }
        var req: URLRequest = URLRequest(url: url, timeoutInterval: 6)
        req.setValue(core.server.token, forHTTPHeaderField: "X-Nova-Token")
        URLSession.shared.dataTask(with: req) { (data: Data?, resp: URLResponse?, err: Error?) in
            var o: [String: Any]? = nil
            if let data = data, (resp as? HTTPURLResponse)?.statusCode == 200 {
                o = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
            }
            let out: [String: Any]? = o
            DispatchQueue.main.async { done(out) }
        }.resume()
    }

    /// Relit l'activité (mêmes sources que le halo et les cartes de l'interface) et met à jour icône, titre et menu.
    func refreshStatusLive() {
        if statusLiveInflight { return }
        statusLiveInflight = true
        statusGet("/api/activity") { [weak self] (act: [String: Any]?) in
            guard let me = self else { return }
            me.statusGet("/api/drafts") { (dr: [String: Any]?) in
                me.statusGet("/api/dots/waiting") { (wt: [String: Any]?) in
                    me.applyStatus(activity: act, drafts: dr, waiting: wt)
                }
            }
        }
    }

    nonisolated static func goPhrase(_ n: Int) -> String {
        return n > 1 ? "\(n) GO attendus" : "\(n) GO attendu"
    }

    /// Applique l'état relevé. Aucune valeur inventée : sans réponse du moteur, l'icône et le menu disent « moteur muet ».
    func applyStatus(activity act: [String: Any]?, drafts dr: [String: Any]?, waiting wt: [String: Any]?) {
        statusLiveInflight = false
        let engineDown: Bool = act == nil && dr == nil && wt == nil
        let running: [[String: Any]] = ((act?["running"] as? [[String: Any]]) ?? []).filter { (x: [String: Any]) -> Bool in
            !(((x["label"] as? String) ?? (x["name"] as? String) ?? "").isEmpty)
        }
        // Brouillons à approuver : même règle que l'interface (peek.js, accueil.js) — ni « sent », ni statut « sent ».
        let draftItems: [[String: Any]] = (dr?["items"] as? [[String: Any]]) ?? []
        let drafts: Int = draftItems.filter { (x: [String: Any]) -> Bool in
            if let v = x["sent"], !(v is NSNull) {
                if let b = v as? Bool { if b { return false } } else { return false }
            }
            if let st = x["status"] as? String, st == "sent" { return false }
            return true
        }.count
        // Éclats en attente d'une DÉCISION d'Ahadi (un simple « a terminé » n'est pas un GO).
        let waitItems: [[String: Any]] = (wt?["items"] as? [[String: Any]]) ?? []
        let dots: Int = waitItems.filter { (x: [String: Any]) -> Bool in (x["decision"] as? Bool) == true }.count
        statusGoDrafts = drafts; statusGoDots = dots
        let go: Int = drafts + dots
        let busy: Bool = !running.isEmpty

        var state: String = engineDown ? "Nova · moteur muet (aucune réponse locale)" : (busy ? "Nova · Réfléchit" : "Nova · Au repos")
        if !engineDown && go > 0 { state += " · " + AppDelegate.goPhrase(go) }
        statusStateItem?.title = state

        var halo: String = "Activité : moteur muet"
        if act != nil {
            if let first = running.first {
                let nm: String = (first["name"] as? String) ?? ""
                let lb: String = (first["label"] as? String) ?? ""
                let name: String = lb.isEmpty ? nm : (nm.isEmpty ? lb : nm + " — " + lb)
                let short: String = name.count > 56 ? String(name.prefix(55)) + "…" : name
                halo = "En cours : " + short + (running.count > 1 ? " (+\(running.count - 1))" : "")
            } else {
                halo = "Activité : rien ne tourne en ce moment"
            }
        }
        statusHaloItem?.title = halo

        if let gi = statusGoItem {
            if engineDown || (dr == nil && wt == nil) {
                gi.title = "GO attendus : inconnus (moteur muet)"; gi.action = nil; gi.target = nil; gi.isEnabled = false
            } else if go == 0 {
                gi.title = "Aucun GO en attente"; gi.action = nil; gi.target = nil; gi.isEnabled = false
            } else {
                var parts: [String] = []
                if drafts > 0 { parts.append("\(drafts) brouillon" + (drafts > 1 ? "s" : "") + " à approuver") }
                if dots > 0 { parts.append("\(dots) Éclat" + (dots > 1 ? "s" : "") + " en attente de décision") }
                gi.title = AppDelegate.goPhrase(go) + " : " + parts.joined(separator: " · ") + "…"
                gi.action = #selector(openGo); gi.target = self; gi.isEnabled = true
            }
        }

        if let b = status?.button {
            b.image = AppDelegate.statusGlyph(engineDown ? 0 : (busy ? 2 : 1))
            b.title = (!engineDown && go > 0) ? " \(go)" : ""
            b.imagePosition = b.title.isEmpty ? .imageOnly : .imageLeft
            b.toolTip = state
            b.setAccessibilityLabel(state)
        }
    }

    /// Clic explicite sur la ligne « GO attendus » : la fenêtre Nova s'ouvre sur l'écran qui porte ces GO.
    @objc func openGo() {
        openMainPage(statusGoDrafts > 0 ? "messages" : "dots")
    }

    /// Glyphes modèles (teintés par macOS) : 0 = moteur muet (anneau pointillé), 1 = au repos (anneau + point),
    /// 2 = réfléchit (anneau + cœur plein).
    nonisolated static func statusGlyph(_ kind: Int) -> NSImage {
        let img: NSImage = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { (_: NSRect) -> Bool in
            NSColor.black.set()
            let ring: NSBezierPath = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 13, height: 13))
            ring.lineWidth = 1.6
            if kind == 0 {
                let dash: [CGFloat] = [2.2, 2.0]
                ring.setLineDash(dash, count: dash.count, phase: 0)
            }
            ring.stroke()
            if kind == 2 {
                NSBezierPath(ovalIn: NSRect(x: 5.0, y: 5.0, width: 8.0, height: 8.0)).fill()
            } else if kind == 1 {
                NSBezierPath(ovalIn: NSRect(x: 6.75, y: 6.75, width: 4.5, height: 4.5)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: - V5-E : passation de main sur les volets web

    /// Moniteur LOCAL (événements adressés à Nova seulement, aucun droit d'Accessibilité, événement rendu intact) :
    /// un clic gauche d'Ahadi dans un volet web affiché est signalé à la fenêtre (NovaNative.onPaneTouch) —
    /// uibridge.js met alors ce volet en pause pour Nova jusqu'à « Rendre la main à Nova ».
    func installPaneTouchMonitor() {
        _ = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] (e: NSEvent) -> NSEvent? in
            self?.notePaneTouch(e)
            return e
        }
    }

    func notePaneTouch(_ e: NSEvent) {
        guard let w: NSWindow = e.window else { return }
        var hit: String = ""
        if let mw = main, w === mw, let c = container {
            let pt: NSPoint = c.convert(e.locationInWindow, from: nil)
            for (pid, v) in panes {
                if let q = v as? QuietWebView, q.quiet { continue }
                if v.isHidden || v.alphaValue < 0.01 || v.superview !== c { continue }
                if v.frame.contains(pt) { hit = pid; break }
            }
        } else {
            for (pid, win) in detachedPanes where win === w { hit = pid; break }
        }
        guard !hit.isEmpty, mainView != nil else { return }
        let paneId: String = hit.hasSuffix(".pop") ? String(hit.dropLast(4)) : hit
        let lit: String = AppDelegate.jsonLiteral(["id": paneId])
        mainView.evaluateJavaScript("window.NovaNative&&NovaNative.onPaneTouch&&NovaNative.onPaneTouch(" + lit + ")", completionHandler: nil)
    }
}
#endif
