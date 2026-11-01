#if canImport(AppKit)
import AppKit
import WebKit
import NovaCore

// V6-COMPAGNON (25/10) — compagnon flottant natif, façon Muse : un médaillon de Nova (avatar illustré + « Nova »)
// posé sur le bureau AU-DESSUS des apps, sur tous les Spaces et en plein écran, déplaçable, jamais activant
// (l'app au premier plan garde le clavier). Contenu : web/companion.html (js/companion-float.js) servi par la
// même origine que l'interface (load(_:_:) : http://127.0.0.1:<port> ou nova://app). Position mémorisée
// (UserDefaults « nova_companion_frame »), ramenée sur un écran visible. Réglage companion_float (défaut true),
// basculé par le menu de la barre « Afficher le compagnon flottant » ; relu à chaque ouverture du menu.
// Gestes (messages du web) : compDragStart / compDrag / compDragEnd (glisser natif, même calcul que le panneau),
// compClick → panneau compact « Demander à Nova » (toggleAsk, ⌃⌥Espace), openMain → fenêtre, compMenu → menu.

/// 25/10 : état du glisser natif du compagnon.
enum CompDrag {
    nonisolated(unsafe) static var timer: Timer? = nil
    nonisolated(unsafe) static var moved: Bool = false
    nonisolated(unsafe) static var endedAt: Date = Date.distantPast
}

extension AppDelegate {

    static let compFrameKey: String = "nova_companion_frame_v2"   // 25/10 : v2 = position par défaut au milieu du bord droit (l'ancienne, en bas, est oubliée une fois)
    static let compSize: NSSize = NSSize(width: 150, height: 200)   // 25/10 : corps libre, sans médaillon

    func companionEnabled() -> Bool {
        guard core != nil else { return true }
        let on: Bool = core.settings.get("companion_float", true)
        return on
    }

    func buildCompanion() {
        let size: NSSize = AppDelegate.compSize
        let p: FloatingPanel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = false   // la WebView reçoit la souris : le glisser est natif, piloté par le web
        p.ignoresMouseEvents = false
        let v: WKWebView = makeWebView(transparent: true)
        v.frame = NSRect(origin: .zero, size: size)
        v.autoresizingMask = [.width, .height]
        p.contentView = v
        compPanel = p
        compView = v
        p.setFrameOrigin(companionOrigin(size))
        load(v, "/companion.html")
        if companionEnabled() { p.orderFrontRegardless() }
        compMenuItem?.state = p.isVisible ? .on : .off
    }

    /// Position mémorisée, ramenée dans l'écran visible qui la contient ; sinon bas-droite de l'écran principal.
    func companionOrigin(_ size: NSSize) -> NSPoint {
        if let saved: String = UserDefaults.standard.string(forKey: AppDelegate.compFrameKey) {
            let r: NSRect = NSRectFromString(saved)
            for sc in NSScreen.screens {
                let vf: NSRect = sc.visibleFrame
                if vf.intersects(r) {
                    let x: CGFloat = min(max(r.origin.x, vf.minX), vf.maxX - size.width)
                    let y: CGFloat = min(max(r.origin.y, vf.minY), vf.maxY - size.height)
                    return NSPoint(x: x, y: y)
                }
            }
        }
        guard let s: NSScreen = NSScreen.main else { return NSPoint(x: 80, y: 120) }
        let vf: NSRect = s.visibleFrame
        return NSPoint(x: vf.maxX - size.width - 12, y: vf.midY - size.height / 2 + 60)   // 25/10 : milieu du bord droit (en bas, il couvrait boutons d'envoi et interrupteurs)
    }

    func saveCompanionFrame() {
        guard let p = compPanel else { return }
        UserDefaults.standard.set(NSStringFromRect(p.frame), forKey: AppDelegate.compFrameKey)
    }

    func setCompanionVisible(_ on: Bool, persist: Bool) {
        guard let p = compPanel else { return }
        if on { p.orderFrontRegardless() } else { p.orderOut(nil) }
        if persist, core != nil { core.settings.set(["companion_float": on]) }
        compMenuItem?.state = on ? .on : .off
    }

    /// Ouverture du menu de la barre : le réglage (modifiable aussi depuis Réglages via /api/settings) fait foi.
    func applyCompanionSetting() {
        guard let p = compPanel else { return }
        let want: Bool = companionEnabled()
        if want != p.isVisible { setCompanionVisible(want, persist: false) }
        compMenuItem?.state = p.isVisible ? .on : .off
    }

    @objc func toggleCompanion(_ sender: Any?) {
        let now: Bool = compPanel?.isVisible ?? false
        setCompanionVisible(!now, persist: true)
    }

    @objc func hideCompanion(_ sender: Any?) { setCompanionVisible(false, persist: true) }

    @objc func companionLive(_ sender: Any?) {
        runJS(compView, "window.NovaCompanion&&window.NovaCompanion.toggleLive()")
    }

    @objc func companionAsk(_ sender: Any?) { toggleAsk() }

    /// 25/10 : garde le compagnon entièrement dans l'écran visible qui le contient (position COURANTE, pas la mémorisée).
    func clampCompanion(_ r: NSRect) -> NSPoint {
        let sc: NSScreen? = NSScreen.screens.first(where: { (s: NSScreen) -> Bool in s.visibleFrame.intersects(r) }) ?? NSScreen.main
        guard let vf: NSRect = sc?.visibleFrame else { return r.origin }
        let x: CGFloat = min(max(r.origin.x, vf.minX), vf.maxX - r.width)
        let y: CGFloat = min(max(r.origin.y, vf.minY), vf.maxY - r.height)
        return NSPoint(x: x, y: y)
    }

    /// 25/10 : menu « Placer » — coins de l'écran visible (au-dessus du Dock, sous la barre des menus).
    @objc func companionPlace(_ sender: Any?) {
        guard let p = compPanel, let it = sender as? NSMenuItem, let code = it.representedObject as? String else { return }
        guard let vf: NSRect = (p.screen ?? NSScreen.main)?.visibleFrame else { return }
        let w: CGFloat = p.frame.width
        let h: CGFloat = p.frame.height
        var o: NSPoint = NSPoint(x: vf.maxX - w - 8, y: vf.minY + 4)
        if code == "bl" { o = NSPoint(x: vf.minX + 8, y: vf.minY + 4) }
        if code == "tr" { o = NSPoint(x: vf.maxX - w - 8, y: vf.maxY - h - 4) }
        if code == "tl" { o = NSPoint(x: vf.minX + 8, y: vf.maxY - h - 4) }
        if code == "mr" { o = NSPoint(x: vf.maxX - w - 12, y: vf.midY - h / 2 + 60) }
        p.setFrameOrigin(o)
        saveCompanionFrame()
    }

    @objc func companionStyle(_ sender: Any?) {
        runJS(compView, "window.NovaCompanion&&window.NovaCompanion.toggleStyle()")
    }

    /// Panneau compact posé à gauche du compagnon (à droite s'il n'y a pas la place), bas aligné, dans l'écran visible.
    func placePanelBesideCompanion(_ c: NSRect) {
        let size: NSSize = panel.frame.size
        let vis: NSRect = (compPanel?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x: CGFloat = c.minX - size.width - 6
        if x < vis.minX { x = c.maxX + 6 }
        x = min(max(x, vis.minX), vis.maxX - size.width)
        var y: CGFloat = c.minY
        y = min(max(y, vis.minY), vis.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func handleCompanionMessage(_ cmd: String) {
        guard let p = compPanel else { return }
        switch cmd {
        case "compDragStart":
            // 25/10 (Ahadi : « on n'arrive pas à déplacer l'avatar ») — glisser NATIF : le suivi lit la vraie souris
            // à 60 i/s tant que le bouton reste enfoncé (avant : dépendait des pointermove de la page, perdus dès que
            // le curseur sortait de la petite fenêtre, et le lâcher remettait l'ancienne position mémorisée).
            dragMouse0 = NSEvent.mouseLocation
            dragOrigin0 = p.frame.origin
            CompDrag.moved = false
            CompDrag.timer?.invalidate()
            CompDrag.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] (t: Timer) in
                guard let self = self, let pp = self.compPanel else { t.invalidate(); return }
                let m: NSPoint = NSEvent.mouseLocation
                let dx: CGFloat = m.x - self.dragMouse0.x
                let dy: CGFloat = m.y - self.dragMouse0.y
                if !CompDrag.moved && abs(dx) + abs(dy) > 4 { CompDrag.moved = true }
                if CompDrag.moved { pp.setFrameOrigin(NSPoint(x: self.dragOrigin0.x + dx, y: self.dragOrigin0.y + dy)) }
                if (NSEvent.pressedMouseButtons & 1) == 0 {
                    t.invalidate()
                    CompDrag.timer = nil
                    if CompDrag.moved {
                        CompDrag.endedAt = Date()
                        pp.setFrameOrigin(self.clampCompanion(pp.frame))
                        self.saveCompanionFrame()
                    }
                }
            }
        case "compDrag":
            break   // 25/10 : suivi natif (ci-dessus)
        case "compDragEnd":
            break
        case "compClick":
            if Date().timeIntervalSince(CompDrag.endedAt) < 0.6 { break }   // 25/10 : un glisser n'est pas un clic
            if !panel.isVisible { placePanelBesideCompanion(p.frame) }   // 25/10 : le panneau ne recouvre jamais le compagnon (2e clic = fermer)
            toggleAsk()
        case "compMenu":
            let menu: NSMenu = NSMenu(title: "Nova")
            let a: NSMenuItem = NSMenuItem(title: "Demander à Nova…  ⌃⌥Espace", action: #selector(companionAsk(_:)), keyEquivalent: "")
            a.target = self
            let o: NSMenuItem = NSMenuItem(title: "Ouvrir Nova", action: #selector(showMain), keyEquivalent: "")
            o.target = self
            let l: NSMenuItem = NSMenuItem(title: "Parler (Live)", action: #selector(companionLive(_:)), keyEquivalent: "")
            l.target = self
            let sty: NSMenuItem = NSMenuItem(title: "Changer d'apparence (illustration / 3D corps entier)", action: #selector(companionStyle(_:)), keyEquivalent: "")
            sty.target = self
            menu.addItem(sty)
            let place: NSMenuItem = NSMenuItem(title: "Placer", action: nil, keyEquivalent: "")
            let sub: NSMenu = NSMenu(title: "Placer")
            let spots: [(String, String)] = [("Coin bas droit", "br"), ("Coin bas gauche", "bl"), ("Coin haut droit", "tr"), ("Coin haut gauche", "tl"), ("Milieu du bord droit", "mr")]
            for sp in spots {
                let it: NSMenuItem = NSMenuItem(title: sp.0, action: #selector(companionPlace(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = sp.1
                sub.addItem(it)
            }
            place.submenu = sub
            menu.addItem(place)
            let hd: NSMenuItem = NSMenuItem(title: "Masquer le compagnon", action: #selector(hideCompanion(_:)), keyEquivalent: "")
            hd.target = self
            menu.addItem(a)
            menu.addItem(o)
            menu.addItem(l)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(hd)
            if let cv = p.contentView {
                let w: NSPoint = p.mouseLocationOutsideOfEventStream
                let at: NSPoint = cv.convert(w, from: nil)
                _ = menu.popUp(positioning: nil, at: at, in: cv)
            }
        default:
            break
        }
    }
}
#endif
