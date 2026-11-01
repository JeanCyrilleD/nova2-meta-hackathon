/* Module Savoir — la base de connaissances de Nova, sur ses routes :
   GET /api/knowledge/status (état de l'index + racines), GET /api/knowledge/recent (documents récents
   des dossiers suivis), GET /api/knowledge/search?q= (recherche — aussi l'outil de l'Archéologue n°30 et
   l'entrée de la Sérendipité n°12), MÉMOIRE SOUVERAINE (24/10) : GET /api/memory/facts (recherche,
   filtres origine/type/verrou/date, compteur réel), POST /api/memory/add, POST /api/memory/fact/update
   (édition, verrou), POST /api/memory/fact/forget (oubli réel, confirmé), GET /api/memory/fact/history +
   POST /api/memory/fact/restore (versions), GET /api/memory/export?format=md|json, POST /api/memory/import
   (aperçu puis fusion dédoublonnée) ; Archéologue POST /api/archeo ; skills GET /api/skills(+/content, /save).
   V6 « Moi » (25/10/2026, contrat conseil_24-10/V6_DESIGN.md) :
   · statistiques de l'index en .ds-kpis, recherche documentaire instantanée (temporisée) ;
   · souvenirs GROUPÉS à l'affichage — Toi · Travail & CAFU · Échéances & voyages · Nova — technique
     (replié) — par une heuristique sur les champs existants (origine/source, type, texte) ; le moteur
     n'est pas modifié ;
   · faits longs coupés à 2 lignes avec « lire la suite » ; actions (modifier, épingler, historique,
     oublier) au survol / focus seulement ; secrets masqués à l'affichage. */
import { LBL, fmtV, fmtDateFR, truncWords, md } from "../core.js";
import * as ds from "../ds.js";
const arrOf = (j, ...keys) => { if (Array.isArray(j)) return j; for (const k of keys) if (j && Array.isArray(j[k])) return j[k]; return []; };
const fmtDate = (v) => {
  if (!v) return "";
  const d = new Date(typeof v === "number" ? v * (v < 1e12 ? 1000 : 1) : v);
  return isNaN(d) ? "" : fmtDateFR(d);
};
const maskText = (s) => String(s ?? "")
  .replace(/\b[A-Z]{2}\d{2}(?:\s?[A-Z0-9]{4}){3,8}(?:\s?[A-Z0-9]{1,4})?\b/g, (m) => ds.maskSecret(m))
  .replace(/\b(?:sk|pk|ghp|gho|xox[abp])[-_][A-Za-z0-9-_]{12,}\b/g, (m) => ds.maskSecret(m))
  .replace(/(?<![\w.,/-])\d{8,}(?!\w|[.,/-]\w)/g, (m) => ds.maskSecret(m));
const setCnt = (sec, n) => { let c = sec.querySelector(":scope > .ds-section-head > .ds-count"); if (n === "" || n == null) { if (c) c.remove(); return; } if (!c) { c = document.createElement("span"); c.className = "ds-count"; sec.querySelector(":scope > .ds-section-head > .ds-h2").after(c); } c.textContent = String(n); };
const plural = (n, one, many) => n + " " + (n > 1 ? many : one);
const fold = (s) => String(s || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
/* Groupes d'affichage des souvenirs (heuristique, lecture seule). Ordre des tests : technique de Nova,
   puis travail, puis échéances & voyages ; le reste parle de toi. */
const GROUPS = [
  { id: "toi", label: "Toi", open: true },
  { id: "travail", label: "Travail & CAFU", open: true },
  { id: "echeances", label: "Échéances & voyages", open: true },
  { id: "nova", label: "Nova — technique", open: false },
];
const RX_TECH = /\b(nova ?2|nova ?1|package_app|launchagent|plist|sqlite|shell|script|outil|dots?\b|eclats?\b|api\b|apis\b|cerveau|spark|wonder|json|tools\/|build|lecon \(nova\)|-1743|terminal|applescript|webkit|swift)/;
const RX_WORK = /\b(cafu|ocha|gho|humanitar|teams|reunion|atelier|rapport|bailleur|partenaire|plaidoyer|sudan|soudan|mission|collegue|catch-up|brief|programme|consultation|projet|equipe|strategie|financement|todoist)/;
const RX_DUE = /\b(visa|e-visa|voyage|vol\b|vols\b|billet|hotel|aeroport|echeance|avant le|avant dimanche|abonnement|renouvel|expire|jusqu'au|rendez-vous|passeport|deadline|date limite|a soumettre)/;
function groupOf(m) {
  const t = fold(m.text), o = fold(m.origine || m.source);
  if (/nova|outil|assistant/.test(o) || RX_TECH.test(t)) return "nova";
  if (RX_WORK.test(t)) return "travail";
  if (RX_DUE.test(t)) return "echeances";
  return "toi";
}

export async function mount(root, ctx) {
  const { api, h, ic } = ctx;
  let dead = false;
  root.classList.add("mod--data", "moi-sv");
  root.append(ds.pageHead({ title: "Savoir", sub: "Ce que Nova a indexé de tes dossiers — et ce qu'elle retient de toi" }));

  /* ── 1 · Index des documents ── */
  const idxSec = ds.section({ title: "Index des documents" });
  const statusBox = h("div", {}, ds.skeleton(1));
  const resBox = h("div", { class: "moi-sv-res" });
  let qTimer = 0, lastQ = "";
  const docBar = ds.toolbar({ search: { placeholder: "Chercher dans tes documents indexés…", onInput: (v) => { clearTimeout(qTimer); if (!v) { lastQ = ""; resBox.replaceChildren(); return; } qTimer = setTimeout(() => search(v), 420); } } });
  docBar.input.addEventListener("keydown", (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter") { clearTimeout(qTimer); search(docBar.input.value.trim()); } });
  idxSec.body.append(statusBox, docBar, resBox);

  /* ── 2 · Souvenirs (mémoire durable) ── */
  const memSec = ds.section({ title: "Souvenirs" });
  /* ── 3 · Archéologue, documents récents, skills (secondaires, repliés) ── */
  const archSec = ds.section({ title: "Archéologue", collapsible: true, open: false });
  const recSec = ds.section({ title: "Documents récents", collapsible: true, open: false });
  const skillsSec = ds.section({ title: "Skills — méthodes de la maison", collapsible: true, open: false });
  root.append(idxSec, memSec, archSec, recSec, skillsSec);

  async function loadStatus() {
    try {
      const j = await api.get("/api/knowledge/status");
      if (dead) return;
      const st = (j && j.status) || {};
      const roots = arrOf(j, "roots");
      /* Libellés = table partagée de core.js (§9.8) : une clé inconnue est OMISE, jamais affichée brute. */
      const known = (k) => { if (!LBL[k]) { try { console.warn("Savoir : clé d'état inconnue omise :", k); } catch (e) {} return false; } return true; };
      const isNum = (v) => typeof v === "number" && isFinite(v);
      const nums = Object.entries(st).filter(([k, v]) => isNum(v) && known(k));
      const dedup = nums.filter(([k, v]) => !(k === "indexed_chunks" && isNum(st.chunks) && st.chunks === v));
      const etat = st.state != null ? fmtV("state", st.state) : st.status != null ? fmtV("status", st.status) : st.scanning === true ? "analyse en cours" : "";
      const cur = typeof st.current === "string" && st.current.trim() ? st.current.trim() : "";
      statusBox.replaceChildren(
        dedup.length ? ds.kpis(dedup.slice(0, 3).map(([k, v]) => ({ label: k === "chunks" && st.indexed_chunks === v ? "Morceaux indexés" : LBL[k], value: fmtV(k, v) })).concat([{ label: "Index", value: etat ? etat.charAt(0).toUpperCase() + etat.slice(1) : null, delta: cur ? "en cours : " + truncWords(cur.split("/").pop(), 40) : "" }])) : null,
        roots.length ? h("div", { class: "ds-meta moi-sv-roots" }, "Racines suivies : ", ...roots.map((r) => h("span", { class: "moi-sv-root" }, String(r)))) : null);
    } catch (e) { if (!dead) statusBox.replaceChildren(ds.errorBox({ cause: "Le moteur n'a pas renvoyé l'état de l'index.", retry: loadStatus })); }
  }
  async function search(q) {
    if (!q) return;
    lastQ = q;
    resBox.replaceChildren(ds.skeleton(2));
    try {
      const j = await api.get("/api/knowledge/search?q=" + encodeURIComponent(q));
      if (dead || q !== lastQ) return;
      const items = arrOf(j, "items", "results");
      resBox.replaceChildren(items.length ? h("div", {}, h("div", { class: "ds-meta moi-sv-hits" }, plural(items.length, "document trouvé", "documents trouvés") + " pour « " + q + " »"),
        h("div", { class: "ds-list" }, ...items.map((it) => ds.row({ lead: "file", title: String(it.title || it.name || (it.path || "").split("/").pop() || "Document"), meta: truncWords(maskText(String(it.snippet || it.text || it.path || "")), 160) || null, tip: it.path ? String(it.path) : null }))))
        : ds.empty({ compact: true, icon: "search", text: "Aucun document ne contient « " + q + " » dans l'index actuel." }));
    } catch (e) { if (!dead) resBox.replaceChildren(ds.errorBox({ cause: "La recherche documentaire ne répond pas.", retry: () => search(q) })); }
  }

  /* ── Archéologue (#30) : POST /api/archeo {sujet, depuis, jusqua, synthese} → traces DATÉES de la période
     (conversations, mémoire, rapports des Éclats, documents), en ordre chronologique ; « Retracer » demande
     au cerveau l'évolution à partir de ces seules traces. Lecture seule. ── */
  const arIn = h("input", { class: "fld", type: "text", placeholder: "Un sujet (ex. maison, GHO 2027, BRVM…)", "aria-label": "Sujet à retracer" });
  const arFrom = h("input", { class: "fld", type: "date", "aria-label": "Depuis" });
  const arTo = h("input", { class: "fld", type: "date", "aria-label": "Jusqu'à" });
  const arPer = h("select", { class: "sel ds-sort", "aria-label": "Période" }, h("option", { value: "90" }, "3 derniers mois"), h("option", { value: "30" }, "30 derniers jours"), h("option", { value: "365" }, "12 derniers mois"), h("option", { value: "" }, "Toute l'histoire"), h("option", { value: "x" }, "Dates choisies…"));
  const arOut = h("div", { class: "moi-sv-arch-out" });
  const isoDay = (d) => d.toISOString().slice(0, 10);
  const syncPer = () => { const v = arPer.value; const custom = v === "x"; arFrom.hidden = !custom; arTo.hidden = !custom; if (!custom) { arTo.value = ""; arFrom.value = v ? isoDay(new Date(Date.now() - Number(v) * 86400000)) : ""; } };
  arPer.addEventListener("change", syncPer); syncPer();
  const SRC_LBL = { conversation: "Conversation", "mémoire": "Mémoire", "éclat": "Éclat", document: "Document" };
  async function archeo(synthese) {
    const q = arIn.value.trim(); if (!q) { ctx.toast("Indique un sujet.", true); arIn.focus(); return; }
    arOut.replaceChildren(ds.skeleton(3));
    try {
      const j = await api.post("/api/archeo", { sujet: q, depuis: arFrom.value || "", jusqua: arTo.value || "", synthese: !!synthese });
      if (dead) return;
      if (j && j.error) throw new Error(String(j.error));
      const tr = arrOf(j, "traces");
      const src = (j && j.sources) || {};
      const synth = j && j.synthese ? ds.card({ class: "moi-sv-synth" }, h("div", { class: "brief-text", html: md(String(j.synthese)) })) : (j && j.synthese_error ? ds.errorBox({ title: "Synthèse indisponible", cause: String(j.synthese_error) }) : null);
      arOut.replaceChildren(
        h("div", { class: "ds-meta moi-sv-hits" }, plural(tr.length, "trace datée", "traces datées") + (tr.length ? " — " + Object.entries(src).map(([k, v]) => v + " " + (SRC_LBL[k] || k).toLowerCase()).join(" · ") : "")),
        ...(tr.length ? [synth, h("ol", { class: "moi-sv-arch-list" }, ...tr.map((t) => h("li", {},
          h("span", { class: "moi-sv-arch-d ds-num" }, fmtDate(t.date) || "—"),
          ds.pill((SRC_LBL[t.source] || String(t.source || "Source")) + (t.qui ? " · " + String(t.qui) : ""), "neutral"),
          h("div", { class: "moi-sv-arch-t" }, t.titre ? h("b", {}, String(t.titre) + " — ") : null, maskText(String(t.texte || "")), t.date_note ? h("span", { class: "ds-meta" }, " (" + String(t.date_note) + ")") : null)))),
          !synthese ? h("div", { class: "moi-sv-arch-more" }, ds.action({ label: "Retracer l'évolution (cerveau)", onClick: () => archeo(true) })) : null]
          : [ds.empty({ compact: true, icon: "search", text: "Aucune trace de « " + q + " » dans cette période — essaie un mot plus court ou une période plus large." })]));
    } catch (e) { if (!dead) arOut.replaceChildren(ds.errorBox({ title: "Archéologue indisponible", cause: String((e && e.message) || e), retry: () => archeo(synthese) })); }
  }
  arIn.addEventListener("keydown", (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter") { e.preventDefault(); archeo(false); } });
  archSec.body.append(h("p", { class: "ds-meta moi-sv-lead" }, "L'évolution d'une idée dans le temps : un sujet, une période — Nova retrouve les traces datées."),
    h("div", { class: "moi-sv-arch-form" }, arIn, arPer, arFrom, arTo, ds.action({ label: "Fouiller", primary: true, icon: "search", onClick: () => archeo(false) })), arOut);

  async function loadRecent() {
    try {
      const j = await api.get("/api/knowledge/recent");
      if (dead) return;
      const items = arrOf(j, "items", "recent");
      setCnt(recSec, items.length || "");
      const shownR = items.slice(0, 12);
      recSec.body.replaceChildren(items.length ? h("div", { class: "ds-list" }, ...shownR.map((it) => ds.row({
        lead: "file", title: String(it.title || it.name || (it.path || "").split("/").pop() || "Document"),
        meta: [fmtDate(it.at || it.mtime || it.date || it.ts), it.path ? String(it.path).split("/").slice(0, -1).join("/") : ""].filter(Boolean).join(" · ") || null, tip: it.path ? String(it.path) : null })),
        items.length > shownR.length ? h("div", { class: "ds-meta moi-sv-more-t" }, "+ " + (items.length - shownR.length) + " autres documents récents") : null)
        : ds.empty({ compact: true, icon: "file", text: "Aucun document récent dans les racines suivies." }));
    } catch (e) { if (!dead) recSec.body.replaceChildren(ds.errorBox({ cause: "Le moteur n'a pas renvoyé les documents récents.", retry: loadRecent })); }
  }

  /* ── MÉMOIRE SOUVERAINE ─────────────────────────────────────────────── */
  const OP_LBL = { add: "créé", update: "modifié", restore: "restauré", import: "importé", lock: "épinglé", unlock: "désépinglé", forget: "oublié", reintegrate: "réintégré" };
  const mf = { q: "", origine: "", kind: "", locked: false, periode: "" };
  let memShown = 100, mqTimer = 0;
  const memBar = ds.toolbar({ search: { placeholder: "Chercher dans les souvenirs…", onInput: (v) => { clearTimeout(mqTimer); mqTimer = setTimeout(() => { mf.q = v; memShown = 100; loadMemory(); }, 320); } } });
  const selOrig = h("select", { class: "sel ds-sort", "aria-label": "Origine" }, h("option", { value: "" }, "Toutes origines"));
  const selKind = h("select", { class: "sel ds-sort", "aria-label": "Type" }, h("option", { value: "" }, "Tous types"), h("option", { value: "profil" }, "Profil"), h("option", { value: "contexte" }, "Contexte"));
  const selPer = h("select", { class: "sel ds-sort", "aria-label": "Période" }, h("option", { value: "" }, "Toute date"), h("option", { value: "7" }, "7 derniers jours"), h("option", { value: "30" }, "30 derniers jours"), h("option", { value: "365" }, "12 derniers mois"));
  const lockBtn = h("button", { type: "button", class: "ds-chip moi-sv-pinf", "aria-pressed": "false", title: "Seulement les souvenirs épinglés" }, h("span", { html: ic("lock", 13) }), "Épinglés");
  selOrig.addEventListener("change", () => { mf.origine = selOrig.value; memShown = 100; loadMemory(); });
  selKind.addEventListener("change", () => { mf.kind = selKind.value; memShown = 100; loadMemory(); });
  selPer.addEventListener("change", () => { mf.periode = selPer.value; memShown = 100; loadMemory(); });
  lockBtn.addEventListener("click", () => { mf.locked = !mf.locked; lockBtn.classList.toggle("is-on", mf.locked); lockBtn.setAttribute("aria-pressed", mf.locked ? "true" : "false"); memShown = 100; loadMemory(); });
  memBar.append(h("div", { class: "ds-tb-end moi-sv-filters" }, selOrig, selKind, selPer, lockBtn));
  const memCount = h("div", { class: "ds-meta moi-sv-count" });
  const memList = h("div", { class: "moi-sv-groups" }, ds.skeleton(4));
  const memImport = h("div", { class: "moi-sv-import" });
  const addIn = h("input", { class: "fld", type: "text", placeholder: "Un fait à retenir durablement…", "aria-label": "Un fait à retenir durablement" });
  const addBtn = ds.action({ label: "Retenir", primary: true, onClick: async () => { const t = addIn.value.trim(); if (!t) { addIn.focus(); return; } try { const r = await api.post("/api/memory/add", { text: t }); if (r && r.item) { addIn.value = ""; ctx.toast("Fait retenu."); } else ctx.toast("Déjà en mémoire (ou mémoire coupée) : rien d'ajouté."); loadMemory(); } catch (e) { ctx.toast("Ajout impossible.", true); } } });
  addIn.addEventListener("keydown", (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter") { e.preventDefault(); addBtn.click(); } });
  const fileIn = h("input", { type: "file", accept: ".json,application/json", hidden: true });
  const download = (content, mime, filename) => { const a = document.createElement("a"); a.href = URL.createObjectURL(new Blob([content], { type: mime })); a.download = filename; document.body.append(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 4000); };
  const exportAs = async (fmt) => {
    try { const j = await api.get("/api/memory/export?format=" + fmt); if (!j || typeof j.content !== "string") throw new Error("réponse vide du moteur"); download(j.content, j.mime || "text/plain", j.filename || ("nova-memoire." + fmt)); const n = Number(j.count) || 0; ctx.toast("Export prêt : " + (j.filename || fmt) + " (" + plural(n, "fait", "faits") + ")."); }
    catch (e) { ctx.toast("Export impossible : " + String((e && e.message) || e), true); }
  };
  fileIn.addEventListener("change", () => {
    const f = fileIn.files && fileIn.files[0]; fileIn.value = "";
    if (!f) return;
    const rd = new FileReader();
    rd.onload = () => previewImport(String(rd.result || ""), f.name);
    rd.onerror = () => ctx.toast("Fichier illisible.", true);
    rd.readAsText(f);
  });
  async function previewImport(text, name) {
    memImport.replaceChildren(ds.skeleton(2));
    try {
      const j = await api.post("/api/memory/import", { data: text, apply: false });
      const nouveaux = arrOf(j, "nouveaux");
      const nN = Number(j && j.nouveaux_n) || nouveaux.length;
      const go = ds.action({ label: nN ? "Importer " + plural(nN, "fait", "faits") : "Rien à importer", primary: true, disabled: !nN, onClick: async () => {
        go.disabled = true;
        try { const r = await api.post("/api/memory/import", { data: text, apply: true }); const a = Number(r && r.added) || 0; ctx.toast(plural(a, "fait importé", "faits importés") + "."); memImport.replaceChildren(); loadMemory(); }
        catch (e) { go.disabled = false; ctx.toast("Import impossible : " + String((e && e.message) || e), true); }
      } });
      const no = ds.action({ label: "Annuler", onClick: () => memImport.replaceChildren() });
      const refs = arrOf(j, "refuses");
      memImport.replaceChildren(ds.card({ class: "moi-sv-imp-card", title: "Aperçu de l'import — " + String(name || "fichier") },
        h("div", { class: "ds-meta" }, [plural(Number(j && j.lus) || 0, "lu", "lus"), plural(nN, "nouveau", "nouveaux"), plural(Number(j && j.doublons_n) || 0, "doublon écarté", "doublons écartés"), plural(refs.length, "refusé", "refusés"), plural(Number(j && j.invalides) || 0, "illisible", "illisibles")].join(" · ")),
        nouveaux.length ? h("ul", { class: "moi-sv-imp-list" }, ...nouveaux.slice(0, 25).map((n) => h("li", {}, maskText(String(n.text || "")) + (n.kind ? " — " + n.kind : "")))) : null,
        nouveaux.length > 25 ? h("div", { class: "ds-meta" }, "… et " + (nN - 25) + " autres.") : null,
        refs.length ? h("div", { class: "ds-meta" }, "Refusés : " + refs.slice(0, 5).map((r) => "« " + maskText(String(r.text || "")) + " » (" + String(r.raison || "") + ")").join(" · ")) : null,
        h("div", { class: "moi-sv-btns" }, go, no)));
    } catch (e) { memImport.replaceChildren(ds.errorBox({ title: "Import refusé", cause: String((e && e.message) || e), retry: () => previewImport(text, name) })); }
  }
  memSec.querySelector(".ds-section-head").append(h("div", { class: "ds-actions" },
    ds.action({ label: "Markdown", icon: "download", ghost: true, tip: "Exporter toute la mémoire en Markdown", onClick: () => exportAs("md") }),
    ds.action({ label: "JSON", icon: "download", ghost: true, tip: "Exporter toute la mémoire en JSON", onClick: () => exportAs("json") }),
    ds.action({ label: "Importer…", icon: "plus", ghost: true, tip: "Importer un JSON (aperçu avant fusion)", onClick: () => fileIn.click() }), fileIn));
  memSec.body.append(memBar, h("div", { class: "moi-sv-add" }, addIn, addBtn), memCount, memImport, memList);

  const openGroups = {}; GROUPS.forEach((g) => { openGroups[g.id] = g.open; });
  function factRow(m) {
    const locked = m.locked === true;
    const shown = maskText(String(m.text || ""));
    const txt = h("div", { class: "moi-sv-txt", title: "Cliquer pour modifier" }, shown);
    const more = h("button", { type: "button", class: "moi-sv-more", hidden: true }, "lire la suite");
    more.addEventListener("click", (e) => { e.stopPropagation(); const on = !txt.classList.contains("is-full"); txt.classList.toggle("is-full", on); more.textContent = on ? "réduire" : "lire la suite"; });
    const metaBits = [fmtDate(m.ts), String(m.origine || m.source || ""), m.kind === "profil" ? "profil" : "", m.forgiven ? "exclu du contexte (ancien Pardon)" : "", m.edited ? "modifié " + fmtDate(m.edited) : "", Number(m.versions) > 1 ? m.versions + " versions" : ""].filter(Boolean);
    const meta = h("div", { class: "ds-row-meta moi-sv-meta" }, locked ? h("span", { class: "moi-sv-pin", title: "Épinglé : n'expire pas et ne s'oublie qu'après désépinglage", html: ic("lock", 12) }) : null, metaBits.join(" · "));
    const main = h("div", { class: "ds-row-main" }, txt, h("div", { class: "moi-sv-foot" }, meta, more));
    const acts = h("div", { class: "ds-row-actions" });
    const rowEl = h("div", { class: "ds-row moi-sv-fact" + (locked ? " is-pinned" : "") }, main, acts);
    const extra = h("div", { class: "moi-sv-extra" });
    const wrap = h("div", { class: "moi-sv-item" }, rowEl, extra);
    requestAnimationFrame(() => { if (txt.scrollHeight > txt.clientHeight + 2) more.hidden = false; });
    const edit = () => {
      if (extra.querySelector("textarea")) return;
      const ta = h("textarea", { class: "fld moi-sv-edit", rows: "3", "aria-label": "Texte du fait" }); ta.value = String(m.text || "");
      const save = async () => {
        const nv = ta.value.trim(); if (!nv || nv === String(m.text || "")) { extra.replaceChildren(); return; }
        try { await api.post("/api/memory/fact/update", { id: m.id, text: nv, why: "correction dans Savoir" }); m.text = nv; txt.textContent = maskText(nv); extra.replaceChildren(); ctx.toast("Fait corrigé — vecteur recalculé, version gardée."); }
        catch (e) { ctx.toast("Correction impossible : " + String((e && e.message) || e), true); }
      };
      ta.addEventListener("keydown", (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); save(); } else if (e.key === "Escape") { e.preventDefault(); extra.replaceChildren(); } });
      extra.replaceChildren(ta, h("div", { class: "moi-sv-btns" }, ds.action({ label: "Enregistrer", primary: true, onClick: save }), ds.action({ label: "Annuler", onClick: () => extra.replaceChildren() }), h("span", { class: "ds-meta" }, "Entrée enregistre · Maj+Entrée nouvelle ligne · Échap annule")));
      try { ta.focus(); } catch (e) {}
    };
    txt.addEventListener("click", edit);
    const history = async () => {
      if (extra.querySelector(".moi-sv-hist")) { extra.replaceChildren(); return; }
      extra.replaceChildren(ds.skeleton(1));
      try {
        const j = await api.get("/api/memory/fact/history?id=" + encodeURIComponent(m.id));
        const vs = arrOf(j, "versions");
        const cur = String((j && j.current && j.current.text) || m.text || "");
        extra.replaceChildren(h("div", { class: "moi-sv-hist" },
          h("div", { class: "ds-h3" }, "Historique de ce fait"),
          ...(vs.length ? vs.map((v) => h("div", { class: "moi-sv-ver" },
            h("div", { class: "moi-sv-ver-main" },
              h("div", { class: "ds-meta" }, [fmtDate(v.ts), OP_LBL[v.op] || "", v.actor ? "par " + String(v.actor) : "", v.why ? String(v.why) : ""].filter(Boolean).join(" · ")),
              v.text ? h("div", { class: "moi-sv-ver-txt" }, maskText(String(v.text))) : null),
            v.text && v.text !== cur ? ds.action({ label: "Restaurer", icon: "undo", onClick: async () => { try { await api.post("/api/memory/fact/restore", { id: m.id, v: v.v }); ctx.toast("Version restaurée."); loadMemory(); } catch (e) { ctx.toast("Restauration impossible : " + String((e && e.message) || e), true); } } }) : null))
            : [ds.empty({ compact: true, icon: "time", text: "Aucune version journalisée : ce fait date d'avant le journal des versions (24/10). Sa prochaine modification ouvrira son historique." })])));
      } catch (e) { extra.replaceChildren(ds.errorBox({ cause: "Le moteur n'a pas renvoyé l'historique.", retry: history })); }
    };
    const toggleLock = async () => {
      try { await api.post("/api/memory/fact/update", { id: m.id, locked: !locked }); ctx.toast(locked ? "Souvenir désépinglé." : "Souvenir épinglé : il n'expire plus et ne s'oublie qu'après désépinglage."); loadMemory(); }
      catch (e) { ctx.toast("Épinglage impossible : " + String((e && e.message) || e), true); }
    };
    const idle = () => { rowEl.classList.remove("is-selected"); acts.replaceChildren(
      ds.action({ icon: "note", tip: "Modifier", onClick: edit }),
      ds.action({ icon: "lock", tip: locked ? "Désépingler" : "Épingler (protège de l'expiration et de l'oubli)", onClick: toggleLock }),
      ds.action({ icon: "time", tip: "Historique et versions", onClick: history }),
      ds.action({ icon: "trash", tip: locked ? "Désépingle d'abord pour oublier" : "Oublier pour de bon", disabled: locked, onClick: ask })); };
    const ask = () => { rowEl.classList.add("is-selected"); acts.replaceChildren(
      h("span", { class: "ds-meta moi-sv-confirm" }, "Effacer pour de bon ?"),
      ds.action({ label: "Oublier", danger: true, onClick: async () => { try { await api.post("/api/memory/fact/forget", { id: m.id, confirm: true, why: "oubli dans Savoir" }); ctx.toast("Fait oublié : donnée, vecteur, versions et provenances effacés."); wrap.remove(); loadMemory(); } catch (e) { ctx.toast("Oubli impossible : " + String((e && e.message) || e), true); idle(); } } }),
      ds.action({ label: "Garder", onClick: idle })); };
    idle();
    return wrap;
  }

  async function loadMemory() {
    const qs = new URLSearchParams();
    if (mf.q) qs.set("q", mf.q);
    if (mf.origine) qs.set("origine", mf.origine);
    if (mf.kind) qs.set("kind", mf.kind);
    if (mf.locked) qs.set("locked", "1");
    if (mf.periode) { const d = new Date(Date.now() - Number(mf.periode) * 86400000); qs.set("since", d.toISOString().slice(0, 10)); }
    try {
      const j = await api.get("/api/memory/facts" + (qs.toString() ? "?" + qs.toString() : ""));
      if (dead) return;
      const items = arrOf(j, "items");
      const c = (j && j.counts) || {};
      const total = Number(c.total) || 0;
      const origs = arrOf(j, "origines");
      const curO = selOrig.value;
      selOrig.replaceChildren(h("option", { value: "" }, "Toutes origines"), ...origs.map((o) => h("option", { value: String(o) }, String(o))));
      selOrig.value = origs.includes(curO) ? curO : "";
      const filtered = !!(mf.q || mf.origine || mf.kind || mf.locked || mf.periode);
      const matched = Number(j && j.matched) || items.length;
      setCnt(memSec, total || "");
      memCount.replaceChildren(...[
        total ? h("span", {}, [plural(Number(c.profil) || 0, "profil", "profils"), plural(Number(c.contexte) || 0, "contexte", "contextes"), plural(Number(c.verrouilles) || 0, "épinglé", "épinglés"), Number(c.exclus) ? plural(c.exclus, "exclu du contexte", "exclus du contexte") : "", plural(Number(c.versions) || 0, "version journalisée", "versions journalisées")].filter(Boolean).join(" · ")) : null,
        filtered ? h("span", { class: "moi-sv-match" }, plural(matched, "correspond", "correspondent") + " aux filtres") : null,
        j && j.off ? ds.pill("Mémoire coupée — rien n'est injecté ni retenu", "warn") : null].filter(Boolean));
      const shown = items.slice(0, memShown);
      if (!shown.length) {
        memList.replaceChildren(ds.empty({ icon: "know", text: filtered ? "Aucun souvenir ne correspond à ces filtres." : "Aucun fait retenu pour le moment — écris-en un ci-dessus, ou laisse Nova distiller tes conversations.", action: filtered ? { label: "Effacer les filtres", ghost: true, onClick: () => { mf.q = ""; mf.origine = ""; mf.kind = ""; mf.locked = false; mf.periode = ""; selOrig.value = selKind.value = selPer.value = ""; lockBtn.classList.remove("is-on"); if (memBar.input) memBar.input.value = ""; memBar.querySelector(".ds-search").classList.remove("has-q"); loadMemory(); } } : { label: "Écrire un fait", ghost: true, onClick: () => addIn.focus() } }));
        return;
      }
      const by = {}; GROUPS.forEach((g) => { by[g.id] = []; });
      for (const m of shown) by[groupOf(m)].push(m);
      memList.replaceChildren(...GROUPS.filter((g) => by[g.id].length).map((g) => {
        const det = h("details", { class: "moi-sv-grp", open: (filtered && mf.q) || openGroups[g.id] ? true : null },
          h("summary", { class: "moi-sv-grp-h" }, h("span", { class: "ds-h3" }, g.label), h("span", { class: "ds-count" }, String(by[g.id].length))),
          h("div", { class: "ds-list" }, ...by[g.id].map(factRow)));
        det.addEventListener("toggle", () => { openGroups[g.id] = det.open; });
        return det;
      }));
      if (items.length > shown.length) memList.append(h("div", { class: "moi-sv-pager" }, ds.action({ label: "Afficher 100 de plus (" + (items.length - shown.length) + " restants)", onClick: () => { memShown += 100; loadMemory(); } })));
    } catch (e) { if (!dead) memList.replaceChildren(ds.errorBox({ cause: "Le moteur n'a pas renvoyé la mémoire.", retry: loadMemory })); }
  }
  /* Skills — les méthodes de la maison (directive d'Ahadi, 20/10/2026) : GET /api/skills (index), GET
     /api/skills/content (le SKILL.md), POST /api/skills/save (édition → le moteur reconstruit l'index). */
  const skillEditor = h("div", { class: "moi-sv-skill-ed" });
  async function loadSkills() {
    try {
      const j = await api.get("/api/skills");
      if (dead) return;
      const items = arrOf(j, "items");
      setCnt(skillsSec, items.length || "");
      skillsSec.body.replaceChildren(
        h("p", { class: "ds-meta moi-sv-lead" }, "Nova charge un skill quand la tâche correspond à son déclencheur."),
        items.length ? h("div", { class: "ds-list" }, ...items.map((sk) => ds.row({ lead: "book", title: String(sk.title || sk.name), meta: sk.trigger ? "Quand : " + String(sk.trigger) : String(sk.description || sk.desc || "") || null, actions: [{ label: "Ouvrir", onClick: () => openSkill(sk) }], onOpen: () => openSkill(sk) })))
          : ds.empty({ compact: true, icon: "book", text: "Aucun skill installé pour le moment." }),
        skillEditor);
    } catch (e) { if (!dead) skillsSec.body.replaceChildren(ds.errorBox({ cause: "Le moteur n'a pas renvoyé les skills.", retry: loadSkills })); }
  }
  async function openSkill(sk) {
    skillEditor.replaceChildren(ds.skeleton(2));
    try {
      const j = await api.get("/api/skills/content?name=" + encodeURIComponent(sk.name));
      if (dead) return;
      /* LOT1-FIX m17 : le moteur répond l'erreur en HTTP 200 ({error:"skill inconnu"}). */
      if (j && j.error) throw new Error(String(j.error));
      const ta = h("textarea", { class: "fld fld-area moi-sv-skill-ta", spellcheck: "false", "aria-label": "Contenu du skill" });
      ta.value = String((j && j.content) || "");
      skillEditor.replaceChildren(ds.card({ title: String(sk.title || sk.name) },
        h("div", { class: "ds-meta" }, "Méthode complète — l'enregistrer met à jour l'index de Nova."),
        ta,
        h("div", { class: "moi-sv-btns" },
          ds.action({ label: "Enregistrer", primary: true, onClick: async () => { try { const r = await api.post("/api/skills/save", { name: sk.name, content: ta.value }); if (r && r.ok) { ctx.toast("Skill enregistré — Nova l'appliquera dès la prochaine tâche."); loadSkills(); } else ctx.toast("Enregistrement refusé par le moteur.", true); } catch (e) { ctx.toast("Enregistrement impossible.", true); } } }),
          ds.action({ label: "Fermer", onClick: () => skillEditor.replaceChildren() }))));
      skillEditor.scrollIntoView({ block: "nearest" });
    } catch (e) { if (!dead) skillEditor.replaceChildren(ds.errorBox({ cause: "Contenu du skill indisponible : " + ((e && e.message) || e), retry: () => openSkill(sk) })); }
  }
  /* Rafraîchi au retour sur l'écran (module persistant), au plus toutes les 30 s ; une zone où Ahadi
     écrit (champ non vide ou focus) n'est jamais reconstruite. */
  const busy = (box) => !!box && (box.contains(document.activeElement) || [...box.querySelectorAll("input[type=text],textarea")].some((e) => e.value.trim()));
  let lastLoad = Date.now();
  loadStatus(); loadRecent(); loadMemory(); loadSkills();
  return {
    destroy() { dead = true; clearTimeout(qTimer); clearTimeout(mqTimer); },
    onShow() { if (Date.now() - lastLoad < 30000) return; lastLoad = Date.now(); loadStatus(); loadRecent(); if (!busy(memList) && !busy(memSec)) loadMemory(); if (!busy(skillsSec)) loadSkills(); },
  };
}
