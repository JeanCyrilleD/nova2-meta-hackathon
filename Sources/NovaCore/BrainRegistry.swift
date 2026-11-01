import Foundation
import NovaFoundation

// PHASE 2 (brief Nova 2, 31/10/2026) — registre de cerveaux, prix, heures de pointe d'un fournisseur, politique de données,
// profils de routage. Données : Config/brains.json, Config/provider_terms.json, Config/cn_public_holidays.json.
// Code pur (aucun réseau, aucune clé) : testé par Tests/NovaCoreTests/Phase2Tests.swift. Branché dans le routeur
// seulement si le réglage « routage_v2 » est vrai (RoutingV2.swift) ; faux par défaut = Nova inchangée.

// MARK: - Argent : micro-dollars entiers

/// 1 USD = 1 000 000 micro-dollars. Jamais de flottant dans les cumuls, réservations et plafonds.
public typealias Micros = Int64

public enum Money {
    public static let perUSD: Micros = 1_000_000
    /// Conversion d'un montant lu dans un JSON (≤ 6 décimales) : arrondi au micro-dollar le plus proche, une seule fois, au chargement.
    public static func micros(usd: Double) -> Micros { Micros((usd * 1_000_000).rounded()) }
    public static func usd(_ m: Micros) -> Double { Double(m) / 1_000_000 }
    public static func format(_ m: Micros) -> String { String(format: "%.4f $", usd(m)) }
    /// ⌈a × b ÷ c⌉ avec un produit intermédiaire sur 128 bits (aucun débordement pour les volumes de Nova). a, b ≥ 0, c > 0.
    public static func mulDivCeil(_ a: Int64, _ b: Int64, _ c: Int64) -> Int64 {
        if a <= 0 || b <= 0 || c <= 0 { return 0 }
        let p = UInt64(a).multipliedFullWidth(by: UInt64(b))
        let qr = UInt64(c).dividingFullWidth((high: p.high, low: p.low))
        let q: UInt64 = qr.quotient + (qr.remainder > 0 ? 1 : 0)
        return q > UInt64(Int64.max) ? Int64.max : Int64(q)
    }
}

// MARK: - Classes de données

public enum DataClass: String, CaseIterable, Codable, Sendable {   // Codable/Sendable : partagé avec AgentsV2 (AgentDataClass)
    case publicData = "public", personal = "personal", sciInternal = "sci_internal", vault = "vault"
    public var rank: Int {
        switch self { case .publicData: return 0; case .personal: return 1; case .sciInternal: return 2; case .vault: return 3 }
    }
    /// Classe d'une tâche = élément le plus sensible de son entrée. Élément sans classe (nil) ou liste vide → personal (brief 2.3).
    /// Étiquette inconnue → vault (échec fermé : la plus stricte, aucune entreprise).
    public static func resolve(_ items: [String?]) -> DataClass {
        if items.isEmpty { return .personal }
        var best: DataClass = .publicData
        for it in items {
            let c: DataClass
            if let s = it { c = DataClass(rawValue: s) ?? .vault } else { c = .personal }
            if c.rank > best.rank { best = c }
        }
        return best
    }
}

// MARK: - Tarifs

public struct Rate {
    public var inp: Micros            // micro-dollars par million de jetons
    public var out: Micros
    public var cacheRead: Micros?
    public var cacheWrite5m: Micros?
    public var cacheWrite1h: Micros?
    public init(inp: Micros, out: Micros, cacheRead: Micros? = nil, cacheWrite5m: Micros? = nil, cacheWrite1h: Micros? = nil) {
        self.inp = inp; self.out = out; self.cacheRead = cacheRead; self.cacheWrite5m = cacheWrite5m; self.cacheWrite1h = cacheWrite1h
    }
}

public struct LongContext {
    public var thresholdInputTokens: Int
    public var inMilli: Int64          // multiplicateurs en millièmes (2.0 → 2000)
    public var outMilli: Int64
    public var cacheMilli: Int64
}

/// Usage d'un appel. outputTokens inclut le raisonnement (facturé comme la sortie) ; reasoningTokens est un sous-total journalisé.
public struct Usage {
    public var inputTokens: Int, cacheRead: Int, cacheWrite5m: Int, cacheWrite1h: Int, outputTokens: Int, reasoningTokens: Int
    public init(input: Int = 0, cacheRead: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, output: Int = 0, reasoning: Int = 0) {
        inputTokens = input; self.cacheRead = cacheRead; self.cacheWrite5m = cacheWrite5m; self.cacheWrite1h = cacheWrite1h
        outputTokens = output; reasoningTokens = reasoning
    }
    public var promptTokens: Int { inputTokens + cacheRead + cacheWrite5m + cacheWrite1h }
    public var isEmpty: Bool { promptTokens + outputTokens == 0 }
}

public struct BrainEntry {
    public var id: String
    public var provider: String
    public var family: String
    public var novaSpec: String?
    public var apiModel: String
    public var enabled: Bool
    public var trainingTier: Bool
    public var thinkingAlwaysOn: Bool
    public var caps: Set<String>
    public var standard: Rate?
    public var peak: Rate?
    public var offpeak: Rate?
    public var batchMilli: Int64?
    public var longContext: LongContext?
    public var schedule: [(from: String, rate: Rate)]
    public var verified: String?
    public var note: String
    public var peakPriced: Bool { peak != nil && offpeak != nil }
}

public struct ProfileSpec {
    public var name: String
    public var chain: [String]
    public var chainPublic: [String]
    public var chainPrivate: [String]
    public var requires: Set<String>
    public var instant: Bool
    public var deterministicFirst: Bool
    public var batchIfNotUrgent: Bool
    public var offpeakForBackground: Bool
    public var otherFamilyThanWriter: Bool
}

public struct ProviderTerms {
    public var id: String
    public var noTrainingAPI: Bool?
    public var retentionDays: Int?
    public var publicAllowed: Bool
    public var onDevice: Bool
    public var verified: String?
    public var trainingModels: Set<String>
    public var conditions: [String]
    public var evidence: String
}

// MARK: - Jours fériés et heures de pointe (UTC, début inclus, fin exclue)

public struct HolidayCalendar {
    public var years: Set<Int>
    public var dates: Set<String>
    public init(years: Set<Int>, dates: Set<String>) { self.years = years; self.dates = dates }
    /// nil = année non couverte (traitée comme « fichier absent » : pas de jour férié reconnu → pointe possible).
    public func isHoliday(_ day: String) -> Bool? {
        guard let y = Int(day.prefix(4)), years.contains(y) else { return nil }
        return dates.contains(day)
    }
    public static func load(path: String) -> HolidayCalendar? {
        guard let d = FileManager.default.contents(atPath: path), let o = parseJSON(d) else { return nil }
        let ys: [Int] = (o["years_covered"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
        let ds: [String] = (o["holidays"] as? [String]) ?? []
        return HolidayCalendar(years: Set(ys), dates: Set(ds))
    }
}

public struct PeakWindows {
    public var weekdays: Set<Int>                  // Calendar.weekday : 1 = dimanche … 7 = samedi
    public var windows: [(start: Int, end: Int)]   // minutes depuis 00:00 UTC
    public var holidays: HolidayCalendar?          // nil = fichier absent → aucun jour férié reconnu → pointe (brief 2.2)
    public init(weekdays: Set<Int>, windows: [(start: Int, end: Int)], holidays: HolidayCalendar?) {
        self.weekdays = weekdays; self.windows = windows; self.holidays = holidays
    }
    static let utc: TimeZone = TimeZone(identifier: "UTC")!
    public static func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = utc; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
    public static func monthKey(_ d: Date) -> String { String(dayKey(d).prefix(7)) }
    public func isPeak(_ d: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = PeakWindows.utc
        let c: DateComponents = cal.dateComponents([.weekday, .hour, .minute], from: d)
        guard let wd = c.weekday, weekdays.contains(wd) else { return false }
        let m: Int = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        guard windows.contains(where: { m >= $0.start && m < $0.end }) else { return false }
        if let h = holidays, h.isHoliday(PeakWindows.dayKey(d)) == true { return false }
        return true
    }
    static func minutes(_ s: String) -> Int? {
        let p = s.split(separator: ":"); guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        return h * 60 + m
    }
    static let dayNames: [String: Int] = ["Sun": 1, "Mon": 2, "Tue": 3, "Wed": 4, "Thu": 5, "Fri": 6, "Sat": 7]
}

// MARK: - Registre

public final class BrainRegistry {
    public let brains: [String: BrainEntry]
    public let profiles: [String: ProfileSpec]
    public var terms: [String: ProviderTerms]
    public var peakWindows: PeakWindows
    public let monthlyHardCap: Micros
    public let monthlyPlanned: Micros
    public let dayCapForeground: Micros
    public let dayCapBackground: Micros
    public let perTaskCap: Micros
    public let alertThresholdsPct: [Int]
    public let allocations: [String: Micros]
    public let maxVerificationAgeDays: Int
    public let personalMaxRetentionDays: Int

    public init(brains: [String: BrainEntry], profiles: [String: ProfileSpec], terms: [String: ProviderTerms], peakWindows: PeakWindows,
                monthlyHardCap: Micros, monthlyPlanned: Micros, dayCapForeground: Micros, dayCapBackground: Micros, perTaskCap: Micros,
                alertThresholdsPct: [Int], allocations: [String: Micros], maxVerificationAgeDays: Int = 90, personalMaxRetentionDays: Int = 30) {
        self.brains = brains; self.profiles = profiles; self.terms = terms; self.peakWindows = peakWindows
        self.monthlyHardCap = monthlyHardCap; self.monthlyPlanned = monthlyPlanned; self.dayCapForeground = dayCapForeground
        self.dayCapBackground = dayCapBackground; self.perTaskCap = perTaskCap; self.alertThresholdsPct = alertThresholdsPct
        self.allocations = allocations; self.maxVerificationAgeDays = maxVerificationAgeDays; self.personalMaxRetentionDays = personalMaxRetentionDays
    }

    // MARK: Chargement (échec → nil : le routeur v2 refuse alors tout appel, message clair)

    static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    static func m(_ v: Any?) -> Micros? { num(v).map { Money.micros(usd: $0) } }
    static func milli(_ v: Any?) -> Int64? { num(v).map { Int64(($0 * 1000).rounded()) } }
    static func rate(_ o: [String: Any]) -> Rate? {
        guard let i = m(o["in"]), let out = m(o["out"]) else { return nil }
        let cw: Micros? = m(o["cache_write"])
        return Rate(inp: i, out: out, cacheRead: m(o["cache_read"]), cacheWrite5m: m(o["cache_write_5m"]) ?? cw, cacheWrite1h: m(o["cache_write_1h"]) ?? cw)
    }

    /// Dossier Config : $NOVA_CONFIG_DIR, puis <données Nova>/Config (surcharge locale), puis Contents/Resources/Config du bundle,
    /// puis ~/spark-local/Nova2/Config (arbre de développement).
    public static func configDirCandidates() -> [String] {
        var out: [String] = []
        if let e = ProcessInfo.processInfo.environment["NOVA_CONFIG_DIR"], !e.isEmpty { out.append(e) }
        out.append(Paths.home.appendingPathComponent("Config").path)
        if let r = Bundle.main.resourcePath { out.append(r + "/Config") }
        out.append(NSHomeDirectory() + "/spark-local/Nova2/Config")
        return out
    }
    public static func loadDefault() -> BrainRegistry? {
        for d in configDirCandidates() where FileManager.default.fileExists(atPath: d + "/brains.json") {
            if let r = load(configDir: d) { return r }
        }
        return nil
    }

    public static func load(configDir: String, holidaysPathOverride: String? = nil) -> BrainRegistry? {
        guard let bd = FileManager.default.contents(atPath: configDir + "/brains.json"), let root = parseJSON(bd),
              let td = FileManager.default.contents(atPath: configDir + "/provider_terms.json"), let troot = parseJSON(td) else { return nil }
        return build(brainsJSON: root, termsJSON: troot, holidays: HolidayCalendar.load(path: holidaysPathOverride ?? (configDir + "/cn_public_holidays.json")))
    }

    public static func build(brainsJSON root: [String: Any], termsJSON troot: [String: Any], holidays: HolidayCalendar?) -> BrainRegistry? {
        guard let b = root["budget"] as? [String: Any], let hard = m(b["monthly_hard_cap_usd"]), let planned = m(b["monthly_planned_usd"]),
              let daily = b["daily_cap_usd"] as? [String: Any], let dFg = m(daily["foreground"]), let dBg = m(daily["background"]),
              let task = m(b["per_task_cap_usd"]), let bj = root["brains"] as? [String: Any] else { return nil }
        var brains: [String: BrainEntry] = [:]
        for (id, v) in bj {
            guard let o = v as? [String: Any], let prov = o["provider"] as? String else { return nil }
            var e = BrainEntry(id: id, provider: prov, family: (o["family"] as? String) ?? prov, novaSpec: o["nova_spec"] as? String,
                               apiModel: (o["model"] as? String) ?? id, enabled: (o["enabled"] as? Bool) ?? false,
                               trainingTier: (o["training_tier"] as? Bool) ?? false, thinkingAlwaysOn: (o["thinking"] as? String) == "always_on",
                               caps: Set((o["caps"] as? [String]) ?? []), standard: rate(o), peak: nil, offpeak: nil,
                               batchMilli: milli(o["batch_multiplier"]), longContext: nil, schedule: [], verified: o["verified"] as? String,
                               note: (o["note"] as? String) ?? "")
            if let p = o["peak"] as? [String: Any], let op = o["offpeak"] as? [String: Any] { e.peak = rate(p); e.offpeak = rate(op) }
            if let lc = o["long_context"] as? [String: Any], let t = num(lc["threshold_input_tokens"]), let im = milli(lc["in_multiplier"]), let om = milli(lc["out_multiplier"]) {
                e.longContext = LongContext(thresholdInputTokens: Int(t), inMilli: im, outMilli: om, cacheMilli: milli(lc["cache_multiplier"]) ?? im)
            }
            for s in (o["schedule"] as? [[String: Any]]) ?? [] {
                if let f = s["from"] as? String, let r = rate(s) { e.schedule.append((from: f, rate: r)) }
            }
            e.schedule.sort { $0.from < $1.from }
            if e.standard == nil && !e.peakPriced { return nil }   // un cerveau sans prix lisible invalide toute la configuration (échec fermé)
            brains[id] = e
        }
        var profiles: [String: ProfileSpec] = [:]
        for (name, v) in (root["profiles"] as? [String: Any]) ?? [:] {
            guard let o = v as? [String: Any] else { continue }
            profiles[name] = ProfileSpec(name: name, chain: (o["chain"] as? [String]) ?? [], chainPublic: (o["chain_public"] as? [String]) ?? [],
                                         chainPrivate: (o["chain_private"] as? [String]) ?? [], requires: Set((o["requires"] as? [String]) ?? []),
                                         instant: (o["instant"] as? Bool) ?? false, deterministicFirst: (o["deterministic_first"] as? Bool) ?? false,
                                         batchIfNotUrgent: (o["batch_if_not_urgent"] as? Bool) ?? false,
                                         offpeakForBackground: (o["offpeak_for_background"] as? Bool) ?? false,
                                         otherFamilyThanWriter: (o["other_family_than_writer"] as? Bool) ?? false)
        }
        var terms: [String: ProviderTerms] = [:]
        for (id, v) in (troot["providers"] as? [String: Any]) ?? [:] {
            guard let o = v as? [String: Any] else { continue }
            terms[id] = ProviderTerms(id: id, noTrainingAPI: o["no_training_api"] as? Bool, retentionDays: (o["retention_days"] as? NSNumber)?.intValue,
                                      publicAllowed: (o["public_allowed"] as? Bool) ?? false, onDevice: (o["on_device"] as? Bool) ?? false,
                                      verified: o["verified"] as? String, trainingModels: Set((o["training_models"] as? [String]) ?? []),
                                      conditions: (o["conditions"] as? [String]) ?? [], evidence: (o["evidence"] as? String) ?? "")
        }
        let rule: [String: Any] = (troot["rule"] as? [String: Any]) ?? [:]
        let pw: [String: Any] = (root["peak_windows_utc"] as? [String: Any]) ?? [:]   // heures de pointe d'un fournisseur (aucune en version Meta)
        let days: Set<Int> = Set(((pw["days"] as? [String]) ?? []).compactMap { PeakWindows.dayNames[$0] })
        var wins: [(start: Int, end: Int)] = []
        for w in (pw["windows"] as? [[String]]) ?? [] where w.count == 2 {
            if let s = PeakWindows.minutes(w[0]), let e = PeakWindows.minutes(w[1]) { wins.append((start: s, end: e)) }
        }
        var alloc: [String: Micros] = [:]
        for (k, v) in (root["monthly_allocation_usd"] as? [String: Any]) ?? [:] { if let x = m(v) { alloc[k] = x } }
        let th: [Int] = ((b["alert_thresholds_pct"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        return BrainRegistry(brains: brains, profiles: profiles, terms: terms,
                             peakWindows: PeakWindows(weekdays: days, windows: wins, holidays: holidays),
                             monthlyHardCap: hard, monthlyPlanned: planned, dayCapForeground: dFg, dayCapBackground: dBg, perTaskCap: task,
                             alertThresholdsPct: th, allocations: alloc,
                             maxVerificationAgeDays: (rule["max_verification_age_days"] as? NSNumber)?.intValue ?? 90,
                             personalMaxRetentionDays: (rule["personal_max_retention_days"] as? NSNumber)?.intValue ?? 30)
    }

    // MARK: Coût (micro-dollars, arrondi au supérieur : jamais sous-compté)

    public func rate(_ e: BrainEntry, at d: Date, peak: Bool?) -> Rate? {
        if e.peakPriced { return (peak ?? peakWindows.isPeak(d)) ? e.peak : e.offpeak }
        let day: String = PeakWindows.dayKey(d)
        var r: Rate? = e.standard
        for s in e.schedule where s.from <= day { r = s.rate }
        return r
    }

    /// Coût d'un appel. `peak` nil = déduit de l'heure `at` (cerveaux à tarif de pointe seulement). `batch` sans multiplicateur connu → plein tarif.
    /// Cache lu ou écrit sans tarif publié → compté au tarif d'entrée (prudent).
    public func cost(_ id: String, usage u: Usage, at d: Date = Date(), batch: Bool = false, peak: Bool? = nil) -> Micros? {
        guard let e = brains[id], let r = rate(e, at: d, peak: peak) else { return nil }
        var mi: Int64 = 1000, mo: Int64 = 1000, mc: Int64 = 1000
        if let lc = e.longContext, u.promptTokens > lc.thresholdInputTokens { mi = lc.inMilli; mo = lc.outMilli; mc = lc.cacheMilli }
        let bm: Int64 = batch ? (e.batchMilli ?? 1000) : 1000
        let div: Int64 = 1_000_000 * 1_000_000   // (jetons / 1M) × (millièmes multiplicateur) × (millièmes batch)
        func term(_ tok: Int, _ price: Micros, _ mult: Int64) -> Micros { Money.mulDivCeil(Int64(tok), price * mult * bm, div) }
        var c: Micros = term(u.inputTokens, r.inp, mi) + term(u.outputTokens, r.out, mo)
        c += term(u.cacheRead, r.cacheRead ?? r.inp, mc)
        c += term(u.cacheWrite5m, r.cacheWrite5m ?? r.inp, mc)
        c += term(u.cacheWrite1h, r.cacheWrite1h ?? r.cacheWrite5m ?? r.inp, mc)
        return c
    }

    // MARK: Vérifications des données (tableau de bord : alerte au-delà de 30 jours)

    public static func daysBetween(_ a: String, _ b: Date) -> Int? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = PeakWindows.utc; f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: a) else { return nil }
        return Int(floor(b.timeIntervalSince(d) / 86400))
    }
    /// Cerveaux actifs dont le prix n'a pas été vérifié depuis plus de `days` jours (ou jamais).
    public func stalePrices(now: Date = Date(), days: Int = 30) -> [String] {
        brains.values.filter { e in
            guard e.enabled else { return false }
            guard let v = e.verified, let age = BrainRegistry.daysBetween(v, now) else { return true }
            return age > days
        }.map { $0.id }.sorted()
    }
    public var allocationTotal: Micros { allocations.values.reduce(0, +) }
}

// MARK: - Politique de données (2.3 amendée) — échec fermé

public struct PolicyContext {
    public var now: Date
    public var sciPolicyConfirmed: Bool
    public var touchIDConfirmed: Bool
    public var vaultProvider: String?      // fournisseur choisi explicitement par Ahadi pour un élément du coffre
    public init(now: Date = Date(), sciPolicyConfirmed: Bool = false, touchIDConfirmed: Bool = false, vaultProvider: String? = nil) {
        self.now = now; self.sciPolicyConfirmed = sciPolicyConfirmed; self.touchIDConfirmed = touchIDConfirmed; self.vaultProvider = vaultProvider
    }
}

public enum PolicyVerdict: Equatable {
    case allowed
    case denied(String)
    public var ok: Bool { if case .allowed = self { return true }; return false }
}

public enum DataPolicy {
    /// Conditions écrites suffisantes pour des données personnelles ? (aucun pays dans la décision)
    public static func personalOK(_ t: ProviderTerms, reg: BrainRegistry, now: Date) -> PolicyVerdict {
        guard t.noTrainingAPI == true else { return .denied("\(t.id) : non-entraînement sur les données API non garanti par écrit") }
        guard let r = t.retentionDays, r <= reg.personalMaxRetentionDays else { return .denied("\(t.id) : conservation non écrite ou > \(reg.personalMaxRetentionDays) jours") }
        guard let v = t.verified, let age = BrainRegistry.daysBetween(v, now), age >= -1, age < reg.maxVerificationAgeDays else {
            return .denied("\(t.id) : conditions non vérifiées depuis moins de \(reg.maxVerificationAgeDays) jours")
        }
        return .allowed
    }

    /// Ordre : autorisation (activé, conditions connues, palier sans entraînement, pas d'inférence locale) → classe de données.
    public static func check(_ e: BrainEntry, cls: DataClass, reg: BrainRegistry, ctx: PolicyContext) -> PolicyVerdict {
        if e.trainingTier { return .denied("\(e.id) : palier qui entraîne sur les données — jamais") }
        guard e.enabled else { return .denied("\(e.id) : désactivé") }
        guard let t = reg.terms[e.provider] else { return .denied("\(e.id) : conditions du fournisseur « \(e.provider) » inconnues → bloqué") }
        if t.trainingModels.contains(e.apiModel) || t.trainingModels.contains(e.id) {
            return .denied("\(e.id) : palier qui entraîne sur les données — jamais")
        }
        if t.onDevice { return .denied("\(e.id) : inférence LLM locale interdite (règle 6)") }
        switch cls {
        case .publicData:
            return t.publicAllowed ? .allowed : .denied("\(e.id) : conditions de \(t.id) non vérifiées, même pour du public")
        case .personal:
            return personalOK(t, reg: reg, now: ctx.now)
        case .sciInternal:
            guard ctx.sciPolicyConfirmed else { return .denied("sci_internal : sciPolicyConfirmed=false — demander à Ahadi") }
            return personalOK(t, reg: reg, now: ctx.now)
        case .vault:
            guard ctx.touchIDConfirmed else { return .denied("vault : Touch ID requis") }
            guard let vp = ctx.vaultProvider, vp == e.provider else { return .denied("vault : \(e.provider) n'est pas le fournisseur choisi explicitement") }
            return personalOK(t, reg: reg, now: ctx.now)
        }
    }

    /// Cerveaux autorisés pour une classe (diagnostic et tests).
    public static func eligible(_ cls: DataClass, reg: BrainRegistry, ctx: PolicyContext) -> [String] {
        reg.brains.values.filter { check($0, cls: cls, reg: reg, ctx: ctx).ok }.map { $0.id }.sorted()
    }
}

// MARK: - Plan de routage (2.4)

/// WP2 : `bench` = appels du banc de qualité (plafond du jour propre, réglage « budget_banc_jour_usd ») ; v2 ne l'utilise pas.
public enum Lane: String { case foreground, background, bench }

/// Vue du budget pour le planificateur (le grand livre la fournit ; les tests la simulent). La réservation atomique reste
/// faite par CostLedger.reserve juste avant l'envoi : ce filtre-ci ne sert qu'à choisir un modèle moins cher en amont.
public struct BudgetView {
    public var monthCommitted: Micros, dayCommitted: Micros, taskCommitted: Micros
    public init(month: Micros = 0, day: Micros = 0, task: Micros = 0) { monthCommitted = month; dayCommitted = day; taskCommitted = task }
}

public struct RouteRequest {
    public var profile: String
    public var items: [String?]                 // classe de chaque élément d'entrée (nil = absent → personal)
    public var lane: Lane
    public var estInputTokens: Int
    public var maxOutputTokens: Int
    public var requires: Set<String>
    public var allowlist: Set<String>?          // liste blanche (agent) : appliquée APRÈS le choix du profil
    public var writerFamily: String?            // profil verify : famille du rédacteur à éviter
    public var urgent: Bool
    public var preferred: String?               // cerveau (id du registre) épinglé par Ahadi : mis en tête s'il passe toutes les contraintes
    public init(profile: String, items: [String?], lane: Lane = .foreground, estInputTokens: Int = 0, maxOutputTokens: Int = 1500,
                requires: Set<String> = [], allowlist: Set<String>? = nil, writerFamily: String? = nil, urgent: Bool = true, preferred: String? = nil) {
        self.profile = profile; self.items = items; self.lane = lane; self.estInputTokens = estInputTokens; self.maxOutputTokens = maxOutputTokens
        self.requires = requires; self.allowlist = allowlist; self.writerFamily = writerFamily; self.urgent = urgent; self.preferred = preferred
    }
}

public struct RouteCandidate {
    public var brainId: String
    public var estimate: Micros
    public var batch: Bool
    public var peak: Bool?
}

public enum RoutePlan {
    case ok(cls: DataClass, candidates: [RouteCandidate], notes: [String])
    /// ask = il faut demander à Ahadi (sci_internal non confirmé, coffre sans Touch ID, plafond au premier plan).
    case blocked(cls: DataClass, reason: String, ask: Bool)
    /// Tâche de fond au-delà du budget : mise en file, rien n'est envoyé.
    case queued(cls: DataClass, reason: String)
    public var candidates: [RouteCandidate] { if case .ok(_, let c, _) = self { return c }; return [] }
    public var dataClass: DataClass {
        switch self { case .ok(let c, _, _): return c; case .blocked(let c, _, _): return c; case .queued(let c, _): return c }
    }
}

public enum RoutePlanner {
    /// Ordre des contraintes : autorisation → classe de données → capacités → (disponibilité) → budget → qualité/latence/prix (ordre du profil).
    /// Le repli ne change jamais la classe : elle est calculée UNE fois et chaque candidat est jugé contre elle.
    public static func plan(_ req: RouteRequest, reg: BrainRegistry, ctx: PolicyContext, budget: BudgetView,
                            isUp: (String) -> Bool = { _ in true }) -> RoutePlan {
        let cls: DataClass = DataClass.resolve(req.items)
        if cls == .sciInternal && !ctx.sciPolicyConfirmed {
            return .blocked(cls: cls, reason: "Données CAFU / Save the Children internes : la politique SCI n'est pas confirmée (sciPolicyConfirmed=false). Aucun envoi — confirme-la ou retire ces éléments.", ask: true)
        }
        if cls == .vault && !ctx.touchIDConfirmed {
            return .blocked(cls: cls, reason: "Élément du coffre : Touch ID et choix explicite du fournisseur requis. Aucun envoi.", ask: true)
        }
        guard let prof = reg.profiles[req.profile] else { return .blocked(cls: cls, reason: "Profil de routage inconnu : \(req.profile)", ask: false) }
        var ids: [String] = prof.chain
        if prof.chain.isEmpty { ids = cls == .publicData ? prof.chainPublic : prof.chainPrivate }   // verify : chaîne publique / privée du profil
        if let p = req.preferred, !p.isEmpty { ids = [p] + ids.filter { $0 != p } }
        if let allow = req.allowlist { ids = ids.filter { allow.contains($0) } }
        var out: [RouteCandidate] = []
        var notes: [String] = []
        var budgetRefusals: Int = 0
        let needs: Set<String> = prof.requires.union(req.requires)
        for id in ids {
            guard let e = reg.brains[id] else { notes.append("\(id) : absent du registre"); continue }
            // 1-2. autorisation puis classe de données
            let v: PolicyVerdict = DataPolicy.check(e, cls: cls, reg: reg, ctx: ctx)
            if case .denied(let why) = v { notes.append(why); continue }
            // 3. capacités
            if !needs.isSubset(of: e.caps) { notes.append("\(id) : capacité manquante (\(needs.subtracting(e.caps).sorted().joined(separator: ", ")))"); continue }
            if prof.instant && e.thinkingAlwaysOn { notes.append("\(id) : réflexion permanente, jamais pour l'instantané"); continue }
            if prof.otherFamilyThanWriter, let wf = req.writerFamily, wf == e.family { notes.append("\(id) : même famille que le rédacteur"); continue }
            if req.lane == .background && prof.offpeakForBackground && e.peakPriced && reg.peakWindows.isPeak(ctx.now) {
                notes.append("\(id) : heure de pointe — le fond attend les heures creuses"); continue
            }
            if !isUp(id) { notes.append("\(id) : indisponible"); continue }
            // 4. budget
            let batch: Bool = prof.batchIfNotUrgent && !req.urgent && e.batchMilli != nil
            let u = Usage(input: req.estInputTokens, output: req.maxOutputTokens)
            guard let est = reg.cost(id, usage: u, at: ctx.now, batch: batch) else { notes.append("\(id) : prix illisible"); continue }
            let dayCap: Micros = req.lane == .background ? reg.dayCapBackground : reg.dayCapForeground
            if budget.monthCommitted + est > reg.monthlyHardCap { notes.append("\(id) : plafond du mois (\(Money.format(reg.monthlyHardCap))) dépassé par \(Money.format(est))"); budgetRefusals += 1; continue }
            if budget.dayCommitted + est > dayCap { notes.append("\(id) : plafond du jour (\(req.lane.rawValue)) dépassé"); budgetRefusals += 1; continue }
            if budget.taskCommitted + est > reg.perTaskCap { notes.append("\(id) : plafond par tâche (\(Money.format(reg.perTaskCap))) dépassé"); budgetRefusals += 1; continue }
            out.append(RouteCandidate(brainId: id, estimate: est, batch: batch, peak: e.peakPriced ? reg.peakWindows.isPeak(ctx.now) : nil))
        }
        if !out.isEmpty { return .ok(cls: cls, candidates: out, notes: notes) }
        let detail: String = notes.joined(separator: " ; ")
        if budgetRefusals > 0 {   // au moins un candidat autorisé n'était bloqué QUE par le budget
            if req.lane == .background { return .queued(cls: cls, reason: "Plafond atteint : tâche de fond mise en file. " + detail) }
            return .blocked(cls: cls, reason: "Plafond atteint : rien n'est envoyé sans ton accord (aucune recharge). " + detail, ask: true)
        }
        return .blocked(cls: cls, reason: "Aucun fournisseur autorisé pour des données « \(cls.rawValue) » (profil \(req.profile)) — échec fermé. " + detail, ask: false)
    }
}
