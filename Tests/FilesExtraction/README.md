# Files extraction regression

Run `/opt/homebrew/bin/python3 Tests/FilesExtraction/run.py` on macOS with Xcode installed. The runner defaults to the verified Xcode-beta Swift toolchain and macOS 27 SDK; `SWIFT_BIN` and `SDKROOT` override those paths.

The runner compiles the current `FilesSource.swift`, its real value types, and the context core. Only source-listing telemetry is stubbed. It creates and removes artificial files in a temporary directory and never reads configured user sources, launches Sentient, loads a model, or calls cloud services.

The 16 cases cover missing and unreadable text, malformed PDF/DOC/DOCX, copied generated markers before and after the excerpt limit, stale generated-root candidates, valid empty text and documents, whitespace, Latin-1, Word/RTF decoding, and the existing 8,000-character cap. A CoreGraphics diagnostic while rejecting the deliberately corrupt PDF is expected. Nonzero exit means a failed check or fixture setup error.
