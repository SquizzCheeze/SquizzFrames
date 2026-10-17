--[[ SquizzFrames IndicatorWidgetsSpells.lua
-- The spell-list settings: a custom indicator's aura list, the Debuffs
-- blacklist, Big Debuff CC and the built-in spell checklists (externals,
-- defensives, AoE healing, CC, missing buffs, HoTs). Moved out of
-- IndicatorWidgets.lua unchanged in 2.0 (phase 2 code split). Loads after
-- IndicatorWidgetsBase.lua and before IndicatorWidgets.lua, which imports
-- these from SquizzFrames.IndicatorWidgetsSpells under the same names.
--]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local W = SquizzFrames.Widgets
if not W then return end

local F = SquizzFrames.F

local Base = SquizzFrames.IndicatorWidgetsBase
if not Base then return end
local SF_CreateFrame, SF_CreateCheckButton = Base.SF_CreateFrame, Base.SF_CreateCheckButton
local settingWidgets = Base.settingWidgets
local FONT_TEMPLATE, CreateLabel = Base.FONT_TEMPLATE, Base.CreateLabel

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
        widget.title:SetTextColor(W.C4(W.palette.HEADING))
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
        widget.title:SetTextColor(W.C4(W.palette.HEADING))
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
        W.StylizeFrame(popup, W.palette.POPUP_BG, W.palette.POPUP_BORDER)
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
                W.StylizeFrame(row, W.palette.PANEL_BG, W.palette.DARK_BORDER)
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
        widget.title:SetTextColor(W.C4(W.palette.HEADING))
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

                -- One row per spell NAME, not per ID. Several spells are
                -- curated under more than one ID (Earth Shield is 974 on
                -- others and 383648 on yourself via Elemental Orbit), and one
                -- row each meant unticking "Earth Shield" left the other copy
                -- showing (user report 2026-09-27). A row now hides or shows
                -- every ID behind its name together. Storage is unchanged --
                -- still a flat list of hidden IDs.
                local entries, byName = {}, {}
                for _, id in ipairs(ids) do
                    local spellName = F.GetSpellInfo(id)
                    local entry = spellName and byName[spellName]
                    if entry then
                        entry.ids[#entry.ids + 1] = id
                    else
                        entry = { name = spellName, ids = { id } }
                        entries[#entries + 1] = entry
                        if spellName then byName[spellName] = entry end
                    end
                end

                if #entries > 0 then
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

                    for _, entry in ipairs(entries) do
                        local entryIds = entry.ids
                        local id = entryIds[1]
                        idx = idx + 1
                        local row = CreateFrame("Frame", nil, scrollChild, "BackdropTemplate")
                        row:SetHeight(20)
                        W.StylizeFrame(row, W.palette.PANEL_BG, W.palette.DARK_BORDER)
                        row:SetPoint("TOPLEFT", rows[idx - 1], "BOTTOMLEFT", 0, -1)
                        row:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)

                        -- Checked = shown (the default). Unchecking hides it
                        -- from scanning; there is deliberately no delete
                        -- affordance -- the curated entry always stays here
                        -- to be re-shown later.
                        -- Ticked only while every ID behind the name is shown,
                        -- so a profile that hid just one copy under the old
                        -- per-ID rows reads as unticked, and one click sets
                        -- them all the same way.
                        local anyHidden = false
                        for _, eid in ipairs(entryIds) do
                            if hiddenSet[eid] then anyHidden = true end
                        end
                        local cb = SF_CreateCheckButton(row, "")
                        cb:SetPoint("LEFT", 4, 0)
                        cb:SetChecked(not anyHidden)
                        cb.onClick = function(checked)
                            local entrySet = {}
                            for _, eid in ipairs(entryIds) do entrySet[eid] = true end
                            local currentHidden = widget._hidden or {}
                            local newHidden = {}
                            for _, existing in ipairs(currentHidden) do
                                if not entrySet[existing] then newHidden[#newHidden + 1] = existing end
                            end
                            if not checked then
                                for _, eid in ipairs(entryIds) do newHidden[#newHidden + 1] = eid end
                            end
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
                        local idText = table.concat(entryIds, ", ")
                        nameStr:SetText(entry.name and (entry.name .. " (" .. idText .. ")") or idText)

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

SquizzFrames.IndicatorWidgetsSpells = {
    CreateSetting_Auras = CreateSetting_Auras,
    CreateSetting_DebuffBlacklist = CreateSetting_DebuffBlacklist,
    CreateSetting_BigDebuffCC = CreateSetting_BigDebuffCC,
    CreateSetting_BuiltInExternals = CreateSetting_BuiltInExternals,
    CreateSetting_BuiltInDefensives = CreateSetting_BuiltInDefensives,
    CreateSetting_BuiltInAoEHealings = CreateSetting_BuiltInAoEHealings,
    CreateSetting_BuiltInCrowdControls = CreateSetting_BuiltInCrowdControls,
    CreateSetting_BuiltInMissingBuffs = CreateSetting_BuiltInMissingBuffs,
    CreateSetting_BuiltInHots = CreateSetting_BuiltInHots,
}
