#!/usr/bin/env python3
"""Keyless demo for judges without a Mac or API keys: replays Nova's RECORDED real runs (demo/traces/*.json)
in the terminal — steps, Meta model ids, endpoints, timings, costs. No network call, no key.
Usage: python3 tools/demo/replay.py [cafu_note|spark_open_review|image|dictation|meta_routing|all] [--pace 0.3]
"""
import json, os, sys, time

IDS = ["cafu_note", "spark_open_review", "image", "dictation", "meta_routing"]
HERE = os.path.dirname(os.path.abspath(__file__))
TRACES = os.environ.get("NOVA_DEMO_DIR") or os.path.join(HERE, "..", "..", "demo", "traces")


def show(tid, pace):
    p = os.path.join(TRACES, tid + ".json")
    t = json.load(open(p, encoding="utf-8"))
    print("\n=== " + t.get("title", tid) + " ===")
    print("recorded real run: " + ("yes" if t.get("recorded") else "NO (shown as such, never invented)"))
    for k in ("model", "endpoint", "reasoning_effort", "started", "finished", "duration_ms", "llm_cost_usd"):
        if t.get(k) is not None:
            print("  %-16s %s" % (k, t[k]))
    for s in t.get("steps", []):
        print("  step  " + s); time.sleep(pace)
    for e in t.get("events", []):
        print("  call  %s  %-10s %-38s %s %s" % (e.get("ts", ""), e.get("fournisseur", ""), e.get("modele", e.get("model", "")),
                                               e.get("statut", "ok" if e.get("ok") else ""), e.get("specialite", "")))
        time.sleep(pace / 3)
    if t.get("citations"):
        print("  public sources cited: %d" % len(t["citations"]))
    if t.get("note"):
        print("\n" + t["note"][:4000])


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    pace = float(sys.argv[sys.argv.index("--pace") + 1]) if "--pace" in sys.argv else 0.3
    which = IDS if not args or args[0] == "all" else [args[0]]
    for tid in which:
        if tid not in IDS:
            print("unknown trace: " + tid); return 2
        show(tid, pace)
    return 0


if __name__ == "__main__":
    sys.exit(main())
