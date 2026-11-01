import Foundation

/// État réel de la machine (batterie, CPU, mémoire, disque, GPU, processus). Lit les commandes système ; une mesure impossible est
/// déclarée absente (nil → null), jamais inventée.
public enum SystemInfo {
    static let lock = NSLock()
    static var cache: (Date, [String: Any])? = nil

    public static func rx(_ p: String, _ s: String) -> [String]? {
        guard let r = try? NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators]), let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }
    static func num(_ s: String?) -> Double? { s.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) } }

    #if os(macOS)
    // --- Mesures natives (sans sous-processus) ; nil => l'appelant retombe sur la commande système. ---
    static var prevTicks: (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)? = nil

    /// CPU en % depuis le dernier appel (premier appel : moyenne depuis le démarrage).
    static func nativeCPU() -> [String: Any]? {
        var n: natural_t = 0
        var info: processor_info_array_t? = nil
        var cnt: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) == KERN_SUCCESS, let inf = info else { return nil }
        defer { _ = vm_deallocate(mach_task_self_, vm_address_t(bitPattern: inf), vm_size_t(cnt) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        var cur: (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64) = (0, 0, 0, 0)
        let st = Int(CPU_STATE_MAX)
        for i in 0..<Int(n) {
            cur.user += UInt64(UInt32(bitPattern: inf[st * i + Int(CPU_STATE_USER)]))
            cur.sys += UInt64(UInt32(bitPattern: inf[st * i + Int(CPU_STATE_SYSTEM)]))
            cur.idle += UInt64(UInt32(bitPattern: inf[st * i + Int(CPU_STATE_IDLE)]))
            cur.nice += UInt64(UInt32(bitPattern: inf[st * i + Int(CPU_STATE_NICE)]))
        }
        lock.lock(); let prev = prevTicks; prevTicks = cur; lock.unlock()
        var d = cur
        if let p = prev, cur.user >= p.user, cur.sys >= p.sys, cur.idle >= p.idle, cur.nice >= p.nice {
            d = (cur.user - p.user, cur.sys - p.sys, cur.idle - p.idle, cur.nice - p.nice)
        }
        let tot = Double(d.user + d.sys + d.idle + d.nice)
        guard tot > 0 else { return nil }
        func r(_ x: UInt64) -> Double { (Double(x) / tot * 1000).rounded() / 10 }
        let u = r(d.user + d.nice), s = r(d.sys)
        return ["user": u, "sys": s, "idle": max(0, ((100 - u - s) * 10).rounded() / 10)]
    }

    /// Mémoire utilisée (octets) = active + câblée + compressée, comme l'ancien calcul vm_stat.
    static func nativeMemUsed() -> Double? {
        var st = vm_statistics64_data_t()
        var cnt = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &st) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &cnt) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let ps = Double(getpagesize())
        return (Double(st.active_count) + Double(st.wire_count) + Double(st.compressor_page_count)) * ps
    }

    static func nativeDisk(_ path: String) -> [String: Any]? {
        guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let t = v.volumeTotalCapacity, let a = v.volumeAvailableCapacityForImportantUsage, t > 0 else { return nil }
        let tot = Double(t), used = max(0, tot - Double(a))
        return ["total": tot, "used": used, "pct": Int(used / max(tot, 1) * 100)]
    }
    #endif

    /// Cache de 5 s : pastille, page État du Mac et autres vues ne relancent plus une dizaine de processus à chaque appel.
    nonisolated(unsafe) static var snapCache: (Date, [String: Any])? = nil
    static let snapLock = NSLock()
    public static func snapshot() -> [String: Any] {
        snapLock.lock(); if let c = snapCache, Date().timeIntervalSince(c.0) < 5 { snapLock.unlock(); return c.1 }; snapLock.unlock()
        let r = snapshotRaw(); snapLock.lock(); snapCache = (Date(), r); snapLock.unlock(); return r
    }
    static func snapshotRaw() -> [String: Any] {
        lock.lock(); if let c = cache, Date().timeIntervalSince(c.0) < 3 { lock.unlock(); return c.1 }; lock.unlock()
        var o: [String: Any] = ["ts": nowISO()]
        #if os(macOS)
        o["os"] = "macOS"
        let (_, batt) = runProcess("/usr/bin/pmset", ["-g", "batt"], timeout: 4)
        if let m = rx(#"(\d+)%;\s*([a-zA-Z ]+?);\s*(?:(\d+:\d+) remaining|\(no estimate\)|finishing charge|)"#, batt) {
            o["battery"] = ["pct": Int(m[1]) ?? 0, "state": m[2].trimmingCharacters(in: .whitespaces), "remaining": m.count > 3 && !m[3].isEmpty ? m[3] : NSNull(),
                            "source": batt.contains("AC Power") ? "secteur" : "batterie"] as [String: Any]
        } else { o["battery"] = NSNull() }
        if let c = nativeCPU() { o["cpu"] = c }
        if o["cpu"] == nil {   // repli : « top » (sous-processus) seulement si l'API native échoue
            let top = runProcess("/usr/bin/top", ["-l", "1", "-n", "0", "-s", "0"], timeout: 8).1
            if let m = rx(#"CPU usage:\s*([\d.,]+)% user,\s*([\d.,]+)% sys,\s*([\d.,]+)% idle"#, top) {
                o["cpu"] = ["user": num(m[1]) ?? 0.0, "sys": num(m[2]) ?? 0.0, "idle": num(m[3]) ?? 0.0] as [String: Any]
            }
        }
        if o["cpu"] == nil {   // repli : somme des %CPU des processus / nombre de cœurs (si « top » n'a rien rendu)
            let (_, ps) = runProcess("/bin/ps", ["-A", "-o", "%cpu"], timeout: 4)
            let tot = ps.split(separator: "\n").dropFirst().compactMap { Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }.reduce(0, +)
            let n = Double(ProcessInfo.processInfo.activeProcessorCount); if tot > 0 { let u = min(100, tot / n); o["cpu"] = ["user": (u * 10).rounded() / 10, "sys": 0.0, "idle": ((100 - u) * 10).rounded() / 10] as [String: Any] }
        }
        let (_, brand) = runProcess("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"], timeout: 3)
        let (_, ncpu) = runProcess("/usr/sbin/sysctl", ["-n", "hw.ncpu"], timeout: 3)
        let (_, load) = runProcess("/usr/sbin/sysctl", ["-n", "vm.loadavg"], timeout: 3)
        o["machine"] = ["cpu": brand.trimmingCharacters(in: .whitespacesAndNewlines), "cores": Int(ncpu.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
                        "mem_total": Double(ProcessInfo.processInfo.physicalMemory), "load": load.trimmingCharacters(in: CharacterSet(charactersIn: "{} \n"))] as [String: Any]
        if let used = nativeMemUsed() {
            o["mem_used"] = used
        } else {   // repli : vm_stat
            let (_, vm) = runProcess("/usr/bin/vm_stat", [], timeout: 3)
            if let ps = rx(#"page size of (\d+) bytes"#, vm).flatMap({ Double($0[1]) }) {
                func pages(_ k: String) -> Double { rx(k + #":\s*(\d+)\."#, vm).flatMap { Double($0[1]) } ?? 0 }
                o["mem_used"] = (pages("Pages active") + pages("Pages wired down") + pages("Pages occupied by compressor")) * ps
            }
        }
        if let used = o["mem_used"] as? Double {
            let tot = ProcessInfo.processInfo.physicalMemory
            o["mem_text"] = "\(Int(used / 1_048_576))M used, \(Int((Double(tot) - used) / 1_048_576))M unused."
        }
        let (_, ior) = runProcess("/usr/sbin/ioreg", ["-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"], timeout: 4)
        if let m = rx(#""Device Utilization %"\s*=\s*(\d+)"#, ior) { o["gpu"] = ["util": Int(m[1]) ?? 0] as [String: Any] } else { o["gpu"] = NSNull() }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: o["thermal"] = "aucune limitation thermique signalée"
        case .fair: o["thermal"] = "état thermique : modéré (fair)"
        case .serious: o["thermal"] = "état thermique : élevé (serious), limitation possible"
        case .critical: o["thermal"] = "état thermique : critique, limitation CPU probable"
        @unknown default:
            let (_, therm) = runProcess("/usr/bin/pmset", ["-g", "therm"], timeout: 3)
            o["thermal"] = therm.contains("CPU_Speed_Limit") ? (rx(#"CPU_Speed_Limit\s*=\s*(\d+)"#, therm).map { "limitation CPU \($0[1]) %" } ?? "ok") : "aucune limitation thermique signalée"
        }
        let (_, bt) = runProcess("/usr/sbin/sysctl", ["-n", "kern.boottime"], timeout: 3)
        if let m = rx(#"sec = (\d+)"#, bt), let t = Double(m[1]) { o["uptime_s"] = Date().timeIntervalSince1970 - t }
        let (_, pl) = runProcess("/bin/ps", ["-Ao", "pcpu,pmem,comm", "-r"], timeout: 4)
        o["procs"] = pl.split(separator: "\n").dropFirst().prefix(6).compactMap { l -> [String: Any]? in
            let p = l.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true); guard p.count == 3 else { return nil }
            return ["cpu": Double(p[0]) ?? 0, "mem": Double(p[1]) ?? 0, "name": (String(p[2]) as NSString).lastPathComponent]
        }
        #else
        o["os"] = "Linux"
        o["battery"] = NSNull(); o["gpu"] = NSNull(); o["thermal"] = "non mesuré sur cette plateforme"
        if let l = try? String(contentsOfFile: "/proc/loadavg", encoding: .utf8) { o["machine"] = ["cpu": "x86_64", "cores": ProcessInfo.processInfo.activeProcessorCount, "mem_total": Double(ProcessInfo.processInfo.physicalMemory), "load": l.split(separator: " ").prefix(3).joined(separator: " ")] as [String: Any] }
        if let mi = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8), let t = rx(#"MemTotal:\s*(\d+)"#, mi).flatMap({ Double($0[1]) }), let a = rx(#"MemAvailable:\s*(\d+)"#, mi).flatMap({ Double($0[1]) }) { o["mem_used"] = (t - a) * 1024 }
        if let u = try? String(contentsOfFile: "/proc/uptime", encoding: .utf8), let s = u.split(separator: " ").first.flatMap({ Double($0) }) { o["uptime_s"] = s }
        o["procs"] = [] as [[String: Any]]
        #endif
        // macOS (APFS) : la racine « / » est le petit volume système en lecture seule ; l'espace réellement utilisé est sur le volume Data.
        // Utilisé = total du conteneur − disponible (comme le Finder), pas la colonne « Used » d'un seul volume.
        let dfPath = FileManager.default.fileExists(atPath: "/System/Volumes/Data") ? "/System/Volumes/Data" : "/"
        #if os(macOS)
        if let d = nativeDisk(dfPath) { o["disk"] = d }
        #endif
        var df = ""
        if o["disk"] == nil { df = runProcess("/bin/df", ["-k", dfPath], timeout: 4).1 }
        let cols = df.split(separator: "\n").dropFirst().first.map { $0.split(separator: " ", omittingEmptySubsequences: true) } ?? []
        if o["disk"] == nil, cols.count >= 5, let tot = Double(cols[1]), let avail = Double(cols[3]) {
            let used = max(0, tot - avail)
            o["disk"] = ["total": tot * 1024, "used": used * 1024, "pct": Int(used / max(tot, 1) * 100)] as [String: Any]
        }
        lock.lock(); cache = (Date(), o); lock.unlock()
        return o
    }
}

extension SystemInfo {
    nonisolated(unsafe) static var cpuCache: (Date, Double)? = nil
    static let cpuLock = NSLock()
    /// Charge CPU système (user + sys, 0–100 %), mesure native sans sous-processus, mise en cache 15 s. -1 si inconnue.
    public static func cpuLoadPercent() -> Double {
        cpuLock.lock()
        if let c = cpuCache, Date().timeIntervalSince(c.0) < 15 { cpuLock.unlock(); return c.1 }
        cpuLock.unlock()
        var v: Double = -1
        #if os(macOS)
        if let c = nativeCPU() {
            let u: Double = (c["user"] as? Double) ?? 0
            let s: Double = (c["sys"] as? Double) ?? 0
            v = u + s
        }
        #endif
        cpuLock.lock(); cpuCache = (Date(), v); cpuLock.unlock()
        return v
    }
}

/// Points d'accroche renseignés par l'app Mac (NovaCore ne dépend pas d'AppKit).
public enum SystemHooks {
    /// (nom, identifiant de paquet) de l'app au premier plan ; nil hors app Mac.
    nonisolated(unsafe) public static var frontmostProvider: (() -> (String, String))? = nil
}
