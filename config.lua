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

--- Show a notification every time XP is earned, not just on a level up.
---
--- This is the skill framework's own message, so every resource that awards
--- XP gets it for free and they all read the same. A resource that already
--- says what you earned in its own line will now say it twice -- that is the
--- cost of having one honest source for it.
Config.NotifyOnXP = true

--- Do not bother for tiny amounts. 1 means notify for everything; 5 would
--- keep the corner-by-corner trickle quiet and still report a real haul.
Config.NotifyXPThreshold = 1

-- ---------------------------------------------------------------------------
-- XP boosts
--
-- One multiplier applied inside `AddXP`, which is the single funnel every
-- resource goes through -- the exports, the `jgrp-skills:server:AddXP` event,
-- all of it. So a boost set here reaches fishing, drug sales, petty crime and
-- anything added later without one line changing in any of them.
--
-- **The boosted number is what the player is told.** `commit()` reports the
-- amount that was actually banked, so a double-XP weekend reads as "+24
-- Thieving xp" rather than "+12" and a quiet lie.
-- ---------------------------------------------------------------------------

Config.Boost = {
    --- The whole feature off. Everything below is ignored and XP is awarded
    --- exactly as it was before any of this existed.
    Enabled = true,

    --- The always-on multiplier, applied whatever the day. 1.0 is no change.
    --- This is the knob to turn for a permanent rate change; leave it at 1.0
    --- and use Schedule for weekends.
    Multiplier = 1.0,

    --- Per-skill overrides of `Multiplier`. A skill listed here ignores the
    --- figure above entirely; one that is not listed uses it.
    ---
    ---     Skills = { fishing = 1.5, thieving = 0.75 },
    Skills = {},

    --- Read the clock in UTC rather than the server box's local time.
    ---
    --- **Decide this before you write a schedule, not after.** txAdmin rotates
    --- its logs at midnight UTC, which is 18:00 on this box, so the two are six
    --- hours apart and a window written against the wrong one opens at the
    --- wrong time. UTC is the safer choice if your players are spread out;
    --- local is friendlier if they are not.
    UseUTC = false,

    --- Recurring windows. Each entry:
    ---
    ---   days       : which days it runs, any of
    ---                'sun' 'mon' 'tue' 'wed' 'thu' 'fri' 'sat'.
    ---                Omit for every day.
    ---   from, to   : 'HH:MM', inclusive both ends.
    ---   multiplier : what XP is multiplied by while it is open.
    ---   skills     : optional list of skill names it applies to. Omit for all.
    ---   label      : what the announcement calls it.
    ---
    --- **A window where `from` is later than `to` wraps past midnight**, and
    --- `days` then means the day it *starts* on. So Friday 20:00 -> 02:00 runs
    --- into Saturday morning and is one entry, not two.
    ---
    --- The bonus weekend, commented out and ready:
    ---
    ---     { days = { 'fri', 'sat', 'sun' }, from = '00:00', to = '23:59',
    ---       multiplier = 2.0, label = 'Double XP Weekend' },
    ---
    --- A Friday-night-into-Saturday one, to show the wrap:
    ---
    ---     { days = { 'fri' }, from = '18:00', to = '02:00',
    ---       multiplier = 2.0, label = 'Friday Night Double XP' },
    Schedule = {},

    --- How the always-on multiplier, an open schedule window and a manual
    --- `/xpboost` combine when more than one is in play.
    ---
    --- 'highest'  : the biggest of them wins. Nothing compounds, so a 2x
    ---              weekend plus a 2x admin boost is still 2x. This is the
    ---              default because compounding is how you accidentally ship
    ---              8x.
    --- 'multiply' : they stack. 2x weekend and 2x manual is 4x. Only pick this
    ---              if that is genuinely what you want.
    Stack = 'highest',

    --- Tell everyone when a scheduled window opens and closes. Checked every
    --- 30 seconds, so an announcement can be up to half a minute late.
    Announce = true,

    --- Register `/xpboost`. With no arguments anyone can use it to see what is
    --- running; setting one needs the `admin` ace.
    Command = true,

    --- The ace permission required to set a boost from `/xpboost`.
    CommandPermission = 'admin',

    --- How long `/xpboost <multiplier>` lasts when no duration is given, in
    --- minutes. An hour, because a boost you have to remember to turn off is
    --- one you will forget to turn off.
    ---
    --- `/xpboost 2 0` is the explicit way to say "until the resource
    --- restarts"; there is deliberately no way to say it by accident.
    DefaultMinutes = 60,

    --- A boost never rounds an award down to nothing: the result is rounded
    --- half up and then floored at 1, because `AddXP` refuses anything below
    --- that. A multiplier of 0 is therefore not a way to switch XP off --
    --- `Enabled = false`, or the resource not running, is.
}

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
    fishing = {
        label = 'Fishing',
        maxLevel = BASE_MAX_LEVEL,
        xpPerLevel = baseXpPerLevel,
    },
    thieving = {
        label = 'Thieving',
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

-- ---------------------------------------------------------------------------
-- Boost resolution
--
-- Shared, next to Config.XPForLevel and for the same reason: the server
-- decides with it and anything that wants to *display* a boost reads the same
-- function, so the two can never disagree about what is running.
-- ---------------------------------------------------------------------------

local DAYS = { sun = 1, mon = 2, tue = 3, wed = 4, thu = 5, fri = 6, sat = 7 }

--- 'HH:MM' as minutes past midnight, or nil if it is not a time.
local function minutesOf(text)
    if type(text) ~= 'string' then return nil end

    local hour, minute = text:match('^(%d%d?):(%d%d)$')
    if not hour then return nil end

    hour, minute = tonumber(hour), tonumber(minute)
    if hour > 23 or minute > 59 then return nil end

    return (hour * 60) + minute
end

--- Which weekday numbers an entry runs on, as a lookup. nil means every day.
local function daysOf(entry)
    if type(entry.days) ~= 'table' or #entry.days == 0 then return nil end

    local set = {}
    for i = 1, #entry.days do
        local day = DAYS[tostring(entry.days[i]):lower()]
        if day then set[day] = true end
    end

    return next(set) and set or nil
end

--- Does this window apply to `skillName`? A window with no `skills` list
--- applies to all of them.
local function coversSkill(entry, skillName)
    if type(entry.skills) ~= 'table' or #entry.skills == 0 then return true end
    if not skillName then return true end

    for i = 1, #entry.skills do
        if entry.skills[i] == skillName then return true end
    end

    return false
end

--- Is a schedule entry open at `now` (an os.date('*t') table)?
---
--- **The wrap is the fiddly part.** When `from` is later than `to` the window
--- runs past midnight, and `days` means the day it *starts* on -- so at 01:00
--- on Saturday, a Friday 18:00->02:00 window is open because *yesterday* was a
--- Friday. Checking today's weekday against the clock alone gets this wrong in
--- both directions.
local function windowOpen(entry, now)
    local from = minutesOf(entry.from)
    local to = minutesOf(entry.to)
    if not from or not to then return false end

    local days = daysOf(entry)
    local nowMinutes = (now.hour * 60) + now.min

    if from <= to then
        if days and not days[now.wday] then return false end
        return nowMinutes >= from and nowMinutes <= to
    end

    -- Wrapped. Either we are in the tail of a window that started today, or in
    -- the tail of one that started yesterday.
    local yesterday = now.wday == 1 and 7 or (now.wday - 1)

    if nowMinutes >= from then
        return not days or days[now.wday] == true
    end

    if nowMinutes <= to then
        return not days or days[yesterday] == true
    end

    return false
end

--- Every schedule window open right now for `skillName`.
--- @param skillName string|nil nil means "any window", for announcements.
--- @return table a list of the matching Config.Boost.Schedule entries
function Config.OpenBoostWindows(skillName, now)
    local boost = Config.Boost
    if not boost or not boost.Enabled then return {} end
    if type(boost.Schedule) ~= 'table' then return {} end

    now = now or os.date(boost.UseUTC and '!*t' or '*t')

    local open = {}

    for i = 1, #boost.Schedule do
        local entry = boost.Schedule[i]

        if coversSkill(entry, skillName) and windowOpen(entry, now) then
            open[#open + 1] = entry
        end
    end

    return open
end

--- The multiplier in force for `skillName`, and what to call it.
---
--- `manual` is an optional { multiplier, skill, label } from a running
--- `/xpboost`; the server passes its own, and a caller that only wants to
--- display the scheduled rate can leave it out.
---
--- @return number multiplier, string|nil label
function Config.BoostFor(skillName, manual, now)
    local boost = Config.Boost
    if not boost or not boost.Enabled then return 1.0, nil end

    -- The always-on rate, per skill if it has been given one.
    local base = tonumber(boost.Skills and boost.Skills[skillName]) or tonumber(boost.Multiplier) or 1.0

    local parts = { { value = base, label = nil } }

    local open = Config.OpenBoostWindows(skillName, now)
    for i = 1, #open do
        parts[#parts + 1] = {
            value = tonumber(open[i].multiplier) or 1.0,
            label = open[i].label,
        }
    end

    if manual and tonumber(manual.multiplier)
        and (not manual.skill or not skillName or manual.skill == skillName) then
        parts[#parts + 1] = { value = tonumber(manual.multiplier), label = manual.label or 'Admin boost' }
    end

    if boost.Stack == 'multiply' then
        local total, label = 1.0, nil

        for i = 1, #parts do
            total = total * parts[i].value
            -- The last named contributor wins the label; with several stacked
            -- there is no one honest name for it anyway.
            if parts[i].label then label = parts[i].label end
        end

        return total, label
    end

    -- 'highest', and the default for anything unrecognised: nothing compounds.
    --
    -- Seeded from the always-on rate rather than from 1.0, so a `Multiplier`
    -- set **below** 1.0 is honoured instead of being quietly floored back up
    -- to normal. Windows and manual boosts can only raise it from there.
    local best, label = parts[1].value, parts[1].label

    for i = 2, #parts do
        if parts[i].value > best then
            best, label = parts[i].value, parts[i].label
        end
    end

    return best, label
end

--- Apply a multiplier to an XP amount.
---
--- Rounds half up, then floors at 1: `AddXP` refuses anything below 1, so a
--- fractional result must never become 0 and silently swallow the award.
function Config.ApplyBoost(amount, multiplier)
    if type(amount) ~= 'number' then return amount end
    if type(multiplier) ~= 'number' or multiplier == 1.0 then return amount end

    return math.max(1, math.floor((amount * multiplier) + 0.5))
end
