Config = {}

--- Level every skill starts at when a player has no stored row yet.
Config.StartingLevel = 1

--- When true, RemoveXP can drop a player back down through levels.
--- When false, XP loss is clamped at 0 for the current level.
Config.AllowDeLevel = true

--- Show a qb-core notification to the player when a skill levels up.
Config.NotifyOnLevelUp = true

--- Skill definitions.
---
--- maxLevel   : level cap. A skill at the cap stops accumulating XP.
--- xpPerLevel : XP needed to go from `level` to `level + 1`. Either a flat
---              number (same for every level) or a function(level) -> number
---              for a curve.
Config.Skills = {
    mining = {
        label = 'Mining',
        maxLevel = 50,
        -- Flat curve: every level costs the same.
        xpPerLevel = 250,
    },

    fishing = {
        label = 'Fishing',
        maxLevel = 30,
        -- Linear curve: 100, 175, 250, ...
        xpPerLevel = function(level)
            return 100 + ((level - 1) * 75)
        end,
    },

    driving = {
        label = 'Driving',
        maxLevel = 20,
        -- Geometric curve: each level costs 15% more than the last.
        xpPerLevel = function(level)
            return math.floor(200 * (1.15 ^ (level - 1)))
        end,
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
