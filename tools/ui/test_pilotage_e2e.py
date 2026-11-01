#!/usr/bin/env python3
"""PILOTAGE (01/11) — test de bout en bout SIMULÉ du pont d'interface (uibridge.js) dans Chromium sans tête.
Le moteur est remplacé par ce script : il pousse des ordres « ui » sur /api/events (SSE) exactement comme
UIPilot.request, et relit les constats postés sur /api/ui/result. Données /api/* simulées (mock_api.json),
aucun appel réel, aucune clé, aucun réglage réel. Usage : python3 tools/ui/test_pilotage_e2e.py [dossier_captures]"""
import json, os, sys, time, threading, queue, http.server, urllib.parse, uuid
from playwright.sync_api import sync_playwright
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mock_server as M   # serveur statique + réponses simulées

ORDERS: "queue.Queue[dict]" = queue.Queue()
RESULTS: dict = {}
POSTS: list = []

class E2E(M.H):
    def do_GET(self):
        if urllib.parse.urlparse(self.path).path == "/api/events":
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Cache-Control", "no-cache"); self.end_headers()
            t0 = time.time()
            try:
                while time.time() - t0 < 240:
                    try:
                        o = ORDERS.get(timeout=1.0)
                        self.wfile.write(("event: ui\ndata: " + json.dumps(o, ensure_ascii=False) + "\n\n").encode()); self.wfile.flush()
                    except queue.Empty:
                        self.wfile.write(b": ping\n\n"); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        u = urllib.parse.urlparse(self.path)
        if u.path == "/api/conversation":   # fil simulé ; « conv-absente » = fil que le moteur ne connaît pas
            cid = (urllib.parse.parse_qs(u.query).get("id") or [""])[0]
            body = {} if cid == "conv-absente" else {"id": cid, "title": "Fil E2E", "messages": [{"role": "user", "content": "bonjour", "ts": "2026-11-01T08:00:00Z"}, {"role": "assistant", "content": "salut", "ts": "2026-11-01T08:00:02Z"}]}
            d = json.dumps(body).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d); return
        return super().do_GET()
    def do_POST(self):
        p = urllib.parse.urlparse(self.path).path
        n = int(self.headers.get("Content-Length") or 0); raw = self.rfile.read(n)
        try: body = json.loads(raw or b"{}")
        except Exception: body = {}
        if p == "/api/ui/result":
            RESULTS[body.get("id")] = body.get("result")
            d = b'{"ok":true}'
        else:
            POSTS.append((p, body))
            d = json.dumps({"ok": True, "settings": body} if p == "/api/settings" else {"ok": True}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d)

def order(op, timeout=12, **args):
    i = uuid.uuid4().hex[:10]; o = dict(args); o["id"] = i; o["op"] = op
    ORDERS.put(o); t0 = time.time()
    while time.time() - t0 < timeout:
        if i in RESULTS: return RESULTS.pop(i)
        time.sleep(0.05)
    return None

FAILS = []
def check(name, cond, detail=""):
    print(("  OK  " if cond else "  FAIL ") + name + ("" if cond else "  → " + str(detail)[:600]))
    if not cond: FAILS.append(name)

def main():
    out = sys.argv[1] if len(sys.argv) > 1 else ""
    port = 8813
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), E2E)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    with sync_playwright() as p:
        b = p.chromium.launch()
        ctx = b.new_context(viewport={"width": 1280, "height": 800})
        ctx.add_init_script("try{localStorage.setItem('nova2_theme','harmattan-nuit');localStorage.setItem('nova2_identite_v1','1');}catch(e){}")
        pg = ctx.new_page(); errs = []
        pg.on("pageerror", lambda e: errs.append(str(e)[:200]))
        pg.goto("http://127.0.0.1:%d/index.html" % port); pg.wait_for_timeout(2500)
        if out:
            os.makedirs(out, exist_ok=True)

        r = order("go", q="cerveaux", section="")
        check("go cerveaux → Réglages › Assistant (alias + section déduite), vérifié", bool(r and r.get("ok") and r.get("ecran") == "settings" and (r.get("section") or {}).get("label") == "Assistant" and r["effet"]["section_active"] == "Assistant"), r)
        lignes = [c.get("ligne") for c in ((r or {}).get("etat") or {}).get("controles", [])]
        check("état relu : lignes de réglage et valeurs renvoyées", any("Cerveau" in (l or "") for l in lignes), lignes)
        if out: pg.screenshot(path=os.path.join(out, "apres-go-cerveaux-1280.png"))

        r = order("go", q="reglages", section="Taille du texte des réponses")
        check("go réglages | <ligne d'une section masquée> → section révélée (via ligne)", bool(r and r.get("ok") and (r.get("section") or {}).get("via") == "ligne" and r["effet"]["section_active"].startswith("Apparence")), r)

        order("go", q="settings", section="Général")
        r = order("clic", q="Taille du texte des réponses > Grand")
        e = (r or {}).get("effet") or {}
        check("ui-clic « ligne > option » depuis une autre section → valeur relue « Grand »", bool(r and r.get("ok") and e.get("valeur_relue") == "Grand" and e.get("valeur_avant") != "Grand"), r)
        check("… et la fenêtre l'a réellement appliquée (data-text-size=l)", pg.evaluate("() => document.documentElement.dataset.textSize") == "l")
        check("… et enregistrée par la route normale /api/settings", any(pp == "/api/settings" and bb.get("text_size") == "l" for pp, bb in POSTS), POSTS[-3:])

        r = order("clic", q="Notifications > off")
        e = (r or {}).get("effet") or {}
        check("ui-clic « Notifications > off » → bascule relue désactivée, conforme", bool(r and r.get("ok") and (r.get("deja") or e.get("conforme") is True)), r)
        r2 = order("clic", q="Notifications > off")
        check("même ordre rejoué → « déjà » sans re-cliquer (idempotent)", bool(r2 and r2.get("ok") and r2.get("deja")), r2)

        r = order("clic", q="bouton qui n'existe pas")
        check("clic introuvable → échec précis + éléments et lignes proposés", bool(r and r.get("ok") is False and isinstance(r.get("elements"), list) and isinstance(r.get("lignes_reglages"), list)), r)

        r = order("go", q="xyz")
        check("go xyz → échec précis avec candidats (aucun ok fictif)", bool(r and r.get("ok") is False and r.get("candidats")), r)
        r = order("go", q="settings", section="section imaginaire")
        check("section introuvable → ok:false, écran ouvert dit, sections disponibles listées", bool(r and r.get("ok") is False and (r.get("section") or {}).get("disponibles")), r)

        r = order("etat")
        check("etat → écran, section active, contrôles relus", bool(r and r.get("ok") and r.get("ecran") == "settings" and r.get("section_active") and r.get("controles")), r)

        r = order("reglages-appliquer", patch={"read_width": "wide", "text_size": "zz"})
        e = (r or {}).get("effet") or {}
        check("reglages-appliquer : valeur valide appliquée et relue, valeur hors liste refusée", bool(r and r.get("ok") and e.get("applique", {}).get("read_width") == "wide" and "text_size" in e.get("refus", {})), r)
        check("… attribut du document réellement posé (data-read-width=wide)", pg.evaluate("() => document.documentElement.dataset.readWidth") == "wide")

        r = order("go", q="chat")
        check("go chat → Conversations (alias)", bool(r and r.get("ok") and r.get("ecran") == "conversations"), r)
        r = order("conv", cid="conv-e2e-1", timeout=14)
        check("conv <id> → conversation affichée relue (nova:conv-active)", bool(r and r.get("ok") and r["effet"]["conversation_affichee"] == "conv-e2e-1"), r)
        if out: pg.screenshot(path=os.path.join(out, "apres-conv-1280.png"))
        r = order("conv", cid="conv-absente", timeout=14)
        check("conv d'un fil inconnu du moteur → ok:false honnête (jamais « affichée »)", bool(r and r.get("ok") is False), r)

        r = order("go", q="medias")
        check("go medias → écran Médias vérifié", bool(r and r.get("ok") and r.get("ecran") == "radio"), r)
        if out:
            order("go", q="cerveaux")
            for w in (1280, 760, 390):
                pg.set_viewport_size({"width": w, "height": 820}); pg.wait_for_timeout(500)
                pg.screenshot(path=os.path.join(out, "reglages-assistant-%d.png" % w))
        check("aucune erreur JS de page", not errs, errs)
        ctx.close(); b.close()
    srv.shutdown()
    print("PILOTAGE E2E :", "TOUT PASSE" if not FAILS else "%d ÉCHEC(S)" % len(FAILS))
    sys.exit(1 if FAILS else 0)

if __name__ == "__main__":
    main()
