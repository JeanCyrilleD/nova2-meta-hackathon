import Foundation
import NovaFoundation

/// 31/10 02:03 (Ahadi : « empêche la veille de la machine ») — RESTER ÉVEILLÉ, à la demande.
/// Fichier dormant/RESTER_EVEILLE : un nombre d'heures (défaut 8) → `caffeinate -i -m -s -t …` lancé détaché (survit aux
/// relances de Nova) ; « off » → arrêt de CE caffeinate seulement (pid gardé dans dormant/caffeinate.pid — ceux d'autres apps,
/// Nova 1 comprise, ne sont jamais touchés). Aucun réglage système modifié (pas de pmset). État : releves/diag/eveil.json.
enum Eveil {
    static func tick(root: String) {
        let req: String = root + "/dormant/RESTER_EVEILLE"
        guard FileManager.default.fileExists(atPath: req) else { return }
        let txt: String = ((try? String(contentsOfFile: req, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try? FileManager.default.removeItem(atPath: req)
        let pidPath: String = root + "/dormant/caffeinate.pid"
        if let p = try? String(contentsOfFile: pidPath, encoding: .utf8), let pid = Int32(p.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
            kill(pid, SIGTERM)
            try? FileManager.default.removeItem(atPath: pidPath)
        }
        var etat: [String: Any] = ["ts": nowISO()]
        if txt == "off" || txt == "0" {
            etat["actif"] = false
        } else {
            let h: Double = min(24, max(0.5, Double(txt.replacingOccurrences(of: ",", with: ".")) ?? 8))
            let secs: Int = Int(h * 3600)
            let (_, out): (Int32, String) = runProcess("/bin/zsh", ["-c", "nohup /usr/bin/caffeinate -i -m -s -t " + String(secs) + " >/dev/null 2>&1 </dev/null & echo $!"], timeout: 5)
            let pid: String = out.trimmingCharacters(in: .whitespacesAndNewlines)
            try? pid.write(toFile: pidPath, atomically: true, encoding: .utf8)
            etat["actif"] = !pid.isEmpty
            etat["pid"] = pid
            etat["heures"] = h
            etat["jusqu_a"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval(secs)))
        }
        try? jsonData(etat).write(to: URL(fileURLWithPath: root + "/releves/diag/eveil.json"))
        _ = BlackBox.record(["tool": "eveil", "actor": "Nova", "ok": true, "effect": "lecture",
                             "why": "demande d'Ahadi : empêcher la veille du Mac", "result": (etat["actif"] as? Bool) == true ? "caffeinate actif" : "arrêté"])
    }
}
