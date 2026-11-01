/* Module Vie — « Projets » : projets et notes, sur les routes du moteur :
   GET /api/projects (+ POST /api/projects/scan pour rescanner les dossiers suivis),
   GET /api/notes + save/remove. (FIX-WEB C1 : la section « Missions » appelait /api/missions*, routes
   absentes du moteur → retirée.)
   V5-P (25/10) : la clôture passe par de VRAIES routes — Deuil d'un projet (/api/projects/deuil/*, Feat_Deuil.swift).
   V5-Y : le moteur (Feat_Projects) sert {nom, alias, personnes, echeances « AAAA-MM-JJ — objet », decisions,
   documents, notes, maj, source} — c'est ce qui est affiché.
   V6 « Moi » (25/10/2026, contrat conseil_24-10/V6_DESIGN.md) :
   · un même dossier relevé plusieurs fois (« CAFU », « CAFU — briefs quotidiens… », « CAFU Global
     Humanitarian Outlook 2027 ») est AFFICHÉ en famille : une ligne parente, les variantes en sous-lignes
     (regroupement d'affichage seulement — le moteur garde ses projets tels quels) ;
   · tri : prochaine échéance, puis date de mise à jour ; recherche + puces Tous / Avec échéance / En retard ;
   · lignes .ds-row dépliables (note, échéances, décisions, documents) ; « Clore » en action discrète ;
   · n° de compte / IBAN / jetons dans les notes masqués à l'affichage (••••1008). */
import { fmtDateFR, truncWords } from "../core.js";
import * as ds from "../ds.js";
const arrOf = (j, ...keys) => { if (Array.isArray(j)) return j; for (const k of keys) if (j && Array.isArray(j[k])) return j[k]; return []; };
/* Normalisation d'horodatage (secondes ou ms) puis rendu délégué au formateur partagé fmtDateFR (§9.8). */
const fmtDate = (v) => {
  if (!v) return "";
  const d = new Date(typeof v === "number" ? v * (v < 1e12 ? 1000 : 1) : v);
  return isNaN(d) ? "" : fmtDateFR(d);
};
const fmtShort = (ymd) => { const d = new Date(ymd + "T12:00:00"); return isNaN(d) ? "" : new Intl.DateTimeFormat("fr-FR", { day: "numeric", month: "short" }).format(d); };
/* Masquage d'affichage (V6 §7) : IBAN, jetons, n° de compte (≥ 8 chiffres d'affilée) → ••••1234. */
const maskText = (s) => String(s ?? "")
  .replace(/\b[A-Z]{2}\d{2}(?:\s?[A-Z0-9]{4}){3,8}(?:\s?[A-Z0-9]{1,4})?\b/g, (m) => ds.maskSecret(m))
  .replace(/\b(?:sk|pk|ghp|gho|xox[abp])[-_][A-Za-z0-9-_]{12,}\b/g, (m) => ds.maskSecret(m))
  .replace(/(?<![\w.,/-])\d{8,}(?!\w|[.,/-]\w)/g, (m) => ds.maskSecret(m));
/* « 1 nouveau(x), 7 enrichi(s) » (texte moteur) → accords réels. */
const plurals = (s) => String(s || "").replace(/(\d+)\s+([^\s(),]+)\((s|x)\)/g, (_, n, w, suf) => n + " " + w + (Number(n) > 1 ? suf : ""));
const setCnt = (sec, n) => { let c = sec.querySelector(":scope > .ds-section-head > .ds-count"); if (n === "" || n == null) { if (c) c.remove(); return; } if (!c) { c = document.createElement("span"); c.className = "ds-count"; sec.querySelector(":scope > .ds-section-head > .ds-h2").after(c); } c.textContent = String(n); };
const norm = (s) => String(s || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

export async function mount(root, ctx) {
  const { api, h, ic } = ctx;
  let dead = false;
  root.classList.add("mod--data", "moi-pj");
  const scanBtn = ds.action({ label: "Rescanner les projets", icon: "refresh", tip: "Relire les dossiers suivis et les échanges pour mettre les projets à jour", onClick: () => rescan() });
  root.append(ds.pageHead({ title: "Projets", sub: "Dossiers suivis, échéances, décisions — et tes notes libres", actions: [scanBtn] }));
  async function rescan() {
    scanBtn.disabled = true;
    try { await api.post("/api/projects/scan", {}); ctx.toast("Scan des projets lancé."); setTimeout(loadProjects, 1200); }
    catch (err) { ctx.toast("Scan impossible : le moteur n'a pas accepté la demande.", true); }
    scanBtn.disabled = false;
  }

  const pf = { q: "", f: "all" };
  const projSec = ds.section({ title: "Projets" });
  const tb = ds.toolbar({ search: { placeholder: "Chercher un projet, une personne, une note…", onInput: (v) => { pf.q = v; paint(); } } });
  const scanMeta = h("div", { class: "ds-meta moi-pj-scan" });
  const listBox = h("div", { class: "moi-pj-list" }, ds.skeleton(4));
  projSec.body.append(tb, scanMeta, listBox);
  const archSec = ds.section({ title: "Archives", collapsible: true, open: false });
  archSec.hidden = true;
  const noteSec = ds.section({ title: "Notes" });
  root.append(projSec, archSec, noteSec);

  /* Notes : champ PERSISTANT (hors du rendu de la liste) — un rafraîchissement ne perd plus le brouillon. */
  const noteTa = h("textarea", { class: "fld fld-area", rows: "2", placeholder: "Une note libre… (Entrée garde la note, Maj+Entrée = nouvelle ligne)", "aria-label": "Nouvelle note libre" });
  const noteBtn = ds.action({ label: "Garder", primary: true, onClick: () => saveNote() });
  const noteList = h("div", { class: "ds-list moi-pj-notes" }, ds.skeleton(2));
  noteSec.body.append(h("div", { class: "moi-pj-compose" }, noteTa, noteBtn), noteList);
  noteTa.addEventListener("keydown", (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); saveNote(); } });
  async function saveNote() {
    const t = noteTa.value.trim(); if (!t || noteBtn.disabled) return;
    noteBtn.disabled = true;
    try { await api.post("/api/notes/save", { title: t.slice(0, 90), body: t }); noteTa.value = ""; ctx.toast("Note gardée."); loadNotes(); }
    catch (e) { ctx.toast("Note impossible : le moteur n'a pas enregistré.", true); }
    noteBtn.disabled = false;
  }

  /* V5-P — DEUIL D'UN PROJET (#32) : « Clore » → le cerveau propose un bilan + des leçons (POST
     /api/projects/deuil/proposer) ; tu relis et corriges ; « Valider et archiver » → chaque leçon devient un fait
     de mémoire et le projet passe aux Archives (POST …/valider). Réversible : « Restaurer » (POST …/restaurer). */
  const deuilBox = {};
  let props = {};
  function deuilPanel(p, prop) {
    const box = deuilBox[p.id];
    if (!box) return;
    const bil = h("textarea", { class: "fld fld-area", rows: "3", "aria-label": "Bilan du projet" }); bil.value = String((prop && prop.bilan) || "");
    const lec = h("textarea", { class: "fld fld-area", rows: "6", "aria-label": "Leçons, une par ligne" }); lec.value = (Array.isArray(prop && prop.lecons) ? prop.lecons : []).join("\n");
    const go = ds.action({ label: "Valider et archiver", primary: true, onClick: async () => {
      const lecons = lec.value.split("\n").map((x) => x.replace(/^[-•]\s*/, "").trim()).filter(Boolean);
      if (!lecons.length) { ctx.toast("Garde au moins une leçon, ou annule.", true); return; }
      go.disabled = true;
      try { const r = await api.post("/api/projects/deuil/valider", { id: p.id, lecons, bilan: bil.value.trim() }); if (r && r.error) throw new Error(String(r.error));
        const n = Number(r && r.lecons_en_memoire) || 0, dj = Number(r && r.deja_en_memoire) || 0;
        ctx.toast("Projet archivé — " + n + " leçon" + (n > 1 ? "s" : "") + " en mémoire" + (dj ? ", " + dj + " déjà connue" + (dj > 1 ? "s" : "") : "") + "."); loadProjects(); }
      catch (e) { go.disabled = false; ctx.toast("Archivage impossible : " + String((e && e.message) || e), true); }
    } });
    const no = ds.action({ label: "Annuler", onClick: async () => { try { await api.post("/api/projects/deuil/abandonner", { id: p.id }); } catch (e) {} delete props[p.id]; box.replaceChildren(); } });
    box.replaceChildren(ds.card({ class: "moi-pj-deuil" },
      h("div", { class: "ds-h3" }, "Clore « " + String(p.nom || "Projet") + " » — proposition à relire"),
      h("p", { class: "ds-meta" }, "Rédigée par le cerveau" + (prop && prop.brain ? " (" + String(prop.brain) + ")" : "") + " à partir du dossier, des décisions, de la mémoire et de ce que tu en as dit. Corrige librement."),
      h("label", { class: "field-lb" }, "Bilan"), bil,
      h("label", { class: "field-lb" }, "Leçons (une par ligne) — chacune deviendra un fait de mémoire"), lec,
      h("div", { class: "moi-pj-deuil-btns" }, go, no, h("span", { class: "ds-meta" }, "Réversible : le projet pourra sortir des archives."))));
  }
  async function proposeDeuil(p, btn) {
    if (btn) btn.disabled = true;
    const box = deuilBox[p.id]; if (box) box.replaceChildren(ds.skeleton(2));
    try { const r = await api.post("/api/projects/deuil/proposer", { id: p.id }); if (dead) return; if (!r || r.error) throw new Error(String((r && r.error) || "réponse vide du moteur")); props[p.id] = r; deuilPanel(p, r); }
    catch (e) { if (box && !dead) box.replaceChildren(ds.errorBox({ title: "Proposition impossible", cause: String((e && e.message) || e), retry: () => proposeDeuil(p, btn) })); }
    if (btn) btn.disabled = false;
  }

  /* ── Lecture des projets ── */
  const strs = (v) => (Array.isArray(v) ? v.map((x) => String(x || "").trim()).filter(Boolean) : []);
  const todayYmd = () => { const d = new Date(); return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0"); };
  const echs = (p) => strs(p.echeances).map((e) => { const m = /^(\d{4}-\d{2}-\d{2})\s*[—–-]?\s*(.*)$/.exec(e); return m ? { d: m[1], t: m[2] || "" } : { d: "", t: e }; });
  const nextEch = (p) => {
    const ec = echs(p);
    const dated = ec.filter((e) => e.d).sort((x, y) => x.d.localeCompare(y.d));
    const t = todayYmd();
    return dated.find((e) => e.d >= t) || dated[dated.length - 1] || ec[0] || null;
  };
  const isLate = (p) => { const ne = nextEch(p); return !!(ne && ne.d && ne.d < todayYmd()); };
  const majMs = (p) => { const d = new Date(p.maj || 0); return isNaN(d) ? 0 : d.getTime(); };

  /* Familles d'affichage : A et B vont ensemble si le nom de l'un commence le nom de l'autre
     (« CAFU » → « CAFU — briefs… »), si le nom de l'un figure parmi les alias de l'autre, ou s'ils
     partagent un alias distinctif (≥ 4 caractères). Union-find ; parent = le nom le plus court. */
  function families(items) {
    const n = items.length, par = items.map((_, i) => i);
    const find = (i) => (par[i] === i ? i : (par[i] = find(par[i])));
    const join = (a, b) => { a = find(a); b = find(b); if (a !== b) par[b] = a; };
    const names = items.map((p) => norm(p.nom || p.name || ""));
    const aliases = items.map((p) => new Set(strs(p.alias).map(norm).filter((a) => a.length >= 4)));
    for (let i = 0; i < n; i++) for (let k = i + 1; k < n; k++) {
      const a = names[i], b = names[k];
      if (!a || !b) continue;
      const pre = (x, y) => x.length >= 3 && (y === x || y.startsWith(x + " "));
      if (pre(a, b) || pre(b, a) || aliases[k].has(a) || aliases[i].has(b) || [...aliases[i]].some((x) => aliases[k].has(x))) join(i, k);
    }
    const groups = new Map();
    items.forEach((p, i) => { const r = find(i); if (!groups.has(r)) groups.set(r, []); groups.get(r).push(p); });
    return [...groups.values()].map((ms) => {
      const sorted = ms.slice().sort((x, y) => norm(x.nom).length - norm(y.nom).length || majMs(y) - majMs(x));
      const parent = sorted[0];
      const kids = sorted.slice(1).sort((x, y) => sortKey(x).localeCompare(sortKey(y)));
      return { parent, kids, all: ms };
    });
  }
  /* Tri : échéance la plus proche d'abord (en retard compris), puis les plus récemment mis à jour. */
  const sortKey = (p) => { const ne = nextEch(p); return (ne && ne.d ? "0" + ne.d : "1") + (9e15 - majMs(p)).toString().padStart(17, "0"); };
  const famKey = (f) => f.all.map(sortKey).sort()[0];

  let items = [], archives = [], lastJ = null;
  function matches(p) {
    if (!pf.q) return true;
    const q = norm(pf.q);
    return norm([p.nom, ...strs(p.alias), ...strs(p.personnes), p.notes, ...strs(p.echeances), ...strs(p.decisions)].join(" ")).includes(q);
  }
  const famPass = (f) => {
    if (pf.f === "ech" && !f.all.some((p) => echs(p).some((e) => e.d))) return false;
    if (pf.f === "late" && !f.all.some(isLate)) return false;
    return f.all.some(matches);
  };

  const subTitle = (parent, p) => {
    const pn = String(parent.nom || ""), cn = String(p.nom || "Projet");
    if (cn.toLowerCase().startsWith(pn.toLowerCase()) && cn.length > pn.length) { const rest = cn.slice(pn.length).replace(/^[\s—–:·-]+/, ""); if (rest) return rest.charAt(0).toUpperCase() + rest.slice(1); }
    return cn;
  };
  function echPill(p) {
    const ne = nextEch(p);
    if (!ne || !ne.d) return null;
    const t = todayYmd();
    const days = Math.round((new Date(ne.d + "T12:00:00") - new Date(t + "T12:00:00")) / 86400000);
    if (days < 0) return ds.pill("En retard · " + fmtShort(ne.d), "danger");
    if (days === 0) return ds.pill("Aujourd'hui", "warn");
    if (days <= 7) return ds.pill(days === 1 ? "Demain" : fmtShort(ne.d), "warn");
    return ds.pill(fmtShort(ne.d), "neutral");
  }
  function details(p) {
    const ec = echs(p), dec = strs(p.decisions), docs = strs(p.documents), pers = strs(p.personnes), al = strs(p.alias);
    const t = todayYmd();
    const blk = (title, kids) => kids && (Array.isArray(kids) ? kids.length : true) ? h("div", { class: "moi-pj-blk" }, h("div", { class: "moi-pj-blk-t" }, title), kids) : null;
    const ul = (arr, max, fmt) => h("ul", { class: "moi-pj-ul" }, ...arr.slice(0, max).map(fmt), arr.length > max ? h("li", { class: "ds-meta" }, "… et " + (arr.length - max) + " autre" + (arr.length - max > 1 ? "s" : "")) : null);
    return h("div", { class: "moi-pj-det" },
      p.notes ? h("p", { class: "moi-pj-note" }, maskText(String(p.notes))) : null,
      ec.length ? blk("Échéances", ul(ec.sort((x, y) => (x.d || "9").localeCompare(y.d || "9")), 8, (e) => h("li", { class: e.d && e.d < t ? "is-late" : null }, e.d ? h("b", { class: "ds-num" }, fmtDate(e.d + "T12:00:00")) : null, e.d && e.t ? " — " : "", maskText(e.t)))) : null,
      dec.length ? blk("Décisions (" + dec.length + ")", ul(dec, 8, (d) => h("li", {}, maskText(d)))) : null,
      docs.length ? blk("Documents (" + docs.length + ")", ul(docs, 8, (d) => h("li", { title: maskText(d) }, maskText(d.split("/").pop())))) : null,
      pers.length ? blk("Personnes", h("div", { class: "moi-pj-people" }, ...pers.map((x) => h("span", { class: "ds-chip moi-pj-person" }, x)))) : null,
      al.length ? h("div", { class: "ds-meta moi-pj-al" }, "Aussi appelé : " + al.join(" · ")) : null,
      p.source === "auto" ? h("div", { class: "ds-meta" }, "Relevé automatiquement dans tes fichiers et échanges.") : null);
  }
  const openSet = new Set();
  function projRow(p, opts = {}) {
    const box = h("div", { class: "moi-pj-deuil-slot" }); deuilBox[p.id] = box;
    const pers = strs(p.personnes), dec = strs(p.decisions), docs = strs(p.documents);
    const ne = nextEch(p);
    const meta = [
      ne && ne.t ? maskText(ne.t) : "",
      pers.length ? (pers.length <= 2 ? pers.join(", ") : pers.slice(0, 2).join(", ") + " +" + (pers.length - 2)) : "",
      dec.length ? dec.length + " décision" + (dec.length > 1 ? "s" : "") : "",
      docs.length ? docs.length + " document" + (docs.length > 1 ? "s" : "") : "",
      p.maj ? "mis à jour " + fmtDate(p.maj) : "",
    ].filter(Boolean).join(" · ") || (p.notes ? truncWords(maskText(String(p.notes)), 120) : "—");
    const key = String(p.id || p.nom);
    const det = details(p);
    const wrap = h("div", { class: "moi-pj-item" + (opts.sub ? " is-sub" : "") + (isLate(p) ? " is-late" : "") });
    const chev = h("span", { class: "moi-pj-chev", "aria-hidden": "true", html: ic("chev-r", 14) });
    const sideKids = [echPill(p), opts.n ? h("span", { class: "ds-count moi-pj-n", title: opts.n + " variantes de ce dossier", "aria-label": opts.n + " variantes" }, "+" + opts.n) : null].filter(Boolean);
    const r = ds.row({
      lead: chev,
      title: opts.title || String(p.nom || p.name || "Projet"),
      meta,
      side: sideKids.length ? h("span", { class: "moi-pj-side" }, ...sideKids) : null,
      actions: p.id ? [{ label: "Clore", ghost: true, tip: "Clore ce projet : bilan et leçons proposés par le cerveau, à relire et valider", onClick: (e) => proposeDeuil(p, e.currentTarget) }] : null,
      onOpen: () => toggle(),
    });
    r.setAttribute("aria-expanded", "false");
    const toggle = (force) => {
      const on = force != null ? force : !wrap.classList.contains("is-open");
      wrap.classList.toggle("is-open", on); r.setAttribute("aria-expanded", on ? "true" : "false");
      det.hidden = !on;
      if (on) openSet.add(key); else openSet.delete(key);
    };
    det.hidden = true;
    wrap.append(r, det, box);
    if (openSet.has(key)) toggle(true);
    if (p.id && props[p.id]) deuilPanel(p, props[p.id]);
    return wrap;
  }
  function paint() {
    const fams = families(items).sort((a, b) => famKey(a).localeCompare(famKey(b)));
    const nEch = fams.filter((f) => f.all.some((p) => echs(p).some((e) => e.d))).length;
    const nLate = fams.filter((f) => f.all.some(isLate)).length;
    const chipsEl = ds.chips([{ id: "all", label: "Tous", n: fams.length, on: pf.f === "all" }, { id: "ech", label: "Avec échéance", n: nEch, on: pf.f === "ech" }, { id: "late", label: "En retard", n: nLate, on: pf.f === "late" }], (id) => { pf.f = id; paint(); });
    const old = tb.querySelector(".ds-chips"); if (old) old.replaceWith(chipsEl); else tb.append(chipsEl);
    setCnt(projSec, fams.length);
    const shown = fams.filter(famPass);
    if (!items.length) {
      listBox.replaceChildren(ds.empty({ icon: "kanban", text: archives.length ? "Aucun projet actif — tous sont aux archives." : "Aucun projet indexé pour l'instant. Lance un scan : Nova relit les dossiers suivis et tes échanges.", action: { label: "Rescanner les projets", icon: "refresh", primary: true, onClick: () => rescan() } }));
      return;
    }
    if (!shown.length) {
      listBox.replaceChildren(ds.empty({ compact: true, icon: "search", text: pf.f === "late" ? "Aucun projet en retard." : pf.f === "ech" ? "Aucun projet avec une échéance datée ne correspond." : "Aucun projet ne correspond à « " + pf.q + " ».", action: { label: "Tout afficher", ghost: true, onClick: () => { pf.f = "all"; pf.q = ""; if (tb.input) { tb.input.value = ""; tb.input.dispatchEvent(new Event("input")); } paint(); } } }));
      return;
    }
    listBox.replaceChildren(h("div", { class: "ds-list" }, ...shown.map((f) => {
      if (!f.kids.length) return projRow(f.parent);
      const kids = f.kids.filter((p) => !pf.q || matches(p) || matches(f.parent));
      return h("div", { class: "moi-pj-fam" }, projRow(f.parent, { n: f.kids.length }),
        h("div", { class: "moi-pj-kids", role: "group", "aria-label": "Variantes de « " + String(f.parent.nom || "") + " »" }, ...kids.map((p) => projRow(p, { sub: true, title: subTitle(f.parent, p) }))));
    })));
  }
  function paintArchives() {
    archSec.hidden = !archives.length;
    setCnt(archSec, archives.length || "");
    archSec.body.replaceChildren(h("div", { class: "ds-list" }, ...archives.map((p) => {
      const lec = Array.isArray(p.archive_lecons) ? p.archive_lecons : [];
      const wrap = h("div", { class: "moi-pj-item" });
      const r = ds.row({
        lead: "brief",
        title: String(p.nom || "Projet"),
        meta: ["archivé le " + (fmtDate(p.archive_ts) || "—"), p.archive_bilan ? truncWords(maskText(String(p.archive_bilan)), 120) : "", lec.length ? lec.length + " leçon" + (lec.length > 1 ? "s" : "") + " en mémoire" : ""].filter(Boolean).join(" · "),
        actions: [{ label: "Restaurer", tip: "Remettre ce projet parmi les actifs (les leçons restent en mémoire)", onClick: async (e) => { e.currentTarget.disabled = true; try { await api.post("/api/projects/deuil/restaurer", { id: p.id }); ctx.toast("Projet sorti des archives."); } catch (err) { ctx.toast("Restauration impossible.", true); } loadProjects(); } }],
      });
      wrap.append(r);
      if (lec.length) wrap.append(h("ul", { class: "moi-pj-ul moi-pj-lec" }, ...lec.slice(0, 7).map((l) => h("li", {}, maskText(String(l))))));
      return wrap;
    })));
  }
  async function loadProjects() {
    try {
      const j = await api.get("/api/projects");
      if (dead) return;
      lastJ = j;
      const all = arrOf(j, "items", "projects");
      items = all.filter((p) => p.archive !== true);
      archives = all.filter((p) => p.archive === true);
      try { const dj = await api.get("/api/projects/deuil"); props = (dj && dj.propositions && typeof dj.propositions === "object") ? dj.propositions : {}; } catch (e) {}
      if (dead) return;
      scanMeta.replaceChildren(...[j && j.running ? h("span", {}, ds.pill("Scan en cours", "warn")) : null,
        h("span", {}, j && j.last_scan ? "Dernier scan " + fmtDate(j.last_scan) + (j.last_note ? " — " + plurals(j.last_note) : "") : "Aucun scan enregistré")].filter(Boolean));
      paint(); paintArchives();
    } catch (e) { if (!dead) listBox.replaceChildren(ds.errorBox({ cause: "Le moteur n'a pas renvoyé les projets.", retry: loadProjects })); }
  }
  async function loadNotes() {
    try {
      const j = await api.get("/api/notes");
      if (dead) return;
      /* Forme moteur (Extras.swift) : {id, title, body, updated, kind, done}. Les notes « autoeval » et
         « manquement » appartiennent à Âme (registre) : elles ne polluent pas les notes libres. */
      const all = arrOf(j, "items", "notes").filter((n) => !n.kind || (n.kind !== "autoeval" && n.kind !== "manquement"));
      const shownN = all.slice(0, 30);
      setCnt(noteSec, all.length || "");
      noteList.replaceChildren(...(all.length ? shownN.map((n) => ds.row({
        lead: "note",
        title: truncWords(maskText(String(n.body || n.title || n.text || "")), 200),
        meta: fmtDate(n.updated || n.at || n.ts) || null,
        actions: [{ icon: "trash", tip: "Supprimer la note", onClick: async () => { try { await api.post("/api/notes/remove", { id: n.id }); ctx.toast("Note supprimée."); loadNotes(); } catch (e) { ctx.toast("Suppression impossible.", true); } } }],
      })) : [ds.empty({ compact: true, icon: "note", text: "Aucune note pour le moment — écris-en une ci-dessus.", action: { label: "Écrire une note", ghost: true, onClick: () => noteTa.focus() } })]),
        all.length > shownN.length ? h("div", { class: "ds-meta moi-pj-more" }, "+ " + (all.length - shownN.length) + " notes plus anciennes") : null);
    } catch (e) { if (!dead) noteList.replaceChildren(ds.errorBox({ cause: "Le moteur n'a pas renvoyé les notes.", retry: loadNotes })); }
  }
  let lastLoad = Date.now();
  loadProjects(); loadNotes();
  return {
    destroy() { dead = true; },
    onShow() { if (Date.now() - lastLoad < 30000) return; lastLoad = Date.now(); loadProjects(); loadNotes(); },
  };
}
