--[[ SquizzFrames Widgets.lua - Styled UI Widgets for Options Panel
    Widget styling approach adapted from Cell (by Dandre). ]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F
local LSM = LibStub and LibStub:GetLibrary("LibSharedMedia-3.0", true)

-- Media paths
local WHITE_TEXTURE = "Interface\\AddOns\\SquizzFrames\\Media\\white.tga"

-- Accent color (lazy-initialized). Sourced from F.GetAccentColor(), which
-- resolves the profile's class_color/custom_color choice -- NOT hardcoded to
-- class color, so this stays consistent with the Indicators-tab widgets
-- (IndicatorWidgets.lua) which already call F.GetAccentColor() live.
local accentColor = {r = 0.7, g = 0.7, b = 0.7}

local function InitAccentColor()
    local a = F.GetAccentColor()
    if a then
        accentColor.r = a.r
        accentColor.g = a.g
        accentColor.b = a.b
    end
end

-- Color definitions
local DARK_BG = {0.1, 0.1, 0.1, 0.9}
local DARK_BORDER = {0, 0, 0, 1}
local PANEL_BG = {0.115, 0.115, 0.115, 1}
local GREY_TEXT = {0.7, 0.7, 0.7, 1}

-- Forward-declared: defined much further down this file (needs ROW_H and
-- other locals declared in between), but CreateStyledDropdown's OpenPopup
-- closure (defined earlier) needs to call it for long item lists. Lua locals
-- aren't visible to code already parsed before they're declared, even though
-- OpenPopup only actually RUNS later when a dropdown is clicked -- same trap
-- hit a few times this session in other files.
local CreateScrollFrame

-----------------------------------------------------------------------
-- StylizeFrame: Apply dark semi-transparent backdrop to a frame
-----------------------------------------------------------------------

local function StylizeFrame(frame, color, borderColor)
    if not frame then return end
    color = color or DARK_BG
    borderColor = borderColor or DARK_BORDER

    frame:SetBackdrop({
        bgFile = WHITE_TEXTURE,
        edgeFile = WHITE_TEXTURE,
        edgeSize = 1,
        insets = {left = 1, right = 1, top = 1, bottom = 1},
    })
    frame:SetBackdropColor(color[1], color[2], color[3], color[4] or 1)
    frame:SetBackdropBorderColor(borderColor[1], borderColor[2], borderColor[3], borderColor[4] or 1)
end

-----------------------------------------------------------------------
-- CreateStyledButton: Button with class-color accent hover
-----------------------------------------------------------------------

local function CreateStyledButton(parent, text, style, size, onClick)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetText(text)
    b:SetSize(size[1], size[2])

    -- Resolve colors based on style
    local normalColor, hoverColor
    if style == "accent-hover" then
        normalColor = {0.115, 0.115, 0.115, 1}
        hoverColor = {accentColor.r, accentColor.g, accentColor.b, 0.6}
    elseif style == "accent" then
        normalColor = {accentColor.r, accentColor.g, accentColor.b, 0.3}
        hoverColor = {accentColor.r, accentColor.g, accentColor.b, 0.6}
    elseif style == "red" then
        normalColor = {0.6, 0.1, 0.1, 0.6}
        hoverColor = {0.6, 0.1, 0.1, 1}
    elseif style == "red-hover" then
        normalColor = {0.115, 0.115, 0.115, 1}
        hoverColor = {0.6, 0.1, 0.1, 1}
    elseif style == "green" then
        normalColor = {0.1, 0.6, 0.1, 0.6}
        hoverColor = {0.1, 0.6, 0.1, 1}
    elseif style == "green-hover" then
        normalColor = {0.115, 0.115, 0.115, 1}
        hoverColor = {0.1, 0.6, 0.1, 1}
    else
        normalColor = {0.115, 0.115, 0.115, 1}
        hoverColor = {0.23, 0.23, 0.23, 1}
    end

    b.color = normalColor
    b.hoverColor = hoverColor

    -- Backdrop
    b:SetBackdrop({
        bgFile = WHITE_TEXTURE,
        edgeFile = WHITE_TEXTURE,
        edgeSize = 1,
        insets = {left = 1, right = 1, top = 1, bottom = 1},
    })
    b:SetBackdropColor(normalColor[1], normalColor[2], normalColor[3], normalColor[4] or 1)
    b:SetBackdropBorderColor(0, 0, 0, 1)

    -- Inner background texture
    b.bg = b:CreateTexture(nil, "BACKGROUND", nil, -8)
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(0.115, 0.115, 0.115, 1)

    -- Font
    local font = b:CreateFontString(nil, "OVERLAY")
    font:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    font:SetPoint("CENTER")
    font:SetTextColor(1, 1, 1, 1)
    b.fontString = font

    -- Hover behavior
    b:SetScript("OnEnter", function(self)
        self:SetBackdropColor(hoverColor[1], hoverColor[2], hoverColor[3], hoverColor[4] or 1)
    end)
    b:SetScript("OnLeave", function(self)
        self:SetBackdropColor(normalColor[1], normalColor[2], normalColor[3], normalColor[4] or 1)
    end)

    -- Click handler
    if onClick then
        b:SetScript("OnClick", function(self)
            PlaySound(SOUNDKIT.U_CHAT_SCROLL_BUTTON)
            onClick(self)
        end)
    end

    function b:SetText(str)
        if self.fontString then
            self.fontString:SetText(str or "")
        end
    end

    -- Set initial text
    if b.fontString then
        b.fontString:SetText(text)
    end

    return b
end

-----------------------------------------------------------------------
-- CreateStyledCheckbox: Checkbox with class-color accent fill
-----------------------------------------------------------------------

-- Dense Tactical: an animated toggle switch (track + sliding square knob)
-- instead of a checkmark box. Track tints toward the class-color accent and
-- the knob slides right as it turns on; both interpolate over ANIM_DUR.
local TOGGLE_W, TOGGLE_H = 30, 16
local TOGGLE_PAD = 2
local TOGGLE_KNOB = TOGGLE_H - TOGGLE_PAD * 2
local TOGGLE_ANIM_DUR = 0.12
local TOGGLE_OFF_KNOB = {0.45, 0.45, 0.45}

local function CreateStyledCheckbox(parent, label, getChecked, onValueChanged)
    local cb = CreateFrame("CheckButton", nil, parent, "BackdropTemplate")
    cb:SetSize(TOGGLE_W, TOGGLE_H)

    -- Track
    cb:SetBackdrop({
        bgFile = WHITE_TEXTURE,
        edgeFile = WHITE_TEXTURE,
        edgeSize = 1,
        insets = {left = 1, right = 1, top = 1, bottom = 1},
    })
    cb:SetBackdropColor(PANEL_BG[1], PANEL_BG[2], PANEL_BG[3], PANEL_BG[4])
    cb:SetBackdropBorderColor(0, 0, 0, 1)

    -- Knob (square, per the Dense Tactical direction -- no rounded corners)
    local knob = cb:CreateTexture(nil, "ARTWORK")
    knob:SetSize(TOGGLE_KNOB, TOGGLE_KNOB)
    knob:SetColorTexture(TOGGLE_OFF_KNOB[1], TOGGLE_OFF_KNOB[2], TOGGLE_OFF_KNOB[3], 1)
    knob:SetPoint("LEFT", TOGGLE_PAD, 0)
    cb.knob = knob

    -- Label text
    local labelText = cb:CreateFontString(nil, "OVERLAY")
    labelText:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    labelText:SetPoint("LEFT", cb, "RIGHT", 7, 0)
    labelText:SetTextColor(1, 1, 1, 1)
    labelText:SetText(label or "")
    cb.labelText = labelText

    -- Hit rect insets to extend clickable area to label
    cb:SetHitRectInsets(0, -labelText:GetStringWidth() - 7, 0, 0)

    local animProgress, animTarget = 0, 0
    local disabled = false

    local function ApplyVisual(p)
        local xOff = TOGGLE_PAD + (TOGGLE_W - TOGGLE_KNOB - TOGGLE_PAD * 2) * p
        knob:ClearAllPoints()
        knob:SetPoint("LEFT", xOff, 0)
        if disabled then return end
        knob:SetColorTexture(
            TOGGLE_OFF_KNOB[1] + (accentColor.r - TOGGLE_OFF_KNOB[1]) * p,
            TOGGLE_OFF_KNOB[2] + (accentColor.g - TOGGLE_OFF_KNOB[2]) * p,
            TOGGLE_OFF_KNOB[3] + (accentColor.b - TOGGLE_OFF_KNOB[3]) * p,
            1)
        cb:SetBackdropColor(
            PANEL_BG[1] + (accentColor.r * 0.28 - PANEL_BG[1]) * p,
            PANEL_BG[2] + (accentColor.g * 0.28 - PANEL_BG[2]) * p,
            PANEL_BG[3] + (accentColor.b * 0.28 - PANEL_BG[3]) * p,
            PANEL_BG[4])
    end

    local function AnimOnUpdate(self, elapsed)
        local dir = (animTarget == 1) and 1 or -1
        animProgress = animProgress + dir * (elapsed / TOGGLE_ANIM_DUR)
        if (dir == 1 and animProgress >= 1) or (dir == -1 and animProgress <= 0) then
            animProgress = animTarget
            self:SetScript("OnUpdate", nil)
        end
        ApplyVisual(animProgress)
    end

    -- animate=true is for user clicks; SetDBValue-driven refreshes snap
    -- instantly so switching indicators/tabs doesn't replay the animation.
    local function SetVisualState(checked, animate)
        animTarget = checked and 1 or 0
        if animate then
            cb:SetScript("OnUpdate", AnimOnUpdate)
        else
            animProgress = animTarget
            cb:SetScript("OnUpdate", nil)
            ApplyVisual(animProgress)
        end
    end

    -- Initialize state (no animation on load)
    if getChecked then
        local initial = getChecked()
        cb:SetChecked(initial)
        SetVisualState(initial, false)
    else
        SetVisualState(false, false)
    end

    -- OnClick
    cb:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        SetVisualState(checked, true)
        if checked then
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        else
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
        end
        if onValueChanged then
            onValueChanged(checked, self)
        end
    end)

    -- Hover: brighten the track border
    cb:SetScript("OnEnter", function(self)
        if disabled then return end
        self:SetBackdropBorderColor(accentColor.r, accentColor.g, accentColor.b, 0.6)
    end)
    cb:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(0, 0, 0, 1)
    end)

    -- Enable/Disable handling
    cb:SetScript("OnEnable", function(self)
        disabled = false
        self.labelText:SetTextColor(1, 1, 1, 1)
        SetVisualState(self:GetChecked(), false)
    end)
    cb:SetScript("OnDisable", function(self)
        disabled = true
        self.labelText:SetTextColor(0.4, 0.4, 0.4, 1)
        knob:SetColorTexture(0.3, 0.3, 0.3, 1)
        self:SetBackdropBorderColor(0, 0, 0, 0.4)
    end)

    -- Override SetChecked so programmatic refreshes (SetDBValue) also update
    -- the visual, without animating (only user clicks animate).
    local origSetChecked = cb.SetChecked
    function cb:SetChecked(checked)
        origSetChecked(self, checked)
        SetVisualState(not not checked, false)
    end

    function cb:SetText(text)
        self.labelText:SetText(text or "")
        self:SetHitRectInsets(0, -self.labelText:GetStringWidth() - 7, 0, 0)
    end

    return cb
end

-----------------------------------------------------------------------
-- CreateStyledSlider: Horizontal slider with class-color thumb
-----------------------------------------------------------------------

-- Dense Tactical: thin 4px track with an accent-colored fill bar tracking
-- the current value (rather than a bare thumb on an empty track), and a
-- small square thumb riding on top.
local function CreateStyledSlider(parent, width, low, high, step, label, getValue, setValue)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(width + 20, 48)

    -- Label above slider
    local title = container:CreateFontString(nil, "OVERLAY")
    title:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    title:SetPoint("TOPLEFT", 10, 0)
    title:SetTextColor(1, 1, 1, 1)
    title:SetText(label or "")

    -- The slider (thin track)
    local slider = CreateFrame("Slider", nil, container, "BackdropTemplate")
    slider:SetPoint("TOPLEFT", 10, -18)
    slider:SetSize(width, 4)
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(low, high)
    slider:SetValueStep(step or 1)
    slider:SetObeyStepOnDrag(true)

    slider:SetBackdrop({
        bgFile = WHITE_TEXTURE,
        edgeFile = WHITE_TEXTURE,
        edgeSize = 1,
        insets = {left = 0, right = 0, top = 0, bottom = 0},
    })
    slider:SetBackdropColor(PANEL_BG[1], PANEL_BG[2], PANEL_BG[3], PANEL_BG[4])
    slider:SetBackdropBorderColor(0, 0, 0, 1)

    -- Accent fill from the left edge up to the current value.
    local fill = slider:CreateTexture(nil, "ARTWORK")
    fill:SetColorTexture(accentColor.r, accentColor.g, accentColor.b, 0.85)
    fill:SetPoint("TOPLEFT", 0, 0)
    fill:SetPoint("BOTTOMLEFT", 0, 0)
    fill:SetWidth(1)

    -- Square thumb riding above the thin track.
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(10, 10)
    thumb:SetColorTexture(1, 1, 1, 1)
    slider:SetThumbTexture(thumb)

    -- Low/High range text
    local lowText = slider:CreateFontString(nil, "OVERLAY")
    lowText:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
    lowText:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -4)
    lowText:SetTextColor(GREY_TEXT[1], GREY_TEXT[2], GREY_TEXT[3], 1)
    lowText:SetText(tostring(low))

    local highText = slider:CreateFontString(nil, "OVERLAY")
    highText:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
    highText:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 0, -4)
    highText:SetTextColor(GREY_TEXT[1], GREY_TEXT[2], GREY_TEXT[3], 1)
    highText:SetText(tostring(high))

    -- Current value editbox
    local editBox = CreateFrame("EditBox", nil, container, "BackdropTemplate")
    editBox:SetPoint("TOP", slider, "BOTTOM", 0, -4)
    editBox:SetSize(52, 16)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(10)
    editBox:SetJustifyH("CENTER")

    editBox:SetBackdrop({
        bgFile = WHITE_TEXTURE,
        edgeFile = WHITE_TEXTURE,
        edgeSize = 1,
        insets = {left = 1, right = 1, top = 1, bottom = 1},
    })
    editBox:SetBackdropColor(PANEL_BG[1], PANEL_BG[2], PANEL_BG[3], PANEL_BG[4])
    editBox:SetBackdropBorderColor(0, 0, 0, 1)

    editBox:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    editBox:SetTextColor(1, 1, 1, 1)

    local function UpdateFill(value)
        local frac = (high > low) and ((value - low) / (high - low)) or 0
        frac = math.max(0, math.min(1, frac))
        fill:SetWidth(math.max(1, width * frac))
    end

    local function UpdateEditBox(value)
        editBox:SetText(tostring(math.floor(value * 100 + 0.5) / 100))
    end

    -- Initialize value
    if getValue then
        local val = getValue()
        slider:SetValue(val)
        UpdateEditBox(val)
        UpdateFill(val)
    end

    slider:SetScript("OnEnter", function(_)
        thumb:SetColorTexture(accentColor.r, accentColor.g, accentColor.b, 1)
    end)

    slider:SetScript("OnLeave", function(_)
        thumb:SetColorTexture(1, 1, 1, 1)
    end)

    slider:SetScript("OnValueChanged", function(_, value)
        UpdateEditBox(value)
        UpdateFill(value)
        if setValue then setValue(value) end
    end)

    -- EditBox commit
    editBox:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val then
            val = math.max(low, math.min(high, val))
            slider:SetValue(val)
            if setValue then setValue(val) end
        end
        self:ClearFocus()
    end)

    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        local val = slider:GetValue()
        self:SetText(tostring(math.floor(val * 100 + 0.5) / 100))
    end)

    container.slider = slider
    container.editBox = editBox
    return container
end

-----------------------------------------------------------------------
-- CreateStyledSwitch: Two-state toggle with class-color highlight
-----------------------------------------------------------------------

local function CreateStyledSwitch(parent, width, height, leftText, rightText, getValue, setValue, leftValue, rightValue)
    local switch = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    switch:SetSize(width, height)

    leftValue = leftValue or "left"
    rightValue = rightValue or "right"

    StylizeFrame(switch, PANEL_BG)

    -- Left text
    local leftFS = switch:CreateFontString(nil, "OVERLAY")
    leftFS:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    leftFS:SetPoint("LEFT", 8, 0)
    leftFS:SetTextColor(1, 1, 1, 1)
    leftFS:SetText(leftText or "")

    -- Right text
    local rightFS = switch:CreateFontString(nil, "OVERLAY")
    rightFS:SetPoint("RIGHT", -8, 0)
    rightFS:SetTextColor(1, 1, 1, 1)
    rightFS:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    rightFS:SetText(rightText or "")

    -- Highlight texture covering selected side
    local highlight = switch:CreateTexture(nil, "ARTWORK")
    highlight:SetColorTexture(accentColor.r, accentColor.g, accentColor.b, 0.45)
    highlight:SetHeight(height - 2)
    highlight:SetPoint("TOPLEFT", 1, -1)
    highlight:SetPoint("BOTTOMLEFT", 1, 1)
    highlight:SetWidth(width / 2 - 2)

    -- Selected state
    local currentValue = getValue and getValue() or leftValue
    switch.selectedValue = currentValue

    local function UpdateHighlight(which)
        if which == "left" then
            highlight:ClearAllPoints()
            highlight:SetPoint("TOPLEFT", 1, -1)
            highlight:SetPoint("BOTTOMLEFT", 1, 1)
        else
            highlight:ClearAllPoints()
            highlight:SetPoint("TOPRIGHT", -1, -1)
            highlight:SetPoint("BOTTOMRIGHT", -1, 1)
        end
    end

    -- Show highlight on the side matching current value
    if currentValue == leftValue then
        UpdateHighlight("left")
    else
        UpdateHighlight("right")
    end

    switch:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        if self.selectedValue == leftValue then
            self.selectedValue = rightValue
            UpdateHighlight("right")
        else
            self.selectedValue = leftValue
            UpdateHighlight("left")
        end
        if setValue then setValue(self.selectedValue) end
    end)

    switch:SetScript("OnEnter", function(_)
        highlight:SetColorTexture(accentColor.r, accentColor.g, accentColor.b, 0.65)
    end)

    switch:SetScript("OnLeave", function(_)
        highlight:SetColorTexture(accentColor.r, accentColor.g, accentColor.b, 0.45)
    end)

    return switch
end

-----------------------------------------------------------------------
-- CreateTitledPane: Section header with class-color underline
-----------------------------------------------------------------------

-- Dense Tactical: a small square accent swatch carries the class color (not
-- the title text itself, which stays a neutral label color) plus a tight
-- hairline divider. Tighter vertical footprint than the old 24px pane.
local function CreateTitledPane(parent, text, yOffset)
    local pane = CreateFrame("Frame", nil, parent)
    pane:SetPoint("TOPLEFT", 12, yOffset or 0)
    pane:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -12, yOffset or 0)
    pane:SetHeight(18)

    local swatch = pane:CreateTexture(nil, "ARTWORK")
    swatch:SetSize(6, 6)
    swatch:SetPoint("LEFT", 0, 0)
    swatch:SetColorTexture(accentColor.r, accentColor.g, accentColor.b, 1)
    pane.swatch = swatch

    pane.title = pane:CreateFontString(nil, "OVERLAY")
    pane.title:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    pane.title:SetPoint("LEFT", swatch, "RIGHT", 6, 0)
    pane.title:SetTextColor(0.75, 0.73, 0.68, 1)
    pane.title:SetText((text or ""):upper())

    -- Hairline divider (neutral, not accent -- the swatch alone carries the
    -- class color so 15 section headers down a page don't turn into 15
    -- colored bars).
    local line = pane:CreateTexture(nil, "BACKGROUND")
    line:SetPoint("BOTTOMLEFT", 0, 0)
    line:SetPoint("BOTTOMRIGHT", 0, 0)
    line:SetHeight(1)
    line:SetColorTexture(1, 1, 1, 0.08)

    return pane
end

-----------------------------------------------------------------------
-- CreateStyledDropdown: Dropdown with class-color highlight
-----------------------------------------------------------------------

-- previewLSMType (optional): an LSM media type (e.g. "statusbar"). When set,
-- each popup row resolves item.value as a texture registered under that
-- type and paints it as the row's own background (Ellesmere-style texture
-- picker), instead of a plain text-only row. Existing callers that don't
-- pass this are unaffected.
local function CreateStyledDropdown(parent, width, height, label, items, getValue, setValue, previewLSMType)
    -- items = { {value = "x", text = "Label"}, ... }
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(width + 20, height or 50)

    -- Label above dropdown
    if label and label ~= "" then
        local title = container:CreateFontString(nil, "OVERLAY")
        title:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        title:SetPoint("TOPLEFT", 10, 0)
        title:SetTextColor(1, 1, 1, 1)
        title:SetText(label)
    end

    -- The dropdown button (click to toggle list)
    local dd = CreateFrame("Button", nil, container, "BackdropTemplate")
    dd:SetSize(width, 18)
    dd:SetPoint("TOPLEFT", 10, label and label ~= "" and -16 or 0)

    StylizeFrame(dd, PANEL_BG)

    -- Selected text
    dd.text = dd:CreateFontString(nil, "OVERLAY")
    dd.text:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    dd.text:SetPoint("LEFT", 6, 0)
    dd.text:SetPoint("RIGHT", -16, 0)
    dd.text:SetJustifyH("LEFT")
    dd.text:SetWordWrap(false)
    dd.text:SetTextColor(1, 1, 1, 1)

    -- Arrow indicator (accent-colored, Dense Tactical: dropdowns signal via
    -- the same accent language as toggles/section swatches). Plain ASCII "v",
    -- not a Unicode triangle -- Blizzard's bundled fonts only cover a sparse
    -- glyph set and render unsupported symbols as a tofu box; "v" is
    -- guaranteed present in every font and reads as a caret well enough.
    dd.arrow = dd:CreateFontString(nil, "OVERLAY")
    dd.arrow:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    dd.arrow:SetPoint("RIGHT", -6, -1)
    dd.arrow:SetTextColor(accentColor.r, accentColor.g, accentColor.b, 1)
    dd.arrow:SetText("v")

    -- Initialize selected value
    dd.selectedValue = getValue and getValue() or (items and items[1] and items[1].value)
    dd.items = items

    -- Update display text
    local function UpdateText()
        for _, item in ipairs(dd.items) do
            if item.value == dd.selectedValue then
                dd.text:SetText(item.text)
                return
            end
        end
        dd.text:SetText(dd.items[1] and dd.items[1].text or "")
    end
    UpdateText()

    -- Popup and closer state
    local popup = nil
    local closer = nil
    local isOpen = false

    local function ClosePopup()
        if popup then
            popup:Hide()
            popup = nil
        end
        if closer then
            closer:Hide()
        end
        isOpen = false
    end

    local function OpenPopup()
        -- If already open, close it (toggle behavior)
        if isOpen then
            ClosePopup()
            return
        end

        ClosePopup() -- ensure clean state

        local numItems = #dd.items
        popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        popup:SetFrameStrata("TOOLTIP")  -- higher than DIALOG so it draws on top
        popup:SetFrameLevel(100)

        -- Position popup below the dropdown button using screen coordinates
        local left, bottom = dd:GetLeft(), dd:GetBottom()
        if left and bottom and left > 0 and bottom > 0 then
            popup:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, bottom - 2)
        else
            popup:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -2)
        end

        -- Long item lists (LibSharedMedia's full statusbar registry, for the
        -- bar-texture pickers) previously made this popup grow tall enough
        -- to run off the bottom of the screen with no way to reach the rest
        -- -- confirmed via user report on Heal Absorb/Shield Overlay's
        -- texture dropdown. Cap the visible height at MAX_VISIBLE_ITEMS rows
        -- and scroll past that instead of growing unbounded.
        local itemHeight = 18
        local MAX_VISIBLE_ITEMS = 15
        local needsScroll = numItems > MAX_VISIBLE_ITEMS
        local visibleCount = needsScroll and MAX_VISIBLE_ITEMS or numItems
        popup:SetSize(width, visibleCount * itemHeight + 4)

        StylizeFrame(popup, {0.12, 0.12, 0.12, 1}, {0, 0, 0, 1})

        -- Rows parent to a scroll frame's content child when scrolling is
        -- needed (CreateScrollFrame reserves 18px on the right for its
        -- scrollbar, so rows there are narrower than the plain-popup case).
        local rowParent = popup
        local rowWidth = width - 4
        if needsScroll then
            local scroll = CreateScrollFrame(popup)
            scroll.scrollChild:SetHeight(numItems * itemHeight)
            rowParent = scroll.scrollChild
            rowWidth = width - 18 - 4
        end

        for i, item in ipairs(dd.items) do
            local row = CreateFrame("Button", nil, rowParent, "BackdropTemplate")
            row:SetSize(rowWidth, itemHeight)
            row:SetPoint("TOPLEFT", 2, -(i - 1) * itemHeight - 2)

            -- Texture preview (Ellesmere-style): paint the row's own
            -- background with the actual registered texture, muted so the
            -- label stays readable. Sits BELOW the hover/selected tint
            -- (explicit lower sublevel -- same-sublevel draw order between
            -- two textures on one layer isn't guaranteed by creation order
            -- alone), which stays transparent when idle, so the texture
            -- shows through clearly except when hovered/selected.
            if previewLSMType and LSM then
                local texPath = LSM:Fetch(previewLSMType, item.value)
                if texPath then
                    local preview = row:CreateTexture(nil, "BACKGROUND", nil, -1)
                    preview:SetAllPoints()
                    preview:SetTexture(texPath)
                    preview:SetVertexColor(1, 1, 1, 0.5)
                end
            end

            -- Highlight background
            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetAllPoints()
            row.bg:SetColorTexture(0, 0, 0, 0)

            -- Selected indicator
            if item.value == dd.selectedValue then
                row.bg:SetColorTexture(accentColor.r, accentColor.g, accentColor.b, 0.25)
            end

            local rowText = row:CreateFontString(nil, "OVERLAY")
            rowText:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
            rowText:SetPoint("LEFT", 6, 0)
            rowText:SetTextColor(1, 1, 1, 1)
            rowText:SetText(item.text)

            row:SetScript("OnEnter", function()
                row.bg:SetColorTexture(accentColor.r, accentColor.g, accentColor.b, 0.4)
            end)
            row:SetScript("OnLeave", function()
                if item.value == dd.selectedValue then
                    row.bg:SetColorTexture(accentColor.r, accentColor.g, accentColor.b, 0.25)
                else
                    row.bg:SetColorTexture(0, 0, 0, 0)
                end
            end)

            row:SetScript("OnClick", function()
                dd.selectedValue = item.value
                UpdateText()
                if setValue then setValue(item.value) end
                ClosePopup()
            end)
        end

        popup:Show()
        isOpen = true

        -- Create a single persistent closer frame that catches clicks outside
        if not closer then
            closer = CreateFrame("Button", nil, UIParent)
            closer:SetFrameStrata("TOOLTIP")
            closer:SetFrameLevel(99)  -- below popup (100) but still high
            closer:SetAllPoints(UIParent)
            closer:EnableMouse(true)
            closer:SetScript("OnClick", function()
                ClosePopup()
            end)
        end
        closer:Show()
    end

    dd:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        OpenPopup()
    end)

    dd:SetScript("OnEnter", function()
        dd:SetBackdropBorderColor(accentColor.r, accentColor.g, accentColor.b, 0.6)
    end)
    dd:SetScript("OnLeave", function()
        dd:SetBackdropBorderColor(0, 0, 0, 1)
    end)

    -- Update dropdown items and refresh display text
    function dd:RefreshItems(newItems)
        dd.items = newItems or dd.items
        -- If the current value is no longer valid, reset to first item
        local found = false
        for _, item in ipairs(dd.items) do
            if item.value == dd.selectedValue then
                found = true
                break
            end
        end
        if not found and dd.items and dd.items[1] then
            dd.selectedValue = dd.items[1].value
        end
        UpdateText()
        -- Close popup if open so next OpenPopup rebuilds with new items
        if isOpen then ClosePopup() end
    end

    container.dropdown = dd
    return container
end

-----------------------------------------------------------------------
-- Cell-style widgets for the click-casting panel
-----------------------------------------------------------------------
-- These recreate Cell's panel primitives (scroll frame, binding-capture
-- overlay, popup edit box, draggable binding rows, dropdown menu) using
-- SquizzFrames' existing styled widgets. They're self-contained — no
-- dependency on Cell internals.

local LIGHT_BG = {0.18, 0.18, 0.18, 1}
local ROW_H = 28
local GRID_PADDING = 6

-----------------------------------------------------------------------
-- CreateScrollFrame: a scroll frame with a content child + scrollbar
-----------------------------------------------------------------------
-- Returns the scroll frame. Access content via scrollFrame.scrollChild.
-- Methods: SetContentHeight(rows), ScrollToBottom(), Reset().
function CreateScrollFrame(parent)
    local sf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 0, 0)
    sf:SetPoint("BOTTOMRIGHT", -18, 0)
    sf:SetClipsChildren(true)

    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(sf:GetWidth() > 0 and sf:GetWidth() or 1)
    content:SetClipsChildren(false)
    sf:SetScrollChild(content)
    sf.scrollChild = content

    -- sf:GetWidth() is often still 0 right after the SetPoint calls above --
    -- WoW resolves anchor-derived sizes a frame later, not synchronously --
    -- so the one-shot SetWidth above can lock content to a stale ~0px width.
    -- Anything inside a row that stretches via LEFT+RIGHT anchors (e.g. a
    -- spell-list row's name text) then gets clipped down to invisible even
    -- though it's really there. Keep content's width synced to the scroll
    -- frame's actual resolved width whenever it changes.
    sf:SetScript("OnSizeChanged", function(self, width)
        if width and width > 0 then
            content:SetWidth(width)
        end
    end)

    function sf:SetContentHeight(rows)
        content:SetHeight(math.max(1, rows * (ROW_H + 2)))
        sf:UpdateScrollChildRect()
        sf.scrollChild = content
    end
    function sf:ScrollToBottom()
        local _, max = sf.ScrollBar:GetMinMaxValues()
        sf.ScrollBar:SetValue(max)
    end
    function sf:Reset()
        sf.ScrollBar:SetValue(0)
    end
    content.UpdateScrollChildRect = content.UpdateScrollChildRect or function() sf:UpdateScrollChildRect() end

    return sf
end

-----------------------------------------------------------------------
-- CreateBindingCapture: "Press a key" overlay that captures the next
-- mouse button / wheel / keyboard key + modifier combination.
-----------------------------------------------------------------------
-- On capture call self.func(modifier, key) where modifier is the
-- canonical "alt-ctrl-shift-" string and key is e.g. "Left", "ScrollUp",
-- "Q". Call SetFunc to assign the handler.
local BIND_BUTTON_MAP = {
    LeftButton = "Left", RightButton = "Right", MiddleButton = "Middle",
    Button4 = "Button4", Button5 = "Button5",
}

local function _ReadModifier()
    local m = ""
    if IsAltKeyDown() then m = m .. "alt-" end
    if IsControlKeyDown() then m = m .. "ctrl-" end
    if IsShiftKeyDown() then m = m .. "shift-" end
    return m
end

-- Keys to ignore on OnKeyDown (bare modifier keys).
local IS_MODIFIER_KEY = {
    ["LSHIFT"] = true, ["RSHIFT"] = true, ["LCTRL"] = true, ["RCTRL"] = true,
    ["LALT"] = true, ["RALT"] = true,
}

local function CreateBindingCapture(parent)
    local overlay = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    overlay:SetFrameStrata("TOOLTIP")
    overlay:SetFrameLevel(parent:GetFrameLevel() + 10)
    overlay:SetPoint("CENTER")
    overlay:SetSize(360, 160)
    StylizeFrame(overlay, DARK_BG, {0.6, 0.4, 0.1, 1})
    overlay:EnableMouse(true)
    overlay:EnableMouseWheel(true)
    overlay:EnableKeyboard(true)

    local title = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Press a key combination...")

    local hint = overlay:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    hint:SetPoint("TOP", 0, -40)
    hint:SetText("Press any mouse button, wheel, or keyboard key with optional Shift/Ctrl/Alt")

    local captured = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    captured:SetPoint("CENTER", 0, 10)

    overlay.func = nil

    local function Fire(mod, key)
        overlay:Hide()
        UISpecialFrames[tostring(overlay)] = nil
        if overlay.func then overlay.func(mod, key) end
    end

    overlay:SetScript("OnMouseDown", function(_, btn)
        local key = BIND_BUTTON_MAP[btn]
        if key then Fire(_ReadModifier(), key) end
        -- unknown buttons ignored
    end)
    overlay:SetScript("OnMouseWheel", function(_, delta)
        local key = delta > 0 and "ScrollUp" or "ScrollDown"
        Fire(_ReadModifier(), key)
    end)
    overlay:SetScript("OnKeyDown", function(_, key)
        if IS_MODIFIER_KEY[key] then return end
        Fire(_ReadModifier(), key)
    end)

    -- Close button.
    local close = CreateFrame("Button", nil, overlay, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() overlay:Hide() end)

    function overlay:SetFunc(fn) overlay.func = fn end

    function overlay:ShowCapture()
        captured:SetText("")
        self:Show()
        UISpecialFrames[tostring(self)] = true
        self:SetPropagateKeyboardInput(false)
    end

    overlay:Hide()
    return overlay
end

-----------------------------------------------------------------------
-- CreatePopupEditBox: a multi-line edit box over a target cell.
-----------------------------------------------------------------------
-- Used for spell-ID and custom-macro entry. onEnter(text) commits,
-- onChange(text) fires live (for spell-name preview).
local function CreatePopupEditBox(parent)
    local box = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    box:SetFrameStrata("TOOLTIP")
    box:SetAutoFocus(true)
    box:SetFontObject(GameFontHighlight)
    box:SetMultiLine(false)
    box:SetWidth(200)
    box:SetHeight(24)
    box:SetTextInsets(6, 6, 0, 0)
    StylizeFrame(box, DARK_BG, {0.6, 0.4, 0.1, 1})
    -- White text for readability.
    box:SetTextColor(1, 1, 1, 1)

    local _origText = ""
    local _onEnter, _onChange

    box:SetScript("OnEscapePressed", function(self)
        self:SetText(_origText)
        self:ClearFocus()
        self:Hide()
    end)
    box:SetScript("OnEnterPressed", function(self)
        local text = self:GetText() or ""
        self:ClearFocus()
        self:Hide()
        if _onEnter then _onEnter(text) end
    end)
    box:SetScript("OnTextChanged", function(self)
        if _onChange then _onChange(self:GetText() or "") end
    end)
    -- Swallow clicks that might dismiss us.
    box:SetScript("OnMouseDown", function(self) self:SetFocus() end)

    function box:Open(originalText, x, y, onChange, onEnter)
        _origText = originalText or ""
        _onChange = onChange
        _onEnter = onEnter
        self:SetText(_origText)
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", parent, "BOTTOMLEFT", x, y - 4)
        self:Show()
        self:HighlightText()
        self:SetFocus()
    end

    box:Hide()
    return box
end

-----------------------------------------------------------------------
-- CreateMenu: a simple dropdown menu (replaces Cell.cell.menu).
-----------------------------------------------------------------------
-- items = { { text="...", onClick=function() end, value=... }, ... }
-- Opens a TOOLTIP-strata popup at the given anchor; clicking outside or
-- an item closes it.
local function CreateMenu(anchor, items, width)
    width = width or 150

    -- Parented to UIParent -- NOT to `anchor` -- with explicit absolute frame
    -- levels. This mirrors CreateStyledDropdown above, which is the one menu
    -- in this file that demonstrably works; `anchor` is now used only as a
    -- positioning reference by the caller, plus the auto-hide hook at the end.
    --
    -- Two earlier attempts to fix row clicks failed because of the old
    -- parenting. As a child of the caller's frame the menu sat inside that
    -- frame's clipping and level context (the options page lives in a
    -- clipping scroll frame), and the closer's level was derived as
    -- `menu:GetFrameLevel() - 1`, which collapses to the SAME level whenever
    -- the menu's own level is 0. At equal level the later-created frame wins
    -- hit testing, and the closer is created last -- so it swallowed every
    -- row click: the menu vanished and nothing was ever selected.
    -- SetToplevel(true) made it worse by re-levelling the menu dynamically,
    -- so any level captured at construction was stale by the first click.
    local menu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    menu:SetFrameStrata("TOOLTIP")
    menu:SetFrameLevel(100)
    -- Keep a tall menu on screen rather than letting it run off the bottom.
    menu:SetClampedToScreen(true)
    StylizeFrame(menu, {0.08, 0.08, 0.08, 1}, {0, 0, 0, 1})

    local rows = {}
    for i, it in ipairs(items) do
        local row = CreateFrame("Button", nil, menu)
        -- Explicit, not relying on the child-inherits-parent+1 default: these
        -- must sit above the closer (99) for clicks to reach them at all.
        row:SetFrameLevel(menu:GetFrameLevel() + 1)
        local h = it.divider and 8 or 20
        row:SetHeight(h)
        row:SetPoint("TOPLEFT", menu, "TOPLEFT", 1, -((i - 1) * 20 + 1))
        row:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -1, -((i - 1) * 20 + 1))
        row.divider = it.divider
        if it.divider then
            local line = row:CreateTexture(nil, "ARTWORK")
            line:SetPoint("TOPLEFT", 4, -3)
            line:SetPoint("BOTTOMRIGHT", -4, 3)
            line:SetColorTexture(0.3, 0.3, 0.3, 0.6)
        else
            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.text:SetPoint("LEFT", 8, 0)
            row.text:SetText(it.text or "")
            local hl = row:CreateTexture(nil, "BACKGROUND")
            hl:SetAllPoints()
            hl:SetColorTexture(0.3, 0.2, 0.1, 0.5)
            hl:Hide()
            row:SetScript("OnEnter", function() hl:Show() end)
            row:SetScript("OnLeave", function() hl:Hide() end)
            row:SetScript("OnClick", function()
                -- Selection FIRST, teardown second. Hiding a frame under the
                -- cursor fires OnLeave and can move focus, so doing it before
                -- the callback leaves the actual result of the click at the
                -- mercy of that teardown. Nothing here needs the menu gone in
                -- order to run.
                --
                -- menu:Hide() then releases the full-screen closer via the
                -- OnHide handler below. This used to call a bare CloseMenus(),
                -- which is not defined anywhere in this addon (nor a reliable
                -- global) -- so picking any item threw, and the closer was
                -- never released either way.
                if it.onClick then it.onClick() end
                menu:Hide()
            end)
        end
        rows[i] = row
    end
    menu:SetSize(width, math.max(20, #items * 20 + 2))

    -- Full-screen closer catches outside clicks. Same strata as the menu with
    -- an explicit level one below it, exactly as CreateStyledDropdown does
    -- (popup 100 / closer 99).
    --
    -- The level is a CONSTANT, not `menu:GetFrameLevel() - 1`. That arithmetic
    -- was how this broke: the menu's own level can be 0, so -1 clamps back to
    -- 0 and the closer lands on the SAME level -- and at equal level the
    -- later-created frame (the closer, created here at the end) wins hit
    -- testing. It swallowed every click meant for a row, so the menu vanished
    -- and nothing was ever selected (reported 2026-08-16: picking a group
    -- member never filled the name box).
    local closer = CreateFrame("Button", nil, UIParent)
    closer:SetFrameStrata("TOOLTIP")
    closer:SetFrameLevel(99) -- below the menu (100) and its rows (101)
    closer:SetAllPoints(UIParent)
    closer:EnableMouse(true)
    -- CreateFrame returns a SHOWN frame. Without this the closer starts
    -- covering the entire screen the instant a menu is CONSTRUCTED -- before
    -- ShowMenu is ever called -- swallowing every click on the UI underneath
    -- it, which is exactly how the options panel became impossible to close.
    closer:Hide()
    closer:SetScript("OnClick", function()
        menu:Hide()
    end)

    -- Single release point for the closer. Every route that hides the menu
    -- (outside click, item pick, Show/Hide from elsewhere) goes through
    -- OnHide, so none of them can leave a full-screen invisible button
    -- attached to the cursor.
    menu:SetScript("OnHide", function()
        closer:Hide()
    end)

    function menu:ShowMenu()
        self:Show()
        closer:Show()
    end

    -- The menu is a child of UIParent now, so it no longer disappears with
    -- whatever opened it -- follow the anchor's visibility explicitly, or a
    -- menu left open would outlive its popup and float over the UI.
    if anchor and anchor.HookScript then
        anchor:HookScript("OnHide", function() menu:Hide() end)
    end

    -- NOTE: this used to end with
    --     setmetatable(menu, {__call = function() return menu end})
    -- which REPLACED the frame's own metatable. That metatable is what
    -- supplies every widget method via __index, so SetPoint/Hide/Show all
    -- became nil and the menu errored on first use ("attempt to call a nil
    -- value"). Nothing ever called menu(), so the metamethod is simply gone
    -- rather than merged back in.
    menu._closer = closer
    return menu
end

-----------------------------------------------------------------------
-- _GridCell: one Key/Type/Action cell inside a binding row.
-----------------------------------------------------------------------
local function _NewGridCell(parent, width, labelText, onClick)
    local cell = CreateFrame("Button", nil, parent, "BackdropTemplate")
    cell:SetHeight(ROW_H - 4)
    cell:SetWidth(width)
    cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    StylizeFrame(cell, LIGHT_BG, {0, 0, 0, 0.6})

    cell.label = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cell.label:SetPoint("LEFT", GRID_PADDING, 0)
    cell.label:SetWidth(width - GRID_PADDING * 2)
    cell.label:SetJustifyH("LEFT")
    cell.label:SetText(labelText or "")

    local hl = cell:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints()
    hl:SetColorTexture(0.3, 0.2, 0.1, 0.5)
    hl:Hide()
    cell:SetScript("OnEnter", function() cell.isSelected = true; hl:Show() end)
    cell:SetScript("OnLeave", function() cell.isSelected = false; hl:Hide() end)

    if onClick then
        cell:SetScript("OnClick", function()
            PlaySound(SOUNDKIT.U_CHAT_SCROLL_BUTTON)
            onClick()
        end)
    end

    function cell:SetText(t) cell.label:SetText(t or "") end
    function cell:GetText() return cell.label:GetText() end
    return cell
end

-----------------------------------------------------------------------
-- CreateBindingRow: one draggable Key/Type/Action row.
-----------------------------------------------------------------------
-- row.keyGrid / row.typeGrid / row.actionGrid: the cells, each with
-- SetText/GetText and their own click handler. row.clickCastingIndex: its
-- position in the binding list. The row registers for left-drag reordering;
-- right-click on the row dims it (delete). onKeyClick / onTypeClick /
-- onActionClick fire when the respective cell is clicked.
local function CreateBindingRow(parent, width, onRightClick, onDragReorder, onKeyClick, onTypeClick, onActionClick)
    local rowW = width - 6
    local cellW = math.floor((rowW + GRID_PADDING * 2 - 8) / 3)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetHeight(ROW_H)
    row:SetWidth(rowW)
    row:RegisterForDrag("LeftButton")
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.14, 0.14, 0.14, 0.6)
    row.bg = bg

    row.keyGrid = _NewGridCell(row, cellW, "", onKeyClick)
    row.keyGrid:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.typeGrid = _NewGridCell(row, cellW, "", onTypeClick)
    row.typeGrid:SetPoint("LEFT", row.keyGrid, "RIGHT", -GRID_PADDING, 0)
    row.actionGrid = _NewGridCell(row, cellW, "", onActionClick)
    row.actionGrid:SetPoint("LEFT", row.typeGrid, "RIGHT", -GRID_PADDING, 0)

    row:SetScript("OnDragStart", function(self)
        self.isDragging = true
        self:SetAlpha(0.5)
    end)
    row:SetScript("OnDragStop", function(self)
        self.isDragging = false
        self:SetAlpha(1)
        -- Defer so GetMouseFocus returns the destination row.
        C_Timer.After(0, function()
            if not onDragReorder then return end
            local f = GetMouseFocus()
            local idx = f and f.GetClickCastingIndex and f:GetClickCastingIndex()
            if idx and idx ~= self.clickCastingIndex then
                onDragReorder(self.clickCastingIndex, idx)
            end
        end)
    end)
    row:SetScript("OnClick", function(_, btn)
        if btn == "RightButton" then
            if onRightClick then onRightClick(row) end
        else
            if row.onClick then row.onClick(row, "LeftButton") end
        end
    end)

    row.clickCastingIndex = 1
    row.isDragging = false
    row.changed = false
    function row:GetClickCastingIndex() return row.clickCastingIndex end

    function row:SetChanged(changed)
        row.changed = changed
        if changed then
            row.bg:SetColorTexture(0.25, 0.18, 0.05, 0.9)
        else
            row.bg:SetColorTexture(0.14, 0.14, 0.14, 0.6)
        end
    end
    function row:Highlight() row.bg:SetColorTexture(0.22, 0.22, 0.1, 0.9) end
    function row:Unhighlight() row:SetChanged(row.changed) end

    return row
end

-----------------------------------------------------------------------
-- Initialization
-----------------------------------------------------------------------

InitAccentColor()

-----------------------------------------------------------------------
-- CreateColorPicker
-----------------------------------------------------------------------
-- A swatch button that opens WoW's ColorPickerFrame plus an opacity slider.

local function CreateColorPicker(parent, label, getColor, setColor)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(200, 24)

    if label then
        container.label = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        container.label:SetPoint("LEFT")
        container.label:SetText(label)
    end

    container.swatch = CreateFrame("Button", nil, container, "BackdropTemplate")
    container.swatch:SetSize(18, 18)
    container.swatch:SetPoint("LEFT", label and (container.label:GetStringWidth() + 8) or 0, 0)
    StylizeFrame(container.swatch, {0, 0, 0, 1}, {0.5, 0.5, 0.5, 1})

    container.swatch.tex = container.swatch:CreateTexture(nil, "ARTWORK")
    container.swatch.tex:SetAllPoints()
    container.swatch.tex:SetPoint("TOPLEFT", 1, -1)
    container.swatch.tex:SetPoint("BOTTOMRIGHT", -1, 1)

    -- Opacity slider. OptionsSliderTemplate's stock "Low"/"High" end labels
    -- don't say what's being adjusted at all -- add a tooltip so hovering
    -- explains it's opacity (0 = fully transparent, 1 = fully opaque)
    -- without needing extra vertical space for a title in this compact row.
    container.opacity = CreateFrame("Slider", nil, container, "OptionsSliderTemplate")
    container.opacity:SetSize(80, 16)
    container.opacity:SetPoint("LEFT", container.swatch, "RIGHT", 8, 0)
    container.opacity:SetMinMaxValues(0, 1)
    container.opacity:SetValueStep(0.05)
    container.opacity:SetObeyStepOnDrag(true)
    container.opacity:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Opacity")
        GameTooltip:AddLine("Low = fully transparent, High = fully opaque.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    container.opacity:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Guards against a real WoW Slider quirk: SetValue() below fires
    -- OnValueChanged even when set programmatically, not just on user drag.
    -- Without this guard, the UNCONDITIONAL UpdateSwatch() call at the end of
    -- this function (just syncing the displayed swatch/slider to whatever
    -- color already exists) fired setColor() immediately at CONSTRUCTION
    -- TIME with getColor()'s current value -- for callers that pass their
    -- real setter directly (not through an indirection layer), this meant
    -- simply BUILDING the widget silently overwrote the real stored color
    -- (confirmed bug: opening/rebuilding the options panel reset a
    -- class-color health bar to the custom-color fallback, with no user
    -- interaction at all).
    --
    -- This must guard EVERY UpdateSwatch() call, not just the first one --
    -- CreateSetting_ColorAlpha's SetDBValue calls widget.color.UpdateSwatch()
    -- every time a DIFFERENT indicator's settings panel is opened (e.g.
    -- switching between Shield Overlay and Heal Absorb, which share this
    -- cached widget), long after construction. A one-shot "constructing"
    -- flag only protected the very first call, so that later resync still
    -- fired OnValueChanged for real -- and since SetDBValue runs BEFORE
    -- SetFunc rebinds widget.func to the NEWLY selected indicator, that
    -- write landed on the PREVIOUSLY selected indicator's t.color instead
    -- (confirmed via user report: switching between the two reset color/
    -- opacity to default -- what actually happened was each switch
    -- overwrote the OTHER indicator's saved color with whatever this one
    -- had). A reusable flag wrapping every SetValue call (not just the
    -- first) fixes both cases.
    local suppressCallback = true

    local function UpdateSwatch()
        local r, g, b, a = getColor()
        container.swatch.tex:SetColorTexture(r or 1, g or 1, b or 1, 1)
        suppressCallback = true
        container.opacity:SetValue(a or 1)
        suppressCallback = false
    end

    -- ColorPickerFrame:SetColorRGB / .func / .opacityFunc / .hasOpacity /
    -- .opacity / .previousValues (the old direct-field API) were REMOVED on
    -- this client -- every color swatch click threw "attempt to call a nil
    -- value" at ColorPickerFrame:SetColorRGB (confirmed via BugGrabber log,
    -- most recent error in the session). Replaced with the current
    -- SetupColorPickerAndShow(info) API. Note WoW's "opacity" here is
    -- inverted from normal alpha (1 = fully transparent, 0 = fully opaque),
    -- hence the `1 - x` conversions on both sides -- this inversion was
    -- already present in the old code's OpacitySliderFrame reads, so it's
    -- an existing API convention, not something introduced by this fix.
    container.swatch:SetScript("OnClick", function()
        local r, g, b, a = getColor()
        r, g, b, a = r or 1, g or 1, b or 1, a or 1
        local info = {}
        info.swatchFunc = function()
            local nr, ng, nb = ColorPickerFrame:GetColorRGB()
            local na = 1 - ColorPickerFrame:GetColorAlpha()
            setColor(nr, ng, nb, na)
            UpdateSwatch()
        end
        info.opacityFunc = function()
            local nr, ng, nb = ColorPickerFrame:GetColorRGB()
            local na = 1 - ColorPickerFrame:GetColorAlpha()
            setColor(nr, ng, nb, na)
            UpdateSwatch()
        end
        info.cancelFunc = function(previousValues)
            if previousValues then
                setColor(previousValues.r, previousValues.g, previousValues.b, 1 - (previousValues.opacity or 0))
                UpdateSwatch()
            end
        end
        info.hasOpacity = true
        info.opacity = 1 - a
        info.r, info.g, info.b = r, g, b
        ColorPickerFrame:SetupColorPickerAndShow(info)
    end)

    container.opacity:SetScript("OnValueChanged", function(_, val)
        if suppressCallback then return end
        local r, g, b = getColor()
        setColor(r, g, b, val)
        UpdateSwatch()
    end)

    container.UpdateSwatch = UpdateSwatch
    UpdateSwatch()

    return container
end

-----------------------------------------------------------------------
-- CreateIndicatorList
-----------------------------------------------------------------------
-- A scrollable list of indicator rows (name + type icon) with selection.
-- Methods: SetItems(items), SetSelected(id), GetSelected()

local function CreateIndicatorList(parent, onClickItem)
    local container = CreateFrame("Frame", nil, parent)
    container:SetAllPoints()

    local scrollFrame = CreateScrollFrame(container)
    scrollFrame:SetAllPoints()

    local rows = {}
    local selectedId = nil

    function container.SetItems(items)
        -- Clear existing rows.
        for _, row in ipairs(rows) do
            row:Hide()
            row:SetParent(nil)
        end
        wipe(rows)

        if not items then return end
        for i, item in ipairs(items) do
            local row = CreateFrame("Button", nil, scrollFrame.scrollChild, "BackdropTemplate")
            row:SetSize(container:GetWidth() - 20, 20)
            StylizeFrame(row, {0.1, 0.1, 0.1, 0.6}, {0.3, 0.3, 0.3, 0.5})
            if i == 1 then
                row:SetPoint("TOPLEFT", 0, 0)
            else
                row:SetPoint("TOPLEFT", rows[i-1], "BOTTOMLEFT", 0, -1)
            end

            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.label:SetPoint("LEFT", 5, 0)
            row.label:SetPoint("RIGHT", -5, 0)
            row.label:SetJustifyH("LEFT")
            row.label:SetText(item.name or "")

            row.id = item.indicatorName or i
            row._item = item

            row:SetScript("OnClick", function()
                container.SetSelected(row.id)
                if onClickItem then onClickItem(row.id, item) end
            end)

            rows[i] = row
        end

        scrollFrame:SetContentHeight(#items, 20, 1)
    end

    function container.SetSelected(id)
        selectedId = id
        for _, row in ipairs(rows) do
            if row.id == id then
                row.label:SetTextColor(1, 0.82, 0)
            else
                if row._item and row._item.enabled then
                    row.label:SetTextColor(1, 1, 1)
                else
                    row.label:SetTextColor(0.5, 0.5, 0.5)
                end
            end
        end
    end

    function container.GetSelected()
        return selectedId
    end

    return container
end

-- Unique suffix for each CreateAuraSpellList instance's menu popup frame
-- name (needs a stable global name to register with UISpecialFrames).
local auraSpellListMenuCounter = 0

-- Player's own class' healer spells (Defaults/Indicator_Defaults.lua's
-- class-keyed healerSpells table). Matches IndicatorWidgets.lua's "Your
-- Class's HoTs" checklist: the whole class group, unfiltered by
-- known-spell status.
local function GetPlayerHealerSpellChoices()
    local playerClass = F.GetClassFile and F.GetClassFile("player")
    local classTable = SquizzFrames.defaults and SquizzFrames.defaults.healerSpells
    local spellSet = (playerClass and classTable and classTable[playerClass]) or {}
    return F.FlattenSpellTable and F.FlattenSpellTable({ spellSet }) or {}
end

-----------------------------------------------------------------------
-- CreateAuraSpellList
-----------------------------------------------------------------------
-- A scrollable list of spell ID rows (icon + name + delete) plus an "Add
-- Spell" button that opens a popup editbox.
-- Methods: SetAuras(auras), GetAuras()
--
-- singleSpellMode = true (used by the single-target custom indicator types
-- -- text/bar/rect/color/glow/border/texture): caps the list at exactly 1
-- spell (the Add button hides once populated) and changes "Add Spell" from
-- a direct ID-entry popup into a menu -- a "Enter Spell ID" row at the top
-- (falls through to the same ID-entry popup every other caller uses) plus
-- the player's own known healer spells below it, each one click to add.

local function CreateAuraSpellList(parent, auraType, getAuras, setAuras, showHealerButton, singleSpellMode)
    local container = CreateFrame("Frame", nil, parent)

    local scrollFrame = CreateScrollFrame(container)
    scrollFrame:SetPoint("TOPLEFT")
    scrollFrame:SetPoint("BOTTOMRIGHT", 0, 30) -- leave room for add button

    -- Clean add-by-ID popup: a small bordered dialog with a label, numeric
    -- editbox, and explicit Add/Cancel buttons -- replaces the old bare-
    -- EditBox-floating-over-the-button hack (no visible frame, no cancel
    -- affordance). Same pattern as the Debuff Blacklist checklist's own add
    -- popup (IndicatorWidgets.lua's CreateSetting_DebuffBlacklist).
    local popup = CreateFrame("Frame", nil, container, "BackdropTemplate")
    popup:SetSize(170, 74)
    popup:SetPoint("BOTTOM", 0, 4)
    popup:SetFrameStrata("DIALOG")
    StylizeFrame(popup, {0.08, 0.08, 0.08, 0.98}, {0.4, 0.4, 0.4, 0.9})
    popup:Hide()
    popup.label = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    popup.label:SetPoint("TOP", 0, -8)
    popup.label:SetText("Enter Spell ID:")
    popup.editbox = CreateFrame("EditBox", nil, popup, "InputBoxTemplate")
    popup.editbox:SetSize(110, 20)
    popup.editbox:SetPoint("TOP", popup.label, "BOTTOM", 0, -6)
    popup.editbox:SetAutoFocus(true)
    popup.editbox:SetNumeric(true)
    local addButton
    local confirmBtn, cancelBtn
    -- Plain text, not Unicode tick/cross glyphs -- Blizzard's bundled fonts
    -- have sparse glyph coverage and render unsupported symbols as a tofu
    -- box (same reason the dropdown arrow elsewhere uses ASCII "v" instead
    -- of a Unicode triangle).
    confirmBtn = CreateStyledButton(popup, "Add", "accent-hover", {50, 20}, function()
        local id = tonumber(popup.editbox:GetText())
        popup.editbox:SetText("")
        popup:Hide()
        addButton:Show()
        if id and id > 0 then
            local auras = getAuras and getAuras() or {}
            tinsert(auras, id)
            if setAuras then setAuras(auras) end
            container.SetAuras(auras)
        end
    end)
    confirmBtn:SetPoint("BOTTOMLEFT", 8, 8)
    cancelBtn = CreateStyledButton(popup, "Cancel", "red-hover", {50, 20}, function()
        popup.editbox:SetText("")
        popup:Hide()
        addButton:Show()
    end)
    cancelBtn:SetPoint("BOTTOMRIGHT", -8, 8)
    popup.editbox:SetScript("OnEnterPressed", function() confirmBtn:Click() end)
    popup.editbox:SetScript("OnEscapePressed", function() cancelBtn:Click() end)

    -- singleSpellMode's menu popup: "Enter Spell ID" (falls through to the
    -- ID-entry popup above) followed by the player's healer spells, one
    -- click to add. Parented to UIParent with "TOOLTIP" strata and absolute
    -- screen coordinates (same pattern as CreateStyledDropdown's popup) so
    -- it isn't clipped by the settings pane's scrollable area. Created once
    -- and reused (rows rebuilt per open) since it needs a stable name to
    -- register with UISpecialFrames for Escape-to-close.
    auraSpellListMenuCounter = auraSpellListMenuCounter + 1
    local menuPopupName = "SquizzFramesAuraSpellListMenu" .. auraSpellListMenuCounter
    local menuPopup, menuCloser
    local menuRows = {}

    local function EnsureMenuPopup()
        if menuPopup then return end
        menuPopup = CreateFrame("Frame", menuPopupName, UIParent, "BackdropTemplate")
        menuPopup:SetFrameStrata("TOOLTIP")
        menuPopup:SetFrameLevel(100)
        menuPopup:Hide()
        StylizeFrame(menuPopup, {0.08, 0.08, 0.08, 0.98}, {0.4, 0.4, 0.4, 0.9})
        tinsert(UISpecialFrames, menuPopupName) -- Escape closes it

        -- Full-screen invisible catcher just below the popup -- closes it
        -- on any click outside, same pattern as CreateStyledDropdown's own
        -- "closer".
        menuCloser = CreateFrame("Button", nil, UIParent)
        menuCloser:SetFrameStrata("TOOLTIP")
        menuCloser:SetFrameLevel(99)
        menuCloser:SetAllPoints(UIParent)
        menuCloser:EnableMouse(true)
        menuCloser:Hide()
        menuCloser:SetScript("OnClick", function() menuPopup:Hide() end)

        -- Centralized cleanup on OnHide (not duplicated at every close site)
        -- -- Escape (via UISpecialFrames) hides menuPopup directly without
        -- running any of our own click handlers, so relying on the row/
        -- closer OnClick handlers alone to restore addButton/hide the
        -- closer would leave both stuck whenever the menu is closed via
        -- Escape specifically.
        menuPopup:SetScript("OnHide", function()
            menuCloser:Hide()
            addButton:Show()
        end)
    end

    local function CloseMenuPopup()
        if menuPopup then menuPopup:Hide() end
    end

    local function OpenMenuPopup()
        EnsureMenuPopup()
        for _, row in ipairs(menuRows) do row:Hide(); row:SetParent(nil) end
        wipe(menuRows)

        local choices = GetPlayerHealerSpellChoices()
        local rowHeight = 20
        local numRows = 1 + #choices -- "Enter Spell ID" + each healer spell

        local function AddRow(index, iconTexture, text, onClick)
            local row = CreateFrame("Button", nil, menuPopup, "BackdropTemplate")
            row:SetSize(182, rowHeight)
            row:SetPoint("TOP", 0, -4 - (index - 1) * rowHeight)
            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetAllPoints()
            row.bg:SetColorTexture(0, 0, 0, 0)
            row:SetScript("OnEnter", function() row.bg:SetColorTexture(accentColor.r, accentColor.g, accentColor.b, 0.35) end)
            row:SetScript("OnLeave", function() row.bg:SetColorTexture(0, 0, 0, 0) end)
            local xOff = 4
            if iconTexture then
                local tex = row:CreateTexture(nil, "ARTWORK")
                tex:SetSize(16, 16)
                tex:SetPoint("LEFT", 4, 0)
                tex:SetTexture(iconTexture)
                tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                xOff = 24
            end
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            fs:SetPoint("LEFT", xOff, 0)
            fs:SetPoint("RIGHT", -4, 0)
            fs:SetJustifyH("LEFT")
            fs:SetText(text)
            row:SetScript("OnClick", onClick)
            tinsert(menuRows, row)
            return row
        end

        AddRow(1, nil, "Enter Spell ID", function()
            CloseMenuPopup()
            addButton:Hide()
            popup.editbox:SetText("")
            popup:Show()
            popup.editbox:SetFocus()
        end)

        for i, id in ipairs(choices) do
            local spellName = F.GetSpellInfo and F.GetSpellInfo(id)
            local iconId = F.GetSpellIcon and F.GetSpellIcon(id)
            AddRow(1 + i, iconId, spellName or tostring(id), function()
                CloseMenuPopup()
                addButton:Show()
                local auras = getAuras and getAuras() or {}
                tinsert(auras, id)
                if setAuras then setAuras(auras) end
                container.SetAuras(auras)
            end)
        end

        menuPopup:SetSize(190, numRows * rowHeight + 8)
        menuPopup:ClearAllPoints()
        local left, top = addButton:GetLeft(), addButton:GetTop()
        if left and top and left > 0 and top > 0 then
            menuPopup:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, top + 2)
        else
            menuPopup:SetPoint("BOTTOM", addButton, "TOP", 0, 2)
        end
        menuPopup:Show()
        menuCloser:Show()
    end

    -- Hide the Add Spell button itself while a popup is open, rather than
    -- relying on the popup's opacity/coverage to occlude it -- the popup
    -- (170px, centered under the container) doesn't fully overlap Add Spell
    -- (anchored to the container's own BOTTOMRIGHT corner), so part of the
    -- button poked out past the popup's edge regardless of how opaque the
    -- popup's background was.
    addButton = CreateStyledButton(container, "Add Spell", "accent-hover", {100, 24}, function()
        if singleSpellMode then
            addButton:Hide()
            OpenMenuPopup()
            return
        end
        popup.editbox:SetText("")
        addButton:Hide()
        popup:Show()
        popup.editbox:SetFocus()
    end)
    addButton:SetPoint("BOTTOMRIGHT", -5, 3)

    -- Bulk-import the curated cross-class healer spell list (HoTs, shields,
    -- beacons -- see Defaults/Indicator_Defaults.lua's healerSpells, also
    -- used by /sfhealers) into whichever custom indicator this list belongs
    -- to, merging with (not replacing) whatever's already there. Doesn't
    -- make sense for every caller of this shared widget (e.g. External/
    -- Defensive Cooldowns' custom spell lists aren't healer spells), so
    -- callers that don't want it pass showHealerButton = false. Also never
    -- shown in singleSpellMode -- bulk-importing many spells contradicts a
    -- 1-spell cap.
    if showHealerButton ~= false and not singleSpellMode then
        local addHealersButton = CreateStyledButton(container, "Add Healer Spells", "accent-hover", {130, 24}, function()
            -- healerSpells is class-keyed (Defaults/Indicator_Defaults.lua) -- flatten it.
            local healerSpells = F.FlattenSpellTable(SquizzFrames.defaults and SquizzFrames.defaults.healerSpells or {})
            if #healerSpells == 0 then return end
            local auras = getAuras and getAuras() or {}
            local newAuras = {}
            local existing = {}
            for _, id in ipairs(auras) do
                tinsert(newAuras, id)
                existing[id] = true
            end
            for _, id in ipairs(healerSpells) do
                if not existing[id] then
                    tinsert(newAuras, id)
                    existing[id] = true
                end
            end
            if setAuras then setAuras(newAuras) end
            container.SetAuras(newAuras)
        end)
        addHealersButton:SetPoint("BOTTOMLEFT", 5, 3)
    end

    local rows = {}

    function container.SetAuras(auras)
        for _, row in ipairs(rows) do row:Hide() row:SetParent(nil) end
        wipe(rows)
        if not auras then return end

        local F_ns = SquizzFrames.F
        for i, id in ipairs(auras) do
            local row = CreateFrame("Frame", nil, scrollFrame.scrollChild, "BackdropTemplate")
            row:SetHeight(20)
            StylizeFrame(row, {0.08, 0.08, 0.08, 0.8}, {0.3, 0.3, 0.3, 0.5})
            if i == 1 then
                row:SetPoint("TOPLEFT", 0, 0)
            else
                row:SetPoint("TOPLEFT", rows[i-1], "BOTTOMLEFT", 0, -1)
            end
            row:SetPoint("RIGHT", scrollFrame.scrollChild, "RIGHT", 0, 0)

            local iconTex = row:CreateTexture(nil, "ARTWORK")
            iconTex:SetSize(16, 16)
            iconTex:SetPoint("LEFT", 2, 0)
            local iconId = F_ns.GetSpellIcon(id)
            if iconId then iconTex:SetTexture(iconId) end
            iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            local nameStr = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            nameStr:SetPoint("LEFT", iconTex, "RIGHT", 4, 0)
            nameStr:SetPoint("RIGHT", -24, 0)
            nameStr:SetJustifyH("LEFT")
            local spellName = F_ns.GetSpellInfo(id)
            nameStr:SetText(spellName and (spellName .. " (" .. id .. ")") or tostring(id))

            local deleteBtn = CreateFrame("Button", nil, row)
            deleteBtn:SetSize(16, 16)
            deleteBtn:SetPoint("RIGHT", -2, 0)
            deleteBtn:SetNormalFontObject("GameFontNormalSmall")
            deleteBtn:SetText("X")
            deleteBtn:SetScript("OnClick", function()
                local currentAuras = getAuras and getAuras() or {}
                local newAuras = {}
                for _, aid in ipairs(currentAuras) do
                    if aid ~= id then tinsert(newAuras, aid) end
                end
                if setAuras then setAuras(newAuras) end
                container.SetAuras(newAuras)
            end)

            rows[i] = row
        end
        scrollFrame:SetContentHeight(#auras, 20, 1)

        -- singleSpellMode cap: once a spell is tracked, hide Add Spell --
        -- delete (the X above) then re-add to swap it for a different one.
        if singleSpellMode then
            addButton:SetShown(#auras < 1)
        end
    end

    function container.GetAuras()
        return getAuras and getAuras() or {}
    end

    return container
end

-----------------------------------------------------------------------
-- CreatePreviewButton
-----------------------------------------------------------------------
-- A fake unit button for the Indicators options panel, with a "Preview" label,
-- Scale slider, and "Show All" checkbox.

local function CreatePreviewButton(parent)
    local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    container:SetSize(110, 80)
    StylizeFrame(container, {0.05, 0.05, 0.05, 0.9}, {0.4, 0.4, 0.4, 0.8})

    -- Title
    container.title = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    container.title:SetPoint("TOPLEFT", 5, -3)
    container.title:SetText("Preview")

    -- The fake unit button (built from the same template as real buttons).
    container.button = CreateFrame("Button", "SquizzIndicatorsPreview", container, "SquizzFramesUnitButtonTemplate")
    container.button:SetSize(100, 40)
    container.button:SetPoint("TOP", 0, -18)
    container.button.unit = "player"
    container.button.indicators = {}
    container.button.states = { displayedUnit = "player" }
    container.button._indicatorsReady = false

    -- Scale slider
    container.scaleSlider = CreateStyledSlider(container, 80, 0.5, 3, 0.1, "Scale",
        function() return 1 end,
        function(val) container.button:SetScale(val) end
    )
    container.scaleSlider:SetPoint("BOTTOMLEFT", 5, 3)

    -- Show All checkbox
    container.showAll = CreateStyledCheckbox(container, "Show All",
        function() return false end,
        function() end
    )
    container.showAll:SetPoint("BOTTOMRIGHT", -5, 5)

    return container
end

-----------------------------------------------------------------------
-- Public API
-----------------------------------------------------------------------

SquizzFrames.Widgets = {
    CreateStyledButton = CreateStyledButton,
    CreateStyledCheckbox = CreateStyledCheckbox,
    CreateStyledDropdown = CreateStyledDropdown,
    CreateStyledSlider = CreateStyledSlider,
    CreateStyledSwitch = CreateStyledSwitch,
    CreateTitledPane = CreateTitledPane,
    StylizeFrame = StylizeFrame,
    CreateScrollFrame = CreateScrollFrame,
    CreateBindingCapture = CreateBindingCapture,
    CreatePopupEditBox = CreatePopupEditBox,
    CreateBindingRow = CreateBindingRow,
    CreateMenu = CreateMenu,
    CreateColorPicker = CreateColorPicker,
    CreateIndicatorList = CreateIndicatorList,
    CreateAuraSpellList = CreateAuraSpellList,
    CreatePreviewButton = CreatePreviewButton,
}
