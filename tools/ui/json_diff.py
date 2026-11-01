#!/usr/bin/env python3
"""Diff de deux dumps root_vars_dump.py ; ignore les valeurs qui changent d'elles-mêmes (heure, aléa)."""
import json, sys
a, b = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])); n = 0
for k in sorted(set(a) | set(b)):
    for el in sorted(set(a.get(k, {})) | set(b.get(k, {}))):
        x, y = a.get(k, {}).get(el, {}), b.get(k, {}).get(el, {})
        for p in sorted(set(x) | set(y)):
            if x.get(p) != y.get(p):
                n += 1
                if n <= 25: print(k, el, p, "|", str(x.get(p))[:70], "→", str(y.get(p))[:70])
print("différences:", n)
