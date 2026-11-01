import Foundation
#if os(macOS)
import AppKit
#endif
#if canImport(EventKit) && os(macOS)
import EventKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Découpé de Tools.swift (19/10) : journal, garde-fous, confirmations, shell, AppleScript — code déplacé à l'identique.
extension Tools {
    /// Journal global des actions (V15) : qui, quoi, pourquoi, résultat, annulable ou non. Jamais de secret : l'entrée est tronquée.
    public static let actions = Journal("actions.jsonl")
    nonisolated(unsafe) public static var appHook: ((String) -> String)? = nil   // PHASE 1 (relu, protégé) : crochet posé au démarrage (NovaApp.start, avant l'ouverture du serveur), lecture seule ensuite
    nonisolated(unsafe) public static var assistHook: ((String) -> String)? = nil   // PHASE 1 (relu, protégé) : crochet posé une fois (Dots.init), lecture seule ensuite

    // Contrôle du Mac (propriétaire = l'utilisateur). Actions courantes : directes. Destructif : « oui » explicite + préfixe CONFIRMÉ:.
    static let consentRx = try! NSRegularExpression(pattern: #"\b(oui|go|ok|okay|confirme|confirmé|vas-y|vas y|d'accord|fais-le|fais le|exécute|execute|valide|j'autorise|autorise)\b"#, options: .caseInsensitive)
    static let forbiddenRx = try! NSRegularExpression(pattern: #"(\bsudo\b|security\s+(find|dump|delete|add)|/\.ssh|/\.aws|/\.gnupg|Library/Keychains|\.netrc\b|\.config/gh(?![\w.-])|/\.codex\b|~?\.codex/|Library/Cookies|\.bionic-tools\b|\.env\b|mkfs|csrutil|nvram|diskutil\s+(erase|partition|apfs\s+delete)|\bdd\s+if=|curl[^|]*\|\s*(sh|bash|zsh)|wget[^|]*\|\s*(sh|bash|zsh))"#, options: .caseInsensitive)
    static let riskyRx = try! NSRegularExpression(pattern: #"(\brm\b|\brmdir\b|\bunlink\b|\bkill(all)?\b|\bpkill\b|\bshutdown\b|\breboot\b|\bhalt\b|launchctl\s+(unload|bootout|remove|disable)|defaults\s+delete|\bchown\b|networksetup|\bpmset\b|git\s+(push|reset\s+--hard|clean)|brew\s+(uninstall|remove)|osascript[^\n]*(delete|restart|shut down|log out)|>\s*/(etc|usr|System|Library)|\btee\b\s+/)"#, options: .caseInsensitive)
    static let mailPayRx = try! NSRegularExpression(pattern: #"(send\s+(message|outgoing)|\bsend\b[^\n]{0,40}(mail|message)|make new outgoing message|sendmail|\bmail\b\s+-s|stripe|paypal|virement|\bpay(ment)?\b|envoy(er|ez)\b[^\n]{0,40}(mail|message|courriel|sms|whatsapp)|\bpaiement\b|\bpayer\b|orange\s*money|\bmomo\b|wave\s+transfer)"#, options: .caseInsensitive)
    /// Hôtes internes à refuser pour web_fetch : boucle locale, réseaux privés, link-local (métadonnées), noms locaux, IP sous toutes
    /// leurs écritures (127.1, 0x7f000001, 2130706433, ::ffff:127.0.0.1, 64:ff9b::…). WP5 : adresses ANALYSÉES (inet_aton/inet_pton),
    /// plus de comparaison par préfixe de chaîne — voir NetPolicy (ToolPolicy.swift).
    /// Résout l'hôte et refuse s'il pointe vers une adresse interne (ex. 127.0.0.1.nip.io).
    static func resolvesInternal(_ host: String) -> Bool { NetPolicy.resolvesInternal(host) }
    static func isInternalHost(_ host: String) -> Bool { NetPolicy.isInternalHost(host) }
    /// Contournements classiques de mailPayRx : envoi par URL mailto/sms, POST réseau, frappe dans une app de messagerie.
    static let sendEvasionRx = try! NSRegularExpression(pattern: #"(mailto:|\bsms:|imessage:|whatsapp:|curl[^\n]*(-X\s*POST|--data|\s-d\s|\s-F\s|--form|--upload-file|-T\s)|(Mail|Messages|Outlook|Teams|WhatsApp|Telegram|Slack)[\s\S]{0,300}(keystroke|key code|click button|\bsend\b))"#, options: .caseInsensitive)
    /// NOVA2-FIX 20/10 : un curl dont TOUTES les cibles sont en boucle locale ne peut rien envoyer à un tiers — c'est l'appel aux
    /// services locaux (ex. [tiers]). WP5 : la commande est LUE (lexique zsh), chaque cible est une URL analysée dont l'hôte est
    /// EXACTEMENT 127.0.0.1, ::1 ou localhost — refus de localhost.example.com, 127.0.0.1.nip.io, http://localhost@evil.com,
    /// [::ffff:127.0.0.1] (politique : formes canoniques seulement), d'un hôte sans schéma, de -x/--proxy, --resolve, --connect-to, -K.
    static func loopbackCurlOnly(_ cmd: String) -> Bool { ShellPolicy.loopbackCurlOnly(cmd) }
    /// Exécution indirecte (code encodé, interpréteur en ligne, concaténation de guillemets) : jamais sans confirmation explicite.
    static let indirectRx = try! NSRegularExpression(pattern: #"(base64\s+(-d|-D|--decode)|\beval\b|\b(python3?|perl|ruby|node|php)\s+-[ce]\b|\bosascript\s+-e|\w(''|"")\w|\bxargs\b[^\n]*\b(sh|bash|zsh)\b|\bsource\s+<\()"#, options: .caseInsensitive)
    // --- Confirmations validées dans l'interface (plus de « CONFIRMÉ: » écrit par le modèle) ---
    nonisolated(unsafe) public static var confirmHook: (([String: Any]) -> Void)? = nil
    /// WP3-M : clé = portée du run (conversation ou Dot, ExecContext.scopeKey) + commande — une validation donnée
    /// dans une conversation ne sert jamais à un Dot ni à une autre conversation.
    nonisolated(unsafe) static var approved: [String: Date] = [:]
    nonisolated(unsafe) static var pendingConfirm: [String: [String: Any]] = [:]
    static func confirmScope() -> String { ExecContext.current?.scopeKey ?? "hors-run" }
    static func scopedKey(_ scope: String, _ cmd: String) -> String { scope + "\u{1F}" + cmd }
    /// Autorisation permanente (réglage « autorisation_totale », enregistré, actif au redémarrage) : plus aucune fenêtre de confirmation,
    /// SAUF envois de mails/messages, paiements et finances (refus dur dans `gate`), mots de passe/secrets (forbiddenRx) et effacements catastrophiques (racine, dossier personnel).
    nonisolated(unsafe) public static var fullAuto: () -> Bool = { false }
    static let catastrophicRx = try! NSRegularExpression(pattern: #"\brm\s+(-\w+\s+)*(/|~|\$HOME|/Users/[^/\s]+)/?(\s|$|\*)"#, options: .caseInsensitive)
    /// « autoriser les commandes courantes pendant N min » (jamais les actions destructrices). INTÉGRATION 31/10 (WP3-M + WP5-M) :
    /// la fenêtre n'est plus un état de Tools — elle appartient au RUN qui l'a demandée (RunScope.grantFreeWindow, sous le verrou
    /// du RunScope). Un run vit dans UNE portée (conversation ou Dot, ExecContext) : ni un autre run, ni une autre conversation,
    /// ni un Dot, ni un fil sans run n'en hérite. Plus aucune fenêtre globale ni « hors-run ».
    static let apLock = NSLock()
    /// PHASE 1 (course réelle, portée sécurité) : la fenêtre est lue sous le même verrou que son écriture (celui du RunScope).
    static func freeWindowOpen() -> Bool { RunScope.current?.freeWindowOpen() ?? false }
    /// Appelé par /api/confirm : l'utilisateur a cliqué Autoriser / Refuser dans la fenêtre de Nova.
    /// WP5 (M) : la décision est LIÉE AU RUN qui l'a demandée (champ « run » de la demande). L'accord n'est consommable que par ce
    /// run ; « autoriser N min » (freeMinutes) ouvre une fenêtre pour CE run seulement ; `workspace` (dossier sous le dossier
    /// personnel, non sensible) ouvre un espace d'ingénierie pour ce run. Une demande sans run (route directe) garde l'ancien
    /// accord à usage unique, sans aucune fenêtre globale : plus rien n'est hérité par un autre run ou par un Dot.
    public static func decide(id: String, ok: Bool, freeMinutes: Int = 0, workspace: String? = nil) -> String {
        apLock.lock(); defer { apLock.unlock() }
        guard let p = pendingConfirm.removeValue(forKey: id), let cmd = p["cmd"] as? String else { return "Demande expirée." }
        DispatchQueue.global(qos: .utility).async { _ = AttentionNotif.refreshBadge() }   // 01/11 : pastille du Dock (hors verrou)
        GoDelais.note(created: p["ts"] as? String, ok: ok, kind: (p["kind"] as? String) ?? "")   // V5-P : délai jusqu'au GO, mesuré (Feat_Boucle.swift)
        // WP3-M : une demande posée par needConfirm porte sa PORTÉE (ExecContext : conversation ou Dot) ; WP5-M : et son RUN
        // (RunScope). L'accord n'est consommable que dans cette portée ET par ce run. Une demande sans portée (Tools.registerAsk,
        // lue par Feat_Chrono sous la clé brute) garde la clé historique.
        var extra = ""
        if ok {
            let scope: String? = p["scope"] as? String
            let runId: String? = p["run"] as? String
            let ak: String = approvalKey(cmd, run: runId)
            approved[scope.map { scopedKey($0, ak) } ?? ak] = Date()
            if let rid = runId, let scope = RunScope.find(rid) {
                if freeMinutes > 0 { scope.grantFreeWindow(minutes: freeMinutes); extra += " Fenêtre de \(min(freeMinutes, 240)) min pour CE run seulement." }
                if let ws = workspace, !ws.isEmpty {
                    if let root = engineeringRoot(ws) { scope.grantEngineering(root: root, minutes: freeMinutes > 0 ? freeMinutes : 60); extra += " Espace d'ingénierie : " + root + "." }
                    else { extra += " Espace d'ingénierie refusé (dossier absent, hors dossier personnel, sensible ou trop large)." }
                }
            } else if freeMinutes > 0 || (workspace ?? "") != "" { extra += " Aucune fenêtre ouverte : la demande n'est liée à aucun run actif." }
        }
        Tools.signalConfirm(id, ok: ok)   // LOT M : libère l'agent qui attend cette décision (carte de confirmation)
        return (ok ? "Autorisé." : "Refusé.") + extra
    }
    /// Clé d'un accord : liée au run quand la demande vient d'un run (aucun autre run ne peut la consommer).
    static func approvalKey(_ cmd: String, run: String?) -> String {
        let k = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = run, !r.isEmpty else { return k }
        return "run:" + r + "\u{1}" + k
    }
    /// Racine d'un espace d'ingénierie : dossier existant, résolu (liens suivis), STRICTEMENT sous le dossier personnel, non
    /// sensible, ni le dossier personnel lui-même ni l'un de ses dossiers de premier niveau trop larges (Library, Documents…).
    static func engineeringRoot(_ raw: String) -> String? {
        let home = PathPolicy.resolveExistingPrefix(NSHomeDirectory())
        let expanded = (raw as NSString).expandingTildeInPath
        guard let real = PathPolicy.realpathOrNil(expanded) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue else { return nil }
        guard PathPolicy.isInside(real, root: home), real != home, !isSensitivePath(real), !isSensitivePath(expanded) else { return nil }
        let rel = String(real.dropFirst(home.count + 1))
        if !rel.contains("/") && ["library", "documents", "desktop", "downloads", "applications", "pictures", "movies", "music", "public", "onedrive", "icloud drive"].contains(rel.lowercased()) { return nil }
        return real
    }
    /// nil = autorisé (déjà validé dans l'interface, à usage unique) ; sinon message pour le modèle et fenêtre de confirmation affichée à l'utilisateur.
    /// WP5 (M) : la demande porte l'identifiant du run courant (RunScope.current) ; seul ce run peut consommer l'accord.
    static func needConfirm(_ cmd: String, kind: String) -> String? {
        let key = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope: String = confirmScope()            // WP3-M : conversation ou Dot
        let runId: String? = RunScope.current?.id     // WP5-M : run
        let akey = scopedKey(scope, approvalKey(key, run: runId))
        apLock.lock()
        approved = approved.filter { Date().timeIntervalSince($0.value) < 300 }
        if approved.removeValue(forKey: akey) != nil { apLock.unlock(); return nil }
        var id = pendingConfirm.first(where: { ($0.value["cmd"] as? String) == key && ($0.value["scope"] as? String) == scope && ($0.value["run"] as? String) == runId })?.key; var fresh: [String: Any]? = nil
        if id == nil {
            let n = String(UUID().uuidString.prefix(6)).lowercased(); id = n
            var e: [String: Any] = ["id": n, "cmd": key, "kind": kind, "ts": nowISO(), "scope": scope]
            if let r = runId { e["run"] = r }
            pendingConfirm[n] = e; fresh = e
        }
        apLock.unlock()
        if let cid = id { Thread.current.threadDictionary["nova.confirm"] = cid }   // LOT M : l'agent retrouve la demande pour afficher sa carte et attendre
        if let e = fresh { confirmHook?(e) }
        return "CONFIRMATION REQUISE : une fenêtre demande à l'utilisateur d'autoriser cette \(kind) (« \(String(key.prefix(160))) »). Dis-le-lui en une phrase, attends qu'il clique, puis rappelle l'outil avec EXACTEMENT la même commande (écrire « CONFIRMÉ » ne sert à rien)."
    }
    /// LOT2 P-SEC1/P-SEC2 — filtre « fichier sensible » UNIQUE, aligné sur la liste stricte du pont (Bridge.swift:155)
    /// fusionnée avec l'ancienne liste de read_file (Tools.swift:447). Un chemin sensible n'est JAMAIS lu ni renvoyé à un cerveau.
    static func isSensitivePath(_ path: String) -> Bool {
        let low = path.lowercased()
        let base = (low as NSString).lastPathComponent
        let pathMarkers = ["/.ssh", "/.aws", "/.gnupg", "/.config/gcloud", "/library/keychains", "/.secrets", "/nova-finances", "/.session", "/.nova", "application support/nova", "blackbox.key", "bridge_devices.json",
                           "/.netrc", "/.config/gh/", "/.codex/", "/library/cookies", "/.bionic-tools"]   // V4-D (24/10) : jetons gh/codex, .netrc, cookies, outils bionic
        if pathMarkers.contains(where: { low.contains($0) }) { return true }
        if low.hasSuffix("/.config/gh") || low.hasSuffix("/.codex") || low.hasSuffix("/.bionic-tools") || base == ".netrc" { return true }   // V4-D : le dossier lui-même
        let baseMarkers = ["client_secret", "credentials", "secret", "token", "password", "passwd", "motdepasse", ".env", ".pem", ".key", ".p12", "id_rsa", "id_ed25519", "keychain", "passwords"]
        return baseMarkers.contains(where: { base.contains($0) })
    }
    /// LOT2 P-SEC2 : vrai si le TEXTE d'une commande shell mentionne un marqueur sensible (même famille de marqueurs, côté commande).
    static func shellMentionsSensitive(_ cmd: String) -> Bool {
        let low = cmd.lowercased()
        let markers = ["client_secret", "credentials", "secret", "token", "password", "passwd", "motdepasse", ".env", ".pem", ".key", ".p12", "id_rsa", "id_ed25519", "keychain", "blackbox.key", "bridge_devices", "/.ssh", "/.aws", "/.gnupg", "/.config/gcloud", "/library/keychains", "/.secrets", "/nova-finances",
                       ".netrc", "/.config/gh/", ".codex/", "/library/cookies", ".bionic-tools"]   // V4-D (24/10)
        return markers.contains(where: { low.contains($0) }) || low.hasSuffix("/.config/gh") || low.hasSuffix(".codex")
    }
    /// Liste blanche de LECTURE (WP5) : la commande est lue par ShellPolicy (lexique zsh strict + validation des arguments,
    /// utilitaire par utilitaire) — ce n'est PAS un bac à sable : c'est un filtre d'analyse ; ce qu'il ne sait pas lire est opaque
    /// et part en confirmation. `open` et `screencapture` ne sont plus des « lectures » (ils lancent des apps / capturent l'écran).
    static var safeShell: Set<String> { Set(ShellPolicy.fixedPaths.keys) }
    static func shellAssessment(_ cmd: String) -> ShellAssessment {
        let scope = RunScope.current
        return ShellPolicy.assess(cmd, home: NSHomeDirectory(), root: scope?.engineeringRoot(), sensitive: { Tools.isSensitivePath($0) })
    }
    static func shellSafe(_ cmd: String) -> Bool { shellAssessment(cmd).readOnly }
    /// Texte lu par les filtres (regex) : la commande brute ET sa forme déguillemetée (`cu''rl`, `s\endmail`, `~/.s"s"h`).
    static func shellFilterText(_ cmd: String) -> String { cmd + "\n" + shellAssessment(cmd).normalized }
    /// AppleScript qui exécute du shell ou du script dynamique : jamais levé par l'autorisation totale.
    static let scriptExecRx = try! NSRegularExpression(pattern: #"(do\s+shell\s+script|run\s+script|load\s+script|store\s+script|doShellScript|\bosascript\b)"#, options: .caseInsensitive)
    /// TRAVAIL EN ARRIÈRE-PLAN : Nova ne passe aucune app au premier plan sauf si la demande de l'utilisateur le dit (ouvre, affiche, montre, premier plan…).
    // Premier plan : jamais permanent. WP3-M (31/10) : vrai seulement pour le RUN où Ahadi l'a demandé explicitement
    // (« devant moi ») — porté par le contexte d'exécution du thread (ExecContext), plus par une fenêtre globale de 3 min :
    // un Dot (contexte propre), une autre conversation ou un thread sans contexte ne peut pas hériter du droit de passer devant.
    public static var frontAllowed: Bool {
        get { return ExecContext.current?.frontAllowed ?? false }
        set { ExecContext.current?.frontAllowed = newValue }
    }
    nonisolated(unsafe) static var lastMailSync = Date.distantPast   // synchronisation web des mails : au plus toutes les 10 min
    nonisolated(unsafe) public static var publishHook: ((String) -> Void)? = nil   // demande à l'interface (ex. « mailsync » : relire Outlook/Gmail/Teams web en arrière-plan)
    // Arrêts explicites de réponses en cours (par conversation) : une réponse continue en arrière-plan si l'on change simplement de conversation.
    nonisolated(unsafe) static var stopped: [String: Date] = [:]
    static let stopLock = NSLock()
    public static func stop(_ cid: String) { guard !cid.isEmpty else { return }; stopLock.lock(); stopped[cid] = Date(); stopLock.unlock() }
    public static func isStopped(_ cid: String, since t0: Date) -> Bool { stopLock.lock(); defer { stopLock.unlock() }; guard let d = stopped[cid] else { return false }; return d > t0 }
    public static func clearStop(_ cid: String) { stopLock.lock(); stopped[cid] = nil; stopLock.unlock() }
    public static let askFrontRx = try! NSRegularExpression(pattern: #"premier plan|devant (moi|mes yeux)|(affiche|montre|montrer|afficher|mets|met|amène|ramène)[- ](moi|le|la|les|le-moi|la-moi)\b[^.!?\n]{0,40}(écran|ecran|devant)|à l'écran|a l'ecran|fais-le devant|ouvre-moi[^.!?\n]{0,30}(écran|ecran)|prends? la main|je suis coinc|bloqu[ée] sur|continu\w* à ma place|fais\w* à ma place|contr[oô]le l['’ ]?[ée]cran"#, options: .caseInsensitive)
    /// WP3 (31/10) : l'ancienne fenêtre globale d'envoi (sendUntil / sendAllowed, ouverte 3 min par le simple verbe
    /// « envoie ») est SUPPRIMÉE. Un verbe d'envoi demande l'approbation ; l'approbation est liée à l'action exacte
    /// par SendApprovals (SendApproval.swift). askSendRx reste comme repère lexical.
    public static let askSendRx = try! NSRegularExpression(pattern: #"\benvoie(?![- ]moi\b)\b|\benvoyer\b|\benvoyez\b|\benvoie-le\b|\benvoie-la\b|\benvoie-lui\b|\bvas-y\b[^.!?\n]{0,24}\benvoi"#, options: .caseInsensitive)
    static let frontRx = try! NSRegularExpression(pattern: #"to (activate|reopen)\b|^\s*(activate|reopen)\s*$|frontmost|set visible|^\s*focus\||\bopen\s+(?!-[a-z]*[gj])-a\b"#, options: [.caseInsensitive, .anchorsMatchLines])
    static let safeScriptRx = try! NSRegularExpression(pattern: #"^\s*(set volume [^\n]*|get volume settings|tell application "[^"]+" to (activate|launch|reopen|get [^\n]*))\s*$"#, options: .caseInsensitive)
    static func match(_ rx: NSRegularExpression, _ t: String) -> Bool { rx.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil }
    /// Garde-fou des outils shell / AppleScript / raccourcis / écran. WP5 : ce sont des FILTRES (regex sur le texte brut ET
    /// déguillemeté, analyse des arguments par ShellPolicy) — pas un bac à sable. Ordre : refus durs (envoi, paiement, secret)
    /// → fichier sensible → risqué / exécution cachée → liste de lecture. L'autorisation totale (fullAuto) ne lève JAMAIS un
    /// envoi, un paiement, un secret, ni une commande opaque ou à exécution cachée (dont on ne peut pas lire l'effet).
    static func gate(_ raw: String, why: String, kind: String) -> (String, String?) {
        var cmd = raw
        if cmd.hasPrefix("CONFIRMÉ:") || cmd.hasPrefix("CONFIRME:") { cmd = String(cmd.drop(while: { $0 != ":" }).dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) }   // le mot n'autorise plus rien : seule la fenêtre de Nova valide
        let isShell: Bool = kind == "commande"
        let sa: ShellAssessment? = isShell ? shellAssessment(cmd) : nil
        let ft: String = sa.map { cmd + "\n" + $0.normalized } ?? cmd   // WP5 : les filtres lisent aussi la forme déguillemetée
        if !frontAllowed, match(frontRx, ft) { return (cmd, "Refusé : tu travailles en ARRIÈRE-PLAN. N'ouvre, n'active et ne passe AUCUNE app au premier plan (Teams, Outlook, Mail…) : l'utilisateur ne l'a pas demandé. Lis sans afficher : mail_week (mails reçus + envoyés), mail_unread, calendar, reminders, teams_read (volet Teams de Nova), notes, find. Si une app n'est pas lisible ainsi, dis-le en une ligne et continue le reste.") }
        if match(mailPayRx, ft) { return (cmd, "Refusé : envoi de messages et paiements sont réservés à l'utilisateur lui-même. Signale uniquement : brouillon possible sur demande (draft_reply seulement si Ahadi le demande explicitement).") }
        if match(sendEvasionRx, ft) && !loopbackCurlOnly(cmd) { return (cmd, "Refusé : envoi de messages et paiements sont réservés à l'utilisateur lui-même (envoi indirect détecté). Signale uniquement : brouillon possible sur demande (draft_reply seulement si Ahadi le demande explicitement).") }
        if match(forbiddenRx, ft) { return (cmd, "Refusé : secret (trousseau, clés, mots de passe), système profond ou dangereux par nature. Les mots de passe sont saisis par l'utilisateur.") }
        // LOT2 P-SEC2 : le shell ne contourne plus read_file — toute commande qui mentionne un chemin sensible exige la confirmation
        // dans l'interface, MÊME en autorisation totale. WP5 : chemins développés (~, $HOME), motifs glob étendus et liens
        // symboliques résolus (ShellPolicy.assess) : `cat ~/lien/config` vers ~/.ssh est vu comme sensible.
        if isShell, Tools.shellMentionsSensitive(ft) || !(sa?.sensitive.isEmpty ?? true) { if let m = needConfirm(cmd, kind: "accès à un fichier sensible") { return (cmd, m) }; return (cmd, nil) }
        // Substitution de commande dans une requête réseau : fuite de fichiers possible, jamais automatique.
        if (cmd.contains("$(") || cmd.contains("`")) && (ft.lowercased().contains("curl") || ft.lowercased().contains("wget")) { return (cmd, "Refusé : substitution de commande dans une requête réseau (fuite de données possible). Fais-le toi-même.") }
        // WP5 (L) : envoi réseau lu dans les ARGUMENTS (curl -d/-F/-T, git push, scp, rsync distant, nc…) : carte à chaque fois,
        // jamais levée par l'autorisation totale, une fenêtre ou un espace d'ingénierie.
        if let s = sa, s.effects.contains(.communication), !loopbackCurlOnly(cmd) { if let m = needConfirm(cmd, kind: "envoi réseau (commande)") { return (cmd, m) }; return (cmd, nil) }
        // Opaque (substitution, redirection, groupe…) ou exécution cachée (interpréteur, enveloppe, find -exec, awk system()…) :
        // effet illisible → ni l'autorisation totale ni une fenêtre ne le lèvent ; seul un espace d'ingénierie du run le peut.
        let opaqueOrHidden: Bool = isShell ? !(sa?.transparent ?? false) : (kind == "AppleScript" && match(scriptExecRx, cmd))
        let engRoot: String? = isShell ? RunScope.current?.engineeringRoot() : nil
        let inWorkspace: Bool = {
            guard let s = sa, engRoot != nil, s.analysable, s.outsideRoot.isEmpty, s.destructive.isEmpty, !s.effects.contains(.network), !s.effects.contains(.communication) else { return false }
            return true
        }()
        if match(riskyRx, ft) || match(indirectRx, ft) || !(sa?.destructive.isEmpty ?? true) {
            if fullAuto() && !match(catastrophicRx, ft) && !opaqueOrHidden && (sa?.destructive.isEmpty ?? true) { return (cmd, nil) }
            if let m = needConfirm(cmd, kind: kind) { return (cmd, m) }; return (cmd, nil)
        }
        let listed: Bool
        switch kind {
        case "commande": listed = sa?.readOnly ?? false
        case "AppleScript": listed = match(safeScriptRx, cmd)
        case "raccourci Apple": listed = false
        case "action d'écran":   // saisie, touches, clics et menus peuvent envoyer/payer/valider : toujours une confirmation dans Nova
            let act = (cmd.split(separator: "|", maxSplits: 1).first.map(String.init) ?? "").lowercased()
            listed = !["type", "key", "click", "menu"].contains(act)
            // autorisation permanente : saisie, clics, menus libres ; seule une touche Entrée/Retour (qui peut envoyer) reste confirmée
            if fullAuto() && !(act == "key" && cmd.lowercased().range(of: #"return|enter|retour|cmd\+shift\+d|⌘"#, options: .regularExpression) != nil) { return (cmd, nil) }
            if !listed { if let m = needConfirm(cmd, kind: kind) { return (cmd, m) }; return (cmd, nil) }
        default: listed = true
        }
        if !listed {
            if inWorkspace { return (cmd, nil) }   // WP5 (C) : espace d'ingénierie de CE run, chemins confinés, sans réseau
            let lifted: Bool = !opaqueOrHidden && (fullAuto() || (kind != "raccourci Apple" && (RunScope.current?.freeWindowOpen() ?? false)))
            if !lifted, let m = needConfirm(cmd, kind: opaqueOrHidden ? kind + " (effet illisible : " + opaqueReason(sa, cmd) + ")" : kind) { return (cmd, m) }
        }
        return (cmd, nil)
    }
    static func opaqueReason(_ sa: ShellAssessment?, _ cmd: String) -> String {
        guard let s = sa else { return "exécution de script" }
        return String(((s.parse.opaque + s.hiddenExec).first ?? "commande non analysable").prefix(90))
    }
    /// Plafonds du shell : durée, sortie (au-delà, le processus est arrêté), stderr (assaini).
    static let shellTimeout: TimeInterval = 30
    static let shellEngineeringTimeout: TimeInterval = 180
    static let shellMaxOutput: Int = 512 * 1024
    static func shell(_ raw: String, why: String) -> String {
        #if os(macOS)
        let (cmd, block) = gate(raw, why: why, kind: "commande"); if let b = block { return b }
        guard !cmd.isEmpty else { return "shell : commande vide." }
        if !Tools.frontAllowed, let url = Tools.webURLInCommand(cmd), let hook = Tools.pageHook, let r = hook("@navigateur " + url) {
            return "« open » d'une page web redirigé vers le volet Navigateur de Nova, en arrière-plan (le navigateur d'Ahadi n'est pas touché) :\n" + r
        }
        let scope: RunScope? = RunScope.current
        let home: String = NSHomeDirectory()
        let sa: ShellAssessment = shellAssessment(cmd)
        let root: String? = scope?.engineeringRoot()
        let timeout: TimeInterval = root != nil && !sa.readOnly ? shellEngineeringTimeout : shellTimeout
        let cancel: () -> Bool = { scope?.cancel() ?? false }
        // WP5 (A) : une lecture simple part SANS shell (exécutable de chemin fixe, arguments déjà développés) ; le reste passe par zsh.
        let r: BoundedResult
        if let argv = sa.argv { r = BoundedProcess.run(argv[0], Array(argv.dropFirst()), timeout: timeout, maxOutput: shellMaxOutput, cwd: home, cancel: cancel) }
        else { r = BoundedProcess.run("/bin/zsh", ["-c", cmd], timeout: timeout, maxOutput: shellMaxOutput, cwd: root ?? home, cancel: cancel) }
        let err: String = Knowledge.redact(BoundedProcess.sanitize(r.err, home: home))
        if let le = r.launchError { return "ÉCHEC : lancement impossible (\(le))." }
        if r.cancelled { return "ÉCHEC : commande annulée (arrêt du run) — processus et sous-processus arrêtés." }
        if r.timedOut { return "Délai dépassé (\(Int(timeout)) s) — commande interrompue, sous-processus compris." + (err.isEmpty ? "" : "\nstderr : " + err) }
        var o: String = (r.code == 0 ? "" : "(code \(r.code))\n") + String(r.out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(6000))
        if r.outTruncated { o += "\n[sortie tronquée : plafond de \(shellMaxOutput / 1024) Ko atteint, processus arrêté]" }
        if r.code != 0 && !err.isEmpty { o += "\nstderr : " + err }
        return o
        #else
        return "indisponible hors macOS"
        #endif
    }
    /// Lance en arrière-plan (open -g -j) les applications ciblées par « tell application "X" » qui ne tournent pas encore : un lancement via AppleScript les mettrait au premier plan.
    static func prelaunchHidden(_ script: String) {
        #if os(macOS)
        guard let rx = try? NSRegularExpression(pattern: #"tell (?:application|app) \\?"([^"\\]+)\\?""#, options: .caseInsensitive) else { return }
        let ns = script as NSString; var names: [String] = []
        for m in rx.matches(in: script, range: NSRange(location: 0, length: ns.length)) { let n: String = ns.substring(with: m.range(at: 1)); if !names.contains(n) { names.append(n) } }
        for n in names.prefix(4) {
            let running: Bool = NSWorkspace.shared.runningApplications.contains { ($0.localizedName ?? "") == n }
            if !running { _ = runProcess("/usr/bin/open", ["-g", "-j", "-a", n], timeout: 10); Thread.sleep(forTimeInterval: 1.5) }
        }
        #endif
    }
    static func applescript(_ raw: String, why: String) -> String {
        #if os(macOS)
        let (cmd, block) = gate(raw, why: why, kind: "AppleScript"); if let b = block { return b }
        let r = osa(cmd, timeout: 40); return r.out.isEmpty ? (r.ok ? "Fait." : "Échec.") : String(r.out.prefix(6000))
        #else
        return "indisponible hors macOS"
        #endif
    }
}
