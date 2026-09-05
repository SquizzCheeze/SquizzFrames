--[[ SquizzFrames Unit Frames Defaults (Phase 1)

    Standalone single-unit frames: player, target, targettarget, focus,
    focustarget. Deliberately a SEPARATE tree from profile.layout (the party
    header) and profile.petFrames -- none of the group concepts (growth
    direction, sorting, spacing, per-subgroup headers) mean anything to a frame
    that shows exactly one permanently-assigned unit.

    Phase 2 added cast bars. Auras and arena frames remain Phase 3; their
    settings are deliberately absent rather than present and ignored -- a live
    control that silently does nothing is the exact failure this codebase keeps
    getting bitten by (see PetFrames' options page hiding its Width slider when
    Match Owner Width is on).
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

-- TEXT ELEMENTS (2026-09-05, replacing the old left/right/centre "slots").
--
-- The old model made the ANCHOR the identity: three slots called leftText,
-- rightText and centerText, each with a content dropdown listing every token.
-- That got the hierarchy backwards. You think "I want the level shown", not
-- "I want the centre slot to be the level", and the anchor-as-identity model
-- made three things awkward at once: you could only ever show three of the
-- available readouts, you could show the same one twice by accident, and
-- moving a readout from the left to the right of the frame meant retyping its
-- whole configuration into a different slot.
--
-- Now each READOUT is the group, with its anchor as one of its settings. The
-- four cover everything the old token list did.
SquizzFrames.UNITFRAME_TEXT_ELEMENTS = {"name", "health", "power", "level"}

-- Which content tokens each element can render. UnitFrames.lua's FormatToken
-- switches on exactly these strings -- the lists are split per element rather
-- than kept as one flat set so a dropdown physically cannot offer a health
-- format on the level element.
--
-- No "healthDeficit": max minus current is ARITHMETIC on a secret value,
-- which throws in combat, and there is no C-level API that returns it. See
-- UnitFrames.lua's header.
SquizzFrames.UNITFRAME_TEXT_FORMATS = {
    name   = {"name"},
    health = {"health", "healthPercent", "healthBoth", "healthMax"},
    power  = {"power", "powerPercent"},
    level  = {"level", "levelClass"},
}

-- Every anchor point a text element may use. The element is anchored to the
-- HEALTH bar (not the whole frame) at point-to-same-point, so these read as
-- "which corner/edge of the health bar do I sit on".
SquizzFrames.UNITFRAME_TEXT_ANCHORS = {
    "TOPLEFT", "TOP", "TOPRIGHT",
    "LEFT", "CENTER", "RIGHT",
    "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT",
}

-- One text element's settings.
--
-- classColor defaults to FALSE for every element on every frame. It used to
-- default on for the name, which meant the single most-read piece of text on
-- the frame changed colour per target with no obvious way to find the switch
-- -- and it borrows the HEALTH bar's colour resolution, so on an NPC it was
-- reaction colour rather than anything to do with the name. Off by default
-- with an explicit custom colour underneath is the honest arrangement.
local function DefaultText(opts)
    opts = opts or {}
    return {
        enabled = opts.enabled or false,
        format = opts.format,
        anchor = opts.anchor or "CENTER",
        x = opts.x or 0,
        y = opts.y or 0,
        size = opts.size or 12,
        classColor = false,
        color = opts.color or {1, 1, 1, 1},
    }
end

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

        -- One entry per readout, keyed by UNITFRAME_TEXT_ELEMENTS. Name and
        -- health are on by default because a frame showing neither is not a
        -- unit frame; power and level are off, since both are usually already
        -- legible from the power bar / the target's own frame and both crowd
        -- a small frame badly.
        texts = {
            name   = DefaultText{enabled = opts.nameText ~= false, format = "name",
                                 anchor = "LEFT", x = 2},
            health = DefaultText{enabled = opts.healthText ~= false,
                                 format = opts.healthFormat or "healthBoth",
                                 anchor = "RIGHT", x = -2},
            power  = DefaultText{format = "powerPercent", anchor = "CENTER"},
            level  = DefaultText{format = "level", anchor = "TOPLEFT", x = 2},
        },

        font = {"Friz QT__", 12, "OUTLINE", true},

        -- Show nicknames in the "name" text token instead of the real name.
        -- Purely cosmetic and entirely local -- it changes nothing anybody
        -- else sees, and it works on your own player frame too (Nicknames'
        -- Resolve matches on name/realm, not on unit token).
        useNicknames = true,

        -- Out-of-combat fade. Deliberately per-frame: a player frame you want
        -- to disappear when idle is a common ask, a target frame is not.
        fadeOutOfCombat = false,
        fadeAlpha = 0.35,

        -- State icons (Icons.lua). Same shape as each other so one factory and
        -- one block of options serve both.
        --
        -- Both are offered on the PLAYER frame only, by request -- the options
        -- page enforces that (SecIcons), not this table and not the renderer.
        -- Icons.lua reads UnitAffectingCombat(unit) and UnitIsGroupLeader(unit)
        -- on whatever unit it is handed, so these keys stay on every frame:
        -- widening the feature later is deleting one check on the options
        -- page, and a profile that already carries the keys costs nothing.
        combatIcon = {enabled = false, anchor = "TOPRIGHT", x = 0, y = 0,
                      size = 18, color = {1, 1, 1, 1}},
        leaderIcon = {enabled = false, anchor = "TOPLEFT", x = 0, y = 0,
                      size = 14, color = {1, 1, 1, 1}},

        -- Absorb overlays on the health bar (Absorbs.lua).
        --
        -- shieldBar: incoming damage absorb. onlyShowOvershields hides it
        -- until the absorb exceeds missing health, which is the reading that
        -- actually changes a healer's decision.
        --
        -- healAbsorb: healing that will be swallowed before it lands, drawn
        -- inward from the health bar's leading edge (reverseFill).
        --
        -- Both default OFF and to a translucent colour: they sit ON TOP of the
        -- health bar, so an opaque default would hide the bar underneath them.
        shieldBar = {enabled = false, color = {0.6, 0.75, 1, 0.55},
                     onlyShowOvershields = false, reverseFill = false},
        healAbsorb = {enabled = false, color = {0.9, 0.2, 0.2, 0.55},
                      reverseFill = true},

        -- Portrait (Phase 2). size 0 means "match the frame's height", so a
        -- resize carries the portrait with it instead of leaving a mismatch.
        portrait = {
            enabled = false,
            -- "3d" automatically falls back to the 2D portrait for any unit
            -- whose model will not load. On 12.1 SetUnit is documented
            -- RequiresDeclassifiedUnitIdentity and returns a success bool, so
            -- Portrait.lua asks rather than guesses -- see its Update.
            style = "2d",        -- "2d" | "3d" | "class"
            -- Square by default: the round look is the DEFAULT UI's mask, not
            -- something inherent to the portrait, and the class icons have
            -- square atlas art that the circular sheet cannot produce.
            shape = "square",    -- "square" | "circle" (2d and class only)
            side = "LEFT",
            inside = false,      -- true overlaps the bar; false sits beside it
            size = 0,
            offsetX = 0,
            offsetY = 0,
            zoom = 1,            -- 3d only: camera distance scale
            borderColor = {0, 0, 0, 0},
        },

        -- Auras (Phase 3), built on the 12.1 AuraEngine -- see Auras.lua.
        --
        -- anchor "none" is off, which is why there is no separate enabled
        -- flag: one control, and no way to have a row that is enabled but
        -- has nowhere to be. The anchor vocabulary matches EllesmereUI's.
        --
        -- growth "auto" derives from the anchor (a row hung off the left
        -- grows left), which is right almost always; the explicit values are
        -- there for the cases where it is not.
        buffs = {
            anchor = opts.buffs or "none",
            growth = "auto",
            num = 8,
            size = 20,
            offsetX = 0,
            offsetY = 2,
            onlyMine = false,
            showDuration = true,
            showStack = true,
            showBorder = true,
            -- Text placement, passed straight through to the AuraEngine style
            -- (see Auras.lua's BuildStyle). Duration takes TWO points -- its
            -- own and the icon's -- which is what lets it sit outside the icon
            -- (TOP anchored to the icon's BOTTOM, the default) as well as on
            -- it. Stacks take one point, used for both sides, because that is
            -- all the engine's style honours for them.
            durationPoint = "TOP",
            durationRelPoint = "BOTTOM",
            durationX = 0,
            durationY = -2,
            stackPoint = "BOTTOMRIGHT",
            stackX = 1,
            stackY = -1,
        },
        debuffs = {
            anchor = opts.debuffs or "none",
            growth = "auto",
            num = 8,
            size = 22,
            offsetX = 0,
            offsetY = -2,
            -- Debuffs default to yours only on a target: an enemy in a raid
            -- carries far too many for an unfiltered row to be readable.
            onlyMine = false,
            showDuration = true,
            showStack = true,
            showBorder = true,
            -- Text placement, passed straight through to the AuraEngine style
            -- (see Auras.lua's BuildStyle). Duration takes TWO points -- its
            -- own and the icon's -- which is what lets it sit outside the icon
            -- (TOP anchored to the icon's BOTTOM, the default) as well as on
            -- it. Stacks take one point, used for both sides, because that is
            -- all the engine's style honours for them.
            durationPoint = "TOP",
            durationRelPoint = "BOTTOM",
            durationX = 0,
            durationY = -2,
            stackPoint = "BOTTOMRIGHT",
            stackX = 1,
            stackY = -1,
        },

        -- Cast bar (Phase 2). Per-frame rather than shared: you almost
        -- certainly want a bigger, more prominent bar on your target than on
        -- a target-of-target, and some frames want none at all.
        --
        -- width 0 means "match the frame's width", so resizing the frame
        -- carries the bar with it instead of leaving a mismatched stub.
        castBar = {
            enabled = opts.castBar == true,

            -- POSITION, one of three modes:
            --   "frame"  ride this unit frame, above or below it
            --   "anchor" ride ANOTHER frame (a CDM row, another unit frame),
            --            following it automatically wherever it moves --
            --            SetPoint to a live frame tracks it for free
            --   "free"   own screen position, dragged in Edit Mode
            positionMode = "frame",
            anchor = "BOTTOM",       -- "frame" mode: BOTTOM | TOP
            attachTo = "EssentialCooldownViewer", -- "anchor" mode target
            attachSide = "BOTTOM",   -- "anchor" mode: which side of the target
            offsetX = 0,             -- used by "frame" AND "anchor"
            offsetY = 0,
            anchorX = 0,             -- "free" only: pixels from UIParent centre
            anchorY = -300,

            -- SIZE. widthMode decides which of the next two fields matters:
            --   "frame"  follow the unit frame's own width
            --   "custom" use `width`
            --   "match"  track another on-screen frame's width, live
            widthMode = "frame",
            width = 180,
            -- Curated targets only (see CastBar.MATCH_TARGETS) rather than an
            -- arbitrary global name: a typo'd frame name would silently mean
            -- "no match" with nothing to explain why.
            matchFrame = "EssentialCooldownViewer",
            height = 16,

            showIcon = true,
            showName = true,
            showTime = true,
            fontSize = 11,

            -- Class colour of the CASTING unit, falling back to `color` when
            -- the unit is an NPC or its class is secret.
            classColor = false,
            color = {0.9, 0.7, 0.1, 1},
            -- Drawn as a TINT OVER the bar, not as a replacement colour: the
            -- uninterruptible flag is secret on 12.1 and cannot be branched
            -- on, only fed to SetAlphaFromBoolean. See CastBar.lua's header.
            uninterruptibleColor = {0.6, 0.6, 0.6, 0.55},
        },
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

    -- NOTE: hideBlizzard and hideBlizzardCastBar used to live here. Both are
    -- now the single general.hideBlizzardFrames master (2026-09-05), which
    -- also covers party, raid and pet frames -- and which is gated per frame
    -- on ours being enabled, so it needs no separate "let me see both while I
    -- position them" escape hatch: switching ours off is that escape hatch.
    -- MigrateHideBlizzardSwitches in Core.lua strips the two dead keys off
    -- existing profiles.

    frames = {
        player       = DefaultFrame{anchorX = -260, anchorY = -180, castBar = true,
                                    healthFormat = "healthBoth"},
        target       = DefaultFrame{anchorX =  260, anchorY = -180, castBar = true,
                                    buffs = "topleft", debuffs = "bottomleft",
                                    healthFormat = "healthBoth"},
        targettarget = DefaultFrame{anchorX =  430, anchorY = -140,
                                    width = 110, height = 26, powerHeight = 0,
                                    healthFormat = "healthPercent"},
        focus        = DefaultFrame{anchorX = -260, anchorY = -280, castBar = true,
                                    debuffs = "bottomleft",
                                    width = 150, height = 34,
                                    healthFormat = "healthPercent"},
        focustarget  = DefaultFrame{enabled = false,
                                    anchorX = -100, anchorY = -280,
                                    width = 110, height = 26, powerHeight = 0,
                                    healthFormat = "healthPercent"},
    },

    -- BOSS FRAMES. ONE settings table shared by boss1..MAX_BOSS_FRAMES rather
    -- than five: they are a stack of identical frames, and five independent
    -- copies would mean five sets of controls that must be kept in sync by
    -- hand for the layout to look right.
    --
    -- anchorX/anchorY place the FIRST frame; the rest follow it along
    -- growthDirection, spacing pixels apart. Same DefaultFrame shape as the
    -- single units, so every text/colour/cast bar/portrait option applies
    -- identically and the options page reuses the same builder.
    boss = (function()
        local t = DefaultFrame{enabled = false,
                               anchorX = 380, anchorY = 120,
                               width = 170, height = 34, powerHeight = 4,
                               healthFormat = "healthBoth",
                               castBar = true}
        t.spacing = 26
        t.growthDirection = "DOWN"   -- DOWN | UP | RIGHT | LEFT
        return t
    end)(),
}
