# Model feedback for Meta — what we observed while building Nova

Nova calls Meta models only: **Muse Spark 1.3** (`muse-spark-1.3`, Meta Model API) answers, and **Muse Wonder 1.0**
reviews. This page lists the model behaviours that made Nova fail its own reliability bench, how Nova works around
each one today, and what we would suggest to the model team. It is written to help, with reproducible numbers.

## How we measured

- **Bench:** 21 fixed cases (mail triage, hidden prompt injection in a mail, refusing to show secrets, ambiguous
  requests, sourced briefs from labelled public documents, evidence grading). Synthetic or public material only.
- **Runs:** 9 full passes on 1–2 November 2026, i.e. 189 case runs, graded by deterministic checks in
  `Sources/NovaCore/Feat_BancEtendu.swift`.
- **Outcome:** 22 failed case runs. About 4 were grader errors that we fixed in the grader, not in the model. With the
  mitigations below, the last pass scored **21/21**, with 54 of 54 citations correct, a median first token of 4.1 s,
  and 0.45 $ for the 21 cases.

## Observed behaviours

| # | Behaviour | Seen | Nova's mitigation today |
|---|---|---|---|
| 1 | **Source type dropped.** The answer cites a news-agency dispatch without saying it is one, and can present the dispatch's publication date as the date of the event. | 6 of 9 passes | A deterministic post-check reads the type and date from the document header and appends them.* |
| 2 | **Over-confident evidence grading.** A figure backed by one document is labelled as corroborated; once, the figure was credited to the wrong document. | 5 of 9 | A two-source check on cited URLs in the note mode; open in plain chat. |
| 3 | **Required tool call silently skipped.** Asked to draft a reply, the model writes the draft in text but omits the `draft_reply` call when no mail id is given, instead of calling it with what it has or asking for the id. | 3 of 9 | A deterministic post-check adds the missing draft proposal. It never adds a send.* |
| 4 | **Key term paraphrased away.** In a procedure answer, the exact qualifier from the source ("earmarked for development") is lost in paraphrase. | 2 of 9 | None specific yet; tracked as variance. |
| 5 | **Over-asking.** For one ambiguous request the model asked 4 clarifying questions where 1 was enough. | 2 of 9 | None specific yet; tracked as variance. |
| 6 | **Empty reply under a small output cap.** In voice mode, non-streamed reasoning used the whole 320-token cap, so nothing visible came back. | 2 of 24 voice turns | Cap raised to 1024, `finish_reason` and `refusal` read, one retry, then an honest sentence. |
| 7 | **Unverified URLs.** Early on, answers cited URLs that no tool of the turn had returned (no count kept). | early tests | `VerifFaits.swift` runs one verification pass and marks what stays unconfirmed. |

\* Added on 2 November 2026 in Nova's own build; published here with the next code update.

**What worked well:** the hidden prompt injection in the mail never led to an unsafe action, the model never
printed secrets, and in the last two passes 107 of 107 citations matched their source.

## Recommendations to Meta

1. **Train and evaluate source attribution with document metadata.** Keep "event date" and "publication date"
   apart, and name the kind of source (dispatch, report, dataset) when the document says it.
2. **Calibrate confidence labels.** Treat "corroborated" as an explicit two-independent-sources claim, and evaluate
   it.
3. **Tool-call completeness.** When the user asks for an action that a tool exists for, the model should call it
   with partial arguments or ask for the missing one, rather than replacing the call with prose.
4. **Visible-output guarantee.** Reserve part of `max_tokens` for visible text when reasoning is enabled, or return a
   distinct `finish_reason` when reasoning used the whole budget.
5. **Respect a "one question" instruction** in ambiguous requests. This is cheap to add to instruction-following
   evaluations.
6. **Documentation:** say whether `temperature` is accepted by the Meta Model API. Today we do not send it, because it
   is not documented.

Reproduce: run the bench from the app (quality evaluation, brain `spark-1.3`, reviewer `wonder-1.0`). Results are
written to `releves/diag/qualite_eval_spark-1.3.json`.
