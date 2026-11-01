/* Module Journal — vague 3 : n°17 LE TÉMOIN + n°2 MÉMOIRE TEMPORELLE.
   n°17 : les LIGNES RÉELLES de l'observation — journal des cerveaux (cerveau, modèle, durée, jetons, échec),
   journal des voix (moteur, latence) et boîte noire scellée (GET /api/journal, GET /api/blackbox), plus une
   SYNTHÈSE SUR DEMANDE (POST /api/chat, flux SSE) — rien n'est synthétisé d'avance, rien n'est inventé.
   n°2 : la FRISE — décisions (GET /api/decision/log), passages des Éclats (GET /api/dots, runs), appels des
   cerveaux, faits de mémoire (GET /api/ame/memoire, GET /api/memory) en une chronologie filtrable.
   V6 « Moi » (25/10/2026, contrat conseil_24-10/V6_DESIGN.md) : lignes .ds-row, pastilles ok / échec,
   regroupement par heure, échecs mis en évidence (liseré + pastille), texte brut des fournisseurs
   (« HTTP 400 {…} ») replié derrière « Détail », filtres en puces avec compteurs, secrets masqués. */
import { md, sse, fmtTimeFR, fmtDurFR, fmtNumFR, ligneBrute, truncWords, errKindLabel, cleanResume } from "../core.js";
import * as ds from "../ds.js";
import { mountJournalSoirSection } from "../journal-soir.js";   // LOT3 (25/10) : section « Journal du soir »
const arrOf = (j, ...keys) => { if (Array.isArray(j)) return j; for (const k of keys) if (j && Array.isArray(j[k])) return j[k]; return []; };
const tsOf = (v) => { if (v == null) return 0; if (typeof v === "number") return v < 1e12 ? v * 1000 : v; const d = Date.parse(v); return isNaN(d) ? 0 : d; };
const fmtT = (ms) => ms ? fmtTimeFR(new Date(ms)) : "";
const fmtDay = (ms) => {
  if (!ms) return "Sans date";
  const d = new Date(ms), now = new Date();
  const same = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  if (same(d, now)) return "Aujourd'hui";
  if (same(d, new Date(now.getTime() - 86400000))) return "Hier";
  const s = d.toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long" });
  return s.charAt(0).toUpperCase() + s.slice(1);
};
const hourKey = (ms) => ms ? fmtDay(ms) + " · " + new Date(ms).getHours() + " h" : "Sans date";
const pick = (e, ...ks) => { for (const k of ks) if (e && e[k] != null) return e[k]; return undefined; };
const maskText = (s) => String(s ?? "")
  .replace(/\b[A-Z]{2}\d{2}(?:\s?[A-Z0-9]{4}){3,8}(?:\s?[A-Z0-9]{1,4})?\b/g, (m) => ds.maskSecret(m))
  .replace(/\b(?:sk|pk|ghp|gho|xox[abp])[-_][A-Za-z0-9-_]{12,}\b/g, (m) => ds.maskSecret(m))
  .replace(/(?<![\w.,/-])\d{8,}(?!\w|[.,/-]\w)/g, (m) => ds.maskSecret(m));
const setCnt = (sec, n) => { let c = sec.querySelector(":scope > .ds-section-head > .ds-count"); if (n === "" || n == null) { if (c) c.remove(); return; } if (!c) { c = document.createElement("span"); c.className = "ds-count"; sec.querySelector(":scope > .ds-section-head > .ds-h2").after(c); } c.textContent = String(n); };
const BRAIN_NAMES = { "spark-1.3": "Muse Spark 1.3", "spark-1.2": "Muse Spark 1.2", "wonder-1.0": "Muse Wonder 1.0", "spark-open-baseten": "Muse Spark Open (Baseten)", "spark-open-hf": "Muse Spark Open (Hugging Face)", "muse-code": "Muse Code" };
const brainName = (id) => { const s = String(id || "").trim(); return BRAIN_NAMES[s] || s || "Cerveau"; };
const VOICE_NAMES = { meta: "Muse Voice Transcribe (Meta)", local: "Voix du Mac", "apple-sur-appareil": "Reconnaissance du Mac (sur l'appareil)", say: "Voix du Mac" };
const voiceName = (id) => VOICE_NAMES[String(id || "")] || String(id || "Voix");
const plural = (n, one, many) => n + " " + (n > 1 ? many : one);

export async function mount(root, ctx) {
  const { api, h, ic } = ctx;
  let dead = false;
  root.classList.add("mod--data", "moi-jr");
  root.append(ds.pageHead({ title: "Journal", sub: "Le Témoin : ce que Nova a vu, fait et décidé — lignes réelles du moteur, en lecture seule" }));

  /* Ligne brute (pour la synthèse) et ligne lisible (pour l'écran) d'un appel de cerveau / de voix. */
  function brainRaw(e) {
    return [String(e.brain || "cerveau"), e.model ? String(e.model) : "", e.ok === false ? "ÉCHEC" + (errKindLabel(e.kind) ? " (" + errKindLabel(e.kind) + ")" : "") : "ok",
      e.ms != null ? fmtDurFR(e.ms) : "", e.chars != null ? fmtNumFR(e.chars) + " car." : "", e.in != null || e.out != null ? "jetons " + fmtNumFR(e.in ?? 0) + "→" + fmtNumFR(e.out ?? 0) : "", e.err ? String(e.err) : "", e.reason ? String(e.reason) : ""].filter(Boolean).join(" · ");
  }
  const shortErr = (e) => {
    const k = errKindLabel(e.kind);
    if (k) return k;
    const s = String(e.err || e.reason || e.raison || "");
    if (/^réponse vide$/i.test(s)) return "réponse vide";
    if (/délai|timeout/i.test(s)) return "délai dépassé";
    return s && s.length <= 40 && !/[{}<>]/.test(s) ? s : "erreur du fournisseur";
  };
  function brainItem(e) {
    const ok = e.ok !== false;
    const empty = ok && Number(e.chars) === 0;
    return {
      t: tsOf(pick(e, "ts", "at", "date")), tag: "cerveau", ok, brain: brainName(e.brain),
      title: brainName(e.brain) + (ok ? (empty ? " — réponse vide" : "") : " — échec : " + shortErr(e)),
      meta: [e.model ? String(e.model) : "", e.ms != null ? fmtDurFR(e.ms) : "", e.chars != null ? fmtNumFR(e.chars) + " car." : "", (e.in || e.out) ? "jetons " + fmtNumFR(e.in ?? 0) + " → " + fmtNumFR(e.out ?? 0) : ""].filter(Boolean).join(" · "),
      raw: e.err || e.reason ? maskText(String(e.err || e.reason)) : "", warn: empty, text: brainRaw(e),
    };
  }
  function voiceItem(e) {
    const ok = e.ok !== false;
    return {
      t: tsOf(pick(e, "ts", "at", "date")), tag: "voix", ok,
      title: voiceName(e.moteur || e.stt) + (ok ? "" : " — échec" + (e.raison ? " : " + String(e.raison) : "")),
      meta: [e.premier_octet_ms != null ? "1er octet " + fmtDurFR(e.premier_octet_ms) : "", e.total_ms != null ? fmtDurFR(e.total_ms) : "", e.chars != null ? fmtNumFR(e.chars) + " car." : "", e.repli_de ? "repli de " + voiceName(e.repli_de) : ""].filter(Boolean).join(" · "),
      raw: "", text: [String(e.moteur || e.stt || "voix"), ok ? "ok" : "ÉCHEC", e.total_ms != null ? fmtDurFR(e.total_ms) : "", e.raison || ""].filter(Boolean).join(" · "),
    };
  }
  const LEAD = { cerveau: "brain", voix: "mic", bb: "shield", decision: "check", dot: "dot", memoire: "know" };
  const TAG_LBL = { cerveau: "Cerveau", voix: "Voix", bb: "Boîte noire", decision: "Décision", dot: "Éclat", memoire: "Mémoire" };

  /* Une ligne de journal : pastille ok/échec + heure à droite ; « Détail » déplie le texte brut. */
  function lineRow(it, opts = {}) {
    const wrap = h("div", { class: "moi-jr-item" + (it.ok === false ? " is-fail" : it.warn ? " is-warn" : "") + (opts.child ? " is-child" : "") });
    const raw = it.raw || it.detail ? h("div", { class: "moi-jr-detail", hidden: true },
      it.detail ? h("p", { class: "moi-jr-detail-t" }, it.detail) : null,
      it.raw ? h("pre", { class: "moi-jr-raw" }, it.raw) : null) : null;
    const tone = it.ok === false ? ds.pill("Échec", "danger") : it.warn ? ds.pill("Vide", "warn") : opts.noPill ? null : ds.pill("OK", "ok");
    let r;
    const toggle = () => { if (!raw) return; raw.hidden = !raw.hidden; wrap.classList.toggle("is-open", !raw.hidden); r.setAttribute("aria-expanded", raw.hidden ? "false" : "true"); };
    r = ds.row({
      lead: LEAD[it.tag] || "dot",
      title: it.title,
      meta: it.meta || null,
      side: h("span", { class: "moi-jr-side" }, tone, h("span", { class: "moi-jr-time ds-num" }, fmtT(it.t))),
      actions: raw ? [{ label: "Détail", ghost: true, tip: it.raw ? "Voir le texte brut du fournisseur" : "Voir le détail", onClick: toggle }] : null,
      onOpen: raw ? toggle : null,
    });
    if (raw) r.setAttribute("aria-expanded", "false");
    wrap.append(r); if (raw) wrap.append(raw);
    return wrap;
  }
  function groupRow(g) {
    const ko = g.items.filter((x) => !x.ok).length, empty = g.items.filter((x) => x.warn).length;
    const by = new Map(); for (const it of g.items) by.set(it.brain, (by.get(it.brain) || 0) + 1);
    const wrap = h("div", { class: "moi-jr-item moi-jr-agg" + (ko ? " is-fail" : "") });
    const kids = h("div", { class: "moi-jr-kids", hidden: true }, ...g.items.map((it) => lineRow(it, { child: true })));
    let r;
    const toggle = () => { kids.hidden = !kids.hidden; wrap.classList.toggle("is-open", !kids.hidden); r.setAttribute("aria-expanded", kids.hidden ? "false" : "true"); };
    const chev = h("span", { class: "moi-jr-chev", html: ic("chev-r", 14) });
    r = ds.row({
      lead: chev,
      title: plural(g.items.length, "appel", "appels") + " aux cerveaux — " + [...by.entries()].map(([k, n]) => k + " ×" + n).join(", "),
      meta: [fmtT(g.items[g.items.length - 1].t) + " → " + fmtT(g.items[0].t), empty ? plural(empty, "réponse vide", "réponses vides") : ""].filter(Boolean).join(" · "),
      side: h("span", { class: "moi-jr-side" }, ko ? ds.pill(plural(ko, "échec", "échecs"), "danger") : ds.pill("OK", "ok"), h("span", { class: "moi-jr-time ds-num" }, fmtT(g.t))),
      onOpen: toggle,
    });
    r.setAttribute("aria-expanded", "false");
    wrap.append(r, kids);
    return wrap;
  }
  /* Rendu groupé par heure (en-têtes « Aujourd'hui · 14 h »). Les appels de cerveaux CONSÉCUTIFS d'une même
     heure se replient en une ligne de synthèse dépliable (24/10). */
  function renderHours(list, opts = {}) {
    const out = [];
    let curKey = null, curList = null;
    for (const it of list) {
      const k = hourKey(it.t);
      if (k !== curKey) { curKey = k; curList = h("div", { class: "ds-list" }); out.push(h("div", { class: "moi-jr-hour" }, h("div", { class: "moi-jr-hour-h" }, k), curList)); }
      const last = curList.lastElementChild && curList.lastElementChild.__grp;
      if (opts.aggregate && it.tag === "cerveau" && last && last.tag === "cerveau") { last.items.push(it); continue; }
      const holder = h("div", { class: "moi-jr-slot" });
      holder.__grp = { tag: it.tag, items: [it], t: it.t };
      curList.append(holder);
    }
    for (const blk of out) for (const slot of blk.querySelectorAll(".moi-jr-slot")) {
      const g = slot.__grp;
      slot.replaceWith(g.items.length >= 2 ? groupRow(g) : lineRow(g.items[0], opts));
    }
    return out;
  }

  /* ═══ n°17 — LE TÉMOIN ═══ */
  const temSec = ds.section({ title: "Le Témoin" });
  const synthBtn = ds.action({ label: "Synthèse de ces lignes", icon: "look", tip: "Un cerveau du moteur lit exactement les lignes affichées — à la demande, jamais en arrière-plan", onClick: () => synth() });
  synthBtn.hidden = true;
  temSec.querySelector(".ds-section-head").append(h("div", { class: "ds-actions" }, synthBtn));
  const temTools = h("div", {});
  const temBox = h("div", {}, ds.skeleton(5));
  const synthBox = h("div", { class: "moi-jr-synth" });
  temSec.body.append(h("p", { class: "ds-meta moi-jr-lead" }, "L'observation ligne par ligne : appels aux cerveaux, voix, actions scellées de la boîte noire."), temTools, temBox, synthBox);
  /* ═══ n°2 — LA FRISE ═══ */
  const friseSec = ds.section({ title: "La frise" });
  const friseTools = h("div", {});
  const friseBox = h("div", {}, ds.skeleton(5));
  friseSec.body.append(h("p", { class: "ds-meta moi-jr-lead" }, "Mémoire temporelle : décisions, passages des Éclats, cerveaux et souvenirs, sur une seule chronologie."), friseTools, friseBox);
  const soirSec = mountJournalSoirSection(ctx);   // LOT3 : entrées du rituel du soir (Actions / Idées / Humeur + rythme mesuré)
  root.append(soirSec, temSec, friseSec);

  let temRows = [], temFailed = [], temNoDetail = 0, temoinLines = [];
  const tf = { f: "all" };
  async function loadTemoin() {
    const rows = [];
    const failed = [];
    try {
      const j = await api.get("/api/journal");
      if (dead) return;
      for (const e of arrOf(j, "cerveaux").slice(-25).reverse()) rows.push(brainItem(e));
      for (const e of arrOf(j, "voix").slice(-10).reverse()) rows.push(voiceItem(e));
    } catch (e) { failed.push("journal des cerveaux et des voix"); }
    let noDet = 0;
    try {
      const j = await api.get("/api/blackbox");
      if (dead) return;
      /* Boîte noire : libellé via ligneBrute (§9.8) — jamais « Entrée » nue ni JSON brut. Les entrées que le
         moteur n'expose pas lisiblement sont comptées, pas affichées une à une. */
      for (const b of arrOf(j, "items").slice(0, 10)) {
        const lb = ligneBrute(b);
        if (/détail indisponible/.test(lb)) { noDet++; continue; }
        rows.push({ t: tsOf(pick(b, "at", "ts", "date")), tag: "bb", ok: b.ok !== false, title: maskText(lb), meta: [b.actor || "", b.effect || "", b.result ? truncWords(maskText(String(b.result)), 90) : ""].filter(Boolean).join(" · "), raw: "", text: [lb, b.actor || "", b.effect || "", b.result || ""].filter(Boolean).join(" · ") });
      }
    } catch (e) { failed.push("boîte noire"); }
    rows.sort((a, b) => b.t - a.t);
    temRows = rows.slice(0, 40); temFailed = failed; temNoDetail = noDet;
    temoinLines = temRows.map((r) => "[" + TAG_LBL[r.tag] + "] " + (fmtT(r.t) || "") + " " + r.text);
    paintTemoin();
  }
  function paintTemoin() {
    const n = (f) => temRows.filter(f).length;
    const items = [{ id: "all", label: "Tout", n: temRows.length }, { id: "fail", label: "Échecs", n: n((r) => r.ok === false) }, { id: "cerveau", label: "Cerveaux", n: n((r) => r.tag === "cerveau") }, { id: "voix", label: "Voix", n: n((r) => r.tag === "voix") }, { id: "bb", label: "Boîte noire", n: n((r) => r.tag === "bb") }].filter((c) => c.id === "all" || c.n);
    if (!items.some((c) => c.id === tf.f)) tf.f = "all";
    items.forEach((c) => { c.on = c.id === tf.f; });
    temTools.replaceChildren(temRows.length ? ds.toolbar({ chips: ds.chips(items, (id) => { tf.f = id; paintTemoin(); }) }) : null);
    setCnt(temSec, temRows.length || "");
    synthBtn.hidden = !temRows.length;
    const list = temRows.filter((r) => tf.f === "all" || (tf.f === "fail" ? r.ok === false : r.tag === tf.f));
    const head = temFailed.length ? [ds.errorBox({ title: "Source injoignable", cause: temFailed.join(", ") + " — les autres lignes restent affichées.", retry: () => loadTemoin() })] : [];
    if (!temRows.length && temFailed.length) { temBox.replaceChildren(ds.errorBox({ cause: "Sources en échec : " + temFailed.join(", ") + ".", retry: loadTemoin })); return; }
    if (!temRows.length) { temBox.replaceChildren(ds.empty({ icon: "journal", text: "Aucune ligne d'observation pour le moment — le journal se remplit à mesure que Nova travaille." })); return; }
    temBox.replaceChildren(...head, ds.card({ class: "moi-jr-card" },
      ...(list.length ? renderHours(list, { aggregate: tf.f === "all" || tf.f === "cerveau" }) : [ds.empty({ compact: true, icon: "check", text: "Aucune ligne pour ce filtre." })]),
      temNoDetail ? h("div", { class: "ds-meta moi-jr-nodet" }, plural(temNoDetail, "entrée", "entrées") + " de la boîte noire sans détail lisible — le moteur ne les expose pas.") : null));
  }
  async function synth() {
    if (!temoinLines.length) { ctx.toast("Aucune ligne à synthétiser.", true); return; }
    synthBtn.disabled = true;
    const out = h("div", { class: "brief-text" }, "Lecture des lignes…");
    synthBox.replaceChildren(ds.card({ title: "Synthèse du Témoin", actions: [{ icon: "close", tip: "Fermer la synthèse", onClick: () => synthBox.replaceChildren() }] },
      h("div", { class: "ds-meta moi-jr-lead" }, "Générée à la demande par un cerveau du moteur, à partir des seules lignes affichées."), out));
    const prompt = "Tu es le Témoin de Nova. Voici les lignes brutes de mon journal d'observation (cerveaux, voix, boîte noire), les plus récentes d'abord :\n\n" +
      temoinLines.join("\n").slice(0, 6000) +
      "\n\nSynthétise UNIQUEMENT ce que ces lignes établissent : ce qui a été fait, ce qui a échoué, les durées et faits notables. N'ajoute aucun fait absent des lignes. Réponse courte, en français, structurée.";
    let acc = "";
    try {
      await sse("/api/chat", { text: prompt }, (ev, d) => {
        if (dead) return;
        if (ev === "delta") { acc += (d && d.t) || ""; out.innerHTML = md(acc); }
        else if (ev === "error") { out.textContent = "Le moteur a refusé la synthèse : " + String((d && d.message) || "erreur inconnue"); }
      });
      if (!acc && !dead) out.textContent = "Le moteur n'a rien renvoyé pour ces lignes.";
    } catch (e) { if (!dead) out.textContent = "Synthèse impossible pour le moment."; }
    synthBtn.disabled = false;
  }

  /* ═══ La frise ═══ */
  const KINDS = [["tout", "Tout"], ["decision", "Décisions"], ["dot", "Éclats"], ["cerveau", "Cerveaux"], ["memoire", "Mémoire"]];
  let kindFilter = "tout", friseItems = [], friseFailed = [], friseShown = 150, fq = "";
  const friseBar = ds.toolbar({ search: { placeholder: "Chercher dans la frise…", onInput: (v) => { fq = v.toLowerCase(); friseShown = 150; renderFrise(); } } });
  function renderFrise() {
    const items = KINDS.map(([id, label]) => ({ id, label, n: id === "tout" ? friseItems.length : friseItems.filter((i) => i.tag === id).length, on: id === kindFilter })).filter((c) => c.id === "tout" || c.n);
    const old = friseBar.querySelector(".ds-chips"); const ch = ds.chips(items, (id) => { kindFilter = id; friseShown = 150; renderFrise(); });
    if (old) old.replaceWith(ch); else friseBar.append(ch);
    if (!friseTools.contains(friseBar)) friseTools.replaceChildren(friseBar);
    const filtered = friseItems.filter((i) => (kindFilter === "tout" || i.tag === kindFilter) && (!fq || (i.title + " " + (i.meta || "") + " " + (i.detail || "")).toLowerCase().includes(fq)));
    setCnt(friseSec, friseItems.length || "");
    const list = filtered.slice(0, friseShown);
    const head = friseFailed.length ? [ds.errorBox({ title: "Source de frise injoignable", cause: friseFailed.join(", ") + ".", retry: () => loadFrise() })] : [];
    if (!list.length) { friseBox.replaceChildren(...head, ds.empty({ compact: !!friseItems.length, icon: "time", text: friseItems.length ? "Rien dans la frise pour ce filtre." : "La frise est vide : les sources du moteur n'ont rien sur cette période." })); return; }
    friseBox.replaceChildren(...head, ds.card({ class: "moi-jr-card" }, ...renderHours(list, { aggregate: false }),
      filtered.length > list.length ? h("div", { class: "moi-jr-more" }, ds.action({ label: "Afficher plus (" + (filtered.length - list.length) + " restantes)", onClick: () => { friseShown += 150; renderFrise(); } })) : null));
  }
  async function loadFrise() {
    const items = [];
    friseFailed = [];
    const push = (it) => { if (it.title) items.push(it); };
    try { const j = await api.get("/api/decision/log"); for (const e of arrOf(j, "items")) push({ t: tsOf(pick(e, "ts", "at")), tag: "decision", ok: true, title: truncWords(maskText(String(e.question || "")), 200), meta: e.choix ? "→ " + truncWords(maskText(String(e.choix)), 160) : "" }); } catch (e) { friseFailed.push("décisions"); }
    try { const j = await api.get("/api/dots"); for (const r of arrOf(j, "runs")) { const res = cleanResume(String(r.result || r.summary || "")); push({ t: tsOf(pick(r, "ts", "at", "date")), tag: "dot", ok: r.ok !== false, title: "Éclat « " + String(r.dot || "Éclat") + " » — " + (r.ok === false ? "échec" : "passage"), meta: truncWords(maskText(res), 140), detail: res.length > 140 ? maskText(res) : "" }); } } catch (e) { friseFailed.push("passages des Éclats"); }
    try { const j = await api.get("/api/journal"); for (const e of arrOf(j, "cerveaux").slice(-40)) push(brainItem(e)); } catch (e) { friseFailed.push("cerveaux"); }
    try { const j = await api.get("/api/ame/memoire"); for (const m of arrOf(j, "items")) push({ t: tsOf(pick(m, "at", "ts", "date")), tag: "memoire", ok: true, title: truncWords(maskText(String(m.text || m.fait || "")), 200), meta: "" }); } catch (e) { friseFailed.push("mémoire de l'âme"); }
    try { const j = await api.get("/api/memory"); for (const m of arrOf(j, "items")) push({ t: tsOf(pick(m, "at", "ts", "date")), tag: "memoire", ok: true, title: truncWords(maskText(String(m.text || m.fait || m.content || "")), 200), meta: "" }); } catch (e) { friseFailed.push("mémoire durable"); }
    items.sort((a, b) => b.t - a.t);
    /* 24/10 : la mémoire de l'âme et la mémoire durable renvoient souvent le MÊME fait — une ligne par fait. */
    { const seen = new Set(); for (let i = items.length - 1; i >= 0; i--) { const it = items[i]; const k = it.tag + "|" + it.title.trim().toLowerCase() + (it.tag === "memoire" ? "" : "|" + Math.round((it.t || 0) / 60000)); if (seen.has(k)) items.splice(i, 1); else seen.add(k); } }
    friseItems = items;
    if (!dead) renderFrise();
  }
  let lastLoad = Date.now();
  loadTemoin(); loadFrise();
  return {
    destroy() { dead = true; try { soirSec.destroy(); } catch (e) {} },
    onShow() { if (Date.now() - lastLoad < 30000) return; lastLoad = Date.now(); loadTemoin(); loadFrise(); },
  };
}
