#!/usr/bin/env python3
"""fix-boutons (31/10) — preuve de non-régression PAR ÉCHANGE DE FEUILLE, dans la même page au même instant.
Pour chaque thème × mode et chaque module : la page est chargée avec la feuille d'AVANT (web d'avant), capture 1 ;
on remplace à chaud css/identite.css par la version d'APRÈS, capture 2 ; on remet l'ancienne, capture 3 (bruit résiduel).
Ainsi seul l'effet du CSS est mesuré (pas d'horloge, de données ou d'animation qui diffèrent entre deux chargements).
Usage : python3 tools/ui/css_swap_diff.py <web_avant> <identite_apres.css> <sortie> [theme-mode ...]  (BC_PART=k/n pour paralléliser)
Sortie : swap__<thème>__<module>.json = { bruit, hors_boutons, mise_en_page_identique, changes:[{sel, txt, box, px}] }."""
import os, sys, re, json, threading, datetime, http.server, urllib.parse
import numpy as np
from PIL import Image
from playwright.sync_api import sync_playwright
HERE = os.path.dirname(os.path.abspath(__file__))
web, after_css, out = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2]), os.path.abspath(sys.argv[3]); os.makedirs(out, exist_ok=True)
MATS = ["harmattan", "fleuve", "sentinelle", "obsidienne", "verre", "graphite", "sable"]
THEMES = sys.argv[4:] or ["%s-%s" % (m, x) for m in MATS for x in ("jour", "nuit")]
MODS = re.findall(r'\{ id: "([a-z]+)", icon:', open(os.path.join(web, "js", "shell.js"), encoding="utf-8").read())
PART = os.environ.get("BC_PART", "")
if PART: k, n = map(int, PART.split("/")); MODS = MODS[k - 1::n]
_today = datetime.date.today()
MOCK = json.loads(re.sub(r'"@(-?\d+)', lambda m: '"' + (_today + datetime.timedelta(days=int(m.group(1)))).isoformat(),
                         open(os.path.join(HERE, "mock_api_boutons.json"), encoding="utf-8").read()))
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=web, **k)
    def log_message(self, *a): pass
    def do_GET(self):
        pth = urllib.parse.urlparse(self.path).path
        if pth == "/__apres.css":
            d = open(after_css, "rb").read(); self.send_response(200); self.send_header("Content-Type", "text/css"); self.end_headers(); self.wfile.write(d); return
        if pth.startswith("/api/"):
            body = MOCK.get(pth, {}); d = b"{}" if body == "__404__" else json.dumps(body, ensure_ascii=False).encode()
            self.send_response(404 if body == "__404__" else 200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(d); return
        return super().do_GET()
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0)); self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H); port = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()
FREEZE = "*,*::before,*::after{animation-play-state:paused!important;transition:none!important;caret-color:transparent!important}"
SWAP = """async (href) => { const l = [...document.querySelectorAll('link[rel=stylesheet]')].find(x => /identite\\.css|__apres\\.css/.test(x.getAttribute('href')));
  const n = l.cloneNode(); n.setAttribute('href', href); await new Promise(r => { n.onload = r; n.onerror = r; l.after(n); }); l.remove(); }"""
BOXES = """() => [...document.querySelectorAll('button, a.btn, [role=button], .btn, .chip, .ds-chip, .hq-chip, .hq-btn')].map(e => { const r = e.getBoundingClientRect();
  const p = []; for (let a = e; a && a.nodeType === 1 && p.length < 3; a = a.parentElement) p.unshift(a.tagName.toLowerCase() + (a.classList.length ? '.' + [...a.classList].slice(0, 3).join('.') : ''));
  return { sel: p.join(' > '), txt: (e.innerText || '').trim().replace(/\\s+/g, ' ').slice(0, 40), box: [r.left, r.top, r.width, r.height] }; }).filter(b => b.box[2] > 0 && b.box[3] > 0)"""
def diff(a, b): return np.abs(a - b).sum(axis=2) > 24
try:
    with sync_playwright() as p:
        br = p.chromium.launch()
        for th in THEMES:
            mode = th.rsplit("-", 1)[1]
            for mid in MODS:
                pj = os.path.join(out, "swap__%s__%s.json" % (th, mid))
                if os.path.exists(pj): continue
                ctx = br.new_context(viewport={"width": 1280, "height": 1300}, color_scheme="dark" if mode == "nuit" else "light")
                ctx.add_init_script("try{localStorage.setItem('nova2_theme','%s');localStorage.setItem('nova2_identite_v1','1');localStorage.setItem('nova2_home_calm','0');localStorage.setItem('nova2_last_module','%s');}catch(e){}" % (th, mid))
                pg = ctx.new_page()
                try:
                    pg.goto("http://127.0.0.1:%d/index.html" % port); pg.wait_for_timeout(2500)
                    pg.add_style_tag(content=FREEZE); pg.mouse.move(1279, 1299); pg.wait_for_timeout(300)
                    base = os.path.join(out, "%s__%s" % (th, mid)); shots = []
                    old_href = pg.evaluate("() => [...document.querySelectorAll('link[rel=stylesheet]')].find(x => /identite\\.css/.test(x.getAttribute('href'))).getAttribute('href')")
                    pg.screenshot(path=base + ".avant.png"); boxes = pg.evaluate(BOXES)
                    pg.evaluate(SWAP, "/__apres.css"); pg.wait_for_timeout(250); pg.screenshot(path=base + ".apres.png"); boxes2 = pg.evaluate(BOXES)
                    pg.wait_for_timeout(250); pg.screenshot(path=base + ".apres2.png")
                    pg.evaluate(SWAP, old_href); pg.wait_for_timeout(250); pg.screenshot(path=base + ".retour.png")
                    A, B, B2, C = (np.asarray(Image.open(base + s).convert("RGB"), dtype=np.int16) for s in (".avant.png", ".apres.png", ".apres2.png", ".retour.png"))
                    # bruit = ce qui bouge sans changement de feuille (avant↔retour, après↔après2), dilaté de 2 px
                    nz = diff(A, C) | diff(B, B2); dac = nz.copy()
                    for dy in (-2, -1, 1, 2): dac |= np.roll(nz, dy, axis=0)
                    nz = dac.copy()
                    for dx in (-2, -1, 1, 2): dac |= np.roll(nz, dx, axis=1)
                    dab = diff(A, B) & diff(C, B2)   # effet de la feuille : stable dans les deux sens
                    allow = np.zeros_like(dab); changes = []
                    for bx in boxes:
                        x, y, w, h = [int(v) for v in bx["box"]]; reg = (slice(max(0, y - 3), max(0, y + h + 3)), slice(max(0, x - 3), max(0, x + w + 3)))
                        n_ = int((dab[reg] & ~dac[reg]).sum())
                        if n_: changes.append(dict(bx, px=n_)); allow[reg] = True
                    hors = dab & ~allow & ~dac
                    res = {"bruit": int(dac.sum()), "hors_boutons": int(hors.sum()), "mise_en_page_identique": [b["box"] for b in boxes] == [b["box"] for b in boxes2], "changes": changes}
                    if hors.any(): ys, xs = np.nonzero(hors); res["hors_bbox"] = [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())]
                    json.dump(res, open(pj, "w"), ensure_ascii=False)
                    if not changes and not hors.any():
                        for s in (".avant.png", ".apres.png", ".apres2.png", ".retour.png"): os.remove(base + s)   # rien n'a changé : on ne garde pas les captures
                    else:
                        for s in (".apres2.png", ".retour.png"): os.remove(base + s)
                    print(th, mid, "changés:", len(changes), "hors:", res["hors_boutons"], "bruit:", res["bruit"], flush=True)
                except Exception as ex:
                    print(th, mid, "ÉCHEC", str(ex)[:120], flush=True)
                ctx.close()
        br.close()
finally:
    srv.shutdown()
