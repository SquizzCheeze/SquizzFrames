--[[ =========================================================================
    SquizzFrames ClickCastingPanel
    Cell-style click-casting options panel.

    Each binding row has three clickable cells: Key / Type / Action.
      * Key cell click   → small "Press Key to Bind" capture frame
                           anchored at the cell (Cell's bindingButton).
      * Type cell click  → dropdown menu (General / Spell / Macro / Item / Custom).
      * Action cell click→ type-appropriate dropdown (General submenu,
                           spell ID input, macro text, etc.).
      * Right-click row  → mark deleted (dims row; Save removes it).
    Bottom: New / Save / Cancel buttons with change tracking.
-------------------------------------------------------------------------- ]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F
local W = SquizzFrames.Widgets

-----------------------------------------------------------------------
-- State
-----------------------------------------------------------------------
local scrollFrame
local rowFrames = {}
local bindingButton   -- singleton key-capture frame (Cell's bindingButton)
local activeMenu      -- singleton dropdown menu frame
local activeMenuCloser

-- Change tracking
local deleted = {}
local changed = {}

local newBtn, saveBtn, cancelBtn
local RebuildList  -- forward declaration

-- Forward declarations for helpers used before their definition.
local CloseActiveMenu
local ShowSpellEditBox, ShowMacroEditBox, ShowItemEditBox

-----------------------------------------------------------------------
-- Constants
-----------------------------------------------------------------------
local BIND_TYPES = {"general", "spell", "macro", "item", "custom"}
local TYPE_LABELS = {
    general = "General", spell = "Spell", macro = "Macro",
    item = "Item", custom = "Custom",
}
local GENERAL_ACTIONS = {
    {value = "target", text = "Target"},
    {value = "focus",  text = "Focus"},
    {value = "assist", text = "Assist"},
    {value = "menu",   text = "Menu"},
}

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------
local function GetProfile()
    return SquizzFrames.db and SquizzFrames.db.profile
end

local function GetClickCasting()
    return SquizzFrames.modules and SquizzFrames.modules["ClickCasting"]
end

local function GetBindings()
    local prof = GetProfile()
    if not prof then return {} end
    if not prof.clickCasting then prof.clickCasting = {} end
    return prof.clickCasting
end

local function FormatBinding(b)
    local raw = b.modifier or ""
    -- Strip trailing dash then convert internal dashes to "+"
    local mod = raw:gsub("-$", ""):gsub("-", "+")
    -- Guard: if nothing left after stripping (e.g. bare "+" or ""), show no prefix
    if mod == "" or mod == "+" then mod = "" end
    return (mod ~= "" and (mod .. "+") or "") .. (b.bindKey or "?")
end

local function FormatAction(b)
    local t, a = b.type, b.action
    if t == "general" then
        -- General actions display their human-readable name.
        for _, ga in ipairs(GENERAL_ACTIONS) do
            if ga.value == a then return ga.text end
        end
        return a and tostring(a) or ""
    elseif t == "spell" then
        local id = tonumber(a)
        return id and (F.GetSpellInfo(id) or ("Spell " .. id)) or (a or "")
    elseif t == "item" then
        return type(a) == "number" and ("Item " .. a) or tostring(a or "")
    elseif t == "macro" or t == "custom" then
        local s = tostring(a or "")
        return (#s > 32) and (s:sub(1, 29) .. "...") or s
    else
        return ""
    end
end

local function TypeLabel(t)
    return TYPE_LABELS[t] or (t and t:gsub("^%l", string.upper)) or "?"
end

local function ReadModifier()
    local m = ""
    if IsAltKeyDown() then m = m .. "alt-" end
    if IsControlKeyDown() then m = m .. "ctrl-" end
    if IsShiftKeyDown() then m = m .. "shift-" end
    return m
end

-- Map raw mouse button names to our bind key names.
local BTN_MAP = {
    LeftButton = "Left", RightButton = "Right", MiddleButton = "Middle",
    Button4 = "Button4", Button5 = "Button5",
}

-----------------------------------------------------------------------
-- Change tracking
-----------------------------------------------------------------------
local function HasChanges()
    for _ in pairs(deleted) do return true end
    for _ in pairs(changed) do return true end
    return false
end

local function UpdateButtons()
    local any = HasChanges()
    if saveBtn then saveBtn:SetEnabled(any) end
    if cancelBtn then cancelBtn:SetEnabled(any) end
end

local function MarkChanged(idx)
    changed[idx] = true
    UpdateButtons()
end

local function MarkDeleted(idx)
    deleted[idx] = true
    UpdateButtons()
end

local function ClearChanges()
    wipe(deleted)
    wipe(changed)
end

-----------------------------------------------------------------------
-- New / Save / Cancel
-----------------------------------------------------------------------
local function OnNew()
    local bindings = GetBindings()
    tinsert(bindings, {bindKey = "Left", modifier = "", type = "spell", action = ""})
    ClearChanges()
    MarkChanged(#bindings)
    RebuildList()
    if scrollFrame then scrollFrame:ScrollToBottom() end
end

local function OnSave()
    local bindings = GetBindings()
    local toDelete = {}
    for idx in pairs(deleted) do tinsert(toDelete, idx) end
    table.sort(toDelete, function(a, b) return a > b end)
    for _, idx in ipairs(toDelete) do
        if bindings[idx] then tremove(bindings, idx) end
    end
    ClearChanges()
    RebuildList()
    local cc = GetClickCasting()
    if cc and cc.ApplyToAll then cc:ApplyToAll() end
end

local function OnCancel()
    ClearChanges()
    RebuildList()
end

-----------------------------------------------------------------------
-- Key-capture (Cell's bindingButton) — a small frame positioned at the
-- keyGrid, NOT a fullscreen overlay. Text changes to "Press Key to Bind".
-----------------------------------------------------------------------
local function EnsureBindingButton()
    if bindingButton then return bindingButton end
    local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    f:SetFrameStrata("TOOLTIP")
    f:SetSize(160, 24)
    f:Hide()
    W.StylizeFrame(f, {0.1, 0.1, 0.1, 1}, {0.6, 0.4, 0.1, 1})
    f:EnableMouse(true)
    f:EnableMouseWheel(true)
    f:EnableKeyboard(true)

    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.text:SetPoint("LEFT", 6, 0)
    f.text:SetPoint("RIGHT", -6, 0)
    f.text:SetJustifyH("LEFT")
    f.text:SetText("Press Key to Bind")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetSize(16, 16)
    closeBtn:SetPoint("TOPRIGHT", -2, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    f.func = nil
    f:SetScript("OnHide", function() f:Hide() end)

    f:SetScript("OnMouseDown", function(_, btn)
        local key = BTN_MAP[btn]
        if key then
            f:Hide()
            if f.func then f.func(ReadModifier(), key) end
        end
    end)
    f:SetScript("OnMouseWheel", function(_, delta)
        local key = delta > 0 and "ScrollUp" or "ScrollDown"
        f:Hide()
        if f.func then f.func(ReadModifier(), key) end
    end)
    f:SetScript("OnKeyDown", function(_, key)
        if key == "ESCAPE" then f:Hide(); return end
        if key == "LALT" or key == "RALT" then return end
        if key == "LCTRL" or key == "RCTRL" then return end
        if key == "LSHIFT" or key == "RSHIFT" then return end
        f:Hide()
        if f.func then f.func(ReadModifier(), key) end
    end)

    function f:SetFunc(fn) f.func = fn end
    bindingButton = f
    return f
end

-- Whether we've told the user (once per session) why rebinding in combat
-- behaves differently -- see ShowBindingButton.
local warnedCombatCapture = false

local function ShowBindingButton(anchor, callback)
    local bb = EnsureBindingButton()
    -- Reparent to the anchor cell so the button moves with it (scroll, etc.)
    bb:SetParent(anchor)
    bb:ClearAllPoints()
    bb:SetAllPoints(anchor)
    bb:SetFunc(callback)
    bb.text:SetText("Press Key to Bind")
    bb:Show()

    -- SetPropagateKeyboardInput is PROTECTED in combat (live ADDON_ACTION_
    -- BLOCKED report, 2026-08-08: a user rebound a key mid-fight and got
    -- "tried to call the protected function 'Frame:SetPropagateKeyboardInput()'").
    -- It was previously called unconditionally here.
    --
    -- Suppressing propagation is what stops the captured key ALSO firing its
    -- normal action -- press "3" to bind it and you'd otherwise cast spell 3
    -- as well. Capture itself doesn't depend on it (EnableKeyboard + OnKeyDown
    -- do that work), so combat only degrades this, it doesn't break it: the
    -- binding is still recorded correctly, which matches the reporting user's
    -- "everything with click casting was working fine afterwards".
    --
    -- Re-applied on every show rather than once at creation: the frame is a
    -- reused singleton, and if it was first shown during combat the flag never
    -- got set at all, so a later out-of-combat capture has to fix it up.
    if not InCombatLockdown() then
        bb:SetPropagateKeyboardInput(false)
    elseif not warnedCombatCapture then
        warnedCombatCapture = true
        print("|cff33cc99[SquizzFrames]|r Rebinding during combat: the key you press will also trigger its normal action. The binding itself still saves correctly.")
    end
    -- Hide any open menu.
    CloseActiveMenu()
end

-----------------------------------------------------------------------
-- Dropdown menu (Cell's menu) — a single reusable popup.
-----------------------------------------------------------------------
CloseActiveMenu = function()
    if activeMenu then activeMenu:Hide(); activeMenu = nil end
    if activeMenuCloser then activeMenuCloser:Hide(); activeMenuCloser = nil end
end

local function ShowMenu(anchor, items, width)
    CloseActiveMenu()
    width = width or 140
    local m = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    m:SetFrameStrata("TOOLTIP")
    m:SetToplevel(true)
    W.StylizeFrame(m, {0.08, 0.08, 0.08, 1}, {0, 0, 0, 1})

    local rowH = 20
    for i, it in ipairs(items) do
        local row = CreateFrame("Button", nil, m)
        row:SetHeight(rowH)
        row:SetPoint("TOPLEFT", m, "TOPLEFT", 1, -((i - 1) * rowH + 1))
        row:SetPoint("TOPRIGHT", m, "TOPRIGHT", -1, -((i - 1) * rowH + 1))
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
            CloseActiveMenu()
            if it.onClick then it.onClick() end
        end)
    end
    m:SetSize(width, math.max(rowH, #items * rowH + 2))
    m:ClearAllPoints()
    m:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    m:Show()
    activeMenu = m

    -- Full-screen closer to dismiss on outside click.
    local closer = CreateFrame("Button", nil, UIParent)
    closer:SetFrameStrata("TOOLTIP")
    closer:SetFrameLevel(m:GetFrameLevel() - 1)
    closer:SetAllPoints(UIParent)
    closer:SetScript("OnClick", function() CloseActiveMenu() end)
    closer:Show()
    activeMenuCloser = closer
end

-- Scrollable dropdown menu for long lists (spells / items). Same look as
-- ShowMenu but capped to maxRows with a scrollbar.
local function ShowScrollMenu(anchor, items, width, maxRows)
    CloseActiveMenu()
    width = width or 200
    maxRows = maxRows or 16
    local rowH = 20
    local visible = math.min(#items, maxRows)

    local m = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    m:SetFrameStrata("TOOLTIP")
    m:SetToplevel(true)
    W.StylizeFrame(m, {0.08, 0.08, 0.08, 1}, {0, 0, 0, 1})

    -- Build a scrollframe + content if the list is long; otherwise plain.
    local content
    if #items <= maxRows then
        content = m
    else
        local sf = CreateFrame("ScrollFrame", nil, m, "UIPanelScrollFrameTemplate")
        sf:SetAllPoints()
        content = CreateFrame("Frame", nil, sf)
        content:SetWidth(width)
        sf:SetScrollChild(content)
        m.scrollChild = content
        m.scrollFrame = sf
    end

    for i, it in ipairs(items) do
        local row = CreateFrame("Button", nil, content)
        row:SetHeight(rowH)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 1, -((i - 1) * rowH + 1))
        row:SetPoint("TOPRIGHT", content, "TOPRIGHT", -1, -((i - 1) * rowH + 1))
        -- Optional icon shown to the left of the text (used for spells).
        local textLeft = 8
        if it.icon then
            local icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetSize(rowH - 4, rowH - 4)
            icon:SetPoint("LEFT", 4, 0)
            icon:SetTexture(it.icon)
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            textLeft = 8 + (rowH - 4)
        end
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", textLeft, 0)
        row.text:SetPoint("RIGHT", -8, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetText(it.text or "")
        local hl = row:CreateTexture(nil, "BACKGROUND")
        hl:SetAllPoints()
        hl:SetColorTexture(0.3, 0.2, 0.1, 0.5)
        hl:Hide()
        row:SetScript("OnEnter", function() hl:Show() end)
        row:SetScript("OnLeave", function() hl:Hide() end)
        row:SetScript("OnClick", function()
            CloseActiveMenu()
            if it.onClick then it.onClick() end
        end)
    end

    local totalH = #items * rowH + 2
    content:SetHeight(totalH)
    m:SetSize(width, rowH * visible + 2)
    m:ClearAllPoints()
    m:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    m:Show()
    activeMenu = m

    local closer = CreateFrame("Button", nil, UIParent)
    closer:SetFrameStrata("TOOLTIP")
    closer:SetFrameLevel(m:GetFrameLevel() - 1)
    closer:SetAllPoints(UIParent)
    closer:SetScript("OnClick", function() CloseActiveMenu() end)
    closer:Show()
    activeMenuCloser = closer
end

-----------------------------------------------------------------------
-- Cell-click handlers
-----------------------------------------------------------------------
local function OnKeyClick(row)
    local idx = row.clickCastingIndex
    local bindings = GetBindings()
    local b = bindings[idx]
    if not b then return end
    -- Change the keyGrid text while capturing (Cell puts "Press Key to Bind"
    -- on the bindingButton which is positioned over the keyGrid).
    ShowBindingButton(row.keyGrid, function(modifier, key)
        b.modifier = modifier or ""
        b.bindKey = key
        row.keyGrid:SetText(FormatBinding(b))
        row:SetChanged(true)
        MarkChanged(idx)
    end)
end

local function OnTypeClick(row)
    local idx = row.clickCastingIndex
    local bindings = GetBindings()
    local b = bindings[idx]
    if not b then return end
    local items = {}
    for _, t in ipairs(BIND_TYPES) do
        local value = t
        tinsert(items, {
            text = TYPE_LABELS[t] or t,
            onClick = function()
                b.type = value
                b.action = nil
                row.typeGrid:SetText(TypeLabel(value))
                row.actionGrid:SetText(FormatAction(b))
                row:SetChanged(true)
                MarkChanged(idx)
            end,
        })
    end
    ShowMenu(row.typeGrid, items, 100)
end

local function OnActionClick(row)
    local idx = row.clickCastingIndex
    local bindings = GetBindings()
    local b = bindings[idx]
    if not b then return end
    local t = b.type

    if t == "general" then
        local items = {}
        for _, ga in ipairs(GENERAL_ACTIONS) do
            local value = ga.value
            tinsert(items, {
                text = ga.text,
                onClick = function()
                    b.action = value
                    row.actionGrid:SetText(ga.text)
                    row:SetChanged(true)
                    MarkChanged(idx)
                end,
            })
        end
        ShowMenu(row.actionGrid, items, 130)
    elseif t == "spell" then
        -- Spell menu: prepopulate with the class/spec spell list (the same
        -- curated list Cell shows). Manual ID entry at top.
        local items = {}
        tinsert(items, {
            text = "|cffffd100Edit Spell ID...|r",
            onClick = function()
                ShowSpellEditBox(row.actionGrid, b, idx, row)
            end,
        })
        local spells = F.GetClickCastingSpellsList()
        for _, sp in ipairs(spells) do
            local name, id = sp.name, sp.id
            tinsert(items, {
                text = name,
                icon = F.GetSpellIcon(id),
                onClick = function()
                    b.action = id
                    row.actionGrid:SetText(name)
                    row:SetChanged(true)
                    MarkChanged(idx)
                end,
            })
        end
        ShowScrollMenu(row.actionGrid, items, 280, 18)
    elseif t == "macro" or t == "custom" then
        local items = {}
        tinsert(items, {
            text = "Edit Macro Text...",
            onClick = function()
                ShowMacroEditBox(row.actionGrid, b, idx, row)
            end,
        })
        ShowMenu(row.actionGrid, items, 160)
    elseif t == "item" then
        -- Item menu: prepopulate with equipped usable items, like Cell.
        -- Manual ID entry at top for items you don't currently have equipped.
        local items = {}
        tinsert(items, {
            text = "|cffffd100Edit Item ID...|r",
            onClick = function()
                ShowItemEditBox(row.actionGrid, b, idx, row)
            end,
        })
        local equipped = F.GetClickCastingItemsFromCell()
        for _, it in ipairs(equipped) do
            local name, id = it.name, it.id
            tinsert(items, {
                text = name,
                onClick = function()
                    b.action = id
                    row.actionGrid:SetText(name)
                    row:SetChanged(true)
                    MarkChanged(idx)
                end,
            })
        end
        ShowScrollMenu(row.actionGrid, items, 240, 18)
    else
        -- Fallback: generic action menu for unknown types
        local items = {}
        tinsert(items, {
            text = "Edit...",
            onClick = function()
                ShowMacroEditBox(row.actionGrid, b, idx, row)
            end,
        })
        ShowMenu(row.actionGrid, items, 130)
    end
end

-----------------------------------------------------------------------
-- In-place edit boxes (for spell ID, macro text, item ID)
-- A small EditBox positioned over the actionGrid.
-----------------------------------------------------------------------
local function ShowEditBoxOver(anchor, initialText, onCommit)
    CloseActiveMenu()
    -- EditBox doesn't inherit BackdropTemplate directly; wrap in a backdrop.
    local wrapper = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    wrapper:SetFrameStrata("TOOLTIP")
    wrapper:ClearAllPoints()
    wrapper:SetPoint("TOPLEFT", anchor, "TOPLEFT")
    wrapper:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT")
    W.StylizeFrame(wrapper, {0.1, 0.1, 0.1, 1}, {0.6, 0.4, 0.1, 1})

    local box = CreateFrame("EditBox", nil, wrapper)
    box:SetAutoFocus(true)
    box:SetFontObject(GameFontHighlight)
    box:SetMultiLine(false)
    box:SetAllPoints(wrapper)
    box:SetTextInsets(6, 6, 0, 0)
    box:SetTextColor(1, 1, 1, 1)
    box:SetText(initialText or "")
    box:Show()
    box:HighlightText()
    box:SetFocus()

    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus(); wrapper:Hide()
    end)
    box:SetScript("OnEnterPressed", function(self)
        local text = self:GetText() or ""
        self:ClearFocus(); wrapper:Hide()
        onCommit(text)
    end)
    box:SetScript("OnEditFocusLost", function()
        wrapper:Hide()
    end)
end

function ShowSpellEditBox(anchor, b, idx, row)
    ShowEditBoxOver(anchor, tostring(b.action or ""), function(text)
        b.action = tonumber(text) or text
        local id = tonumber(b.action)
        row.actionGrid:SetText(id and (F.GetSpellInfo(id) or tostring(b.action)) or (b.action or ""))
        row:SetChanged(true)
        MarkChanged(idx)
    end)
end

function ShowMacroEditBox(anchor, b, idx, row)
    ShowEditBoxOver(anchor, tostring(b.action or ""), function(text)
        b.action = text
        row.actionGrid:SetText(FormatAction(b))
        row:SetChanged(true)
        MarkChanged(idx)
    end)
end

function ShowItemEditBox(anchor, b, idx, row)
    ShowEditBoxOver(anchor, tostring(b.action or ""), function(text)
        b.action = tonumber(text) or text
        row.actionGrid:SetText(FormatAction(b))
        row:SetChanged(true)
        MarkChanged(idx)
    end)
end

-----------------------------------------------------------------------
-- Rebuild the list of binding rows
-----------------------------------------------------------------------
RebuildList = function()
    if not scrollFrame then return end

    -- Hide existing rows.
    for _, r in ipairs(rowFrames) do r:Hide(); r:SetParent(nil) end
    wipe(rowFrames)

    -- Close any open menu or capture frame.
    CloseActiveMenu()
    if bindingButton then bindingButton:Hide() end

    local bindings = GetBindings()
    local idx = 0
    local rowWidth = scrollFrame:GetWidth() - 12
    if rowWidth < 100 then rowWidth = 300 end

    for origIndex, b in ipairs(bindings) do
        if not deleted[origIndex] then
            idx = idx + 1
            local row = W.CreateBindingRow(scrollFrame.scrollChild, rowWidth,
                -- onRightClick: arg `r` is the row frame
                function(r)
                    MarkDeleted(r.clickCastingIndex)
                    r:SetAlpha(0.3)
                end,
                -- onDragReorder
                nil,
                -- onKeyClick: arg is the cell, but we want the row.
                nil,
                nil,
                nil)
            row.clickCastingIndex = origIndex
            row:SetPoint("TOPLEFT", 0, -(idx - 1) * 30)
            row:SetPoint("TOPRIGHT", 0, -(idx - 1) * 30)

            -- Wire cell clicks now that row is assigned.
            -- Left-click edits the cell; right-click marks the row for deletion.
            row.keyGrid:SetScript("OnClick", function(_, btn)
                if btn == "RightButton" then
                    MarkDeleted(row.clickCastingIndex)
                    row:SetAlpha(0.3)
                else
                    OnKeyClick(row)
                end
            end)
            row.typeGrid:SetScript("OnClick", function(_, btn)
                if btn == "RightButton" then
                    MarkDeleted(row.clickCastingIndex)
                    row:SetAlpha(0.3)
                else
                    OnTypeClick(row)
                end
            end)
            row.actionGrid:SetScript("OnClick", function(_, btn)
                if btn == "RightButton" then
                    MarkDeleted(row.clickCastingIndex)
                    row:SetAlpha(0.3)
                else
                    OnActionClick(row)
                end
            end)

            row.keyGrid:SetText(FormatBinding(b))
            row.typeGrid:SetText(TypeLabel(b.type))
            row.actionGrid:SetText(FormatAction(b))
            row:SetChanged(changed[origIndex] and true or false)
            row:Show()
            tinsert(rowFrames, row)
        end
    end

    scrollFrame:SetContentHeight(idx)
    UpdateButtons()
end

-----------------------------------------------------------------------
-- Build the full panel
-----------------------------------------------------------------------
local function Build(parent)
    ClearChanges()

    -- Heading
    local heading = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    heading:SetPoint("TOPLEFT", 16, -16)
    heading:SetText("Click-Cast Bindings")

    local sub = parent:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    sub:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -4)
    sub:SetText("Left-click a cell to edit, right-click a row to delete.")

    -- Top dropdowns
    local topY = -56
    local targetingLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    targetingLabel:SetPoint("TOPLEFT", 16, topY)
    targetingLabel:SetText("Always Targeting")
    local targetingItems = {
        {value = "disabled", text = "Disabled"},
        {value = "left",     text = "Any Left Click"},
        {value = "any",      text = "Any Click"},
    }
    local targetingSel = "disabled"
    local targetingDD = W.CreateStyledDropdown(parent, 150, 22, "", targetingItems, function()
        return targetingSel
    end, function(val)
        targetingSel = val
    end)
    targetingDD:SetPoint("TOPLEFT", targetingLabel, "BOTTOMLEFT", 0, -2)

    local smartLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    smartLabel:SetPoint("LEFT", targetingDD, "RIGHT", 24, 14)
    smartLabel:SetText("Smart Resurrection")
    local smartItems = {
        {value = "disabled",     text = "Disabled"},
        {value = "normal",       text = "Normal"},
        {value = "combat",       text = "Combat"},
        {value = "normalcombat", text = "Normal + Combat"},
    }
    -- Read/write straight from the profile (not a cached local) so this
    -- stays correct across profile switches -- the tab is only Build() once
    -- but re-shown many times (see RebuildClickCasting in OptionsFrame.lua).
    local smartDD = W.CreateStyledDropdown(parent, 150, 22, "", smartItems, function()
        local prof = GetProfile()
        return (prof and prof.smartResurrection) or "disabled"
    end, function(val)
        local prof = GetProfile()
        if prof then prof.smartResurrection = val end
        local cc = GetClickCasting()
        if cc and cc.ApplyToAll then cc:ApplyToAll() end
    end)
    smartDD:SetPoint("TOPLEFT", smartLabel, "BOTTOMLEFT", 0, -2)

    -- Extends the bindings above onto unit frames SquizzFrames doesn't own --
    -- Blizzard's (boss/target/player/focus/pet) and EllesmereUI's. That's the
    -- only way to click-cast a unit with no SquizzFrames frame, dungeon and
    -- raid bosses most of all. Read/written straight from the profile for the
    -- same reason the dropdowns above are (this tab is built once and re-shown
    -- across profile switches).
    local blizzCB = W.CreateStyledCheckbox(parent, "Other addons' frames (Blizzard, EllesmereUI)",
        function()
            local prof = GetProfile()
            return not prof or prof.clickCastBlizzardFrames ~= false
        end,
        function(checked)
            local prof = GetProfile()
            if prof then prof.clickCastBlizzardFrames = checked end
            local cc = GetClickCasting()
            -- Turning it OFF can't retroactively strip attributes we already
            -- wrote (that needs a reload), so ApplyToAll only makes the ON
            -- direction take effect immediately -- see the note in the
            -- changelog.
            if cc and cc.ApplyToAll then cc:ApplyToAll() end
        end)
    blizzCB:SetPoint("LEFT", smartDD, "RIGHT", 24, 0)

    -- Bindings list pane
    local listTop = topY - 60
    W.CreateTitledPane(parent, "Current Profile", listTop)

    local listFrame = CreateFrame("Frame", nil, parent)
    listFrame:SetPoint("TOPLEFT", 12, listTop - 24)
    listFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -24, 48)

    -- Column headers
    local headerY = 0
    local keyH = listFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    keyH:SetPoint("TOPLEFT", 8, headerY)
    keyH:SetWidth(130)
    keyH:SetText("Key")
    local typeH = listFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    typeH:SetPoint("LEFT", keyH, "RIGHT", 6, 0)
    typeH:SetWidth(70)
    typeH:SetText("Type")
    local actionH = listFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    actionH:SetPoint("LEFT", typeH, "RIGHT", 6, 0)
    actionH:SetPoint("RIGHT", -12, 0)
    actionH:SetJustifyH("LEFT")
    actionH:SetText("Action")

    local divider = listFrame:CreateTexture(nil, "BACKGROUND")
    divider:SetPoint("TOPLEFT", 4, headerY - 14)
    divider:SetPoint("TOPRIGHT", -4, headerY - 14)
    divider:SetHeight(1)
    divider:SetColorTexture(1, 1, 1, 0.2)

    -- Scroll frame for binding rows.
    scrollFrame = W.CreateScrollFrame(listFrame)
    scrollFrame:SetPoint("TOPLEFT", 0, headerY - 18)
    scrollFrame:SetPoint("BOTTOMRIGHT", 0, 0)

    -- Bottom button bar
    local btnBar = CreateFrame("Frame", nil, parent)
    btnBar:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
    btnBar:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    btnBar:SetHeight(40)
    btnBar:SetFrameLevel(parent:GetFrameLevel() + 5)

    local function MakeBtn(text, style, w, onClick)
        local btn = W.CreateStyledButton(btnBar, text, style, {w, 26}, onClick)
        btn:EnableMouse(true)
        btn:SetFrameLevel(btnBar:GetFrameLevel() + 1)
        return btn
    end

    newBtn = MakeBtn("New", "accent", 80, OnNew)
    newBtn:SetPoint("BOTTOMLEFT", btnBar, "BOTTOMLEFT", 16, 8)
    saveBtn = MakeBtn("Save", "green", 80, OnSave)
    saveBtn:SetPoint("LEFT", newBtn, "RIGHT", 8, 0)
    cancelBtn = MakeBtn("Cancel", "red", 80, OnCancel)
    cancelBtn:SetPoint("LEFT", saveBtn, "RIGHT", 8, 0)

    RebuildList()
    parent.RebuildClickCasting = RebuildList

    -- Re-sync the binding list whenever the active profile changes (switch/
    -- copy/reset) even if this tab is already the one showing -- OptionsFrame
    -- .lua's ShowPage already rebuilds on NAVIGATING to this tab, but that
    -- doesn't help if a profile copy happens while already parked here.
    -- Own message owner -- see F.NewMessageOwner in Utils.lua (registering
    -- on the shared SquizzFrames root collided with five other sites).
    SquizzFrames.F.NewMessageOwner():RegisterMessage("ProfileChanged", function() RebuildList() end)
end

SquizzFrames.ClickCastingPanel = {
    Build = Build,
    Rebuild = RebuildList,
}
