import Foundation

/// Données du Mac en lecture : Notes, Contacts, Spotlight, Raccourcis, presse-papiers.
/// Rien n'est envoyé ni modifié, sauf `shortcut|run|nom` (passe par `Tools.gate`).
extension Tools {
    static func macData(_ name: String, _ raw: String, why: String) -> String {
        #if os(macOS)
        let arg = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func q(_ t: String) -> String { t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        switch name {
        case "notes":
            let filter = arg.isEmpty ? "" : " whose name contains \"\(q(arg))\" or plaintext contains \"\(q(arg))\""
            let r = osa("""
            set out to ""
            tell application "Notes"
              set ns to every note\(filter)
              set k to 0
              repeat with n in ns
                set k to k + 1
                if k > 12 then exit repeat
                set b to plaintext of n
                if (length of b) > 400 then set b to (text 1 thru 400 of b)
                set out to out & "• " & (name of n) & " — " & b & linefeed & linefeed
              end repeat
            end tell
            return out
            """, timeout: 25)
            return r.ok ? (r.out.isEmpty ? "Aucune note trouvée." : "Notes (Notes.app) :\n" + r.out) : "Notes indisponibles : " + r.out
        case "contacts":
            guard !arg.isEmpty else { return "contacts : donne un nom à chercher." }
            let r = osa("""
            set out to ""
            tell application "Contacts"
              set ps to (every person whose name contains "\(q(arg))")
              set k to 0
              repeat with p in ps
                set k to k + 1
                if k > 8 then exit repeat
                set line_ to name of p
                try
                  set line_ to line_ & " | tél: " & (value of first phone of p)
                end try
                try
                  set line_ to line_ & " | mail: " & (value of first email of p)
                end try
                try
                  set line_ to line_ & " | " & (organization of p)
                end try
                set out to out & line_ & linefeed
              end repeat
            end tell
            return out
            """, timeout: 40)
            return r.ok ? (r.out.isEmpty ? "Aucun contact « \(arg) »." : "Contacts :\n" + r.out) : "Contacts indisponibles : " + r.out
        case "find":
            guard !arg.isEmpty else { return "find : donne un mot ou un nom de fichier." }
            let (_, o) = runProcess("/usr/bin/mdfind", ["-onlyin", NSHomeDirectory(), arg], timeout: 20)
            let lines = o.split(separator: "\n").prefix(25).map(String.init)
            return lines.isEmpty ? "Aucun résultat Spotlight pour « \(arg) »." : "Spotlight (25 premiers) :\n" + lines.joined(separator: "\n")
        case "shortcut":
            let p = arg.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if arg.isEmpty || p[0].lowercased() == "list" {
                let (_, o) = runProcess("/usr/bin/shortcuts", ["list"], timeout: 15)
                return o.isEmpty ? "Aucun raccourci." : "Raccourcis Apple :\n" + o
            }
            if p[0].lowercased() == "run", p.count > 1, !p[1].isEmpty {
                let (cmd, block) = gate(p[1], why: why, kind: "raccourci Apple"); if let b = block { return b }
                let (c, o) = runProcess("/usr/bin/shortcuts", ["run", cmd], timeout: 60)
                return c == 0 ? (o.isEmpty ? "Raccourci exécuté." : o) : "Échec du raccourci : \(o)"
            }
            return "shortcut : « list » ou « run|NomDuRaccourci »."
        case "today":   // Ta journée sur le Mac : fichiers créés ou modifiés aujourd'hui (hors Bibliothèque et caches)
            let (_, o) = runProcess("/usr/bin/mdfind", ["-onlyin", NSHomeDirectory(), "kMDItemFSContentChangeDate >= $time.today"], timeout: 25)
            let skip = ["/Library/", "/.", "/node_modules/", "/build/", "/_tmp", "/.build/"]
            let l = o.split(separator: "\n").map(String.init).filter { p in !skip.contains { p.contains($0) } }
            let home = NSHomeDirectory()
            let short = l.prefix(40).map { $0.replacingOccurrences(of: home, with: "~") }
            return short.isEmpty ? "Aucun fichier modifié aujourd'hui (Spotlight)." : "Fichiers touchés aujourd'hui (Spotlight, \(l.count) au total, 40 premiers) :\n" + short.joined(separator: "\n")
        case "clipboard":
            let (_, o) = runProcess("/usr/bin/pbpaste", [], timeout: 5)
            return o.isEmpty ? "Presse-papiers vide." : "Presse-papiers :\n" + String(o.prefix(3000))
        default:
            return "outil inconnu"
        }
        #else
        return "indisponible hors macOS"
        #endif
    }
}
