#!/usr/bin/env python3
"""Delve soak: play the whole ladder many times and report what actually happens.

    python3 tools/soak.py [--seeds 12] [--rungs 6] [--cap 300]

Every run is a full delve: four rooms, AI on both sides, the party carried from
room to room, the turn loop capped so a stall is a *finding* and not a hung script.
Nothing here re-implements a rule — it boots the shipped modules against
tests/mock_wc3.lua and calls Data.startEncounter, the function `-delve` calls.

Why this exists: more than once, a balance change in this project was justified by a
sentence about how the rest economy *should* feel, and the soak said otherwise. The
numbers this prints are the only argument the delve accepts, which is why the tool is
in the repo and the README quotes its output instead of my prose.
"""
from __future__ import annotations

import argparse
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import harness  # noqa: E402

LUA = r"""
DND.config.useVanillaModels = true
DND.config.aiEnabled = true
DND.config.aiPlaysParty = true

local cells, perRung = {}, {}

local function rungLine(rung, nRuns, wipes, cleared)
  perRung[#perRung + 1] = string.format(
    "  delve%-2d  %2d runs  wiped %2d (%2.0f%%)  cleared the last room %2d times",
    rung, nRuns, wipes, 100 * wipes / math.max(1, nRuns), cleared)
end

local function cell(label, rest, partyKeys, seeds, rungs, cap)
  local nRuns, nRooms, wipes, stalls = 0, 0, 0, 0
  local deaths = { 0, 0, 0, 0 }
  local turns, rounds = {}, {}

  local byRung = {}
  for seed = 1, seeds do
    for rung = 1, rungs do
      local R = byRung[rung] or { runs = 0, wipes = 0, cleared = 0 }
      byRung[rung] = R
      R.runs = R.runs + 1
      local rn = 0
      MOCK.reset(); MOCK.reseed(seed * 15485863 + rung * 977)
      DND.Combatant.clearAll(); DND.Data.CarriedParty = {}; DND.Data.Delve = {}
      DND.logLines = {}
      -- nil here means "no override": the delve row's own corridorRest decides.
      DND.config.restBetweenRooms = rest
      nRuns = nRuns + 1
      local died = 0

      for room = 1, DND.Data.DelveLength do
        local rec = DND.Data.startEncounter("delve" .. rung, {
          encounter = room,
          party = (room == 1 and partyKeys) or nil,   -- only room 1 may pick a party
          atLevel = 3,
        })
        if not rec then break end
        rn = rn + 1
        nRooms = nRooms + 1
        local t = 0
        while DND.Combat.state.running and t < cap do safeTurns(1) t = t + 1 end
        if DND.Combat.state.running then stalls = stalls + 1 end
        turns[#turns + 1] = t
        rounds[#rounds + 1] = (DND.Combat.turns and DND.Combat.turns.round) or 0
        local s = DND.Data.delveState("delve" .. rung)
        if s.wipe then
          died = died + 1
          deaths[room] = (deaths[room] or 0) + 1
          break
        end
      end
      if died > 0 then
        wipes = wipes + 1
        R.wipes = R.wipes + 1
      elseif rn >= DND.Data.DelveLength then
        R.cleared = R.cleared + 1        -- four rooms paid for, boss room and all
      end
    end
  end

  table.sort(turns); table.sort(rounds)
  local function at(a, q) return a[math.max(1, math.floor(#a * q) + 1)] or 0 end
  local head = string.format("%-28s %3d delves %4d rooms  wiped %3d (%2.0f%%)",
    label, nRuns, nRooms, wipes, 100 * wipes / math.max(1, nRuns))
  local tail = string.format("deaths by room %d %d %d %d   rounds/room med %d p95 %d max %d"
    .. "   stalls %d",
    deaths[1], deaths[2], deaths[3], deaths[4],
    at(rounds, 0.5), at(rounds, 0.95), rounds[#rounds] or 0, stalls)
  cells[#cells + 1] = head .. "   " .. tail
  cells[#cells + 1] = "   per rung (" .. seeds .. " seeds each), no rest vs the delve's 2h:"
  for rung = 1, rungs do
    local a, b = byRung[rung] or {}, nil
    cells[#cells + 1] = string.format(
      "  delve%-2d  %2d runs  wiped %2d (%2.0f%%)  reached the boss room and lived: %d",
      rung, a.runs or 0, a.wipes or 0, 100 * (a.wipes or 0) / math.max(1, a.runs or 1),
      a.cleared or 0)
  end
  cells[#cells + 1] = ""
end

local parts = PARTIES
for _, spec in ipairs(parts) do
  cell(spec[1], spec[2], spec[3], SEEDS, RUNGS, CAP)
end
return table.concat(cells, "\n")
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seeds", type=int, default=12)
    ap.add_argument("--rungs", type=int, default=6)
    ap.add_argument("--cap", type=int, default=300,
                    help="creature-turns before a room is called a stall")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    # (label, restBetweenRooms, party)  — `None` = leave it to the encounter row
    parties = [
        ("rolled heroes, no rest", "false", "nil"),
    ("rolled heroes, 1h corridor", "1", "nil"),
    ("rolled heroes, 2h (-delve)", "nil", "nil"),
    ("preset rows (L3 heroes), 2h", "nil", '"heroes"'),
    ("preset rows (L3 heroes), none", "false", '"heroes"'),
]
    rows = ",".join("{%r,%s,%s}" % (label, rest, party)
                    for label, rest, party in parties)

    lua = harness.boot(verbose=not args.quiet)
    t0 = time.time()
    src = (LUA.replace("SEEDS", str(args.seeds))
              .replace("RUNGS", str(args.rungs))
              .replace("CAP", str(args.cap))
              .replace("PARTIES", "{" + rows + "}"))
    print(lua.compile(src, "tools/soak")())
    print("\n%d seeds x %d rungs x %d cells in %.1fs  (delve rooms: start, fight, XP, "
          "level-ups, carry)" % (args.seeds, args.rungs, len(parties), time.time() - t0))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
