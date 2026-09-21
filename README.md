# jgrp-skills

A skill / XP framework for **qb-core**, backed by MySQL via **oxmysql**.

Skills are defined entirely in `config.lua` — each with a label, a level cap, and an XP
curve. Progress is stored per **citizenid**, so each character on an account levels
separately.

## Install

1. Import `sql/jgrp_skills.sql` into your database.
2. Drop the resource into your resources folder and `ensure jgrp-skills` in `server.cfg`
   (after `qb-core` and `oxmysql`).
3. Define your skills in `config.lua`.

## Configuring skills

```lua
Config.Skills = {
    mining = {
        label = 'Mining',
        maxLevel = 50,
        xpPerLevel = 250,                      -- flat: every level costs 250
    },

    fishing = {
        label = 'Fishing',
        maxLevel = 30,
        xpPerLevel = function(level)           -- or a curve
            return 100 + ((level - 1) * 75)
        end,
    },
}
```

`xpPerLevel` is the XP needed to go from `level` to `level + 1`. Everyone starts at
`Config.StartingLevel` (**0**) with 0 XP.

A row is written for **every configured skill** when a character loads, so a new
character exists in `player_skills` at level 0 with 0 XP rather than having no rows at
all. A skill added to the config later gets its rows created on each player's next load.
Nothing has to grant XP first for a skill to exist.

Because the default curve is `100 + (level - 1) * 75`, the very first level (0 -> 1)
costs **25 XP** rather than 100 -- a deliberately gentle first step. Change
`baseXpPerLevel` if you would rather it were flat.

Other options:

| Option | Default | Effect |
| --- | --- | --- |
| `Config.StartingLevel` | `0` | Level a character is created at, and what an untrained skill reports. Rows are created on load. |
| `Config.AllowDeLevel` | `true` | Whether `RemoveXP` can drop through levels. When off, XP loss clamps at 0 in the current level. |
| `Config.NotifyOnLevelUp` | `true` | Show a qb-core notification on level up. |

Lowering a `maxLevel` or removing a skill is safe: out-of-range rows are clamped when
they load, and rows for skills no longer in the config are ignored.

## Server exports

Every export takes a `target` that is either a **player server id** (number, must be
online) or a **citizenid** (string, works offline).

```lua
local Skills = exports['jgrp-skills']

Skills:AddXP(source, 'mining', 50)
Skills:RemoveXP(source, 'mining', 25)
Skills:SetSkill(source, 'mining', 10, 100)   -- level 10, 100 xp into it
Skills:SetLevel(source, 'mining', 10)        -- level 10, 0 xp
Skills:ResetSkill(source, 'mining')          -- omit the skill to wipe all of them

Skills:GetSkill(source, 'mining')            -- single skill, see shape below
Skills:GetSkills(source)                     -- every configured skill, keyed by name
Skills:GetLevel(source, 'mining')
Skills:GetXP(source, 'mining')
```

`GetSkill` and the mutating calls return:

```lua
{
    skill          = 'mining',
    level          = 4,
    xp             = 120,     -- xp banked toward the next level
    maxLevel       = 50,
    xpForNextLevel = 250,     -- nil at the cap
    atMaxLevel     = false,
}
```

`AddXP` also sets `levelsGained` and `RemoveXP` sets `levelsLost`. All of them return
`nil` if the skill is unknown, the amount isn't a positive number, or the target can't be
resolved.

A single `AddXP` call rolls over as many levels as it covers. XP earned at the cap is
discarded rather than banked.

## Server events

The same calls are available as events, for code that would rather not hold an export
reference:

```lua
TriggerEvent('jgrp-skills:server:AddXP', source, 'mining', 50)
TriggerEvent('jgrp-skills:server:RemoveXP', source, 'mining', 25)
TriggerEvent('jgrp-skills:server:SetSkill', source, 'mining', 10, 100)
TriggerEvent('jgrp-skills:server:SetLevel', source, 'mining', 10)
TriggerEvent('jgrp-skills:server:ResetSkill', source, 'mining')
```

These are registered with `AddEventHandler`, **not** `RegisterNetEvent` — a client can't
trigger them, so XP can only ever be granted server-side.

To react to a level up anywhere on the server:

```lua
AddEventHandler('jgrp-skills:server:LevelUp', function(citizenid, skillName, newLevel, levelsGained)
    -- e.g. unlock something, pay a bonus
end)
```

## Client exports

The client keeps a read-only mirror of the local player's skills, pushed by the server, so
these are instant and don't hit the network:

```lua
local Skills = exports['jgrp-skills']

Skills:GetSkill('mining')      -- same shape as the server's GetSkill
Skills:GetSkills()
Skills:GetLevel('mining')
Skills:GetXP('mining')
Skills:GetProgress('mining')   -- 0.0 .. 1.0 through the current level, 1.0 at the cap
```

And for UI or effects on level up:

```lua
RegisterNetEvent('jgrp-skills:client:LevelUp', function(skillName, newLevel, levelsGained)
    -- play a sound, flash a bar, ...
end)
```

## Checking your skills in game

There is no UI yet. `/skill_debug` lists every configured skill with its level,
XP and progress, printed to chat **and** to the F8 console so it can be copied
out:

```
Cooking      Level 2   90 / 175 xp  (51%)
Crafting     Level 0   12 / 25 xp  (48%)
Drug Sales   Level 7   410 / 550 xp  (74%)
```

A skill at its cap shows `Level 100  (MAX)` instead of a fraction, since there
is no next level to work toward.

It reads the **client's local mirror**, not the server, so it is instant and
costs no network round trip — and it shows exactly what the client believes,
which is what you want when the question is "is my client actually in sync?".
A skill listed as `not synced` means the mirror has not arrived yet, not that
the skill is unknown; the server pushes every configured skill on load.

## Telling you when you earn

Every XP award notifies the player — `+14 Thieving xp` — because the framework
is the one place that knows about all of them. A resource that awards XP gets
this for free and does not have to remember to say so.

| Option | Default | Effect |
| --- | --- | --- |
| `Config.NotifyOnXP` | `true` | Notify on every gain, not just a level up. |
| `Config.NotifyXPThreshold` | `1` | Ignore gains below this. Raise it to keep a trickle quiet. |
| `Config.NotifyDelay.xp` | `250` | Hold the XP line back this many ms. |
| `Config.NotifyDelay.levelUp` | `600` | Hold the level-up line back this many ms. |

### Why the notifications are staggered

A crime fires three messages within milliseconds: the XP gain, a level up, and
its own result line. The first two are sent from inside the awarding resource's
`Complete()`, which runs **before** that resource sends its result — so
unstaggered they arrive in the wrong order, with the detail ahead of the
headline.

It used to be worse than an ordering nit. **`sofy-notifications` gave every
notification of the same type the same DOM id** (`colorsentsuccess`) and hid
the previous one on arrival, so of those three `success` messages only the last
reached the screen — which is why XP gains and level ups appeared to do nothing
at all through 2026-09-20. Fixed in that resource on 2026-09-21 (unique ids,
nothing hidden on arrival; see the `LOCAL FIX` comment in its `scripts.js`).

The stagger is no longer load-bearing, but the reading order is better for it.
Set either delay to `0` to fire immediately.

Only **earning** notifies. `RemoveXP` and `SetSkill` stay silent: losing XP is
usually a punishment the resource taking it has already explained, and an admin
setting a level is not an achievement.

For a UI that wants the raw event:

```lua
RegisterNetEvent('jgrp-skills:client:GainedXP', function(skillName, amount, entry, boost)
    -- entry carries the level and banked xp after the award.
    -- boost is { multiplier, label } when one applied, nil otherwise --
    -- `amount` is already boosted, so this is only the reason why.
end)
```

## XP boosts, and bonus weekends

One multiplier, applied inside `AddXP` — which is the single funnel everything
goes through, both the exports and the `jgrp-skills:server:AddXP` event. So a
boost set here reaches fishing, drug sales, petty crime and anything added
later **without one line changing in any of them**.

The boosted figure is what the player is told: a double-XP weekend reads as
`+24 Thieving xp  (2x Double XP Weekend)`, not `+12` and a quiet lie.

### The bonus weekend

`Config.Boost.Schedule` ships **empty**. Uncomment this and restart:

```lua
Schedule = {
    { days = { 'fri', 'sat', 'sun' }, from = '00:00', to = '23:59',
      multiplier = 2.0, label = 'Double XP Weekend' },
},
```

| Field | Effect |
| --- | --- |
| `days` | `'sun'`…`'sat'`. Omit for every day. |
| `from`, `to` | `'HH:MM'`, inclusive at both ends. |
| `multiplier` | What XP is multiplied by while it is open. |
| `skills` | Optional list of skill names. Omit for all of them. |
| `label` | What the announcement calls it. |

**A window where `from` is later than `to` wraps past midnight**, and `days`
then means the day it *starts* on. Friday 18:00 → 02:00 is one entry that runs
into Saturday morning, not two:

```lua
{ days = { 'fri' }, from = '18:00', to = '02:00',
  multiplier = 2.0, label = 'Friday Night Double XP' },
```

This is the part worth getting right, so it has tests: 15 cases covering both
edges of a plain window, both edges of a wrapped one, the day-before rule, and
a wrapped window with no `days` at all.

### Which clock

`Config.Boost.UseUTC` picks between UTC and the server box's local time.
**Decide it before you write a schedule.** txAdmin rotates its logs at midnight
UTC, which is 18:00 on this box — the two are six hours apart, and a window
written against the wrong one opens at the wrong time. UTC is safer if your
players are spread out; local is friendlier if they are not.

### The other knobs

| Option | Default | Effect |
| --- | --- | --- |
| `Config.Boost.Enabled` | `true` | Off means XP is awarded exactly as before any of this existed. |
| `Config.Boost.Multiplier` | `1.0` | The always-on rate. This is the knob for a permanent change. |
| `Config.Boost.Skills` | `{}` | Per-skill overrides of `Multiplier`. |
| `Config.Boost.Stack` | `'highest'` | How a window, the base rate and a manual boost combine. |
| `Config.Boost.Announce` | `true` | Tell everyone when a window opens and closes. |
| `Config.Boost.Command` | `true` | Register `/xpboost`. |
| `Config.Boost.CommandPermission` | `'admin'` | The ace needed to *set* one. |
| `Config.Boost.DefaultMinutes` | `60` | How long `/xpboost <n>` lasts with no duration given. |

**`Stack` defaults to `'highest'` on purpose**: nothing compounds, so a 2x
weekend plus a 2x admin boost is still 2x. `'multiply'` makes that 4x, which is
how you accidentally ship 8x.

A multiplier below 1.0 works and is honoured — `'highest'` seeds from the base
rate rather than from 1.0, so a deliberate `Multiplier = 0.75` is not quietly
floored back up to normal.

### `/xpboost`

```
/xpboost                  what is running, per skill      -- anyone
/xpboost 2                2x everything for an hour       -- admin
/xpboost 2 120            2x everything for two hours     -- admin
/xpboost 2 120 fishing    2x fishing only, for two hours  -- admin
/xpboost 2 0              2x until the resource restarts  -- admin
/xpboost off              clear it                        -- admin
```

Reading is open to everyone; setting needs `Config.Boost.CommandPermission`.
The server console counts as admin, because it is already the server.

**Leaving the duration off gives you an hour**, not forever —
`Config.Boost.DefaultMinutes`. A boost you have to remember to turn off is one
you will forget to turn off, so the indefinite version has to be asked for
explicitly with a `0`.

**A manual boost is in memory and dies with a restart** on top of that,
deliberately — a forgotten 5x should not become somebody else's mystery next
week. Scheduled windows are config and survive.

The `SetBoost` export is the programmatic route and does **not** apply the
default: `minutes` is nil there means indefinite, because a caller passing nil
has said so on purpose rather than just not typing it.

### Rounding

The result is rounded half up and then floored at 1, because `AddXP` refuses
anything below 1 and a fractional result must never silently swallow an award.
**A multiplier of 0 is therefore not a way to switch XP off** — use
`Config.Boost.Enabled = false`.

### For a UI

```lua
-- server
local multiplier, label = exports['jgrp-skills']:GetBoost('thieving')

-- set one from another resource (multiplier, minutes, skill, label)
exports['jgrp-skills']:SetBoost(2.0, 120, nil, 'Launch Weekend')

-- client: fired to everyone when a window opens or closes
RegisterNetEvent('jgrp-skills:client:BoostNotice', function(data)
    -- data.open, data.label, data.multiplier, data.skills
end)
```

`AddXP` also returns `boost` and `boostLabel` on its result table.

## Notifications

Every notification the resource shows goes through one `Notify(message, notifyType, data)`
function at the top of `client/main.lua`. Nothing else calls a notification API directly,
so that function is the only place to change when you swap frameworks — replace its body
with your ox_lib / okokNotify / custom NUI call.

It ships defaulting to qb-core's built-in notification. `data` carries the raw context
behind the message (for a level up: `event`, `skill`, `label`, `level`, `levelsGained`), so
a framework that builds its own title/icon/duration doesn't have to parse `message`.

Set `Config.NotifyOnLevelUp = false` to suppress level-up notifications entirely without
touching the function.

## Persistence

Writes are write-through: every change is upserted immediately, so nothing is lost on a
crash and there is no save loop to tune. On top of that, `ensureSkills()` creates any
missing rows when a player loads, so a character's full skill set is always present in
the database rather than being implied by its absence. Online players' skills are cached
in memory and served from there; lookups by citizenid for offline players read the
database directly.
