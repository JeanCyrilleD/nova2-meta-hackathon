/* motion.js — CHORÉGRAPHIE DE MOUVEMENT DE NOVA (30/10/2026).

   Une seule couche, branchée sur la coquille par trois appels (shell.js : navigate → page(),
   openInSlot → mounting(), showInstance → shown()). Tout le reste est délégué (un écouteur
   par geste, des observateurs ciblés) : aucun module n'est modifié.

     1 · PAGES      Chorégraphie vivante (défaut) : la sortante s'efface en 180 ms en reculant
                    (scale .985) dans un calque inerte, l'entrante monte de 8 px (sens = ordre
                    du rail) et apparaît en 260 ms, cubic-bezier(.32,.72,0,1), départ +40 ms.
                    Aucune capture, aucun gel : la saisie n'est jamais bloquée ; la navigation
                    suivante termine net la précédente. View Transitions API : voie opt-in
                    (nova2_motion_vt = "1"), voir vtOptIn() — elle bloque le pointeur sous Chromium.
     2 · SÉLECTION  Pilule qui glisse (FLIP, transform seul) entre l'ancien et le nouvel
                    élément actif : rail, .seg, .ds-tabs, .ds-chips, barres d'onglets.
                    Pression : scale .97 en 120 ms (propriété « scale », WAAPI, compositeur).
     3 · CONTENU    Révélation échelonnée au PREMIER montage d'un module seulement
                    (≤ 8 éléments, 24 ms, total ≤ 300 ms), jamais au rafraîchissement ;
                    nouveaux messages du fil qui glissent, livrables et suites qui éclosent.
     4 · DÉFILEMENT Bord de défilement par IntersectionObserver (aucun écouteur scroll) :
                    la barre du panneau gagne liseré + ombre douce quand le contenu passe dessous.
     5 · SOBRIÉTÉ   prefers-reduced-motion / data-reduce-motion → fondu seul ; html[data-idle]
                    → aucune animation lancée, celles en cours terminées net.

   Budget : opacity / transform / translate / scale uniquement, jamais de flou animé, aucune
   propriété de mise en page. Désactivable : localStorage nova2_motion = "off". */

const doc = document;
const html = doc.documentElement;
const mqReduce = (() => { try { return matchMedia("(prefers-reduced-motion: reduce)"); } catch (e) { return { matches: false }; } })();
const reduced = () => mqReduce.matches || html.dataset.reduceMotion === "1";
const idle = () => html.dataset.idle === "1";
const quiet = () => idle() || doc.hidden;
const hasVT = typeof doc.startViewTransition === "function";
let off = false;
try { off = localStorage.getItem("nova2_motion") === "off"; } catch (e) {}

/* ── Jetons (lus dans motion.css → identite.css ; valeurs de repli identiques) ── */
const T = {
  page: 260, quick: 180, rise: 8, scaleOut: 0.985, press: 120, pill: 300, enter: 240, stagger: 24, maxStagger: 8, budget: 300,
  easePage: "cubic-bezier(.32, .72, 0, 1)", easeOut: "cubic-bezier(.22, 1, .36, 1)",
  easeStd: "cubic-bezier(.2, 0, 0, 1)", easeSpring: "cubic-bezier(.34, 1.36, .64, 1)",
};
let tokensRead = false;
function tokens() {
  if (tokensRead) return T;
  tokensRead = true;
  try {
    const cs = getComputedStyle(html);
    const ms = (name, d) => { const v = cs.getPropertyValue(name).trim(); const x = parseFloat(v); if (!isFinite(x)) return d; return /ms$/.test(v) ? x : /s$/.test(v) ? x * 1000 : x; };
    const str = (name, d) => cs.getPropertyValue(name).trim() || d;
    T.page = ms("--motion-dur-page", T.page); T.quick = ms("--motion-dur-quick", T.quick);
    T.press = ms("--motion-dur-press", T.press); T.pill = ms("--motion-dur-pill", T.pill);
    T.stagger = ms("--motion-stagger", T.stagger);
    T.rise = parseFloat(cs.getPropertyValue("--motion-rise")) || T.rise;
    T.scaleOut = parseFloat(cs.getPropertyValue("--motion-scale-out")) || T.scaleOut;
    T.easePage = str("--motion-ease-page", T.easePage); T.easeOut = str("--motion-ease-out", T.easeOut);
    T.easeStd = str("--motion-ease-std", T.easeStd); T.easeSpring = str("--motion-ease-spring", T.easeSpring);
  } catch (e) {}
  return T;
}

/* ── Registre des animations vivantes (coupées net au repos) ── */
const live = new Set();
function track(a) {
  if (!a) return a;
  live.add(a);
  const done = () => live.delete(a);
  a.addEventListener("finish", done); a.addEventListener("cancel", done);
  return a;
}
function anim(el, frames, opts) {
  try { return track(el.animate(frames, opts)); } catch (e) { return null; }
}
function settleAll() {
  for (const a of [...live]) { try { a.finish(); } catch (e) { try { a.cancel(); } catch (e2) {} } }
  if (vt) { try { vt.skipTransition(); } catch (e) {} }
  finishOut();
}
addEventListener("nova:idle", (e) => { if (e && e.detail && e.detail.idle) settleAll(); });
doc.addEventListener("visibilitychange", () => { if (doc.hidden) settleAll(); });

/* ════════════════════════════════════════════════════════════════════════
   1 · TRANSITION DE PAGE
   ════════════════════════════════════════════════════════════════════════ */
let vt = null;          // ViewTransition en cours
let fb = null;          // animation de repli en cours
const UPDATE_BUDGET = 32;   // ms max de gel du rendu pendant la capture (le montage lent continue en direct)
const OCCLUDERS = ".fwin, .dock-panel:not([hidden]), .ctxmenu, [role='menu'], [role='dialog'], .halo-panel:not([hidden])";

/* View Transitions : OPT-IN (localStorage nova2_motion_vt = "1"). Mesuré le 30/10 sous Chromium 153 :
   pendant toute la transition, CHAQUE pointeur / molette est routé vers <html> (elementFromPoint et
   événements réels), même avec ::view-transition { pointer-events: none } — un 2e clic rapide dans le
   rail était perdu, le défilement aussi. Contraire à « ne jamais bloquer la saisie » : la chorégraphie
   vivante ci-dessous est donc le chemin par défaut ; la voie VT reste prête pour un moteur qui laisse
   passer les événements. */
const vtOptIn = () => { try { return localStorage.getItem("nova2_motion_vt") === "1"; } catch (e) { return false; } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function focusedBody() {
  return doc.querySelector(".ws > .pane.on > .pane-body") || doc.querySelector(".ws > .pane > .pane-body");
}
function railOrder(id) {
  if (!id) return -1;
  const list = doc.querySelectorAll("#rail [data-page]");
  for (let i = 0; i < list.length; i++) if (list[i].dataset.page === id) return i;
  return -1;
}
/* Sens spatial : descendre dans le rail → la page monte d'en bas ; remonter → elle descend. */
function dirOf(from, to) {
  const a = railOrder(from), b = railOrder(to);
  return a >= 0 && b >= 0 && b < a ? -1 : 1;
}
/* Une surface flottante (fenêtre, menu, volet de dialogue) au-dessus de la page :
   la capture la passerait dessous le temps du fondu → on prend le repli WAAPI. */
function occluded(r) {
  const els = doc.querySelectorAll(OCCLUDERS);
  for (let i = 0; i < els.length; i++) {
    const el = els[i];
    if (el.closest(".pane-body")) continue;          // menus internes à la page : capturés avec elle
    const q = el.getBoundingClientRect();
    if (q.width < 2 || q.height < 2) continue;
    if (q.right <= r.left || q.left >= r.right || q.bottom <= r.top || q.top >= r.bottom) continue;
    const cs = getComputedStyle(el);
    if (cs.display !== "none" && cs.visibility !== "hidden" && parseFloat(cs.opacity) > 0.01) return true;
  }
  return !!doc.querySelector("#pal > *") && getComputedStyle(doc.getElementById("pal")).display !== "none";
}
function runUpdate(update) {
  try { return Promise.resolve(update()); } catch (e) { return Promise.reject(e); }
}

/** page(update, { from, to }) — exécute update() (qui affiche la nouvelle page) sous transition.
    Renvoie la promesse d'update() : la navigation garde exactement sa sémantique. */
function page(update, info = {}) {
  if (off || typeof update !== "function") return runUpdate(update);
  const body = focusedBody();
  if (!body || quiet() || !body.getClientRects().length) return runUpdate(update);
  tokens();
  const dir = dirOf(info.from, info.to);
  html.style.setProperty("--mo-dir", String(dir));
  if (hasVT && vtOptIn() && !occluded(body.getBoundingClientRect())) {
    try { return pageVT(update); } catch (e) { /* repli ci-dessous */ }
  }
  return pageLive(update, dir, body);
}

function pageVT(update) {
  finishOut();
  if (vt) { try { vt.skipTransition(); } catch (e) {} }   // navigation rapide : on coupe la précédente
  if (fb) { try { fb.cancel(); } catch (e) {} fb = null; }
  html.classList.add("mo-vt");
  html.classList.toggle("mo-vt-reduce", reduced());
  let resolve, reject;
  const done = new Promise((a, b) => { resolve = a; reject = b; });
  const t = doc.startViewTransition(() => {
    const p = runUpdate(update);
    p.then(resolve, reject);
    /* La capture « après » n'attend pas un montage lent : la page (ou son squelette) est
       déjà en place à la fin de la partie synchrone ; la suite arrive EN DIRECT dans
       ::view-transition-new, qui est une image vivante. Gel du rendu ≤ ~2 images. */
    return Promise.race([p.catch(() => {}), sleep(UPDATE_BUDGET)]);
  });
  vt = t;
  const clean = () => { if (vt === t) { vt = null; html.classList.remove("mo-vt", "mo-vt-reduce"); } };
  t.finished.then(clean, clean);
  t.ready.catch(() => {});
  t.updateCallbackDone.catch(() => {});
  return done;
}

/* Chorégraphie VIVANTE (défaut) — aucune capture, aucun gel, aucune entrée bloquée.
   La page sortante vient d'être cachée par la coquille (display:none, déposée au dépôt) :
   on la ré-accroche 180 ms en calque inerte (pointer-events:none, inert) SOUS la page
   entrante, le temps de s'effacer en reculant, puis on la rend au dépôt exactement dans
   l'état où la coquille l'avait laissée. Les modules non persistants (coffre, messages)
   sont détruits à la sortie : seule l'entrée est alors animée. */
let out = null;
function finishOut() {
  const o = out; out = null;
  if (!o) return;
  try { if (o.anim) o.anim.cancel(); } catch (e) {}
  const r = o.root;
  r.classList.remove("mo-out");
  for (const k of ["display", "visibility", "position", "inset", "z-index", "pointer-events"]) r.style.removeProperty(k);
  r.inert = o.inert;
  // la coquille ne l'a pas ré-affichée entre-temps → état caché d'origine, retour au dépôt
  if (r.getAttribute("aria-hidden") === "true") {
    r.style.display = "none"; r.style.visibility = "hidden";
    if (o.home && o.home.isConnected && r.parentNode !== o.home) o.home.append(r);
  }
}
function pageLive(update, dir, body) {
  finishOut();
  if (fb) { try { fb.finish(); } catch (e) {} fb = null; }
  const outRoot = body.querySelector(":scope > .mod:not([aria-hidden])");
  const outY = outRoot ? outRoot.scrollTop : 0;
  const outDisp = outRoot ? getComputedStyle(outRoot).display : "";
  const p = runUpdate(update);                      // partie synchrone : nouvelle page (ou son squelette) en place
  const red = reduced();
  const nb = focusedBody();
  if (outRoot && nb && outRoot.isConnected && outRoot.getAttribute("aria-hidden") === "true" && outDisp && outDisp !== "none") {
    const o = { root: outRoot, home: outRoot.parentNode, inert: !!outRoot.inert, anim: null };
    out = o;
    outRoot.inert = true;
    outRoot.classList.add("mo-out");
    outRoot.style.setProperty("display", outDisp, "important");
    outRoot.style.setProperty("visibility", "visible", "important");
    Object.assign(outRoot.style, { position: "absolute", inset: "0", zIndex: "0", pointerEvents: "none" });
    nb.prepend(outRoot);                             // sous la page entrante
    if (outY) outRoot.scrollTop = outY;
    o.anim = anim(outRoot, red ? [{ opacity: 1 }, { opacity: 0 }] : [{ opacity: 1, scale: "1" }, { opacity: 0, scale: String(T.scaleOut) }],
      { duration: red ? 140 : T.quick, easing: red ? "linear" : T.easeStd, fill: "forwards" });
    if (o.anim) o.anim.addEventListener("finish", () => { if (out === o) finishOut(); });
    else finishOut();
  }
  const inEl = nb && (nb.querySelector(":scope > .mod:not([aria-hidden]):not(.mo-out)") || nb.querySelector(":scope > [data-boot-skel]"));
  if (inEl) {
    fb = red
      ? anim(inEl, [{ opacity: 0, offset: 0 }], { duration: 160, easing: "linear" })
      : anim(inEl, [{ opacity: 0, translate: "0 " + T.rise * dir + "px", offset: 0 }], { duration: T.page, delay: 40, easing: T.easePage, fill: "backwards" });
  }
  return p;
}

/* ════════════════════════════════════════════════════════════════════════
   2 · INDICATEUR DE SÉLECTION (FLIP) + PRESSION
   ════════════════════════════════════════════════════════════════════════ */
const SEG_HOST = ".seg, .ds-tabs, .ds-chips, .svc-bar, .moi-ame-nav, [role='tablist']";
const ACTIVE_SEL = ":scope > :is(.on, .is-on, [aria-selected='true'], [aria-checked='true'])";

/* Boîte d'un élément dans le repère du CONTENU de l'hôte (insensible au défilement et au
   scale de pression : centre du rect + taille de mise en page). */
function boxIn(host, el) {
  const hr = host.getBoundingClientRect(), r = el.getBoundingClientRect();
  const w = el.offsetWidth || r.width, h = el.offsetHeight || r.height;
  return {
    x: r.left + r.width / 2 - w / 2 - hr.left - host.clientLeft + host.scrollLeft,
    y: r.top + r.height / 2 - h / 2 - hr.top - host.clientTop + host.scrollTop,
    w, h,
  };
}
const BG_PROPS = ["backgroundColor", "backgroundImage", "backgroundSize", "backgroundPosition", "backgroundRepeat", "backgroundOrigin", "backgroundClip", "boxShadow", "borderRadius", "borderTopWidth", "borderRightWidth", "borderBottomWidth", "borderLeftWidth", "borderTopStyle", "borderRightStyle", "borderBottomStyle", "borderLeftStyle", "borderTopColor", "borderRightColor", "borderBottomColor", "borderLeftColor"];
function paintsSomething(cs) {
  return (cs.backgroundImage && cs.backgroundImage !== "none") || (cs.boxShadow && cs.boxShadow !== "none")
    || !/^(transparent|rgba\(0, 0, 0, 0\))$/.test(cs.backgroundColor);
}
/** Fait glisser la « pilule » active de oldBox (repère contenu de host) vers newEl. */
function slide(host, oldEl, oldBox, newEl) {
  if (off || quiet() || reduced() || !oldBox || !newEl || !newEl.isConnected || !host.contains(newEl)) return;
  tokens();
  const nb = boxIn(host, newEl);
  if (!nb.w || !nb.h || !oldBox.w || !oldBox.h) return;
  const dx = oldBox.x - nb.x, dy = oldBox.y - nb.y;
  if (Math.abs(dx) < 1 && Math.abs(dy) < 1) return;
  const cs = getComputedStyle(newEl);
  if (!paintsSomething(cs)) return;                       // rien à faire glisser (style actif = couleur de texte seule)
  if (host._moSlide) { try { host._moSlide.cancel(); } catch (e) {} }
  const g = doc.createElement("div");
  g.className = "mo-pill"; g.setAttribute("aria-hidden", "true");
  for (const p of BG_PROPS) g.style[p] = cs[p];
  Object.assign(g.style, { left: nb.x + "px", top: nb.y + "px", width: nb.w + "px", height: nb.h + "px" });
  // la « flamme » ::before de l'entrée active (rail) voyage avec la pilule
  try {
    const pb = getComputedStyle(newEl, "::before");
    if (pb.content && pb.content !== "none" && pb.display !== "none" && pb.position === "absolute") {
      const f = doc.createElement("i");
      const top = parseFloat(pb.top) || 0, bottom = parseFloat(pb.bottom) || 0;
      const hh = parseFloat(pb.height) || Math.max(0, nb.h - top - bottom);
      Object.assign(f.style, { position: "absolute", left: pb.left, top: top + "px", width: pb.width, height: hh + "px", backgroundColor: pb.backgroundColor, backgroundImage: pb.backgroundImage, borderRadius: pb.borderRadius });
      g.append(f);
    }
  } catch (e) {}
  host.classList.add("mo-host");
  if (getComputedStyle(host).position === "static") host.classList.add("mo-host-rel");
  host.append(g);
  newEl.classList.add("mo-landing");
  if (oldEl && oldEl !== newEl) oldEl.classList.add("mo-notrans");
  const sx = oldBox.w / nb.w, sy = oldBox.h / nb.h;
  const a = anim(g, [{ transform: "translate(" + dx + "px, " + dy + "px) scale(" + sx + ", " + sy + ")" }, { transform: "none" }],
    { duration: T.pill, easing: T.easePage });
  host._moSlide = a;
  let ended = false;
  const end = () => {
    if (ended) return; ended = true;
    newEl.classList.add("mo-notrans");                     // la pilule réelle reprend sa place sans transition parasite
    newEl.classList.remove("mo-landing");
    g.remove();
    if (host._moSlide === a) { host._moSlide = null; host.classList.remove("mo-host", "mo-host-rel"); }
    requestAnimationFrame(() => requestAnimationFrame(() => { newEl.classList.remove("mo-notrans"); if (oldEl) oldEl.classList.remove("mo-notrans"); }));
  };
  if (!a) { end(); return; }
  a.addEventListener("finish", end); a.addEventListener("cancel", end);
}

/* Rail : shell.js pose aria-current="page" sur l'entrée active — un observateur d'ATTRIBUT
   (filtré, sans sous-arbre de texte) suffit, quelle que soit l'origine (clic, ⌘[, ⌃⇥, agent). */
function watchRail() {
  const rail = doc.getElementById("rail");
  if (!rail) return;
  new MutationObserver((recs) => {
    let was = null, now = null;
    for (const r of recs) {
      const t = r.target;
      if (!t.classList || !t.classList.contains("rail-btn")) continue;
      if (r.oldValue === "page" && !t.hasAttribute("aria-current")) was = t;
      else if (t.getAttribute("aria-current") === "page" && r.oldValue !== "page") now = t;
    }
    if (!was || !now || was === now) return;
    const host = was.closest(".rail-mods");
    if (!host || host !== now.closest(".rail-mods")) return;
    // l'ancienne entrée n'a pas bougé (seule sa classe a changé) : sa boîte est l'origine
    const ob = boxIn(host, was);
    const vis = host.clientHeight;
    if (ob.y - host.scrollTop + ob.h < 0 || ob.y - host.scrollTop > vis) return;   // origine hors champ : pas de glissé fantôme
    slide(host, was, ob, now);
  }).observe(rail, { subtree: true, attributes: true, attributeFilter: ["aria-current"], attributeOldValue: true });
}

/* Contrôles segmentés / onglets : mesure de l'actif AVANT les gestionnaires (capture),
   comparaison à l'image suivante (rAF : avant la peinture, aucun éclair). */
function armSeg(target) {
  if (off || quiet() || reduced() || !target || !target.closest) return;
  const host = target.closest(SEG_HOST);
  if (!host || host.closest("#rail")) return;
  let old = null;
  try { old = host.querySelector(ACTIVE_SEL); } catch (e) { return; }
  if (!old) return;
  const ob = boxIn(host, old);
  requestAnimationFrame(() => {
    if (!host.isConnected) return;
    let now = null;
    try { now = host.querySelector(ACTIVE_SEL); } catch (e) {}
    if (now && now !== old) slide(host, old, ob, now);
  });
}
addEventListener("click", (e) => armSeg(e.target), { capture: true, passive: true });
addEventListener("keydown", (e) => {
  if (/^(Arrow(Left|Right|Up|Down)|Home|End)$/.test(e.key)) armSeg(e.target);
}, { capture: true, passive: true });

/* Pression : scale (propriété individuelle → se compose avec les transform existants).
   Les éléments qui ont déjà leur :active en CSS (.btn, .rail-btn, .pb-btn, .pe-card…) sont exclus. */
const PRESS_SEL = ".seg button, .seg-btn, .ds-tab, .ds-chip, .chip, .nova-suite, .sb-navbtn, .sb-preset, .cs-row, .ds-row[data-open], .svc-tile, .ds-icon-btn";
let pressed = null;
addEventListener("pointerdown", (e) => {
  if (off || e.button !== 0 || quiet() || reduced() || !e.target || !e.target.closest) return;
  const el = e.target.closest(PRESS_SEL);
  if (!el || el.disabled || el.getAttribute("aria-disabled") === "true") return;
  release();
  tokens();
  const w = el.offsetWidth || 1;
  const s = Math.max(0.97, 1 - 6 / w);                  // pastille : .97 ; ligne pleine largeur : ~.99
  const a = anim(el, [{ scale: "1" }, { scale: String(s) }], { duration: T.press, easing: T.easeStd, fill: "forwards" });
  if (a) pressed = a;
}, { capture: true, passive: true });
function release() {
  const a = pressed; pressed = null;
  if (!a) return;
  try { a.addEventListener("finish", () => { try { a.cancel(); } catch (e) {} }, { once: true }); a.reverse(); } catch (e) { try { a.cancel(); } catch (e2) {} }
}
for (const ev of ["pointerup", "pointercancel", "dragstart"]) addEventListener(ev, release, { capture: true, passive: true });
addEventListener("blur", release);

/* ════════════════════════════════════════════════════════════════════════
   3 · CONTENU : entrée échelonnée au premier montage, fil de conversation
   ════════════════════════════════════════════════════════════════════════ */
const SKIP_SEL = ".skel, [data-boot-skel], .boot-skel, .boot-note, .mo-pill, script, style, link, template";
const ATOMIC_SEL = ".ds-card, .card, .home-card, .msg, .chatlog, .cs-log, .cs-list, .pane-host, .pane-slot, img, video, canvas, svg, iframe, table, pre";

function collect(n, depth, out, vr) {
  if (out.length >= 32) return;
  const r = n.getBoundingClientRect();
  if (r.width < 1 || r.height < 1) return;
  if (r.bottom < vr.top || r.top > vr.bottom) return;          // hors champ : rien à révéler
  const kids = n.children;
  const big = r.height > vr.height * 0.45;
  if (depth < 3 && big && kids.length >= 1 && kids.length <= 60 && !n.matches(ATOMIC_SEL)) {
    const before = out.length;
    for (let i = 0; i < kids.length; i++) collect(kids[i], depth + 1, out, vr);
    if (out.length > before) return;
  }
  out.push(n);
}
function reveal(items, vr) {
  const k = Math.min(T.maxStagger, items.length);
  if (!k) return;
  // total ≤ budget : la durée se raccourcit quand l'échelonnement s'allonge
  const dur = Math.max(140, Math.min(T.enter, T.budget - T.stagger * (k - 1)));
  for (let i = 0; i < items.length; i++) {
    const d = Math.min(i, k - 1) * T.stagger;               // au-delà de 8 : même départ que le 8e
    anim(items[i], [{ opacity: 0, translate: "0 10px", offset: 0 }], { duration: dur, delay: d, easing: T.easeOut, fill: "backwards" });
  }
  void vr;
}
/** mounting(root) — appelé juste avant mod.mount() : observe la première arrivée du contenu. */
function mounting(root) {
  if (off || !root || typeof MutationObserver !== "function") return;
  const t0 = performance.now();
  let batches = 0;
  const mo = new MutationObserver((recs) => {
    if (performance.now() - t0 > 2500 || batches >= 2 || !root.isConnected || quiet() || reduced()) { mo.disconnect(); return; }
    const added = [];
    for (const r of recs) {
      for (let i = 0; i < r.addedNodes.length && added.length < 80; i++) {
        const n = r.addedNodes[i];
        if (n.nodeType !== 1 || !n.isConnected) continue;
        if (n.matches(SKIP_SEL) || n.querySelector(".skel")) continue;   // squelette : la vraie page arrivera ensuite
        added.push(n);
      }
    }
    if (!added.length) return;
    const top = added.filter((n) => !added.some((m) => m !== n && m.contains(n)));
    const rr = root.getBoundingClientRect();
    if (!rr.height) return;
    tokens();
    const vr = { top: rr.top, bottom: rr.bottom, height: rr.height };
    const items = [];
    for (const n of top) collect(n, 0, items, vr);
    if (!items.length) return;
    batches++;
    reveal(items, vr);
  });
  mo.observe(root, { childList: true, subtree: true });
  setTimeout(() => mo.disconnect(), 2600);
}

/* Fil de conversation : un observateur par portée (racine du module Conversations, ou le
   journal du dock). Un rendu d'historique (> 2 messages d'un coup) n'anime rien. */
const LOG_SEL = ".chatlog, .cs-log, .dock-log, .panel-log";
const POP_SEL = ".nova-suites, .nova-livrable";
const chatScopes = new WeakSet();
function slideMsgs(nodes) {
  tokens();
  for (const n of nodes) {
    if (n.classList.contains("fd-in") || n.classList.contains("fc")) continue;   // cartes Direct : leur propre descente
    const me = n.classList.contains("me");
    anim(n, [{ opacity: 0, translate: (me ? "6px" : "0") + " 12px", offset: 0 }], { duration: T.page, easing: T.easePage, fill: "backwards" });
  }
}
function popIn(n) {
  tokens();
  const targets = n.matches(POP_SEL) ? [n] : [...n.querySelectorAll(POP_SEL)];
  for (const t of targets) {
    if (t.classList.contains("nova-suites")) {
      const chips = t.querySelectorAll(".nova-suite");
      if (!chips.length) { anim(t, [{ opacity: 0, scale: ".96", offset: 0 }], { duration: 260, easing: T.easeSpring }); continue; }
      chips.forEach((c, i) => anim(c, [{ opacity: 0, scale: ".9", offset: 0 }], { duration: 280, delay: 60 + Math.min(i, 5) * 30, easing: T.easeSpring, fill: "backwards" }));
    } else {
      anim(t, [{ opacity: 0, scale: ".96", translate: "0 6px", offset: 0 }], { duration: 300, easing: T.easeSpring, fill: "backwards" });
    }
  }
}
function watchChat(scope) {
  if (off || !scope || chatScopes.has(scope)) return;
  chatScopes.add(scope);
  let bulkUntil = 0;
  const popped = new WeakSet();
  new MutationObserver((recs) => {
    if (quiet() || reduced()) return;
    const now = performance.now();
    const msgs = [], pops = [];
    let nMsg = 0;
    for (const r of recs) {
      const t = r.target;
      if (t.nodeType !== 1) continue;
      const isLog = t.matches(LOG_SEL);
      if (!isLog && !t.closest(LOG_SEL)) continue;          // liste, panneaux… : hors du fil
      for (let i = 0; i < r.addedNodes.length; i++) {
        const n = r.addedNodes[i];
        if (n.nodeType !== 1) continue;                     // jetons de streaming (texte) : ignorés d'emblée
        if (isLog) {
          if (n.classList.contains("msg")) { nMsg++; msgs.push(n); }
          else if (n.classList.contains("msg-head")) msgs.push(n);
        } else if (n.matches(POP_SEL) || (n.firstElementChild && n.querySelector(POP_SEL))) {
          const b = t.closest(".msg");
          if (b && !popped.has(b)) { popped.add(b); pops.push(n); }
        }
      }
    }
    if (nMsg > 2) { bulkUntil = now + 500; return; }      // historique rechargé : immobile
    if (now < bulkUntil) return;
    if (msgs.length) slideMsgs(msgs);
    for (const n of pops) popIn(n);
  }).observe(scope, { childList: true, subtree: true });
}

/* ════════════════════════════════════════════════════════════════════════
   4 · BORD DE DÉFILEMENT (IntersectionObserver, pas d'écouteur scroll)
   La « ligne » d'observation est le bord haut du défileur (rootMargin -100 % en bas) ;
   le premier enfant du module passe AU-DESSUS → du contenu glisse sous la barre.
   ════════════════════════════════════════════════════════════════════════ */
const edges = new WeakMap();
function frameOf(root) { return root.closest(".pane, .fwin"); }
function setEdge(root, on) {
  const f = frameOf(root);
  if (!f || root.classList.contains("mo-out") || !root.getClientRects().length) return;          // module caché : il ne parle pas pour le panneau
  if (f.hasAttribute("data-mo-edge") !== on) f.toggleAttribute("data-mo-edge", on);
}
function firstBlock(root) {
  for (let c = root.firstElementChild; c; c = c.nextElementSibling) {
    if (c.classList.contains("mo-pill")) continue;
    const cs = getComputedStyle(c);
    if (cs.display === "none" || cs.position === "absolute" || cs.position === "fixed" || cs.position === "sticky") continue;
    return c;
  }
  return null;
}
function edge(root) {
  if (off || !root || typeof IntersectionObserver !== "function") return;
  let st = edges.get(root);
  if (!st) {
    st = { target: null };
    st.io = new IntersectionObserver((ents) => {
      for (const en of ents) {
        if (en.target !== st.target || !en.rootBounds || !root.isConnected) continue;
        if (!en.target.isConnected || en.target.parentElement !== root) { repick(); continue; }
        setEdge(root, en.boundingClientRect.top < en.rootBounds.top - 0.5);
      }
    }, { root, rootMargin: "0px 0px -100% 0px", threshold: 0 });
    const repick = () => {
      const t = firstBlock(root);
      if (t === st.target) return;
      if (st.target) st.io.unobserve(st.target);
      st.target = t;
      if (t) st.io.observe(t);
    };
    st.repick = repick;
    // les modules remplacent leurs enfants directs au rendu : on suit (enfants directs seulement)
    new MutationObserver(repick).observe(root, { childList: true });
    edges.set(root, st);
  }
  st.repick();
  // au retour sur la page, la position de défilement est restaurée à l'image suivante
  requestAnimationFrame(() => requestAnimationFrame(() => setEdge(root, root.scrollTop > 2)));
}

/* ════════════════════════════════════════════════════════════════════════
   API — window.NovaMotion
   ════════════════════════════════════════════════════════════════════════ */
function shown(root) {
  if (off || !root) return;
  edge(root);
  try {
    if (root.querySelector(LOG_SEL)) watchChat(root);
    doc.querySelectorAll(".dock-log, .panel-log").forEach((l) => { if (!l.closest(".mod")) watchChat(l); });
  } catch (e) {}
}
/** Défilement programmatique : le seul endroit où « smooth » est permis. */
function scrollTo(el, top, opts = {}) {
  if (!el) return;
  try { el.scrollTo({ top, left: opts.left, behavior: reduced() || quiet() ? "auto" : "smooth" }); } catch (e) { el.scrollTop = top; }
}

if (!off) {
  html.classList.add("mo-on");
  watchRail();
}
const api = { version: "30.10", page, mounting, shown, scrollTo, settle: settleAll, get enabled() { return !off; } };
try { window.NovaMotion = api; } catch (e) {}
export default api;
export { page, mounting, shown, scrollTo };
