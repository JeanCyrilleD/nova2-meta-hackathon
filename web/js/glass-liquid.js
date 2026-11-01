/* Nova — glass-liquid.js (30/10/2026, identité « Promesse » v3 : vrai Liquid Glass)
   Reflet spéculaire DYNAMIQUE : une lueur suit le pointeur sur la surface de verre survolée,
   et seulement sur elle. Un écouteur unique au niveau du document (passif), cadencé par
   requestAnimationFrame ; il n'écrit que --gx/--gy (propriétés @property NON héritées,
   css/identite.css) sur l'élément sous le pointeur, et la classe .lg-hot qui allume le
   reflet. Au repos : aucun travail (rien ne tourne sans mouvement de pointeur).
   Coupé si : thème hors identité, transparence réduite, mouvement réduit (système ou Nova). */
(function () {
  "use strict";
  if (window.__novaGlassSheen) return;
  window.__novaGlassSheen = true;
  var SEL = ".btn, .hq-glass, .hq-kpi, .hq-tile, .hq-chip, .hq-btn, .card, .tile, .home-card, .ncard, .theme-card, .composer, .rail-btn, .ds-chip, .nova-suite, .sb-search, .sb-preset, .msg.me, #rail";
  var root = document.documentElement;
  var mq = window.matchMedia ? matchMedia("(prefers-reduced-motion: reduce)") : { matches: false };
  var el = null, rect = null, x = 0, y = 0, raf = 0;
  function off() {
    return root.dataset.identite == null || root.dataset.reduceMotion === "1" || root.dataset.transparency === "reduced" || root.dataset.material === "sentinelle" || mq.matches;
  }
  function set(next) {
    if (el === next) return;
    if (el) el.classList.remove("lg-hot");
    el = next; rect = null;
    if (el) el.classList.add("lg-hot");
  }
  function frame() {
    raf = 0;
    if (!el || !el.isConnected) { set(null); return; }
    if (!rect) rect = el.getBoundingClientRect();
    el.style.setProperty("--gx", Math.round(x - rect.left) + "px");
    el.style.setProperty("--gy", Math.round(y - rect.top) + "px");
  }
  addEventListener("pointermove", function (e) {
    if (e.pointerType === "touch" || off()) { if (el) set(null); return; }
    var t = e.target && e.target.closest ? e.target.closest(SEL) : null;
    set(t);
    if (!t) return;
    x = e.clientX; y = e.clientY;
    if (!raf) raf = requestAnimationFrame(frame);
  }, { passive: true, capture: true });
  /* La géométrie change (défilement, redimensionnement) : le rectangle est relu au prochain geste. */
  addEventListener("scroll", function () { rect = null; }, { passive: true, capture: true });
  addEventListener("resize", function () { rect = null; }, { passive: true });
  document.addEventListener("pointerleave", function () { set(null); });
  addEventListener("blur", function () { set(null); });
})();
