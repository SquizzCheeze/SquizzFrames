--[[ SquizzFrames Party Cooldowns options page (Tools group)

    A pure shell over PartyCooldowns.Get / .Set -- every control reads and
    writes through the module, which owns the defaults and fires
    "PartyCooldownsChanged". Nothing here touches the icons directly.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local L = SquizzFrames.L or {}
local W = SquizzFrames.Widgets

local Panel = {}
SquizzFrames.PartyCooldownsPanel = Panel

local NOTE_WIDTH = 420

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

local function Note(host, y, text)
    local fs = host:CreateFontString(nil, "OVERLAY")
    fs:SetFontObject("GameFontDisableSmall")
    fs:SetPoint("TOPLEFT", 32, y)
    fs:SetWidth(NOTE_WIDTH)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return y - math.ceil(fs:GetStringHeight() or 24) - 12
end

-- Spells (stage 4): one checkbox per tracked spell, grouped by class, two
-- columns. Unticking hides that cooldown on every frame.
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
    return order
end

function Panel.BuildSpellList(frame, host, y)
    local M = Mod()
    local DATA = SquizzFrames.PartyCooldownsData
    if not (M and DATA) then return y end

    W.CreateTitledPane(host, L["Spells"] or "Spells", y)
    y = y - 35

    local allOn = W.CreateStyledButton(host, L["All On"] or "All On", "accent-hover", {80, 22}, function()
        M.SetAllSpellsEnabled(true)
        Panel.Build(frame)
    end)
    allOn:SetPoint("TOPLEFT", 15, y)
    local allOff = W.CreateStyledButton(host, L["All Off"] or "All Off", "accent-hover", {80, 22}, function()
        M.SetAllSpellsEnabled(false)
        Panel.Build(frame)
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
            local header = host:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            header:SetPoint("TOPLEFT", 15, y)
            header:SetText(color and ("|c" .. color.colorStr .. name .. "|r") or name)
            y = y - 24

            for i, def in ipairs(list) do
                local col = (i - 1) % 2 + 1
                local icon = C_Spell.GetSpellTexture(def.key)
                local label = (C_Spell.GetSpellName(def.key) or tostring(def.key))
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

function Panel.Build(frame)
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

    local y = -10
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
    }) do
        local cb = W.CreateStyledCheckbox(host, item[2], get(item[1]), set(item[1]))
        cb:SetPoint("TOPLEFT", 15, y)
        y = y - 30
    end
    y = y - 10

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

    local sMax = W.CreateStyledSlider(host, 200, 1, 12, 1, L["Max Icons"] or "Max Icons", get("maxIcons"), set("maxIcons"))
    sMax:SetPoint("TOPLEFT", 15, y - 20)
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
    y = y - 75

    y = Panel.BuildSpellList(frame, host, y)

    -- Test icons are for while the page is open; leaving them on would draw
    -- fake cooldowns on real frames.
    if not frame._sfPartyCDHook then
        frame._sfPartyCDHook = true
        frame:HookScript("OnHide", function()
            local M = Mod()
            if M and M.IsTestMode() then M.SetTestMode(false) end
        end)
    end
end
