--[[ SquizzFrames Party Cooldowns options page (Tools group)

    A pure shell over PartyCooldowns.Get / .Set -- every control reads and
    writes through the module, which owns the defaults and fires
    "PartyCooldownsChanged". Nothing here touches the icons directly.

    Three sub-tabs on a pinned strip, the Tank Tracker page's arrangement:
      General   on/off, test icons, which categories
      Layout    where the icons sit, how they look, the countdown
      Spells    one checkbox per spell, grouped by class
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local L = SquizzFrames.L or {}
local W = SquizzFrames.Widgets
local F = SquizzFrames.F

local Panel = {}
SquizzFrames.PartyCooldownsPanel = Panel

local NOTE_WIDTH = 420
local HEADER_HEIGHT = 34

local TABS = {
    {key = "general", label = L["General"] or "General"},
    {key = "layout",  label = L["Layout"] or "Layout"},
    {key = "spells",  label = L["Spells"] or "Spells"},
}
local activeTab = "general"
local rebuildFields
-- False when the scroll-frame chain was not what we expected and the tab
-- strip had to be built on the page itself, where it scrolls and the fields
-- must start below it.
local headerPinned = false

local SIDE_ITEMS = {
    {value = "BOTTOM", text = L["Below"] or "Below"},
    {value = "TOP",    text = L["Above"] or "Above"},
    {value = "LEFT",   text = L["Left"] or "Left"},
    {value = "RIGHT",  text = L["Right"] or "Right"},
}

local ALIGN_ITEMS = {
    {value = "START",  text = L["Start (left / top)"] or "Start (left / top)"},
    {value = "CENTER", text = L["Center"] or "Center"},
    {value = "END",    text = L["End (right / bottom)"] or "End (right / bottom)"},
}

local function Mod() return SquizzFrames.PartyCooldowns end

local function get(key) return function() local M = Mod(); return M and M.Get(key) end end
local function set(key) return function(v) local M = Mod(); if M then M.Set(key, v) end end end

local function ScrollToTop()
    if SquizzFrames.OptionsScrollToTop then SquizzFrames.OptionsScrollToTop() end
end

local function Note(host, y, text)
    local fs = host:CreateFontString(nil, "OVERLAY")
    fs:SetFontObject("GameFontDisableSmall")
    fs:SetPoint("TOPLEFT", 32, y)
    fs:SetWidth(NOTE_WIDTH)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return y - math.ceil(fs:GetStringHeight() or 24) - 12
end

------------------------------------------------------------------------
-- General
------------------------------------------------------------------------
local function BuildGeneral(host, y)
    W.CreateTitledPane(host, L["Party Cooldowns"] or "Party Cooldowns", y)
    y = y - 35

    local cbOn = W.CreateStyledCheckbox(host, L["Enable"] or "Enable", get("enabled"), set("enabled"))
    cbOn:SetPoint("TOPLEFT", 15, y)
    y = y - 26

    y = Note(host, y, "Each group member's defensives, externals and group-wide cooldowns as icons on their " ..
        "party frame. Solo and party only: never in a raid. Works in combat and in keys by watching the buff " ..
        "each cooldown leaves, so cooldowns without a buff (interrupts, most damage cooldowns) cannot be shown. " ..
        "Cooldown lengths follow talents: yours directly, party members' once they have been inspected out of combat.")

    local cbTest = W.CreateStyledCheckbox(host, L["Show Test Icons"] or "Show Test Icons",
        function() return Mod().IsTestMode() end,
        function(v) Mod().SetTestMode(v) end)
    cbTest:SetPoint("TOPLEFT", 15, y)
    y = y - 40

    W.CreateTitledPane(host, L["What to Show"] or "What to Show", y)
    y = y - 35
    for _, item in ipairs({
        {"showSelf", L["Your Own Cooldowns"] or "Your Own Cooldowns"},
        {"personal", L["Personal Defensives"] or "Personal Defensives"},
        {"external", L["Externals"] or "Externals"},
        {"group",    L["Group-wide Cooldowns"] or "Group-wide Cooldowns"},
        {"potions",  L["Potions"] or "Potions"},
    }) do
        local cb = W.CreateStyledCheckbox(host, item[2], get(item[1]), set(item[1]))
        cb:SetPoint("TOPLEFT", 15, y)
        y = y - 30
    end
    y = y - 4
    return Note(host, y, "Potions: everyone's combat potion, plus your own healing potion and Healthstone " ..
        "(those leave no buff, so other players' cannot be seen). Individual spells can be switched off on the Spells tab.")
end

------------------------------------------------------------------------
-- Layout
------------------------------------------------------------------------
local function BuildLayout(host, y)
    W.CreateTitledPane(host, L["Position"] or "Position", y)
    y = y - 35

    local ddSide = W.CreateStyledDropdown(host, 200, 40, L["Attach To"] or "Attach To",
        SIDE_ITEMS, get("side"), set("side"))
    ddSide:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    local ddAlign = W.CreateStyledDropdown(host, 200, 40, L["Align"] or "Align",
        ALIGN_ITEMS, get("align"), set("align"))
    ddAlign:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    local sX = W.CreateStyledSlider(host, 200, -100, 100, 1, L["Offset X"] or "Offset X", get("offsetX"), set("offsetX"))
    sX:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    local sY = W.CreateStyledSlider(host, 200, -100, 100, 1, L["Offset Y"] or "Offset Y", get("offsetY"), set("offsetY"))
    sY:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 75

    W.CreateTitledPane(host, L["Icons"] or "Icons", y)
    y = y - 35

    local sSize = W.CreateStyledSlider(host, 200, 12, 48, 1, L["Icon Size"] or "Icon Size", get("size"), set("size"))
    sSize:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    local sSpace = W.CreateStyledSlider(host, 200, 0, 10, 1, L["Spacing"] or "Spacing", get("spacing"), set("spacing"))
    sSpace:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    -- Total shown is Max Per Row x Rows; extra rows stack away from the frame.
    local sPer = W.CreateStyledSlider(host, 200, 1, 12, 1, L["Max Per Row"] or "Max Per Row", get("perRow"), set("perRow"))
    sPer:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    local sRows = W.CreateStyledSlider(host, 200, 1, 4, 1, L["Rows"] or "Rows", get("rows"), set("rows"))
    sRows:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 65

    local sShade = W.CreateStyledSlider(host, 200, 0.2, 1, 0.05, L["Cooldown Shade"] or "Cooldown Shade",
        get("shade"), set("shade"))
    sShade:SetPoint("TOPLEFT", 15, y - 20)
    y = y - 70

    local cbBorder = W.CreateStyledCheckbox(host, L["Icon Borders"] or "Icon Borders", get("showBorder"), set("showBorder"))
    cbBorder:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    local cbGlow = W.CreateStyledCheckbox(host, L["Highlight While Active"] or "Highlight While Active",
        get("glow"), set("glow"))
    cbGlow:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    local cbTips = W.CreateStyledCheckbox(host, L["Tooltips on Hover"] or "Tooltips on Hover",
        get("tooltips"), set("tooltips"))
    cbTips:SetPoint("TOPLEFT", 15, y)
    y = y - 40

    W.CreateTitledPane(host, L["Countdown"] or "Countdown", y)
    y = y - 35

    local cbNums = W.CreateStyledCheckbox(host, L["Show Countdown Numbers"] or "Show Countdown Numbers",
        get("showNumbers"), set("showNumbers"))
    cbNums:SetPoint("TOPLEFT", 15, y)
    y = y - 30

    local sNum = W.CreateStyledSlider(host, 200, 8, 24, 1, L["Number Size"] or "Number Size",
        get("numberSize"), set("numberSize"))
    sNum:SetPoint("TOPLEFT", 15, y - 20)
    return y - 75
end

------------------------------------------------------------------------
-- Spells: one checkbox per tracked spell, grouped by class, two columns.
-- Unticking hides that cooldown on every frame.
------------------------------------------------------------------------
local COLUMN_X = { 15, 255 }
local ROW_H = 26
local CAT_TAG = {
    external = L["external"] or "external",
    group = L["group"] or "group",
}

local function ClassOrder()
    local order = {}
    if CLASS_SORT_ORDER then
        for _, c in ipairs(CLASS_SORT_ORDER) do order[#order + 1] = c end
    else
        order = { "WARRIOR", "DEATHKNIGHT", "PALADIN", "MONK", "PRIEST", "SHAMAN", "DRUID",
                  "ROGUE", "MAGE", "WARLOCK", "HUNTER", "DEMONHUNTER", "EVOKER" }
    end
    order[#order + 1] = "ANY" -- potions, for everyone, last
    return order
end

local function BuildSpells(host, y)
    local M = Mod()
    local DATA = SquizzFrames.PartyCooldownsData
    if not (M and DATA) then return y end

    W.CreateTitledPane(host, L["Spells"] or "Spells", y)
    y = y - 35

    local allOn = W.CreateStyledButton(host, L["All On"] or "All On", "accent-hover", {80, 22}, function()
        M.SetAllSpellsEnabled(true)
        if rebuildFields then rebuildFields() end
    end)
    allOn:SetPoint("TOPLEFT", 15, y)
    local allOff = W.CreateStyledButton(host, L["All Off"] or "All Off", "accent-hover", {80, 22}, function()
        M.SetAllSpellsEnabled(false)
        if rebuildFields then rebuildFields() end
    end)
    allOff:SetPoint("LEFT", allOn, "RIGHT", 8, 0)
    y = y - 34

    local byClass = {}
    for _, def in ipairs(DATA.spells) do
        byClass[def.class] = byClass[def.class] or {}
        table.insert(byClass[def.class], def)
    end

    for _, class in ipairs(ClassOrder()) do
        local list = byClass[class]
        if list then
            local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
            local name = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class
            if class == "ANY" then name = L["Potions"] or "Potions" end
            local header = host:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            header:SetPoint("TOPLEFT", 15, y)
            header:SetText(color and ("|c" .. color.colorStr .. name .. "|r") or name)
            y = y - 24

            for i, def in ipairs(list) do
                local col = (i - 1) % 2 + 1
                local icon = (def.items and C_Item.GetItemIconByID(def.items[1])) or C_Spell.GetSpellTexture(def.key)
                local label = def.label or C_Spell.GetSpellName(def.key) or tostring(def.key)
                if def.ownOnly then label = label .. " |cff888888(yours only)|r" end
                if CAT_TAG[def.cat] then
                    label = label .. " |cff888888(" .. CAT_TAG[def.cat] .. ")|r"
                end
                if icon then label = "|T" .. icon .. ":16:16:0:0:64:64:5:59:5:59|t " .. label end
                local key = def.key
                local cb = W.CreateStyledCheckbox(host, label,
                    function() return M.IsSpellEnabled(key) end,
                    function(v) M.SetSpellEnabled(key, v) end)
                cb:SetPoint("TOPLEFT", COLUMN_X[col], y)
                if col == 2 or i == #list then y = y - ROW_H end
            end
            y = y - 8
        end
    end
    return y
end

------------------------------------------------------------------------
-- The selected tab's fields
------------------------------------------------------------------------
local function BuildFields(frame)
    if frame.fieldsHost then
        frame.fieldsHost:Hide()
        frame.fieldsHost:SetParent(nil)
    end
    local host = CreateFrame("Frame", nil, frame)
    host:SetAllPoints()
    frame.fieldsHost = host

    if not Mod() then
        local msg = host:CreateFontString(nil, "OVERLAY", "GameFontRed")
        msg:SetPoint("TOPLEFT", 15, -20)
        msg:SetText("Party Cooldowns module not loaded.")
        return
    end

    local y = headerPinned and -10 or -(HEADER_HEIGHT + 10)

    -- Search: only the tab on screen is built, so tell the options window
    -- which one this is; Panel.Select brings it back for a result.
    local Shell = LibStub and LibStub("LibSquizzShell-1.0", true)
    if Shell then
        local label = activeTab
        for _, tab in ipairs(TABS) do
            if tab.key == activeTab then label = tab.label end
        end
        Shell:SetIndexScope(frame, activeTab, label, { tab = activeTab })
    end

    if activeTab == "layout" then
        BuildLayout(host, y)
    elseif activeTab == "spells" then
        BuildSpells(host, y)
    else
        BuildGeneral(host, y)
    end
end

-- Pinned tab strip: parented up the chain to the scroll frame's own parent
-- (page -> scrollChild -> scrollFrame -> contentArea) so it does NOT scroll,
-- and the shared scroll frame is inset while this page is up -- the same
-- walk TankTrackerPanel makes, for the same reasons (see its comments).
-- Returns the frame the tab buttons belong on.
local function BuildFurniture(frame)
    local scrollChild = frame:GetParent()
    local scroll = scrollChild and scrollChild:GetParent()
    local contentArea = scroll and scroll:GetParent()
    if not (scroll and contentArea) then return frame end
    headerPinned = true

    local level = (contentArea:GetFrameLevel() or 1) + 50

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

    local header = CreateFrame("Frame", nil, contentArea, "BackdropTemplate")
    local firstPoint = originalPoints[1]
    local hx = (firstPoint and firstPoint[4]) or 0
    local hy = (firstPoint and firstPoint[5]) or 0
    header:SetPoint("TOPLEFT", contentArea, "TOPLEFT", hx, hy)
    header:SetPoint("TOPRIGHT", contentArea, "TOPRIGHT", -16, hy)
    header:SetHeight(HEADER_HEIGHT)
    header:SetFrameLevel(level)
    W.StylizeFrame(header, W.palette.DARK_BG, {0, 0, 0, 0})

    local function ShowFurniture(show)
        header:SetShown(show)
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
                btn:SetBackdropColor(W.C4(W.palette.PANEL_BG))
            end
        end
    end

    local x = 15
    for _, tab in ipairs(TABS) do
        local btn = CreateFrame("Button", nil, tabHost, "BackdropTemplate")
        btn:SetSize(90, 22)
        btn:SetPoint("TOPLEFT", tabHost, "TOPLEFT", x, -6)
        W.StylizeFrame(btn, W.palette.PANEL_BG, {0, 0, 0, 0})
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

    -- Test icons are for while the page is open; leaving them on would draw
    -- fake cooldowns on real frames.
    frame:HookScript("OnHide", function()
        local M = Mod()
        if M and M.IsTestMode() then M.SetTestMode(false) end
    end)
end

------------------------------------------------------------------------
-- Preview (the options window's right-hand column): a mock party frame at
-- the real frames' size with icons placed by the module's own Place, so
-- every Layout setting shows as you change it. Plain values only: the
-- shades and numbers are fixed samples, not timers.
------------------------------------------------------------------------
local SAMPLE_LEFT = { 0, 0.62, 0.3, 0, 0.85, 0.12, 0.45, 0, 0.7, 0.2, 0, 0.55 }
local preview

local function SampleSpells()
    local DATA = SquizzFrames.PartyCooldownsData
    local _, class = UnitClass("player")
    local list, potion = {}, nil
    for _, def in ipairs(DATA and DATA.spells or {}) do
        if def.class == class and not def.ownOnly then list[#list + 1] = def end
        if def.class == "ANY" and not def.ownOnly then potion = def end
    end
    if potion then list[#list + 1] = potion end
    return list
end

local function PartyFrameSize()
    local p = SquizzFrames.db and SquizzFrames.db.profile
    local main = p and p.layout and p.layout.main
    return (main and main.width) or 100, (main and main.height) or 40
end

function Panel.RefreshPreview()
    local M = Mod()
    if not (preview and M) then return end
    local w, h = PartyFrameSize()
    preview.mock:SetSize(w, h)
    -- Room for the icons on whichever side they hang.
    local side = M.Get("side")
    preview.mock:ClearAllPoints()
    local dx = (side == "LEFT" and 50) or (side == "RIGHT" and -50) or 0
    local dy = (side == "TOP" and -40) or (side == "BOTTOM" and 40) or 0
    preview.mock:SetPoint("CENTER", preview.holder, "CENTER", dx, dy)

    local samples = SampleSpells()
    local n = math.min(M.Get("perRow") * M.Get("rows"), 12)
    if #samples == 0 then n = 0 end
    local size, shade = M.Get("size"), M.Get("shade")
    local showNums, numSize = M.Get("showNumbers"), M.Get("numberSize")
    for i = 1, math.max(n, #preview.icons) do
        local ic = preview.icons[i]
        if i <= n then
            if not ic then
                ic = CreateFrame("Frame", nil, preview.holder)
                ic.tex = ic:CreateTexture(nil, "ARTWORK")
                ic.tex:SetAllPoints()
                ic.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                ic.shade = ic:CreateTexture(nil, "OVERLAY")
                ic.shade:SetPoint("TOPLEFT")
                ic.shade:SetPoint("TOPRIGHT")
                ic.num = ic:CreateFontString(nil, "OVERLAY")
                ic.num:SetPoint("CENTER")
                ic.border = {}
                local function edge(p1, p2, horizontal)
                    local b = ic:CreateTexture(nil, "OVERLAY", nil, 2)
                    b:SetColorTexture(0, 0, 0, 1)
                    b:SetPoint(p1)
                    b:SetPoint(p2)
                    if horizontal then b:SetHeight(1) else b:SetWidth(1) end
                    ic.border[#ic.border + 1] = b
                end
                edge("TOPLEFT", "TOPRIGHT", true)
                edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
                edge("TOPLEFT", "BOTTOMLEFT", false)
                edge("TOPRIGHT", "BOTTOMRIGHT", false)
                preview.icons[i] = ic
            end
            local def = samples[(i - 1) % #samples + 1]
            local tex = (def.items and C_Item.GetItemIconByID(def.items[1])) or C_Spell.GetSpellTexture(def.key)
            ic.tex:SetTexture(tex)
            ic:SetSize(size, size)
            local left = SAMPLE_LEFT[(i - 1) % #SAMPLE_LEFT + 1]
            ic.shade:SetColorTexture(0, 0, 0, shade)
            ic.shade:SetHeight(math.max(0.01, size * left))
            ic.shade:SetShown(left > 0)
            ic.num:SetFont("Fonts\\FRIZQT__.TTF", numSize, "OUTLINE")
            local secs = math.floor(left * def.cd + 0.5)
            ic.num:SetText(secs >= 60 and string.format("%dm", math.ceil(secs / 60)) or (secs > 0 and tostring(secs) or ""))
            ic.num:SetShown(showNums)
            for _, b in ipairs(ic.border) do b:SetShown(M.Get("showBorder")) end
            M.Place(ic, preview.mock, i - 1, n)
            ic:Show()
        elseif ic then
            ic:Hide()
        end
    end
end

function Panel.BuildPreview(column)
    local holder = CreateFrame("Frame", nil, column)
    holder:SetAllPoints(column)
    holder:SetClipsChildren(true)

    -- A plain stand-in for one party frame: dark body, green health.
    local mock = CreateFrame("Frame", nil, holder)
    local bg = mock:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.08, 0.08, 0.08, 1)
    local hp = mock:CreateTexture(nil, "ARTWORK")
    hp:SetPoint("TOPLEFT", 1, -1)
    hp:SetPoint("BOTTOMRIGHT", -1, 1)
    hp:SetColorTexture(0.2, 0.75, 0.3, 0.9)
    local name = mock:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("CENTER")
    name:SetText(UnitName("player") or "Player")

    preview = { holder = holder, mock = mock, icons = {} }
    Panel.RefreshPreview()

    if F and F.NewMessageOwner then
        F.NewMessageOwner():RegisterMessage("PartyCooldownsChanged", Panel.RefreshPreview)
        F.NewMessageOwner():RegisterMessage("ProfileChanged", Panel.RefreshPreview)
    end
end

-- Search: reopen the tab a result was indexed under, and build each tab
-- once so search knows them all; the tab the player left is restored.
function Panel.Select(scope)
    if type(scope) ~= "table" or not scope.tab then return end
    activeTab = scope.tab
    if rebuildFields then rebuildFields() end
end

function Panel.IndexAll()
    if not rebuildFields then return end
    local saved = activeTab
    for _, tab in ipairs(TABS) do
        activeTab = tab.key
        rebuildFields()
    end
    activeTab = saved
    rebuildFields()
end
