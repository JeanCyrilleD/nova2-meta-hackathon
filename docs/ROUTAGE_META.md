# Routage Meta par spécialité (01/11/2026)

Branche `hackathon/meta` (version soumise, 100 % Meta). Code : `Sources/NovaCore/MetaSpecialites.swift`. Tests simulés : `Tests/NovaCoreTests/MetaSpecialitesTests.swift`.
Rien n'est appliqué aux réglages réels : tout est livré dans la branche.

## 1. Catalogue Meta vérifié (sources lues le 01/11/2026)

| Modèle | Nom d'API | Points d'accès | Spécialité (doc) | Prix publié |
|---|---|---|---|---|
| Muse Wonder | `muse-wonder-1.0` | Responses, Chat Completions, Messages | travail agentique, code, raisonnement (préversion) | 4 $ entrée / 20 $ sortie / 0,20 $ cache par M |
| Muse Wonder Full | aucun | Muse Code seulement, pas l'API | variante la plus capable | abonnement Muse Code |
| Muse Spark 1.3 | `muse-spark-1.3` (+ `-contributor`) | Responses, Chat Completions, Messages | flux agentiques et code, recommandé | 1,25 / 4,25 / 0,15 $ par M ; Contributor 0,10 / 0,20 / 0,002 $ |
| Muse Spark 1.2 | `muse-spark-1.2` (+ `-contributor`) | idem | version précédente | idem 1.3 |
| Muse Spark 1.1 | `muse-spark-1.1` | idem | version d'origine, Standard seulement | 1,25 / 4,25 / 0,15 $ |
| Muse Image | `muse-image-1.0` | Responses, `POST /v1/images/generations`, `/v1/images/edits` | génération et retouche d'images | 0,01 $ par image |
| Muse Voice Transcribe | `muse-voice-transcribe-1.0` | `wss://api.meta.ai/v1/asr/realtime`, `POST /v1/asr/transcribe` | transcription | 0,18 $ par heure d'audio |
| SAM 3.1 | `sam-3.1` | `POST /v1/responses`, Files API | segmentation image et vidéo | 2,50 $ / 1 000 images ; 0,20 $ / 1 000 images de vidéo (minimum 50) |
| Muse Spark Open | aucun sur l'API Meta | auto-hébergé ou fournisseur (Baseten, Fireworks, Modal) | poids ouverts, agentique et code | Baseten (page du compte, 01/11) : 1,25 / 0,15 / 4,25 $ par M, 500 000 jetons/min, 120 req/min |
| Muse Glimmer | aucun | auto-hébergé (`meta-models/Muse-Glimmer-30B`, Apache 2.0) | multimodal à poids ouverts | sans objet |
| Synthèse vocale | **aucune** | — | la doc dit que Muse Voice Transcribe « does not synthesize speech » | — |

Sources : https://dev.meta.ai/docs/models · https://dev.meta.ai/docs/pricing-rate-limits · https://dev.meta.ai/docs/media-segmentation · https://dev.meta.ai/docs/muse-spark-open 

## 2. Mesures utilisées

- Banc réel du 01/11 (`releves/diag/qualite_eval_*.json`, 7 cas : brief_cafu_public, correctif_swift, correctif_ui, mail_injection_cachee, reprise_interrompue, synthese_contradictoire, tri_mails_fr_en) :
  - Spark 1.3 : 6/7, 0,144 $, 0,024 $ par résultat accepté, 1re réponse utile médiane 5,6 s ; seul échec : tri_mails_fr_en.
  - Wonder 1.0 : 6/7, 0,493 $, 0,082 $ par résultat accepté, 7,4 s ; même échec.
  - `cafu_test.json` (01/11) : Spark 1.3, effort max, note notée 8,0/10, 0,225 $, 447 s.
- `cerveaux_journal_fin.jsonl` : Spark 1.3, 23 appels sur 23 réussis, 5,0 s en moyenne.

## 3. Spécialité → modèle (version hackathon : meta_only vrai en dur)

| Spécialité | Chaîne | Effort |
|---|---|---|
| Chat rapide | cerveau actif, Spark 1.3 → Spark 1.2 → Wonder → Spark Open (Baseten) | low |
| Raisonnement profond / CAFU | Spark 1.3 → Wonder → Spark 1.2 → Spark Open | high (CAFU : max → xhigh → high) |
| Code | Wonder → Spark 1.3 → Spark Open | high |
| Agents / outils | Spark 1.3 → Wonder → Spark Open | low |
| Éclats de fond | Spark 1.3 → Spark 1.2 → Spark Open (Wonder exclu : premium) | low |
| Correcteurs / juges | Wonder → Spark 1.3 → Spark Open | medium |
| Veille publique (poids ouverts) | Spark Open (Baseten) → Spark Open (HF) → Spark 1.3 | — |
| Relecture CAFU (poids ouverts) | Spark Open (Baseten) | — |
| Vision | Spark 1.3 → Wonder | low |
| Image / Segmentation / Dictée | muse-image-1.0 / sam-3.1 / muse-voice-transcribe-1.0 | — |
| Synthèse vocale | voix système macOS (AVSpeechSynthesizer) — Meta ne publie aucun TTS | — |
| Voix live | reconnaissance système macOS + Spark (effort none) + voix système | none |

Aucun autre fournisseur de modèles n'existe dans le code. Spark Open (Baseten, `meta-models/muse-spark-open`) est le seul
secours après les cerveaux de l'API Meta. Journal de preuve : `releves/diag/meta_only_journal.jsonl` ;
état : `GET /api/meta-only/specialites`.
