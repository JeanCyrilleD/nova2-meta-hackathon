/* Module Coffre — E3 (vague 3) : le client RÉEL du protocole du moteur (Vault.swift).
   Ouverture : la porte commune (vaultgate.js) — Touch ID / mot de passe du Mac côté moteur
   (POST /api/vault/unlock/system), code vérifié par le moteur (POST /api/vault/unlock), jeton
   en mémoire seulement, révocation à la fermeture de l'écran. Contenu : GET /api/vault/data?
   domain=finance|sante → les sources importées (le moteur détient les données). Import : POST
   /api/vault/import {domain, path, label} ; retrait : POST /api/vault/remove {domain, id}.
   V3 COFFRE (24/10/2026) : chiffrement au repos AES-256-GCM (clé au Trousseau), migration
   JAMAIS automatique (Nova 1 lit ce même coffre en clair), code (ajout / changement), second
   facteur, retour arrière guidé — état réel via GET /api/vault/status.
   V6 (25/10/2026, contrat conseil_24-10/V6_DESIGN.md) :
   · Verrouillé : un écran de verrouillage centré (icône, « Coffre verrouillé », une phrase,
     Touch ID en primaire, le code en secondaire) ; l'état du chiffrement du disque devient une
     pastille VRAIE (lue sur /api/vault/status) et son action « Activer le chiffrement… » ouvre
     d'abord le coffre puis mène à Sécurité — rien n'est chiffré sans ta confirmation.
     La porte (vaultgate.js, partagée avec Finance) n'est pas modifiée : son titre et son
     paragraphe sont remplacés à l'affichage par ceux de cet écran, selon son état observé.
   · Ouvert : sections Finances / Santé / Sécurité en .ds-section, sources en lignes .ds-row,
     libellés masqués (n° de compte, IBAN, jetons → ••••1234), import replié par domaine,
     protocole replié. Corrige l'affichage « N lignes » qui imprimait le CONTENU des lignes
     (s.rows est un tableau) au lieu de leur nombre. */
import { vaultGate, vaultLock, vaultStatus, vaultSetup, vaultSetMode, vaultRestoreClear, vaultEncrypt } from "../vaultgate.js";
import { approvalCard } from "../orb.js";
import { fmtDateFR } from "../core.js";
import * as ds from "../ds.js";

const arrOf = (j, ...keys) => { if (Array.isArray(j)) return j; for (const k of keys) if (j && Array.isArray(j[k])) return j[k]; return []; };
const plural = (n, w, many) => n + " " + (n > 1 ? (many || w + "s") : w);
/* Masquage obligatoire : IBAN, jetons, longues suites de chiffres (n° de compte, carte). */
const maskText = (s) => String(s ?? "")
  .replace(/\b[A-Z]{2}\d{2}(?:\s?[A-Z0-9]{4}){3,8}(?:\s?[A-Z0-9]{1,4})?\b/g, (m) => ds.maskSecret(m))
  .replace(/\b(?:sk|pk|ghp|gho|xox[abp])[-_][A-Za-z0-9-_]{12,}\b/g, (m) => ds.maskSecret(m))
  .replace(/(?<![\w.,/-])\d[\d ]{6,}\d(?!\w|[.,/-]\w)/g, (m) => (m.replace(/\s/g, "").length >= 8 ? ds.maskSecret(m) : m));
const baseName = (p) => String(p || "").split("/").filter(Boolean).pop() || String(p || "");
const errMsg = (e) => String((e && e.message) || e || "").replace(/^\/api\/\S+\s*→\s*\d+\s*:?\s*/, "").trim() || "le moteur ne répond pas";

/* État du chiffrement du disque — toujours VRAI : lu sur /api/vault/status, jamais supposé. */
function encState(st) {
  const enc = (st && st.encryption) || {};
  const ne = Number(enc.encrypted_files) || 0, nc = Number(enc.clear_files) || 0;
  if (enc.supported === false) return { tone: "neutral", label: "Chiffrement du disque indisponible", tip: "Ce système n'offre pas le chiffrement au repos : les fichiers restent en clair." };
  if (enc.clear_mode) return { tone: "danger", label: "Ouvert sans chiffrement", tip: maskText(enc.error || "Clé du Trousseau illisible.") + " Les fichiers restent en clair tant que la clé n'est pas lisible." };
  if (ne > 0 && nc === 0) return { tone: "ok", label: "Chiffré sur le disque", tip: "AES-256-GCM, clé au Trousseau de ce Mac — " + plural(ne, "fichier") };
  if (nc > 0) return { tone: "warn", label: ne > 0 ? "Chiffrement du disque partiel" : "Chiffrement du disque : pas encore activé", tip: plural(nc, "fichier") + " encore en clair" + (ne ? ", " + plural(ne, "fichier") + " chiffré" + (ne > 1 ? "s" : "") : "") + ". Le chiffrement se lance depuis Sécurité, après ta confirmation.", canEncrypt: true, clear: nc };
  if (enc.supported == null && !Object.keys(enc).length) return null;
  return { tone: "neutral", label: "Rien à chiffrer pour l'instant", tip: "Aucun fichier dans le coffre." };
}

export async function mount(root, ctx) {
  const { api, h, ic } = ctx;
  let dead = false;
  const cleanups = [];
  let wantSecurity = false;   // « Activer le chiffrement… » cliqué sur l'écran verrouillé
  root.classList.add("mod--form", "moi-vlt", "is-locked");

  const lockBtn = ds.action({ label: "Verrouiller", icon: "lock", tip: "Refermer le coffre maintenant", onClick: async () => { await vaultLock(); ctx.toast("Coffre verrouillé."); ctx.refresh(); } });
  const head = ds.pageHead({ title: "Coffre", sub: "Tes finances et documents de santé, ouverts par Touch ID ou ton code", actions: [lockBtn] });
  head.classList.add("moi-vlt-head");
  const body = h("div", { class: "moi-vlt-body" });

  /* ── Écran de verrouillage ── */
  const lockTitle = h("h1", { class: "ds-title" }, "Coffre verrouillé");
  const lockText = h("p", { class: "moi-vlt-lock-t" }, "Tes finances et documents de santé restent fermés tant que tu ne les ouvres pas.");
  const encLine = h("div", { class: "moi-vlt-enc" });
  const lockMeta = h("p", { class: "ds-meta moi-vlt-lock-meta" }, "Il se referme quand tu quittes cet écran ou après 5 min sans activité.");
  const gate = vaultGate(ctx, "Coffre", () => {
    root.classList.remove("is-locked");
    lockView.hidden = true;
    if (!dead) loadAll();
    try { const ret = localStorage.getItem("nova2_vault_return"); if (ret) { localStorage.removeItem("nova2_vault_return"); if (ctx.modules) { const ok = Array.isArray(ctx.modules) ? ctx.modules.some((m) => m && m.id === ret) : !!ctx.modules[ret]; if (!ok) return; } ctx.navigate(ret); } } catch (e) {}
  });
  const lockView = h("section", { class: "moi-vlt-lock", "aria-label": "Coffre verrouillé" },
    h("span", { class: "moi-vlt-lock-ic", html: ic("lock", 26) }), lockTitle, lockText, gate, encLine, lockMeta);
  root.append(head, lockView, body);

  /* La porte est commune (Finance l'utilise aussi) : on observe son état pour donner à cet
     écran le bon titre et la bonne phrase — ses propres titre et paragraphe sont masqués (CSS). */
  const GATE_TXT = {
    sys: ["Coffre verrouillé", "Tes finances et documents de santé restent fermés tant que tu ne les ouvres pas."],
    code: ["Coffre verrouillé", "Entre le code du coffre pour l'ouvrir."],
    second: ["Second facteur", "Identité confirmée par le Mac. Entre maintenant ton code — il est valable 2 min."],
    setup: ["Configure ton coffre", "Choisis un code : le moteur n'en garde qu'une empreinte salée, jamais le code lui-même."],
    error: ["Coffre injoignable", "Le moteur ne répond pas pour l'instant."],
  };
  const classify = () => {
    const card = gate.querySelector(".vault-gate-card");
    const t = (card && card.querySelector("h2") ? card.querySelector("h2").textContent : "") || "";
    let st = null;
    if (gate.querySelector(".state-error")) st = "error";
    else if (!card) st = null;
    else if (/second facteur/i.test(t)) st = "second";
    else if (/pas encore configur/i.test(t)) st = "setup";
    else if (card.querySelector(".banner")) st = "code";
    else st = "sys";
    if (!st) return;
    root.dataset.gate = st;
    lockTitle.textContent = GATE_TXT[st][0];
    lockText.textContent = GATE_TXT[st][1];
    /* Lien secondaire « Utiliser le code du coffre » : libellé court, comme demandé. */
    card && card.querySelectorAll(".btn.ghost.sm").forEach((b) => { if (/^Utiliser le code du coffre$/.test(b.textContent.trim())) b.textContent = "Utiliser le code"; });
  };
  const mo = new MutationObserver(classify);
  mo.observe(gate, { childList: true, subtree: true });
  cleanups.push(() => mo.disconnect());

  function renderEnc(st) {
    const e = encState(st);
    if (!e) { encLine.replaceChildren(); return; }
    const p = ds.pill(e.label, e.tone); p.title = e.tip || e.label;
    const kids = [p];
    if (e.canEncrypt) kids.push(ds.action({ label: "Activer le chiffrement…", ghost: true, tip: "Ouvre d'abord le coffre : le chiffrement se lance ensuite dans Sécurité, après ta confirmation", onClick: () => {
      wantSecurity = true;
      lockMeta.textContent = "Ouvre d'abord le coffre : tu confirmeras le chiffrement dans Sécurité.";
      const sysBtn = gate.querySelector(".vault-gate-card .btn.lg.acc");
      const pin = gate.querySelector("input[type=password]");
      if (root.dataset.gate === "sys" && sysBtn && !sysBtn.disabled) sysBtn.click();
      else if (pin) pin.focus();
    } }));
    encLine.replaceChildren(...kids);
  }
  vaultStatus().then((st) => { if (!dead && root.classList.contains("is-locked")) renderEnc(st); }).catch(() => {});

  async function loadAll() {
    body.setAttribute("aria-busy", "true");
    body.replaceChildren(ds.skeleton(3));
    try {
      const st = await vaultStatus();
      if (dead) return;
      body.removeAttribute("aria-busy");
      if (!st.unlocked) {
        body.replaceChildren(ds.card({}, ds.empty({ icon: "lock", text: "Le coffre s'est refermé (5 min sans activité, ou jeton révoqué).", action: { label: "Rouvrir le coffre", primary: true, onClick: () => ctx.refresh() } })));
        return;
      }
      lastStatus = st;
      const [fin, san] = await Promise.all([
        api.get("/api/vault/data?domain=finance").catch(() => null),
        api.get("/api/vault/data?domain=sante").catch(() => null),
      ]);
      if (dead) return;
      render(fin, san);
      if (wantSecurity) {
        wantSecurity = false;
        setTimeout(() => { const t = body.querySelector("#moi-vlt-encrypt") || body.querySelector("#moi-vlt-sec"); if (t) { try { t.scrollIntoView({ behavior: "smooth", block: "center" }); const b = t.querySelector("button"); if (b) b.focus({ preventScroll: true }); } catch (e) {} } }, 120);
      }
    } catch (e) {
      if (dead) return;
      body.removeAttribute("aria-busy");
      body.replaceChildren(ds.errorBox({ cause: "Coffre injoignable pour le moment.", retry: () => loadAll() }));
    }
  }

  function sourceList(data, domain, card, imp) {
    if (data == null) return ds.errorBox({ title: "Domaine illisible", cause: "Le moteur n'a pas servi ce domaine.", retry: () => loadAll() });
    const srcs = arrOf(data, "sources");
    if (!srcs.length) return ds.empty({ compact: true, icon: "file", text: "Aucune source pour l'instant — importe un relevé CSV, JSON, Markdown ou texte ci-dessous." });
    return h("div", { class: "ds-list" }, srcs.map((s) => {
      const label = maskText(String(s.label || "Source"));
      const nRows = Array.isArray(s.rows) ? s.rows.length : (Number.isFinite(Number(s.rows)) && s.rows != null ? Number(s.rows) : null);
      const nCols = Array.isArray(s.columns) ? s.columns.length : null;
      const meta = [s.imported ? "importée le " + fmtDateFR(s.imported) : "", nRows != null ? plural(nRows, "ligne") : "", nCols != null ? plural(nCols, "colonne") : "", s.kind ? String(s.kind) : ""].filter(Boolean).join(" · ");
      return ds.row({ lead: "file", title: label, meta: meta || null, actions: [{ icon: "trash", tip: "Retirer « " + label + " » du coffre", onClick: () => confirmRemove(s, label, domain, card) }] });
    }));
  }
  async function confirmRemove(s, label, domain, card) {
    const appr = approvalCard({ title: "Retirer la source « " + label + " » ?", what: "Elle sera retirée du domaine " + (domain === "finance" ? "Finances" : "Santé") + " du coffre. Les données importées par cette source ne seront plus lisibles dans Nova.", approveLabel: "Retirer", editLabel: null, refuseLabel: "Garder" });
    card.after(appr);
    const v = await appr.promise; appr.remove();
    if (v !== "approve" || dead) return;
    /* LOT1-FIX C4 : le moteur filtre les sources par `id` ; le toast n'apparaît que sur confirmation. */
    try { const j = await api.post("/api/vault/remove", { domain, id: s.id }); if (!j || j.ok !== true) throw new Error((j && j.error) || "le moteur n'a pas confirmé le retrait"); ctx.toast("Source retirée."); loadAll(); }
    catch (e) { ctx.toast("Retrait impossible : " + maskText(errMsg(e)), true); }
  }
  function importForm(domain) {
    const label = h("input", { type: "text", class: "fld", placeholder: "Nom de la source" });
    const path = h("input", { type: "text", class: "fld", placeholder: "Chemin du fichier sur le Mac (CSV, JSON, MD, TXT)…" });
    const fileIn = h("input", { type: "file", accept: ".csv,.json,.md,.txt", hidden: true });
    const nameEl = h("span", { class: "ds-meta" }, "Aucun fichier choisi.");
    const errZone = h("div", {});
    const adv = ds.fold("Avancé — chemin du fichier sur le Mac", h("div", { class: "field" },
      h("label", { class: "field-lb" }, "Chemin du fichier"), path,
      h("span", { class: "field-help" }, "Le moteur lit le fichier à ce chemin sur le Mac. Le sélecteur ci-dessus ne transmet pas le chemin complet : choisis le fichier pour nommer la source, puis confirme son chemin ici.")));
    fileIn.addEventListener("change", () => {
      const f = fileIn.files && fileIn.files[0]; if (!f) return;
      nameEl.textContent = "Fichier choisi : " + f.name;
      if (!label.value.trim()) label.value = f.name.replace(/\.[^.]+$/, "");
    });
    const impBtn = ds.action({ label: "Importer", primary: true, onClick: async () => {
      errZone.replaceChildren(); path.removeAttribute("aria-invalid");
      const p = path.value.trim();
      if (!p) {
        adv.open = true;
        path.setAttribute("aria-invalid", "true");
        errZone.replaceChildren(h("div", { class: "field-err", role: "alert" }, "Chemin manquant : ouvre « Avancé » et donne le chemin du fichier sur le Mac — c'est lui que le moteur lira."));
        path.focus();
        return;
      }
      impBtn.disabled = true;
      try {
        const r = await api.post("/api/vault/import", { domain, path: p, label: label.value.trim() });
        if (r && r.ok === false) errZone.replaceChildren(h("div", { class: "field-err", role: "alert" }, maskText(String(r.error || "Import refusé."))));
        else { ctx.toast("Source importée dans le coffre."); if (!dead) loadAll(); }
      } catch (e) { errZone.replaceChildren(h("div", { class: "field-err", role: "alert" }, "Import impossible : " + maskText(errMsg(e)) + ".")); }
      impBtn.disabled = false;
    } });
    /* V5-Y : le formulaire d'import reste replié derrière « Importer une source… ». */
    const f = ds.fold("Importer une source…", h("div", { class: "moi-vlt-imp" },
      h("div", { class: "moi-vlt-imp-file" }, ds.action({ label: "Choisir un fichier…", onClick: () => fileIn.click() }), nameEl, fileIn),
      h("div", { class: "field" }, h("label", { class: "field-lb" }, "Nom de la source"), label),
      adv,
      h("div", { class: "moi-vlt-imp-go" }, impBtn),
      errZone));
    f.classList.add("moi-vlt-impfold");
    return f;
  }
  let lastStatus = {};
  function securityCard(st) {
    const enc = st.encryption || {};
    const sys = st.system || {};
    const hasCode = !!(st.code || st.configured);
    const list = h("div", { class: "ds-list" });
    const c = ds.card({ class: "moi-vlt-sec", flush: true }, list);
    const errZone = h("div", { class: "moi-vlt-pad" });
    const say = (msg) => errZone.replaceChildren(h("div", { class: "field-err", role: "alert" }, maskText(String(msg))));
    const ne = Number(enc.encrypted_files) || 0, nc = Number(enc.clear_files) || 0;
    const e = encState(st);
    if (e) {
      const algo = String(enc.algorithm || "");
      list.append(ds.row({ lead: "shield", title: "Chiffrement au repos", meta: enc.supported === false ? "Ce système n'offre pas le chiffrement au repos : les fichiers restent en clair." : enc.clear_mode ? maskText(enc.error || "Clé du Trousseau illisible.") + " Les fichiers restent en clair tant que la clé n'est pas lisible." : (ne ? plural(ne, "fichier") + " chiffré" + (ne > 1 ? "s" : "") + " · " : "") + (nc ? plural(nc, "fichier") + " encore en clair · " : "") + "AES-256-GCM, clé au Trousseau de ce Mac", side: ds.pill(e.tone === "ok" ? "Actif" : e.tone === "danger" ? "En clair" : e.canEncrypt ? (ne ? "Partiel" : "Pas activé") : "—", e.tone), tip: algo || null }));
    }
    const m = enc.migration;
    if (m && typeof m === "object") {
      const pb = [].concat(m.conflicts || [], m.errors || [], m.skipped || []);
      const nm = (m.migrated || []).length;
      const r = ds.row({ lead: "refresh", title: "Dernière migration", meta: (m.at ? fmtDateFR(m.at) : "—") + " · " + plural(nm, "fichier") + " chiffré" + (nm > 1 ? "s" : "") + (pb.length ? " · " + plural(pb.length, "point") + " à voir" : " · copies de secours chiffrées vérifiées (" + baseName(m.backup_dir || "coffre-sauvegardes") + ")"), side: ds.pill(pb.length ? "À voir" : "OK", pb.length ? "warn" : "ok") });
      if (pb.length) r.title = maskText(pb.map(baseName).join(" · "));
      list.append(r);
    }
    if (enc.error && !enc.clear_mode) list.append(ds.row({ lead: "alert", title: "Dernier incident", meta: maskText(String(enc.error)), side: ds.pill("Incident", "warn") }));
    /* 24/10 : la migration n'est JAMAIS automatique — Nova 1 lit ce même coffre en clair. Deux temps. */
    if (nc > 0 && enc.supported !== false && !enc.clear_mode) {
      const encBtn = ds.action({ label: "Chiffrer le coffre maintenant", primary: true, onClick: async () => {
        if (!encBtn.dataset.armed) { encBtn.dataset.armed = "1"; encBtn.lastChild.textContent = "Confirmer — Nova 1 ne pourra plus le lire"; setTimeout(() => { try { delete encBtn.dataset.armed; encBtn.lastChild.textContent = "Chiffrer le coffre maintenant"; } catch (e) {} }, 6000); return; }
        encBtn.disabled = true;
        try { const r = await vaultEncrypt(); ctx.toast(r.ok ? "Coffre chiffré au repos." : maskText(r.error || "Chiffrement refusé."), !r.ok); if (!dead) loadAll(); } catch (e) { ctx.toast("Le moteur ne répond pas.", true); }
        encBtn.disabled = false;
      } });
      const r = ds.row({ lead: "lock", title: plural(nc, "fichier") + " encore en clair", meta: "Appliqué seulement sur ton ordre : ta Nova 1 partage ce coffre et ne pourra plus le lire ensuite. Copie de secours chiffrée vérifiée avant tout remplacement.", actions: [encBtn] });
      r.id = "moi-vlt-encrypt";
      r.classList.add("moi-vlt-wrap");
      list.append(r);
    }
    list.append(ds.row({ lead: "look", title: "Ouverture", meta: sys.available ? (sys.biometry === "touchid" ? "Par Touch ID" : "Par le mot de passe du Mac") + (sys.message ? " · " + String(sys.message) : "") : (String(sys.message || "") || "Touch ID et mot de passe du Mac indisponibles pour Nova ici."), side: ds.pill(sys.available ? "Disponible" : "Indisponible", sys.available ? "ok" : "warn") }));

    /* Code du coffre (ajout / changement) — le moteur n'en garde qu'une empreinte salée. */
    const c1 = h("input", { type: "password", inputmode: "numeric", autocomplete: "off", class: "fld", placeholder: hasCode ? "Nouveau code" : "Code du coffre", "aria-label": hasCode ? "Nouveau code" : "Code du coffre" });
    const c2 = h("input", { type: "password", inputmode: "numeric", autocomplete: "off", class: "fld", placeholder: "Confirme le code", "aria-label": "Confirmation du code" });
    const save = ds.action({ label: hasCode ? "Changer le code" : "Ajouter un code", onClick: () => goSave() });
    const goSave = async () => {
      errZone.replaceChildren();
      if (String(c1.value).length < 4) { say("Code trop court (4 caractères minimum)."); c1.focus(); return; }
      if (c1.value !== c2.value) { say("Les deux codes ne correspondent pas."); c2.focus(); return; }
      save.disabled = true;
      try { const r = await vaultSetup(c1.value); if (r.ok) { ctx.toast(hasCode ? "Code changé." : "Code ajouté."); if (!dead) loadAll(); return; } say(r.error || "Refusé par le moteur."); }
      catch (e) { say("Le moteur ne répond pas."); }
      save.disabled = false;
    };
    c2.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); goSave(); } });
    c1.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); c2.focus(); } });
    const codeBlock = h("div", { class: "moi-vlt-pad moi-vlt-code" },
      h("div", { class: "moi-vlt-code-h" }, h("b", { class: "ds-h3" }, "Code du coffre"), ds.pill(hasCode ? "Défini" : "Aucun", hasCode ? "ok" : "neutral")),
      h("div", { class: "moi-vlt-code-f" }, c1, c2, save),
      h("p", { class: "ds-meta" }, "Le moteur n'en garde qu'une empreinte salée, jamais le code. Après 3 erreurs, délai croissant jusqu'à 15 min."));
    c.append(codeBlock);
    if (hasCode && sys.available) {
      const sf = st.second_factor === true;
      const tg = ds.action({ label: sf ? "Revenir au code en repli" : "Exiger aussi le code", onClick: async () => {
        tg.disabled = true;
        try { const r = await vaultSetMode(!sf); if (r.ok) { ctx.toast(!sf ? "Second facteur activé : Touch ID puis code." : "Le code redevient un simple repli."); if (!dead) loadAll(); return; } say(r.error); }
        catch (e) { say("Le moteur ne répond pas."); }
        tg.disabled = false;
      } });
      c.append(h("div", { class: "moi-vlt-pad moi-vlt-sf" }, h("div", { class: "moi-vlt-sf-t" }, h("b", { class: "ds-h3" }, "Second facteur"), h("span", { class: "ds-meta" }, sf ? "Actuel : Touch ID ou mot de passe du Mac, PUIS le code." : "Actuel : Touch ID ou mot de passe du Mac — le code sert de repli.")), tg));
    }
    if (ne > 0) {
      const rbZone = h("div", { class: "moi-vlt-rb" });
      const rb = ds.action({ label: "Préparer le retour arrière…", onClick: async () => {
        const appr = approvalCard({ title: "Écrire une copie EN CLAIR de chaque fichier du coffre ?", what: "Sert uniquement à revenir à une version de Nova sans chiffrement. Rien n'est supprimé ; un fichier clair déjà présent n'est pas écrasé. Ensuite : quitte Nova et reviens à la version précédente avant de rouvrir le coffre (procédure : conseil_24-10/V3_COFFRE.md).", approveLabel: "Écrire les copies claires", editLabel: null, refuseLabel: "Annuler" });
        rbZone.after(appr);
        const v = await appr.promise; appr.remove();
        if (v !== "approve" || dead) return;
        try { const r = await vaultRestoreClear(); if (r.ok) ctx.toast("Copies claires écrites : " + ((r.restored || []).length) + "."); else say(r.error || ("Échec : " + (r.errors || []).map(baseName).join(", "))); }
        catch (e) { say("Le moteur ne répond pas."); }
      } });
      rbZone.append(h("p", { class: "ds-meta" }, "À n'utiliser que pour revenir à une ancienne version de Nova."), rb);
      const adv = ds.fold("Avancé — retour arrière (copies en clair)", rbZone);
      adv.classList.add("moi-vlt-advfold");
      c.append(h("div", { class: "moi-vlt-pad" }, adv));
    }
    c.append(errZone);
    return c;
  }
  function render(fin, san) {
    const finCard = ds.card({ class: "moi-vlt-dom", flush: true });
    const sanCard = ds.card({ class: "moi-vlt-dom", flush: true });
    const finImp = importForm("finance"), sanImp = importForm("sante");
    finCard.append(sourceList(fin, "finance", finCard, finImp), h("div", { class: "moi-vlt-pad" }, finImp));
    sanCard.append(sourceList(san, "sante", sanCard, sanImp), h("div", { class: "moi-vlt-pad" }, sanImp));
    const nF = arrOf(fin, "sources").length, nS = arrOf(san, "sources").length;
    const e = encState(lastStatus);
    const encP = e ? ds.pill(e.label, e.tone) : null;
    if (encP) encP.title = e.tip || e.label;
    const secSec = ds.section({ title: "Sécurité", body: securityCard(lastStatus || {}) });
    secSec.id = "moi-vlt-sec";
    body.replaceChildren(
      h("div", { class: "moi-vlt-open" }, ds.pill("Ouvert", "ok"), encP, h("span", { class: "ds-meta" }, "Il se referme après 5 min sans activité, ou dès que tu quittes cet écran.")),
      ds.section({ title: "Finances", count: nF, body: finCard }),
      ds.section({ title: "Santé", count: nS, body: sanCard }),
      secSec,
      ds.fold("Comment le coffre protège tes données", h("p", { class: "ds-meta moi-vlt-proto" },
        "Les fichiers du coffre sont scellés (AES-256-GCM) avec une clé gardée dans le Trousseau de ce Mac. L'ouverture passe par Touch ID ou le mot de passe du Mac, vérifiés par le moteur ; le code, lui, n'est jamais stocké — seule une empreinte salée l'est. Sans ouverture, le moteur refuse toute lecture. Ouvertures, fermetures, refus et migrations sont inscrits au journal scellé.")));
  }
  return () => { dead = true; cleanups.forEach((f) => { try { f(); } catch (e) {} }); vaultLock(); };   // E3 : verrouillage automatique au changement d'écran
}
