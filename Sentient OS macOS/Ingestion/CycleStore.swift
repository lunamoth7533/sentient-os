//
//  CycleStore.swift
//  Sentient OS macOS
//
//  The iterative system's database — connector-agnostic, with its OWN on-disk container (isolated
//  from the old `Store`, so its models never schema-wipe the old dev DB). Two models:
//
//   - BucketPointer  DURABLE. One row per BUCKET (folder root / chat / "notes"). Normally the
//                    HIGH-WATER MARK — everything ≤ (order, tiebreak) is done, everything newer is
//                    new. During a bucket's FIRST run it also carries a FLOOR (the oldest item done
//                    so far, sinking one item at a time) so a crash mid-descent RESUMES below the
//                    floor instead of restarting; the floor collapses into the mark once the descent
//                    reaches the bottom. The ONLY state that survives a cycle.
//   - CycleNote      EPHEMERAL. One survivor summary, wiped at cycle end (the proactive button).
//                    Junk/sensitive store nothing. `kind` + `sourceID` carry the cloud's trust tag.
//
//  Only this actor touches the @Models; callers pass Sendable value types (ItemKey, CycleNoteItem).
//

import Foundation
import SwiftData

// MARK: - Models

/// DURABLE — one per bucket.
///
/// • Everyday state: `(order, tiebreak)` is the HIGH-WATER MARK (everything ≤ it is done); `floor` is nil.
/// • First-run state, while filling newest→oldest: `(order, tiebreak)` holds the TOP (the newest item
///   this first run covers — fixed for the whole descent), and `floor` is the oldest item done so far,
///   sinking one item at a time. Everything between floor and top is done; the descent continues below
///   the floor. A non-nil floor is the single tell that a first run is mid-flight — so a crash resumes
///   (below the floor) instead of restarting. On reaching the bottom the floor collapses to nil,
///   leaving `(order, tiebreak)` as a normal high-water mark.
@Model
final class BucketPointer {
    @Attribute(.unique) var bucketKey: String     // "file:<root.id>" / "notes" / "whatsapp:<jid>"
    var order: Double
    var tiebreak: String
    var floorOrder: Double?                        // non-nil ⇒ first run in progress (this is the FLOOR)
    var floorTiebreak: String?
    var updatedAt: Date

    init(bucketKey: String, mark: ItemKey, floor: ItemKey? = nil, updatedAt: Date = Date()) {
        self.bucketKey = bucketKey
        self.order = mark.order
        self.tiebreak = mark.tiebreak
        self.floorOrder = floor?.order
        self.floorTiebreak = floor?.tiebreak
        self.updatedAt = updatedAt
    }
    var mark: ItemKey { ItemKey(order: order, tiebreak: tiebreak) }
    var floor: ItemKey? {
        guard let floorOrder else { return nil }
        return ItemKey(order: floorOrder, tiebreak: floorTiebreak ?? "")
    }
}

/// EPHEMERAL — one survivor summary for one item, this cycle only.
@Model
final class CycleNote {
    var bucketKey: String
    var kind: String           // SourceKind.rawValue — the cloud's source-trust tiers key on it
    var sourceID: String       // "file:<path>" / "notes:<uuid>" / chat id — for the cloud's locSrc
    var folder: String         // display tag
    var itemDateEpoch: Double
    var text: String
    var title: String?
    var reminderFlagged: Bool
    var createdAt: Date

    init(bucketKey: String, kind: SourceKind, sourceID: String, folder: String, itemDate: Date,
         text: String, title: String?, reminderFlagged: Bool, createdAt: Date = Date()) {
        self.bucketKey = bucketKey
        self.kind = kind.rawValue
        self.sourceID = sourceID
        self.folder = folder
        self.itemDateEpoch = itemDate.timeIntervalSince1970
        self.text = text
        self.title = title
        self.reminderFlagged = reminderFlagged
        self.createdAt = createdAt
    }
}

/// A Sendable snapshot of one CycleNote — what VIEW SUMMARIES + the cloud calls consume. Codable so
/// a whole summary set can be exported/imported between devs (computed props below aren't stored).
struct CycleNoteItem: Codable, Sendable, Identifiable, Equatable {
    let id: String             // bucket + kind + source ID + item date; distinct windows stay distinct
    let bucketKey: String
    let kind: SourceKind
    let sourceID: String
    let folder: String
    let itemDate: Date
    let text: String
    let title: String?
    let reminderFlagged: Bool
    let createdAt: Date

    /// On-disk path for file artifacts (sourceID is "file:/abs/path"); nil for DB/chat sources.
    var filePath: String? { sourceID.hasPrefix("file:") ? String(sourceID.dropFirst(5)) : nil }
    var displayName: String {
        if let p = filePath { return URL(fileURLWithPath: p).lastPathComponent }
        return title ?? folder
    }
    var displayPath: String {
        guard sourceID.hasPrefix("file:") else { return folder }
        let p = String(sourceID.dropFirst(5))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + String(p.dropFirst(home.count)) : p
    }
}

/// The JSON shape for exporting/importing a summary set between devs (a debug tool — e.g. share a
/// rich CycleStore so a co-founder can build proactive against real context). Notes ONLY: pointers
/// are never exported (a dev's high-water marks are meaningless — and harmful — on another machine).
struct SummaryExport: Codable, Sendable {
    var version = 1
    var exportedAt = Date()
    var notes: [CycleNoteItem]
}

/// The survivor fields for one processed item, handed to an atomic per-item commit (note + marker in
/// ONE save). nil at a call site = a genuine non-survivor (junk / sensitive) — the marker still
/// advances past it, but no note is kept (zero trace). Failed attempts MUST NOT commit a marker.
struct NoteDraft: Sendable {
    let kind: SourceKind
    let sourceID: String
    let folder: String
    let itemDate: Date
    let text: String
    let title: String?
    let reminderFlagged: Bool
}

// MARK: - The actor

@ModelActor
actor CycleStore {
    private var unavailable = false

    enum StoreError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "Local summary storage is unavailable. Existing data was preserved. Check free disk space and Application Support access, then restart Sentient."
        }
    }

    /// A disabled sentinel lets the UI explain an open failure without deleting the user's store
    /// or quietly treating a fresh in-memory database as writable replacement storage.
    init(modelContainer: ModelContainer, unavailable: Bool) {
        self.modelContainer = modelContainer
        let context = ModelContext(modelContainer)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.unavailable = unavailable
    }

    func requireAvailable() throws {
        if unavailable { throw StoreError.unavailable }
    }

    // MARK: Pointers (durable)

    /// The high-water mark for a bucket, or nil if it's never run.
    func pointer(_ bucketKey: String) -> ItemKey? { row(bucketKey)?.mark }

    /// A bucket's full durable state, or nil if it's never run: the high-water mark (or, mid-first-run,
    /// the TOP), plus the FLOOR when a first run is mid-descent. A non-nil floor ⇒ resume that descent
    /// (strictly below the floor) rather than restart. IterativeRun reads this to pick per-bucket mode.
    func pointerState(_ bucketKey: String) throws -> (mark: ItemKey, floor: ItemKey?)? {
        guard let r = try fetchRow(bucketKey) else { return nil }
        return (r.mark, r.floor)
    }

    /// Per-bucket hints handed to connectors for efficient `> mark` listing. A bucket mid-first-run
    /// (floor set) is OMITTED so its connector returns its FULL set — the descent needs items BELOW
    /// its top, which a `> mark` hint would hide. IterativeRun still filters/advances authoritatively.
    func connectorMarks() throws -> [String: ItemKey] {
        try requireAvailable()
        let rows = try modelContext.fetch(FetchDescriptor<BucketPointer>())
        return Dictionary(rows.filter { $0.floorOrder == nil }.map { ($0.bucketKey, $0.mark) },
                          uniquingKeysWith: { a, _ in a })
    }

    /// Set a bucket's mark directly (used by the Gmail cloud leg, which stamps a run-time pointer and
    /// has no on-device descent). On-device runs use the atomic `advance` / `sinkFloor` instead.
    func setPointer(_ bucketKey: String, _ mark: ItemKey) throws {
        try commit(bucketKey: bucketKey, note: nil, apply: { r in
            r.order = mark.order; r.tiebreak = mark.tiebreak; r.updatedAt = Date()
        }, make: {
            BucketPointer(bucketKey: bucketKey, mark: mark)
        })
    }

    /// Initial reset for one bucket: drop its pointer AND its ephemeral notes (fresh top→bottom).
    func clearBucket(_ bucketKey: String) throws {
        try saveChanges {
            if let r = try fetchRow(bucketKey) { modelContext.delete(r) }
            try modelContext.delete(model: CycleNote.self, where: #Predicate { $0.bucketKey == bucketKey })
        }
    }

    /// Throwing fetch — lets write paths tell "no row exists" apart from "the fetch failed" (B9). A
    /// swallowed failure here is what let the insert-branch fire on a row that DID exist, colliding on
    /// the @unique key and losing the mark forever.
    private func fetchRow(_ bucketKey: String) throws -> BucketPointer? {
        try requireAvailable()
        return try modelContext.fetch(
            FetchDescriptor<BucketPointer>(predicate: #Predicate { $0.bucketKey == bucketKey })
        ).first
    }

    /// The scheme prefix of a bucketKey ("whatsapp" / "imessage" / "file" / "notes") — the only part
    /// safe to log: the full key carries a chat's phone-number JID or a user file path, and every
    /// Log() line ships to Sentry as a Release breadcrumb.
    nonisolated static func scheme(_ bucketKey: String) -> Substring { bucketKey.prefix(while: { $0 != ":" }) }

    /// Read-only convenience (pointer / pointerState). A failed fetch degrades to nil (re-listing),
    /// but is now surfaced instead of silently swallowed.
    private func row(_ bucketKey: String) -> BucketPointer? {
        do { return try fetchRow(bucketKey) }
        catch {
            Log("CycleStore.row(\(Self.scheme(bucketKey))) fetch failed: \(ErrorLabel(error))")
            CrashReporting.capture(error)
            return nil
        }
    }

    /// Every write either saves fully or rolls back, including pending in-memory model changes.
    private func saveChanges(_ change: () throws -> Void) throws {
        try requireAvailable()
        try Task.checkCancellation()
        do {
            try change()
            try Task.checkCancellation()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Note and marker share ONE save. Retry a fetch/save collision once; a terminal failure MUST
    /// reach the orchestrator so a later item cannot advance its mark past this unsaved survivor.
    private func commit(bucketKey: String, note: NoteDraft?,
                        apply: (BucketPointer) -> Void, make: () -> BucketPointer) throws {
        func attempt() throws {
            try saveChanges {
                if let note { try insertNote(bucketKey: bucketKey, note: note) }
                if let r = try fetchRow(bucketKey) { apply(r) }
                else { modelContext.insert(make()) }
            }
        }
        do { try attempt() }
        catch {
            try Task.checkCancellation()
            Log("CycleStore.commit(\(Self.scheme(bucketKey))) failed: \(ErrorLabel(error)) — rolling back, retrying as update")
            CrashReporting.capture(error)
            do {
                try attempt()
            } catch {
                Log("CycleStore.commit(\(Self.scheme(bucketKey))) recovery failed: \(ErrorLabel(error)) — mark NOT persisted this item")
                CrashReporting.capture(error)
                throw error
            }
        }
    }

    // MARK: Notes (ephemeral)

    func recordNote(bucketKey: String, kind: SourceKind, sourceID: String, folder: String,
                    itemDate: Date, text: String, title: String?, reminderFlagged: Bool) throws {
        try saveChanges {
            try insertNote(bucketKey: bucketKey,
                           note: NoteDraft(kind: kind, sourceID: sourceID, folder: folder, itemDate: itemDate,
                                           text: text, title: title, reminderFlagged: reminderFlagged))
        }
    }

    /// Idempotent without a schema migration. The item date distinguishes imported chat windows
    /// whose source IDs came from an older exporter; existing duplicates of this identity coalesce.
    private func insertNote(bucketKey: String, note: NoteDraft, createdAt: Date = Date()) throws {
        let kind = note.kind.rawValue, sourceID = note.sourceID
        let epoch = note.itemDate.timeIntervalSince1970
        let existing = try modelContext.fetch(FetchDescriptor<CycleNote>(predicate: #Predicate {
            $0.bucketKey == bucketKey && $0.kind == kind && $0.sourceID == sourceID && $0.itemDateEpoch == epoch
        }))
        if let row = existing.first {
            row.folder = note.folder; row.text = note.text; row.title = note.title
            row.reminderFlagged = note.reminderFlagged; row.createdAt = createdAt
            for duplicate in existing.dropFirst() { modelContext.delete(duplicate) }
        } else {
            modelContext.insert(CycleNote(bucketKey: bucketKey, kind: note.kind, sourceID: note.sourceID,
                                          folder: note.folder, itemDate: note.itemDate, text: note.text,
                                          title: note.title, reminderFlagged: note.reminderFlagged, createdAt: createdAt))
        }
    }

    // MARK: Atomic per-item commits (the crash-safety core — note + marker in ONE save)

    /// EVERYDAY (iterative) — record an optional survivor note AND advance the high-water bookmark to
    /// `mark`, in one save. No gap between the two writes ⇒ a crash can never leave a note without its
    /// bookmark (which would re-summarize the item into a duplicate). Clears any floor.
    func advance(bucketKey: String, note: NoteDraft?, to mark: ItemKey) throws {
        try commit(bucketKey: bucketKey, note: note, apply: { r in
            r.order = mark.order; r.tiebreak = mark.tiebreak
            r.floorOrder = nil; r.floorTiebreak = nil; r.updatedAt = Date()
        }, make: {
            BucketPointer(bucketKey: bucketKey, mark: mark)
        })
    }

    /// FIRST RUN (initial descent) — record an optional survivor note AND sink the floor to `floor`
    /// (top stays fixed), in one save. Creates the row with `top` on the first step. A crash leaves an
    /// honest floor → the next run resumes strictly below it.
    func sinkFloor(bucketKey: String, note: NoteDraft?, top: ItemKey, floor: ItemKey) throws {
        try commit(bucketKey: bucketKey, note: note, apply: { r in
            r.order = top.order; r.tiebreak = top.tiebreak
            r.floorOrder = floor.order; r.floorTiebreak = floor.tiebreak; r.updatedAt = Date()
        }, make: {
            BucketPointer(bucketKey: bucketKey, mark: top, floor: floor)
        })
    }

    /// FIRST RUN done — collapse: clear the floor, leaving `(order, tiebreak)` (the top) as a normal
    /// high-water mark. From here the bucket is in everyday mode. (Mutates an existing row only — no
    /// insert — so it can't hit the unique-collision path.) Failed saves keep the honest floor.
    func collapseFloor(_ bucketKey: String) throws {
        try saveChanges {
            if let r = try fetchRow(bucketKey) { r.floorOrder = nil; r.floorTiebreak = nil; r.updatedAt = Date() }
        }
    }

    /// Every current-cycle note, newest first (VIEW SUMMARIES + the cloud corpus).
    func notes() -> [CycleNoteItem] {
        (try? readNotes()) ?? []
    }

    /// Strict read for operations that depend on having the entire set, such as replacement backup.
    /// A failed fetch must never be interpreted as "there is nothing to preserve".
    func readNotes() throws -> [CycleNoteItem] {
        try requireAvailable()
        let rows = try modelContext.fetch(FetchDescriptor<CycleNote>(
            sortBy: [SortDescriptor(\.itemDateEpoch, order: .reverse)]))
        return rows.map(item(from:))
    }

    /// End-of-cycle wipe (fired by the proactive button) — pointers persist, notes do not.
    func wipeAllNotes() {
        try? wipeAllNotesDurably()
    }

    /// Processing callers must observe completion before acknowledging the end of a cycle.
    func wipeAllNotesDurably() throws {
        try saveChanges { try modelContext.delete(model: CycleNote.self) }
    }

    /// Cloud work consumes a snapshot across awaits. A later import can add or revise notes in
    /// that interval; acknowledge only the exact values the completed work actually consumed.
    func wipeNotesDurably(matching snapshots: [CycleNoteItem]) throws {
        let consumed = Dictionary(grouping: snapshots, by: \.id)
        try saveChanges {
            for row in try modelContext.fetch(FetchDescriptor<CycleNote>()) {
                let current = item(from: row)
                if consumed[current.id]?.contains(current) == true { modelContext.delete(row) }
            }
        }
    }

    /// Factory reset — delete EVERY pointer and EVERY note (the dev "Reset everything" button pairs
    /// this with wiping the vault). After this, the next run is a fresh first run for every bucket.
    func wipeEverything() {
        try? saveChanges {
            try modelContext.delete(model: CycleNote.self)
            try modelContext.delete(model: BucketPointer.self)
        }
    }

    /// Merge notes from an export file (dev cross-pollination — share a rich summary set with a
    /// co-founder). Preserves each note's original createdAt + itemDate so proactive's recency windows
    /// stay faithful to the source timeline. `replace` wipes existing notes first. Pointers are NEVER
    /// touched — an import carries summaries only, so the importer's own processing state is unaffected.
    func importNotes(_ items: [CycleNoteItem], replace: Bool) throws {
        try saveChanges {
            if replace { try modelContext.delete(model: CycleNote.self) }
            for it in items {
                try insertNote(bucketKey: it.bucketKey,
                               note: NoteDraft(kind: it.kind, sourceID: it.sourceID, folder: it.folder,
                                               itemDate: it.itemDate, text: it.text, title: it.title,
                                               reminderFlagged: it.reminderFlagged), createdAt: it.createdAt)
            }
        }
    }

    /// (notes, distinct buckets) — for the dev UI counts.
    func counts() -> (notes: Int, buckets: Int) {
        guard !unavailable else { return (0, 0) }
        let n = (try? modelContext.fetch(FetchDescriptor<CycleNote>())) ?? []
        return (n.count, Set(n.map(\.bucketKey)).count)
    }

    private func item(from n: CycleNote) -> CycleNoteItem {
        // Length prefixes keep separator characters inside source IDs unambiguous. No stored
        // column changes; old exports still decode and their obsolete IDs are ignored on import.
        let identity = [n.bucketKey, n.kind, n.sourceID, String(n.itemDateEpoch.bitPattern)]
            .map { "\($0.utf8.count):\($0)" }.joined()
        return CycleNoteItem(id: identity, bucketKey: n.bucketKey,
                      kind: SourceKind(rawValue: n.kind) ?? .file, sourceID: n.sourceID,
                      folder: n.folder, itemDate: Date(timeIntervalSince1970: n.itemDateEpoch),
                      text: n.text, title: n.title, reminderFlagged: n.reminderFlagged, createdAt: n.createdAt)
    }
}

// MARK: - Shared instance (its own container)

extension CycleStore {
    /// The app-wide iterative store, backed by its OWN on-disk store ("IterativeCycle.store" under
    /// the namespaced `SentientOS` root in Application Support). An open failure preserves the DB,
    /// WAL and SHM for recovery and disables storage; no automatic reset or writable fallback.
    static let shared: CycleStore = {
        let schema = Schema([BucketPointer.self, CycleNote.self])
        let url = URL.sentientSupport.appending(path: "IterativeCycle.store")
        let config = ModelConfiguration(schema: schema, url: url)
        do {
            let container = try ModelContainer(for: schema, configurations: config)
            return CycleStore(modelContainer: container)
        } catch {
            Log("CycleStore: open failed (\(String(describing: type(of: error)))); existing storage preserved")
            // SwiftData still needs a writable scratch backing to construct its in-memory context.
            // The actor's unavailable guard rejects every operation before it can touch that context.
            let disabled = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            guard let container = try? ModelContainer(for: schema, configurations: disabled) else {
                fatalError("CycleStore: storage unavailable; existing on-disk data was preserved")
            }
            return CycleStore(modelContainer: container, unavailable: true)
        }
    }()
}
