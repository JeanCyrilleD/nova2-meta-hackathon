/* couts.js — Phase 4 : TABLEAU DE BORD DES COÛTS (contrat : docs/PHASE4_CONTRATS.md §2).
   v2 (31/10, décision d'Ahadi 19:51 : « on garde notre UI actuelle ») : construit UNIQUEMENT avec les composants
   existants (ds.js : pageHead, section, kpis, card, empty ; tableau .ds-table) — aucune classe ni couleur nouvelle.
   Source attendue : GET /api/costs/summary (grand livre de la Phase 2, micro-dollars entiers). Vérifié le 31/10 dans la
   branche phase-2 : CostLedger.swift + RoutingV2.status() existent mais AUCUNE route HTTP n'est exposée ; l'écran montre
   donc un JEU SIMULÉ, signalé en tête — jamais présenté comme réel.
   Contenu : mois en cours contre le plafond dur (125 $), par profil et par modèle, réservations ouvertes,
   économies (cache de prompt, empreintes, batch), dates de vérification des prix (alerte au-delà de 30 jours).
   Couper : retirer l'entrée « couts » de MODULES (shell.js). */
import * as ds from "../ds.js";
import { usd } from "../tasks-feed.js";

export const SIMULATED = {
  simulated: true, month: "2026-10", timezone: "UTC",
  cap_usd_micro: 125000000, planned_usd_micro: 110000000, spent_usd_micro: 41270000, reserved_usd_micro: 480000,
  alert_thresholds_pct: [50, 80, 95],
  by_profile: [
    { profile: "main", spent_usd_micro: 17900000, calls: 412 }, { profile: "deep", spent_usd_micro: 9800000, calls: 21 },
    { profile: "triage", spent_usd_micro: 2100000, calls: 1630 }, { profile: "bulk_public", spent_usd_micro: 4300000, calls: 2210 },
    { profile: "long_public", spent_usd_micro: 3900000, calls: 14 }, { profile: "verify", spent_usd_micro: 1270000, calls: 38 },
    { profile: "reflex", spent_usd_micro: 600000, calls: 980 }, 
  ],
  by_model: [
    { model: "muse-spark-1.3", provider: "meta", spent_usd_micro: 17900000, allocated_usd_micro: 30000000, calls: 412 },
    { model: "muse-wonder-1.0", provider: "meta", spent_usd_micro: 9800000, allocated_usd_micro: 12000000, calls: 21 },
    { model: "meta-models/muse-spark-open", provider: "baseten", spent_usd_micro: 4300000, allocated_usd_micro: 10000000, calls: 2210 },
  ],
  reservations: [
    { id: "r-sim-1", task_id: "sim-cafu-2", model: "muse-wonder-1.0", profile: "deep", reserved_usd_micro: 420000, at: "2026-10-31T18:40:12Z" },
    { id: "r-sim-2", task_id: "sim-mail-1", model: "muse-spark-1.3", profile: "main", reserved_usd_micro: 60000, at: "2026-10-31T18:41:03Z" },
  ],
  savings: { cache_usd_micro: 6120000, fingerprint_usd_micro: 1880000, fingerprint_hits: 342, batch_usd_micro: 2950000 },
  prices: [
    { model: "muse-spark-1.3", in: 1.25, out: 4.25, verified: "2026-10-31" }, { model: "muse-wonder-1.0", in: 4.0, out: 20.0, verified: "2026-10-31" },
    { model: "meta-models/muse-spark-open", in: 1.25, out: 4.25, verified: "2026-11-01", note: "Baseten" },
  ],
};

const dayAge = (ymd, now = new Date()) => { const d = Date.parse(String(ymd || "") + "T00:00:00Z"); return isNaN(d) ? null : Math.floor((now.getTime() - d) / 86400000); };
const n2 = (x) => new Intl.NumberFormat("fr-FR", { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(x);

export async function mount(root, ctx) {
  const { h, api } = ctx;
  root.classList.add("mod--data");
  let data = null, reason = "";
  try { data = await api.get("/api/costs/summary", 10000); if (!data || data.cap_usd_micro == null) throw new Error("réponse sans cap_usd_micro"); }
  catch (e) { data = SIMULATED; reason = String((e && e.message) || e); }
  const sim = !!data.simulated || !!reason;
  const cap = Number(data.cap_usd_micro), spent = Number(data.spent_usd_micro || 0), resv = Number(data.reserved_usd_micro || 0);
  const left = cap - spent - resv;
  const table = (cols, rows) => h("div", { class: "ds-table-wrap" }, h("table", { class: "ds-table" },
    h("thead", {}, h("tr", {}, ...cols.map((c) => h("th", { scope: "col", class: c.num ? "num" : "" }, c.t)))),
    h("tbody", {}, ...rows.map((r) => h("tr", {}, ...cols.map((c) => h("td", { class: c.num ? "num" : "" }, c.f(r))))))));
  const sortSpent = (a) => (a || []).slice().sort((x, y) => Number(y.spent_usd_micro) - Number(x.spent_usd_micro));
  const prices = (data.prices || []).map((p) => ({ ...p, age: dayAge(p.verified) }));
  const stale = prices.filter((p) => p.age == null || p.age > 30);
  const sv = data.savings || {};
  const th = (data.alert_thresholds_pct || []).filter((p) => spent + resv >= cap * p / 100);
  root.append(
    ds.pageHead({ title: "Coûts", sub: "Mois " + (data.month || "en cours") + " (" + (data.timezone || "UTC") + ") · plafond dur " + usd(cap, 0) + ", appliqué avant chaque appel." }),
    sim ? ds.card({ muted: true }, h("p", { class: "ds-meta" }, "Données simulées : le grand livre de la Phase 2 n'expose pas encore GET /api/costs/summary" + (reason ? " (" + reason + ")" : "") + ". Aucun chiffre ci-dessous n'est réel.")) : null,
    ds.section({ title: "Ce mois", body: [
      ds.kpis([{ label: "Dépensé", value: usd(spent, 2) }, { label: "Réservé (appels en vol)", value: usd(resv, 2) },
        { label: "Reste", value: usd(left, 2), alert: left < 0 }, { label: "Plafond", value: usd(cap, 0), delta: data.planned_usd_micro ? "prévu " + usd(data.planned_usd_micro, 0) + " + réserve" : null }]),
      h("p", { class: "ds-meta" }, "Seuils d'alerte : " + (data.alert_thresholds_pct || []).map((p) => usd(cap * p / 100, 2)).join(" / ") + (th.length ? " — franchi : " + usd(cap * th[th.length - 1] / 100, 2) : " — aucun franchi")) ] }),
    ds.section({ title: "Par profil", body: table([{ t: "Profil", f: (r) => r.profile }, { t: "Appels", num: 1, f: (r) => String(r.calls ?? "—") }, { t: "Dépensé", num: 1, f: (r) => usd(r.spent_usd_micro, 2) }], sortSpent(data.by_profile)) }),
    ds.section({ title: "Par modèle", body: table([{ t: "Modèle", f: (r) => r.model }, { t: "Dépensé", num: 1, f: (r) => usd(r.spent_usd_micro, 2) }, { t: "Enveloppe", num: 1, f: (r) => r.allocated_usd_micro != null ? usd(r.allocated_usd_micro, 0) : "—" }], sortSpent(data.by_model)) }),
    ds.section({ title: "Réservations ouvertes", count: (data.reservations || []).length, body: (data.reservations || []).length
      ? table([{ t: "Tâche", f: (r) => r.task_id || "—" }, { t: "Modèle", f: (r) => r.model }, { t: "Réservé", num: 1, f: (r) => usd(r.reserved_usd_micro) }], data.reservations)
      : ds.empty({ text: "Aucune réservation ouverte.", compact: true }) }),
    ds.section({ title: "Économies du mois", body: ds.kpis([{ label: "Cache de prompt", value: usd(sv.cache_usd_micro, 2) },
      { label: "Empreintes (Dots inchangés)", value: usd(sv.fingerprint_usd_micro, 2), delta: sv.fingerprint_hits != null ? sv.fingerprint_hits + " appels évités" : null },
      { label: "Batch", value: usd(sv.batch_usd_micro, 2) }]) }),
    ds.section({ title: "Prix et date de vérification", body: [
      stale.length ? ds.card({ alert: true }, h("p", { class: "ds-meta", role: "status" }, stale.length + (stale.length > 1 ? " prix ont" : " prix a") + " plus de 30 jours ou aucune date : " + stale.map((p) => p.model).join(", ") + ". À revérifier dans la documentation officielle avant de s'y fier."))
        : h("p", { class: "ds-meta" }, "Tous les prix ont été vérifiés il y a 30 jours ou moins."),
      table([{ t: "Modèle", f: (r) => r.model }, { t: "Entrée $/M", num: 1, f: (r) => n2(r.in) }, { t: "Sortie $/M", num: 1, f: (r) => n2(r.out) },
        { t: "Vérifié le", f: (r) => h("span", {}, (r.verified || "—") + (r.age != null ? " (" + r.age + " j)" : "") + (r.note ? " — " + r.note : "") + " ", r.age == null || r.age > 30 ? ds.pill("À revérifier", "warn") : null) }], prices) ] }));
  return () => {};
}
