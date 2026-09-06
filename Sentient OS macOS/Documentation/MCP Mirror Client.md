# MCP Mirror Client — the app side of the hosted mirror

`MirrorClient.swift` mirrors the local vault to our one persistent backend (the FastMCP
server at `mcp.sentient-os.ai`, Arch §8) so the user's ChatGPT/Claude can read it over MCP.
Opt-in, opt-out, one-click delete. The Mac's vault is always canonical; the mirror is a
disposable copy — and **encrypted at rest**: the server only ever stores ciphertext.

## API

```swift
let mirror = MirrorClient.shared
await mirror.isEnabled                 // is mirroring ON? (the toggle flag — NOT just "a password exists")
let url = try mirror.enable()          // opt in → mints the password if absent → returns the share URL
await mirror.shareURL                  // the "Copy MCP Link" value, or nil
try await mirror.push()                // zip + ENCRYPT the vault, replace the mirror (call after any change)
let s = try await mirror.stats()       // {notesRead24h, toolCalls24h, lastAccess} for "Give AIs Knowledge"
try await mirror.deleteRemote()        // delete the cloud copy (keeps the password → stable URL)
try await mirror.contextChanged()      // remove a stale hosted projection after persisted source changes
MirrorClient.remoteRemovalPending     // deletion/uncertain upload needs acknowledgement or retry
await mirror.disable()                 // opt out: flip OFF + delete remote, but KEEP the password (stable link)
let u2 = try await mirror.regenerateToken()  // leak remediation: mint a NEW password, delete old copy, re-push
MirrorClient.destroyKeychainIdentity() // uninstall only: wipe the Keychain password (+ legacy token)
```

## The single secret: one password, no accounts

No accounts, ever (Invariant 4). Each vault has ONE minted **password** — the root secret, 18
random bytes → base64url (24 chars), in the Keychain (`mcp.mirror.password`). Everything is
derived from it:

- **`userID` = base64url(HKDF-SHA256(password))[:20]** — a public, non-secret label. Because the
  userID is a one-way function of the password, the server can verify *statelessly* that a URL's
  userID belongs to its password (`verify_binding`, constant-time). That binding authorizes MCP
  reads AND push/delete/stats — no separate credential, no stored secret on the server.
- **`encKey` = HKDF-SHA256(password)** (a different HKDF `info` label) — the AES-256 key that
  encrypts the vault before upload.

The share URL is **`mcp.sentient-os.ai/u_<userID>/p_<password>/mcp`**. Tradeoff (founder-decided):
anyone who sees the full URL can also overwrite/delete the vault, and the server decrypts it for
the instant of a request; mitigated by no accounts, the 30-day lease, one-click delete, encryption
at rest, and the vault being PII-stripped.

**Identity ≠ on/off.** The password is the durable identity: minted once and kept across OFF→ON, so
the share URL is **stable** (it's what the user pasted into ChatGPT/Claude — toggling must never
reroll it and break their connectors). Whether mirroring is currently ON is a *separate* flag
(`mcp.mirror.enabled`, UserDefaults) that `isEnabled` reads and the toggle flips — NOT "does a
password exist". `disable()` flips OFF and deletes the cloud copy but keeps the password.

A lost password is a non-event: mint a new one (`regenerateToken`), re-push; the orphaned cloud
copy expires on its 30-day lease. `regenerateToken` mints + persists the NEW password BEFORE
deleting the old copy, so a mint/write failure preserves the existing identity and hosted copy.
An old identity awaiting removal stays in a Keychain cleanup queue until deletion succeeds.

⚠️ **Never mint a weak key.** `mintPassword` throws (rather than returns) if `SecRandomCopyBytes`
fails — an all-zero buffer would be a predictable identity AND a predictable encryption key.
`Keychain.set` returns success/failure so `enable()` never hands out a URL for a password that
didn't persist.

## Encryption (MirrorCrypto — the client half of the envelope)

`push()` encrypts the whole vault zip with **AES-256-GCM** before upload; the server stores only
ciphertext (`crypto.py` is the byte-for-byte server twin). The envelope:

```
encKey = HKDF-SHA256(ikm: password-utf8, salt: SALT, info: INFO_KEY, len: 32)   → AES-256 key
userID = base64url(HKDF-SHA256(password-utf8, SALT, INFO_UID, 32))[:20]         (public label)
blob   = [1 byte version=1] + AES-GCM.combined(nonce(12) ‖ ciphertext ‖ tag(16)), AAD = userID
```

The **userID is the AAD**, so a blob can't be replayed under another identity. The version byte
leaves room to migrate the scheme. `MirrorCrypto` and the server's `crypto.py` MUST agree on every
constant (SALT, both info labels, UID length, layout) or nothing decrypts. ⚠️ On an AES-GCM seal
failure the code throws `encryptionFailed` — it NEVER falls back to uploading plaintext.

*Verified 2026-07-11:* a blob sealed by the real CryptoKit path decrypts byte-for-byte in the
server's Python, and both sides derive an identical userID from the same password.

## Sync

Whole-vault **encrypted-blob replace**: `push()` requires the enabled flag, stages the existing
`VaultGenerator.vaultRoot` content and fresh `ContextProjection.notes(store:, audience: .shared)`
under `Imported`, encrypts the zip, and `POST`s the ciphertext. New imported content is never
persisted into the legacy vault. Staging directories are private (0700; files 0600) and removed
on success or failure. The archive rejects links, unsupported/unreadable files, changed files,
path traversal, and collisions with existing legacy notes; it enforces the server's file/size
limits before uploading. Shared imports can form a mirror even before a legacy vault exists.

The zip is built by shelling to `/usr/bin/zip` from **inside** the disposable staging directory
(`zip -r -X -q … .`) so entries are **root-relative**
(`README.md`, `Career/Job.md`) — the server's contract. (We deliberately do *not* use
`NSFileCoordinator.forUploading`: it wraps everything under the vault folder name, which breaks the
README-portrait bundling in `get_structure`. The server also defensively unwraps a lone wrapper dir,
so old clients still sync correctly.)

**When pushes happen.** `VaultCloud.create()`/`update()` mark the vault dirty
(`VaultActivity.vaultDirty`, persisted); the actual pushes ride:
- **every full cycle** — `ProactiveCycle` calls `VaultCloud.pushIfDirty()` after the
  knowledge-base step (Analyze Now real mode + the 3am run),
- **Knowledge-editor changes** — `VaultActivity.markChanged()` debounces ONE push 30s after the
  last save/create/delete (a spree coalesces; the timer survives window close),
- **app launch** — a `pushIfDirty()` catch-up (a `.task` on the main window) for a push a quit
  interrupted, and
- the dev **MCP SYNC** button — a forced push.

`pushIfDirty()` pushes iff the mirror is enabled AND the vault is dirty, clearing the flag only on
success — a failed push stays pending and retries on the next trigger. ⚠️ A non-HTTP response
(captive portal / transparent proxy) is treated as failure, never success, so a never-synced vault
is never marked clean.

**Permission changes and deletion ordering.** Imported sharing permissions are read from the
evidence store for each archive and checked again before and after the upload. If the shared
projection changes during POST, the client deletes the captured copy before a bounded fresh retry.
If enable/disable, explicit deletion, or identity rotation invalidates the request, it deletes the
captured copy and reports failure. All POST/DELETE requests share one queue across actor awaits,
so a late POST cannot recreate a copy deleted by another operation. Cancellation or a transport
failure can still mean the server accepted the POST; an uncancelled cleanup request removes it.

`contextChanged()` removes a stale hosted projection promptly after source changes, with the
normal dirty-vault debounce rebuilding current content. A local-only change with an identical
shared projection causes no remote request. Removal failures remain pending and keep the required
identities in the Keychain for restart/retry. `lastPush` is cleared on invalidation; UI must report
remote removal as pending until acknowledged. Local exclusion is immediate, but offline deletion
cannot promise a hosted copy or a remote consumer's cached response has already disappeared.
The disconnect window keeps a pending-removal notice and retry action visible after local opt-out.
An unreadable credential clears the old success stamp and retains a durable removal request until
Keychain access returns; it is never interpreted as an already-removed copy.

## Turning the mirror on (today)

The user-facing opt-in is **Settings → Give AIs Knowledge** (`Views/Settings/ShareKnowledgePane.swift`,
renamed 2026-07-13 from "Connect AIs to Knowledge"/`YourAIsPane`)
and the guided **`ConnectAIsView`** window (opened by the pane's CTA and the home popover's door).
The pane: the value/privacy story, the share toggle (ON = `enable()` + a first push; OFF = a
confirm dialog, then `disable()`), and live `stats()` activity. The window (rebuilt 2026-07-13):
per-AI video tabs (ChatGPT's three steps: developer mode → New Plugin + link → instructions;
Claude's two; a text-only Other AIs), deep-link pills straight into each AI's settings screens,
the masked link + Copy, Copy-the-instructions (`MirrorClient.systemPrompt` — rewritten 2026-07-13
to the softer get_structure/get_files coaching), the "what do you know about me?" closer — plus
the same sharing lifecycle (a glowing connect CTA when off; an MCP ON/OFF pill behind the confirm
when on). The masked link (`MirrorClient.maskedURL`) shows the public userID but masks the password
to its first 4 chars. **Regenerate is backend-only** (`regenerateToken()` stays as the support
remediation if a link leaks; there's no UI button — it bricks every connector the user set up).

The **DEV TOOLS** panel (`DevToolsView`) keeps its own controls while the mirror is ON: MCP TOGGLE,
Copy MCP Link, Copy System Prompt, MCP SYNC (force-push), and Stats (under More). Use these to
dogfood end-to-end sync on a real INITIAL/ITERATIVE cloud run.

## Keychain

`MirrorClient` is the app's first Keychain user; the small `Keychain` enum at the bottom of the
file is the shared generic-password helper (service `ai.sentient-os.app`, accessible
`kSecAttrAccessibleAfterFirstUnlock`). Updates use `SecItemUpdate`, preserving the old secret on
failure. The cleanup queue is stored at `mcp.mirror.pendingDeletions` in the Keychain; no password
is stored in UserDefaults or logs. Uninstall is the ONE caller that deletes the password
(`destroyKeychainIdentity`, after `deleteRemote`) — everywhere else it survives by design so the
pasted share URL outlives resets and off→on.

## Retained local tests

Run `bash Tests/MirrorReliability/run.sh` from the repository root. The twenty-six behavioral tests
compile the production client, archive, crypto, evidence store, and shared projection. They use
only synthetic temporary files/stores, isolated defaults, a fake credential boundary, and an
in-memory transport. No app launch, real Keychain access, or live mirror request is made. The
test README records the initial nine behavioral failures and final coverage.

## The server — the contract this client relies on

The backend lives in the private `sentient-os-mcp` repo (AGPL license inside; goes public at
launch); this section records the contract + hosting so app-side work doesn't need that repo open.

- **Hosting: Render.** Service `sentient-os-mcp` (Python, one uvicorn worker), 1 GB persistent disk
  at `/var/data`, auto-deploys on push to `main`. DNS: `CNAME mcp → …onrender.com` (managed on
  Vercel, Jesai's account); Render-issued TLS. (Deliberately NOT Railway/Heroku — reliability /
  ephemeral-filesystem reasons.)
- **One multi-tenant FastAPI + FastMCP app.** A `TokenRouter` front door routes
  `/u_<userID>/p_<password>/mcp` to the MCP app (stashing the userID + password in scope state) and
  everything else to REST. Stateless — every request self-contained. On disk:
  `vaults/<userID>/vault.enc` = the ONE encrypted blob (ciphertext only) · `meta/<userID>/` = lease
  + access log (deleted with the vault). **The plaintext markdown never touches the disk:** the
  server decrypts the blob IN MEMORY per request.
- **Every endpoint verifies the binding.** `verify_binding(userID, password)` (constant-time) gates
  MCP reads, push, delete, and stats. A bad binding / bad password / missing vault all return the
  SAME neutral response (404 on REST, "No vault exists" on MCP) — nothing distinguishes them, so a
  guessed userID leaks nothing.
- **Two MCP tools only.** `get_structure` returns the folder tree PLUS the README portrait in the
  same response (one round-trip answers "what do you know about me?"; the description names the
  trigger phrases and forbids the "I have no memory" disclaimer). `get_files` takes a **JSON array
  of paths** (note titles contain commas — a comma-separated string literally couldn't fetch them);
  strings are still accepted defensively with greedy comma-reassembly. Caps: 50 paths/call, 256 KB
  response; not-found errors carry "did you mean…" matches.
- **Sync endpoints.** `POST /u_<uid>/p_<pw>/vault` (the encrypted blob) decrypts in memory,
  validates the DECRYPTED zip (see guards), stores the CIPHERTEXT via staging + atomic rename, and
  renews the **30-day lease**. `DELETE` is the one-click nuke (idempotent). An hourly sweeper deletes
  expired vaults — AND any dir without a `vault.enc` (a pre-encryption plaintext vault or a partial
  write), lease-independent, so legacy at-rest plaintext is reaped on sight.
- **Zip guards (on the decrypted content):** 60 MB encrypted upload / 200 MB unpacked (bounded on
  ACTUAL extracted bytes, not the zip's self-declared sizes — closes the zip-bomb hole) / 5,000
  files, path-traversal rejection, and UTF-8 filename recovery (macOS `zip` omits the UTF-8 flag —
  em-dashes arrived as mojibake before this).
- **Abuse guards:** ~60 tool-calls/min (burst 30), ~20 pushes/hour (burst 5), per-userID token
  buckets. *(Verified enforcing, 2026-07-11.)*
- **Stats:** every tool call appends one JSONL line with **salted-hashed** note paths (never the
  clear titles — the vault is encrypted at rest, so the log must not leak titles either). `GET
  /u_<uid>/p_<pw>/stats` → `{notes_read_24h, tool_calls_24h, last_access}`.
- **⚠️ SECURITY INVARIANT — the password rides in the URL, so request paths must NEVER be logged.**
  The uvicorn access log writes full paths; it is disabled **at import time** in `server.py`
  (`logging.getLogger("uvicorn.access").disabled = True`), guarded by a regression test. This is
  load-bearing: the encryption protects the disk, not a logged URL. (⚠️ At *import*, not in
  `__main__` — Render's `uvicorn server:app` launch never executes a `__main__` block, a gap the
  2026-07-11 hardening pass closed. Belt-and-suspenders: the Render start command also carries
  `--no-access-log`.)
- **Field lessons (real ChatGPT/Claude sessions):** clients lazy-load connector tools behind a
  search gate — naming the connector in the prompt ("check my Sentient knowledge — …") reliably
  triggers it, so onboarding/demo copy must teach that phrasing. Schemas permit what descriptions
  only request — make every accepted input shape unbreakable. In-note guardrails survive the round
  trip (a connected Claude obeyed an in-note "do not assert X") — a real control surface.
- **Tests:** a pytest suite (17 checks: encrypted round-trip, at-rest ciphertext-only, binding,
  zip-bomb, traversal, sweeper incl. legacy-plaintext reap, comma-title handling) + a 14-check live
  e2e contract script that runs against local AND prod. *(All green against production, 2026-07-11.)*
  Still to verify end-to-end: real ChatGPT + both mobile apps.

## Not built here (downstream)

The onboarding MCP opt-in moment (the no-account/password/30-day-lease pitch after the first
knowledge base exists) and post-launch proper OAuth. The Settings pane's "unreadable ciphertext"
promise is backed by real AES-256-GCM at rest (zero-access: the server stores only ciphertext and
holds no key of its own).
