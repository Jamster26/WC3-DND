--[[ =========================================================================
  dnd_ai.lua — enemies that play by exactly the rules you do.

  There is no privileged AI damage path: the AI calls the same
  Combat.move / Combat.executeOn entry points your keypresses call. That is the
  only reason this stays maintainable — every rule is written once, and the AI
  cannot cheat in a way the player never can.

  Scoring is deliberately simple:
      can I kill it?  >  can I hit it?  >  can I reach it?  >  do I look smart?
========================================================================== ]]
DND = DND or {}
DND.ai = {}
local AI = DND.ai
local C = DND.CONST
local w3 = DND.w3
local Dice = DND.Dice
local Resolve = DND.Resolve
local Combatant = DND.Combatant

AI.thinkDelay = 0.45        -- a beat between decisions so turns read as turns
AI.maxActions = 24          -- hard stop: a bad eval can never hang the game
AI.samples = 16             -- rays per approach cone (see candidates)
local actionsTaken = 0

local function uiPulse(cbt)
  if DND.ui and DND.ui.pulse then DND.ui.pulse(cbt) end
end

---------------------------------------------------------------------- maths
--- P(roll + bonus >= ac), with the advantage/disadvantage adjustment. Kept as
--- closed form because the AI evaluates hundreds of these per turn.
local function hitChance(bonus, ac, adv)
  local need = ac - bonus
  local faces = 21 - C.clamp(need, 2, 21)     -- natural 1 always misses
  if need <= 2 then faces = 19 end            -- everything but a 1 hits
  local p = faces / 20
  if adv >= 1 then p = 1 - (1 - p) * (1 - p) end
  if adv <= -1 then p = p * p end
  return C.clamp(p, 0.05, 0.95)
end

local function avgDamage(cbt, action, crit)
  local t = C.parseDice(action.damage)
  if not t then return 0 end
  local dmod = action.dmod
  if dmod == nil then
    dmod = action.ability and cbt.mods[action.ability] or cbt.mods.str
    if action.finesse then dmod = math.max(cbt.mods.str, cbt.mods.dex) end
  end
  local avg = dmod or 0                        -- 5e doubles the DICE, never the mod
  for _, d in ipairs(t.dice) do
    avg = avg + (crit and d.d or (d.d + 1) / 2)
  end
  for _, ex in ipairs(action.extraDice or {}) do
    local et = C.parseDice(ex.expr)
    if et then
      for _, d in ipairs(et.dice) do
        avg = avg + (crit and d.d or (d.d + 1) / 2)
      end
    end
  end
  return math.max(1, avg)
end

--- What standing in the open at (x, y) will cost us in free swings.
local function threatCost(cbt, x, y)
  local cost = 0
  for _, other in ipairs(DND.Combat.enemiesOf(cbt)) do
    local oa = Combatant.primaryAttack(other)
    if oa and not oa.range then
      local d = w3.distPts(x, y, GetUnitX(other.unit), GetUnitY(other.unit))
      if d <= (oa.reach or C.ft(5)) + C.FIVE_FEET then
        cost = cost + avgDamage(other, oa, false)
             * hitChance(oa.toHit or 0, Combatant.ac(cbt), 0) * 0.5
      end
    end
  end
  return cost
end

local function canSee(cbt, foe)
  if foe.flags.hidden and w3.dist(cbt.unit, foe.unit) > C.ft(10) then return false end
  return true
end

local function index(cbt, action)
  for i, a in ipairs(cbt.actions) do
    if a == action then return i end
  end
  return 1
end

---------------------------------------------------------------------- eval
--- How much is this swing worth? Expected damage, with a huge bonus for kills.
function AI.scoreAttack(cbt, foe, action)
  if not canSee(cbt, foe) then return -100 end
  if action.recharge and not action.ready then return -1 end
  local cover = Resolve.coverBonus(cbt, foe)
  local ac = Combatant.ac(foe, { cover = cover, melee = not action.range })
  local adv = Resolve.situationalAdv(cbt, foe, action)
  local chance = hitChance(action.toHit or (Combatant.spellAttack(cbt)), ac, adv)
  local avg = avgDamage(cbt, action, false)
  if action.save then avg = avg * (1 - hitChance(0, action.dc or 13, adv) * 0.5) end
  -- One Attack action may be several swings (Extra Attack).  Expected damage is the
  -- sum, and the finisher test uses the sum too, because two half-kills are a kill.
  local swings = Combatant.extraAttacks(cbt)
  local s = chance * avg * 1.6 * swings
  if avg * swings >= foe.hp then s = s + 400 end
  if foe.hp <= foe.hpMax * 0.3 and chance > 0.4 then s = s + 90 end
  if action.aoe then s = s + 25 end
  if not action.range and w3.dist(cbt.unit, foe.unit) > (action.reach or C.ft(5)) then
    s = s - threatCost(cbt, GetUnitX(cbt.unit), GetUnitY(cbt.unit))
  end
  return s
end

--- Candidate standing spots. WC3 exposes no pathfinder query, so we fan out
--- from the creature toward the target and, once adjacent, around the target's
--- reach ring. Sampled on the 5 ft grid so it lands where the player can see.
function AI.candidates(cbt, foe, reach, budget)
  local out = {}
  local ux, uy = GetUnitX(cbt.unit), GetUnitY(cbt.unit)
  local tx, ty = GetUnitX(foe.unit), GetUnitY(foe.unit)
  local d = w3.distPts(ux, uy, tx, ty)
  -- 1) approach: walk toward the target along a fan of rays, stopping at the
  --    budget AND at the target's reach. Forgetting either cap is how the AI
  --    ends up scoring "stand still" as its best option in an empty field.
  local step = C.ft(5)
  local n = C.clamp(math.floor(budget / step), 1, 12)
  local reach = C.clamp(reach, C.ft(5), C.ft(30))
  local base = math.atan2(ty - uy, tx - ux)
  local rays = AI.samples
  for i = 0, rays - 1 do
    local a = base + (i / (rays - 1) - 0.5) * math.pi * 0.85
    for k = 1, n do
      local x, y = ux + math.cos(a) * step * k, uy + math.sin(a) * step * k
      local stop = w3.distPts(x, y, tx, ty)
      local walked = w3.distPts(ux, uy, x, y)
      if walked > budget + C.FIVE_FEET then break end  -- out of movement, stop this ray
      if stop < reach - C.ft(2.5) then break end       -- already inside reach
      out[#out + 1] = { x = x, y = y, bias = -k, closesIn = stop < d,
                        walked = walked,
                        adjacent = stop <= reach + C.FIVE_FEET }
    end
  end
  -- 2) the reach ring, for encircling / flanking once you are close enough
  for i = 0, 7 do
    local a = i * math.pi / 4
    for _, pad in ipairs({ -C.FIVE_FEET, 0, C.FIVE_FEET * 2 }) do
      local r = reach - C.ft(5) + pad
      if r < C.ft(5) then r = C.ft(5) end
      local x, y = tx + math.cos(a) * r, ty + math.sin(a) * r
      if w3.distPts(ux, uy, x, y) <= budget + C.FIVE_FEET then
        out[#out + 1] = { x = x, y = y, bias = 6, ring = true }
      end
    end
  end
  -- 3) hold position (attack without moving / stay at range / keep cover)
  out[#out + 1] = { x = ux, y = uy, bias = 1 }
  return out
end

--- Best spot to stand for the primary attack, scored by reach minus exposure.
function AI.bestStep(cbt, foe)
  local a = Combatant.primaryAttack(cbt)
  local reach = a and (a.reach or C.ft(5)) or C.ft(5)
  local budget = cbt.movementLeft or (cbt.speed * C.UNITS_PER_FOOT)
  if cbt.flags.wantDash then budget = budget + cbt.speed * C.UNITS_PER_FOOT end
  local best
  for _, pos in ipairs(AI.candidates(cbt, foe, reach, budget)) do
    if pos.x and pos.y then
      local s = pos.bias or 0
      local d = w3.distPts(pos.x, pos.y, GetUnitX(foe.unit), GetUnitY(foe.unit))
      if d <= reach + C.FIVE_FEET then s = s + 30 end
      if pos.adjacent then s = s + 14 end
      if not cbt.flags.disengaged then
        s = s - threatCost(cbt, pos.x, pos.y)
      end
      -- never pay to shuffle sideways
      s = s - (pos.walked or 0) * 0.004
      if pos.ring then s = s + 4 end
      if not best or s > best.score then
        best = { score = s, x = pos.x, y = pos.y, foe = foe, action = a }
      end
    end
  end
  return best
end

---------------------------------------------------------------------- turn
function AI.takeTurn(cbt, done)
  actionsTaken = 0
  local guard = 0
  while actionsTaken < AI.maxActions do
    guard = guard + 1
    if guard > AI.maxActions + 4 then break end
    if not AI.step(cbt) then break end
  end
  -- breath weapons: "Recharge 5-6"
  for _, a in ipairs(cbt.actions) do
    if a.recharge and not a.ready then
      if Dice.roll(1, 6) >= 5 then
        a.ready = true
        DND.logf("%s's %s recharges.", cbt.name, a.name)
      end
    end
  end
  if DND.config.deathSaves and cbt.downed then Resolve.deathSave(cbt) end
  -- The caller usually wants the turn closed when we finish. A test (or a DM
  -- reviewing what the AI did) needs it held open, so that is opt-out rather
  -- than something the caller has to work around.
  if done and DND.config.aiAutoEnd ~= false then done() end
end

--- One decision. Returns true when something was spent, false to end the turn.
function AI.step(cbt)
  if actionsTaken >= AI.maxActions then return false end
  if cbt.hp <= 0 or cbt.removed then return false end
  actionsTaken = actionsTaken + 1

  local foes = DND.Combat.enemiesOf(cbt)
  if #foes == 0 then return false end

  -- 1) swing at anything already in reach
  if not cbt.actionUsed then
    local best
    for _, foe in ipairs(foes) do
      for _, a in ipairs(cbt.actions) do
        local need = a.reach or (a.range and C.ft(a.range)) or C.ft(5)
        if w3.dist(cbt.unit, foe.unit) <= need + C.FIVE_FEET then
          local s = AI.scoreAttack(cbt, foe, a)
          if not best or s > best.score then best = { score = s, foe = foe, action = a } end
        elseif not best then
          -- Out of reach: keep it as a fallback so the creature at least SWINGS
          -- and the rules refuse it. Skipping silently is how a fight stalls
          -- into a 400-round stalemate with nobody doing anything.
          best = { score = -60, foe = foe, action = a, desperate = true }
        end
      end
      -- spells are just attacks with different maths
      for i, sp in ipairs(cbt.spells or {}) do
        local wantsFoe = sp.needTarget or sp.attackRoll or sp.save
        local lvl = sp.level or 0
        -- Cantrips have no slot to spend, so they need to be considered on the
        -- same footing as slotted spells; a wizard who never throws a firebolt
        -- is a wizard who stalemates the fight.
        if lvl == 0 or (lvl > 0 and (cbt.slots[lvl] or 0) > 0 and not sp.bonus) then
          local s = AI.scoreAttack(cbt, foe, {
            toHit = sp.attackRoll and Combatant.spellAttack(cbt) or nil,
            damage = sp.damage, save = sp.save,
            reach = C.ft(sp.range or 60), range = sp.range, aoe = sp.aoe })
          local wantsFoe = sp.needTarget or sp.attackRoll
          local inRange = w3.dist(cbt.unit, foe.unit) <= C.ft(sp.range or 5) + C.FIVE_FEET
          local usable = (sp.level or 0) == 0 or (cbt.slots[sp.level] or 0) > 0
          if usable and (not wantsFoe or (inRange and not sp.needTarget))
             and (not wantsFoe or sp.needTarget) and inRange
             and s > 8 and (not best or s > best.score) then
            best = { score = s, foe = wantsFoe and foe or nil, spell = sp, index = i }
          end
        end
      end
    end
    if best and best.score > -50 then
      if best.spell then
        local arm = DND.Combat.armAction("spell", best.index)
        if arm and not arm.error then
          local r = DND.Combat.executeOn(best.foe)
          if r and not r.error then return true end
          if r and r.error then DND.logf("AI: %s could not cast (%s)", cbt.name, r.error) end
          DND.Combat.cancelAction()
        elseif arm and arm.error then
          DND.logf("AI: %s could not arm spell (%s)", cbt.name, arm.error)
        end
      else
        local arm = DND.Combat.armAction("attack", index(cbt, best.action),
          best.desperate and { force = true } or nil)
        if arm and not arm.error then
          local r = DND.Combat.executeOn(best.foe)
          if r and not r.error then
            if best.action.recharge then best.action.ready = false end
            return true
          end
          if r and r.error then DND.logf("AI: %s could not attack (%s)", cbt.name, r.error) end
          DND.Combat.cancelAction()
        elseif arm and arm.error then
          DND.logf("AI: %s could not arm attack (%s)", cbt.name, arm.error)
        end
      end
    end
  end

  -- 3b) still nothing? swing anyway. The rules will refuse it if the target is
  -- out of reach, and that refusal is far better than a silent stalemate.
  if not cbt.actionUsed then
    local foe = foes[1]
    local idx = index(cbt, Combatant.primaryAttack(cbt))
    local arm = DND.Combat.armAction("attack", idx, { force = true })
    if arm and not arm.error then
      local r = DND.Combat.executeOn(foe)
      if r and not r.error then return true end
      DND.Combat.cancelAction()
    end
  end

  -- 4) bonus actions: Nimble Escape, Aggressive, Martial Advantage, off-hand
  if not cbt.bonusUsed then
    for _, t in ipairs(cbt.traits or {}) do
      if t.bonus and t.onUse then
        t.onUse(cbt)
        cbt.bonusUsed = true
        return true
      end
    end
    if cbt.bonusAttack and not cbt.flags.bonusAttackUsed then
      local foe = foes[1]
      cbt.flags.bonusAttackUsed = true
      cbt.bonusUsed = true
      local p = Resolve.attack(cbt, foe, cbt.bonusAttack, { force = true })
      if p and not p.error then
        p.reactionWindow = nil
        Resolve.commit(p)
        return true
      end
    end
  end

  -- 2) nothing in reach: spend the move getting into it
  if cbt.movementLeft and cbt.movementLeft > C.FIVE_FEET then
    local plan
    for _, foe in ipairs(foes) do
      local p = AI.bestStep(cbt, foe)
      if p and (not plan or p.score > plan.score) then plan = p end
    end
    if (not plan or plan.score <= 1) and cbt.actionUsed == false then
      -- nothing in reach and no good square: straight-line approach. 5e calls
      -- this "move toward your objective"; WC3's pathing handles the terrain.
      local pf = foes[1]
      local ux, uy = GetUnitX(cbt.unit), GetUnitY(cbt.unit)
      local tx, ty = GetUnitX(pf.unit), GetUnitY(pf.unit)
      local dd = w3.distPts(ux, uy, tx, ty)
      if dd > C.FIVE_FEET then
        -- walk until either the budget runs out or we are 5 ft from the target
        local step = math.min(cbt.movementLeft, math.max(0, dd - C.FIVE_FEET))
        if step > C.FIVE_FEET then
          local t = step / dd
          plan = { score = 20, x = ux + (tx - ux) * t, y = uy + (ty - uy) * t, foe = pf }
          cbt.flags.closing = true
        end
      end
    end
    if plan and plan.x then
      local mv = DND.Combat.move({ x = plan.x, y = plan.y },
        plan.score < 20 and { dash = cbt.flags.wantDash } or nil)
      cbt.flags.wantDash = nil
      if mv and not mv.error then
        uiPulse(cbt)
        if cbt.flags.closing then
          cbt.flags.closing = nil
          cbt.actionUsed = true     -- walking the whole field is the turn's work
        end
        return true
      end
      if mv and mv.error then
        DND.logf("AI: %s is stuck (%s)", cbt.name, mv.error)
      end
    end
  end

  -- 3) support magic: heal or buff the friend who needs it most
  if not cbt.actionUsed then
    for _, ally in ipairs(Combatant.living(cbt.side)) do
      if ally ~= cbt and ally.hp < ally.hpMax * 0.45 then
        for i, sp in ipairs(cbt.spells or {}) do
        local wantsFoe = sp.needTarget or sp.attackRoll or sp.save
          if (sp.heal or (sp.selfEffect and ally ~= cbt)) and not sp.attackRoll
             and (sp.level or 0) > 0 and (cbt.slots[sp.level] or 0) > 0 then
            local need = C.ft(sp.range or 5)
            if w3.dist(cbt.unit, ally.unit) <= need + C.FIVE_FEET then
              local arm = DND.Combat.armAction("spell", i)
              if arm and not arm.error then
                local r = DND.Combat.executeOn(ally)
                if r and not r.error then return true end
                DND.Combat.cancelAction()
              end
            end
          end
        end
      end
    end
  end

  return false
end

--- Called from Combat.beginTurn for the AI side.
return AI
