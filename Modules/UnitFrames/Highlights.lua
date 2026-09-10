--[[ SquizzFrames UnitFrames Highlights

    Hover highlight, target highlight and aggro warning on the standalone unit
    frames -- the "universal" indicators, the ones that describe a frame's
    STATE rather than a unit's auras.

    DELIBERATELY ISOLATED FROM THE PARTY/RAID INDICATOR SYSTEM. These carry
    their own PER-FRAME settings on the Unit Frames page rather than reading
    profile.layout.indicators. Two reasons:

      * It is how every other unit-frame setting already works, and the useful
        configurations genuinely differ -- a thick gold target highlight on
        boss frames without touching your raid frames is the point.
      * The alternative considered was a third tab on the Indicators page
        sharing that system. It was rejected because the runtime carries "is
        this the raid list" as a BOOLEAN through ~50 call sites, so a third
        context means a tri-state refactor of all of them. Isolated settings
        cost nothing by comparison.

    REUSES THE INDICATOR SYSTEM'S MECHANICS, just not its settings.
    BuiltIn_Update.lua exports the border factory and the Check functions for
    exactly this, and PetButton.lua already borrows them the same way. They
    need very little from a button:

      * button.unit
      * button.indicators[name] with Show/Hide (or SetGlow)
      * indicator._sfTable = { enabled = <bool> }
      * button._sfHovered, for the hover-beats-target priority

    Unit frames already have `unit` and `_sfHovered` (UnitFrames.lua's OnLoad),
    so this file only builds the frames and keeps _sfTable in step.

    WHAT IS USEFUL WHERE, since the options page cannot know:
      * Hover highlight -- useful on every frame.
      * Target highlight -- useful on boss, focus and target-of-target, where
        it shows WHICH one you are on. On the target frame itself it is always
        lit, which is part of why everything here defaults off.
      * Aggro -- really a player-frame and boss-frame reading.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local Highlights = {}
SquizzFrames.UnitFrameHighlights = Highlights

-- [settings key] = { indicator key, frame-name suffix, default colour }
Highlights.KINDS = {
    {key = "hover",  ind = "hoverHighlight",  suffix = "HoverHighlight",
     label = "Hover Highlight",  default = {1, 1, 1, 1}},
    {key = "target", ind = "targetHighlight", suffix = "TargetHighlight",
     label = "Target Highlight", default = {1, 0.82, 0, 1}},
    {key = "aggro",  ind = "aggroBorder",     suffix = "AggroBorder",
     label = "Aggro Warning",    default = {0.9, 0.1, 0.1, 1}},
}

local function BU()
    return SquizzFrames.modules and SquizzFrames.modules["BuiltIn_Update"]
end

-- Resolve one kind's settings, falling back to the shipped defaults so a
-- profile that predates these renders identically (i.e. off).
function Highlights.Get(t, key)
    local h = t and t.highlights
    return h and h[key]
end

-- Build the border frames on any frame -- real or preview mock.
--
-- Lazy, and called from ApplyLayout rather than the frame factory, because
-- BuiltIn_Update.lua loads AFTER this module. Same reason the frame border and
-- the resource bar's border are built there.
--
-- `levelOffset` exists because the preview mock's layer stack is its own; the
-- real frame wants +6 (above portrait 4 and border 5, below the text host 7).
function Highlights.Ensure(frame, levelOffset)
    local bu = BU()
    if not (bu and bu.CreateBorderIndicator) then return false end
    frame.indicators = frame.indicators or {}

    for _, def in ipairs(Highlights.KINDS) do
        if not frame.indicators[def.ind] then
            local ind = bu.CreateBorderIndicator(frame, def.suffix)
            ind:SetFrameLevel((frame:GetFrameLevel() or 1) + (levelOffset or 6))
            frame.indicators[def.ind] = ind
        end
    end

    -- The aggro border's pulse. Opt-in, matching the party frames where the
    -- border's pulse defaults off.
    local aggro = frame.indicators.aggroBorder
    if aggro and not aggro._sfBlinkWired and bu.AttachBlinkBehaviour then
        bu.AttachBlinkBehaviour(aggro, false)
        aggro._sfBlinkWired = true
    end
    return true
end

-- Colour/thickness/enabled onto the frames. Shared by the real frames and the
-- preview so the two cannot render differently.
function Highlights.Style(frame, t)
    for _, def in ipairs(Highlights.KINDS) do
        local ind = frame.indicators and frame.indicators[def.ind]
        local c = Highlights.Get(t, def.key)
        if ind then
            local col = (c and c.color) or def.default
            ind:SetColor(col[1] or 1, col[2] or 1, col[3] or 1, col[4] or 1)
            if ind.SetThickness then ind:SetThickness((c and c.thickness) or 2) end
            -- Everything defaults OFF. Unlike the party frames, where hover
            -- and target highlight are long-standing defaults, these are new
            -- to the unit frames -- nobody's layout should change under them
            -- on update.
            ind._sfTable = {enabled = (c ~= nil) and (c.enabled == true)}
        end
    end

    local aggro = frame.indicators and frame.indicators.aggroBorder
    if aggro and aggro.SetBlinkOptions then
        local c = Highlights.Get(t, "aggro")
        aggro:SetBlinkOptions(c and c.blinkOptions)
    end
end

function Highlights.ApplySettings(frame, t)
    if not frame then return end
    if not Highlights.Ensure(frame, 6) then return end
    Highlights.Style(frame, t)
    Highlights.Update(frame)
end

-- Live state, via the indicator system's own Check functions.
function Highlights.Update(frame)
    local bu = BU()
    if not (bu and frame and frame.indicators and frame.unit) then return end
    -- Both must run in the same pass: CheckTargetHighlight hides itself while
    -- _sfHovered is set, so evaluating one without the other leaves a stale
    -- border on screen.
    if bu.CheckHoverHighlight then bu.CheckHoverHighlight(frame) end
    if bu.CheckTargetHighlight then bu.CheckTargetHighlight(frame) end
    if bu.CheckAggroBorder then bu.CheckAggroBorder(frame) end
end

-- PREVIEW. Everything enabled is drawn at full strength, regardless of whether
-- you are actually hovering, actually targeting that unit, or actually holding
-- aggro -- exactly as the preview already treats the combat and leader icons.
-- The point of the preview is to judge the colour and thickness; one that only
-- appears mid-pull cannot be judged at all.
--
-- Note this bypasses the Check functions entirely rather than faking their
-- inputs (_sfFakeTarget/_sfFakeThreat, which the party Designer uses): the
-- three would then hide each other by priority, and the preview's job here is
-- to show all three at once.
function Highlights.Preview(frame, t)
    if not frame then return end
    if not Highlights.Ensure(frame, 6) then return end
    Highlights.Style(frame, t)
    for _, def in ipairs(Highlights.KINDS) do
        local ind = frame.indicators and frame.indicators[def.ind]
        local c = Highlights.Get(t, def.key)
        if ind then
            local on = (c ~= nil) and (c.enabled == true)
            if def.key == "aggro" and ind.SetGlow then
                ind:SetGlow(on)
            elseif on then
                ind:Show()
            else
                ind:Hide()
            end
        end
    end
end
