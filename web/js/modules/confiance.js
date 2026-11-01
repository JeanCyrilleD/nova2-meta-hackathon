/* Module Confiance — VAGUE 1 (24/10/2026), lot « confiance graduée ».
   Source unique : le moteur (Feat_Trust.swift) — GET /api/trust.
     · une politique à 4 niveaux PAR TYPE D'ACTION (agir seule / si pré-approuvé /
       demander à chaque fois / jamais), appliquée dans la garde d'exécution des outils ;
     · les INTERDITS FIXES (envoi, publication, argent/BRVM, suppression définitive,
       secrets) : verrouillés, raison affichée, aucun contrôle ;
     · la fiabilité PROUVÉE : décisions réelles des cartes (approuvé / modifié / refusé),
       30 derniers jours — jamais un chiffre inventé : 0 décision = « pas encore de preuve » ;
     · les propositions d'autonomie (jamais automatiques) : accepter / refuser / revenir.
   Assouplir un niveau ou accepter une proposition exige la provenance d'interface
   (window.__novaProv) : ni un Dot ni un script ne peut s'accorder de l'autonomie. */
/* V6 (25/10) — refonte premium (contrat conseil_24-10/V6_DESIGN.md) : en-tête ds ; synthèse en métriques
   (seule / demande / jamais / décisions sur 30 j) ; sélecteur de niveau compact (segmenté) par type ;
   étiquette « défaut » retirée — seule une valeur que tu as changée est marquée « modifié » ; barre de
   fiabilité alignée ; interdits fixes en liste repliée ; états chargement / erreur / vide du système.
   Routes, provenance d'interface et garanties inchangées. */
import * as ds from "../ds.js";
const LEVELS = [
  { id: "seul", label: "Seule", title: "Agir seule : aucune carte de la couche Confiance (les gardes existantes restent actives)" },
  { id: "regle", label: "Si pré-approuvé", title: "Agir seule quand tu le demandes en conversation ; carte quand l'action vient d'ailleurs (Éclat, automatisme)" },
  { id: "demander", label: "Demander", title: "Une carte d'approbation à chaque fois" },
  { id: "jamais", label: "Jamais", title: "Nova rend la main : l'action n'est jamais exécutée" },
];
const LEVEL_TXT = { seul: "agir seule", regle: "si pré-approuvé", demander: "demander à chaque fois", jamais: "jamais" };
const POINT_TXT = { destinataire: "Destinataire", ton: "Ton", faits: "Faits", piece_jointe: "Pièce jointe", sensible: "Sensible", demande: "Demande" };

export async function mount(root, ctx) {
  const { api, h, ic, bus } = ctx;
  let dead = false;
  let data = null;
  root.classList.add("tr");
  const prov = () => (typeof window !== "undefined" && window.__novaProv ? { "x-nova-provenance": window.__novaProv } : {});
  const errBox = (msg, retry) => ds.errorBox({ title: "Impossible de charger", cause: msg, retry });

  const bluf = h("div", { class: "tr-kpis" });
  const propBox = h("div", {});
  const tableBox = h("div", {}, ds.skeleton(5));
  const lockBox = h("div", {});
  const reviewBox = h("div", {});
  root.append(
    ds.pageHead({ title: "Confiance", sub: "Ce que Nova fait seule, ce qu'elle demande, ce qu'elle ne fera jamais.",
      actions: [{ label: "Journal d'audit", icon: "journal", ghost: true, tip: "Ouvrir le journal d'audit (lecture seule)", onClick: () => ctx.navigate("journal") }] }),
    bluf, propBox, tableBox, lockBox, reviewBox);

  /* ── Synthèse : métriques calculées sur les données réelles (ex-phrase BLUF) ── */
  function blufKpis(d) {
    const cats = d.categories || [];
    const free = cats.filter((c) => !c.fixed && c.level === "seul").length;
    const ask = cats.filter((c) => !c.fixed && (c.level === "demander" || c.level === "regle")).length;
    const never = cats.filter((c) => c.fixed || c.level === "jamais").length;
    const proved = cats.reduce((n, c) => n + ((c.stats && ((c.stats.approuve || 0) + (c.stats.modifie || 0) + (c.stats.refuse || 0))) || 0), 0);
    const props = (d.proposals || []).length;
    const t = (n) => n + (n > 1 ? " types d'action" : " type d'action");
    return ds.kpis([
      { label: "Agit seule", value: String(free), delta: t(free) },
      { label: "Demande ou suit ta règle", value: String(ask), delta: t(ask) },
      { label: "Jamais", value: String(never), delta: "interdits et niveaux « jamais »" },
      { label: "Décisions réelles (30 j)", value: String(proved), delta: props ? props + (props > 1 ? " propositions t'attendent" : " proposition t'attend") : (proved ? "fondent sa fiabilité" : "la preuve se fait carte après carte"), tone: props ? "warn" : "" },
    ]);
  }

  /* ── fiabilité : compteurs + barre (approuvé / modifié / refusé), honnête à vide ── */
  function proof(st) {
    const a = (st && st.approuve) || 0, m = (st && st.modifie) || 0, r = (st && st.refuse) || 0;
    const n = a + m + r;
    if (!n) return h("div", { class: "tr-proof empty-proof" }, h("span", { class: "ds-meta" }, "Pas encore de preuve"));
    const pct = (x) => Math.round((x / n) * 1000) / 10 + "%";
    return h("div", { class: "tr-proof", title: a + " approuvée(s) telle(s) quelle(s), " + m + " modifiée(s), " + r + " refusée(s) — 30 derniers jours" },
      h("div", { class: "tr-bar", role: "img", "aria-label": a + " approuvées, " + m + " modifiées, " + r + " refusées" },
        a ? h("span", { class: "tr-seg ok", style: "width:" + pct(a) }) : null,
        m ? h("span", { class: "tr-seg warn", style: "width:" + pct(m) }) : null,
        r ? h("span", { class: "tr-seg bad", style: "width:" + pct(r) }) : null),
      h("div", { class: "tr-counts" },
        h("span", {}, h("b", {}, String(a)), " approuvé" + (a > 1 ? "s" : "")),
        h("span", {}, h("b", {}, String(m)), " modifié" + (m > 1 ? "s" : "")),
        h("span", {}, h("b", {}, String(r)), " refusé" + (r > 1 ? "s" : ""))));
  }

  async function setLevel(c, lvl, seg) {
    if (lvl === c.level) return;
    for (const b of seg.querySelectorAll("button")) b.disabled = true;
    try {
      const j = await api.post("/api/trust/policy", { type: c.id, niveau: lvl }, 15000, prov());
      ctx.toast((j && j.message) || "Niveau enregistré.");
    } catch (e) {
      ctx.toast("Niveau non modifié : " + String((e && e.body && e.body.error) || (e && e.message) || e), true);
    }
    load();
  }
  function segment(c) {
    const seg = h("div", { class: "seg tr-seg-ctl", role: "radiogroup", "aria-label": "Niveau pour « " + c.label + " »" });
    for (const l of LEVELS) {
      seg.append(h("button", { class: l.id === c.level ? "on" : "", role: "radio", "aria-checked": l.id === c.level ? "true" : "false", title: l.title, onclick: () => setLevel(c, l.id, seg) }, l.label));
    }
    return seg;
  }
  function row(c) {
    const tags = [];
    /* V6 : plus de « défaut » sur chaque ligne (bruit) — seule une valeur que tu as choisie est signalée. */
    if (c.explicit) tags.push(h("span", { class: "tr-tag is-mod", title: "Niveau choisi par toi (différent de la valeur par défaut prudente)" }, "modifié"));
    if (!c.dot_ok) tags.push(h("span", { class: "tr-tag", title: "Un Éclat ne peut jamais l'exécuter sans ta carte (garantie dans le code)" }, "Éclats : carte"));
    if (c.reversible) tags.push(h("span", { class: "tr-tag", title: "Réversible : Nova peut te proposer plus d'autonomie quand la preuve est faite" }, "réversible"));
    return h("div", { class: "tr-row" },
      h("div", { class: "tr-what" },
        h("div", { class: "tt" }, String(c.label), ...tags),
        h("div", { class: "ss", title: String(c.desc || "") }, String(c.desc || ""))),
      segment(c),
      proof(c.stats));
  }
  function lockRow(c) {
    const st = c.stats || {};
    const n = (st.approuve || 0) + (st.modifie || 0) + (st.refuse || 0);
    return h("div", { class: "tr-row tr-locked" },
      h("div", { class: "tr-what" },
        h("div", { class: "tt" }, h("span", { class: "tr-lock", html: ic("lock", 14) }), " " + String(c.label)),
        h("div", { class: "ss" }, String(c.reason || ""))),
      h("div", { class: "tr-fixed", title: "Interdit fixe : non modifiable, même par autorisation totale" }, h("span", { html: ic("lock", 13) }), " Jamais — verrouillé"),
      c.id === "envoi" && n ? proof(st) : h("div", { class: "tr-proof empty-proof" }, h("span", { class: "ss" }, c.id === "envoi" ? "Aucune carte d'envoi décidée sur 30 jours" : "Hors de portée de Nova")));
  }

  async function decide(p, accept, btns) {
    btns.forEach((b) => (b.disabled = true));
    try {
      const j = await api.post("/api/trust/proposal", { id: p.id, accept }, 15000, accept ? prov() : {});
      ctx.toast((j && j.message) || "Décision enregistrée.");
    } catch (e) {
      ctx.toast("Décision non enregistrée : " + String((e && e.body && e.body.error) || (e && e.message) || e), true);
    }
    load();
  }
  function proposalCard(p) {
    const ev = p.evidence || {};
    const yes = ds.action({ label: "Accepter", primary: true });
    const no = ds.action({ label: "Refuser" });
    yes.onclick = () => decide(p, true, [yes, no]);
    no.onclick = () => decide(p, false, [yes, no]);
    return ds.card({ class: "tr-prop" },
      h("div", { class: "tr-prop-ic", html: ic("sparkle", 18) }),
      h("div", { class: "grow" },
        h("div", { class: "tt" }, "« " + String(p.label || p.type) + " » : passer de « " + (LEVEL_TXT[p.from] || p.from) + " » à « " + (LEVEL_TXT[p.to] || p.to) + " »"),
        h("div", { class: "ss" }, String(p.text || "")),
        h("div", { class: "ss tr-evidence" }, (ev.approuve || 0) + " approbations · " + (ev.modifie || 0) + " modifiées · " + (ev.refuse || 0) + " refus · " + (ev.jours || 30) + " jours")),
      h("div", { class: "tr-prop-act" }, no, yes));
  }
  function acceptedRow(p) {
    const back = ds.action({ label: "Revenir", icon: "undo", tip: "Revenir à « " + (LEVEL_TXT[p.from] || p.from) + " »" });
    back.addEventListener("click", () => decide(p, false, [back]));
    back.classList.add("is-primary");   // action principale de la ligne : toujours visible
    return ds.row({ lead: "check", title: "« " + String(p.label || p.type) + " » en « " + (LEVEL_TXT[p.to] || p.to) + " »",
      meta: "Proposition acceptée" + (p.decidedAt ? " le " + new Date(p.decidedAt).toLocaleDateString("fr-FR", { day: "numeric", month: "short" }) : "") + " — réversible en un clic", actions: [back] });
  }
  function reviewRow(r) {
    const pts = Array.isArray(r.points) ? r.points : [];
    const state = r.statut !== "fait" ? "neutral" : r.ok ? "ok" : "warn";
    return h("div", { class: "ds-row tr-review" },
      h("div", { class: "ds-row-main" },
        h("div", { class: "ds-row-title" }, (r.channel === "teams" ? "Teams · " : "Mail · ") + String(r.dest || "destinataire inconnu") + (r.subject ? " — " + String(r.subject) : "")),
        h("div", { class: "ds-row-meta" }, String(r.ligne || (r.ok ? "Relecture : rien à signaler." : "Relecture"))),
        pts.length ? h("ul", { class: "tr-points" }, ...pts.map((p) => h("li", {}, h("b", {}, (POINT_TXT[p.type] || "Point") + " : "), String(p.texte || "")))) : null,
        !r.demande_connue && r.statut === "fait" ? h("div", { class: "ds-row-meta" }, "Demande d'origine introuvable : forme et données sensibles seulement.") : null),
      h("div", { class: "ds-row-side" }, ds.pill(r.statut !== "fait" ? "En cours" : r.ok ? "Relu" : "Points à voir", state)));
  }

  function render(d) {
    data = d;
    const cats = Array.isArray(d.categories) ? d.categories : [];
    if (!cats.length) {
      bluf.replaceChildren();
      tableBox.replaceChildren(errBox("Le moteur n'a pas renvoyé la politique de confiance.", load));
      propBox.replaceChildren(); lockBox.replaceChildren(); reviewBox.replaceChildren();
      return;
    }
    bluf.replaceChildren(blufKpis(d));
    const props = Array.isArray(d.proposals) ? d.proposals : [];
    const acc = Array.isArray(d.accepted) ? d.accepted : [];
    const th = d.threshold || {};
    propBox.replaceChildren(...(props.length || acc.length ? [ds.section({ title: "Propositions d'autonomie", count: props.length || null, body: [
      ...props.map(proposalCard),
      ...(acc.length ? [ds.card({ flush: true, class: "tr-accepted" }, ...acc.map(acceptedRow))] : []),
    ] })] : []));
    const free = cats.filter((c) => !c.fixed);
    tableBox.replaceChildren(ds.section({ title: "Par type d'action", count: free.length, body: [
      h("p", { class: "ds-meta tr-desc" }, "Choisis le niveau de chaque type d'action. Fiabilité : décisions réelles de tes cartes, 30 derniers jours."),
      ds.card({ class: "tr-table" },
        h("div", { class: "tr-row tr-headrow", "aria-hidden": "true" }, h("div", {}, "Type d'action"), h("div", {}, "Niveau"), h("div", {}, "Fiabilité prouvée")),
        ...free.map(row)),
      h("p", { class: "ds-meta tr-note" }, "La couche Confiance ne fait que durcir : les gardes existantes (réglages par outil, garde du shell, permis d'agir) restent actives à tous les niveaux. Nova te propose plus d'autonomie — jamais d'elle-même — quand un type réversible atteint " + (th.approuve || 20) + " approbations sans refus en " + (th.jours || 30) + " jours." + (d.full_auto ? " Autorisation totale active : « Écrire sur le Mac » démarre à « si pré-approuvé »." : ""))] }));
    const fixed = cats.filter((c) => c.fixed);
    /* V6 : interdits fixes en liste REPLIÉE — non modifiables, donc secondaires à l'écran. */
    lockBox.replaceChildren(ds.section({ title: "Interdits fixes", count: fixed.length, collapsible: true, open: false, body: [
      h("p", { class: "ds-meta tr-desc" }, "Non modifiables, même par autorisation totale — Nova te rend la main."),
      ds.card({ class: "tr-table" }, ...fixed.map(lockRow))] }));
    const revs = Array.isArray(d.reviews) ? d.reviews : [];
    reviewBox.replaceChildren(ds.section({ title: "Relecteur indépendant", count: revs.length, body: [
      h("p", { class: "ds-meta tr-desc" }, "Chaque brouillon d'envoi est relu avant ta carte — il ne bloque rien, ne réécrit rien."),
      revs.length ? ds.card({ flush: true }, h("div", { class: "ds-list" }, ...revs.map(reviewRow)))
        : ds.empty({ icon: "check", compact: true, text: "Aucun brouillon d'envoi relu pour le moment." })] }));
  }

  let lastLoad = 0;
  async function load() {
    lastLoad = Date.now();
    if (!data) tableBox.replaceChildren(ds.skeleton(5));
    try {
      const j = await api.get("/api/trust");
      if (dead) return;
      render(j || {});
    } catch (e) {
      if (dead) return;
      bluf.replaceChildren();
      tableBox.replaceChildren(errBox("Politique de confiance injoignable pour le moment.", load));
    }
  }
  const offs = [];
  try { offs.push(bus.on("trust_proposal", () => load())); } catch (e) {}
  try { offs.push(bus.on("draft_review", () => load())); } catch (e) {}
  load();
  return {
    destroy() { dead = true; offs.forEach((o) => { try { o(); } catch (e) {} }); },
    onShow() { if (Date.now() - lastLoad < 15000) return; load(); },
  };
}
