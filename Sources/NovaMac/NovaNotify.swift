#if canImport(AppKit) && canImport(UserNotifications)
import AppKit
import UserNotifications
import NovaCore

// V5-H (24/10/2026) — Notifications natives cliquables (UNUserNotificationCenter, macOS 13+).
//
// - Pose NovaNotifier.post : chaque notification du cœur devient une vraie notification de Nova
//   (icône de l'app, regroupée par écran via threadIdentifier), avec la cible {module, id} en userInfo.
// - Catégorie « nova.item » : actions « Voir » (ouvre l'élément dans Nova) et « Plus tard »
//   (la même notification revient dans 1 h, sans mettre Nova au premier plan).
// - Autorisation demandée UNE fois, au premier besoin réel (pas au lancement) ; un refus est respecté
//   (aucun contournement par osascript).
// - Fenêtre de Nova active (NSApp.isActive) : AUCUNE notification — le contenu arrive déjà dans l'app.
// - Hors paquet .app (binaire lancé depuis .build), UNUserNotificationCenter lève une exception :
//   install() ne fait alors rien et le cœur garde son repli osascript.
final class NovaNotify: NSObject, UNUserNotificationCenterDelegate {
    static let shared: NovaNotify = NovaNotify()
    static let categoryId: String = "nova.item"
    static let actionView: String = "nova.voir"
    static let actionLater: String = "nova.plustard"

    private var openHandler: ((String, String) -> Void)? = nil
    private let lock: NSLock = NSLock()
    private var askedOnce: Bool = false
    private var activeFlag: Bool = false
    private var observers: [NSObjectProtocol] = []

    /// À appeler une fois, dans applicationDidFinishLaunching, après buildMain().
    /// `open(module, id)` est appelé sur la file principale quand Ahadi clique la notification ou « Voir ».
    static func install(open: @escaping (_ module: String, _ id: String) -> Void) {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let me: NovaNotify = shared
        me.openHandler = open
        let center: UNUserNotificationCenter = UNUserNotificationCenter.current()
        center.delegate = me
        let voir: UNNotificationAction = UNNotificationAction(identifier: actionView, title: "Voir", options: [.foreground])
        let tard: UNNotificationAction = UNNotificationAction(identifier: actionLater, title: "Plus tard", options: [])
        let cat: UNNotificationCategory = UNNotificationCategory(identifier: categoryId, actions: [voir, tard], intentIdentifiers: [], options: [])
        center.setNotificationCategories([cat])
        me.lock.lock(); me.activeFlag = NSApp.isActive; me.lock.unlock()
        let nc: NotificationCenter = NotificationCenter.default
        me.observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in me.setActive(true) })
        me.observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { _ in me.setActive(false) })
        NovaNotifier.appActive = { me.isActiveNow() }
        NovaNotifier.post = { (title: String, body: String, target: [String: String], sound: Bool) in
            me.deliver(title: title, body: body, target: target, sound: sound)
        }
    }

    private func setActive(_ v: Bool) { lock.lock(); activeFlag = v; lock.unlock() }
    private func isActiveNow() -> Bool { lock.lock(); defer { lock.unlock() }; return activeFlag }

    /// Script injecté dans la fenêtre principale pour ouvrir la cible : navigation du shell, puis
    /// événement « nova:notif-open » {module, id} que l'écran concerné écoute pour ouvrir l'élément.
    static func openScript(module: String, id: String) -> String {
        let o: [String: String] = ["module": module, "id": id]
        guard let d = try? JSONSerialization.data(withJSONObject: o), let j = String(data: d, encoding: .utf8) else { return "" }
        return "(function(t){try{if(window.NovaWorkspace&&t.module)NovaWorkspace.navigate(t.module);setTimeout(function(){try{if(window.NovaBus)NovaBus.emit('nova:notif-open',t)}catch(e){}},400)}catch(e){}})(" + j + ")"
    }

    private func deliver(title: String, body: String, target: [String: String], sound: Bool) {
        DispatchQueue.main.async {
            // VEILLE-MAIL (24/10 soir) : un NOUVEAU MAIL s'affiche aussi quand Nova est au premier plan (bannière sans son,
            // comme Muse) — Ahadi l'attend ; les autres notifications restent muettes quand Nova est active.
            let isMail: Bool = (target["module"] ?? "") == "messages"
            if NSApp.isActive && !isMail { return }
            let snd: Bool = sound && !NSApp.isActive
            let center: UNUserNotificationCenter = UNUserNotificationCenter.current()
            center.getNotificationSettings { (s: UNNotificationSettings) in
                let st: UNAuthorizationStatus = s.authorizationStatus
                if st == .denied { return }
                if st == .notDetermined {
                    self.lock.lock()
                    let first: Bool = !self.askedOnce
                    self.askedOnce = true
                    self.lock.unlock()
                    if !first { return }
                    center.requestAuthorization(options: [.alert, .sound]) { (granted: Bool, err: Error?) in
                        if granted && err == nil { self.add(title: title, body: body, target: target, sound: snd, after: 0) }
                    }
                    return
                }
                self.add(title: title, body: body, target: target, sound: snd, after: 0)
            }
        }
    }

    private func add(title: String, body: String, target: [String: String], sound: Bool, after: TimeInterval) {
        let c: UNMutableNotificationContent = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.categoryIdentifier = NovaNotify.categoryId
        c.threadIdentifier = target["module"] ?? "nova"
        var info: [AnyHashable: Any] = [:]
        for (k, v) in target { info[k] = v }
        c.userInfo = info
        if sound { c.sound = UNNotificationSound.default }
        var trigger: UNNotificationTrigger? = nil
        if after > 0 { trigger = UNTimeIntervalNotificationTrigger(timeInterval: after, repeats: false) }
        let req: UNNotificationRequest = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: trigger)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // Nova au premier plan au moment où une notification arrive (rappel « Plus tard » compris) : rien n'est affiché.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let mail: Bool = notification.request.content.threadIdentifier == "messages"
        if mail { completionHandler([.banner, .list]) } else { completionHandler([]) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let content: UNNotificationContent = response.notification.request.content
        let info: [AnyHashable: Any] = content.userInfo
        let module: String = (info["module"] as? String) ?? ""
        let id: String = (info["id"] as? String) ?? ""
        let action: String = response.actionIdentifier
        if action == NovaNotify.actionLater {
            var target: [String: String] = [:]
            if !module.isEmpty { target["module"] = module }
            if !id.isEmpty { target["id"] = id }
            add(title: content.title, body: content.body, target: target, sound: content.sound != nil, after: 3600)
        } else if action == NovaNotify.actionView || action == UNNotificationDefaultActionIdentifier {
            let h: ((String, String) -> Void)? = openHandler
            DispatchQueue.main.async { h?(module, id) }
        }
        completionHandler()
    }
}
#endif
