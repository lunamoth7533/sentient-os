#!/usr/bin/env python3
"""Exercise the real app binary without UI, telemetry, cloud calls, or production stores."""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

binary = pathlib.Path(sys.argv[1]).resolve()
fixtures = pathlib.Path(__file__).resolve().parents[1] / "Fixtures"
checks = []
started = time.monotonic()
with tempfile.TemporaryDirectory(prefix="sentient-app-flow-") as temporary:
    root = pathlib.Path(temporary)
    store = root / "private" / "evidence.sqlite"
    def run(*arguments, expected=0):
        result = subprocess.run([str(binary), "--context-store", str(store), *arguments], capture_output=True, text=True, timeout=45)
        assert result.returncode == expected, (arguments, result.returncode, result.stderr, result.stdout)
        return result.stdout
    source = root / "codex.jsonl"
    shutil.copyfile(fixtures / "Sessions" / "codex.jsonl", source)
    initial = json.loads(run("--context-import", "codex", "--path", str(source)))
    repeated = json.loads(run("--context-import", "codex", "--path", str(source)))
    assert initial["records"] == repeated["records"] > 0
    checks.append("initial/repeat/restart native Codex import")
    addition = {"timestamp":"2026-01-02T10:00:00Z", "ordinal":9, "type":"response_item", "payload":{"type":"message","id":"continuation","role":"user","content":[{"type":"input_text","text":"Next action: verify durable recovery with synthetic evidence."}]}}
    with source.open("a") as handle:
        handle.write(json.dumps(addition) + "\n")
    appended = json.loads(run("--context-import", "codex", "--path", str(source)))
    assert appended["records"] == initial["records"] + 1
    answer = run("--context-query", "durable recovery", "--project", "/synthetic/alpha", "--budget", "1024")
    assert "verify durable recovery" in answer and len(answer.encode()) <= 1025
    checks.append("appended session and budgeted project retrieval")
    with source.open("a") as handle:
        handle.write('{"partial":')
    partial = json.loads(run("--context-import", "codex", "--path", str(source), expected=2))
    assert partial["state"] == "partial" and partial["records"] == appended["records"]
    source.write_text(source.read_text().removesuffix('{"partial":'))
    assert json.loads(run("--context-import", "codex", "--path", str(source)))["state"] == "complete"
    checks.append("partial write preserves records and retries")
    lines = source.read_text().splitlines()
    source.write_text("\n".join(lines[:-1]) + "\n")
    run("--context-import", "codex", "--path", str(source))
    assert "verify durable recovery" not in run("--context-query", "durable recovery", "--project", "/synthetic/alpha")
    projection = "\n".join(p.read_text() for p in (store.parent / "Imported").rglob("*.md"))
    assert "verify durable recovery" not in projection
    checks.append("source deletion reaches retrieval and graph projection")
    for kind, name in [("lattice", "capsule.json"), ("lattice", "personal-snapshot.json"), ("metricsCSV", "metrics.csv")]:
        path = root / name
        shutil.copyfile(fixtures / "Lattice" / name, path)
        assert json.loads(run("--context-import", kind, "--path", str(path)))["state"] == "complete"
    assert "synthetic checks passed" in run("--context-query", "Three synthetic checks")
    assert "0" in run("--context-query", "steps")
    assert "synthetic checks passed" not in run("--context-query", "Three synthetic checks", "--shared")
    checks.append("Lattice Workbench and personal metrics stay local by default")
    frames = [
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}},
        {"jsonrpc":"2.0","method":"notifications/initialized"},
        {"jsonrpc":"2.0","id":2,"method":"tools/list"},
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_context","arguments":{"query":"artificial build","budget":1024}}},
        {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_context_sources","arguments":{}}},
    ]
    for local in [False, True]:
        args = [str(binary), "--context-store", str(store), "--context-mcp"] + (["--local-context"] if local else [])
        result = subprocess.run(args, input="".join(json.dumps(f) + "\n" for f in frames), capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stderr
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        assert len(responses) == 4 and all(r["jsonrpc"] == "2.0" for r in responses)
        assert {tool["name"] for tool in responses[1]["result"]["tools"]} == {"search_context", "list_context_sources", "get_context_evidence"}
        answer = responses[2]["result"]["content"][0]["text"]
        assert ("Inspect the artificial build" in answer) == local
        assert len(answer.encode()) <= 1024
        catalog = json.loads(responses[3]["result"]["content"][0]["text"])
        assert len(catalog["sources"]) == (4 if local else 0)
        if local:
            citation = re.search(r"\[([0-9a-f]{12})\]", answer).group(1)
            codex = next(s for s in catalog["sources"] if s["kind"] == "codex")
            assert codex["projects"][0]["id"] == "/synthetic/alpha"
    # A citation obtained locally must still be denied by a separately connected shared client.
    for local in [False, True]:
        inspect_frames = frames[:2] + [{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_context_evidence","arguments":{"id":citation,"budget":1024}}}]
        args = [str(binary), "--context-store", str(store), "--context-mcp"] + (["--local-context"] if local else [])
        result = subprocess.run(args, input="".join(json.dumps(f) + "\n" for f in inspect_frames), capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stderr
        inspected = json.loads(result.stdout.splitlines()[-1])["result"]
        assert inspected["isError"] == (not local)
        if local:
            assert "Inspect the artificial build" in inspected["content"][0]["text"]
            assert len(inspected["content"][0]["text"].encode()) <= 1024
    checks.append("real stdio MCP negotiation, tools and fixed audience")
    checks.append("real MCP source catalog and permission-checked citation inspection")
    assert source.exists()
    assert (store.stat().st_mode & 0o777) == 0o600
    checks.append("original sources preserved; private store permissions")
print(json.dumps({"checks":checks,"passed":len(checks),"seconds":round(time.monotonic()-started,3)}, indent=2))
