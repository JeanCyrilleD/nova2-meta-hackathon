/* C1 (29/10) — RENDU DÉTERMINISTE des réponses de Nova.
   Quel que soit ce que le modèle a écrit, la bulle d'Ahadi suit toujours la même structure :
     BLUF en tête → corps → carte livrable → pied discret (Preuve · DOTS) → suites (une seule rangée, 3 max).
   Fonction PURE (texte → texte), sans dépendance au navigateur : importée par core.js (réexportée)
   et testée sous Node (tests/normalize.test.mjs). Idempotente : normalizeAnswer(normalizeAnswer(x)) === normalizeAnswer(x).
   Règle de prudence : dans le doute, on GARDE. Un paragraphe portant un tableau, une liste, un titre,
   du code, un lien ou une pastille [[…]] n'est jamais retiré. Le pied est émis dans un bloc ```nova-pied
   que md() rend en ligne grisée (Preuve) et en rangée de badges (DOTS). */

const FENCE_OPEN = /^\s*```([\w-]*)\s*$/;
const BLUF_RX = /^\s*(?:>\s*)?(?:\*\*|__)?\s*BLUF\b|^\s*#{1,4}\s*BLUF\b/i;
const DOTS_RX = /^\s*(?:[-*•]\s+)?(?:\*\*)?(?:DOTS|ÉCLATS|Dots|Éclats)(?:\*\*)?\s*:?\s*(?:🟢|🟡|🔴)/u;
const CHEMIN_RX = /^\s*(?:[-*•]\s+)?(?:\*\*)?Chemin du fichier\b/i;
const PREUVE_RX = /^\s*(?:[-*•]\s+)?(?:\*\*)?Preuve(?:\*\*)?\s*(?:\*\*)?\s*:/i;
/* Marqueurs « structurels » : un paragraphe qui en porte un n'est jamais retiré. */
const PROTECT_RX = [
  /^\s*\|/m,                              // tableau
  /^\s*(?:[-*•]|\d{1,2}[.)])\s+/m,        // liste
  /^\s*#{1,6}\s/m,                        // titre
  /^\s*>/m,                               // citation
  /\[[^\]\n]+\]\([^)\s]+\)/,              // lien markdown
  /https?:\/\//i,                         // URL nue
  /\[\[[^\]\n]{2,30}\]\]/,                // pastille CAFU
  /\[Ouvrir\s*:/i,                        // bouton de navigation
  /^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/m,      // filet
  /^\s*\*\*[^*\n]+\*\*\s*:?\s*$/,         // ligne entièrement en gras = intertitre
];
/* Faits qui méritent d'être gardés même dans une phrase à la première personne. */
const FACT_RX = [
  /\b\d{1,2}\/\d{1,2}(?:\/\d{2,4})?\b/,                                     // 21/10, 21/10/2026
  /\b(?:19|20)\d{2}\b/,                                                     // années
  /\b\d{1,2}(?:er)?\s+(?:janv|févr|fevr|mars|avr|mai|juin|juil|août|aout|sept|oct|nov|déc|dec)/i,
  /\d\s?%/,                                                                 // pourcentages
  /\d[\d\s  .,]*\s?(?:FCFA|XOF|CFA|€|\$|USD|EUR|k€|M€|millions?|milliards?|personnes|ménages|morts?|tués?|blessés?|déplacés?|réfugiés?|enfants|km|tonnes?)\b/i,
  /\b\d{1,3}(?:[\s  .]\d{3})+\b/,                                 // 52 546, 1.200.000
  /\b\d{4,}\b/,                                                             // grands nombres
];
const LEAD = String.raw`(?:(?:d['’]abord|ensuite|maintenant|puis|bon|ok|okay|d['’]accord|parfait|très bien|c['’]est noté|entendu|alors)\s*[,:]?\s+)?`;
const PROGRESS_RX = new RegExp("^" + LEAD + String.raw`(?:je|j['’])\s*(?:` + [
  "m['’]en occupe", "m['’]y mets", "m['’]y attelle", "vérifie", "cherche", "lis", "relis", "lance", "relance", "ouvre", "regarde",
  "consulte", "prépare", "récupère", "mets à jour", "passe", "reprends", "rédige", "reviens", "commence", "continue",
  "télécharge", "interroge", "croise", "compile", "analyse", "parcours", "fouille", "contrôle", "termine", "finalise", "génère",
  "ai assez", "ai trouvé de quoi", "ai ce qu['’]il faut", "ai tout ce qu['’]il faut",
  "vais (?:d['’]abord )?(?:vérifier|chercher|lire|relire|lancer|ouvrir|regarder|consulter|préparer|récupérer|mettre à jour|passer|reprendre|rédiger|commencer|continuer|télécharger|interroger|croiser|compiler|analyser|parcourir|contrôler|finaliser|générer)",
].join("|") + String.raw`)\b`, "iu");

/* Notes internes du moteur recopiées par le modèle : jamais affichées. */
const ENGINE_NOTE_RX = /\[Outils utilis[ée]s\s*(?:\(note du moteur|:)/i;
const ENGINE_LINE_RX = /^\s*\[(?:MOTEUR NOVA|R[ÉE]SULTAT DE L['’]OUTIL)/i;
/* Retire « [Outils utilisés (note du moteur … ] » jusqu'au DERNIER « ] » de sa ligne (à défaut : du paragraphe)
   (le JSON interne contient des crochets imbriqués) ; sans « ] », jusqu'à la fin du paragraphe. */
function stripEngineNotes(text) {
  let t = String(text);
  for (let guard = 0; guard < 8; guard++) {
    const m = ENGINE_NOTE_RX.exec(t);
    if (!m) break;
    const eol = t.indexOf("\n", m.index), lineEnd = eol < 0 ? t.length : eol;
    let end = t.lastIndexOf("]", lineEnd - 1);                 // dernier « ] » de la ligne de la note…
    if (end < m.index) end = t.lastIndexOf("]");               // …sinon du paragraphe (note sur plusieurs lignes)
    const before = t.slice(0, m.index).replace(/[ \t]+$/, ""), after = (end >= m.index ? t.slice(end + 1) : "").replace(/^[ \t]+/, "");
    t = before + (before && after && !/\n$/.test(before) && !/^\n/.test(after) ? " " : "") + after;
  }
  return t;
}
const norm = (s) => String(s).replace(/\s+/g, " ").trim();
const isProtected = (p) => PROTECT_RX.some((rx) => rx.test(p));
const hasFact = (p) => FACT_RX.some((rx) => rx.test(p));
const isHr = (p) => /^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/.test(p);

/* Paragraphe de narration d'étape : court, sans structure ni fait, et dont au moins la moitié
   des phrases sont des annonces de progression à la première personne. */
export function isNarration(p) {
  const t = String(p || "").trim();
  if (!t || t.length >= 260 || isProtected(t) || hasFact(t) || BLUF_RX.test(t)) return false;
  const plain = t.replace(/[*_`]/g, "").replace(/\s*\n\s*/g, " ");
  const sentences = plain.split(/(?<=[.!?…])\s+/).map((x) => x.trim()).filter(Boolean);
  if (!sentences.length) return false;
  const prog = sentences.filter((x) => PROGRESS_RX.test(x)).length;
  return prog >= 1 && prog * 2 >= sentences.length;
}

/* Découpage en blocs : { k:"fence", lang, body } ou { k:"text", text } (paragraphes séparés par une ligne vide). */
function parseBlocks(src) {
  const lines = String(src).replace(/\r\n?/g, "\n").split("\n");
  const blocks = [];
  let para = [];
  const flush = () => { if (para.length) { blocks.push({ k: "text", text: para.join("\n") }); para = []; } };
  let i = 0;
  while (i < lines.length) {
    const line = lines[i].replace(/[ \t]+$/, "");
    const m = FENCE_OPEN.exec(line);
    if (!m) {
      if (!line.trim()) flush();
      else if (/^\s*```/.test(line)) { /* ligne de clôture « ```xxx » mal formée isolée : retirée */ }
      else para.push(line);
      i++; continue;
    }
    const lang = m[1] || "";
    /* Recherche de la clôture : une ligne exactement « ``` ». Un bloc anonyme ouvert puis
       interrompu par un nouvel ouvrant nommé (```nova-suites…) était une clôture orpheline. */
    let j = i + 1, close = -1;
    for (; j < lines.length; j++) {
      const l = lines[j].trim();
      if (l === "```") { close = j; break; }
      if (!lang && /^```[\w-]+$/.test(l)) break;
    }
    if (close < 0) {
      if (/^nova-/.test(lang) && j >= lines.length) {   // bloc maison tronqué en fin de réponse : on le ferme
        flush(); blocks.push({ k: "fence", lang, body: lines.slice(i + 1).join("\n") }); break;
      }
      i++; continue;   // ``` orphelin : la ligne disparaît, le texte qui suit reste du texte
    }
    flush();
    blocks.push({ k: "fence", lang, body: lines.slice(i + 1, close).join("\n") });
    i = close + 1;
  }
  flush();
  return blocks;
}

/* Isole une ligne BLUF qui ne commence pas son paragraphe (« Voici.\n> **BLUF : … »). */
function splitAtBluf(blocks) {
  const out = [];
  for (const b of blocks) {
    if (b.k !== "text") { out.push(b); continue; }
    const ls = b.text.split("\n");
    const ix = ls.findIndex((l, n) => n > 0 && BLUF_RX.test(l));
    if (ix > 0) { out.push({ k: "text", text: ls.slice(0, ix).join("\n") }, { k: "text", text: ls.slice(ix).join("\n") }); }
    else out.push(b);
  }
  return out;
}

const suiteItems = (body) => String(body || "").split("\n").map((l) => l.replace(/^\s*[-•*\d.)]+\s*/, "").trim()).filter((l) => l.length > 3);

export function normalizeAnswer(input) {
  const src = String(input ?? "");
  if (!src.trim()) return "";
  let blocks = splitAtBluf(parseBlocks(src));

  /* 1. Blocs de code : vides retirés ; livrables, suites et pied mis de côté. */
  const livrables = [], suites = [], pied = { preuves: [], dots: "" };
  const rest = [];
  for (const b of blocks) {
    if (b.k !== "fence") { rest.push(b); continue; }
    if (!b.body.trim()) continue;
    if (b.lang === "nova-livrable") { const body = b.body.trim(); if (!livrables.includes(body)) livrables.push(body); continue; }
    if (b.lang === "nova-suites") { suites.push(...suiteItems(b.body)); continue; }
    if (b.lang === "nova-pied") {
      for (const l of b.body.split("\n")) {
        if (DOTS_RX.test(l)) pied.dots = l.trim();
        else if (PREUVE_RX.test(l)) pied.preuves.push(l.replace(PREUVE_RX, "").trim());
        else if (l.trim()) pied.preuves.push(l.trim());
      }
      continue;
    }
    rest.push(b);
  }
  const hasLiv = livrables.length > 0;

  /* 2. Lignes internes : notes du moteur recopiées ([Outils utilisés …], [MOTEUR NOVA…], [RÉSULTAT DE L'OUTIL…]) retirées ; DOTS → pied ; avec une carte livrable, « Chemin du fichier » disparaît
        et « Preuve : » passe au pied (l'information reste, en retrait). */
  blocks = [];
  for (const b of rest) {
    if (b.k !== "text") { blocks.push(b); continue; }
    const kept = [];
    for (const l of stripEngineNotes(b.text).split("\n")) {
      if (ENGINE_LINE_RX.test(l)) continue;
      if (DOTS_RX.test(l)) { pied.dots = l.trim().replace(/^[-*•]\s+/, "").replace(/\*\*/g, ""); continue; }
      if (hasLiv && CHEMIN_RX.test(l)) continue;
      if (hasLiv && PREUVE_RX.test(l)) { const v = l.replace(PREUVE_RX, "").replace(/\*\*/g, "").trim(); if (v) pied.preuves.push(v); continue; }
      kept.push(l);
    }
    if (kept.some((l) => l.trim())) blocks.push({ k: "text", text: kept.join("\n") });
  }

  /* 3. Narration d'étape retirée partout — sauf si elle est tout le texte (réponse d'une ligne). */
  const isText = (b) => b.k === "text";
  const narr = blocks.map((b) => isText(b) && isNarration(b.text));
  if (blocks.some((b, n) => isText(b) && !narr[n])) blocks = blocks.filter((b, n) => !narr[n]);

  /* 4. BLUF en tête ; la prose courte qui le précède (pré-résumé < 600 car.) est retirée,
        une prose substantielle et tout bloc structuré sont gardés, placés après le BLUF. */
  const bi = blocks.findIndex((b) => isText(b) && BLUF_RX.test(b.text));
  if (bi > 0) {
    const before = blocks.slice(0, bi);
    const prose = before.filter((b) => isText(b) && !isProtected(b.text));
    const total = prose.reduce((n, b) => n + b.text.trim().length, 0);
    const keptBefore = total < 600 ? before.filter((b) => !prose.includes(b)) : before;
    blocks = [blocks[bi], ...keptBefore, ...blocks.slice(bi + 1)];
  }

  /* 5. Paragraphes identiques dédoublonnés (le premier reste). */
  const seen = new Set();
  blocks = blocks.filter((b) => {
    if (isText(b) && isHr(b.text)) return true;
    const key = b.k + "|" + (b.lang || "") + "|" + norm(b.k === "text" ? b.text : b.body);
    if (seen.has(key)) return false;
    seen.add(key); return true;
  });

  /* 6. Assemblage : corps → livrable(s) → pied → suites (une seule rangée, 3 max). */
  const out = blocks.map((b) => (b.k === "text" ? b.text.trim() : "```" + b.lang + "\n" + b.body.replace(/^\n+|\s+$/g, "") + "\n```"));
  for (const l of livrables) out.push("```nova-livrable\n" + l + "\n```");
  const preuves = [...new Set(pied.preuves.filter(Boolean))];
  const piedLines = [];
  if (preuves.length) piedLines.push("Preuve : " + preuves.join(" · "));
  if (pied.dots) piedLines.push(pied.dots);
  if (piedLines.length) out.push("```nova-pied\n" + piedLines.join("\n") + "\n```");
  const items = [];
  for (const it of suites) { if (!items.some((x) => x.toLowerCase() === it.toLowerCase())) items.push(it); }
  if (items.length) out.push("```nova-suites\n" + items.slice(0, 3).map((x) => "- " + x).join("\n") + "\n```");
  return out.join("\n\n").replace(/\n{3,}/g, "\n\n").trim();
}

if (typeof window !== "undefined") { try { window.normalizeAnswer = normalizeAnswer; } catch (e) {} }
