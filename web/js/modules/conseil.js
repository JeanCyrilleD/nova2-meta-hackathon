/* Module Conseil — la délibération multi-cerveaux de Nova 1, restaurée :
   POST /api/council/stream (SSE : chaque cerveau répond, le conseil arbitre),
   GET /api/council/history (les délibérations passées), et le Jumeau de décision
   (amendement n°6 : POST /api/decision/twin → mémo pour/contre SOURCÉ, historique
   GET /api/decision/log). Le preset Sparring (amendement n°25) attaque la position
   au lieu de la conseiller — c'est un mode de question, dit comme tel.
   Courtier (Φ1) : le conseil propose, il n'exécute rien. */
/* UI TOTALE phase 3 (DS §6.6/§8.3, constats C-16/C-17/C-18, résidu C2) : UN plafond
   pour tout l'écran — formulaires ET résultats — porté par .mod--form (--read-form,
   820 px), plus aucun max-width inline ; tous les champs en .fld/.fld-area libellés ;
   sections en .sec-head/h2 ; sparring = interrupteur à libellé stable + pastille
   d'état (le bouton ne change plus de libellé ni de largeur) ; Studio Meta en UNE
   carte : concept SAM + AIDE PERMANENTE en texte visible (.field-help, jamais le
   placeholder seul), rangée source (généré/choisir + nom), « Découper » à droite de
   cette rangée. Dates et nombres par les helpers FR de core.js (§9.8). */
/* V6 (25/10) — refonte premium (contrat conseil_24-10/V6_DESIGN.md) : en-tête ds.pageHead ; modes en
   ds.tabs ; question + options dans UNE carte de composition (interrupteurs sans pastille d'état
   redondante — l'état se lit sur l'interrupteur, le détail en infobulle) ; délibérations passées en
   lignes ds (question, date, statut « En attente de ton GO » / « Décidé ») qui ouvrent une VUE DÉTAIL
   (avis, réfutations, décision, puis les actions GO qui existent : appliquer, relancer). Aucune route,
   aucun événement du flux ni aucune garde ne change. */
import { sse, md, truncWords, fmtDateFR, fmtTimeFR, fmtNumFR } from "../core.js";
import * as ds from "../ds.js";
const arrOf = (j, ...keys) => { if (Array.isArray(j)) return j; for (const k of keys) if (j && Array.isArray(j[k])) return j[k]; return []; };
const fmtDT = (v) => { const s = fmtDateFR(v); return s ? s + " · " + fmtTimeFR(v) : String(v || "").slice(0, 16); };
/* FIX-WEB : Entrée envoie, Maj+Entrée = nouvelle ligne ; jamais pendant une composition (accents morts, dictée, IME). */
/* V6 : compteur de section posé après chargement (ds.section ne crée le compteur que s'il est connu au montage). */
const setSecCount = (sec, n) => { let c = sec.querySelector(":scope > .ds-section-head > .ds-count"); if (!c) { c = document.createElement("span"); c.className = "ds-count"; const h2 = sec.querySelector(":scope > .ds-section-head > .ds-h2"); if (h2) h2.after(c); } c.textContent = String(n); c.setAttribute("aria-label", n + " éléments"); };
const enterSends = (el, fn) => el.addEventListener("keydown", (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); fn(); } });

export async function mount(root, ctx) {
  const { api, h, ic } = ctx;
  let dead = false, ac = null;
  root.classList.add("cn-v6");
  root.append(ds.pageHead({ title: "Conseil", sub: "Plusieurs cerveaux débattent — avis, réfutation, vote — puis le président tranche." }));

  const q = h("textarea", { rows: "3", id: "conseil-q", class: "fld fld-area cn-q-in", placeholder: "La question à soumettre au conseil…" });
  /* Interrupteur à libellé stable : l'état se lit sur l'interrupteur (aria-checked), l'effet en infobulle —
     plus de pastille d'état qui répète l'interrupteur à côté. */
  const toggle = (label, tip, on, onChange) => {
    const b = h("button", { type: "button", class: "switch", role: "switch", "aria-checked": on ? "true" : "false", "aria-label": label, title: tip() });
    b.addEventListener("click", () => { const v = b.getAttribute("aria-checked") !== "true"; b.setAttribute("aria-checked", v ? "true" : "false"); onChange(v); b.title = tip(); lb.title = tip(); });
    const lb = h("span", { class: "cn-opt-lb", title: tip() }, label);
    lb.addEventListener("click", () => b.click());
    return h("div", { class: "cn-opt" }, b, lb);
  };
  let sparring = false;
  const sparOpt = toggle("Sparring : attaquer ma position", () => sparring ? "Activé — le conseil attaquera ta position au lieu de la conseiller." : "Inactif — le conseil conseille.", false, (v) => { sparring = v; });
  /* FIX-WEB C7 : « Le président applique la décision » → act:true (Council.swift : sans act, aucune exécution).
     Activé par défaut (grille : le président implémente directement) ; envois, paiements et suppressions
     restent soumis à ton GO (cartes d'approbation ci-dessous). */
  let act = true;
  try { const v = localStorage.getItem("nova2_council_act"); if (v === "0") act = false; } catch (e) {}
  const actOpt = toggle("Le président applique la décision", () => act ? "Activé — le président applique ; envois, paiements et suppressions attendent toujours ton GO." : "Coupé — décision seule, rien n'est exécuté.", act,
    (v) => { act = v; try { localStorage.setItem("nova2_council_act", act ? "1" : "0"); } catch (e) {} });
  const out = h("div", { class: "cn-out" });
  const goBtn = ds.action({ label: "Réunir le conseil", icon: "council", primary: true, onClick: () => run() });
  /* NOVA2-FIX (reco n°18) : ligne des membres du conseil + badge Muse Spark — le badge
     n'apparaît QUE si un événement réel du flux (members / mbrain / chairbrain) nomme
     Spark ; jamais affiché « au cas où ». */
  const metaRow = h("div", { class: "cn-metarow" });
  let sparkShown = false;
  function showSpark(role) {
    if (sparkShown || dead) return; sparkShown = true;
    metaRow.append(h("span", { class: "spark-badge" }, h("span", { html: ic("zap", 13) }), " Propulsé par Muse Spark (" + role + ")"));
  }
  const panelConseil = h("div", { class: "cn-panel-mode" });
  const panelJumeau = h("div", { class: "cn-panel-mode", hidden: "" });
  const panelStudio = h("div", { class: "cn-panel-mode", hidden: "" });
  const showPanel = (name) => {
    panelConseil.hidden = name !== "conseil";
    panelJumeau.hidden = name !== "jumeau";
    panelStudio.hidden = name !== "studio";
  };
  const modeTabs = ds.tabs([{ id: "conseil", label: "Conseil" }, { id: "jumeau", label: "Jumeau" }, { id: "studio", label: "Studio Meta" }], showPanel);
  const listView = h("div", { class: "cn-listview" });
  const detailView = h("div", { class: "cn-detail", hidden: "" });
  listView.append(
    ds.card({ class: "cn-composer" },
      h("label", { class: "cn-lb", for: "conseil-q" }, "Question au conseil"), q,
      h("div", { class: "ds-meta cn-help" }, "Entrée envoie · Maj+Entrée va à la ligne. Trois temps : avis indépendants, réfutation, décision motivée du président."),
      h("div", { class: "cn-composer-foot" }, h("div", { class: "cn-opts" }, sparOpt, actOpt), goBtn)),
    metaRow, out);
  panelConseil.append(listView, detailView);
  enterSends(q, () => run());
  root.append(modeTabs, panelConseil, panelJumeau, panelStudio);

  /* V3 CONSEIL (24/10) — « salle du conseil » : la délibération en 3 temps rendue lisible.
     Ordre de lecture : décision BLUF en tête → membres (cerveau, position, confiance en jauge)
     → réfutations (qui attaque qui, position maintenue/révisée) → carte des désaccords pour/contre
     → vote motivé → risques / ce qu'il faudrait savoir → application par le président.
     Le même rendu sert au direct (flux SSE) et aux séances archivées (GET /api/council/get) ;
     un ancien tour sans réfutation ni vote garde ses sections vides masquées — rien n'est inventé. */
  const PHASES = [["avis", "Avis indépendants"], ["refutation", "Réfutation"], ["president", "Président"], ["application", "Application"]];
  const VOTES = [["pour", "Pour"], ["contre", "Contre"], ["abstention", "Abstention"]];
  const fold = (s) => String(s || "").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");
  /* Même lecture que CouncilStore.section (Swift) : rubrique « ## Titre » ou « **Titre** » dont le titre contient key. */
  const sectionOf = (text, key) => {
    const out = []; let inside = false;
    for (const line of String(text || "").split("\n")) {
      const t = line.trim();
      const isHead = t.startsWith("#") || (t.length > 4 && t.length < 70 && t.startsWith("**") && t.endsWith("**"));
      if (isHead) { if (inside) break; if (fold(t).includes(key)) inside = true; continue; }
      if (inside) out.push(line);
    }
    return out.join("\n").trim();
  };
  const firstLine = (s) => { for (const raw of String(s || "").split("\n")) { const t = raw.replace(/\*\*/g, "").replace(/^[\s\-*•>#]+/, "").trim(); if (t) return t; } return ""; };
  const confOf = (text) => {
    const line = String(text || "").split("\n").find((l) => fold(l).includes("confiance")) || "";
    for (const src of [sectionOf(text, "confiance"), line]) {
      const m = /(\d{1,3})\s*(\/\s*100|%|\/\s*10)?/.exec(src || "");
      if (m) { let v = +m[1]; if (String(m[2] || "").replace(/\s/g, "") === "/10") v *= 10; if (v >= 0 && v <= 100) return v; }
    }
    return null;
  };
  const plain = (s) => String(s || "").replace(/[#*_`>]/g, "").replace(/\s+/g, " ").trim();
  const initial = (s) => (String(s || "?").replace(/^muse\s+/i, "").trim()[0] || "?").toUpperCase();
  const confNum = (v) => (typeof v === "number" && v >= 0 && v <= 100 ? v : null);

  function makeRoom({ question, sparring, live }) {
    const el = h("section", { class: "cn-room", "aria-live": live ? "polite" : "off" });
    const steps = new Map();
    const stepper = h("ol", { class: "cn-steps", "aria-label": "Déroulé de la délibération" },
      ...PHASES.map(([k, lb]) => { const li = h("li", { class: "cn-step", "data-st": "todo" }, h("span", { class: "cn-step-dot" }), h("span", { class: "cn-step-lb" }, lb), h("span", { class: "cn-step-lim" })); steps.set(k, li); return li; }));
    const headTools = h("div", { class: "cn-head-tools" });
    const meta = h("div", { class: "cn-meta" });
    const usageEl = h("span", { class: "cn-usage" });
    el.append(
      h("header", { class: "cn-head" },
        h("div", { class: "cn-head-main" },
          h("div", { class: "cn-kicker" }, sparring ? "Sparring · le conseil attaque ta position" : "Séance du conseil"),
          h("div", { class: "cn-q" }, String(question || ""))),
        headTools),
      stepper, meta);
    /* BLUF — la recommandation du président, en tête. */
    const blufT = h("div", { class: "cn-bluf-t" }, live ? "Le conseil délibère : la recommandation du président s'affichera ici." : "Pas de recommandation enregistrée pour ce tour.");
    const blufV = h("div", { class: "cn-bluf-v" });
    const bluf = h("div", { class: "cn-bluf", "data-st": "wait" }, h("div", { class: "cn-bluf-k" }, h("span", { html: ic("council", 15) }), "Décision recommandée"), blufT, blufV);
    el.append(bluf);
    /* Membres */
    const grid = h("div", { class: "cn-grid" });
    const secAvis = h("div", { class: "cn-sec" }, h("h3", { class: "cn-h" }, "Avis indépendants"), grid);
    el.append(secAvis);
    const cards = new Map();
    const card = (id, label, role, family) => {
      let c = cards.get(id);
      if (c) return c;
      const brain = h("div", { class: "cn-brain", title: String(label || id) }, String(label || id || "Membre"));
      const sub = h("div", { class: "cn-role" }, [role, family].filter(Boolean).join(" · "));
      const dot = h("span", { class: "dotst run", "aria-hidden": "true" });
      const pos = h("div", { class: "cn-pos" });
      const livep = h("div", { class: "cn-live" }, live ? "Réflexion en cours…" : "");
      if (!live) livep.hidden = true;
      const fill = h("span", { class: "cn-gauge-fill" });
      const gauge = h("div", { class: "cn-gauge", role: "meter", "aria-valuemin": "0", "aria-valuemax": "100", "aria-label": "Confiance" }, fill);
      const confN = h("span", { class: "cn-conf-n" }, "—");
      const conf = h("div", { class: "cn-conf", hidden: "" }, h("span", { class: "cn-conf-k" }, "Confiance"), gauge, confN);
      const toolsRow = h("div", { class: "cn-tools" });
      const fullT = h("div", { class: "brief-text" });
      const more = h("details", { class: "cn-more", hidden: "" }, h("summary", {}, "Avis complet"), fullT);
      const err = h("div", { class: "cn-err", hidden: "" });
      const wrap = h("article", { class: "cn-card", "data-st": live ? "run" : "ok" },
        h("div", { class: "cn-card-top" }, h("span", { class: "cn-av", "aria-hidden": "true" }, initial(label || id)), h("div", { class: "cn-who" }, brain, sub), dot),
        pos, livep, conf, toolsRow, err, more);
      if (!live) dot.className = "dotst ok";
      grid.append(wrap);
      c = { id, label: String(label || id), acc: "", wrap, brain, sub, dot, pos, livep, fill, gauge, confN, conf, toolsRow, fullT, more, err, confidence: null };
      cards.set(id, c);
      return c;
    };
    const setConf = (c, v) => {
      if (v == null) { c.conf.hidden = true; return; }
      c.conf.hidden = false; c.confidence = v;
      c.fill.style.width = v + "%"; c.gauge.setAttribute("aria-valuenow", String(v));
      c.confN.textContent = v + "/100";
      c.gauge.dataset.lv = v >= 70 ? "hi" : v >= 40 ? "mid" : "lo";
    };
    /* Réfutations */
    const refList = h("div", { class: "cn-refs" });
    const secRef = h("div", { class: "cn-sec", hidden: "" }, h("h3", { class: "cn-h" }, "Réfutations"), h("p", { class: "cn-help" }, "Chaque membre a lu les autres avis : il attaque le point le plus faible d'un autre membre, ou révise sa position."), refList);
    el.append(secRef);
    const refs = new Map();
    const refCard = (id) => {
      let r = refs.get(id);
      if (r) return r;
      const m = cards.get(id);
      const who = h("b", {}, m ? m.label : String(id));
      const target = h("span", { class: "cn-target" });
      const stance = h("span", { class: "chip", hidden: "" });
      const delta = h("span", { class: "cn-cdelta" });
      const txt = h("div", { class: "brief-text" }, live ? h("span", { class: "cn-live" }, "Réfutation en cours…") : "");
      const wrap = h("article", { class: "cn-ref" }, h("div", { class: "cn-ref-top" }, who, target, h("span", { class: "grow" }), stance, delta), txt);
      refList.append(wrap); secRef.hidden = false;
      r = { acc: "", wrap, target, stance, delta, txt };
      refs.set(id, r);
      return r;
    };
    /* Carte des désaccords + vote */
    const vbar = h("div", { class: "cn-vbar", role: "img" });
    const vcols = h("div", { class: "cn-vmap" });
    const disT = h("div", { class: "brief-text cn-dis" });
    const secDis = h("div", { class: "cn-sec", hidden: "" }, h("h3", { class: "cn-h" }, "Carte des désaccords et vote"), vbar, vcols, disT);
    el.append(secDis);
    const duo = h("div", { class: "cn-duo", hidden: "" });
    el.append(duo);
    const fullChair = h("div", { class: "brief-text" });
    const chairMore = h("details", { class: "cn-more cn-chair-more", hidden: "" }, h("summary", {}, "Synthèse complète du président"), fullChair);
    const chairWho = h("span", { class: "cn-chairwho" });
    const chairItem = h("span", { class: "cn-meta-i", hidden: "" }, h("span", { class: "cn-meta-k" }, "Président"), chairWho);
    el.append(chairMore);
    const tail = h("div", { class: "cn-tail" });
    el.append(tail);

    let lastVotes = [];
    const paintVotes = (items) => {
      lastVotes = Array.isArray(items) ? items : [];
      const known = lastVotes.filter((v) => v && v.vote);
      vcols.replaceChildren(); vbar.replaceChildren();
      if (!known.length) { vbar.hidden = true; vcols.hidden = true; return; }
      vbar.hidden = false; vcols.hidden = false;
      const counts = {};
      for (const [k] of VOTES) counts[k] = known.filter((v) => v.vote === k).length;
      vbar.setAttribute("aria-label", VOTES.map(([k, lb]) => lb + " " + counts[k]).join(", "));
      for (const [k, lb] of VOTES) if (counts[k]) vbar.append(h("span", { class: "cn-vseg", "data-v": k, style: "flex:" + counts[k] }, lb + " " + counts[k]));
      for (const [k, lb] of VOTES) {
        const rows = lastVotes.filter((v) => v.vote === k);
        vcols.append(h("div", { class: "cn-vcol", "data-v": k },
          h("div", { class: "cn-vcol-h" }, h("span", { class: "cn-vdot", "aria-hidden": "true" }), lb, h("span", { class: "cn-vcount" }, String(rows.length))),
          ...(rows.length ? rows.map((v) => h("div", { class: "cn-vrow" }, h("div", { class: "cn-vname" }, String(v.label || v.id || "Membre")), v.why ? h("div", { class: "cn-vwhy" }, String(v.why)) : null))
            : [h("div", { class: "cn-vnone" }, "Personne")])));
      }
      const unknown = lastVotes.filter((v) => v && !v.vote);
      if (unknown.length) vcols.append(h("div", { class: "cn-vnote" }, "Vote non attribué par le président : " + unknown.map((v) => String(v.label || v.id)).join(", ") + "."));
      secDis.hidden = false;
    };
    let chairText = "", raf = 0;
    const paintChair = () => {
      raf = 0;
      const t = chairText;
      if (!t) return;
      const reco = sectionOf(t, "recommandation") || sectionOf(t, "synthese");
      const head = reco || (live ? "" : firstLine(t));
      if (head) { blufT.innerHTML = md(head); bluf.dataset.st = "ok"; }
      else if (live) { blufT.textContent = "Le président rédige sa recommandation…"; bluf.dataset.st = "run"; }
      const dis = sectionOf(t, "desaccord");
      if (dis) { disT.innerHTML = md("**Points de désaccord**\n\n" + dis); secDis.hidden = false; }
      const risk = sectionOf(t, "risque"), other = sectionOf(t, "trancher");
      duo.replaceChildren();
      if (risk) duo.append(h("div", { class: "cn-panel" }, h("h3", { class: "cn-h" }, "Risques"), h("div", { class: "brief-text", html: md(risk) })));
      if (other) duo.append(h("div", { class: "cn-panel" }, h("h3", { class: "cn-h" }, "Pour trancher autrement"), h("div", { class: "brief-text", html: md(other) })));
      duo.hidden = !risk && !other;
      fullChair.innerHTML = md(t); chairMore.hidden = false;
    };
    const api_ = {
      el, tail, headTools,
      setMeta(items, d) {
        const names = items.map((m) => String(m.label || m.id || "Membre"));
        if (d && d.chair && !chairWho.textContent) chairWho.textContent = String(d.chair);
        chairItem.hidden = !chairWho.textContent;
        const lim = d && d.limits ? d.limits : null;
        meta.replaceChildren(
          h("span", { class: "cn-meta-i" }, h("span", { class: "cn-meta-k" }, "Membres"), names.join(" · ") || "—"),
          chairItem,
          lim ? h("span", { class: "cn-meta-i", title: "Plafonds de jetons de sortie par appel" }, h("span", { class: "cn-meta-k" }, "Plafonds"), fmtNumFR(lim.member_tokens || 0) + " / " + fmtNumFR(lim.rebuttal_tokens || 0) + " / " + fmtNumFR(lim.chair_tokens || 0) + " jetons") : null,
          usageEl);
        if (lim) {
          const lims = { avis: lim.member_s, refutation: lim.rebuttal_s, president: lim.chair_s, application: lim.exec_s };
          for (const [k, li] of steps) if (lims[k]) li.querySelector(".cn-step-lim").textContent = String(Math.round(lims[k] / 60 * 10) / 10).replace(".", ",") + " min max";
        }
      },
      members(items) { for (const m of items) card(String(m.id || m.label || "membre"), m.label, m.role, m.family); },
      phase(name) {
        let seen = false;
        for (const [k, li] of steps) {
          if (k === name) { li.dataset.st = "run"; seen = true; }
          else if (!seen) li.dataset.st = k === "refutation" && !refs.size && li.dataset.st === "todo" ? "skip" : "done";
        }
      },
      finish(state) {
        for (const [k, li] of steps) {
          if (li.dataset.st === "run") li.dataset.st = state === "cancelled" ? "stop" : "done";
          if (state === "noexec" && k === "application" && li.dataset.st === "todo") li.dataset.st = "skip";
        }
        for (const c of cards.values()) if (c.wrap.dataset.st === "run") { c.wrap.dataset.st = "err"; c.dot.className = "dotst err"; c.livep.textContent = state === "cancelled" ? "Interrompu." : "Sans réponse."; }
        if (bluf.dataset.st !== "ok") { bluf.dataset.st = "wait"; blufT.textContent = state === "cancelled" ? "Séance annulée avant la décision du président." : "Le président n'a pas rendu de recommandation."; }
      },
      brain(id, label) { const c = cards.get(String(id)); if (c && label) { c.brain.textContent = String(label); c.brain.title = String(label); c.label = String(label); } },
      delta(id, t) { const c = card(String(id || "?")); c.acc += t; c.livep.textContent = "… " + plain(c.acc).slice(-200); },
      tool(id, name) { const c = cards.get(String(id)); if (c) { c.acc = ""; c.toolsRow.append(h("span", { class: "cn-tool" }, h("span", { html: ic("search", 11) }), String(name || "outil"))); c.livep.textContent = "Consulte " + String(name || "un outil") + "…"; } },
      done(d) {
        const c = card(String(d.id || "?"));
        const text = typeof d.text === "string" && d.text ? d.text : c.acc;
        if (d.ok === false || !text) {
          c.wrap.dataset.st = "err"; c.dot.className = "dotst err"; c.livep.textContent = "";
          c.err.hidden = false; c.err.replaceChildren(h("span", { html: ic("alert", 13) }), " " + String(d.error || "membre sans réponse"));
          return;
        }
        c.acc = text; c.wrap.dataset.st = "ok"; c.dot.className = "dotst ok"; c.livep.textContent = ""; c.livep.hidden = true;
        const p = String(d.position || firstLine(sectionOf(text, "position")) || "");
        c.pos.textContent = p || "Position non formulée (voir l'avis complet).";
        if (!p) c.pos.classList.add("cn-pos--none");
        setConf(c, confNum(d.confidence) ?? confOf(text));
        if (Array.isArray(d.tools) && d.tools.length && !c.toolsRow.childElementCount) for (const n of d.tools) c.toolsRow.append(h("span", { class: "cn-tool" }, h("span", { html: ic("search", 11) }), String(n)));
        c.fullT.innerHTML = md(text); c.more.hidden = false;
      },
      refBrain(id, label) { refCard(String(id)); if (label) { const r = refs.get(String(id)); r.wrap.title = "Cerveau : " + String(label); } },
      refDelta(id, t) { const r = refCard(String(id)); r.acc += t; r.txt.textContent = "… " + plain(r.acc).slice(-220); },
      refDone(d) {
        const r = refCard(String(d.id || "?"));
        const text = typeof d.text === "string" && d.text ? d.text : r.acc;
        if (d.ok === false || !text) { r.wrap.classList.add("cn-ref--err"); r.txt.replaceChildren(h("span", { class: "cn-err" }, h("span", { html: ic("alert", 13) }), " Réfutation indisponible — " + String(d.error || "sans réponse"))); return; }
        r.target.replaceChildren(d.target_label ? h("span", {}, h("span", { class: "cn-arrow", "aria-hidden": "true" }, "→"), " vise ", h("b", {}, String(d.target_label))) : "");
        if (d.stance) { r.stance.hidden = false; r.stance.textContent = "Position " + String(d.stance); r.stance.className = "chip " + (d.stance === "révisée" ? "warn" : "ok"); }
        const before = cards.get(String(d.id)) ? cards.get(String(d.id)).confidence : null;
        const after = confNum(d.confidence);
        r.delta.textContent = after == null ? "" : (before != null && before !== after ? "confiance " + before + " → " + after : "confiance " + after);
        const body = sectionOf(text, "refut") || text;
        const pos = sectionOf(text, "position");
        r.txt.innerHTML = md(body + (pos && sectionOf(text, "refut") ? "\n\n**Position finale** — " + pos : ""));
      },
      chairBrain(label) { if (label) { chairWho.textContent = String(label); chairItem.hidden = false; } },
      chairDelta(t) { chairText += t; if (!raf) raf = requestAnimationFrame(paintChair); },
      chairSet(t) { chairText = String(t || ""); paintChair(); },
      votes(items) { paintVotes(items); },
      usage(u) { if (u && (u.in || u.out)) usageEl.replaceChildren(h("span", { class: "cn-meta-k" }, "Jetons réels"), fmtNumFR(u.in || 0) + " entrée · " + fmtNumFR(u.out || 0) + " sortie"); },
      verdict(decided) { if (decided) blufV.replaceChildren(h("details", {}, h("summary", {}, "Décisions à appliquer"), h("div", { class: "brief-text", html: md(String(decided)) }))); },
    };
    return api_;
  }

  function run() {
    const text = q.value.trim();
    if (!text || ac) return;
    const box = h("div", { class: "cn-session" });
    out.prepend(box);
    metaRow.replaceChildren(); sparkShown = false;
    session(box, "/api/council/stream", { question: text, sparring, act }, () => { q.value = ""; }, { question: text, sparring });
  }

  /* Une séance ou une relance (même flux SSE, Council.swift councilSession) : members, phase, mbrain, mtool, mdelta, mdone,
     rbrain, rdelta, rdone, chair, chairbrain, delta, votes, usage, saved, exec, xtool, xdelta, step, confirm, report, cancelled, error, done. */
  async function session(box, path, payload, onOk, info) {
    if (ac) return;
    ac = new AbortController();
    goBtn.disabled = true;
    const R = makeRoom({ question: (info && info.question) || payload.question, sparring: !!(info && info.sparring), live: true });
    box.append(R.el);
    let runId = "", savedId = "", anyText = false, ended = "", execCard = null, execAcc = "";
    const confirms = new Map();
    const cancelBtn = ds.action({ label: "Annuler", icon: "stop", tip: "Arrête les membres, la réfutation, le président et l'application" });
    cancelBtn.classList.add("cn-cancel");
    cancelBtn.addEventListener("click", async () => {
      cancelBtn.disabled = true; cancelBtn.lastChild.textContent = "Annulation…";
      let ok = false;
      if (runId) { try { const j = await api.post("/api/council/cancel", { run: runId }); ok = !!(j && j.ok); } catch (e) {} }
      if (!ok && ac) ac.abort();
    });
    R.headTools.append(cancelBtn);
    const ensureExec = () => {
      if (!execCard) {
        const el = h("div", { class: "brief-text" });
        const status = h("div", { class: "ss ss--wrap", style: "margin-bottom:var(--sp-2)" });
        const steps = h("div", { class: "rows", style: "margin-bottom:var(--sp-2)" });
        execCard = h("div", { class: "cn-panel cn-exec" }, h("h3", { class: "cn-h" }, "Application des décisions"), status, steps, el);
        execCard._el = el; execCard._status = status; execCard._steps = steps; execCard._rows = new Map(); R.tail.append(execCard);
      }
      return execCard;
    };
    /* Étapes du président (événement step : {id,index,tool,arg,state:run|ok|err,beat?}) — une ligne par étape, mise à jour en place. */
    const stepRow = (d) => {
      const x = ensureExec();
      const id = String(d.id || d.index || x._rows.size);
      let r = x._rows.get(id);
      if (!r) { r = { dot: h("span", { class: "dotst idle" }), txt: h("span", { class: "ss ss--wrap" }) }; x._steps.append(h("div", { class: "row-item" }, r.dot, h("div", { class: "row-main" }, r.txt))); x._rows.set(id, r); }
      const st = String(d.state || "run");
      r.dot.className = "dotst " + (st === "ok" ? "ok" : st === "err" ? "err" : "warn");
      r.txt.textContent = String(d.tool || "étape") + (d.arg ? " — " + String(d.arg).slice(0, 140) : "") + (st === "run" ? (d.beat != null ? " · en cours depuis " + d.beat + " s" : " · en cours…") : st === "err" ? " · échec" : " · fait");
    };
    /* Carte d'approbation (événement confirm) : POST /api/confirm {id, ok} ; le moteur attend 60 s au plus (Règle d'or n°2). */
    const confirmCard = (d) => {
      const id = String(d.id || "");
      if (d.resolved) {
        const c = confirms.get(id);
        if (c) { c.replaceChildren(h("div", { class: "ss" }, (d.ok ? "Approuvé : " : "Refusé ou sans réponse : ") + String(d.tool || "action"))); confirms.delete(id); }
        return;
      }
      if (!id || confirms.has(id)) return;
      const x = ensureExec();
      const decide = async (ok, btns) => {
        btns.forEach((b) => { b.disabled = true; });
        try { const j = await api.post("/api/confirm", { id, ok }); if (j && j.message && !/^(Autorisé|Refusé)\.?$/.test(String(j.message))) ctx.toast("Moteur : " + String(j.message), true); }
        catch (e) { ctx.toast("Réponse non envoyée : " + String((e && e.message) || e), true); btns.forEach((b) => { b.disabled = false; }); }
      };
      const yes = ds.action({ label: "Approuver", primary: true }), no = ds.action({ label: "Refuser" });
      yes.addEventListener("click", () => decide(true, [yes, no])); no.addEventListener("click", () => decide(false, [yes, no]));
      const card = ds.card({ alert: true, class: "cn-confirm" },
        h("div", { class: "cn-confirm-t" }, h("b", {}, "Le président demande ton accord"), h("span", { class: "ds-meta", title: "Outil : " + String(d.tool || "action") }, "Action : " + String(d.tool || "action"))),
        d.preview || d.arg ? h("div", { class: "cn-confirm-p" }, String(d.preview || d.arg).slice(0, 600)) : null,
        h("div", { class: "cn-confirm-foot" }, h("span", { class: "ds-meta" }, "Sans réponse sous 60 s, l'action est classée « en attente de ton GO »."), h("div", { class: "ds-actions" }, no, yes)));
      confirms.set(id, card); x._steps.after(card);
      try { card.scrollIntoView({ block: "nearest" }); } catch (e) {}
    };
    const errLine = (msg) => R.tail.append(ds.errorBox({ title: "Délibération incomplète", cause: String(msg) }));
    try {
      await sse(path, payload, (ev, d) => {
        d = d || {};
        if (ev === "members") {
          const items = arrOf(d, "items");
          if (d.run) runId = String(d.run);
          R.setMeta(items, d); R.members(items);
          if (items.some((m) => /spark/i.test(String(m.label || "") + " " + String(m.id || "")))) showSpark("membre du conseil");
          return;
        }
        if (ev === "phase") { R.phase(String(d.name || "")); return; }
        if (ev === "mbrain") { R.brain(d.id, d.label); if (/spark/i.test(String(d.label || ""))) showSpark("membre du conseil"); return; }
        if (ev === "mdelta" && d.t) { R.delta(d.id, d.t); anyText = true; return; }
        if (ev === "mtool") { R.tool(d.id, d.name); return; }
        if (ev === "mdone") { R.done(d); if (d.ok) anyText = true; return; }
        if (ev === "rbrain") { R.refBrain(d.id, d.label); return; }
        if (ev === "rdelta" && d.t) { R.refDelta(d.id, d.t); return; }
        if (ev === "rdone") { R.refDone(d); return; }
        if (ev === "chair") { R.phase("president"); return; }
        if (ev === "chairbrain") { R.chairBrain(d.label); if (/spark/i.test(String(d.label || ""))) showSpark("président"); return; }
        if (ev === "delta" && d.t) { R.chairDelta(d.t); anyText = true; return; }
        if (ev === "votes") { R.votes(arrOf(d, "items")); return; }
        if (ev === "usage") { R.usage(d); return; }
        if (ev === "saved") { savedId = String(d.id || ""); return; }
        if (ev === "exec") { R.phase("application"); const x = ensureExec(); x._status.textContent = "Le président applique les décisions en arrière-plan (10 étapes, 5 min au plus) — il continue même si tu quittes l'écran ; « Annuler » l'arrête."; return; }
        if (ev === "step") { stepRow(d); return; }
        if (ev === "confirm") { confirmCard(d); return; }
        if (ev === "xtool") { const x = ensureExec(); execAcc = ""; x._el.replaceChildren(); x._status.textContent = "Outil " + String(d.name || "") + " exécuté" + (d.output ? " — " + String(d.output).slice(0, 160) : "") + "."; return; }
        if (ev === "xdelta" && d.t) { const x = ensureExec(); execAcc += d.t; x._el.innerHTML = md(execAcc); return; }
        if (ev === "report") {
          R.verdict(d.decided);
          if (d.exec === "none") { ended = ended || "noexec"; if (d.id) savedId = String(d.id); return; }
          const x = ensureExec();
          const parts = [];
          if (d.applied) parts.push("**Appliqué**\n\n" + String(d.applied));
          if (d.pending) parts.push("**En attente de ton GO**\n\n" + String(d.pending));
          if (d.notdone) parts.push("**Non fait**\n\n" + String(d.notdone));
          if (parts.length) x._el.innerHTML = md(parts.join("\n\n"));
          x._status.textContent = d.exec === "timeout" ? "Exécution arrêtée : délai de 5 min atteint." : d.exec === "cancelled" ? "Exécution annulée à ta demande." : "Exécution terminée.";
          if (d.exec === "cancelled") ended = "cancelled";
          if (d.id) savedId = String(d.id);
          return;
        }
        if (ev === "cancelled") { ended = "cancelled"; if (d.id) savedId = String(d.id); R.tail.append(h("div", { class: "cn-note" }, "Séance annulée (" + ({ avis: "pendant les avis", refutation: "pendant la réfutation", president: "pendant la décision" }[d.stage] || "en cours") + ") — le tour partiel est archivé.")); return; }
        if (ev === "error" && d.message) { errLine(d.message); return; }
      }, ac.signal);
      if (!anyText) errLine("Le conseil n'a rien renvoyé — les cerveaux disponibles sont peut-être hors ligne (voir Accueil, pastille Cerveaux).");
      else if (onOk && ended !== "cancelled") onOk();
    } catch (e) {
      if (e && e.name === "AbortError") ended = "cancelled";
      else errLine("Délibération interrompue : " + String((e && e.message) || e));
    } finally {
      confirms.forEach((c) => c.remove()); confirms.clear();
      cancelBtn.remove();
      R.finish(ended || "done");
      ac = null; goBtn.disabled = false;
      if (!dead) { if (savedId) box.append(followupBox(savedId)); loadHistory(); }
    }
  }

  /* FIX-WEB C8 : discussion de suivi — POST /api/council/followup {id, question, act} (SSE, même flux, fil complet relu par le moteur).
     V6 : carte « Suite à donner » — les actions GO qui existent (appliquer les décisions, relancer) ; une seule primaire :
     « Appliquer les décisions » quand des actions attendent ton GO, sinon « Relancer le conseil ». */
  function followupBox(id, pending) {
    const fq = h("textarea", { rows: "2", class: "fld fld-area", placeholder: "Relancer le conseil : suivi, objection, GO sur une action en attente…", "aria-label": "Relance du conseil" });
    const send = () => {
      const t = fq.value.trim(); if (!t || ac) return;
      const turn = h("div", { class: "cn-session cn-session--turn" });
      wrap.replaceWith(turn);
      metaRow.replaceChildren(); sparkShown = false;
      /* 24/10 : la relance passe par la route EN FLUX (/api/council/stream + followup) — /api/council/followup n'est pas
         relayée en flux par le pont WKWebView : la relance revenait vide (« Le conseil n'a rien renvoyé »). */
      session(turn, "/api/council/stream", { followup: id, question: t, act }, null, { question: "Relance — " + t, sparring: false });
    };
    /* 24/10 : appliquer les décisions d'une séance passée, en un clic (le président relit le fil complet ; tout envoi,
       paiement, suppression ou écriture sensible passe toujours par une carte d'approbation). */
    const applyPast = () => {
      if (ac) return;
      const turn = h("div", { class: "cn-session cn-session--turn" });
      wrap.replaceWith(turn);
      metaRow.replaceChildren(); sparkShown = false;
      const t = "Applique maintenant les décisions retenues dans ce conseil (dernier tour) et celles restées en attente de mon GO. Vérifie d'abord ce qui est déjà fait, puis fais le reste, une action à la fois, avec ma validation pour toute écriture.";
      session(turn, "/api/council/stream", { followup: id, question: t, act: true }, null, { question: "Appliquer les décisions", sparring: false });
    };
    enterSends(fq, send);
    const applyBtn = ds.action({ label: "Appliquer les décisions", icon: "check", primary: !!pending, tip: "Le président relit cette séance et applique ses décisions (approbation requise pour toute écriture)", onClick: applyPast });
    const sendBtn = ds.action({ label: "Relancer le conseil", icon: "send", primary: !pending, onClick: send });
    const wrap = ds.card({ class: "cn-follow" },
      h("div", { class: "cn-follow-h" }, h("h3", { class: "ds-h3" }, "Suite à donner"), pending ? ds.pill("En attente de ton GO", "warn") : null),
      fq,
      h("div", { class: "cn-composer-foot" },
        h("span", { class: "ds-meta" }, act ? "Le président appliquera la nouvelle décision." : "Décision seule : rien ne sera exécuté."),
        h("div", { class: "ds-actions" }, pending ? sendBtn : applyBtn, pending ? applyBtn : sendBtn)));
    return wrap;
  }

  /* FIX-WEB C8 + V3 : détail d'une séance — GET /api/council/get?id= → {id,title,created,updated,members,rounds:[…]}.
     Chaque tour est rendu dans la même salle que le direct, à partir des données archivées (avis bruts, réfutations, vote, décision).
     V6 : vue détail à part entière (la liste se masque), retour par « Délibérations » ou Échap. */
  const EXEC_LBL = { done: "décisions appliquées", timeout: "exécution arrêtée (délai)", cancelled: "annulé", none: "décision seule", partial: "application partielle" };
  const backToList = () => {
    detailView.hidden = true; listView.hidden = false; modeTabs.hidden = false;
    if (!ac) detailView.replaceChildren();
    try { const r = histBox.querySelector('.ds-row[data-id="' + CSS.escape(openId) + '"]'); if (r) r.focus({ preventScroll: false }); } catch (e) {}
  };
  detailView.addEventListener("keydown", (e) => { if (e.key === "Escape" && !e.target.closest("textarea, input")) { e.preventDefault(); backToList(); } });
  let openId = "";
  async function openSession(id) {
    if (ac) { if (detailView.childElementCount) { listView.hidden = true; detailView.hidden = false; } ctx.toast("Une délibération est en cours.", true); return; }
    openId = String(id);
    const it = histItems.find((x) => String(x.id) === openId) || {};
    const back = ds.action({ label: "Délibérations", icon: "back", ghost: true, onClick: backToList });
    const box = h("div", { class: "cn-session", "aria-busy": "true" }, ds.skeleton(3));
    detailView.replaceChildren(
      h("div", { class: "cn-detail-nav" }, back),
      h("header", { class: "cn-detail-head" },
        h("h2", { class: "ds-h2 cn-detail-q", title: String(it.title || "Délibération") }, String(it.title || "Délibération")),
        h("div", { class: "cn-detail-meta" }, it.pending ? ds.pill("En attente de ton GO", "warn") : it.id ? ds.pill("Décidé", "ok") : null,
          h("span", { class: "ds-meta" }, [fmtDT(it.updated || it.created), it.rounds > 1 ? it.rounds + " tours" : ""].filter(Boolean).join(" · ")))),
      box);
    listView.hidden = true; modeTabs.hidden = true; detailView.hidden = false;
    try { root.closest(".pane-body, .mod") && (root.parentElement.scrollTop = 0); root.scrollTop = 0; } catch (e) {}
    try { back.focus({ preventScroll: true }); } catch (e) {}
    try {
      const rec = await api.get("/api/council/get?id=" + encodeURIComponent(id));
      if (dead || openId !== String(id)) return;
      box.removeAttribute("aria-busy");
      const rounds = Array.isArray(rec && rec.rounds) ? rec.rounds : [];
      const members = Array.isArray(rec && rec.members) ? rec.members : [];
      const last = rounds[rounds.length - 1] || {};
      const pending = !!(it.pending || (last.pending && String(last.pending).trim()));
      box.replaceChildren(
        ...(rounds.length ? rounds.map((r, i) => {
          const R = makeRoom({ question: (i > 0 ? "Relance — " : "") + String(r.question || ""), sparring: !!r.sparring, live: false });
          const avis = Array.isArray(r.avis) ? r.avis : [];
          const mlist = avis.length ? avis : members;
          R.setMeta(mlist, { chair: r.chair && (r.chair.label || r.chair.planned) ? String(r.chair.label || r.chair.planned) : "", limits: r.limits || null });
          R.members(mlist);
          for (const a of avis) { R.brain(a.id || a.label, a.brain || a.label); R.done(Object.assign({}, a, { id: a.id || a.label })); }
          const refsA = Array.isArray(r.refutations) ? r.refutations : [];
          for (const x of refsA) R.refDone(Object.assign({}, x, { id: x.id || x.label }));
          if (r.decision) R.chairSet(String(r.decision));
          R.votes(Array.isArray(r.votes) ? r.votes : []);
          R.usage(r.usage);
          R.verdict(r.decided);
          const done = ["avis"]; if (refsA.length) done.push("refutation"); if (r.decision) done.push("president"); if (r.exec && r.exec !== "none") done.push("application");
          R.phase(done[done.length - 1]);
          R.finish(r.exec === "cancelled" ? "cancelled" : r.exec === "none" ? "noexec" : "done");
          const parts = [];
          if (r.applied) parts.push("**Appliqué**\n\n" + String(r.applied));
          if (r.pending) parts.push("**En attente de ton GO**\n\n" + String(r.pending));
          if (r.notdone) parts.push("**Non fait**\n\n" + String(r.notdone));
          if (parts.length) R.tail.append(h("div", { class: "cn-panel cn-exec" }, h("h3", { class: "cn-h" }, "Application des décisions"), h("div", { class: "brief-text", html: md(parts.join("\n\n")) })));
          R.tail.append(h("div", { class: "cn-note" }, "Tour " + (i + 1) + " · " + fmtDT(r.ts) + (r.exec ? " · " + (EXEC_LBL[r.exec] || "exécution terminée") : "") + (r.duration_s ? " · " + fmtNumFR(r.duration_s) + " s" : "")));
          return R.el;
        }) : [ds.empty({ icon: "council", text: "Cette séance ne contient aucun tour lisible.", compact: true })]),
        followupBox(String(rec.id || id), pending));
    } catch (e) {
      if (dead) return;
      box.removeAttribute("aria-busy");
      box.replaceChildren(ds.errorBox({ title: "Séance illisible", cause: "Le moteur n'a pas renvoyé cette délibération.", retry: () => openSession(id) }));
    }
  }

  /* ── Jumeau de décision (n°6) ──────────────────────────────────────── */
  const tq = h("input", { type: "text", id: "conseil-twin-q", class: "fld", placeholder: "Ex. accepter la mission X ?" });
  const to = h("input", { type: "text", id: "conseil-twin-o", class: "fld", placeholder: "Ex. accepter, négocier, refuser" });
  const twinEmpty = () => ds.empty({ icon: "council", compact: true, text: "Le mémo pour/contre, sourcé sur tes décisions passées et ta charte, s'affichera ici." });
  const twinOut = h("div", { class: "cn-result" }, twinEmpty());
  const twinBtn = ds.action({ label: "Simuler la décision", primary: true, onClick: () => runTwin() });
  enterSends(tq, () => runTwin()); enterSends(to, () => runTwin());
  async function runTwin() {
    const question = tq.value.trim(); if (!question) { ctx.toast("Écris la décision à simuler.", true); tq.focus(); return; }
    twinBtn.disabled = true;
    twinOut.replaceChildren(ds.skeleton(2));
    try {
      const options = to.value.split(",").map((s) => s.trim()).filter(Boolean);
      const r = await api.post("/api/decision/twin", { question, options });
      if (dead) return;
      const text = (r && (r.text || r.memo || r.md || r.result)) || "";
      twinOut.replaceChildren(text ? ds.card({}, h("div", { class: "brief-text", html: md(String(text)) }))
        : ds.empty({ icon: "council", compact: true, text: "Le jumeau n'a rien produit — le moteur est peut-être indisponible.", action: { label: "Réessayer", icon: "refresh", onClick: () => runTwin() } }));
    } catch (err) {
      if (!dead) twinOut.replaceChildren(ds.errorBox({ title: "Jumeau injoignable", cause: "Le moteur n'a pas répondu pour le moment.", retry: () => runTwin() }));
    }
    twinBtn.disabled = false;
  }
  panelJumeau.append(ds.section({ title: "Jumeau de décision", body: [
    h("p", { class: "ds-meta cn-sec-desc" }, "Un mémo pour/contre, sourcé sur tes décisions passées et ta charte."),
    ds.card({ class: "cn-composer" },
      h("div", { class: "cn-fields" },
        h("div", { class: "cn-field" }, h("label", { class: "cn-lb", for: "conseil-twin-q" }, "Décision à simuler"), tq),
        h("div", { class: "cn-field" }, h("label", { class: "cn-lb", for: "conseil-twin-o" }, "Options (facultatif)"), to)),
      h("div", { class: "cn-composer-foot" }, h("span", { class: "ds-meta" }, "Sépare les options par des virgules."), twinBtn)),
    twinOut] }));

  /* ── Studio Meta (n°18) : Muse Image + SAM 3.1, appels RÉELS du moteur ──
     Le visuel du brief se génère ici (Muse Image), puis SAM 3.1 en découpe un
     élément. La clé Meta ne quitte jamais le Trousseau : le web appelle les
     routes du moteur (/api/meta/image, /api/meta/segment). En cas d'échec,
     l'erreur du fournisseur s'affiche telle quelle — aucun visuel de remplissage. */
  const imgPrompt = h("input", { type: "text", id: "conseil-img", class: "fld", placeholder: "Ex. un panda analyste devant un écran BRVM, lumière du soir" });
  const imgOut = h("div", { class: "cn-result" });
  const GEN_LB = "Générer le visuel";
  const genBtn = ds.action({ label: GEN_LB, icon: "sparkle", primary: true, onClick: () => genImage() });
  const setLabel = (b, t) => { const n = [...b.childNodes].reverse().find((x) => x.nodeType === 3); if (n) n.textContent = t; };
  const segConcept = h("input", { type: "text", id: "conseil-sam", class: "fld", placeholder: "Ex. panda, voiture, personne…" });
  const segFile = h("input", { type: "file", accept: "image/*", hidden: "" });
  const segPick = ds.action({ label: "Choisir une image", icon: "attach", onClick: () => segFile.click() });
  const segName = h("span", { class: "ds-meta cn-seg-src" }, "Source : le visuel généré ci-dessus, ou une image choisie.");
  const segOut = h("div", { class: "cn-result" });
  const SEG_LB = "Découper";
  const segBtn = ds.action({ label: SEG_LB, primary: true, onClick: () => runSegment() });
  enterSends(imgPrompt, () => { if (!genBtn.disabled) genImage(); }); enterSends(segConcept, () => { if (!segBtn.disabled) runSegment(); });
  let lastGen = null, fileData = "";
  segFile.addEventListener("change", () => {
    const f = segFile.files && segFile.files[0]; if (!f) return;
    const rd = new FileReader();
    rd.onload = () => { fileData = String(rd.result || ""); segName.textContent = "Source : " + f.name; segName.title = f.name; segOut.replaceChildren(h("div", { class: "ds-meta" }, "Image chargée : " + f.name + " — elle servira de source au découpage.")); };
    rd.readAsDataURL(f);
  });
  const providerErr = (title, j) => ds.errorBox({ title, cause: String((j && j.error) || "réponse vide") + ((j && j.status) ? " (HTTP " + j.status + ")" : "") });
  async function genImage() {
    const prompt = imgPrompt.value.trim();
    if (!prompt) { ctx.toast("Écris le visuel à générer.", true); imgPrompt.focus(); return; }
    genBtn.disabled = true; setLabel(genBtn, "Génération…");
    imgOut.replaceChildren(h("div", { class: "skel skel-card", "aria-busy": "true" }), h("div", { class: "ds-meta" }, "Muse Image travaille… (appel réel à l'API Meta, 10 à 40 s)"));
    try {
      const j = await api.post("/api/meta/image", { prompt });
      if (dead) return;
      if (j && j.ok && j.b64) {
        lastGen = { dataUri: "data:" + (j.mime || "image/webp") + ";base64," + j.b64 };
        imgOut.replaceChildren(
          h("img", { class: "meta-img", src: lastGen.dataUri, alt: prompt }),
          h("div", { class: "ds-meta" }, "Généré par Muse Image (Meta) — sert aussi de source au découpage ci-dessous." + (j.livrable ? " Enregistré dans Livrables." : " Non enregistré dans Livrables (écriture impossible).")));
      } else imgOut.replaceChildren(providerErr("Muse Image a refusé l'appel", j));
    } catch (e) { if (!dead) imgOut.replaceChildren(ds.errorBox({ title: "Route Meta injoignable", cause: "Le moteur n'a pas pu joindre Muse Image.", retry: () => genImage() })); }
    genBtn.disabled = false; setLabel(genBtn, GEN_LB);
  }
  async function runSegment() {
    const concept = segConcept.value.trim();
    const src = fileData || (lastGen && lastGen.dataUri) || "";
    if (!concept) { ctx.toast("Écris le concept à découper.", true); segConcept.focus(); return; }
    if (!src) { ctx.toast("Génère d'abord un visuel, ou choisis une image.", true); return; }
    segBtn.disabled = true; setLabel(segBtn, "Découpage…");
    segOut.replaceChildren(h("div", { class: "ds-meta" }, "SAM 3.1 découpe « " + concept + " »… (appel réel, 5 à 20 s)"));
    try {
      const j = await api.post("/api/meta/segment", { image: src, prompt: concept });
      if (dead) return;
      if (j && j.ok) {
        const boxes = Array.isArray(j.boxes) ? j.boxes : [];
        const stage = h("div", { class: "seg-stage" }, h("img", { class: "meta-img", src, alt: concept }));
        for (const b of boxes) {
          if (!b.w || !b.h) continue;
          stage.append(h("div", { class: "seg-box", style: "left:" + (b.x1 / b.w * 100) + "%;top:" + (b.y1 / b.h * 100) + "%;width:" + ((b.x2 - b.x1) / b.w * 100) + "%;height:" + ((b.y2 - b.y1) / b.h * 100) + "%" },
            h("span", {}, concept)));
        }
        segOut.replaceChildren(stage,
          h("div", { class: "ds-meta" }, boxes.length
            ? "SAM 3.1 (Meta) : " + boxes.length + (boxes.length > 1 ? " zones découpées" : " zone découpée") + ", masque reçu."
            : "SAM 3.1 n'a découpé aucune zone pour « " + concept + " ». Essaie un mot unique, plus concret."));
      } else segOut.replaceChildren(providerErr("SAM 3.1 a refusé l'appel", j));
    } catch (e) { if (!dead) segOut.replaceChildren(ds.errorBox({ title: "Route Meta injoignable", cause: "Le moteur n'a pas pu joindre SAM 3.1.", retry: () => runSegment() })); }
    segBtn.disabled = false; setLabel(segBtn, SEG_LB);
  }
  panelStudio.append(
    ds.section({ title: "Studio Meta", body: [
      h("p", { class: "ds-meta cn-sec-desc" }, "Muse Image génère le visuel du brief, SAM 3.1 en découpe un élément — les modèles Meta, en action."),
      ds.card({ class: "cn-composer" },
        h("div", { class: "cn-field" }, h("label", { class: "cn-lb", for: "conseil-img" }, "Visuel à générer"), imgPrompt),
        h("div", { class: "cn-composer-foot" }, h("span", { class: "ds-meta" }, "Muse Image · enregistré dans Livrables"), genBtn)),
      imgOut] }),
    ds.section({ title: "Découpage SAM 3.1", body: [
      ds.card({ class: "cn-composer" },
        h("div", { class: "cn-field" }, h("label", { class: "cn-lb", for: "conseil-sam" }, "Concept à découper"), segConcept,
          /* C-02 résidu fermé : l'aide est un TEXTE COMPLET VISIBLE en permanence, pas le seul placeholder. */
          h("span", { class: "ds-meta" }, "Un mot concret et unique marche le mieux (panda, voiture, personne…).")),
        h("div", { class: "cn-composer-foot" }, h("div", { class: "cn-seg-pick" }, segPick, segName), segBtn, segFile)),
      segOut] }));

  /* ── Historique ────────────────────────────────────────────────────── */
  const histBox = h("div", { class: "ds-list cn-hist" }, ds.skeleton(3));
  const histSec = ds.section({ title: "Délibérations passées", actions: [{ icon: "refresh", tip: "Actualiser", onClick: () => loadHistory() }], body: histBox });
  listView.append(histSec);
  let histItems = [];
  async function loadHistory() {
    try {
      const j = await api.get("/api/council/history");
      if (dead) return;
      const items = arrOf(j, "items");
      histItems = items;
      setSecCount(histSec, items.length);
      /* FIX-WEB C8 : résumé moteur (CouncilStore.summaries) = {id,title,created,updated,rounds,members,decided,pending,exec} ; clic → détail + relance. */
      histBox.replaceChildren(...(items.length ? items.slice(0, 12).map((it) => {
        const r = ds.row({ title: String(it.title || "Délibération"), tip: String(it.title || "Délibération"),
          meta: [fmtDT(it.updated || it.created), it.rounds > 1 ? it.rounds + " tours" : "", truncWords(String(it.decided || "").replace(/\[GO\]\s*/g, ""), 110)].filter(Boolean).join(" · "),
          side: it.pending ? ds.pill("En attente de ton GO", "warn") : ds.pill("Décidé", "ok"),
          onOpen: () => openSession(String(it.id || "")) });
        r.dataset.id = String(it.id || "");
        r.title = "Ouvrir la séance";
        return r;
      }) : [ds.empty({ icon: "council", text: "Aucune délibération archivée. Pose une première question au conseil.", action: { label: "Poser une question", onClick: () => { try { q.focus(); q.scrollIntoView({ block: "center" }); } catch (e) {} } } })]));
    } catch (e) {
      if (!dead) histBox.replaceChildren(ds.errorBox({ title: "Historique injoignable", cause: "Le moteur n'a pas renvoyé les délibérations.", retry: () => loadHistory() }));
    }
  }
  loadHistory();
  let lastHist = Date.now();
  return {
    destroy() { dead = true; if (ac) ac.abort(); },
    onShow() { if (ac || Date.now() - lastHist < 30000) return; lastHist = Date.now(); loadHistory(); },
  };
}
