--[[ SquizzFrames Compat/ForeverCheck.lua - /sf forevercheck

TEMPORARY DIAGNOSTIC for the WoW Forever port. Blizzard generates one set of
API docs across flavours, so a documented function can still be missing or
inert on a given client. This prints what the running client really has, and
deciding what to gate on Forever comes from its output. It also runs on retail,
which gives a known-good reading to compare against.

Every probe has its own pcall and the dump ends with a terminator line, so a
truncated report is obvious. Delete once the port is finished.

On Forever it also runs by itself, silently, once each per session: after
login, on entering combat, and on joining a group. The reports are kept in
SquizzFramesDB.foreverCheck, so they can be read from the SavedVariables file
after a /reload or logout.
]]

local SquizzFrames = _G["SquizzFrames"]

local PREFIX = "|cff33cc99[SquizzFrames]|r "

-- The report being kept. The slash command prints as well; the automatic runs
-- stay out of chat.
local report, quiet

local function Say(text)
    if report then report[#report + 1] = text end
    if not quiet then print(PREFIX .. text) end
end

-- tostring, except a secret is named rather than handed around.
local function Show(value)
    if issecretvalue and issecretvalue(value) then return "<secret>" end
    return tostring(value)
end

local function Resolve(path)
    local node = _G
    for part in path:gmatch("[^.]+") do
        if type(node) ~= "table" then return nil end
        node = node[part]
    end
    return node
end

local API_NAMES = {
    "C_SpecializationInfo.GetSpecialization",
    "C_SpecializationInfo.GetSpecializationInfo",
    "GetSpecializationNameForSpecID",
    "GetSpecializationInfoForSpecID",
    "C_Spell.IsPriorityAura",
    "C_UnitAuras.AuraIsBigDefensive",
    "C_UnitAuras.GetAuraData",
    "PingableType_UnitFrameMixin",
    "UnitPhaseReason",
    "UnitGetTotalAbsorbs",
    "UnitGetTotalHealAbsorbs",
    "UnitGetIncomingHeals",
    "UnitHealthPercent",
    "CurveConstants",
    "C_CurveUtil.CreateColorCurve",
    "C_CooldownViewer",
    "C_DamageMeter",
    "C_PvP.GetArenaOpponentSpec",
    "GetArenaOpponentSpec",
    "C_Secrets.HasSecretRestrictions",
    "C_Secrets.ShouldAurasBeSecret",
    "C_Secrets.GetSpellAuraSecrecy",
    "IsSpellInRange",
    "C_Spell.IsSpellInRange",
    "UnitInRange",
    "LibStub",
    "C_ClassTalents.GetActiveConfigID",
    "C_Traits.GetConfigInfo",
    "C_SpecializationInfo.GetInspectSpecialization",
    "GetInspectSpecialization",
    "NotifyInspect",
    "SetFocus",
}

local ADDON_NAMES = {
    "Blizzard_PingUI", "Blizzard_CooldownViewer", "Blizzard_CompactRaidFrames",
    "Blizzard_ArenaUI", "Blizzard_ClassTalentUI", "Blizzard_PlayerSpells",
}

local FRAME_NAMES = {
    "PlayerFrame", "TargetFrame", "PetFrame", "FocusFrame", "Boss1TargetFrame",
    "PartyFrame", "PartyMemberFrame1", "CompactPartyFrame", "CompactPartyFrameMember1",
    "CompactRaidFrameContainer", "CompactRaidFrameManager", "CompactArenaFrame",
    "ArenaEnemyFramesContainer", "PlayerCastingBarFrame", "CastingBarFrame",
    "EssentialCooldownViewer", "UtilityCooldownViewer", "BuffIconCooldownViewer",
    "EditModeManagerFrame",
}

local function Probe(label, fn)
    local ok, a, b, c = pcall(fn)
    if ok then
        Say(("  %s = %s, %s, %s"):format(label, Show(a), Show(b), Show(c)))
    else
        Say(("  %s FAILED: %s"):format(label, Show(a)))
    end
end

local function Dump()
    local interface = select(4, GetBuildInfo())
    Say(("build %s, interface %s, IS_FOREVER %s, combat %s"):format(
        Show((GetBuildInfo())), Show(interface),
        Show(SquizzFrames.IS_FOREVER), Show(InCombatLockdown())))

    local missing = {}
    for _, name in ipairs(API_NAMES) do
        if Resolve(name) == nil then missing[#missing + 1] = name end
    end
    Say("API missing (" .. #missing .. "/" .. #API_NAMES .. "): " .. table.concat(missing, ", "))

    missing = {}
    for _, name in ipairs(FRAME_NAMES) do
        if _G[name] == nil then missing[#missing + 1] = name end
    end
    Say("frames missing (" .. #missing .. "/" .. #FRAME_NAMES .. "): " .. table.concat(missing, ", "))

    Say("Blizzard addons:")
    for _, name in ipairs(ADDON_NAMES) do
        Probe(name, function() return C_AddOns.IsAddOnLoaded(name) end)
    end

    Say("talents:")
    Probe("active config, name", function()
        local id = C_ClassTalents.GetActiveConfigID()
        local info = id and C_Traits.GetConfigInfo(id)
        return id, info and info.name, info and info.treeIDs and #info.treeIDs
    end)

    Say("secrets:")
    Probe("HasSecretRestrictions", function() return C_Secrets.HasSecretRestrictions() end)
    Probe("ShouldAurasBeSecret", function() return C_Secrets.ShouldAurasBeSecret() end)

    Say("spec and role:")
    Probe("GetSpecialization", function() return C_SpecializationInfo.GetSpecialization() end)
    Probe("GetPlayerSpecID", function() return SquizzFrames.funcs.GetPlayerSpecID() end)
    Probe("spec list size", function() return #SquizzFrames.funcs.GetPlayerSpecList() end)
    Probe("UnitGroupRolesAssigned(player)", function() return UnitGroupRolesAssigned("player") end)

    Say("player values:")
    Probe("absorb, healAbsorb, incoming", function()
        return UnitGetTotalAbsorbs("player"), UnitGetTotalHealAbsorbs("player"), UnitGetIncomingHeals("player")
    end)
    Probe("UnitHealthPercent", function() return UnitHealthPercent("player", true, CurveConstants.ScaleTo100) end)
    Probe("UnitInRange(player)", function() return UnitInRange("player") end)
    Probe("LibRangeCheck", function() return LibStub("LibRangeCheck-3.0", true) ~= nil end)

    Say("ping:")
    Probe("pingIconFrame on CompactPartyFrameMember1", function()
        local member = _G["CompactPartyFrameMember1"]
        return member and member.pingIconFrame ~= nil
    end)
    Probe("showPingsOnRaidFrames, pingCVarSet", function()
        return GetCVar("showPingsOnRaidFrames"), SquizzFramesDB and SquizzFramesDB.pingCVarSet
    end)
    Probe("CompactPartyFrameMember1 unit, shown, raid style", function()
        local member = _G["CompactPartyFrameMember1"]
        return member and member.unit, member and member:IsShown(), EditModeManagerFrame:UseRaidStylePartyFrames()
    end)
    Probe("our player button, its marker", function()
        local PF = SquizzFrames:GetModule("PartyFrames", true)
        local button = PF and PF.FindButtonByUnit and PF.FindButtonByUnit("player")
        return button ~= nil, button and button.indicators and button.indicators.pingMarker ~= nil
    end)

    Say("group, " .. Show(GetNumGroupMembers()) .. " members:")
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) then
            Probe(unit .. " class, level, role", function()
                return select(2, UnitClass(unit)), UnitLevel(unit), UnitGroupRolesAssigned(unit)
            end)
            Probe(unit .. " UnitInRange, range min, max", function()
                local RC = LibStub("LibRangeCheck-3.0", true)
                local low, high = RC:GetRange(unit)
                return UnitInRange(unit), low, high
            end)
        end
    end
end

local function Run(label)
    report = {}
    local ok, err = pcall(Dump)
    if not ok then Say("check aborted: " .. Show(err)) end
    Say("end of forevercheck")
    if SquizzFramesDB then
        SquizzFramesDB.foreverCheck = SquizzFramesDB.foreverCheck or {}
        SquizzFramesDB.foreverCheck[label] = report
    end
    report = nil
end

function SquizzFrames.ForeverCheck()
    quiet = false
    Run("manual")
end

if SquizzFrames.IS_FOREVER then
    local function RunQuiet(label)
        quiet = true
        Run(label)
    end

    local events = CreateFrame("Frame")
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    events:RegisterEvent("PLAYER_REGEN_DISABLED")
    events:RegisterEvent("GROUP_ROSTER_UPDATE")
    events:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_ENTERING_WORLD" then
            self:UnregisterEvent(event)
            C_Timer.After(5, function() RunQuiet("login") end)
        elseif event == "PLAYER_REGEN_DISABLED" then
            -- This fires just before the lockdown starts, and the first version
            -- reported "combat false" from here. Wait until it really is on.
            self:UnregisterEvent(event)
            C_Timer.After(1, function()
                if InCombatLockdown() then
                    RunQuiet("combat")
                else
                    self:RegisterEvent(event)
                end
            end)
        elseif IsInGroup() then
            self:UnregisterEvent(event)
            C_Timer.After(5, function() RunQuiet("group") end)
        end
    end)
end
