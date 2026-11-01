#!/usr/bin/env python3
"""Nova 2 — génère tools/AppIcon-1024.png (le dessin source est tools/AppIcon.svg).
Fond « vide spatial » (#07080F→#0D1020), orbe orange solaire #FF7A29,
étoile à 4 branches du glyphe « orb » de web/js/icons.js (grille 24).

Deux moteurs, même dessin :
  - PIL si disponible (rapide) ;
  - bibliothèque standard seule sinon (zlib/struct) — c'est ce chemin qui
    tourne sur le Mac d'Ahadi quand package_app.sh régénère l'icône.
Usage : python3 tools/make_icon.py   (écrit tools/AppIcon-1024.png, 1024×1024)"""
import math, os, struct, zlib

S = 1024
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "AppIcon-1024.png")
TOP, BOT = (13, 16, 32), (7, 8, 15)              # dégradé du vide
C_LIGHT, C_MID, C_DEEP = (255, 195, 143), (255, 122, 41), (194, 78, 18)
STAR24 = [(12, 5.8), (13.5, 10.5), (18.2, 12), (13.5, 13.5),
          (12, 18.2), (10.5, 13.5), (5.8, 12), (10.5, 10.5)]


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def in_star(x, y, scale, cx, cy):
    """Point dans l'étoile à 4 branches (polygone de STAR24 mis à l'échelle) ?"""
    pts = [(cx + (px - 12) * scale, cy + (py - 12) * scale) for px, py in STAR24]
    inside = False
    for i in range(len(pts)):
        x1, y1 = pts[i]
        x2, y2 = pts[(i + 1) % len(pts)]
        if (y1 > y) != (y2 > y):
            xin = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
            if x < xin:
                inside = not inside
    return inside


def pixel(x, y):
    """Couleur RGBA du pixel (x, y) — le dessin, partagé par les deux moteurs."""
    # fond : carré arrondi (marge 100, rayon 190), coins transparents
    # (distance au rectangle central rétracté du rayon : SDF classique)
    m, r = 100, 190
    dx = max(m + r - x, x - (S - 1 - m - r), 0)
    dy = max(m + r - y, y - (S - 1 - m - r), 0)
    if dx * dx + dy * dy > r * r:
        return (0, 0, 0, 0)
    base = lerp(TOP, BOT, y / (S - 1))
    cx = cy = S / 2
    d = math.hypot(x - cx, y - cy)
    # halo orange autour de l'orbe
    if d < 330:
        a = 0.55 * (1 - d / 330) ** 2
        base = lerp(base, C_MID, a)
    # orbe (rayon 218) : dégradé radial, lumière haut-gauche
    if d <= 218:
        t = 1 - d / 218
        col = lerp(C_LIGHT, C_MID, t / 0.45) if t < 0.45 else lerp(C_MID, C_DEEP, (t - 0.45) / 0.55)
        lx, ly = cx - 0.24 * 218, cy - 0.32 * 218
        dl = math.hypot(x - lx, y - ly)
        col = lerp(col, (255, 226, 196), max(0.0, 0.35 * (1 - dl / 300)))
        if d > 212:  # anneau clair du glyphe
            col = lerp(col, (255, 255, 255), 0.35)
        base = col
    # étoile (branche du glyphe « orb »), halo doux puis cœur crème
    if in_star(x, y, 19.6, cx, cy):
        base = lerp(base, (255, 190, 130), 0.45)
    if in_star(x, y, 18.2, cx, cy):
        base = (255, 246, 236)
    return base + (255,)


def render_pil():
    from PIL import Image
    img = Image.new("RGBA", (S, S))
    px = img.load()
    for y in range(S):
        for x in range(S):
            px[x, y] = pixel(x, y)
    img.save(OUT)


def render_stdlib():
    raw = bytearray()
    for y in range(S):
        raw.append(0)  # filtre PNG : aucun
        for x in range(S):
            raw += bytes(pixel(x, y))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    with open(OUT, "wb") as f:
        f.write(png)


if __name__ == "__main__":
    try:
        import PIL  # noqa: F401
        render_pil()
        moteur = "PIL"
    except ImportError:
        render_stdlib()
        moteur = "stdlib"
    print(f"OK {OUT} ({S}x{S}, {os.path.getsize(OUT)} octets, moteur {moteur})")
