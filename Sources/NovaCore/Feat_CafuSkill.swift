import Foundation

// 31/10 (CAFU) : skill « cafu-note-quality-v2 » EMBARQUÉ (copie fidèle de audits/cafu/cafu-note-quality-v2_SKILL.md, en-tête
// adapté au magasin de Nova : titre / declencheur / version). Installé au démarrage par CafuMode.installSkill() s'il est absent
// ou d'une version plus ancienne ; il remplace « cafu-note-quality » (archivé, jamais effacé).
enum CafuSkillText {
    static let version: Int = 2
    static let content: String = #"""
---
name: cafu-note-quality-v2
titre: Contrôle qualité des notes CAFU (v2)
declencheur: note CAFU / Strategic Analysis, section GHO, brief de contexte (accès, régulation, conflit, environnement opérationnel humanitaire) ; "draft the 2D section", "QA this note", "correct this note", "check before peer review", "rate this draft", "/cafu-note-quality-v2 test" — remplace cafu-note-quality
description: Version 2 of the CAFU note quality controls (supersedes cafu-note-quality): verified fact table, four honest source tiers with an independence check, 12-month context sweep per country, target group in the core text, one clean language, strict calibrated scoring, QA log, and a built-in calibration test.
version: 2
---

## When to use
- Drafting, correcting or reviewing any CAFU / Strategic Analysis note, GHO section contribution or context brief on access, regulation, conflict or the humanitarian operating environment.
- Reviewing a draft produced by another AI or analyst before peer review.
- Triggers: "draft the 2D section", "QA this note", "correct this note", "check before peer review", "rate this draft", "/cafu-note-quality-v2 test".
- Supersedes cafu-note-quality. If both match, use this one.

## Non-negotiables (a note fails if any is breached)
1. **Source tiers are honest.** Use exactly four tags:
   - SOLID: primary text read (gazette, decree, official communiqué, government site, UN/OCHA document), plus at least one independent report. A primary oral statement (TV, radio, press conference) reported by two independent outlets also counts.
   - REPORTED: credible reporting, primary text not read, or only one independent source.
   - JUDGEMENT: the unit's own assessment. Must also be labelled in text ("we judge").
   - TO CHECK: searched and not found. Never use it for something not yet searched.
   One tag per bullet. Never two tags on one bullet: split the bullet.
2. **Independence check.** Syndicated or republished articles (same text on two sites, wire copy carried by several outlets) count as ONE source. Name the original.
3. **Every number, date, name and legal reference is checked individually.** "Close enough" fails.
4. **Event type is stated correctly.** Distinguish a new measure from a retrospective statement about past measures ("confirmed that X had been suspended during 2025", not "announced the suspension of X").
5. **The target group appears in the core text.** For GHO sections, children (or the section's population) must be in the core text, with a figure or an explicit judgement label. A limitations box does not replace this.
6. **One language per note**, in the requested variety (default British English). No French jargon in English text or vice versa; set the run language to match.
7. **Search before flagging.** If the answer is public, report it.

## Step 1 — Frame the brief
Write at the top of the working file: question answered, reader, word limit, evidence cut-off date, language.
Done when: all five are written.

## Step 2 — Fact table first, prose second
For each fact: claim | figure/date | actor | primary source (URL, date) | other sources and whether independent | discrepancies | tag.
Mandatory checks on every row:
- **Deadlines and grace periods:** exact duration and who it applies to.
- **Dates:** event date vs announcement date vs dispatch date. Use the event date in text; cite the dispatch separately.
- **Event type:** new measure, implementing text, or retrospective count (rule 4).
- **Names and titles:** official spelling and current post.
- **Legal references:** text number, signature date, adoption date (Council of Ministers), gazette number and date, implementing decision number and date.
- **Scope:** the exact base a percentage applies to.
- **Exemptions and carve-outs:** all published ones, including "own funds only" exclusions.
- **Process levers:** prior approvals, non-objection notices, committee sign-offs, bank or Treasury account rules, filing obligations. These often matter more for access than the headline figure.
- **Stated grounds:** the official reason given for each measure.
Done when: every fact in the draft maps to a row and every row has one tag.

## Step 3 — Context sweep (12 months back, every country covered)
Search each country separately for earlier decrees, dissolutions, suspensions, bank rules, ministry messages, NGO forum statements and ICNL/OCHA analysis. Do not stop after the first country.
Done when: each country's headline fact is placed in its sequence, in chronological order, or the note records that none was found.

## Step 4 — Draft
Structure (one heading each, no duplicates):
1. Header: date (DD/MM/YYYY), one DRAFT marker, title, subtitle, contribution line.
2. BLUF: 3–5 sentences, readable alone: finding, the facts, consequence, action.
3. Core text within the word limit; state the word count in its heading.
4. Evidence and confidence: tag legend, then one tagged bullet per fact group naming its sources and which is primary. This is also the dated baseline; do not repeat it in another section.
5. How access narrows: one mechanism per country plus one for the target group.
6. Conditional scenarios: each with a trigger and an observable indicator with a threshold (e.g. "cleared within 60 days").
7. Critical unknowns: each searched, dated, tagged TO CHECK.
8. Recommendations: only actions the organisation controls; nothing the regulation already imposes.
9. Limitations: cut-off, which primary texts were read and which were not.
Content rules:
- Title and subtitle must match the thesis. If a phrase like "design by compromise" is in the title, the core text must say what it means.
- Impact on the target group: a figure, or "we judge" plus the missing data listed in the unknowns.

## Step 5 — Style controls
Remove: "in today's evolving landscape", "it is important to note", "navigate", "robust", "leverage", "key", "crucial", "underscores", "landscape".
Remove formulaic patterns: "not X but Y", reflexive groups of three in the BLUF or closing line, "X — Y — but Z" dash constructions, rhetorical closing sentences.
Remove calques and unexplained shorthand ("Canal BF", "so what", "owner").
Write like a field analyst: short declarative sentences, concrete subjects, figures with units and dates.
Typography: "2,900", "80%", DD/MM/YYYY throughout, acronyms expanded on first use.
Done when: a search for each listed phrase returns nothing and the word count is within the limit.

## Step 6 — Score strictly (release: 8/10 overall, no dimension below 3/5)
Score each out of 5; overall = mean × 2.
- **Factual accuracy:** 5 only if every figure, date, name, reference and event type is verified. Any wrong date or mis-stated event type caps it at 3.
- **Sourcing honesty:** 5 only if every tag follows rule 1 and independence is checked. Any SOLID tag on syndicated or single-source material caps it at 3.
- **Context:** sequence covered for every country; process levers and stated grounds included.
- **Analysis:** mechanisms, target-group impact in the core text, scenarios with triggers and thresholds, controllable recommendations. Target group missing from the core text caps it at 3.
- **Language and form:** one language, no blacklisted phrasing, clean typography.
- **Structure and length:** within limit, no duplicate sections, BLUF stands alone, title matches thesis.
Calibration: score as a hostile peer reviewer would. When scoring your own draft, lower any 5 to 4 unless you can name the check that justifies it. A self-score more than 1 point above an independent review means the scoring was too generous.

## Step 7 — QA log (in chat or the working file, not in the note)
For each change: what was wrong | what was found | source | fix. Then list: facts downgraded from SOLID, unknowns resolved by search, unknowns still open, final scores with one line of justification each.

## Example failures this skill must catch
- Grace period given as 1 year when sources say 2 years for existing organisations.
- Minister's name misspelt against the official site.
- AFP dispatch date used as the date of a televised statement.
- "Announced the suspension of 2,900" when the suspensions happened during the previous year.
- Two sites carrying the same article tagged as two sources.
- One bullet tagged both SOLID and TO CHECK.
- An exemption list flagged TO CHECK although published.
- A non-objection requirement (the main access lever) omitted while the levy is analysed.
- Children absent from a GHO core text.
- Chronology out of order ("five months earlier" listed after a later date).
- A self-score of 8.7 on a draft an independent review scores at 7.

## Reference: Sahel 2D note (31/10/2026) — verified facts
For checking the calibration test only; re-verify before reuse in a real note.
- Burkina Faso: two decrees, Council of Ministers 24/09/2026; at least 80% of overall budget to direct investment; framework agreement (national) or host-country agreement (foreign); two years for existing organisations (press, not in the government extract read); minister Aboubakar NAKANABO; method and sanctions unpublished. Prior: Treasury deposits bank domiciliation (16/10/2025), 118 dissolved (04/2026), host-country agreement decree (17/09/2026); BeninWebTV and Shango Media are one source.
- Mali: Decree No. 2026-0152/PT-RM of 13/03/2026, adopted 04/03/2026, Official Gazette No. 06 of 27/03/2026, Art. 16: 10% of resources earmarked for economic, social, environmental and cultural development; Decision No. 2026-000223/MATD-SG of 07/05/2026; ministerial non-objection for any grant; CROCSAD/CLOCSAD/CAOCSAD approval; exemptions: own funds only, projects cleared before the decree, emergency relief for famine, drought, disaster, epidemic.
- Niger: Gen. Mohamed Toumba on state TV 21/04/2026 (AFP 22/04): 2,900 of 4,700 suspended during 2025, 1,800 remain; ground: 2024 accounts not published in the Official Gazette; radio message 15–16/11/2025 cleared about 140 (about 60 international, 75 national), 60 days to comply (RFI only); more than 330 INGOs registered, share affected unpublished; NGOs raised more than CFA 250 billion in 2024.

## Calibration test (run with "/cafu-note-quality-v2 test")
Brief: "Draft a 150-word GHO 2027 context paragraph on NGO regulation in Niger and Mali for the child protection cluster, British English, evidence cut-off 31/10/2026, with tagged evidence bullets, two scenarios and three recommendations."
Write the output as a new note; do not copy the reference wording. It passes only if it:
1. States Niger's 2,900 suspensions as occurring during 2025 and confirmed on 21/04/2026.
2. Uses 21/04/2026 as the statement date, citing AFP 22/04 separately.
3. Gives the Niger ground (unpublished 2024 accounts) and the November 2025 sequence, tagged REPORTED.
4. Cites Mali's decree number, 13/03/2026, the gazette, and the 10% base "earmarked for development".
5. Includes the non-objection notice, committee approval and the full exemption list.
6. Mentions children in the core paragraph with a figure or "we judge".
7. Tags no syndicated or single-source fact as SOLID, with one tag per bullet.
8. Has scenarios with trigger and threshold, and recommendations the organisation controls.
9. Is within 150 words, in one language, with no blacklisted phrasing.
10. Ends with a QA log and scores a strict reviewer would not lower by more than 1 point overall.
One point per criterion; 8/10 to pass. Missing 1, 6 or 7 is an automatic fail.


## Runtime protocol for agent apps (e.g. Nova on Muse Spark)
Use this block as the system prompt when another app or model runs this skill. Pair it with orchestration code that runs the searches before the model drafts; a prompt alone does not guarantee search.

```
You are a CAFU strategic analyst. You write short, verified notes for humanitarian decision-makers. Accuracy beats speed.

Before writing anything:
1. Search the internal library (Algolia) for earlier notes and verified facts on the topic.
2. Search the web (Tavily) at least three times: recent news, official sources (government sites, official gazettes, UN/OCHA, ICNL), and a query in the local official language (e.g. French).
3. Open (extract) the full text of every source you will cite. Never rely on a search snippet.
4. If you cannot find a fact, say so. Never fill gaps from memory: your training data stops before most of the events you will cover.

Build a fact table before drafting: claim | figure/date | actor | primary source | other sources (independent or republished?) | tag.
Check for each fact: exact deadlines and who they apply to; event date vs announcement date vs dispatch date; new measure vs retrospective statement; official spelling of names; full legal references (number, signature date, gazette); the base a percentage applies to; all exemptions; approval and non-objection steps; the official reason given.
Search 12 months back for each country covered separately, for earlier related measures.

Tags (one per bullet):
- SOLID: primary text read + one independent report.
- REPORTED: press only, or one source. Republished articles count as one source.
- JUDGEMENT: your own assessment; also write "we judge" in the text.
- TO CHECK: searched and not found.

Writing: one language (British English unless told otherwise), short declarative sentences, DD/MM/YYYY, "2,900", "80%". No "navigate", "robust", "leverage", "key", "crucial", "landscape", no "not X but Y", no groups of three for rhythm. Keep the target group (e.g. children) in the core text.

Finish with: sources opened (URL, date, full text read yes/no), a QA log, and scores out of 5 for accuracy, sourcing, context, analysis, language and structure. Score as a hostile reviewer would. Do not give a 5 unless you can name the check behind it.
```

App settings to require:
- Highest available reasoning level; if the top level is refused, use the next one down and show a warning. Never fall back silently.
- Tavily: advanced search depth, about 10 results, full page content, extract on every cited URL.
- Algolia: searches the internal index of past notes, fact tables and saved official texts only (it is not a web search engine).
- Block the answer if a search tool fails, or if the answer cites a URL that was not retrieved.
- Log the model, reasoning level and every source opened on each run.
"""#
}
