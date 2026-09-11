--[[ =========================================================================
  dnd_resolve.lua — the rules. Attack rolls, saves, damage, death, rests.

  Every entry point is split into "roll" and "apply" halves. That is what makes
  reactions legal here: the attacker's swing pauses in flight, the defender is
  asked for an Opportunity Attack / Shield / counterspell, and only then does
  the damage land. No coroutine, no polling, no timers — just a pending object
  that the state machine hands to Resolve.commit().
========================================================================== ]]
DND = DND or {}
DND.Resolve = {}
local Resolve = DND.Resolve
local C = DND.CONST
local Dice = DND.Dice
local w3 = DND.w3
local Combatant = DND.Combatant

---------------------------------------------------------------------- events
-- Minimal message bus so resolve.lua never has to know about the UI.
local listeners = {}
function DND.on(evt, fn)
  listeners[evt] = listeners[evt] or {}
  local l = listeners[evt]
  l[#l + 1] = fn
  return #l
end
function DND.emit(evt, a, b, c, d)
  local l = listeners[evt]
  if not l then return end
  for i = 1, #l do l[i](a, b, c, d) end
end

---------------------------------------------------------------------- helpers
local function resistMult(target, dtype)
  if not dtype then return 1 end
  local r = target.resists and target.resists[dtype]
  if not r then return 1 end
  return C.RESIST_MULT[r] or 1
end

--- Advantage sources that WC3 makes cheap to check.
--- Half / three-quarter cover, judged by counting hostile-agnostic bodies and
--- props that sit in the lane between the two. Coarse, cheap, and true to 5e.
function Resolve.coverBonus(attacker, target)
  if not DND.config.cover then return 0 end
  local d = w3.dist(attacker.unit, target.unit)
  if d <= C.FIVE_FEET then return 0 end
  local blockers = 0
  local x1, y1 = GetUnitX(attacker.unit), GetUnitY(attacker.unit)
  local x2, y2 = GetUnitX(target.unit), GetUnitY(target.unit)
  local steps = C.clamp(C.round(d / C.ft(5)), 2, 12)
  for i = 1, steps - 1 do
    local t = i / steps
    local px, py = x1 + (x2 - x1) * t, y1 + (y2 - y1) * t
    local g = CreateGroup()
    GroupEnumUnitsInRect(g, Rect(px - C.FIVE_FEET, py - C.FIVE_FEET,
                                 px + C.FIVE_FEET, py + C.FIVE_FEET), nil)
    local seen = false
    ForGroup(g, function()
      local u = GetEnumUnit()
      if not seen and u ~= target.unit and u ~= attacker.unit then
        seen = true
        blockers = blockers + 1
      end
    end)
    DestroyGroup(g)
  end
  if blockers >= 2 then return 5 end
  if blockers == 1 then return 2 end
  return 0
end

function Resolve.situationalAdv(attacker, target, action)
  local adv = 0
  local notes = {}
  -- Melee attacks against a prone, restrained, unconscious, paralyzed or
  -- stunned creature have advantage; ranged ones have DISADVANTAGE against
  -- prone. Both halves matter — a sniper should not be rewarded for shooting
  -- someone who is on the ground.
  if DND.hasCond(target, "prone") then
    if action.range then
      adv = adv - 1; notes[#notes + 1] = "prone target, shooting from range"
    else
      adv = adv + 1; notes[#notes + 1] = "target is prone"
    end
  end
  if DND.hasCond(target, "paralyzed") or DND.hasCond(target, "stunned")
     or DND.hasCond(target, "unconscious") or DND.hasCond(target, "restrained")
     or DND.hasCond(target, "grappled") then
    if not action.range then adv = adv + 1; notes[#notes + 1] = "target is easier to hit" end
  end
  -- 5e, the rule that punishes the archer: a ranged attack made from within a
  -- hostile creature's reach has disadvantage. Checked from the TARGET's side
  -- because that is where the threat is visible (the attacker does not get to
  -- consult its enemies' reach lists).
  if action.range then
    for _, other in ipairs(DND.Combat.livingOf(attacker.side == C.SIDE.PARTY
                                                and C.SIDE.FOES or C.SIDE.PARTY)) do
      local oa = Combatant.primaryAttack(other)
      if oa and not oa.range and other.hp > 0
         and w3.dist(attacker.unit, other.unit) <= (oa.reach or C.ft(5)) + C.FIVE_FEET then
        adv = adv - 1
        notes[#notes + 1] = "ranged attack from " .. other.name .. "'s reach"
        break
      end
    end
  end
  if DND.hasCond(attacker, "poisoned") or DND.hasCond(attacker, "frightened")
     or DND.hasCond(attacker, "prone") then
    adv = adv - 1; notes[#notes + 1] = "attacker hindered"
  end
  if DND.hasCond(attacker, "blinded") then adv = adv - 1; notes[#notes + 1] = "blinded" end
  if target.flags.hidden then adv = adv + 1; notes[#notes + 1] = "target is unaware" end
  if attacker.flags.invisible then adv = adv + 1; notes[#notes + 1] = "invisible" end
  return adv, notes
end

function Resolve.rangeOk(attacker, target, action)
  local need = action.reach or C.ft(5)
  if action.range then need = C.ft(action.range) end
  local d = w3.dist(attacker.unit, target.unit)
  if d > need + C.FIVE_FEET then return false, d, need end
  if action.minRange and d < C.ft(action.minRange) then return false, d, need end
  return true, d, need
end

---------------------------------------------------------------------- damage
--- Apply damage through resistances, break concentration, maybe kill.
function Resolve.applyDamage(target, amount, opts)
  opts = opts or {}
  local mult = resistMult(target, opts.type)
  local dealt = math.max(0, C.round(amount * mult))
  if opts.flatReduce then dealt = math.max(0, dealt - opts.flatReduce) end
  if dealt <= 0 then
    DND.logf("%s takes none — %s", target.name,
      mult == 0 and "immune" or (opts.flatReduce and "reduced" or "soaked"))
    return 0
  end
  local before = target.hp
  target.hp = target.hp - dealt
  if target.hp < 0 then target.hp = 0 end
  DND.emit("damage", target, dealt, before, opts)

  -- concentration: the rule everyone forgets
  if target.concentration then
    local dc = math.max(10, C.round(dealt / 2))
    local ok = Dice.check(Combatant.saveBonus(target, "con"), { dc = dc, name = "Concentration" })
    DND.logf("%s concentrates on %s — CON save DC %d: %s%s", target.name,
      target.concentration.spell, dc, ok.success and "held" or "BROKEN",
      (mult == 0 and "") or "")
    if not ok.success then Resolve.breakConcentration(target, "taking damage") end
  end

  if target.hp <= 0 then
    if opts.crit or Resolve.meleeAttackRoll(before, opts) then
      Resolve.twoDeathSaves(target, opts.crit and "critical hit" or "damage while at 0")
    else
      Resolve.enterDowned(target, opts)
    end
  end
  Combatant.sync(target)
  return dealt
end

function Resolve.meleeAttackRoll(_, opts)
  return opts and opts.at0 and true or false
end

function Resolve.breakConcentration(target, why)
  if not target.concentration then return false end
  DND.logf("%s's %s ends (%s)", target.name, target.concentration.spell, why)
  DND.emit("concentration", target, nil)
  target.concentration = nil
  if target.flags.dodging then target.flags.dodging = nil end
  if target.flags.readied then target.flags.readied = nil end
  if target.flags.shield then target.flags.shield = nil end
  return true
end

---------------------------------------------------------------------- attack
--- Damage for one swing. Split out from Resolve.attack so the "crit doubles the
--- DICE, never the modifier" rule can be tested without an encounter.
function Resolve.damageRoll(attacker, action, crit)
  local expr, declared = action.damage, true
  local dmod = action.dmod
  if dmod == nil then
    dmod = action.ability and attacker.mods[action.ability] or attacker.mods.str
    if action.finesse then dmod = math.max(attacker.mods.str, attacker.mods.dex) end
  end
  if action.noMod then dmod = 0 end
  -- A statblock may either say "1d12" (the engine adds the ability modifier,
  -- which is how a Finesse or versatile weapon stays correct) or "1d12+4" (the
  -- writer already did the arithmetic, so the engine must not add it again or
  -- every barbarian in the map hits for +STR twice).
  if not action.includesMod and not action.noMod then
    local stripped = tostring(action.damage):match("^(%d*d%d+)")
    if stripped then expr, declared = stripped, false end
  end
  local t = C.parseDice(expr)
  if not t then return { total = 0, faces = {}, label = "0", count = 0 } end
  local r = Dice.rollTemplate(t, {
    double = crit,
    bonus = declared and 0 or dmod,
    min = 1 })
  if not declared then
    r.label = string.format("%dd%d%s%d", #t.dice,
      (t.dice[1] and t.dice[1].d) or 0, (dmod >= 0 and "+" or ""), dmod)
  end
  r.label = r.label or C.diceLabel(t)      -- never nil; the log formats this
  for _, extra in ipairs(action.extraDice or {}) do
    local er = Dice.rollExpr(extra.expr, { double = crit, max = extra.max,
                                           bonus = extra.mod or 0 })
    r.total = r.total + er.total
    for _, f in ipairs(er.faces) do r.faces[#r.faces + 1] = f end
  end
  r.crit = crit and true or false
  return r
end

---------------------------------------------------------------------- attack
--- Phase 1. Returns a `pending` object, or { error = "..." }.
function Resolve.attack(attacker, target, action, opts)
  opts = opts or {}
  if not attacker or not target then return { error = "no target" } end
  if attacker.hp <= 0 then return { error = "attacker is down" } end
  -- The action-economy check lives in Combat (it needs turn state); this layer
  -- only knows whether the swing is legal in space and against this target.

  local ok = Resolve.rangeOk(attacker, target, action)
  if opts.opportunity then ok = true end
  if not ok then
    local away = C.round(C.unitsToFeet(w3.dist(attacker.unit, target.unit)))
    local need = C.round(C.unitsToFeet(action.reach or C.ft(action.range or 5)))
    return { error = string.format("%s is out of reach: %d ft away, needs %d ft",
      target.name, away, need) }
  end

  local adv, notes = Resolve.situationalAdv(attacker, target, action)
  if opts.adv then adv = adv + opts.adv end
  if opts.setAdv then adv = opts.setAdv end
  local cover = 0
  if not opts.opportunity and not action.touch then
    cover = Resolve.coverBonus(attacker, target)
  end
  local ac = Combatant.ac(target, { cover = cover, melee = not action.range })
  local bonus = (action.toHit or 0) + (opts.bonus or 0)
  -- 5e: a melee attack on an unconscious / paralyzed / restrained creature is
  -- an automatic critical hit. That is how you finish a fight in one swing.
  local autoCrit = DND.config.autoCritOnDown and (not action.range) and (
       DND.hasCond(target, "unconscious") or DND.hasCond(target, "paralyzed")
    or DND.hasCond(target, "restrained") or DND.hasCond(target, "grappled")
    or DND.hasCond(target, "stunned")
  ) or false

  local roll = Dice.attackRoll(bonus, ac, { adv = adv,
    autoCrit = autoCrit or opts.autoCrit })
  hit = roll.hit
  local dmgResult = nil
  if roll.hit then
    dmgResult = Resolve.damageRoll(attacker, action, roll.crit and DND.config.crits)
  end
  local dmg = dmgResult and dmgResult.total or 0

  return {
    rawDamage = dmg,     -- pre-resistance, for the log and for tests
    dmgRoll = dmgResult,
    attacker = attacker, target = target, action = action, roll = roll,
    ac = ac, cover = cover, adv = adv, advNotes = notes, hit = hit,
    damage = dmg, type = action.dmgType, crit = roll.crit,
    reactionWindow = Resolve.reactionsAgainst(target),
    isOpportunity = opts.opportunity,
  }
end

--- Phase 2. Runs after any reactions have been resolved.
function Resolve.commit(pending, opts)
  opts = opts or {}
  local a, t = pending.attacker, pending.target
  local roll = pending.roll
  if not pending.cancelled then
    -- Borrow WC3's swing, refuse its arithmetic: the attack animation plays off
    -- the attacker's own model, while the number below comes from the d20. With
    -- ATTACKS_ENABLED off (set in Combatant.sync) this can never double up.
    w3.playAnim(a.unit, roll.crit and "attack" or "attack1")
    -- defender's reactions may have already changed the numbers
    if t.hp <= 0 then
      DND.logf("%s is already down — %s's %s goes wide.", t.name, a.name, pending.action.name)
      return pending
    end
    if roll.hit then
      local dealt = Resolve.applyDamage(t, pending.damage, {
        type = pending.type, crit = roll.crit, at0 = pending.action.at0 })
      pending.dealt = dealt
      DND.logf("|cff88ff88%s|r hits %s: d20 %s%s%s = %d vs AC %d  |cffcccccc(%s)|r  %d %s dmg%s",
        a.name, t.name, roll.natural, C.signed(roll.mod),
        (pending.adv == 1 and " adv") or (pending.adv == -1 and " dis") or "",
        roll.total, pending.ac,
        (pending.dmgRoll and pending.dmgRoll.label) or "", dealt, pending.type,
        roll.crit and " |cffffe066CRIT!|r" or "")
      DND.ui.showHit(a, t, roll, dealt, pending)
    else
      DND.logf("|cffff6666%s|r misses %s: d20 %s%s = %d vs AC %d%s",
        a.name, t.name, roll.natural, C.signed(roll.mod), roll.total, pending.ac,
        #pending.advNotes > 0 and (" (" .. table.concat(pending.advNotes, ", ") .. ")") or "")
      DND.ui.showMiss(a, t, roll, pending.ac)
    end
  else
    DND.logf("%s's %s is interrupted by %s.", a.name, pending.action.name,
      pending.cancelReason or "a reaction")
  end
  DND.emit("attackResolved", pending)
  return pending
end

---------------------------------------------------------------------- saves
function Resolve.save(target, ability, dc, opts)
  opts = opts or {}
  if type(target) ~= "table" or target.mods == nil then
    error("Resolve.save needs a combatant to roll against (got "
      .. type(target) .. " for a " .. C.saveLabel(ability) .. " save, DC "
      .. tostring(dc) .. ")", 2)
  end
  local adv = opts.adv or 0
  -- 5e: a paralyzed or unconscious creature auto-fails Strength and Dexterity
  -- saves. That is not a -5, it is an automatic zero, so it is handled here and
  -- never left to the arithmetic (a bug I would otherwise ship).
  local autoFail
  if (DND.hasCond(target, "paralyzed") or DND.hasCond(target, "stunned")
      or DND.hasCond(target, "petrified") or DND.hasCond(target, "unconscious"))
     and (ability == "str" or ability == "dex") then
    autoFail = { 1 }
  end
  local r = Dice.d20(Combatant.saveBonus(target, ability) + (opts.bonus or 0)
      + (condFail and condFail.check or 0), adv,
      { dc = dc, autoFail = autoFail })
  r.ability = ability
  r.dc = dc
  DND.logf("%s |cffcccccc%s save|r vs DC %d: d20 %s%s = %d → %s",
    target.name, C.saveLabel(ability), dc, r.natural,
    C.signed(Combatant.saveBonus(target, ability)), r.total,
    r.success and "|cff88ff88saved|r" or "|cffff6666failed|r")
  DND.ui.showSave(target, r)
  return r
end

---------------------------------------------------------------------- spells
--- A spell is one of three shapes: attack roll, saving throw, or "auto".
function Resolve.castSpell(caster, spell, target, opts)
  opts = opts or {}
  if spell.level > 0 then
    if (caster.slots[spell.level] or 0) <= 0 then
      return { error = "no " .. C.ordinal(spell.level) .. "-level slots left" }
    end
  end
  local upcast = opts.upcast or 0
  local out = { caster = caster, spell = spell, target = target, upcast = upcast }

  if spell.needTarget and not target then
    return { error = spell.name .. " needs a target" }
  end
  if spell.needTarget and target then
    local need = C.ft(spell.range or 120)
    if w3.dist(caster.unit, target.unit) > need + C.FIVE_FEET then
      return { error = "out of range" }
    end
  end

  if spell.level > 0 and upcast == 0 then
    caster.slots[spell.level] = caster.slots[spell.level] - 1
  elseif spell.level > 0 then
    caster.slots[spell.level] = caster.slots[spell.level] - 1
  end
  out.spentSlot = spell.level

  if spell.save and not target then
    -- A save needs somebody to fail it. Area spells are resolved per-creature
    -- by the caller (see spells with aoe=), never by aiming at nothing.
    return { error = spell.name .. " is an area effect: pick the square to centre it on" }
  end
  out.dc = spell.dc or Combatant.spellSaveDc(caster)
  -- Shape 1: an area. Saves are rolled per creature in applySpellEffect, NOT
  -- here, or every target eats the damage twice. Getting this wrong showed up
  -- as "half damage on a save" dealing full damage, which is a hard test fail.
  -- Shape 2: a single target with a save. Shape 3: an attack roll. Shape 4: auto.
  if spell.aoe then
    out.area = true
  elseif spell.save then
    local r = Resolve.save(target, spell.save, out.dc, { adv = spell.adv or 0 })
    out.save = r
    out.partial = r.success and (spell.halfOnSave ~= false)
    out.damage = Resolve.spellDamage(caster, spell, upcast, out.partial)
    out.failedConc = not r.success and spell.selfConc or nil
  elseif spell.attackRoll then
    local ac = Combatant.ac(target or caster)
    local r = Dice.attackRoll(Combatant.spellAttack(caster) + (spell.toHitBonus or 0), ac)
    out.roll = r
    out.damage = r.hit and Resolve.spellDamage(caster, spell, upcast, false) or 0
  else
    out.damage = Resolve.spellDamage(caster, spell, upcast, false)
    out.auto = true
  end

  DND.logf("|cffff99ff%s|r casts %s%s at %s", caster.name, spell.name,
    upcast > 0 and (" (upcast to " .. C.ordinal(spell.level + upcast) .. ")") or "",
    target and target.name or "the area")
  return out
end

function Resolve.spellDamage(caster, spell, upcast, half)
  if not spell.damage then return 0 end
  local expr = spell.damage
  if upcast > 0 and spell.upcast then
    -- spell.upcast is a dice string per slot level above the cast level,
    -- e.g. fireball { damage="8d6", upcast="2d6" } at +2 => 8d6 + 2*levels
    local per = C.parseDice(spell.upcast)
    if per and per.dice[1] then
      local sides = per.dice[1].d
      local diceCount = #per.dice * upcast
      expr = string.format("%dd%d", diceCount, sides)
      local base = C.parseDice(spell.damage)
      if base then
        local n = #base.dice + diceCount
        expr = string.format("%dd%d", n, base.dice[1].d)
      end
      if per.mod and per.mod ~= 0 then
        expr = expr .. C.signed(per.mod * upcast)
      end
    elseif type(spell.upcast) == "number" then
      expr = spell.damage .. C.signed(spell.upcast * upcast)
    end
  end
  local r = Dice.rollExpr(expr, { max = spell.maxOnCrit })
  local d = r.total
  if half then d = math.floor(d / 2) end
  return d
end

--- For aoe= spells, run the save + damage for every creature in the blast.
--- Doing this per creature is what makes fireball feel right: allies in the
--- cone save too, and each roll is logged separately.
function Resolve.areaTargets(caster, spell, centre)
  local radius = C.ft(spell.aoe or 15)
  local cx, cy = GetUnitX(centre and centre.unit or caster.unit),
                 GetUnitY(centre and centre.unit or caster.unit)
  local hit = {}
  for _, cbt in ipairs(Combatant.all()) do
    if cbt.hp > 0 and not cbt.removed then
      local friendly = cbt.side == caster.side
      if (not friendly) or spell.affectsAllies then
        local d = w3.distPts(cx, cy, GetUnitX(cbt.unit), GetUnitY(cbt.unit))
        if d <= radius + C.FIVE_FEET then hit[#hit + 1] = cbt end
      end
    end
  end
  return hit
end

function Resolve.applySpellEffect(res)
  local spell, caster, target = res.spell, res.caster, res.target
  if spell.aoe and not res.perCreature then
    res.perCreature = {}
    for _, victim in ipairs(Resolve.areaTargets(caster, spell, target or caster)) do
      local dmg = 0
      if spell.save then
        local r = Resolve.save(victim, spell.save, res.dc or Combatant.spellSaveDc(caster))
        dmg = Resolve.spellDamage(caster, spell, res.upcast or 0, r.success)
      elseif spell.needTarget == false then
        dmg = Resolve.spellDamage(caster, spell, res.upcast or 0, false)
      end
      res.perCreature[victim.cid] = dmg
      if dmg > 0 then
        Resolve.applyDamage(victim, dmg, { type = spell.dmgType or "force" })
      end
      if spell.onHit then spell.onHit(caster, victim, res) end
    end
    res.damage = 0
    res.aoeApplied = true
  end
  if not res.aoeApplied and (res.damage or 0) > 0 and target then
    Resolve.applyDamage(target, res.damage, {
      type = spell.dmgType or "force",
      crit = res.roll and res.roll.crit })
    DND.ui.showSpellHit(caster, target, spell, res.damage)
  end
  if spell.onHit and not res.partial then
    spell.onHit(caster, target, res)
  end
  if spell.selfEffect then spell.selfEffect(caster, res) end
  if spell.concentration and not res.failedConc then
    caster.concentration = { spell = spell.name, dc = spell.dc }
    DND.logf("%s concentrates on %s", caster.name, spell.name)
  end
  DND.emit("spell", caster, spell, target, res)
  return res
end

---------------------------------------------------------------------- death
--- At 0 hp a creature either starts making death saves or simply dies, and the
--- choice is a table-level rule, not a caller's memory: `DND.config.deathSaves`
--- off means mooks stay down for good, which is the DMG shortcut and keeps a
--- 4-vs-4 brawl from becoming a rescue simulation.
function Resolve.enterDowned(cbt, opts)
  if cbt.flags.instantDeath or not DND.config.deathSaves then
    if not cbt.class then                      -- player characters still get saves
      cbt.hp = 0
      cbt.incapacitated = true
      cbt.dead = true
      DND.logf("|cffff4444%s dies outright.|r (death saves are off for mooks)", cbt.name)
      DND.ui.showDied(cbt)
      DND.emit("died", cbt)
      Combatant.sync(cbt)
      return
    end
  end

  cbt.downed = true
  cbt.deathSaves = { success = 0, fail = 0 }
  cbt.hp = 0
  DND.logf("|cffff8866%s falls to 0 hit points!|r  (mooks with the optional rule "
    .. "off just die; %s)", cbt.name,
    cbt.class and "you are at 0, so death saves begin"
        or "the DM rolls death saves for it")
  DND.ui.showDowned(cbt)
  DND.emit("downed", cbt)
end

function Resolve.twoDeathSaves(cbt, why)
  cbt.deathSaves.fail = cbt.deathSaves.fail + 2
  DND.logf("%s takes %s while unconscious — two death-save failures.", cbt.name, why)
  Resolve.checkDeathSaves(cbt)
end

function Resolve.deathSave(cbt)
  if not cbt.downed then return nil end
  local r = Dice.d20(0, 0)
  if r.natural == 1 then r.total = r.total - 1 end
  if r.natural == 20 then
    cbt.downed = false
    cbt.hp = 1
    cbt.deathSaves = { success = 0, fail = 0 }
    DND.logf("|cff88ff88%s rolls a 20 on a death save and regains 1 hp!|r", cbt.name)
    DND.emit("revived", cbt)
    return r
  end
  if r.total >= 10 then
    cbt.deathSaves.success = cbt.deathSaves.success + 1
    DND.logf("%s death save: %s = %d → success (%d/%d)",
      cbt.name, r.natural, r.total, cbt.deathSaves.success, 3)
  else
    cbt.deathSaves.fail = cbt.deathSaves.fail + 1
    DND.logf("%s death save: %s = %d → fail (%d/3)",
      cbt.name, r.natural, r.total, cbt.deathSaves.fail)
  end
  Resolve.checkDeathSaves(cbt)
  return r
end

function Resolve.checkDeathSaves(cbt)
  if cbt.deathSaves.fail >= 3 then
    cbt.incapacitated = true
    cbt.dead = true
    DND.logf("|cffff4444%s is gone. Three failures.|r", cbt.name)
    DND.emit("died", cbt)
  elseif cbt.deathSaves.success >= 3 then
    cbt.stable = true
    cbt.downed = false
    DND.logf("|cff88ff88%s is stable.|r Three successes.", cbt.name)
    DND.emit("stable", cbt)
  end
end

--- Someone can spend an action to stabilize with a DC 10 Medicine check.
function Resolve.stabilize(healer, target)
  if target.hp > 0 then return { error = "not dying" } end
  local r = Dice.check((healer.mods.wis or 0) + (healer.tools and 2 or 0),
    { dc = 10, name = "Medicine" })
  if r.success then
    target.stable = true
    target.downed = false
    target.deathSaves = { success = 3, fail = target.deathSaves.fail }
    DND.logf("|cff88ff88%s stabilises %s|r (Medicine DC 10: %s)",
      healer.name, target.name, r.total)
    DND.emit("stable", target)
  else
    DND.logf("%s fails to stabilise %s (Medicine %s)", healer.name, target.name, r.total)
  end
  return r
end

---------------------------------------------------------------------- healing
--- Hit Dice: 1 per short rest, spent as 1d{die} + CON, heals the same amount.
function Resolve.spendHitDie(cbt)
  if cbt.hitDice <= 0 then return { error = "no Hit Dice left" } end
  local die = cbt.hpDice and cbt.hpDice.d or 8
  local r = Dice.rollExpr("1d" .. die)
  local heal = math.max(1, r.total + (cbt.mods.con or 0))
  cbt.hitDice = cbt.hitDice - 1
  return Resolve.heal(cbt, heal, "1d" .. die .. C.signed(cbt.mods.con or 0))
end

function Resolve.heal(cbt, amount, label)
  local before = cbt.hp
  cbt.hp = math.min(cbt.hpMax, cbt.hp + amount)
  local got = cbt.hp - before
  if cbt.hp > 0 then cbt.downed = false end
  Combatant.sync(cbt)
  DND.logf("|cff88ff88%s|r recovers %d hp%s", cbt.name, got,
    label and (" (" .. label .. ")") or "")
  DND.ui.showHeal(cbt, got)
  DND.emit("heal", cbt, got)
  return { healed = got }
end

---------------------------------------------------------------------- rests
function Resolve.shortRest(cbt)
  local n = math.max(1, math.floor(cbt.level / 2))
  local spend = 0
  for _ = 1, n do
    if cbt.hitDice > 0 then
      Resolve.spendHitDie(cbt)
      spend = spend + 1
    end
  end
  for lvl = 1, #cbt.slotMax do
    if cbt.slotMax[lvl] > 0 and lvl <= 2 then cbt.slots[lvl] = cbt.slotMax[lvl] end
  end
  DND.logf("%s takes a short rest: %d Hit Die spent, 1st/2nd-level slots back.",
    cbt.name, spend)
  DND.emit("shortRest", cbt)
  return spend
end

function Resolve.longRest(cbt)
  cbt.hp = cbt.hpMax
  cbt.hitDice = cbt.level
  cbt.downed, cbt.stable = false, false
  cbt.deathSaves = { success = 0, fail = 0 }
  for lvl = 1, #cbt.slotMax do cbt.slots[lvl] = cbt.slotMax[lvl] end
  -- keys first, then clear (same pairs()-mutation hazard as dnd_combat)
  local cleared = {}
  for k in pairs(cbt.statuses) do cleared[#cleared + 1] = k end
  for _, k in ipairs(cleared) do cbt.statuses[k] = nil end
  cbt.concentration = nil
  Combatant.sync(cbt)
  DND.logf("%s finishes a long rest.", cbt.name)
  DND.emit("longRest", cbt)
  return true
end

---------------------------------------------------------------------- reactions
--- Which reactions does this creature currently have armed and legal?
function Resolve.reactionsAgainst(target)
  local out = {}
  if target.reaction == "opportunity" then
    out[#out + 1] = { key = "attack", label = "Opportunity Attack",
                      desc = "free melee attack before the mover leaves your reach" }
  end
  if target.reaction == "shield" then
    out[#out + 1] = { key = "shield", label = "Shield (+5 AC)",
                      desc = "reaction; also deflects Magic Missile" }
  end
  if target.flags.readied then
    out[#out + 1] = { key = "ready", label = "Ready: " .. target.flags.readied.attack.name,
                      desc = "your readied attack" }
  end
  return out
end

function Resolve.takeReaction(cbt, which, pending)
  if cbt.reactionTaken then return { error = "reaction already used this round" } end
  if which == "attack" and pending then
    local atk = cbt.flags.pendingOpportunity and cbt.flags.pendingOpportunity.action
              or Combatant.primaryAttack(cbt)
    if not atk then return { error = "no melee attack" } end
    cbt.reactionTaken = true
    -- swing at whoever provoked (pending.reactionFor), falling back to the
    -- mover recorded by the caller. Never at pending.attacker: in the
    -- opportunity flow that is this very creature, which is how a guard ends up
    -- faithfully attacking itself.
    local victim = pending.reactionFor or pending.target or pending.attacker
    if victim == cbt then victim = pending.target end
    if victim == cbt then return { error = "no valid provoking creature" } end
    local p = Resolve.attack(cbt, victim, atk, { opportunity = true, force = true })
    if p.error then return p end
    Resolve.commit(p)
    return { ok = true, kind = "opportunity", pending = p }
  elseif which == "shield" then
    cbt.reactionTaken = true
    cbt.flags.shield = true
    if pending then
      pending.ac = pending.ac + 5
      pending.roll = Dice.attackRoll(pending.action.toHit or 0, pending.ac,
        { adv = pending.adv, autoCrit = pending.roll.critOnly })
      pending.hit = pending.roll.hit
      pending.damage = 0
      if pending.roll.hit then
        local r = Dice.rollExpr(pending.action.damage,
          { double = pending.roll.crit,
            bonus = pending.action.finesse and math.max(cbt.mods.str, cbt.mods.dex) or cbt.mods.str })
        pending.damage = r.total
        pending.roll.dmgLabel = r.label
      end
      DND.logf("|cff99ccff%s|r raises a shield — AC is now %d, the attack "
        .. "is rerolled against it.", cbt.name, pending.ac)
      if not pending.hit then pending.cancelled = false end
    end
    return { ok = true, kind = "shield" }
  end
  return { error = "no such reaction" }
end

--- Called by the move code: anyone whose reach you just left gets a shot.
--- Position-based (raw x/y, not a unit handle) so the AI can ask the same
--- question about a square it has not stepped into yet.
function Resolve.opportunitiesAt(mover, ox, oy, nx, ny, disengaged, allowShield)
  local out = {}
  if disengaged then return out end
  if mover.flags.invisible then return out end
  for _, foe in ipairs(Combatant.all()) do
    if foe ~= mover and foe.side ~= mover.side and foe.hp > 0 and not foe.removed
       and not foe.reactionTaken then
      local def = nil
      for name in pairs(foe.statuses) do def = C.CONDITIONS[name] or def end
      local incap = DND.hasCond(foe, "paralyzed") or DND.hasCond(foe, "stunned")
                 or DND.hasCond(foe, "unconscious") or DND.hasCond(foe, "petrified")
      local atk = Combatant.primaryAttack(foe)
      if atk and not incap then
        local reach = atk.reach or C.ft(5)
        local wasIn = w3.distPts(ox, oy, GetUnitX(foe.unit), GetUnitY(foe.unit)) <= reach + C.FIVE_FEET
        local nowOut = w3.distPts(nx, ny, GetUnitX(foe.unit), GetUnitY(foe.unit)) > reach + C.FIVE_FEET
        -- ranged attackers do not get a free swing for you walking away
        if wasIn and nowOut and not atk.range then
          out[#out + 1] = { foe = foe, atk = atk, allowShield = allowShield }
        end
      end
    end
  end
  return out
end

function Resolve.opportunitiesOnMove(mover, fromX, fromY, disengaged)
  local nx, ny = GetUnitX(mover.unit), GetUnitY(mover.unit)
  return Resolve.opportunitiesAt(mover, fromX, fromY, nx, ny, disengaged, true)
end

---------------------------------------------------------------------- stealth
function Resolve.stealth(cbt, dc)
  local r = Dice.check(cbt.mods.dex + (cbt.flags.expertiseStealth and cbt.prof or 0),
    { dc = dc or 999 })
  if r.total >= (dc or 999) or not dc then
    cbt.flags.hidden = true
    DND.logf("%s hides (Stealth %s). Attacks from hiding have advantage; "
      .. "the target loses its DEX-to-AC until revealed.", cbt.name, r.total)
  else
    DND.logf("%s fails to hide (Stealth %s vs DC %d).", cbt.name, r.total, dc or 0)
  end
  return r
end

function Resolve.perception(cbt, dc)
  return Dice.check((cbt.mods.wis or 0) + cbt.prof, { dc = dc })
end

return Resolve
