--[[ SquizzFrames Pet Frames options page

    A pure shell over profile.petFrames -- every control reads and writes that
    tree and then fires "PetFramesChanged", which PetFrames.lua turns into a
    layout pass. Nothing here touches frames directly, the same discipline
    NicknamesPanel, UnitFramesPanel and TankTrackerPanel follow.

    EXTRACTED FROM OptionsFrame.lua (2026-09-10). It lived there alongside the
    General, Layout and Profiles pages, and its ~49 accessors were the single
    largest contributor to that file hitting BOTH of Lua's per-function
    ceilings -- 60 upvalues and 200 active locals -- either of which stops the
    WHOLE options panel loading. See CLAUDE.md's "OptionsFrame.lua is at TWO
    Lua ceilings".

    Moving a page into its own FILE is the real fix rather than collapsing
    accessors into tables: each file is its own Lua main function, so this page
    now has a fresh 200-local budget of its own instead of sharing one.

    OptionsFrame keeps a ~12-line shim that creates the page frame and calls
    Panel.Build, exactly as it already did for the five pages that were split
    out earlier.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local L = SquizzFrames.L
local F = SquizzFrames.F
local W = SquizzFrames.Widgets

local Panel = {}
SquizzFrames.PetFramesPanel = Panel

-- Re-declared rather than shared with OptionsFrame: these panels reach the
-- profile directly (SquizzFrames.db.profile) instead of importing a file-local
-- from another file, which is what lets each one be independent.
local function GetProfile()
    return SquizzFrames.db and SquizzFrames.db.profile
end

local activePetLayoutKey = "main"
local rebuildPetFields -- forward declaration; set by Panel.Build

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

    -- The standalone player's-own-pet frame shares every accessor on this page
    -- (they all read GetActivePetFrameLayout, which the toggle repoints), but
    -- it has no mode, no owner to attach to and no sibling pets to flow
    -- against -- so the Positioning section collapses to a drag hint and the
    -- Match Owner options are dropped entirely.
    local isPlayerPet = activePetLayoutKey == "player"

    W.CreateTitledPane(fieldsHost, L["General"] or "General", yOffset)
    yOffset = yOffset - 35

    local enableLabel = isPlayerPet
        and (L["Enable My Pet Frame"] or "Enable My Pet Frame")
        or (L["Enable Pet Frames"] or "Enable Pet Frames")
    local cbEnable = W.CreateStyledCheckbox(fieldsHost, enableLabel, GetPetEnabled, SetPetEnabled)
    cbEnable:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 30

    if isPlayerPet then
        local note = fieldsHost:CreateFontString(nil, "OVERLAY")
        note:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        note:SetPoint("TOPLEFT", 15, yOffset)
        note:SetWidth(340)
        note:SetJustifyH("LEFT")
        note:SetTextColor(0.7, 0.7, 0.7, 1)
        note:SetText(L["Your own pet, on its own frame, in every group state. While this is on your pet is removed from the Party and Raid pet layouts so it can't appear twice."]
            or "Your own pet, on its own frame, in every group state. While this is on your pet is removed from the Party and Raid pet layouts so it can't appear twice.")
        yOffset = yOffset - 40
    end
    yOffset = yOffset - 5

    W.CreateTitledPane(fieldsHost, L["Sizing"] or "Sizing", yOffset)
    yOffset = yOffset - 35

    -- Only offered in attached mode: a floating pet group is detached from the
    -- party frames entirely, so there's no owner beside it for the size to
    -- read as "matching" (ResolvePetSize ignores the settings there too). The
    -- standalone frame never has an owner at all.
    local attached = not isPlayerPet and GetPetMode() == "attached"
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

    if isPlayerPet then
        -- No mode switch: "attached" would mean attaching to your own party
        -- button, which is the arrangement this frame exists to avoid. It has
        -- one screen position, dragged in Edit Mode like the floating group.
        local playerLabel = fieldsHost:CreateFontString(nil, "OVERLAY")
        playerLabel:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        playerLabel:SetPoint("TOPLEFT", 15, yOffset)
        playerLabel:SetTextColor(0.7, 0.7, 0.7, 1)
        playerLabel:SetText(L["Drag your pet frame in Edit Mode to position it."]
            or "Drag your pet frame in Edit Mode to position it.")
        yOffset = yOffset - 25
        return
    end

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


-- Entry point. The frame is created and registered by OptionsFrame's shim;
-- everything inside it is this file's business.
function Panel.Build(frame)

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
    -- A third sibling rather than a section bolted onto Party/Raid: it edits
    -- profile.petFrames.player, a peer table of .main/.raid, and this toggle
    -- already does exactly the "swap which table every accessor reads" job
    -- that needs. Unlike the other two it is NOT group-scoped (see
    -- PetFrames_Defaults.lua) -- one position, honoured in every group state.
    MakeToggleButton("player", L["My Pet"] or "My Pet", 205)
    RefreshToggleVisual()

    rebuildPetFields = function() BuildPetFrameFields(frame) end
    rebuildPetFields()

    F.NewMessageOwner():RegisterMessage("ProfileChanged", function() rebuildPetFields() end)
end
