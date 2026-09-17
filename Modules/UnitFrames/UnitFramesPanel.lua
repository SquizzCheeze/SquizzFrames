--[[ SquizzFrames Unit Frames options page

    A pure shell over profile.unitFrames -- every control reads and writes that
    tree and then fires "UnitFramesChanged", which UnitFrames.lua turns into an
    ApplyLayout. Nothing here touches frames directly, the same discipline
    NicknamesPanel.lua follows over the Nicknames module.

    Structured like the Pet Frames page: a row of unit toggle buttons at the
    top swaps which sub-table every accessor below reads, so one builder serves
    all five frames instead of five near-identical builders that drift.

    Sections (unit tabs across the top, section tabs down the left) so one
    long scrolling list does not hide every setting. Aura controls are
    deliberately absent rather than present-and-inert -- see
    UnitFrames_Defaults.lua.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local L = SquizzFrames.L
local F = SquizzFrames.F
local W = SquizzFrames.Widgets

local Panel = {}
SquizzFrames.UnitFramesPanel = Panel

-- Which unit's settings the page is currently editing, and which section of
-- them. Both persist across page switches within a session, which is what you
-- want when tweaking one frame's cast bar across several reopens.
local activeUnit = "player"
local activeSection = "general"
local rebuildFields

-- The page is framed by two PINNED strips that never scroll:
--   * a top header carrying the unit tabs (Player/Target/.../Boss)
--   * a left sidebar carrying the section tabs for whichever unit is selected
-- BuildFields insets the scrolling content by exactly these, so the content
-- and the furniture cannot drift apart.
local HEADER_HEIGHT = 34
local SIDEBAR_WIDTH = 96
-- ...and a third on the right holding a 1:1 preview of the frame being
-- edited. Wide enough for a default 180px frame plus a portrait hanging off
-- its side, with room to breathe.
local PREVIEW_WIDTH = 250

-- "boss" is a pseudo-unit here: it edits profile.unitFrames.boss, the ONE
-- table shared by every boss frame, so the same field builder serves it.
local UNIT_TABS = {
    {key = "player",       label = L["Player"] or "Player"},
    {key = "target",       label = L["Target"] or "Target"},
    {key = "targettarget", label = L["ToT"] or "ToT"},
    {key = "focus",        label = L["Focus"] or "Focus"},
    {key = "focustarget",  label = L["Focus Tgt"] or "Focus Tgt"},
    {key = "boss",         label = L["Boss"] or "Boss"},
}

-- The four text readouts, and the label each gets as a section heading.
local TEXT_ELEMENT_LABELS = {
    name   = L["Name"] or "Name",
    health = L["Health"] or "Health",
    power  = L["Power"] or "Power",
    level  = L["Level"] or "Level",
}

-- Format labels. Built against the module's own per-element format lists so a
-- dropdown can never offer something FormatToken doesn't render, nor a health
-- format on the level element -- see UnitFrames_Defaults.lua for why "health
-- deficit" isn't here at all.
local TEXT_LABELS = {
    name          = L["Name"] or "Name",
    health        = L["Health"] or "Health",
    healthPercent = L["Health %"] or "Health %",
    healthBoth    = L["Health + %"] or "Health + %",
    healthMax     = L["Health / Max"] or "Health / Max",
    power         = L["Power"] or "Power",
    powerPercent  = L["Power %"] or "Power %",
    level         = L["Level"] or "Level",
    levelClass    = L["Level + Class"] or "Level + Class",
}

local function FormatItems(element)
    local items = {}
    local formats = SquizzFrames.UNITFRAME_TEXT_FORMATS
        and SquizzFrames.UNITFRAME_TEXT_FORMATS[element]
    for _, token in ipairs(formats or {}) do
        if TEXT_LABELS[token] then
            items[#items + 1] = {value = token, text = TEXT_LABELS[token]}
        end
    end
    return items
end

local ANCHOR_LABELS = {
    TOPLEFT     = L["Top Left"] or "Top Left",
    TOP         = L["Top"] or "Top",
    TOPRIGHT    = L["Top Right"] or "Top Right",
    LEFT        = L["Left"] or "Left",
    CENTER      = L["Center"] or "Center",
    RIGHT       = L["Right"] or "Right",
    BOTTOMLEFT  = L["Bottom Left"] or "Bottom Left",
    BOTTOM      = L["Bottom"] or "Bottom",
    BOTTOMRIGHT = L["Bottom Right"] or "Bottom Right",
}

local function AnchorItems()
    local items = {}
    for _, point in ipairs(SquizzFrames.UNITFRAME_TEXT_ANCHORS or {}) do
        items[#items + 1] = {value = point, text = ANCHOR_LABELS[point] or point}
    end
    return items
end

-----------------------------------------------------------------------
-- Accessors
-----------------------------------------------------------------------

local function GetConfig()
    local prof = SquizzFrames.db and SquizzFrames.db.profile
    return prof and prof.unitFrames
end

local function GetUnitConfig()
    local cfg = GetConfig()
    if not cfg then return nil end
    -- Boss lives beside `frames`, not inside it -- one shared table for the
    -- whole stack. See UnitFrames_Defaults.lua.
    if activeUnit == "boss" then return cfg.boss end
    return cfg.frames and cfg.frames[activeUnit]
end

-- The live preview mock, set once by Panel.Build. Held file-local so Changed()
-- can reach it without every caller having to thread the page frame down.
local previewMock

-- The shared ScrollFrame this page lives in, resolved in Panel.Build.
local scrollHost

-- Scroll to the top. Called ONLY when the unit or section tab changes -- never
-- on a plain rebuild. Several setters rebuild the page (a text-content
-- dropdown, an enable checkbox), and resetting there would yank you back to
-- the top mid-edit every time you touched one of them.
-- Goes through OptionsFrame's helper rather than calling SetVerticalScroll on
-- the frame directly. The wheel handler derives its next position from the
-- SCROLLBAR's value, so moving only the frame leaves the bar holding the old
-- offset and the first wheel tick after a section switch snaps back to where
-- you were. ShowPage has always set both; this was the one place that didn't.
local function ScrollToTop()
    if SquizzFrames.OptionsScrollToTop then
        SquizzFrames.OptionsScrollToTop()
    elseif scrollHost and scrollHost.SetVerticalScroll then
        scrollHost:SetVerticalScroll(0)
    end
end

-- Re-dress the preview for whatever is selected now.
--
-- Called from Changed(), NOT from BuildFields, because BuildFields only runs
-- when the page is rebuilt -- which a handful of setters trigger but a plain
-- slider or colour picker does not. Hanging the refresh off the rebuild meant
-- width, offsets and colours moved the real frames instantly and left the
-- preview showing the old values, which is worse than having no preview.
local function RefreshPreview()
    local P = SquizzFrames.UnitFramePreview
    if not (P and previewMock) then return end
    local cfg = GetConfig()
    local t = GetUnitConfig()
    if t and cfg and cfg.enabled then
        P.Refresh(previewMock, t)
        previewMock:Show()
    else
        previewMock:Hide()
    end
end

local function Changed()
    -- HideBlizzard.lua listens for this and re-evaluates every Blizzard frame
    -- itself -- which it has to, since the single master switch means our
    -- per-frame enables are what decide whether Blizzard's counterpart shows.
    -- This used to call HideBlizzardUnitFrames/HideBlizzardCastBar by hand and
    -- would now need a third call for the pet frame; the message keeps the
    -- decision in one file instead.
    SquizzFrames:Fire("UnitFramesChanged")
    RefreshPreview()
end

local function Set(apply)
    local t = GetUnitConfig()
    if not t then return end
    apply(t)
    Changed()
end

-- Text-element accessors are generated rather than written out four times: the
-- element key is the only thing that differs, and two dozen hand-written
-- getter/setter pairs is exactly how a page drifts out of sync with its data.
--
-- Every setter goes through Elem(), which materialises t.texts[element] on
-- demand -- a profile can reach here with the table missing (a frame added
-- after the profile was created, or a migration that found nothing to carry
-- over), and a setter that silently no-ops on nil is a control that does
-- nothing with no way to tell.
local function ElemGetters(element)
    local function Elem(t)
        t.texts = t.texts or {}
        t.texts[element] = t.texts[element] or {}
        return t.texts[element]
    end
    local function Read(field, fallback)
        local t = GetUnitConfig()
        local e = t and t.texts and t.texts[element]
        local v = e and e[field]
        if v == nil then return fallback end
        return v
    end
    local defFormat = (SquizzFrames.UNITFRAME_TEXT_FORMATS
        and SquizzFrames.UNITFRAME_TEXT_FORMATS[element]
        and SquizzFrames.UNITFRAME_TEXT_FORMATS[element][1]) or "name"

    return {
        enabled = function() return Read("enabled", false) == true end,
        setEnabled = function(v)
            Set(function(t) Elem(t).enabled = v end)
            -- Everything below the checkbox is hidden while off, so the page
            -- has to rebuild to show or hide it.
            if rebuildFields then rebuildFields() end
        end,
        format = function() return Read("format", defFormat) end,
        setFormat = function(v) Set(function(t) Elem(t).format = v end) end,
        anchor = function() return Read("anchor", "CENTER") end,
        setAnchor = function(v) Set(function(t) Elem(t).anchor = v end) end,
        size = function() return Read("size", 12) end,
        setSize = function(v) Set(function(t) Elem(t).size = v end) end,
        x = function() return Read("x", 0) end,
        setX = function(v) Set(function(t) Elem(t).x = v end) end,
        y = function() return Read("y", 0) end,
        setY = function(v) Set(function(t) Elem(t).y = v end) end,
        classColor = function() return Read("classColor", false) == true end,
        setClassColor = function(v)
            Set(function(t) Elem(t).classColor = v end)
            -- The custom colour picker is hidden while class colour is on --
            -- a live control that provably does nothing is the failure this
            -- page keeps trying to avoid.
            if rebuildFields then rebuildFields() end
        end,
        color = function()
            local c = Read("color", nil)
            if type(c) ~= "table" then return 1, 1, 1, 1 end
            return c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1
        end,
        setColor = function(r, g, b, a)
            Set(function(t) Elem(t).color = {r, g, b, a} end)
        end,
    }
end

-----------------------------------------------------------------------
-- Field builder
-----------------------------------------------------------------------

-- Each section renders on its own, starting from the same y. They are only
-- ever called one at a time (the section tabs pick one), so none of them has
-- to know or care what any other one did.
local function SecGeneral(host, y, cfg, t)
    W.CreateTitledPane(host, L["Unit Frames"] or "Unit Frames", y)
    y = y - 35

    local cbModule = W.CreateStyledCheckbox(host,
        L["Enable Unit Frames"] or "Enable Unit Frames",
        function() return cfg.enabled == true end,
        function(v)
            cfg.enabled = v
            Changed()
            if rebuildFields then rebuildFields() end
        end)
    cbModule:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    -- "Hide Blizzard Unit Frames" and "Hide Blizzard Cast Bar" used to sit
    -- here. Both are now folded into the single Hide Blizzard Frames switch on
    -- the General page, which covers party, raid and pet frames as well -- and
    -- which only ever hides a frame we are actually drawing a replacement for,
    -- so turning any of ours off below gives Blizzard's back on its own. See
    -- HideBlizzard.lua's ShouldHideBlizzard.
    local hideNote = host:CreateFontString(nil, "OVERLAY")
    hideNote:SetFontObject("GameFontDisableSmall")
    hideNote:SetPoint("TOPLEFT", 32, y)
    hideNote:SetPoint("RIGHT", host, "RIGHT", -20, 0)
    hideNote:SetJustifyH("LEFT")
    hideNote:SetText(L["UnitFramesHideNote"]
        or "Blizzard's matching frames are hidden by Hide Blizzard Frames on the General page. Frames you leave switched off below keep Blizzard's.")
    y = y - 38

    -- Module-wide, not per-frame: it describes a relationship BETWEEN two
    -- frames, so putting it on the Player tab (or the Target tab) would make
    -- it look like a property of whichever one you happened to be editing.
    local cbMirror = W.CreateStyledCheckbox(host,
        L["Mirror Player and Target"] or "Mirror Player and Target",
        function() return cfg.mirrorPlayerTarget == true end,
        function(v) cfg.mirrorPlayerTarget = v; Changed() end)
    cbMirror:SetPoint("TOPLEFT", 15, y)
    y = y - 28

    local mirrorNote = host:CreateFontString(nil, "OVERLAY")
    mirrorNote:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    mirrorNote:SetPoint("TOPLEFT", 15, y)
    mirrorNote:SetWidth(340)
    mirrorNote:SetJustifyH("LEFT")
    mirrorNote:SetTextColor(0.7, 0.7, 0.7, 1)
    mirrorNote:SetText(L["Drag either the player or target frame in Edit Mode and the other follows to the opposite side of the screen."]
        or "Drag either the player or target frame in Edit Mode and the other follows to the opposite side of the screen.")
    y = y - 40

    if not cfg.enabled then
        local note = host:CreateFontString(nil, "OVERLAY")
        note:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        note:SetPoint("TOPLEFT", 15, y)
        note:SetWidth(340)
        note:SetJustifyH("LEFT")
        note:SetTextColor(0.7, 0.7, 0.7, 1)
        note:SetText(L["Turn Unit Frames on to configure the individual frames."]
            or "Turn Unit Frames on to configure the individual frames.")
    end
end

local function SecFrame(host, y, cfg, t)
    W.CreateTitledPane(host, L["This Frame"] or "This Frame", y)
    y = y - 35

    local cbEnable = W.CreateStyledCheckbox(host, L["Enabled"] or "Enabled",
        function() return t.enabled ~= false end,
        function(v) Set(function(c) c.enabled = v end) end)
    cbEnable:SetPoint("TOPLEFT", 15, y)
    y = y - 28

    -- Player frame only, and the SCOPE IS NOW REAL, not just a hidden
    -- control. A nickname is something you set for yourself or for people in
    -- your group, and the group case is already served by the party frames.
    --
    -- It used to be that only this checkbox was scoped while the setting sat
    -- on every frame's table defaulting to on, and FormatToken honoured it
    -- everywhere -- so target/focus/boss silently resolved nicknames with no
    -- way to say otherwise. FormatToken now refuses outside "player", the
    -- default is set on this frame alone, and Core.lua purges the leftovers.
    if activeUnit == "player" then
        local cbNick = W.CreateStyledCheckbox(host, L["Use Nicknames"] or "Use Nicknames",
            function() return t.useNicknames ~= false end,
            function(v) Set(function(c) c.useNicknames = v end) end)
        cbNick:SetPoint("TOPLEFT", 15, y)
        y = y - 35
    end

    -- Boss frames are a stack sharing one settings table, so the two controls
    -- that describe the STACK rather than a single frame only appear here.
    if activeUnit == "boss" then
        W.CreateTitledPane(host, L["Boss Stack"] or "Boss Stack", y)
        y = y - 35

        local ddGrow = W.CreateStyledDropdown(host, 200, 40,
            L["Growth Direction"] or "Growth Direction", {
            {value = "DOWN",  text = L["Down"] or "Down"},
            {value = "UP",    text = L["Up"] or "Up"},
            {value = "RIGHT", text = L["Right"] or "Right"},
            {value = "LEFT",  text = L["Left"] or "Left"},
        }, function() return t.growthDirection or "DOWN" end,
           function(v) Set(function(c) c.growthDirection = v end) end)
        ddGrow:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        local sSpace = W.CreateStyledSlider(host, 200, 0, 120, 1,
            L["Spacing"] or "Spacing",
            function() return t.spacing or 26 end,
            function(v) Set(function(c) c.spacing = v end) end)
        sSpace:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local bHint = host:CreateFontString(nil, "OVERLAY")
        bHint:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        bHint:SetPoint("TOPLEFT", 15, y)
        bHint:SetWidth(340)
        bHint:SetJustifyH("LEFT")
        bHint:SetTextColor(0.7, 0.7, 0.7, 1)
        bHint:SetText(L["All boss frames share these settings. Drag the FIRST one in Edit Mode to move the whole stack - the others show where they will land."]
            or "All boss frames share these settings. Drag the FIRST one in Edit Mode to move the whole stack - the others show where they will land.")
        y = y - 45
    end

    -- Border. Nested table, so its accessors read t.border rather than t.
    W.CreateTitledPane(host, L["Border"] or "Border", y)
    y = y - 35

    local function BorderRead(field, fb)
        local b = t.border
        local v = b and b[field]
        if v == nil then return fb end
        return v
    end
    -- Materialises t.border on WRITE only. Reading must not, or merely opening
    -- the page would write to the profile.
    local function BorderWrite(field, v)
        Set(function(c)
            c.border = c.border or {}
            c.border[field] = v
        end)
    end

    local cbBorder = W.CreateStyledCheckbox(host, L["Show"] or "Show",
        function() return BorderRead("enabled", false) == true end,
        function(v)
            BorderWrite("enabled", v)
            if rebuildFields then rebuildFields() end
        end)
    cbBorder:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    if BorderRead("enabled", false) then
        local sThick = W.CreateStyledSlider(host, 200, 1, 8, 1,
            L["Thickness"] or "Thickness",
            function() return BorderRead("thickness", 1) end,
            function(v) BorderWrite("thickness", v) end)
        sThick:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local sPad = W.CreateStyledSlider(host, 200, 0, 20, 1,
            L["Padding"] or "Padding",
            function() return BorderRead("padding", 0) end,
            function(v) BorderWrite("padding", v) end)
        sPad:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local cpBorder = W.CreateColorPicker(host, L["Color"] or "Color",
            function()
                local c = BorderRead("color", nil)
                if type(c) ~= "table" then return 0, 0, 0, 1 end
                return c[1] or 0, c[2] or 0, c[3] or 0, c[4] or 1
            end,
            function(r, g, b, a) BorderWrite("color", {r, g, b, a}) end)
        cpBorder:SetPoint("TOPLEFT", 15, y - 6)
        y = y - 42
    end
end

local function SecSizing(host, y, cfg, t)
    W.CreateTitledPane(host, L["Sizing"] or "Sizing", y)
    y = y - 35

    local sliderW = W.CreateStyledSlider(host, 200, 40, 400, 1, L["Width"] or "Width",
        function() return t.width or 180 end,
        function(v) Set(function(c) c.width = v end) end)
    sliderW:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    local sliderH = W.CreateStyledSlider(host, 200, 12, 120, 1, L["Height"] or "Height",
        function() return t.height or 46 end,
        function(v) Set(function(c) c.height = v end) end)
    sliderH:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    -- 0 hides the power bar. One control instead of a checkbox plus a slider
    -- that would then have to disable itself.
    local sliderP = W.CreateStyledSlider(host, 200, 0, 30, 1,
        L["Power Bar Height (0 = off)"] or "Power Bar Height (0 = off)",
        function() return t.powerHeight or 0 end,
        function(v) Set(function(c) c.powerHeight = v end) end)
    sliderP:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

end

local function SecColors(host, y, cfg, t)
    -- HEALTH GRADIENT, above the flat-colour controls because it OVERRIDES
    -- them when on. Putting it below would leave three live-looking colour
    -- controls that the bar is ignoring.
    W.CreateTitledPane(host, L["Health Gradient"] or "Health Gradient", y)
    y = y - 35

    local function GradRead(field, fb)
        local g = t.healthGradient
        local v = g and g[field]
        if v == nil then return fb end
        return v
    end
    local function GradWrite(field, v)
        Set(function(c)
            c.healthGradient = c.healthGradient or {}
            c.healthGradient[field] = v
        end)
    end

    local cbGrad = W.CreateStyledCheckbox(host,
        L["Color by Health"] or "Color by Health",
        function() return GradRead("enabled", false) == true end,
        function(v)
            GradWrite("enabled", v)
            if rebuildFields then rebuildFields() end
        end)
    cbGrad:SetPoint("TOPLEFT", 15, y)
    y = y - 26

    local gradNote = host:CreateFontString(nil, "OVERLAY")
    gradNote:SetFontObject("GameFontDisableSmall")
    gradNote:SetPoint("TOPLEFT", 32, y)
    gradNote:SetPoint("RIGHT", host, "RIGHT", -20, 0)
    gradNote:SetJustifyH("LEFT")
    gradNote:SetText(L["HealthGradientNote"]
        or "Colours the bar by how hurt the unit is instead of who they are. Overrides the class, reaction and custom colours below while it is on.")
    y = y - 40

    if GradRead("enabled", false) then
        local ddStyle = W.CreateStyledDropdown(host, 200, 40, L["Style"] or "Style", {
            {value = "smooth", text = L["Smooth blend"] or "Smooth blend"},
            {value = "bands",  text = L["Hard bands"] or "Hard bands"},
        }, function() return GradRead("style", "smooth") end,
           function(v) GradWrite("style", v) end)
        ddStyle:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        local function GradColor(field, dr, dg, db)
            return function()
                local c = GradRead(field, nil)
                if type(c) ~= "table" then return dr, dg, db, 1 end
                return c[1] or dr, c[2] or dg, c[3] or db, c[4] or 1
            end,
            function(r, g, b, a) GradWrite(field, {r, g, b, a or 1}) end
        end

        local hGet, hSet = GradColor("high", 0.10, 0.85, 0.10)
        local cpHigh = W.CreateColorPicker(host, L["Full Health"] or "Full Health", hGet, hSet)
        cpHigh:SetPoint("TOPLEFT", 15, y)
        y = y - 32

        local mGet, mSet = GradColor("mid", 0.95, 0.80, 0.15)
        local cpMid = W.CreateColorPicker(host, L["Midpoint"] or "Midpoint", mGet, mSet)
        cpMid:SetPoint("TOPLEFT", 15, y)
        y = y - 32

        local lGet, lSet = GradColor("low", 0.85, 0.15, 0.15)
        local cpLow = W.CreateColorPicker(host, L["Empty"] or "Empty", lGet, lSet)
        cpLow:SetPoint("TOPLEFT", 15, y)
        y = y - 36

        local sMid = W.CreateStyledSlider(host, 200, 0.05, 0.95, 0.05,
            L["Midpoint At"] or "Midpoint At",
            function() return GradRead("midpoint", 0.5) end,
            function(v) GradWrite("midpoint", v) end)
        sMid:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70
    end

    W.CreateTitledPane(host, L["Health Bar Color"] or "Health Bar Color", y)
    y = y - 35

    local cbClass = W.CreateStyledCheckbox(host,
        L["Class Color (players)"] or "Class Color (players)",
        function() return t.healthClassColor == true end,
        function(v) Set(function(c) c.healthClassColor = v end) end)
    cbClass:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    local cbReaction = W.CreateStyledCheckbox(host,
        L["Reaction Color (NPCs)"] or "Reaction Color (NPCs)",
        function() return t.healthReactionColor == true end,
        function(v) Set(function(c) c.healthReactionColor = v end) end)
    cbReaction:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    -- Shown even when both toggles above are on: it is the fallback whenever
    -- the unit is neither a player nor reaction-readable, which is a state the
    -- user will actually see (secret identity in combat).
    local picker = W.CreateColorPicker(host, L["Custom Color"] or "Custom Color",
        function()
            local c = t.healthCustomColor or {0.2, 0.6, 0.2, 1}
            return c[1], c[2], c[3], c[4] or 1
        end,
        function(r, g, b, a)
            Set(function(c) c.healthCustomColor = {r, g, b, a or 1} end)
        end)
    picker:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    -- Pointers rather than duplicate controls: bar TEXTURE and POWER BAR
    -- COLOUR are both shared Appearance settings already driving the party
    -- frames, and these frames read the very same values. A second copy here
    -- would either fight the original or need a whole per-frame tree.
    local sharedNote = host:CreateFontString(nil, "OVERLAY")
    sharedNote:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    sharedNote:SetPoint("TOPLEFT", 15, y)
    sharedNote:SetWidth(340)
    sharedNote:SetJustifyH("LEFT")
    sharedNote:SetTextColor(0.7, 0.7, 0.7, 1)
    sharedNote:SetText(L["Bar texture and power bar colour are shared with the party frames - set them under Layout > Appearance."]
        or "Bar texture and power bar colour are shared with the party frames - set them under Layout > Appearance.")
    y = y - 45

end

-- One group per READOUT (name / health / power / level), each with its own
-- enable, format, anchor, offsets, size and colour. This replaced three groups
-- named after anchors whose content was a dropdown -- see
-- UNITFRAME_TEXT_ELEMENTS in UnitFrames_Defaults.lua for why that was backwards.
local function SecText(host, y, cfg, t)
    -- FRAME-WIDE font, before the per-readout groups. The face and outline
    -- were already stored (t.font) and already read by ApplyFrameFont -- they
    -- simply had no control anywhere, so every unit frame was stuck on the
    -- shipped default (user request 2026-09-09). Size stays per readout, since
    -- wanting the name larger than the health text is the common case.
    W.CreateTitledPane(host, L["Font"] or "Font", y)
    y = y - 35

    local ddFace = W.CreateStyledDropdown(host, 200, 40, L["Font"] or "Font",
        (F.GetFontDropdownItems and F.GetFontDropdownItems()) or {},
        function() return (t.font and t.font[1]) or "Friz QT__" end,
        function(v)
            Set(function(c)
                c.font = c.font or {}
                c.font[1] = v
            end)
        end, "font")
    ddFace:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    -- "NONE" is stored but never reaches SetFont -- ApplyFrameFont converts it
    -- to nil, because it is not a valid flag string and passing it through
    -- yields an outline-less font with no error.
    local ddOutline = W.CreateStyledDropdown(host, 200, 40, L["Outline"] or "Outline", {
        {value = "NONE",         text = L["None"] or "None"},
        {value = "OUTLINE",      text = L["Outline"] or "Outline"},
        {value = "THICKOUTLINE", text = L["Thick Outline"] or "Thick Outline"},
    },
        function() return (t.font and t.font[3]) or "OUTLINE" end,
        function(v)
            Set(function(c)
                c.font = c.font or {}
                c.font[3] = v
            end)
        end)
    ddOutline:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    local fontNote = host:CreateFontString(nil, "OVERLAY")
    fontNote:SetFontObject("GameFontDisableSmall")
    fontNote:SetPoint("TOPLEFT", 32, y)
    fontNote:SetPoint("RIGHT", host, "RIGHT", -20, 0)
    fontNote:SetJustifyH("LEFT")
    fontNote:SetText(L["UnitFontNote"]
        or "Applies to all four readouts on this frame. Each one keeps its own size below. The cast bar has its own font settings on its own page.")
    y = y - 44

    for _, element in ipairs(SquizzFrames.UNITFRAME_TEXT_ELEMENTS or {}) do
        local acc = ElemGetters(element)

        W.CreateTitledPane(host, TEXT_ELEMENT_LABELS[element] or element, y)
        y = y - 35

        local cbOn = W.CreateStyledCheckbox(host, L["Show"] or "Show",
            acc.enabled, acc.setEnabled)
        cbOn:SetPoint("TOPLEFT", 15, y)
        y = y - 28

        -- Everything below is meaningless for a hidden readout, so it is
        -- hidden rather than shown-and-ignored.
        if acc.enabled() then
            -- Name has exactly one format, so a one-item dropdown would be a
            -- control that cannot be changed. Skip it rather than show it.
            local formats = FormatItems(element)
            if #formats > 1 then
                local dd = W.CreateStyledDropdown(host, 200, 40, L["Format"] or "Format",
                    formats, acc.format, acc.setFormat)
                dd:SetPoint("TOPLEFT", 15, y - 20)
                y = y - 70
            end

            local ddAnchor = W.CreateStyledDropdown(host, 200, 40, L["Anchor"] or "Anchor",
                AnchorItems(), acc.anchor, acc.setAnchor)
            ddAnchor:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 70

            local sX = W.CreateStyledSlider(host, 200, -100, 100, 1, L["Offset X"] or "Offset X",
                acc.x, acc.setX)
            sX:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65

            local sY = W.CreateStyledSlider(host, 200, -50, 50, 1, L["Offset Y"] or "Offset Y",
                acc.y, acc.setY)
            sY:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65

            local sSize = W.CreateStyledSlider(host, 200, 6, 24, 1, L["Size"] or "Size",
                acc.size, acc.setSize)
            sSize:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65

            local cbCC = W.CreateStyledCheckbox(host, L["Use Class Color"] or "Use Class Color",
                acc.classColor, acc.setClassColor)
            cbCC:SetPoint("TOPLEFT", 15, y)
            y = y - 28

            -- Class colour wins when it's on, so the swatch would be inert.
            if not acc.classColor() then
                local cp = W.CreateColorPicker(host, L["Text Color"] or "Text Color",
                    acc.color, acc.setColor)
                cp:SetPoint("TOPLEFT", 15, y - 6)
                y = y - 32
            end
            y = y - 10
        end
    end
end

local function SecPortrait(host, y, cfg, t)
    W.CreateTitledPane(host, L["Portrait"] or "Portrait", y)
    y = y - 35

    local function PortCfg()
        local c = GetUnitConfig()
        if not c then return nil end
        if not c.portrait then c.portrait = {enabled = false} end
        return c.portrait
    end
    local function PortSet(apply)
        local c = PortCfg()
        if not c then return end
        apply(c)
        Changed()
    end

    local pt = PortCfg()
    local cbPort = W.CreateStyledCheckbox(host, L["Show Portrait"] or "Show Portrait",
        function() return pt and pt.enabled == true end,
        function(v)
            PortSet(function(c) c.enabled = v end)
            if rebuildFields then rebuildFields() end
        end)
    cbPort:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    if pt and pt.enabled then
        local ddStyle = W.CreateStyledDropdown(host, 200, 40, L["Style"] or "Style", {
            {value = "2d",    text = L["2D Portrait"] or "2D Portrait"},
            {value = "3d",    text = L["3D Model"] or "3D Model"},
            {value = "class", text = L["Class Icon"] or "Class Icon"},
        }, function() return pt.style or "2d" end,
           function(v)
               PortSet(function(c) c.style = v end)
               if rebuildFields then rebuildFields() end
           end)
        ddStyle:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        -- 3D models are geometry, not a texture, so neither the mask nor the
        -- square class atlas applies to them -- the control is hidden rather
        -- than shown doing nothing.
        local pstyle = pt.style or "2d"
        if pstyle ~= "3d" then
            local ddShape = W.CreateStyledDropdown(host, 200, 40, L["Shape"] or "Shape", {
                {value = "square", text = L["Square"] or "Square"},
                {value = "circle", text = L["Circle"] or "Circle"},
            }, function() return pt.shape or "square" end,
               function(v) PortSet(function(c) c.shape = v end) end)
            ddShape:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 70
        end

        local ddPSide = W.CreateStyledDropdown(host, 200, 40, L["Side"] or "Side", {
            {value = "LEFT",  text = L["Left"] or "Left"},
            {value = "RIGHT", text = L["Right"] or "Right"},
        }, function() return pt.side or "LEFT" end,
           function(v) PortSet(function(c) c.side = v end) end)
        ddPSide:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        local cbInside = W.CreateStyledCheckbox(host,
            L["Inside the Frame"] or "Inside the Frame",
            function() return pt.inside == true end,
            function(v) PortSet(function(c) c.inside = v end) end)
        cbInside:SetPoint("TOPLEFT", 15, y)
        y = y - 30

        local sPSize = W.CreateStyledSlider(host, 200, 0, 120, 1,
            L["Size (0 = match height)"] or "Size (0 = match height)",
            function() return pt.size or 0 end,
            function(v) PortSet(function(c) c.size = v end) end)
        sPSize:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local sPX = W.CreateStyledSlider(host, 200, -100, 100, 1, L["Offset X"] or "Offset X",
            function() return pt.offsetX or 0 end,
            function(v) PortSet(function(c) c.offsetX = v end) end)
        sPX:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local sPY = W.CreateStyledSlider(host, 200, -100, 100, 1, L["Offset Y"] or "Offset Y",
            function() return pt.offsetY or 0 end,
            function(v) PortSet(function(c) c.offsetY = v end) end)
        sPY:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        if pstyle == "3d" then
            local sZoom = W.CreateStyledSlider(host, 200, 0.5, 3, 0.05,
                L["Model Zoom"] or "Model Zoom",
                function() return pt.zoom or 1 end,
                function(v) PortSet(function(c) c.zoom = v end) end)
            sZoom:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65
        end
    end

end

local function SecCastBar(host, y, cfg, t)
    W.CreateTitledPane(host, L["Cast Bar"] or "Cast Bar", y)
    y = y - 35

    -- Lazily backfilled the same way the pet page's name-text sub-table is:
    -- a profile saved before cast bars existed has a real frame table that
    -- simply lacks this key, and every accessor below would otherwise write
    -- into nothing.
    local function CastCfg()
        local c = GetUnitConfig()
        if not c then return nil end
        if not c.castBar then c.castBar = {enabled = false} end
        return c.castBar
    end
    local function CastSet(apply)
        local c = CastCfg()
        if not c then return end
        apply(c)
        Changed()
    end

    local cb = CastCfg()
    local cbEnableCast = W.CreateStyledCheckbox(host, L["Enable Cast Bar"] or "Enable Cast Bar",
        function() return cb and cb.enabled == true end,
        function(v)
            CastSet(function(c) c.enabled = v end)
            if rebuildFields then rebuildFields() end
        end)
    cbEnableCast:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    if cb and cb.enabled then
        local CBmod = SquizzFrames.UnitFrameCastBar
        local mode = cb.positionMode or "frame"

        local ddMode = W.CreateStyledDropdown(host, 200, 40, L["Position"] or "Position", {
            {value = "frame",  text = L["On This Frame"] or "On This Frame"},
            {value = "anchor", text = L["Attached to Another Frame"] or "Attached to Another Frame"},
            {value = "free",   text = L["Free (drag in Edit Mode)"] or "Free (drag in Edit Mode)"},
        }, function() return mode end,
           function(v)
               CastSet(function(c) c.positionMode = v end)
               if rebuildFields then rebuildFields() end
           end)
        ddMode:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        if mode == "free" then
            local dHint = host:CreateFontString(nil, "OVERLAY")
            dHint:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
            dHint:SetPoint("TOPLEFT", 15, y)
            dHint:SetWidth(340)
            dHint:SetJustifyH("LEFT")
            dHint:SetTextColor(0.7, 0.7, 0.7, 1)
            dHint:SetText(L["Drag the orange cast bar handle in Edit Mode to position it."]
                or "Drag the orange cast bar handle in Edit Mode to position it.")
            y = y - 35
        else
            if mode == "anchor" then
                local ddTarget = W.CreateStyledDropdown(host, 200, 40,
                    L["Attach To"] or "Attach To",
                    (CBmod and CBmod.MATCH_TARGETS) or {},
                    function() return cb.attachTo or "EssentialCooldownViewer" end,
                    function(v) CastSet(function(c) c.attachTo = v end) end)
                ddTarget:SetPoint("TOPLEFT", 15, y - 20)
                y = y - 70

                local ddAttachSide = W.CreateStyledDropdown(host, 200, 40,
                    L["Side"] or "Side",
                    (CBmod and CBmod.ATTACH_SIDES) or {},
                    function() return cb.attachSide or "BOTTOM" end,
                    function(v) CastSet(function(c) c.attachSide = v end) end)
                ddAttachSide:SetPoint("TOPLEFT", 15, y - 20)
                y = y - 70

                local aHint = host:CreateFontString(nil, "OVERLAY")
                aHint:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
                aHint:SetPoint("TOPLEFT", 15, y)
                aHint:SetWidth(340)
                aHint:SetJustifyH("LEFT")
                aHint:SetTextColor(0.7, 0.7, 0.7, 1)
                aHint:SetText(L["The cast bar follows this frame wherever it moves."]
                    or "The cast bar follows this frame wherever it moves.")
                y = y - 32
            else
                local ddSide = W.CreateStyledDropdown(host, 200, 40, L["Side"] or "Side", {
                    {value = "BOTTOM", text = L["Below Frame"] or "Below Frame"},
                    {value = "TOP",    text = L["Above Frame"] or "Above Frame"},
                }, function() return cb.anchor or "BOTTOM" end,
                   function(v) CastSet(function(c) c.anchor = v end) end)
                ddSide:SetPoint("TOPLEFT", 15, y - 20)
                y = y - 70
            end

            -- Offsets apply to both anchored modes, so they live outside the
            -- branch above rather than being duplicated in each.
            local sOX = W.CreateStyledSlider(host, 200, -400, 400, 1, L["Offset X"] or "Offset X",
                function() return cb.offsetX or 0 end,
                function(v) CastSet(function(c) c.offsetX = v end) end)
            sOX:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65

            local sOY = W.CreateStyledSlider(host, 200, -400, 400, 1, L["Offset Y"] or "Offset Y",
                function() return cb.offsetY or 0 end,
                function(v) CastSet(function(c) c.offsetY = v end) end)
            sOY:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65
        end

        -- Width mode. "Match Another Frame" is the reason this is a dropdown
        -- rather than a plain slider: lining the bar up with the Cooldown
        -- Manager's Essential row is the layout this exists to support, and it
        -- has to track that frame's width live as its contents change.
        local ddWidth = W.CreateStyledDropdown(host, 200, 40, L["Width"] or "Width", {
            {value = "frame",  text = L["Match This Frame"] or "Match This Frame"},
            {value = "custom", text = L["Custom"] or "Custom"},
            {value = "match",  text = L["Match Another Frame"] or "Match Another Frame"},
        }, function() return cb.widthMode or "frame" end,
           function(v)
               CastSet(function(c) c.widthMode = v end)
               if rebuildFields then rebuildFields() end
           end)
        ddWidth:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        if (cb.widthMode or "frame") == "custom" then
            local sW = W.CreateStyledSlider(host, 200, 40, 600, 1, L["Bar Width"] or "Bar Width",
                function() return cb.width or 180 end,
                function(v) CastSet(function(c) c.width = v end) end)
            sW:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65
        elseif cb.widthMode == "match" then
            local CB = SquizzFrames.UnitFrameCastBar
            local items = (CB and CB.MATCH_TARGETS) or {}
            local ddMatch = W.CreateStyledDropdown(host, 200, 40, L["Match"] or "Match",
                items,
                function() return cb.matchFrame or "EssentialCooldownViewer" end,
                function(v) CastSet(function(c) c.matchFrame = v end) end)
            ddMatch:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 70
        end

        local sH = W.CreateStyledSlider(host, 200, 6, 60, 1, L["Bar Height"] or "Bar Height",
            function() return cb.height or 16 end,
            function(v) CastSet(function(c) c.height = v end) end)
        sH:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local cbIcon = W.CreateStyledCheckbox(host, L["Show Icon"] or "Show Icon",
            function() return cb.showIcon ~= false end,
            function(v) CastSet(function(c) c.showIcon = v end) end)
        cbIcon:SetPoint("TOPLEFT", 15, y)
        y = y - 28

        local cbName2 = W.CreateStyledCheckbox(host, L["Show Spell Name"] or "Show Spell Name",
            function() return cb.showName ~= false end,
            function(v) CastSet(function(c) c.showName = v end)
                -- Rebuild: the styling group below appears and disappears
                -- with this.
                if rebuildFields then rebuildFields() end
            end)
        cbName2:SetPoint("TOPLEFT", 15, y)
        y = y - 28

        local cbTime = W.CreateStyledCheckbox(host, L["Show Cast Time"] or "Show Cast Time",
            function() return cb.showTime ~= false end,
            function(v) CastSet(function(c) c.showTime = v end)
                if rebuildFields then rebuildFields() end
            end)
        cbTime:SetPoint("TOPLEFT", 15, y)
        y = y - 28

        local cbCastClass = W.CreateStyledCheckbox(host,
            L["Class Color the Bar"] or "Class Color the Bar",
            function() return cb.classColor == true end,
            function(v) CastSet(function(c) c.classColor = v end) end)
        cbCastClass:SetPoint("TOPLEFT", 15, y)
        y = y - 30

        local castPicker = W.CreateColorPicker(host, L["Bar Color"] or "Bar Color",
            function()
                local c = cb.color or {0.9, 0.7, 0.1, 1}
                return c[1], c[2], c[3], c[4] or 1
            end,
            function(r, g, b, a) CastSet(function(c) c.color = {r, g, b, a or 1} end) end)
        castPicker:SetPoint("TOPLEFT", 15, y)
        y = y - 30

        local shieldPicker = W.CreateColorPicker(host,
            L["Uninterruptible Tint"] or "Uninterruptible Tint",
            function()
                local c = cb.uninterruptibleColor or {0.6, 0.6, 0.6, 0.55}
                return c[1], c[2], c[3], c[4] or 0.55
            end,
            function(r, g, b, a)
                CastSet(function(c) c.uninterruptibleColor = {r, g, b, a or 0.55} end)
            end)
        shieldPicker:SetPoint("TOPLEFT", 15, y)
        y = y - 35

        -- BORDER. Same fields and meaning as the resource bar's border, drawn
        -- by CastBar.ApplyBorder on the real bar and the preview alike.
        W.CreateTitledPane(host, L["Border"] or "Border", y)
        y = y - 35

        local function BorderField(key, fallback)
            local v = cb.border and cb.border[key]
            if v == nil then return fallback end
            return v
        end
        local function BorderSet(key, v)
            CastSet(function(c)
                c.border = c.border or {}
                c.border[key] = v
            end)
        end

        local cbCastBorder = W.CreateStyledCheckbox(host, L["Show"] or "Show",
            function() return BorderField("enabled", false) == true end,
            function(v)
                BorderSet("enabled", v)
                if rebuildFields then rebuildFields() end
            end)
        cbCastBorder:SetPoint("TOPLEFT", 15, y)
        y = y - 30

        if BorderField("enabled", false) == true then
            local sCBThick = W.CreateStyledSlider(host, 200, 1, 8, 1,
                L["Thickness"] or "Thickness",
                function() return BorderField("thickness", 1) end,
                function(v) BorderSet("thickness", v) end)
            sCBThick:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65

            local sCBPad = W.CreateStyledSlider(host, 200, 0, 20, 1,
                L["Padding"] or "Padding",
                function() return BorderField("padding", 0) end,
                function(v) BorderSet("padding", v) end)
            sCBPad:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65

            local cpCBBorder = W.CreateColorPicker(host, L["Color"] or "Color",
                function()
                    local c = BorderField("color", nil)
                    if type(c) ~= "table" then return 0, 0, 0, 1 end
                    return c[1] or 0, c[2] or 0, c[3] or 0, c[4] or 1
                end,
                function(r, g, b, a) BorderSet("color", {r, g, b, a or 1}) end)
            cpCBBorder:SetPoint("TOPLEFT", 15, y - 6)
            y = y - 42
        end

        -- TEXT. One builder for both readouts: the two settings tables have
        -- the same shape, and writing it twice is how the two drift apart.
        --
        -- `key` is the settings sub-table ("nameText"/"timeText"); `shown`
        -- says whether that readout is currently switched on above, since
        -- styling text that is turned off is a control that does nothing.
        local function TextGroup(label, key, shown)
            W.CreateTitledPane(host, label, y)
            y = y - 35

            if not shown then
                local off = host:CreateFontString(nil, "OVERLAY")
                off:SetFontObject("GameFontDisableSmall")
                off:SetPoint("TOPLEFT", 32, y)
                off:SetPoint("RIGHT", host, "RIGHT", -20, 0)
                off:SetJustifyH("LEFT")
                off:SetText(L["CastTextOffNote"] or "Switch this on above to style it.")
                return y - 28
            end

            -- Every getter falls back the way CastBar.ApplyTextStyle does, so
            -- the controls show what is actually being rendered rather than a
            -- blank for "not set yet".
            local function Font(i, fallback)
                local sub = cb[key]
                local f = sub and sub.font
                return (f and f[i]) or fallback
            end
            local function SetFont(i, v)
                CastSet(function(c)
                    c[key] = c[key] or {}
                    c[key].font = c[key].font or {}
                    c[key].font[i] = v
                end)
            end

            local ddFace = W.CreateStyledDropdown(host, 200, 40, L["Font"] or "Font",
                F.GetFontDropdownItems and F.GetFontDropdownItems() or {},
                function() return Font(1, "Friz QT__") end,
                function(v) SetFont(1, v) end, "font")
            ddFace:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 70

            local sSize = W.CreateStyledSlider(host, 200, 6, 24, 1, L["Size"] or "Size",
                function() return Font(2, cb.fontSize or 11) end,
                function(v) SetFont(2, v) end)
            sSize:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65

            -- "NONE" is stored, never passed to SetFont -- ApplyTextStyle
            -- converts it to nil, because it is not a valid flag string.
            local ddOutline = W.CreateStyledDropdown(host, 200, 40, L["Outline"] or "Outline", {
                {value = "NONE",         text = L["None"] or "None"},
                {value = "OUTLINE",      text = L["Outline"] or "Outline"},
                {value = "THICKOUTLINE", text = L["Thick Outline"] or "Thick Outline"},
            }, function() return Font(3, "OUTLINE") end, function(v) SetFont(3, v) end)
            ddOutline:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 70

            local cp = W.CreateColorPicker(host, L["Color"] or "Color",
                function()
                    local sub = cb[key]
                    local c = sub and sub.color
                    if type(c) ~= "table" then return 1, 1, 1, 1 end
                    return c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1
                end,
                function(r, g, b, a)
                    CastSet(function(c)
                        c[key] = c[key] or {}
                        c[key].color = {r, g, b, a or 1}
                    end)
                end)
            cp:SetPoint("TOPLEFT", 15, y - 6)
            y = y - 36

            local function Offset(axis, v)
                CastSet(function(c)
                    c[key] = c[key] or {}
                    c[key][axis] = v
                end)
            end
            local sX = W.CreateStyledSlider(host, 200, -100, 100, 1, L["Offset X"] or "Offset X",
                function() local s = cb[key]; return (s and s.x) or 0 end,
                function(v) Offset("x", v) end)
            sX:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65

            local sY = W.CreateStyledSlider(host, 200, -30, 30, 1, L["Offset Y"] or "Offset Y",
                function() local s = cb[key]; return (s and s.y) or 0 end,
                function(v) Offset("y", v) end)
            sY:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 70

            return y
        end

        y = TextGroup(L["Spell Name"] or "Spell Name", "nameText", cb.showName ~= false)
        y = TextGroup(L["Cast Time"] or "Cast Time", "timeText", cb.showTime ~= false)
    end

end

-- The nine anchor points, offered wherever something is placed against a
-- corner/edge. One table so the aura text controls cannot drift apart.
local ANCHOR_POINT_ITEMS = {
    {value = "TOPLEFT",     text = "Top Left"},
    {value = "TOP",         text = "Top"},
    {value = "TOPRIGHT",    text = "Top Right"},
    {value = "LEFT",        text = "Left"},
    {value = "CENTER",      text = "Center"},
    {value = "RIGHT",       text = "Right"},
    {value = "BOTTOMLEFT",  text = "Bottom Left"},
    {value = "BOTTOM",      text = "Bottom"},
    {value = "BOTTOMRIGHT", text = "Bottom Right"},
}

-- Buffs and debuffs share one builder: the two settings tables have the same
-- shape, and writing it twice is how the two drift apart.
local function BuildAuraBlock(host, y, t, kind, label)
    local A = SquizzFrames.UnitFrameAuras
    W.CreateTitledPane(host, label, y)
    y = y - 35

    local function Cfg()
        local c = GetUnitConfig()
        if not c then return nil end
        if not c[kind] then c[kind] = {anchor = "none"} end
        return c[kind]
    end
    local function AuraSet(apply)
        local c = Cfg()
        if not c then return end
        apply(c)
        Changed()
    end

    local a = Cfg()
    if not a then return y end

    -- Anchor doubles as the on/off switch ("none"), so there is no separate
    -- enable checkbox and no way to have a row that is on but has nowhere
    -- to be.
    local ddAnchor = W.CreateStyledDropdown(host, 200, 40, L["Position"] or "Position",
        (A and A.ANCHOR_ITEMS) or {},
        function() return a.anchor or "none" end,
        function(v)
            AuraSet(function(c) c.anchor = v end)
            if rebuildFields then rebuildFields() end
        end)
    ddAnchor:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    if (a.anchor or "none") == "none" then return y end

    local ddGrowth = W.CreateStyledDropdown(host, 200, 40, L["Growth"] or "Growth",
        (A and A.GROWTH_ITEMS) or {},
        function() return a.growth or "auto" end,
        function(v) AuraSet(function(c) c.growth = v end) end)
    ddGrowth:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    local sNum = W.CreateStyledSlider(host, 200, 1, 40, 1, L["Max Icons"] or "Max Icons",
        function() return a.num or 8 end,
        function(v) AuraSet(function(c) c.num = v end) end)
    sNum:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    local sSize = W.CreateStyledSlider(host, 200, 8, 64, 1, L["Icon Size"] or "Icon Size",
        function() return a.size or 20 end,
        function(v) AuraSet(function(c) c.size = v end) end)
    sSize:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    local sAX = W.CreateStyledSlider(host, 200, -200, 200, 1, L["Offset X"] or "Offset X",
        function() return a.offsetX or 0 end,
        function(v) AuraSet(function(c) c.offsetX = v end) end)
    sAX:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    local sAY = W.CreateStyledSlider(host, 200, -200, 200, 1, L["Offset Y"] or "Offset Y",
        function() return a.offsetY or 0 end,
        function(v) AuraSet(function(c) c.offsetY = v end) end)
    sAY:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    local cbMine = W.CreateStyledCheckbox(host, L["Mine Only"] or "Mine Only",
        function() return a.onlyMine == true end,
        function(v) AuraSet(function(c) c.onlyMine = v end) end)
    cbMine:SetPoint("TOPLEFT", 15, y)
    y = y - 28

    local cbDur = W.CreateStyledCheckbox(host, L["Show Duration"] or "Show Duration",
        function() return a.showDuration ~= false end,
        function(v)
            AuraSet(function(c) c.showDuration = v end)
            if rebuildFields then rebuildFields() end
        end)
    cbDur:SetPoint("TOPLEFT", 15, y)
    y = y - 28

    -- Placement controls appear only while the text they place is on --
    -- otherwise they are three live controls that visibly do nothing.
    if a.showDuration ~= false then
        local ddDP = W.CreateStyledDropdown(host, 200, 40,
            L["Duration Anchor"] or "Duration Anchor", ANCHOR_POINT_ITEMS,
            function() return a.durationPoint or "CENTER" end,
            function(v) AuraSet(function(c) c.durationPoint = v end) end)
        ddDP:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        -- The icon-side point. Pairing a point with itself puts the text ON
        -- the icon -- CENTER/CENTER is the default; pairing TOP with BOTTOM
        -- hangs it underneath instead.
        local ddDRP = W.CreateStyledDropdown(host, 200, 40,
            L["Duration Anchor To"] or "Duration Anchor To", ANCHOR_POINT_ITEMS,
            function() return a.durationRelPoint or "CENTER" end,
            function(v) AuraSet(function(c) c.durationRelPoint = v end) end)
        ddDRP:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        local sDX = W.CreateStyledSlider(host, 200, -50, 50, 1,
            L["Duration Offset X"] or "Duration Offset X",
            function() return a.durationX or 0 end,
            function(v) AuraSet(function(c) c.durationX = v end) end)
        sDX:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local sDY = W.CreateStyledSlider(host, 200, -50, 50, 1,
            L["Duration Offset Y"] or "Duration Offset Y",
            function() return a.durationY or 0 end,
            function(v) AuraSet(function(c) c.durationY = v end) end)
        sDY:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65
    end

    local cbStack = W.CreateStyledCheckbox(host, L["Show Stacks"] or "Show Stacks",
        function() return a.showStack ~= false end,
        function(v)
            AuraSet(function(c) c.showStack = v end)
            if rebuildFields then rebuildFields() end
        end)
    cbStack:SetPoint("TOPLEFT", 15, y)
    y = y - 28

    if a.showStack ~= false then
        -- One point only: the engine uses stackPoint for both the text's own
        -- point and the icon's, so there is no "anchor to" counterpart here.
        local ddSP = W.CreateStyledDropdown(host, 200, 40,
            L["Stack Anchor"] or "Stack Anchor", ANCHOR_POINT_ITEMS,
            function() return a.stackPoint or "BOTTOMRIGHT" end,
            function(v) AuraSet(function(c) c.stackPoint = v end) end)
        ddSP:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        local sSX = W.CreateStyledSlider(host, 200, -50, 50, 1,
            L["Stack Offset X"] or "Stack Offset X",
            function() return a.stackX or 1 end,
            function(v) AuraSet(function(c) c.stackX = v end) end)
        sSX:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local sSY = W.CreateStyledSlider(host, 200, -50, 50, 1,
            L["Stack Offset Y"] or "Stack Offset Y",
            function() return a.stackY or -1 end,
            function(v) AuraSet(function(c) c.stackY = v end) end)
        sSY:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65
    end

    local cbBord = W.CreateStyledCheckbox(host, L["Icon Border"] or "Icon Border",
        function() return a.showBorder ~= false end,
        function(v) AuraSet(function(c) c.showBorder = v end) end)
    cbBord:SetPoint("TOPLEFT", 15, y)
    y = y - 35

    return y
end

local function SecAuras(host, y, cfg, t)
    y = BuildAuraBlock(host, y, t, "buffs", L["Buffs"] or "Buffs")
    y = BuildAuraBlock(host, y, t, "debuffs", L["Debuffs"] or "Debuffs")
end

local function SecPosition(host, y, cfg, t)
    W.CreateTitledPane(host, L["Positioning"] or "Positioning", y)
    y = y - 35

    local hint = host:CreateFontString(nil, "OVERLAY")
    hint:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    hint:SetPoint("TOPLEFT", 15, y)
    hint:SetTextColor(0.7, 0.7, 0.7, 1)
    hint:SetText(L["Drag each frame in Edit Mode to position it."]
        or "Drag each frame in Edit Mode to position it.")
end

-- State icons. Same generated-accessor treatment as the text elements, for
-- the same reason: the settings key is all that differs between them.
local function IconGetters(key)
    local function Cfg(t)
        t[key] = t[key] or {}
        return t[key]
    end
    local function Read(field, fallback)
        local t = GetUnitConfig()
        local v = t and t[key] and t[key][field]
        if v == nil then return fallback end
        return v
    end
    return {
        enabled = function() return Read("enabled", false) == true end,
        setEnabled = function(v)
            Set(function(t) Cfg(t).enabled = v end)
            if rebuildFields then rebuildFields() end
        end,
        anchor = function() return Read("anchor", "TOPRIGHT") end,
        setAnchor = function(v) Set(function(t) Cfg(t).anchor = v end) end,
        size = function() return Read("size", 16) end,
        setSize = function(v) Set(function(t) Cfg(t).size = v end) end,
        x = function() return Read("x", 0) end,
        setX = function(v) Set(function(t) Cfg(t).x = v end) end,
        y = function() return Read("y", 0) end,
        setY = function(v) Set(function(t) Cfg(t).y = v end) end,
        color = function()
            local c = Read("color", nil)
            if type(c) ~= "table" then return 1, 1, 1, 1 end
            return c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1
        end,
        setColor = function(r, g, b, a)
            Set(function(t) Cfg(t).color = {r, g, b, a} end)
        end,
    }
end

local function BuildIconGroup(host, y, key, label, note)
    local acc = IconGetters(key)

    W.CreateTitledPane(host, label, y)
    y = y - 35

    local cbOn = W.CreateStyledCheckbox(host, L["Show"] or "Show",
        acc.enabled, acc.setEnabled)
    cbOn:SetPoint("TOPLEFT", 15, y)
    y = y - 26

    if note then
        local fs = host:CreateFontString(nil, "OVERLAY")
        fs:SetFontObject("GameFontDisableSmall")
        fs:SetPoint("TOPLEFT", 32, y)
        fs:SetPoint("RIGHT", host, "RIGHT", -20, 0)
        fs:SetJustifyH("LEFT")
        fs:SetText(note)
        y = y - 26
    end

    if acc.enabled() then
        local dd = W.CreateStyledDropdown(host, 200, 40, L["Anchor"] or "Anchor",
            AnchorItems(), acc.anchor, acc.setAnchor)
        dd:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        local sX = W.CreateStyledSlider(host, 200, -100, 100, 1, L["Offset X"] or "Offset X",
            acc.x, acc.setX)
        sX:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local sY = W.CreateStyledSlider(host, 200, -100, 100, 1, L["Offset Y"] or "Offset Y",
            acc.y, acc.setY)
        sY:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local sSize = W.CreateStyledSlider(host, 200, 6, 48, 1, L["Size"] or "Size",
            acc.size, acc.setSize)
        sSize:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local cp = W.CreateColorPicker(host, L["Tint"] or "Tint",
            acc.color, acc.setColor)
        cp:SetPoint("TOPLEFT", 15, y - 6)
        y = y - 42
    end

    return y
end

-- BOTH icons are the PLAYER frame's, by request. They are not built as
-- hidden-but-present controls on the other tabs: an option that exists in the
-- saved data with no way to reach it is the "live control that silently does
-- nothing" failure in reverse.
--
-- Nothing in Icons.lua is player-specific -- it reads UnitAffectingCombat and
-- UnitIsGroupLeader on whatever unit it is given -- so widening this later is
-- deleting the activeUnit check, not writing new code. The restriction lives
-- here on purpose rather than in the engine.
local function SecIcons(host, y, cfg, t)
    if activeUnit ~= "player" then
        local fs = host:CreateFontString(nil, "OVERLAY")
        fs:SetFontObject("GameFontDisableSmall")
        fs:SetPoint("TOPLEFT", 15, y - 10)
        fs:SetPoint("RIGHT", host, "RIGHT", -20, 0)
        fs:SetJustifyH("LEFT")
        fs:SetText(L["IconsPlayerOnlyNote"]
            or "The combat and leader icons are on the Player frame only. Switch to the Player tab to set them up.")
        return y - 40
    end

    y = BuildIconGroup(host, y, "combatIcon",
        L["Combat Icon"] or "Combat Icon",
        L["CombatIconNote"]
            or "The crossed-swords marker, shown while you are in combat.")

    y = BuildIconGroup(host, y, "leaderIcon",
        L["Leader Icon"] or "Leader Icon",
        L["LeaderIconNote"]
            or "The leader crown, or the assistant badge in a raid.")

    return y
end

-- Absorb overlays. Both sit ON the health bar, so both offer a colour with an
-- opacity rather than a position -- there is nowhere else for them to go.
local function AbsorbGetters(key)
    local function Cfg(t)
        t[key] = t[key] or {}
        return t[key]
    end
    local function Read(field, fallback)
        local t = GetUnitConfig()
        local v = t and t[key] and t[key][field]
        if v == nil then return fallback end
        return v
    end
    return {
        enabled = function() return Read("enabled", false) == true end,
        setEnabled = function(v)
            Set(function(t) Cfg(t).enabled = v end)
            if rebuildFields then rebuildFields() end
        end,
        reverseFill = function() return Read("reverseFill", false) == true end,
        setReverseFill = function(v) Set(function(t) Cfg(t).reverseFill = v end) end,
        overshields = function() return Read("onlyShowOvershields", false) == true end,
        setOvershields = function(v)
            Set(function(t) Cfg(t).onlyShowOvershields = v end)
        end,
        color = function()
            local c = Read("color", nil)
            if type(c) ~= "table" then return 1, 1, 1, 0.55 end
            return c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 0.55
        end,
        setColor = function(r, g, b, a)
            Set(function(t) Cfg(t).color = {r, g, b, a} end)
        end,
    }
end

local function SecAbsorbs(host, y, cfg, t)
    -- Shield (damage absorb)
    local shield = AbsorbGetters("shieldBar")
    W.CreateTitledPane(host, L["Shield"] or "Shield", y)
    y = y - 35

    local cbShield = W.CreateStyledCheckbox(host, L["Show"] or "Show",
        shield.enabled, shield.setEnabled)
    cbShield:SetPoint("TOPLEFT", 15, y)
    y = y - 26

    local shieldNote = host:CreateFontString(nil, "OVERLAY")
    shieldNote:SetFontObject("GameFontDisableSmall")
    shieldNote:SetPoint("TOPLEFT", 32, y)
    shieldNote:SetPoint("RIGHT", host, "RIGHT", -20, 0)
    shieldNote:SetJustifyH("LEFT")
    shieldNote:SetText(L["ShieldBarNote"]
        or "Incoming damage absorb, drawn over the health bar. Keep the opacity below full so the bar stays readable underneath.")
    y = y - 34

    if shield.enabled() then
        local cp = W.CreateColorPicker(host, L["Color"] or "Color",
            shield.color, shield.setColor)
        cp:SetPoint("TOPLEFT", 15, y - 6)
        y = y - 36

        local cbOver = W.CreateStyledCheckbox(host,
            L["Only Show Overshields"] or "Only Show Overshields",
            shield.overshields, shield.setOvershields)
        cbOver:SetPoint("TOPLEFT", 15, y)
        y = y - 26

        local overNote = host:CreateFontString(nil, "OVERLAY")
        overNote:SetFontObject("GameFontDisableSmall")
        overNote:SetPoint("TOPLEFT", 32, y)
        overNote:SetPoint("RIGHT", host, "RIGHT", -20, 0)
        overNote:SetJustifyH("LEFT")
        overNote:SetText(L["OvershieldNote"]
            or "Hide it until the absorb is bigger than the missing health - the point at which more healing would be wasted.")
        y = y - 34

        local cbRev = W.CreateStyledCheckbox(host,
            L["Fill From Right"] or "Fill From Right",
            shield.reverseFill, shield.setReverseFill)
        cbRev:SetPoint("TOPLEFT", 15, y)
        y = y - 36
    end

    -- Heal absorb
    local heal = AbsorbGetters("healAbsorb")
    W.CreateTitledPane(host, L["Heal Absorb"] or "Heal Absorb", y)
    y = y - 35

    local cbHeal = W.CreateStyledCheckbox(host, L["Show"] or "Show",
        heal.enabled, heal.setEnabled)
    cbHeal:SetPoint("TOPLEFT", 15, y)
    y = y - 26

    local healNote = host:CreateFontString(nil, "OVERLAY")
    healNote:SetFontObject("GameFontDisableSmall")
    healNote:SetPoint("TOPLEFT", 32, y)
    healNote:SetPoint("RIGHT", host, "RIGHT", -20, 0)
    healNote:SetJustifyH("LEFT")
    healNote:SetText(L["HealAbsorbNote"]
        or "Healing that will be swallowed before it lands, measured against current health.")
    y = y - 34

    if heal.enabled() then
        local cp = W.CreateColorPicker(host, L["Color"] or "Color",
            heal.color, heal.setColor)
        cp:SetPoint("TOPLEFT", 15, y - 6)
        y = y - 36

        local cbRev = W.CreateStyledCheckbox(host,
            L["Fill From Right"] or "Fill From Right",
            heal.reverseFill, heal.setReverseFill)
        cbRev:SetPoint("TOPLEFT", 15, y)
        y = y - 30
    end

    return y
end

-- A strip of sub-tab buttons across the top of a section, as used by
-- Indicators and Resources: pick the sub-tab, then configure it. Returns the
-- y below the strip. `onPick(key)` runs only for a tab that is not already
-- active; the caller stores the key and rebuilds.
local SubTabs
do
    -- Fixed button geometry the wrap below packs into however many columns
    -- the pane's current width actually has room for.
    local BTN_W, BTN_H, GAP_X, GAP_Y = 76, 22, 3, 3

    SubTabs = function(host, y, tabs, activeKey, onPick)
        local strip = CreateFrame("Frame", nil, host)
        strip:SetPoint("TOPLEFT", 15, y)
        strip:SetPoint("RIGHT", host, "RIGHT", -20, 0)

        -- WRAPPED, not a fixed single row: at a narrower/default window size
        -- the strip's own width (host's, minus the sidebar/preview insets) is
        -- less than every tab needs, and the trailing ones used to run past
        -- the strip's right edge and under the preview pane -- present, but
        -- unclickable. GetWidth() is valid immediately here because the whole
        -- parent chain up to the options window is already laid out by the
        -- time BuildFields runs (same assumption IndicatorsPanel.lua's
        -- listScroll and settingsScroll make with the identical
        -- GetWidth()-right-after-SetPoint pattern).
        local availWidth = strip:GetWidth()
        local stepX = BTN_W + GAP_X
        local perRow = math.max(1, math.floor((availWidth + GAP_X) / stepX))

        local x, row = 0, 0
        for i, tab in ipairs(tabs) do
            if i > 1 and (i - 1) % perRow == 0 then
                row = row + 1
                x = 0
            end
            local btn = CreateFrame("Button", nil, strip, "BackdropTemplate")
            btn:SetSize(BTN_W, BTN_H)
            btn:SetPoint("TOPLEFT", strip, "TOPLEFT", x, -row * (BTN_H + GAP_Y))
            local isActive = (tab.key == activeKey)
            local accent = F.GetAccentColor()
            W.StylizeFrame(btn,
                isActive and {accent.r, accent.g, accent.b, 0.55} or {0.115, 0.115, 0.115, 1},
                {0, 0, 0, 0})
            local text = btn:CreateFontString(nil, "OVERLAY")
            text:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
            text:SetPoint("CENTER")
            text:SetText(tab.label)
            btn:SetScript("OnClick", function()
                if tab.key == activeKey then return end
                onPick(tab.key)
            end)
            x = x + stepX
        end

        -- Height reflects however many rows the wrap actually produced, so
        -- content below the strip (the selected sub-tab's own fields) starts
        -- right after it rather than at a height that only fit one row.
        local rows = row + 1
        local stripHeight = rows * BTN_H + (rows - 1) * GAP_Y
        strip:SetHeight(stripHeight)
        return y - stripHeight - 10
    end
end

-- The resource bar. Module-wide rather than per-unit (it is always the
-- player's own resources), so its accessors read profile.unitFrames.resourceBar
-- directly instead of going through GetUnitConfig.
-- `sub` addresses a nested table (border), so one generator serves both the
-- flat settings and the grouped ones.
local function ResourceGetters(sub)
    local function Cfg()
        local cfg = GetConfig()
        if not cfg then return nil end
        cfg.resourceBar = cfg.resourceBar or {}
        local t = cfg.resourceBar
        if sub then
            t[sub] = t[sub] or {}
            t = t[sub]
        end
        return t
    end
    -- Deliberately does NOT go through Cfg: that materialises missing tables,
    -- and merely OPENING the options page should not write to the profile.
    local function Read(field, fallback)
        local c = GetConfig()
        local t = c and c.resourceBar
        if sub then t = t and t[sub] end
        local v = t and t[field]
        if v == nil then return fallback end
        return v
    end
    local function Write(field, v)
        local c = Cfg()
        if not c then return end
        c[field] = v
        Changed()
    end
    return {
        Read = Read,
        Write = Write,
        bool = function(field, fallback)
            return function() return Read(field, fallback) == true end
        end,
        -- Rebuilding setter, for the switches that add or remove controls
        -- below them. Kept separate so a plain slider never rebuilds the page
        -- mid-drag.
        setBoolRebuild = function(field)
            return function(v) Write(field, v); if rebuildFields then rebuildFields() end end
        end,
        setBool = function(field)
            return function(v) Write(field, v) end
        end,
        -- Generic: these carry strings (a dropdown value) as often as
        -- numbers, hence the neutral names.
        get = function(field, fallback)
            return function() return Read(field, fallback) end
        end,
        set = function(field)
            return function(v) Write(field, v) end
        end,
        colorGet = function(field, dr, dg, db, da)
            return function()
                local c = Read(field, nil)
                if type(c) ~= "table" then return dr, dg, db, da end
                return c[1] or dr, c[2] or dg, c[3] or db, c[4] or da
            end
        end,
        colorSet = function(field)
            return function(r, g, b, a) Write(field, {r, g, b, a}) end
        end,
    }
end

local COLOR_MODE_ITEMS = {
    {value = "auto",   text = L["Automatic"] or "Automatic"},
    {value = "class",  text = L["Class Color"] or "Class Color"},
    {value = "custom", text = L["Custom"] or "Custom"},
}

local POWER_TEXT_ITEMS = {
    {value = "power",        text = L["Power"] or "Power"},
    {value = "powerPercent", text = L["Power %"] or "Power %"},
}

-- The resource bar's options, in three sub-tabs rather than one long scroll:
--   General   the switches and the look shared by both rows
--   Power     the power bar -- and, while the points ride inside it, where
--             the whole bar goes and how wide it is
--   Resource  the points: style, size, colour, and (detached) their own
--             position and width
-- The strip is the same one Indicators uses -- see SubTabs.
local SecResource
do
    local RESOURCE_TABS = {
        {key = "general",  label = L["General"] or "General"},
        {key = "power",    label = L["Power"] or "Power"},
        {key = "resource", label = L["Resource"] or "Resource"},
    }
    -- Persists across page switches within a session, like activeIndicatorTab.
    local activeResourceTab = "general"

    local function Rebuild()
        if rebuildFields then rebuildFields() end
    end

    -- A wrapped grey note, MEASURED rather than stepped by a fixed amount.
    -- The column is narrow and the same sentence can take two lines or five;
    -- a hardcoded step overlapped the next control (the enable note ran into
    -- Move Points Separately). Same approach as TankTrackerPanel's Note.
    --
    -- Needs a real width before GetStringHeight can report the wrapped
    -- height, and host:GetWidth() is valid here -- see BuildFields, which
    -- anchors the host between the sidebar and the preview before any Sec*
    -- builder runs. 32 in from the left, 20 clear of the right edge, as these
    -- notes always were; the fallback only covers a zero-width host.
    local function Note(host, noteY, text)
        local fs = host:CreateFontString(nil, "OVERLAY")
        fs:SetFontObject("GameFontDisableSmall")
        fs:SetPoint("TOPLEFT", 32, noteY)
        local hostW = host:GetWidth()
        fs:SetWidth((hostW and hostW > 80) and (hostW - 52) or 250)
        fs:SetJustifyH("LEFT")
        fs:SetText(text)
        return noteY - math.ceil(fs:GetStringHeight() or 24) - 12
    end

    local POSITION_ITEMS = {
        {value = "free",   text = L["Free (drag it)"] or "Free (drag it)"},
        {value = "anchor", text = L["Anchored to a Frame"] or "Anchored to a Frame"},
    }

    -- One placement block, for the power bar or the detached points. Shares
    -- the cast bar's curated frame list and side vocabulary so "anchor to the
    -- Essential Cooldowns row" means the same thing and reads the same way in
    -- both places.
    --   spec.getters      accessors for the table it edits
    --   spec.mode         the EFFECTIVE mode (loop already broken)
    --   spec.items        the modes on offer
    --   spec.partnerMode  the value meaning "rides the other resource frame"
    --   spec.frame()      the frame a switch to free is seeded from
    --   spec.seedTable()  the position table that seed writes into
    local function PositionBlock(host, y, ctx, spec)
        local P, mode, CB = spec.getters, spec.mode, ctx.CB

        local ddPos = W.CreateStyledDropdown(host, 200, 40, L["Position"] or "Position",
            spec.items, function() return mode end,
            function(v)
                -- Switching to free starts from where the frame is NOW, not
                -- from a free position saved before it was attached somewhere.
                if v == "free" and mode ~= "free" and ctx.RB and ctx.RB.SeedFreePosition then
                    local pos = spec.seedTable()
                    if pos then ctx.RB.SeedFreePosition(spec.frame(), pos) end
                end
                P.Write("positionMode", v)
                Rebuild()
            end)
        ddPos:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        if (mode == "anchor" or mode == spec.partnerMode) and CB then
            if mode == "anchor" then
                local ddTo = W.CreateStyledDropdown(host, 200, 40, L["Attach To"] or "Attach To",
                    CB.MATCH_TARGETS, P.get("attachTo", "EssentialCooldownViewer"),
                    P.set("attachTo"))
                ddTo:SetPoint("TOPLEFT", 15, y - 20)
                y = y - 70
            end

            local ddSide = W.CreateStyledDropdown(host, 200, 40, L["Side"] or "Side",
                CB.ATTACH_SIDES, P.get("attachSide", spec.defaultSide), P.set("attachSide"))
            ddSide:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 70

            local sOX = W.CreateStyledSlider(host, 200, -300, 300, 1, L["Offset X"] or "Offset X",
                P.get("offsetX", 0), P.set("offsetX"))
            sOX:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65

            local sOY = W.CreateStyledSlider(host, 200, -300, 300, 1, L["Offset Y"] or "Offset Y",
                P.get("offsetY", spec.defaultOffsetY), P.set("offsetY"))
            sOY:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 70
        end
        return y
    end

    -- One width block: the mode, then the frame to match or the custom width.
    -- A saved mode this list does not offer (Fit to Points on a row since
    -- switched to bars) shows as `fallback`, which is how the bar treats it.
    local function WidthBlock(host, y, ctx, P, items, fallback, minWidth)
        local mode = P.Read("widthMode", fallback)
        local offered = false
        for _, item in ipairs(items) do
            if item.value == mode then offered = true end
        end
        if not offered then mode = fallback end

        local ddWidth = W.CreateStyledDropdown(host, 200, 40, L["Width"] or "Width",
            items, function() return mode end,
            function(v) P.Write("widthMode", v); Rebuild() end)
        ddWidth:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        if mode == "match" and ctx.CB then
            local ddMatch = W.CreateStyledDropdown(host, 200, 40, L["Match Width Of"] or "Match Width Of",
                ctx.CB.MATCH_TARGETS, P.get("matchFrame", "EssentialCooldownViewer"),
                P.set("matchFrame"))
            ddMatch:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 70
        elseif mode == "custom" then
            local sWidth = W.CreateStyledSlider(host, 200, minWidth, 600, 1, L["Width"] or "Width",
                P.get("width", 220), P.set("width"))
            sWidth:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65
        end
        return mode, y
    end

    -------------------------------------------------------------------
    -- General
    -------------------------------------------------------------------
    local function TabGeneral(host, y, ctx)
        local R, RB, detached = ctx.R, ctx.RB, ctx.detached

        -- Separate the point row from the power bar. Seeded BEFORE the switch
        -- is written, so the first layout with two frames already places the
        -- points (and nudges the power bar) exactly where they were -- see
        -- ResourceBar.SeedDetach.
        local cbDetach = W.CreateStyledCheckbox(host,
            L["Move Points Separately"] or "Move Points Separately",
            R.bool("detachPoints", false),
            function(v)
                if v and not detached and RB and RB.SeedDetach then
                    local c = GetConfig()
                    if c then
                        c.resourceBar = c.resourceBar or {}
                        RB.SeedDetach(c.resourceBar)
                    end
                end
                R.Write("detachPoints", v)
                Rebuild()
            end)
        cbDetach:SetPoint("TOPLEFT", 15, y)
        y = y - 26

        y = Note(host, y, L["ResourceDetachNote"]
            or "Gives the resource points their own position and width, so the power bar and the points can each be dragged, attached to another frame, or attached to each other. They start exactly where they are now.")

        local sScale = W.CreateStyledSlider(host, 200, 0.5, 2, 0.05, L["Scale"] or "Scale",
            R.get("scale", 1), R.set("scale"))
        sScale:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        -- Background
        local BG = ResourceGetters("background")

        W.CreateTitledPane(host, L["Background"] or "Background", y)
        y = y - 35

        local cbBg = W.CreateStyledCheckbox(host, L["Show"] or "Show",
            function() return BG.Read("enabled", true) ~= false end,
            BG.setBoolRebuild("enabled"))
        cbBg:SetPoint("TOPLEFT", 15, y)
        y = y - 26

        if detached then
            y = Note(host, y, L["ResourceBackgroundNoteDetached"]
                or "A solid fill behind the power bar and behind the points, each on its own. Without it the gaps between the resource points are see-through, which makes them hard to count against a busy background.")
        else
            y = Note(host, y, L["ResourceBackgroundNote"]
                or "A solid fill behind the whole bar. Without it the gaps between the resource points are see-through, which makes them hard to count against a busy background.")
        end

        if BG.Read("enabled", true) ~= false then
            local cpBg = W.CreateColorPicker(host, L["Color"] or "Color",
                BG.colorGet("color", 0, 0, 0, 0.8), BG.colorSet("color"))
            cpBg:SetPoint("TOPLEFT", 15, y - 6)
            y = y - 36

            local sBgPad = W.CreateStyledSlider(host, 200, 0, 20, 1,
                L["Padding"] or "Padding",
                BG.get("padding", 0), BG.set("padding"))
            sBgPad:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 70
        end

        -- Border
        local B = ResourceGetters("border")

        W.CreateTitledPane(host, L["Border"] or "Border", y)
        y = y - 35

        -- Detached, the power bar and the points each get their own switch;
        -- thickness, padding and colour stay shared. See
        -- ResourceBar.PointsBorderOn for why the points' switch follows the
        -- power bar's until it is set.
        local function PointsBorderOn()
            local c = GetConfig()
            local b = c and c.resourceBar and c.resourceBar.border
            return (RB and RB.PointsBorderOn and RB.PointsBorderOn(b)) or false
        end

        if detached then
            local cbBorder = W.CreateStyledCheckbox(host, L["Power Bar"] or "Power Bar",
                B.bool("enabled", false),
                function(v)
                    -- Pin the points' switch first, so it stops following
                    -- this one the moment they can differ.
                    if B.Read("pointsEnabled", nil) == nil then
                        B.Write("pointsEnabled", PointsBorderOn())
                    end
                    B.Write("enabled", v)
                    Rebuild()
                end)
            cbBorder:SetPoint("TOPLEFT", 15, y)
            y = y - 26

            local cbPointsBorder = W.CreateStyledCheckbox(host,
                L["Resource Points"] or "Resource Points",
                PointsBorderOn, B.setBoolRebuild("pointsEnabled"))
            cbPointsBorder:SetPoint("TOPLEFT", 15, y)
            y = y - 26

            y = Note(host, y, L["ResourceBorderNoteDetached"]
                or "Outlines the power bar and the resource points separately, one box each, and each can be switched on or off. Thickness, padding and colour are shared.")
        else
            local cbBorder = W.CreateStyledCheckbox(host, L["Show"] or "Show",
                B.bool("enabled", false), B.setBoolRebuild("enabled"))
            cbBorder:SetPoint("TOPLEFT", 15, y)
            y = y - 26

            y = Note(host, y, L["ResourceBorderNote"]
                or "Outlines the whole bar, both rows together. Set the row Gap to 0 if you want it tight around them.")
        end

        if B.Read("enabled", false) or (detached and PointsBorderOn()) then
            local sThick = W.CreateStyledSlider(host, 200, 1, 8, 1,
                L["Thickness"] or "Thickness",
                B.get("thickness", 1), B.set("thickness"))
            sThick:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65

            local sPad = W.CreateStyledSlider(host, 200, 0, 20, 1,
                L["Padding"] or "Padding",
                B.get("padding", 0), B.set("padding"))
            sPad:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65

            local cpBorder = W.CreateColorPicker(host, L["Color"] or "Color",
                B.colorGet("color", 0, 0, 0, 1), B.colorSet("color"))
            cpBorder:SetPoint("TOPLEFT", 15, y - 6)
            y = y - 42
        end

        return y
    end

    -------------------------------------------------------------------
    -- Power
    -------------------------------------------------------------------
    local POWER_WIDTH_ITEMS = {
        {value = "custom", text = L["Custom"] or "Custom"},
        {value = "match",  text = L["Match a Frame"] or "Match a Frame"},
    }

    local function TabPower(host, y, ctx)
        local R, detached = ctx.R, ctx.detached

        W.CreateTitledPane(host, L["Power Bar"] or "Power Bar", y)
        y = y - 35

        local cbPower = W.CreateStyledCheckbox(host, L["Show"] or "Show",
            R.bool("showPower", true), R.setBoolRebuild("showPower"))
        cbPower:SetPoint("TOPLEFT", 15, y)
        y = y - 26

        if not detached then
            y = Note(host, y, L["ResourcePowerAttachedNote"]
                or "The resource points sit inside this bar, so the Position and Width below place both. Turn on Move Points Separately under General to give the points their own.")
        end

        local showPower = R.Read("showPower", true)
        if showPower then
            local sH = W.CreateStyledSlider(host, 200, 2, 60, 1, L["Height"] or "Height",
                R.get("powerHeight", 16), R.set("powerHeight"))
            sH:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 70

            local ddColor = W.CreateStyledDropdown(host, 200, 40, L["Color"] or "Color",
                COLOR_MODE_ITEMS, R.get("powerColorMode", "auto"),
                function(v) R.Write("powerColorMode", v); Rebuild() end)
            ddColor:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 70

            if R.Read("powerColorMode", "auto") == "custom" then
                local cp = W.CreateColorPicker(host, L["Custom Color"] or "Custom Color",
                    R.colorGet("powerColor", 0.2, 0.4, 0.8, 1), R.colorSet("powerColor"))
                cp:SetPoint("TOPLEFT", 15, y - 6)
                y = y - 36
            end
        elseif detached then
            -- A hidden bar that carries nothing else has nothing to place.
            return y
        end

        -- Position
        W.CreateTitledPane(host, L["Position"] or "Position", y)
        y = y - 35

        -- "Attached to Resource Points" only while detached, and only while
        -- the points are not already riding the bar -- both at once is an
        -- anchor loop.
        local barItems = POSITION_ITEMS
        if detached and ctx.pointsMode ~= "power" then
            barItems = {POSITION_ITEMS[1], POSITION_ITEMS[2],
                {value = "points", text = L["Attached to Resource Points"] or "Attached to Resource Points"}}
        end

        y = PositionBlock(host, y, ctx, {
            getters = R, mode = ctx.barMode, items = barItems, partnerMode = "points",
            defaultSide = "BOTTOM", defaultOffsetY = 0,
            frame = function() return ctx.RB and ctx.RB.bar end,
            seedTable = function()
                local c = GetConfig()
                return c and c.resourceBar
            end,
        })

        -- Width
        W.CreateTitledPane(host, L["Width"] or "Width", y)
        y = y - 35

        local _
        _, y = WidthBlock(host, y, ctx, R, POWER_WIDTH_ITEMS, "custom", 60)

        if not showPower then return y end

        -- Text
        W.CreateTitledPane(host, L["Text"] or "Text", y)
        y = y - 35

        local cbText = W.CreateStyledCheckbox(host, L["Show Text"] or "Show Text",
            R.bool("showPowerText", true), R.setBoolRebuild("showPowerText"))
        cbText:SetPoint("TOPLEFT", 15, y)
        y = y - 30

        if R.Read("showPowerText", true) then
            local ddFmt = W.CreateStyledDropdown(host, 200, 40, L["Format"] or "Format",
                POWER_TEXT_ITEMS, R.get("textFormat", "power"), R.set("textFormat"))
            ddFmt:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 70

            local ddAnchor = W.CreateStyledDropdown(host, 200, 40, L["Anchor"] or "Anchor",
                AnchorItems(), R.get("textAnchor", "CENTER"), R.set("textAnchor"))
            ddAnchor:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 70

            local sTX = W.CreateStyledSlider(host, 200, -100, 100, 1, L["Offset X"] or "Offset X",
                R.get("textX", 0), R.set("textX"))
            sTX:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65

            local sTY = W.CreateStyledSlider(host, 200, -50, 50, 1, L["Offset Y"] or "Offset Y",
                R.get("textY", 0), R.set("textY"))
            sTY:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65

            local sFont = W.CreateStyledSlider(host, 200, 6, 24, 1, L["Size"] or "Size",
                R.get("fontSize", 12), R.set("fontSize"))
            sFont:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65

            local cpText = W.CreateColorPicker(host, L["Text Color"] or "Text Color",
                R.colorGet("textColor", 1, 1, 1, 1), R.colorSet("textColor"))
            cpText:SetPoint("TOPLEFT", 15, y - 6)
            y = y - 42
        end

        return y
    end

    -------------------------------------------------------------------
    -- Resource
    -------------------------------------------------------------------
    local STYLE_ITEMS = {
        {value = "bars",     text = L["Bars"] or "Bars"},
        {value = "shape",    text = L["Shape"] or "Shape"},
        {value = "blizzard", text = L["Blizzard Art"] or "Blizzard Art"},
    }

    local FILL_ITEMS = {
        {value = "auto",       text = L["Automatic"] or "Automatic"},
        {value = "horizontal", text = L["Left to Right"] or "Left to Right"},
        {value = "vertical",   text = L["Bottom to Top"] or "Bottom to Top"},
    }

    -- The power bar's colour choices plus the two rainbows, which only make
    -- sense across a row of points.
    local POINT_COLOR_ITEMS = {
        COLOR_MODE_ITEMS[1], COLOR_MODE_ITEMS[2], COLOR_MODE_ITEMS[3],
        {value = "rainbow",         text = L["Rainbow"] or "Rainbow"},
        {value = "rainbowAnimated", text = L["Rainbow (Animated)"] or "Rainbow (Animated)"},
    }

    local WIDTH_SAME   = {value = "power",  text = L["Same as Power Bar"] or "Same as Power Bar"}
    local WIDTH_CUSTOM = {value = "custom", text = L["Custom"] or "Custom"}
    local WIDTH_MATCH  = {value = "match",  text = L["Match a Frame"] or "Match a Frame"}
    local WIDTH_FIT    = {value = "points", text = L["Fit to Points"] or "Fit to Points"}

    local function TabResource(host, y, ctx)
        local R, RB, CB, detached = ctx.R, ctx.RB, ctx.CB, ctx.detached

        W.CreateTitledPane(host, L["Resource Points"] or "Resource Points", y)
        y = y - 35

        local cbPoints = W.CreateStyledCheckbox(host, L["Show"] or "Show",
            R.bool("showPoints", true), R.setBoolRebuild("showPoints"))
        cbPoints:SetPoint("TOPLEFT", 15, y)
        y = y - 26

        -- Names the resource this character will actually get, so it is
        -- obvious when a class simply has none rather than looking like a
        -- broken setting.
        local resName = RB and RB.ResolveSecondary and select(1, RB.ResolveSecondary())
        if resName then
            y = Note(host, y, (L["ResourcePointsFound"] or "This specialization uses: %s"):format(resName))
        else
            y = Note(host, y, L["ResourcePointsNone"]
                or "This specialization has no secondary resource, so no points are drawn.")
        end

        if not R.Read("showPoints", true) then return y end

        -- How the points are drawn. See ResourceBar.lua's "POINT STYLES".
        local style = R.Read("pointStyle", "bars")

        local ddStyle = W.CreateStyledDropdown(host, 200, 40, L["Point Style"] or "Point Style",
            STYLE_ITEMS, R.get("pointStyle", "bars"),
            function(v) R.Write("pointStyle", v); Rebuild() end)
        ddStyle:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        if style == "shape" and RB and RB.SHAPES then
            local ddShape = W.CreateStyledDropdown(host, 200, 40, L["Shape"] or "Shape",
                RB.SHAPES, R.get("pointShape", "round"), R.set("pointShape"))
            ddShape:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 70
        elseif style == "blizzard" then
            y = Note(host, y, L["ResourceBlizzardArtNote"]
                or "Uses the game's own art for your class's resource. Automatic colour keeps the art's real colours; the other colour choices tint it. A resource with no art shows round points instead.")
        end

        local ddFill = W.CreateStyledDropdown(host, 200, 40, L["Fill Direction"] or "Fill Direction",
            FILL_ITEMS, R.get("pointFill", "auto"), R.set("pointFill"))
        ddFill:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        -- A shape or piece of art is sized by this one number (its width
        -- follows its proportions), hence "Size" and the larger range.
        local sPH = W.CreateStyledSlider(host, 200, 2, style == "bars" and 40 or 64, 1,
            style == "bars" and (L["Height"] or "Height") or (L["Size"] or "Size"),
            R.get("pointHeight", 8), R.set("pointHeight"))
        sPH:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local sSpace = W.CreateStyledSlider(host, 200, 0, 20, 1, L["Spacing"] or "Spacing",
            R.get("pointSpacing", 2), R.set("pointSpacing"))
        sSpace:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        -- Gap and Points Above Bar arrange the two rows INSIDE one bar, so
        -- they only exist while attached. Detached, the points' own side and
        -- offsets below do that job.
        if not detached then
            local sGap = W.CreateStyledSlider(host, 200, 0, 20, 1, L["Gap"] or "Gap",
                R.get("gap", 2), R.set("gap"))
            sGap:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 70

            local cbAbove = W.CreateStyledCheckbox(host, L["Points Above Bar"] or "Points Above Bar",
                R.bool("pointsAbove", true), R.setBool("pointsAbove"))
            cbAbove:SetPoint("TOPLEFT", 15, y)
            y = y - 30
        end

        -- The row's own placement and width live in pointsLayout.
        local P = ResourceGetters("pointsLayout")

        if detached and CB then
            W.CreateTitledPane(host, L["Position"] or "Position", y)
            y = y - 35

            -- "Attached to Power Bar" only while the bar is not riding the
            -- points -- the mirror of the Power tab's list.
            local pointItems = {POSITION_ITEMS[1], POSITION_ITEMS[2]}
            if ctx.barMode ~= "points" then
                table.insert(pointItems,
                    {value = "power", text = L["Attached to Power Bar"] or "Attached to Power Bar"})
            end

            y = PositionBlock(host, y, ctx, {
                getters = P, mode = ctx.pointsMode, items = pointItems, partnerMode = "power",
                defaultSide = "TOP", defaultOffsetY = 2,
                frame = function() return RB and RB.pointsFrame end,
                seedTable = function()
                    local c = GetConfig()
                    local rb = c and c.resourceBar
                    if not rb then return nil end
                    rb.pointsLayout = rb.pointsLayout or {}
                    return rb.pointsLayout
                end,
            })
        end

        -- Width. Detached, the same choices as the power bar plus "the power
        -- bar's"; attached the row lives inside the bar, so it is the bar's
        -- width, set on the Power tab. Shapes and art can also pack together
        -- instead of spreading across that width.
        W.CreateTitledPane(host, L["Width"] or "Width", y)
        y = y - 35

        local widthItems = detached and {WIDTH_SAME, WIDTH_CUSTOM, WIDTH_MATCH} or {WIDTH_SAME}
        if style ~= "bars" then table.insert(widthItems, WIDTH_FIT) end

        if not detached then
            y = Note(host, y, L["ResourcePointsWidthAttachedNote"]
                or "While attached, the points use the power bar's width - set it on the Power tab, including Match a Frame. Turn on Move Points Separately under General to give them a width of their own.")
        end

        local widthMode = "power"
        if #widthItems > 1 then
            widthMode, y = WidthBlock(host, y, ctx, P, widthItems, "power", 20)
        end

        if style ~= "bars" then
            if widthMode == "points" then
                y = Note(host, y, L["ResourcePointsFitNote"]
                    or "The points sit side by side, Spacing apart, at their full Size.")
            else
                y = Note(host, y, L["ResourcePointsSpreadNote"]
                    or "The points spread evenly across this width at their Size, first and last on the edges, so the row lines up with the bar or frame it matches. They only shrink if they cannot fit.")
            end
        end

        -- Colours
        W.CreateTitledPane(host, L["Color"] or "Color", y)
        y = y - 35

        local ddPColor = W.CreateStyledDropdown(host, 200, 40, L["Color"] or "Color",
            POINT_COLOR_ITEMS, R.get("pointColorMode", "auto"),
            function(v) R.Write("pointColorMode", v); Rebuild() end)
        ddPColor:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        local pointColorMode = R.Read("pointColorMode", "auto")
        if pointColorMode == "custom" then
            local cp = W.CreateColorPicker(host, L["Custom Color"] or "Custom Color",
                R.colorGet("pointColor", 1, 0.85, 0.3, 1), R.colorSet("pointColor"))
            cp:SetPoint("TOPLEFT", 15, y - 6)
            y = y - 36
        elseif pointColorMode == "rainbowAnimated" then
            local sSpeed = W.CreateStyledSlider(host, 200, 0.05, 2, 0.05,
                L["Rainbow Speed"] or "Rainbow Speed",
                R.get("rainbowSpeed", 0.25), R.set("rainbowSpeed"))
            sSpeed:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65
        end

        -- Blizzard art brings its own empty look (the unlit atlas).
        if style ~= "blizzard" then
            local cpEmpty = W.CreateColorPicker(host, L["Empty Color"] or "Empty Color",
                R.colorGet("pointEmptyColor", 0.22, 0.22, 0.22, 1),
                R.colorSet("pointEmptyColor"))
            cpEmpty:SetPoint("TOPLEFT", 15, y - 6)
            y = y - 42
        end

        -- Point border: an outline on each point. See ResourceBar.lua's
        -- StylePipBorder.
        local PB = ResourceGetters("pointBorder")

        W.CreateTitledPane(host, L["Point Border"] or "Point Border", y)
        y = y - 35

        if style == "blizzard" then
            return Note(host, y, L["ResourcePointBorderBlizzardNote"]
                or "Blizzard art draws its own edges, so it has no point border. Pick Bars or a Shape to outline each point.")
        end

        local cbPB = W.CreateStyledCheckbox(host, L["Show"] or "Show",
            PB.bool("enabled", false), PB.setBoolRebuild("enabled"))
        cbPB:SetPoint("TOPLEFT", 15, y)
        y = y - 26

        y = Note(host, y, L["ResourcePointBorderNote"]
            or "An outline around each point, following its shape and drawn just inside its edge, so the points keep their size. On shapes the thickness grows with Size.")

        if PB.Read("enabled", false) then
            local sPBThick = W.CreateStyledSlider(host, 200, 1, 4, 1,
                L["Thickness"] or "Thickness",
                PB.get("thickness", 2), PB.set("thickness"))
            sPBThick:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65

            local cpPB = W.CreateColorPicker(host, L["Color"] or "Color",
                PB.colorGet("color", 0, 0, 0, 1), PB.colorSet("color"))
            cpPB:SetPoint("TOPLEFT", 15, y - 6)
            y = y - 42
        end

        return y
    end

    -------------------------------------------------------------------

    SecResource = function(host, y, cfg, t)
        local R = ResourceGetters()

        W.CreateTitledPane(host, L["Resource Bar"] or "Resource Bar", y)
        y = y - 35

        local cbOn = W.CreateStyledCheckbox(host, L["Enable Resource Bar"] or "Enable Resource Bar",
            R.bool("enabled", false), R.setBoolRebuild("enabled"))
        cbOn:SetPoint("TOPLEFT", 15, y)
        y = y - 26

        y = Note(host, y, L["ResourceBarNote"]
            or "Your power bar plus your class's secondary resource - Holy Power, Combo Points, Chi, Soul Shards, Arcane Charges, Essence or Runes. Works whether or not the unit frames above are switched on. Drag it in Edit Mode.")

        if not R.Read("enabled", false) then return y end

        local RB = SquizzFrames.ResourceBar
        local ctx = {
            R = R, RB = RB, CB = SquizzFrames.UnitFrameCastBar,
            detached = R.Read("detachPoints", false) == true,
            -- The modes the layout will ACTUALLY use, with the both-attached-
            -- to-each-other loop already broken, so the page never shows a
            -- mode the bars are not in.
            barMode = "free", pointsMode = "power",
        }
        if RB and RB.EffectiveModes then
            local c = GetConfig()
            ctx.barMode, ctx.pointsMode = RB.EffectiveModes((c and c.resourceBar) or {})
        end

        y = SubTabs(host, y, RESOURCE_TABS, activeResourceTab, function(key)
            activeResourceTab = key
            Rebuild()
        end)

        if activeResourceTab == "power" then
            return TabPower(host, y, ctx)
        elseif activeResourceTab == "resource" then
            return TabResource(host, y, ctx)
        end
        return TabGeneral(host, y, ctx)
    end
end

-- Hover / target / aggro highlights. Isolated from the party/raid indicator
-- system on purpose -- see Highlights.lua's header. Every change goes through
-- Changed(), so the 1:1 preview updates live alongside the real frames.
local function SecHighlights(host, y, cfg, t)
    local HL = SquizzFrames.UnitFrameHighlights
    if not HL then return y end

    local function Read(key, field, fb)
        local c = HL.Get(t, key)
        local v = c and c[field]
        if v == nil then return fb end
        return v
    end
    local function Write(key, field, v)
        Set(function(c)
            c.highlights = c.highlights or {}
            c.highlights[key] = c.highlights[key] or {}
            c.highlights[key][field] = v
        end)
    end

    for _, def in ipairs(HL.KINDS) do
        W.CreateTitledPane(host, L[def.label] or def.label, y)
        y = y - 35

        local cbOn = W.CreateStyledCheckbox(host, L["Show"] or "Show",
            function() return Read(def.key, "enabled", false) == true end,
            function(v)
                Write(def.key, "enabled", v)
                if rebuildFields then rebuildFields() end
            end)
        cbOn:SetPoint("TOPLEFT", 15, y)
        y = y - 30

        if Read(def.key, "enabled", false) then
            local sThick = W.CreateStyledSlider(host, 200, 1, 8, 1,
                L["Thickness"] or "Thickness",
                function() return Read(def.key, "thickness", 2) end,
                function(v) Write(def.key, "thickness", v) end)
            sThick:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65

            local cp = W.CreateColorPicker(host, L["Color"] or "Color",
                function()
                    local c = Read(def.key, "color", nil)
                    if type(c) ~= "table" then
                        return def.default[1], def.default[2], def.default[3], def.default[4]
                    end
                    return c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1
                end,
                function(r, g, b, a) Write(def.key, "color", {r, g, b, a or 1}) end)
            cp:SetPoint("TOPLEFT", 15, y - 6)
            y = y - 42

            -- Pulse, aggro only -- matching the party/raid Aggro (border),
            -- which is the only one of the three that pulses there either. A
            -- hover or target highlight that throbbed would be noise.
            --
            -- blinkOptions is POSITIONAL ({speed, fadePercent, on}) because
            -- that is the shape BU.AttachBlinkBehaviour's SetBlinkOptions
            -- takes; these accessors read and write slots, not named keys.
            if def.key == "aggro" then
                local function Blink(i, fb)
                    local o = Read("aggro", "blinkOptions", nil)
                    local v = (type(o) == "table") and o[i] or nil
                    if v == nil then return fb end
                    return v
                end
                local function SetBlink(i, v)
                    Set(function(c)
                        c.highlights = c.highlights or {}
                        c.highlights.aggro = c.highlights.aggro or {}
                        local o = c.highlights.aggro.blinkOptions
                        if type(o) ~= "table" then o = {0.5, 25, false} end
                        o[i] = v
                        c.highlights.aggro.blinkOptions = o
                    end)
                end

                local cbPulse = W.CreateStyledCheckbox(host, L["Pulse"] or "Pulse",
                    function() return Blink(3, false) == true end,
                    function(v)
                        SetBlink(3, v)
                        if rebuildFields then rebuildFields() end
                    end)
                cbPulse:SetPoint("TOPLEFT", 15, y)
                y = y - 30

                if Blink(3, false) then
                    local sSpeed = W.CreateStyledSlider(host, 200, 0.1, 2, 0.05,
                        L["Pulse Speed"] or "Pulse Speed",
                        function() return Blink(1, 0.5) end,
                        function(v) SetBlink(1, v) end)
                    sSpeed:SetPoint("TOPLEFT", 15, y - 20)
                    y = y - 65

                    local sFaint = W.CreateStyledSlider(host, 200, 0, 90, 5,
                        L["Fade To %"] or "Fade To %",
                        function() return Blink(2, 25) end,
                        function(v) SetBlink(2, v) end)
                    sFaint:SetPoint("TOPLEFT", 15, y - 20)
                    y = y - 70
                end
            end
        end
    end

    local note = host:CreateFontString(nil, "OVERLAY")
    note:SetFontObject("GameFontDisableSmall")
    note:SetPoint("TOPLEFT", 15, y)
    note:SetPoint("RIGHT", host, "RIGHT", -20, 0)
    note:SetJustifyH("LEFT")
    note:SetText(L["UnitHighlightsNote"]
        or "Target Highlight shows which frame your current target is on - useful on boss, focus and target-of-target, and always lit on the target frame itself. These are separate from the party and raid indicators so each can be set independently.")
    y = y - 46

    return y
end

-- Dispel overlay + icon. The settings live under t.dispels with OUR key names;
-- Dispels.lua translates them for the party indicator it reuses.
local function SecDispels(host, y, cfg, t)
    local DP = SquizzFrames.UnitFrameDispels
    if not DP then return y end

    local function Read(field, fb)
        local c = t and t.dispels
        local v = c and c[field]
        if v == nil then return fb end
        return v
    end
    local function Write(field, v)
        Set(function(c)
            c.dispels = c.dispels or {}
            c.dispels[field] = v
        end)
    end

    W.CreateTitledPane(host, L["Dispels"] or "Dispels", y)
    y = y - 35

    local cbOn = W.CreateStyledCheckbox(host, L["Show"] or "Show",
        function() return Read("enabled", false) == true end,
        function(v) Write("enabled", v); if rebuildFields then rebuildFields() end end)
    cbOn:SetPoint("TOPLEFT", 15, y)
    y = y - 26

    local note = host:CreateFontString(nil, "OVERLAY")
    note:SetFontObject("GameFontDisableSmall")
    note:SetPoint("TOPLEFT", 32, y)
    note:SetPoint("RIGHT", host, "RIGHT", -20, 0)
    note:SetJustifyH("LEFT")
    note:SetText(L["UnitDispelsNote"]
        or "Tints the health bar by the type of dispellable debuff on the unit, and can show a matching icon. Built on the same aura engine the party frames use, so it keeps working through a whole encounter.")
    y = y - 46

    if not Read("enabled", false) then return y end

    local ddMode = W.CreateStyledDropdown(host, 200, 40, L["Overlay"] or "Overlay",
        DP.OVERLAY_MODES, function() return Read("overlay", "full") end,
        function(v) Write("overlay", v); if rebuildFields then rebuildFields() end end)
    ddMode:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    local mode = Read("overlay", "full")
    if mode ~= "none" then
        local sOp = W.CreateStyledSlider(host, 200, 0.05, 1, 0.05,
            L["Opacity"] or "Opacity",
            function() return Read("opacity", 0.5) end,
            function(v) Write("opacity", v) end)
        sOp:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70
    end

    -- Gradient shape. Only the two ramp modes read these, so they're only
    -- offered there -- unlike the party page, which always shows them.
    if mode == "gradient" or mode == "gradientTop" then
        -- Floor of 5 rather than 0: a 0% ramp is an invisible overlay, which
        -- "None" already says more clearly.
        local sH = W.CreateStyledSlider(host, 200, 5, 100, 1,
            L["Gradient Height"] or "Gradient Height",
            function() return Read("gradientHeight", 100) end,
            function(v) Write("gradientHeight", v) end)
        sH:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        -- The faint end, as a percentage OF the opacity above, so the two
        -- can never invert. 0 = fades right out, 100 = flat tint, no ramp.
        local sW = W.CreateStyledSlider(host, 200, 0, 100, 1,
            L["Gradient Fade"] or "Gradient Fade",
            function() return Read("gradientWeakAlpha", 50) end,
            function(v) Write("gradientWeakAlpha", v) end)
        sW:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70
    end

    local cbAll = W.CreateStyledCheckbox(host,
        L["Show All Types"] or "Show All Types",
        function() return Read("showAll", false) == true end,
        function(v) Write("showAll", v) end)
    cbAll:SetPoint("TOPLEFT", 15, y)
    y = y - 26

    local allNote = host:CreateFontString(nil, "OVERLAY")
    allNote:SetFontObject("GameFontDisableSmall")
    allNote:SetPoint("TOPLEFT", 32, y)
    allNote:SetPoint("RIGHT", host, "RIGHT", -20, 0)
    allNote:SetJustifyH("LEFT")
    allNote:SetText(L["UnitDispelsAllNote"]
        or "Off shows only what YOU can dispel. On shows every dispellable type - useful if you are watching a tank rather than healing.")
    y = y - 40

    local cbIcons = W.CreateStyledCheckbox(host,
        L["Show Dispel Icon"] or "Show Dispel Icon",
        function() return Read("showIcons", false) == true end,
        function(v) Write("showIcons", v); if rebuildFields then rebuildFields() end end)
    cbIcons:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    if Read("showIcons", false) then
        local sSize = W.CreateStyledSlider(host, 200, 8, 40, 1, L["Icon Size"] or "Icon Size",
            function() return Read("iconSize", 16) end,
            function(v) Write("iconSize", v) end)
        sSize:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local sX = W.CreateStyledSlider(host, 200, -100, 100, 1, L["Offset X"] or "Offset X",
            function() return Read("iconX", 0) end,
            function(v) Write("iconX", v) end)
        sX:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local sY = W.CreateStyledSlider(host, 200, -100, 100, 1, L["Offset Y"] or "Offset Y",
            function() return Read("iconY", 0) end,
            function(v) Write("iconY", v) end)
        sY:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        -- The same three the party's Dispel Icons indicator offers. All three
        -- default OFF: these are Blizzard's dispel-type atlases, already
        -- shaped artwork on transparency, which the usual icon furniture
        -- fights.
        local cbSpell = W.CreateStyledCheckbox(host,
            L["Use Debuff Icon"] or "Use Debuff Icon",
            function() return Read("useSpellIcons", false) == true end,
            function(v) Write("useSpellIcons", v) end)
        cbSpell:SetPoint("TOPLEFT", 15, y)
        y = y - 26

        local cbSwipe = W.CreateStyledCheckbox(host,
            L["Show Cooldown Swipe"] or "Show Cooldown Swipe",
            function() return Read("showSwipe", false) == true end,
            function(v) Write("showSwipe", v) end)
        cbSwipe:SetPoint("TOPLEFT", 15, y)
        y = y - 26

        local cbBorder = W.CreateStyledCheckbox(host,
            L["Show Icon Border"] or "Show Icon Border",
            function() return Read("showIconBorder", false) == true end,
            function(v) Write("showIconBorder", v) end)
        cbBorder:SetPoint("TOPLEFT", 15, y)
        y = y - 32
    end

    -- Per-type enable + colour. Written only when changed, so an untouched
    -- profile carries no copy of the game's palette to go stale.
    W.CreateTitledPane(host, L["Dispel Types"] or "Dispel Types", y)
    y = y - 35

    for _, ty in ipairs(DP.TYPES) do
        local cb = W.CreateStyledCheckbox(host, L[ty.label] or ty.label,
            function()
                local m = Read("typesEnabled", nil)
                return (type(m) ~= "table") or (m[ty.key] ~= false)
            end,
            function(v)
                Set(function(c)
                    c.dispels = c.dispels or {}
                    c.dispels.typesEnabled = c.dispels.typesEnabled or {}
                    c.dispels.typesEnabled[ty.key] = v
                end)
            end)
        cb:SetPoint("TOPLEFT", 15, y)

        local cp = W.CreateColorPicker(host, "",
            function()
                local m = Read("colors", nil)
                local c = (type(m) == "table") and m[ty.key] or nil
                if type(c) ~= "table" then
                    return ty.default[1], ty.default[2], ty.default[3], 1
                end
                return c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1
            end,
            function(r, g, b, a)
                Set(function(c)
                    c.dispels = c.dispels or {}
                    c.dispels.colors = c.dispels.colors or {}
                    c.dispels.colors[ty.key] = {r, g, b, a or 1}
                end)
            end)
        cp:SetPoint("TOPLEFT", 175, y)
        y = y - 30
    end

    return y - 10
end

-- INDICATORS: one section, sub-tabs inside it.
--
-- Auras, Icons, Highlights, Absorbs and Dispels were five separate entries in
-- the left sidebar, which buried the per-frame settings people actually reach
-- for under a list that kept growing. They are now one "Indicators" section
-- with a tab strip across the top, the same shape the party/raid Indicators
-- page uses -- pick the indicator, then configure it.
--
-- The individual Sec* builders are UNCHANGED; this only decides which one runs
-- and draws the strip. That is deliberate: each remains independently
-- testable, and moving one back out is deleting an entry here.
local INDICATOR_TABS = {
    {key = "auras",      label = L["Auras"] or "Auras",           build = SecAuras},
    {key = "dispels",    label = L["Dispels"] or "Dispels",       build = SecDispels},
    {key = "absorbs",    label = L["Absorbs"] or "Absorbs",       build = SecAbsorbs},
    {key = "highlights", label = L["Highlights"] or "Highlights", build = SecHighlights},
    {key = "icons",      label = L["Icons"] or "Icons",           build = SecIcons},
}

-- Persists across page switches within a session, like activeUnit and
-- activeSection -- you are usually adjusting one indicator over several visits.
local activeIndicatorTab = "auras"

local function SecIndicators(host, y, cfg, t)
    y = SubTabs(host, y, INDICATOR_TABS, activeIndicatorTab, function(key)
        activeIndicatorTab = key
        if rebuildFields then rebuildFields() end
    end)

    for _, tab in ipairs(INDICATOR_TABS) do
        if tab.key == activeIndicatorTab and tab.build then
            return tab.build(host, y, cfg, t)
        end
    end
    return y
end

-----------------------------------------------------------------------
-- Section registry + dispatch
-----------------------------------------------------------------------

-- Declared AFTER every Sec* function: as a table of references it captures
-- them by value at construction, so a forward declaration would store nils.
local SECTIONS = {
    {key = "general",  label = L["General"] or "General",   build = SecGeneral},
    {key = "frame",    label = L["Frame"] or "Frame",       build = SecFrame},
    {key = "sizing",   label = L["Sizing"] or "Sizing",     build = SecSizing},
    {key = "colors",   label = L["Colors"] or "Colors",     build = SecColors},
    {key = "text",     label = L["Text"] or "Text",         build = SecText},
    {key = "portrait", label = L["Portrait"] or "Portrait", build = SecPortrait},
    {key = "castbar",  label = L["Cast Bar"] or "Cast Bar", build = SecCastBar},
    -- Auras, Dispels, Absorbs, Highlights and Icons are now SUB-TABS inside
    -- this one entry rather than five sidebar rows -- see SecIndicators.
    {key = "indicators", label = L["Indicators"] or "Indicators", build = SecIndicators},
    -- Module-wide, not per-unit: it is always the player's own resources. It
    -- reads the same settings whichever unit tab happens to be selected.
    {key = "resource", label = L["Resources"] or "Resources", build = SecResource},
    {key = "position", label = L["Position"] or "Position", build = SecPosition},
}

local function BuildFields(frame)
    if frame.fieldsHost then
        frame.fieldsHost:Hide()
        frame.fieldsHost:SetParent(nil)
        frame.fieldsHost = nil
    end

    local host = CreateFrame("Frame", nil, frame)
    -- Clears BOTH pinned strips Panel.Build floats above the scroll area: the
    -- unit-tab header along the top and the section-tab sidebar down the left.
    -- No vertical inset any more: the ScrollFrame's own top now sits below the
    -- header (see ApplyScrollInset in Panel.Build), so the content area
    -- already starts in the right place. Only the two side strips, which are
    -- overlays rather than scroll-region changes, still need clearing.
    host:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDEBAR_WIDTH, 0)
    host:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PREVIEW_WIDTH, 0)
    frame.fieldsHost = host

    local cfg = GetConfig()
    if not cfg then return end

    -- Every section except General needs a unit table, and General is also the
    -- only one that means anything while the module is switched off.
    local t = GetUnitConfig()
    if activeSection ~= "general" and (not cfg.enabled or not t) then
        activeSection = "general"
    end

    for _, sec in ipairs(SECTIONS) do
        if sec.key == activeSection then
            sec.build(host, -10, cfg, t)
            break
        end
    end

    -- Also refreshed here, not only from Changed(), so switching unit or
    -- section tabs re-points the preview at the newly selected frame -- those
    -- do not go through a setter. Hence `break` above rather than `return`.
    RefreshPreview()
end

-----------------------------------------------------------------------
-- Page
-----------------------------------------------------------------------

function Panel.Build(frame)
    local unitButtons, sectionButtons = {}, {}

    local function RefreshTabVisual()
        local accent = F.GetAccentColor()
        for key, btn in pairs(unitButtons) do
            if key == activeUnit then
                btn:SetBackdropColor(accent.r, accent.g, accent.b, 0.55)
            else
                btn:SetBackdropColor(0.115, 0.115, 0.115, 1)
            end
        end
        for key, btn in pairs(sectionButtons) do
            if key == activeSection then
                btn:SetBackdropColor(accent.r, accent.g, accent.b, 0.45)
            else
                btn:SetBackdropColor(0.09, 0.09, 0.09, 0)
            end
        end
    end

    -- PINNED HEADER.
    --
    -- Parented up the chain to the scroll frame's own parent rather than to
    -- the page, so it does NOT scroll: the page frame lives inside
    -- scrollChild, and anything parented there scrolls away with the content.
    -- Walking the chain (page -> scrollChild -> scrollFrame -> contentArea)
    -- avoids OptionsFrame having to export another local.
    --
    -- Falls back to the page itself if the chain is not what we expect, which
    -- degrades to the old scrolling behaviour rather than erroring.
    local scrollChild = frame:GetParent()
    local scroll = scrollChild and scrollChild:GetParent()
    local contentArea = scroll and scroll:GetParent()

    scrollHost = scroll

    local header, sidebar
    if contentArea and scroll then
        -- Opaque and WELL above the scrolling content: rows sliding underneath
        -- have to be hidden, which is the whole point of pinned furniture.
        --
        -- +50, not +10. The content is a sibling subtree several frames deep
        -- (scrollChild -> page -> fieldsHost -> widget -> widget's own
        -- children), and the styled widgets bump their own levels on top of
        -- that, so a +10 gap was not enough: sliders scrolled up and drew
        -- straight over the tab row.
        local level = (contentArea:GetFrameLevel() or 1) + 50

        -- THE SCROLL REGION IS SHRUNK, not merely covered.
        --
        -- Overlaying an opaque header hid the content but did not stop it
        -- travelling there: rows still scrolled up behind the tabs, so the
        -- scrollbar's range included a band you could never read. Moving the
        -- ScrollFrame's own top edge down means the content simply has
        -- nowhere to go.
        --
        -- The ScrollFrame is SHARED with every other options page, so its
        -- original anchors are captured and restored on hide rather than the
        -- numbers being hardcoded here -- OptionsFrame owns them and is free
        -- to change them.
        local originalPoints = {}
        for i = 1, scroll:GetNumPoints() do
            originalPoints[i] = { scroll:GetPoint(i) }
        end
        local function ApplyScrollInset(inset)
            scroll:ClearAllPoints()
            for _, pt in ipairs(originalPoints) do
                local point, rel, relPoint, px, py = unpack(pt)
                -- Only the TOP anchors move; the bottom stays where it is.
                if point == "TOPLEFT" or point == "TOPRIGHT" or point == "TOP" then
                    py = (py or 0) - inset
                end
                scroll:SetPoint(point, rel, relPoint, px, py)
            end
        end

        -- Anchored to contentArea, NOT to scroll: scroll is about to move down
        -- by exactly the header's height, and a header anchored to it would
        -- follow it and leave the gap it was meant to fill.
        header = CreateFrame("Frame", nil, contentArea, "BackdropTemplate")
        local firstPoint = originalPoints[1]
        local hx = (firstPoint and firstPoint[4]) or 0
        local hy = (firstPoint and firstPoint[5]) or 0
        header:SetPoint("TOPLEFT", contentArea, "TOPLEFT", hx, hy)
        header:SetPoint("TOPRIGHT", contentArea, "TOPRIGHT", -16, hy)
        header:SetHeight(HEADER_HEIGHT)
        header:SetFrameLevel(level)
        W.StylizeFrame(header, {0.06, 0.06, 0.06, 1}, {0, 0, 0, 0})

        sidebar = CreateFrame("Frame", nil, contentArea, "BackdropTemplate")
        -- Follows scroll's top like the preview pane does, rather than the
        -- header's bottom: the two are the same edge now that the scroll
        -- region has been shortened, and anchoring to scroll keeps the two
        -- side strips consistent.
        sidebar:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
        sidebar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMLEFT", 0, 0)
        sidebar:SetWidth(SIDEBAR_WIDTH)
        sidebar:SetFrameLevel(level)
        W.StylizeFrame(sidebar, {0.06, 0.06, 0.06, 1}, {0, 0, 0, 0})

        -- Preview strip down the right, pinned like the other two so it stays
        -- in view while the settings beside it scroll.
        -- No -HEADER_HEIGHT offset: scroll's own top is already below the
        -- header now, so the pane simply follows it.
        local previewPane = CreateFrame("Frame", nil, contentArea, "BackdropTemplate")
        previewPane:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, 0)
        previewPane:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 0, 0)
        previewPane:SetWidth(PREVIEW_WIDTH)
        previewPane:SetFrameLevel(level)
        W.StylizeFrame(previewPane, {0.06, 0.06, 0.06, 1}, {0, 0, 0, 0})

        local caption = previewPane:CreateFontString(nil, "OVERLAY")
        caption:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        caption:SetPoint("TOP", previewPane, "TOP", 0, -8)
        caption:SetTextColor(0.7, 0.7, 0.7, 1)
        caption:SetText(L["Preview (actual size)"] or "Preview (actual size)")

        local P = SquizzFrames.UnitFramePreview
        if P and P.Create then
            local mock = P.Create(previewPane)
            -- Anchored well below the caption rather than centred: a cast bar
            -- hangs off the bottom and an aura row off the top, and a centred
            -- mock would push them out of the pane at larger sizes.
            mock:SetPoint("TOP", previewPane, "TOP", 0, -70)
            frame.previewFrame = mock
            previewMock = mock
        end

        -- Tied to the page's visibility -- none of the three is one of
        -- OptionsFrame's contentFrames, so ShowPage does not know about them
        -- and they would otherwise sit on top of whatever page you switched to.
        local function ShowFurniture(show)
            header:SetShown(show)
            sidebar:SetShown(show)
            previewPane:SetShown(show)
            -- Restored on hide: the ScrollFrame belongs to every page, and
            -- leaving it short would put a dead band at the top of Layout,
            -- Indicators and everything else.
            ApplyScrollInset(show and HEADER_HEIGHT or 0)
        end
        ShowFurniture(false)
        frame:HookScript("OnShow", function() ShowFurniture(true) end)
        frame:HookScript("OnHide", function() ShowFurniture(false) end)
        if frame:IsShown() then ShowFurniture(true) end
    else
        header, sidebar = frame, frame
    end

    -- Row 1: which unit. 72px + 3px gap fits six across without wrapping.
    local x = 15
    for _, tab in ipairs(UNIT_TABS) do
        local btn = CreateFrame("Button", nil, header, "BackdropTemplate")
        btn:SetSize(72, 22)
        btn:SetPoint("TOPLEFT", header, "TOPLEFT", x, -6)
        W.StylizeFrame(btn, {0.115, 0.115, 0.115, 1}, {0, 0, 0, 0})
        local text = btn:CreateFontString(nil, "OVERLAY")
        text:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        text:SetPoint("CENTER")
        text:SetText(tab.label)
        btn:SetScript("OnClick", function()
            if activeUnit == tab.key then return end
            activeUnit = tab.key
            RefreshTabVisual()
            if rebuildFields then rebuildFields() end
            ScrollToTop()
        end)
        unitButtons[tab.key] = btn
        x = x + 75
    end

    -- Left sidebar: which section of the selected unit's settings. Stacked
    -- vertically and left-aligned, mirroring the options window's own main
    -- navigation, so the hierarchy reads unit (across the top) then section
    -- (down the side).
    local sy = -8
    for _, sec in ipairs(SECTIONS) do
        local btn = CreateFrame("Button", nil, sidebar, "BackdropTemplate")
        btn:SetSize(SIDEBAR_WIDTH - 12, 22)
        btn:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 6, sy)
        W.StylizeFrame(btn, {0.09, 0.09, 0.09, 1}, {0, 0, 0, 0})
        local text = btn:CreateFontString(nil, "OVERLAY")
        text:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        text:SetPoint("LEFT", btn, "LEFT", 8, 0)
        text:SetJustifyH("LEFT")
        text:SetText(sec.label)
        btn:SetScript("OnClick", function()
            if activeSection == sec.key then return end
            activeSection = sec.key
            RefreshTabVisual()
            if rebuildFields then rebuildFields() end
            ScrollToTop()
        end)
        sectionButtons[sec.key] = btn
        sy = sy - 25
    end

    RefreshTabVisual()

    rebuildFields = function()
        BuildFields(frame)
        RefreshTabVisual()
    end
    rebuildFields()

    -- Own message owner: CallbackHandler keeps one handler per (owner,
    -- message), so registering ProfileChanged on the shared root here would
    -- silently replace somebody else's.
    F.NewMessageOwner():RegisterMessage("ProfileChanged", function()
        rebuildFields()
    end)
end

-- Called by OptionsFrame.lua's resize-grip handler once the window has
-- actually settled at its new size (not during the drag itself -- the grip
-- only resizes scrollChild, and therefore this page, on mouse-up). Re-running
-- BuildFields re-measures the indicator tab strip's width and rewraps it,
-- same as any other section rebuild; a no-op before Panel.Build has run.
function Panel.Rebuild()
    if rebuildFields then rebuildFields() end
end
