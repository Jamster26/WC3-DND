--[[ =========================================================================
  dnd_turns.lua — initiative and the round cycle.

  WC3 gives us nothing turn-shaped, so we keep the whole order ourselves:
  a flat list of {combatant, initiativeScore} walked one entry at a time.
  Skipping the dead, the stunned and the unconscious happens here, not in the
  state machine, so nothing can ever be "stuck" on a turn it cannot take.
========================================================================== ]]
DND = DND or {}
DND.Turns = {}
local Turns = DND.Turns
local C = DND.CONST
local Dice = DND.Dice

function Turns.new()
  return { order = {}, index = 0, round = 0, started = false, rerolled = 0 }
end

--- Roll for initiative and build the running order.
--- Tie-break: DEX mod, then a d100 coin flip (5e: DM may let them act in any
--- order; the coin keeps it fair and automated).
function Turns.rollOrder(t, combatants)
  t.order = {}
  for _, cbt in ipairs(combatants) do
    local ini = Dice.initiative(cbt.initiative, cbt.order)
    cbt.initScore = ini.score
    cbt.initNatural = ini.natural
    cbt.init = ini
    t.order[#t.order + 1] = { cbt = cbt, score = ini.score,
                              dex = cbt.initiative, coin = ini.coin,
                              nat = ini.natural }
  end
  table.sort(t.order, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    if a.dex ~= b.dex then return a.dex > b.dex end
    if a.coin ~= b.coin then return a.coin > b.coin end
    return a.cbt.cid < b.cbt.cid
  end)
  t.index = 0
  t.started = true
  return t.order
end

--- The next living creature's turn, wrapping into a new round as needed.
function Turns.next(t)
  if not t.started or #t.order == 0 then return nil end
  local guard = 0
  while true do
    t.index = t.index + 1
    if t.index > #t.order then
      t.index = 1
      t.round = t.round + 1
      DND.logf("--- ROUND %d ---", t.round)
    end
    local entry = t.order[t.index]
    if not entry then return nil end
    local cbt = entry.cbt
    guard = guard + 1
    if guard > #t.order * 3 then return nil end      -- paranoia: never hang
    if cbt.hp > 0 and not cbt.removed and not cbt.incapacitated then
      return entry
    end
    -- dead / stable / incapacitated: skip, but still let a round advance
  end
end

function Turns.current(t) return t.order[t.index] end

function Turns.peek(t, n)
  local out, i = {}, t.index
  local guard = 0
  while #out < (n or 4) and guard < 24 do
    guard = guard + 1
    i = i + 1
    if i > #t.order then i = 1 end
    local e = t.order[i]
    if e then out[#out + 1] = e end
  end
  return out
end

--- A side-to-side view for the tracker widget: who is up, who is down.
function Turns.summary(t)
  local lines = {}
  for i, e in ipairs(t.order) do
    local cbt = e.cbt
    local mark
    if cbt.hp <= 0 then mark = "|cffff5555X|r"
    elseif i == t.index then mark = "|cfffff020>" .. "|r"
    elseif i < t.index then mark = "|cff808080 | " .. "|r"
    else mark = "  " end
    lines[#lines + 1] = string.format("%s %s|cffffcc00%d|r %s",
      mark, cbt.side == C.SIDE.PARTY and "|cff66ccff" or "|cffff8866",
      e.score, cbt.name)
  end
  return lines
end

--- DM tool: force an order change mid-fight (surprise rounds, Ready actions).
function Turns.promote(t, cbt, beforeWhich)
  for i, e in ipairs(t.order) do
    if e.cbt == cbt then
      table.remove(t.order, i)
      local at = beforeWhich or 1
      table.insert(t.order, at, e)
      if i <= t.index then t.index = t.index - 1 end
      t.rerolled = t.rerolled + 1
      return true
    end
  end
  return false
end

--- Surprise: the classic first round where only the alert side acts.
function Turns.surprise(t, actorsFirst, sleepers)
  local keep = {}
  for _, cbt in ipairs(actorsFirst) do
    for i, e in ipairs(t.order) do
      if e.cbt == cbt then keep[i] = true end
    end
  end
  t.surprise = keep
  DND.logf("Surprise round: %d creature(s) act, %d are caught flat-footed.",
    (function() local n = 0 for _ in pairs(keep) do n = n + 1 end return n end)(),
    #t.order - (function() local n = 0 for _ in pairs(keep) do n = n + 1 end return n end)())
  return true
end

return Turns
