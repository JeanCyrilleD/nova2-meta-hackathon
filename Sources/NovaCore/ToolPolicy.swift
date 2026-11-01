import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// WP5 (31/10/2026) — DURCIR L'EXÉCUTION DES OUTILS.
//
// Ce fichier contient des ANALYSEURS et un lanceur borné, rien de plus :
//  - ShellLexer / ShellPolicy : lecture d'une commande zsh (sous-ensemble strict : guillemets, échappements,
//    séparateurs ; tout le reste — substitutions, redirections, groupes, motifs zsh — est « opaque »), puis
//    validation des ARGUMENTS utilitaire par utilitaire (find -exec/-execdir/-ok/-okdir/-delete/-fprint…,
//    sed -i, awk system(), tar --to-command, rsync -e, git -c, xargs, env, open -a, interpréteurs…).
//  - NetPolicy : hôtes et adresses IP analysés EXACTEMENT (URLComponents, inet_aton, inet_pton), jamais par préfixe.
//  - PathPolicy : liens symboliques résolus (realpath) et confinement dans des racines permises.
//  - ToolCapability / ToolCapabilities / RunScope : capacités séparées (lecture, écriture, réseau, exécution,
//    écran, communication), liées à UN run — aucune autorisation globale héritée.
//  - BoundedProcess : sous-processus à exécutable de chemin fixe, durée, taille de sortie et annulation bornées,
//    stderr capturé, assaini et borné.
//  - SafeHTTP : GET dont chaque redirection est revalidée.
//
// CE N'EST PAS UN BAC À SABLE. Une commande acceptée s'exécute avec tous les droits de l'utilisateur.
// L'analyse ne fait que décider « lecture sûre / à confirmer / refus » ; ce qu'elle ne sait pas lire est opaque
// et part en confirmation. Le seul vrai bac à sable de Nova est sandbox-exec (Forge).

// MARK: - Capacités

/// Capacités séparées d'un run. Un outil n'est exécuté que si TOUTES ses capacités requises sont accordées au run.
public enum ToolCapability: String, CaseIterable {
    case fileRead = "lecture_fichiers"
    case fileWrite = "ecriture_fichiers"
    case network = "reseau"
    case exec = "execution"
    case screen = "ecran"
    case communication = "communication"
}

public enum ToolCapabilities {
    public static let all: Set<ToolCapability> = Set(ToolCapability.allCases)
    /// Runs sans surveillance (Dots planifiés, appui d'un Dot, sous-agents) : ni exécution générique, ni écran, ni communication.
    public static let unattended: Set<ToolCapability> = [.fileRead, .fileWrite, .network]
    /// Relais (pilotes d'interface, président du Conseil) : tout sauf l'exécution générique (shell, AppleScript…).
    public static let relay: Set<ToolCapability> = all.subtracting([.exec])

    static func firstWord(_ a: String) -> String {
        String(a.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "|" }).first ?? "").lowercased()
    }

    /// Capacités requises par un appel d'outil. Un outil inconnu exige l'exécution (fermé par défaut).
    public static func required(tool: String, arg: String) -> Set<ToolCapability> {
        switch tool {
        case "web_search", "web_fetch", "flux_titres", "brvm_cours", "media":
            return [.network]
        case "mail_pj":
            return [.network, .fileRead, .fileWrite]
        case "read_file", "transcribe", "find", "notes", "contacts", "today", "clipboard", "recall", "know", "bibliotheque", "lire_fichier_bibliotheque",
             "mail_unread", "mail_week", "mail_corps", "teams_read", "calendar", "reminders", "system", "processes", "skill":
            return [.fileRead]
        case "nova_self":
            return firstWord(arg) == "set" ? [.fileWrite] : [.fileRead]
        case "write_file", "edit_file", "calendar_add", "reminder_add", "note_add", "remember", "draft_reply", "momo",
             "cafu_format_document", "cafu_format_email", "cafu_format_docx", "cafu_format_deck", "cafu_format_pdf", "cafu_format_table":
            return [.fileWrite]
        case "shell", "applescript", "shortcut", "forge_tool", "open":
            return [.exec]
        case "ui":
            return [.screen]
        case "formulaire":
            let v = firstWord(arg)
            if v == "lire" { return [.fileRead] }
            return v == "soumettre" ? [.screen, .communication] : [.screen]
        case "mail_envoyer", "mail_brouillon", "phone":
            return [.communication]
        case "ask_assistant", "nova_ui":
            return []
        case "app":
            let v = firstWord(arg)
            let pilotRead: Set<String> = ["ui-etat", "ui-lire", "page-etat", "page-lire", "page-messages", "page-absence", "ax-lire", "ax-chercher"]
            if (v.hasPrefix("page-") || v.hasPrefix("ui-") || v.hasPrefix("ax-")) && !pilotRead.contains(v) { return [.screen] }
            return []
        default:
            return [.exec]
        }
    }

    public static func isUnattendedActor(_ actor: String) -> Bool {
        actor.hasPrefix("Dot ") || actor == "Assistant (appui d'un Dot)" || actor.hasPrefix("Sous-agent")
    }
    /// Capacités par défaut d'un run selon son acteur (sans autorisation explicite du propriétaire).
    public static func defaults(actor: String) -> Set<ToolCapability> {
        if isUnattendedActor(actor) { return unattended }
        if actor.hasPrefix("Relais ") { return relay }
        return all
    }
    /// Noms d'outils compatibles avec un jeu de capacités (argument vide : forme la plus restrictive connue de l'outil).
    public static func permitted(_ names: [String], caps: Set<ToolCapability>) -> Set<String> {
        Set(names.filter { required(tool: $0, arg: "").isSubset(of: caps) })
    }
    /// Libellé lisible des capacités manquantes.
    public static func label(_ caps: Set<ToolCapability>) -> String {
        caps.map { $0.rawValue }.sorted().joined(separator: ", ")
    }
}

// MARK: - Portée d'un run

/// Autorisations liées à UN run (un passage d'agent). Rien n'est global : une fenêtre « autoriser 1 h » ou un
/// espace d'ingénierie accordé à un run meurt avec lui (ou à son échéance) et n'est hérité par aucun autre run.
public final class RunScope {
    public let id: String
    public let actor: String
    public let capabilities: Set<ToolCapability>
    public let cancel: () -> Bool
    public let started: Date = Date()
    private let lock = NSLock()
    private var freeUntil: Date = .distantPast
    private var engRoot: String? = nil
    private var engUntil: Date = .distantPast

    public init(id: String = String(UUID().uuidString.prefix(12)).lowercased(), actor: String, capabilities: Set<ToolCapability>, cancel: @escaping () -> Bool = { false }) {
        self.id = id; self.actor = actor; self.capabilities = capabilities; self.cancel = cancel
    }

    public func grantFreeWindow(minutes: Int, now: Date = Date()) {
        lock.lock(); freeUntil = now.addingTimeInterval(Double(max(0, min(minutes, 240))) * 60); lock.unlock()
    }
    public func freeWindowOpen(_ now: Date = Date()) -> Bool { lock.lock(); defer { lock.unlock() }; return now <= freeUntil }
    /// Espace d'ingénierie : racine RÉSOLUE (realpath) déjà validée par l'appelant, durée bornée (≤ 4 h).
    public func grantEngineering(root: String, minutes: Int, now: Date = Date()) {
        lock.lock(); engRoot = root; engUntil = now.addingTimeInterval(Double(max(1, min(minutes, 240))) * 60); lock.unlock()
    }
    public func engineeringRoot(_ now: Date = Date()) -> String? { lock.lock(); defer { lock.unlock() }; return now <= engUntil ? engRoot : nil }

    // Registre des runs vivants (pour lier une décision d'interface au run qui l'a demandée).
    final class Registry {
        let lock = NSLock()
        var live: [String: RunScope] = [:]
    }
    static let registry = Registry()
    public static func begin(_ s: RunScope) {
        registry.lock.lock()
        let old = Date().addingTimeInterval(-6 * 3600)
        registry.live = registry.live.filter { $0.value.started > old }
        registry.live[s.id] = s
        registry.lock.unlock()
    }
    public static func end(_ s: RunScope) { registry.lock.lock(); registry.live[s.id] = nil; registry.lock.unlock() }
    public static func find(_ id: String) -> RunScope? { registry.lock.lock(); defer { registry.lock.unlock() }; return registry.live[id] }

    static let threadKey = "nova.runScope"
    /// Portée du run qui exécute l'outil SUR CE FIL (posée par Agent.run autour de chaque appel d'outil).
    public static var current: RunScope? { Thread.current.threadDictionary[threadKey] as? RunScope }
    @discardableResult
    public static func with<T>(_ s: RunScope?, _ body: () -> T) -> T {
        let d = Thread.current.threadDictionary
        let prev = d[threadKey]
        if let s = s { d[threadKey] = s } else { d.removeObject(forKey: threadKey) }
        defer { if let p = prev { d[threadKey] = p } else { d.removeObject(forKey: threadKey) } }
        return body()
    }
}

// MARK: - Lexique zsh (sous-ensemble strict)

public struct ShellWord: Equatable {
    public var text: String
    public var globbed: Bool        // * ? [ non protégés
    public var expanded: Bool       // ~ ou $VAR développés
}
public struct ShellCommand: Equatable {
    public var words: [ShellWord]
    public var separator: String    // opérateur APRÈS la commande : ";", "|", "&&", "||", "&" ou ""
}
public struct ShellParse {
    public var commands: [ShellCommand] = []
    /// Constructions non analysées (substitution, redirection, groupe, arrière-plan…). Non vide => commande opaque.
    public var opaque: [String] = []
    public var devNullRedirects: Int = 0
}

public enum ShellLexer {
    /// Seules ces variables sont développées ; toute autre expansion rend la commande opaque.
    public static let expandableVars: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "SHELL"]

    static func isNameStart(_ c: Unicode.Scalar) -> Bool { (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || c == "_" }
    static func isNameChar(_ c: Unicode.Scalar) -> Bool { isNameStart(c) || (c >= "0" && c <= "9") }
    static func isBreak(_ c: Unicode.Scalar) -> Bool { " \t\n;|&<>()".unicodeScalars.contains(c) }

    public static func parse(_ cmd: String, env: [String: String] = [:]) -> ShellParse {
        let s: [Unicode.Scalar] = Array(cmd.unicodeScalars)
        var out = ShellParse()
        var words: [ShellWord] = []
        var cur = String.UnicodeScalarView()
        var inWord = false, globbed = false, expanded = false
        var i = 0

        func opaque(_ r: String) { if !out.opaque.contains(r) { out.opaque.append(r) } }
        func endWord() {
            if inWord { words.append(ShellWord(text: String(cur), globbed: globbed, expanded: expanded)) }
            cur = String.UnicodeScalarView(); inWord = false; globbed = false; expanded = false
        }
        func endCommand(_ sep: String) {
            endWord()
            if !words.isEmpty { out.commands.append(ShellCommand(words: words, separator: sep)) }
            else if sep != ";" && sep != "" { opaque("opérateur « \(sep) » sans commande") }
            words = []
        }
        /// s[j] == "$" ; renvoie l'index suivant.
        func readDollar(_ j: Int) -> Int {
            let n = j + 1
            guard n < s.count else { cur.append("$"); inWord = true; return n }
            let c = s[n]
            if c == "(" { opaque("substitution de commande $(…)"); return n + 1 }
            if c == "{" { opaque("expansion ${…}"); return n + 1 }
            if c == "'" || c == "\"" { opaque("chaîne $'…'"); return n + 1 }
            if c == "[" { opaque("expansion arithmétique $[…]"); return n + 1 }
            if isNameStart(c) {
                var k = n; var name = String.UnicodeScalarView()
                while k < s.count, isNameChar(s[k]) { name.append(s[k]); k += 1 }
                let nm = String(name)
                if expandableVars.contains(nm), let v = env[nm] { cur.append(contentsOf: v.unicodeScalars); expanded = true }
                else { opaque("variable $" + nm); cur.append("$"); cur.append(contentsOf: name) }
                inWord = true
                return k
            }
            if c == " " || c == "\t" || c == "\n" || c == "\"" { cur.append("$"); inWord = true; return n }
            opaque("paramètre spécial $" + String(Character(c)))
            return n + 1
        }

        while i < s.count {
            let c = s[i]
            switch c {
            case " ", "\t":
                endWord(); i += 1
            case "\n", ";":
                endCommand(";"); i += 1
            case "\\":
                if i + 1 < s.count {
                    if s[i + 1] != "\n" { cur.append(s[i + 1]); inWord = true }
                    i += 2
                } else { i += 1 }
            case "'":
                var k = i + 1; var closed = false
                while k < s.count { if s[k] == "'" { closed = true; break }; cur.append(s[k]); k += 1 }
                if !closed { opaque("guillemet non fermé") }
                inWord = true; i = k + 1
            case "\"":
                var k = i + 1; var closed = false
                while k < s.count {
                    let d = s[k]
                    if d == "\"" { closed = true; break }
                    if d == "\\", k + 1 < s.count {
                        let e = s[k + 1]
                        if e == "$" || e == "`" || e == "\"" || e == "\\" { cur.append(e); k += 2; continue }
                        if e == "\n" { k += 2; continue }
                        cur.append(d); k += 1; continue
                    }
                    if d == "`" { opaque("substitution de commande `…`"); k += 1; continue }
                    if d == "$" { k = readDollar(k); continue }
                    cur.append(d); k += 1
                }
                if !closed { opaque("guillemet non fermé") }
                inWord = true; i = k + 1
            case "`":
                opaque("substitution de commande `…`"); i += 1
            case "$":
                i = readDollar(i)
            case "|":
                if i + 1 < s.count, s[i + 1] == "|" { endCommand("||"); i += 2 }
                else if i + 1 < s.count, s[i + 1] == "&" { opaque("redirection |&"); endCommand("|"); i += 2 }
                else { endCommand("|"); i += 1 }
            case "&":
                if i + 1 < s.count, s[i + 1] == "&" { endCommand("&&"); i += 2 }
                else { opaque("arrière-plan ou redirection &"); endCommand("&"); i += 1 }
            case "<":
                opaque("redirection d'entrée <"); endWord(); i += 1
            case ">":
                // Seules sont lues : [1|2]>/dev/null, [1|2]>>/dev/null, 2>&1, 1>&2. Tout le reste est opaque.
                let fd = String(cur)
                let isFd = inWord && (fd == "1" || fd == "2")
                if isFd { cur = String.UnicodeScalarView(); inWord = false; globbed = false; expanded = false } else { endWord() }
                var k = i + 1
                if k < s.count, s[k] == ">" { k += 1 }
                if k < s.count, s[k] == "&" {
                    if k + 1 < s.count, s[k + 1] == "1" || s[k + 1] == "2", k + 2 >= s.count || isBreak(s[k + 2]) {
                        out.devNullRedirects += 1; i = k + 2; continue
                    }
                    opaque("redirection >&"); i = k + 1; continue
                }
                if k < s.count, s[k] == "(" { opaque("substitution de processus >(…)"); i = k; continue }
                while k < s.count, s[k] == " " || s[k] == "\t" { k += 1 }
                var target = String.UnicodeScalarView()
                while k < s.count, !isBreak(s[k]), s[k] != "'", s[k] != "\"", s[k] != "$", s[k] != "`", s[k] != "\\" { target.append(s[k]); k += 1 }
                if String(target) == "/dev/null", k >= s.count || isBreak(s[k]) { out.devNullRedirects += 1 }
                else { opaque("redirection vers un fichier >") }
                i = k
            case "(", ")", "{", "}":
                opaque("groupe, sous-shell ou motif zsh ( ) { }"); endWord(); i += 1
            case "#" where !inWord:
                opaque("commentaire #")
                var k = i; while k < s.count, s[k] != "\n" { k += 1 }
                i = k
            case "*", "?", "[":
                cur.append(c); inWord = true; globbed = true; i += 1
            case "~" where !inWord:
                let next: Unicode.Scalar? = i + 1 < s.count ? s[i + 1] : nil
                if next == nil || next == "/" || isBreak(next!) {
                    if let h = env["HOME"] { cur.append(contentsOf: h.unicodeScalars); expanded = true } else { cur.append("~") }
                } else { opaque("expansion ~utilisateur"); cur.append("~") }
                inWord = true; i += 1
            case "=" where !inWord:
                opaque("expansion =commande"); cur.append(c); inWord = true; i += 1
            default:
                if c.value < 0x20 || c.value == 0x7F { opaque("caractère de contrôle"); endWord(); i += 1; continue }
                cur.append(c); inWord = true; i += 1
            }
        }
        endCommand("")
        if let last = out.commands.last, ["|", "&&", "||"].contains(last.separator) { out.opaque.append("opérateur en fin de commande") }
        return out
    }

    /// Texte « déguillemeté » (mots réels, tels que le shell les verrait) : c'est lui que les filtres de texte doivent lire,
    /// pour qu'un `cu''rl`, `s\endmail` ou `~/.s"s"h` ne passe plus à côté d'eux.
    public static func normalized(_ p: ShellParse) -> String {
        p.commands.map { c in c.words.map { $0.text }.joined(separator: " ") + (c.separator.isEmpty ? "" : " " + c.separator) }.joined(separator: " ")
    }
}

// MARK: - Analyse des commandes et de leurs arguments

public struct ShellAssessment {
    public var parse: ShellParse
    public var normalized: String
    /// Toutes les commandes sont de la liste de lecture avec des arguments validés, et rien n'est opaque.
    public var readOnly: Bool = false
    /// Exécution dont l'effet n'est pas lisible dans la commande (interpréteur, enveloppe, find -exec, awk system()…).
    public var hiddenExec: [String] = []
    /// Effacements repérés par les arguments (rm, find -delete…).
    public var destructive: [String] = []
    public var effects: Set<ToolCapability> = []
    /// Chemins sensibles (après développement, glob et résolution des liens symboliques).
    public var sensitive: [String] = []
    /// Chemins hors de la racine demandée (espace d'ingénierie).
    public var outsideRoot: [String] = []
    /// Commande unique de lecture exécutable SANS shell : exécutable de chemin fixe + arguments déjà développés.
    public var argv: [String]? = nil
    public var commandNames: [String] = []
    public var analysable: Bool { parse.opaque.isEmpty && !parse.commands.isEmpty }
    /// Ni opaque ni exécution cachée : la commande peut être jugée sur ce qu'on lit.
    public var transparent: Bool { analysable && hiddenExec.isEmpty }
}

public enum ShellPolicy {
    /// Utilitaires de LECTURE avec leur exécutable de chemin fixe (macOS). Pas de `open` (lance des apps et des scripts),
    /// pas de `screencapture` (contrôle d'écran) : ils ont leurs outils typés.
    public static let fixedPaths: [String: String] = [
        "ls": "/bin/ls", "pwd": "/bin/pwd", "date": "/bin/date", "cal": "/usr/bin/cal", "whoami": "/usr/bin/whoami", "hostname": "/bin/hostname",
        "uname": "/usr/bin/uname", "sw_vers": "/usr/bin/sw_vers", "uptime": "/usr/bin/uptime", "df": "/bin/df", "du": "/usr/bin/du", "echo": "/bin/echo",
        "cat": "/bin/cat", "head": "/usr/bin/head", "tail": "/usr/bin/tail", "wc": "/usr/bin/wc", "sort": "/usr/bin/sort", "grep": "/usr/bin/grep",
        "egrep": "/usr/bin/egrep", "fgrep": "/usr/bin/fgrep", "find": "/usr/bin/find", "mdfind": "/usr/bin/mdfind", "mdls": "/usr/bin/mdls",
        "stat": "/usr/bin/stat", "file": "/usr/bin/file", "which": "/usr/bin/which", "ps": "/bin/ps", "top": "/usr/bin/top", "vm_stat": "/usr/bin/vm_stat",
        "system_profiler": "/usr/sbin/system_profiler", "ioreg": "/usr/sbin/ioreg", "pmset": "/usr/bin/pmset", "basename": "/usr/bin/basename",
        "dirname": "/usr/bin/dirname", "tr": "/usr/bin/tr", "cut": "/usr/bin/cut", "defaults": "/usr/bin/defaults", "ifconfig": "/sbin/ifconfig",
        "networksetup": "/usr/sbin/networksetup", "diff": "/usr/bin/diff", "lsof": "/usr/sbin/lsof", "launchctl": "/bin/launchctl",
        "say": "/usr/bin/say", "afplay": "/usr/bin/afplay", "awk": "/usr/bin/awk",
    ]
    static let systemBinDirs: [String] = ["/bin/", "/usr/bin/", "/sbin/", "/usr/sbin/", "/opt/homebrew/bin/", "/usr/local/bin/"]
    static let interpreters: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "source", ".", "eval",
        "python", "python2", "python3", "perl", "ruby", "node", "php", "lua", "rscript", "swift", "deno", "bun", "tclsh", "expect", "osascript",
        "pwsh", "java", "jshell", "irb", "groovy", "osacompile", "automator", "shortcuts", "lldb", "gdb", "jsc"]
    static let wrappers: Set<String> = ["env", "nice", "nohup", "time", "timeout", "gtimeout", "command", "builtin", "exec", "caffeinate", "arch", "stdbuf",
        "unbuffer", "sudo", "doas", "su", "script", "watch", "ionice", "chroot", "flock", "nsenter", "dtruss", "strace", "xargs", "parallel", "noglob", "nocorrect"]
    static let buildTools: Set<String> = ["make", "gmake", "npm", "npx", "yarn", "pnpm", "pip", "pip3", "pipx", "uv", "poetry", "conda", "cargo", "go",
        "gradle", "mvn", "cmake", "ninja", "xcodebuild", "swiftc", "clang", "gcc", "cc", "brew", "gem", "bundle", "pod", "docker", "kubectl", "terraform", "ansible"]
    static let shellStateBuiltins: Set<String> = ["export", "unset", "set", "alias", "unalias", "setopt", "unsetopt", "typeset", "declare", "local", "readonly",
        "trap", "emulate", "autoload", "zmodload", "fc", "functions", "hash", "rehash", "enable", "disable", "bindkey", "zle", "disown", "bg", "fg",
        "jobs", "wait", "zstyle", "zparseopts", "compdef", "r"]
    static let harmlessBuiltins: Set<String> = ["true", "false", ":", "test", "[", "[[", "printf", "print", "cd", "pushd", "popd", "exit", "return", "type", "whence"]
    static let writers: Set<String> = ["cp", "mv", "ln", "mkdir", "touch", "install", "ditto", "chmod", "chown", "chgrp", "chflags", "xattr", "tee", "dd",
        "truncate", "patch", "unzip", "zip", "gzip", "gunzip", "bzip2", "xz", "split", "csplit", "mktemp", "rename", "setfile", "pbcopy", "uniq", "iconv", "sips", "textutil", "plutil"]
    static let deleters: Set<String> = ["rm", "rmdir", "unlink", "srm", "shred"]
    static let netTools: Set<String> = ["nc", "ncat", "netcat", "telnet", "ftp", "socat", "aria2c", "http", "https", "xh"]
    static let mailers: Set<String> = ["mail", "mailx", "sendmail", "msmtp", "mutt", "swaks"]
    static let openExecExt: Set<String> = ["app", "command", "sh", "tool", "terminal", "workflow", "pkg", "mpkg", "dmg", "scpt", "scptd", "applescript",
        "py", "jar", "zsh", "bash", "action", "prefpane", "osax", "kext", "plugin", "bundle", "shortcut", "fileloc", "inetloc", "webloc"]

    struct Info {
        var name: String = ""
        var readOnly = false
        var hiddenExec: [String] = []
        var destructive: [String] = []
        var effects: Set<ToolCapability> = []
        mutating func merge(_ o: Info) {
            hiddenExec += o.hiddenExec; destructive += o.destructive; effects.formUnion(o.effects)
        }
    }

    static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: []) }
    static let assignRx = rx(#"^[A-Za-z_][A-Za-z0-9_]*="#)
    static let ifaceRx = rx(#"^[a-z]+[0-9]*$"#)
    // sed : commande e (exécute) / w,W (écrit), y compris en drapeau de substitution s///e, s///w.
    static let sedExecRx = rx(#"(^|[;\n{}])\s*([0-9]+|\$|/[^/]*/)?(,([0-9]+|\$|/[^/]*/))?\s*!?\s*e(\s|;|$)|s(.)((?!\6).)*\6((?!\6).)*\6[gpIiMm0-9]*e"#)
    static let sedWriteRx = rx(#"(^|[;\n{}])\s*([0-9]+|\$|/[^/]*/)?(,([0-9]+|\$|/[^/]*/))?\s*!?\s*[wW]\s|s(.)((?!\5).)*\5((?!\5).)*\5[gpIiMm0-9]*w"#)
    static func m(_ r: NSRegularExpression, _ t: String) -> Bool { r.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil }

    /// Analyse une commande shell. `sensitive` = filtre des chemins sensibles de Nova (Tools.isSensitivePath).
    public static func assess(_ cmd: String, home: String, cwd: String? = nil, root: String? = nil, env extra: [String: String] = [:],
                              sensitive: (String) -> Bool = { _ in false }) -> ShellAssessment {
        var env: [String: String] = ["HOME": home, "SHELL": "/bin/zsh"]
        let pe = ProcessInfo.processInfo.environment
        env["USER"] = pe["USER"] ?? NSUserName()
        env["LOGNAME"] = pe["LOGNAME"] ?? NSUserName()
        env["TMPDIR"] = pe["TMPDIR"] ?? NSTemporaryDirectory()
        for (k, v) in extra { env[k] = v }
        let p = ShellLexer.parse(cmd, env: env)
        var a = ShellAssessment(parse: p, normalized: ShellLexer.normalized(p))
        var allRead = a.analysable
        var base = cwd ?? root ?? home
        let rootReal: String? = root.map { PathPolicy.resolveExistingPrefix($0) }
        for c in p.commands {
            let info = analyze(c.words, depth: 0)
            allRead = allRead && info.readOnly
            a.hiddenExec += info.hiddenExec; a.destructive += info.destructive; a.effects.formUnion(info.effects)
            a.commandNames.append(info.name)
            // chemins : sensibles (développés, glob, liens résolus) et confinement dans la racine
            for (idx, w) in c.words.enumerated() {
                if idx == 0 && !w.text.contains("/") { continue }
                for cand in pathCandidates(w.text) {
                    let list: [String] = w.globbed ? globExpand(cand, base: base) : [absolutize(cand, base: base)]
                    for x in list {
                        let res = PathPolicy.resolveExistingPrefix(x)
                        if sensitive(x) || sensitive(res) || sensitive(cand) { if !a.sensitive.contains(cand) { a.sensitive.append(cand) } }
                        if idx > 0, let r = rootReal, looksLikePath(cand), !PathPolicy.isInside(res, root: r) { if !a.outsideRoot.contains(cand) { a.outsideRoot.append(cand) } }
                    }
                }
            }
            if info.name == "cd" || info.name == "pushd", c.words.count > 1 { base = absolutize(c.words[1].text, base: base) }
        }
        a.readOnly = allRead && a.hiddenExec.isEmpty && a.destructive.isEmpty
        if a.readOnly, p.commands.count == 1, p.devNullRedirects == 0, !p.commands[0].words.contains(where: { $0.globbed }) {
            let w = p.commands[0].words
            let first = w[0].text
            if let fp = fixedPaths[first] ?? (fixedPaths.values.contains(first) ? first : nil) { a.argv = [fp] + w.dropFirst().map { $0.text } }
        }
        return a
    }

    static func looksLikePath(_ t: String) -> Bool { t.hasPrefix("/") || t.hasPrefix(".") || t.contains("/") }
    /// Valeurs d'un mot qui peuvent désigner un fichier : le mot lui-même, la valeur d'un --opt=valeur, un @fichier (curl).
    static func pathCandidates(_ t: String) -> [String] {
        if t.isEmpty || t.contains("://") { return [] }
        if t.hasPrefix("-") {
            if let eq = t.firstIndex(of: "=") { let v = String(t[t.index(after: eq)...]); return v.isEmpty ? [] : pathCandidates(v) }
            return []
        }
        if t.hasPrefix("@") { return [String(t.dropFirst())] }
        if let r = t.range(of: "=@") { let v = String(t[r.upperBound...]); return v.isEmpty ? [t] : [t, v] }       // curl -F champ=@fichier
        if let eq = t.firstIndex(of: "="), t[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {      // dd if=/chemin, clé=valeur
            let v = String(t[t.index(after: eq)...]); return v.isEmpty ? [t] : [t, v]
        }
        return [t]
    }
    static func absolutize(_ x: String, base: String) -> String {
        let abs = x.hasPrefix("/") ? x : (base.hasSuffix("/") ? base + x : base + "/" + x)
        return PathPolicy.normalize(abs)
    }
    static func globExpand(_ pattern: String, base: String) -> [String] {
        let abs = pattern.hasPrefix("/") ? pattern : base + "/" + pattern
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(abs, 0, nil, &g) == 0 else { return [PathPolicy.normalize(abs)] }
        var outp: [String] = []
        let n = Int(g.gl_pathc)
        if let v = g.gl_pathv { for i in 0..<min(n, 256) { if let cs = v[i] { outp.append(String(cString: cs)) } } }
        return outp.isEmpty ? [PathPolicy.normalize(abs)] : outp
    }

    /// Analyse d'UNE commande simple (mots déjà déguillemetés).
    static func analyze(_ words: [ShellWord], depth: Int) -> Info {
        var info = Info()
        guard let first = words.first else { return info }
        let raw = first.text
        let name = (raw as NSString).lastPathComponent.lowercased()
        info.name = name
        let args: [String] = words.dropFirst().map { $0.text }
        func hidden(_ r: String) { info.hiddenExec.append(r); info.effects.insert(.exec) }
        if depth > 4 { hidden("enveloppes imbriquées"); return info }
        if m(assignRx, raw) { hidden("variable d'environnement en préfixe (\(raw.prefix(40)))"); return info }
        if raw.contains("/") {
            let std = systemBinDirs.contains(where: { raw.hasPrefix($0) && !raw.dropFirst($0.count).contains("/") })
            if !std { hidden("exécutable désigné par un chemin : \(raw.prefix(80))"); return info }
        }
        let fixedOK: Bool = !raw.contains("/") || fixedPaths[name] == raw
        func ro() { info.readOnly = fixedOK; info.effects.insert(.fileRead) }
        func shortFlags(_ a: String) -> String? { (a.hasPrefix("-") && !a.hasPrefix("--") && a.count > 1) ? String(a.dropFirst()) : nil }
        func inner(_ from: Int) {
            guard from < words.count else { return }
            let sub = analyze(Array(words[from...]), depth: depth + 1)
            info.merge(sub)
        }
        switch name {
        case "ls", "pwd", "cal", "whoami", "uname", "sw_vers", "uptime", "df", "du", "echo", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep",
             "mdfind", "mdls", "stat", "which", "ps", "vm_stat", "system_profiler", "ioreg", "basename", "dirname", "tr", "cut", "diff", "lsof", "afplay":
            ro()
        case "say":
            if args.contains(where: { $0 == "-o" || $0.hasPrefix("--output-file") || $0 == "-n" || $0.hasPrefix("--network-send") }) { info.effects.insert(.fileWrite) } else { ro() }
        case "file":
            if args.contains(where: { $0 == "-C" || (shortFlags($0)?.contains("C") ?? false) || $0 == "--compile" }) { info.effects.insert(.fileWrite) } else { ro() }
        case "date":
            let ok = args.contains("-j") || args.allSatisfy { $0.hasPrefix("+") || ["-u", "-R", "-n"].contains($0) || $0.hasPrefix("-v") }
            if ok { ro() } else { info.effects.insert(.fileWrite) }   // réglage de l'horloge
        case "hostname":
            if args.allSatisfy({ ["-s", "-f", "-d"].contains($0) }) { ro() } else { info.effects.insert(.fileWrite) }
        case "ifconfig":
            if args.isEmpty || args.allSatisfy({ ["-a", "-l", "-L", "-u", "-d", "-v", "-m"].contains($0) }) || (args.count == 1 && m(ifaceRx, args[0])) { ro() }
            else { info.effects.formUnion([.network, .fileWrite]) }
        case "defaults":
            if let v = args.first, ["read", "read-type", "domains", "find", "help"].contains(v) { ro() } else { info.effects.insert(.fileWrite) }
        case "networksetup":
            if let v = args.first, v.hasPrefix("-get") || v.hasPrefix("-list") || v == "-printcommands" || v == "-version" { ro() } else { info.effects.formUnion([.network, .fileWrite]) }
        case "launchctl":
            if let v = args.first, ["list", "print", "print-disabled", "blame", "version"].contains(v) { ro() } else { hidden("launchctl modifie ou lance des services") }
        case "pmset":
            if args.first == "-g" { ro() } else { info.effects.insert(.fileWrite) }
        case "top":
            if args.contains(where: { $0 == "-l" || $0.hasPrefix("-l") }) { ro() } else { info.effects.insert(.fileRead) }   // interactif : pas de lecture rapide
        case "sort":
            if args.contains(where: { $0.hasPrefix("--compress-program") }) { hidden("sort --compress-program") }
            else if args.contains(where: { $0 == "-o" || $0.hasPrefix("--output") || (shortFlags($0)?.contains("o") ?? false) }) { info.effects.insert(.fileWrite) }
            else { ro() }
        case "find":
            var ok = true
            for (k, a) in args.enumerated() {
                let w = words[k + 1]
                let low = a.lowercased()
                if ["-exec", "-execdir", "-ok", "-okdir"].contains(low) || low.hasPrefix("-exec") || low.hasPrefix("-ok") { hidden("find " + a + " (exécute une commande par fichier)"); ok = false }
                else if low == "-delete" { info.destructive.append("find -delete"); info.effects.insert(.fileWrite); ok = false }
                else if ["-fprint", "-fprint0", "-fprintf", "-fls"].contains(low) || low.hasPrefix("-fprint") { info.effects.insert(.fileWrite); ok = false }
                else if w.globbed { ok = false; info.effects.insert(.fileRead) }   // un motif non protégé peut s'étendre en « -delete »
            }
            if ok { ro() }
        case "awk", "gawk", "nawk", "mawk":
            if args.contains(where: { $0 == "-f" || $0.hasPrefix("-f") && !$0.hasPrefix("-F") || $0.hasPrefix("--file") || $0 == "-E" || $0.hasPrefix("--exec") }) { hidden("awk -f / -E : programme externe") }
            else if args.contains(where: { $0.contains("system") || $0.contains("getline") || $0.contains("|") || $0.contains(">") || $0.contains("@load") }) { hidden("awk system() / getline / redirection") }
            else if name == "awk" { ro() } else { info.effects.insert(.fileRead) }
        case "sed", "gsed":
            if args.contains(where: { $0 == "-i" || $0 == "-I" || $0.hasPrefix("--in-place") || (shortFlags($0).map { $0.contains("i") || $0.contains("I") } ?? false) }) { info.effects.insert(.fileWrite) }   // sed -i réécrit le fichier : écriture (pas une lecture)
            for a in args where !a.hasPrefix("-") || a.count > 2 {
                if m(sedExecRx, a) { hidden("sed : commande e (exécute)") }
                if m(sedWriteRx, a) { info.effects.insert(.fileWrite) }
            }
            info.effects.insert(.fileRead)
        case "tar", "gtar", "bsdtar":
            let execOpts = ["--to-command", "--use-compress-program", "--checkpoint-action", "--rsh-command", "--info-script", "--new-volume-script", "--rmt-command", "-I", "-F"]
            if args.contains(where: { a in execOpts.contains(where: { a == $0 || a.hasPrefix($0 + "=") }) }) { hidden("tar : programme externe (--to-command, -I, --checkpoint-action…)") }
            let modeWord = args.first ?? ""
            let bundled = modeWord.hasPrefix("-") ? String(modeWord.dropFirst()) : modeWord
            if args.contains(where: { ["-x", "--extract", "--get", "-c", "--create", "-r", "--append", "-u", "--update", "--delete"].contains($0) }) || (!modeWord.hasPrefix("--") && bundled.contains(where: { "xcru".contains($0) })) {
                info.effects.insert(.fileWrite)
            } else { info.effects.insert(.fileRead) }
        case "rsync":
            if args.contains(where: { $0 == "-e" || $0.hasPrefix("--rsh") || $0.hasPrefix("--rsync-path") || (shortFlags($0)?.contains("e") ?? false) }) { hidden("rsync -e / --rsh / --rsync-path") }
            if args.contains(where: { !$0.hasPrefix("-") && ($0.contains(":") || $0.hasPrefix("rsync://")) }) { info.effects.formUnion([.network, .communication]) }
            info.effects.insert(.fileWrite)
        case "git":
            var k = 0; var sub = ""
            while k < args.count {
                let a = args[k]
                if a == "-c" || a.hasPrefix("--config-env") || a.hasPrefix("--exec-path") { hidden("git " + a + " (configuration à la volée : core.sshCommand, core.pager, alias…)"); if a == "-c" { k += 1 } }
                else if a == "-C" || a == "--git-dir" || a == "--work-tree" || a == "--namespace" { k += 1 }
                else if !a.hasPrefix("-") { sub = a; break }
                k += 1
            }
            let rest = k + 1 < args.count ? Array(args[(k + 1)...]) : []
            switch sub {
            case "status", "log", "diff", "show", "rev-parse", "ls-files", "blame", "describe", "shortlog", "reflog", "ls-tree", "cat-file", "grep", "version", "help":
                info.effects.insert(.fileRead)
            case "clone", "fetch", "pull", "ls-remote", "submodule":
                info.effects.formUnion([.network, .fileWrite])
                if rest.contains(where: { $0 == "-u" || $0.hasPrefix("--upload-pack") || $0.hasPrefix("--config") || $0.hasPrefix("ext::") || $0.contains("::") }) { hidden("git " + sub + " : --upload-pack / --config / transport ext::") }
                if sub == "pull" { hidden("git pull : hooks et filtres du dépôt") }
            case "push":
                info.effects.formUnion([.network, .communication])
                if rest.contains(where: { $0.hasPrefix("--receive-pack") || $0.hasPrefix("--exec") }) { hidden("git push --receive-pack / --exec") }
            case "config":
                info.effects.insert(.fileWrite)
                if rest.contains(where: { let l = $0.lowercased(); return l.hasPrefix("core.") || l.hasPrefix("alias.") || l.hasPrefix("filter.") || l.hasPrefix("diff.") || l.hasPrefix("credential.") || l.hasPrefix("include") || l.contains("command") || l.contains("hookspath") }) { hidden("git config core.* / alias.* / filter.* (exécution différée)") }
            case "commit", "merge", "rebase", "checkout", "switch", "am", "cherry-pick", "revert":
                info.effects.insert(.fileWrite); hidden("git " + sub + " : hooks du dépôt")
            case "":
                info.effects.insert(.fileRead)
            default:
                info.effects.insert(.fileWrite)
            }
        case "open":
            var execy = false
            for a in args {
                if a == "-a" || a == "-b" || a.hasPrefix("--args") || a == "-n" || a == "-F" || a.hasPrefix("--env") || (shortFlags(a).map { $0.contains("a") || $0.contains("b") } ?? false) { execy = true }
                let low = a.lowercased()
                if ["mailto:", "sms:", "imessage:", "facetime:", "tel:", "whatsapp:", "skype:", "msteams:", "slack:"].contains(where: { low.hasPrefix($0) }) { info.effects.insert(.communication) }
                if low.hasPrefix("http://") || low.hasPrefix("https://") { info.effects.insert(.network) }
                let ext = (low as NSString).pathExtension
                if !low.hasPrefix("-"), openExecExt.contains(ext) { execy = true }
            }
            if execy { hidden("open lance une application ou un exécutable") }
            info.effects.insert(.screen)
        case "curl":
            if args.contains(where: { $0 == "-K" || $0.hasPrefix("--config") || $0 == "-:" || $0 == "--next" }) { hidden("curl -K / --config / --next") }
            if args.contains(where: { $0 == "-o" || $0 == "-O" || $0.hasPrefix("--output") || $0.hasPrefix("--remote-name") || $0 == "-D" || $0.hasPrefix("--dump-header") || $0 == "-c" || $0.hasPrefix("--cookie-jar") || (shortFlags($0).map { $0.hasSuffix("o") || $0.contains("O") } ?? false) }) { info.effects.insert(.fileWrite) }
            let upload = ["-d", "--data", "--data-raw", "--data-binary", "--data-urlencode", "--json", "-F", "--form", "-T", "--upload-file", "--form-string", "--mail-rcpt", "--mail-from"]
            let method = args.enumerated().contains { k, a in (a == "-X" || a == "--request") && k + 1 < args.count && !["GET", "HEAD"].contains(args[k + 1].uppercased()) } ||
                         args.contains { ($0.hasPrefix("-X") && $0.count > 2 && !["GET", "HEAD"].contains(String($0.dropFirst(2)).uppercased())) || ($0.hasPrefix("--request=") && !["GET", "HEAD"].contains(String($0.dropFirst(10)).uppercased())) }
            if method || args.contains(where: { a in upload.contains(where: { a == $0 || a.hasPrefix($0 + "=") }) || (a.hasPrefix("-d") && a.count > 2) || (a.hasPrefix("-F") && a.count > 2) || (a.hasPrefix("-T") && a.count > 2) }) || args.contains(where: { $0.lowercased().hasPrefix("smtp") }) {
                info.effects.insert(.communication)
            }
            info.effects.insert(.network)
        case "wget":
            if args.contains(where: { $0 == "-e" || $0.hasPrefix("--execute") || $0.hasPrefix("--use-askpass") }) { hidden("wget -e / --execute") }
            if args.contains(where: { $0.hasPrefix("--post-data") || $0.hasPrefix("--post-file") || $0.hasPrefix("--body-data") || $0.hasPrefix("--body-file") || $0.hasPrefix("--method") }) { info.effects.insert(.communication) }
            info.effects.formUnion([.network, .fileWrite])
        case "ssh", "scp", "sftp", "autossh", "mosh":
            if args.contains(where: { $0 == "-o" || $0.hasPrefix("-o") || $0 == "-F" || $0 == "-S" || $0.hasPrefix("-S") }) { hidden(name + " -o / -F / -S (ProxyCommand, programme externe)") }
            if name == "ssh" || name == "autossh" || name == "mosh" { hidden(name + " exécute des commandes à distance") }
            info.effects.formUnion([.network, .communication])
        case "kill", "killall", "pkill":
            info.effects.insert(.exec)
        case "crontab", "at", "batch":
            hidden(name + " planifie une exécution")
        case "screencapture":
            info.effects.formUnion([.screen, .fileWrite])
        case "security":
            hidden("security (trousseau)")
        default:
            if interpreters.contains(name) { hidden("interpréteur « \(name) »"); break }
            if buildTools.contains(name) {
                hidden("outil de construction ou de paquets « \(name) » (exécute du code du projet)"); info.effects.insert(.fileWrite)
                let netVerbs: Set<String> = ["install", "i", "add", "update", "upgrade", "fetch", "get", "pull", "download", "sync", "ci", "restore", "tap", "login"]
                if args.contains(where: { netVerbs.contains($0.lowercased()) }) { info.effects.insert(.network) }
                if args.contains(where: { ["publish", "push", "release", "deploy", "upload"].contains($0.lowercased()) }) { info.effects.formUnion([.network, .communication]) }
                break
            }
            if wrappers.contains(name) {
                if name == "command" && (args.first == "-v" || args.first == "-V") { ro(); break }
                hidden("« \(name) » lance une autre commande")
                // commande enveloppée : options (et leurs valeurs connues) sautées, puis analyse récursive
                var k = 1
                let valued: Set<String> = ["-n", "-u", "-I", "-L", "-P", "-s", "-E", "-d", "-J", "-R", "-S", "-t", "-g", "-C", "-k", "-s", "--signal", "--kill-after"]
                while k < words.count {
                    let t = words[k].text
                    if t == "--" { k += 1; break }
                    if t.hasPrefix("-") { if valued.contains(t) { k += 2 } else { k += 1 }; continue }
                    if name == "env" && m(assignRx, t) { hidden("env : variable " + String(t.prefix(40))); k += 1; continue }
                    if (name == "timeout" || name == "gtimeout") && t.first?.isNumber == true { k += 1; continue }
                    if name == "caffeinate", t.first?.isNumber == true { k += 1; continue }
                    break
                }
                inner(k)
                break
            }
            if shellStateBuiltins.contains(name) { hidden("commande zsh « \(name) » qui modifie le shell ou exécute plus tard"); break }
            if harmlessBuiltins.contains(name) { info.readOnly = true; break }
            if writers.contains(name) { info.effects.insert(.fileWrite); break }
            if deleters.contains(name) { info.destructive.append(name); info.effects.insert(.fileWrite); break }
            if netTools.contains(name) {
                info.effects.formUnion([.network, .communication])
                if args.contains(where: { $0 == "-e" || $0 == "-c" || $0.hasPrefix("--exec") || $0.hasPrefix("--sh-exec") || $0.hasPrefix("--lua-exec") }) { hidden(name + " -e / --exec") }
                break
            }
            if mailers.contains(name) { info.effects.insert(.communication); break }
            info.effects.insert(.exec)   // inconnu : effets non analysés (ni « lecture », ni exécution cachée)
        }
        return info
    }

    /// Valeurs de curl qui prennent un argument (options courtes et longues).
    static let curlShortValued: Set<Character> = ["H", "X", "d", "o", "m", "A", "e", "w", "u", "F", "T", "b", "c", "r", "x", "K", "E", "z", "Y", "y", "C", "Q", "t", "U", "D", "P"]
    static let curlLongValued: Set<String> = ["--header", "--request", "--data", "--data-raw", "--data-binary", "--data-urlencode", "--json", "--output", "--max-time",
        "--connect-timeout", "--user-agent", "--referer", "--write-out", "--user", "--form", "--form-string", "--upload-file", "--cookie", "--cookie-jar", "--retry",
        "--retry-delay", "--retry-max-time", "--range", "--cert", "--cacert", "--key", "--limit-rate", "--continue-at", "--quote", "--telnet-option", "--unix-socket",
        "--abstract-unix-socket", "--interface", "--local-port", "--max-filesize", "--url", "--dump-header", "--time-cond", "--expect100-timeout"]
    static let curlForbidden: [String] = ["--proxy", "--preproxy", "--proxy-", "--socks4", "--socks5", "--resolve", "--connect-to", "--config", "--doh-url", "--next", "--haproxy", "--dns-"]

    /// Vrai seulement si la commande est UN appel curl dont chaque cible est une adresse de boucle locale exacte
    /// (127.0.0.1, ::1, localhost) : sans proxy, sans --resolve/--connect-to, sans configuration externe, sans userinfo.
    public static func loopbackCurlOnly(_ cmd: String, home: String = NSHomeDirectory()) -> Bool {
        let p = ShellLexer.parse(cmd, env: ["HOME": home])
        guard p.opaque.isEmpty, p.commands.count == 1, let w = p.commands.first?.words, w.first?.text == "curl" else { return false }
        let low = cmd.lowercased()
        if low.contains("mailto:") || low.contains("sms:") || low.contains("imessage:") || low.contains("whatsapp:") { return false }
        var targets = 0
        var k = 1
        while k < w.count {
            let t = w[k].text
            if t.hasPrefix("--") {
                let opt = t.split(separator: "=", maxSplits: 1).first.map(String.init) ?? t
                if curlForbidden.contains(where: { opt.hasPrefix($0) }) { return false }
                if opt == "--url" {
                    let v: String? = t.contains("=") ? String(t.split(separator: "=", maxSplits: 1)[1]) : (k + 1 < w.count ? w[k + 1].text : nil)
                    guard let u = v, NetPolicy.isLoopbackURL(u) else { return false }
                    targets += 1; k += t.contains("=") ? 1 : 2; continue
                }
                if !t.contains("="), curlLongValued.contains(opt) { k += 2 } else { k += 1 }
                continue
            }
            if t.hasPrefix("-") && t.count > 1 {
                let letters = Array(t.dropFirst())
                var consumedNext = false
                for (j, ch) in letters.enumerated() {
                    if ch == "x" || ch == "K" || ch == "U" || ch == ":" { return false }
                    if curlShortValued.contains(ch) { if j == letters.count - 1 { consumedNext = true }; break }
                }
                k += consumedNext ? 2 : 1
                continue
            }
            guard NetPolicy.isLoopbackURL(t) else { return false }
            targets += 1; k += 1
        }
        return targets > 0
    }
}

// MARK: - Réseau : hôtes et adresses analysés exactement

public enum NetPolicy {
    /// Hôte nettoyé : minuscules, crochets IPv6 retirés, zone %eth0 retirée, point final retiré.
    public static func canonicalHost(_ h: String) -> String {
        var x = h.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if x.hasPrefix("[") && x.hasSuffix("]") { x = String(x.dropFirst().dropLast()) }
        if let pct = x.firstIndex(of: "%") { x = String(x[..<pct]) }
        while x.hasSuffix(".") { x = String(x.dropLast()) }
        return x
    }
    /// IPv4 au sens de inet_aton : accepte aussi 127.1, 0x7f.0.0.1, 017700000001, 2130706433 — exactement ce qu'un client
    /// réseau acceptera. nil si ce n'est pas une adresse IPv4.
    public static func parseIPv4(_ h: String) -> [UInt8]? {
        guard !h.isEmpty, h.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "." || $0 == "x" || $0 == "X") }) else { return nil }
        var a = in_addr()
        guard inet_aton(h, &a) != 0 else { return nil }
        let v = UInt32(bigEndian: a.s_addr)
        return [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
    }
    public static func parseIPv6(_ h: String) -> [UInt8]? {
        guard h.contains(":") else { return nil }
        var a = in6_addr()
        guard inet_pton(AF_INET6, h, &a) == 1 else { return nil }
        return withUnsafeBytes(of: &a) { Array($0) }
    }
    public static func isInternalIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return true }
        switch b[0] {
        case 0, 10, 127: return true
        case 100: return (64...127).contains(b[1])
        case 169: return b[1] == 254
        case 172: return (16...31).contains(b[1])
        case 192: return b[1] == 168 || (b[1] == 0 && (b[2] == 0 || b[2] == 2)) || (b[1] == 88 && b[2] == 99)
        case 198: return b[1] == 18 || b[1] == 19 || (b[1] == 51 && b[2] == 100)
        case 203: return b[1] == 0 && b[2] == 113
        default: return b[0] >= 224
        }
    }
    public static func isInternalIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return true }
        if b[0..<15].allSatisfy({ $0 == 0 }) { return true }                               // :: et ::1
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }                            // fe80::/10 lien local
        if b[0] == 0xfe && (b[1] & 0xc0) == 0xc0 { return true }                            // fec0::/10 site local (obsolète)
        if (b[0] & 0xfe) == 0xfc { return true }                                            // fc00::/7 ULA
        if b[0] == 0xff { return true }                                                     // multidiffusion
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return isInternalIPv4(Array(b[12..<16])) }   // ::ffff:a.b.c.d
        if b[0..<12].allSatisfy({ $0 == 0 }) { return isInternalIPv4(Array(b[12..<16])) }  // ::a.b.c.d (compatible, obsolète)
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b { return isInternalIPv4(Array(b[12..<16])) }   // 64:ff9b::/96 NAT64
        if b[0] == 0x20 && b[1] == 0x02 { return isInternalIPv4(Array(b[2..<6])) }          // 2002::/16 6to4
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 { return true }     // 2001:db8::/32 documentation
        if b[0] == 0x01 && b[1] == 0x00 && b[2..<8].allSatisfy({ $0 == 0 }) { return true } // 100::/64 rejet
        return false
    }
    /// Hôte interne (refus pour web_fetch) : boucle locale, réseaux privés, lien local, métadonnées, noms locaux, IP sous toutes leurs écritures.
    public static func isInternalHost(_ host: String) -> Bool {
        let h = canonicalHost(host)
        if h.isEmpty { return true }
        if let v4 = parseIPv4(h) { return isInternalIPv4(v4) }
        if let v6 = parseIPv6(h) { return isInternalIPv6(v6) }
        if h.contains(":") || h.contains("/") || h.contains("@") || h.contains("\\") { return true }   // non analysable : refus
        if !h.contains(".") { return true }                                                          // nom à un seul libellé
        let localSuffixes = [".localhost", ".local", ".internal", ".lan", ".home.arpa", ".intranet", ".corp", ".home", ".localdomain", ".test", ".invalid", ".example", ".onion"]
        if h == "localhost" || localSuffixes.contains(where: { h.hasSuffix($0) }) { return true }
        return false
    }
    /// Boucle locale EXACTE (liste d'autorisation) : 127.0.0.1, ::1 ou localhost — pas 127.0.0.2, pas ::ffff:127.0.0.1,
    /// pas localhost.example.com, pas 127.0.0.1.nip.io.
    public static func isExactLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        let stripped = (h.hasPrefix("[") && h.hasSuffix("]")) ? String(h.dropFirst().dropLast()) : h
        return stripped == "127.0.0.1" || stripped == "::1" || stripped == "localhost"
    }
    /// URL http(s) analysée dont l'hôte est une boucle locale exacte, sans userinfo.
    public static func isLoopbackURL(_ s: String) -> Bool {
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard c.user == nil, c.password == nil, let host = c.host, !host.isEmpty else { return false }
        if s.lowercased().replacingOccurrences(of: scheme + "://", with: "").split(separator: "/").first?.contains("@") == true { return false }
        return isExactLoopback(host)
    }
    /// Motif de refus d'une URL pour web_fetch (nil = acceptable avant résolution DNS).
    public static func fetchRefusal(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: t), let scheme = c.scheme?.lowercased() else { return "URL invalide" }
        guard scheme == "http" || scheme == "https" else { return "schéma non autorisé : \(scheme)" }
        if c.user != nil || c.password != nil { return "identifiants dans l'URL (user@hôte) refusés" }
        let authority = t.dropFirst(scheme.count + 3).split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if authority.contains("@") || authority.contains("\\") { return "autorité d'URL ambiguë (@ ou \\)" }
        guard let host = c.host, !host.isEmpty else { return "hôte absent" }
        if isInternalHost(host) { return "hôte interne" }
        return nil
    }
    /// Résout l'hôte et dit si UNE de ses adresses est interne (ex. 127.0.0.1.nip.io). Échec de résolution = interne (refus).
    public static func resolvesInternal(_ host: String) -> Bool {
        let h = canonicalHost(host)
        if parseIPv4(h) != nil || parseIPv6(h) != nil { return isInternalHost(h) }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var res: UnsafeMutablePointer<addrinfo>? = nil
        guard getaddrinfo(h, nil, &hints, &res) == 0, let first = res else { return true }
        defer { freeaddrinfo(first) }
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0, isInternalHost(String(cString: buf)) { return true }
            p = ai.pointee.ai_next
        }
        return false
    }
}

// MARK: - Chemins : liens résolus et racines permises

public enum PathPolicy {
    /// Normalisation LEXICALE (« // », « . », « .. ») — pas NSString.standardizingPath, qui retire « /private » quand le
    /// chemin existe (et pas sinon) : deux formes d'un même dossier ne se compareraient plus.
    public static func normalize(_ p: String) -> String {
        let absolute = p.hasPrefix("/")
        var out: [Substring] = []
        for c in p.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { if let last = out.last, last != ".." { out.removeLast() } else if !absolute { out.append(c) }; continue }
            out.append(c)
        }
        let j = out.joined(separator: "/")
        return absolute ? "/" + j : (j.isEmpty ? "." : j)
    }
    public static func realpathOrNil(_ p: String) -> String? {
        guard let r = realpath(p, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }
    /// Résout les liens symboliques du plus long préfixe EXISTANT, puis recolle le reste (chemin standardisé).
    public static func resolveExistingPrefix(_ p: String) -> String {
        let std = normalize(p)
        var head = std
        var tail: [String] = []
        while !head.isEmpty && head != "/" {
            if let r = realpathOrNil(head) { return tail.isEmpty ? r : (r as NSString).appendingPathComponent(tail.reversed().joined(separator: "/")) }
            tail.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
        }
        return std
    }
    /// `path` (déjà résolu) est-il égal à `root` ou dessous ? Comparaison par composants, jamais par préfixe de chaîne.
    public static func isInside(_ path: String, root: String) -> Bool {
        let r = normalize(root), x = normalize(path)
        if x == r { return true }
        return x.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }
    /// Chemin d'écriture : refus si le chemin RÉSOLU (liens du parent ET du fichier lui-même) sort de la racine.
    public static func resolveForWrite(_ p: String, root: String) -> String? {
        let rootReal = resolveExistingPrefix(root)
        let resolved = resolveExistingPrefix(p)
        guard isInside(resolved, root: rootReal), resolved != rootReal else { return nil }
        return resolved
    }
    /// Fichier statique : chemin relatif décodé, sans « .. », sans NUL ni antislash, résolu DANS la racine. nil = refus.
    public static func containedStaticFile(root: String, relative raw: String) -> String? {
        guard let dec = raw.removingPercentEncoding else { return nil }
        if dec.contains("\0") || dec.contains("\\") || dec.hasPrefix("/") || dec.isEmpty { return nil }
        let comps = dec.split(separator: "/", omittingEmptySubsequences: false)
        if comps.contains(where: { $0 == ".." || $0 == "." }) { return nil }
        guard let rootReal = realpathOrNil(root) else { return nil }
        let cand = (rootReal as NSString).appendingPathComponent(dec)
        guard let real = realpathOrNil(cand), isInside(real, root: rootReal), real != rootReal else { return nil }
        return real
    }
}

// MARK: - Sous-processus bornés

public struct BoundedResult {
    public var code: Int32 = 127
    public var out: String = ""
    public var err: String = ""
    public var timedOut = false
    public var cancelled = false
    public var outTruncated = false
    public var errTruncated = false
    public var launchError: String? = nil
}

public enum BoundedProcess {
    final class Sink {
        let lock = NSLock()
        var data = Data()
        var dropped = false
        let cap: Int
        init(cap: Int) { self.cap = cap }
        func add(_ d: Data) -> Bool {   // false = plafond dépassé
            lock.lock(); defer { lock.unlock() }
            if data.count + d.count > cap { data.append(d.prefix(max(0, cap - data.count))); dropped = true; return false }
            data.append(d); return true
        }
        var overflow: Bool { lock.lock(); defer { lock.unlock() }; return dropped }
        var snapshot: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// Lance un exécutable de chemin FIXE (jamais résolu par PATH) avec délai, plafonds de sortie et annulation.
    /// Délai, plafond de stdout ou annulation : le processus ET ses descendants sont arrêtés (TERM puis KILL).
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval, maxOutput: Int = 512 * 1024, maxError: Int = 16 * 1024,
                           cwd: String? = nil, stdin: Data? = nil, cancel: (() -> Bool)? = nil) -> BoundedResult {
        var r = BoundedResult()
        guard path.hasPrefix("/") else { r.launchError = "exécutable sans chemin absolu refusé"; return r }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let d = cwd { p.currentDirectoryURL = URL(fileURLWithPath: d, isDirectory: true) }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        var inPipe: Pipe? = nil
        if stdin != nil { let i = Pipe(); p.standardInput = i; inPipe = i } else { p.standardInput = FileHandle.nullDevice }
        let outSink = Sink(cap: maxOutput), errSink = Sink(cap: maxError)
        do { try p.run() } catch { r.launchError = shortError(error.localizedDescription, 160); return r }
        if let s = stdin, let i = inPipe { DispatchQueue.global(qos: .utility).async { i.fileHandleForWriting.write(s); try? i.fileHandleForWriting.close() } }
        let g = DispatchGroup()
        for (pipe, sink) in [(outPipe, outSink), (errPipe, errSink)] {
            g.enter()
            DispatchQueue.global(qos: .utility).async {
                let h = pipe.fileHandleForReading
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    _ = sink.add(d)   // au-delà du plafond : on continue de vider le tuyau (l'enfant ne bloque pas), sans stocker
                }
                g.leave()
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() >= deadline { r.timedOut = true; break }
            if cancel?() == true { r.cancelled = true; break }
            if outSink.overflow { r.outTruncated = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if p.isRunning { terminateTree(p.processIdentifier); p.terminate() }
        _ = g.wait(timeout: .now() + 1.5)
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit()
        r.code = (r.timedOut || r.cancelled) ? 124 : p.terminationStatus
        r.out = String(decoding: outSink.snapshot, as: UTF8.self)
        r.err = String(decoding: errSink.snapshot, as: UTF8.self)
        r.outTruncated = r.outTruncated || outSink.overflow
        r.errTruncated = errSink.overflow
        return r
    }

    /// Descendants d'un processus (pgrep -P, récursif, borné).
    static func descendants(_ pid: Int32) -> [Int32] {
        var all: [Int32] = []; var frontier: [Int32] = [pid]
        let pgrep = FileManager.default.isExecutableFile(atPath: "/usr/bin/pgrep") ? "/usr/bin/pgrep" : "/bin/pgrep"
        while let cur = frontier.popLast(), all.count < 256 {
            let q = Process(); q.executableURL = URL(fileURLWithPath: pgrep); q.arguments = ["-P", String(cur)]
            let o = Pipe(); q.standardOutput = o; q.standardError = FileHandle.nullDevice; q.standardInput = FileHandle.nullDevice
            guard (try? q.run()) != nil else { break }
            let d = o.fileHandleForReading.readDataToEndOfFile(); q.waitUntilExit()
            for line in String(decoding: d, as: UTF8.self).split(separator: "\n") { if let c = Int32(line.trimmingCharacters(in: .whitespaces)), !all.contains(c) { all.append(c); frontier.append(c) } }
        }
        return all
    }
    static func terminateTree(_ pid: Int32) {
        let kids = descendants(pid)
        for k in kids.reversed() { kill(k, SIGTERM) }
        kill(-pid, SIGTERM); kill(pid, SIGTERM)
        Thread.sleep(forTimeInterval: 0.3)
        for k in kids.reversed() { kill(k, SIGKILL) }
        kill(-pid, SIGKILL)
    }

    static let ansiRx = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}[@-_]", options: [])
    static let secretRxs: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?i)\b(api[_-]?key|access[_-]?token|token|secret|password|passwd|authorization|bearer)\b(\s*[:=]\s*|\s+)("[^"]*"|'[^']*'|\S+)"#, options: []),
        try! NSRegularExpression(pattern: #"\b(sk|pk|rk|xox[abpr]|ghp|gho|ghs|glpat|AKIA|AIza)[-_A-Za-z0-9]{12,}"#, options: []),
        try! NSRegularExpression(pattern: #"\b[A-Za-z0-9+/_-]{40,}={0,2}"#, options: []),
    ]
    /// stderr exploitable mais sans danger : séquences ANSI et caractères de contrôle retirés, dossier personnel → ~,
    /// secrets probables masqués, au plus 8 lignes et `max` caractères.
    public static func sanitize(_ s: String, home: String = NSHomeDirectory(), max: Int = 600) -> String {
        var t = s
        t = ansiRx.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")
        t = String(String.UnicodeScalarView(t.unicodeScalars.map { ($0.value < 0x20 && $0 != "\n" && $0 != "\t") || $0.value == 0x7F || (0x80...0x9F).contains($0.value) ? " " : $0 }))
        if !home.isEmpty && home != "/" { t = t.replacingOccurrences(of: home, with: "~") }
        t = secretRxs[0].stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "$1$2•••")
        for r in secretRxs.dropFirst() { t = r.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "•••") }
        let lines = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var outp = lines.prefix(8).joined(separator: "\n")
        if lines.count > 8 { outp += "\n…" }
        if outp.count > max { outp = String(outp.prefix(max)) + "…" }
        return outp
    }
}

// MARK: - GET à redirections revalidées

public enum SafeHTTP {
    final class Box: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let allow: (URL) -> String?
        let maxBytes: Int
        let maxRedirects: Int
        var redirects = 0
        var refused: String? = nil
        var status = 0
        var data = Data()
        var truncated = false
        var finalURL: URL? = nil
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        init(allow: @escaping (URL) -> String?, maxBytes: Int, maxRedirects: Int) { self.allow = allow; self.maxBytes = maxBytes; self.maxRedirects = maxRedirects }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            lock.lock()
            redirects += 1
            var why: String? = nil
            if redirects > maxRedirects { why = "trop de redirections (> \(maxRedirects))" }
            else if let u = request.url { why = allow(u) } else { why = "redirection sans adresse" }
            if let w = why { refused = "redirection refusée vers \(request.url?.host ?? "?") : \(w)" }
            lock.unlock()
            completionHandler(why == nil ? request : nil)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.lock(); status = (response as? HTTPURLResponse)?.statusCode ?? 0; finalURL = response.url; lock.unlock()
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive d: Data) {
            lock.lock()
            if data.count + d.count > maxBytes { data.append(d.prefix(max(0, maxBytes - data.count))); truncated = true; lock.unlock(); dataTask.cancel(); return }
            data.append(d); lock.unlock()
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { done.signal() }
    }

    /// GET borné : chaque redirection est revalidée par `allow` (nil = permise, sinon motif) ; corps ≤ maxBytes.
    /// Une redirection refusée arrête la requête : (0, "", motif).
    public static func get(_ req: URLRequest, timeout: TimeInterval, maxBytes: Int = 5 * 1024 * 1024, maxRedirects: Int = 5,
                           allow: @escaping (URL) -> String?) -> (status: Int, data: Data, refused: String?, truncated: Bool) {
        let box = Box(allow: allow, maxBytes: maxBytes, maxRedirects: maxRedirects)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 5
        let s = URLSession(configuration: cfg, delegate: box, delegateQueue: nil)
        let t = s.dataTask(with: req)
        t.resume()
        if box.done.wait(timeout: .now() + timeout + 6) == .timedOut { t.cancel() }
        s.invalidateAndCancel()
        box.lock.lock(); defer { box.lock.unlock() }
        if let r = box.refused { return (0, Data(), r, false) }
        return (box.status, box.data, nil, box.truncated)
    }
}
