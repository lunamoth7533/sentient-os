# Knowledge graph regressions

```sh
bash Tests/KnowledgeGraph/run.sh
```

This retained CLI compiles the real vault loader, graph builder, `NightSkyModel.swift`, and
`SkySimulation.swift` against temporary, synthetic Markdown folders. It does not launch the app
or read the live vault. Rendering/logging are inert and the view's small seeded RNG is supplied
locally. Xcode is selected
with `DEVELOPER_DIR` (default: `/Applications/Xcode-beta.app/Contents/Developer`); the script uses
its compiler and SDK directly and cleans up its temporary executable.

The original code failed six behavioral cases: explicit paths, source-folder disambiguation,
ambiguous-title abstention, code examples, symlink traversal, and ancestor path boundaries. Node
metadata already passed. A separate HTML-comment case also failed before its fix. The first 13
cases pass, including additional root scopes, duplicate-root/name handling, additional-only
vaults, symlink replacement after loading, valid alias/heading/relative links, and metadata.

`KnowledgeVault.load(root:additionalRoots:)` only reads explicit folders. Additional roots appear
under their basename, with deterministic numeric suffixes when names collide, and each receives
its own graph domain. Overlapping roots are omitted to prevent duplicate nodes. The reader uses
`isReadOnly(_:)` for mutation affordances and `resolve(_:from:)` for contextual links. Counting
notes uses `allNotes.count`; `titleIndex` contains only unambiguous names.

The graph extracts explicit wikilinks, not inferred semantic relationships. It excludes fenced
and indented code, inline code, escaped link syntax, and HTML comments. These are data-layer
tests; visual layout and assembled-app checks remain separate.

Six later model regressions also failed before their fixes: the stable root URL prevented a
projection-ready snapshot or same-path content edit from refreshing the displayed sky; slow old
and cancelled builds could publish; a reordered node list moved the highlight to another note;
and a missing vault retained previously displayed notes. All 19 current cases pass. The refresh
tests drive the same `revision` used by the view's `.task`, then check the actual model graph,
simulation positions, and camera. Actor continuation barriers control overlapping real graph
builds without sleeps. Nil-vault preview data remains intentional. Evidence is retained in
`.build/knowledge-graph-refresh-red.log` and `.build/knowledge-graph-refresh-final.log`.
