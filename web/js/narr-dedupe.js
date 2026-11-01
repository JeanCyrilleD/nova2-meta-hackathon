/* narr-dedupe.js — 25/10 : anti-doublon de narration en flux.
   Après une étape d'outil, le cerveau reprend souvent par la même phrase (« Je lance… » deux fois,
   collées « …fin.Je lance… »). Le texte d'après l'étape est retenu jusqu'à sa 1re phrase ; si elle
   répète la dernière phrase d'avant (mots communs ≥ 60 %), elle est retirée ; sinon tout s'affiche,
   séparé par un saut de paragraphe. Usage : const n = createNarr(); acc = n.delta(t); n.boundary();
   n.reset(); acc = n.final(). */
const words = (x) => String(x).toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^a-z0-9 ]+/g, " ").split(/\s+/).filter((w) => w.length > 2);
export function simil(a, b) {
  const A = new Set(words(a)), B = new Set(words(b));
  if (!A.size || !B.size) return 0;
  let n = 0;
  A.forEach((w) => { if (B.has(w)) n++; });
  const small = Math.min(A.size, B.size), ratio = n / Math.max(A.size, B.size);
  /* 26/10 : une annonce contenue dans l'autre (≥ 75 % des mots de la plus courte) est un doublon. */
  if (small >= 3 && n / small >= 0.75) return Math.max(ratio, 0.6);
  return ratio;
}
const lastSent = (x) => { const parts = String(x).trim().split(/(?<=[.!?…])\s*/).filter((y) => y.trim()); return parts.length ? parts[parts.length - 1] : ""; };
export function createNarr() {
  let base = "", seg = "", segOn = false, segCut = -1, acc = "";
  const compose = (final) => {
    if (!segOn) { acc = base; return acc; }
    let shown = "";
    if (segCut < 0) {
      const m = seg.match(/^[\s\S]*?[.!?…](\s|$)/);
      if (m || seg.length > 240 || final) { const first = m ? m[0] : seg; segCut = simil(first, lastSent(base)) >= 0.6 ? first.length : 0; }
    }
    if (segCut >= 0) shown = seg.slice(segCut).replace(/^\s+/, "");
    acc = base + (shown && base.trim() && !/\n\s*$/.test(base) ? "\n\n" : "") + shown;
    return acc;
  };
  return {
    delta(t) { if (segOn) seg += t || ""; else base += t || ""; return compose(false); },
    boundary() { if (!acc.trim()) return; compose(true); base = acc; seg = ""; segOn = true; segCut = -1; },
    reset() { base = ""; seg = ""; segOn = false; segCut = -1; acc = ""; return acc; },
    final() {
      compose(true);
      /* 25/10 : à la fin, les annonces d'étape (« Je lance… », « Je vérifie… ») se réduisent à la première. */
      /* 26/10 : annonces d'étape retirées de la réponse finale dès qu'il y a un vrai résultat (sinon la dernière seule) ; phrases collées séparées. */
      const paras = acc.replace(/([.!?…])(?=[A-ZÉÈÀÂÎÔÛÇ])/g, "$1\n\n").split(/\n{2,}/).map((p) => p.trim()).filter(Boolean);
      const ANN = /^(Oui,? )?(je|j['’])\s*(t['’]entends|lance|ouvre|cherche|récupère|vérifie|regarde|consulte|prépare|reprends|relance|passe|bascule|change|tente|poursuis|remplis|retrouve|liste|essaie|m['’]en occupe|m['’]occupe|lis|analyse|reviens|continue|attaque|démarre|te connecte|te prépare)\b/i;
      let lastAnn = "";
      const kept = paras.filter((t) => { const ann = t.length < 170 && !t.includes("\n") && ANN.test(t); if (ann) { lastAnn = t; return false; } return true; });
      acc = kept.length ? kept.join("\n\n") : (lastAnn || acc);
      return acc;
    },
    get text() { return acc; },
  };
}
