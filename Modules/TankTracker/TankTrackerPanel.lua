--[[ SquizzFrames Tank Tracker options page

    A pure shell over profile.tankTracker -- every control reads and writes
    that tree and then fires "TankTrackerChanged", which TankTracker.lua turns
    into an ApplyLayout. Nothing here touches frames directly, the same
    discipline NicknamesPanel and UnitFramesPanel follow.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local L = SquizzFrames.L
local F = SquizzFrames.F
local W = SquizzFrames.Widgets

local Panel = {}
SquizzFrames.TankTrackerPanel = Panel

local rebuildFields

local function Cfg()
    local p = SquizzFrames.db and SquizzFrames.db.profile
    if not p then return nil end
    p.tankTracker = p.tankTracker or {}
    return p.tankTracker
end

local function Changed()
    SquizzFrames:Fire("TankTrackerChanged")
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

-- Where a text sits ON its icon. AuraEngine's ApplyFontSlot uses ONE point for
-- both sides of SetPoint, so each entry reads as "pin the text's corner to the
-- icon's same corner" -- a point/relative-point pair would offer combinations
-- nobody wants.
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

-- One icon row's controls. Debuffs additionally get the filter dropdown, which
-- is passed in rather than special-cased inside.
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

    local sNum = W.CreateStyledSlider(host, 200, 1, 10, 1, L["Max Icons"] or "Max Icons",
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

    local cbDur = W.CreateStyledCheckbox(host, L["Show Duration"] or "Show Duration",
        R.bool("showDuration", true), R.setBoolRebuild("showDuration"))
    cbDur:SetPoint("TOPLEFT", 15, y)
    y = y - 28

    if R.Read("showDuration", true) then
        local sDur = W.CreateStyledSlider(host, 200, 6, 24, 1,
            L["Duration Text Size"] or "Duration Text Size",
            R.get("durationSize", 11), R.set("durationSize"))
        sDur:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local ddDur = W.CreateStyledDropdown(host, 200, 40,
            L["Duration Anchor"] or "Duration Anchor",
            ANCHOR_POINT_ITEMS, R.get("durationAnchor", "CENTER"),
            R.set("durationAnchor"))
        ddDur:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        local sDx = W.CreateStyledSlider(host, 200, -30, 30, 1,
            L["Duration Offset X"] or "Duration Offset X",
            R.get("durationX", 0), R.set("durationX"))
        sDx:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local sDy = W.CreateStyledSlider(host, 200, -30, 30, 1,
            L["Duration Offset Y"] or "Duration Offset Y",
            R.get("durationY", 0), R.set("durationY"))
        sDy:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65
    end

    local cbStack = W.CreateStyledCheckbox(host, L["Show Stacks"] or "Show Stacks",
        R.bool("showStack", true), R.setBoolRebuild("showStack"))
    cbStack:SetPoint("TOPLEFT", 15, y)
    y = y - 28

    if R.Read("showStack", true) then
        local sSt = W.CreateStyledSlider(host, 200, 6, 24, 1,
            L["Stack Text Size"] or "Stack Text Size",
            R.get("stackSize", 11), R.set("stackSize"))
        sSt:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local ddStack = W.CreateStyledDropdown(host, 200, 40,
            L["Stack Anchor"] or "Stack Anchor",
            ANCHOR_POINT_ITEMS, R.get("stackAnchor", "BOTTOMRIGHT"),
            R.set("stackAnchor"))
        ddStack:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        local sSx = W.CreateStyledSlider(host, 200, -20, 20, 1, L["Stack Offset X"] or "Stack Offset X",
            R.get("stackX", 1), R.set("stackX"))
        sSx:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

        local sSy = W.CreateStyledSlider(host, 200, -20, 20, 1, L["Stack Offset Y"] or "Stack Offset Y",
            R.get("stackY", -1), R.set("stackY"))
        sSy:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65
    end

    local cbBorder = W.CreateStyledCheckbox(host, L["Icon Borders"] or "Icon Borders",
        R.bool("showBorder", true), R.setBool("showBorder"))
    cbBorder:SetPoint("TOPLEFT", 15, y)
    y = y - 36

    return y
end

local function BuildFields(frame)
    if frame.fieldsHost then
        frame.fieldsHost:Hide()
        frame.fieldsHost:SetParent(nil)
        frame.fieldsHost = nil
    end
    local host = CreateFrame("Frame", nil, frame)
    host:SetAllPoints()
    frame.fieldsHost = host

    local C = Acc(nil)
    local y = -10

    W.CreateTitledPane(host, L["Tank Tracker"] or "Tank Tracker", y)
    y = y - 35

    local cbOn = W.CreateStyledCheckbox(host, L["Enable Tank Tracker"] or "Enable Tank Tracker",
        C.bool("enabled", false), C.setBoolRebuild("enabled"))
    cbOn:SetPoint("TOPLEFT", 15, y)
    y = y - 26

    local note = host:CreateFontString(nil, "OVERLAY")
    note:SetFontObject("GameFontDisableSmall")
    note:SetPoint("TOPLEFT", 32, y)
    note:SetPoint("RIGHT", host, "RIGHT", -20, 0)
    note:SetJustifyH("LEFT")
    note:SetText(L["TankTrackerNote"]
        or "A compact frame per tank, with their incoming boss and role debuffs above the bar and their active defensives below. Drag it in Edit Mode.")
    y = y - 46

    -- Everything below is meaningless while the tracker is off, so it is
    -- hidden rather than shown-and-ignored.
    if not C.Read("enabled", false) then return end

    local cbSelf = W.CreateStyledCheckbox(host, L["Include Yourself"] or "Include Yourself",
        C.bool("includeSelf", true), C.setBool("includeSelf"))
    cbSelf:SetPoint("TOPLEFT", 15, y)
    y = y - 26

    local selfNote = host:CreateFontString(nil, "OVERLAY")
    selfNote:SetFontObject("GameFontDisableSmall")
    selfNote:SetPoint("TOPLEFT", 32, y)
    selfNote:SetPoint("RIGHT", host, "RIGHT", -20, 0)
    selfNote:SetJustifyH("LEFT")
    selfNote:SetText(L["TankTrackerSelfNote"]
        or "Off shows only your CO-tanks, so nothing appears when you're tanking alone.")
    y = y - 34

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

    local spacingNote = host:CreateFontString(nil, "OVERLAY")
    spacingNote:SetFontObject("GameFontDisableSmall")
    spacingNote:SetPoint("TOPLEFT", 32, y)
    spacingNote:SetPoint("RIGHT", host, "RIGHT", -20, 0)
    spacingNote:SetJustifyH("LEFT")
    spacingNote:SetText(L["TankTrackerSpacingNote"]
        or "Each frame carries an icon row above AND below, so spacing that only clears the bar will overlap the neighbours' icons.")
    y = y - 40

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

    local cbName = W.CreateStyledCheckbox(host, L["Show Name"] or "Show Name",
        C.bool("showName", true), C.setBoolRebuild("showName"))
    cbName:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    if C.Read("showName", true) then
        local ddFont = W.CreateStyledDropdown(host, 200, 40, L["Font"] or "Font",
            (F.GetFontDropdownItems and F.GetFontDropdownItems()) or {},
            function()
                local f = C.Read("font", nil)
                return (type(f) == "table" and f[1]) or "Friz QT__"
            end,
            function(v)
                local c = Cfg(); if not c then return end
                c.font = c.font or {}
                c.font[1] = v
                Changed()
            end)
        ddFont:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        local sFont = W.CreateStyledSlider(host, 200, 6, 24, 1, L["Size"] or "Size",
            C.get("nameFontSize", 12), C.set("nameFontSize"))
        sFont:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 65

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

        local cpName = W.CreateColorPicker(host, L["Text Color"] or "Text Color",
            C.colorGet("nameColor", 1, 1, 1, 1), C.colorSet("nameColor"))
        cpName:SetPoint("TOPLEFT", 15, y)
        y = y - 36
    end

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
        y = y - 36
    end

    -- Debuffs, with the filter dropdown injected before the shared controls.
    y = BuildRow(host, y, L["Debuffs"] or "Debuffs", "debuffs", function(h, yy)
        local ddFilter = W.CreateStyledDropdown(h, 200, 40, L["Filter"] or "Filter",
            SquizzFrames.TANKTRACKER_DEBUFF_FILTERS or {},
            C.get("debuffFilter", "boss_role"), C.set("debuffFilter"))
        ddFilter:SetPoint("TOPLEFT", 15, yy - 20)
        yy = yy - 70

        local filterNote = h:CreateFontString(nil, "OVERLAY")
        filterNote:SetFontObject("GameFontDisableSmall")
        filterNote:SetPoint("TOPLEFT", 32, yy)
        filterNote:SetPoint("RIGHT", h, "RIGHT", -20, 0)
        filterNote:SetJustifyH("LEFT")
        filterNote:SetText(L["TankTrackerFilterNote"]
            or "Boss & role mechanics is where the game delivers tank-relevant debuffs. The wider settings will show a lot more.")
        yy = yy - 40
        return yy
    end)

    y = BuildRow(host, y, L["Defensives"] or "Defensives", "defensives")
end

function Panel.Build(frame)
    rebuildFields = function() BuildFields(frame) end
    BuildFields(frame)
    frame:HookScript("OnShow", function() BuildFields(frame) end)
end
