--[[ =========================================================================
  dnd_const.lua — shared constants, units of measure, pure-Lua helpers.

  Deliberately native-free: everything in here runs under plain Lua so it can
  be unit-tested outside the game (see tools/harness.py).
========================================================================== ]]
DND = DND or {}

DND.CONST = {}
local C = DND.CONST

---------------------------------------------------------------------- scale
-- D&D:   1 round = 6 s,  1 square = 5 ft.
-- WC3:   1 terrain tile = 64 units.
-- We declare 64 units == 10 ft, so 1 ft == 6.4 units. A 30 ft stride is then
-- 192 units, which a 270-speed Footman covers in ~0.7 s — the distance looks
-- like it reads, which is the whole trick to making turn-based feel natural.
C.UNITS_PER_FOOT = 6.4
C.ROUND_SECONDS  = 6.0
C.FEET_PER_TILE  = 10
C.FIVE_FEET      = C.UNITS_PER_FOOT * 5          -- 32u == one step, and one reach
C.MELEE_REACH_FT = 5

function C.ft(f) return f * C.UNITS_PER_FOOT end
function C.unitsToFeet(u) return u / C.UNITS_PER_FOOT end

---------------------------------------------------------------------- phases
C.PHASE = {
  IDLE       = "idle",         -- no combat; free realtime play
  INITIATIVE = "initiative",   -- rolling for the count
  BEGIN      = "begin",        -- turn just started, opportunity attacks may fire
  MOVE       = "move",         -- active unit may reposition
  ACTION     = "action",       -- main action pending/available
  BONUS      = "bonus",        -- bonus action pending/available
  REACTION   = "reaction",     -- a defender is being prompted
  ENEMY      = "enemy",        -- AI side is taking its turn
  END        = "end",          -- turn wrap-up
}

C.SIDE = { PARTY = 0, FOES = 1 }
C.SIDE_NAME = { [0] = "The Party", [1] = "Invaders" }

---------------------------------------------------------------------- 5e maths
C.PROF_BY_LEVEL = { 2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,6,6,6,6 }
function C.proficiency(level)
  return C.PROF_BY_LEVEL[level] or (2 + math.floor((level - 1) / 4))
end

function C.abilityMod(score)                     -- 20 -> +5, 3 -> -4
  return math.floor((score - 10) / 2)
end

C.ABILITIES = { "str", "dex", "con", "int", "wis", "cha" }
C.SAVE_LABEL = { str = "Strength", dex = "Dexterity", con = "Constitution",
                 int = "Intelligence", wis = "Wisdom", cha = "Charisma" }
function C.saveLabel(a) return C.SAVE_LABEL[a] or tostring(a):upper() end

-- WC3 has exactly three attributes, so we bind them to the physical trio and
-- keep the mental scores in Lua. The unit tooltip then shows numbers that mean
-- something rather than a Footman's stock 14/10/20.
C.ATTR_TO_WC3 = { str = 0x7573746D,   -- 'ustm' strength, permanent
                  dex = 0x7561676D,   -- 'uagm' agility, permanent
                  con = 0x75696E74 }  -- 'uint' intelligence, permanent (stands in)

-- HP is scaled x4 so one crit longsword does not pop a WC3 model between two
-- frames, and so a 138 hp Ancient Keeper feels like a wall without absurd math.
C.HP_SCALE = 4

C.RNGLABEL = { "1st", "2nd", "3rd", "4th", "5th", "6th", "7th", "8th", "9th" }
function C.ordinal(n) return C.RNGLABEL[n] or (n .. "th") end

C.SPELL_SLOTS_MAX = 4      -- levels 1..4 is plenty for a one-evening brawl
C.SLOT_TABLE = {           -- indexed by class level, [lvl] = {1st,2nd,3rd,4th}
  [1] = {2,0,0,0}, [2] = {3,0,0,0}, [3] = {4,2,0,0}, [4] = {4,3,0,0},
  [5] = {4,3,2,0}, [6] = {4,3,3,0}, [7] = {4,3,3,1}, [8] = {4,3,3,2},
  [9] = {4,3,3,2}, [10] = {4,3,3,2},
}

---------------------------------------------------------------------- conditions
-- key = 5e condition; value = the hooks the engine actually honours.
C.CONDITIONS = {
  blinded     = { attack = -1,        note = "it can't see; attacks vs it have adv" },
  charmed     = { noAttackCharmer = 1, note = "can't attack the charmer" },
  deafened    = { perception = -5,    note = "-5 to sound-based Perception" },
  exhaustion1 = { check = -2,         note = "-2 ability checks and saves" },
  exhaustion2 = { check = -4, speedHalf = 1 },
  exhaustion3 = { check = -6, speedHalf = 1 },
  frightened  = { attack = -1, noCloserTo = 1, note = "can't move toward the source" },
  grappled    = { speedZero = 1, attack = -1 },
  paralyzed   = { skipTurn = 1, autoFail = { str = 1, dex = 1 }, critHit = 1,
                  incapacitated = 1 },
  petrified   = { skipTurn = 1, autoFail = { str = 1, dex = 1 }, speedZero = 1,
                  incapacitated = 1 },
  poisoned    = { attack = -1, check = -1 },
  prone       = { meleeAdvVs = 1, attack = -2, speedZero = 1, standCostHalf = 1,
                  note = "standing costs half your speed" },
  restrained  = { speedZero = 1, attack = -1, dexSave = -1 },
  stunned     = { skipTurn = 1, autoFail = { str = 1, dex = 1 },
                  incapacitated = 1, skipReaction = 1 },
  unconscious = { skipTurn = 1, prone = 1, autoFail = { str = 1, dex = 1 },
                  meleeAdvVs = 1, incapacitated = 1, skipReaction = 1 },
}
-- Which save ends it (nil = no save; ends on its own terms).
C.SAVEABLE = {
  blinded = "con", charmed = "wis", deafened = "con", frightened = "wis",
  paralyzed = "con", petrified = "con", poisoned = "con", stunned = "con",
  restrained = "str", grappled = "str",
}

---------------------------------------------------------------------- weapons
-- Only what the demo needs; dnd_data.lua adds the rest. reach is in feet and
-- is what the engine uses for both threat range and opportunity attacks.
C.WEAPONS = {
  club           = { dmg = "1d4",  reach = 5,  type = "bludgeoning" },
  dagger         = { dmg = "1d4",  reach = 5,  type = "piercing",   finesse = 1, light = 1 },
  greatclub      = { dmg = "1d8",  reach = 5,  type = "bludgeoning" },
  longsword      = { dmg = "1d8",  reach = 5,  type = "slashing",   versatile = "1d10" },
  mace           = { dmg = "1d6",  reach = 5,  type = "bludgeoning" },
  rapier         = { dmg = "1d8",  reach = 5,  type = "piercing",   finesse = 1 },
  shortsword     = { dmg = "1d6",  reach = 5,  type = "piercing",   finesse = 1, light = 1 },
  greataxe       = { dmg = "1d12", reach = 5,  type = "slashing" },
  greatsword     = { dmg = "2d6",  reach = 5,  type = "slashing" },
  pike           = { dmg = "1d10", reach = 10, type = "piercing",   reachWeapon = 1 },
  glaive         = { dmg = "1d10", reach = 10, type = "slashing",   reachWeapon = 1 },
  whip           = { dmg = "1d4",  reach = 10, type = "slashing",   reachWeapon = 1, finesse = 1 },
  shortbow       = { dmg = "1d6",  reach = 320, type = "piercing",  ranged = 1 },
  longbow        = { dmg = "1d8",  reach = 600, type = "piercing",  ranged = 1 },
  light_crossbow = { dmg = "1d8",  reach = 320, type = "piercing",  ranged = 1, loading = 1 },
  heavy_crossbow = { dmg = "1d10", reach = 600, type = "piercing",  ranged = 1 },
  unarmed_strike = { dmg = "1",    reach = 5,  type = "bludgeoning" },
}
-- 5e prose says "resistance" and "vulnerability"; the old-guard wording says
-- "half" and "double". Accept both, because a statblock written either way must
-- never silently compute as "no modifier" — that is the bug that shipped here.
C.RESIST_MULT = { resist = 0.5, half = 0.5, immune = 0,
                  vulnerable = 2, double = 2 }

---------------------------------------------------------------------- fx paths
C.SCHOOL_ICON = {
  conjuration   = "Abilities\\Spells\\Human\\Blizzard\\BlizzardTarget.mdl",
  evocation     = "Abilities\\Spells\\Human\\Fireball\\FireBolt.mdl",
  abjuration    = "Abilities\\Spells\\Human\\BlackArrow\\AntiMagicShield.mdl",
  necromancy    = "Abilities\\Spells\\Undead\\AnimateDead\\AnimateDeadTarget.mdl",
  transmutation = "Abilities\\Spells\\Human\\Polymorph\\PolyMorphFalloffs.mdl",
  divination    = "Abilities\\Spells\\Human\\FlameStrike\\HealingSpark.mdl",
  enchantment   = "Abilities\\Spells\\Human\\ManaShield\\ManaShieldTarget.mdl",
  illusion      = "Abilities\\Spells\\Human\\Slow\\SlowMissile.mdl",
}
C.DMG_EFFECT = {
  fire      = "Abilities\\Spells\\Other\\Incinerate\\FireLordDeathExplode.mdl",
  lightning = "Abilities\\Spells\\Human\\ThunderClap\\HumanThunderClap.mdl",
  cold      = "Abilities\\Spells\\Other\\FrostArmor\\FrostArmorDamage.mdl",
  necrotic  = "Abilities\\Spells\\Undead\\DeathCoil\\DeathCoilMissile.mdl",
  radiant   = "Abilities\\Spells\\Human\\HolyBolt\\HolyBoltSpecialArt.mdl",
  poison    = "Abilities\\Spells\\Orc\\Poison\\Poisonbolt.mdl",
  force     = "Abilities\\Spells\\Human\\Feedback\\ArcaneTowerAttack.mdl",
  psychic   = "Abilities\\Spells\\Orc\\PsychicWhip\\RedWhip.mdl",
  thunder   = "Abilities\\Spells\\Human\\ThunderClap\\HumanThunderClap.mdl",
}

---------------------------------------------------------------------- config
C.DEFAULT_CONFIG = {
  gridSnap       = true,  -- quantise every move onto 5 ft squares
  cover          = false, -- count bodies in the lane for half/3/4 cover
  crits          = true,  -- nat 20 doubles the damage dice
  autoCritOnDown = true,  -- a melee hit on an unconscious foe is an auto crit
  deathSaves     = true,  -- false: mooks die at 0 hp; a creature with a `class`
                             -- still gets its saves, so a TPK is always earnable
  reactions      = true,  -- false: opportunity attacks auto-fire, no prompt
  autoEndTurn    = true,  -- end the turn once action + move + bonus are spent
  aiEnabled      = true,   -- false: nobody plays the invader side (scripted scenes, tests)
  nativeTargeting = false, -- grant AMOV/AATK so right-click works (needs dnd_data.js)
  xpTrack        = true,   -- false: no award, no ladder, no levels (a pure
                           -- tactics sandbox: every fight is the same difficulty)
  restBetweenRooms = nil,   -- absent = each encounter decides (a delve rests 2 hours
                            -- in the corridor between rooms); false forces pure
                            -- attrition on every fight; a number forces that many hours
  useVanillaModels = false, -- true: spawn stock WC3 units as the actors
}

-- Bootstrapped here rather than in the entry point: every module reads
-- DND.config, so a map that forgot to copy the defaults would crash on the
-- very first keypress. reconfigure() re-applies defaults for any NEW key, which
-- is what actually saves you when you add a switch and forget to set it.
DND.config = DND.config or {}
for k, v in pairs(C.DEFAULT_CONFIG) do
  if DND.config[k] == nil then DND.config[k] = v end
end
function C.reconfigure(t)
  for k, v in pairs(t or {}) do DND.config[k] = v end
  for k, v in pairs(C.DEFAULT_CONFIG) do
    if DND.config[k] == nil then DND.config[k] = v end
  end
  return DND.config
end

---------------------------------------------------------------------- helpers
function C.clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function C.round(x)                              -- round-half-up
  if x >= 0 then return math.floor(x + 0.5) end
  return math.ceil(x - 0.5)
end

--- Parse a dice expression into a roll template.
---   "1d20+5"    -> { dice={{d=20}}, mod=5 }
---   "2d6+1d4+3" -> { dice={{d=6},{d=6},{d=4}}, mod=3 }
---   "1"         -> { dice={}, mod=1 }
---   "max"       -> { dice={}, mod=0, max=true }  (used by crits / auto-max)
--- Returns nil on junk, so a typo in a statblock fails loudly, not silently.
function C.parseDice(expr)
  if type(expr) == "table" then return expr end
  if type(expr) ~= "string" and type(expr) ~= "number" then return nil end
  local raw = tostring(expr)
  -- Spaces are only allowed around an operator. "1d8 3" must not silently
  -- become "1d83" (a d83); that is how a statblock typo becomes a bug report.
  if raw:find("[0-9a-zA-Z]%s+[0-9a-zA-Z]") then return nil end
  local s = raw:gsub("%s", "")
  if s == "" then return nil end
  if s == "max" then return { dice = {}, mod = 0, max = true, label = "max" } end
  if s == "auto" then return { dice = {}, mod = 0, auto = true, label = "auto" } end
  -- Tokenise:  [sign] NdM | [sign] N   repeated. Anything else fails closed.
  local dice, mod = {}, 0
  local pos = 1
  local first = true
  while pos <= #s do
    local sign = 1
    local c = s:sub(pos, pos)
    if c == "+" or c == "-" then
      sign = (c == "-") and -1 or 1
      pos = pos + 1
    end
    if not first and s:sub(pos - 1, pos - 1) ~= "+" and s:sub(pos - 1, pos - 1) ~= "-" then
      return nil                       -- "1d8 3" with no operator: reject
    end
    local nStr, dStr = s:match("^(%d*)d(%d+)", pos)
    if dStr then
      if nStr ~= "" then
        -- "0d6" is legal 5e shorthand for "no dice"; "2d" is not
        if tonumber(nStr) < 0 then return nil end
      end
      local count = tonumber(nStr)
      if not count then
        if nStr == "" then return nil end   -- "d8" is a typo, not "1d8"
        count = 1
      end
      for _ = 1, count do dice[#dice + 1] = { d = tonumber(dStr) } end
      pos = pos + #nStr + 1 + #dStr
    else
      local num, after = s:match("^(-?%d+)()", pos)
      if not num then return nil end
      mod = mod + sign * tonumber(num)
      pos = after
    end
    first = false
  end
  if #dice == 0 and mod == 0 then return nil end
  return { dice = dice, mod = mod, label = expr }
end

--- "1d8+3" style label rebuilt from a template, for the log and the UI.
function C.diceLabel(t)
  if t and t.label then return tostring(t.label) end
  if not t then return "0" end
  local bySide = {}
  for _, dd in ipairs(t.dice) do bySide[dd.d] = (bySide[dd.d] or 0) + 1 end
  local parts = {}
  for side, n in pairs(bySide) do parts[#parts + 1] = n .. "d" .. side end
  table.sort(parts)
  local s = table.concat(parts, "+")
  if s == "" then s = "0" end
  if t.mod and t.mod ~= 0 then
    s = s .. (t.mod > 0 and ("+" .. t.mod) or tostring(t.mod))
  end
  return s
end

--- Sign-aware "+3" / "-1" for printing modifiers.
function C.signed(n)
  n = n or 0
  if n >= 0 then return "+" .. n end
  return tostring(n)
end

function C.pad(s, w)
  s = tostring(s)
  if #s >= w then return s:sub(1, w) end
  return s .. string.rep(" ", w - #s)
end

return C
