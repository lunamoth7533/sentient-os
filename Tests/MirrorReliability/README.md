# Isolated mirror regressions

Run from the repository root on an Apple Silicon Mac:

```sh
bash Tests/MirrorReliability/run.sh
# Or select one case:
bash Tests/MirrorReliability/run.sh revoke_during_upload
```

The script uses Xcode's direct Swift compiler with an explicit macOS SDK, matching the app's
MainActor default. `DEVELOPER_DIR` can select another installed Xcode. The build directory is
temporary and removed on exit. Tests are retained outside `Self Tests - Temp/` and the app target.

These tests compile the actual `MirrorClient`, `MirrorCrypto`, `MirrorArchive`, `EvidenceStore`,
and `ContextProjection`. Only external boundaries are substituted: an isolated UserDefaults suite,
in-memory credential storage, inert telemetry, a synthetic vault/store, and an actor transport
that can suspend uploads or reject deletions. **No real Keychain, user source, app launch, network
socket, or live mirror is used.** CryptoKit encrypts the real archive; tests decrypt it using the
existing protocol constants and inspect its extracted files.

| Case | Protected behavior |
| --- | --- |
| `disabled_push` | A retained password does not authorize uploads while the mirror is off. |
| `disabled_context_is_inert` | Disabled context-window activity accesses neither credentials nor network. |
| `shared_projection` | The archive includes fresh explicitly shared evidence under Imported, excludes local-only evidence, and leaves the legacy vault unchanged. |
| `revoke_during_upload` | A permission change during POST removes the captured archive before retrying. |
| `disable_during_upload` | Serialized mutations prevent a late POST recreating a deleted cloud copy. |
| `cancelled_upload` | Cancellation cannot stamp success or leave an accepted copy hosted. |
| `disabled_stats` | Disabled mirroring performs no remote stats read. |
| `symlink_boundary` | A linked file outside the vault fails packaging before upload. |
| `projection_read_failure` | Missing current permission data fails closed. |
| `legacy_collision` | Imported path collisions surface a failure and preserve the existing user note. |
| `encryption_contract` | Version 1, HKDF parameters, userID length, AAD, and root-relative ZIP behavior remain compatible. |
| `idle_permission_revocation` | Source removal invalidates an already hosted projection without waiting for another upload. |
| `local_change_keeps_remote` | A local-only change leaves an identical shared projection and sync stamp alone. |
| `revocation_retry_after_restart` | Failed deletion remains visibly pending and retains cleanup credentials for a new client instance. |
| `uncertain_upload_cleanup` | A connection error after server acceptance triggers deletion and reports failure. |
| `rotate_during_upload` | The old identity is removed before a newly persisted identity uploads. |
| `failed_rotation_preserves_identity` | A failed credential write preserves the old identity and cloud copy. |
| `private_temporary_archive` | Temporary folders are 0700, files are 0600, and cleanup removes plaintext. |
| `invalid_imported_path` | Traversal, absolute, and backslash paths are rejected. |
| `imported_only_vault` | Explicitly shared imports can be mirrored without creating a legacy vault. |
| `unavailable_password_revocation` | An unreadable primary key cannot silently acknowledge revocation; pending removal survives restart and retries when the key is readable. |
| `unavailable_password_disable` | Local opt-out remains immediate while credential-dependent remote removal stays pending and recoverable. |
| `repeated_rotation_retries_old_identity` | A second rotation after restart retains and removes all earlier pending identities. |
| `unreadable_cleanup_queue` | An inaccessible cleanup queue is preserved even when a crash prevented the defaults flag from being written. |
| `unavailable_password_rotation` | Rotation does not overwrite an unreadable primary identity before its old copy can be revoked. |
| `reenable_unavailable_password` | Re-enable preserves the unreadable identity required by a prior failed opt-out and leaves local sharing off. |

On 2026-09-06, the first ten tests were run against the original behavior after only injecting
the external boundaries. Nine failed behaviorally; the encryption compatibility control passed.
Independent review reproduced credential-unavailability and repeated-rotation failures before
their fixes; additional retained RED cases covered the inaccessible cleanup queue.
The final retained suite passes all 26 cases. These tests cover local archive and client ordering;
they do not prove real network availability, hosted server behavior, Keychain access policy, or
remote consumer cache eviction. A server-unreachable deletion remains pending, with the existing
30-day lease as the server-side fallback.
