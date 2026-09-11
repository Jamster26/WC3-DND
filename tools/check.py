#!/usr/bin/env python3
"""Fast syntax gate for every Lua file in the project (LuaJIT 5.1 grammar).

Usage:  python3 tools/check.py [dir ...]
Runs `luac -p`-equivalent parse checks plus a few project lint rules
(forbidden Lua 5.2+ constructs that WC3's 5.1 VM will not compile).
"""
import re
import sys
import pathlib
from luaparser import ast

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Constructs the WC3 Lua 5.1 VM does not understand.
BANNED = [
    (re.compile(r"\d+//\d+|\ba\s*//\s*b\b"), "integer division // (5.2+)"),
    (re.compile(r"\bgoto\b"),                "goto (5.2+)"),
    (re.compile(r"\bcontinue\b"),             "continue keyword (not Lua at all)"),
    (re.compile(r"\btable\.pack\b"),          "table.pack (5.2+)"),
    (re.compile(r"\btable\.unpack\b"),        "table.unpack (5.2+; use unpack)"),
    (re.compile(r"\bbit\.\w+"),               "bit.* (not guaranteed in WC3)"),
    (re.compile(r"\bmath\.tointeger\b"),      "math.tointeger (5.3+)"),
    (re.compile(r"\bstring\.pack\b"),         "string.pack (5.3+)"),
    (re.compile(r"\butf8\.\w+"),              "utf8 library (5.3+)"),
]


def check_file(path: pathlib.Path) -> list[str]:
    problems: list[str] = []
    text = path.read_text(encoding="utf-8")
    try:
        ast.parse(text)
    except Exception as exc:  # noqa: BLE001 - parser raises assorted types
        first = str(exc).strip().splitlines()
        problems.append(f"{path.name}: PARSE ERROR: {first[0] if first else exc}")
        return problems
    for lineno, line in enumerate(text.splitlines(), 1):
        code = re.sub(r"--\[\[.*?\]\]", "", line)
        code = code.split("--", 1)[0]
        for rx, why in BANNED:
            if rx.search(code):
                problems.append(f"{path.name}:{lineno}: banned construct: {why}")
    return problems


def main() -> int:
    targets = [pathlib.Path(a) for a in sys.argv[1:]] or [ROOT]
    files: list[pathlib.Path] = []
    for t in targets:
        if t.is_dir():
            files += sorted(t.rglob("*.lua"))
        else:
            files.append(t)
    if not files:
        print("no lua files found")
        return 1

    problems: list[str] = []
    for f in files:
        problems += check_file(f)

    for p in problems:
        print("  ✗", p)
    print(f"checked {len(files)} file(s) -> {'OK' if not problems else str(len(problems)) + ' problem(s)'}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
