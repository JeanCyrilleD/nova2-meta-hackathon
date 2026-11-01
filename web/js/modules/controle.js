/* Module Contrôle — Nova pilote le Mac, à vue (vague 2, item 9).
   Inventaire RÉEL des surfaces de contrôle du moteur (vérifié dans le code) :
   - État : GET /api/system (instantané SystemInfo), GET /api/system/frontmost (app au
     premier plan), POST /api/tool {name:"ui", arg:"windows"|"screens"} (fenêtres/écrans —
     la route /api/tool n'autorise l'outil « ui » qu'en lecture : windows, screens).
   - Le pilotage fin (UIPilot.swift : ouvrir app/fichier/URL, clics, saisies, captures) passe
     par l'AGENT : ses ordres « app … » reviennent à CETTE fenêtre en événements SSE « ui »
     et c'est uibridge.js qui les exécute et répond (POST /api/ui/result) — constat réel ou
     « injoignable », jamais un « fait » sans preuve. Les boutons « Ouvrir… » ci-dessous
     préparent la tâche, la montrent en carte d'approbation, puis la confient à l'Agent.
   - État du Mac et journal des actions : PROPRIÉTÉ DE SYSTÈME (§9.4) — Contrôle ne les
     duplique plus ; il renvoie vers Système par une carte de section.
   - Délégations temporaires (GET/POST /api/delegate, /api/delegate/stop) : un sujet suivi
     jusqu'à une date, brouillons seulement — jamais d'envoi (moteur).
   - Actions natives de la coquille : plein écran Mac (win.fs), effacement des données du
     navigateur intégré (web.clearData, carte d'approbation d'abord). */
/* V6 (25/10) — refonte premium (contrat conseil_24-10/V6_DESIGN.md) : titre « Contrôle » (= menu) ;
   chaque section est une carte avec ses actions en barre ; les zones de résultat restent un état
   vide explicite (ds.empty) tant que rien n'a été lancé ; « Déléguer à l'Agent » en barre d'outils
   propre (champ + Ouvrir, puis gestes prêts) ; délégations en lignes ds avec statut. Routes et
   cartes d'approbation inchangées. */
import { approvalCard } from "../orb.js";
import { etatLabel, fmtDateFR } from "../core.js";
import * as ds from "../ds.js";

const arrOf = (j, ...keys) => { if (Array.isArray(j)) return j; for (const k of keys) if (j && Array.isArray(j[k])) return j[k]; return []; };
const setSecCount = (sec, n) => { let c = sec.querySelector(":scope > .ds-section-head > .ds-count"); if (!c) { c = document.createElement("span"); c.className = "ds-count"; const t = sec.querySelector(":scope > .ds-section-head > .ds-h2"); if (t) t.after(c); } c.textContent = String(n); };
const dayFR = (v) => { const s = fmtDateFR(v); return s || String(v || ""); };

export async function mount(root, ctx) {
  const { api, bus, h } = ctx;
  let dead = false;
  const native = () => window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nova;
  const toSysteme = { label: "Ouvrir Système", icon: "chev-r", onClick: () => ctx.navigate("systeme") };

  root.append(ds.pageHead({ title: "Contrôle", sub: "Ce que Nova voit et fait sur ce Mac — chaque geste sensible passe par une carte d'approbation.",
    actions: [{ label: "Actualiser", icon: "refresh", onClick: () => { loadMac(); loadAx(); loadDelegations(); } }] }));

  /* ── État du Mac : résumé honnête (§9.4 — Système reste propriétaire) ──
     V5-Y : sans donnée vivante, la section n'était qu'un renvoi vers Système — elle reste cachée tant
     que le moteur ne sert ni app au premier plan, ni allumage, ni mémoire libre. */
  const macBody = h("div", { class: "ct-kpis" });
  const macSec = ds.section({ title: "État du Mac", actions: [toSysteme], body: macBody });
  macSec.hidden = true;
  root.append(macSec);
  async function loadMac() {
    try {
      const j = await api.get("/api/system");
      if (dead || !j) return;
      const front = j.frontmost ?? j.front_app ?? j.frontApp ?? j.active_app ?? j.app;
      const up = j.uptime ?? j.boot_time ?? j.up_since ?? j.allume_depuis ?? j.depuis;
      const mem = j.mem_free ?? j.memory_free ?? j.free_mem ?? j.memoire_libre ?? j.memFree ?? j.free_memory;
      /* U5 (23/10) : scalaires seulement — un objet ne se rend JAMAIS (« [object Object] » et JSON brut interdits). */
      const scalarTxt = (x) => (typeof x === "string" && x.trim() !== "" ? x : (typeof x === "number" && isFinite(x) ? String(x) : ""));
      const items = [];
      const frontTxt = scalarTxt(front && typeof front === "object" ? (front.name || front.app || front.label || "") : front);
      if (frontTxt) items.push({ label: "App au premier plan", value: frontTxt });
      const upTxt = scalarTxt(up); if (upTxt) items.push({ label: "Allumé depuis", value: upTxt });
      const memTxt = scalarTxt(mem); if (memTxt) items.push({ label: "Mémoire libre", value: memTxt });
      if (!items.length) { macSec.hidden = true; return; }
      macSec.hidden = false;
      macBody.replaceChildren(ds.kpis(items));
    } catch (e) { /* section cachée : Système reste la référence */ }
  }
  loadMac();

  /* ── Fenêtres & écrans (outil ui en lecture) ─────────────────────── */
  const uiEmpty = () => ds.empty({ icon: "layers", compact: true, text: "Demande l'inventaire : Nova lit les fenêtres et écrans réels du Mac, en lecture seule." });
  const uiOut = h("div", { class: "ct-result" }, uiEmpty());
  root.append(ds.section({ title: "Fenêtres & écrans", body: ds.card({ class: "ct-card" },
    h("div", { class: "ct-bar" },
      ds.action({ label: "Lister les fenêtres", onClick: () => uiQuery("windows") }),
      ds.action({ label: "Lister les écrans", onClick: () => uiQuery("screens") }),
      ds.action({ label: "État système", ghost: true, tip: "Sortie de l'outil système, repliée", onClick: () => uiQuery("system") })),
    uiOut) }));
  async function uiQuery(arg) {
    uiOut.replaceChildren(ds.skeleton(2));
    try {
      const j = await api.post("/api/tool", { name: arg === "system" ? "system" : "ui", arg: arg === "system" ? "" : arg });
      if (dead) return;
      const out = String((j && j.output) || (j && j.error) || "");
      if (arg === "system") {   // D-23 : le brut système reste, mais replié et étiqueté
        uiOut.replaceChildren(ds.fold("Sortie technique de l'outil système", h("pre", { class: "pre-out ct-pre" }, out || "Aucune sortie."), true));
        return;
      }
      const lines = out.split("\n").map((l) => l.trim()).filter(Boolean);
      uiOut.replaceChildren(lines.length
        ? h("div", { class: "ds-list ct-lines" }, h("div", { class: "ds-meta ct-n" }, lines.length + (arg === "windows" ? (lines.length > 1 ? " fenêtres" : " fenêtre") : (lines.length > 1 ? " lignes" : " ligne"))),
          ...lines.map((l) => ds.row({ lead: arg === "windows" ? "layers" : "focus", title: l })))
        : ds.empty({ icon: "layers", compact: true, text: "Aucune ligne renvoyée par l'outil." }));
    } catch (e) { if (!dead) uiOut.replaceChildren(ds.errorBox({ title: "Outil injoignable", cause: "Le moteur n'a pas répondu à la lecture.", retry: () => uiQuery(arg) })); }
  }

  /* ── Pilotage par l'Accessibilité (VAGUE 3, AXPilot.swift) ──────────
     GET /api/ax/etat (droit macOS réel : AXIsProcessTrusted), POST /api/ax/test {app}
     (LECTURE SEULE de Notes ou Finder, jamais lancée ni activée), GET /api/ax/journal
     (actions AX lues dans la Boîte noire). Nova n'ouvre JAMAIS les Réglages d'elle-même. */
  const axState = h("div", { class: "ct-state" }, ds.skeleton(1));
  const axEmpty = () => ds.empty({ icon: "eye-off", compact: true, text: "Test en lecture seule : Nova lit la fenêtre de Notes ou du Finder sans l'activer ni rien modifier." });
  const axOut = h("div", { class: "ct-result" }, axEmpty());
  const axLog = h("div", { class: "ds-list" }, ds.skeleton(1));
  root.append(ds.section({ title: "Pilotage par l'Accessibilité", body: [
    h("p", { class: "ds-meta ct-desc" }, "Apps du Mac lues et pilotées en arrière-plan — jamais au premier plan."),
    ds.card({ class: "ct-card" },
      axState,
      h("div", { class: "ct-bar" },
        ds.action({ label: "Lire la fenêtre de Notes", onClick: () => axTest("Notes") }),
        ds.action({ label: "Lire la fenêtre du Finder", onClick: () => axTest("Finder") }),
        h("span", { class: "ds-meta" }, "Lecture seule : aucun clic, aucune saisie.")),
      axOut,
      h("h3", { class: "ds-h3 ct-sub" }, "Dernières actions (Boîte noire)"),
      axLog)] }));
  async function loadAx() {
    try {
      const j = await api.get("/api/ax/etat");
      if (dead) return;
      if (!j || typeof j.trusted !== "boolean") { axState.replaceChildren(ds.row({ lead: "question", title: "État de l'Accessibilité inconnu", meta: "Le moteur n'a pas répondu.", side: ds.pill("Inconnu", "neutral") })); }
      else axState.replaceChildren(ds.row({ lead: "shield", title: j.trusted ? "Accessibilité accordée" : "Accessibilité non accordée", meta: String(j.message || ""),
        side: ds.pill(j.trusted ? "Accordée" : "Non accordée", j.trusted ? "ok" : "danger") }));
    } catch (e) { if (!dead) axState.replaceChildren(ds.errorBox({ title: "État de l'Accessibilité injoignable", cause: "Le moteur n'a pas répondu.", retry: loadAx })); }
    try {
      const j = await api.get("/api/ax/journal");
      if (dead) return;
      const items = arrOf(j, "items");
      axLog.replaceChildren(...(items.length ? items.slice(0, 12).map((x) => ds.row({ title: String(x.why || "Action d'accessibilité"),
          meta: [x.ts ? new Date(x.ts).toLocaleString("fr-FR", { dateStyle: "medium", timeStyle: "short" }) : "", x.actor ? String(x.actor) : ""].filter(Boolean).join(" · "),
          side: ds.pill(x.ok ? "Réussie" : "À vérifier", x.ok ? "ok" : "warn") }))
        : [ds.empty({ icon: "journal", compact: true, text: "Aucune action d'accessibilité journalisée pour l'instant." })]));
    } catch (e) { if (!dead) axLog.replaceChildren(ds.errorBox({ title: "Journal injoignable", cause: "La Boîte noire n'a pas répondu.", retry: loadAx })); }
  }
  async function axTest(app) {
    axOut.replaceChildren(ds.skeleton(2));
    try {
      const j = await api.post("/api/ax/test", { app }, 30000);
      if (dead) return;
      const items = arrOf(j, "items");
      const head = h("div", { class: "ds-meta ct-n" }, String((j && j.text ? String(j.text).split("\n")[0] : "") || "Aucune réponse du moteur."));
      if (!items.length) { axOut.replaceChildren(head, ds.empty({ icon: "eye-off", compact: true, text: j && j.ok ? "Aucun élément exposé par cette fenêtre." : "Rien n'a été lu." })); loadAx(); return; }
      axOut.replaceChildren(head, h("div", { class: "ds-list ct-ax-list" }, ...items.map((x) => ds.row({
        lead: h("span", { class: "ct-idx" }, String(x.i)),
        title: String(x.title || x.desc || x.value || (x.secure ? "Champ mot de passe (jamais lu)" : "—")),
        meta: [String(x.role || ""), x.focus ? "focus" : "", Array.isArray(x.actions) && x.actions.length ? x.actions.slice(0, 3).join(", ") : ""].filter(Boolean).join(" · ") }))));
      loadAx();
    } catch (e) { if (!dead) axOut.replaceChildren(ds.errorBox({ title: "Lecture impossible", cause: "Le moteur n'a pas pu lire la fenêtre de " + app + ".", retry: () => axTest(app) })); }
  }
  loadAx();

  /* ── Déléguer à l'Agent (pilotage + uibridge) ───────────────────── */
  const openIn = h("input", { type: "text", placeholder: "Nom d'app, chemin de fichier ou URL (ex. Safari, ~/Documents, https://…)", class: "fld", "aria-label": "App, fichier ou URL à ouvrir" });
  const apprSlot = h("div", { class: "ct-appr" });
  async function askAgent(task, title) {
    const card = approvalCard({ title, what: "L'Agent va exécuter : « " + task + " ». Ses propres garde-fous demanderont encore avant tout geste sensible (envoi, suppression, paiement).", approveLabel: "Confier à l'Agent", refuseLabel: "Annuler" });
    apprSlot.replaceChildren(card);
    try { card.scrollIntoView({ block: "nearest", behavior: "smooth" }); } catch (e) {}
    const v = await card.promise; card.remove();
    if (v !== "approve") return;
    ctx.navigate("conversations");
    setTimeout(() => { if (!dead) bus.emit("nova:ask", { text: task }); }, 350);
  }
  const doOpen = () => { const v = openIn.value.trim(); if (!v) { openIn.focus(); ctx.toast("Indique une app, un fichier ou une URL.", true); return; } askAgent("Ouvre « " + v + " » et dis-moi ce que tu vois.", "Ouvrir dans le Mac"); };
  root.append(ds.section({ title: "Déléguer à l'Agent", body: [
    h("p", { class: "ds-meta ct-desc" }, "Ouvrir et piloter : après ta carte d'approbation, l'Agent exécute et renvoie un constat réel — rien n'est « fait » sans ce constat."),
    ds.card({ class: "ct-card" },
      h("div", { class: "ct-open" }, openIn, ds.action({ label: "Ouvrir", icon: "external", primary: true, onClick: doOpen })),
      h("div", { class: "ct-bar" },
        ds.action({ label: "Capture d'écran", onClick: () => askAgent("Fais une capture de l'écran du Mac et décris précisément ce qui est visible (ui-etat puis ui-lire).", "Capture d'écran") }),
        ds.action({ label: "Relais d'arrière-plan", tip: "Faire le tour des mails et Teams non lus et préparer les brouillons utiles", onClick: () => askAgent("Lance un relais d'arrière-plan : relais Faire le tour de mes mails et Teams non lus et préparer les brouillons de réponse utiles.", "Relais d'arrière-plan") }),
        ds.action({ label: "Ouvrir l'Agent", ghost: true, icon: "chev-r", onClick: () => ctx.navigate("conversations") })),
      apprSlot)] }));
  openIn.addEventListener("keydown", (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter") { e.preventDefault(); doOpen(); } });

  /* ── Délégations temporaires ─────────────────────────────────────── */
  const delBox = h("div", { class: "ds-list" }, ds.skeleton(1));
  const dSujet = h("input", { type: "text", id: "ct-d-sujet", placeholder: "Ex. GHO 2027 — réponses des directeurs régionaux", class: "fld" });
  const dUntil = h("input", { type: "date", id: "ct-d-until", class: "fld" });
  const dCons = h("input", { type: "text", id: "ct-d-cons", placeholder: "Facultatif", class: "fld" });
  const createDel = async () => {
    const sujet = dSujet.value.trim(), jusqua = dUntil.value;
    if (!sujet || !jusqua) { ctx.toast("Sujet et date de fin requis.", true); (sujet ? dUntil : dSujet).focus(); return; }
    try { const j = await api.post("/api/delegate", { sujet, jusqua, consignes: dCons.value.trim() }); if (j && j.error) { ctx.toast(String(j.error), true); return; } ctx.toast("Délégation créée jusqu'au " + dayFR(jusqua) + "."); dSujet.value = dCons.value = ""; loadDelegations(); }
    catch (e) { ctx.toast("Délégation refusée par le moteur.", true); }
  };
  const delSec = ds.section({ title: "Délégations temporaires", body: [
    h("p", { class: "ds-meta ct-desc" }, "Nova suit un sujet jusqu'à une date et prépare les brouillons — jamais d'envoi."),
    delBox,
    ds.card({ class: "ct-card ct-newdel" },
      h("h3", { class: "ds-h3" }, "Nouvelle délégation"),
      h("div", { class: "ct-fields" },
        h("div", { class: "ct-field ct-field--wide" }, h("label", { class: "ct-lb", for: "ct-d-sujet" }, "Sujet suivi"), dSujet),
        h("div", { class: "ct-field ct-field--date" }, h("label", { class: "ct-lb", for: "ct-d-until" }, "Jusqu'au"), dUntil),
        h("div", { class: "ct-field" }, h("label", { class: "ct-lb", for: "ct-d-cons" }, "Consignes"), dCons)),
      h("div", { class: "ct-foot" }, ds.action({ label: "Créer la délégation", primary: true, onClick: createDel })))] });
  root.append(delSec);
  /* FIX-WEB : Entrée valide, jamais pendant une composition IME. */
  for (const el of [dSujet, dCons]) el.addEventListener("keydown", (e) => { if (e.isComposing || e.keyCode === 229) return; if (e.key === "Enter") { e.preventDefault(); createDel(); } });

  /* ── Fenêtre Nova & journal : renvois ─────────────────────────────── */
  root.append(ds.section({ title: "Fenêtre et journal", body: ds.card({ flush: true, class: "ct-card ct-links" },
    ds.row({ lead: "maximize", title: "Plein écran du Mac", meta: "Passe la fenêtre de Nova en plein écran macOS.",
      actions: [{ label: "Plein écran", primary: true, onClick: () => { const n = native(); if (n) n.postMessage({ cmd: "win.fs", on: true }); else ctx.toast("Coquille native absente (aperçu web).", true); } }] }),
    /* Journal des actions : propriétaire unique = Système (§9.4) — l'annulation par carte vit dans Système. */
    ds.row({ lead: "journal", title: "Journal des actions", meta: "Ce que les outils du moteur ont fait, annulable par carte d'approbation — dans Système.",
      actions: [Object.assign({}, toSysteme, { primary: false })], onOpen: () => ctx.navigate("systeme") })) }));

  async function loadDelegations() {
    try {
      const j = await api.get("/api/delegate"); if (dead) return;
      const items = arrOf(j, "items");
      setSecCount(delSec, items.filter((d) => d.status === "active").length);
      delBox.replaceChildren(...(items.length ? items.map((d) => {
        const active = d.status === "active";
        const until = d.jusqua || d.until;
        return ds.row({ lead: "time", title: String(d.sujet || d.title || "Délégation"), meta: until ? "Jusqu'au " + dayFR(until) : "Sans date de fin",
          side: ds.pill(active ? "Active" : etatLabel(d.status, "Terminée"), active ? "ok" : "neutral"),
          actions: active ? [{ label: "Arrêter", danger: true, onClick: async () => { try { await api.post("/api/delegate/stop", { id: d.id }); ctx.toast("Délégation arrêtée."); } catch (e) { ctx.toast("Arrêt impossible : " + ((e && e.message) || e), true); } loadDelegations(); } }] : null });
      }) : [ds.empty({ icon: "time", compact: true, text: "Aucune délégation en cours.", action: { label: "Créer une délégation", onClick: () => dSujet.focus() } })]));
    } catch (e) { if (!dead) delBox.replaceChildren(ds.errorBox({ title: "Délégations injoignables", cause: "Le moteur n'a pas répondu.", retry: loadDelegations })); }
  }
  const offAct = bus.on("nova:action", loadDelegations);
  loadDelegations();
  /* FIX-WEB : rafraîchi au retour sur l'écran (module persistant), au plus toutes les 30 s. */
  let lastLoad = Date.now();
  return {
    destroy() { dead = true; try { offAct(); } catch (e) {} },
    onShow() { if (Date.now() - lastLoad < 30000) return; lastLoad = Date.now(); loadMac(); loadDelegations(); loadAx(); },
  };
}
