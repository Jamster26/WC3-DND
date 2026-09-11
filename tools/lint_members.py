#!/usr/bin/env python3
"""Gate: every `Namespace.member` the engine calls must actually be defined.

WC3 maps have no module system, no linker and no type checker — a method name
typo is a runtime `attempt to call a nil value` that only fires when the player
happens to press that button. This walks the flat namespace and reports every
reference with no definition, so those bugs die here instead.

Usage: python3 tools/lint_members.py [--verbose]
"""
import re
import sys
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

# namespace -> (its defining file marker, extra aliases used inside that file)
ALIASES = {
    "C": ["C"],
    "w3": ["w3"],
    "Dice": ["Dice"],
    "Combatant": ["Combatant"],
    "Turns": ["Turns"],
    "Resolve": ["Resolve"],
    "Combat": ["Combat"],
    "ui": ["ui"],
    "AI": ["AI"],
    "Data": ["Data"],
    "Input": ["Input"],
    "MOCK": ["M"],
}

# Fields that legitimately live on a namespace table but are not functions, so
# a `Ns.field` read is not a missing definition.
NON_FUNCTION_MEMBERS = {
    ("Combat", "debug"), ("Combat", "state"), ("Combat", "turns"),
    ("Data", "Bestiary"), ("Data", "Encounters"), ("Data", "Spells"),
    ("Data", "Party"), ("ui", "frames"), ("ui", "state"), ("ui", "enabled"),
    ("Dice", "debug"), ("AI", "thinkDelay"), ("AI", "maxActions"), ("AI", "samples"),
    ("Input", "keys"), ("Input", "commands"), ("Input", "stepFt"),
}


def members_of(aliases, srcs):
    defined = set()
    for a in aliases:
        for src in srcs:
            defined |= set(re.findall(rf"^function\s+{a}\.(\w+)", src, re.M))
            defined |= set(re.findall(rf"^\s*{a}\.(\w+)\s*=", src, re.M))
            # locals assigned inside a function still count as "provided"
            defined |= set(re.findall(rf"\b{a}\.(\w+)\s*=\s*function", src, re.M))
    return defined


def refs_of(alias, srcs):
    out = set()
    for a in alias:
        for src in srcs:
            out |= set(re.findall(rf"\b{a}\.(\w+)", src))
    return out


def main() -> int:
    verbose = "--verbose" in sys.argv
    srcs = []
    for f in sorted((ROOT / "src").glob("*.lua")):
        t = f.read_text(encoding="utf-8")
        t = re.sub(r"--\[\[.*?\]\]", "", t, flags=re.S)
        t = re.sub(r"--[^\n]*", "", t)
        srcs.append(t)
    for f in sorted((ROOT / "tests").glob("*.lua")):
        srcs.append(f.read_text(encoding="utf-8"))

    rc = 0
    for ns, aliases in ALIASES.items():
        all_aliases = aliases + [ns]
        defined = members_of(all_aliases, srcs)
        refs = refs_of(all_aliases, srcs)
        # DND.<Ns>.member is covered by the plain <Ns>.member scan
        missing = sorted(r for r in refs
                         if r not in defined
                         and (ns, r) not in NON_FUNCTION_MEMBERS
                         and r not in {"new", "get"})
        if missing:
            rc = 1
            print(f"DND.{ns}: referenced with no definition -> {', '.join(missing)}")
        elif verbose:
            print(f"DND.{ns}: {len(defined)} members, all references resolve")

    # duplicate definitions = a silent shadowing bug. Count by (file, alias)
    # so the same definition reached through both `AI.x` and `DND.ai.x` is not
    # reported twice, which is exactly what an alias is for.
    dup = {}
    for ns, aliases in ALIASES.items():
        for i, src in enumerate(srcs):
            seen: dict[str, set[tuple[int, str]]] = {}
            for a in set(aliases + [ns]):
                for m in re.finditer(rf"^function\s+{a}\.(\w+)", src, re.M):
                    seen.setdefault(m.group(1), set()).add((i, a))
            for name, origins in seen.items():
                # same file + two aliases that point at one table = fine
                files = {o[0] for o in origins}
                if len(origins) > 1 and len(files) > 1:
                    rc = 1
                    dup.setdefault(ns, []).append((name, len(origins), sorted(files)))
    if dup:
        for ns, items in dup.items():
            for name, n, files in items:
                print(f"DND.{ns}.{name}: defined {n}x across {len(files)} files "
                      f"(the later one silently wins)")

    if not rc:
        print("OK — every namespaced call resolves to a definition")
    return rc


if __name__ == "__main__":
    sys.exit(main())
