--[[ =========================================================================
  dnd_input.lua — the keyboard, the mouse, and the DM's chat line.

  Two facts drive this file:

    * BlzTriggerRegisterPlayerKeyEvent is *synced by the engine* (community
      docs, 1.31+), so a keypress is a legal network command — no hashtable
      round-trip, no TrustMe frame. That is how a D&D action bar gets built.
    * The default command card cannot be rewritten at runtime, so we do not
      fight it: hotkeys + our own frame buttons + right-click in the world.

  Every handler funnels into DND.Combat, never into the rules directly.
========================================================================== ]]
DND = DND or {}
DND.Input = {}
local Input = DND.Input
local C = DND.CONST
local w3 = DND.w3
local Combat = DND.Combat
local S = Combat.state

Input.keys = {}
local bound = {}

--- Move step in feet per keypress. A 10 ft step is half a 30 ft turn: enough
--- to position precisely without burning the whole budget on one click.
Input.stepFt = 10

local function activeCbt()
  local e = S.turn
  if not e then return nil end
  return e.cbt
end

--- Every enemy within reach of whatever is armed. Melee has no `range` field at
--- all, so a bare `C.ft(a.range)` here raises "bad argument #1 to 'ft' (number
--- expected, got nil)" — and because this runs inside a key handler, that error
--- is swallowed by the trigger system and the key just silently does nothing.
local function reachOf(a)
  if not a then return C.ft(5) end
  if a.range then return C.ft(a.range) end
  if a.reach then return a.reach end
  if a.aoe then return C.ft(a.aoe) end
  if a.save then return C.ft(a.range or 5) end
  return C.ft(5)
end

local function inRangeFoes(cbt, armed)
  local out = {}
  if not cbt then return out end
  for _, foe in ipairs(Combat.enemiesOf(cbt)) do
    local a = armed and (armed.action or armed.spell)
    local need = reachOf(a)
    if w3.dist(cbt.unit, foe.unit) <= need + C.FIVE_FEET then out[#out + 1] = foe end
  end
  return out
end

---------------------------------------------------------------------- dispatch
--- The one true input path. `code` is an OSKEY name; harness tests call this
--- directly, so a keybind is exercised by the test suite too.
--- Ctrl+T toggles engine chatter; plain T is a game key. Checking the modifier
--- first keeps a debug switch from stealing a rules binding, which is exactly
--- the kind of collision that makes a key "do nothing" with no error anywhere.
function Input.press(code, metaKey)
  if code == "OSKEY_T" and (metaKey or 0) == 2 then
    Combat.debug = not Combat.debug
    DND.logf("engine chatter %s", Combat.debug and "on" or "off")
    return
  end
  if not S.running then return end
  local cbt = activeCbt()
  if not cbt then return end
  local isMine = cbt.side == C.SIDE.PARTY
  if not isMine then DND.ui.setHint("The invaders are moving. Hold.") return end

  -- A reaction prompt outranks everything else on screen.
  if S.phase == C.PHASE.REACTION then
    if code == "OSKEY_Y" or code == "OSKEY_ENTER" then
      local p = S.reactionPrompt
      local opt = p and p.options and p.options[1]
      Combat.answerReaction(opt and opt.key or "attack")
    elseif code == "OSKEY_N" or code == "OSKEY_ESCAPE" then
      Combat.answerReaction("hold")
    end
    return
  end

  -- Arrow keys: one 5 ft square, free. WC3 never binds the arrows to unit
  -- orders, so unlike WASD they cannot collide with the game's own hotkeys.
  if code == "OSKEY_UP"    then return Input.step("f") end
  if code == "OSKEY_DOWN"  then return Input.step("b") end
  if code == "OSKEY_LEFT"  then return Input.step("l") end
  if code == "OSKEY_RIGHT" then return Input.step("r") end
  if code == "OSKEY_ESCAPE" then Combat.cancelAction() return end
  if code == "OSKEY_SPACE" or code == "OSKEY_ENTER" then
    if S.armed then Input.executeArmed() else Combat.endTurn(cbt) end
    return
  end
  if code == "OSKEY_BACK_SPACE" then Combat.undoMove() return end
  if code == "OSKEY_TAB" then Input.cycleTarget() return end

  -- digits: 1..9 arm an action, or fire the armed one at that target number
  local digit = tonumber((code:gmatch("OSKEY_(%d)")()) or "")
  if digit then
    Input.digit(digit == 0 and 10 or digit)
    return
  end

  if code == "OSKEY_Q" then Input.act("dash")
  elseif code == "OSKEY_W" then Input.moveBy(0, Input.stepFt)
  elseif code == "OSKEY_E" then Input.act("dodge")
  elseif code == "OSKEY_A" then Input.moveBy(-Input.stepFt, 0)
  elseif code == "OSKEY_D" then Input.moveBy(Input.stepFt, 0)
  elseif code == "OSKEY_S" then Input.moveBy(0, -Input.stepFt)
  elseif code == "OSKEY_X" then Input.act("disengage")
  elseif code == "OSKEY_R" then Input.act("hide")
  elseif code == "OSKEY_T" then Input.act("heal")
  elseif code == "OSKEY_Y" then Input.act("stabilize")
  elseif code == "OSKEY_G" then Combat.useBonus("offhand")
  elseif code == "OSKEY_F" then Input.nextBonus()
  elseif code:sub(1, 7) == "OSKEY_F" then
    local n = tonumber(code:sub(8))
    if n and n <= 12 then Input.functionKey(n) end
  elseif code == "OSKEY_Z" then Combat.rerollLast()   -- DM tool, remove for release
  end
end

function Input.digit(n)
  local cbt = activeCbt()
  if S.armed then
    local foes = inRangeFoes(cbt, S.armed)
    local t = foes[n] or (DND.Combat.enemiesOf(cbt)[n])
    if not t then DND.ui.setHint("No target number " .. n .. " in range.") return end
    Input.executeArmed(t)
    return
  end
  -- arm: first the creature's own attacks, then spells, then bar entries
  if n <= #cbt.actions then
    local r = Combat.armAction("attack", n)
    if r and r.error then DND.ui.setHint(r.error) return end
    DND.ui.setHint(("%s armed — press %d for the nearest target, or Tab to cycle.")
      :format(cbt.actions[n].name, n))
    return
  end
  local si = n - #cbt.actions
  if si <= #cbt.spells then
    local r = Combat.armAction("spell", si)
    if r and r.error then DND.ui.setHint(r.error) end
  end
end

function Input.functionKey(n)
  local cbt = activeCbt()
  if n <= #cbt.spells then
    local r = Combat.armAction("spell", n)
    if r and r.error then DND.ui.setHint(r.error) return end
    Input.executeArmed()
  else
    local ti = n - #cbt.spells
    local t = cbt.traits[ti]
    if t then Combat.useBonus(t.key) end
  end
end

function Input.nextBonus()
  local cbt = activeCbt()
  for _, t in ipairs(cbt.traits) do
    if t.bonus then Combat.useBonus(t.key) return end
  end
  if cbt.bonusAttack then Combat.useBonus("offhand") return end
  DND.ui.setHint("No bonus action available.")
end

function Input.act(kind)
  local cbt = activeCbt()
  if kind == "disengage" and cbt.bonusUsed == false then
    for _, t in ipairs(cbt.traits) do
      if t.key == "cunning" then Combat.useBonus("cunning") return end
    end
  end
  local r = Combat.useAction(kind)
  if r and r.error then DND.ui.setHint(r.error) end
end

--- Fire whatever is armed. With no explicit target, take the first in range —
--- which is why the number keys feel fast in play.
function Input.executeArmed(target)
  local cbt = activeCbt()
  if not S.armed then DND.ui.setHint("Nothing armed.") return end
  local t = target or (S.armed.spell and not S.armed.spell.needTarget and cbt)
               or inRangeFoes(cbt, S.armed)[1]
  if not t then
    local foes = inRangeFoes(cbt, S.armed)
    DND.ui.setHint(string.format("Nothing in range (%d foes visible). Move or Tab.",
      #DND.Combat.enemiesOf(cbt)))
    if #foes == 0 and not (S.armed.spell and not S.armed.spell.needTarget) then return end
  end
  local r = Combat.executeOn(t or (S.armed.spell and not S.armed.spell.needTarget and cbt))
  if r and r.error then DND.ui.setHint(r.error) end
end

local cycleIdx = 0
function Input.cycleTarget()
  local cbt = activeCbt()
  local foes = DND.Combat.enemiesOf(cbt)
  if #foes == 0 then return end
  cycleIdx = cycleIdx % #foes + 1
  local t = foes[cycleIdx]
  local a = S.armed and (S.armed.action or S.armed.spell) or cbt.actions[1]
  local need = reachOf(a)
  local d = C.round(C.unitsToFeet(w3.dist(cbt.unit, t.unit)))
  DND.ui.setHint(string.format("Target %d/%d: %s (%d ft, AC %d) %s",
    cycleIdx, #foes, t.name, d, t.ac,
    d <= need + C.FIVE_FEET and "|cff88ff88[in range]|r" or "|cffff8866[out of range]|r"))
  S.cycleTarget = t
end

---------------------------------------------------------------------- movement
--- Keyboard nudging. WC3 exposes no camera yaw, so WASD is world-aligned
--- (W = north); the mouse path below is what people will actually use.
function Input.moveBy(dx, dy)
  local cbt = activeCbt()
  if not cbt then return end
  local u = cbt.unit
  local r = Combat.move({ x = GetUnitX(u) + C.ft(math.abs(dx) > 0 and dx or 0) * (dx < 0 and -1 or 1)
                                + (dx == 0 and 0 or C.ft(math.abs(dx)) * (dx < 0 and -1 or 1)) * 0,
                          y = GetUnitY(u) + C.ft(math.abs(dy) > 0 and dy or 0) })
  -- (kept explicit so the sign maths is readable; see test_input_nudge)
  if r and r.error then DND.ui.setHint(r.error) end
end

--- Click-to-act. BlzGetTriggerPlayerMouseX/Y are synced, so a click is a legal
--- order: enemy under the cursor attacks, ground moves.
function Input.worldClick(player)
  if not S.running then return end
  local cbt = activeCbt()
  if not cbt then return end
  if cbt.side ~= C.SIDE.PARTY then DND.ui.setHint("Not your turn.") return end
  local mx, my = BlzGetTriggerPlayerMouseX(), BlzGetTriggerPlayerMouseY()
  -- anything hostile under the cursor wins
  local hit
  for _, foe in ipairs(Combat.enemiesOf(cbt)) do
    if w3.distPts(mx, my, GetUnitX(foe.unit), GetUnitY(foe.unit)) < C.ft(5) + 12 then
      hit = foe
      break
    end
  end
  if hit and S.armed then
    Input.executeArmed(hit)
  elseif hit then
    local a = cbt.actions[1]
    local need = reachOf(a)
    if w3.dist(cbt.unit, hit.unit) <= need + C.FIVE_FEET then
      local arm = Combat.armAction("attack", 1)
      if arm and not arm.error then Combat.executeOn(hit) end
    else
      DND.ui.setHint("Out of reach — move first.")
    end
  elseif S.armed then
    -- right-clicking empty ground with an action armed = cancel (WC3 muscle memory)
    Combat.cancelAction()
  else
    local r = Combat.move({ x = mx, y = my })
    if r and r.error then DND.ui.setHint(r.error) end
  end
end

--- One square at a time. This is NOT a free action: 5e has no 5-foot step, so it
--- spends 5 ft of the move like any other distance. The arrow keys exist because
--- WC3 never binds them to unit orders, so they cannot collide with the game's
--- own Q/W/E/R/A/S/D/F ability hotkeys the way WASD nudging can.
local STEP = { f = {0, 1}, b = {0, -1}, l = {-1, 0}, r = {1, 0} }
function Input.step(dir)
  local cbt = activeCbt()
  if not cbt then return end
  local v = STEP[dir] or STEP.f
  local d = C.FIVE_FEET
  local r = Combat.move({ x = w3.x(cbt.unit) + v[1] * d,
                           y = w3.y(cbt.unit) + v[2] * d }, { free = true })
  if r and r.error then DND.ui.setHint(r.error) end
end

---------------------------------------------------------------------- chat
Input.commands = {
  ["-start"]  = { "start <ambush|tavern|dragon|mirror|tourney|delve1..6>", function(rest)
      DND.Data.run(rest == "" and "ambush" or rest, DND.entryAnchor, DND.entryAnchor2)
    end },
  ["-end"]    = { "end the fight", function() Combat.abort("chat") end },
  ["-roll"]   = { "roll <expr>, e.g. -roll 2d6+3", function(rest)
      local r = DND.Dice.rollExpr(rest == "" and "1d20" or rest)
      DND.logf("You roll %s: %s = %d", rest, table.concat(r.faces, ","), r.total)
    end },
  ["-hp"]     = { "hp <name> <n>", function(rest)
      local name, v = rest:match("^(%S+)%s+(%-?%d+)$")
      for _, cbt in ipairs(DND.Combatant.all()) do
        if cbt.name:lower():find((name or ""):lower(), 1, true) then
          Combat.setHp(cbt, tonumber(v))
          return
        end
      end
      DND.logf("No creature called %s", tostring(name))
    end },
  ["-hit"]    = { "roll an attack: -hit 5 15", function(rest)
      local b, ac = rest:match("^(%-?%d+)%s+(%d+)$")
      local r = DND.Dice.attackRoll(tonumber(b), tonumber(ac))
      DND.logf("attack %+d vs AC %d: d20 %d = %d → %s%s", tonumber(b), tonumber(ac),
        r.natural, r.total, r.hit and "HIT" or "miss", r.crit and " CRIT" or "")
    end },
  ["-cond"]   = { "condition <name> <n>  e.g. -cond frightened 3", function(rest)
      local k, n = rest:match("^(%a+)%s*(%d*)$")
      for _, cbt in ipairs(DND.Combatant.all()) do
        if k and cbt.name:lower():find(k:lower(), 1, true) then
          DND.addCond(cbt, (n == "" or not n) and "stunned" or "frightened",
            { duration = tonumber(n) or 1 })
          return
        end
      end
    end },
  ["-ai"]     = { "run the AI's whole turn now", function()
      local cbt = activeCbt()
      if cbt and DND.ai then DND.ai.takeTurn(cbt, function() Combat.endTurn(cbt) end) end
    end },
  ["-delve"]  = { "delve <1-6>: the guided run, with a rest in the corridor",
    function(rest)
      local n = tonumber((rest or ""):match("%d+") or "1") or 1
      -- the guided version: an hour or two in the corridor, which is what a table
      -- would actually do. `-start delve3` is the same dungeon with that kindness
      -- switched off, and the difference in who survives is the whole lesson.
      -- Two hours, i.e. one Hit Die per character per hour of rest: the most a
      -- short rest gives, and the amount the table would actually spend between
      -- rooms (two hours, one Hit Die each). It does not make the delve safe —
      -- measured, it moves your deaths later (see README "the delve") — which is
      -- what a short rest is for. The number lives on the delve's own encounter
      -- row, so it does not leak into the next fight you start by hand.
      DND.Data.startEncounter("delve" .. math.max(1, math.min(6, n)), {})
      DND.Data.delveHelp()
    end },
  ["-party"]  = { "who fights next: heroes|muscle|nils|random|<class>", function(rest)
      local name = ((rest or "heroes"):match("^%s*(%a+)") or "heroes"):lower()
      DND.presetParty = name
      DND.Data.newParty()
      local roster = DND.Data.partyRoster(name)
      local bits = {}
      for _, r in ipairs(roster) do
        bits[#bits + 1] = type(r) == "string" and r or (r.class .. " " .. r.name .. " L" .. r.level)
      end
      DND.logf("Next fight: %s. Nothing carries over from the last one.",
        table.concat(bits, ", "))
      DND.logf("(random rolls four level 1 characters — that is the party the "
        .. "XP ladder was written for.)")
    end },
  ["-xp"]     = { "award XP now: -xp 500 (split across the party)", function(rest)
      local n = tonumber((rest or ""):match("%-?%d+"))
      if not n then
        DND.logf("usage: -xp 500   (levels land immediately; see -levelup)")
        return
      end
      DND.Data.grantXp(n)
    end },
  ["-levelup"] = { "print the sheets: levels, XP owed, what the next level gives",
    function()
      DND.logf(DND.Data.progressLine())
      for _, c in ipairs(DND.Data.party()) do
        local plan = DND.Data.levelUpPlan(c, DND.Data.MAX_LEVEL)
        if c.xpNext then
          DND.logf("  %s: %d/%d xp for level %d — next: %s", c.name,
            c.xpEarned or 0, c.xpNext, (c.level or 1) + 1,
            plan[1] and plan[1].text or "nothing")
        else
          DND.logf("  %s: level %d, %d xp banked, and level %d is the cap of "
            .. "this table (Data.MAX_LEVEL)", c.name, c.level or 1,
            c.xpEarned or 0, DND.Data.MAX_LEVEL + 1)
        end
      end
    end },
  ["-rest"]   = { "rest <short|long> [hours] — hit dice and slots, 5e maths", function(rest)
      local kind = (rest or ""):match("^(%a+)")
      local hours = tonumber((rest or ""):match("(%d+)")) or 1
      if kind and kind:lower():sub(1, 4) == "long" then
        DND.Data.longRest()
      else
        DND.Data.shortRest(hours)
      end
    end },
  ["-progress"] = { "the delve ledger: who is standing, what the run is worth",
    function() DND.logf(DND.Data.progressLine()) end },
  ["-help"]   = { "list commands", function()
      local names = {}
      for k in pairs(Input.commands) do names[#names + 1] = k end
      table.sort(names)
      DND.logf("DM commands: " .. table.concat(names, "  "))
    end },
}

--- Chat is the DM console. `rest` may arrive with or without the leading dash:
--- the real trigger hands us the whole string ("\-roll 2d6") while tools and
--- tests pass the bare command, and silently failing on one of those two is a
--- miserable bug to chase at midnight.
function Input.chat(rest)
  rest = (rest or "")
  local bare = rest:gsub("^%s+", ""):gsub("^%-", "")
  local cmd, arg = bare:match("^(%S+)%s*(.*)$")
  if not cmd then return false end
  local entry = Input.commands["-" .. cmd] or Input.commands[cmd]
  if not entry then return false end
  entry[2](arg or "")
  return true
end

---------------------------------------------------------------------- binding
--- Register everything. Safe to call twice.
function Input.bind()
  if bound.done then return end
  bound.done = true
  local trig = CreateTrigger()
  local list = {
    -- movement + core
    "OSKEY_W", "OSKEY_A", "OSKEY_S", "OSKEY_D", "OSKEY_X", "OSKEY_Q", "OSKEY_E",
    "OSKEY_R", "OSKEY_T", "OSKEY_Y", "OSKEY_G", "OSKEY_F", "OSKEY_Z",
    "OSKEY_UP", "OSKEY_DOWN", "OSKEY_LEFT", "OSKEY_RIGHT",
    "OSKEY_SPACE", "OSKEY_ENTER", "OSKEY_ESCAPE", "OSKEY_TAB", "OSKEY_BACK_SPACE",
    -- action / target digits
    "OSKEY_1", "OSKEY_2", "OSKEY_3", "OSKEY_4", "OSKEY_5",
    "OSKEY_6", "OSKEY_7", "OSKEY_8", "OSKEY_9", "OSKEY_0",
    -- spells and traits
    "OSKEY_F1", "OSKEY_F2", "OSKEY_F3", "OSKEY_F4", "OSKEY_F5", "OSKEY_F6",
    "OSKEY_F7", "OSKEY_F8",
  }
  Input.keys = {}
  for _, name in ipairs(list) do Input.keys[name] = true end
  for player = 0, bj_MAX_PLAYERS - 1 do
    local p = Player(player)
    for _, key in ipairs(list) do
      if _G[key] then
        BlzTriggerRegisterPlayerKeyEvent(trig, p, _G[key], 0, false)
        Input.keys[_G[key]] = true
      end
    end
  end
  TriggerAddAction(trig, function()
    local k = BlzGetTriggerPlayerKey()
    if k then Input.press(Input.keyName(k), BlzGetTriggerPlayerMetaKey()) end
  end)

  -- world clicks
  local click = CreateTrigger()
  for player = 0, bj_MAX_PLAYERS - 1 do
    TriggerRegisterPlayerEvent(click, Player(player), EVENT_PLAYER_END_CINEMATIC)
    w3.safe("TriggerRegisterPlayerEvent", click, Player(player),
      ConvertPlayerEvent(306))          -- EVENT_PLAYER_MOUSE_UP
  end
  TriggerAddAction(click, function() Input.worldClick(GetTriggerPlayer()) end)

  -- chat
  local chat = CreateTrigger()
  for player = 0, bj_MAX_PLAYERS - 1 do
    TriggerRegisterPlayerChatEvent(chat, Player(player), "-", true)
  end
  TriggerAddAction(chat, function()
    local msg = GetEventPlayerChatString() or ""
    if not Input.chat(msg:sub(2)) and msg:sub(1, 1) == "-" then
      DND.logf("Unknown command '%s'. Type -help.", msg:match("^%S+"))
    end
  end)
  bound.trig = trig
end

--- Reverse-map an oskeytype back to our names. WC3 gives no name getter, so we
--- build the table by stringifying the constant (works via the default tostring
--- of a handle) and fall back to a numeric comparison.
function Input.keyName(k)
  if bound.names then return bound.names[k] or tostring(k) end
  local names = {}
  for name in pairs(Input.keys) do
    if type(name) == "string" and _G[name] then names[_G[name]] = name end
  end
  bound.names = names
  return names[k] or tostring(k)
end

return Input
