import Foundation

/// Phase 8 — Prédiction temporelle d'ordre 2 : (tranche horaire, app au premier plan, action précédente) -> action suivante.
/// Apprend à partir du journal d'actions réel (Tools.actions) ; l'app au premier plan est reconstituée depuis un petit historique
/// d'échantillons (nom/identifiant seulement, jamais de contenu). Tout reste en local (predict_matrix.json via JSONFile), rien n'est envoyé.
/// Repli (backoff) : contexte exact, puis sans app, puis action précédente seule, puis tranche + app seules.
public final class Predict: @unchecked Sendable {
    public static let shared = Predict()

    private let store = JSONFile("predict_matrix.json")
    private let lock = NSLock()
    private var m: [String: [String: Int]] = [:]
    private var samples: [(t: Double, app: String)] = []
    private var lastTs: Double = 0
    private var prev = "-"
    private var loaded = false

    public init() {}

    // MARK: contexte
    public static func slot(_ d: Date) -> String {
        switch Calendar.current.component(.hour, from: d) {
        case 6..<12: return "matin"
        case 12..<14: return "midi"
        case 14..<18: return "apres-midi"
        case 18..<23: return "soir"
        default: return "nuit"
        }
    }
    static func keyExact(_ s: String, _ a: String, _ p: String) -> String { "\(s)|\(a)|\(p)" }
    static func keyNoApp(_ s: String, _ p: String) -> String { "\(s)|*|\(p)" }
    static func keyPrevOnly(_ p: String) -> String { "*|*|\(p)" }
    static func keyNoPrev(_ s: String, _ a: String) -> String { "\(s)|\(a)|*" }

    // MARK: persistance
    private func loadLocked() {
        if loaded { return }
        loaded = true
        let o = store.read(default: [String: Any]())
        if let mm = o["m"] as? [String: Any] {
            for (k, v) in mm { if let d = v as? [String: Any] { m[k] = d.compactMapValues { ($0 as? NSNumber)?.intValue } } }
        }
        if let ss = o["samples"] as? [[Any]] {
            samples = ss.compactMap { r in
                guard r.count == 2, let t = (r[0] as? NSNumber)?.doubleValue, let a = r[1] as? String else { return nil }
                return (t, a)
            }
        }
        lastTs = (o["lastTs"] as? NSNumber)?.doubleValue ?? 0
        prev = (o["prev"] as? String) ?? "-"
    }
    private func saveLocked() {
        if m.count > 4000 {   // élagage : on garde les contextes les mieux documentés
            let keep = m.sorted { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }.prefix(3000)
            m = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        store.write(["m": m, "samples": samples.suffix(600).map { [$0.t, $0.app] as [Any] }, "lastTs": lastTs, "prev": prev])
    }

    // MARK: observation
    /// Mémorise l'app au premier plan (appelée par la lentille contextuelle et par /api/predict/next).
    public func noteApp(name: String, bundle: String) {
        let a = bundle.isEmpty ? name : bundle
        if a.isEmpty { return }
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        let now = Date().timeIntervalSince1970
        if let l = samples.last, l.app == a, now - l.t < 30 { return }
        samples.append((now, a))
        if samples.count > 600 { samples.removeFirst(samples.count - 600) }
    }

    private func appAt(_ t: Double) -> String {
        var best = "?"
        for s in samples where s.t <= t { best = (t - s.t) < 900 ? s.app : "?" }   // dernier échantillon avant t, s'il date de moins de 15 min
        return best
    }

    private func bump(_ key: String, _ next: String) { m[key, default: [:]][next, default: 0] += 1 }

    /// Apprend les actions nouvelles du journal (idempotent : n'avance que sur les horodatages jamais vus).
    private func syncLocked() {
        let fmt = ISO8601DateFormatter()
        var changed = false
        for e in Tools.actions.tail(300) {
            guard let tsS = e["ts"] as? String, let d = fmt.date(from: tsS) else { continue }
            let t = d.timeIntervalSince1970
            if t <= lastTs { continue }
            lastTs = t; changed = true
            guard let name = e["tool"] as? String, !name.isEmpty, (e["ok"] as? Bool) != false else { continue }
            let s = Predict.slot(d), a = appAt(t)
            bump(Predict.keyExact(s, a, prev), name)
            bump(Predict.keyNoApp(s, prev), name)
            bump(Predict.keyPrevOnly(prev), name)
            bump(Predict.keyNoPrev(s, a), name)
            prev = name
        }
        if changed { saveLocked() }
    }

    // MARK: prédiction
    /// 3 actions les plus probables ; confiance = part de probabilité pondérée × facteur de preuve n/(n+3) (reste prudente avec peu d'exemples).
    public func next(app: String, now: Date = Date()) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        syncLocked()
        let a = app.isEmpty ? "?" : app
        let s = Predict.slot(now)
        let levels: [(String, Double)] = [(Predict.keyExact(s, a, prev), 1.0), (Predict.keyNoApp(s, prev), 0.6), (Predict.keyPrevOnly(prev), 0.35), (Predict.keyNoPrev(s, a), 0.2)]
        var score: [String: Double] = [:]; var support: [String: Int] = [:]
        var wsum = 0.0; var maxTotal = 0
        for (k, w) in levels {
            guard let d = m[k] else { continue }
            let tot = d.values.reduce(0, +); if tot == 0 { continue }
            wsum += w; maxTotal = max(maxTotal, tot)
            for (act, c) in d { score[act, default: 0] += w * Double(c) / Double(tot); support[act] = max(support[act] ?? 0, c) }
        }
        let evidence = Double(maxTotal) / Double(maxTotal + 3)
        let top = score.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(3)
        var items: [[String: Any]] = []
        if wsum > 0 {
            for (act, v) in top {
                let conf: Double = ((v / wsum) * evidence * 100).rounded() / 100
                items.append(["action": act, "confidence": conf, "count": support[act] ?? 0])
            }
        }
        let total = m.values.reduce(0) { $0 + $1.values.reduce(0, +) } / 4
        return ["items": items, "context": ["slot": s, "app": a, "prev": prev], "learned": total]
    }
}
