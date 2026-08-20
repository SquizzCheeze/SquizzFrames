--[[ SquizzFrames PartyFrames Module
    Layout and secure header techniques adapted from Cell (by Dandre) and DandersFrames.
    All code has been rewritten for SquizzFrames and is not a copy/paste. ]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F
local L = SquizzFrames.L
local LSM = LibStub and LibStub:GetLibrary("LibSharedMedia-3.0", true)
local RC = LibStub and LibStub:GetLibrary("LibRangeCheck-3.0", true)
---@class AceModule
local PartyFrames = SquizzFrames:NewModule("PartyFrames", "AceEvent-3.0")

-- Local state
local partyFrame      -- main container
local header           -- secure group header (party/solo)
local unitButtons = {} -- [unit] = button

-- Raid subgroup headers: raid mode is driven by EIGHT secure headers (one per
-- subgroup, groupFilter="1".."8") instead of the single `header` above.
--
-- Why (2026-08-20): a SecureGroupHeaderTemplate supports exactly ONE groupBy,
-- and when groupBy is set the WITHIN-bucket order can only be name or raid
-- index -- sortMethod="NAMELIST" is ignored outright in that branch (read from
-- Blizzard_RestrictedAddOnEnvironment/SecureGroupHeaders.lua: the
-- `if groupBy then ... elseif sortMethod == "NAME"` chain never consults the
-- nameList sorter). One header can therefore give you subgroup columns OR role
-- sorting, never both -- Sort By Role used to set groupBy="ASSIGNEDROLE",
-- which threw the subgroups away and re-bucketed the whole raid into
-- tank/healer/dps columns.
--
-- Narrowing each header to one subgroup with groupFilter FIRST means
-- groupBy="ASSIGNEDROLE" sorts within that subgroup, which is what the setting
-- always implied. Same structure DandersFrames uses (Frames/Headers.lua).
--
-- A second, quieter bug fixed by the same change: configureChildren chunks its
-- flat sorted list every `unitsPerColumn` buttons, so with one header a
-- partially-filled subgroup spilled the NEXT group's members into its column.
-- A per-group header only ever holds its own group, so it can't.
local RAID_GROUP_COUNT = 8
local groupHeaders = {}        -- [1..8] = secure header for raid subgroup N
local raidGroupSlots = {}      -- [subgroup] = visual slot index (1-based)
local raidGroupCounts = {}     -- [subgroup] = member count, from the last census
local activeHeaderScratch = {} -- reused by ActiveHeaders(), never held onto
local initialized = false
local rangeTicker -- out-of-range alpha poll, started in OnEnable's init()
local panelVisibilityTicker -- Blizzard special-frame visibility poll, started in OnEnable's init()
-- [frame] = true for every UIPanelWindows-managed panel currently open, per
-- ShowUIPanel/HideUIPanel hooks installed once in OnEnable's init() -- see
-- ApplyBlizzardPanelVisibility's comment for why this exists instead of
-- polling UIPanelWindows' frame names directly.
local openBlizzardPanels = {}
local blizzardPanelHooksInstalled = false
-- Forward-declared: defined near OnDisable, much further down this file, but
-- OnEnable's init() (just below) needs to call them to start the poll. Lua
-- locals aren't visible to code already parsed before they're declared, even
-- though init() only actually RUNS later -- same trap BuiltIn_Update.lua's
-- CreateDispelsIndicatorLegacy hit.
local RebuildRangeChecker, UpdateRangeAlpha, ResetRangeAlpha
-- Also forward-declared: WireUpAllButtons (defined well above ApplyLayout)
-- needs to re-invoke it when it detects the header configured for the wrong
-- group mode -- see the reconciliation block in WireUpAllButtons.
local ApplyLayout
-- Same reason: the container mover's OnDragStop (created inside
-- CreatePartyContainer, well above the definition) re-asserts the dragged
-- position through ApplyContainerAnchor so the anchor point, scale
-- compensation and default fallbacks all stay in one place. Without this
-- forward declaration that closure would capture a nil GLOBAL instead.
local ApplyContainerAnchor

-- Profile accessor
local function GetProfile()
    return SquizzFrames.db and SquizzFrames.db.profile
end

-- Party and raid have independent layout sub-tables (separate size, growth,
-- spacing, screen position). This is the single switch point every layout-
-- reading/writing call site goes through, so party <-> raid transitions
-- can never leave one code path still reading/writing the wrong sub-table.
-- Edit mode can temporarily pin the layout to a specific mode so the user can
-- adjust the RAID layout while actually in a party (and vice versa) against
-- real, real-scale frames instead of the mock preview. nil = follow reality.
-- Only ever set while edit mode is on; SetEditMode(false) always clears it.
local editLayoutOverride = nil

local function GetActiveLayout(prof)
    prof = prof or GetProfile()
    if not prof or not prof.layout then return nil end
    if editLayoutOverride then
        return prof.layout[editLayoutOverride]
    end
    if IsInRaid() then
        return prof.layout.raid
    end
    return prof.layout.main
end

-- Which layout key edit mode is currently pointed at, override or not.
-- Used by the edit-mode toggle UI and by anything that needs to label the
-- layout being edited rather than the one that's really active.
local function GetEditLayoutKey()
    return editLayoutOverride or (IsInRaid() and "raid" or "main")
end

-- The DEFAULT anchor for whichever mode is currently active.
--
-- Party and Raid are separate layouts with separate default positions
-- (Layout_Defaults.lua: main sits at y=-200, raid at y=+200). Several
-- places used to hardcode the PARTY default unconditionally -- both
-- "something went wrong, reset the position" paths, plus the `or -200`
-- fallbacks when reading a missing anchor -- so a reset (or a missing
-- value) while in a raid dumped the raid frames onto the party's spot,
-- making the two modes look like they shared one position. Bug fix
-- 2026-08-07, confirmed by user report ("raid jumps to party's spot").
--
-- Reads the real defaults table so it can't drift from what
-- Layout_Defaults actually ships.
local function GetDefaultAnchorForActiveMode()
    local defLayout = SquizzFrames.defaults and SquizzFrames.defaults.profile
        and SquizzFrames.defaults.profile.layout
    local defMode = defLayout and (IsInRaid() and defLayout.raid or defLayout.main)
    local fallbackY = IsInRaid() and 200 or -200
    if defMode then
        return defMode.anchorX or 0, defMode.anchorY or fallbackY
    end
    return 0, fallbackY
end

-----------------------------------------------------------------------
-- Screen anchor point (party and raid each have their own)
--
-- The container is pinned POINT -> POINT against UIParent (the same point on
-- both sides, as Cell/ElvUI do), with layout.anchorX/anchorY as the offset
-- between them. Historically this was hardcoded CENTER/CENTER; anchorPoint
-- defaults to "CENTER" so every existing profile's saved offsets keep their
-- exact meaning and need no migration.
--
-- Why it's worth exposing: with CENTER, growing the container (a member
-- joins, or you raise Height) expands it evenly in both directions, so the
-- block visibly drifts. Pinning TOPLEFT/TOP/etc keeps that edge nailed down
-- and grows away from it, and makes the saved position survive a resolution
-- change instead of sliding.
--
-- WoW keeps a POINT->POINT anchor correct across resizes on its own, so
-- nothing has to be recomputed when the container is re-sized -- that's why
-- ApplyContainerAnchor stays a plain SetPoint.
-----------------------------------------------------------------------

local VALID_ANCHOR_POINTS = {
    CENTER = true, TOP = true, BOTTOM = true, LEFT = true, RIGHT = true,
    TOPLEFT = true, TOPRIGHT = true, BOTTOMLEFT = true, BOTTOMRIGHT = true,
}

local function GetAnchorPoint(layout)
    local p = layout and layout.anchorPoint
    if p and VALID_ANCHOR_POINTS[p] then return p end
    return "CENTER"
end

-- Fractional position of a named anchor point within a rect, as (fx, fy)
-- where 0,0 is BOTTOMLEFT and 1,1 is TOPRIGHT (WoW's y axis points up).
-- Substring tests handle the compound points: "TOPLEFT" matches both TOP and
-- LEFT, while plain "TOP" leaves fx at its 0.5 default.
local function AnchorPointFactors(point)
    point = point or "CENTER"
    local fx, fy = 0.5, 0.5
    if point:find("LEFT") then fx = 0 elseif point:find("RIGHT") then fx = 1 end
    if point:find("TOP") then fy = 1 elseif point:find("BOTTOM") then fy = 0 end
    return fx, fy
end

-- Where a given anchor point sits on the screen, in UIParent coords. This is
-- what the drag handlers measure the container's offset against -- they used
-- to hardcode sw/2, sh/2, which is exactly this for CENTER.
local function ScreenAnchorCoords(point)
    local fx, fy = AnchorPointFactors(point)
    return GetScreenWidth() * fx, GetScreenHeight() * fy
end

-- Resolve the configured health/power bar texture via LSM. Falls back to the
-- stock Blizzard bar if LSM is missing or the saved key was never registered
-- (e.g. the addon that registered it got disabled).
local function GetBarTexture()
    local prof = GetProfile()
    local key = prof and prof.appearance and prof.appearance.general and prof.appearance.general.texture or "Blizzard"
    local texture = LSM and LSM:Fetch("statusbar", key)
    return texture or [[Interface\TargetingFrame\UI-StatusBar]]
end

-----------------------------------------------------------------------
-- Container sizing: keep partyFrame shrink-wrapped to visible buttons
-----------------------------------------------------------------------

-- The outer container is always sized to fit the maximum number of buttons
-- (5 for a party). The anchor point is locked to a fixed screen position
-- and never changes. This means the box stays put on screen as members
-- join/leave — buttons fill in from the appropriate edge (or from center
-- for center growth). No position shift on roster changes.
-- Retry frame for SizeContainerToButtons' combat bail-out below -- the
-- frame object is created once and reused across every combat encounter;
-- RegisterEvent is re-armed on every bail-out (harmless if already
-- registered) since the handler unregisters itself after each fire.
local sizeRetryFrame

-- Scans wired raid buttons to find which of the 8 subgroups currently have
-- at least one visible member, and the largest member count among them.
-- Used by both SizeContainerToButtons and SizeEditFrameToButtons's raid
-- sizing so the container shrink-wraps to the actual populated grid instead
-- of always reserving the full 8x5.
-- Census of which raid subgroups actually have members, read from the RAID
-- ROSTER rather than by walking header children.
--
-- Walking children stopped being possible with per-group headers: each header
-- only knows its own subgroup, and a header whose group is empty still keeps
-- its (hidden, unit-less) children, so a walk can't tell "empty group" from
-- "not populated yet". Reading the roster also produces the census BEFORE the
-- headers have re-sorted, which is exactly when the slot assignment needs it.
--
-- Also assigns each subgroup a visual SLOT: populated groups take slots 1..k in
-- ascending group order, then the empty ones take what's left. Empty groups are
-- deliberately still given a slot (rather than being hidden) so that a member
-- joining an empty group DURING COMBAT still appears -- parked just past the
-- last populated block until the next out-of-combat pass tidies the order.
-- Header SetPoint is protected, so nothing can re-slot mid-fight.
--
-- Secret-value hazard, same one the old header-walk guarded: GetRaidRosterInfo's
-- subgroup can be secret in 12.1 and it INDEXES A TABLE here. An unreadable
-- entry falls back to group 1 rather than crashing (an unreadable roster then
-- degrades to a single-group shape, which still renders).
local function CensusRaidGroups()
    wipe(raidGroupCounts)
    wipe(raidGroupSlots)

    local num = GetNumGroupMembers() or 0
    for i = 1, num do
        local subgroup = select(3, GetRaidRosterInfo(i))
        local g = 1
        if F.IsValueNonSecret(subgroup) and type(subgroup) == "number"
            and subgroup >= 1 and subgroup <= RAID_GROUP_COUNT then
            g = subgroup
        end
        raidGroupCounts[g] = (raidGroupCounts[g] or 0) + 1
    end

    local slot, numGroups, maxPerGroup = 0, 0, 0
    for g = 1, RAID_GROUP_COUNT do
        local count = raidGroupCounts[g]
        if count then
            slot = slot + 1
            raidGroupSlots[g] = slot
            numGroups = numGroups + 1
            if count > maxPerGroup then maxPerGroup = count end
        end
    end
    for g = 1, RAID_GROUP_COUNT do
        if not raidGroupSlots[g] then
            slot = slot + 1
            raidGroupSlots[g] = slot
        end
    end

    return numGroups, maxPerGroup
end

local function GetRaidGridShape()
    local numGroups, maxPerGroup = CensusRaidGroups()
    if numGroups == 0 then numGroups = 1 end
    if maxPerGroup == 0 then maxPerGroup = 1 end
    return numGroups, maxPerGroup
end

-- The headers currently driving the display: the eight subgroup headers in a
-- raid, the single party header otherwise. Every "walk the buttons" loop goes
-- through here, so raid mode can't silently keep reading the party header's
-- (now unit-less, hidden) children -- or vice versa.
--
-- Returns a REUSED table; copy it if you need to hold on to it.
local function ActiveHeaders()
    wipe(activeHeaderScratch)
    if IsInRaid() and groupHeaders[1] then
        for i = 1, RAID_GROUP_COUNT do
            if groupHeaders[i] then tinsert(activeHeaderScratch, groupHeaders[i]) end
        end
    elseif header then
        tinsert(activeHeaderScratch, header)
    end
    return activeHeaderScratch
end

-- Walk every unit button of every currently-active header. `fn(button, header)`.
local function ForEachHeaderButton(fn)
    local headers = ActiveHeaders()
    -- Snapshot: fn may itself call ActiveHeaders (which wipes the scratch).
    local snapshot = {}
    for i = 1, #headers do snapshot[i] = headers[i] end
    for _, h in ipairs(snapshot) do
        for _, button in ipairs(h) do
            if button then fn(button, h) end
        end
    end
end

local function SizeContainerToButtons()
    if not partyFrame or not header then return end
    -- partyFrame:SetSize is protected in combat (it's the secure header's
    -- container). Retry once combat ends so the container doesn't stay at
    -- a stale size.
    if InCombatLockdown() then
        if not sizeRetryFrame then
            sizeRetryFrame = CreateFrame("Frame")
            sizeRetryFrame:SetScript("OnEvent", function(self)
                self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                SizeContainerToButtons()
            end)
        end
        sizeRetryFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    local prof = GetProfile()
    -- realLayout is nil when the profile isn't loaded yet; `layout` keeps the
    -- empty-table fallback so the sizing maths below can read defaults off it
    -- without nil checks. The re-anchor at the end deliberately uses
    -- realLayout, so a not-yet-loaded profile can't slam the container to the
    -- built-in default position.
    local realLayout = GetActiveLayout(prof)
    local layout = realLayout or {}
    local spacing = layout.spacingY or 0
    local orientation = layout.orientation or "vertical"

    local firstBtn
    ForEachHeaderButton(function(button)
        if not firstBtn then firstBtn = button end
    end)
    local bW = (firstBtn and firstBtn:GetWidth()) or (layout.width or 100)
    local bH = (firstBtn and firstBtn:GetHeight()) or (layout.height or 40)

    -- Size the container to the visible button footprint. Because the
    -- container is anchored CENTER→CENTER, shrinking/growing it around its
    -- fixed center point does NOT shift the position on screen — it only
    -- changes how much padding surrounds the buttons. This eliminates the
    -- empty draggable strip that a fixed 5-button size would leave.
    if IsInRaid() then
        -- Raid is a 2D grid: subgroups (up to 8) x members within a subgroup
        -- (up to 5), shrink-wrapped to only the currently populated shape.
        local numGroups, maxPerGroup = GetRaidGridShape()
        local groupSpacing = layout.groupSpacing or 6
        if orientation == "horizontal" then
            -- Each subgroup is a horizontal row; subgroups stack vertically.
            partyFrame:SetSize(maxPerGroup * bW + (maxPerGroup - 1) * spacing + 6,
                numGroups * bH + (numGroups - 1) * groupSpacing + 6)
        else
            -- Each subgroup is a vertical column; subgroups sit side by side.
            partyFrame:SetSize(numGroups * bW + (numGroups - 1) * groupSpacing + 6,
                maxPerGroup * bH + (maxPerGroup - 1) * spacing + 6)
        end
    else
        -- Party path: single strip, up to 5.
        local visibleCount = 0
        ForEachHeaderButton(function(button)
            if button:IsShown() and button.unit and UnitExists(button.unit) then
                visibleCount = visibleCount + 1
            end
        end)
        if visibleCount == 0 then visibleCount = 1 end

        if orientation == "horizontal" then
            partyFrame:SetSize(visibleCount * bW + (visibleCount - 1) * spacing + 6, bH + 6)
        else
            partyFrame:SetSize(bW + 6, visibleCount * bH + (visibleCount - 1) * spacing + 6)
        end
    end

    -- Re-assert the saved position after EVERY resize.
    --
    -- This is the single choke point every container size change goes
    -- through, which makes it the one place that can guarantee the container
    -- always ends up exactly where the profile says -- no matter which code
    -- path triggered the resize. Idempotent (it just re-runs ClearAllPoints +
    -- SetPoint from the saved anchor), so calling it here costs nothing even
    -- when ApplyLayout already anchored a moment earlier.
    --
    -- Part of the same 2026-08-08 fix as the header anchor above: previously
    -- only ApplyLayout re-anchored, which is exactly why a loading screen
    -- "fixed" a drifted position while a roster change never did.
    if realLayout then
        ApplyContainerAnchor(prof, realLayout)
    end
end

-----------------------------------------------------------------------
-- Edit frame sizing: snap the edit overlay to enclose all visible buttons
-----------------------------------------------------------------------

local function SizeEditFrameToButtons()
    if not partyFrame or not partyFrame.editFrame then return end
    local editFrame = partyFrame.editFrame
    if not header then
        editFrame:Hide()
        return
    end

    -- Collect visible buttons
    local visible = {}
    ForEachHeaderButton(function(button)
        if button:IsShown() and button.unit and UnitExists(button.unit) then
            tinsert(visible, button)
        end
    end)

    if #visible == 0 then
        editFrame:Hide()
        return
    end

    -- Find the visually top-left-most and bottom-right-most buttons by
    -- comparing actual screen rects, then anchor the edit frame to BOTH
    -- corners at once (WoW auto-sizes a frame between two opposite anchor
    -- points, no SetSize needed). This works for any layout shape -- party's
    -- single strip or center growth, or raid's 2D subgroup grid -- without
    -- assuming header iteration order matches visual order, unlike the old
    -- formula-based approach (which only handled a single strip/spread).
    local pad = 3
    local topLeftBtn, bottomRightBtn = visible[1], visible[1]
    local bestTop, bestLeft = visible[1]:GetTop(), visible[1]:GetLeft()
    local bestBottom, bestRight = visible[1]:GetBottom(), visible[1]:GetRight()
    for i = 2, #visible do
        local btn = visible[i]
        local t, l, b, r = btn:GetTop(), btn:GetLeft(), btn:GetBottom(), btn:GetRight()
        if t and l and bestTop and (t > bestTop or (t == bestTop and l < bestLeft)) then
            topLeftBtn, bestTop, bestLeft = btn, t, l
        end
        if b and r and bestBottom and (b < bestBottom or (b == bestBottom and r > bestRight)) then
            bottomRightBtn, bestBottom, bestRight = btn, b, r
        end
    end

    if not bestTop or not bestBottom then
        -- Buttons don't have valid rects yet (laid out later this tick).
        editFrame:Hide()
        return
    end

    editFrame:ClearAllPoints()
    editFrame:SetPoint("TOPLEFT", topLeftBtn, "TOPLEFT", -pad, pad)
    editFrame:SetPoint("BOTTOMRIGHT", bottomRightBtn, "BOTTOMRIGHT", pad, -pad)

    -- Border edges need explicit sizes -- read back the now-resolved rect.
    local editWidth, editHeight = editFrame:GetWidth(), editFrame:GetHeight()

    -- Position border edges around the frame
    local thick = 2
    do
        editFrame.borderTop:ClearAllPoints()
        editFrame.borderTop:SetSize(editWidth, thick)
        editFrame.borderTop:SetPoint("TOPLEFT", editFrame, "TOPLEFT", 0, 0)
        editFrame.borderTop:SetPoint("TOPRIGHT", editFrame, "TOPRIGHT", 0, 0)

        editFrame.borderBottom:ClearAllPoints()
        editFrame.borderBottom:SetSize(editWidth, thick)
        editFrame.borderBottom:SetPoint("BOTTOMLEFT", editFrame, "BOTTOMLEFT", 0, 0)
        editFrame.borderBottom:SetPoint("BOTTOMRIGHT", editFrame, "BOTTOMRIGHT", 0, 0)

        editFrame.borderLeft:ClearAllPoints()
        editFrame.borderLeft:SetSize(thick, editHeight)
        editFrame.borderLeft:SetPoint("TOPLEFT", editFrame, "TOPLEFT", 0, 0)
        editFrame.borderLeft:SetPoint("BOTTOMLEFT", editFrame, "BOTTOMLEFT", 0, 0)

        editFrame.borderRight:ClearAllPoints()
        editFrame.borderRight:SetSize(thick, editHeight)
        editFrame.borderRight:SetPoint("TOPRIGHT", editFrame, "TOPRIGHT", 0, 0)
        editFrame.borderRight:SetPoint("BOTTOMRIGHT", editFrame, "BOTTOMRIGHT", 0, 0)
    end

    editFrame:Show()
end

-----------------------------------------------------------------------
-- Container sizing: keep partyFrame shrink-wrapped to visible buttons
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- Frame creation
-----------------------------------------------------------------------

local function CreatePartyContainer()
    if partyFrame then return partyFrame end

    partyFrame = CreateFrame("Frame", "SquizzFramesPartyFrame", UIParent, "BackdropTemplate")
    -- Restore saved position or fall back to center of screen.
    -- We always anchor CENTER→CENTER like Danders: the container's center
    -- stays locked to the saved offset regardless of how many buttons are
    -- visible. This prevents any shifting when members join/leave.
    local prof = GetProfile()
    -- Mode-aware from the very first frame -- handles the real case of
    -- /reload happening while already in a raid, not just solo/party login.
    local db = GetActiveLayout(prof)
    -- Migrate old anchorPosition (point/relativePoint/x/y) to anchorX/anchorY.
    -- The old format used TOP/TOP anchors; convert to CENTER/CENTER offsets.
    -- Just nuke the old position and let the safety net reset to defaults.
    -- The user can re-drag to their preferred position.
    if db and not db.anchorX and db.anchorPosition then
        db.anchorPosition = nil
    end
    local anchorX = db and db.anchorX or 0
    local anchorY = db and db.anchorY or -200
    local scale = (prof and prof.appearance and prof.appearance.general and prof.appearance.general.scale) or 1.0
    -- Set the container's scale to match the UI scale setting (like Danders'
    -- frameScale). The drag system divides offsets by this same value, so
    -- save/load stay consistent.
    partyFrame:SetScale(scale)
    -- Strata history (2026-07-30/31, superseded 2026-08-01 -- see below):
    -- originally bumped to "HIGH" to beat nameplates (MEDIUM by default, same
    -- as this container) -- that worked reliably, but also covered Blizzard's
    -- own MEDIUM-strata full-screen panels (Character, Talents, Spellbook,
    -- etc), which then needed a whole separate fade-on-panel-open mechanism
    -- (ApplyBlizzardPanelVisibility/panelVisibilityTicker further down) to
    -- paper over. A high FRAME LEVEL at plain MEDIUM strata was also tried,
    -- and confirmed NOT to reliably beat nameplates (they self-raise via
    -- "toplevel"/"useParentLevel" on every interaction -- see the full
    -- writeup in memory: nameplate-strata-fix-revised-to-framelevel.md).
    --
    -- 2026-08-01: TESTING a full revert to plain "MEDIUM" (the engine
    -- default -- this call is only here for explicitness/searchability, not
    -- because MEDIUM needs to be asserted). Both DandersFrames and
    -- EllesmereUIRaidFrames were checked directly (their actual installed
    -- source, not assumption) and NEITHER attempts to beat nameplates at
    -- all -- their unit frame containers/headers/buttons never call
    -- SetFrameStrata anywhere, everything just sits at MEDIUM, and any
    -- internal layering they need (e.g. Danders' movers) is done via a HIGH
    -- frame LEVEL at the SAME strata as the frames it sits above, not a
    -- different strata tier. This branch mirrors that: party frames no
    -- longer try to out-strata nameplates or Blizzard's panels, and
    -- ApplyBlizzardPanelVisibility's ticker/hooks are left installed but the
    -- fade they'd apply is now a no-op in practice (nothing to counteract at
    -- MEDIUM). If nameplates are confirmed (via user in-game testing) to
    -- cover the frames again at this position, revert this single line back
    -- to "HIGH" and re-enable the fade's practical purpose -- nothing else
    -- needs to change, the whole mechanism is still intact.
    partyFrame:SetFrameStrata("MEDIUM")
    local initialPoint = GetAnchorPoint(db)
    partyFrame:SetPoint(initialPoint, UIParent, initialPoint, anchorX / scale, anchorY / scale)
    -- Size the container to the button footprint immediately so there's no
    -- frame where it's 0×0 (which lets the secure header expand it wider than
    -- the buttons, leaving an empty draggable strip to the right). Uses layout
    -- defaults; SizeContainerToButtons refines this once the header exists.
    -- Just a rough placeholder either way (single strip of 5, or one 5-member
    -- subgroup for raid) -- SizeContainerToButtons recomputes the real shape
    -- moments later once the header/roster actually exist.
    do
        local layout = db or {}
        local spacing = layout.spacingY or 0
        local bW = layout.width or 100
        local bH = layout.height or 40
        local orientation = layout.orientation or "vertical"
        if orientation == "horizontal" then
            partyFrame:SetSize(5 * bW + 4 * spacing + 6, bH + 6)
        else
            partyFrame:SetSize(bW + 6, 5 * bH + 4 * spacing + 6)
        end
    end
    -- The container itself is NOT directly draggable. Secure unit buttons
    -- (children of the secure header) swallow mouse-up events, which would
    -- prevent a container-level drag handler from ever seeing the release.
    -- Instead we use a dedicated non-secure MOVER FRAME on top, following the
    -- DandersFrames pattern: the mover handles drag via standard OnDragStart/
    -- OnDragStop, and repositions the container underneath it.
    partyFrame:EnableMouse(false)

    local mover = CreateFrame("Frame", "SquizzFramesPartyMover", partyFrame)
    mover:SetAllPoints(partyFrame)
    mover:SetFrameStrata(partyFrame:GetFrameStrata())
    mover:SetFrameLevel(partyFrame:GetFrameLevel() + 10)
    mover:EnableMouse(true)
    mover:SetMovable(true)
    mover:RegisterForDrag("LeftButton")
    mover:Hide()  -- only shown in edit mode
    partyFrame.mover = mover

    -- Shared drag state (upvalues readable by both scripts)
    local dragOffsetX, dragOffsetY = 0, 0

    mover:SetScript("OnDragStart", function(self)
        -- Moving the container is PROTECTED in combat: it parents the secure
        -- header, so the ClearAllPoints/SetPoint in the OnUpdate below throws
        -- ADDON_ACTION_BLOCKED. The blame in that error lands on whichever
        -- addon's taint happens to be on the execution path (a live report
        -- named ElvUI_Libraries), which makes it look like someone else's
        -- bug -- it isn't, it's this call site.
        --
        -- ApplyContainerAnchor carries the same guard for its own eight
        -- callers (2026-08-16); the drag handler was the one remaining path
        -- that reached ClearAllPoints raw, because it bypasses that function
        -- entirely and pokes the container directly for smoothness.
        if InCombatLockdown() then
            SquizzFrames:Print("Frames can't be moved during combat.")
            return
        end
        -- Compute the offset between the cursor and the container's center
        -- so the frame doesn't jump to the cursor on drag start.
        -- Read the active layout dynamically (don't reuse the upvalue `db`
        -- from CreatePartyContainer — it can go stale after a profile reset,
        -- and must reflect whichever mode -- party/raid -- is active NOW).
        local p = GetProfile()
        local layoutDb = GetActiveLayout(p)
        local pScale = UIParent:GetEffectiveScale()
        local startCursorX, startCursorY = GetCursorPosition()
        startCursorX = startCursorX / pScale
        startCursorY = startCursorY / pScale
        -- Measure against the layout's configured anchor point rather than a
        -- hardcoded screen centre. Start and end both use the SAME point, so
        -- this stays a pure substitution -- no container geometry is read,
        -- which is why this drag math was never affected by the
        -- coordinate-space scaling bug that hit the preview.
        local anchorPoint = GetAnchorPoint(layoutDb)
        local originX, originY = ScreenAnchorCoords(anchorPoint)
        -- The container's anchor point in UIParent coords (from saved position)
        local frameCX = originX + (layoutDb and layoutDb.anchorX or 0)
        local frameCY = originY + (layoutDb and layoutDb.anchorY or 0)
        local cursorOffX = frameCX - startCursorX
        local cursorOffY = frameCY - startCursorY
        -- Seed the shared offset with the current saved position
        dragOffsetX = layoutDb and layoutDb.anchorX or 0
        dragOffsetY = layoutDb and layoutDb.anchorY or 0

        self:SetScript("OnUpdate", function()
            -- Combat can start mid-drag. Stop repositioning (protected --
            -- see the OnDragStart guard) but leave the handler installed so
            -- the drag picks itself back up when the fight ends. The offsets
            -- are deliberately left alone too, so OnDragStop persists where
            -- the frame actually IS rather than where the cursor wandered.
            if InCombatLockdown() then return end
            local cx, cy = GetCursorPosition()
            local ps = UIParent:GetEffectiveScale()
            cx = cx / ps
            cy = cy / ps
            -- New offset from the anchor point (pixels). Re-read each tick so
            -- a resolution/UI-scale change mid-drag can't desync it.
            local ox, oy = ScreenAnchorCoords(anchorPoint)
            dragOffsetX = (cx + cursorOffX) - ox
            dragOffsetY = (cy + cursorOffY) - oy
            -- Apply to container, compensating for container scale
            local frameScale = partyFrame:GetScale() or 1
            partyFrame:ClearAllPoints()
            partyFrame:SetPoint(anchorPoint, UIParent, anchorPoint,
                dragOffsetX / frameScale, dragOffsetY / frameScale)
        end)
    end)

    mover:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        -- Persist the final offset (raw pixels from screen center).
        -- Read the active layout dynamically (don't reuse the upvalue `db`
        -- from CreatePartyContainer — it can go stale after a profile reset,
        -- and must reflect whichever mode -- party/raid -- is active NOW).
        local p = GetProfile()
        local layoutDb = GetActiveLayout(p)
        if layoutDb then
            layoutDb.anchorX = dragOffsetX
            layoutDb.anchorY = dragOffsetY
        end
        -- Re-assert the saved position cleanly, through the single apply path
        -- so the anchor point, scale compensation and default fallbacks can't
        -- drift from what ApplyLayout would have produced.
        ApplyContainerAnchor(p, layoutDb)
    end)

    -- Edit mode border: visual-only overlay that wraps the visible buttons.
    -- Uses four colored edge textures for a reliable visible border.
    -- Does NOT intercept mouse clicks — the actual draggable area is the
    -- entire party container.
    local editFrame = CreateFrame("Frame", nil, partyFrame)
    editFrame:SetFrameStrata("DIALOG")
    editFrame:SetFrameLevel(100)
    editFrame:Hide()
    partyFrame.editFrame = editFrame

    -- Create four border edge textures (top, bottom, left, right)
    local function MakeBorder(parent, thickness)
        local tex = parent:CreateTexture(nil, "BACKGROUND")
        tex:SetColorTexture(0.33, 0.77, 0.99, 0.0)  -- invisible by default
        tex:SetHeight(thickness)
        tex:SetWidth(thickness)
        return tex
    end
    editFrame.borderTop = MakeBorder(editFrame, 2)
    editFrame.borderBottom = MakeBorder(editFrame, 2)
    editFrame.borderLeft = MakeBorder(editFrame, 2)
    editFrame.borderRight = MakeBorder(editFrame, 2)

    -- Edit mode label (sits above the button area)
    editFrame.editLabel = editFrame:CreateFontString(nil, "OVERLAY")
    editFrame.editLabel:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    editFrame.editLabel:SetPoint("BOTTOM", editFrame, "TOP", 0, 2)
    editFrame.editLabel:SetTextColor(0.33, 0.77, 0.99, 0.0)
    editFrame.editLabel:SetText("Edit Mode — drag to move")

    -- Party/Raid switch, so the layout being edited can be pointed at the
    -- mode you're NOT currently in (see PartyFrames:SetEditLayoutOverride).
    -- Parented to editFrame so it shows/hides with edit mode automatically.
    -- Sits below the frames rather than above, where the edit label already
    -- is, and outside the container so it never overlaps a unit button.
    local toggle = CreateFrame("Frame", nil, editFrame)
    toggle:SetSize(120, 20)
    toggle:SetPoint("TOP", editFrame, "BOTTOM", 0, -4)
    editFrame.modeToggle = toggle

    local function MakeModeButton(key, label, point, relPoint, xOff)
        local b = CreateFrame("Button", nil, toggle)
        b:SetSize(58, 20)
        b:SetPoint(point, toggle, relPoint, xOff, 0)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints(b)
        b.text = b:CreateFontString(nil, "OVERLAY")
        b.text:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        b.text:SetPoint("CENTER", b, "CENTER", 0, 0)
        b.text:SetText(label)
        b.layoutKey = key
        b:SetScript("OnClick", function()
            PartyFrames:SetEditLayoutOverride(key)
        end)
        return b
    end
    toggle.partyButton = MakeModeButton("main", L["Party"] or "Party", "LEFT", "LEFT", 0)
    toggle.raidButton  = MakeModeButton("raid", L["Raid"] or "Raid", "RIGHT", "RIGHT", 0)

    -- Always show the container so self is visible even solo
    partyFrame:Show()

    return partyFrame
end

local function CreateHeader()
    if header then return header end

    local container = CreatePartyContainer()
    header = CreateFrame("Frame", "SquizzFramesPartyHeader", container, "SecureGroupHeaderTemplate")

    -- Anchor the header inside the container at the container's OWN anchor
    -- point (CENTER by default, so this is the historical CENTER→CENTER for
    -- every unmodified profile). Matching the points means the header sits on
    -- the part of the container that is pinned to the screen, so the
    -- container shrink-wrapping around the visible buttons can never drag the
    -- frames with it -- see ReanchorHeaderForCenterGrowth for the full
    -- writeup. ApplyLayout re-asserts this on every layout pass.
    local initialHeaderPoint = GetAnchorPoint(GetActiveLayout())
    header:SetPoint(initialHeaderPoint, container, initialHeaderPoint, 0, 0)
    -- Strata isn't inherited from parent in WoW -- must match the container's
    -- explicitly (see CreatePartyContainer's comment on the nameplate-strata
    -- fix history).
    header:SetFrameStrata(container:GetFrameStrata())

    -- Configure header attributes (secure, only outside combat)
    -- Use xOffset/yOffset (not spacingX/spacingY) per SecureGroupHeaderTemplate.
    header:SetAttribute("template", "SquizzFramesUnitButtonTemplate")
    header:SetAttribute("point", "TOP")
    header:SetAttribute("xOffset", 0)
    header:SetAttribute("yOffset", -2)  -- negative = stack downward
    header:SetAttribute("showPlayer", true)
    header:SetAttribute("showParty", true)
    header:SetAttribute("showRaid", true)
    header:SetAttribute("showSolo", true)
    -- Force-create up to 40 button frames NOW (out of combat), regardless of
    -- current group size, so raid buttons already exist the first time the
    -- player is ever in a raid instead of allocating on demand. Same
    -- always-allocate-max philosophy already used for party's 5 -- children
    -- for units that don't exist just stay hidden via RegisterUnitWatch.
    -- Frame creation is capped by maxColumns*unitsPerColumn, not just
    -- startingIndex, so both must be raised together for this one-time pass.
    --
    -- Single column (unitsPerColumn=40) rather than 8x5: an 8-column
    -- configureChildren pass with no "columnAnchorPoint"/"columnSpacing"
    -- attributes set threw a live error ("SecureGroupHeaders.lua:79: attempt
    -- to index local 'point' (a nil value)") on every login/reload -- the
    -- multi-column path apparently needs those, which this one-time
    -- force-create pass never set (ApplyLayout sets them moments later, but
    -- only after this Show() already ran). 1x40 reaches the same total
    -- capacity (maxColumns*unitsPerColumn = 40) through the single-column
    -- path instead, which only ever needed "point".
    header:SetAttribute("maxColumns", 1)
    header:SetAttribute("unitsPerColumn", 40)
    header:SetAttribute("startingIndex", -39) -- Force-create 40 frames ahead of time

    -- Force the header to create its children NOW (out of combat).
    -- header:Show() triggers configureChildren, which allocates the buttons.
    header:Show()
    header:SetAttribute("startingIndex", 1) -- Reset after children are created
    -- Reset to party's default shape; ApplyLayout (run moments later) sets
    -- the real mode-correct attributes for whichever group type is active.
    header:SetAttribute("maxColumns", 1)

    -- No state-visibility driver: let the header manage per-child visibility
    -- via RegisterUnitWatch (built into SecureUnitButtonTemplate). Each
    -- button auto-hides when its unit doesn't exist. The header itself stays
    -- shown; only the relevant children (player when solo, +party in group)
    -- will be visible.

    return header
end

-- One secure header per raid subgroup -- see the groupHeaders comment at the
-- top of this file for why raid can't be a single header.
--
-- Created up front (out of combat, at the same time as the party header) and
-- left inert until ApplyLayout puts them into raid mode: header creation and
-- every attribute below are protected, so none of this can be done on demand
-- when a raid actually forms.
local function CreateRaidGroupHeaders()
    if groupHeaders[1] then return groupHeaders end
    if InCombatLockdown() then return groupHeaders end

    local container = CreatePartyContainer()
    local anchorPoint = GetAnchorPoint(GetActiveLayout())

    for i = 1, RAID_GROUP_COUNT do
        local h = CreateFrame("Frame", "SquizzFramesRaidGroupHeader" .. i, container,
            "SecureGroupHeaderTemplate")
        h:SetPoint(anchorPoint, container, anchorPoint, 0, 0)
        -- Strata isn't inherited from the parent in WoW (see
        -- CreatePartyContainer's nameplate-strata history).
        h:SetFrameStrata(container:GetFrameStrata())

        h:SetAttribute("template", "SquizzFramesUnitButtonTemplate")
        -- The whole point: restrict this header to ONE subgroup, so that
        -- groupBy="ASSIGNEDROLE" (set later by ApplyRoleSortAttributes) sorts
        -- within the group instead of across the raid.
        h:SetAttribute("groupFilter", tostring(i))
        h:SetAttribute("point", "TOP")
        h:SetAttribute("xOffset", 0)
        h:SetAttribute("yOffset", -2)
        h:SetAttribute("showPlayer", true)
        h:SetAttribute("showParty", false)
        h:SetAttribute("showSolo", false)
        h:SetAttribute("showRaid", true)
        h:SetAttribute("maxColumns", 1)
        h:SetAttribute("unitsPerColumn", 5)

        -- Force-create all five children now, the same way CreateHeader does
        -- for its 40: a negative startingIndex makes configureChildren's
        -- numDisplayed come out at unitsPerColumn even with an empty roster,
        -- so the buttons exist before the first raid instead of being
        -- allocated mid-fight (which is impossible -- CreateFrame on a secure
        -- template is protected).
        h:SetAttribute("startingIndex", -4)
        h:Show()
        h:SetAttribute("startingIndex", 1)
        -- Inert until raid mode. showRaid stays true so that the header is
        -- ready to populate the instant ApplyLayout shows it; being hidden is
        -- what keeps it from drawing (and from running configureChildren) in
        -- party/solo.
        h:Hide()

        groupHeaders[i] = h
    end

    return groupHeaders
end

-----------------------------------------------------------------------
-- Button wiring
-----------------------------------------------------------------------

-- overrideW/overrideH (optional): use these instead of GetActiveLayout()'s
-- width/height. GetActiveLayout() always follows the player's REAL current
-- group state (IsInRaid()) -- fine for real header buttons, but the layout
-- preview intentionally shows whichever tab is being EDITED, which is very
-- often different from the real state (e.g. previewing Raid while actually
-- solo). Without the override, this unconditionally clobbered every preview
-- button's size with the WRONG (real-state) width/height right after
-- LayoutPreviewButtons had already set the correct one -- confirmed bug:
-- preview rows came out sized like the real party layout regardless of
-- which tab/size was actually being previewed.
local function resolveChildren(button, overrideW, overrideH, overridePowerH)
    -- Our XML template uses parentKey, which populates button.healthBar etc.
    -- directly on the parent frame at XML load time. The _G name lookup is a
    -- fallback for FontStrings in <Layers> which aren't returned by GetChildren().
    local n = button:GetName()
    if not n then return end
    button.healthBar      = button.healthBar      or _G[n .. "HealthBar"]
    button.powerBar       = button.powerBar       or _G[n .. "PowerBar"]
    button.nameText       = button.nameText       or _G[n .. "Name"]
    button.statusText     = button.statusText     or _G[n .. "Status"]
    button.healthText     = button.healthText     or _G[n .. "HealthText"]
    button.roleIcon       = button.roleIcon       or _G[n .. "RoleIcon"]
    button.raidIcon       = button.raidIcon       or _G[n .. "RaidIcon"]
    button.healthBackdrop = button.healthBackdrop or _G[n .. "HealthBackdrop"]

    -- StatusBars are child frames (not in Layers), so they need their width
    -- set explicitly — XML <Anchors> only sets position, not size.
    local bw, bh, powerH = overrideW, overrideH, overridePowerH
    if not bw or not bh or not powerH then
        local profile = GetProfile()
        local activeLayout = GetActiveLayout(profile)
        bw = bw or (activeLayout and activeLayout.width) or 100
        bh = bh or (activeLayout and activeLayout.height) or 40
        -- Mode-appropriate fallback, matching Layout_Defaults (party 4,
        -- raid 3) and the options panel's own GetPowerHeight default.
        powerH = powerH or (activeLayout and activeLayout.powerHeight)
            or (IsInRaid() and 3 or 4)
    end
    if button.healthBar then
        button.healthBar:SetWidth(bw)
    end
    if button.powerBar then
        button.powerBar:SetWidth(bw)
        -- Power Bar Height was a dead setting until now (bug fix 2026-08-08,
        -- user report: "adjusting the power bar height does nothing on both
        -- the live and all preview screens"). The options panel wrote
        -- layout.powerHeight and fired LayoutChanged correctly, but NOTHING
        -- in the live path ever read it -- the bar just kept the hardcoded
        -- <Size y="5"/> from UnitButton.xml forever. Only the preview mock
        -- buttons (which build their own power bar in Lua) honoured it, so
        -- the setting appeared to work there and nowhere else.
        button.powerBar:SetHeight(powerH)
    end

    -- Enforce the configured button size. The secure header's configureChildren
    -- step resets children to the template's hardcoded <Size x="100" y="40"/>,
    -- so we must re-apply our size AFTER the header finishes configuring.
    -- resolveChildren runs from WireUpButton, which is called after the header
    -- has configured its children — making this the reliable place to size.
    button:SetSize(bw, bh)
end

local function WireUpButton(button, unit)
    if not button then return end
    unitButtons[unit] = button
    button.unit = unit
    resolveChildren(button)
    -- Bars are now Texture objects in <Layer level="BACKGROUND">, so they
    -- naturally render behind all text/artwork/overlay layers. No frame level
    -- adjustment needed (Textures don't support SetFrameLevel anyway).

    -- Register for clicks so click-casting attributes (type1/type2/...) can
    -- fire. SecureUnitButtonTemplate provides default left-click=target and
    -- right-click=menu; our click-casting bindings override those per-button
    -- by setting the specific typeN attributes.
    button:RegisterForClicks("AnyUp")

    -- Drag-to-move: when in edit mode, dragging a button moves the container.
    -- Uses the same manual OnKeyDown/OnMouseUp approach as the container so
    -- the drag always resolves (secure buttons swallow OnDragStop).
    -- Drag-to-move: when in edit mode, left-drag on a button starts the
    -- container's drag. We hook OnMouseDown (secure buttons have this) and
    -- delegate to the container's OnMouseDown handler.
    button:HookScript("OnMouseDown", function(_, btn)
        if btn == "LeftButton" and SquizzFrames.editMode and partyFrame then
            local onMouseDown = partyFrame:GetScript("OnMouseDown")
            if onMouseDown then onMouseDown(partyFrame, "LeftButton") end
        end
    end)
end

local wireUpRetryFrame
-- Bounded retry counter for the "secure header hasn't reconfigured yet"
-- case inside WireUpAllButtons -- see its comment.
local wireUpStaleRetries = 0
-- Bounded attempt counter for the "header assigned no units at all"
-- recovery in WireUpAllButtons -- see its comment.
local headerReconfigureAttempts = 0
local function WireUpAllButtons()
    -- Combat guard (2026-08-07): resolveChildren (via WireUpButton below)
    -- calls button:SetSize() and button:RegisterForClicks() on secure header
    -- children -- both protected in combat. Every caller used to check
    -- InCombatLockdown() only at SCHEDULE time and then fire a
    -- C_Timer.After(0.2/0.5/1.0/2.0, ...), so combat starting inside that
    -- window reproduced the exact ADDON_ACTION_BLOCKED bug already fixed
    -- once in ApplyLayout. Guarding here directly protects every caller,
    -- same reasoning/pattern as ApplyLayout's own guard above.
    if InCombatLockdown() then
        if not wireUpRetryFrame then
            wireUpRetryFrame = CreateFrame("Frame")
            wireUpRetryFrame:SetScript("OnEvent", function(self)
                self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                WireUpAllButtons()
            end)
        end
        wireUpRetryFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end

    -- The secure header creates children. Iterate with ipairs(header).
    -- The header sets the "unit" attribute on each child via secure code.
    -- We wire ALL buttons (including non-existent units) so that if a unit
    -- joins later, the button is ready. RegisterUnitWatch hides/shows buttons
    -- automatically based on unit existence.
    local inRaid = IsInRaid()

    -- If ANY child still carries the other mode's unit token, the secure
    -- header hasn't finished reconfiguring yet -- retry shortly instead of
    -- wiring against a half-updated set (bug fix 2026-08-07, intermittent
    -- "raid -> party clears the party frames").
    --
    -- SecureGroupHeaderTemplate reconfigures children ASYNCHRONOUSLY after
    -- ApplyLayout writes its attributes, so right after a transition the
    -- buttons still say raid1..raid40 while we're already in a party. Wiring
    -- then keys unitButtons by units that no longer exist: UpdateAllButtons
    -- skips them (it gates on UnitExists) and RegisterUnitWatch hides the
    -- buttons -- blank frames. Hitting that window is timing-dependent,
    -- hence "intermittent".
    --
    -- Deliberately does NOT substitute fallbackUnits[i] for a stale token:
    -- the fallback is index-based, but with role/group sorting a button's
    -- index does NOT correspond to roster order, so guessing installs a
    -- WRONG unit rather than merely a stale one. Waiting for the header's
    -- own (authoritative) assignment is the only correct source. The
    -- fallback still covers a genuinely nil attribute, which is the
    -- pre-assignment state it was written for.
    local retries = wireUpStaleRetries or 0
    local sawStaleToken = false
    ForEachHeaderButton(function(button)
        if sawStaleToken then return end
        local unit = button:GetAttribute("unit")
        if unit then
            local isRaidToken = unit:match("^raid%d+$") ~= nil
            local isPartyToken = (unit == "player") or (unit:match("^party%d+$") ~= nil)
            if (inRaid and isPartyToken) or (not inRaid and isRaidToken) then
                sawStaleToken = true
            end
        end
    end)
    if sawStaleToken then
        -- Bounded, so a genuinely unexpected token can never wedge wiring
        -- permanently -- after the cap we wire with what we have rather than
        -- never wiring at all.
        if retries < 10 then
            wireUpStaleRetries = retries + 1
            C_Timer.After(0.1, WireUpAllButtons)
            return
        end
    end
    wireUpStaleRetries = 0

    -- Recovery: grouped, but the header assigned NO unit attributes at all.
    --
    -- SecureGroupHeaderTemplate only runs its configureChildren pass while
    -- the header is actually VISIBLE. If the container was hidden at the
    -- moment ApplyLayout wrote the header's attributes (preview mode, a
    -- deferred/blocked layout, a mid-transition hide), the assignment is
    -- simply skipped -- and because the header itself is never re-Shown
    -- afterwards, nothing ever re-triggers it. The children keep a nil
    -- "unit" attribute, RegisterUnitWatch therefore hides every one of
    -- them, and the frames stay gone until a /reload. Confirmed by a live
    -- diagnostic dump: every button had a nil unit attribute and
    -- IsShown() == false while in a party.
    --
    -- A Hide/Show cycle is the standard way to force the header to
    -- re-evaluate (it's what CreateHeader itself relies on to force the
    -- initial child creation). Out-of-combat only, which is guaranteed
    -- here -- this function returns early under lockdown.
    if IsInGroup() and partyFrame then
        -- 1) Header configured for the WRONG group mode.
        --
        -- Diagnosed from a live dump after "logout -> login -> convert to
        -- party" left the frames blank: IsInRaid() was false, both frames
        -- were visible, but the header still had showRaid=true /
        -- showParty=false. With no raid to enumerate it assigns no units at
        -- all, so RegisterUnitWatch hides every button. ApplyLayout owns
        -- these attributes, so it simply never re-ran for party mode -- and
        -- nothing else ever calls it again, which is why the state stuck
        -- until a /reload (the stuck-flag escape hatch in ApplyLayout can
        -- only help on the NEXT call; it doesn't generate one).
        --
        -- Reconciling against observable state here means any path that
        -- fails to lay out -- error, blocked call, missed event -- is
        -- self-correcting rather than permanently broken.
        --
        -- Reads the headers that SHOULD be live for the current mode, which
        -- since the per-group split (2026-08-20) is no longer a single flag:
        -- in a raid the party header is deliberately showRaid=false and hidden
        -- while the eight group headers carry the raid, so checking the party
        -- header alone would report "wrong mode" on every raid pass and burn
        -- the retry budget re-laying out for nothing.
        local configuredForMode
        if inRaid then
            local g1 = groupHeaders[1]
            configuredForMode = (g1 and g1:IsShown() and g1:GetAttribute("showRaid")) and true or false
        else
            configuredForMode = (header:GetAttribute("showParty") and not header:GetAttribute("showRaid"))
                and true or false
        end
        if not configuredForMode and headerReconfigureAttempts < 3 then
            headerReconfigureAttempts = headerReconfigureAttempts + 1
            ApplyLayout()
            C_Timer.After(0.1, WireUpAllButtons)
            return
        end

        -- 2) Correct mode, but still no unit assigned to anything.
        -- SecureGroupHeaderTemplate only runs configureChildren while
        -- visible, so an attribute write that landed while hidden is simply
        -- skipped and never retried. A Hide/Show cycle forces it -- the same
        -- mechanism CreateHeader relies on for initial child creation.
        local anyUnitAssigned = false
        ForEachHeaderButton(function(button)
            if button:GetAttribute("unit") then anyUnitAssigned = true end
        end)
        if anyUnitAssigned then
            -- Healthy: re-arm so a future break can recover too.
            headerReconfigureAttempts = 0
        elseif headerReconfigureAttempts < 3 then
            headerReconfigureAttempts = headerReconfigureAttempts + 1
            partyFrame:Show()
            -- Cycle whichever headers are meant to be live -- in a raid the
            -- party header is legitimately hidden, so cycling it would prove
            -- nothing and re-showing it would put party buttons on screen
            -- mid-raid.
            for _, h in ipairs({unpack(ActiveHeaders())}) do
                h:Hide()
                h:Show()
            end
            C_Timer.After(0.1, WireUpAllButtons)
            return
        end
    else
        headerReconfigureAttempts = 0
    end

    wipe(unitButtons)

    -- The index-based fallback only exists for the party header, where child N
    -- reliably maps to the Nth party slot. It is deliberately NOT extended to
    -- the raid group headers: child 2 of the group-3 header is not "raid2", so
    -- a guess there installs a WRONG unit rather than a merely stale one. A
    -- group-header child with no unit attribute is simply skipped and picked
    -- up by the next pass, when the header has assigned one.
    local fallbackUnits = { "player", "party1", "party2", "party3", "party4" }

    local headers = {unpack(ActiveHeaders())}
    for _, h in ipairs(headers) do
        local isPartyHeader = (h == header)
        for i, button in ipairs(h) do
            if button then
                local unit = button:GetAttribute("unit")
                if not unit and isPartyHeader and not inRaid then
                    unit = fallbackUnits[i]
                end
                if unit then WireUpButton(button, unit) end
            end
        end
    end

    -- Notify other modules (e.g. ClickCasting) that buttons are wired and
    -- ready to receive attributes.
    --
    -- Fired once PER HEADER rather than once overall: every listener treats the
    -- payload as "a header, walk its children" (Indicators' OnPartyButtonsWired,
    -- ClickCasting's CollectButtons), so eight fires in a raid keeps them all
    -- working unchanged -- whereas one fire carrying a list would have to be
    -- understood by each of them.
    for _, h in ipairs(headers) do
        SquizzFrames:Fire("PartyButtonsWired", h)
    end
end

-----------------------------------------------------------------------
-- Button update functions
-----------------------------------------------------------------------

local function UpdateHealth(button)
    if not button or not button.unit then return end
    local unit = button.unit

    -- Layout preview: fake a full, class-colored bar for slots with no real
    -- unit (see PartyFrames:SetPreviewMode) -- skips the UnitExists gate
    -- entirely since there's no real unit to check.
    if button._sfFakeName then
        button.nameText:SetAlpha(1)
        if button.healthBar then
            local maxHP = button._sfFakeHealthMax or 100
            button.healthBar:SetMinMaxValues(0, maxHP)
            button.healthBar:SetValue(button._sfFakeHealth or maxHP)
            button.healthBar:SetStatusBarTexture(GetBarTexture())
            local prof = GetProfile()
            local useClass = prof and prof.appearance and prof.appearance.healthBar
                and prof.appearance.healthBar.fullColor
                and prof.appearance.healthBar.fullColor[1] == "class_color"
            local col = prof and prof.appearance and prof.appearance.healthBar
                and prof.appearance.healthBar.fullColor
            if useClass and button._sfFakeClass then
                local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[button._sfFakeClass]
                if cc then button.healthBar:SetStatusBarColor(cc.r, cc.g, cc.b, 1) end
            else
                local r = col and col[2] or 0.2
                local g = col and col[3] or 0.8
                local b = col and col[4] or 0.2
                button.healthBar:SetStatusBarColor(r, g, b, 1)
            end
        end
        return
    end

    if not UnitExists(unit) then return end

    -- Check offline/dead/ghost states
    local isDead = UnitIsDead(unit)
    local isGhost = UnitIsGhost(unit)
    local isConnected = UnitIsConnected(unit)

    if not isConnected or isDead or isGhost then
        -- statusText itself (text + background sync) is UpdateStatus' job --
        -- UpdateButtonAll always calls UpdateHealth immediately before
        -- UpdateStatus, so setting it here was always overwritten a moment
        -- later. Duplicating it left the background texture unsynced on this
        -- path and was the same "two functions writing the same widget"
        -- footgun already fixed once this session for nameText.
        if button.healthBar then
            button.healthBar:SetMinMaxValues(0, 1)
            button.healthBar:SetValue(0)
        end
        if button.powerBar then
            button.powerBar:SetMinMaxValues(0, 1)
            button.powerBar:SetValue(0)
        end
        button.nameText:SetAlpha(0.5)
        return
    end

    -- Normal state
    button.nameText:SetAlpha(1)

    -- Health bar: StatusBar handles secret values at C level.
    -- Pass raw UnitHealth/UnitHealthMax to SetMinMaxValues/SetValue.
    if button.healthBar then
        button.healthBar:SetMinMaxValues(0, UnitHealthMax(unit) or 1)
        button.healthBar:SetValue(UnitHealth(unit) or 0)
        button.healthBar:SetStatusBarTexture(GetBarTexture())

        local prof = GetProfile()
        local useClass = prof and prof.appearance and prof.appearance.healthBar
            and prof.appearance.healthBar.fullColor
            and prof.appearance.healthBar.fullColor[1] == "class_color"
        if useClass then
            local cc = F.GetClassColor(unit)
            button.healthBar:SetStatusBarColor(cc.r, cc.g, cc.b, 1)
        else
            local col = prof and prof.appearance and prof.appearance.healthBar
                and prof.appearance.healthBar.fullColor
            local r = col and col[2] or 0.2
            local g = col and col[3] or 0.8
            local b = col and col[4] or 0.2
            button.healthBar:SetStatusBarColor(r, g, b, 1)
        end
    end

    -- Health text is NOT touched here -- it's a fully Indicators-owned
    -- built-in (CheckHealthText in BuiltIn_Update.lua, with its own color/
    -- current/max/percentage/textWidth settings), which also listens to
    -- UNIT_HEALTH. This function used to unconditionally overwrite
    -- button.healthText with a hardcoded "current / max" format on every
    -- single health tick, stomping whatever CheckHealthText had just
    -- rendered a moment earlier -- every Health Text setting looked like it
    -- did nothing because this reasserted the hardcoded format right after.
end

local function UpdatePower(button)
    if not button or not button.unit then return end
    local unit = button.unit

    -- Layout preview: fake a full power bar for slots with no real unit.
    if button._sfFakeName then
        if button.powerBar then
            button.powerBar:SetMinMaxValues(0, 100)
            button.powerBar:SetValue(100)
            button.powerBar:SetStatusBarTexture(GetBarTexture())
            button.powerBar:Show()
            local prof = GetProfile()
            local col = prof and prof.appearance and prof.appearance.powerBar and prof.appearance.powerBar.powerColor
            if col and col[1] == "class_color" and button._sfFakeClass then
                local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[button._sfFakeClass]
                if cc then button.powerBar:SetStatusBarColor(cc.r, cc.g, cc.b, 0.8) end
            elseif col and col[1] == "custom_color" then
                button.powerBar:SetStatusBarColor(col[2] or 1, col[3] or 1, col[4] or 1, 0.8)
            else
                local colors = PowerBarColor["MANA"] or {r = 1, g = 1, b = 1}
                button.powerBar:SetStatusBarColor(colors.r, colors.g, colors.b, 0.8)
            end
        end
        return
    end

    if not UnitExists(unit) then return end
    local isConnected = UnitIsConnected(unit)
    if not isConnected or UnitIsDead(unit) or UnitIsGhost(unit) then
        if button.powerBar then
            button.powerBar:SetMinMaxValues(0, 1)
            button.powerBar:SetValue(0)
            button.powerBar:Hide()
        end
        return
    end

    -- Power bar: StatusBar handles secret values at C level.
    -- Pass raw UnitPowerMax/UnitPower to SetMinMaxValues/SetValue.
    if not button.powerBar then return end

    -- Arena opponents: UnitPowerMax/UnitPower can return secrets.
    -- C-level SetMinMaxValues/SetValue handles them without taint.
    button.powerBar:SetMinMaxValues(0, UnitPowerMax(unit) or 1)
    button.powerBar:SetValue(UnitPower(unit) or 0)
    button.powerBar:SetStatusBarTexture(GetBarTexture())
    button.powerBar:Show()

    -- Power color: class_color > custom_color > Blizzard's stock per-power-
    -- type color (mana=blue/rage=red/etc, PowerBarColor). The options panel
    -- writes powerColor[1] == "blizzard_default" explicitly for the third
    -- mode, but anything that isn't "class_color"/"custom_color" (including
    -- a missing/nil powerColor on a fresh profile) falls through to this
    -- same else branch, so no separate check is needed for it.
    local prof = GetProfile()
    local col = prof and prof.appearance and prof.appearance.powerBar and prof.appearance.powerBar.powerColor
    if col and col[1] == "class_color" then
        local cc = F.GetClassColor(unit)
        button.powerBar:SetStatusBarColor(cc.r, cc.g, cc.b, 0.8)
    elseif col and col[1] == "custom_color" then
        button.powerBar:SetStatusBarColor(col[2] or 1, col[3] or 1, col[4] or 1, 0.8)
    else
        local colors = F.GetPowerColor(unit)
        button.powerBar:SetStatusBarColor(colors.r, colors.g, colors.b, 0.8)
    end
end

-- Name text is fully Indicators-owned (CheckNameText in BuiltIn_Update.lua,
-- with its own color/textWidth/showGroupNumber settings), which also
-- listens to the same roster/name events. There used to be an UpdateName()
-- here that unconditionally did button.nameText:SetText(name) on every
-- UNIT_HEALTH tick (via UpdateButtonAll below) -- same stomping bug as
-- UpdateHealth's old healthText block, just for Name Text instead.

local function UpdateRole(button)
    if not button or not button.unit then return end
    local unit = button.unit
    if not UnitExists(unit) then return end

    -- F.GetRoleKey gates UnitGroupRolesAssigned against a secret return
    -- (12.1), falls back to the player's own SPEC role when no group role is
    -- assigned (solo), and normalizes anything still unknown to DAMAGER.
    local roleKey = F.GetRoleKey(unit)
    button.roleIcon:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES")
    if roleKey == "TANK" then
        button.roleIcon:SetTexCoord(0, 0.296875, 0.328125, 0.625)
    elseif roleKey == "HEALER" then
        button.roleIcon:SetTexCoord(0.3125, 0.609375, 0.015625, 0.3125)
    else
        button.roleIcon:SetTexCoord(0.3125, 0.609375, 0.328125, 0.625)
    end
    button.roleIcon:Show()
end

-- Incoming-summon status text (Pending/Accepted/Declined). Ellesmere consumes
-- C_IncomingSummon.HasIncomingSummon/IncomingSummonStatus with a plain `if`
-- test, no issecretvalue() guard -- unlike UnitIsAFK, this API isn't secret
-- on this client. Enum.SummonStatus falls back to raw 1/2/3 defensively, same
-- as Ellesmere, in case the enum table isn't populated.
local SUMMON_STATUS_PENDING  = Enum.SummonStatus and Enum.SummonStatus.Pending or 1
local SUMMON_STATUS_ACCEPTED = Enum.SummonStatus and Enum.SummonStatus.Accepted or 2
local SUMMON_STATUS_DECLINED = Enum.SummonStatus and Enum.SummonStatus.Declined or 3

local function GetSummonStatusText(unit)
    if not C_IncomingSummon or not C_IncomingSummon.HasIncomingSummon then return nil end
    if not C_IncomingSummon.HasIncomingSummon(unit) then return nil end
    local status = C_IncomingSummon.IncomingSummonStatus(unit)
    if status == SUMMON_STATUS_PENDING then return L["Pending"]
    elseif status == SUMMON_STATUS_ACCEPTED then return L["Accepted"]
    elseif status == SUMMON_STATUS_DECLINED then return L["Declined"]
    end
    return nil
end

-- Drinking/eating detection: SquizzFrames.defaults.drinks is a curated
-- Food & Drink spell-ID list (see Defaults/Indicator_Defaults.lua) that
-- already existed but was never consumed anywhere. C_UnitAuras.GetAuraData
-- BySpellId does not exist on this client (confirmed via debug print --
-- BuiltIn_Update.lua's ScanAurasForCooldownGrid, used by External/Defensive
-- Cooldowns, relies on the same missing API and is silently broken too) --
-- use the by-index scan CheckDebuffs already uses successfully instead.
-- TEMPORARY diagnostic (/sfdrinktest <unit>, default "party1") -- chasing a
-- user report that Drinking status works in town but silently fails inside a
-- Mythic+ dungeon specifically (confirmed correct at the same moment in Cell,
-- so it's not a blanket Blizzard restriction -- something in THIS scan is
-- either not finding the aura at all, or finding it with a secret spellId
-- that F.IsValueNonSecret's guard (added earlier this session for the
-- crash fix) then silently treats as "not a match" rather than "drinking").
-- Remove once the real cause is confirmed.
SLASH_SQUIZZDRINKTEST1 = "/sfdrinktest"
SlashCmdList["SQUIZZDRINKTEST"] = function(msg)
    local unit = (msg and msg ~= "" and msg) or "party1"
    if not UnitExists(unit) then
        print("|cffff0009[SquizzFrames]|r drink test: unit '" .. unit .. "' doesn't exist")
        return
    end
    local drinks = SquizzFrames.defaults and SquizzFrames.defaults.drinks or {}
    local drinkSet = {}
    for _, id in ipairs(drinks) do drinkSet[id] = true end
    local i, scanned, secretCount = 1, 0, 0
    print("|cff33cc99[SquizzFrames]|r drink test: scanning " .. unit .. "...")
    while i <= 40 do
        local ok, info = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
        if not ok then
            secretCount = secretCount + 1
            i = i + 1
        elseif not info then
            break
        else
            scanned = scanned + 1
            local idReadable = F.IsValueNonSecret(info.spellId)
            local nameReadable = F.IsValueNonSecret(info.name)
            local isMatch = idReadable and drinkSet[info.spellId]
            print(string.format("  #%d spellId=%s name=%s match=%s",
                i, idReadable and tostring(info.spellId) or "<secret>",
                nameReadable and tostring(info.name) or "<secret>",
                tostring(isMatch)))
            i = i + 1
        end
    end
    print("|cff33cc99[SquizzFrames]|r drink test: " .. scanned .. " auras readable, "
        .. secretCount .. " slots threw/secret, result=" .. tostring(IsUnitDrinking and IsUnitDrinking(unit)))
end

function IsUnitDrinking(unit)
    local drinks = SquizzFrames.defaults and SquizzFrames.defaults.drinks
    if not drinks or #drinks == 0 then return false end
    if not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then return false end
    local drinkSet = {}
    for _, id in ipairs(drinks) do drinkSet[id] = true end
    local i = 1
    while i <= 40 do
        local ok, info = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
        if not ok then
            -- Same break-vs-continue distinction as Custom_Dispatch.lua's
            -- Scan -- a single secret slot mid-combat isn't "past the last
            -- aura", skip just this index instead of giving up the whole scan.
            i = i + 1
        elseif not info then
            break
        else
            i = i + 1
            -- info.spellId commonly goes secret in combat -- indexing
            -- drinkSet with a secret key hard-errors ("attempted to index a
            -- table that cannot be indexed with secret keys", confirmed via
            -- a live error report) rather than just returning nil, and
            -- nothing here catches it -- must gate with F.IsValueNonSecret
            -- before ever using it as a table key (same fix BuiltIn_Update
            -- .lua's ScanAurasForCooldownGrid/CheckDebuffs needed).
            if F.IsValueNonSecret(info.spellId) and drinkSet[info.spellId] then return true end
        end
    end
    return false
end

local function UpdateStatus(button)
    if not button or not button.unit then return end
    local unit = button.unit

    -- Layout preview: no status text for fake slots (nothing to report).
    if button._sfFakeName then
        button.statusText:Hide()
        return
    end

    if not UnitExists(unit) then return end

    -- UnitIsAFK can return a secret boolean for group units on this client
    -- (UnitIsConnected/UnitIsDead/UnitIsGhost don't -- confirmed against
    -- EllesmereUIRaidFrames, same PTR client) -- issecretvalue() must gate
    -- it before any boolean test, or this throws "attempt to perform
    -- boolean test on a secret boolean value" the moment it's true.
    local isAFK = not issecretvalue(UnitIsAFK(unit)) and UnitIsAFK(unit)

    if isAFK then
        button.statusText:SetText(L["AFK"])
        button.statusText:Show()
    elseif not UnitIsConnected(unit) or UnitIsDead(unit) or UnitIsGhost(unit) then
        local isGhost = UnitIsGhost(unit)
        local isDead = UnitIsDead(unit)
        button.statusText:SetText(isGhost and L["Ghost"] or (isDead and L["Dead"] or L["Offline"]))
        button.statusText:Show()
    else
        local summonText = GetSummonStatusText(unit)
        if summonText then
            button.statusText:SetText(summonText)
            button.statusText:Show()
        elseif IsUnitDrinking(unit) then
            button.statusText:SetText(L["Drinking"])
            button.statusText:Show()
        else
            button.statusText:Hide()
        end
    end

    -- Keep the "Show Background" texture (see BuiltIn_Update.lua's
    -- CreateBuiltInIndicator statusText branch) in sync with the text's own
    -- show/hide -- never show an empty background box when there's no
    -- status to display.
    local bg = button.statusText._sfBG
    if bg then
        local t = button.statusText.configs or button.statusText._sfTable
        bg:SetShown(t and t.showBackground and button.statusText:IsShown())
    end
end

local function UpdateButtonAll(button)
    if not button then return end
    UpdateHealth(button)
    UpdatePower(button)
    UpdateStatus(button)
end

local function UpdateAllButtons()
    -- The secure header manages per-child visibility based on whether each
    -- unit exists (driven by showSolo/showParty/showRaid attributes).
    -- We only need to update the visual content of wired buttons here.
    for unit, button in pairs(unitButtons) do
        if UnitExists(unit) then
            UpdateButtonAll(button)
        end
    end
end

-----------------------------------------------------------------------
-- Layout
-----------------------------------------------------------------------

-- The container is always anchored CENTER→CENTER to UIParent. The saved
-- anchorX/anchorY are offsets from UIParent's center, scaled by UI scale.
-- This single anchor point never changes based on growth direction, which
-- prevents any positional shifting when settings change.
local function GetAnchorForGrowth()
    return "CENTER", "CENTER"
end

-- CENTER_H/CENTER_V growth is implemented as a NATIVE edge-growth direction
-- (point="LEFT"/"TOP" with a positive xOffset/yOffset -- the header's own
-- configureChildren owns EVERY child position, same as regular DOWN/UP/
-- LEFT/RIGHT growth) with the header FRAME's own anchor (never its
-- children's) recentered here whenever the visible count changes. This is
-- what EllesmereUI's own "Center When Solo" does -- move the header, not
-- its children.
--
-- The previous approach manually called button:SetPoint("CENTER", header,
-- ...) on every visible child to fake symmetric growth, which raced
-- against the secure header's own internal configureChildren pass
-- (triggered by roster changes, combat transitions, etc. -- a protected,
-- opaque process we can't hook into or sequence against). Our manual
-- override intermittently lost that race, snapping the whole block back to
-- plain vertical stacking. Since header:SetPoint is a plain frame
-- anchor (not a secure attribute), repositioning the header itself can
-- never race configureChildren at all -- there's nothing left to race.
local function ReanchorHeaderForCenterGrowth(isCenterH, isCenterV, buttonWidth, buttonHeight, spacing)
    if not header or not partyFrame then return end
    -- Mirrors EllesmereUI's own restriction on repositioning the header
    -- frame to out-of-combat only.
    if InCombatLockdown() then return end

    if not isCenterH and not isCenterV then
        header:ClearAllPoints()
        -- Pin the header to the container at the SAME point the container
        -- itself is pinned to the screen, instead of always CENTER.
        --
        -- Why (bug fix 2026-08-08, user report: "joining groups moves the
        -- frames slightly, a loading screen puts them back"): the container
        -- SHRINK-WRAPS to the visible buttons, so its size changes as members
        -- join. A CENTER→CENTER header follows the container's CENTRE -- and
        -- with a non-CENTER anchor point (TOPLEFT, TOP, ...) that centre
        -- MOVES when the container resizes, dragging every button with it.
        -- Matching the points puts the header on the one part of the
        -- container that is pinned and therefore cannot move, so resizing can
        -- never shift the frames.
        --
        -- For the default CENTER anchor this is literally the previous
        -- behaviour, so nothing changes for anyone who hasn't set an anchor
        -- point.
        local point = GetAnchorPoint(GetActiveLayout())
        header:SetPoint(point, partyFrame, point, 0, 0)
        return
    end

    local count = 0
    for _, button in ipairs(header) do
        if button and button:IsShown() and button.unit and UnitExists(button.unit) then
            count = count + 1
        end
    end
    if count == 0 then count = 1 end

    header:ClearAllPoints()
    if isCenterH then
        local totalWidth = count * buttonWidth + (count - 1) * spacing
        header:SetPoint("LEFT", partyFrame, "CENTER", -totalWidth / 2, 0)
    else
        local totalHeight = count * buttonHeight + (count - 1) * spacing
        header:SetPoint("TOP", partyFrame, "CENTER", 0, totalHeight / 2)
    end
end

-- Reposition the container to a layout's saved anchor (party and raid have
-- independent screen positions -- switching modes must move the single
-- shared container, not just resize it). Idempotent: always resolves to the
-- same saved offset, safe to call on every ApplyLayout.
local containerAnchorRetryFrame
local pendingContainerAnchor  -- last requested {prof, layout} while in combat

function ApplyContainerAnchor(prof, layout)
    if not partyFrame then return end

    -- ClearAllPoints/SetPoint on the container are PROTECTED in combat -- it
    -- parents the secure header, so re-anchoring it throws
    -- ADDON_ACTION_BLOCKED.
    --
    -- The 2026-08-03 fix for exactly this crash put its guard in ApplyLayout,
    -- one level too high. That guard's own comment says "guarding here once,
    -- directly, protects every caller" -- but ApplyLayout is only ONE of this
    -- function's EIGHT call sites, and it's this function that touches
    -- ClearAllPoints. The other seven (ReanchorContainer, the drag handler,
    -- the options panel's anchor controls, the mode switch) reach it
    -- unguarded. That's the 2026-08-16 live report: changing an option during
    -- a raid fight, OptionsFrame -> ReanchorContainer -> here -> blocked.
    -- Guarding at the actual choke point instead of one frame up.
    --
    -- LAST request wins rather than queueing every call: this is idempotent
    -- (it just re-resolves the saved anchor), so only the final position
    -- matters, and a fight can generate many of these.
    if InCombatLockdown() then
        pendingContainerAnchor = {prof = prof, layout = layout}
        if not containerAnchorRetryFrame then
            containerAnchorRetryFrame = CreateFrame("Frame")
            containerAnchorRetryFrame:SetScript("OnEvent", function(self)
                self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                local queued = pendingContainerAnchor
                pendingContainerAnchor = nil
                if queued then ApplyContainerAnchor(queued.prof, queued.layout) end
            end)
        end
        containerAnchorRetryFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end

    local scale = (prof and prof.appearance and prof.appearance.general and prof.appearance.general.scale) or 1.0
    -- Fall back to the ACTIVE MODE's own default, not the party one -- a
    -- raid layout missing its anchor used to land on the party's default
    -- position (see GetDefaultAnchorForActiveMode).
    local defX, defY = GetDefaultAnchorForActiveMode()
    local anchorX = (layout and layout.anchorX) or defX
    local anchorY = (layout and layout.anchorY) or defY
    local point = GetAnchorPoint(layout)
    partyFrame:ClearAllPoints()
    partyFrame:SetPoint(point, UIParent, point, anchorX / scale, anchorY / scale)
end

-- Apply role-sort attributes to a secure group header. "sortMethod" only
-- ever accepts "INDEX"/"NAME"/"NAMELIST" -- there is no built-in "role"
-- value, so a previous version of this file silently no-op'd by passing an
-- invalid sortMethod. Confirmed against both Cell (RaidFrames/Groups/
-- PartyFrame.lua + RaidFrame.lua) and EllesmereUIRaidFrames
-- (EllesmereUIRaidFrames.lua's party/raid header appliers), which both
-- achieve a CUSTOM role order the same way: groupBy="ASSIGNEDROLE" splits
-- the roster into role buckets, groupingOrder lists those buckets in the
-- user's chosen priority (plus a trailing "NONE" bucket for anyone with no
-- assigned role, e.g. solo/non-instance groups), and sortMethod="NAME"
-- sorts within each bucket.
-- SetAttribute("groupBy", ...) triggers SecureGroupHeader_Update
-- SYNCHRONOUSLY and that update reads groupingOrder immediately -- setting
-- groupBy first (groupingOrder still nil/stale from before) throws "attempt
-- to index local 'groupingOrder' (a nil value)" inside Blizzard's own
-- SecureGroupHeaders.lua. groupingOrder/sortMethod must land BEFORE
-- groupBy. Matches Cell's exact ordering (RaidFrames/Groups/PartyFrame.lua).
local DEFAULT_ROLE_ORDER = {"TANK", "HEALER", "DAMAGER"}
local function ApplyRoleSortAttributes(header, layout)
    if layout.sortByRole then
        header:SetAttribute("sortMethod", "NAME")
        header:SetAttribute("groupingOrder", table.concat(layout.roleOrder or DEFAULT_ROLE_ORDER, ",") .. ",NONE")
        header:SetAttribute("groupBy", "ASSIGNEDROLE")
    else
        header:SetAttribute("sortMethod", "INDEX")
        header:SetAttribute("groupBy", nil)
    end
end

-- Configure and place the eight raid subgroup headers.
--
-- Everything about a group's INTERNAL layout (which way units stack, spacing,
-- role sorting) is the same set of attributes the party header gets, so the
-- raid tab's orientation/growth controls keep reading exactly as they did.
-- What this function owns that the single header used to do internally is the
-- placement of the group BLOCKS themselves -- the job columnAnchorPoint /
-- columnSpacing / maxColumns did before.
local function LayoutRaidGroupHeaders(layout, spacing, orientation, growthDir, bW, bH, isCenterH, isCenterV)
    if not partyFrame then return end
    CreateRaidGroupHeaders()
    if not groupHeaders[1] then return end

    local groupSpacing = layout.groupSpacing or 6
    CensusRaidGroups()

    -- Unit axis within one subgroup -- same meaning as the party path's "point".
    local point
    if isCenterH then
        point = "LEFT"
    elseif isCenterV then
        point = "TOP"
    elseif orientation == "horizontal" then
        point = (growthDir == "LEFT") and "RIGHT" or "LEFT"
    else
        point = (growthDir == "UP") and "BOTTOM" or "TOP"
    end

    local xOffset, yOffset = 0, 0
    if point == "LEFT" then
        xOffset = spacing
    elseif point == "RIGHT" then
        xOffset = -spacing
    elseif point == "TOP" then
        yOffset = -spacing
    else -- "BOTTOM"
        yOffset = spacing
    end

    -- Group axis: a vertical unit stack puts the groups side by side, a
    -- horizontal unit row stacks them downward. Those are the same two
    -- directions the single header derived from columnAnchorPoint
    -- ("LEFT"/"TOP"), so an existing raid layout looks unchanged apart from
    -- the sorting itself.
    local groupsAlongX = (point == "TOP" or point == "BOTTOM")
    local groupStride = groupsAlongX and (bW + groupSpacing) or (bH + groupSpacing)
    local basePoint = GetAnchorPoint(layout)

    for i = 1, RAID_GROUP_COUNT do
        local h = groupHeaders[i]
        if h then
            h:SetAttribute("point", point)
            h:SetAttribute("xOffset", xOffset)
            h:SetAttribute("yOffset", yOffset)
            h:SetAttribute("maxColumns", 1)
            h:SetAttribute("unitsPerColumn", 5)
            h:SetAttribute("groupFilter", tostring(i))
            h:SetAttribute("showParty", false)
            h:SetAttribute("showSolo", false)
            h:SetAttribute("showPlayer", true)
            h:SetAttribute("showRaid", true)
            -- With groupFilter narrowing this header to one subgroup, the
            -- ASSIGNEDROLE grouping this sets now orders WITHIN the group.
            ApplyRoleSortAttributes(h, layout)

            local along = ((raidGroupSlots[i] or i) - 1) * groupStride
            local count = raidGroupCounts[i] or 1
            if count < 1 then count = 1 end

            h:ClearAllPoints()
            if isCenterH then
                -- Centre each group's own row on the container's centre line.
                -- Better than the single header's old approximation, which had
                -- to assume a full 5-member subgroup because one header anchor
                -- couldn't centre several differently-sized columns at once.
                local w = count * bW + (count - 1) * spacing
                h:SetPoint("LEFT", partyFrame, "CENTER", -w / 2, -along)
            elseif isCenterV then
                local ht = count * bH + (count - 1) * spacing
                h:SetPoint("TOP", partyFrame, "CENTER", along, ht / 2)
            elseif groupsAlongX then
                -- Pinned at the container's OWN anchor point, not its centre --
                -- the container shrink-wraps, and only its anchor point is
                -- guaranteed not to move (2026-08-08 fix, see
                -- ReanchorHeaderForCenterGrowth).
                h:SetPoint(basePoint, partyFrame, basePoint, along, 0)
            else
                h:SetPoint(basePoint, partyFrame, basePoint, 0, -along)
            end

            -- Show LAST. OnShow is wired straight to SecureGroupHeader_Update
            -- (SecureGroupHeaders.xml), and attribute writes made while hidden
            -- are stored but never acted on -- OnAttributeChanged early-returns
            -- unless IsVisible(). Showing first would lay the group out from
            -- the PREVIOUS attribute set and only correct itself on the next
            -- write.
            h:Show()
        end
    end
end

-- Take the raid group headers out of the picture for party/solo. Attributes
-- are cleared as well as hiding, so a header that somehow gets shown again
-- can't populate itself behind our back.
local function HideRaidGroupHeaders()
    for i = 1, RAID_GROUP_COUNT do
        local h = groupHeaders[i]
        if h then
            h:SetAttribute("showRaid", false)
            h:Hide()
        end
    end
end

-- The container's on-screen centre, converted into UIPARENT's coordinate
-- space (2026-08-07).
--
-- partyFrame:GetCenter() reports in the container's OWN scaled space --
-- CreatePartyContainer applies the profile's UI scale via SetScale -- so it
-- must never be compared against, or stored alongside, UIParent-space
-- values without this conversion. Getting that wrong silently corrupts the
-- saved anchor at any scale other than 1.0 (see the callers' comments).

local function ContainerCenterInUIParentSpace()
    if not partyFrame then return nil, nil end
    local cx, cy = partyFrame:GetCenter()
    if not cx or not cy then return nil, nil end
    local fs = partyFrame:GetEffectiveScale() or 1
    local us = UIParent:GetEffectiveScale() or 1
    if us == 0 then return cx, cy end
    local ratio = fs / us
    return cx * ratio, cy * ratio
end

-- Generalisation of the above for an arbitrary anchor point: where the
-- container's `point` currently sits, in UIParent coords. Same scale
-- conversion and same warning -- GetLeft/GetBottom/GetWidth/GetHeight are all
-- in the container's OWN scaled space.
--
-- Needed by ReanchorContainer, which preserves the frames' on-screen position
-- across a growth/orientation change: with a non-CENTER anchor it's that
-- POINT that has to be held still, not the centre.
local function ContainerAnchorInUIParentSpace(point)
    if not partyFrame then return nil, nil end
    local left, bottom = partyFrame:GetLeft(), partyFrame:GetBottom()
    local w, h = partyFrame:GetWidth(), partyFrame:GetHeight()
    if not left or not bottom or not w or not h then return nil, nil end
    local fs = partyFrame:GetEffectiveScale() or 1
    local us = UIParent:GetEffectiveScale() or 1
    local ratio = (us ~= 0) and (fs / us) or 1
    local fx, fy = AnchorPointFactors(point)
    return (left + w * fx) * ratio, (bottom + h * fy) * ratio
end

local applyingLayout = false
-- When applyingLayout was last set, so a flag left stuck by an error can be
-- released rather than wedging layout permanently -- see ApplyLayout.
local applyingLayoutAt = 0
local applyLayoutRetryFrame
-- Coalesces the post-ApplyLayout re-wire (see the end of ApplyLayout).
local relayoutWireQueued = false

-- Bug fix (2026-08-03, live ADDON_ACTION_BLOCKED report): this function
-- (via ApplyContainerAnchor) calls partyFrame:ClearAllPoints()/SetPoint(),
-- both protected once combat starts. Every call site relied on checking
-- InCombatLockdown() at SCHEDULE time (e.g. PLAYER_ENTERING_WORLD's
-- C_Timer.After(0.3/1.0/2.0, ...) retries), but combat can start in the gap
-- between scheduling and the timer actually firing -- a comment near one of
-- those call sites even claimed this function already guarded itself, which
-- it didn't. Guarding here once, directly, protects every caller instead of
-- requiring each one to remember it. Mirrors ReapplyRosterLayout's own
-- PLAYER_REGEN_ENABLED one-shot retry further down this file (added for the
-- identical reason: a fight commonly outlasts every staggered retry, so
-- without a combat-end catch-up the layout could stay stale until a manual
-- /reload -- confirmed via a past user report on that exact code path).
-- Assigns to the forward-declared local at the top of this file (so
-- WireUpAllButtons, defined earlier, can call it) -- NOT a new local.
function ApplyLayout()
    if not header then return end
    -- Re-entrancy guard, with a stuck-flag escape hatch (2026-08-07).
    --
    -- applyingLayout exists to stop SetAttribute's synchronous
    -- SecureGroupHeader_Update from re-entering this function. But the flag
    -- is cleared by a plain assignment at the end -- so if ANY error was
    -- raised in between, it stayed true FOREVER and every subsequent
    -- ApplyLayout returned right here. The header then keeps whatever
    -- configuration it had: converting party <-> raid stops reassigning unit
    -- attributes, RegisterUnitWatch hides every button because their unit
    -- attribute is nil, and the frames vanish until a /reload. Confirmed
    -- against a live diagnostic dump: all five buttons had a nil "unit"
    -- attribute and IsShown() == false.
    --
    -- Genuine re-entrancy happens within a single frame, so honouring the
    -- flag only briefly keeps that protection while guaranteeing the module
    -- self-heals instead of wedging permanently.
    if applyingLayout then
        if applyingLayoutAt and (GetTime() - applyingLayoutAt) > 1 then
            applyingLayout = false
        else
            return
        end
    end
    if InCombatLockdown() then
        if not applyLayoutRetryFrame then
            applyLayoutRetryFrame = CreateFrame("Frame")
            applyLayoutRetryFrame:SetScript("OnEvent", function(self)
                self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                ApplyLayout()
            end)
        end
        applyLayoutRetryFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end

    -- SecureGroupHeader_Update (triggered by SetAttribute) calls header:GetPoint(1).
    -- If the header's container hasn't been laid out by WoW's renderer yet, this
    -- returns nil. Defer the layout to the next frame tick when the rect is valid.
    --
    -- Tests the POINT (first return), not the fifth (2026-08-07). This was
    -- `local _, _, _, _, _ = header:GetPoint(1)` -- five locals all named
    -- `_`, so `_` resolved to the LAST one (yOfs) and the check was reading
    -- the wrong value entirely. It happened to behave because a missing
    -- point makes every return nil, and a present one usually has a
    -- non-nil yOfs -- but yOfs is legitimately 0 here (CENTER anchor, no
    -- offset) and `not 0` is false in Lua, so it only ever worked by luck.
    local headerPoint = header:GetPoint(1)
    if not headerPoint then
        applyingLayout = false
        C_Timer.After(0, ApplyLayout)
        return
    end

    applyingLayout = true
    applyingLayoutAt = GetTime()

    local prof = GetProfile()
    local layout = GetActiveLayout(prof)
    if not layout then
        applyingLayout = false
        return
    end

    ApplyContainerAnchor(prof, layout)

    -- SecureGroupHeaderTemplate uses xOffset/yOffset (not spacingX/spacingY)
    local spacing = layout.spacingY or 0
    local orientation = layout.orientation or "vertical"
    local growthDir = layout.growthDirection or "DOWN"
    local buttonWidth = layout.width or 100
    local buttonHeight = layout.height or 40

    -- Clear stale anchors BEFORE touching the header's attributes, so the
    -- header's own configureChildren (triggered by the SetAttribute calls
    -- below) starts from a clean slate. A button that still carries an old
    -- anchor from a previous growth direction (e.g. a TOP/BOTTOM anchor from
    -- vertical growth still active when switching to CENTER_H) can end up
    -- with two anchor points from two different layouts fighting each
    -- other, producing a diagonal stagger instead of a clean row/column.
    --
    -- Covers the raid group headers' children as well as the party header's:
    -- a party <-> raid switch changes which set is live, and configureChildren
    -- calls SetPoint WITHOUT clearing first, so a button carrying an anchor
    -- from the other mode keeps both.
    for _, button in ipairs(header) do
        button:ClearAllPoints()
    end
    for i = 1, RAID_GROUP_COUNT do
        local gh = groupHeaders[i]
        if gh then
            for _, button in ipairs(gh) do
                button:ClearAllPoints()
            end
        end
    end

    local isCenterH, isCenterV = false, false
    local isRaidMode = IsInRaid()

    if isRaidMode then
        -- Raid: one secure header per subgroup (see the groupHeaders comment
        -- at the top of this file). orientation/growthDirection are
        -- reinterpreted one level up from party's meaning -- see
        -- Layout_Defaults.lua's comment on profile.layout.raid. CENTER_H/
        -- CENTER_V centre the unit axis WITHIN each subgroup; group placement
        -- itself (blocks side by side / stacked) is unaffected.
        isCenterH = (growthDir == "CENTER_H")
        isCenterV = (growthDir == "CENTER_V")

        -- Stand the party header down FIRST, while it is still visible.
        -- Attribute changes only trigger the header's own configureChildren
        -- while IsVisible() is true (SecureGroupHeader_OnAttributeChanged), so
        -- hiding first would leave its 40 children holding raid units and
        -- drawing the entire raid on top of the group headers.
        header:SetAttribute("showRaid", false)
        header:SetAttribute("showParty", false)
        header:SetAttribute("showSolo", false)
        header:Hide()

        LayoutRaidGroupHeaders(layout, spacing, orientation, growthDir,
            buttonWidth, buttonHeight, isCenterH, isCenterV)
    else
        -- Party: single strip of up to 5, unchanged from before raid support.
        -- point: which direction children grow from the header anchor. CENTER_H/
        -- CENTER_V use a NATIVE edge-growth direction just like the regular
        -- modes below (never manual child positioning) -- see
        -- ReanchorHeaderForCenterGrowth for how the "centered" look is faked by
        -- moving the header's own anchor instead.
        -- "vertical" + "DOWN"  = "TOP" (grow downward from top)
        -- "vertical" + "UP"    = "BOTTOM" (grow upward from bottom)
        -- "horizontal" + "RIGHT" = "LEFT" (grow rightward from left)
        -- "horizontal" + "LEFT"  = "RIGHT" (grow leftward from right)
        -- "CENTER_H" = "LEFT", grows rightward
        -- "CENTER_V" = "TOP", grows downward
        isCenterH = (growthDir == "CENTER_H")
        isCenterV = (growthDir == "CENTER_V")

        -- Raid group headers go inert before the party header is re-armed, so
        -- the two sets can never both claim units at once.
        HideRaidGroupHeaders()

        local point
        if isCenterH then
            point = "LEFT"
        elseif isCenterV then
            point = "TOP"
        elseif orientation == "horizontal" then
            point = (growthDir == "LEFT") and "RIGHT" or "LEFT"
        else
            point = (growthDir == "UP") and "BOTTOM" or "TOP"
        end

        header:SetAttribute("point", point)
        -- xOffset/yOffset is just the GAP between adjacent buttons -- the header
        -- already accounts for each child's own width/height internally when
        -- stacking them. Confirmed against EllesmereUI's own working
        -- implementation (EllesmereUIRaidFrames.lua's _LayoutPartyFrames): they
        -- use xOffset=cs (spacing alone) for LEFT/RIGHT-anchored growth and
        -- yOffset=cs for TOP/BOTTOM-anchored growth, never button-dimension +
        -- spacing. Adding the button's own width/height on top (what this used
        -- to do) double-counts it, producing a diagonal stagger instead of a
        -- clean row/column.
        if point == "LEFT" then
            header:SetAttribute("xOffset", spacing)
            header:SetAttribute("yOffset", 0)
        elseif point == "RIGHT" then
            header:SetAttribute("xOffset", -spacing)
            header:SetAttribute("yOffset", 0)
        elseif point == "TOP" then
            header:SetAttribute("xOffset", 0)
            header:SetAttribute("yOffset", -spacing)
        else -- "BOTTOM"
            header:SetAttribute("xOffset", 0)
            header:SetAttribute("yOffset", spacing)
        end
        header:SetAttribute("maxColumns", 1)
        header:SetAttribute("unitsPerColumn", 5)
        header:SetAttribute("showPlayer", not layout.hideSelf)
        header:SetAttribute("showSolo", not layout.hideSelf)
        header:SetAttribute("showParty", true)
        header:SetAttribute("showRaid", false)
        ApplyRoleSortAttributes(header, layout)
        -- Re-arm after raid mode hid it. Show LAST, for the same reason the
        -- group headers do: OnShow is what runs configureChildren, and writes
        -- made while hidden were stored but never acted on.
        header:Show()
    end

    -- No state-visibility driver: let the header manage per-child visibility
    -- via RegisterUnitWatch (built into SecureUnitButtonTemplate).
    -- showSolo/showParty/showRaid/showPlayer attributes tell the header which
    -- unit slots to populate; buttons for non-existent units auto-hide.
    -- hideSelf just toggles showPlayer/showSolo off.
    UnregisterAttributeDriver(header, "state-visibility")

    -- Sizes go on whichever set is live -- in a raid that's the group headers'
    -- children, and the party header's 40 are hidden and unit-less.
    ForEachHeaderButton(function(button)
        button:SetSize(buttonWidth, buttonHeight)
    end)

    -- Child positions are now ENTIRELY owned by the header's own native
    -- attribute-driven configureChildren -- we never touch them manually,
    -- for any growth direction. The only thing we position ourselves is the
    -- header FRAME's own anchor, which fakes the "centered" look for
    -- CENTER_H/CENTER_V without ever racing the header's internal reflow.
    -- Raid uses its own variant (assumes a full 5-member subgroup rather
    -- than a single flat visible-count, since centering must apply
    -- consistently across multiple grouped columns/rows).
    if not isRaidMode then
        ReanchorHeaderForCenterGrowth(isCenterH, isCenterV, buttonWidth, buttonHeight, spacing)
    end
    -- Raid has no equivalent call: LayoutRaidGroupHeaders already placed every
    -- group header itself, centring each block on its own real member count
    -- rather than the whole-header approximation the single header needed.

    -- Re-size the edit mode overlay to match the laid-out buttons
    if partyFrame and partyFrame.editFrame and partyFrame.editFrame:IsShown() then
        SizeEditFrameToButtons()
    end

    -- Re-size the container to the visible button footprint (anchored
    -- CENTER→CENTER so resizing doesn't shift position). The mover frame
    -- (edit-mode drag handle) matches this size via SetAllPoints.
    SizeContainerToButtons()
    if partyFrame and partyFrame.mover then
        partyFrame.mover:SetAllPoints(partyFrame)
    end

    -- Safety net: if the container ended up off-screen (e.g. from stale
    -- saved coordinates after a code change), reset to defaults so the
    -- user isn't left with invisible frames. Resets whichever layout
    -- (party/raid) is actually active.
    --
    -- Uses ContainerCenterInUIParentSpace (bug fix 2026-08-07, user report:
    -- switching party <-> raid lost the saved raid position and nudged the
    -- party one). partyFrame:GetCenter() is in the CONTAINER's own scaled
    -- coordinate space -- CreatePartyContainer calls partyFrame:SetScale()
    -- from the profile's UI scale -- while UIParent:GetLeft()/GetRight()
    -- are in UIPARENT's space. At any scale other than 1.0 those diverge,
    -- so comparing them directly could wrongly conclude "off-screen" for a
    -- perfectly visible frame and then OVERWRITE that mode's saved anchor
    -- with the defaults below. Harmless before, because this ran rarely;
    -- the 2026-08-07 fix that made OnGroupTypeChanged always run ApplyLayout
    -- (instead of silently skipping in combat) started exercising it on
    -- every mode transition, which is what surfaced the loss.
    if partyFrame then
        local cx, cy = ContainerCenterInUIParentSpace()
        if cx and cy then
            local l, r = UIParent:GetLeft(), UIParent:GetRight()
            local b, t = UIParent:GetBottom(), UIParent:GetTop()
            if l and r and b and t then
                if cx < l or cx > r or cy < b or cy > t then
                    local p = GetProfile()
                    local activeLayout = GetActiveLayout(p)
                    -- Mode-appropriate default (raid resets to raid's own
                    -- spot, not the party one) -- see
                    -- GetDefaultAnchorForActiveMode.
                    local defX, defY = GetDefaultAnchorForActiveMode()
                    if activeLayout then
                        activeLayout.anchorX = defX
                        activeLayout.anchorY = defY
                        -- Reset the anchor POINT too, not just the offsets.
                        -- The defaults in Layout_Defaults are expressed as
                        -- offsets from screen centre; re-applying (0, -200)
                        -- under a TOPLEFT anchor would land 200px above the
                        -- top-left corner -- i.e. straight back off-screen,
                        -- defeating the whole point of this rescue.
                        activeLayout.anchorPoint = "CENTER"
                    end
                    ApplyContainerAnchor(GetProfile(), activeLayout)
                end
            end
        end
    end

    applyingLayout = false

    -- Always re-wire shortly after laying out (bug fix 2026-08-07, second
    -- half of the intermittent "raid -> party clears the frames" report).
    --
    -- Setting the header's attributes above kicks off SecureGroupHeaderTemplate's
    -- ASYNCHRONOUS configureChildren, so unit attributes aren't correct yet
    -- when this function returns. Callers that know this schedule their own
    -- delayed re-wire (OnGroupTypeChanged/OnLayoutChanged do) -- but the
    -- combat-deferred path does NOT: when applyLayoutRetryFrame fires on
    -- PLAYER_REGEN_ENABLED it runs ApplyLayout alone, with no follow-up, so
    -- whatever wiring existed stayed stale. The separate retry frames also
    -- fire in unspecified order, so WireUpAllButtons could run BEFORE this
    -- and then never run again.
    --
    -- Owning the follow-up here means every path that lays out also re-wires.
    -- Coalesced so the callers' own delayed re-wires don't stack with it.
    if not relayoutWireQueued then
        relayoutWireQueued = true
        C_Timer.After(0.1, function()
            relayoutWireQueued = false
            WireUpAllButtons()
            UpdateAllButtons()
            SizeContainerToButtons()
        end)
    end
end

-- Public accessor so the options panel can update the saved anchor corner
-- when the user changes growth direction (without waiting for the next
-- ApplyLayout triggered by LayoutChanged).
function PartyFrames:GetAnchorForGrowth()
    return GetAnchorForGrowth()
end

-- Re-anchor the container against the layout's configured anchor point,
-- preserving the current screen position. Called only when the user changes
-- growth direction or orientation from the options panel (not on every
-- ApplyLayout / roster update — that would cause drifting).
--
-- The container is pinned POINT→POINT (see the anchor-point section near the
-- top of this file). With the default CENTER that means the centre of the
-- block stays locked to the saved screen point regardless of how many buttons
-- are visible, and buttons grow outward from it; with an edge/corner point
-- that edge is what stays put and the block grows away from it.
function PartyFrames:ReanchorContainer()
    if not partyFrame then return end
    local p0 = GetProfile()
    local anchorPoint = GetAnchorPoint(GetActiveLayout(p0))
    -- Hold the configured ANCHOR POINT still, not the centre -- with e.g. a
    -- TOPLEFT anchor the user's expectation is that corner stays nailed down
    -- while the block regrows in the new direction.
    local curX, curY = ContainerAnchorInUIParentSpace(anchorPoint)
    if not curX or not curY then
        -- No valid rect yet — reset to defaults
        local p = GetProfile()
        local activeLayout = GetActiveLayout(p)
        -- Mode-appropriate default, same reasoning as ApplyLayout's
        -- off-screen reset -- see GetDefaultAnchorForActiveMode.
        local defX, defY = GetDefaultAnchorForActiveMode()
        if activeLayout then
            activeLayout.anchorX = defX
            activeLayout.anchorY = defY
            -- Defaults are centre-relative, so the point has to come back to
            -- CENTER with them (same reasoning as the off-screen reset).
            activeLayout.anchorPoint = "CENTER"
        end
        ApplyContainerAnchor(p, activeLayout)
        return
    end
    -- Save as CENTER→CENTER offset from UIParent center.
    --
    -- curX/curY come from ContainerCenterInUIParentSpace (2026-08-07), so
    -- they're already in the same space as UIParent's own width/height.
    -- This previously used partyFrame:GetCenter() directly and subtracted
    -- UIParent-space values from it, then multiplied by the frame's scale --
    -- correct only at scale 1.0, and at any other scale it shifted the
    -- frame slightly every time growth direction or orientation changed
    -- (matching a user report of the frames drifting).
    --
    -- The saved value is in UIParent space (same convention the drag
    -- handler uses); the SetPoint offset divides by the container's own
    -- scale, exactly as ApplyContainerAnchor does when restoring it.
    -- Offset from the configured anchor's own screen position (this is
    -- upW/2, upH/2 for CENTER -- the previous hardcoded behaviour).
    local originX, originY = ScreenAnchorCoords(anchorPoint)
    local savedX = curX - originX
    local savedY = curY - originY
    -- Persist so the position survives reloads. Writes to whichever layout
    -- (party/raid) is currently active.
    local p = GetProfile()
    local activeLayout = GetActiveLayout(p)
    if activeLayout then
        activeLayout.anchorX = savedX
        activeLayout.anchorY = savedY
    end
    ApplyContainerAnchor(p, activeLayout)
end

-- Force all visible-unit buttons to actually show. On initial login the secure
-- header's RegisterUnitWatch may not have fired yet, leaving buttons hidden
-- even though their units exist. This re-applies layout, wires buttons, and
-- explicitly shows any button whose unit is present.
local refreshVisibleRetryFrame
local function RefreshVisible()
    if not header or not partyFrame then return end
    -- Combat guard (2026-08-07): the button:Show()/partyFrame:Show() calls
    -- below are protected on RegisterUnitWatch-managed secure buttons. Every
    -- caller is a C_Timer.After(...) whose only lockdown check happened at
    -- schedule time -- same schedule-vs-fire gap ApplyLayout/WireUpAllButtons
    -- were already fixed for. ApplyLayout/WireUpAllButtons/SizeContainerToButtons
    -- each self-guard too, but they'd then each queue their OWN retry while
    -- this function's own Show() loop still ran unguarded, so guard here first.
    if InCombatLockdown() then
        if not refreshVisibleRetryFrame then
            refreshVisibleRetryFrame = CreateFrame("Frame")
            refreshVisibleRetryFrame:SetScript("OnEvent", function(self)
                self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                RefreshVisible()
            end)
        end
        refreshVisibleRetryFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    ApplyLayout()
    WireUpAllButtons()
    UpdateAllButtons()
    SizeContainerToButtons()
    -- Force-show buttons whose units exist. RegisterUnitWatch normally handles
    -- this but may not have run yet on first login.
    ForEachHeaderButton(function(button)
        if button.unit and UnitExists(button.unit) then
            button:Show()
        end
    end)
    partyFrame:Show()
end

-- Lightweight update for roster changes and flag changes (AFK, cinematic,
-- logout-return). Does NOT touch the header's attributes or any child
-- position -- the secure header's own attribute-driven configureChildren
-- (set once by ApplyLayout) already positions every button correctly for
-- EVERY growth direction, including CENTER_H/CENTER_V (see
-- ReanchorHeaderForCenterGrowth), and RegisterUnitWatch auto-shows/hides
-- buttons for new units. The only thing that can go stale on a roster
-- change is the header's OWN anchor for center growth (it depends on the
-- visible count), so that's all we recompute here.
local function OnRosterOrFlagChanged()
    if not header then return end
    if applyingLayout then return end
    applyingLayout = true

    if IsInRaid() then
        -- Unlike party's fixed 5-max, raid's active-subgroup count changes
        -- dynamically as members join/leave/switch groups -- the container
        -- must shrink-wrap on every roster change, not just at ApplyLayout.
        --
        -- The group headers have to be re-slotted on the same event: which
        -- subgroups are populated is exactly what decides their positions, and
        -- a group emptying or filling shifts every block after it. Out of
        -- combat only -- header SetPoint is protected, and a group that gains
        -- its first member mid-fight is already parked in a usable slot (see
        -- CensusRaidGroups on why empty groups still get one).
        if not InCombatLockdown() then
            local rProf = GetProfile()
            local rLayout = GetActiveLayout(rProf)
            if rLayout then
                local rGrowth = rLayout.growthDirection or "DOWN"
                LayoutRaidGroupHeaders(rLayout,
                    rLayout.spacingY or 0,
                    rLayout.orientation or "vertical",
                    rGrowth,
                    rLayout.width or 100,
                    rLayout.height or 40,
                    rGrowth == "CENTER_H",
                    rGrowth == "CENTER_V")
            end
        end
        SizeContainerToButtons()
        if partyFrame and partyFrame.editFrame and partyFrame.editFrame:IsShown() then
            SizeEditFrameToButtons()
        end
        applyingLayout = false
        return
    end

    local prof = GetProfile()
    local layout = GetActiveLayout(prof)
    local growthDir = layout and layout.growthDirection or "DOWN"
    local isCenterH = (growthDir == "CENTER_H")
    local isCenterV = (growthDir == "CENTER_V")

    if isCenterH or isCenterV then
        local spacing = (layout and layout.spacingY) or 0
        local buttonWidth = (layout and layout.width) or 100
        local buttonHeight = (layout and layout.height) or 40
        ReanchorHeaderForCenterGrowth(isCenterH, isCenterV, buttonWidth, buttonHeight, spacing)
    end

    -- Shrink-wrap to the live visible count, same as the raid path above and
    -- same as ApplyLayout does.
    --
    -- This used to be skipped, with a comment claiming the party container is
    -- "fixed (max 5 buttons)" -- but SizeContainerToButtons' party branch has
    -- always sized to the VISIBLE count, so the comment described behaviour
    -- the code didn't have, and the container was simply left stale until the
    -- next ApplyLayout. That left the edit-mode drag area (mover:SetAllPoints)
    -- covering the wrong region after members joined, and made the roster path
    -- and the loading-screen path disagree about the container's geometry.
    --
    -- Safe to do now that the header is pinned to the container's own anchor
    -- point rather than its centre (see ReanchorHeaderForCenterGrowth): a
    -- resize can no longer move the buttons.
    SizeContainerToButtons()
    if partyFrame and partyFrame.mover then
        partyFrame.mover:SetAllPoints(partyFrame)
    end
    if partyFrame and partyFrame.editFrame and partyFrame.editFrame:IsShown() then
        SizeEditFrameToButtons()
    end

    applyingLayout = false
end

-----------------------------------------------------------------------
-- Edit mode: show/hide border and enable/disable dragging
-----------------------------------------------------------------------

-- Change a layout's screen anchor point, keeping the frames where they are.
--
-- layoutKey is "main" or "raid". The stored anchorX/anchorY are an offset
-- from the anchor point, so changing the point without rewriting them would
-- teleport the frames by up to a full screen. This re-expresses the SAME
-- on-screen position against the new point.
--
-- Exact when the layout being changed is the one currently on screen (the
-- container can be measured directly, including its real block size). For the
-- other mode, only the screen-origin term can be corrected -- the block's
-- footprint isn't known without a live container -- so the frames can land up
-- to half a block out and may want a nudge. Edit mode's Party/Raid switch
-- makes the target layout active, so changing the point from there is always
-- the exact path.
function PartyFrames:SetLayoutAnchorPoint(layoutKey, point)
    if not VALID_ANCHOR_POINTS[point] then return end
    local prof = GetProfile()
    local layout = prof and prof.layout and prof.layout[layoutKey]
    if not layout then return end

    local oldPoint = GetAnchorPoint(layout)
    if oldPoint == point then return end

    local isActive = (layout == GetActiveLayout(prof))
    local newX, newY

    if isActive and partyFrame then
        -- Measure where the NEW point currently sits, then express it
        -- relative to that point's own screen origin.
        local curX, curY = ContainerAnchorInUIParentSpace(point)
        if curX and curY then
            local ox, oy = ScreenAnchorCoords(point)
            newX, newY = curX - ox, curY - oy
        end
    end

    if not newX then
        -- Fallback: keep the anchor POINT itself at the same screen spot,
        -- ignoring the block-footprint term (see the note above).
        local oldOx, oldOy = ScreenAnchorCoords(oldPoint)
        local newOx, newOy = ScreenAnchorCoords(point)
        newX = (layout.anchorX or 0) + oldOx - newOx
        newY = (layout.anchorY or 0) + oldOy - newOy
    end

    layout.anchorPoint = point
    layout.anchorX = newX
    layout.anchorY = newY

    if isActive and not InCombatLockdown() then
        ApplyContainerAnchor(prof, layout)
    end
    SquizzFrames:Fire("LayoutChanged")
end

-- Repaint the Party/Raid switch so the currently-edited layout reads as
-- selected. Also labels the mode you're really in, so it stays obvious that
-- editing "Raid" from inside a party is showing party members standing in for
-- raid geometry rather than a real raid.
function PartyFrames:RefreshEditModeToggle()
    if not partyFrame or not partyFrame.editFrame then return end
    local toggle = partyFrame.editFrame.modeToggle
    if not toggle then return end

    local activeKey = GetEditLayoutKey()
    local realKey = IsInRaid() and "raid" or "main"
    local accent = F.GetAccentColor() or { r = 0.33, g = 0.77, b = 0.99 }

    for _, b in ipairs({ toggle.partyButton, toggle.raidButton }) do
        local selected = (b.layoutKey == activeKey)
        -- Only the FILL changes between states; the text stays white and
        -- outlined, matching the options panel's own Party/Raid tabs. Accent
        -- colours are class colours, and the light ones (pink, yellow, tan)
        -- make dark text on a near-opaque accent fill unreadable -- keeping
        -- the fill translucent keeps the button dark enough for white text
        -- whatever the accent happens to be.
        if selected then
            b.bg:SetColorTexture(accent.r, accent.g, accent.b, 0.55)
        else
            b.bg:SetColorTexture(0, 0, 0, 0.6)
        end
        b.text:SetTextColor(1, 1, 1, 1)
        -- Mark the mode actually in effect right now, so "Raid *" reads as
        -- "this is the live one" vs a stand-in.
        local base = (b.layoutKey == "raid") and (L["Raid"] or "Raid") or (L["Party"] or "Party")
        b.text:SetText(b.layoutKey == realKey and (base .. " *") or base)
    end
end

-- Point edit mode at a specific layout ("main"/"raid"), or nil to follow the
-- real group state again.
--
-- Why this exists: the mock preview window renders unscaled stand-in buttons
-- and never matched the live frames' size, so adjusting the raid layout while
-- in a party meant eyeballing it. Edit mode drags the REAL container, so its
-- anchors are correct by construction -- this just lets edit mode point at
-- the other mode's layout sub-table.
--
-- Scope note: this overrides GEOMETRY only (size, spacing, growth direction,
-- screen anchor -- everything GetActiveLayout feeds). It deliberately does
-- NOT touch the header's unit-population attributes, which stay bound to
-- IsInRaid(): a SecureGroupHeader can only ever lay out units that actually
-- exist, so there is no way to conjure 40 raid slots while in a 5-man party.
-- You get your real group members drawn at the raid layout's size/spacing/
-- position, which is exactly what's needed to set size and position.
function PartyFrames:SetEditLayoutOverride(key)
    if key ~= "main" and key ~= "raid" then key = nil end
    -- Pointing at the mode we're already really in is the same as no
    -- override; normalising here keeps GetEditLayoutKey stable and avoids a
    -- pointless relayout.
    if key and key == (IsInRaid() and "raid" or "main") then key = nil end
    if editLayoutOverride == key then return end

    if InCombatLockdown() then
        SquizzFrames:Print(L["Can't change the edit target in combat."]
            or "Can't change the edit target in combat.")
        return
    end

    editLayoutOverride = key
    ApplyLayout()
    -- Button dimensions come from the layout, so the wired buttons need
    -- resizing too -- ApplyLayout only reconfigures the header itself.
    WireUpAllButtons()
    C_Timer.After(0, function()
        SizeEditFrameToButtons()
        PartyFrames:RefreshEditModeToggle()
    end)
    SquizzFrames:Fire("EditLayoutOverrideChanged", GetEditLayoutKey())
end

function PartyFrames:GetEditLayoutKey()
    return GetEditLayoutKey()
end

function PartyFrames:SetEditMode(enabled)
    if not partyFrame or not partyFrame.editFrame then return end
    local editFrame = partyFrame.editFrame
    local accent = F.GetAccentColor()
    local function ApplyColor(alpha)
        local c = {0.33, 0.77, 0.99}
        if accent then c = {accent.r, accent.g, accent.b} end
        editFrame.borderTop:SetColorTexture(c[1], c[2], c[3], alpha)
        editFrame.borderBottom:SetColorTexture(c[1], c[2], c[3], alpha)
        editFrame.borderLeft:SetColorTexture(c[1], c[2], c[3], alpha)
        editFrame.borderRight:SetColorTexture(c[1], c[2], c[3], alpha)
    end
    if enabled then
        -- Show border around buttons
        ApplyColor(0.9)
        editFrame.editLabel:SetTextColor(0.33, 0.77, 0.99, 1.0)
        -- Show the non-secure mover frame so the user can drag. It sits on
        -- top of the container and intercepts drag events before they reach
        -- the secure unit buttons below.
        if partyFrame.mover then
            partyFrame.mover:SetAllPoints(partyFrame)
            partyFrame.mover:Show()
        end
        -- Defer sizing by one frame tick so buttons have valid rects
        C_Timer.After(0, function()
            SizeEditFrameToButtons()
            if editFrame then editFrame:Show() end
            PartyFrames:RefreshEditModeToggle()
        end)
    else
        -- Hide border and disable dragging
        ApplyColor(0.0)
        editFrame.editLabel:SetTextColor(0, 0, 0, 0)
        editFrame:Hide()
        if partyFrame.mover then partyFrame.mover:Hide() end
        -- Drop any edit-only mode override and snap back to the layout that
        -- matches the real group state. Without this, leaving edit mode while
        -- pointed at the other mode would strand the live frames on the wrong
        -- layout's size/position until the next group change -- exactly the
        -- half-switched state OnGroupTypeChanged's combat retry exists to
        -- prevent. Guarded because SetEditMode(false) is reachable from the
        -- combat auto-disable path, where relayout is illegal; the
        -- PLAYER_REGEN_ENABLED retry inside ApplyLayout picks it up instead.
        if editLayoutOverride then
            editLayoutOverride = nil
            if not InCombatLockdown() then
                ApplyLayout()
                WireUpAllButtons()
            end
            SquizzFrames:Fire("EditLayoutOverrideChanged", GetEditLayoutKey())
        end
    end
end

function PartyFrames:OnInitialize()
    -- Register message callbacks on THIS module (not on the addon root).
    -- CallbackHandler keys registrations by owner table, so two modules
    -- registering on the same target for the same message would collide.
    -- By registering on ourselves, each module gets its own key; a single
    -- SquizzFrames:SendMessage (from Fire) reaches every handler regardless
    -- of which object it was registered on.
    self:RegisterMessage("GroupTypeChanged", function() self:OnGroupTypeChanged() end)
    self:RegisterMessage("LayoutChanged", function() self:OnLayoutChanged() end)
    self:RegisterMessage("ProfileChanged", function() self:OnProfileChanged() end)
    -- Edit mode checkbox is the master toggle; Lock Frames syncs to it
    self:RegisterMessage("EditModeChanged", function(_, enabled)
        self:SetEditMode(enabled)
    end)
    self:RegisterMessage("LockChanged", function(_, isLocked)
        -- Locking turns off edit mode; unlocking leaves edit mode as-is
        if isLocked and SquizzFrames.editMode then
            SquizzFrames.editMode = false
            self:SetEditMode(false)
            SquizzFrames:Fire("EditModeChanged", false)
        end
    end)
end

function PartyFrames:OnEnable()
    if initialized then
        ApplyLayout()
        -- Only show edit frame if the user has enabled it via the checkbox
        if SquizzFrames.editMode then
            self:SetEditMode(true)
        end
        return
    end

    -- Create frames (deferred until out of combat if needed)
    local function init()
        CreatePartyContainer()
        CreateHeader()
        -- Built up front even when the player is nowhere near a raid: creating
        -- a secure header (and its children) is protected, so there is no
        -- second chance once a raid forms mid-combat. They stay hidden and
        -- inert until ApplyLayout puts them into raid mode.
        CreateRaidGroupHeaders()

        -- Size the container immediately so there's no dead space below the
        -- buttons before the first ApplyLayout runs. Uses default button
        -- dimensions; ApplyLayout will refine this once buttons have rects.
        SizeContainerToButtons()

        -- Defer ApplyLayout by one frame tick so the header's container has a
        -- valid rect. SecureGroupHeader_Update (called by SetAttribute) reads
        -- header:GetPoint(1) — if the container hasn't been laid out yet by WoW's
        -- renderer, GetPoint returns nil and we get "attempt to index local 'point'".
        C_Timer.After(0, function()
            -- Set container to fixed max size BEFORE ApplyLayout so the
            -- header:CENTER anchor has a valid rect to work with.
            SizeContainerToButtons()
            ApplyLayout()
        end)

        -- Secure header spawns children asynchronously after attributes are set.
        -- Wire up immediately (for existing children) and again on a slight delay.
        WireUpAllButtons()
        UpdateAllButtons()

        -- Re-wire after header has had time to spawn children
        C_Timer.After(0.5, function()
            WireUpAllButtons()
            UpdateAllButtons()
            SizeContainerToButtons()
        end)

        -- Force-show buttons whose units exist. On initial login,
        -- RegisterUnitWatch may not have fired yet, leaving buttons hidden
        -- even though their units exist. Schedule re-wire + container resize
        -- at increasing delays (no secure operations in combat; ApplyLayout
        -- is skipped by InCombatLockdown guards when it runs from the
        -- PLAYER_ENTERING_WORLD handler). The PLAYER_ENTERING_WORLD handler
        -- also calls RefreshVisible on a timer for the out-of-combat case.
        C_Timer.After(0.3, function()
            WireUpAllButtons()
            UpdateAllButtons()
            SizeContainerToButtons()
        end)
        C_Timer.After(1.0, function()
            -- Re-apply layout to force the secure header to re-run
            -- configureChildren with the full set of party units. On /reload in
            -- a party, the header's initial configureChildren may have run before
            -- all party units existed, leaving buttons with stale anchors.
            ApplyLayout()
            WireUpAllButtons()
            UpdateAllButtons()
            SizeContainerToButtons()
        end)
        C_Timer.After(2.0, function()
            ApplyLayout()
            WireUpAllButtons()
            UpdateAllButtons()
            SizeContainerToButtons()
        end)

        -- Auto-disable the layout preview on combat start -- it deals with
        -- the same button frames the secure header could touch, so it
        -- shouldn't be left active once real secure updates might occur.
        SquizzFrames:RegisterEvent("PLAYER_REGEN_DISABLED", function()
            -- self:IsPreviewActive() (method dispatch), not a bare
            -- `previewActive` reference -- that local is declared further
            -- down in this file, after OnEnable, so referencing it directly
            -- here would silently resolve to a nonexistent global.
            if self:IsPreviewActive() then
                self:SetPreviewMode(false)
                SquizzFrames:Fire("PreviewModeChanged", false)
            end
        end)

        -- Register events for health/power/aura updates
        local function onUnitEvent(_, unit)
            if unit then self:OnUnitEvent(unit) end
        end
        SquizzFrames:RegisterEvent("UNIT_HEALTH", onUnitEvent)
        SquizzFrames:RegisterEvent("UNIT_MAXHEALTH", onUnitEvent)
        SquizzFrames:RegisterEvent("UNIT_POWER_UPDATE", onUnitEvent)
        SquizzFrames:RegisterEvent("UNIT_MAXPOWER", onUnitEvent)
        SquizzFrames:RegisterEvent("UNIT_DISPLAYPOWER", onUnitEvent)
        SquizzFrames:RegisterEvent("UNIT_CONNECTION", onUnitEvent)
        -- Drives the Drinking status text (IsUnitDrinking scans for the
        -- Food & Drink buff) -- fires on every aura change for the unit, same
        -- cost class as the health/power events already registered above.
        SquizzFrames:RegisterEvent("UNIT_AURA", onUnitEvent)
        -- Drives the Pending/Accepted/Declined summon status text. Fires with
        -- no unit payload (confirmed against EllesmereUIRaidFrames), so every
        -- wired button's status needs re-checking rather than just one unit.
        SquizzFrames:RegisterEvent("INCOMING_SUMMON_CHANGED", function()
            for _, button in pairs(unitButtons) do
                UpdateStatus(button)
            end
        end)
        -- GROUP_ROSTER_UPDATE fires when a party/raid member joins/leaves.
        -- The secure header automatically shows/heads buttons for new units
        -- via RegisterUnitWatch. We just need to re-size the container and
        -- re-wire the new buttons. We do NOT call ApplyLayout here — that would
        -- reset the header's attribute-driven layout (causing a visible flash
        -- of the wrong growth direction) when nothing about orientation/growth
        -- actually changed.
        -- Center growth (CENTER_H/CENTER_V) needs OnRosterOrFlagChanged to
        -- recompute the header's own anchor (see
        -- ReanchorHeaderForCenterGrowth) whenever the visible count changes,
        -- so the "centered" block stays centered as members join/leave.
        -- Child positions themselves are never touched -- that's the header's
        -- own native attribute-driven job, for every growth direction, so
        -- there's nothing here that can race its internal configureChildren.
        -- Staggered retries (mirroring PLAYER_ENTERING_WORLD's own
        -- triple-refresh below) just account for RegisterUnitWatch's
        -- show/hide of new buttons taking a moment to actually happen, so
        -- our visible-count recompute isn't reading a stale count.
        local function ReapplyRosterLayout()
            if InCombatLockdown() then return end
            OnRosterOrFlagChanged()
            WireUpAllButtons()
            UpdateAllButtons()
        end
        -- Retry frame for the three staggered calls below, which all bail
        -- out via ReapplyRosterLayout's own InCombatLockdown() check if
        -- combat is still active at 0.3/1.0/2.0s after the roster change --
        -- a fight commonly lasts well past that whole window, so a member
        -- leaving/joining mid-combat could miss ALL three retries with
        -- nothing left to ever re-sync, even once combat actually ended
        -- (confirmed via user report: frames stayed wrong until a full
        -- /reload, well after combat had dropped). One-shot PLAYER_REGEN_
        -- ENABLED registration mirrors SizeContainerToButtons' own
        -- sizeRetryFrame pattern -- re-armed (harmless if already
        -- registered) on every roster change, unregisters itself after
        -- firing once.
        local rosterRetryFrame
        SquizzFrames:RegisterEvent("GROUP_ROSTER_UPDATE", function()
            C_Timer.After(0.3, ReapplyRosterLayout)
            C_Timer.After(1.0, ReapplyRosterLayout)
            C_Timer.After(2.0, ReapplyRosterLayout)
            if not rosterRetryFrame then
                rosterRetryFrame = CreateFrame("Frame")
                rosterRetryFrame:SetScript("OnEvent", function(self)
                    self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                    -- FULL re-apply here, unlike the staggered in-combat
                    -- retries above, which deliberately skip ApplyLayout.
                    --
                    -- Skipping it is right for an ordinary join/leave: the
                    -- header's own configureChildren already positions
                    -- everything and RegisterUnitWatch handles visibility, so
                    -- re-pushing attributes would only cause a visible flash
                    -- of the wrong growth direction for no gain.
                    --
                    -- It is WRONG for a roster change that happened during
                    -- combat. Attribute reconfiguration is deferred under
                    -- lockdown, so a child can come out of the fight still
                    -- carrying a stale unit token -- RegisterUnitWatch then
                    -- hides it (the token names nobody) while the header still
                    -- lays out its slot, leaving a GAP where the button should
                    -- be. Nothing else ever re-assigns that token, which is
                    -- why it survived combat ending and only a /reload cleared
                    -- it. Re-applying the layout forces the header to
                    -- reconfigure and hand out current tokens.
                    --
                    -- Reported 2026-08-18: a Delve NPC companion leaves and
                    -- instantly rejoins on player death, mid-combat, and its
                    -- button never returns. Not actually NPC-specific -- any
                    -- member churning during a fight can land here. The flash
                    -- this guards against is a non-issue on the combat-end
                    -- path, where the frames are re-syncing anyway.
                    ApplyLayout()
                    ReapplyRosterLayout()
                end)
            end
            rosterRetryFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        end)
        -- UNIT_NAME_UPDATE re-sorts the header too -- not just roster changes.
        --
        -- Verified against Blizzard's own SecureGroupHeaders.lua
        -- (Blizzard_RestrictedAddOnEnvironment): SecureGroupHeader_OnLoad
        -- registers exactly two events, GROUP_ROSTER_UPDATE and
        -- UNIT_NAME_UPDATE, and OnEvent runs the SAME full
        -- SecureGroupHeader_Update -- i.e. a full re-sort and unit-attribute
        -- reassignment -- for either one. We handled the first and not the
        -- second, so any name resolving late ("Unknown" -> real name on zone-in,
        -- cross-realm lookups) silently shuffled unit tokens across buttons
        -- with nothing re-wiring afterwards.
        --
        -- Especially load-bearing with sortByRole: that path sets
        -- sortMethod="NAME" (see ApplyRoleSortAttributes), so the sort order is
        -- literally a function of the names this event delivers.
        --
        -- Filtered three ways, because ReapplyRosterLayout is a full re-wire
        -- (it re-fires PartyButtonsWired, hence HandleIndicators on every
        -- button) and UNIT_NAME_UPDATE fires per-unit, in bursts, for units we
        -- don't care about at all:
        --   1. unit filter -- ignore nameplates/target/etc outright;
        --   2. debounce -- coalesce a burst into one pass;
        --   3. HeaderUnitsChanged -- the header re-sorts synchronously on this
        --      event, so by the time the debounce fires we can just compare its
        --      children's unit attributes against what we last wired and do
        --      nothing at all in the overwhelmingly common case where a name
        --      resolved without changing the order.
        --
        -- Owner note: this registers on the SquizzFrames root, matching every
        -- other registration in this file. Checked that nothing else claims
        -- UNIT_NAME_UPDATE on that same owner -- Indicators registers it on the
        -- Indicators module (I:RegisterEvent) and PetFrames on its own module,
        -- so there's no CallbackHandler (owner, event) collision here.
        local function HeaderUnitsChanged()
            if not header then return false end
            local changed = false
            ForEachHeaderButton(function(button)
                if button ~= UIParent then
                    local attr = button:GetAttribute("unit")
                    if attr and attr ~= button.unit then changed = true end
                end
            end)
            return changed
        end
        local nameUpdatePending = false
        SquizzFrames:RegisterEvent("UNIT_NAME_UPDATE", function(_, unit)
            if not unit then return end
            if not (unitButtons[unit] or unit == "player"
                or unit:match("^party%d+$") or unit:match("^raid%d+$")) then
                return
            end
            if nameUpdatePending then return end
            nameUpdatePending = true
            C_Timer.After(0.1, function()
                nameUpdatePending = false
                if HeaderUnitsChanged() then
                    ReapplyRosterLayout()
                end
            end)
        end)
        -- Re-apply layout after AFK screen / cinematic / logout-return so the
        -- secure header doesn't revert to defaults while the UI was hidden.
        -- This handler ONLY resized/repositioned the container -- it never
        -- actually refreshed the statusText FontString for the unit whose
        -- flag changed, so "AFK"/"Dead"/"Offline" never updated live even
        -- though the Status Icon (a separate system in Indicators.lua) did.
        -- UpdateStatus is a plain FontString Show/Hide/SetText, not a secure
        -- attribute change, so it's safe to call even in combat.
        SquizzFrames:RegisterEvent("PLAYER_FLAGS_CHANGED", function(_, unit)
            if not InCombatLockdown() then
                OnRosterOrFlagChanged()
            end
            local button = unit and unitButtons[unit]
            if button then UpdateStatus(button) end
        end)
        -- PLAYER_ENTERING_WORLD fires once the world is loaded — both on initial
        -- login and after zoning. The secure header's children may not be shown
        -- on the very first frame after login (RegisterUnitWatch hasn't fired
        -- yet), so we re-apply the layout here to force buttons visible. This is
        -- what makes frames appear immediately on login instead of only after
        -- the first zone change.
        SquizzFrames:RegisterEvent("PLAYER_ENTERING_WORLD", function()
            if not InCombatLockdown() then
                -- Triple-refresh at increasing delays to catch the secure
                -- header's asynchronous child spawn, which can take longer on
                -- initial login than on subsequent zone changes.
                C_Timer.After(0.3, RefreshVisible)
                C_Timer.After(1.0, RefreshVisible)
                C_Timer.After(2.0, RefreshVisible)
            end
        end)

        -- Out-of-range alpha: build the initial checker now, then rebuild it
        -- whenever the set of available range checkers changes (spec/talent/
        -- equipment swaps -- see LibRangeCheck-3.0's own header example), and
        -- poll every 0.5s to apply it (no WoW event fires on plain movement).
        if RC then
            RebuildRangeChecker()
            RC.RegisterCallback(PartyFrames, RC.CHECKERS_CHANGED, RebuildRangeChecker)
            -- Re-evaluate immediately on every combat transition rather than
            -- waiting up to a full poll interval: entering and leaving combat
            -- SWITCHES WHICH CHECKER APPLIES (see RebuildRangeChecker), so
            -- the alpha computed a moment ago was produced by rules that no
            -- longer hold. This used to be a ResetRangeAlpha on combat start
            -- only -- correct when UpdateRangeAlpha then did nothing for the
            -- rest of the fight, but now it would just throw away a perfectly
            -- good reading and flash every frame to full alpha.
            --
            -- Registered on `self` (PartyFrames), NOT SquizzFrames --
            -- AceEvent/CallbackHandler keeps exactly ONE handler per (self,
            -- event) pair, and SquizzFrames:RegisterEvent("PLAYER_REGEN_
            -- DISABLED", ...) already has a handler above (auto-disabling the
            -- layout preview on combat start) -- a second SquizzFrames-scoped
            -- registration for the same event would have silently REPLACED
            -- it instead of adding a second listener.
            self:RegisterEvent("PLAYER_REGEN_DISABLED", UpdateRangeAlpha)
            self:RegisterEvent("PLAYER_REGEN_ENABLED", UpdateRangeAlpha)

            -- UNIT_IN_RANGE_UPDATE fires the instant a group member crosses
            -- Blizzard's own ~40yd range boundary -- this is what makes the
            -- fade feel immediate rather than up to a poll interval late,
            -- which matters most in combat where people are moving.
            --
            -- The 0.5s ticker below STAYS as the backbone, deliberately. The
            -- event only knows about that one fixed Blizzard boundary, not
            -- the class spell range the in-combat path actually uses -- an
            -- Evoker crossing their 25yd Emerald Blossom range produces no
            -- event at all -- and out of combat nothing fires on plain
            -- movement either. Grid2/ElvUI/DandersFrames all likewise keep
            -- both, event for responsiveness and poll for completeness.
            --
            -- The PAYLOAD IS IGNORED ENTIRELY -- both the unit token and the
            -- isInRange flag. Blizzard's API documentation declares this
            -- event SecretPayloads, so reading either is a taint risk for no
            -- benefit; it's used purely as a "something moved" ping and every
            -- button is then re-evaluated through the normal path. That's 5
            -- units plus pets, so there's nothing to gain from a narrower
            -- per-unit update.
            --
            -- Debounced to one pass per frame: the event is synchronous and
            -- per-unit, so a group crossing the boundary together (everyone
            -- running out of an ability, a party-wide teleport) delivers a
            -- burst of them in a single frame.
            local rangeEventPending = false
            self:RegisterEvent("UNIT_IN_RANGE_UPDATE", function()
                if rangeEventPending then return end
                rangeEventPending = true
                C_Timer.After(0, function()
                    rangeEventPending = false
                    UpdateRangeAlpha()
                end)
            end)

            if not rangeTicker then
                rangeTicker = C_Timer.NewTicker(0.5, UpdateRangeAlpha)
            end
        end

        -- Blizzard special-frame visibility poll (bug fix 2026-07-31): party
        -- frames stay at "HIGH" strata (see CreatePartyContainer's comment
        -- for the full nameplate-vs-Blizzard-menu history/why level-based
        -- alternatives don't work) to reliably beat nameplates, which ALSO
        -- covers Blizzard's own MEDIUM-strata full-screen panels since those
        -- never escalate strata themselves. Rather than chase an unwinnable
        -- level fight to fix that too, just fade the container out while any
        -- such panel is open. See ApplyBlizzardPanelVisibility's own comment
        -- for the UISpecialFrames + ShowUIPanel/HideUIPanel-hook combo this
        -- ended up needing (UISpecialFrames alone missed several modern
        -- panels, e.g. Talents/PlayerSpellsFrame).
        --
        -- 2026-08-01: DISABLED for the MEDIUM-strata experiment (see
        -- CreatePartyContainer's comment) -- with the container no longer
        -- elevated above Blizzard's panels, there's nothing left for this to
        -- paper over, and leaving it running only risked an unwanted fade
        -- if some panel's open/close state ever misbehaved. Neither the
        -- ticker nor the hooks are started; ApplyBlizzardPanelVisibility and
        -- openBlizzardPanels are untouched and still fully working, just
        -- unreferenced. If HIGH strata comes back, uncomment both blocks
        -- below to bring the fade back with it.
        -- if not panelVisibilityTicker then
        --     panelVisibilityTicker = C_Timer.NewTicker(0.3, ApplyBlizzardPanelVisibility)
        -- end
        -- if not blizzardPanelHooksInstalled then
        --     blizzardPanelHooksInstalled = true
        --     hooksecurefunc("ShowUIPanel", function(frame)
        --         if frame then openBlizzardPanels[frame] = true end
        --     end)
        --     hooksecurefunc("HideUIPanel", function(frame)
        --         if frame then openBlizzardPanels[frame] = nil end
        --     end)
        -- end
        partyFrame:SetAlpha(1)

        initialized = true
        SquizzFrames.partyFrame = partyFrame

        -- Only show edit frame if the user has enabled it via the checkbox
        if SquizzFrames.editMode then
            self:SetEditMode(true)
        end
    end

    if InCombatLockdown() then
        -- Defer until out of combat
        local frame = CreateFrame("Frame")
        frame:RegisterEvent("PLAYER_REGEN_ENABLED")
        frame:SetScript("OnEvent", function()
            init()
            -- Schedule RefreshVisible after init so buttons whose units exist
            -- are forced visible (RegisterUnitWatch may not have fired yet).
            C_Timer.After(0.3, RefreshVisible)
            C_Timer.After(1.0, RefreshVisible)
            frame:UnregisterEvent("PLAYER_REGEN_ENABLED")
        end)
    else
        init()
    end
end

function PartyFrames:OnDisable()
    for _, button in pairs(unitButtons) do
        button:Hide()
    end
    if partyFrame then partyFrame:Hide() end
    initialized = false
    if rangeTicker then
        rangeTicker:Cancel()
        rangeTicker = nil
        -- Nothing polls the range any more, so undo whatever dimming was
        -- last applied instead of freezing it in place. (Previously this was
        -- only reachable from the combat-start handler, which no longer
        -- needs it now that combat has a real range check of its own.)
        ResetRangeAlpha()
    end
    if panelVisibilityTicker then
        panelVisibilityTicker:Cancel()
        panelVisibilityTicker = nil
    end
end

-----------------------------------------------------------------------
-- Event handlers
-----------------------------------------------------------------------

function PartyFrames:OnUnitEvent(unit)
    if not unit then return end
    local button = unitButtons[unit]
    if button then
        UpdateButtonAll(button)
    end
end

-----------------------------------------------------------------------
-- Out-of-range alpha
-----------------------------------------------------------------------
-- profile.appearance.general.outOfRangeAlpha existed in defaults and the
-- options panel (a working slider that reads/writes the DB value) but
-- nothing anywhere in the addon ever loaded LibRangeCheck-3.0 or applied the
-- result to a button -- the whole feature was dead on arrival. There's no
-- WoW event for "a unit's distance changed" (movement alone doesn't fire
-- anything), so this needs a lightweight poll like every other range-check
-- implementation uses; 0.5s matches the common convention (Grid2/ElvUI etc)
-- of being responsive without re-running spell/item range checks needlessly
-- often.
--
-- rc:GetFriendMaxChecker(40) (falling back to GetFriendMinChecker if no
-- 40-yard-capable checker is available, e.g. between spell ranges for the
-- player's current spec) returns a checker(unit) function that answers "is
-- this unit within ~40 yards" -- 40 matches the range most heal/buff spells
-- and Blizzard's own default party frame dimming use, so it reads as a
-- generic "in interact range" signal rather than tied to one specific spell.
--
-- IN COMBAT (implemented 2026-08-13; this used to bail out entirely).
--
-- The original failure: RebuildRangeChecker asked for a checker WITHOUT
-- LibRangeCheck's `inCombat` flag, so the returned checker was built from the
-- full list -- items and CheckInteractDistance included. Both of those are
-- gated behind LibRangeCheck's own InCombatLockdownRestriction (which is
-- true for any non-attackable unit, i.e. every party member) and return nil
-- in combat, and the nil fallback here then ran CheckInteractDistance
-- directly, which is restricted too. Everything read as "out of range" and
-- every frame dimmed the instant combat started. Pausing was the stopgap.
--
-- The fix is two separate checkers plus a secret-safe last resort:
--
--  1. OUT OF COMBAT -- unchanged: the full checker list, item/interact
--     checkers and all, with the CheckInteractDistance cross-faction
--     fallback below.
--
--  2. IN COMBAT, living unit, class has a friendly spell -- LibRangeCheck's
--     combat-safe list (the `inCombat` argument), which is built from SPELL
--     checkers only. Those call C_Spell.IsSpellInRange, which is NOT combat
--     restricted and (verified against Blizzard's own API documentation)
--     carries no SecretReturns flag -- it hands back a plain readable
--     boolean even mid-encounter. This is the accurate path: it tracks the
--     player's actual heal range, including talent modifications and shorter
--     ranges like Evoker's 25yd.
--
--     Note LibRangeCheck's spell checkers return true or NIL -- never false
--     (checkers_Spell maps IsSpellInRange's false to nil). Nil is therefore
--     read as out of range, which is how LibRangeCheck itself interprets it
--     when bisecting ranges.
--
--  3. IN COMBAT otherwise -- Warrior/Hunter/Death Knight/Demon Hunter have
--     no entry in LibRangeCheck's FriendSpells at all, so (2) resolves to
--     nil for them; dead units also answer nil to a heal-range check
--     regardless of distance; and CROSS-FACTION group members answer nil to
--     any friendly spell check in the open world (see IsCrossFactionUnit --
--     the same limitation the out-of-combat path handles with
--     CheckInteractDistance, which is itself combat-restricted and so no use
--     here). All three fall back to UnitInRange (Blizzard's own ~40yd
--     group-member check, which works in combat and cross-faction alike)
--     applied via SetAlphaFromBoolean -- see ApplyRangeAlphaSecret below.
local rangeChecker
local rangeCheckerCombat
function RebuildRangeChecker()
    if not RC then
        rangeChecker, rangeCheckerCombat = nil, nil
        return
    end
    rangeChecker = RC:GetFriendMaxChecker(40) or RC:GetFriendMinChecker(40)
    -- nil for the four classes with no friendly range spell -- expected, and
    -- handled by the UnitInRange path rather than treated as an error.
    rangeCheckerCombat = RC:GetFriendMaxChecker(40, true) or RC:GetFriendMinChecker(40, true)
end

-- Forces every non-player frame back to full alpha -- called on combat start
-- so nothing is left dimmed from a stale pre-combat read for the whole fight
-- (UpdateRangeAlpha stops touching alpha entirely once InCombatLockdown()).
-- Pet frames participate in range fading too (2026-08-09). They're not
-- header children, so they're pulled in through the same IterateButtons
-- accessor ClickCasting.lua's CollectButtons uses -- rather than duplicating
-- the LibRangeCheck setup, ticker and combat handling over in PetFrames.lua.
local function ForEachRangeButton(func)
    for unit, button in pairs(unitButtons) do
        func(unit, button)
    end
    local PetFrames = SquizzFrames.modules and SquizzFrames.modules["PetFrames"]
    if PetFrames and PetFrames.IterateButtons then
        PetFrames:IterateButtons(function(button)
            local unit = button and (button.unit or button.petUnit)
            if unit then func(unit, button) end
        end)
    end
end

function ResetRangeAlpha()
    ForEachRangeButton(function(unit, button)
        if UnitExists(unit) then
            button:SetAlpha(1)
        end
    end)
end

-- Secret-safe "is this the player's own frame?".
--
-- UnitIsUnit is declared SecretWhenUnitComparisonRestricted in Blizzard's API
-- documentation: on an addon-restricted map (rated PvP) it returns a SECRET
-- boolean, and `if <secret>` raises "attempt to perform boolean test on a
-- secret boolean value" rather than simply being falsy. That was unreachable
-- while UpdateRangeAlpha bailed out of combat entirely; now that it runs
-- in combat, this call sits directly in the hot path of exactly the content
-- where the restriction applies.
--
-- Its fallback to plain token equality covers the literal "player" token. It
-- misses the vehicle-alias case the caller's comment mentions, which just
-- means the player's own frame gets range-checked like anyone else's -- and
-- a unit is never out of range of itself, so it reads as full alpha anyway.
--
-- Lives in Utils.lua as of 2026-08-13 (the guard details are documented there),
-- when F.GetRoleKey needed the same test for its solo/spec-role fallback. Kept
-- as a local alias so the call sites below read unchanged.
local IsPlayerUnit = F.IsPlayerUnit

-- Apply range alpha from a SECRET boolean (UnitInRange's return -- see
-- RebuildRangeChecker case 3). SetAlphaFromBoolean resolves the secret
-- C-side and picks one of the two alphas without the value ever being
-- readable here; `not inRange` or `inRange and a or b` on a secret raises
-- "attempt to perform boolean test on a secret boolean value" instead.
--
-- Verified against Blizzard's API documentation: SetAlphaFromBoolean is
-- declared SecretArguments = "AllowedWhenTainted", i.e. explicitly callable
-- with secret arguments from addon code. It does mark the frame's Alpha as a
-- secret aspect afterwards, so button:GetAlpha() stops being readable --
-- harmless here, nothing in this addon reads a button's alpha back, and a
-- later plain SetAlpha still overwrites it normally.
local function ApplyRangeAlphaSecret(button, inRange, inAlpha, outAlpha)
    if button.SetAlphaFromBoolean then
        button:SetAlphaFromBoolean(inRange, inAlpha, outAlpha)
    else
        -- No secret-aware setter (shouldn't happen on 12.1, but the whole
        -- point of this path is that we can't inspect the value ourselves) --
        -- full alpha is the safe default: never dim on a guess.
        button:SetAlpha(inAlpha)
    end
end

-- Is this group member of the OPPOSITE faction?
--
-- Every LibRangeCheck friendly checker is built on a friendly spell or item
-- range test, and Blizzard's targeting-validity check underneath those doesn't
-- treat an opposite-faction unit as a valid friendly target in the open world
-- even while grouped. So they answer "out of range" at any distance, and the
-- frame dims permanently no matter how close the player stands. Instances are
-- the exception -- cross-faction data is fully shared there and the same
-- checkers behave normally, which is why this only ever shows up outdoors.
--
-- UnitFactionGroup is safe to read: unlike its neighbours in the Unit API it
-- carries NO SecretWhenUnitIdentityRestricted flag in Blizzard's 12.1
-- documentation (checked, not assumed -- UnitFullName immediately below it in
-- the same file does carry one), so this is a plain string comparison with no
-- secret-boolean trap.
--
-- "Neutral" (Pandaren who haven't picked, and some NPC-ish units) never counts
-- as opposite: it isn't the case this exists for, and treating it as opposite
-- would silently route those units onto the coarser fallback.
local function IsCrossFactionUnit(unit)
    local mine = UnitFactionGroup("player")
    local theirs = UnitFactionGroup(unit)
    if not mine or not theirs then return false end
    if mine == "Neutral" or theirs == "Neutral" then return false end
    return mine ~= theirs
end

function UpdateRangeAlpha()
    if not RC or not rangeChecker then return end
    local inCombat = InCombatLockdown()
    -- UnitInRange only answers meaningfully for GROUP members (and their
    -- pets); ungrouped it reports not-checked, which would read as "out of
    -- range" and dim a solo player's own pet frame for no reason. The spell
    -- checkers have no such restriction, but there's nobody but the player
    -- and their pet to check when solo anyway.
    local grouped = IsInGroup()
    local prof = GetProfile()
    local outOfRangeAlpha = (prof and prof.appearance and prof.appearance.general and prof.appearance.general.outOfRangeAlpha) or 0.3
    ForEachRangeButton(function(unit, button)
        if UnitExists(unit) then
            -- Never dim the player's own frame -- you're never "out of range"
            -- of yourself. IsPlayerUnit catches both the literal "player"
            -- unit and any vehicle-mapped alias that still refers to the
            -- player, without tripping over a secret comparison result.
            if IsPlayerUnit(unit) then
                button:SetAlpha(1)
            elseif inCombat then
                -- See RebuildRangeChecker's comment for the three cases.
                -- Dead units are routed to UnitInRange too: a heal-range
                -- check on a corpse answers nil whatever the distance, which
                -- would otherwise dim every dead party member on sight.
                if rangeCheckerCombat and not UnitIsDeadOrGhost(unit)
                  and not IsCrossFactionUnit(unit) then
                    -- true (in range) or nil (out of range) -- never false.
                    button:SetAlpha(rangeCheckerCombat(unit) and 1 or outOfRangeAlpha)
                elseif grouped then
                    ApplyRangeAlphaSecret(button, UnitInRange(unit), 1, outOfRangeAlpha)
                else
                    button:SetAlpha(1)
                end
            else
                local inRange = rangeChecker(unit)
                -- Cross-faction party members in the OPEN WORLD (confirmed
                -- via user report -- works fine in instances, which is the
                -- key clue): GetFriendMaxChecker's checkers are all built on
                -- friendly-spell/item range checks (IsSpellInRange/
                -- IsItemInRange), and Blizzard's own targeting-validity check
                -- underneath those apparently doesn't treat an opposite-
                -- faction unit as a valid "friendly" target outside of
                -- instanced content even while grouped -- every one of those
                -- checkers then returns nil/false regardless of actual
                -- distance, reading as permanently "out of range" no matter
                -- how close they stand. Inside instances Blizzard fully
                -- shares cross-faction group data, so the same checkers work
                -- normally there, matching the reported "fine in instances"
                -- half of the symptom exactly.
                --
                -- CheckInteractDistance(unit, 4) (28-yard "follow" distance)
                -- doesn't go through spell/item targeting validity at all --
                -- just squad/interact eligibility, which cross-faction party
                -- members DO have -- so it stays reliable exactly where the
                -- spell-based checkers break down.
                --
                -- Consulted whenever the primary checker doesn't say yes, not
                -- just when it returns nil. That nil-only test (until
                -- 2026-08-14) assumed the friendly checkers answer nil for a
                -- cross-faction unit -- some of them answer a plain FALSE
                -- instead, which skipped the fallback entirely and left the
                -- frame dimmed at any distance.
                --
                -- Widening it costs nothing in accuracy: interact distance is
                -- 28 yards against the checker's 40, so a unit genuinely out
                -- of range fails both and still dims. This can only ever
                -- rescue someone standing closer than 28 yards.
                if not inRange then
                    inRange = CheckInteractDistance(unit, 4)
                end
                button:SetAlpha(inRange and 1 or outOfRangeAlpha)
            end
        end
    end)
end

-- Fades the party frame container out while any Blizzard "special frame" is
-- open (Character, Talents/PlayerSpells, Spellbook, Collections, Auction
-- House, etc) -- see CreatePartyContainer's comment for why this exists
-- (party frames stay at HIGH strata to reliably beat nameplates, which also
-- covers these MEDIUM-strata Blizzard panels; this is how that side effect
-- gets resolved instead). Uses SetAlpha, not Show/Hide -- mirrors
-- UpdateRangeAlpha's own convention just above, and avoids fighting with
-- the several OTHER places that already call partyFrame:Show()/:Hide() for
-- unrelated reasons (roster changes, Designer preview, OnDisable, etc) --
-- an alpha toggle layers on top of whatever those decide without needing to
-- know about them.
-- UISpecialFrames is Blizzard's own array of GLOBAL FRAME NAME strings --
-- every ESC-closable panel registers itself into it, so this covers new/
-- addon-added panels too without maintaining a hardcoded list. Re-scanned
-- fresh every poll (not cached) since entries can be appended at any time
-- (other addons' panels, lazily-loaded Blizzard panels, etc).
--
-- UISpecialFrames alone isn't complete, though: PlayerSpellsFrame (Talents/
-- Spellbook/Specialization) never registers there (confirmed by reading
-- Blizzard_PlayerSpellsFrame's actual source -- no UISpecialFrames reference
-- anywhere in it), and it's not the only one -- DeathRecapFrame,
-- EditModeManagerFrame, EncounterJournal, and ChromieTimeFrame's own source
-- are ALSO silent on UISpecialFrames (checked directly). UISpecialFrames
-- only covers frames that show/hide themselves directly; anything using
-- Blizzard's modern docked-panel system (UIPanelWindows -- Character,
-- Collections, Encounter Journal, Talents, Death Recap, ~55 panels total)
-- goes through that system's API instead and was never a safe bet to assume
-- present in UISpecialFrames case-by-case.
--
-- First attempt at covering UIPanelWindows generically: poll every frame
-- name in that table via :IsShown(). Regressed -- the container got
-- permanently stuck faded to alpha 0 even after closing every visible
-- panel, because at least one entry (never isolated which) apparently
-- stays IsShown()==true indefinitely; UIPanelWindows entries are positioned/
-- animated by the manager, not a simple show=open/hide=closed contract.
--
-- Second attempt (current): rather than polling frame state, hook the
-- manager's own choke point. EVERY UIPanelWindows-registered panel opens/
-- closes by calling the global ShowUIPanel(frame)/HideUIPanel(frame)
-- functions (confirmed via Blizzard_UIParentPanelManager/Shared/
-- UIParentPanelManager.lua -- both early-return on a redundant call via
-- `if frame:IsShown() then return end` / `if not frame:IsShown() then
-- return end`, so a hooksecurefunc on them fires once per real open/close,
-- not once per call). openBlizzardPanels below is keyed by frame identity
-- and updated by those hooks -- inherently self-correcting (adding an
-- already-present key or removing an absent one is a no-op), so it can't
-- drift stuck-open the way polling an unreliable IsShown() did. This covers
-- every current AND future UIPanelWindows panel with no name list at all;
-- UISpecialFrames is kept alongside it for the (older/simpler) panels that
-- show/hide themselves directly without going through ShowUIPanel.
function ApplyBlizzardPanelVisibility()
    if not partyFrame then return end
    local anyOpen = false
    for _, name in ipairs(UISpecialFrames) do
        local frame = _G[name]
        if frame and frame.IsShown and frame:IsShown() then
            anyOpen = true
            break
        end
    end
    if not anyOpen and next(openBlizzardPanels) then
        anyOpen = true
    end
    partyFrame:SetAlpha(anyOpen and 0 or 1)
end

-- Party <-> raid transition. Bug fix (2026-08-07, user-reported priority):
-- this used to wrap its whole body in `if not InCombatLockdown()` with NO
-- else and NO retry, so a transition that happened in combat (converting
-- party -> raid mid-pull is completely routine) was dropped PERMANENTLY:
-- ApplyLayout was never called, so its own PLAYER_REGEN_ENABLED retry never
-- armed either, and GROUP_ROSTER_UPDATE's combat-end catch-up deliberately
-- doesn't call ApplyLayout. The header kept party attributes (maxColumns=1/
-- showParty=true/showRaid=false) and party's saved anchor for the rest of
-- the session, while indicators DID eventually rebuild off the raid list via
-- the roster retry -- i.e. raid indicators on a party-shaped header, until a
-- /reload.
--
-- ApplyLayout/WireUpAllButtons/SizeContainerToButtons all self-guard and
-- self-retry on PLAYER_REGEN_ENABLED, so this calls them unconditionally
-- and lets each defer itself if needed. UpdateAllButtons needs no guard --
-- it only writes StatusBar values and FontString text, none of which are
-- protected -- so it stays correct (and useful) even mid-combat.
function PartyFrames:OnGroupTypeChanged()
    -- A real party<->raid transition always wins over an edit-mode override.
    -- Keeping the override here would mean the frames ignored the mode change
    -- that just happened (e.g. pinned to "main" while you actually zoned into
    -- a raid), which is the one thing this module is most careful never to
    -- do. Cleared BEFORE ApplyLayout so the relayout below already reads the
    -- real mode's layout.
    editLayoutOverride = nil

    ApplyLayout()
    WireUpAllButtons()
    UpdateAllButtons()
    SizeContainerToButtons()
    PartyFrames:RefreshEditModeToggle()
    -- SecureGroupHeaderTemplate creates children asynchronously. Re-wire
    -- after a short delay so newly-spawned buttons (e.g. party member
    -- just joined) get their bar sizes and initial fill.
    C_Timer.After(0.5, function()
        WireUpAllButtons()
        UpdateAllButtons()
        SizeContainerToButtons()
    end)
end

function PartyFrames:OnLayoutChanged()
    -- Keep the layout preview (if showing) in sync with slider/dropdown
    -- changes made while it's up -- e.g. dragging the Width slider should
    -- visibly resize the mock grid immediately, not just the (currently
    -- hidden) real frames. Uses self:IsPreviewActive()/RefreshPreviewMode()
    -- (method dispatch, resolved at call time) rather than the bare
    -- `previewActive` local -- that local is declared further down in this
    -- file, after this function, so referencing it directly here would
    -- silently resolve to a nonexistent global instead of the real value.
    if self:IsPreviewActive() then
        self:RefreshPreviewMode()
    end
    -- Unconditional for the same reason as OnGroupTypeChanged above: each
    -- callee self-guards and self-retries, so a settings change made during
    -- combat now actually lands (once combat ends) instead of being dropped.
    ApplyLayout()
    UpdateAllButtons()
    SizeContainerToButtons()
    -- ApplyLayout sets header attributes which triggers the secure
    -- header's async configureChildren. That reset resets child sizes to
    -- template defaults (100×40). Defer WireUpAllButtons by a short delay
    -- so resolveChildren re-applies the correct size AFTER the header has
    -- finished reconfiguring.
    C_Timer.After(0.2, function()
        WireUpAllButtons()
        UpdateAllButtons()
        SizeContainerToButtons()
    end)
end

function PartyFrames:OnProfileChanged()
    if not InCombatLockdown() then
        ApplyLayout()
        WireUpAllButtons()
        UpdateAllButtons()
    end
end


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
    mover:SetFrameStrata("HIGH")
    mover:SetFrameLevel(50)
    mover:EnableMouse(true)
    mover:SetMovable(true)
    mover:RegisterForDrag("LeftButton")
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

    mover:SetScript("OnDragStart", function(self)
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

        self:SetScript("OnUpdate", function()
            local cx, cy = GetCursorPosition()
            local ps = UIParent:GetEffectiveScale()
            cx = cx / ps
            cy = cy / ps
            local ox, oy = ScreenAnchorCoords(anchorPoint)
            dragOffsetX = (cx + cursorOffX) - ox
            dragOffsetY = (cy + cursorOffY) - oy
            LayoutPreviewButtons(previewCount, previewIsRaidTab, dragOffsetX, dragOffsetY)
            PartyFrames:RefreshPreviewMoverBounds()
        end)
    end)

    mover:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        local prof = GetProfile()
        local layout = prof and prof.layout and (previewIsRaidTab and prof.layout.raid or prof.layout.main)
        if layout then
            layout.anchorX = dragOffsetX
            layout.anchorY = dragOffsetY
        end
        LayoutPreviewButtons(previewCount, previewIsRaidTab)
        PartyFrames:RefreshPreviewMoverBounds()
    end)

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
        if partyFrame then partyFrame:Show() end
        return
    end

    if previewRaid == nil then previewRaid = IsInRaid() end
    previewIsRaidTab = previewRaid

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

-- Public accessors for other modules (Indicators, ClickCasting) to iterate
-- buttons and look up by unit without reaching into private state.
function PartyFrames:IterateButtons(func)
    for _, button in pairs(unitButtons) do
        func(button)
    end
end

function PartyFrames.FindButtonByUnit(unit)
    return unitButtons[unit]
end

-- Exposes the private GetBarTexture local above so PetFrames.lua doesn't
-- need to duplicate the LSM statusbar-texture resolution logic.
function PartyFrames.GetBarTexture()
    return GetBarTexture()
end

-- TEMPORARY diagnostic (/sfrosterdiag) -- chasing a user report that a Delve
-- NPC companion (Valeera) leaves and instantly rejoins the group on player
-- death, and her button never returns, not even after combat ends.
--
-- Three different failures produce that same symptom, and they need opposite
-- fixes, so guessing between them is worthless. This tells them apart:
--
--   1. No header child holds her unit at all  -> the SECURE HEADER never
--      reconfigured; the problem is Blizzard's configureChildren or our
--      attributes, and nothing we do to visibility will help.
--   2. A child holds her unit but is HIDDEN   -> RegisterUnitWatch didn't
--      re-show it; a force-show on the roster path is the fix.
--   3. A child holds her unit and IS SHOWN    -> it is being rendered
--      somewhere you can't see: sized to nothing, alpha 0, or positioned
--      outside the container.
--
-- Also prints button.unit alongside the ATTRIBUTE, because the force-show loop
-- in RefreshVisible keys off button.unit (our own wiring) while the header
-- assigns the attribute -- if those disagree, wiring is the fault.
-- Remove once the real cause is confirmed.
SLASH_SQUIZZROSTERDIAG1 = "/sfrosterdiag"
SlashCmdList["SQUIZZROSTERDIAG"] = function()
    local P = "|cff33cc99[SquizzFrames]|r "
    if not header then print(P .. "roster diag: no header") return end

    print(P .. ("roster diag -- inCombat=%s inRaid=%s GetNumGroupMembers=%d")
        :format(tostring(InCombatLockdown()), tostring(IsInRaid()), GetNumGroupMembers() or 0))

    -- What the game says the group is, independent of any frame.
    local roster = {}
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) then
            roster[#roster + 1] = ("%s=%s%s"):format(u, tostring(UnitName(u)),
                UnitIsPlayer(u) and "" or " (NPC)")
        end
    end
    print(P .. "game roster: " .. (#roster > 0 and table.concat(roster, ", ") or "(solo)"))

    local shown, hidden, unitless = 0, 0, 0
    -- Walks whichever headers are live -- eight subgroup headers in a raid --
    -- and labels each row with the header it came from, since "child 2" means
    -- nothing on its own once there are eight of them.
    for _, h in ipairs({unpack(ActiveHeaders())}) do
        local hName = (h:GetName() or "?"):gsub("^SquizzFrames", "")
        for i, button in ipairs(h) do
            local attrUnit = button and button.GetAttribute and button:GetAttribute("unit")
            local wired = button and button.unit
            if attrUnit then
                local exists = UnitExists(attrUnit)
                local isShown = button:IsShown()
                if isShown then shown = shown + 1 else hidden = hidden + 1 end
                -- Only print interesting rows: anything real, or any disagreement.
                if exists or isShown or wired ~= attrUnit then
                    print(("   %s[%d] attr=%s wired=%s exists=%s shown=%s alpha=%.2f size=%dx%d")
                        :format(hName, i, tostring(attrUnit), tostring(wired), tostring(exists),
                            tostring(isShown), button:GetAlpha() or 0,
                            math.floor(button:GetWidth() or 0), math.floor(button:GetHeight() or 0)))
                end
            else
                unitless = unitless + 1
            end
        end
    end
    print(P .. ("children: %d shown, %d hidden, %d with no unit attribute")
        :format(shown, hidden, unitless))
end
