# Native Lattice producer roundtrip

Run from the Sentient repository root with an existing Debug app build:

```sh
bash Tests/LatticeProducer/run.sh
```

Optional environment variables select `LATTICE_ROOT`, `SENTIENT_BINARY`, `DEVELOPER_DIR`, or
`PYTHON_BIN`. Defaults use the sibling Lattice checkout, Sentient's `.build/baseline` Debug app,
Xcode-beta, and Homebrew Python. The script does not invoke Xcode or modify Lattice.

The harness compiles these **unchanged native producer sources** directly from Lattice:

- `Packages/LatticeCore/Sources/LatticeCore/RDWorkspace.swift`
- `Packages/LatticeCore/Sources/LatticeCore/ActivityTimeline.swift`
- `Packages/LatticeCore/Sources/LatticeCore/Markdown/NoteParsing.swift`
- `Packages/LatticeCore/Sources/LatticeCore/Persistence/ContentDigest.swift`

`RDWorkspaceStore.exportCapsule` delegates to `AgentContextExporter.capsule`; the Workbench's
`ContextCapsuleDocument` delegates to `ContextCapsuleCodec.encode`. The harness calls those actual
compiled producer/codec implementations with a synthetic `RDWorkspaceArchive`. No producer logic
or JSON encoder is copied into the fixture.

The actual Sentient Debug binary then imports the generated capsule using an explicit temporary
`--context-store`, reopens and reimports it in a separate process, queries a dated citation, and
resolves that citation through its real local stdio MCP bridge. Six checks verify:

1. Native v1 capsule production includes two events and one release, excluding an unrelated project.
2. Import produces four records and one source, with sharing off by default.
3. Reopening/reimporting retains native project/event identities without duplicates.
4. Query citations retain the recorded instant, source-summary role, project, and capsule reference.
5. Failed work remains failed, and a shared query cannot retrieve the local-only evidence.
6. The returned citation resolves to its original evidence through the app's local MCP endpoint.

All files and stores are synthetic and created in a private temporary directory under Sentient's
`.build`; it is removed on exit. Every app invocation includes `--context-store` and a headless
mode. No Lattice app, private storage, real Keychain, telemetry, model, scheduler, or network service
is used. The app executable's hash is checked before and after the run to reject an overlapping
build that replaces it during verification.

Verified on 2026-09-06 against Lattice commit `82bdb62dc3eb96549fb0eb9f902df3a5b9f8a9ef` with the
listed producer sources clean: **6/6 checks passed**. Final output is retained in
`.build/lattice-producer-roundtrip-final.log`. This verifies the native producer and consumer path;
it does not exercise Lattice's export button, its persisted user workspace, or live health data.
