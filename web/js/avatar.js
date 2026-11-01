/* avatar.js — LA présence vivante de Nova (vague 2, item 1) : l'avatar aimé d'Ahadi restauré.
   - Base immédiate : l'orbe CSS (orb.js) — jamais un trou à l'écran, même sans WebGL.
   - Mode « panda » (défaut) / « renard » (panda roux) : le compagnon 3D de mascot.js, chargé PARESSEUSEMENT
     (three.js n'arrive qu'à la première activation) et monté par-dessus l'orbe.
   - Mode « singularity » : le Singularity Core (singularity.js), même chargement paresseux ;
     il lit l'état via un shim (ctx.avatar) alimenté ici — aucun panda requis.
   - Mode « orbe » : l'orbe CSS seule.
   Le mode vient de /api/settings (clé avatar_mode), cache localStorage « nova2_avatar » pour
   l'amorçage ; Réglages peut le changer en direct (bus « nova:avatar-mode »).
   États Nova (repos/écoute/réflexion/parole) → états avatar (idle/listening/thinking/speaking) ;
   noteTool()/noteError() posent les états transitoires tool/error du moteur d'origine.
   Niveau audio : MESURÉ par un AnalyserNode sur l'élément <audio> de la coquille (radio, TTS)
   quand il joue réellement ; sinon 0 — aucun niveau inventé, la bouche du panda suit le signal.
   Discipline perf : un seul moteur 3D actif par présence, DPR ≤ 1,5 (dans les moteurs),
   horloge rAF partagée de mascot.js (pause hors écran), boucle bridée pour le Singularity.
   V4-B : visèmes mesurés (readViseme) lus dans la boucle du moteur pendant la parole réelle.
   V5-J : si web/avatars/nova_panda.glb / nova_pandaroux.glb sont livrés et valides → moteur glTF
   (avatar-gltf.js, même contrat) ; sinon mascot.js inchangé. */
import { createOrb } from "./orb.js";
import { reportError } from "./core.js";
import { voiceOutputs } from "./voice.js";

const NOVA2PANDA = { repos: "idle", ecoute: "listening", reflexion: "thinking", parole: "speaking", approval: "approval", done: "done", celebrate: "celebrate", reading: "reading", sleep: "sleep", outil: "tool", erreur: "error" };
const MODES = ["panda", "renard", "singularity", "orbe"];   // 24/10 : « renard » = second compagnon (même cahier des charges que le panda, même moteur mascot.js, personnalité propre)

/* C5 (23/10) — SOURCE D'ÉTAT UNIQUE du panda. Avant : chaque mountAvatar
   gardait son propre `cur` → le rail (shell.js) et le héros (Accueil,
   modules/dots.js) étaient DEUX machines à états indépendantes qui pouvaient
   diverger (constat P-01 du conseil), et noteTool/noteError écrivaient le
   moteur sans passer par `cur` (P-10 : l'orbe CSS et le moteur 3D pouvaient
   raconter deux états différents). Désormais : UN état Nova partagé, écrit
   par setState/noteTool/noteError, appliqué à TOUTES les présences vives ;
   une présence montée plus tard adopte l'état courant. L'état « done »
   repasse seul à « repos » après 2,6 s (le moteur sort de sa pose à 2,4 s) —
   c'est ce retour partagé qui rend l'état « done » atteignable et sûr. */
let sharedState = "repos";
let pubT = 0;   // V6-COMPAGNON : publication regroupée de l'état (voir setSharedState)
const liveWraps = new Set();
let doneReturnT = 0;
function setSharedState(s) {
  const prev = sharedState;
  sharedState = String(s || "repos");
  clearTimeout(doneReturnT);
  if (sharedState === "done") { doneReturnT = setTimeout(() => { if (sharedState === "done") setSharedState("repos"); }, 2600); }
  /* V4-B : célébration MAJEURE (livrable, approbation Fundings…) — 3 s, puis repos */
  if (sharedState === "celebrate") { doneReturnT = setTimeout(() => { if (sharedState === "celebrate") setSharedState("repos"); }, 3300); }
  liveWraps.forEach((w) => { try { w._applyShared(); } catch (e) {} });
  /* PV (23/10) : les transitions d'activité sont PUBLIÉES (le compagnon
     s'en sert pour sa célébration dimensionnelle) — la source reste
     unique, ceci n'est qu'un écho en lecture, émis APRÈS l'application
     aux présences pour que les auditeurs composent sur un état à jour. */
  if (sharedState !== prev) { try { window.dispatchEvent(new CustomEvent("nova:presence-state", { detail: { state: sharedState, prev } })); } catch (e) {} }
  /* V6-COMPAGNON (25/10) : l'état est aussi PUBLIÉ au moteur (POST /api/assistant/state → bus « assistant »)
     pour le compagnon flottant natif (companion.html), autre page : regroupé à 250 ms, dernier état gagnant. */
  if (sharedState !== prev) {
    clearTimeout(pubT);
    pubT = setTimeout(() => { try { fetch("/api/assistant/state", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ state: sharedState }) }).catch(() => {}); } catch (e) {} }, 250);
  }
}

/* PV (23/10) — CANAL HUMEUR PARTAGÉ. Orthogonale à l'activité : un teint,
   pas une pose. Une seule humeur pour toutes les présences (comme l'état
   C5), nourrie par des événements réels (retours d'Ahadi §42, verdicts
   des cartes d'approbation, erreurs) via setSharedMood ; elle décroît
   vers « neutre » au bout de son TTL — retour armé par l'événement,
   jamais décoratif. Les humeurs « grave »/« legere » existent au modèle
   mais n'ont AUCUNE source machine ce soir (la gravité du sujet n'existe
   pas comme donnée dans l'app) : aucun code ne les pose pour l'instant. */
const MOODS = ["neutre", "joie", "attention", "grave", "legere"];
let sharedMood = "neutre";
let moodReturnT = 0;
export function setSharedMood(name, ttlMs) {
  if (!MOODS.includes(name)) return;
  sharedMood = name;
  clearTimeout(moodReturnT);
  if (name !== "neutre" && ttlMs > 0) { moodReturnT = setTimeout(() => { if (sharedMood === name) setSharedMood("neutre", 0); }, ttlMs); }
  liveWraps.forEach((w) => { try { w._applyMood(); } catch (e) {} });
  try { window.dispatchEvent(new CustomEvent("nova:presence-mood", { detail: { mood: sharedMood } })); } catch (e) {}
}
export function getSharedMood() { return sharedMood; }

/* ── Pompe de niveau audio (singleton, partagée par toutes les présences) ── */
const pump = { ctx: null, src: null, an: null, timer: 0, targets: new Set(), failed: false };
function pumpEnsure() {
  if (pump.failed || pump.an) return;
  try {
    const audio = document.getElementById("audio");
    if (!audio) { pump.failed = true; return; }
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) { pump.failed = true; return; }
    pump.ctx = new AC();
    pump.src = pump.ctx.createMediaElementSource(audio);
    pump.an = pump.ctx.createAnalyser(); pump.an.fftSize = 256;
    pump.src.connect(pump.an); pump.an.connect(pump.ctx.destination);
    const buf = new Uint8Array(pump.an.fftSize);
    pump.timer = setInterval(() => {
      try {
        if (audio.paused || !pump.targets.size) return;
        if (pump.ctx.state === "suspended") pump.ctx.resume();
        pump.an.getByteTimeDomainData(buf);
        let sum = 0; for (let i = 0; i < buf.length; i += 4) { const v = (buf[i] - 128) / 128; sum += v * v; }
        const rms = Math.min(1, Math.sqrt(sum / (buf.length / 4)) * 3.2);
        pump.targets.forEach((fn) => { try { fn(rms); } catch (e) {} });
      } catch (e) {}
    }, 120);
  } catch (e) { pump.failed = true; }
}

/* ── V4-B : VISÈMES MESURÉS (3 bandes spectrales) ─────────────────────────
   Source : l'AnalyserNode de SORTIE de la voix (voice.js — voix système en flux), lu par
   getByteFrequencyData à chaque image du moteur 3D (la source est appelée DANS sa boucle rAF :
   aucune boucle de plus) et seulement pendant que la voix joue réellement.
     basses 120–450 Hz      → jawOpen (ouverture de mâchoire)
     médiums 1200–2800 Hz   → lipSpread (I / É)
     basses ≫ médiums       → lipRound (O / OU)
     silence court < 220 ms → lipPress (M / B / P entre les syllabes)
   Chaque bande a son contrôle automatique de gain (pic glissant) : la forme suit le TIMBRE,
   pas le volume. Pas de voix active = null : le moteur retombe sur setLevel (compatibilité). */
const VIS = { fb: null, lin: null, lastT: 0, agc: 0.02, sil: 0, voiced: 0, out: { open: 0, spread: 0, round: 0, press: 0 } };
/* Bande → amplitude LINÉAIRE moyenne (getByteFrequencyData est en dB : on le défait, sinon le
   plancher de bruit écrase les rapports et le silence ne retombe jamais à zéro). */
function visBand(binHz, lo, hi) {
  const lin = VIS.lin, n = lin.length;
  const a = Math.max(1, Math.floor(lo / binHz)), b = Math.min(n - 1, Math.ceil(hi / binHz));
  let s = 0; for (let i = a; i <= b; i++) s += lin[i];
  return s / (b - a + 1);
}
export function readViseme() {
  let src = null;
  try { for (const o of voiceOutputs()) { if (o && o.active && o.active()) { src = o; break; } } } catch (e) {}
  if (!src) { VIS.sil = 0; VIS.lastT = 0; VIS.voiced = 0; return null; }
  const now = performance.now();
  if (VIS.lastT && now - VIS.lastT < 4) return VIS.out;   // plusieurs moteurs dans la même image : une seule lecture
  const dt = VIS.lastT ? Math.min(0.1, (now - VIS.lastT) / 1000) : 1 / 60;
  VIS.lastT = now;
  const an = src.an, n = an.frequencyBinCount;
  if (!VIS.fb || VIS.fb.length !== n) { VIS.fb = new Uint8Array(n); VIS.lin = new Float32Array(n); }
  an.getByteFrequencyData(VIS.fb);
  const lo = an.minDecibels, span = (an.maxDecibels - an.minDecibels) / 255;
  for (let i = 0; i < n; i++) VIS.lin[i] = VIS.fb[i] ? Math.pow(10, (lo + VIS.fb[i] * span) / 20) : 0;
  const binHz = src.ctx.sampleRate / an.fftSize;
  const low = visBand(binHz, 120, 450), lm = visBand(binHz, 450, 1200), mid = visBand(binHz, 1200, 2800);
  const total = low + lm + mid;
  VIS.agc = Math.max(total, VIS.agc * (1 - 0.35 * dt), 0.002);   // gain automatique : la forme suit le timbre, pas le volume
  const en = total / VIS.agc;
  const k = (x) => Math.max(0, Math.min(1, x));
  /* Fermeture bilabiale : une chute brève d'énergie APRÈS une syllabe voisée (< 220 ms) */
  if (en < 0.22) VIS.sil += dt; else { VIS.sil = 0; VIS.voiced = now; }
  const press = VIS.sil > 0.02 && VIS.sil < 0.22 && now - VIS.voiced < 400 ? 1 : 0;
  /* Discriminants (calibrés sur voyelles synthétiques à 2 formants, banc V4-B) :
       q  = médiums-aigus / médiums-bas  → I ≈ 1,0 · É ≈ 0,33 · A ≈ 0,28 · O, OU ≈ 0,1
       lr = basses / médiums-bas        → A ≈ 0,6 (F1 haut) · O ≈ 1,9 · OU ≈ 2,9 · É ≈ 3 · I ≈ 12 */
  const q = mid / (lm + 1e-6), lr = low / (lm + 1e-6);
  VIS.q = q; VIS.lr = lr;
  const voiced = k(en * 2.2 - 0.3);
  const spread = k((q - 0.15) * 3.5) * k((lr - 1.2) * 0.8) * voiced;
  const round = k((0.18 - q) * 10) * k((lr - 1.0) * 1.2) * voiced;
  const t = {
    open: k(en * 1.25 - 0.15) * (1 - 0.5 * spread) * (1 - press),
    spread,
    round,
    press,
  };
  const o = VIS.out;
  for (const key in t) { const a = t[key] > o[key] ? 0.6 : 0.35; o[key] += (t[key] - o[key]) * a; }
  return o;
}

/* V5-J — manifeste des avatars réalistes (écrit par tools/check_glb.py --installer, toujours présent
   dans web/avatars/ : aucune requête 404 quand aucun .glb n'est livré). Lu une fois, mis en cache. */
const GLB_FILES = { panda: "nova_panda.glb", renard: "nova_pandaroux.glb" };
let glbManifestP = null;
/* Interrupteur « Avatar 3D (aperçu) » : un .glb marqué « defaut:false » dans le manifeste (verdict
   APERÇU) n'est chargé QUE si Ahadi l'a choisi — réglage avatar_3d (/api/settings), cache
   localStorage « nova2_avatar_3d », bascule en direct par le bus « nova:avatar-3d » {on}.
   Le compagnon organique mascot.js reste le moteur par défaut. */
let opt3d = null;
function opt3dLocal() { try { return localStorage.getItem("nova2_avatar_3d") === "1"; } catch (e) { return false; } }
export function avatar3dEnabled() { return avatarStyleNow() === "3d"; }
/* V5-K (24/10 nuit) — STYLE D'AVATAR, un seul réglage « avatar_style » :
   « organique » (mascot.js, défaut) · « illustre » (illustrations, avatar-illus.js) ·
   « 3d » (glTF en aperçu, avatar-gltf.js). L'ancien interrupteur avatar_3d=true vaut « 3d ».
   Cache localStorage « nova2_avatar_style » ; bascule en direct par le bus « nova:avatar-style » {style}.
   Tout moteur absent ou en échec retombe sur mascot.js. */
export const AVATAR_STYLES = ["video", "verre", "organique", "illustre", "3d"];   // 30/10 : « verre » = présence en verre liquide temps réel (avatar-glass.js), défaut
let styleNow = null;
export function avatarStyleNow() {
  if (styleNow) return styleNow;
  try { const s = localStorage.getItem("nova2_avatar_style"); if (AVATAR_STYLES.includes(s)) return s; } catch (e) {}
  if (opt3d === true || (opt3d == null && opt3dLocal())) return "3d";
  return "video";   // 30/10 soir : vidéos Veo d'Ahadi (panda / panda roux) ; « verre » en repli : l'avatar illustré (illustrations de [tiers]) devient le défaut — repli organique automatique
}
async function loadStyle(api) {
  /* 30/10 (Ahadi : « de vrais avatars 3D animés ») — bascule UNIQUE vers l'avatar 3D (panda roux, 15 animations, état réel
     de Nova) ; tout choix fait ensuite dans Réglages est respecté. */
  try {
    /* 30/10 matin (Ahadi : « les avatars sont mauvais ») — bascule UNIQUE vers la présence en verre liquide. */
    /* 30/10 soir — bascule UNIQUE vers les compagnons VIDÉO (Veo, fond vert détouré en direct). */
    if (api && !localStorage.getItem("nova2_avatar_mig3010c")) {
      ["nova2_avatar_mig3010c", "nova2_avatar_mig3010b", "nova2_avatar_mig3010"].forEach((k) => localStorage.setItem(k, "1"));
      styleNow = "video"; localStorage.setItem("nova2_avatar_style", "video");
      api.post("/api/settings", { avatar_style: "video" }).catch(() => {});
      return styleNow;
    }
  } catch (e) {}
  if (styleNow || !api) return avatarStyleNow();
  try {
    const j = await api.get("/api/settings"); const st = (j && j.settings) || {};
    if (AVATAR_STYLES.includes(st.avatar_style)) styleNow = st.avatar_style;
    else if (st.avatar_3d === true) styleNow = "3d";
    if (styleNow) { try { localStorage.setItem("nova2_avatar_style", styleNow); } catch (e) {} }
  } catch (e) {}
  return avatarStyleNow();
}
async function gltfDeclared(mode, api) {
  try {
    if (!glbManifestP) glbManifestP = fetch(new URL("../avatars/manifest.json", import.meta.url).href, { cache: "no-cache" }).then((r) => (r.ok ? r.json() : null)).catch(() => null);
    const m = await glbManifestP;
    const e = m && m.avatars && m.avatars[mode];
    if (!(e && e.ok === true && e.fichier === GLB_FILES[mode])) return false;
    if (e.defaut === true) return true;
    return (await loadStyle(api)) === "3d";
  } catch (e) { return false; }
}

/* PHASE 5 (brief Nova 2) — PRÉSENCE 3D OPTIONNELLE : UN objet procédural (presence3d.js, WebGPU → WebGL2)
   qui REMPLACE l'orbe et les autres moteurs tant que le réglage presence_3d est vrai (défaut : faux).
   Réglage serveur presence_3d (/api/settings, lu dans la MÊME réponse qu'avatar_mode : aucune requête
   de plus au démarrage) + cache localStorage « nova2_presence_3d » ; bascule en direct par le bus
   « nova:presence-3d » {on}. Coupé : presence3d.js n'est jamais importé (import() dynamique ci-dessous,
   jamais statique). Activé : importé seulement quand la présence est visible (IntersectionObserver).
   Sans WebGPU ni WebGL2 : l'orbe CSS reste. */
let p3d = null;
function presence3dOn() {
  if (p3d !== null) return p3d;
  try { return localStorage.getItem("nova2_presence_3d") === "1"; } catch (e) { return false; }
}
export function presence3dEnabled() { return presence3dOn(); }
/* Résout quand la présence est à l'écran ET la fenêtre visible (l'un puis l'autre, dans n'importe quel ordre). */
function whenVisible(el, hold) {
  return new Promise((res) => {
    if (typeof IntersectionObserver !== "function") { res(); return; }
    let inter = false;
    const done = () => { if (!inter || document.hidden) return; hold.io.disconnect(); document.removeEventListener("visibilitychange", done); res(); };
    const io = new IntersectionObserver((es) => { inter = es.some((x) => x.isIntersecting); done(); });
    hold.io = { disconnect() { io.disconnect(); document.removeEventListener("visibilitychange", done); } };
    document.addEventListener("visibilitychange", done);
    io.observe(el);
  });
}

let modeCache = null;
export async function avatarMode(api) {
  if (modeCache) return modeCache;
  try { const m = localStorage.getItem("nova2_avatar"); if (m && MODES.includes(m)) modeCache = m; } catch (e) {}
  if (api) {
    try {
      const j = await api.get("/api/settings");
      const m = j && j.settings && j.settings.avatar_mode;
      if (m && MODES.includes(m)) { modeCache = m; try { localStorage.setItem("nova2_avatar", m); } catch (e) {} }
      const p = j && j.settings && j.settings.presence_3d;   // PHASE 5 : même réponse, aucune requête de plus
      if (typeof p === "boolean") { p3d = p; try { localStorage.setItem("nova2_presence_3d", p ? "1" : "0"); } catch (e) {} }
    } catch (e) {}
  }
  return modeCache || "panda";
}

/* Monte la présence dans un élément créé pour l'appelant (à insérer dans le DOM).
   Retourne l'élément lui-même, augmenté : setState(état Nova), setLevel(v), noteTool(),
   noteError(), destroyAvatar(). Compatible avec createChat (classList + setState). */
export function mountAvatar(ctx, { px = 190, orbSize = "lg" } = {}) {
  const { api, bus, h } = ctx;
  const wrap = h("div", { class: "avatar-presence", style: "width:" + px + "px;height:" + px + "px" });
  const orb = createOrb(orbSize);
  orb.style.position = "absolute"; orb.style.left = "50%"; orb.style.top = "50%"; orb.style.transform = "translate(-50%,-50%)";
  const layer = h("div", { class: "avatar-3d", "aria-hidden": "true" });
  wrap.append(orb, layer);

  let dead = false, engine = null, engineKind = "", cur = sharedState, level = 0, mountSeq = 0;
  const shim = { state: "idle", setLevel(v) { level = Math.max(0, Math.min(1, v || 0)); if (engine && engineKind === "panda") engine.setLevel(level); } };
  const levelFan = (v) => { shim.setLevel(v); };
  pump.targets.add(levelFan);

  function applyState() {
    /* l'orbe CSS connaît repos/ecoute/reflexion/parole + les transitoires
       tool/error (noms anglais dans orb.js) : on lui traduit outil/erreur. */
    try { orb.setState(cur === "outil" ? "tool" : cur === "erreur" ? "error" : cur); } catch (e) {}
    try { orb.classList.toggle("state-approval", cur === "approval"); orb.classList.toggle("state-done", cur === "done" || cur === "celebrate"); } catch (e) {}
    const st = NOVA2PANDA[cur] || cur || "idle";
    shim.state = st;
    if (engine && engineKind === "panda") { try { engine.setState(st); } catch (e) {} }
    if (engine && engineKind === "presence") { try { engine.setState(cur); } catch (e) {} }   // PHASE 5 : l'objet lit l'état Nova (français)
    /* le Singularity lit shim.state à chaque image (ctx.avatar) : rien d'autre à faire. */
  }
  wrap._applyShared = () => { cur = sharedState; applyState(); };
  /* PV : l'humeur partagée teinte CETTE présence — moteur mascot.js via
     setMood, repli orbe via data-mood (CSS) — sans toucher à son état. */
  wrap._applyMood = () => {
    try { wrap.dataset.mood = sharedMood; } catch (e) {}
    if (engine && engineKind === "panda") { try { if (engine.setMood) engine.setMood(sharedMood); } catch (e) {} }
  };
  /* PV : état LOCAL d'une présence (le compagnon pose « approval »
     pendant une attente de GO) — pose CE wrap sans écrire l'état
     partagé C5 ; _applyShared() le resynchronise dès que l'activité
     partagée change. */
  wrap.setLocalState = (s) => { if (dead) return; cur = String(s || sharedState); applyState(); };
  wrap.setState = (s) => { if (dead) return; setSharedState(s); };
  wrap.setLevel = (v) => { if (!dead) shim.setLevel(v); };
  /* 24/10 : réaction ponctuelle à un événement réel (arrivée d'un message, salut…). */
  wrap.react = (kind) => { if (!dead && engine && engineKind === "panda" && engine.react) { try { engine.react(kind); } catch (e) {} } };
  /* V4-B : regard dirigé vers une cible réelle de l'écran (carte d'approbation, texte lu) —
     x, y dans [-1, 1] relatifs au compagnon ; null relâche la cible (retour au curseur). */
  wrap.setFocus = (x, y) => { if (!dead && engine && engineKind === "panda" && engine.setFocus) { try { engine.setFocus(x, y); } catch (e) {} } };
  wrap.species = () => (engine && engine.species) || "";
  /* P-10 fermé : outil/erreur passent par la MÊME source que les autres
     états (cur, orbe CSS, shim et moteur restent d'accord par construction). */
  wrap.noteTool = () => { if (dead) return; setSharedState("outil"); };
  wrap.noteError = () => { if (dead) return; setSharedState("erreur"); };

  /* PHASE 5 : l'objet 3D, quand le réglage est actif — chargé à la demande, une fois la présence visible. */
  const visHold = { io: null };
  async function mountPresence3d() {
    const seq = ++mountSeq;
    await whenVisible(wrap, visHold);
    if (dead || seq !== mountSeq || engine || !presence3dOn()) return;
    let eng = null;
    try {
      const m = await import("./presence3d.js");
      eng = await m.createPresence3D(layer, { px, onLost: () => { if (!dead && engineKind === "presence") { unmountEngine(); } } });
    } catch (e) { eng = null; reportError(e, "présence 3D — repli sur l'orbe CSS"); }
    if (eng && (dead || seq !== mountSeq || engine)) { try { eng.destroy(); } catch (e) {} return; }
    if (!eng) return;   // ni WebGPU ni WebGL2 : l'orbe CSS reste
    engine = eng; engineKind = "presence";
    try { engine.setState(cur); } catch (e) {}
    orb.style.opacity = "0"; layer.classList.add("on");
    try { wrap.dispatchEvent(new CustomEvent("nova:avatar-ready", { bubbles: true })); } catch (e) {}
  }

  async function mountEngine(mode) {
    if (dead || engine) return;
    if (presence3dOn()) { await mountPresence3d(); return; }   // un seul objet : l'objet 3D remplace orbe et moteurs
    if (mode === "orbe") return;
    try {
      if (mode === "panda" || mode === "renard") {
        /* V5-J : avatar 3D RÉALISTE (.glb de web/avatars/) s'il est déclaré valide par le manifeste
           (tools/check_glb.py --installer) ET s'il passe la validation à l'exécution ; sinon le
           compagnon procédural mascot.js, inchangé. avatar-gltf.js n'est importé que si un .glb existe. */
        const seq = ++mountSeq;
        let eng = null;
        const style = await loadStyle(api);
        if (dead || seq !== mountSeq || engine) return;
        if (style === "video") {
          try { const vm = await import("./avatar-video.js"); eng = await vm.createVideoAvatar(layer, { species: mode }); } catch (e) { eng = null; }
          if (eng && (dead || seq !== mountSeq || engine)) { try { eng.destroy(); } catch (e) {} return; }
          if (eng) orb.style.opacity = "0";
        }
        if (!eng && (style === "verre" || style === "video")) {
          try { const gm = await import("./avatar-glass.js"); eng = gm.createGlassAvatar(layer); } catch (e) { eng = null; }
          if (eng && (dead || seq !== mountSeq || engine)) { try { eng.destroy(); } catch (e) {} return; }
          if (!eng) return;   // sans WebGL : l'orbe CSS reste, jamais le panda
          orb.style.opacity = "0";
        }
        if (!eng && style === "illustre") {
          try {
            const il = await import("./avatar-illus.js");
            const fn = il.createIllusAvatar || il.createAvatar || il.loadAvatar;
            eng = fn ? await fn(layer, { species: mode }) : null;
          } catch (e) { eng = null; }
          if (eng && (dead || seq !== mountSeq || engine)) { try { eng.destroy(); } catch (e) {} return; }
        }
        if (!eng && style === "3d" && await gltfDeclared(mode, api)) {
          try { const g = await import("./avatar-gltf.js"); eng = await g.loadAvatar(layer, { species: mode }); } catch (e) { eng = null; }
          if (eng && (dead || seq !== mountSeq || engine)) { try { eng.destroy(); } catch (e) {} return; }
        }
        if (dead || seq !== mountSeq || engine) return;
        if (!eng) {
          const m = await import("./mascot.js");   // 24/10 nuit : compagnon v3 (chibi 3D flottant) — panda / panda roux
          if (dead || seq !== mountSeq || engine) return;
          eng = m.createAvatar(layer, { species: mode });
        }
        engine = eng;
        if (engine) { engineKind = "panda"; engine.setState(shim.state); engine.setLevel(level); if (engine.setVisemeSource) engine.setVisemeSource(readViseme); try { wrap._applyMood(); } catch (e) {} layer.classList.add("on"); try { wrap.dispatchEvent(new CustomEvent("nova:avatar-ready", { bubbles: true })); } catch (e) {} }
      } else if (mode === "singularity") {
        const m = await import("./singularity.js");
        if (dead) return;
        engine = m.mountSingularity(layer, { avatar: shim, A: null, st: { dots: [] } });
        if (engine) { engineKind = "singularity"; layer.classList.add("on"); try { wrap.dispatchEvent(new CustomEvent("nova:avatar-ready", { bubbles: true })); } catch (e) {} }
      }
    } catch (e) { engine = null; reportError(e, "avatar 3D — repli sur l'orbe CSS"); }
  }
  function unmountEngine() {
    mountSeq++;
    try { if (visHold.io) visHold.io.disconnect(); } catch (e) {} visHold.io = null;
    if (engine) { try { engine.destroy(); } catch (e) {} engine = null; engineKind = ""; }
    layer.classList.remove("on"); layer.replaceChildren(); orb.style.opacity = "";
  }
  avatarMode(api).then((m) => { if (!dead) mountEngine(m); });
  pumpEnsure();

  /* Satellites dorés du Singularity : nombre de Dots réellement en cours (source moteur). */
  let dotsTimer = setInterval(async () => {
    if (document.hidden || engineKind !== "singularity") return;   // 25/10 (recette V5-N) : seuls les satellites du Singularity s'en servent
    try { const j = await api.get("/api/dots/active"); const n = (j && (j.count ?? (Array.isArray(j.items) ? j.items.length : 0))) || 0; window.__novaActiveDots = n; } catch (e) {}
  }, 30000);
  api.get("/api/dots/active").then((j) => { const n = (j && (j.count ?? (Array.isArray(j.items) ? j.items.length : 0))) || 0; window.__novaActiveDots = n; }).catch(() => {});

  const offMode = bus.on("nova:avatar-mode", (m) => {
    if (dead || !m || !MODES.includes(m.mode)) return;
    modeCache = m.mode; try { localStorage.setItem("nova2_avatar", m.mode); } catch (e) {}
    unmountEngine(); mountEngine(m.mode);   // mountEngine gère « orbe » (et la présence 3D si active)
  });
  const offP3d = bus.on("nova:presence-3d", (m) => {
    if (dead || !m) return;
    p3d = !!m.on; try { localStorage.setItem("nova2_presence_3d", p3d ? "1" : "0"); } catch (e) {}
    unmountEngine(); mountEngine(modeCache || "panda");
  });
  const off3d = bus.on("nova:avatar-3d", (m) => {
    if (dead || !m) return;
    opt3d = !!m.on; try { localStorage.setItem("nova2_avatar_3d", opt3d ? "1" : "0"); } catch (e) {}
    styleNow = opt3d ? "3d" : "organique"; try { localStorage.setItem("nova2_avatar_style", styleNow); } catch (e) {}
    if (engineKind === "panda") { unmountEngine(); mountEngine(modeCache || "panda"); }
  });
  const offStyle = bus.on("nova:avatar-style", (m) => {
    if (dead || !m || !AVATAR_STYLES.includes(m.style)) return;
    styleNow = m.style; try { localStorage.setItem("nova2_avatar_style", styleNow); } catch (e) {}
    if (engineKind === "panda" || !engine) { unmountEngine(); mountEngine(modeCache || "panda"); }
  });
  const offSgFail = (e) => { if (!dead && engineKind === "singularity") { unmountEngine(); mountEngine("panda"); } };
  addEventListener("nova:sgfail", offSgFail);

  wrap.destroyAvatar = () => {
    dead = true; liveWraps.delete(wrap); clearInterval(dotsTimer);
    pump.targets.delete(levelFan);
    try { offMode(); } catch (e) {}
    try { off3d(); } catch (e) {}
    try { offStyle(); } catch (e) {}
    try { offP3d(); } catch (e) {}
    removeEventListener("nova:sgfail", offSgFail);
    unmountEngine();
  };
  liveWraps.add(wrap);
  applyState();
  wrap._applyMood();
  return wrap;
}

/* 24/10 — réaction partagée : toutes les présences vives réagissent au même événement réel
   (arrivée d'un message du fil, salut). Point d'entrée unique : reactAll() ou l'événement
   window « nova:presence-react » { kind }. */
export function reactAll(kind) { liveWraps.forEach((w) => { try { if (w.react) w.react(kind); } catch (e) {} }); }
try { window.addEventListener("nova:presence-react", (e) => reactAll(e && e.detail && e.detail.kind)); } catch (e) {}
