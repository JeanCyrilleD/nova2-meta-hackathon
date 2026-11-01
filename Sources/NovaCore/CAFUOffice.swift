import Foundation

/// Mise en forme CAFU des fichiers Word (.docx) et PowerPoint (.pptx) — charte Bionic (Aptos / #C00000 / #ECE9E3 ; deck 16:9 Calibri rouge #E21D1B).
/// Rien n'est envoyé : les fichiers sont écrits dans ~/…/cafu et leur chemin est renvoyé.
enum CAFUOffice {
    static let pyCandidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]

    static func python(for module: String) -> String? {
        var cands: [String] = []
        let res: (Int32, String) = runProcess("/bin/zsh", ["-lc", "command -v python3"], timeout: 8)
        if res.0 == 0 {
            let line: String = res.1.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("/") { cands.append(line) }
        }
        cands.append(contentsOf: pyCandidates)
        let fw: String = "/Library/Frameworks/Python.framework/Versions"
        let vers: [String] = (try? FileManager.default.contentsOfDirectory(atPath: fw)) ?? []
        for v in vers { cands.append(fw + "/" + v + "/bin/python3") }
        for p in cands {
            if !FileManager.default.isExecutableFile(atPath: p) { continue }
            let r: (Int32, String) = runProcess(p, ["-c", "import " + module], timeout: 45)
            if r.0 == 0 { return p }
        }
        return nil
    }

    static func outPath(_ prefix: String, _ ext: String) -> String {
        let dir = Paths.home.appendingPathComponent("cafu", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return dir.appendingPathComponent("\(prefix)-\(f.string(from: Date())).\(ext)").path
    }

    static func run(kind: String, arg: String) -> String {
        let a = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, a.first == "{" else { return "cafu_format_\(kind) : argument = JSON (voir description de l'outil)." }
        let mod = kind == "deck" ? "pptx" : "docx"
        guard let py = python(for: mod) else { return "cafu_format_\(kind) : python-\(mod) introuvable sur ce Mac. Installation (à lancer par toi dans Terminal) : python3 -m pip install python-\(mod)" }
        let tool = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent(".bionic-tools")
        let out = outPath("cafu-" + (kind == "deck" ? "deck" : "note"), kind == "deck" ? "pptx" : "docx")
        let script = Paths.file("cafu_office.py")
        try? pyScript.write(to: script, atomically: true, encoding: .utf8)
        let (code, text) = runProcess(py, [script.path, kind, out, tool], timeout: 60, stdin: a.data(using: .utf8))
        if code != 0 || !FileManager.default.fileExists(atPath: out) { return "cafu_format_\(kind) : échec (code \(code)). \(shortError(text))" }
        _ = runProcess("/usr/bin/xattr", ["-c", out], timeout: 5)
        try? a.write(toFile: out + ".json", atomically: true, encoding: .utf8)   // contenu source : sert à l'aperçu intégré à Nova
        return "Fichier \(kind == "deck" ? "PowerPoint" : "Word") aux normes CAFU créé : \(out)\nRIEN n'a été envoyé. \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    // ---- Aperçu intégré à Nova : méta (contenu JSON), vignette réelle (Quick Look), ouverture dans Word/PowerPoint ----
    static func validName(_ n: String) -> Bool { n.range(of: #"^cafu-(deck|note)-[0-9]{8}-[0-9]{6}\.(pptx|docx)$"#, options: .regularExpression) != nil }
    static func path(_ n: String) -> String? { validName(n) ? Paths.home.appendingPathComponent("cafu", isDirectory: true).appendingPathComponent(n).path : nil }

    static func meta(_ n: String) -> [String: Any] {
        guard let p = path(n), FileManager.default.fileExists(atPath: p) else { return ["error": "fichier introuvable"] }
        let raw = (try? String(contentsOfFile: p + ".json", encoding: .utf8)) ?? "{}"
        let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) ?? [String: Any]()
        return ["kind": n.hasSuffix(".pptx") ? "deck" : "note", "name": n, "path": p, "data": obj]
    }

    static func thumb(_ n: String) -> Data? {
        guard let p = path(n), FileManager.default.fileExists(atPath: p) else { return nil }
        let cache = p + ".png"
        if let d = FileManager.default.contents(atPath: cache), d.count > 500 { return d }
        let tmp = NSTemporaryDirectory() + "nova-ql-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        _ = runProcess("/usr/bin/qlmanage", ["-t", "-s", "1400", "-o", tmp, p], timeout: 30)
        guard let d = FileManager.default.contents(atPath: tmp + "/" + n + ".png"), d.count > 500 else { return nil }
        try? d.write(to: URL(fileURLWithPath: cache))
        return d
    }

    static func openFile(_ n: String) -> Bool {
        guard let p = path(n), FileManager.default.fileExists(atPath: p) else { return false }
        return runProcess("/usr/bin/open", [p], timeout: 10).0 == 0
    }

    static let pyScript = #"""
import sys, json, os, zipfile, hashlib
kind, out, tooldir = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.loads(sys.stdin.read())
def S(x): return x if isinstance(x, str) else ("" if x is None else str(x))
def L(x): return [S(i) for i in x] if isinstance(x, list) else ([S(x)] if x else [])
# NOVA2-FIX 21/10 (R-216) : le markdown du modèle ne doit jamais s'imprimer tel quel.
# _md_runs : **gras** → vrais runs gras pour C.text (PPTX, aucun parsing côté cafu_style).
# _md_strip : retire les marqueurs des champs rendus en run unique à style déjà fixé (titres, en-têtes).
import re as _mdre
def _md_strip(s): return _mdre.sub(r"\*\*([^*]+)\*\*", r"\1", S(s))
def _md_runs(s, size, bold, color):
    runs = []
    for part in _mdre.split(r"(\*\*[^*]+\*\*)", S(s)):
        if not part: continue
        if part.startswith("**") and part.endswith("**") and len(part) > 4: runs.append((part[2:-2], size, True, color))
        else: runs.append((part, size, bold, color))
    return runs or [(S(s), size, bold, color)]
# --- VERROUILLAGE DE LA CHARTE : cafu_style.py doit correspondre à son empreinte SHA-256 (cafu_style.py.sha256) ---
sys.path.insert(0, tooldir)
_sp = os.path.join(tooldir, "cafu_style.py")
try:
    _h = hashlib.sha256(open(_sp, "rb").read()).hexdigest()
    _ref = open(_sp + ".sha256").read().split()[0]
except Exception as e:
    print("CHARTE INTROUVABLE OU NON VERROUILLÉE : " + str(e)); sys.exit(3)
if _h != _ref:
    print("CHARTE MODIFIÉE (empreinte différente) : génération bloquée. Régénérer cafu_style.py.sha256 seulement sur ordre d'Ahadi."); sys.exit(3)
import cafu_style as C
if kind == "deck":
    prs = C.new_deck()
    _t = _md_strip(S(d.get("titre")) or "Titre")
    C.title_slide(prs, "CAFU · CONTEXT ANALYSIS AND FORESIGHT UNIT", [(_t, C.cover_size(_t))], _md_strip(d.get("sous_titre")), _md_strip(d.get("contexte")), _md_strip(d.get("date")), _md_strip(d.get("auteur")) or "Ahadi Dahani")
    for sl in d.get("slides", []):
        s = C.slide(prs); C.kicker(s, _md_strip(sl.get("kicker")).upper()); C.title(s, _md_strip(sl.get("titre"))); C.rule(s)
        pts = L(sl.get("points"))
        if 0 < len(pts) <= 4:
            w = 12.0 / max(len(pts), 1) - 0.25
            for i, p in enumerate(pts):
                head, _, rest = p.partition(":")
                if not rest: head, rest = " ".join(p.split()[:3]), p
                C.num_card(s, 0.7 + i * (w + 0.25), 2.4, "%02d" % (i + 1), _md_strip(head).strip()[:28], _md_strip(rest).strip(), w=w)
        elif pts:
            C.text(s, 0.7, 2.4, 12.0, 4.0, [_md_runs("•  " + p, 15, False, C.DARK) for p in pts], space_after=8)
        C.footer(s, _md_strip(sl.get("takeaway")))
        if sl.get("notes"): C.notes(s, _md_strip(sl.get("notes")))
    prs.save(out)
    iss = C.audit_deck(out)
    print("Audit de charte : " + ("OK, aucun problème." if not iss else "; ".join(iss[:8])))
else:
    # NOVA2-FIX 21/10 (R-216) : champs que note_docx rend en add_run brut (titres, en-têtes,
    # pied…) — on retire les marqueurs ** ; leur style est déjà fixé par la charte (gras, couleur).
    for _k in ("titre", "sous_titre", "auteur", "statut", "date", "type", "type_note", "pied", "encadre_titre", "limites_titre"):
        if isinstance(d.get(_k), str): d[_k] = _md_strip(d[_k])
    if isinstance(d.get("contexte"), str): d["contexte"] = _md_strip(d["contexte"])
    elif isinstance(d.get("contexte"), list): d["contexte"] = [_md_strip(c) for c in d["contexte"]]
    for _sec in d.get("sections", []):
        if isinstance(_sec.get("titre"), str): _sec["titre"] = _md_strip(_sec["titre"])
        _tb = _sec.get("tableau")
        if isinstance(_tb, dict) and isinstance(_tb.get("entetes"), list): _tb["entetes"] = [_md_strip(h) for h in _tb["entetes"]]
    C.note_docx(d, out)
    iss = C.audit_note(out)
    print("Audit de charte : " + ("OK, aucun problème." if not iss else "; ".join(iss[:8])))
    z = zipfile.ZipFile(out); bad = z.testzip(); z.close()
    print("Contrôle d'intégrité : " + ("OK." if bad is None else "ERREUR " + str(bad)))
"""#
}
