"""Verify native export -> real headless importer -> durable cited evidence, using only temp data."""
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import sys


def require(value, message):
    if not value:
        raise AssertionError(message)


def main():
    binary, root = Path(sys.argv[1]), Path(sys.argv[2]).resolve()
    capsule = root / "native-capsule.json"
    store = root / "context" / "evidence.sqlite"
    binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()

    def run(*args, input_text=None):
        result = subprocess.run(
            [str(binary), "--context-store", str(store), *args],
            input=input_text, text=True, capture_output=True, timeout=30,
        )
        require(result.returncode == 0, f"Headless command failed: {result.stderr.strip()}")
        return result.stdout

    imported = json.loads(run("--context-import", "lattice", "--path", str(capsule)))
    require(imported["state"] == "complete" and imported["records"] == 4,
            "Native capsule was not fully imported (context + two events + release)")
    sources = json.loads(run("--context-sources"))
    require(len(sources) == 1 and sources[0]["kind"] == "lattice" and not sources[0]["shareEnabled"],
            "Native import did not retain explicit local-only sharing defaults")
    print("PASS real app import: four records, one source, sharing off")

    # A second independent app process reopens the same store and must not duplicate records.
    run("--context-import", "lattice", "--path", str(capsule))
    with sqlite3.connect(store) as connection:
        rows = connection.execute("SELECT record_id,payload FROM records").fetchall()
    require(len(rows) == 4, "Reimport duplicated native records")
    records = {identifier: json.loads(payload) for identifier, payload in rows}
    decision_id = "project:native-roundtrip:event:decision"
    require(decision_id in records and records[decision_id]["project"] == "native-roundtrip",
            "Native project/event identity was lost")
    require(records[decision_id]["role"] == "summary" and records[decision_id]["provider"] == "lattice",
            "Curated native capsule attribution was promoted or relabeled")
    print("PASS durable reopen/reimport: stable native identities, no duplicates")

    query = run("--context-query", "cobalt", "--project", "native-roundtrip")
    require("preserve the synthetic cobalt records" in query and "| summary | lattice | native-roundtrip" in query,
            "Query lost the native decision or its summary attribution")
    require("2026-09-06T15:00:00Z" in query and str(capsule) in query,
            "Citation lost its recorded instant or original capsule reference")
    match = re.search(r"^\[([a-f0-9]{12})\]", query, re.MULTILINE)
    require(match is not None, "Query returned no evidence citation")
    evidence_id = match.group(1)
    (root / "query.txt").write_text(query)
    print(f"PASS cited query: [{evidence_id}], native date/project/role/reference retained")

    failure = run("--context-query", "completion", "--project", "native-roundtrip")
    require("status=failed" in failure and "completion remains unverified" in failure,
            "Native failed work was presented as completed")
    shared = run("--context-query", "cobalt", "--shared")
    require(re.search(r"^\[[a-f0-9]{12}\]", shared, re.MULTILINE) is None and "cobalt" not in shared,
            "Local-only producer data crossed the shared-query boundary")
    print("PASS failed status and default shared exclusion")

    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25"}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
            "name": "get_context_evidence", "arguments": {"id": evidence_id}
        }},
    ]
    response = run("--context-mcp", "--local-context", input_text="".join(json.dumps(r) + "\n" for r in requests))
    replies = [json.loads(line) for line in response.splitlines()]
    resolved = next(r for r in replies if r.get("id") == 2)["result"]
    require(not resolved.get("isError"), "Returned citation cannot be resolved by the real MCP bridge")
    text = resolved["content"][0]["text"]
    require("preserve the synthetic cobalt records" in text and "Source-provided summary" in text,
            "Evidence lookup lost source attribution or native content")
    require(hashlib.sha256(binary.read_bytes()).hexdigest() == binary_hash,
            "The app binary changed during verification; rerun against a stable build")
    print("PASS real app MCP citation lookup")
    print("Lattice native producer roundtrip: 6 checks passed; no live storage or network used")


if __name__ == "__main__":
    main()
