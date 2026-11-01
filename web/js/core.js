// Utilitaires partagés (fenêtre principale + panneau flottant)
import { ic } from "./icons.js";
import { isHouse, houseHTML, houseSummary } from "./richtext.js";   // V5-W : format maison (STATUT / ## sections / À TOI) mis en page partout
import { normalizeAnswer, isNarration } from "./normalize.js";   // C1 (29/10) : rendu déterministe des réponses de Nova (fonction pure, testée sous Node)
export { normalizeAnswer, isNarration };
/* ── NOVA2 vague 3 (E3) : jeton du coffre, EN MÉMOIRE SEULEMENT ──────────────────
   Le protocole du moteur (Vault.swift) : le code ne voyage jamais ; l'interface dérive
   une empreinte PBKDF2 (vaultgate.js), l'échange contre un jeton de session (15 min),
   et présente ce jeton dans l'en-tête « x-vault ». Ici : le jeton vit dans une variable
   de module — jamais localStorage/sessionStorage — donc l'app démarre TOUJOURS
   verrouillée, et quitter un écran protégé le révoque (vaultgate.lock()). */
let vaultToken = "";
export function setVaultToken(t) { vaultToken = String(t || ""); }
export function hasVaultToken() { return !!vaultToken; }
const vaultHdr = () => (vaultToken ? { "x-vault": vaultToken } : {});
export const TV_CHECK_BOUND_MS = 20000;
const getInflight = new Map();   // V5-N : GET en vol, partagés (voir api.get)
/* NOVA2-FIX (bug démarrage 20/10) : AUCUN appel d'interface ne peut plus pendre
   indéfiniment — chaque fetch a un délai (GET 20 s, POST 150 s : la génération
   d'image Meta est lente par nature), dépassé = erreur NOMMÉE « délai dépassé »,
   que les écrans affichent avec un Réessayer au lieu d'un squelette éternel. */
async function fetchT(p, opts, timeoutMs) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), timeoutMs);
  try { return await fetch(p, { ...opts, signal: ctl.signal }); }
  catch (e) { if (e && e.name === "AbortError") throw new Error("délai dépassé (" + Math.round(timeoutMs / 1000) + " s) sur " + p); throw e; }
  finally { clearTimeout(t); }
}
export const api = {
  /* V5-N (optimisation mesurée) : DÉDOUBLONNAGE des GET simultanés. Au même instant (retour du flux
     /api/events, démarrage), 4 à 6 écrans et services demandaient la même route (/api/dots/waiting ×6,
     /api/drafts ×4…). Un GET identique (même chemin, même jeton de coffre, même délai) déjà en vol est
     partagé ; chaque appelant reçoit SA copie (JSON.parse du même texte) — aucun objet partagé, aucune
     mise en cache au-delà de la requête en cours, erreurs identiques à avant (statut HTTP, JSON illisible). */
  async get(p, timeoutMs = 20000) {
    const key = p + "\u0000" + vaultToken + "\u0000" + timeoutMs;
    let pr = getInflight.get(key);
    if (!pr) {
      pr = fetchT(p, { headers: vaultHdr() }, timeoutMs).then(async (r) => ({ ok: r.ok, status: r.status, text: r.ok ? await r.text() : "" }));
      getInflight.set(key, pr);
      const done = () => { if (getInflight.get(key) === pr) getInflight.delete(key); };
      pr.then(done, done);
    }
    const r = await pr;
    if (!r.ok) throw new Error(p + " → " + r.status);
    return JSON.parse(r.text);
  },
  /* LOT1-FIX C5 (systémique) : post REJETTE désormais sur erreur HTTP, comme get.
     Avant : un 400/403/404/500 JSON était RETOURNÉ comme un succès — patron racine
     des faux succès d'écran (faux « Envoyé », faux « lancé », réglages périmés en
     silence). L'erreur levée porte le statut et le message du moteur (j.error). */
  async post(p, b = {}, timeoutMs = 150000, hdrs = {}) { const r = await fetchT(p, { method: "POST", headers: { "Content-Type": "application/json", ...vaultHdr(), ...hdrs }, body: JSON.stringify(b) }, timeoutMs); let j = null; try { j = await r.json(); } catch (e) { j = null; } if (!r.ok) { const err = new Error(p + " → " + r.status + ((j && (j.error || j.message)) ? " : " + String(j.error || j.message) : "")); err.status = r.status; err.body = j; throw err; } try { busAfterPost(p, b, j); } catch {} return j; },
};
/* TRACE-MIROIR (SPARK8-B2) : une ligne par point de décision du miroir Direct.
   Double écriture : anneau local nova2_direct_mirror_trace + journal moteur /api/direct-mirror/log.
   Ne jette jamais : chaque étape est gardée, le POST est en fire-and-forget. */
export function traceMirror(feed, motif, cible, conv, detail) {
  let e = null;
  try {
    const clip = (v, n) => String(v ?? "").slice(0, n);
    e = { feed: clip(feed, 64), motif: clip(motif, 32), cible: clip(cible, 64), conv: clip(conv, 64), detail: clip(detail, 120) };
  } catch (_) { try { e = { feed: "", motif: "", cible: "", conv: "", detail: "" }; } catch (_) {} }
  try {
    const K = "nova2_direct_mirror_trace";
    let arr = [];
    try { const raw = localStorage.getItem(K); const v = JSON.parse(raw || "[]"); if (Array.isArray(v)) arr = v; } catch (_) {}
    let ts = "";
    try { ts = new Date().toISOString(); } catch (_) {}
    arr.push({ ...e, ts });
    while (arr.length > 300) arr.shift();
    try { localStorage.setItem(K, JSON.stringify(arr)); } catch (_) {}
  } catch (_) {}
  try { const p = api.post("/api/direct-mirror/log", e || {}, 5000); if (p && typeof p.catch === "function") p.catch(() => {}); } catch (_) {}
  try { window.traceMirror = traceMirror; } catch (e) {}
}
try { window.traceMirror = traceMirror; } catch (e) {}
/* ── Thèmes Nova 2 : UN registre, des variantes de tokens (css/nova2.css, blocs [data-theme="…"]). ──
   Nova 1 concaténait 4 familles (THEMES + UNIVERS + PRO + ACCESS) et applyTheme retombait SILENCIEUSEMENT
   sur le premier thème pour tout id inconnu — c'est ainsi que le thème stocké « nova-imperial » (inexistant)
   affichait Tahoe Auto sans un mot. Nova 2 : id inconnu = erreur visible (journal + événement), thème conservé.
   LIQUID GLASS PREMIUM (21/10/2026, jugement d'Ahadi : les anciens thèmes n'étaient « que des
   changements de ton et couleur ») : le registre ne contient plus que cinq thèmes VERRE. Chacun
   pose data-lg sur <html> (le moteur de matière vit dans nova2.css, section 23 : remplissage
   dégradé teinté, liseré spéculaire, ombres étagées, flou réel, mesh d'ambiance par thème).
   Les champs swatch/chip alimentent les cartes d'aperçu des Réglages : le mesh du thème et un
   échantillon de son verre. Migration : les ANCIENS ids (observatoire, encre, sahel, cafu,
   liquidglass) — qui peuvent encore être stockés côté serveur ou en cache — sont traduits
   explicitement par THEME_ALIASES vers leur équivalent verre le plus proche ; un id vraiment
   inconnu reste une erreur visible, comme avant. */
export const THEMES = [
  /* 24/10/2026 (soir) — IDENTITÉ « NOVA SOUVERAIN » : TROIS THÈMES SIGNATURE, chacun en
     JOUR et en NUIT (et AUTO, qui suit l'apparence du Mac). Jetons : css/nova2.css, @layer tokens.
     · OBSIDIENNE & OR SOLAIRE — l'identité de Nova, thème par défaut. Nuit : fond minéral,
       verre fumé à liseré chaud, Ambre solaire / Or sahélien. Jour « Ivoire & Encre » :
       papier chaud, encre noire, Terre de Sienne (rouge CAFU) et Or.
     · VERRE CÉLESTE — le Liquid Glass macOS 27 neutre, accent Nova Iris.
     · GRAPHITE STUDIO — mat, chirurgical, zéro flou, contraste maximal.
     Les anciens ids restent résolus par THEME_ALIASES (jamais d'écran blanc au démarrage). */
  /* 30/10/2026 — IDENTITÉ « PROMESSE » (Nova × Ahadi, docs/identite/IDENTITE.md ; jetons et matière :
     css/identite.css, chargée après app.css). Trois thèmes, chacun avec un vrai Jour et une vraie Nuit,
     et Auto (suit le Mac). Le champ « identite » pose html[data-identite] : c'est lui qui active
     l'habillage (verre liquide, icônes 3D du rail, typographie Fraunces + Hanken Grotesk).
     glass:false — la feuille de verre des panneaux est SIMULÉE (aucun flou plein écran). */
  { id: "harmattan-auto", material: "harmattan", mode: "auto", identite: "promesse", name: "Harmattan — Auto", desc: "L'identité Promesse, qui suit ton Mac : brume dorée le jour, ciel indigo du Sahel la nuit.", accent: "#D9552C", glass: false,
    swatch: "linear-gradient(90deg, #F2EADC 0 50%, #0D1030 50% 100%)", chip: "linear-gradient(160deg, rgba(255,240,220,.7), rgba(232,100,58,.35))" },
  { id: "harmattan-jour", material: "harmattan", mode: "jour", identite: "promesse", name: "Harmattan — Jour", desc: "Brume d'harmattan, sable lumineux, encre indigo et latérite : la lumière de Ouaga à 10 h.", accent: "#BF4220", glass: false,
    swatch: "radial-gradient(70% 80% at 90% 0%, #FFD68C, transparent 62%), radial-gradient(90% 70% at 0% 110%, rgba(206,110,70,.45), transparent 62%), linear-gradient(180deg, #F2EADC, #E6DAC6)",
    chip: "linear-gradient(180deg, rgba(255,252,247,.95), rgba(255,252,247,.7))" },
  { id: "harmattan-nuit", material: "harmattan", mode: "nuit", identite: "promesse", name: "Harmattan — Nuit", desc: "Ciel indigo, braise de latérite à l'horizon, or d'étoile : le thème signature de Nova.", accent: "#E8643A", glass: false,
    swatch: "radial-gradient(1.5px 1.5px at 30% 20%, #fff, transparent), radial-gradient(1.5px 1.5px at 70% 12%, #F2C46B, transparent), radial-gradient(110% 70% at 0% 115%, rgba(214,84,40,.75), transparent 62%), radial-gradient(80% 60% at 80% -10%, rgba(84,92,220,.55), transparent 66%), linear-gradient(180deg, #090B1B, #1A1430)",
    chip: "linear-gradient(160deg, rgba(255,236,214,.2), rgba(24,27,56,.75))" },
  { id: "fleuve-auto", material: "fleuve", mode: "auto", identite: "promesse", name: "Fleuve — Auto", desc: "Le thème de travail calme, qui suit ton Mac : porcelaine le jour, ardoise la nuit.", accent: "#1C6B74", glass: false,
    swatch: "linear-gradient(90deg, #ECF0EF 0 50%, #0C1518 50% 100%)", chip: "linear-gradient(160deg, rgba(255,255,255,.8), rgba(92,196,198,.3))" },
  { id: "fleuve-jour", material: "fleuve", mode: "jour", identite: "promesse", name: "Fleuve — Jour", desc: "Porcelaine, ardoise et eau du Niger : neutre, net, fait pour les longues lectures.", accent: "#1C6B74", glass: false,
    swatch: "radial-gradient(80% 70% at 100% 0%, rgba(170,215,218,.8), transparent 62%), radial-gradient(80% 70% at 0% 110%, rgba(170,185,225,.55), transparent 62%), #ECF0EF",
    chip: "linear-gradient(180deg, rgba(255,255,255,.96), rgba(255,255,255,.75))" },
  { id: "fleuve-nuit", material: "fleuve", mode: "nuit", identite: "promesse", name: "Fleuve — Nuit", desc: "Ardoise profonde, sarcelle douce : le calme pour travailler tard.", accent: "#5CC4C6", glass: false,
    swatch: "radial-gradient(90% 70% at 100% 110%, rgba(40,140,150,.5), transparent 62%), radial-gradient(70% 60% at 0% -10%, rgba(70,90,160,.4), transparent 64%), #0A1214",
    chip: "linear-gradient(160deg, rgba(220,245,245,.16), rgba(20,31,34,.8))" },
  { id: "sentinelle-auto", material: "sentinelle", mode: "auto", identite: "promesse", name: "Sentinelle — Auto", desc: "Contraste élevé, qui suit ton Mac : noir sur blanc le jour, blanc et ambre sur noir la nuit.", accent: "#A3260F", glass: false,
    swatch: "linear-gradient(90deg, #FFFFFF 0 50%, #000000 50% 100%)", chip: "linear-gradient(90deg, #FFFFFF 0 50%, #0A0A0A 50% 100%)" },
  { id: "sentinelle-jour", material: "sentinelle", mode: "jour", identite: "promesse", name: "Sentinelle — Jour", desc: "Contraste maximal, opaque, zéro flou : lisible en plein soleil, en mission.", accent: "#A3260F", glass: false,
    swatch: "linear-gradient(180deg, #FFFFFF, #F2F2F2)", chip: "linear-gradient(180deg, #FFFFFF, #FFFFFF)" },
  { id: "sentinelle-nuit", material: "sentinelle", mode: "nuit", identite: "promesse", name: "Sentinelle — Nuit", desc: "Noir pur, blanc net, ambre de veille : la nuit sans fatigue ni ambiguïté.", accent: "#FFC23D", glass: false,
    swatch: "linear-gradient(180deg, #000000, #050505)", chip: "linear-gradient(180deg, #111111, #0A0A0A)" },
  { id: "obsidienne-auto", material: "obsidienne", mode: "auto", name: "Obsidienne & Or — Auto", desc: "L'identité de Nova, qui suit ton Mac : Ivoire & Encre le jour, Obsidienne la nuit.", accent: "#E58E26", glass: true,
    swatch: "linear-gradient(90deg, #F6F4EF 0 50%, #08090E 50% 100%)", chip: "linear-gradient(160deg, rgba(255,238,210,.5), rgba(229,142,38,.18))" },
  { id: "obsidienne-jour", material: "obsidienne", mode: "jour", name: "Ivoire & Encre — Jour", desc: "Papier chaud, encre noire, Terre de Sienne et Or : la page d'un grand quotidien.", accent: "#C0392B", glass: true,
    swatch: "radial-gradient(90% 80% at 18% 12%, #F3D9AE, transparent 60%), radial-gradient(70% 70% at 90% 90%, #EBC9C2, transparent 60%), #F6F4EF",
    chip: "linear-gradient(160deg, rgba(255, 253, 248, 0.92), rgba(255, 253, 248, 0.6))" },
  { id: "obsidienne-nuit", material: "obsidienne", mode: "nuit", name: "Obsidienne & Or Solaire — Nuit", desc: "Fond minéral, verre fumé à liseré chaud, Ambre solaire : le thème signature de Nova.", accent: "#E58E26", glass: true,
    swatch: "radial-gradient(80% 70% at 18% 12%, #6B3F0E, transparent 62%), radial-gradient(70% 70% at 88% 92%, #23245E, transparent 60%), linear-gradient(180deg, #08090E, #0E111A)",
    chip: "linear-gradient(160deg, rgba(255, 238, 210, 0.18), rgba(20, 23, 34, 0.58))" },
  { id: "verre-auto", material: "verre", mode: "auto", name: "Verre Céleste — Auto", desc: "Le Liquid Glass neutre, qui suit l'apparence de ton Mac.", accent: "#5E5CE6", glass: true,
    swatch: "linear-gradient(90deg, #DCE7F7 0 50%, #070A18 50% 100%)", chip: "linear-gradient(160deg, rgba(255,255,255,.6), rgba(255,255,255,.15))" },
  { id: "verre-jour", material: "verre", mode: "jour", name: "Verre Céleste — Jour", desc: "Verre clair sur aurore pâle : translucide, net, lumineux. Accent Nova Iris.", accent: "#5E5CE6", glass: true,
    swatch: "radial-gradient(90% 80% at 15% 10%, #BFD8FF, transparent 60%), radial-gradient(80% 70% at 90% 20%, #F3D3FF, transparent 60%), radial-gradient(90% 90% at 60% 100%, #CFF3EA, transparent 60%), #EEF2F8",
    chip: "linear-gradient(160deg, rgba(255, 255, 255, 0.82), rgba(255, 255, 255, 0.46))" },
  { id: "verre-nuit", material: "verre", mode: "nuit", name: "Verre Céleste — Nuit", desc: "Verre fumé sur aurore profonde, accent Nova Iris.", accent: "#8E8CFF", glass: true,
    swatch: "radial-gradient(90% 80% at 15% 10%, #1D3A7A, transparent 60%), radial-gradient(80% 70% at 90% 20%, #3B1D5E, transparent 60%), radial-gradient(90% 90% at 60% 100%, #0E3B44, transparent 60%), #070A12",
    chip: "linear-gradient(160deg, rgba(255, 255, 255, 0.16), rgba(255, 255, 255, 0.05))" },
  { id: "graphite-auto", material: "graphite", mode: "auto", name: "Graphite Studio — Auto", desc: "Mat et chirurgical, suit l'apparence du Mac.", accent: "#2E46C8", glass: false,
    swatch: "linear-gradient(90deg, #F4F4F5 0 50%, #0E0E10 50% 100%)", chip: "linear-gradient(160deg, #FFFFFF, #1F1F23)" },
  { id: "graphite-jour", material: "graphite", mode: "jour", name: "Graphite Studio — Jour", desc: "Mat, opaque, zéro flou, contraste maximal : le travail analytique en pleine lumière.", accent: "#2E46C8", glass: false,
    swatch: "linear-gradient(160deg, #F7F7F8, #ECEDEF)", chip: "linear-gradient(160deg, #FFFFFF, #F4F4F5)" },
  { id: "graphite-nuit", material: "graphite", mode: "nuit", name: "Graphite Studio — Nuit", desc: "Noir graphite mat, gris neutres, aucun effet : la concentration.", accent: "#7C9CFF", glass: false,
    swatch: "linear-gradient(160deg, #18181B, #0F0F11)", chip: "linear-gradient(160deg, #232327, #1B1B1F)" },
  /* V5-L — SABLE CAFU : céramique crème, cramoisi CAFU #C00000, bronze brossé #A67C52 (maquette Studio UI v8).
     Mat et opaque (aucun flou) : le relief vient des ombres biseautées. Nuit = « Obsidienne bronze ». */
  { id: "sable-auto", material: "sable", mode: "auto", name: "Sable CAFU — Auto", desc: "Recommandé. Céramique crème le jour, Obsidienne & Bronze la nuit : suit l'apparence de ton Mac.", accent: "#C00000", glass: false,
    swatch: "linear-gradient(90deg, #ECE9E3 0 50%, #28251D 50% 100%)", chip: "linear-gradient(160deg, #FAF8F5, #312D26)" },
  { id: "sable-jour", material: "sable", mode: "jour", name: "Sable CAFU — Jour", desc: "Céramique crème, cramoisi CAFU et bronze brossé : un studio tactile, en relief doux.", accent: "#C00000", glass: false,
    swatch: "radial-gradient(70% 70% at 92% 96%, rgba(166, 124, 82, 0.38), transparent 62%), radial-gradient(90% 80% at 40% 12%, #F6F4EF, transparent 62%), linear-gradient(160deg, #ECE9E3, #DFDBD2)", chip: "linear-gradient(160deg, #FAF8F5, #F1EDE6)" },
  { id: "sable-nuit", material: "sable", mode: "nuit", name: "Sable CAFU — Nuit", desc: "Obsidienne & Bronze : obsidienne chaude #28251D, liserés bronze, cramoisi vif.", accent: "#E21D1B", glass: false,
    swatch: "radial-gradient(70% 70% at 92% 96%, rgba(200, 155, 110, 0.3), transparent 62%), radial-gradient(90% 80% at 40% 12%, #36312A, transparent 62%), linear-gradient(160deg, #28251D, #1E1C16)", chip: "linear-gradient(160deg, #39342C, #312D26)" },
];
export const DEFAULT_THEME = "harmattan-auto";   // 30/10 : identité Promesse — suit le Mac (prefers-color-scheme)
/* Migration explicite : tous les anciens ids restent résolus, jamais en silence.
   « saphir » (défaut historique du moteur), « liquidglass », « observatoire », « ambre », « encre »
   et « sahel/cafu » rejoignent la nouvelle identité ; « verre-* » = Verre Céleste ; « graphite-* » = Graphite Studio. */
export const THEME_ALIASES = {
  "saphir-jour": "obsidienne-jour", "saphir-nuit": "obsidienne-nuit", "cristal-jour": "verre-jour", "cristal-nuit": "verre-nuit",
  "bleue-jour": "verre-jour", "bleue-nuit": "verre-nuit", "celeste-jour": "verre-jour", "celeste-nuit": "verre-nuit", "celeste-auto": "verre-auto",
  saphir: "obsidienne-nuit", cristal: "verre-jour", graphite: "graphite-nuit", verre: "verre-nuit", obsidienne: "obsidienne-nuit", celeste: "verre-nuit",
  ambre: "obsidienne-nuit", "ambre-jour": "obsidienne-jour", "ambre-nuit": "obsidienne-nuit", "ambre-auto": "obsidienne-auto",
  "nuit-ambre": "obsidienne-nuit", "nuit-bleue": "verre-nuit", "ivoire-jour": "obsidienne-jour", ivoire: "obsidienne-jour",
  observatoire: "obsidienne-nuit", liquidglass: "verre-nuit", encre: "obsidienne-nuit", sahel: "obsidienne-jour", cafu: "obsidienne-jour", "tahoe-auto": "obsidienne-auto",
  sable: "sable-jour", "cafu-sand": "sable-jour", "obsidian-bronze": "sable-nuit",
  /* 30/10 : identité Promesse — noms courts */
  promesse: "harmattan-auto", harmattan: "harmattan-auto", fleuve: "fleuve-auto", sentinelle: "sentinelle-auto",
};
/* 30/10 — MIGRATION UNIQUE vers l'identité Promesse : un thème d'avant (Obsidienne, Verre, Graphite,
   Sable…) devient Harmattan dans le MÊME mode (jour / nuit / auto). Faite une seule fois : la marque
   « nova2_identite_v1 » n'est posée qu'après l'enregistrement réussi côté moteur (/api/settings).
   Pendant 20 s après la migration, l'ancien id renvoyé par un /api/state parti AVANT l'enregistrement
   est re-traduit (sinon l'ancien thème reviendrait) ; un choix explicite dans Réglages lève ce garde
   (identiteUserChoice). Ensuite, plus aucun choix n'est jamais touché. */
const IDENTITE_FLAG = "nova2_identite_v1";
let identiteMig = null;   // { from, to, until }
export function identiteUserChoice() { identiteMig = null; try { localStorage.setItem(IDENTITE_FLAG, "1"); } catch (e) {} }
function identiteMigrate(id) {
  try {
    if (identiteMig && id === identiteMig.from && performance.now() < identiteMig.until) return identiteMig.to;
    if (identiteMig || localStorage.getItem(IDENTITE_FLAG) === "1") return id;
    const t = THEMES.find((x) => x.id === id) || THEMES.find((x) => x.id === THEME_ALIASES[id]);
    if (t && t.identite) { localStorage.setItem(IDENTITE_FLAG, "1"); return id; }
    const to = "harmattan-" + (t ? t.mode : "auto");
    identiteMig = { from: id, to, until: performance.now() + 20000 };
    Promise.resolve().then(() => api.post("/api/settings", { theme: to }))
      .then(() => { try { localStorage.setItem(IDENTITE_FLAG, "1"); } catch (e) {} })
      .catch(() => {});   // échec : la marque n'est pas posée, la migration sera retentée au prochain lancement
    setTimeout(() => { try { softToast("Nouvelle identité de Nova : Promesse — thème Harmattan. Les thèmes précédents restent dans Réglages › Apparence.", 7000); } catch (e) {} }, 1400);
    return to;
  } catch (e) { return id; }
}
export function resolveTheme(id) {
  return THEMES.find((x) => x.id === id) || THEMES.find((x) => x.id === THEME_ALIASES[id]) || null;
}
/* 30/10 v3 — VRAI LIQUID GLASS : dans l'app native (window.__NOVA_NATIVE_WEB, posé par main.swift au début
   du document), la page de l'identité Promesse est transparente ; derrière elle, NSVisualEffectView (flou du
   bureau) et, sur macOS 26+, NSGlassEffectView. Le thème pilote leur apparence (jour → light, nuit → dark)
   et leur teinte. Sentinelle : pas de verre (contraste d'abord). Les anciens thèmes ne postent rien. */
const WIN_TINT = { "harmattan-nuit": ["#1A1430", 0], "harmattan-jour": ["#F2EADC", 0], "fleuve-nuit": ["#0A1214", 0], "fleuve-jour": ["#ECF0EF", 0] };
function postWinAppearance(t, mode) {
  try {
    if (!window.__NOVA_NATIVE_WEB || !t || !t.identite) return;
    document.documentElement.dataset.native = "1";
    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nova; if (!h) return;
    const tint = WIN_TINT[t.material + "-" + mode];
    const m = { cmd: "win.appearance", mode: mode === "jour" ? "light" : "dark", glass: !!tint };
    if (tint) { m.tint = tint[0]; m.alpha = tint[1]; }
    h.postMessage(m);
  } catch (e) {}
}
export function applyTheme(id) {
  id = identiteMigrate(id);   // 30/10 : migration unique vers l'identité Promesse (voir plus haut)
  const t = resolveTheme(id);
  if (!t) {   // NOVA2 : jamais de repli silencieux — l'erreur est journalisée et signalée à l'interface.
    reportError(new Error("Thème inconnu : " + id), "applyTheme");
    try { window.dispatchEvent(new CustomEvent("nova:theme-error", { detail: { id: String(id) } })); } catch (e) {}
    return null;
  }
  const d = document.documentElement;
  /* 24/10 : mode « auto » — suit l'apparence du Mac (prefers-color-scheme), en direct. */
  let mode = t.mode;
  if (mode === "auto") {
    let dark = true; try { dark = matchMedia("(prefers-color-scheme: dark)").matches; } catch (e) {}
    mode = dark ? "nuit" : "jour";
    if (!window.__novaAutoTheme) { window.__novaAutoTheme = true; try { matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => { const cur = localStorage.getItem("nova2_theme") || ""; if (/-auto$/.test(cur)) applyTheme(cur); }); } catch (e) {} }
  }
  d.dataset.theme = t.material + "-" + mode;
  d.dataset.themeChoice = t.id;
  d.dataset.material = t.material;
  d.dataset.mode = mode;
  if (t.glass) d.dataset.lg = "1"; else delete d.dataset.lg;
  if (t.identite) d.dataset.identite = t.identite; else delete d.dataset.identite;   // 30/10 : habillage css/identite.css
  postWinAppearance(t, mode);   // 30/10 v3 : teinte et apparence du verre natif (Liquid Glass d'Apple derrière la page)
  try { localStorage.setItem("nova2_theme", t.id); } catch (e) {}   // cache d'amorçage seulement ; la source de vérité est /api/settings
  try { window.dispatchEvent(new CustomEvent("nova:theme", { detail: { id: t.id, material: t.material, mode } })); } catch (e) {}
  try { window.dispatchEvent(new CustomEvent("nova:appearance", { detail: { kind: "theme", id: t.id, material: t.material, mode: t.mode } })); } catch (e) {}
  return t;
}
/** Thème au démarrage : cache local (avant le premier fetch), défaut Obsidienne & Or Solaire — Nuit. */
export function bootTheme() {
  let id = DEFAULT_THEME;
  try { id = localStorage.getItem("nova2_theme") || id; } catch (e) {}
  return applyTheme(id) || applyTheme(DEFAULT_THEME);
}
const clamp01 = (v, fb = 0.5) => { const n = Number(v); return isFinite(n) ? Math.max(0, Math.min(1, n)) : fb; };
const clamp100 = (v, fb = 50) => { const n = Number(v); return isFinite(n) ? Math.max(0, Math.min(100, n)) : fb; };
export function readAppearanceCache() {
  try {
    const a = JSON.parse(localStorage.getItem("nova2_appearance") || "null");
    if (a) return { tint: clamp100(a.tint), density: clamp100(a.density), blur: clamp100(a.blur) };
    const g = JSON.parse(localStorage.getItem("nova2_glass") || "null");
    if (g) {
      const tint = clamp01((Number(g.tint) - 0.3) / 2.1);
      return { tint: Math.round(tint * 100), density: Math.round(tint * 100), blur: Math.round(clamp01((Number(g.blur) - 11) / 37) * 100) };
    }
  } catch (e) {}
  return { tint: 50, density: 50, blur: 50 };
}
/* LOT WEB v3 / R4 §5.6 : trois axes indépendants. Les variables publiques sont
   des fractions 0..1 posées en ligne sur <html> ; la couche tokens en dérive
   teinte, alphas et flous, sans jamais toucher contenu/dense. */
export function applyAppearance(values = {}, opts = {}) {
  const cur = readAppearanceCache();
  const next = {
    tint: clamp100(values.tint != null ? values.tint : cur.tint),
    density: clamp100(values.density != null ? values.density : cur.density),
    blur: clamp100(values.blur != null ? values.blur : cur.blur),
  };
  const d = document.documentElement;
  d.style.setProperty("--u-tint", String(next.tint / 100));
  d.style.setProperty("--u-density", String(next.density / 100));
  d.style.setProperty("--u-blur", String(next.blur / 100));
  d.dataset.appearance = next.tint + "/" + next.density + "/" + next.blur;
  if (opts.persist !== false) { try { localStorage.setItem("nova2_appearance", JSON.stringify(next)); } catch (e) {} }
  try { window.dispatchEvent(new CustomEvent("nova:appearance", { detail: { kind: "sliders", ...next } })); } catch (e) {}
  return next;
}
/* Compatibilité avec l'ancien couplage (shell /api/state : glass_tint + glass_blur).
   Migration R4 §5.6 : teinte héritée → tint et density ; flou hérité → blur. */
export function applyGlass(tint, blur) {
  const hasT = tint != null && isFinite(Number(tint));
  const hasB = blur != null && isFinite(Number(blur));
  if (!hasT && !hasB) return readAppearanceCache();
  const cur = readAppearanceCache();
  const legacyTint = hasT ? Math.round(clamp01((Number(tint) - 0.3) / 2.1) * 100) : cur.tint;
  return applyAppearance({
    tint: legacyTint,
    density: hasT ? legacyTint : cur.density,
    blur: hasB ? Math.round(clamp01((Number(blur) - 11) / 37) * 100) : cur.blur,
  });
}
/* R4 §5.7 : la transparence réduite est un ÉTAT NOMMÉ, jamais un tueur silencieux.
   Les valeurs --u-* restent intactes ; seule la couche accessibility bascule les
   surfaces fonctionnelles sur --surface-dense. La source est conservée et lue
   par Réglages pour afficher badge, raison et action possible. */
export function applyReducedTransparency(on, source = "application") {
  const d = document.documentElement;
  const src = source === "systeme" || source === "system" ? "systeme" : "application";
  if (on) {
    d.dataset.transparency = "reduced";
    d.dataset.transparencySource = src;
    d.dataset.reduceTransparency = "1";
  } else {
    delete d.dataset.transparency;
    delete d.dataset.transparencySource;
    delete d.dataset.reduceTransparency;
  }
  try {
    localStorage.setItem("nova2_reduce_transparency", on ? "1" : "0");
    if (on) localStorage.setItem("nova2_transparency_source", src);
    else localStorage.removeItem("nova2_transparency_source");
  } catch (e) {}
  try { window.dispatchEvent(new CustomEvent("nova:appearance", { detail: { kind: "transparency", reduced: !!on, source: src } })); } catch (e) {}
  return { reduced: !!on, source: src };
}
export function reducedTransparencyState() {
  const d = document.documentElement;
  let media = false;
  try { media = !!(window.matchMedia && matchMedia("(prefers-reduced-transparency: reduce)").matches); } catch (e) {}
  const app = d.dataset.transparency === "reduced" && d.dataset.transparencySource !== "systeme";
  const system = media || (d.dataset.transparency === "reduced" && d.dataset.transparencySource === "systeme");
  return { reduced: !!(app || system), app, system, source: system ? "systeme" : app ? "application" : "" };
}
export const accentOf = () => getComputedStyle(document.documentElement).getPropertyValue("--accent").trim() || "#4cc9ff";
export const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
/* URL sûre : seuls http(s) et mailto passent (sinon « # »). */
export const safeUrl = (u) => (/^\s*(https?:|mailto:)/i.test(String(u ?? "")) ? String(u).trim() : "#");
/* ══════════ Formats de données FR + texte — helpers PARTAGÉS (DS §9.8, contrat phase 3) ══════════
   Source unique des formatages d'écran : aucun module ne reformate un nombre, une date,
   une durée ou un booléen dans son coin (les copies LBL/fmtV de Contrôle/Système/Savoir
   et les cleanResume/truncWords dupliqués convergent ici). Règles : séparateur de milliers
   Intl fr-FR ; aucune valeur brute de moteur (octets, booléens, clés, JSON) n'atteint
   l'écran ; une clé inconnue d'un tableau de bord est OMise et journalisée, jamais affichée. */
const NF_FR = new Intl.NumberFormat("fr-FR");
const NF_FR2 = new Intl.NumberFormat("fr-FR", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const toDate = (v) => {
  if (v == null || v === "") return null;
  if (v instanceof Date) return isNaN(v) ? null : v;
  if (typeof v === "number") { const d = new Date(v < 1e12 && v > 1e9 ? v * 1000 : v); return isNaN(d) ? null : d; }
  const d = new Date(v); return isNaN(d) ? null : d;
};
export function fmtNumFR(n) { const v = Number(n); return isFinite(v) ? NF_FR.format(v) : "—"; }
export function fmtBytesFR(octets) {
  const v = Number(octets); if (!isFinite(v) || v < 0) return "—";
  if (v < 1024) return fmtNumFR(Math.round(v)) + " o";
  if (v < 1048576) return fmtNumFR(Math.round(v / 1024)) + " Ko";
  if (v < 1073741824) return (v / 1048576).toFixed(1).replace(".", ",") + " Mo";
  return (v / 1073741824).toFixed(1).replace(".", ",") + " Go";
}
export function fmtMoneyFR(v, devise = "") {
  const n = Number(v); if (!isFinite(n)) return "—";
  const dec = /^(USD|EUR|GBP|CHF)$/i.test(String(devise)) ? NF_FR2.format(n) : NF_FR.format(n);
  return devise ? dec + " " + String(devise).toUpperCase() : dec;
}
export function fmtPctFR(v) { const n = Number(v); return isFinite(n) ? NF_FR.format(Math.round(n * 10) / 10) + " %" : "—"; }
export function fmtDateFR(d) { const dt = toDate(d); return dt ? new Intl.DateTimeFormat("fr-FR", { dateStyle: "medium" }).format(dt) : ""; }
export function fmtTimeFR(d) {
  const dt = toDate(d); if (!dt) return "";
  const hh = String(dt.getHours()).padStart(2, "0"), mm = String(dt.getMinutes()).padStart(2, "0");
  return hh + " h " + mm;
}
export function fmtRelFR(d) {
  const dt = toDate(d); if (!dt) return "";
  const diff = Date.now() - dt.getTime();
  if (diff < 0) return fmtDateFR(dt);
  if (diff < 60000) return "à l'instant";
  if (diff < 3600000) return "il y a " + Math.max(1, Math.floor(diff / 60000)) + " min";
  if (diff < 86400000) return "il y a " + Math.floor(diff / 3600000) + " h";
  if (diff < 172800000) return "hier";
  return new Intl.DateTimeFormat("fr-FR", { day: "numeric", month: "short" }).format(dt);
}
/* ── HORODATAGE DES FILS (ordre d'Ahadi, 21/10 ~17:08 : « heure et date sur
   les conversations, pour se situer ») ───────────────────────────────────
   Règle unique des trois surfaces de chat : l'heure affichée vient TOUJOURS
   de l'horodatage stocké du message (champ « ts » ISO écrit par le moteur
   dans conversations.json ; en direct, les mêmes valeurs renvoyées par le
   flux /api/chat — « user_ts » du meta, événement « stamp » de fin de run).
   Jamais l'heure de rendu : un message sans ts exploitable s'affiche SANS
   heure plutôt qu'avec une heure inventée. Formats : aujourd'hui « 14:32 » ;
   autre jour « 20 oct. 14:32 » — la même règle que les cartes du fil direct
   (prochat, fmtWhen), pour que tout l'écran parle d'une seule voix. */
export function msgTimeLabel(ts) {
  const d = toDate(ts); if (!d) return "";
  const time = d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });
  return d.toDateString() === new Date().toDateString() ? time
    : d.toLocaleDateString("fr-FR", { day: "numeric", month: "short" }) + " " + time;
}
export function sameDay(a, b) {
  const x = toDate(a), y = toDate(b);
  return !!x && !!y && x.toDateString() === y.toDateString();
}
/* Tamponne une bulle : ligne « .msg-time » en pied de bulle (même patron que
   « .msg-ack » et « .msg-rxline »), date complète au survol. Idempotent :
   un second appel met à jour la même ligne. Pose dataset.ts, lu par
   prevStampedTs pour les séparateurs de jour. Sans ts valide : ne fait
   RIEN — pas d'heure affichée, jamais d'heure inventée.
   RV phase 2 : si la bulle est précédée de son en-tête d'identité (ligne
   fratrie « .msg-head », posée par la surface), l'heure s'écrit dans le
   « .msg-who-time » de l'en-tête et AUCUN pied n'est ajouté — une seule
   heure visible par bulle. Sans en-tête, comportement historique. */
export function stampMsgTime(b, ts) {
  if (!b) return b;
  const label = msgTimeLabel(ts); if (!label) return b;
  b.dataset.ts = String(ts);
  const prev = b.previousElementSibling;
  let el = prev && prev.classList && prev.classList.contains("msg-head") ? prev.querySelector(".msg-who-time") : null;
  if (!el) {
    el = b.querySelector(":scope > .msg-time");
    if (!el) { el = h("div", { class: "msg-time" }); b.append(el); }
  }
  el.textContent = label;
  const d = toDate(ts);
  if (d) el.title = d.toLocaleString("fr-FR", { weekday: "long", day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" });
  return b;
}
export function daySepEl(ts) {
  const d = toDate(ts); if (!d) return null;
  const today = new Date(); const yest = new Date(); yest.setDate(today.getDate() - 1);
  const label = d.toDateString() === today.toDateString() ? "Aujourd'hui"
    : d.toDateString() === yest.toDateString() ? "Hier"
    : d.toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long" });
  return h("div", { class: "day-sep", "aria-hidden": "true" }, h("span", {}, label));
}
/* ts du dernier message tamponné AVANT « el » dans le même fil (les
   séparateurs et les lignes non tamponnées sont sautés) — décide, en
   direct comme au rejeu, s'il faut un séparateur de jour, sans aucun
   état à resynchroniser entre surfaces. */
export function prevStampedTs(logEl, el) {
  let n = el ? el.previousElementSibling : (logEl ? logEl.lastElementChild : null);
  while (n) { if (n.dataset && n.dataset.ts) return n.dataset.ts; n = n.previousElementSibling; }
  return null;
}
export function fmtDurFR(v, unit = "ms") {
  let s = Number(v); if (!isFinite(s) || s < 0) return "—";
  if (unit === "ms") s = s / 1000;
  s = Math.round(s);
  if (s < 60) return s + " s";
  const m = Math.floor(s / 60), r = s % 60;
  if (m < 60) return m + " min" + (r ? " " + String(r).padStart(2, "0") + " s" : "");
  const hh = Math.floor(m / 60), rm = m % 60;
  return hh + " h " + String(rm).padStart(2, "0");
}
export function fmtBoolFR(b) { return b ? "oui" : "non"; }
export function truncWords(t, n = 120) {
  const s = String(t ?? "");
  if (s.length <= n) return s;
  const cut = s.slice(0, n), sp = cut.lastIndexOf(" ");
  return (sp > n * 0.6 ? cut.slice(0, sp) : cut).trim() + "…";
}
/* LOT WEB v3 : le composant d'erreur d'écran, unique. Toute tuile ou tout
   module qui dépend d'un appel doit pouvoir rendre nom + cause + Réessayer ;
   un catch silencieux sur un chargement d'état est donc une régression. */
export function stateErrorNode(label, err, retry, hFn) {
  const mk = typeof hFn === "function" ? hFn : h;
  const cause = err == null ? "" : String((err && err.message) || err || "");
  const kids = [
    mk("span", { class: "state-error-ic", "aria-hidden": "true", html: ic("alert", 14) }),
    mk("span", { class: "grow" }, mk("span", { class: "state-error-label" }, String(label || "Chargement impossible")),
      cause ? mk("span", { class: "state-error-cause" }, cause) : null),
  ];
  if (typeof retry === "function") kids.push(mk("button", { class: "btn sm", onclick: () => retry() }, "Réessayer"));
  return mk("div", { class: "state-error", role: "alert" }, ...kids);
}

export function cleanResume(t) {
  /* V5-W : format maison → résumé d'une ligne (« Partiel — Gardien à signaler · Ops OK · Mac OK · … »), jamais « ## ». */
  try { const raw = String(t ?? ""); if (isHouse(raw)) t = houseSummary(raw); } catch (e) {}
  let s = String(t ?? "").replace(/\*\*/g, "").replace(/__/g, "").replace(/`/g, "")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1").replace(/^#+\s*/gm, "").replace(/\s+/g, " ").trim();
  /* FINITION 21/10 : un champ moteur vide sérialisé « null »/« undefined »
     ne doit jamais s'imprimer tel quel — segment exact retiré. */
  if (/^(null|undefined)$/i.test(s)) return "";
  s = s.split(" · ").filter((p) => !/^(null|undefined)$/i.test(p.trim())).join(" · ");
  s = s.replace(/^((?:STATUT|STATUS)\s*:\s*[A-ZÀ-Þ]+)\s*[-—·]?\s*\1\b/i, "$1");
  /* 24/10 : « STATUT : PARTIEL — … » (jargon moteur) → « Partiel — … » ; « STATUT : OK » → « OK — ». */
  s = s.replace(/^(?:STATUT|STATUS)\s*:\s*([A-ZÀ-Þ]+)\s*[-—·:]?\s*/i, (m, w) => (w.length <= 2 ? w.toUpperCase() : w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()) + " — ");
  return truncWords(s, 220);
}
export function ligneBrute(e) {
  if (e == null) return "Entrée (détail indisponible)";
  if (typeof e === "string") return truncWords(cleanResume(e), 160) || "Entrée (détail indisponible)";
  if (typeof e === "number" || typeof e === "boolean") return String(e);
  if (typeof e === "object") {
    for (const k of ["label", "title", "titre", "name", "nom", "what", "quoi", "sujet", "subject", "summary", "resume", "text", "texte", "value", "valeur", "status", "statut"]) {
      const v = e[k];
      if (typeof v === "string" && v.trim()) return truncWords(cleanResume(v), 160);
      if (typeof v === "number") return fmtNumFR(v);
    }
  }
  return "Entrée (détail indisponible)";
}
/* ── U5/U6 (23/10, mobilisation) : frontière d'affichage UNIQUE.
   txtPropre : un nil ne s'imprime JAMAIS — null/undefined/NaN/[object Object],
   en valeur ou en chaîne exacte, deviennent le repli ("" par défaut).
   etatLabel / phaseLabel / errKindLabel / voixLabel : tout libellé d'état
   passe par une table de correspondance ; un état inconnu donne le repli de
   l'appelant, JAMAIS la valeur brute du moteur. ── */
export function txtPropre(v, repli = "") {
  if (v == null) return repli;
  if (typeof v === "number") return isFinite(v) ? String(v) : repli;
  if (typeof v !== "string") return repli;
  if (/^(null|undefined|nan|\[object Object\])$/i.test(v.trim())) return repli;
  return v;
}
export const ETAT_LBL = {
  actif: "En cours", active: "Actif", attente: "En attente", waiting: "En attente", pending: "En attente",
  pause: "En pause", paused: "En pause", carepause: "En pause (DotCare)", erreur: "Échec", echec: "Échec", "échec": "Échec",
  repos: "Au repos", idle: "Au repos", ok: "Terminé", fait: "Fait", termine: "Terminé", "terminé": "Terminé",
  partiel: "Partiel", en_cours: "En cours", running: "En cours", done: "Clos", stopped: "Arrêté",
  annule: "Annulé", "annulé": "Annulé", ouvert: "Ouvert", ferme: "Fermé", "fermé": "Fermé",
  expired: "Expiré", expire: "Expiré", pret: "Prêt", "prêt": "Prêt", absent: "Absent", inconnu: "État inconnu",
};
export function etatLabel(v, repli = "") {
  if (v == null) return repli;
  const k = String(v).trim().toLowerCase().replace(/\s+/g, "_");
  if (!k || /^(null|undefined|nan)$/.test(k)) return repli;
  return ETAT_LBL[k] || repli;
}
export const PHASE_LBL = { actif: "En cours", attente: "Décision attendue", pause: "En pause", carepause: "En pause (DotCare)", erreur: "Dernier passage : échec", repos: "Au repos" };
export function phaseLabel(ph, repli = "") {
  if (ph == null) return repli;
  return PHASE_LBL[String(ph).trim().toLowerCase()] || repli;
}
export const ERRKIND_LBL = { auth: "authentification", credit: "crédit épuisé", rate: "limite de débit", timeout: "délai dépassé", network: "réseau", server: "serveur", model: "modèle", cut: "flux coupé", canceled: "annulé", other: "autre erreur" };
export function errKindLabel(v, repli = "") {
  if (v == null) return repli;
  return ERRKIND_LBL[String(v).trim().toLowerCase()] || repli;
}
export const VOIX_LBL = { say: "repli « say » du Mac", meta: "Muse Voice Transcribe (Meta)", local: "voix du Mac" };
export function voixLabel(v, repli = "moteur inconnu") {
  if (v == null || String(v).trim() === "") return repli;
  return VOIX_LBL[String(v).trim().toLowerCase()] || repli;
}
/* ── Factorisation Contrôle / Système / Savoir (DS §9.4) : table de libellés UNIQUE
   et formateur par clé. Une clé inconnue → libellé null → l'appelant OMET la ligne
   (jamais de repli « LBL[k] || k » qui affichait la clé brute du moteur). ── */
export const SYS_LBL = {
  mem_text: "Mémoire", mem_used: "Mémoire utilisée", os: "Système", thermal: "Thermique",
  ts: "Relevé à", uptime_s: "Allumé depuis",
  chunks: "Morceaux", files: "Fichiers", indexed_chunks: "Morceaux indexés", masked: "Masqués",
  scanning: "Analyse en cours", state: "État", status: "État", current: "Fichier en cours", skipped: "Ignorés",
  cpu: "Processeur", battery: "Batterie", disk: "Disque", uptime: "Allumé depuis",
};
const SYS_VMAP = { ok: "à jour", idle: "au repos", scan: "en cours", nominal: "normal", fair: "modéré", serious: "élevé", critical: "critique", true: "oui", false: "non" };
export function sysLabel(k) {
  const lb = SYS_LBL[String(k)];
  if (!lb) { try { console.warn("[nova] clé système inconnue, omise à l'écran :", String(k)); } catch (e) {} return null; }
  return lb;
}
export function fmtSysVal(k, v) {
  if (typeof v === "boolean") return fmtBoolFR(v);
  if (k === "uptime_s" || k === "uptime") return fmtDurFR(Number(v) || 0, "s");
  if (k === "ts") { const t = fmtTimeFR(v); return t || truncWords(String(v), 42); }
  if (k === "thermal") {
    let t = String(v).replace(/^état thermique\s*:\s*/i, "").replace(/\s*\((fair|nominal|serious|critical)\)/gi, "").trim().toLowerCase();
    return SYS_VMAP[t] || t;
  }
  if (typeof v === "number") return fmtNumFR(v);
  const sv = String(v);
  if (SYS_VMAP[sv]) return SYS_VMAP[sv];
  /* U6 (23/10) : une valeur d'ÉTAT inconnue (state/status/scanning) ne se rend
     jamais brute — les autres clés gardent leur contenu (ex. fichier en cours). */
  if ((k === "state" || k === "status" || k === "scanning") && /^[a-z0-9_-]+$/i.test(sv.trim())) { try { console.warn("[nova] valeur d'état inconnue, masquée :", k, sv); } catch (e) {} return "—"; }
  return truncWords(sv, 42);
}
/** Paires [libellé, valeur formatée] prêtes à rendre : scalaires connus seulement, clés inconnues omises. */
export function sysPairs(obj, max = 12) {
  return Object.entries(obj || {})
    .filter(([, v]) => ["string", "number", "boolean"].includes(typeof v) && !(typeof v === "string" && v.trim() === ""))
    .map(([k, v]) => { const lb = sysLabel(k); return lb ? [lb, fmtSysVal(k, v)] : null; })
    .filter(Boolean).slice(0, max);
}
export const LBL = SYS_LBL;
export const fmtV = fmtSysVal;
/* V15 — cartes générées à la demande : le modèle renvoie du JSON (jamais du HTML) ; seuls ces composants existent, tout texte est échappé. */
function novaCard(raw) {
  let o; try { o = JSON.parse(raw.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&")); } catch { return ""; }
  if (!o || typeof o !== "object") return "";
  const items = Array.isArray(o.items) ? o.items.slice(0, 12).filter((i) => i && typeof i === "object") : []; const t = (x) => esc(String(x ?? "").slice(0, 120));
  const head = o.title ? '<div class="ncard-t">' + t(o.title) + "</div>" : "";
  let body = "";
  if (o.type === "bars" || o.type === "gauge") {
    const nums = items.map((i) => Number(i.value)).filter((v) => isFinite(v)); const mx = Math.max(...items.map((i) => Number(i.max) || 0), ...nums, 1);
    body = items.map((i) => { const v = Number(i.value), pct = isFinite(v) ? Math.max(0, Math.min(100, (v / (Number(i.max) || mx)) * 100)) : 0;
      return '<div class="ncard-r"><span>' + t(i.label) + '</span><i style="--w:' + pct.toFixed(1) + '%"></i><b>' + t(i.value) + (i.unit ? " " + t(i.unit) : "") + "</b></div>"; }).join("");
  } else if (o.type === "stat") {
    body = '<div class="ncard-stats">' + items.map((i) => '<div><b>' + t(i.value) + (i.unit ? " <small>" + t(i.unit) + "</small>" : "") + "</b><span>" + t(i.label) + "</span></div>").join("") + "</div>";
  } else if (o.type === "list") {
    body = "<ul>" + items.map((i) => "<li><b>" + t(i.label) + "</b>" + (i.value != null ? " — " + t(i.value) : "") + "</li>").join("") + "</ul>";
  } else return "";
  return '<div class="ncard">' + head + body + "</div>";
}
/* NOVA2-DOC — carte « livrable » dans le fil : le modèle émet un bloc ```nova-livrable avec
   le JSON {name,titre,format,size} renvoyé par les outils cafu_format_* ; le nom est validé
   contre le motif strict des fichiers du dossier ~/cafu avant tout rendu (jamais d'URL libre).
   Aperçu inline (PDF/HTML en iframe native, autres formats en vignette QuickLook), ouverture
   dans l'app associée via le moteur, téléchargement direct, saut vers le module Livrables. */
const LIV_NAME_RX = /^cafu-(note|deck|doc|table)-\d{8}-\d{6}\.(docx|pptx|pdf|xlsx|html)$/;
function livFmtSize(n) { return fmtBytesFR(n); }
function livrableCard(raw) {
  let o; try { o = JSON.parse(raw.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&")); } catch { return ""; }
  if (!o || typeof o !== "object") return "";
  const name = String(o.name || "");
  if (!LIV_NAME_RX.test(name)) return "";
  const titre = esc(String(o.titre || name).slice(0, 140));
  const fmt = esc(String(o.format || name.split(".").pop()).toUpperCase());
  const size = Number(o.size) > 0 ? " · " + livFmtSize(Number(o.size)) : "";
  const q = encodeURIComponent(name);
  return '<div class="ncard liv-card" data-liv-name="' + name + '">'
    + '<div class="ncard-t">' + titre + "</div>"
    + '<div class="ss">Livrable CAFU · ' + fmt + size + "</div>"
    + '<img alt="" loading="lazy" src="/api/livrables/thumb?name=' + q + '" onerror="this.remove()" style="width:100%;max-height:190px;object-fit:cover;object-position:top;border-radius:8px;border:1px solid var(--stroke);margin-bottom:8px">'
    + '<div style="display:flex;gap:8px;flex-wrap:wrap">'
    + '<button type="button" class="btn" data-liv-act="preview">Aperçu</button>'
    + '<button type="button" class="btn" data-liv-act="open">Ouvrir</button>'
    + '<a class="btn" href="/api/livrables/file?name=' + q + '&dl=1" download>Télécharger</a>'
    + '<button type="button" class="btn" data-liv-act="goto">Module Livrables</button>'
    + "</div>"
    + '<div class="liv-prev" hidden style="margin-top:10px"></div>'
    + "</div>";
}
/* Délégué unique des cartes livrable (enregistré une seule fois pour tout le document). */
if (typeof window !== "undefined" && !window.__novaLivrableHook) {
  window.__novaLivrableHook = true;
  document.addEventListener("click", (e) => {
    /* DS (carte livrable) : « Télécharger » reçoit un retour d'état HONNÊTE au clic.
       Le téléchargement réel est délégué au moteur (WKDownload, lot Swift) : on ne
       promet donc pas « téléchargé », on dit que la demande est partie et on nomme
       le repli (« Ouvrir ») si rien n'arrive. L'ancre n'est PAS interceptée. */
    const dl = e.target && e.target.closest ? e.target.closest('a[download][href*="/api/livrables/file"]') : null;
    if (dl) {
      showToast("Téléchargement demandé pour « " + (dl.closest("[data-liv-name]")?.getAttribute("data-liv-name") || "le livrable") + " » — s'il ne démarre pas, utilise « Ouvrir » (le moteur gère le fichier).", { kind: "info" });
    }
    const b = e.target && e.target.closest ? e.target.closest("[data-liv-act]") : null;
    if (!b) return;
    const card = b.closest("[data-liv-name]"); if (!card) return;
    const name = card.getAttribute("data-liv-name");
    if (!LIV_NAME_RX.test(name)) return;
    const act = b.getAttribute("data-liv-act");
    if (act === "open") {
      api.post("/api/livrables/open", { name }).then((j) => { if (j && j.ok === false) showToast("Ouverture impossible : " + name, { kind: "bad" }); }).catch(() => showToast("Ouverture impossible.", { kind: "bad" }));
    } else if (act === "goto") {
      try { sessionStorage.setItem("nova2_livrable_focus", name); } catch {}
      const rb = document.querySelector('.rail-btn[title="Livrables"]');
      if (rb) rb.click(); else showToast("Module Livrables introuvable dans le rail.", { kind: "bad" });
    } else if (act === "preview") {
      const zone = card.querySelector(".liv-prev"); if (!zone) return;
      if (!zone.hidden) { zone.hidden = true; zone.innerHTML = ""; return; }
      const ext = name.split(".").pop(), q = encodeURIComponent(name);
      zone.hidden = false;
      /* 29/10 (audit P0-2) : sandbox — un livrable HTML généré (contenu potentiellement influencé par
         mail/web) ne peut plus exécuter de script dans la session Nova (même origine + cookie). */
      if (ext === "pdf" || ext === "html") zone.innerHTML = '<iframe sandbox="allow-same-origin allow-downloads" title="Aperçu du livrable" src="/api/livrables/file?name=' + q + '" style="width:100%;height:430px;border:1px solid var(--stroke);border-radius:10px;background:#fff"></iframe>';
      else zone.innerHTML = '<img alt="Première page" src="/api/livrables/thumb?name=' + q + '" style="width:100%;border-radius:10px;border:1px solid var(--stroke)"><div class="ss">Première page (QuickLook) — aperçu structuré complet dans le module Livrables.</div>';
    }
  });
}
/* BUILD-FEED-DIRECT vague 2 (DESIGN §B.2, temps 4) : le marqueur de navigation
   « [Ouvrir : X] » qui termine les messages composés (Direct, Feed) devient un
   vrai bouton « Ouvrir » — vocabulaire fermé (libellé composé → titre du bouton
   du rail), tout autre libellé est abandonné plutôt que rendu en bouton mort.
   La navigation n'est QUE de la navigation (règle d'or n°2 : jamais d'envoi ni
   de décision depuis un message). Délégué unique, patron des cartes livrable. */
const NOVA_NAV_TITLES = { "Boîtes": { module: "messages", button: "Ouvrir dans Messages" }, "Agenda": { module: "temps", button: "Ouvrir dans Temps" }, "Éclats": { module: "dots", button: "Ouvrir dans Éclats" }, "Dots": { module: "dots", button: "Ouvrir dans Éclats" }, "Veille": { module: "veille", button: "Ouvrir dans Feeds" }, "Feeds": { module: "veille", button: "Ouvrir dans Feeds" } };
if (typeof window !== "undefined" && !window.__novaNavHook) {
  window.__novaNavHook = true;
  document.addEventListener("click", (e) => {
    const b = e.target && e.target.closest ? e.target.closest("[data-nova-nav]") : null;
    if (!b) return;
    const key = b.getAttribute("data-nova-nav") || "";
    const mod2title = { messages: "Messages", temps: "Agenda", dots: "Éclats", veille: "Feeds" };
    const title = mod2title[key];
    if (!title) { showToast("Écran introuvable dans le rail.", { kind: "bad" }); return; }
    /* V4-A : l'entrée est retrouvée par son identifiant de page (data-page), plus par son infobulle
       — l'infobulle porte « Libellé — ⌥-clic… », la recherche par titre exact ne trouvait jamais rien. */
    const rb = document.querySelector('.rail-btn[data-page="' + key + '"]');
    if (rb) rb.click(); else showToast("Écran « " + title + " » introuvable dans le rail.", { kind: "bad" });
  });
}
/* 24/10 : les Dots s'appellent les Éclats — les textes venus du moteur (journaux, fil,
   rapports) sont affichés sous le nouveau nom ; identifiants et routes restent « dot ». */
export function eclatize(t) {
  return String(t == null ? "" : t)
    .replace(/\bLe Dot\b/g, "L'Éclat").replace(/\ble Dot\b/g, "l'Éclat").replace(/\bdu Dot\b/g, "de l'Éclat")
    .replace(/\bau Dot\b/g, "à l'Éclat").replace(/\bce Dot\b/g, "cet Éclat").replace(/\bCe Dot\b/g, "Cet Éclat")
    .replace(/\bDOTS\b/g, "ÉCLATS").replace(/\bDots\b/g, "Éclats").replace(/\bDot\b/g, "Éclat");
}
/* 29/10 (Ahadi : « proposer des axes, relances, détails après un ordre exécuté ») — bloc ```nova-suites :
   2 ou 3 prochaines étapes rendues en boutons ; un clic les envoie comme nouvelle demande (agent.js). Texte déjà échappé. */
function suitesHTML(c) {
  const items = String(c || "").split("\n").map((l) => l.replace(/^\s*[-•*\d.)]+\s*/, "").trim()).filter((l) => l.length > 3).slice(0, 4);
  if (!items.length) return "";
  return '<div class="nova-suites" role="group" aria-label="Suites proposées par Nova">' + items.map((t) => '<button type="button" class="nova-suite" data-ask="' + t.replace(/"/g, "&quot;") + '">' + ic("arrow-up-right", 12) + "<span>" + t + "</span></button>").join("") + "</div>";
}
/* C1 (29/10) — bloc ```nova-pied émis par normalizeAnswer : pied discret de la réponse.
   « Preuve : … » → une ligne grisée ; « DOTS 🟢n 🟡n 🔴n — détail » → rangée compacte de badges + détail grisé.
   Texte déjà échappé par md() ; balises de mise en forme résiduelles (`, **) retirées. */
function piedHTML(c) {
  const rows = String(c || "").split("\n").map((l) => l.replace(/`|\*\*/g, "").trim()).filter(Boolean);
  const out = rows.map((l) => {
    const m = /^(?:DOTS|ÉCLATS|Dots|Éclats)\s*:?\s*((?:(?:🟢|🟡|🔴)\s*\d+\s*)+)(?:[—–-]\s*)?(.*)$/u.exec(l);
    if (m) {
      const badges = [...m[1].matchAll(/(🟢|🟡|🔴)\s*(\d+)/gu)].map(([, e, n]) => '<span class="np-b ' + (e === "🟢" ? "g" : e === "🟡" ? "y" : "r") + '" title="' + (e === "🟢" ? "vérifié" : e === "🟡" ? "à confirmer" : "bloqué / manquant") + '">' + e + " " + n + "</span>").join("");
      return '<div class="np-row np-dots"><span class="np-lbl">Éclats</span>' + badges + (m[2] ? '<span class="np-txt">' + m[2] + "</span>" : "") + "</div>";
    }
    return '<div class="np-row np-preuve">' + l + "</div>";
  });
  return out.length ? '<div class="nova-pied">' + out.join("") + "</div>" : "";
}
export function md(src) {
  src = eclatize(src).replace(/<\/PARLE>/gi, "\n\n").replace(/<\/?(?:PARLE|D[ÉE]TAIL)>/gi, "");   // balises du protocole bi-canal : jamais affichées brutes
  /* V5-W (25/10) : un texte au FORMAT MAISON (« STATUT : X — … ## section … À TOI : … ») est mis en page
     par richtext.js (pastilles d'état, sections titrées, mesures, décision) — échappé de la même façon. */
  try { if (isHouse(src)) return houseHTML(src); } catch (e) {}
  let s = esc(src); const blocks = [];
  s = s.replace(/```([\w-]*)\n([\s\S]*?)```/g, (_, l, c) => { blocks.push(l === "nova-card" ? (novaCard(c) || "<pre><code>" + c + "</code></pre>") : l === "nova-livrable" ? (livrableCard(c) || "") : l === "nova-suites" ? suitesHTML(c) : l === "nova-pied" ? piedHTML(c) : (c.trim() ? "<pre><code>" + c + "</code></pre>" : "")); return "\u0000" + (blocks.length - 1) + "\u0000"; });
  s = s.replace(/^```[\w-]*[ \t]*$/gm, "");   // 29/10 (Ahadi : « rendu médiocre ») : bloc vide ou clôture orpheline → rien d'affiché
  s = s.replace(/\[Ouvrir\s*:\s*([^\]]{1,40})\]/g, (_, l) => { const e = NOVA_NAV_TITLES[String(l).trim()]; if (!e) { try { console.warn("[nova] libellé de navigation non résolu : " + String(l).trim()); } catch (_w) {} return ""; } blocks.push('<button type="button" class="btn sm nova-nav" data-nova-nav="' + e.module + '">' + ic("arrow-up-right", 13) + esc(e.button) + '</button>'); return "\u0000" + (blocks.length - 1) + "\u0000"; });
  /* 29/10 (Ahadi : « améliorer le rendu ») — tableaux Markdown (| a | b |), citations (> …) et filets (---) :
     avant, ils s'affichaient en texte brut (barres verticales, « &gt; »). Construits sur une seule ligne HTML
     pour que le découpage en paragraphes ne les casse pas ; la mise en forme en ligne (gras, code) s'applique ensuite. */
  s = s.replace(/(?:^|\n)((?:\|[^\n]*\|[ \t]*(?:\n|$)){2,})/g, (m0, blk) => {
    const rows = blk.trim().split("\n").map((r) => r.trim());
    if (rows.length < 2 || !/^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$/.test(rows[1])) return m0;
    const cells = (r) => r.replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => c.trim());
    const al = cells(rows[1]).map((c) => (/^:-+:$/.test(c) ? "center" : /-:$/.test(c) ? "right" : ""));
    const td = (tag, c, i) => "<" + tag + (al[i] ? ' style="text-align:' + al[i] + '"' : "") + ">" + c + "</" + tag + ">";
    const head = "<thead><tr>" + cells(rows[0]).map((c, i) => td("th", c, i)).join("") + "</tr></thead>";
    const body = "<tbody>" + rows.slice(2).map((r) => "<tr>" + cells(r).map((c, i) => td("td", c, i)).join("") + "</tr>").join("") + "</tbody>";
    return "\n\n<div class=\"md-table\"><table>" + head + body + "</table></div>\n\n";
  });
  s = s.replace(/(?:^|\n)((?:&gt; ?[^\n]*(?:\n|$))+)/g, (_, blk) => "\n\n<blockquote>" + blk.trim().split("\n").map((l) => l.replace(/^&gt; ?/, "")).join("<br>") + "</blockquote>\n\n");
  s = s.replace(/(?:^|\n)(?:-{3,}|\*{3,}|_{3,})[ \t]*(?=\n|$)/g, "\n\n<hr>\n\n");
  /* 29/10 (Ahadi : « rendus loin des standards CAFU ») — pastilles de la charte : [[À VÉRIFIER]] orange, [[SOLIDE]] rouge (modèle Peer Review). */
  s = s.replace(/\[\[([^\]\n]{2,30})\]\]/g, (_, t) => { const u = String(t).trim().toUpperCase(); const orange = /NUANCE|INCERTAIN|CHECK|CONFIRM|VALID|V[ÉE]RIF|DOUTE|ESTIM/.test(u); return '<span class="cafu-pill ' + (orange ? "orange" : "red") + '">' + u + "</span>"; });
  s = s.replace(/`([^`\n]+)`/g, "<code>$1</code>").replace(/\*\*([^\s*\n](?:[^*\n]*[^\s*\n])?)\*\*/g, "<b>$1</b>").replace(/\*\*/g, "").replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<i>$2</i>")
    .replace(/\[([^\]]+)\]\(((?:https?:|mailto:)[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer" style="color:var(--accent)">$1</a>')
    .replace(/^### (.*)$/gm, "<h3>$1</h3>").replace(/^## (.*)$/gm, "<h2>$1</h2>").replace(/^# (.*)$/gm, "<h1>$1</h1>");
  s = s.replace(/(?:^|\n)((?:[-•*] .*(?:\n|$))+)/g, (_, l) => "\n\n<ul>" + l.trim().split("\n").map((x) => "<li>" + x.replace(/^[-•*] /, "") + "</li>").join("") + "</ul>\n\n");
  /* V5-W : listes numérotées « 1. … » → <ol> (avant : lignes de texte brutes). */
  s = s.replace(/(?:^|\n)((?:\d{1,2}[.)] .*(?:\n|$))+)/g, (_, l) => { const it = l.trim().split("\n"); const st = parseInt(it[0], 10) || 1; return "\n\n<ol" + (st > 1 ? ' start="' + st + '"' : "") + ">" + it.map((x) => "<li>" + x.replace(/^\d{1,2}[.)] /, "") + "</li>").join("") + "</ol>\n\n"; });
  s = s.split(/\n{2,}/).filter((p) => p.trim()).map((p) => (/^<(ul|ol|h\d|pre|div|blockquote|hr)/.test(p.trim()) || /^\u0000\d+\u0000$/.test(p.trim()) ? p : "<p>" + p.trim().replace(/\n/g, "<br>") + "</p>")).join("");
  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => blocks[+i]);
}
/* U5 (24/10) — EXTINCTION DES « null » À LA SOURCE : append/prepend/replaceChildren/before/after
   du DOM convertissent null/undefined en texte « null ». On les filtre une fois pour toute
   l'interface (les modules passent souvent « cond ? noeud : null »). */
(function () {
  try {
    const clean = (args) => args.filter((x) => x != null && x !== false && !(typeof x === "number" && !isFinite(x)));
    for (const proto of [Element.prototype, DocumentFragment.prototype]) {
      for (const m of ["append", "prepend", "replaceChildren"]) {
        const orig = proto[m]; if (typeof orig !== "function" || orig.__novaClean) continue;
        const f = function (...a) { return orig.apply(this, clean(a)); }; f.__novaClean = true; proto[m] = f;
      }
    }
    for (const m of ["before", "after", "replaceWith"]) {
      const orig = Element.prototype[m]; if (typeof orig !== "function" || orig.__novaClean) continue;
      const f = function (...a) { return orig.apply(this, clean(a)); }; f.__novaClean = true; Element.prototype[m] = f;
    }
  } catch (e) {}
})();
export function h(tag, attrs = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) { if (k === "class") e.className = v; else if (k.startsWith("on")) e.addEventListener(k.slice(2), v); else if (k === "html") e.innerHTML = v; else if (v !== false && v != null && !(typeof v === "string" && /^\s*(null|undefined|nan)\s*$/i.test(v))) e.setAttribute(k, v === true ? "" : v); }
  /* U5 (23/10) : un enfant-texte qui n'est QUE « null »/« undefined »/NaN (ou un
     nombre non fini) ne s'affiche jamais — même règle que cleanResume (21/10),
     portée au point de passage unique de toute l'interface. */
  for (const k of kids.flat()) { if (k == null || k === false) continue; if (typeof k === "number" && !isFinite(k)) continue; if (typeof k === "string" && /^\s*(null|undefined|nan|\[object Object\])\s*$/i.test(k)) continue; e.append(k.nodeType ? k : document.createTextNode(k)); }
  if (tag === "button" && attrs && attrs.title && !e.hasAttribute("aria-label") && e.textContent.trim().length <= 2) e.setAttribute("aria-label", attrs.title);   // bouton-icône sans texte
  return e;
}
/* ══════════ Journal d'erreurs discret (refonte, lot D) ══════════
   Toute erreur JS non rattrapée ou promesse rejetée est notée (20 entrées max, dédupliquées) dans localStorage « nova_errors »
   et signalée par un petit toast non bloquant (au plus un toutes les 6 s, jamais d'alert). Lecture : window.NovaErrors.list() / clear(). */
const ERR_KEY = "nova_errors", ERR_MAX = 20;
const ERR_IGNORE = /ResizeObserver loop|^Script error\.?$|AbortError|aborted|signal is aborted/i;
const ERR_QUIET = /Failed to fetch|NetworkError|Load failed|network connection was lost/i;   // moteur en redémarrage : journal seulement
let errList = [];
try { const v = JSON.parse(localStorage.getItem(ERR_KEY) || "[]"); if (Array.isArray(v)) errList = v.slice(-ERR_MAX); } catch {}
let lastSoftToast = 0;
/* ── Toast UNIQUE (DS §6.11 / §9.5) ─────────────────────────────────────────────
   LA voie de toast du socle : un seul conteneur #toasts (shell/index.html, ancré
   sur --rail-w par §24), variantes .toast / .toast.ok / .toast.bad / .toast.info,
   durée unique 4 600 ms, fermeture manuelle .toast-x, action optionnelle unique
   .toast-act. Aucune couleur ni position codée en dur ici : tout vient du CSS.
   Le shell possède sa propre fonction ctx.toast (même conteneur, mêmes classes) —
   les deux convergent sur ce DOM ; softToast ne survit que comme alias (ci-dessous).
   Règle de retour (I S-24) : succès annoncé seulement après la preuve ; échec avec sa cause et sa relance au même endroit ; toute destruction d'état s'annonce par un toast avec « Annuler » pendant 8 s. */
export function showToast(text, opts = {}) {
  text = eclatize(text);
  try {
    if (!document.body) return null;
    let box = document.getElementById("toasts");
    if (!box) { box = document.createElement("div"); box.id = "toasts"; box.setAttribute("aria-live", "polite"); document.body.append(box); }
    const kind = opts.kind || (opts.bad ? "bad" : "");
    const t = document.createElement("div");
    t.className = "toast" + (kind ? " " + kind : "");
    t.setAttribute("role", "status");
    if (opts.icon) { const icEl = document.createElement("span"); icEl.className = "toast-ic"; icEl.innerHTML = ic(opts.icon, 22); t.append(icEl); }
    const label = document.createElement("span"); label.textContent = txtPropre(text).slice(0, 240); t.append(label);
    if (opts.action && opts.action.label) {
      const a = document.createElement("button"); a.type = "button"; a.className = "toast-act"; a.textContent = String(opts.action.label);
      a.addEventListener("click", () => { try { opts.action.onClick && opts.action.onClick(); } catch (e) {} dismiss(); });
      t.append(a);
    }
    const x = document.createElement("button"); x.type = "button"; x.className = "toast-x"; x.innerHTML = ic("close", 16);
    x.setAttribute("aria-label", "Fermer la notification");
    x.addEventListener("click", () => dismiss());
    t.append(x);
    box.append(t);
    const timer = setTimeout(dismiss, Number(opts.ms) > 0 ? Number(opts.ms) : 4600);
    function dismiss() { clearTimeout(timer); try { t.remove(); } catch (e) {} }
    return t;
  } catch (e) { return null; }
}
/* Alias FIN historique (incidents) : même système unique, avec son throttle de 6 s
   pour ne jamais inonder l'écran pendant une rafale d'erreurs. Aucun style propre. */
export function softToast(text, ms = 4200) {
  try {
    const now = Date.now(); if (now - lastSoftToast < 6000 || !document.body) return; lastSoftToast = now;
    showToast(txtPropre(text).slice(0, 160), { kind: "bad", ms });
  } catch (e) {}
}
export function reportError(err, where = "", quiet = false) {
  try {
    if (err && err.name === "AbortError") return;
    const msg = String((err && (err.message || (err.reason && err.reason.message) || err.reason)) || err || "Erreur inconnue").slice(0, 300);
    if (ERR_IGNORE.test(msg)) return;
    const key = where + "|" + msg, now = Date.now(); let i = errList.findIndex((x) => x.key === key); const known = i >= 0;
    if (known) { const x = errList.splice(i, 1)[0]; x.n = (x.n || 1) + 1; x.last = now; errList.push(x); }
    else { errList.push({ key, msg, where: String(where).slice(0, 80), n: 1, first: now, last: now, stack: String((err && err.stack) || "").slice(0, 600) }); while (errList.length > ERR_MAX) errList.shift(); }
    try { localStorage.setItem(ERR_KEY, JSON.stringify(errList)); } catch {}
    /* P0 stabilité (27/10) : les erreurs JS ne vivaient qu'en localStorage —
       invisibles au journal. Première occurrence remontée dans BlackBox via
       la route perf (ecran borné à 32 car. côté moteur, delta = longueur msg). */
    if (!known) { try { const p = api.post("/api/perf/first-paint", { ecran: "jserr:" + String(where || "?").slice(0, 18), delta_ms: msg.length }); if (p && p.catch) p.catch(() => {}); } catch {} }
    if (!known && !quiet && !ERR_QUIET.test(msg)) softToast("Incident (Nova continue) : " + msg.slice(0, 110));
  } catch {}
}
if (typeof window !== "undefined" && !window.NovaErrors) {
  window.addEventListener("error", (e) => { if (e && e.target && e.target !== window) return; reportError(e.error || e.message, String(e.filename || "").split("/").pop() + (e.lineno ? ":" + e.lineno : "")); });
  window.addEventListener("unhandledrejection", (e) => reportError(e && e.reason, "promesse"));
  window.NovaErrors = {
    list: () => errList.slice().reverse().map(({ key, ...x }) => x),
    clear() { errList = []; try { localStorage.removeItem(ERR_KEY); } catch {} },
    report: (e, where) => reportError(e, where || "manuel"),
  };
}

/* ══════════ Intervalle sobre : suspendu quand la fenêtre est cachée (document.hidden), relancé au retour ══════════
   every(ms, fn, { now }) → fonction d'arrêt. now = true : exécute aussi fn au retour de visibilité (rattrapage). */
export function every(ms, fn, { now = true } = {}) {
  let t = 0, stopped = false;
  const tick = () => { if (document.hidden) return; try { const r = fn(); if (r && typeof r.catch === "function") r.catch((e) => reportError(e, "intervalle", true)); } catch (e) { reportError(e, "intervalle", true); } };
  const start = () => { if (!t && !stopped) t = setInterval(tick, ms); };
  const pause = () => { if (t) { clearInterval(t); t = 0; } };
  const onVis = () => { if (document.hidden) pause(); else { start(); if (now) tick(); } };
  document.addEventListener("visibilitychange", onVis);
  if (!document.hidden) start();
  return () => { stopped = true; pause(); document.removeEventListener("visibilitychange", onVis); };
}

/* ══════════ Flux /api/events UNIQUE + bus d'événements Nova ══════════
   Avant : 6 à 8 modules ouvraient chacun leur EventSource. Or WebKit limite à 6 connexions HTTP/1.1 par hôte : au-delà,
   les fetch suivants (/api/state, /api/chat…) restaient en file d'attente → lenteurs et « plantages » apparents.
   Désormais une seule connexion, partagée par tous ; reconnexion à recul exponentiel 1 s → 30 s (jamais de tempête).
   Les modules qui font encore « new EventSource("/api/events") » reçoivent un abonné virtuel branché sur ce flux. */
const NativeES = typeof window !== "undefined" ? window.EventSource : null;
const esSubs = new Map();   // type → Set(fn(évènement brut {type, data, lastEventId}))
let esConn = null, esDelay = 1000, esTimer = 0;
const ES_META = new Set(["open", "error", "message"]);
function esDispatch(type, e) {
  const set = esSubs.get(type); if (!set || !set.size) return;
  const ev = { type, data: e && e.data != null ? e.data : "", lastEventId: (e && e.lastEventId) || "" };
  for (const f of [...set]) { try { f(ev); } catch (err) { reportError(err, "évènement " + type, true); } }
}
function esAttach(type) { if (esConn && !ES_META.has(type)) esConn.addEventListener(type, (e) => esDispatch(type, e)); }
function esLater() { if (esTimer) return; const d = esDelay; esDelay = Math.min(30000, esDelay * 2); esTimer = setTimeout(esConnect, d + Math.floor(Math.random() * 300)); }
function esConnect() {
  esTimer = 0; if (!NativeES || esConn) return;
  let me; try { me = new NativeES("/api/events"); } catch { esLater(); return; }
  esConn = me;
  /* V5-N : le recul ne revient à 1 s qu'après une connexion STABLE (≥ 10 s ouverte). Avant : remis à 1 s à
     chaque « open » — un flux qui s'ouvre puis tombe aussitôt (moteur qui redémarre, relais coupé) se
     reconnectait chaque seconde, et chaque reconnexion relançait ~10 requêtes de resynchronisation
     (mesuré au banc : 26 reconnexions et ~400 requêtes en 30 s sur l'Accueil). */
  let openedAt = 0;
  me.onopen = () => { openedAt = Date.now(); esDispatch("open", null); };
  me.onmessage = (e) => esDispatch("message", e);
  me.onerror = () => { if (esConn !== me) return; try { me.close(); } catch {} esConn = null; if (openedAt && Date.now() - openedAt >= 10000) esDelay = 1000; esDispatch("error", null); esLater(); };
  for (const t of esSubs.keys()) esAttach(t);
}
function esSubscribe(type, fn) {
  let set = esSubs.get(type); if (!set) { set = new Set(); esSubs.set(type, set); esAttach(type); }
  set.add(fn); if (!esConn && !esTimer) esConnect();
  return () => set.delete(fn);
}
const parseData = (e) => { try { return { ok: true, d: JSON.parse(e.data) }; } catch { return { ok: false, d: {} }; } };
const busLocal = new Map();   // « nova:… » → Set(fn(detail))
/** Bus : on("dot", fn) = évènement serveur (données JSON) ; on("nova:…", fn) = évènement d'interface. emit("nova:…", detail). */
export const bus = {
  on(type, fn) {
    if (/^nova:/.test(type)) { let s = busLocal.get(type); if (!s) busLocal.set(type, (s = new Set())); s.add(fn); return () => s.delete(fn); }
    return esSubscribe(type, (e) => fn(parseData(e).d));
  },
  emit(type, detail = {}) {
    const s = busLocal.get(type); if (s) for (const f of [...s]) { try { f(detail); } catch (err) { reportError(err, "bus " + type, true); } }
    try { window.dispatchEvent(new CustomEvent(type, { detail })); } catch {}
  },
};
/* Correspondance évènements serveur → évènements d'interface (les modules s'y abonnent au lieu de sonder) */
const BUS_ALIAS = { dot: "nova:dot-run", brief: "nova:brief-new", draft_sent: "nova:draft-new", projects: "nova:projects", meeting: "nova:meeting", commitment: "nova:commitment", "mail.new": "nova:mail-new" };
/* Après un POST réussi : décisions oui/non, file de brouillons, mode concentration */
function busAfterPost(p, b, j) {
  const path = String(p).split("?")[0];
  if (path === "/api/drafts/send") bus.emit("nova:decision", { answer: "oui", what: "brouillon", ok: !(j && j.ok === false) });
  else if (path === "/api/drafts/remove") bus.emit("nova:decision", { answer: "non", what: "brouillon", ok: !(j && j.ok === false) });
  else if (path === "/api/confirm") bus.emit("nova:decision", { answer: b && b.ok ? "oui" : "non", what: "autorisation" });
  else if (path === "/api/decision") { const r = String((b && b.regle) || ""); bus.emit("nova:decision", { answer: /\bOUI\b/.test(r) ? "oui" : /\bNON\b/.test(r) ? "non" : "", what: "règle" }); }
  if (/^\/api\/drafts(\/update)?$/.test(path)) bus.emit("nova:draft-new", { source: path });
  if (path === "/api/settings" && b && Object.prototype.hasOwnProperty.call(b, "focus_until")) bus.emit("nova:focus-change", { until: Number(b.focus_until) || 0 });
}
if (typeof window !== "undefined" && !window.NovaBus) {
  window.NovaBus = bus;
  for (const [k, v] of Object.entries(BUS_ALIAS)) esSubscribe(k, (e) => bus.emit(v, parseData(e).d));
  /* abonné virtuel pour « new EventSource('/api/events') » des autres modules (les erreurs de connexion ne leur sont pas
     transmises : le flux partagé se reconnecte seul, ils n'ont donc ni à fermer ni à rouvrir) */
  if (NativeES) {
    const isShared = (url) => { try { const u = new URL(String(url), location.href); return u.origin === location.origin && u.pathname === "/api/events" && !u.search; } catch { return false; } };
    function SharedES(url) {
      const self = this, offs = new Map(); self.url = String(url); self.readyState = 1; self.withCredentials = false;
      self.onmessage = null; self.onopen = null; self.onerror = null;
      const meta = [esSubscribe("message", (e) => { if (typeof self.onmessage === "function") self.onmessage(e); }), esSubscribe("open", (e) => { if (typeof self.onopen === "function") self.onopen(e); })];
      self.addEventListener = (type, fn) => { if (!fn || type === "error") return; const key = type + "\u0000"; let m = offs.get(key); if (!m) offs.set(key, (m = new Map())); if (m.has(fn)) return; m.set(fn, esSubscribe(type, (e) => (typeof fn === "function" ? fn.call(self, e) : fn.handleEvent && fn.handleEvent(e)))); };
      self.removeEventListener = (type, fn) => { const m = offs.get(type + "\u0000"); const off = m && m.get(fn); if (off) { off(); m.delete(fn); } };
      self.close = () => { if (self.readyState === 2) return; self.readyState = 2; meta.forEach((o) => o()); for (const m of offs.values()) for (const off of m.values()) off(); offs.clear(); };
      self.dispatchEvent = () => true;
    }
    const Wrapped = function EventSource(url, opts) { return isShared(url) ? new SharedES(url) : new NativeES(url, opts); };
    Wrapped.CONNECTING = 0; Wrapped.OPEN = 1; Wrapped.CLOSED = 2; Wrapped.prototype = NativeES.prototype;
    try { window.EventSource = Wrapped; } catch {}
  }
}
/** Compatibilité : openEvents({ type: fn(données) }) → abonnements au flux partagé ; renvoie { close() }. */
export function openEvents(handlers) {
  const offs = Object.entries(handlers || {}).map(([k, f]) => esSubscribe(k, (e) => { const r = parseData(e); if (!r.ok) return; try { f(r.d); } catch (err) { reportError(err, "évènement " + k, true); } }));
  return { readyState: 1, close() { offs.splice(0).forEach((o) => o()); this.readyState = 2; } };
}
// Lecture d'un flux SSE (POST) : onEvent(nom, données) ; renvoie quand le flux se ferme. signal = AbortController.signal
export async function sse(path, body, onEvent, signal) {
  const r = await fetch(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body || {}), signal });
  if (!r.ok || !r.body) throw new Error(path + " → " + r.status);
  const rd = r.body.getReader(), dec = new TextDecoder(); let buf = "";
  while (true) {
    const { done, value } = await rd.read(); if (done) break; buf += dec.decode(value, { stream: true }); let i;
    while ((i = buf.indexOf("\n\n")) >= 0) {
      const blk = buf.slice(0, i); buf = buf.slice(i + 2); let ev = "message", data = "";
      for (const l of blk.split("\n")) { if (l.startsWith("event:")) ev = l.slice(6).trim(); else if (l.startsWith("data:")) data += l.slice(5).trim(); }
      let d = {}; try { d = JSON.parse(data); } catch {} onEvent(ev, d);
    }
  }
}

/* ── i18n minimal : dictionnaire EN, repli sur le français passé en argument ── */
const EN = {
  "Accueil & Mac": "Home & Mac", "Âme de Nova": "Nova's Soul", "Converser": "Chat", "Mon temps": "My time", "Messageries & Web": "Messaging & Web", "Médias": "Media", "Savoir": "Knowledge", "Agents & mémoire": "Agents & memory", "Vie & travail": "Life & work", "Système": "System", "Apparence & aide": "Appearance & help",
  "Accueil": "Home", "Communications": "Communications", "Web & médias": "Web & media", "Savoir & veille": "Knowledge & watch", "Éclats Studio": "Éclats Studio", "Mémoire & Âme": "Memory & Soul", "Système & Réglages": "System & Settings", "Dossier": "Folder", "Plus": "More",
  "Rechercher partout": "Search everywhere", "Rechercher": "Search", "Palette de commandes": "Command palette", "Plein écran": "Full screen", "Réduire": "Collapse", "Agrandir": "Enlarge", "Messagerie": "Messaging", "Épingler": "Pin",
  "Micro": "Microphone", "Conversation": "Conversation", "Langue": "Language", "Français": "French", "Fermer": "Close", "Appliquer": "Apply", "Annuler": "Cancel", "Enregistrer": "Save", "Chargement": "Loading", "Barre du bas": "Bottom bar", "Assistant": "Assistant",
};
let LANG = "fr";
try { const l = localStorage.getItem("nova_lang"); if (l === "en" || l === "fr") LANG = l; } catch {}
try { document.documentElement.lang = LANG; } catch {}
export const getLang = () => LANG;
export const t = (k, fr) => (LANG === "en" ? EN[k] ?? fr ?? k : fr ?? k);
export function setLang(l) { LANG = l === "en" ? "en" : "fr"; try { localStorage.setItem("nova_lang", LANG); } catch {} try { document.documentElement.lang = LANG; } catch {} }

/* ═══ §44 — Menu contextuel de message (clic droit, modèle Muse) ═══
   Les actions d'un message (réagir, relancer, corriger…) ne s'affichent
   PLUS en permanence sous chaque message : elles vivent dans ce menu,
   ouvert au clic droit sur le message, fermé au clic extérieur, à Échap
   ou au défilement. sections : [{ label?, row?, items: [{ icon, label,
   title?, on?, fn }] }] — row = rangée d'icônes (les réactions). */
let _ctxEl = null, _ctxReturnFocus = null;
export function closeMsgMenu(restoreFocus = false) {
  if (!_ctxEl) return;
  const target = _ctxReturnFocus;
  _ctxEl.remove(); _ctxEl = null; _ctxReturnFocus = null;
  document.removeEventListener("pointerdown", _ctxOutside, true);
  document.removeEventListener("keydown", _ctxKey, true);
  removeEventListener("scroll", _ctxScroll, true);
  if (restoreFocus && target && typeof target.focus === "function") { try { target.focus({ preventScroll: true }); } catch (e) {} }
}
/* §44 / T-CHAT-03 : le menu doit rester utilisable PENDANT le streaming. Or
   Conversations et le dock font défiler leur journal à CHAQUE delta
   (log.scrollTop = log.scrollHeight) : le scroll de suivi automatique fermait
   le menu au delta suivant. Un scroll dont la cible est un journal de chat
   (.chatlog / .cs-log / .dock-log / .panel-log) ne ferme donc plus le menu ;
   tout autre scroll (page, module, autre conteneur) le ferme comme avant. */
function _ctxScroll(e) {
  const t = e && e.target;
  if (t && t !== document && typeof t.closest === "function" && t.closest(".chatlog, .cs-log, .dock-log, .panel-log")) return;
  closeMsgMenu();
}
function _ctxOutside(e) { if (_ctxEl && !_ctxEl.contains(e.target)) closeMsgMenu(); }
function _ctxItems() { return _ctxEl ? [..._ctxEl.querySelectorAll(".ctxmenu-item")] : []; }
function _ctxKey(e) {
  if (!_ctxEl) return;
  if (e.key === "Escape") { e.preventDefault(); closeMsgMenu(true); return; }
  if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(e.key)) return;
  const items = _ctxItems(); if (!items.length) return;
  e.preventDefault();
  const cur = Math.max(0, items.indexOf(document.activeElement));
  const next = e.key === "Home" ? 0 : e.key === "End" ? items.length - 1 : e.key === "ArrowDown" ? (cur + 1) % items.length : (cur - 1 + items.length) % items.length;
  items.forEach((it, i) => { it.tabIndex = i === next ? 0 : -1; });
  items[next].focus();
}
export function openMsgMenu(x, y, sections, opener = null, cfg = {}) {
  closeMsgMenu();
  _ctxReturnFocus = opener || document.activeElement;
  const menu = h("div", { class: "ctxmenu" + (cfg.imsg ? " imsg" : ""), role: "menu", "aria-label": "Actions du message" });
  let moreRow = null, quickRow = null;
  for (const sec of sections) {
    if (sec.header !== undefined) { if (sec.header) menu.append(h("div", { class: "imsg-when" }, sec.header)); continue; }
    if (sec.sep) { menu.append(h("div", { class: "imsg-sep", role: "separator" })); continue; }
    if (sec.svg || (sec.items && sec.items.some((it) => it.svg))) {
      const col = h("div", { class: "imsg-acts" });
      for (const it of sec.items) col.append(h("button", { role: "menuitem", tabindex: "-1", class: "ctxmenu-item imsg-act", title: it.title || it.label || "",
        onclick: (e) => { e.preventDefault(); closeMsgMenu(); if (it.fn) it.fn(); } }, h("span", { class: "imsg-ic", html: it.svg || "" }), h("span", {}, it.label || "")));
      menu.append(col);
      continue;
    }
    if (sec.label) menu.append(h("div", { class: "ctxmenu-label" }, sec.label));
    const row = h("div", { class: (sec.chips ? "ctxmenu-chips" : (sec.row ? "ctxmenu-row" : "ctxmenu-col")) + (sec.quick ? " imsg-quick" : "") + (sec.more ? " imsg-more" : "") });
    if (sec.more) { row.hidden = true; moreRow = row; }
    if (sec.quick) quickRow = row;
    for (const it of sec.items) {
      if (sec.chips) {   /* 25/10 : pastilles texte compactes (menu « Affiner la réponse ») */
        row.append(h("button", { role: "menuitem", tabindex: "-1", class: "ctxmenu-item ctxmenu-chip", title: it.title || it.label || "",
          onclick: (e) => { e.preventDefault(); closeMsgMenu(); if (it.fn) it.fn(); } }, it.label || ""));
        continue;
      }
      row.append(h("button", {
        role: "menuitem",
        tabindex: "-1",
        class: "ctxmenu-item" + (it.on ? " on" : "") + (sec.row ? " rx" : ""),
        title: it.title || it.label || "",
        onclick: (e) => { e.preventDefault(); closeMsgMenu(); if (it.fn) it.fn(); },
      }, it.icon ? h("span", { class: "ctxmenu-ic" }, it.icon) : null, sec.row ? null : h("span", {}, it.label || "")));
    }
    menu.append(row);
  }
  /* « + » : déplie les autres réactions sous la rangée rapide, sans fermer le menu. */
  if (quickRow && moreRow) {
    const plus = h("button", { role: "menuitem", tabindex: "-1", class: "ctxmenu-item imsg-plus", title: "Plus de réactions", "aria-expanded": "false" }, "+");
    plus.addEventListener("click", (e) => { e.preventDefault(); e.stopPropagation(); moreRow.hidden = !moreRow.hidden; plus.setAttribute("aria-expanded", moreRow.hidden ? "false" : "true"); plus.classList.toggle("on", !moreRow.hidden); try { const r2 = menu.getBoundingClientRect(); if (r2.bottom > innerHeight - 8) menu.style.top = Math.max(8, innerHeight - r2.height - 8) + "px"; } catch (err) {} });
    quickRow.append(plus);
  }
  document.body.append(menu);
  const r = menu.getBoundingClientRect();
  menu.style.left = Math.max(8, Math.min(x, innerWidth - r.width - 8)) + "px";
  menu.style.top = Math.max(8, Math.min(y, innerHeight - r.height - 8)) + "px";
  _ctxEl = menu;
  document.addEventListener("pointerdown", _ctxOutside, true);
  document.addEventListener("keydown", _ctxKey, true);
  addEventListener("scroll", _ctxScroll, { capture: true });
  const items = _ctxItems();
  if (items.length) { items[0].tabIndex = 0; try { items[0].focus({ preventScroll: true }); } catch (e) {} }
  return menu;
}
/* LOT WEB v3 / W-19 : une seule voie d'ouverture du menu de message —
   clic droit, touche Menu / Maj+F10 / Entrée sur un message focalisable,
   et appui long tactile. Les trois surfaces de chat consomment ce relieur ;
   aucune ne doit réinventer un déclencheur souris-only. */
export function bindMessageMenuTarget(el, openAt) {
  if (!el || typeof openAt !== "function" || el.dataset.menuTargetBound) return el;
  el.dataset.menuTargetBound = "1";
  if (!el.hasAttribute("tabindex")) el.tabIndex = 0;
  if (!el.hasAttribute("aria-label")) el.setAttribute("aria-label", "Message — Entrée ou clic droit pour les actions");
  el.addEventListener("contextmenu", (e) => { e.preventDefault(); openAt(e.clientX, e.clientY, el); });
  el.addEventListener("keydown", (e) => {
    if (e.key !== "ContextMenu" && !(e.key === "F10" && e.shiftKey) && !(e.key === "Enter" && document.activeElement === el)) return;
    e.preventDefault();
    const r = el.getBoundingClientRect();
    openAt(Math.round(r.left + 24), Math.round(r.top + 24), el);
  });
  let timer = 0, start = null;
  el.addEventListener("pointerdown", (e) => {
    if (e.pointerType !== "touch" && e.pointerType !== "pen") return;
    start = { x: e.clientX, y: e.clientY };
    clearTimeout(timer);
    timer = setTimeout(() => { if (start) openAt(start.x, start.y, el); }, 550);
  });
  const cancel = () => { clearTimeout(timer); start = null; };
  el.addEventListener("pointerup", cancel);
  el.addEventListener("pointercancel", cancel);
  el.addEventListener("pointermove", (e) => { if (start && Math.hypot(e.clientX - start.x, e.clientY - start.y) > 10) cancel(); });
  return el;
}

/* LOT WEB v3 / §44 généralisé : le lieur de message UNIQUE des trois surfaces
   de chat (Conversations, dock, createChat Accueil/panneau). Il possède le
   magasin de réactions, les pastilles, le menu et ses déclencheurs ; chaque
   surface ne fournit que ses callbacks de relance/citation. */
export function messageHash(t) { let x = 5381; const s2 = String(t || ""); for (let i = 0; i < s2.length; i++) x = ((x << 5) + x + s2.charCodeAt(i)) >>> 0; return x.toString(36); }
export function loadMessageReactions() { try { return JSON.parse(localStorage.getItem("nova2_reactions") || "{}"); } catch (e) { return {}; } }
/* 26/10 : styles du « Répondre » (bouton de survol, citation dans la bulle). Injectés une fois, ici, pour ne pas
   toucher aux feuilles de style tenues par l'autre agent. Couleurs prises aux variables du thème. */
let _replyCssDone = false;
function _replyCss() {
  if (_replyCssDone) return; _replyCssDone = true;
  try {
    const st = document.createElement("style");
    st.id = "nova-reply-css";
    st.textContent = ".msg-reply-btn{position:absolute;top:6px;right:34px;width:24px;height:24px;display:inline-flex;align-items:center;justify-content:center;border:0;border-radius:8px;background:var(--glass-strong);box-shadow:var(--shadow-1);color:var(--text-2);font-size:14px;line-height:1;opacity:0;cursor:pointer}"
      + ".msg:hover .msg-reply-btn,.msg:focus-within .msg-reply-btn{opacity:1}"
      + ".msg-reply-btn:hover{color:var(--text-1,inherit)}"
      + ".msg-quote{display:block;margin:0 0 6px;padding:4px 8px;border-left:3px solid var(--accent,#c0392b);border-radius:6px;background:rgba(127,127,127,.12);font-size:12.5px;line-height:1.35;opacity:.85;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:100%}"
      + ".msg.nova .msg-reply-btn,.msg.nova .msg-menu-btn{top:-14px}"
      + ".ctxmenu-col .ctxmenu-item{display:flex;align-items:center;gap:10px}"
      + ".ctxmenu-col .ctxmenu-ic{display:inline-flex;justify-content:center;width:18px;font-size:15px;opacity:.8}";
    document.head.append(st);
  } catch (e) {}
}
export function bindChatMessage(b, getText, opts = {}) {
  if (!b || typeof getText !== "function" || b.dataset.menuBound) return b;
  b.dataset.menuBound = "1";
  const rxline = h("div", { class: "msg-rxline", hidden: true });
  b.append(rxline);
  const cidOf = () => typeof opts.cid === "function" ? opts.cid() : opts.cid || "local";
  const paintRx = () => {
    if (!rxline.isConnected) b.append(rxline);   // les rendus streaming (textContent/innerHTML) peuvent l'avoir détachée
    const saved = loadMessageReactions()[cidOf() + ":" + messageHash(getText())] || [];
    rxline.replaceChildren(...saved.map((emo) => h("span", { class: "msg-rx" }, emo)));
    rxline.hidden = !saved.length;
  };
  b._paintRx = paintRx;
  paintRx();
  const openAt = (x, y, opener) => {
    const text = String(getText() || "");
    const key = cidOf() + ":" + messageHash(text);
    const saved = loadMessageReactions()[key] || [];
    const toggleRx = (emo) => {
      const all = loadMessageReactions(); const cur = new Set(all[key] || []);
      const added = !cur.has(emo);
      if (added) cur.add(emo); else cur.delete(emo);
      all[key] = [...cur];
      try { localStorage.setItem("nova2_reactions", JSON.stringify(all)); } catch (err) {}
      paintRx();
      /* PV (23/10) : un retour d'Ahadi est un ÉVÉNEMENT — une réaction
         positive AJOUTÉE parle au compagnon (humeur joie). Un retrait
         n'émet rien. Point unique : toutes les surfaces de conversation
         passent par bindChatMessage. */
      if (added && (emo === "👍" || emo === "❤️")) { try { window.dispatchEvent(new CustomEvent("nova:feedback", { detail: { kind: "validation", via: emo } })); } catch (err) {} }
      if (added && (emo === "👎" || emo === "⚠️")) { try { window.dispatchEvent(new CustomEvent("nova:feedback", { detail: { kind: "correction", via: emo } })); } catch (err) {} }
      /* 28/10 : sens journalisé côté moteur (POST /api/feedback/reaction via la surface) —
         la réaction devient une leçon relisible, pas un autocollant local. */
      if (added && typeof opts.onReaction === "function") { try { opts.onReaction(emo, RX_SENS[emo] || "reaction"); } catch (err) {} }
    };
    /* 28/10 (Ahadi : « au moins 4 en rapide, et les emojis doivent avoir un sens ») —
       rapides : 👍 utile · ❤️ j'aime · 👎 pas ça (ACTION : affine aussitôt) ·
       🤔 pas clair (ACTION : explique simplement) · 🙏 merci. Rangée « plus » :
       ✅ 🎯 💡 (retours) · 🔁 ⚠️ 🔍 ✂️ (actions) · 🎉 📌 ⏳ (marques). */
    const RX_SENS = { "👍": "utile", "❤️": "aime", "👎": "pas-ca", "🤔": "pas-clair", "🙏": "merci", "✅": "parfait", "🎯": "exactement", "💡": "bonne-idee", "🔁": "refais", "⚠️": "probleme", "🔍": "detaille", "✂️": "plus-court", "🎉": "bravo", "📌": "a-garder", "⏳": "trop-lent" };
    const RX_ACTION = { "👎": "Refais autrement", "🤔": "Explique simplement", "🔁": "Refais autrement", "⚠️": "Corrige le problème", "🔍": "Détaille", "✂️": "Plus court" };
    const rxTap = (emo) => {
      toggleRx(emo);
      const label = RX_ACTION[emo];
      if (label && typeof opts.follow === "function") follow(label, label);
    };
    const rxItem = (emo, label) => ({ icon: emo, label, title: label + (RX_ACTION[emo] ? " — Nova s'y met aussitôt" : ""), on: saved.includes(emo), fn: () => rxTap(emo) });
    const follow = (label, instruction) => {
      /* PV (23/10) : « Refais autrement » et « Corrige le problème » sont
         des CORRECTIONS d'Ahadi — événement réel pour le compagnon
         (humeur attention). Les autres relances sont de l'engagement,
         pas une humeur : elles n'émettent rien. */
      if (label === "Refais autrement" || label === "Corrige le problème") { try { window.dispatchEvent(new CustomEvent("nova:feedback", { detail: { kind: "correction", via: label } })); } catch (err) {} }
      if (typeof opts.follow === "function") opts.follow(text, label, instruction);
    };
    /* 26/10 (Ahadi : « pas d'option Répondre, et les options c'est beaucoup pour rien — simplifie comme WhatsApp ») :
       une rangée de réactions, puis trois actions nommées. Les relances fines (plus court, détaille…) se demandent
       en répondant au message, comme dans une messagerie. */
    /* 29/10 (Ahadi : « même apparence » qu'iMessage — capture) : l'heure en tête, UNE rangée de 6 réactions + « + »
       qui déplie les autres sur place, un filet, puis Répondre / Copier / Refaire avec de vraies icônes. */
    const when = (() => { try { const ts = b.dataset.ts || b.dataset.lts || ""; if (!ts) return ""; const d = new Date(isNaN(Number(ts)) ? ts : Number(ts)); if (isNaN(d)) return ""; const t = d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" }); const today = new Date(); const same = d.toDateString() === today.toDateString(); const y = new Date(today); y.setDate(today.getDate() - 1); return (same ? "Aujourd'hui" : d.toDateString() === y.toDateString() ? "Hier" : d.toLocaleDateString("fr-FR", { day: "numeric", month: "short" })) + " à " + t; } catch (err) { return ""; } })();
    const sections = [
      { header: when },
      { row: true, quick: true, items: [rxItem("👍", "Utile"), rxItem("❤️", "J'aime"), rxItem("😂", "Drôle"), rxItem("👎", "Pas ça"), rxItem("🤔", "Pas clair"), rxItem("🙏", "Merci")] },
      { row: true, more: true, items: [rxItem("✅", "Parfait"), rxItem("🎯", "Exactement"), rxItem("💡", "Bonne idée"), rxItem("🔁", "Refais"), rxItem("⚠️", "Problème"), rxItem("🔍", "Détaille"), rxItem("✂️", "Plus court"), rxItem("🎉", "Bravo"), rxItem("📌", "À garder"), rxItem("⏳", "Trop lent")] },
      { sep: true },
      { items: [] },
    ];
    const RS = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">';
    const IC_REPLY = RS + '<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 5.5 5.5V20"/></svg>';
    const IC_COPY = RS + '<rect x="8" y="8" width="12" height="12" rx="2.5"/><path d="M16 8V6.5A2.5 2.5 0 0 0 13.5 4h-7A2.5 2.5 0 0 0 4 6.5v7A2.5 2.5 0 0 0 6.5 16H8"/></svg>';
    const IC_REDO = RS + '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/></svg>';
    const acts = sections[4].items;
    if (typeof opts.quote === "function") acts.push({ svg: IC_REPLY, label: "Répondre", title: "Répondre à ce message", fn: () => opts.quote(text) });
    acts.push({ svg: IC_COPY, label: "Copier", title: "Copier le message", fn: () => { let t = text; try { if (typeof opts.copyText === "function") t = String(opts.copyText(text) ?? text); } catch (err) {} try { navigator.clipboard.writeText(t); } catch (err) {} } });   // C1 : opts.copyText (réponse normalisée) — la clé des réactions reste le texte brut
    if (typeof opts.follow === "function") acts.push({ svg: IC_REDO, label: "Refaire autrement", title: "Refaire cette réponse sous un autre angle", fn: () => follow("Refais autrement", "Refais cette réponse autrement : autre angle, autre formulation.") });
    openMsgMenu(x, y, sections, opener || b, { imsg: true });
  };
  b._openMessageMenu = openAt;
  /* 26/10 : bouton Répondre au survol (comme la flèche de WhatsApp), à côté de ⋯. */
  if (typeof opts.quote === "function") {
    _replyCss();
    try { const _rb = h("button", { class: "msg-reply-btn", type: "button", "aria-label": "Répondre à ce message", title: "Répondre" }, "↩"); _rb.addEventListener("click", (e) => { e.stopPropagation(); opts.quote(String(getText() || "")); }); b.append(_rb); } catch (e) {}
  }
  try { const _mb = h("button", { class: "msg-menu-btn", type: "button", "aria-label": "Actions du message", title: "Actions du message" }, "⋯"); _mb.addEventListener("click", (e) => { e.stopPropagation(); try { const _r = _mb.getBoundingClientRect(); openAt(_r.left, _r.bottom, b); } catch (err) {} }); b.append(_mb); } catch (e) {}
  bindMessageMenuTarget(b, openAt);
  return b;
}
let _feSeq = 0;
export function setFieldError(input, msg) {
  if (!input) return;
  const hasMsg = msg != null && String(msg) !== "";
  if (!hasMsg) {
    input.removeAttribute("aria-invalid");
    input.removeAttribute("aria-describedby");
    const n0 = input._fieldErr;
    if (n0 && n0.parentNode) n0.remove();
    input._fieldErr = null;
    return;
  }
  input.setAttribute("aria-invalid", "true");
  let node = input._fieldErr;
  const nxt = input.nextElementSibling;
  if (nxt && nxt.classList && nxt.classList.contains("field-err")) node = nxt;
  const wantId = input.id ? input.id + "-err" : "fe-" + (++_feSeq);
  if (!node || !node.isConnected) {
    node = document.createElement("div");
    node.className = "field-err";
    node.setAttribute("role", "alert");
    node.id = wantId;
    if (input.parentNode) input.after(node);
    input._fieldErr = node;
  }
  if (!node.id) node.id = wantId;
  node.className = "field-err";
  node.setAttribute("role", "alert");
  node.textContent = String(msg);
  input.setAttribute("aria-describedby", node.id);
  input._fieldErr = node;
}

/* 24/10 — pas d'« Écrire avec Siri » / suggestions d'écriture système sur les champs de
   Nova : la bulle flottante recouvrait le texte. Attribut WebKit writingsuggestions=false
   posé sur chaque champ, présent et à venir (en plus du réglage natif de la vue). */
try {
  const _noWS = (root) => { try { (root.querySelectorAll ? root.querySelectorAll("textarea, input[type=text], input:not([type]), [contenteditable=true]") : []).forEach((el) => { if (el.getAttribute("writingsuggestions") !== "false") el.setAttribute("writingsuggestions", "false"); }); } catch (e) {} };
  const _goWS = () => { _noWS(document); try { new MutationObserver((ms) => { for (const m of ms) for (const n of m.addedNodes) if (n && n.nodeType === 1) { if (/^(TEXTAREA|INPUT)$/.test(n.tagName)) n.setAttribute("writingsuggestions", "false"); else _noWS(n); } }).observe(document.documentElement, { childList: true, subtree: true }); } catch (e) {} };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", _goWS, { once: true }); else _goWS();
} catch (e) {}
