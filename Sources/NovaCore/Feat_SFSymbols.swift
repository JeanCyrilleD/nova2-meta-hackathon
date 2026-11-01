import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// 30/10 (Ahadi : « les icônes et onglets font vieux, pas premium ») — les VRAIS SF Symbols d'Apple (ceux de macOS),
/// rendus par le système et servis à l'interface : GET /api/sf?n=<nom>&s=<taille px>&w=<poids>&f=1 (fill).
/// PNG noir sur transparent (2× la taille demandée), utilisé comme masque CSS → la couleur suit le texte (currentColor),
/// net à toutes les échelles. Cache mémoire. Aucun fichier installé, aucune licence embarquée : c'est le système qui dessine.
public enum SFSymbols {
    static let lock = NSLock()
    nonisolated(unsafe) static var cache: [String: Data] = [:]

    public static func png(name: String, size: Int, weight: String) -> Data? {
        #if canImport(AppKit)
        let key: String = name + "|" + String(size) + "|" + weight
        lock.lock(); if let d = cache[key] { lock.unlock(); return d }; lock.unlock()
        let w: NSFont.Weight
        switch weight {
        case "light": w = .light
        case "regular": w = .regular
        case "semibold": w = .semibold
        case "bold": w = .bold
        default: w = .medium
        }
        let px: CGFloat = CGFloat(max(8, min(256, size)))
        let scale: CGFloat = 2
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let conf = NSImage.SymbolConfiguration(pointSize: px * 0.82, weight: w)
        guard let img = base.withSymbolConfiguration(conf) else { return nil }
        let side: Int = Int(px * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let isz: NSSize = img.size
        let k: CGFloat = min(px / max(isz.width, 1), px / max(isz.height, 1), 1.0)
        let dw: CGFloat = isz.width * k, dh: CGFloat = isz.height * k
        let rect = NSRect(x: (px - dw) / 2, y: (px - dh) / 2, width: dw, height: dh)
        img.isTemplate = true
        img.draw(in: rect)
        NSColor.black.set()
        rect.fill(using: .sourceIn)
        NSGraphicsContext.restoreGraphicsState()
        guard let d = rep.representation(using: .png, properties: [:]) else { return nil }
        lock.lock(); cache[key] = d; lock.unlock()
        return d
        #else
        return nil
        #endif
    }
}

extension NovaApp {
    func sfSymbolRoutes() {
        server.on("GET", "/api/sf") { req, res in
            let n: String = String((req.query["n"] ?? "").prefix(80))
            guard !n.isEmpty, n.range(of: "^[a-z0-9.]+$", options: .regularExpression) != nil else { res.json(["error": "nom invalide"], status: 400); return }
            let s: Int = Int(req.query["s"] ?? "18") ?? 18
            let w: String = req.query["w"] ?? "medium"
            if let d = SFSymbols.png(name: n, size: s, weight: w) {
                res.data(d, type: "image/png", extra: ["Cache-Control": "max-age=86400"])
            } else {
                res.json(["error": "symbole inconnu : " + n], status: 404)
            }
        }
    }
}
