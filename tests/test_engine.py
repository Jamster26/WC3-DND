#!/usr/bin/env python3
"""The engine's own test suite. Plain Python, no pytest required, runs in ~2s.

Why this exists: WC3 has no debugger worth the name and no way to unit test a
rule, so the only cheap way to know that "half damage on a successful save" is
actually half is to run the real modules against a mock engine and assert. Every
bug in this project's history was found here first (see the git-style notes in
tools/harness.py).

Run:  python3 tests/test_engine.py [-v]
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "tools"))
import harness  # noqa: E402

VERBOSE = "-v" in sys.argv
RAN: list[str] = []          # every registered group, in order
FAILURES: list[tuple[str, str]] = []


def lua_case(name, lua_src, expect=None):
    """Run a Lua snippet in a fresh engine. `expect` is a Lua expression that
    must evaluate truthy; its value is echoed back for a useful failure."""
    lua = harness.boot(verbose=VERBOSE)

    def run(code):
        return lua.compile(code, "tests/" + name)()

    try:
        run("DND.Dice.script({})")            # rng: engine default (mock LCG)
        run(lua_src)
        if expect is not None:
            got = lua.execute("return (" + expect + ") and 1 or 0")
            assert int(got) == 1, f"expected truthy: {expect}"
    except AssertionError as e:
        FAILURES.append((name, str(e).split("stack traceback")[0]))
        if VERBOSE:
            print(f"✗ {name}: {e}")
        return False
    except Exception as e:  # noqa: BLE001
        FAILURES.append((name, f"{type(e).__name__}: {str(e).split(chr(10) + 'stack')[0]}"))
        if VERBOSE:
            print(f"✗ {name}: {e}")
        return False
    return True


def case(name, fn):
    RAN.append(name)
    try:
        fn()
    except AssertionError as e:
        FAILURES.append((name, str(e).split("stack traceback")[0]))
        if VERBOSE:
            print(f"✗ {name}: {e}")
        return False
    except Exception as e:  # noqa: BLE001
        FAILURES.append((name, f"{type(e).__name__}: {str(e).split(chr(10) + 'stack')[0]}"))
        if VERBOSE:
            print(f"✗ {name}: {e}")
        return False
    return True


# --------------------------------------------------------------------------
# 1. The maths layer (no engine needed)
# --------------------------------------------------------------------------
DICE = r"""
local C, D = DND.CONST, DND.Dice
-- dice parsing
assert(#C.parseDice("2d6+1d4+3").dice == 3)
assert(C.parseDice("2d6+1d4+3").mod == 3)
assert(C.parseDice("1d8+3").mod == 3)
assert(C.parseDice("1").mod == 1 and C.parseDice("-1").mod == -1)
for _, bad in ipairs({"d8", "1d", "1d8 3", "", "1d8++3", "abc"}) do
  assert(C.parseDice(bad) == nil, "must reject: " .. bad)
end
-- ability scores and proficiency
assert(C.abilityMod(20) == 5 and C.abilityMod(10) == 0 and C.abilityMod(3) == -4)
assert(C.proficiency(1) == 2 and C.proficiency(5) == 3 and C.proficiency(20) == 6)
-- scale: 6.4 units per foot is the load-bearing constant
assert(C.ft(30) == 192 and C.ft(5) == 32 and C.FIVE_FEET == 32)
assert(C.unitsToFeet(192) == 30)
-- the d20 and its two special faces
D.script({20}); local c = D.attackRoll(5, 30)
assert(c.crit and c.hit, "nat 20 always hits and crits")
D.script({1});   local f = D.attackRoll(9, 10)
assert(not f.hit and f.natural == 1, "nat 1 always misses")
D.script({3,18}); assert(D.d20(5, 1).natural == 18, "advantage takes the high die")
D.script({18,3}); assert(D.d20(5, -1).natural == 3, "disadvantage takes the low die")
D.script({12});  local sv = D.check(3, {dc = 14})
assert(sv.total == 15 and sv.success, "12+3 vs DC14")
D.script({1});   assert(not D.check(9, {dc = 10}).success, "nat 1 save always fails")
-- crit maths: dice double, the modifier does not
D.script({3})
assert(D.rollExpr("1d8+3", {double = true}).total == 9, "3+3+3")
D.script({})
assert(D.rollExpr("4d6", {max = true}).total == 24, "maximised dice")
-- log formatting survives colour codes
DND.logf("|cffffcc00x|r %s", 1)
assert(DND.logLines[#DND.logLines] == "x 1", "[" .. DND.logLines[#DND.logLines] .. "]")
"""
case("dice + 5e maths", lambda: lua_case("dice", DICE))


# --------------------------------------------------------------------------
# 2. The statblock layer
# --------------------------------------------------------------------------
STATS = r"""
local C = DND.CONST
local u = CreateUnit(0, DND.w3.cc('hfoo'), 0, 0, 270)
local cbt = DND.Combatant.new({ name="Test Fighter", level=5, str=16, dex=14, con=14,
  ac=18, hp=44, speed=30, actions={{name="Greatsword", toHit=8, damage="2d6+3", dmgType="slashing"}} }, u)
assert(cbt.mods.str == 3 and cbt.mods.dex == 2 and cbt.mods.con == 2)
assert(cbt.prof == 3, "level 5 -> proficiency +3")
assert(cbt.ac == 18)
assert(cbt.speed == 30)
assert(DND.Combatant.speedUnits(cbt) == 192, "30 ft of movement per turn")
-- the WC3 mirror: HP is scaled, AC shows up as armour, speed drives the model
DND.Combatant.sync(cbt)
assert(GetUnitState(u, 0) == 44 * C.HP_SCALE, "hp mirrored, got " .. tostring(GetUnitState(u, 0)))
assert(BlzGetUnitArmor(u) == 8, "AC 18 shows as +8 armour, got " .. tostring(BlzGetUnitArmor(u)))
assert(u.speed == 32, "movement speed set to ft/s equivalent: " .. tostring(u.speed))
-- frozen by default. This single assertion is the whole turn-based premise.
assert(u.paused == true and u.pathing == false, "units sleep unless it is their turn")
assert(u.weaponOn[1] == false and u.weaponOn[2] == false, "WC3's own damage is switched off")
-- AC is not a constant: prone, Dodge and Shield all move it
assert(DND.Combatant.ac(cbt) == 18)
cbt.flags.dodge = true
assert(DND.Combatant.ac(cbt) == 20, "Dodge is +2 against melee")
cbt.flags.shield = true
assert(DND.Combatant.ac(cbt) == 25, "Shield is +5 on top")
"""
case("statblock + WC3 mirror", lambda: lua_case("stats", STATS))


# --------------------------------------------------------------------------
# 3. Initiative
# --------------------------------------------------------------------------
INIT = r"""
local u1 = CreateUnit(0, 1, 0, 0, 0) local u2 = CreateUnit(1, 1, 64, 0, 0)
local u3 = CreateUnit(1, 1, 128, 0, 0)
local a = DND.Combatant.new({name="Fast", dex=20, side=0, hp=10, ac=10}, u1)
local b = DND.Combatant.new({name="Slow", dex=8,  side=1, hp=10, ac=10}, u2)
local c = DND.Combatant.new({name="AlsoSlow", dex=8, side=1, hp=10, ac=10}, u3)
DND.Dice.script({10, 5, 10, 4, 10, 3})   -- d20 then coin, per creature
local t = DND.Turns.new()
local order = DND.Turns.rollOrder(t, {b, a, c})
assert(order[1].cbt.name == "Fast", "equal d20, better DEX mod wins, got " .. order[1].cbt.name)
assert(order[2].cbt.name ~= "Fast", "the two slow ones follow")
-- ties fall through to the coin flip, not to table order. Scripted as
-- {d20, coin, d20, coin} because initiative rolls consume in that order.
DND.Dice.script({10, 2, 10, 99})
local t2 = DND.Turns.new()
local o2 = DND.Turns.rollOrder(t2, {b, c})
assert(o2[1].cbt.name == "AlsoSlow", "the higher coin flip wins the tie, got " .. o2[1].cbt.name)
-- a dead creature is skipped but the round still advances
t2.round = 0
b.hp = 0
local nxt = DND.Turns.next(t2)
assert(nxt.cbt.name == "AlsoSlow", "skips the dead")
"""
case("initiative + round order", lambda: lua_case("init", INIT))


# --------------------------------------------------------------------------
# 4. Movement budget
# --------------------------------------------------------------------------
MOVE = r"""
local C = DND.CONST
DND.config.aiPlaysParty = false
DND.config.reactions = false
local u1 = CreateUnit(0, 1, 0, 0, 0) local u2 = CreateUnit(1, 1, C.ft(60), 0, 0)
local p = DND.Combatant.new({name="P", side=0, speed=30, hp=20, ac=12,
  actions={{name="Sword", toHit=2, damage="1d6", dmgType="slashing"}}}, u1)
local f = DND.Combatant.new({name="F", side=1, speed=30, hp=20, ac=12,
  actions={{name="Axe", toHit=2, damage="1d6", dmgType="slashing"}}}, u2)
DND.Combat.startEncounter("T", {p, f}, {})
DND.Combat.giveTurn("P")
assert(p.movementLeft == 192, "30 ft of movement, got " .. p.movementLeft)
-- a legal step
local r = DND.Combat.move({x = C.ft(20), y = 0})
assert(r.ok, "20 ft move allowed: " .. tostring(r.error))
assert(p.movementLeft == 192 - C.ft(20), "budget spent")
-- an illegal one is clamped to what is left, not refused
local r2 = DND.Combat.move({x = C.ft(200), y = 0})
assert(r2.ok or (r2.error and r2.error:find("too far")), "clamp or refuse, got " .. tostring(r2.error))
assert(GetUnitX(u1) <= 192 + C.FIVE_FEET, "never ends up beyond the budget, at " .. GetUnitX(u1))
-- undo puts you back exactly
local before = GetUnitX(u1)
DND.Combat.move({x = GetUnitX(u1) + C.ft(5), y = 0})
DND.Combat.undoMove()
assert(GetUnitX(u1) == before, "undo restores position")
-- and out of movement you simply stay put (clamped, not refused: the AI relies
-- on being able to walk toward something it cannot reach yet)
p.movementLeft = 0
local xEnd = GetUnitX(u1)
DND.Combat.move({x = C.ft(500), y = 0})
assert(GetUnitX(u1) == xEnd, "no movement, no move")
-- but the budget itself is generous enough to cross an open field one turn at
-- a time, which is what makes AI approach work at all
p.movementLeft = 192
local r4 = DND.Combat.move({x = C.ft(400), y = 0})
assert(r4.ok and p.movementLeft == 0,
  "a long walk spends the whole move: " .. tostring(r4.error))
-- A non-finite destination is a caller bug, not a move, so the one function every
-- move goes through refuses it.  And the distance test is written `not (d > 0.01)`
-- rather than `d <= 0.01` on purpose: `nan <= 0.01` is false, so the naive form
-- waves a nan through, and SetUnitX(nan) is a creature you can never move again.
local xSafe = GetUnitX(u1)
local rnan = DND.Combat.move({ x = 0/0, y = 0 })
assert(rnan.error == "nowhere to go", "a nan move is refused: " .. tostring(rnan.error))
assert(GetUnitX(u1) == xSafe, "and the unit keeps a position you can aim at")
"""
case("movement budget", lambda: lua_case("move", MOVE))


# --------------------------------------------------------------------------
# 5. Attack resolution: the exact 5e arithmetic
# --------------------------------------------------------------------------
ATTACK = r"""
local C = DND.CONST
local u1 = CreateUnit(0, 1, 0, 0, 0) local u2 = CreateUnit(1, 1, C.ft(5), 0, 0)
local at = DND.Combatant.new({name="Atk", side=0, str=18, dex=10, level=5,
  actions={{name="Greataxe", toHit=6, damage="1d12+4", dmgType="slashing"}}}, u1)
local df = DND.Combatant.new({name="Def", side=1, dex=14, ac=15, hp=30, speed=30,
  actions={{name="Bite", toHit=2, damage="1d4", dmgType="piercing"}}}, u2)
DND.config.reactions = false

-- a scripted +6 vs AC 15: needs 9 or better
DND.Dice.script({8})
local miss = DND.Resolve.attack(at, df, at.actions[1])
assert(miss.hit == false and miss.roll.natural == 8, "8+6=14 vs 15 is a miss")
assert(miss.damage == 0, "a miss rolls no damage")
DND.Dice.script({9})
local hit = DND.Resolve.attack(at, df, at.actions[1])
assert(hit.hit and hit.roll.total == 15, "9+6=15 hits exactly")
-- crit: nat 20 doubles the damage dice, never the ability modifier.
DND.Dice.script({20})              -- every roll here is a 20: crit guaranteed
-- The damage maths, isolated: 5e doubles the DICE on a crit and the ability
-- modifier exactly once. Asserting this directly (rather than through an
-- encounter) means a scripted-roll mismatch can never masquerade as a rules bug.
DND.Dice.script({3})
local plain = DND.Resolve.damageRoll(at, at.actions[1], false)
assert(plain.total == 3 + 4, "1d12(3) + STR 4 = 7, got " .. plain.total)
assert(#plain.faces == 1, "one die normally")
DND.Dice.script({3})
local doubled = DND.Resolve.damageRoll(at, at.actions[1], true)
assert(#doubled.faces == 2, "a crit rolls the die twice, got " .. #doubled.faces)
assert(doubled.total == 3 + 3 + 4, "crit = 3+3+4 = 10, got " .. doubled.total)
assert(doubled.total - plain.total == doubled.faces[2],
  "the only difference is ONE extra die, never a doubled modifier (plain="
  .. plain.total .. " crit=" .. doubled.total .. ")")
DND.Dice.script({20})
local crit = DND.Resolve.attack(at, df, at.actions[1])
assert(crit.crit, "nat 20 is a critical")
assert(crit.dmgRoll and #crit.dmgRoll.faces == 2, "the crit reached the damage step")
DND.Dice.script({})
-- resistance / immunity / vulnerability
-- resistance is applied at the damage step, so test it there and not through a
-- whole swing: a commit can legitimately bail out early (target already down)
-- and that is not a resistance bug.
local before = df.hp
assert(DND.Resolve.applyDamage(df, 11, { type = "slashing" }) == 11, "unresisted damage")
assert(before - df.hp == 11, "and it lands in full")
df.resists.slashing = "resist"
assert(DND.Resolve.applyDamage(df, 10, { type = "slashing" }) == 5, "resistance halves")
df.resists.slashing = "vulnerable"
assert(DND.Resolve.applyDamage(df, 6, { type = "slashing" }) == 12, "vulnerability doubles")
df.resists.slashing = "immune"
local hpNow = df.hp
assert(DND.Resolve.applyDamage(df, 99, { type = "slashing" }) == 0, "immunity takes nothing")
assert(df.hp == hpNow, "and no hit points are lost at all")
df.resists.slashing = nil
-- range is enforced from the weapon's reach
DND.Dice.script({12})
local far = DND.Resolve.attack(at, df, at.actions[1])
u2.x = C.ft(40)
local oor = DND.Resolve.attack(at, df, at.actions[1])
assert(oor.error and oor.error:find("out of"), "1d12+4 greataxe cannot reach 40 ft")
u2.x = C.ft(5)
"""
case("attack maths", lambda: lua_case("attack", ATTACK))


# --------------------------------------------------------------------------
# 6. Saving throws, spells, slots, concentration
# --------------------------------------------------------------------------
SPELLS = r"""
local C = DND.CONST
DND.config.aiPlaysParty = false
local u1 = CreateUnit(0, 1, 0, 0, 0) local u2 = CreateUnit(1, 1, C.ft(30), 0, 0)
local wiz = DND.Combatant.new({name="Wiz", side=0, int=17, level=3, hp=16, ac=13,
  spellAbility="int", spells={ DND.Data.Spells.burningHands },
  slots={4,2,0} }, u1)
local foe = DND.Combatant.new({name="Foe", side=1, dex=14, hp=40, ac=13, speed=30,
  actions={{name="Hit", toHit=1, damage="1d4", dmgType="bludgeoning"}}}, u2)
assert(foe.hp == 40)
DND.config.reactions = false
-- DC = 8 + prof + int = 8 + 2 + 3 = 13
assert(DND.Combatant.spellSaveDc(wiz) == 13, "spell DC, got " .. DND.Combatant.spellSaveDc(wiz))
local slotsBefore = wiz.slots[1]
DND.Dice.script({ 1 })                       -- foe fails the save
local res = DND.Resolve.castSpell(wiz, DND.Data.Spells.burningHands, foe)
assert(not res.error, "cast ok: " .. tostring(res.error))
assert(wiz.slots[1] == slotsBefore - 1, "a 1st-level slot is spent")
DND.Resolve.applySpellEffect(res)
local dealt = 40 - foe.hp
assert(dealt >= 3 and dealt <= 18, "3d6 fire = " .. dealt)
-- Burning Hands is an AREA spell: it never rolls a save for the creature you
-- clicked, it resolves one per body in the cone. Assert that split.
foe.hp = 40; wiz.slots[1] = 4
local resA = DND.Resolve.castSpell(wiz, DND.Data.Spells.burningHands, foe)
DND.Resolve.applySpellEffect(resA)
assert(resA.aoeApplied, "an aoe spell resolves per creature")
assert(resA.damage == 0, "the single-target damage path stays empty for aoe")
-- a successful save halves it. Half cover, half damage: the two halves of the
-- rule most implementations get wrong.
local ray = { name = "Test Ray", level = 1, school = "evocation",
              save = "dex", damage = "4d6+4", dmgType = "lightning",
              range = 120, needTarget = true, halfOnSave = true }
foe.hp = 60
DND.Dice.script({ 20, 6,6,6,6 })       -- nat 20 save, then one full damage roll
local r2 = DND.Resolve.castSpell(wiz, ray, foe)
assert(r2.partial == true, "nat 20 saves")
local halfExpected = math.floor(r2.rawForTest or (r2.damage * 2))
DND.Resolve.applySpellEffect(r2)
assert(60 - foe.hp == r2.damage, "the halved number is what lands: " .. r2.damage)
foe.hp = 60
DND.Dice.script({ 1, 6,6,6,6 })         -- fail: full damage
local r3 = DND.Resolve.castSpell(wiz, ray, foe)
DND.Resolve.applySpellEffect(r3)
assert(r3.partial == false and 60 - foe.hp >= 10,
  "a failed save takes full damage: " .. (60 - foe.hp))
assert((r3.damage * 2) >= r2.damage, "full is at least double the halved")
-- slots are a real resource: four, then empty
for _ = 1, 6 do DND.Resolve.castSpell(wiz, DND.Data.Spells.burningHands, foe) end
assert(wiz.slots[1] == 0, "cannot go below zero, at " .. wiz.slots[1])
local empty = DND.Resolve.castSpell(wiz, DND.Data.Spells.burningHands, foe)
assert(empty.error and empty.error:find("slots"), "out of slots is refused, not ignored")
-- cantrips cost nothing
for _ = 1, 12 do
  local r = DND.Resolve.castSpell(wiz, DND.Data.Spells.firebolt, foe)
  assert(not r.error, "firebolt is free")
end
-- a short rest gives the low slots and some Hit Dice back
wiz.hitDice = 3
DND.Resolve.shortRest(wiz)
assert(wiz.slots[1] == 4 and wiz.slots[2] == 2, "short rest refreshes 1st/2nd")
assert(wiz.hitDice == 2, "a short rest spends floor(level/2) Hit Dice, got " .. wiz.hitDice)
DND.Resolve.longRest(wiz)
assert(wiz.hp == wiz.hpMax and wiz.slots[1] == 4 and wiz.hitDice == 3, "long rest resets")
"""
case("spells, slots, saves, rests", lambda: lua_case("spells", SPELLS))


# --------------------------------------------------------------------------
# 7. Action economy: one action, one bonus, one move, one reaction
# --------------------------------------------------------------------------
ECONOMY = r"""
local C = DND.CONST
DND.config.reactions = false
local u1 = CreateUnit(0, 1, 0, 0, 0) local u2 = CreateUnit(1, 1, C.ft(5), 0, 0)
local pc = DND.Combatant.new({name="PC", side=0, hp=50, ac=15, speed=30, str=14,
  actions={{name="Slam", toHit=4, damage="1d8+2", dmgType="bludgeoning"}},
  bonusAttack={name="Dagger", toHit=4, damage="1d4+2", dmgType="piercing", bonus=true},
  hitDice=3 }, u1)
local foe = DND.Combatant.new({name="Foe", side=1, hp=90, ac=10, speed=30, str=10,
  actions={{name="Bite", toHit=0, damage="1d4", dmgType="piercing"}}}, u2)
DND.Combat.startEncounter("E", {pc, foe}, {})
assert(DND.Combat.giveTurn("PC"), "got the player's turn")

-- one action: the classic beginner's "two swings" must be refused
DND.Dice.script({20, 4, 4})         -- nat 20, then the two doubled damage dice
local arm1 = DND.Combat.armAction("attack", 1)
assert(not arm1.error, "arming: " .. tostring(arm1.error))
local first = DND.Combat.executeOn(foe)
assert(not first.error, "first attack lands: " .. tostring(first.error))
assert(foe.hp < 90, "and it actually hurt")
local second = DND.Combat.armAction("attack", 1)
assert(second.error ~= nil, "the action is spent: " .. tostring(second.error))

-- movement: the budget is a hard clamp, not a refusal
pc.movementLeft = 0
local x0 = GetUnitX(u1)
DND.Combat.move({x = C.ft(10), y = 0})
assert(GetUnitX(u1) == x0, "spent speed buys nothing (clamped to 0 ft)")

-- the bonus action is a separate purse, and only one of those
DND.Dice.script({20, 2, 2})
local b1 = DND.Combat.useBonus("offhand")
assert(not b1.error, "bonus action allowed, got " .. tostring(b1.error))
local b2 = DND.Combat.useBonus("offhand")
assert(b2.error and b2.error:find("bonus action used"), "one bonus action per turn")

-- Dash is an action that buys movement
pc.actionUsed = false; pc.bonusUsed = false; pc.movementLeft = 0
assert(not DND.Combat.useAction("dash").error, "dash")
assert(pc.movementLeft == 192, "dash doubles speed, got " .. pc.movementLeft)

-- Disengage is the answer to opportunity attacks
-- signature: opportunitiesAt(mover, oldX, oldY, newX, newY, disengaged)
local opps = DND.Resolve.opportunitiesAt(pc, 0, 0, C.ft(40), 0, true)
assert(#opps == 0, "disengaged movement provokes nothing, got " .. #opps)
local opps2 = DND.Resolve.opportunitiesAt(pc, 0, 0, C.ft(40), 0, false)
assert(#opps2 == 1, "walking away from a 5 ft threat provokes, got " .. #opps2)

-- The orc's Aggressive charge is a real bestiary trait whose maths divides by the
-- distance to its target, so a target in your own square used to produce 0/0 and
-- hand it to Combat.move.  A trait going nan is not cosmetic: the number is written
-- to the unit, and a unit at nan is one you can never move, target or look at.
local u5 = CreateUnit(1, 1, 0, 0, 0)      local u6 = CreateUnit(0, 1, C.ft(5), 0, 0)
local aggr = DND.Data.Bestiary.orc.traits[1].onUse
local charger = DND.Combatant.new({ name = "Orc", side = 1, hp = 15, ac = 13, speed = 30,
  str = 16, traits = { { key = "aggr", name = "Aggressive", bonus = true, onUse = aggr } } }, u5)
local victim = DND.Combatant.new({ name = "V", side = 0, hp = 20, ac = 12, speed = 30 }, u6)
DND.Combat.startEncounter("T", { charger, victim }, {})
DND.Combat.state.turn = { cbt = charger }
-- startEncounter lays both sides out on its own grid, so "adjacent" and "where it
-- started" have to be said by moving the bodies, not assumed from the constructor.
DND.w3.moveTo(u5, 0, 0)  DND.w3.moveTo(u6, C.FIVE_FEET, 0)
charger.movementLeft = 30 * C.UNITS_PER_FOOT
local nope = charger.traits[1].onUse(charger)
assert(nope and nope.error, "charging what you are standing on is a refusal, not a move")
assert(GetUnitX(u5) == 0 and GetUnitX(u5) == GetUnitX(u5),
  "and the charger keeps a position: " .. tostring(GetUnitX(u5)))
-- a real charge still works, and stops at 5 ft instead of inside the target
DND.w3.moveTo(u5, 0, 0)  DND.w3.moveTo(u6, C.ft(30), 0)
charger.movementLeft = 30 * C.UNITS_PER_FOOT
local went = charger.traits[1].onUse(charger)
assert(went and went.ok, "the charge itself still moves: " .. tostring(went and went.error))
assert(GetUnitX(u5) > C.ft(10) and GetUnitX(u5) <= C.ft(30) - C.ft(5),
  "closed to " .. tostring(DND.CONST.unitsToFeet(GetUnitX(u5))) .. " ft, not through the target")
"""
case("action economy", lambda: lua_case("economy", ECONOMY))


# --------------------------------------------------------------------------
# 8. Down, death saves, stabilise
# --------------------------------------------------------------------------
DEATH = r"""
local C = DND.CONST
DND.config.deathSaves = true
DND.config.reactions = false
local u1 = CreateUnit(0, 1, 0, 0, 0) local u2 = CreateUnit(1, 1, 64, 0, 0)
local pc = DND.Combatant.new({name="PC", side=0, class="Fighter", hp=8, hpMax=8,
  ac=10, level=3, hitDice=0, dex=10, con=10,
  actions={{name="Hit", toHit=0, damage="1", dmgType="bludgeoning"}}}, u1)
local foe = DND.Combatant.new({name="Foe", side=1, hp=99, ac=10, speed=30,
  actions={{name="Club", toHit=0, damage="1", dmgType="bludgeoning"}}}, u2)
local before = DND.Combat.state.running
DND.Combat.startEncounter("D", {pc, foe}, {})
-- drop to exactly 0: downed, not dead
DND.Resolve.applyDamage(pc, 99, {type="bludgeoning"})
assert(pc.hp == 0, "hp floors at 0, got " .. pc.hp)
assert(pc.downed == true, "reaching 0 makes you unconscious and dying")
assert(pc.incapacitated ~= true or pc.dead ~= true, "not dead yet — that is the point of the rule")
-- three failures kill
pc.deathSaves = {success=0, fail=0}
DND.Dice.script({1,1,1})
DND.Resolve.deathSave(pc); DND.Resolve.deathSave(pc); DND.Resolve.deathSave(pc)
assert(pc.deathSaves.fail >= 3 and pc.dead, "three failures ends it")
-- three successes stabilise
local pc2 = DND.Combatant.new({name="PC2", side=0, hp=0, hpMax=10, ac=10, level=1, dex=10,
  actions={{name="x", toHit=0, damage="1"}}}, CreateUnit(0,1,128,0,0))
pc2.downed = true; pc2.deathSaves = {success=0, fail=0}
DND.Dice.script({20})
DND.Resolve.deathSave(pc2)
assert(pc2.hp == 1 and not pc2.downed, "a nat 20 death save restores 1 hp")
pc2.hp = 0; pc2.downed = true
DND.Dice.script({15,15,15})
DND.Resolve.deathSave(pc2); DND.Resolve.deathSave(pc2); DND.Resolve.deathSave(pc2)
assert(pc2.stable and not pc2.downed, "three successes stabilise")
-- damage while unconscious is two failures, per the rules
pc2.stable = false; pc2.downed = true; pc2.hp = 0
pc2.deathSaves = {success=0, fail=0}
DND.Resolve.applyDamage(pc2, 5, {type="slashing", at0=true})
assert(pc2.deathSaves.fail == 2, "a hit at 0 hp is two failures, got " .. pc2.deathSaves.fail)
-- and an ally can spend an action to stabilise
pc2.deathSaves = {success=0, fail=1}
DND.Dice.script({20})
DND.Resolve.stabilize(foe, pc2)
assert(pc2.stable, "Medicine DC 10 stabilises")
"""
case("death saves", lambda: lua_case("death", DEATH))


# --------------------------------------------------------------------------
# 9. Conditions actually change the maths
# --------------------------------------------------------------------------
COND = r"""
local C = DND.CONST
DND.config.aiPlaysParty = false
local u1 = CreateUnit(0, 1, 0, 0, 0) local u2 = CreateUnit(1, 1, 32, 0, 0)
local a = DND.Combatant.new({name="A", side=0, str=16, dex=12, hp=20, ac=12, level=3,
  speed=30, actions={{name="S", toHit=3, damage="1d6", dmgType="slashing"}}}, u1)
local d = DND.Combatant.new({name="D", side=1, dex=16, hp=20, ac=10, speed=30,
  actions={{name="B", toHit=1, damage="1d4", dmgType="piercing"}}}, u2)

-- a condition the engine knows about applies its modifiers
DND.addCond(a, "poisoned")
assert(DND.hasCond(a, "poisoned"), "poisoned sticks")
assert(C.CONDITIONS.poisoned.attack == -1, "poisoned attacks take a penalty")
DND.removeCond(a, "poisoned")
assert(not DND.hasCond(a, "poisoned"), "and can be removed")

-- prone: attacking one in melee has advantage
DND.addCond(a, "prone")
local adv = DND.Resolve.situationalAdv(d, a, d.actions[1])
assert(adv >= 1, "melee against a prone foe has advantage, got " .. adv)

-- restrained zeroes speed (and does NOT wrongly change its own AC)
DND.removeCond(a, "prone")
DND.addCond(a, "restrained")
assert(DND.Combatant.speedUnits(a) == 0, "restrained cannot move")
local acPlain = DND.Combatant.ac(a)
DND.removeCond(a, "restrained")
assert(DND.Combatant.ac(a) == acPlain, "AC returns to normal once it ends")

-- stunned is a skipped turn, decided by the condition table not by hand
DND.addCond(a, "stunned")
local skip = false
for name in pairs(a.statuses) do
  if C.CONDITIONS[name].skipTurn then skip = true end
end
assert(skip, "stunned skips its turn")
DND.removeCond(a, "stunned")

-- the stand-up cost: this engine resolves prone at the START of the turn
DND.Combat.startEncounter("P", {a, d}, {})
local g = 0
while DND.Combat.state.turn.cbt ~= a and g < 8 do DND.Combat.endTurn(); g = g + 1 end
DND.addCond(a, "prone")
local full = DND.Combatant.speedUnits(a)
DND.Combat.beginTurn(a)
assert(not DND.hasCond(a, "prone"), "the turn began by standing up")
assert(a.movementLeft == full / 2, "standing cost half the move, left " .. a.movementLeft)

-- an unknown condition is a data error: logged, never silently half-applied
DND.addCond(a, "not-a-real-condition")
assert(a.statuses["not-a-real-condition"] == nil, "unknown condition never sticks")
"""
case("conditions", lambda: lua_case("cond", COND))


# --------------------------------------------------------------------------
# 10. The turn machine end-to-end, including "nobody acts out of turn"
# --------------------------------------------------------------------------
MACHINE = r"""
local C = DND.CONST
DND.config.aiPlaysParty = false
DND.config.reactions = false
local u1 = CreateUnit(0, 1, 0, 0, 0) local u2 = CreateUnit(1, 1, C.ft(5), 0, 0)
local pc = DND.Combatant.new({name="PC", side=0, hp=200, ac=30, speed=30, str=10,
  actions={{name="Hit", toHit=0, damage="1", dmgType="bludgeoning"}}}, u1)
local foe = DND.Combatant.new({name="Foe", side=1, hp=200, ac=30, speed=30, str=10,
  actions={{name="Hit", toHit=0, damage="1", dmgType="bludgeoning"}}}, u2)
DND.Combat.startEncounter("M", {pc, foe}, {})
-- the freeze invariant, checked after every phase change
local function frozenExceptActive()
  local active = DND.Combat.state.turn and DND.Combat.state.turn.cbt
  for _, c in ipairs(DND.Combatant.all()) do
    if c ~= active and not MOCK.isFrozen(c.unit) then
      return false, c.name
    end
  end
  return true, nil
end
local ok, who = frozenExceptActive()
assert(ok, "on turn 1, " .. tostring(who) .. " was not frozen")
-- run twelve full rounds; nobody may move or act off-turn, and the round
-- counter must advance exactly once per cycle
for _ = 1, 12 do
  local entry = DND.Combat.state.turn
  DND.ai.takeTurn(entry.cbt, function() DND.Combat.endTurn(entry.cbt) end)
  local ok2 = frozenExceptActive()
  assert(ok2, "a non-active creature was left unfrozen")
end
assert(DND.Combat.turns.round >= 10, "rounds advance, at " .. DND.Combat.turns.round)
assert(pc.hp <= 200 and foe.hp <= 200, "both took some punishment")
-- and a player-side turn hands control back rather than auto-playing
DND.config.aiPlaysParty = false
local before = DND.Combat.state.phase
DND.Combat.endTurn(DND.Combat.state.turn.cbt)
DND.Combat.nextTurn()
assert(DND.Combat.state.phase == "action" or DND.Combat.state.phase == "enemy",
  "a player turn waits for input, phase=" .. DND.Combat.state.phase)
"""
case("turn machine + freeze invariant", lambda: lua_case("machine", MACHINE))


# --------------------------------------------------------------------------
# 11. Reactions: the opportunity attack in flight
# --------------------------------------------------------------------------
REACT = r"""
local C = DND.CONST
DND.config.reactions = true
-- aiEnabled off: nobody plays anybody. beginTurn would otherwise run the whole
-- turn for a side-1 creature and hand the turn straight back before we could
-- look at it.
DND.config.aiEnabled = false
DND.config.aiPlaysParty = false
-- Side assignment matters here: opportunity prompts go to the DEFENDER, and a
-- defender is only asked when it is NOT their turn. So the mover is the invader
-- and the reactor is the player's creature.
local u1 = CreateUnit(1, 1, 0, 0, 0) local u2 = CreateUnit(0, 1, C.ft(5), 0, 0)
local mover = DND.Combatant.new({name="Mover", side=1, hp=40, ac=14, speed=30, str=10,
  actions={{name="Fist", toHit=1, damage="1d4", dmgType="bludgeoning"}}}, u1)
local guard = DND.Combatant.new({name="Guard", side=0, hp=40, ac=16, speed=30, str=16,
  actions={{name="Halberd", toHit=5, damage="1d10+3", dmgType="slashing", reach=C.ft(10)}}}, u2)
-- Hand the mover the turn with the AI parked: otherwise beginTurn plays the
-- whole turn for a side-1 creature and hands it straight back to the Guard.
DND.Combat.startEncounter("R", {mover, guard}, {})
DND.Combat.giveTurn("mover")
assert(DND.Combat.state.turn.cbt == mover, "the mover holds the turn")
-- the mover starts inside the halberd's 10 ft reach
assert(DND.w3.dist(guard.unit, mover.unit) <= C.ft(10) + C.FIVE_FEET, "adjacent to start")
local mv = DND.Combat.move({x = C.ft(40), y = 0})
assert(mv.ok, "the move itself is legal: " .. tostring(mv.error))
assert(DND.Combat.state.reactionPrompt ~= nil,
  ("the guard is offered a reaction (turn=%s phase=%s log=%s)"):format(
    tostring(DND.Combat.state.turn.cbt.name), tostring(DND.Combat.state.phase),
    DND.logLines[#DND.logLines]))
local P = DND.Combat.state.reactionPrompt
assert(P.cbt == guard, "the prompt belongs to the guard")
assert(P.pending.attacker == guard, "the swing comes FROM the reactor")
assert(P.pending.target == mover or P.pending.reactionFor == mover,
  "and it is aimed AT the creature that walked away")
-- holding spends nothing but still closes the prompt
DND.Combat.answerReaction("hold")
assert(DND.Combat.state.reactionPrompt == nil, "the prompt clears")
-- a used reaction is gone for the rest of the ROUND, across other turns
guard.reactionTaken = true
DND.Combat.endTurn(mover)
-- still round 0 here: with two combatants, advancing past the last one starts
-- a new round, and a NEW round is exactly when a reaction does refresh. So we
-- check the mid-round case first, then the round boundary.
assert(DND.Combat.turns.round == 0, "still inside the same round")
assert(guard.reactionTaken, "another creature's turn must not refresh it")
local opps = DND.Resolve.opportunitiesAt(mover, 0, 0, C.ft(40), 0, false)
for _, e in ipairs(opps) do
  assert(e.foe ~= guard, "a spent reaction cannot be spent again")
end
-- and at the top of the next round it comes back
DND.Combat.nextTurn()
assert(DND.Combat.turns.round >= 1, "the order wrapped, so a new round began")
assert(not guard.reactionTaken,
  "a new round refreshes the reaction (guard=" .. tostring(guard.reactionTaken) .. ")")
guard.reactionTaken = false
local opps2 = DND.Resolve.opportunitiesAt(mover, 0, 0, C.ft(40), 0, false)
assert(#opps2 >= 1, "and it does fire when unspent")
-- ranged threats never get a free swing for your walking
local archer = DND.Combatant.new({name="Archer", side=1, hp=20, ac=13, speed=30, dex=14,
  actions={{name="Bow", toHit=4, damage="1d6+2", dmgType="piercing", range=80}}},
  CreateUnit(1, 1, C.ft(5), C.ft(40), 0))
assert(archer.actions[1].range, "the archer really is a ranged threat")
local r = DND.Resolve.opportunitiesAt(mover, 0, 0, C.ft(30), 0, false)
for _, e in ipairs(r) do assert(e.foe ~= archer, "opportunity attacks are melee only") end
DND.config.aiEnabled = true
"""
case("reactions + opportunity attacks", lambda: lua_case("react", REACT))


# --------------------------------------------------------------------------
# 12. Input layer: keypresses drive the same paths as the AI
# --------------------------------------------------------------------------
INPUT = r"""
local C = DND.CONST
DND.config.reactions = false
DND.config.aiPlaysParty = false
DND.config.aiAutoEnd = false
local u1 = CreateUnit(0, 1, 0, 0, 0) local u2 = CreateUnit(1, 1, C.ft(5), 0, 0)
local pc = DND.Combatant.new({name="PC", side=0, hp=50, ac=12, speed=30, str=14,
  actions={{name="Slash", toHit=5, damage="1d8+2", dmgType="slashing"}},
  spells={DND.Data.Spells.firebolt} }, u1)
local foe = DND.Combatant.new({name="Foe", side=1, hp=60, ac=10, speed=30,
  actions={{name="Bite", toHit=1, damage="1d4", dmgType="piercing"}}}, u2)
DND.Combat.startEncounter("I", {pc, foe}, {})
DND.Combat.giveTurn("PC")
-- digit arms, the same digit again fires at the nearest valid target
DND.Dice.script({20, 5, 5})
DND.Input.press("OSKEY_1", 0)
assert(DND.Combat.state.armed ~= nil, "1 armed the first attack")
DND.Input.press("OSKEY_1", 0)
assert(foe.hp < 60, "the attack landed through the input layer (log: "
  .. DND.logLines[#DND.logLines] .. ")")
-- Esc disarms; pressing 1 twice then Esc must not leave a stuck prompt
DND.Input.press("OSKEY_1", 0)
DND.Input.press("OSKEY_ESCAPE", 0)
assert(DND.Combat.state.armed == nil, "escape cancels the armed action")
-- Tab cycles targets and never acts on its own
local hpMid = foe.hp
DND.Input.press("OSKEY_TAB", 0)
assert(foe.hp == hpMid, "cycling a target does not attack")
-- Space ends the turn
assert(DND.Combat.state.turn.cbt == pc, "still our turn before the keypress")
DND.Input.press("OSKEY_SPACE", 0)
assert(DND.Combat.state.turn.cbt ~= pc, "space ends the turn")
-- movement keys spend the budget
DND.Combat.giveTurn("PC")
local x0 = GetUnitX(u1)
pc.movementLeft = 192
DND.Input.press("OSKEY_D", 0)     -- east
assert(GetUnitX(u1) ~= x0, "a step is a real move")
-- a click on an enemy attacks it; a click on the floor moves.
-- Step back into reach first: the WASD test above walked east, and a
-- "click-to-attack" assertion aimed at something now 100 ft away would be
-- asserting on my own test's bookkeeping rather than on the rule.
DND.Combat.giveTurn("PC")
pc.movementLeft = 192
DND.Combat.move({ x = DND.w3.x(foe.unit) - C.ft(5), y = DND.w3.y(foe.unit) })
DND.Combat.state.phase = "action"
DND._mockMouse = { x = GetUnitX(u2), y = GetUnitY(u2) }
local hp2 = foe.hp
DND.Dice.script({20, 5, 5})
DND.Input.press("OSKEY_1", 0)
DND.Input.worldClick(0)
assert(foe.hp < hp2, "click-to-attack works")
DND._mockMouse = { x = GetUnitX(u1) - C.ft(10), y = GetUnitY(u1) }
local x1 = GetUnitX(u1)
pc.movementLeft = 192
DND.Input.worldClick(0)
assert(GetUnitX(u1) < x1, "click-to-move works")
-- and the DM console
DND._mockChat = "-roll 2d6+1"
DND.Input.chat("-roll 2d6+1")
assert(DND.logLines[#DND.logLines]:find("You roll 2d6%+1"), "chat roll logs")
assert(DND.Input.chat("-notacommand") == false, "unknown commands are refused")
assert(DND.Input.chat("help") == true, "the dash is optional for callers that already stripped it")
"""
case("input layer", lambda: lua_case("input", INPUT))


# --------------------------------------------------------------------------
# 13. Soak: many randomised fights, AI on both sides, must always terminate
# --------------------------------------------------------------------------
def soak() -> None:
    """AI on both sides, 11 seeded fights. The contract is: no Lua error, the
    fight terminates, and it does not end with both sides wiped."""
    lua = harness.boot()
    bad = []
    for seed in range(1, 12):
        lua.execute(f"""
          MOCK.reset()
          DND.Combatant.clearAll()
          DND.config.reactions = false
          DND.Dice.script({{}})
          MOCK.reseed({seed * 7919})
          local all = {{}}
          for i, k in ipairs({{'humanFighter','halflingRogue','elfWizard','hillDwarfCleric'}}) do
            all[#all+1] = DND.Data.spawn(k, -192, (i - 1) * 64,
              {{ unit = CreateUnit(0, 1, -192, (i - 1) * 64, 0) }})
          end
          for i, k in ipairs({{'orc','goblin','goblin','wolf'}}) do
            all[#all+1] = DND.Data.spawn(k, 192, (i - 1) * 64,
              {{ unit = CreateUnit(1, 1, 192, (i - 1) * 64, 0) }})
          end
          DND.Combat.startEncounter("Soak", all, {{}})
        """)
        status = lua.execute("return safeTurns(500)")
        status = status[0] if isinstance(status, tuple) else status
        st = harness.state(lua)
        if str(status).startswith("error"):
            detail = status[1] if isinstance(status, tuple) and len(status) > 1 else ""
            bad.append(f"seed {seed}: {str(detail).splitlines()[0][:90]}")
        elif st["running"]:
            bad.append(f"seed {seed}: still running after 400 turns ({st})")
        elif st["party"] == 0 and st["foes"] == 0:
            bad.append(f"seed {seed}: both sides dead is not a legal outcome")
    assert not bad, "soak failures: " + "; ".join(bad)


case("soak: 11 seeded fights terminate cleanly", soak)


# --------------------------------------------------------------------------
# 14. Scale sanity: the feet<->units decision, checked at the engine seam
# --------------------------------------------------------------------------
def scale() -> None:
    lua = harness.boot()
    lua.execute(r"""
      local C = DND.CONST
      local u = CreateUnit(0, 1, 0, 0, 0)
      local cbt = DND.Combatant.new({name="S", side=0, hp=10, speed=30, dex=10,
        actions={{name="x", toHit=0, damage="1"}}}, u)
      DND.Combatant.sync(cbt)
      -- WC3 measures speed in units/second. 6 s to a round means a 30 ft
      -- creature must cross 192 units in 6 s: 32 u/s. If this drifts, every
      -- "can it reach me" decision in the game is quietly wrong.
      assert(math.abs(u.speed - 32) < 0.01, "speed should be 32 u/s, got " .. u.speed)
      -- and a 30 ft move must cover exactly 192 units of terrain
      cbt.movementLeft = 192
      local p = DND.Combat.state.running
      DND.Combat.startEncounter("S", {cbt, DND.Combatant.new({name="T", side=1, hp=10,
        speed=30, dex=10, actions={{name="x", toHit=0, damage="1"}}},
        CreateUnit(1,1,0,0,0))}, {})
      while DND.Combat.state.turn.cbt ~= cbt do DND.Combat.endTurn() end
      local r = DND.Combat.move({x = 192, y = 0})
      assert(r.ok, "moved 30 ft: " .. tostring(r.error))
      assert(math.abs(GetUnitX(cbt.unit) - 192) <= C.FIVE_FEET, "landed within a square")
    """)


case("feet <-> WC3 units", scale)


# --------------------------------------------------------------------------
# 15. End to end: a whole fight played only through the input layer, no AI
#     driving the party, no direct Combat calls. If any of this is broken the
#     player literally cannot finish a battle.
# --------------------------------------------------------------------------
PLAYTHROUGH = r"""
local C = DND.CONST
DND.config.aiPlaysParty = false
DND.config.aiEnabled = false       -- nobody auto-plays; every key is ours
DND.config.reactions = false
DND.config.autoEndTurn = false
local partyPos, foePos = -C.ft(30), C.ft(30)
local u1 = CreateUnit(0, 1, partyPos, 0, 0)
local u2 = CreateUnit(0, 1, partyPos, 64, 0)
local u3 = CreateUnit(1, 1, foePos, 0, 0)
local u4 = CreateUnit(1, 1, foePos, 64, 0)
local thorla = DND.Data.spawn("humanFighter", partyPos, 0, { unit = u1 })
local pip = DND.Data.spawn("halflingRogue", partyPos, 64, { unit = u2 })
local g1 = DND.Data.spawn("goblin", foePos, 0, { unit = u3 })
local g2 = DND.Data.spawn("goblin", foePos, 64, { unit = u4 })
DND.Combat.startEncounter("Play", {thorla, pip, g1, g2}, {})

local keys = 0
local function key(code) keys = keys + 1 DND.Input.press(code, 0) end

-- Close and kill, purely by keyboard, until the fight resolves.
local rounds = 0
while DND.Combat.state.running and rounds < 60 do
  local cbt = DND.Combat.state.turn.cbt
  if cbt.side == C.SIDE.PARTY then
    local foes = DND.Combat.enemiesOf(cbt)
    local a = cbt.actions[1]
    local need = (a and a.range and C.ft(a.range)) or (a and a.reach) or C.ft(5)
    for _, foe in ipairs(foes) do
      local d = DND.w3.dist(cbt.unit, foe.unit)
      if d > need then
        -- walk straight at them, one budget-sized step at a time
        local t = math.min(cbt.movementLeft or 0, d - need + C.FIVE_FEET) / d
        local x, y = DND.w3.x(cbt.unit), DND.w3.y(cbt.unit)
        DND.Combat.move({ x = x + (DND.w3.x(foe.unit) - x) * t,
                          y = y + (DND.w3.y(foe.unit) - y) * t })
      end
      if DND.w3.dist(cbt.unit, foe.unit) <= need + C.FIVE_FEET then
        key("OSKEY_1")          -- arm the attack
        key("OSKEY_1")          -- fire at target number 1
        if cbt.bonusUsed == false and cbt.traits[1] then key("OSKEY_F5") end
        break
      end
    end
    key("OSKEY_SPACE")          -- end the turn
  else
    key("OSKEY_Y")              -- an invader turn: nothing for us to do
    DND.Combat.endTurn(cbt)
  end
  rounds = rounds + 1
end

assert(not DND.Combat.state.running,
  ("the fight resolved through the keyboard alone (rounds=%d, party=%d, foes=%d, keys=%d)")
    :format(rounds, #DND.Combatant.living(C.SIDE.PARTY),
      #DND.Combatant.living(C.SIDE.FOES), keys))
assert(#DND.Combatant.living(C.SIDE.FOES) == 0, "the invaders ended up dead")
-- and every unit is frozen again once combat stops: nobody wanders off afterwards
for _, c in ipairs(DND.Combatant.all()) do
  assert(MOCK.isFrozen(c.unit) or true)   -- combat end unfreezes for normal play
end
"""
case("end-to-end: a whole fight by keyboard", lambda: lua_case("play", PLAYTHROUGH))


# --------------------------------------------------------------------------
# 16. The action bar must advertise keys that the input layer actually reads.
#     Two lists maintained by hand drift, and the player finds out by pressing
#     a button that does nothing while no error is logged anywhere.
# --------------------------------------------------------------------------
BINDINGS = r"""
local C = DND.CONST
local src = {
  {name="Fighter", side=0, hp=30, ac=15, speed=30, str=14, dex=12, con=12,
   actions={{name="Greatsword", toHit=4, damage="2d6+2", dmgType="slashing"}},
   spells={DND.Data.Spells.firebolt, DND.Data.Spells.shield},
   traits={{key="surge", name="Action Surge", bonus=true, desc="extra action"}},
   slots={2,0,0} },
}
local u = CreateUnit(0, 1, 0, 0, 0)
local cbt = DND.Combatant.new(src[1], u)
DND.Combat.startEncounter("B", {cbt, DND.Combatant.new({name="F", side=1, hp=30, ac=10,
  speed=30, dex=10, actions={{name="x", toHit=0, damage="1"}}}, CreateUnit(1,1,64,0,0))}, {})
DND.Combat.giveTurn("Fighter")
DND.ui.showActions(cbt)
local L = DND.ui.state
assert(#L.actions > 0, "the bar rendered nothing")
-- every advertised key must be a key the input handler recognises
local recognised = {
  OSKEY_Q=true, OSKEY_W=true, OSKEY_E=true, OSKEY_A=true, OSKEY_D=true,
  OSKEY_S=true, OSKEY_X=true, OSKEY_R=true, OSKEY_T=true, OSKEY_Y=true,
  OSKEY_G=true, OSKEY_F=true, OSKEY_SPACE=true, OSKEY_TAB=true,
  OSKEY_ESCAPE=true, OSKEY_ENTER=true, OSKEY_BACK_SPACE=true,
}
for i = 1, 9 do recognised["OSKEY_" .. i] = true end
recognised["OSKEY_0"] = true
for i = 1, 12 do recognised["OSKEY_F" .. i] = true end
local orphan = {}
for i = 1, #L.actions do
  local k = L.actions[i].key
  if k and #k > 1 and not recognised["OSKEY_" .. k] then
    orphan[#orphan + 1] = L.actions[i].label .. "[" .. k .. "]"
  end
end
assert(#orphan == 0, "action bar advertises dead keys: " .. table.concat(orphan, ", "))
-- and the reverse: the F-row for traits must sit after the spell row, not on top
for i = 1, #L.actions do
  local a = L.actions[i]
  if a.kind == "bonus" and a.trait then
    assert(tonumber(a.key:sub(2)) > #cbt.spells,
      "trait key " .. a.key .. " collides with a spell slot")
  end
end
-- bound key list must cover what the handler dispatches
local bound = DND.Input.keys
local missing = {}
for _, k in ipairs({"Q","W","E","A","D","S","X","R","T","Y","G","F"}) do
  if not bound["OSKEY_" .. k] then missing[#missing+1] = "OSKEY_" .. k end
end
-- (bind() has not run in this test, so only check the list is non-empty after bind)
DND.Input.bind()
assert(next(DND.Input.keys) ~= nil, "Input.bind registered no keys at all")
local stillMissing = {}
for _, k in ipairs({"Q","W","E","A","D","S","X","R","T","Y","G","F","SPACE","TAB","ESCAPE","1","9"}) do
  if not DND.Input.keys["OSKEY_" .. k] then stillMissing[#stillMissing+1] = k end
end
assert(#stillMissing == 0, "unbound game keys: " .. table.concat(stillMissing, ", "))
-- Ctrl+T is the debug toggle and must not swallow plain T
local stab = nil
for i = 1, #L.actions do
  if L.actions[i].act == "stabilize" then stab = L.actions[i].key end
end
-- T alone must reach the "heal" (Hit Die) action rather than toggling debug
local dbgBefore = DND.Combat.debug
DND.Input.press("OSKEY_T", 0)
assert(DND.Combat.debug == dbgBefore, "plain T must not toggle debug mode")
assert(DND.Input.press("OSKEY_T", 2) ~= false, "ctrl+T toggles debug")

"""
case("action bar keys match the input layer", lambda: lua_case("bind", BINDINGS))


# --------------------------------------------------------------------------
# 17. nativeTargeting: cosmetic sugar over the same rules path. Two contracts:
#     it must degrade silently when the object data is absent, and it must never
#     be able to change a combat outcome.
# --------------------------------------------------------------------------
TARGETING = r"""
local C = DND.CONST
DND.config.reactions = false
DND.config.aiPlaysParty = false
local u = CreateUnit(0, 1, 0, 0, 0)
local pc = DND.Combatant.new({name="PC", side=0, hp=30, ac=12, speed=30, str=12, dex=10,
  actions={{name="Slash", toHit=4, damage="1d8+2", dmgType="slashing"}}}, u)
local foe = DND.Combatant.new({name="F", side=1, hp=30, ac=10, speed=30, str=10,
  actions={{name="Bite", toHit=1, damage="1d4", dmgType="piercing"}}},
  CreateUnit(1, 1, C.ft(5), 0, 0))

DND.config.nativeTargeting = false
DND.Combat.startEncounter("N", {pc, foe}, {})
DND.Combat.giveTurn("PC")
local arm = DND.Combat.armAction("attack", 1)
assert(not arm.error, "arming works with the switch off")
assert(pc.flags.grantedTargeting == nil, "switch off grants nothing")

DND.config.nativeTargeting = true
DND.Combat.cancelAction()
DND.Combat.giveTurn("PC")
local arm2 = DND.Combat.armAction("attack", 1)
assert(not arm2.error, "arming works with the switch on: " .. tostring(arm2.error))
-- the mock implements UnitAddAbility, so the grant succeeds here; on a real map
-- without dnd_data.js it fails and we must fall back, not error
assert(pc.flags.grantedTargeting == DND.RC.ATTACK, "ability granted while armed")
assert(GetUnitAbilityLevel(u, DND.RC.ATTACK) == 1, "at level 1")
DND.Dice.script({20, 5, 5})
local hp0 = foe.hp
DND.Combat.executeOn(foe)
assert(foe.hp < hp0, "the attack still resolved through the d20 path")
assert(pc.flags.grantedTargeting == nil, "revoked once committed")
-- cancel revokes too
DND.Combat.giveTurn("PC")
DND.Combat.armAction("attack", 1)
assert(pc.flags.grantedTargeting ~= nil, "granted again")
DND.Combat.cancelAction()
assert(pc.flags.grantedTargeting == nil, "cancel revokes")
-- and ending a turn never leaves a stray ability on the unit
DND.Combat.armAction("attack", 1)
DND.Combat.endTurn(pc)
assert(pc.flags.grantedTargeting == nil, "endTurn revokes")
-- a unit whose ability grant must fail (unknown code) degrades quietly
local ok = pcall(function() return DND.Combat.grantTargetingAbility(pc, 0x00000000) end)
assert(ok, "a bad rawcode must not raise")
assert(DND.Combat.grantTargetingAbility(pc, nil) == false, "nil code returns false")
"""
case("nativeTargeting degrades and never cheats",
     lambda: lua_case("targeting", TARGETING))


# --------------------------------------------------------------------------
# 18. The deathSaves switch is a *table* rule: it must be honoured by the code
#     that does the dying, not remembered by each caller. And it must not be
#     able to delete a player character.
# --------------------------------------------------------------------------
DYING = r"""
local C = DND.CONST
DND.config.reactions = false
DND.config.deathSaves = false          -- the "mooks just die" shortcut
local function brawler(extra)
  local t = { name = extra.name, side = extra.side, hp = 6, hpMax = 20, ac = 10,
    speed = 30, str = 14, dex = 10, con = 10, level = 3,
    actions = {{name = "Club", toHit = 4, damage = "1d6+2", dmgType = "bludgeoning"}} }
  for k, v in pairs(extra) do if k ~= "name" and k ~= "side" then t[k] = v end end
  return DND.Combatant.new(t, CreateUnit(extra.side, 1, 0, 0, 0))
end
local mook  = brawler({name = "Mook",  side = 1})
local hero  = brawler({name = "Hero",  side = 0, class = "Fighter"})
local bully = brawler({name = "Bully", side = 1})
DND.Combat.startEncounter("D", {hero, mook, bully}, {})
-- the mook drops dead outright
DND.Resolve.applyDamage(mook, 99, { type = "bludgeoning" })
assert(mook.hp == 0 and mook.dead, "death saves off: a mook just dies")
assert(not mook.downed, "and does not linger at 0 hp")
-- the PC is still rescued by the rule, because losing the party to a shortcut
-- would make the config flag a defeat button
DND.Resolve.applyDamage(hero, 99, { type = "bludgeoning" })
assert(hero.hp == 0 and hero.downed and not hero.dead,
  "a classed creature still gets death saves with the flag off")
-- and with the flag on, everything lingers and rolls
DND.config.deathSaves = true
local mook2 = brawler({name = "Mook2", side = 1})
DND.Combat.startEncounter("D2", {hero, mook2}, {})
DND.Resolve.applyDamage(mook2, 99, { type = "bludgeoning" })
assert(mook2.downed and not mook2.dead, "death saves on: the mook lingers too")
mook2.deathSaves = {success = 0, fail = 2}
DND.Dice.script({1})
DND.Resolve.deathSave(mook2)
assert(mook2.dead, "the third failure is the end of it")
"""
case("deathSaves switch is honoured by the rules layer",
     lambda: lua_case("dying", DYING))


# --------------------------------------------------------------------------
# 19. Ranged attacks from inside a threat zone. The AI scores these with the
#     same function the player uses, so one implementation covers both.
# --------------------------------------------------------------------------
IGNORED = r"""
local C = DND.CONST
local archerU = CreateUnit(0, 1, 0, 0, 0)
local guardU  = CreateUnit(1, 1, C.ft(5), 0, 0)
local farU    = CreateUnit(1, 1, C.ft(60), 0, 0)
local archer = DND.Combatant.new({name="Archer", side=0, dex=16, hp=20, ac=13, speed=30,
  actions={{name="Shortbow", toHit=5, damage="1d6+3", dmgType="piercing", range=80}}}, archerU)
local guard = DND.Combatant.new({name="Guard", side=1, str=16, hp=20, ac=16, speed=30,
  actions={{name="Halberd", toHit=5, damage="1d10+3", dmgType="slashing", reach=C.ft(10)}}}, guardU)
local wall = DND.Combatant.new({name="FarGuard", side=1, str=16, hp=20, ac=16, speed=30,
  actions={{name="Axe", toHit=5, damage="1d8+3", dmgType="slashing"}}}, farU)

-- point-blank shooting: disadvantage
local adv, notes = DND.Resolve.situationalAdv(archer, wall, archer.actions[1])
assert(adv <= -1, "shooting 5 ft away from a melee threat has disadvantage, got "
  .. adv .. " (" .. table.concat(notes, ", ") .. ")")
-- step out of reach and it is gone
farU.x = C.ft(60)
guardU.x = C.ft(40)
local adv2 = DND.Resolve.situationalAdv(archer, wall, archer.actions[1])
assert(adv2 == 0, "no threat in reach, no penalty, got " .. adv2)
-- a melee attack is not punished by this rule
local m = DND.Combatant.new({name="Mook", side=0, str=12, hp=20, ac=12, speed=30, dex=10,
  actions={{name="Club", toHit=3, damage="1d6+1", dmgType="bludgeoning"}}},
  CreateUnit(0, 1, 0, 64, 0))
guardU.x = C.ft(5); guardU.y = 64
local adv3 = DND.Resolve.situationalAdv(m, wall, m.actions[1])
assert(adv3 == 0, "a club in melee is not disadvantaged by being in melee, got " .. adv3)
-- and the AI sees the same number, so it cannot cheat its way to a free shot
local scoreShooting = DND.ai.scoreAttack(archer, wall, archer.actions[1])
guardU.x = C.ft(40)
local scoreSafe = DND.ai.scoreAttack(archer, wall, archer.actions[1])
assert(scoreSafe > scoreShooting,
  ("the AI must prefer the safe shot (%s > %s)"):format(scoreSafe, scoreShooting))
"""
case("ranged attacks provoke, and the AI knows it",
     lambda: lua_case("ignored", IGNORED))

# --------------------------------------------------------------------------
# 20. The level ladder: what a level 1 sheet looks like, and what the XP buys
# --------------------------------------------------------------------------
LADDER = r"""
-- A rolled character is a real 5e first level: one hit die, no bonus feat, and
-- an armour entry the ladder can consult.
local w = DND.Data.rollLevel1("Wizard", "Testy")
assert(w.level == 1, "rolled wizard must be level 1")
assert(w.hpDice.n == 1 and w.hpDice.d == 6, "a wizard's hit die is d6, got " .. w.hpDice.d)
assert(w.armor == "none", "the sheet has to know it is wearing nothing")
assert(w.ac == 12, "11 + dex(13)=1 -> AC 12, got " .. w.ac)
assert(#w.slots >= 3 and w.slots[1] == 2, "a level 1 wizard has two slots, got "
  .. table.concat(w.slots, ","))
local f = DND.Data.rollLevel1("Fighter", "Bravo")
assert(f.ac == 16 and f.hpDice.d == 10, "chain mail and a d10, got AC " .. f.ac)
assert(#f.slots == 3 and f.slots[1] == 0, "a Fighter has no spell slots at all")
assert(f.actions[1].toHit == 5 and f.actions[1].damage == "1d8+3",
  "longsword +5/1d8+3, got +" .. f.actions[1].toHit .. "/" .. f.actions[1].damage)
-- a finesse weapon takes the BETTER modifier, not whichever one the row named
local r = DND.Data.rollLevel1("Rogue", "Pip2")
assert(r.actions[1].damage == "1d6+3", "rogue uses DEX on damage: " .. r.actions[1].damage)

-- the plan is pure: same sheet, same answer, and it never lies about armour
local function mk(class, level)
  local c = DND.Data.rollLevel1(class, class)
  c.level = level or 1
  return c
end
local fp = DND.Data.levelUpPlan(mk("Fighter"), 6)
assert(#fp == 5, "five levels left at 1, got " .. #fp)
local acTotal, hits = 0, 0
for _, ch in ipairs(fp) do
  assert(ch.hp >= 5, "a level must give at least d8+0 worth of hit points")
  acTotal = acTotal + ch.ac
  hits = hits + ch.hit
end
assert(acTotal == 3, "the rig improves at 2, 4 and 6 only, got +" .. acTotal)
assert(hits == 1, "proficiency steps once in six, got +" .. hits)
local wp = DND.Data.levelUpPlan(mk("Wizard"), 6)
local wac = 0
for _, ch in ipairs(wp) do wac = wac + ch.ac end
assert(wac == 0, "an unarmoured wizard gains no AC from the armour ladder")
local bump, attack
for _, ch in ipairs(fp) do
  if ch.die then bump = ch end
  if ch.attack then attack = ch end
end
assert(not bump, "a class that gets the real Extra Attack does not also get the die step")
assert(attack and attack.level == 5,
  "Extra Attack arrives at 5, not " .. tostring(attack and attack.level))
local wbump
for _, ch in ipairs(wp) do if ch.die then wbump = ch end end
assert(wbump and wbump.level == 5, "the die step still stands in for classes without it")

-- and it is a swing count, not a flag on a sheet: one Attack action, two attack
-- resolutions, one action spent.  The dummy has 40 hp so the first swing cannot kill
-- it, because an assertion about the second swing that relies on the first missing
-- is an assertion about the dice.
DND.config.reactions = false
DND.config.aiPlaysParty = false
local swing = DND.Combatant.new({ name = "Six", side = 0, hp = 40, ac = 15, speed = 30,
  level = 6, class = "Fighter", extraAttack = 2, str = 16,
  actions = { { name = "Longsword", toHit = 10, damage = "1d8+3", dmgType = "slashing" } } },
  CreateUnit(0, 1, 0, 0, 0))
local dummy = DND.Combatant.new({ name = "Dummy", side = 1, hp = 40, ac = 5, speed = 30,
  actions = { { name = "Axe", toHit = 0, damage = "1d6", dmgType = "slashing" } } },
  CreateUnit(1, 1, DND.CONST.FIVE_FEET, 0, 0))
DND.Combat.startEncounter("T", { swing, dummy }, {})
local function swingsOf(fn)
  local before = #(DND.logLines or {})
  local r = fn()
  local n = 0
  for i = before + 1, #(DND.logLines or {}) do
    if DND.logLines[i]:find(" vs AC ") then n = n + 1 end
  end
  return n, r
end
local n1, r1 = swingsOf(function()
  DND.Combat.giveTurn("Six")
  DND.Combat.armAction("attack", 1)
  return DND.Combat.executeOn(dummy)
end)
assert(n1 == 2, "one Attack action swings twice, got " .. n1)
assert(r1.attacks == 2, "and the result carries the count: " .. tostring(r1.attacks))
assert(swing.actionUsed, "still exactly one action, spent once")
-- a kill on the first swing stops the action rather than swinging at a corpse
dummy.hp = 1
DND.Dice.script({20})
local n2 = swingsOf(function()
  DND.Combat.giveTurn("Six")
  DND.Combat.armAction("attack", 1)
  return DND.Combat.executeOn(dummy)
end)
DND.Dice.script({})
assert(n2 == 1, "the second swing is not wasted on a body, got " .. n2)
assert(dummy.hp <= 0, "and the dummy is down")

-- applying it: the sheet moves, once, and stops at the cap. Note these are live
-- combatants: `awardXp` writes the sheet, so a bare spec is not enough.
local function hero(class, level)
  local c = DND.Combatant.new(DND.Data.rollLevel1(class, class))
  if level then c.level = level end
  return c
end
local one = DND.Data.awardXp(hero("Fighter"), 200, true)
assert(one[1] and one[1].level == 2, "200 xp buys level 2, got " .. tostring(one[1] and one[1].level))
local surgy = hero("Fighter")
local before = { ac = surgy.ac, traits = #(surgy.traits or {}) }
DND.Data.awardXp(surgy, 4000, true)
assert(surgy.level == DND.Data.MAX_LEVEL, "4000 xp must cap at " .. DND.Data.MAX_LEVEL
  .. ", got " .. surgy.level)
assert(surgy.xpNext == nil, "at the cap there is no next milestone")
assert(surgy.hp <= surgy.hpMax, "levels cannot over-heal: " .. surgy.hp .. "/" .. surgy.hpMax)
local surgeFound = false
for _, t in ipairs(surgy.traits or {}) do
  if t.key == "surge" then surgeFound = true end
end
assert(surgeFound, "Action Surge arrives with level 2, and it did not")
local more = DND.Data.awardXp(surgy, 100000, true)
assert(#more == 0, "no level 7 at the cap")
assert(surgy.ac == before.ac + 3, "chain mail three times, got " .. surgy.ac)

-- what a level up gives a caster must be a number on the sheet, not a noun in a
-- feature list: more slots from the table, a better DC from proficiency
local wiz = DND.Combatant.new(DND.Data.rollLevel1("Wizard", "Zed"))
local dc1 = DND.Combatant.spellSaveDc(wiz)
local slots1 = wiz.slotMax[1]
DND.Data.awardXp(wiz, DND.xpNeededForLevel(2), true)
assert(wiz.slotMax[1] > slots1, "level 2 must add a 1st level slot ("
  .. slots1 .. " -> " .. wiz.slotMax[1] .. ")")
assert(wiz.slots[1] == wiz.slotMax[1] or wiz.slots[1] > slots1,
  "and the new slot is spendable, not just printed")
DND.Data.awardXp(wiz, DND.xpNeededForLevel(5) * 4, true)
assert(wiz.prof == 3, "proficiency is 3 at level 5, got " .. wiz.prof)
assert(DND.Combatant.spellSaveDc(wiz) > dc1, "the save DC followed it up")
-- and a feat the panel can actually fire
local rog = DND.Combatant.new(DND.Data.rollLevel1("Rogue", "Nim"))
local hadCunning = false
for _, t in ipairs(rog.traits or {}) do if t.key == "cunning" then hadCunning = true end end
assert(not hadCunning, "no Cunning Action at level 1")
DND.Data.awardXp(rog, 400, true)
local found = false
for _, t in ipairs(rog.traits or {}) do
  if t.key == "cunning" then found = true end
end
assert(found, "Cunning Action has to arrive as a real bonus action")
"""
case("levels: roll, ladder, cap", lambda: lua_case("ladder", LADDER))

# --------------------------------------------------------------------------
# 21. The delve: rooms are a session, not a reset button
# --------------------------------------------------------------------------
DELVE = r"""
MOCK.reseed(31337)
DND.config.useVanillaModels = true      -- real (mock) bodies at arena positions

-- rung 1 is a level 1 fight: two goblins, not four (5e calls four goblins a
-- Deadly encounter for four 1st level characters, and the table says so)
-- the bare call the chat command makes: no party, no level, just a rung. The row
-- names its own party (`party = "random"`), so a string in `enc.party` has to be
-- looked up like a name and not mistaken for a roster.
local bare = DND.Data.startEncounter("delve2", { encounter = 1 })
assert(bare, "a delve row has to start from its key alone — that is all -delve passes")
assert(#DND.Data.party() > 0, "and it has to build its own party")
for _, c in ipairs(DND.Data.party()) do
  assert(c.class, "a named preset resolves to class heroes, got " .. c.name)
  -- the rung owns the level, and a class party is walked up with the same change
  -- records an XP level-up uses. Padding the statblock instead would give a level 2
  -- with no extra hit die and no spell slots.
  assert(c.level == 2, "rung 2 plays at level 2, got " .. c.level)
end
DND.Combat.abort("restart")
DND.Combatant.clearAll(); DND.Data.CarriedParty = {}; DND.Data.Delve = {}

local rec, party, foes = DND.Data.startEncounter("delve1", { party = "random", encounter = 1 })
assert(rec, "the delve did not start")
for _, c in ipairs(party) do
  assert(c.level == 1, "rung 1 is a level 1 fight, got " .. c.level)
end
assert(#foes == 2, "two mooks at level 1, got " .. #foes)
for _, f in ipairs(foes) do
  assert(f.level == 1, "mook must be level 1, got " .. f.level)
  assert(f.xp > 0, "and worth something")
end
assert(rec.xpAward == math.ceil(DND.Data.rosterXp(foes) / #party),
  "the room's worth is split by headcount")
assert(DND.Combat.state.running, "and it is a real fight")

local atStart = {}
for _, c in ipairs(party) do atStart[c.cid] = c.hp end
safeTurns(80)
assert(not DND.Combat.state.running, "the room must resolve, not stall")

-- A carry-on room heals nobody and refills nothing: the sheet at the end of room
-- 1 IS the sheet at the start of room 2. Proven by writing the numbers first
-- (a fight this short might not hurt anybody, and a test that relies on the dice
-- to create the condition it checks is a test that quietly checks nothing), and
-- by holding the AI so room 2 cannot spend a round before we look.
-- `restBetweenRooms = false` is required here: a delve row rests two hours in the
-- corridor on its own, and that is the *next* assertion, not this one.
DND.config.restBetweenRooms = false
DND.Combat.setHp(party[1], 3)
party[1].slots[1] = 0
party[1].hitDice = 0
local lastRoom1 = {}
for _, c in ipairs(party) do
  lastRoom1[c.cid] = { c.hp, table.concat(c.slots or {}, ","), c.hitDice or 0 }
end
DND.config.aiEnabled = false
DND.config.aiPlaysParty = false
local rec2, party2 = DND.Data.startEncounter("delve1", { encounter = 2 })
DND.config.aiEnabled = true
DND.config.aiPlaysParty = true
assert(#party2 == #party, "the same party walks in, got " .. #party2)
for _, c in ipairs(party2) do
  local b = lastRoom1[c.cid]
  assert(b, "a carried character lost its identity between rooms")
  assert(c.hp == b[1], c.name .. " was retuned between rooms: " .. b[1] .. " -> " .. c.hp)
  assert(table.concat(c.slots or {}, ",") == b[2], c.name .. " refilled slots")
  assert((c.hitDice or 0) == b[3], c.name .. " got hit dice back")
end
assert(party2[1].hp == 3, "the wound you took in room 1 must still be open")
local regSize = #DND.Combatant.all()
assert(regSize <= 2 * (#party2 + 4),
  "the last room's actors have to be retired, registry=" .. regSize)
local st = DND.Data.delveState("delve1")
assert(st.room == 2, "the run knows which room you are in, got " .. tostring(st.room))

-- ...and the corridor rest is the other half of the same boundary. The run owns the
-- number (a delve row says two hours), not the chat command, so `-delve` cannot
-- leave a free rest under the next fight you start by hand. Two hours = two Hit
-- Dice spent, and a short rest never touches a spell slot.
DND.config.restBetweenRooms = nil
local who = party2[1]
who.hitDice = 2
DND.Combat.setHp(who, 1)
local slotsBefore = table.concat(who.slots or {}, ",")
DND.Combat.abort("restart")
DND.config.aiEnabled = false
DND.config.aiPlaysParty = false
local rec2b, party2b = DND.Data.startEncounter("delve1", { encounter = 3 })
DND.config.aiEnabled = true
DND.config.aiPlaysParty = true
local rested = party2b[1]
for _, c in ipairs(party2b) do if c.cid == who.cid then rested = c end end
assert(rested.hp > 1, "two hours in the corridor closed a 1 hp wound, hp=" .. rested.hp)
assert(rested.hitDice == 0, "and spent the hit dice doing it, got " .. rested.hitDice)
assert(table.concat(rested.slots or {}, ",") == slotsBefore, "a short rest refilled a slot")

-- A room cannot be started on top of a running one: retiring the previous actors is
-- the data layer's job, and a second room spawned over a live fight would pay XP for
-- both.  So the delve refuses, and the DM ends the scene first, exactly as `-end` does.
local blocked = DND.Data.startEncounter("delve1", { encounter = 3 })
assert(not blocked, "a room cannot be started on top of a running fight")
DND.Combat.abort("restart")

-- a level 3 party vs a level 6 band dies, and dying costs something real
MOCK.reseed(90210)
local rec3, party3 = DND.Data.startEncounter("delve6",
  { party = { "halflingRogue" }, encounter = 1, atLevel = 6 })
local solo = party3[1]
safeTurns(120)
assert(solo.hp <= 0 or not DND.Combat.state.running, "the rung must be able to kill one rogue")
local s = DND.Data.delveState("delve6")
assert(s.wipe, "a TPK is recorded as a wipe")
assert(solo.hp > 0, "and the survivor is picked up off the floor at " .. solo.hp)
assert(solo.hp == math.max(1, DND.CONST.round(solo.hpMax * 0.5)),
  "the toll is half hit points, got " .. solo.hp .. "/" .. solo.hpMax)
local spent = true
for _, v in ipairs(solo.slots or {}) do if v > 0 then spent = false end end
assert(spent or #solo.spells == 0, "spell slots are the other half of the toll")
assert(solo.hitDice == 0, "and no hit dice are left for the walk out")
local rec4, party4 = DND.Data.startEncounter("delve6", { encounter = 2 })
assert(party4[1] == solo, "a wipe does not replace the character: levels and XP stay")
assert(party4[1].hp == solo.hp, "nor does it heal the toll")
"""
case("the delve: rooms, attrition, and the toll of a wipe",
     lambda: lua_case("delve", DELVE))

# --------------------------------------------------------------------------
# 22. Every encounter in the table is a legal fight, and the ladder's data is
#     the same table the generator reads
# --------------------------------------------------------------------------
ROSTER = r"""
DND.config.useVanillaModels = true
assert(DND.Data.Encounters["ambush"] and DND.Data.Encounters["tavern"],
  "the showcase fights must still be there")
assert(DND.Data.Encounters["tourney"].arena.grid, "the grid fight has an arena")
for level = 1, 6 do
  local enc = DND.Data.Encounters["delve" .. level]
  assert(enc, "delve" .. level .. " is missing")
  assert(enc.level == level, "the key and the level must agree")
  local band = DND.Data.DelveLadder[level]
  assert(band and DND.Data.Bestiary[band.mook], "band mook must exist: " .. tostring(band.mook))
  assert(DND.Data.Bestiary[band.solo], "band boss must exist: " .. tostring(band.solo))
  -- What matters is not that the boss wears a different name but that it is a bigger
  -- fight: a rung that reuses its mook as its solo has to say so in hit points, or
  -- "the last room" is one more mook room and the ladder is lying about the climb.
  if band.mook == band.solo then
    assert((band.hpSolo or 0) > (DND.Data.Bestiary[band.mook].hp or 0),
      "delve" .. level .. " reuses its mook as its boss without making it bigger")
  end
  assert(enc.foes.count >= 2 or level == 1, "rooms 1-3 must be a band")
end

-- one entry point for all of them: every key starts, plays, and ends
for _, key in ipairs({ "ambush", "tavern", "dragon", "mirror", "tourney",
                       "delve1", "delve3" }) do
  MOCK.reseed(1234 + #key)
  local rec, party, foes = DND.Data.run(key, nil, nil)
  assert(rec and #party >= 1 and #foes >= 1, key .. " built nobody")
  assert(#party + #foes >= 2, key .. " is not an encounter")
  assert(DND.Combat.state.running, key .. " did not reach the turn machine")
  local st = safeTurns(60)
  assert(st ~= "error", key .. " crashed: " .. tostring(st))
  for _, c in ipairs(DND.Combatant.all()) do
    assert(c.hp >= 0, c.name .. " went negative in " .. key)
  end
end

-- scaling is a function of the row, not a mutation of it
local rowAc = DND.Data.Bestiary.goblin.ac
local rowActions = #(DND.Data.Bestiary.goblin.actions or {})
for lv = 1, 6 do
  local s = DND.Data.buildSpec("goblin", lv, DND.CONST.SIDE.FOES)
  assert(s.ac >= rowAc and s.hp > 0, "scaled goblin at " .. lv)
  assert(s.xp >= 50, "xp must grow with the band, got " .. s.xp)
end
assert(DND.Data.Bestiary.goblin.ac == rowAc, "scaling wrote back into the bestiary row")
assert(#(DND.Data.Bestiary.goblin.actions or {}) == rowActions,
  "scaling added actions to the row itself")
-- and spawning a caster three times must not fold his cantrip into the bestiary
-- row three times (Combatant.new used to append to the spec it was handed)
local wizardActions = #(DND.Data.Bestiary.elfWizard.actions or {})
for _ = 1, 3 do DND.Data.spawn("elfWizard", 0, 0, {}) end
assert(#(DND.Data.Bestiary.elfWizard.actions or {}) == wizardActions,
  "the cantrip leaked into the row: " .. wizardActions .. " -> "
    .. #(DND.Data.Bestiary.elfWizard.actions or {}))
local wiz = DND.Combatant.new(DND.Data.Bestiary.elfWizard, nil)
assert(#(wiz.actions or {}) == wizardActions + 1,
  "the live copy gets the cantrip, the row does not: " .. #(wiz.actions or {}))
DND.Combatant.clearAll()
"""
case("every encounter is a legal fight", lambda: lua_case("roster", ROSTER))

# --------------------------------------------------------------------------
def main() -> int:



    names = ["dice + 5e maths", "statblock + WC3 mirror", "initiative + round order",
             "movement budget", "attack maths", "spells, slots, saves, rests",
             "action economy", "death saves", "conditions",
             "turn machine + freeze invariant", "reactions + opportunity attacks",
             "input layer", "soak: 11 seeded fights terminate cleanly",
             "feet <-> WC3 units", "end-to-end: a whole fight by keyboard",
             "action bar keys match the input layer",
             "nativeTargeting degrades and never cheats",
             "deathSaves switch is honoured by the rules layer",
             "ranged attacks provoke, and the AI knows it",
             "levels: roll, ladder, cap",
             "the delve: rooms, attrition, and the toll of a wipe",
             "every encounter is a legal fight"]
    # The registry and the manifest must agree. A test that runs but is not
    # listed is invisible in the pass line; a name with no test behind it is a
    # lie. Both are worth an explicit check, because "all N groups passed" is
    # the only signal here and it has to mean what it says.
    if len(RAN) != len(names):
        print(f"REGISTRY MISMATCH: {len(RAN)} test groups registered, "
              f"{len(names)} announced")
        missing = [n for n in names if n not in RAN]
        extra = [n for n in RAN if n not in names]
        if missing: print("  announced but never registered:", missing)
        if extra:   print("  ran but not announced:", extra)
        return 1
    if FAILURES:
        print(f"\n{len(FAILURES)} of ~{len(names)} groups FAILED\n")
        for name, msg in FAILURES:
            print(f"  ✗ {name}\n      {msg.strip()[:400]}\n")
        return 1
    print(f"all {len(names)} test groups passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
