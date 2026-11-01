/* NOVA2 vague 3 — n°14 Profondeurs : le sélecteur RÉEL des modes de réflexion.
   Le moteur expose deux leviers, vérifiés dans le code (pas d'étiquette plaquée) :
   - « depth » (POST /api/chat → NovaApp.depthPrompt, Ame.swift) :
       0 = SURFACE (une à deux phrases, le fait seul),
       1 = réglage par défaut du prompt système,
       2 = PROFOND (faits, hypothèses, risques, recommandation, ce que Nova ne sait pas),
       3 = NUIT (réflexion lente et chaleureuse) ;
   - « mode » (Router.swift) : « deep » bascule la chaîne de cerveaux sur
     Catalog.deepOrder (les cerveaux d'analyse) au lieu de fastOrder.
   Éclair = depth 0 · Réfléchi = depth 1 · Conseil = depth 2 + mode « deep » · Nuit = depth 3.
   Le choix est mémorisé (localStorage) et vaut pour le chat d'accueil et l'écran Agent. */
import { api, h } from "./core.js";
import * as ds from "./ds.js";

export const DEPTHS = [
  { id: 0, label: "Éclair", hint: "Surface : une à deux phrases, le fait seul.", rank: 0, model: "muse-spark-1.3", outCap: 16000 },
  { id: 1, label: "Réfléchi", hint: "Le réglage par défaut de Nova.", rank: 1, model: "muse-spark-1.3", outCap: 16000 },
  { id: 2, label: "Conseil", hint: "Profond : faits, hypothèses, risques, recommandation — servis par la chaîne deepOrder.", rank: 2, model: "muse-wonder-1.0", outCap: 32000 },
  { id: 3, label: "Nuit", hint: "Réflexion lente et chaleureuse.", rank: 1, model: "muse-spark-1.3", outCap: 16000 },
];
/* PHASE 4 (31/10, v2 — décision d'Ahadi 19:51 : « on garde notre UI actuelle ») : les quatre profondeurs et leur
   rendu sont INCHANGÉS. Seul ajout : un choix qui AUGMENTE le coût (rank plus haut ; Nuit = même chaîne que Réfléchi)
   passe par confirmCostIncrease() — alerte chiffrée dans une carte .ds-card existante, boutons .ds-btn-* existants.
   Prix de repli ($ par million de jetons) = Config/brains.json du brief, vérifiés le 2026-10-31 ; la source qui fait foi
   sera le champ « prices » de GET /api/costs/summary quand la Phase 2 l'exposera (route absente au 31/10).
   Couper : faire renvoyer `true` d'emblée à confirmCostIncrease. */
const BRIEF_PRICES = { "muse-spark-1.3": { in: 1.25, out: 4.25 }, "muse-wonder-1.0": { in: 4.00, out: 20.00 } };
let livePrices = null;
async function prices() {
  if (livePrices) return livePrices;
  try {
    const j = await api.get("/api/costs/summary", 5000);
    if (j && Array.isArray(j.prices)) { const m = {}; for (const p of j.prices) if (p && p.model) m[p.model] = p; livePrices = { map: m, src: "grand livre" }; return livePrices; }
  } catch (e) {}
  return { map: BRIEF_PRICES, src: "prix du brief, vérifiés le 2026-10-31" };
}
export function depthInfo(id) { return DEPTHS.find((d) => d.id === Number(id)) || DEPTHS[1]; }
/** Texte court (≤ 240 car., pour un toast) décrivant la hausse de coût de `fromId` à `toId` ; null si pas de hausse. */
export async function costIncreaseText(fromId, toId) {
  const a = depthInfo(fromId), b = depthInfo(toId);
  if (b.rank <= a.rank) return null;
  const P = await prices(), pa = P.map[a.model], pb = P.map[b.model];
  const f = (x) => new Intl.NumberFormat("fr-FR", { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(x) + " $";
  return b.label + " coûte plus cher que " + a.label + (pa && pb ? " : " + pb.in + " / " + pb.out + " $ par million de jetons contre " + pa.in + " / " + pa.out + " $ ; jusqu'à " + f(b.outCap * pb.out / 1e6) + " par réponse au plafond de sortie." : ".");
}
/** Si passer de `fromId` à `toId` augmente le coût, affiche une alerte chiffrée après `anchor` et attend la réponse.
    Résout true (appliquer) ou false (garder la profondeur actuelle). Sans hausse : true tout de suite. */
export async function confirmCostIncrease(fromId, toId, anchor) {
  const a = depthInfo(fromId), b = depthInfo(toId);
  if (b.rank <= a.rank || !anchor || !anchor.parentNode) return true;
  const P = await prices();
  const pa = P.map[a.model], pb = P.map[b.model];
  const maxA = pa ? a.outCap * pa.out / 1e6 : null, maxB = pb ? b.outCap * pb.out / 1e6 : null;
  const f = (x) => new Intl.NumberFormat("fr-FR", { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(x) + " $";
  const old = anchor.parentNode.querySelector(".depth-costalert"); if (old) old.remove();
  return new Promise((resolve) => {
    const done = (v) => { box.remove(); resolve(v); };
    const box = ds.card({ title: b.label + " coûte plus cher que " + a.label, class: "depth-costalert" },
      h("p", { class: "ds-meta" }, (pb ? b.model + " : " + pb.in + " $ / " + pb.out + " $ par million de jetons (entrée / sortie)" : b.model + " : prix inconnu") +
        (pa ? " contre " + a.model + " : " + pa.in + " $ / " + pa.out + " $." : ".")),
      maxA != null && maxB != null ? h("p", { class: "ds-meta" }, "Une réponse au plafond de sortie (" + b.outCap.toLocaleString("fr-FR") + " jetons) peut coûter jusqu'à " + f(maxB) + ", contre " + f(maxA) + ". Plafond par tâche : 0,75 $.") : null,
      h("p", { class: "ds-meta" }, "Source des prix : " + P.src + ". Le coût réel s'affiche dans Coûts."),
      h("div", { class: "ds-actions" },
        ds.action({ label: "Passer en " + b.label, primary: true, onClick: () => done(true) }),
        ds.action({ label: "Garder " + a.label, ghost: true, onClick: () => done(false) })));
    box.setAttribute("role", "alertdialog");
    anchor.after(box);
    try { box.querySelector("button").focus(); } catch (e) {}
  });
}
export function getDepth() {
  try { const v = Number(localStorage.getItem("nova2_depth")); return DEPTHS.some((d) => d.id === v) ? v : 1; } catch (e) { return 1; }
}
export function depthBody(id) { return id === 2 ? { depth: 2, mode: "deep" } : { depth: id }; }
export function depthControl(onChange) {
  let cur = getDepth();
  const hint = h("span", { class: "ss" }, DEPTHS[cur].hint);
  /* §6.16/§9.9 : choix exclusif = .seg partout (avant : boutons .btn.acc, D-33). */
  const seg = h("div", { class: "seg", role: "group", "aria-label": "Profondeur de réflexion" });
  const box = h("div", { style: "display:flex;gap:6px;align-items:center;flex-wrap:wrap" },
    h("span", { class: "ss" }, "Profondeur :"), seg, hint);
  for (const d of DEPTHS) {
    const b = h("button", { class: d.id === cur ? "on" : "", title: d.hint, onclick: async () => {
      if (!(await confirmCostIncrease(cur, d.id, box))) return;   /* Phase 4 : alerte si le coût monte */
      cur = d.id;
      try { localStorage.setItem("nova2_depth", String(cur)); } catch (e) {}
      seg.querySelectorAll("button").forEach((x) => x.classList.remove("on")); b.classList.add("on");
      hint.textContent = d.hint;
      if (onChange) onChange(cur);
    } }, d.label);
    seg.append(b);
  }
  return box;
}
