// PILOTAGE (01/11) — tests de la résolution déterministe des cibles de navigation (node, sans navigateur, sans réseau).
// Lancer : node tools/test_pilotage.mjs (appelé par tools/verify.sh). Le parcours complet dans Chromium : tools/ui/test_pilotage_e2e.py
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
const m = await import(new URL("../web/js/pilot-resolve.js", import.meta.url).href);
let n = 0; const ok = (name, fn) => { fn(); n++; console.log("  OK  " + name); };
// Liste réelle des écrans (MODULES de shell.js), lue dans le source pour ne jamais diverger.
const src = readFileSync(new URL("../web/js/shell.js", import.meta.url), "utf8");
const MODS = [...src.matchAll(/\{ id: "([a-z]+)", icon: "[a-z0-9-]+", label: "([^"]+)"/g)].map((x) => ({ id: x[1], label: x[2] }));
const R = (q, s = "") => m.resolveScreen(q, MODS, s);

ok("MODULES lus (≥ 20 écrans)", () => assert.ok(MODS.length >= 20, String(MODS.length)));
ok("id et libellé exacts, accents et casse ignorés", () => {
  assert.equal(R("settings").id, "settings"); assert.equal(R("Réglages").id, "settings"); assert.equal(R("REGLAGES").id, "settings");
  assert.equal(R("Médias").id, "radio"); assert.equal(R("Comptes rendus").id, "reunions");
});
ok("alias : chat, tv, agenda, éclats → bon écran", () => {
  assert.equal(R("chat").id, "conversations"); assert.equal(R("tv").id, "radio"); assert.equal(R("agenda").id, "temps"); assert.equal(R("éclats").id, "dots");
});
ok("« cerveaux » (cas réel du 27/10) → Réglages › Assistant", () => { const r = R("cerveaux"); assert.equal(r.id, "settings"); assert.equal(r.section, "assistant"); });
ok("« réglages cerveaux » et « Réglages | Cerveaux » → section Assistant", () => {
  assert.equal(R("réglages cerveaux").section, "assistant");
  assert.equal(R("settings", "Cerveaux").section, "assistant");
});
ok("écran + section libre conservée", () => { const r = R("systeme connexions"); assert.equal(r.id, "systeme"); assert.equal(r.section, "connexions"); });
ok("rien d'inventé : introuvable → candidats, jamais ok", () => {
  const r = R("xyz"); assert.equal(r.ok, false); assert.ok(r.candidats.length >= 20);
  assert.equal(R("").ok, false); assert.equal(R("f").ok, false);
});
ok("plus de faux positif par inclusion (ancien q.includes(id))", () => {
  // l'ancien code ouvrait « vie » (Projets) pour toute demande contenant « vie »
  assert.notEqual(R("revue de la vieille note").id, "vie");
});
ok("matchLabel : exact > préfixe > inclusion ; ambiguïté signalée", () => {
  const E = [{ key: "general", label: "Général" }, { key: "look", label: "Apparence & accès" }, { key: "assistant", label: "Assistant" }];
  assert.equal(m.matchLabel("assistant", E).key, "assistant");
  assert.equal(m.matchLabel("appar", E).key, "look");
  assert.equal(m.matchLabel("zzz", E).ok, false);
  const A = m.matchLabel("cerveau", [{ key: "a", label: "Cerveau par défaut" }, { key: "b", label: "Cerveau des Éclats" }]);
  assert.equal(A.ok, false); assert.deepEqual(A.ambigu.sort(), ["Cerveau des Éclats", "Cerveau par défaut"]);
});
ok("« ligne > option »", () => {
  assert.deepEqual(m.splitRowOption("Taille du texte des réponses > Grand"), { row: "Taille du texte des réponses", opt: "Grand" });
  assert.equal(m.splitRowOption("Enregistrer"), null); assert.equal(m.splitRowOption("> x"), null);
});
ok("réglages côté fenêtre : valeurs bornées", () => {
  assert.deepEqual(m.CLIENT_SETTINGS.text_size.values, ["s", "m", "l", "xl"]);
  assert.ok(m.CLIENT_SETTINGS.soft_night.bool);
});
ok("uibridge branché : ordres go/etat/conv/reglages-appliquer, garde DANGER conservée", () => {
  const u = readFileSync(new URL("../web/js/uibridge.js", import.meta.url), "utf8");
  for (const op of ['op === "go"', 'op === "etat"', 'op === "conv"', 'op === "reglages-appliquer"']) assert.ok(u.includes(op), op);
  assert.ok(u.includes("DANGER.test(label) && !d.confirmed"), "confirmation des clics sensibles");
  assert.ok(!/reply\(id, \{ ok: true, ecran: m\.id/.test(u), "plus de ok avant navigation");
});
console.log("PILOTAGE (résolution) : " + n + " tests OK");
