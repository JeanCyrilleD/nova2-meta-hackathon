/* V6 ÉCLATS (25/10) — retours d'Ahadi sur un passage d'Éclat : « Utile » / « Pas utile » / « Corriger… ».
   POST /api/dots/feedback {run_id, dot, verdict, note} ; le moteur garde les 30 derniers par Éclat et
   injecte « Leçons d'Ahadi » (5 dernières corrections + ratio) dans le prompt du passage suivant
   (Feat_EclatsDots.swift). Partagé par la carte d'Éclat (feedcard.js) et l'écran Éclats (agents.js). */
import { h, api } from "./core.js";

export function feedbackBar({ runId = "", dotId = "", current = "", onDone = null } = {}) {
  const box = h("div", { class: "efb", role: "group", "aria-label": "Ton retour sur ce passage" });
  const st = h("span", { class: "efb-st ds-meta", role: "status" });
  const noteIn = h("input", { type: "text", class: "fld efb-note", maxlength: "300", placeholder: "Ce qu'il faut corriger (une phrase)", "aria-label": "Correction" });
  const noteRow = h("div", { class: "efb-row", hidden: true });
  const send = async (verdict, note) => {
    try {
      await api.post("/api/dots/feedback", { run_id: String(runId), dot: String(dotId), verdict, note: note || "" }, 10000);
      box.dataset.v = verdict;
      st.textContent = verdict === "utile" ? "Noté : utile." : verdict === "pas_utile" ? "Noté : pas utile — l'Éclat en tiendra compte." : "Correction notée — elle sera une leçon au prochain passage.";
      noteRow.hidden = true;
      if (typeof onDone === "function") onDone(verdict);
    } catch (e) { st.textContent = "Retour impossible : " + ((e && e.message) || e); }
  };
  const mk = (label, verdict, fn) => {
    const b = h("button", { type: "button", class: "btn sm ds-btn-ghost efb-b", "data-v": verdict }, label);
    b.addEventListener("click", (e) => { e.stopPropagation(); fn(); });
    return b;
  };
  const okNote = h("button", { type: "button", class: "btn sm ds-btn-secondary" }, "Enregistrer");
  okNote.addEventListener("click", (e) => { e.stopPropagation(); const v = noteIn.value.trim(); if (!v) { noteIn.focus(); return; } send("corriger", v); });
  noteIn.addEventListener("keydown", (e) => { e.stopPropagation(); if (e.key === "Enter") okNote.click(); });
  noteIn.addEventListener("click", (e) => e.stopPropagation());
  noteRow.append(noteIn, okNote);
  box.append(h("div", { class: "efb-row" },
    mk("Utile", "utile", () => send("utile")),
    mk("Pas utile", "pas_utile", () => send("pas_utile")),
    mk("Corriger…", "corriger", () => { noteRow.hidden = !noteRow.hidden; if (!noteRow.hidden) noteIn.focus(); }),
    st), noteRow);
  if (current) box.dataset.v = current;
  return box;
}
