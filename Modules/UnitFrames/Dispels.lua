--[[ SquizzFrames UnitFrames Dispels

    Dispel-type overlay on a unit frame's health bar, plus the dispel-type
    icon -- the same two the party/raid frames have.

    REUSES THE PARTY INDICATOR WHOLESALE. AEI.CreateDispelsIndicator resolves
    its unit from `button.unit` and builds its overlay against
    `button.healthBar`, and unit frames have both -- so this file hands it a
    settings table of the shape it already expects rather than being a second
    implementation of dispel tracking. That matters: the party version encodes
    a pile of hard-won 12.1 behaviour (bare noRegions slots, the
    SetGradient-breaks-SetAlpha workaround, per-type slot refresh) that would
    be miserable to get right twice.

    So the settings below are deliberately named to MATCH the party indicator's
    own keys -- dispelTypesEnabled, dispelColors, dispelOverlay,
    dispelOverlayOpacity, dispelShowAll, showDispelIcons -- and are passed
    straight through. Renaming them for tidiness would mean translating on
    every setter call for no gain.

    THE UNIT BEHIND THE TOKEN STILL CHANGES. A container binds its unit once,
    and "target" is a stable string whose meaning changes constantly -- the
    exact bug that made target-frame aura rows show the previous target. So
    this registers for the same UpdateAllAuras refresh Auras.lua uses, and
    UnitFrames.lua drives it from the token-change events.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local Dispels = {}
SquizzFrames.UnitFrameDispels = Dispels

-- Mirrors AuraEngineIndicators.lua's DISPEL_TYPES, for the options page's
-- per-type colour swatches. Only the fields the panel needs.
Dispels.TYPES = {
    {key = "Magic",   label = "Magic",   default = {0.20, 0.60, 1.00}},
    {key = "Curse",   label = "Curse",   default = {0.60, 0.00, 1.00}},
    {key = "Disease", label = "Disease", default = {0.60, 0.40, 0.00}},
    {key = "Poison",  label = "Poison",  default = {0.00, 0.60, 0.00}},
    {key = "Bleed",   label = "Bleed",   default = {0.75, 0.15, 0.15}},
}

Dispels.OVERLAY_MODES = {
    {value = "full",     text = "Solid"},
    {value = "gradient", text = "Gradient"},
    {value = "none",     text = "Off"},
}

local wrappers = {}   -- [unitToken] = the indicator wrapper

-- The settings table handed to the party indicator. Built from our own
-- per-frame config, using ITS key names -- see the header.
local function BuildSettings(t)
    local c = (t and t.dispels) or {}
    return {
        enabled = c.enabled == true,
        dispelShowAll = c.showAll == true,
        dispelTypesEnabled = c.typesEnabled,
        dispelColors = c.colors,
        dispelOverlay = c.overlay or "full",
        dispelOverlayOpacity = c.opacity or 0.5,
        showDispelIcons = c.showIcons == true,
        -- The wrapper's generic size/position dispatch. The overlay always
        -- spans the health bar, so these only ever place the icon.
        size = {c.iconSize or 16, c.iconSize or 16},
        position = {"TOPRIGHT", "healthBar", "TOPRIGHT", c.iconX or 0, c.iconY or 0},
    }
end

function Dispels.ApplySettings(frame, t)
    if not (frame and frame.unit) then return end
    local AEI = SquizzFrames.AuraEngineIndicators
    if not AEI or not AEI.CreateDispelsIndicator then return end

    local cfg = (t and t.dispels) or {}
    local wrapper = wrappers[frame.unit]

    if not cfg.enabled then
        if wrapper then wrapper:Hide() end
        return
    end

    local settings = BuildSettings(t)

    if not wrapper then
        -- Created on first enable rather than up front: a container carries a
        -- batch of pre-created buttons, so a profile that never uses dispels
        -- should never pay for five frames' worth of them.
        wrapper = AEI.CreateDispelsIndicator(frame, settings)
        if not wrapper then return end
        wrappers[frame.unit] = wrapper
        wrapper._sfTable = settings
    end

    -- Push through the wrapper's own setters rather than rebuilding it.
    -- Containers are permanent and expensive to churn -- the same reason the
    -- aura rows push settings instead of recreating.
    wrapper._sfTable = settings
    if wrapper.SetDispelShowAll then wrapper:SetDispelShowAll(settings.dispelShowAll) end
    if wrapper.SetDispelTypes then wrapper:SetDispelTypes(settings.dispelTypesEnabled) end
    if wrapper.SetDispelColors then wrapper:SetDispelColors(settings.dispelColors) end
    if wrapper.SetDispelOverlay then wrapper:SetDispelOverlay(settings.dispelOverlay) end
    if wrapper.SetDispelOverlayOpacity then
        wrapper:SetDispelOverlayOpacity(settings.dispelOverlayOpacity)
    end
    if wrapper.RefreshBorderInset then wrapper:RefreshBorderInset() end
    wrapper:Show()
end

-- Force a re-parse. Called when a token is repointed -- see the header for why
-- a stable token is not a stable unit.
function Dispels.Refresh(unit)
    local w = unit and wrappers[unit]
    local c = w and w._container
    if c then pcall(c.UpdateAllAuras, c) end
end
