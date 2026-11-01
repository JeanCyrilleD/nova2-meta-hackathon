#!/usr/bin/env python3
"""check_glb.py — V5-J : validation HORS LIGNE d'un compagnon 3D réaliste (.glb) de Nova.

Vérifie un fichier glTF 2.0 binaire au regard de conseil_24-10/CAHIER_AVATAR_3D_REALISTE.md :
poids, squelette (noms d'os EXACTS + hiérarchie), 52 blendshapes ARKit + vis_* + earPerk/Droop +
smileDuchenne, clips, accessoires acc_*, triangles, textures (≤ 2048), compression déclarée,
orientation approximative (Y haut, face +Z, pieds à Y = 0, hauteur ≈ 1). Rapport en français.
Bibliothèque standard Python 3 uniquement, aucun réseau.

Usage :
  python3 tools/check_glb.py fichier.glb [--espece panda|renard] [--json]
  python3 tools/check_glb.py --installer      # valide web/avatars/*.glb et écrit web/avatars/manifest.json
  python3 tools/check_glb.py --installer --apercu   # idem, mais activation seulement sur choix explicite (Réglages)
Codes de sortie : 0 = conforme, 1 = utilisable avec replis, 2 = refusé (ou fichier illisible).
"""
import datetime
import hashlib
import json
import math
import os
import struct
import sys

BONES = ["root", "hips", "spine", "chest", "neck", "head", "jaw", "eye_L", "eye_R", "ear_L", "ear_R",
         "shoulder_L", "upperArm_L", "foreArm_L", "hand_L", "shoulder_R", "upperArm_R", "foreArm_R", "hand_R",
         "upLeg_L", "leg_L", "foot_L", "upLeg_R", "leg_R", "foot_R"]
PARENT = {"hips": "root", "spine": "hips", "chest": "spine", "neck": "chest", "head": "neck",
          "jaw": "head", "eye_L": "head", "eye_R": "head", "ear_L": "head", "ear_R": "head",
          "shoulder_L": "chest", "upperArm_L": "shoulder_L", "foreArm_L": "upperArm_L", "hand_L": "foreArm_L",
          "shoulder_R": "chest", "upperArm_R": "shoulder_R", "foreArm_R": "upperArm_R", "hand_R": "foreArm_R",
          "upLeg_L": "hips", "leg_L": "upLeg_L", "foot_L": "leg_L", "upLeg_R": "hips", "leg_R": "upLeg_R", "foot_R": "leg_R",
          "tail_01": "hips"}
for _i in range(2, 8):
    PARENT["tail_0%d" % _i] = "tail_0%d" % (_i - 1)
HARD_BONES = ["head"]
ARKIT52 = ["eyeBlinkLeft", "eyeLookDownLeft", "eyeLookInLeft", "eyeLookOutLeft", "eyeLookUpLeft", "eyeSquintLeft", "eyeWideLeft",
           "eyeBlinkRight", "eyeLookDownRight", "eyeLookInRight", "eyeLookOutRight", "eyeLookUpRight", "eyeSquintRight", "eyeWideRight",
           "jawForward", "jawLeft", "jawRight", "jawOpen", "mouthClose", "mouthFunnel", "mouthPucker", "mouthLeft", "mouthRight",
           "mouthSmileLeft", "mouthSmileRight", "mouthFrownLeft", "mouthFrownRight", "mouthDimpleLeft", "mouthDimpleRight",
           "mouthStretchLeft", "mouthStretchRight", "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper",
           "mouthPressLeft", "mouthPressRight", "mouthLowerDownLeft", "mouthLowerDownRight", "mouthUpperUpLeft", "mouthUpperUpRight",
           "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight", "cheekPuff", "cheekSquintLeft",
           "cheekSquintRight", "noseSneerLeft", "noseSneerRight", "tongueOut"]
VISEMES = ["vis_A", "vis_E", "vis_I", "vis_O", "vis_U", "vis_MBP", "vis_FV"]
EARS = ["earPerk_L", "earPerk_R", "earDroop_L", "earDroop_R"]
CLIPS = ["idle", "listening", "thinking", "typing", "talk_gesture_A", "talk_gesture_B", "approval", "nod", "wink",
         "celebrate_small", "celebrate_big", "error_resolve", "reading", "sleep"]
ONCE = ["talk_gesture_A", "talk_gesture_B", "nod", "wink", "celebrate_small", "celebrate_big", "error_resolve", "arrive_tail"]
DUR = {"idle": (6, 8), "listening": (4, 4), "thinking": (4, 4), "typing": (2, 2), "talk_gesture_A": (1.5, 1.5),
       "talk_gesture_B": (1.5, 1.5), "approval": (2, 2), "nod": (0.6, 0.6), "wink": (0.8, 0.8), "celebrate_small": (1.6, 1.6),
       "celebrate_big": (3, 3), "error_resolve": (2, 2), "reading": (4, 4), "sleep": (6, 6), "arrive_tail": (1, 1)}
ACCESSORIES = {"acc_headset": ["head"], "acc_laptop": ["hand_L", "hand_R"], "acc_glasses": ["head"]}
FILES = {"panda": "nova_panda.glb", "renard": "nova_pandaroux.glb"}
MAX_MB = 6.0
TRI_MIN, TRI_MAX = 15000, 35000
COMP = {"KHR_draco_mesh_compression": "Draco", "EXT_meshopt_compression": "Meshopt", "KHR_meshopt_compression": "Meshopt",
        "KHR_texture_basisu": "KTX2 (Basis)", "KHR_mesh_quantization": "quantification"}
SUPPORTED_EXT = {"KHR_draco_mesh_compression", "EXT_meshopt_compression", "KHR_texture_basisu", "KHR_mesh_quantization",
                 "KHR_materials_emissive_strength", "KHR_materials_clearcoat", "KHR_materials_ior", "KHR_materials_sheen",
                 "KHR_materials_specular", "KHR_materials_transmission", "KHR_materials_unlit", "KHR_materials_volume",
                 "KHR_materials_iridescence", "KHR_materials_anisotropy", "KHR_texture_transform", "KHR_lights_punctual",
                 "EXT_texture_webp", "EXT_mesh_gpu_instancing", "KHR_materials_variants"}


# ---------- lecture GLB ----------
def read_glb(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 20:
        raise ValueError("fichier trop court pour être un .glb")
    magic, version, length = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67:
        raise ValueError("ce n'est pas un glTF binaire (en-tête « glTF » absent)")
    if version != 2:
        raise ValueError("version glTF %d (2 attendue)" % version)
    if length != len(data):
        raise ValueError("longueur déclarée %d ≠ taille réelle %d (fichier tronqué ?)" % (length, len(data)))
    off, js, binc = 12, None, None
    while off + 8 <= len(data):
        clen, ctype = struct.unpack_from("<II", data, off)
        chunk = data[off + 8: off + 8 + clen]
        if ctype == 0x4E4F534A and js is None:
            js = json.loads(chunk.decode("utf-8"))
        elif ctype == 0x004E4942 and binc is None:
            binc = chunk
        off += 8 + clen
    if js is None:
        raise ValueError("bloc JSON absent")
    return data, js, binc or b""


def skin_joint_names(js, binc, node):
    """Os réellement pondérés (poids > 0,01) d'un nœud skinné ; None si illisible (compressé)."""
    if "skin" not in node or "mesh" not in node:
        return None
    joints = js["skins"][node["skin"]].get("joints", [])
    fmt = {5121: "B", 5123: "H", 5126: "f"}
    out = set()
    for p in js["meshes"][node["mesh"]].get("primitives", []):
        at = p.get("attributes", {})
        if "JOINTS_0" not in at or "WEIGHTS_0" not in at:
            continue
        vals = []
        for key in ("JOINTS_0", "WEIGHTS_0"):
            a = js["accessors"][at[key]]
            if "bufferView" not in a or a["componentType"] not in fmt:
                return None
            bv = js["bufferViews"][a["bufferView"]]
            if "extensions" in bv:
                return None
            ct = a["componentType"]
            size = struct.calcsize("<" + fmt[ct])
            stride = bv.get("byteStride") or 4 * size
            o = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
            vals.append([struct.unpack_from("<" + fmt[ct] * 4, binc, o + k * stride) for k in range(a["count"])])
        for jj, ww in zip(vals[0], vals[1]):
            for j, w in zip(jj, ww):
                if (w > 0.01 if isinstance(w, float) else w > 2) and j < len(joints):
                    out.add(nodes_name(js, joints[j]))
    return out


def nodes_name(js, i):
    return js["nodes"][i].get("name", "")


# ---------- maths 4×4 (colonne-majeure glTF) ----------
def mat_mul(a, b):
    return [sum(a[k * 4 + r] * b[c * 4 + k] for k in range(4)) for c in range(4) for r in range(4)]


def node_matrix(n):
    if "matrix" in n:
        return list(n["matrix"])
    tx, ty, tz = n.get("translation", [0, 0, 0])
    x, y, z, w = n.get("rotation", [0, 0, 0, 1])
    sx, sy, sz = n.get("scale", [1, 1, 1])
    r = [1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0,
         2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0,
         2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0,
         0, 0, 0, 1]
    for i in range(3):
        r[i] *= sx
        r[4 + i] *= sy
        r[8 + i] *= sz
    r[12], r[13], r[14] = tx, ty, tz
    return r


def apply(m, p):
    x, y, z = p
    return (m[0] * x + m[4] * y + m[8] * z + m[12], m[1] * x + m[5] * y + m[9] * z + m[13], m[2] * x + m[6] * y + m[10] * z + m[14])


def image_size(blob):
    if blob[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", blob[16:24])
    if blob[:2] == b"\xff\xd8":
        i = 2
        while i + 9 < len(blob):
            if blob[i] != 0xFF:
                i += 1
                continue
            mk = blob[i + 1]
            ln = struct.unpack(">H", blob[i + 2:i + 4])[0]
            if mk in (0xC0, 0xC1, 0xC2):
                h, w = struct.unpack(">HH", blob[i + 5:i + 9])
                return w, h
            i += 2 + ln
    if blob[:12] == b"\xabKTX 20\xbb\r\n\x1a\n":
        return struct.unpack_from("<II", blob, 20)
    if blob[:4] == b"RIFF" and blob[8:12] == b"WEBP":
        return None
    return None


# ---------- analyse ----------
def analyse(path, espece=None):
    R = {"fichier": os.path.basename(path), "erreurs": [], "avertissements": [], "infos": []}
    E, A, I = R["erreurs"], R["avertissements"], R["infos"]
    try:
        data, js, binc = read_glb(path)
    except Exception as e:  # noqa: BLE001
        E.append("Lecture impossible : %s." % e)
        R["verdict"] = "REFUSÉ"
        return R
    base = os.path.basename(path).lower()
    if espece is None:
        espece = "renard" if "roux" in base or "renard" in base or "red" in base else "panda"
    R["espece"] = espece
    red = espece == "renard"
    size_mb = len(data) / 1048576.0
    R["octets"] = len(data)
    R["sha256"] = hashlib.sha256(data).hexdigest()
    (A if size_mb > MAX_MB else I).append("Poids : %.2f Mo (cahier : ≤ %.0f Mo)%s." % (size_mb, MAX_MB, " — TROP LOURD" if size_mb > MAX_MB else ""))
    asset = js.get("asset", {})
    if str(asset.get("version", "")) != "2.0":
        E.append("asset.version = %r (2.0 attendu)." % asset.get("version"))
    I.append("Générateur : %s." % (asset.get("generator") or "non indiqué"))

    used = js.get("extensionsUsed", []) or []
    req = js.get("extensionsRequired", []) or []
    comp = sorted({COMP[e] for e in used if e in COMP})
    I.append("Compression / encodage : %s." % (", ".join(comp) if comp else "aucune"))
    for e in req:
        if e not in SUPPORTED_EXT:
            E.append("Extension obligatoire non prise en charge par three.js r160 : %s." % e)
    for e in used:
        if e not in SUPPORTED_EXT and e not in req:
            A.append("Extension facultative inconnue (ignorée au rendu) : %s." % e)

    nodes = js.get("nodes", [])
    names = {}
    for i, n in enumerate(nodes):
        nm = n.get("name", "")
        if nm:
            names.setdefault(nm, []).append(i)
    parent = {}
    for i, n in enumerate(nodes):
        for c in n.get("children", []):
            parent[c] = i
    joints = set()
    for s in js.get("skins", []):
        joints.update(s.get("joints", []))
    if not js.get("skins"):
        A.append("Aucun « skin » : le maillage n'est pas gréé (os non pondérés) — seuls les nœuds bougeront.")

    def nidx(nm):
        return names.get(nm, [None])[0]

    # Squelette
    miss = [b for b in BONES if b not in names]
    tails = [t for t in ["tail_0%d" % i for i in range(1, 8)] if t in names]
    want_tail = 7 if red else 2
    R["os_manquants"] = miss
    if miss:
        lvl = E if any(b in HARD_BONES for b in miss) else A
        lvl.append("Os manquants (%d/%d) : %s." % (len(miss), len(BONES), ", ".join(miss)))
    else:
        I.append("Squelette : les %d os requis sont présents." % len(BONES))
    if len(tails) < want_tail:
        A.append("Queue : %d os tail_0x trouvés, %d attendus pour le %s." % (len(tails), want_tail, "panda roux" if red else "panda géant"))
    dups = [nm for nm in BONES if len(names.get(nm, [])) > 1]
    if dups:
        A.append("Noms d'os en double (le premier sera utilisé) : %s." % ", ".join(dups))
    bad_par = []
    for b, p in PARENT.items():
        bi, pi = nidx(b), nidx(p)
        if bi is None or pi is None:
            continue
        actual = nodes[parent[bi]].get("name", "?") if bi in parent else None
        if actual != p:
            bad_par.append("%s (parent attendu : %s, trouvé : %s)" % (b, p, actual or "aucun"))
    if bad_par:
        A.append("Hiérarchie différente du cahier : %s." % "; ".join(bad_par[:8]))
    not_joint = [b for b in BONES if b in names and nidx(b) not in joints and js.get("skins")]
    if not_joint:
        A.append("Nœuds présents mais non utilisés comme articulations du skin : %s." % ", ".join(not_joint[:10]))

    # Maillages, blendshapes, triangles, influences
    morphs = set()
    tris = 0
    unknown_tris = False
    joints1 = False
    for m in js.get("meshes", []):
        tn = (m.get("extras") or {}).get("targetNames") or []
        for p in m.get("primitives", []):
            tn = tn or (p.get("extras") or {}).get("targetNames") or []
            mode = p.get("mode", 4)
            if "JOINTS_1" in p.get("attributes", {}):
                joints1 = True
            if "indices" in p:
                cnt = js["accessors"][p["indices"]]["count"]
            elif "POSITION" in p.get("attributes", {}):
                cnt = js["accessors"][p["attributes"]["POSITION"]]["count"]
            else:
                cnt = 0
            if mode == 4:
                tris += cnt // 3
            elif mode in (5, 6):
                tris += max(0, cnt - 2)
            else:
                unknown_tris = True
            if p.get("targets") and not tn:
                A.append("Maillage « %s » : %d morph targets SANS noms (extras.targetNames) — inutilisables par nom." % (m.get("name", "?"), len(p["targets"])))
        morphs.update(tn)
    R["triangles"] = tris
    msg = "Triangles : %d (cahier : %d à %d)." % (tris, TRI_MIN, TRI_MAX)
    (A if tris > TRI_MAX * 1.15 else I).append(msg + (" — trop dense" if tris > TRI_MAX * 1.15 else " — sous le minimum (personnage simplifié ?)" if tris < TRI_MIN else ""))
    if unknown_tris:
        A.append("Primitives non triangulaires (lignes/points) présentes.")
    if joints1:
        A.append("JOINTS_1 présent : plus de 4 influences d'os par sommet (cahier : 4 maximum).")
    if not js.get("meshes"):
        E.append("Aucun maillage.")
    ear_bones = "ear_L" in names and "ear_R" in names
    need = ARKIT52 + VISEMES + ["smileDuchenne"] + ([] if ear_bones else EARS)
    mm = [n for n in need if n not in morphs]
    R["blendshapes_manquants"] = mm
    arkit_ok = sum(1 for n in ARKIT52 if n in morphs)
    I.append("Blendshapes : %d au total ; ARKit %d/52 ; visèmes %d/7 ; smileDuchenne %s ; oreilles %s." % (
        len(morphs), arkit_ok, sum(1 for n in VISEMES if n in morphs), "oui" if "smileDuchenne" in morphs else "NON",
        "par os" if ear_bones else "%d/4 formes" % sum(1 for n in EARS if n in morphs)))
    if mm:
        A.append("Blendshapes manquants (%d) : %s." % (len(mm), ", ".join(mm)))
    if "jawOpen" not in morphs and "jaw" not in names:
        A.append("Ni « jawOpen » ni os « jaw » : la bouche ne pourra pas s'ouvrir pendant la parole.")
    extra = sorted(n for n in morphs if n not in need and n not in EARS)
    if extra:
        I.append("Blendshapes supplémentaires (ignorés) : %s." % ", ".join(extra[:20]) + (" …" if len(extra) > 20 else ""))

    # Clips
    anims = js.get("animations", [])
    clip_names = [a.get("name", "") for a in anims]
    need_clips = CLIPS + (["arrive_tail"] if red else [])
    mc = [c for c in need_clips if c not in clip_names]
    R["clips_manquants"] = mc
    I.append("Clips : %d présents (%s)." % (len(anims), ", ".join(clip_names) if clip_names else "aucun"))
    if mc:
        A.append("Clips manquants (%d) — repli procédural : %s." % (len(mc), ", ".join(mc)))
    morph_clips = []
    for a in anims:
        nm = a.get("name", "")
        tmax = 0.0
        morph_anim = False
        for ch in a.get("channels", []):
            if ch.get("target", {}).get("path") == "weights":
                morph_anim = True
        for s in a.get("samplers", []):
            acc = js["accessors"][s["input"]]
            if acc.get("max"):
                tmax = max(tmax, acc["max"][0])
        if nm in DUR:
            lo, hi = DUR[nm]
            if tmax and (tmax < lo * 0.7 or tmax > hi * 1.4):
                A.append("Clip « %s » : %.2f s (cahier : %s s)." % (nm, tmax, ("%g" % lo) if lo == hi else "%g–%g" % (lo, hi)))
        if morph_anim:
            morph_clips.append(nm)

    if morph_clips:
        I.append("%d clip(s) animent des blendshapes (%s) : permis pour sourcils/paupières ; la bouche reste imposée en direct par le moteur." % (len(morph_clips), ", ".join(morph_clips[:6]) + (" …" if len(morph_clips) > 6 else "")))

    # Accessoires
    acc_rep = []
    for a, bones in ACCESSORIES.items():
        if a not in names:
            A.append("Accessoire absent : %s (l'état correspondant s'affichera sans)." % a)
            continue
        i = nidx(a)
        chain, p = [], parent.get(i)
        while p is not None:
            chain.append(nodes[p].get("name", ""))
            p = parent.get(p)
        sj = skin_joint_names(js, binc, nodes[i])
        if any(b in chain for b in bones):
            pass
        elif sj and any(b in sj for b in bones):
            I.append("Accessoire %s rattaché par pondération (skin) à %s." % (a, ", ".join(sorted(b for b in sj if b in bones))))
        else:
            A.append("Accessoire %s non rattaché à %s : le moteur l'y rattache au chargement (maillage rigide)." % (a, " ou ".join(bones)))
        acc_rep.append(a)
    if acc_rep:
        I.append("Accessoires présents : %s (masqués par défaut par le moteur)." % ", ".join(acc_rep))

    # Textures
    for k, img in enumerate(js.get("images", [])):
        blob = None
        if "bufferView" in img:
            bv = js["bufferViews"][img["bufferView"]]
            o = bv.get("byteOffset", 0)
            blob = binc[o:o + bv["byteLength"]]
        elif str(img.get("uri", "")).startswith("data:"):
            A.append("Image %d embarquée en data: URI (plus lourd qu'un bufferView)." % k)
        elif img.get("uri"):
            E.append("Image %d externe (%s) : le .glb doit tout embarquer." % (k, img["uri"]))
        if blob:
            wh = image_size(blob)
            if wh and (wh[0] > 2048 or wh[1] > 2048):
                A.append("Texture « %s » : %d × %d (cahier : 2048 max)." % (img.get("name", k), wh[0], wh[1]))
    for b in js.get("buffers", [])[1:] + ([js["buffers"][0]] if js.get("buffers") and js["buffers"][0].get("uri") else []):
        if b.get("uri"):
            E.append("Buffer externe (%s) : le .glb doit tout embarquer." % b["uri"][:40])

    # Orientation approximative (scène par défaut, positions de repos)
    try:
        orient(js, binc, nodes, names, parent, R)
    except Exception as e:  # noqa: BLE001
        A.append("Orientation non évaluée (%s)." % e)

    R["verdict"] = "REFUSÉ" if E else ("UTILISABLE AVEC REPLIS" if A else "CONFORME")
    return R


def orient(js, binc, nodes, names, parent, R):
    A, I = R["avertissements"], R["infos"]
    world = {}

    def wm(i):
        if i not in world:
            m = node_matrix(nodes[i])
            world[i] = mat_mul(wm(parent[i]), m) if i in parent else m
        return world[i]

    mn = [math.inf] * 3
    mx = [-math.inf] * 3
    acc_nodes = set()
    for a in ACCESSORIES:
        for i in names.get(a, []):
            stack = [i]
            while stack:
                j = stack.pop()
                acc_nodes.add(j)
                stack.extend(nodes[j].get("children", []))
    ok = False
    for i, n in enumerate(nodes):
        if "mesh" not in n or i in acc_nodes:
            continue
        m = wm(i) if "skin" not in n else [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        for p in js["meshes"][n["mesh"]].get("primitives", []):
            pa = p.get("attributes", {}).get("POSITION")
            if pa is None:
                continue
            acc = js["accessors"][pa]
            if "min" not in acc or "max" not in acc:
                continue
            lo, hi = acc["min"], acc["max"]
            for cx in (lo[0], hi[0]):
                for cy in (lo[1], hi[1]):
                    for cz in (lo[2], hi[2]):
                        w = apply(m, (cx, cy, cz))
                        for k in range(3):
                            mn[k] = min(mn[k], w[k])
                            mx[k] = max(mx[k], w[k])
                        ok = True
    if not ok:
        A.append("Orientation non évaluée (bornes min/max des positions absentes).")
        return
    ext = [mx[k] - mn[k] for k in range(3)]
    R["boite"] = {"min": [round(v, 3) for v in mn], "max": [round(v, 3) for v in mx]}
    up = ext.index(max(ext))
    if up != 1:
        A.append("Le plus grand côté est sur l'axe %s, pas Y : personnage couché ou exporté Z-haut ?" % "XYZ"[up])
    h = ext[1]
    if not (0.8 <= h <= 1.25):
        A.append("Hauteur %.3f (≈ 1,0 attendu) — le moteur normalise l'échelle, mais vérifie les unités." % h)
    else:
        I.append("Hauteur : %.3f (≈ 1,0 attendu)." % h)
    if abs(mn[1]) > 0.05 * max(h, 1e-6):
        A.append("Pieds à Y = %.3f (0 attendu) — le moteur recale, mais vérifie l'origine." % mn[1])
    eyes = [names.get("eye_L", [None])[0], names.get("eye_R", [None])[0]]
    hd = names.get("head", [None])[0]
    if None not in eyes and hd is not None:
        ez = (wm(eyes[0])[14] + wm(eyes[1])[14]) / 2
        hz = wm(hd)[14]
        ex = wm(eyes[0])[12] - wm(eyes[1])[12]
        if ez > hz + 1e-4:
            I.append("Face orientée vers +Z (yeux devant la tête) : conforme.")
        elif ez < hz - 1e-4:
            A.append("Les yeux sont DERRIÈRE l'os de tête (face −Z ?) — le moteur retournera le modèle de 180°.")
        else:
            A.append("Orientation de la face indéterminée (yeux au niveau de la tête en Z).")
        if ex < 0:
            A.append("eye_L est à droite de eye_R (X) : gauche/droite du personnage inversés ?")
    else:
        A.append("Orientation de la face non évaluée (os eye_L/eye_R/head absents).")


def print_report(R):
    v = R["verdict"]
    print("=" * 72)
    print("Avatar %s — %s" % (R["fichier"], R.get("espece", "?")))
    print("VERDICT : %s" % v)
    print("=" * 72)
    for titre, cle in (("Erreurs (bloquantes)", "erreurs"), ("Avertissements (repli doux au rendu)", "avertissements"), ("Constats", "infos")):
        if R[cle]:
            print("\n%s :" % titre)
            for l in R[cle]:
                print("  - " + l)
    print()
    if v == "REFUSÉ":
        print("→ Nova gardera le panda procédural (mascot.js) pour ce personnage.")
    elif v.startswith("UTILISABLE"):
        print("→ Utilisable : ce qui manque est remplacé en douceur par le moteur (os de mâchoire, poses procédurales…).")
    else:
        print("→ Conforme au cahier : branchement direct.")


def installer(root, apercu=False):
    adir = os.path.join(root, "web", "avatars")
    man_path = os.path.join(adir, "manifest.json")
    out = {"version": 1, "note": "Écrit par tools/check_glb.py --installer. Ne pas éditer à la main.", "avatars": {}}
    worst = 0
    for key, fn in FILES.items():
        p = os.path.join(adir, fn)
        if not os.path.exists(p):
            print("%s : absent → panda procédural." % fn)
            continue
        R = analyse(p, key)
        print_report(R)
        code = {"CONFORME": 0, "UTILISABLE AVEC REPLIS": 1}.get(R["verdict"], 2)
        worst = max(worst, code)
        if code < 2:
            out["avatars"][key] = {"fichier": fn, "ok": True, "verdict": "APERÇU" if apercu else R["verdict"], "verdict_technique": R["verdict"],
                                   "defaut": not apercu, "octets": R["octets"], "sha256": R["sha256"],
                                   "triangles": R.get("triangles", 0), "verifie": datetime.datetime.now().isoformat(timespec="seconds")}
    with open(man_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
        f.write("\n")
    act = ", ".join("%s → %s" % (k, v["fichier"]) for k, v in out["avatars"].items()) or "aucun (pandas procéduraux)"
    if apercu and out["avatars"]:
        act += " — en APERÇU : moteur par défaut inchangé (mascot.js), activation par Réglages › Avatar 3D (aperçu)"
    print("\nManifeste écrit : %s\nAvatars réalistes activés : %s\nÉtape suivante : recompiler (bash tools/package_app.sh)." % (man_path, act))
    return worst


def main(argv):
    args = argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if "--installer" in args:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        return installer(root, apercu="--apercu" in args)
    esp = None
    if "--espece" in args:
        i = args.index("--espece")
        esp = {"panda": "panda", "renard": "renard", "pandaroux": "renard", "panda-roux": "renard"}.get(args[i + 1], "panda")
        del args[i:i + 2]
    as_json = "--json" in args
    files = [a for a in args if not a.startswith("--")]
    worst = 0
    for p in files:
        R = analyse(p, esp)
        if as_json:
            print(json.dumps(R, ensure_ascii=False, indent=2))
        else:
            print_report(R)
        worst = max(worst, {"CONFORME": 0, "UTILISABLE AVEC REPLIS": 1}.get(R["verdict"], 2))
    return worst


if __name__ == "__main__":
    sys.exit(main(sys.argv))
