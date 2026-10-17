--[[ SquizzFrames IndicatorWidgetsBase.lua
-- The building blocks every indicator setting widget is made from: the
-- styled frame/checkbox/dropdown/slider/editbox/button wrappers, the shared
-- settingWidgets cache, anchor point lists and the label/row helpers.
-- Moved out of IndicatorWidgets.lua unchanged in 2.0 (phase 2 code split).
-- Loads right before it; IndicatorWidgets.lua imports everything below from
-- SquizzFrames.IndicatorWidgetsBase under the same local names.
--]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local W = SquizzFrames.Widgets
if not W then return end

local F = SquizzFrames.F

-- The themed palette from Options/Widgets.lua (2.0), shared by reference and
-- filled from LibSquizzTheme-1.0 before the window is built.
local PAL = W.palette
local C4 = W.C4

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
--
-- previewLSMType (optional): pass "font" to draw every row's label -- and the
-- button's own text -- in the face it selects. Mirrors the parameter of the
-- same name on Widgets.lua's CreateStyledDropdown, and shares its single
-- implementation (W.ApplyFontPreview) rather than carrying a second copy.
local function SF_CreateDropdown(parent, width, previewLSMType)
    -- Must be a Button (not a Frame) so it supports an OnClick script.
    local dd = CreateFrame("Button", nil, parent, "BackdropTemplate")
    dd:SetSize(width or 110, 24)

    dd.text = dd:CreateFontString(nil, "OVERLAY")
    dd.text:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    dd.text:SetPoint("LEFT", 10, 0)
    dd.text:SetPoint("RIGHT", -20, 0)  -- widened when a preview icon is shown (see UpdateText)
    dd.text:SetJustifyH("LEFT")
    dd.text:SetWordWrap(false)
    dd.text:SetTextColor(C4(PAL.TEXT))

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
    dd:SetBackdropColor(C4(PAL.PANEL_BG))
    dd:SetBackdropBorderColor(C4(PAL.DARK_BORDER))

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
                if previewLSMType == "font" and W and W.ApplyFontPreview then
                    W.ApplyFontPreview(dd.text, item.value, 11)
                end
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
        -- Anchored to the BUTTON, not to absolute screen coordinates. Still
        -- PARENTED to UIParent (that is what keeps it clear of the settings
        -- pane's clipping and level context); anchoring across a parent
        -- boundary changes position only, never clipping. Screen coordinates
        -- were captured once at open time, so scrolling the page left the
        -- popup frozen mid-air, detached from its dropdown (user report
        -- 2026-09-17). Same fix as Widgets.lua's CreateStyledDropdown, which
        -- this dropdown does NOT share code with (see note above).
        popup:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -2)
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
        popup:SetBackdropColor(C4(PAL.POPUP_BG))
        popup:SetBackdropBorderColor(C4(PAL.DARK_BORDER))

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
            row:SetBackdropColor(C4(PAL.POPUP_BG))
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

            -- Font preview: the row's own label wears the face it selects.
            if previewLSMType == "font" and W and W.ApplyFontPreview then
                W.ApplyFontPreview(t, item.value, 11)
            end

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
            row:SetScript("OnLeave", function() row:SetBackdropColor(C4(PAL.POPUP_BG)) end)
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
    dd:SetScript("OnLeave", function() dd:SetBackdropBorderColor(C4(PAL.DARK_BORDER)) end)

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
    title:SetTextColor(C4(PAL.TEXT))
    title:SetText(label or "")

    local slider = CreateFrame("Slider", nil, container, "BackdropTemplate")
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(sliderWidth, 4)
    slider:SetPoint("TOPLEFT", 10, -18)
    slider:SetMinMaxValues(_min, _max)
    slider:SetValueStep(step or 1)
    slider:SetObeyStepOnDrag(true)
    -- The visible track is deliberately a 4px hairline, but a Slider's mouse
    -- region is its frame rect -- so grabbing one meant hitting a 4px band.
    -- Negative hit-rect insets EXPAND the clickable area without touching the
    -- layout or the thumb's travel: up into the label's empty gap, down toward
    -- (but not onto) the value editbox. Same numbers as Options/Widgets.lua's
    -- CreateStyledSlider -- keep the two in sync.
    slider:SetHitRectInsets(0, 0, -11, -6)
    -- Deliberately no EnableMouseWheel here -- see the matching note in
    -- Options/Widgets.lua: it would eat the page scroll and silently change
    -- values when the cursor passed over a slider mid-scroll.

    slider:SetBackdrop({
        bgFile = [[Interface\Buttons\WHITE8X8]],
        edgeFile = [[Interface\Buttons\WHITE8X8]],
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    slider:SetBackdropColor(C4(PAL.PANEL_BG))
    slider:SetBackdropBorderColor(C4(PAL.DARK_BORDER))

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
    lowText:SetTextColor(C4(PAL.GREY_TEXT))
    lowText:SetText(tostring(_min))

    local highText = slider:CreateFontString(nil, "OVERLAY")
    highText:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
    highText:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 0, -4)
    highText:SetTextColor(C4(PAL.GREY_TEXT))
    highText:SetText(tostring(_max))

    -- Current value editbox -- click it to type an exact number.
    local editBox = CreateFrame("EditBox", nil, container, "BackdropTemplate")
    editBox:SetPoint("TOP", slider, "BOTTOM", 0, -4)
    editBox:SetSize(52, 16)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(10)
    editBox:SetJustifyH("CENTER")
    -- Both are children of `container` at the same frame level, so which one
    -- wins the overlap where the slider's expanded hit rect reaches down here
    -- would otherwise be creation-order luck. Make the editbox explicitly win.
    editBox:SetFrameLevel(slider:GetFrameLevel() + 5)
    editBox:SetBackdrop({
        bgFile = [[Interface\Buttons\WHITE8X8]],
        edgeFile = [[Interface\Buttons\WHITE8X8]],
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    editBox:SetBackdropColor(C4(PAL.PANEL_BG))
    editBox:SetBackdropBorderColor(C4(PAL.DARK_BORDER))
    editBox:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    editBox:SetTextColor(C4(PAL.TEXT))

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

    -- Tooltip by label (2.0, Modules/Options/Tooltips.lua).
    if W.IndexControl then W.IndexControl(container, label) end
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
    fs:SetTextColor(C4(PAL.GREY_TEXT))
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
    if W.IndexControl then W.IndexControl(widget, labelText) end -- tooltip by label (2.0)
    return dd
end

SquizzFrames.IndicatorWidgetsBase = {
    SF_CreateFrame = SF_CreateFrame, SF_CreateCheckButton = SF_CreateCheckButton,
    SF_CreateDropdown = SF_CreateDropdown, SF_CreateSlider = SF_CreateSlider,
    SF_CreateEditBox = SF_CreateEditBox, SF_CreateButton = SF_CreateButton,
    SF_SetEnabled = SF_SetEnabled,
    settingWidgets = settingWidgets, anchorPoints = anchorPoints,
    anchorPoints_noHCenter = anchorPoints_noHCenter, FONT_TEMPLATE = FONT_TEMPLATE,
    CreateLabel = CreateLabel, ROW_HEIGHT = ROW_HEIGHT, LayoutDropdownRow = LayoutDropdownRow,
}
