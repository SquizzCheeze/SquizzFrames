--[[ SquizzFrames IndicatorWidgets.lua
-- Indicator-option widgets built from a token array.
--
-- Provides SquizzFrames.CreateIndicatorSettings(parent, settingsTable)
-- which builds the full set of indicator-option widgets for a given
-- indicator from its token list. The returned widgets expose :SetDBValue()
-- and :SetFunc() for the ShowIndicatorSettings binding block to wire into.
--
-- Dependencies: SquizzFrames.Modules.Options.Widgets (loaded as W)
--]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local W = SquizzFrames.Widgets
if not W then return end

local F = SquizzFrames.F

-----------------------------------------------------------------------
-- Compat wrappers: late-binding widget API → SquizzFrames widget API
-----------------------------------------------------------------------

-- Plain Frame for one setting row. Cell's convention wraps every single
-- setting in its own bordered/backdropped box ("SetBackdrop" bg+edge below,
-- now removed) -- stacked, that reads as a tower of small grey cards. The
-- settingsPane behind these rows already has its own dark backdrop (see
-- IndicatorsPanel.lua), so rows don't need one of their own for contrast --
-- just a hairline divider along the bottom to separate rows, matching a
-- flat modern settings-list look (Discord/Windows 11 style) instead of
-- Cell's card stack.
local function SF_CreateFrame(name, parent, w, h)
    local f = CreateFrame("Frame", name, parent)
    f:SetSize(w or 240, h or 50)
    f:SetClipsChildren(true)

    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 1, 1, 0.07)
    divider:SetPoint("BOTTOMLEFT", 2, 0)
    divider:SetPoint("BOTTOMRIGHT", -2, 0)
    divider:SetHeight(1)
    f.divider = divider

    -- Hover highlight: with the per-setting box gone, there's no edge to
    -- imply "this is the row you're on" -- tint the row with the accent
    -- color under the cursor so it's clear which setting you're interacting
    -- with. EnableMouse on this outer frame doesn't block the child
    -- checkbox/dropdown/slider's own clicks -- WoW dispatches OnEnter/
    -- OnLeave to a frame based on cursor-over-rect independent of whatever
    -- its children do with mouse events.
    local hoverBG = f:CreateTexture(nil, "BACKGROUND")
    hoverBG:SetAllPoints()
    hoverBG:Hide()
    f.hoverBG = hoverBG
    f:EnableMouse(true)
    f:SetScript("OnEnter", function()
        local a = F.GetAccentColor and F.GetAccentColor()
        if a then
            hoverBG:SetColorTexture(a.r, a.g, a.b, 0.08)
        else
            hoverBG:SetColorTexture(1, 1, 1, 0.06)
        end
        hoverBG:Show()
    end)
    f:SetScript("OnLeave", function()
        hoverBG:Hide()
    end)

    return f
end

-- CheckButton with late-binding API
-- Returns a frame with .onClick (assignable), :SetChecked(checked)
local function SF_CreateCheckButton(parent, label)
    local state = false
    local cb = W.CreateStyledCheckbox(parent, label,
        function() return state end,
        function(val) state = val end)
    cb.onClick = nil -- assigned later by SetFunc
    local origSetChecked = cb.SetChecked
    function cb:SetChecked(checked)
        state = not not checked
        if origSetChecked then origSetChecked(self, checked) end
    end
    -- The underlying CheckButton already has an OnClick script (set by
    -- CreateStyledCheckbox). Hook it so the late-bound .onClick callback
    -- fires after state is updated (so callbacks read the new state).
    cb:HookScript("OnClick", function() if cb.onClick then cb.onClick(state) end end)
    return cb
end

-- Dropdown with late-binding API
-- Returns a frame with :SetItems(items), :SetSelectedValue(val),
-- :SetSelectedItem(index), :GetSelected(), .func (callback)
local function SF_CreateDropdown(parent, width)
    -- Must be a Button (not a Frame) so it supports an OnClick script.
    local dd = CreateFrame("Button", nil, parent, "BackdropTemplate")
    dd:SetSize(width or 110, 24)

    dd.text = dd:CreateFontString(nil, "OVERLAY")
    dd.text:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    dd.text:SetPoint("LEFT", 10, 0)
    dd.text:SetPoint("RIGHT", -20, 0)  -- widened when a preview icon is shown (see UpdateText)
    dd.text:SetJustifyH("LEFT")
    dd.text:SetWordWrap(false)
    dd.text:SetTextColor(1, 1, 1, 1)

    -- Preview icon in the dropdown button itself (on the right side)
    dd.previewIcon = dd:CreateTexture(nil, "ARTWORK")
    dd.previewIcon:SetSize(48, 16)  -- 3x wider to show all 3 roles (TANK/HEALER/DAMAGER)
    dd.previewIcon:SetPoint("RIGHT", -10, 0)
    dd.previewIcon:Hide()

    -- Plain ASCII "v", not a Unicode triangle (e.g. "▾") -- Blizzard's bundled
    -- fonts (Friz Quadrata included) only cover a sparse glyph set and render
    -- unsupported symbols as a tofu box; "v" is guaranteed present in every
    -- font and reads as a caret well enough.
    dd.arrow = dd:CreateFontString(nil, "OVERLAY")
    dd.arrow:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    dd.arrow:SetPoint("RIGHT", dd, "RIGHT", -6, -1)
    do
        local a = F.GetAccentColor()
        dd.arrow:SetTextColor(a.r, a.g, a.b, 1)
    end
    dd.arrow:SetText("v")

    dd:SetBackdrop({
        bgFile = [[Interface\Buttons\WHITE8X8]],
        edgeFile = [[Interface\Buttons\WHITE8X8]],
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    dd:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    dd:SetBackdropBorderColor(0, 0, 0, 1)

    dd.items = {}
    dd._selectedValue = nil
    dd._selectedIndex = nil

    local popup = nil
    local closer = nil
    local isOpen = false

    local function ClosePopup()
        if popup then popup:Hide(); popup = nil end
        if closer then closer:Hide() end
        isOpen = false
    end

    -- The preview icon (role/texture choosers) eats space on the right of the
    -- button; text-only dropdowns (orientation, relative-to, etc.) shouldn't
    -- pay that cost, so the text region is only narrowed when an icon is
    -- actually being shown for the current selection.
    local function SetTextRegion(iconShown)
        dd.text:ClearAllPoints()
        dd.text:SetPoint("LEFT", 10, 0)
        dd.text:SetPoint("RIGHT", iconShown and -70 or -20, 0)
    end

    local function UpdateText()
        for _, item in ipairs(dd.items) do
            if item.value == dd._selectedValue then
                dd.text:SetText(item.text or "")
                -- Show preview icon in button if item has icon
                if item.icon then
                    dd.previewIcon:SetTexture(item.icon)
                    if item.iconCoords then
                        dd.previewIcon:SetTexCoord(unpack(item.iconCoords))
                    else
                        dd.previewIcon:SetTexCoord(0, 1, 0, 1)
                    end
                    dd.previewIcon:Show()
                    SetTextRegion(true)
                else
                    dd.previewIcon:Hide()
                    SetTextRegion(false)
                end
                return
            end
        end
        dd.text:SetText("")
        dd.previewIcon:Hide()
        SetTextRegion(false)
    end

    local function OpenPopup()
        if isOpen then ClosePopup(); return end
        ClosePopup()
        local n = #dd.items
        if n == 0 then return end

        popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        popup:SetFrameStrata("TOOLTIP")
        popup:SetFrameLevel(100)
        local left, bottom = dd:GetLeft(), dd:GetBottom()
        if left and bottom and left > 0 and bottom > 0 then
            popup:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, bottom - 2)
        else
            popup:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -2)
        end
        -- Long item lists (LibSharedMedia's full statusbar registry, for the
        -- bar-texture pickers) previously made this popup grow tall enough
        -- to run off the bottom of the screen with no way to reach the rest
        -- -- confirmed via user report + screenshot. Cap the visible height
        -- and scroll past that instead of growing unbounded (same fix as
        -- Widgets.lua's CreateStyledDropdown, which this dropdown does NOT
        -- share code with despite the similar look -- this file has its own
        -- separate local SF_CreateDropdown implementation).
        local itemH = 22 -- taller for icons
        local MAX_VISIBLE_ITEMS = 12
        local needsScroll = n > MAX_VISIBLE_ITEMS
        local visibleCount = needsScroll and MAX_VISIBLE_ITEMS or n
        popup:SetSize(dd:GetWidth(), visibleCount * itemH + 4)
        popup:SetBackdrop({
            bgFile = [[Interface\Buttons\WHITE8X8]],
            edgeFile = [[Interface\Buttons\WHITE8X8]],
            edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 },
        })
        popup:SetBackdropColor(0.12, 0.12, 0.12, 1)
        popup:SetBackdropBorderColor(0, 0, 0, 1)

        -- Rows parent to a scroll frame's content child when scrolling is
        -- needed (CreateScrollFrame reserves 18px on the right for its
        -- scrollbar, so rows there are narrower than the plain-popup case).
        local rowParent = popup
        local rowWidth = popup:GetWidth() - 4
        if needsScroll and W and W.CreateScrollFrame then
            local scroll = W.CreateScrollFrame(popup)
            scroll.scrollChild:SetHeight(n * itemH)
            rowParent = scroll.scrollChild
            rowWidth = popup:GetWidth() - 18 - 4
        end

        for i, item in ipairs(dd.items) do
            local row = CreateFrame("Frame", nil, rowParent, "BackdropTemplate")
            row:SetSize(rowWidth, itemH)
            row:SetPoint("TOPLEFT", 2, -(i - 1) * itemH - 2)
            row:SetBackdrop({ bgFile = [[Interface\Buttons\WHITE8X8]] })
            row:SetBackdropColor(0.12, 0.12, 0.12, 1)
            row:EnableMouse(true)

            -- Icon in dropdown row (only text-only rows reclaim its space --
            -- otherwise a 48px gap sits unused and starves the text region)
            local icon = row:CreateTexture(nil, "ARTWORK")
            if item.icon then
                icon:SetSize(48, 16)  -- 3x wider to show all 3 roles (TANK/HEALER/DAMAGER)
                icon:SetPoint("LEFT", 3, 0)
                icon:SetTexture(item.icon)
                if item.iconCoords then
                    icon:SetTexCoord(unpack(item.iconCoords))
                else
                    icon:SetTexCoord(0, 1, 0, 1)
                end
                icon:Show()
            else
                icon:Hide()
            end

            local t = row:CreateFontString(nil, "OVERLAY")
            t:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
            if item.icon then
                t:SetPoint("LEFT", icon, "RIGHT", 4, 0)
            else
                t:SetPoint("LEFT", 6, 0)
            end
            t:SetPoint("RIGHT", -6, 0)
            t:SetJustifyH("LEFT")
            t:SetWordWrap(false)
            t:SetText(item.text or "")

            row:SetScript("OnMouseDown", function()
                dd._selectedValue = item.value
                dd._selectedIndex = i
                UpdateText()
                ClosePopup()
                if item.onClick then item.onClick() end
            end)
            row:SetScript("OnEnter", function()
                local a = F.GetAccentColor()
                row:SetBackdropColor(a.r * 0.4, a.g * 0.4, a.b * 0.4, 1)
            end)
            row:SetScript("OnLeave", function() row:SetBackdropColor(0.12, 0.12, 0.12, 1) end)
        end

        closer = CreateFrame("Button", nil, UIParent)
        closer:SetAllPoints(UIParent)
        closer:SetFrameStrata("TOOLTIP")
        closer:SetFrameLevel(99)
        closer:EnableMouse(true)
        closer:SetScript("OnClick", function() ClosePopup() end)
        isOpen = true
    end

    dd:EnableMouse(true)
    dd:SetScript("OnClick", function() OpenPopup() end)
    dd:SetScript("OnEnter", function()
        local a = F.GetAccentColor()
        dd:SetBackdropBorderColor(a.r, a.g, a.b, 0.6)
    end)
    dd:SetScript("OnLeave", function() dd:SetBackdropBorderColor(0, 0, 0, 1) end)

    function dd:SetItems(items) self.items = items; UpdateText() end
    function dd:SetSelectedValue(val) self._selectedValue = val; UpdateText() end
    function dd:SetSelectedItem(index)
        self._selectedIndex = index
        if self.items and self.items[index] then self._selectedValue = self.items[index].value end
        UpdateText()
    end
    function dd:GetSelected() return self._selectedValue end

    return dd
end

-- Slider with late-binding API
-- Returns a frame with :SetValue(val), :GetValue(), :UpdateMinMaxValues(min,max),
-- and .afterValueChangedFn (assignable callback).
-- Matches the Layout/Appearance tabs' CreateStyledSlider design: thin
-- accent-fill track, low/high range labels under the ends, and a click-to-type
-- editbox centered underneath so an exact value can be typed instead of only
-- dragged.
local function SF_CreateSlider(label, parent, min, max, width, step)
    local _value = min
    local _min, _max = min, max
    local sliderWidth = width or 110
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(sliderWidth + 20, 50)

    local title = container:CreateFontString(nil, "OVERLAY")
    title:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    title:SetPoint("TOPLEFT", 10, 0)
    title:SetTextColor(1, 1, 1, 1)
    title:SetText(label or "")

    local slider = CreateFrame("Slider", nil, container, "BackdropTemplate")
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(sliderWidth, 4)
    slider:SetPoint("TOPLEFT", 10, -18)
    slider:SetMinMaxValues(_min, _max)
    slider:SetValueStep(step or 1)
    slider:SetObeyStepOnDrag(true)

    slider:SetBackdrop({
        bgFile = [[Interface\Buttons\WHITE8X8]],
        edgeFile = [[Interface\Buttons\WHITE8X8]],
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    slider:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    slider:SetBackdropBorderColor(0, 0, 0, 1)

    -- Accent fill from the left edge up to the current value.
    local fill = slider:CreateTexture(nil, "ARTWORK")
    local accent = F.GetAccentColor()
    fill:SetColorTexture(accent.r, accent.g, accent.b, 0.85)
    fill:SetPoint("TOPLEFT", 0, 0)
    fill:SetPoint("BOTTOMLEFT", 0, 0)
    fill:SetWidth(1)

    -- Square thumb riding above the thin track; brightens to the accent color
    -- on hover, matching CreateStyledSlider.
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(10, 10)
    thumb:SetColorTexture(1, 1, 1, 1)
    slider:SetThumbTexture(thumb)

    -- Low/High range labels under the track ends.
    local lowText = slider:CreateFontString(nil, "OVERLAY")
    lowText:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
    lowText:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -4)
    lowText:SetTextColor(0.6, 0.58, 0.54, 1)
    lowText:SetText(tostring(_min))

    local highText = slider:CreateFontString(nil, "OVERLAY")
    highText:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
    highText:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 0, -4)
    highText:SetTextColor(0.6, 0.58, 0.54, 1)
    highText:SetText(tostring(_max))

    -- Current value editbox -- click it to type an exact number.
    local editBox = CreateFrame("EditBox", nil, container, "BackdropTemplate")
    editBox:SetPoint("TOP", slider, "BOTTOM", 0, -4)
    editBox:SetSize(52, 16)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(10)
    editBox:SetJustifyH("CENTER")
    editBox:SetBackdrop({
        bgFile = [[Interface\Buttons\WHITE8X8]],
        edgeFile = [[Interface\Buttons\WHITE8X8]],
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    editBox:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    editBox:SetBackdropBorderColor(0, 0, 0, 1)
    editBox:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    editBox:SetTextColor(1, 1, 1, 1)

    local function UpdateFill()
        local sliderW = slider:GetWidth() or sliderWidth
        local frac = (_max > _min) and ((_value - _min) / (_max - _min)) or 0
        frac = math.max(0, math.min(1, frac))
        fill:SetWidth(math.max(1, sliderW * frac))
    end

    local function FormatValue(v)
        if step and step < 1 then return string.format("%.2f", v) end
        return string.format("%d", v)
    end

    local function UpdateValText()
        editBox:SetText(FormatValue(slider:GetValue()))
    end
    slider:SetValue(_value)
    UpdateValText()
    UpdateFill()

    container.afterValueChangedFn = nil
    local settingDB = false
    slider:SetScript("OnValueChanged", function(self, val)
        _value = val; UpdateValText(); UpdateFill()
        if not settingDB and container.afterValueChangedFn then container.afterValueChangedFn(val) end
    end)

    slider:SetScript("OnEnter", function()
        thumb:SetColorTexture(accent.r, accent.g, accent.b, 1)
    end)
    slider:SetScript("OnLeave", function()
        thumb:SetColorTexture(1, 1, 1, 1)
    end)

    editBox:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val then
            val = math.max(_min, math.min(_max, val))
            if step and step >= 1 then val = math.floor(val / step + 0.5) * step end
            slider:SetValue(val)
        end
        self:ClearFocus()
    end)
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        UpdateValText()
    end)
    editBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)

    function container:SetValue(val)
        settingDB = true
        _value = val; slider:SetValue(val); UpdateValText()
        settingDB = false
    end
    function container:GetValue() return _value end
    function container:UpdateMinMaxValues(lo, hi)
        _min, _max = lo, hi
        lowText:SetText(tostring(lo))
        highText:SetText(tostring(hi))
        settingDB = true
        slider:SetMinMaxValues(lo, hi)
        settingDB = false
        UpdateFill()
    end

    return container
end

-- EditBox
local function SF_CreateEditBox(parent, width, height, numeric, multiLine, autoSelect)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(width or 60, height or 20)
    eb:SetAutoFocus(false)
    eb:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    if numeric then eb:SetNumeric(true) end
    if autoSelect then eb:HookScript("OnEditFocusGained", function(self) self:HighlightText() end) end
    return eb
end

-- Button
local function SF_CreateButton(parent, text, style, size)
    return W.CreateStyledButton(parent, text, style == "red" and "red" or "accent",
        size or {60, 20}, function() end)
end

-- Enable/disable a list of widgets
local function SF_SetEnabled(enabled, ...)
    for i = 1, select("#", ...) do
        local w = select(i, ...)
        if w then
            if enabled then if w.Enable then w:Enable() end
            else if w.Disable then w:Disable() end end
        end
    end
end

-----------------------------------------------------------------------
-- Shared state and helpers
-----------------------------------------------------------------------
local settingWidgets = {}
local anchorPoints = {"BOTTOM", "BOTTOMLEFT", "BOTTOMRIGHT", "CENTER", "LEFT", "RIGHT", "TOP", "TOPLEFT", "TOPRIGHT"}
local anchorPoints_noHCenter = {"BOTTOMLEFT", "BOTTOMRIGHT", "LEFT", "RIGHT", "TOPLEFT", "TOPRIGHT"}

local FONT_TEMPLATE = "Fonts\\FRIZQT__.TTF"
local function CreateLabel(parent, text, anchor, offX, offY)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT_TEMPLATE, 11, "OUTLINE")
    fs:SetPoint(anchor or "TOPLEFT", offX or 0, offY or 0)
    fs:SetTextColor(0.7, 0.7, 0.7, 1)
    fs:SetText(text or "")
    return fs
end

-- Single-row "label left, control right-aligned" layout for the many
-- settings that are just one dropdown -- label vertically centered on the
-- left, dropdown pinned to the right edge. Replaces the old "label above,
-- dropdown below" stack (which needed a taller 58px box); these rows only
-- need ROW_HEIGHT, so callers should size their SF_CreateFrame to match
-- (also update the token's height estimate in IndicatorsPanel.lua's
-- TOKEN_HEIGHTS).
local ROW_HEIGHT = 34
local function LayoutDropdownRow(widget, labelText, ddWidth)
    local dd = SF_CreateDropdown(widget, ddWidth)
    dd:SetPoint("RIGHT", -6, 0)
    widget.ddText = CreateLabel(widget, labelText, "LEFT", 8, 0)
    return dd
end

-----------------------------------------------------------------------
-- CreateSetting_* helpers
-----------------------------------------------------------------------

local function CreateSetting_Enabled(parent)
    local widget
    if not settingWidgets["enabled"] then
        widget = SF_CreateFrame("SFIndicatorSettings_Enabled", parent, 300,38)
        settingWidgets["enabled"] = widget
        widget.cb = SF_CreateCheckButton(widget, "Enabled")
        widget.cb:SetPoint("TOPLEFT", 5, -8)
        function widget:SetFunc(func) widget.cb.onClick = func end
        function widget:SetDBValue(checked) widget.cb:SetChecked(checked) end
    else widget = settingWidgets["enabled"] end
    widget:Show(); return widget
end

local function CreateSetting_Position(parent)
    local widget
    if not settingWidgets["position"] then
        -- Layout (all Y negative = downward in WoW), with a 14px title row:
        --  y= -32  row1: Anchor Point (110) | Relative Point (110)
        --  y= -70  row2: Relative To (110)
        --  y=-108  row3: X Offset slider (110)
        --  y=-158  row4: Y Offset slider (110)
        -- total height ~199
        widget = SF_CreateFrame("SFIndicatorSettings_Position", parent, 300, 199)
        settingWidgets["position"] = widget

        -- Section title -- see CreateSetting_DurationPosition's for the full
        -- reasoning. This block is generically "where the indicator sits",
        -- which only needs saying when something else on the same page is
        -- also an anchor+offset control (Private Auras' duration text).
        local a = F.GetAccentColor()
        widget.title = widget:CreateFontString(nil, "OVERLAY")
        widget.title:SetFont(FONT_TEMPLATE, 12, "OUTLINE")
        widget.title:SetPoint("TOPLEFT", 5, -4)
        widget.title:SetTextColor(a.r, a.g, a.b, 1)
        widget.title:SetText("Indicator Position")

        local function GetResult()
            return {widget.anchor:GetSelected(), widget.relativeTo:GetSelected(),
                    widget.relativePoint:GetSelected(), widget.x:GetValue(), widget.y:GetValue()}
        end

        -- Row 1: Anchor Point + Relative Point
        widget.anchor = SF_CreateDropdown(widget, 110)
        widget.anchor:SetPoint("TOPLEFT", 10, -32)
        local items = {}
        for _, point in ipairs(anchorPoints) do
            table.insert(items, { text = point, value = point, onClick = function() widget.func(GetResult()) end })
        end
        widget.anchor:SetItems(items)
        widget.anchorText = CreateLabel(widget, "Anchor Point", "BOTTOMLEFT", 10, 1)
        widget.anchorText:SetPoint("BOTTOMLEFT", widget.anchor, "TOPLEFT", 0, 1)

        widget.relativePoint = SF_CreateDropdown(widget, 110)
        widget.relativePoint:SetPoint("TOPLEFT", widget.anchor, "TOPRIGHT", 10, 0)
        items = {}
        for _, point in ipairs(anchorPoints) do
            table.insert(items, { text = point, value = point, onClick = function() widget.func(GetResult()) end })
        end
        widget.relativePoint:SetItems(items)
        widget.relativePointText = CreateLabel(widget, "Relative Point", "BOTTOMLEFT", 10, 1)
        widget.relativePointText:SetPoint("BOTTOMLEFT", widget.relativePoint, "TOPLEFT", 0, 1)

        -- Row 2: Relative To
        widget.relativeTo = SF_CreateDropdown(widget, 110)
        widget.relativeTo:SetPoint("TOPLEFT", widget.anchor, "BOTTOMLEFT", 0, -14)
        widget.relativeTo:SetItems({
            { text = "Unit Button", value = "button",    onClick = function() widget.func(GetResult()) end },
            { text = "Health Bar",  value = "healthBar", onClick = function() widget.func(GetResult()) end },
        })
        widget.relativeToText = CreateLabel(widget, "Relative To", "BOTTOMLEFT", 10, 1)
        widget.relativeToText:SetPoint("BOTTOMLEFT", widget.relativeTo, "TOPLEFT", 0, 1)

        -- Row 3: X Offset | Y Offset side by side
        widget.x = SF_CreateSlider("X Offset", widget, -150, 150, 110, 1)
        widget.x:SetPoint("TOPLEFT", widget.relativeTo, "BOTTOMLEFT", 0, -14)
        widget.x.afterValueChangedFn = function() widget.func(GetResult()) end

        widget.y = SF_CreateSlider("Y Offset", widget, -150, 150, 110, 1)
        widget.y:SetPoint("TOPLEFT", widget.x, "TOPRIGHT", 5, 0)
        widget.y.afterValueChangedFn = function() widget.func(GetResult()) end

        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(positionTable)
            widget.anchor:SetSelectedValue(positionTable[1])
            widget.relativePoint:SetSelectedValue(positionTable[3])
            widget.relativeTo:SetSelectedValue(positionTable[2])
            widget.x:SetValue(positionTable[4])
            widget.y:SetValue(positionTable[5])
        end
    else widget = settingWidgets["position"] end
    widget:Show(); return widget
end

-- Where Blizzard draws the DURATION TEXT inside a private aura icon
-- (C_UnitAuras.AddPrivateAuraAnchor's `durationAnchor` field). Deliberately
-- simpler than CreateSetting_Position: there's no "Relative To" row, because
-- the duration text can only ever be anchored to its own aura holder -- the
-- API takes a single anchor binding, not an arbitrary parent.
--
-- No font/size control here on purpose: Blizzard owns that FontString and the
-- API exposes no way to restyle it (for the since-removed Private Auras indicator).
local function CreateSetting_DurationPosition(parent)
    local widget
    if not settingWidgets["durationPosition"] then
        -- Layout (14px title row up top, then the same two-row stack as
        -- CreateSetting_Position minus its "Relative To" row):
        --  y= -32  row1: Anchor Point (110) | Relative Point (110)
        --  y= -84  row2: X Offset (110) | Y Offset (110)
        widget = SF_CreateFrame("SFIndicatorSettings_DurationPosition", parent, 300, 148)
        settingWidgets["durationPosition"] = widget

        -- Section title. Private Auras stacks this block directly above the
        -- indicator's own "Position" block, and both are anchor-point +
        -- offset controls that look identical at a glance -- without titles
        -- there's nothing saying which one moves the duration TEXT and which
        -- moves the whole indicator (confirmed by user report). Same
        -- reasoning and styling as the Stack Font / Duration Font titles.
        local a = F.GetAccentColor()
        widget.title = widget:CreateFontString(nil, "OVERLAY")
        widget.title:SetFont(FONT_TEMPLATE, 12, "OUTLINE")
        widget.title:SetPoint("TOPLEFT", 5, -4)
        widget.title:SetTextColor(a.r, a.g, a.b, 1)
        widget.title:SetText("Duration Text Position")

        local function GetResult()
            return {widget.anchor:GetSelected(), widget.relativePoint:GetSelected(),
                    widget.x:GetValue(), widget.y:GetValue()}
        end

        widget.anchor = SF_CreateDropdown(widget, 110)
        widget.anchor:SetPoint("TOPLEFT", 10, -32)
        local items = {}
        for _, point in ipairs(anchorPoints) do
            table.insert(items, { text = point, value = point, onClick = function() widget.func(GetResult()) end })
        end
        widget.anchor:SetItems(items)
        widget.anchorText = CreateLabel(widget, "Duration Anchor", "BOTTOMLEFT", 10, 1)
        widget.anchorText:SetPoint("BOTTOMLEFT", widget.anchor, "TOPLEFT", 0, 1)

        widget.relativePoint = SF_CreateDropdown(widget, 110)
        widget.relativePoint:SetPoint("TOPLEFT", widget.anchor, "TOPRIGHT", 10, 0)
        items = {}
        for _, point in ipairs(anchorPoints) do
            table.insert(items, { text = point, value = point, onClick = function() widget.func(GetResult()) end })
        end
        widget.relativePoint:SetItems(items)
        widget.relativePointText = CreateLabel(widget, "To Icon Point", "BOTTOMLEFT", 10, 1)
        widget.relativePointText:SetPoint("BOTTOMLEFT", widget.relativePoint, "TOPLEFT", 0, 1)

        widget.x = SF_CreateSlider("X Offset", widget, -50, 50, 110, 1)
        widget.x:SetPoint("TOPLEFT", widget.anchor, "BOTTOMLEFT", 0, -32)
        widget.x.afterValueChangedFn = function() widget.func(GetResult()) end

        widget.y = SF_CreateSlider("Y Offset", widget, -50, 50, 110, 1)
        widget.y:SetPoint("TOPLEFT", widget.x, "TOPRIGHT", 5, 0)
        widget.y.afterValueChangedFn = function() widget.func(GetResult()) end

        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(t)
            t = t or {}
            widget.anchor:SetSelectedValue(t[1] or "BOTTOMRIGHT")
            widget.relativePoint:SetSelectedValue(t[2] or "BOTTOMRIGHT")
            widget.x:SetValue(t[3] or 0)
            widget.y:SetValue(t[4] or 0)
        end
    else widget = settingWidgets["durationPosition"] end
    widget:Show(); return widget
end

local function CreateSetting_PositionNoHCenter(parent)
    local widget
    if not settingWidgets["position_noHCenter"] then
        widget = SF_CreateFrame("SFIndicatorSettings_PositionNoHCenter", parent, 300, 199)
        settingWidgets["position_noHCenter"] = widget

        -- Section title, same as CreateSetting_Position's (this is the same
        -- control, just with the horizontal-center anchors removed) so the
        -- two share one height estimate and read identically.
        local a = F.GetAccentColor()
        widget.title = widget:CreateFontString(nil, "OVERLAY")
        widget.title:SetFont(FONT_TEMPLATE, 12, "OUTLINE")
        widget.title:SetPoint("TOPLEFT", 5, -4)
        widget.title:SetTextColor(a.r, a.g, a.b, 1)
        widget.title:SetText("Indicator Position")

        local function GetResult()
            return {widget.anchor:GetSelected(), widget.relativeTo:GetSelected(),
                    widget.relativePoint:GetSelected(), widget.x:GetValue(), widget.y:GetValue()}
        end

        -- Row 1: Anchor Point + Relative Point
        widget.anchor = SF_CreateDropdown(widget, 110)
        widget.anchor:SetPoint("TOPLEFT", 10, -32)
        local items = {}
        for _, point in ipairs(anchorPoints_noHCenter) do
            table.insert(items, { text = point, value = point, onClick = function() widget.func(GetResult()) end })
        end
        widget.anchor:SetItems(items)
        widget.anchorText = CreateLabel(widget, "Anchor Point", "BOTTOMLEFT", 10, 1)
        widget.anchorText:SetPoint("BOTTOMLEFT", widget.anchor, "TOPLEFT", 0, 1)

        widget.relativePoint = SF_CreateDropdown(widget, 110)
        widget.relativePoint:SetPoint("TOPLEFT", widget.anchor, "TOPRIGHT", 10, 0)
        items = {}
        for _, point in ipairs(anchorPoints_noHCenter) do
            table.insert(items, { text = point, value = point, onClick = function() widget.func(GetResult()) end })
        end
        widget.relativePoint:SetItems(items)
        widget.relativePointText = CreateLabel(widget, "Relative Point", "BOTTOMLEFT", 10, 1)
        widget.relativePointText:SetPoint("BOTTOMLEFT", widget.relativePoint, "TOPLEFT", 0, 1)

        -- Row 2: Relative To
        widget.relativeTo = SF_CreateDropdown(widget, 110)
        widget.relativeTo:SetPoint("TOPLEFT", widget.anchor, "BOTTOMLEFT", 0, -14)
        widget.relativeTo:SetItems({
            { text = "Unit Button", value = "button",    onClick = function() widget.func(GetResult()) end },
            { text = "Health Bar",  value = "healthBar", onClick = function() widget.func(GetResult()) end },
        })
        widget.relativeToText = CreateLabel(widget, "Relative To", "BOTTOMLEFT", 10, 1)
        widget.relativeToText:SetPoint("BOTTOMLEFT", widget.relativeTo, "TOPLEFT", 0, 1)

        -- Row 3: X Offset slider
        widget.x = SF_CreateSlider("X Offset", widget, -150, 150, 220, 1)
        widget.x:SetPoint("TOPLEFT", widget.relativeTo, "BOTTOMLEFT", 0, -14)
        widget.x.afterValueChangedFn = function() widget.func(GetResult()) end

        -- Row 4: Y Offset slider
        widget.y = SF_CreateSlider("Y Offset", widget, -150, 150, 220, 1)
        widget.y:SetPoint("TOPLEFT", widget.x, "BOTTOMLEFT", 0, -8)
        widget.y.afterValueChangedFn = function() widget.func(GetResult()) end

        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(positionTable)
            widget.anchor:SetSelectedValue(positionTable[1])
            widget.relativePoint:SetSelectedValue(positionTable[3])
            widget.relativeTo:SetSelectedValue(positionTable[2])
            widget.x:SetValue(positionTable[4])
            widget.y:SetValue(positionTable[5])
        end
    else widget = settingWidgets["position_noHCenter"] end
    widget:Show(); return widget
end

local function CreateSetting_Anchor(parent)
    local widget
    if not settingWidgets["anchor"] then
        widget = SF_CreateFrame("SFIndicatorSettings_Anchor", parent, 300, ROW_HEIGHT)
        settingWidgets["anchor"] = widget
        widget.dd = LayoutDropdownRow(widget, "Anchor To", 160)
        widget.dd:SetItems({
            { text = "Health Bar (Current)", value = "healthbar-current", onClick = function() widget.func("healthbar-current") end },
            { text = "Health Bar (Loss)",    value = "healthbar-loss",    onClick = function() widget.func("healthbar-loss") end },
            { text = "Health Bar (Entire)",  value = "healthbar-entire",  onClick = function() widget.func("healthbar-entire") end },
            { text = "Unit Button",          value = "unitButton",        onClick = function() widget.func("unitButton") end },
        })
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(anchor) widget.dd:SetSelectedValue(anchor) end
    else widget = settingWidgets["anchor"] end
    widget:Show(); return widget
end

-- Frame Level, presented as NAMED TIERS rather than a raw 1-100 number
-- (2026-08-07). A bare number tells a user nothing about what it stacks
-- above or below; EllesmereUI exposes the same setting as a named tier list
-- for exactly this reason. Preset names/values come from F.LAYER_PRESETS
-- (Utils.lua), which is the same documented scheme the shipped defaults
-- use.
--
-- Values remain plain numbers in the DB -- nothing about storage changes,
-- so existing profiles (including hand-tuned levels that match no preset)
-- keep working. A non-preset value simply displays as "Custom (N)".
local function CreateSetting_FrameLevel(parent)
    local widget
    if not settingWidgets["frameLevel"] then
        widget = SF_CreateFrame("SFIndicatorSettings_FrameLevel", parent, 300, 58)
        settingWidgets["frameLevel"] = widget

        widget.dd = SF_CreateDropdown(widget, 230)
        widget.dd:SetPoint("TOPLEFT", 10, -20)
        widget.ddText = CreateLabel(widget, "Frame Level", "BOTTOMLEFT", 10, 1)
        widget.ddText:SetPoint("BOTTOMLEFT", widget.dd, "TOPLEFT", 0, 1)

        -- Rebuilt per SetDBValue rather than once up front, so a stored
        -- value that matches no preset can be represented as an extra
        -- "Custom (N)" row. The dropdown renders blank for a selected value
        -- that isn't in its item list, so the row has to actually exist.
        local function BuildItems(currentValue)
            local items = {}
            local matched = false
            for _, preset in ipairs(F.LAYER_PRESETS) do
                if preset.value == currentValue then matched = true end
                table.insert(items, {
                    text = preset.text,
                    value = preset.value,
                    onClick = function() widget.func(preset.value) end,
                })
            end
            if currentValue and not matched then
                -- Keep hand-tuned levels working and visible instead of
                -- silently snapping them to the nearest preset.
                table.insert(items, {
                    text = ("Custom (%d)"):format(currentValue),
                    value = currentValue,
                    onClick = function() widget.func(currentValue) end,
                })
            end
            widget.dd:SetItems(items)
        end

        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(frameLevel)
            frameLevel = tonumber(frameLevel) or F.LAYER.AURA
            BuildItems(frameLevel)
            widget.dd:SetSelectedValue(frameLevel)
        end
    else widget = settingWidgets["frameLevel"] end
    widget:Show(); return widget
end

local function CreateSetting_Size(parent)
    local widget
    if not settingWidgets["size"] then
        widget = SF_CreateFrame("SFIndicatorSettings_Size", parent, 300,75)
        settingWidgets["size"] = widget
        widget.width = SF_CreateSlider("Width", widget, 3, 500, 100, 1)
        widget.width:SetPoint("TOPLEFT", widget, 5, -20)
        widget.width.afterValueChangedFn = function(value) widget.func({value, widget.height:GetValue()}) end
        widget.height = SF_CreateSlider("Height", widget, 3, 500, 100, 1)
        widget.height:SetPoint("LEFT", widget.width, "RIGHT", 15, 0)
        widget.height.afterValueChangedFn = function(value) widget.func({widget.width:GetValue(), value}) end
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(sizeTable)
            -- Defensive unwrap for a saved-profile leftover: debuffs' size
            -- used to be nested {{normalW,normalH},{bigW,bigH}} for the now-
            -- removed big-debuff-size feature (see Layout_Defaults.lua's
            -- comment on debuffs' size) -- a profile saved before that
            -- migration still has the old shape, and unlike Indicators.lua's
            -- HandleIndicators (which already unwraps this), this widget
            -- fed the whole {normalW,normalH} sub-table straight into
            -- SetValue as if it were a plain number, hard-erroring the
            -- moment the panel opened. Same fix as CreateSetting_SizeSquare.
            if type(sizeTable[1]) == "table" then sizeTable = sizeTable[1] end
            widget.width:SetValue(sizeTable[1]); widget.height:SetValue(sizeTable[2])
        end
    else widget = settingWidgets["size"] end
    widget:Show(); return widget
end

local function CreateSetting_SizeSquare(parent)
    local widget
    if not settingWidgets["size-square"] then
        widget = SF_CreateFrame("SFIndicatorSettings_SizeSquare", parent, 300,75)
        settingWidgets["size-square"] = widget
        widget.size = SF_CreateSlider("Size", widget, 1, 200, 230, 1)
        widget.size:SetPoint("TOPLEFT", widget, 5, -20)
        widget.size.afterValueChangedFn = function(value) widget.func({value, value}) end
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(sizeTable)
            -- Defensive unwrap for a saved-profile leftover: debuffs' size
            -- used to be nested {{normalW,normalH},{bigW,bigH}} for the now-
            -- removed big-debuff-size feature (see Layout_Defaults.lua's
            -- comment on debuffs' size) -- a profile saved before that
            -- migration still has the old shape, and unlike Indicators.lua's
            -- HandleIndicators (which already unwraps this), this widget fed
            -- the whole {normalW,normalH} sub-table straight into SetValue
            -- as if it were a plain number ("bad argument #1 to 'SetValue'
            -- (outside of expected range...)", confirmed via a live error
            -- report), hard-erroring the moment the Debuffs settings panel
            -- opened.
            if type(sizeTable[1]) == "table" then sizeTable = sizeTable[1] end
            widget.size:SetValue(sizeTable[1])
        end
    else widget = settingWidgets["size-square"] end
    widget:Show(); return widget
end

local function CreateSetting_Spacing(parent)
    local widget
    if not settingWidgets["spacing"] then
        widget = SF_CreateFrame("SFIndicatorSettings_Spacing", parent, 300,75)
        settingWidgets["spacing"] = widget
        widget.x = SF_CreateSlider("Spacing X", widget, -1, 50, 100, 1)
        widget.x:SetPoint("TOPLEFT", widget, 5, -20)
        widget.x.afterValueChangedFn = function(value) widget.spacing[1] = value; widget.func(widget.spacing) end
        widget.y = SF_CreateSlider("Spacing Y", widget, -1, 50, 100, 1)
        widget.y:SetPoint("LEFT", widget.x, "RIGHT", 15, 0)
        widget.y.afterValueChangedFn = function(value) widget.spacing[2] = value; widget.func(widget.spacing) end
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(spacing) widget.spacing = spacing; widget.x:SetValue(spacing[1]); widget.y:SetValue(spacing[2]) end
    else widget = settingWidgets["spacing"] end
    widget:Show(); return widget
end

local function CreateSetting_Thickness(parent)
    local widget
    if not settingWidgets["thickness"] then
        widget = SF_CreateFrame("SFIndicatorSettings_Thickness", parent, 300,75)
        settingWidgets["thickness"] = widget
        widget.size = SF_CreateSlider("Size", widget, 1, 15, 230, 1)
        widget.size:SetPoint("TOPLEFT", widget, 5, -20)
        widget.size.afterValueChangedFn = function(value) widget.func(value) end
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(n) widget.size:SetValue(n) end
    else widget = settingWidgets["thickness"] end
    widget:Show(); return widget
end

local function CreateSetting_SizeNormalBig(parent)
    local widget
    if not settingWidgets["size-normal-big"] then
        widget = SF_CreateFrame("SFIndicatorSettings_SizeNormalBig", parent, 300,75)
        settingWidgets["size-normal-big"] = widget
        widget.sizeNormal = SF_CreateSlider("Size", widget, 1, 200, 100, 1)
        widget.sizeNormal:SetPoint("TOPLEFT", widget, 5, -20)
        widget.sizeNormal.afterValueChangedFn = function(value)
            widget.func({{value, value}, {widget.sizeBig:GetValue(), widget.sizeBig:GetValue()}})
        end
        widget.sizeBig = SF_CreateSlider("Size (Big)", widget, 1, 200, 100, 1)
        widget.sizeBig:SetPoint("LEFT", widget.sizeNormal, "RIGHT", 15, 0)
        widget.sizeBig.afterValueChangedFn = function(value)
            widget.func({{widget.sizeNormal:GetValue(), widget.sizeNormal:GetValue()}, {value, value}})
        end
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(sizeTable) widget.sizeNormal:SetValue(sizeTable[1][1]); widget.sizeBig:SetValue(sizeTable[2][1]) end
    else widget = settingWidgets["size-normal-big"] end
    widget:Show(); return widget
end

local function CreateSetting_SizeAndBorder(parent)
    local widget
    if not settingWidgets["size-border"] then
        widget = SF_CreateFrame("SFIndicatorSettings_SizeAndBorder", parent, 300,75)
        settingWidgets["size-border"] = widget
        widget.size = SF_CreateSlider("Size", widget, 1, 200, 100, 1)
        widget.size:SetPoint("TOPLEFT", widget, 5, -20)
        widget.size.afterValueChangedFn = function(value) widget.func({value, value, widget.border:GetValue()}) end
        widget.border = SF_CreateSlider("Border", widget, 1, 10, 100, 1)
        widget.border:SetPoint("LEFT", widget.size, "RIGHT", 15, 0)
        widget.border.afterValueChangedFn = function(value) widget.func({widget.size:GetValue(), widget.size:GetValue(), value}) end
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(sizeTable, border) widget.size:SetValue(sizeTable[1]); widget.border:SetValue(border or 1) end
    else widget = settingWidgets["size-border"] end
    widget:Show(); return widget
end

local function CreateSetting_Height(parent)
    local widget
    if not settingWidgets["height"] then
        widget = SF_CreateFrame("SFIndicatorSettings_Height", parent, 300,75)
        settingWidgets["height"] = widget
        widget.height = SF_CreateSlider("Height", widget, 1, 300, 230, 1)
        widget.height:SetPoint("TOPLEFT", widget, 5, -20)
        widget.height.afterValueChangedFn = function(value) widget.func(value) end
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(height) widget.height:SetValue(height) end
    else widget = settingWidgets["height"] end
    widget:Show(); return widget
end

-----------------------------------------------------------------------
-- TextWidth — 3-mode widget (Unlimited / Percentage / Length)
-----------------------------------------------------------------------
local function CreateSetting_TextWidth(parent)
    local widget
    if not settingWidgets["textWidth"] then
        widget = SF_CreateFrame("SFIndicatorSettings_TextWidth", parent, 300,58)
        settingWidgets["textWidth"] = widget

        widget.textWidth = SF_CreateDropdown(widget, 100)
        widget.textWidth:SetPoint("TOPLEFT", 5, -20)
        widget.textWidth:SetItems({
            { text = "Unlimited", value = "unlimited", onClick = function()
                widget.textWidth:SetSelectedItem(1)
                widget.func("unlimited")
                widget.percent:Hide(); widget.length:Hide(); widget.length2:Hide()
                widget.lengthValue = nil; widget.lengthValue2 = nil
            end },
            { text = "Percentage", value = "percentage", onClick = function()
                widget.textWidth:SetSelectedItem(2)
                widget.func({"percentage", 0.75})
                widget.percent:SetSelectedValue(0.75); widget.percent:Show()
                widget.length:Hide(); widget.length2:Hide()
                widget.lengthValue = nil; widget.lengthValue2 = nil
            end },
            { text = "Length", value = "length", onClick = function()
                widget.textWidth:SetSelectedItem(3)
                widget.func({"length", 5, 3})
                widget.percent:Hide()
                widget.length:SetText("5"); widget.length:Show(); widget.lengthValue = 5
                widget.length2:SetText("3"); widget.length2:Show(); widget.lengthValue2 = 3
            end },
        })

        widget.percent = SF_CreateDropdown(widget, 65)
        widget.percent:SetPoint("TOPLEFT", widget.textWidth, "TOPRIGHT", 10, 0)
        widget.percent:SetItems({
            { text = "100%", value = 1,    onClick = function() widget.func({"percentage", 1}) end },
            { text = "75%",  value = 0.75, onClick = function() widget.func({"percentage", 0.75}) end },
            { text = "50%",  value = 0.5,  onClick = function() widget.func({"percentage", 0.5}) end },
            { text = "25%",  value = 0.25, onClick = function() widget.func({"percentage", 0.25}) end },
        })

        widget.length = SF_CreateEditBox(widget, 32, 20, true, false, true)
        widget.length:SetPoint("TOPLEFT", widget.textWidth, "TOPRIGHT", 10, 0)
        widget.enText = CreateLabel(widget.length, "En", "BOTTOMLEFT", 0, 1)
        widget.enText:SetPoint("BOTTOMLEFT", widget.length, "TOPLEFT", 0, 1)

        widget.length.confirmBtn = SF_CreateButton(widget.length, "OK", "accent", {27, 20})
        widget.length.confirmBtn:SetPoint("TOPLEFT", widget.length, "TOPRIGHT", -1, 0)
        widget.length.confirmBtn:Hide()
        widget.length.confirmBtn:SetScript("OnClick", function()
            local l = tonumber(widget.length:GetText())
            widget.length:SetText(tostring(l)); widget.length:ClearFocus()
            widget.length.confirmBtn:Hide(); widget.lengthValue = l
            widget.func({"length", l, tonumber(widget.length2:GetText()) or widget.lengthValue2})
        end)
        widget.length:SetScript("OnTextChanged", function(self, userChanged)
            if userChanged then
                local l = tonumber(self:GetText())
                if l and l ~= widget.lengthValue and l ~= 0 then widget.length.confirmBtn:Show()
                else widget.length.confirmBtn:Hide() end
            end
        end)

        widget.length2 = SF_CreateEditBox(widget, 32, 20, true, false, true)
        widget.length2:SetPoint("TOPLEFT", widget.length, "TOPRIGHT", 50, 0)
        widget.nonEnText = CreateLabel(widget.length2, "Non-En", "BOTTOMLEFT", 0, 1)
        widget.nonEnText:SetPoint("BOTTOMLEFT", widget.length2, "TOPLEFT", 0, 1)

        widget.length2.confirmBtn = SF_CreateButton(widget.length2, "OK", "accent", {27, 20})
        widget.length2.confirmBtn:SetPoint("TOPLEFT", widget.length2, "TOPRIGHT", -1, 0)
        widget.length2.confirmBtn:Hide()
        widget.length2.confirmBtn:SetScript("OnClick", function()
            local l = tonumber(widget.length2:GetText())
            widget.length2:SetText(tostring(l)); widget.length2:ClearFocus()
            widget.length2.confirmBtn:Hide(); widget.lengthValue2 = l
            widget.func({"length", tonumber(widget.length:GetText()) or widget.lengthValue, l})
        end)
        widget.length2:SetScript("OnTextChanged", function(self, userChanged)
            if userChanged then
                local l = tonumber(self:GetText())
                if l and l ~= widget.lengthValue2 and l ~= 0 then widget.length2.confirmBtn:Show()
                else widget.length2.confirmBtn:Hide() end
            end
        end)

        widget.widthText = CreateLabel(widget, "Text Width", "BOTTOMLEFT", 5, 1)
        widget.widthText:SetPoint("BOTTOMLEFT", widget.textWidth, "TOPLEFT", 0, 1)

        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(width)
            if width == "unlimited" then
                widget.textWidth:SetSelectedItem(1); widget.percent:Hide(); widget.length:Hide(); widget.length2:Hide()
            elseif width[1] == "percentage" then
                widget.textWidth:SetSelectedItem(2); widget.percent:SetSelectedValue(width[2]); widget.percent:Show()
                widget.length:Hide(); widget.length2:Hide()
            elseif width[1] == "length" then
                widget.textWidth:SetSelectedItem(3); widget.length:SetText(tostring(width[2])); widget.lengthValue = width[2]; widget.length:Show()
                widget.length2:SetText(tostring(width[3])); widget.lengthValue2 = width[3]; widget.length2:Show(); widget.percent:Hide()
            end
        end
    else widget = settingWidgets["textWidth"] end
    widget:Show(); return widget
end

-----------------------------------------------------------------------
-- Simple single-value settings (Alpha, Num, NumPerLine)
-----------------------------------------------------------------------
local function CreateSetting_Alpha(parent)
    local widget
    if not settingWidgets["alpha"] then
        widget = SF_CreateFrame("SFIndicatorSettings_Alpha", parent, 300,75)
        settingWidgets["alpha"] = widget
        widget.alpha = SF_CreateSlider("Alpha", widget, 0, 1, 230, 0.01)
        widget.alpha:SetPoint("TOPLEFT", widget, 5, -20)
        widget.alpha.afterValueChangedFn = function(value) widget.func(value) end
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(alpha) widget.alpha:SetValue(alpha) end
    else widget = settingWidgets["alpha"] end
    widget:Show(); return widget
end

local function CreateSetting_Num(parent)
    local widget
    if not settingWidgets["num"] then
        widget = SF_CreateFrame("SFIndicatorSettings_Num", parent, 300,75)
        settingWidgets["num"] = widget
        widget.num = SF_CreateSlider("Max Displayed", widget, 1, 20, 230, 1)
        widget.num:SetPoint("TOPLEFT", 5, -20)
        widget.num.afterValueChangedFn = function(value) widget.func(value) end
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(num, maxN) widget.num:UpdateMinMaxValues(1, maxN or 20); widget.num:SetValue(num) end
    else widget = settingWidgets["num"] end
    widget:Show(); return widget
end

local function CreateSetting_NumPerLine(parent)
    local widget
    if not settingWidgets["numPerLine"] then
        widget = SF_CreateFrame("SFIndicatorSettings_NumPerLine", parent, 300,75)
        settingWidgets["numPerLine"] = widget
        widget.num = SF_CreateSlider("Per Line", widget, 1, 20, 230, 1)
        widget.num:SetPoint("TOPLEFT", 5, -20)
        widget.num.afterValueChangedFn = function(value) widget.func(value) end
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(num, maxN) widget.num:UpdateMinMaxValues(2, maxN or 20); widget.num:SetValue(num) end
    else widget = settingWidgets["numPerLine"] end
    widget:Show(); return widget
end

-----------------------------------------------------------------------
-- VehicleNamePosition
-----------------------------------------------------------------------
local function CreateSetting_VehicleNamePosition(parent)
    local widget
    if not settingWidgets["vehicleNamePosition"] then
        -- Row 1: "Vehicle Name Position" label + dropdown (left) | "Y Offset" slider (right), side by side
        widget = SF_CreateFrame("SFIndicatorSettings_VehicleNamePosition", parent, 300, 75)
        settingWidgets["vehicleNamePosition"] = widget
        local vehiclePositions = {"TOP", "BOTTOM", "HIDDEN"}
        widget.position = SF_CreateDropdown(widget, 100)
        widget.position:SetPoint("TOPLEFT", 5, -20)
        local items = {}
        for _, pos in ipairs(vehiclePositions) do
            table.insert(items, { text = pos, value = pos, onClick = function() widget.func({pos, widget.y:GetValue()}) end })
        end
        widget.position:SetItems(items)
        widget.positionText = CreateLabel(widget, "Vehicle Name Position", "BOTTOMLEFT", 5, 1)
        widget.positionText:SetPoint("BOTTOMLEFT", widget.position, "TOPLEFT", 0, 1)
        widget.y = SF_CreateSlider("Y Offset", widget, -50, 50, 110, 1)
        widget.y:SetPoint("TOPLEFT", widget.position, "TOPRIGHT", 15, 0)
        widget.y.afterValueChangedFn = function(value) widget.func({widget.position:GetSelected(), value}) end
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(positionTable) widget.position:SetSelectedValue(positionTable[1]); widget.y:SetValue(positionTable[2] or 0) end
    else widget = settingWidgets["vehicleNamePosition"] end
    widget:Show(); return widget
end

-----------------------------------------------------------------------
-- StatusPosition
-----------------------------------------------------------------------
local function CreateSetting_StatusPosition(parent)
    local widget
    if not settingWidgets["statusPosition"] then
        widget = SF_CreateFrame("SFIndicatorSettings_StatusPosition", parent, 300,58)
        settingWidgets["statusPosition"] = widget
        local statusPositions = {"LEFT", "RIGHT", "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT"}
        widget.position = SF_CreateDropdown(widget, 110)
        widget.position:SetPoint("TOPLEFT", 5, -20)
        local items = {}
        for _, pos in ipairs(statusPositions) do
            table.insert(items, { text = pos, value = pos, onClick = function() widget.func(pos) end })
        end
        widget.position:SetItems(items)
        widget.positionText = CreateLabel(widget, "Position", "BOTTOMLEFT", 5, 1)
        widget.positionText:SetPoint("BOTTOMLEFT", widget.position, "TOPLEFT", 0, 1)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(pos) widget.position:SetSelectedValue(pos) end
    else widget = settingWidgets["statusPosition"] end
    widget:Show(); return widget
end

-----------------------------------------------------------------------
-- Font settings (FontNoOffset = 4-field, Font = 8-field)
-----------------------------------------------------------------------
local function CreateSetting_FontNoOffset(parent)
    local widget
    if not settingWidgets["font-noOffset"] then
        widget = SF_CreateFrame("SFIndicatorSettings_FontNoOffset", parent, 300,115)
        settingWidgets["font-noOffset"] = widget

        local _fontTable = nil
        local _fontName = nil

        local function GetFont()
            if not _fontTable then return end
            if type(_fontTable[1]) == "string" then return _fontTable end
            local idx = _fontName == "durationFont" and 2 or 1
            return _fontTable[idx]
        end

        -- Shared with every other font picker in the addon (Utils.lua) --
        -- LibSharedMedia's full registry, so other addons' fonts appear too.
        local fonts = F.GetFontDropdownItems()
        local outlines = {
            { text = "None",       value = "NONE" },
            { text = "Outline",   value = "OUTLINE" },
            { text = "Thick",     value = "THICKOUTLINE" },
            { text = "Monochrome", value = "MONOCHROME" },
        }

        widget.font = SF_CreateDropdown(widget, 100)
        widget.font:SetPoint("TOPLEFT", 5, -20)
        widget.font:SetItems(fonts)
        widget.fontText = CreateLabel(widget, "Font", "BOTTOMLEFT", 5, 1)
        widget.fontText:SetPoint("BOTTOMLEFT", widget.font, "TOPLEFT", 0, 1)

        widget.outline = SF_CreateDropdown(widget, 100)
        widget.outline:SetPoint("TOPLEFT", widget.font, "TOPRIGHT", 5, 0)
        widget.outline:SetItems(outlines)
        widget.outlineText = CreateLabel(widget, "Outline", "BOTTOMLEFT", 5, 1)
        widget.outlineText:SetPoint("BOTTOMLEFT", widget.outline, "TOPLEFT", 0, 1)

        -- Floor of 1, not 5. Aura icons are commonly 16-20px, where even a
        -- size-5 stack or duration string is large relative to the icon, and
        -- the old floor made it impossible to go smaller (user report
        -- 2026-08-13). 1 rather than 0 because SetFont errors on a size of 0 --
        -- inside initializeFrame that would abort the engine's whole button
        -- batch, not just skip the text (see ApplyFontSlot in AuraEngine.lua).
        widget.size = SF_CreateSlider("Size", widget, 1, 50, 100, 1)
        widget.size:SetPoint("TOPLEFT", widget.font, "BOTTOMLEFT", 0, -10)

        local _shadow = false
        widget.shadow = SF_CreateCheckButton(widget, "Shadow")
        widget.shadow:SetPoint("TOPLEFT", widget.size, "TOPRIGHT", 10, 4)

        local function OnChanged()
            local f = GetFont()
            if not f then return end
            f[1] = widget.font:GetSelected()
            f[2] = widget.size:GetValue()
            f[3] = widget.outline:GetSelected() or "NONE"
            f[4] = _shadow
            if widget.func then widget.func() end
        end

        for _, item in ipairs(fonts) do item.onClick = function() OnChanged() end end
        widget.font:SetItems(fonts)
        for _, item in ipairs(outlines) do item.onClick = function() OnChanged() end end
        widget.outline:SetItems(outlines)
        widget.size.afterValueChangedFn = function() OnChanged() end
        widget.shadow.onClick = function(val) _shadow = val; OnChanged() end

        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(fontTable, settingName)
            _fontTable = fontTable; _fontName = settingName
            local f = GetFont()
            if f then
                widget.font:SetSelectedValue(f[1]); widget.size:SetValue(f[2])
                widget.outline:SetSelectedValue(f[3] or "NONE")
                _shadow = not not f[4]; widget.shadow:SetChecked(_shadow)
            end
        end
    else widget = settingWidgets["font-noOffset"] end
    widget:Show(); return widget
end

local function CreateSetting_Font(parent, index)
    local key = "font_"..(index or "1")
    local widget
    if not settingWidgets[key] then
        -- 8-row stack (font, outline, size, shadow, anchor, X offset, Y
        -- offset, color) actually lays out to ~224px deep (font+outline row
        -- @ -20/24px, size slider @ -10/50px, anchor+X-offset row @
        -- -10/50px, Y offset slider @ -10/50px) -- SF_CreateFrame always
        -- sets SetClipsChildren(true), so the old 173px height (copied from
        -- the estimate table without ever measuring the real stack) was
        -- silently cutting off the Y Offset slider and part of the color
        -- picker. 259 = that 245 plus a 14px title row up top (see
        -- widget.title below) so two font blocks stacked back-to-back are
        -- distinguishable ("Stack Font" vs "Duration Font").
        widget = SF_CreateFrame("SFIndicatorSettings_Font", parent, 300, 259)
        settingWidgets[key] = widget

        -- Section title ("Stack Font" / "Duration Font" / "Font") so two
        -- font blocks stacked back-to-back in the same indicator's settings
        -- are distinguishable at a glance -- set from SetDBValue's
        -- settingName below.
        local a = F.GetAccentColor()
        widget.title = widget:CreateFontString(nil, "OVERLAY")
        widget.title:SetFont(FONT_TEMPLATE, 12, "OUTLINE")
        widget.title:SetPoint("TOPLEFT", 5, -4)
        widget.title:SetTextColor(a.r, a.g, a.b, 1)

        local _fontTable = nil
        local _index = 1
        local _settingName = nil

        local function GetFont()
            if not _fontTable then return end
            -- IndicatorsPanel's GetFontSlot() already resolves down to a single
            -- flat font tuple (e.g. {"Friz QT__", 11, "OUTLINE", ...}) before
            -- calling SetDBValue for font1/font2 tokens. Only the bare "font"
            -- token still passes the full {slot1, slot2} wrapper. Detect which
            -- shape we were given: a string in position 1 means _fontTable IS
            -- the tuple already; a table means it's the wrapper to index into.
            if type(_fontTable[1]) == "string" then return _fontTable end
            return _fontTable[_index]
        end

        -- Shared with every other font picker in the addon (Utils.lua) --
        -- LibSharedMedia's full registry, so other addons' fonts appear too.
        local fonts = F.GetFontDropdownItems()
        local outlines = {
            { text = "None",       value = "NONE" },
            { text = "Outline",   value = "OUTLINE" },
            { text = "Thick",     value = "THICKOUTLINE" },
            { text = "Monochrome", value = "MONOCHROME" },
        }
        local anchors = {}
        for _, p in ipairs(anchorPoints) do table.insert(anchors, { text = p, value = p }) end

        widget.font = SF_CreateDropdown(widget, 100)
        widget.font:SetPoint("TOPLEFT", 5, -34)
        widget.font:SetItems(fonts)
        widget.fontText = CreateLabel(widget, "Font", "BOTTOMLEFT", 5, 1)
        widget.fontText:SetPoint("BOTTOMLEFT", widget.font, "TOPLEFT", 0, 1)

        widget.outline = SF_CreateDropdown(widget, 100)
        widget.outline:SetPoint("TOPLEFT", widget.font, "TOPRIGHT", 5, 0)
        widget.outline:SetItems(outlines)
        widget.outlineText = CreateLabel(widget, "Outline", "BOTTOMLEFT", 5, 1)
        widget.outlineText:SetPoint("BOTTOMLEFT", widget.outline, "TOPLEFT", 0, 1)

        -- Floor of 1, not 5. Aura icons are commonly 16-20px, where even a
        -- size-5 stack or duration string is large relative to the icon, and
        -- the old floor made it impossible to go smaller (user report
        -- 2026-08-13). 1 rather than 0 because SetFont errors on a size of 0 --
        -- inside initializeFrame that would abort the engine's whole button
        -- batch, not just skip the text (see ApplyFontSlot in AuraEngine.lua).
        widget.size = SF_CreateSlider("Size", widget, 1, 50, 100, 1)
        widget.size:SetPoint("TOPLEFT", widget.font, "BOTTOMLEFT", 0, -10)

        local _shadow = false
        widget.shadow = SF_CreateCheckButton(widget, "Shadow")
        widget.shadow:SetPoint("TOPLEFT", widget.size, "TOPRIGHT", 10, 4)

        widget.anchor = SF_CreateDropdown(widget, 100)
        widget.anchor:SetPoint("TOPLEFT", widget.size, "BOTTOMLEFT", 0, -10)
        widget.anchor:SetItems(anchors)
        widget.anchorText = CreateLabel(widget, "Anchor", "BOTTOMLEFT", 5, 1)
        widget.anchorText:SetPoint("BOTTOMLEFT", widget.anchor, "TOPLEFT", 0, 1)

        widget.xOffset = SF_CreateSlider("X Offset", widget, -50, 50, 100, 1)
        widget.xOffset:SetPoint("TOPLEFT", widget.anchor, "TOPRIGHT", 5, 0)

        widget.yOffset = SF_CreateSlider("Y Offset", widget, -50, 50, 100, 1)
        widget.yOffset:SetPoint("TOPLEFT", widget.xOffset, "BOTTOMLEFT", 0, -10)

        local _color = {1, 1, 1}
        widget.color = W.CreateColorPicker(widget, "Color",
            function() return _color[1], _color[2], _color[3] end,
            function(r, g, b) _color = {r, g, b}; if widget.func then widget.func() end end)
        widget.color:SetPoint("TOPLEFT", widget.anchor, "BOTTOMLEFT", 0, -10)

        local function OnChanged()
            local f = GetFont()
            if not f then return end
            f[1] = widget.font:GetSelected(); f[2] = widget.size:GetValue()
            f[3] = widget.outline:GetSelected() or "NONE"; f[4] = _shadow
            f[5] = widget.anchor:GetSelected(); f[6] = widget.xOffset:GetValue()
            f[7] = widget.yOffset:GetValue(); f[8] = _color
            if widget.func then widget.func() end
        end

        for _, item in ipairs(fonts) do item.onClick = function() OnChanged() end end
        widget.font:SetItems(fonts)
        for _, item in ipairs(outlines) do item.onClick = function() OnChanged() end end
        widget.outline:SetItems(outlines)
        for _, item in ipairs(anchors) do item.onClick = function() OnChanged() end end
        widget.anchor:SetItems(anchors)
        widget.size.afterValueChangedFn = function() OnChanged() end
        widget.xOffset.afterValueChangedFn = function() OnChanged() end
        widget.yOffset.afterValueChangedFn = function() OnChanged() end
        widget.shadow.onClick = function(val) _shadow = val; OnChanged() end

        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(fontSlot, settingName)
            _fontTable = fontSlot
            _settingName = settingName
            widget.title:SetText(settingName or "Font")
            if type(fontSlot) == "table" and #fontSlot >= 7 then
                widget.font:SetSelectedValue(fontSlot[1]); widget.size:SetValue(fontSlot[2])
                widget.outline:SetSelectedValue(fontSlot[3] or "NONE")
                _shadow = not not fontSlot[4]; widget.shadow:SetChecked(_shadow)
                widget.anchor:SetSelectedValue(fontSlot[5]); widget.xOffset:SetValue(fontSlot[6])
                widget.yOffset:SetValue(fontSlot[7]); _color = fontSlot[8] or {1, 1, 1}
            end
        end
    else widget = settingWidgets[key] end
    widget:Show(); return widget
end

-----------------------------------------------------------------------
-- Color settings (ColorAlpha, ClassColor, Colors, StatusColors, etc.)
-----------------------------------------------------------------------
local function CreateSetting_ColorAlpha(parent)
    local widget
    if not settingWidgets["color-alpha"] then
        widget = SF_CreateFrame("SFIndicatorSettings_ColorAlpha", parent, 300,38)
        settingWidgets["color-alpha"] = widget
        local _r, _g, _b, _a = 1, 1, 1, 1
        widget.color = W.CreateColorPicker(widget, "Color",
            function() return _r, _g, _b, _a end,
            function(r, g, b, a)
                _r, _g, _b, _a = r, g, b, a
                -- CreateColorPicker's alpha slider fires this via SetValue
                -- during its OWN construction (before SetFunc below ever
                -- runs), so widget.func can still be nil the first time.
                if widget.func then widget.func({"custom_color", r, g, b, a}) end
            end)
        widget.color:SetPoint("TOPLEFT", 5, -8)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(colorTable)
            if colorTable and colorTable[1] == "custom_color" and #colorTable >= 5 then
                _r, _g, _b, _a = colorTable[2], colorTable[3], colorTable[4], colorTable[5]
            elseif colorTable and #colorTable >= 4 then
                _r, _g, _b, _a = colorTable[1], colorTable[2], colorTable[3], colorTable[4]
            end
            -- This widget is cached and shared across every indicator that
            -- uses the "color-alpha" token (Shield Overlay, Heal Absorb) --
            -- switching which indicator's panel is open only updated the
            -- _r/_g/_b/_a upvalues above, never the swatch texture/slider
            -- position actually on screen. Those stayed stuck at whatever
            -- was last visually rendered until the user touched the slider
            -- (whose OnValueChanged handler happens to call UpdateSwatch).
            widget.color.UpdateSwatch()
        end
    else widget = settingWidgets["color-alpha"] end
    widget:Show(); return widget
end

-- Second colour picker, for the overshield / over-absorb glow -- a separate
-- token rather than a second use of "color-alpha" purely because these widgets
-- are cached one-per-token and shared across indicators, so two colours on the
-- same panel need two cache keys.
--
-- Labelled generically: the glow it tints is named by the checkbox directly
-- above it on both panels ("Overshield Glow" / "Over-Absorb Glow").
local function CreateSetting_GlowColor(parent)
    local widget
    if not settingWidgets["glowColor"] then
        widget = SF_CreateFrame("SFIndicatorSettings_GlowColor", parent, 300, 38)
        settingWidgets["glowColor"] = widget
        local _r, _g, _b, _a = 1, 1, 1, 1
        widget.color = W.CreateColorPicker(widget, "Glow Color",
            function() return _r, _g, _b, _a end,
            function(r, g, b, a)
                _r, _g, _b, _a = r, g, b, a
                -- See CreateSetting_ColorAlpha: the alpha slider fires this
                -- during its own construction, before SetFunc has run.
                if widget.func then widget.func({"custom_color", r, g, b, a}) end
            end)
        widget.color:SetPoint("TOPLEFT", 5, -8)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(colorTable)
            if colorTable and colorTable[1] == "custom_color" and #colorTable >= 5 then
                _r, _g, _b, _a = colorTable[2], colorTable[3], colorTable[4], colorTable[5]
            elseif colorTable and #colorTable >= 4 then
                _r, _g, _b, _a = colorTable[1], colorTable[2], colorTable[3], colorTable[4]
            else
                -- Unset: the glow textures are authored to be shown untinted.
                _r, _g, _b, _a = 1, 1, 1, 1
            end
            -- Same cached/shared-widget staleness as color-alpha's SetDBValue.
            widget.color.UpdateSwatch()
        end
    else widget = settingWidgets["glowColor"] end
    widget:Show(); return widget
end

local function CreateSetting_ClassColor(parent)
    local widget
    if not settingWidgets["color-class"] then
        widget = SF_CreateFrame("SFIndicatorSettings_ClassColor", parent, 300,38)
        settingWidgets["color-class"] = widget
        widget.cb = SF_CreateCheckButton(widget, "Class Color")
        widget.cb:SetPoint("TOPLEFT", 5, -8)
        function widget:SetFunc(func) widget.cb.onClick = function(val) func(val) end end
        function widget:SetDBValue(colorTable) widget.cb:SetChecked(colorTable and colorTable[1] == "class_color") end
    else widget = settingWidgets["color-class"] end
    widget:Show(); return widget
end

local function CreateSetting_Color(parent)
    local widget
    if not settingWidgets["color"] then
        widget = SF_CreateFrame("SFIndicatorSettings_Color", parent, 300,38)
        settingWidgets["color"] = widget
        local _r, _g, _b, _a = 0, 1, 0, 1
        widget.color = W.CreateColorPicker(widget, "Color",
            function() return _r, _g, _b, _a end,
            function(r, g, b, a)
                _r, _g, _b, _a = r, g, b, a
                -- Same construction-order guard as CreateSetting_ColorAlpha.
                if widget.func then widget.func({"custom_color", r, g, b, a}) end
            end)
        widget.color:SetPoint("TOPLEFT", 5, -8)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(colorTable)
            if colorTable and colorTable[1] == "custom_color" and #colorTable >= 5 then
                _r, _g, _b, _a = colorTable[2], colorTable[3], colorTable[4], colorTable[5]
            end
            -- Same cached/shared-widget staleness as color-alpha's SetDBValue --
            -- must force the swatch/opacity slider to repaint from the new
            -- upvalues, not just wait for the user to touch them.
            widget.color.UpdateSwatch()
        end
    else widget = settingWidgets["color"] end
    widget:Show(); return widget
end

local function CreateSetting_Colors(parent)
    local widget
    if not settingWidgets["colors"] then
        widget = SF_CreateFrame("SFIndicatorSettings_Colors", parent, 300,58)
        settingWidgets["colors"] = widget
        local _r, _g, _b, _a = 0, 1, 0, 1
        widget.color = W.CreateColorPicker(widget, "Color",
            function() return _r, _g, _b, _a end,
            function(r, g, b, a)
                _r, _g, _b, _a = r, g, b, a
                -- Pass the picked color through so the binding block can
                -- actually store it -- previously called with no arguments,
                -- silently writing nil into t.colors/customColors/etc.
                if widget.func then widget.func(r, g, b, a) end
            end)
        widget.color:SetPoint("TOPLEFT", 5, -8)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(colorsTable)
            if colorsTable and colorsTable[1] then
                local c = colorsTable[1]
                if type(c) == "table" and #c >= 3 then _r, _g, _b, _a = c[1], c[2], c[3], c[4] or 1 end
            end
            -- Same cached/shared-widget staleness as color-alpha's SetDBValue --
            -- must force the swatch/opacity slider to repaint from the new
            -- upvalues, not just wait for the user to touch them.
            widget.color.UpdateSwatch()
        end
    else widget = settingWidgets["colors"] end
    widget:Show(); return widget
end

-- Expiring colour for the custom "colour" indicator: an enable toggle, a
-- threshold, and the colour to switch to. One widget rather than three tokens
-- because the three are meaningless apart.
--
-- The thresholds match the Show Duration vocabulary exactly -- same mechanism
-- underneath (an engine-side breakpoint against the secret duration), so
-- offering different numbers here would just invite the question why.
local function CreateSetting_ExpiringColor(parent)
    local widget
    if not settingWidgets["expiringColor"] then
        widget = SF_CreateFrame("SFIndicatorSettings_ExpiringColor", parent, 300, 96)
        settingWidgets["expiringColor"] = widget
        widget.title = CreateLabel(widget, "Expiring Color", "TOPLEFT", 5, -5)
        widget.title:SetTextColor(0.3, 0.7, 1, 1)
        widget.title:SetFont(FONT_TEMPLATE, 12, "OUTLINE")

        local _enabled, _threshold = false, 5
        local _r, _g, _b, _a = 1, 0, 0, 1
        local function Fire()
            if widget.func then
                widget.func(_enabled, _threshold, {"custom_color", _r, _g, _b, _a})
            end
        end

        widget.cb = SF_CreateCheckButton(widget, "Enabled")
        widget.cb:SetPoint("TOPLEFT", widget.title, "BOTTOMLEFT", 0, -10)
        widget.cb.onClick = function(val) _enabled = val; Fire() end

        widget.dd = SF_CreateDropdown(widget, 110)
        widget.dd:SetPoint("TOPLEFT", widget.cb, "BOTTOMLEFT", 0, -12)
        widget.dd:SetItems({
            { text = "< 3s Remaining",  value = 3,  onClick = function() _threshold = 3;  Fire() end },
            { text = "< 5s Remaining",  value = 5,  onClick = function() _threshold = 5;  Fire() end },
            { text = "< 10s Remaining", value = 10, onClick = function() _threshold = 10; Fire() end },
        })

        widget.color = W.CreateColorPicker(widget, "Color",
            function() return _r, _g, _b, _a end,
            function(r, g, b, a) _r, _g, _b, _a = r, g, b, a; Fire() end)
        widget.color:ClearAllPoints()
        widget.color:SetPoint("LEFT", widget, "LEFT", 150, 0)
        widget.color:SetPoint("TOP", widget.dd, "TOP", 0, 0)

        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(enabled, threshold, colorTable)
            _enabled = not not enabled
            _threshold = tonumber(threshold) or 5
            -- type() rather than a truthiness test: a stored boolean would
            -- otherwise be indexed here too. See wrapper:SetExpiringColor.
            if type(colorTable) == "table" and colorTable[1] == "custom_color" and #colorTable >= 5 then
                _r, _g, _b, _a = colorTable[2], colorTable[3], colorTable[4], colorTable[5]
            end
            widget.cb:SetChecked(_enabled)
            widget.dd:SetSelectedValue(_threshold)
            widget.color.UpdateSwatch()
        end
    else widget = settingWidgets["expiringColor"] end
    widget:Show(); return widget
end

local CreateSetting_BlockColors = CreateSetting_Colors
local CreateSetting_OverlayColors = CreateSetting_Colors
local CreateSetting_CustomColors = CreateSetting_Colors

local function CreateSetting_StatusColors(parent)
    local widget
    if not settingWidgets["statusColors"] then
        widget = SF_CreateFrame("SFIndicatorSettings_StatusColors", parent, 300,38)
        settingWidgets["statusColors"] = widget
        widget.text = CreateLabel(widget, "Status Colors (configure in Appearance)", "TOPLEFT", 5, -8)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(colorsTable) end
    else widget = settingWidgets["statusColors"] end
    widget:Show(); return widget
end

-----------------------------------------------------------------------
-- CheckButton (5 variants for different checkbuttonN: prefixes)
-----------------------------------------------------------------------
local function MakeCheckButton(key, defaultLabel)
    return function(parent)
        local widget
        if not settingWidgets[key] then
            widget = SF_CreateFrame("SFIndicatorSettings_"..key, parent, 300,38)
            settingWidgets[key] = widget
            widget.cb = SF_CreateCheckButton(widget, defaultLabel or "Option")
            widget.cb:SetPoint("TOPLEFT", 5, -8)
            function widget:SetFunc(func) widget.cb.onClick = func end
            function widget:SetDBValue(setting, value, tooltip)
                widget.cb:SetChecked(not not value)
                -- Update checkbox label from the setting key (e.g., "showGroupNumber"
                -- → "Show Group Number") when the binding block provides it.
                if setting and type(setting) == "string" then
                    local labels = {
                        showGroupNumber = "Show Group Number",
                        -- On (default) this indicator hides itself for units
                        -- the game won't let us filter by spell -- see
                        -- IdentityGateState. Ticking it shows the unfiltered
                        -- pool instead.
                        showUnfiltered = "Show Unfiltered Auras",
                        hideRealmName = "Hide Realm Name",
                        showTimer = "Show Timer",
                        showBackground = "Show Background",
                        showAnimation = "Show Animation",
                        showStack = "Show Stack",
                        showCountdownNumbers = "Show Duration Text",
                        showCooldownSwipe = "Show Cooldown Swipe",
                        showTooltip = "Show Tooltip",
                        enableBlacklistShortcut = "Blacklist Shortcut",
                        dispellableByMe = "Dispellable By Me",
                        hideCCDebuffs = "Hide Crowd Control",
                        onlyShowTopGlow = "Only Top Glow",
                        fadeOut = "Fade Out",
                        smooth = "Smooth",
                        hideDamager = "Hide for Damagers",
                        hideInCombat = "Hide In Combat",
                        shieldByMe = "Shield By Me",
                        onlyShowOvershields = "Only Overshields",
                        showDispelIcons = "Show Dispel Icons",
                        reverseFill = "Reverse Fill",
                        showOvershieldGlow = "Overshield Glow",
                        showOverAbsorbGlow = "Over-Absorb Glow",
                        showIconBorder = "Show Icon Border",
                        showSwipe = "Show Cooldown Swipe",
                        useSpellIcons = "Use Spell Icons",
                    }
                    local labelText = labels[setting] or setting
                    if widget.cb.labelText then
                        widget.cb.labelText:SetText(labelText)
                    elseif widget.cb.SetText then
                        widget.cb:SetText(labelText)
                    end
                end
                if tooltip and widget.cb.tooltip then widget.cb.tooltip = tooltip end
            end
        else widget = settingWidgets[key] end
        widget:Show(); return widget
    end
end

local CreateSetting_CheckButton  = MakeCheckButton("checkbutton", "Option")
local CreateSetting_CheckButton2 = MakeCheckButton("checkbutton2", "Option")
local CreateSetting_CheckButton3 = MakeCheckButton("checkbutton3", "Option")
local CreateSetting_CheckButton4 = MakeCheckButton("checkbutton4", "Option")
local CreateSetting_CheckButton5 = MakeCheckButton("checkbutton5", "Option")
local CreateSetting_CheckButton6 = MakeCheckButton("checkbutton6", "Option")

-----------------------------------------------------------------------
-- Orientation / BarOrientation
-----------------------------------------------------------------------
local function CreateSetting_Orientation(parent)
    local widget
    if not settingWidgets["orientation"] then
        widget = SF_CreateFrame("SFIndicatorSettings_Orientation", parent, 300, ROW_HEIGHT)
        settingWidgets["orientation"] = widget
        local orientations = {"left-to-right", "right-to-left", "top-to-bottom", "bottom-to-top", "horizontal", "vertical"}
        widget.dd = LayoutDropdownRow(widget, "Orientation", 140)
        local items = {}
        for _, o in ipairs(orientations) do
            table.insert(items, { text = o, value = o, onClick = function() widget.func(o) end })
        end
        widget.dd:SetItems(items)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(val) widget.dd:SetSelectedValue(val or "left-to-right") end
    else widget = settingWidgets["orientation"] end
    widget:Show(); return widget
end

local CreateSetting_BarOrientation = CreateSetting_Orientation

-- Axis + direction as two coupled dropdowns, rather than one flat list of
-- four directions (the shared Orientation widget above).
--
-- They're one WIDGET, not two, specifically so the coupling can be handled
-- internally: picking Vertical rebuilds the Growth list to Up to Down / Down
-- to Up on the spot. Split across two widgets it would need the whole settings
-- pane to rebuild to refresh the second one, which nothing else here does.
--
-- Growth is stored as an explicit direction ("left-to-right", "down-to-up",
-- ...) not a "normal/reversed" flag, so the saved value says what it means on
-- its own and a mismatched pair (vertical + left-to-right) is detectable
-- rather than silently meaning something different.
local ORIENT_GROWTH = {
    horizontal = {
        { text = "Left to Right", value = "left-to-right" },
        { text = "Right to Left", value = "right-to-left" },
    },
    vertical = {
        { text = "Up to Down",    value = "up-to-down" },
        { text = "Down to Up",    value = "down-to-up" },
    },
}

local function CreateSetting_GrowthOrientation(parent)
    local widget
    if not settingWidgets["growthOrientation"] then
        widget = SF_CreateFrame("SFIndicatorSettings_GrowthOrientation", parent, 300, ROW_HEIGHT * 2)
        settingWidgets["growthOrientation"] = widget

        widget.orientDD = SF_CreateDropdown(widget, 140)
        widget.orientDD:SetPoint("TOPRIGHT", -6, -6)
        widget.orientLabel = CreateLabel(widget, "Orientation", "TOPLEFT", 8, -14)

        widget.growthDD = SF_CreateDropdown(widget, 140)
        widget.growthDD:SetPoint("TOPRIGHT", widget.orientDD, "BOTTOMRIGHT", 0, -6)
        widget.growthLabel = CreateLabel(widget, "Growth", "TOPLEFT", 8, -48)

        local function GrowthItems(orientation)
            local list = ORIENT_GROWTH[orientation] or ORIENT_GROWTH.horizontal
            local items = {}
            for _, o in ipairs(list) do
                items[#items + 1] = { text = o.text, value = o.value, onClick = function()
                    widget._growth = o.value
                    if widget.func then widget.func(widget._orientation, widget._growth) end
                end }
            end
            return items
        end

        -- Re-point growth at the new axis. A saved value from the other axis
        -- can't be kept (it names a direction that axis doesn't have), so fall
        -- back to that axis's first entry.
        local function ApplyOrientation(orientation, keepGrowth)
            widget._orientation = orientation
            widget.growthDD:SetItems(GrowthItems(orientation))
            local valid = false
            for _, o in ipairs(ORIENT_GROWTH[orientation] or {}) do
                if o.value == keepGrowth then valid = true break end
            end
            if not valid then
                widget._growth = (ORIENT_GROWTH[orientation] or ORIENT_GROWTH.horizontal)[1].value
            end
            widget.growthDD:SetSelectedValue(widget._growth)
        end

        widget.orientDD:SetItems({
            { text = "Horizontal", value = "horizontal", onClick = function()
                ApplyOrientation("horizontal", widget._growth)
                if widget.func then widget.func(widget._orientation, widget._growth) end
            end },
            { text = "Vertical", value = "vertical", onClick = function()
                ApplyOrientation("vertical", widget._growth)
                if widget.func then widget.func(widget._orientation, widget._growth) end
            end },
        })

        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(orientation, growth)
            orientation = (orientation == "vertical") and "vertical" or "horizontal"
            widget._growth = growth
            widget.orientDD:SetSelectedValue(orientation)
            ApplyOrientation(orientation, growth)
        end
    else widget = settingWidgets["growthOrientation"] end
    widget:Show(); return widget
end

-- Same widget as above, plus a "center" option -- a SEPARATE cached
-- singleton/token (not just appending "center" to CreateSetting_Orientation
-- itself) so indicators that don't actually implement it (their own
-- SetOrientation has no "center" case, e.g. Debuffs/External Cooldowns/
-- custom icon grids) never show a selectable option that silently does
-- nothing. Only Private Auras uses this token (see IndicatorDefaults.lua's
-- the since-removed Private Auras indicator) -- per explicit user request for a
-- "center growth" option there specifically.
local function CreateSetting_OrientationCenterable(parent)
    local widget
    if not settingWidgets["orientationCenterable"] then
        widget = SF_CreateFrame("SFIndicatorSettings_OrientationCenterable", parent, 300, ROW_HEIGHT)
        settingWidgets["orientationCenterable"] = widget
        local orientations = {"left-to-right", "right-to-left", "top-to-bottom", "bottom-to-top", "center"}
        widget.dd = LayoutDropdownRow(widget, "Orientation", 140)
        local items = {}
        for _, o in ipairs(orientations) do
            table.insert(items, { text = o, value = o, onClick = function() widget.func(o) end })
        end
        widget.dd:SetItems(items)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(val) widget.dd:SetSelectedValue(val or "left-to-right") end
    else widget = settingWidgets["orientationCenterable"] end
    widget:Show(); return widget
end

-----------------------------------------------------------------------
-- Duration / Stack / DurationVisibility
-----------------------------------------------------------------------
local function CreateSetting_DurationVisibility(parent)
    local widget
    if not settingWidgets["durationVisibility"] then
        widget = SF_CreateFrame("SFIndicatorSettings_DurationVisibility", parent, 300, ROW_HEIGHT)
        settingWidgets["durationVisibility"] = widget
        -- Labels read "< Ns" because that is what these actually do: show the
        -- countdown only once it drops BELOW the threshold. They previously
        -- read "> Ns Remaining", which described the opposite behaviour --
        -- and neither behaviour was implemented at all, so the text simply
        -- stayed on permanently (fixed 2026-08-13; see ApplyDurationMode in
        -- AuraEngineIndicators.lua).
        local modes = {"Always", "On Hover", "< 5s Remaining", "< 3s Remaining", "Never"}
        local values = {"always", "onHover", 5, 3, "never"}
        widget.dd = LayoutDropdownRow(widget, "Show Duration", 140)
        local items = {}
        for i, m in ipairs(modes) do
            table.insert(items, { text = m, value = values[i], onClick = function() widget.func(values[i]) end })
        end
        widget.dd:SetItems(items)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(val) widget.dd:SetSelectedValue(val or "always") end
    else widget = settingWidgets["durationVisibility"] end
    widget:Show(); return widget
end

-- Same as the full dropdown minus "On Hover" -- used by Healer HoTs.
--
-- This was Always/Never only, on the belief that a threshold "has no real
-- number to evaluate against" because the duration is secret. That turned out
-- to be wrong: the threshold is evaluated ENGINE-side as a formatter
-- breakpoint, never in Lua (see ThresholdDurationBreakpoints in
-- AuraEngine.lua), so the two threshold options work here exactly as they do
-- everywhere else and are offered now.
--
-- "On Hover" genuinely can't work and stays out: it needs a script handler on
-- the aura button to detect the hover, and those are forbidden on
-- engine-managed buttons (CLAUDE.md section 7).
local function CreateSetting_DurationVisibilitySimple(parent)
    local widget
    if not settingWidgets["durationVisibilitySimple"] then
        widget = SF_CreateFrame("SFIndicatorSettings_DurationVisibilitySimple", parent, 300, ROW_HEIGHT)
        settingWidgets["durationVisibilitySimple"] = widget
        widget.dd = LayoutDropdownRow(widget, "Show Duration", 140)
        widget.dd:SetItems({
            { text = "Always",           value = "always", onClick = function() widget.func("always") end },
            { text = "< 5s Remaining",   value = 5,        onClick = function() widget.func(5) end },
            { text = "< 3s Remaining",   value = 3,        onClick = function() widget.func(3) end },
            { text = "Never",            value = "never",  onClick = function() widget.func("never") end },
        })
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(val) widget.dd:SetSelectedValue(val or "always") end
    else widget = settingWidgets["durationVisibilitySimple"] end
    widget:Show(); return widget
end

-- X/Y offset for a sub-element (currently just the Healer HoTs duration
-- text) that's positioned relative to its OWN icon, not the unit button --
-- deliberately simpler than the full Position widget (no anchor-point/
-- relative-to pickers), since the anchor corner is fixed.
local function CreateSetting_DurationOffset(parent)
    local widget
    if not settingWidgets["durationOffset"] then
        widget = SF_CreateFrame("SFIndicatorSettings_DurationOffset", parent, 300, 75)
        settingWidgets["durationOffset"] = widget
        local function GetResult() return { widget.x:GetValue(), widget.y:GetValue() } end
        widget.x = SF_CreateSlider("Duration X Offset", widget, -50, 50, 100, 1)
        widget.x:SetPoint("TOPLEFT", widget, 5, -20)
        widget.x.afterValueChangedFn = function() widget.func(GetResult()) end
        widget.y = SF_CreateSlider("Duration Y Offset", widget, -50, 50, 100, 1)
        widget.y:SetPoint("LEFT", widget.x, "RIGHT", 15, 0)
        widget.y.afterValueChangedFn = function() widget.func(GetResult()) end
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(offset)
            offset = offset or { 0, -2 }
            widget.x:SetValue(offset[1] or 0)
            widget.y:SetValue(offset[2] or -2)
        end
    else widget = settingWidgets["durationOffset"] end
    widget:Show(); return widget
end

local function CreateSetting_Duration(parent)
    local widget
    if not settingWidgets["duration"] then
        widget = SF_CreateFrame("SFIndicatorSettings_Duration", parent, 300,38)
        settingWidgets["duration"] = widget
        widget.cb = SF_CreateCheckButton(widget, "Show Duration")
        widget.cb:SetPoint("TOPLEFT", 5, -8)
        function widget:SetFunc(func) widget.cb.onClick = func end
        function widget:SetDBValue(val) widget.cb:SetChecked(not not val) end
    else widget = settingWidgets["duration"] end
    widget:Show(); return widget
end

local function CreateSetting_Stack(parent)
    local widget
    if not settingWidgets["stack"] then
        widget = SF_CreateFrame("SFIndicatorSettings_Stack", parent, 300,38)
        settingWidgets["stack"] = widget
        widget.cb = SF_CreateCheckButton(widget, "Show Stack")
        widget.cb:SetPoint("TOPLEFT", 5, -8)
        function widget:SetFunc(func) widget.cb.onClick = func end
        function widget:SetDBValue(val) widget.cb:SetChecked(not not val) end
    else widget = settingWidgets["stack"] end
    widget:Show(); return widget
end

-----------------------------------------------------------------------
-- RoleTexture, GlowOptions, HighlightType, Texture, etc.
-----------------------------------------------------------------------
-- Role texture packs (atlas-based or separate files) - from Utils.lua
local ROLE_TEXTURE_PACKS = SquizzFrames.ROLE_TEXTURE_PACKS or _G.ROLE_TEXTURE_PACKS or {}

local function CreateSetting_RoleTexture(parent)
    local widget
    if not settingWidgets["roleTexture"] then
        widget = SF_CreateFrame("SFIndicatorSettings_RoleTexture", parent, 300, ROW_HEIGHT)
        settingWidgets["roleTexture"] = widget
        local opts = {}
        -- Build sorted list: default first, then alphabetical
        local keys = {}
        for k in pairs(ROLE_TEXTURE_PACKS) do table.insert(keys, k) end
        table.sort(keys, function(a, b)
            if a == "default" then return true end
            if b == "default" then return false end
            return a < b
        end)
        for _, k in ipairs(keys) do
            table.insert(opts, { text = ROLE_TEXTURE_PACKS[k].label, value = k, pack = ROLE_TEXTURE_PACKS[k] })
        end
        widget.dd = LayoutDropdownRow(widget, "Role Texture", 175)
        local items = {}
        for _, o in ipairs(opts) do
            local pack = o.pack
            -- Use preview image showing all roles in a line, if available
            local iconPath, iconCoords
            if pack.preview then
                iconPath = pack.preview
                iconCoords = { 0, 1, 0, 1 }
            elseif pack.atlas then
                iconPath = pack.atlas
                iconCoords = pack.coords.TANK
            elseif pack.files then
                iconPath = pack.files.TANK
                iconCoords = {0, 1, 0, 1}
            end
            table.insert(items, {
                text = o.text,
                value = o.value,
                icon = iconPath,
                iconCoords = iconCoords,
                onClick = function() widget.func(o.value) end
            })
        end
        widget.dd:SetItems(items)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(val) widget.dd:SetSelectedValue(val or "default") end
    else widget = settingWidgets["roleTexture"] end
    widget:Show(); return widget
end

local function CreateSetting_Glow(parent)
    local widget
    if not settingWidgets["glowOptions"] then
        widget = SF_CreateFrame("SFIndicatorSettings_Glow", parent, 300, ROW_HEIGHT)
        settingWidgets["glowOptions"] = widget
        local glows = {
            { text = "None",              value = "None" },
            { text = "Pixel",            value = "Pixel" },
            { text = "Button Glow",      value = "Normal" },
            { text = "Auto Cast Shine",  value = "Shine" },
        }
        widget.dd = LayoutDropdownRow(widget, "Glow", 140)
        local items = {}
        for _, g in ipairs(glows) do
            table.insert(items, { text = g.text, value = g.value, onClick = function()
                widget.glowOptions[1] = g.value; widget.func(widget.glowOptions)
            end })
        end
        widget.dd:SetItems(items)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(glowOptions)
            widget.glowOptions = glowOptions or {"None", {0.95, 0.95, 0.32, 1}}
            widget.dd:SetSelectedValue(widget.glowOptions[1])
        end
    else widget = settingWidgets["glowOptions"] end
    widget:Show(); return widget
end

local function CreateSetting_HighlightType(parent)
    local widget
    if not settingWidgets["highlightType"] then
        widget = SF_CreateFrame("SFIndicatorSettings_HighlightType", parent, 300, ROW_HEIGHT)
        settingWidgets["highlightType"] = widget
        local highlights = {"none", "gradient-half", "gradient-full", "border", "glow"}
        widget.dd = LayoutDropdownRow(widget, "Highlight", 140)
        local items = {}
        for _, h in ipairs(highlights) do
            table.insert(items, { text = h, value = h, onClick = function() widget.func(h) end })
        end
        widget.dd:SetItems(items)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(val) widget.dd:SetSelectedValue(val or "none") end
    else widget = settingWidgets["highlightType"] end
    widget:Show(); return widget
end

-- Shield Overlay / Heal Absorb fill texture -- every statusbar texture
-- registered with LSM by any addon (matches OptionsFrame.lua's general Bar
-- Texture picker: GetBarTextureItems), sorted alphabetically. Includes
-- SquizzFrames' own bundled "Shield" pattern (Media/Media.lua) alongside
-- "Solid"/"Blizzard"/etc and anything other addons register.
local LSM = LibStub and LibStub:GetLibrary("LibSharedMedia-3.0", true)
local function GetBarTextureDropdownItems()
    local items = {}
    if LSM then
        for name in pairs(LSM:HashTable("statusbar")) do
            items[#items + 1] = { text = name, value = name }
        end
        table.sort(items, function(a, b) return a.text < b.text end)
    end
    if #items == 0 then
        items[1] = { text = "Blizzard", value = "Blizzard" }
    end
    return items
end

local function CreateSetting_BarTexture(parent)
    local widget
    if not settingWidgets["barTexture"] then
        widget = SF_CreateFrame("SFIndicatorSettings_BarTexture", parent, 300, ROW_HEIGHT)
        settingWidgets["barTexture"] = widget
        widget.dd = LayoutDropdownRow(widget, "Texture", 140)
        local items = {}
        for _, entry in ipairs(GetBarTextureDropdownItems()) do
            table.insert(items, { text = entry.text, value = entry.value,
                onClick = function() widget.func(entry.value) end })
        end
        widget.dd:SetItems(items)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(val) widget.dd:SetSelectedValue(val or "Blizzard") end
    else widget = settingWidgets["barTexture"] end
    widget:Show(); return widget
end

local function CreateSetting_Texture(parent)
    local widget
    if not settingWidgets["texture"] then
        widget = SF_CreateFrame("SFIndicatorSettings_Texture", parent, 300, ROW_HEIGHT)
        settingWidgets["texture"] = widget
        local textures = {"circle", "square", "blizzard"}
        widget.dd = LayoutDropdownRow(widget, "Texture", 140)
        local items = {}
        for _, t in ipairs(textures) do
            table.insert(items, { text = t, value = t, onClick = function()
                widget.texTable[1] = t; widget.func(widget.texTable)
            end })
        end
        widget.dd:SetItems(items)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(texTable) widget.texTable = texTable or {"circle", 0, {1,1,1,1}}; widget.dd:SetSelectedValue(widget.texTable[1]) end
    else widget = settingWidgets["texture"] end
    widget:Show(); return widget
end

-----------------------------------------------------------------------
-- Auras spell list (simplified — uses SquizzFrames' CreateAuraSpellList)
-----------------------------------------------------------------------
local function CreateSetting_Auras(parent, index, showHealerButton, singleSpellMode)
    -- showHealerButton/singleSpellMode each get their OWN cache key (not
    -- just a different widget property) so they don't collide with the
    -- shared "auras_N" instance other callers (generic custom-indicator
    -- auras, dispel blacklist, etc) still use.
    local key = "auras_"..(index or 1)..(showHealerButton == false and "_noHealer" or "")..(singleSpellMode and "_single" or "")
    local widget
    if not settingWidgets[key] then
        widget = SF_CreateFrame("SFIndicatorSettings_Auras", parent, 300,108)
        settingWidgets[key] = widget
        widget.title = CreateLabel(widget, "Spell List", "TOPLEFT", 5, -5)
        widget.title:SetTextColor(0.3, 0.7, 1, 1)
        widget.title:SetFont(FONT_TEMPLATE, 12, "OUTLINE")
        widget.spellList = W.CreateAuraSpellList(widget, "debuff",
            function() return widget._auras or {} end,
            function(newAuras) widget._auras = newAuras; if widget.func then widget.func(newAuras) end end,
            showHealerButton, singleSpellMode)
        widget.spellList:SetPoint("TOPLEFT", widget.title, "BOTTOMLEFT", 0, -4)
        widget.spellList:SetPoint("BOTTOMRIGHT", 0, 4)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(title, auras)
            if title and type(title) == "string" then widget.title:SetText(title) end
            widget._auras = auras or {}
            if widget.spellList.SetAuras then widget.spellList.SetAuras(widget._auras) end
        end
    else widget = settingWidgets[key] end
    widget:Show(); return widget
end

-----------------------------------------------------------------------
-- Debuff Blacklist: a curated checklist (SquizzFrames.defaults.
-- curatedDebuffBlacklist) with individual allow/disallow checkboxes, plus a
-- clean "Add Spell ID" popup for anything not on the curated list. Deliberately
-- its own widget rather than CreateSetting_Auras/CreateAuraSpellList: a
-- blacklist is "toggle common debuffs on/off", not "freely build a spell
-- list", and it has no use for the Add Healer Spells bulk-import button that
-- widget carries for custom-indicator aura pickers.
-----------------------------------------------------------------------
local function CreateSetting_DebuffBlacklist(parent)
    local widget
    if not settingWidgets["debuffBlacklist"] then
        widget = SF_CreateFrame("SFIndicatorSettings_DebuffBlacklist", parent, 300, 240)
        settingWidgets["debuffBlacklist"] = widget
        widget.title = CreateLabel(widget, "Debuff Blacklist", "TOPLEFT", 5, -5)
        widget.title:SetTextColor(0.3, 0.7, 1, 1)
        widget.title:SetFont(FONT_TEMPLATE, 12, "OUTLINE")

        local scrollFrame = W.CreateScrollFrame(widget)
        scrollFrame:SetPoint("TOPLEFT", widget.title, "BOTTOMLEFT", -5, -4)
        scrollFrame:SetPoint("BOTTOMRIGHT", 0, 32)

        local addButton = W.CreateStyledButton(widget, "Add Spell ID", "accent-hover", {110, 24}, function()
            widget._openAddPopup()
        end)
        addButton:SetPoint("BOTTOMLEFT", 5, 4)

        -- Clean add-by-ID popup: a small bordered dialog with a label,
        -- numeric editbox, and explicit Add/Cancel buttons -- replaces the
        -- old CreateAuraSpellList pattern of a bare EditBox floating over
        -- the Add button with no visible frame or cancel affordance.
        local popup = CreateFrame("Frame", nil, widget, "BackdropTemplate")
        popup:SetSize(170, 74)
        popup:SetPoint("BOTTOM", 0, 4)
        popup:SetFrameStrata("DIALOG")
        W.StylizeFrame(popup, {0.08, 0.08, 0.08, 0.98}, {0.4, 0.4, 0.4, 0.9})
        popup:Hide()
        popup.label = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        popup.label:SetPoint("TOP", 0, -8)
        popup.label:SetText("Enter Spell ID:")
        popup.editbox = CreateFrame("EditBox", nil, popup, "InputBoxTemplate")
        popup.editbox:SetSize(110, 20)
        popup.editbox:SetPoint("TOP", popup.label, "BOTTOM", 0, -6)
        popup.editbox:SetAutoFocus(true)
        popup.editbox:SetNumeric(true)
        local confirmBtn, cancelBtn
        confirmBtn = W.CreateStyledButton(popup, "Add", "accent-hover", {50, 20}, function()
            local id = tonumber(popup.editbox:GetText())
            popup.editbox:SetText("")
            popup:Hide()
            if id and id > 0 then widget._addId(id) end
        end)
        confirmBtn:SetPoint("BOTTOMLEFT", 8, 8)
        cancelBtn = W.CreateStyledButton(popup, "Cancel", "red-hover", {50, 20}, function()
            popup.editbox:SetText("")
            popup:Hide()
        end)
        cancelBtn:SetPoint("BOTTOMRIGHT", -8, 8)
        popup.editbox:SetScript("OnEnterPressed", function() confirmBtn:Click() end)
        popup.editbox:SetScript("OnEscapePressed", function() cancelBtn:Click() end)

        function widget._openAddPopup()
            popup.editbox:SetText("")
            popup:Show()
            popup.editbox:SetFocus()
        end

        local rows = {}

        local function Rebuild()
            for _, row in ipairs(rows) do row:Hide(); row:SetParent(nil) end
            wipe(rows)

            local blacklist = widget._auras or {}
            local blacklistSet = {}
            for _, id in ipairs(blacklist) do blacklistSet[id] = true end

            local curated = SquizzFrames.defaults and SquizzFrames.defaults.curatedDebuffBlacklist or {}
            local curatedSet = {}
            for _, id in ipairs(curated) do curatedSet[id] = true end

            local scrollChild = scrollFrame.scrollChild
            local idx = 0

            local function AddRow(id, isCurated)
                idx = idx + 1
                local row = CreateFrame("Frame", nil, scrollChild, "BackdropTemplate")
                row:SetHeight(20)
                W.StylizeFrame(row, {0.08, 0.08, 0.08, 0.8}, {0.3, 0.3, 0.3, 0.5})
                if idx == 1 then
                    row:SetPoint("TOPLEFT", 0, 0)
                else
                    row:SetPoint("TOPLEFT", rows[idx - 1], "BOTTOMLEFT", 0, -1)
                end
                row:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)

                local cb = SF_CreateCheckButton(row, "")
                cb:SetPoint("LEFT", 4, 0)
                cb:SetChecked(blacklistSet[id])
                cb.onClick = function(checked)
                    local current = widget._auras or {}
                    local newList = {}
                    for _, existing in ipairs(current) do
                        if existing ~= id then newList[#newList + 1] = existing end
                    end
                    if checked then newList[#newList + 1] = id end
                    widget._auras = newList
                    if widget.func then widget.func(newList) end
                end

                local iconTex = row:CreateTexture(nil, "ARTWORK")
                iconTex:SetSize(16, 16)
                iconTex:SetPoint("LEFT", cb, "RIGHT", 4, 0)
                local iconId = F.GetSpellIcon(id)
                if iconId then iconTex:SetTexture(iconId) end
                iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                local nameStr = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                nameStr:SetPoint("LEFT", iconTex, "RIGHT", 4, 0)
                nameStr:SetPoint("RIGHT", isCurated and -4 or -24, 0)
                nameStr:SetJustifyH("LEFT")
                local spellName = F.GetSpellInfo(id)
                nameStr:SetText(spellName and (spellName .. " (" .. id .. ")") or tostring(id))

                if not isCurated then
                    local deleteBtn = CreateFrame("Button", nil, row)
                    deleteBtn:SetSize(16, 16)
                    deleteBtn:SetPoint("RIGHT", -4, 0)
                    deleteBtn:SetNormalFontObject("GameFontNormalSmall")
                    deleteBtn:SetText("X")
                    deleteBtn:SetScript("OnClick", function()
                        local current = widget._auras or {}
                        local newList = {}
                        for _, existing in ipairs(current) do
                            if existing ~= id then newList[#newList + 1] = existing end
                        end
                        widget._auras = newList
                        if widget.func then widget.func(newList) end
                        Rebuild()
                    end)
                end

                rows[idx] = row
            end

            for _, id in ipairs(curated) do AddRow(id, true) end
            for _, id in ipairs(blacklist) do
                if not curatedSet[id] then AddRow(id, false) end
            end

            scrollFrame:SetContentHeight(idx)
        end

        function widget._addId(id)
            local current = widget._auras or {}
            for _, existing in ipairs(current) do
                if existing == id then return end
            end
            local newList = {}
            for _, existing in ipairs(current) do newList[#newList + 1] = existing end
            newList[#newList + 1] = id
            widget._auras = newList
            if widget.func then widget.func(newList) end
            Rebuild()
        end

        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(auras)
            widget._auras = auras or {}
            Rebuild()
        end
    else widget = settingWidgets["debuffBlacklist"] end
    widget:Show(); return widget
end

-----------------------------------------------------------------------
-- Big Debuff Priority: whether CC-detected debuffs (Blizzard's own
-- CROWD_CONTROL aura filter -- see BuiltIn_Update.lua's CC_DEBUFF_FILTER)
-- get sorted first and rendered at the "big" size. A single checkbox, not a
-- spell list -- Blizzard's own filter stays current every patch/tier without
-- a hand-maintained ID table to go stale.
-----------------------------------------------------------------------
local function CreateSetting_BigDebuffCC(parent)
    local widget
    if not settingWidgets["bigDebuffCC"] then
        widget = SF_CreateFrame("SFIndicatorSettings_BigDebuffCC", parent, 300, 50)
        settingWidgets["bigDebuffCC"] = widget
        widget.cb = SF_CreateCheckButton(widget, "Prioritize Crowd Control Debuffs")
        widget.cb:SetPoint("TOPLEFT", 5, -14)
        widget.hint = CreateLabel(widget, "Uses Blizzard's own CC detection -- always current, no list to maintain.", "TOPLEFT", 5, -1)
        widget.hint:SetPoint("TOPLEFT", widget.cb, "BOTTOMLEFT", 0, -4)
        widget.hint:SetFont(FONT_TEMPLATE, 9)
        widget.hint:SetTextColor(0.55, 0.55, 0.55, 1)
        function widget:SetFunc(func) widget.cb.onClick = func end
        function widget:SetDBValue(val) widget.cb:SetChecked(not not val) end
    else widget = settingWidgets["bigDebuffCC"] end
    widget:Show(); return widget
end

-----------------------------------------------------------------------
-- BuiltIn spell toggles (externals, defensives, AoE healings, CC) --
-- a global "Use Default Spells" checkbox, plus a checklist of every curated
-- spell so users can see exactly what's tracked and hide individual entries.
-- Hiding only adds the spell ID to a per-indicator "hidden" list that
-- F.GetEffectiveSpellList filters out before scanning -- the curated table
-- itself (Defaults/Indicator_Defaults.lua) is never modified/deleted from.
-----------------------------------------------------------------------
local BUILTIN_CURATED_TABLE = {
    builtInExternals = "externalCooldowns",
    builtInDefensives = "defensiveCooldowns",
    builtInAoEHealings = "aoeHealings",
    builtInCrowdControls = "crowdControls",
    builtInMissingBuffs = "raidBuffs",
    builtInHots = "healerSpells",
}

local function CreateSetting_BuiltInsForKind(parent, token, filterToPlayerClass, customTitle)
    local curatedName = BUILTIN_CURATED_TABLE[token]
    local cacheKey = "builtIns_" .. token
    local widget
    if not settingWidgets[cacheKey] then
        widget = SF_CreateFrame("SFIndicatorSettings_" .. cacheKey, parent, 300, 280)
        settingWidgets[cacheKey] = widget
        widget.title = CreateLabel(widget, customTitle or "Built-in Spells", "TOPLEFT", 5, -5)
        widget.title:SetTextColor(0.3, 0.7, 1, 1)
        widget.title:SetFont(FONT_TEMPLATE, 12, "OUTLINE")

        widget.cb = SF_CreateCheckButton(widget, "Use Default Spells")
        widget.cb:SetPoint("TOPLEFT", 5, -22)

        local scrollFrame = W.CreateScrollFrame(widget)
        scrollFrame:SetPoint("TOPLEFT", widget.cb, "BOTTOMLEFT", -5, -8)
        scrollFrame:SetPoint("BOTTOMRIGHT", 0, 0)

        local rows = {}

        local function Rebuild()
            for _, row in ipairs(rows) do row:Hide(); row:SetParent(nil) end
            wipe(rows)

            local curated = SquizzFrames.defaults and SquizzFrames.defaults[curatedName]
            local idx = 0
            if not curated then
                scrollFrame:SetContentHeight(0)
                return
            end

            local hidden = widget._hidden or {}
            local hiddenSet = {}
            for _, id in ipairs(hidden) do hiddenSet[id] = true end

            local scrollChild = scrollFrame.scrollChild

            -- Stable group order -- pairs() iteration order isn't
            -- guaranteed, and an unstable list order between rebuilds would
            -- make rows visibly jump around as the user toggles checkboxes.
            local groupNames = {}
            if filterToPlayerClass then
                -- Only the viewer's own class group -- e.g. Healer HoTs only
                -- ever tracks spells the player themselves can cast
                -- (castBy="me"), so showing all 6 healer classes' HoTs in
                -- one long list was pure noise; a Priest can never cast a
                -- Druid HoT.
                local playerClass = F.GetClassFile and F.GetClassFile("player")
                if playerClass and curated[playerClass] then
                    groupNames = { playerClass }
                end
            else
                for groupName in pairs(curated) do groupNames[#groupNames + 1] = groupName end
                table.sort(groupNames)
            end

            for _, groupName in ipairs(groupNames) do
                local spells = curated[groupName]
                local ids = {}
                for id in pairs(spells) do
                    -- Only numeric top-level keys -- matches
                    -- BuiltIn_Update.lua's FlattenSpellTable's actual runtime
                    -- coverage (nested sub-spell tables, e.g. Mass Barrier's
                    -- Ice/Blazing/Prismatic Barrier, aren't currently scanned
                    -- either, so listing them here would be misleading).
                    if type(id) == "number" then ids[#ids + 1] = id end
                end
                table.sort(ids)
                if #ids > 0 then
                    idx = idx + 1
                    local header = CreateFrame("Frame", nil, scrollChild)
                    header:SetHeight(18)
                    if idx == 1 then
                        header:SetPoint("TOPLEFT", 0, 0)
                    else
                        header:SetPoint("TOPLEFT", rows[idx - 1], "BOTTOMLEFT", 0, -3)
                    end
                    header:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)
                    local headerText = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    headerText:SetPoint("LEFT", 2, 0)
                    headerText:SetText(groupName)
                    headerText:SetTextColor(0.6, 0.6, 0.6, 1)
                    rows[idx] = header

                    for _, id in ipairs(ids) do
                        idx = idx + 1
                        local row = CreateFrame("Frame", nil, scrollChild, "BackdropTemplate")
                        row:SetHeight(20)
                        W.StylizeFrame(row, {0.08, 0.08, 0.08, 0.8}, {0.3, 0.3, 0.3, 0.5})
                        row:SetPoint("TOPLEFT", rows[idx - 1], "BOTTOMLEFT", 0, -1)
                        row:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)

                        -- Checked = shown (the default). Unchecking hides it
                        -- from scanning; there is deliberately no delete
                        -- affordance -- the curated entry always stays here
                        -- to be re-shown later.
                        local cb = SF_CreateCheckButton(row, "")
                        cb:SetPoint("LEFT", 4, 0)
                        cb:SetChecked(not hiddenSet[id])
                        cb.onClick = function(checked)
                            local currentHidden = widget._hidden or {}
                            local newHidden = {}
                            for _, existing in ipairs(currentHidden) do
                                if existing ~= id then newHidden[#newHidden + 1] = existing end
                            end
                            if not checked then newHidden[#newHidden + 1] = id end
                            widget._hidden = newHidden
                            if widget.hiddenFunc then widget.hiddenFunc(newHidden) end
                        end

                        local iconTex = row:CreateTexture(nil, "ARTWORK")
                        iconTex:SetSize(16, 16)
                        iconTex:SetPoint("LEFT", cb, "RIGHT", 4, 0)
                        local iconId = F.GetSpellIcon(id)
                        if iconId then iconTex:SetTexture(iconId) end
                        iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                        local nameStr = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                        nameStr:SetPoint("LEFT", iconTex, "RIGHT", 4, 0)
                        nameStr:SetPoint("RIGHT", -4, 0)
                        nameStr:SetJustifyH("LEFT")
                        local spellName = F.GetSpellInfo(id)
                        nameStr:SetText(spellName and (spellName .. " (" .. id .. ")") or tostring(id))

                        rows[idx] = row
                    end
                end
            end

            scrollFrame:SetContentHeight(idx)
        end

        function widget:SetFunc(func) widget.cb.onClick = func end
        function widget:SetHiddenFunc(func) widget.hiddenFunc = func end
        function widget:SetDBValue(useBuiltIn, hidden)
            widget.cb:SetChecked(not not useBuiltIn)
            widget._hidden = hidden or {}
            Rebuild()
        end
    else widget = settingWidgets[cacheKey] end
    widget:Show(); return widget
end

local function CreateSetting_BuiltInExternals(parent) return CreateSetting_BuiltInsForKind(parent, "builtInExternals") end
local function CreateSetting_BuiltInDefensives(parent) return CreateSetting_BuiltInsForKind(parent, "builtInDefensives") end
local function CreateSetting_BuiltInAoEHealings(parent) return CreateSetting_BuiltInsForKind(parent, "builtInAoEHealings") end
local function CreateSetting_BuiltInCrowdControls(parent) return CreateSetting_BuiltInsForKind(parent, "builtInCrowdControls") end
local function CreateSetting_BuiltInMissingBuffs(parent) return CreateSetting_BuiltInsForKind(parent, "builtInMissingBuffs") end
local function CreateSetting_BuiltInHots(parent) return CreateSetting_BuiltInsForKind(parent, "builtInHots", true, "Your Class's HoTs") end

-----------------------------------------------------------------------
-- PowerColor, CastBy, MaxValue, IconStyle, Shape
-----------------------------------------------------------------------
local function CreateSetting_PowerColor(parent)
    local widget
    if not settingWidgets["color-power"] then
        widget = SF_CreateFrame("SFIndicatorSettings_PowerColor", parent, 300,38)
        settingWidgets["color-power"] = widget
        widget.cb = SF_CreateCheckButton(widget, "Power Color")
        widget.cb:SetPoint("TOPLEFT", 5, -8)
        function widget:SetFunc(func) widget.cb.onClick = func end
        function widget:SetDBValue(colorTable) widget.cb:SetChecked(colorTable and colorTable[1] == "power_color") end
    else widget = settingWidgets["color-power"] end
    widget:Show(); return widget
end

local function CreateSetting_CastBy(parent)
    local widget
    if not settingWidgets["castBy"] then
        widget = SF_CreateFrame("SFIndicatorSettings_CastBy", parent, 300, ROW_HEIGHT)
        settingWidgets["castBy"] = widget
        local opts = {"anyone", "me", "others"}
        widget.dd = LayoutDropdownRow(widget, "Cast By", 120)
        local items = {}
        for _, o in ipairs(opts) do
            table.insert(items, { text = o, value = o, onClick = function() widget.func(o) end })
        end
        widget.dd:SetItems(items)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(val) widget.dd:SetSelectedValue(val or "anyone") end
    else widget = settingWidgets["castBy"] end
    widget:Show(); return widget
end

local function CreateSetting_MaxValue(parent)
    local widget
    if not settingWidgets["maxValue"] then
        widget = SF_CreateFrame("SFIndicatorSettings_MaxValue", parent, 300,38)
        settingWidgets["maxValue"] = widget
        widget.cb = SF_CreateCheckButton(widget, "Use Max Value")
        widget.cb:SetPoint("TOPLEFT", 5, -8)
        function widget:SetFunc(func) widget.cb.onClick = func end
        function widget:SetDBValue(val) widget.cb:SetChecked(type(val) ~= "table" and val or val and val[1]) end
    else widget = settingWidgets["maxValue"] end
    widget:Show(); return widget
end

local function CreateSetting_IconStyle(parent)
    local widget
    if not settingWidgets["iconStyle"] then
        widget = SF_CreateFrame("SFIndicatorSettings_IconStyle", parent, 300, ROW_HEIGHT)
        settingWidgets["iconStyle"] = widget
        local opts = {"blizzard", "flat"}
        widget.dd = LayoutDropdownRow(widget, "Icon Style", 120)
        local items = {}
        for _, o in ipairs(opts) do
            table.insert(items, { text = o, value = o, onClick = function() widget.func(o) end })
        end
        widget.dd:SetItems(items)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(val) widget.dd:SetSelectedValue(val or "blizzard") end
    else widget = settingWidgets["iconStyle"] end
    widget:Show(); return widget
end

local function CreateSetting_Shape(parent)
    local widget
    if not settingWidgets["shape"] then
        widget = SF_CreateFrame("SFIndicatorSettings_Shape", parent, 300, ROW_HEIGHT)
        settingWidgets["shape"] = widget
        local opts = {"circle", "square", "diamond"}
        widget.dd = LayoutDropdownRow(widget, "Shape", 120)
        local items = {}
        for _, o in ipairs(opts) do
            table.insert(items, { text = o, value = o, onClick = function() widget.func(o) end })
        end
        widget.dd:SetItems(items)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(val) widget.dd:SetSelectedValue(val or "circle") end
    else widget = settingWidgets["shape"] end
    widget:Show(); return widget
end

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
        widget.title:SetTextColor(0.3, 0.7, 1, 1)
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
        widget.title:SetTextColor(0.3, 0.7, 1, 1)
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
        widget.title:SetTextColor(0.3, 0.7, 1, 1)
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
        function widget:SetDBValue(val) widget.slider:SetValue(val or 50) end
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

-----------------------------------------------------------------------
-- PrivateAuraOptions, Warning, Tips, Thresholds, HealthFormat, PowerFormat
-----------------------------------------------------------------------
local function CreateSetting_PrivateAuraOptions(parent)
    local widget
    if not settingWidgets["privateAuraOptions"] then
        widget = SF_CreateFrame("SFIndicatorSettings_PrivateAuraOptions", parent, 300,38)
        settingWidgets["privateAuraOptions"] = widget
        widget.cb = SF_CreateCheckButton(widget, "Private Auras")
        widget.cb:SetPoint("TOPLEFT", 5, -8)
        function widget:SetFunc(func) widget.cb.onClick = func end
        function widget:SetDBValue(val) widget.cb:SetChecked(type(val) ~= "table" and val or val and val[1]) end
    else widget = settingWidgets["privateAuraOptions"] end
    widget:Show(); return widget
end

local function CreateSetting_Warning(parent)
    local widget
    if not settingWidgets["warning"] then
        widget = SF_CreateFrame("SFIndicatorSettings_Warning", parent, 300,38)
        settingWidgets["warning"] = widget
        widget.text = widget:CreateFontString(nil, "OVERLAY")
        widget.text:SetFont(FONT_TEMPLATE, 10, "OUTLINE")
        widget.text:SetPoint("TOPLEFT", 5, -5)
        widget.text:SetTextColor(1, 0.3, 0.3, 1)
        function widget:SetFunc() end
        function widget:SetDBValue(msg) widget.text:SetText(msg or "") end
    else widget = settingWidgets["warning"] end
    widget:Show(); return widget
end

local function CreateSetting_Tips(parent, text)
    local widget = SF_CreateFrame(nil, parent, 300,38)
    widget.text = widget:CreateFontString(nil, "OVERLAY")
    widget.text:SetFont(FONT_TEMPLATE, 10, "OUTLINE")
    widget.text:SetPoint("TOPLEFT", 5, -5)
    widget.text:SetTextColor(0.7, 0.7, 0.7, 1)
    widget.text:SetText(text or "")
    function widget:SetFunc() end
    function widget:SetDBValue() end
    widget:Show()
    return widget
end

local function CreateSetting_Thresholds(parent)
    local widget
    if not settingWidgets["thresholds"] then
        widget = SF_CreateFrame("SFIndicatorSettings_Thresholds", parent, 300,38)
        settingWidgets["thresholds"] = widget
        widget.text = CreateLabel(widget, "Thresholds (configure in layout)", "TOPLEFT", 5, -8)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue() end
    else widget = settingWidgets["thresholds"] end
    widget:Show(); return widget
end

local function CreateSetting_HealthFormat(parent)
    local widget
    if not settingWidgets["healthFormat"] then
        widget = SF_CreateFrame("SFIndicatorSettings_HealthFormat", parent, 300,58)
        settingWidgets["healthFormat"] = widget
        local formats = {"none", "number", "percent", "effective_percent"}
        widget.dd = SF_CreateDropdown(widget, 140)
        widget.dd:SetPoint("TOPLEFT", 5, -20)
        local items = {}
        for _, f in ipairs(formats) do
            table.insert(items, { text = f, value = f, onClick = function() widget.func(f) end })
        end
        widget.dd:SetItems(items)
        widget.ddText = CreateLabel(widget, "Format", "BOTTOMLEFT", 5, 1)
        widget.ddText:SetPoint("BOTTOMLEFT", widget.dd, "TOPLEFT", 0, 1)
        function widget:SetFunc(func) widget.func = func end
        function widget:SetDBValue(val) widget.dd:SetSelectedValue(val or "effective_percent") end
    else widget = settingWidgets["healthFormat"] end
    widget:Show(); return widget
end

local CreateSetting_PowerFormat = CreateSetting_HealthFormat

-----------------------------------------------------------------------
-- Stubs for features not yet ported (actions, targetedSpells, etc.)
-----------------------------------------------------------------------
local function CreateSetting_ActionsPreview(parent) return CreateSetting_Tips(parent, "Actions preview (not yet ported)") end
local function CreateSetting_ActionsList(parent) return CreateSetting_Tips(parent, "Actions list (not yet ported)") end
local function CreateSetting_TargetedSpellsDisplayMode(parent) return CreateSetting_Tips(parent, "Targeted Spells (Blizzard restricted)") end
local CreateSetting_ClassFilters = CreateSetting_DispelFilters

-----------------------------------------------------------------------
-- Builder dispatch table
-----------------------------------------------------------------------
local builders = {
    ["enabled"] = CreateSetting_Enabled,
    ["vehicleNamePosition"] = CreateSetting_VehicleNamePosition,
    ["statusPosition"] = CreateSetting_StatusPosition,
    ["anchor"] = CreateSetting_Anchor,
    ["size"] = CreateSetting_Size,
    ["size-normal-big"] = CreateSetting_SizeNormalBig,
    ["size-square"] = CreateSetting_SizeSquare,
    ["size-border"] = CreateSetting_SizeAndBorder,
    ["spacing"] = CreateSetting_Spacing,
    ["thickness"] = CreateSetting_Thickness,
    ["height"] = CreateSetting_Height,
    ["durationOffset"] = CreateSetting_DurationOffset,
    ["textWidth"] = CreateSetting_TextWidth,
    ["alpha"] = CreateSetting_Alpha,
    ["healthFormat"] = CreateSetting_HealthFormat,
    ["powerFormat"] = CreateSetting_PowerFormat,
    ["durationVisibility"] = CreateSetting_DurationVisibility,
    ["durationVisibilitySimple"] = CreateSetting_DurationVisibilitySimple,
    ["orientation"] = CreateSetting_Orientation,
    ["growthOrientation"] = CreateSetting_GrowthOrientation,
    ["barOrientation"] = CreateSetting_BarOrientation,
    ["orientationCenterable"] = CreateSetting_OrientationCenterable,
    ["font-noOffset"] = CreateSetting_FontNoOffset,
    ["color"] = CreateSetting_Color,
    ["color-alpha"] = CreateSetting_ColorAlpha,
    ["glowColor"] = CreateSetting_GlowColor,
    ["colors"] = CreateSetting_Colors,
    ["blockColors"] = CreateSetting_BlockColors,
    ["overlayColors"] = CreateSetting_OverlayColors,
    ["customColors"] = CreateSetting_CustomColors,
    ["expiringColor"] = CreateSetting_ExpiringColor,
    ["color-class"] = CreateSetting_ClassColor,
    ["color-power"] = CreateSetting_PowerColor,
    ["statusColors"] = CreateSetting_StatusColors,
    ["duration"] = CreateSetting_Duration,
    ["stack"] = CreateSetting_Stack,
    ["roleTexture"] = CreateSetting_RoleTexture,
    ["glow"] = CreateSetting_Glow,
    ["glowOptions"] = CreateSetting_Glow,
    ["targetedSpellsGlow"] = CreateSetting_Glow,
    ["texture"] = CreateSetting_Texture,
    ["barTexture"] = CreateSetting_BarTexture,
    ["builtInAoEHealings"] = CreateSetting_BuiltInAoEHealings,
    ["builtInDefensives"] = CreateSetting_BuiltInDefensives,
    ["builtInExternals"] = CreateSetting_BuiltInExternals,
    ["builtInCrowdControls"] = CreateSetting_BuiltInCrowdControls,
    ["builtInMissingBuffs"] = CreateSetting_BuiltInMissingBuffs,
    ["builtInHots"] = CreateSetting_BuiltInHots,
    ["actionsPreview"] = CreateSetting_ActionsPreview,
    ["actionsList"] = CreateSetting_ActionsList,
    ["highlightType"] = CreateSetting_HighlightType,
    ["thresholds"] = CreateSetting_Thresholds,
    ["privateAuraOptions"] = CreateSetting_PrivateAuraOptions,
    ["durationPosition"] = CreateSetting_DurationPosition,
    ["textScale"] = CreateSetting_TextScale,
    ["warning"] = CreateSetting_Warning,
    ["shape"] = CreateSetting_Shape,
    ["targetCounterFilters"] = CreateSetting_TargetCounterFilters,
    ["dispelFilters"] = CreateSetting_DispelFilters,
    ["dispelShowAll"] = CreateSetting_DispelShowAll,
    ["dispelTypeColors"] = CreateSetting_DispelTypeColors,
    ["dispelTypes"] = CreateSetting_DispelTypeToggles,
    ["dispelOverlay"] = CreateSetting_DispelOverlay,
    ["dispelOverlayOpacity"] = CreateSetting_DispelOverlayOpacity,
    ["dispelGradientHeight"] = CreateSetting_DispelGradientHeight,
    ["dispelGradientWeakAlpha"] = CreateSetting_DispelGradientWeakAlpha,
    ["castBy"] = CreateSetting_CastBy,
    ["maxValue"] = CreateSetting_MaxValue,
    ["iconStyle"] = CreateSetting_IconStyle,
    ["targetedSpellsDisplayMode"] = CreateSetting_TargetedSpellsDisplayMode,
    ["powerTextFilters"] = CreateSetting_RoleFilters,
    ["debuffBlacklist"] = CreateSetting_DebuffBlacklist,
    ["bigDebuffCC"] = CreateSetting_BigDebuffCC,
}

-- Single-target custom indicator types: capped to exactly 1 tracked spell,
-- with the "auras" setting's Add Spell button opening the healer-spell
-- picker menu instead of a bare ID popup (see CreateAuraSpellList's
-- singleSpellMode). Multi-spell types (icon/icons/bars/blocks/
-- missingBuffs-style) are deliberately excluded -- they track many spells
-- at once to fill a grid via their own "num" setting.
local SINGLE_SPELL_INDICATOR_TYPES = {
    text = true, bar = true, rect = true, color = true,
    glow = true, border = true, texture = true,
}

-----------------------------------------------------------------------
-- Main dispatcher: SquizzFrames.CreateIndicatorSettings(parent, settingsTable, indicatorType)
-----------------------------------------------------------------------
function SquizzFrames.CreateIndicatorSettings(parent, settingsTable, indicatorType)
    local widgetsTable = {}

    -- Hide all cached widgets. Do NOT orphan them with SetParent(nil): a
    -- parentless frame in retail WoW renders onscreen at default strata and
    -- persists until explicitly hidden. Just hide + detach points.
    for _, w in pairs(settingWidgets) do
        w:Hide()
        w:ClearAllPoints()
        -- Re-parent to the caller's parent (in case it changed) so widgets
        -- always live inside the active scroll child.
        if w:GetParent() ~= parent then w:SetParent(parent) end
    end

    for _, setting in ipairs(settingsTable) do
        if builders[setting] then
            table.insert(widgetsTable, builders[setting](parent))
        elseif setting == "position" then
            table.insert(widgetsTable, CreateSetting_Position(parent))
        elseif setting == "position-noHCenter" then
            table.insert(widgetsTable, CreateSetting_PositionNoHCenter(parent))
        elseif string.find(setting, "^frameLevel") then
            table.insert(widgetsTable, CreateSetting_FrameLevel(parent))
        elseif string.find(setting, "^num:") then
            table.insert(widgetsTable, CreateSetting_Num(parent))
        elseif string.find(setting, "^numPerLine:") then
            table.insert(widgetsTable, CreateSetting_NumPerLine(parent))
        elseif string.find(setting, "^font%-noOffset:") then
            table.insert(widgetsTable, CreateSetting_FontNoOffset(parent))
        elseif string.find(setting, "^font") then
            table.insert(widgetsTable, CreateSetting_Font(parent, string.match(setting, "^(font%d?):?.*$")))
        elseif string.find(setting, "^checkbutton6") then
            table.insert(widgetsTable, CreateSetting_CheckButton6(parent))
        elseif string.find(setting, "^checkbutton5") then
            table.insert(widgetsTable, CreateSetting_CheckButton5(parent))
        elseif string.find(setting, "^checkbutton4") then
            table.insert(widgetsTable, CreateSetting_CheckButton4(parent))
        elseif string.find(setting, "^checkbutton3") then
            table.insert(widgetsTable, CreateSetting_CheckButton3(parent))
        elseif string.find(setting, "^checkbutton2") then
            table.insert(widgetsTable, CreateSetting_CheckButton2(parent))
        elseif string.find(setting, "^checkbutton") then
            table.insert(widgetsTable, CreateSetting_CheckButton(parent))
        elseif setting == "auras" then
            -- Generic custom-indicator aura list (Custom Indicators manager)
            -- -- no "Add Healer Spells" bulk-import here, same reasoning as
            -- customExternals/customDefensives below: a fresh custom
            -- indicator can track anything (CC, debuffs, cast auras), not
            -- specifically healer HoTs/shields, so bulk-importing that
            -- curated list doesn't belong as a one-click default here.
            -- Single-target types (SINGLE_SPELL_INDICATOR_TYPES) get the
            -- capped, healer-spell-picker-menu variant instead.
            table.insert(widgetsTable, CreateSetting_Auras(parent, 1, false, SINGLE_SPELL_INDICATOR_TYPES[indicatorType]))
        elseif setting == "dispelBlacklist" or setting == "targetedSpellsList"
            or setting == "customAoEHealings" or setting == "customCrowdControls" then
            table.insert(widgetsTable, CreateSetting_Auras(parent, 1))
        elseif setting == "customExternals" or setting == "customDefensives"
            or setting == "customMissingBuffs" then
            -- No "Add Healer Spells" here -- these are cooldown/CD and raid-
            -- buff spell lists, not healer HoTs/shields.
            table.insert(widgetsTable, CreateSetting_Auras(parent, 1, false))
        elseif string.find(setting, "^warning:") then
            table.insert(widgetsTable, CreateSetting_Warning(parent))
        else
            table.insert(widgetsTable, CreateSetting_Tips(parent, setting))
        end
    end

    return widgetsTable
end

-----------------------------------------------------------------------
-- ClearIndicatorSettings: hide every cached indicator-settings widget.
-- Must be called before rebuilding so no stale widget stays visible. We
-- NEVER SetParent(nil): in retail WoW an orphaned frame renders at default
-- strata and persists onscreen even after the options panel is closed.
-----------------------------------------------------------------------
function SquizzFrames.ClearIndicatorSettings()
    for _, w in pairs(settingWidgets) do
        if w.Hide then w:Hide() end
        if w.ClearAllPoints then w:ClearAllPoints() end
    end
end
