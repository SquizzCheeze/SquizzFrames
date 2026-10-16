--[[ SquizzFrames PartyPreview.lua -- the Layout page's mock party/raid grid.
    Moved out of PartyFrames.lua unchanged in 2.0 (phase 2 code split). It
    reads the few private PartyFrames helpers it needs from
    PartyFrames.shared, which PartyFrames.lua publishes at load. ]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F
local L = SquizzFrames.L
---@class AceModule
local PartyFrames = SquizzFrames:GetModule("PartyFrames")

local shared = PartyFrames.shared
local GetProfile = shared.GetProfile
local GetAnchorPoint = shared.GetAnchorPoint
local AnchorPointFactors = shared.AnchorPointFactors
local ScreenAnchorCoords = shared.ScreenAnchorCoords
local UpdateHealth = shared.UpdateHealth
local UpdatePower = shared.UpdatePower
local UpdateStatus = shared.UpdateStatus
local resolveChildren = shared.resolveChildren
-- A getter, not a value: the container is created after this file loads.
local GetPartyFrame = shared.GetPartyFrame

-----------------------------------------------------------------------
-- Layout preview: mock party/raid grid shown at the real container's
-- screen position, using real data for slots with an actual member and fake
-- data for the rest -- lets you see the configured layout without needing a
-- full group. Deliberately does NOT force-show/reuse the secure header's
-- real children: SecureGroupHeaderTemplate's internal child-flow is a
-- protected black box keyed off real unit existence, and there is no
-- sanctioned way to make it flow a child whose unit doesn't really exist.
-- Instead this builds a small pool of ordinary (non-secure) buttons on the
-- same UI template and positions them with plain SetPoint math mirroring
-- ApplyLayout's own point/spacing/growth formulas. This is a parallel
-- implementation of that math (same drift risk noted for the raid grouping
-- math elsewhere in this file) -- acceptable since it's read-only/visual and
-- the formulas themselves are simple.
-----------------------------------------------------------------------

local previewButtons = {}
local previewActive = false
local previewIsRaidTab = false
local previewCount = 0
local previewMover

-- Cycled per empty slot so the mock grid reads as a real mixed roster
-- instead of identical clones (matches the reference screenshot's varied
-- colored boxes).
local PREVIEW_SAMPLES = {
    {name = "Tank",     class = "WARRIOR",     role = "TANK"},
    {name = "Healer",   class = "PRIEST",      role = "HEALER"},
    {name = "Melee 1",  class = "ROGUE",       role = "DAMAGER"},
    {name = "Melee 2",  class = "DEATHKNIGHT", role = "DAMAGER"},
    {name = "Ranged 1", class = "MAGE",        role = "DAMAGER"},
    {name = "Ranged 2", class = "WARLOCK",     role = "DAMAGER"},
    {name = "Healer 2", class = "DRUID",       role = "HEALER"},
    {name = "Tank 2",   class = "PALADIN",     role = "TANK"},
}

-- Aura/cooldown/absorb-type indicators are hidden in the preview regardless
-- of whether the underlying slot is real or fake data -- the user wants
-- "just the buttons and roles," not whatever debuffs/cooldowns the real
-- member(s) happen to have active right now.
local PREVIEW_HIDDEN_INDICATORS = {
    externalCooldowns = true, defensiveCooldowns = true, debuffs = true,
    ccIndicator = true, dispels = true, missingBuffs = true, healerHots = true,
    shieldBar = true, shieldOverlay = true, healAbsorb = true,
}

local function GetOrCreatePreviewButton(index)
    local btn = previewButtons[index]
    if btn then return btn end
    btn = CreateFrame("Button", "SquizzFramesPreviewButton" .. index, UIParent, "SquizzFramesUnitButtonTemplate")
    btn:Hide()
    -- Mark these as PREVIEW buttons (Indicators.lua's I.IsPreviewButton).
    --
    -- Without it every AuraEngine-backed indicator took its LIVE path here and
    -- built a real AuraContainer per preview slot -- bound to a real unit
    -- token, since ApplyPreviewButtonData keeps button.unit populated. The
    -- engine pre-creates a 10-button batch per container and WoW never
    -- destroys frames, so a 40-slot raid preview permanently stranded 400
    -- aura buttons for Healer HoTs alone, and as many again for every other
    -- aura indicator. That's exactly the 400 the runtime dump reported.
    --
    -- Pure waste, too: PREVIEW_HIDDEN_INDICATORS hides all of those on this
    -- preview anyway, so the containers were built and then never shown.
    btn._sfIsPreviewButton = true
    previewButtons[index] = btn
    return btn
end

local function ApplyPreviewButtonData(button, unit, sampleIndex)
    -- button.unit MUST stay non-nil even for fake slots -- every Check/
    -- Update function guards with "if not unit then return end" BEFORE it
    -- ever looks at _sfFakeXxx, so clearing it here made every fake slot
    -- bail out before reaching its fake-data branch at all (confirmed bug:
    -- only the real player slot rendered, every fake slot stayed blank).
    -- The placeholder token itself is never actually queried live -- every
    -- Check function checks its _sfFakeXxx field first and only falls
    -- through to a real Unit* call when that's absent, which never happens
    -- here since the two are always set together.
    button.unit = unit
    if unit and UnitExists(unit) then
        button._sfFakeName = nil
        button._sfFakeClass = nil
        button._sfFakeRole = nil
        button._sfFakeHealth = nil
        button._sfFakeHealthMax = nil
    else
        local sample = PREVIEW_SAMPLES[((sampleIndex - 1) % #PREVIEW_SAMPLES) + 1]
        button._sfFakeName = sample.name
        button._sfFakeClass = sample.class
        button._sfFakeRole = sample.role
        button._sfFakeHealth = 100
        button._sfFakeHealthMax = 100
    end
end

local function RefreshPreviewButton(button, bw, bh, powerH)
    resolveChildren(button, bw, bh, powerH)
    local Indicators = SquizzFrames.modules and SquizzFrames.modules["Indicators"]
    if Indicators and Indicators.HandleIndicators then
        Indicators.HandleIndicators(button)
    end
    for name in pairs(PREVIEW_HIDDEN_INDICATORS) do
        local ind = button.indicators and button.indicators[name]
        if ind then ind:Hide() end
    end
    UpdateHealth(button)
    UpdatePower(button)
    UpdateStatus(button)
end

-- Lays out `count` preview buttons at the previewed layout's real saved
-- screen anchor, mirroring ApplyLayout's point/spacing/growth math: party is
-- a single strip, raid is grouped columns of <=5 (see Layout_Defaults.lua's
-- comment on profile.layout.raid for the orientation/growthDirection
-- reinterpretation). Takes previewRaid explicitly rather than calling
-- IsInRaid() -- the preview follows whichever tab is being EDITED in the
-- options panel (matches EllesmereUIRaidFrames' own preview, which resolves
-- settings from the currently-open tab's proxy, not real group state), which
-- is very often different from the player's actual current group state.
-- anchorXOverride/anchorYOverride (optional, RAW pixels from screen center,
-- same convention as the saved anchorX/anchorY): used while dragging the
-- preview mover, so the grid can be repositioned live without writing to the
-- profile on every mouse-move tick -- only the final position gets saved.
local function LayoutPreviewButtons(count, previewRaid, anchorXOverride, anchorYOverride)
    local prof = GetProfile()
    local layout = prof and prof.layout and (previewRaid and prof.layout.raid or prof.layout.main)
    if not layout then return end
    local scale = (prof.appearance and prof.appearance.general and prof.appearance.general.scale) or 1.0
    local bw = layout.width or 100
    local bh = layout.height or 40
    local spacing = layout.spacingY or 0
    local orientation = layout.orientation or "vertical"
    local growthDir = layout.growthDirection or "DOWN"
    -- Convert the saved anchor into the "offset from screen centre, in button
    -- space" that every block-placement expression below already assumes,
    -- so the anchor-point feature needs no changes to that math at all.
    --
    -- Two corrections, both no-ops for the default CENTER anchor (which is
    -- why this reduces to the previous `anchorX / scale`):
    --   1. the anchor's own screen position vs the centre (originX - sw/2)
    --   2. block CENTRE vs block ANCHOR POINT -- live pins `point` to
    --      `point`, so with e.g. TOPLEFT the block's top-left is what sits on
    --      the saved offset, and the centre it's laid out around is half a
    --      block away from it.
    local rawAnchorX = anchorXOverride or layout.anchorX or 0
    local rawAnchorY = anchorYOverride or layout.anchorY or -200
    local anchorPoint = GetAnchorPoint(layout)
    local groupSpacing = layout.groupSpacing or 6

    -- Block footprint in button space, mirroring how each branch lays out.
    local blockW, blockH
    if previewRaid then
        local numGroups = math.ceil(count / 5)
        local maxSlots = math.min(5, count)
        if orientation ~= "horizontal" then
            blockW = numGroups * bw + (numGroups - 1) * groupSpacing
            blockH = maxSlots * bh + (maxSlots - 1) * spacing
        else
            blockW = maxSlots * bw + (maxSlots - 1) * spacing
            blockH = numGroups * bh + (numGroups - 1) * groupSpacing
        end
    else
        local isHorizontal
        if growthDir == "CENTER_H" then
            isHorizontal = true
        elseif growthDir == "CENTER_V" then
            isHorizontal = false
        else
            isHorizontal = (orientation == "horizontal")
        end
        if isHorizontal then
            blockW = count * bw + (count - 1) * spacing
            blockH = bh
        else
            blockW = bw
            blockH = count * bh + (count - 1) * spacing
        end
    end

    local fx, fy = AnchorPointFactors(anchorPoint)
    local originX, originY = ScreenAnchorCoords(anchorPoint)
    local sw, sh = GetScreenWidth(), GetScreenHeight()
    local anchorX = (rawAnchorX + originX - sw / 2) / scale + (0.5 - fx) * blockW
    local anchorY = (rawAnchorY + originY - sh / 2) / scale + (0.5 - fy) * blockH

    if previewRaid then
        local numGroups = math.ceil(count / 5)
        local vertical = (orientation ~= "horizontal")
        local isCenterH = (growthDir == "CENTER_H")
        local isCenterV = (growthDir == "CENTER_V")
        for i = 1, count do
            local button = GetOrCreatePreviewButton(i)
            button:SetSize(bw, bh)
            -- Same scale as the live container (2026-08-07). Preview buttons
            -- are unscaled children of UIParent, but the real frames live
            -- inside partyFrame, which has SetScale(profile scale) applied.
            -- Without this the preview rendered buttons at bw instead of
            -- bw*scale AND, because the anchor offsets below are pre-divided
            -- by scale, positioned the block at anchorX/scale instead of
            -- anchorX -- so preview and live agreed only at scale 1.0 and
            -- drifted proportionally either side of it ("close, but not
            -- lined up"). Matching the scale makes both the offsets and the
            -- sizes resolve to the same screen values as live.
            button:SetScale(scale)
            button:SetFrameStrata("HIGH")
            local groupIdx = math.floor((i - 1) / 5)              -- 0-based
            local slotIdx = (i - 1) % 5                            -- 0-based, within group
            button:ClearAllPoints()
            -- Centre the WHOLE block on the anchor, matching live -- see the
            -- party branch below for the full reasoning. The unit axis is
            -- centred on maxSlots (the tallest/longest group), NOT on this
            -- group's own size, so every group stays aligned with the others
            -- exactly as the secure header lays them out; centring each group
            -- independently would stagger a partial last group.
            local maxSlots = math.min(5, count)
            local slotCentred = slotIdx - (maxSlots - 1) / 2
            if vertical then
                -- Each group is a vertical column; groups sit side by side.
                local totalW = numGroups * bw + (numGroups - 1) * groupSpacing
                local colX = -totalW / 2 + bw / 2 + groupIdx * (bw + groupSpacing)
                local rowSign = (isCenterV or growthDir ~= "UP") and -1 or 1
                local rowY = rowSign * slotCentred * (bh + spacing)
                button:SetPoint("CENTER", UIParent, "CENTER", anchorX + colX, anchorY + rowY)
            else
                -- Each group is a horizontal row; groups stack vertically.
                local totalH = numGroups * bh + (numGroups - 1) * groupSpacing
                local rowY = totalH / 2 - bh / 2 - groupIdx * (bh + groupSpacing)
                local colSign = (not isCenterH and growthDir == "LEFT") and -1 or 1
                local colX = colSign * slotCentred * (bw + spacing)
                button:SetPoint("CENTER", UIParent, "CENTER", anchorX + colX, anchorY + rowY)
            end
            button:Show()
        end
    else
        for i = 1, count do
            local button = GetOrCreatePreviewButton(i)
            button:SetSize(bw, bh)
            -- Same scale as the live container (2026-08-07). Preview buttons
            -- are unscaled children of UIParent, but the real frames live
            -- inside partyFrame, which has SetScale(profile scale) applied.
            -- Without this the preview rendered buttons at bw instead of
            -- bw*scale AND, because the anchor offsets below are pre-divided
            -- by scale, positioned the block at anchorX/scale instead of
            -- anchorX -- so preview and live agreed only at scale 1.0 and
            -- drifted proportionally either side of it ("close, but not
            -- lined up"). Matching the scale makes both the offsets and the
            -- sizes resolve to the same screen values as live.
            button:SetScale(scale)
            button:SetFrameStrata("HIGH")
            button:ClearAllPoints()
            -- The BLOCK is centred on the saved anchor, matching live
            -- (bug fix 2026-08-07). Live anchors the container CENTER ->
            -- CENTER, shrink-wraps it to the visible buttons, and centres
            -- the header inside it -- so the block's CENTRE always sits on
            -- the saved point, whatever the growth direction; growth only
            -- decides fill ORDER. The preview instead put the FIRST BUTTON
            -- on the anchor and grew away from it, so what you positioned in
            -- preview sat up to half a block away from where the real frames
            -- appeared (5 party frames at 40px = 80px out). CENTER_H/CENTER_V
            -- were the only modes that happened to agree -- which is why the
            -- shared centring term below reproduces them exactly.
            local idx = i - 1 -- 0-based
            local x, y = anchorX, anchorY
            local isHorizontal
            if growthDir == "CENTER_H" then
                isHorizontal = true
            elseif growthDir == "CENTER_V" then
                isHorizontal = false
            else
                isHorizontal = (orientation == "horizontal")
            end
            local centred = idx - (count - 1) / 2
            if isHorizontal then
                local sign = (growthDir == "LEFT") and -1 or 1
                x = anchorX + sign * centred * (bw + spacing)
            else
                local sign = (growthDir == "UP") and 1 or -1
                y = anchorY + sign * centred * (bh + spacing)
            end
            button:SetPoint("CENTER", UIParent, "CENTER", x, y)
            button:Show()
        end
    end
end

-- Bounding box (UIParent coords) of every currently-shown preview button --
-- used to size/position the preview mover's border and drag hit-area.
local function GetPreviewBoundingBox()
    local l, r, t, b
    local us = UIParent:GetEffectiveScale() or 1
    for _, button in pairs(previewButtons) do
        if button:IsShown() then
            local bl, br, bt, bb = button:GetLeft(), button:GetRight(), button:GetTop(), button:GetBottom()
            -- Convert the button's own (scaled) coordinate space into
            -- UIParent's, which is what the caller anchors the mover in.
            -- Preview buttons carry the profile's UI scale (see
            -- LayoutPreviewButtons), so at any scale other than 1.0 these
            -- edges are NOT UIParent-space values -- mixing them would put
            -- the drag border and hit-area in the wrong place, the same
            -- coordinate-space mistake ContainerCenterInUIParentSpace exists
            -- to prevent for the live container.
            local bs = (button:GetEffectiveScale() or us) / us
            if bl and br and bt and bb then
                bl, br, bt, bb = bl * bs, br * bs, bt * bs, bb * bs
                l = l and math.min(l, bl) or bl
                r = r and math.max(r, br) or br
                t = t and math.max(t, bt) or bt
                b = b and math.min(b, bb) or bb
            end
        end
    end
    return l, r, t, b
end

-- Preview mode auto-enables a drag handle over the whole mock grid (no
-- separate "enter edit mode" step needed) so the previewed position can be
-- set without needing a real group. Mirrors CreatePartyContainer's real
-- mover -- same 4-edge-texture border, same drag math (raw pixels from
-- screen center) -- but targets the previewed layout's anchor (via
-- previewIsRaidTab) instead of GetActiveLayout()'s real-state binding, and
-- repositions the loose previewButtons pool instead of a single container.
local function GetOrCreatePreviewMover()
    if previewMover then return previewMover end
    local mover = CreateFrame("Frame", "SquizzFramesPreviewMover", UIParent)
    SquizzFrames.SnapTarget(mover)
    mover:SetFrameStrata("HIGH")
    mover:SetFrameLevel(50)
    mover:EnableMouse(true)
    mover:SetMovable(true)
    -- Deliberately NOT RegisterForDrag -- see the container mover above: the
    -- drag-system threshold makes the first moment of every drag feel dead.
    mover:Hide()

    local accent = F.GetAccentColor()
    local function MakeBorder()
        local tex = mover:CreateTexture(nil, "OVERLAY")
        tex:SetColorTexture(accent.r, accent.g, accent.b, 0.9)
        return tex
    end
    mover.borderTop = MakeBorder()
    mover.borderBottom = MakeBorder()
    mover.borderLeft = MakeBorder()
    mover.borderRight = MakeBorder()

    mover.label = mover:CreateFontString(nil, "OVERLAY")
    mover.label:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    mover.label:SetPoint("BOTTOM", mover, "TOP", 0, 2)
    mover.label:SetTextColor(accent.r, accent.g, accent.b, 1)
    mover.label:SetText(L["Preview — drag to move"] or "Preview — drag to move")

    local dragOffsetX, dragOffsetY = 0, 0
    local dragging = false

    local StopPreviewDrag

    local function StartPreviewDrag(self)
        if dragging then return end
        dragging = true
        local prof = GetProfile()
        local layout = prof and prof.layout and (previewIsRaidTab and prof.layout.raid or prof.layout.main)
        local pScale = UIParent:GetEffectiveScale()
        local startCursorX, startCursorY = GetCursorPosition()
        startCursorX = startCursorX / pScale
        startCursorY = startCursorY / pScale
        -- Measure against the previewed layout's own anchor point, matching
        -- the live container mover -- otherwise dragging the preview would
        -- write an offset in a different reference frame than the one
        -- ApplyContainerAnchor reads it back in.
        local anchorPoint = GetAnchorPoint(layout)
        local originX, originY = ScreenAnchorCoords(anchorPoint)
        local frameCX = originX + (layout and layout.anchorX or 0)
        local frameCY = originY + (layout and layout.anchorY or 0)
        local cursorOffX = frameCX - startCursorX
        local cursorOffY = frameCY - startCursorY
        dragOffsetX = layout and layout.anchorX or 0
        dragOffsetY = layout and layout.anchorY or 0

        self:SetScript("OnUpdate", function(f)
            -- Self-heal for a mouse-up that never reached us -- the mover's
            -- own border is repositioned under the cursor every tick, so a
            -- fast drag can outrun it and release off-frame.
            if not IsMouseButtonDown("LeftButton") then
                StopPreviewDrag(f)
                return
            end
            local cx, cy = GetCursorPosition()
            local ps = UIParent:GetEffectiveScale()
            cx = cx / ps
            cy = cy / ps
            local ox, oy = ScreenAnchorCoords(anchorPoint)
            dragOffsetX = (cx + cursorOffX) - ox
            dragOffsetY = (cy + cursorOffY) - oy
            LayoutPreviewButtons(previewCount, previewIsRaidTab, dragOffsetX, dragOffsetY)
            PartyFrames:RefreshPreviewMoverBounds()
            -- Snap, measured on the mover: it is the preview's bounds.
            local sdx, sdy = SquizzFrames.SnapDelta(f)
            if sdx ~= 0 or sdy ~= 0 then
                dragOffsetX, dragOffsetY = dragOffsetX + sdx, dragOffsetY + sdy
                LayoutPreviewButtons(previewCount, previewIsRaidTab, dragOffsetX, dragOffsetY)
                PartyFrames:RefreshPreviewMoverBounds()
            end
        end)
    end

    -- Declared as a local above so the OnUpdate's release check can call it.
    function StopPreviewDrag(self)
        if not dragging then return end
        dragging = false
        self:SetScript("OnUpdate", nil)
        SquizzFrames.SnapClear()
        local prof = GetProfile()
        local layout = prof and prof.layout and (previewIsRaidTab and prof.layout.raid or prof.layout.main)
        if layout then
            layout.anchorX = dragOffsetX
            layout.anchorY = dragOffsetY
        end
        LayoutPreviewButtons(previewCount, previewIsRaidTab)
        PartyFrames:RefreshPreviewMoverBounds()
    end

    mover:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then StartPreviewDrag(self) end
    end)
    mover:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then StopPreviewDrag(self) end
    end)
    -- Closing the options panel mid-drag would otherwise strand the OnUpdate.
    mover:SetScript("OnHide", function(self) StopPreviewDrag(self) end)

    previewMover = mover
    return mover
end

-- Resizes/repositions the preview mover's border + hit-area to match the
-- current preview grid's bounding box. Called after every layout/drag
-- update so the drag handle always matches whatever's actually on screen.
function PartyFrames:RefreshPreviewMoverBounds()
    if not previewMover or not previewMover:IsShown() then return end
    local l, r, t, b = GetPreviewBoundingBox()
    if not l then return end
    -- l/r/t/b are in UIParent's own coordinate units (button:GetLeft() etc.
    -- are already measured from UIParent's BOTTOMLEFT = (0,0), same
    -- convention SetPoint offsets use) -- t is the TOP (max Y), b is the
    -- BOTTOM (min Y); do not swap these.
    local pad = 4
    previewMover:ClearAllPoints()
    previewMover:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l - pad, t + pad)
    previewMover:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMLEFT", r + pad, b - pad)

    local thick = 2
    previewMover.borderTop:ClearAllPoints()
    previewMover.borderTop:SetPoint("TOPLEFT", previewMover, "TOPLEFT", 0, 0)
    previewMover.borderTop:SetPoint("TOPRIGHT", previewMover, "TOPRIGHT", 0, 0)
    previewMover.borderTop:SetHeight(thick)

    previewMover.borderBottom:ClearAllPoints()
    previewMover.borderBottom:SetPoint("BOTTOMLEFT", previewMover, "BOTTOMLEFT", 0, 0)
    previewMover.borderBottom:SetPoint("BOTTOMRIGHT", previewMover, "BOTTOMRIGHT", 0, 0)
    previewMover.borderBottom:SetHeight(thick)

    previewMover.borderLeft:ClearAllPoints()
    previewMover.borderLeft:SetPoint("TOPLEFT", previewMover, "TOPLEFT", 0, 0)
    previewMover.borderLeft:SetPoint("BOTTOMLEFT", previewMover, "BOTTOMLEFT", 0, 0)
    previewMover.borderLeft:SetWidth(thick)

    previewMover.borderRight:ClearAllPoints()
    previewMover.borderRight:SetPoint("TOPRIGHT", previewMover, "TOPRIGHT", 0, 0)
    previewMover.borderRight:SetPoint("BOTTOMRIGHT", previewMover, "BOTTOMRIGHT", 0, 0)
    previewMover.borderRight:SetWidth(thick)
end

-- Public: toggles the layout preview on/off. `previewRaid` explicitly says
-- whether to mock up the Party or Raid shape -- pass the options panel's
-- currently-selected tab (activeLayoutKey == "raid"), NOT real IsInRaid();
-- defaults to real IsInRaid() only if omitted (e.g. the combat auto-disable
-- path, which doesn't care about shape since it's turning preview off).
-- Combat handling (bug fix 2026-08-07): previewButtons are created from
-- SquizzFramesUnitButtonTemplate (secure), and partyFrame is the secure
-- header's ancestor, so every Show()/Hide() below is protected. This used to
-- be a blanket `if InCombatLockdown() then return end` placed BEFORE
-- `previewActive = enabled` -- which broke the combat auto-disable
-- (PLAYER_REGEN_DISABLED fires when lockdown is ALREADY true, so the
-- SetPreviewMode(false) call returned immediately): previewActive stayed
-- true, the mock buttons stayed on screen and the real frames stayed hidden
-- for the whole fight, while "PreviewModeChanged, false" fired anyway so the
-- options button showed "off". Now the STATE flag updates immediately (so
-- callers/UI see the truth) and only the protected frame work defers to
-- combat end.
local previewRetryFrame
local pendingPreview
function PartyFrames:SetPreviewMode(enabled, previewRaid)
    previewActive = enabled

    if InCombatLockdown() then
        pendingPreview = { enabled = enabled, previewRaid = previewRaid }
        if not previewRetryFrame then
            previewRetryFrame = CreateFrame("Frame")
            previewRetryFrame:SetScript("OnEvent", function(self)
                self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                local p = pendingPreview
                pendingPreview = nil
                if p then PartyFrames:SetPreviewMode(p.enabled, p.previewRaid) end
            end)
        end
        previewRetryFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    pendingPreview = nil

    if not enabled then
        for _, button in pairs(previewButtons) do
            button:Hide()
        end
        if previewMover then previewMover:Hide() end
        local partyFrame = GetPartyFrame()
        if partyFrame then partyFrame:Show() end
        return
    end

    if previewRaid == nil then previewRaid = IsInRaid() end
    previewIsRaidTab = previewRaid

    local partyFrame = GetPartyFrame()
    if partyFrame then partyFrame:Hide() end

    local prof = GetProfile()
    local layout = prof and prof.layout and (previewRaid and prof.layout.raid or prof.layout.main)
    local count
    if previewRaid then
        count = (layout and layout.raidSize) or 40
    else
        count = 5
    end

    LayoutPreviewButtons(count, previewRaid)

    local slotUnits
    if previewRaid then
        slotUnits = {}
        for i = 1, count do slotUnits[i] = "raid" .. i end
    else
        slotUnits = { "player", "party1", "party2", "party3", "party4" }
    end

    -- Hide any leftover buttons from a previous, larger preview (e.g.
    -- switching from a 40-man raid preview down to a 5-man party preview).
    for i, button in pairs(previewButtons) do
        if i > count then button:Hide() end
    end

    local bw = layout and layout.width or 100
    local bh = layout and layout.height or 40
    -- Passed explicitly for the same reason bw/bh are (see resolveChildren's
    -- comment): `layout` here is the tab being PREVIEWED, while
    -- resolveChildren's own fallback reads GetActiveLayout(), which follows
    -- the player's real group state and would be the wrong mode's value.
    local powerH = layout and layout.powerHeight or (previewIsRaidTab and 3 or 4)
    for i = 1, count do
        local button = previewButtons[i]
        -- Preview buttons carry their own Party/Raid context rather than
        -- following the player's real group state (see I.IsRaidContext), so
        -- this has to track the tab being previewed -- otherwise a Raid
        -- preview would render the Party indicator list.
        button._sfPreviewIsRaid = not not previewIsRaidTab
        ApplyPreviewButtonData(button, slotUnits[i], i)
        RefreshPreviewButton(button, bw, bh, powerH)
    end

    previewCount = count

    -- Auto-enable drag-to-move for the preview -- no separate "enter edit
    -- mode" step needed, since there's no group to be disrupted by editing.
    local mover = GetOrCreatePreviewMover()
    mover:Show()
    self:RefreshPreviewMoverBounds()
end

function PartyFrames:IsPreviewActive()
    return previewActive
end

-- Re-runs the preview for whichever mode is currently active (used when the
-- options panel's Party/Raid tab or Raid Size changes while previewing).
function PartyFrames:RefreshPreviewMode()
    if not previewActive then return end
    self:SetPreviewMode(true, previewIsRaidTab)
end
