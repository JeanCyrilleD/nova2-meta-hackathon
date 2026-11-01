#!/usr/bin/env python3
"""fix-boutons (31/10) — contraste EFFECTIF de chaque élément cliquable visible, MESURÉ SUR LES PIXELS.
Pour chaque thème × mode et chaque module (MODULES de web/js/shell.js), deux captures : normale, puis avec le contenu
(texte, icônes) des éléments cliquables rendu transparent. Les pixels qui changent = le contenu ; leur contraste contre
le fond réellement affiché (dégradés, verre, opacité compris) donne le ratio WCAG. Données SIMULÉES (mock_server.py).
Serveur : web/ statique + réponses /api/* SIMULÉES lues dans tools/ui/mock_api_boutons.json (dates « @n » = aujourd'hui + n jours).
Usage : python3 tools/ui/button_contrast.py <web/> <dossier_sortie> [theme-mode ...]   → page__<thème>__<module>.json + captures PNG (pour diff avant/après)
Seuil signalé : < 3:1 (invisible ou peu lisible). Les éléments désactivés sont listés à part."""
import os, sys, re, json, time, threading, datetime, http.server, urllib.parse
from playwright.sync_api import sync_playwright
from PIL import Image
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
web, out = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2]); os.makedirs(out, exist_ok=True)
MATS = ["harmattan", "fleuve", "sentinelle", "obsidienne", "verre", "graphite", "sable"]
THEMES = sys.argv[3:] or ["%s-%s" % (m, x) for m in MATS for x in ("jour", "nuit")]
MODS = re.findall(r'\{ id: "([a-z]+)", icon:', open(os.path.join(web, "js", "shell.js"), encoding="utf-8").read())
PART = os.environ.get("BC_PART", "")   # « 1/2 » : moitié des modules (exécutions courtes en parallèle)
if PART: k, n = map(int, PART.split("/")); MODS = MODS[k - 1::n]
_today = datetime.date.today()
MOCK = json.loads(re.sub(r'"@(-?\d+)', lambda m: '"' + (_today + datetime.timedelta(days=int(m.group(1)))).isoformat(),
                         open(os.path.join(HERE, "mock_api_boutons.json"), encoding="utf-8").read()))
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=web, **k)
    def log_message(self, *a): pass
    def _api(self):
        pth = urllib.parse.urlparse(self.path).path
        if pth == "/api/events":
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers(); self.wfile.write(b": mock\n\n"); return
        body = MOCK.get(pth, {})
        if body == "__404__": self.send_response(404); self.end_headers(); return
        dd = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json; charset=utf-8"); self.send_header("Content-Length", str(len(dd))); self.end_headers(); self.wfile.write(dd)
    def do_GET(self):
        if self.path.startswith("/api/"): return self._api()
        return super().do_GET()
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0)); return self._api()
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H); port = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()
SEL = "button, a.btn, [role=button], [role=tab], .btn, .chip, .ds-chip, .hq-chip, .hq-link, .hq-kpi, .hq-btn, .hq-send, summary, input[type=button], input[type=submit], select"
FREEZE = "*,*::before,*::after{animation-play-state:paused!important;transition:none!important;caret-color:transparent!important}"
HIDE = ("[data-bs],[data-bs] *,[data-bs]::before,[data-bs]::after,[data-bs] *::before,[data-bs] *::after{color:transparent!important;"
        "-webkit-text-fill-color:transparent!important;text-shadow:none!important}[data-bs] :is(svg,img,canvas,video,i){opacity:0!important}")
# Style en ligne !important en plus de la feuille : un !important posé dans une @layer bat un !important hors couche.
INLINE = """(on) => { for (const r of document.querySelectorAll('[data-bs]')) for (const e of [r, ...r.querySelectorAll('*')]) {
  if (on) { e.dataset.bsOld = e.getAttribute('style') || ''; for (const [k, v] of [['color', 'transparent'], ['-webkit-text-fill-color', 'transparent'], ['text-shadow', 'none']]) e.style.setProperty(k, v, 'important');
            if (/^(svg|img|canvas|video|i)$/i.test(e.tagName)) e.style.setProperty('opacity', '0', 'important'); }
  else { if (e.dataset.bsOld) e.setAttribute('style', e.dataset.bsOld); else e.removeAttribute('style'); delete e.dataset.bsOld; } } }"""
COLLECT = """(sel) => {
  const out = [], mask = []; let n = 0; const cv = document.createElement('canvas'); cv.width = cv.height = 1; const g = cv.getContext('2d', { willReadFrequently: true }); const W = innerWidth, H = innerHeight;
  for (const c of document.querySelectorAll('canvas, video, .avatar, [class*=avatar], [class*=panda], .clock, [class*=clock], time')) { const r = c.getBoundingClientRect(); if (r.width > 0) mask.push([r.left, r.top, r.width, r.height]); }
  const all = [...document.querySelectorAll(sel)];
  for (const e of all) {
    if (e.closest('[data-bs]')) continue;
    const r = e.getBoundingClientRect(); if (r.width < 6 || r.height < 6) continue;
    if (r.right <= 0 || r.bottom <= 0 || r.left >= W || r.top >= H) continue;
    const cs = getComputedStyle(e); if (cs.visibility !== 'visible' || cs.display === 'none') continue;
    let op = 1; for (let a = e; a && a.nodeType === 1; a = a.parentElement) op *= parseFloat(getComputedStyle(a).opacity);
    if (op < 0.02) continue;
    const cx = Math.min(W - 1, Math.max(0, r.left + r.width / 2)), cy = Math.min(H - 1, Math.max(0, r.top + r.height / 2));
    const top = document.elementFromPoint(cx, cy); if (!top || !(top === e || e.contains(top))) continue;   // recouvert, ou rendu nulle part (contenu d'un <details> fermé)
    const txt = (e.innerText || e.value || '').trim().replace(/\\s+/g, ' ').slice(0, 40);
    const hasIcon = !!e.querySelector('svg, img, i, [class*=ic]');
    if (!txt && !hasIcon) continue;   // interrupteurs, pastilles : pas de contenu à lire
    let clip = false; for (let a = e; a && a.nodeType === 1; a = a.parentElement) { const c = getComputedStyle(a); if (c.backgroundClip === 'text' || c.webkitBackgroundClip === 'text') { clip = true; break; } }
    let masked = false; for (let a = e; a && a.nodeType === 1; a = a.parentElement) { const c = getComputedStyle(a); if ((c.maskImage && c.maskImage !== 'none') || (c.webkitMaskImage && c.webkitMaskImage !== 'none')) { masked = true; break; } }
    g.clearRect(0, 0, 1, 1); g.fillStyle = '#000'; g.fillStyle = cs.color; g.fillRect(0, 0, 1, 1); const rgba = Array.from(g.getImageData(0, 0, 1, 1).data);
    e.setAttribute('data-bs', n);
    const path = []; for (let a = e; a && a.nodeType === 1 && path.length < 3; a = a.parentElement) path.unshift(a.tagName.toLowerCase() + (a.classList.length ? '.' + [...a.classList].slice(0, 3).join('.') : ''));
    out.push({ i: n++, box: [r.left, r.top, r.width, r.height], txt, label: e.getAttribute('aria-label') || '', sel: path.join(' > '),
      clip, masked, rgba, disabled: !!(e.disabled || e.getAttribute('aria-disabled') === 'true'), opacity: +op.toFixed(2), color: cs.color, bg: cs.backgroundColor, bgimg: cs.backgroundImage !== 'none' });
  }
  return { out, mask };
}"""
def lum(px):   # px : tableau (..., 3) en 0–255 → luminance relative WCAG
    v = px / 255.0; v = np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)
    return v[..., 0] * 0.2126 + v[..., 1] * 0.7152 + v[..., 2] * 0.0722
def measure(A, B, box):
    x, y, w, h = [int(round(v)) for v in box]; x0, y0 = max(0, x), max(0, y); x1, y1 = min(A.shape[1], x + w), min(A.shape[0], y + h)
    if x1 - x0 < 2 or y1 - y0 < 2: return None, 0
    a = A[y0:y1, x0:x1]; b = B[y0:y1, x0:x1]
    m = np.abs(a - b).sum(axis=2) > 12
    n = int(m.sum())
    if n < 4: return 1.0, n
    la, lb = lum(a[m]), lum(b[m]); rs = np.sort((np.maximum(la, lb) + 0.05) / (np.minimum(la, lb) + 0.05))
    return round(float(rs[-min(8, n)]), 2), n   # 8e pixel le plus contrasté : le cœur du tracé (le flou de fond change aussi, faiblement)
res = []
try:
    with sync_playwright() as p:
        br = p.chromium.launch()
        for th in THEMES:
            mode = th.rsplit("-", 1)[1]
            for mid in MODS:
                pj = os.path.join(out, "page__%s__%s.json" % (th, mid))
                if os.path.exists(pj): res += json.load(open(pj)); continue   # reprise : page déjà mesurée
                ctx = br.new_context(viewport={"width": 1280, "height": 1300}, color_scheme="dark" if mode == "nuit" else "light")
                ctx.add_init_script("try{localStorage.setItem('nova2_theme','%s');localStorage.setItem('nova2_identite_v1','1');localStorage.setItem('nova2_home_calm','0');localStorage.setItem('nova2_last_module','%s');}catch(e){}" % (th, mid))
                pg = ctx.new_page(); errs = []; pg.on("pageerror", lambda e: errs.append(str(e)[:100]))
                try:
                    pg.goto("http://127.0.0.1:%d/index.html" % port); pg.wait_for_timeout(2500)
                    pg.add_style_tag(content=FREEZE); pg.mouse.move(1279, 1299); pg.wait_for_timeout(300)
                    fa = os.path.join(out, "%s__%s.png" % (th, mid)); pres = {}; unstable = 0
                    for attempt in range(3):   # éléments re-rendus pendant la mesure : on remesure (3 essais au plus)
                        pg.evaluate("() => document.querySelectorAll('[data-bs]').forEach(e => e.removeAttribute('data-bs'))")
                        d = pg.evaluate(COLLECT, SEL)
                        f1 = fa if attempt == 0 else os.path.join(out, "_shown%d.png" % os.getpid()); fb = os.path.join(out, "_hidden%d.png" % os.getpid())
                        pg.screenshot(path=f1); hs = pg.add_style_tag(content=HIDE); pg.evaluate(INLINE, True); pg.wait_for_timeout(150); pg.screenshot(path=fb)
                        moved = set(pg.evaluate("(n) => { const m = [], seen = new Set(); for (const e of document.querySelectorAll('[data-bs]')) { seen.add(+e.dataset.bs); const r = e.getBoundingClientRect(), b = n[+e.dataset.bs]; if (Math.abs(r.left - b[0]) + Math.abs(r.top - b[1]) + Math.abs(r.width - b[2]) + Math.abs(r.height - b[3]) > 1) m.push(+e.dataset.bs); } n.forEach((b, i) => { if (!seen.has(i)) m.push(i); }); return m; }", [e["box"] for e in d["out"]]))
                        hs.evaluate("e => e.remove()"); pg.evaluate(INLINE, False); pg.wait_for_timeout(150); fc = os.path.join(out, "_again%d.png" % os.getpid()); pg.screenshot(path=fc)
                        A, B, C = (np.asarray(Image.open(f).convert("RGB"), dtype=np.int16) for f in (f1, fb, fc))
                        unstable = 0
                        for e in d["out"]:
                            key = (e["sel"], e["txt"], tuple(int(v) for v in e["box"]))
                            if key in pres: continue
                            x, y, w, h = [int(v) for v in e["box"]]
                            if e["i"] in moved or (np.abs(A[max(0, y):y + h, max(0, x):x + w] - C[max(0, y):y + h, max(0, x):x + w]).sum(axis=2) > 12).any():
                                unstable += 1; continue   # a bougé, changé ou été re-rendu entre les captures : mesure non fiable, on réessaie
                            e["ratio"], e["px"] = measure(A, B, e["box"]); e.update(theme=th, module=mid)
                            bx = B[max(0, y):y + h, max(0, x):x + w].reshape(-1, 3)
                            if len(bx):   # ratio « théorique » : couleur calculée du texte posée sur le fond médian réellement affiché
                                bg = np.median(bx, axis=0); al = e["rgba"][3] / 255.0; fg = np.array(e["rgba"][:3]) * al + bg * (1 - al)
                                l1, l2 = float(lum(fg)), float(lum(bg)); e["theo"] = round((max(l1, l2) + 0.05) / (min(l1, l2) + 0.05), 2)
                            if e["ratio"] is not None: pres[key] = e
                        if not unstable: break
                        pg.wait_for_timeout(400)
                    pres = list(pres.values())
                    if unstable: print(th, mid, "non mesurés (instables) :", unstable, flush=True)
                    res += pres; json.dump(pres, open(pj, "w"), ensure_ascii=False)
                    json.dump(d["mask"], open(fa[:-4] + ".mask.json", "w"))
                    print(th, mid, len(d["out"]), "éléments", ("erreurs JS: %s" % errs[:2]) if errs else "", flush=True)
                except Exception as ex:
                    print(th, mid, "ÉCHEC", str(ex)[:120], flush=True)
                ctx.close()
        br.close()
finally:
    srv.shutdown()
def fautif(r):   # < 3:1 mesuré ; hors désactivés, texte peint par background-clip:text, fondu de défilement (mask-image),
    return r["ratio"] < 3 and not r["disabled"] and not r["clip"] and not r["masked"] and r.get("theo", 0) < 4.5   # et tracé fin dont la couleur calculée est conforme (≥ 4,5:1)
bad = [r for r in res if fautif(r)]
print("éléments mesurés :", len(res), "· sous 3:1 (actifs) :", len(bad), "· désactivés sous 3:1 :", len([r for r in res if r["ratio"] < 3 and r["disabled"]]))
