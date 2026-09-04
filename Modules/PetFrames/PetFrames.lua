--[[ SquizzFrames PetFrames Module (Phase 1)
    Party/raid pet frames. Manually creates one button per possible pet slot
    ("pet", "partypet1".."partypet4", "raidpet1".."raidpet40") and positions
    every button with plain SetPoint calls -- Attached mode glues each pet to
    a side of its owner's existing unit button; Floating mode stacks all
    currently-visible pets inside a standalone, independently draggable
    container. Deliberately does NOT use Blizzard's SecureGroupPetHeaderTemplate:
    that header's own internal flow layout has no concept of "this pet
    belongs next to owner-button-N", so Attached mode would have to override
    its positioning anyway -- see the approved design plan for the full
    reasoning. Click-casting, the indicator/aura system, and per-pet custom
    appearance are all deliberately out of scope for this phase. ]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F
---@class AceModule
local PetFrames = SquizzFrames:NewModule("PetFrames", "AceEvent-3.0")

-- Local state
local petButtons = {}      -- [petUnit] = button
local petGroupFrame        -- floating-mode container
local playerPetFrame       -- standalone player's-own-pet container
local initialized = false
local applyingPetLayout = false
local applyPetLayoutRetryFrame

-- Every possible pet slot, created once out of combat. Pet-slot unit tokens
-- are stable (e.g. "partypet2" always means "party2's pet", regardless of
-- who currently occupies party2), so the "unit" attribute only needs to be
-- set ONCE at creation time -- unlike the main party header, nothing here
-- ever needs to re-derive tokens on roster change.
local PET_SLOTS = { "pet" }
for i = 1, 4 do PET_SLOTS[#PET_SLOTS + 1] = "partypet" .. i end
for i = 1, 40 do PET_SLOTS[#PET_SLOTS + 1] = "raidpet" .. i end

-- Which side of the PET touches the configured side of the OWNER, e.g.
-- anchorSide == "RIGHT" means the pet sits to the right of its owner, so the
-- pet's own LEFT edge is what anchors to the owner's RIGHT edge.
local OPPOSITE_SIDE = { LEFT = "RIGHT", RIGHT = "LEFT", TOP = "BOTTOM", BOTTOM = "TOP" }

local function GetProfile()
    return SquizzFrames.db and SquizzFrames.db.profile
end

-- Party and raid have independent pet-frame settings, mirroring
-- PartyFrames.lua's own GetActiveLayout/profile.layout.main+.raid split.
-- Named "main" (not "party") specifically so this reads as a one-line copy
-- of that existing function.
local function GetActivePetLayout(prof)
    prof = prof or GetProfile()
    if not prof or not prof.petFrames then return nil end
    if IsInRaid() then
        return prof.petFrames.raid
    end
    return prof.petFrames.main
end

-- The player's OWN pet, on its own standalone frame. Deliberately NOT
-- group-scoped (no main/raid split): one position, honoured solo, in a party
-- and in a raid alike -- the whole point is a pet frame that doesn't move when
-- your group does. See Defaults/PetFrames_Defaults.lua's `player` table.
local function GetPlayerPetLayout(prof)
    prof = prof or GetProfile()
    return prof and prof.petFrames and prof.petFrames.player
end

local function PlayerPetFrameEnabled()
    local layout = GetPlayerPetLayout()
    return (layout and layout.enabled) == true
end

-- Which "raidpetN" token is the player's own pet, or nil when not in a raid /
-- not found. Resolved by GUID rather than UnitIsUnit: that call is on the 12.1
-- secret-value list (already confirmed to return secrets on rated-PvP maps),
-- and a secret here would silently fail the equality test and let the pet draw
-- twice -- exactly the bug this exists to prevent. UnitGUID on a raid token is
-- a plain string.
local function GetOwnRaidPetSlot()
    if not IsInRaid() then return nil end
    local mine = UnitGUID("player")
    if type(mine) ~= "string" then return nil end
    for i = 1, 40 do
        if UnitGUID("raid" .. i) == mine then return "raidpet" .. i end
    end
    return nil
end

-- The pet button size to actually use.
--
-- matchOwnerWidth/matchOwnerHeight take the OWNER frame's dimension instead of
-- the pet's own slider, independently of each other. Read from the party
-- layout rather than measured off a live owner button: ApplyPetLayout runs
-- during roster syncs when a given owner button may not exist or may not have
-- been sized yet, and every pet is meant to share one size anyway (they all
-- have same-sized owners).
--
-- Deliberately ignored in FLOATING mode -- that group is detached from the
-- party frames entirely, so there is no owner alongside it for the size to
-- read as "matching". The options panel only offers the checkboxes in attached
-- mode for the same reason.
--
-- Mirrors GetActivePetLayout's own party/raid split so the two can't disagree
-- about which context is live.
local function ResolvePetSize(layout, prof)
    local w = layout.width or 60
    local h = layout.height or 24
    local wantW = layout.matchOwnerWidth and layout.mode ~= "floating"
    local wantH = layout.matchOwnerHeight and layout.mode ~= "floating"
    if not wantW and not wantH then
        return w, h
    end
    prof = prof or GetProfile()
    local partyLayout = prof and prof.layout and (IsInRaid() and prof.layout.raid or prof.layout.main)
    if not partyLayout then return w, h end
    if wantW then w = partyLayout.width or w end
    if wantH then h = partyLayout.height or h end
    return w, h
end

-- "pet" -> "player", "partypetN" -> "partyN", "raidpetN" -> "raidN".
local function GetOwnerUnitForPet(petUnit)
    if petUnit == "pet" then return "player" end
    local prefix, idx = petUnit:match("^(%a-)pet(%d+)$")
    if prefix and idx then
        return prefix .. idx
    end
    return nil
end

-- Reused scratch table -- the pet slots relevant to the CURRENT group mode
-- (raid pets while in a raid, player+party pets otherwise). Rebuilt on every
-- call rather than cached across mode switches, matching WireUpAllButtons'
-- own wipe-and-rebuild convention.
local relevantSlots = {}
local function GetRelevantPetSlots()
    wipe(relevantSlots)
    local standalone = PlayerPetFrameEnabled()
    if IsInRaid() then
        -- Your own pet has TWO valid tokens in a raid -- "pet" and the
        -- "raidpetN" for your own raid index -- so with the standalone frame
        -- on, the group path must drop yours or the same creature draws
        -- twice. Solo/party needs no equivalent: party tokens exclude you, so
        -- "pet" is already the only token for your own pet there.
        local mine = standalone and GetOwnRaidPetSlot() or nil
        for i = 1, 40 do
            local slot = "raidpet" .. i
            if slot ~= mine then relevantSlots[#relevantSlots + 1] = slot end
        end
    else
        if not standalone then relevantSlots[#relevantSlots + 1] = "pet" end
        for i = 1, 4 do relevantSlots[#relevantSlots + 1] = "partypet" .. i end
    end
    return relevantSlots
end

-----------------------------------------------------------------------
-- Button update functions (health/power/name)
-----------------------------------------------------------------------

-- Aggro (blink) + Aggro (border) for one pet button. Pet buttons are outside
-- BuiltIn_Update's eventMap dispatch, so nothing re-runs these for them --
-- exactly the gap the target-highlight fix further down closed. Called from
-- UpdatePetButton (so they refresh alongside everything else) and from
-- UNIT_THREAT_SITUATION_UPDATE, which is the event that actually matters.
local function RefreshPetAggro(button)
    local BU = SquizzFrames.modules and SquizzFrames.modules["BuiltIn_Update"]
    if not BU then return end
    if BU.CheckAggroBlink then BU.CheckAggroBlink(button) end
    if BU.CheckAggroBorder then BU.CheckAggroBorder(button) end
end

local function UpdatePetButton(button)
    if not button or not button.petUnit then return end
    local unit = button.petUnit
    if not UnitExists(unit) then return end

    -- Before the dead/disconnected early-out below: a dead pet reads as no
    -- threat, which is precisely when these need to be cleared.
    RefreshPetAggro(button)

    if button.nameText then
        -- Passed straight through, no `or ""` (2026-08-07): SetText handles
        -- both nil (clears) and 12.1 secret values natively at C level,
        -- whereas `UnitName(unit) or ""` performs a Lua truthiness test on
        -- a potentially-secret value, which is exactly the pattern that
        -- throws once identity restrictions apply.
        button.nameText:SetText(UnitName(unit))
    end

    local isConnected = UnitIsConnected(unit)
    if not isConnected or UnitIsDead(unit) or UnitIsGhost(unit) then
        if button.healthBar then
            button.healthBar:SetMinMaxValues(0, 1)
            button.healthBar:SetValue(0)
        end
        if button.powerBar then
            button.powerBar:SetMinMaxValues(0, 1)
            button.powerBar:SetValue(0)
            button.powerBar:Hide()
        end
        return
    end

    local PartyFrames = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    local barTexture = (PartyFrames and PartyFrames.GetBarTexture and PartyFrames.GetBarTexture())
        or [[Interface\TargetingFrame\UI-StatusBar]]

    -- Health bar: StatusBar handles secret values at C level, same as the
    -- main UnitButton's UpdateHealth. Pet Health Bar Color (2026-08-05):
    -- owner_class_color (colors the pet's bar using ITS OWNER's class --
    -- pets have no class of their own) vs. custom_color, read from
    -- profile.appearance.petHealthBar -- a dedicated setting, no longer
    -- reusing the main frame's healthBar.fullColor.
    if button.healthBar then
        button.healthBar:SetMinMaxValues(0, UnitHealthMax(unit) or 1)
        button.healthBar:SetValue(UnitHealth(unit) or 0)
        button.healthBar:SetStatusBarTexture(barTexture)

        local prof = GetProfile()
        local col = prof and prof.appearance and prof.appearance.petHealthBar and prof.appearance.petHealthBar.fullColor
        local r, g, b = 0.2, 0.8, 0.2
        if col and col[1] == "owner_class_color" then
            local ownerUnit = GetOwnerUnitForPet(unit)
            local cc = ownerUnit and F.GetClassColor(ownerUnit)
            if cc then r, g, b = cc.r, cc.g, cc.b end
        elseif col and col[1] == "custom_color" then
            r, g, b = col[2] or 0.2, col[3] or 0.8, col[4] or 0.2
        end
        button.healthBar:SetStatusBarColor(r, g, b, 1)
    end

    -- Power bar: class_color has no meaning for a pet, so only custom_color
    -- vs. Blizzard's stock per-power-type color apply here (matches
    -- UpdatePower's own custom_color/else split, minus the class_color leg).
    if button.powerBar then
        button.powerBar:SetMinMaxValues(0, UnitPowerMax(unit) or 1)
        button.powerBar:SetValue(UnitPower(unit) or 0)
        button.powerBar:SetStatusBarTexture(barTexture)
        button.powerBar:Show()

        local prof = GetProfile()
        local col = prof and prof.appearance and prof.appearance.powerBar and prof.appearance.powerBar.powerColor
        if col and col[1] == "custom_color" then
            button.powerBar:SetStatusBarColor(col[2] or 1, col[3] or 1, col[4] or 1, 0.8)
        else
            local colors = F.GetPowerColor(unit)
            button.powerBar:SetStatusBarColor(colors.r, colors.g, colors.b, 0.8)
        end
    end
end

local function UpdateAllPetButtons()
    for _, button in pairs(petButtons) do
        if button.petUnit and UnitExists(button.petUnit) then
            UpdatePetButton(button)
        end
    end
end

-----------------------------------------------------------------------
-- Frame creation
-----------------------------------------------------------------------

-- One-time, out-of-combat-only creation of every possible pet slot's
-- button. Each button's "unit" attribute is set exactly once here (pet slot
-- tokens are stable, see PET_SLOTS' comment) -- nothing else in this file
-- ever calls SetAttribute("unit", ...) again.
local function CreatePetButtons()
    if next(petButtons) then return end
    for _, slot in ipairs(PET_SLOTS) do
        local button = CreateFrame("Button", "SquizzFramesPetButton" .. slot, UIParent, "SquizzFramesPetButtonTemplate")
        button:SetAttribute("unit", slot)
        button.petUnit = slot
        -- Also mirrored onto the generic .unit field (not just .petUnit) --
        -- BuiltIn_Update.lua's CheckTargetHighlight/CheckHoverHighlight
        -- (reused as-is for pet hover/target borders, see PetButton.lua)
        -- read button.unit first, falling back to the secure attribute.
        button.unit = slot
        -- Register for clicks so click-casting attributes (type1/type2/...)
        -- can actually fire. Without this a Button only responds to
        -- LeftButtonUp, so every right/middle/extra-button binding -- and
        -- every modifier variant -- silently did nothing on pet frames while
        -- working fine on party frames (bug fix 2026-08-09, user report:
        -- "the pet frames are not honoring the click castings").
        --
        -- PartyFrames.lua does the same on every unit button in WireUpButton;
        -- pet buttons aren't secure-header children, so nothing was doing it
        -- for them. Must happen out of combat -- CreatePetButtons is only
        -- called from the combat-guarded init path, same as the party side.
        button:RegisterForClicks("AnyUp")
        RegisterUnitWatch(button)
        -- Safe fallback anchor so the button is never anchor-less before the
        -- first real ApplyPetLayout pass positions it for real.
        button:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        petButtons[slot] = button
    end
end

-- Standalone Floating-mode container. Near-verbatim copy of PartyFrames.lua's
-- CreatePartyContainer -- plain Frame/BackdropTemplate, flat MEDIUM strata,
-- CENTER->CENTER to UIParent via its own saved anchorX/anchorY, non-secure
-- drag mover. Pet buttons are NEVER reparented under this frame (or under
-- anything else) -- they stay parented to UIParent for their entire
-- lifetime and are only ever repositioned via SetPoint, in both modes. That
-- means petGroupFrame itself has no secure descendants in the structural
-- (SetParent) sense, so its own SetSize/SetPoint calls are NOT protected by
-- combat lockdown the way partyFrame's are (partyFrame IS a true ancestor
-- of the secure header) -- only the pet BUTTONS' own SetPoint/SetSize calls
-- need guarding, which ApplyPetLayout below handles centrally.
--
-- Parameterised over its layout table (2026-09-04) so the standalone
-- player-pet frame can be a second instance rather than a copy: `getLayout`
-- is called fresh on every read AND on every drag write, so each container
-- persists its position into its own DB table. Everything below refers to the
-- `container` local, never to a module upvalue -- capturing petGroupFrame here
-- would have quietly made both frames drag the group container.
local function CreatePetContainer(frameName, moverName, getLayout, defaultY)
    local container = CreateFrame("Frame", frameName, UIParent, "BackdropTemplate")
    local prof = GetProfile()
    local layout = getLayout(prof)
    local anchorX = (layout and layout.anchorX) or 0
    local anchorY = (layout and layout.anchorY) or defaultY or -260
    local scale = (prof and prof.appearance and prof.appearance.general and prof.appearance.general.scale) or 1.0
    container:SetScale(scale)
    container:SetFrameStrata("MEDIUM")
    container:SetPoint("CENTER", UIParent, "CENTER", anchorX / scale, anchorY / scale)
    container:SetSize((layout and layout.width or 60) + 6, (layout and layout.height or 24) + 6)
    container:EnableMouse(false)

    local mover = CreateFrame("Frame", moverName, container)
    mover:SetAllPoints(container)
    mover:SetFrameStrata(container:GetFrameStrata())
    mover:SetFrameLevel(container:GetFrameLevel() + 10)
    mover:EnableMouse(true)
    mover:SetMovable(true)
    -- Deliberately NOT RegisterForDrag -- see the matching comment on
    -- PartyFrames.lua's container mover: Blizzard's drag detection waits for
    -- the cursor to clear a threshold before firing OnDragStart, which feels
    -- like the frame refuses to move for the first moment of the drag. Start
    -- on the press instead.
    mover:Hide() -- only shown in edit mode
    container.mover = mover

    local dragOffsetX, dragOffsetY = 0, 0
    local dragging = false

    local StopDrag

    local function StartDrag(self)
        if dragging then return end
        dragging = true
        local p = GetProfile()
        local layoutDb = getLayout(p)
        local pScale = UIParent:GetEffectiveScale()
        local startCursorX, startCursorY = GetCursorPosition()
        startCursorX = startCursorX / pScale
        startCursorY = startCursorY / pScale
        local sw, sh = GetScreenWidth(), GetScreenHeight()
        local frameCX = sw / 2 + (layoutDb and layoutDb.anchorX or 0)
        local frameCY = sh / 2 + (layoutDb and layoutDb.anchorY or 0)
        local cursorOffX = frameCX - startCursorX
        local cursorOffY = frameCY - startCursorY
        dragOffsetX = layoutDb and layoutDb.anchorX or 0
        dragOffsetY = layoutDb and layoutDb.anchorY or 0

        self:SetScript("OnUpdate", function(f)
            -- Self-heal for a mouse-up that never reached us (cursor dragged
            -- off the frame/screen edge), which would otherwise leave the pet
            -- group glued to the cursor.
            if not IsMouseButtonDown("LeftButton") then
                StopDrag(f)
                return
            end
            local cx, cy = GetCursorPosition()
            local ps = UIParent:GetEffectiveScale()
            cx = cx / ps
            cy = cy / ps
            local sw2, sh2 = GetScreenWidth(), GetScreenHeight()
            dragOffsetX = (cx + cursorOffX) - sw2 / 2
            dragOffsetY = (cy + cursorOffY) - sh2 / 2
            local frameScale = container:GetScale() or 1
            container:ClearAllPoints()
            container:SetPoint("CENTER", UIParent, "CENTER",
                dragOffsetX / frameScale, dragOffsetY / frameScale)
        end)
    end

    -- Declared as a local above so the OnUpdate's release check can call it.
    function StopDrag(self)
        if not dragging then return end
        dragging = false
        self:SetScript("OnUpdate", nil)
        -- No InCombatLockdown guard here -- mirrors PartyFrames.lua's own
        -- mover precedent (its drag-stop is likewise unguarded), an
        -- accepted existing gap since dragging only happens in edit mode, a
        -- rare/deliberate out-of-combat user action. Also see this
        -- function's header comment: the container isn't actually protected
        -- by combat lockdown in the first place, unlike partyFrame.
        local p = GetProfile()
        local layoutDb = getLayout(p)
        if layoutDb then
            layoutDb.anchorX = dragOffsetX
            layoutDb.anchorY = dragOffsetY
        end
        local frameScale = container:GetScale() or 1
        container:ClearAllPoints()
        container:SetPoint("CENTER", UIParent, "CENTER",
            dragOffsetX / frameScale, dragOffsetY / frameScale)
    end

    mover:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then StartDrag(self) end
    end)
    mover:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then StopDrag(self) end
    end)
    -- Leaving edit mode mid-drag would otherwise strand the OnUpdate handler.
    mover:SetScript("OnHide", function(self) StopDrag(self) end)

    -- Edit mode border (visual only), simplified from PartyFrames.lua's
    -- editFrame -- that one shrink-wraps to the visible BUTTONS' rects
    -- (SizeEditFrameToButtons) because the container can be larger than its
    -- content. These containers are always sized to exactly fit their buttons
    -- (see SizePetGroupToButtons below), so the border can just cover the
    -- whole container -- no separate shrink-wrap pass needed.
    local editFrame = CreateFrame("Frame", nil, container)
    editFrame:SetFrameStrata("DIALOG")
    editFrame:SetFrameLevel(100)
    editFrame:SetAllPoints(container)
    editFrame:Hide()
    container.editFrame = editFrame

    local function MakeBorder(parent, thickness)
        local tex = parent:CreateTexture(nil, "BACKGROUND")
        tex:SetColorTexture(0.33, 0.77, 0.99, 0.0)
        tex:SetHeight(thickness)
        tex:SetWidth(thickness)
        return tex
    end
    editFrame.borderTop = MakeBorder(editFrame, 2)
    editFrame.borderTop:SetPoint("TOPLEFT", editFrame, "TOPLEFT", 0, 0)
    editFrame.borderTop:SetPoint("TOPRIGHT", editFrame, "TOPRIGHT", 0, 0)
    editFrame.borderBottom = MakeBorder(editFrame, 2)
    editFrame.borderBottom:SetPoint("BOTTOMLEFT", editFrame, "BOTTOMLEFT", 0, 0)
    editFrame.borderBottom:SetPoint("BOTTOMRIGHT", editFrame, "BOTTOMRIGHT", 0, 0)
    editFrame.borderLeft = MakeBorder(editFrame, 2)
    editFrame.borderLeft:SetPoint("TOPLEFT", editFrame, "TOPLEFT", 0, 0)
    editFrame.borderLeft:SetPoint("BOTTOMLEFT", editFrame, "BOTTOMLEFT", 0, 0)
    editFrame.borderRight = MakeBorder(editFrame, 2)
    editFrame.borderRight:SetPoint("TOPRIGHT", editFrame, "TOPRIGHT", 0, 0)
    editFrame.borderRight:SetPoint("BOTTOMRIGHT", editFrame, "BOTTOMRIGHT", 0, 0)

    return container
end

local function CreatePetGroupContainer()
    if petGroupFrame then return petGroupFrame end
    petGroupFrame = CreatePetContainer("SquizzFramesPetGroupFrame",
        "SquizzFramesPetGroupMover", GetActivePetLayout, -260)
    return petGroupFrame
end

local function CreatePlayerPetContainer()
    if playerPetFrame then return playerPetFrame end
    playerPetFrame = CreatePetContainer("SquizzFramesPlayerPetFrame",
        "SquizzFramesPlayerPetMover", GetPlayerPetLayout, -320)
    return playerPetFrame
end

-----------------------------------------------------------------------
-- Positioning
-----------------------------------------------------------------------

-- PetButton.xml anchors healthBar/powerBar via TOPLEFT+BOTTOMLEFT only (no
-- RIGHT anchor, matching UnitButton.xml's own template) -- that gives them
-- height but no width until something sets one explicitly. button:SetSize
-- resizes the button frame itself but does NOT cascade to these children,
-- same reason PartyFrames.lua's resolveChildren explicitly calls
-- healthBar/powerBar:SetWidth. Without this, both bars render at 0 width
-- (invisible) regardless of how UnitHealth/UnitPower are set.
local function ResizePetButtonBars(button, bw)
    if button.healthBar then button.healthBar:SetWidth(bw) end
    if button.powerBar then button.powerBar:SetWidth(bw) end
end

-- Apply the configured name-text font, colour and placement.
--
-- PetButton.xml pins the FontString with TWO anchors (TOPLEFT + TOPRIGHT). A
-- user-chosen anchor point can only be a SINGLE point, so those are cleared.
--
-- The FontString is left AUTO-SIZING (SetWidth(0) -- 0 means unlimited in
-- WoW), which is what makes the anchor mean what it says. An explicit width
-- was tried first and is why "Center" rendered left-aligned (user report
-- 2026-08-14): with a fixed width the box spans nearly the whole button
-- whatever the anchor, so the anchor only positions that box and it's the
-- JUSTIFICATION that decides where the text lands inside it. Auto-sizing makes
-- the box exactly the text, so anchoring its CENTER to the button's CENTER
-- genuinely centres the name.
--
-- This matches the party Name Text indicator, whose default "unlimited" text
-- width does the same thing (see CheckNameText in BuiltIn_Update.lua).
--
-- Trade: a very long pet name can now overhang the frame rather than being
-- clipped to it. SetWordWrap(false) still guarantees ONE line -- the thing
-- that actually breaks a 16px raid pet button -- and pet names are short in
-- practice, so this is the better side of the trade.
local function ApplyPetNameText(button, layout)
    local fs = button and button.nameText
    if not fs then return end
    local cfg = layout and layout.nameText
    if cfg and cfg.enabled == false then
        fs:Hide()
        return
    end

    local font = cfg and cfg.font
    local face = F.ResolveFontFile and F.ResolveFontFile(font and font[1])
        or [[Fonts\FRIZQT__.TTF]]
    local size = (font and font[2]) or 10
    local flags = font and font[3]
    if not flags or flags == "NONE" then flags = nil end
    fs:SetFont(face, size, flags)
    -- Shadow is the 4th field, matching the party Name Text indicator's own
    -- font table shape. Explicitly cleared when off -- the XML ships a shadow,
    -- so leaving it alone would make the toggle one-way.
    if font and font[4] then
        fs:SetShadowOffset(1, -1)
        fs:SetShadowColor(0, 0, 0, 1)
    else
        fs:SetShadowOffset(0, 0)
        fs:SetShadowColor(0, 0, 0, 0)
    end

    local r, g, b, a = F.ColorRGB(cfg and cfg.color or {"custom_color", 1, 1, 1, 1})
    fs:SetTextColor(r, g, b, a or 1)

    local point = (cfg and cfg.anchorPoint) or "TOPLEFT"
    fs:ClearAllPoints()
    fs:SetPoint(point, button, point, (cfg and cfg.offsetX) or 0, (cfg and cfg.offsetY) or 0)
    -- 0 = unlimited: the box hugs the text, so the anchor alone places it.
    fs:SetWidth(0)
    fs:SetWordWrap(false)
    -- Justification is redundant on an auto-sized box (it has no slack for the
    -- text to move around in), but set to match the anchor anyway so the two
    -- can never contradict each other if a width is ever reintroduced.
    if point:find("RIGHT") then
        fs:SetJustifyH("RIGHT")
    elseif point:find("LEFT") then
        fs:SetJustifyH("LEFT")
    else
        fs:SetJustifyH("CENTER")
    end
    fs:Show()
end

-- Attached mode: glue each relevant pet button to a side of its owner's
-- current unit button. No extra event wiring is needed for the OWNER
-- moving/dragging -- since the pet anchors directly to the owner button (a
-- descendant of the main party container), WoW's anchor-chain resolution
-- tracks the owner's on-screen position automatically the instant its
-- ancestor moves. Don't "fix" this later with redundant position tracking.
local function LayoutAttachedPets(layout, bw, bh)
    local PartyFrames = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    if not PartyFrames or not PartyFrames.FindButtonByUnit then return end

    local side = layout.anchorSide or "RIGHT"
    local petPoint = OPPOSITE_SIDE[side] or "LEFT"
    local offsetX = layout.offsetX or 0
    local offsetY = layout.offsetY or 0

    for _, slot in ipairs(GetRelevantPetSlots()) do
        local button = petButtons[slot]
        if button then
            local ownerUnit = GetOwnerUnitForPet(slot)
            local ownerButton = ownerUnit and PartyFrames.FindButtonByUnit(ownerUnit)
            if ownerButton then
                button:ClearAllPoints()
                button:SetPoint(petPoint, ownerButton, side, offsetX, offsetY)
                button:SetSize(bw, bh)
                ResizePetButtonBars(button, bw)
                ApplyPetNameText(button, layout)
            end
            -- No ownerButton yet (e.g. buttons not wired up this early) --
            -- leave the button at its last/fallback anchor. The next
            -- PartyButtonsWired pass will correct it.
        end
    end
end

-- Floating mode: stack every currently-visible relevant pet inside
-- petGroupFrame, simple sequential SetPoint chaining (vertical/horizontal,
-- UP/DOWN/LEFT/RIGHT growth only -- no CENTER_H/CENTER_V, a deliberate v1
-- scope cut, see the design plan).
local function LayoutFloatingPets(layout, bw, bh)
    if not petGroupFrame then return end
    local spacing = layout.spacingY or 2
    local orientation = layout.orientation or "vertical"
    local growthDir = layout.growthDirection or "DOWN"

    local visible = {}
    for _, slot in ipairs(GetRelevantPetSlots()) do
        local button = petButtons[slot]
        if button and button:IsShown() and UnitExists(slot) then
            visible[#visible + 1] = button
        end
    end

    for i, button in ipairs(visible) do
        button:ClearAllPoints()
        button:SetSize(bw, bh)
        ResizePetButtonBars(button, bw)
        ApplyPetNameText(button, layout)
        if i == 1 then
            local point
            if orientation == "horizontal" then
                point = (growthDir == "LEFT") and "RIGHT" or "LEFT"
            else
                point = (growthDir == "UP") and "BOTTOM" or "TOP"
            end
            button:SetPoint(point, petGroupFrame, point, 0, 0)
        else
            local prev = visible[i - 1]
            if orientation == "horizontal" then
                if growthDir == "LEFT" then
                    button:SetPoint("RIGHT", prev, "LEFT", -spacing, 0)
                else
                    button:SetPoint("LEFT", prev, "RIGHT", spacing, 0)
                end
            else
                if growthDir == "UP" then
                    button:SetPoint("BOTTOM", prev, "TOP", 0, spacing)
                else
                    button:SetPoint("TOP", prev, "BOTTOM", 0, -spacing)
                end
            end
        end
    end

    return #visible
end

-- Sizes petGroupFrame to fit its currently visible pets. Only ever called
-- from within ApplyPetLayout, which already holds the InCombatLockdown
-- guard covering the pet buttons' own SetPoint/SetSize calls -- petGroupFrame
-- itself needs no separate guard (see CreatePetGroupContainer's comment).
local function SizePetGroupToButtons(layout, bw, bh, visibleCount)
    if not petGroupFrame then return end
    local spacing = layout.spacingY or 2
    local orientation = layout.orientation or "vertical"
    if not visibleCount or visibleCount == 0 then visibleCount = 1 end

    if orientation == "horizontal" then
        petGroupFrame:SetSize(visibleCount * bw + (visibleCount - 1) * spacing + 6, bh + 6)
    else
        petGroupFrame:SetSize(bw + 6, visibleCount * bh + (visibleCount - 1) * spacing + 6)
    end
end

-- The standalone player's-own-pet frame. Exactly one button ("pet"), so there
-- is no flow layout to run -- it just fills its container.
--
-- Sizing/name-text reuse the same helpers the group path uses, so the two
-- can't visually drift. Note ResolvePetSize is NOT reused: its matchOwnerWidth/
-- matchOwnerHeight options read the party layout to match an owner frame, and
-- this frame deliberately has no owner to sit beside.
local function LayoutPlayerPetFrame(enabled)
    local button = petButtons["pet"]
    if not button then return end

    if not enabled then
        -- Only tear the button down if the group path isn't using it. In
        -- solo/party with the standalone frame off, "pet" is a normal member
        -- of the group layout and ApplyPetLayout re-registers it below.
        if playerPetFrame then playerPetFrame:Hide() end
        return
    end

    local layout = GetPlayerPetLayout()
    if not layout then return end
    if not playerPetFrame then CreatePlayerPetContainer() end

    local bw = layout.width or 80
    local bh = layout.height or 30

    -- The container is re-anchored on every pass rather than only at creation:
    -- CreatePlayerPetContainer reads anchorX/anchorY once, so a profile switch
    -- (or the position being restored from a different profile) would
    -- otherwise leave the frame at the old profile's spot until the next drag.
    local prof = GetProfile()
    local scale = (prof and prof.appearance and prof.appearance.general
                   and prof.appearance.general.scale) or 1.0
    playerPetFrame:SetScale(scale)
    playerPetFrame:ClearAllPoints()
    playerPetFrame:SetPoint("CENTER", UIParent, "CENTER",
        (layout.anchorX or 0) / scale, (layout.anchorY or -320) / scale)
    playerPetFrame:SetSize(bw + 6, bh + 6)

    RegisterUnitWatch(button)
    button:ClearAllPoints()
    button:SetPoint("CENTER", playerPetFrame, "CENTER", 0, 0)
    button:SetSize(bw, bh)
    ResizePetButtonBars(button, bw)
    ApplyPetNameText(button, layout)

    -- Shown unconditionally, not gated on UnitExists("pet"): the container
    -- draws nothing itself (no backdrop, EnableMouse(false)) so an empty one
    -- is invisible, and keeping it up means edit mode always has something to
    -- drag even on a class with no pet or before one is summoned. The BUTTON's
    -- visibility is RegisterUnitWatch's job.
    playerPetFrame:Show()
end

-- The single entry point for (re)positioning every pet button, for whichever
-- mode/settings are currently active. Guarded exactly like PartyFrames.lua's
-- ApplyLayout (see that function's own comment for the full "why" -- this
-- mirrors a real, previously-fixed live production bug): pet buttons are
-- secure-templated with a "unit" attribute, so SetPoint/SetSize on them is
-- protected once combat starts, and schedule-time-only InCombatLockdown
-- checks miss the case where combat begins before a deferred call fires.
local function ApplyPetLayout()
    if applyingPetLayout then return end
    if InCombatLockdown() then
        if not applyPetLayoutRetryFrame then
            applyPetLayoutRetryFrame = CreateFrame("Frame")
            applyPetLayoutRetryFrame:SetScript("OnEvent", function(self)
                self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                ApplyPetLayout()
            end)
        end
        applyPetLayoutRetryFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    if not next(petButtons) then return end
    applyingPetLayout = true

    local prof = GetProfile()
    local layout = GetActivePetLayout(prof)
    local standalone = PlayerPetFrameEnabled()

    local relevantSet = {}
    for _, slot in ipairs(GetRelevantPetSlots()) do relevantSet[slot] = true end

    -- Slots irrelevant to the CURRENT group mode (e.g. raid pet slots while
    -- in a party, or vice versa) are always fully disabled: UnregisterUnitWatch
    -- + Hide takes them out of RegisterUnitWatch's automatic show/hide
    -- entirely, since a bare :Hide() call would just get silently overridden
    -- the next time that automatic driver re-evaluates.
    --
    -- "pet" is spared while the standalone frame owns it -- GetRelevantPetSlots
    -- deliberately drops it from the group set in that case, so without this
    -- exemption the standalone frame's only button would be torn down here
    -- immediately after LayoutPlayerPetFrame set it up.
    for slot, button in pairs(petButtons) do
        if not relevantSet[slot] and not (standalone and slot == "pet") then
            UnregisterUnitWatch(button)
            button:Hide()
        end
    end

    -- Independent of the group layout entirely, including of `layout` being
    -- nil or disabled: the standalone frame is its own feature and stays up
    -- for someone who wants ONLY their own pet framed.
    LayoutPlayerPetFrame(standalone)

    if not layout or not layout.enabled then
        for slot in pairs(relevantSet) do
            local button = petButtons[slot]
            if button then
                UnregisterUnitWatch(button)
                button:Hide()
            end
        end
        if petGroupFrame then petGroupFrame:Hide() end
    else
        -- Re-enable automatic existence-driven show/hide for relevant slots
        -- (idempotent/safe to call repeatedly on an already-registered button).
        for slot in pairs(relevantSet) do
            local button = petButtons[slot]
            if button then RegisterUnitWatch(button) end
        end

        local bw, bh = ResolvePetSize(layout)

        if layout.mode == "floating" then
            if not petGroupFrame then CreatePetGroupContainer() end
            local visibleCount = LayoutFloatingPets(layout, bw, bh)
            SizePetGroupToButtons(layout, bw, bh, visibleCount)
            if petGroupFrame then petGroupFrame:Show() end
        else
            if petGroupFrame then petGroupFrame:Hide() end
            LayoutAttachedPets(layout, bw, bh)
        end
    end

    applyingPetLayout = false

    -- Pet frames being turned on/off (or a profile switch doing it) changes
    -- whether the range poll has anything to watch while ungrouped. This is
    -- the one hook every such path already runs through -- PetFramesChanged,
    -- ProfileChanged, LayoutChanged and GroupTypeChanged all land here -- and
    -- RefreshRangePolling is cheap and idempotent, so covering them all from
    -- here beats four separate call sites drifting apart.
    local PartyFrames = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    if PartyFrames and PartyFrames.RefreshRangePolling then
        PartyFrames.RefreshRangePolling()
    end

    -- Toggling the standalone frame from the options page while Edit Mode is
    -- already open changes which movers should be draggable, and nothing else
    -- re-fires EditModeChanged for that -- so the new frame would sit there
    -- un-draggable until Edit Mode was switched off and on again.
    if SquizzFrames.editMode then
        PetFrames:SetEditMode(true)
    end
end

-----------------------------------------------------------------------
-- Edit mode (Floating container only -- Attached-mode pets ride along with
-- their owner button, already covered by PartyFrames' own edit mode)
-----------------------------------------------------------------------

local function SetContainerEditMode(container, enabled)
    if not container or not container.editFrame then return end
    local editFrame = container.editFrame
    local accent = F.GetAccentColor and F.GetAccentColor()
    local function ApplyColor(alpha)
        local c = {0.33, 0.77, 0.99}
        if accent then c = {accent.r, accent.g, accent.b} end
        editFrame.borderTop:SetColorTexture(c[1], c[2], c[3], alpha)
        editFrame.borderBottom:SetColorTexture(c[1], c[2], c[3], alpha)
        editFrame.borderLeft:SetColorTexture(c[1], c[2], c[3], alpha)
        editFrame.borderRight:SetColorTexture(c[1], c[2], c[3], alpha)
    end
    if enabled then
        ApplyColor(0.9)
        if container.mover then
            container.mover:SetAllPoints(container)
            container.mover:Show()
        end
        editFrame:Show()
    else
        ApplyColor(0.0)
        editFrame:Hide()
        if container.mover then container.mover:Hide() end
    end
end

function PetFrames:SetEditMode(enabled)
    SetContainerEditMode(petGroupFrame, enabled)
    -- Only offer the standalone frame's mover when the feature is on --
    -- otherwise edit mode shows a draggable box for a frame that never
    -- appears. Its container is hidden in that state anyway, which already
    -- hides the mover, but being explicit keeps the two from disagreeing.
    if PlayerPetFrameEnabled() then
        SetContainerEditMode(playerPetFrame, enabled)
    else
        SetContainerEditMode(playerPetFrame, false)
    end
end

-----------------------------------------------------------------------
-- Module lifecycle
-----------------------------------------------------------------------

function PetFrames:OnInitialize()
    -- Registered on self (this module), never on SquizzFrames directly --
    -- CallbackHandler keeps exactly one handler per (self,event) pair, and
    -- PartyFrames/ClickCasting/Indicators already register their own
    -- handlers on themselves for several of these same messages.
    -- Coalesced: in a raid PartyButtonsWired fires once per subgroup header
    -- (eight times), and ApplyPetLayout re-places every pet button each time.
    local petLayoutPending = false
    self:RegisterMessage("PartyButtonsWired", function()
        if petLayoutPending then return end
        petLayoutPending = true
        C_Timer.After(0, function()
            petLayoutPending = false
            ApplyPetLayout()
        end)
    end)
    self:RegisterMessage("GroupTypeChanged", function() ApplyPetLayout() end)
    -- One handler per (owner, message): CallbackHandler keeps exactly one, so
    -- a second self:RegisterMessage("ProfileChanged", ...) anywhere in this
    -- file would silently REPLACE this one rather than run alongside it.
    -- Anything that needs to happen on a profile switch belongs in here.
    self:RegisterMessage("ProfileChanged", function()
        ApplyPetLayout()
        UpdateAllPetButtons()
        PetFrames.RefreshBorders()
    end)
    self:RegisterMessage("PetFramesChanged", function() ApplyPetLayout() end)
    -- The party layout's own width is an INPUT to pet sizing once
    -- either match option is on (see ResolvePetSize), and nothing else re-runs
    -- the pet layout when the Width slider on the Layout page moves.
    -- Unconditional rather than gated on the setting: ApplyPetLayout is
    -- already the handler for four other messages and re-runs constantly, so
    -- one more call on a layout edit costs nothing and can't go stale.
    self:RegisterMessage("LayoutChanged", function() ApplyPetLayout() end)
    -- Border/aggro colour, thickness, size, position, pulse and enabled
    -- changes. UpdateIndicators fires for every indicator edit; only the ones
    -- pet buttons actually build affect them, so filter rather than re-styling
    -- on every unrelated indicator change.
    local PET_BUTTON_INDICATORS = {
        frameBorder = true, hoverHighlight = true, targetHighlight = true,
        aggroBlink = true, aggroBorder = true,
    }
    self:RegisterMessage("UpdateIndicators", function(_, indicatorName)
        if PET_BUTTON_INDICATORS[indicatorName] then
            PetFrames.RefreshBorders()
        end
    end)
    self:RegisterMessage("EditModeChanged", function(_, enabled)
        self:SetEditMode(enabled)
    end)
    self:RegisterMessage("LockChanged", function(_, isLocked)
        if isLocked and SquizzFrames.editMode then
            self:SetEditMode(false)
        end
    end)
end

function PetFrames:OnEnable()
    if initialized then
        ApplyPetLayout()
        UpdateAllPetButtons()
        if SquizzFrames.editMode then
            self:SetEditMode(true)
        end
        return
    end

    local function init()
        CreatePetButtons()
        CreatePetGroupContainer()
        CreatePlayerPetContainer()
        ApplyPetLayout()
        UpdateAllPetButtons()

        -- Deterministic initial click-casting apply (2026-08-05): pet
        -- buttons' typeN/spellN attributes get written by
        -- ClickCasting:ApplyToAll, which collects buttons via
        -- PetFrames:IterateButtons (see ClickCasting.lua's CollectButtons).
        -- ApplyToAll already gets re-triggered independently on
        -- PLAYER_ENTERING_WORLD/ProfileChanged/PLAYER_REGEN_ENABLED, so this
        -- call isn't strictly load-bearing, but calling it directly here
        -- (rather than relying entirely on that cascade's timing) means
        -- bindings land on pet buttons the moment they're created instead
        -- of waiting on an unrelated event.
        local cc = SquizzFrames.modules and SquizzFrames.modules["ClickCasting"]
        if cc and cc.ApplyToAll then
            cc:ApplyToAll()
        end

        -- Same staggered re-apply convention as PartyFrames.lua's own
        -- OnEnable -- owner buttons may not be wired yet on first login.
        C_Timer.After(0.5, function()
            ApplyPetLayout()
            UpdateAllPetButtons()
        end)
        C_Timer.After(1.5, function()
            ApplyPetLayout()
            UpdateAllPetButtons()
        end)

        initialized = true

        local function onPetUnitEvent(_, unit)
            if unit and petButtons[unit] then
                UpdatePetButton(petButtons[unit])
            end
        end
        self:RegisterEvent("UNIT_HEALTH", onPetUnitEvent)
        self:RegisterEvent("UNIT_MAXHEALTH", onPetUnitEvent)
        self:RegisterEvent("UNIT_POWER_UPDATE", onPetUnitEvent)
        self:RegisterEvent("UNIT_MAXPOWER", onPetUnitEvent)
        self:RegisterEvent("UNIT_DISPLAYPOWER", onPetUnitEvent)
        self:RegisterEvent("UNIT_CONNECTION", onPetUnitEvent)
        self:RegisterEvent("UNIT_NAME_UPDATE", onPetUnitEvent)
        -- Fires on the OWNER's unit token when their pet is summoned/
        -- dismissed/swapped. RegisterUnitWatch already handles individual
        -- button show/hide automatically -- this just catches the
        -- "a previously-absent pet just appeared" positioning/reflow gap
        -- (matters most for Floating mode, which needs to re-stack around
        -- the newly-visible pet).
        self:RegisterEvent("UNIT_PET", function()
            ApplyPetLayout()
            UpdateAllPetButtons()
            -- A pet appearing/vanishing is what decides whether the range poll
            -- has anything to watch while ungrouped -- see PartyFrames'
            -- RangePollNeeded. Deferred a tick: RegisterUnitWatch does the
            -- actual show/hide, and HasVisibleButtons reads exactly that.
            local PartyFrames = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
            if PartyFrames and PartyFrames.RefreshRangePolling then
                C_Timer.After(0, PartyFrames.RefreshRangePolling)
            end
        end)

        -- Target Highlight bug fix (2026-08-05, user report: the border
        -- stuck on a pet after untargeting it, only clearing once hovered).
        -- BU.CheckTargetHighlight was only ever getting called from
        -- PetButton.lua's OnEnter/OnLeave (via RecheckHighlights) -- nothing
        -- re-ran it when the target itself changed. The main unit buttons
        -- avoid this via BuiltIn_Update.lua's eventMap, which dispatches
        -- PLAYER_TARGET_CHANGED (no unit payload) to every wired button;
        -- pet buttons were never part of that dispatch loop at all.
        self:RegisterEvent("PLAYER_TARGET_CHANGED", function()
            local BU = SquizzFrames.modules and SquizzFrames.modules["BuiltIn_Update"]
            if not BU or not BU.CheckTargetHighlight then return end
            for _, button in pairs(petButtons) do
                BU.CheckTargetHighlight(button)
            end
        end)

        -- Aggro indicators (2026-08-25). The same event the main frames use
        -- (BuiltIn_Update's eventMap), which pet buttons are not part of. It
        -- carries the unit whose threat changed, so only that pet's button is
        -- touched -- a pet's threat is its own, not its owner's.
        self:RegisterEvent("UNIT_THREAT_SITUATION_UPDATE", function(_, unit)
            local button = unit and petButtons[unit]
            if button then RefreshPetAggro(button) end
        end)

        if SquizzFrames.editMode then
            self:SetEditMode(true)
        end
    end

    if InCombatLockdown() then
        local frame = CreateFrame("Frame")
        frame:RegisterEvent("PLAYER_REGEN_ENABLED")
        frame:SetScript("OnEvent", function()
            frame:UnregisterEvent("PLAYER_REGEN_ENABLED")
            init()
        end)
    else
        init()
    end
end

function PetFrames:OnDisable()
    for _, button in pairs(petButtons) do
        UnregisterUnitWatch(button)
        button:Hide()
    end
    if petGroupFrame then petGroupFrame:Hide() end
    if playerPetFrame then playerPetFrame:Hide() end
    initialized = false
end

-- Public accessors (2026-08-05), mirroring PartyFrames.lua's own
-- IterateButtons/FindButtonByUnit exactly -- used by ClickCasting.lua's
-- CollectButtons to include pet buttons in click-casting binding application.
function PetFrames:IterateButtons(func)
    for _, button in pairs(petButtons) do
        func(button)
    end
end

function PetFrames.FindButtonByUnit(unit)
    return petButtons[unit]
end

-- Re-apply the border indicators (hover/target highlight + frame border) from
-- the user's current settings. Pet buttons aren't part of the indicator
-- system's own update pipeline, so nothing else re-styles them when those
-- universal border settings change -- without this they'd keep whatever
-- colour/thickness they were built with until a reload.
-- Is any pet button actually on screen? Asked by PartyFrames' RangePollNeeded:
-- a visible pet is the only thing worth range-polling while ungrouped, so this
-- is what keeps the poll alive (or lets it stop) for a solo player.
--
-- Deliberately a plain loop, not IterateButtons: this is called from the poll
-- itself, and passing a closure would allocate on every tick -- the exact
-- churn the stop condition exists to avoid.
function PetFrames.HasVisibleButtons()
    for _, button in pairs(petButtons) do
        if button:IsShown() then return true end
    end
    return false
end

function PetFrames.RefreshBorders()
    if not SquizzFrames.PetButton_ApplyBorders then return end
    for _, button in pairs(petButtons) do
        SquizzFrames.PetButton_ApplyBorders(button)
    end
end
