#!/usr/bin/env python3
"""Lecture du banc voix (dormant/VOIX_TEST_REQUEST → releves/diag/voix_test.json).

Usage : python3 tools/voix/lire_voix_test.py [--diag releves/diag] [--attendre 600]
  --attendre N : attend jusqu'à N secondes que le passage soit « terminé » (relit toutes les 5 s).
Affiche : statut, critères du dossier (2 min, 3 barge-in, premier audio < 1 s), médiane et p90 par étape,
WER, coût réel, tours un par un, et les lignes du journal meta_only (spécialités dictee et voix) du passage.
"""
import argparse, json, os, sys, time


def load(p):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def ms(v):
    return "—" if v is None or v == -1 else "%d ms" % v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--diag", default=os.path.expanduser("~/spark-local/Nova2/releves/diag"))
    ap.add_argument("--attendre", type=int, default=0)
    a = ap.parse_args()
    path = os.path.join(a.diag, "voix_test.json")
    t0 = time.time()
    d = load(path)
    while a.attendre and (d is None or d.get("etat") != "terminé") and time.time() - t0 < a.attendre:
        time.sleep(5)
        d = load(path)
    if d is None:
        print("Pas de résultat : %s absent (la demande est prise sous 30 s par Nova en service)." % path)
        return 2
    print("Banc voix — début %s, fin %s, état %s, statut %s %s" % (d.get("started"), d.get("finished", "…"), d.get("etat"),
                                                                d.get("statut", "…"), ("(" + d["raison"] + ")") if d.get("raison") else ""))
    print("meta_only : %s · entrées : %s" % (d.get("meta_only"), json.dumps(d.get("entrees", {}), ensure_ascii=False)))
    c = d.get("criteres", {})
    if c:
        print("\nCRITÈRES DU DOSSIER")
        print("  conversation : %.1f s (≥ 120 s : %s)" % (c.get("conversation_ms", 0) / 1000, "OUI" if c.get("conversation_2_min") else "non"))
        print("  barge-in réussis : %s / 3 (%s)" % (c.get("barge_in_reussis"), "OUI" if c.get("barge_in_3") else "non"))
        print("  premier audio, médiane : %s (< 1 s : %s) ; tours sous 1 s : %s / %s" % (
            ms(c.get("premier_audio_mediane_ms")), "OUI" if c.get("premier_audio_sous_1s_mediane") else "non",
            c.get("premier_audio_sous_1s_tours"), c.get("tours_mesures")))
    e = d.get("etapes", {})
    if e:
        print("\nÉTAPES (n, médiane, p90)")
        for k, v in e.items():
            print("  %-30s n=%-3s médiane %-9s p90 %s" % (k, v.get("n"), ms(v.get("mediane_ms")), ms(v.get("p90_ms"))))
    if d.get("wer"):
        w = d["wer"]
        print("\nWER approximatif : moyen %.1f %%, médian %.1f %% (n=%s)" % (w["moyen"] * 100, w["median"] * 100, w["n"]))
    if d.get("synthese_prechauffage"):
        print("Préchauffage voix locale : %s" % json.dumps(d["synthese_prechauffage"], ensure_ascii=False))
    if d.get("connexion_http"):
        print("Connexion HTTP : %s requêtes sur la session partagée" % d["connexion_http"].get("requetes_session_partagee"))
    if d.get("cout_usd"):
        cu = d["cout_usd"]
        print("Coût réel : %.6f $ (Voice Transcribe %.6f $, Spark %.6f $) — plafond %.2f $" % (
            cu.get("total", 0), cu.get("voice_transcribe", 0), cu.get("spark", 0), d.get("plafond_usd", 0.5)))
    print("\nTOURS")
    for t in d.get("tours", []):
        b = t.get("barge_in")
        bs = ""
        if b:
            bs = " · BARGE-IN %s : arrêt %s, reprise %s" % (b.get("type"), ms(b.get("arret_ms")), ms(b.get("reprise_ms")))
        wer = t.get("wer")
        print("  %2s %-10s %s stt %-8s 1er jeton %-8s 1re phrase %-8s tts 1er tampon %-8s PREMIER AUDIO %-8s wer %s%s" % (
            t.get("n"), t.get("fichier"), t.get("statut"), ms(t.get("stt_ms")), ms(t.get("spark_premier_jeton_ms")),
            ms(t.get("spark_premiere_phrase_ms")), ms(t.get("tts_premier_tampon_ms")), ms(t.get("premier_audio_ms")),
            "—" if wer is None else "%.0f %%" % (wer * 100), bs))
        if t.get("erreur") or t.get("erreur_spark"):
            print("       erreur : %s" % (t.get("erreur") or t.get("erreur_spark")))
        if t.get("transcription") is not None:
            print("       entendu : %s" % t.get("transcription"))
            print("       réponse : %s" % (t.get("reponse") or "")[:160].replace("\n", " "))
    jp = os.path.join(a.diag, "meta_only_journal.jsonl")
    if os.path.exists(jp) and d.get("started"):
        rows = []
        for line in open(jp, encoding="utf-8"):
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("source") == "voix_test" and str(o.get("ts", "")) >= d["started"]:
                rows.append(o)
        print("\nJOURNAL meta_only (source voix_test) : %d lignes ; spécialités %s ; toutes Meta : %s" % (
            len(rows), sorted({r.get("specialite") for r in rows}), all(r.get("meta") is True for r in rows)))
    tr = os.path.join(a.diag, "voix_test_traces")
    if os.path.isdir(tr):
        for n in sorted(os.listdir(tr)):
            o = load(os.path.join(tr, n)) or {}
            print("Trace %s : recorded=%s" % (n, o.get("recorded")))
        print("  → copier voix_test_traces/dictation.json dans demo/traces/ (branche hackathon/meta), ou relancer tools/demo/build_traces.py")
    return 0 if d.get("statut") == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
