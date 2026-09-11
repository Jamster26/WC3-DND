#!/usr/bin/env python3
"""One command to prove the engine is sound. Run this before saying "done".

  python3 tools/all.py

Gates, in the order that fails fastest:
  1. syntax          every Lua file parses under the Lua 5.1 grammar, and uses
                     no construct WC3's VM lacks (5.2+ syntax, bit.*, //)
  2. natives         every global the code calls is a real common.j native, a
                     Blizzard.j function, or one of ours -- including war3map.lua
  3. members         every DND.X.y call resolves to a definition
  4. colons/pairs    the two idioms that produce "attempt to index a nil value"
                     several frames from the actual bug
  5. build           splice src/*.lua into dist/war3map.lua
  6. tests           15 groups against the mock WC3, incl. an AI-vs-AI soak
"""
import subprocess
import sys
import pathlib
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent

STEPS = [
    ("syntax", ["python3", "tools/check.py", "src"]),
    ("natives", ["python3", "tools/lint_natives.py"]),
    ("members", ["python3", "tools/lint_members.py"]),
    ("lua idioms", ["python3", "tools/lint_colons.py"]),
    ("object data", ["python3", "tools/gen_data_js.py"]),
    ("build", ["python3", "tools/build.py"]),
    ("tests", ["python3", "tests/test_engine.py"]),
]


def main() -> int:
    failed = []
    t0 = time.time()
    for label, cmd in STEPS:
        t = time.time()
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        dt = time.time() - t
        ok = r.returncode == 0
        out = (r.stdout + r.stderr).strip().splitlines()
        tail = out[-1] if out else ""
        print(f"  {'✓' if ok else '✗'} {label:12s} {dt:5.1f}s  {tail[:78]}")
        if not ok:
            failed.append(label)
            for line in out[-14:]:
                print(f"      {line}")
    print(f"\n{'ALL GATES PASSED' if not failed else 'FAILED: ' + ', '.join(failed)}"
          f"  ({time.time() - t0:.1f}s)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
