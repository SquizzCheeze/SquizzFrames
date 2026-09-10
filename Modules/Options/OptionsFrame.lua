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
local currentPageId       -- currently shown pageId (functions can't hold fields)

-- Sidebar navigation model.
-- Appearance was merged into Layout (layout and appearance settings go
-- hand in hand) -- see BuildLayoutFields' "Appearance" section.
local NAV_ITEMS = {
    {id = "general",      label = "General"},
    {id = "layout",       label = "Layout"},
    {id = "petFrames",    label = "Pet Frames"},
    {id = "unitFrames",   label = "Unit Frames"},
    {id = "clickCasting", label = "Click Casting"},
    {id = "indicators",   label = "Indicators"},
    {id = "tankTracker",  label = "Tank Tracker"},
    {id = "nicknames",    label = "Nicknames"},
    {id = "profiles",     label = "Profiles"},
}

-- Fixed content heights per simple page (content can exceed; scrolls if
-- needed). Indicators pages manage their own layout and aren't part of this.
local pageHeights = {
    ["general"] = 220, -- -30: Edit Mode's button moved to the title bar
    ["layout"] = 1615, -- +280 Health Gradient group above Health Bar Colors
    ["petFrames"] = 1090, -- +490 for the Name Text section
    ["unitFrames"] = 1450, -- one section at a time; Colors/Text are the tallest
    ["clickCasting"] = 460,
    ["tankTracker"] = 2100, -- both icon rows expanded, incl. duration/stack anchors + offsets
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
-- Edit mode toggle (shared)
-----------------------------------------------------------------------

-- Edit mode lives in the TITLE BAR rather than on the General page, so it's
-- reachable from every tab -- you're usually on Layout or Indicators when you
-- want to nudge the frames, and having to navigate back to General to get out
-- of edit mode was the whole complaint. Closing the panel also leaves edit
-- mode (see the OnHide below): the toggle is only visible while the panel is
-- open, so leaving it on after closing meant the only way back out was to
-- reopen the panel just to click it again.
--
-- Every button that displays edit-mode state registers a refresher here, so
-- they can't drift from each other or from SquizzFrames.editMode -- which
-- also gets toggled from outside this file (Lock Frames, the combat
-- auto-disable in PartyFrames.lua).
local editModeRefreshers = {}

local function RefreshEditModeButtons()
    for _, fn in ipairs(editModeRefreshers) do fn() end
end

-- The single write path for edit-mode state. Pass nil to toggle.
local function SetEditModeEnabled(enabled)
    if enabled == nil then enabled = not SquizzFrames.editMode end
    enabled = enabled and true or false
    if SquizzFrames.editMode == enabled then
        RefreshEditModeButtons()
        return
    end
    SquizzFrames.editMode = enabled
    -- Direct call to PartyFrames module (bypasses the AceEvent message bridge,
    -- which can fail to deliver in some load-order scenarios). PetFrames and
    -- anything else still pick it up from the message below.
    local partyModule = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    if partyModule and partyModule.SetEditMode then
        partyModule:SetEditMode(enabled)
    end
    SquizzFrames:Fire("EditModeChanged", enabled)
    RefreshEditModeButtons()
end

-- Applies the on/off look to a styled button used as an edit-mode toggle, and
-- registers it for future refreshes. Shared by the title-bar button and any
-- other surface that wants to show the same state.
local function WireEditModeButton(btn)
    local function Refresh()
        if SquizzFrames.editMode then
            local a = F.GetAccentColor()
            btn:SetBackdropColor(a.r, a.g, a.b, 0.5)
            btn.fontString:SetTextColor(1, 1, 1, 1)
        else
            btn:SetBackdropColor(0.115, 0.115, 0.115, 1)
            btn.fontString:SetTextColor(0.7, 0.7, 0.7, 1)
        end
    end
    btn:SetScript("OnClick", function() SetEditModeEnabled(nil) end)
    -- CreateStyledButton's own OnLeave restores its *normal* colour, which
    -- wiped the lit "edit mode is on" backdrop the moment the cursor moved
    -- off the button. Re-assert state instead. (This was already wrong on the
    -- old General-page button; it just mattered less there than it does two
    -- pixels from the close button, which you hover constantly.)
    btn:SetScript("OnLeave", function() Refresh() end)
    editModeRefreshers[#editModeRefreshers + 1] = Refresh
    Refresh()
    return Refresh
end

-- Keep the toggle's look correct when edit mode changes from OUTSIDE this file
-- -- Lock Frames turning it off, or PartyFrames' combat auto-disable. Its own
-- message owner so it can't collide with any other "EditModeChanged" listener
-- (see F.NewMessageOwner in Utils.lua); registered once at load, not per
-- rebuild, since the title-bar button is created once and never rebuilt.
if F and F.NewMessageOwner then
    F.NewMessageOwner():RegisterMessage("EditModeChanged", RefreshEditModeButtons)
end

-----------------------------------------------------------------------
-- Sidebar
-----------------------------------------------------------------------

local SIDEBAR_WIDTH = 150
local ROW_HEIGHT = 24
-- Accent alpha for a hovered (unselected) nav row. Same value the Indicators
-- tab's header buttons use, for one consistent hover across the panel.
local SIDEBAR_HOVER_ALPHA = 0.3

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
    -- Hover is a faint wash of the accent colour (which follows the profile's
    -- class-colour/custom choice), not the flat warm brown it used to be.
    -- Resolved per hover, since the accent changes with the profile and with
    -- the accent-colour setting -- a value captured at creation would go stale
    -- on both. Well under the 0.55 the SELECTED row uses (see HighlightRow),
    -- which is why hovering an unselected row can't be mistaken for selecting
    -- it. Matches the Indicators tab's own row/button hovers.
    row:SetScript("OnEnter", function(self)
        if self.isSelected then return end
        local a = F.GetAccentColor()
        self:SetBackdropColor(a.r, a.g, a.b, SIDEBAR_HOVER_ALPHA)
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
        -- Leave edit mode with the panel. Its only toggle is in this window's
        -- title bar, so staying in edit mode after closing left the frames
        -- draggable with no visible way to stop -- you had to reopen the panel
        -- purely to click the button again. PartyFrames:SetEditMode(false) is
        -- combat-safe (it defers its relayout to PLAYER_REGEN_ENABLED), so
        -- this needs no lockdown guard of its own.
        if SquizzFrames.editMode then
            SetEditModeEnabled(false)
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

    -- Both title-bar buttons are vertically centred in the 26px bar and inset
    -- from the right edge. Anchored at TOPRIGHT 0,0 the close button sat hard
    -- against the window's own border and corner with all its slack below it,
    -- which read as misaligned next to the Edit Mode button beside it.
    local closeBtn = W.CreateStyledButton(titleBar, "X", "red", {20, 20}, function()
        optionsFrame:Hide()
    end)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -4, 0)

    -- Edit Mode toggle, left of the close button: reachable from every tab
    -- (see SetEditModeEnabled's header comment for why it moved here off the
    -- General page). The callback is installed by WireEditModeButton.
    local editBtn = W.CreateStyledButton(titleBar, L["Edit Mode"] or "Edit Mode",
        "accent-hover", {76, 20}, nil)
    editBtn:SetPoint("RIGHT", closeBtn, "LEFT", -6, 0)
    editBtn.fontString:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    WireEditModeButton(editBtn)

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

    -- Reset the shared scroll area to the top.
    --
    -- MUST go through the SCROLLBAR. scrollFrame:SetVerticalScroll(0) on its
    -- own moves the view but leaves scrollBar holding the old value, and the
    -- wheel handler above derives its next position from exactly that -- so
    -- the first wheel tick after a "reset" snaps straight back to where you
    -- were. Setting the bar fires OnValueChanged, which moves the frame too.
    --
    -- Exposed because the Unit Frames page resets scroll when you switch
    -- section, and it has no access to these locals.
    function SquizzFrames.OptionsScrollToTop()
        if scrollBar then scrollBar:SetValue(0) end
        if scrollFrame then scrollFrame:SetVerticalScroll(0) end
    end

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
                local LP = SquizzFrames.LayoutPanel
                if LP and LP.IsRaidTab then
                    GroupPreview.SetRaidMode(LP.IsRaidTab())
                end
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

-- One switch for every Blizzard frame the addon replaces (2026-09-05).
-- Replaced the separate Hide Party / Hide Raid pair here and the two more on
-- the Unit Frames page -- see HideBlizzard.lua's ShouldHideBlizzard.
local function GetHideBlizzard()
    local p = GetProfile()
    local v = p and p.general and p.general.hideBlizzardFrames
    if v == nil then return true end
    return v ~= false
end

local function SetHideBlizzard(checked)
    local p = GetProfile()
    if p and p.general then
        p.general.hideBlizzardFrames = checked
        if SquizzFrames.HideBlizzard then SquizzFrames:HideBlizzard() end
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
        -- Start/stop the range poll to match. Nothing consumed this setting
        -- at all until now (it was written here and read nowhere), so the
        -- checkbox looked like it worked and didn't.
        local partyModule = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
        if partyModule and partyModule.RefreshRangePolling then
            partyModule.RefreshRangePolling()
        end
        SquizzFrames:Fire("LayoutChanged")
    end
end


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

    local cb1 = W.CreateStyledCheckbox(fieldsHost, L["Hide Blizzard Frames"] or "Hide Blizzard Frames", GetHideBlizzard, SetHideBlizzard)
    cb1:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 22

    local hideNote = fieldsHost:CreateFontString(nil, "OVERLAY")
    hideNote:SetFontObject("GameFontDisableSmall")
    hideNote:SetPoint("TOPLEFT", 32, yOffset)
    hideNote:SetPoint("RIGHT", fieldsHost, "RIGHT", -20, 0)
    hideNote:SetJustifyH("LEFT")
    hideNote:SetText(L["HideBlizzardFramesNote"]
        or "Covers party, raid, player, target, focus, boss, pet and cast bar - but only the ones SquizzFrames actually draws. Anything you leave switched off keeps Blizzard's frame.")
    yOffset = yOffset - 40

    -- Section: Behavior
    W.CreateTitledPane(fieldsHost, L["Behavior"] or "Behavior", yOffset)
    yOffset = yOffset - 35

    local cb3 = W.CreateStyledCheckbox(fieldsHost, L["Lock Frames"] or "Lock Frames", GetLocked, SetLocked)
    cb3:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    local cb4 = W.CreateStyledCheckbox(fieldsHost, L["Fade Out of Range"] or "Fade Out of Range", GetFadeOut, SetFadeOut)
    cb4:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    -- Edit Mode's toggle used to be a button here. It now lives in the title
    -- bar (CreateOptionsFrame) so it's reachable from every tab -- see
    -- SetEditModeEnabled's header comment. Nothing replaces it on this page.
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
-- Layout Page
-----------------------------------------------------------------------
-- The page itself lives in Modules/PartyFrames/LayoutPanel.lua. It was moved
-- there (2026-09-10) because BuildLayoutFields hit Lua's 60-upvalue ceiling
-- and its ~80 accessors were a large part of this file's 200-active-local
-- one, either of which stops the WHOLE options panel loading. A separate file
-- gets its own budget; see CLAUDE.md's "OptionsFrame.lua is at TWO Lua
-- ceilings".
local function CreateLayoutPage()
    local frame = CreateFrame("Frame", nil, scrollChild)
    frame:SetAllPoints()
    frame:Hide()
    contentFrames["layout"] = frame

    if SquizzFrames.LayoutPanel and SquizzFrames.LayoutPanel.Build then
        SquizzFrames.LayoutPanel.Build(frame)
    else
        local msg = frame:CreateFontString(nil, "OVERLAY", "GameFontRed")
        msg:SetPoint("CENTER")
        msg:SetText("Layout page module not loaded.")
    end
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
-- Pet Frames Page
-----------------------------------------------------------------------
-- The page itself lives in Modules/PetFrames/PetFramesPanel.lua. It was moved
-- there (2026-09-10) because its ~49 accessors were the largest single
-- contributor to this file hitting Lua's 200-active-local and 60-upvalue
-- ceilings, either of which stops the WHOLE options panel loading. A separate
-- file gets its own budget; see CLAUDE.md's "OptionsFrame.lua is at TWO Lua
-- ceilings".
local function CreatePetFramesPage()
    local frame = CreateFrame("Frame", nil, scrollChild)
    frame:SetAllPoints()
    frame:Hide()
    contentFrames["petFrames"] = frame

    if SquizzFrames.PetFramesPanel and SquizzFrames.PetFramesPanel.Build then
        SquizzFrames.PetFramesPanel.Build(frame)
    else
        local msg = frame:CreateFontString(nil, "OVERLAY", "GameFontRed")
        msg:SetPoint("CENTER")
        msg:SetText("Pet Frames module not loaded.")
    end
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

-----------------------------------------------------------------------
-- Unit Frames Page
-----------------------------------------------------------------------

local function CreateUnitFramesPage()
    local frame = CreateFrame("Frame", nil, scrollChild)
    frame:SetAllPoints()
    frame:Hide()
    contentFrames["unitFrames"] = frame

    if SquizzFrames.UnitFramesPanel and SquizzFrames.UnitFramesPanel.Build then
        SquizzFrames.UnitFramesPanel.Build(frame)
    else
        local msg = frame:CreateFontString(nil, "OVERLAY", "GameFontRed")
        msg:SetPoint("CENTER")
        msg:SetText("Unit Frames module not loaded.")
    end
end

local function CreateTankTrackerPage()
    local frame = CreateFrame("Frame", nil, scrollChild)
    frame:SetAllPoints()
    frame:Hide()
    contentFrames["tankTracker"] = frame

    if SquizzFrames.TankTrackerPanel and SquizzFrames.TankTrackerPanel.Build then
        SquizzFrames.TankTrackerPanel.Build(frame)
    else
        local msg = frame:CreateFontString(nil, "OVERLAY", "GameFontRed")
        msg:SetPoint("CENTER")
        msg:SetText("Tank Tracker module not loaded.")
    end
end

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
        CreateUnitFramesPage()
        CreateClickCastingPage()
        CreateIndicatorsPage()
        CreateTankTrackerPage()
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
