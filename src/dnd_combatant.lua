--[[ =========================================================================
  dnd_combatant.lua — the D&D creature, and how it is mirrored into WC3.

  A combatant is a Lua table (the truth) wrapped around a WC3 unit (the body).
  Everything the engine needs is on the Lua side; the unit object is used for
  model, position, HP bar, and the ability buttons. Synced one way:
  Lua -> WC3, via Combatant.sync().
========================================================================== ]]
DND = DND or {}
DND.Combatant = {}
local Combatant = DND.Combatant
local C = DND.CONST
local w3 = DND.w3

local byHandle = {}          -- handleId -> combatant
local all = {}               -- ordered list
local nextCid = 1

local ABILITY_KEYS = { "str", "dex", "con", "int", "wis", "cha" }

---------------------------------------------------------------------- lookup
function Combatant.get(u)
  if not u then return nil end
  return byHandle[w3.id(u)]
end
function Combatant.byId(cid) return all[cid] end
function Combatant.all() return all end
function Combatant.count() return #all end

function Combatant.listOnSide(side)
  local out = {}
  for _, cbt in ipairs(all) do
    if cbt.side == side and not cbt.removed then out[#out + 1] = cbt end
  end
  return out
end

--- Living creatures on one side, exactly one side. `Combatant.living(nil)` means
--- "everybody", which is right for end-of-fight checks and wrong for reading a
--- threat list; keep the two intentions in different functions.
function Combatant.livingOf(side)
  local out = {}
  for _, cbt in ipairs(all) do
    if cbt.side == side and cbt.hp > 0 and not cbt.removed then out[#out + 1] = cbt end
  end
  return out
end

function Combatant.living(side)
  local out = {}
  for _, cbt in ipairs(all) do
    if (side == nil or cbt.side == side) and cbt.hp > 0 and not cbt.removed then
      out[#out + 1] = cbt
    end
  end
  return out
end

function Combatant.remove(cbt)
  cbt.removed = true
  byHandle[cbt.hid] = nil
end

--- Drop every marked combatant out of the ordered list. `remove` unregisters the
--- unit handle, which is what the rules check, but `all` is what anything that
--- walks the whole roster reads — so a session of repeated encounters would keep
--- growing it forever. Cheap, and the delve calls it between rooms.
function Combatant.compact()
  local keep = {}
  for _, cbt in ipairs(all) do
    if not cbt.removed then keep[#keep + 1] = cbt end
  end
  for i = #all, 1, -1 do all[i] = nil end
  for i, cbt in ipairs(keep) do all[i] = cbt end
  return #all
end

---------------------------------------------------------------------- build
--- spec: a 5e-ish statblock. Fields all have sane defaults so a monster can be
--- declared in four lines: { name="Goblin", ac=15, hp=7, speed=30, str=8, dex=14 }
function Combatant.new(spec, unit)
  assert(spec, "Combatant.new needs a spec")
  local level = spec.level or 1
  local prof = spec.prof or C.proficiency(level)
  local scores = {}
  for _, k in ipairs(ABILITY_KEYS) do scores[k] = spec[k] or 10 end
  local mods = {}
  for _, k in ipairs(ABILITY_KEYS) do mods[k] = C.abilityMod(scores[k]) end

  local cbt = {
    cid = nextCid, name = spec.name or "Creature", unit = unit,
    hid = unit and w3.id(unit) or 0,
    side = spec.side or C.SIDE.PARTY,
    level = level, prof = prof,
    scores = scores, mods = mods,
    ac = spec.ac or (10 + mods.dex),
    -- Extra Attack, from a level-up or from the statblock (a beast that has two
    -- natural weapons writes `extraAttack = 2` and gets the same loop for free).
    extraAttack = spec.extraAttack,
    armor = spec.armor,                -- "none" matters: the level ladder's +1
                                       -- is armour getting better, not magic
    spellAbility = spec.spellAbility,  -- which score a save DC is built from
    hpMax = spec.hp or (level * 5 + (mods.con or 0) * level),
    speed = spec.speed or 30,          -- feet per turn
    initiative = spec.initiative or mods.dex,
    senses = spec.senses or {},
    resists = spec.resists or {},      -- { fire="resist", poison="immune" }
    saves = spec.saves or {},          -- { str=3, dex=2 } proficiency-added bonus
    traits = spec.traits or {},
    actions = spec.actions or {},      -- see below
    spells = spec.spells or {},        -- { {name=,level=,...}, ... }
    slotMax = spec.slots or C.SLOT_TABLE[level] or { 0, 0, 0, 0 },
    hpDice = spec.hpDice or { n = level, d = 8 },
    hitDice = spec.hitDice or 0,
    class = spec.class,
    flags = {},
    statuses = {},
    deathSaves = { success = 0, fail = 0 },
    reaction = "none",                 -- none | opportunity | shield | count
    bonusAttack = spec.bonusAttack,
    rangedAttack = spec.rangedAttack,
    passivePerception = 10 + (mods.wis or 0) + (spec.expertise and 2 or 0),
    concentration = nil,
    desc = spec.desc or "",
    icon = spec.icon,
    order = nextCid,
  }
  nextCid = nextCid + 1
  cbt.hp = cbt.hpMax

  -- A statblock can declare a cantrip attack; it is just another action with no
  -- slot behind it, and folding it in here keeps every consumer (AI scoring,
  -- threat ranges, opportunity attacks) looking at one list. The list is copied
  -- first: the spec is usually a row of Data.Bestiary, and appending here would
  -- leave that row with one more attack every time somebody spawned it.
  local actions = {}
  for i, a in ipairs(spec.actions or {}) do actions[i] = a end
  if spec.cantripAttack then
    spec.cantripAttack.isCantrip = true   -- spell damage scales with level
    actions[#actions + 1] = spec.cantripAttack
  end
  cbt.actions = actions

  -- Normalise attacks. Each action: { name, toHit|spellDc, damage, dmgType,
  --   reach, range, bonus (attack bonus override), finesse, props }
  for i, a in ipairs(cbt.actions) do
    if not a.toHit and not a.spellDc then
      a.toHit = prof + (a.ability and mods[a.ability] or mods.str)
    end
    a.reach = a.reach or (a.range and C.ft(a.range) or C.ft(5))
    a.damage = a.damage or "1"
    a.dmgType = a.dmgType or "bludgeoning"
    a.index = i
    a.hotkey = a.hotkey or ("123456789"):sub(i, i)
  end

  -- Slots: spendable per level, restored by a short/long rest.
  cbt.slots = {}
  for lvl = 1, #cbt.slotMax do cbt.slots[lvl] = cbt.slotMax[lvl] end

  byHandle[cbt.hid] = cbt
  all[#all + 1] = cbt
  return cbt
end

--- Mirror into the WC3 unit so the tooltips and the bar agree with the rules.
function Combatant.sync(cbt)
  local u = cbt.unit
  if not u then return end
  SetUnitState(u, UNIT_STATE_MAX_LIFE, math.max(1, math.floor(cbt.hpMax * C.HP_SCALE)))
  SetUnitState(u, UNIT_STATE_LIFE, math.max(0, math.floor(cbt.hp * C.HP_SCALE)))
  SetUnitMoveSpeed(u, cbt.speed * C.UNITS_PER_FOOT / 6.0)
  BlzSetUnitArmor(u, cbt.ac - 10)                  -- WC3 shows AC-10 as "armor"
  BlzSetUnitName(u, cbt.name)
  -- threat ring == the unit's own acquire range, driven by weapon reach
  local reach = C.ft(5)
  for _, a in ipairs(cbt.actions) do
    if a.reach and not a.range and a.reach > reach then reach = a.reach end
  end
  SetUnitAcquireRange(u, reach + C.FIVE_FEET * 2)
  w3.disableRealDamage(u, true)                    -- Lua deals all damage
  w3.freeze(u)
end

---------------------------------------------------------------------- accessors
function Combatant.hpScaled(cbt)  return cbt.hp * C.HP_SCALE end
function Combatant.speed(cbt)     return cbt.speed end
function Combatant.speedUnits(cbt)
  local s = cbt.speed * C.UNITS_PER_FOOT
  if DND.hasCond(cbt, "exhaustion2") or DND.hasCond(cbt, "exhaustion3") then s = s * 0.5 end
  if DND.hasCond(cbt, "restrained") or DND.hasCond(cbt, "grappled")
     or DND.hasCond(cbt, "paralyzed") or DND.hasCond(cbt, "petrified") then s = 0 end
  return s
end
function Combatant.reachUnits(cbt, action)
  return action.reach or (action.range and C.ft(action.range) or C.ft(5))
end
function Combatant.isFoeOf(a, b)  return a.side ~= b.side end

--- Best to-hit bonus available (used by the AI and by Opportunity Attacks).
--- How many times one Attack action resolves.  1 unless something granted it.
function Combatant.extraAttacks(cbt)
  local n = cbt and cbt.extraAttack
  if not n then return 1 end
  if type(n) == "boolean" then return 2 end
  return math.max(1, n)
end

function Combatant.primaryAttack(cbt)
  local best = cbt.actions[1]
  for _, a in ipairs(cbt.actions) do
    if a.toHit and (not best or a.toHit > best.toHit) then best = a end
  end
  return best
end

--- Total AC right now, including cover, Dex loss, and Dodge.
function Combatant.ac(cbt, opts)
  opts = opts or {}
  local ac = cbt.ac
  if DND.hasCond(cbt, "prone") and not opts.melee then ac = ac - 2 end
  if DND.hasCond(cbt, "paralyzed") or DND.hasCond(cbt, "stunned")
     or DND.hasCond(cbt, "unconscious") then ac = 10 + (cbt.mods.dex >= 0 and 0 or cbt.mods.dex) end
  if cbt.flags.dodge then ac = ac + 2 end
  if cbt.flags.shield then ac = ac + 5 end
  ac = ac + (opts.cover or 0)
  if opts.attackerHasAdv and DND.hasCond(cbt, "prone") then ac = ac end
  return ac
end

function Combatant.saveBonus(cbt, ability)
  local base = cbt.mods[ability] or 0
  if cbt.saves[ability] then return cbt.saves[ability] end
  return base + cbt.prof
end

function Combatant.spellSaveDc(cbt)
  local key = cbt.spellAbility or "int"
  return 8 + cbt.prof + (cbt.mods[key] or 0)
end

function Combatant.spellAttack(cbt)
  local key = cbt.spellAbility or "int"
  return cbt.prof + (cbt.mods[key] or 0)
end

---------------------------------------------------------------------- status
function Combatant.addCond(cbt, name, opts)
  if C.CONDITIONS[name] == nil then
    w3.log("unknown condition: " .. tostring(name)); return false
  end
  cbt.statuses[name] = { duration = opts and opts.duration or nil,
                         source = opts and opts.source }
  DND.ui.refreshStatus(cbt)
  return true
end

function Combatant.removeCond(cbt, name)
  if cbt.statuses[name] then
    cbt.statuses[name] = nil
    DND.ui.refreshStatus(cbt)
    return true
  end
  return false
end

function Combatant.hasCond(cbt, name)
  if type(cbt) ~= "table" or cbt.statuses == nil then
    error("hasCond(cbt, name) called with " .. type(cbt)
      .. " as the combatant (name=" .. tostring(name) .. ")", 2)
  end
  return cbt.statuses[name] ~= nil
end

function Combatant.conditionList(cbt)
  local out = {}
  for k in pairs(cbt.statuses) do out[#out + 1] = k end
  table.sort(out)
  return out
end

--- End-of-turn saves that a condition allows (e.g. frightened vs the source).
function Combatant.conditionSaves(cbt)
  local n = 0
  local names = {}
  for name in pairs(cbt.statuses) do names[#names + 1] = name end
  for _, name in ipairs(names) do
    local def = C.CONDITIONS[name]
    local save = C.SAVEABLE[name]
    if def and save and (def.endSave ~= false) then
      local ok = DND.Dice.check(Combatant.saveBonus(cbt, save), { dc = cbt.condDc or 12 })
      n = n + 1
      DND.logf("%s repeats its %s save: %s -> %s", cbt.name, save,
        C.saveLabel(save), ok.success and "ended" or "still affected")
      if ok.success then Combatant.removeCond(cbt, name) end
    end
  end
  return n
end

---------------------------------------------------------------------- display
--- The statline that goes in the tooltip / side panel. Compact on purpose.
function Combatant.statline(cbt)
  local lines = {}
  lines[#lines+1] = string.format("|cffffe066%s|r  (AC %d, %d hp, speed %d ft)",
    cbt.name, cbt.ac, cbt.hp, cbt.speed)
  local sc = {}
  for _, k in ipairs(ABILITY_KEYS) do
    sc[#sc+1] = string.upper(k) .. " " .. cbt.scores[k] .. C.signed(cbt.mods[k])
  end
  lines[#lines+1] = table.concat(sc, "  ")
  local acts = {}
  for _, a in ipairs(cbt.actions) do
    if a.toHit then acts[#acts+1] = a.name .. " " .. C.signed(a.toHit) .. " (" .. a.damage .. ")"
    else acts[#acts+1] = a.name .. " DC" .. a.spellDc end
  end
  if #acts > 0 then lines[#lines+1] = "Actions: " .. table.concat(acts, ", ") end
  if #cbt.spells > 0 then
    local sl = {}
    for lvl = 1, #cbt.slotMax do
      if cbt.slotMax[lvl] > 0 then sl[#sl+1] = C.ordinal(lvl) .. " (" .. cbt.slots[lvl] .. "/" .. cbt.slotMax[lvl] .. ")" end
    end
    lines[#lines+1] = "Slots: " .. table.concat(sl, ", ")
  end
  return table.concat(lines, "\n")
end

function Combatant.clearAll()
  for i = #all, 1, -1 do
    all[i] = nil
  end
  byHandle = {}
end

-- expose the condition helpers on DND so other modules read naturally
DND.hasCond   = Combatant.hasCond
DND.addCond   = Combatant.addCond
DND.removeCond = Combatant.removeCond

return Combatant
