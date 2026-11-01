import Foundation
#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
#endif
#if canImport(AVFoundation) && os(macOS)
import AVFoundation
#endif
#if canImport(EventKit) && os(macOS)
import EventKit
#endif

/// Page « Droits » : tableau de bord des autorisations macOS de Nova.
/// Garde-fous : aucun test n'affiche quoi que ce soit ni ne lance d'application ; aucune demande d'autorisation n'est déclenchée
/// (Automatisation : AEDeterminePermissionToAutomateTarget avec askUserIfNeeded = false AVANT tout osascript).
/// Seule exception au « jamais au premier plan » : POST /api/droits/open, déclenché par un clic de l'utilisateur.
final class DroitsCache: @unchecked Sendable {
    static let shared: DroitsCache = DroitsCache()
    let lock: NSLock = NSLock()
    var at: Date = Date.distantPast
    var items: [[String: Any]] = []
}

private let droitsPaneBase: String = "x-apple.systempreferences:com.apple.preference.security?"

private func droitsItem(_ id: String, _ label: String, _ state: String, _ detail: String, _ pane: String) -> [String: Any] {
    let ok: Bool = (state == "ok")
    let item: [String: Any] = ["id": id, "label": label, "ok": ok, "state": state, "detail": detail, "pane": droitsPaneBase + pane]
    return item
}

/// Vraie lecture de quelques octets (isReadableFile seul ne suffit pas : TCC bloque à l'ouverture).
private func droitsCanRead(_ path: String) -> Bool {
    let fm: FileManager = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return false }
    if isDir.boolValue {
        do { _ = try fm.contentsOfDirectory(atPath: path); return true } catch { return false }
    }
    guard fm.isReadableFile(atPath: path) else { return false }
    guard let fh: FileHandle = FileHandle(forReadingAtPath: path) else { return false }
    let data: Data = fh.readData(ofLength: 16)
    fh.closeFile()
    return data.count > 0
}

private func droitsFullDisk() -> [String: Any] {
    let home: String = NSHomeDirectory()
    let paths: [String] = [
        home + "/Library/Application Support/com.apple.TCC/TCC.db",
        home + "/Library/Safari/Bookmarks.plist",
        home + "/Library/Mail",
    ]
    var existing: Int = 0
    for p in paths {
        if FileManager.default.fileExists(atPath: p) { existing += 1 }
        if droitsCanRead(p) {
            let name: String = (p as NSString).lastPathComponent
            return droitsItem("disque", "Accès complet au disque", "ok", "Lecture réussie (" + name + ").", "Privacy_AllFiles")
        }
    }
    if existing == 0 {
        return droitsItem("disque", "Accès complet au disque", "na", "Aucun fichier témoin trouvé : impossible de vérifier.", "Privacy_AllFiles")
    }
    return droitsItem("disque", "Accès complet au disque", "no", "Lecture refusée : Mail, Safari et la base TCC restent illisibles.", "Privacy_AllFiles")
}

private func droitsAccessibility() -> [String: Any] {
    #if os(macOS)
    let trusted: Bool = AXIsProcessTrusted()
    if trusted { return droitsItem("accessibilite", "Accessibilité", "ok", "Nova peut lire et piloter l'interface des apps.", "Privacy_Accessibility") }
    return droitsItem("accessibilite", "Accessibilité", "no", "Non accordée : le pilotage de l'interface (outil ui) ne fonctionnera pas.", "Privacy_Accessibility")
    #else
    return droitsItem("accessibilite", "Accessibilité", "na", "Indisponible hors macOS.", "Privacy_Accessibility")
    #endif
}

private func droitsScreen() -> [String: Any] {
    #if os(macOS)
    let granted: Bool = CGPreflightScreenCaptureAccess()
    if granted { return droitsItem("ecran", "Enregistrement de l'écran", "ok", "Nova peut lire l'écran à ta demande (Témoin).", "Privacy_ScreenCapture") }
    return droitsItem("ecran", "Enregistrement de l'écran", "no", "Non accordé : « Analyser l'écran actif » ne fonctionnera pas.", "Privacy_ScreenCapture")
    #else
    return droitsItem("ecran", "Enregistrement de l'écran", "na", "Indisponible hors macOS.", "Privacy_ScreenCapture")
    #endif
}

private func droitsMicro() -> [String: Any] {
    #if canImport(AVFoundation) && os(macOS)
    let st: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    switch st {
    case .authorized:
        return droitsItem("micro", "Microphone", "ok", "Accordé.", "Privacy_Microphone")
    case .denied:
        return droitsItem("micro", "Microphone", "no", "Refusé : la dictée vocale ne fonctionnera pas.", "Privacy_Microphone")
    case .restricted:
        return droitsItem("micro", "Microphone", "no", "Restreint par une règle du système.", "Privacy_Microphone")
    case .notDetermined:
        return droitsItem("micro", "Microphone", "na", "Jamais demandé : macOS le proposera au premier usage de la voix.", "Privacy_Microphone")
    @unknown default:
        return droitsItem("micro", "Microphone", "na", "État inconnu.", "Privacy_Microphone")
    }
    #else
    return droitsItem("micro", "Microphone", "na", "Indisponible.", "Privacy_Microphone")
    #endif
}

#if canImport(EventKit) && os(macOS)
private func droitsEventKit(_ type: EKEntityType, _ id: String, _ label: String, _ pane: String) -> [String: Any] {
    let st: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: type)
    if #available(macOS 14.0, *) {
        if st == .fullAccess { return droitsItem(id, label, "ok", "Accès complet accordé.", pane) }
        if st == .writeOnly { return droitsItem(id, label, "no", "Écriture seule : Nova ne peut pas lire les éléments existants.", pane) }
    } else {
        if st == .authorized { return droitsItem(id, label, "ok", "Accès accordé.", pane) }
    }
    if st == .denied { return droitsItem(id, label, "no", "Refusé : Nova passe par AppleScript (plus lent).", pane) }
    if st == .restricted { return droitsItem(id, label, "no", "Restreint par une règle du système.", pane) }
    if st == .notDetermined { return droitsItem(id, label, "na", "Jamais demandé.", pane) }
    return droitsItem(id, label, "na", "État inconnu.", pane)
}
#endif

private func droitsCalendars() -> [[String: Any]] {
    #if canImport(EventKit) && os(macOS)
    let a: [String: Any] = droitsEventKit(.event, "calendrier", "Calendrier", "Privacy_Calendars")
    let b: [String: Any] = droitsEventKit(.reminder, "rappels", "Rappels", "Privacy_Reminders")
    return [a, b]
    #else
    return [droitsItem("calendrier", "Calendrier", "na", "Indisponible.", "Privacy_Calendars"),
            droitsItem("rappels", "Rappels", "na", "Indisponible.", "Privacy_Reminders")]
    #endif
}

/// Automatisation (Apple Events) d'une app : jamais lancée, jamais de fenêtre de consentement.
private func droitsAutomation(_ name: String, _ bundleIDs: [String]) -> [String: Any] {
    let id: String = "auto-" + name.lowercased().replacingOccurrences(of: " ", with: "-")
    let label: String = "Automatisation · " + name
    let pane: String = "Privacy_Automation"
    #if os(macOS)
    var runningID: String? = nil
    let apps: [NSRunningApplication] = NSWorkspace.shared.runningApplications
    for bid in bundleIDs {
        if apps.contains(where: { (a: NSRunningApplication) -> Bool in a.bundleIdentifier == bid }) { runningID = bid; break }
    }
    guard let bid: String = runningID else {
        return droitsItem(id, label, "na", "App non lancée : non vérifiée (Nova ne la lance pas).", pane)
    }
    // 1) Question posée à macOS sans jamais afficher la demande d'autorisation.
    let wild: UInt32 = 0x2A2A2A2A   // '****' (typeWildCard)
    let target: NSAppleEventDescriptor = NSAppleEventDescriptor(bundleIdentifier: bid)
    let status: OSStatus = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(wild), AEEventID(wild), false)
    if status == -1743 { return droitsItem(id, label, "no", "Refusé (Réglages > Confidentialité > Automatisation).", pane) }
    if status == -1744 { return droitsItem(id, label, "na", "Jamais demandé : aucune ligne n'existe encore dans Réglages > Automatisation. « Demander l'accès » déclenche la vraie demande macOS.", pane) }
    if status == -600 { return droitsItem(id, label, "na", "App non lancée : non vérifiée.", pane) }
    // 2) Confirmation réelle par un AppleScript inoffensif (l'app tourne déjà ; rien n'est affiché).
    var lines: [String] = []
    lines.append("try")
    lines.append("with timeout of 6 seconds")
    lines.append("tell application id \"" + bid + "\" to get name")
    lines.append("end timeout")
    lines.append("return \"OK\"")
    lines.append("on error m number n")
    lines.append("return \"ERR \" & n & \" \" & m")
    lines.append("end try")
    let script: String = lines.joined(separator: "\n")
    let result: (Int32, String) = runProcess("/usr/bin/osascript", ["-e", script], timeout: 8)
    let out: String = result.1.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.0 == 124 { return droitsItem(id, label, "na", "L'app n'a pas répondu à temps (8 s).", pane) }
    if out.hasPrefix("OK") { return droitsItem(id, label, "ok", "Accordé (test AppleScript réussi).", pane) }
    if out.contains("-1743") || out.localizedCaseInsensitiveContains("not authorized") || out.localizedCaseInsensitiveContains("pas autoris") {
        return droitsItem(id, label, "no", "Refusé (Réglages > Confidentialité > Automatisation).", pane)
    }
    if out.contains("-600") { return droitsItem(id, label, "na", "App non lancée : non vérifiée.", pane) }
    let brief: String = String(out.prefix(120))
    return droitsItem(id, label, "na", "Résultat indéterminé : " + (brief.isEmpty ? "aucune réponse" : brief), pane)
    #else
    return droitsItem(id, label, "na", "Indisponible hors macOS.", pane)
    #endif
}

private let droitsAutomationTargets: [(String, [String])] = [
    ("Mail", ["com.apple.mail"]),
    ("Microsoft Outlook", ["com.microsoft.Outlook"]),
    ("Microsoft Teams", ["com.microsoft.teams2", "com.microsoft.teams"]),
    ("Calendar", ["com.apple.iCal"]),
    ("Reminders", ["com.apple.reminders"]),
    ("System Events", ["com.apple.systemevents"]),
    ("Finder", ["com.apple.finder"]),
]

private func droitsCompute() -> [[String: Any]] {
    var out: [[String: Any]] = []
    out.append(droitsFullDisk())
    out.append(droitsAccessibility())
    out.append(droitsScreen())
    out.append(droitsMicro())
    out.append(contentsOf: droitsCalendars())
    for t in droitsAutomationTargets { out.append(droitsAutomation(t.0, t.1)) }
    return out
}

extension NovaApp {
    func droitsRoutes() {
        let s: HTTPServer = server
        s.on("GET", "/api/droits") { req, res in
            let cache: DroitsCache = DroitsCache.shared
            let force: Bool = (req.query["force"] == "1")
            cache.lock.lock()
            let age: TimeInterval = Date().timeIntervalSince(cache.at)
            // « Revérifier » (force=1) reste limité à un test toutes les 5 s ; sinon cache de 60 s.
            let fresh: Bool = force ? (age < 5) : (age < 60)
            if fresh && !cache.items.isEmpty {
                let items: [[String: Any]] = cache.items
                cache.lock.unlock()
                let body: [String: Any] = ["items": items, "cached": true, "age": Int(age)]
                res.json(body)
                return
            }
            cache.lock.unlock()
            let items: [[String: Any]] = droitsCompute()
            cache.lock.lock()
            cache.items = items
            cache.at = Date()
            cache.lock.unlock()
            let body: [String: Any] = ["items": items, "cached": false, "age": 0, "at": nowISO()]
            res.json(body)
        }
        s.on("POST", "/api/droits/open") { req, res in
            let pane: String = (req.json["pane"] as? String) ?? ""
            let allowed: CharacterSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:?_-=&")
            let clean: Bool = pane.unicodeScalars.allSatisfy { (u: Unicode.Scalar) -> Bool in allowed.contains(u) }
            guard pane.hasPrefix("x-apple.systempreferences:"), pane.count < 200, clean else {
                let err: [String: Any] = ["ok": false, "error": "réglage non autorisé"]
                res.json(err, status: 400)
                return
            }
            let r: (Int32, String) = runProcess("/usr/bin/open", [pane], timeout: 5)
            // L'utilisateur va peut-être changer un droit : on invalide le cache.
            let cache: DroitsCache = DroitsCache.shared
            cache.lock.lock(); cache.at = Date.distantPast; cache.lock.unlock()
            let done: Bool = (r.0 == 0)
            let body: [String: Any] = ["ok": done]
            res.json(body)
        }
        // DIAG-CALENDRIER : demande d'accès EventKit — déclenchée UNIQUEMENT par un clic
        // dans la page Droits (seul déclencheur légitime, cf. doctrine en tête de fichier).
        // Réponse immédiate : la boîte système s'affiche en asynchrone, la page revérifie
        // ensuite via GET /api/droits (le cache est invalidé à la fin de la demande).
        s.on("POST", "/api/droits/request-calendar") { req, res in
            #if canImport(EventKit) && os(macOS)
            Tools.ekRequestAccess(.event) { _ in
                let cache: DroitsCache = DroitsCache.shared
                cache.lock.lock(); cache.at = Date.distantPast; cache.lock.unlock()
            }
            res.json(["ok": true, "state": "demande affichée"])
            #else
            res.json(["ok": false, "error": "EventKit indisponible sur cette plateforme"], status: 400)
            #endif
        }
        // Automatisation : la ligne d'une app cible n'apparaît dans Réglages > Confidentialité >
        // Automatisation qu'après une VRAIE demande. Le contrôle d'état ci-dessus interroge
        // macOS avec askUserIfNeeded=false (aucune fenêtre) ; seul ce clic déclenche la demande.
        s.on("POST", "/api/droits/request-automation") { req, res in
            let id: String = (req.json["id"] as? String) ?? ""
            #if os(macOS)
            let match: (String, [String])? = droitsAutomationTargets.first(where: { t -> Bool in
                "auto-" + t.0.lowercased().replacingOccurrences(of: " ", with: "-") == id
            })
            guard let target: (String, [String]) = match else {
                res.json(["ok": false, "error": "cible d'automatisation inconnue"], status: 400)
                return
            }
            let running: [NSRunningApplication] = NSWorkspace.shared.runningApplications
            let bid: String? = target.1.first(where: { b -> Bool in
                running.contains(where: { (a: NSRunningApplication) -> Bool in a.bundleIdentifier == b })
            }) ?? target.1.first
            guard let bundleID: String = bid else {
                res.json(["ok": false, "error": "aucun identifiant cible"], status: 400)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let wild: UInt32 = 0x2A2A2A2A
                let desc: NSAppleEventDescriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
                _ = AEDeterminePermissionToAutomateTarget(desc.aeDesc, AEEventClass(wild), AEEventID(wild), true)
                let cache: DroitsCache = DroitsCache.shared
                cache.lock.lock(); cache.at = Date.distantPast; cache.lock.unlock()
            }
            res.json(["ok": true, "state": "demande affichée"])
            #else
            res.json(["ok": false, "error": "indisponible hors macOS"], status: 400)
            #endif
        }
        s.on("POST", "/api/droits/request-reminders") { req, res in
            #if canImport(EventKit) && os(macOS)
            Tools.ekRequestAccess(.reminder) { _ in
                let cache: DroitsCache = DroitsCache.shared
                cache.lock.lock(); cache.at = Date.distantPast; cache.lock.unlock()
            }
            res.json(["ok": true, "state": "demande affichée"])
            #else
            res.json(["ok": false, "error": "EventKit indisponible sur cette plateforme"], status: 400)
            #endif
        }
    }
}
