/* companion-float.js — V6-COMPAGNON (25/10) : le compagnon flottant natif (companion.html, chargé par
   NovaCompanion.swift dans un panneau non activant au-dessus des apps). Avatar illustré (avatar-illus.js,
   même espèce que l'app : localStorage « nova2_avatar »), vivant au repos (respiration CSS, clignement
   du manifeste, regard qui se promène, petite inclinaison de tête de temps en temps) et qui RÉAGIT à
   l'état réel publié sur le flux /api/events :
     · « assistant » {state} — écho de la présence de la fenêtre principale (avatar.js › setSharedState)
     · « voix_live » {etat, niveau} — Nova Live : écoute / réfléchit / parle (bouche au niveau mesuré)
     · « voix_dictee » {etat} — dictée en cours
     · « confirm » {id, resolved} — une carte d'approbation attend ton GO (pastille GO + frétillement)
   Sommeil seulement la nuit (heures calmes des Réglages) et après 10 min sans activité.
   Gestes : clic = panneau compact (Demander à Nova, ⌃⌥Espace) ; double-clic = fenêtre Nova ;
   clic droit = menu natif (Masquer, Ouvrir Nova, Parler (Live)) ; glisser = déplacer (calcul natif). */
import { bus } from "./core.js";
import { createVoiceLive } from "./voice.js";

const root = document.getElementById("cf");
const avHost = document.getElementById("cf-av");
const goEl = document.getElementById("cf-go");
const stEl = document.getElementById("cf-st");
const post = (o) => { try { window.webkit.messageHandlers.nova.postMessage(o); return true; } catch (e) { return false; } };
const reduced = () => { try { return matchMedia("(prefers-reduced-motion: reduce)").matches; } catch (e) { return false; } };

let eng = null, state = "idle", lastAct = Date.now();
let live = null;   // client Live de cette page (menu « Parler (Live) » ou mot de réveil)
const LABEL = { idle: "au repos", listening: "t'écoute", thinking: "réfléchit", tool: "agit", speaking: "parle", done: "a fini", celebrate: "a fini", approval: "attend ton GO", sleep: "dort", error: "souci" };
const MAP = { repos: "idle", ecoute: "listening", reflexion: "thinking", parole: "speaking", outil: "tool", tool: "tool", done: "done", celebrate: "celebrate", approval: "approval", erreur: "error", error: "error", reading: "tool", off: "idle", transcription: "thinking" };
let doneT = 0;
function setState(raw, label) {
  const s = MAP[raw] || (LABEL[raw] ? raw : "idle");
  lastAct = Date.now();
  clearTimeout(doneT);
  if (s === "done" || s === "celebrate") {
    root.classList.remove("pop"); void root.offsetWidth; root.classList.add("pop");
    doneT = setTimeout(() => setState("idle"), 2600);
  }
  state = s;
  root.dataset.state = s;
  stEl.textContent = label || LABEL[s] || "";
  root.title = "Nova · " + (label || LABEL[s] || "");
  if (eng) { try { eng.setState(s); } catch (e) {} }
}

/* GO : cartes d'approbation en attente (événements confirm du moteur) */
const pending = new Set();
function paintGo() {
  const n = pending.size;
  goEl.hidden = !n;
  goEl.textContent = n > 1 ? "GO " + n : "GO";
  root.classList.toggle("go", !!n);
  if (n) setState("approval", n > 1 ? n + " GO attendus" : "attend ton GO");
  else if (state === "approval") setState("idle");
}

async function boot() {
  let sp = "panda";
  try { const m = localStorage.getItem("nova2_avatar"); if (m === "renard") sp = "renard"; } catch (e) {}
  // 25/10 : style du compagnon — « illus » (illustration détourée, sans cercle) ou « 3d » (corps entier animé, 15 clips)
  let style = "verre";   /* 30/10 : présence en verre liquide par défaut ; « full » / « illus » = illustrations, « 3d » = modèle 3D */
  try {
    if (!localStorage.getItem("nova2_comp_mig3010c")) { ["nova2_comp_mig3010c", "nova2_comp_mig3010b"].forEach((k) => localStorage.setItem(k, "1")); localStorage.setItem("nova2_comp_style", "video"); }   // 30/10 soir : vidéos Veo
    const v = localStorage.getItem("nova2_comp_style"); if (v === "3d" || v === "illus" || v === "full" || v === "video" || v === "verre") style = v;
  } catch (e) {}
  document.body.dataset.style = style;
  if (style === "video") {
    try { const vm = await import("./avatar-video.js"); eng = await vm.createVideoAvatar(avHost, { species: sp }); } catch (e) { eng = null; }
    if (!eng) { style = "verre"; document.body.dataset.style = style; }
  }
  if (style === "verre") {
    try { const gm = await import("./avatar-glass.js"); eng = gm.createGlassAvatar(avHost); } catch (e) { eng = null; }
    if (!eng) { style = "full"; document.body.dataset.style = style; }
  }
  if (style === "3d") {
    try { const g = await import("./avatar-gltf.js"); eng = await g.loadAvatar(avHost, { species: sp }); } catch (e) { eng = null; }
    if (!eng) { style = "illus"; document.body.dataset.style = style; }
  }
  if (!eng) {
    try {
      const il = await import("./avatar-illus.js");
      eng = await il.createIllusAvatar(avHost, { species: sp, set: style === "full" ? "full" : "" });
    } catch (e) { eng = null; }
  }
  if (eng) eng.setState(state);
}
boot();

bus.on("assistant", (d) => { if (d && d.state) setState(String(d.state), d.label || ""); });
bus.on("voix_dictee", (d) => { if (!d) return; if (d.etat === "ecoute") setState("listening", "t'écoute (dictée)"); else if (d.etat === "transcription") setState("thinking", "transcrit"); });
/* 25/10 : LIP-SYNC — niveaux reçus du moteur (Live « voix_live.niveau » ~12/s ; lecture TTS de la fenêtre
   principale « voix_niveau » ~9/s), lissés par une enveloppe attaque rapide / relâche douce et rejoués à
   ~30 i/s vers eng.setLevel → image de bouche (avatar-illus : > 0,5 vis_A ; > 0,28 vis_E/vis_O ;
   ≤ 0,12 vis_MBP fermée). Plus rien depuis 260 ms → bouche fermée. prefers-reduced-motion : aucune
   interpolation, 4 mises à jour/s au plus, ouverture plafonnée (pas de vis_A). */
let lipTarget = 0, lipCur = 0, lipAt = 0, lipRaf = 0, lipPush = 0;
function lipFeed(v) {
  lipTarget = Math.max(0, Math.min(1, +v || 0));
  lipAt = performance.now();
  if (!lipRaf) lipRaf = requestAnimationFrame(lipTick);
}
function lipSet(v) { if (eng) { try { eng.setLevel(v); } catch (e) {} } }
function lipTick(now) {
  lipRaf = 0;
  if (!eng) return;
  const silent = now - lipAt > 260;
  const target = silent ? 0 : lipTarget;
  if (reduced()) {
    if (now - lipPush >= 250) { lipPush = now; lipCur = Math.min(target, 0.4); lipSet(lipCur); }
  } else {
    lipCur += (target - lipCur) * (target > lipCur ? 0.55 : 0.22);
    if (now - lipPush >= 33) { lipPush = now; lipSet(lipCur < 0.05 ? 0 : lipCur); }
  }
  if (!silent || lipCur > 0.02) lipRaf = requestAnimationFrame(lipTick);
  else { lipCur = 0; lipSet(0); }
}
let ttsSpeakT = 0;
bus.on("voix_live", (d) => {
  if (!d) return;
  if (d.etat) setState(d.etat === "off" ? "idle" : d.etat, d.label || "");
  if (d.etat === "off" && live && live.actif()) { live.stop().catch(() => {}); }   // session close ailleurs : client local remis à zéro
  if (d.etat === "off" || d.etat === "ecoute" || d.etat === "reflexion") lipFeed(0);
  if (typeof d.niveau === "number") lipFeed(d.niveau);
});
/* Parole TTS de la fenêtre principale : la bouche suit, l'état « parle » tient tant que le son arrive. */
bus.on("voix_niveau", (d) => {
  if (!d || typeof d.niveau !== "number") return;
  lipFeed(d.niveau);
  if (d.niveau > 0.08 && (state === "idle" || state === "sleep" || state === "done")) setState("speaking");
  clearTimeout(ttsSpeakT);
  ttsSpeakT = setTimeout(() => { if (state === "speaking") setState("idle"); }, 1200);
});
/* 25/10 : mot de réveil — « Nova » entendu : le moteur lance le Live ; ce compagnon s'y rattache
   (missions de voice.js › runMission), comme son entrée de menu « Parler (Live) ». */
bus.on("wake", () => { setState("listening", "« Nova » entendu"); });
bus.on("wake_live", (d) => {
  if (!d) return;
  if (!d.ok) { setState("error", String(d.erreur || "Live refusé").slice(0, 60)); return; }
  if (!live) live = createVoiceLive({});
  if (!live.actif()) live.start().catch((e) => setState("error", String((e && e.message) || e).slice(0, 60)));
});
bus.on("confirm", (d) => {
  if (!d || !d.id) return;
  if (d.resolved) pending.delete(String(d.id)); else pending.add(String(d.id));
  paintGo();
  if (d.resolved && d.ok && eng) { try { eng.react("validate"); } catch (e) {} }
});

/* Vie au repos : regard qui se promène, inclinaison de tête ; garde éveillé le jour, dort la nuit. */
let quiet = { from: "22:00", to: "07:00" };
fetch("/api/settings").then((r) => r.json()).then((j) => { const s = (j && j.settings) || j || {}; if (s.quiet_from) quiet = { from: String(s.quiet_from), to: String(s.quiet_to || "07:00") }; }).catch(() => {});
const mins = (t) => { const m = /^(\d{1,2}):(\d{2})/.exec(t || ""); return m ? (+m[1]) * 60 + (+m[2]) : -1; };
function isQuiet() {
  const d = new Date(), n = d.getHours() * 60 + d.getMinutes(), a = mins(quiet.from), b = mins(quiet.to);
  if (a < 0 || b < 0) return false;
  return a <= b ? (n >= a && n < b) : (n >= a || n < b);
}
function lifeTick() {
  const calm = state === "idle" || state === "sleep";
  if (calm && isQuiet() && Date.now() - lastAct > 600000) { if (state !== "sleep") { state = "sleep"; root.dataset.state = "sleep"; stEl.textContent = LABEL.sleep; if (eng) eng.setState("sleep"); } }
  else if (state === "idle" && eng) {
    eng.setState("idle");   // garde éveillé (le moteur illustré s'endort seul après 4 min sans curseur)
    if (!reduced()) {
      eng.lookAt((Math.random() * 2 - 1) * 0.7, (Math.random() * 2 - 1) * 0.4);
      const r = Math.random();
      if (r < 0.3) { const b = root.querySelector(".cf-bob"); b.classList.remove("tilt"); void b.offsetWidth; b.classList.add("tilt"); }
      else if (r < 0.42) { try { eng.react(Math.random() < 0.5 ? "nod" : "wave"); } catch (e) {} }   // petit geste spontané
      else if (r < 0.5) { const b = root.querySelector(".cf-bob"); b.classList.remove("hop"); void b.offsetWidth; b.classList.add("hop"); }
    }
  }
  setTimeout(lifeTick, 4000 + Math.random() * 5000);
}
setTimeout(lifeTick, 3000);

/* Gestes : glisser (natif), clic, double-clic, clic droit. */
let down = null, moved = false, clickT = 0;
root.addEventListener("pointerdown", (e) => {
  if (e.button !== 0) return;
  down = { x: e.screenX, y: e.screenY }; moved = false;
  post({ cmd: "compDragStart" });
  try { root.setPointerCapture(e.pointerId); } catch (er) {}
});
root.addEventListener("pointermove", (e) => {
  if (!down) return;
  if (!moved && Math.abs(e.screenX - down.x) + Math.abs(e.screenY - down.y) > 3) moved = true;
  if (moved) post({ cmd: "compDrag" });
});
root.addEventListener("pointerup", () => {
  if (!down) return;
  const wasDrag = moved; down = null;
  if (wasDrag) { post({ cmd: "compDragEnd" }); return; }
  if (clickT) { clearTimeout(clickT); clickT = 0; post({ cmd: "openMain" }); return; }
  clickT = setTimeout(() => { clickT = 0; post({ cmd: "compClick" }); }, 260);
});
root.addEventListener("contextmenu", (e) => { e.preventDefault(); post({ cmd: "compMenu" }); });

/* « Parler (Live) » du menu natif : session Live tenue par CETTE page (missions : voice.js › runMission). */
window.NovaCompanion = {
  async toggleLive() {
    if (!live) live = createVoiceLive({});
    try { if (live.actif()) await live.stop(); else await live.start(); }
    catch (e) { setState("error", String((e && e.message) || e).slice(0, 60)); }
  },
  setState,
  toggleStyle() {
    const order = ["full", "illus", "3d"];   /* corps entier → portrait → 3D → corps entier */
    let cur = "full";
    try { const v = localStorage.getItem("nova2_comp_style"); if (order.indexOf(v) >= 0) cur = v; } catch (e) {}
    const next = order[(order.indexOf(cur) + 1) % order.length];
    try { localStorage.setItem("nova2_comp_style", next); } catch (e) {}
    location.reload();
  },
};
