import Foundation

/// DIRECT-B (23/10, ordre d'Ahadi « A + B ») : lecture RÉELLE des corps des
/// messages du miroir Direct, sans aucune API externe.
///
/// Voie retenue — preuve de code. Le pont AppleEvents vers Mail.app existe
/// déjà dans le moteur et il est éprouvé : Tools.osa (Tools+System.swift)
/// lance Mail en arrière-plan si elle est fermée et exécute les scripts des
/// outils `mail_unread` / `mail_week` (lecture par listes de propriétés).
/// Feat_MailAPI.MailAPI ne sait PAS lire un corps : il ne couvre que la base
/// locale de l'app Outlook bureau et les caches Teams — et Gmail n'y existe
/// pas. Or les comptes Outlook/SCI ET Gmail sont synchronisés dans Mail.app
/// avec leurs corps (cartographie DIRECT-B, §1) : UN fetcher Mail.app couvre
/// les deux boîtes. La lecture directe des .emlx sous Accès complet au
/// disque (accordé à Nova le 22/10) reste le plan B documenté (§1.3 de la
/// cartographie), non implémentée.
///
/// Propriétés :
///  - AUCUN marquage lu : lire les propriétés d'un message par AppleScript
///    (sender / subject / content) ne change pas son « read status » — seul
///    l'affichage dans l'interface le fait (cartographie §1, état revérifié
///    inchangé sur le cas témoin). Aucun volet n'est touché non plus.
///  - Asynchrone : l'événement « faits » du lot A part immédiatement ;
///    l'enrichissement arrive en SECOND message du même événement via
///    ProactiveFeed.onEnriched — jamais en bloquant le flux.
///  - États honnêtes : trouvé + corps → « lu » ; trouvé + aucun texte
///    lisible (message protégé Purview/IRM, ou sans texte) → « protégé » ;
///    absent du magasin, Mail muet ou correspondance non vérifiée → AUCUN
///    enrichissement : l'événement garde l'état du lot A (« contenu non
///    lu ») et aucun tri n'est publié.
///  - Chaque tentative est tracée (webmail_resume_log.json, nature
///    « corps ») AVANT la persistance du résultat (discipline SPARK6 C4).
///  - Résilience (B-RÉSILIENCE, 23/10) : Mail.app ne répond que lorsque
///    son fil principal est libre (synchronisations du matin) — un essai
///    « Mail muet » n'est donc pas un échec définitif. Il part en
///    relance sur une file SÉPARÉE (la file principale n'est jamais
///    bloquée par l'attente), espacements croissants 2 min puis 5 min,
///    3 essais au total par message, chacun tracé avec son rang
///    (« essai n/3 ») et son motif. Les échecs déterministes
///    (introuvable, correspondance rejetée, réponse illisible, abandon)
///    ne sont PAS retentés. La clé reste dans `inflight` pendant toute
///    la fenêtre de relance : la déduplication couvre aussi les
///    relances. Épuisement = le message reste « contenu non lu »,
///    définitivement, sans aucun texte ajouté à l'événement. Relances
///    en mémoire : elles ne survivent pas à un redémarrage de l'app
///    (même sémantique d'abandon qu'avant ce lot — aucune régression).
///    FIXES-MAIL (24/10) : la voie PRINCIPALE est désormais le volet
///    web de Nova (Gmail / Outlook, hors écran) ; Mail.app n'est plus
///    qu'un dernier recours, tenté seulement s'il tourne déjà (jamais
///    lancé), avec un délai de 20 s au lieu de 60.
///  - Repli champs dégénérés (DIRECT-STYLE, 23/10) : la correspondance
///    stricte suppose un expéditeur et un objet sains. Quand les champs
///    du volet sont DÉGÉNÉRÉS (expéditeur réduit à la pastille avatar
///    — ≤ 1 caractère ou glyphes —, objet vide, ou objet égal au nom
///    d'expéditeur : la ligne décalée a rangé le nom en objet — cas
///    réel d'un expéditeur au prénom court, clos en « correspondance rejetée »),
///    le fetch bascule sur une recherche de REPLI dans le MÊME essai :
///    le nom complet est cherché là où la ligne l'a rangé, le message
///    est repéré par ce nom (et par l'objet cité en référence
///    « <<…>> » quand l'aperçu en porte une), et la garde décisive
///    RESTE la revérification historique : le fragment d'aperçu —
///    début du corps relevé au volet — doit se retrouver dans le
///    corps retourné. Chaque aboutissement trace la voie empruntée
///    (« voie repli » ; la voie stricte garde ses libellés et gagne le
///    suffixe « voie stricte » sur ses échecs terminaux). Les relances
///    B-RÉSILIENCE sont inchangées : le repli vit DANS l'essai, un
///    silence de Mail en repli part en relance comme un silence strict.
///  - Teams : le corps est le texte RENDU de la conversation, déjà extrait
///    par uibridge.js (messages rendus seulement — aucun clic, aucune
///    ouverture de fil, aucun accusé « Vu »).
///    25/10 (ordre d'Ahadi : « lire intégralement ») : les lignes de la LISTE
///    des conversations (objet « conversation », aperçu tronqué par Teams)
///    ne sont plus laissées sans corps — leur texte complet est cherché
///    LOCALEMENT (notifications macOS de Teams, puis cache de l'app Teams :
///    MailAPI.teamsFull), avec la même garde que Mail.app : l'aperçu relevé
///    au volet doit se retrouver dans le texte trouvé. Sans correspondance
///    vérifiée : aucun enrichissement (l'aperçu reste un aperçu).
public enum BodyFetcher {
    private static let queue = DispatchQueue(label: "nova.bodyfetch")
    /// File de relance SÉPARÉE (B-RÉSILIENCE) : les essais 2 et 3 y
    /// vivent ; ni leurs attentes (2 min / 5 min) ni leurs appels ne
    /// bloquent la file principale des premiers essais. Sérielle :
    /// deux relances ne frappent jamais Mail.app en même temps.
    private static let retryQueue = DispatchQueue(label: "nova.bodyfetch.retry")
    private static let lock = NSLock()
    private static var inflight = Set<String>()
    private static let bodiesFile = JSONFile("webmail_bodies.json")
    private static let bodyCap = 8000
    private static let excerptCap = 1500
    private static let bodiesCap = 300
    /// B-RÉSILIENCE : nombre TOTAL d'essais par message (essai initial
    /// + relances) et espacements — relanceDelais[0] avant l'essai 2,
    /// relanceDelais[1] avant l'essai 3.
    private static let maxTentatives = 3
    /// FIXES-MAIL (24/10) : relances plus courtes — la voie principale est désormais le
    /// volet web (réponse en quelques secondes), plus l'attente de Mail.app.
    private static let relanceDelais = [45, 180]
    /// FIXES-MAIL (24/10) : un seul pilotage de volet à la fois (file principale, file
    /// de relance et outil mail_corps se partagent les volets Gmail/Outlook).
    private static let paneGate = DispatchSemaphore(value: 1)
    /// FIXES-MAIL (24/10) : délai du dernier recours Mail.app (était 60 s) — et il n'est
    /// tenté QUE si Mail.app tourne déjà (jamais lancé ni activé par le pont).
    private static let mailAppTimeout: TimeInterval = 20

    /// Point d'entrée — appelé par WebMail.put (chemin structuré) pour les
    /// seuls messages émis en INDIVIDUEL. box : id du volet (« ol » |
    /// « gm » | « tm ») ; key : clé stable du message (WebMail.messageKey) ;
    /// eventId : id de l'événement du journal proactif à enrichir.
    public static func enqueue(box: String, key: String, item: WebMail.MailItem, eventId: String) {
        guard !eventId.isEmpty else { return }
        if box == "tm" {
            if item.objet != "message" {
                // 25/10 : ligne de la liste des conversations — texte complet cherché localement (file principale).
                queue.async { teamsConversation(key: key, item: item, eventId: eventId) }
                return
            }
            // Le corps Teams EST l'aperçu porté par l'item (texte rendu,
            // borné à 2 000 car. par uibridge.js pour « tm »).
            let body = item.apercu.trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.count >= 8 else { return }
            complete(box: box, key: key, eventId: eventId, outcome: .lu(body: body, via: "volet-rendu", repli: false))
            return
        }
        guard box == "ol" || box == "gm" else { return }
        lock.lock()
        if inflight.contains(key) { lock.unlock(); return }
        inflight.insert(key)
        lock.unlock()
        queue.async {
            attempt(box: box, key: key, item: item, eventId: eventId, n: 1)
        }
    }

    /// 25/10 : corps complet d'une ligne de conversation Teams, lu LOCALEMENT
    /// (notifications macOS de Teams, puis cache de l'app) — garde : l'aperçu
    /// de la liste doit se retrouver dans le texte trouvé (MailAPI.teamsFull).
    /// Introuvable : trace « corps-teams » (nature distincte : mail_corps ne
    /// la lit pas comme un état terminal) et AUCUN enrichissement.
    private static func teamsConversation(key: String, item: WebMail.MailItem, eventId: String) {
        if let s = storedBody(forKey: key) {
            complete(box: "tm", key: key, eventId: eventId, outcome: .lu(body: s.body, via: s.via, repli: false))
            return
        }
        let name: String = item.de.trimmingCharacters(in: .whitespacesAndNewlines)
        let apercu: String = item.apercu.trimmingCharacters(in: .whitespacesAndNewlines)
        // REPRISE TEAMS (26/10) : si la garde sur fragment echoue (volet deconnecte : l'apercu
        // est souvent un statut de presence, pas le message), repli par nom de conversation
        // dans les memes sources locales — le Direct reçoit alors le contenu reel, comme les mails.
        guard let hit = MailAPI.teamsFull(name: name, fragment: apercu) ?? MailAPI.teamsByName(name) else {
            WebMail.traceBody(box: "tm", nature: "corps-teams", contenu: "texte complet introuvable localement (notifications macOS / cache Teams) — aperçu de liste seul │ \(name)")
            return
        }
        let via: String = hit.source.contains("cache") ? "teams-cache" : "teams-notif"
        complete(box: "tm", key: key, eventId: eventId, outcome: .lu(body: hit.text, via: via, repli: false))
    }

    /// B-RÉSILIENCE : un essai de lecture Mail.app, de rang n sur
    /// maxTentatives. Succès, protégé et échecs déterministes concluent
    /// ici même (aboutissement par `complete`, inchangé). Un essai
    /// « Mail muet » (délai dépassé / aucune réponse) est tracé AVEC
    /// SON RANG puis, s'il reste des essais, reprogrammé sur la file
    /// de relance après l'espacement croissant — la clé RESTE dans
    /// `inflight` pendant toute la fenêtre (dédup continue : ni second
    /// fetch, ni doublon d'événement, ni second corps). Au dernier
    /// essai muet : trace d'épuisement, clé libérée, et le message
    /// reste « contenu non lu » — aucun enrichissement, aucun texte
    /// ajouté à l'événement.
    private static func attempt(box: String, key: String, item: WebMail.MailItem, eventId: String, n: Int) {
        // FIXES-MAIL (24/10) : corps déjà au magasin (lu entre-temps par l'outil
        // mail_corps, par exemple) → l'événement est enrichi avec lui, sans relire.
        if let s = storedBody(forKey: key) {
            finishKey(key)
            complete(box: box, key: key, eventId: eventId, outcome: .lu(body: s.body, via: s.via, repli: false), tentative: n)
            return
        }
        switch essai(box: box, item: item, tentative: n) {
        case .fini(let outcome):
            finishKey(key)
            complete(box: box, key: key, eventId: eventId, outcome: outcome, tentative: n)
        case .echec:
            finishKey(key)   // déjà tracé (fetchMailApp / essai) ; définitif, jamais retenté
        case .muet(let motif, let repli):
            // DIRECT-STYLE : la voie du fetch (stricte ou repli) est tracée
            // avec le rang quand l'essai part en relance ou s'épuise.
            let voie = repli ? " │ voie repli" : ""
            if n < maxTentatives {
                WebMail.traceBody(box: box, nature: "corps", contenu: "\(motif) — essai \(n)/\(maxTentatives), relance programmée │ \(item.de) │ \(item.objet)\(voie)")
                retryQueue.asyncAfter(deadline: .now() + .seconds(relanceDelais[n - 1])) {
                    attempt(box: box, key: key, item: item, eventId: eventId, n: n + 1)
                }
            } else {
                WebMail.traceBody(box: box, nature: "corps", contenu: "\(motif) — essai \(n)/\(maxTentatives), relances épuisées — laissé « contenu non lu » │ \(item.de) │ \(item.objet)\(voie)")
                finishKey(key)
                // FIXES-MAIL (24/10) : la carte du Fil direct cesse d'annoncer une
                // lecture « en cours » — état terminal « non lu » posé EN PLACE sur
                // l'événement (même carte, aucun doublon), avec le motif court.
                let motifCourt: String = String(motif.prefix(160))
                let updated: [String: Any]? = ProactiveFeed.updateEvent(id: eventId) { ev in
                    ev["body"] = "non lu"; ev["bodyMotif"] = motifCourt
                }
                if let ev = updated { ProactiveFeed.onEnriched?(ev, "") }
            }
        }
    }

    // ───────── FIXES-MAIL (24/10) : volet web d'abord, Mail.app en dernier recours ─────────

    private enum Essai { case fini(Outcome); case muet(motif: String, repli: Bool); case echec }
    private enum WebResult { case lu(body: String, via: String); case protege; case transitoire(motif: String); case absent(motif: String) }

    /// Corps protégé (Purview/IRM) : même règle pour toutes les voies.
    private static func estProtege(_ body: String) -> Bool {
        let low: String = body.lowercased()
        let purview: Bool = low.contains("message protégé") || low.contains("protected message") || low.contains("purview") || low.contains("a reçu un message protégé")
        return purview && body.count < 800
    }

    /// Mail.app tourne-t-il DÉJÀ ? (pgrep : ne lance rien, n'active rien.)
    static func mailAppRunning() -> Bool {
        let r: (Int32, String) = runProcess("/usr/bin/pgrep", ["-x", "Mail"], timeout: 3)
        return r.0 == 0
    }

    /// Lecture du corps par le volet web de Nova (Gmail : fetch même origine de la
    /// source / vue impression ; Outlook : volet de lecture du volet caché), via le
    /// pont d'interface (UIPilot → uibridge.js « page / corps »). Arrière-plan strict :
    /// le volet reste hors écran, aucune app n'est mise au premier plan.
    private static func fetchWebPane(box: String, item: WebMail.MailItem) -> WebResult {
        guard box == "gm" || box == "ol" else { return .absent(motif: "boîte sans volet web") }
        let pane: String = box == "gm" ? "gmail" : "outlook"
        if paneGate.wait(timeout: .now() + 40) == .timedOut {
            return .transitoire(motif: "volet \(pane) occupé par une autre lecture")
        }
        defer { paneGate.signal() }
        let args: [String: Any] = ["pane": pane, "sub": "corps", "de": item.de, "objet": item.objet, "apercu": String(item.apercu.prefix(300))]
        guard let r: [String: Any] = UIPilot.shared.request("page", args, timeout: 35) else {
            return .transitoire(motif: "volet \(pane) injoignable (fenêtre de Nova sans réponse)")
        }
        let ok: Bool = (r["ok"] as? Bool) ?? false
        if !ok {
            let code: String = (r["code"] as? String) ?? ""
            let err: String = String(((r["erreur"] as? String) ?? "échec sans motif").prefix(200))
            if code == "introuvable" || code == "boite" { return .absent(motif: "volet \(pane) : \(err)") }
            return .transitoire(motif: "volet \(pane) : \(err)")
        }
        let body: String = ((r["corps"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let viaRaw: String = (r["via"] as? String) ?? pane
        let via: String = "volet-" + viaRaw
        if body.count < 10 || estProtege(body) { return .protege }
        return .lu(body: body, via: via)
    }

    /// Un essai complet : volet web, puis Mail.app SEULEMENT s'il tourne déjà.
    private static func essai(box: String, item: WebMail.MailItem, tentative: Int) -> Essai {
        let rang: String = " — essai \(tentative)/\(maxTentatives)"
        var motifWeb: String = ""
        var webTransitoire: Bool = false
        switch fetchWebPane(box: box, item: item) {
        case .lu(let body, let via):
            return .fini(.lu(body: body, via: via, repli: false))
        case .protege:
            return .fini(.protege(repli: false))
        case .transitoire(let m):
            motifWeb = m; webTransitoire = true
        case .absent(let m):
            motifWeb = m
        }
        // Trace intermédiaire sous une nature distincte (« corps-volet ») : mail_corps
        // ne lit que la nature « corps » pour l'état terminal.
        WebMail.traceBody(box: box, nature: "corps-volet", contenu: "\(motifWeb)\(rang) │ \(item.de) │ \(item.objet)")
        if !mailAppRunning() {
            return .muet(motif: "\(motifWeb) ; Mail.app fermé — dernier recours non lancé", repli: false)
        }
        switch fetchMailApp(box: box, item: item, tentative: tentative) {
        case .lu(let body, let repli):
            return .fini(.lu(body: body, via: "mailapp", repli: repli))
        case .protege(let repli):
            return .fini(.protege(repli: repli))
        case .echec:
            return webTransitoire ? .muet(motif: "\(motifWeb) ; Mail.app sans correspondance", repli: false) : .echec
        case .muet(let m, let repli):
            return .muet(motif: "\(motifWeb) ; \(m)", repli: repli)
        }
    }

    /// FIXES-MAIL (24/10) : lecture IMMÉDIATE pour l'outil mail_corps (synchrone,
    /// ≤ ~40 s, volet web seul — Mail.app reste la voie différée de requestFetch).
    /// Succès : corps persisté au magasin et, si eventId nomme un événement du
    /// journal, la carte du Fil direct est enrichie EN PLACE. ok=false : motif.
    public static func fetchNow(box: String, item: WebMail.MailItem, eventId: String) -> (ok: Bool, body: String, via: String, motif: String) {
        guard box == "gm" || box == "ol" else { return (false, "", "", "boîte sans volet web") }
        guard let key = WebMail.stableKey(for: item) else { return (false, "", "", "ni expéditeur ni objet exploitables") }
        if let s = storedBody(forKey: key) { return (true, s.body, s.via, "") }
        switch fetchWebPane(box: box, item: item) {
        case .lu(let body, let via):
            complete(box: box, key: key, eventId: eventId.isEmpty ? "outil:mail_corps" : eventId, outcome: .lu(body: body, via: via, repli: false))
            return (true, body, via, "")
        case .protege:
            complete(box: box, key: key, eventId: eventId.isEmpty ? "outil:mail_corps" : eventId, outcome: .protege(repli: false))
            return (false, "", "", "message protégé — corps non lisible (Purview/IRM)")
        case .transitoire(let m):
            return (false, "", "", m)
        case .absent(let m):
            return (false, "", "", m)
        }
    }

    /// Libère la clé de déduplication — uniquement à la résolution
    /// TERMINALE du message (succès, protégé, échec définitif ou
    /// relances épuisées), jamais entre deux essais d'une même séquence.
    private static func finishKey(_ key: String) {
        lock.lock(); inflight.remove(key); lock.unlock()
    }

    private enum FetchResult { case lu(body: String, repli: Bool); case protege(repli: Bool); case muet(motif: String, repli: Bool); case echec }
    private enum Outcome { case lu(body: String, via: String, repli: Bool); case protege(repli: Bool) }

    // ───────── Mail.app (AppleEvents) ─────────

    /// Assainit une chaîne pour un littéral AppleScript (patron de
    /// Feat_MailAPI.outlookAppleScript : jamais d'échappée maison).
    private static func asaClean(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func normText(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Retire les préfixes de réponse/transfert en tête (« RE: », « Fwd: »…).
    private static func stripSubjectPrefixes(_ s: String) -> String {
        var t = s
        while let r = t.range(of: #"^\s*(re|fw|fwd)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            t = String(t[r.upperBound...])
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Correspondance d'objets : égalité normalisée ou préfixe dans un sens
    /// ou dans l'autre (les volets tronquent parfois l'objet affiché).
    private static func subjectMatches(_ a: String, _ b: String) -> Bool {
        let x = normText(stripSubjectPrefixes(a))
        let y = normText(stripSubjectPrefixes(b))
        if x.isEmpty || y.isEmpty { return true }
        return x == y || x.hasPrefix(y) || y.hasPrefix(x)
    }

    /// DIRECT-STYLE (23/10) : un scalaire est-il un glyphe d'icône (zone
    /// privée — le contenu d'une pastille avatar ou d'une icône de ligne) ?
    private static func estGlyphe(_ v: UInt32) -> Bool { v >= 0xE000 && v <= 0xF8FF }

    /// DIRECT-STYLE (23/10) : champs du volet DÉGÉNÉRÉS — la correspondance
    /// stricte (expéditeur + objet) ne peut pas aboutir : objet vide ;
    /// expéditeur réduit à la pastille avatar (≤ 1 caractère, ou glyphes
    /// seuls) ; objet égal au nom d'expéditeur (la ligne décalée a rangé
    /// le nom en objet).
    private static func champsDegeneres(de: String, objet: String) -> Bool {
        let d = de.trimmingCharacters(in: .whitespacesAndNewlines)
        let o = objet.trimmingCharacters(in: .whitespacesAndNewlines)
        if o.isEmpty { return true }
        if d.count <= 1 { return true }
        if !d.isEmpty && d.unicodeScalars.allSatisfy({ estGlyphe($0.value) }) { return true }
        if !d.isEmpty && normText(d) == normText(o) { return true }
        return false
    }

    /// DIRECT-STYLE (23/10) : éléments exploitables de l'aperçu d'une ligne
    /// dégénérée — l'objet du courriel cité en référence « <<…>> » (lignes
    /// de rappel Outlook) et le fragment de corps : l'aperçu débarrassé de
    /// la référence et du jeton d'heure qui la suit, c'est-à-dire le début
    /// du corps tel que le volet l'a relevé. Sans référence, le fragment
    /// est l'aperçu entier et l'objet candidat est vide.
    private static func elementsApercu(_ apercu: String) -> (objet: String, fragment: String) {
        var a = apercu.trimmingCharacters(in: .whitespacesAndNewlines)
        var objet = ""
        if let r1 = a.range(of: "<<"), let r2 = a.range(of: ">>", range: r1.upperBound..<a.endIndex) {
            objet = String(a[r1.upperBound..<r2.lowerBound]).trimmingCharacters(in: .whitespaces)
            a = String(a[r2.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let m = a.range(of: #"^\d{1,2}:\d{2}\s+"#, options: .regularExpression) {
                a = String(a[m.upperBound...])
            }
        }
        return (objet: objet, fragment: a)
    }

    /// Cherche le message dans Mail.app (tous comptes, boîtes de réception,
    /// 300 plus récents par boîte — lecture par listes comme mail_week) et
    /// lit son corps. Correspondance : expéditeur ET objet ; le résultat
    /// est revérifié en Swift (objet retourné + fragment d'aperçu présent
    /// dans le corps) avant d'être cru. DIRECT-STYLE (23/10) : si les
    /// champs du volet sont dégénérés, la recherche bascule sur le repli
    /// (fetchRepli) avant tout script — la voie stricte ci-dessous ne
    /// voit que des champs sains.
    private static func fetchMailApp(box: String, item: WebMail.MailItem, tentative: Int) -> FetchResult {
        // B-RÉSILIENCE : suffixe de rang apposé aux traces terminales
        // quand l'aboutissement conclut une séquence de relances
        // (l'essai 1 garde les libellés historiques, à l'identique).
        let rang = tentative > 1 ? " — essai \(tentative)/\(maxTentatives)" : ""
        let deRaw = item.de.trimmingCharacters(in: .whitespacesAndNewlines)
        let suRaw = item.objet.trimmingCharacters(in: .whitespacesAndNewlines)
        // DIRECT-STYLE : champs dégénérés → recherche de repli, dans le
        // MÊME essai (les relances B-RÉSILIENCE s'appliquent à son résultat
        // comme à celui de la voie stricte).
        if champsDegeneres(de: deRaw, objet: suRaw) {
            return fetchRepli(box: box, item: item, deRaw: deRaw, suRaw: suRaw, rang: rang)
        }
        // Aiguille expéditeur : l'adresse si elle est présente, sinon le nom affiché.
        var needle = deRaw
        if deRaw.contains("@") {
            let toks = deRaw.split(whereSeparator: { " <>\"'".contains($0) }).map(String.init)
            if let em = toks.first(where: { $0.contains("@") }) { needle = em }
        }
        needle = asaClean(needle)
        var core = suRaw
        while core.hasSuffix("…") || core.hasSuffix("...") {
            core = String(core.dropLast(core.hasSuffix("...") ? 3 : 1))
        }
        let subj = asaClean(core)
        let apercu = item.apercu.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty || (subj.isEmpty && apercu.count < 20) {
            WebMail.traceBody(box: box, nature: "corps", contenu: "abandon — ni expéditeur exploitable ni objet/aperçu\(rang) : \(deRaw) │ \(suRaw) │ voie stricte")
            return .echec
        }
        // Condition objet omise si l'objet est vide (l'aperçu revérifie seul).
        let condSubj = subj.isEmpty ? "" : " and ((su is \"\(subj)\") or (su starts with \"\(subj)\") or (\"\(subj)\" starts with su))"
        let script = """
        tell application "Mail"
            set sep to (ASCII character 30)
            repeat with a in accounts
                try
                    set mb to first mailbox of a whose name is "INBOX" or name is "Inbox" or name is "Boîte de réception"
                    set n to count of messages of mb
                    set topN to 300
                    if n < topN then set topN to n
                    if topN > 0 then
                        set ss to sender of messages 1 thru topN of mb
                        set subs to subject of messages 1 thru topN of mb
                        repeat with i from 1 to topN
                            set s to item i of ss
                            set su to item i of subs
                            if (s contains "\(needle)")\(condSubj) then
                                set m to message i of mb
                                set c to ""
                                try
                                    set c to content of m
                                end try
                                if c is missing value then set c to ""
                                return "FOUND" & sep & su & sep & c
                            end if
                        end repeat
                    end if
                end try
            end repeat
            return "NOTFOUND"
        end tell
        """
        let r = Tools.osa(script, timeout: mailAppTimeout)
        if !r.ok {
            // « Mail muet » : PAS de trace ici — le pilote d'essai
            // (attempt) trace avec le rang et programme la relance.
            // FIXES-MAIL (24/10) : délai ramené à 20 s (mailAppTimeout).
            return .muet(motif: "mailapp sans réponse — \(FeedText.shortReason(r.out))", repli: false)
        }
        if r.out == "NOTFOUND" || !r.out.hasPrefix("FOUND") {
            WebMail.traceBody(box: box, nature: "corps", contenu: "introuvable dans Mail.app\(rang) │ \(deRaw) │ \(suRaw) │ voie stricte")
            return .echec
        }
        let parts = r.out.components(separatedBy: "\u{1E}")
        guard parts.count >= 3 else {
            WebMail.traceBody(box: box, nature: "corps", contenu: "réponse Mail.app illisible\(rang) │ \(deRaw) │ \(suRaw) │ voie stricte")
            return .echec
        }
        let foundSubject = parts[1]
        let body = parts[2...].joined(separator: "\u{1E}").trimmingCharacters(in: .whitespacesAndNewlines)
        // Revérification 1 : l'objet retourné doit correspondre à l'objet du volet.
        if !subjectMatches(foundSubject, suRaw) {
            WebMail.traceBody(box: box, nature: "corps", contenu: "correspondance rejetée — objet retourné différent (« \(foundSubject) »)\(rang) │ \(deRaw) │ \(suRaw) │ voie stricte")
            return .echec
        }
        // Revérification 2 : l'aperçu du volet est le début du corps — il doit s'y retrouver.
        if apercu.count >= 20 {
            let frag = normText(String(apercu.prefix(40)))
            let frag25 = normText(String(apercu.prefix(25)))
            let nb = normText(body)
            if !frag.isEmpty && !nb.contains(frag) && (frag25.isEmpty || !nb.contains(frag25)) {
                WebMail.traceBody(box: box, nature: "corps", contenu: "correspondance rejetée — aperçu absent du corps\(rang) │ \(deRaw) │ \(suRaw) │ voie stricte")
                return .echec
            }
        }
        if body.count < 10 {
            return .protege(repli: false)   // trouvé, mais aucun texte : protégé (Purview/IRM) ou sans corps texte
        }
        let low = body.lowercased()
        let purview = low.contains("message protégé") || low.contains("protected message") || low.contains("purview") || low.contains("a reçu un message protégé")
        if purview && body.count < 800 { return .protege(repli: false) }
        return .lu(body: body, repli: false)
    }

    /// DIRECT-STYLE (23/10) : recherche de REPLI pour champs dégénérés.
    /// L'expéditeur du volet étant inutilisable comme aiguille, le nom
    /// complet est cherché là où la ligne l'a rangé : dans le champ objet
    /// quand l'expéditeur est une pastille, dans le champ expéditeur
    /// sinon. Le script renvoie jusqu'à 3 candidats (objet + corps) dont
    /// l'expéditeur contient ce nom — et dont l'objet correspond à la
    /// référence « <<…>> » quand l'aperçu en porte une. La garde décisive
    /// a lieu en Swift et c'est LA MÊME que la voie stricte : le fragment
    /// d'aperçu (le début du corps relevé au volet) doit se retrouver
    /// dans le corps retourné ; aucun candidat ne la passe → rejet, tracé
    /// avec la voie. Un silence de Mail en repli est un .muet comme un
    /// autre : le pilote d'essai le met en relance, inchangé.
    private static func fetchRepli(box: String, item: WebMail.MailItem, deRaw: String, suRaw: String, rang: String) -> FetchResult {
        let apercu = item.apercu.trimmingCharacters(in: .whitespacesAndNewlines)
        let el = elementsApercu(apercu)
        let deExploitable = deRaw.count >= 3 && !deRaw.unicodeScalars.allSatisfy({ estGlyphe($0.value) })
        let needle = asaClean(deExploitable ? deRaw : suRaw)
        let frag = normText(String(el.fragment.prefix(40)))
        let frag25 = normText(String(el.fragment.prefix(25)))
        if needle.isEmpty || frag.count < 20 {
            WebMail.traceBody(box: box, nature: "corps", contenu: "abandon — repli impossible (nom ou fragment d'aperçu inexploitable)\(rang) │ \(deRaw) │ \(suRaw) │ voie repli")
            return .echec
        }
        var core = el.objet
        while core.hasSuffix("…") || core.hasSuffix("...") {
            core = String(core.dropLast(core.hasSuffix("...") ? 3 : 1))
        }
        let subjRef = asaClean(core)
        // Condition objet omise si l'aperçu ne porte aucune référence.
        let condSubj = subjRef.isEmpty ? "" : " and ((su is \"\(subjRef)\") or (su starts with \"\(subjRef)\") or (\"\(subjRef)\" starts with su))"
        let script = """
        tell application "Mail"
            set sep to (ASCII character 30)
            set usep to (ASCII character 31)
            set trouves to ""
            set nb to 0
            repeat with a in accounts
                if nb > 2 then exit repeat
                try
                    set mb to first mailbox of a whose name is "INBOX" or name is "Inbox" or name is "Boîte de réception"
                    set n to count of messages of mb
                    set topN to 300
                    if n < topN then set topN to n
                    if topN > 0 then
                        set ss to sender of messages 1 thru topN of mb
                        set subs to subject of messages 1 thru topN of mb
                        repeat with i from 1 to topN
                            if nb > 2 then exit repeat
                            set s to item i of ss
                            set su to item i of subs
                            if (s contains "\(needle)")\(condSubj) then
                                set m to message i of mb
                                set c to ""
                                try
                                    set c to content of m
                                end try
                                if c is missing value then set c to ""
                                if (count of c) > 9000 then set c to (text 1 thru 9000 of c)
                                set trouves to trouves & su & sep & c & usep
                                set nb to nb + 1
                            end if
                        end repeat
                    end if
                end try
            end repeat
            if nb is 0 then return "NOTFOUND"
            return "FOUND" & sep & trouves
        end tell
        """
        let r = Tools.osa(script, timeout: mailAppTimeout)
        if !r.ok {
            return .muet(motif: "mailapp sans réponse — \(FeedText.shortReason(r.out))", repli: true)
        }
        if r.out == "NOTFOUND" || !r.out.hasPrefix("FOUND") {
            WebMail.traceBody(box: box, nature: "corps", contenu: "introuvable dans Mail.app\(rang) │ \(deRaw) │ \(suRaw) │ voie repli")
            return .echec
        }
        // Charge utile : après « FOUND » + séparateur — candidats séparés
        // par le caractère 31, chacun « objet » + séparateur 30 + corps.
        let payload = String(r.out.dropFirst(6))
        let candidats = payload.components(separatedBy: "\u{1F}").filter { !$0.isEmpty }
        for cand in candidats {
            let parts = cand.components(separatedBy: "\u{1E}")
            guard parts.count >= 2 else { continue }
            let body = parts[1...].joined(separator: "\u{1E}").trimmingCharacters(in: .whitespacesAndNewlines)
            // Garde décisive (identique à la revérification 2 de la voie
            // stricte) : le fragment d'aperçu doit se retrouver dans le corps.
            let nb2 = normText(body)
            guard nb2.contains(frag) || (!frag25.isEmpty && nb2.contains(frag25)) else { continue }
            if body.count < 10 { return .protege(repli: true) }
            let low = body.lowercased()
            let purview = low.contains("message protégé") || low.contains("protected message") || low.contains("purview") || low.contains("a reçu un message protégé")
            if purview && body.count < 800 { return .protege(repli: true) }
            return .lu(body: body, repli: true)
        }
        WebMail.traceBody(box: box, nature: "corps", contenu: "correspondance rejetée — aperçu absent du corps\(rang) │ \(deRaw) │ \(suRaw) │ voie repli")
        return .echec
    }

    // ───────── Aboutissement ─────────

    /// Trace AVANT persistance (discipline C4), persiste le corps borné (si
    /// lu), met à jour l'événement du journal (champs body*), puis prévient
    /// App via ProactiveFeed.onEnriched — le second message du Fil direct.
    private static func complete(box: String, key: String, eventId: String, outcome: Outcome, tentative: Int = 1) {
        // B-RÉSILIENCE : quand l'aboutissement conclut une relance, la
        // trace de résolution porte le rang de l'essai gagnant (l'essai
        // 1 garde les libellés historiques, à l'identique).
        let rang = tentative > 1 ? " — essai \(tentative)/\(maxTentatives)" : ""
        switch outcome {
        case .lu(let body, let via, let repli):
            // DIRECT-STYLE : la voie de lecture est tracée quand c'est le repli.
            WebMail.traceBody(box: box, nature: "corps", contenu: "lu (\(via), \(body.count) car.)\(rang)\(repli ? " — voie repli" : "") │ \(key)")
            lock.lock()
            var all = bodiesFile.read(default: [String: [String: Any]]())
            all[key] = ["body": String(body.prefix(bodyCap)), "len": body.count, "via": via, "ts": nowISO(), "event": eventId]
            if all.count > bodiesCap {
                let keep = all.sorted { (($0.value["ts"] as? String) ?? "") > (($1.value["ts"] as? String) ?? "") }.prefix(bodiesCap)
                all = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            bodiesFile.write(all)
            lock.unlock()
            let excerpt = String(body.prefix(excerptCap))
            let updated = ProactiveFeed.updateEvent(id: eventId) { ev in
                ev["body"] = "lu"; ev["bodyVia"] = via; ev["bodyExcerpt"] = excerpt
            }
            if let ev = updated { ProactiveFeed.onEnriched?(ev, body) }
        case .protege(let repli):
            WebMail.traceBody(box: box, nature: "corps", contenu: "protégé — corps non lisible\(rang)\(repli ? " — voie repli" : "") │ \(key)")
            let updated = ProactiveFeed.updateEvent(id: eventId) { ev in
                ev["body"] = "protégé"
            }
            if let ev = updated { ProactiveFeed.onEnriched?(ev, "") }
        }
    }

    // ───────── VÉRITÉ-MAGASIN (23/10) : consultation du magasin ─────────
    // Lecture seule + déclenchement : ces fonctions BRANCHENT la
    // consultation sur les mécanismes prouvés (attempt/complete/traces)
    // sans y toucher. Avant ce lot, l'acteur conversationnel n'avait
    // AUCUN chemin vers webmail_bodies.json : ses seuls accès à un corps
    // étaient les volets web (page-lire/page-clic), dont l'échec devenait
    // « corps inaccessible » alors même que le pont avait déjà lu et
    // persisté le corps (cas Plan International, 23/10 : corps lu par le
    // pont à 10:53:41, « analyse impossible » déclaré à 11:21).

    /// Corps persisté pour une clé stable, s'il existe.
    public static func storedBody(forKey key: String) -> (body: String, via: String, ts: String)? {
        lock.lock(); defer { lock.unlock() }
        let all = bodiesFile.read(default: [String: [String: Any]]())
        guard let e = all[key], let b = e["body"] as? String else { return nil }
        return (b, (e["via"] as? String) ?? "", (e["ts"] as? String) ?? "")
    }

    /// Recherche de corps persistés par fragments d'expéditeur et/ou
    /// d'objet (les clés portent de│objet│aperçu, normalisés). Au plus 5
    /// résultats, le plus récent d'abord.
    public static func searchStored(de: String, objet: String) -> [(key: String, body: String, via: String, ts: String)] {
        let dq = normText(de); let oq = normText(objet)
        if dq.isEmpty && oq.isEmpty { return [] }
        lock.lock(); defer { lock.unlock() }
        let all = bodiesFile.read(default: [String: [String: Any]]())
        var hits: [(key: String, body: String, via: String, ts: String)] = []
        for (k, e) in all {
            let parts = k.components(separatedBy: "│")
            guard parts.count >= 2, let b = e["body"] as? String else { continue }
            let kd = parts[0]; let ko = parts[1]
            let deOK = dq.isEmpty || kd.contains(dq) || dq.contains(kd)
            let obOK = oq.isEmpty || ko.contains(oq) || oq.contains(ko)
            if deOK && obOK { hits.append((k, b, (e["via"] as? String) ?? "", (e["ts"] as? String) ?? "")) }
        }
        return Array(hits.sorted { $0.ts > $1.ts }.prefix(5))
    }

    /// 25/10 : corps persisté pour un ÉVÉNEMENT du Fil direct (champ « event »
    /// du magasin) — sert la lecture complète depuis la carte (GET /api/mail/corps).
    public static func storedBody(forEvent id: String) -> (body: String, via: String, ts: String)? {
        if id.isEmpty { return nil }
        lock.lock(); defer { lock.unlock() }
        let all = bodiesFile.read(default: [String: [String: Any]]())
        for (_, e) in all {
            guard (e["event"] as? String) == id, let b = e["body"] as? String else { continue }
            return (b, (e["via"] as? String) ?? "", (e["ts"] as? String) ?? "")
        }
        return nil
    }

    /// 25/10 : corps TEAMS persistés (voies volet-rendu / teams-notif / teams-cache) dont l'expéditeur
    /// (partie « de » de la clé) et/ou le TEXTE contiennent la requête — l'objet d'un item Teams n'est
    /// qu'un type (« message », « conversation ») : la requête « objet » est cherchée dans le corps.
    public static func searchStoredTeams(de: String, texte: String) -> [(key: String, body: String, via: String, ts: String)] {
        let dq = normText(de); let tq = normText(texte)
        if dq.isEmpty && tq.isEmpty { return [] }
        lock.lock(); defer { lock.unlock() }
        let all = bodiesFile.read(default: [String: [String: Any]]())
        var hits: [(key: String, body: String, via: String, ts: String)] = []
        for (k, e) in all {
            let via: String = (e["via"] as? String) ?? ""
            guard via == "volet-rendu" || via.hasPrefix("teams-"), let b = e["body"] as? String else { continue }
            let kd: String = k.components(separatedBy: "│").first ?? ""
            let nb: String = normText(b)
            let deOK: Bool = dq.isEmpty || kd.contains(dq) || nb.contains(dq)
            let txOK: Bool = tq.isEmpty || nb.contains(tq)
            if deOK && txOK { hits.append((k, b, via, (e["ts"] as? String) ?? "")) }
        }
        return Array(hits.sorted { $0.ts > $1.ts }.prefix(5))
    }

    /// Une récupération est-elle en cours (essai ou fenêtre de relance)
    /// pour cette clé ? La clé reste dans inflight pendant TOUTE la
    /// séquence B-RÉSILIENCE, relances comprises.
    public static func isInflight(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inflight.contains(key)
    }

    /// Déclenche la récupération d'un corps connu mais pas encore lu
    /// (message repéré au journal Direct ou dans les traces, jamais émis
    /// en individuel — donc jamais passé par enqueue). Réutilise attempt/
    /// complete à l'identique ; l'eventId technique « outil:mail_corps »
    /// ne correspond à aucun événement du journal : updateEvent rend nil,
    /// aucun second message n'est composé — mais le corps est persisté
    /// et la tentative tracée, comme pour un arrivage. Retourne l'état.
    public static func requestFetch(box: String, item: WebMail.MailItem) -> String {
        guard let key = WebMail.stableKey(for: item) else { return "récupération impossible à cibler : ni expéditeur ni objet exploitables" }
        if storedBody(forKey: key) != nil { return "corps déjà au magasin" }
        if box == "tm" {
            // 25/10 : texte complet local d'abord (notifications / cache Teams, garde sur l'aperçu).
            if let hit = MailAPI.teamsFull(name: item.de, fragment: item.apercu) {
                let via: String = hit.source.contains("cache") ? "teams-cache" : "teams-notif"
                complete(box: box, key: key, eventId: "outil:mail_corps", outcome: .lu(body: hit.text, via: via, repli: false))
                return "corps Teams persisté au magasin depuis \(hit.source) (texte complet local, vérifié contre l'aperçu) — réinterroge mail_corps"
            }
            let body = item.apercu.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.objet == "conversation" {
                // 25/10 : une ligne de LISTE n'est qu'un aperçu tronqué par Teams — jamais persistée comme corps.
                let ap: String = String(body.prefix(300))
                return "seul l'APERÇU de la liste Teams est connu (texte complet introuvable dans les notifications et le cache Teams du Mac) — aperçu : « \(ap) »"
            }
            guard body.count >= 8 else { return "texte Teams rendu trop court pour tenir lieu de corps" }
            complete(box: box, key: key, eventId: "outil:mail_corps", outcome: .lu(body: body, via: "volet-rendu", repli: false))
            return "corps Teams persisté au magasin depuis le texte rendu du volet"
        }
        guard box == "ol" || box == "gm" else { return "boîte inconnue pour le pont : \(box)" }
        lock.lock()
        if inflight.contains(key) { lock.unlock(); return "récupération déjà en cours (relances B-RÉSILIENCE actives)" }
        inflight.insert(key)
        lock.unlock()
        queue.async { attempt(box: box, key: key, item: item, eventId: "outil:mail_corps", n: 1) }
        return "récupération déclenchée en arrière-plan (volet web puis Mail.app s'il est ouvert ; essai 1/\(maxTentatives), relances automatiques à 45 s puis 3 min) — le corps arrivera au magasin, réinterroge mail_corps ensuite"
    }
}
