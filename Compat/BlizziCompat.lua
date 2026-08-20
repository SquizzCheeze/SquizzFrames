--[[ SquizzFrames BlizziCompat.lua - Optional integration with BliZzi_Interrupts' unit-frame resolver ]]
--
-- BliZzi_Interrupts (a separate, third-party addon some users run alongside
-- SquizzFrames for party cooldown/interrupt tracking) maintains its own
-- hardcoded list of supported party-frame addons (ElvUI, Cell, Grid2, etc,
-- see its Core/UnitFrames.lua) and has no public "register a new provider"
-- API -- SquizzFrames isn't in that list, so Blizzi can't find our frames
-- at all and silently falls through to its Blizzard-frame fallback, which
-- SquizzFrames hides (see HideBlizzard.lua). Confirmed via user report:
-- Blizzi's party-cooldown icons don't attach to SquizzFrames' party frames.
--
-- Blizzi DOES expose its resolver as a public global table (BIT.UnitFrames
-- -- see that addon's own UnitFrames.lua header comment, which documents
-- GetPartyFrame/GetPartyContainer/GetAvailableProviders/CountFrameAddons as
-- its public API). This file wraps those 4 functions from OUTSIDE Blizzi's
-- own addon folder entirely -- nothing here edits BliZzi_Interrupts' files,
-- so this survives Blizzi's own updates as long as that public surface
-- stays stable, and does nothing at all (safely) if Blizzi isn't installed.
--
-- SquizzFrames' own frame naming (SquizzFramesPartyHeaderUnitButton1..40 for
-- party, SquizzFramesRaidGroupHeader<1-8>UnitButton<1-5> for raid -- all set by
-- SecureGroupHeaderTemplate's own child-naming convention off each header's
-- name, see PartyFrames.lua's CreateHeader) mirrors Cell's exact
-- scheme, so this uses the same scan-and-match-by-unit-attribute technique
-- Blizzi's own Cell/ElvUI/etc finders already use (reviewed directly from
-- BliZzi_Interrupts' local install) -- including its same secret-value-safe
-- habit of comparing unit strings directly rather than calling UnitIsUnit()
-- (see GetFrameUnit below, copied from Blizzi's own identical helper).

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

-- Read a frame's bound unit. Secure-header children set their unit via
-- SetAttribute("unit", ...); prefer that over the plain .unit field since
-- it survives child recycling on roster changes. pcall guards
-- GetAttribute throwing on tainted handlers in some secure-frame edge
-- cases. Direct string compare (not UnitIsUnit()) avoids a tainted/secret
-- boolean throwing the moment it's used in an `if` -- same reasoning
-- BliZzi_Interrupts' own identical helper documents.
local function GetFrameUnit(btn)
    if not btn then return nil end
    local u
    if btn.GetAttribute then
        local ok, val = pcall(btn.GetAttribute, btn, "unit")
        if ok then u = val end
    end
    if (not u or u == "") and btn.unit then u = btn.unit end
    if type(u) ~= "string" or u == "" then return nil end
    return u
end

local function IsSquizzFramesActive()
    return _G["SquizzFramesPartyHeader"] ~= nil
end

-- Two shapes to search, because SquizzFrames uses two (2026-08-20):
--   * party/solo -- one header, SquizzFramesPartyHeaderUnitButton1..40. The 40
--     is because CreateHeader force-creates that many children up front
--     regardless of current group size.
--   * raid -- eight subgroup headers, SquizzFramesRaidGroupHeader<1-8>UnitButton<1-5>
--     (see the groupHeaders comment in PartyFrames.lua for why raid can't be a
--     single header).
-- Whichever set isn't in use has hidden children, so the IsVisible test alone
-- keeps them from matching -- no need to ask which mode is active.
local function FindSquizzFramesButton(unit)
    local header = _G["SquizzFramesPartyHeader"]
    if header and header:IsVisible() then
        for i = 1, 40 do
            local btn = _G["SquizzFramesPartyHeaderUnitButton" .. i]
            if btn and btn:IsVisible() and GetFrameUnit(btn) == unit then
                return btn
            end
        end
    end
    for g = 1, 8 do
        local groupHeader = _G["SquizzFramesRaidGroupHeader" .. g]
        if groupHeader and groupHeader:IsVisible() then
            for i = 1, 5 do
                local btn = _G["SquizzFramesRaidGroupHeader" .. g .. "UnitButton" .. i]
                if btn and btn:IsVisible() and GetFrameUnit(btn) == unit then
                    return btn
                end
            end
        end
    end
    return nil
end

local function FindSquizzFramesContainer()
    local frame = _G["SquizzFramesPartyFrame"]
    if frame and frame:IsVisible() then return frame end
    return nil
end

local patched = false
local function TryPatchBlizzi()
    if patched then return end
    if not (_G.BIT and _G.BIT.UnitFrames) then return end
    local UF = _G.BIT.UnitFrames
    patched = true

    local origGetPartyFrame = UF.GetPartyFrame
    -- AUTO/nil tries SquizzFrames like any other auto-detected provider;
    -- an explicit "SQUIZZFRAMES" override always tries it and falls back to
    -- Blizzard if SquizzFrames' own frame isn't there right now -- matching
    -- every one of Blizzi's own PROVIDER_FINDERS entries' identical
    -- "or FindBlizzard(unit)" fallback convention.
    function UF:GetPartyFrame(unit, providerOverride)
        if not providerOverride or providerOverride == "AUTO" or providerOverride == "SQUIZZFRAMES" then
            local f = FindSquizzFramesButton(unit)
            if f then return f end
            if providerOverride == "SQUIZZFRAMES" then
                return origGetPartyFrame(self, unit, "BLIZZARD")
            end
        end
        return origGetPartyFrame(self, unit, providerOverride)
    end

    local origGetPartyContainer = UF.GetPartyContainer
    function UF:GetPartyContainer(provider)
        if not provider or provider == "AUTO" or provider == "SQUIZZFRAMES" then
            local f = FindSquizzFramesContainer()
            if f then return f end
            if provider == "SQUIZZFRAMES" then
                return origGetPartyContainer(self, "BLIZZARD")
            end
        end
        return origGetPartyContainer(self, provider)
    end

    local origGetAvailableProviders = UF.GetAvailableProviders
    function UF:GetAvailableProviders()
        local list = origGetAvailableProviders(self)
        if IsSquizzFramesActive() then
            -- Right after "Auto Detect" (index 1) so it reads as a
            -- first-class option, not an afterthought tacked on the end.
            table.insert(list, 2, { value = "SQUIZZFRAMES", label = "SquizzFrames" })
        end
        return list
    end

    local origCountFrameAddons = UF.CountFrameAddons
    function UF:CountFrameAddons()
        local n = origCountFrameAddons(self) or 0
        if IsSquizzFramesActive() then n = n + 1 end
        return n
    end
end

-- Both addons' load order relative to each other isn't guaranteed (neither
-- lists the other as a dependency), and the globals this file checks for
-- (BIT, SquizzFramesPartyHeader) may not exist yet even right after
-- ADDON_LOADED -- PLAYER_LOGIN is late enough that every addon's own
-- OnInitialize/OnEnable has already run.
local waiter = CreateFrame("Frame")
waiter:RegisterEvent("PLAYER_LOGIN")
waiter:SetScript("OnEvent", function(self)
    TryPatchBlizzi()
    self:UnregisterEvent("PLAYER_LOGIN")
end)
