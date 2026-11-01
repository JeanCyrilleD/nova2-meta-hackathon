import Foundation
#if canImport(Accelerate)
import Accelerate
#endif
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Index vectoriel de la base de connaissances (UltraVectorIndex).
/// - Plongements : NLEmbedding.sentenceEmbedding(.french), sinon (.english), sinon hachage sémantique local (384 dimensions).
/// - Stockage : une seule matrice contiguë [Float] (lignes normalisées), produit matrice × vecteur via vDSP_mmul (Accelerate).
/// - Construction en arrière-plan (QoS utilitaire), plafonnée ; une construction plus récente annule la précédente.
/// Interrupteur « NovaVectors » (UserDefaults, défaut : ACTIF ; false = coupé) ou NOVA_VECTORS=0. Coupé ou pas prêt → BM25 seul, comme avant.
public final class UltraVectorIndex: @unchecked Sendable {
    public static let shared = UltraVectorIndex()
    public static let maxRows = 12000
    public static let hashDim = 384

    public static var enabled: Bool {
        if ProcessInfo.processInfo.environment["NOVA_VECTORS"] == "0" { return false }
        return (UserDefaults.standard.object(forKey: "NovaVectors") as? Bool) ?? true
    }

    private let lock = NSLock()          // protège l'état de l'index
    private let embLock = NSLock()       // NLEmbedding n'est pas garanti thread-safe : appels sérialisés
    private var loaded = false
    #if canImport(NaturalLanguage)
    private var nl: NLEmbedding? = nil
    #endif
    private var kindName = "hash"
    private var dimension = UltraVectorIndex.hashDim

    // état publié (remplacé d'un bloc à la fin d'une construction)
    private var matrix: [Float] = []
    private var rows = 0
    private var dim = 0
    private var sourceID = -1
    private var rowHash: [UInt64: Int] = [:]   // empreinte du texte → ligne (réutilisée à la reconstruction suivante)
    private var generation = 0
    private var building = false
    private var lastBuildMs = 0.0
    private var lastQueryMs = 0.0

    /// V5-I : nom de base du cache disque (« vec-knowledge » = base de connaissances, inchangé). Un index distinct
    /// (ex. « vec-pinecone », copie locale de la mémoire sémantique [tiers] — Credits.swift) ne touche jamais au cache principal.
    let cacheBase: String
    init(cacheBase: String = "vec-knowledge") { self.cacheBase = cacheBase }

    /// Charge le modèle à la première utilisation (jamais au lancement de l'app).
    private func ensureModel() {
        embLock.lock(); defer { embLock.unlock() }
        if loaded { return }
        loaded = true
        #if canImport(NaturalLanguage)
        if let e = NLEmbedding.sentenceEmbedding(for: .french) { nl = e; kindName = "nl-fr" }
        else if let e = NLEmbedding.sentenceEmbedding(for: .english) { nl = e; kindName = "nl-en" }
        if let e = nl, e.dimension > 0 { dimension = e.dimension } else { nl = nil; kindName = "hash"; dimension = UltraVectorIndex.hashDim }
        #endif
    }

    public var kind: String { ensureModel(); embLock.lock(); defer { embLock.unlock() }; return kindName }

    static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    static func normalize(_ v: inout [Float]) {
        var n: Float = 0
        for x in v { n += x * x }
        if n <= 0 { return }
        let inv = 1 / n.squareRoot()
        for i in 0..<v.count { v[i] *= inv }
    }

    /// Repli sans modèle : mots (et trigrammes de lettres) hachés avec signe dans `d` dimensions.
    static func hashVector(_ text: String, dim d: Int) -> [Float] {
        var v = [Float](repeating: 0, count: d)
        guard d > 0 else { return v }
        for w in Knowledge.tokens(text) {
            let h = fnv(w)
            v[Int(h % UInt64(d))] += (h >> 63) == 0 ? 1 : -1
            let cs = Array(w)
            if cs.count >= 3 {
                for i in 0...(cs.count - 3) {
                    let g = fnv(String(cs[i..<(i + 3)]))
                    v[Int(g % UInt64(d))] += (g >> 63) == 0 ? 0.5 : -0.5
                }
            }
        }
        normalize(&v)
        return v
    }

    /// Vecteur normalisé de longueur `dimension` (vecteur nul si le modèle échoue : aucune contribution, jamais de bruit).
    func embed(_ text: String) -> [Float] {
        ensureModel()
        let s = String(text.prefix(1200))
        embLock.lock()
        let d = dimension
        #if canImport(NaturalLanguage)
        if let e = nl {
            NovaNLGate.lock.lock(); let raw = e.vector(for: s); NovaNLGate.lock.unlock()
            embLock.unlock()
            guard let r = raw, r.count == d else { return [Float](repeating: 0, count: d) }
            var v = r.map { Float($0) }
            UltraVectorIndex.normalize(&v)
            return v
        }
        #endif
        embLock.unlock()
        return UltraVectorIndex.hashVector(s, dim: d)
    }

    /// Reconstruit l'index pour `texts` (identifiés par `id`, l'appelant vérifie qu'il correspond toujours à ses données).
    public static func onBattery() -> Bool {   // vrai si le Mac tourne sur batterie (cache 60 s)
        battLock.lock(); defer { battLock.unlock() }
        let now = Date()
        if now.timeIntervalSince(battT) > 60 { battT = now; let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["-g", "batt"]; let o = Pipe(); p.standardOutput = o; p.standardError = Pipe(); try? p.run(); p.waitUntilExit(); battV = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.contains("Battery Power") ?? false }
        return battV
    }
    private static let battLock = NSLock()
    private static var battT = Date.distantPast
    private static var battV = false

    public func rebuild(id: Int, texts: [String]) {
        guard UltraVectorIndex.enabled else { return }
        lock.lock(); generation += 1; let gen = generation; building = true; let first = rows == 0; lock.unlock()
        let t = Thread { [self] in
            ensureModel()
            embLock.lock(); let d = dimension; let kind = kindName; embLock.unlock()
            lock.lock(); var oldM = matrix, oldHash = rowHash, oldDim = dim; lock.unlock()
            // Redémarrage : on reprend la matrice déjà calculée sur disque (seuls les extraits nouveaux sont ré-plongés).
            if oldM.isEmpty, let c = UltraVectorIndex.loadCache(kind: kind, dim: d, base: self.cacheBase) { oldM = c.0; oldHash = c.1; oldDim = d }
            // Premier index : on laisse l'app finir de démarrer UNIQUEMENT si aucun cache n'est réutilisable (ré-embedding complet).
            if first && oldM.isEmpty { Thread.sleep(forTimeInterval: 15) }
            lock.lock(); let staleAtStart = gen != generation; lock.unlock()
            if staleAtStart { return }
            let t0 = Date()
            let n = min(texts.count, UltraVectorIndex.maxRows)
            var m = [Float](repeating: 0, count: n * d)
            var hashes: [UInt64: Int] = [:]
            for i in 0..<n {
                if i % 8 == 0 {   // une construction plus récente a démarré, ou l'interrupteur a été coupé : on abandonne
                    lock.lock(); let stale = gen != generation; lock.unlock()
                    if stale || !UltraVectorIndex.enabled {
                        // 27/10 (CPU au repos ~100 % mesuré) : bancariser la progression AVANT d'abandonner.
                        // Sans cela, une reconstruction annulée (scan suivant) re-plongeait les mêmes textes
                        // à chaque passe et le cache ne se remplissait jamais (857 lignes figées depuis le 25/10).
                        // Uniquement si cette passe a dépassé le cache existant (jamais de rétrécissement).
                        if i > oldHash.count { UltraVectorIndex.saveCache(matrix: Array(m[0..<(i * d)]), dim: d, kind: kind, hashes: hashes, base: self.cacheBase) }
                        return
                    }
                }
                let h = UltraVectorIndex.fnv(texts[i])
                var v: [Float]
                if oldDim == d, let r = oldHash[h], (r + 1) * d <= oldM.count { v = Array(oldM[(r * d)..<((r + 1) * d)]) }
                else { v = embed(texts[i]); Thread.sleep(forTimeInterval: UltraVectorIndex.onBattery() ? 0.04 : 0.008) }   // bride : laisse respirer le Mac
                if v.count != d { v = [Float](repeating: 0, count: d) }
                for j in 0..<d { m[i * d + j] = v[j] }
                hashes[h] = i
            }
            lock.lock()
            let commit = gen == generation
            if commit {
                matrix = m; rows = n; dim = d; sourceID = id; rowHash = hashes; building = false
                lastBuildMs = Date().timeIntervalSince(t0) * 1000
            }
            lock.unlock()
            if commit { UltraVectorIndex.saveCache(matrix: m, dim: d, kind: kind, hashes: hashes, base: self.cacheBase) }
        }
        t.qualityOfService = .background
        t.stackSize = 4 << 20
        t.start()
    }

    // MARK: cache disque (matrice + empreintes) — clé STABLE (nom de base fixe, pas le numéro de génération).
    // Le cache est réutilisé d'un lancement à l'autre ; les empreintes par texte ne re-plongent que les extraits nouveaux/modifiés.
    static func cacheURL(_ base: String = "vec-knowledge") -> URL { Paths.home.appendingPathComponent(base + ".f32") }
    static func cacheMetaURL(_ base: String = "vec-knowledge") -> URL { Paths.home.appendingPathComponent(base + ".json") }
    static func loadCache(kind: String, dim d: Int, base: String = "vec-knowledge") -> ([Float], [UInt64: Int])? {
        guard let meta = try? Data(contentsOf: cacheMetaURL(base)),
              let j = try? JSONSerialization.jsonObject(with: meta) as? [String: Any],
              (j["kind"] as? String) == kind, (j["dim"] as? Int) == d,
              let pairs = j["hashes"] as? [[String]], let raw = try? Data(contentsOf: cacheURL(base)) else { return nil }
        var m = [Float](repeating: 0, count: raw.count / MemoryLayout<Float>.size)
        _ = m.withUnsafeMutableBytes { raw.copyBytes(to: $0) }
        var h: [UInt64: Int] = [:]
        for p in pairs where p.count == 2 { if let k = UInt64(p[0]), let r = Int(p[1]) { h[k] = r } }
        guard !h.isEmpty, m.count >= ((h.values.max() ?? 0) + 1) * d else { return nil }
        return (m, h)
    }
    static func saveCache(matrix m: [Float], dim d: Int, kind: String, hashes: [UInt64: Int], base: String = "vec-knowledge") {
        try? FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
        let data = m.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: cacheURL(base), options: .atomic)
        let meta: [String: Any] = ["kind": kind, "dim": d, "hashes": hashes.map { [String($0.key), String($0.value)] }]
        if let j = try? JSONSerialization.data(withJSONObject: meta) { try? j.write(to: cacheMetaURL(base), options: .atomic) }
    }

    /// Produit scores[i] = M[i,:] · q pour une matrice n × d (lignes contiguës).
    static func scores(_ m: [Float], rows n: Int, dim d: Int, query q: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: n)
        guard n > 0, d > 0, m.count >= n * d, q.count == d else { return out }
        #if canImport(Accelerate)
        // vDSP_mmul(A, IA, B, IB, C, IC, M, N, P) : C[M×N] = A[M×P] · B[P×N] ; ici A = M (n×d), B = q (d×1), C = out (n×1).
        m.withUnsafeBufferPointer { mp in
            q.withUnsafeBufferPointer { qp in
                out.withUnsafeMutableBufferPointer { op in
                    vDSP_mmul(mp.baseAddress!, 1, qp.baseAddress!, 1, op.baseAddress!, 1, vDSP_Length(n), 1, vDSP_Length(d))
                }
            }
        }
        #else
        for i in 0..<n {
            var s: Float = 0
            let base = i * d
            for j in 0..<d { s += m[base + j] * q[j] }
            out[i] = s
        }
        #endif
        return out
    }

    /// Les k meilleurs (indice, score) par ordre décroissant — tri partiel par insertion (k petit).
    static func topK(_ s: [Float], _ k: Int) -> [(Int, Float)] {
        guard k > 0 else { return [] }
        var top: [(Int, Float)] = []
        top.reserveCapacity(k + 1)
        for i in 0..<s.count {
            let v = s[i]
            if top.count < k {
                top.append((i, v))
                if top.count == k { top.sort { $0.1 > $1.1 } }
            } else if v > top[k - 1].1 {
                var j = k - 1
                while j > 0 && top[j - 1].1 < v { j -= 1 }
                top.insert((i, v), at: j)
                top.removeLast()
            }
        }
        if top.count < k { top.sort { $0.1 > $1.1 } }
        return top
    }

    /// Recherche cosinus top-k. nil si coupé, pas prêt ou index vide.
    public func search(_ query: String, k: Int) -> (id: Int, kind: String, hits: [(Int, Float)])? {
        guard UltraVectorIndex.enabled else { return nil }
        lock.lock(); let m = matrix, n = rows, d = dim, sid = sourceID; lock.unlock()
        guard n > 0, d > 0 else { return nil }
        let t0 = Date()
        let q = embed(query)
        guard q.count == d, q.contains(where: { $0 != 0 }) else { return nil }
        let hits = UltraVectorIndex.topK(UltraVectorIndex.scores(m, rows: n, dim: d, query: q), k)
        let ms = Date().timeIntervalSince(t0) * 1000
        lock.lock(); lastQueryMs = ms; lock.unlock()
        return (id: sid, kind: kind, hits: hits)
    }

    public func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["enabled": UltraVectorIndex.enabled, "rows": rows, "dim": dim, "building": building,
                "build_ms": Int(lastBuildMs), "last_query_ms": (lastQueryMs * 1000).rounded() / 1000]
    }

    /// Mesures : requête réelle sur l'index courant + produit matriciel synthétique 5000 × dim.
    public func selftest() -> [String: Any] {
        var o = status()
        o["kind"] = kind
        if let r = search("charte règles projet", k: 8) { o["requete_reelle_ms"] = (lastQueryMsValue() * 1000).rounded() / 1000; o["requete_reelle_hits"] = r.hits.count }
        let d = max(1, dimension), n = 5000
        var m = [Float](repeating: 0, count: n * d)
        for i in 0..<m.count { m[i] = Float((i &* 2654435761) % 1000) / 1000 - 0.5 }
        var q = [Float](repeating: 0, count: d)
        for j in 0..<d { q[j] = Float(j % 7) - 3 }
        let t0 = Date()
        let top = UltraVectorIndex.topK(UltraVectorIndex.scores(m, rows: n, dim: d, query: q), 10)
        o["synthetique_5000x\(d)_ms"] = (Date().timeIntervalSince(t0) * 1_000_000).rounded() / 1000
        o["synthetique_top"] = top.count
        #if canImport(Accelerate)
        o["moteur"] = "vDSP_mmul"
        #else
        o["moteur"] = "boucle Swift"
        #endif
        return o
    }

    private func lastQueryMsValue() -> Double { lock.lock(); defer { lock.unlock() }; return lastQueryMs }
}

/// Verrou unique pour TOUS les appels NLEmbedding (Mémoire + index vectoriel) : appelés en parallèle, ils plantaient CoreNLP (EXC_BAD_ACCESS, vDSP_vclip).
enum NovaNLGate { static let lock = NSLock() }
