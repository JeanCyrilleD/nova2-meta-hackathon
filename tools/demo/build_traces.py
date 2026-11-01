#!/usr/bin/env python3
"""Build the public demo traces (demo/traces/*.json) from Nova's REAL run logs.

Inputs (never committed, see .gitignore): releves/diag/meta_only_journal.jsonl, releves/diag/cafu_test.json,
releves/diag/voix_journal.jsonl. Output: demo/traces/{cafu_note,spark_open_review,image,dictation,meta_routing}.json.

Sanitisation: only whitelisted fields are copied (model ids, provider, host, status, timings, token counts, cost,
public source URLs, the public CAFU note text). No conversation text, no keys, no file paths, no e-mail addresses.
A trace with no successful real run is written with "recorded": false and is never invented.
Usage: python3 tools/demo/build_traces.py [--diag releves/diag] [--out demo/traces]
"""
import argparse, json, os, re, sys

KEEP = ["ts", "fournisseur", "hote", "modele", "cerveau", "meta", "statut", "source", "specialite", "chaine", "mode",
        "jetons_entree", "jetons_sortie", "cout_usd", "ms", "raison"]
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}")
PATH = re.compile(r"(/Users/[^\s\"']+|~/[^\s\"']+)")


def clean(s):
    s = EMAIL.sub("[email]", str(s))
    return PATH.sub("[path]", s)


def jl(path):
    out = []
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line.startswith("{"):
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    return out


def pick(e):
    return {k: (clean(e[k]) if isinstance(e[k], str) else e[k]) for k in KEEP if k in e}


def write(out, name, obj):
    with open(os.path.join(out, name), "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(("recorded " if obj.get("recorded") else "NOT recorded ") + name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--diag", default="releves/diag")
    ap.add_argument("--out", default="demo/traces")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    journal = jl(os.path.join(a.diag, "meta_only_journal.jsonl"))
    src = "real Nova run logs (releves/diag), sanitised by tools/demo/build_traces.py"

    # 1. CAFU note (Muse Spark 1.3, reasoning_effort max) — cafu_test.json
    p = os.path.join(a.diag, "cafu_test.json")
    if os.path.exists(p):
        c = json.load(open(p, encoding="utf-8"))
        note = "\n".join(l for l in str(c.get("note", "")).split("\n") if not l.startswith("Warning:"))
        steps = [clean(re.sub(r"index nova-[a-z]+", "internal index", s)) for s in c.get("etapes", [])]
        write(a.out, "cafu_note.json", {
            "id": "cafu_note", "recorded": c.get("etat") == "terminé", "source": src,
            "title": "CAFU context note (public sources) — Muse Spark 1.3, reasoning_effort max",
            "model": "muse-spark-1.3", "endpoint": "https://api.meta.ai/v1/chat/completions",
            "reasoning_effort": c.get("raisonnement"), "max_tokens": c.get("max_tokens_envoye"),
            "started": c.get("started"), "finished": c.get("finished"), "duration_ms": c.get("ms"),
            "llm_cost_usd": c.get("cout_llm_usd"), "brief": clean(c.get("brief", "")),
            "steps": steps, "citations": c.get("citations", []), "checks": c.get("verifications", {}),
            "note": clean(note)})

    # 2. Spark Open (Baseten) — CAFU QA review / any Baseten call
    bt = [pick(e) for e in journal if e.get("fournisseur") == "baseten"]
    ok = [e for e in bt if e.get("statut") == "ok"]
    write(a.out, "spark_open_review.json", {
        "id": "spark_open_review", "recorded": bool(ok), "source": src,
        "title": "Muse Spark Open (open weights) via Baseten — CAFU QA review and Meta fallback",
        "model": "meta-models/muse-spark-open", "endpoint": "https://inference.baseten.co/v1/chat/completions",
        "events": bt,
        "note": "" if ok else "No successful Spark Open response recorded yet: the requests above used the wrong model id "
                              "(…-1026, HTTP 404); fixed to meta-models/muse-spark-open. Re-run a CAFU note with a Baseten key, then rebuild."})

    # 3. Muse Image
    im = [pick(e) for e in journal if str(e.get("modele", "")).startswith("muse-image")]
    write(a.out, "image.json", {
        "id": "image", "recorded": any(e.get("statut") == "ok" for e in im), "source": src,
        "title": "Muse Image (muse-image-1.0) — POST /v1/images/generations", "model": "muse-image-1.0",
        "events": im, "note": "Journal lines only: the generated image file is not part of the public trace."})

    # 4. Dictation (Muse Voice Transcribe)
    vx = [v for v in jl(os.path.join(a.diag, "voix_journal.jsonl")) if v.get("model") == "muse-voice-transcribe-1.0"]
    vok = [{k: v[k] for k in ("ts", "model", "ok", "bytes", "duree_audio_ms") if k in v} for v in vx if v.get("ok")]
    dj = [pick(e) for e in journal if e.get("specialite") == "dictee"]
    write(a.out, "dictation.json", {
        "id": "dictation", "recorded": bool(vok) or any(e.get("statut") == "ok" for e in dj), "source": src,
        "title": "Dictation — Muse Voice Transcribe (muse-voice-transcribe-1.0), POST /v1/asr/transcribe",
        "model": "muse-voice-transcribe-1.0", "events": dj + vok,
        "note": "" if vok else "No successful dictation recorded yet with the current endpoint. Dictate once in Nova, then rebuild. Transcript text is never copied."})

    # 5. Routing proof (every model call is Meta)
    write(a.out, "meta_routing.json", {
        "id": "meta_routing", "recorded": bool(journal), "source": src,
        "title": "meta_only proof journal — every routed model call", "events": [pick(e) for e in journal][-40:],
        "all_meta": all(e.get("meta") is True for e in journal)})


if __name__ == "__main__":
    sys.exit(main())
