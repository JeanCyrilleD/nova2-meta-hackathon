#if canImport(AppKit)
import AppKit
import WebKit
import Carbon.HIToolbox
import NovaCore
import PDFKit
import Network

// Nova — coquille macOS native : fenêtre principale + assistant flottant 3D + icône de barre de menus + raccourci global ⌥Espace.
// Toute la logique (cerveaux, voix, briefs, dots) tourne dans NovaCore, dans ce même processus, sur 127.0.0.1 uniquement.

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// 25/10 : le 1er clic sur une fenêtre flottante non clé (compagnon, panneau) atteint la page au lieu d'être avalé.
final class NovaWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }
}

/// Volets web natifs (WhatsApp, Telegram, Facebook, navigateur) : de vraies WKWebView à session persistante, posées par-dessus la zone réservée par l'interface.
/// Téléchargements (exports CSV/JSON/Markdown, fichiers des volets web) : enregistrés dans ~/Téléchargements, puis révélés dans le Finder.
final class DownloadHandler: NSObject, WKDownloadDelegate {
    static let shared = DownloadHandler()
    var dest: [ObjectIdentifier: URL] = [:]
    func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        var name = suggestedFilename.isEmpty ? "nova-export" : suggestedFilename.replacingOccurrences(of: "/", with: "-")
        var u = dir.appendingPathComponent(name); var i = 1
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: u.path) { name = base + " (\(i))" + (ext.isEmpty ? "" : "." + ext); u = dir.appendingPathComponent(name); i += 1 }
        dest[ObjectIdentifier(d)] = u; completionHandler(u)
    }
    func downloadDidFinish(_ d: WKDownload) {
        if let u = dest.removeValue(forKey: ObjectIdentifier(d)) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }
    func download(_ d: WKDownload, didFailWithError e: Error, resumeData: Data?) {
        dest.removeValue(forKey: ObjectIdentifier(d))
        let a = NSAlert(); a.messageText = "Téléchargement impossible"; a.informativeText = e.localizedDescription; a.runModal()
    }

    /// Écriture d'octets déjà récupérés (voie nova://, voir AppDelegate.fetchNovaDownload) :
    /// même dossier, même nom sûr et dédupliqué que decideDestinationUsing, puis révélation Finder.
    static func save(_ data: Data, suggestedName: String) -> URL? {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        var name = suggestedName.isEmpty ? "nova-export" : suggestedName.replacingOccurrences(of: "/", with: "-")
        var u = dir.appendingPathComponent(name); var i = 1
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: u.path) { name = stem + " (\(i))" + (ext.isEmpty ? "" : "." + ext); u = dir.appendingPathComponent(name); i += 1 }
        do { try data.write(to: u); NSWorkspace.shared.activateFileViewerSelecting([u]); return u } catch { return nil }
    }
}

/// Volet web « silencieux » : rendu normal par WebKit (dans la fenêtre, derrière l'interface, alpha 0), mais invisible et jamais cliquable.
/// Remplace le placement hors écran (x = -20000) : hors écran, WebKit cessait de construire les pages lourdes (Outlook, Teams) et l'assistant
/// lisait « about:blank » ou une page vide.
final class QuietWebView: WKWebView {
    var quiet: Bool = false
    override func hitTest(_ point: NSPoint) -> NSView? { return quiet ? nil : super.hitTest(point) }
    override var acceptsFirstResponder: Bool { return quiet ? false : super.acceptsFirstResponder }
}

final class PaneDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id: String; weak var owner: AppDelegate?
    init(id: String, owner: AppDelegate) { self.id = id; self.owner = owner }
    // NOVA2-PUSH : les événements de navigation partent en rafales (Outlook/Teams) ; on coalesce à 1 push / 250 ms,
    // dernier état gagnant. Le thread principal n'est plus un bus d'événements.
    private var lastPushAt = Date.distantPast
    private var trailingPush: DispatchWorkItem?
    func push(_ v: WKWebView, error: String? = nil) {
        if Date().timeIntervalSince(lastPushAt) < 0.25 {
            trailingPush?.cancel()
            let work = DispatchWorkItem { [weak self, weak v] in guard let self = self, let v = v else { return }; self.pushNow(v, error: error) }
            trailingPush = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            return
        }
        pushNow(v, error: error)
    }
    private func pushNow(_ v: WKWebView, error: String? = nil) {
        lastPushAt = Date()
        owner?.notePaneUsed(id)   // NOVA2-VOLETS : toute activité du volet repousse sa récolte
        var o: [String: Any] = ["id": id, "url": v.url?.absoluteString ?? "", "title": v.title ?? "", "loading": v.isLoading, "canBack": v.canGoBack, "canForward": v.canGoForward, "zoom": v.pageZoom]
        if let e = error { o["error"] = e }
        if let d = try? JSONSerialization.data(withJSONObject: o), let j = String(data: d, encoding: .utf8) { owner?.mainView.evaluateJavaScript("window.NovaNative&&NovaNative.onNav(\(j))", completionHandler: nil) }
    }
    /// 29/10 (Ahadi : « un lien cliqué dans Zoho transforme la page du mail, sans retour ») — pages de connexion :
    /// elles restent dans leur fenêtre surgissante (la connexion en dépend), tout le reste s'ouvre À CÔTÉ.
    static func isAuthHost(_ h: String) -> Bool {
        let x: String = h.lowercased()
        let fixed: [String] = ["login.microsoftonline.com", "login.live.com", "login.windows.net", "accounts.google.com", "appleid.apple.com", "web.whatsapp.com"]
        if fixed.contains(x) { return true }
        return x.hasPrefix("accounts.zoho.") || x.hasPrefix("login.") || x.hasPrefix("auth.") || x.hasPrefix("sso.") || x.contains("oauth")
    }
    /// 29/10 (Ahadi : « the sign in button for Teams isn't working ») — domaines d'un même éditeur (connexion,
    /// retour de connexion, documents) : jamais relayés « à côté », sinon la connexion casse en route.
    static func vendor(_ h: String?) -> String {
        guard let x0 = h?.lowercased() else { return "" }
        let x: String = x0
        let groups: [(String, [String])] = [
            ("ms", ["microsoft.com", "cloud.microsoft", "microsoftonline.com", "live.com", "office.com", "office.net", "office365.com", "sharepoint.com", "skype.com", "msauth.net", "msftauth.net", "windows.net"]),
            ("g", ["google.com", "gstatic.com", "googleusercontent.com"]),
            ("z", ["zoho.com", "zoho.eu", "zohocdn.com"]),
            ("wa", ["whatsapp.com", "whatsapp.net"])]
        for (k, list) in groups { for f in list where x == f || x.hasSuffix("." + f) { return k } }
        return ""
    }
    /// Reste DANS le volet : page de connexion, ou même éditeur que le volet (connexion Teams → retour Teams).
    static func keepInside(_ h: String, paneHost: String?) -> Bool {
        if isAuthHost(h) { return true }
        let v: String = vendor(h)
        return !v.isEmpty && v == vendor(paneHost)
    }
    nonisolated(unsafe) static var authSeen: Set<String> = []
    /// Lien de redirection du même service (« …?url=https://… », « ?q= », « ?u= ») → adresse réelle, sinon nil.
    static func redirectTarget(_ u: URL) -> URL? {
        guard let c = URLComponents(url: u, resolvingAgainstBaseURL: false), let items = c.queryItems else { return nil }
        for it in items where ["url", "u", "q", "target", "redirect", "redirect_url", "dest", "link"].contains(it.name.lowercased()) {
            if let v = it.value, v.lowercased().hasPrefix("http"), let t = URL(string: v), t.host != nil { return t }
        }
        return nil
    }
    nonisolated(unsafe) static var lastBeside: (url: String, at: Date) = ("", Date.distantPast)
    /// Même site (deux derniers niveaux du nom d'hôte) : une fenêtre du service lui-même, pas un lien sortant.
    static func sameSite(_ a: String?, _ b: String?) -> Bool {
        guard let x = a?.lowercased(), let y = b?.lowercased() else { return false }
        let ka: String = x.split(separator: ".").suffix(2).joined(separator: ".")
        let kb: String = y.split(separator: ".").suffix(2).joined(separator: ".")
        return ka == kb
    }
    func openBeside(_ u: URL) {
        // garde-fou anti-boucle : la même adresse n'est relayée qu'une fois toutes les 5 s
        let key: String = u.absoluteString
        if PaneDelegate.lastBeside.url == key && Date().timeIntervalSince(PaneDelegate.lastBeside.at) < 5 { return }
        PaneDelegate.lastBeside = (key, Date())
        if let d = try? JSONSerialization.data(withJSONObject: [u.absoluteString]), let j = String(data: d, encoding: .utf8) {
            owner?.mainView.evaluateJavaScript("window.NovaOpenUrl&&window.NovaOpenUrl(\(j)[0])", completionHandler: nil)
        }
    }
    func webView(_ v: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 29/10 : fenêtre surgissante d'un volet courrier — dès qu'elle part vers une vraie page (hors connexion),
        // la page s'ouvre à côté dans Messages et la fenêtre surgissante disparaît : le mail reste intact dessous.
        if let u0 = a.request.url, let h0 = u0.host, PaneDelegate.isAuthHost(h0) { PaneDelegate.authSeen.insert(id) }
        if id.hasSuffix(".pop"), !id.hasPrefix("web"), !id.hasPrefix("tor"), !PaneDelegate.authSeen.contains(id),
           let u = a.request.url, (u.scheme == "https" || u.scheme == "http"), let h = u.host, !PaneDelegate.keepInside(h, paneHost: owner?.panes[String(id.dropLast(4))]?.url?.host),
           !PaneDelegate.sameSite(h, owner?.panes[String(id.dropLast(4))]?.url?.host),
           a.targetFrame?.isMainFrame ?? true {
            openBeside(PaneDelegate.redirectTarget(u) ?? u)
            decisionHandler(.cancel)
            let pid: String = id
            DispatchQueue.main.async { [weak self] in self?.owner?.closePane(pid) }
            return
        }
        // 29/10 : lien du même service qui n'est qu'une redirection vers l'extérieur (Zoho, [tiers] « /url?q= ») → à côté aussi.
        if a.navigationType == .linkActivated, !id.hasSuffix(".pop"), id != "web", id != "tor",
           let u = a.request.url, let uh = u.host, !PaneDelegate.isAuthHost(uh),
           let t = PaneDelegate.redirectTarget(u), let th = t.host, th != v.url?.host, !PaneDelegate.keepInside(th, paneHost: v.url?.host),
           a.targetFrame?.isMainFrame ?? true {
            openBeside(t)
            decisionHandler(.cancel); return
        }
        // 27/10 (Ahadi) : un lien cliqué dans un volet COURRIER ne doit plus naviguer
        // le volet lui-même (la boîte disparaissait sous la page, sans retour visible).
        // Lien externe (autre hôte, cadre principal) depuis un volet non-navigateur :
        // on annule et on demande à l'interface d'ouvrir la page À CÔTÉ, dans Messages
        // (window.NovaOpenUrl, shell.js). Le volet web/tor et les popups naviguent
        // chez eux ; la navigation interne au même hôte (ouvrir un mail) passe.
        if a.navigationType == .linkActivated, !id.hasSuffix(".pop"), id != "web", id != "tor",
           let u = a.request.url, (u.scheme == "https" || u.scheme == "http"),
           let h = u.host, h != v.url?.host, !PaneDelegate.keepInside(h, paneHost: v.url?.host), let tf = a.targetFrame, tf.isMainFrame {
            if let d = try? JSONSerialization.data(withJSONObject: [u.absoluteString]),
               let j = String(data: d, encoding: .utf8) {
                owner?.mainView.evaluateJavaScript("window.NovaOpenUrl&&window.NovaOpenUrl(\(j)[0])", completionHandler: nil)
            }
            decisionHandler(.cancel); return
        }
        decisionHandler(a.shouldPerformDownload ? .download : .allow)
    }
    func webView(_ v: WKWebView, decidePolicyFor r: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(r.canShowMIMEType ? .allow : .download)
    }
    func webView(_ v: WKWebView, navigationAction a: WKNavigationAction, didBecome d: WKDownload) { d.delegate = DownloadHandler.shared }
    func webView(_ v: WKWebView, navigationResponse r: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = DownloadHandler.shared }
    func webView(_ v: WKWebView, didCommit n: WKNavigation!) { push(v) }
    func webView(_ v: WKWebView, didFinish n: WKNavigation!) {
        push(v)
        // Outlook / Teams web : si Microsoft affiche « Choisir un compte » avec un compte déjà « connecté », on reprend CETTE session
        // (un clic sur la tuile du compte existant). Jamais de saisie de mot de passe ni de compte ajouté.
        if (id == "ol" || id == "tm"), v.url?.host == "login.microsoftonline.com" {
            let js = "(function(){var t=document.querySelector('#tilesHolder .tile-container [role=button], #tilesHolder [role=button], .tile-container [role=button]');if(!t)return 'none';var s=(t.innerText||'').toLowerCase();if(!(s.indexOf('signed in')>=0||s.indexOf('connecté')>=0))return 'notsigned';t.click();return 'clicked'})()"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { v.evaluateJavaScript(js, completionHandler: nil) }
        }
    }
    /// NOVA2-VOLETS : échecs réels seuls (Cancelled = navigation remplacée, non journalisé) ; hôte seul, jamais l'URL complète.
    private func logNavFailure(_ v: WKWebView, kind: String, error e: Error) {
        let ns = e as NSError
        if ns.code == NSURLErrorCancelled { return }
        _ = BlackBox.record(["tool": "volet_nav", "actor": "Nova", "why": kind + " volet " + id, "ok": false, "effect": "lecture", "result": "\(v.url?.host ?? "?") \(ns.domain)/\(ns.code)"])
    }
    func webView(_ v: WKWebView, didFail n: WKNavigation!, withError e: Error) { push(v, error: (e as NSError).code == NSURLErrorCancelled ? nil : e.localizedDescription); logNavFailure(v, kind: "échec navigation", error: e) }
    func webView(_ v: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { push(v, error: (e as NSError).code == NSURLErrorCancelled ? nil : e.localizedDescription); logNavFailure(v, kind: "échec provisoire navigation", error: e) }
    func webViewWebContentProcessDidTerminate(_ v: WKWebView) {
        _ = BlackBox.record(["tool": "volet_nav", "actor": "Nova", "why": "processus WebContent terminé volet \(id)", "ok": false, "effect": "lecture", "result": v.url?.host ?? "?"])
        v.reload()
    }
    func webView(_ v: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { push(v) }
    func webView(_ v: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures w: WKWindowFeatures) -> WKWebView? {
        // Un document ouvert depuis Outlook/Gmail/etc. (nouvelle fenêtre, window.open) s'affiche PAR-DESSUS le volet, dans un volet « .pop » fermable ;
        // on renvoie une vraie vue (avec la configuration demandée) pour que la page puisse y naviguer elle-même (about:blank puis redirection).
        // 29/10 : volet courrier → une vraie adresse connue d'avance (hors connexion) s'ouvre À CÔTÉ, sans fenêtre par-dessus.
        let base: String = id.hasSuffix(".pop") ? String(id.dropLast(4)) : id
        if base != "web", base != "tor", let u = a.request.url, (u.scheme == "https" || u.scheme == "http"), let h = u.host, !PaneDelegate.isAuthHost(h) {
            let target: URL = PaneDelegate.redirectTarget(u) ?? u
            let th: String = target.host ?? h
            if !PaneDelegate.keepInside(th, paneHost: v.url?.host) && !PaneDelegate.sameSite(th, v.url?.host) {
                openBeside(target)
                return nil
            }
        }
        return owner?.makePop(from: base, config: c)
    }
    func webViewDidClose(_ v: WKWebView) { if id.hasSuffix(".pop") { owner?.closePane(id) } }
    @available(macOS 12.0, *)
    func webView(_ v: WKWebView, requestMediaCapturePermissionFor o: WKSecurityOrigin, initiatedByFrame f: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.prompt) }
    func webView(_ v: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) { let a = NSAlert(); a.messageText = m; a.runModal(); completionHandler() }
    func webView(_ v: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = m; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Annuler"); completionHandler(a.runModal() == .alertFirstButtonReturn)
    }
}

// S43-S1 : délégué des fenêtres détachées — la fermeture par l'utilisateur devient une fermeture de volet.
final class PaneWindowDelegate: NSObject, NSWindowDelegate {
    let id: String; weak var owner: AppDelegate?
    init(id: String, owner: AppDelegate) { self.id = id; self.owner = owner }
    func windowWillClose(_ n: Notification) { owner?.detachedWindowWillClose(id) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKUIDelegate, WKScriptMessageHandler, WKNavigationDelegate, NSMenuDelegate {
    var core: NovaApp!
    var base = ""
    // NOVA2-ENTRÉE : externalToken supprimé (moteur intégré unique).
    // NOVA2-ENTRÉE : externalEngine() supprimé — plus de sonde HTTP bloquante au démarrage.
    var main: NSWindow!
    var panel: FloatingPanel!
    var dragMouse0 = NSPoint.zero, dragOrigin0 = NSPoint.zero
    var mainView: WKWebView!
    var panelView: WKWebView!
    var status: NSStatusItem!
    var hotRef: EventHotKeyRef?
    var hotRefDictee: EventHotKeyRef?   // ⌥⌘D : dictée partout (Feat_Dictee.swift)
    var hotRefAsk: EventHotKeyRef? = nil
    // NOVA PARTOUT (24/10, NovaEverywhere.swift) : URL nova:// reçues avant la fin du lancement, vues web prêtes
    // (didFinish) et scripts en attente de leur page, panneau compact appelé par l'utilisateur, lignes d'état du menu.
    var pendingURLs: [URL] = []
    var launchDone: Bool = false
    var webReady: Set<ObjectIdentifier> = []
    var webPending: [ObjectIdentifier: [String]] = [:]
    var panelSummonedAt: Date = Date.distantPast
    var statusStateItem: NSMenuItem? = nil
    var statusHaloItem: NSMenuItem? = nil
    var activityInflight: Bool = false
    // V5-E (NovaEverywhere.swift) : présence vivante dans la barre de menus — état relevé toutes les 20 s
    // (GET /api/activity, /api/drafts, /api/dots/waiting), GO attendus comptés sur ces données réelles.
    var statusTimer: Timer? = nil
    var statusLiveInflight: Bool = false
    var statusGoItem: NSMenuItem? = nil
    var statusGoDrafts: Int = 0
    var statusGoDots: Int = 0
    var container: FlippedView!
    /// 30/10 (Ahadi : « où est le Liquid Glass ? ») — verre NATIF de macOS derrière la page transparente : NSVisualEffectView
    /// (flou de fenêtre, toutes versions) et, sur macOS 26+, le vrai Liquid Glass d'Apple (NSGlassEffectView, chargé
    /// dynamiquement pour compiler avec n'importe quel SDK). L'interface pilote l'apparence et la teinte (cmd « win.appearance »).
    var mainFx: NSVisualEffectView?
    var mainGlass: NSView?
    var panes: [String: WKWebView] = [:]
    var paneDelegates: [String: PaneDelegate] = [:]
    // NOVA2-VOLETS : dernier usage de chaque volet + récolteur d'inactivité (voir applicationDidFinishLaunching).
    var paneLastUsed: [String: Date] = [:]
    var paneReaper: Timer?
    // FIXPREP D-R5 : dernier rectangle VISIBLE déclaré par le web + volets dont
    // la hauteur reçue était une bande et qui doivent donc suivre le bas du conteneur.
    var paneRawFrames: [String: NSRect] = [:]
    var paneFillBottom: Set<String> = []
    // SPARK-PLACE journal seul : derniere signature volet_place par volet, dedup du journal uniquement.
    var placeLogLast: [String: String] = [:]
    // S43-S1 : fenêtres détachées (le délégué n'est pas retenu par NSWindow : registre dédié).
    var detachedPanes: [String: NSWindow] = [:]
    var paneWindowDelegates: [String: PaneWindowDelegate] = [:]
    func notePaneUsed(_ id: String) { paneLastUsed[id] = Date() }
    var panelHiddenByUser = false
    // V6-COMPAGNON (NovaCompanion.swift) : compagnon flottant natif au-dessus des apps (companion.html).
    var compPanel: FloatingPanel? = nil
    var compView: WKWebView? = nil
    var compMenuItem: NSMenuItem? = nil
    // DOCK-MINIMIZE : le cadran suit la visibilité de l'hôte (fenêtre principale réduite / app masquée) — masquage mémorisé, restauré au retour.
    var panelHostMasked = false
    var panelShownBeforeMask = false
    // Schéma nova:// (interrupteur « NovaIPC », défaut : désactivé) — enregistré sur la fenêtre principale et l'assistant uniquement.
    var schemeHandler: NovaSchemeHandler?
    var ipcFallback = Set<ObjectIdentifier>()   // vues revenues sur http://127.0.0.1 après un échec de chargement nova://
    // Tor : processus tor géré par Nova (SOCKS 127.0.0.1:9250), utilisé uniquement par le volet « Navigateur Tor ».
    var torProc: Process?; var torPct = 0; var torPipe: Pipe?
    nonisolated(unsafe) static var torPort: UInt16 = 9250   // 9250 = tor lancé par Nova ; 9050 = tor Homebrew déjà actif (réutilisé)
    func findTor() -> String? {
        let c = ["/opt/homebrew/bin/tor", "/usr/local/bin/tor", "/Applications/Tor Browser.app/Contents/MacOS/Tor/tor", NSHomeDirectory() + "/Applications/Tor Browser.app/Contents/MacOS/Tor/tor"]
        return c.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    func portOpen(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0); if fd < 0 { return false }; defer { close(fd) }
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }
    func torPortOpen() -> Bool { portOpen(AppDelegate.torPort) }
    var torLogPath: String { NSHomeDirectory() + "/Library/Application Support/Nova/tor/notice.log" }
    /// Avancement réel lu dans le journal de tor (« Bootstrapped NN% »), sans dépendre du tube de sortie.
    func torLogPct() -> Int {
        guard let d = FileManager.default.contents(atPath: torLogPath), let t = String(data: d.suffix(6000), encoding: .utf8) else { return 0 }
        var best = 0
        var rest = t[...]
        while let r = rest.range(of: #"Bootstrapped (\d+)%"#, options: .regularExpression) { best = Int(rest[r].filter { $0.isNumber }) ?? best; rest = rest[r.upperBound...] }
        return best
    }
    func torReport() {
        if torProc?.isRunning == true { torPct = max(torPct, torLogPct()) }
        let st: [String: Any] = ["installed": findTor() != nil, "running": torPortOpen(), "pct": torPct, "ready": torPct >= 100 || (torProc == nil && torPortOpen())]
        if let data = try? JSONSerialization.data(withJSONObject: st), let j = String(data: data, encoding: .utf8) { mainView.evaluateJavaScript("window.NovaNative&&NovaNative.onTor&&NovaNative.onTor(\(j))", completionHandler: nil) }
    }
    func torStart() {
        if torProc?.isRunning != true {   // un tor déjà actif (service Homebrew sur 9050, ou le nôtre sur 9250) : on le réutilise
            if portOpen(9050) { AppDelegate.torPort = 9050; torPct = 100; torReport(); return }
            if portOpen(9250) { AppDelegate.torPort = 9250; torPct = 100; torReport(); return }
        } else { torReport(); return }
        guard let bin = findTor() else { torReport(); return }
        let dir = NSHomeDirectory() + "/Library/Application Support/Nova/tor"; try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = Process(); p.executableURL = URL(fileURLWithPath: bin)
        var args = ["--SocksPort", "127.0.0.1:\(AppDelegate.torPort)", "--DataDirectory", dir, "--ClientOnly", "1", "--Log", "notice file \(dir)/notice.log"]
        let base = (bin as NSString).deletingLastPathComponent
        for (flag, f) in [("--GeoIPFile", "../Data/geoip"), ("--GeoIPv6File", "../Data/geoip6")] { let path = base + "/" + f; if FileManager.default.fileExists(atPath: path) { args += [flag, path] } }
        p.arguments = args; p.currentDirectoryURL = URL(fileURLWithPath: base)
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe; torPipe = pipe; torPct = 0
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let t = String(decoding: h.availableData, as: UTF8.self)
            if let r = t.range(of: #"Bootstrapped (\d+)%"#, options: .regularExpression), let n = Int(t[r].filter { $0.isNumber }) { DispatchQueue.main.async { self?.torPct = n; self?.torReport() } }
        }
        do { try p.run(); torProc = p } catch { torReport() }
    }
    func applicationWillTerminate(_ n: Notification) { torProc?.terminate(); JSONFile.flush() }   // pose les écritures d'état encore en attente (~150 ms)

    /// NOVA2-VEILLE : Nova ne bloque plus la veille du Mac. Seule la terminaison brutale est différée, le temps de flusher l'état.
    /// (Nova 1 imposait idleSystemSleepDisabled + automaticTerminationDisabled, plus 5 scripts caffeinate concurrents : le Mac ne dormait jamais.)
    var keepAwake: NSObjectProtocol?
    /// NOVA PARTOUT : le gestionnaire d'URL nova:// est posé AVANT la fin du lancement — l'URL qui lance l'app arrive ici.
    func applicationWillFinishLaunching(_ n: Notification) { installURLHandler() }
    func applicationDidFinishLaunching(_ n: Notification) {
        SentryBootstrap.start()   // SENTRY : tout premier, avant le moteur — no-op silencieux si aucun DSN n'est configuré (voir SentryBootstrap.swift).
        Amplitude.start()   // AMPLITUDE (CRÉDITS 23/10) : émetteur analytics — dormant sans clé, disjoncteur intégré, jamais bloquant (voir Amplitude.swift).
        keepAwake = ProcessInfo.processInfo.beginActivity(options: [.suddenTerminationDisabled], reason: "Nova 2 : flush d'état en cours")
        // Sélecteur d'onglets Ctrl+Tab / Option+Tab (⌘Tab est réservé à macOS) : fonctionne aussi quand un volet web (Outlook, Teams…) a le focus.
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self = self, let w = self.main, w.isKeyWindow else { return e }
            let f = e.modifierFlags
            if e.type == .keyDown, e.keyCode == 48, (f.contains(.control) || f.contains(.option)), !f.contains(.command) {
                self.mainView.evaluateJavaScript("window.NovaSwitch&&NovaSwitch.step(\(f.contains(.shift) ? -1 : 1))", completionHandler: nil)
                return nil
            }
            if e.type == .flagsChanged, !f.contains(.control), !f.contains(.option) {
                self.mainView.evaluateJavaScript("window.NovaSwitch&&NovaSwitch.commit()", completionHandler: nil)
            }
            return e
        }
        let res = Bundle.main.resourcePath.map { $0 + "/web" } ?? ""
        let web = ProcessInfo.processInfo.environment["NOVA_WEB"] ?? (FileManager.default.fileExists(atPath: res + "/index.html") ? res : "")
        // NOVA2-ENTRÉE : un seul point d'entrée — le moteur intégré, toujours. La sonde externe bloquante de Nova 1
        // (fichier engine-mode + requête synchrone de 2 s, Mission 4) est supprimée : démarrage déterministe.
        core = NovaApp(keys: KeychainStore(), webDir: web)
        do {
            // Port FIXE (repli : aléatoire s'il est pris) : le navigateur intégré range thèmes, disposition, historique… par origine (adresse + port).
            // Avec un port aléatoire, chaque redémarrage donnait une origine neuve et tout « sautait ».
            let port: Int
            if let p = try? core.start(port: 47615) { port = p } else { port = try core.start(port: 0) }
            base = "http://127.0.0.1:\(port)"
            // Banc d'essai local (tests/run-tests.sh) : port + jeton de session, lisibles par l'utilisateur seul (0600), jamais réseau.
            let tdir = NSHomeDirectory() + "/Library/Application Support/Nova"; try? FileManager.default.createDirectory(atPath: tdir, withIntermediateDirectories: true)
            let tfile = tdir + "/.session"; try? "\(port) \(core.server.token)".write(toFile: tfile, atomically: true, encoding: .utf8); _ = chmod(tfile, 0o600)
            schemeHandler = NovaSchemeHandler(server: core.server)
        } catch {
            let a = NSAlert(); a.messageText = "Nova ne peut pas démarrer"; a.informativeText = "\(error)"; a.runModal(); NSApp.terminate(nil); return
        }
        buildMenu(); buildMain(); buildPanel(); buildStatus(); registerHotkey(); panel.orderOut(nil); buildCompanion()
        NovaNotify.install { [weak self] module, id in guard let self = self else { return }; NSApp.activate(ignoringOtherApps: true); self.main?.makeKeyAndOrderFront(nil); self.mainView?.evaluateJavaScript(NovaNotify.openScript(module: module, id: id), completionHandler: nil) }   // V5-H : clic sur une notification (geste explicite d'Ahadi) → Nova s'ouvre sur l'élément
        installPaneTouchMonitor()   // V5-E : un clic d'Ahadi dans un volet web met Nova en pause sur ce volet (NovaEverywhere.swift)
        // NOVA2-VOLETS : récolteur d'inactivité — tout volet SILENCIEUX (lecture d'arrière-plan Outlook/Teams)
        // inutilisé depuis 10 minutes est détruit : son processus WebContent est libéré au lieu de rendre 24/7.
        paneReaper = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let now = Date()
            let stale = self.panes.compactMap { (pid, v) -> String? in
                guard let q = v as? QuietWebView, q.quiet, let last = self.paneLastUsed[pid], now.timeIntervalSince(last) > 600 else { return nil }
                return pid
            }
            stale.forEach { self.closePane($0) }
        }
        // MISSION 7 : Service macOS « Demander à Nova » (déclaré dans Info.plist › NSServices, message askNova:userData:error:)
        NSApp.servicesProvider = NovaServiceProvider.shared; NovaServiceProvider.shared.owner = self; NSUpdateDynamicServices()
        // NOVA PARTOUT : les URL nova:// arrivées pendant le lancement sont traitées maintenant que fenêtres et panneau existent.
        launchDone = true
        let early: [URL] = pendingURLs; pendingURLs = []
        for u in early { handleNovaURL(u) }
        // pas d'activation forcée : lancé par un clic, macOS l'active déjà ; relancé en arrière-plan (open -g), Nova ne vole plus l'écran
    }
    /// Un seul compagnon à la fois : dans la fenêtre Nova c'est l'avatar de l'app ; quand tu travailles dans une autre app, le panneau flottant prend le relais.
    func applicationDidBecomeActive(_ n: Notification) {
        // NOVA PARTOUT : un panneau compact appelé il y a moins de 2 s (raccourci, nova://ask, Service) reste ouvert
        // même si macOS active Nova au passage (ouverture d'URL sans -g).
        if Date().timeIntervalSince(panelSummonedAt) < 2 { return }
        if let w = main, w.isVisible, !w.isMiniaturized { panel?.orderOut(nil) }
        // 29/10 (Claude, audit UI) : le compagnon flottant couvrait le bouton Envoyer du composeur et les cartes de
        // l'Accueil. Dans Nova, l'avatar de l'app suffit : le compagnon flottant s'efface, et revient dès qu'on change d'app.
        if let w = main, w.isVisible, !w.isMiniaturized, let cp = compPanel, cp.isVisible { cp.orderOut(nil) }
    }
    func applicationDidResignActive(_ n: Notification) {
        if let cp = compPanel, companionEnabled(), !cp.isVisible { cp.orderFrontRegardless() }
    }   // ne vole jamais le premier plan quand Ahadi change d'app
    func windowWillClose(_ n: Notification) { if !panelHiddenByUser { panel?.orderFrontRegardless() } }
    func windowDidMiniaturize(_ n: Notification) { maskPanelForHost() }   // DOCK-MINIMIZE : réduite au Dock → le cadran se masque aussi (restauré à la dé-réduction)
    func windowDidDeminiaturize(_ n: Notification) { unmaskPanelForHost() }   // DOCK-MINIMIZE : fenêtre restaurée → le cadran revient dans son état d'avant réduction
    func applicationDidHide(_ n: Notification) { maskPanelForHost() }   // DOCK-MINIMIZE : Cmd+H → le cadran se masque avec l'app
    func applicationDidUnhide(_ n: Notification) { unmaskPanelForHost() }   // DOCK-MINIMIZE : app réaffichée → le cadran revient selon son état
    /// DOCK-MINIMIZE : masque le cadran quand l'hôte disparaît (réduction de la fenêtre principale / masquage de l'app), en mémorisant s'il était visible. L'état propre du cadran (fermé par son ✕ = panelHiddenByUser) n'est pas touché.
    func maskPanelForHost() {
        guard !panelHostMasked else { return }
        panelHostMasked = true
        panelShownBeforeMask = panel?.isVisible ?? false
        if panelShownBeforeMask { panel?.orderOut(nil) }
    }
    /// DOCK-MINIMIZE : au retour de l'hôte, le cadran ne revient que s'il était visible au masquage, si l'utilisateur ne l'a pas fermé entre-temps, et si ni la réduction ni le masquage d'app ne sont encore en cours.
    func unmaskPanelForHost() {
        guard panelHostMasked else { return }
        panelHostMasked = false
        let wasShown = panelShownBeforeMask; panelShownBeforeMask = false
        if wasShown, !panelHiddenByUser, let w = main, !w.isMiniaturized, !NSApp.isHidden { panel?.orderFrontRegardless() }
    }
    func windowDidResize(_ n: Notification) {
        // FIXPREP D-R5 : la WebView principale suit la fenêtre par autoresizing,
        // pas les volets posés en coordonnées explicites. Sans réapplication,
        // un volet garde son rectangle initial — notamment la bande de ~110 px.
        for (id, p) in panes {
            guard let raw = paneRawFrames[id], p.alphaValue > 0, !p.isHidden else { continue }
            let resizeSig = "id=\(id) src=resize reqX=\(Int(raw.origin.x)) reqY=\(Int(raw.origin.y)) reqW=\(Int(raw.size.width)) reqH=\(Int(raw.size.height))"
            if placeLogLast["caller:" + id] != resizeSig { placeLogLast["caller:" + id] = resizeSig; _ = BlackBox.record(["tool": "volet_place", "actor": "Nova", "why": "redim volet \(id)", "ok": true, "effect": "lecture", "result": resizeSig]) }
            placePane(p, raw)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ a: NSApplication, hasVisibleWindows f: Bool) -> Bool { showMain(); return true }

    func makeWebView(transparent: Bool) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // 24/10 : pas de bulle « Écrire avec Siri » (Writing Tools) qui flottait sur l'interface de Nova
        if #available(macOS 15.0, *) { cfg.writingToolsBehavior = .none }
        cfg.userContentController.add(self, name: "nova")
        cfg.mediaTypesRequiringUserActionForPlayback = []
        if let h = schemeHandler { cfg.setURLSchemeHandler(h, forURLScheme: "nova") }
        // MISSION 6 : provenance « interface » pour /api/drafts/send — secret en mémoire, donné seulement aux pages de Nova (jamais aux Dots ni aux volets web)
        cfg.userContentController.addUserScript(WKUserScript(source: "if(location.origin===\(String(reflecting: base))||location.protocol==='nova:'){Object.defineProperty(window,'__novaProv',{value:\(String(reflecting: SendQueue.uiSecret))})}", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let v: WKWebView = NovaWebView(frame: .zero, configuration: cfg)
        v.uiDelegate = self; v.navigationDelegate = self
        if transparent { v.setValue(false, forKey: "drawsBackground") }
        if #available(macOS 13.3, *) { v.isInspectable = true }
        return v
    }
    /// Par défaut : http://127.0.0.1:<port>. Avec l'interrupteur NovaIPC : nova://app/… (repli automatique sur HTTP si le chargement échoue).
    func load(_ v: WKWebView, _ path: String) {
        if NovaSchemeIO.enabled, schemeHandler != nil, !ipcFallback.contains(ObjectIdentifier(v)),
           let u = URL(string: "nova://app" + (path == "/" ? "/index.html" : path)) {
            v.load(URLRequest(url: u)); return
        }
        loadHTTP(v, path)
    }
    func loadHTTP(_ v: WKWebView, _ path: String) {
        // MISSION 4 : jeton du moteur externe si présent, sinon celui du core local (inchangé)
        if let u = URL(string: "\(base)\(path)?t=\(core.server.token)") { v.load(URLRequest(url: u)) }   // NOVA2-ENTRÉE
    }
    /// NOVA PARTOUT : page de la fenêtre principale ou du panneau chargée → les scripts en attente (nova://, Services) partent.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let isComp: Bool = compView != nil && webView === compView
        guard webView === mainView || webView === panelView || isComp else { return }
        let key = ObjectIdentifier(webView)
        webReady.insert(key)
        let queued: [String] = webPending[key] ?? []
        webPending[key] = nil
        for js in queued { webView.evaluateJavaScript(js, completionHandler: nil) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let failing = ((error as NSError).userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? ""
        guard failing.hasPrefix("nova:"), !ipcFallback.contains(ObjectIdentifier(webView)) else { return }
        ipcFallback.insert(ObjectIdentifier(webView))
        let p = URL(string: failing)?.path ?? "/"
        loadHTTP(webView, (p.isEmpty || p == "/index.html") ? "/" : p)
    }

    /// NOVA2-CRASH : le processus de rendu WebKit peut mourir sous charge WebGL ; Nova 1 laissait un écran blanc.
    /// On recharge la vue touchée ; le shell restaure son état depuis /api/state.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webReady.remove(ObjectIdentifier(webView))   // NOVA PARTOUT : les scripts attendront le prochain didFinish
        if webView === mainView { load(webView, "/") }
        else if webView === panelView { load(webView, "/panel.html") }
        else if let cv = compView, webView === cv { load(webView, "/companion.html") }   // V6-COMPAGNON
    }

    func buildMain() {
        // NDL (24/10) : contenu plein cadre sous une barre de titre transparente — la barre latérale
        // de verre de l'interface monte jusqu'en haut et accueille les feux de la fenêtre (comme macOS 26/27).
        main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        main.titlebarAppearsTransparent = true; main.titleVisibility = .hidden
        main.minSize = NSSize(width: 900, height: 600)
        main.title = "Nova · Ahadi Jean Cyrille Dahani"; main.center(); main.isReleasedWhenClosed = false; main.delegate = self
        main.setFrameAutosaveName("NovaMain")
        mainView = makeWebView(transparent: true)   // page transparente : le style « Liquid Glass Transparent » laisse voir le verre natif ; les autres styles ont un fond opaque
        main.isOpaque = false; main.backgroundColor = .clear
        mainView.configuration.userContentController.addUserScript(WKUserScript(source: "window.__NOVA_NATIVE_WEB = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        container = FlippedView(frame: main.contentView!.bounds)
        let fx = NSVisualEffectView(frame: container.bounds)
        fx.material = .hudWindow; fx.appearance = NSAppearance(named: .vibrantDark); fx.blendingMode = .behindWindow; fx.state = .active; fx.autoresizingMask = [.width, .height]
        container.addSubview(fx)
        mainFx = fx
        // 30/10 : vrai Liquid Glass (macOS 26+) par-dessus le flou de fenêtre, sous la page — absent = repli silencieux sur le flou.
        if UserDefaults.standard.bool(forKey: "NovaGlassEffectView"), let glassType = NSClassFromString("NSGlassEffectView") as? NSObject.Type, let g = glassType.init() as? NSView {   // 30/10 : essai — couche Liquid Glass pleine fenêtre trop opaque à l'écran ; flou natif seul par défaut
            g.frame = container.bounds
            g.autoresizingMask = [.width, .height]
            container.addSubview(g)
            mainGlass = g
        }
        mainView.frame = container.bounds; mainView.autoresizingMask = [.width, .height]; container.addSubview(mainView)
        main.contentView = container
        load(mainView, "/")
        if NSApp.isActive { main.makeKeyAndOrderFront(nil) } else { main.orderBack(nil) }   // relancé en arrière-plan : reste derrière
    }
    func buildPanel() {
        let f = NSRect(x: 0, y: 0, width: 360, height: 560)   // plus haut : journal de conversation dans le panneau
        panel = FloatingPanel(contentRect: f, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.isMovableByWindowBackground = false   // un seul mécanisme de déplacement (sinon deux déplacements se battent); panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.setFrameAutosaveName("NovaPanel")
        if let s = NSScreen.main { panel.setFrameOrigin(NSPoint(x: s.visibleFrame.maxX - 330, y: s.visibleFrame.minY + 30)) }
        panelView = makeWebView(transparent: true)
        // NOVA PARTOUT : verre natif arrondi derrière la page (comme Spotlight) — la page reste transparente hors de sa surface.
        let host = NSView(frame: f)
        let glass = NSVisualEffectView(frame: host.bounds)
        glass.material = .hudWindow; glass.blendingMode = .behindWindow; glass.state = .active
        glass.autoresizingMask = [.width, .height]
        glass.maskImage = AppDelegate.roundedMask(radius: 18)
        host.addSubview(glass)
        panelView.frame = host.bounds; panelView.autoresizingMask = [.width, .height]
        host.addSubview(panelView)
        panel.contentView = host
        panel.hasShadow = true
        load(panelView, "/panel.html")
        // (pas d'affichage au démarrage : évite le flash par-dessus les autres apps)
    }
    func buildStatus() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Icône de barre de menus : image modèle dessinée (anneau + point,
        // remplace le glyphe de point cerclé — V4-C14), teintée par le système.
        let statusIcon = NSImage(size: NSSize(width: 18, height: 18))
        statusIcon.lockFocus()
        NSColor.black.set()
        let ring = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 13, height: 13)); ring.lineWidth = 1.6; ring.stroke()
        NSBezierPath(ovalIn: NSRect(x: 6.75, y: 6.75, width: 4.5, height: 4.5)).fill()
        statusIcon.unlockFocus()
        statusIcon.isTemplate = true
        status.button?.image = statusIcon
        status.button?.toolTip = "Nova"
        // NOVA PARTOUT : état réel + halo d'activité en une ligne (relus à chaque ouverture du menu, voir menuWillOpen).
        let m = NSMenu()
        let stateItem = NSMenuItem(title: "Nova · lecture de l'état…", action: nil, keyEquivalent: ""); stateItem.isEnabled = false
        let haloItem = NSMenuItem(title: "Activité : lecture…", action: nil, keyEquivalent: ""); haloItem.isEnabled = false
        // V5-E : GO attendus (brouillons à approuver + Éclats qui attendent une décision) — cliquable seulement s'il y en a.
        let goItem = NSMenuItem(title: "GO attendus : lecture…", action: nil, keyEquivalent: ""); goItem.isEnabled = false
        m.addItem(stateItem); m.addItem(haloItem); m.addItem(goItem)
        statusStateItem = stateItem; statusHaloItem = haloItem; statusGoItem = goItem
        m.addItem(NSMenuItem.separator())
        m.addItem(withTitle: "Demander à Nova…  ⌃⌥Espace", action: #selector(ask), keyEquivalent: "").target = self
        m.addItem(withTitle: "Parler  ⌥Espace", action: #selector(talk), keyEquivalent: "").target = self
        m.addItem(withTitle: "Dictée partout  ⌃⌥D", action: #selector(toggleDictee), keyEquivalent: "").target = self
        m.addItem(NSMenuItem.separator())
        m.addItem(withTitle: "Ouvrir Nova", action: #selector(showMain), keyEquivalent: "").target = self
        m.addItem(withTitle: "Afficher / masquer l'assistant", action: #selector(togglePanel), keyEquivalent: "").target = self
        // V6-COMPAGNON : compagnon flottant (réglage companion_float, défaut : affiché) — coche = état réel du panneau.
        let compItem: NSMenuItem = NSMenuItem(title: "Afficher le compagnon flottant", action: #selector(toggleCompanion(_:)), keyEquivalent: "")
        compItem.target = self
        m.addItem(compItem)
        compMenuItem = compItem
        m.addItem(NSMenuItem.separator())
        m.addItem(withTitle: "Quitter Nova", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.delegate = self
        status.menu = m
        startStatusLive()   // V5-E : icône vivante (Au repos / Réfléchit / N GO attendus), relevée sur données réelles
    }
    /// NOVA PARTOUT : à chaque ouverture du menu de la barre, l'état et l'activité sont relus (aucun sondage permanent).
    func menuWillOpen(_ menu: NSMenu) { if menu === status?.menu { refreshStatusActivity(); applyCompanionSetting() } }
    func buildMenu() {
        let bar = NSMenu(); let app = NSMenuItem(); bar.addItem(app)
        let am = NSMenu(); app.submenu = am
        am.addItem(withTitle: "À propos de Nova", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        am.addItem(NSMenuItem.separator())
        let adv = NSMenuItem(title: "Réglages avancés", action: nil, keyEquivalent: "")
        let advm = NSMenu(title: "Réglages avancés"); adv.submenu = advm
        for (key, title) in AppDelegate.advancedFlags {
            let it = NSMenuItem(title: title, action: #selector(toggleFlag(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = key; it.state = AppDelegate.flag(key) ? .on : .off
            advm.addItem(it)
        }
        am.addItem(adv)
        am.addItem(NSMenuItem.separator())
        am.addItem(withTitle: "Masquer Nova", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        am.addItem(withTitle: "Quitter Nova", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let ed = NSMenuItem(); bar.addItem(ed); let em = NSMenu(title: "Édition"); ed.submenu = em
        em.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        em.addItem(withTitle: "Rétablir", action: Selector(("redo:")), keyEquivalent: "Z")
        em.addItem(NSMenuItem.separator())
        em.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        em.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        em.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        em.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let wi = NSMenuItem(); bar.addItem(wi); let wm = NSMenu(title: "Fenêtre"); wi.submenu = wm
        wm.addItem(withTitle: "Assistant flottant", action: #selector(togglePanel), keyEquivalent: "").target = self
        wm.addItem(withTitle: "Fenêtre Nova", action: #selector(showMain), keyEquivalent: "0").target = self
        NSApp.mainMenu = bar; NSApp.windowsMenu = wm
    }

    /// Interrupteurs de secours (UserDefaults). Tous désactivés par défaut sauf la recherche vectorielle (coupable ici).
    static let advancedFlags: [(String, String)] = [
        ("NovaIPC", "Bus mémoire nova:// (expérimental)"),
        ("NovaIsolation", "Isolation COOP/COEP (expérimental)"),
        ("NovaSQLite", "Base SQLite WAL (expérimental)"),
        ("NovaVectors", "Recherche vectorielle des connaissances"),
    ]
    static func flag(_ key: String) -> Bool {
        if let v = UserDefaults.standard.object(forKey: key) as? Bool { return v }
        return key == "NovaVectors"
    }
    @objc func toggleFlag(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let now = !AppDelegate.flag(key)
        UserDefaults.standard.set(now, forKey: key)
        sender.state = now ? .on : .off
        let a = NSAlert()
        a.messageText = sender.title + (now ? " : activé" : " : désactivé")
        a.informativeText = "Le changement s'applique au prochain lancement de Nova. Relancer maintenant ?"
        a.addButton(withTitle: "Relancer"); a.addButton(withTitle: "Plus tard")
        if a.runModal() == .alertFirstButtonReturn { relaunch() }
    }
    /// Relance unique et visible (ouvre de nouveau l'app 1,5 s après sa fermeture, le temps de libérer le port 47615). Hors bundle .app : on quitte seulement.
    func relaunch() {
        let path = Bundle.main.bundlePath
        if path.hasSuffix(".app") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1.5; /usr/bin/open -g \"$0\"", path]   // -g : la relance reste en arrière-plan, Nova ne vole jamais le premier plan
            try? p.run()
        }
        NSApp.terminate(nil)
    }

    @objc func showMain() { main.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func togglePanel() { if panel.isVisible { panelHiddenByUser = true; panel.orderOut(nil) } else { panelHiddenByUser = false; panel.orderFrontRegardless() } }
    @objc func ask() {   // champ texte du panneau flottant, sans toucher à la fenêtre principale ni à l'app devant
        panelSummonedAt = Date()   // NOVA PARTOUT : appelé par l'utilisateur → pas de masquage automatique à l'activation
        if !panel.isVisible { panelHiddenByUser = false; panel.orderFrontRegardless() }
        panel.makeKey()   // panneau non activant : il prend le clavier SANS activer Nova ni passer devant l'app courante
        panel.makeFirstResponder(panelView)
        panelView.evaluateJavaScript("window.Nova && window.Nova.focusAsk && window.Nova.focusAsk()", completionHandler: nil)
    }
    @objc func talk() {
        panelSummonedAt = Date()   // V5-E : ⌥Espace = geste d'Ahadi → le panneau n'est pas remasqué par applicationDidBecomeActive
        panelHiddenByUser = false
        if !panel.isVisible { panel.orderFrontRegardless() }
        panel.makeKey()
        panelView.evaluateJavaScript("window.Nova && window.Nova.toggleVoice && window.Nova.toggleVoice()", completionHandler: nil)
    }

    func registerHotkey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, ev, ud in
            guard let ud = ud else { return noErr }
            let d = Unmanaged<AppDelegate>.fromOpaque(ud).takeUnretainedValue()
            // Quel raccourci ? id 1 = ⌥Espace (parler), id 2 = ⌥⌘D (dictée partout)
            var hk = EventHotKeyID()
            if let ev = ev {
                _ = GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            }
            if hk.id == 2 {
                DispatchQueue.main.async { Dictee.shared.toggle() }
                return noErr
            }
            if hk.id == 3 {
                DispatchQueue.main.async { d.toggleAsk() }   // NOVA PARTOUT : ⌃⌥Espace ouvre / ferme le panneau compact
                return noErr
            }
            DispatchQueue.main.async { d.talk() }
            return noErr
        }, 1, &spec, me, nil)
        // V5-E : ⌥Espace est DÉJÀ ce raccourci (id 1, « Parler ») et ouvre le même panneau compact (panel.html), en voix.
        // Un second enregistrement de ⌥Espace pour l'écrit échouerait (eventHotKeyExistsErr) ou volerait « Parler » :
        // l'écrit reste sur ⌃⌥Espace (id 3). Voir conseil_24-10/V5_E_PASSATION.md.
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: OSType(0x4E4F5641), id: 1), GetApplicationEventTarget(), 0, &hotRef)
        // ⌃⌥Espace : demander à Nova par écrit, depuis n'importe quelle app du Mac (panneau flottant, sans activer la fenêtre principale)
        let askMods: UInt32 = UInt32(controlKey) | UInt32(optionKey)
        RegisterEventHotKey(UInt32(kVK_Space), askMods, EventHotKeyID(signature: OSType(0x4E4F5641), id: 3), GetApplicationEventTarget(), 0, &hotRefAsk)
        // Dictée partout : ⌥⌘D (aucune invite système ici ; droits vérifiés au premier appui seulement)
        let dicteeMods: UInt32 = UInt32(controlKey) | UInt32(optionKey)   // ⌃⌥D : ⌥⌘D est pris par macOS (Dock)
        RegisterEventHotKey(UInt32(kVK_ANSI_D), dicteeMods, EventHotKeyID(signature: OSType(0x4E4F5641), id: 2), GetApplicationEventTarget(), 0, &hotRefDictee)
    }

    // Micro : accordé uniquement à notre propre serveur local.
    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host == "127.0.0.1" || origin.`protocol` == "nova" ? .grant : .deny)
    }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let d = m.body as? [String: Any], let cmd = d["cmd"] as? String else { return }
        if cmd == "openMain" { showMain(); return }
        if cmd == "companionApply" { applyCompanionSetting(); return }   // 25/10 : interrupteur « Compagnon flottant » des Réglages
        if let cv = compView, m.webView === cv { handleCompanionMessage(cmd); return }   // V6-COMPAGNON (NovaCompanion.swift)
        // NOVA PARTOUT : Échap / ✕ du panneau compact, et « Continuer dans Nova » (même conversation, fenêtre principale).
        if cmd == "panelHide", m.webView === panelView { hideAskPanel(); return }
        if cmd == "panelContinue", m.webView === panelView { continueInMain(cid: (d["cid"] as? String) ?? ""); return }
        // Glisser l'assistant flottant : la fenêtre suit la position réelle de la souris (calcul natif, pas de maths côté web)
        if cmd == "panelDragStart", m.webView === panelView { dragMouse0 = NSEvent.mouseLocation; dragOrigin0 = panel.frame.origin; return }
        if cmd == "panelDrag", m.webView === panelView { let p = NSEvent.mouseLocation; panel.setFrameOrigin(NSPoint(x: dragOrigin0.x + p.x - dragMouse0.x, y: dragOrigin0.y + p.y - dragMouse0.y)); return }
        // NDL (24/10) : barre de titre transparente → la zone haute de l'interface déplace la fenêtre (même calcul natif que le panneau)
        if cmd == "winDragStart", m.webView === mainView { dragMouse0 = NSEvent.mouseLocation; dragOrigin0 = main.frame.origin; return }
        if cmd == "winDrag", m.webView === mainView, !main.styleMask.contains(.fullScreen) { let p = NSEvent.mouseLocation; main.setFrameOrigin(NSPoint(x: dragOrigin0.x + p.x - dragMouse0.x, y: dragOrigin0.y + p.y - dragMouse0.y)); return }
        if cmd == "winZoom", m.webView === mainView { main.zoom(nil); return }
        // 30/10 : apparence du verre natif suivant le thème de l'interface (jour/nuit, teinte de l'identité).
        if cmd == "win.appearance", m.webView === mainView {
            let dark: Bool = ((d["mode"] as? String) ?? "dark") != "light"
            mainFx?.appearance = NSAppearance(named: dark ? .vibrantDark : .vibrantLight)
            mainFx?.material = .hudWindow   // 30/10 : même matière translucide jour et nuit (« underWindowBackground » était presque opaque)
            if let g = mainGlass {
                g.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                if let hex = d["tint"] as? String, let col = NSColor.novaHex(hex, alpha: CGFloat((d["alpha"] as? Double) ?? 0.18)),
                   g.responds(to: NSSelectorFromString("setTintColor:")) { g.setValue(col, forKey: "tintColor") }
                let on: Bool = (d["glass"] as? Bool) ?? true
                g.isHidden = !on
            }
            return
        }
        guard m.webView === mainView else { return }   // seule la fenêtre principale pilote les volets
        func rect() -> NSRect { NSRect(x: (d["x"] as? Double) ?? 0, y: (d["y"] as? Double) ?? 0, width: (d["w"] as? Double) ?? 0, height: (d["h"] as? Double) ?? 0) }
        let id = (d["id"] as? String) ?? ""
        switch cmd {
        case "web.show":
            let bgShow: Bool = (d["bg"] as? Bool) ?? false
            // Garde de tenue des volets : un show d'arrière-plan ne parque jamais un volet affiché, la lecture lit le même DOM.
            let dejaAffiche: Bool
            if let p = panes[id] {
                dejaAffiche = (p as? QuietWebView)?.quiet == false && p.alphaValue > 0 && !p.isHidden
            } else {
                dejaAffiche = false
            }
            if detachedPanes[id] != nil {
                // S43-S1 : volet détaché — le show ne replace jamais dans la fenêtre principale.
                paneLastUsed[id] = Date()
            } else if bgShow && dejaAffiche {
                paneLastUsed[id] = Date()   // NOVA2-VOLETS
                let showR = rect()
                let showSig = "id=\(id) src=show reqX=\(Int(showR.origin.x)) reqY=\(Int(showR.origin.y)) reqW=\(Int(showR.size.width)) reqH=\(Int(showR.size.height))"
                if placeLogLast["caller:" + id] != showSig { placeLogLast["caller:" + id] = showSig; _ = BlackBox.record(["tool": "volet_place", "actor": "Nova", "why": "web.show volet \(id)", "ok": true, "effect": "lecture", "result": showSig]) }
                let gardeSig = showSig + " action=show-bg-sans-placement affiche=1"
                if placeLogLast["garde:" + id] != gardeSig { placeLogLast["garde:" + id] = gardeSig; _ = BlackBox.record(["tool": "volet_place", "actor": "Nova", "why": "web.show volet \(id)", "ok": true, "effect": "lecture", "result": gardeSig]) }
            } else {
                let pane = panes[id] ?? makePane(id)
                paneLastUsed[id] = Date()   // NOVA2-VOLETS
                let showR = rect()
                let showSig = "id=\(id) src=show reqX=\(Int(showR.origin.x)) reqY=\(Int(showR.origin.y)) reqW=\(Int(showR.size.width)) reqH=\(Int(showR.size.height))"
                if placeLogLast["caller:" + id] != showSig { placeLogLast["caller:" + id] = showSig; _ = BlackBox.record(["tool": "volet_place", "actor": "Nova", "why": "web.show volet \(id)", "ok": true, "effect": "lecture", "result": showSig]) }
                placePane(pane, rect())
                if let q = panes[id + ".pop"] { placePane(q, rect()); paneDelegates[id + ".pop"]?.push(q) }
                if pane.url == nil, let u = (d["url"] as? String).flatMap({ URL(string: $0) }) { pane.load(URLRequest(url: u)) }
                if !bgShow { main.makeFirstResponder(pane) }
            }
        case "web.popout":
            guard let p = panes[id], detachedPanes[id] == nil else { break }
            paneRawFrames[id] = nil
            p.removeFromSuperview()
            let cur = p.frame
            let popSize: NSRect
            if cur.size.width > 100 && cur.size.height > 100 { popSize = NSRect(x: 0, y: 0, width: cur.size.width, height: cur.size.height) }
            else { popSize = NSRect(x: 0, y: 0, width: 1100, height: 760) }
            let win = NSWindow(contentRect: popSize, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            win.center()
            win.isReleasedWhenClosed = false
            let popTitle = p.title ?? ""
            win.title = popTitle.isEmpty ? id : popTitle
            win.contentView = p
            p.frame = NSRect(origin: .zero, size: popSize.size)
            p.autoresizingMask = [.width, .height]
            (p as? QuietWebView)?.quiet = false
            p.alphaValue = 1; p.isHidden = false
            let popDlg = PaneWindowDelegate(id: id, owner: self)
            paneWindowDelegates[id] = popDlg
            win.delegate = popDlg
            detachedPanes[id] = win
            win.makeKeyAndOrderFront(nil)
            paneLastUsed[id] = Date()
        case "web.dock":
            guard let win = detachedPanes[id], let p = panes[id] else { break }
            win.delegate = nil
            detachedPanes[id] = nil; paneWindowDelegates[id] = nil
            p.removeFromSuperview()
            container.addSubview(p)
            win.close()
            placePane(p, rect())
            paneLastUsed[id] = Date()
        case "web.move": if detachedPanes[id] == nil { if let p = panes[id] { placePane(p, rect()) }; if let q = panes[id + ".pop"] { placePane(q, rect()) } }
            let moveR = rect()
            let moveSig = "id=\(id) src=move reqX=\(Int(moveR.origin.x)) reqY=\(Int(moveR.origin.y)) reqW=\(Int(moveR.size.width)) reqH=\(Int(moveR.size.height))"
            if placeLogLast["caller:" + id] != moveSig { placeLogLast["caller:" + id] = moveSig; _ = BlackBox.record(["tool": "volet_place", "actor": "Nova", "why": "web.move volet \(id)", "ok": true, "effect": "lecture", "result": moveSig]) }
        case "win.fs":   // plein écran réel du Mac (barre de menus et Dock masqués) ; "on" absent = bascule
            let isFS = main.styleMask.contains(.fullScreen)
            let want = (d["on"] as? Bool) ?? !isFS
            main.collectionBehavior.insert(.fullScreenPrimary)
            if want != isFS { main.toggleFullScreen(nil) }
        case "tor.start": torStart()
        case "tor.status": torReport()
        case "web.hideAll":   // boîtes de messagerie : gardées vivantes HORS ÉCRAN (lisibles par l'assistant), jamais détruites ni masquées
            let keep: Set<String> = ["ol", "gm", "tm", "wa"]
            for (pid, p) in panes {
                if detachedPanes[pid] != nil { continue }
                if keep.contains(pid) { placePane(p, NSRect(x: -20000, y: 0, width: 1100, height: 760)) }
                else { p.isHidden = true }
                let hideSig = "id=\(pid) src=hideAll cache=\(p.isHidden ? 1 : 0)"
                if placeLogLast["caller:" + pid] != hideSig { placeLogLast["caller:" + pid] = hideSig; _ = BlackBox.record(["tool": "volet_place", "actor": "Nova", "why": "web.hideAll volet \(pid)", "ok": true, "effect": "lecture", "result": hideSig]) }
            }
        case "web.nav":
            guard let p = panes[id] else { return }
            switch (d["action"] as? String) ?? "" {
            case "back": p.goBack()
            case "forward": p.goForward()
            case "reload": p.reload()
            case "stop": p.stopLoading()
            case "go": if let u = (d["url"] as? String).flatMap({ URL(string: $0) }) { p.load(URLRequest(url: u)) }
            default: break }
        case "web.zoom":
            guard let p = panes[id] else { return }
            switch (d["action"] as? String) ?? "" {
            case "in": p.pageZoom = min(3.0, p.pageZoom + 0.1)
            case "out": p.pageZoom = max(0.5, p.pageZoom - 0.1)
            case "reset": p.pageZoom = 1.0
            default: if let v = d["value"] as? Double { p.pageZoom = min(3.0, max(0.5, v)) } }
            panes[id].map { paneDelegates[id]?.push($0) }
        case "web.clearData":   // cookies, cache, stockage local du navigateur intégré (jamais les clés ni les réglages de Nova)
            let all = WKWebsiteDataStore.allWebsiteDataTypes()
            WKWebsiteDataStore.default().removeData(ofTypes: all, modifiedSince: Date.distantPast) { }
        case "web.close": panes[id]?.removeFromSuperview(); panes[id] = nil; paneDelegates[id] = nil; paneRawFrames[id] = nil; paneFillBottom.remove(id); closePane(id + ".pop")
            _ = BlackBox.record(["tool": "volet_place", "actor": "Nova", "why": "fermeture volet \(id)", "ok": true, "effect": "lecture", "result": "id=\(id) action=fermeture voie=web.close"])
            placeLogLast[id] = nil; placeLogLast["caller:" + id] = nil
        case "web.chats":   // WhatsApp web : liste des conversations avec non lus (lecture seule)
            guard let p = panes[id] else { return }
            let js = "(function(){var rows=document.querySelectorAll('#pane-side [role=listitem], #pane-side [role=row]');var out=[];rows.forEach(function(r){var sp=r.querySelector('span[title]');var name=sp?sp.getAttribute('title'):'';if(!name)return;var t=(r.innerText||'').split('\\n').map(function(x){return x.trim()}).filter(Boolean);var badge=0;var b=r.querySelector('[aria-label*=\"unread\" i],[aria-label*=\"non lu\" i]');if(b){var m=(b.getAttribute('aria-label')||b.innerText||'').match(/\\d+/);badge=m?+m[0]:1}else{var l=t[t.length-1];if(/^\\d{1,4}$/.test(l))badge=+l}if(!badge)return;var prev=t.filter(function(x){return x!==name&&!/^\\d{1,2}[:h.]\\d{2}/.test(x)&&!/^(hier|yesterday|today|aujourd)/i.test(x)&&!/^\\d{1,4}$/.test(x)}).join(' ');var g=(r.querySelector('[data-icon*=group]')||/^[^:]{1,40}:\\s/.test(prev))?1:0;out.push([g,name,badge,prev.slice(0,200)].join('\\t'))});return out.join('\\n')})()"
            p.evaluateJavaScript(js) { [weak self] r, _ in
                let t = (r as? String) ?? ""
                if let data = try? JSONSerialization.data(withJSONObject: [t], options: []), let arr = String(data: data, encoding: .utf8) {
                    self?.mainView.evaluateJavaScript("window.NovaNative&&NovaNative.onText(\"\(id)#c\", \(arr)[0])", completionHandler: nil)
                }
            }
        case "web.eval":   // pilotage d'une page par l'assistant (autorisé par l'utilisateur) : exécute le script dans le volet et renvoie le résultat texte à l'interface
            guard let js = d["js"] as? String, let rid = d["rid"] as? String else { return }
            guard let p = panes[id] else {
                mainView.evaluateJavaScript("window.NovaNative&&NovaNative.onText(\"\(rid)\", \"\")", completionHandler: nil)
                return
            }
            p.evaluateJavaScript(js) { [weak self] r, e in
                if r as? String != nil { self?.notePaneUsed(id) }   // NOVA2-VOLETS : lecture réussie = usage (échec transport ne maintient pas le volet)
                let t = (r as? String) ?? (e != nil ? "{\"ok\":false,\"erreur\":\"script refusé par la page\"}" : "")
                if let data = try? JSONSerialization.data(withJSONObject: [t], options: []), let arr = String(data: data, encoding: .utf8) {
                    self?.mainView.evaluateJavaScript("window.NovaNative&&NovaNative.onText(\"\(rid)\", \(arr)[0])", completionHandler: nil)
                }
            }
        case "web.text":
            guard let p = panes[id] else {
                mainView.evaluateJavaScript("window.NovaNative&&NovaNative.onText(\"\(id)\", \"\")", completionHandler: nil)
                return
            }
            p.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] r, _ in
                if r as? String != nil { self?.notePaneUsed(id) }   // NOVA2-VOLETS : lecture réussie = usage (échec transport ne maintient pas le volet)
                let t = (r as? String) ?? ""
                if let data = try? JSONSerialization.data(withJSONObject: [t], options: []), let arr = String(data: data, encoding: .utf8) {
                    self?.mainView.evaluateJavaScript("window.NovaNative&&NovaNative.onText(\"\(id)\", \(arr)[0])", completionHandler: nil)
                }
            }
        default: break
        }
    }
    // S43-S1 : fermeture de la fenêtre détachée par l'utilisateur = fermeture du volet (même onNav que closePane).
    func detachedWindowWillClose(_ id: String) {
        guard detachedPanes[id] != nil else { return }
        detachedPanes[id] = nil; paneWindowDelegates[id] = nil
        closePane(id)
    }
    func closePane(_ id: String) {
        if let win = detachedPanes[id] { win.delegate = nil; detachedPanes[id] = nil; paneWindowDelegates[id] = nil; win.close() }
        panes[id]?.removeFromSuperview(); panes[id] = nil; paneDelegates[id] = nil; paneLastUsed[id] = nil   // NOVA2-VOLETS
        paneRawFrames[id] = nil; paneFillBottom.remove(id)   // FIXPREP D-R5
        _ = BlackBox.record(["tool": "volet_place", "actor": "Nova", "why": "fermeture volet \(id)", "ok": true, "effect": "lecture", "result": "id=\(id) action=fermeture voie=closePane"])
        placeLogLast[id] = nil; placeLogLast["caller:" + id] = nil
        let o: [String: Any] = ["id": id, "url": "", "title": "", "loading": false, "canBack": false, "canForward": false, "closed": true]
        if let d = try? JSONSerialization.data(withJSONObject: o), let j = String(data: d, encoding: .utf8) { mainView.evaluateJavaScript("window.NovaNative&&NovaNative.onNav(\(j))", completionHandler: nil) }
    }
    func makePop(from id: String, config: WKWebViewConfiguration) -> WKWebView {
        let pid = id + ".pop"
        if panes[pid] != nil { panes[pid]?.removeFromSuperview(); panes[pid] = nil; paneDelegates[pid] = nil }
        let v = WKWebView(frame: panes[id]?.frame ?? .zero, configuration: config)
        let dlg = PaneDelegate(id: pid, owner: self)
        v.navigationDelegate = dlg; v.uiDelegate = dlg; v.allowsBackForwardNavigationGestures = true
        paneDelegates[pid] = dlg; panes[pid] = v; container.addSubview(v); v.isHidden = false
        _ = BlackBox.record(["tool": "volet_place", "actor": "Nova", "why": "création volet \(pid)", "ok": true, "effect": "lecture", "result": "id=\(pid) action=creation popDe=\(id)"])
        dlg.push(v)   // l'interface affiche aussitôt « ✕ Fermer le document »
        return v
    }
    /// Place un volet : un cadre « hors écran » (x < -5000) devient un volet silencieux rendu derrière l'interface ; sinon volet normal au premier plan.
    func placePane(_ p: WKWebView, _ r: NSRect) {
        let q = p as? QuietWebView
        if r.origin.x < -5000 {
            let b = container.bounds
            let w = min(1100, max(320, b.width)); let h = min(760, max(240, b.height))
            p.frame = NSRect(x: 0, y: 0, width: w, height: h); p.alphaValue = 0; q?.quiet = true; p.isHidden = false
            let placeIDPark = panes.first(where: { $0.value === p })?.key ?? "?"
            let placeWasFirstPark = container.subviews.first === p
            let placeHadFirstPark = container.subviews.first != nil
            if let first = container.subviews.first, first !== p { p.removeFromSuperview(); container.addSubview(p, positioned: .below, relativeTo: first) }
            let placeReinsertPark = placeHadFirstPark && !placeWasFirstPark
            let placeSigPark = "id=\(placeIDPark) branche=silencieux reqX=\(Int(r.origin.x)) reqY=\(Int(r.origin.y)) reqW=\(Int(r.size.width)) reqH=\(Int(r.size.height)) posW=\(Int(w)) posH=\(Int(h)) reinsert=\(placeReinsertPark ? 1 : 0) quiet=\((q?.quiet == true) ? 1 : 0) cache=\(p.isHidden ? 1 : 0) alpha=\(Int(p.alphaValue))"
            if placeLogLast[placeIDPark] != placeSigPark { placeLogLast[placeIDPark] = placeSigPark; _ = BlackBox.record(["tool": "volet_place", "actor": "Nova", "why": "parcage volet \(placeIDPark)", "ok": true, "effect": "lecture", "result": placeSigPark]) }
        } else {
            // FIXPREP D-R5 : le rectangle web est intersecté avec le conteneur, puis
            // une hauteur de bande (< 220 px ou < 35 % de la hauteur utile) est
            // étendue jusqu'au bas. Un emplacement Messages est par contrat une
            // zone pleine hauteur (§41/§45), jamais un aperçu de 110 px.
            let paneID = panes.first(where: { $0.value === p })?.key
            let isFirstVisible = paneID.map { paneRawFrames[$0] == nil } ?? false
            if let paneID { paneRawFrames[paneID] = r }
            var f = r.intersection(container.bounds)
            if f.isNull { f = r }
            let usable = max(0, container.bounds.height - f.origin.y)
            let isStrip = usable >= 320 && (f.height < 220 || f.height < usable * 0.35)
            if let paneID, isStrip { paneFillBottom.insert(paneID) }
            if let paneID, paneFillBottom.contains(paneID) { f.size.height = max(f.height, usable) }
            // 27/10 anti-bougé : même cadre, déjà visible et au-dessus → ne rien
            // toucher (poser le même frame relançait la peinture de la page, qui
            // refaisait bouger la mise en page web en boucle).
            if abs(p.frame.origin.x - f.origin.x) < 1 && abs(p.frame.origin.y - f.origin.y) < 1
                && abs(p.frame.size.width - f.size.width) < 1 && abs(p.frame.size.height - f.size.height) < 1
                && !p.isHidden && p.alphaValue == 1 && (q?.quiet != true) && container.subviews.last === p { return }
            p.frame = f; p.alphaValue = 1; q?.quiet = false; p.isHidden = false
            let placeWasLastShow = container.subviews.last === p
            if isFirstVisible || container.subviews.last !== p { p.removeFromSuperview(); container.addSubview(p, positioned: .above, relativeTo: nil) }
            let placeReinsertShow = isFirstVisible || !placeWasLastShow
            let placeIDShow = paneID ?? "?"
            let placeSigShow = "id=\(placeIDShow) branche=visible reqX=\(Int(r.origin.x)) reqY=\(Int(r.origin.y)) reqW=\(Int(r.size.width)) reqH=\(Int(r.size.height)) posX=\(Int(f.origin.x)) posY=\(Int(f.origin.y)) posW=\(Int(f.size.width)) posH=\(Int(f.size.height)) first=\(isFirstVisible ? 1 : 0) reinsert=\(placeReinsertShow ? 1 : 0) quiet=\((q?.quiet == true) ? 1 : 0) cache=\(p.isHidden ? 1 : 0) alpha=\(Int(p.alphaValue))"
            if placeLogLast[placeIDShow] != placeSigShow { placeLogLast[placeIDShow] = placeSigShow; _ = BlackBox.record(["tool": "volet_place", "actor": "Nova", "why": "placement volet \(placeIDShow)", "ok": true, "effect": "lecture", "result": placeSigShow]) }
        }
    }
    func makePane(_ id: String) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        if id == "tor", #available(macOS 14.0, *) {   // navigation via Tor : stockage éphémère (rien n'est conservé) + tout le trafic passe par le SOCKS local de tor
            let ds = WKWebsiteDataStore.nonPersistent()
            ds.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: AppDelegate.torPort)!))]
            cfg.websiteDataStore = ds
        } else {
        cfg.websiteDataStore = WKWebsiteDataStore.default()          // session conservée d'un lancement à l'autre (connexion WhatsApp, Telegram, Facebook)
        }
        cfg.applicationNameForUserAgent = "Version/18.6 Safari/605.1.15"
        let v = QuietWebView(frame: .zero, configuration: cfg)
        let dlg = PaneDelegate(id: id, owner: self)
        v.navigationDelegate = dlg; v.uiDelegate = dlg; v.allowsBackForwardNavigationGestures = true
        paneDelegates[id] = dlg; panes[id] = v; container.addSubview(v)
        paneLastUsed[id] = Date()   // NOVA2-VOLETS
        _ = BlackBox.record(["tool": "volet_place", "actor": "Nova", "why": "création volet \(id)", "ok": true, "effect": "lecture", "result": "id=\(id) action=creation"])
        return v
    }
    // Bouton « Joindre » (input type=file) : WKWebView n'ouvre AUCUN sélecteur sans ce délégué. Les chemins choisis sont aussi
    // transmis à la page (window.__novaPicked) pour que Nova lise les PDF, Word, images… avec ses outils.
    func webView(_ v: WKWebView, runOpenPanelWith p: WKOpenPanelParameters, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let o = NSOpenPanel(); o.allowsMultipleSelection = p.allowsMultipleSelection; o.canChooseDirectories = true; o.canChooseFiles = true   // fichiers ET dossiers entiers
        o.message = "Choisis des fichiers ou un dossier entier à joindre à la discussion"
        // 25/10 : « Joindre un dossier entier » (input webkitdirectory) → sélecteur de DOSSIERS seulement ; « Joindre des fichiers » → fichiers.
        if #available(macOS 13.3, *) {
            if p.allowsDirectories { o.canChooseFiles = false; o.canChooseDirectories = true; o.allowsMultipleSelection = true; o.prompt = "Joindre ce dossier"; o.message = "Choisis un ou plusieurs dossiers : Nova les lira sur place, sans copie" }
            else { o.canChooseDirectories = false; o.message = "Choisis les fichiers à joindre à la discussion" }
        }
        o.begin { r in
            guard r == .OK else { completionHandler(nil); return }
            var items: [[String: Any]] = []; var files: [URL] = []
            for u in o.urls { var isDir: ObjCBool = false; FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir); items.append(["p": u.path, "d": isDir.boolValue]); if !isDir.boolValue { files.append(u) } }
            if let d = try? JSONSerialization.data(withJSONObject: items), let js = String(data: d, encoding: .utf8) {
                v.evaluateJavaScript("window.__novaPicked=" + js + ";window.dispatchEvent(new CustomEvent('nova:picked',{detail:window.__novaPicked}))", completionHandler: nil)
            }
            completionHandler(files.isEmpty ? nil : files)
        }
    }
    // Boîtes de dialogue JavaScript (confirm, alert) de l'interface Nova elle-même
    func webView(_ v: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) { let a = NSAlert(); a.messageText = m; a.runModal(); completionHandler() }
    func webView(_ v: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = m; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Annuler"); completionHandler(a.runModal() == .alertFirstButtonReturn)
    }
    // Les liens externes s'ouvrent dans le navigateur, jamais dans la fenêtre Nova.
    func webView(_ webView: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if a.shouldPerformDownload {
            // NOVA2-FIX 21/10 : WKDownload ne sait pas télécharger une URL nova:// (schéma personnalisé,
            // NSURLErrorUnsupportedURL « unsupported URL ») — cas de TOUTE l'interface quand NovaIPC est
            // actif : on récupère le fichier par le serveur local HTTP et on l'écrit dans ~/Téléchargements.
            if let u = a.request.url, u.scheme == "nova" { fetchNovaDownload(u); decisionHandler(.cancel); return }
            decisionHandler(.download); return
        }
        if let u = a.request.url, u.scheme != "nova", let h = u.host, h != "127.0.0.1", a.navigationType == .linkActivated { NSWorkspace.shared.open(u); decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ v: WKWebView, decidePolicyFor r: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // NOVA2-FIX 21/10 : même garde qu'à l'action — une réponse nova:// non affichable
        // (Content-Disposition: attachment sans attribut download) partait aussi en -1002.
        if !r.canShowMIMEType, let u = r.response.url, u.scheme == "nova" { fetchNovaDownload(u); decisionHandler(.cancel); return }
        decisionHandler(r.canShowMIMEType ? .allow : .download)
    }
    func webView(_ v: WKWebView, navigationAction a: WKNavigationAction, didBecome d: WKDownload) { d.delegate = DownloadHandler.shared }
    func webView(_ v: WKWebView, navigationResponse r: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = DownloadHandler.shared }

    /// NOVA2-FIX 21/10 : téléchargement d'un lien de l'interface servi en nova:// (WKDownload impossible
    /// sur un schéma personnalisé). Rejeu de la même requête sur le serveur local HTTP — jeton du
    /// lancement en « t= » comme loadHTTP, doublé de l'en-tête X-Nova-Token comme le scheme handler —
    /// puis écriture dans ~/Téléchargements via DownloadHandler.save. Échec : même alerte que le handler.
    func fetchNovaDownload(_ u: URL) {
        var qs = u.query ?? ""
        if !qs.isEmpty { qs += "&" }
        guard let hu = URL(string: base + u.path + "?" + qs + "t=\(core.server.token)") else { return }
        var req = URLRequest(url: hu)
        req.setValue(core.server.token, forHTTPHeaderField: "X-Nova-Token")
        let fallbackName = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value ?? "nova-export"
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                let http = resp as? HTTPURLResponse
                var name = fallbackName
                if let cd = http?.value(forHTTPHeaderField: "Content-Disposition"),
                   let m = cd.range(of: "filename=\""), let e = cd.range(of: "\"", range: m.upperBound..<cd.endIndex) {
                    name = String(cd[m.upperBound..<e.lowerBound])
                }
                if let data = data, !data.isEmpty, http?.statusCode == 200, DownloadHandler.save(data, suggestedName: name) != nil { return }
                let al = NSAlert(); al.messageText = "Téléchargement impossible"
                al.informativeText = err?.localizedDescription ?? "HTTP \(http?.statusCode ?? 0)"
                al.runModal()
            }
        }.resume()
    }
    func webView(_ webView: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures w: WKWindowFeatures) -> WKWebView? {
        if let u = a.request.url { NSWorkspace.shared.open(u) }
        return nil
    }
}

/// NOVA2-DOC : boîte de rendu PDF des livrables CAFU — WebKit hors écran (jamais affichée,
/// jamais au premier plan : Nova travaille en arrière-plan), format A4, puis pagination PDFKit.
/// FIX-CRASH (vague n°3) : l'ancien flux pompait la runloop principale de façon réentrante
/// pendant que la fenêtre hôte et la WKWebView vivaient dans la portée de la closure du
/// crochet — 2× EXC_BAD_ACCESS dans objc_release au vidage du pool autorelease du thread
/// principal (21/10, 20:59:27 et 21:01:10). Nouveau flux : la box vit dans un registre fort
/// statique, de sa création (file principale, en async) à sa fin de job ; ses callbacks —
/// tous sur la file principale — enchaînent stabilisation de 0,5 s (asyncAfter, AUCUN
/// pompage) puis createPDF ; la fin de job est idempotente (démontage sur la file
/// principale, PUIS signal du sémaphore) et le fil worker appelant attend ce sémaphore.
/// Chien de garde : 45 s sur la file principale, même chemin de fin, échec nommé « timeout ».
/// FIX-CRASH2 (d'après DIAG-CRASH3) : le crash n°3 (22:09:23Z, même signature) a prouvé
/// que le démontage lui-même tuait : la fenêtre hôte, créée par code SANS
/// isReleasedWhenClosed = false, recevait DEUX libérations par job (close() puis
/// host = nil) et le vidage du pool autorelease du thread principal détonait sur le
/// cadavre, pendant le job ou longtemps après. Le cycle de vie par job est donc
/// SUPPRIMÉ : moteur de rendu persistant (LivrablePDFEngine ci-dessous) — une seule
/// WKWebView et une seule fenêtre hôte, créées une fois sur la file principale et
/// retenues pour la vie du processus, jamais fermées ni nilées ; délégué PERMANENT
/// routant chaque rappel vers l'enregistrement du job courant ; fin de job réduite
/// à marquer l'étape, vider la fente, puis signaler le sémaphore du job.

/// Enregistrement d'UN job de rendu PDF : id, sémaphore, étapes et résultat.
/// Porté par la fente unique du moteur pendant le job, et par la référence locale
/// du fil worker appelant. Aucun objet AppKit/WebKit ne vit ici.
final class LivrablePDFJob {
    let id = UUID()
    let sema = DispatchSemaphore(value: 0)
    var mark: ((String) -> Void)?
    // État lu/écrit sur la file principale, SAUF pdfData/errorStage : écrits sur la
    // file principale AVANT le signal du sémaphore, relus par le fil worker APRÈS
    // l'attente (le sémaphore établit le happens-before).
    var pdfData: Data?
    var errorStage: String?
    var finished = false
    var pdfScheduled = false, pdfRetried = false
    var navigation: WKNavigation?   // identité de la navigation du job : garde des rappels du délégué
}

/// Délégué de navigation PERMANENT du moteur de rendu : une seule instance, créée
/// avec le moteur et détenue par lui pour la vie du processus — jamais réassigné,
/// jamais nilé. Il ne porte aucun état de job : chaque rappel est routé vers le
/// job courant du moteur et gardé par l'identité de la navigation (ou, pour la
/// complétion createPDF, par l'id du job) — un rappel tardif (navigation remplacée
/// par le job suivant, rendu zombie après timeout) tombe sur une fente vide ou
/// étrangère et est ignoré proprement.
final class LivrablePDFBox: NSObject, WKNavigationDelegate {
    func webView(_ v: WKWebView, didFinish navigation: WKNavigation!) {
        guard let job = LivrablePDFEngine.currentJob, job.navigation === navigation,
              !job.finished, !job.pdfScheduled else { return }
        job.pdfScheduled = true
        // La peinture suit didFinish : 0,5 s de stabilisation SANS pomper la runloop.
        let id = job.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { LivrablePDFEngine.startPDF(jobID: id) }
    }
    func webView(_ v: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let job = LivrablePDFEngine.currentJob, job.navigation === navigation else { return }
        LivrablePDFEngine.finish(job, failure: "navigation échouée")
    }
    func webView(_ v: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let job = LivrablePDFEngine.currentJob, job.navigation === navigation else { return }
        LivrablePDFEngine.finish(job, failure: "navigation échouée")
    }
}

/// FIX-CRASH2 : moteur de rendu PDF PERSISTANT. Une WKWebView A4 (595×842) et une
/// fenêtre hôte borderless jamais montrée, créées UNE fois sur la file principale
/// à la première demande et retenues par ces statiques pour la vie du processus :
/// jamais close(), jamais de mise à nil, jamais de retrait — la paire
/// « close() + libération ARC » qui sur-libérait la fenêtre à chaque job
/// (DIAG-CRASH3, suspect (a), ÉTABLI par le code) n'existe plus dans le chemin
/// d'un job. La fenêtre porte isReleasedWhenClosed = false dès sa création
/// (invariant maison, cf. fenêtres principale et panneau). Verrou de
/// sérialisation conservé : un seul rendu à la fois, tout job concurrent attend.
enum LivrablePDFEngine {
    static let renderLock = NSLock()
    // État du moteur : file principale uniquement (création, rappels WebKit, fente).
    private static var webView: WKWebView?
    private static var host: NSWindow?
    private static var delegateBox: LivrablePDFBox?
    private(set) static var currentJob: LivrablePDFJob?
    // Constantes du pied de page (DIAG-CRASH3, volet (b)) : résolues UNE fois sur la
    // file principale à la naissance du moteur — la recherche de la police par nom
    // (aller-retour XPC d'auto-activation CoreText) n'a lieu qu'ici, jamais sur le
    // fil worker — puis figées. NSFont/NSColor sont immuables : sûrs à utiliser
    // ensuite depuis le fil worker pendant le tamponnage.
    private(set) static var footerFont: NSFont = NSFont.systemFont(ofSize: 8)
    private(set) static var contactColor: NSColor = NSColor(srgbRed: 0.678, green: 0.122, blue: 0.137, alpha: 1)   // #AD1F23
    private(set) static var pageColor: NSColor = NSColor(srgbRed: 0.306, green: 0.231, blue: 0.188, alpha: 1)      // #4E3B30

    /// Naissance du moteur (file principale, une seule fois) : résolution des
    /// constantes du pied de page, vue WebKit, fenêtre hôte, délégué permanent.
    static func ensureCreated() {
        guard webView == nil else { return }
        footerFont = NSFont(name: "Aptos", size: 8) ?? NSFont.systemFont(ofSize: 8)
        // DIAG2 D-R6 : une WKWebView hors de toute hiérarchie peut terminer sa
        // navigation sans jamais peindre — createPDF rend alors 0 page, que le
        // garde pageCount du crochet invalide. Fenêtre hôte réelle mais JAMAIS
        // montrée (orderOut, aucun orderFront à aucun moment) : Nova reste en
        // arrière-plan, l'utilisateur n'est pas dérangé.
        // Magasin de données NON persistant : le moteur est partagé entre jobs —
        // aucun cookie ni stockage ne survit d'un rendu à l'autre (le HTML rendu
        // est local : loadHTMLString, baseURL: nil, aucune dépendance réseau).
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 595, height: 842), configuration: config)   // A4 à 72 dpi
        let h = NSWindow(contentRect: wv.frame, styleMask: .borderless, backing: .buffered, defer: false)
        h.isReleasedWhenClosed = false
        h.contentView = wv
        h.orderOut(nil)
        let box = LivrablePDFBox()
        wv.navigationDelegate = box
        webView = wv
        host = h
        delegateBox = box
    }

    /// Ouverture d'un job (file principale) : le moteur naît au besoin, la fente
    /// reçoit le job, la navigation démarre et le chien de garde de 45 s est armé
    /// pour CE job — sa garde par id fait qu'il ne peut terminer que lui.
    static func begin(_ job: LivrablePDFJob, html: String) {
        ensureCreated()
        currentJob = job
        job.mark?("navigation")
        job.navigation = webView?.loadHTMLString(html, baseURL: nil)
        let id = job.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { finishIfCurrent(jobID: id, failure: "timeout") }
    }

    /// Démarrage du createPDF (file principale, via le délégué après la
    /// stabilisation de 0,5 s). Garde par id : un appel tardif pour un job fini
    /// ou remplacé est ignoré.
    static func startPDF(jobID: UUID) {
        guard let job = currentJob, job.id == jobID, !job.finished, let wv = webView else { return }
        if !job.pdfRetried { job.mark?("createPDF") }
        wv.createPDF(configuration: WKPDFConfiguration()) { r in
            var d: Data? = nil
            if case .success(let data) = r { d = data }
            pdfCompleted(jobID: jobID, data: d)
        }
    }

    /// Complétion createPDF : re-dispatchée sur la file principale si besoin, puis
    /// routée par id vers la fente. Si le job est déjà fini (timeout) ou remplacé,
    /// la donnée zombie est abandonnée sans toucher au job courant.
    static func pdfCompleted(jobID: UUID, data: Data?) {
        if !Thread.isMainThread { DispatchQueue.main.async { pdfCompleted(jobID: jobID, data: data) }; return }
        guard let job = currentJob, job.id == jobID, !job.finished else { return }
        if let data { job.pdfData = data; finish(job, failure: nil) }
        else if !job.pdfRetried { job.pdfRetried = true; startPDF(jobID: jobID) }
        else { finish(job, failure: "createPDF vide après réessai") }
    }

    /// Chien de garde : ne termine le job que si la fente le porte encore.
    static func finishIfCurrent(jobID: UUID, failure: String) {
        guard let job = currentJob, job.id == jobID else { return }
        finish(job, failure: failure)
    }

    /// Fin de job, UNE seule fois (garde idempotente) : AUCUN démontage — ni
    /// close(), ni contentView, ni délégué touchés ; le moteur survit et reste
    /// utilisable pour le job suivant, qui remplacera la page par son propre
    /// loadHTMLString. On marque l'échec éventuel, on vide la fente, PUIS on
    /// signale le sémaphore qui réveille le fil worker.
    static func finish(_ job: LivrablePDFJob, failure: String?) {
        if !Thread.isMainThread { DispatchQueue.main.async { finish(job, failure: failure) }; return }
        guard currentJob === job, !job.finished else { return }
        job.finished = true
        if let failure { job.errorStage = failure; job.mark?(failure) }
        currentJob = nil
        job.sema.signal()
    }
}

VaultHooks.pdfText = { path in PDFDocument(url: URL(fileURLWithPath: path))?.string }
VaultBiometric.register(BiometricKeychain())   // PHASE 4 : clé du coffre derrière Touch ID au Trousseau (opt-in : POST /api/vault/biometric/enable) — couper : retirer cette ligne
// NOVA2-DOC : rendu PDF du gabarit maître CAFU (même HTML que cafu_format_document) + pied de
// page charte tamponné sur chaque page : contact #AD1F23 à gauche, « Page X of Y » #4E3B30 à droite.
LivrableHooks.htmlToPDF = { html, outPath in
    // DIAG2 D-R6 : le crochet ne rend qu'un Bool et ses gardes internes sont
    // silencieuses — chacune nomme donc son étape dans un sidecar <pdf>.err,
    // supprimé en cas de succès. La prochaine panne dira QUELLE garde a cédé.
    let mark: (String) -> Void = { stage in
        try? stage.write(toFile: outPath + ".err", atomically: true, encoding: .utf8)
    }
    // FIX-CRASH/FIX-CRASH2 : unique appelant = Livrables.generate (Livrables.swift),
    // sur un fil worker du serveur. Appelé un jour depuis le fil principal, le crochet
    // refuse net : jamais d'attente de sémaphore ni de file principale depuis ce fil.
    guard !Thread.isMainThread else { mark("appel sur le fil principal refusé"); return false }
    // Sérialisation : un seul rendu PDF à la fois — les jobs se succèdent, jamais
    // ils ne se chevauchent (deuxième verrou, applicatif, par-dessus la file serveur).
    LivrablePDFEngine.renderLock.lock()
    defer { LivrablePDFEngine.renderLock.unlock() }
    let job = LivrablePDFJob()
    job.mark = mark
    // Ouverture du job ASYNC sur la file principale (aucune synchronisation bloquante,
    // aucun pompage de runloop) : le moteur persistant y naît au besoin, reçoit le
    // job dans sa fente et démarre sa navigation.
    DispatchQueue.main.async { LivrablePDFEngine.begin(job, html: html) }
    // Le fil worker attend la fin du job ; la file principale reste libre de servir
    // l'interface et les callbacks WebKit — plus aucun interblocage possible.
    if job.sema.wait(timeout: .now() + 60) == .timedOut {
        // Le chien de garde (45 s) a déjà terminé le job sur la file principale.
        mark("timeout")
        return false
    }
    guard job.errorStage == nil else { return false }   // échec déjà nommé dans le sidecar par finish()
    mark("validation")
    // DIAG-CRASH3, volet (b) : validation, tamponnage et écriture sous un pool
    // explicite PAR JOB — les fils du serveur n'ont pas de pool garanti ; sans lui,
    // les objets autoreleased du tamponnage s'accumulent entre jobs. Police et
    // couleurs : constantes du moteur, pré-résolues sur la file principale.
    return autoreleasepool {
        guard let data = job.pdfData, let doc = PDFDocument(data: data), doc.pageCount > 0 else { return false }
        let font = LivrablePDFEngine.footerFont
        let contactColor = LivrablePDFEngine.contactColor
        let pageColor = LivrablePDFEngine.pageColor
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let b = page.bounds(for: .mediaBox)
            let contact = PDFAnnotation(bounds: CGRect(x: 40, y: 16, width: 370, height: 12), forType: .freeText, withProperties: nil)
            contact.contents = "For feedback or questions, please contact: Ahadi Dahani"
            contact.font = font; contact.fontColor = contactColor; contact.alignment = .left
            page.addAnnotation(contact)
            let num = PDFAnnotation(bounds: CGRect(x: b.maxX - 190, y: 16, width: 150, height: 12), forType: .freeText, withProperties: nil)
            num.contents = "Page \(i + 1) of \(doc.pageCount)"
            num.font = font; num.fontColor = pageColor; num.alignment = .right
            page.addAnnotation(num)
        }
        mark("ecriture")
        let ok = doc.write(to: URL(fileURLWithPath: outPath))
        if ok { try? FileManager.default.removeItem(atPath: outPath + ".err") }
        return ok
    }
}
// Lentille contextuelle : app au premier plan (nom + identifiant), sans API d'accessibilité ni titre de fenêtre.
SystemHooks.frontmostProvider = { () -> (String, String) in
    let a = NSWorkspace.shared.frontmostApplication
    return (a?.localizedName ?? "", a?.bundleIdentifier ?? "")
}
/// MISSION 7 + NOVA PARTOUT (24/10) : fournisseur des Services macOS (Info.plist › NSServices) — texte sélectionné dans
/// n'importe quelle app → panneau compact, pré-rempli, JAMAIS envoyé ni écrit sans geste dans le panneau (Entrée / « Retenir »).
/// Le panneau est non activant : l'app d'où vient le texte reste devant.
final class NovaServiceProvider: NSObject {
    static let shared = NovaServiceProvider()
    weak var owner: AppDelegate?
    @objc func askNova(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) { deliver(pb, mode: "ask", error: error) }
    @objc func summarizeNova(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) { deliver(pb, mode: "resume", error: error) }
    @objc func rememberNova(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) { deliver(pb, mode: "retenir", error: error) }
    private func deliver(_ pb: NSPasteboard, mode: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let t = pb.string(forType: .string), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let o = owner else {
            error.pointee = "Aucun texte sélectionné" as NSString; return
        }
        o.showAsk(text: "", context: String(t.prefix(12000)), mode: mode, source: "service")
    }
}

// P1-INSTR (23/10) : ancre de démarrage — t0 monotone du processus + horloge murale (ms), première ligne du journal de chaque lancement : t0 de M1 (démarrage → écran utile).
_ = BlackBox.record(["tool": "boot_anchor", "actor": "Nova", "why": "ancre de démarrage du processus (M1)", "ok": true, "effect": "lecture", "result": "t0_processus=\(ProcessInfo.processInfo.systemUptime) ts_mural_ms=\(Int(Date().timeIntervalSince1970 * 1000))"])
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
#else
print("NovaMac requiert macOS (AppKit). Utilise nova-server sur les autres plateformes.")
#endif


// 30/10 : couleur depuis « #RRGGBB » (teinte du verre natif envoyée par l'interface).
extension NSColor {
    static func novaHex(_ hex: String, alpha: CGFloat) -> NSColor? {
        var h: String = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }
}
