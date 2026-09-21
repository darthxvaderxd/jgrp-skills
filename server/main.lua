local QBCore = exports['qb-core']:GetCoreObject()

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

--- Create `player_skills` on first start if it is not there.
---
--- sql/jgrp_skills.sql still exists for applying it by hand, but relying on a
--- manual import is a deployment step that is easy to forget -- and forgetting
--- it fails in a way that reads like a permissions problem: every skill lookup
--- errors and every gated action is refused. jgrp-garage adds its own column
--- the same way.
local function ensureSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `player_skills` (
            `citizenid` VARCHAR(50) NOT NULL,
            `skill` VARCHAR(50) NOT NULL,
            `level` INT NOT NULL DEFAULT 0,
            `xp` INT NOT NULL DEFAULT 0,
            PRIMARY KEY (`citizenid`, `skill`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
end

--- [citizenid] = { [skillName] = { level = number, xp = number } }
--- Only holds entries for players currently online; offline reads/writes go
--- straight to the database.
local cache = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Resolve a target into a citizenid plus (if they are online) their Player.
--- A number is treated as a player server id, a string as a citizenid.
local function resolveTarget(target)
    if type(target) == 'number' then
        local Player = QBCore.Functions.GetPlayer(target)
        if not Player then return nil end
        return Player.PlayerData.citizenid, Player
    end

    if type(target) == 'string' and target ~= '' then
        return target, QBCore.Functions.GetPlayerByCitizenId(target)
    end

    return nil
end

--- A fresh, unsaved entry for a skill the player has never trained.
local function defaultEntry()
    return { level = Config.StartingLevel, xp = 0 }
end

--- Clamp a stored row against the current config, so lowering a skill's
--- maxLevel (or removing a skill) can't leave a player in an invalid state.
local function normalise(skillName, entry)
    local skill = Config.Skills[skillName]
    if not skill then return nil end

    local level = math.floor(tonumber(entry.level) or Config.StartingLevel)
    local xp = math.floor(tonumber(entry.xp) or 0)

    if level < Config.StartingLevel then level = Config.StartingLevel end
    if level > skill.maxLevel then
        level = skill.maxLevel
        xp = 0
    end
    if xp < 0 then xp = 0 end

    -- At the cap there is no next level, so banked XP is meaningless.
    local required = Config.XPForLevel(skillName, level)
    if not required then
        xp = 0
    elseif xp >= required then
        xp = required - 1
    end

    return { level = level, xp = xp }
end

local function loadFromDb(citizenid)
    local rows = MySQL.query.await(
        'SELECT `skill`, `level`, `xp` FROM `player_skills` WHERE `citizenid` = ?',
        { citizenid }
    )

    local data = {}
    for _, row in ipairs(rows or {}) do
        local entry = normalise(row.skill, row)
        if entry then data[row.skill] = entry end
    end

    return data
end

local function persist(citizenid, skillName, entry)
    MySQL.prepare(
        'INSERT INTO `player_skills` (`citizenid`, `skill`, `level`, `xp`) VALUES (?, ?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE `level` = VALUES(`level`), `xp` = VALUES(`xp`)',
        { citizenid, skillName, entry.level, entry.xp }
    )
end

--- Create a stored row for every configured skill this player is missing, at
--- Config.StartingLevel with no XP.
---
--- Without this a skill only comes into existence the first time something
--- mutates it, so a fresh character has no rows at all and every read falls
--- back to an in-memory default that is never written. That also means a skill
--- added to the config later silently has no row for anyone until they happen
--- to earn XP in it. Called on load, so both cases resolve themselves.
---
--- @return boolean whether anything was created
local function ensureSkills(citizenid, data)
    local created = false

    for skillName in pairs(Config.Skills) do
        if not data[skillName] then
            local entry = defaultEntry()
            data[skillName] = entry
            persist(citizenid, skillName, entry)
            created = true
        end
    end

    return created
end

--- All of a player's skills. Cached for online players, read-through for
--- offline ones (an offline read is never cached).
local function getSkills(citizenid)
    if cache[citizenid] then return cache[citizenid] end
    return loadFromDb(citizenid)
end

--- One skill entry, defaulted when the player has no row for it yet.
local function getEntry(data, skillName)
    local entry = data[skillName]
    if entry then
        return { level = entry.level, xp = entry.xp }
    end
    return defaultEntry()
end

--- Write an entry back to the cache (when online), the database, and the
--- owning client, then fire the level-up hooks for any levels gained.
--- @param gained number|nil XP just earned, for the client to report
local function commit(citizenid, Player, skillName, entry, levelsGained, gained, boost)
    if cache[citizenid] then
        cache[citizenid][skillName] = entry
    end

    persist(citizenid, skillName, entry)

    local src = Player and Player.PlayerData.source
    if src then
        TriggerClientEvent('jgrp-skills:client:UpdateSkill', src, skillName, entry)

        -- Reported by the framework rather than by whatever awarded it, so
        -- every source of XP reads the same and none of them has to remember
        -- to say so.
        if gained and gained > 0 then
            TriggerClientEvent('jgrp-skills:client:GainedXP', src, skillName, gained, entry, boost)
        end
    end

    if levelsGained and levelsGained > 0 then
        TriggerEvent('jgrp-skills:server:LevelUp', citizenid, skillName, entry.level, levelsGained)
        if src then
            TriggerClientEvent('jgrp-skills:client:LevelUp', src, skillName, entry.level, levelsGained)
        end
    end
end

--- Shared validation for every mutating call.
--- Returns citizenid, Player, skills table, current entry.
local function prepareMutation(target, skillName, amount)
    if not Config.Skills[skillName] then
        print(('[jgrp-skills] unknown skill "%s"'):format(tostring(skillName)))
        return nil
    end

    if amount ~= nil then
        amount = tonumber(amount)
        if not amount or amount ~= amount or amount < 1 then
            print(('[jgrp-skills] invalid amount for skill "%s": %s')
                :format(skillName, tostring(amount)))
            return nil
        end
        amount = math.floor(amount)
    end

    local citizenid, Player = resolveTarget(target)
    if not citizenid then return nil end

    local data = getSkills(citizenid)
    return citizenid, Player, data, getEntry(data, skillName), amount
end

-- ---------------------------------------------------------------------------
-- XP boosts
--
-- The scheduled windows live in the config and need no state. This is only the
-- manual one from `/xpboost`, which is deliberately **in memory**: a boost an
-- admin sets by hand should not outlive a restart, or a forgotten 5x becomes
-- somebody else's mystery next week.
-- ---------------------------------------------------------------------------

--- { multiplier, skill, label, expires } or nil. `expires` is an os.time()
--- stamp; nil means until the resource stops.
local manualBoost

local function manualActive()
    if not manualBoost then return nil end

    if manualBoost.expires and os.time() >= manualBoost.expires then
        manualBoost = nil
        return nil
    end

    return manualBoost
end

--- The multiplier in force for a skill right now, and what to call it.
local function boostFor(skillName)
    return Config.BoostFor(skillName, manualActive())
end

-- ---------------------------------------------------------------------------
-- Core API
-- ---------------------------------------------------------------------------

--- @return table|nil { level, xp, maxLevel, xpForNextLevel, atMaxLevel }
local function GetSkill(target, skillName)
    if not Config.Skills[skillName] then return nil end

    local citizenid = resolveTarget(target)
    if not citizenid then return nil end

    local entry = getEntry(getSkills(citizenid), skillName)
    local required = Config.XPForLevel(skillName, entry.level)

    return {
        skill = skillName,
        level = entry.level,
        xp = entry.xp,
        maxLevel = Config.Skills[skillName].maxLevel,
        xpForNextLevel = required,
        atMaxLevel = required == nil,
    }
end

--- Every configured skill for a player, including untrained ones.
local function GetSkills(target)
    local citizenid = resolveTarget(target)
    if not citizenid then return nil end

    local data = getSkills(citizenid)
    local out = {}
    for skillName in pairs(Config.Skills) do
        local entry = getEntry(data, skillName)
        local required = Config.XPForLevel(skillName, entry.level)
        out[skillName] = {
            skill = skillName,
            level = entry.level,
            xp = entry.xp,
            maxLevel = Config.Skills[skillName].maxLevel,
            xpForNextLevel = required,
            atMaxLevel = required == nil,
        }
    end

    return out
end

local function GetLevel(target, skillName)
    local skill = GetSkill(target, skillName)
    return skill and skill.level or nil
end

local function GetXP(target, skillName)
    local skill = GetSkill(target, skillName)
    return skill and skill.xp or nil
end

--- Add XP, rolling over into as many levels as the amount covers.
--- @return table|nil the updated skill, plus `levelsGained`
local function AddXP(target, skillName, amount)
    local citizenid, Player, _, entry, value = prepareMutation(target, skillName, amount)
    if not citizenid then return nil end

    -- **Applied here and nowhere else.** Every route into this resource --
    -- both exports and the AddXP server event -- lands on this function, so a
    -- boost set in the config reaches every resource that awards XP without
    -- any of them knowing it exists.
    --
    -- After prepareMutation, so the caller's own amount is what gets validated
    -- and a boost can never turn a refused award into an accepted one. The
    -- boosted figure is what goes to commit(), so the player is told what was
    -- actually banked rather than what was asked for.
    local multiplier, boostLabel = boostFor(skillName)
    value = Config.ApplyBoost(value, multiplier)

    local levelsGained = 0
    entry.xp = entry.xp + value

    while true do
        local required = Config.XPForLevel(skillName, entry.level)
        if not required then
            -- Capped: excess XP is discarded rather than banked.
            entry.xp = 0
            break
        end
        if entry.xp < required then break end

        entry.xp = entry.xp - required
        entry.level = entry.level + 1
        levelsGained = levelsGained + 1
    end

    -- Only tell the client about a boost that actually changed the number.
    commit(citizenid, Player, skillName, entry, levelsGained, value,
        multiplier ~= 1.0 and { multiplier = multiplier, label = boostLabel } or nil)

    local result = GetSkill(citizenid, skillName)
    if result then
        result.levelsGained = levelsGained
        result.boost = multiplier
        result.boostLabel = boostLabel
    end
    return result
end

--- Remove XP. Drops through levels when Config.AllowDeLevel is on, otherwise
--- clamps at 0 XP in the current level.
local function RemoveXP(target, skillName, amount)
    local citizenid, Player, _, entry, value = prepareMutation(target, skillName, amount)
    if not citizenid then return nil end

    local levelsLost = 0
    entry.xp = entry.xp - value

    while entry.xp < 0 do
        if not Config.AllowDeLevel or entry.level <= Config.StartingLevel then
            entry.xp = 0
            break
        end

        entry.level = entry.level - 1
        levelsLost = levelsLost + 1
        entry.xp = entry.xp + (Config.XPForLevel(skillName, entry.level) or 0)
    end

    commit(citizenid, Player, skillName, entry, 0)

    local result = GetSkill(citizenid, skillName)
    if result then result.levelsLost = levelsLost end
    return result
end

--- Set a skill outright. `xp` is optional and defaults to 0.
local function SetSkill(target, skillName, level, xp)
    if not Config.Skills[skillName] then return nil end

    local citizenid, Player = resolveTarget(target)
    if not citizenid then return nil end

    local entry = normalise(skillName, {
        level = tonumber(level) or Config.StartingLevel,
        xp = tonumber(xp) or 0,
    })
    if not entry then return nil end

    local previous = getEntry(getSkills(citizenid), skillName)
    commit(citizenid, Player, skillName, entry, math.max(0, entry.level - previous.level))

    return GetSkill(citizenid, skillName)
end

local function SetLevel(target, skillName, level)
    return SetSkill(target, skillName, level, 0)
end

--- Wipe a single skill, or every skill when `skillName` is omitted.
local function ResetSkill(target, skillName)
    local citizenid, Player = resolveTarget(target)
    if not citizenid then return false end

    -- A reset puts the skill back to the starting level rather than removing
    -- the row, so the invariant that a character always has a row for every
    -- configured skill survives a reset.
    if skillName then
        if not Config.Skills[skillName] then return false end

        local entry = defaultEntry()
        persist(citizenid, skillName, entry)
        if cache[citizenid] then cache[citizenid][skillName] = entry end
    else
        -- Delete first so rows for skills no longer in the config are cleared
        -- out, then recreate the configured ones at the starting level.
        --
        -- Awaited deliberately: MySQL.prepare is fire-and-forget, so an
        -- un-awaited DELETE can land after the re-inserts below and wipe them.
        MySQL.prepare.await('DELETE FROM `player_skills` WHERE `citizenid` = ?', { citizenid })

        local data = {}
        ensureSkills(citizenid, data)
        if cache[citizenid] then cache[citizenid] = data end
    end

    local src = Player and Player.PlayerData.source
    if src then
        TriggerClientEvent('jgrp-skills:client:SetSkills', src, GetSkills(citizenid))
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Cache lifecycle
-- ---------------------------------------------------------------------------

local function loadPlayer(src)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid
    local data = loadFromDb(citizenid)

    -- Anything this character has no row for is created now, at the starting
    -- level with no XP, rather than waiting for something to grant XP first.
    ensureSkills(citizenid, data)

    cache[citizenid] = data
    TriggerClientEvent('jgrp-skills:client:SetSkills', src, GetSkills(citizenid))
end

RegisterNetEvent('QBCore:Server:PlayerLoaded', function(Player)
    loadPlayer(Player.PlayerData.source)
end)

AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    local Player = QBCore.Functions.GetPlayer(src)
    if Player then cache[Player.PlayerData.citizenid] = nil end
end)

AddEventHandler('playerDropped', function()
    local Player = QBCore.Functions.GetPlayer(source)
    if Player then cache[Player.PlayerData.citizenid] = nil end
end)

-- Repopulate the cache on a resource restart with players already online.
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    -- Before any load, or the first query hits a table that is not there yet.
    ensureSchema()

    for _, Player in pairs(QBCore.Functions.GetQBPlayers()) do
        loadPlayer(Player.PlayerData.source)
    end
end)

-- ---------------------------------------------------------------------------
-- Client access (read-only)
-- ---------------------------------------------------------------------------

QBCore.Functions.CreateCallback('jgrp-skills:server:GetSkills', function(source, cb)
    cb(GetSkills(source))
end)

-- ---------------------------------------------------------------------------
-- Boost: reporting, announcements and /xpboost
-- ---------------------------------------------------------------------------

--- A multiplier as a short string: 2.00 -> "2", 1.50 -> "1.5".
local function rateText(multiplier)
    local text = ('%.2f'):format(multiplier):gsub('%.?0+$', '')
    return text
end

--- What is running right now, as lines for a console or a chat box.
local function boostReport()
    if not (Config.Boost and Config.Boost.Enabled) then
        return { 'XP boosts are disabled.' }
    end

    local lines = {}
    local manual = manualActive()

    -- Reported per skill, because a window or a Skills override can single one
    -- out and a single headline figure would be a lie for the others.
    local names = {}
    for skillName in pairs(Config.Skills) do names[#names + 1] = skillName end
    table.sort(names)

    local width = 0
    for i = 1, #names do
        local label = Config.Skills[names[i]].label or names[i]
        if #label > width then width = #label end
    end

    local pad = ('%%-%ds'):format(width)

    for i = 1, #names do
        local skillName = names[i]
        local multiplier, label = Config.BoostFor(skillName, manual)
        local text = ('%s   %sx'):format(
            pad:format(Config.Skills[skillName].label or skillName), rateText(multiplier))

        if label then text = ('%s  -- %s'):format(text, label) end

        lines[#lines + 1] = text
    end

    if manual then
        local left = manual.expires and math.max(0, manual.expires - os.time()) or nil

        lines[#lines + 1] = left
            and ('Manual boost: %sx for another %d min')
                :format(rateText(manual.multiplier), math.ceil(left / 60))
            or ('Manual boost: %sx, until the resource restarts')
                :format(rateText(manual.multiplier))
    end

    return lines
end

exports('GetBoost', function(skillName)
    return Config.BoostFor(skillName, manualActive())
end)

--- Set or clear the manual boost from another resource. A multiplier of 0 or
--- less clears it.
exports('SetBoost', function(multiplier, minutes, skillName, label)
    multiplier = tonumber(multiplier)

    if not multiplier or multiplier <= 0 then
        manualBoost = nil
        return true
    end

    if skillName and not Config.Skills[skillName] then return false end

    manualBoost = {
        multiplier = multiplier,
        skill = skillName,
        label = label or 'Admin boost',
        expires = tonumber(minutes) and (os.time() + (tonumber(minutes) * 60)) or nil,
    }

    return true
end)

-- ---------------------------------------------------------------------------
-- Announcements
--
-- Polled rather than scheduled: working out the next transition for a set of
-- wrapping, day-filtered windows is a great deal more code than looking every
-- half minute, and half a minute of lateness does not matter for a weekend.
-- ---------------------------------------------------------------------------

CreateThread(function()
    if not (Config.Boost and Config.Boost.Enabled and Config.Boost.Announce) then return end

    -- Seeded from the current state, so restarting during an open window does
    -- not re-announce it to everyone already playing.
    local announced = {}
    for _, entry in ipairs(Config.OpenBoostWindows(nil)) do announced[entry] = true end

    while true do
        Wait(30000)

        local open = {}
        for _, entry in ipairs(Config.OpenBoostWindows(nil)) do open[entry] = true end

        for entry in pairs(open) do
            if not announced[entry] then
                TriggerClientEvent('jgrp-skills:client:BoostNotice', -1, {
                    open = true,
                    label = entry.label or 'XP boost',
                    multiplier = tonumber(entry.multiplier) or 1.0,
                    skills = entry.skills,
                })
            end
        end

        for entry in pairs(announced) do
            if not open[entry] then
                TriggerClientEvent('jgrp-skills:client:BoostNotice', -1, {
                    open = false,
                    label = entry.label or 'XP boost',
                })
            end
        end

        announced = open
    end
end)

-- ---------------------------------------------------------------------------
-- /xpboost
--
--   /xpboost                 what is running -- anyone
--   /xpboost 2               2x everything for an hour (Config.DefaultMinutes)
--   /xpboost 2 120           2x everything for two hours
--   /xpboost 2 120 fishing   2x fishing only, for two hours
--   /xpboost 2 0             2x until the resource restarts
--   /xpboost off             clear it
--
-- Reading is open to everyone; setting needs Config.Boost.CommandPermission.
-- ---------------------------------------------------------------------------

CreateThread(function()
    if not (Config.Boost and Config.Boost.Command) then return end

    RegisterCommand('xpboost', function(source, args)
        local src = source

        local function reply(message)
            if src == 0 then
                print(('[jgrp-skills] %s'):format(message))
            else
                TriggerClientEvent('QBCore:Notify', src, message, 'primary')
            end
        end

        if not args[1] then
            local body = table.concat(boostReport(), '\n')

            if src == 0 then
                print(('[jgrp-skills] XP boosts:\n%s'):format(body))
            else
                TriggerClientEvent('chat:addMessage', src, {
                    color = { 200, 160, 255 },
                    multiline = true,
                    args = { 'XP Boost', body },
                })
            end

            return
        end

        -- Setting one is an admin action. The console (src 0) is always
        -- allowed, because it is already the server.
        if src ~= 0
            and not QBCore.Functions.HasPermission(src, Config.Boost.CommandPermission or 'admin') then
            return reply('You cannot set that.')
        end

        local first = tostring(args[1]):lower()

        if first == 'off' or first == 'clear' or first == 'none' then
            manualBoost = nil
            return reply('Manual XP boost cleared.')
        end

        local multiplier = tonumber(args[1])
        if not multiplier or multiplier <= 0 then
            return reply(('Usage: /xpboost <multiplier> [minutes] [skill] -- minutes '
                .. 'defaults to %d, 0 means until restart. /xpboost off to clear.')
                :format(tonumber(Config.Boost.DefaultMinutes) or 60))
        end

        -- No duration given means Config.Boost.DefaultMinutes -- an hour --
        -- rather than forever. An explicit 0 is the only way to ask for a
        -- boost that outlives the command, because the indefinite one is the
        -- one that gets forgotten about.
        --
        -- Note 0 is truthy in Lua, so this cannot be collapsed into
        -- `minutes and ...`; that is what made an explicit 0 expire instantly.
        local minutes = tonumber(args[2])

        if minutes == nil then
            minutes = tonumber(Config.Boost.DefaultMinutes) or 60
        end

        if minutes < 0 then minutes = 0 end

        local skillName = args[3]

        if skillName and not Config.Skills[skillName] then
            return reply(('There is no "%s" skill.'):format(skillName))
        end

        manualBoost = {
            multiplier = multiplier,
            skill = skillName,
            label = 'Admin boost',
            expires = minutes > 0 and (os.time() + (minutes * 60)) or nil,
        }

        reply(('XP boost set: %sx%s%s'):format(
            rateText(multiplier),
            skillName and (' on ' .. skillName) or '',
            minutes > 0 and ((' for %d min'):format(minutes)) or ' until restart'))

        if Config.Boost.Announce then
            TriggerClientEvent('jgrp-skills:client:BoostNotice', -1, {
                open = true,
                label = 'Admin boost',
                multiplier = multiplier,
                skills = skillName and { skillName } or nil,
            })
        end
    end, false)

    TriggerClientEvent('chat:addSuggestion', -1, '/xpboost',
        ('Current XP boosts, or set one for %d min (admin)')
            :format(tonumber(Config.Boost.DefaultMinutes) or 60))
end)

-- ---------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------

exports('GetSkill', GetSkill)
exports('GetSkills', GetSkills)
exports('GetLevel', GetLevel)
exports('GetXP', GetXP)
exports('AddXP', AddXP)
exports('RemoveXP', RemoveXP)
exports('SetSkill', SetSkill)
exports('SetLevel', SetLevel)
exports('ResetSkill', ResetSkill)

-- ---------------------------------------------------------------------------
-- Server events
--
-- Deliberately AddEventHandler and not RegisterNetEvent: XP changes must only
-- ever originate server-side, never from a client packet.
-- ---------------------------------------------------------------------------

AddEventHandler('jgrp-skills:server:AddXP', AddXP)
AddEventHandler('jgrp-skills:server:RemoveXP', RemoveXP)
AddEventHandler('jgrp-skills:server:SetSkill', SetSkill)
AddEventHandler('jgrp-skills:server:SetLevel', SetLevel)
AddEventHandler('jgrp-skills:server:ResetSkill', ResetSkill)
