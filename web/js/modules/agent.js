/* Module Agent — CHATS « COMME MUSE » : LISTE + VUE UNIQUE (refonte 21/10/2026,
   re-spécification d'Ahadi : « structure la partie chats comme le tien — onglets
   d'accès à gauche avec l'historique accessible pour chaque chat, listés comme
   les tiens ; l'intérieur des chats doit être clean et configuré comme les
   tiens ; je n'ai pas vu l'option joindre dossiers/fichiers dans les chats,
   ni le micro pour le conversationnel comme tu me l'avais promis »).

   CE QUI CHANGE PAR RAPPORT À LA REFONTE MULTI-PANNEAUX (20/10, écartée) :
   - la grille de panneaux disparaît : à GAUCHE, une colonne (~300 px) avec le
     bouton « + Nouvelle conversation » et la LISTE des conversations (GET
     /api/conversations) — titre, cerveau, heure relative, PASTILLE D'ÉTAT EN
     DIRECT (en cours = pulsée, non vue = accent, repos = discrète) ; un clic
     ouvre la conversation dans la zone principale, la ligne ouverte est
     surlignée ; Ahadi suit ses conversations depuis la liste, comme dans le
     chat Muse ;
   - la zone principale montre UNE conversation : en-tête fine (titre +
     sélecteurs compacts Cerveau / Profondeur / Mode, par conversation),
     bandeau Direct d'UNE ligne au-dessus du fil, fil CLEAN (QUE les messages :
     bulles utilisateur, réponses de Nova, cartes d'approbation — elles font
     partie de la conversation), composeur complet en bas ;
   - la TRACE d'exécution (étapes, outils, notices, plan, routine) vit dans un
     tiroir « Détails » RE PLIÉ par défaut, sous l'en-tête — plus jamais dans
     le fil. Le bloc Supervision reste sous la mise en page, replié ;
   - le COMPOSEUR gagne ce qui manquait : bouton JOINDRE (trombone) avec menu
     « Joindre des fichiers… » / « Joindre un dossier entier… » (attach.js —
     la MÊME implémentation que le chat de l'Accueil, POST /api/chat/upload),
     chips au-dessus du champ, glisser-déposer sur le fil, coller dans le
     champ ; bouton MICRO (dictée par voice.js — POST /api/stt, la même voie
     que la barre vocale de l'Accueil — le texte tombe dans le composeur) et
     bascule « Conversation vocale » (réponses parlées par POST /api/tts +
     barge-in, même voice.js) ;
   - la machinerie d'exécution NE CHANGE PAS : sessions isolées par
     conversation (SSE propre, runToken, AbortController, approbations,
     budget dur, plan éditable, Reprendre, routine) — ouvrir A pendant que B
     tourne ne tue pas B ; revenir sur B recharge son historique moteur.

   CONTRATS MOTEUR UTILISÉS (inchangés, vérifiés dans le code existant) :
   POST /api/chat (SSE ; body { text, autonomie, tools, depth/mode,
   conversation_id?, brain?, voice? }), événements meta/brain/step/confirm/
   tool/failover/retry/usage/delta/error/done ; POST /api/chat/stop
   { conversation_id } ; POST /api/confirm ; POST /api/chat/upload?name=
   (corps brut, pièces jointes) ; POST /api/stt (audio brut → { text }) ;
   POST /api/tts ({ text } → flux audio, en-tête X-Nova-Voice) ;
   GET /api/conversations ({items} SEULEMENT — les cerveaux vivent dans
   /api/state, LOT1), GET /api/conversation?id= ;
   GET /api/couts?jours=7, /api/settings (agent_rules), /api/rules,
   /api/actions, POST /api/dots/save. Aucune route inventée. */
import { md, normalizeAnswer, sse, fmtRelFR, truncWords, cleanResume, bindChatMessage, fmtNumFR, stampMsgTime, daySepEl, sameDay, prevStampedTs, msgTimeLabel, voixLabel } from "../core.js";   // fmtNumFR ajouté par l'applicateur vague 2 : requis par MN2-5 hunk 5 et MN2-6 hunk 3 (absent de la portée, vérifié à l'application)
import { DEPTHS, depthBody, getDepth, confirmCostIncrease } from "../depth.js";   /* Phase 4 : alerte si le coût monte */
import { createAttachments, renderSent, describeForBrain, visionImages, splitBrainBlock } from "../attach.js";   // V4-D : visionImages → champ « images » de /api/chat
import { createVoice, createVoiceLive, parseBiChannel, speakable } from "../voice.js";
import { mountPlush } from "../plush.js";
import { createNarr } from "../narr-dedupe.js";   /* 25/10 : anti-doublon de narration après une étape d'outil */
import { setSharedMood } from "../avatar.js";
import { renderFeedCard } from "../feedcard.js";
import { isArchived, archiveFilter, archiveButton } from "../conv-archive.js";   // LOT3 (25/10) : Archiver / filtre « Archivées » — rien n'est supprimé
import * as FC from "../feedcard.js";   // V4-D : sélecteur de canal du Fil direct — exports du lot C (channelOf, isFundings, mountFundingsBand) lus de façon défensive   // 24/10 : carte d'arrivée unique du fil (BLUF · tri · commentaire · DOTS · mémoire)

const arrOf = (j, ...keys) => { if (Array.isArray(j)) return j; for (const k of keys) if (j && Array.isArray(j[k])) return j[k]; return []; };
const trunc = (s, n) => { s = String(s ?? ""); return s.length > n ? s.slice(0, n) + "…" : s; };
const READONLY_TOOLS = new Set(["web_fetch", "web_search", "read_file", "calendar", "reminders", "system", "know", "recall", "mail_unread", "mail_week", "processes", "nova_self", "teams_read", "brvm_cours", "flux_titres"]);
const AGENT_TOOLS = ["web_search", "web_fetch", "mail_unread", "calendar", "reminders", "read_file", "transcribe", "remember", "recall", "system", "know", "draft_reply", "nova_self", "shell", "applescript", "open", "processes", "app"];
const AUD_KEY = "nova2_audit", RUN_KEY = "nova2_agent_run", BUD_KEY = "nova2_budget", PLAN_KEY = "nova2_plan_first", WATCH_KEY = "nova2_watch";
const OPEN_KEY = "nova2_agent_open_panes", ACTIVE_KEY = "nova2_agent_active_pane", SIDE_KEY = "nova2_agent_side";
const DIRECT_UNREAD_KEY = "nova2_direct_unread_v1";   // FIX-DIRECT-WEB (correctif ⑤ du diagnostic Direct/Fil) : état lu/non-lu du Fil direct, PARTAGÉ avec le shell (badge du rail) — { cid, seen, count, seeded }
const MIRROR_KEY = "nova2_direct_mirror_v1";   // R-MIROIR (SPARK8-B) : registre durable des miroirs Direct par cid — { cid: [{ feed, msg }] }, plafond 30 par cid, dédup par feed
function mirrorRegistry() { try { return JSON.parse(localStorage.getItem(MIRROR_KEY) || "{}") || {}; } catch (e) { return {}; } }
/* FIXES-MAIL (24/10) : enrichissement EN PLACE — la carte d'une arrivée est remplacée
   (même feed) quand le moteur a lu le corps ; le registre garde UNE entrée par feed. */
function mirrorRegistryUpsert(cid, feed, msg, meta) {
  try {
    cid = String(cid || ""); feed = String(feed || ""); msg = String(msg || "");
    if (!cid || !feed || !msg) return false;
    const reg = mirrorRegistry();
    const arr = reg[cid] || (reg[cid] = []);
    const i = arr.findIndex((e) => String((e && e.feed) || "") === feed);
    const entry = { feed, msg, ...(meta && typeof meta === "object" ? meta : {}) };
    if (i >= 0) arr[i] = entry; else arr.push(entry);
    while (arr.length > 30) arr.shift();
    try { localStorage.setItem(MIRROR_KEY, JSON.stringify(reg)); } catch (e) {}
    return true;
  } catch (e) { return false; }
}
function mirrorRegistryAdd(cid, feed, msg, meta) {
  try {
    cid = String(cid || ""); feed = String(feed || ""); msg = String(msg || "");
    if (!cid || !feed || !msg) return false;
    const reg = mirrorRegistry();
    const arr = reg[cid] || (reg[cid] = []);
    for (const e of arr) { if (String((e && e.feed) || "") === feed) return false; }
    arr.push({ feed, msg, ...(meta && typeof meta === "object" ? meta : {}) });
    while (arr.length > 30) arr.shift();
    try { localStorage.setItem(MIRROR_KEY, JSON.stringify(reg)); } catch (e) {}
    return true;
  } catch (e) { return false; }
}
/* ── FD (23/10) — FEEDS & DIRECTS PARITÉ MUSE ──────────────────────────
   La composition du fil se dérive des CHAMPS du message stocké (urgent,
   kind, box, who, action, gravite — produits par le moteur), jamais
   d'une heuristique sur le texte. fdMetaOf : les métadonnées qui
   voyagent avec le miroir (registre durable, poussée immédiate, repli
   réseau) pour que badges et réaction survivent aux rejeux. */
function fdMetaOf(src) {
  if (!src || typeof src !== "object") return {};
  const meta = {};
  if (src.urgent === true) meta.urgent = true;
  for (const k of ["kind", "box", "who", "ts", "gravite"]) { const v = src[k]; if (v != null && v !== "") meta[k] = v; }
  if (src.action && typeof src.action === "object") meta.action = src.action;
  return meta;
}
const FD_BOX_LABELS = { ol: "Outlook", gm: "Gmail", tm: "Teams", wa: "WhatsApp", gh: "GitHub", zm: "Zoho" };   // miroir de DirectCompose.boxNames (moteur)
function fdSourceLabel(m) {
  const kind = String((m && m.kind) || "");
  const box = String((m && m.box) || "");
  if (kind === "dot.done") return "Éclat";   // V5-Y : la boîte d'un Éclat est son identifiant technique (« boites ») — le titre nomme déjà l'Éclat
  if (kind === "brief") return "Brief";
  if (kind === "meeting") return "Agenda";
  if (kind === "teams.new") return "Teams";
  if (kind === "mail.new") return FD_BOX_LABELS[box] || "Boîte";
  return FD_BOX_LABELS[box] || "Direct";
}
/* Réaction du compagnon à une arrivée VIVANTE (jamais un rejeu, jamais
   l'historique) : la gravité composée par le moteur (champ gravite,
   règles fermées R-G1/R-G2 de DirectCompose) pose l'humeur PV
   correspondante — TTL dans la bande PV (12–30 s). Aucune gravité
   portée par les données = aucune humeur : on ne simule pas une
   importance que les données n'ont pas. */
function fdPandaReact(m) {
  try {
    if (!m) return;
    if (m.gravite === "grave") setSharedMood("grave", 20000);
    else if (m.gravite === "legere") setSharedMood("legere", 15000);
  } catch (e) {}
}
/* Empreinte d'un message rendu — fdAppendLive ne descend en incrémental
   que si le fil relu commence exactement par ces messages. */
function fdMsgSig(m) {
  const c = String((m && m.content) || "");
  let x = 5381; for (let i = 0; i < c.length; i++) x = ((x << 5) + x + c.charCodeAt(i)) >>> 0;
  return [String((m && m.role) || ""), String((m && m.feed) || ""), String((m && m.ts) || ""), c.length, x.toString(36)].join("|");
}
// TRACE-MIROIR (SPARK8-B2) : auxiliaire de core.js (window), no-op si absent — la trace ne bloque jamais le miroir.
const traceMirror = (typeof window !== "undefined" && window.traceMirror) || function () {};
const MAX_RESTORE = 6;
const HISTORY_RENDER_MAX = 1000;   // FIX-RENDU ③ (forensique écran §2.4) : borne de SÉCURITÉ du rendu d'historique — le plus gros fil constaté (Fil direct) fait 80 messages ; 1 000 = 12,5× cette borne. En dessous : TOUT le fil est rendu ; au-dessus : les plus récents, et le fil le DIT (jamais de troncature silencieuse).
const fmtRel = (ts) => (ts ? fmtRelFR(ts) : "");   // DS §9.8 : relatif FR partagé, plus de copie locale
/* V5-W (25/10) — TITRE LISIBLE d'une conversation. Les fils de routine étaient tous titrés
   « Exécute exactement cette com… » : la formule d'appel est retirée, l'étiquette [Routine]
   passe en méta, une commande se nomme par ce qu'elle lance (script + arguments, chemins
   réduits à leur nom). Le titre STOCKÉ reste intact (infobulle) — affichage seulement. */
/* V5-Y (25/10) — le préambule ENTIER est reconnu : « Exécute exactement cette commande avec ton
   outil shell, sans rien modifier ni ajouter, puis dis-moi seulement si elle est lancée : <cmd> »
   (avant, seule la formule d'ouverture tombait et « avec ton outil… » devenait le titre). La
   commande est nommée par ce qu'elle FAIT (« Build Nova (package_app.sh) ») ; un titre stocké
   tronqué avant les deux-points devient « Commande shell ». Un titre en CAPITALES passe en casse
   de phrase (sigles connus conservés). */
const CMD_LEAD = /^(?:ex[ée]cute(?:r|z)?|lance(?:r|z)?|run)\b[^:]{0,40}?\b(?:commande|command)s?\b/i;
const CMD_ACRO = /^(?:BRVM|CAFU|GHO|WCA|ESA|PDF|RH|ONG|ONU|UE|IA|API|URL|CV|OK|MAJ|TODO|SBIF|UEMOA|BCEAO|FCFA|XOF|USD|EUR|PV|CR|ODJ|KPI|N°)$/;
const CMD_KNOWN = [
  [/package_app\.sh|build_app\.sh|make_app\.sh/i, (m) => "Build Nova (" + m[0] + ")"],
  [/\bswift\s+build\b/i, () => "Compilation Swift (swift build)"],
  [/\bswift\s+test\b/i, () => "Tests Swift (swift test)"],
  [/\bxcodebuild\b/i, () => "Build Xcode (xcodebuild)"],
  [/\bgit\s+(?:-C\s+\S+\s+)?(pull|push|commit|status|log|fetch|clone|checkout|diff)\b/i, (m) => "Git " + m[1].toLowerCase()],
  [/\bnpm\s+(install|run\s+\S+|test|ci)\b/i, (m) => "npm " + m[1]],
  [/\bbrew\s+(install|upgrade|update)\b/i, (m) => "Homebrew " + m[1]],
  [/\bopen\s+-a\s+(?:"([^"]+)"?|'([^']+)'?|(\S+))/i, (m) => "Ouvre " + (m[1] || m[2] || m[3]).replace(/\.app$/i, "")],
  [/\b(?:pkill|killall)\s+(?:-\S+\s+)*["']?([^\s"'&|;]+)/i, (m) => "Arrête " + m[1]],
  [/\blaunchctl\s+(load|unload|kickstart|bootstrap|bootout)\b/i, (m) => "Service launchctl (" + m[1] + ")"],
  [/\b(?:tail|cat|less)\s+(?:-\S+\s+)*\S*?([^\s/]+\.log)\b/i, (m) => "Lecture du journal " + m[1]],
];
let cmdRaw = false;   // vrai quand le libellé EST la commande elle-même (rendue en chasse fixe dans la liste)
function cmdLabel(c) {
  cmdRaw = false;
  const raw = String(c || "").replace(/^[`«"'\s]+|[`»"'\s]+$/g, "").trim();
  if (!raw) return "";
  for (const [re, f] of CMD_KNOWN) { const m = re.exec(raw); if (m) return f(m); }
  /* Commande principale : on écarte cd/export/source/nohup/sudo, les variables et les redirections. */
  const parts = raw.split(/\s*(?:&&|\|\||;|\|)\s*/).map((x) => x.replace(/\s*[12]?>>?\s*\S+/g, "").replace(/\s*&\s*$/, "").trim()).filter(Boolean);
  const main = parts.find((x) => !/^(?:cd|export|source|\.|set|sleep|echo|true)\b/.test(x)) || parts[0] || raw;
  let w = main.replace(/^(?:(?:nohup|sudo|env|time|exec)\s+|[A-Z_][A-Z0-9_]*=\S+\s+)+/, "");
  const script = /(?:^|\s)(?:(?:python3?|bash|zsh|sh|node|ruby|perl|swift|osascript)\s+)?(?:\S*\/)?([\w.-]+\.(?:sh|py|js|rb|pl|swift|scpt|command))\b/.exec(w);
  if (script) return "Script " + script[1];
  w = w.replace(/(?:~|\.{0,2})?\/(?:[^\s/]+\/)+([^\s/]+)/g, "$1");   // chemins → nom de fichier
  cmdRaw = true;
  return w.split(/\s+/).slice(0, 4).join(" ");
}
function sentenceCase(t) {
  const letters = t.replace(/[^A-Za-zÀ-ÖØ-öø-ÿ]/g, "");
  if (letters.length < 8) return t;
  const up = letters.replace(/[^A-ZÀ-ÖØ-Þ]/g, "").length;
  if (up / letters.length < 0.7) return t;
  const low = t.split(/(\s+)/).map((w) => (CMD_ACRO.test(w.replace(/[^\wÀ-ÿ°]/g, "")) ? w : w.toLowerCase())).join("");
  return low.charAt(0).toUpperCase() + low.slice(1);
}
export function niceTitle(raw) {
  let t = String(raw || "").replace(/\s+/g, " ").trim();
  const tags = [];
  for (let i = 0; i < 4; i++) { const m = /^\[([^\]]{1,30})\]\s*/.exec(t); if (!m) break; tags.push(m[1].trim()); t = t.slice(m[0].length); }
  let kind = tags.find((x) => /routine|rituel|éclat|eclat/i.test(x)) || "";
  let isCmd = false;
  if (CMD_LEAD.test(t)) {
    isCmd = true;
    kind = kind || "Commande";
    const colon = t.indexOf(":", t.search(CMD_LEAD));
    const after = colon >= 0 ? t.slice(colon + 1).replace(/\s+(?:et|puis)\s+(?:rends|renvoie|donne|montre|affiche|dis)\b.*$/i, "").trim() : "";
    cmdRaw = false;
    t = cmdLabel(after) || "Commande shell";
  } else {
    /* 29/10 (audit UI) : un titre qui commence par un chemin (« /Users/…/Fichier.pdf … ») montre le NOM du fichier. */
    const pm = /^(?:\/Users\/|~\/)\S*\/([^\/\s]+)(.*)$/.exec(t);
    if (pm) t = (pm[1] + pm[2]).trim();
    t = t.replace(/^(?:peux-tu|pourrais-tu|merci de|stp|s'il te plaît)\s+/i, "");
    t = sentenceCase(t);
    t = t ? t.charAt(0).toUpperCase() + t.slice(1) : "";
  }
  return { t: t || "Conversation", kind: kind ? kind.charAt(0).toUpperCase() + kind.slice(1) : "", cmd: isCmd && cmdRaw };
}

export async function mount(root, ctx) {
  const { api, bus, esc, h, ic } = ctx;
  /* V5-W (25/10) — CARTE D'ERREUR CALME et unique : titre, cause en clair quand elle est reconnue
     (crédit, clé, limite, surcharge, délai), détail technique replié (jamais un JSON brut en vitrine),
     rappel de ce qui est conservé, action. Rien n'est relancé sans clic. */
  const errHuman = (m) => {
    const t = String(m || "");
    if (/credit balance|insufficient[_ ]quota|billing|cr[ée]dits?\s+[ée]puis/i.test(t)) return "Crédits du fournisseur épuisés : le cerveau a refusé la requête. Recharge le compte ou choisis un autre cerveau.";
    if (/\b401\b|invalid[_ ]api[_ ]key|unauthori[sz]ed|cl[ée] (?:refus|invalide)/i.test(t)) return "Clé refusée par le fournisseur : vérifie-la dans Réglages › Données & comptes.";
    if (/\b429\b|rate[_ ]limit|too many requests/i.test(t)) return "Limite de débit du fournisseur atteinte : réessaie dans un instant.";
    if (/overloaded|\b5\d\d\b|service unavailable|bad gateway/i.test(t)) return "Fournisseur surchargé ou indisponible pour le moment.";
    if (/timed? ?out|d[ée]lai d[ée]pass|timeout/i.test(t)) return "Le cerveau n'a pas répondu dans le délai.";
    return "";
  };
  function errCard(title, message, note, action) {
    const human = errHuman(message);
    return h("div", { class: "cs-err", role: "alert" },
      h("div", { class: "cs-err-head" }, h("span", { class: "cs-err-ic", html: ic("alert", 15) }), h("span", { class: "cs-err-t" }, title)),
      human || message ? h("div", { class: "cs-err-msg" }, human || message) : null,
      human && message ? h("details", { class: "cs-err-det" }, h("summary", {}, "Détail technique"), h("code", {}, message)) : null,
      note ? h("div", { class: "cs-err-note" }, note) : null,
      action ? h("div", { class: "cs-err-acts" }, action) : null);
  }
  let dead = false;
  const offs = [];
  const onBus = (t, f) => { const off = bus.on(t, f); offs.push(off); return off; };

  /* ── Préférences PARTAGÉES (écran) ──────────────────────────────────── */
  let budget = { min: 10, steps: 40 };   // FIX-BUDGET 21/10 : plus de budget jetons (compteurs informatifs). AUTONOMIE A1 22/10 : durée/étapes ne sont plus un BUDGET DUR mais des REPÈRES d'alerte — tous les runs de ce module sont ordonnés par Ahadi (envoi, file, Reprendre, panneau) et vivent en piste entière ; au dépassement, une seule alerte journalisée par run, jamais d'arrêt demandé au moteur.
  try { Object.assign(budget, JSON.parse(localStorage.getItem(BUD_KEY) || "{}")); } catch (e) {}
  const saveBudget = () => { try { localStorage.setItem(BUD_KEY, JSON.stringify(budget)); } catch (e) {} };
  let planFirst = true;
  try { planFirst = localStorage.getItem(PLAN_KEY) !== "0"; } catch (e) {}
  const setPlanFirst = (v) => { planFirst = v; try { localStorage.setItem(PLAN_KEY, v ? "1" : "0"); } catch (e) {} for (const s of sessions.values()) s.syncPlanBtn(); };
  let watchMode = false;
  try { watchMode = localStorage.getItem(WATCH_KEY) === "1"; } catch (e) {}
  const autoDefault = () => { try { return localStorage.getItem("nova2_autonomie") || "total"; } catch (e) { return "total"; } };

  /* ── Journal d'audit local (décisions prises dans CETTE interface) ──── */
  function audit(kind, what, result) {
    try {
      const a = JSON.parse(localStorage.getItem(AUD_KEY) || "[]");
      a.push({ at: Date.now(), kind, what: String(what).slice(0, 220), result: String(result || "").slice(0, 220) });
      while (a.length > 300) a.shift();
      localStorage.setItem(AUD_KEY, JSON.stringify(a));
    } catch (e) {}
    renderAudit();
  }
  const auditLocal = () => { try { return JSON.parse(localStorage.getItem(AUD_KEY) || "[]"); } catch (e) { return []; } };

  /* ── Règles d'approbation (source = moteur /api/settings) ───────────── */
  let rules = [], rulesFromEngine = false;
  /* §30 (21/10) : cerveau par défaut des Réglages (clé « brain ») — lu dans
     la même réponse /api/settings ; les nouvelles conversations le
     présélectionnent au lieu d'afficher « automatique » contre l'ordre
     d'Ahadi (Spark 1.3 par défaut). */
  let defaultBrainId = "";
  let defaultBrainLabel = "";
  async function loadRules() {
    try {
      /* §35 (21/10) : /api/state, PAS /api/settings — la réponse settings
         ne contient QUE {settings} (App.swift, GET /api/settings) ; la
         liste des cerveaux vit dans /api/state (même constat que le
         module Réglages, qui y lit ses cerveaux depuis toujours).
         Le §33 récoltait j.brains sur la mauvaise route : toujours vide. */
      const j = await api.get("/api/state");
      const r = j && j.settings && j.settings.agent_rules;
      if (Array.isArray(r)) { rules = r; rulesFromEngine = true; }
      const db = j && j.settings && j.settings.brain;
      /* §33 (21/10) — CAUSE RACINE du « Cerveau : automatique » éternel,
         établie dans les sources moteur : GET /api/conversations ne renvoie
         QUE {items} (App.swift) — la liste des cerveaux n'y a jamais
         existé, donc brainsList restait vide et populateBrains() ne
         remplissait jamais le sélecteur. La liste vit dans CETTE réponse
         /api/state (champ brains — la même source que le sélecteur des
         Réglages ; le commentaire d'origine disait « /api/settings » à tort,
         contredisant le §35 ci-dessus — rectifié au LOT1, m20) : on la
         récolte ici, puis on (re)peuple les sélecteurs. */
      metaOnlyUI = !!(j && j.settings && j.settings.meta_only === true);
      const regList = Array.isArray(j.brains) ? j.brains.filter(keepBrain) : [];
      if (regList.length) brainsList = regList.map((b) => ({ id: String(b.id), label: String(b.label || b.id), etat: String(b.etat || ""), meta: b.meta }));   // DIAG2-CERVEAUX : l'état servi (prêt / désactivé / sans clé / en panne…) n'est plus jeté — le sélecteur doit le montrer (H2)
      if (db && db !== "auto") {
        defaultBrainId = String(db);
        /* À défaut d'identifiant égal dans la liste, on garde le LIBELLÉ
           du cerveau par défaut pour présélectionner par libellé. */
        const reg = regList.find((b) => String(b.id) === defaultBrainId);
        if (reg) defaultBrainLabel = String(reg.label || "");
      }
      if (regList.length || defaultBrainId) { for (const s of sessions.values()) s.populateBrains(); }
    } catch (e) { /* repli local ci-dessous */ }
    if (!rulesFromEngine) { try { rules = JSON.parse(localStorage.getItem("nova2_agent_rules") || "[]"); } catch (e) { rules = []; } }
    renderRules();
  }
  async function saveRules() {
    try { localStorage.setItem("nova2_agent_rules", JSON.stringify(rules)); } catch (e) {}
    if (rulesFromEngine) { try { await api.post("/api/settings", { agent_rules: rules }); } catch (e) { ctx.toast("Règles gardées localement (moteur injoignable).", true); } }
    renderRules();
  }
  const ruleFor = (tool) => rules.find((r) => r && r.tool === tool && r.type === "always");

  /* ── Estimation : historique réel des appels cerveaux (/api/couts) ───── */
  let couts = null;
  async function loadCouts() { try { couts = await api.get("/api/couts?jours=7"); } catch (e) { couts = null; } renderEst(); }
  function estFor(brainId) {
    const rows = (couts && couts.brains) || [];
    if (!rows.length) return null;
    const pick = brainId ? rows.find((r) => r.brain === brainId) : null;
    const src = pick || rows.reduce((a, r) => ({ ms: a.ms + (r.ms_avg || 0) * (r.calls || 0), usd: a.usd + (r.usd || 0), calls: a.calls + (r.calls || 0) }), { ms: 0, usd: 0, calls: 0 });
    const calls = pick ? (pick.calls || 0) : src.calls;
    if (!calls) return null;
    return { msAvg: pick ? (pick.ms_avg || 0) : Math.round(src.ms / calls), usdAvg: (pick ? (pick.usd || 0) : src.usd) / calls, calls, brain: pick ? pick.brain : "tous cerveaux" };
  }
  function estText(brainId) {
    const e = estFor(brainId);
    if (!e) return "Estimation : aucun historique d'appels sur 7 jours — pas de chiffre inventé.";
    return "Estimation (historique réel 7 j, /api/couts — " + e.calls + " appels, " + e.brain + ") : ~" +
      (e.msAvg ? (e.msAvg / 1000).toFixed(1) + " s" : "?") + " et ~" + e.usdAvg.toFixed(4) + " $ par appel de cerveau. " +
      "La chaîne du moteur est bornée (6 cerveaux max, 25 s par tentative). Étiquette : estimation, pas un devis.";
  }

  /* ── Mise en page : colonne des conversations + zone principale ─────── */
  const layout = h("div", { class: "cs-layout" });
  const listEl = h("div", { class: "cs-list", "aria-label": "Historique des conversations" });
  let archView = "actives";   // LOT3 : « Actives » masque les archivées (manuel + auto) ; « Archivées » ne montre qu'elles
  const archFilter = archiveFilter((v) => { archView = v; renderList(); });
  listEl.addEventListener("click", () => { try { layout.classList.remove("side-peek"); } catch (e) {} });
  layout.addEventListener("keydown", (e) => { if (e.key === "Escape" && layout.classList.contains("side-peek")) { layout.classList.remove("side-peek"); } });   /* 25/10 : Échap referme la liste */
  const newBtn = h("button", { class: "btn acc cs-newbtn", onclick: () => { try { layout.classList.remove("side-peek"); } catch (e) {} newConversation(true); } },   /* 25/10 : la liste se referme aussi après « Nouvelle conversation » */
    h("span", { html: ic("plus", 15) }), " Nouvelle conversation");
  const trustBtn = h("button", { class: "btn cs-iconbtn cs-trustbtn", title: "Supervision & confiance — régimes, règles, audit", "aria-label": "Supervision et confiance", html: ic("shield", 16) });
  const side = h("aside", { class: "cs-side" },
    h("div", { class: "cs-side-top" }, newBtn, trustBtn,
      h("div", { class: "cs-side-label" }, "Historique — clique pour ouvrir, la pastille dit l'état en direct")),
    archFilter, listEl);
  const main = h("div", { class: "cs-main" });
  /* 01/11 (fenêtre étroite) : sous 760 px la liste est un TIROIR (fond opaque) posé sur un VOILE ; un clic sur le
     voile la referme. Le voile n'existe visuellement qu'en mode tiroir (CSS @container cs), jamais en pleine largeur. */
  const scrim = h("div", { class: "cs-scrim", "aria-hidden": "true", onclick: () => { layout.classList.remove("side-peek"); } });
  layout.append(side, scrim, main);
  root.append(layout);
  try { if (localStorage.getItem(SIDE_KEY) === "0") layout.classList.add("side-hidden"); else if (window.innerWidth <= 1150 && localStorage.getItem(SIDE_KEY) === null) layout.classList.add("side-hidden"); } catch (e) {}
  /* DS §2.4 : les régimes (liste réduite / volet superposé) sont pilotés par le CSS
     seul — la mesure JS au montage (root.clientWidth < 900) est supprimée. */

  /* ══ Registre des sessions (une par conversation ouverte) ═════════════ */
  const sessions = new Map();          // sessionId → session (ordre d'ouverture)
  const sessionsByCid = new Map();     // conversation_id → session
  let sessionSeq = 0;
  let activeId = "";
  let brainsList = [];                 // cerveaux du moteur (GET /api/conversations)
  /* 01/11 (voix-rapide, défaut d'interface) : en meta_only, le sélecteur ne propose QUE les cerveaux Meta. Le moteur filtre
     déjà /api/state (Router.healthSnapshot) ; ce filet écarte en plus toute ligne marquée meta === false (cache d'état ancien). */
  let metaOnlyUI = false;
  const keepBrain = (b) => !!(b && b.id) && !(metaOnlyUI && b.meta === false);
  const convIndex = new Map();         // conversation_id → { title, updated, brain }
  /* V5-Y : items Direct masqués localement (bandeau) — mémorisés pour la SESSION de l'app
     (sessionStorage) : un ✕ ne revient pas à chaque rechargement du module. */
  const BAND_X_KEY = "nova2_dband_dismissed";
  const bandDismissed = new Set((() => { try { const a = JSON.parse(sessionStorage.getItem(BAND_X_KEY) || "[]"); return Array.isArray(a) ? a : []; } catch (e) { return []; } })());
  const saveBandDismissed = () => { try { sessionStorage.setItem(BAND_X_KEY, JSON.stringify([...bandDismissed].slice(-200))); } catch (e) {} };
  const activeSession = () => sessions.get(activeId) || sessions.values().next().value || null;

  /* ── FIX-DIRECT-WEB (22/10, correctif ⑤ du diagnostic Direct/Fil) ───────
     Le Fil direct reçoit les événements sans aucun signal hors du fil ouvert :
     ni épingle dans la liste, ni compteur. Correctif, côté web seul :
       · le fil est ÉPINGLÉ en tête de la liste (rendu de renderList) ;
       · un compteur de non-lus vit dans localStorage (DIRECT_UNREAD_KEY),
         PARTAGÉ avec le shell qui peint le badge du rail « Conversations »
         (le shell compte les arrivées quand ce module n'est pas monté ;
         ici, on RECALCULE sur vérité moteur : /api/conversations donne le
         nombre total de messages du fil, « seen » est le total acquitté à la
         dernière ouverture — non-lus = total − seen, jamais un compteur
         incrémental qui dérive).
     L'id du fil s'apprend comme prochat.js : GET /api/proactive/feed
     (champ direct_thread_id), relayé par chaque événement « direct.appended »
     (d.conv) et par l'état persisté. Premier apprentissage = amorçage
     SILENCIEUX (patron « seeded » de direct.js) : l'historique déjà là n'est
     pas badgé, seuls les messages arrivés ensuite comptent. ─────────────── */
  let engineDirectCid = "";            // 24/10 : id du Fil direct servi par le moteur (/api/proactive/feed → direct_thread_id)
  let moduleShown = false;             // piloté par onShow/onHide du cycle de vie (plus bas)
  const directStore = () => { try { return JSON.parse(localStorage.getItem(DIRECT_UNREAD_KEY) || "{}") || {}; } catch (e) { return {}; } };
  const directSave = (st) => { try { localStorage.setItem(DIRECT_UNREAD_KEY, JSON.stringify(st)); } catch (e) {} };
  let dst = directStore();             // { cid, seen, count, seeded } — cache local, resynchronisé avant chaque usage
  let dstSnap = JSON.stringify(dst);   // empreinte de l'état AVANT mutation : directSync() retourne la même référence que dst, comparer st à dst après mutation ne verrait jamais de changement — la détection se fait donc contre cette empreinte
  const directSync = () => { dst = directStore(); dstSnap = JSON.stringify(dst); return dst; };
  function directEmit() { try { bus.emit("nova:direct-unread", { cid: dst.cid || "", count: dst.count || 0 }); } catch (e) {} }
  function directSet(st) {
    const changed = JSON.stringify(st) !== dstSnap;
    dst = st; directSave(st); dstSnap = JSON.stringify(st);
    if (changed) { directEmit(); renderList(); }
  }
  function learnDirectCid(cid) {
    cid = String(cid || ""); if (!cid) return;
    const st = directSync();
    if (st.cid === cid) return;
    st.cid = cid;
    if (!st.seeded) {                  // amorçage : l'historique n'est pas badgé ; on préserve ce que le shell a déjà compté (arrivées depuis le chargement de la page, avant le premier montage de ce module)
      const total = (convIndex.get(cid) || {}).count || 0;
      st.seen = Math.max(0, total - (st.count || 0)); st.seeded = true;
    }
    directSet(st);
  }
  function recomputeDirect() {         // vérité moteur : non-lus = messages du fil − acquittés
    const st = directSync(); if (!st.cid) return;
    const meta = convIndex.get(st.cid); if (!meta) return;
    const total = meta.count || 0;
    let dirty = false;
    if (!st.seeded) { st.seen = Math.max(0, total - (st.count || 0)); st.seeded = true; dirty = true; }   // l'amorçage aussi doit être persisté, même si le compteur ne bouge pas
    const n = Math.max(0, total - (st.seen || 0));
    if (n !== (st.count || 0)) { st.count = n; dirty = true; }
    if (dirty) directSet(st);
  }
  function markDirectSeen() {          // le fil vient d'être ouvert et regardé : tout est acquitté (total moteur lu dans convIndex, rafraîchi par loadHistory)
    const st = directSync(); if (!st.cid) return;
    const meta = convIndex.get(st.cid);
    const total = (meta && meta.count) || 0;
    if (total > (st.seen || 0) || (st.count || 0) !== 0) { st.seen = total; st.count = 0; st.seeded = true; directSet(st); }
  }
  const readingDirect = () => { directSync(); const s = activeSession(); return !!(moduleShown && dst.cid && s && s.cid === dst.cid); };

  /* ── MIROIR DIRECT → SESSION ACTIVE (C3 n°7 Direct, volet WEB) ──────────
     Les événements Direct se matérialisent aussi dans la conversation active,
     en affichage LOCAL seul (ni stock moteur côté active, ni ré-émis au bus).
     Par session : _mirrorFeeds (déduplication par feed), _mirrorPending (attente
     pendant run/chargement), _mirrorRendered (rendus, plafond 30, ré-ajoutés
     après chaque loadConversation). Initialisation paresseuse. ─────────── */
  /* 24/10 : dans une conversation ordinaire, les arrivées du Fil direct sont
     COMPACTES (une ligne : source · titre · heure, clic = déplier) — elles ne
     noient plus la réponse de Nova. Le Fil direct, lui, garde les cartes pleines. */
  /* V5-T (25/10) : les arrivées du Fil direct VIVENT dans le Fil direct. Une conversation
     ordinaire ne reçoit plus les cartes de routine (mail, Teams, Éclat) — seule une arrivée
     URGENTE (urgent / gravité « grave », champs du moteur) y laisse une ligne discrète
     « 🔴 Urgent · source · titre · heure → Fil direct », cliquable vers le Fil direct.
     Avant : chaque arrivée était recopiée en carte pleine dans la conversation affichée
     (et une seconde fois par prochat.js) — d'où les « doublons » ressentis. */
  const mirrorIsUrgent = (m) => { try { return FC.isRealUrgent ? FC.isRealUrgent(m) : !!(m && (m.urgent === true || m.gravite === "grave")); } catch (e) { return false; } };   // V5-Y : un échec d'Éclat de routine n'est pas une urgence (écran Éclats)
  function mirrorRender(s, m, live) {
    /* 26/10 : remplacé par le dépôt du message complet dans la conversation active (conv.append). */
    if (s && s.log) return null;
    if (!s || !s.log || !mirrorIsUrgent(m)) return null;
    const fid = (m.feed != null && m.feed !== "") ? String(m.feed) : "";
    let lk = ""; try { lk = FC.logicalKeyOf ? FC.logicalKeyOf(m) : ""; } catch (e) { lk = ""; }
    let bluf = ""; try { bluf = FC.parseComposed ? FC.parseComposed(m.content).bluf : ""; } catch (e) { bluf = ""; }
    bluf = String(bluf || String(m.content || "").split("\n")[0] || "").replace(/\*\*/g, "").replace(/^🔴\s*URGENT\s*[—-]\s*/i, "").trim();
    const srcL = fdSourceLabel(m);
    if (srcL && bluf.toLowerCase().startsWith(srcL.toLowerCase() + " ")) bluf = bluf.slice(srcL.length).replace(/^\s*[—–:-]\s*/, "");   // « Outlook — … » : la source est déjà nommée
    const time = (() => { const d = new Date(m.ts || 0); return isNaN(d) || !m.ts ? "" : d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" }); })();
    const go = () => { const c = String((directSync() && dst.cid) || engineDirectCid || ""); if (c) openConversation(c, false); };
    const el = h("div", { class: "msg fd-notice" + (live ? " fd-in" : ""), role: "button", tabindex: "0", title: "Ouvrir le Fil direct (la carte complète y est)", onclick: go,
      onkeydown: (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); go(); } } },
      h("span", { class: "fd-notice-u" }, "🔴 Urgent"),
      h("span", { class: "fd-notice-src" }, srcL),
      h("span", { class: "fd-notice-t" }, trunc(bluf || "(arrivée sans titre)", 140)),
      h("span", { class: "fd-notice-h" }, time),
      h("span", { class: "fd-notice-go" }, "Fil direct", h("span", { html: ic("arrow-up-right", 12) })));
    if (fid) el.dataset.feed = fid;
    if (lk) el.dataset.lk = lk;
    let prev = null;
    try { prev = [...s.log.querySelectorAll(".fd-notice")].find((k) => (fid && k.dataset.feed === fid) || (lk && k.dataset.lk === lk)) || null; } catch (e) { prev = null; }
    if (prev) { el.dataset.n = prev.dataset.n || "1"; prev.replaceWith(el); }
    else {
      /* 26/10 : des arrivées urgentes qui se suivent tiennent en UNE ligne (la plus récente + « +N ») au lieu de s'empiler dans la conversation. */
      const last = s.log.lastElementChild;
      if (last && last.classList && last.classList.contains("fd-notice")) {
        const n = (parseInt(last.dataset.n || "1", 10) || 1) + 1;
        el.dataset.n = String(n);
        el.querySelector(".fd-notice-go").before(h("span", { class: "fd-notice-more", title: n + " arrivées urgentes au Fil direct" }, "+" + (n - 1)));
        last.replaceWith(el);
      } else { el.dataset.n = "1"; s.log.append(el); }
    }
    return el;
  }
  function directMirrorSeen(s) { if (!s._mirrorFeeds) s._mirrorFeeds = new Set(); return s._mirrorFeeds; }
  function directMirrorPending(s) { if (!s._mirrorPending) s._mirrorPending = []; return s._mirrorPending; }
  function directMirrorRendered(s) { if (!s._mirrorRendered) s._mirrorRendered = []; return s._mirrorRendered; }
  function pushDirectMirror(s, m) {
    if (!s || s.dead || !m || !m.content) { try { if (s && s.dead) traceMirror(m && m.feed, "SESSION_MORTE", String(s.cid || ""), "", "push"); } catch (e2) {} return false; }
    /* 27/10 (diagnostic vérifié, point 3) : les cartes Direct vivent UNIQUEMENT dans le
       Fil direct. Déposées dans la conversation ouverte, elles polluaient le fil (9 à 13
       cartes comptées dans les fils J/Comet audités) et rafraîchissaient sa récence.
       Le registre de déduplication continue d'être alimenté en amont ; le rendu, non. */
    try { const _ds = directSync(); if (_ds && _ds.cid && String(s.cid || "") !== String(_ds.cid)) { traceMirror(m.feed, "FIL_DIRECT_SEUL", String(s.cid || ""), "", "push"); return false; } } catch (e) {}
    const feed = (m.feed != null && m.feed !== "") ? String(m.feed) : "";
    if (!mirrorIsUrgent(m)) { try { traceMirror(feed, "ROUTINE_NON_MIROITEE", String(s.cid || ""), "", "push"); } catch (e2) {} return false; }   // V5-T
    const seen = directMirrorSeen(s);
    if (feed && seen.has(feed) && !m.update) { try { traceMirror(feed, "DEJA_VU", String(s.cid || ""), "", "session"); } catch (e2) {} return false; }
    if (feed) seen.add(feed);
    if (s.running || s.historyLoading) { directMirrorPending(s).push(m); try { traceMirror(feed, s.running ? "FILE_RUN" : "FILE_CHARGEMENT", String(s.cid || ""), "", ""); } catch (e2) {} return true; }
    try { mirrorRender(s, m, true); } catch (e) { try { traceMirror(feed, "ECHEC_RENDU", String(s.cid || ""), "", String((e && e.name) || "Error") + ": " + String((e && e.message) || e || "")); } catch (e2) {} return false; }
    const rend = directMirrorRendered(s);
    rend.push(m);
    while (rend.length > 30) rend.shift();
    try { traceMirror(feed, "RENDU", String(s.cid || ""), "", ""); } catch (e2) {}
    return true;
  }
  function replayDirectMirrors(s) {   // fin de loadConversation : le journal vient d'être remplacé, on ré-ajoute les rendus puis on vide l'attente
    if (!s || s.dead) return;
    try { const _ds = directSync(); if (_ds && _ds.cid && String(s.cid || "") && String(s.cid) === String(_ds.cid)) return; } catch (e) {}   // R-MIROIR : le Fil direct ne reçoit jamais de miroirs, y compris par rejeu
    try {
      const cid = String(s.cid || "");
      const seen = directMirrorSeen(s);
      const rend = directMirrorRendered(s);
      const pend = directMirrorPending(s);
      const pendSnap = pend.slice();
      const fresh = [];
      if (cid) {
        let arr = [];
        try { const reg = mirrorRegistry(); arr = (reg && reg[cid]) || []; } catch (e) { arr = []; }
        if (Array.isArray(arr) && arr.length) {
          const known = new Set(seen);
          for (const m of rend) { try { const f = (m && m.feed != null && m.feed !== "") ? String(m.feed) : ""; if (f) known.add(f); } catch (e) {} }
          for (const m of pend) { try { const f = (m && m.feed != null && m.feed !== "") ? String(m.feed) : ""; if (f) known.add(f); } catch (e) {} }
          for (const en of arr) {
            const f = String((en && en.feed) || "");
            const c = String((en && en.msg) || "");
            if (!f || !c || known.has(f)) continue;
            if (!mirrorIsUrgent(fdMetaOf(en))) continue;   // V5-T : les miroirs de routine déjà au registre ne sont plus rejoués
            known.add(f); seen.add(f);
            const mObj = { feed: f, content: c, ...fdMetaOf(en) };
            rend.push(mObj);
            while (rend.length > 30) rend.shift();
            fresh.push(mObj);
          }
        }
      }
      let hasDom = false;
      try { hasDom = !!(s.log && s.log.querySelector && s.log.querySelector(".fd-notice")); } catch (e) { hasDom = false; }   // V5-T : le miroir est une ligne .fd-notice
      if (hasDom) {
        for (const m of fresh) { try { mirrorRender(s, m); } catch (e) {} }
        while (pend.length) {
          const m = pend.shift();
          try { mirrorRender(s, m); } catch (e) { continue; }
          rend.push(m);
          while (rend.length > 30) rend.shift();
        }
      } else {
        for (const m of rend.slice()) { try { mirrorRender(s, m); } catch (e) {} }
        while (pend.length) {
          const m = pend.shift();
          try { mirrorRender(s, m); } catch (e) { continue; }
          rend.push(m);
          while (rend.length > 30) rend.shift();
        }
      }
      try {
        for (const en of fresh) { try { traceMirror(en && en.feed, "RENDU_DIFFERE", cid, "", "rejeu-registre"); } catch (e2) {} }
        for (const m of pendSnap) { try { traceMirror(m && m.feed, "RENDU_DIFFERE", cid, "", "rejeu-file"); } catch (e2) {} }
      } catch (e2) {}
    } catch (e) {}
  }
  function flushDirectMirrorQueue(s) {   // fin de run : seulement l'attente, jamais pendant run/chargement
    if (!s || s.dead || s.running || s.historyLoading) return;
    try {
      const pend = directMirrorPending(s);
      if (!pend.length) return;
      const rend = directMirrorRendered(s);
      while (pend.length) {
        const m = pend.shift();
        try { mirrorRender(s, m, true); } catch (e) { continue; }
        try { traceMirror(m && m.feed, "RENDU_DIFFERE", String(s.cid || ""), "", "flush"); } catch (e2) {}
        rend.push(m);
        while (rend.length > 30) rend.shift();
      }
    } catch (e) {}
  }
  // R-MIROIR (SPARK8-B) : cible affichée sinon dernière consultée ; jamais le Fil direct ; jamais de repli première session.
  async function mirrorDirectToActive(d) {   // poussée depuis direct.appended : enregistrement immédiat au registre, rendu via la file existante
    let convId = "";
    let feed = "";
    let targetCid = "";
    try {
      if (!d || !d.conv) return;
      convId = String(d.conv || "");
      feed = String(d.feed || "");
      let msg = "";
      let meta = {};
      let viaRepli = false;
      if (typeof d.msg === "string") msg = d.msg;
      else if (d.msg && typeof d.msg.content === "string") msg = d.msg.content;
      else msg = "";
      if (d.msg && typeof d.msg === "object") meta = fdMetaOf(d.msg);   // FD : les métadonnées du message stocké voyagent avec le miroir
      // Repli réseau : direct.appended sans msg → relire la conversation pour retrouver l'événement du même feed.
      if (!msg && feed && convId) {
        try {
          const j = await api.get("/api/conversation?id=" + encodeURIComponent(convId));
          const list = (typeof arrOf === "function") ? arrOf(j, "messages") : ((j && j.messages) || []);
          for (const cand of (list || [])) {
            if (!cand || cand.role !== "event") continue;
            if (String(cand.feed || "") !== feed) continue;
            if (typeof cand.content === "string" && cand.content) { msg = cand.content; meta = fdMetaOf(cand); break; }
          }
        } catch (e2) {}
        if (msg) viaRepli = true;
      }
      if (msg) { try { traceMirror(feed, viaRepli ? "MSG_REPLI_OK" : "MSG_DIRECT", "", convId, ""); } catch (e2) {} }
      if (!convId || !feed || !msg) { if (!msg) { try { traceMirror(feed, "MSG_INTROUVABLE", "", convId, !feed ? "feed absent" : (viaRepli || feed ? "repli vide" : "")); } catch (e2) {} } return; }
      let targetMotif = "";
      const act = activeSession();
      if (moduleShown && act && act.cid) { targetCid = String(act.cid); targetMotif = "CIBLE_AFFICHEE"; }
      if (!targetCid) { try { targetCid = String(localStorage.getItem(ACTIVE_KEY) || ""); if (targetCid) targetMotif = "CIBLE_DERNIERE_CONSULTEE"; } catch (e) { targetCid = ""; } }
      if (!targetCid && act && act.cid) { targetCid = String(act.cid); targetMotif = "CIBLE_ACTIVE"; }
      if (targetCid) { try { traceMirror(feed, targetMotif, targetCid, convId, ""); } catch (e2) {} }
      if (!targetCid || targetCid === convId) { try { if (!targetCid) traceMirror(feed, "AUCUNE_CIBLE", "", convId, ""); else traceMirror(feed, "CIBLE_EGALE_FIL_DIRECT", targetCid, convId, ""); } catch (e2) {} return; }
      if (!mirrorIsUrgent(meta)) { try { traceMirror(feed, "ROUTINE_NON_MIROITEE", targetCid, convId, "registre"); } catch (e2) {} return; }   // V5-T : la routine reste au Fil direct
      const isUpdate = !!(d && d.update);   // FIXES-MAIL (24/10) : carte enrichie en place (même feed)
      const added = isUpdate ? mirrorRegistryUpsert(targetCid, feed, msg, meta) : mirrorRegistryAdd(targetCid, feed, msg, meta);
      try { traceMirror(feed, added ? "REGISTRE_ECRIT" : "DEJA_VU", targetCid, convId, added ? "" : "registre"); } catch (e2) {}
      const s = sessionsByCid.get(targetCid);
      if (!s) { try { traceMirror(feed, "SESSION_ABSENTE", targetCid, convId, ""); } catch (e2) {} }
      else if (s.dead) { try { traceMirror(feed, "SESSION_MORTE", targetCid, convId, ""); } catch (e2) {} }
      else pushDirectMirror(s, { feed, content: msg, ...meta, update: isUpdate });
    } catch (e) { try { traceMirror(feed, "ECHEC_HANDLER", targetCid || "", convId || "", String((e && e.name) || "Error") + ": " + String((e && e.message) || e || "")); } catch (e2) {} }
  }

  function saveOpen() {
    try {
      localStorage.setItem(OPEN_KEY, JSON.stringify([...sessions.values()].map((s) => s.cid).filter(Boolean).slice(0, MAX_RESTORE)));
      const a = activeSession();
      localStorage.setItem(ACTIVE_KEY, (a && a.cid) || "");
    } catch (e) {}
  }
  function sessionStateWord(s) {
    if (s.running) return "en cours";
    if (s.unseen) return "terminée — non vue";
    return "au repos";
  }

  /* ── Liste des conversations (colonne de gauche) ───────────────────────
     Fusion : l'index moteur (GET /api/conversations) + les sessions ouvertes
     (leur état EN DIRECT prime : en cours / non vue / cerveau / activité). */
  function renderList() {
    if (dead) return;
    const rows = new Map();
    for (const [cid, meta] of convIndex) rows.set(cid, { cid, draftId: "", title: meta.title, updated: meta.updated || 0, brain: meta.brain || "", session: sessionsByCid.get(cid) || null, pinned: !!meta.pinned, created: meta.created || 0 });
    for (const s of sessions.values()) {
      if (s.cid) {
        const r = rows.get(s.cid) || { cid: s.cid, draftId: "", title: s.title, updated: 0, brain: "", session: null };
        r.session = s; r.title = s.title || r.title;
        /* TRI (27/10, diagnostic vérifié) : l'ordre n'utilise QUE le « updated » STOCKÉ
           (convIndex, vérité moteur). L'activité de session sert à l'indicateur d'état
           (« en cours »), jamais à l'ordre — cliquer un vieux fil ne le trie plus
           comme neuf. Seuls les brouillons sans cid gardent leur activité locale. */
        const stored = convIndex.get(s.cid);
        if (stored) r.updated = stored.updated || 0;
        else if (!r.updated) r.updated = s._adoptedUpdated || 0;
        if (s.brainLabel) r.brain = s.brainLabel;
        rows.set(s.cid, r);
      } else {
        rows.set(s.id, { cid: "", draftId: s.id, title: s.title, updated: s.lastActivity || 0, brain: s.brainLabel || "", session: s });
      }
    }
    let list = [...rows.values()].sort((a, b) => (b.updated || 0) - (a.updated || 0));
    /* LOT3 : archivées (manuel ou règle auto) hors de la liste par défaut — jamais la session active ni un run en cours. */
    const archOf = (r) => !!r.cid && isArchived(convIndex.get(r.cid));
    const keepVisible = (r) => !!r.session && (r.session === activeSession() || r.session.running);
    const nArch = list.filter(archOf).length;
    try { archFilter.set(archView, nArch); } catch (e) {}
    list = archView === "archivees" ? list.filter(archOf) : list.filter((r) => !archOf(r) || keepVisible(r));
    /* FIX-DIRECT-WEB ⑤ : ÉPINGLE — le Fil direct passe en tête, AVANT le tri par
       récence ; l'ordre relatif de toutes les autres conversations est inchangé
       (partition stable : on extrait la seule ligne du fil, le reste garde
       exactement l'ordre trié). */
    directSync();
    if (dst.cid) {
      const di = list.findIndex((r) => r.cid === dst.cid);
      if (di > 0) { const [dr] = list.splice(di, 1); list.unshift(dr); }
    }
    /* 27/10 : les fils ÉPINGLÉS par Ahadi montent juste sous le Fil direct (partition
       stable : leur ordre relatif, par récence, est inchangé). */
    {
      const head = list.slice(0, dst.cid && list.length && list[0].cid === dst.cid ? 1 : 0);
      const rest = list.slice(head.length);
      const pins = rest.filter((r) => r.pinned && r.cid !== dst.cid);
      if (pins.length) list = [...head, ...pins, ...rest.filter((r) => !r.pinned || r.cid === dst.cid)];
    }
    /* 29/10 (témoin de saccades : 42 gels de 250–490 ms sur l'écran Conversations en 10 min, sans clic) : la liste n'est
       reconstruite que si quelque chose a changé — le sondage de 45 s et les événements de session ne touchent plus au DOM
       quand rien ne bouge. Signature = tout ce qui s'affiche (ordre, titre, état, épingle, récence à la minute, compteur). */
    const _sig = archView + "|" + historyError + "|" + list.map((r) => {
      const s = r.session;
      return (r.cid || r.draftId) + ":" + (r.title || "") + ":" + (s ? (s.running ? "r" : s.unseen ? "u" : "i") : "i") + ":" + (s && s === activeSession() ? "A" : "") + ":" + (r.pinned ? "P" : "") + ":" + fmtRel(r.updated) + ":" + (r.brain || "") + ":" + (dst.cid && r.cid === dst.cid ? (dst.count || 0) : "") + ":" + (r.cid && isArchived(convIndex.get(r.cid)) ? "a" : "");
    }).join("\n");
    if (_sig === renderList._lastSig) return;
    renderList._lastSig = _sig;
    if (historyError && !list.length) {
      listEl.replaceChildren(h("div", { class: "state-error" },
        h("span", {}, "Historique injoignable (moteur)."),
        h("button", { class: "btn sm", onclick: () => loadHistory() }, "Réessayer")));
      return;
    }
    listEl.replaceChildren(...(list.length ? list.map((r) => {
      const s = r.session;
      const state = s ? (s.running ? "run" : s.unseen ? "unseen" : "idle") : "idle";
      const isActive = !!s && s === activeSession();
      const brainEtat = (() => { try { const _f = brainsList.find((b) => b && (String(b.label) === String(r.brain) || String(b.id) === String(r.brain))); return _f ? String(_f.etat || "") : ""; } catch (e) { return ""; } })();
      /* V5-W : méta calme — nature (Routine / Commande), état vivant, récence ; le cerveau n'y figure que s'il est en panne. */
      const brainShown = (brainEtat === "en panne" || brainEtat === "sans clé") && r.brain ? r.brain + " — " + brainEtat : "";
      const nt = niceTitle(r.title);
      /* 27/10 : la date de CRÉATION du fil est affichée à part — ouvrir un vieux fil
         ne le rajeunit plus (« sa période se réinitialise »). */
      const creeLe = r.created ? "créée le " + new Date(r.created).toLocaleDateString("fr-FR", { day: "numeric", month: "short" }) : "";
      const meta = [nt.kind, s && s.running ? "en cours" : s && s.unseen ? "non vue" : "", brainShown, fmtRel(r.updated), creeLe].filter(Boolean).join(" · ");
      const isDirect = !!dst.cid && r.cid === dst.cid;   // FIX-DIRECT-WEB ⑤ : ligne du Fil direct (épingle + compteur)
      const unread = isDirect ? (dst.count || 0) : 0;
      const rowBtn = h("button", { class: "cs-row" + (isActive ? " on" : "") + (isDirect ? " pinned" : ""), title: (s && s.titleFull) || r.title,
        onclick: () => { if (r.cid) openConversation(r.cid, true); else if (s) activate(s, true); } },
        h("span", { class: "mp-dot " + state }),
        h("span", { class: "cs-row-txt" },
          h("span", { class: "cs-row-t" + (nt.cmd ? " is-cmd" : "") }, truncWords(nt.t, 90)),
          h("span", { class: "cs-row-m" }, meta || "—")),
        isDirect || r.pinned ? h("span", { class: "cs-pin-ic", title: "Épinglé", "aria-label": "Épinglé", html: ic("pin", 12) }) : null,
        unread ? h("span", { class: "cs-unread", "aria-label": unread + " message(s) direct(s) non lu(s)" }, unread > 99 ? "99+" : String(unread)) : null);
      if (!r.cid || isDirect) return rowBtn;   // brouillon sans id ou Fil direct : pas d'archivage
      const arch = archOf(r);
      /* 27/10 : bouton épingler/désépingler (POST /api/conversations/pin). */
      const pinBtn = h("button", { class: "cs-row-pin" + (r.pinned ? " on" : ""), title: r.pinned ? "Désépingler ce fil" : "Épingler ce fil en haut de la liste", "aria-label": r.pinned ? "Désépingler" : "Épingler", html: ic("pin", 14),
        onclick: async (ev) => { ev.stopPropagation(); const on = !r.pinned; const m = convIndex.get(r.cid); if (m) m.pinned = on; renderList();
          try { const j = await api.post("/api/conversations/pin", { id: r.cid, pinned: on }); if (!j || j.ok !== true) throw new Error("refusé"); }
          catch (e) { if (m) m.pinned = !on; renderList(); ctx.toast("Épinglage refusé par le moteur.", true); } } });
      return h("div", { class: "cs-row-wrap" + (arch ? " is-arch" : "") }, rowBtn, pinBtn, archiveButton(r.cid, arch, (on) => { const m = convIndex.get(r.cid); if (m) m.archived = on ? "manuel" : "non"; renderList(); }, (t, bad) => ctx.toast(t, bad)));
    }) : [h("div", { class: "empty" }, archView === "archivees" ? "Aucune conversation archivée." : "Aucune conversation pour le moment.")]));
  }
  function openConversation(cid, focusComposer) {
    const existing = sessionsByCid.get(cid);
    if (existing) { activate(existing, focusComposer); if (existing.ensureHistory) existing.ensureHistory(); return existing; }   // FIX-RENDU ① : réactiver une session existante ne court-circuite plus le chargement — si son historique n'a jamais été rendu (session adoptée), il est chargé ici
    const s = createSession();
    registerSession(s);
    s.loadConversation(cid);
    activate(s, focusComposer);
    saveOpen();
    return s;
  }
  function newConversation(focusComposer) {
    /* Un brouillon vierge déjà ouvert est réutilisé (comme Muse) plutôt
       que d'empiler des conversations vides. */
    const draft = [...sessions.values()].find((s) => !s.cid && !s.running && !s.used);
    if (draft) { activate(draft, focusComposer); return draft; }
    const s = createSession();
    registerSession(s);
    s.syncDirect();
    activate(s, focusComposer);
    return s;
  }
  function registerSession(s) {
    sessions.set(s.id, s);
    if (s.cid) sessionsByCid.set(s.cid, s);
    main.append(s.el);
    s.populateBrains();
    renderList();
  }
  /* 26/10 : le moteur dépose les directs dans la conversation OUVERTE — on lui dit laquelle (et on le lui rappelle). */
  function reportActive() {
    try { const a = activeSession(); const cid = a && a.cid && !a.dead ? String(a.cid) : ""; fetch("/api/ui/conv-active", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ cid }) }).catch(() => {}); } catch (e) {}
  }
  setInterval(() => { if (!dead && document.visibilityState === "visible") reportActive(); }, 300000);
  function activate(s, focusComposer) {
    if (!s || !sessions.has(s.id)) return;
    activeId = s.id;
    setTimeout(reportActive, 50);
    /* V5-T (25/10) : PROCHAT n'injecte plus ses cartes dans les conversations ordinaires (elles
       doublaient les arrivées du Fil direct). Seul le Fil direct s'enregistre — sous « conv:<cid> »,
       la clé que la garde de prochat.appendTo compare (avant : « conv:sess-N », la garde ne
       jouait jamais et chaque événement y figurait deux fois : message moteur + carte prochat). */
    try { directSync(); const dc = String(dst.cid || engineDirectCid || ""); if (window.NovaProChat && dc && s.cid === dc) window.NovaProChat.registerThread("conv:" + s.cid, s.log); } catch (e) {}
    if (s.ensureHistory) s.ensureHistory();   // FIX-RENDU ① : TOUTE activation d'une session au passé non rendu déclenche son chargement (ensureHistory garde : jamais pendant un run, jamais en double)
    /* FIX-DIRECT-WEB ⑤ : le shell apprend quelle conversation est affichée
       (il s'en sert pour ne pas compter une arrivée que l'utilisateur est en
       train de lire) ; et si le fil activé EST le Fil direct et que le module
       est visible, l'ouverture acquitte le compteur. */
    try { bus.emit("nova:conv-active", { cid: s.cid || "" }); } catch (e) {}
    /* Historique de navigation (27/10) : chaque conversation ouverte devient une vue
       « Précédent / Suivant » du shell. Le flux en cours n'est jamais coupé : revenir
       ré-affiche la session conservée, en plein stream si elle tourne encore. */
    try { if (s.cid && window.NovaNav) window.NovaNav.push({ id: "conversations", cid: String(s.cid) }); } catch (e) {}
    if (moduleShown) { directSync(); if (dst.cid && s.cid === dst.cid) markDirectSeen(); }
    s.unseen = false;
    /* 28/10 : ouvrir le fil acquitte son badge « tâche finie non vue ». */
    try {
      const K = "nova2_unseen_done_v1";
      const st8 = JSON.parse(localStorage.getItem(K) || "{}") || {};
      if (st8[String(s.cid || "local")]) { delete st8[String(s.cid || "local")]; localStorage.setItem(K, JSON.stringify(st8)); ctx.bus.emit("nova:unseen-done", { cid: s.cid }); }
    } catch (e) {}
    for (const q of sessions.values()) q.el.classList.toggle("on", q === s);
    s.renderHead(); renderList(); saveOpen(); renderEst();
    if (focusComposer) { try { s.input.focus({ preventScroll: true }); } catch (e) {} }
  }
  function closeSession(s) {
    if (s.running) { ctx.toast("Arrête l'exécution en cours dans cette conversation d'abord.", true); return; }
    s.destroy();
    sessions.delete(s.id);
    if (s.cid && sessionsByCid.get(s.cid) === s) sessionsByCid.delete(s.cid);
    s.el.remove();
    if (!sessions.size) { newConversation(false); return; }
    if (activeId === s.id) activate(activeSession(), false);
    renderList(); saveOpen();
  }

  /* ══ Voix PARTAGÉE du module (voice.js — les mêmes /api/stt et /api/tts
     que la barre vocale de l'Accueil) ════════════════════════════════════
     Une seule instance pour tout l'écran : la dictée vise le composeur de
     la conversation ACTIVE, la lecture ne parle que pour elle (changer de
     conversation coupe la parole — barge-in par bascule). */
  let voice = null;
  let voiceStatus = "Voix : voix système du Mac (ou repli nommé).";
  function getVoice() {
    if (voice) return voice;
    voice = createVoice({
      /* 25/10 : silence de 1,8 s après la dictée → transcription puis ENVOI automatique dans la conversation active. */
      onAutoEnd: () => { const s = activeSession(); if (!s || !s.finishDictation) return; s.finishDictation().then((t) => { if (t && !s.dead && s.submit) s.submit(); }).catch(() => {}); },
      onEngine: (e) => { if (e) { voiceStatus = "Voix : " + voixLabel(e) + "."; paintVoiceStatus(); } },
      onLatency: (m) => {
        if (dead) return;
        if (m.kind === "tts") voiceStatus = "Dernier échange — parole entendue en " + (m.firstSoundMs / 1000).toFixed(1).replace(".", ",") + " s (flux " + voixLabel(m.engine) + ").";
        else if (m.kind === "stt") voiceStatus = "Dernier échange — dictée transcrite en " + (m.ms / 1000).toFixed(1).replace(".", ",") + " s.";
        paintVoiceStatus();
      },
      onState: (st) => { for (const s of sessions.values()) s.paintVoiceState(st); },
      /* V6-COMPAGNON (25/10) : la pastille « J'écoute… » s'ancre sur le composeur de la
         conversation ACTIVE (même centre, même largeur) — plus jamais au centre de la fenêtre. */
      anchor: () => { const a = activeSession(); return a && a.el ? a.el.querySelector(".cs-composer") : null; },
    });
    return voice;
  }
  function paintVoiceStatus() { const s = activeSession(); if (s) s.vstate.textContent = voiceStatus; }
  /* ── Conversation vocale LIVE (VL, 23/10) : UNE session native partagée
     par tout l'écran (le moteur Feat_VoiceLive tient le micro et la voix ;
     ici on ne fait que démarrer/arrêter et peindre les états). ── */
  let voiceLive = null;
  /* V4-D (24/10) — GOUVERNEUR : POST /api/perf {busy, source} au début/fin d'un stream
     de chat et d'une Voix Live — le moteur diffère alors l'indexation lourde et les
     Dots planifiés (une source oubliée expire seule côté moteur après 15 min).
     Dédoublonné : un seul envoi par changement d'état de chaque source. */
  const perfState = new Map();
  function perfSignal(source, busy) {
    const b = !!busy;
    if (perfState.get(source) === b) return;
    perfState.set(source, b);
    try { const p = api.post("/api/perf", { busy: b, source }, 5000); if (p && p.catch) p.catch(() => {}); } catch (e) {}
  }
  function getVoiceLive() {
    if (voiceLive) return voiceLive;
    voiceLive = createVoiceLive({
      onState: (st) => { for (const s of sessions.values()) if (s.paintLiveState) s.paintLiveState(st); try { perfSignal("voix-live", !!(voiceLive && voiceLive.actif())); } catch (e) {} },
      /* V6-COMPAGNON : une demande d'action dite en Live part par l'agent NORMAL (outils, cartes
         d'approbation) dans la conversation active ; ses cartes s'affichent dans CE fil, le fil se
         recharge à la fin, et la voix live dit le résumé (voice.js › runMission). */
      missionConv: () => { const a = activeSession(); return (a && a.cid) || ""; },
      onMission: (m) => {
        if (dead || !m) return;
        const target = (m.cid && sessionsByCid.get(m.cid)) || activeSession();
        if (!target) return;
        if (m.phase === "start") { target.vstate.textContent = "Nova Live : tâche lancée en arrière-plan — « " + trunc(m.text, 60) + " »"; ctx.toast("Nova Live lance la tâche avec ses outils : « " + trunc(m.text, 70) + " »"); }
        else if (m.phase === "confirm" && m.confirm) {
          const d = m.confirm;
          if (d.resolved) { const c = target.confirmCards.get(d.id); if (c && c._resolve) c._resolve(!!d.ok); target.confirmCards.delete(d.id); }
          else if (d.id && !target.confirmCards.has(d.id)) target.confirmCards.set(d.id, target.confirmCard(d));
        }
        else if (m.phase === "done") {
          target.vstate.textContent = voiceStatus;
          if (m.cid && target.cid === m.cid && !target.running && target.loadConversation) { try { target.loadConversation(m.cid); } catch (e) {} }
          if (!m.ok) ctx.toast("Nova Live : " + (m.summary || "la tâche n'a pas abouti."), true);
        }
      },
      onEvent: (d) => {
        if (dead) return;
        const s = activeSession(); if (!s) return;
        if (d.label) s.vstate.textContent = d.label;
        else if (d.partiel) s.vstate.textContent = "Tu dis : " + d.partiel;
        else if (d.final) s.vstate.textContent = "Nova réfléchit…";
      },
    });
    return voiceLive;
  }
  function speakAnswer(s, text) {
    if (dead || !s.voiceMode || s !== activeSession()) return;
    const p = parseBiChannel(text || "");
    const say = (p.bic ? p.parle : speakable(text || "")).slice(0, 1200);
    if (!say) return;
    getVoice().speak(say).catch((e) => ctx.toast(String((e && e.message) || e), true));
  }

  /* ══ Fabrique de session — TOUT l'état d'une conversation vit ici ═══════ */
  /* ── MÉMOIRE SOUVERAINE (24/10) — provenance sous une réponse ─────────
     Le moteur émet « memory » juste avant « done » (et le persiste sur le
     message) : {items:[{id, kind: memoire|profil|rappel, text, ts}], count,
     incognito}. Puce discrète « N souvenirs utilisés » qui se déplie ; un
     fait se modifie ou s'oublie (oubli définitif, confirmé en deux temps),
     un rappel rouvre sa conversation. Rien d'inventé : sans provenance,
     aucune puce. ─────────────────────────────────────────────────────── */
  const PROV_KIND = { memoire: "mémoire", profil: "profil", rappel: "conversation" };
  function provChip(prov) {
    const items = Array.isArray(prov && prov.items) ? prov.items : [];
    const inc = !!(prov && prov.incognito);
    if (!items.length && !inc) return null;
    const n = items.length;
    /* VAGUE 2 FIABILITÉ : la puce compte les seuls FAITS choisis pour cette question (kind « memoire » — le moteur
       ne sert plus que les pertinents, Memory.chatItems) ; le profil permanent est dit « + profil » ; les rappels de
       conversations récentes restent visibles dans la liste dépliée, sans gonfler le compte. */
    const nSel = items.filter((it) => it && (it.kind || "memoire") === "memoire").length;
    const nProf = items.filter((it) => it && it.kind === "profil").length;
    const nRap = items.filter((it) => it && it.kind === "rappel").length;
    const label = n
      ? (nSel ? nSel + (nSel > 1 ? " souvenirs" : " souvenir") + (nProf ? " + profil" : "") : (nProf ? "Profil seul" : "Fil récent seul"))
      : "Aucun souvenir utilisé";
    const list = h("div", { class: "mem-prov-list", hidden: true });
    const chip = h("button", { type: "button", class: "mem-prov-chip", "aria-expanded": "false", title: "Ce que Nova a tiré de sa mémoire pour cette réponse" + (nSel ? " — " + nSel + " fait(s) choisi(s) pour la question" : "") + (nProf ? ", profil permanent" : "") + (nRap ? ", " + nRap + " conversation(s) récente(s) en rappel" : "") },
      h("span", { html: ic("brain", 12) }), " " + label + (inc ? " · hors mémoire" : "") + (prov && prov.forgotten ? " · " + prov.forgotten + " oublié(s) depuis" : ""),
      n ? h("span", { class: "mem-prov-chev", html: ic("chev-d", 11) }) : null);
    const wrap = h("div", { class: "mem-prov" + (inc ? " inc" : "") }, chip, list);
    if (!n) { chip.disabled = true; return wrap; }
    const row = (it) => {
      const kind = String(it.kind || "memoire");
      const txt = h("span", { class: "mem-prov-txt" }, String(it.text || ""));
      const meta = h("span", { class: "mem-prov-meta" }, (PROV_KIND[kind] || kind) + (it.ts ? " · " + String(it.ts) : "") + (it.locked ? " · verrouillé" : "") + (kind === "rappel" ? " · ouvrir" : ""));
      const acts = h("div", { class: "mem-prov-acts", hidden: true });
      const r = h("div", { class: "mem-prov-row", tabindex: "0", role: "button" }, h("div", { class: "grow" }, txt, meta), acts);
      const open = () => {
        if (r.classList.contains("gone")) return;
        if (kind === "rappel") { if (it.id) openConversation(String(it.id), false); return; }
        acts.hidden = !acts.hidden;
        if (acts.hidden) return;
        const edit = h("button", { type: "button", class: "btn sm" }, "Modifier");
        const forget = h("button", { type: "button", class: "btn sm danger" }, "Oublier");
        acts.replaceChildren(edit, forget);
        edit.addEventListener("click", async (e) => {
          e.stopPropagation();
          let cur = String(it.text || "");
          try { const hj = await api.get("/api/memory/fact/history?id=" + encodeURIComponent(it.id)); if (hj && hj.current && hj.current.text) cur = String(hj.current.text); } catch (er) {}
          const ta = h("textarea", { class: "fld mem-prov-edit", rows: "2", "aria-label": "Texte du fait" }); ta.value = cur;
          const save = h("button", { type: "button", class: "btn sm acc" }, "Enregistrer");
          const cancel = h("button", { type: "button", class: "btn sm" }, "Annuler");
          const doSave = async () => {
            const nv = ta.value.trim(); if (!nv || nv === cur) { acts.hidden = true; return; }
            try { await api.post("/api/memory/fact/update", { id: it.id, text: nv, why: "correction depuis une réponse" }); it.text = nv; txt.textContent = nv; acts.hidden = true; ctx.toast("Fait corrigé — Nova s'en servira dès la prochaine réponse."); }
            catch (er) { ctx.toast("Correction impossible : " + String((er && er.message) || er), true); }
          };
          ta.addEventListener("keydown", (ev) => { if (ev.isComposing || ev.keyCode === 229) return; ev.stopPropagation(); if (ev.key === "Enter" && !ev.shiftKey) { ev.preventDefault(); doSave(); } if (ev.key === "Escape") acts.hidden = true; });
          save.addEventListener("click", (ev) => { ev.stopPropagation(); doSave(); });
          cancel.addEventListener("click", (ev) => { ev.stopPropagation(); acts.hidden = true; });
          ta.addEventListener("click", (ev) => ev.stopPropagation());
          acts.replaceChildren(ta, h("div", { class: "mem-prov-btns" }, save, cancel));
          try { ta.focus(); } catch (er) {}
        });
        forget.addEventListener("click", (e) => {
          e.stopPropagation();
          const yes = h("button", { type: "button", class: "btn sm danger" }, "Oublier pour de bon");
          const no = h("button", { type: "button", class: "btn sm" }, "Garder");
          acts.replaceChildren(h("span", { class: "ss" }, "Effacement définitif : le fait, son vecteur, ses versions et ses copies."), h("div", { class: "mem-prov-btns" }, yes, no));
          no.addEventListener("click", (ev) => { ev.stopPropagation(); acts.hidden = true; });
          yes.addEventListener("click", async (ev) => {
            ev.stopPropagation();
            try { await api.post("/api/memory/fact/forget", { id: it.id, confirm: true, why: "oubli depuis une réponse" }); r.classList.add("gone"); txt.textContent = "Fait oublié."; meta.textContent = ""; acts.hidden = true; ctx.toast("Fait oublié pour de bon."); }
            catch (er) { ctx.toast("Oubli impossible : " + String((er && er.message) || er), true); }
          });
        });
      };
      r.addEventListener("click", open);
      r.addEventListener("keydown", (ev) => { if (ev.target !== r) return; if (ev.key === "Enter" || ev.key === " ") { ev.preventDefault(); open(); } });
      return r;
    };
    list.append(...items.map(row));
    chip.addEventListener("click", () => { list.hidden = !list.hidden; chip.setAttribute("aria-expanded", list.hidden ? "false" : "true"); wrap.classList.toggle("open", !list.hidden); });
    return wrap;
  }

  function createSession() {
    const s = {
      id: "sess-" + (++sessionSeq), cid: "", title: "Nouvelle conversation", brainTouched: false,
      running: false, runToken: 0, abortCtl: null, dead: false, used: false,
      historyLoaded: false, historyLoading: false, historyReloadNeeded: false,   // FIX-RENDU ① : l'historique moteur de CETTE session a-t-il été RENDU ? Une session qui adopte un cid par le flux SSE (meta) naît avec historyLoaded=false — son journal ne contient que le run en direct tant qu'ensureHistory n'a pas chargé le passé.
      stepRows: new Map(), confirmCards: new Map(), pendingPlan: null,
      runStats: null, budgetTimer: 0, lastTask: "", depth: getDepth(),
      autonomie: autoDefault(), brainLabel: "", usageText: "", lastActivity: Date.now(), unseen: false,
      voiceMode: false, detailsOpen: false, detailCount: 0, attSending: false,
      queue: [], queuePaused: false,
      steered: [], steerRoute: null, _steering: false,   // V4-D : LIVE STEER — ajouts remis au moteur (POST /api/chat/steer) en attente de l'événement « steer »
    };

    /* ── Pièces jointes (attach.js) : création AVANT le composeur ; les deux
       champs fichier cachés qu'elle pose dans <body> sont repérés pour être
       retirés à la destruction de la session (aucune fuite de DOM). ── */
    const bodyBefore = new Set([...document.body.children]);
    const att = createAttachments();
    const attInputs = [...document.body.children].filter((el) => !bodyBefore.has(el));
    s.att = att;

    /* ── En-tête fine : titre + sélecteurs compacts par conversation ──── */
    const dotEl = h("span", { class: "mp-dot idle" });
    const titleEl = h("div", { class: "cs-title" }, s.title);
    const subEl = h("div", { class: "cs-sub" }, "au repos");
    const sparkBadge = h("span", { class: "spark-badge", style: "display:none" }, h("span", { html: ic("zap", 13) }), " Propulsé par Muse Spark");
    const brainSel = h("select", { class: "sel cs-brain", title: "Cerveau pour CETTE conversation" }, h("option", { value: "" }, "Cerveau : automatique"));
    /* RUBIS (23/10) : le menu natif de ce <select> échappe au pilotage
       (7 voies épuisées — dossier F8) ; le sélecteur devient un bouton +
       menu 100 % DOM, pilotable comme le reste de l'interface. brainSel
       RESTE le détenteur d'état : populateBrains, l'envoi (body.brain),
       les lectures .value/.selectedOptions et l'événement « change »
       d'origine sont inchangés — le menu ne fait qu'écrire la même valeur
       et déclencher le même événement que le menu natif. */
    brainSel.classList.add("cs-brain-native");
    const brainLbl = h("span", {}, "Cerveau : automatique");
    const brainBtn = h("button", { type: "button", class: "sel cs-brainbtn", title: "Cerveau pour CETTE conversation" }, brainLbl, " ", h("span", { html: ic("chev-d", 12) }));
    const brainMenu = h("div", { class: "cs-brainmenu", hidden: true });
    const brainWrap = h("span", { class: "cs-brainwrap" }, brainSel, brainBtn, brainMenu);
    const paintBrainBtn = () => { try { const o = brainSel.selectedOptions && brainSel.selectedOptions[0]; brainLbl.textContent = (o ? o.textContent : "Cerveau : automatique"); } catch (e) {} };
    const onBrainDocClick = (ev) => { try { if (!brainWrap.contains(ev.target)) closeBrainMenu(); } catch (e) {} };
    const onBrainDocKey = (ev) => { if (ev.key === "Escape") closeBrainMenu(); };
    const closeBrainMenu = () => { brainMenu.hidden = true; document.removeEventListener("click", onBrainDocClick, true); document.removeEventListener("keydown", onBrainDocKey, true); };
    const openBrainMenu = () => {
      try {
        brainMenu.replaceChildren(...[...brainSel.options].map((o) => {
          const it = h("button", { type: "button", class: "cs-brainitem" + (o.value === brainSel.value ? " on" : "") }, o.textContent);
          it.addEventListener("click", () => { closeBrainMenu(); if (brainSel.value !== o.value) { brainSel.value = o.value; brainSel.dispatchEvent(new Event("change")); } paintBrainBtn(); });
          return it;
        }));
        brainMenu.hidden = false;
        document.addEventListener("click", onBrainDocClick, true);
        document.addEventListener("keydown", onBrainDocKey, true);
      } catch (e) {}
    };
    brainBtn.addEventListener("click", () => { if (brainMenu.hidden) openBrainMenu(); else closeBrainMenu(); });
    brainSel.addEventListener("change", paintBrainBtn);
    try { const moBrain = new MutationObserver(() => { if (!brainSel.isConnected) { moBrain.disconnect(); return; } paintBrainBtn(); }); moBrain.observe(brainSel, { childList: true }); } catch (e) {}
    paintBrainBtn();
    const brainState = h("span", { class: "dotst", title: "" });
    const brainDotClass = (etat) => { const e = String(etat || ""); if (e === "prêt") return "ok"; if (e === "inconnu") return "run"; if (e === "en panne" || e === "sans clé") return "err"; if (e === "désactivé") return "idle"; return "idle"; };
    const paintBrainState = () => { try { const cur = brainsList.find((b) => b && String(b.id) === String(brainSel.value)); const et = cur ? String(cur.etat || "") : ""; brainState.className = "dotst " + brainDotClass(et); brainState.title = et; } catch (e) {} };
    brainSel.addEventListener("change", () => { s.brainTouched = true; s.brainLabel = brainSel.value ? (brainSel.selectedOptions[0] && brainSel.selectedOptions[0].textContent) : ""; paintBrainState(); s.renderHead(); renderList(); });
    const depthSeg = h("div", { class: "seg" }, ...DEPTHS.map((d) => { const _b = h("button", { type: "button", class: "seg-btn" + (Number(d.id) === Number(s.depth) ? " on" : ""), title: d.hint || d.label }, d.label); _b.dataset.depth = String(d.id); _b.addEventListener("click", async () => { if (!(await confirmCostIncrease(s.depth, Number(_b.dataset.depth), depthSeg))) return; s.depth = Number(_b.dataset.depth); try { localStorage.setItem("nova2_depth", String(s.depth)); } catch (e) {} syncDepthUI(); }); return _b; }));
    const depthNote = h("div", { class: "ss" }, "Réglage partagé entre l'Accueil et Conversations.");
    const depthBlock = h("div", { class: "depth-block" }, depthSeg, depthNote);
    const depthLbl = h("span", {}, ((DEPTHS[s.depth] && DEPTHS[s.depth].label) || ""));
    const depthSummary = h("button", { class: "btn sm ghost", title: "Profondeur de réflexion — ouvrir les réglages" }, depthLbl, " ", h("span", { html: ic("chev-d", 12) }));
    const syncDepthUI = () => { try { [...depthSeg.querySelectorAll("button")].forEach((b) => b.classList.toggle("on", Number(b.dataset.depth) === Number(s.depth))); } catch (e) {} try { depthLbl.textContent = ((DEPTHS[s.depth] && DEPTHS[s.depth].label) || ""); } catch (e) {} };
    s.syncDepthUI = syncDepthUI;
    depthSummary.addEventListener("click", () => { s.setDetails(true); try { depthSeg.scrollIntoView({ block: "nearest" }); } catch (e) {} });
    const autoSel = h("select", { class: "sel cs-mini", title: "Mode pour CETTE conversation — Cowork : il s'arrête aux décisions ; Totale : il avance, les garde-fous demandent quand même" },
      h("option", { value: "total" }, "Autonomie totale"), h("option", { value: "cowork" }, "Cowork"));
    autoSel.value = s.autonomie;
    autoSel.addEventListener("change", () => { s.autonomie = autoSel.value; });
    const planBtn = h("button", { class: "btn cs-hbtn" + (planFirst ? " on" : ""), title: "Afficher un plan éditable avant chaque exécution (préférence de l'écran)" }, "Plan d'abord");
    planBtn.addEventListener("click", () => setPlanFirst(!planFirst));
    s.syncPlanBtn = () => { planBtn.classList.toggle("on", planFirst); };
    const detailBadge = h("span", { class: "cs-badge", hidden: true }, "");
    const detailsBtn = h("button", { class: "btn cs-hbtn", title: "Trace d'exécution, outils, plan, notices — replié par défaut, hors du fil",
      onclick: () => s.setDetails(!s.detailsOpen) }, "Détails", detailBadge);
    const sideBtn = h("button", { class: "btn cs-iconbtn", title: "Afficher / masquer la liste des conversations",
      onclick: () => { if (layout.clientWidth <= 760) { layout.classList.toggle("side-peek"); if (layout.classList.contains("side-peek")) { try { const on = listEl.querySelector(".cs-row.on") || newBtn; on.focus({ preventScroll: true }); } catch (e) {} } return; } layout.classList.toggle("side-hidden"); try { localStorage.setItem(SIDE_KEY, layout.classList.contains("side-hidden") ? "0" : "1"); } catch (e) {} } },
      h("span", { html: ic("list", 16) }));
    /* MÉMOIRE SOUVERAINE : « Hors mémoire » — pastille d'en-tête (visible
       seulement si actif, clic = désactiver) + bascule dans le tiroir Détails. */
    s.incognito = false;
    const incPill = h("button", { type: "button", class: "mem-inc-pill", hidden: true, title: "Hors mémoire : Nova utilise sa mémoire mais ne retient rien de cette conversation — clic pour réactiver la mémoire" },
      h("span", { html: ic("lock", 12) }), " Hors mémoire");
    const incBtn = h("button", { type: "button", class: "btn cs-hbtn mem-inc-btn", title: "Hors mémoire : le contexte reste utilisé, rien n'est retenu (ni extraction, ni outil « retenir »)" }, h("span", { html: ic("lock", 13) }), " Hors mémoire");
    const incNote = h("div", { class: "ss mem-inc-note" }, "Mémoire active : Nova peut retenir des faits durables de cette conversation.");
    s.paintIncognito = () => {
      incPill.hidden = !s.incognito;
      incBtn.classList.toggle("on", !!s.incognito);
      incBtn.setAttribute("aria-pressed", s.incognito ? "true" : "false");
      incNote.textContent = s.incognito ? "Hors mémoire : la mémoire sert le contexte, mais rien de ce fil n'est retenu." : "Mémoire active : Nova peut retenir des faits durables de cette conversation.";
    };
    s.setIncognito = async (on) => {
      const prev = !!s.incognito;
      s.incognito = !!on; s.paintIncognito();
      const msg = on ? "Hors mémoire : rien ne sera retenu de cette conversation." : "Mémoire réactivée pour cette conversation.";
      if (!s.cid) { ctx.toast(msg); return; }
      try { await api.post("/api/conversation/incognito", { cid: s.cid, on: !!on }); ctx.toast(msg); }
      catch (e) { s.incognito = prev; s.paintIncognito(); ctx.toast("Bascule impossible : " + String((e && e.message) || e), true); }
    };
    incPill.addEventListener("click", () => s.setIncognito(false));
    incBtn.addEventListener("click", () => s.setIncognito(!s.incognito));
    /* Re-titrage à la demande (point 4) : double-clic sur le titre → édition en place,
       Entrée valide (route rename), Échap annule. Jamais le Fil direct. */
    titleEl.title = "Double-clic pour renommer ce fil";
    titleEl.addEventListener("dblclick", () => {
      if (!s.cid || isDirectSession()) return;
      const old = String(s.title || "");
      titleEl.contentEditable = "true";
      titleEl.textContent = old;
      titleEl.focus();
      try { document.execCommand && document.execCommand("selectAll", false, null); } catch (e) {}
      const finish = (save) => {
        titleEl.contentEditable = "false";
        titleEl.removeEventListener("blur", onBlur);
        const t = titleEl.textContent.trim().slice(0, 80);
        if (save && t && t !== old) {
          api.post("/api/conversations/rename", { id: s.cid, title: t }).then(() => { const m2 = convIndex.get(s.cid); if (m2) m2.title = t; s.title = t; s.renderHead(); renderList(); ctx.toast("Fil renommé."); }).catch(() => { s.renderHead(); ctx.toast("Renommage refusé par le moteur.", true); });
        } else s.renderHead();
      };
      const onBlur = () => finish(true);
      titleEl.addEventListener("blur", onBlur);
      titleEl.addEventListener("keydown", (ev) => { if (ev.key === "Enter") { ev.preventDefault(); titleEl.blur(); } else if (ev.key === "Escape") { ev.preventDefault(); titleEl.textContent = old; titleEl.blur(); } });
    });
    s.renderProv = (b, prov) => {
      if (!b) return;
      try { if (b._provEl) b._provEl.remove(); } catch (e) {}
      const el = provChip(prov); if (!el) return;
      b._provEl = el;
      const nx = b.nextElementSibling;
      if (nx && nx.classList && nx.classList.contains("brain-badge")) nx.after(el); else b.after(el);
    };
    const headActions = h("div", { class: "mod-actions cs-head-actions" },
      incPill, sparkBadge, brainWrap, brainState, depthSummary, detailsBtn);
    const head = h("div", { class: "cs-head" },
      sideBtn, dotEl,
      h("div", { class: "grow cs-head-txt" }, titleEl, subEl),
      headActions,
      h("button", { class: "btn-close", title: "Fermer cette vue (la conversation n'est pas supprimée)", "aria-label": "Fermer cette vue", onclick: () => closeSession(s), html: ic("close", 16) }));

    /* ── Bandeau Direct : UNE ligne, au-dessus du fil, jamais dedans ──── */
    const directBand = h("div", { class: "cs-direct direct-band", hidden: true });

    /* ── Tiroir Détails : trace, outils, notices, plan, routine ───────── */
    const traceBox = h("div", { class: "agent-trace" });
    traceBox.append(h("div", { class: "empty" }, "Aucune exécution pour le moment — donne une tâche à l'agent."));
    const routineBar = h("div", { style: "display:none;margin-top:10px" });
    const metaFlow = h("div", { class: "cs-metaflow" });
    const detailsEl = h("div", { class: "cs-details", hidden: true },
      h("div", { class: "cs-details-head" }, h("div", { class: "tt" }, "Détails de la conversation"),
        h("button", { class: "btn-close", title: "Fermer les détails", "aria-label": "Fermer les détails", html: ic("close", 15), onclick: () => s.setDetails(false) })),
      depthBlock, autoSel, planBtn, incBtn, incNote,
      h("div", { class: "subhead" }, "Exécution en direct"),
      traceBox, routineBar, metaFlow);

    /* ── Fil CLEAN : uniquement les messages ──────────────────────────── */
    const log = h("div", { class: "chatlog cs-log" });
    /* 29/10 : un clic sur une suite proposée (bloc nova-suites) part comme nouvelle demande dans CETTE conversation. */
    log.addEventListener("click", (ev) => {
      const sb = ev.target && ev.target.closest ? ev.target.closest(".nova-suite") : null;
      if (!sb || !log.contains(sb)) return;
      ev.preventDefault();
      const ask = (sb.dataset.ask || sb.textContent || "").replace(/&quot;/g, '"').trim();
      if (!ask) return;
      try { sb.closest(".nova-suites").querySelectorAll(".nova-suite").forEach((x) => { x.disabled = true; }); sb.classList.add("on"); } catch (e) {}
      try { s.input.value = ask; s.input.dispatchEvent(new Event("input")); s.submit(); } catch (e) {}
    });
    /* 25/10 (Ahadi : « les messages de réponse sont cachés en partie à la sortie ») — en fin de réponse le texte
       est re-rendu (markdown, réactions, « N souvenirs ») et grandit APRÈS le dernier défilement : la fin restait
       sous le compositeur. Le fil reste désormais collé en bas à chaque croissance, sauf si Ahadi est remonté lire. */
    try {
      /* 25/10 (2) : seul un geste d'Ahadi (molette, toucher, clavier, glisser) peut décoller le fil. Un défilement
         programmé (fondu « smooth » des cartes du Fil direct) traversait des positions intermédiaires et faisait
         croire à une remontée : le fil cessait de suivre et la fin de la réponse suivante restait cachée. */
      let stuck = true, raf = 0, userAt = 0;
      const mark = () => { userAt = Date.now(); };
      for (const ev of ["wheel", "touchmove", "keydown", "pointerdown"]) log.addEventListener(ev, mark, { passive: true });
      log.addEventListener("scroll", () => {
        const near = log.scrollHeight - log.scrollTop - log.clientHeight < 140;
        if (near) stuck = true; else if (Date.now() - userAt < 900) stuck = false;
      }, { passive: true });
      const follow = () => { if (raf) return; raf = requestAnimationFrame(() => { raf = 0; if (stuck) log.scrollTop = log.scrollHeight; }); };
      /* chaque message est aussi observé en TAILLE : une réponse qui grandit sans nouveau nœud (gros blocs de
         Spark, re-rendu markdown, souvenirs dépliés, images) déclenche le suivi — reproduit au banc : 400 px cachés. */
      const ro = typeof ResizeObserver === "function" ? new ResizeObserver(follow) : null;
      if (ro) { ro.observe(log); for (const k of log.children) ro.observe(k); }
      new MutationObserver((recs) => {
        if (ro) for (const r of recs) for (const n of r.addedNodes) if (n.nodeType === 1 && n.parentNode === log) ro.observe(n);
        follow();
      }).observe(log, { childList: true, subtree: true, characterData: true });
    } catch (e) {}

    /* ── Composeur complet : joindre, micro, voix, envoi ──────────────── */
    const input = h("textarea", { rows: "1", placeholder: "Écris à Nova…", title: "Entrée envoie · Maj+Entrée = nouvelle ligne", "aria-label": "Tâche pour l'agent" });
    const attMenu = h("div", { class: "cs-att-menu", hidden: true },
      h("button", { onclick: () => { attMenu.hidden = true; att.btn.click(); } }, h("span", { html: ic("attach", 15) }), "Joindre des fichiers…"),
      h("button", { onclick: () => { attMenu.hidden = true; att.dirBtn.click(); } }, h("span", { html: ic("layers", 15) }), "Joindre un dossier entier…"));
    const attBtn = h("button", { class: "btn icon cs-iconbtn", title: "Joindre des fichiers ou un dossier", html: ic("attach", 17),
      onclick: () => { attMenu.hidden = !attMenu.hidden; } });
    const attWrap = h("div", { class: "cs-att-wrap" }, attBtn, attMenu);
    const onDocClick = (e) => { if (!attWrap.contains(e.target)) attMenu.hidden = true; };
    document.addEventListener("click", onDocClick);
    const micBtn = h("button", { class: "btn icon cs-iconbtn cs-mic", type: "button", title: "Dicter (micro) — clique, parle, puis reclique ou Envoyer : le texte tombe dans le champ", "aria-label": "Dicter", "aria-pressed": "false", html: ic("mic", 17) });
    /* V4-D (24/10) — « Voir mon écran » : capture de la fenêtre active par le Témoin
       (GET /api/temoin/vision?explicit=1&image=1, image gardée en mémoire vive côté
       moteur, jamais sur disque), jointe à ton PROCHAIN message : le cerveau la voit en
       vision native ; un cerveau non multimodal le dit et n'a que le texte reconnu. */
    const screenBtn = h("button", { class: "btn icon cs-iconbtn", title: "Voir mon écran — joint la fenêtre active à ton prochain message (sur ton clic seulement)", "aria-label": "Voir mon écran", html: ic("look", 17), onclick: () => s.captureScreen() });
    const screenChipText = h("span", { class: "qtext" }, "");
    const screenChip = h("div", { class: "cs-quotebar cs-screenbar", hidden: true }, screenChipText,
      h("button", { class: "btn sm", title: "Retirer la capture", "aria-label": "Retirer la capture", html: ic("close", 16), onclick: () => { s.pendingScreen = null; paintScreenChip(); } }));
    function paintScreenChip() {
      screenChip.hidden = !s.pendingScreen;
      if (s.pendingScreen) screenChipText.replaceChildren(h("span", { html: ic("look", 14) }), " Écran joint : " + (s.pendingScreen.app || "fenêtre active") + (s.pendingScreen.id ? " — Claude le verra avec ton prochain message" : " — texte reconnu seulement (image indisponible)"));
    }
    s.captureScreen = async () => {
      if (s._capturing) return;
      s._capturing = true; screenBtn.disabled = true;
      try {
        const j = await api.get("/api/temoin/vision?explicit=1&image=1", 20000);
        if (!j || j.ok !== true) { ctx.toast("Écran non capturé : " + String((j && (j.message || j.reason)) || "le moteur n'a pas répondu"), true); return; }
        s.pendingScreen = { id: j.image_id ? String(j.image_id) : "", app: String(j.app || ""), title: String(j.windowTitle || ""), text: String(j.screenText || "") };
        paintScreenChip();
        if (!j.image_id) ctx.toast("Image de l'écran indisponible (" + String(j.image_error || "moteur sans vision") + ") — seul le texte reconnu partira.", true);
        try { input.focus(); } catch (e) {}
      } catch (e) { ctx.toast("Écran non capturé : " + ((e && e.message) || e), true); }
      finally { s._capturing = false; screenBtn.disabled = false; }
    };
    /* Consomme la capture en attente : note texte pour le cerveau + référence image pour le moteur. */
    s.takeScreen = () => {
      const sc = s.pendingScreen;
      if (!sc) return { note: "", images: [] };
      s.pendingScreen = null; paintScreenChip();
      const note = "[Capture de l'écran actif prise sur ma demande — " + (sc.app || "fenêtre active") + (sc.title ? " · « " + trunc(sc.title, 80) + " »" : "") + (sc.text ? ". Texte reconnu (OCR) :\n" + trunc(sc.text, 4000) : ". Aucun texte reconnu.") + "]";
      return { note, images: sc.id ? [{ id: sc.id }] : [] };
    };
    const stopBtn = h("button", { class: "btn", style: "display:none", onclick: () => s.stopRun() }, h("span", { html: ic("stop", 11) }), " Stop");
    const sendBtn = h("button", { class: "btn acc", onclick: () => s.submit() }, h("span", { html: ic("send", 16) }), " Envoyer");
    /* ── Barre de file d'envoi : visible seulement si des messages
       attendent leur tour (exécution en cours). « Envoyer la file »
       n'apparaît qu'après un arrêt (file en pause, jamais vidée en
       silence) ; « Tout effacer » retire messages ET bulles. ── */
    const queueLabel = h("span", { class: "cs-queue-n" }, "");
    const queueState = h("span", { class: "cs-queue-state" }, "");
    const queueSendBtn = h("button", { class: "btn sm acc", style: "display:none", onclick: () => s.sendQueue() }, "Envoyer la file");
    const queueClearBtn = h("button", { class: "btn sm", onclick: () => s.clearQueue() }, "Tout effacer");
    const queueBar = h("div", { class: "cs-queuebar", hidden: true },
      queueLabel, queueState, h("span", { class: "sp", style: "flex:1" }), queueSendBtn, queueClearBtn);
    input.classList.add("fld");
    const composerRow = h("div", { class: "composer-row cs-row" }, h("div", { class: "composer-tools" }, attWrap, micBtn, screenBtn), input, h("div", { class: "composer-tools right" }), stopBtn, sendBtn);
    const vstate = h("span", { class: "vstate" }, voiceStatus);
    const convBtn = h("button", { class: "btn sm vbtn", title: "Conversation vocale : Nova répond à voix haute, en phrases courtes — tape dans le champ pour la couper (barge-in)",
      onclick: () => setVoiceMode(!s.voiceMode), "aria-label": "Conversation vocale" }, h("span", { html: ic("talk", 16) }));
    /* V6-COMPAGNON : Nova Live — bouton (( )) toujours visible (aussi à 550 px), états lisibles :
       écoute · réfléchit · Nova parle ; « Interrompre » apparaît pendant que Nova parle. */
    const liveLbl = h("span", { class: "cs-live-lbl" }, "");
    const liveBtn = h("button", { class: "btn sm vbtn cs-live", type: "button", title: "Nova Live — parler en continu",
      onclick: () => toggleLive(), "aria-label": "Nova Live — parler en continu", "aria-pressed": "false" }, h("span", { html: ic("radio", 16) }), liveLbl);
    const speechStopBtn = h("button", { class: "btn icon vbtn cs-speechstop", type: "button", title: "Interrompre Nova", "aria-label": "Interrompre Nova", hidden: true, html: ic("pause", 15),
      onclick: () => { if (voiceLive && voiceLive.actif()) { voiceLive.interrompre(); return; } if (voice) voice.stopSpeaking(); } });
    /* 25/10 (Ahadi : « deux boutons qui prêtent à confusion ») — un seul bouton voix visible : Live (parler en continu).
       « Réponses lues à voix haute » reste réglable dans Réglages › Voix ; le bouton dédié n'est plus affiché. */
    convBtn.hidden = true; convBtn.style.display = "none";
    liveLbl.textContent = "Parler";
    composerRow.querySelector(".composer-tools.right").append(convBtn, liveBtn, speechStopBtn);
    const vrow = h("div", { class: "vrow cs-vrow" }, vstate);
    /* textarea auto-ajustée : une ligne au repos, grandit jusqu'à 8 lignes */
    const autoGrow = () => { try { input.style.height = "auto"; input.style.height = Math.min(input.scrollHeight, 200) + "px"; } catch (e) {} };
    input.addEventListener("input", autoGrow);
    /* §42 : barre de relance ciblée — visible quand un message vise une
       réponse précise de Nova (bouton ↪ d'une bulle). */
    const quoteText = h("span", { class: "qtext" }, "");
    const quoteBar = h("div", { class: "cs-quotebar", hidden: true },
      quoteText,
      h("button", { class: "btn sm", title: "Retirer la visée", onclick: () => { s.pendingQuote = ""; paintQuoteBar(); }, html: ic("close", 16) }));
    function paintQuoteBar() {
      quoteBar.hidden = !s.pendingQuote;
      if (s.pendingQuote) quoteText.replaceChildren(h("span", { html: ic("undo", 14) }), " Réponse à : « " + s.pendingQuote + " »");
    }
    s.paintQuoteBar = paintQuoteBar;
    const composer = h("div", { class: "composer cs-composer" }, att.bar, queueBar, quoteBar, screenChip, composerRow, vrow);
    /* Le bouton d'envoi ne se verrouille PLUS pendant une exécution :
       il ne se désactive que le temps d'un téléversement de pièces
       jointes (attSending), et son libellé annonce la mise en file. */
    function paintSendBtn() {
      sendBtn.disabled = !!s.attSending;
      sendBtn.replaceChildren(h("span", { html: ic("send", 16) }), s.running ? " Ajouter à la file" : " Envoyer");
    }
    att.attachTo(log, input);
    log.addEventListener("nova:att-rejected", (e) => { (e.detail || []).forEach((m) => ctx.toast(m, true)); });
    input.addEventListener("keydown", (e) => {
      if (voice && voice.isSpeaking()) voice.stopSpeaking();   // barge-in par la frappe (patron de l'Accueil)
      if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); s.submit(); }
    });

    /* ── V4-D (24/10) — SÉLECTEUR DE CANAL DU FIL DIRECT (cahier Bloc 4.2 point 1) :
       Tous · Fundings · Courrier & Teams · Éclats. Visible seulement sur le Fil direct ET
       si feedcard.js (lot C) exporte channelOf — sinon masqué (aucun tri inventé ici).
       Vue Fundings : bandeau des 3 prochaines échéances (mountFundingsBand, GET /api/fundings)
       en tête. Le filtre masque, il ne supprime rien : « Tous » rend le fil intact. */
    const CHANNELS = [["tous", "Tous"], ["fundings", "Fundings"], ["courrier", "Courrier & Teams"], ["eclats", "Éclats"]];
    const CHAN_KEY = "nova2.direct.channel";
    const chanOK = () => typeof FC.channelOf === "function";
    s.channel = (() => { try { const v = localStorage.getItem(CHAN_KEY) || "tous"; return CHANNELS.some((c) => c[0] === v) ? v : "tous"; } catch (e) { return "tous"; } })();
    const chanSeg = h("div", { class: "seg cs-chanseg", role: "tablist", "aria-label": "Canal du Fil direct" });
    const chanBtns = CHANNELS.map(([id, label]) => {
      const b = h("button", { type: "button", role: "tab", "data-chan": id, onclick: () => s.setChannel(id) }, label);
      chanSeg.append(b); return b;
    });
    const fundBand = h("div", { class: "cs-fundband", hidden: true });
    const chanBar = h("div", { class: "cs-chanbar", style: "display:none;flex:0 0 auto;flex-direction:column;gap:8px;padding:8px 16px 0;max-width:100%;box-sizing:border-box;overflow-x:auto" }, chanSeg, fundBand);   /* 24/10 : flex 0 0 auto — avec overflow-x, la hauteur minimale automatique tombe à 0 et un long fil écrasait la barre à 0 px */
    let fundMounted = false;
    /* 24/10 : trois preuves acceptées — id mémorisé côté interface, id servi par le moteur (direct_thread_id), ou titre « Fil direct » posé par le moteur à la création du fil. */
    const isDirectSession = () => { try { const d = directSync(); if (d && d.cid && s.cid && String(s.cid) === String(d.cid)) return true; if (engineDirectCid && s.cid && String(s.cid) === engineDirectCid) return true; const t1 = String(s.title || "").trim(), t2 = String(s.titleFull || "").trim(), t3 = String((titleEl && titleEl.textContent) || "").trim(); return [t1, t2, t3].some((t) => /^fil direct$/i.test(t)); } catch (e) { return false; } };
    s.chanOf = (m) => { try { const c = FC.channelOf(m); if (c) return String(c); } catch (e) {} try { if (typeof FC.isFundings === "function" && FC.isFundings(m)) return "fundings"; } catch (e) {} return "autre"; };
    s.paintChannelBar = () => {
      const show = chanOK() && isDirectSession();
      chanBar.style.display = show ? "flex" : "none";
      for (const b of chanBtns) { const on = b.dataset.chan === s.channel; b.classList.toggle("on", on); b.setAttribute("aria-selected", on ? "true" : "false"); }
      const wantBand = show && s.channel === "fundings" && typeof FC.mountFundingsBand === "function";
      fundBand.hidden = !wantBand;
      if (wantBand && !fundMounted) {
        fundMounted = true;
        try { Promise.resolve(FC.mountFundingsBand(fundBand, { h, ic, api, md, navigate: ctx.navigate })).catch(() => { fundBand.replaceChildren(h("div", { class: "ss" }, "Échéances Fundings illisibles pour l'instant.")); }); }
        catch (e) { fundBand.replaceChildren(h("div", { class: "ss" }, "Échéances Fundings illisibles pour l'instant.")); }
      }
    };
    s.applyChannel = (only) => {
      const active = chanOK() && isDirectSession() && s.channel !== "tous";
      const kids = only ? [only] : [...log.children];
      for (const k of kids) {
        if (!k || !k.dataset) continue;
        if (!active) { if (k.dataset.chanHidden) { k.hidden = false; delete k.dataset.chanHidden; } continue; }
        const keep = !!k.dataset.channel && k.dataset.channel === s.channel;
        if (!keep && !k.hidden) { k.hidden = true; k.dataset.chanHidden = "1"; }
        else if (keep && k.dataset.chanHidden) { k.hidden = false; delete k.dataset.chanHidden; }
      }
    };
    s.setChannel = (id) => {
      if (!CHANNELS.some((c) => c[0] === id)) id = "tous";
      s.channel = id;
      try { localStorage.setItem(CHAN_KEY, id); } catch (e) {}
      s.paintChannelBar(); s.applyChannel();
      log.scrollTop = log.scrollHeight;
    };

    /* 29/10 (Ahadi : « make Nova the best UI ever ») — une conversation neuve n'est plus un grand vide noir :
       salutation + quatre départs concrets (clic = la demande part). Disparaît dès le premier message. */
    const welcome = (() => {
      const hr = new Date().getHours();
      const hello = hr < 5 || hr >= 18 ? "Bonsoir Ahadi." : "Bonjour Ahadi.";
      const picks = [
        ["sun", "Le point du jour", "Fais-moi le point du jour : ce qui est urgent dans mes mails, Teams et mon agenda."],
        ["mail", "Ce qui m'attend dans mes mails", "Qu'est-ce qui m'attend dans mes mails depuis hier ? Seulement ce qui demande une action de ma part."],
        ["calendar", "Préparer ma prochaine réunion", "Prépare ma prochaine réunion : objet, participants, derniers échanges et points à trancher."],
        ["chat", "Ce qui a bougé sur Teams", "Résume ce qui a bougé sur Teams aujourd'hui, par personne, avec ce qu'on attend de moi."],
      ];
      const w = h("div", { class: "cs-welcome", hidden: true },
        h("div", { class: "cs-welcome-in" },
          h("img", { class: "cs-welcome-glass", src: "img/glass/conversations-128.webp", srcset: "img/glass/conversations-128.webp 1x, img/glass/conversations-256.webp 2x", alt: "", width: "84", height: "84", decoding: "async", draggable: "false" }),   // 30/10 : icône en verre
          h("div", { class: "cs-welcome-h" }, hello),
          h("div", { class: "cs-welcome-s" }, "Demande, dicte ou glisse un fichier. Rien ne part sans ton GO."),
          h("div", { class: "cs-welcome-picks" }, ...picks.map(([icn, label, ask]) => {
            const b = h("button", { type: "button", class: "cs-welcome-pick" }, h("span", { class: "cs-welcome-ic", html: ic(icn, 16) }), h("span", {}, label));
            b.addEventListener("click", () => { try { input.value = ask; input.dispatchEvent(new Event("input")); s.submit(); } catch (e) {} });
            return b;
          }))));
      const paint = () => { try { w.hidden = !!(log.firstElementChild || s.cid || s.historyLoading || s.running); } catch (e) {} };
      try { new MutationObserver(paint).observe(log, { childList: true }); } catch (e) {}
      s.paintWelcome = paint;
      setTimeout(paint, 0);
      return w;
    })();
    const el = h("section", { class: "cs-view", "data-session": s.id }, head, directBand, chanBar, detailsEl, log, welcome, composer);
    Object.assign(s, { el, dotEl, titleEl, subEl, sparkBadge, brainSel, brainState, depthSeg, depthSummary, depthBlock, autoSel, directBand, traceBox, routineBar, metaFlow, detailsEl, detailBadge, log, input, stopBtn, sendBtn, micBtn, convBtn, liveBtn, speechStopBtn, vstate, attInputs, queueBar, queueLabel, queueState, queueSendBtn });
    el.addEventListener("keydown", (e) => { if (e.key === "Escape" && s.detailsOpen && window.innerWidth <= 1250) s.setDetails(false); });
    s.populateBrains = () => {
      if (!brainsList.length) return;
      const cur = brainSel.value;
      brainSel.replaceChildren(h("option", { value: "" }, "Cerveau : automatique"),
        ...brainsList.filter(keepBrain).map((b) => h("option", { value: String(b.id) }, String(b.label || b.id))));
      try { paintBrainState(); } catch (e) {}
      if (cur) brainSel.value = cur;
      else if (!s.brainTouched && defaultBrainId) {
        /* §30 : défaut des Réglages présélectionné (par identifiant, sinon
           par libellé), jamais réimposé après un choix manuel (brainTouched). */
        const opt = [...brainSel.options].find((o) => o.value === defaultBrainId)
          || (defaultBrainLabel ? [...brainSel.options].find((o) => o.textContent === defaultBrainLabel) : null);
        if (opt) { brainSel.value = opt.value; s.brainLabel = opt.textContent; }
      }
    };
    s.renderHead = () => {
      if (dead || s.dead) return;
      titleEl.textContent = trunc(niceTitle(s.title).t, 60);   // V5-W : même titre lisible que la liste
      try { titleEl.title = s.titleFull || s.title; } catch (e) {}
      dotEl.className = "mp-dot " + (s.running ? "run" : s.unseen ? "unseen" : "idle");
      subEl.textContent = sessionStateWord(s) + (s.usageText ? " · " + s.usageText : "");   // V5-Y : l'identifiant technique du fil ne s'affiche plus (infobulle seulement)
      subEl.title = s.cid ? "Identifiant du fil : " + s.cid : "";
      el.classList.toggle("running", s.running);
      try { if (s.paintChannelBar) s.paintChannelBar(); } catch (e) {}   // V4-D : le sélecteur suit l'identité du fil (Fil direct seulement)
    };
    function showBrain(label, id) {
      s.brainLabel = label || id || "";
      const isSpark = /spark/i.test(String(id || "")) || /spark/i.test(String(label || ""));
      sparkBadge.style.display = isSpark ? "" : "none";   // badge Spark : suit l'événement réel du moteur, jamais simulé
      try { const _b = brainsList.find((x) => x && (String(x.id) === String(id || "") || String(x.label) === String(label || ""))); const _et = _b ? String(_b.etat || "") : ""; brainState.className = "dotst " + brainDotClass(_et); brainState.title = _et; } catch (e) {}
      s.renderHead();
    }
    s.showBrain = showBrain;
    s.touch = () => { s.lastActivity = Date.now(); s.renderHead(); renderList(); };
    s.setDetails = (open) => {
      s.detailsOpen = !!open;
      detailsEl.hidden = !s.detailsOpen;
      if (s.detailsOpen) { s.detailCount = 0; paintDetailBadge(); }
      try { if (s.detailsOpen && window.innerWidth <= 1250) traceBox.classList.add("open"); else traceBox.classList.remove("open"); } catch (e) {}
    };
    function paintDetailBadge() {
      detailBadge.hidden = !s.detailCount;
      detailBadge.textContent = s.detailCount > 99 ? "99+" : String(s.detailCount || "");
      detailsBtn.classList.toggle("has-new", !!s.detailCount);
    }
    s.bumpDetail = () => { if (!s.detailsOpen) { s.detailCount++; paintDetailBadge(); } };

    /* ── Rendu des événements d'exécution → Détails (jamais le fil) ───── */
    s.stepRow = (d) => {
      let row = s.stepRows.get(d.id);
      if (!row) {
        row = h("div", { class: "astep" },
          h("span", { class: "astep-ic spin", html: ic("dot", 13) }),
          h("span", { class: "astep-n" }, "#" + (d.index ?? "")),
          h("span", { class: "astep-tool" }, String(d.tool || "outil")),
          h("span", { class: "astep-arg" }, trunc(d.arg, 90)),
          h("span", { class: "astep-ms" }, ""),
          h("span", { class: "astep-ts" }, d.ts ? msgTimeLabel(d.ts) : ""));   // HORODATAGE : heure de début de l'étape si le moteur la fournit (P-HORO-6) ; sinon rien — jamais d'heure inventée
        s.stepRows.set(d.id, row);
        if (traceBox.querySelector(".empty")) traceBox.replaceChildren();
        traceBox.append(row);
        s.bumpDetail();
      }
      const icEl = row.querySelector(".astep-ic"), msEl = row.querySelector(".astep-ms");
      if (d.state === "ok") { icEl.innerHTML = ic("check", 13); icEl.className = "astep-ic ok"; }
      else if (d.state === "err") { icEl.innerHTML = ic("alert", 13); icEl.className = "astep-ic err"; }
      if (d.beat != null) msEl.textContent = "en cours · " + d.beat + " s";   // DIAG2-FLUX P5 : battement P-FLUX-3 — l'étape ouverte affiche son âge, le gel silencieux devient visible
      if (d.ms != null) msEl.textContent = (Number(d.ms) / 1000).toFixed(1) + " s";
      if (d.checkpoint) row.title = "Point de restauration : " + d.checkpoint;
      if (d.truncated && row) { const t = document.createElement("span"); t.className = "ss"; t.textContent = " · sortie tronquée (" + fmtNumFR(d.out_chars || 0) + " car. d'origine, 8 000 réinjectés)"; row.append(t); }
      if (d.state === "budget" && row) { const t = document.createElement("span"); t.className = "ss"; t.textContent = " · budget de jetons atteint (~" + fmtNumFR(d.tokens || 0) + ") — conclusion sans nouvel outil"; row.append(t); }
      traceBox.scrollTop = traceBox.scrollHeight;
      return row;
    };
    s.notice = (text, cls = "") => {
      const n = h("div", { class: "ss agent-notice " + cls }, text);
      metaFlow.append(n); metaFlow.scrollTop = metaFlow.scrollHeight;
      s.bumpDetail();
      return n;
    };
    s.bubble = (role, text, atts, ts) => {
      const b = h("div", { class: "msg " + (role === "user" ? "me" : "nova") });
      if (role === "user") {
        /* 24/10 : la note OCR d'une capture d'écran part au cerveau mais ne s'affiche pas — une pastille la remplace. */
        let shown = String(text || ""); let shot = "";
        /* V5-W : relu depuis l'historique, le bloc « [Pièces jointes de ce message — … chemin : …] » destiné au
           cerveau redevient des pastilles de pièces jointes ; le texte d'Ahadi seul reste dans la bulle. */
        if (!(atts && atts.length)) { try { const sp = splitBrainBlock(shown); if (sp.atts.length) { shown = sp.text; atts = sp.atts; } } catch (e) {} }
        const ix = shown.indexOf("[Capture de l'écran actif prise sur ma demande");
        if (ix >= 0) { const m = /— ([^·.\n]+)/.exec(shown.slice(ix)); shot = m ? m[1].trim() : "fenêtre active"; shown = shown.slice(0, ix).trim(); }
        /* 26/10 : « ↩ « citation » » en tête = réponse à un message précis → citation affichée au-dessus, comme WhatsApp. */
        const qm = /^↩ « ([\s\S]*?) »\n/.exec(shown);
        if (qm) { b.append(h("span", { class: "msg-quote", title: qm[1] }, qm[1])); shown = shown.slice(qm[0].length); }
        if (shown) b.append(shown);
        if (shot) b.append(h("div", { class: "cs-shot-chip", style: "margin-top:6px;font-size:12px;opacity:.75;display:flex;gap:6px;align-items:center" }, h("span", { html: ic("look", 13) }), "Écran joint : " + shot));
        if (atts && atts.length) b.append(renderSent(atts));
      }
      else b.innerHTML = md(normalizeAnswer(text || ""));   // C1 (29/10) : bulle de Nova (historique, direct, réponse) → rendu déterministe
      /* RV phase 2 (RV-D1) — en-tête d'identité, patron Direct : avatar +
         nom + heure HORS du corps, en ligne FRATRIE posée juste avant la
         bulle — jamais enfant de la bulle : le streaming la réécrit par
         textContent/innerHTML et emporterait un en-tête interne (même
         raison qui fait vivre l'accusé .msg-ack et le badge cerveau en
         fratrie). prevStampedTs saute cette ligne (sans dataset.ts).
         L'heure part vide : stampMsgTime l'écrit dans .msg-who-time quand
         le ts stocké arrive (à la création ou à l'événement « stamp ») ;
         sans ts, rien — jamais d'heure inventée. */
      const head = h("div", { class: "msg-head " + (role === "user" ? "me" : "nova") },
        h("span", { class: "msg-av", html: ic(role === "user" ? "avatar" : "orb", 11) }),
        h("span", { class: "msg-who" }, role === "user" ? "Ahadi" : "Nova"),
        h("span", { class: "msg-who-time" }, ""));
      log.append(head, b);
      if (ts) stampMsgTime(b, ts);   // HORODATAGE : ts stocké du moteur ; absent → aucune heure affichée, jamais inventée
      log.scrollTop = log.scrollHeight; return b;
    };
    /* BUILD-FEED-DIRECT vague 2 (DESIGN §B.4 — remplace la carte §4.4 de la SPEC
       événements) : un message role:"event" du Fil direct se rend comme un MESSAGE
       DE NOVA — même bulle .msg.nova que les réponses, markdown restreint par
       md() (le marqueur « [Ouvrir : X] » du texte composé y devient le bouton de
       navigation), heure par stampMsgTime, séparateurs de jour du fil (posés par
       loadConversation). Aucun en-tête de source, aucune pastille, aucun compteur :
       l'urgence vit dans la phrase (🔴), la source dans le fait. Pas de menu §44
       (réagir/relancer n'a pas de sens sur un événement — inchangé).
       Stock ancien (matérialisé avant la composition, sans marqueur) : le repli
       hérité s'affiche dans la bulle — corps en texte, et bouton « Ouvrir » dérivé
       de l'action structurée, correspondance CORRIGÉE (brief → Veille ; l'ancien
       code envoyait les briefs vers Temps).
       FD (23/10, ordre 19:24 — parité Muse) : l'en-tête redevient porteur :
       source nommée depuis les champs stockés (kind/box), pastille DOTS,
       badges HAUTE (urgent) / DÉCISION (action decision) — l'urgence vit
       toujours dans la phrase du texte composé ; l'en-tête porte les
       métadonnées que le chat de Muse affiche. Et le corps markdown va
       dans .direct-body : avant FD, b.innerHTML = md(content) EFFAÇAIT
       l'en-tête .direct-src posé juste avant, dès que le contenu portait
       le marqueur [Ouvrir (le cas normal). */
    s.directEvent = (m, live) => {
      /* 24/10 — CARTE D'ARRIVÉE UNIQUE (feedcard.js) : même composition pour toute arrivée
         (source · tri · BLUF · commentaire de Nova · à toi · DOTS · mémoire · action),
         même descente (fd-in, sans rechargement), même réaction du compagnon
         (nova:feed-arrival émis par la carte pour les arrivées vivantes seulement). */
      let b;
      try { b = renderFeedCard(m, { h, md, ic, navigate: ctx.navigate }, !!live); }
      catch (e) { b = h("div", { class: "msg nova direct-msg" }, String(m.content || "")); }
      /* FIXES-MAIL (24/10) : UNE carte par arrivée — une carte du même feed déjà au fil
         est remplacée en place (enrichissement : corps lu → BLUF, tri, commentaire). */
      const fid = (m && m.feed != null && m.feed !== "") ? String(m.feed) : "";
      let prev = null;
      if (fid) {
        try { b.dataset.feed = fid; } catch (e) {}
        try { prev = [...log.children].find((k) => k && k !== b && k.dataset && k.dataset.feed === fid) || null; } catch (e) { prev = null; }
      }
      /* V5-T (25/10) : clé LOGIQUE en plus du feed — un même événement stocké deux fois sous
         deux ids (rejeu « Plus tard », deux producteurs, historique d'avant le correctif moteur)
         ne s'affiche qu'UNE fois : même run d'Éclat (toujours), ou même kind|boîte|titre à
         moins de 10 min. La carte la plus récente remplace l'ancienne, à sa place. */
      let lk = ""; try { lk = FC.logicalKeyOf ? FC.logicalKeyOf(m) : ""; } catch (e) { lk = ""; }
      const lts = new Date((m && m.ts) || 0).getTime() || 0;
      if (lk) {
        try { b.dataset.lk = lk; b.dataset.lts = String(lts); } catch (e) {}
        if (!prev) {
          try { prev = [...log.children].find((k) => k && k !== b && k.dataset && k.dataset.lk === lk && (lk.startsWith("run|") || Math.abs((Number(k.dataset.lts) || 0) - lts) <= 600000)) || null; } catch (e) { prev = null; }
        }
      }
      try { b.dataset.channel = s.chanOf(m); } catch (e) {}   // V4-D : canal pour le sélecteur du Fil direct
      if (prev) { try { prev.replaceWith(b); } catch (e) { log.append(b); } }
      else log.append(b);
      /* 25/10 : plusieurs exécutions du MÊME Éclat ne s'empilent plus — seule la plus récente reste visible,
         avec « +N exécutions précédentes » pour déplier les autres (rien n'est supprimé). */
      try {
        const dn = b.dataset && b.dataset.dot;
        if (dn) {
          const older = [...log.children].filter((k) => k !== b && k.dataset && k.dataset.dot === dn && !k.classList.contains("fc-skip"));
          if (older.length) {
            for (const k of older) { k.hidden = true; const ob = k.querySelector(".fc-older"); if (ob) ob.remove(); }
            const btn = h("button", { class: "fc-older", type: "button" }, "+" + older.length + (older.length > 1 ? " exécutions précédentes" : " exécution précédente"));
            btn.addEventListener("click", (ev) => { ev.stopPropagation(); const show = older.some((k) => k.hidden); for (const k of older) k.hidden = !show; btn.textContent = show ? "Masquer les précédentes" : "+" + older.length + (older.length > 1 ? " exécutions précédentes" : " exécution précédente"); });
            b.append(btn);
          }
        }
      } catch (e) {}
      try { s.applyChannel(b); } catch (e) {}
      log.scrollTop = log.scrollHeight;   // 25/10 (2) : plus de défilement « smooth » ici — il décollait le suivi du fil
      return b;
    };

    /* ── §42 — ACCUSÉS, RÉACTIONS, RELANCES (ordre d'Ahadi, 21/10 09:44)
       · Accusé : sa bulle reçoit « 👍 reçu » dès l'envoi, « 👀 Nova s'en
         occupe… » au premier événement du moteur, « ✅ » à la fin.
       · Réactions à sens stable sur chaque réponse de Nova : 👍 utile,
         ❤️ j'aime (persistées, localStorage par conversation+empreinte).
       · Relance ciblée : ↪ vise une réponse ; le prochain message part
         avec la directive moteur « en réponse à ce message précis ».
         Chips d'un toucher : Détaille / Plus court / Un exemple / Continue.
         🔁 = refais autrement · ⚠️ = trouve le problème et corrige. ── */
    const REACT_KEY = "nova2_reactions";
    const hashTxt = (t) => { let x = 5381; const s2 = String(t || ""); for (let i = 0; i < s2.length; i++) x = ((x << 5) + x + s2.charCodeAt(i)) >>> 0; return x.toString(36); };
    const loadReacts = () => { try { return JSON.parse(localStorage.getItem(REACT_KEY) || "{}"); } catch (e) { return {}; } };
    s.setAck = (b) => {
      if (!b) return;
      const chip = h("div", { class: "msg-ack" }, "👍 reçu — Nova s'y met");   // 28/10 (Ahadi) : accusé de réception en emoji, langue commune
      try { b.after(chip); } catch (e) { b.append(chip); }
      s.ackEl = chip; s.ackBubble = b;
    };
    s.followUp = (quoted, instruction) => {
      s.pendingQuote = trunc(String(quoted || ""), 220);
      paintQuoteBar();
      s.submit(instruction);
    };
    /* LOT WEB v3 : §44 est factorisé dans core.bindChatMessage (menu,
       réactions, pastilles, clavier et appui long). Cette surface ne fournit
       que la relance métier : citation dans la barre de visée et suivis par
       la file d'envoi de la conversation. Le lieur est posé à la création de
       la bulle, donc actif PENDANT le streaming. */
    s.bindMsgMenu = (b, getText) => bindChatMessage(b, getText, {
      cid: () => s.cid || "local",
      copyText: (text) => normalizeAnswer(text),   // C1 : « Copier » copie la réponse normalisée (la clé des réactions reste le texte brut)
      quote: (text) => { s.pendingQuote = trunc(String(text || ""), 220); paintQuoteBar(); input.focus(); },
      follow: (text, label) => {
        const instructions = {
          "Détaille": "Détaille", "Plus court": "Plus court", "Un exemple": "Un exemple", "Continue": "Continue",
          "Refais autrement": "Refais cette réponse autrement.",
          "Corrige le problème": "Il y a un problème dans cette réponse : trouve-le et corrige-la.",
          "Explique simplement": "Explique plus simplement, avec un exemple concret, sans jargon.",
        };
        s.followUp(text, instructions[label] || label);
      },
      /* 28/10 : réaction emoji d'Ahadi journalisée côté moteur (leçons). */
      onReaction: (emoji, sens) => { try { const p2 = api.post("/api/feedback/reaction", { emoji, sens, cid: s.cid || "" }); if (p2 && p2.catch) p2.catch(() => {}); } catch (e) {} },
    });
    s.decorateNovaBubble = (b, text) => {
      if (!b || !text) return;
      if (b.dataset.menuBound) { if (b._paintRx) b._paintRx(); return; }
      s.bindMsgMenu(b, () => text);
    };

    /* ── Voix de CETTE conversation : dictée + conversation vocale ────── */
    let dictBusy = false;
    function setVoiceMode(on) {
      s.voiceMode = !!on;
      convBtn.classList.toggle("on", s.voiceMode);
      if (!s.voiceMode && voice) voice.stopSpeaking();
      if (s.voiceMode) ctx.toast("Conversation vocale : parle ou écris, Nova répond à voix haute, en phrases courtes.");
    }
    s.setVoiceMode = setVoiceMode;
    s.paintVoiceState = (st) => { speechStopBtn.hidden = st !== "parole"; };
    /* ── VL : bascule de la conversation vocale live (session native
       partagée — l'état suit voiceLive.actif(), pas cette session). ── */
    async function toggleLive() {
      const vl = getVoiceLive();
      if (vl.actif()) {
        liveBtn.classList.remove("on");
        await vl.stop();
        perfSignal("voix-live", false);   // V4-D : gouverneur
        vstate.textContent = voiceStatus;
        return;
      }
      if (s.voiceMode) setVoiceMode(false);
      if (voice) voice.stopSpeaking();
      try {
        await vl.start();
        perfSignal("voix-live", true);   // V4-D : gouverneur
        liveBtn.classList.add("on");
        ctx.toast("Conversation live : parle, Nova t'écoute et répond avec sa voix. Reparle par-dessus pour l'interrompre ; reclique « Live » pour terminer.");
      } catch (e) { ctx.toast(String((e && e.message) || e), true); }
    }
    s.toggleLive = toggleLive;
    s.paintLiveState = (st) => {
      const on = !!(voiceLive && voiceLive.actif());
      const e = on ? String(st || "ecoute") : "off";
      liveBtn.classList.toggle("on", on);
      liveBtn.dataset.live = e;
      liveBtn.setAttribute("aria-pressed", on ? "true" : "false");
      const LBL = { ecoute: "Écoute", reflexion: "Réfléchit", parole: "Nova parle", erreur: "Erreur" };
      liveLbl.textContent = on ? (LBL[e] || "Live") : "Parler";
      liveBtn.title = !on ? "Nova Live — parler en continu"
        : e === "parole" ? "Nova Live — Nova parle (reparle pour l'interrompre, ou ⏸) · clique pour terminer"
        : e === "reflexion" ? "Nova Live — Nova réfléchit · clique pour terminer"
        : "Nova Live — je t'écoute · clique pour terminer";
      if (st === "parole") speechStopBtn.hidden = false;
      else if (!voice || !voice.isSpeaking()) speechStopBtn.hidden = true;
    };
    /* V6-COMPAGNON (25/10, « quand le message est fini on n'arrive pas à envoyer ») : la dictée se
       termine par le micro, par Envoyer OU par Entrée — le texte transcrit tombe dans le champ, puis
       (Envoyer / Entrée) part aussitôt. L'état ne reste jamais coincé sur « J'écoute » : tout échec
       rend le micro, repeint le bouton et laisse le champ utilisable. */
    let dictP = null;
    const paintMic = (on) => {
      micBtn.classList.toggle("rec", !!on);
      micBtn.setAttribute("aria-pressed", on ? "true" : "false");
      micBtn.title = on ? "Arrêter la dictée — le texte tombe dans le champ (Envoyer / Entrée l'envoie directement)" : "Dicter (micro) — clique, parle, puis reclique ou Envoyer : le texte tombe dans le champ";
    };
    s.finishDictation = () => {
      if (dictP) return dictP;
      const v = voice;
      if (!v || !v.isListening()) return Promise.resolve("");
      dictBusy = true;
      paintMic(false);
      vstate.textContent = "Transcription en cours…";
      dictP = (async () => {
        try {
          const t = await v.listenStop();
          if (s.dead) return "";
          const add = String(t || "").trim();
          if (add) {
            const cur = input.value;
            input.value = (cur && !/\s$/.test(cur) ? cur + " " : cur) + add;
            autoGrow();
            try { input.focus(); const n = input.value.length; input.setSelectionRange(n, n); } catch (e) {}
          }
          return add;
        } catch (e) { ctx.toast(String((e && e.message) || e), true); return ""; }
        finally { dictBusy = false; dictP = null; paintMic(false); vstate.textContent = voiceStatus; paintSendBtn(); }
      })();
      return dictP;
    };
    s.dictationActive = () => !!(dictP || (voice && voice.isListening()));
    micBtn.addEventListener("click", async () => {
      if (dictBusy) return;
      const v = getVoice();
      if (v.isListening()) { await s.finishDictation(); return; }
      v.stopSpeaking();
      dictBusy = true;
      try {
        await v.listenStart();
        paintMic(true);
        vstate.textContent = "Je t'écoute — parle ; le message part tout seul quand tu te tais.";
      } catch (e) { paintMic(false); try { v.cancelListen && v.cancelListen(); } catch (er) {} ctx.toast("Micro : " + String((e && e.message) || e), true); }
      finally { dictBusy = false; }
    });
    input.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && voice && voice.isListening() && !dictP) { e.preventDefault(); try { voice.cancelListen(); } catch (er) {} paintMic(false); vstate.textContent = voiceStatus; }
    });

    /* ── Bandeau Direct de CETTE vue (DS §9.3 : surface unique, enrichie) ──
       Ligne 1 : avatar + titre + compteur « +N » CLIQUABLE (déploie la file).
       Ligne 2 : .direct-body — le corps est VISIBLE (tronqué 2 lignes par le CSS),
       jamais relégué dans l'attribut title seul. Actions : primaire + Vu + Plus
       tard ; le ✕ masque LOCALEMENT sans marquer comme vu (asymétrie documentée
       dans l'aide dépliée de la file, ci-dessous). */
    let directOpen = false;
    s.renderDirectBand = (items) => {
      if (dead || s.dead) return;
      const listItems = Array.isArray(items) ? items : [];
      const item = listItems[0] || null;
      /* V5-Y (25/10) : le bandeau ne vit QUE dans le Fil direct (l'Accueil a ses propres cartes) —
         il ne s'empile plus au-dessus de chaque conversation. */
      let isDirectView = false; try { directSync(); const dc = String(dst.cid || engineDirectCid || ""); isDirectView = !!(dc && s.cid && String(s.cid) === dc); } catch (e) { isDirectView = false; }
      if (!item || !isDirectView) { directBand.hidden = true; directBand.replaceChildren(); s._fdBandKey = ""; return; }
      /* FD (23/10) : une tête de file NOUVELLE (après amorçage) entre avec
         la classe d'entrée — y compris quand elle le devient par
         acquittement de la précédente : c'est elle qui arrive à
         l'attention. Même tête repeinte (états, compteurs) : rien. */
      const fdKey = String(item.key || "");
      if (fdKey && s._fdBandKey && fdKey !== s._fdBandKey) { try { directBand.classList.remove("fd-in"); void directBand.offsetWidth; directBand.classList.add("fd-in"); } catch (e) {} }
      if (fdKey) s._fdBandKey = fdKey;
      const total = listItems.length;
      const avatarOf = (it) => {
        if (it.dot) { const host = h("span", { class: "mp-dot-avatar sm", title: it.dot.name }); try { mountPlush(host, it.dot.color || "#D93226", 20, it.dot.id || it.dot.name, ""); } catch (e) {} return host; }
        return h("span", { class: "mp-dot-avatar sm sys", title: "Nova", html: ic("orb", 14) });
      };
      const actBtns = (it) => [
        ...(it.runId ? [h("button", { class: "btn sm acc", onclick: () => openDotReader(it) }, "Lire")] : []),
        ...(it.action && it.action.label ? [h("button", { class: "btn sm acc", onclick: () => {
          if (it.action.module) ctx.navigate(it.action.module);
          else if (it.action.href) { try { location.href = it.action.href; } catch (e) {} }
        } }, it.action.label)] : []),
        h("button", { class: "btn sm", onclick: () => { if (it.kind === "waiting") ctx.direct.ackWaiting(it, 0); else ctx.direct.markSeen(it.key); } }, "Vu"),
        h("button", { class: "btn sm", onclick: () => { if (it.kind === "waiting") ctx.direct.ackWaiting(it, 60); else ctx.direct.snooze(it.key, 60); } }, "Plus tard"),
      ];
      const fileRow = (it) => h("div", { class: "row-item" }, avatarOf(it),
        h("div", { class: "row-main" },
          h("div", { class: "tt" }, (it.dot ? it.dot.name + " · " : "") + it.titre),
          it.corps ? h("div", { class: "ss ss--wrap" }, it.corps) : null),
        h("div", { class: "row-actions" }, ...actBtns(it)));
      /* FINITION 21/10 : ne JAMAIS passer un null nu à replaceChildren —
         le DOM le convertit en texte « null » visible. Enfants filtrés. */
      directBand.replaceChildren(...[
        h("div", { class: "cs-direct-line" },
          avatarOf(item),
          h("span", { class: "cs-direct-t", title: item.corps ? String(item.corps) : "" }, (item.dot ? item.dot.name + " · " : "") + item.titre),
          total > 1 ? h("button", { class: "more-chip direct-count", title: directOpen ? "Replier la file Direct" : "Déployer la file Direct (" + total + " éléments)",
            onclick: () => { directOpen = !directOpen; s.renderDirectBand(listItems); } }, "+" + (total - 1)) : null,
          h("span", { class: "sp" }),
          ...actBtns(item),
          h("button", { class: "btn-close cs-direct-x", title: "Masquer le bandeau pour cette session — rien n'est marqué comme vu ; une nouvelle arrivée le rouvrira", "aria-label": "Masquer le bandeau pour cette session", onclick: () => { for (const it of listItems) bandDismissed.add(it.key); saveBandDismissed(); syncDirect(); }, html: ic("close", 14) })),
        directOpen && total > 1 ? h("div", { class: "direct-file", tabindex: "0" },
          ...listItems.slice(1).map(fileRow),
          h("div", { class: "ss ss--wrap" }, "File Direct complète. « Vu » et « Plus tard » s'appliquent partout (service unique) ; « Masquer sans vu » ne masque que ce bandeau, ici.")) : null,
      ].filter(Boolean));
      directBand.hidden = false;
    };
    s.syncDirect = () => syncDirect();

    /* §36 (21/10) : lecteur de résultat de Dot SUR PLACE — le message vient
       à Ahadi, il ne quitte ni sa conversation ni son écran. Le résultat
       complet est relu depuis GET /api/dots (historique moteur, 30
       dernières exécutions) ; jamais de contenu fabriqué si absent. */
    async function openDotReader(it) {
      let run = null;
      try {
        const j = await api.get("/api/dots");
        const runs = (j && j.runs) || [];
        run = runs.find((r) => String(r.id || r.run_id || "") === String(it.runId)) || null;
      } catch (e) {}
      const veil = h("div", { class: "modal-veil" });
      const close = () => veil.remove();
      veil.addEventListener("click", (e) => { if (e.target === veil) close(); });
      const body = h("div", { class: "dot-reader-body" });
      const full = run && (run.result || run.summary);
      if (full) body.innerHTML = md(String(full));
      else body.append(h("div", { class: "ss ss--wrap" }, "Résultat introuvable dans l'historique récent (30 dernières exécutions) — il reste lisible dans l'écran Éclats."));
      veil.append(h("div", { class: "dot-reader card" },
        h("div", { class: "dot-reader-head" },
          h("span", { class: "tt" }, (it.dot ? it.dot.name + " · " : "") + (it.titre || "Résultat de l'Éclat")),
          h("span", { class: "sp" }),
          h("button", { class: "btn sm", onclick: close }, "Fermer")),
        body));
      document.body.append(veil);
    }

    /* ── Cartes d'approbation granulaires (dans le fil — conversation) ── */
    s.confirmCard = (d) => {
      const card = h("div", { class: "appr" });
      const tool = String(d.tool || "action");
      const head = h("div", { class: "appr-head" }, h("span", { html: ic("alert", 18) }),
        h("span", {}, "Approbation requise — " + tool));
      const scope = h("div", { class: "appr-scope" }, "Périmètre : outil « " + tool + " »" + (d.kind ? " · type : " + String(d.kind) : "") +
        " · déclencheur : " + (d.reason === "politique" ? "politique de l'outil" : "garde-fou du moteur") +
        (READONLY_TOOLS.has(tool) ? " · lecture seule" : " · action à effet"));
      const body = h("div", {},
        d.preview ? h("div", { class: "tt", style: "white-space:normal" }, String(d.preview)) : null,
        d.cmd ? h("div", { class: "appr-cmd" }, String(d.cmd)) : (d.arg ? h("div", { class: "appr-cmd" }, trunc(d.arg, 300)) : null),
        scope,
        h("div", { class: "ss", style: "color:var(--ink-2);margin-top:6px" }, "Sans réponse sous 3 min, l'agent considère que c'est refusé."));
      const status = h("div", { class: "ss", style: "margin-top:8px" }, "");
      const okBtn = h("button", { class: "btn lg acc", onclick: () => decide(true) }, "Approuver");
      const hourBtn = h("button", { class: "btn", title: "Le moteur cesse de demander pour les commandes courantes pendant 1 h (jamais les actions destructrices)", onclick: () => decide(true, 60) }, "Autoriser 1 h");
      const noBtn = h("button", { class: "btn danger", onclick: () => decide(false) }, "Refuser");
      const motifBtn = h("button", { class: "btn", onclick: () => motifRow.classList.toggle("open") }, "Refuser avec motif…");
      const alwaysBtn = READONLY_TOOLS.has(tool)
        ? h("button", { class: "btn", title: "Crée une règle persistante (lecture seule) : l'interface approuvera ce type sans te déranger", onclick: () => decideAlways() }, "Toujours autoriser ce type")
        : null;
      const motifIn = h("input", { type: "text", class: "fld", placeholder: "Motif du refus — il repart à l'agent (ex. pas ce fichier, l'autre)" });
      const motifRow = h("div", { class: "motif-row" }, motifIn,
        h("button", { class: "btn danger", onclick: () => decide(false, 0, motifIn.value.trim()) }, "Refuser avec ce motif"));
      let decided = false;
      async function decide(ok, freeMinutes = 0, motif = "") {
        if (decided) return; decided = true;
        [okBtn, hourBtn, noBtn, motifBtn, alwaysBtn].forEach((b) => { if (b) b.disabled = true; });
        try {
          const cj = await api.post("/api/confirm", { id: d.id, ok, ...(freeMinutes ? { free_minutes: freeMinutes } : {}) });
          /* LOT1-FIX m18 : le moteur répond {message} (« Autorisé. » / « Refusé. » /
             « Demande expirée. », Tools.decide) — la décision n'est tenue pour
             appliquée que si le message CONFIRME le sens demandé ; sinon le
             message du moteur s'affiche tel quel. */
          const cmsg = cj && cj.message ? String(cj.message) : "";
          if (cmsg !== (ok ? "Autorisé." : "Refusé.")) status.textContent = "Moteur : " + (cmsg || "réponse illisible") + " — ta décision n'a pas été appliquée.";
          else status.textContent = ok ? (freeMinutes ? "Envoyé : approuvé + passe 1 h pour les commandes courantes." : "Envoyé : approuvé.") : "Envoyé : refusé" + (motif ? " avec motif." : ".");
          audit(ok ? "approbation" : "refus", tool + (freeMinutes ? " (+1 h)" : ""), motif || (ok ? "approuvé" : "refusé"));
          if (!ok && motif) sendMotif(tool, motif);
        } catch (e) { status.textContent = "Échec de l'envoi de ta décision — l'agent refusera seul après 3 min."; }
      }
      async function decideAlways() {
        if (decided) return;
        if (!ruleFor(tool)) { rules.push({ type: "always", tool, scope: "lecture", at: Date.now() }); await saveRules(); }
        audit("regle", "Règle créée : toujours autoriser « " + tool + " » (lecture seule)", "persistée");
        decide(true);
      }
      function sendMotif(toolName, motif) {
        const msg = "Motif de mon refus pour « " + toolName + " » : " + motif + " — adapte ton approche en conséquence.";
        setTimeout(() => { if (dead || s.dead) return; if (!s.running) { s.pendingUserBubble = s.bubble("user", msg); s.runAgent(msg, msg, {}); } else { input.value = msg; s.notice("Motif noté — il partira avec ton prochain message (l'agent est encore en cours)."); } }, 1200);
      }
      card.replaceChildren(head, body, h("div", { style: "display:flex;gap:8px;margin-top:10px;flex-wrap:wrap" }, okBtn, hourBtn, alwaysBtn, noBtn, motifBtn), motifRow, status);
      card._resolve = (ok) => { decided = true; [okBtn, hourBtn, noBtn, motifBtn, alwaysBtn].forEach((b) => { if (b) b.disabled = true; }); status.textContent = ok ? "Résolu : approuvé." : "Résolu : refusé (ou délai dépassé)."; card.classList.add(ok ? "ok" : "no"); };
      if (ruleFor(tool)) {
        status.textContent = "Ta règle « toujours autoriser " + tool + " » s'applique — approbation automatique par l'interface…";
        setTimeout(async () => { if (!decided && !dead && !s.dead) { try { const cj = await api.post("/api/confirm", { id: d.id, ok: true }); if (cj && cj.message && String(cj.message) !== "Autorisé.") { status.textContent = "Approbation automatique NON appliquée — moteur : " + String(cj.message); } else { decided = true; status.textContent = "Approuvé automatiquement par ta règle (interface). Le moteur garde ses garde-fous propres."; audit("approbation-auto", tool, "règle « toujours autoriser »"); } } catch (e) {} } }, 400);
      }
      log.append(card); log.scrollTop = log.scrollHeight;
      if (s !== activeSession()) { s.unseen = true; s.renderHead(); renderList(); }
      return card;
    };

    /* ── Plan éditable — présenté dans le tiroir Détails (hors du fil) ── */
    function planSteps(text) {
      const t = text.toLowerCase();
      const brainLabel = brainSel.value ? (brainSel.selectedOptions[0] && brainSel.selectedOptions[0].textContent) : "automatique (chaîne du moteur)";
      const steps = [{ on: true, fixed: true, text: "Comprendre la demande et planifier — cerveau : " + brainLabel + " · profondeur : " + s.depth }];
      if (/mail|courriel|boîte|inbox|message|teams|outlook/.test(t)) steps.push({ on: true, text: "Lire les messages concernés (lecture seule)" });
      if (/fichier|document|rapport|note|pdf|dossier|texte/.test(t)) steps.push({ on: true, text: "Lire les fichiers et documents utiles (lecture seule)" });
      if (/agenda|rendez-vous|réunion|calendrier|planning/.test(t)) steps.push({ on: true, text: "Consulter l'agenda et les engagements" });
      if (/web|internet|cherche|recherche|actualité|brvm|cours|prix/.test(t)) steps.push({ on: true, text: "Chercher les informations à jour (web et données Nova)" });
      steps.push({ on: true, text: "Exécuter les actions nécessaires avec les outils — chaque geste sensible passe par une carte d'approbation" });
      if (/envo|mail|message|écris|ecris|répond/.test(t)) steps.push({ on: true, text: "Préparer un brouillon pour ta relecture (jamais d'envoi direct)" });
      steps.push({ on: true, fixed: true, text: "Vérifier le résultat et te rendre compte — trace complète dans les Détails de cette conversation" });
      return steps;
    }
    s.cancelPlan = () => { if (s.pendingPlan) { s.pendingPlan.remove(); s.pendingPlan = null; } };
    s.showPlan = (text) => {
      s.cancelPlan();
      const card = h("div", { class: "appr appr--plan" });
      const rowsBox = h("div", {});
      const steps = planSteps(text);
      function draw() {
        rowsBox.replaceChildren(...steps.map((st, i) => {
          const cb = h("input", { type: "checkbox", ...(st.on ? { checked: "" } : {}), ...(st.fixed ? { disabled: "" } : {}) });
          cb.addEventListener("change", () => { st.on = cb.checked; row.classList.toggle("off", !st.on); });
          const fld = h("input", { type: "text", class: "fld", value: st.text });
          fld.addEventListener("input", () => { st.text = fld.value; });
          const rm = st.fixed ? h("span", { class: "ss", style: "flex:none" }, "noyau") : h("button", { class: "rm", title: "Retirer cette étape", onclick: () => { steps.splice(i, 1); draw(); }, html: ic("close", 14) });
          const row = h("div", { class: "plan-step" + (st.on ? "" : " off") }, cb, fld, rm);
          return row;
        }));
      }
      draw();
      const bMin = h("input", { type: "number", min: "1", max: "120", value: String(budget.min) });
      const bSteps = h("input", { type: "number", min: "1", max: "500", value: String(budget.steps) });
      const syncBudget = () => { budget = { min: Math.max(1, Number(bMin.value) || 10), steps: Math.max(1, Number(bSteps.value) || 40) }; saveBudget(); };
      [bMin, bSteps].forEach((i) => i.addEventListener("change", syncBudget));
      const launch = (withPlan) => {
        syncBudget();
        const kept = steps.filter((x) => x.on && x.text.trim());
        s.cancelPlan();
        s.bubble("user", text);
        const suffix = withPlan && kept.length ? "\n\nPlan validé par l'utilisateur (suis-le ; les étapes absentes ont été retirées par lui) :\n" + kept.map((x, i) => (i + 1) + ". " + x.text.trim()).join("\n") : "";
        s.runAgent(text + suffix, text, { voice: s.voiceMode });
      };
      card.replaceChildren(
        h("div", { class: "appr-head" }, h("span", { html: ic("route", 18) }), h("span", {}, "Plan d'exécution — édite, retire, puis lance")),
        h("div", { class: "ss", style: "color:var(--ink-2)" }, "Tâche : « " + trunc(text, 110) + " »"),
        rowsBox,
        h("button", { class: "btn", style: "margin-top:4px", onclick: () => { steps.push({ on: true, text: "" }); draw(); const ins = rowsBox.querySelectorAll("input.fld, input[type='text']"); const last = ins[ins.length - 1]; if (last) last.focus(); } }, h("span", { html: ic("plus", 14) }), " Ajouter une étape"),
        h("div", { class: "est-line", style: "margin-top:10px" }, estText(brainSel.value || "")),
        h("div", { class: "budget-grid" },
          h("label", {}, "Repère durée (min)", bMin),
          h("label", {}, "Repère étapes", bSteps),
          h("span", { class: "ss", style: "color:var(--ink-3);max-width:300px" }, "Repères d'alerte : au dépassement, une alerte s'affiche et le run ORDONNÉ continue — la coupure reste manuelle (bouton Stop).")),
        h("div", { style: "display:flex;gap:8px;margin-top:12px;flex-wrap:wrap" },
          h("button", { class: "btn acc", onclick: () => launch(true) }, "Lancer avec ce plan"),
          h("button", { class: "btn", onclick: () => launch(false) }, "Lancer sans plan"),
          h("button", { class: "btn danger", onclick: () => { s.cancelPlan(); input.value = text; input.focus(); } }, "Annuler")));
      metaFlow.append(card); s.pendingPlan = card;
      s.setDetails(true);   // le plan demande une décision : le tiroir s'ouvre, le fil reste propre
    };

    /* ── Exécution SSE (par session — flux isolé, jamais coupé) ───────── */
    s.setRunning = (on) => {
      s.running = on; if (on) s._vxFiller = false;   // une phrase d'attente par tour vocal
      try { if (s.paintWelcome) s.paintWelcome(); } catch (e) {}
      perfSignal("chat-" + s.id, !!on);   // V4-D : gouverneur — stream en cours / terminé
      stopBtn.style.display = on ? "" : "none";
      paintSendBtn();   // plus de verrouillage : envoyer pendant une exécution met en file
      if (!on && s.budgetTimer) { clearInterval(s.budgetTimer); s.budgetTimer = 0; }
      s.renderHead(); renderList();
    };
    s.stopRun = async () => {
      s.runToken++;
      try { if (s.cid) await api.post("/api/chat/stop", { conversation_id: s.cid }); } catch (e) {}
      try { s.abortCtl && s.abortCtl.abort(); } catch (e) {}
      s.setRunning(false);
      /* Un arrêt met la file EN PAUSE, sans la vider : elle reste visible
         dans sa barre et repart au clic sur « Envoyer la file ». */
      if (s.queue.length) { s.queuePaused = true; s.paintQueue(); }
      try { const r = JSON.parse(localStorage.getItem(RUN_KEY) || "null"); if (r && r.cid === s.cid) { r.status = "stoppé"; r.finishedAt = Date.now(); localStorage.setItem(RUN_KEY, JSON.stringify(r)); } } catch (e) {}
      s.notice("Arrêt demandé — l'agent s'interrompt à la fin de l'étape en cours.");
    };
    s.budgetCheck = () => {
      if (!s.runStats || s.runStats.tripped || !s.running) return;
      const elapsedMin = (Date.now() - s.runStats.t0) / 60000;
      let why = "";
      if (elapsedMin > budget.min) why = "durée (" + elapsedMin.toFixed(1) + " min > " + budget.min + " min)";
      else if (s.runStats.steps > budget.steps) why = "étapes (" + s.runStats.steps + " > " + budget.steps + ")";
      if (!why) return;
      s.runStats.tripped = true;
      // AUTONOMIE A1 (22/10) : repère, pas une coupure. Le run est ORDONNÉ (chat,
      // panneau, file, Reprendre) : il continue jusqu'à son terme ; l'arrêt reste
      // manuel (bouton Stop) ou vient du moteur. Une alerte par run, journalisée.
      audit("budget", "Repère dépassé : " + why, "run ordonné — poursuite sans coupure (A1)");
      s.notice("Repère dépassé — " + why + ". Run ordonné : je continue sans couper (pour arrêter : bouton Stop).", "warn");
    };
    s.submit = async (textOverride) => {
      /* Garde-fous conservés : téléversement en cours (attSending / bac
         occupé) = on ne peut pas prendre un instantané propre, on attend.
         En revanche `s.running` ne bloque PLUS : le message part en file. */
      if (s.attSending || att.busy()) return;
      /* V6-COMPAGNON : Envoyer / Entrée pendant la dictée = fin de dictée PUIS envoi du texte transcrit. */
      if (textOverride == null && s.dictationActive && s.dictationActive()) { await s.finishDictation(); if (s.dead) return; }
      const hasAtt = att.count() > 0;
      const text = String(textOverride ?? input.value).trim();
      if (!text && !hasAtt) return;
      if (textOverride == null) { input.value = ""; try { input.style.height = ""; } catch (e) {} }
      if (s.running) { await s.enqueue(text); return; }
      if (textOverride == null && planFirst && !hasAtt) { s.showPlan(text); return; }
      await s.sendNow(text, text);
    };
    /* ── File d'envoi : mise en file, affichage, vidange ───────────────
       Chaque élément = { text, atts (instantané téléversé), voice,
       bubble } — la bulle est rendue TOUT DE SUITE dans le fil avec la
       classe .cs-queued ; au lancement, la même bulle perd sa marque
       (jamais de double bulle). */
    s.enqueue = async (text) => {
      try { if (s.channel && s.channel !== "tous" && chanBar.style.display !== "none") s.setChannel("tous"); } catch (e) {}   // V4-D : idem sendNow
      let atts = [];
      if (att.count()) {
        s.attSending = true; paintSendBtn();
        try { await att.uploadPending(); atts = att.take(); }
        catch (e) {
          s.attSending = false; paintSendBtn();
          if (!input.value) input.value = text;
          ctx.toast("Pièce jointe : " + String((e && e.message) || e), true);
          return;
        }
        s.attSending = false; paintSendBtn();
      }
      const scq = s.takeScreen();   // V4-D : capture d'écran en attente → part avec CE message
      const item = { text, atts, voice: s.voiceMode, bubble: null, quote: s.pendingQuote || "", screenNote: scq.note, images: visionImages(atts).concat(scq.images) };
      if (s.pendingQuote) { s.pendingQuote = ""; paintQuoteBar(); }
      item.bubble = s.bubble("user", (item.quote ? "↩ « " + item.quote.replace(/\s*\n+\s*/g, " ") + " »\n" : "") + text, atts);
      if (item.bubble) { item.bubble.classList.add("cs-queued"); s.setAck(item.bubble); }
      s.queue.push(item);
      s.used = true;
      s.paintQueue();
    };
    s.paintQueue = () => {
      const n = s.queue.length;
      queueBar.hidden = !n;
      if (!n) return;
      queueLabel.textContent = n > 1 ? n + " ajouts à la tâche" : "1 ajout à la tâche";
      queueState.textContent = s.queuePaused ? "en pause — l'arrêt a suspendu la file" : "file : chaque ajout part comme son propre message dès la fin du tour en cours, dans l'ordre écrit";
      queueSendBtn.style.display = s.queuePaused ? "" : "none";
    };
    s.clearQueue = () => {
      for (const item of s.queue) { if (item.bubble) item.bubble.remove(); }
      s.queue = [];
      s.paintQueue();
    };
    s.sendQueue = () => { s.queuePaused = false; s.paintQueue(); s.drainQueue(); };
    s.drainQueue = () => {
      if (dead || s.dead || s.running || s.attSending || s.queuePaused || !s.queue.length) return;
      setTimeout(() => {
        if (dead || s.dead || s.running || s.attSending || s.queuePaused) return;
        const item = s.queue.shift();
        if (!item) { s.paintQueue(); return; }
        if (item.bubble) item.bubble.classList.remove("cs-queued");
        if (item.bubble) s.pendingUserBubble = item.bubble;   // HORODATAGE : même tamponnage au « meta », pour les messages partis de la file
        s.paintQueue();
        let engineText = item.text + (item.atts.length ? (item.text ? "\n\n" : "") + describeForBrain(item.atts) : "");
        if (item.screenNote) engineText += "\n\n" + item.screenNote;   // V4-D : capture d'écran jointe
        if (item.quote) engineText = "[RELANCE — en réponse à ce message précis de Nova : « " + item.quote + " »]\n" + engineText;
        s.runAgent(engineText, item.text, { voice: item.voice, images: item.images || [] });
      }, 400);
    };
    /* ── §34 — PILOTAGE EN COURS D'EXÉCUTION (ordre d'Ahadi, 21/10 09:10) ──
       Un message écrit pendant une tâche part dès la fin du tour en cours,
       comme son propre tour, dans l'ordre — jamais fusionné avec les autres,
       jamais en run concurrent (le moteur sérialise le fil, P-CTX-2). */
    s.steerNow = async () => {
      /* V4-D (24/10) — LIVE STEER : un ajout écrit pendant un run part au moteur
         (POST /api/chat/steer {conv, text}) ; Agent.run l'injecte dans le tour EN
         COURS à la fin de l'étape d'outil, sans redémarrer (événement « steer »).
         Repli inchangé (DIAG2-CONTEXTE P-CTX-3) si la route manque (404), si le
         moteur répond qu'aucun run ne tourne (409), ou pour un ajout avec pièce
         jointe ou citation : il reste en file et partira comme son propre tour. */
      if (dead || s.dead || !s.running || s.queuePaused || !s.queue.length || s._steering) return;
      s._steering = true;
      try {
        if (s.cid && s.steerRoute !== false) {
          const sendable = s.queue.filter((it) => !(it.atts && it.atts.length) && !(it.images && it.images.length) && !it.screenNote && !it.quote && !it.steerTried && String(it.text || "").trim());
          for (const it of sendable) {
            if (dead || s.dead || !s.running) break;
            it.steerTried = true;
            try {
              const j = await api.post("/api/chat/steer", { conv: s.cid, conversation_id: s.cid, text: String(it.text) }, 8000);
              if (j && j.ok === true && j.queued === true) {
                s.steerRoute = true;
                const k = s.queue.indexOf(it); if (k >= 0) s.queue.splice(k, 1);
                if (it.bubble) { it.bubble.classList.remove("cs-queued"); it.bubble.classList.add("cs-steered"); it.bubble.style.opacity = ""; }
                s.steered.push(it);
              }
            } catch (e) {
              if (e && e.status === 404) { s.steerRoute = false; break; }   // moteur sans la route : repli complet
            }
          }
          s.paintQueue();
          if (!s.queue.length) return;
        }
        let fresh = 0;
        for (const it of s.queue) { if (it.bubble) { it.bubble.classList.remove("cs-queued"); it.bubble.classList.add("cs-steered"); } if (!it.steerNoted) { it.steerNoted = true; fresh++; } }
        if (fresh) s.notice("Ajout(s) en file — ils partiront un par un dès la fin du tour en cours, dans l'ordre écrit.");
      } finally { s._steering = false; }
    };
    /* V4-D : rendu des événements Live Steer du moteur. */
    s.onSteerApplied = (d) => {
      const t = String((d && d.text) || "");
      const k = s.steered.findIndex((it) => String(it.text) === t);
      const it = k >= 0 ? s.steered.splice(k, 1)[0] : null;
      if (it && it.bubble) it.bubble.title = "Précision prise en compte en cours de route";
      try { (s._steerShown = s._steerShown || []).push(t); } catch (e) {}   // 24/10 : réaffichée si le rechargement de fin de run précède l'écriture du grand livre
      s.notice("Précision prise en compte en cours de route : « " + trunc(t, 120) + " »");
    };
    s.onSteerUnused = (d) => {
      const texts = Array.isArray(d && d.texts) ? d.texts.map(String) : [];
      let back = 0;
      for (const t of texts) {
        const k = s.steered.findIndex((it) => String(it.text) === t);
        const it = k >= 0 ? s.steered.splice(k, 1)[0] : { text: t, atts: [], voice: s.voiceMode, bubble: null, quote: "" };
        it.steerTried = true;
        if (it.bubble) { it.bubble.classList.remove("cs-steered"); it.bubble.classList.add("cs-queued"); }
        s.queue.push(it); back++;
      }
      if (back) { s.paintQueue(); s.notice(back + " précision(s) arrivée(s) après la dernière étape : elle(s) part(ent) comme message dès la fin du tour."); }
    };
    s.sendNow = async (text, displayText) => {
      try { if (s.channel && s.channel !== "tous" && chanBar.style.display !== "none") s.setChannel("tous"); } catch (e) {}   // V4-D : écrire dans le Fil direct rend le fil complet (ta bulle n'est jamais masquée par un filtre)
      let atts = [];
      if (att.count()) {
        s.attSending = true; paintSendBtn();
        try { await att.uploadPending(); atts = att.take(); }
        catch (e) {
          s.attSending = false; paintSendBtn();
          if (!input.value) input.value = text;
          ctx.toast("Pièce jointe : " + String((e && e.message) || e), true);
          return;
        }
        s.attSending = false; paintSendBtn();
      }
      s.used = true;
      const qPrefix = s.pendingQuote ? "↩ « " + s.pendingQuote.replace(/\s*\n+\s*/g, " ") + " »\n" : "";
      const ub = s.bubble("user", qPrefix + text, atts);
      s.setAck(ub);   // §42 : accusé de réception immédiat sur SA bulle
      s.pendingUserBubble = ub;   // HORODATAGE : tamponnée au « meta » du run, avec le ts stocké renvoyé par le moteur
      let engineText = text + (atts.length ? (text ? "\n\n" : "") + describeForBrain(atts) : "");
      if (s.pendingQuote) {   // §42 : relance ciblée sur une réponse précise
        engineText = "[RELANCE — l'utilisateur répond à CE message précis de Nova : « " + s.pendingQuote + " » — ta réponse doit porter sur ce message-là]\n" + engineText;
        s.pendingQuote = ""; paintQuoteBar();
      }
      const scn = s.takeScreen();   // V4-D : capture d'écran en attente → note OCR + image pour [tiers]
      if (scn.note) engineText += "\n\n" + scn.note;
      s.runAgent(engineText, qPrefix + (displayText || text), { voice: s.voiceMode, images: visionImages(atts).concat(scn.images) });
    };
    s.runAgent = async (text, displayText, opts) => {
      const wantVoice = !!(opts && opts.voice);
      const my = ++s.runToken;
      s.setRunning(true);
      s.stepRows.clear(); traceBox.replaceChildren();
      s.detailCount = 0;
      routineBar.style.display = "none";
      s.lastTask = String(displayText || text);
      if (!s.cid) { try { s.titleFull = String(s.lastTask || ""); let _ct = cleanResume(s.lastTask || ""); let _prev = ""; while (_ct !== _prev) { _prev = _ct; _ct = _ct.replace(/^\[[^\]]{1,80}\]\s*/, ""); } s.title = trunc(_ct, 42) || s.title; } catch (e) { s.title = trunc(s.lastTask, 42) || s.title; } }
      s.runStats = { t0: Date.now(), steps: 0, tokens: 0, tripped: false };
      s._runT0 = performance.now(); s._ttftMs = 0;   // LATENCE RÉELLE (27/10) : départ du chronomètre client, premier mot au premier « delta »
      s.runUsage = null;   // MN2-6 : cumul RÉEL des événements usage du run ; null = aucun compteur reçu = « inconnu », jamais 0
      s.budgetTimer = setInterval(s.budgetCheck, 4000);
      s.touch();
      try { localStorage.setItem(RUN_KEY, JSON.stringify({ status: "running", at: Date.now(), text: trunc(s.lastTask, 120), cid: s.cid })); } catch (e) {}
      let novaBubble = null, acc = "", gotDelta = false, sawDone = false;
      const narr = createNarr();
      /* 25/10 (Ahadi : « décalage entre la voix et le texte, retard manifeste ») — la voix suit le texte EN DIRECT :
         première phrase dite dès qu'elle est complète, puis phrase après phrase (file séquentielle, speak() attend
         la fin de la lecture). Format bi-canal <PARLE> : lu en entier à la fin, comme avant. Plafond 1 500 car. */
      const vq = { said: 0, chars: 0, items: [], busy: false, bic: false };
      const vPump = async () => {
        if (vq.busy) return; vq.busy = true;
        try { while (vq.items.length) { if (dead || !s.voiceMode) { vq.items.length = 0; break; } const t = vq.items.shift(); try { await getVoice().speak(t); } catch (e) { break; } } }
        finally { vq.busy = false; }
      };
      const vFeed = (final) => {
        if (!wantVoice || dead || !s.voiceMode || s !== activeSession() || vq.chars > 1500) return;
        if (/<PARLE>/i.test(acc)) { vq.bic = true; return; }
        const rest = acc.slice(vq.said);
        let cut = -1;
        if (final) cut = rest.length;
        else { const re = /[.!?…](\s|$)/g; let m; while ((m = re.exec(rest))) cut = m.index + 1; if (cut < (vq.said ? 220 : 25)) cut = -1; }
        if (cut <= 0) return;
        const chunk = speakable(rest.slice(0, cut)).trim();
        vq.said += cut;
        if (chunk) { vq.chars += chunk.length; vq.items.push(chunk); vPump(); }
      };
      s.abortCtl = new AbortController();
      const body = { text, autonomie: s.autonomie, tools: true, ecran: "Conversations", ...depthBody(s.depth) };
      if (wantVoice) body.voice = true;
      if (s.cid) body.conversation_id = s.cid;
      if (brainSel.value) body.brain = brainSel.value;
      if (s.incognito) body.incognito = true;   // MÉMOIRE SOUVERAINE : posé aussi sur un fil encore sans id
      if (opts && Array.isArray(opts.images) && opts.images.length) body.images = opts.images.slice(0, 5);   // V4-D : VISION — pièces jointes image + capture du Témoin
      s.lastProv = null;
      try {
        await sse("/api/chat", body, (type, d) => {
          if (dead || s.dead || my !== s.runToken) return;
          d = d || {};
          /* §42 : l'accusé passe en « en cours » au premier signe du moteur. */
          if (s.ackEl && !s.ackEl.dataset.seen) { s.ackEl.dataset.seen = "1"; s.ackEl.textContent = "Nova s'en occupe…"; }
          /* §46 : la présence du rail (panda + ligne d'activité) suit le run en direct. */
          try { const P = window.__novaPresence; if (P) { if (type === "tool") P("tool", String(d.name || "outil en cours")); else if (type === "step") P("reflexion", String(d.label || "Étape en cours…")); else if (type === "error") P("error", "Erreur de l'agent"); else if (type === "done") P("done", "✅ Terminé : " + trunc(s.lastTask || "tâche", 44)); else if (type === "delta" || type === "meta" || type === "brain") P("reflexion", "Nova réfléchit…"); } } catch (e) {}
          if (type === "meta") {
            s.greetAllowed = !(d && d.greet === false);   // 25/10 : le moteur dit si une salutation est attendue à ce tour
            if (d.conversation_id) {
              const adoptedCid = String(d.conversation_id);
              const isNew = !s.cid;
              const adopted = s.cid !== adoptedCid;
              if (adopted && s.cid && sessionsByCid.get(s.cid) === s) sessionsByCid.delete(s.cid);   // FIX-RENDU ① : une adoption ne laisse pas l'ancien id pointer sur cette session (sessionsByCid.set écrasait sans fusionner)
              s.cid = adoptedCid;
              if (adopted) { s.historyLoaded = false; s.historyReloadNeeded = false; }   // FIX-RENDU ① : le journal visible ne contient que le run en direct — l'historique du fil adopté reste À CHARGER ; le chargement partira en fin de run (bloc finally de runAgent) ou à la prochaine activation, via ensureHistory. Jamais ici : loadConversation REMPLACE le journal, il effacerait le flux en cours.
              if (isNew || adopted) { sessionsByCid.set(s.cid, s); }
              if (isNew || adopted) { try { if (activeSession() === s) reportActive(); } catch (e) {} }
              saveOpen(); s.renderHead(); renderList();
            }
            if (d.user_ts && s.pendingUserBubble) {   // HORODATAGE : le moteur a stocké le message d'Ahadi avant le flux — son ts arrive avec le meta
              if (!sameDay(prevStampedTs(log, s.pendingUserBubble), d.user_ts)) { const sep = daySepEl(d.user_ts); if (sep) s.pendingUserBubble.before(sep); }
              stampMsgTime(s.pendingUserBubble, d.user_ts);
            }
          }
          else if (type === "brain") { showBrain(d.label || d.id, d.id); s.notice("Cerveau : " + (d.label || d.id || "")); }
          else if (type === "brain_rejected") { s.notice("Cerveau choisi non utilisé : " + (d.label || d.id || "") + " — " + (d.reason || "indisponible") + ". La chaîne automatique répond à la place.", "warn"); }   // DIAG2-CERVEAUX : émis par le moteur (P-CERV-3 H5) quand le cerveau nommé est inconnu ou sans clé — jamais de remplacement silencieux
          else if (type === "step") {
            if (d.state === "run" && d.beat == null) narr.boundary();
            s.stepRow(d); if (s.runStats) { s.runStats.steps = s.stepRows.size; s.budgetCheck(); }
            try { if (d.state === "run" && d.beat == null && s.voiceMode && s === activeSession() && !s._vxFiller) { s._vxFiller = true; const vv = getVoice(); if (vv && vv.speakFiller) vv.speakFiller(d.tool); } } catch (e) {}
            /* DIAG2-FLUX P5 : le fil lui-même montre l'étape en cours (avant : Détails seulement,
               donc un fil figé pendant tout le travail). Ligne transitoire unique, mise à jour
               en place, retirée au done/error. Les étapes « confirm » gardent leur carte dédiée. */
            if (d.state === "run" || d.state === "err") {
              if (!s.threadStep) { s.threadStep = h("div", { class: "ss nova-step-line" }); log.append(s.threadStep); }
              s.threadStep.textContent = d.beat != null
                ? String(d.tool || "étape") + " — toujours en cours · " + d.beat + " s"
                : d.state === "err" ? String(d.tool || "étape") + " — en erreur" + (d.arg ? " — " + trunc(d.arg, 90) : "") : String(d.tool || "étape") + (d.arg ? " — " + trunc(d.arg, 90) : "");
              log.scrollTop = log.scrollHeight;
            }
          }
          else if (type === "confirm") {
            if (d.resolved) { const c = s.confirmCards.get(d.id); if (c) c._resolve(!!d.ok); s.confirmCards.delete(d.id); }
            else { s.confirmCards.set(d.id, s.confirmCard(d)); }
          }
          else if (type === "tool") {
            narr.boundary();
            const card = h("div", { class: "tool-card" },
              h("div", { class: "tt" }, "Outil : " + String(d.name || "")),
              d.input ? h("div", { class: "appr-cmd" }, trunc(d.input, 300)) : null,
              d.output ? h("div", { class: "ss", style: "white-space:pre-wrap" }, trunc(d.output, 600)) : null);
            metaFlow.append(card); metaFlow.scrollTop = metaFlow.scrollHeight;
            s.bumpDetail();
          }
          else if (type === "failover") { s.notice("Bascule de cerveau : " + (d.from || "?") + " → " + (d.to || "?") + (d.reason ? " (" + d.reason + ")" : ""), "warn"); }
          else if (type === "retry") { s.notice("Nouvelle tentative : " + (d.reason || ""), "warn"); }
          else if (type === "usage") { if (!s.runUsage) s.runUsage = { in: 0, out: 0 }; s.runUsage.in += Number(d.in) || 0; s.runUsage.out += Number(d.out) || 0; s.usageText = "Jetons : ~" + fmtNumFR(s.runUsage.in + s.runUsage.out) + " (" + fmtNumFR(s.runUsage.in) + " entrants · " + fmtNumFR(s.runUsage.out) + " sortants)"; s.renderHead(); if (s.runStats) { s.runStats.tokens += (Number(d.in) || 0) + (Number(d.out) || 0); s.budgetCheck(); } }
          else if (type === "memory") { s.lastProv = d; if (sawDone && novaBubble) s.renderProv(novaBubble, d); }   // MÉMOIRE SOUVERAINE : provenance (avant « done » ; repli après)
          else if (type === "final") { const ft = String((d && d.t) || ""); if (ft && novaBubble) { acc = ft; novaBubble.innerHTML = md(normalizeAnswer(acc)); try { s.decorateNovaBubble(novaBubble, acc); } catch (e) {} } }   // 29/10 : version finie du moteur (BLUF en tête, sans annonces d'étape)
          else if (type === "reset") { acc = narr.reset(); vq.said = 0; vq.items.length = 0; if (novaBubble) novaBubble.textContent = ""; }   // 24/10 : la tentative remplacée par le routeur quitte l'écran (fini les réponses soudées)
          else if (type === "delta") {
            /* LATENCE RÉELLE (27/10) : premier mot mesuré ici, à l'arrivée du premier
               fragment — pas la pseudo-latence dérivée des horodatages stockés. */
            if (!s._ttftMs) s._ttftMs = Math.round(performance.now() - (s._runT0 || performance.now()));
            gotDelta = true;
            if (!novaBubble) { novaBubble = s.bubble("nova", ""); novaBubble.textContent = ""; s.bindMsgMenu(novaBubble, () => acc); }
            acc = narr.delta(d.t || ""); novaBubble.textContent = acc; vFeed(false); if (novaBubble._paintRx) novaBubble._paintRx(); log.scrollTop = log.scrollHeight;
          }
          else if (type === "error") {
            if (s.threadStep) { s.threadStep.remove(); s.threadStep = null; }   // DIAG2-FLUX P5 (symétrique du done) : la ligne d'étape transitoire ne survit pas à l'erreur
            const eb = errCard("L'agent a rencontré une erreur", String(d.message || "Erreur inconnue"),
              "La conversation est conservée côté moteur : « Reprendre » relance l'agent là où il s'était arrêté.",
              h("button", { class: "btn sm acc", onclick: () => { if (!s.running) s.runAgent("Reprends là où tu t'étais arrêté et termine la tâche initiale.", "Reprendre la tâche", {}); } }, "Reprendre"));
            log.append(eb); log.scrollTop = log.scrollHeight;
          }
          else if (type === "stamp") {
            /* HORODATAGE : le moteur a écrit la réponse finale (checkpoint) et
               renvoie les ts STOCKÉS — on tamponne la bulle de Nova (celle
               d'Ahadi l'a été au « meta » ; repli ici si elle l'a manqué).
               Aucun ts → rien ne s'affiche, jamais d'heure inventée. */
            if (novaBubble && d.assistant_ts) {
              if (!sameDay(prevStampedTs(log, novaBubble), d.assistant_ts)) { const sep = daySepEl(d.assistant_ts); if (sep) novaBubble.before(sep); }
              stampMsgTime(novaBubble, d.assistant_ts);
            }
            if (s.pendingUserBubble && d.user_ts && !s.pendingUserBubble.dataset.ts) stampMsgTime(s.pendingUserBubble, d.user_ts);
          }
          else if (type === "done") {
            sawDone = true;
            if (gotDelta) { acc = narr.final(); if (novaBubble) novaBubble.textContent = acc; }
            if (d.label) showBrain(d.label, d.id);
            /* DIAG2-FLUX P5 : fin SANS réponse exploitable (réessais épuisés, .done vide du moteur) —
               avant : « ✅ » + barre « Cette tâche a abouti » pour un run qui n'a rien produit
               (21/10 17:04). La fin vide se nomme dans le fil et ne reçoit ni ✅ ni barre d'abouti. */
            const emptyRun = !acc.trim() && !novaBubble;
            if (s.threadStep) { s.threadStep.remove(); s.threadStep = null; }
            if (emptyRun) {
              const eb = errCard("Le run s'est terminé sans réponse", "",
                "Aucun texte, aucun résultat d'outil : rien n'a été exécuté. Les étapes et réessais du run sont dans Détails.",
                h("button", { class: "btn sm acc", onclick: () => { if (!s.running) s.runAgent(s.lastTask, s.lastTask, {}); } }, "Relancer la demande"));
              log.append(eb); log.scrollTop = log.scrollHeight;
            }
            if (!s.runUsage) { s.usageText = "Jetons : inconnus (le fournisseur n'a pas renvoyé de compteur)"; s.renderHead(); }   // MN2-6 : jamais un faux 0
            // MN2-8 : badge PAR RÉPONSE, alimenté par le « done » du moteur = le cerveau qui a
            // RÉELLEMENT produit cette réponse (bascule comprise) — jamais le choix du sélecteur.
            if (novaBubble && d.label) { const bd = h("div", { class: "ss brain-badge" }, h("span", { html: ic("brain", 12) }), " " + String(d.label) + (d.light ? " · réponse légère" : "")); novaBubble.after(bd); }
            /* LATENCE RÉELLE (27/10) : chiffres du MOTEUR pour ce tour (ttft_ms/total_ms
               de l'événement done), repli sur le chronomètre client — remplace la
               métrique dérivée des cartes (jusqu'à ~10 h, sans signification). */
            if (novaBubble && (d.ttft_ms > 0 || s._ttftMs)) { const ttft = d.ttft_ms > 0 ? d.ttft_ms : s._ttftMs; const total = d.total_ms > 0 ? d.total_ms : Math.round(performance.now() - (s._runT0 || performance.now())); const lat = h("div", { class: "ss lat-badge" }, "Premier mot : " + (ttft / 1000).toFixed(1) + " s · Réponse complète : " + (total / 1000).toFixed(1) + " s" + (typeof d.cout_usd === "number" ? " · Coût : " + (d.cout_usd < 0.01 ? "< 0,01" : d.cout_usd.toFixed(2).replace(".", ",")) + " $" : "") + " (mesuré sur ce tour)"); const anchor = novaBubble.nextElementSibling && novaBubble.nextElementSibling.classList.contains("brain-badge") ? novaBubble.nextElementSibling : novaBubble; anchor.after(lat); }
            /* 25/10 (Ahadi : « Bonsoir Ahadi » à chaque réponse) — filet : si le moteur a dit « pas de salutation »
               et que le cerveau salue quand même, la formule d'ouverture est retirée de la réponse affichée. */
            if (acc && s.greetAllowed === false) { const g = acc.replace(/^\s*(?:bonjour|bonsoir|bon après-midi|salut|hello)(?:\s+ahadi)?\s*(?:👋)?\s*[.!,]?\s*/iu, ""); if (g.trim() && g !== acc) acc = g.charAt(0).toUpperCase() + g.slice(1); }
            if (novaBubble && acc) { novaBubble.innerHTML = md(normalizeAnswer(acc)); s.decorateNovaBubble(novaBubble, acc); }   // §42 : réactions + relances sur la réponse
            if (novaBubble && s.lastProv) s.renderProv(novaBubble, s.lastProv);   // MÉMOIRE SOUVERAINE : « N souvenirs utilisés »
            if (s.ackEl) { const a = s.ackEl; s.ackEl = null; const _t = (() => { try { const _ts = s.ackBubble && s.ackBubble.dataset && s.ackBubble.dataset.ts; const _lb = _ts ? msgTimeLabel(_ts) : ""; return _lb; } catch (e) { return ""; } })(); a.innerHTML = (emptyRun ? ic("alert", 13) : "✅") + (_t ? " " + _t : ""); setTimeout(() => { try { a.remove(); } catch (e) {} }, 1600); }   // DIAG2-FLUX P5 : pas de ✅ pour un run vide
            try { localStorage.setItem(RUN_KEY, JSON.stringify({ status: "terminée", at: Date.now(), finishedAt: Date.now(), text: trunc(s.lastTask, 120), cid: s.cid })); } catch (e) {}
            if (s !== activeSession()) { s.unseen = true; }
            /* 28/10 (Ahadi) : tâche finie pendant qu'il est ailleurs -> badge du rail +
               notification macOS cliquable (le compagnon reçoit déjà « done » via présence). */
            if (!emptyRun && acc && (s !== activeSession() || document.hidden)) {
              try {
                const K = "nova2_unseen_done_v1";
                const st8 = JSON.parse(localStorage.getItem(K) || "{}") || {};
                st8[String(s.cid || "local")] = Date.now();
                localStorage.setItem(K, JSON.stringify(st8));
                ctx.bus.emit("nova:unseen-done", { cid: s.cid });
              } catch (e) {}
              /* 01/11 : la notification macOS part désormais du MOTEUR à la fin du tour (NovaNotifier+Attention.swift :
                 fenêtre inactive OU autre conversation affichée, tour ≥ 8 s, heures calmes, débit) — plus d'appel
                 /api/notify/taskdone d'ici, qui ratait le cas « Nova en arrière-plan sur la conversation ouverte ». */
            }
            if (watchMode) { ctx.toast("Watch : tâche terminée — « " + trunc(s.lastTask, 60) + " »"); audit("watch", "Tâche terminée : " + s.lastTask, "notification Watch"); }
            if (s.lastTask && !emptyRun) {   // DIAG2-FLUX P5 : « a abouti » seulement si le run a produit une réponse
              routineBar.replaceChildren(
                h("span", { class: "ss", style: "color:var(--ink-2)" }, "Cette tâche a abouti. "),
                h("button", { class: "btn", onclick: () => s.saveAsRoutine() }, h("span", { html: ic("zap", 15) }), " Sauver comme routine"));
              routineBar.style.display = "";
            }
            if (wantVoice && acc) { if (vq.bic || vq.said === 0) speakAnswer(s, acc); else vFeed(true); }   /* 25/10 : reste de la réponse, à la suite */
            s.touch();
          }
          /* §34 : point de pilotage — une étape vient de se terminer,
             un ajout en attente part tout de suite au moteur. */
          else if (type === "vision") { if (d.ok) s.notice("Vision : " + (Number(d.sent) || 0) + " image(s) transmise(s) à " + String(d.brain || "le cerveau") + (Array.isArray(d.refused) && d.refused.length ? " · refusée(s) : " + d.refused.join(" ; ") : "")); else s.notice("Vision : " + String(d.reason || "image non transmise") + (Array.isArray(d.refused) && d.refused.length ? " · " + d.refused.join(" ; ") : ""), "warn"); }   // V4-D : refus honnête si le cerveau n'est pas multimodal
          else if (type === "steer") { s.onSteerApplied(d); }   // V4-D : LIVE STEER — précision injectée par le moteur dans le tour en cours
          else if (type === "steer_unused") { s.onSteerUnused(d); }   // V4-D : arrivée(s) après la dernière étape — repassent en file
          if ((type === "tool" || type === "step") && s.queue.length && !s.queuePaused) s.steerNow();
        }, s.abortCtl.signal);
      } catch (e) {
        if (!dead && !s.dead && my === s.runToken && s.abortCtl && !s.abortCtl.signal.aborted) {
          s.notice("Connexion au moteur interrompue (" + ((e && e.message) || e) + "). La conversation reste ouverte côté moteur — renvoie un message pour reprendre.", "warn");
        }
      }
      if (!dead && !s.dead && my === s.runToken) { s.setRunning(false); s.touch(); loadHistory(); loadAudit(); if (s.ensureHistory) s.ensureHistory(); s.drainQueue(); try { flushDirectMirrorQueue(s); } catch (e) {} }   // FIX-RENDU ① : fin de run = premier moment sûr pour charger l'historique d'une session adoptée (le flux est clos ; le chargement remplace le journal par le fil moteur complet, échange du run compris — aucun double rendu). Si une file repart, ensureHistory s'abstient et drainQueue enchaîne. MIROIR DIRECT → ACTIVE : vidange de l'attente de la session qui vient de finir (garde running/historyLoading interne).
    };
    s.saveAsRoutine = async () => {
      if (!s.lastTask) return;
      const id = "perso-agent-" + Date.now().toString(36);
      const name = trunc(s.lastTask.replace(/\s*\n[\s\S]*$/, ""), 48) || "Routine de l'agent";
      try {
        const j = await api.post("/api/dots/save", { id, name, color: "#FF7A29", role: "Routine personnelle (depuis l'agent)", tools: [], brain: brainSel.value || "", schedule: "", prompt: s.lastTask, paused: true, quiet_ok: true });
        if (j && j.error) throw new Error(j.error);
        ctx.toast("Routine « " + name + " » créée EN PAUSE — active-la et donne-lui un horaire dans Automatisations.");
        audit("routine", "Tâche sauvée comme routine : " + name, "créée en pause, sans horaire");
        routineBar.style.display = "none";
      } catch (e) { ctx.toast("Création de la routine impossible : " + ((e && e.message) || e), true); }
    };
    s.loadConversation = async (id) => {
      id = String(id || "");
      if (!id) return;
      if (s.historyLoading) { s.historyReloadNeeded = true; return; }   // FIX-RENDU ① : un appel pendant un chargement en cours ne double pas le rendu — il demande UN rejeu à la fin (le fetch en vol peut précéder le dernier événement matérialisé)
      const sameCid = s.cid === id;
      if (!sameCid) s.historyLoaded = false;
      s.historyLoading = true;
      try {
        const j = await api.get("/api/conversation?id=" + encodeURIComponent(id), 60000);
        if (!j || !Array.isArray(j.messages)) throw new Error("réponse du moteur sans messages");
        if (dead || s.dead) { s.historyLoading = false; return; }
        s.cid = id;
        sessionsByCid.set(id, s);
        /* PILOTAGE 01/11 : un fil ouvert par son id n'avait pas de cid au moment d'activate() — « nova:conv-active » partait vide
           et ni le shell ni le pilotage (conv-ouvrir) ne savaient quel fil était affiché. Signalé ici, une fois l'id adopté. */
        if (!sameCid) { try { if (activeSession() === s) bus.emit("nova:conv-active", { cid: id }); } catch (e) {} }
        const meta = convIndex.get(id);
        /* Point 2 du diagnostic : une session qui adopte un fil existant reprend son
           « updated » stocké comme activité — « maintenant » seulement pour un brouillon. */
        if (meta && meta.updated) { s.lastActivity = meta.updated; s._adoptedUpdated = meta.updated; }
        s.title = (meta && meta.title) || s.title;
        try { s.incognito = !!(j && j.incognito); s.paintIncognito(); } catch (e2) {}   // MÉMOIRE SOUVERAINE : état « Hors mémoire » du fil
        try { s.renderedUpdated = (meta && meta.updated) || 0; } catch (e2) {}
        s.used = true;
        s.stepRows.clear(); traceBox.replaceChildren(h("div", { class: "empty" }, "Conversation reprise — la trace repartira à la prochaine tâche."));
        metaFlow.replaceChildren();
        log.replaceChildren();
        const msgs = arrOf(j, "messages");
        /* FIX-RENDU ③ : le plafond slice(-30) DISPARAÎT — il rendait invisibles
           à l'ouverture 50 des 80 messages du Fil direct (forensique §2.4), et
           le summary moteur ne les absorbait que pour le cerveau, pas pour
           l'œil. On rend TOUT le fil jusqu'à HISTORY_RENDER_MAX ; au-delà, les
           plus récents seulement, annoncés dans le fil. */
        const shownMsgs = msgs.length > HISTORY_RENDER_MAX ? msgs.slice(-HISTORY_RENDER_MAX) : msgs;
        if (shownMsgs.length < msgs.length) log.append(h("div", { class: "ss" }, "Historique très long : seuls les " + HISTORY_RENDER_MAX + " derniers messages sont affichés (" + msgs.length + " au total dans ce fil)."));
        /* 27/10 (Ahadi) : BRUIT DIRECT — dans le Fil direct, les cartes de statut/réunion
           (rôle event) se SÉPARENT des échanges : puces Tout / Échanges / Cartes.
           Le filtre agit au rendu du fil ; les données ne bougent pas. */
        const isDirThread = s.cid && directSync().cid === s.cid;
        if (isDirThread) {
          const cur = s._directFilter || "tout";
          const chips = h("div", { class: "direct-filter", role: "group", "aria-label": "Filtrer le Fil direct" });
          for (const [k, lab] of [["tout", "Tout"], ["echanges", "Échanges"], ["cartes", "Cartes de statut"]]) {
            const b = h("button", { class: "df-chip" + (cur === k ? " on" : "") }, lab);
            b.addEventListener("click", () => { if (s._directFilter !== k) { s._directFilter = k; s.loadConversation(s.cid); } });
            chips.append(b);
          }
          log.append(chips);
        }
        /* 27/10 (Ahadi : « ça se fige quand je clique le Fil direct ») : rendu par FENÊTRE.
           On ne peint que les 60 derniers messages ; les précédents arrivent par pas de 60
           via le bouton en tête de fil, sans repeindre l'existant (ancrage de défilement
           conservé). Avant : tout le fil (des centaines de cartes) en un seul passage. */
        const WIN = 60;
        const paintRange = (arr, target) => {
          let prevTs = null, lastNovaEl = null, lastHadSteer = false;
          for (const m of arr) {
            if (isDirThread && s._directFilter === "echanges" && m.role === "event") continue;
            if (isDirThread && s._directFilter === "cartes" && m.role !== "event") continue;
            /* Un message au rendu difficile ne doit jamais vider tout le fil :
               repli texte brut pour CE message, les autres continuent. */
            try {
              if (m.ts && !sameDay(prevTs, m.ts)) { const sep = daySepEl(m.ts); if (sep) target.append(sep); }
              if (m.role === "user") s.bubble("user", String(m.content || ""), null, m.ts);
              else if (m.role === "event") s.directEvent(m);   // BUILD-FEED-DIRECT vague 2 : message du Fil direct, même famille que les réponses (plus de carte)
              else if (m.role === "assistant") { lastHadSteer = false; try { for (const tl of (Array.isArray(m.tools) ? m.tools : [])) { if (tl && tl.tool === "precision_ahadi" && tl.arg) { lastHadSteer = true; const pb = s.bubble("user", "↳ " + String(tl.arg), null, m.ts); if (pb) pb.classList.add("cs-steered"); } } } catch (e) {} const bb = s.bubble("nova", String(m.content || ""), null, m.ts); lastNovaEl = bb; s.decorateNovaBubble(bb, String(m.content || "")); if (m.memory) s.renderProv(bb, m.memory); }   // §42 : l'historique aussi a ses réactions/relances — MÉMOIRE SOUVERAINE : + provenance persistée
            } catch (e) {
              s._renderErrors = (s._renderErrors || 0) + 1;
              try { target.append(h("div", { class: "msg " + (m.role === "user" ? "me" : "nova") }, String(m.content || ""))); } catch (e2) {}
            }
            if (m.ts) prevTs = m.ts;
          }
          return { lastNovaEl, lastHadSteer, prevTs };
        };
        /* s.bubble/directEvent ajoutent au log de la session : pour peindre un fragment
           détaché, on redirige temporairement la cible via s._paintTarget si le moteur le
           permet — repli : peindre dans le log puis déplacer les nœuds créés. */
        const paintInto = (arr, frag) => {
          const before = new Set(log.childNodes);
          const r = paintRange(arr, log);
          const made = [...log.childNodes].filter((n) => !before.has(n));
          for (const n of made) frag.append(n);
          return r;
        };
        let from = Math.max(0, shownMsgs.length - WIN);
        s._histFrom = from; s._histMsgs = shownMsgs;
        if (from > 0) {
          /* Repère explicite (retour Ahadi : « le contenu a disparu ») : la fenêtre de 60
             est un choix d'affichage, les messages existent — et le haut du fil les
             recharge tout seul au défilement. */
          log.append(h("div", { class: "ss hist-note" }, "Affichage des " + WIN + " derniers messages sur " + shownMsgs.length + " — les précédents se chargent en remontant le fil, ou par le bouton ci-dessous."));
          const moreBtn = h("button", { class: "btn sm hist-more" }, "Afficher les précédents (" + from + " plus anciens)");
          moreBtn.addEventListener("click", () => {
            const nf = Math.max(0, s._histFrom - WIN);
            const slice = s._histMsgs.slice(nf, s._histFrom);
            const firstDayBefore = s._histMsgs[s._histFrom] && s._histMsgs[s._histFrom].ts ? new Date(s._histMsgs[s._histFrom].ts).toDateString() : "";
            const frag = document.createDocumentFragment();
            paintInto(slice, frag);
            const h0 = log.scrollHeight, y0 = log.scrollTop;
            const seamSep = moreBtn.nextElementSibling;   // séparateur de tête du bloc déjà peint
            log.insertBefore(frag, moreBtn.nextSibling);
            /* Jour identique de part et d'autre de la couture : le séparateur en double part. */
            const lastSlice = slice[slice.length - 1];
            if (seamSep && seamSep.classList && seamSep.classList.contains("day-sep")
                && lastSlice && lastSlice.ts && new Date(lastSlice.ts).toDateString() === firstDayBefore) seamSep.remove();
            log.scrollTop = y0 + (log.scrollHeight - h0);
            s._histFrom = nf;
            if (nf <= 0) moreBtn.remove(); else moreBtn.textContent = "Afficher les précédents (" + nf + " plus anciens)";
          });
          log.append(moreBtn);
          s._histMoreBtn = moreBtn;
          /* Remonter le fil charge les précédents tout seul (une fois par arrivée en haut). */
          if (!s._histScrollBound) {
            s._histScrollBound = true;
            log.addEventListener("scroll", () => {
              if (log.scrollTop < 90 && s._histMoreBtn && s._histFrom > 0 && !s._histLoadingMore) {
                s._histLoadingMore = true;
                try { s._histMoreBtn.click(); } catch (e) {}
                setTimeout(() => { s._histLoadingMore = false; }, 400);
              }
            }, { passive: true });
          }
        }
        s._renderErrors = 0;
        const painted = paintRange(shownMsgs.slice(from), log);
        if (s._renderErrors) s.notice(s._renderErrors + " message(s) affiché(s) en texte simple : leur mise en forme riche a échoué, le contenu est là.", "warn");
        let lastNovaEl = painted.lastNovaEl, lastHadSteer = painted.lastHadSteer;
        /* 24/10 : le rechargement de fin de run peut lire la réponse AVANT que le moteur y écrive son grand livre :
           les précisions Live Steer de ce run sont alors reposées juste avant la dernière réponse. */
        try {
          if (s._steerShown && s._steerShown.length && !lastHadSteer && lastNovaEl) {
            let anchor = lastNovaEl; while (anchor.previousElementSibling && anchor.previousElementSibling.classList.contains("msg-head")) anchor = anchor.previousElementSibling;
            for (const t of s._steerShown) { const pb = s.bubble("user", "↳ " + t); if (pb) { pb.classList.add("cs-steered"); const head = pb.previousElementSibling && pb.previousElementSibling.classList.contains("msg-head") ? pb.previousElementSibling : null; if (head) log.insertBefore(head, anchor); log.insertBefore(pb, anchor); } }
          }
          s._steerShown = [];
        } catch (e) {}
        /* FD (23/10) : empreintes du rendu — fdAppendLive ne descendra en
           incrémental que si le fil relu commence exactement par ces
           messages (même ordre, même contenu) ; tout écart rejoue le
           chargement complet. */
        s._fdSigs = shownMsgs.map(fdMsgSig);
        s._fdTotal = msgs.length;
        s._fdLastTs = painted.prevTs;
        try { s.paintChannelBar(); s.applyChannel(); } catch (e) {}   // V4-D : filtre de canal réappliqué au fil rejoué
        s.historyLoaded = true;   // FIX-RENDU ① : fetch réussi + historique rendu (borne ③ comprise) — cette session n'est plus une coquille adoptée
        if (!msgs.length) s.notice("Conversation vide.");
        /* TITRES (27/10, point 4) : fini les titres gelés aux 48 premiers caractères et
           les « J » / « N » / « h » illisibles. Si le titre stocké est minuscule (≤ 3 car.)
           ou n'est que le préfixe du premier message, on re-titre UNE fois depuis le
           premier message substantiel du fil (ni salut, ni commande d'appel), via la
           route de renommage existante. Jamais le Fil direct. */
        try {
          if (!s._retitled && !isDirThread) {
            const curT = String(((convIndex.get(id) || {}).title || s.title || "")).trim();
            const users = msgs.filter((m) => m.role === "user").map((m) => String(m.content || "").trim());
            const first = users[0] || "";
            const subst = users.find((t) => t.length >= 12 && !/^(salut|bonjour|bonsoir|hello|ok|oui|non|merci|test)\b/i.test(t)) || "";
            const autoPrefix = !!first && !!curT && first.replace(/\s+/g, " ").startsWith(curT.replace(/…$/, "").replace(/\s+/g, " "));
            if (subst && (curT.length <= 3 || autoPrefix)) {
              let t = subst.replace(/\s+/g, " ").split(" ").slice(0, 9).join(" ");
              if (t.length > 60) t = t.slice(0, 60).replace(/\s+\S*$/, "") + "…";
              if (t && t !== curT) {
                s._retitled = true;
                api.post("/api/conversations/rename", { id, title: t }).then(() => { const m2 = convIndex.get(id); if (m2) m2.title = t; s.title = t; try { s.renderHead(); } catch (e) {} renderList(); }).catch(() => {});
              }
            }
          }
        } catch (e) {}
        try { replayDirectMirrors(s); } catch (e) {}   // MIROIR DIRECT → ACTIVE : survie au rechargement — rendus ré-ajoutés dans l'ordre puis attente vidée, jamais deux fois (déduplication par feed)
        /* DIAG2-CONTEXTE P-CTX-6 : ajouts persistés lors d'une fermeture de vue (hunk 1) —
           reposés en file, dans l'ordre, puis drainés si aucun run n'est en cours. */
        try {
          const key = "nova2.queue." + id;
          const rest = JSON.parse(localStorage.getItem(key) || "[]");
          if (rest.length) {
            localStorage.removeItem(key);
            for (const it of rest) { if (it && it.text) { s.pendingQuote = it.quote || ""; await s.enqueue(it.text); } }
            if (!s.running && !s.queuePaused) s.drainQueue();
            s.notice("File restaurée : " + rest.length + " ajout(s) en attente, écrits avant la fermeture de la vue.");
          }
        } catch (e) {}
        try { s.touch(); s.syncDirect(); } catch (e) { /* contenu déjà rendu : un souci d'à-côté ne rend pas le fil « illisible » */ }
      } catch (e) {
        if (!sameCid) s.historyLoaded = false;
        const detail = String((e && e.message) || e || "erreur inconnue");
        try {
          log.append(h("div", { class: "errbox" },
            h("b", {}, "Conversation interrompue : "), detail + ". Le contenu reste dans le moteur.",
            h("div", { style: "margin-top:8px" }, h("button", { class: "btn sm", onclick: () => { if (!s.historyLoading) s.loadConversation(id); } }, "Réessayer"))));
        } catch (e2) {}
        ctx.toast("Conversation illisible : " + detail, true);
      }
      s.historyLoading = false;
      if (s.historyReloadNeeded) { s.historyReloadNeeded = false; if (!dead && !s.dead && !s.running) s.loadConversation(id); }   // FIX-RENDU ① : rejeu unique demandé pendant le chargement (cf. E7)
    };
    /* FD (23/10) — DESCENTE INCRÉMENTALE DU FIL DIRECT OUVERT : à
       l'arrivée d'un événement, on ne re-rend QUE le suffixe nouveau
       (avant FD : loadConversation complet — tout le fil re-rendu à
       chaque arrivée). Sûreté : les empreintes des messages déjà rendus
       (posées par loadConversation) doivent correspondre exactement à la
       queue relue ; sinon on rend la main (false) et l'appelant rejoue le
       chargement complet historique. Les événements du suffixe sont
       rendus live (animation + réaction panda) ; séparateurs de jour et
       autres rôles gardent le rendu d'historique. */
    s.fdAppendLive = async (convId) => {
      try {
        if (s.dead || s.running || s.historyLoading || !s.historyLoaded) return false;
        if (!Array.isArray(s._fdSigs) || s.cid !== String(convId)) return false;
        const j = await api.get("/api/conversation?id=" + encodeURIComponent(String(convId)));
        if (dead || s.dead || s.running) return false;
        const msgs = arrOf(j, "messages");
        if (msgs.length < (s._fdTotal || 0)) return false;
        const base = msgs.slice(msgs.length - s._fdSigs.length);
        for (let i = 0; i < s._fdSigs.length; i++) { if (fdMsgSig(base[i]) !== s._fdSigs[i]) return false; }
        const fresh = msgs.slice(s._fdTotal || 0);
        if (!fresh.length) return true;
        let prevTs = s._fdLastTs || null;
        for (const m of fresh) {
          if (m.ts && !sameDay(prevTs, m.ts)) { const sep = daySepEl(m.ts); if (sep) log.append(sep); }
          if (m.role === "user") s.bubble("user", String(m.content || ""), null, m.ts);
          else if (m.role === "event") s.directEvent(m, true);
          else if (m.role === "assistant") { try { for (const tl of (Array.isArray(m.tools) ? m.tools : [])) { if (tl && tl.tool === "precision_ahadi" && tl.arg) { const pb = s.bubble("user", "↳ " + String(tl.arg), null, m.ts); if (pb) pb.classList.add("cs-steered"); } } } catch (e) {} const bb = s.bubble("nova", String(m.content || ""), null, m.ts); s.decorateNovaBubble(bb, String(m.content || "")); if (m.memory) s.renderProv(bb, m.memory); }
          if (m.ts) prevTs = m.ts;
          s._fdSigs.push(fdMsgSig(m));
        }
        s._fdLastTs = prevTs;
        s._fdTotal = msgs.length;
        s.touch();
        return true;
      } catch (e) { return false; }
    };
    s.ensureHistory = () => {   // FIX-RENDU ① : point d'entrée UNIQUE des activations et des fins de run — charge l'historique de la session UNE fois. Gardes : jamais pendant un run (loadConversation remplace le journal, il effacerait le flux), jamais pendant un chargement, jamais si une file non suspendue va repartir (son run chargera en son temps), jamais deux fois (historyLoaded).
      if (!s.cid || s.dead || s.running || s.historyLoaded || s.historyLoading) return;
      if (s.queue && s.queue.length && !s.queuePaused) return;
      s.loadConversation(s.cid);
    };
    s.destroy = () => {
      s.dead = true; s.runToken++;
      /* DIAG2-CONTEXTE P-CTX-6 : la file ne meurt PLUS avec la vue. Avant : tout ajout en
         attente était jeté sans envoi ni trace (« la file vit dans la vue : elle meurt avec
         elle ») — Ahadi écrivait des messages que Nova ne recevait jamais. Désormais, les
         items non partis sont persistés (par conversation, plafond 20) et reposés en file
         à la réouverture du fil (hunk 2). Sans cid (fil jamais ouvert côté moteur), les
         textes n'ont aucune existence serveur : ils restent perdus — cas limite assumé,
         le composeur du fil neuf n'est pas détruit par une navigation ordinaire. */
      if (s.queue.length && s.cid) {
        try {
          const key = "nova2.queue." + s.cid;
          const prev = JSON.parse(localStorage.getItem(key) || "[]");
          const rest = s.queue.map((it) => ({ text: it.text, quote: it.quote || "" }));
          localStorage.setItem(key, JSON.stringify(prev.concat(rest).slice(-20)));
        } catch (e) {}
      }
      s.queue = [];
      if (s.budgetTimer) clearInterval(s.budgetTimer);
      try { s.abortCtl && s.abortCtl.abort(); } catch (e) {}
      document.removeEventListener("click", onDocClick);
      attInputs.forEach((el) => { try { el.remove(); } catch (e) {} });
    };
    s.renderHead();
    return s;
  }

  /* ── Bandeau Direct partagé : le dernier item, une ligne, partout ──── */
  function syncDirect() {
    if (dead || !ctx.direct) return;
    const items = ctx.direct.list().filter((i) => !bandDismissed.has(i.key));
    for (const s of sessions.values()) s.renderDirectBand(items);
  }

  /* ── Bloc Supervision & confiance — SOUS la mise en page, hors des fils ── */
  const regimesBox = h("div", { class: "regime-grid" });
  const rulesBox = h("div", {});
  const auditBox = h("div", {});
  const neverBox = h("div", {});
  const estLine = h("div", { class: "est-line", style: "margin-top:8px" }, "Estimation : chargement de l'historique…");
  function renderEst() { const s = activeSession(); estLine.textContent = estText(s ? s.brainSel.value || "" : ""); }
  const trustClose = h("button", { class: "btn-close", title: "Fermer", "aria-label": "Fermer", html: ic("close", 16), onclick: () => { trust.hidden = true; } });
  const trust = h("div", { class: "mp-trust", hidden: true, role: "dialog", "aria-label": "Supervision et confiance" },
    h("div", { class: "mp-trust-head" }, h("span", { html: ic("shield", 18) }), h("div", { class: "grow tt" }, "Supervision & confiance"), trustClose),
    h("div", { class: "mp-trust-body" },
      regimesBox,
      h("div", { class: "card flat", style: "margin-top:12px" },
        h("div", { class: "tt" }, "Mes règles d'approbation"),
        h("div", { class: "ss", style: "color:var(--ink-2);margin:4px 0 6px" }, "« Toujours autoriser ce type » ne vaut que pour les outils de lecture seule, et c'est l'INTERFACE qui l'applique (le moteur garde ses propres garde-fous, intacts). Règles persistées côté moteur (/api/settings)."),
        rulesBox),
      h("div", { class: "card flat", style: "margin-top:12px" },
        h("div", { class: "tt" }, "Jamais sans toi"),
        h("div", { class: "ss", style: "color:var(--ink-2);margin:4px 0 6px" }, "Le périmètre que le moteur refuse en dur — aucune règle, aucune autonomie ne l'ouvre :"),
        neverBox),
      h("div", { class: "card flat", style: "margin-top:12px" },
        h("div", { class: "tt" }, "Outils accessibles à l'IA"),
        h("div", { style: "display:flex;gap:6px;flex-wrap:wrap;margin-top:8px" }, ...AGENT_TOOLS.map((t) => h("span", { class: "chip" }, t))),
        estLine),
      h("div", { class: "card flat", style: "margin-top:12px" },
        h("div", { style: "display:flex;gap:8px;align-items:center;flex-wrap:wrap" },
          h("div", { class: "tt" }, "Journal d'audit"),
          h("span", { class: "sp", style: "flex:1" }),
          h("button", { class: "btn", onclick: () => exportAudit("json") }, h("span", { html: ic("download", 15) }), " Export JSON"),
          h("button", { class: "btn", onclick: () => exportAudit("csv") }, h("span", { html: ic("download", 15) }), " Export CSV")),
        h("div", { class: "ss", style: "color:var(--ink-2);margin:4px 0 6px" }, "Actions du moteur (/api/actions) + décisions prises dans cette interface (approbations, refus motivés, règles, arrêts budget)."),
        auditBox)));
  root.append(trust);
  trustBtn.addEventListener("click", () => { trust.hidden = !trust.hidden; if (!trust.hidden) { try { loadAudit(); } catch (e) {} } });
  const onTrustKey = (e) => { if (e.key === "Escape" && !trust.hidden && root.isConnected) { trust.hidden = true; e.stopPropagation(); } };
  document.addEventListener("keydown", onTrustKey, true);
  const onTrustDown = (e) => { try { if (!trust.hidden && root.isConnected && !trust.contains(e.target) && !trustBtn.contains(e.target)) trust.hidden = true; } catch (err) {} };
  document.addEventListener("pointerdown", onTrustDown, true);

  function renderRegimes() {
    const cell = (name, desc, on, extra) => h("div", { class: "regime" + (on ? " on" : "") },
      h("div", { class: "tt" }, name), h("div", { class: "ss" }, desc), extra || null);
    const watchSw = h("button", { class: "switch", role: "switch", "aria-checked": watchMode ? "true" : "false",
      onclick: () => { watchMode = !watchMode; try { localStorage.setItem(WATCH_KEY, watchMode ? "1" : "0"); } catch (e) {} watchSw.setAttribute("aria-checked", String(watchMode)); renderRegimes(); } });
    const watchRow = h("div", { style: "display:flex;align-items:center;gap:9px;margin-top:9px" }, watchSw, h("span", { class: "ss" }, "Me prévenir quand une tâche se termine"));
    regimesBox.replaceChildren(
      cell("Takeover — tu reprends la main", "Bouton Stop de la conversation : l'agent s'interrompt à la fin de l'étape en cours ; le pont UI rend le contrôle du Mac à tout moment.", false,
        h("button", { class: "btn", style: "margin-top:7px", onclick: () => { const s = activeSession(); if (s) s.stopRun(); } }, h("span", { html: ic("stop", 11) }), " Stop (conversation active)")),
      cell("Confirmation — il demande avant", "Cartes d'approbation pour les gestes sensibles (politique d'outil ou garde-fou) ; sans réponse sous 60 s, refus automatique du moteur.", true),
      cell("Watch — supervision silencieuse", "La trace reste dans les Détails de sa conversation, la fin de tâche te notifie et tout est journalisé dans l'audit ci-dessous.", watchMode, watchRow),
      cell("Refus — jamais, même en autonomie totale", "Envois de messages, paiements, finances, mots de passe et secrets : refus en dur du moteur (voir « Jamais sans toi »).", false));
  }
  function renderRules() {
    if (!rulesBox) return;
    rulesBox.replaceChildren(...(rules.length ? rules.map((r, i) => h("div", { class: "rule-row" },
      h("span", { html: ic("check", 15) }),
      h("div", { class: "grow" }, h("div", { class: "tt" }, "Toujours autoriser : " + String(r.tool || "")),
        h("div", { class: "ss" }, "Lecture seule · créée le " + (r.at ? new Date(r.at).toLocaleString("fr-FR") : "—") + " · appliquée par l'interface")),
      h("button", { class: "btn danger-solid", onclick: async (e) => { const b = e.currentTarget; if (!b.dataset.armed) { b.dataset.armed = "1"; b.textContent = "Confirmer ?"; setTimeout(() => { try { if (b.isConnected) { delete b.dataset.armed; b.textContent = "Retirer"; } } catch (e2) {} }, 4000); return; } rules.splice(i, 1); await saveRules(); audit("regle", "Règle retirée : " + r.tool, "supprimée"); } }, "Retirer")))
      : [h("div", { class: "empty" }, "Aucune règle pour l'instant — crée-en une depuis une carte d'approbation (« Toujours autoriser ce type »).")]));
  }
  let engineActions = [];
  async function loadAudit() {
    try { const j = await api.get("/api/actions"); if (!dead) engineActions = arrOf(j, "items"); } catch (e) { engineActions = []; }
    renderAudit();
  }
  function auditRows() {
    const eng = engineActions.slice(0, 14).map((a) => ({
      at: a.ts || a.at || a.time || "", src: "moteur",
      what: String(a.what || a.action || a.tool || a.kind || "action"), result: String(a.result || a.status || a.outcome || ""),
    }));
    const loc = auditLocal().slice(-10).reverse().map((a) => ({ at: a.at, src: "interface", what: a.kind + " — " + a.what, result: a.result }));
    return [...loc, ...eng];
  }
  function renderAudit() {
    if (!auditBox || dead) return;
    const rows = auditRows();
    auditBox.replaceChildren(...(rows.length ? rows.slice(0, 16).map((r) => h("div", { class: "audit-row" },
      h("span", { class: "when" }, r.at ? (isNaN(new Date(r.at)) ? String(r.at).slice(0, 16) : new Date(r.at).toLocaleString("fr-FR", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })) : "—"),
      h("span", { class: "chip" }, r.src),
      h("span", { class: "what" }, trunc(r.what, 130)),
      h("span", { class: "ss" }, trunc(r.result, 60))))
      : [h("div", { class: "empty" }, "Aucune action journalisée pour le moment.")]));
  }
  function exportAudit(fmt) {
    const rows = [...auditLocal().map((a) => ({ at: new Date(a.at).toISOString(), source: "interface", kind: a.kind, what: a.what, result: a.result })),
      ...engineActions.map((a) => ({ at: String(a.ts || a.at || ""), source: "moteur", kind: String(a.kind || a.tool || ""), what: String(a.what || a.action || ""), result: String(a.result || a.status || "") }))];
    let blob, name;
    if (fmt === "csv") {
      const q = (v) => '"' + String(v ?? "").replace(/"/g, '""') + '"';
      blob = new Blob([["at,source,kind,what,result", ...rows.map((r) => [r.at, r.source, r.kind, r.what, r.result].map(q).join(","))].join("\n")], { type: "text/csv" });
      name = "nova-audit.csv";
    } else {
      blob = new Blob([JSON.stringify({ exported: new Date().toISOString(), rows }, null, 2)], { type: "application/json" });
      name = "nova-audit.json";
    }
    const a = h("a", { href: URL.createObjectURL(blob), download: name }); document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 4000);
    audit("export", "Journal d'audit exporté (" + fmt.toUpperCase() + ")", rows.length + " lignes");
  }
  async function loadNever() {
    try {
      const j = await api.get("/api/rules"); if (dead) return;
      const hard = arrOf(j, "interdits_en_dur");
      neverBox.replaceChildren(...[
        h("ul", { class: "never-list" }, ...hard.map((x) => h("li", {}, String(x)))),
        j && j.file_envoi ? h("div", { class: "ss", style: "margin-top:6px" }, String(j.file_envoi)) : null,
      ].filter(Boolean));   /* FINITION 21/10 : pas de null nu à replaceChildren */
    } catch (e) { neverBox.replaceChildren(h("div", { class: "empty" }, "Never-list injoignable (moteur).")); }
  }

  /* ── Historique des conversations (liste + index des titres) ───────── */
  let historyError = false;
  async function loadHistory() {
    try {
      const j = await api.get("/api/conversations"); if (dead) return;
      historyError = false;
      const items = arrOf(j, "items", "conversations");
      convIndex.clear();
      for (const c of items) {
        if (c && c.id) convIndex.set(String(c.id), {
          title: String(c.title || c.id),
          updated: new Date(c.updated || c.updated_at || c.at || c.ts || 0).getTime() || 0,   // FIX-RENDU ② : Store.swift envoie « updated » — le lire EN PREMIER, les anciens noms restent en repli. Sans lui : fraîcheur = 0 pour les 217 fils, tri par récence inopérant et méta « — » partout (forensique §3).
          brain: String(c.brain_label || c.brain || ""),
          count: Number(c.count || 0),
          pinned: c.pinned === true,   // 27/10 : épinglage manuel (Store.list)
          created: c.created ? new Date(c.created).getTime() || 0 : 0,   // 27/10 : date de CRÉATION du fil, distincte de l'activité
          archived: String(c.archived || ""),   // LOT3 : manuel | auto | non (Feat_ConvArchive.swift)   // FIX-DIRECT-WEB ⑤ : total de messages du fil (Store.list le fournit) — base du recalcul des non-lus du Fil direct
        });
      }
      /* FIX-DIRECT-WEB ⑤ : après chaque rafraîchissement de l'index, le compteur
         du Fil direct est recalculé sur vérité moteur — SAUF si l'utilisateur est
         en train de lire le fil : alors tout est acquitté. */
      if (readingDirect()) markDirectSeen(); else recomputeDirect();
      const brains = arrOf(j, "brains");
      if (brains.length) { brainsList = brains; for (const s of sessions.values()) s.populateBrains(); }
      for (const s of sessions.values()) { if (s.cid && convIndex.has(s.cid)) { s.title = convIndex.get(s.cid).title || s.title; s.renderHead(); } }
      renderList();
    } catch (e) { historyError = true; renderList(); /* A-17/DS §6.10 : échec ≠ vide — renderList rend .state-error + Réessayer, jamais « Aucune conversation » */ }
  }
  /* Rafraîchissement sobre de la liste : l'état en direct des sessions
     ouvertes est local (instantané) ; le sondage ne sert qu'à découvrir les
     conversations créées ailleurs et les nouveaux titres. */
  let stopPoll = null;
  if (typeof ctx.every === "function") stopPoll = ctx.every(45000, () => { if (!dead) loadHistory(); });
  else { const t = setInterval(() => { if (!dead && !document.hidden) loadHistory(); }, 45000); stopPoll = () => clearInterval(t); }

  /* ── Abonnements : demandes externes + Direct global ────────────────── */
  /* 26/10 : une question venue de l'Accueil (fresh) ouvre sa propre conversation au lieu de s'ajouter à la dernière. */
  onBus("nova:ask", (d) => { if (d && d.text && !dead) { const s = d.fresh ? newConversation(false) : activeSession(); if (s) s.submit(d.text); } });
  /* Accès conversations DIRECT depuis le rail (panneau global du shell,
     ordre d'Ahadi 21/10) : le shell pose aussi la clé pending — on la
     consomme ici pour qu'une ouverture déjà servie ne se rejoue pas. */
  onBus("nova:open-conv", (d) => { if (d && d.cid && !dead) { try { localStorage.removeItem("nova2_pending_conv"); } catch (e) {} openConversation(String(d.cid), true); } });
  onBus("nova:nav-open-conv", (d) => { if (d && d.cid && !dead) openConversation(String(d.cid), false); });   // retour historique du shell : ré-affiche sans voler le focus clavier
  /* 26/10 : un direct déposé par le moteur dans une conversation ouverte apparaît comme un message de Nova, en place. */
  onBus("conv.append", (d) => {
    if (dead || !d || !d.conv || !d.msg) return;
    const s = sessionsByCid.get(String(d.conv));
    if (!s || s.dead) return;
    const txt = String(d.msg.content || "");
    const put = () => { try { const bb = s.bubble("nova", txt, null, d.msg.ts); if (bb) { bb.classList.add("cs-direct-in"); s.decorateNovaBubble(bb, txt); } } catch (e) {} };
    if (s.running) { const iv = setInterval(() => { if (s.dead) { clearInterval(iv); return; } if (!s.running) { clearInterval(iv); put(); } }, 800); }
    else put();
  });
  onBus("direct.appended", (d) => {   // SPEC ÉVÉNEMENTS DANS LE CHAT (§4.7) : le fil dédié ouvert se rafraîchit tout seul quand le moteur y matérialise un événement — jamais pendant un run (on ne touche pas à un fil en cours d'écriture)
    if (dead || !d || !d.conv) return;
    try { traceMirror(d.feed, "RECU_AGENT", "", String(d.conv || ""), ""); } catch (e) {}
    learnDirectCid(String(d.conv));   // FIX-DIRECT-WEB ⑤ : d.conv EST l'id du Fil direct (App.swift, bus.publish « direct.appended »)
    const s = sessionsByCid.get(String(d.conv));
    /* FD (23/10) : le fil ouvert descend en incrémental (fdAppendLive) ;
       repli sur le chargement complet si les empreintes divergent ou si
       le fil n'est pas dans l'état requis. loadHistory (compteurs) reste
       appelé dans tous les cas, comme avant. */
    if (s && !s.dead && !s.running) {
      const convId = String(d.conv);
      if (s.historyLoaded && !s.historyLoading && s.cid === convId && Array.isArray(s._fdSigs)) {
        s.fdAppendLive(convId).then((ok) => { if (!ok && !s.dead && !s.running) s.loadConversation(convId); });
      } else s.loadConversation(convId);
    }
    loadHistory();
    try { mirrorDirectToActive(d); } catch (e) {}   // MIROIR DIRECT → ACTIVE : pousse l'événement dans la session active (repli async silencieux, déduplication par feed, file d'attente si run/chargement)
  });
  /* FIX-DIRECT-WEB ⑤ : le shell incrémente le compteur quand ce module n'est
     pas monté et le signale ici — la ligne du fil se repeint (le compteur lu
     vient de l'état partagé, resynchronisé dans renderList). */
  onBus("nova:direct-unread", () => { if (!dead) renderList(); });
  onBus("nova:new-conv", () => { if (!dead) { try { localStorage.removeItem("nova2_pending_conv"); } catch (e) {} newConversation(true); } });
  /* §31 (21/10 ~08:58) : l'onglet Conversations du rail déploie la liste EN
     COLONNE dans cet espace — si elle était masquée, on la ré-affiche. */
  onBus("nova:show-conv-side", () => { if (!dead) { layout.classList.remove("side-hidden"); try { localStorage.setItem(SIDE_KEY, "1"); } catch (e) {} } });
  /* §40 bis : ouverture demandée par le panneau latéral (dock) quand ce
     module est DÉJÀ monté — la clé localStorage ne sert qu'au montage
     frais ; ici, l'événement fait le relais et consomme la clé. */
  onBus("nova:open-conv", (d) => {
    if (dead || !d || !d.id) return;
    try { localStorage.removeItem("nova2_pending_conv"); } catch (e) {}
    if (String(d.id) === "__new__") newConversation(true);
    else openConversation(String(d.id), true);
  });
  if (ctx.direct) {
    onBus("nova:direct-item", () => syncDirect());
    onBus("nova:direct-state", () => syncDirect());
  }

  /* ── Restauration des conversations ouvertes (localStorage) ─────────── */
  let restoreIds = [], restoreActive = "";
  try { restoreIds = JSON.parse(localStorage.getItem(OPEN_KEY) || "[]"); restoreActive = localStorage.getItem(ACTIVE_KEY) || ""; } catch (e) {}
  if (Array.isArray(restoreIds) && restoreIds.length) {
    for (const cid of restoreIds.slice(0, MAX_RESTORE)) openConversation(String(cid), false);
    const act = sessionsByCid.get(restoreActive);
    if (act) activate(act, false);
  } else {
    newConversation(false);
  }

  /* ── « Pendant ton absence » : état d'exécution persisté ────────────── */
  try {
    const r = JSON.parse(localStorage.getItem(RUN_KEY) || "null");
    const first = activeSession();
    if (first && r && r.status === "running" && r.at && Date.now() - r.at > 30000) {
      first.notice("Pendant ton absence : une tâche était en cours quand tu as quitté cet écran (" + new Date(r.at).toLocaleTimeString("fr-FR") + ") — « " + (r.text || "") + " ». Le fil d'interface s'est détaché, mais la conversation est conservée côté moteur : rouvre-la depuis la liste de gauche.", "warn");
      first.setDetails(true);
    } else if (first && r && r.status === "terminée" && r.finishedAt && Date.now() - r.finishedAt < 6 * 3600 * 1000 && !sessionStorage.getItem("nova2_agent_seen")) {
      first.notice("Pendant ton absence : la tâche « " + (r.text || "") + " » s'est terminée à " + new Date(r.finishedAt).toLocaleTimeString("fr-FR") + ".");
      try { sessionStorage.setItem("nova2_agent_seen", "1"); } catch (e) {}
    }
  } catch (e) {}

  /* Demande d'ouverture venue du panneau Conversations global (rail) quand
     le module n'était pas encore monté : consommée une seule fois, ici. */
  try {
    const p = localStorage.getItem("nova2_pending_conv");
    if (p) {
      localStorage.removeItem("nova2_pending_conv");
      if (p === "__new__") newConversation(true);
      else openConversation(String(p), true);
    }
  } catch (e) {}

  renderRegimes(); renderRules();
  loadHistory(); loadCouts(); loadRules(); loadNever(); loadAudit();
  syncDirect();
  /* FIX-DIRECT-WEB ⑤ : apprendre l'id du Fil direct dès le montage (même
     source que prochat.js : GET /api/proactive/feed → direct_thread_id).
     Échec toléré en silence : l'état persisté et les événements
     « direct.appended » couvrent l'apprentissage. */
  try { api.get("/api/proactive/feed").then((j) => { if (!dead && j && j.direct_thread_id) { engineDirectCid = String(j.direct_thread_id); learnDirectCid(engineDirectCid); for (const x of sessions.values()) { try { if (x.paintChannelBar) x.paintChannelBar(); } catch (e) {} } } }).catch(() => {}); } catch (e) {}

  /* Cycle de vie objet (shell persistant) : destroy = fermeture réelle du
     module (rafraîchissement forcé) ; onHide/onShow ne coupent AUCUN flux —
     c'est ce qui permet de suivre les conversations en direct depuis la
     liste et d'y revenir avec tout en place. */
  return {
    destroy: () => {
      dead = true;
      try { document.removeEventListener("keydown", onTrustKey, true); document.removeEventListener("pointerdown", onTrustDown, true); } catch (e) {}
      if (stopPoll) { try { stopPoll(); } catch (e) {} }
      offs.forEach((o) => { try { o(); } catch (e) {} });
      for (const s of sessions.values()) s.destroy();
      if (voice) { try { voice.dispose(); } catch (e) {} voice = null; }
      try { for (const [src, b] of perfState) { if (b) { perfState.set(src, false); const p = api.post("/api/perf", { busy: false, source: src }, 5000); if (p && p.catch) p.catch(() => {}); } } } catch (e) {}   // V4-D : aucune source « occupé » ne survit au démontage
    },
    onHide: () => { moduleShown = false; },   // FIX-DIRECT-WEB ⑤ : module caché = on ne « lit » plus le fil
    onShow: () => { moduleShown = true; syncDirect(); loadHistory(); try { const a = activeSession(); if (a && !a.dead && a.cid) replayDirectMirrors(a); } catch (e) {} try { const a = activeSession(); if (a && !a.dead && a.cid) { api.get("/api/conversations").then((jj) => { try { const arr = (jj && (jj.items || jj.conversations)) || []; const ent = arr.find((x) => x && String(x.id) === String(a.cid)); if (!ent) return; const u = new Date(ent.updated || ent.updated_at || ent.at || ent.ts || 0).getTime() || 0; if (u && u !== a.renderedUpdated) { a.renderedUpdated = u; if (!a.running && !a.historyLoading) a.loadConversation(a.cid); } } catch (e2) {} }).catch(() => {}); } } catch (e) {} },   // R-MIROIR : rattrapage des miroirs arrivés hors vue (rejeu idempotent, garde Fil direct interne)
  };
}
