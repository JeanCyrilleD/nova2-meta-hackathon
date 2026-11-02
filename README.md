# Nova — the augmented analyst · 100% Meta models

**▶ Demo video (2 min 27):** https://youtu.be/XUFS6rvUn8o

📣 Like / repost / comment the demo on X (Most Viral track): https://x.com/DahaniPasc81200/status/2116924167429960109

📝 Model feedback for Meta (observed failures, mitigations, recommendations): [MODEL_FEEDBACK.md](MODEL_FEEDBACK.md)

License: All rights reserved — see LICENSE (evaluation permitted).

Nova is a native macOS companion (Swift + a local web UI) for an analyst who writes sourced notes: it drafts
context notes (BLUF, tagged evidence, scenarios, recommendations), reviews them with an open-weight
model, triages mail and agenda, dictates, generates images and talks back — **and every model it calls at runtime is
a Meta model.** There is no other model provider in this code: no client, no key slot, no endpoint.

- Track: Indie Developer (solo). Suggested GitHub topic: `meta-hackathon-2026`.
- Platform: macOS 13+ (Apple silicon or Intel), Xcode 15+ / Swift 5.9+.

## Features

- **Chat with tools** on Muse Spark 1.3: web search and fetch, files, mail, agenda, shell (with approval cards),
  several pure reads run in parallel in one step.
- **Sourced context notes** (note mode): research → Spark 1.3 draft (BLUF, tagged evidence, scenarios, recommendations) →
  Spark Open review, each step journaled and costed.
- **Reliability rule** in the system prompt (safety first, then the explicit instruction of the message, then house
  style; unknown = said, never guessed; a failed tool is followed by 2–3 other ways) and a **source check**
  (`Sources/NovaCore/VerifFaits.swift`): a URL that no tool of the turn returned triggers one verification pass, and
  what stays unconfirmed is marked `[[NON CONFIRMÉ]]`.
- **Complete answers**: per-request cap raised for Meta brains (1.50 $ by default), cache reads billed at the
  published Meta price, clean conclusion at the cap instead of a cut, no silence after "Approve" or after
  "I will do it" (`Sources/NovaCore/Feat_ChatTasks.swift`).
- **Driving Nova's own UI**: verified internal navigation (the target screen is read back), settings re-read after a
  change, conversation verbs `conv-liste`, `conv-ouvrir`, `conv-lire` (list, open, read) (`Sources/NovaCore/Pilotage.swift`, `web/js/pilot-resolve.js`).
- **Narrow window**: the conversation list becomes an opaque drawer over a veil.
- **Notifications**: a conversation waiting for your approval, a long task finished, Dock badge
  (`Sources/NovaCore/NovaNotifier+Attention.swift`).
- **Voice**: Muse Voice Transcribe dictation (canonical WAV sent as is, shared HTTP session to `api.meta.ai`),
  Spark 1.3 as the voice brain (`reasoning_effort` `minimal`), macOS system voice pre-warmed at launch, barge-in, and
  a voice bench (`Sources/NovaCore/VoixBanc.swift`). Voice update of 01/11/2026 (`Sources/NovaCore/VoixRapide.swift`,
  `Sources/NovaCore/Feat_VoiceLive.swift`):
  - **earlier first audio**: the brain starts as soon as the end of speech is detected and the partial transcript is
    stable (early start; if you resume speaking within the pause window, the turn is cancelled and both parts are merged),
    the first clause (a comma or six words) is synthesised without waiting for the end of the sentence, the connection
    to `api.meta.ai` is pre-warmed when live voice starts, and a short pre-rendered acknowledgement ("Mm.", "D'accord,")
    plays if nothing has been said 700 ms after your question (never two turns in a row);
  - **language-matched voice**: the language is detected on the reply text, so an English answer is read by an English
    system voice and a French answer by a French one (also for `/api/tts`);
  - **barge-in**: an interruption no longer discards the words that triggered it, and sentences of an interrupted turn
    are no longer synthesised;
  - **empty replies**: Spark's output cap is raised to 1024 tokens in voice mode (its non-streamed reasoning used up the
    previous 320-token floor: 2 empty replies out of 24 in the 08:42 bench), `finish_reason` and `refusal` are read and
    named, and an empty reply is retried once, then answered with an honest sentence instead of silence;
  - **vocabulary**: dictation sends the documented `keywords` (fixed list of place names and domain
    acronyms, never contacts or memory) and `languageBias` fields, with one retry without them on HTTP 400;
  - **Meta-only picker**: the brain selectors list Meta brains only.

  Measured with the voice bench on 01/11/2026 16:39 UTC (same voice code, run in the author's everyday build of Nova;
  every model call was Muse Voice Transcribe or Spark 1.3; 24 synthetic public phrases, 0.061 $ in total):
  - **real-time conversation mode** (SFSpeech fed the audio in real time, the stable partial sent to Spark; 12 turns,
    10 measured): first sound median **0.75 s** (the acknowledgement, 0.74 s); first audio of the actual answer
    median **1.28 s** (p90 1.65 s), against **2.77 s** in the bench of 08:42 UTC before this update; end of speech →
    first Spark token 1.21 s; barge-in 3 of 3, stop median 0 ms, resume median 0.72 s (2.5 to 3.5 s before);
    word error rate of the partials 13.7 %;
  - **file mode** (Muse Voice Transcribe dictation of each file, 24 turns): dictation median 1.81 s, Spark first token
    1.09 s, end-to-end first audio median 3.15 s (the file dictation is included);
  - all 24 turns: mean word error rate 5.5 %, **0 empty replies out of 24** (2 of 24 at 08:42), place names
    transcribed correctly.

  Limits: the actual answer still starts above 1 s, bounded by Spark's first token; in this bench SFSpeech did not run
  on-device. Covered by simulated tests: `VoixRapideTests`, `VoixBancStreamingTests`, `MetaOnlySelecteurTests`.
- **Images** (Muse Image), **segmentation** (SAM 3.1), mail and agenda triage, the Dots automations, budget ledger
  with spend caps, approvals, keyless demo replay.

## 1. Install and run (step by step)

1. Install Xcode (App Store) and open it once, or install the command-line tools: `xcode-select --install`.
2. Clone this repository and enter it:
   `git clone <repo-url> nova && cd nova`
3. Keys — copy the template and fill it, or skip this step and use the keyless demo (section 2):
   `cp .env.example .env` then set `META_API_KEY` (Meta Model API) and `BASETEN_API_KEY` (Spark Open on Baseten),
   and load them: `set -a; source .env; set +a`. Keys are read from the environment or the macOS Keychain
   (`Sources/NovaCore/Keys.swift`); they are never written to disk by Nova and never committed (`.gitignore`).
4. Build: `swift build` (first build fetches the only package dependency, sentry-cocoa).
5. Run the app: `swift run NovaMac` — the window opens on the local UI. To build a signed `.app` bundle instead:
   `bash tools/package_app.sh`.
6. Tests: `swift test` (thread-sanitised run: `swift test --sanitize=thread`). Extra static checks: `bash tools/verify.sh`.

`meta_only` is **hard-wired to true** (`Sources/NovaCore/MetaOnly.swift:31`): there is no setting to turn it off, so
the old "Meta models only" switch is shown as "always on" in Settings and cannot be changed.

## 2. Keyless demo mode (no key, no Mac needed)

Judges without keys can still see the real flow. Nova ships **recorded real runs** in `demo/traces/`, built from
Nova's own run logs by `tools/demo/build_traces.py` and sanitised (model ids, endpoints, timings, token counts,
costs, public source URLs only — no conversation text, keys, paths or e-mail addresses).

- Without a Mac: `python3 tools/demo/replay.py all` (or `cafu_note`, `spark_open_review`, `image`, `dictation`,
  `voice_chain`, `meta_routing`). No network call is made.
- In the app: `NOVA_DEMO_REPLAY=1 swift run NovaMac`, then `GET /api/demo/traces`, `GET /api/demo/trace?id=cafu_note`
  or the step-by-step stream `GET /api/demo/replay?id=cafu_note` (`Sources/NovaCore/DemoReplay.swift`).

| Trace | What it shows | Recorded real run? |
|---|---|---|
| `cafu_note` | Analysis note from public sources only — Muse Spark 1.3, `reasoning_effort=max`, 447 s, LLM cost 0.2254 $ (01/11/2026) | yes |
| `meta_routing` | the `meta_only` proof journal: every routed model call, all `meta: true` | yes |
| `image` | Muse Image call (`muse-image-1.0`), journal lines only (no image file) | yes |
| `spark_open_review` | Spark Open (Baseten) calls of 01/11/2026: the first ones with a wrong model id (`…-1026`, HTTP 404, now fixed to `meta-models/muse-spark-open`), then the note review that succeeded at 06:44:54 UTC | yes |
| `dictation` | Muse Voice Transcribe dictation (`POST /v1/asr/transcribe`), 24 calls of the voice bench of 01/11/2026 08:42 UTC, synthetic public phrases, no transcript text | yes |
| `voice_chain` | the voice bench end to end: Muse Voice Transcribe → Spark 1.3 (`reasoning_effort` `minimal`) → macOS system voice; 21 measured turns, first audio median 2.77 s (the < 1 s target is not met in this file-based bench), barge-in 2 of 3, 0.0256 $ | yes |

A trace without a successful real run is marked `"recorded": false`; nothing is invented. After a real run, rebuild
with `python3 tools/demo/build_traces.py --diag <run-logs dir>`.

## 3. Meta models → role

| Meta model | Role in Nova | Where (file:line) |
|---|---|---|
| Muse Spark 1.3 (`muse-spark-1.3`) | default brain: chat, agents and tools, background tasks, vision, context notes (`reasoning_effort` max → xhigh → high), voice-live brain (`minimal`) | `Sources/NovaCore/Brains.swift:176`, `Sources/NovaCore/MetaSpecialites.swift:89` |
| Muse Wonder 1.0 (`muse-wonder-1.0`) | code, judge / second reader, deep fallback | `Sources/NovaCore/Brains.swift:172` |
| Muse Spark 1.2 (`muse-spark-1.2`) | fallback of Spark 1.3 | `Sources/NovaCore/Brains.swift:180` |
| Muse Spark 1.2/1.3 Contributor | explicit choice only, never in automatic chains (Meta may train on that tier) | `Sources/NovaCore/Brains.swift:193` |
| Muse Spark Open (`meta-models/muse-spark-open`, Baseten) | open-weight Meta fallback, note QA review, public news synthesis | `Sources/NovaCore/Brains.swift:203` |
| Muse Spark Open 816B (Hugging Face) | optional, hand-picked only (HF token) | `Sources/NovaCore/Brains.swift:200` |
| Muse Code (CLI `muse exec`) | optional, hand-picked only (Muse Code subscription) | `Sources/NovaCore/Brains.swift:196` |
| Muse Image (`muse-image-1.0`) | images (briefs, design studio) | `Sources/NovaCore/MetaCapabilities.swift:21`, `Sources/NovaCore/App.swift:1131` |
| Muse Voice Transcribe (`muse-voice-transcribe-1.0`) | dictation and audio-file transcription (`POST /v1/asr/transcribe`) | `Sources/NovaCore/MetaCapabilities.swift:23`, `Sources/NovaCore/Voice.swift:220` |
| SAM 3.1 (`sam-3.1`) | image / video segmentation (`POST /api/meta/segment`, explicit confirmation) | `Sources/NovaCore/MetaCapabilities.swift:22`, `Sources/NovaCore/MetaCapabilities.swift:117` |

**Meta calls are visible.** Every call passes a network gate (`Sources/NovaCore/HTTPStream.swift:59` →
`Sources/NovaCore/MetaOnly.swift`) that blocks, before sending, any request naming a non-Meta model or any non-Meta
WebSocket, and writes one line per call to `releves/diag/meta_only_journal.jsonl` (provider, host, model, status,
specialty). Live view: `GET /api/meta-only/specialites`. A copy of that journal is the `meta_routing` demo trace.

## 4. Not models

- **Tavily** (web search), **Brave / DuckDuckGo** (search fallback), **Algolia** (full-text index of the user's own
  library) — search services, no model is called.
- **macOS system voice**: speech synthesis by `AVSpeechSynthesizer` (`Sources/NovaCore/Feat_VoixLocale.swift:218`) and
  speech recognition by `SFSpeechRecognizer` for live voice and wake word (`Sources/NovaCore/Feat_VoiceLive.swift:91`),
  on-device recognition required whenever the language supports it. These are operating-system services, not
  generative models called by Nova. Meta publishes no text-to-speech model (dev.meta.ai: Voice Transcribe "does not
  synthesize speech"). This classification is our reading; it was not confirmed by the organisers.
- Gmail / Outlook / Teams / Zoho / RSS readers, Sentry (crash reports), Amplitude (analytics) — no model.

## 5. Where and how Spark Open (open-weight) is used

Muse Spark Open runs on Baseten, model `meta-models/muse-spark-open`, endpoint
`https://inference.baseten.co/v1/chat/completions` (`Sources/NovaCore/Brains.swift:203`). Three real uses:

1. **Meta fallback.** Every automatic chain is Meta-only, and Spark Open is appended right after the Meta Model API
   brains (`Sources/NovaCore/MetaSpecialites.swift:188`; reroute pool `Sources/NovaCore/Router.swift:304`): an outage of
   the Meta API (5xx, 429, timeout, credit) falls over to the open-weight model, never to another vendor.
2. **Note QA review.** After Spark 1.3 drafts a context note, Spark Open reviews it (facts, evidence tags, score) as a
   visible, journaled, costed step (`Sources/NovaCore/MetaSpecialites.swift:283`, called from
   `Sources/NovaCore/Feat_CafuMode.swift:1146`). Without a Baseten key the step is skipped and says so.
3. **Public synthesis.** `POST /api/feed/synthese-ouverte` summarises public RSS headlines with Spark Open
   (`Sources/NovaCore/MetaSpecialites.swift:389` and `:404`); only public titles are sent.

Each Baseten call is logged with tokens and cost at the Baseten price (1.25 $ in / 4.25 $ out per M tokens).

## 6. What pre-existed vs built during the event

**About this repository's history.** This public repository starts with a **single-commit snapshot** (01/11/2026) of the
submission branch, followed by README updates (demo video, X post), a post-submission update (fixes listed in Features) and a voice update (Features, Voice). The real development history starts on **26/10/2026** (root commit `4817512`, tag
`v2.0.0-baseline`, 26/10/2026 16:10:36 UTC) and is kept in the author's private repository, because older commits
contain personal data that was removed from the code before publication.
**Development history kept private (contains personal data); available to judges on request.**
The commit hashes below refer to that private history.

- **Pre-existing (before 26/10/2026), taken from Nova 1.** Nova 1 (the author's earlier app) and its engine
  `NovaCore` (router, tools, memory, mail and agenda bridges, the Dots automations, the macOS shell), carried into
  Nova 2 nearly unchanged; the Nova 2 rebuild of the web layer started on 20/10/2026 (see `ARCHITECTURE.md`). The
  private history's root commit `4817512` (26/10/2026) **imports that pre-existing code as one snapshot** (510 files).
  That commit is pre-existing work, even though it is dated 26/10.
- **Built during the event (26/10 16:57 UTC → 01/11/2026, every commit after the root in the private history).**
  Muse Wonder, Spark 1.2, Muse Image, Voice Transcribe and SAM 3.1 (commit `339e2b9`, 26/10 16:57 UTC), Spark Open on
  Baseten (`5ab0f5d`, 29/10), routing by specialty (`MetaSpecialites.swift`, 01/11) and the `meta_only` gate and proof
  journal (`MetaOnly.swift`, 01/11), the note mode (`Feat_CafuMode.swift`, first committed 31/10 in the bulk commit
  `7c08d37`: research → Spark 1.3 draft → Spark Open review), budget ledger and spend policy (`CostLedger.swift`,
  `SpendPolicy.swift`, 31/10), approvals (`SendApproval.swift`, 31/10), the web UI consolidation, and the Meta-only
  submission branch (removal of every non-Meta provider, keyless demo, personal-data review). Muse Spark 1.3 and
  Spark Open via Hugging Face were already wired in the baseline and are **not** claimed as event work; the panda
  avatar (`web/js/mascot.js`, illustrations in `web/avatars/`) and the live-voice engine (`Feat_VoiceLive.swift`, in
  the baseline; changed this week to Meta-only) are pre-existing too. Against the baseline the tree has 357 new files
  and 443 kept files (556 files changed, +42 209 / −14 703 lines, measured on the private history).
- **Uncertain.** Commit `7c08d37` (31/10/2026, "Nova 2 initial", 339 files) was committed in bulk: its date is
  certain, the day-by-day origin of each file inside it is not.
- Some visual assets (avatar illustrations, glass icons) were produced earlier with third-party creative tools; they
  are static files, and no model is called to produce or play them.
- **Example data.** Names, addresses, amounts and portfolio lines that appear in prompts, tests and fixtures are
  fictional (marked « fictif » / « exemple », `example.org`, `.example`). The note and Fundings modules are kept as
  generic code: the Fundings store starts empty and the note evaluation case uses public sources only
  (`eval/cas/brief_cafu_public.json`).

## 7. Tests

`swift test --sanitize=thread`: 314 XCTest cases, 0 failures (1 skipped), 0 ThreadSanitizer warnings, and `tools/verify.sh` passing on 01/11/2026 after the voice update (227 at submission; new suites `ChatAboutiTests`, `PilotageTests`, `UIEtroitNotifTests`, `FiabiliteTests`, `VoixTestTests`, `VoixRapideTests`, `VoixBancStreamingTests`, `MetaOnlySelecteurTests`). Every test is simulated: no network, no key. Routing
v2, budget and bench tests run on a **fictional** provider registry (`Tests/NovaCoreTests/Fixtures/`, vendors named
`vendor-*`), so the generic engines stay tested while the shipped configuration (`Config/`) is Meta-only.
`DemoReplayTests.testNoNonMetaModelHostInShippedCode` fails if a non-Meta model host appears in `Sources`, `web/js`
or `Config`.

## 8. Open-source dependencies

| Dependency | Licence | Use |
|---|---|---|
| sentry-cocoa 9.31 (Swift package) | MIT | crash reports (optional DSN) |
| three.js 0.160.0 + examples (GLTF/DRACO/KTX2 loaders, RoomEnvironment, BufferGeometryUtils, WorkerPool, ktx-parse, meshopt decoder, zstddec) — `web/vendor/` | MIT | 3D companion |
| Draco decoder, Basis Universal transcoder (wasm) — `web/vendor/draco`, `web/vendor/basis` | Apache-2.0 | 3D assets |
| hls.js — `web/vendor/hls.min.js` | Apache-2.0 | video playback |
| Fraunces, Hanken Grotesk, Spline Sans Mono — `web/assets/fonts/` | SIL OFL 1.1 (licence files included) | fonts |

Licence texts and copyright holders of the vendored files: `web/vendor/THIRD_PARTY_LICENSES.txt`. Nova's own code is
under `LICENSE` (all rights reserved, evaluation permitted); these components keep their own licences.

## 8b. Credits

- **Origins of Nova.** Nova was started with Meta's **Muse Code** and **Muse Spark 1.3** as coding and design assistants:
  they shaped its first architecture and code. Other AI coding assistants were used later in development; every model
  Nova calls at runtime is a Meta model (section 3).
- **Baseten** hosts Muse Spark Open, the open-weight Meta model Nova uses for independent review (section 5). Thanks to
  the Baseten team for the access and support during the hackathon.

## 9. Privacy

No personal data, internal organisation data or secrets are committed: run logs (`releves/`), working files
(`dormant/`), audits (`audits/`), build products (`.build/`, `build/`, `*.dSYM`), `.env`, mails and finance data are
excluded by `.gitignore`. Keys live in the macOS Keychain or the
environment only.
