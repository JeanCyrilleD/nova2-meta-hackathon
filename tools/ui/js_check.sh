#!/bin/sh
# Phase 4 — vérification syntaxique RÉELLE des modules ES (node --check sur un .js à « import » ne vérifie rien :
# on passe par une copie .mjs). Usage : tools/ui/js_check.sh fichier.js ...
rc=0; t=$(mktemp -d)
for f in "$@"; do cp "$f" "$t/x.mjs"; if node --check "$t/x.mjs" 2>"$t/err"; then echo "ok   $f"; else echo "ERREUR $f"; head -5 "$t/err"; rc=1; fi; done
rm -rf "$t"; exit $rc
