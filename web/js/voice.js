/* Nova 2 — la voix de la conversation (chantier conversation).
   Le moteur savait déjà parler et écouter (Voice.swift : POST /api/tts voix système en flux,
   PCM 24 kHz si le client annonce « Accept: audio/pcm », repli annoncé par l'en-tête
   X-Nova-Voice ; POST /api/stt Muse Voice Transcribe, Meta) — mais AUCUNE
   surface web ne l'appelait. Ce module est le chaînon manquant, côté client uniquement :

   - speak(texte) : lit le flux PCM au fil de l'eau (Web Audio, buffers planifiés) — le
     premier son part dès le premier paquet, pas après la génération complète. Le niveau
     RÉEL du signal est mesuré (AnalyserNode) et poussé vers l'avatar (bouche du panda).
     Si le moteur répond en MP3/WAV (repli), on décode et on joue par le même graphe.
   - listen() : micro (MediaRecorder) → /api/stt → texte. Push-to-talk : l'appelant
     démarre et arrête ; le niveau micro alimente aussi l'avatar pendant l'écoute.
   - Barge-in : stopSpeaking() coupe le flux, les buffers planifiés et le gain, aussitôt.
   - Latences MESURÉES (performance.now), jamais estimées : chaque tour vocal rapporte
     { kind, firstByteMs, firstSoundMs | ms, totalMs } via onLatency — l'honnêteté des
     chiffres fait partie du produit.
   Aucun niveau inventé : silence = niveau 0. Aucune erreur silencieuse : si le moteur
   dit « voix indisponible » (503, raison dans le corps), l'erreur remonte avec sa raison. */
import { bus, reportError, sse } from "./core.js";

/* Sépare le bi-canal du mode vocal : <PARLE> (lu à voix haute) et <DÉTAIL> (affiché).
   Miroir de Persona.stripBiChannel (Store.swift) — mais ici on SÉPARE au lieu d'aplatir :
   seul « parle » part au TTS ; l'affichage passe par md() qui retire déjà les balises.
   Sans balises (réponse écrite ordinaire), tout le texte est « parle » si on choisit de
   le lire, après nettoyage léger du markdown. */
export function parseBiChannel(t) {
  const s = String(t || "");
  const grab = (open, close) => {
    const o = s.search(new RegExp(open, "i")); if (o < 0) return null;
    const rest = s.slice(o + open.length);
    const m = rest.search(new RegExp(close, "i"));
    return (m < 0 ? rest : rest.slice(0, m)).trim();
  };
  const parle = grab("<PARLE>", "</PARLE>");
  if (parle === null) return { parle: speakable(s), detail: "", bic: false };
  const detail = grab("<DÉTAIL>", "</DÉTAIL>") ?? grab("<DETAIL>", "</DETAIL>") ?? "";
  return { parle, detail, bic: true };
}
/* Texte « disible » : le markdown d'écran ne se lit pas (« étoile étoile ») ; on le retire
   grossièrement pour la lecture des réponses écrites (bouton « Lire »). */
export function speakable(t) {
  return String(t || "")
    .replace(/```[\s\S]*?```/g, " (bloc de code à l'écran) ")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/\*\*([^*]+)\*\*/g, "$1").replace(/\*([^*]+)\*/g, "$1")
    .replace(/^#{1,4}\s+/gm, "")
    .replace(/^\s*[-•]\s+/gm, "")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/\s+/g, " ").trim();
}

/* ── VOIX FIABLE (vague 2, 24/10) ───────────────────────────────────────────
   Réglages lus au moteur (GET /api/voix/reglages, cache 30 s) : moteur « apple »
   (défaut) = dictée NATIVE du Mac en flux (POST /api/voix/dictee/start|stop,
   texte partiel et niveau sur le bus « voix_dictee », vocabulaire personnel,
   correction des noms/sigles/montants) ; enregistrement
   puis transcription haute précision (POST /api/voix/transcrire). Si la voie
   native est refusée (droit, langue absente, moteur ancien), on retombe sur
   l'enregistrement — jamais d'échec muet. Indicateur premium .vx-pill (onde de
   niveau RÉEL, « J'écoute… » / « Je transcris… », texte partiel). */
const VX_DEFAULTS = { moteur: "apple", langue: "fr-FR", pause_ms: 1400, phrases_attente: false };   /* 25/10 : phrases d'attente coupées par défaut */
let vxReg = null, vxRegAt = 0;
export async function voixReglages(force) {
  if (!force && vxReg && performance.now() - vxRegAt < 30000) return vxReg;
  try {
    const r = await fetch("/api/voix/reglages");
    if (r.ok) { const j = await r.json(); if (j && j.moteur) { vxReg = j; vxRegAt = performance.now(); } }
  } catch (e) {}
  return vxReg || VX_DEFAULTS;
}
const vxSleep = (ms) => new Promise((res) => setTimeout(res, ms));

/* Indicateur de dictée : pastille flottante, hors flux, jamais au-dessus d'une saisie.
   V6-COMPAGNON (25/10, « le cadran est décalé ») : l'ancrage lisait document.activeElement —
   or WebKit ne donne PAS le focus à un bouton cliqué : sans champ focalisé, la pastille
   tombait au centre de la FENÊTRE (left: 50 %, bottom: 96 px), donc décalée à gauche et
   par-dessus les boutons du composeur en vue scindée (550 px). Désormais l'ancre est
   explicite (option `anchor` : élément ou fonction → élément, fournie par le composeur),
   sinon le composeur du dernier élément pressé, sinon celui du champ focalisé ; la pastille
   prend la largeur et le centre de CE composeur, se pose juste au-dessus (ou à l'intérieur,
   en haut, s'il n'y a pas la place) et le suit pendant toute l'écoute (redimensionnement,
   défilement, vue scindée). Le niveau vient du micro réel. */
let vxLastPress = null;
if (typeof document !== "undefined") {
  try { document.addEventListener("pointerdown", (e) => { vxLastPress = e.target; }, true); } catch (e) {}
}
const VX_BOX_SEL = ".composer, .cs-composer, .qk-card, [data-vx-anchor]";
function vxFindBox(start) {
  let n = start;
  if (n && n.nodeType !== 1) n = n.parentElement;
  if (n && n.closest) { const c = n.closest(VX_BOX_SEL); if (c) return c; }
  for (let k = 0; n && n !== document.body && k < 8; k++, n = n.parentElement) {
    if (n.querySelector && n.querySelector("textarea, input[type=text], [contenteditable=true]")) return n;
  }
  return null;
}
export function vxResolveAnchor(anchor) {
  try {
    const a = typeof anchor === "function" ? anchor() : anchor;
    if (a && a.nodeType === 1 && a.isConnected) return a;
  } catch (e) {}
  const press = vxLastPress && vxLastPress.isConnected ? vxFindBox(vxLastPress) : null;
  if (press) return press;
  return document.activeElement && document.activeElement !== document.body ? vxFindBox(document.activeElement) : null;
}
/* Place la pastille sur son ancre : centre et largeur du composeur, au-dessus ; à l'intérieur (haut)
   si l'espace au-dessus manque (panneau d'accès rapide). Sans ancre : bas de fenêtre centré (CSS). */
export function vxPlace(el, box) {
  if (!el) return;
  if (!box || !box.isConnected) { el.style.left = ""; el.style.bottom = ""; el.style.top = ""; el.style.maxWidth = ""; el.dataset.anchored = "0"; return; }
  const rc = box.getBoundingClientRect();
  if (!(rc.width > 0 && rc.height > 0)) return;
  const vw = window.innerWidth, vh = window.innerHeight;
  const maxW = Math.max(160, Math.min(560, rc.width - 16, vw - 16));
  el.style.maxWidth = Math.round(maxW) + "px";
  const half = Math.min(el.offsetWidth || maxW, maxW) / 2;
  const cx = Math.min(vw - 8 - half, Math.max(8 + half, rc.left + rc.width / 2));
  el.style.left = Math.round(cx) + "px";
  const ph = el.offsetHeight || 44;
  if (rc.top - ph - 10 >= 4) { el.style.top = "auto"; el.style.bottom = Math.round(vh - rc.top + 8) + "px"; el.dataset.anchored = "dessus"; }
  else { el.style.bottom = "auto"; el.style.top = Math.round(Math.max(4, rc.top + 6)) + "px"; el.dataset.anchored = "dedans"; }
}
export function vxIndicator(anchor) {
  if (typeof document === "undefined" || !document.body) return null;
  const el = document.createElement("div");
  el.className = "vx-pill";
  el.setAttribute("role", "status");
  el.setAttribute("aria-live", "polite");
  const wave = document.createElement("span"); wave.className = "vx-wave"; wave.setAttribute("aria-hidden", "true");
  const N = 14, bars = [], hist = new Array(N).fill(0);
  for (let i = 0; i < N; i++) { const b = document.createElement("i"); b.className = "vx-bar"; wave.appendChild(b); bars.push(b); }
  const txt = document.createElement("span"); txt.className = "vx-txt";
  const st = document.createElement("b"); st.className = "vx-etat"; st.textContent = "J'écoute…";
  const part = document.createElement("span"); part.className = "vx-part";
  txt.append(st, part);
  el.append(wave, txt);
  document.body.appendChild(el);
  const box = vxResolveAnchor(anchor);
  let closed = false, raf = 0, lastSig = "";
  /* suivi de l'ancre pendant l'écoute : une lecture de rectangle par image, placement seulement si elle a bougé */
  const follow = () => {
    raf = 0;
    if (closed) return;
    try {
      const b = box && box.isConnected ? box.getBoundingClientRect() : null;
      const sig = b ? [b.left, b.top, b.width, b.height, window.innerWidth, window.innerHeight, el.offsetWidth].map(Math.round).join(",") : "x";
      if (sig !== lastSig) { lastSig = sig; vxPlace(el, box); }
    } catch (e) {}
    raf = requestAnimationFrame(follow);
  };
  try { vxPlace(el, box); } catch (e) {}
  raf = requestAnimationFrame(follow);
  requestAnimationFrame(() => el.classList.add("on"));
  return {
    el,
    anchor: () => box,
    level(v) {
      if (closed) return;
      hist.shift(); hist.push(Math.max(0, Math.min(1, Number(v) || 0)));
      for (let i = 0; i < N; i++) bars[i].style.transform = "scaleY(" + (0.12 + hist[i] * 0.88).toFixed(3) + ")";
    },
    state(s) {
      if (closed) return;
      el.dataset.etat = s;
      st.textContent = s === "transcription" ? "Je transcris…" : s === "erreur" ? "Écoute interrompue" : "J'écoute…";
    },
    partial(t) {
      if (closed) return;
      const s = String(t || "").replace(/\s+/g, " ").trim();
      part.textContent = s.length > 110 ? "…" + s.slice(-110) : s;
      el.classList.toggle("has-part", !!s);
    },
    close() {
      if (closed) return; closed = true;
      if (raf) { cancelAnimationFrame(raf); raf = 0; }
      el.classList.remove("on");
      setTimeout(() => { try { el.remove(); } catch (e) {} }, 260);
    },
  };
}

/* V4-B — SORTIES VOCALES OBSERVABLES : chaque voix crée ici son AnalyserNode de sortie (le TTS
   la voix en flux passe par master → analyser → destination). avatar.js lit ce registre pour
   calculer les visèmes (3 bandes spectrales) à 60 fps pendant que la voix parle RÉELLEMENT. */
const VOICE_OUTS = new Set();
export function voiceOutputs() { return VOICE_OUTS; }

/* 25/10 : lip-sync du compagnon — le niveau de NOTRE lecture TTS est relayé au moteur
   (POST /api/voix/niveau), qui le republie sur le bus « voix_niveau » pour la WebView séparée
   du compagnon (companion-float.js). ~9/s, seulement pendant la parole ; un seul 0 au silence. */
let relayLast = 0, relayZeroSent = true;
function relayLevel(lv) {
  const now = Date.now();
  if (!(lv > 0.01)) { if (relayZeroSent) return; relayZeroSent = true; lv = 0; }
  else { if (now - relayLast < 100) return; relayZeroSent = false; }
  relayLast = now;
  try {
    fetch("/api/voix/niveau", { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ niveau: Math.round(lv * 100) / 100 }), keepalive: true }).catch(() => {});
  } catch (e) {}
}

export function createVoice({ onLevel, onState, onLatency, onEngine, onPartial, onAutoEnd, indicator = true, anchor = null } = {}) {
  let ac = null;              // AudioContext (créé au premier geste)
  let master = null, analyser = null, micAnalyser = null;
  let speakCtl = null;        // AbortController du fetch TTS en cours
  let scheduled = [];         // BufferSourceNodes planifiés (à couper au barge-in)
  let speaking = false, engine = "";
  let rec = null, recStream = null, recChunks = [], recMime = "", recT0 = 0, recTimer = 0;
  let listening = false;
  let levelTimer = 0;
  let outRec = null;          // V4-B : entrée de cette voix dans le registre des sorties observables
  let mode = "", ind = null, unsubNat = null, natT0 = 0, lastPartial = "";
  const buf = new Uint8Array(512);

  function graph() {
    if (ac) return ac;
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) throw new Error("Web Audio indisponible dans cette WebView.");
    ac = new AC();
    master = ac.createGain(); master.gain.value = 1;
    analyser = ac.createAnalyser(); analyser.fftSize = 1024;
    analyser.smoothingTimeConstant = 0.45;   // V4-B : spectre réactif pour les visèmes (le niveau temporel n'est pas lissé par ce réglage)
    master.connect(analyser); analyser.connect(ac.destination);
    outRec = { an: analyser, ctx: ac, active: () => speaking && scheduled.length > 0 };
    VOICE_OUTS.add(outRec);
    levelTimer = setInterval(() => {
      if (listening && mode === "natif") return;   // niveau natif : poussé par le bus « voix_dictee »
      const an = (listening && micAnalyser) ? micAnalyser : analyser;   // niveau de la source ACTIVE (micro pendant l'écoute, TTS pendant la parole)
      if (!an || (!speaking && !listening)) { if (onLevel) onLevel(0); relayLevel(0); return; }
      an.getByteTimeDomainData(buf);
      let sum = 0; for (let i = 0; i < buf.length; i += 2) { const v = (buf[i] - 128) / 128; sum += v * v; }
      const lv = Math.min(1, Math.sqrt(sum / (buf.length / 2)) * 3.2);
      if (onLevel) onLevel(lv);
      if (speaking && !listening) relayLevel(lv);   // 25/10 : bouche du compagnon (TTS seulement, jamais le micro)
      if (listening && ind) ind.level(lv);
    }, 110);
    return ac;
  }
  function levelFrom(stream) {   // niveau micro pendant l'écoute — SANS retour haut-parleur :
    // le micro allait dans `analyser`, relié à ac.destination → Ahadi s'entendait en direct
    // (monitoring). Ici : analyseur micro dédié, raccordé à la destination par un gain à
    // ZÉRO (le graphe reste tiré par la sortie, l'analyseur reçoit les données, rien ne sonne).
    const src = ac.createMediaStreamSource(stream);
    const an = ac.createAnalyser(); an.fftSize = 1024;
    const mute = ac.createGain(); mute.gain.value = 0;
    src.connect(an); an.connect(mute); mute.connect(ac.destination);
    micAnalyser = an;
    return () => { try { src.disconnect(); an.disconnect(); mute.disconnect(); } catch (e) {} if (micAnalyser === an) micAnalyser = null; };
  }

  /* ── Parole (TTS) ─────────────────────────────────────────────────────── */
  async function speak(text) {
    const clean = String(text || "").trim();
    if (!clean) return false;
    stopSpeaking();
    graph(); if (ac.state === "suspended") { try { await ac.resume(); } catch (e) {} }
    const t0 = performance.now();
    speakCtl = new AbortController();
    speaking = true; if (onState) onState("parole");
    let firstByte = 0, firstSound = 0;
    try {
      const r = await fetch("/api/tts", {
        method: "POST",
        headers: { "Content-Type": "application/json", "Accept": "audio/pcm" },
        body: JSON.stringify({ text: clean }), signal: speakCtl.signal,
      });
      engine = r.headers.get("X-Nova-Voice") || "";
      if (onEngine) onEngine(engine);
      if (!r.ok || !r.body) {
        let raison = ""; try { const j = await r.json(); raison = j.raison || j.error || ""; } catch (e) {}
        throw new Error("Voix indisponible" + (raison ? " : " + raison : " (HTTP " + r.status + ")"));
      }
      const ctype = (r.headers.get("Content-Type") || "").toLowerCase();
      if (ctype.includes("audio/pcm")) {
        /* Flux PCM 24 kHz 16 bits LE : on planifie les buffers au fil de l'eau. */
        const rd = r.body.getReader();
        /* 25/10 (Ahadi : « rendu saccadé ») — tampon anti-à-coups : on n'attaque qu'avec 0,45 s d'avance,
           et si le réseau prend du retard on se redonne 0,3 s au lieu de 30 ms (avant : 80 ms d'avance,
           chaque retard réseau = un trou audible). Petits morceaux regroupés (≥ 120 ms) avant planification. */
        let nextAt = 0, carry = null, ended = false, started = false;
        let pend = [], pendN = 0;
        const PRE = 0.45, REBUF = 0.3, MIN_CHUNK = 2880;   // 2 880 échantillons = 120 ms à 24 kHz
        const schedule = (f32) => {
          const b = ac.createBuffer(1, f32.length, 24000);
          b.getChannelData(0).set(f32);
          const src = ac.createBufferSource(); src.buffer = b; src.connect(master);
          if (nextAt < ac.currentTime + 0.02) nextAt = ac.currentTime + REBUF;
          src.start(nextAt); nextAt += b.duration; scheduled.push(src);
          if (!firstSound) { firstSound = performance.now() - t0; }
          src.onended = () => { scheduled = scheduled.filter((x) => x !== src); };
        };
        const flush = (force) => {
          if (!pendN) return;
          if (!started && !force && pendN < 24000 * PRE) return;
          if (started && !force && pendN < MIN_CHUNK) return;
          const all = new Float32Array(pendN); let o = 0;
          for (const p of pend) { all.set(p, o); o += p.length; }
          pend = []; pendN = 0;
          if (!started) { started = true; nextAt = ac.currentTime + 0.05; }
          schedule(all);
        };
        const playBuf = (f32) => { pend.push(f32); pendN += f32.length; flush(false); };
        while (!ended) {
          const { done, value } = await rd.read();
          if (done) break;
          if (!firstByte) firstByte = performance.now() - t0;
          let bytes = value;
          if (carry) { const m = new Uint8Array(carry.length + bytes.length); m.set(carry); m.set(bytes, carry.length); bytes = m; carry = null; }
          const even = bytes.length - (bytes.length % 2);
          if (even < bytes.length) carry = bytes.slice(even);
          if (even > 0) {
            const i16 = new Int16Array(bytes.buffer, bytes.byteOffset, even / 2);
            const f32 = new Float32Array(i16.length);
            for (let i = 0; i < i16.length; i++) f32[i] = i16[i] / 32768;
            playBuf(f32);
          }
        }
        flush(true);
        const waitMs = Math.max(0, (nextAt - ac.currentTime) * 1000);
        await new Promise((res) => setTimeout(res, waitMs));
      } else {
        /* Repli MP3/WAV : corps complet, décodé, joué par le même graphe. */
        const ab = await r.arrayBuffer();
        if (!firstByte) firstByte = performance.now() - t0;
        const b = await ac.decodeAudioData(ab);
        const src = ac.createBufferSource(); src.buffer = b; src.connect(master);
        scheduled.push(src); firstSound = performance.now() - t0;
        await new Promise((res) => { src.onended = () => { scheduled = scheduled.filter((x) => x !== src); res(); }; src.start(); });
      }
      if (onLatency) onLatency({ kind: "tts", engine, firstByteMs: Math.round(firstByte), firstSoundMs: Math.round(firstSound), totalMs: Math.round(performance.now() - t0), chars: clean.length });
      return true;
    } catch (e) {
      if (e && e.name === "AbortError") return false;   // barge-in : pas une erreur
      reportError(e, "tts", true);
      throw e;
    } finally {
      speaking = false; speakCtl = null;
      if (onLevel) onLevel(0);
      if (onState) onState("repos");
    }
  }
  function stopSpeaking() {
    if (speakCtl) { try { speakCtl.abort(); } catch (e) {} speakCtl = null; }
    for (const s of scheduled) { try { s.onended = null; s.stop(); } catch (e) {} }
    scheduled = [];
    if (speaking) { speaking = false; if (onLevel) onLevel(0); if (onState) onState("repos"); }
  }

  /* ── Écoute (STT) ─────────────────────────────────────────────────────── */
  let silTimer = 0;   /* 25/10 : fin de dictée sur silence */
  function openInd() { if (indicator && !ind) ind = vxIndicator(anchor); if (ind) { ind.state("ecoute"); ind.partial(""); } }
  function closeInd() { if (ind) { ind.close(); ind = null; } }
  async function nativeStart() {
    let r, j = {};
    try {
      r = await fetch("/api/voix/dictee/start", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
      j = await r.json().then((x) => (x && typeof x === "object" ? x : {}), () => ({}));   // V5-N : un corps « null » ne lève plus « Cannot read properties of null »
    } catch (e) { return false; }
    if (!r || !r.ok || !j || j.ok !== true) return false;
    mode = "natif"; listening = true; natT0 = performance.now(); lastPartial = "";
    unsubNat = bus.on("voix_dictee", (d) => {
      if (!d || typeof d !== "object" || mode !== "natif") return;
      if (typeof d.niveau === "number") { if (onLevel) onLevel(d.niveau); if (ind) ind.level(d.niveau); }
      if (typeof d.partiel === "string") {
        lastPartial = d.partiel; if (ind) ind.partial(d.partiel); if (onPartial) onPartial(d.partiel);
        /* 25/10 : envoi tout seul quand Ahadi se tait (1,8 s sans nouveau mot) — plus besoin de recliquer. */
        clearTimeout(silTimer);
        if (String(d.partiel).trim()) silTimer = setTimeout(() => { if (listening && mode === "natif" && typeof onAutoEnd === "function") { try { onAutoEnd(); } catch (e) {} } }, 2800);   /* 26/10 : 2,8 s (1,8 s coupait les hésitations) — l'appelant transcrit ET envoie */
      }
      if (d.etat === "transcription" && ind) ind.state("transcription");
      if (d.etat === "erreur" && ind) { ind.state("erreur"); if (d.erreur) ind.partial(d.erreur); }
    });
    openInd();
    if (onEngine) onEngine("apple");
    if (onState) onState("ecoute");
    clearTimeout(recTimer);
    recTimer = setTimeout(() => { if (listening && mode === "natif") listenStop().catch(() => {}); }, 300000);   // garde-fou : 5 min
    return true;
  }
  /* V6-COMPAGNON (25/10, « on n'arrive pas à envoyer ») : l'arrêt de la dictée native ne peut plus
     laisser l'écoute coincée. Délai borné (12 s), annulation du côté moteur sur tout échec (le micro
     est rendu), et si la transcription finale échoue alors qu'un texte partiel a été entendu, c'est
     ce texte partiel qui est rendu — jamais une dictée perdue. */
  const vxPost = (path, ms) => {
    const ctl = typeof AbortController !== "undefined" ? new AbortController() : null;
    const t = ctl ? setTimeout(() => { try { ctl.abort(); } catch (e) {} }, ms) : 0;
    return fetch(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}", signal: ctl ? ctl.signal : undefined })
      .finally(() => { if (t) clearTimeout(t); });
  };
  async function nativeStop() {
    const tStop = performance.now();
    clearTimeout(recTimer); clearTimeout(silTimer);
    if (ind) ind.state("transcription");
    listening = false;
    const heard = String(lastPartial || "").trim();
    let r = null, j = {}, err = "";
    try {
      r = await vxPost("/api/voix/dictee/stop", 12000);
      j = await r.json().then((x) => (x && typeof x === "object" ? x : {}), () => ({}));   // V5-N : un corps « null » ne lève plus « Cannot read properties of null »
    } catch (e) {
      err = e && e.name === "AbortError" ? "le moteur n'a pas rendu la dictée à temps" : String((e && e.message) || e);
    } finally {
      if (unsubNat) { try { unsubNat(); } catch (e) {} unsubNat = null; }
      mode = ""; closeInd();
      if (onLevel) onLevel(0); if (onState) onState("repos");
    }
    const ok = !!(r && r.ok && j && j.ok === true);
    if (!ok) { try { vxPost("/api/voix/dictee/annuler", 4000).catch(() => {}); } catch (e) {} }
    let t = ok ? String(j.text || "").trim() : "";
    if (!t && heard) t = heard;   // repli honnête : ce qui a été entendu et affiché en partiel
    if (!t) {
      if (!ok) throw new Error("Transcription impossible : " + (err || (j && (j.erreur || j.error)) || ("HTTP " + (r ? r.status : "?"))));
      throw new Error("Aucune parole reconnue — réessaie en parlant près du micro.");
    }
    if (onLatency) onLatency({ kind: "stt", engine: (ok && j.moteur) || "apple", ms: Math.round(performance.now() - tStop), recMs: Math.round(tStop - natT0), bytes: 0, chars: t.length, partial: !ok });
    return t;
  }
  /* Abandon franc (Échap, fermeture) : rien n'est transcrit, le micro est rendu, l'état revient au repos. */
  function cancelListen() {
    clearTimeout(recTimer);
    if (listening && mode === "natif") { try { vxPost("/api/voix/dictee/annuler", 4000).catch(() => {}); } catch (e) {} }
    if (unsubNat) { try { unsubNat(); } catch (e) {} unsubNat = null; }
    if (rec) { try { rec.onstop = null; rec.stop(); } catch (e) {} if (rec._unLevel) { try { rec._unLevel(); } catch (e) {} } rec = null; }
    if (recStream) { try { recStream.getTracks().forEach((t) => t.stop()); } catch (e) {} recStream = null; }
    const was = listening;
    listening = false; mode = ""; lastPartial = "";
    closeInd();
    if (onLevel) onLevel(0);
    if (was && onState) onState("repos");
  }
  async function listenStart() {
    if (listening) return false;
    /* Écho : Nova se tait d'abord, et on laisse mourir la queue de sa voix (≈ 0,2 s)
       avant d'ouvrir le micro — sinon sa dernière phrase est transcrite. Appuyer sur le
       micro pendant qu'elle parle EST le barge-in volontaire. */
    if (speaking || scheduled.length) { stopSpeaking(); await vxSleep(220); }
    const reg = await voixReglages();
    if (await nativeStart()) return true;
    mode = "enreg";
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia || typeof MediaRecorder === "undefined")
      throw new Error("Micro indisponible dans cette WebView (MediaRecorder absent).");
    graph(); if (ac.state === "suspended") { try { await ac.resume(); } catch (e) {} }
    recStream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } });   // refus TCC = erreur nommée par le navigateur ; l'annulation d'écho empêche la parole de Nova (haut-parleurs) d'être recaptée pendant la conversation
    recMime = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4", "audio/ogg"].find((m) => { try { return MediaRecorder.isTypeSupported(m); } catch (e) { return false; } }) || "";
    recChunks = [];
    rec = new MediaRecorder(recStream, recMime ? { mimeType: recMime } : undefined);
    rec.ondataavailable = (e) => { if (e.data && e.data.size) recChunks.push(e.data); };
    recT0 = performance.now();
    rec.start(250);
    listening = true; if (onState) onState("ecoute");
    openInd();
    var unLevel = levelFrom(recStream);
    rec._unLevel = unLevel;
    recTimer = setTimeout(() => { if (listening) listenStop().catch(() => {}); }, 120000);   // garde-fou : 2 min max
    return true;
  }
  async function listenStop() {
    if (listening && mode === "natif") return nativeStop();
    if (!listening || !rec) return "";
    const t0 = recT0;
    const blob = await new Promise((res) => {
      rec.onstop = () => res(new Blob(recChunks, { type: recMime || rec.mimeType || "audio/webm" }));
      try { rec.stop(); } catch (e) { res(new Blob(recChunks, { type: recMime || "audio/webm" })); }
    });
    clearTimeout(recTimer);
    if (rec._unLevel) rec._unLevel();
    if (recStream) recStream.getTracks().forEach((t) => t.stop());
    rec = null; recStream = null; listening = false; mode = "";
    if (onLevel) onLevel(0);
    if (!blob.size) { closeInd(); if (onState) onState("repos"); throw new Error("Aucun son capté — réessaie en parlant près du micro."); }
    if (ind) ind.state("transcription");
    const ts = performance.now();
    // FIX-STT : le corps Blob d'un fetch() se perd dans le transport nova://
    // (le moteur recevait 0 octet, 8 fois le 22/10) ; les corps TEXTE traversent
    // readBody sans perte (chat, TTS). L'audio part donc en base64 dans un
    // corps JSON — la route /api/stt décode et garde le binaire en repli.
    const buf = new Uint8Array(await blob.arrayBuffer());
    let bin = "";
    for (let i = 0; i < buf.length; i += 32768) bin += String.fromCharCode.apply(null, buf.subarray(i, i + 32768));
    const payload = JSON.stringify({ audio_b64: btoa(bin), type: blob.type || "audio/webm" });
    let r = null, j = {};
    try {
      /* Vague 2 : /api/voix/transcrire (vocabulaire + correction, Muse Voice Transcribe) ;
         repli /api/stt si le moteur ne connaît pas encore la route. */
      r = await fetch("/api/voix/transcrire", { method: "POST", headers: { "Content-Type": "application/json" }, body: payload });
      if (r.status === 404) r = await fetch("/api/stt", { method: "POST", headers: { "Content-Type": "application/json" }, body: payload });
      j = await r.json().then((x) => (x && typeof x === "object" ? x : {}), () => ({}));   // V5-N : un corps « null » ne lève plus « Cannot read properties of null »
    } catch (e) { j = { error: String((e && e.message) || e) }; }
    finally { closeInd(); if (onState) onState("repos"); }
    if (!r || !r.ok || !j.text) {
      // Message VRAI : le moteur a reçu 0 octet alors que l'envoi en faisait
      // blob.size (> 0, garde ci-dessus) — panne de transport interne,
      // pas une panne des moteurs de transcription.
      if (j.audio_bytes != null && j.audio_bytes === 0)
        throw new Error("Transcription impossible : l'enregistrement n'est pas parvenu à Nova (panne de transport interne) — réessaie.");
      throw new Error("Transcription impossible : " + (j.error || ("HTTP " + (r ? r.status : "?"))) + (j.audio_bytes != null ? " [enregistrement reçu : " + j.audio_bytes + " octets, type " + (j.audio_type || blob.type || "?") + "]" : ""));
    }
    if (onLatency) onLatency({ kind: "stt", ms: Math.round(performance.now() - ts), recMs: Math.round(ts - t0), bytes: blob.size, chars: String(j.text).length });
    return String(j.text);
  }

  function dispose() {
    stopSpeaking();
    if (listening && mode === "natif") { try { fetch("/api/voix/dictee/annuler", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" }); } catch (e) {} }
    if (unsubNat) { try { unsubNat(); } catch (e) {} unsubNat = null; }
    closeInd(); listening = false; mode = "";
    if (recStream) recStream.getTracks().forEach((t) => t.stop());
    clearTimeout(recTimer); clearInterval(levelTimer);
    if (outRec) { VOICE_OUTS.delete(outRec); outRec = null; }
    if (ac) { try { ac.close(); } catch (e) {} ac = null; }
  }
  /* Phrase d'attente (conversation vocale écrite avec outils) : à appeler quand un outil
     démarre — la réponse, quand elle arrive, coupe la phrase (speak() interrompt). */
  async function speakFiller(outil) {
    const reg = await voixReglages();
    if (reg.phrases_attente === false || speaking) return false;
    return speak(vxFiller(outil)).catch(() => false);
  }
  return { speak, stopSpeaking, listenStart, listenStop, cancelListen, dispose, speakFiller,
           isSpeaking: () => speaking, isListening: () => listening, engine: () => engine,
           partial: () => lastPartial, mode: () => mode };
}

/* ── Conversation vocale LIVE (VL, 23/10) ──────────────────────────────────
   Le pipeline temps réel vit ENTIÈREMENT dans le moteur natif
   (Feat_VoiceLive.swift) : micro, VAD, transcription en flux, cerveau en
   flux, voix système en flux, lecture native interrompable à la voix
   (barge-in). Aucun audio ne transite par le web. Ce client ne fait que :
   démarrer/arrêter la session (POST /api/voix-live/start|stop), relayer les
   états du bus « voix_live » vers le panda — window.__novaPresence, la
   source d'état unique (avatar.js/shell.js) — et vers l'écran (onState /
   onEvent : partiels de transcription, fins de tour, niveaux). Un refus du
   moteur (interrupteur fermé, micro refusé, clé absente) remonte NOMMÉ. */
/* V6-COMPAGNON (25/10) — MISSIONS DE LA VOIX LIVE. Le cerveau du Live n'a pas d'outils (latence) ;
   quand une demande exige d'agir (mails, agenda, fichiers, web, Éclats…), il commence sa réponse par la
   balise <mission> (jamais dite : retirée avant la voix) et dit en une phrase qu'il lance la tâche. Le
   moteur publie alors voix_live {evenement: "mission", texte} ; la page qui tient la session Live lance
   ICI la demande par le chemin NORMAL de l'agent (POST /api/chat, tools: true — mêmes outils, mêmes
   cartes d'approbation, même garde « devant moi » pour la navigation), en arrière-plan, puis fait dire
   par la voix live un résumé court du résultat (POST /api/voix-live/annoncer — dit seulement si personne
   ne parle ; sinon le résultat reste dans le fil écrit). Aucun résultat n'est inventé : le résumé est
   extrait de la vraie réponse de l'agent. */
export function vxMissionSummary(text) {
  const t = speakable(parseBiChannel(String(text || "")).parle || "");
  if (!t) return "";
  const parts = t.match(/[^.!?…]+[.!?…]+(\s|$)|[^.!?…]+$/g) || [t];
  let out = "";
  for (const p of parts) { const q = p.trim(); if (!q) continue; if ((out + " " + q).trim().length > 260) break; out = (out + " " + q).trim(); if (out.length > 120) break; }
  if (!out) out = t.slice(0, 240).replace(/\s+\S*$/, "") + "…";
  return out;
}
/* 26/10 (audit voix) : plusieurs écouteurs Live (Conversations, panneau, compagnon) restaient branchés et lançaient
   chacun la même mission, puis l'annonçaient deux fois. Dédoublonnage GLOBAL au module + désabonnement sur « off ». */
const VX_MISSIONS = new Set();
function createVoiceLiveClassic({ onState, onEvent, missionConv, onMission } = {}) {
  let actif = false, unsub = null, etat = "off";
  const missions = VX_MISSIONS;
  function onBus(d) {
    if (!d || typeof d !== "object") return;
    if (d.etat) {
      etat = String(d.etat);
      if (d.etat === "off" && unsub) { try { unsub(); } catch (e) {} unsub = null; actif = false; }
      const st = d.etat === "off" ? "repos" : d.etat === "erreur" ? "error" : d.etat;
      if (window.__novaPresence) { try { window.__novaPresence(st, d.label || ""); } catch (e) {} }
      if (onState) onState(d.etat, d);
    }
    if (d.evenement === "mission" && typeof d.texte === "string" && d.texte.trim()) runMission(d.texte.trim(), d.tour);
    if (onEvent) onEvent(d);
  }
  async function runMission(text, tour) {
    const key = String(tour || "") + "|" + text;
    if (missions.has(key)) return;   // un même tour n'est lancé qu'une fois
    missions.add(key);
    let cid = "";
    try { cid = String((missionConv && missionConv()) || ""); } catch (e) { cid = ""; }
    const emit = (o) => { if (onMission) { try { onMission(o); } catch (e) {} } };
    emit({ phase: "start", text, cid });
    let acc = "", failed = "";
    try {
      const body = { text: "[Demande dite à voix haute en Nova Live — exécute-la avec tes outils, puis rends compte brièvement] " + text, tools: true };
      if (cid) body.conversation_id = cid;
      await sse("/api/chat", body, (ev, dd) => {
        dd = dd || {};
        if (ev === "meta" && dd.conversation_id) { cid = String(dd.conversation_id); emit({ phase: "meta", cid }); }
        else if (ev === "delta") acc += dd.t || "";
        else if (ev === "reset") acc = "";
        else if (ev === "confirm") emit({ phase: "confirm", confirm: dd, cid });
        else if (ev === "step") emit({ phase: "step", step: dd, cid });
        else if (ev === "error") failed = String(dd.message || "erreur du moteur");
      });
    } catch (e) { failed = String((e && e.message) || e); }
    /* 26/10 : le résultat est annoncé COMME résultat de la demande (plus de phrase « hors sujet » minutes plus tard), jamais d'erreur brute. */
    const ask = text.replace(/\s+/g, " ").slice(0, 70).replace(/\s+\S*$/, "");
    const sum0 = failed && !acc.trim() ? "" : vxMissionSummary(acc);
    const sum = failed && !acc.trim() ? "Ta demande « " + ask + " » n'a pas pu aboutir ; le détail est dans la conversation écrite." : (sum0 ? "Pour ta demande « " + ask + " » : " + sum0 : "");
    emit({ phase: "done", text: acc, summary: sum, ok: !failed, error: failed, cid });
    if (actif && sum) {
      try { await fetch("/api/voix-live/annoncer", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ text: sum }) }); } catch (e) {}
    }
  }
  async function start() {
    if (actif) return true;
    const r = await fetch("/api/voix-live/start", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
    const j = await r.json().then((x) => (x && typeof x === "object" ? x : {}), () => ({}));   // V5-N : un corps « null » ne lève plus « Cannot read properties of null »
    if (!r.ok || !j.ok) throw new Error("Conversation live refusée : " + (j.erreur || ("HTTP " + r.status)));
    unsub = bus.on("voix_live", onBus);
    actif = true; etat = "ecoute";
    if (onState) onState("ecoute", j);
    return true;
  }
  async function stop() {
    if (unsub) { try { unsub(); } catch (e) {} unsub = null; }
    actif = false; etat = "off";
    try { await fetch("/api/voix-live/stop", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" }); } catch (e) {}
    if (window.__novaPresence) { try { window.__novaPresence("repos", "Nova · au repos"); } catch (e) {} }
    if (onState) onState("repos", {});
  }
  async function interrompre() {
    try { await fetch("/api/voix-live/interrompre", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" }); } catch (e) {}
    // 27/10 : même fonction côté conversation inspectable (VoixConversation.interrompre).
    try { await fetch("/api/voix-conversation/interrompre", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" }); } catch (e) {}
  }
  return { start, stop, interrompre, actif: () => actif, etat: () => etat };
}

/* Phrases d'attente — miroir de VoixAttente (Feat_Voix2.swift) : variées, jamais deux fois
   la même de suite ; une phrase qui nomme une source n'est dite que si un outil la touche. */
let vxLastFiller = "";
export function vxFiller(outil) {
  const o = String(outil || "").toLowerCase();
  let pool = ["Une seconde…", "Voyons voir…", "Laisse-moi réfléchir une seconde…", "D'accord, je réfléchis…", "Je te dis ça tout de suite…"];
  if (o) {
    if (/mail|inbox|outlook|boite|boîte/.test(o)) pool = ["Je regarde ta boîte…", "Je jette un œil à tes mails…", "Je regarde tes messages…"];
    else if (/agenda|calendar|event|reunion|réunion/.test(o)) pool = ["Je regarde ton agenda…", "Je vérifie ton calendrier…"];
    else if (/web|search|recherche|fetch/.test(o)) pool = ["Je cherche ça…", "Je fais une recherche rapide…", "Je regarde en ligne…"];
    else if (/file|fichier|read|doc/.test(o)) pool = ["J'ouvre le fichier…", "Je regarde le document…"];
    else if (/brvm|bourse|portfolio|cours/.test(o)) pool = ["Je regarde les cours…", "Je vérifie ton portefeuille…"];
    else if (/teams/.test(o)) pool = ["Je regarde Teams…", "Je jette un œil à tes discussions…"];
    else pool = ["Je vérifie…", "Je regarde ça…", "Je m'en occupe…"];
  }
  const c = pool.filter((p) => p !== vxLastFiller);
  const pick = (c.length ? c : pool)[Math.floor(Math.random() * (c.length ? c.length : pool.length))];
  vxLastFiller = pick;
  return pick;
}


/* Version hackathon Meta — LIVE : moteur natif seul (reconnaissance vocale système macOS + cerveau Meta Spark +
   voix système macOS). Aucun moteur de voix tiers. */
export function createVoiceLive(opts = {}) {
  let impl = null;
  const classic = () => createVoiceLiveClassic(opts);
  return {
    async start() {
      if (impl && impl.actif()) return true;
      impl = classic();
      return impl.start();
    },
    async stop() { if (impl) return impl.stop(); },
    async interrompre() { if (impl) return impl.interrompre(); },
    actif: () => !!(impl && impl.actif()),
    etat: () => (impl ? impl.etat() : "off"),
  };
}
