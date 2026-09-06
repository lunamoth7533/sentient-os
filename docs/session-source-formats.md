# Session source formats verified on 2026-09-06

This audit inspected installed schemas, source code, and bounded structural samples. No private
message bodies, credentials, or real transcripts were copied into fixtures or this document.
`SessionAdapters.swift` is shared by the macOS target and the standalone context test package.

## Source selection

| Source | Preferred input | Additional explicit inputs | Exclude from automatic discovery |
| --- | --- | --- | --- |
| Codex CLI / desktop | `~/.codex/sessions/**/*.jsonl`, `archived_sessions/**/*.jsonl` | `thread_history_1.sqlite` projected history | `history.jsonl`, `session_index.jsonl`, `state_5.sqlite`, logs, queues, memories, browser state |
| Claude Code | `~/.claude/projects/**/*.jsonl`, including `subagents/agent-*.jsonl` | A copied native transcript | Prompt history, tool-result spill files as separate conversations, file-history snapshots, settings, session/UI metadata |
| Hermes | `~/.hermes/state.db` | Whole-session JSON/JSONL `sessions export` output | Routing `sessions.json`, prompt-only exports, obsolete transcript mirrors when the canonical DB exists |
| OpenClaw | `~/.openclaw/agents/*/agent/openclaw-agent.sqlite` | Legacy session JSONL, explicit `session-branch.json` export | Generation-lock databases, `sessions.json`, trajectory/event mirrors, checkpoint/deleted archives as duplicate live conversations |

Prefer one canonical representation per source. In particular, do not auto-import Codex's projected
database alongside its rollouts. Native external-agent Codex rollouts may also mirror conversations
owned by Hermes or OpenClaw; preserve origin metadata instead of assuming every Codex model call
was started in the Codex UI. A selected copied export remains its own file-owned import.

The installed Codex binary is 0.153.4; observed rollouts also include 0.151.x and 0.153.3. Claude Code's
installed executable is 2.1.261, with sampled transcripts written by 2.1.251/2.1.259. Hermes's installed
and live SQLite schema is 30. OpenClaw's live main-agent schema is 19, recording app version 2026.9.1.
The OpenClaw main database contains active transcript events; no native live JSONL transcripts were
present. The second locally present agent database was empty.

## Codex

Rollout envelopes have `timestamp`, `type`, `payload`, and, in current files, `ordinal`.
`session_meta.payload` supplies native `id`, optional `session_id`, `cwd`, `originator`, `source`,
`model_provider`, `cli_version`, `history_mode`, `git`, `parent_thread_id`, `forked_from_id`, and agent
metadata. `source` may be a string or a nested subagent/spawn object. `source: vscode` does not by
itself identify the desktop app: observed `originator` values include Codex Desktop,
codex_work_desktop, codex_vscode, codex-tui, codex_exec, and openclaw.

`turn_context.payload` carries `turn_id`, `cwd`, `model`, and per-turn configuration. Carry this
metadata forward within the transcript instead of assigning one guessed model to all messages.

`response_item.payload` uses Responses-style message content (`input_text`/`output_text`), roles,
function/custom tool calls (`call_id`, `name`, `arguments`/`input`), tool outputs (`call_id`, `output`),
reasoning summaries, and inter-agent envelopes. Encrypted content and opaque signatures are not
readable text. `event_msg` contains lifecycle and usage events as well as `item_completed.item`
projections. The latter use native item IDs with UserMessage, AgentMessage, Reasoning,
CommandExecution, FileChange, SubAgentActivity, and Extension records. Legacy user/agent message
events can mirror Responses messages. The adapter prefers completed projections and suppresses
wire/event mirrors within the same turn; repeated human text in separate turns remains separate.

`thread_history_1.sqlite.thread_items` has `(thread_id, turn_id, item_id)` as its key, `item_json`,
`item_type`, `rollout_ordinal`, `updated_at_ordinal`, and `created_at_ms`. It is a mutable UI history
projection. Item types use camelCase (`agentMessage`, `commandExecution`, `mcpToolCall`, `webSearch`,
etc.). The metadata index `state_5.sqlite.threads` contains `rollout_path`, source/model/provider,
cwd/git/project/name/archive fields, but is not the message store. The adapter does not read an
unselected sibling metadata database, so a standalone projected DB can lack model/origin/project
attribution. Unknown projected/response item types mark the document incomplete.

Rollout ordinals and native item IDs are distinct from byte offsets. Archive/unarchive moves files;
rollbacks and compaction introduce source state boundaries; projected items can be updated in place.
File signatures and complete-session reconciliation are required, not just an append cursor.

Official sources fetched before use:

- [OpenAI App Server documentation](https://learn.chatgpt.com/docs/app-server): `thread/read` reads stored history without resuming; item pagination is experimental. Archive and rollback semantics are documented here.
- [Official originator implementation](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/default_client.rs): `CODEX_INTERNAL_ORIGINATOR_OVERRIDE` is checked before supplied/default originator. Its constant was also found in the installed binary.
- [Official TypeScript SDK subprocess environment](https://github.com/openai/codex/blob/main/sdk/typescript/src/exec.ts): uses that internal originator variable. Treat it as compatibility behavior, not a permanent public setting.

## Claude Code

Message envelopes carry `type`, `uuid`, `parentUuid`, `sessionId`, `timestamp`, `cwd`, `gitBranch`,
`entrypoint`, `version`, and optional `isSidechain`/`agentId`. `message.role` and `message.content`
contain the actual message. Assistant `message.model` is recorded without inventing a provider:
the same model name may be served through different providers.

One API `message.id` can span multiple transcript rows. The samples contained distinct UUIDs with
`apiBlockIndex` 0/1/2/3 for thinking, text, and multiple tool-use blocks. Deduplicating by API message
ID would lose content; the adapter uses transcript UUID plus block position. Tool calls are
`tool_use` blocks (`id`, `name`, `input`), and their results are `tool_result` blocks inside a **user**
envelope (`tool_use_id`, `content`, `is_error`). These results are tool evidence, not human statements.
`toolUseResult` duplicates rendered content and is not imported a second time. Compaction has
`type: system`, `subtype: compact_boundary`, and `compactMetadata`.

Parent UUID links preserve branches and sidechains without flattening their origin. Binary
attachments remain explicit unavailable-content records. Large tool-output spill files are not
recursively opened through transcript-provided paths. Concurrent writers can interleave transcript
rows; UUID upserts and physical line provenance are retained.

Official sources fetched: [sessions](https://code.claude.com/docs/en/sessions),
[application data](https://code.claude.com/docs/en/claude-directory),
[subagent transcript layout](https://code.claude.com/docs/en/sub-agents).
These distinguish CLI history from the desktop/web histories, describe optional persistence and
retention, and document plain-text export. No unverified desktop cache format is parsed.

## Hermes

Installed source references under `~/.hermes/hermes-agent/`:

- `hermes_state_common.py:279`: sessions schema; native ID, source platform, model/config,
  parent ID, start/end times, cwd/git roots, profile, routing, archive, and rewind metadata.
- `hermes_state_common.py:342`: messages schema; native integer ID, session ID, role/content,
  tool IDs/calls/name, timestamp, reasoning fields, active/compacted/summary flags, display metadata.
- `hermes_state.py:1216`, `hermes_state_messages.py:111`: structured content uses a literal NUL
  followed by `json:` and encoded JSON. Ordinary JSON-looking strings remain prose.
- `hermes_state_messages.py:508`: in-place compaction archives original rows and clones a kept tail.
- `hermes_state_messages.py:587`: display deduplication uses role/content/timestamp/tool fields,
  preferring an active row and then the newest ID.
- `hermes_state_messages.py:628`: ordering is message ID, never timestamp; display includes
  `active=1 OR compacted=1`, while inactive non-compacted rows were rewound or replaced.
- `hermes_cli/session_export.py:40`: default JSONL export is one whole session object per line,
  not one message per line. `/save` snapshots and routing mirrors are different artifacts.

The adapter imports display history, preserves source compaction summaries, omits withdrawn rows,
decodes the sentinel with byte-length-aware SQLite reads, and links tool results to their calls.
`api_content` and Codex replay sidecars are wire/context copies, not independent human statements.
`model_config.provider` is distinct from the source platform. Parent IDs plus `_branched_from`,
`_delegate_from`, and `_reset_from` markers describe lineage; compression alone is not a new
human conversation. Full reparsing detects updates to flags/content and carried-tail generations.

Official sources fetched: [session storage](https://hermes-agent.nousresearch.com/docs/developer-guide/session-storage),
[sessions and exports](https://hermes-agent.nousresearch.com/docs/user-guide/sessions).
The developer page's displayed schema-version number lagged the installed source; live schema
inspection, not that number, controls capability detection.

## OpenClaw

The active per-agent database stores:

- `session_nodes`: `session_key`, `current_session_id`, mutable `entry_json`, project/parent/fork metadata.
- `session_windows`: native `session_id`, session key, previous session, model/provider, parent key.
- `transcript_events`: `(session_id, seq)` key, `event_json`, creation time.
- `transcript_event_identities`: native event IDs, parent IDs and idempotency keys.
- `session_transcript_index_state`: current leaf and `needs_rebuild`.
- `session_transcript_active_events`: active branch/context projection.
- `transcript_rewrite_watermarks`: generation for detecting in-place replacements.

Events retain the JSONL structure: a `session` header (`version`, `id`, `timestamp`, `cwd`) and
entries with `id`, `parentId`, `timestamp`, `type`. Message roles are user, assistant and toolResult.
Assistant messages have `provider`, `model`, `api`, usage, and content blocks. Calls use `toolCall`
with `id`, `name`, `arguments`/`input`; results have `toolCallId`, `toolName`, `isError` and text/content
aliases. The native `toolResult` message envelope's `isError` and `toolName` are preserved even when
its content blocks are plain text; absent error flags remain unknown. Only one alias is rendered.
`model_change`, `compaction` and `branch_summary` retain model
and summary boundaries. The explicit current leaf excludes withdrawn branches from live evidence;
a dirty branch index defers the document instead of using stale branch state.

Installed code under `~/.openclaw/tools/node-v24.19.0/lib/node_modules/openclaw/dist/`:
`session-accessor.sqlite-transcript-store-DV0WFe1a.js:919` exposes checkpoint reads for rewrite
detection; `:1288` rewrites existing JSON rows and rotates generation. `export-trajectory-NqlGHDdB.js:879`
writes `session-branch.json` as `{header, leafId, entries}`. Session sequence numbers are not a
permanent append-only import cursor. The adapter reparses the captured session to see rewrites.

Official sources fetched: [session storage/compaction](https://docs.openclaw.ai/reference/session-management-compaction),
[trajectory exports](https://docs.openclaw.ai/tools/trajectory). Runtime trajectory events duplicate
transcript material and have their own capture limits. Meeting transcript exports are a separate
feature and are not inferred to be agent sessions.

## Snapshot and completeness rules

Existing active WAL databases are opened with `SQLITE_OPEN_READONLY`, query-only mode and one read
transaction. Native schema/migration APIs, auth tables, FTS/vector tables, and source checkpointing
are not invoked. A WAL-mode file with no sidecars reproduced a macOS SQLite 3.54 `SQLITE_CANTOPEN`
even though its main file was readable. For that closed-file layout, the adapter creates a private
snapshot, verifies unchanged file identity/size/mtime and SHA-256 plus absence of WAL/journal before
and after copying, and allows sidecars only for the private copy. The snapshot is removed on close.
It never treats a main-file-only copy as sufficient when an active WAL exists.

Limits are explicit: 1 GiB source database, 64 MiB selected text across a snapshot, 8 MiB per text
field, and 100,000 rows per query. Cancellation, read/UTF-8 failures, unstable copies, missing active
WAL indexes, malformed JSONL tails, unknown formats, and unsupported evidence types cannot authorize
deletions. A malformed JSONL tail keeps its verified prefix. Locators are source path plus physical
line, or native SQLite table/session/item key. Imports never follow tool-supplied file paths.

Sentient's explicit origin values and exact `.sentientos-vault-staging-*`,
`sentient-proactive-judge`, and `Sentient OS - Knowledge Base` cwd components are marked
`origin=sentient` for the import policy to reject. A user coding in the `sentient-os` repository is
not classified as generated merely because of the repository name.

Synthetic regression fixtures are under `Tests/Fixtures/Sessions`; SQLite fixtures are constructed
in unique test directories. The test suite covers mirror suppression, split blocks, tool attribution,
compaction/rewind, closed and active WAL layouts, native rewrite identities, branch-index races,
explicit exports, generated-source marking, and incomplete inputs. No test reads a live session store.

`native_record_id` and `call_id` retain source identities. Native tool references resolve to their
same-session evidence record IDs, and a parent message containing multiple content blocks resolves
to those block IDs. Unresolved external references remain recorded without fabricating a target.
Synthetic boundary tests also cover 8,000 native messages with a same-ID correction and malformed
tail, sparse input over the 64 MiB cap, and cancellation preserving prior evidence/checkpoints.

The privacy review reproduced and fixed double-quoted/nested JSON credential assignments escaping
the encoded-record filter, and local path suffixes leaking when volume or user names contained
spaces. Filtering checks native fields plus encoded metadata and rechecks shared text. Shared
credential-bearing lines and complete PEM blocks are withheld; unquoted local path tails are
removed conservatively through the end of their line. All privacy fixtures contain artificial values.
