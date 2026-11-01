import { h, cleanResume } from "./core.js";
import { ic } from "./icons.js";
import { sseWatchdog, SWEEP_MS } from "./direct-global.js";   // V4-D : chien de garde SSE unique + filet lent   // APPLY-ADDONS : ligne d'import requise par les dépendances déclarées du patch (h, cleanResume, exports de core.js) — absente du bloc préparé, ajoutée telle quelle, aucun autre écart
/* ═══════════════════════════════════════════════════════════════════════════
   PROCHAT — LE FIL DIRECT SANS CLIC (ordre d'Ahadi, 21/10 ~16:54 : « les
   messages et événements arrivent directement dans le chat, sans que j'aie
   à cliquer quoi que ce soit, comme tu le fais pour moi »).

   Avant ce service : le journal proactif du moteur (proactive_feed.json,
   route GET /api/proactive/feed) n'avait AUCUN consommateur vivant — son
   seul lecteur (modules/direct.js) n'est monté par aucun écran — et le
   service Direct (direct-global.js) alimentait un bandeau et des toasts,
   jamais un fil de conversation. Les événements Teams publiés par le
   moteur (« teams.new ») n'avaient même ni alias ni abonné côté web.

   Ce service est le dernier kilomètre :
     · il LIT le journal moteur (source unique de rendu) avec un curseur
       persisté : un événement manqué pendant l'absence arrive au retour,
       marqué « pendant ton absence », jamais perdu, jamais rejoué ;
     · il ÉCOUTE le bus SSE comme simple signal de relecture (le moteur
       append au journal dans le même geste qu'il publie : la relecture
       à +1,2 s voit toujours l'événement) — le payload SSE n'est jamais
       rendu directement, donc aucun doublon n'est possible ;
     · il INJECTE des cartes système datées et attribuées dans chaque fil
       de conversation enregistré (Accueil, Conversations, dock, panneau)
       via registerThread() — aucun clic, aucun focus volé, aucun
       défilement imposé (on ne suit que si Ahadi est déjà en bas du fil) ;
     · il REGROUPE les rafales (≥ 2 événements d'une même boîte dans un
       lot = une carte de synthèse) ;
     · il RESPECTE les réglages de discrétion existants : si « notify »
       est coupé ou si le mode concentration (focus_until) est actif,
       rien n'est injecté ET le curseur n'avance pas — les événements
       attendent et arriveront quand le réglage rouvrira. Les heures
       calmes ne gatent pas le fil (surface interne silencieuse ; le
       moteur continue de taire ses notifications, lui).

   Garde-fous : une carte n'a AUCUN bouton d'action externe (elle informe,
   elle n'envoie rien — RÈGLE D'OR n°2) ; ses seuls gestes sont « Lire »
   (déplier) et ✕ (masquage local à la surface).
   ═══════════════════════════════════════════════════════════════════════════ */

const CURSOR_KEY = "nova2_prochat_cursor_v1";   // ts du dernier événement du journal injecté
const IDS_KEY = "nova2_prochat_ids_v1";         // clés déjà injectées (anti-rejeu, persisté)
/* V4-D (24/10) : plus de sondage fixe de 45 s — relecture sur événement du bus SSE
   (dont « direct.appended »), au retour au premier plan, par le chien de garde
   (flux coupé) et par le seul filet lent SWEEP_MS (10 min). */
const JOURNAL_MAX = 60;

const BOX_LABEL = { ol: "Outlook", gm: "Gmail", tm: "Teams", wa: "WhatsApp", zm: "Zoho" };
const KIND_META = {
  "mail.new":  { icon: "mail", source: (ev) => BOX_LABEL[ev.box] || "Courrier" },
  "teams.new": { icon: "teams", source: () => "Teams" },
  "dot.done":  { icon: "agent", source: () => "Éclat" },
  "brief":     { icon: "brief", source: () => "Brief" },
  "meeting":   { icon: "calendar", source: () => "Agenda" },
  "waiting":   { icon: "time", source: () => "Éclat" },
};
const metaOf = (kind) => KIND_META[kind] || { icon: "orb", source: () => "Nova" };

export function createProChat({ api, bus }) {
  const threads = new Map();   // id → { log, delivered:Set<key> }
  const journal = [];          // specs des cartes livrées (session) — rejeu aux surfaces qui (re)naissent
  const bootedAt = Date.now();
  let cursor = loadCursor();
  let ids = loadIds();
  let timer = 0, hintT = 0, syncing = false, waitingBusy = false, stopWatch = null;
  let settingsCache = { at: 0, v: null };
  let directId = "";   // SPEC ÉVÉNEMENTS DANS LE CHAT (21/10, §4.6) : id du fil dédié « Fil direct », appris de GET /api/proactive/feed (champ direct_thread_id). Ses événements y sont déjà matérialisés en messages par le moteur : ils ne doivent pas y surgir AUSSI en carte.

  /* ── Persistance locale (curseur + anti-rejeu) ─────────────────────── */
  function loadCursor() { try { return localStorage.getItem(CURSOR_KEY) || ""; } catch (e) { return ""; } }
  function saveCursor() { try { localStorage.setItem(CURSOR_KEY, cursor); } catch (e) {} }
  function loadIds() { try { return new Set(JSON.parse(localStorage.getItem(IDS_KEY) || "[]")); } catch (e) { return new Set(); } }
  function saveIds() { try { localStorage.setItem(IDS_KEY, JSON.stringify([...ids].slice(-300))); } catch (e) {} }

  /* ── Porte de discrétion : réglages existants, lus chez le moteur ──── */
  async function gateOpen() {
    if (!settingsCache.v || Date.now() - settingsCache.at > 60000) {
      try { const j = await api.get("/api/settings"); settingsCache = { at: Date.now(), v: (j && j.settings) || {} }; }
      catch (e) { settingsCache = { at: Date.now(), v: settingsCache.v || {} }; }
    }
    const s = settingsCache.v || {};
    if (s.notify === false) return false;
    const fu = Number(s.focus_until || 0);
    if (fu && fu > Date.now()) return false;
    return true;
  }

  /* ── Cartes ─────────────────────────────────────────────────────────── */
  const fmtWhen = (ts) => {
    const d = new Date(ts); if (isNaN(d)) return "";
    const time = d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });
    return d.toDateString() === new Date().toDateString() ? time
      : d.toLocaleDateString("fr-FR", { day: "numeric", month: "short" }) + " " + time;
  };
  /* 25/10 (Ahadi : « aperçu masqué, rien sur le message, aucune action rapide ») — carte lisible :
     en-tête (source · qui · heure), objet UNE fois, le vrai texte (lignes « De : / Objet : / Heure : »
     retirées, « Aperçu : » déballé), « Lire en entier » (corps complet du magasin, GET /api/mail/corps),
     et deux gestes internes qui demandent à Nova dans CE fil : Résumer, Proposer une réponse.
     Rien n'est jamais envoyé ni écrit en brouillon (RÈGLE D'OR n°2). */
  const cleanBody = (spec) => {
    const out = [];
    for (const raw of String(spec.body || "").split("\n")) {
      const l = raw.trim(); if (!l) continue;
      if (/^(De|From|Heure|Date|Reçu)\s*:/i.test(l)) continue;
      const mObj = /^(Objet|Subject)\s*:\s*(.*)$/i.exec(l);
      if (mObj) { if (spec.title && mObj[2].trim() && spec.title.indexOf(mObj[2].trim().slice(0, 40)) >= 0) continue; out.push(mObj[2]); continue; }
      const mAp = /^Aperçu\s*:\s*(.*)$/i.exec(l);
      if (mAp) { const t = mAp[1].trim(); if (t && !/^(\(?masqu|—|-$)/i.test(t)) out.push(t); continue; }
      out.push(l);
    }
    return out.join("\n");
  };
  function cardFor(spec, ask) {
    const isMsg = spec.kind === "mail.new" || spec.kind === "teams.new";
    const txt = cleanBody(spec);
    const body = txt ? h("div", { class: "prochat-body" + (txt.length > 280 ? " clamp" : "") }, txt)
                     : (isMsg ? h("div", { class: "prochat-body prochat-muted" }, "Contenu pas encore lu — « Lire en entier » le récupère.") : null);
    const acts = [];
    const feedId = spec.key.indexOf("pf|") === 0 && spec.key.indexOf("pf|grp|") !== 0 ? spec.key.slice(3) : "";
    if (isMsg && feedId) {
      const full = h("button", { class: "btn sm", type: "button" }, "Lire en entier");
      full.onclick = async () => {
        full.disabled = true; full.textContent = "Lecture…";
        try {
          const j = await api.get("/api/mail/corps?feed=" + encodeURIComponent(feedId));
          if (j && j.ok && j.body) { body.textContent = String(j.body); body.classList.remove("clamp", "prochat-muted"); full.remove(); }
          else { full.textContent = j && j.state === "masqué" ? "Contenu masqué (code ou secret)" : "Contenu indisponible pour l'instant"; }
        } catch (e) { full.disabled = false; full.textContent = "Réessayer"; }
      };
      acts.push(full);
    } else if (body && txt.length > 280) {
      const more = h("button", { class: "btn sm", type: "button" }, "Lire");
      more.onclick = () => { body.classList.toggle("clamp"); more.textContent = body.classList.contains("clamp") ? "Lire" : "Réduire"; };
      acts.push(more);
    }
    if (isMsg && typeof ask === "function") {
      const ref = "« " + (spec.title || "ce message").slice(0, 140) + " »" + (spec.who ? " de " + spec.who : "") + " (" + spec.source + ")";
      acts.push(h("button", { class: "btn sm ghost", type: "button", onclick: () => ask("Résume-moi " + ref + " en 3 points, BLUF d'abord, et dis-moi s'il attend une action de ma part. Ouvre d'abord son contenu complet (mail_corps).") }, "Résumer"));
      acts.push(h("button", { class: "btn sm ghost", type: "button", onclick: () => ask("Propose-moi une réponse courte à " + ref + ". Ouvre d'abord son contenu complet (mail_corps). N'envoie rien et ne crée aucun brouillon : montre-moi seulement le texte.") }, "Proposer une réponse"));
    }
    const x = h("button", { class: "btn-close prochat-x", title: "Retirer cette carte de ce fil (l'événement reste au journal du moteur)", "aria-label": "Retirer la carte",
      onclick: (e) => { const c = e.target.closest(".prochat-card"); if (c) c.remove(); }, html: ic("close", 16) });
    return h("div", { class: "msg prochat-card", "data-kind": spec.kind, "data-key": spec.key },
      h("div", { class: "prochat-head" },
        h("span", { class: "prochat-ic", html: ic(spec.icon || "orb", 14) }),
        h("span", { class: "prochat-src" }, spec.source + (spec.who ? " · " + spec.who : "")),
        spec.urgent ? h("span", { class: "prochat-urg" }, "Urgent") : null,
        spec.absence ? h("span", { class: "prochat-abs" }, "pendant ton absence") : null,
        h("span", { class: "sp" }),
        h("span", { class: "prochat-time" }, fmtWhen(spec.ts)),
        x),
      spec.title ? h("div", { class: "prochat-title" }, spec.title) : null,
      body,
      acts.length ? h("div", { class: "prochat-actions" }, ...acts) : null);
  }

  /* ── Livraison dans les fils enregistrés ────────────────────────────── */
  function appendTo(t, spec) {
    if (t.delivered.has(spec.key)) return;
    // SPEC ÉVÉNEMENTS DANS LE CHAT (21/10, §4.6) : dans le fil dédié, l'événement est
    // DÉJÀ un message (role:"event", matérialisé par le moteur) — jamais de carte en
    // plus dans CE fil-là. Les autres surfaces gardent leurs cartes, et les cartes
    // « en attente de décision » (clés wait|) ne sont pas des événements du journal :
    // elles continuent d'arriver partout, y compris dans le fil dédié.
    if (directId && t.id === "conv:" + directId && spec.key.startsWith("pf|")) return;
    // V5-T (25/10) : une carte « attend ta décision » ne double pas la carte d'Éclat du même run déjà au fil (data-run, feedcard.js).
    if (spec.key.startsWith("wait|")) { try { const rid = spec.key.slice(5); if (rid && [...t.log.querySelectorAll(".direct-msg[data-run]")].some((el) => el.dataset.run === rid)) return; } catch (e) {} }
    t.delivered.add(spec.key);
    const nearBottom = t.log.scrollHeight - t.log.scrollTop - t.log.clientHeight < 140;
    t.log.append(cardFor(spec, t.ask));
    if (nearBottom) { try { t.log.scrollTop = t.log.scrollHeight; } catch (e) {} }
  }
  function deliver(spec) {
    if (ids.has(spec.key)) return false;
    ids.add(spec.key); saveIds();
    journal.push(spec);
    if (journal.length > JOURNAL_MAX) journal.splice(0, journal.length - JOURNAL_MAX);
    for (const t of threads.values()) appendTo(t, spec);
    return true;
  }
  /* Une surface (Accueil, session de Conversations, dock, panneau) enregistre
     son log : elle reçoit le journal de session qu'elle a manqué, sans doublon
     — l'état « livré » est reconstruit depuis le DOM, donc un re-rendu de la
     surface (activation, rechargement de l'historique du dock) ne perd rien
     et ne répète rien. */
  function registerThread(id, log, ask) {
    if (!id || !log) return;
    let t = threads.get(id);
    if (!t) { t = { log, delivered: new Set() }; threads.set(id, t); }
    if (typeof ask === "function") t.ask = ask;   /* 25/10 : gestes « Résumer / Proposer une réponse » de ce fil */
    t.log = log; t.id = id;   // SPEC ÉVÉNEMENTS DANS LE CHAT : la garde d'appendTo compare l'id du fil à celui du fil dédié
    try {
      t.delivered = new Set([...log.querySelectorAll(".prochat-card")].map((el) => el.dataset.key).filter(Boolean));
    } catch (e) {}
    for (const spec of journal) appendTo(t, spec);
  }

  /* ── Source A : le journal moteur ───────────────────────────────────── */
  const toSpec = (ev, absence) => {
    const m = metaOf(ev.kind);
    return { key: "pf|" + ev.id, kind: ev.kind, icon: m.icon, source: m.source(ev),
      title: String(ev.title || ""), body: String(ev.text || ""), ts: ev.ts,
      urgent: !!ev.urgent && !(ev.kind === "dot.done" && /a [ée]chou[ée]|\bECHEC\b/i.test(String(ev.title || "") + " " + String(ev.text || "").slice(0, 300))), who: String(ev.who || ""), absence };   // V5-Y : un échec d'Éclat n'est pas une urgence
  };
  async function sync() {
    if (syncing || document.hidden) return;
    syncing = true;
    try {
      if (!(await gateOpen())) return;   // discrétion : curseur figé, rien n'est perdu
      const j = await api.get("/api/proactive/feed?limit=50" + (cursor ? "&since=" + encodeURIComponent(cursor) : ""));
      if (j && j.direct_thread_id) directId = String(j.direct_thread_id);
      const evs = ((j && j.items) || []).filter((e) => e && e.id && e.ts)
        .sort((a, b) => String(a.ts).localeCompare(String(b.ts)));
      if (!evs.length) return;
      if (!cursor) {   // tout premier lancement : référence, pas de rejeu (doctrine WebMail / Direct)
        cursor = String(evs[evs.length - 1].ts); saveCursor(); return;
      }
      const batch = evs.filter((ev) => !ids.has("pf|" + ev.id));
      const groups = new Map(), singles = [];
      for (const ev of batch) {
        if (ev.kind === "mail.new" || ev.kind === "teams.new") {
          const gk = ev.kind + "|" + (ev.box || "");
          if (!groups.has(gk)) groups.set(gk, []);
          groups.get(gk).push(ev);
        } else singles.push(ev);
      }
      const specs = singles.map((ev) => toSpec(ev, new Date(ev.ts).getTime() < bootedAt));
      for (const list of groups.values()) {
        if (list.length === 1) { specs.push(toSpec(list[0], new Date(list[0].ts).getTime() < bootedAt)); continue; }
        const lines = [];
        for (const ev of list) for (const l of String(ev.text || "").split("\n")) if (l.trim()) lines.push(l);
        specs.push({
          key: "pf|grp|" + list.map((e) => e.id).join("+"), kind: list[0].kind,
          icon: metaOf(list[0].kind).icon, source: metaOf(list[0].kind).source(list[0]),
          title: (BOX_LABEL[list[0].box] || "Boîte") + " — " + list.length + " nouveaux messages",
          body: lines.slice(0, 6).join("\n"), ts: list[list.length - 1].ts,
          urgent: list.some((e) => e.urgent), who: "", absence: new Date(list[0].ts).getTime() < bootedAt,
          memberIds: list.map((e) => e.id),
        });
      }
      specs.sort((a, b) => String(a.ts).localeCompare(String(b.ts)));
      for (const spec of specs) {
        deliver(spec);
        if (spec.memberIds) { for (const mid of spec.memberIds) ids.add("pf|" + mid); saveIds(); }
      }
      const newest = String(evs[evs.length - 1].ts);
      if (newest && newest > cursor) { cursor = newest; saveCursor(); }
    } catch (e) { /* moteur injoignable : le prochain cycle réessaiera, le curseur n'a pas bougé */ }
    finally { syncing = false; }
  }

  /* ── Source B : les Dots en attente de décision ─────────────────────── */
  async function syncWaiting() {
    if (waitingBusy) return;
    waitingBusy = true;
    try {
      if (!(await gateOpen())) return;
      const w = await api.get("/api/dots/waiting");
      const items = (w && (w.items || w.waiting)) || [];
      for (const r of items.slice(0, 5)) {
        const rid = String(r.run_id || r.id || ""); if (!rid) continue;
        deliver({ key: "wait|" + rid, kind: "waiting", icon: "time", source: "Éclat",
          title: String(r.dot_name || r.name || r.title || r.dot || "Un Éclat") + " attend ta décision",
          body: cleanResume(r.summary || r.text || r.question || ""),
          ts: new Date(r.ts || r.at || Date.now()).toISOString(), urgent: true, who: "", absence: false });
      }
    } catch (e) { /* file illisible : rien */ }
    finally { waitingBusy = false; }
  }

  /* ── Signaux SSE : de simples déclencheurs de relecture ────────────── */
  function hint(waiting) {
    if (hintT) return;
    hintT = setTimeout(() => { hintT = 0; sync(); if (waiting) syncWaiting(); }, 1200);
  }
  function start() {
    sync();
    timer = setInterval(() => { if (!document.hidden) sync(); }, SWEEP_MS);   // V4-D : filet lent seulement
    stopWatch = sseWatchdog(bus, () => { if (!document.hidden) { sync(); syncWaiting(); } });
    document.addEventListener("visibilitychange", () => { if (!document.hidden) sync(); });
    /* Types BRUTS du flux /api/events (bus.on sait les écouter) — dont
       « teams.new », que l'alias nova:… de core.js ne couvre pas. */
    for (const t of ["mail.new", "teams.new", "brief", "meeting", "commitment", "direct.appended"]) {
      try { bus.on(t, () => hint(false)); } catch (e) {}
    }
    try {
      bus.on("dot", (d) => {
        if (!d || typeof d !== "object") return;
        if (d.phase === "ready") hint(false);
        else if (d.phase === "waiting") hint(true);
      });
    } catch (e) {}
    return service;
  }
  function stop() {
    if (timer) clearInterval(timer);
    if (hintT) { clearTimeout(hintT); hintT = 0; }
    if (stopWatch) { try { stopWatch(); } catch (e) {} stopWatch = null; }
  }

  const service = { registerThread, sync, syncWaiting, start, stop };
  return service;
}
