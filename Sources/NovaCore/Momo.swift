import Foundation

/// Carnet mobile money (Orange Money, Moov Money, Wave…) : RAPPELS et suivi seulement.
/// Nova ne paie, ne transfère et ne tape aucun code : tu fais l'opération toi-même sur ton téléphone.
extension Tools {
    static let momoFile = JSONFile("momo.json")
    static func momo(_ raw: String) -> String {
        var raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.uppercased().hasPrefix("CONFIRMÉ:") || raw.uppercased().hasPrefix("CONFIRME:") { raw = String(raw.dropFirst(9)).trimmingCharacters(in: .whitespaces) }
        if raw.lowercased().hasPrefix("releve|") || raw.lowercased().hasPrefix("relevé|") {   // analyse d'un relevé collé (SMS / CSV) : lecture seule, aucun ordre
            let txt = String(raw[raw.index(after: raw.firstIndex(of: "|")!)...])
            return "Analyse du relevé (lecture seule) : " + jsonString(DotPacks.releve(txt))
        }
        let p = raw.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let act = (p.first ?? "").lowercased()
        var l = momoFile.read(default: [[String: Any]]())
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; let today = f.string(from: Date())
        func line(_ e: [String: Any]) -> String {
            let due = (e["due"] as? String) ?? ""; let late = !due.isEmpty && due < today && e["done"] as? Bool != true
            return "[\(e["id"] ?? "")] \(e["op"] ?? "") · \(e["amount"] ?? "") FCFA · \(e["label"] ?? "")" + (due.isEmpty ? "" : " · échéance \(due)") + (e["done"] as? Bool == true ? " · ✔ fait" : (late ? " · ⚠ EN RETARD" : ""))
        }
        switch act {
        case "add":
            guard p.count >= 4, let amt = Int(p[2].filter { $0.isNumber }) else { return "momo|add|Opérateur|montant|libellé|AAAA-MM-JJ (échéance facultative)" }
            let e: [String: Any] = ["id": String(UUID().uuidString.prefix(4)).lowercased(), "op": p[1], "amount": amt, "label": p[3], "due": p.count > 4 ? p[4] : "", "done": false, "created": today]
            l.append(e); momoFile.write(l); return "Noté (rappel seulement, rien n'est payé) : " + line(e)
        case "done":
            guard p.count > 1, let i = l.firstIndex(where: { ($0["id"] as? String) == p[1] }) else { return "momo|done|id" }
            l[i]["done"] = true; momoFile.write(l); return "Marqué comme fait : " + line(l[i])
        case "remove":
            guard p.count > 1 else { return "momo|remove|id" }
            l.removeAll { ($0["id"] as? String) == p[1] }; momoFile.write(l); return "Supprimé."
        default:
            let open = l.filter { $0["done"] as? Bool != true }.sorted { (($0["due"] as? String) ?? "9") < (($1["due"] as? String) ?? "9") }
            guard !open.isEmpty else { return "Mobile money : aucune opération à faire. (Nova ne paie jamais : il te rappelle.)" }
            let total = open.reduce(0) { $0 + (($1["amount"] as? Int) ?? 0) }
            return "Mobile money à faire (\(open.count), total \(total) FCFA) :\n" + open.map(line).joined(separator: "\n")
        }
    }
}
