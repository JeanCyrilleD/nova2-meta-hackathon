import Foundation
#if canImport(EventKit) && os(macOS)
import EventKit
#endif

// V5-O (25/10/2026) — Innovation 18 « CHRONOBIOLOGIE » : de vrais créneaux de travail profond.
//
// Rien d'inventé : aucune « énergie », aucun modèle de fatigue. Deux mesures réelles seulement :
// 1) les HEURES OÙ AHADI EST LE PLUS ACTIF — sur les 14 derniers jours, distribution par heure (GMT+0) de ses
//    messages de conversation (conversations.json, rôle user — même lecture que ameStats) et de ses actions
//    signées dans la BlackBox (acteur « Ahadi » / « Toi ») ;
// 2) son AGENDA RÉEL d'aujourd'hui et de demain — EventKit (début ET fin réels) si l'accès est accordé, sinon
//    l'outil calendar (fins inconnues : 60 min supposées, et la source le DIT) ; agenda illisible → aucun créneau.
// Un créneau = au moins 90 min libres d'affilée, DANS les heures de pic, HORS heures calmes (quiet_from/quiet_to),
// jamais dans le passé ; au plus 3 h (la meilleure sous-fenêtre si le trou est plus long).
// « Bloquer ce créneau » passe par l'outil existant calendar_add, APRÈS une carte d'approbation (Tools.registerAsk →
// /api/confirm) : POST /api/chrono/propose inscrit la demande, POST /api/chrono/block ne crée l'événement que si le GO
// d'Ahadi a été enregistré pour CETTE commande exacte. Réglage chronobio_on (défaut true) : false = route éteinte.

enum ChronoKit {
    static let utc: TimeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
    static func cal() -> Calendar {
        var c: Calendar = Calendar(identifier: .gregorian)
        c.timeZone = utc
        return c
    }
    static let minRun: Int = 90
    static let maxRun: Int = 180
    static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    /// Heures de pic : celles qui pèsent au moins 40 % de l'heure la plus active (et au moins 2 actes).
    static func peakHours(_ hours: [Int]) -> Set<Int> {
        let mx: Int = hours.max() ?? 0
        if mx <= 0 { return [] }
        let floor40: Int = Int((Double(mx) * 0.4).rounded(.up))
        let thr: Int = Swift.max(2, floor40)
        var out: Set<Int> = []
        for h in 0..<Swift.min(24, hours.count) where hours[h] >= thr { out.insert(h) }
        return out
    }

    /// Minute du jour dans les heures calmes [from, to) — passage de minuit compris ; from == to : jamais calme.
    static func inQuiet(_ m: Int, from a: Int, to b: Int) -> Bool {
        if a == b { return false }
        return a > b ? (m >= a || m < b) : (m >= a && m < b)
    }

    /// Plages [début, fin) de minutes libres consécutives d'au moins minLen.
    static func runs(_ mask: [Bool], minLen: Int) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var start: Int = -1
        for i in 0...mask.count {
            let free: Bool = i < mask.count ? mask[i] : false
            if free && start < 0 { start = i }
            if !free && start >= 0 {
                if i - start >= minLen { out.append((start, i)) }
                start = -1
            }
        }
        return out
    }

    /// Poids d'une fenêtre [s, e) : somme, minute par minute, de l'activité de son heure.
    static func weight(_ s: Int, _ e: Int, _ hours: [Int]) -> Int {
        var w: Int = 0
        var m: Int = s
        while m < e {
            let h: Int = m / 60
            if h >= 0 && h < hours.count { w += hours[h] }
            m += 1
        }
        return w
    }

    /// La meilleure sous-fenêtre d'au plus maxLen minutes (pas de 15 min) dans [s, e).
    static func bestWindow(_ s: Int, _ e: Int, _ hours: [Int], maxLen: Int) -> (Int, Int) {
        if e - s <= maxLen { return (s, e) }
        var best: (Int, Int) = (s, s + maxLen)
        var bestW: Int = -1
        var a: Int = s
        while a + maxLen <= e {
            let w: Int = weight(a, a + maxLen, hours)
            if w > bestW { bestW = w; best = (a, a + maxLen) }
            a += 15
        }
        return best
    }

    static func hhmm(_ m: Int) -> String {
        let mm: Int = ((m % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", mm / 60, mm % 60)
    }

    /// Créneaux d'une journée. busy : minutes [début, fin) occupées ce jour-là ; notBefore : première minute utilisable.
    static func slots(dayStart: Date, dayLabel: String, notBefore: Int, busy: [(Int, Int)], hours: [Int], peaks: Set<Int>,
                      quietFrom: Int, quietTo: Int) -> [[String: Any]] {
        var mask: [Bool] = Array(repeating: false, count: 1440)
        for m in 0..<1440 {
            mask[m] = m >= notBefore && peaks.contains(m / 60) && !inQuiet(m, from: quietFrom, to: quietTo)
        }
        for b in busy {
            let a: Int = Swift.max(0, b.0)
            let z: Int = Swift.min(1440, b.1)
            if a >= z { continue }
            for m in a..<z { mask[m] = false }
        }
        let mx: Int = Swift.max(1, hours.max() ?? 1)
        var out: [[String: Any]] = []
        for r in runs(mask, minLen: minRun) {
            let w: (Int, Int) = bestWindow(r.0, r.1, hours, maxLen: maxRun)
            let len: Int = w.1 - w.0
            let avg: Double = Double(weight(w.0, w.1, hours)) / Double(Swift.max(1, len))
            let score: Int = Int((100.0 * avg / Double(mx)).rounded())
            let n: Int = Int((avg * 1.0).rounded())
            let st: Date = dayStart.addingTimeInterval(Double(w.0) * 60)
            let en: Date = dayStart.addingTimeInterval(Double(w.1) * 60)
            let why: String = "Dans tes heures de pic (≈ " + String(n) + " actes par heure sur 14 j) · " + String(len) + " min libres d'affilée dans l'agenda · hors heures calmes"
            let one: [String: Any] = ["start": iso.string(from: st), "end": iso.string(from: en), "jour": dayLabel,
                                      "hhmm": hhmm(w.0) + "–" + hhmm(w.1), "minutes": len, "score": score, "why": why]
            out.append(one)
        }
        return out
    }
}

final class ChronoState: @unchecked Sendable {
    static let shared: ChronoState = ChronoState()
    let lock: NSLock = NSLock()
    var cached: [String: Any] = [:]
    var cachedAt: Date = Date.distantPast
    /// Propositions « Bloquer ce créneau » en attente de GO : id de la carte → (commande inscrite, argument calendar_add, libellé).
    var proposals: [String: (cmd: String, arg: String, label: String, at: Date)] = [:]
}

extension NovaApp {
    /// Activité réelle des 14 derniers jours, par heure GMT+0 : messages d'Ahadi + actions signées de la BlackBox.
    func chronoActivity(days: Int) -> (hours: [Int], messages: Int, actions: Int) {
        let c: Calendar = ChronoKit.cal()
        var hours: [Int] = Array(repeating: 0, count: 24)
        let msgs: [(Date, String)] = ameMessages(days: days, role: "user", limit: 100000)
        var nMsg: Int = 0
        for (d, t) in msgs {
            if t.hasPrefix("RÉSUMÉ DE LA CONVERSATION") || t.hasPrefix("[NOTE MOTEUR") { continue }
            hours[c.component(.hour, from: d)] += 1
            nMsg += 1
        }
        let since: Date = Date().addingTimeInterval(-Double(days) * 86400)
        var nAct: Int = 0
        for r in BlackBox.tail(4000) {
            guard let ts: String = r["ts"] as? String, let d: Date = ChronoKit.iso.date(from: ts), d >= since,
                  let e: [String: Any] = r["entry"] as? [String: Any], let actor: String = e["actor"] as? String,
                  actor == "Ahadi" || actor == "Toi" else { continue }
            hours[c.component(.hour, from: d)] += 1
            nAct += 1
        }
        return (hours, nMsg, nAct)
    }

    /// Rendez-vous réels entre d0 et d1 : (début, fin). readable = false → agenda illisible (aucun créneau ne sera proposé).
    func chronoEvents(from d0: Date, to d1: Date) -> (events: [(Date, Date)], source: String, readable: Bool) {
        #if canImport(EventKit) && os(macOS)
        if Tools.ekAuthorized(.event) {
            let store: EKEventStore = EKEventStore()
            var out: [(Date, Date)] = []
            for c in store.calendars(for: .event) {   // mêmes calendriers que Tools.ekCalendarText (fériés, anniversaires, Siri exclus)
                let cn: String = c.title
                if cn.contains("fériés") || cn.contains("Birthdays") || cn.contains("Anniversaires") || cn.contains("Siri") || cn.contains("Scheduled") { continue }
                let pred: NSPredicate = store.predicateForEvents(withStart: d0, end: d1, calendars: [c])
                for e in store.events(matching: pred) {
                    if e.isAllDay { continue }
                    let sd: Date = e.startDate
                    let ed: Date = e.endDate
                    if ed <= sd { continue }
                    out.append((sd, ed))
                }
            }
            return (out, "Calendrier (EventKit : début et fin réels des rendez-vous)", true)
        }
        #endif
        let evs: [[String: Any]] = dailyEvents(force: false)
        let st: DailyState = DailyState.shared
        st.lock.lock(); let note: String = st.calNote; st.lock.unlock()
        if evs.isEmpty && !note.isEmpty { return ([], "Agenda illisible : " + note, false) }
        var out: [(Date, Date)] = []
        for e in evs {
            let ts: Double = (e["ts"] as? Double) ?? 0
            if ts <= 0 { continue }
            let sd: Date = Date(timeIntervalSince1970: ts)
            if sd < d0.addingTimeInterval(-3600) || sd >= d1 { continue }
            out.append((sd, sd.addingTimeInterval(3600)))
        }
        return (out, "Agenda lu par l'outil calendar (fins inconnues : 60 min supposées par rendez-vous)", true)
    }

    func chronoCompute() -> [String: Any] {
        let now: Date = Date()
        let c: Calendar = ChronoKit.cal()
        let act: (hours: [Int], messages: Int, actions: Int) = chronoActivity(days: 14)
        let peaks: Set<Int> = ChronoKit.peakHours(act.hours)
        let peakRows: [[String: Any]] = peaks.sorted { (a: Int, b: Int) -> Bool in act.hours[a] != act.hours[b] ? act.hours[a] > act.hours[b] : a < b }
            .map { (h: Int) -> [String: Any] in ["h": h, "n": act.hours[h]] }
        let basis: [String: Any] = ["days": 14, "messages": act.messages, "actions": act.actions, "tz": "GMT+0"]
        let total: Int = act.messages + act.actions
        var out: [String: Any] = ["on": true, "peaks": peakRows, "hours": act.hours, "basis": basis, "generated": iso8601(now)]
        if total < 12 {
            out["slots"] = [[String: Any]]()
            out["source"] = "activité insuffisante"
            out["note"] = "Pas assez d'activité mesurée sur 14 jours (" + String(total) + " actes) pour situer tes heures de pic : aucun créneau proposé."
            return out
        }
        let today0: Date = c.startOfDay(for: now)
        let tomorrow0: Date = today0.addingTimeInterval(86400)
        let ev: (events: [(Date, Date)], source: String, readable: Bool) = chronoEvents(from: today0, to: tomorrow0.addingTimeInterval(86400))
        out["source"] = ev.source
        if !ev.readable {
            out["slots"] = [[String: Any]]()
            out["note"] = "Agenda illisible : impossible de dire ce qui est libre, aucun créneau proposé."
            return out
        }
        let qf: Int = Briefs.minutes(settings.get("quiet_from", "22:00")) ?? 0
        let qt: Int = Briefs.minutes(settings.get("quiet_to", "07:00")) ?? 0
        func busy(_ d0: Date) -> [(Int, Int)] {
            var b: [(Int, Int)] = []
            for e in ev.events {
                let a: Int = Int((e.0.timeIntervalSince(d0) / 60).rounded(.down))
                let z: Int = Int((e.1.timeIntervalSince(d0) / 60).rounded(.up))
                if z <= 0 || a >= 1440 { continue }
                b.append((a, z))
            }
            return b
        }
        let nowMin: Int = Int(now.timeIntervalSince(today0) / 60)
        let notBefore: Int = ((nowMin + 14) / 15) * 15
        var slots: [[String: Any]] = ChronoKit.slots(dayStart: today0, dayLabel: "aujourd'hui", notBefore: notBefore, busy: busy(today0),
                                                     hours: act.hours, peaks: peaks, quietFrom: qf, quietTo: qt)
        slots += ChronoKit.slots(dayStart: tomorrow0, dayLabel: "demain", notBefore: 0, busy: busy(tomorrow0),
                                 hours: act.hours, peaks: peaks, quietFrom: qf, quietTo: qt)
        out["slots"] = slots
        out["quiet"] = ["from": ChronoKit.hhmm(qf), "to": ChronoKit.hhmm(qt)]
        if slots.isEmpty { out["note"] = "Aucun créneau d'au moins 90 min libre dans tes heures de pic, aujourd'hui ni demain." }
        return out
    }

    func iso8601(_ d: Date) -> String { ChronoKit.iso.string(from: d) }

    func chronoRoutes() {
        let s = server
        // GET /api/chrono → {on, peaks:[{h, n}], hours:[24], slots:[{start, end, jour, hhmm, minutes, score, why}], source, generated, basis, note?}
        s.on("GET", "/api/chrono") { [self] req, res in
            if !settings.get("chronobio_on", true) {
                let off: [String: Any] = ["on": false, "peaks": [[String: Any]](), "slots": [[String: Any]](), "source": "", "generated": nowISO(),
                                          "note": "Chronobiologie désactivée dans Réglages."]
                res.json(off); return
            }
            let force: Bool = (req.query["force"] ?? "") == "1"
            let st: ChronoState = ChronoState.shared
            st.lock.lock()
            let fresh: Bool = !force && Date().timeIntervalSince(st.cachedAt) < 120 && !st.cached.isEmpty
            let cached: [String: Any] = st.cached
            st.lock.unlock()
            if fresh { res.json(cached); return }
            let r: [String: Any] = chronoCompute()
            st.lock.lock(); st.cached = r; st.cachedAt = Date(); st.lock.unlock()
            res.json(r)
        }
        // POST /api/chrono/propose {start, end} (ISO 8601) → inscrit la carte d'approbation ; RIEN n'est créé ici.
        s.on("POST", "/api/chrono/propose") { [self] req, res in
            if !settings.get("chronobio_on", true) { let e: [String: Any] = ["ok": false, "error": "chronobiologie désactivée"]; res.json(e, status: 409); return }
            let j: [String: Any] = req.json
            guard let a: String = j["start"] as? String, let b: String = j["end"] as? String,
                  let sd: Date = ChronoKit.iso.date(from: a), let ed: Date = ChronoKit.iso.date(from: b) else {
                let e: [String: Any] = ["ok": false, "error": "start et end ISO 8601 requis"]; res.json(e, status: 400); return }
            let mins: Int = Int(ed.timeIntervalSince(sd) / 60)
            if mins < 30 || mins > 240 || ed <= Date() { let e: [String: Any] = ["ok": false, "error": "créneau invalide (30 à 240 min, dans le futur)"]; res.json(e, status: 400); return }
            // calendar_add lit « AAAA-MM-JJ HH:MM » à l'heure LOCALE du Mac (DateFormatter par défaut) : même fuseau ici.
            let lf: DateFormatter = DateFormatter()
            lf.locale = Locale(identifier: "en_US_POSIX")
            lf.timeZone = TimeZone.current
            lf.dateFormat = "yyyy-MM-dd HH:mm"
            let hf: DateFormatter = DateFormatter()
            hf.locale = Locale(identifier: "fr_FR")
            hf.timeZone = TimeZone.current
            hf.dateFormat = "EEEE d MMMM, HH:mm"
            let hm: DateFormatter = DateFormatter()
            hm.locale = Locale(identifier: "fr_FR")
            hm.timeZone = TimeZone.current
            hm.dateFormat = "HH:mm"
            let title: String = "Travail profond (Nova)"
            let label: String = hf.string(from: sd) + "–" + hm.string(from: ed)
            let argObj: [String: Any] = ["title": title, "start": lf.string(from: sd), "end": lf.string(from: ed),
                                         "notes": "Créneau proposé par Nova (heures où tu es le plus actif, 14 j) et bloqué sur ton GO."]
            let arg: String = jsonString(argObj)
            let reg: (id: String, cmd: String) = Tools.registerAsk("calendar_add", arg, kind: "bloquer « " + title + " » dans Calendrier · " + label + " (aucune invitation envoyée)")
            let st: ChronoState = ChronoState.shared
            st.lock.lock()
            let old: Date = Date().addingTimeInterval(-3600)
            st.proposals = st.proposals.filter { $0.value.at > old }
            st.proposals[reg.id] = (cmd: reg.cmd, arg: arg, label: label, at: Date())
            st.lock.unlock()
            let ok: [String: Any] = ["ok": true, "id": reg.id, "title": title, "label": label, "start": a, "end": b,
                                     "what": "Créer l'événement « " + title + " » dans Calendrier, " + label + ". Aucune invitation ni message envoyé. Rien n'est créé sans ton GO."]
            res.json(ok)
        }
        // POST /api/chrono/block {id} → crée l'événement (outil calendar_add) SEULEMENT si le GO a été enregistré par /api/confirm.
        s.on("POST", "/api/chrono/block") { [self] req, res in
            let id: String = (req.json["id"] as? String) ?? ""
            let st: ChronoState = ChronoState.shared
            st.lock.lock()
            let p: (cmd: String, arg: String, label: String, at: Date)? = st.proposals[id]
            st.lock.unlock()
            guard let prop: (cmd: String, arg: String, label: String, at: Date) = p else {
                let e: [String: Any] = ["ok": false, "created": false, "error": "proposition inconnue ou expirée"]; res.json(e, status: 404); return }
            let key: String = prop.cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            Tools.apLock.lock()
            let goAt: Date? = Tools.approved[key]
            if goAt != nil { Tools.approved.removeValue(forKey: key) }
            Tools.apLock.unlock()
            guard let go: Date = goAt, Date().timeIntervalSince(go) < 300 else {
                let e: [String: Any] = ["ok": false, "created": false, "error": "aucun GO enregistré pour ce créneau : rien n'a été créé"]; res.json(e, status: 409); return }
            st.lock.lock(); st.proposals.removeValue(forKey: id); st.lock.unlock()
            let out: String = tools.run("calendar_add", prop.arg, why: "Bloquer un créneau de travail profond (" + prop.label + ") — GO d'Ahadi sur la carte de l'Agenda", actor: "Toi")
            let created: Bool = out.hasPrefix("Fait")
            st.lock.lock(); st.cachedAt = Date.distantPast; st.lock.unlock()
            let r: [String: Any] = ["ok": created, "created": created, "output": String(out.prefix(400)), "label": prop.label]
            res.json(r, status: created ? 200 : 502)
        }
    }
}
