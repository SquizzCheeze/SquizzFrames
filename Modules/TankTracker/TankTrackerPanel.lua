--[[ SquizzFrames Tank Tracker options page

    A pure shell over profile.tankTracker -- every control reads and writes
    that tree and then fires "TankTrackerChanged", which TankTracker.lua turns
    into an ApplyLayout. Nothing here touches the live frames directly, the
    same discipline NicknamesPanel and UnitFramesPanel follow.

    Layout, modelled on the Unit Frames page:
      * a pinned tab strip across the top -- General / Debuffs / Defensives
      * the selected tab's settings in a fixed-width column on the left
      * a pinned 1:1 preview (TankTrackerPreview.lua) filling the rest, which
        stays in view while the column scrolls
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local L = SquizzFrames.L
local F = SquizzFrames.F
local W = SquizzFrames.Widgets

local Panel = {}
SquizzFrames.TankTrackerPanel = Panel

-- Width of the settings column. Everything right of it belongs to the
-- preview. Widgets are 200 wide at x=15 (plus their own 20px container), so
-- this leaves a small gutter and lets the preview take whatever the window's
-- current width allows.
local FIELDS_WIDTH = 270
local HEADER_HEIGHT = 34

local TABS = {
    {key = "general",    label = L["General"] or "General"},
    {key = "debuffs",    label = L["Debuffs"] or "Debuffs"},
    {key = "defensives", label = L["Defensives"] or "Defensives"},
}
local activeTab = "general"

local rebuildFields
local previewMock, previewHint
-- False when the scroll-frame chain was not what we expected and the tab
-- strip had to be built on the page itself, where it scrolls and the fields
-- must start below it.
local headerPinned = false

local function Cfg()
    local p = SquizzFrames.db and SquizzFrames.db.profile
    if not p then return nil end
    p.tankTracker = p.tankTracker or {}
    return p.tankTracker
end

-- Re-dress the preview for the current settings. Called from Changed(), NOT
-- only from BuildFields: a plain slider or colour picker does not rebuild the
-- page, and a preview hung off the rebuild would lag every one of them -- the
-- mistake UnitFramesPanel documents having made once.
local function RefreshPreview()
    local P = SquizzFrames.TankTrackerPreview
    if not (P and previewMock) then return end
    local c = Cfg()
    if c and c.enabled then
        P.Refresh(previewMock, c)
        if previewHint then previewHint:Hide() end
    else
        previewMock:Hide()
        if previewHint then previewHint:Show() end
    end
end

local function Changed()
    SquizzFrames:Fire("TankTrackerChanged")
    RefreshPreview()
end

-- Through OptionsFrame's helper, which moves the scrollbar as well as the
-- frame -- see UnitFramesPanel's ScrollToTop for the snap-back it avoids.
local function ScrollToTop()
    if SquizzFrames.OptionsScrollToTop then SquizzFrames.OptionsScrollToTop() end
end

-- Generic accessor pair over a settings table, optionally a nested one
-- ("debuffs"/"defensives"). One generator rather than three hand-written sets:
-- the two icon rows have identical shapes and writing them twice is how they
-- drift apart.
local function Acc(sub)
    local function Table()
        local c = Cfg()
        if not c then return nil end
        if sub then
            c[sub] = c[sub] or {}
            return c[sub]
        end
        return c
    end
    -- Deliberately does NOT go through Table(): that materialises missing
    -- sub-tables, and merely OPENING the options page should not write to the
    -- profile.
    local function Read(field, fallback)
        local c = Cfg()
        local t = c and (sub and c[sub] or c)
        local v = t and t[field]
        if v == nil then return fallback end
        return v
    end
    local function Write(field, v)
        local t = Table()
        if not t then return end
        t[field] = v
        Changed()
    end
    return {
        Read = Read,
        Write = Write,
        bool = function(field, fb) return function() return Read(field, fb) == true end end,
        setBool = function(field) return function(v) Write(field, v) end end,
        setBoolRebuild = function(field)
            return function(v) Write(field, v); if rebuildFields then rebuildFields() end end
        end,
        get = function(field, fb) return function() return Read(field, fb) end end,
        set = function(field) return function(v) Write(field, v) end end,
        setRebuild = function(field)
            return function(v) Write(field, v); if rebuildFields then rebuildFields() end end
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

local GROWTH_ITEMS = {
    {value = "DOWN",  text = L["Down"] or "Down"},
    {value = "UP",    text = L["Up"] or "Up"},
    {value = "RIGHT", text = L["Right"] or "Right"},
    {value = "LEFT",  text = L["Left"] or "Left"},
}

-- Where a text sits. One point used for both sides of SetPoint, for the name
-- on the bar (DressFrame) and for each icon text (AuraEngine's ApplyFontSlot)
-- alike, so every entry reads as "pin the text's corner to the same corner" --
-- a point/relative-point pair would offer combinations nobody wants.
local ANCHOR_POINT_ITEMS = {
    {value = "TOPLEFT",     text = L["Top Left"] or "Top Left"},
    {value = "TOP",         text = L["Top"] or "Top"},
    {value = "TOPRIGHT",    text = L["Top Right"] or "Top Right"},
    {value = "LEFT",        text = L["Left"] or "Left"},
    {value = "CENTER",      text = L["Center"] or "Center"},
    {value = "RIGHT",       text = L["Right"] or "Right"},
    {value = "BOTTOMLEFT",  text = L["Bottom Left"] or "Bottom Left"},
    {value = "BOTTOM",      text = L["Bottom"] or "Bottom"},
    {value = "BOTTOMRIGHT", text = L["Bottom Right"] or "Bottom Right"},
}

local OUTLINE_ITEMS = {
    {value = "NONE",         text = L["None"] or "None"},
    {value = "OUTLINE",      text = L["Outline"] or "Outline"},
    {value = "THICKOUTLINE", text = L["Thick Outline"] or "Thick Outline"},
}

local function FontItems()
    return (F.GetFontDropdownItems and F.GetFontDropdownItems()) or {}
end

-- A wrapped grey note. Measured rather than given a fixed height: the column
-- is narrow enough that the same sentence can take two lines or four, and a
-- hardcoded step either overlaps the next control or leaves a hole.
local function Note(host, y, text)
    local fs = host:CreateFontString(nil, "OVERLAY")
    fs:SetFontObject("GameFontDisableSmall")
    fs:SetPoint("TOPLEFT", 32, y)
    fs:SetWidth(FIELDS_WIDTH - 45)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return y - math.ceil(fs:GetStringHeight() or 24) - 12
end

-- Every control for ONE icon text: face, outline, size, colour, anchor, both
-- offsets. `prefix` is "duration" or "stack".
--
-- Getters read TankTracker.TextSettings, not the raw fields with their own
-- fallbacks: the face and outline have no default of their own (they follow
-- the frame font until set -- see TankTracker_Defaults.lua), and a second copy
-- of that rule here is how the dropdown ends up showing one font while the
-- icons render another.
local function TextControls(host, y, sub, prefix)
    local R = Acc(sub)
    local TT = SquizzFrames.TankTracker
    local function TS()
        local c = Cfg()
        return (TT and TT.TextSettings) and TT.TextSettings(c, c and c[sub], prefix) or {}
    end
    local function get(field) return function() return TS()[field] end end

    local ddFace = W.CreateStyledDropdown(host, 200, 40, L["Font"] or "Font",
        FontItems(), get("face"), R.set(prefix .. "Font"), "font")
    ddFace:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    local ddOutline = W.CreateStyledDropdown(host, 200, 40, L["Outline"] or "Outline",
        OUTLINE_ITEMS, get("outline"), R.set(prefix .. "Outline"))
    ddOutline:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    local sSize = W.CreateStyledSlider(host, 200, 6, 32, 1, L["Size"] or "Size",
        get("size"), R.set(prefix .. "Size"))
    sSize:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    local cp = W.CreateColorPicker(host, L["Text Color"] or "Text Color",
        function()
            local c = TS().color or {1, 1, 1, 1}
            return c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1
        end,
        R.colorSet(prefix .. "Color"))
    cp:SetPoint("TOPLEFT", 15, y)
    y = y - 36

    local ddAnchor = W.CreateStyledDropdown(host, 200, 40, L["Anchor"] or "Anchor",
        ANCHOR_POINT_ITEMS, get("anchor"), R.set(prefix .. "Anchor"))
    ddAnchor:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    local sX = W.CreateStyledSlider(host, 200, -40, 40, 1, L["Offset X"] or "Offset X",
        get("x"), R.set(prefix .. "X"))
    sX:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    local sY = W.CreateStyledSlider(host, 200, -40, 40, 1, L["Offset Y"] or "Offset Y",
        get("y"), R.set(prefix .. "Y"))
    sY:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    return y
end

-- One icon row's tab: layout controls, then a titled group per text. Debuffs
-- additionally get the filter dropdown, which is passed in rather than
-- special-cased inside.
local function BuildRow(host, y, label, sub, extra)
    local R = Acc(sub)
    local A = SquizzFrames.UnitFrameAuras

    W.CreateTitledPane(host, label, y)
    y = y - 35

    local cbOn = W.CreateStyledCheckbox(host, L["Show"] or "Show",
        R.bool("enabled", true), R.setBoolRebuild("enabled"))
    cbOn:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    if not R.Read("enabled", true) then return y end

    if extra then y = extra(host, y) end

    local ddAnchor = W.CreateStyledDropdown(host, 200, 40, L["Position"] or "Position",
        (A and A.ANCHOR_ITEMS) or {}, R.get("anchor", "topleft"), R.set("anchor"))
    ddAnchor:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    local sX = W.CreateStyledSlider(host, 200, -200, 200, 1, L["Offset X"] or "Offset X",
        R.get("offsetX", 0), R.set("offsetX"))
    sX:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    local sY = W.CreateStyledSlider(host, 200, -200, 200, 1, L["Offset Y"] or "Offset Y",
        R.get("offsetY", 0), R.set("offsetY"))
    sY:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    local sSize = W.CreateStyledSlider(host, 200, 8, 64, 1, L["Icon Size"] or "Icon Size",
        R.get("size", 32), R.set("size"))
    sSize:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    -- "Max Per Row", not "Max Icons": this caps ONE line, and the row's total
    -- capacity is this x Rows (BuildSpec multiplies them into maxFrameCount).
    -- Labelled as a total it read as a hard ceiling that Rows then appeared to
    -- ignore. The stored key is still `num` -- this is a label change only, so
    -- no profile is touched.
    --
    -- The unit frames' aura rows keep L["Max Icons"]: they have no Rows
    -- setting and no wrap width, so num really is the total there.
    local sNum = W.CreateStyledSlider(host, 200, 1, 10, 1, L["Max Per Row"] or "Max Per Row",
        R.get("num", 4), R.set("num"))
    sNum:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    local sRows = W.CreateStyledSlider(host, 200, 1, 4, 1, L["Rows"] or "Rows",
        R.get("maxRows", 1), R.set("maxRows"))
    sRows:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    local sSpace = W.CreateStyledSlider(host, 200, 0, 20, 1, L["Spacing"] or "Spacing",
        R.get("spacing", 2), R.set("spacing"))
    sSpace:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    local cbBorder = W.CreateStyledCheckbox(host, L["Icon Borders"] or "Icon Borders",
        R.bool("showBorder", true), R.setBool("showBorder"))
    cbBorder:SetPoint("TOPLEFT", 15, y)
    y = y - 40

    -- Duration text
    W.CreateTitledPane(host, L["Duration Text"] or "Duration Text", y)
    y = y - 35

    local cbDur = W.CreateStyledCheckbox(host, L["Show Duration"] or "Show Duration",
        R.bool("showDuration", true), R.setBoolRebuild("showDuration"))
    cbDur:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    if R.Read("showDuration", true) then
        y = TextControls(host, y, sub, "duration")
    end

    -- Stack text
    W.CreateTitledPane(host, L["Stack Text"] or "Stack Text", y)
    y = y - 35

    local cbStack = W.CreateStyledCheckbox(host, L["Show Stacks"] or "Show Stacks",
        R.bool("showStack", true), R.setBoolRebuild("showStack"))
    cbStack:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    if R.Read("showStack", true) then
        y = TextControls(host, y, sub, "stack")
    end

    return y
end

-- The General tab: who, the frame itself, its look, and the name on the bar.
local function BuildGeneral(host, y)
    local C = Acc(nil)

    W.CreateTitledPane(host, L["Tank Tracker"] or "Tank Tracker", y)
    y = y - 35

    local cbOn = W.CreateStyledCheckbox(host, L["Enable Tank Tracker"] or "Enable Tank Tracker",
        C.bool("enabled", false), C.setBoolRebuild("enabled"))
    cbOn:SetPoint("TOPLEFT", 15, y)
    y = y - 26

    y = Note(host, y, L["TankTrackerNote"]
        or "A compact frame per tank, with their incoming boss and role debuffs above the bar and their active defensives below. Drag it in Edit Mode.")

    -- Everything below is meaningless while the tracker is off, so it is
    -- hidden rather than shown-and-ignored.
    if not C.Read("enabled", false) then return end

    local cbSelf = W.CreateStyledCheckbox(host, L["Include Yourself"] or "Include Yourself",
        C.bool("includeSelf", true), C.setBool("includeSelf"))
    cbSelf:SetPoint("TOPLEFT", 15, y)
    y = y - 26

    y = Note(host, y, L["TankTrackerSelfNote"]
        or "Off shows only your CO-tanks, so nothing appears when you're tanking alone.")

    local cbSpec = W.CreateStyledCheckbox(host,
        L["Only While Tank Spec"] or "Only While Tank Spec",
        C.bool("requireTankSpec", false), C.setBool("requireTankSpec"))
    cbSpec:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    local sMax = W.CreateStyledSlider(host, 200, 1, 8, 1, L["Max Frames"] or "Max Frames",
        C.get("maxFrames", 4), C.set("maxFrames"))
    sMax:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    -- Frame
    W.CreateTitledPane(host, L["Frame"] or "Frame", y)
    y = y - 35

    local sW = W.CreateStyledSlider(host, 200, 60, 400, 1, L["Width"] or "Width",
        C.get("width", 150), C.set("width"))
    sW:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    local sH = W.CreateStyledSlider(host, 200, 8, 80, 1, L["Height"] or "Height",
        C.get("height", 20), C.set("height"))
    sH:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    local sScale = W.CreateStyledSlider(host, 200, 0.5, 2, 0.05, L["Scale"] or "Scale",
        C.get("scale", 1), C.set("scale"))
    sScale:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    local ddGrowth = W.CreateStyledDropdown(host, 200, 40, L["Growth"] or "Growth",
        GROWTH_ITEMS, C.get("growthDirection", "DOWN"), C.set("growthDirection"))
    ddGrowth:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    local sSpacing = W.CreateStyledSlider(host, 200, 0, 200, 1, L["Spacing"] or "Spacing",
        C.get("spacing", 80), C.set("spacing"))
    sSpacing:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    y = Note(host, y, L["TankTrackerSpacingNote"]
        or "Each frame carries an icon row above AND below, so spacing that only clears the bar will overlap the neighbours' icons.")

    -- Appearance
    W.CreateTitledPane(host, L["Appearance"] or "Appearance", y)
    y = y - 35

    local cbClass = W.CreateStyledCheckbox(host, L["Class Color Health"] or "Class Color Health",
        C.bool("healthClassColor", true), C.setBoolRebuild("healthClassColor"))
    cbClass:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    local cpHealth = W.CreateColorPicker(host, L["Custom Color"] or "Custom Color",
        C.colorGet("healthCustomColor", 0.2, 0.6, 0.2, 1), C.colorSet("healthCustomColor"))
    cpHealth:SetPoint("TOPLEFT", 15, y)
    y = y - 32

    local cpBack = W.CreateColorPicker(host, L["Background"] or "Background",
        C.colorGet("backdropColor", 0, 0, 0, 0.6), C.colorSet("backdropColor"))
    cpBack:SetPoint("TOPLEFT", 15, y)
    y = y - 36

    local cbBorder = W.CreateStyledCheckbox(host, L["Border"] or "Border",
        C.bool("showBorder", true), C.setBoolRebuild("showBorder"))
    cbBorder:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    if C.Read("showBorder", true) then
        local sThick = W.CreateStyledSlider(host, 200, 1, 6, 1, L["Thickness"] or "Thickness",
            C.get("borderThickness", 1), C.set("borderThickness"))
        sThick:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local cpBorder = W.CreateColorPicker(host, L["Color"] or "Color",
            C.colorGet("borderColor", 0, 0, 0, 1), C.colorSet("borderColor"))
        cpBorder:SetPoint("TOPLEFT", 15, y)
        y = y - 40
    end

    -- Name text
    W.CreateTitledPane(host, L["Name Text"] or "Name Text", y)
    y = y - 35

    local cbName = W.CreateStyledCheckbox(host, L["Show Name"] or "Show Name",
        C.bool("showName", true), C.setBoolRebuild("showName"))
    cbName:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    if not C.Read("showName", true) then return end

    -- The frame-wide `font`: the name always uses it, and each icon text
    -- follows it until given a face or outline of its own.
    local ddFont = W.CreateStyledDropdown(host, 200, 40, L["Font"] or "Font",
        FontItems(),
        function()
            local f = C.Read("font", nil)
            return (type(f) == "table" and f[1]) or "Friz QT__"
        end,
        function(v)
            local c = Cfg(); if not c then return end
            c.font = c.font or {}
            c.font[1] = v
            Changed()
        end, "font")
    ddFont:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    local ddOutline = W.CreateStyledDropdown(host, 200, 40, L["Outline"] or "Outline",
        OUTLINE_ITEMS,
        function()
            local f = C.Read("font", nil)
            return (type(f) == "table" and f[3]) or "OUTLINE"
        end,
        function(v)
            local c = Cfg(); if not c then return end
            c.font = c.font or {}
            c.font[3] = v
            Changed()
        end)
    ddOutline:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    local sFont = W.CreateStyledSlider(host, 200, 6, 32, 1, L["Size"] or "Size",
        C.get("nameFontSize", 12), C.set("nameFontSize"))
    sFont:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    local cpName = W.CreateColorPicker(host, L["Text Color"] or "Text Color",
        C.colorGet("nameColor", 1, 1, 1, 1), C.colorSet("nameColor"))
    cpName:SetPoint("TOPLEFT", 15, y)
    y = y - 36

    local ddAnchor = W.CreateStyledDropdown(host, 200, 40, L["Anchor"] or "Anchor",
        ANCHOR_POINT_ITEMS, C.get("nameAnchor", "LEFT"), C.set("nameAnchor"))
    ddAnchor:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    local sNx = W.CreateStyledSlider(host, 200, -200, 200, 1, L["Offset X"] or "Offset X",
        C.get("nameX", 3), C.set("nameX"))
    sNx:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    local sNy = W.CreateStyledSlider(host, 200, -60, 60, 1, L["Offset Y"] or "Offset Y",
        C.get("nameY", 0), C.set("nameY"))
    sNy:SetPoint("TOPLEFT", 15, y - 20)
end

local function BuildFields(frame)
    if frame.fieldsHost then
        frame.fieldsHost:Hide()
        frame.fieldsHost:SetParent(nil)
        frame.fieldsHost = nil
    end
    -- Column width, not the full page: the preview pane covers the rest, and
    -- anything built out there would sit underneath it.
    local host = CreateFrame("Frame", nil, frame)
    host:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    host:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    host:SetWidth(FIELDS_WIDTH)
    frame.fieldsHost = host

    -- Every rebuild, including the OnShow one: the profile can change behind
    -- the page's back (a profile switch, /sf reset).
    RefreshPreview()

    local y = headerPinned and -10 or -(HEADER_HEIGHT + 10)

    if activeTab == "general" then
        BuildGeneral(host, y)
        return
    end

    -- The row tabs have nothing to configure while the tracker is off, and the
    -- switch lives on General -- say so rather than showing an empty column.
    if not Acc(nil).Read("enabled", false) then
        Note(host, y, L["TankTrackerOffNote"]
            or "The Tank Tracker is off. Turn it on in the General tab.")
        return
    end

    if activeTab == "debuffs" then
        local C = Acc(nil)
        BuildRow(host, y, L["Debuffs"] or "Debuffs", "debuffs", function(h, yy)
            local ddFilter = W.CreateStyledDropdown(h, 200, 40, L["Filter"] or "Filter",
                SquizzFrames.TANKTRACKER_DEBUFF_FILTERS or {},
                C.get("debuffFilter", "boss_role"), C.set("debuffFilter"))
            ddFilter:SetPoint("TOPLEFT", 15, yy - 20)
            yy = yy - 70

            return Note(h, yy, L["TankTrackerFilterNote"]
                or "Boss & role mechanics is where the game delivers tank-relevant debuffs. The wider settings will show a lot more.")
        end)
    else
        BuildRow(host, y, L["Defensives"] or "Defensives", "defensives")
    end
end

-- Pinned furniture: the tab strip across the top and the preview pane down
-- the right. Both are parented up the chain to the scroll frame's own parent
-- (page -> scrollChild -> scrollFrame -> contentArea) so they do NOT scroll --
-- the same walk UnitFramesPanel makes, and for the same reason: the page lives
-- inside scrollChild and anything parented there scrolls away with it.
--
-- Returns the frame the tab buttons belong on.
local function BuildFurniture(frame)
    local scrollChild = frame:GetParent()
    local scroll = scrollChild and scrollChild:GetParent()
    local contentArea = scroll and scroll:GetParent()
    if not (scroll and contentArea) then return frame end
    headerPinned = true

    -- +50 for the reason UnitFramesPanel gives: the scrolling widgets bump
    -- their own levels several deep, and a smaller gap let them draw over the
    -- pinned furniture.
    local level = (contentArea:GetFrameLevel() or 1) + 50

    -- THE SCROLL REGION IS SHRUNK, not merely covered, while this page is up
    -- -- otherwise rows scroll up behind the tabs into a band you can never
    -- read. The ScrollFrame is SHARED with every other page, so its own
    -- anchors are captured and restored on hide rather than hardcoded here.
    local originalPoints = {}
    for i = 1, scroll:GetNumPoints() do
        originalPoints[i] = { scroll:GetPoint(i) }
    end
    local function ApplyScrollInset(inset)
        scroll:ClearAllPoints()
        for _, pt in ipairs(originalPoints) do
            local point, rel, relPoint, px, py = unpack(pt)
            if point == "TOPLEFT" or point == "TOPRIGHT" or point == "TOP" then
                py = (py or 0) - inset
            end
            scroll:SetPoint(point, rel, relPoint, px, py)
        end
    end

    -- Anchored to contentArea, NOT to scroll: scroll moves down by exactly the
    -- header's height, and a header following it would leave the gap it was
    -- meant to fill.
    local header = CreateFrame("Frame", nil, contentArea, "BackdropTemplate")
    local firstPoint = originalPoints[1]
    local hx = (firstPoint and firstPoint[4]) or 0
    local hy = (firstPoint and firstPoint[5]) or 0
    header:SetPoint("TOPLEFT", contentArea, "TOPLEFT", hx, hy)
    header:SetPoint("TOPRIGHT", contentArea, "TOPRIGHT", -16, hy)
    header:SetHeight(HEADER_HEIGHT)
    header:SetFrameLevel(level)
    W.StylizeFrame(header, {0.06, 0.06, 0.06, 1}, {0, 0, 0, 0})

    -- Preview pane. Anchored to scroll, which already stops short of the
    -- scrollbar and (once inset) starts below the header. Mouse is left
    -- DISABLED, so the wheel still reaches the scroll frame underneath and the
    -- page scrolls with the cursor over the preview too.
    local pane = CreateFrame("Frame", nil, contentArea, "BackdropTemplate")
    pane:SetPoint("TOPLEFT", scroll, "TOPLEFT", FIELDS_WIDTH, 0)
    pane:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 0, 0)
    pane:SetFrameLevel(level)
    -- Clipped: a wide frame or a long icon row at a large size can be wider
    -- than the pane, and a mock spilling out over the settings column is worse
    -- than one cut off at the edge.
    pane:SetClipsChildren(true)
    W.StylizeFrame(pane, {0.06, 0.06, 0.06, 1}, {0, 0, 0, 0})

    local caption = pane:CreateFontString(nil, "OVERLAY")
    caption:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    caption:SetPoint("TOP", pane, "TOP", 0, -8)
    caption:SetTextColor(0.7, 0.7, 0.7, 1)
    caption:SetText(L["Preview (actual size)"] or "Preview (actual size)")

    local hint = pane:CreateFontString(nil, "OVERLAY")
    hint:SetFontObject("GameFontDisableSmall")
    hint:SetPoint("CENTER", pane, "CENTER", 0, 0)
    hint:SetText(L["Enable the Tank Tracker to preview it."]
        or "Enable the Tank Tracker to preview it.")
    hint:Hide()
    previewHint = hint

    local P = SquizzFrames.TankTrackerPreview
    if P and P.Create then previewMock = P.Create(pane) end

    -- Tied to the page's visibility: neither is one of OptionsFrame's
    -- contentFrames, so ShowPage does not know about them and they would
    -- otherwise sit on top of whatever page you switched to. The inset is
    -- restored on hide, or every other page inherits a dead band at the top.
    local function ShowFurniture(show)
        header:SetShown(show)
        pane:SetShown(show)
        ApplyScrollInset(show and HEADER_HEIGHT or 0)
    end
    ShowFurniture(false)
    frame:HookScript("OnShow", function() ShowFurniture(true) end)
    frame:HookScript("OnHide", function() ShowFurniture(false) end)
    if frame:IsShown() then ShowFurniture(true) end

    return header
end

function Panel.Build(frame)
    local tabHost = BuildFurniture(frame)

    local tabButtons = {}
    local function RefreshTabVisual()
        local accent = F.GetAccentColor()
        for key, btn in pairs(tabButtons) do
            if key == activeTab then
                btn:SetBackdropColor(accent.r, accent.g, accent.b, 0.55)
            else
                btn:SetBackdropColor(0.115, 0.115, 0.115, 1)
            end
        end
    end

    local x = 15
    for _, tab in ipairs(TABS) do
        local btn = CreateFrame("Button", nil, tabHost, "BackdropTemplate")
        btn:SetSize(90, 22)
        btn:SetPoint("TOPLEFT", tabHost, "TOPLEFT", x, -6)
        W.StylizeFrame(btn, {0.115, 0.115, 0.115, 1}, {0, 0, 0, 0})
        local text = btn:CreateFontString(nil, "OVERLAY")
        text:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        text:SetPoint("CENTER")
        text:SetText(tab.label)
        btn:SetScript("OnClick", function()
            if activeTab == tab.key then return end
            activeTab = tab.key
            RefreshTabVisual()
            if rebuildFields then rebuildFields() end
            ScrollToTop()
        end)
        tabButtons[tab.key] = btn
        x = x + 93
    end

    rebuildFields = function()
        BuildFields(frame)
        RefreshTabVisual()
    end
    rebuildFields()
    frame:HookScript("OnShow", function() rebuildFields() end)
end
