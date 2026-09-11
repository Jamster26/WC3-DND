--[[ =========================================================================
  dnd_data.lua — the bestiary and the party.

  A creature is a plain Lua statblock; nothing in the Object Editor has to be
  touched to add one. Combatant.new() does the work of turning it into rules,
  Data.spawn() does the work of turning it into a WC3 unit you can look at.

  Numbers are 5e SRD-faithful so the maths is checkable against the book.
========================================================================== ]]
DND = DND or {}
DND.Data = {}
local Data = DND.Data
local C = DND.CONST
local Combatant = DND.Combatant

---------------------------------------------------------------------- spells
-- Reactions and bonus actions are what make D&D feel like D&D, so the spells
-- here are chosen for how they interact with the turn structure.
local Spells = {
  firebolt = {
    name = "Firebolt", level = 0, school = "evocation", cantrip = true,
    attackRoll = true, damage = "1d10", dmgType = "fire", range = 120,
    upcast = "1d10", upcastAt = { 5, 11, 17 },
    desc = "Ranged spell attack. +1d10 at levels 5/11/17.",
  },
  rayOfFrost = {
    name = "Ray of Frost", level = 0, school = "evocation", cantrip = true,
    attackRoll = true, damage = "1d8", dmgType = "cold", range = 60,
    onHit = function(c, t) t.flags.slowed = true end,
    desc = "Target's speed drops by 10 ft until the start of your next turn.",
  },
  shield = {
    name = "Shield", level = 1, school = "abjuration", bonus = false,
    reaction = true,
    selfEffect = function(c)
      c.flags.shield = true
      DND.logf("%s raises a shimmering barrier (+5 AC until the start of their next turn).", c.name)
    end,
    desc = "Reaction: +5 AC until the start of your next turn, and Magic Missile is deflected.",
  },
  mageArmor = {
    name = "Mage Armor", level = 1, school = "abjuration", needTarget = true,
    selfEffect = function(c, res)
      local t = res.target
      if t then
        local newAc = math.max(t.ac, 13 + t.mods.dex)
        if newAc ~= t.ac then
          DND.logf("%s's AC improves to %d while the armor lasts.", t.name, newAc)
          t.ac = newAc
          t.flags.mageArmor = true
          Combatant.sync(t)
        end
      end
    end,
    desc = "Touch a willing creature: AC becomes 13 + DEX while it lasts.",
  },
  burningHands = {
    name = "Burning Hands", level = 1, school = "evocation",
    save = "dex", damage = "3d6", dmgType = "fire", range = 15,
    halfOnSave = true, aoe = 15,
    desc = "15 ft cone, DEX save for half.",
  },
  sleep = {
    name = "Sleep", level = 1, school = "enchantment", aoe = 20, needTarget = false,
    -- Sleep works on hit points, not saves: the oldest trick in the book.
    sleepPool = true,
    desc = "5d8 hp of creatures fall unconscious, lowest hp first.",
    onCast = function(caster, spell)
      local pool = DND.Dice.rollExpr("5d8").total
      local foes = DND.Combat.enemiesOf(caster)
      local put = {}
      for _, f in ipairs(foes) do
        if f.hp <= pool and f.hp > 0 then
          pool = pool - f.hp
          put[#put + 1] = f
        end
      end
      for _, f in ipairs(put) do
        f.hp = 0
        f.downed = true
        f.flags.magicSleep = true
        DND.addCond(f, "unconscious", { source = caster.cid })
        DND.logf("|cff99ccff%s|r falls asleep (Sleep had %d hp to spare).", f.name, pool)
        Combatant.sync(f)
      end
      if #put == 0 then DND.logf("Sleep finds nobody low enough (%d hp of pool left).", pool) end
      return { affected = put }
    end,
  },
  thunderwave = {
    name = "Thunderwave", level = 1, school = "evocation",
    save = "con", damage = "2d8", dmgType = "thunder", range = 0, aoe = 15,
    needTarget = false, halfOnSave = true,
    onCast = function(caster, spell)
      local n = 0
      for _, foe in ipairs(DND.Combat.enemiesOf(caster)) do
        if DND.w3.dist(caster.unit, foe.unit) <= C.ft(spell.aoe or 15) then n = n + 1 end
      end
      caster.flags.thunderwaveHits = n
      if n > 0 then DND.logf("Thunderwave booms across %d creature(s).", n) end
      return { aoe = n }
    end,
    desc = "15 ft cube from you: CON save, half on a success, pushed 10 ft.",
  },
  falseLife = {
    name = "False Life", level = 1, school = "necromancy",
    selfEffect = function(c)
      local r = DND.Dice.rollExpr("1d4+4")
      c.flags.tempHp = (c.flags.tempHp or 0) + r.total
      DND.logf("%s gains %d temporary hit points.", c.name, r.total)
    end,
    desc = "1d4+4 temporary hit points.",
  },
  healingWord = {
    name = "Healing Word", level = 1, school = "evocation", bonus = true,
    needTarget = true, damage = "1d4+3", heal = true, range = 60,
    desc = "Bonus action. 1d4 + spellcasting mod hit points to a creature you can see.",
  },
  cureWounds = {
    name = "Cure Wounds", level = 1, school = "evocation",
    needTarget = true, damage = "1d8+3", heal = true, range = 5,
    upcast = "1d8",
    desc = "Touch: restore 1d8 + WIS mod. +1d8 per slot level above 1st.",
  },
  sacredFlame = {
    name = "Sacred Flame", level = 0, school = "evocation", cantrip = true,
    save = "dex", damage = "1d8", dmgType = "radiant", range = 60,
    noCover = true,
    desc = "DEX save or take 1d8 radiant. Cover doesn't help the target.",
  },
  inflictWounds = {
    name = "Inflict Wounds", level = 1, school = "necromancy",
    attackRoll = true, damage = "3d10", dmgType = "necrotic", range = 5,
    desc = "Melee spell attack: 3d10 necrotic.",
  },
  guidance = {
    name = "Guidance", level = 0, school = "divination", cantrip = true,
    bonus = true, needTarget = true,
    selfEffect = function(c, res)
      local t = res.target
      if t then
        t.flags.guidance = DND.Dice.rollExpr("1d4").total
        DND.logf("%s channels guidance (+1d4 = %d to its next check).", t.name, t.flags.guidance)
      end
    end,
    desc = "Bonus action: the target adds 1d4 to its next ability check.",
  },
  inflict = nil,
}
Data.Spells = Spells

---------------------------------------------------------------------- template
local function creature(spec)
  spec.actions = spec.actions or {}
  return spec
end

Data.Bestiary = {
  ------------------------------------------------------------------ foes
  goblin = creature({
    name = "Goblin", side = C.SIDE.FOES, level = 1, hp = 7, hpDice = { n = 2, d = 6 },
    ac = 15, speed = 30, str = 8, dex = 14, con = 10,
    model = "ogro", icon = "ReplaceableTextures\\CommandButtons\\BTNHeadlessCrusher.blp",
    traits = { { key = "nimble", name = "Nimble Escape",
      desc = "can Disengage or Hide as a bonus action", bonus = true } },
    actions = {
      { name = "Scimitar", toHit = 4, damage = "1d6+2", dmgType = "slashing",
        finesse = true },
      { name = "Shortbow", toHit = 4, damage = "1d6+2", dmgType = "piercing", range = 80 },
    },
    desc = "Small humanoid, CR 1/4. Nimble Escape is why it keeps getting away.",
  }),
  hobgoblinCaptain = creature({
    name = "Hobgoblin Captain", side = C.SIDE.FOES, level = 3, hp = 39,
    hpDice = { n = 6, d = 8 }, ac = 17, speed = 30,
    str = 13, dex = 12, con = 12, int = 10, wis = 11, cha = 14,
    model = "ogru",
    actions = { { name = "Longsword", toHit = 3, damage = "1d8+1", dmgType = "slashing",
                  versatile = "1d10+1",
                  extraDice = { { expr = "2d6", dmgType = "slashing" } } } },
    -- Martial Advantage is printed INTO the weapon here rather than armed by a
    -- bonus action: the real feature needs an ally within 5 ft of the target,
    -- and this captain is written as a rank fighter, so the +2d6 is always on.
    -- (An onUse handler that rewrote the shared bestiary action would leak the
    -- bonus into every later fight, which is worse than being generous here.)
    traits = { { key = "martial", name = "Martial Advantage",
      desc = "+2d6 on a hit: his rank is in the fray with him" } },
  }),
  orc = creature({
    name = "Orc", side = C.SIDE.FOES, level = 1, hp = 15, ac = 13, speed = 30,
    str = 16, dex = 12, con = 16, model = "ogru",
    actions = { { name = "Greataxe", toHit = 5, damage = "1d12+3", dmgType = "slashing" },
                { name = "Javelin", toHit = 5, damage = "1d6+3", dmgType = "piercing", range = 30 } },
    traits = { { key = "aggr", name = "Aggressive", bonus = true,
      desc = "move up to its speed toward a hostile creature",
      onUse = function(c)
        local foe = DND.Combat.enemiesOf(c)[1]
        if not foe then return { error = "nothing to charge" } end
        local u = c.unit
        local fx, fy = GetUnitX(u), GetUnitY(u)
        local tx, ty = GetUnitX(foe.unit), GetUnitY(foe.unit)
        local d = DND.w3.distPts(fx, fy, tx, ty)
        local step = math.min(c.speed * C.UNITS_PER_FOOT, math.max(0, d - C.ft(5)))
        -- Guard the division, and guard it as `not (step > x)`: a nan distance (a
        -- target whose unit is already gone) fails that too, where `step <= 0` would
        -- let it through and write 0/0 into the creature's position.
        if not (step > C.FIVE_FEET) then return { error = "nothing to charge" } end
        local t = step / d
        return DND.Combat.move({ x = fx + (tx - fx) * t, y = fy + (ty - fy) * t }, { free = true })
      end } },
  }),
  wolf = creature({
    name = "Winter Wolf", side = C.SIDE.FOES, level = 2, hp = 22, ac = 13, speed = 40,
    str = 14, dex = 12, con = 12, wis = 12, model = "Umal",
    actions = { { name = "Bite", toHit = 4, damage = "2d4+2", dmgType = "piercing",
                  reach = 5, knockdown = true } },
    senses = { passivePerception = 13 },
  }),
  banditCaptain = creature({
    name = "Bandit Captain", side = C.SIDE.FOES, level = 5, hp = 65, ac = 15,
    speed = 30, str = 15, dex = 16, con = 14, int = 14, wis = 11, cha = 14,
    saves = { str = 4, dex = 5 }, model = "hkni",
    actions = { { name = "Scimitar", toHit = 5, damage = "1d6+3", dmgType = "slashing", finesse = true },
                { name = "Handaxe", toHit = 5, damage = "1d6+3", dmgType = "slashing",
                  light = true },
                { name = "Heavy Crossbow", toHit = 5, damage = "1d10+3", dmgType = "piercing", range = 100 } },
    bonusAttack = { name = "Off-hand Handaxe", toHit = 5, damage = "1d6+3",
                    dmgType = "slashing", bonus = true },
  }),
  ogre = creature({
    name = "Ogre", side = C.SIDE.FOES, level = 4, hp = 59, ac = 11, speed = 40,
    str = 19, dex = 8, con = 16, int = 7, wis = 7, cha = 8, model = "ogru",
    actions = { { name = "Greatclub", toHit = 6, damage = "2d8+4", dmgType = "bludgeoning" },
                { name = "Javelin", toHit = 6, damage = "2d6+4", dmgType = "piercing", range = 30 } },
  }),
  youngDragon = creature({
    name = "Young Red Dragon", side = C.SIDE.FOES, level = 7, hp = 178, ac = 18,
    speed = 60, fly = true, str = 23, dex = 10, con = 21, int = 14, wis = 11, cha = 19,
    saves = { dex = 3, con = 7, wis = 3, cha = 6 },
    resists = { fire = "immune" }, model = "Hadr",
    actions = {
      { name = "Bite", toHit = 9, damage = "2d10+6", dmgType = "piercing" },
      { name = "Claw", toHit = 9, damage = "2d4+6", dmgType = "slashing" },
      { name = "Fire Breath", recharge = "5-6", save = "dex", damage = "16d6",
        dmgType = "fire", aoe = 15, halfOnSave = true, needTarget = false,
        desc = "30 ft cone, DEX save for half. Recharges on a 5-6." },
    },
  }),

  ------------------------------------------------------------------ party
  humanFighter = creature({
    name = "Thorla", class = "Fighter", side = C.SIDE.PARTY, level = 3,
    hp = 29, hpDice = { n = 3, d = 10 }, ac = 18, speed = 30,
    str = 16, dex = 14, con = 15, int = 10, wis = 12, cha = 11,
    saves = { str = 5, con = 4 }, model = "hkni",
    actions = { { name = "Greatsword", toHit = 5, damage = "2d6+3", dmgType = "slashing" },
                { name = "Handaxe", toHit = 5, damage = "1d6+3", dmgType = "slashing", range = 20 } },
    bonusAttack = { name = "Action Surge", toHit = 5, damage = "2d6+3", bonus = true,
                    dmgType = "slashing", action = false },
    traits = { { key = "surge", name = "Action Surge", bonus = true,
      desc = "take one extra action this turn",
      onUse = function(c)
        if c.flags.surgeUsed then return { error = "already used" } end
        c.flags.surgeUsed = true
        c.actionUsed = false
        DND.logf("|cffffe066%s uses Action Surge|r — a second action, right now.", c.name)
        return { ok = true }
      end } },
    hitDice = 3,
  }),
  halflingRogue = creature({
    name = "Pip", class = "Rogue", side = C.SIDE.PARTY, level = 3,
    hp = 24, hpDice = { n = 3, d = 8 }, ac = 15, speed = 30,
    str = 8, dex = 17, con = 13, int = 12, wis = 12, cha = 14,
    saves = { dex = 5, int = 3 }, model = "Harb", smallFry = true,
    actions = { { name = "Shortsword", toHit = 5, damage = "1d6+3", dmgType = "piercing",
                  finesse = true, sneak = "2d6" },
                { name = "Shortbow", toHit = 5, damage = "1d6+3", dmgType = "piercing",
                  range = 80, sneak = "2d6" } },
    traits = {
      { key = "cunning", name = "Cunning Action", bonus = true,
        desc = "Dash, Disengage or Hide as a bonus action",
        onUse = function(c, opts)
          local which = opts and opts.which or "disengage"
          return DND.Combat.useAction(which, { bonus = true })
        end },
      { key = "evasion", name = "Evasion",
        desc = "DEX save for zero on effects that allow a save" },
    },
    hitDice = 3,
  }),
  elfWizard = creature({
    name = "Saria", class = "Wizard", side = C.SIDE.PARTY, level = 3,
    hp = 16, hpDice = { n = 3, d = 6 }, ac = 13, speed = 30,
    str = 8, dex = 16, con = 13, int = 17, wis = 12, cha = 10,
    saves = { int = 6, wis = 4 }, model = "Hblm", spellAbility = "int",
    actions = { { name = "Dagger", toHit = 5, damage = "1d4+3", dmgType = "piercing",
                  finesse = true, range = 20 } },
    -- Fire Bolt is an Action, so it belongs in `actions` as well as in the spell
    -- list; the slot maths for a cantrip is "spend nothing".
    cantripAttack = { name = "Fire Bolt", toHit = 6, damage = "1d10", dmgType = "fire",
                      range = 120, ability = "int", atRange = true },
    spells = { Spells.firebolt, Spells.shield, Spells.mageArmor, Spells.burningHands,
               Spells.sleep, Spells.thunderwave, Spells.falseLife, Spells.rayOfFrost },
    slots = { 4, 2, 0 },
    hitDice = 3,
  }),
  hillDwarfCleric = creature({
    name = "Brokk", class = "Cleric", side = C.SIDE.PARTY, level = 3,
    hp = 30, hpDice = { n = 3, d = 8 }, ac = 18, speed = 25,
    str = 14, dex = 8, con = 16, int = 10, wis = 17, cha = 12,
    saves = { wis = 6, cha = 3 }, model = "Hpal", spellAbility = "wis",
    resists = { poison = "vulnerable" },   -- dwarf stubbornness (flavour)
    actions = { { name = "Warhammer", toHit = 4, damage = "1d8+2", dmgType = "bludgeoning" } },
    spells = { Spells.sacredFlame, Spells.guidance, Spells.healingWord, Spells.cureWounds,
               Spells.inflictWounds },
    slots = { 4, 2, 0 },
    hitDice = 3,
  }),
}
Data.Party = { "humanFighter", "halflingRogue", "elfWizard", "hillDwarfCleric" }

---------------------------------------------------------------------- the roster
--- Extra bestiary entries for the delve. Same `creature()` shape as above, so
--- `DND.Bestiary` is the one place to look for a statblock.
Data.Bestiary.bandit = creature({
  name = "Bandit", side = C.SIDE.FOES, level = 2, xp = 100, hp = 11,
  hpDice = { n = 2, d = 8 }, ac = 12, speed = 30, str = 11, dex = 12, con = 10,
  model = "Harb",
  actions = { { name = "Scimitar", toHit = 3, damage = "1d6+1", dmgType = "slashing",
                finesse = true },
              { name = "Shortbow", toHit = 3, damage = "1d6+1", dmgType = "piercing",
                range = 80 } },
  desc = "One level above a goblin and only slightly better at it.",
})
Data.Bestiary.skeleton = creature({
  name = "Skeleton", side = C.SIDE.FOES, level = 3, xp = 150, hp = 13,
  hpDice = { n = 2, d = 8 }, ac = 13, speed = 30, str = 10, dex = 14, con = 10,
  model = "uske", resists = { poison = "immune" },
  traits = { { key = "sunlight", name = "Sunlight Sensitivity",
    desc = "disadvantage to hit in daylight" } },
  actions = { { name = "Shortsword", toHit = 4, damage = "1d6+2", dmgType = "piercing" } },
  desc = "Immune to poison, hates the sun. Hit point pinata.",
})
Data.Bestiary.skeletonChampion = creature({
  name = "Skeleton Champion", side = C.SIDE.FOES, level = 4, xp = 400, hp = 52,
  hpDice = { n = 8, d = 8 }, ac = 15, speed = 30, str = 15, dex = 15, con = 14,
  model = "nskg", resists = { poison = "immune" },
  actions = { { name = "Greatsword", toHit = 5, damage = "2d6+2", dmgType = "slashing" },
              { name = "Shortbow", toHit = 5, damage = "1d6+2", dmgType = "piercing",
                range = 80 } },
  desc = "Twenty bones more than his friends and a greatsword to match.",
})
Data.Bestiary.guard = creature({
  name = "Watch Guard", side = C.SIDE.FOES, level = 4, xp = 200, hp = 22,
  hpDice = { n = 4, d = 8 }, ac = 16, speed = 30, str = 13, dex = 12, con = 12,
  wis = 11, model = "hkni",
  actions = { { name = "Spear", toHit = 4, damage = "1d6+2", dmgType = "piercing",
                reach = 10 } },
  desc = "Professional. Ten feet of reach says do not walk past him.",
})
Data.Bestiary.orcReaver = creature({
  name = "Orc Reaver", side = C.SIDE.FOES, level = 5, xp = 250, hp = 27,
  hpDice = { n = 5, d = 8 }, ac = 14, speed = 30, str = 16, dex = 12, con = 13,
  model = "ogru",
  actions = { { name = "Greataxe", toHit = 5, damage = "1d12+3", dmgType = "slashing" } },
  desc = "Big axe, bigger appetite.",
})
Data.Bestiary.spiderBrood = creature({
  name = "Giant Spider", side = C.SIDE.FOES, level = 6, xp = 300, hp = 26,
  hpDice = { n = 4, d = 10 }, ac = 14, speed = 30, str = 14, dex = 16, con = 12,
  model = "nspb", venomous = true,
  traits = { { key = "web", name = "Web Walk", desc = "no penalty in its own webs" } },
  actions = { { name = "Bite", toHit = 6, damage = "1d8+3", dmgType = "piercing",
                save = "con", saveDc = 12, saveHalf = "poison" } },
  desc = "Poison on the bite. CON save or the extra dice land too.",
})


---------------------------------------------------------------------- spawning
--- Build the combatant AND its WC3 body. `unit` may be pre-made; if nil we
--- CreateUnit from the spec's model rawcode so the demo needs zero data edits.
function Data.spawn(key, x, y, opts)
  opts = opts or {}
  -- `opts.spec` is how the delve hands in a level-scaled copy of a row: the row
  -- itself is never modified, so the next fight cannot inherit this one's maths.
  local spec = opts.spec or Data.Bestiary[key]
  assert(spec, "unknown creature: " .. tostring(key))
  x = x or (DND.entryAnchor and DND.entryAnchor.x) or 0
  y = y or (DND.entryAnchor and DND.entryAnchor.y) or 0
  local unit = opts.unit
  -- Bodies are the map's business, and the switch is the same one a real map
  -- flips: `useVanillaModels`. A test that wants actors turns it on and gets
  -- mock units at its own coordinates; the rules never notice either way.
  if not unit and DND.config.useVanillaModels then
    local owner = spec.side == C.SIDE.PARTY and Player(0) or Player(1)
    local tpl = spec.model or "hfoo"
    unit = CreateUnit(owner, DND.w3.cc(tpl), x, y, 270)
    if unit then
      SetUnitPathing(unit, true)
      SetUnitScale(unit, spec.smallFry and 0.7 or 1.0, spec.smallFry and 0.7 or 1.0,
                   spec.smallFry and 0.7 or 1.0)
    end
  end
  if not unit and not DND.testMode and DND.config.useVanillaModels == false then
    -- `useVanillaModels = false` means "the map supplies the actors". It is a
    -- real mode (your own edited units), but a roster built here with nothing
    -- in it would fight on hit points alone and the distance maths would have
    -- no handle to read, so say it now instead of crashing on round one.
    DND.logError("no body for " .. (spec.name or "?") .. ": make one and pass it "
      .. "in as opts.unit, or turn DND.config.useVanillaModels back on.")
  end
  local cbt = Combatant.new(spec, unit)
  cbt.xp = spec.xp or (cbt.level * 50 + (cbt.hpMax > 100 and 200 or 0))
  -- the XP bar the action panel prints. Every character starts this conversation
  -- with the same two numbers: what they have, and what the next level costs.
  cbt.xpEarned = spec.xpEarned or 0
  cbt.xpNext = cbt.level < (Data.MAX_LEVEL or 6)
      and DND.xpNeededForLevel(cbt.level + 1) or nil
  cbt.hideDc = opts.hideDc or 12
  -- carried state from the last room of a delve: current hit points and the
  -- spell slots that are left, both of which 5e does NOT hand back for free.
  if opts.hp then cbt.hp = math.max(0, math.min(cbt.hpMax, opts.hp)) end
  if opts.slots then
    for lvl = 1, #cbt.slotMax do cbt.slots[lvl] = opts.slots[lvl] or 0 end
  end
  Combatant.sync(cbt)
  return cbt
end

--- Spawn a whole preset party around a point, spaced on the 5 ft grid.
function Data.spawnParty(x, y, keys)
  local out = {}
  keys = keys or Data.Party
  for i, key in ipairs(keys) do
    out[#out + 1] = Data.spawn(key, x + (i - 1) * C.FIVE_FEET * 4, y, {})
  end
  return out
end

--- Same, for a rank of foes facing them.
function Data.spawnFoes(x, y, keys)
  local out = {}
  for i, key in ipairs(keys) do
    out[#out + 1] = Data.spawn(key, x + (i - 1) * C.FIVE_FEET * 4, y, {})
  end
  return out
end


---------------------------------------------------------------------- levels
--- The whole ladder. 20 XP is enough for level 1 (that is the starting
--- allowance, not a fight); every level after that costs +300. Past the table
--- the curve is 300 x level and the cap is MAX_LEVEL, which is six only
--- because that is where this bestiary stops having armour to give you, not
--- because the maths does.
Data.MAX_LEVEL = 6
Data.LEVEL1_XP = 20
-- 300 is the book number for level 2; this is 200 on purpose. The first
-- level-up has to happen inside the first two delves or nobody ever sees the
-- ladder, and level 1 is the level where a player decides whether they like
-- your game. Everything from 3 up is the book.
Data.LEVEL_MILESTONE = { [2] = 200, [3] = 600, [4] = 900, [5] = 1200, [6] = 2200 }
Data.ARMOUR_SLOTS = { 2, 4, 6 }     -- +1 AC each: 16 -> 19 at level 6

--- Total XP needed to BE level lv. `DND` keeps it because the UI wants to print
--- "120/300" without knowing anything about this file.
function DND.xpNeededForLevel(lv)
  if lv <= 1 then return Data.LEVEL1_XP end
  return Data.LEVEL_MILESTONE[lv] or (300 * lv)
end
Data.CON_BONUS_AT = { 2, 5 }         -- +1 CON each: +1 hp/level, +1 on the die

Data.LEVEL_PROGRESS = {
  hpGain = { [2] = 5, [3] = 6, [4] = 6, [5] = 7, [6] = 7 },
  profBonus = { [1] = 2, [2] = 2, [3] = 2, [4] = 2, [5] = 3, [6] = 3 },
  -- Only features the engine can actually run are listed here. A caster's level
  -- up gains slots (C.SLOT_TABLE), a better save DC (via prof) and, at 5, the
  -- same damage step as everybody else — so no invented feat names sit in the
  -- table promising a mechanic nobody implements.
  byClass = {
    Rogue = { die = 8, hpGain = 5, weaponDie = 6, featAt = 2,
      featName = "Cunning Action", featKey = "cunning",
      featDesc = "Dash, Disengage or Hide as a bonus action" },
    Cleric = { die = 8, hpGain = 5, weaponDie = 6 },
    Fighter = { die = 10, hpGain = 6, featAt = 2, extraAttack = 5,
      featName = "Action Surge", featKey = "surge",
      featDesc = "one extra action, once per turn" },
    Wizard = { die = 6, hpGain = 4, weaponDie = 4 },
  },
}

--- What a fresh first level character looks like, per class. Deliberately
--- awful: this is the half of D&D the finished four level 3 party skips, so it
--- has to feel like a step up rather than a nerf.
Data.CLASS_PACKAGE = {
  Fighter = { die = 10, ac = 16, armor = "chain mail", str = 16, dex = 13, con = 14,
    weapon = "Longsword", weaponDie = 8, weaponType = "slashing", save = "str",
    blurb = "d10 hit die, chain mail, one attack, no Action Surge yet." },
  Rogue = { die = 8, ac = 12, armor = "padded", str = 10, dex = 16, con = 12,
    weapon = "Shortsword", weaponDie = 6, weaponType = "piercing", save = "dex",
    finesse = true, blurb = "d8, padded armour, +5 to hit, no Sneak Attack yet." },
  Cleric = { die = 8, ac = 13, armor = "hide", str = 13, dex = 10, con = 14,
    weapon = "Mace", weaponDie = 6, weaponType = "bludgeoning", save = "wis",
    blurb = "d8, hide armour, and Healing Word still costs a spell slot." },
  Wizard = { die = 6, ac = 11, armor = "none", str = 7, dex = 13, con = 12, int = 16,
    weapon = "Dagger", weaponDie = 4, weaponType = "piercing", save = "int",
    finesse = true, blurb = "d6, no armour, Fire Bolt at 1d10. Send him to the back." },
}

local ROLL_CLASSES = { "Fighter", "Rogue", "Cleric", "Wizard" }
local ROLL_NAMES = { "Corin", "Bess", "Alder", "Wren", "Hob", "Mara", "Nell", "Jod" }
Data.ROLL_NAMES = ROLL_NAMES

local function bonusFrom(v)
  v = v or 10
  return v >= 16 and 3 or v >= 14 and 2 or v >= 12 and 1 or 0
end
Data.bonusFrom = bonusFrom

--- Read a score or a modifier off either shape: a spec (flat keys, as the
--- bestiary writes them) or a live combatant (which keeps them in .scores).
local function scoreOf(c, k)
  if not c then return 10 end
  if c.scores and c.scores[k] then return c.scores[k] end
  return c[k] or 10
end
local function modOf(c, k)
  if c and c.mods and c.mods[k] then return c.mods[k] end
  return bonusFrom(scoreOf(c, k))
end

--- Build a level 1 PC spec (no unit yet) for a class. Dice do the class pick
--- when `class` is nil, so `-random` really is random.
function Data.rollLevel1(class, name, nameIdx)
  class = class or ROLL_CLASSES[DND.Dice.rollExpr("1d4").total]
  local p = Data.CLASS_PACKAGE[class] or Data.CLASS_PACKAGE.Fighter
  local con = bonusFrom(p.con)
  local str = bonusFrom(p.str)
  local dex = bonusFrom(p.dex)
  local intel = bonusFrom(p.int or 10)
  local toHit = Data.LEVEL_PROGRESS.profBonus[1] + (p.finesse and dex or str)
  local spec = {
    -- `nameIdx` keeps a rolled party from being three Besses; the dice only
    -- choose who you get when nobody asked.
    name = name or ROLL_NAMES[(nameIdx or 0) % #ROLL_NAMES + 1]
        or "Adventurer",
    class = class, side = C.SIDE.PARTY, level = 1,
    hp = p.die + con, hpDice = { n = 1, d = p.die },
    ac = p.ac + (p.armor == "none" and dex or 0), armor = p.armor, speed = 30,
    str = p.str, dex = p.dex, con = p.con, int = p.int or 10, wis = 12, cha = 10,
    model = "hfoo", hitDice = 1,
    -- `slots` is the cap, and Combatant.new would otherwise hand a Fighter the
    -- caster table from C.SLOT_TABLE: two 1st level slots with nothing to spend
    -- them on. Non-casters get none.
    slots = { 0, 0, 0 },
    saves = { [p.save] = 2 + con },
    traits = {},
    actions = { { name = p.weapon, toHit = toHit,
      -- a finesse weapon takes the better modifier, which for a rogue is DEX
      damage = "1d" .. p.weaponDie
          .. (math.max(str, p.finesse and dex or -9) > 0
              and C.signed(math.max(str, p.finesse and dex or -9)) or ""),
      dmgType = p.weaponType, finesse = p.finesse } },
  }
  if class == "Cleric" then
    spec.spellAbility = "wis"
    spec.spells = { Spells.healingWord, Spells.guidance }
    spec.slots = { 2, 0, 0, 0 }
  elseif class == "Wizard" then
    spec.spellAbility = "int"
    spec.spells = { Spells.firebolt, Spells.rayOfFrost, Spells.mageArmor }
    spec.slots = { 2, 0, 0, 0 } -- a level 1 wizard has two, not one
    spec.cantripAttack = { name = "Fire Bolt", toHit = 2 + intel, damage = "1d10",
      dmgType = "fire", range = 120, ability = "int", atRange = true }
    spec.actions[1] = { name = "Dagger", toHit = 2 + dex, damage = "1d4+1",
      dmgType = "piercing", finesse = true, range = 20 }
  end
  return spec
end

---------------------------------------------------------------------- progression
--- Does level `lv` hand this caster more spell slots than level lv-1? Read off
--- C.SLOT_TABLE, which is the same table the sheet is built from, so the plan
--- cannot promise a slot that the mirror will not show.
local function casterSlotGain(c, lv)
  if not c.spellAbility then return false end
  local T = C.SLOT_TABLE
  if not (T[lv] and T[lv - 1]) then return false end
  local function sum(t)
    local n = 0
    for _, v in ipairs(t) do n = n + v end
    return n
  end
  return sum(T[lv]) > sum(T[lv - 1])
end

--- Pure function: what levels from+1 .. to would hand this character. Returns a
--- list of change records; empty means "nothing left to gain".
function Data.levelUpPlan(c, to)
  to = to or Data.MAX_LEVEL
  local P = Data.LEVEL_PROGRESS
  local out = {}
  for lv = (c.level or 1) + 1, to do
    local cls = P.byClass[c.class] or {}
    local conGained = false
    for _, at in ipairs(Data.CON_BONUS_AT) do
      if at == lv then conGained = true end
    end
    local acGained = false
    for _, at in ipairs(Data.ARMOUR_SLOTS) do
      if at == lv then acGained = true end
    end
    -- "you get +1 AC" is a claim about the armour, not about you: a wizard in
    -- nothing gains nothing, and a level table that says otherwise is a lie you
    -- read once and then never trust again.
    if c.armor == "none" then acGained = false end
    local con = modOf(c, "con") + (conGained and 1 or 0)
    local change = {
      level = lv,
      -- the class hit die halved and rounded up, plus CON: exactly the 5e deal,
      -- and the reason `byClass.hpGain` is the whole gain rather than a top-up
      hp = (cls.hpGain or P.hpGain[lv] or 5) + con,
      ac = acGained and 1 or 0,
      hit = (P.profBonus[lv] or 2) - (P.profBonus[lv - 1] or 2),
      con = conGained,
      -- A class that gets the real Extra Attack does not also get the invention, and
      -- a class that does not gets the invention instead of nothing.  One or the
      -- other, decided here, so the two can never stack.
      die = (cls.weaponDie and not cls.extraAttack
             and lv % Data.WEAPON_DIE_STEP.at == 0) or nil,
      attack = (cls.extraAttack and lv == cls.extraAttack) or nil,
      feat = (cls.featAt == lv and cls.featName) or nil,
      featKey = (cls.featAt == lv and cls.featKey) or nil,
      prof = P.profBonus[lv] or 2,
      slots = casterSlotGain(c, lv),
    }
    local bits = { "+" .. change.hp .. " hp" }
    if change.ac > 0 then bits[#bits + 1] = "+1 armour" end
    if change.hit > 0 then bits[#bits + 1] = "+" .. change.hit .. " to hit" end
    if change.attack then bits[#bits + 1] = "Extra Attack (one more swing per Action)" end
    if change.die and cls.weaponDie then
      local nd = math.min(cls.weaponDie + math.floor(lv / Data.WEAPON_DIE_STEP.at)
        * Data.WEAPON_DIE_STEP.sides, Data.WEAPON_DIE_STEP.cap)
      bits[#bits + 1] = "weapon die d" .. cls.weaponDie .. "->d" .. nd
    end
    if change.con then bits[#bits + 1] = "+1 CON (heals and death saves)" end
    if change.slots then bits[#bits + 1] = "+spell slots" end
    if change.feat then bits[#bits + 1] = change.feat end
    change.text = table.concat(bits, ", ")
    out[#out + 1] = change
  end
  return out
end

--- Award XP to one combatant. Returns the list of level changes applied, so the
--- caller can log or ignore them; `quiet` is what the harness uses.
function Data.awardXp(c, amount, quiet)
  if DND.config.xpTrack == false then return {} end
  c.xpEarned = (c.xpEarned or 0) + math.max(0, math.floor(amount or 0))
  if c.level >= Data.MAX_LEVEL then return {} end
  local applied = {}
  while c.xpEarned >= DND.xpNeededForLevel(c.level + 1) and c.level < Data.MAX_LEVEL do
    local plan = Data.levelUpPlan(c, c.level + 1)
    local ch = plan[1]
    if not ch then break end
    Data.applyLevelUp(c, ch)
    applied[#applied + 1] = ch
    if not quiet then
      DND.logf("|cffffe066%s reaches level %d|r: %s.", c.name, ch.level, ch.text)
      DND.logf("  [%s] now %d/%d hp, AC %d, %s.", c.name, c.hp, c.hpMax, c.ac,
        c.xpNext and (c.xpEarned .. "/" .. c.xpNext .. " xp toward level "
            .. (c.level + 1)) or ("level " .. c.level .. " is the cap"))
    end
    if c.level >= Data.MAX_LEVEL then break end
  end
  -- the bar the action panel prints; set here, because this is the only place
  -- the number moves
  c.xpNext = c.level < Data.MAX_LEVEL and DND.xpNeededForLevel(c.level + 1) or nil
  return applied
end

--- Push one change record into the character. The plan is the source of truth;
--- this only moves numbers, which is why the two can never disagree.
function Data.applyLevelUp(c, ch)
  local P = Data.LEVEL_PROGRESS
  local cls = P.byClass[c.class] or {}
  c.level = ch.level
  c.hpMax = c.hpMax + ch.hp
  c.hp = math.min(c.hpMax, c.hp + ch.hp)
  if ch.ac > 0 then c.ac = c.ac + ch.ac end
  if ch.attack then
    -- how many times one attack action swings; see Combat.executeOn
    c.extraAttack = 2
  end
  if ch.con then
    c.scores = c.scores or {}
    c.scores.con = (c.scores.con or scoreOf(c, "con")) + 1
    c.mods = c.mods or {}
    c.mods.con = bonusFrom(c.scores.con)
  end
  c.hitDice = (c.hitDice or 0) + 1
  c.hpDice = { n = ch.level, d = cls.die or 8 }
  -- proficiency: the number behind every attack bonus, spell save DC and save
  c.prof = ch.prof or c.prof
  for _, a in ipairs(c.actions or {}) do
    a.toHit = a.toHit + ch.hit
    -- The level 5 damage step, and an invention: 5e hands a martial class Extra
    -- Attack, this engine rolls one attack per Action, so the die grows instead.
    -- Cantrips are excluded — spell damage scales with level already, and
    -- rewriting Fire Bolt's die is how a wizard ends up with a SMALLER cantrip.
    if ch.die and cls.weaponDie and not a.isCantrip then
      local step = Data.WEAPON_DIE_STEP
      local nd = math.min(cls.weaponDie + math.floor(ch.level / step.at) * step.sides,
        step.cap)
      a.damage = (a.damage or "1d6"):gsub("d%d+", "d" .. nd, 1)
    end
  end
  if ch.feat then
    if ch.featKey == "surge" then
      c.traits = c.traits or {}
      c.traits[#c.traits + 1] = { key = "surge", name = "Action Surge", bonus = true,
        desc = "take one extra action this turn",
        onUse = function(cc)
          if cc.flags.surgeUsed then return { error = "already used" } end
          cc.flags.surgeUsed = true
          cc.actionUsed = false
          DND.logf("|cffffe066%s uses Action Surge|r — a second action, right now.", cc.name)
          return { ok = true }
        end }
    elseif ch.featKey == "cunning" then
      c.traits = c.traits or {}
      c.traits[#c.traits + 1] = { key = "cunning", name = "Cunning Action", bonus = true,
        desc = "Dash, Disengage or Hide as a bonus action",
        onUse = function(cc, opts)
          return DND.Combat.useAction((opts and opts.which) or "disengage",
            { bonus = true })
        end }
    end
  end
  -- A caster's level is a row of C.SLOT_TABLE: the new slots arrive, the ones
  -- you already spent stay spent. That is the whole reason the delve works.
  if c.spellAbility and C.SLOT_TABLE[ch.level] then
    local newMax = C.SLOT_TABLE[ch.level]
    for lvl = 1, #newMax do
      local had = (c.slotMax and c.slotMax[lvl]) or 0
      c.slots[lvl] = c.slots[lvl] or 0
      local fresh = newMax[lvl] - had
      if fresh > 0 then c.slots[lvl] = c.slots[lvl] + fresh end
      if c.slots[lvl] > newMax[lvl] then c.slots[lvl] = newMax[lvl] end
    end
    -- copy, never alias: C.SLOT_TABLE is shared by every caster in the session
    local cap = {}
    for lvl = 1, #newMax do cap[lvl] = newMax[lvl] end
    c.slotMax = cap
  end
  c.xpNext = DND.xpNeededForLevel(c.level + 1)
  if c.level >= Data.MAX_LEVEL then c.xpNext = nil end
  Combatant.sync(c)
end

---------------------------------------------------------------------- building
--- The one place the delve learns what a "goblin" looks like at level 5. A CR
--- by level is not a thing in 5e, so this is a table that reads like one.
--- 5e hands a martial class Extra Attack at 5; this engine resolves one attack per
--- Action (for everything, monsters included), so the second swing is expressed as a
--- bigger die instead. One knob for both the plan and the application, so the prose in
--- `levelUpPlan` and the maths in `applyLevelUp` cannot drift: at 5 the longsword is a
--- d12, and the cap stops a second bump at 10 from inventing a d16.
Data.WEAPON_DIE_STEP = { at = 5, sides = 4, cap = 12 }
Data.LEVEL_STATS = { hpPerLevel = 8, acPerLevel = 0.5, toHitPerLevel = 0.75,
  dmgPerLevel = 1.5 }
local function bandFor(level)
  return ({ [1] = 50, [2] = 100, [3] = 150, [4] = 200, [5] = 250, [6] = 300 })[level]
      or level * 50
end
Data.bandFor = bandFor

--- Shallow copy, and it has to be shallow for the right reason: the generated
--- spec must never be written back into the bestiary row it came from, or the
--- second fight of the session starts worse than the first.
local function specCopy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end
Data.specCopy = specCopy

--- Turn a bestiary row into a statblock at a level. `level` nil or 1 means
--- "use the row exactly as written", which is what the showcase fights do.
function Data.buildSpec(key, level, side, hpOverride)
  local base = type(key) == "table" and key or Data.Bestiary[key]
  if not base then
    DND.logError("unknown creature: " .. tostring(key))
    return nil
  end
  local s = specCopy(base)
  -- Never scale *down*, not even the label: a row printed at level 3 that is asked
  -- to fight at level 1 keeps its level 3 numbers, and claiming L1 on a 29 hp body
  -- is how the XP maths and the sheet start disagreeing.
  s.level = math.max(level or 0, s.level or 1)
  if side then s.side = side end
  local L = Data.LEVEL_STATS
  -- scaled from the row's OWN level, so a delve rung whose mook is already
  -- printed at that level spawns exactly the printed statblock.
  local bonus = math.max(0, s.level - (base.level or 1))
  if bonus > 0 then
    local hitDice = s.hpDice and s.hpDice.n or 1
    s.hp = math.max(1, C.round((base.hp or 10) * (1 + 0.35 * bonus)))
    s.hpDice = { n = hitDice + bonus, d = s.hpDice and s.hpDice.d or 8 }
    s.ac = (base.ac or 12) + C.round(L.acPerLevel * bonus)
    s.xp = (base.xp or bandFor(math.max(s.level, base.level or 1))) + bonus * 25
    s.actions = {}
    for _, a0 in ipairs(base.actions or {}) do
      local a = specCopy(a0)
      a.toHit = (a.toHit or 2) + C.round(L.toHitPerLevel * bonus)
      local t = C.parseDice(a.damage or "1d6")
      if t and t.dice and #t.dice > 0 then
        -- one extra damage die every four levels plus a growing flat bonus: the
        -- 5e habit. The string is rebuilt from the parsed parts, never patched.
        local n = #t.dice + math.floor(bonus / 4)
        local dmg = C.round((t.mod or 0) + L.dmgPerLevel * bonus)
        a.damage = string.format("%dd%d", n, t.dice[1].d)
        if dmg ~= 0 then a.damage = a.damage .. C.signed(dmg) end
      elseif t then
        a.damage = tostring(C.round((t.mod or 0) + L.dmgPerLevel * bonus))
      end
      s.actions[#s.actions + 1] = a
    end
  else
    -- as written: a boss borrowed from a higher-level row keeps that row's worth
    s.xp = base.xp or bandFor(math.max(s.level, base.level or 1))
  end
  if hpOverride then s.hp = hpOverride end
  return s
end

--- Spawn from a spec. `x`/`y` may be nil, which means "the entry anchor" — the
--- only position the engine is allowed to invent.
function Data.spawnSpec(spec, x, y, opts)
  opts = opts or {}
  local s = specCopy(spec)
  if opts.name then s.name = opts.name end
  if opts.hp then s.hp = opts.hp end
  if opts.slots then s.slots = opts.slots end
  local cbt = Data.spawn(nil, x, y, { spec = s })
  cbt.delveIndex = opts.delveIndex
  return cbt
end

--- One whole side. Rosters come in two shapes and both end up in the same
--- place, which is what lets `-start tavern` (a list of names) and
--- `-start delve3` (a level and a count) share one function:
---   { "goblin", "ogre" }          spawn each row as written
---   { mook = "goblin", count = 4, level = 3 }   scale the row to that level
function Data.buildRoster(runningKey, roster, spots, side, level)
  local out = {}
  if type(roster) ~= "table" then return out end
  local function at(i)
    local p2 = spots and spots[i]
    return p2 and p2.x or nil, p2 and p2.y or nil
  end

  if roster.mook or roster.count then
    local level = roster.level or 1
    local n = roster.count or 1
    local isBoss = (n == 1 and roster.solo) and true or false
    local key = isBoss and roster.solo or roster.mook
    for i = 1, n do
      local spec = Data.buildSpec(key, level, side,
        (isBoss and roster.soloHp) or (roster.hp and roster.hp[i]))
      if spec then
        local x, y = at(i)
        local cbt = Data.spawnSpec(spec, x, y, { delveIndex = i })
        if cbt then
          cbt.xp = roster.xp or spec.xp or (level * 50)
          out[#out + 1] = cbt
        end
      end
    end
    return out
  end

  for i, item in ipairs(roster) do
    -- buildSpec never scales *down*, so a level below the row's own is a no-op and
    -- a showcase fight's rows stay exactly as printed.
    local spec = Data.buildSpec(item, level, side)
    if spec then
      local key = type(item) == "string" and item or nil
      spec.presetKey = key or spec.presetKey or spec.name
      local x, y = at(i)
      local cbt = Data.spawnSpec(spec, x, y, {})
      if cbt then
        cbt.presetKey = spec.presetKey
        out[#out + 1] = cbt
      end
    end
  end
  return out
end

---------------------------------------------------------------------- arenas
--- Two ways to say where a fight happens: a rectangle, or "on this ring".
--- Nothing here reads terrain, so a flat patch of grass is all a map needs.
local function ring(cx, cy, radius, n, phase)
  local out = {}
  for i = 1, math.max(1, n) do
    local a = (i - 1) / math.max(1, n) * 2 * math.pi + (phase or 0)
    out[#out + 1] = { x = cx + math.cos(a) * radius, y = cy + math.sin(a) * radius }
  end
  return out
end

local function lineFrom(pos, spacing, n)
  local out = {}
  for i = 1, math.max(1, n) do
    out[#out + 1] = { x = pos.x + (i - 1) * spacing, y = pos.y }
  end
  return out
end

local function rowOf(cx, cy, spacing, n, axis)
  local out = {}
  for i = 1, math.max(1, n) do
    local k = (i - (n + 1) / 2) * spacing
    if axis == "ns" then
      out[#out + 1] = { x = cx, y = cy + k }
    else
      out[#out + 1] = { x = cx + k, y = cy }
    end
  end
  return out
end

--- Keep a spawn point inside the arena rectangle. Cheap insurance for a 40 ft
--- ring drawn on a map whose playable area is smaller than you think.
local function clampTo(spots, bounds)
  if not spots or not bounds then return spots end
  for _, p in ipairs(spots) do
    p.x = math.max(bounds.x, math.min(bounds.x + bounds.w, p.x))
    p.y = math.max(bounds.y, math.min(bounds.y + bounds.d, p.y))
  end
  return spots
end

--- Work out the spots for both sides from the encounter's `arena` table.
function Data.arenaFor(arena, nParty, nFoes, opts)
  opts = opts or {}
  local centre = DND.entryAnchor or { x = 0, y = 0 }
  local cx, cy = centre.x, centre.y
  local snap = function(v) return math.floor(v / C.FIVE_FEET + 0.5) * C.FIVE_FEET end
  if not arena then
    -- No arena, or two anchors handed in by the caller: the classic "two ranks,
    -- 10 ft apart, facing each other", which is what `-start ambush` has always
    -- done. Keeping that path exact is why the anchors win here.
    local pp = opts.partyPos or { x = cx - C.ft(40), y = cy }
    local fp = opts.foePos or { x = cx + C.ft(40), y = cy }
    return {
      partyPos = lineFrom(pp, C.ft(10), nParty),
      foePos = lineFrom(fp, C.ft(10), nFoes),
    }
  elseif arena.kind == "circle" then
    local r = arena.radius or C.ft(40)
    return {
      partyPos = ring(cx, cy, r, nParty, math.pi),
      foePos = ring(cx, cy, r, nFoes, 0),
      radius = r,
    }
  else
    local w, d = snap(C.ft(arena.width or 80)), snap(C.ft(arena.depth or 60))
    return {
      partyPos = rowOf(cx, cy - d / 4, C.FIVE_FEET * 2, nParty, "ew"),
      foePos = rowOf(cx, cy + d / 4, C.FIVE_FEET * 2, nFoes, "ew"),
      bounds = { x = cx - w / 2, y = cy - d / 2, w = w, d = d },
    }
  end
end

---------------------------------------------------------------------- the delve
--- What a delve scales. `mook` is what four of them look like; `solo` is the
--- boss you meet only when the band numbers one, so the same ladder can be
--- played with a full party or a lone survivor and the maths still works.
--- Encounters are 1-indexed into `ladder`: the fifth room is the boss room.
Data.DelveLadder = {
  [1] = { name = "Goblin Cutthroats", mook = "goblin", solo = "hobgoblinCaptain",
    -- the printed captain is a level 3 brute (39 hp, AC 17, +2d6 in a rank). At
    -- 25 he is a scout captain: still the scary room, and four level 1
    -- characters can beat him with 8 hp of luck, which the run needs.
    hpSolo = 25, rooms = 4 },
  [2] = { name = "The Rot Gang", mook = "bandit", solo = "ogre", rooms = 4 },
  [3] = { name = "Bonewatch", mook = "skeleton", solo = "skeletonChampion",
    rooms = 4 },
  [4] = { name = "The Toll Keep", mook = "guard", solo = "banditCaptain",
    hpSolo = 45, rooms = 4 },
  -- The two deep rungs send two mooks per room, not three. A rung-5 mook is an
  -- orc reaver printed at level 5 (27 hp, 1d12+3): three of them is a Deadly
  -- encounter before the corridor has even taken its toll, and measured, every
  -- seed ended in a wipe. Two of them is the same fight the book would run.
  -- Two mooks per room on the deep rungs, and a boss whose hit points are stated
  -- rather than inherited. The reason both dials are needed: a monster row is never
  -- scaled *down* (see buildSpec's math.max on the level), so asking for `mookDown`
  -- on a row printed at level 5 or 6 changes nothing at all — measured, the rungs
  -- wiped 12 of 12 seeds either way. What does move the fight is how many bodies
  -- swing at the party and how much hit the party has to chew through, which is
  -- exactly what `mookCount` and `hpSolo` are.
  [5] = { name = "Ironjaw Camp", mook = "orcReaver", mookCount = 2, mookDown = 2,
    solo = "ogre", hpSolo = 55, rooms = 4 },
  -- The Silk Hall's last room is the brood mother, not the dragon. The printed
  -- Young Red Dragon is 178 hp with a 16d6 breath, which is a level 11 fight in the
  -- book and a party-wipe button at 6; it is on the `-start dragon` card for anyone
  -- who wants to find out.
  [6] = { name = "Silk Hall", mook = "spiderBrood", mookCount = 2, mookDown = 2,
    solo = "spiderBrood", hpSolo = 90, rooms = 4 },
}
Data.DelveLength = 4     -- rooms, the fourth being the boss

---------------------------------------------------------------------- carry
--- Between rooms the party is NOT rebuilt from the bestiary: the same objects
--- walk into the next room. That is what a delve means at a table — the
--- characters persist, the room is what changes — and it is the only way every
--- level, feat, spell slot and wound a room cost you survives the cut.
Data.CarriedParty = {}

--- Bank the live party. Called at the end of each room and after any rest.
function Data.saveCarry(party)
  local out = {}
  for _, c in ipairs(party or Data.party()) do
    if c.side == C.SIDE.PARTY and not c.removed then
      c.presetKey = c.presetKey or c.name
      out[#out + 1] = c
    end
  end
  Data.CarriedParty = out
  return out
end

--- A wipe. 5e is not polite about this: you do not come back at full strength,
--- you come back at whatever the party could scrape together, and every spell
--- slot you burned getting out is still burned. Levels and XP are not taken
--- back, because they were earned.
function Data.wipeToll()
  for _, c in ipairs(Data.CarriedParty) do
    c.hp = math.max(1, C.round(c.hpMax * 0.5))
    for lvl = 1, #(c.slotMax or {}) do c.slots[lvl] = 0 end
    c.hitDice = 0
    Data.standUp(c)
    Combatant.sync(c)
  end
end

--- Somebody stabilised you before the dungeon door. A carried character who is
--- still flagged `downed` wedges the turn machine — the rules layer sees 0 hit
--- points and immediately starts death saves again — so the flag comes off
--- here, once, at the threshold of a new room, whatever the last one did to
--- the numbers.
function Data.standUp(c)
  c.downed = false
  c.deathSaves = { success = 0, fail = 0 }
  if (c.hp or 0) <= 0 then c.hp = 1 end
  c.flags = c.flags or {}
  c.flags.dodging = nil
  c.flags.hidden = nil
  c.flags.disengaged = nil
  c.flags.readied = nil
  c.flags.pendingOpportunity = nil
end

--- Start over: a brand new party, nothing carried. This is also what `-party`
--- does, because a different party has no history with this dungeon.
function Data.newParty()
  Data.CarriedParty = {}
end

--- Retire the actors from the room you just finished, keeping the carried
--- heroes registered. Without this the delve's `Data.party()` is a census of
--- everyone you have ever met, and XP lands on ghosts.
function Data.dropPreviousFight(keep)
  if not keep or #keep == 0 then
    Combatant.clearAll()
    return
  end
  local keepSet = {}
  for _, c in ipairs(keep) do keepSet[c] = true end
  local drop = {}
  for _, c in ipairs(Combatant.all()) do
    if not keepSet[c] then drop[#drop + 1] = c end
  end
  for _, c in ipairs(drop) do
    if not c.removed then Combatant.remove(c) end
  end
  -- `removed` only unregisters the handle; the ordered list has to be rebuilt or
  -- every room you clear leaves its corpses in Combatant.all() forever.
  if Combatant.compact then Combatant.compact() end
end

---------------------------------------------------------------------- parties
--- Named parties. `random` is the interesting one: it rolls four fresh level 1
--- characters, which is the only way to see what the level ladder is for.
Data.PartyPresets = {
  heroes = { "humanFighter", "halflingRogue", "elfWizard", "hillDwarfCleric" },
  nils = { "halflingRogue", "halflingRogue" },
  muscle = { "humanFighter", "hillDwarfCleric" },
  random = function(n)
    local out = {}
    for i = 1, n or 4 do
      out[i] = Data.rollLevel1(ROLL_CLASSES[i % 4 + 1], nil, i - 1)
    end
    return out
  end,
}

--- Resolve `--party <name>` into a roster (a list of keys and/or specs).
function Data.partyRoster(name, n)
  local p = Data.PartyPresets[name or "heroes"]
  if type(p) == "function" then return p(n) end
  if p then return p end
  -- a bare class name: one character, for `-party rogue`
  local classes = { fighter = "Fighter", rogue = "Rogue", cleric = "Cleric",
                    wizard = "Wizard", mage = "Wizard" }
  if classes[(name or ""):lower()] then return { Data.rollLevel1(classes[name:lower()]) } end
  return Data.Party
end

---------------------------------------------------------------------- encounters
--- The showcase fights. `party`/`foes` are lists of bestiary keys, which is all
--- an encounter has ever needed to be; the delve rungs below use the level form.
Data.Encounters = {
  ["ambush"] = {
    name = "Roadside Ambush",
    party = { "humanFighter", "halflingRogue", "elfWizard", "hillDwarfCleric" },
    foes = { "goblin", "goblin", "goblin", "hobgoblinCaptain" },
    hint = "Three goblins in the trees, a captain on the road. The rogues roll "
        .. "Stealth; whoever fails is surprised.",
  },
  ["tavern"] = {
    name = "Tavern Brawl",
    party = { "humanFighter", "halflingRogue" },
    foes = { "banditCaptain", "orc", "orc" },
    arena = { kind = "rect", width = 40, depth = 30 },
    hint = "Tight room: 40 x 30 ft, so nobody can walk around anyone.",
  },
  ["dragon"] = {
    name = "The Red Scales",
    party = { "humanFighter", "halflingRogue", "elfWizard", "hillDwarfCleric" },
    foes = { "youngDragon", "goblin", "goblin", "wolf", "wolf" },
    hint = "Fire Breath recharges on a 5-6. Spread out or eat the cone.",
  },
  ["mirror"] = {
    name = "Mirror Wall (AI vs AI)",
    party = { "hillDwarfCleric", "elfWizard", "orc", "ogre" },
    foes = { "banditCaptain", "youngDragon", "goblin", "goblin" },
    bothAI = true,
    hint = "Nobody presses a button: the AI runs both sides. Great soak test.",
  },
  ["tourney"] = {
    name = "Tournament Yard (4 x 4 on a grid)",
    party = { "humanFighter", "halflingRogue", "elfWizard", "hillDwarfCleric" },
    foes = { "guard", "guard", "bandit", "bandit" },
    arena = { kind = "rect", width = 60, depth = 40, grid = true },
    hint = "Two ranks, 60 x 40 ft, movement on the 5 ft grid. The guards have "
        .. "10 ft reach: the front rank cannot walk past them for free.",
  },
}

--- The delve rungs, generated rather than hand-typed so the level in the key is
--- the level in the maths. `-start delve3` is four rooms of level 3 mooks and
--- one boss. Every rung is a real encounter table, so `-start delve6` on a
--- level 1 party is a fun house and the same thing at level 6 is a slog.
Data.DelveLength = 4

--- Build Data.Encounters["delveN"] from the ladder.
local function registerDelves()
  for level = 1, 6 do
    local band = Data.DelveLadder[level]
    Data.Encounters["delve" .. level] = {
      name = band.name,
      runningKey = "delve" .. level,
      level = level,
      rooms = Data.DelveLength,
      arena = { kind = "circle", radius = C.ft(40) },
      carry = true,
      rest = false,       -- no free sheet: see Combat.startEncounter's opts.rest
      corridorRest = 2,   -- ...and two hours in the corridor instead: one Hit Die each
      party = "random",
      -- room size follows the party's level: four mooks at level 1 is a Deadly
      -- encounter by the book (200 adjusted XP for 7 hp wizards), so rung 1 is
      -- a short fight and rung 6 is a long one.
      -- The mook rooms sit one level below the party and only the boss room sits at
      -- it. Four monsters at your own level, four rooms deep, with nothing but Hit
      -- Dice between them, is a Deadly encounter x4 by the book — measured, a rolled
      -- party at equal levels lost 12 of 12 runs from rung 4 up. One level down and
      -- the corridor is what makes the run a climb instead of a wall.
      foes = { count = band.mookCount or ({ [1] = 2, [2] = 3 })[level] or 3, level = level,
               mookLevel = math.max(1, level - (band.mookDown or 1)),
               soloLevel = level,
               mook = band.mook, solo = band.solo, soloHp = band.hpSolo },
      hint = "Four rooms of " .. (Data.Bestiary[band.mook] or {}).name .. " at level "
          .. level .. ", then " .. (Data.Bestiary[band.solo] or {}).name .. " alone in "
          .. "the last one. Two hours in the corridor between them is one Hit Die "
          .. "each and nothing else: no spell slot comes back. -rest long after the "
          .. "run, if you survive it.",
    }
  end
end

registerDelves()

--- What this run is worth, per body, before anyone rolls a die.
function Data.rosterXp(list)
  local total = 0
  for _, f in ipairs(list or {}) do total = total + (f.xp or 0) end
  return total
end

--- Per-run bookkeeping: which room you are in, whether the party has been
--- wiped, what the dead have cost. Not a save game: closing the map forgets it.
function Data.delveState(key)
  Data.Delve = Data.Delve or {}
  local s = Data.Delve[key]
  if not s then
    s = { key = key, done = 0, room = 0, wipe = false, cleared = false,
      deaths = 0, level = 1, lastResult = nil }
    Data.Delve[key] = s
  end
  return s
end

local function hpLine(party)
  local bits = {}
  for _, c in ipairs(party) do bits[#bits + 1] = c.name .. " " .. c.hp .. "/" .. c.hpMax end
  return table.concat(bits, ", ")
end

--- Everyone on the party side, in spawn order, still on the roster. The delve
--- needs this outside a fight (that is the point of a rest), so it walks the
--- combatant list rather than the turn order.
function Data.party()
  local out = {}
  for _, c in ipairs(Combatant.all()) do
    if not c.removed and c.side == C.SIDE.PARTY then out[#out + 1] = c end
  end
  return out
end

function Data.foes()
  local out = {}
  for _, c in ipairs(Combatant.all()) do
    if not c.removed and c.side == C.SIDE.FOES then out[#out + 1] = c end
  end
  return out
end

--- The one entry point for everything: showcase fight, delve rung, or a table
--- you built yourself. `key` is a string in Data.Encounters or a table.
--- opts: { encounter, atLevel, party, partySize, partyPos, foePos, carry,
---         rest, surprise, quiet }.
function Data.startEncounter(key, opts)
  opts = opts or {}
  local enc = type(key) == "table" and key or Data.Encounters[key]
  if not enc then
    DND.logError("no encounter: " .. tostring(key) .. "  (try ambush, tavern, "
      .. "dragon, mirror, tourney, delve1..delve6)")
    return nil
  end
  local runningKey = enc.runningKey or (type(key) == "string" and key or nil)
  local state = runningKey and Data.delveState(runningKey) or nil
  -- A carried run must not be restarted by accident: `Combat.startEncounter`
  -- aborts whatever is running, and for a showcase fight that is fine, but here
  -- it would throw away the room you are still fighting and the hit points the
  -- next one is supposed to inherit. Say so instead.
  if enc.carry and opts.carry ~= false and DND.Combat.state.running then
    DND.logf("A room is still being played. |cffffcc00-end|r it first — starting "
      .. "over would drop the hit points and spell slots this run is tracking.")
    return nil
  end
  -- `-party` and `opts.party` both mean "this is a different party", so the
  -- carried one is dropped; an explicit `carry = false` means "fresh bodies
  -- from the same roster", which is what a replay of a showcase fight wants.
  if opts.party then Data.newParty() end
  local carried = (enc.carry and opts.carry ~= false and not opts.party)
      and Data.CarriedParty or nil
  if carried and #carried == 0 then carried = nil end
  -- The last room's actors have to be retired or `Data.party()` counts ghosts
  -- and XP lands on corpses. A map that owns its own cast passes
  -- `keepRoster = true` and does this itself.
  if not opts.keepRoster then Data.dropPreviousFight(carried) end
  -- One level knob for the whole room. It used to be read as "the rung wins" for
  -- the party and "the override wins" for the foes, which is how `-delve 6` ended up
  -- a level 6 corridor full of level 3 goblins whenever anything passed atLevel.
  local level = opts.atLevel or enc.level or 1
  local room = opts.encounter or ((state and state.room or 0) + 1)
  local rooms = enc.rooms or 1
  if rooms > 1 then room = ((room - 1) % rooms) + 1 end
  local isBoss = rooms > 1 and room >= rooms

  -- Only a party with no history gets chosen from the console: once the delve
  -- has bodies to carry, `DND.presetParty` must not reach in and replace them.
  local partyName = opts.party or (not carried and DND.presetParty)
  local partyRoster = enc.party
  -- A row may name its party (`party = "random"`) instead of typing a roster, and a
  -- name is only useful if it goes through the same lookup the chat command uses.
  if type(partyRoster) == "string" then partyName = partyName or partyRoster end
  if type(partyName) == "string" then
    partyRoster = Data.partyRoster(partyName, opts.partySize)
  elseif type(partyName) == "table" then
    partyRoster = partyName
  end

  -- foes: the band for this room, at the delve's level
  local foeRoster = enc.foes
  if type(foeRoster) == "table" and (foeRoster.mook or foeRoster.count) then
    foeRoster = specCopy(foeRoster)
    -- a room of mooks and the solo boss are budgeted separately (see registerDelves)
    foeRoster.level = (isBoss and (foeRoster.soloLevel or level))
        or (foeRoster.mookLevel or level)
    foeRoster.count = isBoss and 1 or (enc.foes.count or 4)
    foeRoster.soloHp = isBoss and enc.foes.soloHp or nil
    foeRoster.solo = isBoss and enc.foes.solo or nil
  end

  local nParty = type(partyRoster) == "table" and #partyRoster or 0
  local nFoes = type(foeRoster) == "table" and (foeRoster.count or #foeRoster) or 0
  local spots = Data.arenaFor(enc.arena, nParty, nFoes, opts)
  if spots.bounds then
    clampTo(spots.partyPos, spots.bounds)
    clampTo(spots.foePos, spots.bounds)
  end

  -- Hours in the corridor between rooms. The *run* owns this number (a delve row
  -- says `corridorRest = 2`), because a chat command that edits a global config to
  -- set up one fight is a switch you discover is on three fights later.
  -- `DND.config.restBetweenRooms` overrides it in both directions: `false` for a
  -- pure-attrition delve, a number to rest on a showcase fight that has no opinion.
  local rest = DND.config.restBetweenRooms
  if rest == nil then rest = enc.corridorRest end
  if rest == true then rest = 1 end
  if carried and rest then
    DND.logf("%d hour(s) in the corridor: one Hit Die each per hour, and that is "
      .. "all a short rest is.", rest)
    Data.shortRest(rest)
  end
  local party
  if carried then
    party = {}
    for i, c in ipairs(carried) do
      Data.standUp(c)
      party[#party + 1] = c
      -- the new room is laid out around the ring; stand the heroes on their side
      -- of it so the first round is not spent walking back to where you were
      local p = spots.partyPos and spots.partyPos[i]
      if p and c.unit then DND.w3.moveTo(c.unit, p.x, p.y) end
    end
  else
    -- No `level` on the party's buildRoster call, on purpose: the padding in
    -- Data.LEVEL_STATS would arrive with `c.level` already set, the walk below would
    -- find nothing to do, and a "level 6 fighter" would be a d8+11 statblock with one
    -- hit die. Monsters keep the padding, because a monster's CR bump is not a class
    -- level. A class party grows the way the XP ladder grows it: same change records.
    party = Data.buildRoster(runningKey, partyRoster, spots.partyPos, C.SIDE.PARTY)
    for _, c in ipairs(party) do
      if c.class and level > (c.level or 1) then
        for _, ch in ipairs(Data.levelUpPlan(c, level)) do Data.applyLevelUp(c, ch) end
        c.xpEarned = DND.xpNeededForLevel(c.level)
        c.xpNext = c.level < Data.MAX_LEVEL and DND.xpNeededForLevel(c.level + 1) or nil
      end
    end
  end
  local foes = Data.buildRoster(runningKey, foeRoster, spots.foePos, C.SIDE.FOES, level)
  if #party == 0 then
    DND.logError("the party could not be built — check the bestiary keys")
    return nil
  end

  local xpTotal = Data.rosterXp(foes)
  local perHead = math.ceil(xpTotal / #party)
  for _, c in ipairs(party) do c.xpAward = perHead end
  for i, c in ipairs(foes) do c.delveIndex = i end

  if state then
    state.level = level
    state.room = room
    state.encounter = (state.encounter or 0) + 1
  end

  local label = (enc.name or "Encounter")
      .. (rooms > 1 and (" — room " .. room .. "/" .. rooms .. (isBoss and " (boss)" or "")) or "")
      .. (level > 1 and ("  [lvl " .. level .. "]") or "")
  if not opts.quiet then
    DND.logf("%s", "|cffccd6ff" .. label .. "|r")
    if enc.hint then DND.logf(enc.hint) end
    if carry then DND.logf("Carried in: %s.", hpLine(party)) end
    if isBoss then
      DND.logf("|cffff9c66%s|r stands alone in the last room: %d hp, AC %d, and it "
        .. "is worth %d XP between them.", foes[1] and foes[1].name or "the boss",
        foes[1] and foes[1].hpMax or 0, foes[1] and foes[1].ac or 0, xpTotal)
    end
    DND.logf("This room is worth %d XP, %d each.", xpTotal, perHead)
  end

  local all = {}
  for _, v in ipairs(party) do all[#all + 1] = v end
  for _, v in ipairs(foes) do all[#all + 1] = v end
  DND.Combat.startEncounter(label, all, {
    surprise = enc.surprise, bounds = spots.bounds, aiBoth = enc.bothAI,
    encounterKey = runningKey, encounterIndex = room,
    -- the delve's two real switches, read back at the end of the fight.
    -- `rest` here is the engine's "new fight, fresh sheet" refill (hit dice up to
    -- your level, slots back to max). A carried room turns it off — the corridor
    -- rest above is what heals you instead, and it costs dice.
    carryOn = enc.carry and opts.carry ~= false,
    rest = enc.rest ~= false,
  })
  local rec = DND.Combat.state.encounter
  if rec then
    rec.runningKey = runningKey
    rec.room = room
    rec.rooms = rooms
    rec.isBossRoom = isBoss
    rec.delveLevel = level
    rec.xpTotal = xpTotal
    rec.xpAward = perHead
    rec.carryOn = enc.carry and opts.carry ~= false
    rec.restAfterFight = enc.rest ~= false
    rec.partyCount = #party
  end
  return rec, party, foes
end


---------------------------------------------------------------------- the ledger
--- Called from the map's victory hook. This is the only place XP becomes levels.
function Data.afterVictory(xp, rec, result)
  rec = rec or DND.Combat.state.encounter
  local party = Data.party()
  local defeated = result == "defeat"
  if defeated then xp = 0 end
  local levels = 0
  local downed = 0
  for _, c in ipairs(party) do
    if c.hp <= 0 or c.downed then downed = downed + 1 end
    local award = (not defeated) and (c.xpAward
        or math.ceil((xp or 0) / math.max(1, #party))) or 0
    if award > 0 then
      local gained = Data.awardXp(c, award, DND.testMode)
      levels = levels + #gained
    end
    c.xpTotal = (c.xpTotal or 0) + (award or 0)
  end
  Data.saveCarry(party)

  local state = rec and rec.runningKey and Data.delveState(rec.runningKey)
  local wiped = defeated or (#party > 0 and downed == #party)
  if state then
    if wiped then
      state.wipe = true
      state.deaths = (state.deaths or 0) + downed
      state.lastResult = defeated and "defeat" or "wipe"
      DND.logf("|cffff6666The party is dead in the room.|r Somebody drags the "
        .. "bodies out: you come back at half hit points, and every spell slot you "
        .. "burned getting out stays burned. The XP you earned stays earned.")
      Data.wipeToll()
    else
      state.lastResult = "win"
      if rec and rec.isBossRoom and (rec.room or 0) >= (rec.rooms or 1) then
        state.cleared = true
      end
    end
  end
  if rec and rec.carryOn and not wiped then
    for _, c in ipairs(party) do
      if c.hp <= 0 then
        DND.logf("|cffff9c66%s is down and stays down: a delve does not stabilise "
          .. "itself. Carry them out, or leave them.|r", c.name)
        Data.standUp(c)   -- a corpse cannot take a turn; the party is not TPK yet
        DND.Combatant.sync(c)
      end
    end
  end
  if not DND.testMode then
    DND.logf("%s", Data.progressLine(state))
  end
  return { levels = levels, downed = downed, wiped = wiped }
end

--- The progress line, in world units, so a failed delve tells you what the party
--- is worth now and not just where it died.
function Data.progressLine(state)
  state = state or (DND.activeCombat and DND.activeCombat.runningKey
    and Data.delveState(DND.activeCombat.runningKey))
  local bits = {}
  local party = Data.party()
  for _, c in ipairs(party) do
    bits[#bits + 1] = string.format("%s L%d %d/%d hp AC %d", c.name, c.level or 1,
      c.hp, c.hpMax, c.ac)
  end
  local line = "Party: " .. table.concat(bits, "  |  ")
  if state then
    local roomTxt = state.cleared and "run cleared"
        or (state.wipe and "wiped, cost " .. (state.deaths or 0) .. " death saves"
        or ("room " .. (state.room or 0) .. "/" .. (Data.DelveLength or 4)))
    line = line .. string.format("\n%s [%s]: %s  (%d xp each so far)",
      state.key, roomTxt, state.lastResult or "pending",
      party[1] and party[1].xpEarned or 0)
  end
  return line
end

---------------------------------------------------------------------- resting
--- A rest resets whatever the rules marked as "once per rest": every trait in
--- this file names its flag ...Used, so the convention IS the interface.
local function clearOncePerRest(c)
  if not c.flags then return end
  local drop = {}
  for k in pairs(c.flags) do
    if type(k) == "string" and k:match("Used$") then drop[#drop + 1] = k end
  end
  for _, k in ipairs(drop) do c.flags[k] = nil end
end

--- 5e's rest economy, on the two numbers a short rest actually moves.
function Data.shortRest(nHours)
  nHours = nHours or 1
  if nHours < 1 then
    DND.logf("That is not a rest. An hour, minimum, or you get nothing.")
    return { ok = false }
  end
  local party = Data.party()
  local out = {}
  for _, c in ipairs(party) do
    local spend = math.min(c.hitDice or 0, nHours)
    local healed = 0
    local die = c.hpDice and c.hpDice.d or 8
    for _ = 1, spend do
      healed = healed + math.max(1, DND.Dice.rollExpr("1d" .. die).total + modOf(c, "con"))
    end
    local before = c.hp
    if spend > 0 then
      c.hitDice = (c.hitDice or 0) - spend
      DND.Resolve.heal(c, healed)
      clearOncePerRest(c)
    end
    -- report the hit points that actually arrived. Spending a die while already
    -- whole wastes the die, and a log that says "+6" over an unmoved sheet is
    -- the kind of white lie that makes a player distrust the whole character.
    local got = c.hp - before
    out[#out + 1] = { name = c.name, spent = spend, healed = got, hp = c.hp }
    DND.logf("%s spends %d Hit Die: %s (%d/%d, %d dice left).", c.name, spend,
      got > 0 and ("+" .. got .. " hp") or "nothing back, already whole",
      c.hp, c.hpMax, c.hitDice or 0)
  end
  DND.logf("An hour passes. The 5e maths: one Hit Die per hour, no more.")
  Data.saveCarry(party)
  return { ok = true, party = out }
end

--- A long rest: eight hours, half the hit dice back, every spell slot, and the
--- delve's clock reset to the beginning of the rung.
function Data.longRest()
  local party = Data.party()
  for _, c in ipairs(party) do
    c.hp = c.hpMax
    local dice = c.level or 1
    c.hitDice = math.min(dice, math.floor(dice / 2) + (c.hitDice or 0))
    for lvl = 1, #(c.slotMax or {}) do c.slots[lvl] = c.slotMax[lvl] end
    clearOncePerRest(c)
    Combatant.sync(c)
    DND.logf("%s wakes at %d/%d hp with %d Hit Die and every spell slot back.",
      c.name, c.hp, c.hpMax, c.hitDice or 0)
  end
  for _, c in ipairs(party) do
    if DND.ui and DND.ui.refreshStatus then DND.ui.refreshStatus(c) end
  end
  Data.saveCarry(party)
  DND.logf("Eight hours. That is the whole day spent, and you get it all back.")
  return true
end

--- The DM's hand: hand out XP without a fight, and watch the levels land.
function Data.grantXp(amount)
  local party = Data.party()
  local per = math.ceil((amount or 0) / math.max(1, #party))
  local up = 0
  for _, c in ipairs(party) do
    up = up + #Data.awardXp(c, per, false)
    c.xpTotal = (c.xpTotal or 0) + per
  end
  Data.saveCarry(party)
  DND.logf("%d XP each, %d level(s) gained.", per, up)
  return up
end

--- Where every fight goes through, including the old one-call form.
function Data.run(key, partyPos, foePos)
  return Data.startEncounter(key, { partyPos = partyPos, foePos = foePos })
end

Data.delveHelp = function()
  DND.logf("Delve: -delve 1 .. -delve 6, or -start delve3 (four rooms, XP between")
  DND.logf("       them). -party heroes|muscle|nils|random picks who walks in.")
  DND.logf("       -levelup reads the sheets, -xp 500 skips ahead, -rest rests.")
  DND.logf("       -rest short|long  -progress  -party heroes|random  -end")
end

--- The engine calls this at victory with (xp, encounterRecord). dnd_combat.lua
--- does not know what an XP award is; this file decides. Overridable, because
--- a real map will want to hand out treasure too.
DND.afterCombatHook = Data.afterVictory

return Data
