-----------------------------------------------------------------------
-- Nicknames options page
-----------------------------------------------------------------------
-- Hosted by OptionsFrame.lua's "nicknames" nav entry, which just creates a
-- frame and hands it to Panel.Build -- same arrangement IndicatorsPanel uses.
-- Kept in its own file rather than growing OptionsFrame.lua, which already ran
-- into Lua's 60-upvalue-per-function cap once (see BuildBorderSections).
--
-- Every control here is a thin shell over the module's public API
-- (SetMyNickname / SetMineAccountWide / SetSyncEnabled / SetCustomNickname /
-- SetBlacklisted / SetEnabled). No option writes the saved-variable tables
-- directly, so the panel and the /sf nick commands can't drift apart, and
-- every write goes through Sanitize exactly once.
-----------------------------------------------------------------------

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F
local W = SquizzFrames.Widgets

local Panel = {}
SquizzFrames.NicknamesPanel = Panel

local pageFrame          -- the frame OptionsFrame handed us
local RefreshCustomList  -- forward declarations; defined in Build
local RefreshBlockedList

-- Controls that need re-syncing when the data changes underneath the panel
-- (the /sf nick commands touch the same tables). Populated by Build.
local widgets = {}

-- The module may not exist if its file failed to load; every accessor here
-- tolerates that rather than erroring inside the options frame.
local function Mod()
    return SquizzFrames.Nicknames
end

local function Data()
    local m = Mod()
    return m and m.GetDB and m.GetDB() or nil
end

-----------------------------------------------------------------------
-- Small local widgets
-----------------------------------------------------------------------

-- Row pitch for both list widgets. Declared up here because MakeListRow (a
-- few functions down) closes over it -- a `local` declared after that function
-- would compile inside it as a nil GLOBAL instead, with no error until the
-- arithmetic ran.
local ROW_SPACING = 24

-- "Name-Realm" for a unit, in the exact form the module keys nicknames by.
--
-- Mirrors Nicknames.lua's own Resolve: UnitName returns an EMPTY realm for
-- same-realm players, which means "my realm", not "unknown" -- so fill it in
-- rather than storing a bare name. Returns nil rather than a secret if the
-- unit's identity is currently restricted; the options panel is normally open
-- out of combat, but nothing guarantees it.
local function UnitKeyName(unit)
    if not unit or not UnitExists(unit) then return nil end
    -- AI party members (Delve companions like Brann and Valeera) count. They
    -- fail UnitIsPlayer, so a bare player test would drop them from Pick from
    -- Group and from target auto-fill -- yet a nickname for one resolves fine:
    -- UnitName gives an empty realm, which Resolve fills in with your own, so
    -- the key matches the same "Name-Realm" form as everyone else.
    if not (UnitIsPlayer(unit) or (UnitInPartyIsAI and UnitInPartyIsAI(unit))) then return nil end
    local name, realm = UnitName(unit)
    if not name or not F.IsValueNonSecret(name) then return nil end
    if realm and F.IsValueNonSecret(realm) and realm ~= "" then
        return name .. "-" .. realm
    end
    local myRealm = GetNormalizedRealmName()
    if myRealm and myRealm ~= "" then return name .. "-" .. myRealm end
    return name
end

-- Current group members, for the "Pick from Group" menu.
--
-- Deliberately does NOT filter yourself out with UnitIsUnit -- that call
-- returns a secret on rated-PvP maps, and one stray self entry is a far
-- smaller problem than an error inside the options panel.
local function GroupUnits()
    local units = {}
    if IsInRaid() then
        for i = 1, 40 do
            local u = "raid" .. i
            if UnitExists(u) then units[#units + 1] = u end
        end
    else
        for i = 1, 4 do
            local u = "party" .. i
            if UnitExists(u) then units[#units + 1] = u end
        end
    end
    return units
end

local function MakeEditBox(parent, width, maxLetters, placeholder)
    local eb = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    eb:SetSize(width, 22)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(maxLetters or 24)
    eb:SetFontObject("GameFontHighlightSmall")
    eb:SetTextInsets(6, 6, 0, 0)
    W.StylizeFrame(eb, {0.08, 0.08, 0.08, 1}, {0.3, 0.3, 0.3, 1})

    if placeholder then
        eb.placeholder = eb:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        eb.placeholder:SetPoint("LEFT", 7, 0)
        eb.placeholder:SetText(placeholder)
        local function UpdatePlaceholder()
            if eb:GetText() == "" then eb.placeholder:Show() else eb.placeholder:Hide() end
        end
        eb:HookScript("OnTextChanged", UpdatePlaceholder)
        UpdatePlaceholder()
    end

    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return eb
end

local function MakeSectionNote(parent, text, yOffset, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetPoint("TOPLEFT", 17, yOffset)
    fs:SetWidth(width or 420)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return fs
end

-- Shared "add an entry" dialog. Used with two fields (private list) or one
-- (blocked list); onAccept receives the trimmed field values.
local function MakeAddPopup(parent, title, field1, field2, onAccept)
    local popup = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    popup:SetFrameStrata("DIALOG")
    W.StylizeFrame(popup, {0.08, 0.08, 0.08, 0.98}, {0.4, 0.4, 0.4, 0.9})
    popup:Hide()

    local y = -8
    local heading = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    heading:SetPoint("TOP", 0, y)
    heading:SetText(title)
    y = y - 20

    local eb1 = MakeEditBox(popup, 210, 32, field1)
    eb1:SetPoint("TOP", 0, y)
    y = y - 27

    local eb2
    if field2 then
        eb2 = MakeEditBox(popup, 210, 20, field2)
        eb2:SetPoint("TOP", 0, y)
        eb1:SetScript("OnTabPressed", function() eb2:SetFocus() end)
        eb2:SetScript("OnTabPressed", function() eb1:SetFocus() end)
        y = y - 27
    end

    -- Two ways to fill the name in without typing it.
    local help = popup:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    help:SetPoint("TOP", 0, y)
    help:SetWidth(210)
    help:SetHeight(26)
    help:SetJustifyH("LEFT")
    help:SetJustifyV("TOP")
    help:SetText("Target a player and their name fills in automatically, or pick from your group below.")
    y = y - 30

    -- Group picker. Passing nil as CreateStyledButton's onClick and wiring
    -- OnClick separately, same as OptionsFrame's Edit Mode button -- the
    -- factory only installs its own handler when given one.
    local groupBtn = W.CreateStyledButton(popup, "Pick from Group", "accent-hover", {210, 20}, nil)
    groupBtn:SetPoint("TOP", 0, y)
    y = y - 26

    -- Cached across clicks. CreateMenu builds its rows once at construction
    -- and WoW frames can never be destroyed, so making a fresh one per click
    -- would leak a frame (plus its full-screen closer) every time the button
    -- is pressed. Rebuild only when the roster actually differs.
    local groupMenu, groupMenuSig

    groupBtn:SetScript("OnClick", function()
        local keys = {}
        local groupSize = 0
        for _, unit in ipairs(GroupUnits()) do
            groupSize = groupSize + 1
            local key = UnitKeyName(unit)
            if key then keys[#keys + 1] = key end
            -- A full 40-man would build a menu taller than the screen.
            if #keys >= 20 then break end
        end

        -- Signature includes the group size, not just the readable names --
        -- otherwise "in a group but every name unreadable" and "not in a
        -- group" both produce an empty signature and share one cached menu.
        local sig = groupSize .. "\30" .. table.concat(keys, "\30")
        if groupMenu and groupMenuSig == sig then
            groupMenu:ShowMenu()
            return
        end
        if groupMenu then groupMenu:Hide() end

        local items = {}
        for _, key in ipairs(keys) do
            items[#items + 1] = {
                text = key,
                onClick = function()
                    eb1:SetText(key)
                    if eb2 then eb2:SetFocus() end
                end,
            }
        end
        if #items == 0 then
            -- Distinguish the two ways this list comes back empty. They used
            -- to render identically, which made "clicked a name and nothing
            -- happened" impossible to tell apart from "there were no names to
            -- click" -- reported 2026-08-16.
            items[1] = (groupSize > 0)
                and { text = "|cffff8080names hidden in combat|r", onClick = function() end }
                or  { text = "|cff808080(not in a group)|r", onClick = function() end }
        elseif #keys >= 20 then
            items[#items + 1] = { text = "|cff808080...more: type the name|r", onClick = function() end }
        end

        groupMenu = W.CreateMenu(popup, items, 210)
        groupMenuSig = sig
        groupMenu:SetPoint("TOP", groupBtn, "BOTTOM", 0, -2)
        groupMenu:ShowMenu()
    end)

    -- Auto-fill from the current target while the popup is open. Registered
    -- only for as long as it's visible, so nothing listens in the background.
    popup:SetScript("OnEvent", function()
        local key = UnitKeyName("target")
        if key then eb1:SetText(key) end
    end)

    local function Close()
        eb1:SetText("")
        if eb2 then eb2:SetText("") end
        popup:Hide()
    end

    local function Accept()
        local v1 = (eb1:GetText() or ""):match("^%s*(.-)%s*$")
        local v2 = eb2 and ((eb2:GetText() or ""):match("^%s*(.-)%s*$")) or nil
        if v1 == "" or (eb2 and v2 == "") then return end
        onAccept(v1, v2)
        Close()
    end

    local addBtn = W.CreateStyledButton(popup, "Add", "green-hover", {96, 20}, Accept)
    addBtn:SetPoint("TOPLEFT", 15, y)
    local cancelBtn = W.CreateStyledButton(popup, "Cancel", "red-hover", {96, 20}, Close)
    cancelBtn:SetPoint("TOPRIGHT", -15, y)
    y = y - 30

    -- Height derived from the running layout offset rather than hardcoded, so
    -- the one-field (block) and two-field (nickname) variants both fit.
    popup:SetSize(240, math.abs(y))

    eb1:SetScript("OnEnterPressed", function() if eb2 then eb2:SetFocus() else Accept() end end)
    if eb2 then eb2:SetScript("OnEnterPressed", Accept) end
    eb1:SetScript("OnEscapePressed", Close)
    if eb2 then eb2:SetScript("OnEscapePressed", Close) end

    popup:SetScript("OnShow", function() popup:RegisterEvent("PLAYER_TARGET_CHANGED") end)
    popup:SetScript("OnHide", function() popup:UnregisterEvent("PLAYER_TARGET_CHANGED") end)

    popup.Open = function()
        popup:Show()
        popup:Raise()
        -- Seed from whatever is already targeted, so the common case needs no
        -- clicks at all: target, click Add, type the nickname.
        local key = UnitKeyName("target")
        if key then eb1:SetText(key) end
        if key and eb2 then eb2:SetFocus() else eb1:SetFocus() end
    end
    return popup
end

-- One row in a list: a label, an optional secondary label, and a delete button.
local function MakeListRow(parent, index, primary, secondary, onDelete)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetHeight(22)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_SPACING)
    row:SetPoint("TOPRIGHT", 0, -(index - 1) * ROW_SPACING)
    W.StylizeFrame(row, {0.115, 0.115, 0.115, 1}, {0.22, 0.22, 0.22, 1})

    local del = W.CreateStyledButton(row, "x", "red-hover", {20, 16}, onDelete)
    del:SetPoint("RIGHT", -4, 0)

    local nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameFS:SetPoint("LEFT", 6, 0)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetText(primary)

    if secondary then
        local nickFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nickFS:SetPoint("RIGHT", del, "LEFT", -8, 0)
        nickFS:SetJustifyH("RIGHT")
        nickFS:SetText(secondary)
        -- Cap the left label so a long Name-Realm can't run under the nickname.
        nameFS:SetPoint("RIGHT", nickFS, "LEFT", -8, 0)
        nameFS:SetWordWrap(false)
    else
        nameFS:SetPoint("RIGHT", del, "LEFT", -8, 0)
        nameFS:SetWordWrap(false)
    end

    return row
end

-- Sized directly rather than via the widget's SetContentHeight, which assumes
-- its own 30px row pitch -- these rows are denser (24), and the mismatch would
-- leave a growing strip of dead scroll space below the last entry.
local function SetRowCount(scroll, count)
    scroll.scrollChild:SetHeight(math.max(1, count * ROW_SPACING))
    scroll:UpdateScrollChildRect()
end

-- Sorted key list, so row order is stable between refreshes instead of
-- following pairs()' arbitrary iteration order.
local function SortedKeys(tbl)
    local keys = {}
    for k in pairs(tbl or {}) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return a:lower() < b:lower() end)
    return keys
end

-----------------------------------------------------------------------
-- Build
-----------------------------------------------------------------------

function Panel.Build(frame)
    pageFrame = frame

    if frame.fieldsHost then
        frame.fieldsHost:Hide()
        frame.fieldsHost:SetParent(nil)
        frame.fieldsHost = nil
    end
    local host = CreateFrame("Frame", nil, frame)
    host:SetAllPoints()
    frame.fieldsHost = host

    if not Mod() then
        local msg = host:CreateFontString(nil, "OVERLAY", "GameFontRed")
        msg:SetPoint("TOPLEFT", 15, -20)
        msg:SetText("Nicknames module not loaded.")
        return
    end

    local yOffset = -10

    -----------------------------------------------------------------
    -- Master toggle
    -----------------------------------------------------------------
    W.CreateTitledPane(host, "Nicknames", yOffset)
    yOffset = yOffset - 35

    local enableCB = W.CreateStyledCheckbox(host, "Enable nicknames",
        function() local d = Data() return d and d.enabled end,
        function(checked) Mod():SetEnabled(checked) end)
    enableCB:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 22

    MakeSectionNote(host, "Shows a nickname in place of a character name on your frames.", yOffset)
    yOffset = yOffset - 30

    -----------------------------------------------------------------
    -- Your own nickname
    -----------------------------------------------------------------
    W.CreateTitledPane(host, "Your Nickname", yOffset)
    yOffset = yOffset - 35

    local myBox = MakeEditBox(host, 200, 20, "Your nickname")
    myBox:SetPoint("TOPLEFT", 17, yOffset)

    local function CommitMine()
        local text = (myBox:GetText() or ""):match("^%s*(.-)%s*$")
        local stored = Mod():SetMyNickname(text ~= "" and text or nil)
        -- Show the SANITIZED value that was actually stored, not the raw
        -- input -- otherwise a rejected or trimmed entry silently disagrees
        -- with what the frames display.
        myBox:SetText(stored or "")
        myBox:ClearFocus()
    end
    myBox:SetScript("OnEnterPressed", CommitMine)
    myBox:SetScript("OnEditFocusLost", CommitMine)
    myBox:SetText(Mod():GetMyNickname() or "")

    local clearMine = W.CreateStyledButton(host, "Clear", "red-hover", {60, 22}, function()
        Mod():SetMyNickname(nil)
        myBox:SetText("")
        myBox:ClearFocus()
    end)
    clearMine:SetPoint("LEFT", myBox, "RIGHT", 6, 0)
    yOffset = yOffset - 28

    local accountCB = W.CreateStyledCheckbox(host, "Use this nickname on all my characters",
        function() local d = Data() return d and d.mineAccountWide end,
        function(checked)
            Mod():SetMineAccountWide(checked)
            -- Switching store changes which value is live, so re-read it.
            myBox:SetText(Mod():GetMyNickname() or "")
        end)
    accountCB:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 22

    MakeSectionNote(host, "Off, each character keeps its own nickname. Switching between the two never discards either one.", yOffset)
    yOffset = yOffset - 32

    -----------------------------------------------------------------
    -- Sharing
    -----------------------------------------------------------------
    W.CreateTitledPane(host, "Sharing", yOffset)
    yOffset = yOffset - 35

    local syncCB = W.CreateStyledCheckbox(host, "Share nicknames with your group",
        function() local d = Data() return d and d.sync end,
        function(checked)
            Mod():SetSyncEnabled(checked)
            if RefreshBlockedList then RefreshBlockedList() end
        end)
    syncCB:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 22

    MakeSectionNote(host, "Sends your nickname to other SquizzFrames users in your group, and shows theirs. Your own private entries below always take priority over anything received.", yOffset)
    yOffset = yOffset - 42

    -----------------------------------------------------------------
    -- Private list
    -----------------------------------------------------------------
    W.CreateTitledPane(host, "Private Nicknames", yOffset)
    yOffset = yOffset - 35

    local customCB = W.CreateStyledCheckbox(host, "Use my private list",
        function() local d = Data() return d and d.customEnabled end,
        function(checked)
            local d = Data()
            if d then d.customEnabled = checked and true or false end
            Mod().RefreshAllNames()
        end)
    customCB:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 22

    MakeSectionNote(host, "Only you see these, and they apply on every character you play. Target a player before clicking Add and their name is filled in for you, or pick them from your group.", yOffset)
    yOffset = yOffset - 32

    local customHost = CreateFrame("Frame", nil, host, "BackdropTemplate")
    customHost:SetPoint("TOPLEFT", 17, yOffset)
    customHost:SetPoint("TOPRIGHT", -17, yOffset)
    customHost:SetHeight(150)
    W.StylizeFrame(customHost, {0.05, 0.05, 0.05, 1}, {0.25, 0.25, 0.25, 1})

    local customScroll = W.CreateScrollFrame(customHost)
    customScroll:SetPoint("TOPLEFT", 4, -4)
    customScroll:SetPoint("BOTTOMRIGHT", -4, 4)

    local customRows = {}
    local customEmptyFS = customHost:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    customEmptyFS:SetPoint("CENTER")
    customEmptyFS:SetText("No private nicknames yet.")

    RefreshCustomList = function()
        for _, row in ipairs(customRows) do row:Hide(); row:SetParent(nil) end
        wipe(customRows)

        local d = Data()
        local keys = SortedKeys(d and d.custom)
        customEmptyFS:SetShown(#keys == 0)

        for i, who in ipairs(keys) do
            local row = MakeListRow(customScroll.scrollChild, i, who, d.custom[who], function()
                Mod():SetCustomNickname(who, nil)
                RefreshCustomList()
            end)
            customRows[#customRows + 1] = row
        end
        SetRowCount(customScroll, #keys)
    end
    yOffset = yOffset - 156

    local customPopup = MakeAddPopup(host, "Add a private nickname",
        "Name or Name-Realm", "Nickname",
        function(who, nick)
            Mod():SetCustomNickname(who, nick)
            RefreshCustomList()
        end)
    customPopup:SetPoint("TOP", customHost, "BOTTOM", 0, -2)

    local customAdd = W.CreateStyledButton(host, "Add Nickname", "accent-hover", {120, 22},
        function() customPopup.Open() end)
    customAdd:SetPoint("TOPLEFT", 17, yOffset)
    yOffset = yOffset - 34

    -----------------------------------------------------------------
    -- Blocked
    -----------------------------------------------------------------
    W.CreateTitledPane(host, "Blocked Players", yOffset)
    yOffset = yOffset - 35

    MakeSectionNote(host, "Nicknames broadcast by these players are ignored, and you see their real character name instead. Your own private nicknames still apply.", yOffset)
    yOffset = yOffset - 32

    local blockHost = CreateFrame("Frame", nil, host, "BackdropTemplate")
    blockHost:SetPoint("TOPLEFT", 17, yOffset)
    blockHost:SetPoint("TOPRIGHT", -17, yOffset)
    blockHost:SetHeight(100)
    W.StylizeFrame(blockHost, {0.05, 0.05, 0.05, 1}, {0.25, 0.25, 0.25, 1})

    local blockScroll = W.CreateScrollFrame(blockHost)
    blockScroll:SetPoint("TOPLEFT", 4, -4)
    blockScroll:SetPoint("BOTTOMRIGHT", -4, 4)

    local blockRows = {}
    local blockEmptyFS = blockHost:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    blockEmptyFS:SetPoint("CENTER")
    blockEmptyFS:SetText("Nobody blocked.")

    RefreshBlockedList = function()
        for _, row in ipairs(blockRows) do row:Hide(); row:SetParent(nil) end
        wipe(blockRows)

        local d = Data()
        local keys = SortedKeys(d and d.blacklist)
        blockEmptyFS:SetShown(#keys == 0)

        for i, who in ipairs(keys) do
            local row = MakeListRow(blockScroll.scrollChild, i, who, nil, function()
                Mod():SetBlacklisted(who, false)
                RefreshBlockedList()
            end)
            blockRows[#blockRows + 1] = row
        end
        SetRowCount(blockScroll, #keys)
    end
    yOffset = yOffset - 106

    local blockPopup = MakeAddPopup(host, "Block a player", "Name-Realm", nil,
        function(who)
            Mod():SetBlacklisted(who, true)
            RefreshBlockedList()
        end)
    blockPopup:SetPoint("TOP", blockHost, "BOTTOM", 0, -2)

    local blockAdd = W.CreateStyledButton(host, "Block Player", "accent-hover", {120, 22},
        function() blockPopup.Open() end)
    blockAdd:SetPoint("TOPLEFT", 17, yOffset)

    widgets.enableCB  = enableCB
    widgets.myBox     = myBox
    widgets.accountCB = accountCB
    widgets.syncCB    = syncCB
    widgets.customCB  = customCB

    RefreshCustomList()
    RefreshBlockedList()
end

-- Re-sync on show: /sf nick writes the same tables, so the panel can be stale
-- by the time it's reopened.
--
-- Deliberately re-syncs the existing controls rather than calling Build again.
-- Build tears down and recreates its whole widget host, and WoW frames can
-- never be destroyed -- rebuilding on every open would orphan a full page of
-- frames (plus popups and their menus) each time the panel is viewed.
function Panel.Refresh()
    if not pageFrame or not widgets.enableCB then return end
    local d = Data()
    local m = Mod()
    if not d or not m then return end

    widgets.enableCB:SetChecked(d.enabled)
    widgets.accountCB:SetChecked(d.mineAccountWide)
    widgets.syncCB:SetChecked(d.sync)
    widgets.customCB:SetChecked(d.customEnabled)
    widgets.myBox:SetText(m:GetMyNickname() or "")

    if RefreshCustomList then RefreshCustomList() end
    if RefreshBlockedList then RefreshBlockedList() end
end
