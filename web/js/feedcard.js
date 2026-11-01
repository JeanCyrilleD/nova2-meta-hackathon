import { eclatize, api, bus, showToast, h as coreH, md as coreMd } from "./core.js";
import { feedbackBar } from "./eclat-feedback.js";   // V6 ÉCLATS : Utile / Pas utile / Corriger…
import { ic as coreIc } from "./icons.js";
import { isHouse, parseHouse, houseCompactHTML } from "./richtext.js";
import { renderJournalSoirCard } from "./journal-soir.js";   // LOT3 (25/10) : carte « 2 minutes pour ta journée ? »   // V5-W : format maison (STATUT / ## / À TOI) mis en page
import { mountAutoDraft } from "./autodraft.js";   // 25/10 AUTONOMIE : bloc « Brouillon prêt » (Feat_Autonomie, jamais d'envoi)
/* feedcard.js — CARTE D'ARRIVÉE UNIQUE DU FIL (24/10/2026, ordre d'Ahadi).

   Toute arrivée dans les chats de Nova — mail (Outlook, Gmail), Teams, WhatsApp, Dot qui a
   fini, brief, échéance, GitHub — a désormais la MÊME composition, la MÊME descente et la
   MÊME mémoire :

     en-tête   source nommée (icône) · TRI (Urgent / À décider / À traiter / À suivre / Info) · heure
     BLUF      la ligne qui dit l'essentiel (première ligne composée par le moteur)
     Nova —    le commentaire / tri rédigé par le moteur (DirectFeed.triText), jamais inventé ici
     À toi     « Ce qui reste pour toi : … » quand le corps l'exige ; échéance citée
     Extrait   le corps réellement lu, replié
     pied      DOTS (le Dot qui a pris l'événement en charge) + MÉMOIRE (ce que Nova sait déjà
               de ce fil, de cette personne, de ce dossier) + action « Ouvrir … »

   La MÉMOIRE DES FAITS : chaque arrivée est consignée dans un registre local (clé
   nova2_feed_memory_v1) indexé par personne, par fil (objet normalisé) et par dossier
   (repères partagés avec direct-global.js). Une nouvelle arrivée est reliée à ce que Nova
   sait déjà — « Suite de … (il y a 2 j) », « 3ᵉ échange avec … », « Dossier : BRVM ». Quand
   il n'existe aucun passé, la carte le DIT (« Premier fil — Nova s'en souviendra ») : jamais
   un fait isolé présenté comme s'il avait un passé, jamais un passé inventé.
   Ne fabrique aucun contenu : tout vient des champs stockés du message et de son texte.

   V4-C (24/10) : la mémoire des faits vit désormais dans le MOTEUR (feed_memory.json,
   GET/POST /api/feed/memory — DirectFeed.swift). Le localStorage n'est plus qu'un cache de
   premier rendu : hydraté depuis le moteur au chargement, les entrées locales jamais vues du
   moteur lui sont remontées (migration), chaque nouvelle entrée part au moteur par lots.
   Canal FUNDINGS (DOSSIER §5) : renderFundingsEvent + mountFundingsBand ; contrat du lot D :
   channelOf(item), isFundings(item), mountFundingsBand(container, ctx). */

const MEM_KEY = "nova2_feed_memory_v1";
const MEM_MAX = 600;

const TAG_RULES = [
  [/\brh\b|ressources humaines|human resources/i, "RH"], [/recrutement|recruitment/i, "Recrutement"],
  [/gho|global outlook/i, "GHO 2027"], [/visa|e-visa|voyage|travel/i, "Voyage / visa"],
  [/paiement|payment|facture|invoice|virement/i, "Paiements"], [/brvm|bourse/i, "BRVM"],
  [/github|commit|pull request|issue/i, "GitHub"],
];
const BOX = { ol: "Outlook", gm: "Gmail", tm: "Teams", wa: "WhatsApp", gh: "GitHub", zm: "Zoho" };   // V5-S : zm = boîte Zoho campagne (lecture directe)
const BOX_IC = { ol: "outlook", gm: "gmail", tm: "teams", wa: "whatsapp", gh: "globe", zm: "mail" };
const DOT_OF = { ol: "Éclat Courrier", gm: "Éclat Courrier", tm: "Éclat Teams", wa: "Éclat WhatsApp", gh: "Éclat GitHub", zm: "Éclat Courrier" };

function sourceOf(m) {
  const kind = String(m.kind || ""), box = String(m.box || "");
  if (kind === "dot.done") return { label: "Éclat" + (BOX[box] ? " · " + BOX[box] : ""), icon: "agent" };
  if (kind === "muse") return { label: ({ contact: "Contact de la semaine", passe: "Passe mail", argent: "Argent · vigilance", antiseche: "Antisèche réunion", integrations: "Intégrations" })[box] || "Nova", icon: ({ contact: "talk", passe: "mail", argent: "alert", antiseche: "calendar", integrations: "alert" })[box] || "feed" };
  if (kind === "brief") return { label: "Brief", icon: "brief" };
  if (kind === "meeting") return { label: "Agenda", icon: "calendar" };
  if (kind === "teams.new" || box === "tm") return { label: "Teams", icon: "teams" };
  if (kind.startsWith("github.")) return { label: "GitHub", icon: "globe" };
  if (BOX[box]) return { label: BOX[box], icon: BOX_IC[box] || "mail" };
  if (kind === "mail.new") return { label: "Boîte mail", icon: "mail" };
  if (kind === "due") return { label: "Échéance", icon: "time" };
  if (kind === "brvm.alerte") return { label: "BRVM · alerte", icon: "chart" };   // LOT3 (25/10)
  return { label: "Direct", icon: "feed" };
}
function dotOf(m) {
  if (m.dot) return String(typeof m.dot === "object" ? (m.dot.name || "Éclat") : m.dot);
  const kind = String(m.kind || ""), box = String(m.box || "");
  if (kind === "dot.done") { const n = String(m.dot_name || m.who || ""); return n ? n : "Éclat"; }
  if (kind === "brief") return "Nova · bilan";
  if (kind === "muse") return "Nova";
  if (kind === "meeting" || kind === "due") return "Éclat Agenda";
  if (kind === "teams.new") return "Éclat Teams";
  if (kind.startsWith("github.")) return "Éclat GitHub";
  return DOT_OF[box] || (kind === "mail.new" ? "Éclat Courrier" : "Nova");
}

/* ── Analyse du texte composé par le moteur (DirectFeed.compose) ─────────── */
/* 25/10 : corps de mail lisible — commentaires HTML/MSO, lignes vides en rafale, liens interminables
   (<https://…> → domaine), espaces insécables retirés. Le texte n'est pas réécrit, seulement nettoyé. */
function tidyBody(t) {
  /* 26/10 : balisage interne d'un cerveau gpt-oss (<|start|>…<|call|>) jamais affiché. */
  t = String(t || "").replace(/<\|start\|>[\s\S]*?<\|call\|>/g, " ").replace(/<\|[a-z_]+\|>/g, " ");
  let s = String(t || "");
  s = s.replace(/<!--[\s\S]*?-->/g, "").replace(/<!\[if[^\]]*\]>|<!\[endif\]>/gi, "");
  s = s.replace(/<(https?:\/\/[^>\s]{60,})>/g, (m, u) => { try { return "[lien " + new URL(u).hostname + "]"; } catch (e) { return "[lien]"; } });
  s = s.replace(/https?:\/\/[^\s)>\]]{90,}/g, (u) => { try { return "[lien " + new URL(u).hostname + "]"; } catch (e) { return "[lien]"; } });
  s = s.replace(/\u00a0/g, " ").replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n");
  return s.trim();
}
const FC_SEEN_KEY = "nova2_fc_seen_v1";
function fcSeenAll() { try { return JSON.parse(localStorage.getItem(FC_SEEN_KEY) || "{}") || {}; } catch (e) { return {}; } }
function fcSeen(fid, until) { try { const a = fcSeenAll(); a[fid] = { until, at: Date.now() }; const ks = Object.keys(a); if (ks.length > 600) for (const k of ks.slice(0, ks.length - 600)) delete a[k]; localStorage.setItem(FC_SEEN_KEY, JSON.stringify(a)); } catch (e) {} }
function fcSeenState(fid) { const a = fcSeenAll(); return a[fid] || null; }
export function parseComposed(content) {
  let txt = String(content || "").trim();
  let open = "";
  txt = txt.replace(/\s*\[Ouvrir\s*:\s*([^\]]+)\]\s*$/i, (_, x) => { open = x.trim(); return ""; });
  const lines = txt.split(/\n+/).map((l) => l.trim()).filter(Boolean);
  const out = { bluf: "", note: [], todo: "", due: "", extract: "", open, pri: "", priWhy: "", dots: "", qual: "", niveau: "", niveauWhy: "" };
  /* STYLE-MUSE (26/10, PDF « Le Direct de Muse » R2/R3) : la qualification et le niveau
     sortent du texte et deviennent des pastilles — jamais des lignes brutes dans le corps. */
  for (let i = lines.length - 1; i >= 0; i--) {
    const q = /^QUALIFICATION\s*:\s*(CONFIRMATION|RELANCE|FAIT NOUVEAU)\s*$/i.exec(lines[i]);
    if (q) { out.qual = q[1].toUpperCase(); lines.splice(i, 1); continue; }
    const n = /^NIVEAU\s*:\s*(URGENT|HAUT|MOYEN|BAS)\s*(?:[—–-]\s*(.*))?$/i.exec(lines[i]);
    if (n) { out.niveau = n[1].toUpperCase(); out.niveauWhy = (n[2] || "").trim(); lines.splice(i, 1); continue; }
    if (/^MESSAGE\s*:\s*/i.test(lines[i])) { lines[i] = lines[i].replace(/^MESSAGE\s*:\s*/i, ""); if (!lines[i]) lines.splice(i, 1); }
  }
  if (!lines.length) return out;
  out.bluf = lines.shift()
    .replace(/^[\u{1F300}-\u{1FAFF}☀-➿️‍]+\s*/u, "")   // l'icône de source vit dans l'en-tête
    .replace(/\s*·\s*corps lu\s*$/i, "");
  for (let l of lines) {
    if (/^Extrait\s*:/i.test(l)) { out.extract = l.replace(/^Extrait\s*:\s*/i, "").replace(/^«\s*|\s*»$/g, ""); continue; }
    if (/^Ce qui reste pour toi\s*:/i.test(l)) { out.todo = l.replace(/^Ce qui reste pour toi\s*:\s*/i, ""); continue; }
    /* 26/10 (format Muse) : priorité haute/moyenne/basse, commentaire, clôture DOTS */
    if (/^Priorit[ée]\s*:/i.test(l)) { const m = /^Priorit[ée]\s*:\s*(haute|moyenne|basse)\s*(?:[—–-]\s*(.*))?$/i.exec(l); if (m) { out.pri = m[1].toLowerCase(); out.priWhy = (m[2] || "").trim(); } continue; }
    if (/^Commentaire\s*:/i.test(l)) { out.note.push(l.replace(/^Commentaire\s*:\s*/i, "")); continue; }
    if (/^[🔴🟡🟢]/u.test(l)) { out.dots = l; continue; }
    if (/^DOTS\s*:/i.test(l)) { out.dots = l.replace(/^DOTS\s*:\s*/i, ""); continue; }
    l = l.replace(/^Mon tri\s*:\s*/i, "");
    // Échéance citée → puce dédiée ; « pas d'échéance » → rien (aucun bruit)
    l = l.replace(/Échéance\s*:\s*([^.]*)\.?/i, (_, d) => { if (!/pas d'échéance/i.test(d)) out.due = d.trim(); return ""; }).trim();
    if (l) out.note.push(l);
  }
  return out;
}
/* V5-W (25/10) : « À décider » ne s'affiche que si la décision ATTEND vraiment. L'état vivant vient de
   GET /api/dots/waiting (run_id, champ posé par 6fccca9) ; tant qu'il n'est pas connu, seule une
   arrivée en direct garde « À décider » — une carte d'historique reste neutre (« Terminé »), puis la
   pastille est corrigée dès que la file est lue. Jamais une décision soldée présentée comme ouverte. */
const WAIT = { at: 0, ids: null, busy: null };
function waitingState(runId) { if (!WAIT.ids || !runId) return null; return WAIT.ids.has(String(runId)); }
export async function refreshWaiting(force = false) {
  if (WAIT.busy) return WAIT.busy;
  if (!force && WAIT.ids && Date.now() - WAIT.at < 30000) return WAIT.ids;
  WAIT.busy = (async () => {
    try {
      const j = await api.get("/api/dots/waiting", 10000);
      const arr = j && Array.isArray(j.items) ? j.items : (j && Array.isArray(j.waiting) ? j.waiting : (Array.isArray(j) ? j : null));
      if (arr) { WAIT.ids = new Set(arr.map((x) => String((x && x.run_id) || "")).filter(Boolean)); WAIT.at = Date.now(); paintWaiting(); }
    } catch (e) {}
    WAIT.busy = null; return WAIT.ids;
  })();
  return WAIT.busy;
}
function paintWaiting() {
  try {
    for (const el of document.querySelectorAll('.fc[data-decision="1"][data-run]')) {
      const w = waitingState(el.dataset.run); if (w == null) continue;
      setPri(el, w ? { k: "decision", label: "À décider" } : { k: "done", label: "Terminé" });
    }
  } catch (e) {}
}
function setPri(card, pri) {
  card.dataset.pri = pri.k;
  const chip = card.querySelector(".fc-pri"); if (chip) { chip.className = "fc-pri p-" + pri.k; chip.textContent = pri.label; }
}
/* V5-Y (25/10) : un ÉCHEC d'Éclat de routine (« … a échoué », statut ECHEC) arrive du moteur
   avec urgent=true (donc gravité « grave » par R-G1) — ce n'est pas une urgence du monde
   d'Ahadi mais une panne d'outil : elle se lit dans l'écran Éclats, pas en « Urgent » rouge. */
export function isRoutineFailure(m) {
  if (!m || String(m.kind || "") !== "dot.done") return false;
  const c = String(m.content || "");
  return /a [ée]chou[ée]|\bECHEC\b|\b[ÉE]CHEC\b|statut\s*:\s*[ée]chec/i.test(c.slice(0, 400));
}
export function isRealUrgent(m) {
  return !!(m && (m.urgent === true || m.gravite === "grave") && !isRoutineFailure(m));
}
function priorityOf(m, p, live) {
  if (isRoutineFailure(m)) return { k: "suivre", label: "Échec" };
  if (isRealUrgent(m)) return { k: "urgent", label: "Urgent" };
  if (m.action && m.action.type === "decision") {
    const w = waitingState(m.action.run_id);
    if (w === true || (w == null && live)) return { k: "decision", label: "À décider" };
    return { k: "done", label: "Terminé" };
  }
  if (p.pri === "haute") return { k: "urgent", label: "🔴 Haute" };
  if (p.pri === "moyenne") return { k: "decision", label: "🟡 Moyenne" };
  if (p.pri === "basse") return { k: "info", label: "🟢 Info" };
  if (p.todo) return { k: "decision", label: "À traiter" };
  if (p.due) return { k: "suivre", label: "À suivre" };
  return { k: "info", label: "Info" };
}

/* ── Mémoire des faits ───────────────────────────────────────────────────── */
const loadMem = () => { try { const a = JSON.parse(localStorage.getItem(MEM_KEY) || "[]"); return Array.isArray(a) ? a : []; } catch (e) { return []; } };
const saveMem = (a) => { try { localStorage.setItem(MEM_KEY, JSON.stringify(a.slice(-MEM_MAX))); } catch (e) {} };
/* Moteur = source ; cache local = premier rendu. Hydratation au plus une fois par minute. */
let memHydratedAt = 0, memQueue = [], memTimer = 0;
function memFlush() {
  memTimer = 0;
  const batch = memQueue.splice(0, MEM_MAX);
  if (!batch.length) return;
  try { const pr = api.post("/api/feed/memory", { entries: batch }, 15000); if (pr && pr.catch) pr.catch(() => { memQueue = batch.concat(memQueue).slice(-MEM_MAX); }); } catch (e) {}
}
function memPush(e) { memQueue.push(e); if (!memTimer) memTimer = setTimeout(memFlush, 900); }
export async function hydrateFeedMemory(force = false) {
  if (!force && Date.now() - memHydratedAt < 60000) return false;
  memHydratedAt = Date.now();
  try {
    const j = await api.get("/api/feed/memory", 10000);
    const srv = j && Array.isArray(j.entries) ? j.entries.filter((e) => e && e.id && Number(e.at) > 0) : null;
    if (!srv) return false;   // moteur muet (ou banc d'essai) : le cache local reste tel quel, rien d'inventé
    const ids = new Set(srv.map((e) => String(e.id)));
    const localOnly = loadMem().filter((e) => e && e.id && !ids.has(String(e.id)));
    saveMem([...srv, ...localOnly].sort((a, b) => a.at - b.at));
    if (localOnly.length) { for (const e of localOnly) memQueue.push(e); if (!memTimer) memTimer = setTimeout(memFlush, 300); }
    return true;
  } catch (e) { return false; }
}
try { if (typeof window !== "undefined") setTimeout(() => { hydrateFeedMemory(true); }, 1500); } catch (e) {}
const normThread = (s) => String(s || "").replace(/\*\*/g, "").replace(/^(?:[A-Za-zÀ-ÿ ]{0,24}[—–-]\s*)?/, "").replace(/^\s*((re|tr|fw|fwd|réf)\s*:\s*)+/i, "").replace(/[«»"'`]/g, "").trim().toLowerCase().slice(0, 80);
function keysOf(m, p) {
  const hay = [m.who, p.bluf, p.note.join(" ")].join(" ");
  const tags = TAG_RULES.filter(([re]) => re.test(hay)).map(([, t]) => t);
  return { who: String(m.who || "").trim(), thread: normThread(p.bluf), tags };
}
const ago = (ms) => {
  const d = Math.max(0, ms) / 1000;
  if (d < 3600) return "il y a " + Math.max(1, Math.round(d / 60)) + " min";
  if (d < 86400) return "il y a " + Math.round(d / 3600) + " h";
  const j = Math.round(d / 86400); return j === 1 ? "hier" : "il y a " + j + " j";
};
/** Relie l'arrivée à ce que Nova sait déjà (entrées ANTÉRIEURES à elle seulement) et la consigne. */
export function linkMemory(m, p) {
  const id = String(m.feed || "") || [m.kind, m.box, p.bluf].join("|");
  const at = new Date(m.ts || Date.now()).getTime() || Date.now();
  const k = keysOf(m, p);
  const mem = loadMem();
  const prior = mem.filter((e) => e.id !== id && e.at <= at);
  const links = [];
  if (k.thread) {
    const same = prior.filter((e) => e.thread && e.thread === k.thread);
    if (same.length) links.push({ t: "Suite du fil · " + ago(at - same[same.length - 1].at) + (same.length > 1 ? " · " + (same.length + 1) + "ᵉ message" : "") });
  }
  if (k.who && links.length < 2) {
    const n = prior.filter((e) => e.who && e.who === k.who).length;
    if (n) links.push({ t: (n + 1) + "ᵉ échange avec " + k.who });
  }
  for (const tag of k.tags) { if (links.length >= 3) break; const n = prior.filter((e) => (e.tags || []).includes(tag)).length; links.push({ t: "Dossier " + tag + (n ? " · " + n + " fait" + (n > 1 ? "s" : "") + " connu" + (n > 1 ? "s" : "") : "") }); }
  if (!mem.some((e) => e.id === id)) { const ne = { id, at, who: k.who, thread: k.thread, tags: k.tags, bluf: p.bluf.slice(0, 120) }; mem.push(ne); mem.sort((a, b) => a.at - b.at); saveMem(mem); memPush(ne); }
  if (!links.length) links.push({ t: "Premier fil" + (k.who ? " avec " + k.who : "") + " — Nova s'en souviendra", fresh: true });
  return links;
}

/* ── V3 « RÉPONSES DANS SA VOIX » (24/10, patron Superhuman Auto Drafts) ─────────────
   Le bouton « Préparer une réponse » n'apparaît que sur une arrivée de messagerie
   (mail, Teams, WhatsApp) dont le TRI du moteur nomme une action pour Ahadi
   (« Ce qui reste pour toi : … ») qui appelle une réponse. Rien d'automatique : au clic
   seulement, le moteur (POST /api/voix-ahadi/variantes) rédige 3 variantes
   courtes dans SA voix (profil local). Elles sont éditables ici ; « Copier » ou
   « Préparer pour envoi » (POST /api/voix-ahadi/choix) qui crée la carte d'approbation
   existante de Messages — l'envoi reste ENVOYER d'Ahadi, rien ne part d'ici. */
const VA_MSG_BOX = new Set(["ol", "gm", "tm", "wa", "zm"]);
const VA_REPLY_RE = /r[ée]pon|confirm|valid|accept|d[ée]cid|indiqu|retour|revenir|r[ée]agi|avis|feedback|commente|approuv|pr[ée]cis|dire si|faire savoir|partag|envoy|transmet|propos|disponib|reply|respond|let .{0,20}know|get back/i;
export function attendReponse(m, p) {
  const box = String(m.box || ""), kind = String(m.kind || "");
  if (!(VA_MSG_BOX.has(box) || kind === "mail.new" || kind === "teams.new")) return false;
  if (!p.todo) return false;
  return VA_REPLY_RE.test(p.todo) || /\?/.test(p.note.join(" "));
}
function vaPanel(m, p, ctx, card, btn) {
  const { h, ic } = ctx;
  const panel = h("div", { class: "va-panel", role: "region", "aria-label": "Réponses dans ta voix" });
  const status = h("div", { class: "va-status", role: "status" });
  const body = h("div", { class: "va-body" });
  const close = () => { panel.remove(); btn.disabled = false; btn.style.display = ""; };
  const consigne = h("input", { class: "fld va-consigne", type: "text", placeholder: "Consigne (facultatif) : ex. « oui, mais pas avant jeudi » — Entrée pour rédiger à nouveau" });
  let state = null;   // { id, canal, variantes, destinataire, objet, envoi_possible, cur, edits[] }
  const head = h("div", { class: "va-head" },
    h("span", { class: "va-title" }, h("span", { html: ic("draft", 13) }), "Réponses dans ta voix"),
    h("span", { class: "sp" }),
    h("button", { class: "btn sm ghost", title: "Fermer — rien n'est gardé ni envoyé", onclick: close }, "Fermer"));
  panel.append(head, status, body);
  async function gen() {
    body.replaceChildren();
    status.className = "va-status";
    status.textContent = "Rédaction de 3 variantes dans ta voix…";
    try {
      const j = await api.post("/api/voix-ahadi/variantes", {
        feed: String(m.feed || ""), texte: String(m.content || "").slice(0, 4000), contexte: consigne.value.trim(),
        box: String(m.box || ""), kind: String(m.kind || ""), who: String(m.who || ""), titre: p.bluf || "",
      }, 120000);
      if (!panel.isConnected) return;
      if (!j || j.ok !== true || !Array.isArray(j.variantes) || !j.variantes.length) throw new Error((j && j.error) || "aucune variante reçue");
      state = { ...j, cur: 0, edits: j.variantes.map((v) => String(v.texte || "")) };
      status.textContent = "Rien n'est envoyé. Choisis, modifie, puis copie ou prépare pour envoi." + (j.cerveau ? " · " + j.cerveau : "");
      paint();
    } catch (e) {
      if (!panel.isConnected) return;
      status.className = "va-status bad";
      status.textContent = "Variantes indisponibles : " + ((e && e.message) || e);
      body.replaceChildren(h("div", { class: "va-actions" }, h("button", { class: "btn sm", onclick: gen }, "Réessayer")));
    }
  }
  function paint() {
    const s = state, v = s.variantes[s.cur];
    const tabs = h("div", { class: "va-tabs", role: "tablist" }, ...s.variantes.map((x, i) =>
      h("button", { class: "va-tab" + (i === s.cur ? " on" : ""), role: "tab", "aria-selected": i === s.cur ? "true" : "false",
        title: String(x.intention || ""), onclick: () => { s.cur = i; paint(); } }, String(x.label || "Variante " + (i + 1)))));
    const ta = h("textarea", { class: "fld fld-area va-text", rows: String(Math.min(14, Math.max(4, s.edits[s.cur].split("\n").length + 1))), "aria-label": "Texte de la variante — modifiable" });
    ta.value = s.edits[s.cur];
    const lintEl = h("div", { class: "va-lint" });
    const paintLint = () => {
      const items = (v.lint && v.lint.items) || [];
      const edited = s.edits[s.cur] !== String(v.texte || "");
      if (!items.length) { lintEl.textContent = s.canal === "whatsapp" ? "WhatsApp : copie seulement — Nova n'a pas de chemin d'envoi WhatsApp." : ""; return; }
      const bad = items.filter((it) => it.hard && !it.ok);
      lintEl.replaceChildren(
        h("span", { html: ic(bad.length ? "alert" : "check", 13) }),
        " " + (bad.length ? "Coche gabarit : à corriger avant l'envoi — " + bad.map((it) => it.label).join(" · ") : "Coche gabarit : tout est vert")
          + (edited ? " (texte modifié : la coche sera recalculée sur la carte Messages)" : ""));
      lintEl.className = "va-lint" + (bad.length ? " bad" : " ok");
    };
    ta.addEventListener("input", () => { s.edits[s.cur] = ta.value; paintLint(); });
    paintLint();
    const isMail = s.canal === "mail", isTeams = s.canal === "teams";
    const dest = h("input", { class: "fld va-dest", type: isMail ? "email" : "text", placeholder: isMail ? "Adresse e-mail du destinataire" : "Conversation Teams (nom exact)", "aria-label": isMail ? "Destinataire" : "Conversation Teams" });
    dest.value = String(s._dest != null ? s._dest : (s.destinataire || ""));
    dest.addEventListener("input", () => { s._dest = dest.value; });
    const obj = h("input", { class: "fld va-obj", type: "text", placeholder: "Objet", "aria-label": "Objet" });
    obj.value = String(s._obj != null ? s._obj : (s.objet || ""));
    obj.addEventListener("input", () => { s._obj = obj.value; });
    const fields = (isMail || isTeams) ? h("div", { class: "va-fields" },
      h("label", { class: "va-to" }, h("span", {}, isMail ? "À" : "Conversation"), dest),
      isMail ? h("label", { class: "va-to" }, h("span", {}, "Objet"), obj) : null) : null;
    const copyBtn = h("button", { class: "btn sm", onclick: async () => {
      const txt = s.edits[s.cur];
      try { await navigator.clipboard.writeText(txt); } catch (e) { showToast("Copie refusée par le système : sélectionne le texte et copie-le à la main.", { kind: "bad" }); return; }
      showToast("Copié dans ton presse-papiers — rien n'a été envoyé.");
      api.post("/api/voix-ahadi/choix", { id: s.id, variante: s.cur, final: txt, action: "copier" }, 15000).catch(() => {});
    } }, h("span", { html: ic("note", 13) }), "Copier");
    /* 29/10 (Ahadi : « déposer directement les brouillons dans Outlook, Gmail et Teams ») — un clic dépose la variante
       choisie DANS la boîte d'origine (Brouillons d'Outlook / de Gmail, zone de saisie Teams sans Entrée). Rien n'est envoyé. */
    const boxBtn = () => {
      const bx = String(m.box || "");
      const boite = bx === "ol" ? "outlook" : bx === "gm" ? "gmail" : bx === "tm" ? "teams" : "";
      if (!boite) return null;
      const lab = boite === "outlook" ? "Brouillon dans Outlook" : boite === "gmail" ? "Brouillon dans Gmail" : "Poser dans Teams";
      const b = h("button", { class: "btn sm", title: "Dépose ce texte comme brouillon dans " + (boite === "teams" ? "la conversation Teams (sans l'envoyer)" : "la boîte " + (boite === "outlook" ? "Outlook" : "Gmail")) + " — rien n'est envoyé" }, h("span", { html: ic(boite === "teams" ? "teams" : boite === "gmail" ? "gmail" : "outlook", 13) }), lab);
      b.addEventListener("click", async () => {
        const to = dest.value.trim();
        if (boite === "teams" && !to) { status.className = "va-status bad"; status.textContent = "Indique la conversation Teams (nom exact) avant de déposer le texte."; dest.focus(); return; }
        b.disabled = true; status.className = "va-status"; status.textContent = "Dépôt du brouillon dans " + lab.replace(/^Brouillon dans |^Poser dans /, "") + "…";
        try {
          const j = await api.post("/api/brouillon/boite", { boite, a: boite === "teams" ? "" : to, conversation: boite === "teams" ? to : "", objet: obj.value.trim(), corps: s.edits[s.cur] }, 90000);
          const ok = !!(j && j.ok);
          status.className = "va-status " + (ok ? "ok" : "bad");
          status.textContent = String((j && j.message) || (ok ? "Brouillon déposé — rien n'est envoyé." : "Dépôt impossible."));
          if (ok) api.post("/api/voix-ahadi/choix", { id: s.id, variante: s.cur, final: s.edits[s.cur], action: "copier" }, 15000).catch(() => {});
        } catch (e) { status.className = "va-status bad"; status.textContent = "Dépôt impossible : " + ((e && e.message) || e); }
        b.disabled = false;
      });
      return b;
    };
    const prepBtn = h("button", { class: "btn sm acc", disabled: !s.envoi_possible, title: s.envoi_possible ? "Crée la carte d'approbation dans Messages — l'envoi attendra ton ENVOYER" : "Pas de chemin d'envoi pour ce canal", onclick: async () => {
      const to = dest.value.trim();
      if (isMail && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(to.split(/[,;]/)[0].trim())) { status.className = "va-status bad"; status.textContent = "Ajoute l'adresse e-mail du destinataire avant de préparer l'envoi."; dest.focus(); return; }
      if (isTeams && !to) { status.className = "va-status bad"; status.textContent = "Indique la conversation Teams cible avant de préparer l'envoi."; dest.focus(); return; }
      prepBtn.disabled = true;
      try {
        const j = await api.post("/api/voix-ahadi/choix", { id: s.id, variante: s.cur, final: s.edits[s.cur], action: "preparer", to, objet: obj.value.trim() }, 20000);
        if (!j || j.ok !== true || !j.draft_id) throw new Error((j && j.error) || "le moteur n'a pas confirmé le brouillon");
        try { bus.emit("nova:draft-new", { source: "voix-ahadi" }); } catch (e) {}
        status.className = "va-status ok";
        body.replaceChildren(h("div", { class: "va-done" },
          h("span", { html: ic("check", 14) }),
          h("span", { class: "grow" }, (j.deja ? "Déjà préparé" : "Brouillon prêt") + " dans Messages, à approuver. Rien n'est parti : l'envoi attend ton ENVOYER."),
          ctx.navigate ? h("button", { class: "btn sm", onclick: () => { ctx.navigate("messages"); setTimeout(() => bus.emit("nova:draft-focus", { id: j.draft_id }), 350); } }, "Voir dans Messages") : null));
        status.textContent = "";
      } catch (e) { prepBtn.disabled = false; status.className = "va-status bad"; status.textContent = "Préparation impossible : " + ((e && e.message) || e); }
    } }, "Préparer pour envoi");
    body.replaceChildren(tabs, v.intention ? h("div", { class: "va-int" }, String(v.intention)) : null, ta, lintEl, fields,
      h("div", { class: "va-actions" }, consigne, h("button", { class: "btn sm ghost", title: "Rédiger 3 nouvelles variantes (avec la consigne si tu en as mis une)", onclick: gen }, "Autres variantes"), h("span", { class: "sp" }), copyBtn, boxBtn(), prepBtn));
  }
  consigne.addEventListener("keydown", (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); gen(); } });
  card.append(panel);
  gen();
}

/* ═══ V5-T (25/10) — CARTE D'ÉCLAT INTERACTIVE ═══════════════════════════════════════
   « je n'arrive pas à interagir avec les messages des Éclats » : une fin d'Éclat
   (kind dot.done) se déplie au clic sur le RÉSULTAT RÉEL du run (GET /api/dots → runs,
   relié par action.run_id, sinon par Éclat + heure la plus proche), avec les seuls
   gestes qui existent déjà au moteur : « Plus tard » (POST /api/dots/snooze) et
   « Marquer vu » (POST /api/dots/ack) quand le run est en file, « Voir le résultat
   complet » (écran Éclats, sur ce run). Rien n'est envoyé, publié, payé ni supprimé :
   ack retire le run de la file d'attente, l'exécution reste dans l'historique. */
const ECLAT_SEEN_KEY = "nova2_eclat_seen_v1";
const eclatSeen = () => { try { const a = JSON.parse(localStorage.getItem(ECLAT_SEEN_KEY) || "[]"); return new Set(Array.isArray(a) ? a : []); } catch (e) { return new Set(); } };
function eclatMarkSeen(k) { if (!k) return; try { const s = eclatSeen(); s.add(String(k)); localStorage.setItem(ECLAT_SEEN_KEY, JSON.stringify([...s].slice(-400))); } catch (e) {} }
export const PENDING_RUN_KEY = "nova2_pending_run";
export function openEclatRun(navigate, runId, dotId) {
  try { localStorage.setItem(PENDING_RUN_KEY, JSON.stringify({ run_id: String(runId || ""), dot: String(dotId || ""), at: Date.now() })); } catch (e) {}
  try { if (navigate) navigate("dots"); } catch (e) {}
  setTimeout(() => { try { bus.emit("nova:eclat-run-focus", { run_id: String(runId || ""), dot: String(dotId || "") }); } catch (e) {} }, 450);
}
const arrIn = (j, k) => (j && Array.isArray(j[k]) ? j[k] : (Array.isArray(j) ? j : []));
/** Retrouve le run d'une carte : run_id exact, sinon même Éclat et heure la plus proche (≤ 20 min). */
export function findRun(runs, runId, dotId, ts) {
  if (runId) { const r = runs.find((x) => x && String(x.id || "") === String(runId)); if (r) return r; }
  if (!dotId) return null;
  const t0 = new Date(ts || 0).getTime() || 0; let best = null, bd = Infinity;
  for (const r of runs) {
    if (!r || String(r.dot || r.dot_id || "") !== String(dotId)) continue;
    const d = Math.abs((new Date(r.ts || 0).getTime() || 0) - t0);
    if (d < bd) { bd = d; best = r; }
  }
  return best && bd <= 20 * 60000 ? best : null;
}
function mountEclatCard(m, p, ctx, card) {
  const h = (ctx && ctx.h) || coreH, md = (ctx && ctx.md) || coreMd, ic = (ctx && ctx.ic) || coreIc;
  const act = m.action && typeof m.action === "object" ? m.action : {};
  const dotId = String(act.dot || m.box || "");
  let runId = String(act.run_id || "");
  const seenKey = () => runId || String(m.feed || "");
  if (runId) card.dataset.run = runId;
  card.classList.add("fc-eclat");
  if (eclatSeen().has(seenKey())) card.classList.add("fc-seen");
  card.setAttribute("tabindex", "0");
  card.setAttribute("aria-expanded", "false");
  card.title = "Cliquer pour le résultat de cette exécution et les actions";
  const panel = h("div", { class: "fc-run", hidden: true, role: "region", "aria-label": "Résultat de l'exécution" });
  const metaEl = card.querySelector(".fc-meta");
  if (metaEl) card.insertBefore(panel, metaEl); else card.append(panel);
  const status = h("div", { class: "fc-run-st", role: "status" });
  let loaded = false;
  const btn = (label, cls, title, fn) => { const b = h("button", { class: "btn sm " + (cls || ""), title: title || "" }, label); b.addEventListener("click", (e) => { e.stopPropagation(); fn(b); }); return b; };
  async function load() {
    panel.replaceChildren(h("div", { class: "fc-run-st" }, "Lecture du résultat de l'exécution…"));
    let runs = [], items = [], waiting = [], err = "";
    try { const j = await api.get("/api/dots", 15000); runs = arrIn(j, "runs"); items = arrIn(j, "items"); } catch (e) { err = String((e && e.message) || e); }
    try { const w = await api.get("/api/dots/waiting", 10000); waiting = arrIn(w, "items"); } catch (e) {}
    const run = findRun(runs, runId, dotId, m.ts);
    if (run && !runId && run.id) { runId = String(run.id); card.dataset.run = runId; }
    const w = runId ? waiting.find((x) => x && String(x.run_id || "") === runId) : null;
    const d = items.find((x) => x && String(x.id || "") === dotId);
    const name = String((d && d.name) || (w && w.name) || dotOf(m));
    const kids = [];
    if (run) {
      const st = run.ok === false ? "échec" : (String(run.status || "").toUpperCase() === "PARTIEL" ? "partiel" : "réussi");
      const when = (() => { const t = new Date(run.ts || 0); return isNaN(t) || !run.ts ? "" : t.toLocaleString("fr-FR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }); })();
      const stShown = isHouse(String(run.result || run.summary || "")) ? "" : " · " + st;   // V5-W : la pastille du rendu maison porte déjà l'état
      kids.push(h("div", { class: "fc-run-head" }, h("b", {}, eclatize(name)), stShown + (when ? " · " + when : "") + (run.ms ? " · " + Math.round(Number(run.ms) / 1000) + " s" : "") + (run.brain ? " · " + String(run.brain) : "")));
    } else {
      kids.push(h("div", { class: "fc-run-head" }, h("b", {}, eclatize(name)), err ? " · moteur injoignable" : " · exécution introuvable parmi les 30 dernières servies par le moteur"));
    }
    /* V5-W : l'état vivant de la file corrige la pastille de tri (« À décider » ↔ « Terminé »). */
    if (card.dataset.decision === "1" && runId) { card.dataset.run = runId; setPri(card, w ? { k: "decision", label: "À décider" } : { k: "done", label: "Terminé" }); }
    let full = String((run && (run.result || run.summary)) || "").trim();
    if (!full && card._houseText) full = String(card._houseText);   // run hors des 30 servis : le texte du fil, mis en page
    const house = isHouse(full);
    if (!house) full = full.replace(/^STATUT\s*:\s*(OK|PARTIEL|ÉCHEC|ECHEC)\s*[—:-]?\s*/i, "");   // le statut est déjà dans l'en-tête
    let houseHasAsk = false; try { houseHasAsk = house && !!parseHouse(full).ask; } catch (e) {}
    if (w && w.decision && w.question && !houseHasAsk) kids.push(h("div", { class: "fc-todo" }, h("b", {}, "À toi · "), String(w.question)));
    if (full) {
      const short = !house && full.length > 1400 ? full.slice(0, 1400) + "…" : full;
      const r = h("div", { class: "fc-run-res" + (house ? " is-house" : "") }); r.innerHTML = md(short); kids.push(r);
    } else if (!run) kids.push(h("div", { class: "fc-run-st" }, "Le texte reçu au fil (ci-dessus) est tout ce que Nova a de ce run ici ; l'écran Éclats garde l'historique complet."));
    const acts = h("div", { class: "fc-run-acts" });
    if (ctx && ctx.navigate) acts.append(btn([h("span", { html: ic("arrow-up-right", 12) }), run ? " Voir le résultat complet" : " Ouvrir dans Éclats"], "", "Ouvre l'écran Éclats sur cette exécution", () => openEclatRun(ctx.navigate, runId, dotId)));
    if (w) {
      acts.append(btn("Plus tard", "ghost", "Reporte d'une heure (POST /api/dots/snooze) — la file d'attente le resservira", async (b) => {
        b.disabled = true;
        try { await api.post("/api/dots/snooze", { run_id: runId, minutes: 60 }, 10000); status.textContent = "Reporté d'une heure — rien d'autre n'a bougé."; }
        catch (e) { b.disabled = false; status.textContent = "Report impossible : " + ((e && e.message) || e); }
      }));
    }
    acts.append(btn([h("span", { html: ic("check", 12) }), " Marquer vu"], w ? "acc" : "", w ? "Acquitte ce run dans la file d'attente (POST /api/dots/ack) — l'exécution reste dans l'historique" : "Marque la carte comme vue (ce run n'est plus en file d'attente)", async (b) => {
      b.disabled = true;
      if (w) { try { await api.post("/api/dots/ack", { run_id: runId }, 10000); } catch (e) { b.disabled = false; status.textContent = "Accusé impossible : " + ((e && e.message) || e); return; } }
      eclatMarkSeen(seenKey()); card.classList.add("fc-seen");
      if (w && card.dataset.decision === "1") { setPri(card, { k: "done", label: "Terminé" }); try { if (WAIT.ids) WAIT.ids.delete(String(runId)); } catch (e) {} }
      status.textContent = w ? "Vu et acquitté — retiré de la file d'attente, l'exécution reste dans l'historique." : "Marqué vu.";
    }));
    kids.push(acts, status);
    if (run && run.id && dotId) kids.push(feedbackBar({ runId: String(run.id), dotId }));   // V6 ÉCLATS : retour d'Ahadi → leçons du prochain passage
    panel.replaceChildren(...kids);
  }
  const toggle = (e) => {
    if (e && e.target && e.target.closest && e.target.closest("a,button,input,textarea,select,summary,.va-panel,.fc-run")) return;
    const open = panel.hidden;
    panel.hidden = !open;
    card.classList.toggle("open", open);
    card.setAttribute("aria-expanded", open ? "true" : "false");
    if (open && !loaded) { loaded = true; load(); }
  };
  card.addEventListener("click", toggle);
  card.addEventListener("keydown", (e) => { if (e.target === card && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); toggle(e); } });
}

/* V5-T : clé LOGIQUE d'une arrivée (au-delà de l'id feed) — une fin d'Éclat = son run ;
   sinon kind|boîte|titre composé. Sert à l'anti-doublon du journal du chat. */
export function logicalKeyOf(m) {
  if (!m || typeof m !== "object") return "";
  const kind = String(m.kind || ""), box = String(m.box || "");
  const rid = m.action && typeof m.action === "object" ? String(m.action.run_id || "") : "";
  if (kind === "suggestion") { const sid = m.action && typeof m.action === "object" ? String(m.action.suggestion_id || "") : ""; if (sid) return "sugg|" + sid; }   // V5-U : une suggestion = son id (deux accroches identiques ne sont pas un doublon)
  if (kind === "dot.done" && rid) return "run|" + rid;
  const p = parseComposed(m.content);
  const t = String(p.bluf || "").replace(/\*\*/g, "").replace(/\s+/g, " ").trim().toLowerCase().slice(0, 140);
  return t ? kind + "|" + box + "|" + t : "";
}

const NAV = { boîtes: "messages", boites: "messages", messages: "messages", dots: "agents", agents: "agents", veille: "veille", feeds: "veille", agenda: "temps", temps: "temps", finance: "finance" };

/* ═══ CANAL FUNDINGS (DOSSIER_fundings §5) ═══════════════════════════════════════
   Format exact : Programme | Décision ou Statut | Montant en jeu | Action requise | Échéance.
   5 catégories normalisées. Un clic = le détail (expéditeur, objet, phrase clé) + la doctrine.
   Jamais de montant visé présenté comme acquis ; aucun bouton d'envoi ni de brouillon ici. */
export const FUNDINGS_CATS = ["APPROBATION", "REFUS", "RÉPONSE ATTENDUE", "ACTION REQUISE", "SIMPLE ACCUSÉ"];
const CAT_META = {
  "APPROBATION": { k: "ok", e: "🟢" }, "REFUS": { k: "bad", e: "🔴" }, "RÉPONSE ATTENDUE": { k: "warn", e: "🟡" },
  "ACTION REQUISE": { k: "act", e: "🟠" }, "SIMPLE ACCUSÉ": { k: "ack", e: "⚪" },
};
export const FUNDINGS_DOCTRINE = "Intégration nommée sous 7 jours pour la démo du 03/11 — jamais présentée comme du cash levé.";
const foldCat = (c) => String(c || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toUpperCase().replace(/_/g, " ").trim();
export function normCategorie(c) { const f = foldCat(c); return FUNDINGS_CATS.find((x) => foldCat(x) === f) || ""; }
export function isFundings(item) {
  if (!item || typeof item !== "object") return false;
  if (item.channel === "fundings" || item.kind === "fundings" || item.box === "fundings") return true;
  return !!(item.programme && normCategorie(item.categorie));
}
export function channelOf(item) {
  if (!item || typeof item !== "object") return "autre";
  if (isFundings(item)) return "fundings";
  const kind = String(item.kind || ""), box = String(item.box || "");
  if (kind === "dot.done" || kind.startsWith("dot.") || item.dot) return "eclats";
  if (kind === "mail.new" || kind === "teams.new" || ["ol", "gm", "tm", "wa", "zm"].includes(box)) return "courrier";
  return "autre";
}
/** Champs d'un événement Fundings : objet de /api/fundings (events) OU message composé du Fil direct. */
export function parseFundings(item) {
  if (!item) return null;
  if (item.programme) {
    return { programme: String(item.programme || ""), categorie: normCategorie(item.categorie) || String(item.categorie || ""), statut: String(item.statut || ""),
      montant: String(item.montant || ""), action: String(item.action || ""), echeance: String(item.echeance || ""), expediteur: String(item.expediteur || ""),
      objet: String(item.objet || ""), phrase_cle: String(item.phrase_cle || ""), source: String(item.source || ""),
      preuve: item.preuve === true ? "message du programme" : "non — statut inchangé", motif: String(item.motif || ""), ts: item.ts || "", id: String(item.id || ""), lu: item.lu === true };
  }
  let txt = String(item.content || "").trim().replace(/\s*\[Ouvrir\s*:\s*[^\]]+\]\s*$/i, "");
  const lines = txt.split(/\n+/).map((l) => l.trim()).filter(Boolean);
  if (!lines.length) return null;
  const first = lines.shift().replace(/^💰\s*/u, "");
  const parts = first.split(" | ").map((x) => x.replace(/\*\*/g, "").trim());
  const f = { programme: parts[0] || "", statut: "", montant: "", action: "", echeance: "", categorie: "", expediteur: "", objet: "", phrase_cle: "", source: "", preuve: "", ts: item.ts || "", id: String(item.feed || ""), lu: true };
  if (parts.length >= 5) { f.echeance = parts[parts.length - 1]; f.action = parts[parts.length - 2]; f.montant = parts[parts.length - 3]; f.statut = parts.slice(1, parts.length - 3).join(" | "); }
  const KEYS = { "Catégorie": "categorie", "De": "expediteur", "Objet": "objet", "Phrase clé": "phrase_cle", "Source": "source", "Preuve": "preuve" };
  for (const l of lines) { const i = l.indexOf(" : "); if (i < 0) continue; const k = KEYS[l.slice(0, i).trim()]; if (k) f[k] = l.slice(i + 3).trim(); }
  f.categorie = normCategorie(f.categorie) || f.categorie;
  return f;
}
export function fundingsBadge(cat, H = coreH) {
  const c = normCategorie(cat), m = CAT_META[c] || { k: "ack", e: "⚪" };
  return H("span", { class: "fb-badge fb-" + m.k, "data-cat": c || "?" }, m.e + " " + (c || String(cat || "—")));
}
const dash = (v) => { const t = String(v || "").trim(); return t && t !== "—" ? t : "—"; };
/* V5-W (25/10) : sous une pastille ACTION REQUISE, jamais « aucune » ni un tiret vide — l'action est tirée
   du statut quand il la nomme (verbe d'action en tête de phrase), sinon « à préciser ». Front seul. */
const isEmptyAction = (a) => { const t = String(a || "").trim().toLowerCase(); return !t || t === "—" || t === "-" || /^(aucune?|néant|neant|rien|none|n\/a|ras)\.?$/.test(t); };
const ACT_VERB = /^(compl[ée]ter|envoyer|fournir|signer|confirmer|valider|r[ée]pondre|t[ée]l[ée]verser|uploader|soumettre|renseigner|mettre à jour|ajouter|joindre|v[ée]rifier|activer|payer|accepter|cr[ée]er|transmettre|remplir|relancer|programmer|choisir|r[ée]server|connecter|lier|associer|pr[ée]ciser|inscrire|candidater|postuler|rappeler)\b/i;
function actionOf(f, cat) {
  if (!isEmptyAction(f.action)) return String(f.action).trim();
  if (cat !== "ACTION REQUISE") return dash(f.action);
  const st = String(f.statut || "").trim();
  const sent = st.split(/(?<=[.;!])\s+|\s+[—–]\s+/).map((x) => x.trim()).find((x) => ACT_VERB.test(x));
  if (sent) return sent.replace(/\s+(?:pour|afin de|afin d')\s.*$/i, "").replace(/[.;]\s*$/, "");
  return "à préciser";
}
const isoDay = (v) => { const t = String(v || "").trim(); const m = /^(\d{4})-(\d{2})-(\d{2})(.*)$/.exec(t); return m ? m[3] + "/" + m[2] + "/" + m[1] + m[4] : t; };
/** Carte d'un événement Fundings (Fil direct ET onglet Feeds). ctx : { h } facultatif. */
export function renderFundingsEvent(item, ctx = {}, live = false) {
  const H = (ctx && ctx.h) || coreH;
  const f = parseFundings(item) || {};
  const cat = normCategorie(f.categorie), meta = CAT_META[cat] || { k: "ack" };
  const time = (() => { const d = new Date(f.ts || 0); return isNaN(d) || !f.ts ? "" : d.toLocaleString("fr-FR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }); })();
  const cell = (label, value, cls = "") => H("div", { class: "fb-cell " + cls }, H("span", { class: "fb-k" }, label), H("span", { class: "fb-v" }, value));
  const due = cat === "ACTION REQUISE" ? H("b", {}, dash(isoDay(f.echeance))) : dash(isoDay(f.echeance));
  const detail = H("div", { class: "fb-detail", hidden: true },
    H("dl", {},
      H("dt", {}, "Expéditeur"), H("dd", {}, dash(f.expediteur)),
      H("dt", {}, "Objet"), H("dd", {}, dash(f.objet)),
      H("dt", {}, "Phrase clé"), H("dd", {}, f.phrase_cle ? "« " + f.phrase_cle + " »" : "—"),
      H("dt", {}, "Source"), H("dd", {}, dash(f.source)),
      H("dt", {}, "Preuve"), H("dd", {}, dash(f.preuve) + (f.motif ? " · " + f.motif : ""))),
    H("p", { class: "fb-doctrine" }, H("b", {}, "Doctrine · "), FUNDINGS_DOCTRINE));
  const card = H("div", { class: "fb-card fb-k-" + meta.k + (live ? " fd-in" : "") + (f.lu === false ? " is-unread" : ""), role: "button", tabindex: "0", "aria-expanded": "false",
    title: "Afficher le détail (expéditeur, objet, phrase clé)" },
    H("div", { class: "fb-head" }, fundingsBadge(cat || f.categorie, H), H("span", { class: "fb-chan" }, "Fundings"), H("span", { class: "sp" }), H("span", { class: "fb-time" }, time)),
    H("div", { class: "fb-row" },
      cell("Programme", dash(f.programme), "fb-prog"),
      cell("Décision ou statut", dash(f.statut || cat)),
      cell("Montant en jeu", dash(f.montant), "fb-num"),
      cell("Action requise", actionOf(f, cat), isEmptyAction(f.action) && cat === "ACTION REQUISE" ? "fb-derived" : ""),
      cell("Échéance", due, "fb-num")),
    detail);
  const toggle = (e) => {
    if (e && e.target && e.target.closest && e.target.closest("a,button")) return;
    detail.hidden = !detail.hidden; card.setAttribute("aria-expanded", detail.hidden ? "false" : "true");
    if (!detail.hidden && f.lu === false && f.id && ctx && ctx.markRead) { try { ctx.markRead(f.id); card.classList.remove("is-unread"); } catch (er) {} }
  };
  card.addEventListener("click", toggle);
  card.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggle(e); } });
  return card;
}
const countdown = (n) => n == null ? "" : n === 0 ? "aujourd'hui" : n === 1 ? "demain" : "J-" + n;
const ddmm = (d) => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(d || "")); return m ? m[3] + "/" + m[2] + (m[1] !== String(new Date().getFullYear()) ? "/" + m[1].slice(2) : "") : String(d || ""); };
/** Bandeau PERMANENT des 3 prochaines échéances du §4 (GET /api/fundings). Retourne { el, refresh, destroy }. */
export async function mountFundingsBand(container, ctx = {}) {
  const H = (ctx && ctx.h) || coreH, A = (ctx && ctx.api) || api, B = (ctx && ctx.bus) || bus;
  const band = H("div", { class: "fb-band", role: "region", "aria-label": "Fundings — 3 prochaines échéances" });
  if (container) container.append(band);
  let dead = false;
  const paint = (j) => {
    const list = j && Array.isArray(j.prochaines) ? j.prochaines
      : (j && Array.isArray(j.echeances) ? j.echeances.filter((e) => Number(e.days_left) >= 0).slice(0, 3) : null);
    const head = H("span", { class: "fb-band-t" }, "💰 Fundings · prochaines échéances");
    if (!list) { band.replaceChildren(head, H("span", { class: "fb-band-empty" }, "Campagne Fundings : le moteur n'a rien servi pour le moment.")); return; }
    if (!list.length) { band.replaceChildren(head, H("span", { class: "fb-band-empty" }, "Aucune échéance à venir dans le dossier.")); return; }
    band.replaceChildren(head, ...list.slice(0, 3).map((e) => {
      const n = Number(e.days_left);
      return H("span", { class: "fb-due" + (n <= 2 ? " soon" : ""), title: String(e.label || "") },
        H("b", { class: "fb-due-d" }, ddmm(e.date) + (e.heure ? " " + e.heure : "")),
        H("span", { class: "fb-due-l" }, String(e.label || "")),
        H("span", { class: "fb-due-c" }, (e.approx ? "≈ " : "") + countdown(isFinite(n) ? n : null)));
    }));
  };
  const refresh = async () => { if (dead) return; try { const j = await A.get("/api/fundings", 15000); if (!dead) paint(j); } catch (e) { if (!dead) band.replaceChildren(H("span", { class: "fb-band-t" }, "💰 Fundings"), H("span", { class: "fb-band-empty" }, "Échéances injoignables pour le moment.")); } };
  band.replaceChildren(H("span", { class: "fb-band-t" }, "💰 Fundings · prochaines échéances"), H("span", { class: "fb-band-empty" }, "Lecture…"));
  let off = null; try { off = B.on("fundings", () => refresh()); } catch (e) {}
  await refresh();
  return { el: band, refresh, destroy() { dead = true; try { if (off) off(); } catch (e) {} try { band.remove(); } catch (e) {} } };
}

/* ═══ V5-U (25/10) — « NOVA TE PROPOSE » : carte de suggestion au format Muse ═══════════════════════
   Champs lus dans l'ACTION du message (moteur : Feat_Suggestions.swift → App.swift, action.type
   "suggestion") : suggestion_id, kind (lecture | a_voir | opportunite | a_faire), url, title, source,
   why, ideas[3] {titre, detail}, limit, dossier, headline, verified. Repli : le texte composé (museText).
   Fermée : accroche · titre lié — source · « Ça compte pour toi parce que … ». Ouverte (clic, Entrée) :
   les 3 idées clés, la petite limite honnête, la vérification, et les gestes — Lire (volet Navigateur
   de Nova : nova2_pending_url + nova:open-url), Approfondir (nouvelle conversation PRÉ-REMPLIE, jamais
   envoyée), Plus tard / Pas pertinent / Utile (POST /api/suggestions/feedback). Rien n'est envoyé. */
export const SUGG_KIND = { lecture: "Lecture", a_voir: "À voir", opportunite: "Opportunité", a_faire: "À faire" };
const SUGG_SEEN_KEY = "nova2_sugg_verdicts_v1";
export const PENDING_SUGG_KEY = "nova2_pending_sugg";
const suggVerdicts = () => { try { const o = JSON.parse(localStorage.getItem(SUGG_SEEN_KEY) || "{}"); return o && typeof o === "object" ? o : {}; } catch (e) { return {}; } };
function suggSetVerdict(id, v) { if (!id) return; try { const o = suggVerdicts(); o[id] = v; const ks = Object.keys(o); if (ks.length > 300) for (const k of ks.slice(0, ks.length - 300)) delete o[k]; localStorage.setItem(SUGG_SEEN_KEY, JSON.stringify(o)); } catch (e) {} }
/** Suggestion normalisée depuis un message du Fil direct (action) ou un élément de GET /api/suggestions. */
export function suggestionOf(m) {
  const a = m && m.action && typeof m.action === "object" && m.action.type === "suggestion" ? m.action : null;
  const src = a || (m && m.suggestion_id ? m : null) || (m && m.id && m.ideas ? m : null);
  if (src) {
    return { id: String(src.suggestion_id || src.id || ""), kind: String(src.kind || src.suggestion_kind || ""), url: String(src.url || ""), title: String(src.title || (m && m.title) || ""),
      source: String(src.source || ""), why: String(src.why || ""), ideas: Array.isArray(src.ideas) ? src.ideas.slice(0, 3) : [], limit: String(src.limit || ""),
      dossier: String(src.dossier || ""), headline: String(src.headline || ""), verified: String(src.verified || "") };
  }
  /* Repli : texte composé par le moteur (SuggestKit.museText). */
  const lines = String((m && m.content) || "").split(/\n+/).map((l) => l.trim()).filter(Boolean);
  const o = { id: "", kind: "", url: "", title: "", source: "", why: "", ideas: [], limit: "", dossier: "", headline: lines[0] || "", verified: "" };
  for (const l of lines.slice(1)) {
    let r;
    if ((r = /^\[(.+?)\]\((https?:[^)\s]+)\)(?:\s+—\s+(.+?))?\.?$/.exec(l))) { o.title = r[1]; o.url = r[2]; o.source = r[3] || ""; continue; }
    if ((r = /^\*\*(.+?)\*\*(?:\s+—\s+(.+?))?\.?$/.exec(l))) { o.title = r[1]; o.source = r[2] || ""; continue; }
    if ((r = /^Ça compte pour toi parce que\s+(.*)$/i.exec(l))) { o.why = r[1].replace(/^\s*(ç|c)a compte pour toi parce que\s*/i, ""); continue; }
    if ((r = /^Petite limite honnête\s*:\s*(.*)$/i.exec(l))) { o.limit = r[1]; continue; }
    if ((r = /^[•*-]\s+(.+)$/.exec(l))) { const [t, ...d] = r[1].split(" — "); o.ideas.push({ titre: t, detail: d.join(" — ") }); }
  }
  return o;
}
function openUrlInNova(navigate, url) {
  if (!/^https?:\/\//i.test(String(url || ""))) return;
  try { localStorage.setItem("nova2_pending_url", JSON.stringify({ url, at: Date.now() })); } catch (e) {}
  try { if (navigate) navigate("messages"); } catch (e) {}
  setTimeout(() => { try { bus.emit("nova:open-url", { url }); } catch (e) {} }, 60);
}
/** Texte de départ d'« Approfondir » — posé dans le champ d'une NOUVELLE conversation, jamais envoyé. */
export function deepenPrompt(sg) {
  const ideas = (sg.ideas || []).map((i, k) => (k + 1) + ") " + String(i.titre || "") + (i.detail ? " — " + String(i.detail) : "")).join(" ");
  return "Approfondissons ta suggestion « " + sg.title + " »" + (sg.source ? " (" + sg.source + ")" : "") + (sg.url ? " : " + sg.url : "") + ".\n"
    + (sg.why ? "Pourquoi tu me l'as proposée : " + sg.why + "\n" : "")
    + (ideas ? "Les idées clés : " + ideas + "\n" : "")
    + (sg.url ? "Relis la page, puis dis-moi concrètement ce que j'en retire" : "Aide-moi à m'y préparer concrètement") + (sg.dossier ? " pour mon dossier « " + sg.dossier + " »" : "") + ", et ce qui reste à vérifier.";
}
export function startDeepen(navigate, text) {
  try { if (navigate) navigate("conversations"); } catch (e) {}
  setTimeout(() => { try { bus.emit("nova:new-conv", {}); } catch (e) {} }, 140);
  let tries = 0;
  const fill = () => {
    const tas = [...document.querySelectorAll('.mod[data-mod="conversations"] .composer textarea')];
    const t = tas.find((x) => x.offsetParent) || tas[0];
    if (!t) { if (tries++ < 40) setTimeout(fill, 150); else showToast("Conversation introuvable — le texte n'a pas été placé.", true); return; }
    t.value = text;
    try { t.dispatchEvent(new Event("input", { bubbles: true })); } catch (e) {}
    try { t.focus(); t.setSelectionRange(t.value.length, t.value.length); } catch (e) {}
    showToast("Nouvelle conversation pré-remplie — rien n'est envoyé tant que tu n'appuies pas sur Entrée.");
  };
  setTimeout(fill, 520);
}
export function renderSuggestionCard(m, ctx, live = false) {
  const h = (ctx && ctx.h) || coreH, ic = (ctx && ctx.ic) || coreIc;
  const navigate = ctx && ctx.navigate;
  const sg = suggestionOf(m);
  const time = (() => { const d = new Date(m.ts || 0); return isNaN(d) || !m.ts ? "" : d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" }); })();
  const card = h("div", { class: "msg nova direct-msg fc fc-sugg" + (live ? " fd-in" : ""), "data-pri": "sugg", "data-sugg": sg.id, tabindex: "0", "aria-expanded": "false",
    title: "Cliquer pour les 3 idées clés et les actions" });
  const verdict = suggVerdicts()[sg.id] || "";
  if (verdict) card.classList.add("fc-seen", "v-" + verdict);
  card.append(h("div", { class: "fc-head" },
    h("span", { class: "fc-src" }, h("span", { html: ic("sparkle", 14) }), "Nova te propose"),
    h("span", { class: "fc-pri p-sugg" }, SUGG_KIND[sg.kind] || "Suggestion"),
    h("span", { class: "sp" }),
    h("span", { class: "fc-time" }, time)));
  card.append(h("div", { class: "fc-sg-hl" }, sg.headline || "Nova te propose quelque chose."));
  const tl = sg.url
    ? h("a", { class: "fc-sg-title", href: sg.url, title: "Lire dans Nova (volet Navigateur)", onclick: (e) => { e.preventDefault(); e.stopPropagation(); openUrlInNova(navigate, sg.url); } }, sg.title)
    : h("b", { class: "fc-sg-title" }, sg.title);
  card.append(h("div", { class: "fc-sg-line" }, tl, sg.source ? h("span", { class: "fc-sg-src" }, " — " + sg.source) : null));
  if (sg.why) card.append(h("p", { class: "fc-sg-why" }, h("b", {}, "Ça compte pour toi parce que "), sg.why));
  const hint = h("div", { class: "fc-sg-hint" }, (sg.kind === "a_faire" ? "3 gestes pour t'y préparer" : (sg.kind === "a_voir" ? "Ce qu'il faut regarder" : "3 idées clés")) + " · petite limite honnête", h("span", { html: ic("chev-d", 12) }));
  card.append(hint);
  const panel = h("div", { class: "fc-sg-body", hidden: true, role: "region", "aria-label": "Détail de la suggestion" });
  panel.append(h("div", { class: "fc-sg-h" }, sg.kind === "a_faire" ? "Pour t'y préparer :" : (sg.kind === "a_voir" ? "Ce qu'il faut regarder :" : "Les 3 idées clés que tu en retireras :")));
  panel.append(h("ul", { class: "fc-sg-ideas" }, ...sg.ideas.map((i) => h("li", {}, h("b", {}, String(i.titre || "")), i.detail ? " — " + String(i.detail) : ""))));
  if (sg.limit) panel.append(h("p", { class: "fc-sg-limit" }, h("b", {}, "Petite limite honnête : "), sg.limit));
  const metaBits = [sg.dossier ? "Dossier : " + sg.dossier : "", sg.verified].filter(Boolean);
  if (metaBits.length) panel.append(h("div", { class: "fc-sg-ver" }, h("span", { html: ic("check", 11) }), metaBits.join(" · ")));
  const status = h("div", { class: "fc-run-st", role: "status" });
  const btn = (label, cls, title, fn) => { const b = h("button", { class: "btn sm " + (cls || ""), title: title || "" }, label); b.addEventListener("click", (e) => { e.stopPropagation(); fn(b); }); return b; };
  const feedback = async (b, v, done) => {
    if (!sg.id) { status.textContent = "Suggestion sans identifiant — avis non transmis."; return; }
    b.disabled = true;
    try {
      const j = await api.post("/api/suggestions/feedback", { id: sg.id, verdict: v }, 10000);
      if (!j || j.ok !== true) throw new Error((j && j.error) || "réponse sans ok");
      suggSetVerdict(sg.id, v); card.classList.add("fc-seen"); card.classList.remove("v-utile", "v-pas_pertinent", "v-plus_tard"); card.classList.add("v-" + v);
      status.textContent = done;
    } catch (e) { b.disabled = false; status.textContent = "Avis non transmis : " + ((e && e.message) || e); }
  };
  const acts = h("div", { class: "fc-run-acts fc-sg-acts" });
  if (sg.url) acts.append(btn([h("span", { html: ic("arrow-up-right", 12) }), " Lire"], "acc", "Ouvre la page dans le volet Navigateur de Nova", () => openUrlInNova(navigate, sg.url)));
  acts.append(btn([h("span", { html: ic("sparkle", 12) }), " Approfondir"], "", "Nouvelle conversation pré-remplie avec cette suggestion — rien n'est envoyé sans toi", () => startDeepen(navigate, deepenPrompt(sg))));
  acts.append(btn("Plus tard", "ghost", "Nova te la reproposera dans quelques heures (une fois)", (b) => feedback(b, "plus_tard", "Reportée — Nova te la reproposera au prochain créneau, une seule fois.")));
  acts.append(btn("Pas pertinent", "ghost", "Nova proposera moins ce sujet", (b) => feedback(b, "pas_pertinent", "Noté — ce sujet sera proposé moins souvent.")));
  acts.append(btn([h("span", { html: ic("check", 12) }), " Utile"], "ghost", "Nova proposera davantage ce sujet", (b) => feedback(b, "utile", "Merci — ce sujet comptera davantage.")));
  panel.append(acts, status);
  card.append(panel);
  const toggle = (e, force) => {
    if (e && e.target && e.target.closest && e.target.closest("a,button,input,textarea,select,.fc-sg-body")) return;
    const open = force != null ? force : panel.hidden;
    panel.hidden = !open; hint.hidden = open;
    card.classList.toggle("open", open);
    card.setAttribute("aria-expanded", open ? "true" : "false");
  };
  card.addEventListener("click", (e) => toggle(e));
  card.addEventListener("keydown", (e) => { if (e.target === card && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); toggle(e); } });
  /* Ouverture demandée depuis l'Accueil (tuile « Nova te propose ») : la carte se déplie et vient à l'écran. */
  try { const p = localStorage.getItem(PENDING_SUGG_KEY); if (p && sg.id && p === sg.id) { localStorage.removeItem(PENDING_SUGG_KEY); setTimeout(() => { toggle(null, true); try { card.scrollIntoView({ block: "center", behavior: "smooth" }); } catch (e) {} }, 300); } } catch (e) {}
  if (live) { try { window.dispatchEvent(new CustomEvent("nova:feed-arrival", { detail: { gravite: "", urgent: false, kind: "suggestion" } })); } catch (e) {} }
  return card;
}

/** Construit la carte. ctx : { h, md, ic, navigate }. live : vraie arrivée (animation + réaction du compagnon). */
export function renderFeedCard(m, ctx, live = false) {
  if (String((m && m.kind) || "") === "suggestion") { try { return renderSuggestionCard(m, ctx, live); } catch (e) {} }
  if (String((m && m.kind) || "") === "journal.soir") { try { return renderJournalSoirCard(m, ctx, live); } catch (e) {} }   // LOT3 (25/10) : Journal du soir (bouton Dicter)   // V5-U : « Nova te propose »
  if (isFundings(m)) {   // V4-C : un événement Fundings garde le format fermé du §5 (pas de tri, pas de réponse proposée)
    const fc = renderFundingsEvent(m, ctx, live);
    if (live) { try { window.dispatchEvent(new CustomEvent("nova:feed-arrival", { detail: { gravite: m.gravite || "", urgent: m.urgent === true, kind: "fundings" } })); } catch (e) {} }
    return fc;
  }
  const h = (ctx && ctx.h) || coreH, md = (ctx && ctx.md) || coreMd, ic = (ctx && ctx.ic) || coreIc;
  const p = parseComposed(m.content);
  /* 25/10 (Ahadi : « les messages des Éclats sont toujours bizarres ») : un run d'Éclat SANS contenu
     (« le run n'a pas joint de résumé. Rien à faire de ton côté. ») n'est plus affiché du tout. */
  const isDot = String((m && m.kind) || "") === "dot.done";
  if (isDot) {
    const all = [p.bluf || ""].concat(p.note || []).join(" ").replace(/\s+/g, " ").trim();
    const emptyRun = /n'a pas joint de r[ée]sum[ée]|rien [àa] faire de ton c[ôo]t[ée]\s*\.?$/i.test(all) && all.length < 220;
    if (emptyRun) return (ctx && ctx.h ? ctx.h : coreH)("div", { class: "fc-skip", hidden: "" });
    p.note = (p.note || []).map((t) => { const x = String(t || "").trim(); return x ? x.charAt(0).toUpperCase() + x.slice(1) : x; });
  }
  const src = sourceOf(m), pri = priorityOf(m, p, live);
  const time = (() => { const d = new Date(m.ts || 0); return isNaN(d) || !m.ts ? "" : d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" }); })();
  const card = h("div", { class: "msg nova direct-msg fc" + (live ? " fd-in" : ""), "data-pri": pri.k });
  if (isDot) { try { card.dataset.dot = dotOf(m); } catch (e) {} }
  const isDecision = !!(m.action && m.action.type === "decision");
  if (isDecision) { card.dataset.decision = "1"; if (m.action.run_id) card.dataset.run = String(m.action.run_id); refreshWaiting(); }
  card.append(h("div", { class: "fc-head" },
    h("span", { class: "fc-src" }, h("span", { html: ic(src.icon, 14) }), src.label),
    h("span", { class: "fc-pri p-" + pri.k }, pri.label),
    h("span", { class: "sp" }),
    h("span", { class: "fc-time" }, time)));
  /* STYLE-MUSE : pastille de qualification (R2) + niveau justifié (R3) — le niveau ne
     s'affiche en couleur que s'il est URGENT ou HAUT, avec sa justification datée. */
  if (p.qual || p.niveau) {
    const qk = p.qual === "CONFIRMATION" ? "confirmation" : (p.qual === "RELANCE" ? "relance" : "nouveau");
    const row = h("div", { class: "fc-qualrow" });
    if (p.qual) row.append(h("span", { class: "fc-qual q-" + qk }, p.qual === "FAIT NOUVEAU" ? "Fait nouveau" : (p.qual === "RELANCE" ? "Relance" : "Confirmation")));
    if (p.niveau === "URGENT" || p.niveau === "HAUT") row.append(h("span", { class: "fc-niveau n-" + p.niveau.toLowerCase() }, p.niveau + (p.niveauWhy ? " — " + p.niveauWhy : "")));
    else if (p.niveau) row.append(h("span", { class: "fc-niveau n-calme" }, p.niveau.toLowerCase()));
    card.append(row);
  }
  const bl = h("div", { class: "fc-bluf" }); bl.innerHTML = md(p.bluf || "(événement sans titre)"); card.append(bl);
  /* V5-W : un commentaire au format maison se replie en UNE ligne propre (pastille d'état + résumé +
     mini-états des sections) ; le détail mis en page vit dans le panneau déplié. « À TOI » → À toi. */
  let urgentLine = "";
  if (isDot && isRoutineFailure(m)) {
    card.classList.add("fc-compact");
    p.note = p.note.map((t) => String(t).replace(/\s*[ÀA] regarder dans l'[ée]cran [ÉE]clats\.?/i, "").trim()).filter(Boolean);
  } else if (isDot && p.note.length && !isHouse(p.note.join("\n"))) {
    /* « … URGENT — e-Visa Thaïlande : … » : le segment urgent sort du paragraphe et passe en ligne mise en évidence. */
    const joined = p.note.join(" ");
    const mU = joined.match(/\bURGENT\s*[—:–-]\s*(.+?)(?:\s+Action\b.*)?$/);
    if (mU) { urgentLine = mU[1].trim(); const before = joined.slice(0, mU.index).replace(/[\s.;,—-]+$/, "").trim(); p.note = before ? [before] : []; }
  }
  const noteTxt = p.note.join("\n");
  let houseAsk = "";
  if (p.note.length && isHouse(noteTxt)) {
    const n = h("div", { class: "fc-note is-house" }); n.innerHTML = houseCompactHTML(noteTxt, false); card.append(n);
    try { houseAsk = parseHouse(noteTxt).ask; } catch (e) {}
    card.dataset.house = "1"; card._houseText = noteTxt;
  } else if (p.note.length) {
    /* 25/10 : titres markdown aplatis au milieu d'une ligne (« … lus. ## Urgent - … ») et jargon d'outil
       entre parenthèses (« (mail_week timeout, teams_read déjà appelé) ») ne s'affichent plus bruts. */
    let nt = noteTxt.replace(/\s*#{1,4}\s+([^\n#-]{2,40}?)\s*[-—:]\s*/g, "\n\n**$1** — ").replace(/\s*#{1,4}\s+/g, "\n\n");
    nt = nt.replace(/\s*\((?:[^()]*\b(?:mail_week|mail_unread|mail_corps|teams_read|timeout|déjà appelé|deja appele)\b[^()]*)\)/gi, "");
    const n = h("div", { class: "fc-note" }); n.innerHTML = md(nt.trim()); card.append(n);
  }
  if (urgentLine) card.append(h("div", { class: "fc-todo fc-urgent-line" }, h("b", {}, "Urgent · "), urgentLine));
  if (p.todo || houseAsk) card.append(h("div", { class: "fc-todo" }, h("b", {}, "À toi · "), p.todo || houseAsk));
  if (p.due) card.append(h("div", { class: "fc-due" }, "Échéance : ", h("b", {}, p.due)));
  if (p.dots) card.append(h("div", { class: "fc-dots" }, p.dots + (p.priWhy ? " — " + p.priWhy : "")));
  /* 25/10 (Ahadi : « lire intégralement le contenu des messages ») : quand le corps a été LU par le moteur
     (corps_etat « lu », ou extrait présent dans le texte composé), le dépliant charge le message COMPLET
     à l'ouverture (GET /api/mail/corps — lecture seule des magasins, rien n'est relu ni marqué lu).
     Échec ou corps absent : l'extrait reste affiché, avec l'état honnête. */
  const mailLike = ["mail.new", "teams.new"].includes(String(m.kind || ""));
  const corpsEtat = String(m.corps_etat || "");
  const canFull = mailLike && m.feed != null && String(m.feed) !== "" && (corpsEtat === "lu" || (!!p.extract && corpsEtat === ""));
  if (canFull) {
    const zone = h("div", { style: "max-height:420px;overflow:auto" }, p.extract || "Ouvre pour lire le message complet.");
    const det = h("details", { class: "fc-extract fc-full" }, h("summary", {}, "Lire le message complet"), zone);
    let fetched = false;
    det.addEventListener("toggle", async () => {
      if (!det.open || fetched) return;
      fetched = true;
      zone.textContent = "Lecture du corps au magasin de Nova…";
      try {
        const j = await api.get("/api/mail/corps?feed=" + encodeURIComponent(String(m.feed)), 12000);
        if (j && j.ok && j.body) {
          zone.textContent = tidyBody(String(j.body));
          if (j.extrait) zone.append(h("div", { class: "fc-run-st" }, "(extrait du journal : le corps complet a quitté le magasin borné)"));
        } else {
          const st = String((j && j.state) || "non lu");
          zone.textContent = (p.extract ? p.extract + "\n\n" : "") + "Corps complet indisponible — état : " + st + ".";
        }
      } catch (e) {
        fetched = false;
        zone.textContent = (p.extract ? p.extract + "\n\n" : "") + "Lecture impossible pour l'instant : " + String((e && e.message) || e);
      }
    });
    card.append(det);
  } else if (p.extract) card.append(h("details", { class: "fc-extract" }, h("summary", {}, "Extrait du message"), h("div", {}, p.extract)));
  const meta = h("div", { class: "fc-meta" }, h("span", { class: "fc-dot", title: "Pris en charge par" }, h("i", {}), eclatize(dotOf(m))));
  for (const l of (isDot ? linkMemory(m, p).filter((x) => /^Dossier /.test(x.t)).slice(0, 1) : linkMemory(m, p))) meta.append(h("span", { class: "fc-mem" + (l.fresh ? " new" : ""), title: "Mémoire de Nova" }, l.t));
  meta.append(h("span", { class: "sp" }));
  if (attendReponse(m, p)) {
    const rb = h("button", { class: "btn sm va-btn", title: "Nova rédige 3 variantes courtes dans ta voix — rien n'est créé ni envoyé sans toi" }, h("span", { html: ic("draft", 12) }), "Préparer une réponse");
    rb.addEventListener("click", () => { rb.disabled = true; rb.style.display = "none"; try { vaPanel(m, p, ctx, card, rb); } catch (e) { rb.disabled = false; rb.style.display = ""; } });
    meta.append(rb);
  }
  /* 26/10 (format Muse) : [Vu] [Plus tard] sur les arrivées de messages — état gardé dans ce navigateur, rien n'est marqué lu dans la boîte. */
  if (mailLike && m.feed != null && String(m.feed) !== "") {
    const fid = String(m.feed);
    const vu = h("button", { class: "btn sm ghost", title: "Marquer vu ici (la boîte n'est pas touchée)" }, "Vu");
    vu.addEventListener("click", () => { fcSeen(fid, 0); card.classList.add("fc-seen"); vu.disabled = true; vu.textContent = "Vu ✓"; });
    const later = h("button", { class: "btn sm ghost", title: "Reporter : la carte se replie et revient en tête dans 3 h" }, "Plus tard");
    later.addEventListener("click", () => { const until = Date.now() + 3 * 3600000; fcSeen(fid, until); card.classList.add("fc-snoozed"); later.disabled = true; later.textContent = "Revient à " + new Date(until).toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" }); });
    meta.append(vu, later);
    const st = fcSeenState(fid);
    if (st && st.until === 0) { card.classList.add("fc-seen"); vu.disabled = true; vu.textContent = "Vu ✓"; }
    else if (st && st.until > Date.now()) { card.classList.add("fc-snoozed"); later.disabled = true; later.textContent = "Revient à " + new Date(st.until).toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" }); }
  }
  if (p.open && ctx.navigate) {
    const target = NAV[p.open.toLowerCase()] || "";
    if (target) meta.append(h("button", { class: "btn sm ghost", onclick: () => ctx.navigate(target) }, (target === "agents" ? "Voir dans Éclats" : "Ouvrir " + p.open), h("span", { html: ic("arrow-up-right", 12) })));
  }
  card.append(meta);
  if (mailLike) { try { mountAutoDraft(m, { h, ic, navigate: ctx && ctx.navigate }, card).catch(() => {}); } catch (e) {} }   // 25/10 AUTONOMIE : brouillon prêt à valider
  if (String(m.kind || "") === "dot.done") { try { mountEclatCard(m, p, { h, md, ic, navigate: ctx && ctx.navigate }, card); } catch (e) {} }   // V5-T : carte d'Éclat cliquable
  if (live) { try { const rf = isRoutineFailure(m); window.dispatchEvent(new CustomEvent("nova:feed-arrival", { detail: { gravite: rf ? "" : (m.gravite || ""), urgent: rf ? false : m.urgent === true, kind: m.kind || "" } })); } catch (e) {} }
  return card;
}
