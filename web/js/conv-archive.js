/* conv-archive.js — LOT3 (25/10/2026) : archivage des conversations, AUCUNE suppression.
   Moteur : Sources/NovaCore/Feat_ConvArchive.swift — champ « archived » de conversations.json :
     "manuel" (Archiver), "auto" (règle : « Commande shell », ou > 2 jours avec ≤ 2 messages), "non" (désarchivée, gardée).
   POST /api/conversations/archive {id, archived:true|false}. La liste par défaut masque manuel + auto ;
   le filtre « Archivées » les montre et permet de les ramener. */
import { api, h } from "./core.js";
import { ic } from "./icons.js";

export const isArchived = (meta) => { const a = String((meta && meta.archived) || ""); return a === "manuel" || a === "auto"; };

/** Puces « Actives / Archivées (n) » ; onPick(view). Retourne l'élément, .set(view, nArch). */
export function archiveFilter(onPick) {
  const bA = h("button", { type: "button", class: "ds-chip cs-arch-chip is-on", role: "radio", "aria-checked": "true" }, "Actives");
  const bR = h("button", { type: "button", class: "ds-chip cs-arch-chip", role: "radio", "aria-checked": "false" }, "Archivées");
  const n = h("span", { class: "ds-chip-n" });
  bR.append(n);
  const box = h("div", { class: "ds-chips cs-arch-filter", role: "radiogroup", "aria-label": "Filtre des conversations" }, bA, bR);
  let view = "actives";
  const paint = () => {
    bA.classList.toggle("is-on", view === "actives"); bA.setAttribute("aria-checked", view === "actives" ? "true" : "false");
    bR.classList.toggle("is-on", view === "archivees"); bR.setAttribute("aria-checked", view === "archivees" ? "true" : "false");
  };
  bA.addEventListener("click", () => { view = "actives"; paint(); onPick(view); });
  bR.addEventListener("click", () => { view = "archivees"; paint(); onPick(view); });
  box.set = (v, nArch) => { if (v) view = v; n.textContent = nArch ? String(nArch) : ""; paint(); };
  box.view = () => view;
  return box;
}

/** Bouton Archiver / Ramener d'une ligne de la liste (frère du bouton de ligne, jamais imbriqué). */
export function archiveButton(cid, archived, done, toast) {
  const label = archived ? "Ramener dans la liste" : "Archiver (rien n'est supprimé)";
  const b = h("button", { type: "button", class: "cs-row-arch", title: label, "aria-label": label, html: ic(archived ? "undo" : "inbox", 14) });
  b.addEventListener("click", async (e) => {
    e.stopPropagation();
    b.disabled = true;
    try {
      await api.post("/api/conversations/archive", { id: cid, archived: !archived }, 10000);
      if (toast) toast(archived ? "Conversation ramenée dans la liste." : "Conversation archivée — filtre « Archivées » pour la revoir.");
      if (done) done(!archived);
    } catch (err) {
      b.disabled = false;
      if (toast) toast("Archivage impossible : " + String((err && err.message) || err).replace(/^\/api\/conversations\/archive → \d+ : /, ""), true);
    }
  });
  return b;
}
