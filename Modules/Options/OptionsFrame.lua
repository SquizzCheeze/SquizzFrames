--[[ SquizzFrames OptionsFrame.lua - Custom Options Panel ]]
--
-- Sidebar-navigation shell (app-style): a resizable window with a left-hand
-- section list (General / Layout / Appearance / Click Casting / Indicators).
--
-- Simple pages (General/Layout/Appearance/Click Casting) render into a
-- shared scrolling content area. Indicators takes over the full content area
-- directly (IndicatorsPanel.lua manages its own internal preview/list/
-- settings layout and needs the real estate) -- it's a single page (list +
-- settings + a Built-in/Custom switch + a live preview, all in one place),
-- not split across sidebar sub-pages.

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F
local L = SquizzFrames.L
local W = SquizzFrames.Widgets

-- Frame references
local optionsFrame
local sidebarFrame
local contentArea
local scrollFrame, scrollBar, scrollChild -- shared scroll for simple pages
local indicatorsHost -- full-area host frame for Indicators pages
local contentFrames = {}   -- pageId -> content frame
local growthDirDropdown   -- dropdown widget (container) for growth direction
local currentPageId       -- currently shown pageId (functions can't hold fields)
-- Which layout sub-table the Layout page's widgets currently read/write:
-- "main" (Party) or "raid" (Raid). Independent of the player's REAL current
-- group state -- lets raid layout be configured without being in a raid.
local activeLayoutKey = "main"
local rebuildLayoutFields -- forward declaration; set by CreateLayoutPage

-- Sidebar navigation model.
-- Appearance was merged into Layout (layout and appearance settings go
-- hand in hand) -- see BuildLayoutFields' "Appearance" section.
local NAV_ITEMS = {
    {id = "general",      label = "General"},
    {id = "layout",       label = "Layout"},
    {id = "petFrames",    label = "Pet Frames"},
    {id = "clickCasting", label = "Click Casting"},
    {id = "indicators",   label = "Indicators"},
    {id = "nicknames",    label = "Nicknames"},
    {id = "profiles",     label = "Profiles"},
}

-- Fixed content heights per simple page (content can exceed; scrolls if
-- needed). Indicators pages manage their own layout and aren't part of this.
local pageHeights = {
    ["general"] = 250,
    ["layout"] = 1265, -- +115 for the Copy Between Modes section
    ["petFrames"] = 1090, -- +490 for the Name Text section
    ["clickCasting"] = 460,
    ["nicknames"] = 780,
    ["profiles"] = 600,
}

local ShowPage -- forward declaration (sidebar row handlers close over this)

-----------------------------------------------------------------------
-- Profile accessors
-----------------------------------------------------------------------

local function GetProfile()
    return SquizzFrames.db and SquizzFrames.db.profile
end

-----------------------------------------------------------------------
-- Sidebar
-----------------------------------------------------------------------

local SIDEBAR_WIDTH = 150
local ROW_HEIGHT = 24

local sidebarRows = {}       -- pageId -> row button

local function HighlightRow(selectedId)
    local accent = F.GetAccentColor()
    for id, row in pairs(sidebarRows) do
        if id == selectedId then
            row.isSelected = true
            row:SetBackdropColor(accent.r, accent.g, accent.b, 0.55)
        else
            -- isSelected must be cleared here too, not just set on the match:
            -- CreateSidebarRow's OnEnter/OnLeave check it to decide whether to
            -- preserve the selected color through a hover, and it was never
            -- being set at all before, so every row silently reverted to the
            -- default color the instant the mouse passed over ANY row.
            row.isSelected = false
            row:SetBackdropColor(0.115, 0.115, 0.115, 1)
        end
    end
end

local function LayoutSidebarRows()
    local y = -6
    for _, item in ipairs(NAV_ITEMS) do
        local row = sidebarRows[item.id]
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", sidebarFrame, "TOPLEFT", 4, y)
        row:SetPoint("TOPRIGHT", sidebarFrame, "TOPRIGHT", -4, y)
        row:Show()
        y = y - ROW_HEIGHT - 2
    end
end

local function CreateSidebarRow(parent, label, onClick)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetHeight(ROW_HEIGHT)
    W.StylizeFrame(row, {0.115, 0.115, 0.115, 1}, {0, 0, 0, 0})

    local text = row:CreateFontString(nil, "OVERLAY")
    text:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    text:SetPoint("LEFT", 8, 0)
    text:SetText(label)
    row.fontString = text

    row:SetScript("OnClick", onClick)
    row:SetScript("OnEnter", function(self)
        if self.isSelected then return end
        self:SetBackdropColor(0.2, 0.17, 0.08, 1)
    end)
    row:SetScript("OnLeave", function(self)
        if self.isSelected then return end
        self:SetBackdropColor(0.115, 0.115, 0.115, 1)
    end)
    return row
end

local function CreateSidebar()
    sidebarFrame = CreateFrame("Frame", nil, optionsFrame, "BackdropTemplate")
    sidebarFrame:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 0, -26)
    sidebarFrame:SetPoint("BOTTOMLEFT", optionsFrame, "BOTTOMLEFT", 0, 0)
    sidebarFrame:SetWidth(SIDEBAR_WIDTH)
    W.StylizeFrame(sidebarFrame, {0.08, 0.08, 0.08, 1}, {0, 0, 0, 1})

    for _, item in ipairs(NAV_ITEMS) do
        local row = CreateSidebarRow(sidebarFrame, item.label, function()
            ShowPage(item.id)
        end)
        sidebarRows[item.id] = row
    end

    LayoutSidebarRows()
end

-----------------------------------------------------------------------
-- Create the main options frame
-----------------------------------------------------------------------

local DEFAULT_WIDTH, DEFAULT_HEIGHT = 820, 560
local MIN_WIDTH, MIN_HEIGHT = 700, 480
local MAX_WIDTH, MAX_HEIGHT = 1100, 800

local function CreateOptionsFrame()
    if optionsFrame then return optionsFrame end

    optionsFrame = CreateFrame("Frame", "SquizzFramesOptionsFrame", UIParent, "BackdropTemplate")
    optionsFrame:SetSize(DEFAULT_WIDTH, DEFAULT_HEIGHT)
    optionsFrame:SetPoint("CENTER", 0, 0)
    optionsFrame:SetFrameStrata("DIALOG")
    optionsFrame:SetFrameLevel(520)
    optionsFrame:SetClampedToScreen(true)
    optionsFrame:SetMovable(true)
    optionsFrame:SetResizable(true)
    if optionsFrame.SetResizeBounds then
        optionsFrame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT)
    else
        -- Fallback for API surfaces without SetResizeBounds.
        optionsFrame:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
        optionsFrame:SetMaxResize(MAX_WIDTH, MAX_HEIGHT)
    end
    optionsFrame:EnableMouse(true)
    optionsFrame:SetToplevel(true)
    optionsFrame:Hide()

    -- Closing the panel should always drop any preview left showing.
    --
    -- The group preview window handles itself (GroupPreview.lua hooks this
    -- same OnHide). This remains only for PartyFrames' older in-world preview,
    -- which the Layout tab no longer opens -- it's unreachable from this panel
    -- now, but the API is still public, so dropping it here stays correct if
    -- anything else ever turns it on.
    optionsFrame:SetScript("OnHide", function()
        local partyModule = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
        if partyModule and partyModule.IsPreviewActive and partyModule:IsPreviewActive() then
            partyModule:SetPreviewMode(false)
        end
    end)

    W.StylizeFrame(optionsFrame, {0.1, 0.1, 0.1, 0.9}, {0, 0, 0, 1})

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, optionsFrame)
    titleBar:SetPoint("TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", 0, 0)
    titleBar:SetHeight(26)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() optionsFrame:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() optionsFrame:StopMovingOrSizing() end)

    local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
    titleBg:SetAllPoints()
    titleBg:SetColorTexture(0.115, 0.115, 0.115, 1)

    local titleText = titleBar:CreateFontString(nil, "OVERLAY")
    titleText:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
    titleText:SetPoint("LEFT", 10, 0)
    titleText:SetTextColor(1, 1, 1, 1)
    titleText:SetText("SquizzFrames")

    local accent = F.GetAccentColor()
    local accentLine = titleBar:CreateTexture(nil, "BACKGROUND")
    accentLine:SetPoint("BOTTOMLEFT", 0, 0)
    accentLine:SetPoint("BOTTOMRIGHT", 0, 0)
    accentLine:SetHeight(1)
    accentLine:SetColorTexture(accent.r, accent.g, accent.b, 0.5)

    local closeBtn = W.CreateStyledButton(titleBar, "X", "red", {20, 20}, function()
        optionsFrame:Hide()
    end)
    closeBtn:SetPoint("TOPRIGHT", 0, 0)

    -- Resize grip (bottom-right corner)
    local resizeGrip = CreateFrame("Button", nil, optionsFrame)
    resizeGrip:SetSize(16, 16)
    resizeGrip:SetPoint("BOTTOMRIGHT", -2, 2)
    resizeGrip:SetNormalTexture([[Interface\ChatFrame\UI-ChatIM-SizeGrabber-Up]])
    resizeGrip:SetHighlightTexture([[Interface\ChatFrame\UI-ChatIM-SizeGrabber-Highlight]])
    resizeGrip:SetPushedTexture([[Interface\ChatFrame\UI-ChatIM-SizeGrabber-Down]])
    resizeGrip:SetScript("OnMouseDown", function()
        optionsFrame:StartSizing("BOTTOMRIGHT")
    end)
    resizeGrip:SetScript("OnMouseUp", function()
        optionsFrame:StopMovingOrSizing()
        if scrollFrame and currentPageId then ShowPage(currentPageId) end
    end)

    -- Sidebar (left)
    CreateSidebar()

    -- Content area (right of sidebar)
    contentArea = CreateFrame("Frame", nil, optionsFrame)
    contentArea:SetPoint("TOPLEFT", sidebarFrame, "TOPRIGHT", 4, 0)
    contentArea:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -4, 4)

    -- Shared scroll area for simple pages (General/Layout/Appearance/Click Casting)
    scrollFrame = CreateFrame("ScrollFrame", nil, contentArea)
    scrollFrame:SetPoint("TOPLEFT", 4, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", -16, 4)

    scrollBar = CreateFrame("Slider", nil, contentArea, "BackdropTemplate")
    scrollBar:SetPoint("TOPRIGHT", contentArea, "TOPRIGHT", -2, -4)
    scrollBar:SetPoint("BOTTOMRIGHT", contentArea, "BOTTOMRIGHT", -2, 4)
    scrollBar:SetWidth(12)
    scrollBar:SetOrientation("VERTICAL")
    scrollBar:SetMinMaxValues(0, 0)
    scrollBar:SetValueStep(20)
    scrollBar:SetValue(0)
    scrollBar:SetObeyStepOnDrag(true)
    W.StylizeFrame(scrollBar, {0.1, 0.1, 0.1, 0.8}, {0, 0, 0, 1})

    local scrollThumb = scrollBar:CreateTexture(nil, "OVERLAY")
    scrollThumb:SetSize(10, 30)
    scrollThumb:SetColorTexture(accent.r, accent.g, accent.b, 0.7)
    scrollBar:SetThumbTexture(scrollThumb)

    scrollChild = CreateFrame("Frame")
    scrollFrame:SetScrollChild(scrollChild)

    scrollFrame:SetScript("OnScrollRangeChanged", function(_, _, yrange)
        scrollBar:SetMinMaxValues(0, yrange)
    end)
    scrollBar:SetScript("OnValueChanged", function(_, value)
        scrollFrame:SetVerticalScroll(value)
    end)
    scrollFrame:SetScript("OnMouseWheel", function(_, delta)
        local current = scrollBar:GetValue()
        local minVal, maxVal = scrollBar:GetMinMaxValues()
        local newVal = math.max(minVal, math.min(maxVal, current - delta * 30))
        scrollBar:SetValue(newVal)
    end)

    -- Full-area host for Indicators pages (no shared scroll wrapper --
    -- IndicatorsPanel.lua manages its own list/settings/preview panes).
    indicatorsHost = CreateFrame("Frame", nil, contentArea)
    indicatorsHost:SetAllPoints(contentArea)
    indicatorsHost:Hide()

    -- Show page function. "indicators" is a single page that manages its own
    -- preview/list/settings layout internally (IndicatorsPanel.lua), so it
    -- skips the shared scroll wrapper the simple pages use, same as before.
    ShowPage = function(navId)
        if not navId then return end
        currentPageId = navId

        for _, frame in pairs(contentFrames) do
            if frame then frame:Hide() end
        end

        local isIndicatorsPage = (navId == "indicators")

        scrollFrame:SetShown(not isIndicatorsPage)
        scrollBar:SetShown(not isIndicatorsPage)
        indicatorsHost:SetShown(isIndicatorsPage)

        local selected = contentFrames[navId]
        if selected then selected:Show() end

        HighlightRow(navId)

        -- The group preview window is shared by the Layout and Indicators
        -- pages, which keep INDEPENDENT Party/Raid selections. Without this,
        -- opening it from Layout/Raid and then navigating to an Indicators
        -- page sitting on Party would leave the window showing a raid while
        -- the page beside it edits party -- so re-point it at whichever page
        -- you just landed on. No-op while the window is closed.
        local GroupPreview = SquizzFrames.GroupPreview
        if GroupPreview and GroupPreview.SetRaidMode then
            if navId == "layout" then
                GroupPreview.SetRaidMode(activeLayoutKey == "raid")
            elseif navId == "indicators" then
                local IP = SquizzFrames.IndicatorsPanel
                if IP and IP.IsRaidTab then
                    GroupPreview.SetRaidMode(IP.IsRaidTab())
                end
            end
        end

        if not isIndicatorsPage then
            -- At least the page's natural/minimum content height
            -- (pageHeights), but never smaller than the actual visible
            -- viewport -- growing the window (resizeGrip's OnMouseUp
            -- already re-calls ShowPage) used to leave scrollChild pinned
            -- to the fixed pageHeights value regardless of how much bigger
            -- the window got, so pages with bottom-anchored content (e.g.
            -- Click Casting's button bar/keybind list, both anchored to
            -- this frame's own bottom edge) just left dead space below
            -- them instead of the list/buttons actually growing into it.
            local height = math.max(pageHeights[navId] or 400, scrollFrame:GetHeight())
            scrollChild:SetSize(scrollFrame:GetWidth(), height)
            scrollFrame:SetVerticalScroll(0)
            scrollBar:SetValue(0)
        end

        if selected and selected.RebuildClickCasting then
            selected:RebuildClickCasting()
        end
    end

    optionsFrame.ShowPage = ShowPage

    -- Combat protection
    optionsFrame:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_REGEN_DISABLED" then
            self:SetAlpha(0.5)
        elseif event == "PLAYER_REGEN_ENABLED" then
            self:SetAlpha(1)
        end
    end)
    optionsFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    optionsFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

    optionsFrame.titleBar = titleBar

    return optionsFrame
end

-----------------------------------------------------------------------
-- Named checkbox value handlers (avoids inline lambdas)
-----------------------------------------------------------------------

local function GetHideParty()
    local p = GetProfile()
    return p and p.general and p.general.hideBlizzardParty
end

local function SetHideParty(checked)
    local p = GetProfile()
    if p and p.general then
        p.general.hideBlizzardParty = checked
        if SquizzFrames.HideBlizzardParty then SquizzFrames:HideBlizzardParty() end
        SquizzFrames:Fire("LayoutChanged")
    end
end

local function GetHideRaid()
    local p = GetProfile()
    return p and p.general and p.general.hideBlizzardRaid
end

local function SetHideRaid(checked)
    local p = GetProfile()
    if p and p.general then
        p.general.hideBlizzardRaid = checked
        if SquizzFrames.HideBlizzardRaid then SquizzFrames:HideBlizzardRaid() end
        SquizzFrames:Fire("LayoutChanged")
    end
end

local function GetLocked()
    return SquizzFrames.locked
end

local function SetLocked(checked)
    SquizzFrames.locked = checked
    SquizzFrames:Fire("LockChanged", checked)
end


local function GetFadeOut()
    local p = GetProfile()
    return p and p.general and p.general.fadeOut
end

local function SetFadeOut(checked)
    local p = GetProfile()
    if p and p.general then
        p.general.fadeOut = checked
        SquizzFrames:Fire("LayoutChanged")
    end
end

-- Every accessor below reads/writes p.layout[activeLayoutKey] instead of a
-- hardcoded p.layout.main, so the same widgets serve both the Party ("main")
-- and Raid ("raid") tabs -- switching activeLayoutKey + calling
-- rebuildLayoutFields() is what actually changes which values are shown.
local function GetActiveLayoutTable()
    local p = GetProfile()
    return p and p.layout and p.layout[activeLayoutKey]
end

local function GetWidth()
    local l = GetActiveLayoutTable()
    return l and l.width or (activeLayoutKey == "raid" and 70 or 100)
end

local function SetWidth(val)
    local l = GetActiveLayoutTable()
    if l then
        l.width = val
        SquizzFrames:Fire("LayoutChanged")
    end
end

local function GetHeight()
    local l = GetActiveLayoutTable()
    return l and l.height or (activeLayoutKey == "raid" and 24 or 40)
end

local function SetHeight(val)
    local l = GetActiveLayoutTable()
    if l then
        l.height = val
        SquizzFrames:Fire("LayoutChanged")
    end
end

local function GetPowerHeight()
    local l = GetActiveLayoutTable()
    return l and l.powerHeight or (activeLayoutKey == "raid" and 3 or 4)
end

local function SetPowerHeight(val)
    local l = GetActiveLayoutTable()
    if l then
        l.powerHeight = val
        SquizzFrames:Fire("LayoutChanged")
    end
end

local function GetOrientation()
    local l = GetActiveLayoutTable()
    return l and l.orientation or "vertical"
end

-- Growth direction dropdown items, filtered by orientation. Horizontal shows
-- Left/Right/Center, vertical shows Up/Down/Center. Available identically
-- for Party and Raid -- for raid, Center growth centers the unit axis
-- within each subgroup (see LayoutRaidGroupHeaders in
-- PartyFrames.lua); group placement itself is unaffected. Defined at file
-- scope so SetOrientation (also file scope) can call it to refresh the
-- dropdown.
local function GetDirectionItems(orientation)
    if orientation == "horizontal" then
        return {
            {value = "RIGHT",    text = L["Right"] or "Right"},
            {value = "LEFT",     text = L["Left"] or "Left"},
            {value = "CENTER_H", text = L["Center (Horizontal)"] or "Center (Horizontal)"},
        }
    else
        return {
            {value = "DOWN",     text = L["Down"] or "Down"},
            {value = "UP",       text = L["Up"] or "Up"},
            {value = "CENTER_V", text = L["Center (Vertical)"] or "Center (Vertical)"},
        }
    end
end

local function SetOrientation(val)
    local l = GetActiveLayoutTable()
    if l then
        l.orientation = val
        -- If the current growth direction is invalid for the new
        -- orientation, reset it to a valid default so the layout doesn't
        -- break. CENTER_H/CENTER_V are valid for both Party and Raid.
        local gd = l.growthDirection
        local isRaid = (activeLayoutKey == "raid")
        if val == "horizontal" then
            if gd ~= "LEFT" and gd ~= "RIGHT" and gd ~= "CENTER_H" then
                l.growthDirection = "RIGHT"
            end
        else
            if gd ~= "UP" and gd ~= "DOWN" and gd ~= "CENTER_V" then
                l.growthDirection = "DOWN"
            end
        end
        -- Refresh the growth direction dropdown so it shows the correct
        -- options for the new orientation (Up/Down/Center vs Left/Right/Center).
        if growthDirDropdown and growthDirDropdown.dropdown
           and growthDirDropdown.dropdown.RefreshItems then
            local newVal = l.growthDirection
            growthDirDropdown.dropdown:RefreshItems(GetDirectionItems(val))
            -- Sync displayed value to the reset growth direction
            growthDirDropdown.dropdown.selectedValue = newVal
        end
        -- Re-anchor to the corner that matches the (possibly reset) growth
        -- direction so the block grows from the correct edge. ONLY when
        -- editing the tab that matches the player's REAL current group
        -- state -- ReanchorContainer reads the container's actual on-screen
        -- position and saves it into GetActiveLayout(), which always
        -- follows real IsInRaid(), NOT this options panel's activeLayoutKey.
        -- Calling it while editing the OTHER (non-live) tab would read the
        -- real container's current position (reflecting whichever mode is
        -- actually rendering) and stomp THAT mode's saved anchor with it --
        -- confirmed bug: editing the Raid tab's Orientation/Growth Direction
        -- while actually solo/partied was silently overwriting the Party
        -- anchor with the container's current (real, party-mode) position.
        if isRaid == IsInRaid() then
            local partyModule = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
            if partyModule and partyModule.ReanchorContainer then
                partyModule:ReanchorContainer()
            end
        end
        SquizzFrames:Fire("LayoutChanged")
    end
end

local function GetGrowthDirection()
    local l = GetActiveLayoutTable()
    return l and l.growthDirection or "DOWN"
end

local function SetGrowthDirection(val)
    local l = GetActiveLayoutTable()
    if l then
        -- Reject growth directions that don't match the current orientation.
        -- CENTER_H/CENTER_V are valid for both Party and Raid now.
        local ori = l.orientation or "vertical"
        local isRaid = (activeLayoutKey == "raid")
        if ori == "horizontal" then
            if val ~= "LEFT" and val ~= "RIGHT" and val ~= "CENTER_H" then
                val = "RIGHT"
            end
        else
            if val ~= "UP" and val ~= "DOWN" and val ~= "CENTER_V" then
                val = "DOWN"
            end
        end
        l.growthDirection = val
        -- Re-anchor to the corner that matches the new growth direction --
        -- ONLY when editing the tab that matches real IsInRaid() (see the
        -- matching comment in SetOrientation for why: ReanchorContainer
        -- always targets whichever mode is REALLY active, so calling it
        -- while editing the other tab would stomp that mode's saved anchor
        -- with the container's current, unrelated on-screen position).
        if isRaid == IsInRaid() then
            local partyModule = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
            if partyModule and partyModule.ReanchorContainer then
                partyModule:ReanchorContainer()
            end
        end
        SquizzFrames:Fire("LayoutChanged")
    end
end

-- Screen anchor point. Operates on activeLayoutKey, so the Party and Raid
-- tabs each set their own -- they're independent layouts with independent
-- positions. Unlike Orientation/Growth Direction above, this is safe to
-- change from the non-live tab: PartyFrames:SetLayoutAnchorPoint writes to
-- the layout it was HANDED (by key) rather than to GetActiveLayout(), so it
-- can't stomp the other mode's anchor.
local ANCHOR_POINT_ITEMS = {
    {value = "CENTER",      text = L["Center"] or "Center"},
    {value = "TOP",         text = L["Top"] or "Top"},
    {value = "BOTTOM",      text = L["Bottom"] or "Bottom"},
    {value = "LEFT",        text = L["Left"] or "Left"},
    {value = "RIGHT",       text = L["Right"] or "Right"},
    {value = "TOPLEFT",     text = L["Top Left"] or "Top Left"},
    {value = "TOPRIGHT",    text = L["Top Right"] or "Top Right"},
    {value = "BOTTOMLEFT",  text = L["Bottom Left"] or "Bottom Left"},
    {value = "BOTTOMRIGHT", text = L["Bottom Right"] or "Bottom Right"},
}

local function GetAnchorPointOpt()
    local l = GetActiveLayoutTable()
    return (l and l.anchorPoint) or "CENTER"
end

local function SetAnchorPointOpt(val)
    local partyModule = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    if partyModule and partyModule.SetLayoutAnchorPoint then
        -- Converts the saved offsets so the frames stay put rather than
        -- teleporting; also fires LayoutChanged itself.
        partyModule:SetLayoutAnchorPoint(activeLayoutKey, val)
    end
end

local function GetSpacing()
    local l = GetActiveLayoutTable()
    return l and l.spacingY or 0
end

local function SetSpacing(val)
    local l = GetActiveLayoutTable()
    if l then
        l.spacingY = val
        SquizzFrames:Fire("LayoutChanged")
    end
end

local function GetGroupSpacing()
    local l = GetActiveLayoutTable()
    return l and l.groupSpacing or 6
end

local function SetGroupSpacing(val)
    local l = GetActiveLayoutTable()
    if l then
        l.groupSpacing = val
        SquizzFrames:Fire("LayoutChanged")
    end
end

-- Raid Size: expected raid size for PREVIEW purposes only (see
-- PartyFrames:SetPreviewMode) -- always targets layout.raid directly since
-- it's a raid-only concept, regardless of which tab is active.
local function GetRaidSize()
    local p = GetProfile()
    local l = p and p.layout and p.layout.raid
    return l and l.raidSize or 40
end

local function SetRaidSize(val)
    local p = GetProfile()
    local l = p and p.layout and p.layout.raid
    if l then l.raidSize = val end
    local partyModule = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    if partyModule and partyModule.RefreshPreviewMode then
        partyModule:RefreshPreviewMode()
    end
end

local function GetHideSelf()
    local l = GetActiveLayoutTable()
    return l and l.hideSelf
end

local function SetHideSelf(checked)
    local l = GetActiveLayoutTable()
    if l then
        l.hideSelf = checked
        SquizzFrames:Fire("LayoutChanged")
    end
end

local function GetSortByRole()
    local l = GetActiveLayoutTable()
    return l and l.sortByRole
end

local function SetSortByRole(checked)
    local l = GetActiveLayoutTable()
    if l then
        l.sortByRole = checked
        SquizzFrames:Fire("LayoutChanged")
        -- Show/hide the role-priority dropdowns below.
        if rebuildLayoutFields then rebuildLayoutFields() end
    end
end

-- Bundled into a single table (rather than separate top-level locals) so
-- BuildLayoutFields only picks up ONE new upvalue referencing this instead
-- of several -- that function already sits close to Lua's 60-upvalue-per-
-- function ceiling (it hosts every Layout-tab accessor), and a handful of
-- extra individual locals was enough to tip it over (silent runtime
-- LUA_WARNING "function ... has more than 60 upvalues").
local RoleOrderUI = {
    DEFAULT = {"TANK", "HEALER", "DAMAGER"},
    ITEMS = {
        {value = "TANK", text = L["Tank"] or "Tank"},
        {value = "HEALER", text = L["Healer"] or "Healer"},
        {value = "DAMAGER", text = L["DPS"] or "DPS"},
    },
}

function RoleOrderUI.Get()
    local l = GetActiveLayoutTable()
    return (l and l.roleOrder) or RoleOrderUI.DEFAULT
end

-- Set the role in priority slot `index` (1/2/3). Swaps with whichever slot
-- currently holds the newly-picked role, so the list always stays a valid
-- 3-way permutation instead of allowing duplicates/gaps.
function RoleOrderUI.SetPriority(index, newRole)
    local l = GetActiveLayoutTable()
    if not l then return end
    if not l.roleOrder then
        l.roleOrder = {RoleOrderUI.DEFAULT[1], RoleOrderUI.DEFAULT[2], RoleOrderUI.DEFAULT[3]}
    end
    local order = l.roleOrder
    local oldRole = order[index]
    if oldRole == newRole then return end
    for i, r in ipairs(order) do
        if r == newRole then
            order[i] = oldRole
            break
        end
    end
    order[index] = newRole
    SquizzFrames:Fire("LayoutChanged")
    if rebuildLayoutFields then rebuildLayoutFields() end
end

local function GetScale()
    local p = GetProfile()
    return p and p.appearance and p.appearance.general and p.appearance.general.scale or 1.0
end

local function SetScale(val)
    local p = GetProfile()
    if p and p.appearance and p.appearance.general then
        p.appearance.general.scale = val
        SquizzFrames:Fire("ScaleChanged")
    end
end

local function GetOutOfRange()
    local p = GetProfile()
    return p and p.appearance and p.appearance.general and p.appearance.general.outOfRangeAlpha or 0.3
end

local function SetOutOfRange(val)
    local p = GetProfile()
    if p and p.appearance and p.appearance.general then
        p.appearance.general.outOfRangeAlpha = val
        SquizzFrames:Fire("LayoutChanged")
    end
end

local function GetBarTexture()
    local p = GetProfile()
    return p and p.appearance and p.appearance.general and p.appearance.general.texture or "Blizzard"
end

local function SetBarTexture(val)
    local p = GetProfile()
    if p and p.appearance and p.appearance.general then
        p.appearance.general.texture = val
        SquizzFrames:Fire("LayoutChanged")
    end
end

-- Fixed list matching EllesmereUIRaidFrames' own curated health/power bar
-- texture set exactly (name-for-name, same order) -- NOT a full enumeration
-- of every statusbar texture registered with LSM by any addon. Ellesmere's
-- own texture picker actually works this same way: its 19 built-ins are a
-- hardcoded list (see EllesmereUIRaidFrames.lua's InitHealthBarTextures),
-- with SharedMedia entries only appended after -- this dropdown intentionally
-- mirrors just the curated 19, not the SharedMedia tail, so it doesn't fill
-- up with unrelated textures every other installed addon happens to register.
-- All 19 are registered under these exact names in Media/Media.lua.
local ELLESMERE_BAR_TEXTURE_ORDER = {
    "None", "Melli (ElvUI)", "Atrocity", "Fade", "Fade Right",
    "Thin Line Top", "Thin Line Bottom", "Beautiful", "Plating", "Divide",
    "Glass", "Gradient Right", "Gradient Left", "Gradient Up", "Gradient Down",
    "Matte", "Sheer", "Blinkii Diamonds", "Kringel Window",
}

local function GetBarTextureItems()
    local items = {}
    for _, name in ipairs(ELLESMERE_BAR_TEXTURE_ORDER) do
        items[#items + 1] = { value = name, text = name }
    end
    return items
end

-- Health/power custom colors are stored in TWO places: fullColor/powerColor
-- (the LIVE render mode -- "class_color" or "custom_color" -- read by
-- PartyFrames.lua's UpdateHealth/UpdatePower) and a separate, persistent
-- customColor field that always remembers the last custom color regardless
-- of which mode is active. Without the separate field, toggling "Use Class
-- Colors" off used to hard-reset to a fixed default every time (confirmed
-- bug: any previously-picked custom color was discarded the moment class
-- color was turned on, since fullColor got overwritten to {"class_color",
-- "any"} with nothing preserving the prior custom values for when it was
-- turned off again).
local function GetHealthClassColor()
    local p = GetProfile()
    return p and p.appearance and p.appearance.healthBar and p.appearance.healthBar.fullColor and p.appearance.healthBar.fullColor[1] == "class_color"
end

local function SetHealthClassColor(checked)
    local p = GetProfile()
    if p and p.appearance and p.appearance.healthBar then
        local hb = p.appearance.healthBar
        if checked then
            hb.fullColor = {"class_color", "any"}
        else
            local c = hb.customColor or {0.2, 0.8, 0.2, 1}
            hb.fullColor = {"custom_color", c[1], c[2], c[3], c[4]}
        end
        SquizzFrames:Fire("LayoutChanged")
    end
end

-- Power bar color is a 3-way mode (class_color / custom_color /
-- blizzard_default -- Blizzard's own stock per-power-type color, mana=blue/
-- rage=red/etc, PartyFrames.lua's UpdatePower already falls through to
-- PowerBarColor for anything that isn't the first two). Health bar stays a
-- plain class-color-vs-custom checkbox (see cb3 above) since health has no
-- equivalent "stock color by type" concept to offer a third mode for.
local POWER_COLOR_MODES = {
    {value = "class_color", text = L["Class Color"] or "Class Color"},
    {value = "custom_color", text = L["Custom Color"] or "Custom Color"},
    {value = "blizzard_default", text = L["Default Blizzard Color"] or "Default Blizzard Color"},
}

local function GetPowerColorMode()
    local p = GetProfile()
    local pb = p and p.appearance and p.appearance.powerBar
    return (pb and pb.powerColor and pb.powerColor[1]) or "custom_color"
end

local function SetPowerColorMode(mode)
    local p = GetProfile()
    local pb = p and p.appearance and p.appearance.powerBar
    if not pb then return end
    if mode == "class_color" then
        pb.powerColor = {"class_color", "any"}
    elseif mode == "blizzard_default" then
        pb.powerColor = {"blizzard_default"}
    else
        local c = pb.customColor or {0.0863, 0.0706, 1, 1} -- #1612FF
        pb.powerColor = {"custom_color", c[1], c[2], c[3], c[4]}
    end
    SquizzFrames:Fire("LayoutChanged")
end

-- Custom (non-class-color) health/power bar colors -- always editable
-- regardless of whether Use Class Colors is currently checked (matches the
-- common pattern of showing both controls). Reads/writes the persistent
-- customColor field; only pushes into the LIVE fullColor/powerColor (and
-- fires a re-render) when custom mode is actually active -- picking a color
-- while class color is checked just updates what custom mode WOULD show
-- next, without silently switching the live mode out from under the
-- checkbox (confirmed bug: it used to always overwrite fullColor to
-- custom_color immediately, regardless of what the checkbox displayed).
local function GetHealthCustomColor()
    local p = GetProfile()
    local hb = p and p.appearance and p.appearance.healthBar
    local c = hb and hb.customColor
    if c then return c[1] or 0.2, c[2] or 0.8, c[3] or 0.2, c[4] or 1 end
    return 0.2, 0.8, 0.2, 1
end

local function SetHealthCustomColor(r, g, b, a)
    local p = GetProfile()
    local hb = p and p.appearance and p.appearance.healthBar
    if hb then
        hb.customColor = {r, g, b, a}
        if hb.fullColor and hb.fullColor[1] ~= "class_color" then
            hb.fullColor = {"custom_color", r, g, b, a}
            SquizzFrames:Fire("LayoutChanged")
        end
    end
end

local function GetPowerCustomColor()
    local p = GetProfile()
    local pb = p and p.appearance and p.appearance.powerBar
    local c = pb and pb.customColor
    if c then return c[1] or 0.0863, c[2] or 0.0706, c[3] or 1, c[4] or 1 end
    return 0.0863, 0.0706, 1, 1 -- #1612FF
end

local function SetPowerCustomColor(r, g, b, a)
    local p = GetProfile()
    local pb = p and p.appearance and p.appearance.powerBar
    if pb then
        pb.customColor = {r, g, b, a}
        if pb.powerColor and pb.powerColor[1] ~= "class_color" then
            pb.powerColor = {"custom_color", r, g, b, a}
            SquizzFrames:Fire("LayoutChanged")
        end
    end
end

-----------------------------------------------------------------------
-- Target Highlight / Hover Highlight -- moved here from the Indicators tab
-- (excluded from IndicatorsPanel.lua's list) since they're simple, always-
-- relevant frame borders that belong with the rest of the frame's
-- appearance settings, matching EllesmereUIRaidFrames' own grouping (their
-- Frame Display section has both target and hover border settings
-- together). Storage is still a normal indicator entry in
-- profile.layout.indicators -- BuiltIn_Update.lua's CheckTargetHighlight/
-- CheckHoverHighlight read it exactly the same way regardless of which
-- options tab edits it. Live updates go through the same
-- SquizzFrames:Fire("UpdateIndicators", ...) message the Indicators tab's
-- own widgets use (Indicators.lua's UpdateIndicators handler applies it to
-- every wired button and updates the stored table).
-----------------------------------------------------------------------

local function FindIndicatorEntry(name)
    local p = GetProfile()
    local list = p and p.layout and p.layout.indicators
    if not list then return nil end
    for _, t in ipairs(list) do
        if t.indicatorName == name then return t end
    end
    return nil
end

-- Target/Hover Highlight and Frame Border are deliberately universal --
-- Party's own list (via FindIndicatorEntry above) is the source of truth
-- for reads, but every WRITE below also mirrors the same value onto Raid's
-- matching entry, so the two never drift apart even though only ONE UI
-- surface (this page, not the per-Party/Raid Designer) ever edits them. The
-- accompanying SquizzFrames:Fire calls omit isRaidContext (nil), which
-- Indicators.lua's CollectAndApply treats as unfiltered -- it reaches every
-- real button regardless of that button's own current party/raid state,
-- same as this whole system behaved before the party/raid split existed.
local function FindIndicatorEntryRaid(name)
    local p = GetProfile()
    local list = p and p.layout and p.layout.indicatorsRaid
    if not list then return nil end
    for _, t in ipairs(list) do
        if t.indicatorName == name then return t end
    end
    return nil
end

local function GetIndicatorEnabled(name)
    local t = FindIndicatorEntry(name)
    return t and t.enabled
end

local function SetIndicatorEnabled(name, checked)
    local t = FindIndicatorEntry(name)
    if t then
        t.enabled = checked
        local tRaid = FindIndicatorEntryRaid(name)
        if tRaid then tRaid.enabled = checked end
        SquizzFrames:Fire("UpdateIndicators", name, "enabled", checked)
    end
end

local function GetIndicatorThickness(name)
    local t = FindIndicatorEntry(name)
    return t and t.thickness or 2
end

local function SetIndicatorThickness(name, val)
    local t = FindIndicatorEntry(name)
    if t then
        t.thickness = val
        local tRaid = FindIndicatorEntryRaid(name)
        if tRaid then tRaid.thickness = val end
        SquizzFrames:Fire("UpdateIndicators", name, "thickness", val)
    end
end

-- F.ColorRGB only recognizes the tagged {"custom_color", r,g,b,a} shape
-- (matches how CreateSetting_ColorAlpha's widget always stores it) -- see
-- Layout_Defaults.lua's comment on targetHighlight's color field.
local function GetIndicatorColor(name)
    local t = FindIndicatorEntry(name)
    return F.ColorRGB(t and t.color)
end

local function SetIndicatorColor(name, r, g, b, a)
    local t = FindIndicatorEntry(name)
    if t then
        t.color = {"custom_color", r, g, b, a}
        local tRaid = FindIndicatorEntryRaid(name)
        if tRaid then tRaid.color = {"custom_color", r, g, b, a} end
        SquizzFrames:Fire("UpdateIndicators", name, "color", t.color)
    end
end

local function GetTargetHighlightEnabled() return GetIndicatorEnabled("targetHighlight") end
local function SetTargetHighlightEnabled(v) SetIndicatorEnabled("targetHighlight", v) end
local function GetTargetHighlightThickness() return GetIndicatorThickness("targetHighlight") end
local function SetTargetHighlightThickness(v) SetIndicatorThickness("targetHighlight", v) end
local function GetTargetHighlightColor() return GetIndicatorColor("targetHighlight") end
local function SetTargetHighlightColor(r, g, b, a) SetIndicatorColor("targetHighlight", r, g, b, a) end

local function GetHoverHighlightEnabled() return GetIndicatorEnabled("hoverHighlight") end
local function SetHoverHighlightEnabled(v) SetIndicatorEnabled("hoverHighlight", v) end
local function GetHoverHighlightThickness() return GetIndicatorThickness("hoverHighlight") end
local function SetHoverHighlightThickness(v) SetIndicatorThickness("hoverHighlight", v) end
local function GetHoverHighlightColor() return GetIndicatorColor("hoverHighlight") end
local function SetHoverHighlightColor(r, g, b, a) SetIndicatorColor("hoverHighlight", r, g, b, a) end

local function GetFrameBorderEnabled() return GetIndicatorEnabled("frameBorder") end
local function SetFrameBorderEnabled(v) SetIndicatorEnabled("frameBorder", v) end
local function GetFrameBorderThickness() return GetIndicatorThickness("frameBorder") end
local function SetFrameBorderThickness(v) SetIndicatorThickness("frameBorder", v) end
local function GetFrameBorderColor() return GetIndicatorColor("frameBorder") end
local function SetFrameBorderColor(r, g, b, a) SetIndicatorColor("frameBorder", r, g, b, a) end

-----------------------------------------------------------------------
-- General Page Content
-----------------------------------------------------------------------

-- Builds (or rebuilds) the General page's widgets. Destroy-and-recreate
-- (not a per-widget refresh) -- same pattern as BuildProfilesFields/
-- BuildLayoutFields, since CreateStyledCheckbox only ever polls its
-- getChecked function ONCE at creation (there's no exposed "resync" method
-- on the returned widget), so a switched/copied profile would otherwise
-- leave every checkbox showing stale state until the page happened to be
-- rebuilt some other way (confirmed via user report: General/Layout/Click
-- Casting tabs didn't reflect a live profile copy until a full /reload).
local function BuildGeneralFields(frame)
    if frame.fieldsHost then
        frame.fieldsHost:Hide()
        frame.fieldsHost:SetParent(nil)
        frame.fieldsHost = nil
    end
    local fieldsHost = CreateFrame("Frame", nil, frame)
    fieldsHost:SetAllPoints()
    frame.fieldsHost = fieldsHost

    local yOffset = -10

    -- Section: Blizzard Frames
    W.CreateTitledPane(fieldsHost, L["Blizzard Frames"] or "Blizzard Frames", yOffset)
    yOffset = yOffset - 35

    local cb1 = W.CreateStyledCheckbox(fieldsHost, L["Hide Blizzard Party"] or "Hide Blizzard Party", GetHideParty, SetHideParty)
    cb1:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    local cb2 = W.CreateStyledCheckbox(fieldsHost, L["Hide Blizzard Raid"] or "Hide Blizzard Raid", GetHideRaid, SetHideRaid)
    cb2:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    -- Section: Behavior
    W.CreateTitledPane(fieldsHost, L["Behavior"] or "Behavior", yOffset)
    yOffset = yOffset - 35

    local cb3 = W.CreateStyledCheckbox(fieldsHost, L["Lock Frames"] or "Lock Frames", GetLocked, SetLocked)
    cb3:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    local cb4 = W.CreateStyledCheckbox(fieldsHost, L["Fade Out of Range"] or "Fade Out of Range", GetFadeOut, SetFadeOut)
    cb4:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    -- Edit Mode as a toggle button (not a checkbox) -- session-only state
    -- (SquizzFrames.editMode), not profile data, but rebuilt here anyway
    -- since it lives on the same page.
    local editBtn = W.CreateStyledButton(fieldsHost, L["Edit Mode"] or "Edit Mode", "accent-hover", {202, 22}, nil)
    editBtn:SetPoint("TOPLEFT", 15, yOffset)
    editBtn.fontString:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    local function RefreshEditModeButton()
        if SquizzFrames.editMode then
            local a = F.GetAccentColor()
            editBtn:SetBackdropColor(a.r, a.g, a.b, 0.5)
            editBtn.fontString:SetTextColor(1, 1, 1, 1)
        else
            editBtn:SetBackdropColor(0.115, 0.115, 0.115, 1)
            editBtn.fontString:SetTextColor(0.7, 0.7, 0.7, 1)
        end
    end
    editBtn:SetScript("OnClick", function()
        SquizzFrames.editMode = not SquizzFrames.editMode
        -- Direct call to PartyFrames module (bypasses AceEvent message bridge
        -- which can fail to deliver in some load-order scenarios)
        local partyModule = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
        if partyModule and partyModule.SetEditMode then
            partyModule:SetEditMode(SquizzFrames.editMode)
        end
        SquizzFrames:Fire("EditModeChanged", SquizzFrames.editMode)
        RefreshEditModeButton()
    end)
    RefreshEditModeButton()
    yOffset = yOffset - 30

    -- Keep the button state in sync if edit mode is toggled from elsewhere.
    -- Re-registering under the same owner ("SquizzFrames") + event name on
    -- every rebuild REPLACES the previous handler (CallbackHandler-3.0
    -- semantics), it doesn't accumulate duplicates.
    SquizzFrames:RegisterMessage("EditModeChanged", function() RefreshEditModeButton() end)
end

local function CreateGeneralPage()
    local frame = CreateFrame("Frame", nil, scrollChild)
    frame:SetAllPoints()
    frame:Hide()
    contentFrames["general"] = frame

    BuildGeneralFields(frame)

    -- Re-sync every checkbox's displayed state whenever the active profile
    -- changes (switch/copy/reset), not just when this tab happens to be
    -- rebuilt some other way.
    -- Own message owner (2026-08-07): six sites used to register
    -- "ProfileChanged" on the shared SquizzFrames root, and CallbackHandler
    -- keys by (owner, message) -- so only the last-registered survived and
    -- every other page silently stopped refreshing on a profile switch.
    -- See F.NewMessageOwner in Utils.lua.
    F.NewMessageOwner():RegisterMessage("ProfileChanged", function() BuildGeneralFields(frame) end)
end

-----------------------------------------------------------------------
-- Layout Page Content
-----------------------------------------------------------------------

-- Builds (or rebuilds) the actual field widgets for whichever layout is
-- currently selected (activeLayoutKey). Called once at page creation and
-- again every time the Party/Raid toggle is clicked -- old widgets are
-- discarded and recreated rather than trying to refresh each one in place,
-- since a handful of small widgets is cheap to rebuild and this avoids
-- needing a bespoke refresh path on every widget type (sliders, dropdowns,
-- checkboxes).
-- Border sections (Frame Border + Target/Hover Highlight), split out of
-- BuildLayoutFields (2026-08-07).
--
-- NOT cosmetic: Lua caps a function at 60 UPVALUES (distinct enclosing-scope
-- locals it references), and BuildLayoutFields references one Get/Set
-- closure pair per control, so it sat just under the cap and adding the
-- Copy Between Modes section pushed it over -- "function at line 1083 has
-- more than 60 upvalues". These three sections alone account for 18 of
-- them, so moving them here buys back plenty of headroom for future
-- settings. If that warning ever returns, extract another section the same
-- way rather than trying to shave individual references.
--
-- Takes and returns yOffset so the caller's vertical flow is unchanged.
local function BuildBorderSections(fieldsHost, yOffset)
    -- Section: Frame Border -- static decorative border around the whole
    -- button (matches EllesmereUIRaidFrames' general Border Style/Size).
    -- Backed by the "frameBorder" built-in indicator; moved here rather than
    -- the Indicators tab since it's an always-relevant appearance setting.
    W.CreateTitledPane(fieldsHost, L["Frame Border"] or "Frame Border", yOffset)
    yOffset = yOffset - 35

    local cbFB = W.CreateStyledCheckbox(fieldsHost, L["Enabled"] or "Enabled", GetFrameBorderEnabled, SetFrameBorderEnabled)
    cbFB:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    local sliderFB = W.CreateStyledSlider(fieldsHost, 200, 1, 6, 1, L["Border Size"] or "Border Size", GetFrameBorderThickness, SetFrameBorderThickness)
    sliderFB:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 65

    local colorFB = W.CreateColorPicker(fieldsHost, L["Border Color"] or "Border Color", GetFrameBorderColor, SetFrameBorderColor)
    colorFB:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 30

    -- Section: Target / Hover Highlight -- moved here from the Indicators
    -- tab (see the comment above FindIndicatorEntry) -- backed by the
    -- targetHighlight/hoverHighlight built-in indicators. Hover always takes
    -- visual priority over target (see BuiltIn_Update.lua's
    -- CheckTargetHighlight), matching EllesmereUIRaidFrames' own behavior.
    W.CreateTitledPane(fieldsHost, L["Target Highlight"] or "Target Highlight", yOffset)
    yOffset = yOffset - 35

    local cbTH = W.CreateStyledCheckbox(fieldsHost, L["Enabled"] or "Enabled", GetTargetHighlightEnabled, SetTargetHighlightEnabled)
    cbTH:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    local sliderTH = W.CreateStyledSlider(fieldsHost, 200, 1, 6, 1, L["Border Size"] or "Border Size", GetTargetHighlightThickness, SetTargetHighlightThickness)
    sliderTH:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 65

    local colorTH = W.CreateColorPicker(fieldsHost, L["Border Color"] or "Border Color", GetTargetHighlightColor, SetTargetHighlightColor)
    colorTH:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 30

    W.CreateTitledPane(fieldsHost, L["Hover Highlight"] or "Hover Highlight", yOffset)
    yOffset = yOffset - 35

    local cbHH = W.CreateStyledCheckbox(fieldsHost, L["Enabled"] or "Enabled", GetHoverHighlightEnabled, SetHoverHighlightEnabled)
    cbHH:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    local sliderHH = W.CreateStyledSlider(fieldsHost, 200, 1, 6, 1, L["Border Size"] or "Border Size", GetHoverHighlightThickness, SetHoverHighlightThickness)
    sliderHH:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 65

    local colorHH = W.CreateColorPicker(fieldsHost, L["Border Color"] or "Border Color", GetHoverHighlightColor, SetHoverHighlightColor)
    colorHH:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 30

    return yOffset
end

local function BuildLayoutFields(frame)
    if frame.fieldsHost then
        frame.fieldsHost:Hide()
        frame.fieldsHost:SetParent(nil)
        frame.fieldsHost = nil
    end

    local fieldsHost = CreateFrame("Frame", nil, frame)
    fieldsHost:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -34)
    fieldsHost:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    frame.fieldsHost = fieldsHost

    local isRaid = (activeLayoutKey == "raid")
    local yOffset = -10

    -- Section: Copy Between Modes. Party and Raid keep fully separate
    -- settings for layout, indicators AND pet frames, so configuring the
    -- second mode from scratch is a lot of clicking -- this is the one-shot
    -- way across. Two-click arm/confirm (the same pattern the Profiles
    -- page's Delete uses) since it overwrites the other mode wholesale.
    W.CreateTitledPane(fieldsHost, L["Copy Between Modes"] or "Copy Between Modes", yOffset)
    yOffset = yOffset - 35

    do
        local copyDesc = fieldsHost:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        copyDesc:SetPoint("TOPLEFT", 15, yOffset)
        copyDesc:SetWidth(420)
        copyDesc:SetJustifyH("LEFT")
        copyDesc:SetText(L["Copies sizing, layout, indicators and pet frames to the other mode. Each mode keeps its own on-screen position."]
            or "Copies sizing, layout, indicators and pet frames to the other mode. Each mode keeps its own on-screen position.")
        yOffset = yOffset - 30

        -- Direction is fixed by which tab you're on, so there's no way to
        -- get it backwards: you always copy FROM what you're looking at.
        local dir = isRaid and "raidToParty" or "partyToRaid"
        local label = isRaid and (L["Copy Raid to Party..."] or "Copy Raid to Party...")
            or (L["Copy Party to Raid..."] or "Copy Party to Raid...")
        local armed = false
        local copyBtn
        copyBtn = W.CreateStyledButton(fieldsHost, label, "accent-hover", {200, 22}, function()
            local db = SquizzFrames.db
            if not db or not db.CopyBetweenModes then return end
            if not armed then
                armed = true
                copyBtn.fontString:SetText(L["Click again to confirm"] or "Click again to confirm")
                return
            end
            db:CopyBetweenModes(dir)
            armed = false
            copyBtn.fontString:SetText(label)
        end)
        copyBtn:SetPoint("TOPLEFT", 15, yOffset)
        yOffset = yOffset - 40
    end

    -- Section: Sizing
    W.CreateTitledPane(fieldsHost, L["Sizing"] or "Sizing", yOffset)
    yOffset = yOffset - 35

    local slider1 = W.CreateStyledSlider(fieldsHost, 200, 40, 200, 1, L["Width"] or "Width", GetWidth, SetWidth)
    slider1:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 65

    local slider2 = W.CreateStyledSlider(fieldsHost, 200, 20, 100, 1, L["Height"] or "Height", GetHeight, SetHeight)
    slider2:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 65

    local slider3 = W.CreateStyledSlider(fieldsHost, 200, 2, 20, 1, L["Power Bar Height"] or "Power Bar Height", GetPowerHeight, SetPowerHeight)
    slider3:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 65

    -- Section: Layout Options
    W.CreateTitledPane(fieldsHost, L["Layout Options"] or "Layout Options", yOffset)
    yOffset = yOffset - 35

    local slider4 = W.CreateStyledSlider(fieldsHost, 200, 0, 20, 1, L["Spacing"] or "Spacing", GetSpacing, SetSpacing)
    slider4:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 65

    -- Raid-only: gap between subgroup blocks (distinct from Spacing, which is
    -- the gap between units WITHIN one subgroup).
    if isRaid then
        local slider4b = W.CreateStyledSlider(fieldsHost, 200, 0, 40, 1, L["Group Spacing"] or "Group Spacing", GetGroupSpacing, SetGroupSpacing)
        slider4b:SetPoint("TOPLEFT", 15, yOffset - 20)
        yOffset = yOffset - 65
    end

    local dd1 = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Orientation"] or "Orientation", {
        {value = "vertical",   text = L["Vertical"] or "Vertical"},
        {value = "horizontal", text = L["Horizontal"] or "Horizontal"},
    }, GetOrientation, SetOrientation)
    dd1:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 70

    -- Growth direction dropdown. Items are filtered by orientation: horizontal
    -- shows Left/Right/Center, vertical shows Up/Down/Center -- same options
    -- for both Party and Raid. The dropdown is refreshed whenever
    -- orientation changes (SetOrientation).
    local dd = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Growth Direction"] or "Growth Direction",
        GetDirectionItems(GetOrientation()), GetGrowthDirection, SetGrowthDirection)
    growthDirDropdown = dd
    dd:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 70

    -- Screen anchor point (independent per Party/Raid tab). Changing it
    -- re-expresses the saved position against the new point, so the frames
    -- don't move -- see PartyFrames:SetLayoutAnchorPoint.
    local ddAnchor = W.CreateStyledDropdown(fieldsHost, 200, 40,
        L["Anchor Point"] or "Anchor Point",
        ANCHOR_POINT_ITEMS, GetAnchorPointOpt, SetAnchorPointOpt)
    ddAnchor:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 70

    -- Section: Visibility
    W.CreateTitledPane(fieldsHost, L["Visibility"] or "Visibility", yOffset)
    yOffset = yOffset - 35

    local cb1 = W.CreateStyledCheckbox(fieldsHost, L["Hide Self"] or "Hide Self", GetHideSelf, SetHideSelf)
    cb1:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    local cb2 = W.CreateStyledCheckbox(fieldsHost, L["Sort By Role"] or "Sort By Role", GetSortByRole, SetSortByRole)
    cb2:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    if GetSortByRole() then
        local roleOrderLabel = fieldsHost:CreateFontString(nil, "OVERLAY")
        roleOrderLabel:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        roleOrderLabel:SetPoint("TOPLEFT", 30, yOffset)
        roleOrderLabel:SetTextColor(0.7, 0.7, 0.7, 1)
        roleOrderLabel:SetText(L["Role Priority (top = first)"] or "Role Priority (top = first)")
        yOffset = yOffset - 20

        local priorityLabels = {L["1st"] or "1st", L["2nd"] or "2nd", L["3rd"] or "3rd"}
        for i = 1, 3 do
            local ddRole = W.CreateStyledDropdown(fieldsHost, 110, 40, priorityLabels[i], RoleOrderUI.ITEMS,
                function() return (RoleOrderUI.Get())[i] end,
                function(val) RoleOrderUI.SetPriority(i, val) end)
            ddRole:SetPoint("TOPLEFT", 30 + (i - 1) * 125, yOffset - 20)
        end
        yOffset = yOffset - 65
    end

    -- Raid-only: how many units the layout preview mocks up (doesn't affect
    -- real display, which always shows the real roster).
    if isRaid then
        local ddRaidSize = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Raid Size"] or "Raid Size", {
            {value = 10, text = "10"},
            {value = 20, text = "20"},
            {value = 30, text = "30"},
            {value = 40, text = "40"},
        }, GetRaidSize, SetRaidSize)
        ddRaidSize:SetPoint("TOPLEFT", 15, yOffset - 20)
        yOffset = yOffset - 70
    end

    -- Section: Appearance (merged in from the former standalone Appearance
    -- tab -- layout and appearance go hand in hand, and these settings apply
    -- globally regardless of which mode/tab is selected above).
    W.CreateTitledPane(fieldsHost, L["Appearance"] or "Appearance", yOffset)
    yOffset = yOffset - 35

    local slider5 = W.CreateStyledSlider(fieldsHost, 200, 0.5, 2.0, 0.05, L["Scale"] or "Scale", GetScale, SetScale)
    slider5:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 65

    local slider6 = W.CreateStyledSlider(fieldsHost, 200, 0, 1, 0.05, L["Out of Range Alpha"] or "Out of Range Alpha", GetOutOfRange, SetOutOfRange)
    slider6:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 65

    local textureDropdown = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Bar Texture"] or "Bar Texture",
        GetBarTextureItems(), GetBarTexture, SetBarTexture, "statusbar")
    textureDropdown:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 70

    W.CreateTitledPane(fieldsHost, L["Health Bar Colors"] or "Health Bar Colors", yOffset)
    yOffset = yOffset - 35

    local cb3 = W.CreateStyledCheckbox(fieldsHost, L["Use Class Colors"] or "Use Class Colors", GetHealthClassColor, SetHealthClassColor)
    cb3:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    -- Custom color swatch -- takes effect whenever "Use Class Colors" above
    -- is unchecked.
    local healthColorPicker = W.CreateColorPicker(fieldsHost, L["Custom Color"] or "Custom Color",
        GetHealthCustomColor, SetHealthCustomColor)
    healthColorPicker:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 30

    W.CreateTitledPane(fieldsHost, L["Power Bar Colors"] or "Power Bar Colors", yOffset)
    yOffset = yOffset - 35

    local ddPowerColorMode = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Color Mode"] or "Color Mode",
        POWER_COLOR_MODES, GetPowerColorMode, SetPowerColorMode)
    ddPowerColorMode:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 70

    -- Editable regardless of the mode above -- only takes visual effect once
    -- "Custom Color" is selected (see SetPowerCustomColor's own comment).
    local powerColorPicker = W.CreateColorPicker(fieldsHost, L["Custom Color"] or "Custom Color",
        GetPowerCustomColor, SetPowerCustomColor)
    powerColorPicker:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 30

    -- Frame Border + Target/Hover Highlight live in BuildBorderSections
    -- above -- see its comment (Lua's 60-upvalue-per-function cap).
    yOffset = BuildBorderSections(fieldsHost, yOffset)
end

local function CreateLayoutPage()
    local frame = CreateFrame("Frame", nil, scrollChild)
    frame:SetAllPoints()
    frame:Hide()
    contentFrames["layout"] = frame

    -- Party / Raid toggle -- switches which layout sub-table (profile.layout
    -- .main / .raid) the fields below read and write. Independent of the
    -- player's real current group state, so raid layout can be configured
    -- without actually being in a raid.
    local toggleButtons = {}
    local function RefreshToggleVisual()
        local accent = F.GetAccentColor()
        for key, btn in pairs(toggleButtons) do
            if key == activeLayoutKey then
                btn:SetBackdropColor(accent.r, accent.g, accent.b, 0.55)
            else
                btn:SetBackdropColor(0.115, 0.115, 0.115, 1)
            end
        end
    end

    local function MakeToggleButton(key, label, xOff)
        local btn = CreateFrame("Button", nil, frame, "BackdropTemplate")
        btn:SetSize(90, 22)
        btn:SetPoint("TOPLEFT", frame, "TOPLEFT", xOff, -6)
        W.StylizeFrame(btn, {0.115, 0.115, 0.115, 1}, {0, 0, 0, 0})
        local text = btn:CreateFontString(nil, "OVERLAY")
        text:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        text:SetPoint("CENTER")
        text:SetText(label)
        btn:SetScript("OnClick", function()
            if activeLayoutKey == key then return end
            activeLayoutKey = key
            RefreshToggleVisual()
            if rebuildLayoutFields then rebuildLayoutFields() end
            -- Live preview follows whichever tab is being edited (matches
            -- EllesmereUIRaidFrames' own preview, which resolves from the
            -- currently-open tab, not real group state) -- rebuild it for
            -- the new tab if it's currently showing. No-op when closed.
            local GroupPreview = SquizzFrames.GroupPreview
            if GroupPreview and GroupPreview.SetRaidMode then
                GroupPreview.SetRaidMode(key == "raid")
            end
        end)
        toggleButtons[key] = btn
        return btn
    end

    MakeToggleButton("main", L["Party"] or "Party", 15)
    MakeToggleButton("raid", L["Raid"] or "Raid", 110)
    RefreshToggleVisual()

    -- Preview button -- opens the shared full-group preview window
    -- (GroupPreview.lua), the same one the Indicators tab uses, showing a
    -- full 5-man party or 20-man raid at the configured sizes.
    --
    -- This replaced PartyFrames:SetPreviewMode's older in-world mockup, which
    -- drew stand-in buttons at the frames' real screen position and could be
    -- dragged to set it. Positioning now lives in EDIT MODE, which drags the
    -- real container (so its anchors are correct by construction) and has its
    -- own Party/Raid switch for adjusting either layout. The old preview
    -- system is left intact in PartyFrames.lua but is no longer reachable
    -- from this panel.
    local previewBtn = CreateFrame("Button", nil, frame, "BackdropTemplate")
    previewBtn:SetSize(110, 22)
    previewBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -15, -6)
    W.StylizeFrame(previewBtn, {0.115, 0.115, 0.115, 1}, {0, 0, 0, 0})
    local previewText = previewBtn:CreateFontString(nil, "OVERLAY")
    previewText:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    previewText:SetPoint("CENTER")
    previewText:SetText(L["Show Preview"] or "Show Preview")

    local function RefreshPreviewButtonVisual()
        local GroupPreview = SquizzFrames.GroupPreview
        local active = GroupPreview and GroupPreview.IsShown and GroupPreview.IsShown()
        local accent = F.GetAccentColor()
        if active then
            previewBtn:SetBackdropColor(accent.r, accent.g, accent.b, 0.55)
            previewText:SetText(L["Hide Preview"] or "Hide Preview")
        else
            previewBtn:SetBackdropColor(0.115, 0.115, 0.115, 1)
            previewText:SetText(L["Show Preview"] or "Show Preview")
        end
    end

    previewBtn:SetScript("OnClick", function()
        local GroupPreview = SquizzFrames.GroupPreview
        if not (GroupPreview and GroupPreview.Toggle) then return end
        -- Sync to the tab being edited before showing, so opening it never
        -- flashes the other group type first.
        GroupPreview.SetRaidMode(activeLayoutKey == "raid")
        GroupPreview.Toggle()
    end)
    RefreshPreviewButtonVisual()

    -- Driven by the message rather than set inline, so this stays correct when
    -- the window is closed from somewhere else -- its own X, the Indicators
    -- tab's toggle, or the options panel hiding.
    F.NewMessageOwner():RegisterMessage("GroupPreviewToggled", RefreshPreviewButtonVisual)

    rebuildLayoutFields = function() BuildLayoutFields(frame) end
    rebuildLayoutFields()

    -- Re-sync every slider/dropdown/checkbox's displayed value whenever the
    -- active profile changes (switch/copy/reset) -- BuildLayoutFields was
    -- already rebuild-safe (the Party/Raid toggle already calls it), it
    -- just wasn't wired to this message before.
    F.NewMessageOwner():RegisterMessage("ProfileChanged", function() rebuildLayoutFields() end)
end

-----------------------------------------------------------------------
-- Profiles Page
-----------------------------------------------------------------------
-- ProfileStore.lua (2026-08-06, replaces AceDB-3.0 entirely) stores every
-- tab's settings under db.profile (layout, appearance, indicators, click-
-- casting -- literally everything the other pages read/write), and
-- PartyFrames/ClickCasting/Indicators all already listen for the
-- "ProfileChanged" message Core.lua's RefreshProfile fires on every
-- SetProfile/CopyProfile/RenameProfile/ResetProfile call. So switching/
-- copying/renaming/resetting a profile applies live across every tab with
-- zero extra wiring. Every brand-new character still gets their own
-- profile from the very first login (mirrors AceDB's old native default),
-- seeded from "Default" -- see ProfileStore.lua's Init for the full
-- per-character seed logic.
local function BuildProfilesFields(frame)
    if frame.fieldsHost then
        frame.fieldsHost:Hide()
        frame.fieldsHost:SetParent(nil)
        frame.fieldsHost = nil
    end

    local fieldsHost = CreateFrame("Frame", nil, frame)
    fieldsHost:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    fieldsHost:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    frame.fieldsHost = fieldsHost

    local db = SquizzFrames.db
    local yOffset = -10

    local function Rebuild() BuildProfilesFields(frame) end

    -- Section: Current Profile
    W.CreateTitledPane(fieldsHost, L["Current Profile"] or "Current Profile", yOffset)
    yOffset = yOffset - 35

    local current = fieldsHost:CreateFontString(nil, "OVERLAY")
    current:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
    current:SetPoint("TOPLEFT", 15, yOffset)
    do
        local a = F.GetAccentColor()
        current:SetTextColor(a.r, a.g, a.b, 1)
    end
    current:SetText(db and db:GetCurrentProfile() or "?")
    yOffset = yOffset - 30

    -- Section: Switch Profile
    W.CreateTitledPane(fieldsHost, L["Switch Profile"] or "Switch Profile", yOffset)
    yOffset = yOffset - 35

    local profileNames = db and db:GetProfiles() or {}
    table.sort(profileNames)
    local switchItems = {}
    for _, name in ipairs(profileNames) do
        table.insert(switchItems, { value = name, text = name })
    end
    local switchDD = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Profile"] or "Profile", switchItems,
        function() return db and db:GetCurrentProfile() end,
        function(name)
            if db and name and name ~= db:GetCurrentProfile() then
                db:SetProfile(name)
            end
            Rebuild()
        end)
    switchDD:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 70

    -- Section: Save to Default -- Default is what every new profile (and
    -- every new character, per ProfileStore.lua's Init) starts from, so
    -- this is the one-click way to promote whatever you've tuned on your
    -- CURRENT profile into that shared baseline, without switching off the
    -- profile you're actively editing.
    W.CreateTitledPane(fieldsHost, L["Save to Default"] or "Save to Default", yOffset)
    yOffset = yOffset - 35

    -- Default is a deliberately STABLE template (per explicit user
    -- preference: many people, including the one who asked for this, like
    -- to keep Default trimmed down to a bare-minimum starting point) --
    -- it never picks up changes just from being the active profile, even
    -- while you're actively on it. ProfileStore.lua's DB:CommitDraft(): while
    -- on Default, db.profile is a draft copy, never linked into the saved
    -- variable at all -- edits apply live on screen as normal, but nothing
    -- reaches disk until Save is clicked.
    local isOnDefault = db and db:GetCurrentProfile() == "Default"
    if isOnDefault then
        local desc = fieldsHost:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        desc:SetPoint("TOPLEFT", 15, yOffset - 10)
        desc:SetWidth(420)
        desc:SetJustifyH("LEFT")
        desc:SetText(L["Changes preview live, but nothing saves permanently until you click Save -- otherwise they're lost the next time you switch away, reload, or log out."]
            or "Changes preview live, but nothing saves permanently until you click Save -- otherwise they're lost the next time you switch away, reload, or log out.")
        yOffset = yOffset - 50

        local saveBtn
        saveBtn = W.CreateStyledButton(fieldsHost, L["Save"] or "Save", "accent-hover", {180, 22}, function()
            if db then db:CommitDraft() end
        end)
        saveBtn:SetPoint("TOPLEFT", 15, yOffset - 5)
        yOffset = yOffset - 45
    else
        local desc = fieldsHost:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        desc:SetPoint("TOPLEFT", 15, yOffset - 10)
        desc:SetWidth(420)
        desc:SetJustifyH("LEFT")
        desc:SetText(L["Overwrite the Default profile with your CURRENT profile's settings, so new profiles (and new characters) start from this setup."]
            or "Overwrite the Default profile with your CURRENT profile's settings, so new profiles (and new characters) start from this setup.")
        yOffset = yOffset - 35

        local armed = false
        local saveBtn
        saveBtn = W.CreateStyledButton(fieldsHost, L["Save to Default..."] or "Save to Default...", "accent-hover", {180, 22}, function()
            if not db then return end
            if not armed then
                armed = true
                saveBtn.fontString:SetText(L["Click again to confirm"] or "Click again to confirm")
                return
            end
            db:SaveCurrentAsDefault()
            armed = false
            saveBtn.fontString:SetText(L["Save to Default..."] or "Save to Default...")
        end)
        saveBtn:SetPoint("TOPLEFT", 15, yOffset - 5)
        yOffset = yOffset - 45
    end

    -- Section: Rename Profile (new capability -- the old AceDB-backed page
    -- had no rename, the pattern was duplicate-under-new-name + delete-old).
    W.CreateTitledPane(fieldsHost, L["Rename Profile"] or "Rename Profile", yOffset)
    yOffset = yOffset - 35

    if isOnDefault then
        local msg = fieldsHost:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        msg:SetPoint("TOPLEFT", 15, yOffset - 10)
        msg:SetText(L["Default can't be renamed."] or "Default can't be renamed.")
        yOffset = yOffset - 40
    else
        local renameBox = CreateFrame("EditBox", nil, fieldsHost, "InputBoxTemplate")
        renameBox:SetSize(150, 20)
        renameBox:SetPoint("TOPLEFT", 20, yOffset)
        renameBox:SetAutoFocus(false)
        renameBox:SetText(db and db:GetCurrentProfile() or "")

        local function DoRename()
            if not db then return end
            local newName = renameBox:GetText()
            newName = newName and newName:match("^%s*(.-)%s*$") or ""
            local oldName = db:GetCurrentProfile()
            if newName == "" or newName == oldName then return end
            db:RenameProfile(oldName, newName)
            Rebuild()
        end
        renameBox:SetScript("OnEnterPressed", function(self) DoRename(); self:ClearFocus() end)

        local renameBtn = W.CreateStyledButton(fieldsHost, L["Rename"] or "Rename", "accent-hover", {80, 20}, DoRename)
        renameBtn:SetPoint("LEFT", renameBox, "RIGHT", 10, 0)
        yOffset = yOffset - 40
    end

    -- Section: New Profile
    W.CreateTitledPane(fieldsHost, L["New Profile"] or "New Profile", yOffset)
    yOffset = yOffset - 35

    local newBox = CreateFrame("EditBox", nil, fieldsHost, "InputBoxTemplate")
    newBox:SetSize(150, 20)
    newBox:SetPoint("TOPLEFT", 20, yOffset)
    newBox:SetAutoFocus(false)
    yOffset = yOffset - 5

    local function CreateNewProfile()
        local name = newBox:GetText()
        name = name and name:match("^%s*(.-)%s*$") or ""
        if name == "" or not db then return end
        db:SetProfile(name)
        newBox:SetText("")
        newBox:ClearFocus()
        Rebuild()
    end
    newBox:SetScript("OnEnterPressed", function(self) CreateNewProfile(); self:ClearFocus() end)

    local createBtn = W.CreateStyledButton(fieldsHost, L["Create"] or "Create", "accent-hover", {80, 20}, CreateNewProfile)
    createBtn:SetPoint("LEFT", newBox, "RIGHT", 10, 0)
    yOffset = yOffset - 40

    -- Section: Copy Settings From
    W.CreateTitledPane(fieldsHost, L["Copy Settings From"] or "Copy Settings From", yOffset)
    yOffset = yOffset - 35

    local otherNames = {}
    for _, name in ipairs(profileNames) do
        if not db or name ~= db:GetCurrentProfile() then
            table.insert(otherNames, name)
        end
    end

    if #otherNames == 0 then
        local msg = fieldsHost:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        msg:SetPoint("TOPLEFT", 15, yOffset - 10)
        msg:SetText(L["No other profiles exist yet."] or "No other profiles exist yet.")
        yOffset = yOffset - 40
    else
        local copySource = otherNames[1]
        local copyItems = {}
        for _, name in ipairs(otherNames) do
            table.insert(copyItems, { value = name, text = name })
        end
        local copyDD = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Source Profile"] or "Source Profile", copyItems,
            function() return copySource end,
            function(name) copySource = name end)
        copyDD:SetPoint("TOPLEFT", 15, yOffset - 20)

        local copyBtn = W.CreateStyledButton(fieldsHost, L["Copy Into Current"] or "Copy Into Current", "accent-hover", {150, 22}, function()
            if db and copySource then
                -- No explicit Rebuild() here (2026-08-07): CopyProfile ends
                -- in RefreshProfile -> "ProfileChanged", which this page now
                -- correctly receives, and it fires at the right TIME -- in
                -- combat the copy is queued to combat-end, so rebuilding
                -- immediately would just re-render the pre-copy state.
                db:CopyProfile(copySource)
            end
        end)
        copyBtn:SetPoint("LEFT", copyDD, "RIGHT", 10, -10)
        yOffset = yOffset - 70
    end

    -- Section: Delete Profile. "Default" is unconditionally excluded --
    -- ProfileStore.lua's DB:DeleteProfile refuses it too (it's the template
    -- new characters/profiles seed from), so it's never offered here at all.
    W.CreateTitledPane(fieldsHost, L["Delete Profile"] or "Delete Profile", yOffset)
    yOffset = yOffset - 35

    local deletableNames = {}
    for _, name in ipairs(otherNames) do
        if name ~= "Default" then
            table.insert(deletableNames, name)
        end
    end

    if #deletableNames == 0 then
        local msg = fieldsHost:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        msg:SetPoint("TOPLEFT", 15, yOffset - 10)
        msg:SetText(L["No other profiles to delete (the active profile and Default can't be deleted)."]
            or "No other profiles to delete (the active profile and Default can't be deleted).")
        yOffset = yOffset - 40
    else
        local deleteTarget = deletableNames[1]
        local deleteItems = {}
        for _, name in ipairs(deletableNames) do
            table.insert(deleteItems, { value = name, text = name })
        end
        local deleteDD = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Profile"] or "Profile", deleteItems,
            function() return deleteTarget end,
            function(name) deleteTarget = name end)
        deleteDD:SetPoint("TOPLEFT", 15, yOffset - 20)

        -- Two-step arm/confirm on the same button (no separate popup) --
        -- deleting a profile is destructive and irreversible, but a full
        -- modal dialog felt heavier than this needs; a click-to-arm,
        -- click-again-to-confirm button is the same "are you sure" gate
        -- with none of that overhead.
        local armed = false
        local deleteBtn
        deleteBtn = W.CreateStyledButton(fieldsHost, L["Delete..."] or "Delete...", "red-hover", {150, 22}, function()
            if not db or not deleteTarget then return end
            if not armed then
                armed = true
                deleteBtn.fontString:SetText(L["Click again to confirm"] or "Click again to confirm")
                return
            end
            -- No explicit Rebuild() -- DeleteProfile refreshes this page
            -- from inside its own combat-guarded action, so the list updates
            -- when the deletion actually happens rather than before it.
            db:DeleteProfile(deleteTarget)
        end)
        deleteBtn:SetPoint("LEFT", deleteDD, "RIGHT", 10, -10)
        -- Matches Copy Settings From's own closing gap (-70) -- both
        -- sections place their dropdown the same way (a CreateStyledDropdown
        -- container, itself ~40px tall, anchored an ADDITIONAL 20px below
        -- this section's own title gap), so both need the same total
        -- clearance before the next section's title. This used to be the
        -- last section on the page, so falling short of that (the old -45)
        -- never actually clipped anything -- it started overlapping only
        -- once Spec Profiles was added directly below it.
        yOffset = yOffset - 70
    end

    -- Section: Auto-Switch (Spec x Situation) -- auto-switches db:SetProfile()
    -- on spec change AND group-composition change (see Core.lua's
    -- HandleSpecProfileSwitch/UpdateGroupType/UpdateSpec). Off by default:
    -- this is opt-in, since silently switching profiles out from under
    -- someone who never asked for it would be surprising.
    W.CreateTitledPane(fieldsHost, L["Auto-Switch (Spec x Situation)"] or "Auto-Switch (Spec x Situation)", yOffset)
    yOffset = yOffset - 35

    local function GetSpecSwitchEnabled() return db and db.autoSwitch and db.autoSwitch.enabled end
    local function SetSpecSwitchEnabled(checked)
        if not db or not db.autoSwitch then return end
        db.autoSwitch.enabled = checked
        Rebuild()
    end
    local specCB = W.CreateStyledCheckbox(fieldsHost, L["Switch profile by specialization and situation"] or "Switch profile by specialization and situation",
        GetSpecSwitchEnabled, SetSpecSwitchEnabled)
    specCB:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 30

    if GetSpecSwitchEnabled() then
        -- Used to call GetNumSpecializations/GetSpecializationInfo directly.
        -- Both are gone on 12.1, and the existence guard around them meant
        -- this silently rendered the "no specializations found" note instead
        -- of erroring -- so the auto-switch mapping simply could not be
        -- configured. F.GetPlayerSpecList owns the C_SpecializationInfo
        -- compat (and sidesteps GetNumSpecializations having no drop-in
        -- replacement by walking the slots). The empty case still renders
        -- the note, which is now a real "this class has no specs" answer.
        local specs = (F and F.GetPlayerSpecList and F.GetPlayerSpecList()) or {}
        if #specs == 0 then
            local msg = fieldsHost:CreateFontString(nil, "OVERLAY", "GameFontDisable")
            msg:SetPoint("TOPLEFT", 15, yOffset - 5)
            msg:SetText(L["No specializations found for this class."] or "No specializations found for this class.")
            yOffset = yOffset - 30
        else
            -- Column headers (Solo/Party/Raid), matching the 3-column
            -- x=130/255/380 layout the per-spec rows below use.
            local situationCols = {
                {key = "solo",  label = L["Solo"] or "Solo"},
                {key = "party", label = L["Party"] or "Party"},
                {key = "raid",  label = L["Raid"] or "Raid"},
            }
            for i, col in ipairs(situationCols) do
                local head = fieldsHost:CreateFontString(nil, "OVERLAY")
                head:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
                head:SetPoint("TOPLEFT", 130 + (i - 1) * 125, yOffset)
                head:SetTextColor(0.7, 0.7, 0.7, 1)
                head:SetText(col.label)
            end
            yOffset = yOffset - 20

            for i, spec in ipairs(specs) do
                local specID, specName = spec.id, spec.name
                if specID then
                    local rowY = yOffset
                    local label = fieldsHost:CreateFontString(nil, "OVERLAY")
                    label:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
                    label:SetPoint("TOPLEFT", 15, rowY - 3)
                    label:SetWidth(110)
                    label:SetJustifyH("LEFT")
                    label:SetText(specName or ("Spec " .. i))

                    local rowItems = { { value = "", text = L["(none yet)"] or "(none yet)" } }
                    for _, pname in ipairs(profileNames) do
                        table.insert(rowItems, { value = pname, text = pname })
                    end

                    for colIndex, col in ipairs(situationCols) do
                        local situation = col.key
                        local colDD = W.CreateStyledDropdown(fieldsHost, 110, 40, nil, rowItems,
                            function()
                                local situations = db and db.autoSwitch and db.autoSwitch.map[specID]
                                return (situations and situations[situation]) or ""
                            end,
                            function(name)
                                if not db or not db.autoSwitch then return end
                                db.autoSwitch.map[specID] = db.autoSwitch.map[specID] or {}
                                if name == "" then
                                    db.autoSwitch.map[specID][situation] = nil
                                else
                                    db.autoSwitch.map[specID][situation] = name
                                end
                            end)
                        colDD:SetPoint("TOPLEFT", 130 + (colIndex - 1) * 125, rowY - 20)
                    end
                    yOffset = yOffset - 45
                end
            end
        end
    end
end

-- ------------------------------------------------------------------
-- Spec Profile prompt -- fired by Core.lua's HandleSpecProfileSwitch when
-- the current spec has no (or a stale) profile mapping, per explicit user
-- request to ask rather than silently auto-create one. Standalone dialog
-- (parented to UIParent, not any specific options tab) since a spec change
-- can happen at any time, including while the options panel is closed.
-- ------------------------------------------------------------------
local SITUATION_LABELS = { solo = "Solo", party = "Party", raid = "Raid" }
local specDialog
local function ShowSpecProfileDialog(specID, specName, situation)
    if not specID or not situation then return end
    local db = SquizzFrames.db
    if not db then return end

    if not specDialog then
        local dialog = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        dialog:SetSize(280, 190)
        dialog:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
        dialog:SetFrameStrata("DIALOG")
        dialog:SetClampedToScreen(true)
        dialog:EnableMouse(true)
        W.StylizeFrame(dialog, {0.1, 0.1, 0.1, 0.95}, {0.3, 0.7, 1, 0.8})

        dialog.title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        dialog.title:SetPoint("TOP", 0, -10)

        dialog.desc = dialog:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        dialog.desc:SetPoint("TOP", dialog.title, "BOTTOM", 0, -8)
        dialog.desc:SetWidth(dialog:GetWidth() - 30)
        dialog.desc:SetJustifyH("CENTER")
        dialog.desc:SetText(L["Pick an existing profile for this spec, or type a new name to create one."]
            or "Pick an existing profile for this spec, or type a new name to create one.")

        dialog.pickLabel = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        dialog.pickLabel:SetPoint("TOPLEFT", 15, -68)
        dialog.pickLabel:SetText(L["Existing profile"] or "Existing profile")
        dialog.pickDropdown = W.CreateStyledDropdown(dialog, 200, 40, nil, {},
            function() return dialog._picked end,
            function(name) dialog._picked = name; dialog.nameBox:SetText("") end)
        dialog.pickDropdown:SetPoint("TOPLEFT", 15, -84)

        dialog.orLabel = dialog:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        dialog.orLabel:SetPoint("TOP", 0, -122)
        dialog.orLabel:SetText(L["-- or --"] or "-- or --")

        dialog.nameBox = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
        dialog.nameBox:SetSize(dialog:GetWidth() - 40, 20)
        dialog.nameBox:SetPoint("TOP", dialog.orLabel, "BOTTOM", 0, -6)
        dialog.nameBox:SetAutoFocus(false)
        dialog.nameBox:SetScript("OnTextChanged", function(self)
            if self:GetText() ~= "" then dialog._picked = nil end
        end)

        dialog.confirmBtn = W.CreateStyledButton(dialog, L["Confirm"] or "Confirm", "accent-hover", {90, 22}, function()
            local newName = dialog.nameBox:GetText()
            newName = newName and newName:match("^%s*(.-)%s*$") or ""
            local chosen = (newName ~= "" and newName) or dialog._picked
            if not chosen or chosen == "" then return end
            if not SquizzFrames.db or not SquizzFrames.db.autoSwitch then return end
            SquizzFrames.db.autoSwitch.map[dialog._specID] = SquizzFrames.db.autoSwitch.map[dialog._specID] or {}
            SquizzFrames.db.autoSwitch.map[dialog._specID][dialog._situation] = chosen
            -- SetProfile creates the profile fresh (from registered
            -- defaults) if `chosen` doesn't exist yet -- matches the
            -- existing "New Profile" section's own behavior on this same
            -- page, so a spec+situation's first-ever profile starts the
            -- same way any other manually-created profile does.
            if SquizzFrames.db:GetCurrentProfile() ~= chosen then
                SquizzFrames.db:SetProfile(chosen)
            end
            dialog:Hide()
            if SquizzFrames.OptionsFrame_RefreshProfilesPage then SquizzFrames.OptionsFrame_RefreshProfilesPage() end
        end)
        dialog.confirmBtn:SetPoint("BOTTOMLEFT", 15, 12)

        dialog.cancelBtn = W.CreateStyledButton(dialog, L["Cancel"] or "Cancel", nil, {90, 22}, function()
            dialog:Hide()
        end)
        dialog.cancelBtn:SetPoint("BOTTOMRIGHT", -15, 12)

        specDialog = dialog
    end

    specDialog._specID = specID
    specDialog._situation = situation
    specDialog._picked = nil
    local situationLabel = L[SITUATION_LABELS[situation]] or SITUATION_LABELS[situation] or situation
    specDialog.title:SetText((L["Profile for"] or "Profile for") .. ": "
        .. (specName or ("Spec " .. tostring(specID))) .. " / " .. situationLabel)
    specDialog.nameBox:SetText("")

    local items = {}
    for _, name in ipairs(db:GetProfiles()) do
        table.insert(items, { value = name, text = name })
    end
    specDialog.pickDropdown.dropdown:RefreshItems(items)
    -- RefreshItems auto-selects the first item (dd.selectedValue) when the
    -- previous value isn't in the new list, but only updates the dropdown's
    -- own display -- it doesn't call back into setValue, so _picked (what
    -- Confirm actually reads) would stay nil until the user explicitly
    -- clicks a row. Sync it explicitly so Confirm works even if they just
    -- accept whatever's pre-selected.
    specDialog._picked = specDialog.pickDropdown.dropdown.selectedValue

    specDialog:Show()
end

SquizzFrames:RegisterMessage("SpecProfileNeeded", function(_, specID, specName, situation)
    ShowSpecProfileDialog(specID, specName, situation)
end)

local function CreateProfilesPage()
    local frame = CreateFrame("Frame", nil, scrollChild)
    frame:SetAllPoints()
    frame:Hide()
    contentFrames["profiles"] = frame

    BuildProfilesFields(frame)

    -- Keep this page in sync with profile switches that happen from
    -- OUTSIDE it -- specifically the spec-profile dialog above, which can
    -- switch profiles while this tab isn't even the one showing.
    F.NewMessageOwner():RegisterMessage("ProfileChanged", function() BuildProfilesFields(frame) end)
    SquizzFrames.OptionsFrame_RefreshProfilesPage = function() BuildProfilesFields(frame) end
end

-----------------------------------------------------------------------
-- Pet Frames Page (Phase 1 -- see the Pet Frames design plan for scope)
-----------------------------------------------------------------------

-- Independent of the Layout page's own activeLayoutKey -- Pet Frames gets
-- its own Party/Raid toggle, matching profile.petFrames.main/.raid's own
-- separate-sibling-table convention (see PetFrames_Defaults.lua).
local activePetLayoutKey = "main"
local rebuildPetFields -- forward declaration; set by CreatePetFramesPage

local function GetActivePetFrameLayout()
    local prof = GetProfile()
    return prof and prof.petFrames and prof.petFrames[activePetLayoutKey]
end

local function GetPetEnabled()
    local layout = GetActivePetFrameLayout()
    return layout and layout.enabled or false
end
local function SetPetEnabled(checked)
    local layout = GetActivePetFrameLayout()
    if layout then
        layout.enabled = checked
        SquizzFrames:Fire("PetFramesChanged")
    end
end

local function GetPetMode()
    local layout = GetActivePetFrameLayout()
    return (layout and layout.mode) or "attached"
end
local function SetPetMode(mode)
    local layout = GetActivePetFrameLayout()
    if layout then
        layout.mode = mode
        SquizzFrames:Fire("PetFramesChanged")
        if rebuildPetFields then rebuildPetFields() end
    end
end

local function GetPetWidth()
    local layout = GetActivePetFrameLayout()
    return (layout and layout.width) or 60
end
local function SetPetWidth(val)
    local layout = GetActivePetFrameLayout()
    if layout then layout.width = val; SquizzFrames:Fire("PetFramesChanged") end
end

local function GetPetMatchOwnerWidth()
    local layout = GetActivePetFrameLayout()
    return (layout and layout.matchOwnerWidth) or false
end
local function SetPetMatchOwnerWidth(checked)
    local layout = GetActivePetFrameLayout()
    if layout then
        layout.matchOwnerWidth = checked
        SquizzFrames:Fire("PetFramesChanged")
        -- Rebuild so the now-redundant Width slider disappears/returns.
        if rebuildPetFields then rebuildPetFields() end
    end
end

local function GetPetHeight()
    local layout = GetActivePetFrameLayout()
    return (layout and layout.height) or 24
end

local function GetPetMatchOwnerHeight()
    local layout = GetActivePetFrameLayout()
    return (layout and layout.matchOwnerHeight) or false
end
local function SetPetMatchOwnerHeight(checked)
    local layout = GetActivePetFrameLayout()
    if layout then
        layout.matchOwnerHeight = checked
        SquizzFrames:Fire("PetFramesChanged")
        -- Rebuild so the now-redundant Height slider disappears/returns.
        if rebuildPetFields then rebuildPetFields() end
    end
end

-----------------------------------------------------------------------
-- Pet name text
-----------------------------------------------------------------------
-- Every accessor goes through this so a profile saved before the name-text
-- settings existed gets the sub-table filled in on first touch rather than
-- erroring -- the same lazy-backfill the rest of the pet page relies on
-- EnsurePetFramesDefaults for at load time.
local function GetPetNameCfg()
    local layout = GetActivePetFrameLayout()
    if not layout then return nil end
    if not layout.nameText then
        layout.nameText = {
            enabled = true,
            font = {"Friz QT__", 10, "OUTLINE", true},
            color = {"custom_color", 1, 1, 1, 1},
            anchorPoint = "TOPLEFT",
            offsetX = 2,
            offsetY = -1,
        }
    end
    if not layout.nameText.font then
        layout.nameText.font = {"Friz QT__", 10, "OUTLINE", true}
    end
    return layout.nameText
end

local function PetNameSet(apply)
    local cfg = GetPetNameCfg()
    if not cfg then return end
    apply(cfg)
    SquizzFrames:Fire("PetFramesChanged")
end

local function GetPetNameEnabled()
    local cfg = GetPetNameCfg()
    return cfg and cfg.enabled ~= false
end
local function SetPetNameEnabled(checked)
    PetNameSet(function(cfg) cfg.enabled = checked end)
    if rebuildPetFields then rebuildPetFields() end
end

local function GetPetNameFont()
    local cfg = GetPetNameCfg()
    return (cfg and cfg.font[1]) or "Friz QT__"
end
local function SetPetNameFont(val)
    PetNameSet(function(cfg) cfg.font[1] = val end)
end

local function GetPetNameSize()
    local cfg = GetPetNameCfg()
    return (cfg and cfg.font[2]) or 10
end
local function SetPetNameSize(val)
    PetNameSet(function(cfg) cfg.font[2] = val end)
end

local function GetPetNameOutline()
    local cfg = GetPetNameCfg()
    return (cfg and cfg.font[3]) or "NONE"
end
local function SetPetNameOutline(val)
    PetNameSet(function(cfg) cfg.font[3] = val end)
end

local function GetPetNameShadow()
    local cfg = GetPetNameCfg()
    return cfg and cfg.font[4] and true or false
end
local function SetPetNameShadow(checked)
    PetNameSet(function(cfg) cfg.font[4] = checked end)
end

local function GetPetNameColor()
    local cfg = GetPetNameCfg()
    return F.ColorRGB(cfg and cfg.color or {"custom_color", 1, 1, 1, 1})
end
local function SetPetNameColor(r, g, b, a)
    PetNameSet(function(cfg) cfg.color = {"custom_color", r, g, b, a or 1} end)
end

local function GetPetNameAnchor()
    local cfg = GetPetNameCfg()
    return (cfg and cfg.anchorPoint) or "TOPLEFT"
end
local function SetPetNameAnchor(val)
    PetNameSet(function(cfg) cfg.anchorPoint = val end)
end

local function GetPetNameOffsetX()
    local cfg = GetPetNameCfg()
    return (cfg and cfg.offsetX) or 0
end
local function SetPetNameOffsetX(val)
    PetNameSet(function(cfg) cfg.offsetX = val end)
end

local function GetPetNameOffsetY()
    local cfg = GetPetNameCfg()
    return (cfg and cfg.offsetY) or 0
end
local function SetPetNameOffsetY(val)
    PetNameSet(function(cfg) cfg.offsetY = val end)
end

-- Shared with every other font picker in the addon (Utils.lua). Routed through
-- the same builder rather than querying LibSharedMedia directly so this one
-- also carries the legacy entries -- notably "Friz QT__", which is the shipped
-- default and is NOT an LSM key, so a pure LSM list showed the pet font
-- dropdown as blank on a fresh profile.
local function GetPetFontItems()
    return F.GetFontDropdownItems()
end

local PET_NAME_ANCHOR_ITEMS = {
    {value = "TOPLEFT",     text = L["Top Left"] or "Top Left"},
    {value = "TOP",         text = L["Top"] or "Top"},
    {value = "TOPRIGHT",    text = L["Top Right"] or "Top Right"},
    {value = "LEFT",        text = L["Left"] or "Left"},
    {value = "CENTER",      text = L["Center"] or "Center"},
    {value = "RIGHT",       text = L["Right"] or "Right"},
    {value = "BOTTOMLEFT",  text = L["Bottom Left"] or "Bottom Left"},
    {value = "BOTTOM",      text = L["Bottom"] or "Bottom"},
    {value = "BOTTOMRIGHT", text = L["Bottom Right"] or "Bottom Right"},
}
local function SetPetHeight(val)
    local layout = GetActivePetFrameLayout()
    if layout then layout.height = val; SquizzFrames:Fire("PetFramesChanged") end
end

local function GetPetAnchorSide()
    local layout = GetActivePetFrameLayout()
    return (layout and layout.anchorSide) or "RIGHT"
end
local function SetPetAnchorSide(val)
    local layout = GetActivePetFrameLayout()
    if layout then layout.anchorSide = val; SquizzFrames:Fire("PetFramesChanged") end
end

local function GetPetOffsetX()
    local layout = GetActivePetFrameLayout()
    return (layout and layout.offsetX) or 0
end
local function SetPetOffsetX(val)
    local layout = GetActivePetFrameLayout()
    if layout then layout.offsetX = val; SquizzFrames:Fire("PetFramesChanged") end
end

local function GetPetOffsetY()
    local layout = GetActivePetFrameLayout()
    return (layout and layout.offsetY) or 0
end
local function SetPetOffsetY(val)
    local layout = GetActivePetFrameLayout()
    if layout then layout.offsetY = val; SquizzFrames:Fire("PetFramesChanged") end
end

local function GetPetOrientation()
    local layout = GetActivePetFrameLayout()
    return (layout and layout.orientation) or "vertical"
end
local function SetPetOrientation(val)
    local layout = GetActivePetFrameLayout()
    if layout then
        layout.orientation = val
        SquizzFrames:Fire("PetFramesChanged")
        if rebuildPetFields then rebuildPetFields() end
    end
end

local function GetPetGrowthDirection()
    local layout = GetActivePetFrameLayout()
    return (layout and layout.growthDirection) or "DOWN"
end
local function SetPetGrowthDirection(val)
    local layout = GetActivePetFrameLayout()
    if layout then layout.growthDirection = val; SquizzFrames:Fire("PetFramesChanged") end
end

local function GetPetSpacing()
    local layout = GetActivePetFrameLayout()
    return (layout and layout.spacingY) or 2
end
local function SetPetSpacing(val)
    local layout = GetActivePetFrameLayout()
    if layout then layout.spacingY = val; SquizzFrames:Fire("PetFramesChanged") end
end

-- Pet Health Bar Color (2026-08-05). Single shared setting -- NOT scoped by
-- activePetLayoutKey/Party-Raid toggle, matching the main frame's own
-- Health Bar Colors section (profile.appearance.healthBar), which is also
-- appearance-wide rather than duplicated per party/raid layout.
local function GetPetHealthOwnerClassColor()
    local p = GetProfile()
    local pb = p and p.appearance and p.appearance.petHealthBar
    return pb and pb.fullColor and pb.fullColor[1] == "owner_class_color"
end
local function SetPetHealthOwnerClassColor(checked)
    local p = GetProfile()
    if p and p.appearance and p.appearance.petHealthBar then
        local pb = p.appearance.petHealthBar
        if checked then
            pb.fullColor = {"owner_class_color", "any"}
        else
            local c = pb.customColor or {0.2, 0.8, 0.2, 1}
            pb.fullColor = {"custom_color", c[1], c[2], c[3], c[4]}
        end
        SquizzFrames:Fire("PetFramesChanged")
    end
end

local function GetPetHealthCustomColor()
    local p = GetProfile()
    local pb = p and p.appearance and p.appearance.petHealthBar
    local c = pb and pb.customColor
    if c then return c[1] or 0.2, c[2] or 0.8, c[3] or 0.2, c[4] or 1 end
    return 0.2, 0.8, 0.2, 1
end
local function SetPetHealthCustomColor(r, g, b, a)
    local p = GetProfile()
    local pb = p and p.appearance and p.appearance.petHealthBar
    if pb then
        pb.customColor = {r, g, b, a}
        if pb.fullColor and pb.fullColor[1] ~= "owner_class_color" then
            pb.fullColor = {"custom_color", r, g, b, a}
            SquizzFrames:Fire("PetFramesChanged")
        end
    end
end

-- Growth-direction items, filtered by orientation -- same UP/DOWN vs.
-- LEFT/RIGHT split as the main Layout page's GetDirectionItems, but without
-- the CENTER_H/CENTER_V entries (Floating pet groups don't support center
-- growth in this phase -- see the design plan's scope cuts).
local function GetPetDirectionItems(orientation)
    if orientation == "horizontal" then
        return {
            {value = "LEFT",  text = L["Left"] or "Left"},
            {value = "RIGHT", text = L["Right"] or "Right"},
        }
    end
    return {
        {value = "UP",   text = L["Up"] or "Up"},
        {value = "DOWN", text = L["Down"] or "Down"},
    }
end

local function BuildPetFrameFields(frame)
    if frame.fieldsHost then
        frame.fieldsHost:Hide()
        frame.fieldsHost:SetParent(nil)
        frame.fieldsHost = nil
    end

    local fieldsHost = CreateFrame("Frame", nil, frame)
    fieldsHost:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -34)
    fieldsHost:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    frame.fieldsHost = fieldsHost

    local yOffset = -10

    W.CreateTitledPane(fieldsHost, L["General"] or "General", yOffset)
    yOffset = yOffset - 35

    local cbEnable = W.CreateStyledCheckbox(fieldsHost, L["Enable Pet Frames"] or "Enable Pet Frames", GetPetEnabled, SetPetEnabled)
    cbEnable:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 35

    W.CreateTitledPane(fieldsHost, L["Sizing"] or "Sizing", yOffset)
    yOffset = yOffset - 35

    -- Only offered in attached mode: a floating pet group is detached from the
    -- party frames entirely, so there's no owner beside it for the size to
    -- read as "matching" (ResolvePetSize ignores the settings there too).
    local attached = GetPetMode() == "attached"
    if attached then
        local cbMatchW = W.CreateStyledCheckbox(fieldsHost,
            L["Match Owner Width"] or "Match Owner Width",
            GetPetMatchOwnerWidth, SetPetMatchOwnerWidth)
        cbMatchW:SetPoint("TOPLEFT", 15, yOffset)
        yOffset = yOffset - 30

        local cbMatchH = W.CreateStyledCheckbox(fieldsHost,
            L["Match Owner Height"] or "Match Owner Height",
            GetPetMatchOwnerHeight, SetPetMatchOwnerHeight)
        cbMatchH:SetPoint("TOPLEFT", 15, yOffset)
        yOffset = yOffset - 30
    end

    -- Each slider is hidden while its own match is on, rather than shown but
    -- ignored: a live slider that visibly does nothing is the exact silent
    -- no-op this codebase keeps getting bitten by. The two are independent, so
    -- matching width still leaves Height adjustable and vice versa.
    if not (attached and GetPetMatchOwnerWidth()) then
        local sliderW = W.CreateStyledSlider(fieldsHost, 200, 12, 150, 1, L["Width"] or "Width", GetPetWidth, SetPetWidth)
        sliderW:SetPoint("TOPLEFT", 15, yOffset - 20)
        yOffset = yOffset - 65
    end

    if not (attached and GetPetMatchOwnerHeight()) then
        local sliderH = W.CreateStyledSlider(fieldsHost, 200, 8, 80, 1, L["Height"] or "Height", GetPetHeight, SetPetHeight)
        sliderH:SetPoint("TOPLEFT", 15, yOffset - 20)
        yOffset = yOffset - 65
    end

    W.CreateTitledPane(fieldsHost, L["Name Text"] or "Name Text", yOffset)
    yOffset = yOffset - 35

    local cbName = W.CreateStyledCheckbox(fieldsHost, L["Show Name"] or "Show Name",
        GetPetNameEnabled, SetPetNameEnabled)
    cbName:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 30

    if GetPetNameEnabled() then
        local ddFont = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Font"] or "Font",
            GetPetFontItems(), GetPetNameFont, SetPetNameFont)
        ddFont:SetPoint("TOPLEFT", 15, yOffset - 20)
        yOffset = yOffset - 70

        local sliderSize = W.CreateStyledSlider(fieldsHost, 200, 4, 24, 1, L["Size"] or "Size",
            GetPetNameSize, SetPetNameSize)
        sliderSize:SetPoint("TOPLEFT", 15, yOffset - 20)
        yOffset = yOffset - 65

        local ddOutline = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Outline"] or "Outline", {
            {value = "NONE",         text = L["None"] or "None"},
            {value = "OUTLINE",      text = L["Outline"] or "Outline"},
            {value = "THICKOUTLINE", text = L["Thick Outline"] or "Thick Outline"},
        }, GetPetNameOutline, SetPetNameOutline)
        ddOutline:SetPoint("TOPLEFT", 15, yOffset - 20)
        yOffset = yOffset - 70

        local cbShadow = W.CreateStyledCheckbox(fieldsHost, L["Shadow"] or "Shadow",
            GetPetNameShadow, SetPetNameShadow)
        cbShadow:SetPoint("TOPLEFT", 15, yOffset)
        yOffset = yOffset - 30

        local namePicker = W.CreateColorPicker(fieldsHost, L["Color"] or "Color",
            GetPetNameColor, SetPetNameColor)
        namePicker:SetPoint("TOPLEFT", 15, yOffset)
        yOffset = yOffset - 30

        local ddAnchor = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Anchor"] or "Anchor",
            PET_NAME_ANCHOR_ITEMS, GetPetNameAnchor, SetPetNameAnchor)
        ddAnchor:SetPoint("TOPLEFT", 15, yOffset - 20)
        yOffset = yOffset - 70

        local sliderNX = W.CreateStyledSlider(fieldsHost, 200, -50, 50, 1, L["Offset X"] or "Offset X",
            GetPetNameOffsetX, SetPetNameOffsetX)
        sliderNX:SetPoint("TOPLEFT", 15, yOffset - 20)
        yOffset = yOffset - 65

        local sliderNY = W.CreateStyledSlider(fieldsHost, 200, -50, 50, 1, L["Offset Y"] or "Offset Y",
            GetPetNameOffsetY, SetPetNameOffsetY)
        sliderNY:SetPoint("TOPLEFT", 15, yOffset - 20)
        yOffset = yOffset - 65
    end

    -- Health Bar Color -- single shared setting (not affected by the
    -- Party/Raid toggle above), matching the main Layout page's own Health
    -- Bar Colors section (profile.appearance.healthBar).
    W.CreateTitledPane(fieldsHost, L["Health Bar Color"] or "Health Bar Color", yOffset)
    yOffset = yOffset - 35

    local cbOwnerClass = W.CreateStyledCheckbox(fieldsHost, L["Use Owner's Class Color"] or "Use Owner's Class Color",
        GetPetHealthOwnerClassColor, SetPetHealthOwnerClassColor)
    cbOwnerClass:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    local petHealthColorPicker = W.CreateColorPicker(fieldsHost, L["Custom Color"] or "Custom Color",
        GetPetHealthCustomColor, SetPetHealthCustomColor)
    petHealthColorPicker:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 30

    W.CreateTitledPane(fieldsHost, L["Positioning"] or "Positioning", yOffset)
    yOffset = yOffset - 35

    local modeSwitch = W.CreateStyledSwitch(fieldsHost, 200, 22,
        L["Attached"] or "Attached", L["Floating"] or "Floating",
        GetPetMode, SetPetMode, "attached", "floating")
    modeSwitch:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 35

    if GetPetMode() == "floating" then
        local ddOrient = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Orientation"] or "Orientation", {
            {value = "vertical",   text = L["Vertical"] or "Vertical"},
            {value = "horizontal", text = L["Horizontal"] or "Horizontal"},
        }, GetPetOrientation, SetPetOrientation)
        ddOrient:SetPoint("TOPLEFT", 15, yOffset - 20)
        yOffset = yOffset - 70

        local ddGrowth = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Growth Direction"] or "Growth Direction",
            GetPetDirectionItems(GetPetOrientation()), GetPetGrowthDirection, SetPetGrowthDirection)
        ddGrowth:SetPoint("TOPLEFT", 15, yOffset - 20)
        yOffset = yOffset - 70

        local sliderSpacing = W.CreateStyledSlider(fieldsHost, 200, 0, 20, 1, L["Spacing"] or "Spacing", GetPetSpacing, SetPetSpacing)
        sliderSpacing:SetPoint("TOPLEFT", 15, yOffset - 20)
        yOffset = yOffset - 65

        local floatingLabel = fieldsHost:CreateFontString(nil, "OVERLAY")
        floatingLabel:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        floatingLabel:SetPoint("TOPLEFT", 15, yOffset)
        floatingLabel:SetTextColor(0.7, 0.7, 0.7, 1)
        floatingLabel:SetText(L["Drag the floating pet group in Edit Mode to position it."]
            or "Drag the floating pet group in Edit Mode to position it.")
        yOffset = yOffset - 25
    else
        local ddSide = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Anchor Side"] or "Anchor Side", {
            {value = "LEFT",   text = L["Left"] or "Left"},
            {value = "RIGHT",  text = L["Right"] or "Right"},
            {value = "TOP",    text = L["Top"] or "Top"},
            {value = "BOTTOM", text = L["Bottom"] or "Bottom"},
        }, GetPetAnchorSide, SetPetAnchorSide)
        ddSide:SetPoint("TOPLEFT", 15, yOffset - 20)
        yOffset = yOffset - 70

        local sliderOffX = W.CreateStyledSlider(fieldsHost, 200, -50, 50, 1, L["Offset X"] or "Offset X", GetPetOffsetX, SetPetOffsetX)
        sliderOffX:SetPoint("TOPLEFT", 15, yOffset - 20)
        yOffset = yOffset - 65

        local sliderOffY = W.CreateStyledSlider(fieldsHost, 200, -50, 50, 1, L["Offset Y"] or "Offset Y", GetPetOffsetY, SetPetOffsetY)
        sliderOffY:SetPoint("TOPLEFT", 15, yOffset - 20)
        yOffset = yOffset - 65
    end
end

local function CreatePetFramesPage()
    local frame = CreateFrame("Frame", nil, scrollChild)
    frame:SetAllPoints()
    frame:Hide()
    contentFrames["petFrames"] = frame

    local toggleButtons = {}
    local function RefreshToggleVisual()
        local accent = F.GetAccentColor()
        for key, btn in pairs(toggleButtons) do
            if key == activePetLayoutKey then
                btn:SetBackdropColor(accent.r, accent.g, accent.b, 0.55)
            else
                btn:SetBackdropColor(0.115, 0.115, 0.115, 1)
            end
        end
    end

    local function MakeToggleButton(key, label, xOff)
        local btn = CreateFrame("Button", nil, frame, "BackdropTemplate")
        btn:SetSize(90, 22)
        btn:SetPoint("TOPLEFT", frame, "TOPLEFT", xOff, -6)
        W.StylizeFrame(btn, {0.115, 0.115, 0.115, 1}, {0, 0, 0, 0})
        local text = btn:CreateFontString(nil, "OVERLAY")
        text:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        text:SetPoint("CENTER")
        text:SetText(label)
        btn:SetScript("OnClick", function()
            if activePetLayoutKey == key then return end
            activePetLayoutKey = key
            RefreshToggleVisual()
            if rebuildPetFields then rebuildPetFields() end
        end)
        toggleButtons[key] = btn
        return btn
    end

    MakeToggleButton("main", L["Party"] or "Party", 15)
    MakeToggleButton("raid", L["Raid"] or "Raid", 110)
    RefreshToggleVisual()

    rebuildPetFields = function() BuildPetFrameFields(frame) end
    rebuildPetFields()

    F.NewMessageOwner():RegisterMessage("ProfileChanged", function() rebuildPetFields() end)
end

-----------------------------------------------------------------------
-- Click Casting Page
-----------------------------------------------------------------------

local function CreateClickCastingPage()
    local frame = CreateFrame("Frame", nil, scrollChild)
    frame:SetAllPoints()
    frame:Hide()
    contentFrames["clickCasting"] = frame

    if SquizzFrames.ClickCastingPanel and SquizzFrames.ClickCastingPanel.Build then
        SquizzFrames.ClickCastingPanel.Build(frame)
    else
        local msg = frame:CreateFontString(nil, "OVERLAY", "GameFontRed")
        msg:SetPoint("CENTER")
        msg:SetText("ClickCasting module not loaded.")
    end
end

-----------------------------------------------------------------------
-- Indicators page: preview + list + settings, all built by IndicatorsPanel.lua
-----------------------------------------------------------------------

local function CreateIndicatorsPage()
    local frame = CreateFrame("Frame", nil, indicatorsHost)
    frame:SetAllPoints()
    frame:Hide()
    contentFrames["indicators"] = frame

    if SquizzFrames.IndicatorsPanel and SquizzFrames.IndicatorsPanel.Build then
        SquizzFrames.IndicatorsPanel.Build(frame, optionsFrame)
    else
        local msg = frame:CreateFontString(nil, "OVERLAY", "GameFontRed")
        msg:SetPoint("CENTER")
        msg:SetText("Indicators module not loaded.")
    end
end

-----------------------------------------------------------------------
-- Nicknames Page
-----------------------------------------------------------------------

local function CreateNicknamesPage()
    local frame = CreateFrame("Frame", nil, scrollChild)
    frame:SetAllPoints()
    frame:Hide()
    contentFrames["nicknames"] = frame

    if SquizzFrames.NicknamesPanel and SquizzFrames.NicknamesPanel.Build then
        SquizzFrames.NicknamesPanel.Build(frame)
        -- The same data is reachable from /sf nick, so the page can be stale
        -- by the time it's reopened -- rebuild on show rather than trusting
        -- the panel to have observed every external change.
        frame:HookScript("OnShow", function()
            SquizzFrames.NicknamesPanel.Refresh()
        end)
    else
        local msg = frame:CreateFontString(nil, "OVERLAY", "GameFontRed")
        msg:SetPoint("CENTER")
        msg:SetText("Nicknames module not loaded.")
    end
end

-----------------------------------------------------------------------
-- Toggle / Open
-----------------------------------------------------------------------

local function ToggleOptions()
    if not optionsFrame then
        CreateOptionsFrame()
        CreateGeneralPage()
        CreateLayoutPage()
        CreatePetFramesPage()
        CreateClickCastingPage()
        CreateIndicatorsPage()
        CreateNicknamesPage()
        CreateProfilesPage()
    end

    if optionsFrame:IsShown() then
        optionsFrame:Hide()
    else
        optionsFrame:Show()
        optionsFrame:Raise()
        ShowPage("general")
    end
end

-----------------------------------------------------------------------
-- First-run welcome (shown once, ever)
-----------------------------------------------------------------------
-- A brand-new user currently lands on fully default frames with no hint
-- that /sf exists or that a healer preset is one click away. This is a
-- single, dismissible prompt -- modelled on EllesmereUI's own one-shot
-- first-install popup -- gated on a flag in the ACCOUNT-WIDE store
-- (SquizzFramesDB) rather than the profile, so it can't reappear by
-- switching or resetting a profile.
local firstRunFrame
local function ShowFirstRunPopup()
    if firstRunFrame then firstRunFrame:Show() return end

    local dialog = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    -- 390 wide: the three buttons below are chained left-to-right and need
    -- 150 + 110 + 70 plus gaps/margins. At the original 360 they overlapped
    -- (each was anchored to a different corner, so nothing accounted for
    -- their combined width).
    dialog:SetSize(390, 200)
    dialog:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    dialog:SetFrameStrata("DIALOG")
    dialog:SetClampedToScreen(true)
    dialog:EnableMouse(true)
    W.StylizeFrame(dialog, {0.1, 0.1, 0.1, 0.95}, {0.3, 0.7, 1, 0.8})

    dialog.title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    dialog.title:SetPoint("TOP", 0, -14)
    dialog.title:SetText("Welcome to SquizzFrames")

    dialog.desc = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    dialog.desc:SetPoint("TOP", dialog.title, "BOTTOM", 0, -10)
    dialog.desc:SetWidth(dialog:GetWidth() - 40)
    dialog.desc:SetJustifyH("LEFT")
    dialog.desc:SetText("Your party frames are ready to go.\n\nType |cff33cc99/sf|r any time to open the options, where you can change layout, indicators, click-casting and profiles.\n\nHealing? The healer preset turns on the indicators most healers want.")

    local presetBtn = W.CreateStyledButton(dialog, "Apply Healer Preset", "accent-hover", {150, 22}, function()
        if SquizzFrames.ApplyHealerPreset then SquizzFrames.ApplyHealerPreset() end
        dialog:Hide()
    end)
    presetBtn:SetPoint("BOTTOMLEFT", 15, 14)

    -- Chained off each other rather than anchored to separate corners, so
    -- they physically cannot overlap regardless of button/dialog width.
    local openBtn = W.CreateStyledButton(dialog, "Open Options", nil, {110, 22}, function()
        dialog:Hide()
        ToggleOptions()
    end)
    openBtn:SetPoint("LEFT", presetBtn, "RIGHT", 8, 0)

    local closeBtn = W.CreateStyledButton(dialog, "Close", nil, {70, 22}, function()
        dialog:Hide()
    end)
    closeBtn:SetPoint("LEFT", openBtn, "RIGHT", 8, 0)

    firstRunFrame = dialog
    dialog:Show()
end

do
    local firstRunOwner = F.NewMessageOwner()
    firstRunOwner:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        -- Only ever once: unregister immediately so zoning doesn't re-check.
        firstRunOwner:UnregisterEvent("PLAYER_ENTERING_WORLD")
        local sv = _G["SquizzFramesDB"]
        if not sv or sv.firstRunShown then return end
        sv.firstRunShown = true
        -- Slight delay so it lands after the frames themselves are up,
        -- rather than competing with login UI churn.
        C_Timer.After(3, ShowFirstRunPopup)
    end)
end

-----------------------------------------------------------------------
-- Public API
-----------------------------------------------------------------------

SquizzFrames.ToggleOptions = ToggleOptions
