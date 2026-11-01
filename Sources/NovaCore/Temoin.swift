import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif
#if canImport(AppKit) && canImport(ScreenCaptureKit) && canImport(Vision)
import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import Vision
#endif

/// Phase 7 — Vision écran (Témoin). Lit le TEXTE de la fenêtre au premier plan, uniquement à la demande explicite de l'utilisateur.
/// Garde-fous (tous voulus) :
///  - jamais de boucle ni de capture automatique : seule la route GET /api/temoin/vision?explicit=1 (clic sur « Analyser l'écran actif ») déclenche ;
///  - l'image reste en mémoire vive (CGImage), n'est JAMAIS écrite sur le disque, et est libérée dès l'OCR terminé ; seul le texte est renvoyé ;
///  - les fenêtres de Nova et les gestionnaires de mots de passe / trousseau sont exclus (aucune capture, même si la fenêtre est la 1re) ;
///  - sans l'autorisation macOS « Enregistrement de l'écran », on répond {ok:false, reason:"permission"} : l'utilisateur l'accorde lui-même
///    (Réglages Système › Confidentialité et sécurité), Nova ne la demande pas par détour ;
///  - les lignes qui ressemblent à un secret sont masquées (même nettoyage que la base de connaissances).
public enum Temoin {
    /// Identifiants de paquet jamais capturés (gestionnaires de mots de passe, trousseau, coffres).
    public static let excludedBundles: Set<String> = [
        "com.1password.1password", "com.1password.1password7", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx", "com.agilebits.onepassword4",
        "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.passwords", "com.apple.Passwords",
        "org.keepassxc.keepassxc", "org.keepassx.keepassx", "com.lastpass.lastpassmacdesktop", "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal", "com.dashlane.Dashlane", "in.sinew.Enpass-Desktop", "com.callpod.keepermac.lite",
        "com.nordsec.nordpass", "me.proton.pass.electron", "com.proton.pass", "com.apple.Passwords.PasswordsMenuBarExtra",
        "com.roboform.roboform", "com.stickypassword.StickyPassword", "com.logmeonce.logmeonce", "com.keepersecurity.keeper",
    ]
    /// Filet de sécurité sur le nom de l'application quand l'identifiant est inconnu.
    static let excludedNameFragments = ["1password", "bitwarden", "keychain", "trousseau", "keepass", "lastpass", "dashlane", "enpass", "nordpass", "mots de passe", "passwords"]
    static let ownBundles: Set<String> = ["com.ahadi.nova"]

    static let gate = NSLock()
    nonisolated(unsafe) static var lastCapture = Date.distantPast   // PHASE 1 (relu, protégé) : sous gate
    static let minInterval: TimeInterval = 2

    static func isExcluded(bundle: String, name: String) -> Bool {
        if excludedBundles.contains(bundle) || excludedBundles.contains(where: { $0.caseInsensitiveCompare(bundle) == .orderedSame }) { return true }
        let n = name.lowercased()
        return excludedNameFragments.contains(where: { n.contains($0) })
    }

    static let permissionMessage = "Autorisation « Enregistrement de l'écran » manquante pour Nova. Ouvre Réglages Système › Confidentialité et sécurité › Enregistrement de l'écran et coche Nova (puis relance Nova). Nova ne l'obtient pas toute seule : c'est à toi de l'accorder."

    /// Capture (en mémoire) la fenêtre au premier plan — hors Nova et hors apps exclues — et renvoie son texte OCR.
    /// Bloquant (quelques centaines de ms) : à appeler depuis un fil de fond, jamais depuis le fil principal.
    public static func captureActiveWindowContext(keepImage: Bool = false) -> [String: Any] {
        #if canImport(AppKit) && canImport(ScreenCaptureKit) && canImport(Vision)
        gate.lock()
        if Date().timeIntervalSince(lastCapture) < minInterval { gate.unlock(); return ["ok": false, "reason": "too_fast", "message": "Une analyse vient d'avoir lieu ; réessaie dans quelques secondes."] }
        lastCapture = Date(); gate.unlock()

        // Pas d'autorisation : on s'arrête ici (CGPreflight ne déclenche aucune boîte de dialogue).
        guard CGPreflightScreenCaptureAccess() else { return ["ok": false, "reason": "permission", "message": permissionMessage] }

        let t0 = Date()
        guard let target = pickWindow() else { return ["ok": false, "reason": "no_active_window", "message": "Aucune fenêtre d'application à analyser (Nova est seule au premier plan)."] }
        if target.excluded { return ["ok": false, "reason": "excluded", "app": target.app, "message": "Fenêtre exclue par confidentialité (gestionnaire de mots de passe / trousseau) : rien n'a été capturé."] }

        var image: CGImage? = nil
        var err = ""
        if #available(macOS 14.0, *) {
            let r = captureWithSCK(windowID: target.windowID, size: target.size)
            image = r.0; err = r.1
        }
        if image == nil { image = captureLegacy(windowID: target.windowID) }   // macOS 13 ou échec de ScreenCaptureKit (autorisation déjà vérifiée plus haut)
        guard let img = image else { return ["ok": false, "reason": "capture_failed", "app": target.app, "message": "Capture impossible" + (err.isEmpty ? "." : " : " + err)] }

        let raw = recognize(img)
        // V4-D (24/10) : vision multimodale — sur demande (keepImage), l'image est encodée en JPEG EN MÉMOIRE et confiée au
        // dépôt RAM de VisionInput (10 min, jamais écrite sur disque) ; le client ne reçoit qu'un identifiant à joindre au message.
        var imageId: String = ""
        var imageBytes: Int = 0
        if keepImage, let jpg = VisionInput.jpegData(img) {
            imageId = VisionInput.stash(jpg, media: "image/jpeg", label: target.app)
            imageBytes = jpg.count
        }
        image = nil   // l'image vit uniquement en mémoire vive le temps de l'OCR ; jamais écrite nulle part
        let (clean, masked) = Knowledge.scrub(raw)
        var text = clean
        let truncated = text.count > 6000
        if truncated { text = String(text.prefix(6000)) }
        var out: [String: Any] = ["ok": true, "app": target.app, "bundle": target.bundle, "windowTitle": target.title, "screenText": text,
                "chars": text.count, "masked": masked, "truncated": truncated, "ms": Int(Date().timeIntervalSince(t0) * 1000), "ts": nowISO()]
        if !imageId.isEmpty { out["image_id"] = imageId; out["image_bytes"] = imageBytes; out["image_ttl_s"] = Int(VisionInput.ttl) }
        else if keepImage { out["image_error"] = "encodage JPEG en mémoire impossible — seul le texte reconnu est disponible" }
        return out
        #else
        return ["ok": false, "reason": "unsupported", "message": "Vision écran indisponible sur cette plateforme (macOS requis)."]
        #endif
    }

    #if canImport(AppKit) && canImport(ScreenCaptureKit) && canImport(Vision)
    struct Target { let windowID: CGWindowID; let app: String; let bundle: String; let title: String; let size: CGSize; let excluded: Bool }

    /// 1re fenêtre ordinaire (calque 0, taille raisonnable) de l'ordre d'empilement, en sautant celles de Nova.
    /// Si cette fenêtre appartient à une app exclue, elle est renvoyée marquée « excluded » (on ne passe PAS à la suivante).
    static func pickWindow() -> Target? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        let myBundle = Bundle.main.bundleIdentifier ?? ""
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let num = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let ww = (b["Width"] as? NSNumber)?.doubleValue, let hh = (b["Height"] as? NSNumber)?.doubleValue, ww >= 200, hh >= 120 else { continue }
            let ownerName = (w[kCGWindowOwnerName as String] as? String) ?? ""
            let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            if pid == me || ownBundles.contains(bundle) || (!myBundle.isEmpty && bundle == myBundle) || ownerName == "Nova" { continue }   // jamais les fenêtres de Nova
            let ex = isExcluded(bundle: bundle, name: ownerName)
            return Target(windowID: num, app: ownerName, bundle: bundle, title: ex ? "" : ((w[kCGWindowName as String] as? String) ?? ""), size: CGSize(width: ww, height: hh), excluded: ex)
        }
        return nil
    }

    final class Box<T>: @unchecked Sendable { var v: T; init(_ v: T) { self.v = v } }

    @available(macOS 14.0, *)
    static func captureWithSCK(windowID: CGWindowID, size: CGSize) -> (CGImage?, String) {
        let box = Box<(CGImage?, String)>((nil, "délai dépassé"))
        let sem = DispatchSemaphore(value: 0)
        let scale = NSScreen.screens.map { $0.backingScaleFactor }.max() ?? 2
        Task.detached {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let win = content.windows.first(where: { $0.windowID == windowID }) else { box.v = (nil, "fenêtre introuvable"); sem.signal(); return }
                let filter = SCContentFilter(desktopIndependentWindow: win)
                let cfg = SCStreamConfiguration()
                let k = min(scale, 2800 / max(size.width, size.height, 1))   // borne la taille pour garder l'OCR rapide
                cfg.width = max(1, Int(size.width * k)); cfg.height = max(1, Int(size.height * k)); cfg.showsCursor = false
                let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                box.v = (img, "")
            } catch { box.v = (nil, error.localizedDescription) }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 8) == .timedOut { return (nil, "délai dépassé") }
        return box.v
    }

    /// CGWindowListCreateImage résolu dynamiquement : le symbole est obsolète/retiré des SDK récents, la liaison statique ferait échouer la compilation.
    static func captureLegacy(windowID: CGWindowID) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return nil }
        let f = unsafeBitCast(sym, to: Fn.self)
        // CGRect.null = fenêtre entière ; optionIncludingWindow = 1<<3 ; boundsIgnoreFraming = 1<<0
        return f(CGRect.null, 1 << 3, windowID, 1 << 0)?.takeRetainedValue()
    }

    /// Lecture d'une image (PNG/JPEG…) du dossier personnel : texte reconnu (OCR) + dimensions. Les cerveaux texte ([tiers]…) ne « voient » pas : l'OCR est leur œil.
    public static func ocrFile(_ path: String) -> String {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return "Image illisible (format non reconnu)." }
        let txt = Knowledge.scrub(recognize(img)).0.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = "Image \(img.width)×\(img.height) — lecture par reconnaissance de texte (je ne vois pas les couleurs ni les formes, seulement le texte affiché) :\n"
        return head + (txt.isEmpty ? "(aucun texte reconnu dans l'image)" : String(txt.prefix(7000)))
    }

    static func recognize(_ cg: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["fr-FR", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([req]) } catch { return "" }
        let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
        return obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    #endif
}

extension NovaApp {
    /// Routes Phase 7 + 8 (Témoin vision, Prédiction). Appelée une seule fois depuis extraRoutes().
    func visionPredictRoutes() {
        let s = server
        // Vision écran : UNIQUEMENT sur demande explicite (le bouton ajoute explicit=1). Rien ne l'appelle en boucle.
        s.on("GET", "/api/temoin/vision") { req, res in
            guard req.query["explicit"] == "1" else {
                res.json(["ok": false, "reason": "explicit_required", "message": "La lecture de l'écran n'est lancée que par un clic explicite (paramètre explicit=1)."]); return
            }
            let r = Temoin.captureActiveWindowContext(keepImage: req.query["image"] == "1")   // V4-D : image=1 → image gardée en RAM pour [tiers] (bouton « Voir mon écran »)
            // Trace de transparence : le fait qu'une analyse a eu lieu, jamais son contenu.
            Tools.actions.add(["tool": "temoin_vision", "actor": "Utilisateur", "why": "clic « Analyser l'écran actif »", "ok": (r["ok"] as? Bool) ?? false, "app": (r["app"] as? String) ?? ""])
            res.json(r)
        }
        // Prédiction : 3 prochaines actions probables (matrice de transitions d'ordre 2).
        s.on("GET", "/api/predict/next") { _, res in
            let f = SystemHooks.frontmostProvider?() ?? ("", "")
            Predict.shared.noteApp(name: f.0, bundle: f.1)
            res.json(Predict.shared.next(app: f.1.isEmpty ? f.0 : f.1))
        }
    }
}

/// V4-D (24/10) — VISION MULTIMODALE. Construit les blocs image [tiers]
/// {"type":"image","source":{"type":"base64","media_type":…,"data":…}} pour [tiers] ([tiers]/[tiers] via l'API [tiers]) :
///  - images jointes : uniquement des fichiers du dossier Attachments de Nova (déposés par POST /api/chat/upload) ;
///  - captures du Témoin : dépôt en MÉMOIRE VIVE (stash), 10 min au plus, 4 au plus, retirées dès qu'un message les utilise.
/// Formats : JPEG, PNG, GIF, WebP. Taille : au-delà de 3,7 Mo bruts ou 1 568 px de côté, l'image est réduite en JPEG
/// (ImageIO, en mémoire) ; si c'est impossible, refus nommé — jamais d'envoi tronqué.
public enum VisionInput {
    public static let maxRawBytes: Int = 3_700_000   // ≈ 5 Mo une fois en base64 (limite prudente par image)
    public static let maxSide: Int = 1568
    public static let maxImages: Int = 5
    public static let ttl: TimeInterval = 600
    static let mediaByExt: [String: String] = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp"]
    static let lock: NSLock = NSLock()
    nonisolated(unsafe) static var store: [String: (data: Data, media: String, label: String, at: Date)] = [:]

    public static func isImagePath(_ path: String) -> Bool { mediaByExt[(path as NSString).pathExtension.lowercased()] != nil }

    /// Dépose une image en mémoire ; rend son identifiant.
    public static func stash(_ data: Data, media: String, label: String) -> String {
        let id: String = "vis-" + String(UUID().uuidString.prefix(12)).lowercased()
        lock.lock(); defer { lock.unlock() }
        let now: Date = Date()
        store = store.filter { now.timeIntervalSince($0.value.at) < ttl }
        while store.count >= 4, let oldest = store.min(by: { $0.value.at < $1.value.at })?.key { store.removeValue(forKey: oldest) }
        store[id] = (data: data, media: media, label: label, at: now)
        return id
    }
    /// Retire une capture du dépôt (usage unique) ; nil si inconnue ou expirée.
    static func take(_ id: String) -> (data: Data, media: String, label: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let e = store.removeValue(forKey: id) else { return nil }
        if Date().timeIntervalSince(e.at) >= ttl { return nil }
        return (data: e.data, media: e.media, label: e.label)
    }

    static func block(_ data: Data, media: String) -> [String: Any] {
        let src: [String: Any] = ["type": "base64", "media_type": media, "data": data.base64EncodedString()]
        let b: [String: Any] = ["type": "image", "source": src]
        return b
    }

    #if canImport(ImageIO)
    /// JPEG en mémoire d'une image CoreGraphics, réduite à maxSide. nil si l'encodage échoue.
    public static func jpegData(_ cg: CGImage) -> Data? {
        let out: NSMutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.82]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let full: Data = out as Data
        if cg.width <= maxSide && cg.height <= maxSide && full.count <= maxRawBytes { return full }
        return shrink(full)
    }
    #endif

    /// Réduction en JPEG (côté max 1 568 px) — en mémoire. nil si l'image est illisible.
    static func shrink(_ data: Data) -> Data? {
        #if canImport(ImageIO)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxSide]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out: NSMutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        CGImageDestinationAddImage(dest, thumb, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let d: Data = out as Data
        return d.count <= maxRawBytes ? d : nil
        #else
        return nil
        #endif
    }

    /// Bloc image pour un fichier joint (dossier Attachments de Nova seulement). (bloc, libellé, motif du refus).
    public static func fileBlock(path: String) -> (block: [String: Any]?, label: String, error: String) {
        let url: URL = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let root: String = Paths.home.appendingPathComponent("Attachments").standardizedFileURL.resolvingSymlinksInPath().path
        let name: String = url.lastPathComponent
        guard url.path.hasPrefix(root + "/") else { return (nil, name, "hors du dossier des pièces jointes de Nova — refusé") }
        guard let media = mediaByExt[url.pathExtension.lowercased()] else { return (nil, name, "format non pris en charge (JPEG, PNG, GIF, WebP seulement)") }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return (nil, name, "fichier illisible") }
        if data.count <= maxRawBytes { return (block(data, media: media), name, "") }
        if let small = shrink(data) { return (block(small, media: "image/jpeg"), name, "") }
        return (nil, name, "image trop lourde (> 3,7 Mo) et réduction impossible")
    }

    /// Bloc image pour une capture du Témoin (usage unique).
    public static func stashedBlock(id: String) -> (block: [String: Any]?, label: String, error: String) {
        guard let e = take(id) else { return (nil, "capture d'écran", "capture expirée ou inconnue (10 min au plus) — relance « Voir mon écran »") }
        return (block(e.data, media: e.media), "capture d'écran · " + e.label, "")
    }
}
