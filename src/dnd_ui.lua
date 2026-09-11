--[[ =========================================================================
  dnd_ui.lua — everything the player can see.

  WC3 gives us a command card we cannot write to at runtime and a tooltip we
  cannot reformat on the fly, so the D&D layer builds its own chrome out of
  raw frames (BlzCreateFrameByType on stock templates = no FDF, no .toc, works
  in any patch) plus floating text tags. If a frame native is unavailable the
  panel silently degrades to the native log and hotkeys — the game is playable
  with the UI switch off, which is worth a lot when you are debugging at 1am.
========================================================================== ]]
DND = DND or {}
DND.ui = {}
local ui = DND.ui
local C = DND.CONST
local w3 = DND.w3

ui.enabled = true
ui.frames = {}
ui.state = { hint = "", log = {}, tracker = {}, actions = {}, targets = {} }
local L = ui.state

---------------------------------------------------------------------- frames
local function mk(typ, name, parent, inherits)
  if DND.testMode or not ui.enabled then return nil end
  if not w3.has("BlzCreateFrameByType") then return nil end
  local f = BlzCreateFrameByType(typ, name, parent or BlzGetOriginFrame(ORIGIN_FRAME_GAME_UI, 0),
                                 inherits or "", 0)
  return f
end

local function txt(name, x, y, size, w, h)
  local f = mk("TEXT", name, nil, "TooltipTextTemplate")
  if not f then return nil end
  BlzFrameSetAbsPoint(f, FRAMEPOINT_TOPLEFT, x, y)
  BlzFrameSetSize(f, w or 0.30, h or 0.026)
  BlzFrameSetText(f, "")
  return f
end

local function button(name, label, x, y, w, h, onClick, key)
  local f = mk("BUTTON", name, nil, "StandardButtonTemplate")
  if not f then return nil end
  BlzFrameSetAbsPoint(f, FRAMEPOINT_CENTER, x, y)
  BlzFrameSetSize(f, w or 0.072, h or 0.036)
  local t = BlzCreateFrameByType("TEXT", name .. "Label", f, "TooltipTextTemplate", 0)
  BlzFrameSetAllPoints(t, f)
  BlzFrameSetText(t, (key and ("[" .. key .. "] " .. label)) or label)
  local tr = CreateTrigger()
  BlzTriggerRegisterFrameEvent(tr, f, FRAMEEVENT_CONTROL_CLICK)
  TriggerAddAction(tr, function()
    -- buttons steal keyboard focus; bounce it so hotkeys keep working
    BlzFrameSetEnable(f, false); BlzFrameSetEnable(f, true)
    if onClick then onClick() end
  end)
  return f
end

function ui.init()
  if DND.testMode then return end
  ui.state.round   = txt("DNDTitle", 0.005, 0.005, 10)
  ui.state.log0    = txt("DNDLog0", 0.005, 0.036, 9)
  ui.state.log1    = txt("DNDLog1", 0.005, 0.060, 9)
  ui.state.log2    = txt("DNDLog2", 0.005, 0.084, 9)
  ui.state.hintBox = txt("DNDHint", 0.005, 0.108, 9)
  ui.state.tracker = txt("DNDTracker", 0.80, 0.02, 9)
  ui.state.status  = txt("DNDStatus", 0.34, 0.02, 11)
  ui.enabled = ui.state.round ~= nil
end

---------------------------------------------------------------------- log
function ui.pushLog(line)
  local log = L.log
  log[#log + 1] = line
  while #log > 60 do table.remove(log, 1) end
  if not ui.enabled then return end
  local recent = {}
  for i = math.max(1, #log - 2), #log do recent[#recent + 1] = log[i] end
  if ui.state.log0 then BlzFrameSetText(ui.state.log0, recent[1] or "") end
  BlzFrameSetText(ui.state.log1, recent[1] or "")
  if ui.state.log1 then BlzFrameSetText(ui.state.log1, recent[2] or "") end
  if ui.state.log2 then BlzFrameSetText(ui.state.log2, recent[3] or "") end
end

function ui.setHint(s)
  L.hint = s
  if ui.enabled and ui.state.hintBox then BlzFrameSetText(ui.state.hintBox, s) end
end

---------------------------------------------------------------------- tracker
function ui.buildTracker()
  L.tracker = DND.Turns.summary(DND.Combat.turns)
  if not ui.enabled or not ui.state.tracker then return end
  local lines = { "|cffffe066INITIATIVE|r" }
  for i, s in ipairs(L.tracker) do lines[#lines + 1] = s end
  BlzFrameSetText(ui.state.tracker, table.concat(lines, "\n"))
end

function ui.refreshStatus(cbt)
  if not ui.enabled or not ui.state.status then return end
  local con = {}
  for k in pairs(cbt.statuses) do con[#con + 1] = k end
  table.sort(con)
  local s = cbt.name .. ": " .. cbt.hp .. "/" .. cbt.hpMax .. " hp, AC " .. cbt.ac
  if #con > 0 then s = s .. "  |cffff8866[" .. table.concat(con, ", ") .. "]|r" end
  BlzFrameSetText(ui.state.status, s)
end

---------------------------------------------------------------------- action bar
local function clearTable(t) for k in pairs(t) do t[k] = nil end end

function ui.showActions(cbt)
  clearTable(L.actions)
  for i, a in ipairs(cbt.actions) do
    L.actions[#L.actions + 1] = {
      key = tostring(i), kind = "attack", index = i,
      label = a.name .. (DND.Combatant.extraAttacks(cbt) > 1 and " x2" or ""),
      sub = a.toHit and (C.signed(a.toHit) .. " to hit, " .. a.damage) or ("DC " .. a.spellDc),
      enabled = (not cbt.actionUsed) or a.bonus == true,
    }
  end
  for i, sp in ipairs(cbt.spells) do
    local left = sp.level == 0 and 99 or (cbt.slots[sp.level] or 0)
    L.actions[#L.actions + 1] = {
      key = string.format("F%d", i), label = sp.name, kind = "spell", index = i,
      sub = (sp.level == 0 and "cantrip" or (C.ordinal(sp.level) .. " " .. left .. "/" .. (cbt.slotMax[sp.level] or 0))),
      enabled = (left > 0) and (not cbt.actionUsed or sp.bonus == true),
    }
  end
  L.actions[#L.actions + 1] = { key = "Q", label = "Dash", kind = "act", act = "dash",
                                enabled = not cbt.actionUsed }
  L.actions[#L.actions + 1] = { key = "W", label = "Disengage", kind = "act", act = "disengage",
                                enabled = not cbt.actionUsed }
  L.actions[#L.actions + 1] = { key = "E", label = "Dodge", kind = "act", act = "dodge",
                                enabled = not cbt.actionUsed }
  L.actions[#L.actions + 1] = { key = "R", label = "Hide", kind = "act", act = "hide",
                                enabled = not cbt.actionUsed }
  L.actions[#L.actions + 1] = { key = "T", label = "Hit Die", kind = "act", act = "heal",
                                enabled = cbt.hitDice > 0 and not cbt.actionUsed }
  L.actions[#L.actions + 1] = { key = "Y", label = "Stabilise", kind = "act", act = "stabilize",
                                enabled = DND.Combat.downedFoeOrAlly(cbt) ~= nil }
  -- keep the bar honest: a listed key that the input layer does not read is a
  -- lie the player will discover the hard way
  L.actions.checked = true
  for i, t in ipairs(cbt.traits) do
    L.actions[#L.actions + 1] = { key = string.format("F%d", #cbt.spells + i), label = t.name,
                                  kind = "bonus", trait = t.key,
                                  sub = t.desc or "bonus action",
                                  enabled = not cbt.bonusUsed }
  end
  if cbt.bonusAttack then
    L.actions[#L.actions + 1] = { key = "G", label = "Off-hand", kind = "bonus",
                                  sub = cbt.bonusAttack.damage,
                                  enabled = not cbt.bonusUsed }
  end
  L.actions[#L.actions + 1] = { key = "SPACE", label = "End Turn", kind = "end", enabled = true }
  L.targets = ui.targetList(cbt)
  ui.renderActionBar()
end

--- Enemies currently in reach for whatever is armed — this is what makes the
--- 1-9 keys feel like a tactics game rather than a menu.
function ui.targetList(cbt, armed)
  local out = {}
  for _, foe in ipairs(DND.Combat.enemiesOf(cbt)) do
    local a = armed and (armed.action or armed.spell) or cbt.actions[1]
    local need = (a and a.range and C.ft(a.range)) or (a and a.reach) or C.ft(5)
    local d = w3.dist(cbt.unit, foe.unit)
    out[#out + 1] = { cbt = foe, inRange = d <= need + C.FIVE_FEET,
                      dist = C.round(C.unitsToFeet(d)), hp = foe.hp, ac = foe.ac }
  end
  return out
end

function ui.renderActionBar()
  L.actionText = {}
  for i, a in ipairs(L.actions) do
    L.actionText[i] = string.format("%s%s [%s] %s — %s",
      a.enabled and " " or "x", "", a.key, a.label, a.sub or "")
  end
  L.targetText = {}
  for i, t in ipairs(L.targets) do
    L.targetText[i] = string.format("%d. %s%s  AC%d  %dhp  %dft", i, t.cbt.name,
      t.inRange and " (in range)" or "  ", t.ac, t.hp, t.dist)
  end
  if not ui.enabled then return end
  local parts = { "|cffffe066ACTIONS|r" }
  for i = 1, #L.actionText do parts[#parts + 1] = L.actionText[i] end
  parts[#parts + 1] = "|cffffe066TARGETS|r"
  for i = 1, math.min(8, #L.targetText) do parts[#parts + 1] = L.targetText[i] end
  if ui.enabled and ui.state.round then BlzFrameSetText(ui.state.round, table.concat(parts, "\n")) end
end

function ui.updateMovement(cbt)
  L.moveText = string.format("%s: %.0f/%.0f ft left, action %s, bonus %s, reaction %s",
    cbt.name, C.round(C.unitsToFeet(cbt.movementLeft)), cbt.speed,
    cbt.actionUsed and "used" or "ready", cbt.bonusUsed and "used" or "ready",
    cbt.reactionTaken and "used" or "ready")
  if ui.enabled then ui.setHint(L.moveText) end
end

function ui.hideActions(cbt)
  clearTable(L.actions); clearTable(L.targets)
  if ui.enabled and ui.state.round then BlzFrameSetText(ui.state.round, "") end
end

function ui.setActive(cbt)
  L.active = cbt.cid
  ui.refreshStatus(cbt)
  ui.updateMovement(cbt)
  if DND.testMode then return end
  if cbt.unit and not DND.testMode then
    w3.safe("SelectUnitForSingleUser", cbt.unit)
  end
end
function ui.clearActive() L.active = nil end

---------------------------------------------------------------------- prompts
function ui.promptPlayer(cbt)
  ui.setHint(string.format("YOUR TURN: pick an action (1-%d), move with A/S/D/W, "
    .. "Space ends.", math.max(9, #cbt.actions)))
end

--- Three different pending shapes reach this prompt (a swing in flight, an
--- opportunity attack, a readied action) and they do not all carry the same
--- fields, so every one of them is defaulted. %d against a nil ac is a crash in
--- the single most player-visible moment in the game.
function ui.promptReaction(cbt, options, pending)
  local names = {}
  for i, o in ipairs(options) do names[i] = string.format("%d) %s", i, o.label or "?") end
  local who = pending and pending.attacker and pending.attacker.name or "the attacker"
  local ac = (pending and pending.ac) or (pending and pending.roll and pending.roll.ac) or 0
  local what = (pending and pending.action and pending.action.name) or "attack"
  ui.setHint(string.format("|cffff8866REACTION — %s|r: %s's %s is in the air vs AC %d."
    .. "  %s  (Y=take, N=hold)",
    cbt and cbt.name or "?", who, what, ac, table.concat(names, "  ")))
end

function ui.clearReaction() ui.setHint("Reaction resolved.") end

function ui.showTargeting(cbt, a)
  L.armed = a
  ui.setHint(string.format("Armed: %s. Pick a target with 1-9, or Esc to cancel.",
    a.name or (a and a.desc) or "?"))
end
function ui.clearTargeting() L.armed = nil end

---------------------------------------------------------------------- feedback
-- The dice have to be *seen*. This is the single biggest "it's D&D now" win.
function ui.showHit(attacker, target, roll, dealt, pending)
  if not target.unit then return end
  w3.textTag(target.unit, tostring(dealt) .. (roll.crit and "!!" or ""), 12,
    roll.crit and 255 or 255, roll.crit and 230 or 120, 60)
  if roll.crit then w3.textTag(target.unit, "CRIT", 10, 255, 215, 0) end
  local art = (pending and pending.type and C.DMG_EFFECT[pending.type])
    or "Abilities\\Weapons\\Axe\\AxeMissile\\AxeMissile.mdl"
  w3.fxTarget(art, target.unit, "origin")
end

function ui.showMiss(attacker, target, roll, ac)
  if not target.unit then return end
  w3.textTag(target.unit, "MISS", 11, 200, 200, 200)
  if ac and roll then
    w3.textTag(attacker.unit, roll.natural .. C.signed(roll.mod) .. " vs " .. ac, 8,
      180, 180, 255)
  end
end

function ui.showSave(target, r)
  if not target.unit then return end
  w3.textTag(target.unit, r.success and "SAVE ok" or "SAVE fail", 10,
    r.success and 140 or 255, r.success and 255 or 90, 140)
end

function ui.showHeal(target, got)
  if not target.unit then return end
  w3.textTag(target.unit, "+" .. got, 11, 120, 255, 120)
end

function ui.showSpellHit(caster, target, spell, dmg)
  if target and target.unit then
    w3.fxTarget(C.SCHOOL_ICON[spell.school or "evocation"], target.unit, "origin")
  end
end

function ui.showDowned(cbt)
  ui.setHint("|cffff8866" .. cbt.name .. " is down.|r  Death saves begin.")
  if cbt.unit then w3.textTag(cbt.unit, "DOWN", 12, 255, 60, 60) end
end

function ui.showDied(cbt)
  if cbt.unit then w3.textTag(cbt.unit, "x", 14, 255, 40, 40) end
  ui.buildTracker()
end

function ui.pulse(cbt)
  if cbt.unit then w3.playAnim(cbt.unit, "spell") end
end

function ui.clear()
  clearTable(L.actions); clearTable(L.targets); L.hint = ""
  if ui.enabled and ui.state.round then BlzFrameSetText(ui.state.round, "") end
  if ui.enabled and ui.state.tracker then BlzFrameSetText(ui.state.tracker, "") end
end

--- A compact text dump of the panel — the harness asserts against this, so the
--- UI is not just decoration, it is checked code.
function ui.dump()
  local out = { string.format("ROUND %d  PHASE %s", DND.Combat.turns.round,
    DND.Combat.state.phase) }
  for i = 1, #L.actionText or 0 do out[#out + 1] = L.actionText[i] end
  for i = 1, #L.targetText or 0 do out[#out + 1] = L.targetText[i] end
  out[#out + 1] = L.hint
  return table.concat(out, "\n")
end

return ui
