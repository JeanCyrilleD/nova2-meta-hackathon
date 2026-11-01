/* 25/10 — AUTOTEST DE LA NUIT (écran Système). Le moteur (Feat_Autotest.swift) se teste à 03:30 : cerveaux
   (cerveaux Meta), sources de courrier, agenda, BRVM, TV, échecs d'Éclats, disque et
   batterie. GET /api/autotest/last (dernier passage + 14 derniers), POST /api/autotest/run (relance, < 60 s).
   Chaque ligne : contrôle, détail mesuré, durée, pastille OK / KO (cause probable) / sans objet. */
import * as ds from "../ds.js";
import { fmtDateFR, fmtTimeFR } from "../core.js";

export function autotestSection(ctx, isDead) {
  const { api, h } = ctx;
  const box = h("div", { class: "sy-at" }, ds.skeleton(2));
  const dead = () => { try { return !!isDead(); } catch (e) { return false; } };
  const when = (iso) => { const d = new Date(iso); return isNaN(d) ? "" : fmtDateFR(d) + " " + fmtTimeFR(d); };
  const secs = (ms) => (Number(ms) >= 1000 ? (Number(ms) / 1000).toFixed(1).replace(".", ",") + " s" : String(Number(ms) || 0) + " ms");
  let busy = false;
  const runBtn = ds.action({ label: "Relancer", icon: "refresh", tip: "Relancer l'autotest maintenant (moins d'une minute)", onClick: () => runNow() });
  const sec = ds.section({ title: "Autotest de la nuit", actions: [runBtn], body: box });

  function line(c) {
    let pill;
    if (c.skip) pill = ds.pill("Sans objet", "neutral");
    else if (c.ok) pill = ds.pill("OK", "ok");
    else pill = ds.pill("KO", "danger");
    const meta = [String(c.detail || "")];
    if (!c.ok && !c.skip && c.cause) meta.push("Cause probable : " + String(c.cause));
    const r = ds.row({ title: String(c.label || c.id || ""), meta: meta.filter(Boolean).join(" · ") || null,
      side: h("span", { class: "sy-measure" }, h("span", { class: "sy-vt ds-meta" }, secs(c.ms)), pill) });
    r.classList.add("sy-wrap");
    if (!c.ok && !c.skip) r.classList.add("sy-at-ko");
    return r;
  }
  function paint(j) {
    const last = j && j.last;
    if (!last) {
      box.replaceChildren(ds.empty({ text: "Aucun passage encore : le premier aura lieu cette nuit à " + String((j && j.heure) || "03:30") + " — ou « Relancer ».", compact: true }));
      return;
    }
    const checks = Array.isArray(last.checks) ? last.checks : [];
    const ko = checks.filter((c) => !c.ok && !c.skip);
    const groups = [];
    for (const c of checks) { const g = String(c.groupe || "Autres"); let e = groups.find((x) => x.g === g); if (!e) { e = { g, items: [] }; groups.push(e); } e.items.push(c); }
    const hist = Array.isArray(j.history) ? j.history.slice(1, 8) : [];
    box.replaceChildren(
      ds.kpis([
        { label: "Contrôles OK", value: String(last.ok_n || 0) + "/" + String(last.total || 0), alert: ko.length > 0 },
        { label: "En échec", value: String(ko.length), alert: ko.length > 0 },
        { label: "Durée", value: secs(last.ms) },
        { label: "Passage", value: when(last.ts), tip: String(last.raison || "") },
      ]),
      ...groups.map((e) => ds.card({ flush: true, class: "sy-at-g" }, h("div", { class: "sy-cap" }, e.g), h("div", { class: "ds-list" }, ...e.items.map(line)))),
      hist.length ? h("div", { class: "sy-at-hist ds-meta" }, "Passages précédents : " + hist.map((x) => when(x.ts) + " " + String(x.ok_n) + "/" + String(x.total)).join(" · ")) : null);
  }
  async function load() {
    try { const j = await api.get("/api/autotest/last"); if (!dead()) paint(j); }
    catch (e) { if (!dead()) box.replaceChildren(ds.errorBox({ cause: "Résultat de l'autotest injoignable.", retry: load })); }
  }
  async function runNow() {
    if (busy) return;
    busy = true; runBtn.disabled = true;
    box.replaceChildren(h("p", { class: "ds-meta" }, "Autotest en cours… (moins d'une minute)"));
    try {
      const r = await api.post("/api/autotest/run", {}, 90000);
      if (!dead()) ctx.toast(r && r.status === "en_cours" ? "Un autotest tourne déjà." : "Autotest : " + String((r && r.ok_n) || 0) + "/" + String((r && r.total) || 0) + " OK.");
    } catch (e) { if (!dead()) ctx.toast("Autotest impossible — le moteur ne répond pas.", true); }
    busy = false; if (runBtn.isConnected) runBtn.disabled = false;
    if (!dead()) load();
  }
  return { el: sec, load };
}
