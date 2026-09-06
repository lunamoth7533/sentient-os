# Imported context

Use **Settings → Knowledge Sources → Manage imported sources**. Add a detected source or choose a file/folder, then press **Import**. Adding a source saves configuration only. Import is local and does not need a loaded model. Analyze Now and overnight runs also refresh enabled imports.

The Evidence tab searches current records and opens individual citations with native roles, metadata, dates and original locators. The Knowledge graph includes generated, read-only project/session notes. Use source controls to correct their availability; edit the original export and import again to correct its content.

Three independent switches have different effects:

- **Collect future changes** stops or enables future collection. Existing evidence remains.
- **Use saved evidence in context** controls local search, summaries and graph visibility.
- **Share redacted excerpts with connected or cloud models** permits that source in Sentient command context, the shared MCP connection, and the optional encrypted cloud mirror. It starts off for every new source, including health data. This is a source-wide grant.

Remove deletes Sentient's imported evidence and configuration. It never edits or deletes the original source. A remote mirror update still requires a successful network operation; already consumed model context cannot be recalled. Disconnect turns local sharing off immediately and displays a pending-removal notice if the previous cloud copy could not be removed. Use **Retry cloud removal**; cleanup credentials persist securely across restart and token rotation.

## Supported inputs

| Adapter | Verified input and access |
| --- | --- |
| Codex CLI / desktop | Native rollout JSONL including archives; explicitly selected projected thread-history SQLite. Rollouts preserve more metadata. |
| Claude Code | Native project and subagent JSONL transcripts. |
| Hermes | Native `state.db` schema 30; whole-session exports. |
| OpenClaw | Native agent SQLite schema 19; legacy JSONL and explicit branch exports. |
| Lattice | Native Workbench `lattice.context-capsule.v1` JSON; explicitly selected personal-snapshot copy compatibility mode. |
| Markdown | Explicit UTF-8 notes, with file identity and modification-time provenance. |
| Metrics CSV | Documented nine-column, unit/date/revision-aware interchange format. |

See [verified session formats and exact exclusions](session-source-formats.md) and [Lattice/CSV contracts and producer limitations](LATTICE_IMPORT.md). Claude Desktop and proprietary ChatGPT conversations have no verified adapter here. Codex's metadata-only state DB, prompt-only histories, encrypted payloads and unknown future transcript records are not treated as complete conversations. Unknown formats report an actionable error or partial import. Lattice currently has no native personal-metrics JSON/CSV exporter; the compatibility reader is not a live Lattice storage integration.

## Model connection

Configure a stdio MCP server using the built app executable (`Sentient OS.app/Contents/MacOS/Sentient OS`) with argument `--context-mcp`. The Connect a model tab displays the installed executable path. This mode does not start the GUI, telemetry, scheduler, models or network requests.

- `list_context_sources` lists only permitted sources and project IDs without loading transcript bodies. Shared project IDs are opaque so private working-directory paths are not exposed. Follow `next_source_offset` with `offset` for more sources; pass `source` and `next_project_offset` as `offset` for more projects in that source.
- `search_context` accepts `query`, exact `project`, `source`, ISO8601 `after`/`before`, `budget`, and optional `include_graph`.
- `get_context_evidence` reads a returned citation ID and rechecks permissions.

MCP defaults to sharing-enabled sources. The explicit launch argument `--local-context` grants the connected process all locally included sources, including sensitive records. Use that only when deliberately granting a trusted local model access. Tool arguments cannot change the audience, import sources, or enable sharing.

The implementation uses newline-delimited JSON-RPC over stdio, following the [official MCP transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports) and [tool contracts](https://modelcontextprotocol.io/specification/2025-11-25/server/tools). It offers a read-only tool subset, not a proxy to arbitrary app commands.

Sentient commands automatically receive relevant sharing-enabled evidence. Their context budget is configurable in Connect a model. Budgets range from 128 to 32,768; UTF-8 bytes provide a conservative token upper bound, not a provider-specific tokenizer count. Citation framing and warnings count against the budget. Exact native relationships can expand search within the same source and project; graph expansion defaults off. No embedding service or cloud summarizer was added.

Automatic command screenshots are suppressed while a context or knowledge window is visible. A window appearing briefly during capture or context preparation invalidates those frames as well. Pending excerpts are withheld if persisted source permissions change before dispatch. These safeguards apply to Sentient's automatic attachments; a model with independently granted filesystem or computer access has its own access boundary.

## Storage, fidelity and recovery

The separate private SQLite store lives at `~/Library/Application Support/SentientOS/Context/evidence.sqlite`. Legacy SwiftData records and source keys retain their existing schema. Schema 2 of the new evidence store preserves per-file payloads/locators. Its additive v1 upgrade preserves records and source permissions; previously complete fingerprints are invalidated once so originals can repopulate per-copy provenance. Unsupported or corrupt stores are preserved and reported, never reset automatically.

Records, per-document ownership and file fingerprints commit in one SQLite transaction. Repeat imports skip unchanged completed files. Changed files are reconciled, native IDs deduplicate mirrors within a source, and explicit revisions order corrections. Removing a file restores another surviving copy's payload where applicable. Missing files mean deletion only after a successful full directory census. Partial JSONL accepts the verified prefix, retains unseen old records and never accepts a completed checkpoint. Retry rechecks incomplete files. SQLite imports use coherent read snapshots; no source database is opened for writing.

Summaries are bounded attributed excerpts rebuilt from current evidence: up to 24 per session and 12 across a project's sessions, prioritizing recorded decisions, constraints, corrections and open work. They distinguish user statements, assistant reports/proposals, tool evidence, source-provided summaries, observations and instructions. Recorded tool status/error/exit code is preserved. Corrections, dates and omitted-record notices remain visible; recency alone does not establish truth. A summary is not a claim that a model understood an entire history. Literal Markdown in imported text cannot invent graph edges.

Source data is not executable authority. Known credential patterns are rejected before persistence and checked again before sharing; shared text removes emails, phone numbers and local user/volume paths. Detection is pattern-based and cannot identify every possible secret. Sentient's generated vault, staging and context paths and marked session origins are excluded from collection to reduce feedback. Historical unmarked agent output copied elsewhere cannot always be identified.

Processing is bounded: 64 MiB text inputs, 10,000 eligible files per source scan, 100,000 rows/64 MiB text per native SQLite query, 200,000 normalized records per commit, and 50,000 records/64 MiB per retrieval. Oversize sources require narrower selections or exports. Incremental imports reparse changed files rather than maintaining fragile byte offsets; very large active files can require repeated retries. Text over 64 KiB is explicitly capped with an omission marker and original locator.

## Development and extension

`./script/build_and_run.sh --verify` builds and opens the independent context workspace with an isolated `.build/context-workspace` store and synthetic legacy vault. It does not launch production onboarding or scheduling. The Codex Run action uses this entry point. To exercise the normal app, launch its built bundle normally; the context source defaults remain off until selected.

Headless commands on the same app executable:

```text
--context-import codex --path /chosen/sessions --context-store /scratch/evidence.sqlite
--context-query "retry recovery" --project /recorded/project --budget 1024 --context-store /scratch/evidence.sqlite
--context-sources --context-store /scratch/evidence.sqlite
```

To add an adapter: add an `ImportSourceKind`, implement a bounded reader returning `ImportDocument`/`EvidenceRecord`, wire `StructuredImporter` selection and discovery only for verified paths, and add synthetic initial/repeat/edit/partial/deletion fixtures. Preserve native IDs, locators, roles and revisions; mark bounded exports `replaceExisting: false` when omission does not prove deletion. Do not bypass the shared store, permissions or projection layer.

Run `Scripts/test-context.sh`, `bash Tests/LegacyReliability/run.sh`, `bash Tests/KnowledgeGraph/run.sh`, `bash Tests/MirrorReliability/run.sh`, `python3 Tests/PipelineFlows/run.py`, `python3 Tests/FilesExtraction/run.py`, and `python3 Tests/AppFlows/run.py '<built app executable>'`. The latter launches actual headless import/query/MCP modes on temporary synthetic stores. See [evaluation results](context-evaluation.md) for scope and limitations.
