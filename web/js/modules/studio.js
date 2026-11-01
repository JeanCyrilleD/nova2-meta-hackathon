/* Module Studio Muse — NOUVEAU (26/10/2026, demande d'Ahadi : des fonctions
   nouvelles, pas seulement du visuel). Les capacités Meta Model API hors chat,
   utilisables dans Nova :
   · Muse Image : génération d'image depuis un texte (POST /api/meta/image).
   · SAM 3.1 : segmentation d'une image publique par concept (POST /api/meta/segment).
   · Muse Voice : descripteur du canal temps réel (aucun batch — doc officielle).
   · État Meta : clé présente ou non, modèles servis, politique d'envoi.
   POLITIQUE A : chaque génération/segmentation exige la case « J'envoie ce
   contenu vers le cloud Meta » cochée, par appel — le moteur refuse sinon (403).
   Aucun faux succès : sans clé ou sans réponse du fournisseur, l'erreur réelle
   s'affiche. Les images générées restent dans cet écran (aperçu), rien n'est
   enregistré sans action explicite d'Ahadi. */
import * as ds from "../ds.js";

export async function mount(root, ctx) {
  const { api, h } = ctx;
  let dead = false;

  root.append(ds.pageHead({
    title: "Studio Muse",
    sub: "Créer et analyser avec les modèles Meta : images Muse Image, segmentation SAM 3.1, voix temps réel — chaque envoi cloud se confirme, par appel.",
    actions: [{ label: "Actualiser l'état", icon: "refresh", onClick: () => loadStatus() }],
  }));

  /* ── État Meta ─────────────────────────────────────────────────────────── */
  const statusBody = h("div", {});
  const statusSec = ds.section({ title: "État Meta Model API", body: statusBody });
  root.append(statusSec);
  async function loadStatus() {
    statusBody.replaceChildren(ds.skeleton(2));
    try {
      const j = await api.get("/api/meta/status");
      if (dead) return;
      if (!j || j.ok === false) throw new Error((j && j.error) || "pas de réponse");
      const items = [
        { label: "Clé Meta", value: j.key_present ? "présente (Trousseau)" : "absente — Réglages › Connexions" },
        { label: "Cerveaux chat", value: (j.chat_models || []).join(" · ") },
        { label: "Image", value: String(j.image_model || "—") },
        { label: "Segmentation", value: String(j.segment_model || "—") },
        { label: "Voix", value: (j.voice && j.voice.model) ? j.voice.model + " (temps réel)" : "—" },
        { label: "Politique", value: String(j.policy || "") },
      ];
      statusBody.replaceChildren(ds.kpis(items));
    } catch (e) {
      if (!dead) statusBody.replaceChildren(ds.errorBox({ cause: "Le moteur n'a pas répondu sur /api/meta/status.", retry: loadStatus }));
    }
  }

  /* ── Confirmation cloud (Politique A, par appel) ───────────────────────── */
  const confirmBox = (id) => h("label", { style: "display:flex;gap:8px;align-items:center;font:400 13px var(--f-ui);color:var(--text-2)" },
    h("input", { type: "checkbox", id }),
    "J'envoie ce contenu vers le cloud Meta (par appel, jamais en tâche de fond).");

  /* ── Muse Image ────────────────────────────────────────────────────────── */
  const imgPrompt = h("textarea", { rows: "3", placeholder: "Décris l'image à générer…", style: "width:100%;box-sizing:border-box" });
  const imgConfirm = confirmBox("studio-img-confirm");
  const imgOut = h("div", {});
  const imgBtn = ds.action({ label: "Générer l'image", icon: "sparkle", primary: true, onClick: async () => {
    const prompt = imgPrompt.value.trim();
    if (!prompt) { ctx.toast("Écris d'abord la description de l'image.", true); return; }
    if (!imgConfirm.querySelector("input").checked) { ctx.toast("Coche la confirmation d'envoi cloud (Politique A).", true); return; }
    imgOut.replaceChildren(ds.skeleton(2));
    try {
      const j = await api.post("/api/meta/image", { prompt, confirm_cloud: true });
      if (dead) return;
      if (!j || j.ok === false) throw new Error((j && (j.error || "échec")) + "");
      const d = (j.result && j.result.data && j.result.data[0]) || {};
      imgOut.replaceChildren();
      if (d.b64_json) {
        const im = h("img", { src: "data:image/png;base64," + d.b64_json, alt: prompt, style: "max-width:100%;border-radius:14px" });
        const dl = ds.action({ label: "Télécharger le PNG", icon: "download", onClick: () => {
          const a = h("a", { href: im.src, download: "nova-muse-image.png" }); a.click();
        } });
        imgOut.append(im, h("div", { style: "margin-top:8px" }, dl));
      } else if (d.url) {
        imgOut.append(h("img", { src: d.url, alt: prompt, style: "max-width:100%;border-radius:14px" }));
      } else {
        imgOut.append(ds.empty({ text: "Meta a répondu sans image exploitable — rien n'est inventé.", icon: "alert" }));
      }
    } catch (e) {
      if (!dead) imgOut.replaceChildren(ds.errorBox({ cause: String(e && e.message || e), retry: null }));
    }
  } });
  const imgSec = ds.section({ title: "Muse Image — générer", body: h("div", {}, imgPrompt, imgConfirm, h("div", { style: "margin:10px 0" }, imgBtn), imgOut) });
  root.append(imgSec);

  /* ── SAM 3.1 ───────────────────────────────────────────────────────────── */
  const segPrompt = h("input", { type: "text", placeholder: "Concept à découper (groupe nominal court, ex. yellow school bus)", style: "width:100%;box-sizing:border-box" });
  const segURL = h("input", { type: "url", placeholder: "URL publique de l'image (https://…)", style: "width:100%;box-sizing:border-box" });
  const segConfirm = confirmBox("studio-seg-confirm");
  const segOut = h("div", {});
  const segBtn = ds.action({ label: "Segmenter", icon: "look", primary: true, onClick: async () => {
    const prompt = segPrompt.value.trim(), url = segURL.value.trim();
    if (!prompt || !url) { ctx.toast("Il faut un concept et une URL d'image.", true); return; }
    if (!segConfirm.querySelector("input").checked) { ctx.toast("Coche la confirmation d'envoi cloud (Politique A).", true); return; }
    segOut.replaceChildren(ds.skeleton(2));
    try {
      const j = await api.post("/api/meta/segment", { prompt, image_url: url, confirm_cloud: true });
      if (dead) return;
      if (!j || j.ok === false) throw new Error((j && (j.error || "échec")) + "");
      const txt = JSON.stringify(j.result || {}, null, 1).slice(0, 4000);
      segOut.replaceChildren(
        h("img", { src: url, alt: prompt, style: "max-width:100%;border-radius:14px" }),
        h("pre", { style: "white-space:pre-wrap;font:400 12px/18px ui-monospace,monospace;color:var(--text-2);margin-top:10px" }, txt));
    } catch (e) {
      if (!dead) segOut.replaceChildren(ds.errorBox({ cause: String(e && e.message || e), retry: null }));
    }
  } });
  const segSec = ds.section({ title: "SAM 3.1 — segmenter une image", body: h("div", {}, segPrompt, h("div", { style: "height:8px" }), segURL, segConfirm, h("div", { style: "margin:10px 0" }, segBtn), segOut) });
  root.append(segSec);

  /* ── Muse Voice ────────────────────────────────────────────────────────── */
  const voiceBody = h("div", {}, ds.empty({ compact: true, icon: "mic", text: "Muse Voice Transcribe : transcription temps réel uniquement (WebSocket, PCM 16/24 kHz). La dictée locale reste le chemin par défaut ; ce canal s'ouvrira par session explicite." }));
  root.append(ds.section({ title: "Muse Voice — transcription temps réel", body: voiceBody }));


  /* ── Santé Muse en direct (états réels du routeur, /api/state) ────────── */
  const healthBody = h("div", {});
  root.append(ds.section({ title: "Santé Muse en direct", body: healthBody }));
  async function loadHealth() {
    try {
      const j = await api.get("/api/state");
      if (dead || !j) return;
      const meta = (j.brains || []).filter((b) => /wonder|spark|muse/i.test(String(b.id) + " " + String(b.label)));
      if (!meta.length) { healthBody.replaceChildren(ds.empty({ compact: true, icon: "brain", text: "Aucun cerveau Muse servi pour le moment." })); return; }
      healthBody.replaceChildren(...meta.map((b) => ds.row({
        title: String(b.label || b.id), meta: String(b.model || ""),
        side: ds.pill(String(b.etat || "—"), b.etat === "prêt" ? "ok" : (b.etat === "sans clé" ? "danger" : "neutral")),
      })));
    } catch (e) { if (!dead) healthBody.replaceChildren(ds.empty({ compact: true, icon: "alert", text: "État des cerveaux illisible pour le moment." })); }
  }

  /* ── Coûts publiés (grille officielle Meta, lue dans /api/meta/status) ── */
  const costBody = h("div", {});
  root.append(ds.section({ title: "Coûts Meta publiés", body: costBody }));
  async function loadCosts() {
    try {
      const j = await api.get("/api/meta/status");
      if (dead || !j || !j.pricing) return;
      costBody.replaceChildren(ds.kpis([
        { label: "Wonder (Standard)", value: j.pricing.wonder },
        { label: "Spark (Standard)", value: j.pricing.spark_standard },
        { label: "Spark Contributor — défaut Nova", value: j.pricing.spark_contributor },
        { label: "Muse Image", value: j.pricing.image },
        { label: "Muse Voice", value: j.pricing.voice },
      ]));
    } catch (e) {}
  }
  loadHealth(); loadCosts();

  /* ── NOUVEAUTÉ : Pré-vol d'envoi (relit un brouillon AVANT le GO) ──────── */
  const pfTo = h("input", { type: "text", placeholder: "Destinataire", style: "width:100%;box-sizing:border-box" });
  const pfSub = h("input", { type: "text", placeholder: "Objet", style: "width:100%;box-sizing:border-box" });
  const pfBody = h("textarea", { rows: "4", placeholder: "Corps du message…", style: "width:100%;box-sizing:border-box" });
  const pfAtt = h("input", { type: "text", placeholder: "Pièces jointes (noms séparés par des virgules)", style: "width:100%;box-sizing:border-box" });
  const pfOut = h("div", {});
  const pfBtn = ds.action({ label: "Lancer le pré-vol", icon: "shield", primary: true, onClick: async () => {
    pfOut.replaceChildren(ds.skeleton(1));
    try {
      const j = await api.post("/api/meta/preflight", { to: pfTo.value, subject: pfSub.value, body: pfBody.value,
        attachments: pfAtt.value.split(",").map((x) => x.trim()).filter(Boolean) });
      if (dead) return;
      pfOut.replaceChildren(...(j.checks || []).map((c) => ds.row({ title: c.label, side: ds.pill(c.level === "block" ? "Bloquant" : (c.level === "warn" ? "À vérifier" : "OK"), c.level === "block" ? "danger" : (c.level === "warn" ? "warn" : "ok")) })));
    } catch (e) { if (!dead) pfOut.replaceChildren(ds.errorBox({ cause: String(e && e.message || e) })); }
  } });
  root.append(ds.section({ title: "Pré-vol d'envoi — avant ton GO", body: h("div", {}, pfTo, h("div", { style: "height:8px" }), pfSub, h("div", { style: "height:8px" }), pfBody, h("div", { style: "height:8px" }), pfAtt, h("div", { style: "margin:10px 0" }, pfBtn), pfOut) }));

  /* ── NOUVEAUTÉ : Pièces jointes Outlook (index local, lecture seule) ───── */
  const ojQ = h("input", { type: "search", placeholder: "Chercher une pièce jointe Outlook (ex. visa, receipt, DAR)…", style: "width:100%;box-sizing:border-box" });
  const ojOut = h("div", {});
  async function loadOutlook() {
    ojOut.replaceChildren(ds.skeleton(2));
    try {
      const j = await api.get("/api/meta/outlook?q=" + encodeURIComponent(ojQ.value.trim()));
      if (dead) return;
      const items = (j && j.items) || [];
      if (!items.length) { ojOut.replaceChildren(ds.empty({ compact: true, icon: "file", text: "Aucune pièce jointe trouvée (accès : " + String((j && j.access) || "—") + ")." })); return; }
      ojOut.replaceChildren(...items.map((a) => ds.row({ title: String(a.name || ""), meta: String(a.ext || "").toUpperCase() + " · " + Math.round((a.size || 0) / 1024) + " Ko · " + String(a.modified || "").slice(0, 10) + (a.snippet ? " — " + String(a.snippet).replace(/\s+/g, " ").slice(0, 140) + "…" : "") })));
    } catch (e) { if (!dead) ojOut.replaceChildren(ds.errorBox({ cause: String(e && e.message || e) })); }
  }
  ojQ.addEventListener("keydown", (e) => { if (e.key === "Enter") loadOutlook(); });
  root.append(ds.section({ title: "Pièces jointes Outlook — index local", body: h("div", {}, ojQ, h("div", { style: "margin-top:10px" }, ojOut)) }));
  loadOutlook();

  /* ── NOUVEAUTÉ : Estimateur de coût Meta ───────────────────────────────── */
  const estBrain = h("select", {}, ...["spark-1.3-contributor", "spark-1.3", "spark-1.2", "wonder-1.0"].map((b) => h("option", { value: b }, b)));
  const estIn = h("input", { type: "number", value: "100000", min: "0", style: "width:130px" });
  const estOut = h("input", { type: "number", value: "20000", min: "0", style: "width:130px" });
  const estRes = h("span", { style: "font:600 14px var(--f-ui)" }, "—");
  const estBtn = ds.action({ label: "Estimer", icon: "chart", onClick: async () => {
    try {
      const j = await api.post("/api/meta/estimate", { brain: estBrain.value, input_tokens: Number(estIn.value) || 0, output_tokens: Number(estOut.value) || 0 });
      if (!dead) estRes.textContent = (j && j.ok) ? ("≈ " + j.usd + " $") : "hors grille";
    } catch (e) { if (!dead) estRes.textContent = "—"; }
  } });
  root.append(ds.section({ title: "Estimateur de coût Meta", body: h("div", { style: "display:flex;gap:8px;align-items:center;flex-wrap:wrap" }, estBrain, estIn, estOut, estBtn, estRes) }));

  loadStatus();
  return () => { dead = true; };
}
