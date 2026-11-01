/* Module Outils — V5-G (24/10) : les capacités du moteur qui n'avaient pas d'écran.
   1) Outils forgés par Nova (Forge.swift) : GET /api/forge/outils — registre réel
      [{name, kind, path, attempts, ts, state, checked?, last_error?, retired?, trashed?}].
      Actions : POST /api/forge/recheck {name} (test de santé seul, bac à sable, aucune
      correction par un cerveau) et POST /api/forge/retire {name} (fichier à la Corbeille,
      entrée conservée « retire » — jamais d'effacement définitif).
   2) Points de restauration (Feat_Checkpoints.swift) : GET /api/checkpoints?last=N —
      [{id, ts, tool, created, path?, backupPath?, eventId?, undone?, undoneAt?}] ;
      POST /api/checkpoints/undo {id}. Seules les modifications de FICHIERS sont
      restaurables ici : le moteur sauvegarde d'abord la version actuelle (backups-fichiers)
      ou met le fichier créé à la Corbeille. L'annulation d'un événement, d'un rappel ou
      d'une note est une suppression : elle n'est pas proposée sur cet écran. */
import { fmtDateFR, fmtTimeFR, fmtRelFR } from "../core.js";
import { approvalCard } from "../orb.js";
import * as ds from "../ds.js";
/* V6 (25/10) — refonte premium (contrat conseil_24-10/V6_DESIGN.md) : en-tête ds ; outils forgés et points
   de restauration en lignes ds (nom de fichier, action, date ; chemin en méta tronquée avec infobulle) ;
   Revérifier / Restaurer / Annuler en boutons secondaires ; états vide (avec action), chargement, erreur.
   Routes et cartes d'approbation inchangées. */
const setSecCount = (sec, n) => { let c = sec.querySelector(":scope > .ds-section-head > .ds-count"); if (!c) { c = document.createElement("span"); c.className = "ds-count"; const t = sec.querySelector(":scope > .ds-section-head > .ds-h2"); if (t) t.after(c); } c.textContent = String(n); };
/* Nom d'outil forgé (identifiant « convertir_csv_brvm ») → libellé lisible ; l'identifiant reste en infobulle. */
const toolLabel = (n) => { const t = String(n || "outil").replace(/\.[a-z0-9]+$/i, "").replace(/[_-]+/g, " ").trim(); return t ? t[0].toUpperCase() + t.slice(1) : "Outil"; };

const FILE_TOOLS = new Set(["write_file", "edit_file"]);
const OTHER_LABEL = { calendar_add: "événement ajouté", reminder_add: "rappel ajouté", note_add: "note ajoutée" };
const KIND_LABEL = { sh: "zsh", zsh: "zsh", py: "Python", python: "Python", js: "Node", node: "Node" };

export async function mount(root, ctx) {
  const { api, h, ic } = ctx;
  let dead = false;
  root.classList.add("og");
  const when = (v) => { const d = v ? new Date(v) : null; return d && !isNaN(d) ? fmtDateFR(d) + " · " + fmtTimeFR(d) : "date inconnue"; };
  const base = (p) => String(p || "").split("/").filter(Boolean).pop() || String(p || "");
  const shortPath = (p) => String(p || "").replace(/^\/Users\/[^/]+/, "~");
  const errText = (e) => (e && e.body && (e.body.message || e.body.error)) || (e && e.message) || String(e);

  root.append(ds.pageHead({ title: "Outils", sub: "Ce que Nova a fabriqué et modifié pour toi — vérifiable, réversible.",
    actions: [{ label: "Actualiser", icon: "refresh", onClick: () => { loadForge(); loadChecks(); } }] }));

  const forgeBox = h("div", { class: "ds-list og-list", "aria-live": "polite" });
  const ckBox = h("div", { class: "ds-list og-list", "aria-live": "polite" });
  const ckMore = h("div", { class: "og-foot" });
  const forgeSec = ds.section({ title: "Outils forgés par Nova", body: [
    h("p", { class: "ds-meta og-desc" }, "Quand aucun outil existant ne convient, Nova écrit un petit script. Il n'est enregistré qu'après un test de santé en bac à sable (3 s, sans réseau, écriture limitée à un dossier temporaire)."),
    ds.card({ flush: true, class: "og-card" }, forgeBox)] });
  const ckSec = ds.section({ title: "Points de restauration", body: [
    h("p", { class: "ds-meta og-desc" }, "Avant chaque écriture de fichier, Nova en garde une copie. Restaurer remet la version précédente en place ; la version actuelle est d'abord sauvegardée, rien n'est perdu."),
    ds.card({ flush: true, class: "og-card" }, ckBox), ckMore] });
  root.append(forgeSec, ckSec);

  const skel = (box) => box.replaceChildren(ds.skeleton(2));
  const errBox = (box, msg, retry) => box.replaceChildren(ds.errorBox({ title: "Impossible de charger", cause: msg, retry }));
  const placeCard = (anchor, card) => { const old = root.querySelector(".og-confirm"); if (old) old.remove(); card.classList.add("og-confirm"); anchor.after(card); try { card.scrollIntoView({ block: "nearest", behavior: "smooth" }); } catch (e) {} };

  /* ── Outils forgés ─────────────────────────────────────────────── */
  const stateOf = (t) => {
    const s = String(t.state || "");
    if (s === "retire") return { tone: "neutral", lb: "Retiré" };
    if (s === "en_echec") return { tone: "danger", lb: "En échec" };
    if (s === "operationnel") return { tone: "ok", lb: "Opérationnel" };
    return { tone: "neutral", lb: "État inconnu" };
  };
  function toolRow(t) {
    const name = String(t.name || "outil");
    const st = stateOf(t);
    const retired = t.state === "retire";
    const meta = [KIND_LABEL[t.kind] || String(t.kind || "script"), "créé le " + when(t.ts), t.attempts ? (Number(t.attempts) === 1 ? "sain dès le 1er essai" : "sain au " + t.attempts + "ᵉ essai") : "",
      t.checked ? "revérifié " + fmtRelFR(t.checked) : "", retired && t.retired ? "retiré le " + when(t.retired) : "",
      retired ? (t.trashed ? "fichier dans la Corbeille, récupérable" : "fichier déjà absent") : "",
      t.state === "en_echec" && t.last_error ? "dernière erreur : " + String(t.last_error) : ""].filter(Boolean).join(" · ");
    const metaEl = h("span", { title: [t.path && !retired ? shortPath(t.path) : "", t.state === "en_echec" && t.last_error ? String(t.last_error) : ""].filter(Boolean).join("\n") || meta }, meta);
    const acts = [];
    let row = null;
    const fail = (msg) => ctx.toast(msg, true);
    if (!retired) {
      const check = ds.action({ label: "Revérifier", tip: "Relancer le test de santé en bac à sable (sans correction automatique)" });
      check.addEventListener("click", async () => {
        check.disabled = true; check.lastChild.textContent = "Test en cours…";
        try {
          const j = await api.post("/api/forge/recheck", { name }, 30000);
          if (dead) return;
          ctx.toast((j && j.ok ? "« " + toolLabel(name) + " » est sain. " : "« " + toolLabel(name) + " » échoue : ") + String((j && j.message) || ""), !(j && j.ok));
          loadForge();
        } catch (e) {
          if (dead) return;
          check.disabled = false; check.lastChild.textContent = "Revérifier";
          fail(e && e.status === 404 ? "Ce moteur ne connaît pas encore la revérification : relance Nova après la mise à jour." : "Revérification impossible : " + errText(e));
        }
      });
      const retire = ds.action({ label: "Retirer", icon: "trash", ghost: true, tip: "Mettre le fichier de l'outil à la Corbeille (récupérable)" });
      retire.addEventListener("click", async () => {
        const card = approvalCard({ title: "Retirer l'outil « " + toolLabel(name) + " » ?",
          what: "Son fichier (" + shortPath(t.path || "") + ") part à la Corbeille du Mac — récupérable. L'outil reste listé ici comme « retiré » ; rien n'est effacé définitivement.",
          approveLabel: "Retirer", refuseLabel: "Garder", editLabel: null });
        placeCard(row, card);
        const v = await card.promise; card.remove();
        if (v !== "approve" || dead) return;
        retire.disabled = true;
        try {
          const j = await api.post("/api/forge/retire", { name });
          if (dead) return;
          ctx.toast(String((j && j.message) || "Outil retiré."), !(j && j.ok));
          loadForge();
        } catch (e) {
          if (dead) return;
          retire.disabled = false;
          fail(e && e.status === 404 ? "Ce moteur ne connaît pas encore le retrait : relance Nova après la mise à jour." : "Retrait impossible : " + errText(e));
        }
      });
      acts.push(check, retire);
    }
    row = ds.row({ lead: "zap", title: toolLabel(name), tip: "Outil « " + name + " »", meta: metaEl, side: ds.pill(st.lb, st.tone), actions: acts });
    row.classList.toggle("is-off", retired);
    row.dataset.tool = name;
    return row;
  }
  async function loadForge() {
    if (!forgeBox.childElementCount) skel(forgeBox);
    try {
      const j = await api.get("/api/forge/outils");
      if (dead) return;
      const items = Array.isArray(j && j.items) ? j.items.filter((x) => x && typeof x === "object") : [];
      if (!items.length) { setSecCount(forgeSec, 0); forgeBox.replaceChildren(ds.empty({ icon: "zap", text: "Aucun outil forgé pour l'instant. Nova n'en crée un que si aucun outil existant ne suffit — et la création te demande ton accord.", action: { label: "Voir la règle dans Confiance", ghost: true, onClick: () => ctx.navigate("confiance") } })); return; }
      const order = (t) => (t.state === "retire" ? 1 : 0);
      items.sort((a, b) => order(a) - order(b) || String(b.ts || "").localeCompare(String(a.ts || "")));
      const live = items.filter((t) => t.state !== "retire").length;
      setSecCount(forgeSec, live);
      forgeBox.replaceChildren(h("div", { class: "ds-meta og-count" }, live + (live > 1 ? " outils en service" : " outil en service") + (items.length > live ? " · " + (items.length - live) + " retiré" + (items.length - live > 1 ? "s" : "") : "")), ...items.map(toolRow));
    } catch (e) { if (!dead) errBox(forgeBox, "Registre des outils forgés illisible — le moteur ne répond pas.", loadForge); }
  }

  /* ── Points de restauration ────────────────────────────────────── */
  let ckLimit = 40;
  function ckRow(c) {
    const p = String(c.path || "");
    const undone = c.undone === true;
    const created = c.created === true;
    const hasBackup = !!c.backupPath;
    const what = created ? "Créé par Nova" : (c.tool === "edit_file" ? "Modifié par Nova" : "Réécrit par Nova");
    /* Méta : action · date · chemin (tronqué par la ligne ; chemin complet en infobulle). */
    const metaEl = h("span", { class: "og-meta", title: shortPath(p) },
      [what, when(c.ts), undone && c.undoneAt ? "annulé le " + when(c.undoneAt) : ""].filter(Boolean).join(" · "),
      h("span", { class: "og-path" }, " · " + shortPath(p)));
    const acts = [];
    let row = null;
    if (!undone) {
      let label = "", title = "", whatTxt = "";
      if (hasBackup) {
        label = "Restaurer";
        title = "Restaurer la version précédente ?";
        whatTxt = "« " + shortPath(p) + " » reprend la version sauvegardée avant l'écriture de Nova du " + when(c.ts) + ". La version actuelle est d'abord copiée dans backups-fichiers : rien n'est perdu.";
      } else if (created) {
        label = "Annuler la création";
        title = "Annuler la création de ce fichier ?";
        whatTxt = "« " + shortPath(p) + " » a été créé par Nova le " + when(c.ts) + ". Il part à la Corbeille du Mac — récupérable, jamais effacé définitivement.";
      }
      if (label) {
        const b = ds.action({ label, icon: "undo", tip: hasBackup ? "Remettre la version précédente en place" : "Mettre ce fichier à la Corbeille (récupérable)" });
        b.addEventListener("click", async () => {
          const card = approvalCard({ title, what: whatTxt, approveLabel: hasBackup ? "Restaurer" : "Mettre à la Corbeille", refuseLabel: "Garder", editLabel: null });
          placeCard(row, card);
          const v = await card.promise; card.remove();
          if (v !== "approve" || dead) return;
          b.disabled = true;
          try {
            const j = await api.post("/api/checkpoints/undo", { id: String(c.id || "") });
            if (dead) return;
            if (j && j.ok) { ctx.toast(String(j.message || "Restauré.")); loadChecks(); }
            else { b.disabled = false; ctx.toast(String((j && j.message) || "Le moteur n'a rien restauré."), true); }
          } catch (e) { if (dead) return; b.disabled = false; ctx.toast("Restauration impossible : " + errText(e), true); }
        });
        acts.push(b);
      }
    }
    row = ds.row({ lead: "file", title: base(p), tip: shortPath(p), meta: metaEl,
      side: undone ? ds.pill("Restauré", "neutral") : (acts.length ? null : h("span", { class: "ds-meta" }, "sauvegarde absente")), actions: acts });
    row.classList.toggle("is-off", undone);
    row.dataset.ck = String(c.id || "");
    return row;
  }
  async function loadChecks() {
    if (!ckBox.childElementCount) skel(ckBox);
    try {
      const j = await api.get("/api/checkpoints?last=" + ckLimit);
      if (dead) return;
      const all = Array.isArray(j && j.items) ? j.items.filter((x) => x && typeof x === "object") : [];
      const files = all.filter((c) => FILE_TOOLS.has(String(c.tool || "")) && c.path);
      const others = all.filter((c) => !FILE_TOOLS.has(String(c.tool || "")));
      ckMore.replaceChildren();
      if (others.length) {
        const counts = {};
        for (const o of others) { const k = OTHER_LABEL[o.tool] || "autre action"; counts[k] = (counts[k] || 0) + 1; }
        ckMore.append(h("div", { class: "ds-meta" }, "Aussi dans ces points : " + Object.entries(counts).map(([k, n]) => n + " " + k + (n > 1 ? "s" : "")).join(", ") + ". Leur annulation est une suppression : elle reste dans la conversation, carte par carte."));
      }
      if (all.length >= ckLimit && ckLimit < 200) ckMore.append(ds.action({ label: "Voir plus ancien", ghost: true, onClick: () => { ckLimit = 200; loadChecks(); } }));
      setSecCount(ckSec, files.filter((c) => c.undone !== true).length);
      if (!files.length) { ckBox.replaceChildren(ds.empty({ icon: "undo", text: "Aucune modification de fichier par Nova. Dès qu'elle écrit ou modifie un fichier, sa version précédente apparaît ici, prête à être remise en place.", action: { label: "Voir les actions dans Système", ghost: true, onClick: () => ctx.navigate("systeme") } })); return; }
      ckBox.replaceChildren(...files.map(ckRow));
    } catch (e) { if (!dead) errBox(ckBox, "Points de restauration illisibles — le moteur ne répond pas.", loadChecks); }
  }

  await Promise.all([loadForge(), loadChecks()]);
  return { destroy: () => { dead = true; }, onShow: () => { if (!dead) { loadForge(); loadChecks(); } } };
}
