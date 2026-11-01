import Foundation

/// OUTLOOK LOCAL (Chantier 5, 26/10/2026 — Muse Code) : lecture LOCALE et
/// STRICTEMENT LECTURE SEULE d'Outlook pour Mac, pour compléter mail_pj
/// (qui ne couvre aujourd'hui que Gmail et Zoho).
///
/// Constats vérifiés sur ce Mac le 26/10/2026 :
/// - Le profil vit dans ~/Library/Group Containers/UBF8T346G9.Office/Outlook/
///   « Outlook 15 Profiles/Main Profile » (~269 Mo).
/// - L'ancienne base Outlook.sqlite (452 Ko, avril 2026) a sa table Mail VIDE :
///   le nouvel Outlook stocke les corps dans HxStore.hxd (format propriétaire).
/// - MAIS les pièces jointes sont des fichiers ordinaires, lisibles tels quels :
///   Files/S0/<store>/Attachments/0/Nom[recordID].ext — 104 PDF relevés.
/// Ce fichier fait donc ce qui est faisable sans contourner quoi que ce soit :
/// inventorier les pièces jointes et en extraire le texte (PDF via pdftotext
/// s'il est présent). Il n'écrit RIEN, ne touche à aucun état Outlook, ne peut
/// donc rien marquer comme lu. Le corps des messages (HxStore) reste hors de
/// portée de cette voie ; le branchement dans mail_pj est demandé à [tiers]
/// (dormant/DEMANDES_POUR_CLAUDE.md, D4).
/// Accès disque : si macOS refuse la lecture (Accès complet au disque non
/// accordé à Nova), `inventory()` renvoie une liste vide et `accessState()`
/// dit « refusé » — jamais de faux contenu.
public enum OutlookLocal {
    public struct Attachment: Codable {
        public var name: String        // nom nettoyé (sans le [recordID])
        public var recordID: String    // identifiant entre crochets, "" si absent
        public var path: String        // chemin complet (lecture seule)
        public var size: Int
        public var modified: Date
        public var ext: String
    }

    /// Racine du profil Outlook (premier « Main Profile » trouvé).
    public static func profileRoot() -> URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles")
        // Candidat direct d'abord : dans l'app, lister le conteneur de groupe peut être
        // refusé (TCC) alors que le chemin exact reste joignable — ou l'inverse.
        let direct = base.appendingPathComponent("Main Profile")
        if FileManager.default.fileExists(atPath: direct.appendingPathComponent("Files").path) { return direct }
        guard let profiles = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return nil }
        for name in profiles.sorted() {
            let p = base.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: p.appendingPathComponent("Files").path) { return p }
        }
        return nil
    }

    /// État d'accès réel, sans rien lire d'autre que la liste des dossiers.
    public static func accessState() -> String {
        guard let root = profileRoot() else { return "profil_absent" }
        // Honnêteté d'accès : exister ne suffit pas — il faut pouvoir LISTER Files/S0.
        // Dans l'app sans « Accès complet au disque », macOS refuse en silence :
        // on le dit (« refuse ») au lieu d'annoncer un inventaire vide comme un fait.
        if (try? FileManager.default.contentsOfDirectory(atPath: accPath(root).path)) != nil { return "ok" }
        return "refuse"
    }

    private static func accPath(_ root: URL) -> URL { root.appendingPathComponent("Files/S0") }

    /// Inventaire des pièces jointes (fichiers sous Files/S0/<store>/Attachments).
    /// Tri : plus récentes d'abord. Aucune écriture, aucune ouverture d'Outlook.
    public static func inventory(limit: Int = 200) -> [Attachment] {
        guard let root = profileRoot() else { return [] }
        let fm = FileManager.default
        let s0 = accPath(root)
        guard let stores = try? fm.contentsOfDirectory(atPath: s0.path) else { return [] }
        var out: [Attachment] = []
        for store in stores {
            let attRoot = s0.appendingPathComponent(store).appendingPathComponent("Attachments")
            guard let subs = try? fm.contentsOfDirectory(atPath: attRoot.path) else { continue }
            for sub in subs {
                let dir = attRoot.appendingPathComponent(sub)
                guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                for f in files {
                    let full = dir.appendingPathComponent(f)
                    let vals = try? full.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                    guard vals?.isRegularFile == true else { continue }
                    var name = f; var rid = ""
                    if let m = f.range(of: #"\[(\d+)\]"#, options: .regularExpression) {
                        rid = String(f[m].dropFirst().dropLast())
                        name = f.replacingCharacters(in: m, with: "").trimmingCharacters(in: .whitespaces)
                    }
                    out.append(Attachment(name: name, recordID: rid, path: full.path,
                                          size: vals?.fileSize ?? 0,
                                          modified: vals?.contentModificationDate ?? .distantPast,
                                          ext: (f as NSString).pathExtension.lowercased()))
                }
            }
        }
        return Array(out.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    /// Texte d'une pièce jointe PDF (pdftotext -layout si présent). Pour les
    /// autres formats : nil explicite — jamais de texte inventé.
    public static func pdfText(_ a: Attachment, maxChars: Int = 20000) -> String? {
        guard a.ext == "pdf" else { return nil }
        for exe in ["/opt/homebrew/bin/pdftotext", "/usr/local/bin/pdftotext", "/usr/bin/pdftotext"] where FileManager.default.isExecutableFile(atPath: exe) {
            let (code, out) = runProcess(exe, ["-layout", a.path, "-"], timeout: 30)
            if code == 0 && !out.isEmpty { return String(out.prefix(maxChars)) }
        }
        return nil
    }

    /// Recherche par mot-clé sur les noms de pièces jointes (rapide, sans extraction).
    public static func search(_ q: String, limit: Int = 50) -> [Attachment] {
        let needle = q.lowercased()
        return Array(inventory(limit: 1000).filter { $0.name.lowercased().contains(needle) }.prefix(limit))
    }
}
