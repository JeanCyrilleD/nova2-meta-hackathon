import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum Paths {
    /// Dossier de données de Nova (~/Library/Application Support/Nova sur Mac, ~/.nova ailleurs ou via NOVA_HOME).
    public static var home: URL {
        if let h = ProcessInfo.processInfo.environment["NOVA_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Nova")
        #else
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nova")
        #endif
    }
    public static func file(_ name: String) -> URL {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home.appendingPathComponent(name)
    }
    /// WP1 (31/10) : dossier UNIQUE des relevés de diagnostic (avant : « ~/spark-local/Nova2/releves/diag » écrit en dur fichier
    /// par fichier). NOVA_DIAG_DIR l'impose ; sous NOVA_HOME (tests, bac à sable) il suit NOVA_HOME/diag — un test n'écrit
    /// jamais dans les relevés de l'app en service. Par défaut : inchangé (~/spark-local/Nova2/releves/diag).
    public static var diagDir: URL {
        let env = ProcessInfo.processInfo.environment
        if let d = env["NOVA_DIAG_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
        if let h = env["NOVA_HOME"], !h.isEmpty { return URL(fileURLWithPath: h).appendingPathComponent("diag") }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("spark-local/Nova2/releves/diag")
    }
    public static func diagFile(_ name: String) -> URL {
        let d = diagDir
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent(name)
    }
}

public func nowISO() -> String { ISO8601DateFormatter().string(from: Date()) }

public func jsonData(_ obj: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
}
public func jsonString(_ obj: Any) -> String { String(data: jsonData(obj), encoding: .utf8) ?? "{}" }
public func parseJSON(_ d: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }

/// Pont optionnel vers la persistance SQLite (UltraDatabase, cible NovaCore) — NovaFoundation ne
/// dépend d'aucune cible supérieure : NovaCore enregistre ces fermetures au démarrage (registerSQLiteBridge).
/// Non enregistré ou interrupteur coupé : les fichiers JSON font foi, exactement comme avant le découpage.
public enum SQLiteBridge {
    public static var put: ((_ name: String, _ data: Data) -> Bool)?
    public static var get: ((_ name: String) -> (data: Data, ts: Double)?)?
    public static var mirrorJSON: (() -> Bool)?
    public static var drain: (() -> Void)?
    public static var append: ((_ ns: String, _ value: Data) -> Void)?
}

/// État partagé par fichier : toutes les instances JSONFile d'un même chemin voient la même valeur (cache mémoire + écriture différée).
final class JSONFileState {
    let url: URL
    let lock = NSLock()
    var loaded = false
    var value: Any? = nil       // dernière valeur écrite (relue depuis ses octets JSON : même forme qu'une lecture disque)
    var pending: Data? = nil    // octets pas encore posés sur le disque
    var scheduled = false
    init(url: URL) { self.url = url }
}

/// Lecture/écriture JSON thread-safe d'un petit fichier d'état : lecture en mémoire, écriture disque atomique, différée (~150 ms) et regroupée.
public final class JSONFile {
    let url: URL
    let st: JSONFileState
    nonisolated(unsafe) static var states: [String: JSONFileState] = [:]
    static let statesLock = NSLock()
    static let writer = DispatchQueue(label: "nova.disk.writer", qos: .utility)

    public init(_ name: String) {
        let u = Paths.file(name)
        let key = u.path
        url = u
        JSONFile.statesLock.lock()
        if let s = JSONFile.states[key] {
            st = s
        } else {
            let s = JSONFileState(url: u)
            JSONFile.states[key] = s
            st = s
        }
        JSONFile.statesLock.unlock()
    }
    public func read<T>(default def: T) -> T {
        st.lock.lock(); defer { st.lock.unlock() }
        if !st.loaded {
            st.loaded = true
            if let d = JSONFile.loadBytes(url) {
                st.value = try? JSONSerialization.jsonObject(with: d)
                // 29/10 (audit n°3) : fichier illisible → copie de sauvegarde AVANT que la prochaine écriture ne l'écrase.
                if st.value == nil, !d.isEmpty {
                    try? d.write(to: url.appendingPathExtension("illisible-" + String(Int(Date().timeIntervalSince1970))))
                    NSLog("Nova JSONFile illisible, copie gardée : %@", url.path)
                }
            }
        }
        guard let v = st.value, let o = v as? T else { return def }
        return o
    }
    public func write(_ obj: Any) {
        // 29/10 (audit n°3) : un objet non sérialisable n'écrase plus le fichier par « {} ».
        guard JSONSerialization.isValidJSONObject(obj) else { NSLog("Nova JSONFile : objet non sérialisable, écriture refusée %@", url.path); return }
        st.lock.lock()
        let d = jsonData(obj)
        st.value = try? JSONSerialization.jsonObject(with: d)
        st.loaded = true
        st.pending = d
        let schedule = !st.scheduled
        st.scheduled = true
        st.lock.unlock()
        if schedule {
            let s = st
            JSONFile.writer.asyncAfter(deadline: .now() + .milliseconds(150)) { JSONFile.flushState(s) }
        }
    }
    static func flushState(_ s: JSONFileState) {
        s.lock.lock()
        let d = s.pending
        s.pending = nil
        s.scheduled = false
        s.lock.unlock()
        guard let d = d else { return }
        // Interrupteur « NovaSQLite » (défaut : désactivé) : écriture dans la base WAL ; le fichier JSON reste écrit en miroir
        // (sauf NovaSQLiteMirrorJSON = false) pour qu'un retour arrière de l'interrupteur ne perde jamais rien. Échec base → fichier JSON.
        let name = s.url.lastPathComponent
        if let put = SQLiteBridge.put, put(name, d), SQLiteBridge.mirrorJSON?() == false { return }
        do { try d.write(to: s.url, options: .atomic) } catch { NSLog("Nova JSONFile : écriture échouée %@ — %@", s.url.path, "\(error)") }
    }
    /// Lecture initiale : base SQLite si l'interrupteur est actif et que sa copie est au moins aussi récente que le fichier, sinon le fichier.
    static func loadBytes(_ url: URL) -> Data? {
        let name = url.lastPathComponent
        if let row = SQLiteBridge.get?(name) {
            let mtime = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            if row.ts + 1 >= mtime { return row.data }
        }
        return try? Data(contentsOf: url)
    }
    /// Pose immédiatement sur le disque toutes les écritures en attente (à appeler à la fermeture de l'app).
    public static func flush() {
        statesLock.lock()
        let all = Array(states.values)
        statesLock.unlock()
        writer.sync { for s in all { flushState(s) } }
        SQLiteBridge.drain?()
    }
}

/// Journal JSONL append-only (une ligne par événement). Jamais de secret dedans.
public final class Journal {
    public let url: URL
    public let lock = NSLock()
    public init(_ name: String) { url = Paths.file(name) }
    public func add(_ ev: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        var e = ev; e["ts"] = nowISO()
        let line = jsonData(e) + Data("\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
        SQLiteBridge.append?(url.lastPathComponent, line)   // journal append-only (interrupteur NovaSQLite, via le pont)
    }
    public func tail(_ n: Int) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        // 31/10 (voix/mémoire/Live) : avant, le journal ENTIER était chargé en mémoire (String + tableau de toutes les lignes)
        // pour n'en garder que les n dernières — à chaque appel (/api/journal, actions, Trust…). Lecture bornée par la fin.
        return journalTailLines(url, n).compactMap { parseJSON(Data($0.utf8)) }
    }
}

/// 31/10 (voix/mémoire/Live) : les `n` dernières lignes non vides d'un fichier, en ne lisant que la fin (64 Ko au moins,
/// élargi ×4 tant qu'il manque des lignes). Même résultat que lire tout le fichier et garder les n dernières lignes.
public func journalTailLines(_ url: URL, _ n: Int) -> [String] {
    guard n > 0, let fh = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? fh.close() }
    let size: UInt64 = fh.seekToEndOfFile()
    if size == 0 { return [] }
    var want: UInt64 = UInt64(max(65_536, n * 1_024))
    var data: Data = Data()
    while true {
        let start: UInt64 = size > want ? size - want : 0
        fh.seek(toFileOffset: start)
        data = fh.readData(ofLength: Int(size - start))
        if start == 0 { break }
        var nl: Int = 0
        for byte in data where byte == 0x0A { nl += 1 }
        if nl > n + 1 {
            // La première ligne lue peut être tronquée : on la retire (il reste au moins n + 1 lignes complètes).
            if let i = data.firstIndex(of: 0x0A) { data = data.subdata(in: data.index(after: i)..<data.endIndex) }
            break
        }
        want = want &* 4
    }
    let txt: String = String(decoding: data, as: UTF8.self)
    return txt.split(separator: "\n").suffix(n).map { String($0) }
}

/// Exécute un binaire système et renvoie (code, stdout). Délai maximal obligatoire.
@discardableResult
public func runProcess(_ path: String, _ args: [String], timeout: TimeInterval = 5, stdin: Data? = nil) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice   // stderr jamais lu : on le jette (évite le blocage au-delà de 64 Ko)
    var inPipe: Pipe? = nil
    if stdin != nil { let i = Pipe(); p.standardInput = i; inPipe = i }
    do { try p.run() } catch { return (127, "") }
    if let s = stdin, let i = inPipe { DispatchQueue.global(qos: .utility).async { i.fileHandleForWriting.write(s); try? i.fileHandleForWriting.close() } }
    let deadline = Date().addingTimeInterval(timeout)
    var data = Data()
    let q = DispatchQueue(label: "run.read"); let g = DispatchGroup(); g.enter()
    q.async { data = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if p.isRunning {
        let pid = p.processIdentifier
        _ = runProcess("/usr/bin/pkill", ["-TERM", "-P", "\(pid)"], timeout: 2)   // les enfants d'abord (zsh -c lance des sous-processus)
        p.terminate()
        Thread.sleep(forTimeInterval: 0.3)
        if p.isRunning { _ = runProcess("/usr/bin/pkill", ["-KILL", "-P", "\(pid)"], timeout: 2); kill(pid, SIGKILL) }
        return (124, "")
    }
    _ = g.wait(timeout: .now() + 1)
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

public func shortError(_ s: String, _ n: Int = 240) -> String {
    let t = s.replacingOccurrences(of: "\n", with: " ")
    return t.count > n ? String(t.prefix(n)) + "…" : t
}
