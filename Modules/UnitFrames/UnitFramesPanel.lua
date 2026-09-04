--[[ SquizzFrames Unit Frames options page (Phase 1)

    A pure shell over profile.unitFrames -- every control reads and writes that
    tree and then fires "UnitFramesChanged", which UnitFrames.lua turns into an
    ApplyLayout. Nothing here touches frames directly, the same discipline
    NicknamesPanel.lua follows over the Nicknames module.

    Structured like the Pet Frames page: a row of unit toggle buttons at the
    top swaps which sub-table every accessor below reads, so one builder serves
    all five frames instead of five near-identical builders that drift.

    PHASE 1 ONLY. Cast bar, portrait, aura and boss controls are deliberately
    absent rather than present-and-inert -- see UnitFrames_Defaults.lua.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local L = SquizzFrames.L
local F = SquizzFrames.F
local W = SquizzFrames.Widgets

local Panel = {}
SquizzFrames.UnitFramesPanel = Panel

-- Which unit's settings the page is currently editing.
local activeUnit = "player"
local rebuildFields

local UNIT_TABS = {
    {key = "player",       label = L["Player"] or "Player"},
    {key = "target",       label = L["Target"] or "Target"},
    {key = "targettarget", label = L["ToT"] or "ToT"},
    {key = "focus",        label = L["Focus"] or "Focus"},
    {key = "focustarget",  label = L["Focus Tgt"] or "Focus Tgt"},
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
    return cfg and cfg.frames and cfg.frames[activeUnit]
end

local function Changed()
    SquizzFrames:Fire("UnitFramesChanged")
    -- The Blizzard-frame hide reads the same settings, and nothing else
    -- re-evaluates it when they change.
    if SquizzFrames.HideBlizzardUnitFrames then
        SquizzFrames:HideBlizzardUnitFrames()
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

local function BuildFields(frame)
    if frame.fieldsHost then
        frame.fieldsHost:Hide()
        frame.fieldsHost:SetParent(nil)
        frame.fieldsHost = nil
    end

    local host = CreateFrame("Frame", nil, frame)
    host:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -34)
    host:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    frame.fieldsHost = host

    local y = -10
    local cfg = GetConfig()
    if not cfg then return end

    -- Module-wide switches, repeated on every unit tab rather than hidden on
    -- one of them: someone who lands on the Target tab first should not have
    -- to discover that the master switch lives under Player.
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
        return
    end

    local t = GetUnitConfig()
    if not t then return end

    W.CreateTitledPane(host, L["This Frame"] or "This Frame", y)
    y = y - 35

    local cbEnable = W.CreateStyledCheckbox(host, L["Enabled"] or "Enabled",
        function() return t.enabled ~= false end,
        function(v) Set(function(c) c.enabled = v end) end)
    cbEnable:SetPoint("TOPLEFT", 15, y)
    y = y - 35

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

    -- Text slots
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
-- Page
-----------------------------------------------------------------------

function Panel.Build(frame)
    local tabButtons = {}
    local function RefreshTabVisual()
        local accent = F.GetAccentColor()
        for key, btn in pairs(tabButtons) do
            if key == activeUnit then
                btn:SetBackdropColor(accent.r, accent.g, accent.b, 0.55)
            else
                btn:SetBackdropColor(0.115, 0.115, 0.115, 1)
            end
        end
    end

    -- Five tabs at 72px + 3px gap fits the panel width without wrapping; the
    -- Pet page's 90px buttons would not.
    local x = 15
    for _, tab in ipairs(UNIT_TABS) do
        local btn = CreateFrame("Button", nil, frame, "BackdropTemplate")
        btn:SetSize(72, 22)
        btn:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -6)
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
        tabButtons[tab.key] = btn
        x = x + 75
    end
    RefreshTabVisual()

    rebuildFields = function() BuildFields(frame) end
    rebuildFields()

    -- Own message owner: CallbackHandler keeps one handler per (owner,
    -- message), so registering ProfileChanged on the shared root here would
    -- silently replace somebody else's.
    F.NewMessageOwner():RegisterMessage("ProfileChanged", function()
        rebuildFields()
    end)
end
