/* brvm-alertes.js — LOT3 (25/10/2026) : alertes de cours BRVM + liste de suivi (écran Finance).
   Moteur : Sources/NovaCore/Feat_BRVMAlertes.swift.
     GET  /api/brvm/alertes   → { items:[{sym,name,haut?,bas?,var?}], declenchees:[…du jour], seance:{ouverte,horaires}, derniere_verif, regle }
     POST /api/brvm/alertes   {sym, haut, bas, var} (vide = retiré ; tout vide = alerte supprimée)
     GET  /api/brvm/historique?syms=A,B → { series:{SYM:[["AAAA-MM-JJ", cours], …]} } — relevés de Nova, un point par jour.
   Suivi : symboles suivis (veille_pole « watch », POST /api/veille/config) ∪ symboles sous alerte ∪ positions
   détenues (fournies par finance.js SEULEMENT coffre ouvert). Courbe = historique relevé ; moins de 2 points → « — ».
   Faits seuls : cours, variation, seuils. Aucun avis d'achat ou de vente. */
import { api, h, fmtMoneyFR, fmtPctFR, fmtTimeFR } from "./core.js";
import * as ds from "./ds.js";

const varTxt = (v) => { const n = Number(v); return isFinite(n) ? (n > 0 ? "+" : "") + fmtPctFR(n) : "—"; };
const toneOf = (v) => { const n = Number(v); return n > 0 ? "ok" : n < 0 ? "danger" : ""; };
const numIn = (v) => { const s = String(v ?? "").replace(/[\s  ]/g, "").replace(",", "."); if (!s) return null; const n = Number(s); return isFinite(n) ? n : NaN; };
const SVGNS = "http://www.w3.org/2000/svg";

/** Courbe compacte d'une série [[jour, cours], …] — null si moins de 2 points (jamais de point inventé). */
export function sparkline(serie, w = 96, hgt = 24) {
  const pts = (Array.isArray(serie) ? serie : []).map((p) => Number(p && p[1])).filter((n) => isFinite(n) && n > 0);
  if (pts.length < 2) return null;
  const min = Math.min(...pts), max = Math.max(...pts), span = max - min || 1;
  const step = (w - 4) / (pts.length - 1);
  const xy = pts.map((v, i) => (2 + i * step).toFixed(1) + "," + (2 + (hgt - 4) * (1 - (v - min) / span)).toFixed(1)).join(" ");
  const svg = document.createElementNS(SVGNS, "svg");
  svg.setAttribute("viewBox", "0 0 " + w + " " + hgt); svg.setAttribute("width", String(w)); svg.setAttribute("height", String(hgt));
  svg.setAttribute("class", "brvm-spark " + toneOf(pts[pts.length - 1] - pts[0]));
  svg.setAttribute("role", "img");
  const first = serie[0][0], last = serie[serie.length - 1][0];
  svg.setAttribute("aria-label", pts.length + " cours relevés du " + first + " au " + last + " : de " + pts[0] + " à " + pts[pts.length - 1] + " FCFA");
  const pl = document.createElementNS(SVGNS, "polyline");
  pl.setAttribute("points", xy); pl.setAttribute("fill", "none"); pl.setAttribute("stroke", "currentColor"); pl.setAttribute("stroke-width", "1.5");
  pl.setAttribute("stroke-linejoin", "round"); pl.setAttribute("stroke-linecap", "round");
  svg.append(pl);
  const t = document.createElementNS(SVGNS, "title"); t.textContent = pts.length + " relevés de Nova (" + first + " → " + last + ")"; svg.append(t);
  return svg;
}

/** opts : { toast, getQuotes(): [{sym,name,price,var}], getHeld(): Set, getWatch(): [sym], setWatch(list), repaint() } */
export function createBrvmAlerts(opts) {
  const st = { items: new Map(), fired: new Map(), seance: null, verif: "", note: "", hist: {}, open: "", loaded: false, error: false };
  const alertSec = ds.section({ title: "Mes alertes" });
  const watchSec = ds.section({ title: "Suivi" });
  const toast = (t, bad) => { try { if (opts.toast) opts.toast(t, bad); } catch (e) {} };

  async function load() {
    try {
      const j = await api.get("/api/brvm/alertes", 12000);
      st.items = new Map((Array.isArray(j && j.items) ? j.items : []).map((x) => [String(x.sym), x]));
      st.fired = new Map();
      for (const d of (Array.isArray(j && j.declenchees) ? j.declenchees : [])) { const k = String(d.sym); if (!st.fired.has(k)) st.fired.set(k, []); st.fired.get(k).push(d); }
      st.seance = (j && j.seance) || null; st.verif = String((j && j.derniere_verif) || ""); st.note = String((j && j.derniere_verif_note) || "");
      st.loaded = true; st.error = false;
    } catch (e) { st.error = true; }
    await loadHist();
    if (opts.repaint) opts.repaint(); else paint();   // la cloche des lignes du marché suit l'état des alertes
  }
  function watchSyms() {
    const s = new Set();
    for (const x of (opts.getWatch && opts.getWatch()) || []) s.add(String(x));
    for (const k of st.items.keys()) s.add(k);
    for (const k of (opts.getHeld && opts.getHeld()) || []) s.add(String(k));
    return [...s].filter(Boolean).sort();
  }
  let histKey = "", histAt = 0;
  async function loadHist() {
    const syms = watchSyms();
    const key = syms.join(",");
    if (!syms.length) { st.hist = {}; return; }
    if (key === histKey && Date.now() - histAt < 300000) return;
    try { const j = await api.get("/api/brvm/historique?syms=" + encodeURIComponent(key), 12000); st.hist = (j && j.series) || {}; histKey = key; histAt = Date.now(); } catch (e) {}
  }
  const quoteOf = (sym) => ((opts.getQuotes && opts.getQuotes()) || []).find((q) => String(q.sym) === sym) || null;
  const ruleTxt = (a) => [a.haut != null ? "seuil haut " + fmtMoneyFR(a.haut, "FCFA") : "", a.bas != null ? "seuil bas " + fmtMoneyFR(a.bas, "FCFA") : "", a.var != null ? "variation du jour ≥ ±" + fmtPctFR(a.var) : ""].filter(Boolean).join(" · ");

  function paint() {
    /* Mes alertes */
    const rows = [...st.items.values()];
    let c = alertSec.querySelector(":scope > .ds-section-head > .ds-count");
    if (rows.length && !c) { c = h("span", { class: "ds-count" }); alertSec.querySelector(".ds-h2").after(c); }
    if (c) c.textContent = rows.length ? String(rows.length) : "";
    const sea = st.seance ? (st.seance.ouverte ? "Séance ouverte" : "Séance fermée") + " (" + String(st.seance.horaires || "lun–ven 09:00–15:30 GMT") + ")" : "";
    const meta = h("div", { class: "ds-meta brvm-al-meta" }, [sea, st.verif ? "dernière vérification " + fmtTimeFR(st.verif) : "", st.note].filter(Boolean).join(" · ") || "Les alertes sont vérifiées après chaque relevé des cours, pendant la séance — une fois par jour et par alerte.");
    if (st.error) alertSec.body.replaceChildren(ds.errorBox({ cause: "Le moteur n'a pas renvoyé les alertes.", retry: () => load() }));
    else if (!rows.length) alertSec.body.replaceChildren(ds.empty({ compact: true, icon: "bell", text: "Aucune alerte. Pose-en une avec la cloche d'une ligne du marché : seuil haut, seuil bas ou variation du jour." }), meta);
    else alertSec.body.replaceChildren(h("div", { class: "ds-list" }, ...rows.map((a) => {
      const q = quoteOf(String(a.sym));
      const f = st.fired.get(String(a.sym)) || [];
      const side = h("span", { class: "brvm-al-side" }, q ? h("b", { class: "ds-num" }, fmtMoneyFR(q.price, "")) : "—", " ", q ? h("span", { class: "moi-fin-v " + toneOf(q.var) }, varTxt(q.var)) : null,
        f.length ? ds.pill("Déclenchée " + fmtTimeFR(f[0].ts), "warn") : null);
      return ds.row({ lead: "bell", title: String(a.sym) + (a.name && a.name !== a.sym ? " · " + String(a.name) : ""), meta: ruleTxt(a), side,
        actions: [{ label: "Modifier", ghost: true, onClick: () => openEditor(String(a.sym), true) }, { icon: "trash", tip: "Retirer l'alerte", onClick: () => save(String(a.sym), null, null, null) }] });
    })), meta);
    /* Suivi */
    const syms = watchSyms();
    let wc = watchSec.querySelector(":scope > .ds-section-head > .ds-count");
    if (syms.length && !wc) { wc = h("span", { class: "ds-count" }); watchSec.querySelector(".ds-h2").after(wc); }
    if (wc) wc.textContent = syms.length ? String(syms.length) : "";
    if (!syms.length) { watchSec.body.replaceChildren(ds.empty({ compact: true, icon: "star", text: "Aucune valeur suivie. Une alerte, une position du coffre ou « Suivre » dans l'éditeur d'alerte l'ajoute ici." })); return; }
    const held = (opts.getHeld && opts.getHeld()) || new Set();
    const tb = syms.map((sym) => {
      const q = quoteOf(sym);
      const serie = st.hist[sym] || [];
      const sp = sparkline(serie);
      const why = [held.has(sym) ? "détenue" : "", st.items.has(sym) ? "alerte" : "", ((opts.getWatch && opts.getWatch()) || []).includes(sym) ? "suivie" : ""].filter(Boolean).join(" · ");
      return h("tr", {},
        h("td", { class: "moi-fin-sym" }, sym, h("span", { class: "moi-fin-pname" }, why)),
        h("td", { class: "num" }, q ? fmtMoneyFR(q.price, "") : "—"),
        h("td", { class: "num moi-fin-v " + (q ? toneOf(q.var) : "") }, q ? varTxt(q.var) : "—"),
        h("td", { class: "brvm-spark-td", title: sp ? "" : (serie.length ? "1 seul cours relevé — la courbe apparaît dès le 2e jour de séance" : "aucun cours relevé par Nova pour l'instant") }, sp || "—"));
    });
    watchSec.body.replaceChildren(h("div", { class: "ds-table-wrap" }, h("table", { class: "ds-table" },
      h("thead", {}, h("tr", {}, h("th", { scope: "col" }, "Valeur"), h("th", { class: "num", scope: "col" }, "Cours (FCFA)"), h("th", { class: "num", scope: "col" }, "Var."), h("th", { scope: "col" }, "Relevés de Nova"))),
      h("tbody", {}, ...tb))),
      h("p", { class: "ds-meta moi-fin-note" }, "Courbe : un point par jour de séance, dernier cours vu par Nova sur brvm.org — la série commence au premier relevé, rien n'est reconstitué. Information uniquement, ni conseil ni ordre."));
  }

  async function save(sym, haut, bas, vr) {
    try {
      await api.post("/api/brvm/alertes", { sym, haut, bas, var: vr }, 12000);
      toast(haut == null && bas == null && vr == null ? "Alerte retirée (" + sym + ")." : "Alerte enregistrée (" + sym + ").");
      if (st.open === sym && haut == null && bas == null && vr == null) st.open = "";
      await load(); if (opts.repaint) opts.repaint();
      return true;
    } catch (e) { toast("Alerte : " + String((e && e.message) || e).replace(/^\/api\/brvm\/alertes → \d+ : /, ""), true); return false; }
  }
  function openEditor(sym, scroll) {
    st.open = st.open === sym && !scroll ? "" : sym;
    if (opts.repaint) opts.repaint();
    if (scroll) setTimeout(() => { const el = document.querySelector('.brvm-ed-row[data-sym="' + sym + '"]'); if (el) { el.scrollIntoView({ block: "center", behavior: "smooth" }); const f = el.querySelector("input"); if (f) f.focus(); } }, 60);
  }

  /** Cellule « cloche » d'une ligne du marché. */
  function cell(q) {
    const sym = String(q.sym || "");
    const a = st.items.get(sym);
    const fired = st.fired.has(sym);
    const b = ds.action({ icon: "bell", tip: a ? "Alerte : " + ruleTxt(a) + (fired ? " — déclenchée aujourd'hui" : "") : "Poser une alerte sur " + sym, onClick: () => openEditor(sym, false) });
    b.classList.add("brvm-bell"); if (a) b.classList.add("is-on"); if (fired) b.classList.add("is-fired");
    b.setAttribute("aria-expanded", st.open === sym ? "true" : "false");
    return h("td", { class: "brvm-bell-td" }, b);
  }
  /** Ligne d'édition sous la valeur ouverte (null sinon). */
  function editorRow(q, colspan) {
    const sym = String(q.sym || "");
    if (st.open !== sym) return null;
    const a = st.items.get(sym) || {};
    const val = (v) => (v == null ? "" : String(v).replace(".", ","));
    const hi = h("input", { type: "text", class: "fld", inputmode: "decimal", placeholder: "Seuil haut (FCFA)", value: val(a.haut), "aria-label": "Seuil haut en FCFA" });
    const lo = h("input", { type: "text", class: "fld", inputmode: "decimal", placeholder: "Seuil bas (FCFA)", value: val(a.bas), "aria-label": "Seuil bas en FCFA" });
    const vr = h("input", { type: "text", class: "fld", inputmode: "decimal", placeholder: "Variation du jour ≥ ±x %", value: val(a.var), "aria-label": "Variation du jour en pourcentage, hausse ou baisse" });
    const watch = (opts.getWatch && opts.getWatch()) || [];
    const fol = h("input", { type: "checkbox", checked: watch.includes(sym) ? true : null });
    const doSave = () => {
      const H = numIn(hi.value), L = numIn(lo.value), V = numIn(vr.value);
      if ([H, L, V].some((x) => x !== null && !isFinite(x))) { toast("Nombre invalide dans un seuil.", true); return; }
      save(sym, H, L, V);
    };
    [hi, lo, vr].forEach((el) => el.addEventListener("keydown", (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter") { e.preventDefault(); doSave(); } if (e.key === "Escape") { st.open = ""; if (opts.repaint) opts.repaint(); } }));
    fol.addEventListener("change", async () => {
      const cur = ((opts.getWatch && opts.getWatch()) || []).filter((x) => x !== sym);
      if (fol.checked) cur.push(sym);
      try { await api.post("/api/veille/config", { watch: cur }, 12000); if (opts.setWatch) opts.setWatch(cur); toast(fol.checked ? sym + " ajoutée au suivi." : sym + " retirée du suivi."); await loadHist(); paint(); }
      catch (e) { fol.checked = !fol.checked; toast("Suivi : " + String((e && e.message) || e), true); }
    });
    const cur = q && q.price ? "Cours actuel " + fmtMoneyFR(q.price, "FCFA") + " · variation " + varTxt(q.var) : "";
    return h("tr", { class: "brvm-ed-row", "data-sym": sym },
      h("td", { colspan: String(colspan) },
        h("div", { class: "brvm-ed" },
          h("div", { class: "ds-meta" }, "Alerte sur " + sym + (cur ? " — " + cur : "") + ". Vérifiée pendant la séance, une fois par jour et par seuil ; un message arrive au Fil direct."),
          h("div", { class: "brvm-ed-grid" }, hi, lo, vr),
          h("div", { class: "brvm-ed-acts" },
            h("label", { class: "ds-meta brvm-ed-fol" }, fol, " Suivre dans ma liste"),
            h("span", { class: "sp" }),
            ds.action({ label: "Annuler", ghost: true, onClick: () => { st.open = ""; if (opts.repaint) opts.repaint(); } }),
            st.items.has(sym) ? ds.action({ label: "Retirer", ghost: true, onClick: () => save(sym, null, null, null) }) : null,
            ds.action({ label: "Enregistrer", primary: true, onClick: doSave })))));
  }
  /* 29/10 (Ahadi : « alerte quand une de mes valeurs bouge de plus de 5 % ») — chaque valeur DÉTENUE sans alerte
     reçoit une alerte de variation ±5 % (une fois ; ensuite modifiable ou supprimable comme les autres). Coffre ouvert seulement. */
  const autoDone = new Set();
  async function autoHeld(seuil = 5) {
    if (!st.loaded) return;
    const held = [...((opts.getHeld && opts.getHeld()) || [])].map(String).filter(Boolean);
    let n = 0;
    for (const sym of held) {
      if (st.items.has(sym) || autoDone.has(sym)) continue;
      autoDone.add(sym);
      try { const r = await api.post("/api/brvm/alertes", { sym, haut: "", bas: "", var: seuil }, 10000); if (r && r.ok !== false) n++; } catch (e) {}
    }
    if (n) { try { await load(); } catch (e) {} if (opts.toast) opts.toast("Alerte ±" + seuil + " % posée sur " + n + " valeur" + (n > 1 ? "s" : "") + " détenue" + (n > 1 ? "s" : "") + " — tu peux la modifier dans Mes alertes."); }
  }
  return { alertSec, watchSec, load, paint, cell, editorRow, autoHeld, refreshHist: async () => { await loadHist(); paint(); } };
}
