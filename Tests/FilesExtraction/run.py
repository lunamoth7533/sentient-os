#!/usr/bin/env python3
"""Exercise actual FilesSource decoders with temporary synthetic files only."""
from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parents[2] / 'Sentient OS macOS'
source = '\n'.join(p.read_text() for p in sorted((root/'Context').glob('*.swift'))) + '\n' + (root/'Sources/DataSource.swift').read_text() + '\n' + (root/'Sources/FilesSource.swift').read_text()
audit = r'''
nonisolated enum SourceHealth { static func checkListingCollapse(source: String, bucketKey: String, count: Int) {} }
@MainActor func auditFiles() throws -> Int32 {
 let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SENTIENT_FILES_AUDIT_ROOT"]!, isDirectory: true)
 var failures = 0
 func candidate(_ url: URL) -> Candidate { Candidate(id: "file:\(url.path)", kind: .file, itemDate: Date(), metadata: ["path": url.path]) }
 func reject(_ name: String, data: Data?, directory: Bool = false) throws {
  let file = root.appendingPathComponent(name)
  if let data { try data.write(to: file) }
  if directory { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false) }
  do { _ = try FilesSource.loadArtifact(candidate(file)); print("FAIL \(name) returned an artifact"); failures += 1 }
  catch { print("PASS \(name) rejected") }
 }
 try reject("missing.txt", data: nil)
 try reject("unreadable.txt", data: nil, directory: true)
 try reject("malformed.pdf", data: Data("%PDF-1.7\nnot a PDF structure".utf8))
 try reject("malformed.doc", data: Data([0, 255, 1, 254, 127, 0]))
 try reject("malformed.docx", data: Data([80, 75, 3, 4, 0, 255, 1]))
 try reject("copied-summary.md", data: Data("# Artificial projection\n\(ContextProjection.marker)\nAlready synthesized.".utf8))
 try reject("late-marker.txt", data: Data((String(repeating: "A", count: 9000) + ContextProjection.marker).utf8))
 let generated = ContextPaths.root.appendingPathComponent("copied-into-generated.txt")
 try FileManager.default.createDirectory(at: ContextPaths.root, withIntermediateDirectories: true)
 try Data("Synthetic stale candidate".utf8).write(to: generated)
 do { _ = try FilesSource.loadArtifact(candidate(generated)); print("FAIL stale generated-root candidate was loaded"); failures += 1 }
 catch { print("PASS stale generated-root candidate rejected") }
 let empty = root.appendingPathComponent("empty.txt"); try Data().write(to: empty)
 if try FilesSource.loadArtifact(candidate(empty)).text == "" { print("PASS legitimate empty text preserved") } else { failures += 1 }
 let whitespace = root.appendingPathComponent("whitespace.md"); try Data(" \r\n\t".utf8).write(to: whitespace)
 if try FilesSource.loadArtifact(candidate(whitespace)).text == "" { print("PASS whitespace-only text preserved") } else { failures += 1 }
 let latin = root.appendingPathComponent("latin.txt"); try Data([99, 97, 102, 233]).write(to: latin)
 if try FilesSource.loadArtifact(candidate(latin)).text == "caf\u{e9}" { print("PASS supported Latin-1 text preserved") } else { failures += 1 }
 let long = root.appendingPathComponent("long.txt"); try Data(String(repeating: "A", count: 9000).utf8).write(to: long)
 if try FilesSource.loadArtifact(candidate(long)).text?.count == 8000 { print("PASS existing extraction cap preserved") } else { failures += 1 }
 let pdf = PDFDocument(); pdf.insert(PDFPage(), at: 0)
 let blank = root.appendingPathComponent("blank.pdf")
 guard let blankData = pdf.dataRepresentation() else { throw NSError(domain: "audit", code: 1) }
 try blankData.write(to: blank)
 if try FilesSource.loadArtifact(candidate(blank)).text == "" { print("PASS valid blank PDF preserved") } else { failures += 1 }
 let docx = root.appendingPathComponent("valid.docx")
 let attributed = NSAttributedString(string: "Synthetic Word text")
 let docxData = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
 try docxData.write(to: docx)
 if try FilesSource.loadArtifact(candidate(docx)).text == "Synthetic Word text" { print("PASS valid Word document preserved") } else { failures += 1 }

 let emptyDocx = root.appendingPathComponent("empty.docx")
 let noText = NSAttributedString(string: "")
 let emptyDocxData = try noText.data(from: NSRange(location: 0, length: 0), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
 try emptyDocxData.write(to: emptyDocx)
 if try FilesSource.loadArtifact(candidate(emptyDocx)).text == "" { print("PASS valid empty Word document preserved") } else { failures += 1 }
 let rtfDoc = root.appendingPathComponent("rich-text.doc")
 let rtfData = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
 try rtfData.write(to: rtfDoc)
 if try FilesSource.loadArtifact(candidate(rtfDoc)).text == "Synthetic Word text" { print("PASS supported rich-text DOC preserved") } else { failures += 1 }
 return failures == 0 ? 0 : 1
}
Task { @MainActor in do { exit(try auditFiles()) } catch { print("FAIL fixture setup: \(error)"); exit(2) } }; dispatchMain()
'''
command = [os.environ.get('SWIFT_BIN', '/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift'),'-D','DEBUG','-swift-version','5','-default-isolation','MainActor','-target','arm64-apple-macos15.0','-sdk',os.environ.get('SDKROOT', '/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk'),'-lsqlite3','-']
with tempfile.TemporaryDirectory(prefix='sentient-files-audit-') as temporary:
 environment = os.environ.copy(); environment['SENTIENT_FILES_AUDIT_ROOT'] = temporary; environment['SENTIENT_CONTEXT_ROOT'] = str(Path(temporary)/'context')
 raise SystemExit(subprocess.run(command, input=source+audit, env=environment, text=True, timeout=120).returncode)
