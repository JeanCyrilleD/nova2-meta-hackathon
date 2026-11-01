/* Module Temps (écran « Agenda ») — la journée d'Ahadi, sur les routes de Feat_Daily :
   GET /api/morning (la fiche du matin : agenda, rappels, mails, BRVM, Éclats),
   GET /api/meeting/next (prochain rendez-vous et le précédent, décorés par le moteur),
   GET /api/today (les autres réunions du jour), GET /api/meeting/brief (brief pré-réunion),
   GET /api/commitments (+ POST /api/commitments/update) pour les échéances proches,
   GET /api/chrono (+ /propose, /api/confirm, /block) pour les créneaux de concentration. */
/* V6 (25/10/2026, contrat conseil_24-10/V6_DESIGN.md) : en-tête ds.pageHead, sections ds.section,
   lignes ds.row avec leur action principale toujours visible. Acquis conservés : ordre V5-Y
   (Rendez-vous → Créneaux → Fiche du matin → Échéances proches), cleanNote (« null », erreur
   Calendar -1743 traduite), « Préparer le brief » absent sur une réunion passée, échéances calculées
   avec libellé (jamais la couleur seule), « Fait »/« Clore »/« Reçu » + « Annuler » 8 s + « Rouvrir ».
   Fiche du matin : plus de paragraphe parlé en tête (repli « Version à écouter »), une phrase
   d'accroche calculée sur les données, sections en cartes ; jamais de JSON ni de flottant brut
   (partie « MARCHÉ » relue et formatée) ; promotions et lettres d'information écartées des mails. */
import { md, fmtDateFR, fmtTimeFR } from "../core.js";
import { approvalCard } from "../orb.js";
import * as ds from "../ds.js";
const arrOf = (j, ...keys) => { if (Array.isArray(j)) return j; for (const k of keys) if (j && Array.isArray(j[k])) return j[k]; return []; };
const toD = (v) => { const d = new Date(typeof v === "number" ? v * (v < 1e12 ? 1000 : 1) : v); return isNaN(d) ? null : d; };
const dayRel = (d) => {
  const t0 = new Date(); t0.setHours(0, 0, 0, 0);
  const dd = Math.round((new Date(d.getFullYear(), d.getMonth(), d.getDate()) - t0) / 86400000);
  return dd === 0 ? "aujourd'hui" : dd === 1 ? "demain" : dd === -1 ? "hier" : fmtDateFR(d);
};
const hhmm = (v) => { const d = toD(v); return d ? String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0") : ""; };
const dayShort = (iso) => { const d = iso ? new Date(String(iso) + "T12:00:00") : null; return d && !isNaN(d) ? d.toLocaleDateString("fr-FR", { day: "numeric", month: "short" }) : String(iso || ""); };
const plural = (n, one, many) => n + " " + (n > 1 ? many : one);
const frPct = (v) => { const n = Number(v); if (!isFinite(n)) return "—"; const s = Math.abs(n).toLocaleString("fr-FR", { minimumFractionDigits: 1, maximumFractionDigits: 1 }); return (n > 0 ? "+" : n < 0 ? "−" : "") + s + " %"; };
/* Mails : une promotion ou une lettre d'information n'est jamais « à regarder » (même liste que le moteur). */
const PROMO_RX = /offre sp[ée]ciale|profitez|% de r[ée]duction|code promo|newsletter|lettre d'information|webinaire|webinar|formation internationale|certifiante|inscrivez-vous|derni[èe]re chance|black friday|soldes|unsubscribe|d[ée]sabonner/i;
/* Marché : la partie « MARCHÉ » de brvm_cours est un objet JSON (parfois tronqué) — relu cotation par cotation. */
function marketLines(raw) {
  const movers = [];
  for (const m of String(raw).match(/\{[^{}]*\}/g) || []) {
    try { const o = JSON.parse(m); if (o && o.sym && o.price != null && isFinite(Number(o.var))) movers.push({ sym: String(o.sym), v: Number(o.var) }); } catch (e) {}
  }
  if (!movers.length) return [];
  const up = movers.filter((m) => m.v > 0).length, down = movers.filter((m) => m.v < 0).length;
  const out = ["Marché : " + plural(movers.length, "valeur relevée", "valeurs relevées") + ", " + up + " en hausse, " + down + " en baisse."];
  const top = movers.filter((m) => m.v !== 0).sort((a, b) => Math.abs(b.v) - Math.abs(a.v)).slice(0, 3);
  if (top.length) out.push("Plus fortes variations : " + top.map((m) => m.sym + " " + frPct(m.v)).join(" · "));
  return out;
}
/* Nombres flottants bruts (0.650000000000002) → 1 décimale, virgule française. */
const tidyNums = (s) => String(s).replace(/(-?\d+)\.(\d{3,})/g, (x, a, b) => Number(a + "." + b).toLocaleString("fr-FR", { maximumFractionDigits: 1 }));
const SEC_TITLE = { mails: "Mails non lus à regarder", agenda: "Agenda du jour", echeances: "Échéances", brvm: "Marché BRVM", dots: "Éclats" };

export async function mount(root, ctx) {
  const { api, h, ic } = ctx;
  let dead = false;
  root.classList.add("mod--data", "ag");

  const refreshAll = () => { lastLoad = Date.now(); loadMorning(false, true); loadNext(); loadCommitments(); loadChrono(true); };
  root.append(ds.pageHead({ title: "Agenda", sub: "Tes rendez-vous, tes créneaux de concentration et la fiche du matin", actions: [{ label: "Actualiser", icon: "refresh", onClick: refreshAll }] }));

  /* Compteur de section (créé, mis à jour ou retiré). */
  const setCount = (sec, n) => {
    const head = sec.querySelector(".ds-section-head");
    let c = head.querySelector(".ds-count");
    if (n == null || n === "" || n === 0) { if (c) c.remove(); return; }
    if (!c) { c = h("span", { class: "ds-count" }); head.querySelector(".ds-h2").after(c); }
    c.textContent = String(n);
  };
  const errBox = (cause, retry) => ds.errorBox({ title: "Lecture impossible", cause, retry });

  const secRdv = ds.section({ title: "Rendez-vous" });
  const nextBox = h("div", { class: "ds-list ag-rdv" }, ds.skeleton(2));
  secRdv.body.append(nextBox);
  /* V5-O (#18) : créneaux de travail profond — GET /api/chrono. Section cachée si chronobio_on est coupé. */
  const secChrono = ds.section({ title: "Créneaux de concentration" });
  const chronoBox = h("div", {});
  secChrono.body.append(chronoBox);
  secChrono.hidden = true;
  const secMatin = ds.section({ title: "Fiche du matin" });
  const morningBox = h("div", {}, ds.skeleton(3));
  secMatin.body.append(morningBox);
  /* V5-Y : seules les échéances proches restent ici (l'écran Engagements porte la liste complète). */
  const secDue = ds.section({ title: "Échéances proches", actions: [{ label: "Tous les engagements", icon: "arrow-up-right", ghost: true, onClick: () => ctx.navigate("engagements") }] });
  const commitBox = h("div", { "aria-busy": "true" }, ds.skeleton(3));
  secDue.body.append(commitBox);
  /* 30/10 (refonte des mises en page) : deux colonnes — la journée (rendez-vous, puis la fiche du matin)
     à gauche, ce qui se décide (échéances proches, puis créneaux à bloquer) à droite. Une seule colonne
     dans un panneau étroit (layouts.css). Sections, routes et actions inchangées. */
  root.append(h("div", { class: "ag-cols" },
    h("div", { class: "ag-main" }, secRdv, secMatin),
    h("div", { class: "ag-side" }, secDue, secChrono)));

  /* Audit écrans 20/10 : un « null » littéral s'affichait, l'erreur Calendar -1743 était déversée brute. */
  const cleanNote = (s) => { const t = String(s == null ? "" : s).trim(); if (!t || t === "null" || t === "undefined") return ""; if (/osascript|execution error|not authorized|-1743/i.test(t)) return "Agenda non autorisé pour Nova — Réglages Système › Confidentialité et sécurité › Automatisation : autorise Nova à contrôler Calendar, puis reviens ici."; return t; };
  const emptyCompact = (icon, text) => ds.empty({ text, icon, compact: true });

  /* ── Fiche du matin ──────────────────────────────────────────────────
     GET /api/morning → { status:"pret"|"en_cours", page:{ date, generated, sections:[{id,title,lines,ok}], ecouter, brain } }.
     Tant que status === "en_cours", on re-sonde toutes les 4 s (2 min au plus) ; la page précédente reste affichée. */
  const POLL_MS = 4000, POLL_MAX_MS = 120000;
  let morningTimer = 0, morningT0 = 0, morningGaveUp = false;
  function sectionLines(sec) {
    const raw = (Array.isArray(sec.lines) ? sec.lines : []).map((l) => cleanNote(l)).filter(Boolean);
    const id = String(sec.id || "");
    let lines = [], note = "";
    if (id === "brvm") {
      for (const l of raw) {
        if (/^MARCH[ÉE]\s*:?\s*$/i.test(l)) continue;
        if (l.charAt(0) === "{" || /"sym"\s*:/.test(l)) { for (const m of marketLines(l)) if (!lines.includes(m)) lines.push(m); continue; }
        lines.push(tidyNums(l.replace(/^MARCH[ÉE]\s*:\s*/i, "Marché : ")));
      }
    } else if (id === "mails") {
      const kept = raw.filter((l) => !PROMO_RX.test(l));
      const n = raw.length - kept.length;
      lines = kept;
      if (n > 0) note = plural(n, "promotion ou lettre d'information écartée", "promotions ou lettres d'information écartées") + ".";
    } else if (id === "dots") {
      lines = raw.map((l) => l.replace(/\bDot\(s\)/g, "Éclat(s)").replace(/\bdans Dots\b/g, "dans Éclats").replace(/\bDots\b/g, "Éclats"));
    } else lines = raw.map(tidyNums);
    return { lines, note };
  }
  /* Une échéance de la fiche « Je dois : X — Qui · EN RETARD (2026-10-21) » → texte + statut lisible. */
  function dueLine(l) {
    const m = /^(.*?)(?:\s·\s(EN RETARD)\s*\((\d{4}-\d{2}-\d{2})\)|\s·\s(\d{4}-\d{2}-\d{2}))\s*$/.exec(l);
    if (!m) return { text: l, pill: null };
    if (m[2]) return { text: m[1], pill: ds.pill("En retard · " + dayShort(m[3]), "danger") };
    return { text: m[1], pill: ds.pill(dayShort(m[4]), "neutral") };
  }
  function renderMorning(j) {
    const page = j && j.page && typeof j.page === "object" ? j.page : null;
    const running = !!(j && j.status === "en_cours") && !morningGaveUp;
    const sections = page && Array.isArray(page.sections) ? page.sections : [];
    if (!page || !sections.length) {
      morningBox.replaceChildren(running
        ? h("div", { class: "ag-wait" }, h("p", { class: "ds-meta" }, "Nova assemble la fiche du matin (agenda, mails, BRVM, Éclats)…"), ds.skeleton(3))
        : emptyCompact("calendar", "La fiche du matin n'est pas encore assemblée — « Actualiser » la compose."));
      return;
    }
    const parsed = sections.map((s) => ({ s, ...sectionLines(s) }));
    /* Une phrase d'accroche CALCULÉE sur les données de la fiche (aucun texte inventé). */
    const byId = (id) => parsed.find((p) => String(p.s.id) === id);
    const lead = [];
    const ag = byId("agenda");
    if (ag) { const n = ag.lines.filter((l) => /^\d{1,2}[:h]\d{2}/.test(l)).length; if (n) lead.push(plural(n, "rendez-vous", "rendez-vous") + " aujourd'hui"); }
    const ec = byId("echeances");
    if (ec) { const late = ec.lines.filter((l) => /EN RETARD/.test(l)).length; if (late) lead.push(plural(late, "échéance en retard", "échéances en retard")); else if (ec.lines.length) lead.push(plural(ec.lines.length, "échéance proche", "échéances proches")); }
    const ml = byId("mails");
    if (ml && ml.s.ok !== false) { const n = ml.lines.filter((l) => !/^Aucun mail/i.test(l)).length; lead.push(n ? plural(n, "mail à regarder", "mails à regarder") : "aucun mail à regarder"); }
    const metaBits = [page.date ? String(page.date) : "", page.generated ? "assemblée à " + fmtTimeFR(page.generated) : ""].filter(Boolean);
    const card = (p) => {
      const id = String(p.s.id || "");
      const title = SEC_TITLE[id] || String(p.s.title || "Section");
      const items = p.lines.slice(0, 8).map((l) => {
        if (id === "echeances") { const d = dueLine(l); return h("li", { class: "ag-li" }, h("span", { class: "ag-li-t", title: d.text }, d.text), d.pill); }
        return h("li", { class: "ag-li" }, h("span", { class: "ag-li-t", title: l }, l.slice(0, 400)));
      });
      const emptyTxt = p.s.ok === false ? "Source indisponible ce matin." : id === "mails" && p.note ? "Aucun mail important." : "Rien à signaler.";
      return h("div", { class: "ag-mc" + (id === "brvm" || id === "dots" ? " is-small" : "") },
        h("div", { class: "ag-mc-h" }, h("h3", { class: "ds-h3" }, title), items.length ? h("span", { class: "ds-count" }, String(p.lines.length)) : null),
        items.length ? h("ul", { class: "ag-ul" }, items) : h("p", { class: "ds-meta ag-none" }, emptyTxt),
        p.note ? h("p", { class: "ds-meta ag-note" }, p.note) : null);
    };
    morningBox.replaceChildren(...[
      h("div", { class: "ag-mhead" },
        h("p", { class: "ag-lead" }, lead.length ? lead.join(" · ").replace(/^./, (c) => c.toUpperCase()) + "." : "Rien d'urgent dans la fiche de ce matin."),
        h("span", { class: "ds-meta ag-mmeta" }, metaBits.join(" · "), running ? h("span", { class: "ag-busy" }, h("i"), "mise à jour…") : null)),
      h("div", { class: "ag-mgrid" }, parsed.map(card)),
      page.ecouter ? ds.fold("Version à écouter (120 mots)", h("p", { class: "ag-listen" }, String(page.ecouter)), false) : null].filter(Boolean));
  }
  async function loadMorning(fromPoll, force) {
    clearTimeout(morningTimer); morningTimer = 0;
    if (!fromPoll) { morningT0 = Date.now(); morningGaveUp = false; }
    try {
      const j = await api.get("/api/morning" + (force ? "?force=1" : ""));   // 24/10 : « Actualiser » recompose vraiment la fiche (sinon cache 30 min)
      if (dead) return;
      const waiting = j && j.status === "en_cours";
      if (waiting && Date.now() - morningT0 >= POLL_MAX_MS) morningGaveUp = true;   // le libellé « mise à jour » ne reste pas affiché indéfiniment
      renderMorning(j);
      if (waiting && !morningGaveUp) morningTimer = setTimeout(() => { if (!dead) loadMorning(true); }, POLL_MS);
      else if (waiting && !(j.page && j.page.sections)) morningBox.replaceChildren(errBox("La fiche du matin tarde (plus de 2 min) — le moteur la termine en arrière-plan.", () => loadMorning()));
    } catch (e) { if (!dead) morningBox.replaceChildren(errBox("Fiche du matin injoignable.", () => loadMorning())); }
  }

  /* ── Brief pré-réunion (patron Granola) ─────────────────────────────
     GET /api/meeting/brief?key= ; absent ou périmé → préparé en arrière-plan ({status:"en_cours"}),
     re-sondé toutes les 4 s (2 min au plus). Nova ne rejoint jamais la réunion : aucun bot, aucun enregistrement. */
  const prepTimers = new Set();
  const sleep = (ms) => new Promise((r) => { const t = setTimeout(() => { prepTimers.delete(t); r(); }, ms); prepTimers.add(t); });
  const list = (arr, ordered) => h(ordered ? "ol" : "ul", {}, ...arr.map((x) => h("li", {}, String(x))));
  function briefView(b) {
    const people = Array.isArray(b.participants) ? b.participants : [];
    const eng = Array.isArray(b.engagements) ? b.engagements : [];
    const ech = Array.isArray(b.echanges) ? b.echanges : [];
    const dec = Array.isArray(b.decisions) ? b.decisions : [];
    const qs = Array.isArray(b.questions) ? b.questions : [];
    const structured = !!(b.contexte || ech.length || dec.length || qs.length);
    const okSrc = Object.entries(b.sources || {}).filter(([, v]) => v === true).map(([k]) => k.replace(/_/g, " "));
    const sec = (title, body) => h("div", { class: "mb-sec" }, h("h4", {}, title), body);
    return [
      h("div", { class: "mb-head" },
        h("span", { class: "tt" }, "Brief · " + String(b.title || "réunion")),
        h("span", { class: "ss" }, [b.when || "", b.location || ""].filter(Boolean).join(" · "))),
      b.contexte ? h("p", { class: "mb-ctx" }, String(b.contexte)) : null,
      sec("Participants", people.length
        ? h("div", { class: "mb-people" }, ...people.slice(0, 14).map((p) => h("span", { class: "mb-chip", title: String(p.email || "") }, String(p.nom || p.email || "?"), (p.role || p.statut) ? h("small", {}, [p.role, p.statut].filter(Boolean).join(" · ")) : null)))
        : h("div", { class: "ss ss--wrap" }, "Non lus : " + String(b.participants_note || "aucune information dans l'invitation") + ".")),
      structured ? sec("Derniers échanges", ech.length ? list(ech) : h("div", { class: "ss" }, "Aucun échange récent retrouvé avec ces personnes.")) : null,
      sec("Engagements en cours avec eux", eng.length
        ? list(eng.map((c) => (c.dir === "eux" ? "On te doit : " : "Tu dois : ") + String(c.quoi || "") + (c.qui ? " (" + c.qui + ")" : "") + (c.echeance ? " · " + fmtDateFR(c.echeance + "T12:00:00") : "")))
        : h("div", { class: "ss" }, "Aucun engagement ouvert lié à ces personnes ou à ce sujet.")),
      structured ? sec("Décisions attendues", dec.length ? list(dec) : h("div", { class: "ss" }, "Aucune décision identifiée dans les données.")) : null,
      structured && qs.length ? h("div", { class: "mb-sec mb-q" }, h("h4", {}, "3 questions à poser"), list(qs, true)) : null,
      b.vigilance ? h("div", { class: "ss ss--wrap" }, "Vigilance : " + String(b.vigilance)) : null,
      !structured && b.text ? h("div", { class: "brief-text", html: md(String(b.text)) }) : null,
      h("div", { class: "mb-foot" },
        h("span", {}, (b.status === "erreur" ? "Données brutes : aucun assistant n'a répondu · " : "") + (okSrc.length ? "Sources : " + okSrc.join(", ") : "Aucune source n'a renvoyé de donnée liée")),
        h("span", { class: "sp" }),
        h("span", {}, "Nova ne rejoint jamais la réunion" + (b.ts ? " · " + fmtTimeFR(b.ts) : "")))];
  }
  async function openBrief(e, btn, host, force) {
    if (btn) btn.disabled = true;
    host.querySelectorAll("[data-prep]").forEach((n) => n.remove());
    const box = h("div", { class: "mb", "data-prep": "1", "aria-busy": "true" }, h("div", { class: "ss" }, "Brief « " + String(e.title || "réunion") + " » en préparation : invitation, mails, Teams, engagements, mémoire…"), ds.skeleton(2));
    host.append(box);
    try {
      const key = String(e.key || "");
      if (!key) throw new Error("rendez-vous sans identifiant dans l'agenda");
      let b = await api.get("/api/meeting/brief?key=" + encodeURIComponent(key) + (force ? "&force=1" : ""));
      const t0 = Date.now();
      while (!dead && b && b.status === "en_cours" && Date.now() - t0 < POLL_MAX_MS) {
        await sleep(POLL_MS);
        if (dead) return;
        b = await api.get("/api/meeting/brief?key=" + encodeURIComponent(key));
      }
      if (dead) return;
      box.removeAttribute("aria-busy");
      if (b && (b.status === "pret" || b.status === "erreur") && (b.text || b.participants)) {
        box.replaceChildren(...briefView(b).filter(Boolean),
          h("div", { class: "mb-foot" }, h("span", { class: "sp" }),
            ds.action({ label: "Refaire", icon: "refresh", ghost: true, onClick: (ev) => openBrief(e, ev.currentTarget, host, true) }),
            ds.action({ label: "Fermer", icon: "close", ghost: true, onClick: () => box.remove() })));
      } else if (b && b.status === "absent") box.replaceChildren(errBox("Réunion introuvable dans l'agenda.", () => openBrief(e, btn, host, false)));
      else box.replaceChildren(errBox("Le brief n'est pas encore prêt — le moteur continue en arrière-plan.", () => openBrief(e, btn, host, false)));
    } catch (err) { if (!dead) { box.removeAttribute("aria-busy"); box.replaceChildren(errBox("Brief impossible : " + String((err && err.message) || err), () => openBrief(e, btn, host, false))); } }
    if (btn) btn.disabled = false;
  }
  /* Ligne de rendez-vous : heure en tête, titre, lieu ; action principale = le brief. */
  const evRow = (e, kind, host) => {
    const at = e.ts || e.at || e.date;
    const title = String(e.title || e.name || "Rendez-vous");
    const past = kind === "Précédent";
    const ready = e.prep_status === "pret";
    const d = toD(at);
    const isToday = !!(d && d.toDateString() === new Date().toDateString());
    const mins = d ? Math.round((d.getTime() - Date.now()) / 60000) : NaN;
    const relTxt = !d ? "" : !isToday ? dayRel(d) : mins >= 0 && mins < 60 ? "dans " + mins + " min" : mins >= 60 && mins < 360 ? "dans " + Math.floor(mins / 60) + " h" + (mins % 60 ? " " + String(mins % 60).padStart(2, "0") : "") : mins < 0 && mins > -360 ? "il y a " + (mins > -60 ? -mins + " min" : Math.floor(-mins / 60) + " h" + ((-mins) % 60 ? " " + String((-mins) % 60).padStart(2, "0") : "")) : "aujourd'hui";
    const meta = [past ? "Précédent" : "", relTxt, cleanNote(e.location || e.where || ""), cleanNote(e.note || "")].filter(Boolean).join(" · ");
    /* V5-Y : préparer le brief d'une réunion PASSÉE n'a pas de sens — seul un brief déjà prêt se relit. */
    const act = past && !ready ? null : { label: ready ? "Voir le brief" : "Préparer le brief", icon: ready ? "brief" : "sparkle", primary: kind === "Prochain", onClick: (ev) => openBrief(e, ev.currentTarget, host, false) };
    const r = ds.row({
      lead: h("span", { class: "ag-hour" }, String(e.hhmm || hhmm(at) || "—")),
      title, meta,
      side: ready ? ds.pill("Brief prêt", "ok") : kind === "Prochain" ? ds.pill("Prochain", "warn") : null,
      actions: act ? [act] : null,
    });
    r.classList.add("ag-ev");
    if (past) r.classList.add("is-muted");
    if (act) r.querySelector(".ds-row-actions > button").classList.add("is-primary");
    return r;
  };
  let dayCount = 0;
  async function loadNext() {
    try {
      const j = await api.get("/api/meeting/next");
      if (dead) return;
      const nx = j && j.next, past = j && j.past;
      /* replaceChildren DIRECT convertit un enfant null en texte « null » (WebKit) : on filtre avant d'injecter. */
      nextBox.replaceChildren(...[
        nx ? evRow(nx, "Prochain", nextBox) : emptyCompact("calendar", "Aucun rendez-vous dans les 3 prochaines heures."),
        past ? evRow(past, "Précédent", nextBox) : null,
        j && cleanNote(j.note) ? h("p", { class: "ds-meta ag-note" }, cleanNote(j.note)) : null].filter(Boolean));
      dayCount = nx ? 1 : 0;
      setCount(secRdv, dayCount);
      /* VAGUE 1 : un brief déjà prêt (T-30 ou demandé) s'affiche seul — lecture du cache, aucun assistant sollicité. */
      if (nx && nx.prep_status === "pret") openBrief(nx, null, nextBox, false);
      loadDayMeetings(nx);
    } catch (e) { if (!dead) nextBox.replaceChildren(errBox("Agenda injoignable pour le moment.", () => loadNext())); }
  }
  /* VAGUE 1 : les autres réunions du jour (GET /api/today), chacune avec son brief à la demande. */
  async function loadDayMeetings(nx) {
    let items = [];
    try { items = arrOf(await api.get("/api/today"), "items"); } catch (e) { return; }
    if (dead) return;
    const now = Date.now() / 1000;
    const rows = items.filter((e) => { const t = Number(e.ts) || 0; const d = new Date(t * 1000); return t > now - 1800 && d.toDateString() === new Date().toDateString() && !(d.getHours() === 0 && d.getMinutes() === 0) && (!nx || e.key !== nx.key); }).slice(0, 6);
    nextBox.querySelectorAll(".mb-day").forEach((n) => n.remove());
    setCount(secRdv, dayCount + rows.length);
    if (!rows.length) return;
    const host = h("div", { class: "mb-day" }, h("h3", { class: "ds-h3 ag-sub" }, "Plus tard aujourd'hui"));
    for (const e of rows) host.append(evRow(e, "later", host));
    host.append(h("p", { class: "ds-meta ag-note" }, "Chaque brief se prépare seul avant la réunion (avance : Réglages › Rituels) ou maintenant, à la demande."));
    nextBox.append(host);
  }

  /* ── Échéances proches ──────────────────────────────────────────────
     Forme RÉELLE du moteur : {id, quoi, qui, echeance (AAAA-MM-JJ), dir (moi|eux), source, status (ouvert|fait|ignore)}.
     Mise à jour : {id, status:"fait"} ; Rouvrir = {id, status:"ouvert"} (C-24). */
  async function loadCommitments() {
    try {
      const j = await api.get("/api/commitments");
      if (dead) return;
      commitBox.removeAttribute("aria-busy");
      const items = arrOf(j, "items", "commitments");
      /* V5-Y : ouverts, en retard ou dus sous 7 jours (les plus urgents d'abord, 6 au plus). */
      const t0 = new Date(); t0.setHours(0, 0, 0, 0);
      const lim = t0.getTime() + 7 * 86400000;
      const dueTs = (c) => { const d = c.echeance ? new Date(String(c.echeance) + "T12:00:00") : null; return d && !isNaN(d) ? d.getTime() : Infinity; };
      const near = items.filter((c) => (c.status || "ouvert") === "ouvert" && dueTs(c) <= lim).sort((a, b) => dueTs(a) - dueTs(b));
      const open = near.slice(0, 6);
      const restN = items.filter((c) => (c.status || "ouvert") === "ouvert").length - open.length;
      setCount(secDue, open.length);
      const rowsEl = h("div", { class: "ds-list" });
      for (const c of open) rowsEl.append(dueRow(c));
      commitBox.replaceChildren(...(open.length
        ? [rowsEl, restN > 0 ? h("p", { class: "ds-meta ag-note" }, plural(restN, "autre engagement ouvert", "autres engagements ouverts") + ", plus lointain" + (restN > 1 ? "s" : "") + " ou sans échéance — dans Engagements.") : null].filter(Boolean)
        : [emptyCompact("check", items.some((c) => (c.status || "ouvert") === "ouvert") ? "Aucune échéance dans les 7 prochains jours." : "Aucun engagement ouvert.")]));
    } catch (e) { if (!dead) { commitBox.removeAttribute("aria-busy"); commitBox.replaceChildren(errBox("Engagements injoignables.", () => loadCommitments())); } }
  }
  function dueRow(c) {
    const done = c.status === "fait";
    const isRecv = c.dir === "eux";
    const sens = isRecv ? "On te doit" : "Tu dois";
    /* Échéance calculée (DS §6.8) : pastille + libellé, jamais la couleur seule. */
    const echTxt = String(c.echeance || "");
    const echD = echTxt ? new Date(echTxt + "T12:00:00") : null;
    let tone = "neutral", urg = echD && !isNaN(echD) ? dayShort(echTxt) : "sans échéance";
    if (done) { tone = "ok"; urg = "Fait"; }
    else if (echD && !isNaN(echD)) {
      const today = new Date(); today.setHours(0, 0, 0, 0);
      const echDay = new Date(echD); echDay.setHours(0, 0, 0, 0);
      const diff = Math.round((echDay - today) / 86400000);
      if (diff < 0) { tone = "danger"; urg = "En retard de " + Math.abs(diff) + " j"; }
      else if (diff === 0) { tone = "warn"; urg = "Aujourd'hui"; }
      else if (diff === 1) { tone = "warn"; urg = "Demain"; }
      else if (diff <= 2) { tone = "warn"; urg = "Dans " + diff + " j"; }
    }
    const isTeam = !isRecv && /equipe|équipe|team/i.test(String(c.source || "") + " " + String(c.qui || ""));
    const doneLabel = isRecv ? "Reçu" : isTeam ? "Clore" : "Fait";
    const origStatus = c.status || "ouvert";
    const src = String(c.source || "").replace(/^(teams|mail|outlook)\s*:\s*/i, (m, k) => k.charAt(0).toUpperCase() + k.slice(1).toLowerCase() + " · ");
    const meta = [sens + (c.qui ? " · " + c.qui : ""), echD && !isNaN(echD) && tone !== "neutral" ? dayShort(echTxt) : "", src].filter(Boolean).join(" · ");
    const pillEl = ds.pill(urg, tone);
    const update = async (status) => { await api.post("/api/commitments/update", { id: c.id, status }); };
    const r = ds.row({ title: String(c.quoi || "Engagement"), meta, side: pillEl, tip: String(c.quoi || "") + " — ouvrir dans Engagements", onOpen: () => ctx.navigate("engagements") });
    r.classList.add("ag-due");
    if (done) r.classList.add("is-done");
    const acts = h("div", { class: "ds-row-actions" });
    const mk = (d) => { const b = ds.action(d); b.classList.add("is-primary"); return b; };
    const reopen = mk({ label: "Rouvrir", ghost: true, onClick: async () => { try { await update("ouvert"); loadCommitments(); } catch (e) { ctx.toast("Mise à jour impossible.", true); } } });
    const doneBtn = mk({ label: doneLabel, icon: "check", onClick: async (ev) => {
      const btn = ev.currentTarget;
      btn.disabled = true;
      try { await update("fait"); } catch (e) { ctx.toast("Mise à jour impossible.", true); btn.disabled = false; return; }
      if (dead) return;
      r.classList.add("is-done");
      let timer = null;
      const cancelBtn = mk({ label: "Annuler", icon: "undo", ghost: true, onClick: async () => { if (timer) clearTimeout(timer); try { await update(origStatus); } catch (e) {} if (!dead) loadCommitments(); } });
      btn.replaceWith(cancelBtn);
      timer = setTimeout(() => { if (!dead) loadCommitments(); }, 8000);
    } });
    acts.append(done ? reopen : doneBtn);
    r.append(acts);
    return r;
  }

  /* ── Créneaux de concentration (V5-O) ───────────────────────────────
     « Bloquer ce créneau » = l'outil existant calendar_add, APRÈS ton GO sur la carte :
     POST /api/chrono/propose (rien n'est créé) → carte → POST /api/confirm {id, ok} → POST /api/chrono/block {id}
     (le moteur ne crée l'événement que si CE GO existe). Le résultat affiché est la sortie réelle de l'outil. */
  let openCard = null;
  const hourLbl = (x) => { const n = ((Number(x) % 24) + 24) % 24; return n === 0 ? "minuit" : n + " h"; };
  async function blockSlot(sl, btn) {
    btn.disabled = true;
    let prop = null;
    try { prop = await api.post("/api/chrono/propose", { start: sl.start, end: sl.end }); }
    catch (e) { ctx.toast("Proposition refusée par le moteur : " + ((e && e.message) || e), true); btn.disabled = false; return; }
    if (dead) return;
    if (!prop || prop.ok !== true || !prop.id) { ctx.toast("Proposition refusée : " + String((prop && prop.error) || "réponse incomplète du moteur"), true); btn.disabled = false; return; }
    const card = approvalCard({ title: "Bloquer ce créneau dans Calendrier ?", what: String(prop.what || ("« " + String(prop.title || "Travail profond") + " » · " + String(prop.label || ""))), approveLabel: "GO — bloquer", editLabel: null, refuseLabel: "Non" });
    openCard = { card, id: prop.id };
    (btn.closest(".ds-row") || btn).after(card);
    const v = await card.promise;
    card.remove(); openCard = null;
    if (dead) return;
    if (v !== "approve") {
      try { await api.post("/api/confirm", { id: prop.id, ok: false }); } catch (e) {}
      ctx.toast("Rien n'a été créé."); btn.disabled = false; return;
    }
    try {
      const c = await api.post("/api/confirm", { id: prop.id, ok: true });
      if (!c || String(c.message) !== "Autorisé.") throw new Error("GO non enregistré — moteur : " + String((c && c.message) || "sans réponse"));
      const r = await api.post("/api/chrono/block", { id: prop.id });
      if (dead) return;
      if (r && r.created === true) { ctx.toast(String(r.output || "Créneau bloqué dans Calendrier.")); btn.textContent = "Bloqué"; loadChrono(true); return; }
      throw new Error(String((r && (r.output || r.error)) || "aucun événement créé"));
    } catch (e) {
      if (!dead) { ctx.toast("Créneau non bloqué : " + String((e && e.body && (e.body.output || e.body.error)) || (e && e.message) || e), true); btn.disabled = false; }
    }
  }
  async function loadChrono(force) {
    let j = null;
    try { j = await api.get("/api/chrono" + (force ? "?force=1" : "")); } catch (e) { j = null; }
    if (dead) return;
    if (j && j.on === false) { secChrono.hidden = true; return; }
    secChrono.hidden = false;
    if (!j || !Array.isArray(j.slots)) { chronoBox.replaceChildren(errBox("Créneaux illisibles — le moteur ne répond pas.", () => loadChrono(true))); return; }
    const peaks = Array.isArray(j.peaks) ? j.peaks.slice().sort((a, b) => a.h - b.h) : [];
    const basis = j.basis || {};
    const maxN = Math.max(1, ...peaks.map((p) => Number(p.n) || 0));
    const slots = j.slots.slice(0, 6);
    setCount(secChrono, slots.length);
    const intro = h("p", { class: "ds-meta ag-intro" }, "Plages libres d'au moins 90 minutes dans ton agenda, placées sur les heures où tu es le plus actif. Un clic les propose ; rien n'est bloqué sans ton GO.");
    const peaksEl = peaks.length ? h("div", { class: "ag-peaks" },
      h("span", { class: "ag-peaks-l" }, "Tes heures les plus actives"),
      h("div", { class: "ag-peaks-c" }, peaks.map((p) => {
        const n = Number(p.n) || 0;
        const el = h("span", { class: "ag-peak", title: plural(n, "message ou action", "messages ou actions") + " sur 14 jours, entre " + hourLbl(p.h) + " et " + hourLbl(Number(p.h) + 1) },
          h("span", { class: "ag-peak-t" }, hourLbl(p.h) + " – " + hourLbl(Number(p.h) + 1)), h("i", { class: "ag-peak-b" }));
        el.style.setProperty("--lvl", String(Math.max(0.12, n / maxN)));
        return el;
      }))) : h("p", { class: "ds-meta" }, "Heures les plus actives : —");
    const rows = slots.map((sl) => {
      const lbl = String(sl.hhmm || (hhmm(sl.start) + "–" + hhmm(sl.end))).replace(/[–-]/, " – ");
      const r = ds.row({
        lead: "calendar",
        title: (sl.jour === "demain" ? "Demain" : "Aujourd'hui") + " · " + lbl,
        meta: String(sl.why || ""),
        tip: sl.score != null ? "Score du créneau : " + Math.round(Number(sl.score) * 100) / 100 : null,
        actions: [{ label: "Bloquer ce créneau", primary: true, onClick: (ev) => blockSlot(sl, ev.currentTarget) }],
      });
      r.querySelector(".ds-row-actions > button").classList.add("is-primary");
      return r;
    });
    const src = String(j.source || "").replace(/\s*\((?:[^)]*EventKit[^)]*)\)/i, "").trim();
    const basisTxt = (Number(basis.messages) || Number(basis.actions)) ? "Mesuré sur 14 jours : " + plural(Number(basis.messages) || 0, "message", "messages") + " et " + plural(Number(basis.actions) || 0, "action", "actions") + " (heure GMT)" : "";
    chronoBox.replaceChildren(...[intro, peaksEl,
      rows.length ? h("div", { class: "ds-list ag-slots" }, rows) : emptyCompact("calendar", String(j.note || "Aucun créneau d'au moins 90 min libre dans tes heures actives, aujourd'hui ni demain.")),
      h("p", { class: "ds-meta ag-note" }, [basisTxt, src ? "agenda lu dans " + src : "agenda : —", j.generated ? "calculé à " + fmtTimeFR(j.generated) : ""].filter(Boolean).join(" · "))]);
  }

  let lastLoad = Date.now();
  loadMorning(); loadNext(); loadCommitments(); loadChrono(false);
  /* FIX-WEB : module persistant (monté une fois puis caché) → rafraîchi au retour s'il date de plus de 30 s. */
  return {
    destroy() { dead = true; clearTimeout(morningTimer); prepTimers.forEach((t) => clearTimeout(t)); prepTimers.clear(); if (openCard) { try { api.post("/api/confirm", { id: openCard.id, ok: false }); } catch (e) {} openCard = null; } },
    onShow() { if (Date.now() - lastLoad < 30000) return; lastLoad = Date.now(); loadMorning(); loadNext(); loadCommitments(); loadChrono(false); },
  };
}
