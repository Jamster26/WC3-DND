--[[ =========================================================================
  war3map.lua — ENTRY POINT.  This is the only file WC3 executes.

  Build it with  python3 tools/build.py  (splices src/*.lua in dependency order,
  syntax-checks the result, and writes dist/war3map.lua). The modules stay
  separate because that is what keeps them testable; the game sees one file
  because that is all it gets.

  Nothing here needs the Object Editor. The demo fights run on stock WC3 units
  whose D&D numbers live entirely in dnd_data.lua, so you can paste this file
  into a blank melee map and type -start ambush.
========================================================================== ]]
--<<BUILD:BEGIN>>--  (build.py splices the modules above this line)

---------------------------------------------------------------------- config
-- dnd_const bootstraps DND.config with its defaults; these are the switches you
-- are most likely to want on your first run.
DND.config.useVanillaModels = true   -- spawn stock units as the actors (no data needed)
DND.config.cover = false             -- needs props on the map; turn on with dnd_data.js
DND.config.autoStart = false         -- true: the demo fight begins on load
DND.config.autoEndTurn = true        -- end the turn when nothing is left to do
DND.config.aiEnabled = true          -- false: invaders wait for -ai (hot-seat, inspect)

--- Where the demo fight happens, taken from the map's own bounds so it works on
--- any terrain without editing a coordinate.
local function anchors()
  local C = DND.CONST
  local cx, cy = 0, 0
  -- The editor always emits a playable-area region; the Blizzard.j extents are
  -- the fallback for a map assembled by hand.
  local r = _G.gg_rct_Playable_Area
  if r then
    cx = (GetRectMinX(r) + GetRectMaxX(r)) / 2
    cy = (GetRectMinY(r) + GetRectMaxY(r)) / 2
  elseif _G.bj_MAP_EXTENT_LEFT then
    cx = (bj_MAP_EXTENT_LEFT + bj_MAP_EXTENT_RIGHT) / 2
    cy = (bj_MAP_EXTENT_BOTTOM + bj_MAP_EXTENT_TOP) / 2
  end
  local gap = C.ft(45)          -- 45 ft: one full charge plus a little, so the
  return { x = cx - gap, y = cy }, { x = cx + gap, y = cy }   -- first round swings
end

--- The honest limit of this design. WC3's F10 menu pause is single-player only,
--- so the engine cannot pause the world and instead pauses *units*: nobody can
--- act out of turn, but a player who opens the menu still freezes the frame
--- while their own turn is open, which is a free "think forever" button and, in
--- a networked game, simply not allowed. Detect it and say so rather than
--- quietly letting a second human break the initiative order.
local function guardSoloOnly()
  local humans = 0
  for i = 0, 15 do
    if GetPlayerSlotState(Player(i)) == PLAYER_SLOT_STATE_PLAYING
       and GetPlayerController(Player(i)) == MAP_CONTROL_USER then
      humans = humans + 1
    end
  end
  DND.config.humanPlayers = humans
  if humans > 1 then
    DND.logf("|cffff8866WARNING|r: %d human players. Initiative order and the "
      .. "menu pause are single-player ideas. Either make the others Neutral "
      .. "Hostile/CPU, or set DND.config.allowMultiHuman = true if you want to "
      .. "drive one side with hot-seat keys.", humans)
  end
  return humans <= 1 or DND.config.allowMultiHuman
end

local function banner()
  DND.logf("|cffffe066D&D in Warcraft III|r — turn-based, d20, six seconds a round.")
  DND.logf("Type |cffffcc00-start ambush|r to fight, |cffffcc00-delve 1|r to run a "
    .. "dungeon for XP, |cffffcc00-party random|r to roll four level 1 characters.")
  DND.logf("|cffffcc00-help|r lists the DM console.")
  DND.logf("Keys: 1-9 act/target · Tab cycle · W/A/S/D step · Q dash · X disengage · "
    .. "E dodge · R hit die · Y stabilise · F bonus · SPACE end turn · Esc cancel")
end

local function init()
  DND.ui.init()
  DND.Input.bind()
  banner()

  local a, b = anchors()
  DND.entryAnchor, DND.entryAnchor2 = a, b
  guardSoloOnly()

  -- Win / lose hooks. A real map would start a cinematic or hand out treasure;
  -- the engine only tells you the fight is over and what it was worth.
  DND.onVictory = function(xp)
    local rec = DND.Combat.state.encounter
    if rec and rec.restAfterFight == false then
      -- A delve room. The XP has already landed (that is Data.afterVictory, run
      -- by the engine one line earlier) and nothing else comes back for free:
      -- hit dice and spell slots are the resource the run is measured in.
      DND.logf("Room cleared. Nothing rests for you here: -rest short, -rest long, "
        .. "or walk straight into the next one and find out what you had left.")
      DND.logf(DND.Data.progressLine())
      return
    end
    DND.logf("Victory. %d XP banked. Rest for hit dice and slots, or go again.", xp or 0)
    for _, cbt in ipairs(DND.Combatant.all()) do
      if cbt.side == DND.CONST.SIDE.PARTY and not cbt.removed then
        cbt.hitDice = cbt.level
        for lvl = 1, #cbt.slotMax do cbt.slots[lvl] = cbt.slotMax[lvl] end
      end
    end
  end
  DND.onDefeat = function()
    DND.logf("The party falls. Reload, and try a different line.")
    DND.logf(DND.Data.progressLine())
  end

  if DND.config.autoStart then
    DND.Data.run("ambush", a, b)
  else
    DND.ui.setHint("Type -start ambush to begin.")
  end
end

-- One tick after load: units and regions exist, and frames accept input.
TimerStart(CreateTimer(), 0.1, false, function()
  DestroyTimer(GetExpiredTimer())
  init()
end)
--<<BUILD:END>>--
