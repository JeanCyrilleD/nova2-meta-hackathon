/* Module Engagements — VAGUE 1 (24/10) : « qui a promis quoi, à qui, pour quand ».
   Source unique : commitments.json, servi par GET /api/engagements?vue= (Feat_Engagements.swift) —
   le même magasin que le scan quotidien (Agenda), la distillation des conversations et le relevé
   automatique des arrivées triées du Fil direct (mail/Teams au corps lu).
   · actions Fait / Reporter / Annuler (POST /api/engagements/update) — « en retard » est calculé ;
   · relance d'un engagement qu'on te doit : un TEXTE proposé dans l'écran (POST /api/engagements/relance),
     « Copier » et « Demander à Nova de préparer » — jamais de brouillon, jamais d'envoi (règle d'or n°2) ;
   · source cliquable : Fil direct / conversation d'origine, sinon l'écran Messages ;
   · états vides honnêtes : rien n'est inventé.
   V6 (25/10) — système de design : en-tête de page, métriques (en retard, cette semaine, je dois, on me
   doit), vue en onglets (Liste / Par personne / Par dossier) + filtres en puces à compteurs + recherche ;
   lignes .ds-row (personne, échéance, statut en pastille) ; actions cohérentes partout : Fait (primaire,
   toujours visible), Reporter, Relancer (si on te doit), Annuler ; clos repliés ; squelette, erreur, vide. */
import { fmtDateFR, fmtRelFR } from "../core.js";
import * as ds from "../ds.js";

const VIEWS = [["liste", "Liste"], ["personnes", "Par personne"], ["dossiers", "Par dossier"]];
const FILTERS = [["tout", "Tout"], ["je_dois", "Je dois"], ["on_me_doit", "On me doit"], ["en_retard", "En retard"]];
const VIEW_KEY = "nova2_eng_view", FILTER_KEY = "nova2_eng_filter", OLD_TAB_KEY = "nova2_eng_tab";
const KIND_LB = { mail: "Courrier", teams: "Teams", conversation: "Conversation", reunion: "Réunion" };
const plural = (n, one, many) => n + " " + (Math.abs(n) > 1 ? many : one);
const dayLabel = (iso) => { try { const d = new Date(iso + "T12:00:00"); return isNaN(d) ? iso : new Intl.DateTimeFormat("fr-FR", { weekday: "short", day: "numeric", month: "short" }).format(d); } catch (e) { return iso; } };
const ymd = (d) => d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0");
const initials = (n) => { const p = String(n || "?").trim().split(/\s+/).filter(Boolean); return ((p[0] || "?")[0] + (p.length > 1 ? p[p.length - 1][0] : "")).toUpperCase(); };

async function copyText(t) {
  try { if (navigator.clipboard && navigator.clipboard.writeText) { await navigator.clipboard.writeText(t); return true; } } catch (e) {}
  try {
    const ta = document.createElement("textarea"); ta.value = t; ta.setAttribute("readonly", ""); ta.style.position = "fixed"; ta.style.opacity = "0";
    document.body.append(ta); ta.select(); const ok = document.execCommand("copy"); ta.remove(); return !!ok;
  } catch (e) { return false; }
}

export async function mount(root, ctx) {
  const { api, h, bus } = ctx;
  let dead = false;
  let view = "liste", filter = "tout", query = "";
  try {
    const v = localStorage.getItem(VIEW_KEY), f = localStorage.getItem(FILTER_KEY), old = localStorage.getItem(OLD_TAB_KEY);
    if (VIEWS.some(([id]) => id === v)) view = v;
    else if (old === "personnes" || old === "dossiers") view = old;
    if (FILTERS.some(([id]) => id === f)) filter = f;
    else if (old === "je_dois" || old === "on_me_doit") filter = old;
  } catch (e) {}
  let data = null;            // dernière réponse du moteur (vue « tout »)
  let loadErr = false;
  const openGroups = new Set();
  const relances = new Map(); // id → { state: "load"|"ok"|"err", texte, how, note }
  const reporting = new Set();

  root.classList.add("mod--data", "eng", "flx-eng");
  const refreshDesc = { icon: "refresh", tip: "Actualiser les engagements", onClick: () => load(true, true) };
  const head = ds.pageHead({ title: "Engagements", sub: "Qui a promis quoi, à qui, pour quand — par personne et par dossier", actions: [refreshDesc] });
  const kpiHost = h("div", {});
  const tabsEl = ds.tabs(VIEWS.map(([id, label]) => ({ id, label, on: id === view })), (id) => { view = id; try { localStorage.setItem(VIEW_KEY, id); } catch (e) {} render(); });
  const tbHost = h("div", {});
  const body = h("div", { class: "flx-eng-body" });
  const foot = h("p", { class: "ds-meta flx-eng-foot" });
  /* 30/10 (refonte des mises en page) : vue (Liste / Par personne / Par dossier), recherche et filtres sur une seule barre. */
  root.append(head, kpiHost, h("div", { class: "flx-eng-bar" }, tabsEl, tbHost), body, foot);
  body.append(ds.skeleton(4));

  const busy = () => root.contains(document.activeElement) && /^(INPUT|TEXTAREA)$/.test(document.activeElement.tagName);

  async function load(quiet, manual) {
    try {
      const j = await api.get("/api/engagements?vue=tout");
      if (dead) return;
      data = j && typeof j === "object" ? j : {};
      loadErr = false;
      render();
      if (manual) ctx.toast("Engagements à jour.");
    } catch (e) {
      if (dead) return;
      loadErr = true;
      if (!data) body.replaceChildren(ds.errorBox({ cause: "Engagements injoignables pour le moment — le moteur ne répond pas.", retry: () => { body.replaceChildren(ds.skeleton(4)); load(); } }));
      else if (manual) ctx.toast("Actualisation impossible — le moteur ne répond pas.", true);
    }
  }

  /* ── Métriques ────────────────────────────────────────────────────── */
  function paintKpis() {
    const b = (data && data.bluf) || {};
    const late = b.en_retard | 0, week = b.cette_semaine | 0, open = b.ouverts | 0;
    if (!(b.total | 0)) { kpiHost.replaceChildren(); return; }
    kpiHost.replaceChildren(ds.kpis([
      { label: "En retard", value: String(late), delta: late ? "à traiter d'abord" : "rien en retard", tone: late ? "danger" : "ok", alert: late > 0 },
      { label: "Dus cette semaine", value: String(week), delta: plural(open, "ouvert", "ouverts") + " au total" },
      { label: "Je dois", value: String(b.je_dois | 0), delta: b.sans_echeance ? plural(b.sans_echeance | 0, "sans échéance", "sans échéance") : "tous datés" },
      { label: "On me doit", value: String(b.on_me_doit | 0), delta: "relances proposées, jamais envoyées" },
    ]));
  }

  /* ── Lignes ───────────────────────────────────────────────────────── */
  function dueInfo(it) {
    const open = it.status === "ouvert";
    if (it.status === "fait") return { pill: ds.pill("Fait", "ok"), text: it.echeance ? "échéance " + dayLabel(it.echeance) : "" };
    if (it.status === "annule") return { pill: ds.pill("Annulé", "neutral"), text: it.echeance ? "échéance " + dayLabel(it.echeance) : "" };
    if (!it.echeance) return { pill: ds.pill("Sans échéance", "neutral"), text: "" };
    const j = Number(it.jours);
    if (it.etat === "en_retard") { const n = Math.max(1, -j || 1); return { pill: ds.pill("En retard de " + n + " j", "danger"), text: dayLabel(it.echeance) }; }
    if (!open) return { pill: null, text: dayLabel(it.echeance) };
    if (j === 0) return { pill: ds.pill("Aujourd'hui", "warn"), text: dayLabel(it.echeance) };
    if (j === 1) return { pill: ds.pill("Demain", "warn"), text: dayLabel(it.echeance) };
    if (isFinite(j) && j > 1) return { pill: ds.pill("Dans " + j + " j", it.cette_semaine ? "warn" : "neutral"), text: dayLabel(it.echeance) };
    return { pill: ds.pill(dayLabel(it.echeance), "neutral"), text: "" };
  }
  function openSource(it) {
    const ref = it.source_ref || {};
    if (ref.conv) {
      try { localStorage.setItem("nova2_pending_conv", String(ref.conv)); } catch (e) {}
      ctx.navigate("conversations");
      setTimeout(() => { try { bus.emit("nova:open-conv", { id: String(ref.conv) }); } catch (e) {} }, 120);
      return;
    }
    if (it.source_kind === "reunion") { ctx.navigate("temps"); return; }
    ctx.navigate("messages");
  }
  function sourceInfo(it) {
    const kind = it.source_kind || "";
    const ref = it.source_ref || {};
    const txt = String(it.source || "").replace(/^(mail|teams|conversation|courrier|outlook|gmail)\s*[:—–-]\s*/i, "").trim();   // V5-Y : « Teams — Teams — canal » ne se répète plus
    if (!kind && !txt) return null;
    const label = (KIND_LB[kind] || "Source") + (txt && txt.toLowerCase() !== String(KIND_LB[kind] || "").toLowerCase() ? " — " + txt : "");
    const where = ref.conv ? (ref.feed ? "Ouvrir le message dans le Fil direct" : "Ouvrir la conversation d'origine") : kind === "reunion" ? "Ouvrir l'Agenda" : (kind === "mail" || kind === "teams") ? "Ouvrir Messages (le message d'origine n'est pas lié)" : "";
    return { label, where, icon: kind === "teams" ? "teams" : kind === "conversation" ? "chat" : kind === "reunion" ? "calendar" : "mail" };
  }
  async function update(it, patch, okMsg) {
    try {
      await api.post("/api/engagements/update", { id: it.id, ...patch });
      if (okMsg) ctx.toast(okMsg);
      reporting.delete(it.id);
      load(true);
    } catch (e) { ctx.toast("Modification impossible : " + String((e && e.message) || "moteur injoignable").replace(/^.*→ \d+ : /, ""), true); }
  }
  async function askRelance(it) {
    relances.set(it.id, { state: "load" }); render();
    try {
      const r = await api.post("/api/engagements/relance", { id: it.id }, 60000);
      if (dead) return;
      relances.set(it.id, { state: (r && r.texte) ? "ok" : "err", texte: (r && r.texte) || "", how: (r && r.how) || "", note: (r && r.note) || "" });
    } catch (e) { if (!dead) relances.set(it.id, { state: "err", texte: "", note: "Le moteur n'a pas pu proposer de texte." }); }
    if (!dead) render();
  }
  function askNova(it) {
    const qui = it.qui_nom || it.qui || "la personne concernée";
    const text = "Prépare-moi le texte d'une relance courtoise pour " + qui + " au sujet de : « " + it.quoi + " »" + (it.echeance ? " (échéance convenue : " + it.echeance + ")" : "") + ". Donne-moi seulement le texte à copier : ne crée aucun brouillon et n'envoie rien.";
    ctx.navigate("conversations");
    let tries = 0;
    const fire = () => { if (document.querySelector('.mod[data-mod="conversations"] .composer') || tries > 30) { bus.emit("nova:ask", { text, fresh: true }); return; } tries++; setTimeout(fire, 150); };
    setTimeout(fire, 150);
  }
  /* 25/10 AUTONOMIE — « Proposer une relance » d'un mail resté sans réponse : un BROUILLON dans la file
     de validation (POST /api/autonomie/relance) — jamais un envoi ; la carte d'approbation de Messages
     attend ENVOYER. */
  const drafting = new Set();
  async function proposeRelance(it) {
    if (drafting.has(it.id)) return;
    drafting.add(it.id); render();
    try {
      const r = await api.post("/api/autonomie/relance", { id: it.id }, 90000);
      if (!r || r.ok !== true || !r.draft_id) throw new Error((r && r.error) || "le moteur n'a pas confirmé le brouillon");
      ctx.toast((r.deja ? "Relance déjà prête" : "Relance prête") + " dans Messages › À approuver" + (r.how === "gabarit" ? " (gabarit : aucun cerveau n'a répondu)" : "") + " — rien n'est parti.");
      try { bus.emit("nova:draft-new", { source: "relance" }); } catch (e) {}
      ctx.navigate("messages");
      setTimeout(() => { try { bus.emit("nova:draft-focus", { id: String(r.draft_id) }); } catch (e) {} }, 350);
    } catch (e) { ctx.toast("Relance impossible : " + String((e && e.message) || e), true); }
    drafting.delete(it.id);
    if (!dead) load(true);
  }
  function relancePanel(it) {
    const st = relances.get(it.id);
    if (!st) return null;
    const closeA = { label: "Fermer", ghost: true, onClick: () => { relances.delete(it.id); render(); } };
    if (st.state === "load") return h("div", { class: "flx-eng-panel" }, h("p", { class: "ds-meta" }, "Nova compose un texte de relance…"), ds.skeleton(1));
    if (st.state === "err") return h("div", { class: "flx-eng-panel" }, ds.errorBox({ title: "Aucun texte proposé", cause: st.note || "Le moteur n'a pas pu proposer de texte.", retry: () => askRelance(it) }), h("div", { class: "flx-act-row" }, ds.action(closeA)));
    const ta = h("textarea", { class: "fld flx-eng-txt", rows: "6", "aria-label": "Texte de relance proposé" });
    ta.value = st.texte;
    ta.addEventListener("input", () => { st.texte = ta.value; });
    return h("div", { class: "flx-eng-panel" },
      h("p", { class: "ds-meta" }, "Texte proposé" + (st.how === "gabarit" ? " (gabarit — aucun cerveau n'a répondu)" : "") + ". Rien n'est envoyé ni enregistré en brouillon : tu copies, tu envoies toi-même si tu le décides."),
      ta,
      h("div", { class: "flx-act-row" },
        ds.action(closeA),
        ds.action({ label: "Demander à Nova de préparer", ghost: true, tip: "Ouvre la conversation et demande à Nova de préparer le texte — sans brouillon, sans envoi", onClick: () => askNova(it) }),
        ds.action({ label: "J'ai relancé", tip: "Noter que tu as relancé aujourd'hui", onClick: () => { relances.delete(it.id); update(it, { relance: true }, "Relance notée."); } }),
        ds.action({ label: "Copier", primary: true, onClick: async () => { const ok = await copyText(ta.value); ctx.toast(ok ? "Texte copié." : "Copie impossible — sélectionne le texte à la main.", !ok); } })));
  }
  function reportPanel(it) {
    if (!reporting.has(it.id)) return null;
    const inp = h("input", { class: "fld", type: "date", "aria-label": "Nouvelle échéance" });
    const base = it.echeance && it.etat !== "en_retard" ? new Date(it.echeance + "T12:00:00") : new Date();
    const plus = (n) => { const d = new Date(base.getTime()); d.setDate(d.getDate() + n); return ymd(d); };
    inp.value = plus(7);
    const go = (v) => { if (!/^\d{4}-\d{2}-\d{2}$/.test(String(v || ""))) { ctx.toast("Choisis une date.", true); return; } update(it, { echeance: v }, "Échéance reportée au " + fmtDateFR(v + "T12:00:00") + "."); };
    inp.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); go(inp.value); } if (e.key === "Escape") { reporting.delete(it.id); render(); } });
    setTimeout(() => { try { inp.focus(); } catch (e) {} }, 30);
    return h("div", { class: "flx-eng-panel flx-eng-rep" },
      h("span", { class: "flx-eng-rep-lb" }, "Reporter au"),
      inp,
      ds.action({ label: "+1 j", onClick: () => go(plus(1)) }),
      ds.action({ label: "+7 j", onClick: () => go(plus(7)) }),
      it.echeance ? ds.action({ label: "Sans échéance", ghost: true, tip: "Retirer l'échéance", onClick: () => update(it, { echeance: "" }, "Échéance retirée.") }) : null,
      h("span", { class: "flx-sp" }),
      ds.action({ label: "Fermer", ghost: true, onClick: () => { reporting.delete(it.id); render(); } }),
      ds.action({ label: "Valider", primary: true, onClick: () => go(inp.value) }));
  }
  function itemRow(it, opts = {}) {
    const open = it.status === "ouvert";
    const late = it.etat === "en_retard";
    const eux = it.dir === "eux";
    const qui = it.qui_nom || it.qui || "";
    const attente = it.origine === "attente_reponse";   // 25/10 AUTONOMIE : mail envoyé resté sans réponse
    const dirLb = attente ? (qui ? qui + " me doit une réponse" : "On me doit une réponse") : eux ? (qui ? qui + " me doit" : "On me doit") : (qui ? "Je dois à " + qui : "Je dois");
    const due = dueInfo(it);
    const src = sourceInfo(it);
    const metaBits = [opts.hidePerson ? (eux ? "Me doit" : "Je dois") : dirLb];
    if (due.text) metaBits.push(due.text);
    if (it.dossier && !opts.hideDossier) metaBits.push((it.dossier_deduit ? "dossier déduit : " : "") + it.dossier);
    if (src) metaBits.push(src.label);
    if (it.relances && it.relances.length) metaBits.push(plural(it.relances.length, "relance", "relances") + " (dernière " + fmtRelFR(it.relances[it.relances.length - 1].ts) + ")");
    if (attente && it.envoye_le) metaBits.push("envoyé " + fmtRelFR(it.envoye_le) + (it.envoye_via ? " (" + it.envoye_via + ")" : ""));
    if (attente && it.relance_draft) metaBits.push("relance en brouillon");
    if (it.reports) metaBits.push(plural(it.reports, "report", "reports") + (it.echeance_initiale ? " (initiale : " + dayLabel(it.echeance_initiale) + ")" : ""));
    const acts = open ? [
      { label: "Annuler", ghost: true, tip: "Annuler cet engagement (il reste visible dans les clos)", onClick: () => update(it, { statut: "annule" }, "Engagement annulé.") },
      attente ? { label: drafting.has(it.id) ? "Relance en préparation…" : "Proposer une relance", tip: "Nova prépare un brouillon de relance dans Messages › À approuver — rien n'est envoyé sans ton ENVOYER", onClick: () => proposeRelance(it) }
        : eux ? { label: "Relancer", tip: "Nova propose un texte de relance — rien n'est envoyé", onClick: () => askRelance(it) } : null,
      { label: "Reporter", tip: "Changer l'échéance", onClick: () => { if (reporting.has(it.id)) reporting.delete(it.id); else reporting.add(it.id); render(); } },
      (() => { /* Fait : action principale, toujours visible ; pleine (accent) seulement pour un engagement en retard — pas de mur de boutons pleins. */
        const b = ds.action({ label: "Fait", icon: "check", primary: late, tip: eux ? "Marquer comme reçu" : "Marquer comme fait", onClick: () => update(it, { statut: "fait" }, eux ? "Engagement reçu et soldé." : "Engagement soldé.") });
        b.classList.add("is-primary");
        return b;
      })(),
    ].filter(Boolean) : [{ label: "Rouvrir", tip: "Rouvrir cet engagement", onClick: () => update(it, { statut: "ouvert" }, "Engagement rouvert.") }];
    const el = ds.row({
      lead: opts.hidePerson ? (eux ? "arrow-up-right" : "check") : h("span", { class: "flx-av" }, initials(qui || "?")),
      title: String(it.quoi || "—"),
      meta: metaBits.join(" · "),
      side: due.pill,
      actions: acts,
      onOpen: src && src.where ? () => openSource(it) : null,
      tip: (it.quoi || "") + (src && src.where ? " — clic : " + src.where.toLowerCase() : ""),
    });
    el.dataset.id = String(it.id || "");
    if (!open) el.classList.add("is-muted");
    if (late) el.classList.add("flx-is-late");
    if (it.citation) el.querySelector(".ds-row-main").append(h("div", { class: "flx-eng-cit", title: String(it.citation) }, "« " + String(it.citation) + " »"));
    const panels = [reportPanel(it), relancePanel(it)].filter(Boolean);
    if (!panels.length) return el;
    el.classList.add("is-selected");
    return h("div", { class: "flx-eng-item" }, el, ...panels);
  }

  /* ── Filtrage ─────────────────────────────────────────────────────── */
  const passFilter = (x) => filter === "je_dois" ? x.dir !== "eux" : filter === "on_me_doit" ? x.dir === "eux" : filter === "en_retard" ? x.etat === "en_retard" && x.status === "ouvert" : true;
  const passQuery = (x) => !query || [x.quoi, x.qui_nom, x.qui, x.dossier, x.source, x.citation].filter(Boolean).join(" ").toLowerCase().includes(query.toLowerCase());
  function paintToolbar(items) {
    const openIts = items.filter((x) => x.status === "ouvert");
    const counts = {
      tout: openIts.length,
      je_dois: openIts.filter((x) => x.dir !== "eux").length,
      on_me_doit: openIts.filter((x) => x.dir === "eux").length,
      en_retard: openIts.filter((x) => x.etat === "en_retard").length,
    };
    const sig = JSON.stringify(counts) + "|" + filter;
    if (tbHost.dataset.sig === sig) return;
    tbHost.dataset.sig = sig;
    const chipsEl = ds.chips(FILTERS.map(([id, label]) => ({ id, label, n: counts[id], on: id === filter })), (id) => { filter = id; try { localStorage.setItem(FILTER_KEY, id); } catch (e) {} render(); });
    const prevInput = tbHost.querySelector("input");
    const hadFocus = prevInput && document.activeElement === prevInput;
    const tb = ds.toolbar({ search: { placeholder: "Rechercher (quoi, qui, dossier)…", value: query, onInput: (q) => { query = q; render(); } }, chips: chipsEl });
    tbHost.replaceChildren(tb);
    if (hadFocus && tb.input) { tb.input.focus(); try { tb.input.setSelectionRange(tb.input.value.length, tb.input.value.length); } catch (e) {} }
  }

  /* ── Rendu des vues ───────────────────────────────────────────────── */
  const HOW = "Nova relève les engagements explicites dans les mails et messages Teams au corps lu du Fil direct, dans tes conversations, et lors de l'analyse du courrier (Agenda). Rien n'est inventé : sans promesse écrite, rien n'apparaît.";
  const sortOpen = (a, b) => (a.etat === "en_retard" ? 0 : 1) - (b.etat === "en_retard" ? 0 : 1) || String(a.echeance || "9999") .localeCompare(String(b.echeance || "9999"));
  function listView(items, total) {
    /* 25/10 AUTONOMIE : « On me doit une réponse » — mails envoyés restés sans réponse (relevé du moteur), en tête. */
    const showAtt = filter === "tout" || filter === "on_me_doit";
    const att = showAtt ? items.filter((x) => x.status === "ouvert" && x.origine === "attente_reponse").sort(sortOpen) : [];
    const open = items.filter((x) => x.status === "ouvert" && !(showAtt && x.origine === "attente_reponse")).sort(sortOpen);
    const closed = items.filter((x) => x.status !== "ouvert");
    const out = [];
    if (att.length) {
      const as = ds.section({ title: "On me doit une réponse", count: att.length, actions: [{ label: "Vérifier maintenant", ghost: true, tip: "Relit les mails envoyés et les réponses reçues (lecture seule)", onClick: async () => { try { await api.post("/api/autonomie/attente/scan", {}); ctx.toast("Relevé lancé — l'écran se met à jour à la fin."); } catch (e) { ctx.toast("Relevé impossible — le moteur ne répond pas.", true); } } }] });
      as.body.append(h("p", { class: "ds-meta" }, "Mails que tu as envoyés avec une question ou une demande, sans réponse de leur destinataire depuis plusieurs jours. Une réponse reçue les solde d'elle-même."),
        h("div", { class: "ds-list" }, ...att.map((it) => itemRow(it))));
      out.push(as);
    }
    const sec = ds.section({ title: filter === "en_retard" ? "En retard" : filter === "je_dois" ? "Ce que je dois" : filter === "on_me_doit" ? "Ce qu'on me doit" : "Ouverts", count: open.length });
    if (!open.length) {
      sec.body.append(query ? ds.empty({ compact: true, icon: "search", text: "Aucun engagement ouvert ne correspond à « " + query + " ».", action: { label: "Effacer la recherche", onClick: () => { query = ""; tbHost.dataset.sig = ""; render(); } } })
        : !total ? ds.empty({ icon: "check", text: "Aucun engagement relevé pour l'instant. " + HOW, action: { label: "Ouvrir le Fil direct", onClick: () => ctx.navigate("conversations") } })
          : ds.empty({ compact: true, icon: "check", text: filter === "en_retard" ? "Rien en retard — tout est à jour." : filter === "je_dois" ? "Tu ne dois rien d'ouvert." : filter === "on_me_doit" ? "Personne ne te doit rien d'ouvert." : "Aucun engagement ouvert — tout est soldé.", action: filter !== "tout" ? { label: "Voir tout", onClick: () => { filter = "tout"; tbHost.dataset.sig = ""; render(); } } : null }));
    } else sec.body.append(h("div", { class: "ds-list" }, ...open.map((it) => itemRow(it))));
    out.push(sec);
    if (closed.length && filter !== "en_retard") {
      const cs = ds.section({ title: "Clos", count: closed.length, collapsible: true, open: false });
      cs.body.append(h("div", { class: "ds-list" }, ...closed.slice(0, 60).map((it) => itemRow(it))));
      out.push(cs);
    }
    return out;
  }
  function groupView(groups, kind) {
    const byId = new Map(((data && data.items) || []).map((x) => [x.id, x]));
    const title = kind === "p" ? "Personnes" : "Dossiers";
    const sec = ds.section({ title, count: 0 });
    const cards = [];
    for (const g of groups) {
      const its = (g.ids || []).map((id) => byId.get(id)).filter(Boolean).filter(passFilter).filter(passQuery);
      const nameHit = query && String(g.nom || "").toLowerCase().includes(query.toLowerCase());
      if (!its.length && !(nameHit && filter === "tout")) continue;
      const key = kind + ":" + (g.cle != null ? g.cle : g.nom);
      const openIts = its.filter((x) => x.status === "ouvert").sort(sortOpen);
      const shown = openIts.length ? openIts : its;
      const counts = [
        g.je_dois ? (kind === "p" ? "tu lui dois " : "tu dois ") + g.je_dois : "",
        g.on_me_doit ? (kind === "p" ? "te doit " : "on te doit ") + g.on_me_doit : "",
        !g.ouverts ? "rien d'ouvert" : "",
        kind === "p" ? (g.dernier ? "dernier échange relevé " + fmtRelFR(g.dernier) : "") : (g.prochaine ? "prochaine échéance " + dayLabel(g.prochaine) : ""),
      ].filter(Boolean).join(" · ");
      const isOpen = openGroups.has(key) || !!query;
      const det = h("details", { class: "flx-grp" + (g.en_retard ? " is-late" : ""), open: isOpen ? true : null });
      det.addEventListener("toggle", () => { if (det.open) openGroups.add(key); else openGroups.delete(key); });
      det.append(
        h("summary", { class: "flx-grp-h" },
          h("span", { class: "ds-row-lead" }, kind === "p" ? h("span", { class: "flx-av" }, initials(g.nom)) : h("span", { class: "flx-grp-ic", html: ctx.ic("kanban", 16) })),
          h("span", { class: "flx-grp-t" }, h("span", { class: "flx-grp-n" }, String(g.nom || "—")), h("span", { class: "ds-meta flx-grp-c" }, counts || plural(g.total | 0, "engagement clos", "engagements clos"))),
          g.en_retard ? ds.pill(g.en_retard + " en retard", "danger") : g.ouverts ? ds.pill(plural(g.ouverts | 0, "ouvert", "ouverts"), "neutral") : ds.pill("Soldé", "ok"),
          h("span", { class: "flx-grp-chev", "aria-hidden": "true", html: ctx.ic("chev-r", 14) })),
        h("div", { class: "ds-list flx-grp-b" }, ...shown.map((it) => itemRow(it, kind === "p" ? { hidePerson: true } : { hideDossier: true }))));
      cards.push(det);
    }
    sec.setCount(cards.length);
    if (!cards.length) sec.body.append(query || filter !== "tout"
      ? ds.empty({ compact: true, icon: "search", text: "Aucun groupe ne correspond à ces filtres.", action: { label: "Tout afficher", onClick: () => { query = ""; filter = "tout"; tbHost.dataset.sig = ""; render(); } } })
      : ds.empty({ icon: kind === "p" ? "avatar" : "kanban", text: (kind === "p" ? "Aucune personne liée à un engagement." : "Aucun dossier pour l'instant.") + " " + HOW, action: { label: "Voir la liste", onClick: () => { view = "liste"; tabsEl.set("liste"); render(); } } }));
    else sec.body.append(h("div", { class: "flx-grps" }, ...cards));
    return [sec];
  }

  function render() {
    if (dead || !data) return;
    paintKpis();
    const items = Array.isArray(data.items) ? data.items : [];
    paintToolbar(items);
    let out;
    if (view === "personnes") out = groupView(Array.isArray(data.personnes) ? data.personnes : [], "p");
    else if (view === "dossiers") out = groupView(Array.isArray(data.dossiers) ? data.dossiers : [], "d");
    else out = listView(items.filter(passFilter).filter(passQuery), items.length);
    body.replaceChildren(...out);
    const ex = data.extraction || {};
    const bits = [];
    if (ex.en_cours) bits.push("Relevé en cours sur une arrivée du Fil direct…");
    else if (ex.note) bits.push("Dernier relevé automatique " + fmtRelFR(ex.dernier) + " : " + ex.note);
    if (data.last_scan) bits.push("Dernière analyse du courrier " + fmtRelFR(data.last_scan) + ".");
    if (data.extraction_auto === false) bits.push("Relevé automatique désactivé (Réglages › engagements).");
    foot.replaceChildren(...(bits.length ? [bits.join(" ")] : []));
    foot.hidden = !bits.length;
  }

  /* ── Direct : le moteur prévient quand le magasin bouge ───────────── */
  let t = 0;
  const soon = () => { clearTimeout(t); t = setTimeout(() => { if (!dead && !busy() && !document.hidden) load(true); }, 600); };
  const offs = [];
  try { offs.push(bus.on("engagements", soon)); } catch (e) {}
  try { offs.push(bus.on("nova:commitment", soon)); } catch (e) {}
  let lastLoad = Date.now();
  load();
  return {
    destroy() { dead = true; clearTimeout(t); offs.forEach((o) => { try { o && o(); } catch (e) {} }); },
    onShow() { if (Date.now() - lastLoad < 20000 || busy()) return; lastLoad = Date.now(); load(true); },
  };
}
