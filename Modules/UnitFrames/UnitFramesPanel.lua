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

    -- Player frame only. A nickname is something you set for YOURSELF or for
    -- people in your group, and the group case is already served by the party
    -- frames -- offering it on target/focus/boss would be a control that
    -- almost never has anything to resolve. The setting still exists on every
    -- frame's table (see UnitFrames_Defaults.lua) and FormatToken still reads
    -- it; only the control is scoped.
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
            function(v) CastSet(function(c) c.showName = v end) end)
        cbName2:SetPoint("TOPLEFT", 15, y)
        y = y - 28

        local cbTime = W.CreateStyledCheckbox(host, L["Show Cast Time"] or "Show Cast Time",
            function() return cb.showTime ~= false end,
            function(v) CastSet(function(c) c.showTime = v end) end)
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
            function() return a.durationPoint or "TOP" end,
            function(v) AuraSet(function(c) c.durationPoint = v end) end)
        ddDP:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        -- The icon-side point. Pairing TOP with BOTTOM puts the text just
        -- below the icon (the default); pairing a point with itself puts it
        -- on the icon.
        local ddDRP = W.CreateStyledDropdown(host, 200, 40,
            L["Duration Anchor To"] or "Duration Anchor To", ANCHOR_POINT_ITEMS,
            function() return a.durationRelPoint or "BOTTOM" end,
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
            function() return a.durationY or -2 end,
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

local function SecResource(host, y, cfg, t)
    local R = ResourceGetters()

    W.CreateTitledPane(host, L["Resource Bar"] or "Resource Bar", y)
    y = y - 35

    local cbOn = W.CreateStyledCheckbox(host, L["Enable Resource Bar"] or "Enable Resource Bar",
        R.bool("enabled", false), R.setBoolRebuild("enabled"))
    cbOn:SetPoint("TOPLEFT", 15, y)
    y = y - 26

    local note = host:CreateFontString(nil, "OVERLAY")
    note:SetFontObject("GameFontDisableSmall")
    note:SetPoint("TOPLEFT", 32, y)
    note:SetPoint("RIGHT", host, "RIGHT", -20, 0)
    note:SetJustifyH("LEFT")
    note:SetText(L["ResourceBarNote"]
        or "Your power bar plus your class's secondary resource - Holy Power, Combo Points, Chi, Soul Shards, Arcane Charges, Essence or Runes. Works whether or not the unit frames above are switched on. Drag it in Edit Mode.")
    y = y - 46

    if not R.Read("enabled", false) then return y end

    -- Position. Shares the cast bar's curated frame list and side vocabulary
    -- so "anchor to the Essential Cooldowns row" means the same thing and
    -- reads the same way in both places.
    local CB = SquizzFrames.UnitFrameCastBar
    local POSITION_ITEMS = {
        {value = "free",   text = L["Free (drag it)"] or "Free (drag it)"},
        {value = "anchor", text = L["Anchored to a Frame"] or "Anchored to a Frame"},
    }

    local ddPos = W.CreateStyledDropdown(host, 200, 40, L["Position"] or "Position",
        POSITION_ITEMS, R.get("positionMode", "free"),
        function(v) R.Write("positionMode", v); if rebuildFields then rebuildFields() end end)
    ddPos:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    if R.Read("positionMode", "free") == "anchor" and CB then
        local ddTo = W.CreateStyledDropdown(host, 200, 40, L["Attach To"] or "Attach To",
            CB.MATCH_TARGETS, R.get("attachTo", "EssentialCooldownViewer"),
            R.set("attachTo"))
        ddTo:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        local ddSide = W.CreateStyledDropdown(host, 200, 40, L["Side"] or "Side",
            CB.ATTACH_SIDES, R.get("attachSide", "BOTTOM"), R.set("attachSide"))
        ddSide:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        local sOX = W.CreateStyledSlider(host, 200, -300, 300, 1, L["Offset X"] or "Offset X",
            R.get("offsetX", 0), R.set("offsetX"))
        sOX:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local sOY = W.CreateStyledSlider(host, 200, -300, 300, 1, L["Offset Y"] or "Offset Y",
            R.get("offsetY", 0), R.set("offsetY"))
        sOY:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70
    end

    -- Width
    local WIDTH_ITEMS = {
        {value = "custom", text = L["Custom"] or "Custom"},
        {value = "match",  text = L["Match a Frame"] or "Match a Frame"},
    }

    local ddWidth = W.CreateStyledDropdown(host, 200, 40, L["Width"] or "Width",
        WIDTH_ITEMS, R.get("widthMode", "custom"),
        function(v) R.Write("widthMode", v); if rebuildFields then rebuildFields() end end)
    ddWidth:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    if R.Read("widthMode", "custom") == "match" and CB then
        local ddMatch = W.CreateStyledDropdown(host, 200, 40, L["Match Width Of"] or "Match Width Of",
            CB.MATCH_TARGETS, R.get("matchFrame", "EssentialCooldownViewer"),
            R.set("matchFrame"))
        ddMatch:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70
    else
        local sWidth = W.CreateStyledSlider(host, 200, 60, 600, 1, L["Width"] or "Width",
            R.get("width", 220), R.set("width"))
        sWidth:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65
    end

    local sScale = W.CreateStyledSlider(host, 200, 0.5, 2, 0.05, L["Scale"] or "Scale",
        R.get("scale", 1), R.set("scale"))
    sScale:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    -- Power bar
    W.CreateTitledPane(host, L["Power Bar"] or "Power Bar", y)
    y = y - 35

    local cbPower = W.CreateStyledCheckbox(host, L["Show"] or "Show",
        R.bool("showPower", true), R.setBoolRebuild("showPower"))
    cbPower:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    if R.Read("showPower", true) then
        local sH = W.CreateStyledSlider(host, 200, 2, 60, 1, L["Height"] or "Height",
            R.get("powerHeight", 16), R.set("powerHeight"))
        sH:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        local ddColor = W.CreateStyledDropdown(host, 200, 40, L["Color"] or "Color",
            COLOR_MODE_ITEMS, R.get("powerColorMode", "auto"),
            function(v) R.Write("powerColorMode", v); if rebuildFields then rebuildFields() end end)
        ddColor:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        if R.Read("powerColorMode", "auto") == "custom" then
            local cp = W.CreateColorPicker(host, L["Custom Color"] or "Custom Color",
                R.colorGet("powerColor", 0.2, 0.4, 0.8, 1), R.colorSet("powerColor"))
            cp:SetPoint("TOPLEFT", 15, y - 6)
            y = y - 36
        end

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
    end

    -- Point row
    W.CreateTitledPane(host, L["Resource Points"] or "Resource Points", y)
    y = y - 35

    local cbPoints = W.CreateStyledCheckbox(host, L["Show"] or "Show",
        R.bool("showPoints", true), R.setBoolRebuild("showPoints"))
    cbPoints:SetPoint("TOPLEFT", 15, y)
    y = y - 26

    -- Names the resource this character will actually get, so it is obvious
    -- when a class simply has none rather than looking like a broken setting.
    local RB = SquizzFrames.ResourceBar
    local resName = RB and RB.ResolveSecondary and select(1, RB.ResolveSecondary())
    local pointNote = host:CreateFontString(nil, "OVERLAY")
    pointNote:SetFontObject("GameFontDisableSmall")
    pointNote:SetPoint("TOPLEFT", 32, y)
    pointNote:SetPoint("RIGHT", host, "RIGHT", -20, 0)
    pointNote:SetJustifyH("LEFT")
    if resName then
        pointNote:SetText((L["ResourcePointsFound"] or "This specialization uses: %s")
            :format(resName))
    else
        pointNote:SetText(L["ResourcePointsNone"]
            or "This specialization has no secondary resource, so no points are drawn.")
    end
    y = y - 34

    if R.Read("showPoints", true) then
        local sPH = W.CreateStyledSlider(host, 200, 2, 40, 1, L["Height"] or "Height",
            R.get("pointHeight", 8), R.set("pointHeight"))
        sPH:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local sSpace = W.CreateStyledSlider(host, 200, 0, 20, 1, L["Spacing"] or "Spacing",
            R.get("pointSpacing", 2), R.set("pointSpacing"))
        sSpace:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local sGap = W.CreateStyledSlider(host, 200, 0, 20, 1, L["Gap"] or "Gap",
            R.get("gap", 2), R.set("gap"))
        sGap:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        local cbAbove = W.CreateStyledCheckbox(host, L["Points Above Bar"] or "Points Above Bar",
            R.bool("pointsAbove", true), R.setBool("pointsAbove"))
        cbAbove:SetPoint("TOPLEFT", 15, y)
        y = y - 30

        local ddPColor = W.CreateStyledDropdown(host, 200, 40, L["Color"] or "Color",
            COLOR_MODE_ITEMS, R.get("pointColorMode", "auto"),
            function(v) R.Write("pointColorMode", v); if rebuildFields then rebuildFields() end end)
        ddPColor:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        if R.Read("pointColorMode", "auto") == "custom" then
            local cp = W.CreateColorPicker(host, L["Custom Color"] or "Custom Color",
                R.colorGet("pointColor", 1, 0.85, 0.3, 1), R.colorSet("pointColor"))
            cp:SetPoint("TOPLEFT", 15, y - 6)
            y = y - 36
        end

        local cpEmpty = W.CreateColorPicker(host, L["Empty Color"] or "Empty Color",
            R.colorGet("pointEmptyColor", 0.15, 0.15, 0.15, 0.8),
            R.colorSet("pointEmptyColor"))
        cpEmpty:SetPoint("TOPLEFT", 15, y - 6)
        y = y - 42
    end

    -- Border
    local B = ResourceGetters("border")

    W.CreateTitledPane(host, L["Border"] or "Border", y)
    y = y - 35

    local cbBorder = W.CreateStyledCheckbox(host, L["Show"] or "Show",
        B.bool("enabled", false), B.setBoolRebuild("enabled"))
    cbBorder:SetPoint("TOPLEFT", 15, y)
    y = y - 26

    local borderNote = host:CreateFontString(nil, "OVERLAY")
    borderNote:SetFontObject("GameFontDisableSmall")
    borderNote:SetPoint("TOPLEFT", 32, y)
    borderNote:SetPoint("RIGHT", host, "RIGHT", -20, 0)
    borderNote:SetJustifyH("LEFT")
    borderNote:SetText(L["ResourceBorderNote"]
        or "Outlines the whole bar, both rows together. Set the row Gap to 0 if you want it tight around them.")
    y = y - 34

    if B.Read("enabled", false) then
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
    {key = "auras",    label = L["Auras"] or "Auras",       build = SecAuras},
    {key = "icons",    label = L["Icons"] or "Icons",       build = SecIcons},
    {key = "absorbs",  label = L["Absorbs"] or "Absorbs",   build = SecAbsorbs},
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
