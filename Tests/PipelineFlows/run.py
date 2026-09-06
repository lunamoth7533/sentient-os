#!/usr/bin/env python3
"""Run synthetic ingestion, command, capture, and completion regression checks."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent
failed = []
for name in ["controller.py", "processing.py", "scheduler.py", "proactive.py", "commands.py", "capture.py", "status.py", "streams.py"]:
    result = subprocess.run([sys.executable, str(root / name)], timeout=150)
    if result.returncode:
        failed.append(name)
if failed:
    print("Failed pipeline runners: " + ", ".join(failed), file=sys.stderr)
    raise SystemExit(1)
print("PASS all eight pipeline runners")
