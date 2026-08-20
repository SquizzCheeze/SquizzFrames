--[[ SquizzFrames IndicatorsPanel.lua - Indicators options panel ]]
--
-- The single "Indicators" page: preview canvas on top, indicator list +
-- settings below (a Built-in/Custom switch above the list replaces what used
-- to be separate sidebar sub-pages/a separate "Designer" page -- one page
-- handles selecting, previewing/dragging, and editing all in one view).
--
-- On change, every widget fires:
--   SquizzFrames:Fire("UpdateIndicators", indicatorName, setting, value, value2)
-- which the runtime (Indicators.lua) consumes to update all buttons + preview.

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local W = SquizzFrames.Widgets
local F = SquizzFrames.F
local L = SquizzFrames.L

-----------------------------------------------------------------------
-- State
-----------------------------------------------------------------------
local parent             -- the tab content frame
local listPane           -- left list pane (bottom-left)
local listScroll         -- scroll frame for the list rows
local settingsPane       -- right settings pane (bottom-right)
local settingsScroll     -- scroll frame for settings widgets
local settingsTitle      -- "Indicator Settings" / "Custom Indicators" label above settingsScroll
local customIndicatorsPane -- dedicated "Custom Indicators" manager view (Add Indicator + list), shown instead of settingsScroll
local previewBG, previewButton -- preview canvas (top)
local selectedName       -- currently selected indicatorName
local listButtons = {}   -- row buttons in the left list
local selectedButton     -- currently selected row button

-- Which indicator list (Party/Raid) the Designer is currently editing --
-- "main" or "raid", mirroring OptionsFrame.lua's Layout tab activeLayoutKey.
-- Every read (GetIndicatorList) and write (FireUpdate) below funnels through
-- this single key, so the whole page becomes context-aware just by toggling
-- it (see the Party/Raid toggle buttons built in Build()).
local activeIndicatorLayoutKey = "main"

local DEFAULT_PREVIEW_SCALE = 2

-- Real configured button dimensions for whichever tab is active (Layout
-- tab's Party/Raid sizes are independent -- 100x40 vs 70x24 by default), not
-- an arbitrary mock size -- so percentage-based settings (textWidth,
-- position offsets, etc) look exactly like they will on the actual frame
-- instead of being proportioned against a fake or wrong-context box. The
-- Scale slider is a separate, pure magnification convenience on top of this
-- -- it doesn't change these proportions, only how big the whole thing
-- renders on screen.
local function GetRealButtonDimensions()
    local l = SquizzFrames.db and SquizzFrames.db.profile and SquizzFrames.db.profile.layout
        and SquizzFrames.db.profile.layout[activeIndicatorLayoutKey]
    if activeIndicatorLayoutKey == "raid" then
        return (l and l.width) or 70, (l and l.height) or 24, (l and l.powerHeight) or 3
    end
    return (l and l.width) or 100, (l and l.height) or 40, (l and l.powerHeight) or 4
end

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

-- Resolves whichever list activeIndicatorLayoutKey currently points at
-- ("main" -> profile.layout.indicators, "raid" -> .indicatorsRaid) -- every
-- read/write in this file funnels through this (via GetIndicatorList) and
-- FireUpdate, so toggling the key alone makes the whole page context-aware.
local function IndicatorListKey()
    return activeIndicatorLayoutKey == "raid" and "indicatorsRaid" or "indicators"
end

local function GetIndicatorList()
    -- Primary: live DB (loaded profile, same table the runtime mutates).
    local key = IndicatorListKey()
    local list = SquizzFrames.db and SquizzFrames.db.profile
        and SquizzFrames.db.profile.layout
        and SquizzFrames.db.profile.layout[key]
    if list and #list > 0 then return list end
    -- Fallback 1: SquizzFrames.defaults (should match DB on a fresh profile).
    local defList = SquizzFrames.defaults and SquizzFrames.defaults.profile
        and SquizzFrames.defaults.profile.layout
        and SquizzFrames.defaults.profile.layout[key]
    if defList and #defList > 0 then return defList end
    -- Fallback 2: the addon saved no layout table at all (corrupt/partial SV).
    -- Build a fresh list from IndicatorDefaults.BUILT_IN_NAMES so the panel is
    -- never empty. These tables are not persisted (DB may be read-only here),
    -- but they let the user interact with the options UI.
    local names = SquizzFrames.IndicatorDefaults and SquizzFrames.IndicatorDefaults.BUILT_IN_NAMES
    if names then
        -- Use a stable order matching Layout_Defaults.lua's indicatorIndices.
        local order = {
            "nameText", "healthText", "powerText", "statusText", "statusIcon",
            "roleIcon", "leaderIcon", "playerRaidIcon", "aggroBlink",
            "aggroBorder", "shieldBar", "externalCooldowns", "defensiveCooldowns",
            "debuffs", "ccIndicator", "dispels", "missingBuffs", "targetHighlight",
            "hoverHighlight", "frameBorder",
        }
        local built = {}
        for _, indicatorName in ipairs(order) do
            if names[indicatorName] then
                built[#built + 1] = {
                    name = names[indicatorName], indicatorName = indicatorName,
                    type = "built-in", enabled = true,
                    position = {"CENTER", "button", "CENTER", 0, 0}, frameLevel = 1,
                }
            end
        end
        if #built > 0 then return built end
    end
    return {}
end

local function FindIndicator(name)
    for _, t in ipairs(GetIndicatorList()) do
        if t.indicatorName == name then return t end
    end
    return nil
end

local function FireUpdate(indicatorName, setting, value, value2)
    SquizzFrames:Fire("UpdateIndicators", indicatorName, setting, value, value2, activeIndicatorLayoutKey == "raid")
end

-- Height estimates for each token's widget (matches IndicatorWidgets.lua).
-- Freshly-created widgets return 0 from GetHeight before layout runs, so we
-- use a fixed estimate per token to stack them vertically.
local TOKEN_HEIGHTS = {
    ["enabled"] = 38,
    -- 199/185 = the widget's real built height including its title row (see
    -- CreateSetting_Position). SF_CreateFrame clips children, so an
    -- underestimate here silently cuts off the bottom slider.
    ["position"] = 199,
    ["position-noHCenter"] = 199,
    -- Anchor Point + Relative Point row, then X/Y offsets (no Relative To
    -- row, unlike "position") -- see CreateSetting_DurationPosition.
    ["durationPosition"] = 148,
    ["textScale"] = 75,
    ["textWidth"] = 58,
    ["font"] = 259,
    -- estimateTokenHeight looks up the RAW token string (tokens[i]), not the
    -- normalized "font1"/"font2" name used elsewhere for binding -- real
    -- token lists always carry the ":stackFont"/":durationFont" suffix (see
    -- IndicatorDefaults.lua), so the bare ["font1"]/["font2"] keys below are
    -- dead for every actual indicator and every font1/font2 widget fell
    -- through to the generic "^font" pattern fallback (130) instead of its
    -- real built height -- a 43px undercount on the LAST token in 11
    -- different indicator lists (externalCooldowns, debuffs, ccIndicator,
    -- etc.), which is what was clipping the bottom of those panels. The
    -- widget's own real height was ALSO wrong (see CreateSetting_Font's
    -- comment) -- its 8-row stack lays out ~224px deep with SetClipsChildren
    -- enabled, clipping the Y Offset slider/color picker at the old 173px.
    ["font1"] = 259,
    ["font2"] = 259,
    ["font1:stackFont"] = 259,
    ["font2:durationFont"] = 259,
    ["font-noOffset"] = 200,
    ["auras"] = 108,
    -- These share CreateSetting_Auras' cached "auras_1" widget (108px) but
    -- had no exact-key entry, so they fell through to the bare 75 fallback
    -- -- another 33px undercount stacking on top of the font1/font2 one
    -- above for externalCooldowns/defensiveCooldowns specifically.
    ["customExternals"] = 108,
    ["customDefensives"] = 108,
    ["customMissingBuffs"] = 108,
    ["customAoEHealings"] = 108,
    ["customCrowdControls"] = 108,
    ["targetedSpellsList"] = 108,
    ["debuffBlacklist"] = 240,
    ["dispelBlacklist"] = 108,
    ["bigDebuffCC"] = 50,
    ["dispelFilters"] = 130,
    ["filters"] = 160,
    -- ROW_HEIGHT (34) below: converted to IndicatorWidgets.lua's
    -- LayoutDropdownRow (label left, dropdown right-aligned, single row) --
    -- these used to be 58/75 (label above, dropdown below).
    ["glowOptions"] = 34,
    ["glow"] = 34,
    ["targetedSpellsGlow"] = 58,
    ["customColors"] = 58,
    ["overlayColors"] = 58,
    ["blockColors"] = 58,
    ["colors"] = 58,
    ["vehicleNamePosition"] = 75,
    ["statusPosition"] = 58,
    ["anchor"] = 34,
    ["size"] = 75,
    ["size-square"] = 75,
    ["size-normal-big"] = 75,
    ["size-border"] = 75,
    ["spacing"] = 75,
    ["thickness"] = 75,
    ["height"] = 75,
    ["alpha"] = 75,
    ["num"] = 75,
    ["numPerLine"] = 75,
    ["orientation"] = 34,
    ["growthOrientation"] = 68,
    ["barOrientation"] = 34,
    ["durationVisibility"] = 34,
    ["durationVisibilitySimple"] = 34,
    ["durationOffset"] = 75,
    ["duration"] = 38,
    ["stack"] = 38,
    ["roleTexture"] = 34,
    ["highlightType"] = 34,
    ["texture"] = 34,
    ["barTexture"] = 34,
    ["builtInExternals"] = 280,
    ["builtInDefensives"] = 280,
    ["builtInAoEHealings"] = 280,
    ["builtInCrowdControls"] = 280,
    ["builtInMissingBuffs"] = 280,
    ["builtInHots"] = 280,
    ["actionsPreview"] = 38,
    ["actionsList"] = 38,
    ["color"] = 38,
    ["color-alpha"] = 38,
    ["glowColor"] = 38,
    ["expiringColor"] = 96,
    ["color-class"] = 38,
    ["color-power"] = 38,
    ["statusColors"] = 38,
    ["castBy"] = 34,
    ["maxValue"] = 38,
    ["iconStyle"] = 34,
    ["targetedSpellsDisplayMode"] = 38,
    ["shape"] = 34,
    ["privateAuraOptions"] = 38,
    ["warning"] = 38,
    ["thresholds"] = 38,
    ["targetCounterFilters"] = 130,
    ["powerTextFilters"] = 130,
    ["dispelShowAll"] = 34,
    ["dispelTypeColors"] = 190,
    ["dispelTypes"] = 110,
    ["dispelOverlay"] = 34,
    ["dispelOverlayOpacity"] = 75,
    ["dispelGradientHeight"] = 75,
    ["dispelGradientWeakAlpha"] = 75,
    ["healthFormat"] = 75,
    ["powerFormat"] = 75,
    ["frameLevel"] = 58, -- matches CreateSetting_FrameLevel's frame height (dropdown, was a 75px slider)
    ["checkbutton"] = 38,
    ["checkbutton2"] = 38,
    ["checkbutton3"] = 38,
    ["checkbutton4"] = 38,
    ["checkbutton5"] = 38,
}
local function estimateTokenHeight(token)
    if TOKEN_HEIGHTS[token] then return TOKEN_HEIGHTS[token] end
    if token:match("^font") then return 130 end
    if token:match("^num") then return 75 end
    if token:match("^frameLevel") then return 75 end
    if token:match("^checkbutton") then return 38 end
    return 75
end

-----------------------------------------------------------------------
-- Left list: build rows for every indicator (20px)
-----------------------------------------------------------------------

local LIST_ROW_HEIGHT = 20
local LIST_HEADER_HEIGHT = 18
local LIST_HEADER_GAP = 5 -- extra breathing room before every header but the first

-- Healer-workflow grouping for the indicator list -- "where's the thing that
-- tracks my HoTs" should be a one-glance answer instead of scanning 18 items
-- in whatever order they're defined in code. Only built-in indicators get
-- their own rows here now -- custom indicators don't appear in this list at
-- all; they're managed entirely from the single "Custom Indicators >" entry
-- injected into CUSTOM_INDICATORS_HOME_CATEGORY below, which opens the
-- dedicated manager pane instead of listing each one individually.
local CATEGORY_ORDER = { "Vitals", "My HoTs & Heals", "Debuffs to Dispel", "Defensives Available", "Alerts", "Other" }
local CUSTOM_INDICATORS_HOME_CATEGORY = "My HoTs & Heals"
local INDICATOR_CATEGORY = {
    nameText = "Vitals", healthText = "Vitals", powerText = "Vitals",
    healerHots = "My HoTs & Heals",
    debuffs = "Debuffs to Dispel", dispels = "Debuffs to Dispel", dispelIcons = "Debuffs to Dispel",
    -- "CC Indicator" (big centered icon, was "Raid Debuffs") reads more as
    -- an urgent "you're about to be crowd-controlled" alert than a dispel
    -- tool, so it lives in Alerts instead of the Debuffs to Dispel group.
    ccIndicator = "Alerts",
    externalCooldowns = "Defensives Available", defensiveCooldowns = "Defensives Available",
    statusText = "Alerts", statusIcon = "Alerts", aggroBlink = "Alerts", aggroBorder = "Alerts",
    targetHighlight = "Alerts", hoverHighlight = "Alerts",
    roleIcon = "Alerts", playerRaidIcon = "Alerts", leaderIcon = "Alerts",
    shieldBar = "Vitals", shieldOverlay = "Vitals", healAbsorb = "Vitals",
    missingBuffs = "Other",
}

-- Category for a built-in indicator (falls back to "Other" for one nobody's
-- filed yet). Only ever called with built-in indicators now.
local function GetIndicatorCategory(t)
    return INDICATOR_CATEGORY[t.indicatorName] or "Other"
end

-- Selected row previously only got an accent-colored TEXT tint -- easy to
-- miss against the same background as every other row, especially since the
-- hover tint (warm brownish-gold) reads similarly at a glance. Now also
-- tints the row's own background with the accent color so the selected
-- indicator is unambiguous even without reading the text color.
local ROW_BG_NORMAL = {0.1, 0.1, 0.08, 0.9}
local ROW_BG_HOVER = {0.25, 0.2, 0.1, 0.95}
local function UpdateRowVisual(btn)
    if not btn then return end
    local text = btn.fontString
    local icon = btn.iconTex
    if selectedButton == btn then
        local a = F.GetAccentColor()
        if text then text:SetTextColor(a.r, a.g, a.b, 1) end
        if icon then icon:SetAlpha(0.85) end
        if btn.SetBackdropColor then btn:SetBackdropColor(a.r, a.g, a.b, 0.3) end
    elseif btn.enabled then
        if text then text:SetTextColor(1, 1, 1, 1) end
        if icon then icon:SetAlpha(0.55) end
        if btn.SetBackdropColor then btn:SetBackdropColor(unpack(ROW_BG_NORMAL)) end
    else
        if text then text:SetTextColor(0.47, 0.47, 0.47, 1) end
        if icon then icon:SetAlpha(0.15) end
        if btn.SetBackdropColor then btn:SetBackdropColor(unpack(ROW_BG_NORMAL)) end
    end
end

-- Forward declarations: both are defined after BuildIndicatorList (which
-- references them from row-click closures) so they can call back into it.
-- Lua hoists these locals to the top of the block; assignment happens when
-- the later `ShowSettings = function` / `ShowCustomIndicatorsManager =
-- function` statements execute during file load.
local ShowSettings
local ShowCustomIndicatorsManager

local function SelectIndicator(name)
    -- Clear the OLD selection before resetting its visual: UpdateRowVisual
    -- compares against the module-level `selectedButton`, so resetting it
    -- while that variable still points at the same button just re-applies
    -- the highlight instead of clearing it, leaving every previously
    -- selected row stuck highlighted.
    local oldButton = selectedButton
    selectedButton = nil
    if oldButton then UpdateRowVisual(oldButton) end
    selectedName = name
    for _, btn in ipairs(listButtons) do
        if btn.indicatorName == name then
            selectedButton = btn
            local a = F.GetAccentColor()
            if btn.fontString then btn.fontString:SetTextColor(a.r, a.g, a.b, 1) end
            if btn.iconTex then btn.iconTex:SetAlpha(0.85) end
            break
        end
    end
    -- Show animated highlight on preview button for the selected indicator
    if SquizzFrames.Indicators then SquizzFrames.Indicators.ShowPreviewHighlight(name) end
    ShowSettings(name)
end

-- Creates one plain (non-interactive) category header row at the given
-- y-offset (in scrollChild's own coordinate space) and returns the new y
-- after it.
local function CreateCategoryHeaderRow(scrollChild, category, y)
    local header = CreateFrame("Frame", nil, scrollChild)
    header:SetHeight(LIST_HEADER_HEIGHT)
    header:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -y)
    header:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, -y)

    local swatch = header:CreateTexture(nil, "ARTWORK")
    swatch:SetSize(5, 5)
    swatch:SetPoint("LEFT", 5, 0)
    local accent = F.GetAccentColor()
    swatch:SetColorTexture(accent.r, accent.g, accent.b, 1)

    local headerText = header:CreateFontString(nil, "OVERLAY")
    headerText:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    headerText:SetPoint("LEFT", swatch, "RIGHT", 5, 0)
    headerText:SetWordWrap(false)
    headerText:SetTextColor(0.85, 0.83, 0.78, 1)
    headerText:SetText(category:upper())

    local divider = header:CreateTexture(nil, "BACKGROUND")
    divider:SetPoint("BOTTOMLEFT", 0, 1)
    divider:SetPoint("BOTTOMRIGHT", 0, 1)
    divider:SetHeight(1)
    divider:SetColorTexture(1, 1, 1, 0.12)

    listButtons[#listButtons + 1] = header
    return y + LIST_HEADER_HEIGHT
end

-- Creates one clickable list row styled the same as a real indicator row.
-- Used both for real built-in indicators (onClick selects them) and for the
-- single synthetic "Custom Indicators" entry (onClick opens the manager
-- pane instead of selecting anything).
local function CreateListRow(scrollChild, y, displayText, indicatorName, enabled, onClick, textColor)
    local btn = CreateFrame("Button", nil, scrollChild, "BackdropTemplate")
    btn:SetHeight(LIST_ROW_HEIGHT)
    btn:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -y)
    btn:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, -y)

    btn:SetBackdrop({ bgFile = [[Interface\Buttons\WHITE8X8]] })
    btn:SetBackdropColor(unpack(ROW_BG_NORMAL))

    local text = btn:CreateFontString(nil, "OVERLAY")
    text:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    text:SetPoint("LEFT", 5, 0)
    text:SetPoint("RIGHT", -6, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    text:SetText(displayText)
    if textColor then text:SetTextColor(textColor[1], textColor[2], textColor[3], 1) end
    btn.fontString = text

    btn.indicatorName = indicatorName
    btn.enabled = enabled

    btn:SetScript("OnClick", onClick)
    btn:SetScript("OnEnter", function(self)
        if selectedButton ~= self then
            self:SetBackdropColor(unpack(ROW_BG_HOVER))
        end
    end)
    -- Re-derive the row's own state instead of hardcoding the default
    -- background -- previously this unconditionally reset even the
    -- SELECTED row's background when the mouse left it, undoing its
    -- highlight. Skipped for rows with an explicit textColor (the "Custom
    -- Indicators" entry) -- UpdateRowVisual's enabled/disabled branches
    -- would otherwise stomp that color back to plain white immediately.
    if textColor then
        btn:SetScript("OnLeave", function(self) self:SetBackdropColor(unpack(ROW_BG_NORMAL)) end)
    else
        btn:SetScript("OnLeave", function(self) UpdateRowVisual(self) end)
        UpdateRowVisual(btn)
    end
    listButtons[#listButtons + 1] = btn
    return y + LIST_ROW_HEIGHT + 1
end

local function BuildIndicatorList()
    if not listScroll then return end
    -- Clear previous rows (both indicator buttons and category headers).
    for _, btn in ipairs(listButtons) do
        btn:Hide()
        btn:SetParent(nil)
    end
    wipe(listButtons)
    selectedButton = nil

    local fullList = GetIndicatorList()
    local scrollChild = listScroll.scrollChild
    if not scrollChild then return end

    -- Ensure scrollChild width matches the scroll frame's current width.
    -- (CreateScrollFrame sets content width at creation time; if the parent
    -- was 0x0 then, the content width would be 1px and rows would be invisible.)
    local sfWidth = listScroll:GetWidth()
    if sfWidth and sfWidth > 1 then
        scrollChild:SetWidth(sfWidth)
    end

    -- Two-level walk: category, then built-in indicators within it. Custom
    -- indicators never get rows here at all -- only the single "Custom
    -- Indicators >" entry, injected as a normal row (not a header) inside
    -- CUSTOM_INDICATORS_HOME_CATEGORY, opens the manager pane where every
    -- custom indicator actually lives.
    local y = 0
    local firstCategory = true
    local accent = F.GetAccentColor()
    for _, category in ipairs(CATEGORY_ORDER) do
        local items = {}
        for _, t in ipairs(fullList) do
            -- targetHighlight/hoverHighlight/frameBorder moved to the Layout
            -- tab (they're simple always-relevant frame borders, grouped
            -- there with the rest of the frame's appearance settings instead
            -- of living alongside aura/cooldown indicators) -- excluded from
            -- this list so there's exactly one place to configure them, not two.
            if t.type == "built-in" and t.indicatorName ~= "targetHighlight"
               and t.indicatorName ~= "hoverHighlight" and t.indicatorName ~= "frameBorder"
               and GetIndicatorCategory(t) == category then
                items[#items + 1] = t
            end
        end

        if not firstCategory then y = y + LIST_HEADER_GAP end
        firstCategory = false
        y = CreateCategoryHeaderRow(scrollChild, category, y)

        for _, t in ipairs(items) do
            local names = SquizzFrames.IndicatorDefaults and SquizzFrames.IndicatorDefaults.BUILT_IN_NAMES or {}
            local displayName = names[t.indicatorName] or t.name or t.indicatorName
            y = CreateListRow(scrollChild, y, displayName, t.indicatorName, t.enabled,
                function(self) SelectIndicator(self.indicatorName) end)
        end

        if category == CUSTOM_INDICATORS_HOME_CATEGORY then
            y = CreateListRow(scrollChild, y, "Custom Indicators  >", nil, true,
                function() ShowCustomIndicatorsManager() end,
                {accent.r, accent.g, accent.b})
        end
    end

    -- Bypasses SetContentHeight (which assumes every row is the same fixed
    -- height) since headers and indicator rows differ in height here.
    scrollChild:SetHeight(math.max(1, y))
    listScroll:UpdateScrollChildRect()

    -- Re-apply selection.
    if selectedName then
        for _, btn in ipairs(listButtons) do
            if btn.indicatorName == selectedName then
                selectedButton = btn
                local a = F.GetAccentColor()
                if btn.fontString then btn.fontString:SetTextColor(a.r, a.g, a.b, 1) end
                break
            end
        end
    end
end

-----------------------------------------------------------------------
-- Right pane: token-driven settings builder
-----------------------------------------------------------------------

local function ClearSettings()
    local scrollChild = settingsScroll and settingsScroll.scrollChild
    if not scrollChild then return end
    -- Hide all cached indicator widgets via the dispatcher (never SetParent:
    -- orphaned frames persist onscreen in retail WoW).
    if SquizzFrames.ClearIndicatorSettings then SquizzFrames.ClearIndicatorSettings() end
    -- Hide any FontString children this panel created ("Select an indicator.",
    -- "No settings for this indicator.", fallback "(token)" tips, etc.).
    local children = { scrollChild:GetChildren() }
    for _, child in ipairs(children) do
        if child:IsObjectType("FontString") then
            child:Hide()
            child:ClearAllPoints()
        end
    end
    local regions = { scrollChild:GetRegions() }
    for _, r in ipairs(regions) do r:Hide() end
end

local function SetField(indicatorTable, field, val)
    indicatorTable[field] = val
    FireUpdate(indicatorTable.indicatorName, field, val)
    if field == "enabled" then BuildIndicatorList() end
end

-----------------------------------------------------------------------
-- Binding block: wire each built widget into the DB table via SetFunc /
-- SetDBValue, mirroring the upstream ShowIndicatorSettings logic.
-----------------------------------------------------------------------

-- Ensure a font table slot exists (either flat or 2D) and return it.
local function EnsureFontTable(it)
    if not it.font then
        it.font = {
            {"Friz QT__", 11, "OUTLINE", false, "TOPRIGHT", 2, 1, {1, 1, 1}},
            {"Friz QT__", 11, "OUTLINE", false, "BOTTOMRIGHT", 2, -1, {1, 1, 1}},
        }
    end
    return it.font
end

local function GetFontSlot(it, idx)
    -- Flat single-tuple shape (nameText/statusText): the table IS the slot.
    if it.font and type(it.font[1]) == "string" then return it.font end
    -- Then ensure the two-slot table exists. This used to start with
    -- `if not it.font then return nil end`, which made the EnsureFontTable
    -- call below unreachable in exactly the case it was written for: an
    -- indicator carrying font1/font2 tokens but no font default shipped a
    -- fully functional-looking Stack/Duration Font block bound to nothing, so
    -- every edit was silently discarded. Healer HoTs hit this the moment it
    -- gained those tokens. The defaults are also filled in properly now, so
    -- this is belt and braces -- but it's what stops the next indicator
    -- repeating it.
    local ft = EnsureFontTable(it)
    while #ft < idx do
        ft[#ft + 1] = {"Friz QT__", 11, "OUTLINE", false, "BOTTOMRIGHT", 2, -1, {1, 1, 1}}
    end
    return ft[idx]
end

-- Build the right pane for the selected indicator. Called via the
-- forward-declared `local ShowSettings`.
ShowSettings = function(name)
    selectedName = name
    -- Selecting any real indicator (built-in or custom) switches back to the
    -- normal per-indicator settings view -- undoes ShowCustomIndicatorsManager
    -- having swapped it out for the Add Indicator/list view.
    if customIndicatorsPane then customIndicatorsPane:Hide() end
    if settingsScroll then settingsScroll:Show() end
    if settingsTitle then settingsTitle:SetText("|cffffd100Indicator Settings|r") end
    local scrollChild = settingsScroll and settingsScroll.scrollChild
    if not scrollChild then return end

    local sfWidth = settingsScroll:GetWidth()
    if sfWidth and sfWidth > 1 then scrollChild:SetWidth(sfWidth) end

    -- Show animated highlight around the selected indicator in preview
    if SquizzFrames.Indicators then
        if name then
            SquizzFrames.Indicators.ShowPreviewHighlight(name)
        else
            SquizzFrames.Indicators.HidePreviewHighlight()
        end
    end

    ClearSettings()

    local t = FindIndicator(name)
    if not t then
        local fs = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontRed")
        fs:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, -2)
        fs:SetText("Select an indicator.")
        settingsScroll:SetContentHeight(1)
        return
    end

    local tokens
    if t.type == "built-in" then
        tokens = SquizzFrames.IndicatorDefaults and SquizzFrames.IndicatorDefaults.BUILT_IN_SETTINGS
            and SquizzFrames.IndicatorDefaults.BUILT_IN_SETTINGS[name]
    else
        tokens = SquizzFrames.IndicatorDefaults and SquizzFrames.IndicatorDefaults.CUSTOM_SETTINGS
            and SquizzFrames.IndicatorDefaults.CUSTOM_SETTINGS[t.type]
    end

    if not tokens then
        local fs = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        fs:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, -2)
        fs:SetText("No settings for this indicator.")
        settingsScroll:SetContentHeight(1)
        return
    end

    -- Build widgets from the token list via SquizzFrames.CreateIndicatorSettings
    local ok, widgets = pcall(SquizzFrames.CreateIndicatorSettings, scrollChild, tokens, t.type)
    if not ok then
        print("|cffff0009[SquizzFrames]|r CreateIndicatorSettings error for " .. tostring(name) .. ": " .. tostring(widgets))
        return
    end

    -- Build a flat setting-name list mirroring tokens. The binding block
    -- below keys off these names, so they must match the widget's expected
    -- SetDBValue/SetFunc argument signatures.
    local names = {}
    for _, token in ipairs(tokens) do
        if token:match("^num:") then
            names[#names + 1] = "num"
        elseif token:match("^numPerLine:") then
            names[#names + 1] = "numPerLine"
        elseif token:match("^frameLevel") then
            names[#names + 1] = "frameLevel"
        elseif token:match("^checkbutton%d*:") then
            -- Store generic name so binding block matches; key extracted from token there.
            names[#names + 1] = "checkbutton"
        elseif token:match("^font%d+:") then
            -- "font1:stackFont" / "font2:durationFont" → "font1" / "font2"
            local slotNum = token:match("^font(%d+)")
            names[#names + 1] = "font" .. slotNum
        elseif token:match("^font%-noOffset") then
            local paired = token:match("^font%-noOffset:(.+)")
            names[#names + 1] = (paired == "durationFont") and "font2" or "font1"
        elseif token == "orientationCenterable" then
            -- Different WIDGET (adds a "center" option -- see
            -- IndicatorWidgets.lua's CreateSetting_OrientationCenterable),
            -- but the same underlying setting as plain "orientation" --
            -- binds through the identical t.orientation/SetOrientation path.
            names[#names + 1] = "orientation"
        else
            names[#names + 1] = token
        end
    end

    -- Shared helpers for slot-based font tokens
    local function SetFontUpdate()
        FireUpdate(t.indicatorName, "font", t.font)
    end

    -- Per-widget binding: SetFunc wires the value-change callback; SetDBValue
    -- populates the widget from the DB table.
    for i, w in ipairs(widgets) do
        if not w then break end
        local token = tokens[i]
        local n = names[i] or token
        local isBuiltIn = (t.type == "built-in")

        -- Enabled
        if n == "enabled" then
            w:SetFunc(function(checked)
                t.enabled = checked
                FireUpdate(t.indicatorName, "enabled", checked)
                BuildIndicatorList()
            end)
            w:SetDBValue(isBuiltIn and t.enabled or t.enabled)

        -- Warning banner
        elseif token == "warning" or token:match("^warning:") then
            w:SetDBValue("")
            w:SetFunc(function() end)

        -- CheckButtons (general + N-suffixed)
        elseif n == "checkbutton" then
            local key = token:match("^checkbutton%d*:(.+)") or "Option"
            -- Note: the checkbox widget already carries its own label
            -- (built by CreateSetting_Checkbutton), so no label map is needed here.
            if w.SetDBValue then w:SetDBValue(key, t[key]) end
            w:SetFunc(function(val)
                t[key] = val
                FireUpdate(t.indicatorName, "checkbutton", key, val)
                -- Also fire under the field's own name: most checkbutton-driven
                -- fields (showAnimation, showStack, etc.) are only read on the
                -- next aura scan, so the generic "checkbutton" event above is
                -- enough. But AuraEngine-backed indicators (e.g. dispels'
                -- showDispelIcons) apply changes live via a dedicated Set*
                -- method keyed on the field name -- this is a no-op for
                -- everything else since ApplySettingToOne only reacts to
                -- setting names it explicitly knows.
                FireUpdate(t.indicatorName, key, val)
            end)

        -- Duration/stack text size (Private Auras only). Stored as a plain
        -- multiplier; the widget presents it as a percentage.
        elseif n == "textScale" then
            w:SetDBValue(t.textScale or 1)
            w:SetFunc(function(val)
                t.textScale = val
                FireUpdate(t.indicatorName, "textScale", val)
            end)

        -- Duration text position (Private Auras only) -- 4 fields:
        -- {anchorPoint, relativePoint, xOffset, yOffset}. No relativeTo,
        -- because Blizzard's durationAnchor can only bind to the aura's own
        -- holder frame (for the since-removed Private Auras indicator).
        elseif n == "durationPosition" then
            w:SetDBValue(t.durationPosition or {"BOTTOMRIGHT", "BOTTOMRIGHT", 0, 0})
            w:SetFunc(function(pos)
                t.durationPosition = pos
                FireUpdate(t.indicatorName, "durationPosition", pos)
            end)

        -- Position (full 5-field widget: anchor, relativeTo, relativePoint, x, y)
        elseif n == "position" then
            local default = t.position or {"CENTER", "button", "CENTER", 0, 0}
            w:SetDBValue(default)
            w:SetFunc(function(pos)
                t.position = pos
                FireUpdate(t.indicatorName, "position", pos)
            end)

        -- Vehicle name position (TOP/BOTTOM/HIDDEN + y)
        elseif n == "vehicleNamePosition" then
            local default = t.vehicleNamePosition or {"TOP", 0}
            w:SetDBValue(default)
            w:SetFunc(function(vnp)
                t.vehicleNamePosition = vnp
                FireUpdate(t.indicatorName, "vehicleNamePosition", vnp)
            end)

        -- Status position
        elseif n == "statusPosition" then
            w:SetDBValue(t.statusPosition or "LEFT")
            w:SetFunc(function(pos)
                t.statusPosition = pos
                FireUpdate(t.indicatorName, "statusPosition", pos)
            end)

        -- Anchor
        elseif n == "anchor" then
            w:SetDBValue(t.anchor or "healthbar-current")
            w:SetFunc(function(anchor)
                t.anchor = anchor
                FireUpdate(t.indicatorName, "anchor", anchor)
            end)

        -- Size (width+height)
        elseif n == "size" then
            local default = t.size or {13, 13}
            if not isBuiltIn then
                w:SetDBValue(default)
            else
                w:SetDBValue(default)
            end
            w:SetFunc(function(size)
                t.size = size
                FireUpdate(t.indicatorName, "size", size)
            end)

        -- Size-square
        elseif n == "size-square" then
            local default = t.size or {13, 13}
            w:SetDBValue(default)
            w:SetFunc(function(size)
                t.size = size
                FireUpdate(t.indicatorName, "size", size)
            end)

        -- Size normal+big. t.size is stored as the WHOLE pair here --
        -- {{normalW,normalH}, {bigW,bigH}} -- matching debuffs' actual
        -- default data shape and what HandleIndicators' generic size
        -- handling expects (it unwraps sz[1] when sz[1] is itself a table).
        elseif n == "size-normal-big" then
            local default = {{10, 10}, {15, 15}}
            if t.size then
                if type(t.size[1]) == "table" then
                    default = t.size
                else
                    default = {t.size, {t.size[1] + 5, t.size[2] + 5}}
                end
            end
            w:SetDBValue(default)
            w:SetFunc(function(sizeTable)
                t.size = sizeTable
                FireUpdate(t.indicatorName, "size", sizeTable)
            end)

        -- Size + border (raid debuffs)
        elseif n == "size-border" then
            local default = t.size or {13, 13}
            local border = t.border or 1
            w:SetDBValue(default, border)
            w:SetFunc(function(sizeTable, borderVal)
                t.size = sizeTable
                t.border = borderVal
                FireUpdate(t.indicatorName, "size-border", t)
            end)

        -- Spacing
        elseif n == "spacing" then
            local default = t.spacing or {2, 2}
            w:SetDBValue(default)
            w:SetFunc(function(spacing)
                t.spacing = spacing
                FireUpdate(t.indicatorName, "spacing", spacing)
            end)

        -- Thickness
        elseif n == "thickness" then
            w:SetDBValue(t.thickness or 2)
            w:SetFunc(function(n2) SetField(t, "thickness", n2) end)

        -- Height
        elseif n == "height" then
            w:SetDBValue(t.height or 4)
            w:SetFunc(function(n2) SetField(t, "height", n2) end)

        -- Alpha
        elseif n == "alpha" then
            w:SetDBValue(t.alpha or 1)
            w:SetFunc(function(a) SetField(t, "alpha", a) end)

        -- Text width (unlimited/percentage/length)
        elseif n == "textWidth" then
            local default = t.textWidth or {"percentage", 0.75}
            if default ~= "unlimited" and type(default) ~= "table" then default = {"percentage", 0.75} end
            w:SetDBValue(default)
            w:SetFunc(function(width)
                t.textWidth = width
                FireUpdate(t.indicatorName, "textWidth", width)
            end)

        -- Frame level
        elseif n == "frameLevel" then
            -- No max-value argument any more: this is a named-tier dropdown
            -- (see CreateSetting_FrameLevel), not a bounded slider.
            w:SetDBValue(t.frameLevel)
            w:SetFunc(function(fl) SetField(t, "frameLevel", fl) end)

        -- Num displayed
        elseif n == "num" then
            local default = t.num or 5
            local maxN = 20
            w:SetDBValue(default, maxN)
            w:SetFunc(function(n2) SetField(t, "num", n2) end)

        -- Num per line
        elseif n == "numPerLine" then
            local default = t.numPerLine or 5
            w:SetDBValue(default, 20)
            w:SetFunc(function(n2) SetField(t, "numPerLine", n2) end)

        -- Orientation / Bar orientation
        elseif n == "orientation" or n == "barOrientation" then
            w:SetDBValue(t.orientation or "left-to-right")
            w:SetFunc(function(o) SetField(t, "orientation", o) end)

        -- Axis + direction as one coupled widget (Dispel Icons). Writes both
        -- fields, then fires ONE update: the two are only meaningful together,
        -- and firing separately would push a half-applied pair (new axis, old
        -- direction) through the indicator on the way.
        elseif n == "growthOrientation" then
            w:SetDBValue(t.orientation or "horizontal", t.growthDirection or "left-to-right")
            w:SetFunc(function(orientation, growth)
                t.orientation = orientation
                t.growthDirection = growth
                FireUpdate(t.indicatorName, "growthOrientation", orientation, growth)
            end)

        -- Duration visibility
        elseif n == "durationVisibility" or n == "durationVisibilitySimple" then
            w:SetDBValue(t.durationVisibility or "always")
            w:SetFunc(function(dv) t.durationVisibility = dv; FireUpdate(t.indicatorName, "durationVisibility", dv) end)

        -- Duration text X/Y offset (Healer HoTs)
        elseif n == "durationOffset" then
            w:SetDBValue(t.durationOffset or {0, -2})
            w:SetFunc(function(offset) SetField(t, "durationOffset", offset) end)

        -- Duration / Stack toggles
        elseif n == "duration" then
            w:SetDBValue(t.duration and t.duration[1])
            w:SetFunc(function(val)
                if not t.duration then t.duration = {false, false, 0} end
                t.duration[1] = val
                FireUpdate(t.indicatorName, "duration", t.duration)
            end)

        elseif n == "stack" then
            w:SetDBValue(t.stack and t.stack[1])
            w:SetFunc(function(val)
                if not t.stack then t.stack = {false, false} end
                t.stack[1] = val
                FireUpdate(t.indicatorName, "stack", t.stack)
            end)

        -- Health format
        elseif n == "healthFormat" or n == "powerFormat" then
            local key = (n == "healthFormat") and "healthFormat" or "powerTextFormat"
            w:SetDBValue(t[key] or "effective_percent")
            w:SetFunc(function(f) t[key] = f; FireUpdate(t.indicatorName, n, f) end)

        -- Role texture
        elseif n == "roleTexture" then
            w:SetDBValue(t.roleTexture or "default")
            w:SetFunc(function(rt) SetField(t, "roleTexture", rt) end)

        -- Glow options
        elseif n == "glowOptions" or n == "glow" or n == "targetedSpellsGlow" then
            local default = t.glowOptions or {"None", {0.95, 0.95, 0.32, 1}}
            w:SetDBValue(default)
            w:SetFunc(function(glow)
                t.glowOptions = glow
                FireUpdate(t.indicatorName, "glowOptions", glow)
            end)

        -- Highlight type (dispels)
        elseif n == "highlightType" then
            w:SetDBValue(t.highlightType or "none")
            w:SetFunc(function(ht) SetField(t, "highlightType", ht) end)

        -- Texture
        elseif n == "texture" then
            local default = t.texture or {"circle", 0, {1, 1, 1, 1}}
            w:SetDBValue(default)
            w:SetFunc(function(tex)
                t.texture = tex
                FireUpdate(t.indicatorName, "texture", tex)
            end)

        -- Shield Overlay / Heal Absorb fill texture (LSM statusbar name)
        elseif n == "barTexture" then
            w:SetDBValue(t.barTexture)
            w:SetFunc(function(name) SetField(t, "barTexture", name) end)

        -- Color (generic, class, power, alpha)
        elseif n == "color" then
            w:SetDBValue(t.color)
            w:SetFunc(function(c)
                t.color = c
                FireUpdate(t.indicatorName, "color", c)
                BuildIndicatorList()
            end)

        elseif n == "color-alpha" then
            local default = t.color or {"custom_color", 1, 1, 1, 1}
            w:SetDBValue(default)
            w:SetFunc(function(c) t.color = c; FireUpdate(t.indicatorName, "color", c) end)

        -- Custom "colour" indicator: switch to a second colour once the tracked
        -- aura drops below the threshold. All three fields arrive together --
        -- see CreateSetting_ExpiringColor.
        elseif n == "expiringColor" then
            w:SetDBValue(t.expiringEnabled, t.expiringThreshold, t.expiringColor)
            w:SetFunc(function(enabled, threshold, color)
                t.expiringEnabled = enabled
                t.expiringThreshold = threshold
                t.expiringColor = color
                -- ONE payload table, not three positional args: FireUpdate
                -- forwards only value/value2 (the third slot is the raid-context
                -- flag it appends itself), so a third argument is silently
                -- dropped. Reading the colour back off `t` in the dispatch
                -- instead was worse -- it made the value depend on which
                -- context's list the receiving button resolved, and one of
                -- those paths handed F.ColorRGB a boolean (live 2026-08-14).
                FireUpdate(t.indicatorName, "expiringColor",
                    { enabled = enabled, threshold = threshold, color = color })
            end)

        -- Overshield / over-absorb glow tint, separate from the bar's colour.
        elseif n == "glowColor" then
            w:SetDBValue(t.glowColor or {"custom_color", 1, 1, 1, 1})
            w:SetFunc(function(c) t.glowColor = c; FireUpdate(t.indicatorName, "glowColor", c) end)

        elseif n == "color-class" then
            w:SetDBValue(t.color)
            w:SetFunc(function(useClass)
                t.color = useClass and {"class_color", "any"} or {"custom_color", 1, 1, 1, 1}
                FireUpdate(t.indicatorName, "color", t.color)
                BuildIndicatorList()
            end)

        elseif n == "color-power" then
            w:SetDBValue(t.color)
            w:SetFunc(function(usePower)
                t.color = usePower and {"power_color", "any"} or {"custom_color", 1, 1, 1, 1}
                FireUpdate(t.indicatorName, "color", t.color)
            end)

        -- Status colors (statusText)
        elseif n == "statusColors" then
            w:SetDBValue(t.statusColors)
            w:SetFunc(function(sc) t.statusColors = sc; FireUpdate(t.indicatorName, "statusColors", sc) end)

        -- Number colors list
        elseif n == "colors" or n == "blockColors" or n == "overlayColors" or n == "customColors" then
            local key = (n == "blockColors") and "blockColors"
                or (n == "overlayColors") and "overlayColors"
                or (n == "customColors") and "customColors"
                or "colors"
            local default = t[key] or {{0, 1, 0, 1}}
            w:SetDBValue(default)
            -- CreateSetting_Colors' picker now passes (r,g,b,a) directly
            -- (previously called with no arguments at all, which silently
            -- wrote nil into t[key] here every time a color was picked).
            w:SetFunc(function(r, g, b, a)
                local ct = {{r, g, b, a}}
                t[key] = ct
                FireUpdate(t.indicatorName, key, ct)
            end)

        -- Font (slot 1 or 2 for stackFont/durationFont)
        elseif n == "font1" or n == "font2" then
            local targetIndex = tonumber(token:match("^font(%d)")) or 1
            local prop = token:match("^font%d+:(.+)$") or "stackFont"
            -- "stackFont" -> "Stack Font", "durationFont" -> "Duration Font"
            -- (strip the trailing "Font" before title-casing, else this
            -- doubled up into "StackFont Font").
            local label = prop:gsub("Font$", ""):gsub("^%l", string.upper) .. " Font"
            local fontSlot = GetFontSlot(t, targetIndex)
            w:SetDBValue(fontSlot, label)
            w:SetFunc(SetFontUpdate)

        -- Bare "font" token (custom text/bars/rects): full 8-field widget,
        -- writes into the 2D font table (both slots).
        elseif n == "font" then
            local fontTable = EnsureFontTable(t)
            w:SetDBValue(fontTable, "Font")
            w:SetFunc(SetFontUpdate)

        -- Cast by
        elseif n == "castBy" then
            w:SetDBValue(t.castBy or "anyone")
            w:SetFunc(function(cb) SetField(t, "castBy", cb) end)

        -- Max value (bars)
        elseif n == "maxValue" then
            w:SetDBValue(t.maxValue)
            w:SetFunc(function(mv)
                if not t.maxValue then t.maxValue = {false, 10, true} end
                t.maxValue[1] = mv
                FireUpdate(t.indicatorName, "maxValue", t.maxValue)
            end)

        -- Icon style
        elseif n == "iconStyle" then
            w:SetDBValue(t.iconStyle or "blizzard")
            w:SetFunc(function(is2) SetField(t, "iconStyle", is2) end)

        -- Private aura options
        elseif n == "privateAuraOptions" then
            w:SetDBValue(t.privateAuraOptions and t.privateAuraOptions[1])
            w:SetFunc(function(val)
                if not t.privateAuraOptions then t.privateAuraOptions = {false} end
                t.privateAuraOptions[1] = val
                FireUpdate(t.indicatorName, "privateAuraOptions", t.privateAuraOptions)
            end)

        -- Shape
        elseif n == "shape" then
            w:SetDBValue(t.shape or "circle")
            w:SetFunc(function(s) SetField(t, "shape", s) end)

        -- Dispel filters (dispels indicator)
        elseif n == "dispelFilters" or n == "targetCounterFilters" then
            local key = (n == "dispelsFilters") and "dispelFilters" or "targetCounterFilters"
            w:SetDBValue(t[key])
            w:SetFunc(function(f) t[key] = f; FireUpdate(t.indicatorName, key, f) end)

        -- Dispels (AuraEngine-backed) -- Show All vs Dispellable By Me
        elseif n == "dispelShowAll" then
            w:SetDBValue(t.dispelShowAll ~= false)
            w:SetFunc(function(val) SetField(t, "dispelShowAll", val) end)

        -- Dispels -- per-type enable + color
        elseif n == "dispelTypeColors" then
            w:SetDBValue(t.dispelTypesEnabled, t.dispelColors)
            w:SetFunc(function(enabledMap, colorsMap)
                t.dispelTypesEnabled = enabledMap
                t.dispelColors = colorsMap
                FireUpdate(t.indicatorName, "dispelTypesEnabled", enabledMap)
                FireUpdate(t.indicatorName, "dispelColors", colorsMap)
            end)

        -- Dispel Icons -- per-type enable, no colors (fixed Blizzard atlases)
        elseif n == "dispelTypes" then
            w:SetDBValue(t.dispelTypesEnabled)
            w:SetFunc(function(enabledMap)
                t.dispelTypesEnabled = enabledMap
                FireUpdate(t.indicatorName, "dispelTypesEnabled", enabledMap)
            end)

        -- Dispels -- overlay style (none/fill/full)
        elseif n == "dispelOverlay" then
            w:SetDBValue(t.dispelOverlay or "fill")
            w:SetFunc(function(val) SetField(t, "dispelOverlay", val) end)

        -- Dispels -- overlay opacity (0-100)
        elseif n == "dispelOverlayOpacity" then
            w:SetDBValue(t.dispelOverlayOpacity or 40)
            w:SetFunc(function(val) SetField(t, "dispelOverlayOpacity", val) end)

        elseif n == "dispelGradientHeight" then
            w:SetDBValue(t.dispelGradientHeight or 50)
            w:SetFunc(function(val) SetField(t, "dispelGradientHeight", val) end)

        elseif n == "dispelGradientWeakAlpha" then
            w:SetDBValue(t.dispelGradientWeakAlpha or 50)
            w:SetFunc(function(val) SetField(t, "dispelGradientWeakAlpha", val) end)

        -- Built-in spell toggles + per-spell hide checklist
        elseif n == "builtInExternals" or n == "builtInDefensives" or n == "builtInAoEHealings" or n == "builtInCrowdControls" or n == "builtInMissingBuffs" or n == "builtInHots" then
            local key = n:gsub("^builtIn", "useBuiltIn")
            local hiddenKey = n:gsub("^builtIn", "hiddenBuiltIn")
            w:SetDBValue(t[key] ~= false, t[hiddenKey] or {})
            w:SetFunc(function(val) t[key] = val; FireUpdate(t.indicatorName, key, val) end)
            if w.SetHiddenFunc then
                w:SetHiddenFunc(function(hidden) t[hiddenKey] = hidden; FireUpdate(t.indicatorName, hiddenKey, hidden) end)
            end

        -- Custom spell lists
        elseif n == "customExternals" or n == "customDefensives" or n == "customAoEHealings" or n == "customCrowdControls" or n == "customMissingBuffs" then
            local key = n
            local default = t[key] or {}
            w:SetDBValue(key, default)
            w:SetFunc(function(l) t[key] = l; FireUpdate(t.indicatorName, key, l) end)

        -- Auras / blacklist / priority lists
        elseif n == "auras" or n == "dispelBlacklist" or n == "targetedSpellsList" then
            local key = (n == "auras") and "auras" or n
            local default = t[key] or {}
            local listTitle = (n == "auras") and "Spells"
                or (n == "dispelBlacklist") and "Dispel Blacklist"
                or "Targeted Spells"
            w:SetDBValue(listTitle, default)
            w:SetFunc(function(l) t[key] = l; FireUpdate(t.indicatorName, key, l) end)

        -- Debuffs' curated blacklist checklist (own SetDBValue/SetFunc shape:
        -- just the spell-ID array, no title arg -- see CreateSetting_DebuffBlacklist).
        elseif n == "debuffBlacklist" then
            local default = t.debuffBlacklist or {}
            w:SetDBValue(default)
            w:SetFunc(function(l) t.debuffBlacklist = l; FireUpdate(t.indicatorName, "debuffBlacklist", l) end)

        -- Debuffs' "Big Debuff Priority" -- single checkbox (Blizzard CC filter).
        elseif n == "bigDebuffCC" then
            w:SetDBValue(t.bigDebuffCC)
            w:SetFunc(function(val) t.bigDebuffCC = val; FireUpdate(t.indicatorName, "bigDebuffCC", val) end)

        -- Tips / decoration / anything else
        else
            if w.SetDBValue then w:SetDBValue() end
            if w.SetFunc then w.SetFunc(function() end) end
        end
    end

    -- Stack widgets vertically from top to bottom with positive Y offsets.
    -- (WoW coordinate: positive Y = down, so each successive widget goes lower.)
    -- We anchor each widget's TOPLEFT to the previous widget's BOTTOMLEFT + gap,
    -- so widgets stack cleanly from top to bottom.
    local yOff = 0
    local prevW = nil
    local GAP = -8
    for i, w in ipairs(widgets) do
        if not w then break end
        w:ClearAllPoints()
        if not prevW then
            w:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, 0)
        else
            w:SetPoint("TOPLEFT", prevW, "BOTTOMLEFT", 0, GAP)
        end
        prevW = w
        local h = estimateTokenHeight(tokens[i])
        yOff = yOff + h + GAP
    end

    -- Set the content frame height directly in pixels so the scroll frame clips
    -- and scrolls the widget stack.
    local contentH = math.max(1, yOff + 60)
    scrollChild:SetHeight(contentH)
    settingsScroll:UpdateScrollChildRect()

    -- The estimate above is necessarily approximate (TOKEN_HEIGHTS is a
    -- hand-maintained guess per token, matched against IndicatorWidgets.lua's
    -- actual built widgets) -- this class of bug has already bitten twice
    -- this session (font1/font2 falling through to the wrong pattern
    -- fallback, auras/customExternals having no exact-key entry at all),
    -- each time silently capping the scroll range short of the real content
    -- and clipping the bottom of the panel. Rather than keep hand-tuning
    -- individual token estimates as new ones get discovered, re-measure the
    -- REAL stacked height once layout has actually run (widgets report 0
    -- from GetHeight() synchronously after creation/positioning -- see the
    -- comment on TOKEN_HEIGHTS) and grow the scroll range to match if the
    -- estimate undershot.
    if prevW then
        C_Timer.After(0, function()
            if not scrollChild or not scrollChild:IsShown() then return end
            local top = scrollChild:GetTop()
            local bottom = prevW:GetBottom()
            if not top or not bottom then return end
            local realH = (top - bottom) + 60
            if realH > contentH then
                scrollChild:SetHeight(realH)
                settingsScroll:UpdateScrollChildRect()
            end
        end)
    end

    if SquizzFrames.Indicators then SquizzFrames.Indicators.BuildPreview() end
end

-- Dragging an indicator on the preview (Indicators.lua owns the drag proxy,
-- since that's where the highlight border and preview button already live)
-- writes the new position straight to the profile and calls back here so the
-- X/Y Offset sliders in an already-open settings pane don't go stale.
if SquizzFrames.Indicators then
    SquizzFrames.Indicators.OnPreviewPositionDragged = function(name)
        if name == selectedName then ShowSettings(name) end
    end
end

-----------------------------------------------------------------------
-- Create popup (Custom Indicators manager's "Add Indicator" button)
-----------------------------------------------------------------------
local function ShowCreatePopup()
    local dialog = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    dialog:SetSize(240, 165)
    -- Centered on the whole tab rather than pinned to a hardcoded offset --
    -- the old offset was tuned for a "Create" footer button that no longer
    -- exists (this now opens from the Custom Indicators manager's "Add
    -- Indicator" button instead), so a fixed screen position no longer means
    -- anything.
    dialog:SetPoint("CENTER", parent, "CENTER", 0, 20)
    dialog:SetFrameStrata("TOOLTIP")
    dialog:SetFrameLevel(parent:GetFrameLevel() + 300)
    dialog:SetClampedToScreen(true)
    dialog:EnableKeyboard(true)
    W.StylizeFrame(dialog, {0.1, 0.1, 0.1, 0.95}, {0.3, 0.7, 1, 0.8})

    dialog.title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dialog.title:SetPoint("TOP", 0, -10)
    dialog.title:SetText("Create New Indicator")

    dialog.nameBox = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
    dialog.nameBox:SetSize(dialog:GetWidth() - 40, 20)
    dialog.nameBox:SetPoint("TOP", dialog.title, "BOTTOM", 0, -14)
    dialog.nameBox:SetAutoFocus(true)
    dialog.nameBox:SetText("")
    dialog.nameBox:SetScript("OnTextChanged", function(self)
        local text = self:GetText()
        local hasText = text and text ~= ""
        dialog.confirmBtn:SetEnabled(hasText)
        dialog.confirmBtn:SetAlpha(hasText and 1 or 0.4)
    end)

    -- Two styled dropdowns side by side, each exactly half of nameBox's
    -- width -- replaces the raw UIDropDownMenuTemplate pair, whose fixed-
    -- size Blizzard skin textures stayed ~150px wide regardless of
    -- UIDropDownMenu_SetWidth and visually overlapped when squeezed
    -- side-by-side into a box this size.
    local typeItems = (SquizzFrames.IndicatorDefaults and SquizzFrames.IndicatorDefaults.CUSTOM_TYPES) or {}
    dialog.typeValue = typeItems[1] and typeItems[1].value or "icon"
    dialog.typeDropdown = W.CreateStyledDropdown(dialog, 80, 40, "Type", typeItems,
        function() return dialog.typeValue end,
        function(v) dialog.typeValue = v end)
    dialog.typeDropdown:SetPoint("TOPLEFT", dialog.nameBox, "BOTTOMLEFT", 0, -14)

    local auraItems = { {value = "buff", text = "Buff"}, {value = "debuff", text = "Debuff"} }
    dialog.auraValue = "buff"
    dialog.auraDropdown = W.CreateStyledDropdown(dialog, 80, 40, "Aura Type", auraItems,
        function() return dialog.auraValue end,
        function(v) dialog.auraValue = v end)
    dialog.auraDropdown:SetPoint("TOPRIGHT", dialog.nameBox, "BOTTOMRIGHT", 0, -14)

    dialog.confirmBtn = W.CreateStyledButton(dialog, "Create", "accent-hover", {80, 22}, function()
        local nm = dialog.nameBox:GetText()
        if nm and nm ~= "" then
            -- "indicator" .. (#GetIndicatorList()+1) isn't a reliable unique
            -- name -- after a deletion the list length shrinks, so a later
            -- create can recompute a name still taken by a surviving
            -- indicator, and FindOrCreateIndicatorSlot silently no-ops on the
            -- collision. Find the smallest actually-unused "indicatorN" instead.
            local used = {}
            for _, existing in ipairs(GetIndicatorList()) do
                used[existing.indicatorName] = true
            end
            local n = 1
            local indicatorName = "indicator" .. n
            while used[indicatorName] do
                n = n + 1
                indicatorName = "indicator" .. n
            end
            local newTable = SquizzFrames.GetDefaultCustomIndicatorTable(nm, indicatorName, dialog.typeValue, dialog.auraValue)
            SquizzFrames:Fire("UpdateIndicators", indicatorName, "create", newTable, nil, activeIndicatorLayoutKey == "raid")
            BuildIndicatorList()
            if SquizzFrames.IndicatorsPanel.RefreshCustomIndicatorsPane then
                SquizzFrames.IndicatorsPanel.RefreshCustomIndicatorsPane()
            end
            SelectIndicator(indicatorName)
        end
        dialog:Hide()
    end)
    dialog.confirmBtn:SetPoint("BOTTOMLEFT", 14, 12)
    dialog.confirmBtn:SetEnabled(false)
    dialog.confirmBtn:SetAlpha(0.4)

    dialog.cancelBtn = W.CreateStyledButton(dialog, "Cancel", "red-hover", {80, 22}, function()
        dialog:Hide()
    end)
    dialog.cancelBtn:SetPoint("BOTTOMRIGHT", -14, 12)

    dialog:Show()
end

-----------------------------------------------------------------------
-- Preview canvas (top section)
-----------------------------------------------------------------------

-- Build a mock unit button: a plain (non-secure) Frame that mimics enough of
-- SquizzFramesUnitButtonTemplate's structure for the indicator runtime to
-- treat it like a real unit frame -- indicators anchor to healthBar/nameText,
-- BuiltIn_Update reads button.indicators, etc.
--
-- Extracted from BuildPreviewCanvas so the group preview window can build a
-- whole party/raid out of the same thing. Everything in here (especially the
-- textHost frame-level workaround below) is load-bearing and was arrived at by
-- debugging; a second hand-rolled copy would silently drift from it.
--
-- Caller is responsible for positioning and (if wanted) scaling the result.
local function CreateMockUnitButton(parent, name, w, h, powerH)
    local button = CreateFrame("Frame", name, parent)
    button:SetSize(w, h)

    local healthBackdrop = CreateFrame("Frame", nil, button, "BackdropTemplate")
    healthBackdrop:SetPoint("TOPLEFT", 1, -1)
    healthBackdrop:SetPoint("BOTTOMRIGHT", -1, 1)
    healthBackdrop:SetBackdrop({ bgFile = [[Interface\Buttons\WHITE8X8]] })
    healthBackdrop:SetBackdropColor(0.15, 0.15, 0.15, 1)
    button.healthBackdrop = healthBackdrop

    local healthBar = CreateFrame("StatusBar", nil, button)
    healthBar:SetPoint("TOPLEFT", 1, -1)
    healthBar:SetPoint("BOTTOMRIGHT", -1, 1)
    healthBar:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
    healthBar:SetStatusBarColor(0, 0.8, 0, 1)
    healthBar:SetMinMaxValues(0, 1)
    healthBar:SetValue(0.75)
    button.healthBar = healthBar

    -- Dedicated host for the text indicators, explicitly ABOVE button's own
    -- level. healthBar/powerBar are separate child StatusBar frames, which WoW
    -- defaults to button's level + 1 -- above nameText/statusText/healthText/
    -- powerText if those were left as plain FontString regions owned directly
    -- by button (which render at button's OWN level). textHost is a SEPARATE
    -- frame explicitly bumped above that, so bumping ITS level doesn't change
    -- what level anything parented to button itself (health/power bars, icon
    -- indicators created later by HandleIndicators) defaults to -- text
    -- reliably stays on top regardless of creation order.
    local textHost = CreateFrame("Frame", nil, button)
    textHost:SetAllPoints(button)
    textHost:SetFrameLevel(button:GetFrameLevel() + 10)

    local nameText = textHost:CreateFontString(nil, "OVERLAY")
    nameText:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    nameText:SetPoint("LEFT", 4, 0)
    nameText:SetText("Preview")
    button.nameText = nameText

    local statusText = textHost:CreateFontString(nil, "OVERLAY")
    statusText:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
    statusText:SetPoint("BOTTOM", healthBar, "BOTTOM", 0, 0)
    statusText:SetText("Alive")
    button.statusText = statusText

    -- healthText/powerText aren't part of the static template (unlike name/
    -- status text above) -- BuiltIn_Update.lua only creates them on demand
    -- (`button.healthText or button:CreateFontString(...)`) when those
    -- indicators are actually enabled. Pre-creating placeholders on textHost
    -- here means that lookup finds these instead of falling through to create
    -- fresh ones parented directly to button (which would go back to
    -- rendering at button's own, lower level).
    local healthText = textHost:CreateFontString(nil, "OVERLAY")
    healthText:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    healthText:Hide()
    button.healthText = healthText

    local powerText = textHost:CreateFontString(nil, "OVERLAY")
    powerText:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    powerText:Hide()
    button.powerText = powerText

    local powerBar = CreateFrame("StatusBar", nil, button)
    powerBar:SetPoint("BOTTOMLEFT", healthBackdrop, "BOTTOMLEFT", 0, 0)
    powerBar:SetPoint("BOTTOMRIGHT", healthBackdrop, "BOTTOMRIGHT", 0, 0)
    powerBar:SetHeight(powerH)
    powerBar:SetStatusBarTexture([[Interface\Buttons\WHITE8X8]])
    powerBar:SetStatusBarColor(0, 0.5, 1, 1)
    powerBar:SetMinMaxValues(0, 1)
    powerBar:SetValue(1)
    button.powerBar = powerBar

    local roleIcon = button:CreateTexture(nil, "ARTWORK")
    roleIcon:SetSize(12, 12)
    roleIcon:SetPoint("TOPLEFT", 0, 0)
    roleIcon:SetTexture([[Interface\AddOns\SquizzFrames\Media\Icons\healer]])
    roleIcon:Hide()
    button.roleIcon = roleIcon

    local raidIcon = button:CreateTexture(nil, "OVERLAY")
    raidIcon:SetSize(14, 14)
    raidIcon:SetPoint("TOP", button, "TOP", 0, 3)
    raidIcon:SetTexture([[Interface\TargetingFrame\UI-RaidTargetingIcon_1]])
    raidIcon:Hide()
    button.raidIcon = raidIcon

    button.unit = "player"
    button.states = { displayedUnit = "player" }
    button.indicators = {}
    button._indicatorsReady = false

    return button
end

-- Exposed for GroupPreview.lua (loaded after this file), which builds a whole
-- mock party/raid out of these.
if SquizzFrames.Indicators then
    SquizzFrames.Indicators.CreateMockUnitButton = CreateMockUnitButton
end

local function BuildPreviewCanvas(canvasFrame)
    previewBG = CreateFrame("Frame", nil, canvasFrame, "BackdropTemplate")
    previewBG:SetAllPoints(canvasFrame)
    W.StylizeFrame(previewBG, {0.1, 0.1, 0.1, 0.77}, {0, 0, 0, 1})

    -- Preview button mockup (plain Frame, not secure). Mimics
    -- SquizzFramesUnitButtonTemplate structure so indicators can anchor to
    -- healthBar, nameText, etc. Centered in the canvas since drags can move
    -- indicators well outside the button's own tiny footprint.
    local realW, realH, realPowerH = GetRealButtonDimensions()
    previewButton = CreateMockUnitButton(previewBG, "SquizzIndicatorsPreview", realW, realH, realPowerH)
    previewButton:SetPoint("CENTER", previewBG, "CENTER", 0, 0)
    previewButton:SetScale(DEFAULT_PREVIEW_SCALE)

    -- Scale slider (1-5). Bottom-left corner of the canvas.
    local scaleSlider = W.CreateStyledSlider(previewBG, 60, 1, 5, 1, "Scale",
        function() return previewButton:GetScale() end,
        function(val) previewButton:SetScale(val) end)
    scaleSlider:SetPoint("BOTTOMLEFT", previewBG, "BOTTOMLEFT", 10, 10)

    -- Show All checkbox (to the right of the scale slider). Was a stub
    -- before: getValue always returned false (so it visually never stayed
    -- checked) and setValue ignored its own `checked` argument and just
    -- re-ran BuildPreview() with nothing actually changed -- rebuilding from
    -- the same real indicatorList looks identical, so the checkbox appeared
    -- to do nothing. Session-only (not saved to the profile): forces every
    -- disabled indicator to render in the preview via
    -- previewButton._sfShowAllIndicators (read by HandleIndicators, which
    -- feeds a forced-enabled shallow copy through the normal Check/Show
    -- pipeline -- see its comment). Custom (user-created) indicators will
    -- show their frame/position but may not populate fake aura content --
    -- Custom_Dispatch.lua's enabled gate is a separate, global mechanism
    -- this override doesn't reach.
    local showAllIndicators = false
    local showAllCB = W.CreateStyledCheckbox(previewBG, "Show All",
        function() return showAllIndicators end,
        function(checked)
            showAllIndicators = checked
            previewButton._sfShowAllIndicators = checked
            if SquizzFrames.Indicators then SquizzFrames.Indicators.BuildPreview() end
        end)
    showAllCB:SetPoint("LEFT", scaleSlider, "RIGHT", 14, 2)

    if SquizzFrames.Indicators then SquizzFrames.Indicators.SetPreviewButton(previewButton) end
end

-----------------------------------------------------------------------
-- Custom Indicators manager pane -- shown in place of settingsScroll when
-- the "CUSTOM INDICATORS" list header is clicked. Holds the "Add Indicator"
-- button plus a live list of every custom indicator (click a row to open its
-- settings, click "X" to delete). Replaces the old global Create/Rename/
-- Delete footer, which the user asked removed since it applied to whatever
-- indicator happened to be selected rather than living with the customs
-- themselves.
-----------------------------------------------------------------------
local customListScroll
local customListRows = {}

-- Fallback preview icon per custom indicator type, used when the indicator
-- has no tracked auras yet (a fresh "text"/"color"/etc indicator has nothing
-- spell-shaped to show a real icon for).
local TYPE_PREVIEW_ICON = {
    icon = [[Interface\Icons\INV_Misc_Book_09]],
    icons = [[Interface\Icons\INV_Misc_Book_09]],
    text = [[Interface\Icons\INV_Inscription_Scroll]],
    bar = [[Interface\Icons\Spell_Nature_HealingWaveGreater]],
    bars = [[Interface\Icons\Spell_Nature_HealingWaveGreater]],
    rect = [[Interface\Icons\INV_Misc_QuestionMark]],
    color = [[Interface\Icons\INV_Misc_Gem_01]],
    texture = [[Interface\Icons\INV_Misc_QuestionMark]],
    glow = [[Interface\Icons\Spell_Holy_HolyBolt]],
    overlay = [[Interface\Icons\Spell_Holy_PowerWordShield]],
    block = [[Interface\Icons\INV_Misc_QuestionMark]],
    blocks = [[Interface\Icons\INV_Misc_QuestionMark]],
    border = [[Interface\Icons\INV_Misc_QuestionMark]],
}

-- Prefers the actual tracked aura's icon (what the indicator will really
-- show in-game) over the generic per-type fallback, so tiles read as a true
-- visual preview instead of a static type glyph once auras are added.
local function GetCustomIndicatorPreviewIcon(t)
    local auras = t.auras
    if auras and auras[1] then
        local icon = F.GetSpellIcon(auras[1])
        if icon then return icon end
    end
    return TYPE_PREVIEW_ICON[t.type] or [[Interface\Icons\INV_Misc_QuestionMark]]
end

local function DeleteCustomIndicator(indicatorName)
    -- Remove from the profile first (mirrors the old delete popup's
    -- behavior) -- UpdateIndicators' "delete" handler only removes the
    -- runtime working-list entry, expecting the caller to have already
    -- dropped it from the profile.
    local list = GetIndicatorList()
    for i, t in ipairs(list) do
        if t.indicatorName == indicatorName then
            table.remove(list, i)
            break
        end
    end
    SquizzFrames:Fire("UpdateIndicators", indicatorName, "delete", nil, nil, activeIndicatorLayoutKey == "raid")
    if selectedName == indicatorName then
        selectedName = nil
    end
    BuildIndicatorList()
end

-- Tile grid, not a plain text list -- each custom indicator gets a square
-- preview tile (icon + name) that visually previews what it tracks, wrapping
-- into as many columns as fit the pane's current width.
local TILE_W, TILE_H, TILE_GAP = 64, 72, 6

local function RefreshCustomIndicatorsPane()
    if not customListScroll then return end
    local scrollChild = customListScroll.scrollChild
    for _, row in ipairs(customListRows) do
        row:Hide()
        row:SetParent(nil)
    end
    wipe(customListRows)

    local customs = {}
    for _, t in ipairs(GetIndicatorList()) do
        if t.type ~= "built-in" then customs[#customs + 1] = t end
    end

    if #customs == 0 then
        local empty = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        empty:SetPoint("TOPLEFT", 4, -4)
        empty:SetText("No custom indicators yet.")
        customListRows[1] = empty
        scrollChild:SetHeight(20)
        customListScroll:UpdateScrollChildRect()
        return
    end

    local availW = customListScroll:GetWidth()
    if not availW or availW < TILE_W then availW = TILE_W end
    local cols = math.max(1, math.floor((availW + TILE_GAP) / (TILE_W + TILE_GAP)))
    local accent = F.GetAccentColor()

    for i, t in ipairs(customs) do
        local col = (i - 1) % cols
        local gridRow = math.floor((i - 1) / cols)

        local tile = CreateFrame("Button", nil, scrollChild, "BackdropTemplate")
        tile:SetSize(TILE_W, TILE_H)
        tile:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", col * (TILE_W + TILE_GAP), -gridRow * (TILE_H + TILE_GAP))
        W.StylizeFrame(tile, {0.08, 0.08, 0.08, 0.85}, {0.3, 0.3, 0.3, 0.6})

        local icon = tile:CreateTexture(nil, "ARTWORK")
        icon:SetSize(36, 36)
        icon:SetPoint("TOP", 0, -6)
        icon:SetTexture(GetCustomIndicatorPreviewIcon(t))
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        local label = tile:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", 3, -46)
        label:SetPoint("TOPRIGHT", -3, -46)
        label:SetJustifyH("CENTER")
        label:SetWordWrap(true)
        label:SetText(t.name or t.indicatorName)

        -- Child button -- WoW gives child frames a frame level above their
        -- parent by default, so this reliably catches the click instead of
        -- falling through to the tile's own OnClick underneath it.
        local deleteBtn = CreateFrame("Button", nil, tile)
        deleteBtn:SetSize(14, 14)
        deleteBtn:SetPoint("TOPRIGHT", 0, 0)
        deleteBtn:SetNormalFontObject("GameFontNormalSmall")
        deleteBtn:SetText("X")
        deleteBtn:SetScript("OnClick", function()
            DeleteCustomIndicator(t.indicatorName)
            RefreshCustomIndicatorsPane()
        end)

        tile:SetScript("OnClick", function() SelectIndicator(t.indicatorName) end)
        tile:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(accent.r, accent.g, accent.b, 1) end)
        tile:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.6) end)

        customListRows[i] = tile
    end

    local totalRows = math.ceil(#customs / cols)
    scrollChild:SetHeight(math.max(1, totalRows * (TILE_H + TILE_GAP)))
    customListScroll:UpdateScrollChildRect()
end

local function BuildCustomIndicatorsPane(pane)
    customIndicatorsPane = CreateFrame("Frame", nil, pane)
    customIndicatorsPane:SetPoint("TOPLEFT", pane, "TOPLEFT", 2, -22)
    customIndicatorsPane:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -2, 4)
    customIndicatorsPane:Hide()

    local addBtn = W.CreateStyledButton(customIndicatorsPane, "+ Add Indicator", "accent-hover", {130, 24}, ShowCreatePopup)
    addBtn:SetPoint("TOPLEFT", customIndicatorsPane, "TOPLEFT", 2, -2)

    customListScroll = W.CreateScrollFrame(customIndicatorsPane)
    customListScroll:SetPoint("TOPLEFT", addBtn, "BOTTOMLEFT", -2, -8)
    customListScroll:SetPoint("BOTTOMRIGHT", customIndicatorsPane, "BOTTOMRIGHT", 0, 0)
    customListScroll.scrollChild:SetClipsChildren(true)
end

-- Switches the right-hand settings pane from "editing one indicator" to the
-- Custom Indicators manager view. ShowSettings() (called whenever any real
-- indicator row is selected) undoes this.
ShowCustomIndicatorsManager = function()
    local oldButton = selectedButton
    selectedButton = nil
    if oldButton then UpdateRowVisual(oldButton) end
    selectedName = nil
    if SquizzFrames.Indicators then SquizzFrames.Indicators.HidePreviewHighlight() end

    if settingsTitle then settingsTitle:SetText("|cffffd100Custom Indicators|r") end
    if settingsScroll then settingsScroll:Hide() end
    if customIndicatorsPane then customIndicatorsPane:Show() end
    RefreshCustomIndicatorsPane()
end

-----------------------------------------------------------------------
-- Build
-----------------------------------------------------------------------

local BOTTOM_SECTION_HEIGHT = 300

local function Build(parentFrame, optionsFrame)
    parent = parentFrame

    -- ============================================================
    -- TOP: Party/Raid toggle -- switches which indicator list (profile
    -- .layout.indicators / .indicatorsRaid) everything below reads and
    -- writes. Mirrors OptionsFrame.lua's Layout tab Party/Raid toggle
    -- exactly (same widget pattern, independent of the player's real
    -- current group state).
    -- ============================================================
    local toggleHeader = CreateFrame("Frame", nil, parent)
    toggleHeader:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -5)
    toggleHeader:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -5, -5)
    toggleHeader:SetHeight(24)

    local toggleButtons = {}
    local function RefreshIndicatorToggleVisual()
        local accent = F.GetAccentColor and F.GetAccentColor()
        for key, btn in pairs(toggleButtons) do
            if key == activeIndicatorLayoutKey then
                btn:SetBackdropColor(accent and accent.r or 0.6, accent and accent.g or 0.4, accent and accent.b or 1, 0.55)
            else
                btn:SetBackdropColor(0.115, 0.115, 0.115, 1)
            end
        end
    end
    local function MakeIndicatorToggleButton(key, label, xOff)
        local btn = CreateFrame("Button", nil, toggleHeader, "BackdropTemplate")
        btn:SetSize(90, 22)
        btn:SetPoint("TOPLEFT", toggleHeader, "TOPLEFT", xOff, 0)
        W.StylizeFrame(btn, {0.115, 0.115, 0.115, 1}, {0, 0, 0, 0})
        local text = btn:CreateFontString(nil, "OVERLAY")
        text:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        text:SetPoint("CENTER")
        text:SetText(label)
        btn:SetScript("OnClick", function()
            if activeIndicatorLayoutKey == key then return end
            activeIndicatorLayoutKey = key
            RefreshIndicatorToggleVisual()
            local IndicatorsModule = SquizzFrames.Indicators
            if IndicatorsModule and IndicatorsModule.SetPreviewIndicatorMode then
                IndicatorsModule.SetPreviewIndicatorMode(key == "raid")
            end
            -- Re-sync the preview button to the new context's real
            -- width/height/powerHeight before rebuilding it, same as the
            -- OnShow handler below does.
            if previewButton then
                local realW, realH, realPowerH = GetRealButtonDimensions()
                previewButton:SetSize(realW, realH)
                if previewButton.powerBar then previewButton.powerBar:SetHeight(realPowerH) end
            end
            BuildIndicatorList()
            if IndicatorsModule then IndicatorsModule.BuildPreview() end
            -- Keep the full-group preview window on the same tab (it's a
            -- no-op when the window isn't open).
            local GroupPreview = SquizzFrames.GroupPreview
            if GroupPreview and GroupPreview.SetRaidMode then
                GroupPreview.SetRaidMode(key == "raid")
            end
            if selectedName then
                ShowSettings(selectedName)
                if IndicatorsModule then IndicatorsModule.ShowPreviewHighlight(selectedName) end
            end
        end)
        toggleButtons[key] = btn
        return btn
    end
    MakeIndicatorToggleButton("main", "Party", 0)
    MakeIndicatorToggleButton("raid", "Raid", 95)
    RefreshIndicatorToggleVisual()

    -- Full-group preview toggle. Opens a read-only window (pinned to the left
    -- of the options panel) showing a whole 5-man party or 20-man raid at the
    -- real configured frame sizes, so indicator spacing/overlap can be judged
    -- across a group instead of from this single frame. See GroupPreview.lua.
    local groupPreviewBtn = CreateFrame("Button", nil, toggleHeader, "BackdropTemplate")
    groupPreviewBtn:SetSize(150, 22)
    groupPreviewBtn:SetPoint("TOPRIGHT", toggleHeader, "TOPRIGHT", 0, 0)
    W.StylizeFrame(groupPreviewBtn, {0.115, 0.115, 0.115, 1}, {0, 0, 0, 0})
    local gpText = groupPreviewBtn:CreateFontString(nil, "OVERLAY")
    gpText:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    gpText:SetPoint("CENTER")

    -- Selected state matches RefreshIndicatorToggleVisual above: only the
    -- BACKDROP changes, to accent at 0.55 alpha, and the text is left alone.
    -- Accent colours are class colours, so several of them (pink, yellow,
    -- tan) are light enough that dark text on a near-opaque accent fill is
    -- unreadable -- holding the fill translucent keeps the button dark enough
    -- for the standard white outlined text at any accent.
    local function RefreshGroupPreviewVisual()
        local GroupPreview = SquizzFrames.GroupPreview
        local shown = GroupPreview and GroupPreview.IsShown and GroupPreview.IsShown()
        local accent = F.GetAccentColor and F.GetAccentColor()
        if shown then
            groupPreviewBtn:SetBackdropColor(accent and accent.r or 0.6,
                accent and accent.g or 0.4, accent and accent.b or 1, 0.55)
            gpText:SetText(L["Hide Group Preview"] or "Hide Group Preview")
        else
            groupPreviewBtn:SetBackdropColor(0.115, 0.115, 0.115, 1)
            gpText:SetText(L["Show Group Preview"] or "Show Group Preview")
        end
    end

    groupPreviewBtn:SetScript("OnClick", function()
        local GroupPreview = SquizzFrames.GroupPreview
        if not GroupPreview then return end
        -- Sync to the tab being edited before showing, so the first open
        -- doesn't flash the wrong group type.
        GroupPreview.SetRaidMode(activeIndicatorLayoutKey == "raid")
        GroupPreview.Toggle()
    end)
    -- Driven by the message rather than set inline, so the button also
    -- updates when the window closes on its own (its X, or the options panel
    -- hiding).
    F.NewMessageOwner():RegisterMessage("GroupPreviewToggled", RefreshGroupPreviewVisual)
    RefreshGroupPreviewVisual()

    -- ============================================================
    -- preview canvas. Fills whatever space is left above the fixed-
    -- height bottom section, so it grows/shrinks with the window instead of
    -- being pinned to a fraction of it (WoW anchors are pixel offsets, not
    -- percentages -- easier to fix the bottom section's height and let the
    -- top fill the remainder than to recompute a percentage on every resize).
    -- ============================================================
    local bottomSection = CreateFrame("Frame", nil, parent)
    bottomSection:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 5, 5)
    bottomSection:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -5, 5)
    bottomSection:SetHeight(BOTTOM_SECTION_HEIGHT)

    local previewSection = CreateFrame("Frame", nil, parent)
    previewSection:SetPoint("TOPLEFT", toggleHeader, "BOTTOMLEFT", 0, -5)
    previewSection:SetPoint("TOPRIGHT", toggleHeader, "BOTTOMRIGHT", 0, -5)
    previewSection:SetPoint("BOTTOM", bottomSection, "TOP", 0, 5)
    BuildPreviewCanvas(previewSection)

    -- ============================================================
    -- BOTTOM-LEFT: indicator list (built-ins only, category-grouped) +
    -- a single "Custom Indicators" entry that opens the manager pane
    -- ============================================================
    listPane = CreateFrame("Frame", nil, bottomSection, "BackdropTemplate")
    listPane:SetPoint("TOPLEFT", bottomSection, "TOPLEFT", 0, 0)
    listPane:SetPoint("BOTTOMLEFT", bottomSection, "BOTTOMLEFT", 0, 0)
    listPane:SetWidth(136)
    W.StylizeFrame(listPane, {0.1, 0.1, 0.1, 0.95}, {0, 0, 0, 1})

    -- Scroll frame for the list rows — created directly on listPane with
    -- explicit insets, matching ClickCasting's pattern (no nested container).
    -- Built-in indicators are grouped by workflow category (see
    -- GetIndicatorCategory); custom indicators don't get rows here at all --
    -- see CreateListRow's "Custom Indicators >" entry inside BuildIndicatorList.
    listScroll = W.CreateScrollFrame(listPane)
    listScroll:SetPoint("TOPLEFT", listPane, "TOPLEFT", 2, -6)
    listScroll:SetPoint("BOTTOMRIGHT", listPane, "BOTTOMRIGHT", -2, 2)
    listScroll.scrollChild:SetClipsChildren(true)

    -- ============================================================
    -- BOTTOM-RIGHT: settings pane
    -- ============================================================
    settingsPane = CreateFrame("Frame", nil, bottomSection, "BackdropTemplate")
    settingsPane:SetPoint("TOPLEFT", listPane, "TOPRIGHT", 5, 0)
    settingsPane:SetPoint("BOTTOMRIGHT", bottomSection, "BOTTOMRIGHT", 0, 0)
    W.StylizeFrame(settingsPane, {0.1, 0.1, 0.1, 0.95}, {0, 0, 0, 1})

    settingsTitle = settingsPane:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    settingsTitle:SetPoint("TOPLEFT", settingsPane, "TOPLEFT", 6, -5)
    settingsTitle:SetText("|cffffd100Indicator Settings|r")

    -- Scroll frame for settings content — directly on settingsPane.
    -- Frame level must be ABOVE the pane's backdrop or widgets render behind it.
    settingsScroll = W.CreateScrollFrame(settingsPane)
    settingsScroll:SetFrameLevel(settingsPane:GetFrameLevel() + 10)
    settingsScroll:SetPoint("TOPLEFT", 2, -22)
    settingsScroll:SetPoint("BOTTOMRIGHT", settingsPane, "BOTTOMRIGHT", -2, 4)
    -- Enable clipping on the content frame so widget contents don't overflow
    settingsScroll.scrollChild:SetClipsChildren(true)

    BuildCustomIndicatorsPane(settingsPane)

    -- Initial build + auto-select first indicator.
    local function _doBuild()
        BuildIndicatorList()
        local list = GetIndicatorList()
        if list[1] then
            SelectIndicator(list[1].indicatorName or list[1].name)
        end
    end
    local ok, errmsg = pcall(_doBuild)
    if not ok then print("|cffff0009[SquizzFrames]|r IndicatorsPanel error: " .. tostring(errmsg)) end

    -- Rebuild when the panel is shown so widgets get correct sizes.
    -- (Build runs while the parent is still 0x0 and hidden; the scroll
    -- frame + children need a valid rect to lay out correctly.)
    local function RefreshForCurrentProfile()
        BuildIndicatorList()
        if selectedName then ShowSettings(selectedName) end
        -- Re-sync the preview to the Layout tab's current width/height/
        -- powerHeight in case they were changed since this page was last shown.
        if previewButton then
            local realW, realH, realPowerH = GetRealButtonDimensions()
            previewButton:SetSize(realW, realH)
            if previewButton.powerBar then previewButton.powerBar:SetHeight(realPowerH) end
        end
        if SquizzFrames.Indicators then SquizzFrames.Indicators.BuildPreview() end
        if selectedName and SquizzFrames.Indicators then SquizzFrames.Indicators.ShowPreviewHighlight(selectedName) end
    end
    parent:SetScript("OnShow", RefreshForCurrentProfile)

    -- Same refresh, but for a profile switch/copy/reset that happens while
    -- this tab is ALREADY the one showing -- OnShow alone only catches
    -- navigating back to this tab, not a change that occurs while already
    -- parked here.
    -- Own message owner -- see F.NewMessageOwner in Utils.lua (registering
    -- on the shared SquizzFrames root collided with five other sites).
    SquizzFrames.F.NewMessageOwner():RegisterMessage("ProfileChanged", function()
        if parent:IsShown() then RefreshForCurrentProfile() end
    end)

    parent:SetScript("OnHide", function()
        if SquizzFrames.Indicators then SquizzFrames.Indicators.HidePreviewHighlight() end
    end)

    parent.RebuildIndicators = BuildIndicatorList
end

SquizzFrames.IndicatorsPanel = {
    Build = Build,
    Rebuild = BuildIndicatorList,
    SelectIndicator = SelectIndicator,
    GetSelectedName = function() return selectedName end,
    GetIndicatorList = GetIndicatorList,
    RefreshCustomIndicatorsPane = RefreshCustomIndicatorsPane,
    ShowCustomIndicatorsManager = ShowCustomIndicatorsManager,
    -- Which group type this page is editing. The shared group preview window
    -- is driven by both this page and the Layout page, so OptionsFrame's
    -- ShowPage re-syncs the window to whichever page you navigate to.
    IsRaidTab = function() return activeIndicatorLayoutKey == "raid" end,
}