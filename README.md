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
