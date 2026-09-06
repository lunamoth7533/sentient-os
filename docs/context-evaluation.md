# Fixed context evaluation

The fixture and five queries in `Tests/Fixtures/ContextEvaluation/corpus.json` were frozen before retrieval/summarization changes. Both paths use the same synthetic content and a 1,024 UTF-8-byte conservative token budget. Dates, source roles, required evidence IDs and forbidden project hits are explicit. The final harness assigns Codex and Lattice their own source identities and runs the production SQLite store and retriever, including query reads in latency; fixture import/setup is excluded.

The baseline compiles the original production KnowledgeVault loader and captures the mirror's default `get_structure` consumption policy (README plus file tree). That path offers no query API and supplies navigation rather than the underlying facts. Subsequent model-chosen file reads were **not evaluated**. This is a comparison of automatic context provision, not proof of better downstream model answers or a comparison against a complete agent searching the old vault.

| Query | Baseline required support | Final required support | Final citations | Bytes | Final latency ms |
| --- | --- | --- | --- | --- | --- |
| continuation | 0/2 | 2/2 | 2 | 468 | 0.717 |
| cross-session | 0/2 | 2/2 | 3 | 676 | 0.922 |
| conflict | 0/2 | 2/2 | 2 | 419 | 0.856 |
| project-isolation | 0/1 | 1/1 | 1 | 247 | 0.403 |
| lattice | 0/2 | 2/2 | 2 | 501 | 1.033 |

- **Important omissions:** baseline omits all nine required source facts/decisions; final includes all nine. The Friday/Monday conflict includes both dated statements and the explicit correction. Mercury retrieval excludes Atlas, and Lattice preserves zero steps versus missing sleep.
- **Relevance:** final retrieval returns ten cited records across the five queries. Nine are in the strict required set (90% required-set precision); the extra cross-session item is an assistant proposal about storage, explicitly marked unverified. No forbidden project evidence appears. A review run initially returned 17 records because the project name matched every project record; removing that anchor within explicit project filters reduced unrelated results using the same frozen queries.
- **Factual support and citations:** every returned citation maps to its exact fixture source record (100% ID accuracy). The summaries/excerpts use source wording with role attribution; no new outcome or preference is inferred. This checks provenance and retrieval, not whether a source's original statement is true.
- **Latency:** single-run median default baseline load 0.227 ms; final SQLite-backed lexical retrieval 0.856 ms on this Mac. Baseline does less work. These are single-run tiny-corpus measurements, not production throughput benchmarks; raw per-query measurements are retained. Earlier development timings used in-memory records and are not used in this final table.
- **Graph/semantic decision:** lexical-plus-native-graph returns the same evidence on this corpus, which has no additional native links. No measured retrieval benefit justifies enabling graph expansion by default. Separate regressions verify real native parent/tool links, source/project isolation and graph edge resolution. No semantic infrastructure was added; its potential benefit on broader queries remains unmeasured.

Raw artifacts: [baseline](context-baseline.json), [final lexical and graph outputs](context-final.json). Reproduce final output with `SENTIENT_EVAL_OUTPUT="$PWD/docs/context-final.json" Scripts/test-context.sh` (supported Xcode toolchain required). The original baseline output stays frozen rather than being overwritten with the new loader.

The fixed corpus also drives deterministic, attributed project/session projections. Additional regression tests verify corrections/deletion rebuilding summaries, source-provided Lattice summaries remaining attributed, tool failure flags, private-source exclusion, native-link integrity, literal Markdown not fabricating graph edges, and source permissions at each output boundary. No cloud/model inference was invoked in this evaluation.
