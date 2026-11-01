#!/usr/bin/env python3
"""Compare deux dossiers de captures PNG (mêmes noms) : % de pixels différents (seuil de 8 niveaux par canal)."""
import os, sys
from PIL import Image, ImageChops
a, b = sys.argv[1], sys.argv[2]
for n in sorted(os.listdir(a)):
    if not n.endswith(".png") or not os.path.exists(os.path.join(b, n)): continue
    A, B = Image.open(os.path.join(a, n)).convert("RGB"), Image.open(os.path.join(b, n)).convert("RGB")
    if A.size != B.size: print(n, "TAILLES DIFFÉRENTES", A.size, B.size); continue
    d = ImageChops.difference(A, B).convert("L").point(lambda v: 255 if v > 8 else 0)
    px = d.histogram()[255]
    print("%-42s %6.2f %% de pixels différents%s" % (n, 100.0 * px / (A.size[0] * A.size[1]), "  boîte " + str(d.getbbox()) if px else ""))
