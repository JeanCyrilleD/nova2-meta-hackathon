// Phase 4 — tests du réducteur d'évènements de tâche (format v1, docs/PHASE4_CONTRATS.md §1). node tools/ui/test_tasks_feed.mjs
import assert from "node:assert/strict";
import { applyEvent, simulatedScript, usd, STATES, fromAgents2 } from "../../web/js/tasks-feed.js";
let t = {};
for (const ev of simulatedScript(Date.parse("2026-10-31T18:00:00Z"))) t = applyEvent(t, ev);
assert.equal(Object.keys(t).length, 3, "trois tâches simulées");
const m = t["sim-mail-1"];
assert.equal(m.state, "awaiting_approval"); assert.ok(m.approval && m.approval.content_sha256, "approbation présente avec empreinte");
assert.equal(m.spent_usd_micro, 412 + 8120, "coût réel = somme des coûts « actual » en micro-dollars entiers");
assert.equal(m.reserved_usd_micro, 30000);
const c = t["sim-cafu-2"];
assert.equal(c.estimated_usd_micro, 236000, "coût estimé séparé du réel"); assert.equal(c.spent_usd_micro, 1900 + 6400); assert.equal(c.state, "verifying");
assert.equal(t["sim-tri-3"].state, "done"); assert.ok(t["sim-tri-3"].receipt, "« done » vient avec un reçu");
// rejeu idempotent et ordre : un seq ancien ou égal est ignoré
const same = applyEvent(t, { v: 1, task_id: "sim-mail-1", seq: 4, at: "x", kind: "step", state: "failed" });
assert.equal(same, t, "seq déjà vu → table inchangée (même objet)");
// tout changement d'état annule l'approbation affichée
const t2 = applyEvent(t, { v: 1, task_id: "sim-mail-1", seq: 5, at: "2026-10-31T18:01:00Z", kind: "approval_cleared", state: "draft" });
assert.equal(t2["sim-mail-1"].approval, null); assert.equal(t["sim-mail-1"].approval.destination.includes("@"), true, "l'ancienne table n'est pas mutée");
// version inconnue ou état inconnu
assert.equal(applyEvent(t, { v: 2, task_id: "z", seq: 1 }), t);
const t3 = applyEvent({}, { v: 1, task_id: "z", seq: 1, at: "a", kind: "step", state: "bizarre" });
assert.equal(t3.z.state, "unknown");
assert.ok(STATES.includes("paused"));
// contrat RÉEL de la Phase 3 (AgentEngine.summary / specSummary, GET /api/agents2)
const specs = { mail: { id: "mail", label: "Mail", capMicros: 750000, maxSteps: 6 } };
const r = fromAgents2({ id: "t1", agent: "mail", state: "awaiting_approval", dataClass: "personal", content: "Bonjour", contentSha256: "abc", approved: false,
  spentMicros: 8532, reason: "réponse", createdAt: "2026-10-31T18:00:00Z", steps: [{ tool: "gmail.draft", status: "done", attempts: 1, receipt: "" }, { tool: "gmail.send", status: "pending", attempts: 0, receipt: "" }] }, specs);
assert.equal(r.state, "awaiting_approval"); assert.equal(r.approval.content_sha256, "abc", "l'approbation porte l'empreinte contentSha256 de la Phase 3");
assert.equal(r.approval.content_preview, "Bonjour"); assert.equal(r.cap_usd_micro, 750000); assert.equal(r.spent_usd_micro, 8532); assert.equal(r.steps.length, 2);
assert.equal(r.steps[0].state, "done"); assert.equal(r.receipt, null, "pas de reçu → pas de reçu inventé");
const r2 = fromAgents2({ id: "t2", agent: "x", state: "weird", steps: [{ tool: "say", status: "done", receipt: "cache/a.mp3" }] });
assert.equal(r2.state, "unknown"); assert.equal(r2.approval, null); assert.deepEqual(r2.receipt, { kind: "say", id: "cache/a.mp3" });
// argent : micro-dollars entiers → texte, jamais NaN
assert.equal(usd(125000000, 0), "125 $"); assert.equal(usd(null), "—"); assert.equal(usd(750000, 2), "0,75 $");
// aucun pourcentage dans le module d'affichage
import { readFileSync } from "node:fs";
const src = readFileSync(new URL("../../web/js/modules/taches.js", import.meta.url), "utf8");
assert.ok(!/%/.test(src.replace(/\/\*[\s\S]*?\*\//g, "")), "taches.js n'affiche aucun pourcentage");
console.log("tasks-feed : toutes les assertions OK");
