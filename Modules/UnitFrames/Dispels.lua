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

    So the settings below are deliberately named to MATCH the party indicators'
    own keys -- dispelTypesEnabled, dispelColors, dispelOverlay,
    dispelOverlayOpacity, dispelShowAll -- and are passed straight through.
    Renaming them for tidiness would mean translating on every setter call for
    no gain. The two exceptions are documented where they happen: the opacity
    slider is a fraction here and a percentage there, and each frame claims its
    own AE.styles namespace so its settings don't fight the party list's.

    TWO indicators, not one. The overlay (CreateDispelsIndicator) draws the
    health-bar tint and nothing else; the type symbols are their own indicator
    (CreateDispelIconsIndicator) and have been since 2026-08-13.

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

-- Same five the party indicator offers, same value strings and same labels
-- (CreateSetting_DispelOverlay in IndicatorWidgets.lua) -- "fill" and
-- "gradientTop" were missing here, so two of the party's looks simply weren't
-- reachable on a unit frame.
Dispels.OVERLAY_MODES = {
    {value = "none",        text = "None"},
    {value = "fill",        text = "Fill (Health Loss)"},
    {value = "full",        text = "Full Frame"},
    {value = "gradient",    text = "Blizzard (Strong Bottom)"},
    {value = "gradientTop", text = "Blizzard (Strong Top)"},
}

local wrappers = {}   -- [unitToken] = the overlay indicator wrapper
local iconWrappers = {}   -- [unitToken] = the dispel-icons indicator wrapper

-- The settings tables handed to the party indicators are MUTATED IN PLACE, not
-- rebuilt, because both factories capture the table they were created with and
-- their setters write back into that same table. Handing them a fresh table on
-- every apply would leave the captured one -- the one the styles are actually
-- rebuilt from -- frozen at its creation values.
local settingsTables = {}      -- [unitToken] = overlay settings
local iconSettingsTables = {}  -- [unitToken] = icon settings

-- The overlay and the icons are two SEPARATE indicators, and have been since
-- 2026-08-13 -- the overlay no longer draws a symbol at all. Passing
-- showDispelIcons to CreateDispelsIndicator (which is what this file used to
-- do) therefore reached nothing, which is why no icon ever appeared on a unit
-- frame. Each gets its own settings table below.

local function CopyInto(dst, src)
    for k in pairs(dst) do dst[k] = nil end
    for k, v in pairs(src) do dst[k] = v end
    return dst
end

-- Style keys live in ONE global table (AE.styles), so an indicator that
-- doesn't share the party list's settings has to claim its own namespace or
-- the two overwrite each other -- see CreateDispelsIndicator's own note. Per
-- UNIT, because the unit frames configure dispels per frame.
local function StyleNS(unit) return "uf_" .. tostring(unit) .. "_" end

-- Built from our own per-frame config, using the party indicator's key names.
--
-- PUBLIC because the 1:1 options preview (Preview.lua) has to paint the same
-- overlay from the same numbers. The opacity rescale below is exactly the kind
-- of thing a second, hand-rolled translation gets wrong -- it already was
-- wrong here once -- so there is one translation and both callers use it.
function Dispels.BuildSettings(t, unit)
    local c = (t and t.dispels) or {}
    return {
        _sfStyleNS = StyleNS(unit),
        enabled = c.enabled == true,
        dispelShowAll = c.showAll == true,
        dispelTypesEnabled = c.typesEnabled,
        dispelColors = c.colors,
        dispelOverlay = c.overlay or "full",
        -- PERCENT, not a fraction: BuildDispelStyleForType divides by 100.
        -- Our own slider is 0-1, so it has to be scaled here -- passing it
        -- through raw made every overlay 0.5% opaque, i.e. invisible.
        dispelOverlayOpacity = (c.opacity or 0.5) * 100,
        -- Gradient-mode shape, in percent, ignored by the other modes.
        dispelGradientHeight = c.gradientHeight or 100,
        dispelGradientWeakAlpha = c.gradientWeakAlpha or 50,
    }
end

local function BuildIconSettings(t, unit, frame)
    local c = (t and t.dispels) or {}
    local size = c.iconSize or 16
    return {
        _sfStyleNS = StyleNS(unit),
        -- The party version is placed by the generic indicator dispatch; we
        -- have none, so the tier is passed explicitly. Above the health bar
        -- (MEDIUM, and the overlay slots sit in that strata too) and above the
        -- text host, which takes the frame's level + 6.
        _sfStrata = "MEDIUM",
        _sfLevel = (frame:GetFrameLevel() or 1) + 8,
        size = {size, size},
        dispelShowAll = c.showAll == true,
        dispelTypesEnabled = c.typesEnabled,
        useSpellIcons = c.useSpellIcons == true,
        showSwipe = c.showSwipe == true,
        showIconBorder = c.showIconBorder == true,
        orientation = c.iconOrientation or "horizontal",
        growthDirection = c.iconGrowth or "left-to-right",
    }
end

-- Anchors and sizes the icon wrapper. Ours to do: the party path gets this
-- from Indicators.lua's generic position/size dispatch, which resolves the
-- "healthBar" relative token -- there is no such dispatch here.
local function PlaceIcons(wrapper, frame, c)
    local size = c.iconSize or 16
    local rel = frame.healthBar or frame
    wrapper:ClearAllPoints()
    wrapper:SetPoint("TOPRIGHT", rel, "TOPRIGHT", c.iconX or 0, c.iconY or 0)
    -- Through the overridden SetSize, so the live groups re-layout with it.
    wrapper:SetSize(size, size)
end

function Dispels.ApplySettings(frame, t)
    if not (frame and frame.unit) then return end
    local AEI = SquizzFrames.AuraEngineIndicators
    if not AEI or not AEI.CreateDispelsIndicator then return end

    local unit = frame.unit
    local cfg = (t and t.dispels) or {}
    local wrapper = wrappers[unit]
    local icons = iconWrappers[unit]

    if not cfg.enabled then
        if wrapper then wrapper:Hide() end
        if icons then icons:Hide() end
        return
    end

    local settings = settingsTables[unit]
    if settings then
        CopyInto(settings, Dispels.BuildSettings(t, unit))
    else
        settings = Dispels.BuildSettings(t, unit)
        settingsTables[unit] = settings
    end

    if not wrapper then
        -- Created on first enable rather than up front: a container carries a
        -- batch of pre-created buttons, so a profile that never uses dispels
        -- should never pay for five frames' worth of them.
        wrapper = AEI.CreateDispelsIndicator(frame, settings)
        if not wrapper then return end
        wrappers[unit] = wrapper
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
    if wrapper.SetDispelGradientHeight then
        wrapper:SetDispelGradientHeight(settings.dispelGradientHeight)
    end
    if wrapper.SetDispelGradientWeakAlpha then
        wrapper:SetDispelGradientWeakAlpha(settings.dispelGradientWeakAlpha)
    end
    if wrapper.RefreshBorderInset then wrapper:RefreshBorderInset() end
    wrapper:Show()

    -- The icons, same lifecycle: built on first enable, then pushed.
    if not cfg.showIcons then
        if icons then icons:Hide() end
        return
    end
    if not AEI.CreateDispelIconsIndicator then return end

    local iconSettings = iconSettingsTables[unit]
    if iconSettings then
        CopyInto(iconSettings, BuildIconSettings(t, unit, frame))
    else
        iconSettings = BuildIconSettings(t, unit, frame)
        iconSettingsTables[unit] = iconSettings
    end

    if not icons then
        icons = AEI.CreateDispelIconsIndicator(frame, iconSettings)
        if not icons then return end
        iconWrappers[unit] = icons
    end
    if icons.SetDispelShowAll then icons:SetDispelShowAll(iconSettings.dispelShowAll) end
    if icons.SetDispelTypes then icons:SetDispelTypes(iconSettings.dispelTypesEnabled) end
    PlaceIcons(icons, frame, cfg)
    icons:Show()
end

-- Force a re-parse. Called when a token is repointed -- see the header for why
-- a stable token is not a stable unit.
function Dispels.Refresh(unit)
    if not unit then return end
    for _, tbl in ipairs({wrappers, iconWrappers}) do
        local w = tbl[unit]
        local c = w and w._container
        if c then pcall(c.UpdateAllAuras, c) end
    end
end
