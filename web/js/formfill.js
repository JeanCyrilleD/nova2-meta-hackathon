/* formfill.js — 25/10 : côté fenêtre de l'outil « formulaire » (Feat_Formulaire.swift).
   Le moteur envoie l'ordre SSE « ui » op « formulaire » {pane, act, valeurs?, empreinte?, confirmed?} ;
   uibridge.js l'aiguille ici (handleForm) et renvoie le constat par POST /api/ui/result.
   - lire     : champs visibles de la page du volet (libellé, name/id, type, valeur, requis, options,
                sélecteur stable) ; champs cachés ignorés ; champs PROTÉGÉS listés SANS leur valeur.
   - origine  : adresse + referrer de la page (le moteur refuse de remplir une page atteinte par un lien
                de mail/document qu'Ahadi n'a pas demandée).
   - remplir  : pose les valeurs (setter natif + input/change : compatible React), N'ENVOIE RIEN ;
                bandeau « Nova a rempli N champs… » + surlignage léger des champs remplis.
   - resume   : page, valeurs remplies relues, libellé du bouton d'envoi, empreinte (pour la carte).
   - soumettre: clic du bouton d'envoi, UNIQUEMENT avec confirmed:true (posé par le moteur après le GO
                d'Ahadi sur la carte) ET une empreinte identique à celle de la carte.
   EXCLUSIONS DURES (code, pas prompt) : mot de passe, carte bancaire, CVV, IBAN/RIB, n° de compte,
   sécurité sociale, passeport, pièce d'identité, OTP / code de vérification, CAPTCHA : jamais lus,
   jamais remplis — « à remplir par toi ». Aucune résolution de CAPTCHA.
   paneFormScript est une fonction AUTONOME (aucune fermeture) sérialisée par toString(), comme
   paneGmailCorps : elle s'exécute DANS le volet web et rend une chaîne JSON. */

export function paneFormScript(ACT, ARG) {
  try {
    ARG = ARG || {};
    var norm = function (s) { return String(s == null ? "" : s).toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/\s+/g, " ").trim(); };
    var txt = function (e) { return e ? String(e.innerText || e.textContent || "").replace(/\s+/g, " ").trim() : ""; };
    // 25/10 : champs protégés — même famille que NovaForm.sensitiveRx côté moteur (double garde).
    var SENS = /(mot de passe|password|passwd|passcode|\bpin\b|code pin|numero de (la )?carte|n° de carte|card ?(number|no|num)|cardnumber|credit ?card|carte (bancaire|de credit)|\bcc-?(number|num|csc|exp|name)|\bcvv|\bcvc|\bcsc\b|cryptogramme|security code|code de securite|\biban\b|\brib\b|\bbic\b|\bswift\b|numero de compte|n° de compte|account ?(number|no|num)|routing|sort code|\bssn\b|social security|securite sociale|passport|passeport|national ?id|identite nationale|carte d.identite|piece d.identite|\bcni\b|\bnin\b|\botp\b|one.?time|code de verification|verification code|code de confirmation|confirmation code|code (recu|envoye) par sms|\b2fa\b|\btotp\b|captcha)/;
    var AC = /(^|\s)(cc-[a-z-]+|current-password|new-password|one-time-code)(\s|$)/;
    var PAY = /(payer|paiement|pay\b|pay now|acheter|buy|commander|passer (la )?commande|place order|checkout|regler|valider (le|mon) (paiement|achat)|souscrire et payer)/;
    var SUBMIT_TXT = /(envoyer|valider|soumettre|submit|send|continuer|confirmer|s.inscrire|inscription|register|sign up|enregistrer|save|suivant|next|terminer|postuler|candidater|demander|reserver|publier|payer|commander)/;
    var cssq = function (s) { return (window.CSS && CSS.escape) ? CSS.escape(s) : String(s).replace(/[^a-zA-Z0-9_-]/g, "\\$&"); };
    var qv = function (s) { return String(s).replace(/\\/g, "\\\\").replace(/"/g, "\\\""); };
    var shown = function (e) {
      if (!e || !e.getBoundingClientRect) return false;
      var cs = getComputedStyle(e);
      if (cs.display === "none" || cs.visibility === "hidden") return false;
      var r = e.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    };
    var labelEl = function (e) {
      if (e.id) { try { var l = document.querySelector("label[for=\"" + qv(e.id) + "\"]"); if (l) return l; } catch (x) {} }
      return e.closest ? e.closest("label") : null;
    };
    var ownText = function (node, e) {
      var out = "";
      for (var i = 0; i < node.childNodes.length; i++) {
        var c = node.childNodes[i];
        if (c === e) continue;
        if (c.nodeType === 3) out += " " + c.textContent;
        else if (c.nodeType === 1) {
          if (c.contains(e)) out += " " + ownText(c, e);
          else if (!/^(SELECT|OPTION|SCRIPT|STYLE)$/.test(c.tagName)) out += " " + (c.innerText || c.textContent || "");
        }
      }
      return out.replace(/\s+/g, " ").trim();
    };
    var labelOf = function (e) {
      var t = "";
      var lb = labelEl(e);
      if (lb) t = lb.contains(e) ? ownText(lb, e) : txt(lb);
      if (!t) {
        var ids = String(e.getAttribute("aria-labelledby") || "").split(/\s+/).filter(Boolean);
        t = ids.map(function (i) { return txt(document.getElementById(i)); }).join(" ").trim();
      }
      if (!t) t = String(e.getAttribute("aria-label") || "").trim();
      if (!t) t = String(e.getAttribute("placeholder") || "").trim();
      if (!t) t = String(e.getAttribute("title") || "").trim();
      if (!t) {
        var p = e.previousElementSibling, k = 0;
        while (p && !t && k < 3) { if (!/^(INPUT|SELECT|TEXTAREA|BUTTON)$/.test(p.tagName)) t = txt(p); p = p.previousElementSibling; k++; }
      }
      if (!t && e.parentElement) t = ownText(e.parentElement, e);
      return t.slice(0, 90);
    };
    var uniq = function (sel, e) { try { var l = document.querySelectorAll(sel); return l.length === 1 && l[0] === e; } catch (x) { return false; } };
    var selOf = function (e) {
      if (e.id && uniq("#" + cssq(e.id), e)) return "#" + cssq(e.id);
      var tag = e.tagName.toLowerCase();
      var nm = e.getAttribute("name");
      if (nm) {
        var s = tag + "[name=\"" + qv(nm) + "\"]";
        if (uniq(s, e)) return s;
        var s2 = s + "[value=\"" + qv(e.value) + "\"]";
        if ((e.type === "radio" || e.type === "checkbox") && uniq(s2, e)) return s2;
      }
      var path = [], cur = e;
      while (cur && cur.nodeType === 1 && cur !== document.documentElement) {
        if (cur !== e && cur.id && uniq("#" + cssq(cur.id), cur)) { path.unshift("#" + cssq(cur.id)); break; }
        var i = 1, sib = cur;
        while ((sib = sib.previousElementSibling)) { if (sib.tagName === cur.tagName) i++; }
        path.unshift(cur.tagName.toLowerCase() + ":nth-of-type(" + i + ")");
        cur = cur.parentElement;
      }
      return path.join(">");
    };
    var kindOf = function (e) {
      var tag = e.tagName.toLowerCase();
      if (tag === "input") return String(e.getAttribute("type") || "text").toLowerCase();
      if (tag === "select") return e.multiple ? "select-multiple" : "select";
      if (tag === "textarea") return "textarea";
      return "texte-riche";
    };
    var visibleField = function (e, kind) {
      if (e.closest && e.closest("[hidden],#nova-form-banner")) return false;
      if (shown(e)) return true;
      if (kind === "checkbox" || kind === "radio") { var lb = labelEl(e); return !!(lb && shown(lb)); }
      return false;
    };
    var collect = function () {
      var els = [].slice.call(document.querySelectorAll("input,select,textarea,[contenteditable=\"true\"][role=\"textbox\"],[contenteditable=\"\"][role=\"textbox\"]"));
      var out = [], groups = {};
      for (var i = 0; i < els.length && out.length < 80; i++) {
        var e = els[i], kind = kindOf(e);
        if (["hidden", "submit", "button", "reset", "image"].indexOf(kind) >= 0) continue;
        if (e.disabled) continue;
        if (!visibleField(e, kind)) continue;
        if (kind === "radio" && e.name) {
          var key = (e.form ? "f" + [].indexOf.call(document.forms, e.form) : "d") + "|" + e.name;
          if (groups[key]) { groups[key].els.push(e); continue; }
          groups[key] = { kind: "radio", el: e, els: [e] };
          out.push(groups[key]);
          continue;
        }
        out.push({ kind: kind, el: e, els: [e] });
      }
      return out;
    };
    var groupLabel = function (f) {
      var e = f.el;
      var fs = e.closest ? e.closest("fieldset") : null;
      if (fs) { var lg = fs.querySelector("legend"); if (lg && txt(lg)) return txt(lg).slice(0, 90); }
      var rg = e.closest ? e.closest("[role=\"radiogroup\"]") : null;
      if (rg) {
        var t = String(rg.getAttribute("aria-label") || "").trim();
        if (!t) { var ids = String(rg.getAttribute("aria-labelledby") || "").split(/\s+/).filter(Boolean); t = ids.map(function (i) { return txt(document.getElementById(i)); }).join(" ").trim(); }
        if (t) return t.slice(0, 90);
      }
      // texte qui précède le premier bouton radio dans son conteneur commun
      var c = e.parentElement, k = 0;
      while (c && k < 3) {
        var all = f.els.every(function (r) { return c.contains(r); });
        if (all) {
          var p = c.previousElementSibling;
          if (p && txt(p) && txt(p).length < 120) return txt(p).slice(0, 90);
        }
        c = c.parentElement; k++;
      }
      return String(e.name || "").slice(0, 90);
    };
    var sigOf = function (e, lab) {
      return norm([lab, e.getAttribute("name"), e.id, e.getAttribute("placeholder"), e.getAttribute("aria-label"), e.getAttribute("autocomplete"), e.getAttribute("title")].join(" "));
    };
    var isSens = function (e, lab) {
      if (String(e.getAttribute("type") || "").toLowerCase() === "password") return true;
      if (AC.test(String(e.getAttribute("autocomplete") || "").toLowerCase())) return true;
      return SENS.test(sigOf(e, lab));
    };
    var groupSel = function (f) { return "input[type=\"radio\"][name=\"" + qv(f.el.name) + "\"]"; };
    var describe = function (f, i) {
      var e = f.el;
      var lab = f.kind === "radio" ? groupLabel(f) : labelOf(e);
      var d = { n: i + 1, sel: (f.kind === "radio" && e.name) ? groupSel(f) : selOf(e), label: lab, name: e.getAttribute("name") || "", id: e.id || "", type: f.kind,
        requis: !!(e.required || e.getAttribute("aria-required") === "true") };
      var sens = f.els.some(function (x) { return isSens(x, f.kind === "radio" ? lab + " " + labelOf(x) : lab); });
      if (sens) { d.sensible = true; d.note = "à remplir par toi"; return d; }
      if (f.kind === "file") { d.nonRemplissable = true; d.note = "fichier : à joindre par toi"; return d; }
      if (f.kind === "checkbox") d.valeur = e.checked ? "coché" : "non coché";
      else if (f.kind === "radio") {
        var on = f.els.filter(function (r) { return r.checked; })[0];
        d.valeur = on ? (labelOf(on) || on.value) : "";
        d.options = f.els.slice(0, 30).map(function (r) { return (labelOf(r) || r.value).slice(0, 60); });
      } else if (f.kind === "select" || f.kind === "select-multiple") {
        d.valeur = [].slice.call(e.selectedOptions || []).map(function (o) { return txt(o) || o.value; }).join(", ").slice(0, 120);
        d.options = [].slice.call(e.options).slice(0, 40).map(function (o) { return (txt(o) || o.value).slice(0, 60); });
      } else if (f.kind === "texte-riche") d.valeur = txt(e).slice(0, 120);
      else d.valeur = String(e.value || "").slice(0, 120);
      if (e.maxLength > 0 && e.maxLength < 100000) d.max = e.maxLength;
      return d;
    };
    var captcha = function () {
      var el = document.querySelector("iframe[src*=\"recaptcha\"],iframe[src*=\"hcaptcha\"],iframe[src*=\"turnstile\"],iframe[src*=\"captcha\"],.g-recaptcha,.h-captcha,.cf-turnstile,[data-sitekey]");
      if (!el) return { present: false, resolu: false };
      var resp = [].slice.call(document.querySelectorAll("textarea[name=\"g-recaptcha-response\"],textarea[name=\"h-captcha-response\"],input[name=\"cf-turnstile-response\"]"));
      return { present: true, resolu: resp.some(function (r) { return String(r.value || "").length > 10; }) };
    };
    var protoSet = function (e, v) {
      var proto = (e instanceof HTMLTextAreaElement) ? HTMLTextAreaElement.prototype : ((e instanceof HTMLSelectElement) ? HTMLSelectElement.prototype : HTMLInputElement.prototype);
      var pd = Object.getOwnPropertyDescriptor(proto, "value");
      if (pd && pd.set) pd.set.call(e, v); else e.value = v;
    };
    var fire = function (e) {
      e.dispatchEvent(new Event("input", { bubbles: true }));
      e.dispatchEvent(new Event("change", { bubbles: true }));
    };
    var truthy = function (v) { if (v === true) return true; var s = norm(v); return ["1", "oui", "true", "vrai", "yes", "coche", "cocher", "x", "on"].indexOf(s) >= 0; };
    var pickOpt = function (cands, labOf, v) {
      var nv = norm(v), hit = null;
      cands.forEach(function (c) { if (!hit && (norm(labOf(c)) === nv)) hit = c; });
      if (!hit) cands.forEach(function (c) { if (!hit && nv && norm(labOf(c)).indexOf(nv) >= 0) hit = c; });
      return hit;
    };
    var mark = function (e) {
      try {
        if (!e.hasAttribute("data-nova-rempli")) e.setAttribute("data-nova-rempli", String(e.style.getPropertyValue("box-shadow") || ""));
        e.style.setProperty("box-shadow", "0 0 0 2px rgba(124, 92, 255, 0.6)", "important");
        e.style.setProperty("transition", "box-shadow .2s");
      } catch (x) {}
    };
    var unmarkAll = function () {
      [].slice.call(document.querySelectorAll("[data-nova-rempli]")).forEach(function (e) {
        try { var prev = e.getAttribute("data-nova-rempli"); e.style.removeProperty("box-shadow"); if (prev) e.style.setProperty("box-shadow", prev); e.removeAttribute("data-nova-rempli"); } catch (x) {}
      });
      var b = document.getElementById("nova-form-banner"); if (b) b.remove();
    };
    var banner = function (n, aToi) {
      var b = document.getElementById("nova-form-banner");
      if (b) b.remove();
      b = document.createElement("div");
      b.id = "nova-form-banner";
      b.setAttribute("role", "status");
      var st = b.style;
      st.setProperty("position", "fixed", "important"); st.setProperty("top", "0", "important"); st.setProperty("left", "0", "important"); st.setProperty("right", "0", "important");
      st.setProperty("z-index", "2147483647", "important"); st.setProperty("display", "flex"); st.setProperty("align-items", "center"); st.setProperty("gap", "10px");
      st.setProperty("padding", "6px 12px"); st.setProperty("font", "500 12.5px/1.35 -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif");
      st.setProperty("color", "#1d1b2e"); st.setProperty("background", "rgba(237, 233, 255, 0.97)"); st.setProperty("border-bottom", "1px solid rgba(124, 92, 255, 0.35)");
      st.setProperty("box-shadow", "0 1px 6px rgba(0,0,0,.08)");
      var t = document.createElement("span");
      t.style.setProperty("flex", "1");
      t.textContent = "Nova a rempli " + n + " champ" + (n > 1 ? "s" : "") + " — vérifie, puis Valider l'envoi (carte)" + (aToi.length ? " · À remplir par toi : " + aToi.slice(0, 4).join(", ") + (aToi.length > 4 ? "…" : "") : "");
      var x = document.createElement("button");
      x.type = "button"; x.textContent = "×"; x.setAttribute("aria-label", "Masquer le bandeau de Nova");
      x.style.setProperty("border", "0"); x.style.setProperty("background", "transparent"); x.style.setProperty("font-size", "16px"); x.style.setProperty("cursor", "pointer"); x.style.setProperty("color", "#4b3fb0");
      x.addEventListener("click", function () { b.remove(); });
      b.appendChild(t); b.appendChild(x);
      (document.body || document.documentElement).appendChild(b);
    };
    var findField = function (fields, descs, k) {
      var key = String(k).trim(), nk = norm(key), i;
      if (/^#?\d+$/.test(key)) { var n = parseInt(key.replace("#", ""), 10); return n >= 1 && n <= fields.length ? n - 1 : -1; }
      for (i = 0; i < descs.length; i++) if (descs[i].sel === key) return i;
      for (i = 0; i < descs.length; i++) if ((descs[i].name && descs[i].name === key) || (descs[i].id && descs[i].id === key)) return i;
      for (i = 0; i < descs.length; i++) if (norm(descs[i].label) === nk) return i;
      for (i = 0; i < descs.length; i++) if (nk.length >= 3 && norm(descs[i].label).indexOf(nk) >= 0) return i;
      for (i = 0; i < descs.length; i++) if (nk.length >= 3 && (norm(descs[i].name).indexOf(nk) >= 0 || norm(descs[i].id).indexOf(nk) >= 0)) return i;
      /* 25/10 : titre de groupe (<legend> d'un fieldset : « Pizza Toppings ») → 1er champ du groupe */
      for (i = 0; i < fields.length; i++) {
        var el0 = fields[i].el || (fields[i].els && fields[i].els[0]);
        var fs0 = el0 && el0.closest ? el0.closest("fieldset") : null;
        var lg0 = fs0 ? fs0.querySelector("legend") : null;
        if (lg0 && nk.length >= 3 && norm(lg0.textContent || "").indexOf(nk) >= 0) return i;
      }
      return -1;
    };
    var setField = function (f, v) {
      var e = f.el;
      if (f.kind === "checkbox") {
        var want = truthy(v);
        if (e.checked !== want) e.click();
        if (e.checked !== want) { e.checked = want; fire(e); }
        mark(labelEl(e) || e);
        return { ok: e.checked === want, relu: e.checked ? "coché" : "non coché" };
      }
      if (f.kind === "radio") {
        var r = pickOpt(f.els, function (x) { return labelOf(x) || x.value; }, v) || pickOpt(f.els, function (x) { return x.value; }, v);
        if (!r) return { ok: false, erreur: "option introuvable : " + String(v).slice(0, 60) + " (options : " + f.els.map(function (x) { return labelOf(x) || x.value; }).join(" / ").slice(0, 200) + ")" };
        if (!r.checked) r.click();
        if (!r.checked) { r.checked = true; fire(r); }
        mark(labelEl(r) || r);
        return { ok: r.checked, relu: labelOf(r) || r.value };
      }
      if (f.kind === "select" || f.kind === "select-multiple") {
        var wants = f.kind === "select-multiple" ? (Array.isArray(v) ? v : String(v).split(/\s*[,;]\s*/)) : [v];
        var opts = [].slice.call(e.options);
        var picked = [];
        for (var j = 0; j < wants.length; j++) {
          var o = pickOpt(opts, function (x) { return txt(x) || x.value; }, wants[j]) || pickOpt(opts, function (x) { return x.value; }, wants[j]);
          if (!o) return { ok: false, erreur: "option introuvable : " + String(wants[j]).slice(0, 60) + " (options : " + opts.map(function (x) { return txt(x) || x.value; }).join(" / ").slice(0, 200) + ")" };
          picked.push(o);
        }
        e.focus();
        if (f.kind === "select-multiple") { opts.forEach(function (x) { x.selected = picked.indexOf(x) >= 0; }); }
        else protoSet(e, picked[0].value);
        fire(e); e.blur();
        mark(e);
        var relu = [].slice.call(e.selectedOptions || []).map(function (x) { return txt(x) || x.value; }).join(", ");
        return { ok: picked.every(function (x) { return x.selected; }), relu: relu.slice(0, 120) };
      }
      if (f.kind === "file") return { ok: false, erreur: "fichier : à joindre par toi" };
      var sv = String(v);
      e.focus();
      if (f.kind === "texte-riche") {
        try { document.execCommand("selectAll", false, null); document.execCommand("insertText", false, sv); } catch (x) {}
        if (txt(e) !== sv.replace(/\s+/g, " ").trim()) { e.textContent = sv; e.dispatchEvent(new Event("input", { bubbles: true })); }
        e.blur(); mark(e);
        return { ok: txt(e) === sv.replace(/\s+/g, " ").trim(), relu: txt(e).slice(0, 120) };
      }
      protoSet(e, sv);
      fire(e);
      e.blur();
      mark(e);
      var back = String(e.value == null ? "" : e.value);
      var r2 = { ok: back === sv, relu: back.slice(0, 120) };
      if (!r2.ok) r2.erreur = back ? "valeur relue différente (format du champ ou longueur maximale)" : "le champ est resté vide après saisie";
      return r2;
    };
    // Empreinte courte et stable (djb2) du résumé présenté sur la carte.
    var hash = function (s) { var h = 5381; for (var i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0; return h.toString(36); };
    var pageKey = function () { return location.origin + location.pathname; };
    var resume = function () {
      var st = window.__novaForm;
      var fields = collect(), descs = fields.map(describe);
      var filled = (st && st.page === pageKey()) ? st.champs : [];
      var rows = [], els = [];
      if (filled.length) {
        filled.forEach(function (c) {
          var i = -1;
          for (var k = 0; k < descs.length; k++) if (descs[k].sel === c.sel) { i = k; break; }
          if (i < 0) { rows.push({ label: c.label, valeur: "(champ disparu de la page)" }); return; }
          if (descs[i].sensible) return;
          rows.push({ label: descs[i].label || descs[i].name || ("champ " + descs[i].n), valeur: descs[i].valeur });
          els.push(fields[i].el);
        });
      }
      var form = null;
      if (els.length) {
        var cnt = new Map();
        els.forEach(function (e) { var fm = e.form || (e.closest ? e.closest("form") : null); if (fm) cnt.set(fm, (cnt.get(fm) || 0) + 1); });
        var best = 0; cnt.forEach(function (v, k) { if (v > best) { best = v; form = k; } });
      } else {
        var forms = [].slice.call(document.forms).filter(function (fm) { return fields.some(function (f) { return fm.contains(f.el); }); });
        if (forms.length === 1) {
          form = forms[0];
          fields.forEach(function (f, i) { if (form.contains(f.el) && !descs[i].sensible && !descs[i].nonRemplissable) { rows.push({ label: descs[i].label || descs[i].name || ("champ " + descs[i].n), valeur: descs[i].valeur }); els.push(f.el); } });
        }
      }
      var sensibles = [];
      fields.forEach(function (f, i) { if (descs[i].sensible && (!form || form.contains(f.el))) sensibles.push(descs[i].label || descs[i].name || ("champ " + descs[i].n)); });
      var btnLabel = function (b) { return (txt(b) || b.value || b.getAttribute("aria-label") || b.title || "").slice(0, 80); };
      var btn = null;
      if (form) {
        var bs = [].slice.call(form.querySelectorAll("button,input[type=\"submit\"],input[type=\"image\"]")).filter(function (b) { var ty = String(b.getAttribute("type") || "submit").toLowerCase(); return (ty === "submit" || ty === "image") && shown(b); });
        if (form.id) bs = bs.concat([].slice.call(document.querySelectorAll("[form=\"" + qv(form.id) + "\"]")).filter(function (b) { return /^(BUTTON|INPUT)$/.test(b.tagName) && shown(b); }));
        btn = bs.filter(function (b) { return SUBMIT_TXT.test(norm(btnLabel(b))); })[0] || bs[0] || null;
      }
      if (!btn && els.length) {   // SPA sans <form> : bouton d'envoi le plus proche des champs remplis
        var c = els[0].parentElement, k2 = 0;
        while (c && !btn && k2 < 7) {
          var cand = [].slice.call(c.querySelectorAll("button,[role=\"button\"],input[type=\"submit\"]")).filter(function (b) { return shown(b) && SUBMIT_TXT.test(norm(btnLabel(b))); });
          if (cand.length) btn = cand[cand.length - 1];
          c = c.parentElement; k2++;
        }
      }
      var cap = captcha();
      var out = { ok: true, url: location.href, titre: document.title || "", champs: rows, sensibles: sensibles, bouton: btn ? btnLabel(btn) : "", captcha: cap.present, captcha_resolu: cap.resolu };
      out.paiement = !!(btn && PAY.test(norm(btnLabel(btn))));
      out.empreinte = hash(JSON.stringify([out.url, rows, out.bouton]));
      if (!btn) { out.ok = false; out.erreur = "bouton d'envoi introuvable sur cette page (aucun bouton « Envoyer / Valider / Submit » repéré près des champs)"; }
      return { r: out, btn: btn, form: form };
    };

    if (ACT === "origine") {
      return JSON.stringify({ ok: true, url: location.href, referrer: document.referrer || "", titre: document.title || "" });
    }
    if (ACT === "lire") {
      var fl = collect(), ds = fl.map(describe);
      var cp = captcha();
      return JSON.stringify({ ok: true, url: location.href, titre: document.title || "", referrer: document.referrer || "", formulaires: document.forms.length, champs: ds, captcha: cp.present, captcha_resolu: cp.resolu });
    }
    if (ACT === "remplir") {
      var vals = ARG.valeurs || {};
      var fields = collect(), descs = fields.map(describe);
      var faits = [], echecs = [], refus = [];
      var st = window.__novaForm && window.__novaForm.page === pageKey() ? window.__novaForm : { page: pageKey(), champs: [] };
      Object.keys(vals).forEach(function (k) {
        var i = findField(fields, descs, k);
        if (i < 0) { echecs.push({ champ: k, erreur: "champ introuvable" }); return; }
        /* 25/10 : groupe de cases à cocher (même name, ex. « topping ») + valeur textuelle (« fromage », « Extra Cheese », « bacon, oignon »)
           → on coche les cases dont le libellé correspond, au lieu de la 1re case du groupe. */
        if (fields[i].kind === "checkbox" && !truthy(vals[k]) && !/^(non|no|false|faux|0|decoche|décoché|off)$/i.test(String(vals[k]).trim())) {
          var grpName = descs[i].name;
          var grp = []; for (var gi = 0; gi < fields.length; gi++) if (fields[gi].kind === "checkbox" && (grpName ? descs[gi].name === grpName : gi === i)) grp.push(gi);
          var wantsC = Array.isArray(vals[k]) ? vals[k] : String(vals[k]).split(/\s*[,;]\s*|\s+et\s+/);
          var hitAny = false;
          wantsC.forEach(function (w) {
            var nw = norm(w); if (!nw) return;
            var syn = { fromage: "cheese", oignon: "onion", champignon: "mushroom", lardons: "bacon" };
            var nw2 = syn[nw] ? norm(syn[nw]) : nw;
            for (var q = 0; q < grp.length; q++) {
              var lab = norm(descs[grp[q]].label + " " + (fields[grp[q]].el.value || ""));
              if (lab.indexOf(nw) >= 0 || lab.indexOf(nw2) >= 0) {
                var rr = setField(fields[grp[q]], true);
                if (rr.ok) { hitAny = true; faits.push({ n: descs[grp[q]].n, champ: descs[grp[q]].label || k, valeur: "coché" }); st.champs.push({ sel: descs[grp[q]].sel, label: descs[grp[q]].label || k }); }
                return;
              }
            }
            echecs.push({ champ: k, erreur: "case introuvable : " + String(w).slice(0, 40) });
          });
          if (hitAny || grp.length > 1) return;
        }
        var d = descs[i];
        if (d.sensible) { refus.push(d.label || d.name || k); return; }
        if (d.nonRemplissable) { echecs.push({ champ: d.label || k, erreur: d.note }); return; }
        var r = setField(fields[i], vals[k]);
        if (r.ok) {
          faits.push({ n: d.n, champ: d.label || d.name || k, valeur: r.relu });
          st.champs = st.champs.filter(function (c) { return c.sel !== d.sel; });
          st.champs.push({ sel: d.sel, label: d.label || d.name || k });
        } else echecs.push({ champ: d.label || k, erreur: r.erreur || "non conforme", relu: r.relu || "" });
      });
      // champs protégés de la page, non demandés : signalés aussi (« à remplir par toi »)
      descs.forEach(function (d) { var l = d.label || d.name || ("champ " + d.n); if (d.sensible && refus.indexOf(l) < 0) refus.push(l); });
      st.ts = Date.now();
      window.__novaForm = st;
      if (st.champs.length) banner(st.champs.length, refus);
      return JSON.stringify({ ok: faits.length > 0, url: location.href, remplis: faits, echecs: echecs, a_remplir_par_toi: refus, total_remplis: st.champs.length,
        effet: { remplis: faits.length, envoye: false }, erreur: faits.length ? undefined : "aucun champ rempli" });
    }
    if (ACT === "resume") return JSON.stringify(resume().r);
    if (ACT === "soumettre") {
      if (ARG.confirmed !== true) return JSON.stringify({ ok: false, confirmation: true, erreur: "envoi de formulaire : GO d'Ahadi requis (carte)" });
      var rs = resume();
      if (!rs.r.ok) return JSON.stringify(rs.r);
      if (rs.r.empreinte !== ARG.empreinte) return JSON.stringify({ ok: false, code: "change", erreur: "la page ou les valeurs ont changé depuis la carte validée — rien n'est envoyé ; redemande une carte" });
      if (rs.r.paiement) return JSON.stringify({ ok: false, code: "paiement", erreur: "bouton de paiement/commande : Nova ne le clique jamais" });
      var avant = location.href, lbl = rs.r.bouton;
      unmarkAll();
      window.__novaForm = null;
      rs.btn.click();
      return JSON.stringify({ ok: true, url: avant, bouton: lbl, effet: { clique: lbl, url_avant: avant } });
    }
    if (ACT === "effacer") { unmarkAll(); window.__novaForm = null; return JSON.stringify({ ok: true }); }
    return JSON.stringify({ ok: false, erreur: "action formulaire inconnue : " + ACT });
  } catch (e) {
    return JSON.stringify({ ok: false, code: "script", erreur: "script formulaire : " + String((e && e.message) || e).slice(0, 160) });
  }
}

/* Aiguillage côté fenêtre. k = { native, paneId, svc, paneEval, ensurePane, paneProbe, waitForContent, loginInfo, held, heldResult }. */
export async function handleForm(d, k) {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const pid = k.paneId;
  const act = String(d.act || "lire");
  if (!k.native()) return { ok: false, erreur: "coquille native absente : les volets web ne sont pas pilotables depuis l'aperçu" };
  if (act === "soumettre" && d.confirmed !== true) return { ok: false, confirmation: true, erreur: "envoi de formulaire : carte d'Ahadi requise" };
  if (k.held(pid)) return k.heldResult(pid);
  k.ensurePane(pid);
  let p = await k.paneProbe(pid);
  if (!p || p.pret !== "complete") {
    const w = await k.waitForContent(pid, 8000, true);
    if (w.held) return k.heldResult(pid);
    p = w.probe || p;
  }
  if (!p) return { ok: false, pane: pid, erreur: "volet " + k.svc + " sans réponse (aucune page ouverte ?) — ouvre d'abord la page : app page-aller <adresse>" };
  if (!/^https?:/i.test(String(p.url || ""))) return { ok: false, pane: pid, erreur: "aucune page web ouverte dans " + k.svc + " (adresse : " + (p.url || "vide") + ") — ouvre d'abord la page : app page-aller <adresse>" };
  const li = k.loginInfo(pid, p.url, p.ech);
  if (li && act !== "lire" && act !== "origine") return { ok: false, pane: pid, bloqueur: li.code, erreur: "page de connexion : identifiants à saisir par toi, jamais par Nova. " + li.msg };
  if (k.held(pid)) return k.heldResult(pid);
  const arg = { valeurs: d.valeurs || {}, empreinte: String(d.empreinte || ""), confirmed: d.confirmed === true };
  const js = "(" + paneFormScript.toString() + ")(" + JSON.stringify(act) + "," + JSON.stringify(arg) + ")";
  const raw = await k.paneEval(pid, js, 12000);
  if (raw == null) return { ok: false, pane: pid, erreur: "le volet " + k.svc + " n'a pas exécuté le script de formulaire" };
  let r = null;
  try { r = JSON.parse(raw); } catch (e) { r = null; }
  if (!r || typeof r !== "object") return { ok: false, pane: pid, erreur: "réponse illisible du volet" };
  r.pane = pid;
  if (act === "soumettre" && r.ok) {
    await sleep(2500);   // laisse partir la requête / la navigation, puis relit la page
    const p2 = await k.paneProbe(pid);
    if (p2) { r.effet.url_apres = p2.url || ""; r.effet.titre_apres = p2.titre || ""; r.effet.extrait_apres = String(p2.ech || "").slice(0, 300); }
  }
  return r;
}
