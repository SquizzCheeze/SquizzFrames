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
    power  = {"power", "powerPercent", "powerMax"},
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

        -- HEALTH GRADIENT. Colour the bar by REMAINING HEALTH rather than by
        -- who the unit is: green at full, through amber, to red as they drop.
        --
        -- Takes precedence over class/reaction/custom colouring when on --
        -- they answer different questions ("who is this" vs "how hurt are
        -- they") and cannot both drive one bar, so the more specific request
        -- wins and the others stay as the fallback.
        --
        -- See F.ApplyHealthGradient in Utils.lua. The value never reaches Lua:
        -- a colour curve is handed to UnitHealthPercent and the ENGINE
        -- evaluates it, because health is a secret number on 12.1 and any
        -- arithmetic on one throws.
        healthGradient = {
            enabled = false,
            -- "smooth" blends between the three colours; "bands" snaps to the
            -- nearest one, for people who want a clear three-state readout.
            style = "smooth",
            high = {0.10, 0.85, 0.10, 1},   -- at full health
            mid  = {0.95, 0.80, 0.15, 1},   -- at `midpoint`
            low  = {0.85, 0.15, 0.15, 1},   -- at empty
            midpoint = 0.5,
        },

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
        -- else sees.
        --
        -- THE PLAYER FRAME ONLY, which is why this is opt-in per frame rather
        -- than a flat `true`: Nicknames' Resolve matches on name and realm and
        -- knows nothing about tokens, so it answered just as happily for
        -- "target" and "boss1" -- and since the options page only ever offered
        -- the checkbox on the player frame, every other frame ran on a saved
        -- `true` that nobody could see or switch off. UnitFrames.lua's
        -- FormatToken now enforces the scope as well, so this key is
        -- meaningless anywhere else and Core.lua purges it from existing
        -- profiles (MigrateUnitFrameNicknames).
        useNicknames = opts.useNicknames == true or nil,

        -- Out-of-combat fade. Deliberately per-frame: a player frame you want
        -- to disappear when idle is a common ask, a target frame is not.
        fadeOutOfCombat = false,
        fadeAlpha = 0.35,

        -- Dispel overlay + icon (Dispels.lua). The key names inside `dispels`
        -- are OURS; Dispels.lua translates them to the party indicator's own
        -- key names, which it reuses wholesale rather than reimplementing.
        dispels = {
            enabled = false,
            -- The same five the party indicator offers -- see
            -- Dispels.OVERLAY_MODES: "none"|"fill"|"full"|"gradient"|
            -- "gradientTop". "none" leaves the icon (below) on its own.
            overlay = "full",
            -- 0-1 HERE, but a percentage on the party indicator; Dispels.lua
            -- scales it on the way through.
            opacity = 0.5,
            -- Gradient modes only, both percentages. Height = how much of the
            -- bar the ramp spans from its strong edge; fade = the faint end's
            -- alpha as a percentage OF opacity, so the two can't invert.
            --
            -- Height 100 (the whole bar) as of 2026-09-11, matching the
            -- party/raid indicator's own default -- the two describe the same
            -- overlay and should not disagree about its shape.
            gradientHeight = 100,
            gradientWeakAlpha = 50,
            -- Off = only the types YOU can dispel. On = every dispellable
            -- type, which is what a non-healer watching a tank usually wants.
            showAll = false,
            -- The dispel-type symbols are their OWN indicator (one icon per
            -- active type, deduped), not part of the overlay above.
            showIcons = false,
            iconSize = 16,
            iconX = 0,
            iconY = 0,
            -- Icon look. All off: these are Blizzard's dispel-type atlases,
            -- shaped artwork on transparency that the usual icon furniture
            -- fights. useSpellIcons swaps the symbol for the debuff's own art.
            useSpellIcons = false,
            showSwipe = false,
            showIconBorder = false,
            -- nil means "every type on" and "use the game's own colours"; the
            -- panel only writes these once you change one, so a default
            -- profile carries no copy of Blizzard's palette to go stale.
            typesEnabled = nil,
            colors = nil,
        },

        -- Hover / target / aggro highlights (Highlights.lua). PER FRAME and
        -- isolated from the party/raid indicator system on purpose -- see
        -- that file's header for why a third Indicators tab was rejected.
        --
        -- All default OFF: these are new to the unit frames, and nobody's
        -- layout should change under them on update.
        highlights = {
            hover  = {enabled = false, color = {1, 1, 1, 1},       thickness = 2},
            target = {enabled = false, color = {1, 0.82, 0, 1},    thickness = 2},
            -- blinkOptions is POSITIONAL, matching the party indicators' own
            -- format so BU.AttachBlinkBehaviour's SetBlinkOptions takes it
            -- unchanged: {seconds per half-pulse, percent to fade down to,
            -- pulse on/off}. Pulse defaults OFF here exactly as it does on the
            -- party Aggro (border).
            aggro  = {enabled = false, color = {0.9, 0.1, 0.1, 1}, thickness = 2,
                      blinkOptions = {0.5, 25, false}},
        },

        -- Frame border. Every other frame type in the addon already had one --
        -- pet buttons, the resource bar, the tank tracker, all on the shared
        -- BU.CreateBorderIndicator factory -- and the unit frames were simply
        -- the one that never got it (user request 2026-09-09).
        --
        -- padding pushes it outward from the frame's edge; at 0 it sits on the
        -- edge itself, over the outermost pixel of the bars, matching how the
        -- party frame border behaves.
        border = {
            enabled = false,
            thickness = 1,
            padding = 0,
            color = {0, 0, 0, 1},
        },

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
            -- (see Auras.lua's StyleFields). Duration takes TWO points -- its
            -- own and the icon's -- which is what lets it sit outside the icon
            -- (pair TOP with the icon's BOTTOM) as well as on it. Stacks take
            -- one point, used for both sides, because that is all the engine's
            -- style honours for them.
            --
            -- CENTRED ON THE ICON as of 2026-09-11 (user request), which is
            -- where nearly every aura addon puts a countdown and what reads
            -- best at these sizes -- the old default hung it under the icon,
            -- outside the row's own footprint. An existing profile that never
            -- moved it is carried across by Core.lua's
            -- MigrateUnitFrameAuraDuration.
            durationPoint = "CENTER",
            durationRelPoint = "CENTER",
            durationX = 0,
            durationY = 0,
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
            -- Same vocabulary as the party/raid Debuffs indicator's Filter
            -- dropdown, so one word means one thing in both places. "all" = no
            -- narrowing; the others depend on Blizzard flagging the aura and
            -- can therefore show nothing at all. See Auras.lua's
            -- DEBUFF_FILTER_CANDIDATES.
            debuffFilter = "all",
            showDuration = true,
            showStack = true,
            showBorder = true,
            -- Text placement, passed straight through to the AuraEngine style
            -- (see Auras.lua's StyleFields). Duration takes TWO points -- its
            -- own and the icon's -- which is what lets it sit outside the icon
            -- (pair TOP with the icon's BOTTOM) as well as on it. Stacks take
            -- one point, used for both sides, because that is all the engine's
            -- style honours for them.
            --
            -- CENTRED ON THE ICON as of 2026-09-11 (user request), which is
            -- where nearly every aura addon puts a countdown and what reads
            -- best at these sizes -- the old default hung it under the icon,
            -- outside the row's own footprint. An existing profile that never
            -- moved it is carried across by Core.lua's
            -- MigrateUnitFrameAuraDuration.
            durationPoint = "CENTER",
            durationRelPoint = "CENTER",
            durationX = 0,
            durationY = 0,
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

            -- TEXT. Face, size and outline per readout, plus colour and
            -- offsets. Before this the two shared a single `fontSize` and
            -- borrowed the unit frame's font face, so a cast bar detached from
            -- its frame -- floating free, or riding a Cooldown Manager row --
            -- had no way to be styled to match where it actually sat.
            --
            -- `fontSize` below is KEPT and honoured as the size fallback, so a
            -- profile written before these existed renders identically until
            -- somebody touches the new controls. No migration needed.
            --
            -- font is {face, size, outline}. "NONE" is not a valid SetFont
            -- flag -- it has to become nil -- which is why nothing reads
            -- font[3] straight through. See CastBar.ApplyTextStyle.
            nameText = {
                font = {"Friz QT__", 11, "OUTLINE"},
                color = {1, 1, 1, 1},
                x = 0, y = 0,
            },
            timeText = {
                font = {"Friz QT__", 11, "OUTLINE"},
                color = {1, 1, 1, 1},
                x = 0, y = 0,
            },
            fontSize = 11,

            -- Class colour of the CASTING unit, falling back to `color` when
            -- the unit is an NPC or its class is secret.
            classColor = false,
            color = {0.9, 0.7, 0.1, 1},
            -- Drawn as a TINT OVER the bar, not as a replacement colour: the
            -- uninterruptible flag is secret on 12.1 and cannot be branched
            -- on, only fed to SetAlphaFromBoolean. See CastBar.lua's header.
            uninterruptibleColor = {0.6, 0.6, 0.6, 0.55},

            -- Outline around the bar (CastBar.ApplyBorder). padding pushes it
            -- outward; at 0 it sits on the bar's own edge.
            border = {
                enabled = false,
                thickness = 1,
                padding = 0,
                color = {0, 0, 0, 1},
            },
        },
    }
end

profile.unitFrames = {
    -- Master switch. Off by default -- this module hides Blizzard's own unit
    -- frames when it runs, which is far too invasive to inflict on an existing
    -- user who updates the addon and never asked for it.
    enabled = false,

    -- Migration marker, not a setting: the aura duration text's default moved
    -- onto the icon on 2026-09-11, and Core.lua's MigrateUnitFrameAuraDuration
    -- carries an existing profile across exactly once. See its comment for why
    -- this one needs a flag when the others get by on value detection.
    auraDurationCentred = true,

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

    -- THE RESOURCE BAR (ResourceBar.lua). A standalone movable bar for the
    -- player's own power plus their class's secondary resource -- Holy Power,
    -- Combo Points, Chi, Soul Shards, Arcane Charges, Essence, Runes.
    --
    -- Lives here beside `frames` rather than inside player's own table, and
    -- reads its `enabled` INDEPENDENTLY of unitFrames.enabled: wanting a Holy
    -- Power display is not the same as wanting a replacement player frame, and
    -- making one require the other would be a hidden dependency with no error
    -- message. See ResourceBar.lua's header.
    --
    -- Which secondary resource appears is worked out per class and spec, and
    -- then only drawn when the game currently reports one (a Feral druid's
    -- combo points come and go with cat form on their own). There is no manual
    -- override because there is nothing sensible to override it TO -- a
    -- Warrior has no secondary resource to pick.
    resourceBar = {
        enabled = false,

        -- POSITION. "free" is its own screen position, dragged in Edit Mode;
        -- "anchor" rides another frame and follows it around. attachTo is a
        -- global frame name from CastBar.MATCH_TARGETS (a curated list, not
        -- free text -- a typo would silently resolve to nothing on screen with
        -- no way to tell why), and attachSide is one of its ATTACH_SIDES.
        -- "points" (ride the detached point row) is only offered while
        -- detachPoints is on, and is treated as "free" otherwise.
        positionMode = "free",       -- "free" | "anchor" | "points"
        attachTo = "EssentialCooldownViewer",
        attachSide = "BOTTOM",
        offsetX = 0,
        offsetY = 0,

        -- Raw pixels from UIParent centre, divided by scale at apply time --
        -- the same convention as every other saved position in the addon.
        -- Still used as the fallback when an anchor target has not loaded yet,
        -- so the bar is somewhere findable rather than pinned to screen centre.
        anchorX = 0,
        anchorY = -260,

        -- WIDTH. "match" tracks another frame's width live, sharing the cast
        -- bar's implementation -- the Cooldown Manager rows are the point of
        -- it, and they resize themselves as your tracked cooldowns change.
        widthMode = "custom",        -- "custom" | "match"
        matchFrame = "EssentialCooldownViewer",
        width = 220,
        scale = 1,

        -- Primary power bar. showPower false, or powerHeight 0, drops it and
        -- leaves a bare point row -- which is a perfectly reasonable thing to
        -- want next to a class that already shows mana somewhere else.
        showPower = true,
        powerHeight = 16,
        powerColorMode = "auto",     -- "auto" (power type) | "class" | "custom"
        powerColor = {0.2, 0.4, 0.8, 1},

        -- Point row for the secondary resource.
        showPoints = true,
        pointHeight = 8,
        pointSpacing = 2,
        -- Which row owns the TOP edge. Points above reads more naturally for
        -- a builder/spender (they are what you are watching), so it is the
        -- default.
        pointsAbove = true,
        pointColorMode = "auto",     -- "auto" (per resource) | "class" | "custom" | "rainbow" | "rainbowAnimated"
        pointColor = {1, 0.85, 0.3, 1},
        -- Deliberately lighter than the backdrop below, and fully opaque. The
        -- point row has to read as THREE distinct tones to be countable at a
        -- glance: the resource colour for a filled point, this grey for an
        -- empty one, and the near-black backdrop showing through the gaps
        -- between them. At the old 0.15/0.8 an empty point and a gap were
        -- nearly the same shade.
        pointEmptyColor = {0.22, 0.22, 0.22, 1},

        -- How each point is drawn (see ResourceBar.lua's "POINT STYLES"):
        -- "bars" is the plain look, "shape" cuts each point to pointShape,
        -- "blizzard" uses the game's own art for this resource. Shapes and
        -- art keep their proportions and spread evenly across the row's
        -- width, unless pointsLayout.widthMode is "points" (Fit to Points).
        pointStyle = "bars",           -- "bars" | "shape" | "blizzard"
        pointShape = "round",          -- a value from ResourceBar.SHAPES
        -- "auto" fills bars left to right and shapes/art bottom to top.
        pointFill = "auto",            -- "auto" | "horizontal" | "vertical"
        -- Colour cycles per second, for pointColorMode "rainbowAnimated".
        rainbowSpeed = 0.25,
        -- An outline on each point, just inside its edge: pixel edges on
        -- bars, a ring following the shape on shapes. Blizzard art has its
        -- own edges and never gets one. thickness is 1-4 -- pixels on bars,
        -- which ring image on shapes (see ResourceBar.lua's StylePipBorder).
        pointBorder = {
            enabled = false,
            thickness = 2,
            color = {0, 0, 0, 1},
        },

        -- Gap between the two rows, when both are shown.
        gap = 2,

        -- The point row as its own movable frame. Off, the two rows are one
        -- bar with one position (how every profile started). On, the points
        -- are placed by pointsLayout: free, anchored to a frame, or attached
        -- to the power bar ("power"). ResourceBar.SeedDetach rewrites this
        -- table as detach is switched on, so the row starts where it already
        -- is; these values only matter to a profile that has never detached.
        detachPoints = false,
        pointsLayout = {
            positionMode = "power",      -- "free" | "anchor" | "power"
            attachTo = "EssentialCooldownViewer",
            attachSide = "TOP",
            offsetX = 0,
            offsetY = 2,
            anchorX = 0,
            anchorY = -236,
            -- "points" packs shapes/art side by side (attached: centred in
            -- the bar; detached: the row is as wide as its points). Bars
            -- treat it as "power". Attached, only "power"/"points" apply.
            widthMode = "power",         -- "power" | "custom" | "match" | "points"
            matchFrame = "EssentialCooldownViewer",
            width = 220,
        },

        -- Solid fill behind the whole bar. ON by default, because the point
        -- row is not reliably countable without it -- the gaps between points
        -- are transparent, so the charges get read against whatever the game
        -- world is showing through them (user report + screenshot, 2026-09-06).
        -- padding extends it past the bar's edge.
        background = {
            enabled = true,
            color = {0, 0, 0, 0.8},
            padding = 0,
        },

        -- Border around the WHOLE bar (both rows plus the gap between them),
        -- built on BuiltIn_Update.lua's shared CreateBorderIndicator.
        -- padding pushes it outward from the bar's edge; at 0 it sits on the
        -- edge itself, over the outermost pixel of the bars, matching how the
        -- party frame border behaves.
        -- Detached, enabled is the power bar's border and the points have
        -- their own switch, pointsEnabled -- deliberately NOT defaulted here,
        -- so that unset it follows enabled (see ResourceBar.PointsBorderOn).
        border = {
            enabled = false,
            thickness = 1,
            padding = 0,
            color = {0, 0, 0, 1},
        },

        -- Power text. textFormat is a UnitFrames text token, rendered through
        -- that module's own FormatToken so the secret-value handling lives in
        -- one place -- "power", "powerPercent".
        showPowerText = true,
        textFormat = "power",
        textAnchor = "CENTER",
        textX = 0,
        textY = 0,
        textColor = {1, 1, 1, 1},
        font = {"Friz QT__", 12, "OUTLINE", true},
        fontSize = 12,
    },

    frames = {
        -- useNicknames is set HERE and nowhere else -- see DefaultFrame.
        player       = DefaultFrame{anchorX = -260, anchorY = -180, castBar = true,
                                    healthFormat = "healthBoth",
                                    useNicknames = true},
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
