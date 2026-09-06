# Importing Lattice context and personal metrics

All examples and test fixtures in this repository are synthetic. Add a file source explicitly in Sentient; no adapter discovers Lattice's live store, requests HealthKit access, or connects to an account. External sharing starts off. Every personal snapshot and metrics CSV record, including deletion markers, is marked sensitive in the evidence inspector. Source inclusion and sharing permissions govern its use.

## Supported Lattice Workbench export

In Lattice, open **Work**, choose one **Project Lens**, then choose **Approved Agent Context → Export JSON capsule**. Save the exported JSON and select it as a **Lattice export** source in Sentient. Lattice's **Share Markdown context** action can instead be used with Sentient's Markdown import. Workbench context contains development summaries and evidence handles; it is not a health-data export.

Sentient accepts the provider-neutral `lattice.context-capsule.v1` format. The source contract was checked against Lattice commit `82bdb62dc3eb96549fb0eb9f902df3a5b9f8a9ef`, configured as version 1.0 (11), in its `README.md`, `docs/RD_WORKSPACE.md`, and `Packages/LatticeCore/Sources/LatticeCore/RDWorkspace.swift`.

```json
{
  "schema": "lattice.context-capsule.v1",
  "id": "synthetic-capsule-1",
  "generatedAt": "2026-09-06T12:00:00Z",
  "project": {"id": "example", "name": "Example", "aliases": []},
  "provider": "lattice",
  "goal": "Verify the local connector.",
  "events": [{
    "id": "test-1", "projectID": "example", "occurredAt": "2026-09-06T11:00:00Z",
    "kind": "test", "status": "succeeded", "source": "Synthetic runner",
    "title": "Connector check", "summary": "Three synthetic checks passed.",
    "evidence": ["test:synthetic-1"], "metadata": {"passed": "3"}
  }],
  "releases": [],
  "redactions": ["Raw source bodies omitted."]
}
```

Top-level arrays and `project.aliases` are required, even when empty. `project.repository`, event `threadID`, and event/release `capsuleProvenance` are optional. Release receipts require `id`, `projectID`, `version`, `build`, `commitSHA`, `occurredAt`, and `processingStatus`; their optional details are preserved as attributed summaries.

The adapter validates the native boundary: 1 MiB, 500 events, 25 releases, 8,192-character summaries/goals, bounded labels/evidence/metadata, valid identifiers, supported enums, unique IDs, and a single project. Unknown fields are not imported. Unknown schemas and malformed files fail as a whole.

Capsule evidence remains a source-provided summary, even when its status says a test succeeded. Stable identities include the project and native event/release ID. `generatedAt` orders revisions; equal-time corrections follow import order, matching Lattice, because capsule identity is not a revision token. **An omitted event is not a deletion:** native exports keep the newest evidence that fits their limits, and report omissions in `redactions`. Importing a complete capsule therefore upserts records without deleting older imported evidence. Capsule v1 has no deletion-marker field.

The private `RDWorkspace-v1.json` archive (`lattice.rd-workspace.v1`) is a different format and is not accepted as an exported capsule. The reference Lattice script `scripts/capsule-from-session.py` can create capsules outside Lattice; its current transcript parser recognizes Claude-shaped tool blocks. A provider label alone does not establish support for another provider's raw transcript format.

## Personal snapshot compatibility mode

Lattice 1.0 (11) has no native JSON/CSV personal-metric export action. Its visible metric export shares rendered charts. Sentient's personal-snapshot adapter is an explicit **user-selected copy compatibility mode**, not a supported Lattice export API or a live database connection. Supply a copy of `PersonalData-v1.json` that you have chosen to make available. Do not point it at an application's live container; the adapter does not search containers or create the copy for you.

The accepted internal format is `version: 1`, a `records` dictionary keyed by each record's native `id`, and a `pending` ID array. Legacy `accountID` and `changeToken` fields, pending state, and unknown fields are never saved as imported evidence. Files are bounded to 64 MiB and 50,000 records. These are adapter limits, not a promise that Lattice's internal format will remain stable.

```json
{
  "version": 1,
  "records": {
    "checkin-2026-09-06": {
      "id": "checkin-2026-09-06", "day": "2026-09-06",
      "checkIn": {"day": "2026-09-06", "mood": 4, "caffeineMg": 0},
      "updatedAt": 810388800.125,
      "revision": "00000000-0000-4000-8000-000000000001", "deleted": false
    },
    "metric-steps-2026-09-06": {
      "id": "metric-steps-2026-09-06", "day": "2026-09-06", "metric": "steps", "value": 0,
      "updatedAt": 810388800,
      "revision": "00000000-0000-4000-8000-000000000002", "deleted": false
    }
  },
  "pending": []
}
```

`updatedAt` is a finite number of seconds since **2001-01-01 00:00:00 UTC**, as produced by Swift's default JSON date encoder. `810388800` represents `2026-09-06T12:00:00Z`. Sentient normalizes this to an ISO 8601 `revisionTimestamp`, preserving milliseconds. It is a record update time, not an individual sample timestamp. A UUID `revision` breaks equal-time ties using Lattice's native lexicographic ordering.

`day` is a validated Gregorian civil date in `YYYY-MM-DD` form. No timezone is stored in this format. Sentient preserves the day and labels timezone `unknown`; it never invents UTC midnight. Missing optional fields and absent days remain unrecorded. An explicitly stored zero remains zero.

Check-in IDs are `checkin-<day>`. Mood is required; mood, energy, stress and focus must be integer ratings from 1 to 5. Caffeine can be 0–2,000 mg and outdoor time 0–1,440 minutes. Omitted optional values remain absent. The adapter maps `energy`, `stress`, and `focus` to `energyLevel`, `stressLevel`, and `focusQuality` attributes.

Aggregate IDs are `metric-<metric>-<day>`, with finite nonnegative values. Supported units come from Lattice's current `MetricKind` source:

| Metrics | Unit |
| --- | --- |
| `steps` | `steps` |
| `activeEnergy`, `restingEnergy` | `kcal` |
| `exerciseMinutes`, `standTime`, `mindfulMinutes`, `outdoorMinutes` | `min` |
| `distanceWalking` | `km` |
| `flightsClimbed` | `flights` |
| `heartRate`, `restingHeartRate`, `walkingHeartRate` | `bpm` |
| `hrv` | `ms` |
| `respiratoryRate` | `br/min` |
| `vo2Max` | `ml/kg·min` |
| `oxygenSaturation` | `%` |
| `bodyMass` | `kg` |
| `sleepHours`, `calendarBusyHours`, `meetingHours` | `hr` |
| `calendarEventCount` | `events` |
| `remindersCompleted` | `done` |
| `photosTaken` | `photos` |
| `mood`, `energyLevel`, `stressLevel`, `focusQuality` | `/5` |
| `caffeineMg` | `mg` |

Check-in metrics belong inside `checkIn`; they cannot be supplied as standalone aggregate records. Legacy note metrics and unknown metric names are rejected.

Deletion markers keep their ID/day and, for aggregates, metric, set `deleted: true`, and omit `value` and `checkIn`. They remove previous imported values and are never rendered as measured zero. Lattice also creates markers for retention expiry and successful empty source collection, so a marker does not establish why a value disappeared. A complete selected snapshot is authoritative for that imported file's records; a malformed snapshot makes no partial update.

Snapshots contain daily totals and self-reports, not raw HealthKit/FHIR records, calendar bodies, notes, or photos. Health collection is iPhone-only; the Mac can hold nearby-transferred totals. The snapshot does not prove current permissions, collection completeness, or current provider availability. Imported context identifies values as saved observations with record-update provenance, not fresh measurements.

## Interoperable metrics CSV

CSV is a separate, generic import contract; it is not described as native Lattice output. Export or prepare UTF-8 with this exact header order (all nine columns, case-sensitive):

```csv
id,metric,value,unit,date,timezone,updated_at,deleted,source
day-steps,steps,0,steps,2026-09-06,America/Chicago,2026-09-06T12:00:00Z,false,Manual
day-sleep,sleepHours,,hr,2026-09-06,,2026-09-06T12:00:00Z,false,Manual
old-steps,steps,,steps,2026-09-05,UTC,2026-09-06T12:30:00Z,true,Manual
```

- `id`: stable, nonempty ID; unique within the file. Reuse it for a correction.
- `metric`: nonempty metric name; generic names are allowed.
- `value`: finite decimal number, or empty for an unknown/unrecorded value. Negative numbers are permitted for generic metrics whose domain allows them. Zero is never substituted for an empty value.
- `unit`: explicit, nonempty unit. Use `1` for a dimensionless quantity. Sentient does not infer or convert CSV units.
- `date`: a real Gregorian `YYYY-MM-DD` civil date, or an ISO 8601 timestamp with an explicit UTC/offset zone.
- `timezone`: an IANA timezone such as `America/Chicago`, or `UTC`; blank means the named timezone is unknown. A date-only row never becomes an invented instant. Timestamp offsets remain in `date`.
- `updated_at`: required ISO 8601 timestamp with a UTC/offset zone. Increase it for corrections. The schema contains no independent revision token; equal-time conflicting updates are not an ordered edit history.
- `deleted`: exactly `true` or `false`. A deleted row must have an empty value.
- `source`: optional human-readable provenance, preserved as data.

RFC 4180 quoting supports commas, double quotes escaped as `""`, and newlines inside quoted fields. LF and CRLF line endings are accepted. Incomplete quotes, invalid UTF-8, a wrong header, extra/missing columns, duplicate IDs, invalid dates/zones, nonfinite numbers, or conflicting deletion/value fields reject the whole file. An optional UTF-8 BOM is accepted. Files are bounded to 64 MiB, 50,000 records, and 8,192 characters per field.

Keep the same configured source and row IDs when replacing a CSV with corrections. A complete CSV replaces that file's imported rows; explicit deletion rows preserve revision provenance. Personal CSV observations and unknown values stay local until the user enables sharing for that source.
