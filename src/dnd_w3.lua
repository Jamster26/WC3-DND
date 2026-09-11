--[[ =========================================================================
  dnd_w3.lua — the only file in the engine that talks to WC3.

  Everything above this layer is pure Lua, which is what makes the whole
  combat system testable: tools/harness.py swaps in mock natives with the same
  names and a full fight runs headless.

  Natives chosen here are deliberately limited to the ones verified present in
  common.j for 1.31+ (see tools/check.py --natives). Anything optional goes
  through w3.safe() so a missing native logs once and degrades instead of
  taking the map down.
========================================================================== ]]
DND = DND or {}
DND.w3 = {}
local w3 = DND.w3
local C = DND.CONST

w3.verbose = false
local missing = {}

--- Call a native if the host provides it; otherwise warn once and return nil.
function w3.safe(name, ...)
  local f = _G[name]
  if type(f) ~= "function" then
    if not missing[name] then
      missing[name] = true
      w3.log("!! native missing: " .. name .. " (feature disabled)")
    end
    return nil
  end
  return f(...)
end

function w3.has(name) return type(_G[name]) == "function" end

---------------------------------------------------------------------- ids
local handleIds = {}
local nextId = 1
function w3.id(handle)
  if handle == nil then return 0 end
  local cached = handleIds[handle]
  if cached then return cached end
  local i
  if w3.has("GetHandleId") then i = GetHandleId(handle) else
    nextId = nextId + 1; i = nextId
  end
  handleIds[handle] = i
  return i
end
function w3.resetIds() nextId = 1 handleIds = {} end

--- Four-char code from a string, for the rare places we need one at runtime.
function w3.cc(s)
  local n = 0
  for i = 1, #s do n = n * 256 + string.byte(s, i) end
  return n
end

---------------------------------------------------------------------- geometry
function w3.x(u) return GetUnitX(u) end
function w3.y(u) return GetUnitY(u) end
function w3.dist(u1, u2)
  local dx, dy = GetUnitX(u1) - GetUnitX(u2), GetUnitY(u1) - GetUnitY(u2)
  return SquareRoot(dx * dx + dy * dy)
end
function w3.distPts(x1, y1, x2, y2)
  local dx, dy = x1 - x2, y1 - y2
  return SquareRoot(dx * dx + dy * dy)
end
--- Snap to the 5 ft grid so battles read like a printed battle map.
function w3.snap(x, y)
  local g = C.FIVE_FEET
  return C.round(x / g) * g, C.round(y / g) * g
end
function w3.moveTo(u, x, y, faceTarget)
  if DND.config and DND.config.gridSnap then x, y = w3.snap(x, y) end
  SetUnitX(u, x); SetUnitY(u, y)
  if faceTarget then
    SetUnitFacing(u, w3.angleTo(x, y, GetUnitX(faceTarget), GetUnitY(faceTarget)))
  end
end

--- BJ has no angle helper with this name; compute it from the vector instead.
function w3.angleTo(x1, y1, x2, y2)
  local rad = math.atan2(y2 - y1, x2 - x1)
  return rad * 180 / math.pi
end

---------------------------------------------------------------------- freeze
-- The heart of "turn based": a paused unit accepts no order, takes no path,
-- and attacks nothing. Everyone sleeps until the initiative says otherwise.
function w3.freeze(u)
  if not u then return end
  PauseUnit(u, true)
  SetUnitPathing(u, false)
  -- kill WC3's own damage even if something unpauses it (see README §Why)
  BlzSetUnitWeaponBooleanField(u, UNIT_WEAPON_BF_ATTACKS_ENABLED, 0, false)
  BlzSetUnitWeaponBooleanField(u, UNIT_WEAPON_BF_ATTACKS_ENABLED, 1, false)
end

function w3.unfreeze(u, allowAttacks)
  if not u then return end
  PauseUnit(u, false)
  SetUnitPathing(u, true)
  BlzSetUnitWeaponBooleanField(u, UNIT_WEAPON_BF_ATTACKS_ENABLED, 0, not not allowAttacks)
  BlzSetUnitWeaponBooleanField(u, UNIT_WEAPON_BF_ATTACKS_ENABLED, 1, not not allowAttacks)
end

--- Stop WC3's real-time attack engine for a unit; we deal all damage in Lua.
function w3.disableRealDamage(u, off)
  local v = not off
  BlzSetUnitWeaponBooleanField(u, UNIT_WEAPON_BF_ATTACKS_ENABLED, 0, v)
  BlzSetUnitWeaponBooleanField(u, UNIT_WEAPON_BF_ATTACKS_ENABLED, 1, v)
end

---------------------------------------------------------------------- life
function w3.hp(u)      return GetUnitState(u, UNIT_STATE_LIFE) end
function w3.maxHp(u)   return BlzGetUnitMaxHP(u) end
function w3.setHp(u, v) SetUnitState(u, UNIT_STATE_LIFE, C.clamp(v, 0, w3.maxHp(u))) end
function w3.alive(u)   return u ~= nil and GetUnitState(u, UNIT_STATE_LIFE) > -0.5 end

---------------------------------------------------------------------- log
function w3.log(msg)
  if DND.testMode then
    table.insert(DND.logLines, msg)
    if DND.testVerbose then print("[wc3] " .. msg) end
    return
  end
  BJDebugMsg(msg)
end

--- Floating numbers above a unit: the entire reason this feels like D&D.
function w3.textTag(u, text, size, r, g, b, rise)
  if DND.testMode then return nil end
  local t = CreateTextTag()
  SetTextTagText(t, text, size * 1.0e-4)
  SetTextTagPosUnit(t, u, 24)
  SetTextTagVelocity(t, 0, (rise or 18))
  SetTextTagLifespan(t, 1.6)
  SetTextTagFadepoint(t, 1.1)
  SetTextTagColor(t, r or 255, g or 255, b or 255, 255)
  w3.after(2.2, function() if t then DestroyTextTag(t) end end)
  return t
end

---------------------------------------------------------------------- fx
function w3.fxTarget(path, u, attach)
  if DND.testMode or type(path) ~= "string" or path == "" then return nil end
  local e = AddSpecialEffectTarget(path, u, attach or "origin")
  if e then w3.after(2.0, function() DestroyEffect(e) end) end
  return e
end

function w3.playAnim(u, name)
  if w3.has("SetUnitAnimation") then SetUnitAnimation(u, name or "stand") end
end

---------------------------------------------------------------------- timing
w3.timers = {}
local function newTimer(delay, fn)
  if DND.testMode then
    -- immediate execution keeps the state machine synchronous under test
    fn()
    return nil
  end
  local t = CreateTimer()
  table.insert(w3.timers, { t = t, fn = fn })
  TimerStart(t, delay, false, function()
    for i, e in ipairs(w3.timers) do
      if e.t == t then table.remove(w3.timers, i) break end
    end
    DestroyTimer(t)
    fn()
  end)
  return t
end
--- Defer by `delay` seconds. In the headless harness these fire at once so a
--- whole encounter resolves without wall-clock waiting.
function w3.after(delay, fn) return newTimer(delay, fn) end
function w3.cancelAll()
  for _, e in ipairs(w3.timers) do if e.t then DestroyTimer(e.t) end end
  w3.timers = {}
end

---------------------------------------------------------------------- camera
function w3.lookAt(u, quick)
  if DND.testMode then return end
  local x, y = GetUnitX(u), GetUnitY(u)
  w3.safe("SetCameraField", CAMERA_FIELD_TARGET_DISTANCE, 1180, 0)
  w3.safe("SetCameraField", CAMERA_FIELD_ANGLE_OF_ATTACK, 62, 0)
  PanCameraToTimed(x, y, quick and 0.35 or 0)
end

---------------------------------------------------------------------- misc
function w3.rand(a, b) return GetRandomInt(a, b) end
function w3.name(u) return GetUnitName(u) or "?" end
function w3.typeId(u) return GetUnitTypeId(u) end

return w3
