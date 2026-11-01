import json, pathlib, subprocess, time, urllib.request, sys
import websocket

base = pathlib.Path.home() / "Library/Application Support/Nova"
parts = (base / ".session").read_text().split()
port, tok = parts[0], parts[1]
url = f"http://127.0.0.1:{port}/?t={tok}"
chrome = subprocess.Popen([
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "--headless=new", "--disable-gpu", "--no-first-run",
    "--remote-debugging-port=9334", "--user-data-dir=/tmp/nova-sweep-profile-" + str(int(time.time())),
    "--window-size=1600,1000", url,
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    ws_url = None
    for _ in range(60):
        try:
            tabs = json.load(urllib.request.urlopen("http://127.0.0.1:9334/json", timeout=3))
            for t in tabs:
                if t.get("type") == "page" and "webSocketDebuggerUrl" in t:
                    ws_url = t["webSocketDebuggerUrl"]; break
            if ws_url: break
        except Exception: pass
        time.sleep(0.4)
    ws = websocket.create_connection(ws_url, timeout=30)
    seq = [0]
    def ev(expr):
        seq[0] += 1; sid = seq[0]
        ws.send(json.dumps({"id": sid, "method": "Runtime.evaluate",
                            "params": {"expression": expr, "returnByValue": True}}))
        while True:
            m = json.loads(ws.recv())
            if m.get("id") == sid:
                r = m.get("result", {}).get("result", {})
                if r.get("subtype") == "error": return "ERR:" + str(r.get("description"))[:120]
                return r.get("value")
    ev("1"); time.sleep(7)
    mods = ev("(() => [...document.querySelectorAll('.rail-btn')].map(b => b.getAttribute('data-page')).filter(Boolean))()") or []
    print("modules rail:", len(mods), mods)
    results = []
    for mid in mods:
        ev(f"(() => {{ const b=[...document.querySelectorAll('.rail-btn')].find(x => x.getAttribute('data-page') === '{mid}'); if(b){{ b.click(); return 1; }} return 0; }})()")
        time.sleep(2.6)
        state = ev("""(() => {
          const err = document.querySelector('.pane.on .errbox, .float.on .errbox');
          const head = document.querySelector('.pane.on .pb-title, .pane-bar .pb-title');
          const bodyEl = document.querySelector('.pane.on .pane-body') || document.body;
          const txt = (bodyEl.innerText || '').trim();
          return JSON.stringify({titre: head ? head.textContent.trim() : '', err: err ? err.innerText.slice(0,120) : '', len: txt.length});
        })()""")
        try: st = json.loads(state)
        except Exception: st = {"titre": "?", "err": str(state)[:80], "len": 0}
        if not st.get("err") and (st.get("len") or 0) < 40:
            time.sleep(6)   # chargement lent != vide : re-mesure avant de conclure
            state = ev("""(() => {
              const bodyEl = document.querySelector('.pane.on .pane-body') || document.body;
              const txt = (bodyEl.innerText || '').trim();
              const err = document.querySelector('.pane.on .errbox, .float.on .errbox');
              return JSON.stringify({titre: '', err: err ? err.innerText.slice(0,120) : '', len: txt.length});
            })()""")
            try:
                st2 = json.loads(state); st["len"] = st2.get("len", st.get("len", 0)); st["err"] = st2.get("err", st.get("err", ""))
            except Exception: pass
        flag = "ERREUR" if st.get("err") else ("VIDE?" if (st.get("len") or 0) < 40 else "ok")
        results.append((mid, flag, st.get("titre", ""), st.get("len", 0), st.get("err", "")))
        print(f"{mid:16} {flag:7} titre={st.get('titre','')[:26]!r} texte={st.get('len',0)} {st.get('err','')[:70]}")
    bad = [r for r in results if r[1] != "ok"]
    print("\nBILAN:", len(results) - len(bad), "ok /", len(results), "| problèmes:", [(r[0], r[1]) for r in bad])
finally:
    chrome.terminate()
    try: chrome.wait(timeout=8)
    except Exception: chrome.kill()
