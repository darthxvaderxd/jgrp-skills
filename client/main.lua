local QBCore = exports['qb-core']:GetCoreObject()

--- [skillName] = { skill, level, xp, maxLevel, xpForNextLevel, atMaxLevel }
--- A mirror of the server's data for this player, kept up to date by the
--- server. Read-only: writing to it changes nothing server-side.
local skills = {}

--- Every notification this resource shows goes through here.
---
--- Swap the body for whatever notification framework you end up using — ox_lib,
--- okokNotify, a custom NUI, anything. Nothing else in the resource calls a
--- notification API directly, so this function is the only place that needs to
--- change.
---
--- @param message string  ready-made text, already formatted
--- @param notifyType string  'success' | 'error' | 'primary'
--- @param data table  the raw context behind the message, so a framework that
---        builds its own text (title, icon, duration) doesn't have to parse
---        `message`. For a level up: { event, skill, label, level, levelsGained }.
local function Notify(message, notifyType, data)
    -- >>> Add your code here to push notifications to your notification framework. <<<

    -- Default: qb-core's built-in notification.
    QBCore.Functions.Notify(message, notifyType)
end

local function requestSync()
    QBCore.Functions.TriggerCallback('jgrp-skills:server:GetSkills', function(data)
        skills = data or {}
    end)
end

RegisterNetEvent('jgrp-skills:client:SetSkills', function(data)
    skills = data or {}
end)

RegisterNetEvent('jgrp-skills:client:UpdateSkill', function(skillName, entry)
    local skill = Config.Skills[skillName]
    if not skill or type(entry) ~= 'table' then return end

    local required = Config.XPForLevel(skillName, entry.level)
    skills[skillName] = {
        skill = skillName,
        level = entry.level,
        xp = entry.xp,
        maxLevel = skill.maxLevel,
        xpForNextLevel = required,
        atMaxLevel = required == nil,
    }
end)

RegisterNetEvent('jgrp-skills:client:LevelUp', function(skillName, level, levelsGained)
    if not Config.NotifyOnLevelUp then return end

    local skill = Config.Skills[skillName]
    if not skill then return end

    Notify(('%s level %d'):format(skill.label or skillName, level), 'success', {
        event = 'levelup',
        skill = skillName,
        label = skill.label or skillName,
        level = level,
        levelsGained = levelsGained or 1,
    })
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', requestSync)

AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    if LocalPlayer.state.isLoggedIn then requestSync() end

    -- Registered here rather than at file scope: at load the chat resource may
    -- not be listening yet and the suggestion is silently dropped.
    TriggerEvent('chat:addSuggestion', '/skill_debug',
        'List your level and XP for every skill')
end)

-- ---------------------------------------------------------------------------
-- Exports (read-only mirror of the server's data)
-- ---------------------------------------------------------------------------

local function GetSkill(skillName)
    return skills[skillName]
end

local function GetSkills()
    return skills
end

local function GetLevel(skillName)
    local skill = skills[skillName]
    return skill and skill.level or nil
end

local function GetXP(skillName)
    local skill = skills[skillName]
    return skill and skill.xp or nil
end

--- Progress through the current level as a 0..1 fraction. Returns 1 at cap.
local function GetProgress(skillName)
    local skill = skills[skillName]
    if not skill then return nil end
    if skill.atMaxLevel or not skill.xpForNextLevel then return 1.0 end
    return skill.xp / skill.xpForNextLevel
end

exports('GetSkill', GetSkill)
exports('GetSkills', GetSkills)
exports('GetLevel', GetLevel)
exports('GetXP', GetXP)
exports('GetProgress', GetProgress)

-- ---------------------------------------------------------------------------
-- /skill_debug
--
-- A stopgap until there is a real UI. Reads the local mirror rather than asking
-- the server, so it is instant and shows exactly what the client believes --
-- which is also what you want when the question is "is my client in sync?".
-- ---------------------------------------------------------------------------

--- One line per skill, sorted by label so the list does not reshuffle between
--- calls (pairs() over Config.Skills has no defined order).
local function skillLines()
    local rows = {}
    local width = 0

    for skillName, skill in pairs(Config.Skills) do
        local label = skill.label or skillName
        if #label > width then width = #label end
        rows[#rows + 1] = { label = label, entry = skills[skillName] }
    end

    table.sort(rows, function(a, b) return a.label < b.label end)

    -- Padded to the longest label so the levels line up in a column. Chat
    -- renders in a proportional font, so this is approximate, but the F8
    -- console it also prints to is monospaced and lines up exactly.
    local pad = ('%%-%ds'):format(width)
    local lines = {}

    for i = 1, #rows do
        local label, entry = pad:format(rows[i].label), rows[i].entry

        if not entry then
            -- The server pushes every configured skill, so a gap here means the
            -- mirror has not arrived yet rather than that the skill is unknown.
            lines[i] = ('%s   not synced'):format(label)
        elseif entry.atMaxLevel or not entry.xpForNextLevel then
            lines[i] = ('%s   Level %d  (MAX)'):format(label, entry.level)
        else
            local pct = math.floor((entry.xp / entry.xpForNextLevel) * 100)
            lines[i] = ('%s   Level %-3d %d / %d xp  (%d%%)')
                :format(label, entry.level, entry.xp, entry.xpForNextLevel, pct)
        end
    end

    return lines
end

RegisterCommand('skill_debug', function()
    local lines = skillLines()

    if #lines == 0 then
        return Notify('No skills are configured.', 'error', { event = 'skill_debug' })
    end

    local body = table.concat(lines, '\n')

    TriggerEvent('chat:addMessage', {
        color = { 120, 200, 255 },
        multiline = true,
        args = { 'Skills', body },
    })

    -- Also to F8, so it can be copied out of the console.
    print(('[jgrp-skills] skills for this character:\n%s'):format(body))
end, false)
