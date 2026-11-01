/* richtext.js — RENDU STRUCTURÉ DU « FORMAT MAISON » (V5-W, 25/10/2026, ordre d'Ahadi :
   « why are some Éclat or direct or feed messages not polished? »).

   Les Éclats, le Fil direct et certaines réponses rendent un texte compact du moteur :

     STATUT : PARTIEL — gardien à signaler ## ops STATUT : OK RAS — system 25/10/2026 :
     batterie 33 %, mémoire 75 % … ## gardien STATUT : PARTIEL — anomalies mesurées
     - Boîte noire ALTÉRÉE … - cerveau X 12 échecs … À TOI : Faut-il recharger …

   Ce module le met en page, SANS rien inventer ni retirer :
     · « STATUT : X — résumé »      → pastille d'état (OK/RAS vert, PARTIEL/À SIGNALER ambre,
                                      ÉCHEC/KO rouge) + résumé ;
     · « ## section »                → section titrée, avec sa propre pastille et son texte ;
     · puces « - » (même en ligne)   → vraie liste ;
     · « batterie 33 %, mémoire … »  → pastilles de mesure (libellé + valeur ; couleur seulement
                                      si un seuil est écrit dans le texte : « 33 % > 20 % ») ;
     · horodatages ISO « 10:54:28Z » → heure locale « 10:54 » ;
     · « À TOI : question »          → bloc de décision en fin de carte.
   Tout le contenu est ÉCHAPPÉ avant mise en forme (esc) : aucune balise venue du texte n'est
   jamais interprétée. Module SANS import : core.js l'appelle depuis md() et cleanResume()
   (aucun cycle). Classes CSS : .rt-* (nova2.css, bloc V5-W). */

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

/* ── Détection ─────────────────────────────────────────────────────────── */
const ST_WORDS = ["OK", "RAS", "PARTIEL", "ÉCHEC", "ECHEC", "KO", "ERREUR", "ALERTE", "ATTENTION", "À SIGNALER", "A SIGNALER", "EN COURS", "INCONNU"];
const ST_RE = /(?:^|[\s(])(?:STATUT|STATUS)\s*:\s*(?:À SIGNALER|A SIGNALER|EN COURS|OK|RAS|PARTIEL|ÉCHEC|ECHEC|KO|ERREUR|ALERTE|ATTENTION|INCONNU)\b/;
const ASK_RE = /(?:^|\s)(?:À|A) TOI\s*:\s*/;
/** Vrai si le texte porte le format maison (statut, sections en ligne, « À TOI : »). */
export function isHouse(src) {
  const s = String(src || "");
  if (!s || /```/.test(s)) return false;
  return ST_RE.test(s) || (s.match(/\S[ \t]+##[ \t]+\S/g) || []).length >= 2 || ASK_RE.test(s);
}

/* ── États ─────────────────────────────────────────────────────────────── */
function stateOf(words) {
  const w = String(words || "").toUpperCase();
  if (!w) return null;
  if (/ÉCHEC|ECHEC|\bKO\b|ERREUR/.test(w)) return { k: "bad", label: /KO/.test(w) ? "KO" : /ERREUR/.test(w) ? "Erreur" : "Échec" };
  if (/PARTIEL/.test(w)) return { k: "warn", label: "Partiel" };
  if (/SIGNALER|ALERTE|ATTENTION/.test(w)) return { k: "warn", label: "À signaler" };
  if (/EN COURS/.test(w)) return { k: "info", label: "En cours" };
  if (/INCONNU/.test(w)) return { k: "info", label: "Inconnu" };
  if (/\bOK\b/.test(w) && /\bRAS\b/.test(w)) return { k: "ok", label: "OK · RAS" };
  if (/\bOK\b/.test(w)) return { k: "ok", label: "OK" };
  if (/\bRAS\b/.test(w)) return { k: "ok", label: "RAS" };
  return null;
}
/** Retire « STATUT : MOTS — » en tête et rend { st, rest }. */
function takeStatus(text) {
  let s = String(text || "").trim();
  const m = /^(?:STATUT|STATUS)\s*:\s*/.exec(s);
  if (!m) return { st: null, rest: s };
  s = s.slice(m[0].length);
  const words = [];
  for (;;) {
    const w = ST_WORDS.find((x) => s.startsWith(x) && !/[A-Za-zÀ-ÿ0-9]/.test(s.charAt(x.length)));
    if (!w) break;
    words.push(w); s = s.slice(w.length).replace(/^[ \t]+/, "");
  }
  s = s.replace(/^[—–:·-]\s*/, "");
  return { st: stateOf(words.join(" ")), rest: s.trim() };
}
const cap = (s) => { const t = String(s || "").trim(); return t ? t.charAt(0).toUpperCase() + t.slice(1) : t; };
const SEC_NAMES = { ops: "Ops", mac: "Mac", gardien: "Gardien", system: "Système", systeme: "Système", "système": "Système", brvm: "BRVM", cpu: "CPU", gpu: "GPU", ia: "IA", runs: "Exécutions", cerveaux: "Cerveaux", mail: "Courrier", courrier: "Courrier" };
const secTitle = (t) => { const k = String(t || "").trim().toLowerCase(); return SEC_NAMES[k] || cap(String(t || "").trim().replace(/[_-]+/g, " ")); };

/* ── Inline : échappement puis mise en forme sûre ──────────────────────── */
const thisYear = String(new Date().getFullYear());
function localHM(dateStr, hms) {
  /* « 25/10/2026 10:54:28Z » ou « 10:54:28Z » → heure locale « 10:54 » ; date française tenue par l'appelant. */
  try {
    let y, mo, d;
    const dm = /^(\d{2})\/(\d{2})\/(\d{4})$/.exec(dateStr || "");
    if (dm) { d = +dm[1]; mo = +dm[2] - 1; y = +dm[3]; } else { const n = new Date(); y = n.getUTCFullYear(); mo = n.getUTCMonth(); d = n.getUTCDate(); }
    const [H, M, S] = hms.split(":").map(Number);
    const t = new Date(Date.UTC(y, mo, d, H, M, S || 0));
    if (isNaN(t)) return hms;
    return t.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });
  } catch (e) { return hms; }
}
function timeFix(s) {
  return String(s)
    .replace(/\b(\d{4})-(\d{2})-(\d{2})T(\d{2}:\d{2}(?::\d{2})?)(?:\.\d+)?Z\b/g, (_, y, mo, d, hms) => d + "/" + mo + (y !== thisYear ? "/" + y : "") + " " + localHM(d + "/" + mo + "/" + y, hms))
    .replace(/\b(\d{2}\/\d{2}\/\d{4})\s+(à\s+)?(\d{2}:\d{2}(?::\d{2})?)(?:\.\d+)?Z\b/g, (all, dt, a, hms) => dt + (a ? " à " : " ") + localHM(dt, hms))
    .replace(/\b(\d{2}:\d{2}(?::\d{2})?)(?:\.\d+)?Z\b/g, (_, hms) => localHM("", hms))
    .replace(/\b(\d{2})\/(\d{2})\/(\d{4})\b/g, (all, d, mo, y) => (y === thisYear ? d + "/" + mo : all));
}
const ALARM = /(?<![A-Za-zÀ-ÿ])(ALTÉRÉE?S?|ÉCHECS?|ECHECS?|PANNE|CRITIQUE|ÉPUISÉE?S?|BLOQUÉE?S?|KO)(?![A-Za-zÀ-ÿ])/g;
/** Texte d'une ligne → HTML sûr (gras, italique, code, liens http/mailto, heures locales, mots d'alarme). */
export function inlineHTML(src) {
  let s = esc(timeFix(String(src || "")));
  const keep = [];
  s = s.replace(/`([^`\n]+)`/g, (_, c) => { keep.push("<code>" + c + "</code>"); return "\u0001" + (keep.length - 1) + "\u0001"; });
  s = s.replace(/\[([^\]]+)\]\(((?:https?:|mailto:)[^)\s]+)\)/g, (_, l, u) => { keep.push('<a href="' + u + '" target="_blank" rel="noopener noreferrer">' + l + "</a>"); return "\u0001" + (keep.length - 1) + "\u0001"; });
  s = s.replace(/\*\*([^\s*](?:[^*]*[^\s*])?)\*\*/g, "<b>$1</b>").replace(/\*\*/g, "")
    .replace(/(^|[^*\w])\*([^*\s][^*]*?)\*(?!\w)/g, "$1<i>$2</i>")
    .replace(ALARM, '<b class="rt-alarm">$1</b>');
  return s.replace(/\u0001(\d+)\u0001/g, (_, i) => keep[+i]);
}

/* ── Mesures : « batterie 33 %, mémoire 75 % … » → pastilles ───────────── */
const NUM = "(\\d+(?:[.,]\\d+)?)";
const UNIT = "(%|Go|Mo|Ko|To|°C|ms|GHz|W)";
const ITEM_RE = new RegExp("^([A-Za-zÀ-ÿ][A-Za-zÀ-ÿ'’.]*(?:\\s[A-Za-zÀ-ÿ'’.]+){0,2}?)\\s+" + NUM + "\\s*" + UNIT + "(\\s+(?:libres?|utilisée?s?|occupée?s?))?\\s*(?:\\(([^)]{1,40})\\))?\\s*(?:(>=|<=|>|<|≥|≤)\\s*" + NUM + "\\s*" + UNIT + "?)?\\s*[.;]?$");
const toN = (x) => Number(String(x).replace(",", "."));
function parseMetricList(str) {
  const parts = String(str || "").trim().replace(/[.;]\s*$/, "").split(/,\s+|\s+et\s+(?=[A-Za-zÀ-ÿ]+\s+\d)/);
  if (parts.length < 2) return null;
  const out = [];
  for (const p of parts) {
    const m = ITEM_RE.exec(p.trim());
    if (!m) return null;
    const [, label, v, u, qual, paren, op, thr, tu] = m;
    let k = "n";
    if (op) {
      const a = toN(v), b = toN(thr);
      const okv = op === ">" ? a > b : op === "<" ? a < b : op === ">=" || op === "≥" ? a >= b : a <= b;
      k = okv ? "ok" : "bad";
    }
    out.push({ label: cap(label + (qual ? " " + qual.trim() : "")), value: v + " " + u, sub: [paren || "", op ? "seuil " + op + " " + thr + " " + (tu || u) : ""].filter(Boolean).join(" · "), k });
  }
  return out;
}
/** Cherche une liste de mesures dans une phrase : { lead, metrics, tail } ou null. */
function findMetrics(text) {
  const t = String(text || "").trim();
  const cands = [-1];
  for (let i = t.indexOf(":"); i >= 0; i = t.indexOf(":", i + 1)) { if (/\s/.test(t.charAt(i + 1) || " ") && !/\d/.test(t.charAt(i - 1))) cands.push(i); }
  for (const i of cands) {
    const rest = t.slice(i + 1);
    const ms = parseMetricList(rest);
    if (ms && ms.length >= 2) return { lead: i >= 0 ? t.slice(0, i).trim() : "", metrics: ms };
  }
  return null;
}
function metricsHTML(ms) {
  return '<div class="rt-metrics">' + ms.map((m) => '<span class="rt-m rt-m-' + m.k + '"' + (m.sub ? ' title="' + esc(m.sub) + '"' : "") + '><span class="rt-m-k">' + esc(m.label) + '</span><b class="rt-m-v">' + esc(m.value) + "</b>" + (m.sub ? '<span class="rt-m-s">' + esc(m.sub) + "</span>" : "") + "</span>").join("") + "</div>";
}
const LEAD_WORDS = { system: "Système", status: "Statut" };
const leadText = (s) => cap(String(s || "").replace(/^(\w+)/, (w) => LEAD_WORDS[w.toLowerCase()] || w));

/* ── Corps d'une section : lignes, puces (même en ligne), mesures ──────── */
function lineHTML(line) {
  const mt = findMetrics(line);
  if (mt) return (mt.lead ? '<div class="rt-cap">' + inlineHTML(leadText(mt.lead)) + "</div>" : "") + metricsHTML(mt.metrics);
  return "<p>" + inlineHTML(cap(line)) + "</p>";
}
function splitInlineBullets(text) {
  const pieces = String(text).split(/\s+[-•]\s+(?=\S)/);
  if (pieces.length >= 3) return { lead: pieces[0].trim(), items: pieces.slice(1) };
  if (pieces.length === 2 && (/:\s*$/.test(pieces[0]) || pieces[0].trim().split(/\s+/).length <= 4)) return { lead: pieces[0].trim(), items: pieces.slice(1) };
  return null;
}
function bodyHTML(body) {
  const out = [];
  const lines = String(body || "").split(/\n+/).map((l) => l.trim()).filter(Boolean);
  let list = [];
  const flush = () => { if (list.length) { out.push('<ul class="rt-list">' + list.map((x) => "<li>" + inlineHTML(cap(x)) + "</li>").join("") + "</ul>"); list = []; } };
  for (let l of lines) {
    l = l.replace(/^#{1,4}\s+/, "");
    const bm = /^(?:[-•*]|\d+[.)])\s+(.*)$/.exec(l);
    if (bm) { list.push(bm[1]); continue; }
    flush();
    const sb = splitInlineBullets(l);
    if (sb) {
      if (sb.lead) out.push(lineHTML(sb.lead.replace(/:\s*$/, "")));
      out.push('<ul class="rt-list">' + sb.items.map((x) => "<li>" + (findMetrics(x) ? lineHTML(x) : inlineHTML(cap(x.trim().replace(/\.$/, "")))) + "</li>").join("") + "</ul>");
      continue;
    }
    out.push(lineHTML(l));
  }
  flush();
  return out.join("");
}

/* ── Analyse complète ──────────────────────────────────────────────────── */
/** { st, summary, pre, sections:[{title, st, body}], ask } */
export function parseHouse(src) {
  let s = String(src || "").replace(/\r/g, "").replace(/\s*\[Ouvrir\s*:\s*[^\]]{1,40}\]\s*/g, " ").trim();
  let ask = "";
  const am = ASK_RE.exec(s);
  if (am) {
    ask = s.slice(am.index + am[0].length).trim();
    s = s.slice(0, am.index).trim();
  } else {
    const qm = /\n\s*Question\s*:\s*([^\n]+)\s*$/.exec(s);   // « Question : … » en dernière ligne = décision demandée
    if (qm) { ask = qm[1].trim(); s = s.slice(0, qm.index).trim(); }
  }
  if (ask) {
    if (!/[?.!…]$/.test(ask) && /^(faut|dois|veux|est-ce|je |on |peut|souhait|valide|confirme|garde|lance|recharge)/i.test(ask)) ask += " ?";
  }
  const chunks = s.split(/(?:^|[ \t\n]+)##[ \t]+/);
  const headRaw = chunks.shift() || "";
  const sections = [];
  for (const c of chunks) {
    const t = c.trim(); if (!t) continue;
    let title = "", body = t;
    const sm = /^(.{1,40}?)\s+(?=(?:STATUT|STATUS)\s*:)/.exec(t);
    if (sm) { title = sm[1]; body = t.slice(sm[0].length); }
    else { const nl = t.indexOf("\n"); const first = nl >= 0 ? t.slice(0, nl) : t; if (nl >= 0 && first.length <= 60) { title = first; body = t.slice(nl + 1); } else { const w = /^(\S+)\s*/.exec(t); title = w ? w[1] : t; body = t.slice(w ? w[0].length : t.length); } }
    const { st, rest } = takeStatus(body);
    sections.push({ title: secTitle(title.replace(/[:—–-]\s*$/, "")), st, body: rest });
  }
  // Tête : « STATUT : X — résumé » (+ reste éventuel, lignes suivantes)
  const head = headRaw.trim();
  const nl = head.indexOf("\n");
  const firstLine = nl >= 0 ? head.slice(0, nl) : head;
  const after = nl >= 0 ? head.slice(nl + 1).trim() : "";
  const stIdx = firstLine.search(/(?:STATUT|STATUS)\s*:/);
  let pre = "", st = null, summary = "", more = after;
  if (stIdx >= 0) {
    pre = firstLine.slice(0, stIdx).replace(/[\s:—–-]+$/, "").trim();
    const r = takeStatus(firstLine.slice(stIdx));
    st = r.st; summary = r.rest;
  } else { summary = firstLine; }
  return { st, summary: summary.trim(), pre, more, sections, ask };
}

const chip = (st, cls = "") => st ? '<span class="rt-chip rt-' + st.k + (cls ? " " + cls : "") + '">' + esc(st.label) + "</span>" : "";
/** HTML complet (cartes dépliées, panneaux de run, bulles de conversation). */
export function houseHTML(src) {
  const p = parseHouse(src);
  const out = ['<div class="rt rt-house">'];
  if (p.pre) out.push('<p class="rt-pre">' + inlineHTML(p.pre) + "</p>");
  if (p.st || p.summary) {
    const sb = p.summary ? splitInlineBullets(p.summary) : null;
    out.push('<div class="rt-head">' + chip(p.st) + (p.summary && !sb ? '<span class="rt-sum">' + inlineHTML(cap(p.summary)) + "</span>" : "") + "</div>");
    if (sb) out.push('<div class="rt-sec-b">' + bodyHTML(p.summary) + "</div>");
  }
  if (p.more) out.push('<div class="rt-more">' + bodyHTML(p.more) + "</div>");
  if (p.sections.length) {
    out.push('<div class="rt-secs">');
    for (const sec of p.sections) {
      out.push('<section class="rt-sec" data-st="' + (sec.st ? sec.st.k : "n") + '"><div class="rt-sec-h"><span class="rt-sec-t">' + esc(sec.title) + "</span>" + chip(sec.st, "sm") + "</div>"
        + (sec.body ? '<div class="rt-sec-b">' + bodyHTML(sec.body) + "</div>" : "") + "</section>");
    }
    out.push("</div>");
  }
  if (p.ask) out.push('<div class="rt-ask"><span class="rt-ask-k">À toi</span><span class="rt-ask-q">' + inlineHTML(cap(p.ask)) + "</span></div>");
  out.push("</div>");
  return out.join("");
}
/** HTML replié (carte fermée) : pastille + UNE ligne de résumé + mini-états des sections. */
export function houseCompactHTML(src, withAsk = false) {
  const p = parseHouse(src);
  const sum = p.summary ? cap(p.summary.split(/\s+[-•]\s+/)[0]).replace(/[.;:]\s*$/, "") : (p.sections[0] ? p.sections[0].title : "");
  const minis = p.sections.filter((x) => x.st).map((x) => '<span class="rt-mini rt-' + x.st.k + '"><i></i>' + esc(x.title) + "</span>").join("");
  return '<div class="rt rt-compact"><div class="rt-head">' + chip(p.st) + (sum ? '<span class="rt-sum">' + inlineHTML(sum) + "</span>" : "") + "</div>"
    + (minis ? '<div class="rt-minis">' + minis + "</div>" : "")
    + (withAsk && p.ask ? '<div class="rt-ask sm"><span class="rt-ask-k">À toi</span><span class="rt-ask-q">' + inlineHTML(cap(p.ask)) + "</span></div>" : "") + "</div>";
}
/** Résumé texte (une ligne) : « Partiel — Gardien à signaler · Ops OK · Mac OK · Gardien partiel ». */
export function houseSummary(src) {
  const p = parseHouse(src);
  const head = [p.st ? p.st.label : "", p.summary ? cap(timeFix(p.summary.split(/\s+[-•]\s+/)[0])).replace(/[.;:]\s*$/, "") : ""].filter(Boolean).join(" — ");
  const secs = p.sections.filter((x) => x.st).map((x) => x.title + " " + (x.st.k === "ok" ? "OK" : x.st.label.toLowerCase()));
  return [head, ...secs].filter(Boolean).join(" · ") + (p.ask ? (head || secs.length ? " · " : "") + "À toi : " + cap(p.ask) : "");
}
