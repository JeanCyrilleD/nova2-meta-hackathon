/* Module Âme — le compartiment « Mémoire & Âme » de Nova 1, restauré sur Ame.swift :
   les documents d'âme (GET/POST /api/ame/doc : pack, registre, valeurs, relations, laisser,
   plans, reves, pensee, corps), le Miroir (GET /api/ame/stats), le Gardien du corps
   (GET /api/ame/corps + compagnon de charge GET /api/charge, POST /api/charge/reglage :
   signaux HONNÊTES, jamais un « état de fatigue » inventé), la mémoire de l'âme
   (GET /api/ame/memoire) avec Pardon par fait (POST /api/ame/pardon), les Rêves de la nuit
   (GET /api/reves, POST /api/reves/decider|lancer), la Boucle fermée (GET /api/boucle,
   /api/decision/log, /api/journal ; POST /api/boucle/rediger), l'auto-évaluation et le
   registre des manquements (API Notes du moteur, kinds « autoeval » / « manquement »),
   les compétences (GET /api/ame/skills, POST /api/ame/skills/save), le Chef d'orchestre
   (POST /api/ame/llm {kind:"plan"} → POST /api/ame/orchestre/run → GET …/run?id=) et la
   Transmission (POST /api/ame/llm {kind:"pensee"}, POST /api/ame/heritage).
   V6 (25/10/2026, contrat conseil_24-10/V6_DESIGN.md) : UNE page à la fois. La navigation
   latérale (groupée, état actif net) remplace la longue page à ancres où le Chef
   d'orchestre coiffait tout ; chaque rubrique a son en-tête (titre + une phrase + actions),
   son état vide qui dit quoi faire, ses actions. Documents d'âme : six onglets .ds-tabs
   (Pensée → Transmission, Rêves → Rêves de la nuit, Corps → Gardien du corps), typographie
   de lecture (≤ 72 ch, échelle H1/H2/H3 du système), sommaire en pleine largeur, provenance
   technique repliée. Volet étroit : la navigation devient une liste déroulante. */
import { md, ligneBrute, truncWords, fmtDateFR, etatLabel } from "../core.js";
import * as ds from "../ds.js";

const arrOf = (j, ...keys) => { if (Array.isArray(j)) return j; for (const k of keys) if (j && Array.isArray(j[k])) return j[k]; return []; };
const fmtDate = (v) => {
  if (!v) return "";
  const d = new Date(typeof v === "number" ? v * (v < 1e12 ? 1000 : 1) : v);
  return isNaN(d) ? String(v).slice(0, 16) : fmtDateFR(d);
};
const plural = (n, one, many) => n + " " + (n > 1 ? (many || one + "s") : one);
/* Message d'erreur lisible : core.api préfixe « /api/… → 400 » — jamais montré tel quel. */
const errMsg = (e) => String((e && e.message) || e || "").replace(/^\/api\/\S+\s*→\s*\d+\s*:?\s*/, "").trim() || "le moteur n'a pas répondu";
/* Cerveaux : un identifiant moteur n'est jamais affiché brut. */
const BRAINS = { "spark-1.3": "Muse Spark 1.3", "spark-1.2": "Muse Spark 1.2", "wonder-1.0": "Muse Wonder 1.0", "spark-open-baseten": "Muse Spark Open (Baseten)", "spark-open-hf": "Muse Spark Open (Hugging Face)", "muse-code": "Muse Code" };
const brainName = (b) => { const s = String(b || ""); return BRAINS[s] || s.replace(/[-_](direct|cloud|local)$/i, "").replace(/[-_]+/g, " ").replace(/^\w/, (c) => c.toUpperCase()); };
const tildify = (p) => String(p || "").replace(/^\/Users\/[^/]+/, "~");
const niceSkill = (n) => { const s = String(n || "compétence").replace(/[-_]+/g, " ").trim(); return s.charAt(0).toUpperCase() + s.slice(1); };

/* Rubriques — groupées ; l'ordre est celui de la navigation. */
const NAV = [
  [null, [["orchestre", "Chef d'orchestre"]]],
  ["Identité", [["documents", "Documents d'âme"], ["transmission", "Transmission"], ["competences", "Compétences"]]],
  ["Toi", [["corps", "Gardien du corps"], ["miroir", "Miroir"], ["reves", "Rêves de la nuit"], ["memoire", "Mémoire & Pardon"]]],
  ["Progrès", [["boucle", "Boucle fermée"], ["evaluation", "Auto-évaluation"], ["manquements", "Registre des manquements"]]],
];
const SUBS = {
  orchestre: "Une intention devient un plan, puis le moteur l'exécute en lecture seule.",
  documents: "Les textes qui disent qui est Nova et ce qui compte pour toi.",
  transmission: "Ta manière de penser, mise en mots et emportable.",
  competences: "Des savoir-faire écrits que Nova applique à la lettre.",
  corps: "Les signaux bruts du Mac sur ton rythme — jamais un diagnostic.",
  miroir: "Tes rythmes d'écriture, tels que tes messages à Nova les montrent.",
  reves: "Chaque nuit, Nova propose ce qu'elle retiendrait de ta journée. Rien n'entre sans toi.",
  memoire: "Les faits que Nova garde de toi. Pardonner efface un fait pour de bon.",
  boucle: "Chaque écart devient une leçon datée, relue ensuite — jamais une excuse.",
  evaluation: "Ce que le moteur mesure chaque semaine, et la note sur les dix axes de la maison.",
  manquements: "Ce qui a été raté, et la règle qui en sort.",
};
/* Documents d'âme affichés en onglets (≤ 6). Pensée vit dans Transmission, Rêves dans
   « Rêves de la nuit », Corps dans « Gardien du corps ». */
const DOCS = [
  { id: "pack", label: "Pack d'âme", kind: "text", desc: "Qui est Nova : identité, voix, philosophie, charte et routines. Tes amendements priment sur le texte transmis.",
    prov: "Transmis par Muse, ce texte nourrit les instructions du chat, de l'agent et des Éclats. Sans amendement, c'est le texte transmis qui fait foi, mot pour mot ; tes amendements sont relus à chaque conversation. Détail technique : AmePack.swift → Persona.system, amendements dans ame_pack.json.",
    saved: "Pack amendé — actif dès la prochaine conversation." },
  { id: "registre", label: "Registre", kind: "text", desc: "Comment Nova converse : longueur des réponses, tics interdits, art de reprendre le fil.",
    prov: "Ajouté aux instructions du chat après l'âme, il prime sur les habitudes de mise en forme. Les Éclats, le Conseil et l'agent ne le reçoivent pas. Sans amendement, c'est le registre transmis qui fait foi. Détail technique : RegistreConversation, amendements dans ame_registre.json.",
    saved: "Registre amendé — actif dès le prochain tour de conversation." },
  { id: "valeurs", label: "Valeurs", kind: "list", switchable: true, desc: "Ton contrat de valeurs : chaque ligne active part dans chaque réponse de Nova." },
  { id: "relations", label: "Relations", kind: "list", desc: "Les personnes qui comptent et ce que tu veux garder en tête à leur sujet." },
  { id: "laisser", label: "Ce qu'on laisse", kind: "list", switchable: true, desc: "Ce que tu as décidé de laisser derrière toi — les lignes actives sont relues par le rituel du soir." },
  { id: "plans", label: "Plans", kind: "list", desc: "Tes plans, tels que tu les écris." },
];

/* Titres en CAPITALES (« PACK D'ÂME DE NOVA ») → casse de phrase ; un mot écrit ailleurs dans le
   texte avec une majuscule (nom propre) ou en sigle garde cette graphie. */
function tameHeadings(root) {
  const clone = root.cloneNode(true);
  clone.querySelectorAll("h1, h2, h3, h4").forEach((x) => x.remove());
  const txt = clone.textContent || "";
  const known = new Map();
  for (const w of txt.match(/[\p{L}][\p{L}'’-]*/gu) || []) {
    if (w === w.toUpperCase() && w.length > 1 && w.length <= 5 && /\p{Lu}/u.test(w)) { if (!known.has(w.toLowerCase())) known.set(w.toLowerCase(), w); }
    else if (/^\p{Lu}\p{Ll}/u.test(w)) known.set(w.toLowerCase(), w);
  }
  root.querySelectorAll("h1, h2, h3, h4").forEach((hd) => {
    const t = hd.textContent || "";
    const letters = t.replace(/[^\p{L}]/gu, "");
    if (letters.length < 4 || letters !== letters.toUpperCase()) return;
    let first = true;
    hd.textContent = t.replace(/[\p{L}][\p{L}'’-]*/gu, (w) => {
      const lw = w.toLowerCase();
      const k = known.get(lw);
      const out = k && k !== k.toUpperCase() ? k : (k && w.length <= 5 ? k : lw);
      if (first) { first = false; return out.charAt(0).toUpperCase() + out.slice(1); }
      return out;
    });
  });
}

export async function mount(root, ctx) {
  const { api, h, ic } = ctx;
  let dead = false;
  const cleanups = [];
  root.classList.add("mod--wide", "moi-ame");
  const errBox = (cause, retry) => ds.errorBox({ cause, retry });
  const subHead = (id, actions) => {
    const label = NAV.flatMap((g) => g[1]).find((x) => x[0] === id)[1];
    const head = h("header", { class: "ds-page-head moi-ame-ph" },
      h("div", { class: "ds-ph-txt" }, h("h2", { class: "ds-h2" }, label), h("p", { class: "ds-sub moi-ame-ph-sub" }, SUBS[id] || "")));
    const acts = h("div", { class: "ds-actions" });
    head.append(acts);
    head.setActions = (list) => acts.replaceChildren(...[].concat(list || []).map((a) => ds.action(a)).filter(Boolean));
    if (actions) head.setActions(actions);
    return head;
  };
  /* Rendu « document » : md() puis typographie de lecture ; renvoie le nœud. */
  const docView = (text, cls = "") => { const el = h("div", { class: "moi-ame-doc " + cls, html: md(String(text || "")) }); try { tameHeadings(el); } catch (e) {} return el; };

  root.append(ds.pageHead({ title: "Âme", sub: "Ce que Nova sait de toi, ce qu'elle garde, ce qu'elle peut oublier" }));

  /* ── Navigation : liste groupée (large) / liste déroulante (volet étroit) ── */
  const nav = h("nav", { class: "moi-ame-nav", "aria-label": "Rubriques de l'Âme" });
  const pick = h("select", { class: "fld moi-ame-pick", "aria-label": "Rubrique de l'Âme" });
  const main = h("div", { class: "moi-ame-main" }, h("div", { class: "moi-ame-pickwrap" }, pick));
  const pages = {}, navBtns = {}, LOADERS = {}, started = new Set();
  for (const [group, items] of NAV) {
    const og = group ? h("optgroup", { label: group }) : pick;
    if (group) { nav.append(h("div", { class: "moi-ame-nav-g" }, group)); pick.append(og); }
    for (const [id, label] of items) {
      navBtns[id] = h("button", { type: "button", class: "moi-ame-nav-i", "data-nav": id, onclick: () => show(id) }, label);
      nav.append(navBtns[id]);
      og.append(h("option", { value: id }, label));
      pages[id] = h("section", { class: "moi-ame-page", "data-page": id, hidden: true, "aria-label": label });
      main.append(pages[id]);
    }
  }
  pick.addEventListener("change", () => show(pick.value));
  root.append(h("div", { class: "moi-ame-grid" }, nav, main));
  let current = null;
  function show(id) {
    if (!pages[id]) id = "documents";
    current = id;
    for (const k in pages) { const on = k === id; pages[k].hidden = !on; navBtns[k].classList.toggle("is-on", on); if (on) navBtns[k].setAttribute("aria-current", "page"); else navBtns[k].removeAttribute("aria-current"); }
    pick.value = id;
    try { localStorage.setItem("nova2_ame_page", id); } catch (e) {}
    if (!started.has(id)) { started.add(id); const f = LOADERS[id]; if (f) f(); }
    try { if (root.scrollTop > 0) root.scrollTo({ top: 0, behavior: "smooth" }); } catch (e) {}
  }

  /* ═══ Chef d'orchestre ═══════════════════════════════════════════════ */
  {
    const page = pages.orchestre;
    const orchIn = h("input", { class: "fld", type: "text", placeholder: "Une intention (ex. prépare ma journée de demain)…", "aria-label": "Intention à orchestrer" });
    const orchOut = h("div", { class: "moi-ame-orch-out" }, ds.empty({ icon: "sparkle", text: "Écris une intention : Nova te montre le plan, puis le moteur l'exécute en lecture seule avec les Éclats et les outils." }));
    const STEP = { "fait": ["Fait", "ok"], "échec": ["Échec", "danger"], "en cours": ["En cours", "warn"] };
    const orchBtn = ds.action({ label: "Orchestrer", primary: true, onClick: () => run() });
    let running = false;
    async function run() {
      const t = orchIn.value.trim();
      if (!t) { orchIn.focus(); return; }
      if (running) return;
      running = true; orchBtn.disabled = true;
      orchOut.replaceChildren(ds.skeleton(2));
      try {
        /* LOT1-FIX C3 : contrat moteur réel (Ame.swift). 1) Le PLAN vient de
           POST /api/ame/llm {kind:"plan", input} → {steps:[{titre,task}]} ;
           2) l'EXÉCUTION part en POST /api/ame/orchestre/run {goal, steps} → {id} ;
           3) le RÉSULTAT se sonde en GET /api/ame/orchestre/run?id= jusqu'à done==true. */
        const plan = await api.post("/api/ame/llm", { kind: "plan", input: t });
        if (dead) return;
        const steps = (plan && Array.isArray(plan.steps)) ? plan.steps.filter((s) => s && (s.titre || s.task)) : [];
        if (!steps.length) throw new Error("le moteur n'a produit aucune étape pour cette intention");
        const runR = await api.post("/api/ame/orchestre/run", { goal: t, steps });
        if (dead) return;
        const runId = runR && runR.id;
        if (!runId) throw new Error((runR && runR.error) || "le moteur n'a pas renvoyé d'identifiant d'exécution");
        let doneSeen = false;
        const renderRun = (st) => {
          const list = (st && Array.isArray(st.steps) && st.steps.length) ? st.steps : steps;
          const done = !!(st && st.done);
          const sec = ds.section({ title: "Plan", count: list.length, actions: [done ? ds.pill("Terminé", "ok") : ds.pill("En cours", "warn")] });
          sec.body.append(ds.card({ flush: true }, h("div", { class: "ds-list" }, list.map((s, i) => {
            const stt = STEP[s.status] || ["En attente", "neutral"];
            return ds.row({ lead: h("span", { class: "moi-ame-num" }, String(i + 1)), title: String(s.titre || "Étape"), meta: s.result ? truncWords(String(s.result), 240) : etatLabel(s.status || "attente", "en attente"), side: ds.pill(stt[0], stt[1]) });
          }))));
          const kids = [sec];
          if (done && st.synthese) kids.push(ds.section({ title: "Synthèse", body: ds.card({}, docView(st.synthese, "is-compact")) }));
          orchOut.replaceChildren(...kids);
        };
        renderRun({ steps });
        for (let n = 0; n < 40 && !dead; n++) {
          await new Promise((r) => setTimeout(r, 2500));
          if (dead) return;
          const st = await api.get("/api/ame/orchestre/run?id=" + encodeURIComponent(runId));
          if (dead) return;
          if (st && st.error) throw new Error(String(st.error));
          renderRun(st || {});
          if (st && st.done) { doneSeen = true; break; }
        }
        if (!doneSeen && !dead) orchOut.append(h("p", { class: "ds-meta" }, "L'exécution continue côté moteur — reviens ici pour la suite."));
      } catch (err) { if (!dead) orchOut.replaceChildren(errBox("Orchestre : " + errMsg(err), () => run())); }
      running = false; orchBtn.disabled = false;
    }
    orchIn.addEventListener("keydown", (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter") { e.preventDefault(); run(); } });
    page.append(subHead("orchestre"),
      ds.card({ class: "moi-ame-orch" }, h("div", { class: "moi-ame-inline" }, orchIn, orchBtn),
        h("p", { class: "ds-meta" }, "Le plan s'affiche avant toute exécution lourde. Rien n'est envoyé ni modifié sans ta carte.")),
      orchOut);
  }

  /* ═══ Éditeur de document-liste (valeurs, relations, laisser, plans, corps) ═══ */
  /* V5-P (bug n°2) : « valeurs » et « laisser » s'écrivent en {text, on, ts} — le moteur relit chaque
     ligne ACTIVE ; l'interrupteur règle « on ». Les lignes en texte nu restent lues (actives) et
     deviennent des objets au premier basculement. Les contacts suivis (objets {name, cadence…}) sont
     gérés par l'écran Relations : ici on les montre sans les modifier. */
  function listDoc(name, box, opts = {}) {
    const switchable = !!opts.switchable;
    const lineText = (it) => String(typeof it === "string" ? it : (it.text || it.nom || it.name || it.titre || ligneBrute(it)));
    const isOn = (it) => typeof it === "string" ? true : (it.on != null ? it.on !== false : it.actif !== false);
    const editable = (it) => typeof it === "string" || (it && typeof it === "object" && typeof it.text === "string");
    const isContact = (it) => it && typeof it === "object" && !it.text && (it.name || it.nom);
    async function load() {
      box.replaceChildren(ds.skeleton(3));
      let items;
      try { const j = await api.get("/api/ame/doc?name=" + encodeURIComponent(name)); if (dead) return; items = Array.isArray(j && j.data) ? j.data.filter((x) => x != null) : []; }
      catch (e) { if (!dead) box.replaceChildren(errBox("Document injoignable : " + errMsg(e) + ".", load)); return; }
      const save = async (arr, msg) => {
        try { const r = await api.post("/api/ame/doc", { name, data: arr }); if (r && r.error) throw new Error(r.error); if (msg) ctx.toast(msg); }
        catch (e) { ctx.toast("Enregistrement impossible : " + errMsg(e) + ".", true); }
        if (!dead) load();
      };
      const addIn = h("input", { class: "fld", type: "text", placeholder: opts.placeholder || "Ajouter une ligne…", "aria-label": "Nouvelle ligne" });
      const add = () => { const t = addIn.value.trim(); if (!t) { addIn.focus(); return; } save([...items, switchable ? { text: t, on: true, ts: new Date().toISOString() } : t], "Ligne ajoutée."); };
      addIn.addEventListener("keydown", (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter") { e.preventDefault(); add(); } });
      const rows = items.map((it, idx) => {
        const on = isOn(it);
        const txt = lineText(it);
        let rowEl = null;
        const setText = (v) => items.map((x, k) => k !== idx ? x : (typeof x === "string" ? v : { ...x, text: v }));
        const startEdit = () => {
          const inp = h("input", { class: "fld", type: "text", value: txt, "aria-label": "Modifier la ligne" });
          const ok = () => { const v = inp.value.trim(); if (!v || v === txt) { load(); return; } save(setText(v), "Ligne modifiée."); };
          inp.addEventListener("keydown", (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter") { e.preventDefault(); ok(); } if (e.key === "Escape") { e.preventDefault(); load(); } });
          rowEl.replaceWith(h("div", { class: "moi-ame-edrow" }, inp, ds.action({ label: "Enregistrer", primary: true, onClick: ok }), ds.action({ label: "Annuler", ghost: true, onClick: () => load() })));
          setTimeout(() => { try { inp.focus(); inp.select(); } catch (e) {} }, 30);
        };
        const askRemove = () => {
          const acts = rowEl.querySelector(".ds-row-actions");
          if (!acts) return;
          rowEl.classList.add("is-selected");
          acts.replaceChildren(h("span", { class: "ds-meta" }, "Retirer ?"),
            ds.action({ label: "Retirer", danger: true, onClick: () => save(items.filter((_, k) => k !== idx), "Ligne retirée.") }),
            ds.action({ label: "Garder", ghost: true, onClick: () => load() }));
        };
        let side = null, actions = [];
        if (switchable) {
          side = h("button", { type: "button", class: "switch", role: "switch", "aria-checked": on ? "true" : "false", title: on ? "Active — clique pour la mettre en pause" : "En pause — clique pour la réactiver", "aria-label": (on ? "Désactiver" : "Activer") + " : " + txt.slice(0, 60),
            onclick: (e) => { e.stopPropagation(); save(items.map((x, k) => { if (k !== idx) return x; const o = typeof x === "string" ? { text: x, ts: "" } : { ...x }; o.on = !isOn(x); delete o.actif; return o; }), on ? "Ligne en pause — elle ne part plus dans les instructions." : "Ligne réactivée."); } });
        } else if (it && typeof it === "object" && it.actif != null) side = ds.pill(it.actif ? "Active" : "Inactive", it.actif ? "ok" : "neutral");
        if (isContact(it)) {
          actions = [{ label: "Ouvrir Relations", ghost: true, onClick: () => { try { ctx.navigate("relations"); } catch (e) {} } }];
        } else if (editable(it)) {
          actions = [{ label: "Modifier", ghost: true, onClick: startEdit }, { icon: "trash", tip: "Retirer cette ligne", onClick: askRemove }];
        }
        rowEl = ds.row({ title: txt, meta: isContact(it) ? "Contact suivi — géré dans Relations" + (it.cadence ? " · tous les " + it.cadence + " j" : "") : (it && typeof it === "object" && it.ts ? "Ajoutée le " + fmtDate(it.ts) : null), side, actions });
        rowEl.classList.add("moi-ame-line");
        if (switchable && !on) rowEl.classList.add("is-off");
        if (switchable) rowEl.classList.add("has-switch");
        return rowEl;
      });
      const onCount = items.filter(isOn).length;
      const summary = switchable && items.length ? h("p", { class: "ds-meta moi-ame-listsum" }, plural(onCount, "ligne active", "lignes actives") + " sur " + items.length + (opts.onNote ? " — " + opts.onNote : "")) : null;
      box.replaceChildren(ds.card({ class: "moi-ame-listcard" },
        summary,
        items.length ? h("div", { class: "ds-list" }, rows) : ds.empty({ compact: true, icon: "note", text: opts.empty || "Rien d'écrit pour l'instant — ajoute la première ligne ci-dessous." }),
        h("div", { class: "moi-ame-inline moi-ame-add" }, addIn, ds.action({ label: "Ajouter", icon: "plus", onClick: add }))));
    }
    return load;
  }

  /* ═══ Lecteur/éditeur de document texte (pack, registre) ═══════════════ */
  function textDoc(d, box) {
    async function load() {
      box.replaceChildren(ds.skeleton(4));
      let text;
      try { const j = await api.get("/api/ame/doc?name=" + d.id); if (dead) return; const v = j && j.data; text = typeof v === "string" ? v : (v && typeof v.text === "string" ? v.text : ""); }
      catch (e) { if (!dead) box.replaceChildren(errBox("Document injoignable : " + errMsg(e) + ".", load)); return; }
      const reader = docView(text);
      const words = (text.match(/\S+/g) || []).length;
      /* Sommaire (pleine largeur) : les titres de niveau 2 du document. */
      const heads = [...reader.querySelectorAll("h2")];
      const toc = heads.length >= 3 ? h("nav", { class: "moi-ame-toc", "aria-label": "Sommaire du document" }, h("div", { class: "moi-ame-toc-t" }, "Sommaire"),
        ...heads.map((hd) => h("button", { type: "button", onclick: () => { try { hd.scrollIntoView({ behavior: "smooth", block: "start" }); } catch (e) {} } }, hd.textContent))) : null;
      const ta = h("textarea", { class: "fld fld-area moi-ame-src", rows: "22", spellcheck: "false", "aria-label": "Texte du document « " + d.label + " »" });
      ta.value = text;
      const view = h("div", { class: "moi-ame-docwrap" + (toc ? " has-toc" : "") }, reader, toc);
      const editZone = h("div", { class: "moi-ame-edit", hidden: true }, h("p", { class: "ds-meta" }, "Texte source (Markdown). Tes amendements priment sur le texte transmis."), ta);
      const bar = h("div", { class: "moi-ame-docbar" });
      const setMode = (editing) => {
        view.hidden = editing; editZone.hidden = !editing;
        bar.replaceChildren(h("span", { class: "ds-meta" }, editing ? "Modification en cours" : "≈ " + Math.max(1, Math.round(words / 220)) + " min de lecture · " + words.toLocaleString("fr-FR") + " mots"),
          h("span", { class: "ds-actions" }, ...(editing
            ? [ds.action({ label: "Annuler", ghost: true, onClick: () => { ta.value = text; setMode(false); } }),
               ds.action({ label: "Enregistrer", primary: true, onClick: async (e) => {
                 const b = e.currentTarget; b.disabled = true;
                 try { const r = await api.post("/api/ame/doc", { name: d.id, data: ta.value }); if (r && r.error) throw new Error(r.error); ctx.toast(d.saved); if (!dead) load(); }
                 catch (err) { ctx.toast("Enregistrement impossible : " + errMsg(err) + ".", true); b.disabled = false; }
               } })]
            : [ds.action({ label: "Modifier", onClick: () => { setMode(true); setTimeout(() => { try { ta.focus(); } catch (e) {} }, 30); } })])));
      };
      setMode(false);
      box.replaceChildren(ds.card({ class: "moi-ame-doccard" }, bar, view, editZone), ds.fold("D'où vient ce texte", h("p", { class: "ds-meta moi-ame-prov" }, d.prov)));
    }
    return load;
  }

  /* ═══ Documents d'âme ════════════════════════════════════════════════ */
  {
    const page = pages.documents;
    const descEl = h("p", { class: "ds-meta moi-ame-docdesc" });
    const docBox = h("div", {});
    let curDoc = "pack";
    try { const s = localStorage.getItem("nova2_ame_doc"); if (DOCS.some((x) => x.id === s)) curDoc = s; } catch (e) {}
    const openDoc = (id) => {
      curDoc = id;
      try { localStorage.setItem("nova2_ame_doc", id); } catch (e) {}
      const d = DOCS.find((x) => x.id === id);
      descEl.textContent = d.desc;
      const box = h("div", {});
      docBox.replaceChildren(box);
      const load = d.kind === "text" ? textDoc(d, box) : listDoc(d.id, box, { switchable: d.switchable, placeholder: "Ajouter une ligne à « " + d.label + " »…" });
      load();
    };
    const tabs = ds.tabs(DOCS.map((d) => ({ id: d.id, label: d.label, on: d.id === curDoc })), openDoc);
    tabs.setAttribute("aria-label", "Document d'âme");
    page.append(subHead("documents"), tabs, descEl, docBox);
    LOADERS.documents = () => openDoc(curDoc);
  }

  /* ═══ Transmission (n°24) ════════════════════════════════════════════
     « Ma manière de penser » : POST /api/ame/llm {kind:"pensee"} la génère, l'écran la range dans
     le document d'âme « pensee » ({text, updated}), POST /api/ame/heritage l'embarque dans le
     paquet portable (~/NOVA_ECHANGE, MANIERE_DE_PENSER.md). */
  {
    const page = pages.transmission;
    const head = subHead("transmission");
    const box = h("div", {});
    page.append(head, box);
    const exportPack = async (e) => {
      const b = e && e.currentTarget; if (b) b.disabled = true;
      try { const r = await api.post("/api/ame/heritage", {}); ctx.toast("Paquet de transmission prêt" + (r && r.path ? " : " + tildify(r.path) : " dans ~/NOVA_ECHANGE") + "."); }
      catch (err) { ctx.toast("Export impossible : " + errMsg(err) + ".", true); }
      if (b) b.disabled = false;
    };
    let gen = null;
    async function load() {
      box.replaceChildren(ds.skeleton(3));
      try {
        const j = await api.get("/api/ame/doc?name=pensee");
        if (dead) return;
        const data = j && j.data;
        const text = typeof data === "string" ? data : (data && data.text) || "";
        const updated = data && typeof data === "object" ? data.updated : null;
        gen = async (e) => {
          const b = e && e.currentTarget; if (b) b.disabled = true;
          box.prepend(h("p", { class: "ds-meta moi-ame-busy" }, "Génération en cours — le cerveau profond lit ta mémoire, tes valeurs et tes doctrines…"));
          try {
            const r = await api.post("/api/ame/llm", { kind: "pensee" });
            const t = (r && (r.text || r.md || r.result)) || "";
            if (!t) throw new Error((r && r.error) || "le moteur n'a rien renvoyé");
            await api.post("/api/ame/doc", { name: "pensee", data: { text: t, updated: new Date().toISOString() } });
            ctx.toast("« Ma manière de penser » est à jour.");
          } catch (err) { ctx.toast("Génération impossible : " + errMsg(err) + ".", true); }
          if (b) b.disabled = false;
          if (!dead) load();
        };
        head.setActions([{ label: "Exporter le paquet", icon: "download", tip: "Écrit le paquet de transmission dans le dossier NOVA_ECHANGE de ton Mac", onClick: exportPack },
          { label: text ? "Régénérer" : "Générer", primary: true, onClick: (e) => gen(e) }]);
        if (!text) {
          box.replaceChildren(ds.card({}, ds.empty({ icon: "brain", text: "« Ma manière de penser » n'existe pas encore. Nova peut la rédiger à partir de ta mémoire, de tes valeurs et de tes doctrines ; l'export le signale tant qu'elle manque.", action: { label: "Générer ma manière de penser", primary: true, onClick: (e) => gen(e) } })));
          return;
        }
        box.replaceChildren(
          h("div", { class: "moi-ame-state" }, ds.pill("Rédigée", "ok"), h("span", { class: "ds-meta" }, (updated ? "Mise à jour le " + fmtDate(updated) + " · " : "") + text.length.toLocaleString("fr-FR") + " caractères · embarquée telle quelle dans le paquet de transmission")),
          ds.card({ class: "moi-ame-doccard" }, h("div", { class: "moi-ame-docbar" }, h("h3", { class: "ds-h3" }, "Ma manière de penser"), h("span", { class: "ds-meta" }, "lecture seule — Régénérer pour la réécrire")), docView(text.slice(0, 12000))));
      } catch (e) { if (!dead) box.replaceChildren(errBox("Transmission injoignable : " + errMsg(e) + ".", load)); }
    }
    LOADERS.transmission = load;
  }

  /* ═══ Compétences (S4/C2) ════════════════════════════════════════════ */
  {
    const page = pages.competences;
    const head = subHead("competences");
    const editor = h("div", {});
    const box = h("div", {});
    page.append(head, editor, box);
    const openEditor = (sk) => {
      const nameIn = h("input", { class: "fld", type: "text", placeholder: "Nom (ex. revue hebdo)", "aria-label": "Nom de la compétence", value: sk ? niceSkill(sk.name) : null, disabled: !!sk });
      const ta = h("textarea", { class: "fld fld-area moi-ame-src", rows: "14", spellcheck: "false", "aria-label": "Instructions de la compétence", placeholder: "Les instructions, en Markdown — Nova les appliquera à la lettre." });
      ta.value = sk ? String(sk.body || "") : "";
      const err = h("div", {});
      const saveB = ds.action({ label: "Enregistrer", primary: true, onClick: async () => {
        const n = sk ? sk.name : nameIn.value.trim();
        if (!n) { err.replaceChildren(h("div", { class: "field-err", role: "alert" }, "Donne un nom à la compétence.")); nameIn.focus(); return; }
        if (!ta.value.trim()) { err.replaceChildren(h("div", { class: "field-err", role: "alert" }, "Écris au moins une instruction.")); ta.focus(); return; }
        saveB.disabled = true;
        try { const r = await api.post("/api/ame/skills/save", { name: n, body: ta.value }); if (r && r.error) throw new Error(r.error); ctx.toast(sk ? "Compétence enregistrée." : "Compétence créée."); editor.replaceChildren(); if (!dead) load(); }
        catch (e) { err.replaceChildren(h("div", { class: "field-err", role: "alert" }, "Enregistrement impossible : " + errMsg(e) + ".")); saveB.disabled = false; }
      } });
      editor.replaceChildren(ds.card({ class: "moi-ame-skilled", title: sk ? "Modifier « " + niceSkill(sk.name) + " »" : "Nouvelle compétence" },
        sk ? null : nameIn, ta, err,
        h("div", { class: "moi-ame-docbar is-foot" }, h("span", { class: "ds-meta" }, "20 000 caractères au plus."), h("span", { class: "ds-actions" }, ds.action({ label: "Annuler", ghost: true, onClick: () => editor.replaceChildren() }), saveB))));
      setTimeout(() => { try { (sk ? ta : nameIn).focus(); editor.scrollIntoView({ behavior: "smooth", block: "nearest" }); } catch (e) {} }, 30);
    };
    head.setActions([{ label: "Nouvelle compétence", icon: "plus", onClick: () => openEditor(null) }]);
    async function load() {
      box.replaceChildren(ds.skeleton(2));
      try {
        const j = await api.get("/api/ame/skills");
        if (dead) return;
        const items = arrOf(j, "items", "skills");
        if (!items.length) { box.replaceChildren(ds.card({}, ds.empty({ icon: "book", text: "Aucune compétence pour l'instant. Écris-en une : des instructions précises que Nova appliquera à la lettre.", action: { label: "Nouvelle compétence", icon: "plus", primary: true, onClick: () => openEditor(null) } }))); return; }
        const list = h("div", { class: "ds-list" });
        for (const s of items) {
          const body = String(s.body || "");
          const first = (body.split("\n").map((l) => l.replace(/^#+\s*/, "").trim()).find((l) => l && l.toLowerCase() !== niceSkill(s.name).toLowerCase()) || "Pas encore d'instructions.");
          const det = h("div", { class: "moi-ame-skillbody", hidden: true }, docView(body.slice(0, 6000), "is-compact"));
          let open = false;
          const toggle = () => { open = !open; det.hidden = !open; r.setSelected(open); };
          const r = ds.row({ lead: "book", title: niceSkill(s.name), meta: truncWords(first, 140), onOpen: toggle,
            actions: [{ label: "Modifier", ghost: true, onClick: () => openEditor(s) }] });
          list.append(r, det);
        }
        box.replaceChildren(ds.section({ title: "Tes compétences", count: items.length, body: ds.card({ flush: true }, list) }),
          h("p", { class: "ds-meta" }, "Clique une compétence pour la lire. Pour l'emporter ailleurs : Transmission › Exporter le paquet."));
      } catch (e) { if (!dead) box.replaceChildren(errBox("Compétences injoignables : " + errMsg(e) + ".", load)); }
    }
    LOADERS.competences = load;
  }

  /* ═══ Gardien du corps + compagnon de charge ══════════════════════════ */
  {
    const page = pages.corps;
    const head = subHead("corps", [{ label: "Essayer le rappel de pause", tip: "Envoie maintenant le rappel de pause, pour voir à quoi il ressemble", onClick: async (e) => {
      const b = e.currentTarget; b.disabled = true;
      try { await api.post("/api/ame/corps/test", {}); ctx.toast("Rappel de pause envoyé."); } catch (err) { ctx.toast("Rappel impossible : " + errMsg(err) + ".", true); }
      b.disabled = false;
    } }]);
    const kBox = h("div", {});
    const chargeSec = ds.section({ title: "Compagnon de charge" });
    const notesBox = h("div", {});
    const notesSec = ds.section({ title: "Notes sur le corps", body: [h("p", { class: "ds-meta moi-ame-secnote" }, "Ce que tu veux que Nova garde en tête pour ton corps."), notesBox] });
    page.append(head, kBox, chargeSec, notesSec);
    const BAT = { charging: "en charge", discharging: "sur batterie", charged: "chargée", "finishing charge": "fin de charge", "ac attached": "sur secteur" };
    async function loadCorps() {
      kBox.replaceChildren(ds.skeleton(1));
      try {
        const j = await api.get("/api/ame/corps");
        if (dead) return;
        const b = j && j.batterie;
        const bat = b && typeof b === "object" ? (b.pct != null ? b.pct + " %" : null) : (b != null ? String(b) : null);
        const batSt = b && typeof b === "object" && b.state ? (BAT[String(b.state).toLowerCase()] || String(b.state)) : "";
        kBox.replaceChildren(
          h("div", { class: "moi-ame-state" }, j.actif === false ? ds.pill("Gardien éteint", "neutral") : ds.pill("Gardien actif", "ok"), h("span", { class: "ds-meta" }, "Relevé à l'ouverture de cette page. Nova n'en déduit aucun état de fatigue.")),
          ds.kpis([
            { label: "Inactivité (clavier, souris)", value: j.mesurable && j.idle_s != null ? Math.round((Number(j.idle_s) || 0) / 60) + " min" : null, tip: j.mesurable ? "Temps depuis ton dernier geste sur le Mac" : "Non mesurable sur ce Mac" },
            { label: "Séquence de travail", value: j.streak_min != null ? j.streak_min + " min" : null, tip: j.streak_min != null ? "Temps de travail continu en cours" : "Pas de séquence mesurée" },
            { label: "Pause conseillée après", value: j.seuil_min != null ? j.seuil_min + " min" : null, tip: j.seuil_min != null ? "Seuil réglé pour le rappel de pause" : "Seuil non servi par le moteur" },
            { label: "Batterie du Mac", value: bat, delta: batSt || null, tip: bat ? null : "Pas de batterie lue sur ce Mac" },
          ]));
      } catch (e) { if (!dead) kBox.replaceChildren(errBox("Signaux du corps injoignables : " + errMsg(e) + ".", loadCorps)); }
    }
    /* VAGUE 2 — Compagnon de charge (GET /api/charge, POST /api/charge/reglage {actif}) : quels signaux sont
       lus, d'où ils viennent, à quel seuil — et les garde-fous. Aucun diagnostic. */
    async function loadCharge() {
      chargeSec.body.replaceChildren(ds.skeleton(2));
      try {
        const j = await api.get("/api/charge");
        if (dead) return;
        const sig = Array.isArray(j && j.signaux) ? j.signaux : [];
        const gf = Array.isArray(j && j.garde_fous) ? j.garde_fous : [];
        const ret = Array.isArray(j && j.retenues) ? j.retenues : [];
        const on = j && j.actif !== false;
        const swb = h("button", { type: "button", class: "switch", role: "switch", "aria-checked": on ? "true" : "false", "aria-label": "Activer ou couper le compagnon de charge", title: on ? "Activé" : "Coupé",
          onclick: async (e) => {
            e.preventDefault(); e.stopPropagation();
            const v = swb.getAttribute("aria-checked") !== "true"; swb.setAttribute("aria-checked", String(v));
            try { await api.post("/api/charge/reglage", { actif: v }); ctx.toast(v ? "Compagnon de charge activé." : "Compagnon de charge coupé."); } catch (err) { ctx.toast("Réglage impossible : " + errMsg(err) + ".", true); }
            if (!dead) loadCharge();
          } });
        const headActs = chargeSec.querySelector(".ds-section-head");
        headActs.querySelectorAll(".moi-ame-sw").forEach((x) => x.remove());
        headActs.append(h("label", { class: "moi-ame-sw" }, h("span", { class: "ds-meta" }, on ? "Activé" : "Coupé"), swb));
        chargeSec.body.replaceChildren(
          h("p", { class: "ds-meta moi-ame-secnote" }, "Au plus une à deux propositions par jour (protéger une pause, regrouper les mails, décaler une tâche non urgente), arrivées dans le Pulse. Elles ne changent rien d'elles-mêmes."),
          sig.length ? ds.card({ flush: true }, h("div", { class: "ds-list" }, sig.map((s) => {
            const measured = !(s.mesure === false || s.valeur == null);
            const u = s.unite ? " " + s.unite : "";
            return ds.row({ title: String(s.label || "Signal"), meta: "Source : " + String(s.source || "—") + " · seuil " + (s.seuil != null ? s.seuil + u : "—"),
              side: h("span", { class: "moi-ame-sig" }, h("b", { class: "ds-num", title: measured ? null : "Non mesuré pour l'instant" }, measured ? String(s.valeur) + u : "—"), s.depasse ? ds.pill("Au-dessus", "warn") : null) });
          }))) : ds.card({}, ds.empty({ compact: true, icon: "pulse", text: on ? "Aucun signal lu pour l'instant — ils apparaissent au fil de la journée." : "Compagnon coupé : aucun signal n'est lu. Active-le pour recevoir des propositions." })),
          ret.length ? h("p", { class: "ds-meta moi-ame-secnote" }, plural(ret.length, "proposition retenue", "propositions retenues") + " aujourd'hui : " + String((ret[0] && ret[0].motif) || "plafond atteint") + ".") : null,
          gf.length ? ds.fold("Garde-fous", h("ul", { class: "moi-ame-ul" }, gf.map((t) => h("li", {}, String(t))))) : null);
      } catch (e) { if (!dead) chargeSec.body.replaceChildren(errBox("Compagnon de charge injoignable : " + errMsg(e) + ".", loadCharge)); }
    }
    const loadNotes = listDoc("corps", notesBox, { placeholder: "Ex. marcher dix minutes après le déjeuner…", empty: "Aucune note pour l'instant — ajoute ce que Nova doit garder en tête." });
    LOADERS.corps = () => { loadCorps(); loadCharge(); loadNotes(); };
  }

  /* ═══ Miroir (n°3, n°18) ═════════════════════════════════════════════ */
  {
    const page = pages.miroir;
    const out = h("div", {});
    const box = h("div", {});
    const mirror = async (e) => {
      const b = e && e.currentTarget; if (b) b.disabled = true;
      out.replaceChildren(ds.skeleton(2));
      try {
        const r = await api.post("/api/ame/llm", { kind: "miroir" });
        if (dead) return;
        if (!(r && r.text)) throw new Error((r && r.error) || "le moteur n'a rien renvoyé");
        out.replaceChildren(ds.section({ title: "Ce que le miroir te montre", actions: r.brain ? [h("span", { class: "ds-meta" }, brainName(r.brain))] : null, body: ds.card({}, docView(r.text, "is-compact")) }));
      } catch (err) { if (!dead) out.replaceChildren(errBox("Lecture du Miroir impossible : " + errMsg(err) + ".", () => mirror())); }
      if (b) b.disabled = false;
    };
    page.append(subHead("miroir", [{ label: "Me tendre le miroir", primary: true, tip: "Le cerveau relit tes messages et ta mémoire : ce que tu répètes, ce que tu repousses, où tes actes contredisent tes valeurs", onClick: mirror }]), out, box);
    async function load() {
      box.replaceChildren(ds.skeleton(3));
      try {
        const j = await api.get("/api/ame/stats");
        if (dead) return;
        /* V5-P (bug n°1) : le moteur renvoie « jours » et « heures » ; anciennes clés gardées en repli. */
        const days = arrOf(j, "jours", "last14", "days");
        const hours = Array.isArray(j && j.heures) ? j.heures : (Array.isArray(j && j.hours) ? j.hours : []);
        const total = Number(j && j.messages_60j) || 0;
        const pic = j && j.pic && typeof j.pic === "object" ? j.pic : null;
        if (!total) { box.replaceChildren(ds.card({}, ds.empty({ icon: "chart", text: "Aucun message de toi dans les conversations des 60 derniers jours — le Miroir n'a rien à refléter pour l'instant. Écris à Nova, il se remplira de lui-même." }))); return; }
        const maxD = Math.max(1, ...days.map((d) => Number(d.n) || 0));
        const maxH = Math.max(1, ...hours.map((n) => Number(n) || 0));
        const activeDays = days.filter((d) => Number(d.n) > 0).length;
        const words = (arr, fmt) => (Array.isArray(arr) && arr.length) ? h("div", { class: "ds-chips" }, arr.slice(0, 8).map((w) => h("span", { class: "ds-chip moi-ame-word", title: fmt(w) }, String(w.mot || "")))) : h("span", { class: "ds-meta", title: "Pas assez de messages pour comparer" }, "—");
        const dayLbl = (d) => { const x = new Date(String(d.d || "")); return isNaN(x) ? String(d.d || "") : x.toLocaleDateString("fr-FR", { weekday: "short", day: "numeric" }); };
        box.replaceChildren(
          ds.kpis([
            { label: "Tes messages sur 60 jours", value: total.toLocaleString("fr-FR") },
            { label: "Ton pic d'activité", value: pic ? String(pic.debut).padStart(2, "0") + " h – " + String(pic.fin).padStart(2, "0") + " h" : null, delta: pic ? plural(Number(pic.messages) || 0, "message") + " sur ces 2 h" : null, tip: pic ? "Les deux heures consécutives où tu écris le plus" : "Pas encore de données" },
            { label: "Jours actifs sur 14", value: days.length ? String(activeDays) : null, tip: days.length ? null : "Série des 14 jours non servie" },
          ]),
          days.length ? ds.section({ title: "Messages par jour", actions: [h("span", { class: "ds-meta" }, "14 derniers jours")], body: ds.card({ class: "moi-ame-chart" },
            h("div", { class: "moi-ame-bars is-days", role: "img", "aria-label": "Messages par jour sur 14 jours" }, days.map((d) => {
              const n = Number(d.n) || 0;
              const bar = h("i", { title: dayLbl(d) + " : " + plural(n, "message") });
              bar.style.height = Math.max(3, Math.round(n / maxD * 100)) + "%";
              if (!n) bar.classList.add("is-zero");
              return h("div", { class: "moi-ame-bar" }, bar);
            })),
            h("div", { class: "moi-ame-axis" }, h("span", {}, dayLbl(days[0])), h("span", {}, dayLbl(days[days.length - 1])))) }) : null,
          hours.length ? ds.section({ title: "Répartition par heure", actions: [h("span", { class: "ds-meta" }, "60 derniers jours")], body: ds.card({ class: "moi-ame-chart" },
            h("div", { class: "moi-ame-bars is-hours", role: "img", "aria-label": "Messages par heure sur 60 jours" }, hours.map((n, hh) => {
              const bar = h("i", { title: hh + " h : " + plural(Number(n) || 0, "message") });
              bar.style.height = Math.max(3, Math.round((Number(n) || 0) / maxH * 100)) + "%";
              if (pic && hh >= pic.debut && hh < pic.fin) bar.classList.add("is-peak");
              if (!Number(n)) bar.classList.add("is-zero");
              return h("div", { class: "moi-ame-bar" }, bar);
            })),
            h("div", { class: "moi-ame-axis is-hours" }, h("span", {}, "0 h"), h("span", {}, "6 h"), h("span", {}, "12 h"), h("span", {}, "18 h"), h("span", {}, "23 h"))) }) : null,
          ds.section({ title: "Tes mots", body: ds.card({ class: "moi-ame-words" },
            h("div", { class: "moi-ame-wl" }, h("span", { class: "ds-meta" }, "Qui montent"), words(j && j.montent, (w) => (w.recent || 0) + " récemment · " + (w.avant || 0) + " avant")),
            h("div", { class: "moi-ame-wl" }, h("span", { class: "ds-meta" }, "Qui disparaissent"), words(j && j.disparaissent, (w) => (w.avant || 0) + " avant · 0 récemment")),
            h("div", { class: "moi-ame-wl" }, h("span", { class: "ds-meta" }, "Tes constantes"), words(j && j.constants, (w) => (w.recent || 0) + " récemment · " + (w.avant || 0) + " avant"))) }),
          h("p", { class: "ds-meta" }, "Source : tes messages à Nova, comptés par le moteur — pas ton agenda ni ton Mac. Les mots comparent les 14 derniers jours aux 14 d'avant."));
      } catch (e) { if (!dead) box.replaceChildren(errBox("Miroir injoignable : " + errMsg(e) + ".", load)); }
    }
    LOADERS.miroir = load;
  }

  /* ═══ Rêves de la nuit (n°5) ═════════════════════════════════════════
     GET /api/reves, POST /api/reves/decider {id, decision: garder|rejeter, text} — Garder = la ligne
     devient un fait de mémoire ; POST /api/reves/lancer = distiller maintenant. Historique : le
     document d'âme « reves » (lecture seule ici). */
  {
    const page = pages.reves;
    const box = h("div", {});
    const ORIG = { "23:30": "à 23:30", "rattrapage": "en rattrapage (Mac endormi à 23:30)", "à la demande": "à ta demande" };
    const distill = async (e) => {
      const b = e && e.currentTarget; if (b) b.disabled = true;
      try { const r = await api.post("/api/reves/lancer", {}); if (dead) return; ctx.toast(r && r.ok ? (Number(r.n) ? plural(Number(r.n), "proposition") + " à valider." : String(r.text || "Rien à distiller.")) : "Distillation impossible : " + String((r && (r.error || r.reason)) || "réponse vide"), !(r && r.ok)); }
      catch (err) { ctx.toast("Distillation impossible : " + errMsg(err) + ".", true); }
      if (b) b.disabled = false;
      if (!dead) load();
    };
    page.append(subHead("reves", [{ label: "Distiller ma journée", icon: "sparkle", onClick: distill }]), box);
    async function load() {
      box.replaceChildren(ds.skeleton(3));
      try {
        const j = await api.get("/api/reves");
        if (dead) return;
        const items = arrOf(j, "items");
        const et = (j && j.etat) || {};
        const etatTxt = et.last_ok ? "Dernière distillation " + fmtDate(et.last_ok) + " " + (ORIG[et.last_origine] || "") + " — " + plural(Number(et.last_n) || 0, "proposition") + "."
          : (et.last_try ? "Dernier essai " + fmtDate(et.last_try) + (et.last_error ? " — échec : " + String(et.last_error) : "") + "." : "Aucune distillation enregistrée : la prochaine part à 23:30, ou au réveil du Mac si elle a été manquée.");
        const card = (it) => {
          const ta = h("textarea", { class: "fld fld-area moi-ame-reve-ta", rows: "2", "aria-label": "Texte du souvenir proposé" }); ta.value = String(it.text || "");
          const acts = h("div", { class: "ds-actions" });
          const decide = async (decision) => {
            acts.querySelectorAll("button").forEach((b) => { b.disabled = true; });
            try {
              const r = await api.post("/api/reves/decider", { id: it.id, decision, text: ta.value.trim() });
              if (r && r.error) throw new Error(String(r.error));
              ctx.toast(decision === "garder" ? (r && r.deja ? "Déjà en mémoire — proposition close." : "Gardé : c'est maintenant un souvenir de Nova.") : "Rejeté : rien n'est retenu.");
              if (!dead) load();
            } catch (e) { ctx.toast("Décision impossible : " + errMsg(e) + ".", true); acts.querySelectorAll("button").forEach((b) => { b.disabled = false; }); }
          };
          ta.addEventListener("keydown", (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); decide("garder"); } });
          acts.append(ds.action({ label: "Rejeter", ghost: true, onClick: () => decide("rejeter") }), ds.action({ label: "Garder", primary: true, onClick: () => decide("garder") }));
          return h("div", { class: "moi-ame-reve" }, ta, h("div", { class: "moi-ame-reve-foot" }, h("span", { class: "ds-meta" }, "Proposé " + fmtDate(it.ts) + (it.origine ? " · " + (ORIG[it.origine] || String(it.origine)) : "") + " · tu peux corriger le texte avant de garder"), acts));
        };
        const hist = h("div", {});
        const histFold = ds.fold("Historique des rêves", hist);
        histFold.addEventListener("toggle", async () => {
          if (!histFold.open || hist.dataset.done) return;
          hist.dataset.done = "1"; hist.replaceChildren(ds.skeleton(2));
          try {
            const d = await api.get("/api/ame/doc?name=reves");
            const all = arrOf(d && d.data).filter((x) => x && typeof x === "object").slice().reverse();
            const ST = { "gardé": ["Gardé", "ok"], "rejeté": ["Rejeté", "neutral"], "proposé": ["En attente", "warn"] };
            hist.replaceChildren(all.length ? h("div", { class: "ds-list" }, all.slice(0, 40).map((x) => { const s = ST[x.status] || ["—", "neutral"]; return ds.row({ title: String(x.text || "—"), meta: fmtDate(x.ts), side: ds.pill(s[0], s[1]) }); }))
              : ds.empty({ compact: true, icon: "moon", text: "Aucun rêve consigné pour l'instant." }));
          } catch (e) { delete hist.dataset.done; hist.replaceChildren(errBox("Historique injoignable : " + errMsg(e) + ".", null)); }
        });
        box.replaceChildren(
          h("div", { class: "moi-ame-state" }, et.last_error && !et.last_ok ? ds.pill("Échec", "danger") : ds.pill(items.length ? "À valider" : "À jour", items.length ? "warn" : "ok"), h("span", { class: "ds-meta" }, etatTxt + (Number(j && j.gardes) ? " " + plural(Number(j.gardes), "rêve gardé", "rêves gardés") + " en tout." : ""))),
          j && j.memoire_coupee ? ds.card({ alert: true, class: "moi-ame-alert" }, h("b", {}, "Mémoire coupée"), h("span", {}, " — « Garder » ne pourra rien retenir tant qu'elle l'est (Savoir › Mémoire).")) : null,
          items.length ? ds.section({ title: "Propositions à valider", count: items.length, body: h("div", { class: "moi-ame-reves" }, items.slice(0, 20).map(card)) })
            : ds.card({}, ds.empty({ icon: "moon", text: "Aucune proposition en attente. La prochaine distillation part à 23:30 — ou lance-la maintenant.", action: { label: "Distiller ma journée", onClick: distill } })),
          histFold);
      } catch (e) { if (!dead) box.replaceChildren(errBox("Rêves injoignables : " + errMsg(e) + ".", load)); }
    }
    LOADERS.reves = load;
  }

  /* ═══ Mémoire de l'âme + Pardon (n°33) ════════════════════════════════
     MÉMOIRE SOUVERAINE (24/10) : le Pardon EFFACE pour de bon. Confirmation en deux temps sur la
     ligne ; un fait exclu par l'ancien Pardon peut être réintégré ou effacé. */
  {
    const page = pages.memoire;
    const head = subHead("memoire");
    const box = h("div", {});
    page.append(head, box);
    let all = [], q = "", limit = 30;
    const listEl = h("div", { class: "ds-list" });
    const countEl = h("span", { class: "ds-meta" });
    const moreEl = h("div", { class: "moi-ame-more" });
    const bar = ds.toolbar({ search: { placeholder: "Chercher un fait…", onInput: (v) => { q = v.toLowerCase(); limit = 30; draw(); } }, end: [countEl] });
    function rowFor(m) {
      const forgiven = m.forgiven === true;
      let r = null;
      const idle = () => r.querySelector(".ds-row-actions").replaceChildren(...acts().map(ds.action));
      const ask = () => {
        r.setSelected(true);
        r.querySelector(".ds-row-actions").replaceChildren(h("span", { class: "ds-meta" }, "Effacer pour de bon ?"),
          ds.action({ label: "Effacer", danger: true, onClick: async () => {
            try { const x = await api.post("/api/ame/pardon", { id: m.id, confirm: true }); if (x && x.ok === false) throw new Error(x.error || "refusé"); ctx.toast("Pardonné : le fait est effacé pour de bon."); all = all.filter((y) => y !== m); draw(); }
            catch (e) { ctx.toast("Pardon impossible : " + errMsg(e) + ".", true); r.setSelected(false); idle(); }
          } }),
          ds.action({ label: "Garder", ghost: true, onClick: () => { r.setSelected(false); idle(); } }));
      };
      const acts = () => {
        const a = [];
        if (forgiven) a.push({ label: "Réintégrer", ghost: true, tip: "Remettre ce fait dans le contexte de Nova", onClick: async () => { try { await api.post("/api/ame/pardon", { id: m.id, reintegrate: true }); ctx.toast("Fait réintégré."); load(); } catch (e) { ctx.toast("Réintégration impossible : " + errMsg(e) + ".", true); } } });
        a.push({ label: forgiven ? "Effacer" : "Pardonner", ghost: true, disabled: !!m.locked, tip: m.locked ? "Fait verrouillé : déverrouille-le dans Savoir › Mémoire" : "Le fait est effacé pour de bon (donnée, vecteur, versions)", onClick: ask });
        return a;
      };
      r = ds.row({ title: String(m.text || m.fait || "—"), meta: [fmtDate(m.at || m.date || m.ts), forgiven ? "exclu par l'ancien Pardon, encore stocké" : ""].filter(Boolean).join(" · "),
        side: m.locked ? ds.pill("Verrouillé", "neutral") : null, actions: acts() });
      r.classList.add("moi-ame-line");
      if (forgiven) r.classList.add("is-off");
      return r;
    }
    function draw() {
      const shown = q ? all.filter((m) => String(m.text || m.fait || "").toLowerCase().includes(q)) : all;
      countEl.textContent = q ? shown.length + " sur " + plural(all.length, "fait") : plural(all.length, "fait");
      listEl.replaceChildren(...(shown.length ? shown.slice(0, limit).map(rowFor) : [ds.empty({ compact: true, icon: "search", text: "Aucun fait ne contient « " + q + " »." })]));
      moreEl.replaceChildren(shown.length > limit ? ds.action({ label: "Afficher " + Math.min(30, shown.length - limit) + " de plus", ghost: true, onClick: () => { limit += 30; draw(); } }) : null);
    }
    async function load() {
      box.replaceChildren(ds.skeleton(4));
      try {
        const j = await api.get("/api/ame/memoire");
        if (dead) return;
        all = arrOf(j, "items");
        if (!all.length) { box.replaceChildren(ds.card({}, ds.empty({ icon: "brain", text: "Aucun fait dans la mémoire de l'âme. Nova retient ce que tu lui confies en conversation, et ce que tu gardes dans « Rêves de la nuit »." }))); return; }
        draw();
        box.replaceChildren(bar, ds.card({ flush: true }, listEl), moreEl);
      } catch (e) { if (!dead) box.replaceChildren(errBox("Mémoire de l'âme injoignable : " + errMsg(e) + ".", load)); }
    }
    LOADERS.memoire = load;
  }

  /* ═══ Boucle fermée (philosophie n°5) ════════════════════════════════
     Le principe vient du pack ; la matière vient du moteur : journal des décisions
     (GET /api/decision/log, le plus récent d'abord) et journal des cerveaux/voix (GET /api/journal). */
  {
    const page = pages.boucle;
    const box = h("div", {});
    page.append(subHead("boucle"), box);
    async function load() {
      box.replaceChildren(ds.skeleton(4));
      const kids = [ds.card({ muted: true, class: "moi-ame-principle" }, h("b", {}, "Le principe. "), "Chaque manquement devient une leçon écrite, datée et relue au démarrage suivant ; une erreur répétée devient une règle. Preuve avant annonce, toujours.")];
      try {
        const j = await api.get("/api/decision/log");
        const items = arrOf(j, "items");
        const list = h("div", { class: "ds-list" });
        let showAll = false;
        const draw = () => {
          list.replaceChildren(...(showAll ? items : items.slice(0, 8)).map((e) => { const r = ds.row({ title: String(e.regle || e.text || e.line || e.decision || ligneBrute(e)), meta: fmtDate(e.at || e.ts || e.date) || null }); r.classList.add("moi-ame-line"); return r; }));
        };
        draw();
        const sec = ds.section({ title: "Journal des décisions", count: items.length, actions: items.length > 8 ? [{ label: "Tout afficher", ghost: true, onClick: (ev) => { showAll = !showAll; ev.currentTarget.lastChild.textContent = showAll ? "Les 8 dernières" : "Tout afficher"; draw(); } }] : null,
          body: items.length ? ds.card({ flush: true }, list) : ds.card({}, ds.empty({ compact: true, icon: "list", text: "Aucune décision journalisée. Elles s'inscrivent quand une règle est posée en conversation." })) });
        kids.push(sec);
      } catch (e) { kids.push(errBox("Journal des décisions injoignable : " + errMsg(e) + ".", load)); }
      try {
        const j = await api.get("/api/journal");
        const cerv = arrOf(j, "cerveaux");
        const voix = arrOf(j, "voix");
        const line = (e, kind) => { const who = e.brain ? brainName(e.brain) : (e.voix ? "voix " + String(e.voix) : ""); const r = ds.row({ title: String(e.line || e.text || e.msg || ligneBrute(e)), meta: [fmtDate(e.at || e.ts), who].filter(Boolean).join(" · ") || null, side: ds.pill(kind, "neutral") }); r.classList.add("moi-ame-line"); return r; };
        const rows = [...cerv.slice(-5).reverse().map((e) => line(e, "Cerveau")), ...voix.slice(-3).reverse().map((e) => line(e, "Voix"))];
        kids.push(ds.section({ title: "Journal du moteur", actions: [h("span", { class: "ds-meta" }, "cerveaux et voix, les plus récents")],
          body: rows.length ? ds.card({ flush: true }, h("div", { class: "ds-list" }, rows)) : ds.card({}, ds.empty({ compact: true, icon: "cpu", text: "Journal vide pour l'instant." })) }));
      } catch (e) { kids.push(errBox("Journal du moteur (cerveaux et voix) injoignable — les décisions ci-dessus restent affichées.", load)); }
      /* LOT I (28/10) — style d'écriture appris (GET /api/style) : paires brouillon→envoi,
         écarts relevés (leçons), consignes injectées dans chaque prompt. Réapprendre + auto. */
      try {
        const sj = await api.get("/api/style");
        const prof = (sj && sj.profile && typeof sj.profile === "object") ? sj.profile : null;
        const lines = [];
        if (prof) {
          const pair = [["Salutation", prof.salutation], ["Clôture", prof.cloture], ["Registre", prof.registre], ["Longueur", prof.longueur], ["Structure", prof.structure]]
            .filter((p) => p[1]);
          for (const p of pair) { const r = ds.row({ title: p[0] + " : " + String(p[1]).slice(0, 220) }); r.classList.add("moi-ame-line"); lines.push(r); }
          for (const e of (Array.isArray(prof.ecarts_nova) ? prof.ecarts_nova : [])) { const r = ds.row({ title: "Leçon — " + String(e).slice(0, 240) }); r.classList.add("moi-ame-line"); lines.push(r); }
        }
        const relearn = async (ev) => {
          const b = ev && ev.currentTarget; if (b) b.disabled = true;
          try { await api.post("/api/style/learn", {}); ctx.toast("Apprentissage lancé — le profil se mettra à jour ici."); }
          catch (err) { ctx.toast("Apprentissage impossible : " + errMsg(err) + ".", true); }
          if (b) b.disabled = false;
        };
        const autoBtn = h("button", { type: "button", class: "switch", role: "switch", "aria-checked": sj && sj.auto ? "true" : "false", "aria-label": "Apprentissage automatique du style (hebdomadaire)",
          onclick: async (e) => {
            e.preventDefault(); e.stopPropagation();
            const v = autoBtn.getAttribute("aria-checked") !== "true"; autoBtn.setAttribute("aria-checked", String(v));
            try { await api.post("/api/style/auto", { on: v }); ctx.toast(v ? "Apprentissage hebdomadaire activé." : "Apprentissage automatique coupé."); }
            catch (err) { ctx.toast("Réglage impossible : " + errMsg(err) + ".", true); }
          } });
        kids.push(ds.section({ title: "Ton style d'écriture (appris de tes envois)", count: lines.length || null,
          actions: [{ label: sj && sj.running ? "Apprentissage…" : "Réapprendre", ghost: true, tip: "Relit tes mails envoyés (Mail.app, lecture seule) et les écarts avec les brouillons de Nova", onClick: relearn },
            h("label", { class: "moi-ame-sw" }, h("span", { class: "ds-meta" }, "hebdo auto"), autoBtn)],
          body: lines.length
            ? [h("p", { class: "ds-meta moi-ame-secnote" }, "Appris " + (sj.ts ? fmtDate(sj.ts) : "") + " · " + (sj.pairs || 0) + " paires brouillon→envoi sur " + (sj.sent || 0) + " mails envoyés · " + (sj.brain || "") + ". Ces règles sont injectées dans chaque brouillon."),
               ds.card({ flush: true }, h("div", { class: "ds-list" }, lines))]
            : ds.card({}, ds.empty({ compact: true, icon: "note", text: "Aucun profil appris. Clique « Réapprendre » : Nova relit tes mails envoyés et ce que tu corriges dans ses brouillons." })) }));
      } catch (e) { kids.push(errBox("Profil de style injoignable : " + errMsg(e) + ".", load)); }
      if (!dead) box.replaceChildren(...kids);
    }
    LOADERS.boucle = load;
  }

  /* ═══ Auto-évaluation (P5) ═══════════════════════════════════════════
     GET /api/boucle : indicateurs MESURÉS (7 j glissants vs les 7 d'avant), dérives (règles fixes),
     rapports hebdomadaires écrits par Nova, bloc relu dans chaque prompt. La note de la semaine vit
     dans l'API Notes du moteur (kind « autoeval »). */
  const AXES = ["Preuve avant annonce", "Action réelle, pas d'intention", "Anticipation", "Honnêteté des limites", "Vérification avant refus", "Règle d'or n°2 respectée", "Fiabilité technique", "Utilité concrète", "Leçons écrites et relues", "Sobriété — aucun bruit inutile"];
  {
    const page = pages.evaluation;
    const mBox = h("div", {});
    const nBox = h("div", {});
    const rediger = async (e) => {
      const b = e && e.currentTarget; if (b) b.disabled = true;
      try { const r = await api.post("/api/boucle/rediger", {}); if (r && r.error) throw new Error(String(r.error)); ctx.toast("Auto-évaluation rédigée par Nova."); }
      catch (err) { ctx.toast("Rédaction impossible : " + errMsg(err) + ".", true); }
      if (b) b.disabled = false;
      if (!dead) loadBoucle();
    };
    page.append(subHead("evaluation", [{ label: "Faire rédiger maintenant", tip: "Nova rédige son auto-évaluation de la semaine sans attendre dimanche", onClick: rediger }]), mBox, nBox);
    async function loadBoucle() {
      mBox.replaceChildren(ds.skeleton(4));
      try {
        const j = await api.get("/api/boucle");
        if (dead) return;
        const c = (j && j.courante) || {}, p = (j && j.precedente) || {};
        const pct = (v) => (v == null || v === "" || isNaN(Number(v))) ? "—" : (Math.round(Number(v) * 1000) / 10).toLocaleString("fr-FR") + " %";
        const sec = (v) => v == null || isNaN(Number(v)) ? "—" : (Number(v) >= 120 ? Math.round(Number(v) / 60) + " min" : Math.round(Number(v)) + " s");
        const num = (v) => v == null || isNaN(Number(v)) ? "—" : Number(v).toLocaleString("fr-FR");
        const cards = (o) => num(o.cartes_approuvees) + " / " + num(o.cartes_refusees) + " / " + num(o.cartes_expirees);
        const rowsDef = [
          ["Actions journalisées", num(c.actions), num(p.actions)],
          ["Taux d'erreur des actions", pct(c.taux_erreur), pct(p.taux_erreur)],
          ["Cartes approuvées / refusées / expirées", cards(c), cards(p)],
          ["Délai médian jusqu'au feu vert", sec(c.go_median_s) + (Number(c.go_n) ? " (" + c.go_n + ")" : ""), sec(p.go_median_s) + (Number(p.go_n) ? " (" + p.go_n + ")" : "")],
          ["Refus par le garde-fou de confiance", num(c.refus_politique), num(p.refus_politique)],
          ["Leçons d'outils touchées", num(c.lecons_outils), num(p.lecons_outils)],
          ["Manquements consignés", num(c.manquements), num(p.manquements)],
        ];
        const dsv = arrOf(j, "derives");
        const reps = arrOf(j, "rapports");
        const table = h("div", { class: "ds-table-wrap moi-ame-tw" }, h("table", { class: "ds-table" },
          h("thead", {}, h("tr", {}, h("th", {}, "Indicateur"), h("th", { class: "num" }, "Cette semaine"), h("th", { class: "num" }, "Semaine d'avant"))),
          h("tbody", {}, rowsDef.map((r) => h("tr", {}, h("td", {}, r[0]), h("td", { class: "num" }, r[1]), h("td", { class: "num muted" }, r[2]))))));
        const drift = dsv.length
          ? ds.card({ alert: true, class: "moi-ame-alert" }, h("b", {}, "Dérive mesurée — "), dsv.map((d) => String(d.indicateur) + " (" + (/taux/.test(String(d.indicateur)) ? pct(d.avant) + " → " + pct(d.maintenant) : num(d.avant) + " → " + num(d.maintenant)) + ")").join(" · "), h("div", { class: "ds-meta" }, "Règle : " + dsv.map((d) => String(d.regle || "")).filter(Boolean).join(" ; ")))
          : !Object.keys(c).length ? h("div", { class: "moi-ame-state" }, ds.pill("Pas de mesure", "neutral"), h("span", { class: "ds-meta" }, "Le moteur n'a encore rien mesuré sur ces deux semaines."))
          : h("div", { class: "moi-ame-state" }, ds.pill("Aucune dérive", "ok"), h("span", { class: "ds-meta" }, "Règles fixes : taux d'erreur +5 points, refus ×2, délai jusqu'au feu vert ×1,5, manquements en hausse."));
        mBox.replaceChildren(
          ds.section({ title: "Mesuré par le moteur", actions: [h("span", { class: "ds-meta" }, "7 derniers jours / 7 jours d'avant")], body: [ds.card({ flush: true }, table), drift] }),
          ds.section({ title: "Rapports de Nova", count: reps.length || null, actions: [h("span", { class: "ds-meta" }, "chaque dimanche, 19 h")],
            body: reps.length ? h("div", { class: "moi-ame-reps" }, reps.slice(0, 4).map((r) => ds.card({ class: "moi-ame-rep" },
              h("div", { class: "moi-ame-rep-h" }, h("b", { class: "ds-h3" }, "Semaine du " + fmtDate(r.debut) + " au " + fmtDate(r.fin)), Array.isArray(r.derives) && r.derives.length ? ds.pill(plural(r.derives.length, "dérive"), "warn") : null, r.brain ? h("span", { class: "ds-meta" }, brainName(r.brain)) : null),
              r.texte ? docView(String(r.texte), "is-compact") : h("p", { class: "ds-meta" }, String(r.note || "Pas de texte (cerveau indisponible) — indicateurs seuls.")))))
              : ds.card({}, ds.empty({ compact: true, icon: "note", text: "Pas encore de rapport : le premier s'écrit dimanche à 19 h, ou maintenant avec « Faire rédiger maintenant »." })) }),
          ds.fold("Ce que Nova relit dans chaque prompt (" + plural(Number(j && j.manquements_actifs) || 0, "manquement actif", "manquements actifs") + ")", h("pre", { class: "moi-ame-pre" }, String((j && j.prompt) || "Rien pour l'instant — aucun manquement actif."))));
      } catch (e) { if (!dead) mBox.replaceChildren(errBox("Boucle fermée injoignable : " + errMsg(e) + ".", loadBoucle)); }
    }
    async function loadNotes() {
      nBox.replaceChildren(ds.skeleton(2));
      try {
        const j = await api.get("/api/notes");
        if (dead) return;
        const hist = arrOf(j, "items").filter((n) => n.kind === "autoeval");
        const scores = {};
        const moy = h("b", { class: "ds-num" }, "5,0");
        const majMoy = () => { const v = AXES.reduce((s, a) => s + (scores[a] || 0), 0) / AXES.length; moy.textContent = v.toFixed(1).replace(".", ","); };
        const sliders = AXES.map((a) => {
          scores[a] = 5;
          const val = h("b", { class: "ds-num moi-ame-ax-v" }, "5");
          const rg = h("input", { type: "range", min: "0", max: "10", step: "1", value: "5", "aria-label": a });
          rg.addEventListener("input", () => { scores[a] = Number(rg.value); val.textContent = rg.value; majMoy(); });
          return h("div", { class: "moi-ame-ax" }, h("span", { class: "moi-ame-ax-l" }, a), rg, val);
        });
        const save = ds.action({ label: "Consigner la note", primary: true, onClick: async () => {
          const m = AXES.reduce((s, a) => s + (scores[a] || 0), 0) / AXES.length;
          save.disabled = true;
          try { await api.post("/api/notes/save", { title: "Auto-évaluation hebdo — " + new Date().toLocaleDateString("fr-FR"), kind: "autoeval", body: JSON.stringify({ axes: { ...scores }, moyenne: Number(m.toFixed(1)) }) }); ctx.toast("Auto-évaluation consignée."); if (!dead) loadNotes(); }
          catch (e) { ctx.toast("Consignation impossible : " + errMsg(e) + ".", true); save.disabled = false; }
        } });
        nBox.replaceChildren(
          ds.section({ title: "Noter la semaine", body: ds.card({ class: "moi-ame-axes" },
            h("p", { class: "ds-meta" }, "Une note de 0 à 10 sur chacun des dix axes de la maison. Elle est gardée dans les notes du moteur : la boucle ne vaut que si la mesure survit à la semaine."),
            h("div", { class: "moi-ame-axgrid" }, sliders),
            h("div", { class: "moi-ame-docbar is-foot" }, h("span", {}, "Moyenne : ", moy, " / 10"), save)) }),
          ds.section({ title: "Historique", count: hist.length || null, body: hist.length ? ds.card({ flush: true }, h("div", { class: "ds-list" }, hist.slice(0, 8).map((n) => {
            let d = null; try { d = JSON.parse(n.body || ""); } catch (e) {}
            return ds.row({ title: String(n.title || "Auto-évaluation"), meta: d && d.axes ? truncWords(Object.entries(d.axes).map(([k, v]) => k + " " + v).join(" · "), 200) : null, side: h("b", { class: "ds-num" }, d && d.moyenne != null ? String(d.moyenne).replace(".", ",") + " / 10" : "—") });
          }))) : ds.card({}, ds.empty({ compact: true, icon: "chart", text: "Aucune note consignée pour l'instant — la première se pose juste au-dessus." })) }));
      } catch (e) { if (!dead) nBox.replaceChildren(errBox("Notes du moteur injoignables : " + errMsg(e) + ".", loadNotes)); }
    }
    LOADERS.evaluation = () => { loadBoucle(); loadNotes(); };
  }

  /* ═══ Registre des manquements (notes du moteur, kind « manquement ») ═══ */
  {
    const page = pages.manquements;
    const head = subHead("manquements");
    const box = h("div", {});
    const tIn = h("input", { class: "fld", type: "text", placeholder: "Le manquement — ce qui a été raté, factuel…", "aria-label": "Le manquement" });
    const lIn = h("input", { class: "fld", type: "text", placeholder: "La leçon, la règle qui en sort…", "aria-label": "La leçon qui en sort" });
    const add = ds.action({ label: "Consigner", primary: true, onClick: async () => {
      const t = tIn.value.trim(); if (!t) { tIn.focus(); ctx.toast("Décris le manquement d'abord.", true); return; }
      add.disabled = true;
      try { await api.post("/api/notes/save", { title: t, body: lIn.value.trim(), kind: "manquement" }); ctx.toast(lIn.value.trim() ? "Manquement consigné, leçon jointe." : "Manquement consigné."); tIn.value = ""; lIn.value = ""; if (!dead) load(); }
      catch (e) { ctx.toast("Consignation impossible : " + errMsg(e) + ".", true); }
      add.disabled = false;
    } });
    lIn.addEventListener("keydown", (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter") { e.preventDefault(); add.click(); } });
    tIn.addEventListener("keydown", (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter") { e.preventDefault(); lIn.focus(); } });
    page.append(head, ds.card({ class: "moi-ame-manqform" }, h("div", { class: "moi-ame-manqfields" }, tIn, lIn, add),
      h("p", { class: "ds-meta" }, "Un manquement sans leçon n'est qu'une honte ; avec une leçon datée, il devient une règle.")), box);
    async function load() {
      box.replaceChildren(ds.skeleton(3));
      try {
        const j = await api.get("/api/notes");
        if (dead) return;
        const items = arrOf(j, "items").filter((n) => n.kind === "manquement");
        const rows = items.map((n) => {
          let r = null;
          const idle = () => r.querySelector(".ds-row-actions").replaceChildren(ds.action({ icon: "trash", tip: "Retirer cette entrée du registre", onClick: ask }));
          const ask = () => {
            r.setSelected(true);
            r.querySelector(".ds-row-actions").replaceChildren(h("span", { class: "ds-meta" }, "Retirer ?"),
              ds.action({ label: "Retirer", danger: true, onClick: async () => { try { await api.post("/api/notes/remove", { id: n.id }); ctx.toast("Entrée retirée."); if (!dead) load(); } catch (e) { ctx.toast("Retrait impossible : " + errMsg(e) + ".", true); r.setSelected(false); idle(); } } }),
              ds.action({ label: "Garder", ghost: true, onClick: () => { r.setSelected(false); idle(); } }));
          };
          r = ds.row({ title: String(n.title || "Manquement"), meta: [fmtDate(n.updated), n.body ? "Leçon : " + String(n.body) : "sans leçon"].filter(Boolean).join(" · "), actions: [{ icon: "trash", tip: "Retirer cette entrée du registre", onClick: ask }] });
          r.classList.add("moi-ame-line");
          return r;
        });
        box.replaceChildren(ds.section({ title: "Consignés", count: items.length, body: items.length ? ds.card({ flush: true }, h("div", { class: "ds-list" }, rows))
          : ds.card({}, ds.empty({ compact: true, icon: "check", text: "Aucun manquement consigné — le registre est vide, pas l'histoire. Note le premier juste au-dessus." })) }));
      } catch (e) { if (!dead) box.replaceChildren(errBox("Registre injoignable (notes du moteur) : " + errMsg(e) + ".", load)); }
    }
    LOADERS.manquements = load;
  }

  /* Rubrique de départ : la dernière ouverte (mémoire locale), sinon les Documents d'âme. */
  let first = "documents";
  try { const s = localStorage.getItem("nova2_ame_page"); if (s && pages[s]) first = s; } catch (e) {}
  show(first);
  return () => { dead = true; cleanups.forEach((f) => { try { f(); } catch (e) {} }); };
}
