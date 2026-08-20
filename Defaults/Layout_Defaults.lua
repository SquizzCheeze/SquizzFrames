--[[ SquizzFrames Layout Defaults ]]
local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local defaults = SquizzFrames.defaults
if not defaults then
    defaults = { profile = {} }
    SquizzFrames.defaults = defaults
end
if not defaults.profile then
    defaults.profile = {}
end

local profile = defaults.profile

-- Named frame-level tiers (Utils.lua's F.LAYER -- loaded earlier per the
-- .toc). Every `frameLevel` below references these instead of a bare
-- number, so the layering scheme has one documented definition rather than
-- being implied by scattered magic numbers. The constants intentionally
-- carry the exact values that were already shipping, so this is a naming
-- change only -- existing saved profiles re-layer identically.
local LAYER = SquizzFrames.F.LAYER

profile.layout = {
    main = {
        width = 100,
        height = 40,
        powerHeight = 4,
        orientation = "vertical",
        growthDirection = "DOWN",
        -- Which point of the container is pinned to the SAME point on
        -- UIParent (POINT->POINT, as Cell/ElvUI do). CENTER keeps the block's
        -- centre locked to the saved offset regardless of how many buttons
        -- are visible, so it grows evenly both ways; an edge/corner point
        -- (TOP, TOPLEFT, ...) nails that edge down and grows away from it,
        -- and keeps the position stable across resolution changes.
        -- CENTER is the historical hardcoded behaviour, so existing profiles'
        -- saved anchorX/anchorY keep their exact meaning with no migration.
        anchorPoint = "CENTER",
        -- Offset from anchorPoint (on the container) to the same point on
        -- UIParent, in raw screen pixels; divided by the UI scale on apply.
        anchorX = 0,
        anchorY = -200,
        spacingY = 0,
        sortByRole = true,
        roleOrder = {"TANK", "HEALER", "DAMAGER"},
        hideSelf = false,
    },
    -- Raid layout: independent from "main" (party) -- separate size, growth,
    -- spacing, and screen position, selected automatically via IsInRaid().
    -- Reuses the same orientation/growthDirection concepts as party, just one
    -- level up: orientation picks whether each 5-unit subgroup is a vertical
    -- column or horizontal row, growthDirection picks which way units grow
    -- WITHIN a subgroup (including CENTER_H/CENTER_V, which center that axis
    -- within each subgroup -- see LayoutRaidGroupHeaders in
    -- PartyFrames.lua), and groupSpacing is the gap BETWEEN subgroup blocks
    -- (spacingY remains the gap between units within one subgroup).
    raid = {
        width = 70,
        height = 24,
        powerHeight = 3,
        orientation = "vertical",
        growthDirection = "DOWN",
        -- See profile.layout.main.anchorPoint above.
        anchorPoint = "CENTER",
        anchorX = 0,
        anchorY = 200,
        spacingY = 0,
        groupSpacing = 6,
        sortByRole = true,
        roleOrder = {"TANK", "HEALER", "DAMAGER"},
        hideSelf = false,
        -- Expected raid size for PREVIEW purposes only (10/20/30/40) -- caps
        -- how many fake units the layout preview populates. Does not affect
        -- real display, which always shows however many units are actually
        -- in the raid regardless of this setting.
        raidSize = 40,
    },
    barOrientation = {
        anchorPoint = "LEFT",
    },
}

-- indicatorIndices maps indicator names to stable slot numbers. Built-ins get
-- fixed slots 1..N; custom indicators are appended to customIndicators as they
-- are created. The runtime uses these slots to key button.indicators.
profile.indicatorIndices = {
    nameText = 1,
    healthText = 2,
    powerText = 3,
    statusText = 4,
    statusIcon = 5,
    roleIcon = 6,
    leaderIcon = 7,
    playerRaidIcon = 8,
    aggroBlink = 9,
    aggroBorder = 10,
    shieldBar = 11,
    externalCooldowns = 12,
    defensiveCooldowns = 13,
    debuffs = 14,
    ccIndicator = 15,
    dispels = 16,
    missingBuffs = 17,
    healerHots = 18,
    shieldOverlay = 19,
    healAbsorb = 20,
    targetHighlight = 21,
    hoverHighlight = 22,
    frameBorder = 23,
    dispelIcons = 24,
    customIndicators = {},
}

-- profile.layout.indicators is an array of indicator tables. Built-ins occupy
-- the first N slots (by convention, in indicatorIndices order); custom
-- indicators are appended after. Each entry follows Cell's schema:
--   {name, indicatorName, type="built-in", enabled, position, frameLevel, ...}
-- where position = {point, relativeTo, relativePoint, x, y} and relativeTo is
-- the literal string "button" or "healthBar" (resolved at anchor time).
profile.layout.indicators = {
    -- 1: Name Text (already wired into the button template as nameText)
    {
        name = "Name Text", indicatorName = "nameText", type = "built-in",
        enabled = true,
        position = {"CENTER", "healthBar", "CENTER", 0, 0}, frameLevel = LAYER.TEXT,
        font = {"Friz QT__", 13, "NONE", true},
        color = {"custom_color", 1, 1, 1, 1},
        textWidth = {"percentage", 0.75},
    },
    -- 2: Health Text
    {
        name = "Health Text", indicatorName = "healthText", type = "built-in",
        enabled = true,
        position = {"LEFT", "healthBar", "LEFT", 3, 0}, frameLevel = LAYER.TEXT,
        font = {"Friz QT__", 11, "NONE", true},
        color = {"class_color"},
        showPercentage = true,
        showCurrent = false,
        showMax = false,
        textWidth = {"percentage", 0.75},
    },
    -- 3: Power Text
    {
        name = "Power Text", indicatorName = "powerText", type = "built-in",
        enabled = false,
        position = {"RIGHT", "healthBar", "RIGHT", -3, 0}, frameLevel = LAYER.TEXT,
        font = {"Friz QT__", 11, "NONE", true},
        color = {"power_color"},
        showPercentage = true,
        showCurrent = false,
        showMax = false,
        textWidth = {"percentage", 0.75},
    },
    -- 4: Status Text (already wired into the button template as statusText)
    {
        name = "Status Text", indicatorName = "statusText", type = "built-in",
        enabled = true,
        position = {"BOTTOM", "healthBar", "BOTTOM", 0, 0}, frameLevel = LAYER.STATUS_TEXT,
        font = {"Friz QT__", 11, "NONE", true},
        showTimer = true,
        colors = {
            ["OFFLINE"] = {1, 0.19, 0.19, 1},
            ["DEAD"] = {1, 0.19, 0.19, 1},
            ["GHOST"] = {1, 0.19, 0.19, 1},
            ["AFK"] = {1, 0.5, 0.1, 1},
            ["DRINKING"] = {0.12, 0.75, 1, 1},
        },
    },
    -- 5: Status Icon (AFK/Dead/Ghost)
    -- frameLevel 35: deliberately above every other built-in's default
    -- (highest otherwise is Status Text at 30) -- user request: this should
    -- render on top of everything else, not just Name Text.
    {
        name = "Status Icon", indicatorName = "statusIcon", type = "built-in",
        enabled = true,
        position = {"TOP", "button", "TOP", 0, -3}, frameLevel = LAYER.STATUS_ICON,
        size = {18, 18},
    },
    -- 6: Role Icon (already wired into the button template as roleIcon)
    {
        name = "Role Icon", indicatorName = "roleIcon", type = "built-in",
        enabled = true, hideDamager = false,
        position = {"TOPLEFT", "button", "TOPLEFT", 0, 0},
        size = {11, 11}, frameLevel = LAYER.ICON,
    },
    -- 7: Leader Icon
    {
        name = "Leader Icon", indicatorName = "leaderIcon", type = "built-in",
        enabled = true, hideInCombat = true,
        position = {"TOPLEFT", "button", "TOPLEFT", 1, -10},
        -- LAYER.ICON, matching Role Icon -- this is its closest sibling in
        -- both shape (CreateIconIndicator) and placement (button corner), and
        -- the two overlapping was the whole reason a frame level was wanted.
        size = {11, 11}, frameLevel = LAYER.ICON,
    },
    -- 8: Player Raid Icon (already wired into the button template as raidIcon)
    {
        name = "Raid Icon (player)", indicatorName = "playerRaidIcon", type = "built-in",
        enabled = true,
        position = {"TOP", "button", "TOP", 0, 3}, frameLevel = LAYER.ICON,
        size = {14, 14}, alpha = 0.77,
    },
    -- 9: Aggro (blink) -- full-button pulsing red border, see
    -- BuiltIn_Update.lua's aggroBlink creation. No position/size (matches
    -- aggroBorder's shape: a border always wraps the whole button).
    {
        name = "Aggro (blink)", indicatorName = "aggroBlink", type = "built-in",
        enabled = true, frameLevel = LAYER.AGGRO_BLINK, thickness = 2,
    },
    -- 10: Aggro (border)
    {
        name = "Aggro (border)", indicatorName = "aggroBorder", type = "built-in",
        enabled = false, frameLevel = LAYER.AGGRO_BORDER, thickness = 2,
    },
    -- 11: Shield Bar
    {
        name = "Shield Bar", indicatorName = "shieldBar", type = "built-in",
        enabled = false,
        position = {"BOTTOMLEFT", nil, "BOTTOMLEFT", 0, 0}, frameLevel = LAYER.ICON,
        height = 4, color = {1, 1, 0, 1},
        onlyShowOvershields = false,
    },
    -- 12: External Cooldowns
    {
        name = "External Cooldowns", indicatorName = "externalCooldowns", type = "built-in",
        enabled = true,
        position = {"RIGHT", "button", "RIGHT", 2, 5}, frameLevel = LAYER.AURA,
        size = {12, 20}, showDuration = false, showAnimation = true,
        num = 2, orientation = "right-to-left",
        font = {{"Friz QT__", 11, "OUTLINE", false, "TOPRIGHT", 2, 1, {1, 1, 1}},
                {"Friz QT__", 11, "OUTLINE", false, "BOTTOMRIGHT", 2, -1, {1, 1, 1}}},
        glowOptions = {"None", {0.95, 0.95, 0.32, 1}},
        useBuiltInExternals = {},
        -- Explicit -- see Missing Buffs' identical comment.
        showIconBorder = true,
    },
    -- 13: Defensive Cooldowns
    {
        name = "Defensive Cooldowns", indicatorName = "defensiveCooldowns", type = "built-in",
        enabled = true,
        position = {"LEFT", "button", "LEFT", -2, 5}, frameLevel = LAYER.AURA,
        size = {12, 20}, showDuration = false, showAnimation = true,
        num = 2, orientation = "left-to-right",
        font = {{"Friz QT__", 11, "OUTLINE", false, "TOPRIGHT", 2, 1, {1, 1, 1}},
                {"Friz QT__", 11, "OUTLINE", false, "BOTTOMRIGHT", 2, -1, {1, 1, 1}}},
        glowOptions = {"None", {0.95, 0.95, 0.32, 1}},
        useBuiltInDefensives = {},
        -- Explicit -- see Missing Buffs' identical comment.
        showIconBorder = true,
    },
    -- 14: Debuffs
    {
        name = "Debuffs", indicatorName = "debuffs", type = "built-in",
        enabled = true,
        position = {"BOTTOMLEFT", "button", "BOTTOMLEFT", 1, 4}, frameLevel = LAYER.ICON,
        -- Flat {w,h} -- was the nested {{normal},{big}} shape for the
        -- dropped bigDebuffCC size-boost, no longer meaningful.
        size = {13, 13}, showDuration = false,
        num = 3,
        font = {{"Friz QT__", 11, "OUTLINE", false, "TOPRIGHT", 2, 1, {1, 1, 1}},
                {"Friz QT__", 11, "OUTLINE", false, "BOTTOMRIGHT", 2, -1, {1, 1, 1}}},
        dispellableByMe = false, hideCCDebuffs = false, orientation = "left-to-right",
        -- Explicit -- see Missing Buffs' identical comment on why an unset
        -- value here would make the checkbox and rendered state disagree.
        showIconBorder = true,
    },
    -- 15: CC Indicator -- was "Raid Debuffs", a stub that never rendered its
    -- own content at all (see BuiltIn_Update.lua's CheckCCIndicator comment
    -- for the full story). Rebuilt as a real crowd-control-only tracker
    -- using Blizzard's native CROWD_CONTROL aura filter tag directly as the
    -- scan filter, so it needs no curated spell list and stays accurate as
    -- Blizzard updates which effects count as CC.
    {
        name = "CC Indicator", indicatorName = "ccIndicator", type = "built-in",
        enabled = true,
        position = {"CENTER", "button", "CENTER", 0, 3}, frameLevel = LAYER.TEXT,
        size = {22, 22}, num = 1,
        font = {{"Friz QT__", 11, "OUTLINE", false, "TOPRIGHT", 2, 1, {1, 1, 1}},
                {"Friz QT__", 11, "OUTLINE", false, "BOTTOMRIGHT", 2, -1, {1, 1, 1}}},
        orientation = "left-to-right",
        -- Explicit -- see Missing Buffs' identical comment.
        showIconBorder = true,
    },
    -- 16: Dispels -- built on AuraEngine (12.1 AuraContainer), mirroring
    -- EllesmereUI's architecture: a health-bar overlay per dispel type
    -- (Magic/Curse/Disease/Poison/Bleed), so it stays accurate through combat
    -- secrecy. size/position drive the single shared dispel-type icon
    -- (highest-priority active type wins) -- draggable on the preview like
    -- any other indicator; the overlay itself always covers the health bar
    -- regardless of these.
    {
        name = "Dispels", indicatorName = "dispels", type = "built-in",
        enabled = true,
        frameLevel = LAYER.DISPEL,
        -- No size or position: the overlay always covers the health bar. Those
        -- only ever existed here to place the dispel-type symbol, which is now
        -- its own "dispelIcons" indicator (see below).
        dispelShowAll = true,           -- true = any dispellable debuff; false = only ones I can dispel
        dispelTypesEnabled = {Magic = true, Curse = true, Disease = true, Poison = true, Bleed = true},
        dispelColors = {
            Magic = {0.20, 0.60, 1.00}, Curse = {0.60, 0.00, 1.00}, Disease = {0.60, 0.40, 0.00},
            Poison = {0.00, 0.60, 0.00}, Bleed = {0.75, 0.15, 0.15},
        },
        -- "gradient"/"gradientTop" = full-height ramp, strongest at the
        -- bottom / at the top respectively (both shown as "Blizzard (...)").
        dispelOverlay = "fill",         -- "none"|"fill"|"full"|"gradient"|"gradientTop"
        dispelOverlayOpacity = 40,
        -- Gradient modes only. Height = % of the health bar the ramp spans,
        -- measured from its strong (pinned) edge. WeakAlpha = the faint end's
        -- alpha as a % OF dispelOverlayOpacity, so the two can't invert.
        dispelGradientHeight = 50,
        dispelGradientWeakAlpha = 50,
    },
    -- 17: Missing Buffs
    {
        name = "Missing Buffs", indicatorName = "missingBuffs", type = "built-in",
        enabled = false,
        position = {"BOTTOMRIGHT", "button", "BOTTOMRIGHT", 0, 4}, frameLevel = LAYER.AURA,
        size = {13, 13}, orientation = "right-to-left",
        -- Explicit (not left to a code fallback) since the checkbox
        -- widget's own default display (SetChecked(not not t.showIconBorder))
        -- would show unchecked/false for a nil value, while CheckMissingBuffs
        -- treats nil as "on" -- an unset value here would make the checkbox
        -- and the actual rendered state visually disagree on first open.
        showIconBorder = true,
    },
    -- 18: Healer HoTs -- built on AuraEngine (12.1 AuraContainer), the only
    -- indicator rendering path that stays accurate in combat. Enabled by
    -- default: healers shouldn't need /sfhealers to get HoT tracking.
    {
        name = "Healer HoTs", indicatorName = "healerHots", type = "built-in",
        enabled = true,
        position = {"TOP", "button", "TOP", 0, 2}, frameLevel = LAYER.AURA,
        size = {16, 16}, num = 5, orientation = "right-to-left",
        castBy = "me",
        -- Stack + duration font, same two-slot shape (and same values) as
        -- Debuffs/CC/the Cooldown indicators above. Slot 1 = stack, slot 2 =
        -- duration; each is {name, size, outline, shadow, anchor, x, y, color}.
        --
        -- REQUIRED, not optional: the settings panel's font widgets bind to
        -- t.font and do nothing at all when it's absent, so without this the
        -- Stack/Duration Font blocks render but every edit is silently
        -- discarded (confirmed 2026-08-13 by runtime dump -- font=NIL
        -- while the style still held its hardcoded defaults).
        font = {{"Friz QT__", 11, "OUTLINE", false, "TOPRIGHT", 2, 1, {1, 1, 1}},
                {"Friz QT__", 11, "OUTLINE", false, "BOTTOMRIGHT", 2, -1, {1, 1, 1}}},
        -- Explicit -- see Missing Buffs' identical comment.
        showIconBorder = true,
    },
    -- 19: Shield Overlay -- health-bar overlay showing absorb shields, mirroring
    -- Cell's shieldBar/shieldBarR + overShieldGlow(R) system (Media\shield.tga,
    -- overshield.tga, overshield_reversed.tga -- assets already bundled for this).
    -- Always covers the health bar (no position of its own), forward-fills from
    -- the left by default (absorbs/maxHealth), or from the right when
    -- reverseFill is enabled. The glow shows when shield+health exceeds max
    -- health ("overshielding").
    {
        name = "Shield Overlay", indicatorName = "shieldOverlay", type = "built-in",
        enabled = false,
        frameLevel = LAYER.BAR_OVERLAY,
        barTexture = "Shield",
        color = {"custom_color", 1, 1, 1, 0.5},
        reverseFill = false,
        showOvershieldGlow = true,
        -- Tint for the overshield glow strip only (the bar's own colour is
        -- `color` above). White = the texture exactly as authored, so the
        -- default is a no-op.
        glowColor = {"custom_color", 1, 1, 1, 1},
    },
    -- 20: Heal Absorb -- health-bar overlay showing "reduced healing" debuffs
    -- (UnitGetTotalHealAbsorbs), mirroring Cell's absorbsBar + overAbsorbGlow.
    -- Reverse-fills from the right (health absorb eats into the healable
    -- portion of the bar first). Glow (Media\overabsorb.tga) shows when the
    -- heal-absorb amount fully covers current health.
    {
        name = "Heal Absorb", indicatorName = "healAbsorb", type = "built-in",
        enabled = false,
        frameLevel = LAYER.BAR_OVERLAY,
        barTexture = "Solid",
        color = {"custom_color", 0.8, 0.1, 0.1, 0.6},
        showOverAbsorbGlow = true,
        -- See Shield Overlay's glowColor: tints the over-absorb strip only.
        glowColor = {"custom_color", 1, 1, 1, 1},
    },
    -- 21: Target Highlight -- full-button border shown when this unit is the
    -- player's current target. Same 4-texture border shape as aggroBorder,
    -- just driven by UnitIsUnit(unit, "target") instead of threat. Enabled by
    -- default (unlike aggroBorder) since there's no other indicator that
    -- already covers this and it's a baseline-expected unit frame feature.
    -- Suppressed while the button is hovered (see hoverHighlight below) --
    -- mirrors EllesmereUIRaidFrames' single-border priority: hover > target,
    -- never both drawn at once.
    -- color uses the tagged {"custom_color", r,g,b,a} shape -- F.ColorRGB
    -- (what the generic per-indicator color-apply path uses) only recognizes
    -- "class_color"/"custom_color" tags; an untagged {r,g,b,a} tuple falls
    -- through to its white fallback regardless of the actual stored values.
    {
        name = "Target Highlight", indicatorName = "targetHighlight", type = "built-in",
        enabled = true, frameLevel = LAYER.TARGET, thickness = 2, color = {"custom_color", 1, 1, 1, 1},
    },
    -- 22: Hover Highlight -- full-button border shown while the mouse is over
    -- this button. Replaces the old always-on-hover $parentHighlight overlay
    -- wash (UnitButton.xml's "highlight" texture, still present but no longer
    -- driven) with a border, matching EllesmereUIRaidFrames' look. Takes
    -- visual priority over Target Highlight when both would apply.
    {
        name = "Hover Highlight", indicatorName = "hoverHighlight", type = "built-in",
        enabled = true, frameLevel = LAYER.HOVER, thickness = 2, color = {"custom_color", 1, 1, 1, 1},
    },
    -- 23: Frame Border -- static, always-visible decorative border around the
    -- whole button (matches EllesmereUIRaidFrames' "Border Style"/"Border
    -- Size" general frame chrome). Unlike aggroBorder/targetHighlight/
    -- hoverHighlight, this has no on/off CONDITION beyond the enabled flag
    -- itself -- HandleIndicators' generic Show()/Hide() dispatch already
    -- handles that, so no Check function is needed at all. Disabled by
    -- default (opt-in decorative extra, matching aggroBorder's own
    -- off-by-default convention); low frameLevel so target/hover/aggro
    -- borders (which ARE meaningful state) still draw above it.
    {
        name = "Frame Border", indicatorName = "frameBorder", type = "built-in",
        enabled = false, frameLevel = LAYER.FRAME_BORDER, thickness = 1, color = {"custom_color", 0, 0, 0, 1},
    },
    -- 24: Dispel Icons -- the dispel-TYPE symbols, split out of the Dispels
    -- overlay on 2026-08-13 so they can be sized and positioned independently
    -- of it. One icon per active dispel type, deduplicated (three Magic
    -- debuffs = one Magic symbol) and laid out by the engine; see
    -- AEI.CreateDispelIconsIndicator.
    --
    -- Inherits the position/size the overlay used to carry for its single
    -- icon, so an existing profile keeps the placement it already had.
    -- Disabled by default, matching the old showDispelIcons default.
    {
        name = "Dispel Icons", indicatorName = "dispelIcons", type = "built-in",
        enabled = false,
        position = {"RIGHT", "healthBar", "RIGHT", 2, 0}, frameLevel = LAYER.DISPEL,
        size = {16, 16},
        -- Row/column and which way the icons grow. Resolved by
        -- ResolveOrientation in AuraEngineIndicators.lua into the flow axis,
        -- growth directions and the container's own anchor corner.
        orientation = "horizontal",
        growthDirection = "left-to-right",
        dispelShowAll = true,           -- true = any dispellable debuff; false = only ones I can dispel
        -- Per-type filter, independent of the overlay's map of the same name:
        -- a disabled type sets its group's frame cap to 0, so the symbol never
        -- appears while the overlay can still colour the bar for it.
        dispelTypesEnabled = {Magic = true, Curse = true, Disease = true, Poison = true, Bleed = true},
        -- Off by default: these are shaped symbol atlases, not icon artwork,
        -- so the swipe's dim fill and an outside border both fight them.
        showSwipe = false,
        showIconBorder = false,
        -- Show the actual debuff's own icon instead of the dispel-type symbol.
        -- Off by default -- the symbol is the point of this indicator, and it
        -- stays readable at 16px where a spell icon often doesn't. Note the
        -- dedupe still applies, so with this on you see the icon of whichever
        -- debuff of that type the game ranks first, not all of them.
        useSpellIcons = false,
    },
}

-- Raid gets its own fully independent indicator array (enable/position/size/
-- font/color/etc. can all diverge from Party), mirroring how profile.layout
-- already splits main (party) vs raid for width/height/growth/etc. A deep
-- copy (F.CopyTable, not a shared reference -- a plain `= profile.layout
-- .indicators` here would alias the SAME table, so editing one context would
-- silently edit both) so Raid starts out looking identical to Party's
-- defaults but the two are genuinely independent tables from the very first
-- profile a user ever gets.
profile.layout.indicatorsRaid = SquizzFrames.F.CopyTable(profile.layout.indicators)

defaults.profile = profile
