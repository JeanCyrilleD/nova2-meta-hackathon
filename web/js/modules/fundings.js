/* Pipeline Fundings (Lot C 27/10) — les 50 programmes startups d'Ahadi en une
   seule vue : échéances à venir d'abord, puis en attente (sans réponse depuis
   le plus longtemps en tête), acquis, clos. Source : GET /api/fundings
   (campagne réelle, lecture seule). Aucune relance n'est envoyée d'ici. */
import { fmtTimeFR } from "../core.js";

const tsOf = (v) => { const d = Date.parse(v || ""); return isNaN(d) ? 0 : d; };
const daysSince = (ms) => ms ? Math.max(0, Math.round((Date.now() - ms) / 86400000)) : null;
const money = (n) => (typeof n === "number" && n > 0) ? n.toLocaleString("fr-FR") + " $" : "";

export async function mount(root, ctx) {
  const { api, h } = ctx;
  let dead = false;
  const head = h("div", { class: "mod-head" },
    h("h1", {}, "Fundings — pipeline"),
    h("span", { class: "sp" }),
    h("button", { type: "button", class: "btn sm", onclick: () => load() }, "Recharger"));
  const body = h("div", { class: "fund-body" });
  root.append(h("div", { class: "mod-fill" }, head, body));

  function section(titre, rows, note) {
    if (!rows.length) return null;
    return h("section", { class: "fund-sec" },
      h("h2", { class: "fund-h" }, titre + " · " + rows.length + (note ? " — " + note : "")),
      ...rows);
  }

  async function load() {
    if (dead) return;
    body.replaceChildren(h("div", { class: "ds-meta" }, "Lecture de la campagne…"));
    let d;
    try { d = await api.get("/api/fundings"); }
    catch (e) { if (!dead) body.replaceChildren(h("div", { class: "errbox" }, "Campagne injoignable — réessaie avec Recharger.")); return; }
    if (dead) return;
    const kids = [];

    const ech = (d.echeances || []).filter((e) => !e.passee).sort((a, b) => (a.days_left ?? 999) - (b.days_left ?? 999));
    if (ech.length) {
      kids.push(section("Échéances à venir", ech.map((e) => {
        const urg = (e.days_left ?? 99) <= 7;
        return h("div", { class: "fund-row" },
          h("span", { class: "fund-when" + (urg ? " fund-urg" : "") },
            e.days_left === 0 ? "Aujourd'hui" : "J-" + e.days_left),
          h("span", { class: "fund-main" }, h("b", {}, String(e.label || "")),
            h("span", { class: "ds-meta" }, " " + [e.date, e.heure, e.programme].filter(Boolean).join(" · "))));
      })));
    }

    const att = [...(d.en_attente || [])].sort((a, b) => tsOf(a.maj) - tsOf(b.maj));
    kids.push(section("En attente de décision", att.map((p) => {
      const nb = daysSince(tsOf(p.maj));
      return h("div", { class: "fund-row" },
        h("span", { class: "fund-when" + (nb !== null && nb >= 7 ? " fund-urg" : "") }, nb !== null ? "depuis " + nb + " j" : ""),
        h("span", { class: "fund-main" }, h("b", {}, String(p.programme || p.id || "?")),
          h("span", { class: "ds-meta" }, " — " + String(p.statut || "").slice(0, 150))),
        h("span", { class: "fund-amt" }, money(p.montant_vise_usd) || String(p.montant || "")));
    }), "sans réponse depuis le plus longtemps en tête"));

    const acq = d.acquis || [];
    const totalAcquis = acq.reduce((s, p) => s + (p.montant_acquis_usd || 0), 0);
    kids.push(section("Acquis" + (totalAcquis ? " — " + money(totalAcquis) + " confirmés" : ""), acq.map((p) =>
      h("div", { class: "fund-row" },
        h("span", { class: "fund-when" }, "✓"),
        h("span", { class: "fund-main" }, h("b", {}, String(p.programme || p.id || "?")),
          h("span", { class: "ds-meta" }, " — " + String(p.statut || "").slice(0, 130))),
        h("span", { class: "fund-amt" }, money(p.montant_acquis_usd) || String(p.montant || ""))))));

    const clos = d.clos || [];
    kids.push(section("Clos", clos.map((p) =>
      h("div", { class: "fund-row fund-dim" },
        h("span", { class: "fund-when" }, String(p.derniere_categorie || "clos").slice(0, 10)),
        h("span", { class: "fund-main" }, h("b", {}, String(p.programme || p.id || "?")),
          h("span", { class: "ds-meta" }, " — " + String(p.statut || "").slice(0, 130)))))));

    body.replaceChildren(...kids.filter(Boolean));
  }

  load();
  const timer = setInterval(load, 300000);
  return () => { dead = true; clearInterval(timer); };
}
