import Foundation

// CHANTIER 3-A · VOIX CONVERSATIONNELLE ÉTAPE 1 — « conversation inspectable »
// (ordre du 27/10/2026). Nouveau fichier autonome : il ne modifie NI
// Feat_VoiceLive.swift NI web/js/voice.js. Il se branche sur le pipeline
// EXISTANT (transcriptions partielles/finales déjà publiées par la dictée
// native et par VoiceLive sur le bus « voix_dictee » / « voix_live ») et
// n'ajoute AUCUNE voie cloud : aucun appel réseau ici, aucun moteur nouveau —
// les moteurs actuels de Nova (dictée Apple, [tiers], [tiers], replis
// locaux) restent seuls maîtres de l'audio.
//
// Ce que ce module garantit, côté logique pure (testable sans micro) :
//  1. Transcription affichée en direct ET relisible avant exécution : un tour
//     utilisateur passe par l'état « enAttenteRelecture » ; il n'est JAMAIS
//     exécuté tant que `validerTour(_:)` n'a pas été appelé explicitement.
//  2. Barge-in logiciel : `interrompre(motCle:)` coupe la parole en cours
//     (état du tour Nova → « interrompu ») ; `motDeclencheur(_:)` reconnaît
//     les mots-clés parlés (« stop », « arrête », « attends », « nova stop »…)
//     dans un partiel de transcription. Le bouton d'interruption de l'écran
//     appelle la même fonction — une seule voie d'arrêt.
//  3. File des tours consultable : `file()` rend chaque tour avec son texte
//     intermédiaire (partiel le plus récent), son texte final et son état ;
//     rien n'est exécuté ni effacé implicitement.
//  4. Réglage « voix_conversation » : DÉFAUT INACTIF. Tant qu'il vaut false,
//     `demarrerTour` refuse nommément et la file reste vide — le comportement
//     historique de Nova est inchangé.
//
// Branchement restant (à faire par le parent, hors périmètre de ce chantier) :
// relayer les événements bus « voix_dictee »/« voix_live » vers
// `majPartiel`/`cloreTourUtilisateur`, et n'envoyer le texte au chat qu'après
// `validerTour`. Voir la demande précise en tête de Feat_VoixConversation
// dans le rapport du chantier (unresolved) si ce branchement exige de
// toucher Feat_VoiceLive.swift.

/// État d'un tour de conversation inspectable.
public enum TourConversationEtat: String {
    case ecoute          // transcription en cours (partiels qui arrivent)
    case enAttenteRelecture // texte final reçu, EN ATTENTE de relecture/validation
    case valide          // relu et validé → peut être exécuté
    case rejete          // relu et rejeté → ne sera jamais exécuté
    case execute         // envoyé au pipeline (après validation seulement)
    case interrompu      // parole de Nova coupée par barge-in sur ce tour
}

/// Un tour de la file : texte intermédiaire consultable à tout moment.
public struct TourConversation {
    public let id: Int
    public let auteur: String            // "utilisateur" ou "nova"
    public var texteIntermediaire: String // dernier partiel affiché en direct
    public var texteFinal: String         // texte clos ("" tant que le tour écoute)
    public var etat: TourConversationEtat
    public let creeLe: Date
    public var majLe: Date
}

/// File des tours + portes d'exécution de la conversation inspectable.
/// Thread-safe (file d'attente série interne). Aucun effet réseau.
public final class VoixConversation {
    public static let shared = VoixConversation()
    public static let reglCle = "voix_conversation"
    /// Mots-clés de barge-in parlé (minuscules, sans accent significatif).
    public static let motsBargeIn = ["stop", "arrête", "arrete", "attends", "nova stop", "tais-toi", "silence"]

    private let q = DispatchQueue(label: "nova.voixconversation")
    private var tours: [TourConversation] = []
    private var prochainId = 1
    private var parConversation: [String: Int] = [:]   // 27/10 : rattachement tour <-> fil de conversation (porte du chat)
    private let horloge: () -> Date

    /// Rattache un tour à un fil de conversation (porte de relecture du chat vocal).
    public func lierConversation(id: Int, cid: String) { q.sync { parConversation[cid] = id } }

    /// Le tour en attente de relecture de ce fil, s'il existe.
    public func tourEnAttente(cid: String) -> TourConversation? {
        q.sync {
            guard let id = parConversation[cid], let t = tours.first(where: { $0.id == id }),
                  t.etat == .enAttenteRelecture else { return nil }
            return t
        }
    }

    /// Oublie le rattachement d'un fil (tour exécuté, rejeté ou remplacé).
    public func delier(cid: String) { q.sync { parConversation[cid] = nil } }

    public init(horloge: @escaping () -> Date = { Date() }) { self.horloge = horloge }

    /// Le réglage fait foi : inactif par défaut (défaut `false` explicite).
    public static func estActif(_ settings: Settings) -> Bool {
        settings.get(reglCle, false)
    }

    /// Ouvre un tour utilisateur en écoute. Refus NOMMÉ si le réglage est fermé.
    @discardableResult
    public func demarrerTour(actif: Bool) -> (ok: Bool, raison: String, id: Int?) {
        q.sync {
            guard actif else {
                return (false, "mode « conversation inspectable » inactif : active le réglage « \(Self.reglCle) » pour l'utiliser", nil)
            }
            let t = TourConversation(id: prochainId, auteur: "utilisateur", texteIntermediaire: "",
                                     texteFinal: "", etat: .ecoute, creeLe: horloge(), majLe: horloge())
            prochainId += 1
            tours.append(t)
            return (true, "", t.id)
        }
    }

    /// Met à jour le texte intermédiaire AFFICHÉ EN DIRECT (jamais exécuté).
    public func majPartiel(id: Int, texte: String) {
        q.sync {
            guard let i = tours.firstIndex(where: { $0.id == id }), tours[i].etat == .ecoute else { return }
            tours[i].texteIntermediaire = texte
            tours[i].majLe = horloge()
        }
    }

    /// Clôt la transcription d'un tour : il passe en relecture, PAS en exécution.
    public func cloreTourUtilisateur(id: Int, texteFinal: String) {
        q.sync {
            guard let i = tours.firstIndex(where: { $0.id == id }), tours[i].etat == .ecoute else { return }
            tours[i].texteFinal = texteFinal
            if tours[i].texteIntermediaire.isEmpty { tours[i].texteIntermediaire = texteFinal }
            tours[i].etat = .enAttenteRelecture
            tours[i].majLe = horloge()
        }
    }

    /// Relecture explicite : seul chemin vers l'exécution.
    @discardableResult
    public func validerTour(id: Int) -> Bool {
        q.sync {
            guard let i = tours.firstIndex(where: { $0.id == id }), tours[i].etat == .enAttenteRelecture,
                  !tours[i].texteFinal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            tours[i].etat = .valide
            tours[i].majLe = horloge()
            return true
        }
    }

    @discardableResult
    public func rejeterTour(id: Int) -> Bool {
        q.sync {
            guard let i = tours.firstIndex(where: { $0.id == id }), tours[i].etat == .enAttenteRelecture else { return false }
            tours[i].etat = .rejete
            tours[i].majLe = horloge()
            return true
        }
    }

    /// Marque un tour validé comme exécuté (appelé par l'appelant APRÈS envoi réel).
    @discardableResult
    public func marquerExecute(id: Int) -> Bool {
        q.sync {
            guard let i = tours.firstIndex(where: { $0.id == id }), tours[i].etat == .valide else { return false }
            tours[i].etat = .execute
            tours[i].majLe = horloge()
            return true
        }
    }

    /// Texte exécutable d'un tour : non vide UNIQUEMENT s'il a été validé.
    public func texteExecutable(id: Int) -> String? {
        q.sync {
            guard let t = tours.first(where: { $0.id == id }), t.etat == .valide else { return nil }
            return t.texteFinal
        }
    }

    /// Enregistre un tour de parole de Nova (pour pouvoir l'interrompre).
    @discardableResult
    public func demarrerTourNova(texte: String) -> Int {
        q.sync {
            let t = TourConversation(id: prochainId, auteur: "nova", texteIntermediaire: texte,
                                     texteFinal: texte, etat: .valide, creeLe: horloge(), majLe: horloge())
            prochainId += 1
            tours.append(t)
            return t.id
        }
    }

    /// Barge-in logiciel : bouton OU mot-clé — même fonction, même effet.
    /// Coupe le dernier tour Nova non terminé ; retourne son id (nil si rien à couper).
    @discardableResult
    public func interrompre() -> Int? {
        q.sync {
            guard let i = tours.lastIndex(where: { $0.auteur == "nova" && $0.etat != .interrompu && $0.etat != .execute }) else { return nil }
            tours[i].etat = .interrompu
            tours[i].majLe = horloge()
            return tours[i].id
        }
    }

    /// Le texte entendu contient-il un mot-clé de barge-in ? (comparaison simple)
    public static func motDeclencheur(_ texte: String) -> String? {
        let t = texte.lowercased()
        return motsBargeIn.first { t.contains($0) }
    }

    /// File complète, consultable : partiels, finaux et états, dans l'ordre.
    public func file() -> [TourConversation] { q.sync { tours } }

    /// Vue sérialisable de la file (pour un futur écran / diagnostic, sans audio).
    public func fileJSON() -> [[String: Any]] {
        file().map { t in
            ["id": t.id, "auteur": t.auteur, "etat": t.etat.rawValue,
             "texte_intermediaire": t.texteIntermediaire, "texte_final": t.texteFinal]
        }
    }

    public func vider() { q.sync { tours.removeAll() } }
}

// MARK: - Branchement chat (27/10, parent) : porte de relecture des messages vocaux
//
// Principe : le réglage « voix_conversation » actif, un message du chat marqué
// vocal (voice: true) n'est JAMAIS exécuté tel quel. Il devient un tour en
// attente de relecture ; Nova affiche la transcription dans le fil même
// (« Voici ce que j'ai entendu… ») et le tour suivant tranche :
//   - validation (« valide », « go », « ok », « envoie », « oui »…) → le texte
//     relu est exécuté comme demande de ce tour ;
//   - annulation (« annule », « laisse tomber », « non »…) → tour rejeté ;
//   - tout autre texte → c'est la correction : elle remplace la transcription
//     et s'exécute comme demande de ce tour.
// Le barge-in partage la même fonction des deux côtés : le bouton/mot-clé de
// l'écran appelle /api/voix-conversation/interrompre (ici) ET l'arrêt moteur
// existant (/api/voix-live/interrompre, web/js/voice.js).

extension VoixConversation {
    /// Mots de validation d'une relecture (message court, comparaison simple).
    public static func estValidation(_ texte: String) -> Bool {
        let t: String = texte.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 40 { return false }
        return ["valide", "valider", "go", "ok", "okay", "envoie", "envoyer", "oui", "vas-y", "vasy", "parfait", "c'est ça", "correct", "exact"].contains(t)
    }

    /// Mots d'annulation d'une relecture (message court seulement : « annule le vol de
    /// demain et réserve le suivant » est une correction, pas une annulation).
    public static func estAnnulation(_ texte: String) -> Bool {
        let t: String = texte.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 25 { return false }
        return ["annule", "annuler", "laisse tomber", "laisse", "non", "stop", "oublie", "abandonne"].contains { t == $0 || t.hasPrefix($0 + " ") }
    }
}

extension NovaApp {
    func voixConversationRoutes() {
        let s = server
        let vc = VoixConversation.shared
        s.on("GET", "/api/voix-conversation") { [self] _, res in
            res.json(["actif": VoixConversation.estActif(settings), "file": vc.fileJSON()])
        }
        s.on("POST", "/api/voix-conversation/valider") { req, res in
            let id: Int = (req.json["id"] as? Int) ?? 0
            if vc.validerTour(id: id), let t: String = vc.texteExecutable(id: id) {
                _ = vc.marquerExecute(id: id)
                res.json(["ok": true, "texte": t])
            } else {
                res.json(["ok": false, "erreur": "tour introuvable ou non validable"], status: 409)
            }
        }
        s.on("POST", "/api/voix-conversation/rejeter") { req, res in
            let id: Int = (req.json["id"] as? Int) ?? 0
            res.json(["ok": vc.rejeterTour(id: id)])
        }
        s.on("POST", "/api/voix-conversation/interrompre") { _, res in
            res.json(["ok": true, "tour": vc.interrompre() ?? -1])
        }
    }
}
