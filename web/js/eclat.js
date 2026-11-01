/* LOT-13 — Éclat, la luciole de verre (second compagnon, DOM/CSS seul). */
import { bus } from "./core.js";

/* ── 1. Constantes et clés ─────────────────────────────────────────── */
const MODE_KEY = "nova2_eclat_mode";
const HABITS_KEY = "nova2_eclat_habits";
const LASTDAY_KEY = "nova2_eclat_lastday";
const EVENING_KEY = "nova2_eclat_evening";
const MAX_FLIGHTS_PER_HOUR = 6;
const PRIO = { approval: 3, dot: 2, mail: 1 };

/* ── 2. Petits utilitaires sûrs ────────────────────────────────────── */
function dayStr(d = new Date()) {
  try {
    const y = d.getFullYear(), m = String(d.getMonth() + 1).padStart(2, "0"), j = String(d.getDate()).padStart(2, "0");
    return y + "-" + m + "-" + j;
  } catch (e) { return "1970-01-01"; }
}
function minsOfDay(d = new Date()) { try { return d.getHours() * 60 + d.getMinutes(); } catch (e) { return 0; } }
function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }
function getMode() {
  try { const m = localStorage.getItem(MODE_KEY); if (m === "silencieux" || m === "off" || m === "actif") return m; } catch (e) {}
  return "off";   // 24/10 : le compagnon vivant (panda/renard) porte la présence — la luciole n'apparaît que si Ahadi la rallume
}
function isReducedMotion() {
  try {
    if (document.documentElement.dataset.reduceMotion === "1") return true;
    if (window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches) return true;
  } catch (e) {}
  return false;
}
function loadHabits() {
  try {
    const v = JSON.parse(localStorage.getItem(HABITS_KEY) || "null");
    if (v && typeof v === "object") return { follows: Array.isArray(v.follows) ? v.follows : [], deposited: Number(v.deposited) || 0 };
  } catch (e) {}
  return { follows: [], deposited: 0 };
}
function saveHabits(h) { try { localStorage.setItem(HABITS_KEY, JSON.stringify(h)); } catch (e) {} }
function pruneHabits(h) {
  try {
    const cut = Date.now() - 30 * 86400000;
    h.follows = (h.follows || []).filter((f) => {
      try { const t = new Date(f.day + "T12:00:00").getTime(); return isFinite(t) && t >= cut; } catch (e) { return false; }
    });
  } catch (e) {}
  return h;
}

/* ── 3. Heures calmes (défaut 22:00–07:00, voir NOTE) ──────────────── */
function parseQuietFromSettings(s) {
  try {
    if (!s || typeof s !== "object") return null;
    const num = (v) => {
      if (v == null) return null;
      if (typeof v === "number" && isFinite(v)) return v < 24 ? Math.round(v * 60) : Math.round(v);
      const m = String(v).match(/(\d{1,2})[:hH]?(\d{2})?/);
      if (!m) return null;
      return (Number(m[1]) * 60 + Number(m[2] || 0)) % 1440;
    };
    const pairs = [
      ["quiet_start", "quiet_end"], ["quiet_debut", "quiet_fin"], ["debut_calme", "fin_calme"],
      ["silence_debut", "silence_fin"], ["quiet_hours_start", "quiet_hours_end"], ["debut", "fin"],
    ];
    for (const [a, b] of pairs) {
      const x = num(s[a]), y = num(s[b]);
      if (x != null && y != null) return { start: x, end: y };
    }
    if (s.quiet_hours && typeof s.quiet_hours === "string") {
      const m = s.quiet_hours.match(/(\d{1,2})[^0-9]+(\d{1,2})/);
      if (m) return { start: (Number(m[1]) * 60) % 1440, end: (Number(m[2]) * 60) % 1440 };
    }
  } catch (e) {}
  return null;
}
function inQuietWindow(mins, q) {
  if (!q) return false;
  if (q.start <= q.end) return mins >= q.start && mins < q.end;
  return mins >= q.start || mins < q.end;
}

/* ── 4. Fonction principale (aucun argument) ───────────────────────── */
export function mountEclat() {
  try {
    if (window.__novaEclatMounted) return;
    window.__novaEclatMounted = true;
    let habits = pruneHabits(loadHabits());
    saveHabits(habits);

    /* ── 5. Construction du DOM (UN seul élément) ─────────────────── */
    const el = document.createElement("div");
    el.className = "eclat at-perch";
    el.setAttribute("role", "button");
    el.setAttribute("tabindex", "0");
    el.setAttribute("aria-label", "Luciole, la petite lumière de verre");
    el.setAttribute("title", "Luciole — clique pour suivre, double-clique pour rentrer");
    el.dataset.core = "1";
    const core = document.createElement("div");
    core.className = "eclat-core";
    const star = document.createElement("div");
    star.className = "eclat-star";
    const trail = document.createElement("span");
    trail.className = "eclat-trail";
    for (let i = 0; i < 3; i++) trail.append(document.createElement("i"));
    el.append(core, star, trail);
    try { document.body.append(el); } catch (e) { return; }

    const S = {
      mode: getMode(), flying: false, queue: [], flightTimes: [],
      lastEvents: [], lastUnseen: null, onCard: null, cardEl: null,
      quiet: { start: 22 * 60, end: 7 * 60 }, quietOn: false, summaryTarget: null,
      perchOverride: null, clickTimer: 0, clickCount: 0, dead: false, deferred: [],
    };
    const hide = () => { try { el.style.display = "none"; } catch (e) {} };
    const show = () => { try { el.style.display = ""; } catch (e) {} };
    const setCore = (v) => { try { el.dataset.core = String(v); } catch (e) {} };
    const ping = () => {
      try { el.classList.remove("ping"); void el.offsetWidth; el.classList.add("ping"); setTimeout(() => { try { el.classList.remove("ping"); } catch (e) {} }, 650); } catch (e) {}
    };
    const pale = () => {
      try {
        const prev = el.dataset.core || "1";
        setCore("0.35");
        setTimeout(() => { try { if (!S.quietOn && !S.onCard) setCore(prev === "0.35" ? "1" : prev); } catch (e) {} }, 2000);
      } catch (e) {}
    };
    const microPulse = () => {
      try { el.classList.remove("eclat-micro"); void el.offsetWidth; el.classList.add("eclat-micro"); setTimeout(() => { try { el.classList.remove("eclat-micro"); } catch (e) {} }, 500); } catch (e) {}
    };
    function renderTrail() {
      try {
        const extra = clamp(Math.floor((habits.deposited || 0) / 50), 0, 3);
        const want = 3 + extra;
        while (trail.childElementCount < want) trail.append(document.createElement("i"));
        while (trail.childElementCount > want) trail.lastElementChild.remove();
      } catch (e) {}
    }
    renderTrail();
    function applyMode() {
      try {
        S.mode = getMode();
        if (S.mode === "off") { hide(); releaseCard(false); stopWatch(); }
        else { show(); if (S.quietOn) setCore("0.18"); else if (!S.onCard) setCore("1"); startWatch(); }
      } catch (e) {}
    }

    /* ── 6. Perchoir (jamais dans le rail) ────────────────────────── */
    function watchboxVisible() {
      try { const w = document.getElementById("watchbox"); return !!(w && w.style.display !== "none" && w.childElementCount); } catch (e) { return false; }
    }
    function refreshPerchClass() {
      try {
        if (S.onCard) { el.classList.remove("at-perch", "perch-high"); return; }
        if (!el.classList.contains("at-perch")) el.classList.add("at-perch");
        el.classList.toggle("perch-high", watchboxVisible());
        if (S.perchOverride) { el.classList.remove("at-perch", "perch-high"); }
      } catch (e) {}
    }
    function perchPoint() {
      try {
        if (S.perchOverride) return S.perchOverride;
        const w = 30, hh = 22;
        const bottom = watchboxVisible() ? 152 : 96;
        return { x: window.innerWidth - 20 - w, y: window.innerHeight - bottom - hh };
      } catch (e) { return { x: 100, y: 100 }; }
    }
    function placeOnCard(cardEl) {
      try {
        if (!cardEl || !cardEl.isConnected) return false;
        const r = cardEl.getBoundingClientRect();
        const x = clamp(r.right - 15, 8, window.innerWidth - 38);
        const y = clamp(r.top - 6 - 22, 8, window.innerHeight - 30);
        S.onCard = cardEl; S.cardEl = cardEl;
        el.classList.remove("at-perch", "perch-high");
        el.classList.add("on-card");
        el.style.left = x + "px"; el.style.top = y + "px";
        el.style.right = "auto"; el.style.bottom = "auto";
        setCore("0.9");
        return true;
      } catch (e) { return false; }
    }
    function releaseCard(flyHome = true) {
      try {
        if (!S.onCard) { refreshPerchClass(); return; }
        S.onCard = null; S.cardEl = null;
        el.classList.remove("on-card");
        el.style.left = ""; el.style.top = ""; el.style.right = ""; el.style.bottom = "";
        el.classList.add("at-perch");
        refreshPerchClass();
        if (!S.quietOn) setCore("1");
        if (flyHome) { try { el.animate([{ transform: "translate(0,-6px)" }, { transform: "translate(0,0)" }], { duration: 250 }); } catch (e) {} }
      } catch (e) {}
    }
    function trackCardLoss() {
      try {
        if (S.onCard && !S.onCard.isConnected) releaseCard(true);
        else if (S.onCard) {
          const r = S.onCard.getBoundingClientRect();
          if (r.width === 0 && r.height === 0) releaseCard(true);
          else placeOnCard(S.onCard);
        }
      } catch (e) {}
    }

    /* ── 7. Cibles des vols ───────────────────────────────────────── */
    function railBtn(title) { try { return document.querySelector('.rail-btn[title="' + title + '"]'); } catch (e) { return null; } }
    function findApprovalCard() {
      try {
        return document.querySelector(".card--decision") || document.querySelector("[data-decision]") ||
          document.querySelector(".dock-confirm") || document.querySelector(".appr-card") ||
          document.querySelector("[data-approval]");
      } catch (e) { return null; }
    }
    function resolveTarget(kind) {
      try {
        if (kind === "approval") { const c = findApprovalCard(); if (c) return c; }
        if (kind === "mail") return railBtn("Messages") || document.querySelector(".feed-unit") || railBtn("Veille");
        if (kind === "dot") return railBtn("Éclats") || railBtn("Conversations") || document.querySelector(".feed-unit");
        if (kind === "brief") return railBtn("Veille") || document.querySelector(".feed-unit");
        return railBtn("Veille") || document.querySelector(".feed-unit") || document.body;
      } catch (e) { return null; }
    }
    function targetPoint(tEl, hover = 8) {
      try {
        const r = tEl.getBoundingClientRect();
        return { x: clamp(r.left + r.width / 2 - 15, 8, window.innerWidth - 38), y: clamp(r.top - hover - 22, 8, window.innerHeight - 30) };
      } catch (e) { const p = perchPoint(); return p; }
    }
    function isApprovalPayload(d) {
      try {
        if (!d || typeof d !== "object") return false;
        const k = String(d.kind || d.type || "");
        if (/approv|decision|waiting|confirm/i.test(k)) return true;
        if (d.action && /approuv|décision|decision/i.test(String(d.action.label || "") + String(d.action.module || ""))) return true;
        if (d.runId && /waiting/i.test(k)) return true;
      } catch (e) {}
      return false;
    }

    /* ── 8. Moteur de vol (un seul à la fois) ─────────────────────── */
    function budgetOk() {
      try {
        const now = Date.now();
        S.flightTimes = S.flightTimes.filter((t) => now - t < 3600000);
        return S.flightTimes.length < MAX_FLIGHTS_PER_HOUR;
      } catch (e) { return true; }
    }
    function enqueue(kind, targetEl, label) {
      try {
        if (S.mode === "off") return;
        const ev = { kind, targetEl: targetEl || null, label: String(label || kind), at: Date.now(), seen: false };
        S.lastEvents.push(ev);
        while (S.lastEvents.length > 12) S.lastEvents.shift();
        S.lastUnseen = ev;
        if (kind === "approval" || !S.summaryTarget) S.summaryTarget = ev;
        const ex = S.queue.find((q) => q.kind === kind);
        if (ex) { ex.targetEl = ev.targetEl || ex.targetEl; ex.label = ev.label; return; }
        S.queue.push(ev);
        S.queue.sort((a, b) => (PRIO[b.kind] || 0) - (PRIO[a.kind] || 0));
        pump();
      } catch (e) {}
    }
    function vplayOn() { try { return document.body.classList.contains("vplay"); } catch (e) { return false; } }
    function pump() {
      try {
        if (S.flying || !S.queue.length || S.mode === "off") return;
        if (S.mode === "silencieux") { S.queue.length = 0; ping(); return; }
        if (S.quietOn) { S.queue.length = 0; setCore("0.18"); return; }
        if (vplayOn()) {
          const ev = S.queue.shift();
          S.deferred.push(ev);
          setTimeout(() => {
            try {
              const i = S.deferred.indexOf(ev);
              if (i >= 0) S.deferred.splice(i, 1);
              ping();
            } catch (e) {}
          }, 30000);
          if (S.queue.length) setTimeout(() => pump(), 4000);
          return;
        }
        if (!budgetOk()) { S.queue.length = 0; ping(); return; }
        const ev = S.queue.shift();
        const tEl = (ev.targetEl && ev.targetEl.isConnected) ? ev.targetEl : resolveTarget(ev.kind);
        if (!tEl) { ping(); setTimeout(() => pump(), 300); return; }
        ev.targetEl = tEl;
        if (ev.kind === "approval") flyToCard(tEl);
        else flyRoundTrip(tEl, {});
      } catch (e) {}
    }
    function bez(a, c, b, t) {
      const u = 1 - t;
      return { x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y };
    }
    async function animateAlong(from, to, lift, opts = {}) {
      const dist = Math.hypot(to.x - from.x, to.y - from.y);
      let dur = clamp(dist / 900, 0.35, 1.2) * 1000;
      if (opts.slow) dur = clamp(dur * 1.6, 0.6, 2);
      if (isReducedMotion()) {
        try { await el.animate([{ opacity: 1 }, { opacity: 0.25 }, { opacity: 1 }], { duration: 350 }).finished; } catch (e) {}
        return;
      }
      const mid = { x: (from.x + to.x) / 2, y: Math.min(from.y, to.y) - 60 - lift };
      const frames = [];
      for (let i = 0; i <= 12; i++) {
        const p = bez(from, mid, to, i / 12);
        frames.push({ transform: "translate(" + Math.round(p.x - from.x) + "px," + Math.round(p.y - from.y) + "px)" });
      }
      try {
        try { await el.animate([{ transform: "translate(0,0)" }, { transform: "translate(0,-12px)" }], { duration: 200, easing: "ease-out" }).finished; } catch (e) {}
        const a = el.animate(frames, { duration: dur, easing: "ease-in-out" });
        try { await a.finished; } catch (e) {}
      } catch (e) {}
    }
    function currentXY() { try { const r = el.getBoundingClientRect(); return { x: r.left, y: r.top }; } catch (e) { return perchPoint(); } }
    async function flyRoundTrip(tEl, opts = {}) {
      if (S.flying) return;
      S.flying = true;
      try { el.classList.add("flying"); } catch (e) {}
      try {
        const start = currentXY();
        const dest = targetPoint(tEl, 8);
        await animateAlong(start, dest, 0, opts);
        try { el.classList.add("eclat--celebrate"); setTimeout(() => { try { el.classList.remove("eclat--celebrate"); } catch (e) {} }, 400); } catch (e) {}
        await new Promise((r) => setTimeout(r, 600));
        const back = perchPoint();
        const nowAt = currentXY();
        await animateAlong({ x: nowAt.x, y: nowAt.y }, back, 0, opts);
        try { el.style.transform = ""; } catch (e) {}
        refreshPerchClass();
        S.flightTimes.push(Date.now());
        habits.deposited = (habits.deposited || 0) + 1;
        saveHabits(habits); renderTrail();
      } catch (e) {}
      try { el.classList.remove("flying"); } catch (e) {}
      S.flying = false;
      setTimeout(() => pump(), 120);
    }
    async function flyToCard(cardEl) {
      if (S.flying) { enqueue("approval", cardEl, "approbation"); return; }
      S.flying = true;
      try { el.classList.add("flying"); } catch (e) {}
      try {
        const start = currentXY();
        const r = cardEl.getBoundingClientRect();
        const dest = { x: clamp(r.right - 15, 8, window.innerWidth - 38), y: clamp(r.top - 6 - 22, 8, window.innerHeight - 30) };
        await animateAlong(start, dest, 0, {});
        try { el.style.transform = ""; } catch (e) {}
        placeOnCard(cardEl);
        S.flightTimes.push(Date.now());
        habits.deposited = (habits.deposited || 0) + 1;
        saveHabits(habits); renderTrail();
      } catch (e) {}
      try { el.classList.remove("flying"); } catch (e) {}
      S.flying = false;
    }

    /* ── 9. Sources du bus ────────────────────────────────────────── */
    function onMailEvent(label) {
      try {
        if (S.mode === "off") return;
        if (window.__novaModule === "conversations") { microPulse(); }
        if (S.mode === "silencieux" || S.quietOn || isReducedMotion() && false) { if (S.mode === "silencieux") ping(); }
        enqueue("mail", null, label || "courrier");
        if (window.__novaModule === "conversations") microPulse();
      } catch (e) {}
    }
    function onDotRun(d) {
      try {
        if (S.mode === "off" || !d || typeof d !== "object") return;
        const bad = d.ok === false || /err|fail|éch|error/i.test(String(d.status || d.error || ""));
        if (d.phase && d.phase !== "ready" && d.phase !== "done" && !d.ok && d.phase !== "waiting") {
          if (bad) { pale(); return; }
          if (d.phase === "working") return;
        }
        if (bad) { pale(); return; }
        enqueue("dot", null, String(d.dot_name || d.name || "Éclat"));
      } catch (e) {}
    }
    function onDirectItem(d) {
      try {
        if (S.mode === "off" || !d || typeof d !== "object") return;
        if (isApprovalPayload(d)) {
          const card = findApprovalCard();
          enqueue("approval", card || null, String(d.titre || d.title || "approbation"));
          return;
        }
        const k = String(d.kind || "");
        if (k === "mail" || k === "push" || k === "brief" || k === "due" || k === "dot" || k === "waiting") {
          if (k === "waiting") { const card = findApprovalCard(); enqueue("approval", card || null, String(d.titre || "décision")); return; }
          onMailEvent(String(d.titre || k));
        } else onMailEvent(String(d.titre || "direct"));
      } catch (e) {}
    }
    function onDecision() {
      try {
        if (S.onCard) { releaseCard(true); S.queue = S.queue.filter((q) => q.kind !== "approval"); }
      } catch (e) {}
    }
    try { bus.on("nova:mail-new", (d) => onMailEvent(String((d && d.box) || "courrier"))); } catch (e) {}
    try { bus.on("nova:direct-item", onDirectItem); } catch (e) {}
    try { bus.on("nova:dot-run", onDotRun); } catch (e) {}
    try { bus.on("nova:decision", onDecision); } catch (e) {}
    try {
      bus.on("nova:focus-change", () => { if (S.mode !== "off") refreshQuiet().catch(() => {}); });
    } catch (e) {}

    /* ── 10. Heures calmes ────────────────────────────────────────── */
    async function refreshQuiet() {
      try {
        const r = await fetch("/api/settings", { headers: { accept: "application/json" } });
        const j = await r.json();
        const s = (j && (j.settings || j)) || {};
        const q = parseQuietFromSettings(s) || parseQuietFromSettings(s.settings) || null;
        if (q) S.quiet = q;
      } catch (e) {}
      checkQuiet();
    }
    function checkQuiet() {
      try {
        const q = inQuietWindow(minsOfDay(new Date()), S.quiet);
        if (q && !S.quietOn) { S.quietOn = true; setCore("0.18"); S.queue.length = 0; }
        else if (!q && S.quietOn) {
          S.quietOn = false;
          if (!S.onCard) setCore("1");
          if (S.summaryTarget && S.summaryTarget.targetEl && S.summaryTarget.targetEl.isConnected) {
            const t = S.summaryTarget.targetEl;
            S.summaryTarget = null;
            enqueue(S.summaryTarget ? "mail" : "mail", t, "résumé");
          } else if (S.lastUnseen && S.lastUnseen.targetEl && S.lastUnseen.targetEl.isConnected) {
            enqueue("mail", S.lastUnseen.targetEl, "résumé");
          }
        }
      } catch (e) {}
    }

    /* ── 11. Clics : suivre puis rentrer ──────────────────────────── */
    function recordFollow(kind) {
      try {
        habits.follows.push({ kind: String(kind || "mail"), day: dayStr(), mins: minsOfDay() });
        habits = pruneHabits(habits);
        saveHabits(habits);
      } catch (e) {}
    }
    function hop() { try { return el.animate([{ transform: "translate(0,0)" }, { transform: "translate(0,-10px)" }, { transform: "translate(0,0)" }], { duration: 180 }); } catch (e) { return null; } }
    function onSingleClick() {
      try {
        if (S.mode === "off") return;
        const h = hop();
        const go = () => {
          try {
            const ev = S.lastUnseen && !evSeen(S.lastUnseen) ? S.lastUnseen : [...S.lastEvents].reverse().find((e) => !evSeen(e));
            const target = (ev && ev.targetEl && ev.targetEl.isConnected) ? ev.targetEl : resolveTarget((ev && ev.kind) || "mail");
            if (!target) { ping(); return; }
            if (ev) { ev.seen = true; if (S.lastUnseen === ev) S.lastUnseen.seen = true; }
            recordFollow((ev && ev.kind) || "mail");
            if (S.mode === "silencieux" || S.quietOn || vplayOn()) { ping(); return; }
            if (!budgetOk()) { ping(); return; }
            flyRoundTrip(target, {});
          } catch (e) {}
        };
        if (h && h.finished) h.finished.then(go).catch(go);
        else setTimeout(go, 190);
      } catch (e) {}
    }
    function evSeen(ev) { try { return !!(ev && ev.seen); } catch (e) { return true; } }
    function onDoubleClick() {
      try {
        try { el.getAnimations().forEach((a) => { try { a.cancel(); } catch (e) {} }); } catch (e) {}
        try { el.style.transform = ""; } catch (e) {}
        S.queue.length = 0; S.flying = false;
        try { el.classList.remove("flying"); } catch (e) {}
        releaseCard(false);
        refreshPerchClass();
      } catch (e) {}
    }
    try {
      el.addEventListener("click", () => {
        S.clickCount++;
        clearTimeout(S.clickTimer);
        S.clickTimer = setTimeout(() => { try { if (S.clickCount === 1) onSingleClick(); else onDoubleClick(); } catch (e) {} S.clickCount = 0; }, 260);
      });
      el.addEventListener("keydown", (e) => {
        try { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); onSingleClick(); } else if (e.key === "Escape") onDoubleClick(); } catch (err) {}
      });
    } catch (e) {}
    try { window.addEventListener("nova:eclat-mode", () => applyMode()); } catch (e) {}

    /* ── 12. Conversations : perchoir compositeur ─────────────────── */
    function composerEl() {
      try {
        const v = document.getElementById("view");
        const c = v ? v.querySelector(".composer") : null;
        if (c && c.isConnected && c.getBoundingClientRect().width > 0) return c;
        return null;
      } catch (e) { return null; }
    }
    function checkConversations() {
      try {
        if (window.__novaModule === "conversations") {
          const c = composerEl();
          if (c) {
            const r = c.getBoundingClientRect();
            S.perchOverride = { x: clamp(r.right - 44, 8, window.innerWidth - 38), y: clamp(r.top - 30, 8, window.innerHeight - 30) };
            /* 29/10 (fluidité) : sondé chaque seconde — on n'écrit le style que s'il change (aucune invalidation au repos) */
            if (!S.onCard && !S.flying && (el.style.left !== S.perchOverride.x + "px" || el.style.top !== S.perchOverride.y + "px" || !el.classList.contains("on-card"))) {
              el.classList.remove("at-perch", "perch-high");
              el.classList.add("on-card");
              el.style.left = S.perchOverride.x + "px"; el.style.top = S.perchOverride.y + "px";
              el.style.right = "auto"; el.style.bottom = "auto";
            }
            return;
          }
        }
        if (S.perchOverride) {
          S.perchOverride = null;
          if (!S.onCard) { el.classList.remove("on-card"); el.style.left = ""; el.style.top = ""; refreshPerchClass(); }
        }
      } catch (e) {}
    }

    /* ── 13. Habitudes : vols anticipés ───────────────────────────── */
    function median(ns) { try { const s = ns.slice().sort((a, b) => a - b); return s[Math.floor(s.length / 2)]; } catch (e) { return 0; } }
    function checkHabits() {
      try {
        if (S.mode !== "actif" || S.quietOn || S.flying || vplayOn()) return;
        const now = minsOfDay();
        const byKind = new Map();
        for (const f of habits.follows || []) {
          if (!byKind.has(f.kind)) byKind.set(f.kind, []);
          byKind.get(f.kind).push(f);
        }
        for (const [kind, arr] of byKind) {
          if (arr.length < 5) continue;
          const days = new Set(arr.map((f) => f.day));
          if (days.size < 3) continue;
          const med = median(arr.map((f) => Number(f.mins) || 0));
          const near = arr.filter((f) => Math.abs(Number(f.mins) - med) <= 30);
          if (near.length < 5) continue;
          const nearDays = new Set(near.map((f) => f.day));
          if (nearDays.size < 3) continue;
          let diff = Math.abs(now - med);
          diff = Math.min(diff, 1440 - diff);
          if (diff <= 5) {
            const t = resolveTarget(kind === "dot" ? "dot" : kind === "approval" ? "approval" : "mail");
            if (t && t.isConnected !== false) { flyRoundTrip(t, { slow: true }); return; }
          }
        }
      } catch (e) {}
    }

    /* ── 14. Rituels matin et soir ────────────────────────────────── */
    function morningRitual() {
      try {
        const today = dayStr();
        let last = "";
        try { last = localStorage.getItem(LASTDAY_KEY) || ""; } catch (e) {}
        if (last === today) return;
        try { localStorage.setItem(LASTDAY_KEY, today); } catch (e) {}
        setTimeout(() => {
          try {
            if (S.mode !== "actif" || S.quietOn || vplayOn()) return;
            let t = null;
            try {
              const btns = [...document.querySelectorAll("button")];
              t = btns.find((b) => /brief du matin/i.test(b.textContent || ""));
            } catch (e) {}
            if (!t || !t.isConnected) t = railBtn("Veille");
            if (t) flyRoundTrip(t, { slow: true });
          } catch (e) {}
        }, 2500);
      } catch (e) {}
    }
    function eveningRitual() {
      try {
        const h = new Date().getHours();
        if (h < 21) return;
        const today = dayStr();
        let done = "";
        try { done = localStorage.getItem(EVENING_KEY) || ""; } catch (e) {}
        if (done === today) return;
        try { localStorage.setItem(EVENING_KEY, today); } catch (e) {}
        setTimeout(async () => {
          try {
            if (S.mode !== "actif" || vplayOn()) return;
            const unseen = S.lastEvents.filter((e) => !e.seen).slice(-3);
            const targets = [];
            for (const ev of unseen) {
              const t = (ev.targetEl && ev.targetEl.isConnected) ? ev.targetEl : resolveTarget(ev.kind);
              if (t) targets.push(t);
              if (targets.length >= 3) break;
            }
            for (const t of targets) {
              if (S.mode !== "actif" || vplayOn()) break;
              await flyRoundTrip(t, { slow: true });
              await new Promise((r) => setTimeout(r, 300));
            }
            setCore("0.3");
          } catch (e) {}
        }, 4000);
      } catch (e) {}
    }

    /* ── 15. Observateurs, sondes et amorçage ─────────────────────── */
    /* FIX-WEB (audit P1 eclat.js:605-613) : mode « off » (défaut) = TOTALEMENT inerte — aucun
       MutationObserver, aucun intervalle, aucun écouteur scroll/resize/click, aucun appel réseau.
       startWatch/stopWatch suivent applyMode (événement nova:eclat-mode). En mode actif/silencieux :
       observer débouncé par requestAnimationFrame (au lieu d'un recalcul par mutation, donc par
       jeton de réponse) et intervalles suspendus quand la fenêtre est cachée. */
    const W = { on: false, mo: null, raf: 0, timers: [], booted: false };
    const onMut = () => { if (W.raf) return; W.raf = requestAnimationFrame(() => { W.raf = 0; try { trackCardLoss(); refreshPerchClass(); } catch (e) {} }); };
    const onScroll = () => { try { if (S.onCard && S.cardEl) placeOnCard(S.cardEl); } catch (e) {} };
    const onResize = () => { try { if (S.onCard && S.cardEl) placeOnCard(S.cardEl); else refreshPerchClass(); } catch (e) {} };
    const onClickCap = () => { try { checkConversations(); } catch (e) {} };
    const startTimers = () => {
      if (W.timers.length || document.hidden) return;
      W.timers.push(setInterval(() => { try { checkConversations(); } catch (e) {} }, 1000));
      W.timers.push(setInterval(() => { try { trackCardLoss(); } catch (e) {} }, 2000));
      W.timers.push(setInterval(() => { try { checkHabits(); checkQuiet(); } catch (e) {} }, 60000));
    };
    const stopTimers = () => { W.timers.splice(0).forEach((t) => clearInterval(t)); };
    const onVis = () => { if (document.hidden) stopTimers(); else if (W.on) { startTimers(); try { checkQuiet(); } catch (e) {} } };
    function startWatch() {
      if (W.on) return; W.on = true;
      try { W.mo = new MutationObserver(onMut); W.mo.observe(document.body, { childList: true, subtree: true }); } catch (e) {}
      try { window.addEventListener("scroll", onScroll, { passive: true, capture: true }); } catch (e) {}
      try { window.addEventListener("resize", onResize); } catch (e) {}
      try { document.addEventListener("click", onClickCap, true); } catch (e) {}
      try { document.addEventListener("visibilitychange", onVis); } catch (e) {}
      startTimers();
      refreshPerchClass();
      refreshQuiet().catch(() => {});
      if (!W.booted) {
        W.booted = true;
        morningRitual();
        eveningRitual();
        setTimeout(() => { try { const c = findApprovalCard(); if (c && S.mode === "actif" && !S.quietOn) enqueue("approval", c, "approbation"); } catch (e) {} }, 3000);
      }
    }
    function stopWatch() {
      if (!W.on) return; W.on = false;
      try { if (W.mo) W.mo.disconnect(); } catch (e) {} W.mo = null;
      if (W.raf) { try { cancelAnimationFrame(W.raf); } catch (e) {} W.raf = 0; }
      try { window.removeEventListener("scroll", onScroll, { capture: true }); } catch (e) {}
      try { window.removeEventListener("resize", onResize); } catch (e) {}
      try { document.removeEventListener("click", onClickCap, true); } catch (e) {}
      try { document.removeEventListener("visibilitychange", onVis); } catch (e) {}
      stopTimers();
      S.queue.length = 0;
    }
    applyMode();
  } catch (err) {
    try { const n = document.querySelector(".eclat"); if (n) n.style.display = "none"; } catch (e) {}
  }
}
