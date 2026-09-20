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
local function commit(citizenid, Player, skillName, entry, levelsGained)
    if cache[citizenid] then
        cache[citizenid][skillName] = entry
    end

    persist(citizenid, skillName, entry)

    local src = Player and Player.PlayerData.source
    if src then
        TriggerClientEvent('jgrp-skills:client:UpdateSkill', src, skillName, entry)
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

    commit(citizenid, Player, skillName, entry, levelsGained)

    local result = GetSkill(citizenid, skillName)
    if result then result.levelsGained = levelsGained end
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
