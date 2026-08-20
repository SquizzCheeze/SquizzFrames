--[[ SquizzFrames IndicatorDefaults.lua - Module-side defaults accessor ]]
--
-- The DB defaults (Indicator_Defaults.lua in the Defaults/ folder) already
-- populated SquizzFrames.GetDefaultCustomIndicatorTable and the spell-ID
-- lists. This file re-exports them for the runtime modules and options panel
-- under the Indicators namespace.

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

-- Re-export the factory function and spell ID lists for convenience.
-- The actual data lives in Defaults/Indicator_Defaults.lua and is already
-- available on the SquizzFrames global from load time.
local IndicatorDefaults = {}

--- Returns a default custom indicator table for the given type and auraType.
---@param name string Display name
---@param indicatorName string Unique key (e.g. "indicator1")
---@param type string One of: icon, icons, text, bar, bars, rect, color, texture, glow, overlay, block, blocks, border
---@param auraType string "buff" or "debuff"
---@return table defaultIndicatorTable
function IndicatorDefaults.GetDefaultCustomIndicatorTable(name, indicatorName, type, auraType)
    if SquizzFrames.GetDefaultCustomIndicatorTable then
        return SquizzFrames.GetDefaultCustomIndicatorTable(name, indicatorName, type, auraType)
    end
    return {}
end

--- Return the external defensive spell ID list (curated healer-focused subset).
function IndicatorDefaults.GetExternalCooldowns()
    return SquizzFrames.defaults and SquizzFrames.defaults.externalCooldowns or {}
end

--- Return the personal defensive spell ID list.
function IndicatorDefaults.GetDefensiveCooldowns()
    return SquizzFrames.defaults and SquizzFrames.defaults.defensiveCooldowns or {}
end

--- Built-in count constant. Indicators 1..BUILT_IN_COUNT are built-ins;
--- everything after is custom.
IndicatorDefaults.BUILT_IN_COUNT = 24

--- Display names for the built-ins, keyed by indicatorName.
IndicatorDefaults.BUILT_IN_NAMES = {
    nameText = "Name Text",
    statusText = "Status Text",
    statusIcon = "Status Icon",
    roleIcon = "Role Icon",
    leaderIcon = "Leader Icon",
    playerRaidIcon = "Raid Icon (player)",
    aggroBlink = "Aggro (blink)",
    aggroBorder = "Aggro (border)",
    shieldBar = "Shield Bar",
    externalCooldowns = "External Cooldowns",
    defensiveCooldowns = "Defensive Cooldowns",
    debuffs = "Debuffs",
    ccIndicator = "CC Indicator",
    dispels = "Dispels",
    missingBuffs = "Missing Buffs",
    healthText = "Health Text",
    powerText = "Power Text",
    healerHots = "Healer HoTs",
    shieldOverlay = "Shield Overlay",
    healAbsorb = "Heal Absorb",
    targetHighlight = "Target Highlight",
    hoverHighlight = "Hover Highlight",
    frameBorder = "Frame Border",
    dispelIcons = "Dispel Icons",
}

--- Every custom indicator type the runtime knows how to dispatch, whether or
--- not it is currently offered in the Create dropdown. Kept complete so an
--- indicator of a hidden type that already exists in a profile still resolves
--- normally -- hiding a type only stops NEW ones being made.
IndicatorDefaults.CUSTOM_TYPES_ALL = {
    { value = "icon",    text = "Icon" },
    { value = "icons",   text = "Icons" },
    { value = "text",    text = "Text" },
    { value = "bar",     text = "Bar" },
    { value = "bars",    text = "Bars" },
    { value = "rect",    text = "Rect" },
    { value = "color",   text = "Color" },
    { value = "texture", text = "Texture" },
    { value = "glow",    text = "Glow" },
    { value = "overlay", text = "Overlay" },
    { value = "block",   text = "Block" },
    { value = "blocks",  text = "Blocks" },
    { value = "border",  text = "Border" },
}

--- The types actually OFFERED in the Create dropdown.
---
--- Only Icon, Bar and Color have been confirmed working in game (2026-08-14).
--- The rest were carried over from the original Cell-derived type list and have
--- never been verified end to end -- several may have no working factory, no
--- settings tokens, or no dispatch branch at all. Offering a type that quietly
--- does nothing is worse than not offering it, and this codebase has been bitten
--- repeatedly by exactly that shape of silent no-op.
---
--- TO RE-ENABLE ONE: verify it renders and responds to its settings on a live
--- frame, then move its line up from CUSTOM_TYPES_ALL into this list. Nothing
--- else needs changing -- this table is the Create dropdown's only source.
IndicatorDefaults.CUSTOM_TYPES = {
    { value = "icon",  text = "Icon" },
    { value = "bar",   text = "Bar" },
    { value = "color", text = "Color" },
}

--- Aura type choices (for the Create dropdown).
IndicatorDefaults.AURA_TYPES = {
    { value = "buff",   text = "Buff" },
    { value = "debuff", text = "Debuff" },
}

--- Settings token arrays per built-in indicator. Copied 1:1 from Cell's
--- Modules/Indicators/Indicators.lua indicatorSettings (retail/Mists branch).
IndicatorDefaults.BUILT_IN_SETTINGS = {
    nameText    = {"enabled", "color-class", "textWidth", "checkbutton:showGroupNumber", "checkbutton2:hideRealmName", "vehicleNamePosition", "position", "frameLevel", "font-noOffset"},
    statusText  = {"enabled", "checkbutton:showTimer", "checkbutton2:showBackground", "statusPosition", "frameLevel", "font-noOffset"},
    statusIcon  = {"enabled", "size-square", "position", "frameLevel"},
    roleIcon    = {"enabled", "checkbutton:hideDamager", "size-square", "roleTexture", "position", "frameLevel"},
    leaderIcon  = {"enabled", "checkbutton:hideInCombat", "size-square", "position", "frameLevel"},
    playerRaidIcon = {"enabled", "size-square", "alpha", "position", "frameLevel"},
    -- Full-button pulsing red border (see BuiltIn_Update.lua's aggroBlink
    -- creation) -- no position/size tokens, same shape as aggroBorder.
    aggroBlink  = {"enabled", "thickness", "frameLevel"},
    aggroBorder = {"enabled", "thickness", "frameLevel"},
    -- Same full-button border shape, driven by UnitIsUnit(unit, "target").
    -- color-alpha matches EllesmereUIRaidFrames' targetBorderColor/Alpha.
    targetHighlight = {"enabled", "thickness", "color-alpha", "frameLevel"},
    -- Full-button border driven by mouseover (OnEnter/OnLeave in
    -- UnitButton.lua). color-alpha matches Ellesmere's hoverBorderColor/Alpha.
    hoverHighlight = {"enabled", "thickness", "color-alpha", "frameLevel"},
    -- Static decorative border, no on/off condition beyond enabled itself.
    frameBorder = {"enabled", "thickness", "color-alpha", "frameLevel"},
    shieldBar   = {"enabled", "checkbutton:onlyShowOvershields", "color-alpha", "height", "position", "frameLevel"},
    externalCooldowns = {"enabled", "builtInExternals", "customExternals", "durationVisibility", "checkbutton:showAnimation", "checkbutton2:showIconBorder", "checkbutton3:showStack", "checkbutton4:showUnfiltered", "glowOptions", "size", "num:5", "orientation", "position", "frameLevel", "font1:stackFont", "font2:durationFont"},
    defensiveCooldowns = {"enabled", "builtInDefensives", "customDefensives", "durationVisibility", "checkbutton:showAnimation", "checkbutton2:showIconBorder", "checkbutton3:showStack", "checkbutton4:showUnfiltered", "glowOptions", "size", "num:5", "orientation", "position", "frameLevel", "font1:stackFont", "font2:durationFont"},
    -- AuraEngine-backed (AEI.CreateDebuffsIndicator) -- bigDebuffCC (no
    -- native "is this CC" sort criterion), showAnimation/glowOptions (never
    -- implemented for AuraEngine indicators, including the already-migrated
    -- cooldowns), showTooltip (unimplemented), and enableBlacklistShortcut
    -- (would need a script handler on an engine-managed button, which the
    -- engine forbids outright) are all dropped -- see CreateDebuffsIndicator's
    -- comment for the full rationale. showStack IS exposed here even though
    -- it only works on the pre-12.1 CreateCooldownGrid fallback (SetShowStack
    -- doesn't exist on the AuraEngine wrapper, so the checkbox is a silent
    -- no-op once 12.1 takes over -- same tradeoff as everything else in this
    -- comment, just not dropped outright since it's still useful pre-12.1).
    debuffs     = {"enabled", "checkbutton:dispellableByMe", "checkbutton2:showStack", "checkbutton3:hideCCDebuffs", "debuffBlacklist", "durationVisibility", "checkbutton6:showIconBorder", "size-square", "num:10", "orientation", "position", "frameLevel", "font1:stackFont", "font2:durationFont"},
    ccIndicator = {"enabled", "checkbutton:showIconBorder", "checkbutton2:showStack", "durationVisibility", "size-square", "num:3", "orientation", "position", "frameLevel", "font1:stackFont", "font2:durationFont"},
    -- Built on AuraEngine (12.1 AuraContainer), mirroring EllesmereUI's
    -- architecture -- see AEI.CreateDispelsIndicator in
    -- AuraEngineIndicators.lua. The health-bar overlay always covers the
    -- health bar itself (no position/size of its own); size/position here
    -- instead drive the single shared dispel-type icon (highest-priority
    -- active type wins), draggable on the preview like any other indicator.
    -- Health-bar OVERLAY only. The overlay always covers the health bar, so
    -- it has no size or position of its own; the dispel-type symbols moved to
    -- their own "dispelIcons" indicator (2026-08-13) and took size/position/
    -- the show-icons checkbox with them.
    dispels     = {"enabled", "dispelShowAll", "dispelTypeColors", "dispelOverlay", "dispelOverlayOpacity", "dispelGradientHeight", "dispelGradientWeakAlpha", "frameLevel"},
    -- Dispel-type symbols, one per type, deduplicated and laid out by the
    -- engine (AEI.CreateDispelIconsIndicator). Swipe and border are off by
    -- default -- see BuildDispelIconsStyle for why.
    dispelIcons = {"enabled", "dispelShowAll", "dispelTypes", "checkbutton:useSpellIcons", "checkbutton2:showSwipe", "checkbutton3:showIconBorder", "size-square", "growthOrientation", "position", "frameLevel"},
    missingBuffs = {"enabled", "builtInMissingBuffs", "customMissingBuffs", "checkbutton:showIconBorder", "size-square", "num:10", "orientation", "position", "frameLevel"},
    healthText  = {"enabled", "color-class", "checkbutton:showPercentage", "checkbutton2:showCurrent", "checkbutton3:showMax", "textWidth", "position", "frameLevel", "font-noOffset"},
    powerText   = {"enabled", "color-class", "color-power", "checkbutton:showPercentage", "checkbutton2:showCurrent", "checkbutton3:showMax", "textWidth", "position", "frameLevel", "font-noOffset"},
    -- Built on AuraEngine (12.1 AuraContainer) instead of the manual scan
    -- path, so it stays accurate in combat.
    --
    -- durationVisibilitySimple is the full dropdown MINUS "On Hover" (which
    -- needs a script handler on the aura button, forbidden on engine-managed
    -- buttons). The two thresholds work here exactly as everywhere else --
    -- they're evaluated engine-side as formatter breakpoints, never in Lua.
    --
    -- font1/font2 replace the old standalone durationOffset widget: the font
    -- blocks carry size, outline, shadow, ANCHOR, X/Y offset and colour for
    -- the stack and duration text, each under its own section header, which
    -- is a superset of what durationOffset did (X/Y only). Keeping both would
    -- mean two controls writing style.durationX/Y and fighting each other.
    healerHots  = {"enabled", "checkbutton:showIconBorder", "checkbutton2:showStack", "checkbutton3:showUnfiltered", "size-square", "num:10", "orientation", "castBy", "durationVisibilitySimple", "builtInHots", "position", "frameLevel", "font1:stackFont", "font2:durationFont"},
    -- Health-bar overlays (like dispels) -- always cover the health bar, no
    -- position/size of their own. See BU.CreateShieldOverlayIndicator /
    -- CreateHealAbsorbIndicator in BuiltIn_Update.lua.
    shieldOverlay = {"enabled", "barTexture", "color-alpha", "checkbutton:reverseFill", "checkbutton2:showOvershieldGlow", "glowColor", "frameLevel"},
    healAbsorb    = {"enabled", "barTexture", "color-alpha", "checkbutton:showOverAbsorbGlow", "glowColor", "frameLevel"},
}

--- Settings token arrays per custom indicator type. Copied 1:1 from Cell's
--- custom type branches.
IndicatorDefaults.CUSTOM_SETTINGS = {
    icon    = {"enabled", "auras", "checkbutton3:showStack", "durationVisibility", "checkbutton4:showAnimation", "glowOptions", "size-square", "position", "frameLevel", "font1:stackFont", "font2:durationFont"},
    icons   = {"enabled", "auras", "checkbutton3:showStack", "durationVisibility", "checkbutton4:showAnimation", "glowOptions", "size-square", "num:10", "numPerLine:10", "spacing", "orientation", "position", "frameLevel", "font1:stackFont", "font2:durationFont"},
    text    = {"enabled", "auras", "duration", "stack", "colors", "position", "frameLevel", "font-noOffset"},
    bar     = {"enabled", "auras", "maxValue", "colors", "checkbutton3:showStack", "durationVisibility", "barOrientation", "glowOptions", "size", "position", "frameLevel", "font1:stackFont", "font2:durationFont"},
    bars    = {"enabled", "auras", "maxValue", "checkbutton3:showStack", "durationVisibility", "glowOptions", "size", "num:10", "numPerLine:10", "spacing", "orientation", "position", "frameLevel", "font1:stackFont", "font2:durationFont"},
    rect    = {"enabled", "auras", "colors", "checkbutton3:showStack", "durationVisibility", "glowOptions", "size", "position", "frameLevel", "font1:stackFont", "font2:durationFont"},
    color   = {"enabled", "auras", "customColors", "expiringColor", "anchor", "frameLevel:50"},
    texture = {"enabled", "checkbutton3:fadeOut", "auras", "texture", "size", "position", "frameLevel"},
    glow    = {"enabled", "checkbutton3:fadeOut", "auras", "glowOptions", "frameLevel"},
    overlay = {"enabled", "auras", "overlayColors", "checkbutton3:smooth", "barOrientation", "frameLevel:50"},
    block   = {"enabled", "auras", "blockColors", "checkbutton3:showStack", "durationVisibility", "glowOptions", "size", "position", "frameLevel", "font1:stackFont", "font2:durationFont"},
    blocks  = {"enabled", "auras", "checkbutton3:showStack", "durationVisibility", "glowOptions", "size", "num:10", "numPerLine:10", "spacing", "orientation", "position", "frameLevel", "font1:stackFont", "font2:durationFont"},
    border  = {"enabled", "checkbutton3:fadeOut", "auras", "thickness", "frameLevel:50"},
}

SquizzFrames.IndicatorDefaults = IndicatorDefaults
