--[[ =========================================================================
  tests/mock_wc3.lua — a small, honest WC3 for headless tests.

  Not an emulation: only what the engine touches, implemented just enough that
  the rules have real consequences. Pausing actually freezes, HP actually
  drops, positions actually move, GetRandomInt is a seeded LCG so every fight
  is reproducible down to the last die face.

  Anything the engine calls that is NOT in here raises immediately — which is
  exactly the failure we want: it means the map would hit a missing native.
========================================================================== ]]
local M = {}
DND = DND or {}
DND.testMode = true
DND.logLines = DND.logLines or {}

local units = {}
local nextHandle = 1000
local pausedLog = {}
local events = {}          -- { [n] = { unit = u, event = id } }
local groupPool = {}
local enumUnit = nil
local enumGuard = 0
local rectPool = {}

---------------------------------------------------------------------- rng
local seed = 12345
function M.reseed(s) seed = s or 12345 end
function GetRandomInt(low, high)
  if high < low then low, high = high, low end
  -- Park-Miller style LCG in pure arithmetic (no bit ops: WC3's Lua is 5.1)
  seed = (seed * 48271) % 2147483647
  local span = high - low + 1
  local base = seed % 2147483647
  return low + (base % span)
end
function GetRandomReal(low, high)
  return low + (high - low) * (GetRandomInt(0, 1000000) / 1000000)
end

---------------------------------------------------------------------- units
function CreateUnit(owner, typeId, x, y, face)
  nextHandle = nextHandle + 1
  local u = {
    __unit = true, id = nextHandle, owner = owner or 0, type = typeId,
    x = x, y = y, face = face or 270, hp = 100, hpMax = 100, mana = 0, manaMax = 0,
    speed = 270, armor = 0, name = "unit", alive = true, paused = false,
    pathing = true, weaponOn = { false, false }, abilities = {}, levels = {},
    scale = 1, acquire = 0,
  }
  units[u.id] = u
  return u
end
function RemoveUnit(u) if u then u.alive = false units[u.id] = nil end end
function KillUnit(u) if u then u.hp = 0 u.alive = false end end

local function must(u, who)
  if type(u) ~= "table" or not u.__unit then
    error("bad unit handle in " .. tostring(who), 2)
  end
  return u
end

function GetUnitX(u) return must(u, "GetUnitX").x end
function GetUnitY(u) return must(u, "GetUnitY").y end
function SetUnitX(u, v) must(u, "SetUnitX").x = v end
function SetUnitY(u, v) must(u, "SetUnitY").y = v end
function SetUnitFacing(u, a) must(u, "SetUnitFacing").face = a end
function GetUnitTypeId(u) return must(u, "GetUnitTypeId").type end
function BlzGetUnitMaxHP(u) return must(u, "BlzGetUnitMaxHP").hpMax end
function BlzGetUnitMaxMana(u) return 0 end
function SetUnitMoveSpeed(u, v) must(u, "SetUnitMoveSpeed").speed = v end
function SetUnitScale(u, a, b, c) must(u, "SetUnitScale").scale = a end
function SetUnitVertexColor(u, r, g, bl, al) return true end
function SetUnitPathing(u, v) must(u, "SetUnitPathing").pathing = v and true or false end
function GetUnitName(u) return must(u, "GetUnitName").name end
function BlzSetUnitName(u, n) must(u, "BlzSetUnitName").name = n end
function BlzSetUnitArmor(u, a) must(u, "BlzSetUnitArmor").armor = a end
function BlzGetUnitArmor(u) return must(u, "BlzGetUnitArmor").armor end
function SetUnitAcquireRange(u, r) must(u, "SetUnitAcquireRange").acquire = r end
function GetUnitAcquireRange(u) return must(u, "GetUnitAcquireRange").acquire end
function BlzGetUnitIntegerField(u, f) return must(u, "BlzGetUnitIntegerField")["f" .. tostring(f)] or 0 end
function SetUnitAnimation(u, a) u.__anim = a end
function SelectUnitForSingleUser(u) end
function ClearSelection() end
function GetLocalPlayer() return 0 end
function GetOwningPlayer(u) return must(u, "GetOwningPlayer").owner end
function IsUnitEnemy(u, p) return u.owner ~= p end
function IsUnitAlly(u, p) return u.owner == p end
function IsUnitVisible(u, p) return true end
function GetPlayerId(p) return p or 0 end
function Player(i) return i end

local STATE = { [0] = "hp", [1] = "hpMax", [2] = "mana", [3] = "manaMax" }
function UNIT_STATE_LIFE() return 0 end
function UNIT_STATE_MAX_LIFE() return 1 end
-- WC3's constants are handles; the engine passes them straight through, so the
-- mock keys off their identity via a tiny lookup built at load time.
UNIT_STATE_LIFE, UNIT_STATE_MAX_LIFE = 0, 1
function ConvertUnitState(i) return i end

function GetUnitState(u, s)
  u = must(u, "GetUnitState")
  if s == UNIT_STATE_LIFE then return u.hp end
  if s == UNIT_STATE_MAX_LIFE then return u.hpMax end
  return 0
end
function SetUnitState(u, s, v)
  u = must(u, "SetUnitState")
  if s == UNIT_STATE_LIFE then
    u.hp = v
    if v <= 0 and u.alive then
      u.alive = false
      events[#events + 1] = { kind = "death", unit = u }
    end
  elseif s == UNIT_STATE_MAX_LIFE then
    u.hpMax = v
    if u.hp > v then u.hp = v end
  end
end
function GetUnitLifePercent(u) return 100 * u.hp / math.max(1, u.hpMax) end

---------------------------------------------------------------------- pause
function PauseUnit(u, flag)
  must(u, "PauseUnit")
  u.paused = flag and true or false
  pausedLog[#pausedLog + 1] = { id = u.id, paused = u.paused }
end
function BlzPauseUnitEx(u, flag) PauseUnit(u, flag) end
function BlzSetUnitWeaponBooleanField(u, field, idx, v)
  must(u, "BlzSetUnitWeaponBooleanField")
  u.weaponOn[idx + 1] = v and true or false
  return true
end
function BlzGetUnitWeaponBooleanField(u, field, idx) return u.weaponOn[idx + 1] end

---------------------------------------------------------------------- abilities
function UnitAddAbility(u, code) u.abilities[code] = true; return true end
function UnitRemoveAbility(u, code) u.abilities[code] = nil; return true end
function GetUnitAbilityLevel(u, code) return u.levels[code] or 0 end
function SetUnitAbilityLevel(u, code, lvl) u.levels[code] = lvl; return true end
function BlzUnitDisableAbility(u, code, flag, hide) return true end
function BlzUnitHideAbility(u, code, flag) return true end
function BlzSetUnitAbilityCooldown(u, code, lvl, cd) return true end
function BlzGetUnitAbilityCooldownRemaining(u, code) return 0 end

---------------------------------------------------------------------- geometry
function SquareRoot(v) return math.sqrt(v) end
function DistanceBetweenPoints(x1, y1, x2, y2)
  local dx, dy = x1 - x2, y1 - y2
  return math.sqrt(dx * dx + dy * dy)
end
function RMinBJ(a, b) return math.min(a, b) end
function Deg2RadBJ(d) return math.rad(d) end
function Rad2DegBJ(r) return math.deg(r) end
function SubBJ(a, b) return a - b end

---------------------------------------------------------------------- groups
function CreateGroup() local g = { __group = true, set = {} } return g end
function DestroyGroup(g) if g then g.set = {} end end
function GroupClear(g) g.set = {} end
function GroupAddUnit(g, u) g.set[u.id] = u; return true end
function GroupRemoveUnit(g, u) g.set[u.id] = nil; return true end
function GroupSize(g) local n = 0 for _ in pairs(g.set) do n = n + 1 end return n end
function GetEnumUnit() return enumUnit end
function ForGroup(g, fn)
  if enumGuard > 8 then return end
  enumGuard = enumGuard + 1
  local snapshot = {}
  for _, u in pairs(g.set) do snapshot[#snapshot + 1] = u end
  for _, u in ipairs(snapshot) do enumUnit = u fn() end
  enumUnit = nil
  enumGuard = enumGuard - 1
end
function Rect(a, b, c, d) return { x1 = math.min(a, c), x2 = math.max(a, c),
                                   y1 = math.min(b, d), y2 = math.max(b, d) } end
function GroupEnumUnitsInRect(g, r, filter)
  for _, u in pairs(units) do
    if u.alive and u.x >= r.x1 and u.x <= r.x2 and u.y >= r.y1 and u.y <= r.y2 then
      g.set[u.id] = u
    end
  end
end
function BlzEnumObjectsMultiple(g, code) return nil end

---------------------------------------------------------------------- triggers
function CreateTrigger() return { __trigger = true, actions = {}, events = {} } end
function DestroyTrigger(t) if t then t.actions = {} end end
function TriggerAddAction(t, fn) t.actions[#t.actions + 1] = fn end
function TriggerRegisterPlayerUnitEvent(t, p, ev, filter) return true end
function TriggerRegisterAnyUnitEventBJ(t, ev) return true end
function BlzTriggerRegisterPlayerKeyEvent(t, p, key, meta, down) return true end
function BlzTriggerRegisterPlayerSyncEvent(t, p, prefix, fromServer) return true end
function BlzTriggerRegisterFrameEvent(t, f, ev) return true end
function TriggerRegisterPlayerChatEvent(t, p, prefix, exact) return true end
function TriggerRegisterPlayerEvent(t, p, ev) return true end
function TriggerExecute(t) for _, a in ipairs(t.actions) do a() end end
function ConvertPlayerUnitEvent(i) return i end
function ConvertPlayerEvent(i) return i end
function ConvertFrameEventType(i) return i end
function ConvertOsKeyType(i) return i end
local keyCounter = 0
local function oskey(name)
  -- unique numeric-ish handle per key name, mirroring how WC3 hands them out
  keyCounter = keyCounter + 1
  return { __oskey = name, n = keyCounter }
end
function BlzGetTriggerPlayerKey() return DND._mockKey end
function BlzGetTriggerPlayerMetaKey() return 0 end
function BlzGetTriggerPlayerIsKeyDown() return false end
function BlzGetTriggerPlayerMouseX() return DND._mockMouse and DND._mockMouse.x or 0 end
function BlzGetTriggerPlayerMouseY() return DND._mockMouse and DND._mockMouse.y or 0 end
function GetEventPlayerChatString() return DND._mockChat end
function GetTriggerUnit() return DND._trigUnit end
function GetTriggerPlayer() return DND._trigPlayer or 0 end
function GetIssuedOrderId() return DND._order or 0 end
function GetOrderPointX() return DND._orderPoint and DND._orderPoint.x or 0 end
function GetOrderPointY() return DND._orderPoint and DND._orderPoint.y or 0 end
function GetOrderTarget() return DND._orderTarget end
function GetSpellAbility() return DND._spellAbility end
function GetSpellAbilityId() return DND._spellAbility end
function GetSpellTargetUnit() return DND._spellTarget end

---------------------------------------------------------------------- orders
function IssuePointOrderById(u, id, x, y)
  must(u, "IssuePointOrderById")
  if u.paused then return false end
  DND.ordersIssued = (DND.ordersIssued or 0) + 1
  if id == 0x00000001 then u.x, u.y = x, y end
  return true
end
function IssueTargetOrderById(u, id, target)
  must(u, "IssueTargetOrderById")
  if u.paused then return false end
  DND.ordersIssued = (DND.ordersIssued or 0) + 1
  if id == 0x00000002 then
    events[#events + 1] = { kind = "attacked", unit = u, target = target }
  end
  return true
end
function IssueImmediateOrderById(u, id) return not u.paused end
function IssuePointOrder(u, o, x, y) return IssuePointOrderById(u, 0x00000001, x, y) end
function IssueTargetOrder(u, o, t) return IssueTargetOrderById(u, 0x00000002, t) end
function IssuePointOrderLoc(u, o, loc) return true end
function BlzIssueQuickCast(c, q) return true end

---------------------------------------------------------------------- misc natives
function CreateTimer() return { __timer = true } end
function DestroyTimer(t) end
function TimerStart(t, period, periodic, fn)
  if not periodic then fn() end
  return true
end
function TriggerSleepAction(s) end
function TriggerWaitOnSleeps() end
function DisableUserControl(b) DND.userControl = b end
function EnableUserControl(b) DND.userControl = b end
function PauseGame(b) DND.gamePaused = b end
function ShowInterface(b, f) end
function BJDebugMsg(s) DND.logLines[#DND.logLines + 1] = "DEBUG " .. tostring(s) end
function DisplayTextToPlayer(p, x, y, s) end
function DisplayTimedTextToPlayer(p, x, y, dur, s) end
function CreateTextTag() return { __tag = true } end
function DestroyTextTag(t) end
function SetTextTagText(t, s, h) t.text = s end
function SetTextTagPos(t, x, y, z) end
function SetTextTagPosUnit(t, u, z) end
function SetTextTagColor(t, r, g, b, a) end
function SetTextTagVelocity(t, x, y) end
function SetTextTagLifespan(t, v) end
function SetTextTagFadepoint(t, v) end
function AddSpecialEffect(p, x, y) return { __effect = true } end
function AddSpecialEffectTarget(p, u, a) return { __effect = true } end
function DestroyEffect(e) end
function PanCameraToTimed(x, y, d) end
function SetCameraField(f, v, d) end
function ConvertCameraField(i) return i end
function BlzLoadTOCFile(p) return true end
function BlzCreateFrameByType(typ, name, parent, inherits, ctx)
  return { __frame = name, text = "", visible = true, children = {} }
end
function BlzCreateFrame(name, owner, prio, ctx) return { __frame = name } end
function BlzGetOriginFrame(t, i) return { __frame = "origin" .. i } end
function BlzGetFrameByName(n, i) return { __frame = n .. i } end
function BlzFrameSetText(f, t) if f then f.text = t end end
function BlzFrameSetAbsPoint(f, p, x, y) end
function BlzFrameSetPoint(...) end
function BlzFrameSetAllPoints(a, b) end
function BlzFrameSetSize(f, w, h) end
function BlzFrameSetVisible(f, v) if f then f.visible = v end end
function BlzFrameSetEnable(f, v) end
function BlzFrameSetTexture(f, t, p, m) end
function BlzFrameSetScale(f, s) end
function BlzFrameSetAlpha(f, a) end
function BlzFrameSetModel(f, m, a) end
function BlzFrameClearAllPoints(f) end
function BlzFrameSetTooltip(f, t) end
function BlzFrameGetValue(f) return 0 end
function BlzFrameSetValue(f, v) end
function BlzFrameSetMinMaxValue(f, a, b) end
function GetHandleId(h)
  if type(h) == "table" then return h.id or h.uid or (function()
      h.uid = (h.uid or 0) + 100000
      return h.uid
    end)() end
  return tonumber(h) or 0
end
function FourCC(s)
  local n = 0
  for i = 1, #s do n = n * 256 + string.byte(s, i) end
  return n
end
function GetUnitType() return 0 end

---------------------------------------------------------------------- mock-only
function M.allUnits() return units end
function M.count() local n = 0 for _ in pairs(units) do n = n + 1 end return n end
function M.pausedLog() return pausedLog end
function M.clearLog() pausedLog = {} end
function M.events() local e = events events = {} return e end
function M.unit(id) return units[id] end
function M.lastEvent() return events[#events] end
function M.ordersIssued() return DND.ordersIssued or 0 end
function M.isFrozen(u)
  return u.paused == true and u.pathing == false
     and u.weaponOn[1] == false and u.weaponOn[2] == false
end
function M.reset()
  units = {}
  nextHandle = 1000
  pausedLog = {}
  events = {}
  DND.ordersIssued = 0
  M.reseed()
end

MOCK = M
return M
