// avatar-gltf.js — V5-J : moteur des compagnons 3D RÉALISTES (fichiers .glb livrés par un artiste/[tiers]).
// Même contrat que mascot.js (moteur procédural, qui reste le repli) :
//   createAvatar(host, { species, gltf, preserve }) → { setState, setMood, setLevel, setViseme,
//   setVisemeSource, lookAt, setFocus, react, setTheme, state, species, snapshot, destroy }
//   loadAvatar(host, { species }) → Promise<moteur | null>  (null = fichier absent/invalide → mascot.js)
// Spécification suivie : conseil_24-10/CAHIER_AVATAR_3D_REALISTE.md (squelette root→…→head, 52 blendshapes
// ARKit + vis_A/E/I/O/U/MBP/FV + earPerk/Droop + smileDuchenne, clips nommés, accessoires acc_*,
// Y vers le haut, face +Z, hauteur ≈ 1).
// Tolérance : un blendshape, un os ou un clip absent = repli doux (os de mâchoire, pose procédurale,
// paupières par échelle d'os…), jamais d'exception vers l'appelant. Une seule boucle rAF (partagée par
// toutes les instances glTF), pause hors écran / onglet caché, destroy() libère tout (GPU compris).

import * as THREE from "../vendor/three.module.js";
import { GLTFLoader } from "../vendor/GLTFLoader.js";
import { RoomEnvironment } from "../vendor/RoomEnvironment.js";

/* ---------- 0. Spécification (noms EXACTS du cahier) ---------- */
export const BONES = ["root", "hips", "spine", "chest", "neck", "head", "jaw", "eye_L", "eye_R", "ear_L", "ear_R",
  "shoulder_L", "upperArm_L", "foreArm_L", "hand_L", "shoulder_R", "upperArm_R", "foreArm_R", "hand_R",
  "upLeg_L", "leg_L", "foot_L", "upLeg_R", "leg_R", "foot_R"];
export const HARD_BONES = ["head"];   // sans tête, aucun regard ni parole possible : refus → mascot.js
export const ARKIT52 = ["eyeBlinkLeft", "eyeLookDownLeft", "eyeLookInLeft", "eyeLookOutLeft", "eyeLookUpLeft", "eyeSquintLeft", "eyeWideLeft",
  "eyeBlinkRight", "eyeLookDownRight", "eyeLookInRight", "eyeLookOutRight", "eyeLookUpRight", "eyeSquintRight", "eyeWideRight",
  "jawForward", "jawLeft", "jawRight", "jawOpen", "mouthClose", "mouthFunnel", "mouthPucker", "mouthLeft", "mouthRight",
  "mouthSmileLeft", "mouthSmileRight", "mouthFrownLeft", "mouthFrownRight", "mouthDimpleLeft", "mouthDimpleRight",
  "mouthStretchLeft", "mouthStretchRight", "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper",
  "mouthPressLeft", "mouthPressRight", "mouthLowerDownLeft", "mouthLowerDownRight", "mouthUpperUpLeft", "mouthUpperUpRight",
  "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight", "cheekPuff", "cheekSquintLeft",
  "cheekSquintRight", "noseSneerLeft", "noseSneerRight", "tongueOut"];
export const EXTRA_MORPHS = ["vis_A", "vis_E", "vis_I", "vis_O", "vis_U", "vis_MBP", "vis_FV", "smileDuchenne"];
export const EAR_MORPHS = ["earPerk_L", "earPerk_R", "earDroop_L", "earDroop_R"];
export const CLIPS = ["idle", "listening", "thinking", "typing", "talk_gesture_A", "talk_gesture_B", "approval", "nod", "wink",
  "celebrate_small", "celebrate_big", "error_resolve", "reading", "sleep"];
export const CLIPS_RED = ["arrive_tail"];
export const ACCESSORIES = ["acc_headset", "acc_laptop", "acc_glasses"];
export const FILES = { panda: "nova_panda.glb", renard: "nova_pandaroux.glb" };
const MAX_BYTES = 24 * 1024 * 1024;
/* La bouche est pilotée EN DIRECT par la voix : même si un clip anime ces poids (fichiers [tiers] du
   24/10 : tous les clips animent les 64 blendshapes de Nova_Body), le moteur les impose. */
const MOUTH_RE = /^(jaw|mouth|vis_|tongue|cheekPuff)/;
/* Os de rattachement des accessoires (cahier §6) */
const ACC_BONE = { acc_headset: ["head"], acc_glasses: ["head"], acc_laptop: ["hand_L", "hand_R"] };
/* Mesures (banc, Réglages > diagnostic) : images rendues et coût moyen update+rendu */
export const gltfStats = { frames: 0, ms: 0, last: 0 };   // garde-fou (le cahier vise ≤ 6 Mo ; check_glb.py le signale)

const isRed = (s) => s === "renard" || s === "panda-roux" || s === "red" || s === "pandaroux" || s === 1;
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const lerp = (a, b, t) => a + (b - a) * t;
const rnd = (a, b) => a + Math.random() * (b - a);
const expo = (m) => -Math.log(1 - Math.random()) * m;
const damp = (c, t, rate, dt) => c + (t - c) * (1 - Math.exp(-rate * dt));
const sstep = (a, b, x) => { const t = clamp((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); };
const bell = (p) => (p <= 0 || p >= 1 ? 0 : Math.sin(Math.PI * p));
const n1 = (() => {
  const P = new Float32Array(512);
  for (let i = 0; i < 512; i++) P[i] = ((Math.sin(i * 127.1 + 311.7) * 43758.5453) % 1) * 2 - 1;
  return (t) => { const i = Math.floor(t), f = t - i, u = f * f * (3 - 2 * f); return lerp(P[i & 511], P[(i + 1) & 511], u); };
})();

/* Personnalités (Bloc 2 §3 du cahier d'instructions du 24/10 — mêmes intentions que mascot.js SPECIES) :
   panda géant calme et amorti (zeta = 0.85) · panda roux vif (zeta = 0.65, micro-vie ×1,35 = life). */
const PERSO = {
  panda: { zeta: 0.85, fade: 0.45, life: 1.0, breath: 0.22, tScale: 1.0, gazeRate: 9, headRate: 5.5, poseRate: 4.2, ear: 0.8 },
  red: { zeta: 0.65, fade: 0.28, life: 1.35, breath: 0.27, tScale: 1.08, gazeRate: 14, headRate: 8.5, poseRate: 6.5, ear: 1.25 },
};

/* 11 états (mêmes noms que mascot.js). clip = clip glTF de base ; once = clip joué une fois à l'entrée ;
   acc = accessoire affiché ; le reste = pose faciale/corporelle (repli procédural si le clip manque). */
const STATES = {
  idle: { clip: "idle", smile: 0.45 },
  listening: { clip: "listening", acc: "acc_headset", smile: 0.62, perk: 0.88, brow: [0.25, 0.25], lean: 0.07, roll: 0.12, pitch: -0.02, wide: 0.08 },
  thinking: { clip: "thinking", smile: 0.25, brow: [-0.42, 0.78], yaw: 0.10, pitch: -0.10, roll: -0.10, gy: 0.62, gx: 0.25, lid: 0.08 },
  tool: { clip: "typing", acc: "acc_laptop", smile: 0.5, brow: [-0.15, -0.15], pitch: 0.20, lean: 0.05, gy: -0.72, lid: 0.14 },
  speaking: { clip: "idle", smile: 0.62, brow: [0.22, 0.22], wide: 0.04 },
  approval: { clip: "approval", smile: 0.66, perk: 0.55, brow: [0.62, 0.62], roll: 0.10, pitch: -0.06, turn: 0.26, wide: 0.12 },
  done: { clip: "idle", once: "celebrate_small", smile: 1.0, jaw: 0.42, perk: 1.0, brow: [0.6, 0.6], pitch: -0.11, hop: 1 },
  celebrate: { clip: "idle", once: "celebrate_big", smile: 1.1, jaw: 0.55, perk: 1.0, brow: [0.7, 0.7], pitch: -0.13, hop: 2, spin: 1 },
  error: { clip: "idle", once: "error_resolve", smile: 0.12, press: 0.55, perk: 0.55, brow: [-0.55, -0.55], lean: -0.05, pitch: -0.03 },
  reading: { clip: "reading", acc: "acc_glasses", smile: 0.5, brow: [0.12, 0.12], pitch: 0.10, roll: 0.04, gy: -0.25, lid: 0.06, scan: 1 },
  sleep: { clip: "sleep", smile: 0.48, pitch: 0.22, roll: 0.15, perk: -0.55, lid: 1.0, breathK: 0.6 },
};
const MOODS = {
  joie: { smile: 0.3, perk: 0.38, brow: 0.2, life: 1.25 },
  attention: { smile: -0.2, perk: 0.32, brow: -0.15, life: 0.65 },
  grave: { smile: -0.28, perk: -0.25, brow: -0.2, life: 0.5, lid: 0.12 },
  legere: { smile: 0.2, perk: 0.18, brow: 0.09, life: 1.35 },
  neutre: { smile: 0, perk: 0, brow: 0, life: 1.0 },
};

/* ---------- 1. Disponibilité : manifeste écrit par tools/check_glb.py --installer ---------- */
let manifestP = null;
export function readManifest() {
  if (!manifestP) {
    manifestP = fetch(new URL("../avatars/manifest.json", import.meta.url).href, { cache: "no-cache" })
      .then((r) => (r.ok ? r.json() : null))
      .catch(() => null);
  }
  return manifestP;
}
export async function gltfAvailable(species) {
  try {
    const m = await readManifest();
    const key = isRed(species) ? "renard" : "panda";
    const e = m && m.avatars && m.avatars[key];
    return !!(e && e.ok === true && e.fichier === FILES[key]);
  } catch (e) { return false; }
}

/* ---------- 2. Chargement (cache d'octets par fichier ; un parse par instance) ---------- */
const bytesCache = new Map();
function fetchBytes(url) {
  if (!bytesCache.has(url)) {
    const p = fetch(url, { cache: "no-cache" })
      .then((r) => (r.ok ? r.arrayBuffer() : null))
      .then((b) => (b && b.byteLength > 20 && b.byteLength <= MAX_BYTES ? b : null))
      .catch(() => null);
    bytesCache.set(url, p);
    p.then((b) => { if (!b) bytesCache.delete(url); });
  }
  return bytesCache.get(url);
}
/* Lit le bloc JSON du .glb (sans rien décoder) pour savoir quels décodeurs charger — ils ne sont
   importés QUE si le fichier les exige (Draco / Meshopt / KTX2), tous locaux dans web/vendor/. */
export function peekGlbJson(buf) {
  try {
    const dv = new DataView(buf);
    if (dv.getUint32(0, true) !== 0x46546c67 || dv.getUint32(4, true) !== 2) return null;
    const len = dv.getUint32(12, true);
    if (dv.getUint32(16, true) !== 0x4e4f534a || 20 + len > buf.byteLength) return null;
    return JSON.parse(new TextDecoder().decode(new Uint8Array(buf, 20, len)));
  } catch (e) { return null; }
}
async function parseGlb(buf, renderer) {
  const json = peekGlbJson(buf);
  if (!json) return null;
  const used = new Set([...(json.extensionsUsed || []), ...(json.extensionsRequired || [])]);
  const loader = new GLTFLoader();
  const disposers = [];
  if (used.has("KHR_draco_mesh_compression")) {
    const { DRACOLoader } = await import("../vendor/DRACOLoader.js");
    const d = new DRACOLoader();
    d.setDecoderPath(new URL("../vendor/draco/", import.meta.url).href);
    d.setDecoderConfig({ type: "wasm" });
    loader.setDRACOLoader(d);
    disposers.push(() => d.dispose());
  }
  if (used.has("EXT_meshopt_compression")) {
    const { MeshoptDecoder } = await import("../vendor/meshopt_decoder.module.js");
    loader.setMeshoptDecoder(MeshoptDecoder);
  }
  if (used.has("KHR_texture_basisu")) {
    const { KTX2Loader } = await import("../vendor/KTX2Loader.js");
    const k = new KTX2Loader();
    k.setTranscoderPath(new URL("../vendor/basis/", import.meta.url).href);
    k.detectSupport(renderer);
    loader.setKTX2Loader(k);
    disposers.push(() => k.dispose());
  }
  try {
    return await new Promise((res, rej) => loader.parse(buf, new URL("../avatars/", import.meta.url).href, res, rej));
  } finally {
    disposers.forEach((f) => { try { f(); } catch (e) {} });
  }
}

/* ---------- 3. Inventaire / validation à l'exécution (miroir de tools/check_glb.py) ---------- */
export function inspectGltf(gltf, species) {
  const red = isRed(species);
  const nodes = {};
  const morphs = new Set();
  let meshes = 0, tris = 0;
  if (gltf && gltf.scene) {
    gltf.scene.traverse((o) => {
      if (o.name && (!nodes[o.name] || (o.isBone && !nodes[o.name].isBone))) nodes[o.name] = o;
      if (o.isMesh) {
        meshes++;
        const g = o.geometry;
        if (g) tris += g.index ? g.index.count / 3 : (g.attributes.position ? g.attributes.position.count / 3 : 0);
        if (o.morphTargetDictionary) Object.keys(o.morphTargetDictionary).forEach((k) => morphs.add(k));
      }
    });
  }
  const clipNames = ((gltf && gltf.animations) || []).map((c) => c.name);
  const tails = [];
  for (let i = 1; i <= 7; i++) { const n = "tail_0" + i; if (nodes[n]) tails.push(n); }
  const needClips = red ? CLIPS.concat(CLIPS_RED) : CLIPS;
  const earBones = !!(nodes.ear_L && nodes.ear_R);
  const needMorphs = ARKIT52.concat(EXTRA_MORPHS, earBones ? [] : EAR_MORPHS);
  const rep = {
    meshes, triangles: Math.round(tris),
    bones: { missing: BONES.filter((n) => !nodes[n]), tails: tails.length, tailsExpected: red ? 7 : 2 },
    morphs: { count: morphs.size, missing: needMorphs.filter((n) => !morphs.has(n)) },
    clips: { present: clipNames, missing: needClips.filter((n) => clipNames.indexOf(n) < 0) },
    accessories: { missing: ACCESSORIES.filter((n) => !nodes[n]) },
  };
  rep.hardMissing = HARD_BONES.filter((n) => !nodes[n]);
  rep.ok = meshes > 0 && rep.hardMissing.length === 0;
  rep.verdict = !rep.ok ? "refuse"
    : rep.bones.missing.length || rep.morphs.missing.length || rep.clips.missing.length || rep.accessories.missing.length ? "replis" : "conforme";
  return rep;
}

/* ---------- 4. Horloge partagée : UNE seule boucle rAF pour toutes les instances glTF ---------- */
const IS_COMPANION_PAGE = /companion\.html/i.test(String((typeof location !== "undefined" && location.pathname) || ""));
const TICKER = { subs: new Set(), raf: 0, add(fn) { this.subs.add(fn); if (!this.raf) this.raf = requestAnimationFrame(tick); } };
function tick() {
  TICKER.raf = 0;
  if (!TICKER.subs.size) return;
  TICKER.raf = requestAnimationFrame(tick);
  const now = performance.now() / 1000;
  TICKER.subs.forEach((f) => { try { f(now); } catch (e) {} });
}

/* Heures calmes (30/10) — une lecture de /api/settings par page, partagée par toutes les instances */
const QUIET = { from: "22:00", to: "07:00", p: null };
function loadQuiet() {
  if (QUIET.p) return;
  try {
    QUIET.p = fetch("/api/settings", { cache: "no-cache" }).then((r) => (r.ok ? r.json() : null)).then((j) => {
      const s = (j && j.settings) || j || {};
      if (s.quiet_from) { QUIET.from = String(s.quiet_from); QUIET.to = String(s.quiet_to || "07:00"); }
    }).catch(() => {});
  } catch (e) {}
}
function inQuietHours() {
  const mins = (t) => { const m = /^(\d{1,2}):(\d{2})/.exec(t || ""); return m ? +m[1] * 60 + +m[2] : -1; };
  const d = new Date(), n = d.getHours() * 60 + d.getMinutes(), a = mins(QUIET.from), b = mins(QUIET.to);
  if (a < 0 || b < 0 || a === b) return false;
  return a < b ? n >= a && n < b : n >= a || n < b;
}

/* ---------- 5. Point d'entrée asynchrone utilisé par avatar.js ---------- */
export async function loadAvatar(host, { species = "panda", preserve = false, url = "" } = {}) {
  let probe = null;
  try {
    const key = isRed(species) ? "renard" : "panda";
    const u = url || new URL("../avatars/" + FILES[key], import.meta.url).href;
    const buf = await fetchBytes(u);
    if (!buf) return null;
    probe = makeRenderer(preserve);
    if (!probe) return null;
    const gltf = await parseGlb(buf, probe);
    if (!gltf) { disposeRenderer(probe); return null; }
    const rep = inspectGltf(gltf, species);
    if (!rep.ok) { disposeGltf(gltf); disposeRenderer(probe); return null; }
    const eng = createAvatar(host, { species, gltf, preserve, renderer: probe, report: rep });
    if (!eng) { disposeGltf(gltf); disposeRenderer(probe); }
    return eng;
  } catch (e) {
    try { if (probe) disposeRenderer(probe); } catch (e2) {}
    return null;
  }
}

function makeRenderer(preserve) {
  try {
    const cv = document.createElement("canvas");
    const gl2 = cv.getContext("webgl2", { alpha: true, antialias: true, premultipliedAlpha: true, preserveDrawingBuffer: !!preserve });
    if (!gl2) return null;
    const r = new THREE.WebGLRenderer({ canvas: cv, context: gl2, alpha: true, antialias: true, premultipliedAlpha: true, powerPreference: "high-performance", preserveDrawingBuffer: !!preserve });
    r.setClearColor(0x000000, 0);
    r.outputColorSpace = THREE.SRGBColorSpace;
    /* 30/10 (rendu premium) : tonemapping filmique ACES — hautes lumières de la fourrure roulées en douceur,
       pas de blanc brûlé sur le museau ; exposition calée avec l'éclairage « Promesse » (section 6). */
    r.toneMapping = THREE.ACESFilmicToneMapping;
    r.toneMappingExposure = 1.05;
    return r;
  } catch (e) { return null; }
}
function disposeRenderer(r) {
  try { r.dispose(); } catch (e) {}
  try { const ext = r.getContext().getExtension("WEBGL_lose_context"); if (ext) ext.loseContext(); } catch (e) {}
  try { r.domElement.remove(); } catch (e) {}
}
function disposeGltf(gltf) {
  if (!gltf || !gltf.scene) return;
  const seen = new Set();
  gltf.scene.traverse((o) => {
    if (o.geometry && !seen.has(o.geometry)) { seen.add(o.geometry); o.geometry.dispose(); }
    if (o.isSkinnedMesh && o.skeleton && !seen.has(o.skeleton)) { seen.add(o.skeleton); o.skeleton.dispose(); }
    const ms = o.material ? (Array.isArray(o.material) ? o.material : [o.material]) : [];
    ms.forEach((m) => {
      if (seen.has(m)) return;
      seen.add(m);
      for (const k in m) { const v = m[k]; if (v && v.isTexture && !seen.has(v)) { seen.add(v); v.dispose(); } }
      m.dispose();
    });
  });
}

/* ---------- 6. Moteur ---------- */
export function createAvatar(host, { species = "panda", gltf = null, preserve = false, renderer = null, report = null } = {}) {
  if (!gltf || !gltf.scene) return null;
  const red = isRed(species);
  const SP = red ? PERSO.red : PERSO.panda;
  const rep = report || inspectGltf(gltf, species);
  if (!rep.ok) return null;
  if (!renderer) renderer = makeRenderer(preserve);
  if (!renderer) return null;

  const cv = renderer.domElement;
  cv.style.cssText = "width:100%;height:100%;display:block";
  cv.dataset.engine = "gltf";
  cv.dataset.species = red ? "renard" : "panda";
  cv.dataset.verdict = rep.verdict;
  host.appendChild(cv);

  const scene = new THREE.Scene();
  const cam = new THREE.PerspectiveCamera(25, 1, 0.05, 40);
  const pmrem = new THREE.PMREMGenerator(renderer);
  const room = new RoomEnvironment(renderer);
  const envRT = pmrem.fromScene(room, 0.04);
  scene.environment = envRT.texture;
  room.traverse((o) => { if (o.geometry) o.geometry.dispose(); if (o.material) o.material.dispose(); });
  pmrem.dispose();

  /* 30/10 — ÉCLAIRAGE « PROMESSE » (docs/identite/IDENTITE.md) : la fin d'après-midi d'harmattan.
     · environnement RoomEnvironment (PMREM) en appoint modeste (envMapIntensity ≈ 0,45 par matériau) ;
     · clé chaude « or d'étoile » haut-droite, la seule lumière forte ;
     · rebond latérite #C84A23 bas-gauche, très faible (la piste qui rougeoie) ;
     · liseré froid indigo/violet (#7B80F0, teinté par --accent) arrière-gauche + contre-jour or arrière-droit ;
     · ciel/sol : sable chaud au zénith, indigo #1A1430 au sol. Rendu filmique ACES (makeRenderer). */
  const ENV_K = 0.45;
  const hemi = new THREE.HemisphereLight(0xfff1de, 0x1a1430, 0.42);
  const key = new THREE.DirectionalLight(0xffd9a6, 2.35);
  key.position.set(1.4, 2.5, 2.6);
  const fill = new THREE.DirectionalLight(0xc84a23, 0.38);
  fill.position.set(-2.2, 0.35, 1.6);
  const rim = new THREE.DirectionalLight(0x7b80f0, 1.9);
  rim.position.set(-1.9, 1.6, -2.2);
  const kick = new THREE.DirectionalLight(0xffc979, 0.9);
  kick.position.set(2.0, 1.2, -1.8);
  scene.add(hemi, key, fill, rim, kick);

  /* Ombre de contact à deux couches (texture canvas radiale) : un cœur serré et sombre sous les pieds
     (occlusion), un halo large et doux (pénombre), teinte nuit indigo — jamais un noir pur. */
  const shCv = document.createElement("canvas");
  shCv.width = shCv.height = 128;
  const sctx = shCv.getContext("2d");
  const grd = sctx.createRadialGradient(64, 64, 2, 64, 64, 63);
  grd.addColorStop(0, "rgba(14,12,34,0.50)");
  grd.addColorStop(0.32, "rgba(14,12,34,0.30)");
  grd.addColorStop(0.7, "rgba(14,12,34,0.08)");
  grd.addColorStop(1, "rgba(14,12,34,0)");
  sctx.fillStyle = grd;
  sctx.fillRect(0, 0, 128, 128);
  const shTex = new THREE.CanvasTexture(shCv);
  shTex.colorSpace = THREE.SRGBColorSpace;
  const shGeo = new THREE.PlaneGeometry(1, 1);
  const shMat = new THREE.MeshBasicMaterial({ map: shTex, transparent: true, depthWrite: false, toneMapped: false });
  const shadow = new THREE.Mesh(shGeo, shMat);
  shadow.rotation.x = -Math.PI / 2;
  shadow.position.y = 0.002;
  shadow.renderOrder = -1;
  scene.add(shadow);
  const shCore = new THREE.Mesh(shGeo, shMat);   // même géométrie/matériau : aucun coût mémoire de plus
  shCore.rotation.x = -Math.PI / 2;
  shCore.position.y = 0.003;
  shCore.renderOrder = -1;
  scene.add(shCore);

  // rig (pivot aux pieds) → fix (normalisation/orientation) → modèle de l'artiste
  const model = gltf.scene;
  const fix = new THREE.Group();
  const rig = new THREE.Group();
  fix.add(model);
  rig.add(fix);
  scene.add(rig);

  /* Index des nœuds (os prioritaires sur les homonymes) */
  const N = {};
  model.traverse((o) => { if (o.name && (!N[o.name] || (o.isBone && !N[o.name].isBone))) N[o.name] = o; });
  const B = {};
  BONES.forEach((n) => { if (N[n]) B[n] = N[n]; });
  const tails = [];
  for (let i = 1; i <= 7; i++) if (N["tail_0" + i]) tails.push(N["tail_0" + i]);
  /* 30/10 : bras compris — les couches procédurales (balancier) y écrivent après le mixer ; la remise au
     repos à chaque image garantit qu'aucune rotation ne s'accumule si un fondu laisse un poids total < 1. */
  const driven = ["root", "hips", "spine", "chest", "neck", "head", "jaw", "eye_L", "eye_R", "ear_L", "ear_R",
    "shoulder_L", "upperArm_L", "foreArm_L", "shoulder_R", "upperArm_R", "foreArm_R"].filter((n) => B[n]).map((n) => B[n]).concat(tails);
  const rest = new Map();
  driven.forEach((b) => rest.set(b, { q: b.quaternion.clone(), p: b.position.clone(), s: b.scale.clone() }));

  /* Accessoires : masqués par défaut, affichés par état (pop doux d'échelle) */
  const accs = {};
  model.updateMatrixWorld(true);
  ACCESSORIES.forEach((n) => {
    const o = N[n];
    if (!o) return;
    /* Rattachement : un accessoire SKINNÉ suit déjà ses os par pondération ; un maillage rigide livré
       hors de head / hand_* est rattaché ici à l'os du cahier (transformation monde conservée). */
    let skinned = false;
    o.traverse((c) => { if (c.isSkinnedMesh) skinned = true; });
    if (!skinned) {
      const targets = ACC_BONE[n].filter((b) => B[b]);
      let under = false;
      for (let p = o.parent; p; p = p.parent) if (targets.indexOf(p.name) >= 0) under = true;
      if (!under && targets.length) { try { B[targets[0]].attach(o); } catch (e) {} }
    }
    accs[n] = { o, s0: o.scale.clone(), k: 0, skinned };
    o.visible = false;
  });
  /* 30/10 — Portable : livré pondéré à 100 % sur hand_L, il suivait la main du clip « typing » jusque
     DEVANT LE VISAGE. Il est ré-pondéré sur la poitrine (chest, sinon spine) : posé devant le ventre à sa
     place de pose de liaison, les mains tapent dessus. Le .glb n'est pas modifié (géométrie de l'instance). */
  if (accs.acc_laptop && accs.acc_laptop.skinned) {
    const anchor = B.chest || B.spine;
    accs.acc_laptop.o.traverse((c) => {
      if (!c.isSkinnedMesh || !anchor || !c.skeleton) return;
      const bi = c.skeleton.bones.indexOf(anchor);
      const si = c.geometry && c.geometry.attributes.skinIndex, sw = c.geometry && c.geometry.attributes.skinWeight;
      if (bi < 0 || !si || !sw) return;
      for (let i = 0; i < si.count; i++) { si.setXYZW(i, bi, 0, 0, 0); sw.setXYZW(i, 1, 0, 0, 0); }
      si.needsUpdate = true; sw.needsUpdate = true;
    });
  }
  const underAcc = (o) => { for (let p = o; p; p = p.parent) if (p.name && accs[p.name]) return true; return false; };

  /* Blendshapes : nom → liste (maillage, index) */
  const MT = new Map();
  const meshList = [];
  model.traverse((o) => {
    if (!o.isMesh) return;
    meshList.push(o);
    o.frustumCulled = false;   // un maillage skinné peut sortir de sa boîte de repos (saut, pirouette)
    if (o.morphTargetDictionary && o.morphTargetInfluences) {
      for (const [k, i] of Object.entries(o.morphTargetDictionary)) {
        if (!MT.has(k)) MT.set(k, []);
        MT.get(k).push({ m: o, i });
      }
    }
  });
  /* 30/10 — Matières : la fourrure (MeshStandard du .glb) devient MeshPhysical avec un voile de « sheen »
     chaud (diffusion rasante du poil, lisible au liseré), les yeux reçoivent un vernis (clearcoat) qui
     accroche un reflet net de l'environnement, et toutes les matières prennent l'environnement à faible
     intensité (ENV_K) : la lumière vient des sources « Promesse », pas de la pièce PMREM. Les textures
     sont réutilisées (aucune copie) ; l'ancien matériau est libéré tout de suite. */
  const physFrom = (m, extra) => {
    const p = new THREE.MeshPhysicalMaterial();
    THREE.MeshStandardMaterial.prototype.copy.call(p, m);
    p.defines = { STANDARD: "", PHYSICAL: "" };
    p.name = m.name;
    Object.assign(p, extra);
    return p;
  };
  meshList.forEach((o) => {
    const ms = Array.isArray(o.material) ? o.material : [o.material];
    const out = ms.map((m) => {
      if (!m || !m.isMeshStandardMaterial) return m;
      const nm = String(m.name || "");
      let n = m;
      try {
        if (/fur|body|nova_body/i.test(nm) || (o.name === "Nova_Body" && !m.isMeshPhysicalMaterial)) {
          n = physFrom(m, { sheen: 1, sheenRoughness: 0.62, sheenColor: new THREE.Color(0xffc69a).multiplyScalar(0.42), roughness: Math.min(1, m.roughness) * 0.94 });
          if (n.normalMap) n.normalScale.multiplyScalar(1.1);
        } else if (/eye/i.test(nm) || o.name === "Nova_Eyes") {
          n = physFrom(m, { clearcoat: 1, clearcoatRoughness: 0.04, roughness: Math.max(0.12, m.roughness) });
          n.envMapIntensity = 1.25;
        }
      } catch (e) { n = m; }
      if (n.envMapIntensity === 1) n.envMapIntensity = /acc/i.test(nm) ? 0.8 : ENV_K;   // accessoires (métal léger) : un peu plus de reflets
      if (n !== m) { try { m.dispose(); } catch (e) {} }
      return n;
    });
    o.material = Array.isArray(o.material) ? out : out[0];
  });
  const has = (n) => MT.has(n);
  const W = {};   // poids voulus ce frame (remis à 0 à chaque image)
  const ownNames = new Set();   // noms écrits par le moteur (pour les remettre à 0 quand inutilisés)
  const setW = (n, v) => { if (MT.has(n)) { W[n] = Math.max(W[n] || 0, clamp(v, 0, 1)); ownNames.add(n); } };

  /* Clips : noms animés par les clips (morph « weights ») → combinaison max avec le moteur */
  const clips = {};
  (gltf.animations || []).forEach((c) => { clips[c.name] = c; });
  const clipMorphMeshes = new Set();
  (gltf.animations || []).forEach((c) => c.tracks.forEach((t) => { if (/\.morphTargetInfluences/.test(t.name)) clipMorphMeshes.add(t.name.split(".")[0]); }));

  /* Dernière sortie du mixer pour les maillages dont les clips animent les blendshapes (voir update) */
  const clipMorphOut = new Map();
  meshList.forEach((m) => { if (clipMorphMeshes.has(m.name) && m.morphTargetInfluences) clipMorphOut.set(m, new Array(m.morphTargetInfluences.length).fill(0)); });

  /* Normalisation : hauteur ≈ 1, pieds sur Y = 0, centré ; face +Z (retourné si les yeux regardent −Z) */
  model.updateMatrixWorld(true);
  const box = new THREE.Box3();
  const tmpBox = new THREE.Box3();
  meshList.forEach((m) => {
    if (underAcc(m)) return;
    try {
      if (m.isSkinnedMesh) { m.computeBoundingBox(); tmpBox.copy(m.boundingBox).applyMatrix4(m.matrixWorld); }
      else { if (!m.geometry.boundingBox) m.geometry.computeBoundingBox(); tmpBox.copy(m.geometry.boundingBox).applyMatrix4(m.matrixWorld); }
      box.union(tmpBox);
    } catch (e) {}
  });
  if (box.isEmpty()) box.set(new THREE.Vector3(-0.4, 0, -0.4), new THREE.Vector3(0.4, 1, 0.4));
  const size = box.getSize(new THREE.Vector3());
  const H0 = size.y > 1e-4 ? size.y : 1;
  const sc = clamp(1 / H0, 0.001, 1000);
  fix.scale.setScalar(sc);
  const ctr = box.getCenter(new THREE.Vector3());
  model.position.x -= ctr.x;
  model.position.y -= box.min.y;
  model.position.z -= ctr.z;
  if (B.eye_L && B.eye_R && B.head) {
    const e1 = B.eye_L.getWorldPosition(new THREE.Vector3()), e2 = B.eye_R.getWorldPosition(new THREE.Vector3()), hp = B.head.getWorldPosition(new THREE.Vector3());
    if ((e1.z + e2.z) / 2 < hp.z - 0.01) fix.rotation.y = Math.PI;   // livré face −Z : on le retourne
  }
  const H = 1;
  const shW = Math.max(0.5, size.x * sc * 1.25);
  shadow.scale.set(shW, shW * 0.62, 1);
  shCore.scale.set(shW * 0.46, shW * 0.26, 1);

  /* Mixer : poids gérés à la main = fondus déterministes (pas d'empilement de fadeIn/fadeOut) */
  const mixer = new THREE.AnimationMixer(model);
  mixer.timeScale = SP.tScale;
  const acts = new Map();   // nom → { a, w }
  let loopName = "", oneShot = "";
  const actFor = (name) => {
    if (!clips[name]) return null;
    let e = acts.get(name);
    if (!e) {
      const a = mixer.clipAction(clips[name]);
      e = { a, w: 0 };
      acts.set(name, e);
    }
    return e;
  };
  const playOnce = (name) => {
    const e = actFor(name);
    if (!e) return false;
    e.a.reset();
    e.a.setLoop(THREE.LoopOnce, 1);
    e.a.clampWhenFinished = true;
    e.a.setEffectiveWeight(e.w);
    e.a.play();
    oneShot = name;
    return true;
  };
  const setLoop = (name) => {
    const e = actFor(name);
    if (!e) { loopName = ""; return; }
    if (loopName !== name) {
      e.a.setLoop(THREE.LoopRepeat, Infinity);
      e.a.clampWhenFinished = false;
      if (!e.a.isRunning()) { e.a.reset(); e.a.play(); }
    }
    loopName = name;
  };
  const onFinished = (ev) => { if (ev && ev.action && acts.get(oneShot) && acts.get(oneShot).a === ev.action) oneShot = ""; };
  mixer.addEventListener("finished", onFinished);
  /* 30/10 — FONDUS : durée bornée 0,25–0,4 s (zeta de la personnalité : roux plus vif, panda plus posé),
     progression linéaire mais poids appliqué en smoothstep (départ et arrivée sans à-coup ; deux fondus
     croisés en phase gardent une somme = 1). Un clip ponctuel commence à s'effacer AVANT sa dernière image
     (FADE avant la fin) : il ne se fige jamais sur sa pose finale en attendant le fondu. */
  const FADE = clamp(SP.fade * (SP.zeta / 0.85), 0.25, 0.4);
  let fading = false, lastShot = null;
  /* clip court (nod 0,6 s, wink 0,8 s) : fondu ≤ 30 % de sa durée, sinon le geste serait mangé par le fondu ;
     le mixer de three normalise les poids (somme > 1 = moyenne pondérée), aucune surexposition de pose. */
  const fadeOf = (e) => (e.a.loop === THREE.LoopOnce ? Math.min(FADE, Math.max(0.12, e.a.getClip().duration * 0.3)) : FADE);
  const updateWeights = (dt) => {
    if (oneShot) {
      const o = acts.get(oneShot);
      if (o && o.a.time >= o.a.getClip().duration - fadeOf(o)) oneShot = "";
    }
    fading = false;
    if (oneShot) lastShot = acts.get(oneShot) || null;
    const os = lastShot && (lastShot.w > 0 || oneShot) ? lastShot : null;   // la boucle suit le rythme du geste ponctuel (fondu croisé en phase)
    acts.forEach((e, name) => {
      const tgt = name === oneShot ? 1 : name === loopName ? (oneShot ? 0 : 1) : 0;
      const step = dt / (os && name === loopName ? fadeOf(os) : fadeOf(e));
      e.w = tgt > e.w ? Math.min(tgt, e.w + step) : Math.max(tgt, e.w - step);
      if (e.w !== tgt) fading = true;
      if (e.w <= 0 && tgt <= 0) { if (e.a.isRunning() || e.a.paused) e.a.stop(); e.a.enabled = true; }
      else { e.a.enabled = true; if (!e.a.isScheduled()) e.a.play(); e.a.setEffectiveWeight(sstep(0, 1, e.w)); }
    });
  };

  /* ---- État dynamique ---- */
  let state = "idle", stateT = 0, mood = "neutre", level = 0, dead = false, visible = true;
  let lastAct = performance.now() / 1000;
  let visSrc = null;
  const vis = { open: 0, spread: 0, round: 0, press: 0, t: -10 };
  const mouth = { open: 0, spread: 0, round: 0, press: 0 };
  const ptr = { x: 0, y: 0 };
  const focus = { on: false, x: 0, y: 0 };
  const gaze = { x: 0, y: 0, tx: 0, ty: 0, nextSac: 0, driftUntil: 0, dx: 0, dy: 0 };
  const blink = { next: performance.now() / 1000 + rnd(1.2, 3.5), t0: -10 };
  const P = { lean: 0, roll: 0, pitch: 0, yaw: 0, turn: 0, smile: 0.45, perk: 0, browL: 0, browR: 0, lid: 0, jaw: 0, press: 0, wide: 0 };
  const imp = [];   // mimiques procédurales { k, t0, d }
  let hopY = 0, hopV = 0, squash = 0, squashV = 0;
  const hops = [];
  let spinT0 = -10, whipT0 = -10, gestureAlt = 0;
  let duchPulse = 0;
  /* 30/10 — parole : voix réelle (visème frais ou niveau audio mesuré) → gestes talk_gesture_A/B enchaînés ;
     « parole » SANS son = la réponse s'écrit à l'écran (flux texte, orb.js › delta) → clip typing + portable. */
  let voiceT = -10, talkNext = 0, talkVoice = false;
  /* 30/10 — variété au repos : un clin d'œil, un hochement ou un coup de queue toutes les 20–40 s (jamais
     pendant une autre activité, jamais en sommeil) ; ce geste ne compte pas comme une activité d'Ahadi. */
  let fidgetAt = performance.now() / 1000 + rnd(14, 26), fidget = "";
  /* 30/10 — regard : la tête SUIT les yeux avec retard (les yeux mènent), cible = curseur ; curseur
     immobile depuis 8 s → la cible revient doucement vers la caméra (il te regarde, pas un coin d'écran). */
  const look = { x: 0, y: 0, k: 1 };
  let ptrT = -100;

  const isReduced = () => { try { return matchMedia("(prefers-reduced-motion: reduce)").matches || document.documentElement.dataset.reduceMotion === "1"; } catch (e) { return false; } };
  const jump = (v, delay) => { const k = isReduced() ? 0.2 : 1; squashV -= 2.2 * v * k; hops.push({ t: performance.now() / 1000 + (delay || 0.1), v: v * k }); };

  /* Rotation d'un os autour des axes du MODÈLE (Y haut, face +Z), quel que soit le repère local de l'artiste */
  const _e = new THREE.Euler(0, 0, 0, "YXZ"), _q = new THREE.Quaternion(), _pq = new THREE.Quaternion(), _mq = new THREE.Quaternion(), _iq = new THREE.Quaternion();
  const rotModel = (bone, x, y, z) => {
    if (!bone || !bone.parent || (!x && !y && !z)) return;
    _e.set(x, y, z, "YXZ");
    _q.setFromEuler(_e);
    rig.getWorldQuaternion(_mq);   // repère de présentation (après retournement éventuel)
    _q.premultiply(_mq).multiply(_iq.copy(_mq).invert());   // axes modèle → monde
    bone.parent.getWorldQuaternion(_pq);
    _q.premultiply(_iq.copy(_pq).invert()).multiply(_pq);    // monde → repère du parent
    bone.quaternion.premultiply(_q);
    bone.updateMatrixWorld(true);
  };

  /* Thème : liseré froid de l'identité (#7B80F0, indigo du ciel de Promesse) légèrement teinté par --accent
     (30 %) — l'accent latérite ne réchauffe jamais le contre-jour au point de perdre le contraste chaud/froid. */
  const tmpC = new THREE.Color();
  const RIM0 = new THREE.Color(0x7b80f0);
  const applyTheme = () => {
    let hex = "#7B80F0";
    try { hex = getComputedStyle(document.documentElement).getPropertyValue("--accent").trim() || hex; } catch (e) {}
    try { tmpC.set(hex); } catch (e) { tmpC.copy(RIM0); }
    rim.color.copy(RIM0).lerp(tmpC, 0.3);
  };
  applyTheme();

  /* Taille / caméra (DPR = min(2, dpr), résolution interne ≤ 560 px : net sur Retina pour le héros 150 px
     et le compagnon, sans payer une toile géante si l'hôte grandit ; MSAA du contexte WebGL2) */
  let cssW = 0, cssH = 0;
  const resize = () => {
    cssW = Math.max(16, host.clientWidth || 200);
    cssH = Math.max(16, host.clientHeight || cssW);
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    renderer.setPixelRatio(Math.min(dpr, 560 / Math.max(cssW, cssH)));
    renderer.setSize(cssW, cssH, false);
    cam.aspect = cssW / cssH;
    const fov = 25;
    const dist = (H * 0.56) / Math.tan((fov * Math.PI) / 360) + 0.22;
    cam.fov = cam.aspect < 1 ? (2 * Math.atan(Math.tan((fov * Math.PI) / 360) / cam.aspect) * 180) / Math.PI : fov;
    cam.position.set(0, H * 0.58, dist);
    cam.lookAt(0, H * 0.52, 0);
    cam.updateProjectionMatrix();
  };
  const ro = new ResizeObserver(resize);
  ro.observe(host);
  const io = new IntersectionObserver((en) => { if (en && en[0]) visible = en[0].isIntersecting; });
  io.observe(host);

  const enterState = (st, prev) => {
    const S = STATES[st];
    oneShot = "";   // la mimique ou la pose ponctuelle précédente s'efface en fondu
    setLoop(clips[S.clip] ? S.clip : "idle");
    if (S.once) playOnce(S.once);
    const k = isReduced() ? 0.2 : 1;
    const proc = !(S.once && clips[S.once]);   // le clip livré porte déjà le saut / la pirouette
    if (st === "done" && proc) { jump(1.0, 0.12); setTimeout(() => { if (!dead && state === "done") jump(0.7, 0.1); }, 900); }
    if (st === "celebrate" && proc) { jump(1.4, 0.16); spinT0 = performance.now() / 1000 + 0.24; whipT0 = spinT0; setTimeout(() => { if (!dead && state === "celebrate") jump(0.8, 0.08); }, 1350); }
    if (st === "error") squashV += 0.5 * k;
    if (st === "approval" && !clips.approval) jump(0.5, 0.08);
    if (prev === "sleep") P.perk = 1.2;
    if (st === "idle") fidgetAt = performance.now() / 1000 + rnd(14, 28);
    if (st === "speaking") { talkVoice = false; talkNext = 0; }
  };
  /* Geste spontané au repos (voir fidgetAt). Panda roux : clin d'œil / hochement / coup de queue ;
     panda géant : clin d'œil / hochement (sa queue courte n'a pas de clip). */
  const playFidget = (now) => {
    const r = Math.random();
    const k = red && clips.arrive_tail ? (r < 0.3 ? "wink" : r < 0.65 ? "nod" : "arrive_tail") : r < 0.45 ? "wink" : "nod";
    if (k === "nod") imp.push({ k: "nod", t0: now, d: 0.85, clip: playOnce("nod") });
    else if (k === "wink") imp.push({ k: "wink", t0: now, d: 0.9, clip: playOnce("wink") });
    else if (!playOnce("arrive_tail")) imp.push({ k: "whip", t0: now, d: 1.0 });
    fidget = oneShot;
  };
  /* Heures calmes (Réglages : quiet_from / quiet_to, défaut 22:00–07:00) : s'endort après 90 s sans
     geste au lieu de 4 min. Lu une fois par page (promesse partagée), réévalué toutes les 30 s. */
  loadQuiet();
  let quietNow = false, quietChk = 0;

  /* ---- Image ---- */
  function update(now, dt) {
    stateT += dt;
    const red_ = isReduced(), mot = red_ ? 0.2 : 1;
    const vide = document.documentElement.hasAttribute("data-vide");
    if (now - quietChk > 30) { quietChk = now; quietNow = inQuietHours(); }
    if (state !== "sleep" && ((state === "idle" || state === "reading") && now - lastAct > (quietNow ? 90 : 240) || now - lastAct > 240 || vide)) { const p = state; state = "sleep"; stateT = 0; enterState("sleep", p); }
    if (state === "done" && stateT > 2.4) api.setState("idle");
    if (state === "celebrate" && stateT > 3.1) api.setState("idle");
    const S = STATES[state] || STATES.idle;
    const M = MOODS[mood] || MOODS.neutre;
    const life = SP.life * M.life * mot;
    const poseProc = S.once && clips[S.once] && oneShot === S.once ? false : !clips[S.clip] || S.clip === "idle";   // clip propre absent → pose procédurale

    // Source de visèmes lue DANS cette boucle (aucune boucle de plus)
    if (visSrc) { try { const v = visSrc(); if (v) api.setViseme(v); } catch (e) {} }

    // Cibles de pose (état + humeur), amorties selon la personnalité
    const pr = SP.poseRate;
    P.lean = damp(P.lean, poseProc ? S.lean || 0 : 0, pr, dt);
    P.roll = damp(P.roll, poseProc ? S.roll || 0 : 0, pr, dt);
    P.pitch = damp(P.pitch, poseProc ? S.pitch || 0 : 0, pr, dt);
    P.yaw = damp(P.yaw, poseProc ? S.yaw || 0 : 0, pr, dt);
    const turnT = S.turn ? S.turn * (focus.on ? Math.sign(focus.x || 1) : 1) : 0;
    P.turn = damp(P.turn, poseProc ? turnT : 0, pr * 0.8, dt);
    P.smile = damp(P.smile, clamp((S.smile ?? 0.45) + M.smile, 0, 1.2), 6, dt);
    P.perk = damp(P.perk, clamp((S.perk || 0) + M.perk, -1, 1.2), 6 * SP.ear, dt);
    const br = S.brow || [0, 0];
    P.browL = damp(P.browL, br[0] + M.brow, 8, dt);
    P.browR = damp(P.browR, br[1] + M.brow, 8, dt);
    P.lid = damp(P.lid, (S.lid || 0) + (M.lid || 0), 8, dt);
    P.jaw = damp(P.jaw, S.jaw || 0, 10, dt);
    P.press = damp(P.press, S.press || 0, 10, dt);
    P.wide = damp(P.wide, S.wide || 0, 8, dt);
    duchPulse = Math.max(0, duchPulse - dt * 0.9);

    // Bouche : visème mesuré récent, sinon niveau audio (mâchoire seule), sinon fermée
    const fresh = now - vis.t < 0.25;
    const tOpen = fresh ? vis.open : state === "speaking" ? level : 0;
    const tSpread = fresh ? vis.spread : 0, tRound = fresh ? vis.round : 0, tPress = fresh ? vis.press : 0;
    const att = (c, t) => (t > c ? 24 : 14);
    mouth.open = damp(mouth.open, tOpen, att(mouth.open, tOpen), dt);
    mouth.spread = damp(mouth.spread, tSpread, 18, dt);
    mouth.round = damp(mouth.round, tRound, 18, dt);
    mouth.press = damp(mouth.press, tPress, 34, dt);

    // Parole (30/10) : voix réelle → gestes A/B enchaînés, calés sur le début de la voix ; silence → écriture
    if ((fresh && vis.open > 0.04) || level > 0.04) voiceT = now;
    if (state === "speaking") {
      const v = now - voiceT < 2.0;   // hystérésis : une pause entre deux phrases ne fait pas « taper » le panda
      if (v && !talkVoice) talkNext = Math.min(talkNext || Infinity, now + 0.12);   // la voix démarre : premier geste tout de suite
      talkVoice = v;
      const want = talkVoice ? "idle" : stateT > 0.35 && clips.typing ? "typing" : loopName || "idle";
      if (want !== loopName) setLoop(want);
      if (talkVoice && !oneShot && now >= talkNext && (clips.talk_gesture_A || clips.talk_gesture_B)) {
        const g = gestureAlt++ % 2 ? "talk_gesture_B" : "talk_gesture_A";
        playOnce(clips[g] ? g : clips.talk_gesture_A ? "talk_gesture_A" : "talk_gesture_B");
        talkNext = now + clips[oneShot].duration + rnd(0.7, 2.0) / SP.life;
      }
    } else talkVoice = false;
    // Variété au repos (clin d'œil / hochement / queue) — éveillé, rien d'autre en cours
    if (fidget && oneShot !== fidget) fidget = "";
    if (state === "idle" && !oneShot && !imp.length && !red_ && now >= fidgetAt) { playFidget(now); fidgetAt = now + rnd(20, 40); }

    // Regard 80/20 : revient vers toi (curseur / carte ciblée) 80 % du temps, dérives 20 %, micro-saccades
    if (now >= gaze.nextSac) {
      gaze.nextSac = now + rnd(0.4, 1.0) / Math.max(0.6, life);
      if (now > gaze.driftUntil && Math.random() < 0.2 && !focus.on) { gaze.driftUntil = now + rnd(0.6, 1.6); gaze.dx = rnd(-0.6, 0.6); gaze.dy = rnd(-0.3, 0.3); }
      gaze.jx = rnd(-0.04, 0.04); gaze.jy = rnd(-0.03, 0.03);
    }
    look.k = damp(look.k, now - ptrT > 8 ? 0.25 : 1, 1.5, dt);   // curseur immobile → retour doux vers toi
    let gx = focus.on ? focus.x : ptr.x * look.k, gy = focus.on ? focus.y : ptr.y * look.k;
    if (now < gaze.driftUntil) { gx = gaze.dx; gy = gaze.dy; }
    if (S.gy != null) { gy = S.gy; gx = S.gx != null ? S.gx : gx * 0.3; }
    if (S.scan) gx = Math.sin(now * 1.7) * 0.35;
    if (state === "sleep") { gx = 0; gy = -0.3; }
    gaze.tx = clamp(gx + (gaze.jx || 0), -1, 1);
    gaze.ty = clamp(gy + (gaze.jy || 0), -1, 1);
    gaze.x = damp(gaze.x, gaze.tx, SP.gazeRate * 3, dt);
    gaze.y = damp(gaze.y, gaze.ty, SP.gazeRate * 3, dt);

    // Clignements naturels (≥ 1,2 s d'écart, fermeture 70 ms, réouverture 150 ms)
    if (now >= blink.next) { blink.t0 = now; blink.next = now + 1.2 + expo(3.0 / Math.max(0.6, life)); }
    const bt = now - blink.t0;
    let bl = bt < 0.07 ? bt / 0.07 : bt < 0.22 ? 1 - sstep(0.07, 0.22, bt) : 0;
    bl = Math.max(bl, P.lid + Math.max(0, -gaze.y) * 0.22);
    let blL = bl, blR = bl, wide = P.wide, browIn = 0, jawCut = 1, nodP = 0, hRollImp = 0, tailWhip = 0;

    // Mimiques procédurales (repli des clips nod/wink ; Duchenne, surprise : toujours)
    for (let i = imp.length - 1; i >= 0; i--) {
      const it = imp[i], p = (now - it.t0) / it.d;
      if (p >= 1) { imp.splice(i, 1); continue; }
      if (it.k === "nod" && !it.clip) nodP += Math.sin(p * Math.PI * 2) * bell(p) * 0.2;
      if (it.k === "wink") { if (!it.clip) { blL = Math.max(blL, bell(Math.min(1, p * 1.6))); nodP += bell(p) * 0.08; } }
      if (it.k === "surprise") { wide = Math.max(wide, bell(p) * 0.9); browIn = Math.max(browIn, bell(p)); jawCut = 0.15; }
      if (it.k === "wave" && !it.clip) hRollImp += Math.sin(p * Math.PI * 4) * bell(p) * 0.08;
      if (it.k === "whip") tailWhip = Math.max(tailWhip, bell(p));
    }
    if (now - whipT0 < 1.0) tailWhip = Math.max(tailWhip, bell(now - whipT0));

    // Sauts (rebond ballistique) + squash & stretch à volume conservé
    for (let i = hops.length - 1; i >= 0; i--) if (now >= hops[i].t) { hopV = Math.max(hopV, hops[i].v * 1.6); hops.splice(i, 1); }
    if (hopY > 0 || hopV > 0) { hopV -= 9.8 * dt; hopY += hopV * dt; if (hopY <= 0) { hopY = 0; if (hopV < -0.4) squashV -= hopV * 1.6; hopV = 0; } }
    squashV += (-120 * squash - 2 * 0.35 * 11 * squashV) * dt;
    squash += squashV * dt;
    const spinP = clamp((now - spinT0) / 0.9, 0, 1);
    const spin = spinP > 0 && spinP < 1 ? sstep(0, 1, spinP) * Math.PI * 2 : 0;

    // 1) Remise au repos des os pilotés, puis clips (absolus), puis couches procédurales
    /* 30/10 (correctif) : le PropertyMixer de three n'ÉCRIT un os que si sa valeur a changé depuis l'image
       précédente — une piste immobile (bras levés de « thinking », tête fixe d'un clip) n'est donc pas
       réécrite. L'ancienne remise au REPOS avant le mixer effaçait alors la pose du clip dès la fin du fondu
       (bras qui retombaient d'un coup). On restaure maintenant la dernière SORTIE du mixer (r.q…, initialisée
       au repos), puis on la mémorise après mixer.update, avant les couches procédurales : pas d'accumulation,
       et la pose d'un clip immobile tient. */
    rest.forEach((r, b) => { b.quaternion.copy(r.q); b.position.copy(r.p); b.scale.copy(r.s); });
    clipMorphOut.forEach((buf, m) => { const inf = m.morphTargetInfluences; for (let i = 0; i < buf.length; i++) inf[i] = buf[i]; });   // même logique pour les blendshapes (sinon max(clip, moteur) se verrouille : yeux mi-clos)
    updateWeights(dt);
    mixer.update(dt);
    rest.forEach((r, b) => { r.q.copy(b.quaternion); r.p.copy(b.position); r.s.copy(b.scale); });
    clipMorphOut.forEach((buf, m) => { const inf = m.morphTargetInfluences; for (let i = 0; i < buf.length; i++) buf[i] = inf[i]; });
    rig.updateMatrixWorld(true);

    // Corps (rig) : penché, roulis, rotation vers la carte, saut, pirouette, squash
    const sq = clamp(squash, -0.25, 0.25);
    rig.position.y = hopY * 0.35;
    rig.rotation.set(P.lean * mot, P.turn * mot + spin, (P.roll * 0.4 + hRollImp) * mot);
    rig.scale.set(1 - sq * 0.5, 1 + sq, 1 - sq * 0.5);
    shadow.material.opacity = 1 - clamp(hopY * 1.5, 0, 0.6);

    // Respiration (repli : si le clip de l'état n'anime pas la poitrine) — tête non déformée
    const breathK = (S.breathK || 1) * mot;
    if (B.chest && poseProc && !clips.idle) {
      const b = Math.sin(now * Math.PI * 2 * SP.breath) * 0.012 * breathK;
      B.chest.scale.multiplyScalar(1 + b);
      if (B.neck) B.neck.scale.multiplyScalar(1 / (1 + b));
    }
    // Tête : pose d'état + suivi du regard (20 %) + micro-mouvements permanents + hochements
    /* 30/10 : la tête suit la cible du regard (sans les micro-saccades) avec retard — les yeux mènent, la
       tête rattrape (SP.headRate), bornée (±24° lacet, ±12° tangage) et atténuée pendant un geste du clip. */
    look.x = damp(look.x, gaze.tx - (gaze.jx || 0), SP.headRate * 0.55, dt);
    look.y = damp(look.y, gaze.ty - (gaze.jy || 0), SP.headRate * 0.55, dt);
    const lk = oneShot ? 0.5 : 1;
    const micro = 0.03 * life;
    const hx = P.pitch + nodP + clamp(-look.y * 0.17, -0.21, 0.21) * lk + n1(now * 0.31 + 3) * micro;
    const hy = P.yaw + clamp(look.x * 0.34, -0.42, 0.42) * lk + n1(now * 0.27 + 11) * micro;
    const hz = P.roll * 0.6 + n1(now * 0.23 + 29) * micro * 0.6;
    if (B.neck) { rotModel(B.neck, hx * 0.35 * mot, hy * 0.35 * mot, hz * 0.35 * mot); rotModel(B.head, hx * 0.65 * mot, hy * 0.65 * mot, hz * 0.65 * mot); }
    else rotModel(B.head, hx * mot, hy * mot, hz * mot);
    // Yeux : os eye_L/eye_R, sinon blendshapes eyeLook*
    if (B.eye_L || B.eye_R) {
      rotModel(B.eye_L, -gaze.y * 0.28, gaze.x * 0.38, 0);
      rotModel(B.eye_R, -gaze.y * 0.28, gaze.x * 0.38, 0);
    } else {
      setW(gaze.x > 0 ? "eyeLookOutLeft" : "eyeLookInLeft", Math.abs(gaze.x));
      setW(gaze.x > 0 ? "eyeLookInRight" : "eyeLookOutRight", Math.abs(gaze.x));
      setW(gaze.y > 0 ? "eyeLookUpLeft" : "eyeLookDownLeft", Math.abs(gaze.y));
      setW(gaze.y > 0 ? "eyeLookUpRight" : "eyeLookDownRight", Math.abs(gaze.y));
    }
    // Paupières : blendshapes, sinon écrasement d'échelle des os d'yeux (repli doux)
    if (has("eyeBlinkLeft") || has("eyeBlinkRight")) {
      setW("eyeBlinkLeft", blL); setW("eyeBlinkRight", blR);
      /* 30/10 : la paupière du .glb ne recouvre pas tout le globe (maillage Nova_Eyes séparé) — paupière
         fermée = yeux mi-clos. Le globe s'aplatit donc avec la fermeture (moteur OU clip : sleep, wink, idle). */
      const cl = (n) => { const e = MT.get(n); const buf = e && clipMorphOut.get(e[0].m); return buf ? buf[e[0].i] || 0 : 0; };
      const kL = sstep(0.35, 1, Math.max(blL, cl("eyeBlinkLeft"))), kR = sstep(0.35, 1, Math.max(blR, cl("eyeBlinkRight")));
      if (B.eye_L && kL > 0) B.eye_L.scale.y *= 1 - 0.9 * kL;
      if (B.eye_R && kR > 0) B.eye_R.scale.y *= 1 - 0.9 * kR;
    } else {
      if (B.eye_L) B.eye_L.scale.y *= 1 - 0.85 * blL;
      if (B.eye_R) B.eye_R.scale.y *= 1 - 0.85 * blR;
    }
    setW("eyeWideLeft", wide); setW("eyeWideRight", wide);

    // Sourire de Duchenne : smileDuchenne si livré, sinon sourire + plissement + pommettes
    const smile = clamp(P.smile + duchPulse * 0.5, 0, 1.2);
    /* 30/10 : le smileDuchenne du .glb plisse fortement les yeux (arcs « heureux ») — réservé à la vraie
       joie (sourire ≥ 0,7 : done, celebrate, humeur joie, impulsion de validation) ; avant, dès 0,4 il
       laissait le panda les yeux mi-clos en écoute, réflexion, parole. */
    const duch = Math.max(sstep(0.7, 1.05, smile) * 0.85, duchPulse);
    if (has("smileDuchenne")) { setW("smileDuchenne", duch); setW("mouthSmileLeft", smile * 0.5 * (1 - duch)); setW("mouthSmileRight", smile * 0.5 * (1 - duch)); }
    else {
      setW("mouthSmileLeft", smile * 0.75); setW("mouthSmileRight", smile * 0.75);
      setW("cheekSquintLeft", duch * 0.6); setW("cheekSquintRight", duch * 0.6);
      setW("eyeSquintLeft", duch * 0.35); setW("eyeSquintRight", duch * 0.35);
    }
    if (smile < 0.2) { setW("mouthFrownLeft", (0.2 - smile) * 2); setW("mouthFrownRight", (0.2 - smile) * 2); }

    // Sourcils (L = gauche du personnage)
    setW("browOuterUpLeft", Math.max(0, P.browL) * 0.85); setW("browOuterUpRight", Math.max(0, P.browR) * 0.85);
    setW("browDownLeft", Math.max(0, -P.browL)); setW("browDownRight", Math.max(0, -P.browR));
    setW("browInnerUp", Math.max(browIn, Math.max(0, (P.browL + P.browR) / 2) * 0.6));

    // Parole : 4 canaux mesurés → vis_* (si livrés) + ARKit ; repli os de mâchoire
    const o = mouth.open * jawCut, s = mouth.spread, r = mouth.round, pz = Math.max(mouth.press, P.press);
    const jawV = clamp(Math.max(o * 0.85 + r * 0.2, P.jaw), 0, 1) * (1 - pz * 0.9);
    const visK = has("vis_A") || has("vis_O") || has("vis_I") ? 0.35 : 1;   // vis_* livrés : ARKit en appoint seulement
    setW("vis_A", o * (1 - s) * (1 - r)); setW("vis_E", s * sstep(0.2, 0.6, o)); setW("vis_I", s * (1 - sstep(0.2, 0.6, o)));
    setW("vis_O", r * sstep(0.15, 0.5, o)); setW("vis_U", r * (1 - sstep(0.15, 0.5, o))); setW("vis_MBP", pz);
    setW("mouthFunnel", r * 0.6 * visK); setW("mouthPucker", r * (1 - o) * 0.7 * visK);
    setW("mouthStretchLeft", s * 0.6 * visK); setW("mouthStretchRight", s * 0.6 * visK);
    setW("mouthPressLeft", pz * 0.8 * visK); setW("mouthPressRight", pz * 0.8 * visK); setW("mouthClose", pz * 0.4 * visK);
    if (has("jawOpen")) setW("jawOpen", jawV);
    else if (B.jaw) rotModel(B.jaw, jawV * 0.32 * mot, 0, 0);

    // Oreilles : blendshapes earPerk/earDroop, sinon os ear_L/ear_R (petit frémissement asymétrique)
    const twL = n1(now * 0.9 * life + 41) * 0.12 * life, twR = n1(now * 0.8 * life + 57) * 0.12 * life;
    const perk = P.perk;
    if (has("earPerk_L") || has("earDroop_L")) {
      setW("earPerk_L", Math.max(0, perk + twL)); setW("earPerk_R", Math.max(0, perk + twR));
      setW("earDroop_L", Math.max(0, -perk - twL)); setW("earDroop_R", Math.max(0, -perk - twR));
    } else {
      rotModel(B.ear_L, (perk + twL) * 0.18 * SP.ear * mot, 0, -Math.max(0, -perk) * 0.35 * mot);
      rotModel(B.ear_R, (perk + twR) * 0.18 * SP.ear * mot, 0, Math.max(0, -perk) * 0.35 * mot);
    }
    // Queue : onde continue (plus vive chez le panda roux), fouet à l'arrivée, tourbillon en pirouette
    if (tails.length) {
      const amp = (red ? 0.07 : 0.03) * life + tailWhip * (red ? 0.45 : 0.15) + (spin ? 0.35 : 0);
      const f = red ? 1.6 : 1.0;
      for (let i = 0; i < tails.length; i++) rotModel(tails[i], 0, Math.sin(now * f * Math.PI * 2 * (tailWhip ? 2.2 : 1) - i * 0.6) * amp * ((i + 1) / tails.length), 0);
    }

    // Corps vivant permanent : les clips livrés sont quasi figés au repos (hanches/poitrine/bras à
    // 0° sur idle/listening, mesuré dans le GLB) — cette couche procédurale donne la vie corporelle
    // continue : respiration, transfert de poids, balancier des bras, micro-balancement du bassin.
    // Amplitudes faibles (≤ 3°), ajoutées APRÈS le mixer, jamais pendant un clip ponctuel (oneShot).
    if (!oneShot) {
      const bk = life * (state === "sleep" ? 0.45 : 1) * (poseProc ? 1 : 0.55);
      const brPh = now * Math.PI * 2 * SP.breath;
      const br = Math.sin(brPh);
      if (B.chest) rotModel(B.chest, br * 0.028 * bk, 0, Math.sin(now * 0.31) * 0.008 * bk);
      if (B.spine) rotModel(B.spine, br * 0.016 * bk, Math.sin(now * 0.23 + 1.7) * 0.02 * bk, 0);
      if (B.hips) rotModel(B.hips, 0, Math.sin(now * 0.45 + 0.6) * 0.05 * bk, Math.sin(now * 0.31) * 0.035 * bk);
      rig.position.y += br * 0.006 * bk;
      if (state !== "tool" && loopName !== "typing") {
        const sw = Math.sin(brPh + Math.PI) * 0.05 * bk;
        const out = 0.035 * bk + Math.sin(now * 0.9) * 0.012 * bk;
        if (B.upperArm_L) rotModel(B.upperArm_L, sw, 0, out);
        if (B.upperArm_R) rotModel(B.upperArm_R, -sw, 0, -out);
        if (B.foreArm_L) rotModel(B.foreArm_L, -0.04 * bk + Math.sin(brPh + 2.2) * 0.03 * bk, 0, 0);
        if (B.foreArm_R) rotModel(B.foreArm_R, -0.04 * bk + Math.sin(brPh + 2.9) * 0.03 * bk, 0, 0);
      }
    }

    // Accessoires par état (pop d'échelle 0,6 → 1)
    for (const n in accs) {
      const a = accs[n];
      a.k = damp(a.k, (S.acc || (state === "speaking" && loopName === "typing" ? "acc_laptop" : "")) === n ? 1 : 0, 9, dt);
      a.o.visible = a.k > 0.02;
      if (!a.skinned) a.o.scale.copy(a.s0).multiplyScalar(0.6 + 0.4 * sstep(0, 1, a.k));
    }

    // 2) Écriture des blendshapes : max(clip, moteur) pour les maillages animés par un clip
    MT.forEach((list, name) => {
      if (!ownNames.has(name)) return;
      const v = W[name] || 0;
      for (let i = 0; i < list.length; i++) {
        const { m, i: idx } = list[i];
        m.morphTargetInfluences[idx] = clipMorphMeshes.has(m.name) && !MOUTH_RE.test(name) ? Math.max(m.morphTargetInfluences[idx], v) : v;
      }
      W[name] = 0;
    });
  }

  let last = performance.now() / 1000, acc = 0;
  function frame(now) {
    if (dead) return;
    if (!visible || document.hidden) { last = now; acc = 0; return; }
    /* 30/10 : un fondu de clips en cours ou un état tout juste entré (< 0,6 s) = transition → 60 i/s, même
       vers le sommeil (aucun fondu saccadé) ; un geste spontané du repos (fidget) reste à 30 i/s. */
    const fid = !!fidget && oneShot === fidget;
    const trans = fading || stateT < 0.6;
    const active = state === "speaking" || state === "tool" || state === "done" || state === "celebrate" || hopY > 0 || hops.length > 0 || (imp.length > 0 && !fid) || (!!oneShot && !fid) || Math.abs(squashV) > 0.08 || (trans && !fid);
    let bgApp = false; try { bgApp = !IS_COMPANION_PAGE && !document.hasFocus(); } catch (e) {}
    /* 29/10 (fluidité) : repos partagé (html[data-idle], 10 s sans geste — shell.js) et aucune animation
       propre en cours → respiration/regard à 15 i/s au lieu de 30, sommeil à 6 ; la pleine cadence revient
       au premier geste, à la parole et à tout changement d'état (active). Le compagnon du bureau garde son rythme. */
    const idleUi = !IS_COMPANION_PAGE && !active && !fid && document.documentElement.dataset.idle === "1";
    const fps = bgApp ? 4 : active ? 60 : state === "sleep" ? (idleUi ? 6 : 10) : fid ? 30 : idleUi ? 15 : 30;   /* 29/10 : Nova derrière une autre app → 4 images/s (le compagnon du bureau garde son rythme) */
    acc += now - last;
    last = now;
    if (acc < 1 / fps - 0.002) return;
    const step = Math.min(acc, 0.1);
    acc = 0;
    const t0 = performance.now();
    update(now, step);
    renderer.render(scene, cam);
    const ms = performance.now() - t0;
    gltfStats.frames++;
    gltfStats.last = ms;
    gltfStats.ms = gltfStats.ms ? gltfStats.ms * 0.9 + ms * 0.1 : ms;
  }

  const touch = () => { if (!document.documentElement.hasAttribute("data-vide")) lastAct = performance.now() / 1000; };
  const api = {
    setState(st) {
      if (dead || !STATES[st]) return;
      touch();
      if (st === state) return;
      const prev = state;
      state = st;
      stateT = 0;
      enterState(st, prev);
    },
    setMood(m) { if (!dead && MOODS[m]) mood = m; },
    setLevel(v) { level = clamp(+v || 0, 0, 1); },
    setViseme(v) {
      if (dead || !v) return;
      vis.open = clamp(+v.open || 0, 0, 1);
      vis.spread = clamp(+v.spread || 0, 0, 1);
      vis.round = clamp(+v.round || 0, 0, 1);
      vis.press = clamp(+v.press || 0, 0, 1);
      vis.t = performance.now() / 1000;
    },
    setVisemeSource(fn) { visSrc = typeof fn === "function" ? fn : null; },
    lookAt(x, y) { ptr.x = clamp(+x || 0, -1, 1); ptr.y = clamp(+y || 0, -1, 1); ptrT = performance.now() / 1000; },
    setFocus(x, y) {
      if (x == null) { focus.on = false; return; }
      focus.on = true;
      focus.x = clamp(+x || 0, -1, 1);
      focus.y = clamp(+y || 0, -1, 1);
    },
    react(kind) {
      if (dead) return;
      const now = performance.now() / 1000;
      if (!document.documentElement.hasAttribute("data-vide")) { lastAct = now; if (state === "sleep" && kind !== "nod") api.setState("idle"); }
      const k = String(kind || "");
      if (k === "nod") imp.push({ k: "nod", t0: now, d: 0.85, clip: playOnce("nod") });
      else if (k === "validate" || k === "wink") {
        imp.push({ k: "wink", t0: now, d: 0.9, clip: playOnce("wink") });
        if (k === "validate") { duchPulse = 1; jump(0.5, 0.12); }
      } else if (k === "wave") imp.push({ k: "wave", t0: now, d: 1.5, clip: playOnce("talk_gesture_A") });
      else if (k === "celebrate_small" || k === "small") { if (!playOnce("celebrate_small")) jump(0.9, 0.1); duchPulse = 1; }
      else if (k === "celebrate_big" || k === "big") { if (!playOnce("celebrate_big")) { jump(1.4, 0.16); spinT0 = now + 0.24; } whipT0 = now + 0.24; duchPulse = 1; }
      else if (k === "arrival" || k === "arrive_tail" || k === "whip") {
        const c = red && playOnce("arrive_tail");
        if (!c) imp.push({ k: "whip", t0: now, d: 1.0 });
        if (k === "arrival") jump(0.8, 0.1);
      } else if (k === "surprise") {
        imp.push({ k: "surprise", t0: now, d: 0.9 });
        vis.t = -10;
        level = 0;
        mouth.open *= 0.2;
      }
    },
    setTheme() { if (!dead) applyTheme(); },
    get state() { return state; },
    get species() { return red ? "renard" : "panda"; },
    /* Banc (Playwright, Réglages > diagnostic) : lecture seule de l'état interne, jamais utilisé par l'app */
    _debug() { return { scene, cam, renderer, model, mixer, MT, clips, B, loop: loopName, oneShot, weights: [...acts].map(([n, e]) => [n, +e.w.toFixed(2)]) }; },
    snapshot() {
      if (dead) return "";
      renderer.render(scene, cam);
      return cv.toDataURL("image/png");
    },
    destroy() {
      if (dead) return;
      dead = true;
      TICKER.subs.delete(frame);
      try { if (host.__avatarEngine === api) delete host.__avatarEngine; } catch (e) {}
      io.disconnect();
      ro.disconnect();
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("nova:theme", onTheme);
      try { mixer.removeEventListener("finished", onFinished); mixer.stopAllAction(); mixer.uncacheRoot(model); } catch (e) {}
      disposeGltf(gltf);
      try { shGeo.dispose(); shMat.dispose(); shTex.dispose(); envRT.dispose(); } catch (e) {}
      disposeRenderer(renderer);
    },
  };

  const onMove = (e) => {
    if (dead) return;
    const b = host.getBoundingClientRect();
    if (!b.width) return;
    api.lookAt((e.clientX - (b.left + b.width / 2)) / Math.max(320, window.innerWidth * 0.5), -(e.clientY - (b.top + b.height * 0.35)) / Math.max(240, window.innerHeight * 0.5));
    if (document.documentElement.hasAttribute("data-vide")) return;
    lastAct = performance.now() / 1000;
    if (state === "sleep") api.setState("idle");
  };
  let themeTimer = 0;
  const onTheme = () => { clearTimeout(themeTimer); themeTimer = setTimeout(() => { if (!dead) applyTheme(); }, 50); };
  window.addEventListener("pointermove", onMove, { passive: true });
  window.addEventListener("nova:theme", onTheme);

  resize();
  enterState("idle", "");
  update(performance.now() / 1000, 1 / 30);
  renderer.render(scene, cam);
  TICKER.add(frame);
  try { host.__avatarEngine = api; } catch (e) {}   // banc / diagnostic (lecture seule)
  return api;
}
