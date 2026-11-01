import Foundation

/// Contrôle des écrans et des apps demandé et confirmé par l'utilisateur (System Events, screencapture).
/// Mots de passe, envoi de messages et paiements : jamais (garde-fous de `Tools.gate`).
extension Tools {
    static func ui(_ raw: String, why: String) -> String {
        #if os(macOS)
        let (cmd, block) = gate(raw, why: why, kind: "action d'écran"); if let b = block { return b }
        let parts = cmd.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        let act = (parts.first ?? "").lowercased()
        func q(_ t: String) -> String { t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        func se(_ body: String) -> String {
            let r = osa("tell application \"System Events\"\n\(body)\nend tell", timeout: 30)
            if r.out.isEmpty { return r.ok ? "Fait." : "Échec." }
            return String(r.out.prefix(5000)) + (r.ok ? "" : "\n(Accessibilité : Réglages Système › Confidentialité › Accessibilité › activer Nova.)")
        }
        switch act {
        case "screens":
            let (_, o) = runProcess("/bin/sh", ["-c", "system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Resolution|Main Display|Display Type|^        [A-Za-z]' | head -30"], timeout: 15)
            return o.isEmpty ? "Écrans : information indisponible." : o
        case "windows":
            return se("set out to \"\"\nrepeat with p in (every process whose background only is false)\nset ws to \"\"\ntry\nrepeat with w in (every window of p)\nset ws to ws & (name of w) & \" ; \"\nend repeat\nend try\nset out to out & (name of p) & \" : \" & ws & linefeed\nend repeat\nreturn out")
        case "screenshot":
            let dir = NSHomeDirectory() + "/Pictures/Nova-captures"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let f = dir + "/capture-\(Int(Date().timeIntervalSince1970)).png"
            let (c, o) = runProcess("/usr/sbin/screencapture", ["-x", f], timeout: 15)
            #if canImport(AppKit) && canImport(ScreenCaptureKit) && canImport(Vision)
            if c == 0 && FileManager.default.fileExists(atPath: f) { return "Capture enregistrée : \(f)\n" + Temoin.ocrFile(f) }
            #endif
            return c == 0 && FileManager.default.fileExists(atPath: f) ? "Capture enregistrée : \(f)" : "Capture impossible (\(o)) — Réglages Système › Confidentialité › Enregistrement de l'écran › activer Nova."
        case "focus":
            guard parts.count > 1, !parts[1].isEmpty else { return "focus|NomApp" }
            let r = osa("tell application \"\(q(parts[1]))\" to activate", timeout: 20)
            return r.ok ? "App active : \(parts[1])." : r.out
        case "click":
            guard parts.count > 2, let x = Int(parts[1]), let y = Int(parts[2]) else { return "click|x|y (coordonnées en points)" }
            return se("click at {\(x), \(y)}")
        case "type":
            guard parts.count > 1 else { return "type|texte" }
            return se("keystroke \"\(q(parts.dropFirst().joined(separator: "|")))\"")
        case "key":
            guard parts.count > 1 else { return "key|cmd+shift+g" }
            var mods: [String] = []; var key = ""
            for t in parts[1].lowercased().split(separator: "+").map(String.init) {
                switch t {
                case "cmd", "command": mods.append("command down")
                case "shift": mods.append("shift down")
                case "alt", "option", "opt": mods.append("option down")
                case "ctrl", "control": mods.append("control down")
                default: key = t
                }
            }
            let codes: [String: Int] = ["return": 36, "enter": 76, "tab": 48, "esc": 53, "escape": 53, "space": 49, "delete": 51, "left": 123, "right": 124, "down": 125, "up": 126]
            let using = mods.isEmpty ? "" : " using {\(mods.joined(separator: ", "))}"
            if let c = codes[key] { return se("key code \(c)\(using)") }
            return se("keystroke \"\(q(key))\"\(using)")
        case "menu":
            guard parts.count > 3 else { return "menu|App|Menu|Élément" }
            return se("tell process \"\(q(parts[1]))\" to click menu item \"\(q(parts[3]))\" of menu 1 of menu bar item \"\(q(parts[2]))\" of menu bar 1")
        case "nova":
            return Tools.appHook?("go \(parts.count > 1 ? parts[1] : "")") ?? "Commande interne indisponible."
        default:
            return "ui : actions = screens · windows · screenshot · focus|App · click|x|y · type|texte · key|combo · menu|App|Menu|Élément · nova|onglet — en arrière-plan, préfère l'outil app : ax-lire / ax-chercher / ax-cliquer / ax-saisir / ax-menu (Accessibilité, app jamais activée)"
        }
        #else
        return "indisponible hors macOS"
        #endif
    }
}
