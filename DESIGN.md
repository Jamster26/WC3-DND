# DESIGN — porting D&D 5e onto a real-time RTS engine

Everything here is derived from the shipped code and the verified native list (`common.j` /
`Blizzard.j` from the current game, fetched and grepped rather than recalled).

---

## 1. What WC3 actually gives you, and what it refuses to

| You want | WC3 has | The gap |
|---|---|---|
| end the turn | nothing | no turn concept at all |
| pause combat | `PauseGame(bool)` | single-player menu semantics; useless for authored flow |
| stop one unit acting | `PauseUnit`, `SetUnitPathing` | works, but does **not** stop its attack if it is already winding up |
| stop real damage | `BlzSetUnitWeaponBooleanField(u, UNIT_WEAPON_BF_ATTACKS_ENABLED, idx, false)` | per-weapon, runtime, no Object Editor — the keystone |
| a command card per turn | no | the card is baked into unit object data; you cannot author abilities at runtime |
| a grid | 64-unit tiles | no square-occupancy concept, no "one creature per square" |
| line of sight | `IsUnitVisible` | no terrain ray query |
| dice | `GetRandomInt` | no d20 concept; `math.random` exists but is the wrong tool for a synced game |
| key input | `BlzTriggerRegisterPlayerKeyEvent` + `BlzGetTriggerPlayerKey` | **synced by the engine**, so a keypress is a legal game command |
| custom UI | `BlzCreateFrameByType` against stock templates | works with no FDF/TOC; `BlzFrameSetCallback` does **not** exist, so clicks go through `BlzTriggerRegisterFrameEvent` + `FRAMEEVENT_CONTROL_CLICK` |
| arbitrary object data at runtime | no | object data is compiled at map save; runtime code can only *read/write fields*, not create abilities |

Two of those rows dictated the whole architecture.

**"No runtime ability creation"** is why the input layer is keys + clicks + chat rather than the
native command card. The tempting design — grant a "Strike" ability whose cast-range *is* the
creature's reach, and let WC3's targeting cursor do everything — needs `AATK`/`AMOV` to exist in
the Object Editor. So it is supported but optional:

```lua
DND.config.nativeTargeting = true    -- grant AMOV/AATK, right-click becomes the targeting UI
```

…with the keys-and-clicks path as the always-working default. The engine never *requires* your
object data, which is what makes it droppable into a blank map. `Combat.grantTargetingAbility` /
`revokeTargetingAbility` arm and disarm it, and a test asserts the whole contract: granted while
armed, revoked on commit/cancel/end-turn, outcome identical either way, and a missing rawcode
degrades instead of raising.

**"No grid"** is why movement is Euclidean with 5 ft snapping (`w3.snap`) rather than an attempt to
impose squares. Squares would need a position-occupancy table, push-out rules, and an AI that
thinks in them; distance checks give the same tactical shape (reach, threat, disengage, closing)
for free, and if you decide you want a grid, exactly one function changes.

---

## 2. Scale, in one box

```
1 tile          = 64 units      (WC3 terrain)
1 tile          = 10 ft         (declared)
1 ft            = 6.4 units     C.UNITS_PER_FOOT
1 round         = 6 s           C.ROUND_SECONDS
1 square step   = 32 units      C.FIVE_FEET  (== a 5 ft reach, so they match)
speed(ft/round) -> u/s          ft * 6.4 / 6      (30 ft -> 32 u/s)
hp              -> WC3 hp       hp * 4            (C.HP_SCALE, display only)
ac              -> WC3 armour    ac - 10           (BlzSetUnitArmor)
reach(ft)       -> weapon range reach * 6.4       (ua1r, SetUnitAcquireRange for threat)
```

`HP_SCALE = 4` is not decoration: at 1:1 a longsword crit ends a level-1 wizard between two
frames, and the death/save/damage hooks fire so fast that the log reads as noise. The Lua `hp`
field is always the true D&D number; the unit's bar is a scaled mirror.

The 6.4 constant is asserted in the test suite at the engine seam, because if it drifts, *every*
"can that creature reach me" decision in the game becomes quietly wrong:

```lua
assert(math.abs(u.speed - 32) < 0.01)   -- 30 ft/round == 32 u/s, checked after sync()
```

---

## 3. The turn machine

Event-driven, not polled. There is no game-loop timer anywhere; a "tick" happens when a key is
pressed, when a click lands, or when the AI callback returns. That removes an entire category of
race conditions and, in a networked port, all desync surface.

```
startEncounter
   └► rollOrder (d20 + DEX, ties by DEX then d100)
        └► nextTurn ──► Turns.next (skip dead / downed / incapacitated)
             └► beginTurn(cbt)
                  ├─ freeze everything else
                  ├─ reactionTaken resets only at the START OF YOUR ROUND
                  ├─ movementLeft = speed; actionUsed/bonusUsed = false
                  ├─ prone → stand, cost half speed
                  ├─ skipTurn condition? → death save / duration tick → endTurn
                  ├─ party side   → phase=ACTION, wait for input
                  └─ invader side → AI.takeTurn(cbt, endTurn)
             └► endTurn(cbt)
                  ├─ condition save rolls (frightened, stun, restraint…)
                  ├─ freeze unit, clear temp flags (dodge, shield, readied)
                  └► nextTurn …  until checkEnd() sees a side empty
```

The active creature is the only unfrozen unit on the map. Its attacks still can't deal WC3 damage
(`ATTACKS_ENABLED = false`), so even a bug in the freeze logic cannot produce real-time combat —
it can only produce a unit that cannot act, which is a much nicer failure.

### Action economy

`dnd_combat.lua` owns the purse strings; `dnd_resolve.lua` owns the maths. `Resolve.attack`
deliberately does **not** check `actionUsed`, because "is this legal right now" is turn state, not
rule state. The split is what lets the AI deliberately over-arm a swing so the rules can refuse it
out loud instead of the AI silently standing still — an early version of this AI never attacked at
all, and hid it behind a score function that rated "walk 30 ft" worse than "stand here", for every
creature, forever.

---

## 4. Reactions need a pending object, not a coroutine

A D&D reaction interrupts the resolution of another creature's action. So an attack is resolved in
two phases with an explicit seam:

```lua
local pending = Resolve.attack(attacker, target, action)  -- roll to-hit, compute damage, collect
                                                          -- the defender's legal reactions
pending.reactionWindow = { {key="attack", ...}, {key="shield", ...} }
-- ... the engine may now hand control to the defender, across several callbacks ...
Resolve.commit(pending)                                   -- apply damage / log the miss
```

Because `pending` is a plain table, the delay can be arbitrarily long and survive any number of
prompts. Two things this bought:

- **Shield** rerolls the attack in place: `takeReaction(cbt, "shield", pending)` bumps
  `pending.ac`, re-rolls `pending.roll` against the new AC and recomputes damage — the swing's
  outcome is genuinely rewritten after the roll, exactly like the spell.
- **Opportunity attacks on movement** fire from inside `Combat.move`, mid-move, which is where 5e
  puts them. The mover's *old* and *new* positions are both measured, so "you left the reach" is a
  real transition and not an approximation.

Prompt routing is keyed on **who is defending**, never on whose turn it is. My first version asked
"whose turn is it?" and auto-fired every invader's reaction against the player — the one case
where a prompt matters most. The rule is simply: a party-side defender gets asked, everyone else
resolves greedily.

Prompts are queued: leaving two guards' reach gives you one prompt, then the second drains
(`Combat.drainQueuedOpportunities`) after the first is answered, because a creature has one
reaction per round.

---

## 5. Spell slots, and why they aren't ability charges

WC3 charges would have been the "authentic" choice — `BlzSetUnitAbilityCharges` for slots, a
cooldown per level, and the command card shows it for you. I kept slots in Lua instead:

- slots are **per level**, and a short rest restores 1st/2nd only, and a wizard's Arcane Recovery
  restores a specific subset. Cooldown/charge UI can't express "level ≤ 2 refill" without lying;
- upcasting (`fireball` +1d6 per slot above 1st) needs to *know* the slot spent, so the rules layer
  has to own the number anyway;
- a cantrip is "level 0, cost nothing", which a charge system models badly.

`cbt.slots[lvl]` and `cbt.slotMax[lvl]` are the truth; the UI renders them as text
(`1st (3/4)`). Mirroring them into ability cooldowns for flavour is ~10 lines in
`Combatant.sync` if you want the bar to drain — deliberately left as an exercise so the engine has
no dependency on object data existing.

---

## 6. Conditions are data

`dnd_const.C.CONDITIONS` is a table of *hooks the rules layer reads*:

```lua
stunned = { skipTurn = 1, autoFail = { str = 1, dex = 1 }, incapacitated = 1, skipReaction = 1 },
prone   = { meleeAdvVs = 1, attack = -2, speedZero = 1, standCostHalf = 1 },
```

`beginTurn` reads `skipTurn` and `standCostHalf`; `speedUnits` reads `speedZero`/`speedHalf`;
`situationalAdv` reads `meleeAdvVs`; `saveBonus` consults `autoFail`; `conditionSaves` consults
`C.SAVEABLE` to decide which save ends it. Adding "paralyzed"-grade status to a new condition is
therefore one table row, not four scattered `if`s.

The `C.SAVEABLE` / `C.CONDITIONS` split also means the AI can be trusted not to break rules: it
uses the same `speedUnits` (so a grappled ogre genuinely cannot close) and the same
`situationalAdv` (so it prefers prone targets) without knowing anything about conditions.

---

## 7. The AI is a player with a keyboard

`DND.ai` calls `Combat.move`, `Combat.armAction`, `Combat.executeOn`, `Combat.useBonus` — the
public input-level API. There is no `AIDamage()` and no privileged path. Consequences:

- the AI provokes opportunity attacks, spends real spell slots, obeys its own budget, and can be
  tested by driving it;
- scoring is closed-form so a 12-creature brawl evaluates cheaply: `expected = p(hit) × avg`,
  `+400` for a kill, `-threatCost` for stepping into someone else's reach, `×(1 - p(save)×0.5)`
  for save-half effects;
- positioning samples a fan of rays toward the target, clipped to *both* the movement budget and
  the target's reach, plus the target's reach ring, plus "hold position". Getting that clipping
  wrong is how the AI concluded that walking was always worse than standing, in an empty field,
  against an enemy 120 ft away — and then the fight never ended.

One rule worth keeping: if nothing is legal, **swing anyway and let the rules refuse it**. A silent
`return false` produces a stalemate; a refusal produces a log line that tells you why.

---

## 8. Death, and why monsters may skip it

`Resolve.applyDamage` floors `hp` at 0 and calls `enterDowned`, which sets `downed` (not `dead`).
Death saves run at the start of the sufferer's turn — a nat 20 restores 1 hp, a nat 1 counts as two
failures, damage while at 0 counts as two failures, 3 successes = stable. `DND.config.deathSaves =
false` makes anything on the invader side die outright at 0 hp, which is the DMG-suggested shortcut
for mooks and keeps a 4-vs-4 brawl at "a few rounds" instead of a foregone conclusion.

`Combat.checkEnd` counts living per side, so the fight ends the instant a side is empty — with death
saves on, a downed-but-not-dead party member still counts, and the victory screen does not arrive
while someone is rolling saves. That asymmetry is intentional: the party gets its last save.

---

## 9. Levels are data, and the corridor rest

The delve was added *underneath* the rules layer, and that is the one structural fact worth knowing
before you touch it: `dnd_combat.lua` gained exactly two things — an `S.encounter` record that rides
along to the end of the fight, and one call, `DND.afterCombatHook(xp, rec)`, in `checkEnd`. It has no
idea what a room is, what a wipe costs, or that XP exists. Everything else lives in `dnd_data.lua`.

**One level knob, read the same way on both sides.** `local level = opts.atLevel or enc.level or 1`:
a chat command or a script may force a level, otherwise the encounter row decides (`-delve 6` is a
level 6 fight because the row says so). It used to be `enc.level or opts.atLevel`, which the party
read one way and the foes another — `-delve 6` then meant "level 6 mooks, level 3 heroes" and nobody
noticed, because both sides looked self-consistent in the log.

**Monsters are padded; characters are levelled.** Two different growth maths, deliberately:

- `Data.buildSpec(key, level, side)` scales a *statblock* by `Data.LEVEL_STATS` (hp ×(1+0.35·bonus),
  AC, to-hit, damage, and an extra damage die every 4 levels), never downward — `s.level` is
  `math.max(level, base.level)` so a row printed at level 3 asked to fight at level 1 keeps its level
  3 numbers *and its label*. A monster's CR bump is not a class level. The consequence for the ladder
  is worth knowing before you retune it: `foes.mookLevel` cannot make an orc reaver *weaker* than the
  level 5 it is printed at, so the deep rungs are balanced with `count` and `hpSolo`, and a soak that
  repeats itself exactly after a `mookLevel` edit is reporting the dial, not the fight.
- A class party is walked up with `levelUpPlan` + `applyLevelUp` — the same change records the XP
  ladder uses — so a level 6 fighter from `-delve 6` and a level 6 fighter you *earned* are the same
  sheet: hit dice per level, `C.SLOT_TABLE` slots, `prof` 3, Action Surge at 2, Extra Attack at 5. Padding the party
  instead gives you a "level 6" with one hit die and a +11 damage bonus nobody earned, which is how
  the first version of this section was wrong.

`levelUpPlan` returns *descriptions*; `applyLevelUp` moves *numbers*. The plan is the only source of
truth, so the chat line and the sheet cannot disagree, and the one invention is stated in the code
that implements it: a class with `extraAttack = 5` in `Data.LEVEL_PROGRESS.byClass` gains
`c.extraAttack = 2`, and `Combat.executeOn` resolves the Action that many times through
`Resolve.attack` + `Resolve.commit`, while classes without it get `Data.WEAPON_DIE_STEP = { at = 5,
sides = 4, cap = 12 }` growing the weapon die instead (`cap` stops level 10 inventing a d16) — and
`levelUpPlan` suppresses the die step for any class that has the real thing, so the two can never
stack. Both are fields on the plan, which is why the log line and the sheet say the same thing.
A monster with two natural weapons writes `extraAttack = 2` on its row and gets the same loop,
because `Combatant.new` copies it like any other spec field. Cantrips are excluded by a flag on the
attack itself — the first version rewrote Fire Bolt's `1d10` down to the wizard's `1d8` weapon die.
Save DCs need no code at all: `Combatant.spellSaveDc` is `8 + prof + mod`, so moving `prof` moves the
DC, which is why `applyLevelUp` sets `c.prof` and never `c.spellDc` (an earlier draft set a `spellDc`
field nothing read, and the cleric's DC sat on its INT modifier because `Combatant.new` had not been
copying `spec.spellAbility` at all).

**The order inside `Data.startEncounter` is the design.** Refuse if a carried run is still being
played → retire the previous room's actors → *then* the corridor short rest → stand the carried party
on the new room's spots → build and spawn the foes → `Combat.startEncounter` with `rest = false`. Two
of those are load-bearing:

- The rest happens **before** the foes exist and **after** the last room is retired, so it can heal a
  party that has already paid for the room it just cleared, and cannot heal one it has not fought yet.
- `opts.rest = false` is the engine's switch for "this is not a fresh day": it is what stops
  `Combat.startEncounter` from handing everyone their max spell slots and hit dice. Do not overload it
  with a duration — the delve's own `corridorRest = 2` is a separate field, and when they briefly shared
  the name `rest`, every delve room silently refilled, which is the difference between a delve and a
  series of unrelated fights.

**A room pays what its survivors are worth, per head.** `checkEnd` sums the XP of foes *alive at the
end*, divides by `S.encounter.partyCount` (heads, not survivors — dividing by the living is how a
party that lost two heroes gets a *bonus* for it), and hands the pair to the hook. `Data.afterVictory`
then decides everything: half on an aborted victory, nothing on a wipe, the ladder advanced per
character, `xpTrack = false` short-circuits the whole thing in both `awardXp` and the log line, and a
wipe charges `hp = max(1, round(hpMax/2))` with zero slots and zero hit dice. The engine never learns
that last sentence exists.

---

## 10. Extension points, in the order you will probably want them

1. **New creature** — one table in `Data.Bestiary`. `Combatant.new` derives mods, prof, slots,
   action ordering, hotkeys and DCs; `sync` mirrors it. Run `tools/all.py` and the gates check your
   dice strings actually parse (`C.parseDice` returns `nil` on junk on purpose, so `"1d8 3"` — a
   real typo class — fails at boot, not in a damage roll).
2. **New condition** — a row in `C.CONDITIONS` plus, if it is savable, `C.SAVEABLE`.
3. **New spell** — a table in `Data.Spells`. Four shapes are handled: `save`, `attackRoll`,
   `aoe`, and auto/no-save. Anything with `onHit`/`selfEffect` gets a callback with
   `(caster, target, res)`.
4. **New action type** — add a branch in `Combat.useAction`, a key in `dnd_input`, and a row in
   `ui.showActions`. All three are checked by the "action bar advertises only live keys" test, so
   you cannot ship a dead button.
5. **Real object data** — `python3 tools/gen_data_js.py`, then compile the emitted
   `//! externalblock` lines with jassNewGenPack's ObjectMerger (or paste into a JASS header and
   save the map). Sets per-unit `uhpm`, `umvs`, `ud2a`, `ua1r`, and `1d0+0` weapon damage; the
   engine's numbers stay authoritative, so a mismatch degrades to cosmetic and cannot desync your
   damage.
6. **True grid combat** — quantise in `w3.snap`, block movement with pathing-blocking doodads, and
   replace `Resolve.opportunitiesAt`'s distance test with "did the occupied square change".
7. **Hot-seat for two humans** — the pieces are there (synced key events, per-side prompts, one
   input path). What you must add is turn ownership (`S.activePlayer`) and the removal of the
   single-player menu-pause cheat.

---

## 11. Bugs the harness caught that a playtest would not

Worth recording, because they are the argument for the mock engine:

- **`BlzSetUnitDice*` was a dead end** — no such natives exist in `common.j`. Found by checking
  names against the real file before writing code, not by a crash.
- **`C.parseDice` rejected `"1d8+3"`** — a sign was only allowed at position 1, so *every* damage
  string in the bestiary failed and the engine rolled a `nil` template. Found by the first real
  fight, because a test asserted `crit.damage == 10` and got a crash instead.
- **Opportunity attacks attacked themselves.** `Resolve.takeReaction` swung at
  `pending.attacker`, which in the opportunity flow *is* the reactor. The log read "Guard misses
  Guard" — funny, and completely invisible in a live game where it looks like a bad roll.
- **`beginTurn` refilled every defender's reaction.** Clearing `reactionTaken` at the start of each
  *turn* instead of each *round* meant unlimited free attacks against anyone who walked.
- **Prone melee advantage was simply missing**, while the ranged -2 against a prone shooter was
  implemented — the classic half-a-rule. (Same story for disadvantage on ranged attacks made from
  inside a threat zone: implemented after the first real log review showed a goblin shooting from
  30 ft and strolling away unpunished. The fix went into `situationalAdv`, which the AI scores
  through, so it took one function and the AI got smarter for free.)
- **Damage modifier double-dip**: `"1d12+4"` in a statblock *plus* the engine's STR bonus.
- **Two `pairs()`-mutation crashes** that surfaced as `attempt to index local 'cbt' (a nil value)`
  in code three frames away from the loop that deleted the key. Now a dedicated gate, because both
  times I lost 20 minutes staring at the wrong function.
- **The action bar and the input layer had already drifted** (`R`/`T`/`H`/`Y` meant different
  things in each file, and `T` was double-bound to Stabilise and a debug toggle). That is the
  argument for the test that asserts the two agree, rather than trusting a table of keys.

The level/delve layer added its own list, all of them found the same way:

- **Carrying the party as a snapshot of numbers** re-spawned combatants from bestiary rows, so every
  level, class feature and `xpEarned` silently evaporated between rooms and XP was awarded to ghosts.
  The fix is to carry the objects and rebuild only the foes (`Combatant.compact` exists for that).
- **`Data.spawn` dropped `spec.spellAbility`**, so `spellSaveDc`'s `8 + prof + mod` used Intelligence
  for a cleric, and no amount of "higher DC at level 5" writing could show up in a roll.
- **`awardXp` divided the room's worth by the number of survivors** — a party that lost half its
  heroes was paid double per head for losing them.
- **A trait's `0/0` poisoned a unit handle**: the orc's Aggressive charge divides by the distance to
  its target, and a target in the orc's own square made that zero. The result was `SetUnitX(u, nan)`,
  i.e. a creature that can never be moved, targeted or looked at again — and `nan <= 0.01` is false in
  Lua, so the existing "already there" guard waved it through. `Combat.move` now refuses a
  non-finite destination, and the guard is written `not (d > 0.01)` so it catches nan by construction.
- **`autoEndTurn` almost ate Extra Attack.** The second swing runs after `resolvePending`, which
  schedules the turn's end on a timer — instantaneous under `testMode`. So the action is bracketed by
  `cbt.flags.inAction`, and `maybeAutoEnd` refuses while it is up. In the editor the timer is 0.8 s and
  nobody would ever have noticed; in the harness the Fighter would attack once and the feature would
  have shipped as a flag on a sheet.
- **The soak repeating its own numbers exactly, twice.** Not a broken soak: `mookDown` on rows whose
  printed level was already higher is a no-op under the never-scale-down rule, and the actual problem
  was the boss (`solo = "youngDragon"` — 178 hp and a 16d6 breath, a level 11 monster at the top of a
  ladder that ends at 6). The fix is `hpSolo` on the deep rungs; the lesson is that a measurement which
  refuses to move is telling you the lever you pulled is disconnected, and the README had been written
  from the design intent (an "80 hp Young Bronze Dragon") instead of from `Data.DelveLadder`.
- **A delve row naming its party (`party = "random"`) built no party at all**, because only
  `opts.party` went through the preset lookup and a string in `enc.party` was mistaken for a roster.
  It reached the `-delve` command and not a single test, because every test passed a party by hand —
  which is why the delve group now starts a rung with `{ encounter = 1 }` and nothing else.

Every one of those was found by *running the real modules against a mock WC3* — in under two
seconds, deterministically, without launching the editor.
