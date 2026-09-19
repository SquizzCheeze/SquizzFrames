--[[ SquizzFrames Tank Tracker Defaults

    A compact frame per tank in the group, carrying that tank's incoming boss
    and role DEBUFFS above the bar and their active DEFENSIVES below it.

    Layout is modelled on CoTankTracker (by zerbi), which is the addon that
    established this shape: a thin health bar with the name on it, one icon row
    above, one below, frames stacked in a chosen direction. The implementation
    is entirely our own, on our own AuraEngine rather than oUF.

    WHAT WE TOOK FROM READING IT, which is worth more than the layout -- two
    12.1 engine behaviours that are not documented anywhere and are expensive
    to discover:

      1. C_UnitAuras.GetUnitAuraInstanceIDs applies a filter string's POLARITY
         but ignores its CLASSIFICATION tokens. "HELPFUL|BIG_DEFENSIVE" comes
         back as every helpful aura, and the container trusts it
         (hasMatchedFilterString = true) so the group never re-checks. The
         UNIT_AURA path DOES re-check, which is why the fault presents as
         intermittent rather than constant. Candidate filters are evaluated on
         both paths, so a maxDuration bound narrows the group where the filter
         string cannot -- every real defensive runs well under a minute, and
         the noise it removes (flasks, food, auras, forms) is permanent or very
         long. See DEFENSIVE_MAX_DURATION in TankTracker.lua.

      2. IMPORTANT is not usable on HARMFUL. Blizzard flags HELPFUL auras with
         it, so "HARMFUL|IMPORTANT" is an empty set. The friendly-unit
         equivalents are engine CANDIDATE filters instead: isPriorityAura (the
         curated priority-debuff list the raid frames use) and isBossOrRoleAura
         (boss auras plus role auras), and the latter is where 12.1 actually
         delivers tank mechanics as readable auras.

      3. NEITHER OF THOSE FLAGS IS GUARANTEED. Blizzard authors them per aura,
         so an encounter whose debuffs carry neither shows nothing under either
         preset -- and no setting of ours can make an unflagged aura flagged.
         Found 2026-09-19: the Lost Explorers' debuffs appeared on the party/
         raid Debuffs indicator, which applies NO candidate filters, and on
         nothing in the tank tracker.

         That is what `encounter` is for, and why it is the default: no flag
         narrowing at all, only a maxDuration bound (DEBUFF_MAX_DURATION in
         TankTracker.lua). Same trick as point 1 -- evaluated on both paths,
         and it implicitly drops permanent auras (duration == 0 fails the
         test), which is exactly the noise a tank does not want. It answers
         "what is on this tank right now" instead of "what did Blizzard
         remember to flag".
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local defaults = SquizzFrames.defaults
if not defaults then
    defaults = { profile = {} }
    SquizzFrames.defaults = defaults
end
if not defaults.profile then defaults.profile = {} end

local profile = defaults.profile

-- Debuff filter presets, offered as one dropdown. The value is resolved into a
-- filter string plus candidate filters in TankTracker.lua -- see the note
-- above for why the interesting half is the candidate filters, not the string.
SquizzFrames.TANKTRACKER_DEBUFF_FILTERS = {
    {value = "encounter",      text = "Encounter debuffs"},
    {value = "boss_role",      text = "Boss & role mechanics"},
    {value = "important",      text = "Priority debuffs"},
    {value = "both",           text = "Priority + Boss & role"},
    {value = "raid_important", text = "Priority, raid-relevant only"},
    {value = "raid",           text = "Raid-relevant"},
    {value = "all",            text = "Everything"},
}

-- One icon row's settings. Debuffs and defensives have the same shape so one
-- builder and one block of options serve both.
local function DefaultRow(opts)
    opts = opts or {}
    return {
        enabled = opts.enabled ~= false,
        size = opts.size or 32,
        num = opts.num or 4,
        maxRows = opts.maxRows or 1,
        spacing = opts.spacing or 2,

        -- Our own anchor vocabulary (Modules/UnitFrames/Auras.lua's
        -- ANCHOR_POINTS), not CoTankTracker's anchor+attachTo PAIR. The pair is
        -- more flexible and invites nonsensical combinations; a single named
        -- anchor says "above, left-aligned" in one control, and it is what
        -- every other aura row in this addon already uses.
        anchor = opts.anchor or "topleft",
        offsetX = opts.offsetX or 0,
        offsetY = opts.offsetY or 0,
        -- Growth follows the anchor unless overridden.
        growth = "auto",

        -- Both texts get the same controls: face, size, outline, colour,
        -- anchor, and two offsets. AuraEngine's ApplyFontSlot uses ONE point
        -- for both sides of SetPoint, so an anchor reads as "pin the text's
        -- <corner> to the icon's <corner>" -- which is why these are a single
        -- dropdown rather than a point/relative-point pair.
        --
        -- durationFont/durationOutline (and the stack pair) are DELIBERATELY
        -- ABSENT. Before they existed both texts followed the frame-wide
        -- `font` face and outline, and a profile is a deep copy of these
        -- defaults: shipping "Friz QT__" here would stamp it over anyone who
        -- had already picked a different face. Absent, they fall through to
        -- `font` in TankTracker.ResolveText -- the one resolver the engine,
        -- the preview and the panel all read.
        showDuration = true,
        durationSize = opts.durationSize or 11,
        durationAnchor = "CENTER",
        durationX = 0,
        durationY = 0,
        durationColor = {1, 1, 1, 1},

        showStack = true,
        stackSize = 11,
        stackAnchor = "BOTTOMRIGHT",
        stackX = 1,
        stackY = -1,
        stackColor = {1, 1, 1, 1},

        showBorder = true,
    }
end

profile.tankTracker = {
    enabled = false,

    -- WHO. includeSelf is the setting the reference addon does not have: it
    -- only ever shows OTHER tanks, which means it shows nothing at all when
    -- you are the only tank -- most 5-mans and many raid bosses. Defaulting it
    -- on makes the frame useful solo-tanking; turning it off reproduces
    -- CoTankTracker's behaviour exactly.
    includeSelf = true,
    -- Only show anything while the player is in a tank specialisation. Off by
    -- default so the frame can be found and positioned on any character.
    requireTankSpec = false,
    maxFrames = 4,

    -- WHERE. Raw pixels from UIParent centre, divided by scale at apply time --
    -- the same convention as every other saved position in the addon.
    anchorX = 0,
    anchorY = 260,
    scale = 1,

    -- One frame's size, and how the stack of them grows.
    width = 150,
    height = 20,
    growthDirection = "DOWN",   -- DOWN | UP | LEFT | RIGHT
    -- Generous by default: each frame carries an icon row above AND below, so
    -- a spacing that only clears the bar itself overlaps the neighbours' icons.
    spacing = 80,

    showName = true,
    nameFontSize = 12,
    font = {"Friz QT__", 12, "OUTLINE"},
    nameColor = {1, 1, 1, 1},
    -- Name placement on the health bar: one point used for both sides, like
    -- the unit frames' texts. LEFT/3/0 is exactly where the name sat before it
    -- could be moved, so existing profiles see no change when these backfill.
    nameAnchor = "LEFT",
    nameX = 3,
    nameY = 0,

    -- Health bar. Texture comes from the shared Layout > Appearance setting the
    -- party frames use, so everything matches without a second control.
    healthClassColor = true,
    healthCustomColor = {0.2, 0.6, 0.2, 1},
    backdropColor = {0, 0, 0, 0.6},

    showBorder = true,
    borderColor = {0, 0, 0, 1},
    borderThickness = 1,

    debuffs = DefaultRow{
        anchor = "topleft", offsetY = 2, size = 32, num = 4,
        durationSize = 11,
    },
    -- Duration-bounded rather than flag-based, deliberately -- see point 3 of
    -- the header note. A flag-based default shows NOTHING AT ALL in any
    -- encounter Blizzard did not flag, and does it silently.
    debuffFilter = "encounter",
    -- A permanent debuff has no duration to run down and is rarely the thing a
    -- tank is watching for; off by default because hiding them is the common
    -- want, not because they are never interesting.
    debuffHidePermanent = false,

    defensives = DefaultRow{
        anchor = "bottomleft", offsetY = -2, size = 32, num = 4,
        durationSize = 13,
    },
}
