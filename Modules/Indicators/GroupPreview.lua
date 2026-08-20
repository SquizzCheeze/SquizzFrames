--[[ SquizzFrames GroupPreview.lua - Full-group indicator preview window ]]
--
-- A read-only window showing an entire party (5) or raid (20) of mock unit
-- frames at the profile's REAL configured sizes, with every enabled indicator
-- rendered using the same dummy-icon fallbacks the Designer's single-frame
-- preview uses.
--
-- Why it exists: judging indicator spacing/overlap/icon size from one frame is
-- guesswork. Indicators that look fine alone routinely collide once five (or
-- twenty) frames sit next to each other at real size.
--
-- This is purely additive. The Designer's own preview canvas
-- (IndicatorsPanel.lua's BuildPreviewCanvas) is unchanged and remains the
-- editing surface -- indicators are still selected and dragged there. Nothing
-- in this window is interactive.
--
-- How the mock frames get dummy data instead of real auras: every button here
-- is flagged via Indicators.lua's I.SetPreviewButton contract
-- (_sfIsPreviewButton), which is what every preview-rendering branch in
-- BuiltIn_Update.lua and AuraEngineIndicators.lua keys off. That flag is also
-- what stops the 12.1 AuraEngine path creating a real AuraContainer per
-- button -- 20 containers bound to a fake unit would leak the player's real
-- casts into the preview (a bug that actually happened with the single
-- Designer button before it was gated the same way).

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local W = SquizzFrames.Widgets
-- SquizzFrames.L carries an __index metatable returning the key itself, so a
-- missing locale entry degrades to the English string rather than nil.
local L = SquizzFrames.L

local GP = {}
SquizzFrames.GroupPreview = GP

-----------------------------------------------------------------------
-- State
-----------------------------------------------------------------------
local window              -- the window frame (lazily created)
local content             -- inner frame the mock buttons are parented to
local titleText
local buttons = {}        -- pooled mock buttons, index -> frame
local isRaidMode = false  -- which tab we're mirroring
local rebuildQueued = false

local PARTY_COUNT = 5
local RAID_COUNT = 20     -- 4 groups of 5
local RAID_GROUP_SIZE = 5
local PADDING = 14        -- gap between the block and the window edge
local TITLE_HEIGHT = 22
local MIN_WIDTH = 170     -- enough for the title text plus the close button

-- Sample roster so the preview reads like a real group rather than five
-- identical frames. Roles are ordered the way a real group sorts (tanks,
-- healers, then damage) so role-icon/sorting-sensitive indicators look
-- representative.
local SAMPLES = {
    { name = "Squizzums",  class = "WARRIOR",     role = "TANK" },
    { name = "Bearlyhere", class = "DRUID",       role = "TANK" },
    { name = "Lightwell",  class = "PRIEST",      role = "HEALER" },
    { name = "Mendicant",  class = "PALADIN",     role = "HEALER" },
    { name = "Rainfall",   class = "SHAMAN",      role = "HEALER" },
    { name = "Backstab",   class = "ROGUE",       role = "DAMAGER" },
    { name = "Pyroblast",  class = "MAGE",        role = "DAMAGER" },
    { name = "Felhound",   class = "WARLOCK",     role = "DAMAGER" },
    { name = "Quickshot",  class = "HUNTER",      role = "DAMAGER" },
    { name = "Windwalk",   class = "MONK",        role = "DAMAGER" },
    { name = "Deathwish",  class = "DEATHKNIGHT", role = "DAMAGER" },
    { name = "Vengeance",  class = "DEMONHUNTER", role = "DAMAGER" },
    { name = "Dracthyr",   class = "EVOKER",      role = "DAMAGER" },
}

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

local function GetLayout()
    local layout = SquizzFrames.db and SquizzFrames.db.profile and SquizzFrames.db.profile.layout
    if not layout then return nil end
    return isRaidMode and layout.raid or layout.main
end

-- Real configured button dimensions for the mode being previewed. Mirrors
-- IndicatorsPanel.lua's GetRealButtonDimensions (party 100x40, raid 70x24 by
-- default) -- the "correct sizes" requirement means reading these, never a
-- mock size.
local function GetButtonDimensions()
    local l = GetLayout()
    if isRaidMode then
        return (l and l.width) or 70, (l and l.height) or 24, (l and l.powerHeight) or 3
    end
    return (l and l.width) or 100, (l and l.height) or 40, (l and l.powerHeight) or 4
end

-- The profile's UI scale, which the LIVE container carries via
-- partyFrame:SetScale (PartyFrames.lua's CreatePartyContainer). Mock buttons
-- are children of this window, not that container, so they have to apply it
-- themselves or they render at raw width/height -- identical to live at scale
-- 1.0 and proportionally wrong either side of it.
--
-- Applied per BUTTON rather than to the content frame, mirroring the same fix
-- in PartyFrames.lua's LayoutPreviewButtons: a button's SetPoint offsets are
-- interpreted in its OWN scaled space, so scaling the button makes both its
-- rendered size AND the gaps between buttons resolve to the same screen
-- values as live, for free. Keeping the content frame unscaled also leaves
-- this window's padding/title chrome in true screen pixels.
local function GetUIScale()
    local prof = SquizzFrames.db and SquizzFrames.db.profile
    return (prof and prof.appearance and prof.appearance.general
        and prof.appearance.general.scale) or 1.0
end

-- Fake unit data, same field contract BuiltIn_Update.lua reads (_sfFake*).
-- Values mirror Indicators.lua's InitPreviewData, including the deliberately
-- STATIC health/power numbers: reading a real UnitHealth here would defeat the
-- point of a guaranteed-safe mockup the moment the player's own health is a
-- secret number (see that function's comment for the full history).
local function ApplyFakeData(button, index)
    local sample = SAMPLES[((index - 1) % #SAMPLES) + 1]
    button._sfFakeName = sample.name
    button._sfFakeClass = sample.class
    button._sfFakeRole = sample.role
    button._sfFakeThreat = 0
    -- Only the first frame draws the target highlight -- on every frame it
    -- would read as a rendering bug rather than a highlight.
    button._sfFakeTarget = (index == 1)
    button._sfFakeLeader = (index == 1)
    button._sfFakeRaidIcon = ((index - 1) % 8) + 1
    button._sfFakeReady = "ready"
    button._sfFakeConnection = true
    button._sfFakeFlags = 0
    -- Vary the health a little so health bars/text don't all read identically,
    -- but keep it fully static (never derived from a real unit).
    local pct = 0.45 + ((index * 7) % 11) * 0.05
    button._sfFakeHealth = math.floor(100000 * pct)
    button._sfFakeHealthMax = 100000
    button._sfFakePower = 65000
    button._sfFakePowerMax = 100000
    button._sfFakeIsConnected = true
    button._sfFakeIsAFK = false
    button._sfFakeIsDead = false
    button._sfFakeIsGhost = false
    button._sfFakeAssistant = false
end

-- Apply health/power bar appearance to one mock button.
--
-- Modelled on Indicators.lua's UpdatePreviewAppearance, with one necessary
-- difference: that function resolves class colour from
-- F.GetClassFile("player") because it only ever styles a single button. Here
-- every frame is a different pretend class, so the colour comes from that
-- button's own _sfFakeClass -- otherwise all 20 frames render in the player's
-- class colour, which defeats the point of previewing a group.
--
-- Without this the bars keep the flat green the mock factory hardcodes.
local function ApplyAppearance(button)
    if not button or not button.healthBar or not button.powerBar then return end
    local db = SquizzFrames.db and SquizzFrames.db.profile
    local appearance = db and db.appearance
    if not appearance then return end

    local LSM = LibStub and LibStub:GetLibrary("LibSharedMedia-3.0", true)
    local texture = LSM and LSM:Fetch("statusbar",
        (appearance.general and appearance.general.texture) or "Blizzard")
    if not texture then texture = [[Interface\TargetingFrame\UI-StatusBar]] end
    button.healthBar:SetStatusBarTexture(texture)
    button.powerBar:SetStatusBarTexture(texture)

    -- Health: mirrors PartyFrames.lua's UpdateHealth _sfFakeName branch
    -- exactly, including its fallbacks. Note the else-branch is NOT gated on
    -- fullColor[1] == "custom_color" -- the live frames treat ANY non-
    -- class_color mode as "read the RGB out of indices 2-4", so gating on the
    -- literal string here would leave the bar on the factory's flat green for
    -- any other mode.
    local maxHP = button._sfFakeHealthMax or 100
    button.healthBar:SetMinMaxValues(0, maxHP)
    button.healthBar:SetValue(button._sfFakeHealth or maxHP)

    local col = appearance.healthBar and appearance.healthBar.fullColor
    local useClass = col and col[1] == "class_color"
    if useClass and button._sfFakeClass then
        local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[button._sfFakeClass]
        if cc then button.healthBar:SetStatusBarColor(cc.r, cc.g, cc.b, 1) end
    else
        local r = col and col[2] or 0.2
        local g = col and col[3] or 0.8
        local b = col and col[4] or 0.2
        button.healthBar:SetStatusBarColor(r, g, b, 1)
    end

    -- Power: mirrors PartyFrames.lua's UpdatePower _sfFakeName branch, which
    -- deliberately falls back to MANA's stock colour rather than reading the
    -- player's live power type -- a mock frame has no power type of its own.
    button.powerBar:SetMinMaxValues(0, 100)
    button.powerBar:SetValue(100)
    local pcol = appearance.powerBar and appearance.powerBar.powerColor
    if pcol and pcol[1] == "class_color" and button._sfFakeClass then
        local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[button._sfFakeClass]
        if cc then button.powerBar:SetStatusBarColor(cc.r, cc.g, cc.b, 0.8) end
    elseif pcol and pcol[1] == "custom_color" then
        button.powerBar:SetStatusBarColor(pcol[2] or 1, pcol[3] or 1, pcol[4] or 1, 0.8)
    else
        local colors = (PowerBarColor and PowerBarColor["MANA"]) or {r = 1, g = 1, b = 1}
        button.powerBar:SetStatusBarColor(colors.r, colors.g, colors.b, 0.8)
    end
end

local function GetOrCreateButton(index, w, h, powerH, scale)
    local button = buttons[index]
    if not button then
        local Indicators = SquizzFrames.Indicators
        local factory = Indicators and Indicators.CreateMockUnitButton
        if not factory then return nil end
        -- MUST have a global name. Several built-in indicator factories build
        -- their child frame's name from the owning button's
        -- (BuiltIn_Update.lua's CreateIconIndicator does
        -- `CreateFrame("Frame", button:GetName() .. name, button)`), so an
        -- anonymous button throws "attempt to concatenate a nil value" the
        -- moment an icon indicator like statusIcon/leaderIcon/aggroBlink is
        -- enabled. The Designer's own preview button is named for the same
        -- reason. Index-based so it stays stable across rebuilds (buttons are
        -- pooled and reused per index, so no name is ever claimed twice).
        button = factory(content, "SquizzFramesGroupPreviewButton" .. index, w, h, powerH)
        -- Purely a display. Mouse off so clicks fall through to whatever is
        -- behind, and so nothing here can ever be dragged or targeted.
        button:EnableMouse(false)
        buttons[index] = button
    else
        button:SetSize(w, h)
        if button.powerBar then button.powerBar:SetHeight(powerH) end
    end
    -- Match the live container's UI scale so this renders 1:1 with the real
    -- frames (see GetUIScale). Re-applied on every rebuild, not just at
    -- creation, so changing the Scale slider updates pooled buttons too.
    button:SetScale(scale or 1)
    -- Marks this as a mock frame for every preview-rendering branch, and gives
    -- it its own raid/party context (I.IsRaidContext reads this per button, so
    -- this window and the Designer canvas can't fight over one global).
    button._sfIsPreviewButton = true
    button._sfPreviewIsRaid = isRaidMode
    return button
end

-----------------------------------------------------------------------
-- Layout
--
-- Mirrors the geometry PartyFrames.lua's LayoutPreviewButtons produces, but
-- anchored inside this window instead of against UIParent -- so there's no
-- anchor-point, screen-offset or container-scale math to reproduce here. The
-- block is laid out from the content frame's TOPLEFT and the window is then
-- sized to fit it.
--
-- Returns the block's total width/height so the caller can size the window.
-----------------------------------------------------------------------
local function LayoutButtons()
    local layout = GetLayout()
    if not layout then return 0, 0 end

    local w, h, powerH = GetButtonDimensions()
    local scale = GetUIScale()
    local spacing = layout.spacingY or 0
    local orientation = layout.orientation or "vertical"
    local growthDir = layout.growthDirection or "DOWN"
    local count = isRaidMode and RAID_COUNT or PARTY_COUNT

    -- Growth direction decides the block's AXIS...
    local isHorizontal
    if growthDir == "CENTER_H" then
        isHorizontal = true
    elseif growthDir == "CENTER_V" then
        isHorizontal = false
    else
        isHorizontal = (orientation == "horizontal")
    end

    -- ...and, for UP/LEFT, the fill ORDER. The block itself is always drawn
    -- from this window's top-left (it's a fixed panel, not the frames' real
    -- screen position), but which END of it unit 1 occupies is a real,
    -- visible layout property: with growth UP the player sits at the BOTTOM
    -- of the column, not the top. Reversing the slot index reproduces that
    -- without moving the block.
    --
    -- CENTER_H/CENTER_V aren't reversed -- they centre their axis rather than
    -- growing from an end, so their order matches the default direction.
    local reverse = (growthDir == "UP") or (growthDir == "LEFT")
    local function SlotIndex(idx, total)
        if reverse then return total - 1 - idx end
        return idx
    end

    local blockW, blockH = 0, 0

    if isRaidMode then
        -- Raid: subgroups of 5. orientation is reinterpreted one level up
        -- (see Layout_Defaults.lua's comment on profile.layout.raid) --
        -- vertical means each subgroup is a COLUMN and subgroups sit side by
        -- side; horizontal means each subgroup is a ROW and they stack.
        local groupSpacing = layout.groupSpacing or 6
        local numGroups = math.ceil(count / RAID_GROUP_SIZE)
        local vertical = (orientation ~= "horizontal")

        for i = 1, count do
            local button = GetOrCreateButton(i, w, h, powerH, scale)
            if not button then break end
            local groupIdx = math.floor((i - 1) / RAID_GROUP_SIZE)
            -- Direction applies WITHIN a subgroup (that's the level
            -- growthDirection operates at for raid -- see Layout_Defaults);
            -- subgroup order itself is always left-to-right / top-to-bottom.
            local slotIdx = SlotIndex((i - 1) % RAID_GROUP_SIZE, RAID_GROUP_SIZE)
            local x, y
            if vertical then
                x = groupIdx * (w + groupSpacing)
                y = -(slotIdx * (h + spacing))
            else
                x = slotIdx * (w + spacing)
                y = -(groupIdx * (h + groupSpacing))
            end
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
            button:Show()
        end

        if vertical then
            blockW = numGroups * w + (numGroups - 1) * groupSpacing
            blockH = RAID_GROUP_SIZE * h + (RAID_GROUP_SIZE - 1) * spacing
        else
            blockW = RAID_GROUP_SIZE * w + (RAID_GROUP_SIZE - 1) * spacing
            blockH = numGroups * h + (numGroups - 1) * groupSpacing
        end
    else
        for i = 1, count do
            local button = GetOrCreateButton(i, w, h, powerH, scale)
            if not button then break end
            local idx = SlotIndex(i - 1, count)
            local x, y = 0, 0
            if isHorizontal then
                x = idx * (w + spacing)
            else
                y = -(idx * (h + spacing))
            end
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
            button:Show()
        end

        if isHorizontal then
            blockW = count * w + (count - 1) * spacing
            blockH = h
        else
            blockW = w
            blockH = count * h + (count - 1) * spacing
        end
    end

    -- Hide any pooled buttons beyond the current count (party after raid).
    for i = count + 1, #buttons do
        if buttons[i] then buttons[i]:Hide() end
    end

    -- Converted to SCREEN units for the caller. blockW/blockH were summed
    -- from unscaled width/height/spacing values, but every button carries the
    -- profile scale -- so the block's actual footprint, and therefore the
    -- window that has to contain it, is that much bigger or smaller.
    return blockW * scale, blockH * scale
end

-----------------------------------------------------------------------
-- Window
-----------------------------------------------------------------------

local function CreateWindow()
    if window then return window end

    local optionsFrame = _G["SquizzFramesOptionsFrame"]
    if not optionsFrame then return nil end

    window = CreateFrame("Frame", "SquizzFramesGroupPreview", UIParent, "BackdropTemplate")
    -- Match the options panel's strata (DIALOG/520) rather than sitting at
    -- HIGH, where any other DIALOG-strata frame would cover this one. A level
    -- just below the panel's keeps the panel on top if they ever overlap.
    window:SetFrameStrata("DIALOG")
    window:SetFrameLevel(510)
    window:Hide()
    if W and W.StylizeFrame then
        W.StylizeFrame(window, {0.1, 0.1, 0.1, 0.95}, {0, 0, 0, 1})
    end
    -- Pinned to the options panel's left edge and moves with it (user's
    -- choice: fixed, not draggable).
    window:SetPoint("TOPRIGHT", optionsFrame, "TOPLEFT", -6, 0)

    titleText = window:CreateFontString(nil, "OVERLAY")
    titleText:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    titleText:SetPoint("TOPLEFT", window, "TOPLEFT", PADDING, -6)

    local closeBtn = CreateFrame("Button", nil, window)
    closeBtn:SetSize(18, 18)
    closeBtn:SetPoint("TOPRIGHT", window, "TOPRIGHT", -5, -4)
    local closeText = closeBtn:CreateFontString(nil, "OVERLAY")
    closeText:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    closeText:SetPoint("CENTER")
    closeText:SetText("x")
    closeText:SetTextColor(0.8, 0.8, 0.8, 1)
    closeBtn:SetScript("OnClick", function() GP.Hide() end)
    closeBtn:SetScript("OnEnter", function() closeText:SetTextColor(1, 0.3, 0.3, 1) end)
    closeBtn:SetScript("OnLeave", function() closeText:SetTextColor(0.8, 0.8, 0.8, 1) end)

    -- Everything the mock buttons anchor into. Kept separate from `window` so
    -- the title bar doesn't have to be accounted for in the layout math.
    content = CreateFrame("Frame", nil, window)
    content:SetPoint("TOPLEFT", window, "TOPLEFT", PADDING, -TITLE_HEIGHT)

    -- The options panel owning this window is the only thing that should keep
    -- it alive -- closing the panel closes the preview too.
    optionsFrame:HookScript("OnHide", function() GP.Hide() end)

    return window
end

-- Rebuild the whole preview: re-layout at current sizes, re-apply fake data,
-- and re-run the indicator pipeline on every button.
function GP.Rebuild()
    if not window or not window:IsShown() then return end

    local Indicators = SquizzFrames.Indicators
    if not Indicators or not Indicators.HandleIndicators then return end

    local blockW, blockH = LayoutButtons()

    local CustomDispatch = SquizzFrames.modules and SquizzFrames.modules["Custom_Dispatch"]
    local count = isRaidMode and RAID_COUNT or PARTY_COUNT
    for i = 1, count do
        local button = buttons[i]
        if button then
            -- Fake data BEFORE HandleIndicators: HandleIndicators ends with
            -- its own BuiltIn.CheckAll pass, and if _sfFakeHealth/-Max aren't
            -- set by then, CheckHealthText falls through to its LIVE branch
            -- and touches real (possibly secret) values -- the exact ordering
            -- bug documented in Indicators.lua's BuildPreview.
            ApplyFakeData(button, i)
            Indicators.HandleIndicators(button)
            -- ...and custom-indicator fake aura data AFTER, since InitPreview
            -- only populates indicators that already exist in
            -- button.indicators (same reason BuildPreview orders it this way).
            if CustomDispatch and CustomDispatch.InitPreview then
                CustomDispatch.InitPreview(button)
            end
            -- Last, mirroring BuildPreview's ordering (UpdatePreviewAppearance
            -- is its final step): bar texture/colour and fill are pure
            -- styling and must not be undone by the indicator pipeline's own
            -- Check pass.
            ApplyAppearance(button)
        end
    end

    content:SetSize(math.max(blockW, 1), math.max(blockH, 1))
    -- MIN_WIDTH keeps the title bar and close button readable: a vertical
    -- party block is only one button wide (100px, less at scale < 1), which
    -- would otherwise clip "Party Preview (5)" and crowd the X.
    window:SetSize(math.max(blockW + PADDING * 2, MIN_WIDTH),
        blockH + TITLE_HEIGHT + PADDING)

    if titleText then
        titleText:SetText(isRaidMode
            and string.format(L["Raid Preview (%d)"] or "Raid Preview (%d)", RAID_COUNT)
            or string.format(L["Party Preview (%d)"] or "Party Preview (%d)", PARTY_COUNT))
    end
end

-- Coalesces bursts of rebuilds (a slider drag fires UpdateIndicators every
-- frame). Mirrors Indicators.lua's own QueuePreviewRebuild.
function GP.QueueRebuild()
    if rebuildQueued then return end
    if not window or not window:IsShown() then return end
    rebuildQueued = true
    C_Timer.After(0.05, function()
        rebuildQueued = false
        GP.Rebuild()
    end)
end

-- Point the window at a party or raid group. Called by the Indicators tab's
-- Party/Raid toggle so the preview always mirrors the tab being edited.
function GP.SetRaidMode(raid)
    raid = not not raid
    if isRaidMode == raid then return end
    isRaidMode = raid
    -- Every pooled button's per-button context has to move with it, otherwise
    -- buttons built under the old mode would keep reading the old indicator
    -- list (I.IsRaidContext reads _sfPreviewIsRaid per button).
    for _, button in pairs(buttons) do
        button._sfPreviewIsRaid = isRaidMode
    end
    GP.Rebuild()
end

function GP.Show()
    if not CreateWindow() then return end
    window:Show()
    GP.Rebuild()
    SquizzFrames:Fire("GroupPreviewToggled", true)
end

function GP.Hide()
    if not window then return end
    window:Hide()
    SquizzFrames:Fire("GroupPreviewToggled", false)
end

function GP.IsShown()
    return window and window:IsShown() or false
end

function GP.Toggle()
    if GP.IsShown() then GP.Hide() else GP.Show() end
end

-----------------------------------------------------------------------
-- Message wiring
--
-- Indicator setting changes arrive via Indicators.lua's QueuePreviewRebuild
-- (which calls GP.QueueRebuild directly). These two cover the other things
-- that change what the window should be showing:
--   LayoutChanged  -- frame width/height/spacing edited on the Layout tab
--   ProfileChanged -- a whole different set of sizes and indicator lists
--
-- Registered on private owners: CallbackHandler keys by (owner, message), so
-- registering these on the SquizzFrames root would silently replace whatever
-- else already listens for them (see Utils.lua's F.NewMessageOwner).
-----------------------------------------------------------------------
local F = SquizzFrames.F
if F and F.NewMessageOwner then
    F.NewMessageOwner():RegisterMessage("LayoutChanged", function()
        GP.QueueRebuild()
    end)
    -- The UI Scale slider fires its own message, not LayoutChanged -- and
    -- scale is exactly what makes this window render 1:1 with the live
    -- frames, so it has to be followed too.
    F.NewMessageOwner():RegisterMessage("ScaleChanged", function()
        GP.QueueRebuild()
    end)
    F.NewMessageOwner():RegisterMessage("ProfileChanged", function()
        GP.QueueRebuild()
    end)
end
