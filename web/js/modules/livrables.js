/* Module Livrables — production documentaire CAFU intégrée (NOVA2-DOC).
   Génération réelle côté moteur (/api/livrables/generate) : PDF (gabarit maître → WebKit),
   DOCX/PPTX (CAFUOffice, charte verrouillée par empreinte), XLSX (OOXML direct), HTML.
   Aperçus : PDF et HTML affichés NATIVEMENT (iframe sur le fichier servi par le moteur) ;
   DOCX/PPTX/XLSX = première page QuickLook + aperçu structuré (contenu source), ÉTIQUETÉ.
   Historique : le dossier ~/cafu du moteur (GET /api/livrables) — titre, format, date, taille.
   Rien n'est jamais envoyé : ouvrir = app associée du Mac, télécharger = copie locale. */
/* V6 (25/10) — refonte premium (contrat conseil_24-10/V6_DESIGN.md) : le formulaire « Nouveau livrable »
   se replie derrière l'action primaire « + Nouveau livrable » de l'en-tête ; le schéma JSON et les codes
   couleur de la charte vivent dans le repli « Gabarit avancé » (plus dans l'aide visible) ; liste et aperçu
   en maître-détail (liste à gauche, aperçu à droite ; empilés dans le volet partagé), format en UNE
   pastille, Ouvrir / Télécharger en vrais boutons, recherche + puces de format, « N livrables ».
   Routes, charges utiles et retours d'état HONNÊTES du téléchargement (C-22) inchangés. */
import { truncWords, fmtDateFR, fmtTimeFR, fmtBytesFR, setFieldError } from "../core.js";
import * as ds from "../ds.js";
const arrOf = (j, ...keys) => { if (Array.isArray(j)) return j; for (const k of keys) if (j && Array.isArray(j[k])) return j[k]; return []; };
const fmtDT = (v) => { const s = fmtDateFR(v); return s ? s + " · " + fmtTimeFR(v) : String(v || "").slice(0, 16); };
const FMT_LABEL = { pdf: "PDF", docx: "Word", pptx: "PowerPoint", xlsx: "Excel", html: "HTML", webp: "Image", png: "Image", jpg: "Image", jpeg: "Image", m4a: "Audio", wav: "Audio", mp3: "Audio" };   /* 25/10 : épisodes du Podcast hebdo */
const fmtLabel = (f) => FMT_LABEL[String(f || "").toLowerCase()] || String(f || "Fichier").toUpperCase();
/* Aide visible : en clair, sans schéma ni code couleur. */
const HINTS = {
  pdf: "Texte libre : un titre par ligne, « - » pour les points, « À retenir : … » pour l'encadré. Rendu au gabarit maître CAFU, pied paginé.",
  html: "Texte libre, même gabarit maître que le PDF, en fichier HTML autonome.",
  docx: "Note Office CAFU : colle le gabarit préparé (voir « Gabarit avancé »). Charte verrouillée sur le Mac.",
  pptx: "Deck 16:9 : colle le gabarit préparé (voir « Gabarit avancé »). Audit de charte automatique.",
  xlsx: "Tableau simple : première ligne = en-têtes, cellules séparées par « ; ». Mis en forme à la charte CAFU.",
};
/* Détail technique, replié dans « Gabarit avancé ». */
const SCHEMAS = {
  pdf: "Gabarit JSON : {titre, encadre, sections:[{titre, texte, points}]}.",
  html: "Gabarit JSON : {titre, encadre, sections:[…]} — identique au PDF.",
  docx: "Gabarit JSON Office CAFU : {titre, sous_titre, contexte, auteur, encadre, sections:[{kicker, titre, texte, points, tableau:{entetes, lignes}}], limites:[…]}.",
  pptx: "Gabarit JSON Office CAFU : {titre, sous_titre, contexte, date, auteur, slides:[{kicker, titre, points:[4 max], takeaway, notes}]}.",
  xlsx: "Charte du tableau : en-têtes blancs sur fond #C00000, titre #D93226, police Aptos.",
};
const PRODUCE_LB = "Produire le livrable";

export async function mount(root, ctx) {
  const { api, h, ic } = ctx;
  let dead = false, selected = null, lastItems = [], listLimit = 40, query = "", fmtFilter = "all";

  /* ── En-tête : action primaire « Nouveau livrable » ───────────────── */
  const newBtn = ds.action({ label: "Nouveau livrable", icon: "plus", primary: true, onClick: () => openForm(!formCard.hidden ? false : true) });
  newBtn.setAttribute("aria-expanded", "false");
  root.append(ds.pageHead({ title: "Livrables", sub: "Documents CAFU produits par Nova — PDF, Word, PowerPoint, Excel, HTML. Rien n'est envoyé.", actions: [newBtn] }));

  /* ── Nouveau livrable (replié) ────────────────────────────────────── */
  const fmtSel = h("select", { id: "liv-fmt", class: "fld" },
    h("option", { value: "pdf" }, "PDF — note au gabarit maître"),
    h("option", { value: "docx" }, "Word — note Office CAFU"),
    h("option", { value: "pptx" }, "PowerPoint — deck 16:9"),
    h("option", { value: "xlsx" }, "Excel — tableau à la charte"),
    h("option", { value: "html" }, "HTML — gabarit maître autonome"));
  const titleIn = h("input", { type: "text", id: "liv-title", class: "fld", placeholder: "Ex. Note Sahel — semaine 43" });
  const bodyIn = h("textarea", { rows: "7", id: "liv-body", class: "fld fld-area", placeholder: "Écris ou colle ton contenu — un titre par ligne, « - » pour les points." });
  const hint = h("span", { class: "ds-meta" }, HINTS.pdf);
  const schema = h("p", { class: "ds-meta lv-schema" }, SCHEMAS.pdf);
  const jsonIn = h("textarea", { rows: "7", class: "fld fld-area lv-json", placeholder: "Colle ici le gabarit JSON…", "aria-label": "Gabarit JSON", spellcheck: "false" });
  const exBtn = ds.action({ label: "Insérer un exemple", ghost: true, onClick: () => { bodyIn.value = "Note d'exemple — Réunion Sahel\n- Point clé 1\n- Point clé 2\nÀ retenir : la phrase à retenir."; bodyIn.focus(); } });
  const genErrZone = h("div", {});
  const showGenErr = (msg) => genErrZone.replaceChildren(h("div", { class: "field-err", role: "alert" }, msg));
  fmtSel.addEventListener("change", () => { hint.textContent = HINTS[fmtSel.value] || ""; schema.textContent = SCHEMAS[fmtSel.value] || ""; genErrZone.replaceChildren(); });
  const parseJsonObject = (value) => {
    try { const parsed = JSON.parse(value); return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null; }
    catch (e) { return null; }
  };
  const cleanDocLine = (line) => String(line || "").replace(/^#{1,4}\s+/, "").replace(/\*\*/g, "").trim();
  function freeTextDoc(raw, explicitTitle) {
    const lines = String(raw || "").split("\n").map((x) => x.trim()).filter(Boolean);
    const sections = [];
    let current = null, callout = "", docTitle = String(explicitTitle || "").trim();
    const flush = () => {
      if (current && (current.titre || current.texte.length || current.points.length)) {
        const sec = { titre: current.titre, texte: current.texte.join("\n"), points: current.points };
        if (current.ordonne) sec.ordonne = true;
        sections.push(sec);
      }
      current = null;
    };
    const ensure = () => { if (!current) current = { titre: "", texte: [], points: [], ordonne: false }; return current; };
    lines.forEach((line, idx) => {
      if (!docTitle && idx === 0 && lines.length > 1) { docTitle = cleanDocLine(line); return; }
      if (docTitle && idx === 0 && cleanDocLine(line).toLowerCase() === docTitle.toLowerCase()) return;
      const heading = line.match(/^#{1,4}\s+(.+)$/);
      if (heading) { flush(); current = { titre: cleanDocLine(heading[1]), texte: [], points: [], ordonne: false }; return; }
      const call = line.match(/^(?:à retenir|a retenir|encadré|encadre|en bref|point d'attention)\s*:\s*(.+)$/i);
      if (call) { callout = [callout, call[1].trim()].filter(Boolean).join(" "); return; }
      const quote = line.match(/^>\s*(.+)$/);
      if (quote) { callout = [callout, quote[1].trim()].filter(Boolean).join(" "); return; }
      const numbered = line.match(/^\d+[.)]\s+(.+)$/);
      if (numbered) { const sec = ensure(); sec.points.push(numbered[1].trim()); sec.ordonne = true; return; }
      const bullet = line.match(/^[-•–*]\s+(.+)$/);
      if (bullet) { ensure().points.push(bullet[1].trim()); return; }
      const shortHeading = line.length <= 80 && !/[.]$/.test(line) && (/:$/.test(line) || line === line.toUpperCase()) && /[A-Za-zÀ-ÿ]/.test(line);
      if (shortHeading) { flush(); current = { titre: cleanDocLine(line).replace(/:$/, ""), texte: [], points: [], ordonne: false }; return; }
      ensure().texte.push(line.replace(/\*\*/g, ""));
    });
    flush();
    const doc = {};
    if (docTitle) doc.titre = docTitle;
    if (callout) doc.encadre = callout;
    if (sections.length) doc.sections = sections;
    return doc;
  }
  const genBtn = ds.action({ label: PRODUCE_LB, icon: "file", primary: true });
  const busyGen = (on) => { genBtn.disabled = on; const n = [...genBtn.childNodes].reverse().find((x) => x.nodeType === 3); if (n) n.textContent = on ? "Production…" : PRODUCE_LB; };
  const produced = async (r, format) => {
    ctx.toast("Livrable produit : " + fmtLabel(r.format || format) + ((r.titre || r.name) ? " — " + (r.titre || r.name) : ""));   // V5-N : jamais « undefined »
    openForm(false);
    titleIn.value = ""; bodyIn.value = ""; jsonIn.value = "";
    await loadList(r.name);
  };
  genBtn.addEventListener("click", async () => {
    const format = fmtSel.value, titre = titleIn.value.trim();
    const jsonRaw = jsonIn.value.trim();
    if (jsonRaw) {
      let jdoc = null;
      try { jdoc = JSON.parse(jsonRaw); } catch (e) { setFieldError(jsonIn, "Gabarit illisible : vérifie les accolades et les guillemets."); return; }
      setFieldError(jsonIn, null);
      if (!jdoc || typeof jdoc !== "object" || Array.isArray(jdoc)) { setFieldError(jsonIn, "Gabarit illisible : vérifie les accolades et les guillemets."); return; }
      busyGen(true); genErrZone.replaceChildren();
      try {
        const payload = { format };
        if (format === "pdf" || format === "html") { payload.doc = { ...jdoc }; if (titre && !payload.doc.titre && !payload.doc.title) payload.doc.titre = titre; }
        else if (format === "docx" || format === "pptx") payload.arg = jsonRaw;
        else { payload.texte = jsonRaw; if (titre) payload.titre = titre; }
        const r = await api.post("/api/livrables/generate", payload);
        if (dead) return;
        if (!r || r.ok !== true) throw new Error((r && r.error) || "génération refusée par le moteur");
        await produced(r, format);
      } catch (e) {
        if (!dead) showGenErr("Échec : " + String((e && e.message) || e).slice(0, 220));
      }
      busyGen(false);
      return;
    }
    const texte = bodyIn.value.trim();
    if (!texte) { showGenErr("Le contenu est vide — écris ou colle le contenu d'abord."); bodyIn.setAttribute("aria-invalid", "true"); bodyIn.focus(); return; }
    bodyIn.removeAttribute("aria-invalid");
    busyGen(true); genErrZone.replaceChildren();
    try {
      const payload = { format };
      if (format === "pdf" || format === "html") {
        if (texte.startsWith("{")) {
          const doc = parseJsonObject(texte);
          if (!doc) throw new Error("gabarit illisible : vérifie les accolades et les guillemets.");
          const hasContent = (Array.isArray(doc.sections) && doc.sections.length) || doc.encadre || doc["encadré"] || doc.callout || doc.texte || doc.body || doc.contenu || (Array.isArray(doc.points) && doc.points.length);
          if (!hasContent) throw new Error("gabarit valide mais sans contenu exploitable : ajoute des sections, du texte, des points ou un encadré.");
          payload.doc = { ...doc };
          if (titre && !payload.doc.titre && !payload.doc.title) payload.doc.titre = titre;
        } else {
          payload.doc = freeTextDoc(texte, titre);
          if (!payload.doc.sections && !payload.doc.encadre) throw new Error("contenu structuré vide : ajoute au moins un paragraphe, un point ou un encadré.");
        }
      }
      else if (format === "docx" || format === "pptx") payload.arg = texte;
      else { payload.texte = texte; if (titre) payload.titre = titre; }
      const r = await api.post("/api/livrables/generate", payload);
      if (dead) return;
      if (!r || r.ok !== true) throw new Error((r && r.error) || "génération refusée par le moteur");
      await produced(r, format);
    } catch (e) {
      if (!dead) showGenErr("Échec : " + String((e && e.message) || e).slice(0, 220));
    }
    busyGen(false);
  });
  const formCard = ds.card({ class: "lv-form" },
    h("div", { class: "ds-section-head" }, h("h2", { class: "ds-h2" }, "Nouveau livrable"),
      h("div", { class: "ds-actions" }, ds.action({ icon: "close", tip: "Fermer le formulaire", onClick: () => openForm(false) }))),
    h("div", { class: "lv-fields" },
      h("div", { class: "lv-field lv-field--fmt" }, h("label", { class: "lv-lb", for: "liv-fmt" }, "Format"), fmtSel),
      h("div", { class: "lv-field" }, h("label", { class: "lv-lb", for: "liv-title" }, "Titre"), titleIn)),
    h("div", { class: "lv-field" }, h("label", { class: "lv-lb", for: "liv-body" }, "Contenu"), bodyIn, hint),
    ds.fold("Gabarit avancé", [schema, jsonIn, h("p", { class: "ds-meta" }, "Rempli, ce gabarit remplace le contenu ci-dessus.")]),
    genErrZone,
    h("div", { class: "lv-form-foot" }, exBtn, h("div", { class: "ds-actions" }, ds.action({ label: "Annuler", ghost: true, onClick: () => openForm(false) }), genBtn)));
  formCard.hidden = true;
  root.append(formCard);
  function openForm(on) {
    formCard.hidden = !on;
    newBtn.setAttribute("aria-expanded", on ? "true" : "false");
    newBtn.classList.toggle("is-on", !!on);
    if (on) { try { formCard.scrollIntoView({ block: "nearest" }); titleIn.focus({ preventScroll: true }); } catch (e) {} }
  }
  formCard.addEventListener("keydown", (e) => { if (e.key === "Escape") { e.preventDefault(); openForm(false); newBtn.focus(); } });

  /* ── Produits par Nova : recherche, puces de format, maître-détail ── */
  const listBox = h("div", { class: "ds-list lv-list", role: "listbox", "aria-label": "Livrables" }, ds.skeleton(4));
  const countEl = h("div", { class: "ds-meta lv-count", "aria-live": "polite" });
  const prevBox = h("div", { class: "lv-prev" }, ds.empty({ icon: "file", text: "Sélectionne un livrable pour voir son aperçu ici." }));
  const chipsSlot = h("div", { class: "lv-chips" });
  const bar = ds.toolbar({ search: { placeholder: "Rechercher un livrable…", onInput: (v) => { query = v.toLowerCase(); listLimit = 40; renderList(); } } });
  bar.append(chipsSlot);
  const sec = ds.section({ title: "Produits par Nova", actions: [{ icon: "refresh", tip: "Actualiser", onClick: () => loadList(selected) }],
    body: [bar, h("div", { class: "lv-md" }, h("div", { class: "lv-master" }, countEl, listBox), prevBox)] });
  root.append(sec);

  function structuredView(data) {
    const box = h("div", { class: "lv-struct" });
    if (!data || typeof data !== "object") return box;
    const pointList = (pts, n) => h("ul", {}, ...pts.slice(0, n).map((p) => h("li", {}, truncWords(p, 160))));
    const block = (title, ...kids) => h("div", { class: "lv-sblock" }, h("div", { class: "ds-h3" }, title), ...kids);
    const secs = Array.isArray(data.sections) ? data.sections : [];
    for (const s of secs.slice(0, 10)) box.append(block(String(s.titre || s.kicker || "Section"), s.texte ? h("p", {}, truncWords(s.texte, 220)) : null, (Array.isArray(s.points) && s.points.length) ? pointList(s.points, 5) : null));
    const slides = Array.isArray(data.slides) ? data.slides : [];
    slides.slice(0, 10).forEach((s, i) => box.append(block("Diapositive " + (i + 1) + " — " + String(s.titre || ""), (Array.isArray(s.points) && s.points.length) ? pointList(s.points, 4) : null)));
    const feuilles = Array.isArray(data.feuilles) ? data.feuilles : (data.entetes ? [{ nom: "Feuille", entetes: data.entetes, lignes: data.lignes }] : []);
    for (const f of feuilles.slice(0, 4)) {
      const n = (f.lignes || []).length;
      box.append(block("Feuille — " + String(f.nom || "Données"), h("p", {}, "Colonnes : " + ((f.entetes || []).join(" · ") || "—") + " · " + n + (n > 1 ? " lignes" : " ligne"))));
    }
    if (data.encadre) box.prepend(h("p", { class: "lv-bluf" }, h("b", {}, "À retenir — "), truncWords(data.encadre, 260)));
    if (!box.childNodes.length) box.append(ds.empty({ icon: "file", compact: true, text: "Contenu source non archivé pour ce livrable." }));
    return box;
  }

  async function showPreview(it) {
    selected = it.name;
    for (const row of listBox.querySelectorAll(".ds-row[data-name]")) { const on = row.getAttribute("data-name") === it.name; row.classList.toggle("is-selected", on); row.setAttribute("aria-selected", on ? "true" : "false"); }
    const q = encodeURIComponent(it.name);
    /* Retour d'état du téléchargement (C-22) : la demande est signalée dès le clic,
       dans une zone adjacente en aria-live ET par toast — jamais « téléchargé »
       promis, puisque le sort réel du fichier appartient au délégué WKDownload. */
    const dlStatus = h("div", { class: "ds-meta lv-dl", "aria-live": "polite" });
    const dlLink = h("a", { class: "btn sm ds-btn-secondary lv-dl-btn", href: "/api/livrables/file?name=" + q + "&dl=1", download: "", role: "button" });
    dlLink.innerHTML = ic("download", 14); dlLink.append("Télécharger");
    dlLink.addEventListener("click", () => {
      dlStatus.textContent = "Téléchargement demandé — si rien ne se télécharge, utilise « Ouvrir » puis enregistre depuis l'app associée.";
      ctx.toast("Téléchargement demandé : " + (it.titre || it.name));
    });
    const openBtn = ds.action({ label: "Ouvrir", icon: "external", onClick: async () => { try { const j = await api.post("/api/livrables/open", { name: it.name }); if (j && j.ok === false) ctx.toast("Ouverture impossible : " + (j.error || "refusée par le moteur"), true); } catch (e) { ctx.toast("Ouverture impossible : " + ((e && e.message) || e), true); } } });
    const head = h("div", { class: "lv-prev-head" },
      h("div", { class: "lv-prev-t" },
        h("h3", { class: "ds-h3 lv-prev-title", title: String(it.titre || it.name) }, String(it.titre || it.name)),
        h("div", { class: "lv-prev-meta" }, ds.pill(fmtLabel(it.format), "neutral"), h("span", { class: "ds-meta", title: it.name }, [fmtDT(it.date), fmtBytesFR(it.size)].filter(Boolean).join(" · ")))),
      h("div", { class: "ds-actions" }, openBtn, dlLink));
    prevBox.replaceChildren(head, dlStatus);
    if (it.format === "pdf" || it.format === "html") {
      prevBox.append(h("div", { class: "ds-meta lv-prev-note" }, it.format === "pdf" ? "Aperçu natif — le PDF lui-même, tel qu'il partira." : "Aperçu natif — le document HTML au gabarit maître."),
        h("iframe", { class: "lv-frame", sandbox: "allow-same-origin allow-downloads", title: "Aperçu du livrable", src: "/api/livrables/file?name=" + q }));   /* 29/10 (audit P0-2) : même sandbox que core.js — scripts bloqués dans l'aperçu */
      return;
    }
    /* 25/10 : épisode audio (Podcast hebdo) — lecteur natif + script complet depuis le sidecar. */
    if (it.format === "m4a" || it.format === "wav" || it.format === "mp3" || it.preview === "audio") {
      const player = h("audio", { controls: "", preload: "metadata", class: "lv-audio", style: "width:100%;margin:8px 0", src: "/api/livrables/file?name=" + q });
      const scriptBox = h("div", { class: "lv-struct-wrap" });
      prevBox.append(h("div", { class: "ds-meta lv-prev-note" }, "Épisode audio — lecture locale, rien n'est publié."), player, scriptBox);
      try {
        const meta = await api.get("/api/livrables/meta?name=" + q);
        if (dead || selected !== it.name) return;
        const data = (meta && meta.data) || {};
        if (data.encadre) scriptBox.append(h("p", { class: "lv-bluf" }, h("b", {}, "En bref — "), String(data.encadre)));
        if (data.script) scriptBox.append(h("div", { class: "ds-h3" }, "Script"), h("div", { class: "lv-extract", style: "white-space:pre-wrap" }, String(data.script)));
        else scriptBox.append(ds.empty({ icon: "file", compact: true, text: "Script non archivé pour cet épisode." }));
      } catch (e) {
        scriptBox.append(ds.errorBox({ title: "Script injoignable", cause: "Le moteur n'a pas renvoyé le script de cet épisode.", retry: () => showPreview(it) }));
      }
      return;
    }
    const img = h("img", { class: "lv-thumb", alt: "Première page du livrable", src: "/api/livrables/thumb?name=" + q });
    img.addEventListener("error", () => img.replaceWith(ds.empty({ icon: "file", compact: true, text: "Vignette indisponible pour ce fichier — l'aperçu structuré ci-dessous reste valable." })));
    const struct = h("div", { class: "lv-struct-wrap" }, h("div", { class: "ds-meta lv-prev-note" }, "Aperçu structuré — contenu source du livrable (ce n'est pas le rendu paginé)."));
    prevBox.append(h("div", { class: "ds-meta lv-prev-note" }, "Première page (QuickLook)"), img, struct);
    try {
      const meta = await api.get("/api/livrables/meta?name=" + q);
      if (dead || selected !== it.name) return;
      struct.append(structuredView(meta && meta.data));
      if (meta && meta.texte_extrait) struct.append(h("div", { class: "lv-extract" }, String(meta.texte_extrait)));
    } catch (e) {
      struct.append(ds.errorBox({ title: "Contenu source injoignable", cause: "Le moteur n'a pas renvoyé le contenu de ce livrable.", retry: () => showPreview(it) }));
    }
  }

  function renderChips() {
    const counts = {};
    for (const it of lastItems) { const k = fmtLabel(it.format); counts[k] = (counts[k] || 0) + 1; }
    const keys = Object.keys(counts);
    if (fmtFilter !== "all" && !counts[fmtFilter]) fmtFilter = "all";
    if (keys.length < 2) { chipsSlot.replaceChildren(); return; }
    const order = ["PDF", "Word", "PowerPoint", "Excel", "HTML", "Image"];
    keys.sort((a, b) => (order.indexOf(a) + 1 || 99) - (order.indexOf(b) + 1 || 99) || a.localeCompare(b));
    chipsSlot.replaceChildren(ds.chips([{ id: "all", label: "Tous", n: lastItems.length, on: fmtFilter === "all" }, ...keys.map((k) => ({ id: k, label: k, n: counts[k], on: fmtFilter === k }))],
      (id) => { fmtFilter = id; listLimit = 40; renderList(); }));
  }
  function renderList() {
    const all = lastItems;
    const items = all.filter((it) => (fmtFilter === "all" || fmtLabel(it.format) === fmtFilter)
      && (!query || (String(it.titre || "") + " " + String(it.name || "")).toLowerCase().includes(query)));
    const shown = items.slice(0, listLimit);
    const n = items.length, plural = (k) => k + (k > 1 ? " livrables" : " livrable");
    countEl.textContent = !all.length ? "" : n === all.length ? plural(n) : plural(n) + " sur " + all.length;
    if (!all.length) {
      listBox.replaceChildren(ds.empty({ icon: "file", text: "Aucun livrable pour l'instant — produis-en un, ou demande au chat : « rédige une note CAFU sur… », « fais un deck ».", action: { label: "Nouveau livrable", icon: "plus", onClick: () => openForm(true) } }));
      prevBox.hidden = true;
      return;
    }
    prevBox.hidden = false;
    listBox.replaceChildren(
      ...(shown.length ? shown.map((it) => {
        const r = ds.row({ lead: "file", title: String(it.titre || it.name), tip: String(it.titre || it.name),
          meta: [fmtDT(it.date), fmtBytesFR(it.size)].filter(Boolean).join(" · "),
          side: ds.pill(fmtLabel(it.format), "neutral"), selected: selected === it.name, onOpen: () => showPreview(it) });
        r.setAttribute("data-name", it.name); r.setAttribute("role", "option"); r.setAttribute("aria-selected", selected === it.name ? "true" : "false");
        return r;
      }) : [ds.empty({ icon: "search", compact: true, text: "Aucun livrable ne correspond.", action: { label: "Tout afficher", ghost: true, onClick: () => { query = ""; fmtFilter = "all"; if (bar.input) { bar.input.value = ""; bar.input.dispatchEvent(new Event("input")); } renderChips(); renderList(); } } })]),
      ...(items.length > listLimit ? [ds.action({ label: "Afficher " + Math.min(40, items.length - listLimit) + " de plus", ghost: true, onClick: () => { listLimit += 40; renderList(); } })] : []));
  }
  /* Flèches haut/bas dans la liste : sélection au clavier (Entrée/Espace = ouvrir, déjà fourni par ds.row). */
  listBox.addEventListener("keydown", (e) => {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
    const rows = [...listBox.querySelectorAll(".ds-row[data-name]")]; const i = rows.indexOf(document.activeElement); if (i < 0) return;
    const n = rows[Math.max(0, Math.min(rows.length - 1, i + (e.key === "ArrowDown" ? 1 : -1)))]; e.preventDefault(); n.focus(); n.click();
  });

  async function loadList(focusName) {
    try {
      const j = await api.get("/api/livrables");
      if (dead) return;
      lastItems = arrOf(j, "items");
      const cnt = sec.querySelector(".ds-section-head > .ds-count");
      if (cnt) cnt.textContent = String(lastItems.length); else { const c = h("span", { class: "ds-count" }, String(lastItems.length)); sec.querySelector(".ds-section-head > .ds-h2").after(c); }
      renderChips();
      renderList();
      const focus = focusName || (() => { try { const v = sessionStorage.getItem("nova2_livrable_focus"); if (v) sessionStorage.removeItem("nova2_livrable_focus"); return v; } catch { return null; } })();
      const target = lastItems.find((i) => i.name === focus) || lastItems.find((i) => i.name === selected) || lastItems[0];
      if (target) showPreview(target);
    } catch (e) {
      if (!dead) listBox.replaceChildren(ds.errorBox({ title: "Historique injoignable", cause: "Le moteur n'a pas renvoyé la liste des livrables.", retry: () => loadList() }));
    }
  }
  /* FIX-WEB : rafraîchi au retour sur l'écran (module persistant), au plus toutes les 30 s. */
  let lastLoad = Date.now();
  loadList();
  return {
    destroy() { dead = true; },
    onShow() { if (Date.now() - lastLoad < 30000) return; lastLoad = Date.now(); loadList(); },
  };
}
