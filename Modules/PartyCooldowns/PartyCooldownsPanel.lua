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
