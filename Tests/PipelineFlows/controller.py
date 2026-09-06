#!/usr/bin/env python3
"""Exercise current pipeline code using synthetic dependencies and temporary data."""
from pathlib import Path
import os
SOURCE_ROOT = Path(__file__).resolve().parents[2] / 'Sentient OS macOS'
import os, subprocess, tempfile
root = SOURCE_ROOT
source = '\n'.join(p.read_text() for p in sorted((root/'Context').glob('*.swift'))) + '\n' + (root/'App/ContextLibrary.swift').read_text()
audit = r'''
@MainActor func auditContextUI() async -> Int32 {
 do {
  let root = ContextPaths.root
  let original = root.deletingLastPathComponent().appendingPathComponent("artificial.md")
  try Data("Synthetic decision: keep local context private by default.".utf8).write(to: original)
  let library = ContextLibrary()
  guard let store = library.store else { print("FAIL store setup"); return 1 }
  precondition(!library.projectionReady)
  var source = ImportSource(kind: .markdown, path: original.path)
  precondition(library.add(source)); precondition(!library.projectionReady)
  let first = Task { await library.importEnabled() }, second = Task { await library.importEnabled() }
  let firstOK = await first.value, secondOK = await second.value
  precondition(firstOK && secondOK)
  precondition(try store.counts(sourceID: source.id) == 1)
  precondition(try store.evidence(audience: .shared).isEmpty)
  precondition(library.projectionReady)
  print("PASS shared callers await import and source sharing stays off")

  let lock = root.appendingPathComponent(".projection.lock")
  try FileManager.default.removeItem(at: lock)
  try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
  source.contextEnabled = false
  precondition(library.save(source)); precondition(!library.projectionReady)
  let failed = await library.refreshProjection()
  precondition(!failed && !library.projectionReady)
  precondition(try store.evidence(audience: .local).isEmpty)
  print("PASS source exclusion hides projection immediately and a failed rebuild stays hidden")
  try FileManager.default.removeItem(at: lock)
  let recovered = await library.refreshProjection()
  precondition(recovered && library.projectionReady)
  let files = try FileManager.default.contentsOfDirectory(at: ContextPaths.projection, includingPropertiesForKeys: nil)
  precondition(files.isEmpty)
  print("PASS successful retry publishes only current permitted evidence")

  source.contextEnabled = true
  precondition(library.save(source))
  let directory = root.deletingLastPathComponent().appendingPathComponent("artificial-large", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  for index in 0..<100 { try Data(String(repeating: "Synthetic context. ", count: 3000).utf8).write(to: directory.appendingPathComponent("\(index).md")) }
  var large = ImportSource(kind: .markdown, path: directory.path)
  precondition(library.add(large))
  let run = Task { await library.importEnabled() }
  while !library.isImporting { await Task.yield() }
  large.enabled = false
  precondition(library.save(large))
  let stoppedCount = try store.counts(sourceID: large.id)
  let finished = await run.value
  precondition(!finished && !library.isImporting)
  precondition(try store.counts(sourceID: large.id) == stoppedCount)
  print("PASS disabling an active source prevents subsequent writes")
  precondition(library.remove(source)); precondition(!library.projectionReady)
  precondition(FileManager.default.fileExists(atPath: original.path))
  print("PASS source removal preserves the original file")
  _ = await library.refreshProjection()
  return 0
 } catch { print("FAIL synthetic UI lifecycle: \(error)"); return 1 }
}
Task { exit(await auditContextUI()) }; dispatchMain()
'''
# Throwing work must be evaluated outside precondition's nonthrowing autoclosure.
audit = audit.replace('precondition(try store.counts(sourceID: source.id) == 1)', 'let count = try store.counts(sourceID: source.id); precondition(count == 1)')
audit = audit.replace('precondition(try store.evidence(audience: .shared).isEmpty)', 'let shared = try store.evidence(audience: .shared); precondition(shared.isEmpty)')
audit = audit.replace('precondition(try store.evidence(audience: .local).isEmpty)', 'let local = try store.evidence(audience: .local); precondition(local.isEmpty)')
audit = audit.replace('precondition(try store.counts(sourceID: large.id) == stoppedCount)', 'let laterCount = try store.counts(sourceID: large.id); precondition(laterCount == stoppedCount)')
command = [os.environ.get('SWIFT_BIN', '/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift'),'-D','DEBUG','-swift-version','5','-default-isolation','MainActor','-target','arm64-apple-macos15.0','-sdk',os.environ.get('SDKROOT', '/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk'),'-lsqlite3','-']
with tempfile.TemporaryDirectory(prefix='sentient-ui-audit-') as temporary:
 environment = os.environ.copy(); environment['SENTIENT_CONTEXT_ROOT'] = str(Path(temporary)/'context')
 raise SystemExit(subprocess.run(command, input=source+audit, env=environment, text=True, timeout=120).returncode)
