# Legacy ingestion reliability regressions

Run from the repository root on an Apple Silicon Mac:

```sh
bash Tests/LegacyReliability/run.sh
# Or run one named case:
bash Tests/LegacyReliability/run.sh initial_resume
```

The script calls Xcode's `swiftc` directly with an explicit macOS SDK. It defaults to
`/Applications/Xcode-beta.app/Contents/Developer`; set `DEVELOPER_DIR` to another installed Xcode
developer directory when needed. It creates and removes a temporary CLI build directory.

These tests are **retained** outside `Self Tests - Temp/` and outside the synchronized app source
group. They compile the actual `CycleStore`, `IterativeRun`, `Triage`, `PIIScan`, `SQLiteDB`, and
their value types. The native inference engine is replaced at its boundary with deterministic
synthetic replies/failures; telemetry, UI, and global app services are inert test stubs. All SQLite
and SwiftData files are temporary synthetic stores. No model download, app launch, live source,
Application Support store, or network service is used. The shared-store test explicitly redirects
the test-only support path before opening it.

| Case | Protected behavior |
| --- | --- |
| `extraction_retry` | A failed read leaves its item eligible; independent buckets progress; reopening recovers the backlog exactly once. |
| `generation_retry` | A failed model generation cannot advance past an unsummarized item. |
| `parse_retry` | Unreadable model output is a surfaced, retryable failure, not consumed junk. |
| `initial_resume` | A failed first-run item retains the last committed floor; reopening resumes without duplicates. |
| `cancel_does_not_commit` | Cancellation after generation produces no note, pointer, or successful-work count. |
| `junk_sensitive_zero_trace` | Genuine junk and sensitive verdicts advance progress while storing no note. |
| `save_failure_stops_bucket` | A real read-only SwiftData save failure rolls back, stops the bucket, and recovers after writable reopen. |
| `replace_failure_preserves_notes` | A failed replacement import retains the previous durable notes. |
| `wipe_failure_preserves_notes` | A failed strict wipe throws and retains durable notes; a successful wipe preserves processing pointers. |
| `wipe_only_consumed_snapshot` | Cloud cleanup removes only the exact consumed snapshots; newly imported, revised, and recreated notes survive. |
| `import_idempotent` | Repeated imports update one logical note, retain original dates, and preserve processing pointers. |
| `chat_identity` | Distinct imported windows with reused source IDs have distinct UI identities. |
| `shared_open_preserves_store` | An unreadable store and its WAL/SHM remain intact; the disabled store refuses writes and analysis surfaces the error. |
| `sqlite_step_error` | An error after the first query row throws instead of accepting a partial result. |
| `sqlite_rejects_invalid_snapshot` | An invalid source fails snapshot creation and leaves no temporary copy behind. |
| `sqlite_wal_snapshot` | A standalone private snapshot contains committed WAL rows and remains unchanged after source writes/checkpointing. |
| `sqlite_concurrent_checkpoint` | Sixty snapshots retain a 128-row transaction invariant while a separate connection writes and truncates its WAL. |

On 2026-09-06, the first run against the original production sources produced 11 behavioral
failures; `junk_sensitive_zero_trace` and `sqlite_wal_snapshot` already passed. After the fixes,
all 17 cases pass. SwiftData intentionally emits local framework diagnostics for the synthetic
read-only and unreadable-store cases; the process exits nonzero only for test failures.

The harness verifies persistence and orchestration behavior. It does not exercise the GPU runtime,
real application databases or access grants, cloud connectors, or SwiftUI presentation. Build and
UI checks for the assembled app remain separate.
