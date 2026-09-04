--[[ SquizzFrames Unit Frames Defaults (Phase 1)

    Standalone single-unit frames: player, target, targettarget, focus,
    focustarget. Deliberately a SEPARATE tree from profile.layout (the party
    header) and profile.petFrames -- none of the group concepts (growth
    direction, sorting, spacing, per-subgroup headers) mean anything to a frame
    that shows exactly one permanently-assigned unit.

    PHASE 1 SCOPE. Cast bars, boss frames, portraits, auras and arena frames
    are Phase 2/3; their settings are deliberately absent rather than present
    and ignored -- a live control that silently does nothing is the exact
    failure this codebase keeps getting bitten by (see PetFrames' options page
    hiding its Width slider when Match Owner Width is on).
]]

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

-- Text content tokens shared by every text slot. Kept as one list so the
-- options dropdowns and the renderer can't drift -- UnitFrames.lua's
-- RenderTextSlot switches on exactly these.
SquizzFrames.UNITFRAME_TEXT_TOKENS = {
    "none",
    "name",
    "health",          -- current, abbreviated (e.g. 1.2M)
    "healthPercent",
    "healthBoth",      -- "1.2M | 84%"
    "healthMax",       -- "1.2M / 1.4M"
    "healthDeficit",   -- "-220k", blank at full
    "power",
    "powerPercent",
    "level",
    "levelClass",      -- "70 Warlock" / "72 Elite"
}

-- One frame's settings. Every unit gets the same shape so the options page can
-- be a single builder parameterised by unit key -- the alternative (per-unit
-- bespoke tables, as the group layouts do for main/raid) does not scale to
-- five frames and would guarantee drift.
--
-- anchorX/anchorY carry the same meaning as profile.layout.main's own fields:
-- raw pixels from UIParent centre, divided by scale at apply time. See
-- CLAUDE.md's "Scale & Position" note -- do not pre-divide when saving.
local function DefaultFrame(opts)
    opts = opts or {}
    return {
        enabled = opts.enabled ~= false,
        width = opts.width or 180,
        height = opts.height or 46,
        anchorX = opts.anchorX or 0,
        anchorY = opts.anchorY or 0,

        -- Power bar. height 0 hides it entirely rather than needing a second
        -- boolean -- one control, no invalid combinations.
        powerHeight = opts.powerHeight or 6,
        powerGap = 1,

        -- Health bar colouring. classColor applies to PLAYERS only; NPCs fall
        -- back to reaction colouring (hostile red / neutral yellow / friendly
        -- green), which is why there is no separate "npcColor" toggle.
        healthClassColor = true,
        healthReactionColor = true,
        healthCustomColor = {0.2, 0.6, 0.2, 1},
        healthBackdropColor = {0, 0, 0, 0.6},

        -- Three text slots per frame, matching where the eye actually looks.
        -- Each is {content, size, offsetX, offsetY, useClassColor}.
        leftText   = {content = opts.leftText   or "name",   size = 12, x = 2,  y = 0, classColor = true},
        rightText  = {content = opts.rightText  or "healthBoth", size = 12, x = -2, y = 0, classColor = false},
        centerText = {content = "none", size = 12, x = 0, y = 0, classColor = false},

        font = {"Friz QT__", 12, "OUTLINE", true},

        -- Out-of-combat fade. Deliberately per-frame: a player frame you want
        -- to disappear when idle is a common ask, a target frame is not.
        fadeOutOfCombat = false,
        fadeAlpha = 0.35,
    }
end

profile.unitFrames = {
    -- Master switch. Off by default -- this module hides Blizzard's own unit
    -- frames when it runs, which is far too invasive to inflict on an existing
    -- user who updates the addon and never asked for it.
    enabled = false,

    -- Mirror the player and target frames across the screen's vertical centre
    -- line: drag either one and the other takes the opposite X at the same Y.
    -- OFF by default and never implicit -- someone who has deliberately placed
    -- an asymmetric layout must not have it silently rearranged by an update.
    --
    -- Bidirectional on purpose (drag EITHER frame), but ApplyLayout normalises
    -- target from player whenever it's on, so the pair can't end up
    -- half-mirrored after a profile switch or a settings edit.
    mirrorPlayerTarget = false,

    -- Whether to hide Blizzard's corresponding frame when ours is enabled.
    -- Separate from `enabled` so someone can run ours alongside Blizzard's
    -- while positioning them, and so the hide is reversible from one place
    -- (HideBlizzard.lua's reparent hide, not UnregisterAllEvents).
    hideBlizzard = true,

    frames = {
        player       = DefaultFrame{anchorX = -260, anchorY = -180,
                                    rightText = "healthBoth"},
        target       = DefaultFrame{anchorX =  260, anchorY = -180,
                                    rightText = "healthBoth"},
        targettarget = DefaultFrame{anchorX =  430, anchorY = -140,
                                    width = 110, height = 26, powerHeight = 0,
                                    leftText = "name", rightText = "healthPercent"},
        focus        = DefaultFrame{anchorX = -260, anchorY = -280,
                                    width = 150, height = 34,
                                    rightText = "healthPercent"},
        focustarget  = DefaultFrame{enabled = false,
                                    anchorX = -100, anchorY = -280,
                                    width = 110, height = 26, powerHeight = 0,
                                    leftText = "name", rightText = "healthPercent"},
    },
}
