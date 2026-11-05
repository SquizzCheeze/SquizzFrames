--[[ SquizzFrames ProfileTransfer.lua - Profile import/export strings

    A string is "!SQF1!" followed by LibSerialize -> LibDeflate -> print-safe
    encoding of { addon, format, version, flavor, name, profile }. Only the
    profile travels: nicknames, spec auto-switch and the theme are account-wide
    and live outside it. An imported profile's migrations run through the normal
    RefreshProfile path, so an old string upgrades the same way an old
    SavedVariables file does.

    An imported string is someone else's data, and three rules follow from that:

    - It only ever creates a NEW profile, so nothing the user has is overwritten.
    - LibSerialize rebuilds plain values and never runs code, but a click-cast
      macro does run, on the user's own clicks. Macros are removed unless the
      user ticks the box that appears when the string contains any.
    - Spell IDs differ between retail and WoW Forever, so a string from the other
      client loses any ID that doesn't exist on this one. ]]

local SquizzFrames = _G["SquizzFrames"]

local L = SquizzFrames.L
local W = SquizzFrames.Widgets

local ProfileTransfer = {}
SquizzFrames.ProfileTransfer = ProfileTransfer

local PREFIX = "!SQF1!"
local FORMAT = 1
local MAX_NAME = 48

-- Fields holding spell IDs that are worth checking when a string crosses
-- between clients. Walked anywhere under profile.layout, since custom
-- indicators keep theirs inside each list entry.
local SPELL_LIST_KEYS = { auras = true, debuffBlacklist = true }

local function CurrentFlavor()
    return SquizzFrames.IS_FOREVER and "forever" or "retail"
end

local function IsMacroBinding(binding)
    return type(binding) == "table" and (binding.type == "macro" or binding.type == "custom")
end

-----------------------------------------------------------------------
-- Encoding
-----------------------------------------------------------------------

-- Returns the string, or nil and the reason.
function ProfileTransfer.Encode()
    local db = SquizzFrames.db
    if not db or not db.profile then return nil, "No profile is loaded." end
    local LibSerialize = LibStub("LibSerialize")
    local LibDeflate = LibStub("LibDeflate")

    local ok, result = pcall(function()
        local serialized = LibSerialize:Serialize({
            addon = "SquizzFrames",
            format = FORMAT,
            version = C_AddOns.GetAddOnMetadata("SquizzFrames", "Version"),
            flavor = CurrentFlavor(),
            name = db:GetCurrentProfile(),
            profile = db.profile,
        })
        return PREFIX .. LibDeflate:EncodeForPrint(LibDeflate:CompressDeflate(serialized, { level = 9 }))
    end)
    if not ok then return nil, tostring(result) end
    return result
end

-- Returns the checked payload, or nil and a reason fit to show the user.
function ProfileTransfer.Decode(text)
    text = tostring(text or ""):gsub("%s+", "")
    if text == "" then return nil, nil end
    if text:sub(1, #PREFIX) ~= PREFIX then
        return nil, L["This isn't a SquizzFrames profile string."] or "This isn't a SquizzFrames profile string."
    end

    local damaged = L["This string is damaged or incomplete. Copy it again."]
        or "This string is damaged or incomplete. Copy it again."
    local ok, success, payload = pcall(function()
        local LibDeflate = LibStub("LibDeflate")
        local compressed = LibDeflate:DecodeForPrint(text:sub(#PREFIX + 1))
        local serialized = compressed and LibDeflate:DecompressDeflate(compressed)
        if not serialized then return false end
        return LibStub("LibSerialize"):Deserialize(serialized)
    end)
    if not ok or not success or type(payload) ~= "table" then return nil, damaged end

    if payload.addon ~= "SquizzFrames" or type(payload.profile) ~= "table"
        or type(payload.profile.layout) ~= "table" then
        return nil, damaged
    end
    if payload.format ~= FORMAT then
        return nil, L["This string came from a newer version of SquizzFrames. Update first."]
            or "This string came from a newer version of SquizzFrames. Update first."
    end
    return payload
end

-----------------------------------------------------------------------
-- Cleaning an imported profile
-----------------------------------------------------------------------

local function CountMacros(profile)
    local count = 0
    if type(profile.clickCasting) == "table" then
        for _, binding in ipairs(profile.clickCasting) do
            if IsMacroBinding(binding) then count = count + 1 end
        end
    end
    return count
end

local function RemoveMacros(profile)
    local bindings = profile.clickCasting
    if type(bindings) ~= "table" then return end
    for i = #bindings, 1, -1 do
        if IsMacroBinding(bindings[i]) then tremove(bindings, i) end
    end
end

local function SpellExists(id)
    return type(id) ~= "number" or C_Spell.DoesSpellExist(id)
end

local function PruneSpellList(list)
    local removed = 0
    for i = #list, 1, -1 do
        if not SpellExists(list[i]) then
            tremove(list, i)
            removed = removed + 1
        end
    end
    return removed
end

local function PruneSpellLists(node)
    local removed = 0
    for key, value in pairs(node) do
        if type(value) == "table" then
            if SPELL_LIST_KEYS[key] then
                removed = removed + PruneSpellList(value)
            else
                removed = removed + PruneSpellLists(value)
            end
        end
    end
    return removed
end

local function PruneMissingSpells(profile)
    local removed = PruneSpellLists(profile.layout)
    local bindings = profile.clickCasting
    if type(bindings) == "table" then
        for i = #bindings, 1, -1 do
            local binding = bindings[i]
            if type(binding) == "table" and binding.type == "spell" and not SpellExists(binding.action) then
                tremove(bindings, i)
                removed = removed + 1
            end
        end
    end
    return removed
end

local function CleanName(name)
    name = tostring(name or ""):gsub("|", ""):match("^%s*(.-)%s*$")
    if #name > MAX_NAME then
        -- Drop the last character whole rather than leave half of a UTF-8 one.
        name = name:sub(1, MAX_NAME):gsub("[\192-\255][\128-\191]*$", "")
    end
    return name
end

local function UniqueName(name)
    local profiles = SquizzFrames.db.sv.profiles
    if name == "" then name = L["Imported"] or "Imported" end
    if not profiles[name] then return name end
    local n = 2
    while profiles[name .. " (" .. n .. ")"] do n = n + 1 end
    return name .. " (" .. n .. ")"
end

-----------------------------------------------------------------------
-- The dialog
-----------------------------------------------------------------------

local dialog

local function SetStatus(text, isError)
    dialog.status:SetText(text or "")
    if isError then
        dialog.status:SetTextColor(1, 0.35, 0.35, 1)
    else
        dialog.status:SetTextColor(0.8, 0.8, 0.8, 1)
    end
end

local function DescribePayload(payload)
    local lines = {
        (L["Profile \"%s\", from SquizzFrames %s."] or "Profile \"%s\", from SquizzFrames %s."):format(
            CleanName(payload.name), tostring(payload.version or "?")),
    }
    if payload.flavor ~= CurrentFlavor() then
        lines[#lines + 1] = L["Made on the other client: spells that don't exist here will be left out."]
            or "Made on the other client: spells that don't exist here will be left out."
    end
    if SquizzFrames.db:DraftIsDirty() then
        lines[#lines + 1] = L["Importing switches profile, which discards your unsaved Default changes."]
            or "Importing switches profile, which discards your unsaved Default changes."
    end
    return table.concat(lines, "\n")
end

local function OnImportTextChanged(text)
    local payload, err = ProfileTransfer.Decode(text)
    dialog.payload = payload
    dialog.keepMacros = false
    dialog.keepMacrosBox:SetChecked(false)

    local macros = payload and CountMacros(payload.profile) or 0
    dialog.keepMacrosBox:SetShown(macros > 0)
    dialog.macroCount = macros

    if payload then
        dialog.nameBox:SetText(CleanName(payload.name))
        SetStatus(DescribePayload(payload))
    else
        dialog.nameBox:SetText("")
        SetStatus(err, true)
    end
end

local function DoImport()
    local payload = dialog.payload
    if not payload then
        SetStatus(L["Paste a profile string first."] or "Paste a profile string first.", true)
        return
    end

    local profile = payload.profile
    local macrosRemoved = 0
    if not dialog.keepMacros then
        macrosRemoved = dialog.macroCount
        RemoveMacros(profile)
    end
    local spellsRemoved = 0
    if payload.flavor ~= CurrentFlavor() then
        spellsRemoved = PruneMissingSpells(profile)
    end

    local name = UniqueName(CleanName(dialog.nameBox:GetText()))
    SquizzFrames.db:ImportProfile(name, profile)
    dialog:Hide()

    SquizzFrames:Print((L["Imported profile '%s'."] or "Imported profile '%s'."):format(name))
    if InCombatLockdown() then
        SquizzFrames:Print(L["It will apply when combat ends."] or "It will apply when combat ends.")
    end
    if macrosRemoved > 0 then
        SquizzFrames:Print((L["Removed %d click-cast macro(s)."] or "Removed %d click-cast macro(s)."):format(macrosRemoved))
    end
    if spellsRemoved > 0 then
        SquizzFrames:Print((L["Left out %d spell(s) that don't exist on this client."]
            or "Left out %d spell(s) that don't exist on this client."):format(spellsRemoved))
    end
end

local function BuildDialog()
    -- Named so UISpecialFrames lets Escape close it.
    dialog = CreateFrame("Frame", "SquizzFramesProfileTransfer", UIParent, "BackdropTemplate")
    dialog:SetSize(480, 400)
    dialog:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    dialog:SetFrameStrata("DIALOG")
    dialog:SetClampedToScreen(true)
    dialog:EnableMouse(true)
    W.StylizeFrame(dialog, W.palette.DARK_BG, W.palette.POPUP_BORDER)
    tinsert(UISpecialFrames, "SquizzFramesProfileTransfer")

    dialog.title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dialog.title:SetPoint("TOP", 0, -12)

    dialog.status = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dialog.status:SetPoint("TOPLEFT", 15, -34)
    dialog.status:SetPoint("TOPRIGHT", -15, -34)
    dialog.status:SetJustifyH("LEFT")
    dialog.status:SetJustifyV("TOP")
    dialog.status:SetHeight(44)

    local scroll = CreateFrame("ScrollFrame", nil, dialog, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 15, -82)
    scroll:SetPoint("BOTTOMRIGHT", -34, 104)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetMaxLetters(0)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(430)
    edit:SetScript("OnEscapePressed", function() dialog:Hide() end)
    edit:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        if dialog.mode == "export" then
            -- Read-only: put back anything typed over the string.
            self:SetText(dialog.exportText or "")
            self:HighlightText()
        else
            OnImportTextChanged(self:GetText())
        end
    end)
    scroll:SetScrollChild(edit)
    scroll:SetScript("OnMouseDown", function() edit:SetFocus() end)
    dialog.edit = edit

    dialog.nameLabel = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dialog.nameLabel:SetPoint("BOTTOMLEFT", 15, 76)
    dialog.nameLabel:SetText(L["New profile name"] or "New profile name")

    dialog.nameBox = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
    dialog.nameBox:SetSize(220, 20)
    dialog.nameBox:SetPoint("LEFT", dialog.nameLabel, "RIGHT", 12, 0)
    dialog.nameBox:SetAutoFocus(false)
    dialog.nameBox:SetMaxLetters(MAX_NAME)
    dialog.nameBox:SetScript("OnEscapePressed", function() dialog:Hide() end)

    dialog.keepMacrosBox = W.CreateStyledCheckbox(dialog,
        L["Keep click-cast macros (only from someone you trust)"] or "Keep click-cast macros (only from someone you trust)",
        function() return dialog.keepMacros end,
        function(checked) dialog.keepMacros = checked end)
    dialog.keepMacrosBox:SetPoint("BOTTOMLEFT", 15, 44)

    dialog.importBtn = W.CreateStyledButton(dialog, L["Import"] or "Import", "accent-hover", {110, 22}, DoImport)
    dialog.importBtn:SetPoint("BOTTOMLEFT", 15, 12)

    dialog.closeBtn = W.CreateStyledButton(dialog, L["Close"] or "Close", nil, {110, 22}, function() dialog:Hide() end)
    dialog.closeBtn:SetPoint("BOTTOMRIGHT", -15, 12)
end

local function ShowMode(mode)
    if not dialog then BuildDialog() end
    dialog.mode = mode
    dialog.payload = nil
    dialog.keepMacros = false
    dialog.macroCount = 0

    local importing = mode == "import"
    dialog.nameLabel:SetShown(importing)
    dialog.nameBox:SetShown(importing)
    dialog.importBtn:SetShown(importing)
    dialog.keepMacrosBox:Hide()
    dialog.nameBox:SetText("")
    dialog.edit:SetText("")
    dialog:Show()
end

function ProfileTransfer.ShowExport()
    ShowMode("export")
    local name = SquizzFrames.db and SquizzFrames.db:GetCurrentProfile() or "?"
    dialog.title:SetText((L["Export Profile: %s"] or "Export Profile: %s"):format(name))

    local text, err = ProfileTransfer.Encode()
    if not text then
        dialog.exportText = nil
        SetStatus(err, true)
        return
    end
    dialog.exportText = text
    dialog.edit:SetText(text)
    dialog.edit:SetFocus()
    dialog.edit:HighlightText()
    SetStatus(L["Press Ctrl+C to copy, then share the string. Nicknames and the theme are not included."]
        or "Press Ctrl+C to copy, then share the string. Nicknames and the theme are not included.")
end

function ProfileTransfer.ShowImport()
    ShowMode("import")
    dialog.title:SetText(L["Import Profile"] or "Import Profile")
    dialog.edit:SetFocus()
    SetStatus(L["Paste a profile string below (Ctrl+V). It is added as a new profile; nothing you have is overwritten."]
        or "Paste a profile string below (Ctrl+V). It is added as a new profile; nothing you have is overwritten.")
end
