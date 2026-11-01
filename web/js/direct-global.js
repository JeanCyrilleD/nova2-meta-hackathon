/* ═══════════════════════════════════════════════════════════════════════════
   DIRECT GLOBAL + DOTS QUI VIENNENT À AHADI (ordres d'Ahadi, 20/10/2026 22:44)

   Avant : le « Fil Direct » vivait ENFERMÉ dans l'écran Agent (modules/direct.js,
   monté par agent.js) — fermé avec l'écran, invisible partout ailleurs ; et les
   Dots restaient passifs dans leur parc : Ahadi devait aller les chercher.

   Désormais le Direct est un SERVICE DU SHELL (shell.js l'instancie une fois) :
     · il SONDE les sources réelles du moteur (mêmes routes que l'ancien fil :
       /api/mailapi/unread, /api/dots/waiting, /api/commitments, /api/briefs) ;
     · il ÉCOUTE le bus serveur partagé (core.js) : « nova:dot-run » (un Dot
       vient de tourner), « nova:brief-new », « nova:commitment »,
       « nova:meeting » — un Dot qui finit un travail devient un événement
       Direct dont le Dot est l'émetteur VISIBLE (avatar + nom) ;
     · il expose une API publique d'injection, utilisable par n'importe quel
       module ou par le pont UI :  window.NovaDirect.push({dot, titre, corps,
       action})  et  ctx.direct.push(…) ;
     · il détient LA source unique de l'état « vu / plus tard » (localStorage
       « nova2_direct_seen_v1 », MÊME clé que l'ancien fil : l'historique d'Ahadi
       est conservé) — marquer « Vu » à un endroit met à jour TOUS les panneaux
       (événement « nova:direct-state ») ;
     · il ÉMET sur le bus : « nova:direct-item » (nouvel item, une fois) et
       « nova:direct-state » (liste + état, à chaque changement). L'écran Agent
       s'y abonne PAR PANNEAU : l'item arrive en carte dans la conversation
       principale et en bandeau non destructif dans les autres panneaux ouverts.

   Règles : le Direct PROPOSE, n'envoie jamais rien (RÈGLE D'OR n°2) ; aucun
   bring-to-front, aucune interruption de saisie — l'item se pose et attend.
   Limite dite : ce service vit dans la fenêtre web ; app fermée ou écran Agent
   jamais ouvert, aucun panneau ne peut afficher l'item (le sondage continue
   tant que l'app est ouverte, les items non vus restent en file et sont
   livrés à la prochaine ouverture d'un panneau). La génération d'événements
   « app fermée » relève du moteur/Swift — voir LISEZ-MOI.md.
   ═══════════════════════════════════════════════════════════════════════════ */

const SEEN_KEY = "nova2_direct_seen_v1";
const SNOOZE_KEY = "nova2_direct_snooze_v1";
/* V4-D (24/10) — FIL DIRECT UNIFIÉ SUR LE BUS SSE : plus de sondage fixe (30 s ici + 45 s
   dans prochat.js = double sondage des mêmes routes). Les relectures partent désormais des
   événements moteur (direct.appended, dot, brief, commitment, mail.new, teams.new, meeting),
   du retour au premier plan, et du CHIEN DE GARDE ci-dessous (45 s) quand le flux /api/events
   est coupé. Filet lent unique : SWEEP_MS, pour les échéances qui DEVIENNENT dues avec le
   temps (aucun événement ne les signale). */
export const WATCHDOG_MS = 45000;
export const SWEEP_MS = 10 * 60 * 1000;
/* Chien de garde du flux SSE partagé (core.js appartient au lot A : il vit ici).
   Les battements du moteur (« : ping » toutes les 15 s) sont des commentaires SSE
   invisibles au JS : on se fie donc aux événements « error » / « open » du flux
   partagé. Flux coupé → onStale() toutes les 45 s jusqu'au retour ; retour du flux
   → onStale() une fois (rattrapage). Renvoie stop(). */
export function sseWatchdog(bus, onStale, ms = WATCHDOG_MS) {
  let down = false, t = 0, stopped = false;
  const offs = [];
  const tick = () => { t = 0; if (stopped || !down) return; try { onStale("watchdog"); } catch (e) {} t = setTimeout(tick, ms); };
  try { offs.push(bus.on("error", () => { if (stopped) return; if (!down) { down = true; if (!t) t = setTimeout(tick, ms); } })); } catch (e) {}
  try { offs.push(bus.on("open", () => { if (stopped) return; const was = down; down = false; if (t) { clearTimeout(t); t = 0; } if (was) { try { onStale("reconnect"); } catch (e) {} } })); } catch (e) {}
  return () => { stopped = true; if (t) clearTimeout(t); offs.forEach((o) => { try { o(); } catch (e) {} }); };
}
const MAX_ITEMS = 30;

/* DS §9.8 : cleanResume / truncWords vivent dans core.js (source unique) — les copies
   locales, déjà divergentes entre modules (140 vs 220 caractères), sont supprimées.
   Le service expose titre, corps, dot, tags, at et action : c'est exactement ce que
   le bandeau enrichi DS §9.3 consomme (ligne 1 titre + compteur, ligne 2 .direct-body). */
import { cleanResume, truncWords, fmtDateFR } from "./core.js";
const fmtEch = (v) => { const t = String(v || ""); const d = new Date(t + "T12:00:00"); return t && !isNaN(d) ? new Intl.DateTimeFormat("fr-FR", { weekday: "short", day: "numeric", month: "short" }).format(d) : (fmtDateFR(t) || t); };

/* Repères de dossier — même heuristique locale que l'ancien fil (RH, GHO…). */
const TAG_RULES = [
  [/\brh\b|ressources humaines|human resources/i, "Dossier : RH"],
  [/recrutement|recruitment/i, "Recrutement"],
  [/gho|global outlook/i, "GHO 2027"],
  [/visa|e-visa|voyage|travel/i, "Voyage / visa"],
  [/paiement|payment|facture|invoice|virement/i, "Paiements"],
  [/brvm|bourse/i, "BRVM"],
  [/urgent|deadline|échéance|rappel|avant le|dès que possible/i, "À traiter vite"],
];
const tagsFor = (from, subject) => {
  const hay = String(from || "") + " " + String(subject || "");
  const out = [];
  for (const [re, label] of TAG_RULES) if (re.test(hay) && !out.includes(label)) out.push(label);
  return out.slice(0, 2);
};

/**
 * Crée le service Direct. À appeler UNE fois (shell.js).
 * @param {{api:object, bus:object}} deps — l'api et le bus de core.js.
 * @returns service { list, push, markSeen, snooze, ackWaiting, refresh, start, stop }
 * Item Direct : { key, kind: "mail"|"waiting"|"due"|"brief"|"dot"|"push",
 *   dot: {name, emoji, color} | null, titre, corps, tags: [], at,
 *   action: {label, module?, run?, href?} | null, runId? }
 */
export function createDirectService({ api, bus }) {
  let stopped = false;
  let timer = 0;
  const items = new Map();       // key → item (ordre d'arrivée)
  const announced = new Set();   // keys déjà émises en « nova:direct-item »

  /* ── État partagé « vu / plus tard » — LA source unique ─────────────── */
  const loadSeen = () => { try { return JSON.parse(localStorage.getItem(SEEN_KEY) || "{}"); } catch (e) { return {}; } };
  const saveSeen = (s) => { try { localStorage.setItem(SEEN_KEY, JSON.stringify(s)); } catch (e) {} };
  const loadSnooze = () => { try { return JSON.parse(localStorage.getItem(SNOOZE_KEY) || "{}"); } catch (e) { return {}; } };
  const saveSnooze = (s) => { try { localStorage.setItem(SNOOZE_KEY, JSON.stringify(s)); } catch (e) {} };
  const mailKey = (m) => "mail|" + String(m.from || "") + "|" + String(m.subject || "") + "|" + String(m.date || "");
  const isSeen = (key) => {
    const s = loadSeen();
    if (key.startsWith("mail|")) return Array.isArray(s.mail) && s.mail.includes(key.slice(5));
    if (key.startsWith("brief|")) return s.brief === key.slice(6);
    return Array.isArray(s.keys) && s.keys.includes(key);
  };
  const isSnoozed = (key) => { const z = loadSnooze(); return z[key] && Number(z[key]) > Date.now(); };

  function emitState() {
    bus.emit("nova:direct-state", { items: list() });
  }
  function addItem(item) {
    if (!item || !item.key || stopped) return null;
    if (isSeen(item.key) || isSnoozed(item.key)) return null;
    const prev = items.get(item.key);
    items.set(item.key, { ...prev, ...item, at: item.at || (prev && prev.at) || Date.now() });
    while (items.size > MAX_ITEMS) items.delete(items.keys().next().value);
    if (!announced.has(item.key)) { announced.add(item.key); bus.emit("nova:direct-item", items.get(item.key)); }
    emitState();
    return items.get(item.key);
  }
  function list() {
    return [...items.values()].filter((it) => !isSeen(it.key) && !isSnoozed(it.key))
      .sort((a, b) => (b.at || 0) - (a.at || 0));
  }

  /* ── Gestes partagés (un seul endroit les applique → vu partout) ────── */
  function markSeen(key) {
    if (!key) return;
    const s = loadSeen();
    if (key.startsWith("mail|")) { s.mail = Array.isArray(s.mail) ? s.mail : []; const mk = key.slice(5); if (!s.mail.includes(mk)) s.mail.push(mk); }
    else if (key.startsWith("brief|")) { s.brief = key.slice(6); }
    else { s.keys = Array.isArray(s.keys) ? s.keys : []; if (!s.keys.includes(key)) s.keys.push(key); }
    saveSeen(s);
    items.delete(key);
    emitState();
  }
  function snooze(key, minutes = 60) {
    if (!key) return;
    const z = loadSnooze(); z[key] = Date.now() + minutes * 60000; saveSnooze(z);
    items.delete(key);
    emitState();
  }
  async function ackWaiting(item, laterMinutes = 0) {
    /* Décision sur une exécution de Dot en attente : mêmes routes que l'ancien
       fil et que l'écran Agents (/api/dots/ack, /api/dots/snooze). */
    const rid = item && item.runId;
    if (rid) {
      try {
        if (laterMinutes) await api.post("/api/dots/snooze", { run_id: rid, minutes: laterMinutes });
        else await api.post("/api/dots/ack", { run_id: rid });
      } catch (e) { /* moteur injoignable : l'état local ci-dessous reste la vérité d'affichage */ }
    }
    if (laterMinutes) snooze(item.key, laterMinutes); else markSeen(item.key);
  }

  /* ── API publique d'injection (Dots, modules, pont UI) ──────────────── */
  function push(d) {
    if (!d || typeof d !== "object") return null;
    const titre = String(d.titre || d.title || "Information");
    const corps = cleanResume(d.corps || d.body || d.text || "");
    const dot = d.dot ? {
      name: String((typeof d.dot === "object" ? d.dot.name : d.dot) || "Éclat"),
      emoji: String((typeof d.dot === "object" && d.dot.emoji) || d.emoji || ""),
      color: String((typeof d.dot === "object" && d.dot.color) || d.color || ""),
    } : (d.emoji || d.dotName ? { name: String(d.dotName || "Nova"), emoji: String(d.emoji || ""), color: String(d.color || "") } : null);
    const key = String(d.key || ("push|" + (dot ? dot.name : "") + "|" + titre + "|" + corps.slice(0, 60)));
    return addItem({
      key, kind: d.kind || (dot ? "dot" : "push"), dot,
      titre: truncWords(titre, 110), corps, tags: Array.isArray(d.tags) ? d.tags.slice(0, 2).map(String) : [],
      at: Number(d.at) || Date.now(),
      action: d.action && typeof d.action === "object" ? {
        label: String(d.action.label || "Ouvrir"),
        module: d.action.module ? String(d.action.module) : "",
        run: d.action.run ? String(d.action.run) : "",
        href: d.action.href ? String(d.action.href) : "",
      } : null,
      runId: d.runId ? String(d.runId) : "",
    });
  }

  /* ── Le Dot vient à Ahadi : événements serveur → items Direct ─────────
     core.js aliasse déjà les événements moteur : « dot » → « nova:dot-run »,
     « brief » → « nova:brief-new », « commitment » → « nova:commitment »,
     « meeting » → « nova:meeting ». Formes défensives : le payload exact du
     moteur n'est pas contractuel côté web, on lit tous les champs plausibles
     et on n'invente rien (pas de résumé absent → corps vide, jamais fabriqué). */
  const offs = [];
  const onBus = (t, f) => { try { offs.push(bus.on(t, f)); } catch (e) {} };
  onBus("nova:dot-run", (d) => {
    if (!d || typeof d !== "object") return;
    if (d.phase && d.phase !== "ready") return;   /* R-235 : « a terminé » seulement à la phase finale (le moteur publie aussi « working ») */
    const name = String(d.dot_name || d.name || (d.dot && d.dot.name) || d.dot || "Éclat");
    const bad = d.ok === false || /err|fail|éch/i.test(String(d.status || ""));
    push({
      key: "dot|" + String(d.run_id || d.id || (name + "|" + (d.ts || d.at || Date.now()))),
      kind: "dot",
      dot: { name, emoji: String(d.emoji || ""), color: String(d.color || "") },
      titre: name + (bad ? " — échec à signaler" : " a terminé un travail"),
      corps: cleanResume(d.summary || d.result || d.error || d.status || ""),
      at: new Date(d.ts || d.at || Date.now()).getTime() || Date.now(),
      /* §36 (21/10) : le Dot AMÈNE son message — la carte porte le run_id,
         le bandeau affiche « Lire » (résultat complet sur place, sans
         quitter l'écran). Le détour par l'écran Dots ne subsiste que
         si l'exécution n'a pas d'identifiant. */
      runId: String(d.run_id || d.id || ""),
      action: (d.run_id || d.id) ? null : { label: "Ouvrir les Éclats", module: "agents" },
    });
  });
  onBus("nova:brief-new", (d) => {
    if (!d || typeof d !== "object") return;
    push({
      key: "brief|" + String(d.id || d.title || "") + "|" + String(d.at || d.date || ""),
      kind: "brief", titre: "Brief prêt : " + String(d.title || d.kind || "Brief"),
      corps: cleanResume(d.summary || ""), at: new Date(d.at || d.date || Date.now()).getTime() || Date.now(),
      action: { label: "Ouvrir Feeds", module: "veille" },
    });
  });
  onBus("nova:commitment", (d) => {
    if (!d || typeof d !== "object" || !d.quoi) return;
    push({
      key: "due|" + String(d.quoi) + "|" + String(d.echeance || ""),
      kind: "due", titre: "Échéance : " + String(d.quoi),
      corps: [(d.dir === "eux" ? "Promesse reçue" : "Mon engagement") + (d.qui ? " · " + d.qui : ""), d.echeance ? fmtEch(d.echeance) : ""].filter(Boolean).join(" · "),
      at: Date.now(), action: { label: "Ouvrir Engagements", module: "engagements" },
    });
  });
  /* R-235 — mails web nouveaux, publiés en direct par le moteur
     (bus « mail.new » : lignes fraîches des boîtes web ol/gm/tm/wa,
     déjà dédoublonnées côté moteur). La clé « mail|… » réutilise la
     mécanique vu/plus tard persistée. Lignes brutes : jamais de
     commentaire fabriqué — le tri rédigé reste le Dot Courrier. */
  onBus("nova:mail-new", (d) => {
    if (!d || !Array.isArray(d.lines)) return;
    const svc = String(d.service || ""), boxName = String(d.box || "Boîte web");
    for (const line of d.lines.slice(0, 6)) {
      const l = String(line || "").trim(); if (!l) continue;
      push({
        key: "mail|" + svc + "|" + l.slice(0, 120),
        kind: "mail",
        titre: truncWords(l, 100),
        corps: [boxName, d.urgent ? "URGENT" : "", d.who ? "expéditeur prioritaire : " + String(d.who) : ""].filter(Boolean).join(" · "),
        tags: tagsFor(l, ""),
        at: new Date(d.at || Date.now()).getTime() || Date.now(),
        action: { label: "Ouvrir Messages", module: "messages" },
      });
    }
  });

  /* ── Sondage des sources (les 4 mêmes routes que l'ancien fil) ──────── */
  async function refresh() {
    if (stopped) return;
    const seen = loadSeen();
    if (!Array.isArray(seen.mail)) seen.mail = [];
    if (typeof seen.seeded !== "boolean") seen.seeded = false;

    try {   /* 📬 Mails nouveaux (Outlook local lu par le moteur) */
      const j = await api.get("/api/mailapi/unread");
      const boxes = (j && j.boxes) || [];
      const mails = boxes.length && Array.isArray(boxes[0].items) ? boxes[0].items : [];
      if (!seen.seeded && mails.length) { seen.mail = mails.slice(3).map((m) => mailKey(m).slice(5)); seen.seeded = true; saveSeen(seen); }
      for (const m of mails.slice(0, 6)) {
        addItem({
          key: mailKey(m), kind: "mail",
          titre: truncWords(m.subject || "(sans objet)", 100),
          corps: [String(m.from || ""), String(m.date || ""), truncWords(m.preview || "", 90)].filter(Boolean).join(" · "),
          tags: tagsFor(m.from, m.subject),
          at: new Date(m.date || Date.now()).getTime() || Date.now(),
          action: { label: "Ouvrir Messages", module: "messages" },
        });
      }
    } catch (e) { /* boîte illisible : section simplement absente */ }

    try {   /* 🧭 Exécutions de Dots en attente de décision — le Dot attend Ahadi */
      const w = await api.get("/api/dots/waiting");
      const waiting = (w && (w.items || w.waiting)) || [];
      for (const r of waiting.slice(0, 5)) {
        const rid = String(r.run_id || r.id || "");
        addItem({
          key: "waiting|" + (rid || String(r.dot_name || r.title || "")), kind: "waiting",
          dot: { name: String(r.dot_name || r.name || r.title || r.dot || "Éclat"), emoji: String(r.emoji || ""), color: String(r.color || "") },
          titre: String(r.dot_name || r.name || r.title || r.dot || "Un Éclat") + " attend ta décision",   // V5-W : nom lisible (« Gardien du Mac ») avant l'id brut
          corps: cleanResume(r.summary || r.text || r.question || ""),
          at: new Date(r.ts || r.at || Date.now()).getTime() || Date.now(),
          runId: rid,
          action: { label: "Ouvrir Éclats", module: "dots" },
        });
      }
    } catch (e) { /* file illisible */ }

    try {   /* ⏰ Engagements ouverts : en retard ou dus d'ici ~36 h */
      const j = await api.get("/api/commitments");
      const all = (j && j.items) || [];
      const today = new Date(); today.setHours(0, 0, 0, 0);
      const limit = today.getTime() + 36 * 3600 * 1000;
      const due = all.filter((c) => (c.status || "ouvert") === "ouvert" && c.echeance && !isNaN(new Date(c.echeance + "T12:00:00")) && new Date(c.echeance + "T12:00:00").getTime() <= limit)
        .sort((a, b) => String(a.echeance).localeCompare(String(b.echeance))).slice(0, 3);
      for (const c of due) {
        const late = new Date(c.echeance + "T12:00:00").getTime() < today.getTime();
        addItem({
          key: "due|" + String(c.quoi || "") + "|" + String(c.echeance || ""), kind: "due",
          titre: String(c.quoi || "Engagement"),
          corps: [(c.dir === "eux" ? "Promesse reçue" : "Mon engagement") + (c.qui ? " · " + c.qui : ""), fmtEch(c.echeance) + (late ? " — EN RETARD" : "")].filter(Boolean).join(" · "),
          at: Date.now(), action: { label: "Ouvrir Engagements", module: "engagements" },
        });
      }
    } catch (e) { /* engagements illisibles */ }

    try {   /* 🛠️ Dernier brief frais (< 36 h), une fois par brief */
      const j = await api.get("/api/briefs");
      const briefs = (j && (j.items || j.briefs)) || [];
      const b = briefs[0];
      if (b) {
        const at = new Date(b.at || b.date || b.created || b.ts).getTime();
        if (!isNaN(at) && Date.now() - at < 36 * 3600 * 1000) {
          addItem({
            key: "brief|" + String(b.id || b.title || "") + "|" + String(b.at || b.date || ""), kind: "brief",
            titre: String(b.title || b.kind || "Brief"),
            corps: "Assemblé " + new Date(at).toLocaleString("fr-FR", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) + " — il t'attend dans Veille.",
            at, action: { label: "Ouvrir Feeds", module: "veille" },
          });
        }
      }
    } catch (e) { /* historique optionnel */ }
    emitState();
  }

  /* V4-D : relecture déclenchée par le bus (anti-rafale 1,5 s), jamais par une horloge courte. */
  let hintT = 0, stopWatch = null;
  function hint() {
    if (hintT || stopped) return;
    hintT = setTimeout(() => { hintT = 0; if (!stopped && !document.hidden) refresh(); }, 1500);
  }
  function start() {
    refresh();
    for (const t of ["direct.appended", "nova:dot-run", "nova:brief-new", "nova:commitment", "nova:mail-new", "teams.new"]) onBus(t, () => hint());
    stopWatch = sseWatchdog(bus, () => { if (!document.hidden) refresh(); });
    timer = setInterval(() => { if (!document.hidden) refresh(); }, SWEEP_MS);   // filet lent : échéances devenues dues
    try { document.addEventListener("visibilitychange", () => { if (!document.hidden && !stopped) refresh(); }); } catch (e) {}
    return service;
  }
  function stop() {
    stopped = true;
    if (timer) clearInterval(timer);
    if (hintT) { clearTimeout(hintT); hintT = 0; }
    if (stopWatch) { try { stopWatch(); } catch (e) {} stopWatch = null; }
    offs.forEach((o) => { try { o(); } catch (e) {} });
  }

  const service = { list, push, markSeen, snooze, ackWaiting, refresh, start, stop };
  return service;
}
