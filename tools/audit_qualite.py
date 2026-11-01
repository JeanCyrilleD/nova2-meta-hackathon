import json, re, statistics, collections, pathlib

d = json.load(open("/Users/jeancyrilledahani/SPARK-LOCAL/Nova2/releves/diag/audit_conversations_24h.json"))
convs = d.get("conversations") or []

def txt(m): return str(m.get("contenu") or m.get("content") or m.get("texte") or "")
def brain(m): return str(m.get("cerveau") or m.get("brain") or m.get("modele") or "?")

asst, users, pairs = [], [], []
for c in convs:
    ms = c.get("echanges") or c.get("messages") or []
    for i, m in enumerate(ms):
        role = str(m.get("role") or "").lower()
        if role in ("assistant", "nova"):
            asst.append(m)
            prev = txt(ms[i-1]) if i > 0 else ""
            pairs.append((prev, m, c.get("titre") or c.get("title") or "?"))
        elif role in ("user", "utilisateur", "ahadi"):
            users.append(m)

print(f"== Corpus : {len(users)} messages Ahadi, {len(asst)} réponses Nova, {len(convs)} fils ==")
words = [len(txt(m).split()) for m in asst]
if words:
    print(f"Longueur réponses : médiane {int(statistics.median(words))} mots, moyenne {round(statistics.mean(words))}, "
          f"<25 mots: {sum(1 for w in words if w<25)} ({100*sum(1 for w in words if w<25)//len(words)}%), "
          f"<40: {sum(1 for w in words if w<40)} ({100*sum(1 for w in words if w<40)//len(words)}%), "
          f">300: {sum(1 for w in words if w>300)}")

# --- Questions posées par Nova (grief: questions inutiles/répétées) ---
qtexts = []
for m in asst:
    for sent in re.split(r"(?<=[.!])\s+", txt(m)):
        s = sent.strip()
        if s.endswith("?") and len(s) > 8:
            qtexts.append(s)
qnorm = collections.Counter(re.sub(r"\W+", " ", q.lower()).strip()[:80] for q in qtexts)
print(f"\nQuestions posées par Nova : {len(qtexts)} au total, {len(qnorm)} distinctes")
print("Répétées (>=2):")
for q, n in qnorm.most_common(10):
    if n >= 2: print(f"  ×{n}  {q[:95]}")
containsQ = sum(1 for m in asst if "?" in txt(m))
print(f"Réponses contenant au moins une question : {containsQ}/{len(asst)} ({100*containsQ//max(len(asst),1)}%)")

# --- Formules d'impuissance / refus / renvoi à Ahadi ---
PAT = {
 "je ne peux pas": r"je ne peux pas", "aucun outil": r"aucun outil",
 "pas d'outil/pas accès": r"(je n'ai pas|pas d['’](outil|accès))",
 "dis-moi/dites-moi": r"\bdis(-| )moi\b", "tu veux que je": r"tu veux que je",
 "veux-tu": r"veux-tu", "à toi de": r"à toi de (voir|décider|choisir|valider)",
 "ouvre toi-même": r"(ouvre|appuie|clique) .{0,30}toi(-| )?même",
 "je ne sais pas": r"je ne sais pas", "non vérifié": r"non vérifié",
 "rien n'est envoyé/parti": r"rien n['’]est (envoyé|parti)",
 "en attente de ton GO": r"attend (ton|votre) (go|validation)|ton go",
}
print("\nFormules (occurrences dans les réponses) :")
for label, pat in PAT.items():
    n = sum(len(re.findall(pat, txt(m), flags=re.I)) for m in asst)
    if n: print(f"  {label:26s} {n}")

# --- Narration de progression ---
prog_pat = r"(?i)\b(je corrige|je rassemble|je consolide|je tisse|je lance|je récupère|je relève|je creuse|je fouille|je bascule|je prépare|en cours…|je m['’]en occupe)\b"
prog = [(m, len(re.findall(prog_pat, txt(m)))) for m in asst]
print(f"\nNarration de progression : {sum(n for _,n in prog)} occurrences dans {sum(1 for _,n in prog if n)} réponses")

# --- Promesses sans livraison dans le même message (finit par une promesse/question) ---
prom = 0
for m in asst:
    t = txt(m).strip()
    if re.search(r"(?i)(je (vais|m['’]apprête à)|dès que|je reviens|je te reviens)[^.!?]*[.!]?\s*$", t) or t.endswith("?"):
        prom += 1
print(f"Réponses se terminant par promesse/question (pas de livraison finale) : {prom}")

# --- Structure / rendu ---
struct = sum(1 for m in asst if re.search(r"(^|\n)\s*(- |\d+[.)]|#{1,3} |\*\*|\|)", txt(m)))
table = sum(1 for m in asst if txt(m).count("|") >= 4)
print(f"Structurées (listes/titres/gras/tableau) : {struct} ({100*struct//max(len(asst),1)}%), dont tableaux bruts : {table}")
raw = sum(1 for m in asst if re.search(r"(^|\n)\s*\|.*\|\s*$", txt(m), flags=re.M))
print(f"Tableaux markdown en lignes brutes : {raw}")

# --- Comptes de mots revendiqués ---
wc = []
for m in asst:
    for hit in re.findall(r"(\d[\d\s]{1,6})\s*mots", txt(m)):
        wc.append((hit, len(txt(m).split())))
print("Comptes de mots revendiqués vs réels (message) :", wc[:8] if wc else "aucun")

# --- Dumps bruts : très longues réponses contenant URLs/artefacts ---
dumps = sum(1 for m in asst if len(txt(m)) > 4000 and txt(m).count("http") >= 3)
print(f"Réponses >4000 car. avec ≥3 URLs (suspicion dump) : {dumps}")

# --- Cerveaux + latences si présentes ---
print("\nCerveaux :", dict(collections.Counter(brain(m) for m in asst)))
lat = [m.get("total_ms") or m.get("latence_ms") or m.get("ms") for m in asst]
lat = [x for x in lat if isinstance(x, (int, float)) and x > 0]
if lat: print(f"Latences (n={len(lat)}) médiane {int(statistics.median(lat))} ms, p90 {int(sorted(lat)[int(len(lat)*0.9)])} ms, max {int(max(lat))} ms")

# --- Exemples (courtes réponses + questions de Nova) ---
print("\n-- Exemples de réponses < 25 mots --")
for m in asst[:200]:
    if len(txt(m).split()) < 25:
        print("  •", txt(m)[:130].replace("\n", " "))
        if sum(1 for _ in [1]) and False: pass
print("\n-- Exemples de questions posées par Nova --")
for q in qtexts[:12]: print("  •", q[:140])

# Réponses aux ordres d'exécution d'Ahadi (impératifs) : la réponse finit-elle en question ?
orders = 0; order_q = 0
for prev, m, _ in pairs:
    if re.search(r"(?i)^(envoie|ouvre|affiche|lance|fais|corrige|prends|analyse|cherche|lis|mets|branche|continue|vas-y|go)\b", prev.strip()):
        orders += 1
        if txt(m).strip().endswith("?"): order_q += 1
print(f"\nOrdres impératifs d'Ahadi suivis : {orders} ; dont réponse finissant par une question : {order_q}")
