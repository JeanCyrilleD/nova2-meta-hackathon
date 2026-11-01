/* 29/10 (Ahadi : « Nova lague, surtout dans Messages : clics en retard ») — mesure RÉELLE des saccades de l'interface.
   Le profilage Instruments du processus Nova (22:52) montre un moteur calme (≈ 3,6 % CPU) : la lenteur vit dans la page.
   Ce témoin note, sans rien changer à l'affichage :
   • tout gel d'image > 250 ms (écart entre deux requestAnimationFrame) quand la fenêtre est visible ;
   • tout clic dont l'écran ne se met à jour qu'après > 150 ms ;
   avec l'onglet ouvert et la cible du dernier clic. Envoi groupé (toutes les 20 s) vers releves/diag/ui_events.txt. Aucun contenu. */
(function () {
  if (window.__novaJank) return; window.__novaJank = true;
  const buf = [];
  let lastInput = null;
  const where = () => { try { return (document.querySelector(".nav .on, [aria-current='page'], .dock .on") || {}).textContent?.trim().slice(0, 30) || location.hash || "?"; } catch (e) { return "?"; } };
  const sel = (el) => { try { if (!el || !el.tagName) return "?"; let s = el.tagName.toLowerCase(); if (el.id) s += "#" + el.id; const c = (el.className && typeof el.className === "string") ? el.className.trim().split(/\s+/).slice(0, 2).join(".") : ""; if (c) s += "." + c; return s.slice(0, 60); } catch (e) { return "?"; } };
  document.addEventListener("pointerdown", (e) => {
    const t0 = performance.now(); lastInput = { t: t0, target: sel(e.target) };
    requestAnimationFrame(() => setTimeout(() => { const d = performance.now() - t0; if (d > 150) buf.push(["clic_lent", Math.round(d), where(), lastInput.target]); }, 0));
  }, { capture: true, passive: true });
  let prev = performance.now();
  const loop = (now) => {
    const gap = now - prev; prev = now;
    if (gap > 250 && document.visibilityState === "visible" && document.hasFocus()) {
      const since = lastInput ? Math.round(now - lastInput.t) : -1;
      buf.push(["gel", Math.round(gap), where(), since >= 0 && since < 3000 ? (lastInput.target + " +" + since + "ms") : "sans clic"]);
    }
    requestAnimationFrame(loop);
  };
  requestAnimationFrame(loop);
  setInterval(() => {
    if (!buf.length) return;
    const rows = buf.splice(0, 40);
    for (const r of rows) {
      try { fetch("/api/ui/trace", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ev: r[0], pid: r[2], why: r[1] + "ms " + r[3] }) }); } catch (e) {}
    }
  }, 20000);
})();
