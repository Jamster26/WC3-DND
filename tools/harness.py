#!/usr/bin/env python3
"""Headless test driver: runs the real engine modules against mock_wc3.lua.

This is not a re-implementation of the rules — it loads src/*.lua unmodified,
installs a mock WC3, and lets the engine drive itself. If a native is missing,
a test fails with a Lua error naming it, which is precisely the failure mode we
cannot afford to discover in-game.
"""
from __future__ import annotations
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
_OFFSETS: list = []
ORDER = [
    "dnd_const.lua", "dnd_rawcodes.lua", "dnd_w3.lua", "dnd_dice.lua",
    "dnd_combatant.lua", "dnd_turns.lua", "dnd_resolve.lua", "dnd_combat.lua",
    "dnd_ui.lua", "dnd_ai.lua", "dnd_data.lua", "dnd_input.lua",
]

def translate(err: str) -> str:
    """lupa loads our modules into one chunk, so a Lua error reports a chunk-wide
    line number. Map it back to src/<file>.lua:<line> before the reader gives up."""
    m = re.search(r'\[string "<python>"\]:(\d+)', err)
    if not _OFFSETS:
        return err
    if not m:
        return err
    n = int(m.group(1))
    for name, start, span in _OFFSETS:
        if start <= n < start + span:
            return err.replace(m.group(0), f"src/{name}:{n - start + 1}")
    return err


TRACE_HELPER = r"""
-- TRACE_HELPER: run a body with a Lua-level traceback so an error names the
-- function it came from, not just lupa's chunk line number.
function tracedChunk(src, chunkname)
  local body = "return (function()\n" .. src .. "\nend)()"
  local f, err = loadstring(body, chunkname)
  if not f then return false, "compile: " .. tostring(err) end
  local ok, res = xpcall(f, function(e)
    return tostring(e) .. "\n" .. debug.traceback("", 2)
  end)
  if not ok then return false, tostring(res) end
  return true, res
end
"""

DRIVER = r"""
DND.testVerbose = false
-- The harness needs the player side to be playable without a human, so the AI
-- drives it. Same entry points a keypress uses; DND.ai is not a special path.
DND.config.aiPlaysParty = true
-- w3.after() runs its callback immediately under test, so the "you have nothing
-- left, turn over" convenience would close turns in the middle of an
-- assertion. Off here; on in the game.
DND.config.autoEndTurn = false
function runEncounter(partyKeys, foeKeys, seed, spacing)
  MOCK.reset()
  MOCK.reseed(seed or 12345)
  DND.Combatant.clearAll()
  local gap = spacing or DND.CONST.ft(60)
  local party, foes = {}, {}
  for i, k in ipairs(partyKeys) do
    local u = CreateUnit(0, DND.w3.cc(k:sub(1, 4)), -gap, (i - 1) * 64, 270)
    party[#party + 1] = DND.Data.spawn(k, -gap, (i - 1) * 64, { unit = u })
  end
  for i, k in ipairs(foeKeys) do
    local u = CreateUnit(1, DND.w3.cc(k:sub(1, 4)), gap, (i - 1) * 64, 90)
    foes[#foes + 1] = DND.Data.spawn(k, gap, (i - 1) * 64, { unit = u })
  end
  local all = {}
  for _, v in ipairs(party) do all[#all + 1] = v end
  for _, v in ipairs(foes) do all[#all + 1] = v end
  DND.Combat.startEncounter("Harness", all, {})
  return party, foes, all
end

--- Take the current turn to its end, whoever is holding it.
function playTurn()
  local S = DND.Combat.state
  local cbt = S.turn and S.turn.cbt
  if not cbt then return nil end
  if cbt.side == DND.CONST.SIDE.PARTY and not DND.config.aiPlaysParty then
    DND.Combat.endTurn(cbt)
  else
    DND.ai.takeTurn(cbt, function() DND.Combat.endTurn(cbt) end)
  end
  return cbt
end

function press(code)
  DND._mockKey = code
  DND.Input.press(code, 0)
end

function mouseClick(x, y)
  DND._mockMouse = { x = x, y = y }
  DND.Input.worldClick(0)
end

--- Runs N turns entirely inside Lua with a traceback hook, so a crash reports
--- the real src/*.lua line instead of lupa's chunk. This is how the harness
--- should have worked from the start.
function safeTurns(n)
  for _ = 1, n do
    if not DND.Combat.state.running then return "ended" end
    local ok, err = xpcall(playTurn, function(e)
      return tostring(e) .. " || " .. debug.traceback("", 2)
    end)
    if not ok then return "error", tostring(err) end
  end
  return DND.Combat.state.running and "running" or "ended"
end

function snapshot()
  local S = DND.Combat.state
  return {
    running = S.running, phase = S.phase,
    round = DND.Combat.turns.round, index = DND.Combat.turns.index,
    active = S.turn and S.turn.cbt and S.turn.cbt.name or "",
    logLines = #(DND.logLines or {}),
  }
end
"""


def boot(verbose: bool = False, seed: int = 12345):
    import lupa.lua51 as lupa
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    # mock first: the engine resolves natives as globals at call time, but
    # DND.testMode has to be set before any module body runs.
    lua.compile((ROOT / "tests" / "mock_wc3.lua").read_text(encoding="utf-8"),
                "tests/mock_wc3.lua")()
    g["MOCK"].reseed(seed)
    for name in ORDER:
        lua.execute((ROOT / "src" / name).read_text(encoding="utf-8"))
    lua.execute(f"DND.testVerbose = {'true' if verbose else 'false'}\n")
    for k, v in [("bj_MAX_PLAYERS", 16), ("EVENT_PLAYER_UNIT_ATTACKED", 18),
                 ("EVENT_PLAYER_UNIT_DAMAGED", 308), ("EVENT_PLAYER_UNIT_DEATH", 20),
                 ("UNIT_WEAPON_BF_ATTACKS_ENABLED", 0x7561656E),
                 ("FRAMEPOINT_TOPLEFT", 1), ("FRAMEPOINT_CENTER", 2),
                 ("ORIGIN_FRAME_GAME_UI", 0), ("FRAMEEVENT_CONTROL_CLICK", 1),
                 ("UNIT_STATE_LIFE", 0), ("UNIT_STATE_MAX_LIFE", 1)]:
        g[k] = v
    lua.compile(DRIVER, "tests/driver.lua")()
    lua.execute("""
-- In-game these come from common.j. A test that silently skips a code path
-- because a global was missing would be worse than no test, so we assert.
for _, n in ipairs({ "bj_MAX_PLAYERS", "EVENT_PLAYER_UNIT_ATTACKED",
                    "UNIT_STATE_LIFE", "UNIT_STATE_MAX_LIFE",
                    "FRAMEEVENT_CONTROL_CLICK" }) do
  if _G[n] == nil then error("mock is missing global: " .. n) end
end
if type(DND.Data) ~= "table" then error("Data module did not load") end
if DND.config == nil then error("DND.config was not bootstrapped by dnd_const") end
""")
    g["MOCK"].reset()
    return lua


def run_chunk(lua, src: str, chunkname: str = "<test>") -> None:
    """Run a Lua body with a real traceback attached to any error.

    Without this a failing test reports `[string "<python>"]:222` — a chunk-wide
    line number that sends you counting lines by hand. With it you get the
    function that threw and the frames above it.
    """
    g = lua.globals()
    g["__test_body"] = "return (function()\n" + src + "\nend)()"
    g["__test_chunk"] = chunkname
    lua.execute("""
local f, cerr = loadstring(__test_body, __test_chunk)
if not f then error("compile failed for " .. __test_chunk .. ": " .. tostring(cerr), 0) end
local ok, err = xpcall(f, function(e)
  return tostring(e) .. "\n" .. debug.traceback("", 2)
end)
if not ok then error(err, 0) end
""")


def log_lines(lua) -> list[str]:
    out = []
    arr = lua.globals().DND.logLines
    for i in range(1, 100000):
        v = arr[i]
        if v is None:
            break
        out.append(str(v))
    return out


def run(lua, n=60):
    for _ in range(n):
        try:
            lua.execute("playTurn()")
        except Exception as e:  # noqa: BLE001
            raise AssertionError(translate(str(e))) from None
    return None


def state(lua) -> dict:
    raw = lua.execute("""
      local a={0,0}
      for _,c in ipairs(DND.Combatant.all()) do if c.hp>0 then a[c.side+1]=a[c.side+1]+1 end end
      return string.format("%d|%d|%s|%d", a[1], a[2],
        tostring(DND.Combat.state.running), DND.Combat.turns.round)""")
    p, f, running, rnd = str(raw).split("|")
    return {"party": int(p), "foes": int(f), "running": running == "true", "round": int(rnd)}


def fight(lua, party, foes, seed=999, turns=60):
    """Start an encounter and run it. Any Lua error becomes an AssertionError
    whose message names the real src/*.lua line — that is the whole point."""
    try:
        lua.execute(f"runEncounter({{{','.join(repr(x) for x in party)}}},"
                    f" {{{','.join(repr(x) for x in foes)}}}, {seed})")
    except Exception as e:  # noqa: BLE001
        raise AssertionError(translate(str(e))) from None
    return run(lua, turns)


if __name__ == "__main__":
    lua = boot(verbose="--verbose" in sys.argv)
    lua.execute("runEncounter({'goblin','goblin'}, {'humanFighter'}, 999)")
    for i in range(40):
        lua.execute("playTurn()")
    for line in log_lines(lua)[-45:]:
        print(line)
    print("--- snapshot:", dict(lua.eval("snapshot() and {snapshot().running, snapshot().round, snapshot().active}")))
