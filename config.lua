local BASE_MAX_LEVEL = 100

Config = {}

--- Level every skill starts at. A character who has never trained a skill is
--- created at this level with 0 XP, and a row is written for them on load --
--- see ensureSkills() in server/main.lua -- rather than the skill only coming
--- into existence the first time something touches it.
---
--- Note the default XP curve is `100 + (level - 1) * 75`, so the very first
--- level (0 -> 1) costs 25 XP rather than 100. That is a deliberately gentle
--- first step; change baseXpPerLevel if you would rather it were flat.
Config.StartingLevel = 0

--- When true, RemoveXP can drop a player back down through levels.
--- When false, XP loss is clamped at 0 for the current level.
Config.AllowDeLevel = true

--- Show a qb-core notification to the player when a skill levels up.
Config.NotifyOnLevelUp = true

--- The default XP curve. Declared before Config.Skills because the table below
--- reads it by value -- a `function baseXpPerLevel` further down the file would
--- still be nil at the point the table is built.
local function baseXpPerLevel(level)
    return 100 + ((level - 1) * 75)
end

--- Skill definitions.
---
--- maxLevel   : level cap. A skill at the cap stops accumulating XP.
--- xpPerLevel : XP needed to go from `level` to `level + 1`. Either a flat
---              number (same for every level) or a function(level) -> number
---              for a curve.
Config.Skills = {
    cooking = {
        label = 'Cooking',
        maxLevel = BASE_MAX_LEVEL,
        xpPerLevel = baseXpPerLevel,
    },
    crafting = {
        label = 'Crafting',
        maxLevel = BASE_MAX_LEVEL,
        xpPerLevel = baseXpPerLevel,
    },
    drug_sales = {
        label = 'Drug Sales',
        maxLevel = BASE_MAX_LEVEL,
        xpPerLevel = baseXpPerLevel,
    },
}

--- XP required to advance from `level` to `level + 1` for a skill.
--- Returns nil when the skill is unknown or `level` is at or above the cap
--- (i.e. there is no next level to earn).
function Config.XPForLevel(skillName, level)
    local skill = Config.Skills[skillName]
    if not skill then return nil end
    if type(level) ~= 'number' or level < Config.StartingLevel then return nil end
    if level >= skill.maxLevel then return nil end

    local required = skill.xpPerLevel
    if type(required) == 'function' then
        required = required(level)
    end

    if type(required) ~= 'number' or required < 1 then return nil end

    return math.floor(required)
end
