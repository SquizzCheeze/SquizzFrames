--[[ SquizzFrames UnitFramesResourcePanel.lua
    The Unit Frames page's Resources section (the resource bar's General /
    Power / Resource sub-tabs). Moved out of UnitFramesPanel.lua unchanged in
    2.0 (phase 2 code split). Loads right after it: reads the page's helpers
    from Panel.shared at load, and publishes Panel.SecResource, which the
    page's SECTIONS table reaches through a same-named forwarder.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local Panel = SquizzFrames.UnitFramesPanel
if not (Panel and Panel.shared) then return end

local L = SquizzFrames.L
local W = SquizzFrames.Widgets
local AnchorItems, Changed = Panel.shared.AnchorItems, Panel.shared.Changed
local GetConfig, SubTabs = Panel.shared.GetConfig, Panel.shared.SubTabs
-- rebuildFields is only assigned once Panel.Build runs, so reach it through
-- Panel.Rebuild (the same guarded call, a no-op before Build).
local function rebuildFields() Panel.Rebuild() end

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
                    CB.Targets("resource"), P.get("attachTo", "EssentialCooldownViewer"),
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
                ctx.CB.Targets("resource"), P.get("matchFrame", "EssentialCooldownViewer"),
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

Panel.SecResource = SecResource
