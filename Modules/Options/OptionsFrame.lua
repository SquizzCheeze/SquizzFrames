--[[ SquizzFrames OptionsFrame.lua - the options window ]]
--
-- Since 2.0 the window itself is LibSquizzShell-1.0 (Libs/), shared with
-- Squizzumables: title bar with search and Edit Mode, a sidebar in four
-- groups, a page header, and page hosting. This file registers the pages
-- (CreateOptionsFrame) and holds the builders for the ones still written
-- here (General, Profiles); the rest live in their own *Panel.lua files and
-- are only called from here.
--
-- Most pages are "scroll" pages placed in the shell's shared scroll frame at
-- least pageHeights tall. Indicators is a "fill" page: IndicatorsPanel.lua
-- manages its own list/settings/preview panes and needs the whole area.

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F
local L = SquizzFrames.L
local W = SquizzFrames.Widgets

local optionsFrame -- the shell window's frame, "SquizzFramesOptionsFrame"

-- Minimum content height per scroll page (content can exceed; the window
-- scrolls). Indicators manages its own layout and isn't part of this.
local pageHeights = {
    ["general"] = 715, -- -30: Edit Mode's button moved to the title bar; +320 Frame Opacity; +125 Theme, +25 Follow Blizzard's Edit Mode (2.0); +25 Reduce Motion
    ["layout"] = 1615, -- +280 Health Gradient group above Health Bar Colors
    ["petFrames"] = 1090, -- +490 for the Name Text section
    ["unitFrames"] = 1450, -- one section at a time; Colors/Text are the tallest
    ["clickCasting"] = 460,
    ["tankTracker"] = 1920, -- one sub-tab at a time; a row tab with both texts expanded is the tallest
    ["nicknames"] = 780,
    ["partyCooldowns"] = 1500, -- one sub-tab at a time; Spells (13 classes, 2 columns) is the tallest
    ["profiles"] = 600,
}

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

-- Keep the toggle's look correct when edit mode changes from OUTSIDE this file
-- -- Lock Frames turning it off, or PartyFrames' combat auto-disable. Its own
-- message owner so it can't collide with any other "EditModeChanged" listener
-- (see F.NewMessageOwner in Utils.lua); registered once at load, not per
-- rebuild, since the title-bar button is created once and never rebuilt.
if F and F.NewMessageOwner then
    F.NewMessageOwner():RegisterMessage("EditModeChanged", RefreshEditModeButtons)
end

-- Following Blizzard's Edit Mode (2.0, user decision 2026-10-16, as in
-- Squizzumables): opening it (Esc > Edit Mode) turns ours on too, and closing
-- it turns ours off again -- but only if opening it was what turned ours on,
-- so Edit Mode switched on from our title bar stays on. General > Follow
-- Blizzard's Edit Mode (general.followBlizzardEditMode, nil = on) stops it.
--
-- EventRegistry's EditMode.Enter / EditMode.Exit are Blizzard's own
-- notifications: listening calls nothing on EditModeManagerFrame, so nothing
-- of ours runs inside Edit Mode's code (touching that frame taints it).
-- Blizzard's Edit Mode cannot open in combat, and SetEditModeEnabled's own
-- callees defer their secure work if it ever did.
do
    local enabledForBlizzard = false
    local function Following()
        local p = SquizzFrames.db and SquizzFrames.db.profile
        return not (p and p.general and p.general.followBlizzardEditMode == false)
    end
    if EventRegistry and EventRegistry.RegisterCallback then
        local owner = {}
        EventRegistry:RegisterCallback("EditMode.Enter", function()
            if not Following() or SquizzFrames.editMode then return end
            SetEditModeEnabled(true)
            enabledForBlizzard = SquizzFrames.editMode and true or false
        end, owner)
        EventRegistry:RegisterCallback("EditMode.Exit", function()
            if not enabledForBlizzard then return end
            enabledForBlizzard = false
            if SquizzFrames.editMode then SetEditModeEnabled(false) end
        end, owner)
    end
end

-----------------------------------------------------------------------
-- The window: LibSquizzShell-1.0 (2.0 phase 3)
-----------------------------------------------------------------------
-- The window, title bar, search, grouped sidebar and page hosting come from
-- the shell shared with Squizzumables (Libs/LibSquizzShell-1.0). This file
-- registers SquizzFrames' pages with it and keeps what is ours: the Edit
-- Mode button's behaviour, the group-preview re-pointing and the page
-- builders below. The pages themselves are unchanged; each is still built
-- into the frame it is handed.

local Shell = LibStub("LibSquizzShell-1.0")
local win -- the shell window, made on first open

-- Keep the group preview pointed at the Party/Raid selection of whichever
-- page you just landed on. The Layout and Indicators pages keep INDEPENDENT
-- Party/Raid selections and share one preview window, so without this the
-- preview could show a raid beside a page editing party. No-op while closed.
local function OnShowPage(key, _, page)
    -- 2.0 motion: the page coming in fades up over 0.12s (instant with
    -- Reduce Motion), its preview with it -- as in Squizzumables.
    if SquizzFrames.Motion and page then
        if page.frame then SquizzFrames.Motion.Appear(page.frame, 0.12) end
        if page.previewFrame then SquizzFrames.Motion.Appear(page.previewFrame, 0.12) end
    end
    local GroupPreview = SquizzFrames.GroupPreview
    if not (GroupPreview and GroupPreview.SetRaidMode) then return end
    if key == "layout" then
        local LP = SquizzFrames.LayoutPanel
        if LP and LP.IsRaidTab then GroupPreview.SetRaidMode(LP.IsRaidTab()) end
    elseif key == "indicators" then
        local IP = SquizzFrames.IndicatorsPanel
        if IP and IP.IsRaidTab then GroupPreview.SetRaidMode(IP.IsRaidTab()) end
    end
end

-- Closing the panel drops any preview left showing and leaves edit mode.
-- The group preview window handles itself (GroupPreview.lua hooks this same
-- OnHide); this covers PartyFrames' older in-world preview. Edit mode: its
-- only toggle is in this window's title bar, so staying in it after closing
-- left the frames draggable with no visible way to stop.
-- PartyFrames:SetEditMode(false) is combat-safe (it defers its relayout).
local function OnWindowHide()
    -- Handing over to the other addon's window (combined /squizz): this window
    -- is only stepping aside, so Edit Mode and the preview stay as they are.
    if Shell.handingOff then return end
    -- Edit Mode first: since 2.0 it shows the mock grid itself, and leaving it
    -- is what moves the real frames to where the grid was placed. Dropping
    -- the grid first would skip that.
    if SquizzFrames.editMode then
        SetEditModeEnabled(false)
    end
    local partyModule = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    if partyModule and partyModule.IsPreviewActive and partyModule:IsPreviewActive() then
        partyModule:SetPreviewMode(false)
    end
end

local DEFAULT_WIDTH, DEFAULT_HEIGHT = 900, 620
local MIN_WIDTH, MIN_HEIGHT = 780, 500
local MAX_WIDTH, MAX_HEIGHT = 1400, 1000

-- Page builders are declared further down; the registration below only
-- runs on first open, by which time they all exist.
local Pages = {}

local function CreateOptionsFrame()
    if win then return win end

    -- The theme's choice is settled by now (Core's OnInitialize); fill the
    -- controls' palette and accent from it before any page is built.
    if SquizzFrames.Widgets_RefreshPalette then SquizzFrames.Widgets_RefreshPalette() end

    local function Page(key, label, subtitle, build, extra)
        local p = { key = key, label = label, subtitle = subtitle, build = build,
                    layout = "scroll", height = pageHeights[key] }
        for k, v in pairs(extra or {}) do p[k] = v end
        return p
    end

    Shell:RegisterAddon("SquizzFrames", { title = "SquizzFrames", groups = {
        { label = "Frames", pages = {
            Page("layout", "Party and Raid", "Size, growth and look of the group frames", Pages.layout),
            Page("unitFrames", "Unit Frames", "Player, target, focus, boss and arena frames", Pages.unitFrames, {
                -- Builds one section at a time, so search is told which
                -- section a control is in and how to reopen it.
                select = function(scope) SquizzFrames.UnitFramesPanel.Select(scope) end,
                indexAll = function() SquizzFrames.UnitFramesPanel.IndexAll() end,
                preview = function(column) SquizzFrames.UnitFramesPanel.BuildPreview(column) end,
                onResize = function()
                    -- The indicator sub-tab strip wraps to the width it had
                    -- when built, so re-measure once the drag has settled.
                    local UFP = SquizzFrames.UnitFramesPanel
                    if UFP and UFP.Rebuild then UFP.Rebuild() end
                end,
            }),
            Page("petFrames", "Pet Frames", "Party, raid and your own pet", Pages.petFrames),
        } },
        { label = "On the frames", pages = {
            Page("indicators", "Indicators", "What draws on each party and raid frame", Pages.indicators,
                { layout = "fill", autoIndex = false,
                  -- Every indicator by name, read live (customs change).
                  search = function(add) SquizzFrames.IndicatorsPanel.SearchEntries(add) end,
                  preview = function(column) SquizzFrames.IndicatorsPanel.BuildPreview(column) end }),
            Page("nicknames", "Nicknames", "Names shown in place of players' own", Pages.nicknames),
        } },
        { label = "Tools", pages = {
            Page("tankTracker", "Tank Tracker", "Each tank's debuffs and defensives", Pages.tankTracker, {
                select = function(scope) SquizzFrames.TankTrackerPanel.Select(scope) end,
                indexAll = function() SquizzFrames.TankTrackerPanel.IndexAll() end,
                preview = function(column) SquizzFrames.TankTrackerPanel.BuildPreview(column) end,
            }),
            Page("partyCooldowns", "Party Cooldowns", "Group members' defensives and externals on their frames", Pages.partyCooldowns, {
                -- One sub-tab at a time, like the Tank Tracker.
                select = function(scope) SquizzFrames.PartyCooldownsPanel.Select(scope) end,
                indexAll = function() SquizzFrames.PartyCooldownsPanel.IndexAll() end,
                preview = function(column) SquizzFrames.PartyCooldownsPanel.BuildPreview(column) end,
            }),
            Page("clickCasting", "Click Casting", "Spells and actions on mouse clicks and keys", Pages.clickCasting, {
                onShow = function(frame)
                    if frame.RebuildClickCasting then frame:RebuildClickCasting() end
                end,
            }),
        } },
        { label = "General", pages = {
            Page("general", "General", "Theme, Blizzard frames, behaviour and opacity", Pages.general),
            Page("profiles", "Profiles", "Profiles, spec switching, import and export", Pages.profiles),
        } },
    } })

    win = Shell:CreateWindow({
        name = "SquizzFramesOptionsFrame",
        addons = { "SquizzFrames" },
        title = "SQUIZZFRAMES",
        width = DEFAULT_WIDTH, height = DEFAULT_HEIGHT,
        minWidth = MIN_WIDTH, minHeight = MIN_HEIGHT,
        maxWidth = MAX_WIDTH, maxHeight = MAX_HEIGHT,
        level = 520,
        combat = "fade",
        buttons = {
            { key = "editMode", label = L["Edit Mode"] or "Edit Mode", width = 90,
              tip = "Shows every SquizzFrames frame with a box you can drag. Closing this window leaves Edit Mode.",
              -- Combined (/squizz): switches every addon's Edit Mode at once.
              onClick = function()
                  if Shell.combined and Shell.ToggleCombinedEdit then
                      Shell:ToggleCombinedEdit()
                  else
                      SetEditModeEnabled(nil)
                  end
              end },
        },
        onHide = OnWindowHide,
        onShowPage = OnShowPage,
    })
    optionsFrame = win.frame

    -- Build every page now, hidden, so search finds settings on pages that
    -- have not been opened yet (1.x built them all on first open too).
    win:BuildAllPages()

    -- The Edit Mode button shows the live state, however it was changed.
    editModeRefreshers[#editModeRefreshers + 1] = function()
        local b = win.buttons.editMode
        if b then b:SetActive(SquizzFrames.editMode) end
    end
    RefreshEditModeButtons()

    -- Reset the shared scroll area to the top. The Unit Frames and Tank
    -- Tracker pages call this when you switch section.
    function SquizzFrames.OptionsScrollToTop()
        win:ScrollToTop()
    end

    return win
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


-- The General page's blanket opacity sliders. Each row names the table that
-- holds its `opacity` (0-1); the modules read the same field.
local FRAME_OPACITY_ROWS = {
    {label = "Party Frames", path = function(p) return p and p.layout and p.layout.main end},
    {label = "Raid Frames",  path = function(p) return p and p.layout and p.layout.raid end},
    {label = "Unit Frames",  path = function(p) return p and p.unitFrames end},
    {label = "Pet Frames",   path = function(p) return p and p.petFrames end},
    {label = "Tank Tracker", path = function(p) return p and p.tankTracker end},
}

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

    -- Section: Theme. Shared with Squizzumables (LibSquizzTheme-1.0, 2.0): one
    -- account-wide choice, so picking here changes both addons. Our window
    -- reads its accent once, when built, so the change shows here after a
    -- reload; Squizzumables repaints its own accent live.
    local LST = LibStub and LibStub("LibSquizzTheme-1.0", true)
    if LST then
        W.CreateTitledPane(fieldsHost, L["Theme"] or "Theme", yOffset)
        yOffset = yOffset - 35
        local themeItems = {}
        for _, key in ipairs(LST.ORDER) do
            themeItems[#themeItems + 1] = {value = key, text = LST.PRESETS[key].name}
        end
        local ddTheme = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Preset"] or "Preset", themeItems,
            function() return LST:PresetKey() end,
            function(key)
                if key == LST:PresetKey() then return end
                LST:SetPreset(key)
                if not StaticPopupDialogs["SQUIZZFRAMES_THEME_RELOAD"] then
                    StaticPopupDialogs["SQUIZZFRAMES_THEME_RELOAD"] = {
                        text = "Theme set to %s for SquizzFrames and Squizzumables.\n\nReload now to see it in this window?",
                        button1 = RELOADUI or "Reload", button2 = CANCEL or "Later",
                        OnAccept = function() ReloadUI() end,
                        timeout = 0, whileDead = true, hideOnEscape = true,
                    }
                end
                StaticPopup_Show("SQUIZZFRAMES_THEME_RELOAD", LST.PRESETS[key].name)
            end)
        ddTheme:SetPoint("TOPLEFT", 15, yOffset)
        yOffset = yOffset - 50

        local themeNote = fieldsHost:CreateFontString(nil, "OVERLAY")
        themeNote:SetFontObject("GameFontDisableSmall")
        themeNote:SetPoint("TOPLEFT", 32, yOffset)
        themeNote:SetPoint("RIGHT", fieldsHost, "RIGHT", -20, 0)
        themeNote:SetJustifyH("LEFT")
        themeNote:SetText(L["ThemeNote"]
            or "One theme covers SquizzFrames and Squizzumables: this window, its controls and its accent colour.")
        yOffset = yOffset - 40
    end

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

    -- 2.0: Blizzard's Edit Mode turns ours on and off too (see the
    -- EditMode.Enter/Exit listeners near SetEditModeEnabled). Inline
    -- accessors: this file is short of locals (see CLAUDE.md).
    local cbFollow = W.CreateStyledCheckbox(fieldsHost,
        L["Follow Blizzard's Edit Mode"] or "Follow Blizzard's Edit Mode",
        function()
            local p = GetProfile()
            return not (p and p.general and p.general.followBlizzardEditMode == false)
        end,
        function(checked)
            local p = GetProfile()
            if p and p.general then p.general.followBlizzardEditMode = checked and true or false end
        end)
    cbFollow:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    -- 2.0 motion (Motion.lua): every fade and pop becomes instant. Chained,
    -- not kept in a local: this file is short of locals.
    W.CreateStyledCheckbox(fieldsHost, L["Reduce Motion"] or "Reduce Motion",
        function()
            local p = GetProfile()
            return (p and p.general and p.general.reduceMotion) and true or false
        end,
        function(checked)
            local p = GetProfile()
            if p and p.general then p.general.reduceMotion = checked and true or false end
        end):SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    -- Section: Frame Opacity -- one blanket slider per frame group. Built
    -- from a table so five controls cost this file no extra locals.
    yOffset = yOffset - 15
    W.CreateTitledPane(fieldsHost, L["Frame Opacity"] or "Frame Opacity", yOffset)
    yOffset = yOffset - 45
    for _, row in ipairs(FRAME_OPACITY_ROWS) do
        local s = W.CreateStyledSlider(fieldsHost, 200, 0, 100, 5, row.label,
            function()
                local tbl = row.path(GetProfile())
                return math.floor(((tbl and tbl.opacity) or 1) * 100 + 0.5)
            end,
            function(v)
                local tbl = row.path(GetProfile())
                if not tbl then return end
                tbl.opacity = v / 100
                SquizzFrames:Fire("FrameOpacityChanged")
            end)
        s:SetPoint("TOPLEFT", 15, yOffset)
        yOffset = yOffset - 52
    end

    -- Edit Mode's toggle used to be a button here. It now lives in the title
    -- bar (CreateOptionsFrame) so it's reachable from every tab -- see
    -- SetEditModeEnabled's header comment. Nothing replaces it on this page.
end

function Pages.general(frame)

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
function Pages.layout(frame)

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
                head:SetTextColor(W.C4(W.palette.GREY_TEXT))
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
        W.StylizeFrame(dialog, W.palette.DARK_BG, W.palette.POPUP_BORDER)

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

function Pages.profiles(frame)

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
function Pages.petFrames(frame)

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

function Pages.clickCasting(frame)

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

function Pages.indicators(frame)

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

function Pages.unitFrames(frame)

    if SquizzFrames.UnitFramesPanel and SquizzFrames.UnitFramesPanel.Build then
        SquizzFrames.UnitFramesPanel.Build(frame)
    else
        local msg = frame:CreateFontString(nil, "OVERLAY", "GameFontRed")
        msg:SetPoint("CENTER")
        msg:SetText("Unit Frames module not loaded.")
    end
end

function Pages.tankTracker(frame)

    if SquizzFrames.TankTrackerPanel and SquizzFrames.TankTrackerPanel.Build then
        SquizzFrames.TankTrackerPanel.Build(frame)
    else
        local msg = frame:CreateFontString(nil, "OVERLAY", "GameFontRed")
        msg:SetPoint("CENTER")
        msg:SetText("Tank Tracker module not loaded.")
    end
end

function Pages.partyCooldowns(frame)
    if SquizzFrames.PartyCooldownsPanel and SquizzFrames.PartyCooldownsPanel.Build then
        SquizzFrames.PartyCooldownsPanel.Build(frame)
    else
        local msg = frame:CreateFontString(nil, "OVERLAY", "GameFontRed")
        msg:SetPoint("CENTER")
        msg:SetText("Party Cooldowns module not loaded.")
    end
end

function Pages.nicknames(frame)

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
    CreateOptionsFrame()
    win:Toggle()
end

-- The combined /squizz window (2.0): how the shared shell builds and opens
-- ours. See LibSquizzShell's "The combined window".
if Shell.RegisterOpener then
    Shell:RegisterOpener("SquizzFrames", {
        open = function(pageId, show)
            CreateOptionsFrame()
            if show then win:Open(pageId) end
            return win
        end,
        -- The combined window's one Edit Mode (lib:ToggleCombinedEdit).
        editMode = function(on) SetEditModeEnabled(on and true or false) end,
        isEditing = function() return SquizzFrames.editMode and true or false end,
    })
end

-----------------------------------------------------------------------
-- Public API
-----------------------------------------------------------------------

SquizzFrames.ToggleOptions = ToggleOptions
-- For first-run setup (Modules/Welcome/Setup.lua): Edit Mode on/off, and
-- the options window opened on one page.
SquizzFrames.SetEditModeEnabled = SetEditModeEnabled
function SquizzFrames.OpenOptionsPage(pageId)
    CreateOptionsFrame()
    if win then win:Open(pageId) end
end
