--[[ =========================================================================
  dnd_dice.lua — the RNG and every roll the game makes.

  One rule drives this file: NEVER call math.random(). In WC3 the Lua state is
  shared with the game's own seeded RNG, and in any multiplayer-capable build a
  client-local RNG desyncs instantly. We roll through GetRandomInt, and the
  test harness replaces that one function with a seeded stream so fights are
  byte-for-byte reproducible.
========================================================================== ]]
DND = DND or {}
DND.Dice = {}
local Dice = DND.Dice
local C = DND.CONST

Dice.debug = false          -- print every die face to the log
local stream = {}           -- deterministic queue used by the test harness
local streamIdx = 1

--- Script the RNG for a test. Values are consumed in order; once they run out
--- the LAST value repeats forever. That is the convention that makes a test
--- readable: script({20}) means "this attack is a critical", whatever number of
--- damage dice the rules path happens to roll afterwards, so the assertion does
--- not have to model the engine's internal roll count. Pass {} to hand control
--- back to the engine RNG (used by the soak tests).
function Dice.script(values)
  stream = {}
  for i = 1, #(values or {}) do stream[i] = values[i] end
  streamIdx = 1
end

function Dice.isScripted() return streamIdx <= #stream end

--- Core roll: inclusive integer range.
function Dice.roll(low, high)
  low, high = math.floor(low), math.floor(high)
  if high < low then low, high = high, low end
  if low == high then return low end
  if #stream > 0 then
    local v = stream[math.min(streamIdx, #stream)]
    streamIdx = streamIdx + 1
    return math.floor(C.clamp(v, low, high))
  end
  return GetRandomInt(low, high)
end

local function dieFace(sides, forceMax)
  if forceMax then return sides end
  return Dice.roll(1, sides)
end

--- Roll a parsed template.
---   opts.max   -> every die shows its maximum face (Sneak Attack style)
---   opts.double-> roll every die twice (the 5e crit rule)
---   opts.bonus -> flat addition on top of the template's own modifier
---   opts.min   -> floor, used so damage can never drop below 1
function Dice.rollTemplate(t, opts)
  opts = opts or {}
  local copies = opts.double and 2 or 1
  local forceMax = opts.max or t.max
  local faces, total = {}, 0
  for _, d in ipairs(t.dice) do
    for _ = 1, copies do
      local f = dieFace(d.d, forceMax)
      faces[#faces + 1] = f
      total = total + f
    end
  end
  total = total + (t.mod or 0) + (opts.bonus or 0)
  if opts.min and total < opts.min then total = opts.min end
  return { total = total, faces = faces, label = C.diceLabel(t),
           mod = (t.mod or 0) + (opts.bonus or 0), count = #faces }
end

--- "2d6+1d4+3" in one call.
function Dice.rollExpr(expr, opts)
  local t = C.parseDice(expr)
  if not t then
    DND.logError("bad dice expression: " .. tostring(expr))
    return { total = 0, faces = {}, label = "0", mod = 0, count = 0 }
  end
  return Dice.rollTemplate(t, opts)
end

---------------------------------------------------------------------- d20 core
--- The only place a d20 is touched. Returns a rich result object so every
--- caller (log, text tag, concentration check) can replay the maths.
---   adv  :  1 advantage, -1 disadvantage, 0 neither
function Dice.d20(mod, adv, opts)
  opts = opts or {}
  local a = Dice.roll(1, 20)
  local b = nil
  if adv == 1 or adv == -1 then b = Dice.roll(1, 20) end

  local chosen, rolled
  if not b then
    rolled, chosen = a, a
  elseif adv == 1 then
    rolled, chosen = (a >= b) and a or b, (a >= b) and a or b
  else
    rolled, chosen = (a <= b) and a or b, (a <= b) and a or b
  end

  local nat = rolled                    -- "natural" 20 / 1 ignores all maths
  local total = nat + (mod or 0)
  local r = {
    natural = nat, total = total, mod = mod or 0,
    dice = { a, b }, adv = adv or 0,
    crit = (opts.autoCrit or nat == 20) and true or false,
    fumble = (nat == 1) and true or false,
  }
  r.critOnly = (nat == 20) and true or false
  if opts.dc then
    r.dc = opts.dc
    r.success = (nat == 20) or (nat ~= 1 and total >= opts.dc)
    if opts.autoFail and opts.autoFail[1] then r.success = false end
  end
  r.text = string.format("d20%s %s %s = %d",
    (adv == 1 and " (adv)") or (adv == -1 and " (dis)") or "",
    nat, C.signed(mod or 0), total)
  return r
end

---------------------------------------------------------------------- checks
--- Ability check or saving throw. `score` optional; pass `mod` directly.
function Dice.check(mod, opts)
  opts = opts or {}
  local adv = opts.adv or 0
  if opts.disadv then adv = -1 end
  local r = Dice.d20(mod, adv, { dc = opts.dc, autoCrit = opts.autoCrit,
                                 autoFail = opts.autoFail })
  if opts.autoSuccess then r.success = true end
  r.label = opts.name or "check"
  return r
end

--- Attack roll vs an AC. Returns { hit, crit, total, natural, ... }
function Dice.attackRoll(bonus, ac, opts)
  opts = opts or {}
  local r = Dice.d20(bonus, opts.adv or (opts.disadv and -1 or 0),
                      { autoCrit = opts.autoCrit, dc = ac })
  r.ac = ac
  r.crit = opts.autoCrit or r.natural == 20
  r.hit = r.crit or (r.natural ~= 1 and r.total >= ac)
  return r
end

--- Initiative. Tie-break by DEX mod, then a coin flip, then a stable index.
function Dice.initiative(dexMod, tiebreak, coin)
  local d = Dice.d20(dexMod or 0, 0)
  return { score = d.total, natural = d.natural, dex = dexMod or 0,
           tie = tiebreak or 0, coin = coin or Dice.roll(1, 100) }
end

--- Percentile roll (loot, wild magic, mishaps).
function Dice.percent() return Dice.roll(1, 100) end

--- Convenience: roll N dice of X, no modifier.
function Dice.pool(n, sides)
  local t = { dice = {}, mod = 0 }
  for _ = 1, n do t.dice[#t.dice + 1] = { d = sides } end
  return Dice.rollTemplate(t)
end

return Dice
