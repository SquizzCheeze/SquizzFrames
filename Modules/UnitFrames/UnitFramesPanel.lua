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

-- Content tokens offered in every text-slot dropdown. Built from the module's
-- own token list so the page can never offer something FormatToken doesn't
-- render -- see UnitFrames_Defaults.lua for why "health deficit" isn't here.
local TEXT_LABELS = {
    none          = L["None"] or "None",
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

local function TextItems()
    local items = {}
    for _, token in ipairs(SquizzFrames.UNITFRAME_TEXT_TOKENS or {}) do
        if TEXT_LABELS[token] then
            items[#items + 1] = {value = token, text = TEXT_LABELS[token]}
        end
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

local function Changed()
    SquizzFrames:Fire("UnitFramesChanged")
    -- The Blizzard-frame hide reads the same settings, and nothing else
    -- re-evaluates it when they change.
    if SquizzFrames.HideBlizzardUnitFrames then
        SquizzFrames:HideBlizzardUnitFrames()
    end
    -- The cast bar hide reads the module switch, its own switch AND the player
    -- frame's cast bar enable, so any of the three changing has to re-run it.
    -- Cheapest correct answer is to run it on every settings change.
    if SquizzFrames.HideBlizzardCastBar then
        SquizzFrames:HideBlizzardCastBar()
    end
end

local function Set(apply)
    local t = GetUnitConfig()
    if not t then return end
    apply(t)
    Changed()
end

-- Text-slot accessors are generated rather than written out three times: the
-- slot key is the only thing that differs, and fifteen hand-written getter/
-- setter pairs is exactly how a page drifts out of sync with its data.
local function SlotGetters(slotKey)
    return {
        content = function()
            local t = GetUnitConfig()
            return (t and t[slotKey] and t[slotKey].content) or "none"
        end,
        setContent = function(v)
            Set(function(t)
                t[slotKey] = t[slotKey] or {}
                t[slotKey].content = v
            end)
            if rebuildFields then rebuildFields() end
        end,
        size = function()
            local t = GetUnitConfig()
            return (t and t[slotKey] and t[slotKey].size) or 12
        end,
        setSize = function(v)
            Set(function(t) t[slotKey] = t[slotKey] or {}; t[slotKey].size = v end)
        end,
        x = function()
            local t = GetUnitConfig()
            return (t and t[slotKey] and t[slotKey].x) or 0
        end,
        setX = function(v)
            Set(function(t) t[slotKey] = t[slotKey] or {}; t[slotKey].x = v end)
        end,
        y = function()
            local t = GetUnitConfig()
            return (t and t[slotKey] and t[slotKey].y) or 0
        end,
        setY = function(v)
            Set(function(t) t[slotKey] = t[slotKey] or {}; t[slotKey].y = v end)
        end,
        classColor = function()
            local t = GetUnitConfig()
            return (t and t[slotKey] and t[slotKey].classColor) == true
        end,
        setClassColor = function(v)
            Set(function(t) t[slotKey] = t[slotKey] or {}; t[slotKey].classColor = v end)
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

    local cbHide = W.CreateStyledCheckbox(host,
        L["Hide Blizzard Unit Frames"] or "Hide Blizzard Unit Frames",
        function() return cfg.hideBlizzard ~= false end,
        function(v) cfg.hideBlizzard = v; Changed() end)
    cbHide:SetPoint("TOPLEFT", 15, y)
    y = y - 28

    local cbHideCast = W.CreateStyledCheckbox(host,
        L["Hide Blizzard Cast Bar"] or "Hide Blizzard Cast Bar",
        function() return cfg.hideBlizzardCastBar == true end,
        function(v) cfg.hideBlizzardCastBar = v; Changed() end)
    cbHideCast:SetPoint("TOPLEFT", 15, y)
    y = y - 30

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

local function SecText(host, y, cfg, t)
    local slots = {
        {key = "leftText",   label = L["Left Text"] or "Left Text"},
        {key = "rightText",  label = L["Right Text"] or "Right Text"},
        {key = "centerText", label = L["Center Text"] or "Center Text"},
    }
    for _, slot in ipairs(slots) do
        W.CreateTitledPane(host, slot.label, y)
        y = y - 35

        local acc = SlotGetters(slot.key)

        local dd = W.CreateStyledDropdown(host, 200, 40, L["Content"] or "Content",
            TextItems(), acc.content, acc.setContent)
        dd:SetPoint("TOPLEFT", 15, y - 20)
        y = y - 70

        -- Everything below is meaningless for an empty slot, so it is hidden
        -- rather than shown-and-ignored.
        if acc.content() ~= "none" then
            local sSize = W.CreateStyledSlider(host, 200, 6, 24, 1, L["Size"] or "Size",
                acc.size, acc.setSize)
            sSize:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65

            local sX = W.CreateStyledSlider(host, 200, -100, 100, 1, L["Offset X"] or "Offset X",
                acc.x, acc.setX)
            sX:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65

            local sY = W.CreateStyledSlider(host, 200, -50, 50, 1, L["Offset Y"] or "Offset Y",
                acc.y, acc.setY)
            sY:SetPoint("TOPLEFT", 15, y - 20)
            y = y - 65

            local cbCC = W.CreateStyledCheckbox(host, L["Use Class Color"] or "Use Class Color",
                acc.classColor, acc.setClassColor)
            cbCC:SetPoint("TOPLEFT", 15, y)
            y = y - 35
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
    host:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDEBAR_WIDTH, -HEADER_HEIGHT)
    host:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
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
            return
        end
    end
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

    local header, sidebar
    if contentArea and scroll then
        -- Opaque and above the scrolling content: rows sliding underneath have
        -- to be hidden, which is the whole point of pinned furniture.
        local level = (scroll:GetFrameLevel() or 1) + 10

        header = CreateFrame("Frame", nil, contentArea, "BackdropTemplate")
        header:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
        header:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, 0)
        header:SetHeight(HEADER_HEIGHT)
        header:SetFrameLevel(level)
        W.StylizeFrame(header, {0.06, 0.06, 0.06, 1}, {0, 0, 0, 0})

        sidebar = CreateFrame("Frame", nil, contentArea, "BackdropTemplate")
        sidebar:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
        sidebar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMLEFT", 0, 0)
        sidebar:SetWidth(SIDEBAR_WIDTH)
        sidebar:SetFrameLevel(level)
        W.StylizeFrame(sidebar, {0.06, 0.06, 0.06, 1}, {0, 0, 0, 0})

        -- Tied to the page's visibility -- neither is one of OptionsFrame's
        -- contentFrames, so ShowPage does not know about them and they would
        -- otherwise sit on top of whatever page you switched to.
        header:Hide()
        sidebar:Hide()
        frame:HookScript("OnShow", function() header:Show(); sidebar:Show() end)
        frame:HookScript("OnHide", function() header:Hide(); sidebar:Hide() end)
        if frame:IsShown() then header:Show(); sidebar:Show() end
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
