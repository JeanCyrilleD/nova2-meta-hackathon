/* Nova 2 — pièces jointes de la conversation (ordre d'Ahadi, 20/10/2026).
   Joindre dans les échanges avec Nova : fichiers, dossiers, images, musique,
   enregistrements audio, vidéos.

   Mécanique réelle, sans promesse en l'air :
   - l'envoi part en corps brut vers POST /api/chat/upload (route moteur, Swift) qui
     enregistre le fichier dans le dossier de données de Nova (…/Nova/Attachments) ;
   - le message transmis au cerveau référence chaque fichier par son CHEMIN — c'est
     ainsi que Nova peut réellement le relire avec ses outils (read_file pour les
     documents texte/PDF/Word ; transcribe/read_file pour l'audio et la vidéo, qui
     sont transcrits par le moteur) ;
   - les IMAGES et les formats exotiques sont joints et archivés, affichés dans le
     fil, mais AUCUN cerveau de la chaîne ne sait les analyser : l'étiquette le dit
     (« joint et archivé ») et le bloc transmis au moteur lui interdit de prétendre
     les avoir vus.
   Styles : ceux du système de design, §24 (tokens.css → nova2.css) — ce module
   n'injecte AUCUN style (A-09 résolu) : la barre et les chips vivent sous
   `.att-bar`, `.att-chip`, `.att-chip-x`, fournies par le CSS. */
import { h } from "./core.js";
import { ic } from "./icons.js";

export const ATT_MAX_FILE = 10 * 1024 * 1024;    // 10 Mo par fichier (PHASE 1 : plafond du moteur, HTTPServer.maxBodyBytes — refus 413 au-delà)
export const ATT_MAX_TOTAL = 60 * 1024 * 1024;   // 60 Mo par message (le moteur refuse au-delà)
export const ATT_MAX_FILES = 10;                 // 10 pièces par message

const DOC_EXT = ["txt", "md", "pdf", "doc", "docx", "rtf", "html", "htm", "csv", "json", "odt", "pages", "xml", "log"];
export function attKind(f) {
  const mime = (f.type || "").toLowerCase();
  const ext = ((f.name || "").split(".").pop() || "").toLowerCase();
  if (mime.startsWith("image/")) return "image";
  if (mime.startsWith("audio/")) return "audio";
  if (mime.startsWith("video/")) return "video";
  if (DOC_EXT.includes(ext) || mime.startsWith("text/") || mime === "application/pdf" || mime.includes("word") || mime.includes("opendocument")) return "doc";
  return "file";
}
/* Étiquette honnête par type : ce que le moteur sait réellement en faire. */
export function attTag(kind) {
  if (kind === "folder") return { tag: "dossier lu sur place", brain: "c'est un DOSSIER de ce Mac : liste son contenu (list_dir) puis lis les fichiers utiles avec read_file — aucune copie n'a été faite" };
  if (kind === "doc") return { tag: "Nova peut le lire", brain: "lis-le avec l'outil read_file pour l'analyser" };
  if (kind === "audio") return { tag: "Nova peut le transcrire", brain: "transcris-le avec l'outil transcribe (ou read_file) pour l'analyser" };
  if (kind === "video") return { tag: "Nova peut transcrire le son", brain: "transcris sa bande-son avec l'outil transcribe (ou read_file) ; les images de la vidéo ne sont pas analysées" };
  if (kind === "image") return { tag: "image jointe", brain: "image jointe ; si le cerveau du tour ne la voit pas : dis-le, et lis seulement son texte avec read_file (OCR) — ne prétends jamais l'avoir vue" };   // V4-D : vision multimodale
  return { tag: "joint et archivé", brain: "joint et archivé : format non analysable automatiquement par les outils actuels" };
}
export const attSize = (n) => n >= 1048576 ? (n / 1048576).toFixed(1).replace(".", ",") + " Mo" : n >= 1024 ? Math.round(n / 1024) + " Ko" : n + " o";
const kindLabel = (kind, f) => {
  const ext = ((f && f.name || "").split(".").pop() || "").toUpperCase();
  if (kind === "folder") return "dossier";
  return { image: "image", audio: "audio", video: "vidéo", doc: "document", file: "fichier" }[kind] + (ext && ext.length <= 5 ? " " + ext : "");
};

/* ── Envoi d'un fichier vers le moteur (XHR : progression réelle) ─────────── */
/* 25/10 (Ahadi : « Échec : fichier vide » quel que soit le format) : le transport interne nova:// perd les corps
   binaires (Blob/File) — le moteur recevait 0 octet, même panne que la voix le 22/10. Le fichier part donc en
   morceaux de 2 Mo encodés en base64 dans des corps JSON (les corps texte traversent sans perte) ; le moteur
   les rassemble. Progression réelle, morceau par morceau. */
const CHUNK = 2 * 1024 * 1024;
const b64 = (buf) => { let bin = ""; for (let i = 0; i < buf.length; i += 32768) bin += String.fromCharCode.apply(null, buf.subarray(i, i + 32768)); return btoa(bin); };
async function uploadOne(item, onProgress) {
  const f = item.file, total = f.size || 0;
  const uid = Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10);
  const n = Math.max(1, Math.ceil(total / CHUNK));
  let j = {};
  for (let i = 0; i < n; i++) {
    const part = new Uint8Array(await f.slice(i * CHUNK, Math.min(total, (i + 1) * CHUNK)).arrayBuffer());
    let r;
    try {
      r = await fetch("/api/chat/upload?name=" + encodeURIComponent(f.name), { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ upload_id: uid, index: i, last: i === n - 1, data_b64: b64(part) }) });
    } catch (e) { throw new Error("envoi de « " + f.name + " » interrompu — moteur injoignable"); }
    j = await r.json().then((x) => (x && typeof x === "object" ? x : {}), () => ({}));
    if (!r.ok || !j.ok) throw new Error(j.error || ("le moteur a refusé « " + f.name + " » (HTTP " + r.status + ")"));
    onProgress((i + 1) / n);
  }
  if (!j.path) throw new Error("le moteur n'a pas confirmé « " + f.name + " »");
  return j;
}

/* ── Barre de pièces jointes d'un composeur ──────────────────────────────── */
export function createAttachments() {
  let items = [];   // {id, file, kind, rel, status, progress, server, err, url}
  let seq = 0, uploading = false;

  const bar = h("div", { class: "att-bar" });
  const fileInput = h("input", { type: "file", multiple: "", style: "display:none" });
  const dirInput = h("input", { type: "file", style: "display:none" });
  dirInput.setAttribute("webkitdirectory", ""); dirInput.setAttribute("directory", "");
  document.body.append(fileInput, dirInput);
  fileInput.addEventListener("change", () => { addFiles(fileInput.files); fileInput.value = ""; });
  dirInput.addEventListener("change", () => { dirInput.value = ""; });   // le dossier arrive par « nova:picked » (chemin réel), pas en copie

  /* Dossiers : le sélecteur natif transmet les chemins choisis (window « nova:picked ») — un dossier est joint par son
     chemin sur ce Mac (Nova le lit sur place avec ses outils), sans téléversement. Seul le composeur qui a ouvert le
     sélecteur les reçoit. */
  let pickArmed = 0;
  const onPicked = (e) => {
    if (!pickArmed || Date.now() - pickArmed > 10 * 60 * 1000) return;
    pickArmed = 0;
    for (const p of (e && e.detail) || []) {
      if (!p || !p.d || !p.p) continue;
      if (items.length >= ATT_MAX_FILES || items.some((x) => x.server && x.server.path === p.p)) continue;
      const name = String(p.p).replace(/\/+$/, "").split("/").pop() || p.p;
      items.push({ id: ++seq, file: { name, size: 0, type: "" }, kind: "folder", rel: "", status: "ok", progress: 1,
        server: { path: p.p, name, size: 0 }, err: "", url: "" });
    }
    render();
  };
  window.addEventListener("nova:picked", onPicked);
  const btn = h("button", { class: "btn att-btn", title: "Joindre des fichiers (images, audio, vidéo, documents…)", "aria-label": "Joindre des fichiers", html: ic("attach", 17), onclick: () => { pickArmed = Date.now(); fileInput.click(); } });
  const dirBtn = h("button", { class: "btn att-btn", title: "Joindre un dossier entier", "aria-label": "Joindre un dossier entier", html: ic("layers", 17), onclick: () => { pickArmed = Date.now(); dirInput.click(); } });

  function totalSize() { return items.reduce((s, it) => s + it.file.size, 0); }

  function addFiles(list) {
    const files = [...(list || [])].filter((f) => f && f.size !== undefined);
    const rejected = [];
    for (const f of files) {
      if (items.length >= ATT_MAX_FILES) { rejected.push("« " + f.name + " » : " + ATT_MAX_FILES + " pièces maximum par message"); continue; }
      if (f.size === 0) { rejected.push("« " + f.name + " » : fichier vide"); continue; }
      if (f.size > ATT_MAX_FILE) { rejected.push("« " + f.name + " » : " + attSize(f.size) + " — limite " + attSize(ATT_MAX_FILE) + " par fichier"); continue; }
      if (totalSize() + f.size > ATT_MAX_TOTAL) { rejected.push("« " + f.name + " » : limite totale de " + attSize(ATT_MAX_TOTAL) + " par message atteinte"); continue; }
      items.push({ id: ++seq, file: f, kind: attKind(f), rel: f.webkitRelativePath || "", status: "prêt", progress: 0, server: null, err: "", url: URL.createObjectURL(f) });
    }
    render();
    return rejected;
  }

  function remove(id) {
    const it = items.find((x) => x.id === id);
    if (it && it.url) { try { URL.revokeObjectURL(it.url); } catch (e) {} }
    items = items.filter((x) => x.id !== id);
    render();
  }

  function render() {
    bar.replaceChildren(...items.map((it) => {
      const left = it.kind === "image"
        ? h("img", { class: "att-thumb", src: it.url, alt: "" })
        : h("span", { class: "att-ic", html: ic(it.kind === "audio" ? "mic" : it.kind === "video" ? "video" : it.kind === "folder" ? "layers" : "file", 17) });
      const sub = it.status === "échec" ? "Échec : " + it.err
        : it.status === "envoi" ? "Envoi… " + Math.round(it.progress * 100) + " %"
        : it.kind === "folder" ? "Dossier · Nova le lit sur place"
        : it.status === "ok" ? "Reçu par Nova · " + attTag(it.kind).tag
        : attSize(it.file.size) + " · " + attTag(it.kind).tag;
      const meta = h("div", { class: "att-meta" },
        h("div", { class: "att-name", title: it.rel || it.file.name }, it.file.name),
        h("div", { class: "att-sub" }, sub),
        it.status === "envoi" ? h("div", { class: "att-prog", style: "width:" + Math.round(it.progress * 100) + "%" }) : null);
      return h("div", { class: "att-chip" + (it.status === "échec" ? " err" : "") }, left, meta,
        h("button", { class: "att-chip-x", title: "Retirer", "aria-label": "Retirer la pièce jointe " + it.file.name, html: ic("close", 13), onclick: () => remove(it.id) }));
    }));
  }

  /* Envoie séquentiellement les pièces pas encore reçues ; lève une erreur NOMMÉE. */
  async function uploadPending() {
    if (uploading) throw new Error("un envoi de pièces jointes est déjà en cours");
    uploading = true;
    try {
      for (const it of items) {
        if (it.status === "ok") continue;
        it.status = "envoi"; it.progress = 0; it.err = ""; render();
        try {
          it.server = await uploadOne(it, (p) => { it.progress = p; render(); });
          it.status = "ok";
        } catch (e) {
          it.status = "échec"; it.err = String((e && e.message) || e).slice(0, 140); render();
          throw new Error(it.err);
        }
        render();
      }
    } finally { uploading = false; }
  }

  /* Descripteurs des pièces reçues par le moteur (à passer à chat.send). */
  function descriptors() {
    return items.filter((it) => it.status === "ok" && it.server).map((it) => ({
      name: it.server.name || it.file.name, path: it.server.path, size: it.server.size ?? it.file.size,
      kind: it.kind, url: it.url, label: kindLabel(it.kind, it.file),
    }));
  }
  function take() { const d = descriptors(); items = []; render(); return d; }

  /* Glisser-déposer sur une zone + coller depuis le presse-papiers dans un champ. */
  function attachTo(zone, pasteTarget) {
    if (zone) {
      zone.addEventListener("dragover", (e) => { e.preventDefault(); zone.classList.add("att-drop"); });
      zone.addEventListener("dragleave", () => zone.classList.remove("att-drop"));
      zone.addEventListener("drop", (e) => {
        e.preventDefault(); zone.classList.remove("att-drop");
        if (e.dataTransfer) { const r = addFiles(e.dataTransfer.files); if (r.length) zone.dispatchEvent(new CustomEvent("nova:att-rejected", { detail: r })); }
      });
    }
    if (pasteTarget) pasteTarget.addEventListener("paste", (e) => {
      const fs = e.clipboardData && e.clipboardData.files;
      if (fs && fs.length) { e.preventDefault(); addFiles(fs); }
    });
  }

  return { bar, btn, dirBtn, addFiles, attachTo, uploadPending, descriptors, take,
    count: () => items.length, busy: () => uploading, hasFailed: () => items.some((it) => it.status === "échec") };
}

/* ── Rendu des pièces dans le fil (bulle utilisateur, après envoi) ────────── */
export function renderSent(attachments) {
  const wrap = h("div", { class: "att-views" });
  for (const a of attachments || []) {
    if (a.kind === "image" && a.url) wrap.append(h("div", { class: "att-view" }, h("img", { src: a.url, alt: a.name })));
    else if (a.kind === "video" && a.url) { const v = h("video", { controls: "", src: a.url }); wrap.append(h("div", { class: "att-view" }, v)); }
    else if (a.kind === "audio" && a.url) { const au = h("audio", { controls: "", src: a.url }); wrap.append(h("div", { class: "att-view" }, au)); }
    else wrap.append(h("div", { class: "att-file" },
      h("span", { html: ic(a.kind === "audio" ? "mic" : a.kind === "video" ? "video" : a.kind === "folder" ? "layers" : "file", 16) }),
      h("div", { class: "att-meta" }, h("div", { class: "att-name", title: a.name }, a.name),
        h("div", { class: "att-sub" }, (a.kind === "folder" ? "dossier" : (a.sizeLabel || attSize(a.size || 0))) + " · " + (a.label && a.kind === "file" ? a.label + " · " : "") + attTag(a.kind).tag))));
  }
  return wrap;
}

/* V5-W (25/10) — RELECTURE D'HISTORIQUE : le message stocké d'Ahadi contient le bloc destiné au cerveau
   (describeForBrain ci-dessous). Rejoué, il s'affichait brut (chemins, consignes d'outils). On le sépare :
   { text : ce qu'Ahadi a écrit, atts : [{name, kind, label, sizeLabel, path}] } — mêmes pastilles qu'à l'envoi
   (renderSent). Seules les lignes au format exact de describeForBrain sont reprises ; sinon rien ne change. */
const KIND_OF_LABEL = { image: "image", audio: "audio", "vidéo": "video", video: "video", document: "doc", fichier: "file", dossier: "folder" };
export function splitBrainBlock(text) {
  const src = String(text || "");
  const i = src.indexOf("[Pièces jointes de ce message");
  if (i < 0) return { text: src, atts: [] };
  // Le bloc = la ligne d'en-tête + les lignes « • … » qui la suivent (la dernière se ferme par « ] »).
  let end = src.indexOf("\n", i); if (end < 0) end = src.length;
  while (end < src.length) { const nx = src.indexOf("\n", end + 1); const line = src.slice(end + 1, nx < 0 ? src.length : nx); if (!/^\s*•/.test(line)) break; end = nx < 0 ? src.length : nx; }
  const block = src.slice(i, end);
  const atts = [];
  for (const line of block.split("\n")) {
    const m = /^•\s*«\s*(.+?)\s*»\s*\(([^)]*)\)\s*—\s*chemin\s*:\s*(.+?)\s+—\s/.exec(line.trim());
    if (!m) continue;
    const parts = m[2].split(/,\s+/).map((x) => x.trim());   // « 1,2 Mo » garde sa virgule décimale
    const label = parts[0] || "";
    const kind = KIND_OF_LABEL[(label.split(/\s+/)[0] || "").toLowerCase()] || "file";
    atts.push({ name: m[1], kind, label, sizeLabel: parts.slice(1).join(", ") || "", path: m[3] });
  }
  if (!atts.length) return { text: src, atts: [] };
  return { text: (src.slice(0, i) + src.slice(i + block.length)).replace(/\n{3,}/g, "\n\n").trim(), atts };
}

/* ── Bloc transmis au cerveau : chemins réels + ce qu'il peut en faire ────── */
export function describeForBrain(attachments) {
  if (!attachments || !attachments.length) return "";
  const lines = attachments.map((a) => "• « " + a.name + " » (" + (a.label || a.kind) + (a.kind === "folder" ? "" : ", " + attSize(a.size || 0)) + ") — chemin : " + a.path + " — " + attTag(a.kind).brain + ".");
  return "[Pièces jointes de ce message — fichiers enregistrés sur ce Mac :\n" + lines.join("\n") + "]";
}

/* V4-D (24/10) — VISION MULTIMODALE : images jointes à passer au moteur
   (champ « images » de POST /api/chat) — le moteur relit le fichier dans son
   dossier Attachments, le réduit si besoin et l'envoie à Claude en bloc image
   base64. Formats que l'API accepte : JPEG, PNG, GIF, WebP. */
export const VISION_EXT = ["jpg", "jpeg", "png", "gif", "webp"];
export function visionImages(attachments) {
  if (!attachments || !attachments.length) return [];
  return attachments
    .filter((a) => a && a.kind === "image" && a.path && VISION_EXT.includes(String(a.path).split(".").pop().toLowerCase()))
    .slice(0, 5)
    .map((a) => ({ path: String(a.path), name: String(a.name || "") }));
}
