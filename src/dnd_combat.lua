--[[ =========================================================================
  dnd_combat.lua — the turn state machine.

  WC3 has no "end my turn" and no pause-all-units, so this file manufactures
  both. The whole design rests on three moves:

    1. Every combatant is frozen (PauseUnit + pathing off + attacks disabled)
       at all times. Real time therefore cannot hurt anybody.
    2. Only the creature whose initiative it is gets unfrozen, and only for
       exactly as long as its action economy allows.
    3. Damage never comes from WC3's attack engine — the swing animation is
       borrowed, the numbers come from dnd_resolve.lua.

  The machine is event-driven, not timer-driven: a "tick" happens when a
  player presses something, and on AI turns when the AI callback returns.
  That means no polling, no race conditions, and no desync surface at all.
========================================================================== ]]
DND = DND or {}
DND.Combat = {}
local Combat = DND.Combat
local C = DND.CONST
local w3 = DND.w3
local Dice = DND.Dice
local Resolve = DND.Resolve
local Combatant = DND.Combatant
local Turns = DND.Turns

Combat.state = {
  running = false,
  phase = C.PHASE.IDLE,
  turn = nil,             -- { cbt, score }
  pending = nil,          -- attack awaiting a reaction / commit
  armed = nil,            -- { action=, kind= } the selected action
  moves = {},             -- undo stack for this turn
  encounter = nil,
  debug = false,
}
local S = Combat.state
Combat.turns = Turns.new()
local turns = Combat.turns

---------------------------------------------------------------------- logging
DND.logLines = DND.logLines or {}
function DND.logf(fmt, ...)
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then msg = tostring(fmt) end
  -- strip WC3 colour codes for the plain-text log. The pattern has to be
  -- |c + 8 hex digits, exactly; a sloppy version here ate a visible character.
  msg = (msg:gsub("|c%x%x%x%x%x%x%x%x", "")):gsub("|r", "")
  local n = #DND.logLines + 1
  DND.logLines[n] = msg
  if n > 400 then table.remove(DND.logLines, 1) end
  if DND.ui and DND.ui.pushLog then DND.ui.pushLog(msg) end
  if DND.testVerbose then print("[log] " .. msg) end
end
function DND.logError(msg)
  DND.logf("|cffff5555ERROR:|r " .. tostring(msg))
  if not DND.testMode then w3.log("ERROR: " .. tostring(msg)) end
end

---------------------------------------------------------------------- helpers
local function livingOn(side) return Combatant.living(side) end

function Combat.enemiesOf(cbt)
  local out = {}
  for _, other in ipairs(Combatant.all()) do
    if other ~= cbt and other.side ~= cbt.side and other.hp > 0 and not other.removed then
      out[#out + 1] = other
    end
  end
  table.sort(out, function(a, b) return a.hp < b.hp end)
  return out
end

--- Living creatures on the given side (a `side` is required, unlike
--- Combatant.living's "everybody" default). Exposed here because the rules layer
--- reaches for threat lists through DND.Combat.
function Combat.livingOf(side)
  return Combatant.livingOf(side)
end

--- Threatened = an armed foe is inside someone's reach.
function Combat.threatenedBy(cbt)
  local out = {}
  for _, foe in ipairs(Combat.enemiesOf(cbt)) do
    local atk = Combatant.primaryAttack(foe)
    if atk and w3.dist(foe.unit, cbt.unit) <= (atk.reach or C.ft(5)) + C.FIVE_FEET then
      out[#out + 1] = foe
    end
  end
  return out
end

---------------------------------------------------------------------- lifecycle
function Combat.startEncounter(name, combatants, opts)
  opts = opts or {}
  if S.running then Combat.abort("restart") end
  if #combatants < 2 then DND.logError("encounter needs at least two combatants") return end
  S.running = true
  -- Whatever the caller adds to this record (delve room, XP, carry-on) rides
  -- along to the end of the fight, where Data.afterVictory reads it back.
  S.encounter = { name = name or "Skirmish", round = 0, startedAt = 0,
                  rounds = 0, surprise = opts.surprise,
                  carryOn = opts.carryOn, rest = opts.rest,
                  encounterKey = opts.encounterKey, index = opts.encounterIndex,
                  bounds = opts.bounds }
  for _, cbt in ipairs(combatants) do
    cbt.reaction = "none"
    cbt.reactionTaken = false
    cbt.flags = cbt.flags or {}
    Combatant.sync(cbt)
    if opts.rest ~= false then
      cbt.hitDice = cbt.hitDice > 0 and cbt.hitDice or cbt.level
      for lvl = 1, #cbt.slotMax do cbt.slots[lvl] = cbt.slotMax[lvl] end
    end
  end
  turns = Turns.new(); Combat.turns = turns
  DND.logf("|cffffe066== %s ==|r  Roll for initiative!", name or "Encounter")
  local order = Turns.rollOrder(turns, combatants)
  for _, e in ipairs(order) do
    DND.logf("  %-18s %s%s  init %d", e.cbt.name,
      e.cbt.side == C.SIDE.PARTY and "(party)" or "(foes)",
      (""):rep(0), e.score)
  end
  DND.ui.buildTracker()
  if opts.surprise then Turns.surprise(turns, opts.surprise, {}) end
  Combat.nextTurn()
  return true
end

function Combat.abort(reason)
  S.running = false
  S.phase = C.PHASE.IDLE
  S.turn = nil
  S.pending = nil
  S.armed = nil
  for _, cbt in ipairs(Combatant.all()) do
    w3.unfreeze(cbt.unit, false)
    cbt.flags = {}
    cbt.concentration = nil
  end
  DND.ui.clear()
  DND.logf("Combat ended (%s).", reason)
end

--- Victory/defeat screen hook; the real map overrides it.
function Combat.checkEnd()
  local party, foes = #livingOn(C.SIDE.PARTY), #livingOn(C.SIDE.FOES)
  if party == 0 then
    DND.logf("|cffff4444The party is broken. Defeat.|r")
    local rec = S.encounter
    Combat.abort("wipe")
    -- Same hook as a victory, with 0 XP and a result string: a delve has to be
    -- able to charge you for losing, and this file should not know what losing
    -- costs. See Data.afterVictory.
    if DND.afterCombatHook then DND.afterCombatHook(0, rec, "defeat") end
    if DND.onDefeat then DND.onDefeat() end
    return true
  end
  if foes == 0 then
    DND.logf("|cff88ff88The field is yours. Victory.|r")
    local xp = 0
    for _, cbt in ipairs(Combatant.all()) do
      if cbt.side == C.SIDE.FOES then xp = xp + (cbt.xp or (cbt.level * 50)) end
    end
    -- "each" is per head of the party as it STARTED, not per survivor: the
    -- difference matters in a delve, where the roster shrinks mid-run. The
    -- encounter record knows how many walked in; `party` is how many are left.
    if xp > 0 and DND.config.xpTrack ~= false then
      local heads = (S.encounter and S.encounter.partyCount) or party
      if heads < 1 then heads = 1 end
      DND.logf("Award %d XP (%d each).", xp, math.ceil(xp / heads))
    end
    -- What the award MEANS (levels, hit points carried into the next room, the
    -- toll of a wipe) is the adventure layer's business, so it is a hook this
    -- file only offers. dnd_data.lua installs it; a real map can replace it.
    local rec = S.encounter
    Combat.abort("victory")
    if DND.afterCombatHook then DND.afterCombatHook(xp, rec) end
    if DND.onVictory then DND.onVictory(xp) end
    return true
  end
  return false
end

---------------------------------------------------------------------- turn flow
function Combat.nextTurn()
  if not S.running then return end
  if Combat.checkEnd() then return end
  local entry = Turns.next(turns)
  if not entry then Combat.abort("no valid turns") return end
  S.turn = entry
  S.moves = {}
  S.armed = nil
  S.pending = nil
  local cbt = entry.cbt
  DND.logf("|cffffcc00Round %d|r — %s's turn%s", turns.round, cbt.name,
    cbt.side == C.SIDE.PARTY and "" or " (invaders)")
  Combat.beginTurn(cbt)
end

function Combat.beginTurn(cbt)
  S.phase = C.PHASE.BEGIN
  -- A reaction refreshes at the START OF YOUR OWN ROUND, not at the start of
  -- each creature's turn. Clearing it here would hand every defender a fresh
  -- opportunity attack on every single move anywhere on the board.
  if turns.index <= 1 and turns.round > 0 then
    for _, other in ipairs(Combatant.all()) do other.reactionTaken = false end
  end
  cbt.flags.disengaged = nil
  cbt.flags.movedThisTurn = nil
  cbt.movementLeft = Combatant.speedUnits(cbt)
  cbt.movementTotal = cbt.movementLeft
  cbt.actionUsed = false
  cbt.bonusUsed = false
  local stale = {}
  for k in pairs(cbt.flags) do
    if k == "dodge" or k == "shield" or k == "readied" then stale[#stale+1] = k end
  end
  for _, k in ipairs(stale) do cbt.flags[k] = nil end
  Combat.freeActions(cbt)

  -- prone costs half your movement to rise (5e: standing uses 1/2 your speed)
  if DND.hasCond(cbt, "prone") then
    cbt.movementLeft = math.floor(cbt.movementLeft / 2)
    DND.removeCond(cbt, "prone")
    DND.logf("%s stands, spending half its movement.", cbt.name)
  end

  -- incapacitated conditions burn the turn but still let a save happen
  local skip = false
  for name in pairs(cbt.statuses) do
    local def = C.CONDITIONS[name]
    if def and def.skipTurn then skip = true end
  end
  if cbt.downed then skip = true end

  w3.lookAt(cbt.unit)
  DND.ui.setActive(cbt)

  if skip then
    S.phase = C.PHASE.END
    local why = cbt.downed and "unconscious" or "incapacitated"
    DND.logf("%s cannot act (%s).", cbt.name, why)
    if cbt.downed then Resolve.deathSave(cbt) end
    -- Snapshot the KEYS only, then mutate after the walk. removeCond touches
    -- cbt.statuses, and deleting a key while pairs() is mid-traversal is
    -- undefined in Lua 5.1: the loop can hand you a nil value, and the crash
    -- surfaces as "attempt to index a nil value" several frames away from the
    -- line that actually caused it.
    local due = {}
    for name in pairs(cbt.statuses) do due[#due + 1] = name end
    for _, name in ipairs(due) do
      local st = cbt.statuses[name]
      if st and st.duration then
        st.duration = st.duration - 1
        if st.duration <= 0 then DND.removeCond(cbt, name) end
      end
    end
    w3.after(DND.testMode and 0 or 0.6, function() Combat.endTurn(cbt) end)
    return
  end

  -- now they can actually act
  w3.unfreeze(cbt.unit, false)          -- attacks stay disabled: Lua deals damage
  DND.ui.showActions(cbt)
  if cbt.side == C.SIDE.PARTY then
    S.phase = C.PHASE.ACTION
    DND.ui.promptPlayer(cbt)
  else
    S.phase = C.PHASE.ENEMY
    if DND.config.aiEnabled ~= false and DND.ai and DND.ai.takeTurn then
      DND.ai.takeTurn(cbt, function() Combat.endTurn(cbt) end)
    else
      -- With the AI off the turn simply waits. Ending it here (the obvious
      -- fallback) silently skips every invader and makes "aiEnabled = false"
      -- look broken instead of useful: it is how you run a hot-seat session, a
      -- scripted scene, or a test that inspects a turn mid-flight.
      DND.ui.setHint(cbt.name .. "'s turn is on hold (AI disabled).")
    end
  end
end

--- Free things that cost nothing, recomputed each turn.
function Combat.freeActions(cbt)
  cbt.canStep = true
  cbt.interactionsLeft = 1
end

function Combat.endTurn(cbt)
  cbt = cbt or (S.turn and S.turn.cbt)
  if not cbt then
    -- Called with no argument after the order moved on: end whoever currently
    -- holds the turn rather than silently doing nothing. A no-op here leaves
    -- the game frozen mid-turn, which is the worst possible failure to debug.
    local e = S.turn or DND.Combat.turns.order[DND.Combat.turns.index]
    cbt = e and e.cbt
  end
  if not cbt then
    DND.logf("endTurn: no active creature, ignoring")
    return
  end
  S.phase = C.PHASE.END
  -- concentration persists; conditions tick at the end of the sufferer's turn
  Combatant.conditionSaves(cbt)
  w3.freeze(cbt.unit)
  cbt.movementLeft = 0
  DND.ui.hideActions(cbt)
  DND.ui.clearActive()
  Combat.revokeTargetingAbility(cbt)
  S.armed, S.pending, S.reactionPrompt = nil, nil, nil
  w3.after(DND.testMode and 0 or 0.12, function() Combat.nextTurn() end)
end

---------------------------------------------------------------------- movement
--- A single "step": a move order for up to `ft` feet. Validated before it is
--- issued, so WC3 can never cheat the budget by pathing somewhere illegal.
function Combat.move(f, opts)
  opts = opts or {}
  local cbt = S.turn and S.turn.cbt
  if not cbt then return { error = "not your turn" } end
  -- Explicit actor: silently moving whoever happens to hold the turn is the
  -- kind of bug that hides in an AI refactor, so we refuse it out loud.
  if opts.who and opts.who ~= cbt then
    return { error = "not " .. opts.who.name .. "'s turn" }
  end
  if S.phase == C.PHASE.REACTION then return { error = "resolve the reaction first" } end
  if cbt.side == C.SIDE.PARTY and S.phase == C.PHASE.ENEMY then
    return { error = "wait for your turn" }
  end
  local u = cbt.unit
  local x1, y1 = GetUnitX(u), GetUnitY(u)
  -- `0/0` in a trait's maths, or a position read off a unit that is already gone,
  -- lands here as nan.  Guard it at the one place every move goes through: in the
  -- real game SetUnitX(nan) gives you a creature that can never be moved, targeted
  -- or looked at again, and `nan <= 0.01` is false, so the distance check below
  -- would not have caught it.
  if not (f.x == f.x and f.y == f.y) then return { error = "nowhere to go" } end
  local d = w3.distPts(x1, y1, f.x, f.y)
  if not (d > 0.01) then return { error = "already there" } end
  -- The remaining budget is the only hard limit; a destination farther than one
  -- turn of movement is not an error, you just spend it all walking that way.
  -- There is deliberately no extra per-order clamp, because the AI depends on
  -- being able to approach across a big battlefield one move at a time.
  cbt.movementLeft = cbt.movementLeft or 0
  if opts.dash and not cbt.flags.dashCredited then
    cbt.movementLeft = cbt.movementLeft + cbt.speed * C.UNITS_PER_FOOT
    cbt.flags.dashCredited = true
  end
  if d > cbt.movementLeft + C.FIVE_FEET * 0.5 then
    -- clamp to the budget instead of refusing: keeps 6 seconds of movement
    local t = cbt.movementLeft / d
    f = { x = x1 + (f.x - x1) * t, y = y1 + (f.y - y1) * t }
    d = cbt.movementLeft
  end

  -- a frightened creature may not end a move nearer the source of its fear
  local fear = cbt.statuses.frightened
  if fear and fear.source then
    local src = Combatant.byId(fear.source)
    if src and w3.distPts(f.x, f.y, GetUnitX(src.unit), GetUnitY(src.unit))
              < w3.dist(u, src.unit) - C.FIVE_FEET then
      return { error = "frightened: cannot move closer to " .. src.name }
    end
  end

  local before = { x = x1, y = y1, left = cbt.movementLeft }
  w3.moveTo(u, f.x, f.y)
  cbt.movementLeft = math.max(0, cbt.movementLeft - d)
  cbt.flags.movedThisTurn = true
  S.moves[#S.moves + 1] = before
  DND.ui.updateMovement(cbt)
  DND.logf("%s moves %.0f ft (%.0f ft left).", cbt.name,
    C.round(C.unitsToFeet(d)), C.round(C.unitsToFeet(cbt.movementLeft)))

  -- leaving reach?  Opportunity attacks happen here, mid-move, exactly as 5e wants
  local react = Resolve.opportunitiesOnMove(cbt, before.x, before.y,
    cbt.flags.disengaged)
  if #react > 0 then
    Combat.offerOpportunities(cbt, react)
  end
  return { ok = true, distance = d }
end

function Combat.undoMove()
  local cbt = S.turn and S.turn.cbt
  if not cbt or #S.moves == 0 then return { error = "nothing to undo" } end
  local prev = table.remove(S.moves)
  w3.moveTo(cbt.unit, prev.x, prev.y)
  cbt.movementLeft = prev.left
  DND.ui.updateMovement(cbt)
  -- note: opportunity attacks already resolved cannot be un-triggered; the
  -- undo is a courtesy, the DM console says so in the log.
  DND.logf("%s steps back. (Opportunity attacks already taken stay taken.)", cbt.name)
  return { ok = true }
end

---------------------------------------------------------------------- attacking
---------------------------------------------------------------------- targeting
--- Optional sugar: while an action is armed, grant the creature a real WC3
--- ability (AATK / AMOV from dnd_data.js) so the native targeting cursor and
--- its range ring do the pointing for us. This is cosmetic wiring over the same
--- rules path: the ability's own damage is 1d0+0 and the cast still funnels
--- through executeOn, so nothing can bypass the d20. If the object data is not
--- compiled into the map, UnitAddAbility fails and we quietly stay on the key
--- path — which is why the flag defaults off rather than being required.
function Combat.grantTargetingAbility(cbt, code)
  if not DND.config.nativeTargeting or not cbt or not cbt.unit then return false end
  if not code then return false end
  if not UnitAddAbility(cbt.unit, code) then
    DND.logf("nativeTargeting needs dnd_data.js compiled (missing ability %s)",
      string.format("%08X", code))
    return false
  end
  SetUnitAbilityLevel(cbt.unit, code, 1)
  BlzSetUnitAbilityCooldown(cbt.unit, code, 1, 0)
  cbt.flags.grantedTargeting = code
  DND.ui.setHint(DND.ui.state.hint .. "  (right-click to aim)")
  return true
end

function Combat.revokeTargetingAbility(cbt)
  local code = cbt and cbt.flags and cbt.flags.grantedTargeting
  if code then
    UnitRemoveAbility(cbt.unit, code)
    cbt.flags.grantedTargeting = nil
  end
end

--- Arm an action. opts.force is for the AI's "swing anyway so the rules say no"
--- fallback, and for a DM nudging a scripted moment; it does NOT skip range,
--- targets, or slot costs.
function Combat.armAction(kind, index, opts)
  opts = opts or {}
  local cbt = S.turn and S.turn.cbt
  if not cbt then return { error = "not your turn" } end
  if opts.who and opts.who ~= cbt then return { error = "not " .. opts.who.name .. "'s turn" } end
  if kind == "attack" then
    local a = cbt.actions[index or 1]
    if not a then return { error = "no such attack" } end
    if cbt.actionUsed and not a.bonus then return { error = "action already used" } end
    S.armed = { kind = "attack", action = a, index = index or 1 }
    Combat.grantTargetingAbility(cbt, DND.RC.ATTACK)
    DND.ui.showTargeting(cbt, a)
    return { ok = true }
  elseif kind == "spell" then
    local sp = cbt.spells[index]
    if not sp then return { error = "no such spell" } end
    if cbt.actionUsed and not sp.bonus then return { error = "action already used" } end
    if sp.level > 0 and (cbt.slots[sp.level] or 0) <= 0 then
      return { error = "no " .. C.ordinal(sp.level) .. " slots left" }
    end
    S.armed = { kind = "spell", spell = sp, index = index }
    Combat.grantTargetingAbility(cbt, DND.RC.ATTACK)
    DND.ui.showTargeting(cbt, sp)
    return { ok = true }
  end
  return { error = "unknown action" }
end

function Combat.cancelAction()
  S.armed = nil
  Combat.revokeTargetingAbility(S.turn and S.turn.cbt)
  DND.ui.clearTargeting()
  return { ok = true }
end

--- Resolve the armed action against a chosen target.
function Combat.executeOn(target, opts)
  opts = opts or {}
  local cbt = S.turn and S.turn.cbt
  if not cbt or not S.armed then return { error = "nothing selected" } end
  if opts.who and opts.who ~= cbt then return { error = "not " .. opts.who.name .. "'s turn" } end
  local armed = S.armed
  local a = armed.action or armed.spell
  if not a then
    S.armed = nil
    Combat.revokeTargetingAbility(cbt)
    return { error = "the armed action vanished (statblock changed mid-turn?)" }
  end
  if target and target.hp <= 0 then return { error = "already down" } end

  if armed.kind == "spell" then
    local res = Resolve.castSpell(cbt, armed.spell, target)
    if res.error then return res end
    if armed.spell.bonus then cbt.bonusUsed = true else cbt.actionUsed = true end
    Resolve.applySpellEffect(res)
    if armed.spell.needConcSave then
      res.failedConc = not Resolve.save(cbt, "con", armed.spell.dc or 10).success
    end
    S.armed = nil
    Combat.revokeTargetingAbility(cbt)
    DND.ui.clearTargeting()
    Combat.maybeAutoEnd(cbt)
    return res
  end

  local pending = Resolve.attack(cbt, target, a, force and { force = true } or nil)
  if pending.error then return pending end
  cbt.actionUsed = not a.bonus and true or cbt.actionUsed
  if a.bonus then cbt.bonusUsed = true end
  S.armed = nil
  S.pending = pending
  Combat.revokeTargetingAbility(cbt)
  DND.ui.clearTargeting()
  -- Held for the whole multi-swing action: `maybeAutoEnd` schedules the turn's end on
  -- a timer, and in test mode that timer is instantaneous, which would end the turn
  -- between the first swing and the second.  A player would see one attack and no
  -- explanation, and the flag is cheaper than reasoning about timer order.
  cbt.flags.inAction = true
  local res = Combat.resolvePending()

  -- Extra Attack, and it lives here rather than in Resolve.attack because it is a
  -- question about the Action, not about the swing: the second attack is part of the
  -- same action, which `cbt.actionUsed` has already been spent on.  The AI gets it
  -- for free, because the AI calls these same two entry points.
  --
  -- Deliberately no reaction window per extra swing: a defender has one reaction per
  -- turn, and the first swing already spent the trigger.  Prompting again would sell
  -- the player a reaction they are not entitled to.
  for i = 2, Combatant.extraAttacks(cbt) do
    if a.bonus or not res or res.error then break end
    if target.hp <= 0 or cbt.hp <= 0 then break end
    if not S.turn or S.turn.cbt ~= cbt then break end   -- the fight moved on under us
    DND.logf("|cffffe066Extra Attack|r — %s swings %s again.", cbt.name, a.name)
    local more = Resolve.attack(cbt, target, a, force and { force = true } or nil)
    if more.error then
      res = more
      break
    end
    res = Resolve.commit(more)
    res.attacks = i
  end
  cbt.flags.inAction = nil
  Combat.maybeAutoEnd(cbt)
  return res
end

--- Insert the reaction window, then commit.  For AI defenders the reactions are
--- taken automatically; for the player's side we stop and wait for input.
function Combat.resolvePending()
  local pending = S.pending
  if not pending then return { error = "no pending attack" } end
  local defender = pending.target
  local avail = pending.reactionWindow
  if (not avail) or #avail == 0 or not DND.config.reactions then
    Resolve.commit(pending)
    S.pending = nil
    Combat.maybeAutoEnd(defender)
    Combat.maybeAutoEnd(pending.attacker)
    return pending
  end
  -- The defender is asked if it belongs to a side that plays itself; every
  -- other side resolves its own reactions with no prompt.
  if defender.side ~= C.SIDE.PARTY or DND.config.aiPlaysParty or not DND.config.reactions then
    -- AI reacts greedily: take the best option it has
    for _, r in ipairs(avail) do
      if r.key == "attack" then Resolve.takeReaction(defender, "attack", pending) break
      elseif r.key == "shield" then Resolve.takeReaction(defender, "shield", pending) break end
    end
    Resolve.commit(pending)
    S.pending = nil
    Combat.maybeAutoEnd(pending.attacker)
    return pending
  end
  -- human defender gets the prompt; the attack hangs in mid-air meanwhile
  S.phase = C.PHASE.REACTION
  S.reactionPrompt = { kind = "defense", cbt = defender, options = avail, pending = pending }
  DND.ui.promptReaction(defender, avail, pending)
  return pending
end

--- `choice` is "hold" or a reaction key. Routes to whichever flow armed the
--- prompt: a defender answering a swing, or a foe answering a movement.
function Combat.answerReaction(choice)
  local prompt = S.reactionPrompt
  if not prompt then return { error = "no reaction requested" } end
  local cbt, pending = prompt.cbt, prompt.pending
  S.reactionPrompt = nil
  if choice and choice ~= "hold" then
    Resolve.takeReaction(cbt, choice, pending)
  else
    DND.logf("%s holds its reaction.", cbt.name)
  end
  if prompt.kind == "defense" then
    Resolve.commit(pending)
    S.pending = nil
    S.phase = C.PHASE.ACTION
  end
  DND.ui.clearReaction()
  if Combat.drainQueuedOpportunities() then return { ok = true, queued = true } end
  Combat.maybeAutoEnd(cbt)
  return { ok = true }
end

--- Opportunity attacks on movement.  A player-side defender is asked; an AI
--- defender just swings.  Prompts are queued so leaving two enemies' reach
--- spends the single reaction on the first of them, exactly as 5e rules go.
function Combat.offerOpportunities(mover, react)
  for _, r in ipairs(react) do
    local foe = r.foe
    -- Direction matters and is easy to flip: the *reacting* creature swings at
    -- the one that just walked away.
    local pending = { attacker = foe, target = mover, action = r.atk,
                      isOpportunity = true, advNotes = {}, reactionWindow = nil,
                      reactionFor = mover }
    -- Ask the DEFENDER, not "the side that is not acting". Keying this off
    -- whose turn it is was my first instinct and it is wrong: on an invader's
    -- turn the reactor IS the player, and that is exactly when a free attack
    -- against them deserves a "do you take it?" prompt.
    if foe.side ~= C.SIDE.PARTY or DND.config.aiPlaysParty or not DND.config.reactions then
      foe.reactionTaken = false
      Resolve.takeReaction(foe, "attack", pending)
    elseif not S.reactionPrompt then
      S.phase = C.PHASE.REACTION
      S.reactionPrompt = { kind = "opportunity", cbt = foe, pending = pending,
                           options = { { key = "attack", label = "Opportunity Attack" } } }
      DND.ui.promptReaction(foe, S.reactionPrompt.options, pending)
    else
      -- a second foe also wants a bite; the mover is already inside reach so we
      -- let the queue drain one at a time when the first prompt closes.
      foe.flags.pendingOpportunity = pending
    end
  end
end

--- Called after a prompt closes: anyone still owed an opportunity gets it.
function Combat.drainQueuedOpportunities()
  for _, cbt in ipairs(Combatant.all()) do
    local p = cbt.flags.pendingOpportunity
    if p then
      cbt.flags.pendingOpportunity = nil
      cbt.reactionTaken = false
      Resolve.takeReaction(cbt, "attack", p)
      return true     -- one at a time; re-enters from answerReaction
    end
  end
  return false
end

---------------------------------------------------------------------- other acts
function Combat.useAction(kind, opts)
  local cbt = S.turn and S.turn.cbt
  if not cbt then return { error = "not your turn" } end
  if cbt.actionUsed then return { error = "action used" } end
  if kind == "dash" then
    cbt.movementLeft = cbt.movementLeft + cbt.speed * C.UNITS_PER_FOOT
    cbt.actionUsed = true
    DND.logf("%s dashes (+" .. cbt.speed .. " ft).", cbt.name)
  elseif kind == "disengage" then
    cbt.flags.disengaged = true
    cbt.actionUsed = true
    DND.logf("%s disengages — movement will not provoke.", cbt.name)
  elseif kind == "dodge" then
    cbt.flags.dodge = true
    cbt.actionUsed = true
    DND.logf("%s takes the Dodge action (attacks vs it have disadvantage).", cbt.name)
  elseif kind == "help" then
    cbt.actionUsed = true
    DND.logf("%s helps an ally's next check.", cbt.name)
  elseif kind == "hide" then
    cbt.actionUsed = true
    Resolve.stealth(cbt, cbt.flags.hideDc or 12)
  elseif kind == "ready" then
    cbt.actionUsed = true
    cbt.flags.readied = { attack = opts and opts.attack or Combatant.primaryAttack(cbt) }
    DND.logf("%s readies %s.", cbt.name, cbt.flags.readied.attack.name)
  elseif kind == "heal" then
    if cbt.hitDice <= 0 then return { error = "no Hit Dice left" } end
    cbt.actionUsed = true
    Resolve.spendHitDie(cbt)
  elseif kind == "stabilize" then
    local down = Combat.downedFoeOrAlly(cbt)
    if not down then return { error = "nobody to stabilise" } end
    cbt.actionUsed = true
    Resolve.stabilize(cbt, down)
  else
    return { error = "unknown action: " .. tostring(kind) }
  end
  DND.ui.showActions(cbt)
  return { ok = true }
end

--- Bonus actions: off-hand attack, class features, second wind.
function Combat.useBonus(kind)
  local cbt = S.turn and S.turn.cbt
  if not cbt then return { error = "not your turn" } end
  -- The flag goes up only once the attack is committed. Setting it first and
  -- unwinding it on every early return is how you get "two bonus actions" or
  -- "none at all", depending on which branch forgets to put it back.
  if cbt.bonusUsed then return { error = "bonus action used" } end
  if kind == "offhand" then
    local a = cbt.bonusAttack
    if not a then return { error = "no light weapon to off-hand" } end
    local tgt = S.cycleTarget or (Combat.enemiesOf(cbt)[1])
    if not tgt then return { error = "no target in reach" } end
    local p = Resolve.attack(cbt, tgt, a, { force = true })
    if p.error then return p end
    cbt.bonusUsed = true
    S.pending = p
    return Combat.resolvePending()
  elseif kind == "secondwind" then
    cbt.bonusUsed = true
    local r = Resolve.spendHitDie(cbt)
    DND.logf("%s uses Second Wind.", cbt.name)
    return r
  end
  for _, t in ipairs(cbt.traits) do
    if t.key == kind then
      cbt.bonusUsed = true
      if t.onUse then return t.onUse(cbt) or { ok = true } end
      return { ok = true }
    end
  end
  return { error = "no such bonus: " .. tostring(kind) }
end

function Combat.downedFoeOrAlly(cbt)
  local pool = (cbt.side == C.SIDE.PARTY) and Combatant.living(C.SIDE.PARTY)
             or Combatant.living(C.SIDE.FOES)
  for _, other in ipairs(pool) do
    if other.hp <= 0 and other.downed then return other end
  end
  for _, other in ipairs(Combatant.all()) do
    if other.hp <= 0 and other.downed and other.side == cbt.side then return other end
  end
  return nil
end

--- If the active creature has nothing left to do, close its turn promptly.
--- Convenience only: closing the turn when nothing is left to do. It has to be
--- switchable, because in tests every deferred callback runs synchronously and
--- a turn that evaporates mid-assertion looks exactly like a rules bug.
function Combat.maybeAutoEnd(cbt)
  if not DND.config.autoEndTurn then return end
  if not cbt or not S.running then return end
  if S.turn and S.turn.cbt ~= cbt then return end
  if cbt.side ~= C.SIDE.PARTY then return end
  if cbt.flags.inAction then return end   -- the Action is still resolving its swings
  if cbt.actionUsed and cbt.bonusUsed and (cbt.movementLeft < C.FIVE_FEET) then
    DND.ui.setHint("Nothing left to do — turn ends.")
    w3.after(DND.testMode and 0 or 0.8, function()
      if S.turn and S.turn.cbt == cbt and not S.armed and not S.pending then
        Combat.endTurn(cbt)
      end
    end)
  end
end

---------------------------------------------------------------------- DM tools
--- Put a named creature in the driver's seat without advancing anybody else.
--- A party turn is *waited for*, so an endTurn() loop to reach it would also
--- run straight through the AI's turn and land back where it started; this is
--- the primitive both the DM console and the test suite need.
function Combat.giveTurn(name)
  local t = DND.Combat.turns
  if #t.order == 0 then
    DND.logf("giveTurn: no combat is running")
    return nil
  end
  local needle = name and name:lower() or nil
  for i, e in ipairs(t.order) do
    if (not needle) or e.cbt.name:lower() == needle then
      t.index = i
      S.turn, S.armed, S.pending, S.reactionPrompt = e, nil, nil, nil
      Combat.beginTurn(e.cbt)
      return e.cbt
    end
  end
  return nil
end

function Combat.rerollLast()
  if not S.pending then return { error = "no attack in flight" } end
  local p = S.pending
  local fresh = Dice.attackRoll(p.action.toHit or 0, p.ac, { adv = p.adv })
  DND.logf("DM forces a reroll: %d → %d", p.roll.total, fresh.total)
  p.roll = fresh
  p.hit = fresh.hit
  p.damage = 0
  if fresh.hit then
    local r = Dice.rollExpr(p.action.damage, { double = fresh.crit,
      bonus = p.action.finesse and math.max(p.attacker.mods.str, p.attacker.mods.dex)
             or (p.action.ability and p.attacker.mods[p.action.ability] or p.attacker.mods.str) })
    p.damage = r.total
  end
  return { ok = true }
end

function Combat.setHp(cbt, v)
  cbt.hp = C.clamp(v, 0, cbt.hpMax)
  if cbt.hp > 0 then cbt.downed = false end
  Combatant.sync(cbt)
  DND.logf("DM sets %s to %d hp.", cbt.name, cbt.hp)
end

function Combat.grantAdvantage(cbt)
  cbt.flags.hidden = true
  DND.logf("%s is treated as unseen until it acts.", cbt.name)
end

return Combat
