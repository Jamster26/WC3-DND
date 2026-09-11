#!/usr/bin/env python3
"""Gate: no colon-calls, and no dot-calls, on combatant tables.

Combatants are plain data, so a *method-style* call on one is a bug whatever
the punctuation: `cbt:saveBonus(x)` and `target.saveBonus(x)` both explode, and
both are invisible until the rules path that reaches them finally runs. We
collect every namespace function name and flag any call of it on a variable we
know to be a combatant.

Combatants are plain Lua tables with no metatable (deliberately: they are
data, and a metatable would make them invisible to BlzGetTriggerFrame-style
debugging and easy to shadow). So `cbt:method()` is always a bug — it raises
"attempt to call a nil value" only when that exact rules path runs, which in
this project means "when the player is unconscious", i.e. never in a smoke test.

Also flags colon-calls on the other native-free data objects (pending, unit).
"""
import re
import sys
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

# variables that are always plain tables in this codebase
TABLE_VARS = ("cbt", "attacker", "target", "mover", "foe", "ally", "other",
              "healer", "pending", "entry", "res", "u", "unit")
RX = re.compile(r"(?<![\w.])(%s)[:.](\w+)\s*\(" % "|".join(TABLE_VARS))

# functions that live on a namespace, not on the object
NAMESPACE_FN = {
    "saveBonus", "spellSaveDc", "spellAttack", "primaryAttack", "speedUnits",
    "hpScaled", "ac", "reachUnits", "statline", "conditionSaves", "addCond",
    "removeCond", "hasCond", "isFoeOf", "living", "get", "byId", "sync",
}


def main() -> int:
    verbose = "--verbose" in sys.argv
    hits = []
    for f in sorted((ROOT / "src").glob("*.lua")):
        text = f.read_text(encoding="utf-8")
        for i, line in enumerate(text.splitlines(), 1):
            code = re.sub(r"--[^\n]*", "", line)
            for m in RX.finditer(code):
                sep, fn = m.group(0), m.group(2)
                if sep.endswith(".") and fn not in NAMESPACE_FN:
                    continue          # plain field read: cbt.hp is fine
                if sep.endswith(".") and ".unit" in code:
                    pass
                hits.append((f.name, i, m.group(0).strip(), line.strip()[:78]))
    if hits:
        print(f"{len(hits)} colon-call(s) on a plain table (use Namespace.fn(obj, ...)):")
        for name, ln, frag, ctx in hits:
            print(f"  {name}:{ln}: {frag}")
            print(f"      {ctx}")
        return 1
    if verbose:
        print("OK — no colon-calls on plain tables")
    return 0


if __name__ == "__main__":
    sys.exit(main())


# ---------------------------------------------------------------------------
# Second gate bundled here: mutating a table while pairs() is iterating it.
# In Lua 5.1 removing a field during traversal is undefined behaviour and can
# hand the loop a nil on the next step — which reads as "attempt to index a nil
# value" several frames later, in code that looks innocent.
# ---------------------------------------------------------------------------
def check_pairs_mutation(root: pathlib.Path) -> list[str]:
    problems = []
    for f in sorted((root / "src").glob("*.lua")):
        lines = f.read_text(encoding="utf-8").splitlines()
        depth_stack = []           # open for-blocks keyed by indent
        for i, raw in enumerate(lines):
            line = re.sub(r"--[^\n]*", "", raw)
            m = re.search(r"for\s+\w+(,\s*\w+)?\s+in\s+pairs\((\w+(?:\.\w+)*)\)", line)
            if m:
                depth_stack.append({"tbl": m.group(2), "start": i, "depth": 0})
                continue
            if depth_stack:
                for frame in depth_stack:
                    nxt = line.strip()
                    if re.match(r"^\s*(function|for|if|while|do)\b", nxt):
                        frame["depth"] += 1
                    t = frame["tbl"]
                    if re.search(rf"\b{re.escape(t)}\s*\[[^\]]+\]\s*=\s*nil", line) or \
                       re.search(rf"\b(removeCond|addCond)\s*\(\s*{t.split('.')[-1]}\b", line) or \
                       re.search(rf"\btable\.remove\s*\(\s*{re.escape(t)}\b", line):
                        problems.append(
                            f"{f.name}:{i+1}: mutates {t} inside pairs() "
                            f"(opened at line {frame['start']+1})")
                depth_stack = [d for d in depth_stack
                               if re.match(r"^\s*end\b", line) is None or True]
                if re.match(r"^\s*end\b", lines[i].strip()):
                    for j in range(len(depth_stack) - 1, -1, -1):
                        if depth_stack[j]["depth"] == 0:
                            del depth_stack[j]
                            break
                        depth_stack[j]["depth"] -= 1
    return problems


if __name__ == "__main__":
    extra = check_pairs_mutation(ROOT)
    for p in extra:
        print("  ✗", p)
    if extra:
        sys.exit(1)
