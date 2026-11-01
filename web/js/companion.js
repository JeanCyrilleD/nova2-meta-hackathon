/* companion.js — PANDA VIVANT v2 (24/10/2026) : UNE présence, portable, jamais réinitialisée.

   Avant : trois instances 3D indépendantes (rail, héros d'Accueil, compagnon flottant) —
   trois pandas qui pouvaient diverger, et un compagnon flottant qui couvrait le contenu.
   Désormais : UN SEUL moteur (monté une fois, enfant de body, hors des modules) et des
   ANCRES. Une ancre est un emplacement réservé dans la mise en page (le haut du rail, le
   héros d'Accueil…) : elle ne contient rien, elle réserve la place. Le compagnon choisit
   l'ancre visible de plus haute priorité et s'y pose — même identité, même état, même
   humeur ; il glisse d'une ancre à l'autre quand tu changes d'écran, suit la fenêtre
   quand tu réduis ou agrandis (ResizeObserver), suit le défilement, et ne recouvre jamais
   ton travail puisque sa place est réservée par la mise en page elle-même.

   Affichage = f(activité partagée (avatar.js) · attente d'un GO · célébration · humeur) :
     · nova:presence-state  → travaille / écoute / réfléchit / parle / célèbre / déterminé
     · nova:approval-wait, nova:dot-run (waiting) → pose « attend ton GO »
     · nova:feedback (validation → joie, correction → attention)
     · nova:feed-arrival    → réaction d'arrivée synchronisée à la descente du message
   Aucune pose n'est déclenchée par un minuteur décoratif. */
import { mountAvatar, setSharedMood, reactAll } from "./avatar.js";

const PRIO = { vide: 5, hero: 3, conv: 2, rail: 1 };
const anchors = new Set();
let schedule = () => {};

/** Réserve un emplacement pour le compagnon. Retourne l'ancre, augmentée des méthodes de
    pilotage historiques (setState, setLevel, noteTool, noteError, react) qui délèguent à
    l'UNIQUE présence — createChat et le shell la pilotent comme avant. */
export function presenceAnchor(ctx, { slot = "rail", px = 104 } = {}) {
  const a = document.createElement("div");
  a.className = "pv-anchor pv-anchor--" + slot;
  a.dataset.pvSlot = slot;
  a.style.width = px + "px"; a.style.height = px + "px";
  a.setAttribute("aria-hidden", "true");
  const w = () => (window.__novaCompanion && window.__novaCompanion._wrap) || null;
  a.setState = (s) => { const x = w(); if (x && x.setState) x.setState(s); };
  a.setLevel = (v) => { const x = w(); if (x && x.setLevel) x.setLevel(v); };
  a.noteTool = () => { const x = w(); if (x && x.noteTool) x.noteTool(); };
  a.noteError = () => { const x = w(); if (x && x.noteError) x.noteError(); };
  a.react = (k) => reactAll(k);
  a.destroyAvatar = () => { anchors.delete(a); schedule(); };
  anchors.add(a);
  try { new ResizeObserver(() => schedule()).observe(a); } catch (e) {}
  queueMicrotask(() => schedule());
  return a;
}

export function bootCompanion(ctx) {
  if (window.__novaCompanion) return window.__novaCompanion;
  const { bus, h } = ctx;
  const host = h("div", { class: "pv-companion", title: "Nova — ton compagnon" });
  document.body.append(host);
  const wrap = mountAvatar(ctx, { px: 132, orbSize: "lg" });
  wrap.style.width = "100%"; wrap.style.height = "100%";
  host.append(wrap);
  host._wrap = wrap;
  window.__novaCompanion = host;
  wrap.addEventListener("nova:avatar-ready", () => { try { host.dispatchEvent(new CustomEvent("nova:avatar-ready")); } catch (e) {} });

  /* ── Placement sur l'ancre ─────────────────────────────────────────── */
  let cur = null, raf = 0, moveT = 0;
  const visible = (a) => {
    if (!a.isConnected) return false;
    const r = a.getBoundingClientRect();
    if (r.width < 24 || r.height < 24) return false;
    if (a.closest("[aria-hidden='true'].mod, [hidden]")) return false;
    if (a.offsetParent === null) return false;
    // au moins 60 % de l'ancre dans la fenêtre
    const vh = window.innerHeight, vw = window.innerWidth;
    const ih = Math.max(0, Math.min(r.bottom, vh) - Math.max(r.top, 0)), iw = Math.max(0, Math.min(r.right, vw) - Math.max(r.left, 0));
    return (ih * iw) / (r.width * r.height) >= 0.6;
  };
  function place() {
    raf = 0;
    let best = null;
    for (const a of anchors) { if (!visible(a)) continue; if (!best || (PRIO[a.dataset.pvSlot] || 0) > (PRIO[best.dataset.pvSlot] || 0)) best = a; }
    if (!best) { host.classList.add("pv-parked"); return; }
    host.classList.remove("pv-parked");
    if (best !== cur) {
      if (cur) { host.classList.add("pv-moving"); clearTimeout(moveT); moveT = setTimeout(() => host.classList.remove("pv-moving"), 520); }
      for (const a of anchors) a.classList.toggle("pv-anchor--on", a === best);
      cur = best; host.dataset.slot = best.dataset.pvSlot || "";
    }
    const r = best.getBoundingClientRect();
    host.style.left = Math.round(r.left) + "px"; host.style.top = Math.round(r.top) + "px";
    host.style.width = Math.round(r.width) + "px"; host.style.height = Math.round(r.height) + "px";
  }
  schedule = () => { if (!raf) raf = requestAnimationFrame(place); };
  window.addEventListener("resize", schedule, { passive: true });
  document.addEventListener("scroll", schedule, { passive: true, capture: true });
  bus.on("nova:module", () => { schedule(); setTimeout(schedule, 80); setTimeout(schedule, 400); });
  try { new MutationObserver(schedule).observe(document.body, { attributes: true, attributeFilter: ["class"] }); } catch (e) {}
  try { const v = document.getElementById("view"); if (v) new MutationObserver(schedule).observe(v, { childList: true, subtree: false, attributes: true, attributeFilter: ["aria-hidden"], attributeOldValue: false }); } catch (e) {}

  /* ── État composé : attente d'un GO, lecture, célébration, humeurs ─── */
  let activity = "repos", waiting = 0, localPose = "", celebT = 0, videOn = false;
  let apprEl = null, readEl = null;
  /* Pose LOCALE (n'écrit jamais l'état partagé) : « approval » si un GO est attendu (Dot en
     attente, carte d'approbation visible) ; sinon « reading » si Ahadi lit un long contenu.
     Les activités réelles (réflexion, parole, outil…) passent toujours devant. */
  function compose() {
    if (videOn) return;
    const calm = activity === "repos" || activity === "ecoute";
    const wantAppr = calm && (waiting > 0 || !!apprEl);
    const want = wantAppr ? "approval" : (activity === "repos" && readEl) ? "reading" : "";
    if (want !== localPose) {
      localPose = want;
      try { if (want) wrap.setLocalState(want); else wrap._applyShared(); } catch (e) {}
    }
    host.classList.toggle("pv-waiting", wantAppr);
    host.dataset.pose = localPose;
    aimFocus();
  }
  /* Regard dirigé vers la cible réelle (carte d'approbation, zone lue) — coordonnées DOM. */
  function focusOn(x, y) {
    const b = host.getBoundingClientRect();
    if (!b.width) return;
    const fx = (x - (b.left + b.width / 2)) / Math.max(320, window.innerWidth * 0.5);
    const fy = -(y - (b.top + b.height * 0.35)) / Math.max(240, window.innerHeight * 0.5);
    try { wrap.setFocus(Math.max(-1, Math.min(1, fx)), Math.max(-1, Math.min(1, fy))); } catch (e) {}
  }
  function aimFocus() {
    try {
      if (localPose === "approval" && apprEl && apprEl.isConnected) {
        const r = apprEl.getBoundingClientRect();
        focusOn(r.left + r.width / 2, r.top + r.height / 2);
      } else if (localPose === "reading" && readEl && readEl.isConnected) {
        const r = readEl.getBoundingClientRect();
        const span = Math.max(1, readEl.scrollHeight - readEl.clientHeight);
        const frac = Math.max(0, Math.min(1, readEl.scrollTop / span));
        focusOn(r.left + r.width * 0.5, r.top + r.height * (0.2 + 0.6 * frac));
      } else wrap.setFocus(null);
    } catch (e) {}
  }
  function celebrate() {
    host.classList.add("pv-celebrate");
    clearTimeout(celebT);
    celebT = setTimeout(() => host.classList.remove("pv-celebrate"), 2600);
  }
  bus.on("nova:dot-run", (d) => {
    if (!d) return;
    if (d.phase === "waiting") { waiting++; compose(); }
    else if (d.phase === "ready") { waiting = Math.max(0, waiting - 1); compose(); }
  });
  window.addEventListener("nova:presence-state", (e) => {
    const st = e && e.detail && e.detail.state; if (!st) return;
    activity = st;
    if (st === "done" || st === "celebrate") { waiting = 0; celebrate(); }
    if (st === "erreur") setSharedMood("attention", 20000);
    host.dataset.activity = st;
    compose();
  });
  window.addEventListener("nova:approval-wait", (e) => {
    const d = (e && e.detail) || {};
    if (d.phase === "shown") { waiting++; compose(); }
    else if (d.phase === "resolved") {
      waiting = Math.max(0, waiting - 1);
      if (d.verdict === "approve") {
        setSharedMood("joie", 14000);
        /* PV 17 : célébration PROPORTIONNÉE — un OK simple = clin d'œil + hochement ;
           une approbation marquée majeure par son émetteur (Fundings, livrable) = grande fête. */
        if (d.major) { try { wrap.setState("celebrate"); } catch (e) {} } else reactAll("validate");
      }
      else if (d.verdict === "refuse") setSharedMood("attention", 16000);
      compose();
    }
  });
  window.addEventListener("nova:feedback", (e) => {
    const k = e && e.detail && e.detail.kind;
    if (k === "validation") { setSharedMood("joie", 20000); reactAll("validate"); }
    else if (k === "correction") setSharedMood("attention", 30000);
  });
  /* Arrivée d'un message du fil (Direct, Teams, mails, Dots) : le compagnon la VOIT
     au moment où elle descend — même instant, même animation partout. La gravité
     portée par les données pose l'humeur ; aucune gravité = aucune humeur inventée. */
  window.addEventListener("nova:feed-arrival", (e) => {
    const d = (e && e.detail) || {};
    reactAll("arrival");
    if (d.gravite === "grave" || d.urgent) setSharedMood("grave", 20000);
    else if (d.gravite === "legere") setSharedMood("legere", 14000);
  });
  /* Un clic sur le compagnon = un clic sur son ancre (ex. Accueil : couper la voix en cours) + un salut. */
  host.addEventListener("click", () => {
    reactAll("wave");
    try { if (cur) cur.dispatchEvent(new MouseEvent("click", { bubbles: true })); } catch (e) {}
    /* §40 : depuis la barre latérale, un clic sur le compagnon ouvre la conversation À CÔTÉ de la page en cours */
    try { if (host.dataset.slot === "rail" && window.NovaWorkspace) window.NovaWorkspace.openBeside("conversations"); } catch (e) {}
  });
  /* LE VIDE (R-127 / U4) : tout disparaît sauf le compagnon, qui s'endort. */
  bus.on("nova:vide", (d) => {
    const on = !!(d && d.on);
    videOn = on; localPose = "";
    try { if (on) wrap.setLocalState("sleep"); else wrap._applyShared(); } catch (e) {}
    host.classList.toggle("pv-vide", on);
    schedule(); setTimeout(schedule, 60);
  });

  /* ── V4-B · Célébration majeure : contrat public pour les autres lots ──
     window « nova:celebrate » { major: true } (livrable CAFU généré, synthèse du Conseil,
     approbation Fundings) → grande fête ; { major: false } → clin d'œil de validation. */
  window.addEventListener("nova:celebrate", (e) => {
    const d = (e && e.detail) || {};
    if (d.major) { try { wrap.setState("celebrate"); } catch (err) {} } else reactAll("validate");
  });

  /* ── V4-B · Écoute active (Voix Live, Feat_VoiceLive.swift) ──────────
     fin_phrase : le VAD a détecté ~350 ms de pause dans la voix d'Ahadi → hochement doux ;
     barge_in   : Ahadi interrompt → yeux écarquillés, silence immédiat. */
  try {
    bus.on("voix_live", (d) => {
      if (!d || typeof d !== "object") return;
      if (d.evenement === "fin_phrase") reactAll("nod");
      else if (d.evenement === "barge_in") reactAll("surprise");
    });
  } catch (e) {}

  /* ── V4-B · Nouvelle arrivée dans le fil direct (SSE « direct.appended ») ──
     Le panda roux fouette l'air de sa queue ; le panda géant dresse les oreilles. */
  let lastWhip = 0;
  try {
    bus.on("direct.appended", (d) => {
      if (!d || d.update) return;
      const now = Date.now(); if (now - lastWhip < 1200) return; lastWhip = now;
      reactAll("whip");
      whisperFromDirect(d);
    });
  } catch (e) {}

  /* ── V4-B · Carte d'approbation qui apparaît → pose « approval » tournée vers elle ──
     Sélecteurs réels : .appr (orb.js, carte d'approbation), .cn-confirm (confirmation),
     .card--decision (Éclats en attente), .fc-todo (« À toi » d'une carte du fil — seulement
     dans les 25 s qui suivent son APPARITION : une ancienne carte n'appelle pas de GO). */
  const APPR_SEL = ".appr, .cn-confirm, .card--decision, .fc-todo";
  const APPR_RANK = (el) => el.classList.contains("appr") ? 4 : el.classList.contains("cn-confirm") ? 3 : el.classList.contains("card--decision") ? 2 : 1;
  const apprSeen = new Map();
  let apprTimer = 0, apprQ = [], apprQT = 0;
  const inView = (el) => {
    const r = el.getBoundingClientRect();
    return r.width > 4 && r.height > 4 && r.bottom > 0 && r.right > 0 && r.top < window.innerHeight && r.left < window.innerWidth;
  };
  const pending = (el, now) => {
    if (el.classList.contains("fc-todo")) return now - (apprSeen.get(el) || 0) < 25000;
    if (el.classList.contains("appr")) { const b = el.querySelectorAll("button"); return !b.length || [...b].some((x) => !x.disabled); }
    return true;
  };
  function apprEval() {
    apprTimer = 0;
    if (document.hidden) { apprTimer = setTimeout(apprEval, 2000); return; }   // 29/10 : fenêtre cachée — aucune mesure de rect
    const now = Date.now();
    let best = null;
    for (const [el] of apprSeen) {
      if (!el.isConnected || (el.classList.contains("fc-todo") && now - apprSeen.get(el) > 25000)) { apprSeen.delete(el); continue; }
      if (!pending(el, now) || !inView(el) || el.closest("[hidden], [aria-hidden='true'].mod")) continue;
      if (!best || APPR_RANK(el) > APPR_RANK(best) || (APPR_RANK(el) === APPR_RANK(best) && apprSeen.get(el) > apprSeen.get(best))) best = el;
    }
    if (best !== apprEl) { apprEl = best; compose(); } else if (best) aimFocus();
    /* 29/10 : 700 ms tant qu'une carte de GO est affichée (le regard la suit) ; sinon 2 s suffisent pour
       voir apparaître une carte déjà connue (les nouvelles arrivent par le MutationObserver). */
    if (apprSeen.size) apprTimer = setTimeout(apprEval, best ? 700 : 2000);
  }
  function apprAdd(el, t) { if (!apprSeen.has(el)) apprSeen.set(el, t); }
  function apprFlush() {
    apprQT = 0;
    const now = Date.now(), q = apprQ, n0 = apprSeen.size; apprQ = [];
    for (const n of q) {
      if (!n.isConnected || n.closest(".pv-companion")) continue;
      if (n.matches(APPR_SEL)) apprAdd(n, now);
      n.querySelectorAll(APPR_SEL).forEach((x) => apprAdd(x, now));
    }
    if (apprSeen.size > n0) { clearTimeout(apprTimer); apprEval(); }   // 29/10 : une NOUVELLE carte est évaluée tout de suite (le sondage lent de 2 s ne la retarde pas)
    else if (apprSeen.size && !apprTimer) apprEval();
  }
  try {
    document.querySelectorAll(APPR_SEL).forEach((x) => apprAdd(x, x.classList.contains("fc-todo") ? 0 : Date.now()));
    new MutationObserver((muts) => {
      for (const m of muts) for (const n of m.addedNodes) if (n.nodeType === 1) apprQ.push(n);
      if (apprQ.length && !apprQT) apprQT = setTimeout(apprFlush, 220);
    }).observe(document.body, { childList: true, subtree: true });
    if (apprSeen.size) apprEval();
  } catch (e) {}

  /* ── V4-B · Lecture : défilement long d'un module de lecture → lunettes + regard qui suit ── */
  const READ_MODS = new Set(["messages", "veille", "conseil", "livrables", "savoir", "journal", "conversations", "relations", "engagements", "finance"]);
  let curMod = "";
  try { curMod = (ctx.currentId && ctx.currentId()) || ""; } catch (e) {}
  bus.on("nova:module", (d) => { if (d && d.id) curMod = String(d.id); });
  const lastTop = new WeakMap();
  let readAcc = 0, readAccT = 0, readUntil = 0, readT = 0, readAimRaf = 0;
  function readStop() {
    readT = 0;
    if (Date.now() < readUntil) { readT = setTimeout(readStop, readUntil - Date.now() + 30); return; }
    readEl = null; readAcc = 0; compose();
  }
  document.addEventListener("scroll", (e) => {
    try {
      const t = e.target;
      const el = t === document || t === document.documentElement ? document.scrollingElement : t;
      if (!el || el.nodeType !== 1 || !READ_MODS.has(curMod)) return;
      if (!el.closest("#view, .pane-body, .mod") || el.closest(".pv-companion")) return;
      if (el.scrollHeight < el.clientHeight * 1.8) return;
      const prev = lastTop.has(el) ? lastTop.get(el) : 0;   // premier défilement vu : depuis le haut (les évènements peuvent être regroupés)
      lastTop.set(el, el.scrollTop);
      const now = Date.now();
      if (now - readAccT > 10000) readAcc = 0;
      readAccT = now;
      readAcc += Math.abs(el.scrollTop - prev);
      if (readEl === el) {
        readUntil = now + 7000;
        if (!readAimRaf) readAimRaf = requestAnimationFrame(() => { readAimRaf = 0; aimFocus(); });
      } else if (readAcc >= 700) {
        readEl = el; readUntil = now + 7000;
        compose();
        if (!readT) readT = setTimeout(readStop, 7030);
      }
    } catch (err) {}
  }, { passive: true, capture: true });

  /* ── V4-B · WHISPER PILL : la pensée d'une phrase, toujours RÉELLE ────────────
     Sources (par priorité) : un GO attendu (carte visible / Éclat en attente) → l'activité
     en cours lue sur /api/activity → la dernière arrivée du fil direct (< 10 min) → l'écoute
     de la voix live. Rien de réel = pilule masquée (jamais de texte inventé). Clic = ouvre
     l'élément. Désactivable : bouton × (mémorisé, localStorage « nova2_whisper_pill ») ou
     window « nova:whisper-pill » { on } (interrupteur de Réglages). */
  const WP_KEY = "nova2_whisper_pill";
  let wpOn = true;
  try { wpOn = localStorage.getItem(WP_KEY) !== "0"; } catch (e) {}
  const wp = { running: [], direct: null, voix: "", waitName: "", pollT: 0, inflight: false };
  const pill = h("div", { class: "wp-pill", role: "button", tabindex: "0", hidden: true });
  const pDot = h("span", { class: "wp-dot", "aria-hidden": "true" });
  const pTxt = h("span", { class: "wp-t" });
  const pX = h("button", { class: "wp-x", type: "button", title: "Masquer la bulle d'intention", "aria-label": "Masquer la bulle d'intention" }, "×");
  pill.append(pDot, pTxt, pX);
  const mini = h("button", { class: "wp-mini", type: "button", hidden: true, "aria-label": "Pensée de Nova" });
  host.append(mini);
  let wpCur = null;
  const court = (x, n) => { x = String(x || "").replace(/\s+/g, " ").trim(); return x.length > n ? x.slice(0, n - 1) + "…" : x; };
  function whisperFromDirect(d) {
    const m = (d && d.msg) || null;
    if (!m) return;
    const first = String(m.content || "").split("\n")[0].replace(/^🔴\s*URGENT\s*—\s*/, "").replace(/\*\*|__|`/g, "").trim();   // 29/10 : pas d'astérisques markdown bruts dans la pastille
    if (!first) return;
    const who = String(m.who || "").trim();
    const rf = String(m.kind || "") === "dot.done" && /a [ée]chou[ée]|\bECHEC\b/i.test(String(m.content || "").slice(0, 300));   // V5-Y : échec d'Éclat ≠ urgence
    wp.direct = { t: Date.now(), text: (m.urgent && !rf ? "Urgent · " : rf ? "Échec · " : "Nouveau · ") + court((who && !first.includes(who) ? who + " — " : "") + first, 70), conv: String(d.conv || "") };
    wpPaint();
  }
  function wpPick() {
    if (waiting > 0 || apprEl) {
      const nm = wp.waitName;
      return { kind: "go", text: nm ? nm + " attend ton GO" : "J'attends ton GO", go: () => {
        if (apprEl && apprEl.isConnected) { try { apprEl.scrollIntoView({ block: "center", behavior: "smooth" }); } catch (e) {} }
        else ctx.navigate("dots");
      } };
    }
    const r = wp.running[0];
    if (r) return { kind: "run", text: court(String(r.label || r.name || ""), 70), go: () => {
      if (r.kind === "conversation" && r.id) {
        try { localStorage.setItem("nova2_pending_conv", String(r.id)); } catch (e) {}
        ctx.navigate("conversations");
        setTimeout(() => { try { bus.emit("nova:open-conv", { id: String(r.id) }); } catch (e) {} }, 120);
      } else if (r.ecran) ctx.navigate(String(r.ecran));
    } };
    if (wp.direct && Date.now() - wp.direct.t < 600000) {
      const dd = wp.direct;
      return { kind: "direct", text: dd.text, go: () => {
        if (dd.conv) { try { localStorage.setItem("nova2_pending_conv", dd.conv); } catch (e) {} }
        ctx.navigate("conversations");
        if (dd.conv) setTimeout(() => { try { bus.emit("nova:open-conv", { id: dd.conv }); } catch (e) {} }, 120);
      } };
    }
    if (wp.voix) return { kind: "voix", text: wp.voix, go: () => ctx.navigate("conversations") };
    return null;
  }
  function wpMount() {
    const pres = document.querySelector(".rail-presence");
    if (!pres) return false;
    const txt = pres.querySelector(".rp-txt");
    if (txt && pill.parentElement !== txt) txt.append(pill);
    return true;
  }
  function wpPaint() {
    if (!wpMount()) { setTimeout(wpPaint, 800); return; }
    const pres = pill.closest(".rail-presence");
    wpCur = wpOn ? wpPick() : null;
    const on = !!(wpCur && wpCur.text);
    if (pill.hidden !== !on) pill.hidden = !on;
    if (pres && pres.classList.contains("has-whisper") !== on) pres.classList.toggle("has-whisper", on);
    if (mini.hidden !== !on) mini.hidden = !on;
    if (on && pTxt.textContent !== wpCur.text) {
      pTxt.textContent = wpCur.text;
      pill.title = wpCur.text + " — clic : ouvrir";
      pill.dataset.kind = wpCur.kind;
      mini.title = wpCur.text;
      mini.dataset.kind = wpCur.kind;
    }
  }
  const wpGo = (e) => { if (e) { e.stopPropagation(); } if (wpCur && wpCur.go) { try { wpCur.go(); } catch (err) {} } };
  pill.addEventListener("click", (e) => { if (e.target === pX) return; wpGo(e); });
  pill.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); wpGo(e); } });
  mini.addEventListener("click", wpGo);
  pX.addEventListener("click", (e) => {
    e.stopPropagation();
    wpOn = false; try { localStorage.setItem(WP_KEY, "0"); } catch (err) {}
    wpPaint();
    try { ctx.toast("Bulle d'intention masquée."); } catch (err) {}
  });
  window.addEventListener("nova:whisper-pill", (e) => {
    wpOn = !!(e && e.detail && e.detail.on);
    try { localStorage.setItem(WP_KEY, wpOn ? "1" : "0"); } catch (err) {}
    wpPaint();
  });
  async function wpPoll() {
    clearTimeout(wp.pollT);
    if (!document.hidden && wpOn && !wp.inflight) {
      wp.inflight = true;
      try {
        /* 29/10 (fluidité) : le halo de la coquille sonde déjà /api/activity — on réutilise sa lecture si
           elle a moins de 15 s au lieu de doubler la requête (il sonde toutes les 4 s dès que quelque chose tourne). */
        const c = window.__novaActivity;
        const j = c && Date.now() - c.t < 15000 ? c.j : await ctx.api.get("/api/activity", 8000);
        wp.running = (Array.isArray(j && j.running) ? j.running : []).filter((x) => x && (x.label || x.name));
      } catch (e) { wp.running = []; }
      wp.inflight = false;
      wpPaint();
    }
    wp.pollT = setTimeout(wpPoll, wp.running.length ? 5000 : 30000);
  }
  bus.on("nova:dot-run", (d) => {
    if (d && d.phase === "waiting") wp.waitName = String(d.dot_name || d.name || "");
    else if (d && d.phase === "ready" && waiting <= 1) wp.waitName = "";
    setTimeout(wpPaint, 0);
    clearTimeout(wp.pollT); wp.pollT = setTimeout(wpPoll, 900);
  });
  try {
    bus.on("voix_live", (d) => {
      if (!d || typeof d !== "object" || !d.etat) return;
      wp.voix = d.etat === "ecoute" ? "Je t'écoute…" : "";
      wpPaint();
    });
  } catch (e) {}
  window.addEventListener("nova:presence-state", () => { clearTimeout(wp.pollT); wp.pollT = setTimeout(wpPoll, 1500); });
  window.addEventListener("nova:approval-wait", () => setTimeout(wpPaint, 0));
  const wpCompose = compose;
  compose = () => { wpCompose(); wpPaint(); };
  setTimeout(wpPoll, 2000);

  place();
  setTimeout(schedule, 300); setTimeout(schedule, 1200);
  return host;
}
