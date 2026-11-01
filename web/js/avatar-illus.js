/* avatar-illus.js — V5-K : le compagnon « illustré » (look Muse) bâti sur les illustrations 2D de [tiers].
   Images : web/avatars/illus/<espèce>/*.webp (768 px) et <espèce>/384/*.webp (≤ 200 px affichés) + manifest.json
   (outil : web/avatars/illus/_build/build_illus.py ; V5-M : super-résolution x4 Real-ESRGAN).
   MÊME CONTRAT que le moteur de mascot.js (createAvatar) et d'avatar-gltf.js :
     setState(st)        idle | listening | thinking | tool | speaking | approval | done | celebrate | error | reading | sleep
                         (+ alias directs : typing, error_resolve, wink)
     setMood(m)          neutre | joie | attention | grave | legere   (teinte, jamais une pose)
     setLevel(v)         niveau audio mesuré 0..1 (pompe d'avatar.js)
     setViseme(v)        { open, spread, round, press } 0..1
     setVisemeSource(fn) fn() → visème ou null, lue dans la boucle du moteur (readViseme d'avatar.js)
     lookAt(x, y)        [-1, 1] — le curseur est aussi suivi seul (comme mascot.js)
     setFocus(x, y)      cible prioritaire ; null relâche
     react(kind)         validate | wave | nod | arrival | whip | surprise
     setTheme()          sans effet (le cadre lit les variables CSS en direct)
     state, species      accesseurs
     snapshot()          URL de l'image affichée
     destroy()
   DIFFÉRENCE UNIQUE : la fabrique est ASYNCHRONE (manifeste + préchargement), comme loadAvatar() d'avatar-gltf.js :
     const eng = await createIllusAvatar(layer, { species: "panda" | "renard" });   // null → l'appelant replie sur mascot.js
   Rendu : <img> empilées, fondu enchaîné 150 ms (états) / 75 ms (bouche) ; respiration 2,4 % sur 5 s ;
   micro-mouvement vers la cible du regard (quelques px + légère inclinaison) ; pas de faux clignement
   (manifest.blink = null tant qu'aucune image yeux fermés au même cadrage n'existe ; sinon clignement 130 ms toutes les 3–7 s au repos) ; prefers-reduced-motion respecté. */

const BASE = new URL("../avatars/illus/", import.meta.url);
const STATES = ["idle", "listening", "thinking", "tool", "speaking", "approval", "done", "celebrate", "error", "reading", "sleep"];
const ALIAS_STATE = { typing: "tool", error_resolve: "error", wink: "wink" };
const MOODS = ["neutre", "joie", "attention", "grave", "legere"];
const FADE_STATE = 150, FADE_MOUTH = 75, MOUTH_HOLD = 90, SILENCE_MS = 260, SLEEP_AFTER_S = 240;

let manifestP = null;
function readManifest() {
  if (!manifestP) {
    manifestP = fetch(new URL("manifest.json", BASE).href, { cache: "no-cache" })
      .then((r) => (r.ok ? r.json() : null))
      .catch(() => null);
  }
  return manifestP;
}
function speciesKey(m, species) {
  const s = String(species || "panda");
  if (m && m.species && m.species[s]) return s;
  const a = m && m.alias && m.alias[s];
  return a && m.species[a] ? a : (s === "renard" || s === "red" || s === 1 ? "pandaroux" : "panda");
}
/* Disponibilité (sans rien monter) : l'appelant peut choisir son moteur avant d'importer quoi que ce soit. */
export async function illusAvailable(species) {
  const m = await readManifest();
  const k = speciesKey(m, species);
  const e = m && m.species && m.species[k];
  return !!(e && e.states && e.states.idle);
}

const CSS = `
.ia-root{position:absolute;inset:0;display:grid;place-items:center;pointer-events:none;container-type:size}
.ia-frame{position:relative;width:min(100cqw,100cqh);height:min(100cqw,100cqh);border-radius:50%;
  overflow:hidden;isolation:isolate;background:var(--ia-bg,#efe6d6);
  box-shadow:0 0 0 1.5px color-mix(in srgb,var(--accent,#c0392b) 42%,transparent),
    0 0 0 5px color-mix(in srgb,var(--accent,#c0392b) 10%,transparent),
    0 10px 28px -12px rgb(0 0 0/.45);
  transition:box-shadow .4s ease,filter .6s ease}
.ia-root[data-state="listening"] .ia-frame,.ia-root[data-state="speaking"] .ia-frame{
  box-shadow:0 0 0 2px color-mix(in srgb,var(--accent,#c0392b) 70%,transparent),
    0 0 0 6px color-mix(in srgb,var(--accent,#c0392b) 18%,transparent),0 10px 28px -12px rgb(0 0 0/.45)}
.ia-root[data-state="sleep"] .ia-frame{filter:saturate(.82) brightness(.9)}
.ia-root[data-mood="joie"] .ia-frame{filter:saturate(1.08) brightness(1.03)}
.ia-root[data-mood="attention"] .ia-frame{filter:contrast(1.04) saturate(1.04)}
.ia-root[data-mood="grave"] .ia-frame{filter:saturate(.86) brightness(.96)}
.ia-root[data-mood="legere"] .ia-frame{filter:saturate(1.05) brightness(1.02)}
.ia-full .ia-frame{width:min(100cqw,75cqh);height:min(133.34cqw,100cqh);border-radius:0;overflow:visible;background:transparent;box-shadow:none!important}
.ia-full .ia-look{inset:0}
.ia-full .ia-breath{transform-origin:50% 96%}
.ia-full .ia-img{object-fit:contain}
.ia-look{position:absolute;inset:-3%;transition:transform .45s cubic-bezier(.22,1,.36,1);will-change:transform}
.ia-breath{position:absolute;inset:0;transform-origin:50% 78%;animation:ia-breathe 5s ease-in-out infinite alternate}
.ia-root[data-state="sleep"] .ia-breath{animation-duration:7s}
.ia-hop{position:absolute;inset:0}
.ia-hop.go{animation:ia-hop .62s cubic-bezier(.34,1.28,.64,1)}
.ia-hop.wig{animation:ia-wig .5s ease-in-out}
.ia-img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;opacity:0;user-select:none;-webkit-user-drag:none;
  transition-property:opacity;transition-timing-function:ease-in-out;backface-visibility:hidden}
.ia-img.on{opacity:1}
@keyframes ia-breathe{from{transform:scale(1)}to{transform:scale(1.024) translateY(-.4%)}}
@keyframes ia-hop{0%{transform:translateY(0) scale(1)}25%{transform:translateY(1.5%) scale(1.02,.98)}55%{transform:translateY(-4%) scale(.99,1.02)}100%{transform:none}}
@keyframes ia-wig{0%,100%{transform:none}30%{transform:rotate(-2.2deg)}70%{transform:rotate(2deg)}}
@media (prefers-reduced-motion: reduce){
  .ia-breath,.ia-hop.go,.ia-hop.wig{animation:none}
  .ia-look{transition:none}
}
:root[data-reduce-motion="1"] .ia-breath,:root[data-reduce-motion="1"] .ia-hop.go,:root[data-reduce-motion="1"] .ia-hop.wig{animation:none}
`;
function ensureCss() {
  if (document.getElementById("nova-illus-css")) return;
  const st = document.createElement("style");
  st.id = "nova-illus-css";
  st.textContent = CSS;
  document.head.appendChild(st);
}
const reducedMotion = () => {
  try { return matchMedia("(prefers-reduced-motion: reduce)").matches || document.documentElement.dataset.reduceMotion === "1"; } catch (e) { return false; }
};
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const BG = { panda: "#f3ead9", pandaroux: "#ece6dc" };

/* ── Fabrique ─────────────────────────────────────────────────────────────── */
export async function createIllusAvatar(host, { species = "panda", set = "" } = {}) {
  if (!host) return null;
  const m = await readManifest();
  let key = speciesKey(m, species);
  /* 25/10 : jeu « corps entier » (compagnon) — <espèce>_full s'il existe, sinon le portrait habituel. */
  if (set === "full" && m && m.species && m.species[key + "_full"]) key = key + "_full";
  const E = m && m.species && m.species[key];
  if (!E || !E.states || !E.states.idle) return null;
  /* V5-M : deux jeux d'images (768 et 384 px). Le petit sert quand l'hôte est affiché à ≤ smallMaxCss px
     (CSS) au montage ; hôte pas encore mesuré (0 px) → grand jeu. */
  let side = 0;
  try { const r = host.getBoundingClientRect(); side = Math.min(r.width, r.height); } catch (e) {}
  const smallMax = (m.sizes && m.sizes.smallMaxCss) || 0;
  const small = !!(E.dirSmall && side > 0 && side <= smallMax);
  const dir = new URL(small ? E.dirSmall : (E.dir || key + "/"), BASE);
  const url = (f) => new URL(f, dir).href;

  /* préchargement : l'image de repos est décodée AVANT de rendre la main (jamais de cadre vide),
     les autres suivent en arrière-plan ; une image qui manque est simplement retirée du jeu. */
  const files = Array.from(new Set([...(E.files || []), ...Object.values(E.states), ...Object.values(E.visemes || {})].filter(Boolean)));
  const imgs = new Map();
  const load = (f) => new Promise((res) => {
    const im = new Image();
    im.className = "ia-img"; im.alt = ""; im.draggable = false; im.decoding = "async";
    im.onload = () => { (im.decode ? im.decode().catch(() => {}) : Promise.resolve()).then(() => { imgs.set(f, im); res(true); }); };
    im.onerror = () => res(false);
    im.src = url(f);
  });
  if (!(await load(E.states.idle))) return null;
  ensureCss();

  const root = document.createElement("div");
  root.className = "ia-root" + (E.full ? " ia-full" : "");
  root.setAttribute("aria-hidden", "true");
  root.style.setProperty("--ia-bg", BG[key] || BG.panda);
  const frame = document.createElement("div"); frame.className = "ia-frame";
  const look = document.createElement("div"); look.className = "ia-look";
  const breath = document.createElement("div"); breath.className = "ia-breath";
  const hop = document.createElement("div"); hop.className = "ia-hop";
  breath.appendChild(hop); look.appendChild(breath); frame.appendChild(look); root.appendChild(frame);
  host.appendChild(root);

  const attach = (f) => { const im = imgs.get(f); if (im && !im.parentNode) hop.appendChild(im); return im; };
  const rest = files.filter((f) => f !== E.states.idle);
  Promise.all(rest.map(load)).then(() => { if (!dead) rest.forEach(attach); });

  /* ── état interne ── */
  let dead = false, state = "idle", mood = "neutre", level = 0, levelT = 0;
  let visSrc = null, vis = null, visT = 0;
  let shown = null, shownFile = "", z = 1, showTok = 0;
  let mouthFile = "", mouthT = 0, speakT = 0;
  let pulse = null;                 // image ponctuelle (react) : { f, until }
  let ptr = { x: 0, y: 0 }, focus = null;
  let lastAct = performance.now() / 1000;
  let raf = 0, visible = true, blinkAt = 0;

  function show(f, fade) {
    if (!f || f === shownFile) return;
    const im = attach(f) || (imgs.get(f) ? imgs.get(f) : null);
    if (!im) return;                 // pas encore chargée : on garde l'image actuelle (aucun trou)
    const prev = shown;
    const d = reducedMotion() ? Math.min(fade, 90) : fade;
    // fondu ENCHAÎNÉ sans creux : la nouvelle monte au-dessus de l'ancienne restée opaque,
    // l'ancienne n'est masquée qu'une fois la nouvelle pleinement visible.
    im.style.transitionDuration = d + "ms";
    im.style.zIndex = String(++z);
    im.classList.add("on");
    const tok = ++showTok;
    if (prev && prev !== im) {
      let done = false;
      const settle = () => {
        if (done) return; done = true;
        im.removeEventListener("transitionend", onEnd);
        // seule l'image ENCORE au premier plan, désormais pleinement opaque, fait le ménage : toutes
        // les autres couches visibles sont retirées d'un coup (jamais de creux, même si les fondus
        // s'enchaînent plus vite qu'ils ne finissent — parole rapide).
        if (tok !== showTok) return;   // un fondu plus récent a pris la main : c'est lui qui nettoiera
        hop.querySelectorAll(".ia-img.on").forEach((o) => { if (o !== im) { o.style.transitionDuration = "0ms"; o.classList.remove("on"); } });
      };
      const onEnd = (e) => { if (e.propertyName === "opacity") settle(); };
      if (d > 0 && getComputedStyle(im).opacity !== "1") { im.addEventListener("transitionend", onEnd); setTimeout(settle, d + 600); }
      else requestAnimationFrame(() => requestAnimationFrame(settle));
    }
    shown = im; shownFile = f;
  }

  function stateFile() {
    const s = state;
    if (s === "wink") return E.wink || E.states.idle;
    return E.states[s] || E.states.idle;
  }

  /* visème mesuré → image de bouche */
  function mouthFromViseme(v) {
    const V = E.visemes || {};
    if (v.press > 0.5) return V.vis_MBP;
    if (v.open < 0.12 && v.round < 0.3 && v.spread < 0.3) return V.vis_MBP;
    if (v.round > 0.42) return v.open > 0.5 ? V.vis_O : V.vis_U;
    if (v.spread > 0.42) return v.open > 0.42 ? V.vis_E : V.vis_I;
    if (v.open > 0.58) return V.vis_A;
    if (v.open > 0.3) return V.vis_E;
    return V.vis_FV || V.vis_MBP;
  }
  /* repli niveau seul (pas de source spectrale) : l'ouverture suit le niveau MESURÉ, la forme
     alterne entre deux voyelles proches pour ne pas figer la bouche sur une syllabe longue. */
  let alt = 0;
  function mouthFromLevel(l) {
    const V = E.visemes || {};
    if (l > 0.5) return V.vis_A;
    if (l > 0.28) return (alt ^= 1) ? V.vis_E : V.vis_O;
    if (l > 0.12) return (alt ^= 1) ? V.vis_I : V.vis_U;
    return V.vis_MBP;
  }

  function applyLook() {
    const t = focus || ptr;
    const k = reducedMotion() ? 0.25 : 1;
    const tx = clamp(t.x, -1, 1) * 1.1 * k, ty = clamp(-t.y, -1, 1) * 0.8 * k;   // en % du cadre (≈ 4–5 px à 420 px)
    look.style.transform = `translate(${tx.toFixed(2)}%, ${ty.toFixed(2)}%) rotate(${(clamp(t.x, -1, 1) * 1.6 * k).toFixed(2)}deg)`;
  }

  function frameTick() {
    raf = 0;
    if (dead) return;
    const now = performance.now();
    const nowS = now / 1000;
    // sommeil : Le Vide (data-vide) ou 240 s sans activité — comme mascot.js
    const vide = document.documentElement.hasAttribute("data-vide");
    if (state !== "sleep" && (vide || nowS - lastAct > SLEEP_AFTER_S) && state !== "speaking") setStateInternal("sleep", true);

    // parole : visème lu DANS la boucle (aucune autre boucle), sinon le niveau audio mesuré
    let v = null;
    if (visSrc) { try { v = visSrc(); } catch (e) { v = null; } }
    if (v) { vis = v; visT = now; }
    const fresh = vis && now - visT < 200;
    const talking = (fresh && (vis.open > 0.08 || vis.press > 0.5)) || (now - levelT < 300 && level > 0.08);
    if (talking) speakT = now;
    const speakingNow = state !== "sleep" && now - speakT < SILENCE_MS;

    let want;
    if (pulse && now < pulse.until) want = pulse.f;
    else {
      pulse = null;
      if (speakingNow) {
        if (now - mouthT >= MOUTH_HOLD) {
          const f = fresh ? mouthFromViseme(vis) : mouthFromLevel(level);
          if (f && f !== mouthFile) { mouthFile = f; mouthT = now; }
        }
        want = mouthFile || E.states.idle;
      } else {
        mouthFile = "";
        want = stateFile();
        // V5-M : clignement réel si le manifeste fournit une image yeux fermés au même cadrage que le repos
        if (E.blink && want === E.states.idle && !reducedMotion()) {
          if (!blinkAt) blinkAt = now + 2500 + Math.random() * 3500;
          if (now >= blinkAt) { want = E.blink; if (now >= blinkAt + 130) blinkAt = now + 2800 + Math.random() * 4200; }
        }
      }
    }
    if (want !== shownFile) show(want, speakingNow && !pulse ? FADE_MOUTH : (want === E.blink || shownFile === E.blink) ? 40 : FADE_STATE);
    schedule(speakingNow || !!pulse || (visSrc && fresh));
  }
  /* 25/10 (recette V5-N) : au repos, la boucle tourne à ~8 images/s (setTimeout 120 ms) au lieu de 60 — la
     respiration est en CSS, le regard et le clignement se contentent de 8 Hz ; pleine cadence dès que Nova parle. */
  let idleT = 0;
  function schedule(fast = true) {
    if (dead || raf || idleT || !visible || document.hidden) return;
    if (fast) { raf = requestAnimationFrame(frameTick); return; }
    /* 29/10 (fluidité) : repos partagé (html[data-idle], 10 s sans geste — shell.js) → 400 ms ; tout changement
       d'état, niveau ou visème appelle schedule() et repasse aussitôt en pleine cadence. */
    const slow = document.documentElement.dataset.idle === "1" ? 400 : 120;
    idleT = setTimeout(() => { idleT = 0; if (!dead && !raf) raf = requestAnimationFrame(frameTick); }, slow);
  }

  function setStateInternal(st, auto) {
    if (st === state) return;
    const prev = state;
    state = st;
    root.dataset.state = st;
    if (!auto) lastAct = performance.now() / 1000;
    if ((st === "done" || st === "celebrate") && !reducedMotion()) bump("go");
    if (st === "approval" && !reducedMotion()) bump("go");
    if (prev === "sleep" && st !== "sleep" && !reducedMotion()) bump("go");
    schedule();
  }
  function bump(cls) {
    hop.classList.remove("go", "wig");
    void hop.offsetWidth;            // relance l'animation CSS
    hop.classList.add(cls);
  }
  hop.addEventListener("animationend", () => hop.classList.remove("go", "wig"));

  /* curseur (comme mascot.js) */
  const onMove = (e) => {
    if (dead) return;
    const b = host.getBoundingClientRect();
    if (!b.width) return;
    ptr.x = clamp((e.clientX - (b.left + b.width / 2)) / Math.max(320, innerWidth * 0.5), -1, 1);
    ptr.y = clamp(-(e.clientY - (b.top + b.height * 0.35)) / Math.max(240, innerHeight * 0.5), -1, 1);
    if (!focus) applyLook();
    if (document.documentElement.hasAttribute("data-vide")) return;
    lastAct = performance.now() / 1000;
    if (state === "sleep") api.setState("idle");
  };
  addEventListener("pointermove", onMove, { passive: true });
  const onVis = () => schedule();
  document.addEventListener("visibilitychange", onVis);
  let io = null;
  try {
    io = new IntersectionObserver((en) => { visible = en.some((x) => x.isIntersecting); schedule(); });
    io.observe(root);
  } catch (e) {}

  const api = {
    setState(st) {
      if (dead) return;
      const s = ALIAS_STATE[st] || st;
      if (!STATES.includes(s) && s !== "wink") return;
      if (!document.documentElement.hasAttribute("data-vide")) lastAct = performance.now() / 1000;
      setStateInternal(s, false);
    },
    setMood(mo) { if (!dead && MOODS.includes(mo)) { mood = mo; root.dataset.mood = mo; } },
    setLevel(v) { level = clamp(+v || 0, 0, 1); levelT = performance.now(); schedule(); },
    setViseme(v) {
      if (dead || !v) return;
      vis = { open: clamp(+v.open || 0, 0, 1), spread: clamp(+v.spread || 0, 0, 1), round: clamp(+v.round || 0, 0, 1), press: clamp(+v.press || 0, 0, 1) };
      visT = performance.now(); schedule();
    },
    setVisemeSource(fn) { visSrc = typeof fn === "function" ? fn : null; schedule(); },
    lookAt(x, y) { ptr.x = clamp(+x || 0, -1, 1); ptr.y = clamp(+y || 0, -1, 1); if (!focus) applyLook(); },
    setFocus(x, y) {
      if (x == null) { focus = null; applyLook(); return; }
      focus = { x: clamp(+x || 0, -1, 1), y: clamp(+y || 0, -1, 1) }; applyLook();
    },
    react(kind) {
      if (dead) return;
      const now = performance.now();
      if (!document.documentElement.hasAttribute("data-vide")) {
        lastAct = now / 1000;
        if (state === "sleep" && kind !== "nod") api.setState("idle");
      }
      const rm = reducedMotion();
      if (kind === "validate" || kind === "nod") { pulse = { f: E.wink || E.smile, until: now + (kind === "nod" ? 850 : 1250) }; if (!rm && kind === "validate") bump("go"); }
      else if (kind === "wave" || kind === "arrival") { pulse = { f: E.states.wave || E.smile || E.states.celebrate, until: now + (E.states.wave ? 1600 : 1250) }; if (!rm) bump("go"); }   /* 25/10 : vrai salut de la patte (jeu corps entier) */
      else if (kind === "whip") { if (!rm) bump("wig"); }
      else if (kind === "surprise") { pulse = { f: (E.visemes && E.visemes.vis_O) || E.states.idle, until: now + 900 }; }
      schedule();
    },
    setTheme() {},
    get state() { return state; },
    get species() { return key.indexOf("pandaroux") === 0 ? "renard" : "panda"; },
    get engine() { return "illus"; },
    snapshot() { return shownFile ? url(shownFile) : ""; },
    destroy() {
      if (dead) return;
      dead = true;
      if (raf) cancelAnimationFrame(raf);
      if (idleT) { clearTimeout(idleT); idleT = 0; }
      removeEventListener("pointermove", onMove);
      document.removeEventListener("visibilitychange", onVis);
      try { io && io.disconnect(); } catch (e) {}
      root.remove();
    },
  };

  root.dataset.state = state;
  root.dataset.mood = mood;
  show(E.states.idle, 0);
  applyLook();
  schedule();
  return api;
}
