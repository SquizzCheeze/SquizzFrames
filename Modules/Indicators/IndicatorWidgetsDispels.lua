--[[ SquizzFrames IndicatorWidgetsDispels.lua
-- The Dispels settings: type toggles and colours, overlay style, opacity,
-- gradient, the animated border, plus the shared filter checklist widget
-- (dispel/target-counter/role filters) and Text Scale that sat beside them.
-- Moved out of IndicatorWidgets.lua unchanged in 2.0 (phase 2 code split).
-- Loads before IndicatorWidgets.lua, which imports these from
-- SquizzFrames.IndicatorWidgetsDispels under the same names.
--]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local W = SquizzFrames.Widgets
if not W then return end

local Base = SquizzFrames.IndicatorWidgetsBase
if not Base then return end
local SF_CreateFrame, SF_CreateCheckButton = Base.SF_CreateFrame, Base.SF_CreateCheckButton
local SF_CreateDropdown, SF_CreateSlider = Base.SF_CreateDropdown, Base.SF_CreateSlider
local settingWidgets = Base.settingWidgets
local FONT_TEMPLATE, CreateLabel = Base.FONT_TEMPLATE, Base.CreateLabel
local ROW_HEIGHT, LayoutDropdownRow = Base.ROW_HEIGHT, Base.LayoutDropdownRow

-----------------------------------------------------------------------
-- DispelFilters / TargetCounterFilters / RoleFilters
-----------------------------------------------------------------------
local function CreateSetting_DispelFilters(parent)
    local widget
    if not settingWidgets["dispelFilters"] then
        widget = SF_CreateFrame("SFIndicatorSettings_DispelFilters", parent, 300,130)
        settingWidgets["dispelFilters"] = widget
        local filterTypes = {"Magic", "Curse", "Disease", "Poison", "Bleed"}
        local prev = nil
        for _, fType in ipairs(filterTypes) do
            local cb = SF_CreateCheckButton(widget, fType)
            if prev then cb:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -2)
            else cb:SetPoint("TOPLEFT", 5, -8) end
            prev = cb
        end
        widget.title = CreateLabel(widget, "Dispel Filters", "TOPLEFT", 5, -8)
        widget.title:SetTextColor(W.C4(W.palette.HEADING))
        widget.title:SetFont(FONT_TEMPLATE, 12, "OUTLINE")
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue() end
    else widget = settingWidgets["dispelFilters"] end
    widget:Show(); return widget
end

local CreateSetting_TargetCounterFilters = CreateSetting_DispelFilters
local CreateSetting_RoleFilters = CreateSetting_DispelFilters

-----------------------------------------------------------------------
-- Dispels (AuraEngine-backed) — Show All vs Dispellable By Me, per-type
-- enable + color, overlay style/opacity, and icon placement.
-----------------------------------------------------------------------
local function CreateSetting_DispelShowAll(parent)
    local widget
    if not settingWidgets["dispelShowAll"] then
        widget = SF_CreateFrame("SFIndicatorSettings_DispelShowAll", parent, 300, ROW_HEIGHT)
        settingWidgets["dispelShowAll"] = widget
        widget.dd = LayoutDropdownRow(widget, "Show", 200)
        widget.dd:SetItems({
            { text = "Any Dispellable Debuff", value = true,  onClick = function() widget.func(true) end },
            { text = "Only What I Can Dispel",  value = false, onClick = function() widget.func(false) end },
        })
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(val) widget.dd:SetSelectedValue(val ~= false) end
    else widget = settingWidgets["dispelShowAll"] end
    widget:Show(); return widget
end

local DISPEL_TYPE_ROWS = {
    { key = "Magic",   label = "Magic",   default = {0.20, 0.60, 1.00} },
    { key = "Curse",   label = "Curse",   default = {0.60, 0.00, 1.00} },
    { key = "Disease", label = "Disease", default = {0.60, 0.40, 0.00} },
    { key = "Poison",  label = "Poison",  default = {0.00, 0.60, 0.00} },
    { key = "Bleed",   label = "Bleed",   default = {0.75, 0.15, 0.15} },
}

local function CreateSetting_DispelTypeColors(parent)
    local widget
    if not settingWidgets["dispelTypeColors"] then
        widget = SF_CreateFrame("SFIndicatorSettings_DispelTypeColors", parent, 300, 190)
        settingWidgets["dispelTypeColors"] = widget
        widget.title = CreateLabel(widget, "Dispel Types", "TOPLEFT", 5, -5)
        widget.title:SetTextColor(W.C4(W.palette.HEADING))
        widget.title:SetFont(FONT_TEMPLATE, 12, "OUTLINE")

        widget._enabled = {}
        widget._colors = {}
        widget.rows = {}

        local function Fire()
            if widget.func then widget.func(widget._enabled, widget._colors) end
        end

        local prevCb
        for _, def in ipairs(DISPEL_TYPE_ROWS) do
            local cb = SF_CreateCheckButton(widget, def.label)
            if prevCb then cb:SetPoint("TOPLEFT", prevCb, "BOTTOMLEFT", 0, -10)
            else cb:SetPoint("TOPLEFT", widget.title, "BOTTOMLEFT", 0, -12) end
            cb.onClick = function(val) widget._enabled[def.key] = val; Fire() end

            local cp = W.CreateColorPicker(widget, nil,
                function()
                    local c = widget._colors[def.key] or def.default
                    return c[1], c[2], c[3]
                end,
                function(nr, ng, nb) widget._colors[def.key] = {nr, ng, nb}; Fire() end)
            cp:ClearAllPoints()
            cp:SetPoint("LEFT", widget, "LEFT", 160, 0)
            cp:SetPoint("TOP", cb, "TOP", 0, 0)

            widget.rows[def.key] = { cb = cb, cp = cp }
            prevCb = cb
        end

        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(enabledMap, colorsMap)
            widget._enabled = enabledMap or {}
            widget._colors = colorsMap or {}
            for _, def in ipairs(DISPEL_TYPE_ROWS) do
                local row = widget.rows[def.key]
                row.cb:SetChecked(widget._enabled[def.key] ~= false)
                if row.cp.UpdateSwatch then row.cp.UpdateSwatch() end
            end
        end
    else widget = settingWidgets["dispelTypeColors"] end
    widget:Show(); return widget
end

-- Types-only variant, for Dispel Icons.
--
-- Same five toggles as CreateSetting_DispelTypeColors, without the colour
-- pickers: the icons are Blizzard's own fixed dispel-type atlases
-- (RaidFrame-Icon-Debuff*), so there is no colour for the user to choose.
-- Writes the same t.dispelTypesEnabled shape the overlay uses, but into the
-- Dispel Icons indicator's own table -- the two indicators filter
-- independently, so you can (say) keep the overlay for everything while
-- showing a symbol only for Magic.
--
-- Laid out in two columns rather than the overlay's single column purely to
-- keep the panel short; five rows of colour swatches earn their height, five
-- bare toggles don't.
local function CreateSetting_DispelTypeToggles(parent)
    local widget
    if not settingWidgets["dispelTypes"] then
        widget = SF_CreateFrame("SFIndicatorSettings_DispelTypes", parent, 300, 110)
        settingWidgets["dispelTypes"] = widget
        widget.title = CreateLabel(widget, "Dispel Types", "TOPLEFT", 5, -5)
        widget.title:SetTextColor(W.C4(W.palette.HEADING))
        widget.title:SetFont(FONT_TEMPLATE, 12, "OUTLINE")

        widget._enabled = {}
        widget.rows = {}

        local PER_COLUMN = 3
        for i, def in ipairs(DISPEL_TYPE_ROWS) do
            local cb = SF_CreateCheckButton(widget, def.label)
            local col = (i <= PER_COLUMN) and 0 or 1
            local row = (i - 1) % PER_COLUMN
            cb:SetPoint("TOPLEFT", widget.title, "BOTTOMLEFT", col * 145, -12 - row * 26)
            cb.onClick = function(val)
                widget._enabled[def.key] = val
                if widget.func then widget.func(widget._enabled) end
            end
            widget.rows[def.key] = cb
        end

        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(enabledMap)
            widget._enabled = enabledMap or {}
            for _, def in ipairs(DISPEL_TYPE_ROWS) do
                -- Absent means on: profiles predating this setting have no map
                -- at all, and were showing every type.
                widget.rows[def.key]:SetChecked(widget._enabled[def.key] ~= false)
            end
        end
    else widget = settingWidgets["dispelTypes"] end
    widget:Show(); return widget
end

local function CreateSetting_DispelOverlay(parent)
    local widget
    if not settingWidgets["dispelOverlay"] then
        widget = SF_CreateFrame("SFIndicatorSettings_DispelOverlay", parent, 300, ROW_HEIGHT)
        settingWidgets["dispelOverlay"] = widget
        -- "gradient"/"gradientTop" are the same full-height ramp in opposite
        -- directions -- see ApplyDispelSlotStyle (12.1) and
        -- ApplyDispelOverlayColor (legacy). "gradient" keeps its original
        -- value string so existing profiles carry straight over.
        local opts = {"none", "fill", "full", "gradient", "gradientTop"}
        local optLabels = { none = "None", fill = "Fill (Health Loss)", full = "Full Frame",
            gradient = "Blizzard (Strong Bottom)", gradientTop = "Blizzard (Strong Top)" }
        widget.dd = LayoutDropdownRow(widget, "Overlay Style", 150)
        local items = {}
        for _, o in ipairs(opts) do
            table.insert(items, { text = optLabels[o], value = o, onClick = function() widget.func(o) end })
        end
        widget.dd:SetItems(items)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(val) widget.dd:SetSelectedValue(val or "fill") end
    else widget = settingWidgets["dispelOverlay"] end
    widget:Show(); return widget
end

local function CreateSetting_DispelOverlayOpacity(parent)
    local widget
    if not settingWidgets["dispelOverlayOpacity"] then
        widget = SF_CreateFrame("SFIndicatorSettings_DispelOverlayOpacity", parent, 300,75)
        settingWidgets["dispelOverlayOpacity"] = widget
        widget.slider = SF_CreateSlider("Overlay Opacity", widget, 0, 100, 230, 1)
        widget.slider:SetPoint("TOPLEFT", widget, 5, -20)
        widget.slider.afterValueChangedFn = function(value) widget.func(value) end
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(val) widget.slider:SetValue(val or 40) end
    else widget = settingWidgets["dispelOverlayOpacity"] end
    widget:Show(); return widget
end

-- Both of these apply to the two "Blizzard (...)" gradient overlay modes
-- only, and are inert in none/fill/full. They're always shown rather than
-- hidden per-mode, matching how Overlay Opacity already behaves in "none".
local function CreateSetting_DispelGradientHeight(parent)
    local widget
    if not settingWidgets["dispelGradientHeight"] then
        widget = SF_CreateFrame("SFIndicatorSettings_DispelGradientHeight", parent, 300, 75)
        settingWidgets["dispelGradientHeight"] = widget
        -- Floor of 5, not 0: a 0% ramp is just an invisible overlay, which
        -- "none" already covers more clearly.
        widget.slider = SF_CreateSlider("Gradient Height", widget, 5, 100, 230, 1)
        widget.slider:SetPoint("TOPLEFT", widget, 5, -20)
        widget.slider.afterValueChangedFn = function(value) widget.func(value) end
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(val) widget.slider:SetValue(val or 100) end
    else widget = settingWidgets["dispelGradientHeight"] end
    widget:Show(); return widget
end

local function CreateSetting_DispelGradientWeakAlpha(parent)
    local widget
    if not settingWidgets["dispelGradientWeakAlpha"] then
        widget = SF_CreateFrame("SFIndicatorSettings_DispelGradientWeakAlpha", parent, 300, 75)
        settingWidgets["dispelGradientWeakAlpha"] = widget
        -- % of Overlay Opacity, not an absolute alpha: 0 = fades out
        -- completely, 100 = flat tint with no visible ramp.
        widget.slider = SF_CreateSlider("Gradient Weak End", widget, 0, 100, 230, 1)
        widget.slider:SetPoint("TOPLEFT", widget, 5, -20)
        widget.slider.afterValueChangedFn = function(value) widget.func(value) end
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(val) widget.slider:SetValue(val or 50) end
    else widget = settingWidgets["dispelGradientWeakAlpha"] end
    widget:Show(); return widget
end

-- Dispels' Animated Border look (user request 2026-10-14). Each has its own
-- settingWidgets key -- the namespace is shared and caches one frame per key.
local function MakeSliderSetting(key, label, minV, maxV, step, default)
    return function(parent)
        local widget
        if not settingWidgets[key] then
            widget = SF_CreateFrame("SFIndicatorSettings_" .. key, parent, 300, 75)
            settingWidgets[key] = widget
            widget.slider = SF_CreateSlider(label, widget, minV, maxV, 230, step)
            widget.slider:SetPoint("TOPLEFT", widget, 5, -20)
            widget.slider.afterValueChangedFn = function(value) widget.func(value) end
            function widget:SetFunc(func) widget.func = func end
            function widget:SetDBValue(val) widget.slider:SetValue(val or default) end
        else widget = settingWidgets[key] end
        widget:Show(); return widget
    end
end
-- Defaults must match DISPEL_ANTS_DEFAULT_* in AuraEngineIndicators.lua.
-- Thickness tops out at the strips' built size (DISPEL_ANTS_MAX_THICKNESS).
local CreateSetting_DispelAntsThickness = MakeSliderSetting("dispelAntsThickness", "Border Thickness", 1, 8, 1, 2)
local CreateSetting_DispelAntsSpeed = MakeSliderSetting("dispelAntsSpeed", "Border Speed", 4, 64, 1, 16)

-- Three lengths, not a slider: the crawl only loops cleanly when the dash
-- period divides the fixed slide distance (see DISPEL_ANTS_PERIODS).
local function CreateSetting_DispelAntsDash(parent)
    local widget
    if not settingWidgets["dispelAntsDash"] then
        widget = SF_CreateFrame("SFIndicatorSettings_DispelAntsDash", parent, 300, 58)
        settingWidgets["dispelAntsDash"] = widget
        widget.dd = SF_CreateDropdown(widget, 230)
        widget.dd:SetPoint("TOPLEFT", 10, -20)
        widget.ddText = CreateLabel(widget, "Dash Length", "BOTTOMLEFT", 10, 1)
        widget.ddText:SetPoint("BOTTOMLEFT", widget.dd, "TOPLEFT", 0, 1)
        local items = {}
        for _, opt in ipairs({ { "short", "Short" }, { "medium", "Medium" }, { "long", "Long" } }) do
            items[#items + 1] = {
                text = opt[2], value = opt[1],
                onClick = function() if widget.func then widget.func(opt[1]) end end,
            }
        end
        widget.dd:SetItems(items)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(val) widget.dd:SetSelectedValue(val or "medium") end
    else widget = settingWidgets["dispelAntsDash"] end
    widget:Show(); return widget
end

-- Only read while Custom Border Colour is ticked; the type's colour otherwise.
local function CreateSetting_DispelAntsColor(parent)
    local widget
    if not settingWidgets["dispelAntsColor"] then
        widget = SF_CreateFrame("SFIndicatorSettings_DispelAntsColor", parent, 300, 38)
        settingWidgets["dispelAntsColor"] = widget
        local _r, _g, _b, _a = 1, 1, 1, 1
        widget.color = W.CreateColorPicker(widget, "Border Colour",
            function() return _r, _g, _b, _a end,
            function(r, g, b, a)
                _r, _g, _b, _a = r, g, b, a
                -- See CreateSetting_ColorAlpha: the alpha slider fires this
                -- during its own construction, before SetFunc has run.
                if widget.func then widget.func({"custom_color", r, g, b, a}) end
            end)
        widget.color:SetPoint("TOPLEFT", 5, -8)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(c)
            if c and c[1] == "custom_color" and #c >= 4 then
                _r, _g, _b, _a = c[2], c[3], c[4], c[5] or 1
            else
                _r, _g, _b, _a = 1, 1, 1, 1
            end
            widget.color.UpdateSwatch()
        end
    else widget = settingWidgets["dispelAntsColor"] end
    widget:Show(); return widget
end

-- Private Auras' duration/stack text size. Expressed as a percentage
-- multiplier rather than a font height because Blizzard owns those
-- FontStrings -- the size is achieved by scaling the frame they're drawn in
-- (for the since-removed Private Auras indicator), so there is no point size to set.
--
-- The text already tracks icon size automatically; this multiplies that.
local function CreateSetting_TextScale(parent)
    local widget
    if not settingWidgets["textScale"] then
        widget = SF_CreateFrame("SFIndicatorSettings_TextScale", parent, 300, 75)
        settingWidgets["textScale"] = widget
        widget.slider = SF_CreateSlider("Duration / Stack Text Size (%)", widget, 25, 300, 230, 5)
        widget.slider:SetPoint("TOPLEFT", widget, 5, -20)
        -- Stored as a plain multiplier (1.0 = 100%) to match how
        -- The since-removed Private Auras indicator consumed it; the slider works in percent so the
        -- number reads sensibly to the user.
        widget.slider.afterValueChangedFn = function(value) widget.func(value / 100) end
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(val) widget.slider:SetValue((tonumber(val) or 1) * 100) end
    else widget = settingWidgets["textScale"] end
    widget:Show(); return widget
end

SquizzFrames.IndicatorWidgetsDispels = {
    CreateSetting_DispelFilters = CreateSetting_DispelFilters,
    CreateSetting_TargetCounterFilters = CreateSetting_TargetCounterFilters,
    CreateSetting_RoleFilters = CreateSetting_RoleFilters,
    CreateSetting_DispelShowAll = CreateSetting_DispelShowAll,
    CreateSetting_DispelTypeColors = CreateSetting_DispelTypeColors,
    CreateSetting_DispelTypeToggles = CreateSetting_DispelTypeToggles,
    CreateSetting_DispelOverlay = CreateSetting_DispelOverlay,
    CreateSetting_DispelOverlayOpacity = CreateSetting_DispelOverlayOpacity,
    CreateSetting_DispelGradientHeight = CreateSetting_DispelGradientHeight,
    CreateSetting_DispelGradientWeakAlpha = CreateSetting_DispelGradientWeakAlpha,
    CreateSetting_DispelAntsThickness = CreateSetting_DispelAntsThickness,
    CreateSetting_DispelAntsSpeed = CreateSetting_DispelAntsSpeed,
    CreateSetting_DispelAntsDash = CreateSetting_DispelAntsDash,
    CreateSetting_DispelAntsColor = CreateSetting_DispelAntsColor,
    CreateSetting_TextScale = CreateSetting_TextScale,
}
