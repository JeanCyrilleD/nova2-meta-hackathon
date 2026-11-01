/* Suivi de dossiers (Lot F, 28/10) — GET/POST /api/dossiers.
   Un dossier = intitulé, échéance optionnelle, pièces cochables. C'est Ahadi
   qui crée ses dossiers ; Nova compte les pièces restantes et les jours avant
   échéance, sans rien deviner. Aucune action extérieure depuis cet écran. */
import { fmtDateFR } from "../core.js";

export async function mount(root, ctx) {
  const { api, h } = ctx;
  let dead = false;
  let items = [];

  const head = h("div", { class: "mod-head" },
    h("h1", {}, "Dossiers"),
    h("span", { class: "sp" }),
    h("button", { type: "button", class: "btn sm", onclick: () => load() }, "Recharger"));
  const sub = h("p", { class: "ds-meta" }, "Tes dossiers en cours : pièces à rassembler et échéances. Tu coches, Nova compte — rien d'autre ne bouge.");
  const listEl = h("div", { class: "doss-list" });

  // Création : intitulé, échéance, pièces (une par ligne).
  const titreIn = h("input", { type: "text", class: "fld", placeholder: "Intitulé (ex. Visa — mission)", "aria-label": "Intitulé du dossier" });
  const echIn = h("input", { type: "date", class: "fld", "aria-label": "Échéance" });
  const piecesIn = h("textarea", { class: "fld doss-pieces-in", rows: "3", placeholder: "Pièces, une par ligne\nPasseport\nRelevé bancaire 3 mois\nLettre d'invitation", "aria-label": "Pièces, une par ligne" });
  const createBtn = h("button", { type: "button", class: "btn sm", onclick: () => create() }, "Créer le dossier");
  const form = h("div", { class: "doss-form" },
    h("div", { class: "ds-h3" }, "Nouveau dossier"), titreIn, echIn, piecesIn, createBtn);
  root.append(h("div", { class: "mod-fill doss-body" }, head, sub, listEl, form));

  async function post(body) {
    try { const r = await api.post("/api/dossiers", body); if (r && r.items) { items = r.items; paint(); } return true; }
    catch (e) { try { ctx.toast("Dossier : " + String((e && e.message) || e), true); } catch (x) {} return false; }
  }
  async function create() {
    const titre = titreIn.value.trim();
    if (!titre) { ctx.toast("Intitulé manquant.", true); return; }
    createBtn.disabled = true;
    const ok = await post({ action: "save", titre, echeance: echIn.value || "", pieces: piecesIn.value, note: "" });
    createBtn.disabled = false;
    if (ok) { titreIn.value = ""; echIn.value = ""; piecesIn.value = ""; ctx.toast("Dossier créé."); }
  }

  function whenTxt(d) {
    if (!d.echeance) return "";
    const j = d.jours_restants;
    if (j == null) return fmtDateFR(d.echeance);
    if (j < 0) return "échéance dépassée de " + (-j) + " j (" + fmtDateFR(d.echeance) + ")";
    if (j === 0) return "échéance aujourd'hui";
    return "J-" + j + " · " + fmtDateFR(d.echeance);
  }

  function paint() {
    if (dead) return;
    if (!items.length) {
      listEl.replaceChildren(h("div", { class: "pane-note" }, "Aucun dossier. Crée le premier ci-dessous : un intitulé, une échéance, et la liste des pièces à rassembler."));
      return;
    }
    const cards = items.map((d) => {
      const clos = d.statut === "clos";
      const tot = d.pieces_total || 0, faits = d.pieces_faites || 0;
      const urg = !clos && d.jours_restants != null && d.jours_restants <= 7;
      const addIn = h("input", { type: "text", class: "fld doss-add", placeholder: "Ajouter une pièce…", "aria-label": "Ajouter une pièce" });
      addIn.addEventListener("keydown", (ev) => {
        if (ev.key === "Enter" && addIn.value.trim()) { post({ action: "piece_add", id: d.id, label: addIn.value.trim() }); }
      });
      const pieceRows = (Array.isArray(d.pieces) ? d.pieces : []).map((p) => {
        return h("div", { class: "doss-piece" + (p.fait ? " doss-done" : "") },
          h("input", { type: "checkbox", checked: !!p.fait,
            onchange: () => post({ action: "piece_toggle", id: d.id, piece: p.id }) }),
          h("span", { class: "doss-piece-label" }, String(p.label || "")),
          h("button", { type: "button", class: "btn sm ghost doss-x", title: "Retirer cette pièce",
            onclick: () => post({ action: "piece_remove", id: d.id, piece: p.id }) }, "×"));
      });
      return h("section", { class: "doss-card" + (clos ? " doss-clos" : "") },
        h("div", { class: "doss-head" },
          h("span", { class: "ds-h3" }, String(d.titre || "Dossier")),
          h("span", { class: "ds-meta" + (urg ? " doss-urg" : "") }, whenTxt(d)),
          h("span", { class: "ds-meta" }, tot ? faits + "/" + tot + " pièces" : "aucune pièce"),
          h("span", { class: "sp" }),
          h("button", { type: "button", class: "btn sm ghost",
            onclick: () => post({ action: "save", id: d.id, titre: d.titre, echeance: d.echeance || "", statut: clos ? "ouvert" : "clos", note: d.note || "" }) },
            clos ? "Rouvrir" : "Clore")),
        ...pieceRows,
        clos ? null : addIn,
        d.note ? h("div", { class: "ds-meta" }, String(d.note)) : null);
    });
    listEl.replaceChildren(...cards);
  }

  async function load() {
    if (dead) return;
    try { const j = await api.get("/api/dossiers"); items = (j && j.items) || []; }
    catch (e) { listEl.replaceChildren(h("div", { class: "errbox" }, "Dossiers injoignables — réessaie avec Recharger.")); return; }
    paint();
  }

  load();
  return () => { dead = true; };
}
