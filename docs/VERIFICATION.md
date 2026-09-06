# Structured context verification and handoff

Work is on `codex/structured-context` in the requested Sentient checkout. No commit, push, deployment, live data import, credential change or production cloud-sharing change was performed. Native session format checks read bounded live records transiently and reported counts only; all persistent test stores and exported test artifacts are synthetic.

## Capabilities and use

Open **Settings → Knowledge Sources → Manage imported sources**. Add a detected source or choose a file, then import. The independent context workspace has Sources, Evidence and Connect a model tabs. It supports retry/cancel/status, collection control, saved-evidence exclusion, removal, and separate source sharing. Search accepts project/source/time filters and a bounded context budget; citations open recorded roles, metadata and original locators. The local graph has generated, read-only project/session overviews derived from the same current permitted evidence.

The app executable's `--context-mcp` mode implements read-only stdio MCP; `--context-import`, `--context-query` and `--context-sources` provide actual headless app flows. Sentient commands use sharing-enabled evidence, and the existing encrypted mirror packages a fresh separately filtered projection. See [usage and architecture](IMPORTED_CONTEXT.md), [session support](session-source-formats.md), and [Lattice contracts](LATTICE_IMPORT.md).

## Causes fixed

| Demonstrated problem | Fix and retained evidence |
| --- | --- |
| Extraction/generation/parse failures advanced ingestion pointers; terminal SwiftData saves were swallowed. | Retryable items remain eligible; notes and progress commit together; explicit save failure rolls back. `LegacyReliability` includes first import, restart, cancellation and a real read-only store failure. |
| A failed store open deleted the old store; blanket cleanup could remove newly arrived work. | Preserve unreadable stores/WAL/SHM and surface the error; delete only unchanged consumed snapshots. Migration and restart checks preserve records and processing pointers. |
| Sequential DB/WAL copies were inconsistent; terminal SQLite step errors looked like complete queries. | Coherent read transactions/backups and checked terminal status. A concurrent checkpoint test preserves a 128-row transaction invariant across 60 snapshots. |
| Mutable imports, partial tails and rotated duplicate files could leave stale evidence or wrong provenance. | Transactional document ownership, fingerprints, revision ordering and per-owner payloads; restore surviving copies, retain incomplete tails, and recheck configuration inside commit. |
| Graph title dictionaries overwrote ambiguous names; code examples, comments and unsafe paths created misleading edges. | Resolve explicit/scoped links, abstain on ambiguous names, reject traversal/symlink changes, and exclude literal code/comments. Generated source text is escaped. |
| The visual graph used only the unchanged vault path as its refresh key. | A new scan revision triggers graph rebuilding; cancelled/older builds cannot publish, removed notes clear interactions, and highlights follow stable URLs. The actual UI changed 7→4→7 notes when an imported source was excluded and restored without restarting. |
| Project pages were only indexes; ISO strings with different offsets sorted incorrectly. | Bounded cited cross-session overviews, separate source/project identities, and actual-instant ordering. Two behavioral regressions failed before the fix. |
| Quoted/nested credentials and paths containing spaces escaped filtering. | Reject known credential-bearing records before storage, recheck sharing output and conservatively redact full local path tails. Retained artificial secret fixtures cover these cases. |
| Source revocation, disconnect or token rotation could leave an old mirror accessible or lose its cleanup key. | Serialize uploads/deletion, recheck source permissions, keep secure deletion identities across restart/rotation, fail closed on unreadable credentials, and display pending removal with retry. Tests decrypt the real archive and inspect its contents using an artificial transport. |
| File decoding failures became empty successful records; generated files beyond the excerpt cap could feed back into analysis. | Distinguish valid empty files from read/decode failures and check generated markers across the bounded original content. |
| Automatic screenshots could expose local-only evidence; sharing could change while context retrieval awaited. | Protected-window visibility generations invalidate frames, including briefly visible windows; persisted source permissions are rechecked before command dispatch. |
| Cancellation during context preparation left a command running; missing or `NOT_DONE` status could report success. | All cancelled preparation paths complete as stopped; only exact unquoted final status tokens count. Tests exercise real stream separation so stderr token-usage trailers do not hide valid final answers. |
| A small context budget reported no matching evidence even when matches existed. | Return an explicit raise-budget notice while retaining the omission count. |
| The runtime thinning script raced Xcode's framework copy. | Declare the copied dylib as a script input. The failing log had thinning before the copy; the corrected build orders the copy first and succeeds. This follows [Apple's script dependency contract](https://developer.apple.com/documentation/xcode/running-custom-scripts-during-a-build). |

## Verification

| Gate | Result |
| --- | --- |
| Original Debug app build | Passed before edits, signing disabled. |
| Shared context core | 75 XCTest cases passed, including v1→v2 preservation, transaction rollback, repeat/edit/rotation/restart, malformed/partial input, cancellation, permissions, summaries, native formats, retrieval and MCP. |
| Legacy ingestion | 17 cases passed. Original sources failed 11 initial behavioral cases. |
| Knowledge graph | 19 cases passed, including 6 new refresh/cancellation regressions. The same suite also passed with the app's actor-isolation flags. |
| Mirror | 26 cases passed, independently rereviewed. Synthetic transport/credentials only. |
| Pipeline and commands | 79 behavior groups passed: 5 controller, 7 processing, 7 scheduler, 6 proactive, 16 command, 15 capture, 18 status and 5 native stream-boundary checks. |
| File extraction | 16 cases passed. |
| Native Lattice producer roundtrip | 6 checks passed using unchanged Lattice producer/codec code, the actual Sentient app and local MCP citation lookup on temporary synthetic data. |
| Final independent review | Command/capture/status and graph/fixture boundaries reviewed; no remaining serious findings. Affected regressions rerun after fixes. |
| Final Debug and Release app builds | Both passed after the final source change, signing disabled. The independent context workspace also launched successfully. |
| Actual Debug and Release app flows | 8 checks passed on each fresh executable: initial/repeat/restart, append, partial/retry, deletion, Lattice/metrics privacy, MCP negotiation, citation permissions and source preservation. Final runs took 1.358 s and 1.335 s respectively. |

Run commands are documented next to each retained suite under `Tests/`; use `Scripts/test-context.sh` for the shared XCTest package. The toolchain on this Mac requires direct Xcode executables: `/usr/bin/xcrun` wrappers fail with an arm64/arm64e mismatch. The test script invokes XCTest explicitly because the attempted SwiftPM test driver exited successfully without running XCTest. Builds retain existing actor-isolation/bundled-runtime warnings; successful compilation alone is not treated as behavioral verification.

Final local artifacts are retained under ignored `.build/`: `context-run-build.log`, `context-release-final.log`, `app-flows-debug-final.json`, `app-flows-release-final.json`, and `lattice-producer-roundtrip-final.log`, alongside the named regression-suite logs. The final native Lattice roundtrip used the fresh Debug executable. Release skipped Sentry upload because `sentry-cli` was unavailable; no upload credentials were supplied. `git diff --check` passed.

The isolated UI checks exercised adding and importing a Lattice capsule, source status, search and citation details, exclusion/re-inclusion changing both search and graph, and synthetic source sharing toggles controlling the actual shared CLI result. Pausing collection retained one matching cited record while disabling its Import button. The final graph matched the reader after restart and changed 7→4→7 notes on exclusion/restoration without restarting. Imported project pages show their cited overview, hide Edit/Delete and offer only Reveal in Finder in their context menu; their source-access action opens the correct source window. The synthetic legacy overview now reports **Saved locally on this Mac**, and its editor cannot trigger the production mirror. The development Run action opens this isolated workspace using `.build/context-workspace`; production app processes and stores remain untouched.

## Fixed context evaluation

Five frozen queries cover session continuation, cross-session decisions, conflicting dates, project isolation and Lattice context, with a 1,024-byte conservative token budget. Final retrieval includes all **9/9 required evidence items**, with **100% fixture citation ID accuracy**, **90% strict required-set precision**, and no forbidden project hits. The extra item is an explicitly unverified assistant proposal. Source truth and downstream model-answer quality were not evaluated.

The old default tree/README context includes 0/9 required items. That baseline does **not** include a model choosing subsequent whole-file reads, so this demonstrates improved automatic context provision rather than superiority over a complete agent using the old vault. Actual per-query output and latency, graph comparison, limitations and reproduction are in [the evaluation report](context-evaluation.md). No measured result justified adding embeddings or enabling graph expansion by default.

## Preservation, privacy and remaining access limits

The new private SQLite evidence store is separate from legacy SwiftData. Its additive schema-2 upgrade preserves existing payloads and permissions and invalidates old complete fingerprints once to rebuild per-copy provenance. Unknown/corrupt stores are preserved. Removing an imported source deletes only Sentient's saved evidence; disabling collection keeps it. Summaries and graph files are rebuildable derivatives, not independent evidence.

All new sources start with sharing off. Personal metrics stay local unless their source is explicitly shared. `--local-context` deliberately grants a connected local process access to all locally included sources. Pattern-based secret filtering is not a universal secret detector; these controls govern Sentient's outputs and cannot restrict an independently authorized model's filesystem/computer access. Remote deletion requires available credentials/network and remains visibly pending on failure; already consumed context cannot be recalled.

Verified native source readers: Codex rollout/projected history, Claude Code project/subagent transcripts, Hermes schema 30, and OpenClaw schema 19/legacy exports. Lattice Workbench capsule v1 has a supported export path. **Lattice 1.0 (11) has no native personal-metrics JSON/CSV exporter**: the selected snapshot-copy reader is compatibility mode, and generic metrics CSV is a separate documented interchange contract. Claude Desktop/proprietary ChatGPT stores, opaque/encrypted contents, metadata-only histories and unknown future schemas have no verified adapter here. Live cloud model/hosted MCP behavior and signed distribution are unverified; tests use the real local app protocol and synthetic cloud boundaries.
