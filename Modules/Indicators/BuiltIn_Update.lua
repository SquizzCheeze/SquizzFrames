--[[ SquizzFrames BuiltIn_Update.lua - Built-in indicator check/create ]]
--
-- Provides CreateBuiltInIndicator(button, t) to create the frame for a built-in
-- indicator, SetupIndicator(button, t) for post-creation wiring, CheckAll(button)
-- for an immediate pass of every built-in's Check, and HandleEvent(button, event)
-- for event-driven updates.
--
-- Only the 19 core built-ins (nameText, statusText, statusIcon, roleIcon,
-- leaderIcon, playerRaidIcon, aggroBlink, aggroBorder, targetHighlight,
-- hoverHighlight, shieldBar, externalCooldowns, defensiveCooldowns, debuffs,
-- ccIndicator, dispels, missingBuffs, healthText, powerText) are implemented
-- here.

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F

local BU = SquizzFrames:NewModule("BuiltIn_Update", "AceEvent-3.0")

-- Stack-count display used to rely on a spellStackCache heuristic here
-- (learn a spell's real applications value from the last non-secret reading,
-- since a secret count's MAGNITUDE can never be safely tested). That's gone
-- now -- ApplySlotVisuals below uses C_UnitAuras.GetAuraApplicationDisplayCount
-- instead, which needs no learned cache at all (see its comment).

-- External/defensive spell ID tables (loaded from Indicator_Defaults by Indicators.lua)
-- These are now class-keyed tables; flatten them into simple arrays for scanning.
-- F.FlattenSpellTable lives in Utils.lua (not local here) so
-- AuraEngineIndicators.lua can share the exact same flatten logic when
-- building the includeSpellIDs set for the AuraContainer-backed versions.
local externalCooldowns = F.FlattenSpellTable(SquizzFrames.defaults and SquizzFrames.defaults.externalCooldowns or {})
local defensiveCooldowns = F.FlattenSpellTable(SquizzFrames.defaults and SquizzFrames.defaults.defensiveCooldowns or {})

-- raidBuffs also needs a spellID -> providing-class map (FlattenSpellTable
-- alone discards which class-key each ID came from) so CheckMissingBuffs can
-- skip a curated buff entirely when nobody who could provide it is actually
-- in the group -- e.g. don't flag "missing Arcane Intellect" with no Mage
-- present. Built by hand here rather than via FlattenSpellTable for that
-- extra bit of per-ID data.
local raidBuffs, raidBuffClass = {}, {}
do
    local curated = SquizzFrames.defaults and SquizzFrames.defaults.raidBuffs or {}
    for className, spells in pairs(curated) do
        for id in pairs(spells) do
            if type(id) == "number" then
                raidBuffs[#raidBuffs + 1] = id
                raidBuffClass[id] = className
            end
        end
    end
end
local raidBuffVariants = SquizzFrames.defaults and SquizzFrames.defaults.raidBuffVariants or {}

-- True if `id` itself, or any of its registered alternate aura IDs
-- (defaults.raidBuffVariants -- e.g. Blessing of the Bronze's 26
-- per-recipient-class variants), is in presentSet. Lets a single curated
-- checklist entry (one blanket "Blessing of the Bronze" checkbox) match
-- whichever class-specific aura ID actually lands on a given unit, without
-- ever surfacing the variants as their own separate checklist rows.
local function IsBuffPresent(id, presentSet)
    if presentSet[id] then return true end
    local variants = raidBuffVariants[id]
    if variants then
        for _, vid in ipairs(variants) do
            if presentSet[vid] then return true end
        end
    end
    return false
end

-- Which classes are actually present in the current group (player + party,
-- or the full raid roster). Recomputed fresh on each CheckMissingBuffs call
-- -- group composition changes are rare and a party/raid roster is at most
-- 40 units, so there's no need for event-driven cache invalidation here.
-- UnitClass's classFileName return is plain identity data (not aura/health/
-- combat-log data, the categories confirmed secret-tainted elsewhere this
-- session) but the whole scan is pcall-wrapped as a defensive measure since
-- that hasn't been specifically verified safe on this client.
local function GetGroupClasses()
    local classes = {}
    pcall(function()
        if IsInRaid() then
            for i = 1, GetNumGroupMembers() do
                local unit = "raid" .. i
                if UnitExists(unit) then
                    local classFile = select(2, UnitClass(unit))
                    if classFile then classes[classFile] = true end
                end
            end
        else
            local classFile = select(2, UnitClass("player"))
            if classFile then classes[classFile] = true end
            for i = 1, 4 do
                local unit = "party" .. i
                if UnitExists(unit) then
                    local cf = select(2, UnitClass(unit))
                    if cf then classes[cf] = true end
                end
            end
        end
    end)
    return classes
end

-- ------------------------------------------------------------------
-- Indicator frame creation helpers
-- ------------------------------------------------------------------

-- FontStrings/Textures created directly on a frame (button:CreateFontString,
-- e.g. nameText/healthText/powerText/statusText) have no independent
-- SetFrameLevel -- that's a Frame-only concept, not available on a Region.
-- The generic "frameLevel" dispatch in Indicators.lua checks
-- `indicator.SetFrameLevel` before calling it, so it silently no-ops on
-- these; they're permanently stuck at their owning frame's own baseline
-- level, always BELOW any sibling overlay child frame (shieldOverlay/
-- shieldBar/healAbsorb/etc), which either default to owner-level+1 or get
-- their OWN frameLevel setting correctly applied (they're real Frames).
-- Confirmed via user report: nameText's frameLevel slider visibly moves in
-- the Designer preview but has zero effect on real buttons, because it was
-- never actually doing anything there.
--
-- Fix: reparent the region onto a small dedicated "level frame" (invisible,
-- owns no regions of its own) so it gets a REAL, independently controllable
-- frame level. GetParent is overridden back to the original owner so the
-- generic dispatch's "owner:GetFrameLevel() + t.frameLevel" math stays
-- stable -- reading the level frame's own level here would drift upward
-- every time the setting changes, since we're the ones mutating it.
local function GiveRegionRealFrameLevel(region, owner)
    if region._sfLevelFrame then return end
    local levelFrame = CreateFrame("Frame", nil, owner)
    region._sfLevelFrame = levelFrame
    region:SetParent(levelFrame)
    function region:SetFrameLevel(lvl)
        levelFrame:SetFrameLevel(lvl)
    end
    function region:GetFrameLevel()
        return levelFrame:GetFrameLevel()
    end
    function region:GetParent()
        return owner
    end
end

-- Simple icon texture on a Frame. Used by statusIcon, leaderIcon, aggroBlink.
local function CreateIconIndicator(button, name)
    local f = CreateFrame("Frame", button:GetName() .. name, button)
    f:SetSize(11, 11)
    f:Hide()
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    function f:SetIcon(texture, ...)
        if texture then
            if ... then
                -- Multiple return values: texture path + tex coords (Blizzard atlas)
                self.tex:SetTexture(texture)
                self.tex:SetTexCoord(...)
            else
                self.tex:SetTexture(texture)
                self.tex:SetTexCoord(0, 1, 0, 1)
            end
            self:Show()
        else
            self:Hide()
        end
    end
    -- NOTE: no custom SetSize needed here. The frame's native SetSize works,
    -- and f.tex was created with SetAllPoints so it resizes automatically.
    return f
end

-- Border frame using 4 textures (Cell's approach). Used by aggroBorder.
-- Flush with the button's actual edges (no inset) so the border strips
-- (drawn inward from here by SetThickness) read as a true outline right at
-- the frame's perimeter, not shading pulled in from it.
local function CreateBorderIndicator(button, name)
    local f = CreateFrame("Frame", button:GetName() .. name, button, "BackdropTemplate")
    f:SetAllPoints(button)
    f:Hide()
    local top    = f:CreateTexture(nil, "BORDER")
    local bottom = f:CreateTexture(nil, "BORDER")
    local left   = f:CreateTexture(nil, "BORDER")
    local right  = f:CreateTexture(nil, "BORDER")
    top:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    top:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    bottom:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    bottom:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    left:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    right:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    f._textures = { top = top, bottom = bottom, left = left, right = right }
    function f:SetThickness(thick)
        top:SetHeight(thick)
        bottom:SetHeight(thick)
        left:SetWidth(thick)
        right:SetWidth(thick)
    end
    function f:SetColor(r, g, b, a)
        a = a or 1
        top:SetColorTexture(r, g, b, a)
        bottom:SetColorTexture(r, g, b, a)
        left:SetColorTexture(r, g, b, a)
        right:SetColorTexture(r, g, b, a)
    end
    f:SetThickness(2)
    f:SetColor(1, 0, 0, 1)
    return f
end
-- Exported (2026-08-05) so PetFrames' PetButton.lua can reuse the same
-- border-texture factory for pet hover/target highlights instead of
-- duplicating it -- pet buttons don't have the full indicator system wired
-- up, so they build just these two border frames directly rather than going
-- through I.HandleIndicators/I.CreateIndicator.
BU.CreateBorderIndicator = CreateBorderIndicator

-- Simple StatusBar for shieldBar. Unlike shieldOverlay/healAbsorb (which
-- SetAllPoints to the health bar and get their width for free), this bar is
-- positioned via the generic single-point t.position anchor, which sets
-- location but never size -- so it needs an explicit width or it renders at
-- 0px and stays invisible no matter what value/color/alpha it's given.
local function CreateBarIndicator(button, name)
    local bar = CreateFrame("StatusBar", button:GetName() .. name, button)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:SetHeight(4)
    bar:SetWidth((button:GetWidth() and button:GetWidth() > 0) and button:GetWidth() or 100)
    bar:Hide()
    local tex = bar:CreateTexture(nil, "ARTWORK")
    tex:SetColorTexture(1, 1, 0, 1)
    tex:SetAllPoints()
    bar:SetStatusBarTexture(tex)
    function bar:SetColor(r, g, b, a)
        tex:SetColorTexture(r, g, b, a or 1)
    end
    return bar
end

-- Health-bar overlay textures (Cell-derived; see Media\shield.tga etc. --
-- bundled but unused until this feature).
local SHIELD_TEX = "Interface\\AddOns\\SquizzFrames\\Media\\shield"
local OVERSHIELD_TEX = "Interface\\AddOns\\SquizzFrames\\Media\\overshield"
local OVERSHIELD_TEX_R = "Interface\\AddOns\\SquizzFrames\\Media\\overshield_reversed"
-- Native pixel widths (confirmed via TGA header inspection) -- these are
-- narrow edge-highlight strips, NOT full-bar gradients. SetAllPoints-ing one
-- against the whole fill texture (this indicator's previous fix) stretched
-- an 8px-wide image across the entire shielded width instead of keeping it a
-- crisp line at the current fill edge -- confirmed via user report + screenshot
-- comparison against Cell. reversed is a different native width (16 vs 8),
-- so each needs its own SetWidth, not one shared constant.
local OVERSHIELD_TEX_WIDTH = 8
local OVERSHIELD_TEX_R_WIDTH = 16
local OVERABSORB_TEX = "Interface\\AddOns\\SquizzFrames\\Media\\overabsorb"
local OVERABSORB_TEX_WIDTH = 8

-- GetRaidTargetIndex(unit) can return a genuinely secret number on this
-- client (confirmed via BugGrabber + cross-checked against
-- EllesmereUIRaidFrames, same PTR client). SetRaidTargetIconTexture(texture,
-- index) is NOT secret-safe -- it appears to do the index-to-texcoord lookup
-- on the Lua side internally, so feeding it a secret index still fails
-- silently (no icon, no error). Ellesmere sidesteps the whole problem: set
-- the raw 4x2-icon atlas once (see CreateBuiltInIndicator's playerRaidIcon
-- branch), then drive the visible cell via SetTexCoord from a hand-rolled
-- lookup table when the index is a normal number, or via
-- Texture:SetSpriteSheetCell (a C-level method that CAN accept a secret
-- index directly, pcall-wrapped since its existence isn't guaranteed) when
-- issecretvalue(index) is true -- see CheckPlayerRaidIcon.
local RAID_MARKER_TEX = [[Interface\TargetingFrame\UI-RaidTargetingIcons]]
local RAID_MARKER_TEXCOORDS = {
    [1] = { 0,    0.25, 0,    0.25 },  -- Star
    [2] = { 0.25, 0.5,  0,    0.25 },  -- Circle
    [3] = { 0.5,  0.75, 0,    0.25 },  -- Diamond
    [4] = { 0.75, 1,    0,    0.25 },  -- Triangle
    [5] = { 0,    0.25, 0.25, 0.5  },  -- Moon
    [6] = { 0.25, 0.5,  0.25, 0.5  },  -- Square
    [7] = { 0.5,  0.75, 0.25, 0.5  },  -- Cross
    [8] = { 0.75, 1,    0.25, 0.5  },  -- Skull
}

-- Shield Overlay and Heal Absorb each have their own independently
-- selectable fill texture (t.barTexture, an LSM statusbar name -- see
-- IndicatorWidgets.lua's CreateSetting_BarTexture) instead of a single
-- texture shared by both: sharing one made them visually indistinguishable
-- when both show at once on the same health bar (confirmed via user report).
-- Different resolved-if-missing fallbacks per indicator (Shield vs Solid)
-- so each still looks reasonable/distinct even with no explicit choice made.
local LSM = LibStub and LibStub:GetLibrary("LibSharedMedia-3.0", true)
local function ResolveBarTexture(name, fallback)
    if name and LSM then
        local path = LSM:Fetch("statusbar", name)
        if path then return path end
    end
    return fallback
end

-- Absorb/shield values (UnitGetTotalAbsorbs, UnitGetTotalHealAbsorbs,
-- UnitHealth/UnitHealthMax) can be "secret numbers" in combat -- ANY Lua-side
-- arithmetic or comparison on them throws. The previously-used
-- "pcall(function() return val + 0 end)" sanitize trick silently drops the
-- value to nil whenever it's genuinely secret (the pcall fails), which is
-- exactly when a real shield/absorb needs to be shown -- hiding the
-- indicator at the worst possible time. Confirmed via EllesmereUIRaidFrames
-- (same PTR client, working): its UpdateAbsorb feeds raw values STRAIGHT
-- into SetMinMaxValues/SetValue (secret-safe at the C level, per WoW's own
-- design) without ever touching them in Lua, and uses a
-- UnitHealPredictionCalculator + SetAlphaFromBoolean for the secret-safe
-- overshield boolean instead of comparing health+absorbs > maxHealth by hand.
-- One calculator is created per button (shared by shieldBar/shieldOverlay/
-- healAbsorb) and cached on button._sfHealPredCalc (false = unavailable on
-- this client, distinct from nil = "not yet attempted").
local function GetHealPredCalc(button)
    if button._sfHealPredCalc ~= nil then return button._sfHealPredCalc end
    local calc = false
    if CreateUnitHealPredictionCalculator then
        local ok, c = pcall(CreateUnitHealPredictionCalculator)
        if ok and c then
            calc = c
            if calc.SetMaximumHealthMode and Enum.UnitMaximumHealthMode then
                calc:SetMaximumHealthMode(Enum.UnitMaximumHealthMode.WithAbsorbs)
            end
            if calc.SetDamageAbsorbClampMode and Enum.UnitDamageAbsorbClampMode then
                calc:SetDamageAbsorbClampMode(Enum.UnitDamageAbsorbClampMode.MissingHealth)
            end
        end
    end
    button._sfHealPredCalc = calc
    return calc
end

-- Returns maxHealth (plain number) and isClamped (possibly-secret boolean,
-- or nil if unavailable) for overshield detection. Falls back to
-- UnitHealthMax when the calculator API doesn't exist on this client.
local function ReadHealPredData(button, unit)
    local calc = GetHealPredCalc(button)
    local maxHealth, isClamped
    if calc and UnitGetDetailedHealPrediction then
        UnitGetDetailedHealPrediction(unit, nil, calc)
        if calc.SetMaximumHealthMode and Enum.UnitMaximumHealthMode then
            calc:SetMaximumHealthMode(Enum.UnitMaximumHealthMode.Default)
        end
        if calc.GetMaximumHealth then maxHealth = calc:GetMaximumHealth() end
        if calc.GetDamageAbsorbs then
            local _, clamped = calc:GetDamageAbsorbs()
            isClamped = clamped
        end
    end
    if not maxHealth then
        maxHealth = UnitHealthMax(unit) or 0
    end
    return maxHealth, isClamped
end

-- Pin a full-health-bar overlay wrapper INSIDE the health bar's chrome, rather
-- than SetAllPoints-ing it flush.
--
-- Two insets, both the Dispels overlay's (AuraEngineIndicators.lua owns the
-- measurements -- see the comments on HealthBottomInset/FrameBorderInset there
-- for why each exists):
--   bottom -- the power bar is a short strip drawn ON TOP of health's lower
--             edge, so anything flush to health's bottom covers it.
--   top/left/right -- frameBorder draws flush to the button's own edges, so
--             anything flush to health paints over it.
-- Both are read live off the button, so a hidden power bar or a disabled
-- border correctly yields 0 and the overlay reclaims that space.
--
-- Re-run from the Check functions rather than only at creation: the insets
-- change with settings the overlay itself never hears about (power bar height,
-- border thickness, border enabled), and both Checks already run on every
-- absorb/health event and after every rebuild, so re-measuring there is both
-- free and always current at the moment the bar is about to be shown.
local function AnchorInsideHealth(wrapper)
    local health = wrapper and wrapper._sfInsetHealth
    if not health then return end
    local AEI = SquizzFrames.AuraEngineIndicators
    -- Zero on a pre-12.1 client, where AuraEngineIndicators.lua bails before
    -- defining these -- i.e. the flush behaviour this replaced.
    local bottom = (AEI and AEI.HealthBottomInset and AEI.HealthBottomInset(health)) or 0
    local bi = (AEI and AEI.FrameBorderInset and AEI.FrameBorderInset(health)) or 0
    wrapper:ClearAllPoints()
    -- +x moves right and +y moves up, so left is +bi, right is -bi, top is -bi.
    wrapper:SetPoint("TOPLEFT", health, "TOPLEFT", bi, -bi)
    wrapper:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", -bi, bottom)
end

-- Re-anchor the two health-bar overlays whose insets depend on something they
-- never hear about themselves. Called from Indicators.lua when the Frame
-- Border's thickness or enabled state changes, alongside the equivalent
-- AEI.RefreshBorderInsets -- the Check functions re-measure too, but only
-- when a health/absorb event happens to arrive, and a border tweak in the
-- options panel produces neither. Without this the overlay keeps its old inset
-- until the unit next takes damage.
function BU.RefreshOverlayInsets(button)
    local inds = button and button.indicators
    if not inds then return end
    AnchorInsideHealth(inds.shieldOverlay)
    AnchorInsideHealth(inds.healAbsorb)
end

-- Shield Overlay: a StatusBar spanning the health bar, filling by
-- absorbs/maxHealth (forward from the left, or reverse from the right when
-- t.reverseFill is set) -- mirrors Cell's shieldBar/shieldBarR. A full-bar
-- glow (overshield.tga / overshield_reversed.tga) shows while overshielding
-- (shield + current health exceeds max health). No strata override (unlike
-- Dispels' AuraContainer-slot overlay): this wrapper is a plain child of
-- button, same as shieldBar/nameText/etc, so the ordinary frameLevel
-- mechanism (health bar pinned to "BACKGROUND" strata on the live button;
-- button-relative frameLevel on the Designer preview, whose health bar has
-- no strata split) is enough -- forcing "LOW" here would actually render
-- BELOW the preview's default-"MEDIUM" health bar mockup.
--
-- Fill texture is user-selectable (t.barTexture, an LSM statusbar name) via
-- wrapper:SetTexture -- defaults to the bundled "Shield" shimmer pattern.
local function CreateShieldOverlayIndicator(button, initialTexture)
    local health = button.healthBar or button
    local wrapper = CreateFrame("Frame", button:GetName() .. "ShieldOverlay", button)
    wrapper._sfInsetHealth = health
    AnchorInsideHealth(wrapper)
    wrapper:Hide()

    local bar = CreateFrame("StatusBar", nil, wrapper)
    bar:SetAllPoints(wrapper)
    bar:SetStatusBarTexture(ResolveBarTexture(initialTexture, SHIELD_TEX))
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    wrapper.bar = bar

    -- A narrow (8px/16px reversed) edge-highlight strip, NOT a full-bar
    -- overlay -- positioned by ApplyShieldGlowAnchor (called from
    -- CheckShieldOverlay, which knows the current reverseFill state) flush
    -- against whichever edge of the fill texture is CURRENTLY the shield's
    -- leading edge. The fill texture itself already repositions/resizes
    -- correctly for both fill directions (SetReverseFill), so anchoring the
    -- glow relative to it (rather than the wrapper) tracks the shield's
    -- actual value automatically without re-anchoring on every health tick.
    local glow = wrapper:CreateTexture(nil, "OVERLAY")
    glow:SetTexture(OVERSHIELD_TEX)
    glow:Hide()
    wrapper.glow = glow

    function wrapper:SetColor(r, g, b, a)
        bar:SetStatusBarColor(r, g, b, a or 1)
    end
    function wrapper:SetTexture(name)
        bar:SetStatusBarTexture(ResolveBarTexture(name, SHIELD_TEX))
    end
    -- Tint carried on the VERTEX colour, not SetAlpha, because the glow's
    -- object alpha is already spoken for: CheckShieldOverlay drives it from
    -- the secret `isClamped` via SetAlphaFromBoolean, and the two would fight.
    -- Vertex alpha multiplies with object alpha, so the boolean still decides
    -- whether the glow shows at all and this decides how strong it is when it
    -- does. Default 1,1,1,1 leaves the texture exactly as authored.
    function wrapper:SetGlowColor(r, g, b, a)
        wrapper._glow = { r or 1, g or 1, b or 1, a or 1 }
        glow:SetVertexColor(r or 1, g or 1, b or 1, a or 1)
    end
    -- CheckShieldOverlay re-runs glow:SetTexture on every pass (the two
    -- directions use different files), and the tint must survive that. Cheaper
    -- and more certain than relying on SetTexture preserving vertex colour.
    function wrapper:ReapplyGlowColor()
        local c = wrapper._glow
        if c then glow:SetVertexColor(c[1], c[2], c[3], c[4]) end
    end
    return wrapper
end

-- Heal Absorb: a StatusBar spanning the health bar, reverse-filling from the
-- right by healAbsorbs/currentHealth -- mirrors Cell's absorbsBar. There's no
-- confirmed secret-safe "fully capped" boolean for heal absorb (unlike
-- shields' isClamped), so instead of trying to detect that state, the glow
-- (overabsorb.tga) is anchored to the bar's OWN fill texture rather than the
-- full wrapper -- it naturally tracks whatever width the (possibly secret)
-- heal-absorb value produces, including collapsing to nothing when there's
-- none, without ever comparing the value in Lua.
--
-- Fill texture is user-selectable (t.barTexture) via wrapper:SetTexture --
-- defaults to "Solid" (flat), deliberately DIFFERENT from Shield Overlay's
-- "Shield" default so the two don't read as identical when both show at
-- once on the same health bar (confirmed clash via user report -- this
-- mirrors EllesmereUIRaidFrames' own anti-clash approach: independent
-- texture/color/opacity per bar, with differing defaults).
local function CreateHealAbsorbIndicator(button, initialTexture)
    local health = button.healthBar or button
    local wrapper = CreateFrame("Frame", button:GetName() .. "HealAbsorb", button)
    wrapper._sfInsetHealth = health
    AnchorInsideHealth(wrapper)
    wrapper:Hide()

    local bar = CreateFrame("StatusBar", nil, wrapper)
    bar:SetAllPoints(wrapper)
    bar:SetReverseFill(true)
    bar:SetStatusBarTexture(ResolveBarTexture(initialTexture, [[Interface\Buttons\WHITE8X8]]))
    bar:SetStatusBarColor(0.8, 0.1, 0.1, 0.6)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    wrapper.bar = bar

    -- Centered ON the fill texture's LEFT edge (reverse-fill's leading edge,
    -- always left here -- this bar reverse-fills unconditionally, no user
    -- toggle, so unlike Shield Overlay's glow this only needs anchoring once
    -- at creation) rather than SetAllPoints-ing the whole fill texture --
    -- same fix/reasoning as CreateShieldOverlayIndicator's ApplyShieldGlowAnchor:
    -- SetAllPoints stretched this narrow 8px strip across the entire
    -- heal-absorbed width instead of keeping it a crisp line at the edge,
    -- and flush (non-overlapping) placement left a visible gap since the
    -- fill texture's reported edge doesn't exactly coincide with where the
    -- bar's own fill visually appears to end. Straddling the edge (half
    -- overlapping into the absorbed portion, half beyond it) is robust to
    -- that discrepancy and is anchored relative to the fill texture, so it
    -- tracks the current heal-absorb value automatically as the fill resizes.
    local glow = wrapper:CreateTexture(nil, "OVERLAY")
    glow:SetWidth(OVERABSORB_TEX_WIDTH)
    glow:SetPoint("TOP", bar:GetStatusBarTexture(), "TOPLEFT", 0, 0)
    glow:SetPoint("BOTTOM", bar:GetStatusBarTexture(), "BOTTOMLEFT", 0, 0)
    glow:SetTexture(OVERABSORB_TEX)
    glow:Hide()
    wrapper.glow = glow

    function wrapper:SetColor(r, g, b, a)
        bar:SetStatusBarColor(r, g, b, a or 1)
    end
    function wrapper:SetTexture(name)
        bar:SetStatusBarTexture(ResolveBarTexture(name, [[Interface\Buttons\WHITE8X8]]))
    end
    -- See CreateShieldOverlayIndicator's SetGlowColor. This glow is a plain
    -- Show/Hide rather than a secret-driven alpha, so vertex alpha isn't
    -- strictly required here -- kept identical so the two behave the same and
    -- there's one rule to remember.
    function wrapper:SetGlowColor(r, g, b, a)
        glow:SetVertexColor(r or 1, g or 1, b or 1, a or 1)
    end
    return wrapper
end

-- Grid of N cooldown icons. Used by externalCooldowns, defensiveCooldowns,
-- debuffs, ccIndicator, dispels, missingBuffs (legacy fallback).
local function CreateCooldownGrid(button, name, maxSlots, supportsBorder)
    maxSlots = maxSlots or 10
    local f = CreateFrame("Frame", button:GetName() .. name, button)
    f:Hide()
    -- Capture the frame's NATIVE SetSize before we override it below, so the
    -- override can still resize the frame itself without recursing.
    local nativeSetSize = f.SetSize
    f._slots = {}
    for i = 1, maxSlots do
        local slot = CreateFrame("Frame", nil, f)
        slot:SetSize(12, 12)
        slot:Hide()
        slot.icon = slot:CreateTexture(nil, "ARTWORK")
        slot.icon:SetAllPoints()
        slot.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        slot.cooldown = CreateFrame("Cooldown", nil, slot, "CooldownFrameTemplate")
        slot.cooldown:SetAllPoints()
        slot.cooldown:SetDrawEdge(true)
        slot.cooldown:SetHideCountdownNumbers(true)
        slot.stack = slot:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        slot.stack:SetPoint("BOTTOMRIGHT", 1, -1)
        slot.stack:Hide()
        -- Optional 1px icon border, opt-in per caller. Children of `slot`
        -- (via F.CreateBorder), so they inherit its Show/Hide automatically
        -- -- SetShowBorder below only toggles their OWN shown flag once;
        -- whether they're actually visible still follows the slot's own
        -- state via the normal parent/child cascade, no extra syncing
        -- needed on every SetCooldown/ClearCooldown call.
        if supportsBorder then
            F.CreateBorder(slot, 0, 0, 0, 1, 1)
            F.SetBorderShown(slot, false)
        end
        f._slots[i] = slot
    end
    function f:SetShowBorder(show)
        for _, slot in ipairs(f._slots) do
            F.SetBorderShown(slot, show)
        end
    end
    -- Master on/off for the stack-count text (bottom-right number on each
    -- slot). Independent from the >1/secret-value gating in ApplySlotVisuals
    -- below -- this is the user's explicit override for indicators where the
    -- count is never useful (or always wanted) regardless of that logic.
    f._showStack = true
    function f:SetShowStack(show)
        f._showStack = (show ~= false)
    end
    function f:SetOrientation(orient)
        -- Lay out slots. Simplified: horizontal left-to-right.
        f._orientation = orient
        for i, slot in ipairs(f._slots) do
            slot:ClearAllPoints()
            if i == 1 then
                slot:SetPoint("TOPLEFT", f, "TOPLEFT")
            else
                local prev = f._slots[i - 1]
                if orient == "right-to-left" then
                    slot:SetPoint("TOPRIGHT", prev, "TOPLEFT", -1, 0)
                elseif orient == "top-to-bottom" then
                    slot:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -1)
                elseif orient == "bottom-to-top" then
                    slot:SetPoint("BOTTOMLEFT", prev, "TOPLEFT", 0, 1)
                else -- left-to-right / horizontal
                    slot:SetPoint("TOPLEFT", prev, "TOPRIGHT", 1, 0)
                end
            end
        end
    end
    f._normalSize = {12, 12}
    function f:SetSize(w, h)
        nativeSetSize(self, w, h)
        f._normalSize = {w, h}
        for _, slot in ipairs(f._slots) do
            if not slot._sfBig then slot:SetSize(w, h) end
        end
    end
    -- Big/priority slot size (debuffs' CC-detected entries -- see
    -- CheckDebuffs' isBig flag passed into SetCooldown below). Independent
    -- of SetSize so normal and big slots can be resized separately even
    -- though they share the same grid.
    function f:SetBigSize(w, h)
        f._bigSize = {w, h}
        for _, slot in ipairs(f._slots) do
            if slot._sfBig then slot:SetSize(w, h) end
        end
    end
    function f:SetFont(font)
        -- apply to stack fontstrings (simplified)
    end
    f:SetOrientation("left-to-right")
    -- Shared tail for SetCooldown/SetCooldownFromAura below: icon texture,
    -- stack count text, big/normal sizing, Show, and the anchor re-layout a
    -- resized slot requires. Only the cooldown-swipe half differs between
    -- the two entry points.
    local function ApplySlotVisuals(slot, icon, count, isBig, unit, auraInstanceID)
        if icon then
            slot.icon:SetTexture(icon)
        end
        -- count (info.applications) routinely goes secret in combat --
        -- comparing it to 1 directly threw ("attempt to compare... a secret
        -- number value", confirmed via a live error report) instead of
        -- returning false, which aborted the rest of this call (and, worse,
        -- the rest of that whole event pass, same cascade class as
        -- ScanAurasForCooldownGrid/CheckDispels' fixes). Three home-grown
        -- workarounds were tried here and all regressed in some way
        -- (confirmed via user reports): hiding outright whenever secret lost
        -- every real stack the instant combat started; showing unconditionally
        -- flashed a stray "1" on non-stacking debuffs; a spellStackCache
        -- "confirmed >1" cache never got a reading to learn from for
        -- combat-only debuffs (secret from their very first tick), so they
        -- never showed either.
        --
        -- C_UnitAuras.GetAuraApplicationDisplayCount(unit, auraInstanceID,
        -- minCount, maxCount) replaces all of that: it's a genuinely
        -- secret-safe Blizzard API that does the threshold comparison
        -- entirely engine-side and hands back either ready-to-display text
        -- or nil -- the actual secret count is never read/compared in Lua at
        -- all, so there's no "while secret" fallback case left to guess at.
        -- Confirmed via EllesmereUIRaidFrames' own working stack-count code
        -- (same call, same 2/99 thresholds -- "only show text once there are
        -- at least 2 stacks"), per explicit user request to match its
        -- approach instead of the cache heuristic above.
        --
        -- unit/auraInstanceID aren't available for mocked preview data (a
        -- plain Lua number count with no real aura behind it) -- fall back to
        -- the old direct comparison there, which is safe since mock counts
        -- are never secret.
        local showStack, stackText = false, nil
        if f._showStack then
            if unit and auraInstanceID and C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount then
                stackText = C_UnitAuras.GetAuraApplicationDisplayCount(unit, auraInstanceID, 2, 99)
                showStack = stackText ~= nil
            elseif count and F.IsValueNonSecret(count) then
                showStack = count > 1
            end
        end
        if showStack then
            if stackText then
                slot.stack:SetText(stackText)
            else
                slot.stack:SetFormattedText("%d", count)
            end
            slot.stack:Show()
        else
            slot.stack:Hide()
        end
        slot._sfBig = not not isBig
        local sz = (slot._sfBig and f._bigSize) or f._normalSize
        if sz then slot:SetSize(sz[1], sz[2]) end
        slot:Show()
        -- A resized slot shifts every following slot's anchor point (each
        -- anchors edge-to-edge off the previous one) -- re-run layout so the
        -- row doesn't leave a gap/overlap where a big icon changed size.
        f:SetOrientation(f._orientation or "left-to-right")
    end
    function f:SetCooldown(index, start, duration, debuffType, icon, count, isBig, unit, auraInstanceID)
        local slot = f._slots[index]
        if not slot then return end
        if start and duration and duration > 0 then
            slot.cooldown:SetCooldown(start, duration)
        else
            slot.cooldown:Clear()
        end
        ApplySlotVisuals(slot, icon, count, isBig, unit, auraInstanceID)
    end
    -- Secret-safe cooldown swipe via a LuaDurationObject instead of raw
    -- start/duration numbers -- C_UnitAuras.GetAuraDuration(unit,
    -- auraInstanceID) resolves the (possibly secret) remaining time
    -- entirely engine-side and hands the Cooldown widget an opaque object
    -- it can render directly via SetCooldownFromDurationObject, without
    -- Lua ever reading the actual number. Confirmed via EllesmereUIRaidFrames
    -- and Cell's own working External/Defensive Cooldowns implementations
    -- (both reviewed directly from their local installs, both use exactly
    -- this) -- this is what actually makes those show correctly in combat
    -- on THIS client, unlike the plain start/duration path which requires
    -- expirationTime/duration to be non-secret and just goes blank when
    -- they aren't. durObj:IsZero() (a permanent aura -- no real countdown)
    -- is likewise a secret-safe method call, never a raw comparison.
    function f:SetCooldownFromAura(index, unit, auraInstanceID, icon, count, isBig)
        local slot = f._slots[index]
        if not slot then return end
        local applied = false
        if C_UnitAuras and C_UnitAuras.GetAuraDuration and slot.cooldown.SetCooldownFromDurationObject then
            local durObj = C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
            if durObj then
                slot.cooldown:SetCooldownFromDurationObject(durObj)
                if durObj.IsZero and slot.cooldown.SetAlphaFromBoolean then
                    slot.cooldown:SetAlphaFromBoolean(durObj:IsZero(), 0, 1)
                else
                    slot.cooldown:SetAlpha(1)
                end
                applied = true
            end
        end
        if not applied then
            slot.cooldown:Clear()
        end
        ApplySlotVisuals(slot, icon, count, isBig, unit, auraInstanceID)
    end
    function f:ClearCooldown(index)
        local slot = f._slots[index]
        if slot then
            slot:Hide()
            slot.cooldown:Clear()
        end
    end
    function f:ClearAllCooldowns()
        for _, slot in ipairs(f._slots) do
            slot:Hide()
            slot.cooldown:Clear()
        end
    end
    return f
end

-- Forward-declared: defined near CheckDispels, much further down this file
-- (it needs CheckDispels as an upvalue for its live-update Set* methods) --
-- but CreateBuiltInIndicator's dispatch below needs to call it. Without this,
-- that call would resolve to a nil GLOBAL instead of the local defined later
-- (Lua locals aren't visible to code that was already parsed before they're
-- declared, even though this function only actually RUNS later).
local CreateDispelsIndicatorLegacy

-- ------------------------------------------------------------------
-- CreateBuiltInIndicator: dispatch by indicatorName
-- ------------------------------------------------------------------
function BU.CreateBuiltInIndicator(button, t)
    if not button or not t then return nil end
    local name = t.indicatorName
    local indicator

    if name == "nameText" then
        indicator = button.nameText or button:CreateFontString(nil, "ARTWORK")
        indicator._sfType = "builtin"
        GiveRegionRealFrameLevel(indicator, button)
    elseif name == "statusText" then
        indicator = button.statusText or button:CreateFontString(nil, "ARTWORK")
        indicator._sfType = "builtin"
        -- "Show Background" (checkbutton2:showBackground) had no widget
        -- consuming it at all -- a FontString can't own a texture itself
        -- (CreateTexture isn't a FontString method), so a separate texture
        -- is created here on the BACKGROUND draw layer so it always renders
        -- behind the ARTWORK-layer text. Mimics Cell's own status text
        -- background (Cell/Indicators/Built-in.lua's StatusText_SetPosition):
        -- spans the health bar's full width (not just the button) and uses
        -- the same black gradient, up to 0.777 alpha, fading in from
        -- whichever edge the text is justified toward -- rather than a flat
        -- 0.2-alpha box. Actual width/height/gradient direction are set by
        -- ApplyStatusPosition (runs on build and whenever "statusPosition"
        -- changes) since they depend on the health bar frame and the
        -- indicator's own justify, neither known yet at creation time here.
        -- Shown/hidden by ApplySettingToOne's "showBackground" branch and
        -- kept in sync with the text's own show/hide by PartyFrames.lua's
        -- UpdateStatus.
        if not indicator._sfBG then
            local bg = button:CreateTexture(nil, "BACKGROUND")
            bg:SetTexture([[Interface\Buttons\WHITE8X8]])
            bg:Hide()
            indicator._sfBG = bg
        end
    elseif name == "statusIcon" then
        indicator = CreateIconIndicator(button, "StatusIcon")
        indicator._sfType = "builtin"
    elseif name == "roleIcon" then
        -- The button template's roleIcon is a FontString (text display), which
        -- has no CreateTexture method. Always create a fresh icon Frame for the
        -- indicator rather than reusing the template child.
        indicator = CreateIconIndicator(button, "RoleIcon")
        indicator._sfType = "builtin"
    elseif name == "leaderIcon" then
        indicator = CreateIconIndicator(button, "LeaderIcon")
        indicator._sfType = "builtin"
    elseif name == "playerRaidIcon" then
        -- Same as roleIcon: create a fresh icon Frame for the indicator
        -- rather than reusing the template's raidIcon texture, so it's fully
        -- driven by this indicator's own position/size/frameLevel/alpha
        -- settings. Named "PlayerRaidIcon" (not "RaidIcon") to avoid
        -- colliding with the template's own "$parentRaidIcon" texture
        -- (parentKey="raidIcon") -- CreateFrame's explicit name argument
        -- would otherwise overwrite that global to point at this new frame
        -- instead. See PartyFrames.lua's (now-removed) legacy UpdateRaidIcon
        -- for the actual duplicate-system bug: that function independently
        -- showed the template's raidIcon texture on RAID_TARGET_UPDATE too,
        -- same "two different code paths driving the same visual" class of
        -- bug already found and fixed for nameText/statusText this session.
        indicator = CreateIconIndicator(button, "PlayerRaidIcon")
        indicator._sfType = "builtin"
        -- Base atlas set once here; CheckPlayerRaidIcon only ever adjusts
        -- which cell is visible (SetTexCoord/SetSpriteSheetCell), never
        -- re-sets the texture file itself.
        indicator.tex:SetTexture(RAID_MARKER_TEX)
    elseif name == "aggroBlink" then
        -- Solid red border around the whole button that pulses in/out --
        -- NOT LibCustomGlow's PixelGlow (a marching ring of small pixels
        -- travelling around the edge), which reads as an "ant trail" rather
        -- than a clear aggro warning. Same 4-texture border as aggroBorder,
        -- just animated instead of static.
        indicator = CreateBorderIndicator(button, "AggroBlink")
        indicator._sfType = "builtin"
        indicator:SetColor(1, 0, 0, 1)

        local anim = indicator:CreateAnimationGroup()
        anim:SetLooping("REPEAT")
        local fadeOut = anim:CreateAnimation("Alpha")
        fadeOut:SetFromAlpha(1)
        fadeOut:SetToAlpha(0.25)
        fadeOut:SetDuration(0.5)
        fadeOut:SetOrder(1)
        fadeOut:SetSmoothing("IN_OUT")
        local fadeIn = anim:CreateAnimation("Alpha")
        fadeIn:SetFromAlpha(0.25)
        fadeIn:SetToAlpha(1)
        fadeIn:SetDuration(0.5)
        fadeIn:SetOrder(2)
        fadeIn:SetSmoothing("IN_OUT")
        indicator._blinkAnim = anim

        function indicator:SetGlow(on)
            if on then
                self:SetAlpha(1)
                self:Show()
                if not anim:IsPlaying() then anim:Play() end
            else
                anim:Stop()
                self:Hide()
            end
        end
    elseif name == "aggroBorder" then
        indicator = CreateBorderIndicator(button, "AggroBorder")
        indicator._sfType = "builtin"
    elseif name == "targetHighlight" then
        indicator = CreateBorderIndicator(button, "TargetHighlight")
        indicator._sfType = "builtin"
        indicator:SetColor(1, 1, 1, 1)
    elseif name == "hoverHighlight" then
        indicator = CreateBorderIndicator(button, "HoverHighlight")
        indicator._sfType = "builtin"
        indicator:SetColor(1, 1, 1, 1)
    elseif name == "frameBorder" then
        -- Static decorative border, no Check function needed -- the generic
        -- enabled-driven Show()/Hide() in HandleIndicators' per-item loop is
        -- already the whole story for this one.
        indicator = CreateBorderIndicator(button, "FrameBorder")
        indicator._sfType = "builtin"
        indicator:SetColor(0, 0, 0, 1)
    elseif name == "shieldBar" then
        indicator = CreateBarIndicator(button, "ShieldBar")
        indicator._sfType = "builtin"
    elseif name == "shieldOverlay" then
        indicator = CreateShieldOverlayIndicator(button, t.barTexture)
        indicator._sfType = "builtin"
    elseif name == "healAbsorb" then
        indicator = CreateHealAbsorbIndicator(button, t.barTexture)
        indicator._sfType = "builtin"
    elseif name == "externalCooldowns" then
        indicator = CreateCooldownGrid(button, "ExternalCooldowns", 10)
        indicator._sfType = "builtin"
    elseif name == "defensiveCooldowns" then
        indicator = CreateCooldownGrid(button, "DefensiveCooldowns", 10)
        indicator._sfType = "builtin"
    elseif name == "healerHots" then
        -- Legacy (pre-12.1) fallback -- see CheckHealerHots.
        indicator = CreateCooldownGrid(button, "HealerHots", 10, true)
        indicator._sfType = "builtin"
    elseif name == "dispels" then
        -- Legacy (pre-12.1) fallback -- see CheckDispels/CreateDispelsIndicatorLegacy.
        indicator = CreateDispelsIndicatorLegacy(button, t)
    elseif name == "debuffs" then
        indicator = CreateCooldownGrid(button, "Debuffs", 20, true)
        indicator._sfType = "builtin"
    elseif name == "ccIndicator" then
        indicator = CreateCooldownGrid(button, "CCIndicator", 5, true)
        indicator._sfType = "builtin"
    elseif name == "missingBuffs" then
        indicator = CreateCooldownGrid(button, "MissingBuffs", 10, true)
        indicator._sfType = "builtin"
    elseif name == "healthText" then
        indicator = button.healthText or button:CreateFontString(nil, "ARTWORK")
        indicator._sfType = "builtin"
        -- Same treatment nameText gets. A FontString is a REGION: it has no
        -- SetFrameLevel at all, so HandleIndicators' generic
        -- `if t.frameLevel and indicator.SetFrameLevel` simply skipped it and
        -- the Frame Level slider did nothing -- health text could never be
        -- layered against Name Text no matter what value you set (user report
        -- 2026-08-13). GiveRegionRealFrameLevel reparents it onto a host frame
        -- and forwards SetFrameLevel/GetFrameLevel to that.
        GiveRegionRealFrameLevel(indicator, button)
    elseif name == "powerText" then
        indicator = button.powerText or button:CreateFontString(nil, "ARTWORK")
        -- Same reasoning as healthText above -- it shares the same settings
        -- shape, so it had the same dead Frame Level slider.
        GiveRegionRealFrameLevel(indicator, button)
        indicator._sfType = "builtin"
    else
        return nil
    end

    return indicator
end

-- Keeps statusText's background synced to the health bar's width and the
-- indicator's OWN current position -- mirrors Cell's StatusText background
-- (full width of the health bar, black gradient up to 0.777 alpha, fading
-- in from whichever edge the text sits nearest). NEVER moves the indicator
-- itself -- text placement is owned entirely by the normal drag/t.position
-- mechanism (ApplyPosition) shared with every other indicator. Safe to call
-- on every rebuild.
function BU.SyncStatusTextBackground(button)
    local indicator = button.statusText
    if not indicator then return end
    local bg = indicator._sfBG
    if not bg then return end
    local healthBar = button.healthBar or button

    bg:ClearAllPoints()
    bg:SetPoint("LEFT", healthBar, "LEFT", 0, 0)
    bg:SetPoint("RIGHT", healthBar, "RIGHT", 0, 0)
    bg:SetPoint("TOP", indicator, "TOP", 0, 2)
    bg:SetPoint("BOTTOM", indicator, "BOTTOM", 0, -2)

    -- Gradient fades in from whichever edge the text is actually closest to
    -- right now -- works for any drag position, not just a fixed left/right.
    local barCenter = healthBar.GetCenter and healthBar:GetCenter()
    local textCenter = indicator.GetCenter and indicator:GetCenter()
    if barCenter and textCenter and textCenter > barCenter then
        bg:SetGradient("HORIZONTAL", CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.777))
    else
        bg:SetGradient("HORIZONTAL", CreateColor(0, 0, 0, 0.777), CreateColor(0, 0, 0, 0))
    end
end

-- The "Position" dropdown (LEFT/RIGHT/TOPLEFT/TOPRIGHT/BOTTOMLEFT/
-- BOTTOMRIGHT) is a one-time "jump to this corner of the health bar" action,
-- not a second, competing position system -- it writes into the SAME
-- t.position table the free-drag preview uses, so the result persists
-- through the normal ApplyPosition path on future rebuilds. Calling this
-- unconditionally on every rebuild (the previous version of this fix) is
-- what caused the "drag snaps back" bug: dragging updates t.position, but
-- the very next rebuild (opening the panel, BuildPreview, etc) re-ran this
-- and jumped straight back to the dropdown's fixed corner, discarding the
-- drag. Now it only runs when the dropdown itself changes.
function BU.ApplyStatusPosition(button, t)
    local indicator = button.statusText
    if not indicator then return end
    local pos = t.statusPosition or "LEFT"
    local healthBar = button.healthBar or button

    t.position = {pos, "healthBar", pos, 0, 0}
    indicator:ClearAllPoints()
    indicator:SetPoint(pos, healthBar, pos, 0, 0)

    BU.SyncStatusTextBackground(button)
end

-- Post-creation setup that needs the indicator table's data.
function BU.SetupIndicator(button, t)
    -- Most built-ins don't need extra setup beyond what HandleIndicators
    -- already does (position, size, font, etc.). This hook exists for cases
    -- like aggroBorder that need their thickness/color set from the table.
    local name = t.indicatorName
    local indicator = button.indicators and button.indicators[name]
    if not indicator then return end

    if name == "aggroBorder" or name == "aggroBlink" or name == "targetHighlight"
       or name == "hoverHighlight" or name == "frameBorder" then
        if t.thickness and indicator.SetThickness then
            indicator:SetThickness(t.thickness)
        end
    elseif name == "statusText" then
        -- Position itself was already applied earlier in HandleIndicators'
        -- per-item loop (the generic `if t.position then ApplyPosition(...)
        -- end` block) -- only the background needs re-syncing here.
        BU.SyncStatusTextBackground(button)
    elseif name == "roleIcon" then
        -- Apply initial role texture from settings
        BU.CheckRoleIcon(button)
    end
end

-- ------------------------------------------------------------------
-- CheckRoleIcon - must be defined before SetupIndicator uses it
-- ------------------------------------------------------------------
function BU.CheckRoleIcon(button)
    local unit = button.unit or button:GetAttribute("unit")
    local indicator = button.indicators and button.indicators.roleIcon
    if not indicator then return end
    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then indicator:Hide() return end

    local roleTexture = t.roleTexture or "default"
    local roleKey
    -- For preview button, use fake role; otherwise use real unit role
    if button._sfFakeRole then
        roleKey = button._sfFakeRole
    elseif unit then
        -- F.GetRoleKey gates UnitGroupRolesAssigned against a secret return
        -- (12.1), falls back to the player's own SPEC role when no group role
        -- is assigned (solo), and normalizes anything still unknown to DAMAGER.
        roleKey = F.GetRoleKey(unit)
    else
        roleKey = "DAMAGER"
    end
    indicator:SetIcon(F.GetRoleTextureByRole(roleTexture, roleKey))
end

-- ------------------------------------------------------------------
-- Per-built-in Check functions (driven by events)
-- ------------------------------------------------------------------

-- Name Text: respects indicator settings for color, textWidth, etc.
local function CheckNameText(button)
    local unit = button.unit or button:GetAttribute("unit")
    if not unit then return end
    local indicator = button.indicators and button.indicators.nameText
    if not indicator then return end
    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then indicator:Hide() return end

    -- For preview button, use fake name/class data
    local name, classFile
    if button._sfFakeName then
        name = button._sfFakeName
        classFile = button._sfFakeClass
    else
        -- Nicknames module returns a PLAIN string or nil, never a secret --
        -- see the contract documented at the top of Nicknames.lua. nil falls
        -- through to the ordinary path below, which stays byte-identical to
        -- what ran before nicknames existed (and is the only branch that is
        -- safe once the unit's identity goes secret).
        local Nicknames = SquizzFrames.Nicknames
        name = Nicknames and Nicknames:Resolve(unit) or nil
        if not name then
            name = F.UnitFullName(unit, t.hideRealmName)
        end
        classFile = F.GetClassFile(unit)
    end

    -- showGroupNumber: prefix the name with the unit's raid subgroup (1-8),
    -- e.g. "[2] Playername". Only meaningful in a raid -- a plain 4-person
    -- party has no subgroup concept, so this is a no-op there (matches how
    -- Blizzard's own raid frames only show group numbers in raid content).
    -- Was previously captured by the options UI (checkbox, label, DB write,
    -- re-render trigger) but never actually read here -- the checkbox did
    -- nothing.
    --
    -- SECRET-VALUE HANDLING (12.1): every value this block touches can be
    -- secret once the unit's identity is restricted, and BOTH operations used
    -- here -- a truthiness test and a concatenation -- throw on a secret
    -- rather than returning something harmless. That's the same crash class
    -- PetFrames.lua:127-131 documents for `UnitName(unit) or ""`. The
    -- original code did `UnitInRaid(unit)` as an `elseif` condition (a
    -- truthiness test), concatenated `subgroup`, and finished with
    -- `(name or "")` -- three separate ways to take down the whole name
    -- update mid-raid, which is exactly when this option is in use.
    --
    -- So each step is gated independently rather than trusting the one
    -- before it: UnitInRaid joined the secret-when-identity-restricted set in
    -- 12.1, and GetRaidRosterInfo's returns inherit the secrecy of the index
    -- it was handed.
    if t.showGroupNumber then
        local groupNum
        if button._sfFakeName then
            groupNum = 1 -- demo value so the preview shows a visible change
        elseif UnitInRaid then
            -- F.IsValueNonSecret returns false for nil too, so this single
            -- gate covers "not in a raid" as well as "secret".
            local raidIndex = UnitInRaid(unit)
            if F.IsValueNonSecret(raidIndex) then
                local _, _, subgroup = GetRaidRosterInfo(raidIndex)
                if F.IsValueNonSecret(subgroup) then
                    groupNum = subgroup
                end
            end
        end
        -- `name` may itself be secret -- F.UnitFullName passes one straight
        -- through precisely so SetText can consume it C-side. Nothing can be
        -- concatenated onto that, so the prefix is skipped and the bare name
        -- still renders. Losing the group number beats losing the name.
        if groupNum and F.IsValueNonSecret(name) then
            name = "[" .. groupNum .. "] " .. name
        end
    end

    -- Color: class_color / custom_color / power_color
    if t.color and t.color[1] == "class_color" then
        -- classFile (UnitClass's return) went secret-when-identity-restricted
        -- in Patch 12.1.0 -- F.IsValueNonSecret must gate the table index,
        -- same fix as F.GetClassColor.
        if classFile and F.IsValueNonSecret(classFile) then
            local c = RAID_CLASS_COLORS[classFile]
            if c then indicator:SetVertexColor(c.r, c.g, c.b, 1) end
        else
            indicator:SetVertexColor(1, 1, 1, 1)
        end
    elseif t.color and t.color[1] == "custom_color" and #t.color >= 3 then
        local r, g, b = t.color[2], t.color[3], t.color[4] or 1
        local a = t.color[5] or 1
        indicator:SetVertexColor(r, g, b, a)
    elseif t.color and t.color[1] == "power_color" then
        -- F.GetPowerColor gates the PowerBarColor table index against a
        -- secret UnitPowerType return (12.1) and always returns a table.
        local c = F.GetPowerColor(unit)
        indicator:SetVertexColor(c.r, c.g, c.b, 1)
    else
        indicator:SetVertexColor(1, 1, 1, 1)
    end

    -- textWidth: unlimited / percentage / length
    if t.textWidth then
        local mode = t.textWidth[1]
        if mode == "unlimited" then
            indicator:SetWidth(0)  -- 0 = unlimited in WoW
        elseif mode == "percentage" then
            local pct = t.textWidth[2] or 0.75
            local parent = indicator:GetParent()
            local refFrame = t.position and t.position[2] == "healthBar" and button.healthBar or button
            if refFrame then
                indicator:SetWidth(refFrame:GetWidth() * pct)
            else
                indicator:SetWidth(parent:GetWidth() * pct)
            end
        elseif mode == "length" then
            indicator:SetWidth(t.textWidth[2] or 50)
        end
    else
        indicator:SetWidth(0)
    end
    -- A constrained width word-wraps by default, growing the FontString to 2+
    -- lines that spill into whatever else is anchored nearby (looks exactly
    -- like "the text is behind/cut off by something else"). Single-line only.
    indicator:SetWordWrap(false)

    -- Justify text based on anchor point so text doesn't shift when width changes
    -- CENTER anchor needs CENTER justify to expand from center
    local anchorPoint = t.position and t.position[1] or "CENTER"
    if anchorPoint == "CENTER" then
        indicator:SetJustifyH("CENTER")
    elseif anchorPoint == "LEFT" then
        indicator:SetJustifyH("LEFT")
    elseif anchorPoint == "RIGHT" then
        indicator:SetJustifyH("RIGHT")
    end

    indicator:SetText(name)
    indicator:Show()

    -- Store updater for options panel to call on textWidth/showGroupNumber/hideRealmName/vehicleNamePosition/color changes
    indicator._sfNameUpdater = function() CheckNameText(button) end
end

local function CheckStatusText(button) end  -- text, updated by PartyFrames

local function CheckHealthText(button)
    local unit = button.unit or button:GetAttribute("unit")
    if not unit then return end
    local indicator = button.indicators and button.indicators.healthText
    if not indicator then return end
    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then indicator:Hide() return end

    -- UnitHealth/UnitHealthMax can be secret numbers in combat. The previous
    -- "pcall(function() return val + 0 end)" sanitize THROWS whenever the
    -- value genuinely is secret (arithmetic on a secret errors), so the
    -- pcall failed, curHP/maxHP stayed nil, and the indicator hid itself --
    -- exactly when a real value should have been showing. Confirmed against
    -- EllesmereUIRaidFrames (same PTR client, working): pass
    -- UnitHealth(unit, true) straight to AbbreviateNumbers with NO
    -- arithmetic at all, and use UnitHealthPercent (a C-level, secret-safe
    -- API) for the percentage instead of computing curHP/maxHP*100 in Lua
    -- (division on a secret also throws).
    --
    -- AbbreviateNumbers' RETURN STRING inherits the secret taint too, so
    -- even comparing that string against "" ("text ~= ''", used to decide
    -- whether a separator is needed) throws "attempt to compare a secret
    -- string value". Nil-checks (plain "if x then") on a secret are fine --
    -- confirmed by this exact code not erroring on those -- but equality/
    -- inequality comparisons are not. So the live branch below tracks
    -- presence with plain (never-secret) booleans set via those safe
    -- nil-checks, and only ever CONCATENATES the secret-derived strings,
    -- never compares them.
    local text
    if button._sfFakeHealth and button._sfFakeHealthMax then
        -- Preview only: F.ShortNumber (pure Lua, Utils.lua), NOT
        -- AbbreviateNumbers. These fake values are always plain, known
        -- numbers -- never actually secret -- but AbbreviateNumbers appears
        -- to be flagged by Blizzard as "may return a secret" at the API
        -- level regardless of input, and just calling it seems to
        -- permanently mark the FontString it's fed into as tainted for
        -- later geometry reads (confirmed: nameText's preview text, which
        -- never touches AbbreviateNumbers, never hit this; healthText/
        -- powerText's did, even with these hardcoded numbers). The live
        -- branch below still has to use AbbreviateNumbers -- a real
        -- UnitHealth(unit, true) value can genuinely be secret, and no Lua
        -- arithmetic is allowed on it -- but the preview never needs that.
        local curHP, maxHP = button._sfFakeHealth, button._sfFakeHealthMax
        text = ""
        if t.showCurrent then text = F.ShortNumber(curHP) end
        if t.showMax then text = text .. (text ~= "" and " / " or "") .. F.ShortNumber(maxHP) end
        if t.showPercentage then
            local pct = maxHP > 0 and math.floor(curHP / maxHP * 100 + 0.5) or 0
            text = text .. (text ~= "" and " " or "") .. pct .. "%"
        end
        if text == "" then text = F.ShortNumber(curHP) end
    else
        local hasCur, curStr = false, nil
        if t.showCurrent then
            local curr = UnitHealth(unit, true)
            if curr and AbbreviateNumbers then
                curStr = AbbreviateNumbers(curr)
                hasCur = true
            end
        end
        local hasMax, maxStr = false, nil
        if t.showMax then
            local max = UnitHealthMax(unit, true)
            if max and AbbreviateNumbers then
                maxStr = AbbreviateNumbers(max)
                hasMax = true
            end
        end
        local hasPct, pctStr = false, nil
        if t.showPercentage and UnitHealthPercent and CurveConstants then
            local pct = UnitHealthPercent(unit, true, CurveConstants.ScaleTo100)
            if pct then
                pctStr = string.format("%.0f%%", pct)
                hasPct = true
            end
        end

        if hasCur and hasMax and hasPct then
            text = curStr .. " / " .. maxStr .. " " .. pctStr
        elseif hasCur and hasMax then
            text = curStr .. " / " .. maxStr
        elseif hasCur and hasPct then
            text = curStr .. " " .. pctStr
        elseif hasMax and hasPct then
            text = maxStr .. " " .. pctStr
        elseif hasCur then
            text = curStr
        elseif hasMax then
            text = maxStr
        elseif hasPct then
            text = pctStr
        else
            -- Nothing toggled on (or all reads failed) -- fall back to plain
            -- current health, matching the old behavior's final fallback.
            local curr = UnitHealth(unit, true)
            if curr and AbbreviateNumbers then text = AbbreviateNumbers(curr) end
        end
    end

    if not text then indicator:Hide() return end
    indicator:SetText(text)

    -- Color
    -- For preview button, use fake class data
    local classFile
    if button._sfFakeClass then
        classFile = button._sfFakeClass
    else
        _, classFile = UnitClass(unit)
    end

    if t.color and t.color[1] == "class_color" then
        -- classFile went secret-when-identity-restricted in Patch 12.1.0 --
        -- F.IsValueNonSecret must gate the table index, same fix as
        -- F.GetClassColor/CheckNameText.
        local color = F.IsValueNonSecret(classFile) and RAID_CLASS_COLORS[classFile]
        if color then indicator:SetTextColor(color.r, color.g, color.b) end
    elseif t.color and t.color[1] == "power_color" then
        -- See F.GetPowerColor -- gates the table index against a secret
        -- UnitPowerType return on 12.1.
        local color = F.GetPowerColor(unit)
        indicator:SetTextColor(color.r, color.g, color.b)
    elseif t.color and t.color[1] == "custom_color" and #t.color >= 4 then
        indicator:SetTextColor(t.color[2], t.color[3], t.color[4], t.color[5] or 1)
    else
        indicator:SetTextColor(1, 1, 1)
    end

    -- Text width handling. IMPORTANT: always explicitly SetWidth() at the
    -- end, even on a malformed/unrecognized width[1] -- a saved override
    -- like {nil, 1} (width[1] genuinely nil; can happen from an old/partial
    -- save) matches none of the three modes below, and previously that
    -- meant NO SetWidth() call at all, leaving the FontString to size
    -- itself naturally from its own text content instead. That mattered
    -- here specifically: this text comes from AbbreviateNumbers(), and
    -- letting the FontString's rendered width be driven by that text
    -- (rather than an explicit, plain pixel width) is what left this
    -- indicator's geometry permanently unreadable via GetWidth()/GetHeight()
    -- elsewhere (the Designer's drag-highlight/marching-ants) -- explicitly
    -- setting a fallback width sidesteps that regardless of the exact
    -- mechanism.
    local function ApplyTextWidth()
        local width = t.textWidth
        local refFrame = indicator:GetParent()
        local parentW = (refFrame and refFrame.GetWidth and refFrame:GetWidth()) or 0
        if width == "unlimited" or (type(width) == "table" and width[1] == "unlimited") then
            indicator:SetWidth(0)  -- 0 = unlimited in WoW
            return
        elseif type(width) == "table" and width[1] == "percentage" then
            local pct = width[2] or 0.75
            if parentW > 0 then
                indicator:SetWidth(parentW * pct)
                return
            end
        elseif type(width) == "table" and width[1] == "length" then
            indicator:SetWidth(width[2] or 50)
            return
        end
        -- Fallback for nil/malformed textWidth (or a zero-width parent):
        -- 75% of parent width, same as the built-in default, so this
        -- indicator is never left to size itself from its own text.
        indicator:SetWidth(parentW > 0 and (parentW * 0.75) or 50)
    end
    ApplyTextWidth()
    -- Single-line only -- see the matching comment in CheckNameText.
    indicator:SetWordWrap(false)
    -- Same reasoning as ApplyTextWidth's fallback above, but for height:
    -- a FontString's height is derived automatically from its rendered
    -- content unless explicitly set, and this text comes from
    -- AbbreviateNumbers(). Explicitly pinning it to a plain, font-size-based
    -- pixel value (never read back from the FontString itself) keeps its
    -- geometry fully independent of the text content.
    indicator:SetHeight((t.font and t.font[2] or 11) + 4)

    -- Justify text based on anchor point so text doesn't shift when width changes
    -- CENTER anchor needs CENTER justify to expand from center
    local anchorPoint = t.position and t.position[1] or "CENTER"
    if anchorPoint == "CENTER" then
        indicator:SetJustifyH("CENTER")
    elseif anchorPoint == "LEFT" then
        indicator:SetJustifyH("LEFT")
    elseif anchorPoint == "RIGHT" then
        indicator:SetJustifyH("RIGHT")
    end

    -- Font handled by HandleIndicators
    indicator:Show()

    -- Store updater for options panel
    indicator._sfNameUpdater = function() CheckHealthText(button) end
end

local function CheckPowerText(button)
    local unit = button.unit or button:GetAttribute("unit")
    if not unit then return end
    local indicator = button.indicators and button.indicators.powerText
    if not indicator then return end
    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then indicator:Hide() return end

    -- UnitPower/UnitPowerMax can be secret numbers too -- same fix as
    -- CheckHealthText above. Unlike UnitHealth, Ellesmere does NOT call
    -- UnitPower/UnitPowerMax with a trailing "true" (confirmed by reading
    -- its actual power-bar code: "local pmx = UnitPowerMax(unit, pType)",
    -- no 3rd arg) -- it passes the unit's real pType (from UnitPowerType)
    -- and feeds the result straight to AbbreviateNumbers with NO arithmetic.
    -- UnitPowerPercent still takes the same secret-safe C-level path as
    -- UnitHealthPercent for the percentage.
    --
    -- AbbreviateNumbers' return string inherits the secret taint too, so
    -- comparing it against "" (to decide whether a separator is needed)
    -- throws "attempt to compare a secret string value" -- see
    -- CheckHealthText's comment for the full explanation. Same fix here:
    -- track presence with plain booleans from safe nil-checks, only
    -- concatenate the secret-derived strings, never compare them.
    local text
    if button._sfFakePower and button._sfFakePowerMax then
        -- Preview only: F.ShortNumber, not AbbreviateNumbers -- see the
        -- matching comment in CheckHealthText's fake-data branch above.
        local curPower, maxPower = button._sfFakePower, button._sfFakePowerMax
        text = ""
        if t.showCurrent then text = F.ShortNumber(curPower) end
        if t.showMax then text = text .. (text ~= "" and " / " or "") .. F.ShortNumber(maxPower) end
        if t.showPercentage then
            local pct = maxPower > 0 and math.floor(curPower / maxPower * 100 + 0.5) or 0
            text = text .. (text ~= "" and " " or "") .. pct .. "%"
        end
        if text == "" then text = F.ShortNumber(curPower) end
    else
        local pType = UnitPowerType(unit)
        local hasCur, curStr = false, nil
        if t.showCurrent then
            local curr = UnitPower(unit, pType)
            if curr and AbbreviateNumbers then
                curStr = AbbreviateNumbers(curr)
                hasCur = true
            end
        end
        local hasMax, maxStr = false, nil
        if t.showMax then
            local max = UnitPowerMax(unit, pType)
            if max and AbbreviateNumbers then
                maxStr = AbbreviateNumbers(max)
                hasMax = true
            end
        end
        local hasPct, pctStr = false, nil
        if t.showPercentage and UnitPowerPercent and CurveConstants then
            local pct = UnitPowerPercent(unit, pType, true, CurveConstants.ScaleTo100)
            if pct then
                pctStr = string.format("%.0f%%", pct)
                hasPct = true
            end
        end

        if hasCur and hasMax and hasPct then
            text = curStr .. " / " .. maxStr .. " " .. pctStr
        elseif hasCur and hasMax then
            text = curStr .. " / " .. maxStr
        elseif hasCur and hasPct then
            text = curStr .. " " .. pctStr
        elseif hasMax and hasPct then
            text = maxStr .. " " .. pctStr
        elseif hasCur then
            text = curStr
        elseif hasMax then
            text = maxStr
        elseif hasPct then
            text = pctStr
        else
            local curr = UnitPower(unit, pType)
            if curr and AbbreviateNumbers then text = AbbreviateNumbers(curr) end
        end
    end

    if not text then indicator:Hide() return end
    indicator:SetText(text)

    -- Color
    -- For preview button, use fake class data
    local classFile
    if button._sfFakeClass then
        classFile = button._sfFakeClass
    else
        _, classFile = UnitClass(unit)
    end

    if t.color and t.color[1] == "class_color" then
        -- classFile went secret-when-identity-restricted in Patch 12.1.0 --
        -- F.IsValueNonSecret must gate the table index, same fix as
        -- F.GetClassColor/CheckNameText.
        local color = F.IsValueNonSecret(classFile) and RAID_CLASS_COLORS[classFile]
        if color then indicator:SetTextColor(color.r, color.g, color.b) end
    elseif t.color and t.color[1] == "power_color" then
        -- See F.GetPowerColor -- gates the table index against a secret
        -- UnitPowerType return on 12.1.
        local color = F.GetPowerColor(unit)
        indicator:SetTextColor(color.r, color.g, color.b)
    elseif t.color and t.color[1] == "custom_color" and #t.color >= 4 then
        indicator:SetTextColor(t.color[2], t.color[3], t.color[4], t.color[5] or 1)
    else
        indicator:SetTextColor(1, 1, 1)
    end

    -- Text width handling. IMPORTANT: always explicitly SetWidth() at the
    -- end, even on a malformed/unrecognized width[1] -- a saved override
    -- like {nil, 1} (width[1] genuinely nil; can happen from an old/partial
    -- save) matches none of the three modes below, and previously that
    -- meant NO SetWidth() call at all, leaving the FontString to size
    -- itself naturally from its own text content instead. That mattered
    -- here specifically: this text comes from AbbreviateNumbers(), and
    -- letting the FontString's rendered width be driven by that text
    -- (rather than an explicit, plain pixel width) is what left this
    -- indicator's geometry permanently unreadable via GetWidth()/GetHeight()
    -- elsewhere (the Designer's drag-highlight/marching-ants) -- explicitly
    -- setting a fallback width sidesteps that regardless of the exact
    -- mechanism.
    local function ApplyTextWidth()
        local width = t.textWidth
        local refFrame = indicator:GetParent()
        local parentW = (refFrame and refFrame.GetWidth and refFrame:GetWidth()) or 0
        if width == "unlimited" or (type(width) == "table" and width[1] == "unlimited") then
            indicator:SetWidth(0)  -- 0 = unlimited in WoW
            return
        elseif type(width) == "table" and width[1] == "percentage" then
            local pct = width[2] or 0.75
            if parentW > 0 then
                indicator:SetWidth(parentW * pct)
                return
            end
        elseif type(width) == "table" and width[1] == "length" then
            indicator:SetWidth(width[2] or 50)
            return
        end
        -- Fallback for nil/malformed textWidth (or a zero-width parent):
        -- 75% of parent width, same as the built-in default, so this
        -- indicator is never left to size itself from its own text.
        indicator:SetWidth(parentW > 0 and (parentW * 0.75) or 50)
    end
    ApplyTextWidth()
    -- Single-line only -- see the matching comment in CheckNameText.
    indicator:SetWordWrap(false)
    -- Same reasoning as ApplyTextWidth's fallback above, but for height:
    -- a FontString's height is derived automatically from its rendered
    -- content unless explicitly set, and this text comes from
    -- AbbreviateNumbers(). Explicitly pinning it to a plain, font-size-based
    -- pixel value (never read back from the FontString itself) keeps its
    -- geometry fully independent of the text content.
    indicator:SetHeight((t.font and t.font[2] or 11) + 4)

    -- Justify text based on anchor point so text doesn't shift when width changes
    -- CENTER anchor needs CENTER justify to expand from center
    local anchorPoint = t.position and t.position[1] or "CENTER"
    if anchorPoint == "CENTER" then
        indicator:SetJustifyH("CENTER")
    elseif anchorPoint == "LEFT" then
        indicator:SetJustifyH("LEFT")
    elseif anchorPoint == "RIGHT" then
        indicator:SetJustifyH("RIGHT")
    end

    -- Font handled by HandleIndicators
    indicator:Show()

    -- Store updater for options panel
    indicator._sfNameUpdater = function() CheckPowerText(button) end
end

-- Ready Check: GetReadyCheckStatus(unit) is the live source of truth, but it
-- does NOT reliably keep returning a real status once the check ends -- it
-- goes back to nil almost immediately (bug fix 2026-07-31, user report: icons
-- vanishing the instant everyone responds despite the decay timer below).
-- Confirmed via Blizzard's own real source
-- (Blizzard_UnitFrame/Shared/CompactUnitFrame.lua's
-- CompactUnitFrame_UpdateReadyCheck): their reference implementation guards
-- against exactly this by checking GetReadyCheckTimeLeft() <= 0 and, once
-- true, simply NOT re-querying GetReadyCheckStatus at all -- the icon just
-- keeps showing whatever it last resolved to until the decay timer expires.
-- This addon's CheckStatusIcon previously had no such guard: it re-queried
-- GetReadyCheckStatus fresh on every call, so ANY routine update during the
-- 11-second decay window (health ticks, roster events, etc -- constant in a
-- group) would hit the now-nil status and blank the icon immediately,
-- regardless of button._sfReadyCheckActive or the decay timer still running.
-- Fixed the same way Blizzard does: cache the last resolved icon
-- (button._sfReadyCheckIcon) and stop re-querying once GetReadyCheckTimeLeft()
-- says the check itself is over, falling back to the cached icon instead.
-- button._sfReadyCheckActive still gates whether CheckStatusIcon looks at
-- ready-check status at all, so the icon doesn't linger forever.
-- StartReadyCheck/ConfirmReadyCheck/FinishReadyCheck below are wired to
-- READY_CHECK/READY_CHECK_CONFIRM/READY_CHECK_FINISHED in eventMap.
local READY_CHECK_DECAY_TIME = 4 -- user-requested (2026-07-31): 3-4s, not Blizzard's 11s default

local function CheckStatusIcon(button)
    local unit = button.unit or button:GetAttribute("unit")
    if not unit then return end
    local indicator = button.indicators and button.indicators.statusIcon
    if not indicator then return end
    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then indicator:Hide() return end

    -- Ready Check takes priority over AFK/Dead/etc while active/decaying --
    -- that's the more relevant thing to show during a ready check. Skipped
    -- for the Designer preview (button._sfFakeIsConnected ~= nil marks it --
    -- see the branch just below), which never receives real ready-check
    -- events. Classic (pre-atlas) texture paths -- same convention this
    -- function's other icons already use (ConnectIcon/StatusIcon-Away/
    -- RaidIcon-Skull), and confirmed still valid/in active use by both Cell
    -- and DandersFrames (reviewed directly from their local installs).
    if button._sfReadyCheckActive and button._sfFakeIsConnected == nil and GetReadyCheckStatus then
        -- Once the check's own timer has run out, mirror Blizzard exactly:
        -- stop re-querying (it's unreliable past this point) and just keep
        -- showing whatever was last resolved, until the decay timer clears
        -- _sfReadyCheckActive entirely.
        local checkIsOver = GetReadyCheckTimeLeft and GetReadyCheckTimeLeft() <= 0
        if checkIsOver and button._sfReadyCheckIcon then
            indicator:SetIcon(button._sfReadyCheckIcon)
            return
        end

        local status = GetReadyCheckStatus(unit)
        if status == "ready" then
            button._sfReadyCheckIcon = [[Interface\RaidFrame\ReadyCheck-Ready]]
            indicator:SetIcon(button._sfReadyCheckIcon)
            return
        elseif status == "notready" then
            button._sfReadyCheckIcon = [[Interface\RaidFrame\ReadyCheck-NotReady]]
            indicator:SetIcon(button._sfReadyCheckIcon)
            return
        elseif status == "waiting" then
            -- Once the check is over, an unanswered "waiting" reads as
            -- not-ready instead (matches Blizzard's own
            -- CompactUnitFrame_FinishReadyCheck: "If you haven't responded,
            -- you are not ready").
            button._sfReadyCheckIcon = checkIsOver
                and [[Interface\RaidFrame\ReadyCheck-NotReady]]
                or [[Interface\RaidFrame\ReadyCheck-Waiting]]
            indicator:SetIcon(button._sfReadyCheckIcon)
            return
        elseif checkIsOver and button._sfReadyCheckIcon then
            -- status came back nil (the unreliable case this fix targets),
            -- but the check is already over and we have a cached icon --
            -- keep showing it rather than falling through to AFK/Dead/etc.
            indicator:SetIcon(button._sfReadyCheckIcon)
            return
        end
        -- status nil AND no cached icon: no ready-check info for this unit
        -- at all (e.g. they weren't in the group when it started) -- fall
        -- through to the normal AFK/Dead/etc display below.
    end

    -- For preview button, use fake status data
    local isConnected, isAFK, isDead, isGhost
    if button._sfFakeIsConnected ~= nil then
        isConnected = button._sfFakeIsConnected
        isAFK = button._sfFakeIsAFK
        isDead = button._sfFakeIsDead
        isGhost = button._sfFakeIsGhost
    else
        isConnected = UnitIsConnected(unit)
        -- UnitIsAFK can return a secret boolean for group units on this
        -- client (UnitIsConnected/UnitIsDead/UnitIsGhost don't -- confirmed
        -- against EllesmereUIRaidFrames, same PTR client) -- guard with
        -- issecretvalue() before the elseif branch below boolean-tests it.
        isAFK = not issecretvalue(UnitIsAFK(unit)) and UnitIsAFK(unit)
        isDead = UnitIsDead(unit)
        isGhost = UnitIsGhost(unit)
    end

    if not isConnected then
        indicator:SetIcon([[Interface\CharacterFrame\ConnectIcon]])
    elseif isAFK then
        indicator:SetIcon([[Interface\FriendsFrame\StatusIcon-Away]])
    elseif isDead then
        indicator:SetIcon([[Interface\RaidFrame\RaidIcon-Skull]])
    elseif isGhost then
        indicator:SetIcon([[Interface\RaidFrame\RaidIcon-Skull]])
    else
        indicator:SetIcon(nil)
    end
end

-- READY_CHECK has no unit of its own (payload is initiatorName/timeLeft) --
-- Indicators.lua's OnEvent forces it to broadcast to every button (see its
-- comment), so this runs once per button, each already knowing its own unit.
local function StartReadyCheck(button)
    if not button then return end
    button._sfReadyCheckActive = true
    button._sfReadyCheckIcon = nil -- clear any cached icon left over from a previous check
    CheckStatusIcon(button)
end

-- READY_CHECK_CONFIRM DOES carry a real unit (unitTarget), so this only ever
-- runs for the button whose unit just responded.
local function ConfirmReadyCheck(button)
    if not button or not button._sfReadyCheckActive then return end
    CheckStatusIcon(button)
end

-- READY_CHECK_FINISHED also has no real unit (payload is `preempted`) and is
-- likewise forced to broadcast. Re-checks immediately (some units may have
-- gone straight from "waiting" to a final status), then lets the icon linger
-- for READY_CHECK_DECAY_TIME before clearing -- matching Blizzard's own UX
-- (CompactUnitFrame_FinishReadyCheck) rather than either snapping instantly
-- to nothing or (worse) never clearing since GetReadyCheckStatus itself never
-- goes stale on its own.
local function FinishReadyCheck(button)
    if not button or not button._sfReadyCheckActive then return end
    CheckStatusIcon(button)
    C_Timer.After(READY_CHECK_DECAY_TIME, function()
        if not button._sfReadyCheckActive then return end
        button._sfReadyCheckActive = false
        button._sfReadyCheckIcon = nil
        CheckStatusIcon(button)
    end)
end

local function CheckLeaderIcon(button)
    local unit = button.unit or button:GetAttribute("unit")
    if not unit then return end
    local indicator = button.indicators and button.indicators.leaderIcon
    if not indicator then return end
    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then indicator:Hide() return end

    -- For preview button, use fake leader data
    local isLeader, isAssistant
    if button._sfFakeLeader ~= nil then
        isLeader = button._sfFakeLeader
        isAssistant = button._sfFakeAssistant
    else
        isLeader = UnitIsGroupLeader(unit)
        isAssistant = not isLeader and UnitIsGroupAssistant(unit)
    end
    if isLeader then
        indicator:SetIcon("Interface\\GroupFrame\\UI-Group-LeaderIcon")
    elseif isAssistant then
        indicator:SetIcon("Interface\\GroupFrame\\UI-Group-AssistantIcon")
    else
        indicator:SetIcon(nil)
    end
end

local function CheckPlayerRaidIcon(button)
    local unit = button.unit or button:GetAttribute("unit")
    if not unit then return end
    local indicator = button.indicators and button.indicators.playerRaidIcon
    if not indicator then return end
    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then indicator:Hide() return end

    -- For preview button, use fake raid icon
    local index
    if button._sfFakeRaidIcon then
        index = button._sfFakeRaidIcon
    else
        index = GetRaidTargetIndex(unit)
    end
    -- Only a nil-check is safe on a possibly-secret index (GetRaidTargetIndex
    -- never returns 0 for "no marker" -- nil means none -- so a nil-check
    -- alone is enough to decide show/hide).
    if index then
        if issecretvalue(index) then
            if indicator.tex.SetSpriteSheetCell then
                pcall(indicator.tex.SetSpriteSheetCell, indicator.tex, index, 4, 4, 64, 64)
            end
        elseif RAID_MARKER_TEXCOORDS[index] then
            local tc = RAID_MARKER_TEXCOORDS[index]
            indicator.tex:SetTexCoord(tc[1], tc[2], tc[3], tc[4])
        end
        indicator:Show()
    else
        indicator:Hide()
    end
end

local function CheckAggroBlink(button)
    local unit = button.unit or button:GetAttribute("unit")
    if not unit then return end
    local indicator = button.indicators and button.indicators.aggroBlink
    if not indicator then return end
    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then
        indicator:SetGlow(false)
        return
    end

    -- For preview button, use fake threat
    local threat
    if button._sfFakeThreat ~= nil then
        threat = button._sfFakeThreat
    else
        threat = UnitThreatSituation(unit)
    end
    -- Secret-gated (2026-08-07): comparing a secret number against a
    -- literal throws on 12.1. Treat an unreadable threat level as "not
    -- tanking" rather than erroring out of the whole check pass.
    indicator:SetGlow(F.IsValueNonSecret(threat) and threat == 3)
end

local function CheckAggroBorder(button)
    local unit = button.unit or button:GetAttribute("unit")
    if not unit then return end
    local indicator = button.indicators and button.indicators.aggroBorder
    if not indicator then return end
    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then indicator:Hide() return end

    -- For preview button, use fake threat
    local threat
    if button._sfFakeThreat ~= nil then
        threat = button._sfFakeThreat
    else
        threat = UnitThreatSituation(unit)
    end
    -- See CheckAggroBlink above -- same secret-comparison gate.
    if F.IsValueNonSecret(threat) and threat == 3 then
        indicator:Show()
    else
        indicator:Hide()
    end
end

function BU.CheckTargetHighlight(button)
    local unit = button.unit or button:GetAttribute("unit")
    if not unit then return end
    local indicator = button.indicators and button.indicators.targetHighlight
    if not indicator then return end
    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then indicator:Hide() return end

    -- Hover takes visual priority over target -- mirrors
    -- EllesmereUIRaidFrames' own single-border priority (hover > target),
    -- so the two never draw stacked on top of each other.
    if button._sfHovered then indicator:Hide() return end

    -- For preview button, use a fake target state.
    local isTarget
    if button._sfFakeTarget ~= nil then
        isTarget = button._sfFakeTarget
    else
        isTarget = UnitIsUnit(unit, "target")
    end
    -- SetShownFromBoolean, not `if isTarget then` (2026-08-07). UnitIsUnit
    -- joins the secret-value set in 12.1, and a SECRET false is TRUTHY in
    -- Lua -- so a plain truthiness test doesn't error, it silently produces
    -- the WRONG answer (target border stuck on for every unit). The
    -- SetXFromBoolean family resolves the boolean at C level where secrets
    -- are handled natively; this file already uses SetAlphaFromBoolean the
    -- same way for absorb clamping. Plain-boolean fallback for the preview
    -- path / clients without the API.
    if indicator.SetShownFromBoolean then
        indicator:SetShownFromBoolean(isTarget)
    elseif isTarget then
        indicator:Show()
    else
        indicator:Hide()
    end
end
local CheckTargetHighlight = BU.CheckTargetHighlight

function BU.CheckHoverHighlight(button)
    local indicator = button.indicators and button.indicators.hoverHighlight
    if not indicator then return end
    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then indicator:Hide() return end

    if button._sfHovered then
        -- 12.1 PTR ONLY: re-assert the full-button anchor on every hover-in.
        -- User-reported bug (2026-07-28): this border renders in a small,
        -- consistently-wrong spot on PTR while Target Highlight (identical
        -- CreateBorderIndicator/SetAllPoints(button) call, same button) is
        -- correct, and retail renders THIS SAME indicator/code/data
        -- correctly too (confirmed via the retail<->PTR junction -- byte-
        -- identical files). Also confirmed NOT a stray t.position override
        -- via direct SavedVariables inspection (none present). Hover is the
        -- only one of the two that toggles on every single mouse enter/leave
        -- (Target Highlight only changes on a rare target swap), so this is
        -- scoped as a defensive re-anchor on the hover trigger specifically,
        -- not a change to shared/legacy behavior -- retail is unaffected
        -- since IS_121 is false there.
        if SquizzFrames.IS_121 then
            indicator:ClearAllPoints()
            indicator:SetAllPoints(button)
        end
        indicator:Show()
    else
        indicator:Hide()
    end
end
local CheckHoverHighlight = BU.CheckHoverHighlight

local function CheckShieldBar(button)
    local unit = button.unit or button:GetAttribute("unit")
    if not unit then return end
    local indicator = button.indicators and button.indicators.shieldBar
    if not indicator then return end
    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then indicator:Hide() return end

    -- Keep width synced to the button (layout width changes, e.g. the width
    -- slider, don't otherwise touch this bar -- see CreateBarIndicator).
    local buttonWidth = button:GetWidth()
    if buttonWidth and buttonWidth > 0 and indicator:GetWidth() ~= buttonWidth then
        indicator:SetWidth(buttonWidth)
    end

    if button._sfFakeHealthMax then
        -- Designer preview: synthetic demo shield. The player's own live
        -- absorb is usually 0 while designing, which would render as an
        -- empty/invisible bar and look broken.
        local maxHP = button._sfFakeHealthMax
        indicator:SetMinMaxValues(0, maxHP)
        indicator:SetValue(t.onlyShowOvershields and maxHP or (maxHP * 0.25))
        indicator:SetAlpha(1)
        indicator:Show()
        return
    end

    -- UnitGetTotalAbsorbs/UnitHealthMax can be "secret numbers" in combat.
    -- Feed them straight into SetMinMaxValues/SetValue (secret-safe at the C
    -- level) without any Lua-side arithmetic/comparison -- confirmed against
    -- EllesmereUIRaidFrames' working UpdateAbsorb on this same PTR client.
    local maxHP, isClamped = ReadHealPredData(button, unit)
    local absorbs = (UnitGetTotalAbsorbs and UnitGetTotalAbsorbs(unit)) or 0
    indicator:SetMinMaxValues(0, maxHP)
    indicator:SetValue(absorbs)
    if t.onlyShowOvershields then
        -- isClamped may itself be secret; SetAlphaFromBoolean is the
        -- secret-safe way to branch on it (no plain "if isClamped").
        if indicator.SetAlphaFromBoolean then
            indicator:SetAlphaFromBoolean(isClamped, 1, 0)
        else
            indicator:SetAlpha(0)
        end
    else
        indicator:SetAlpha(1)
    end
    indicator:Show()
end

-- Centers the narrow overshield-glow strip ON whichever edge of the fill
-- texture is CURRENTLY the shield's leading edge -- the RIGHT edge for
-- normal (left-to-right) fill, the LEFT edge for reverse fill (which fills
-- from the right, growing leftward, so its leading edge is on the left) --
-- rather than placing it flush OUTSIDE that edge. Flush placement (this
-- function's first version) left a visible gap between the shield pattern
-- and the glow (confirmed via user report + screenshot: the fill texture's
-- reported edge doesn't exactly coincide with where the shield pattern
-- visually appears to end, likely due to the tiled hatch texture's own
-- rendering). Anchoring the glow's TOP/BOTTOM (its horizontal center points)
-- directly to the fill texture's corner makes the glow straddle the edge --
-- half overlapping into the shield, half extending beyond it -- which is
-- also the more typical look for this kind of effect, and is robust to
-- small discrepancies in exactly where the "true" edge sits instead of
-- depending on pixel-perfect alignment. Anchored relative to the fill
-- texture (not the wrapper), so once set it tracks the shield's current
-- value automatically as the fill texture resizes.
local function ApplyShieldGlowAnchor(indicator, reverseFill)
    local fillTex = indicator.bar:GetStatusBarTexture()
    indicator.glow:ClearAllPoints()
    if reverseFill then
        indicator.glow:SetWidth(OVERSHIELD_TEX_R_WIDTH)
        indicator.glow:SetPoint("TOP", fillTex, "TOPLEFT", 0, 0)
        indicator.glow:SetPoint("BOTTOM", fillTex, "BOTTOMLEFT", 0, 0)
    else
        indicator.glow:SetWidth(OVERSHIELD_TEX_WIDTH)
        indicator.glow:SetPoint("TOP", fillTex, "TOPRIGHT", 0, 0)
        indicator.glow:SetPoint("BOTTOM", fillTex, "BOTTOMRIGHT", 0, 0)
    end
end

local function CheckShieldOverlay(button)
    local unit = button.unit or button:GetAttribute("unit")
    if not unit then return end
    local indicator = button.indicators and button.indicators.shieldOverlay
    if not indicator then return end
    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then indicator:Hide() return end

    -- Re-measure the power bar / frame border insets before showing: neither
    -- fires anything this indicator listens to when it changes.
    AnchorInsideHealth(indicator)

    indicator.bar:SetReverseFill(not not t.reverseFill)

    if button._sfFakeHealthMax then
        -- Designer preview: synthetic demo shield. The player's own live
        -- absorb is usually 0 while designing, which would render as an
        -- empty/invisible bar and look broken. No real isClamped is
        -- available for a fake unit, so the glow just previews at full
        -- alpha whenever the toggle is on.
        local maxHP = button._sfFakeHealthMax
        indicator.bar:SetMinMaxValues(0, maxHP)
        indicator.bar:SetValue(maxHP * 0.3)
        if t.showOvershieldGlow then
            indicator.glow:SetTexture(t.reverseFill and OVERSHIELD_TEX_R or OVERSHIELD_TEX)
            if indicator.ReapplyGlowColor then indicator:ReapplyGlowColor() end
            ApplyShieldGlowAnchor(indicator, t.reverseFill)
            indicator.glow:SetAlpha(1)
            indicator.glow:Show()
        else
            indicator.glow:Hide()
        end
        indicator:Show()
        return
    end

    -- UnitGetTotalAbsorbs/UnitHealthMax can be "secret numbers" in combat.
    -- Feed them straight into SetMinMaxValues/SetValue (secret-safe at the C
    -- level) without any Lua-side arithmetic/comparison, and use the
    -- heal-prediction calculator's isClamped (also secret-safe, applied via
    -- SetAlphaFromBoolean) for overshield detection instead of comparing
    -- health+absorbs > maxHealth by hand -- confirmed against
    -- EllesmereUIRaidFrames' working UpdateAbsorb on this same PTR client.
    local maxHP, isClamped = ReadHealPredData(button, unit)
    local absorbs = (UnitGetTotalAbsorbs and UnitGetTotalAbsorbs(unit)) or 0

    indicator.bar:SetMinMaxValues(0, maxHP)
    indicator.bar:SetValue(absorbs)

    if t.showOvershieldGlow then
        indicator.glow:SetTexture(t.reverseFill and OVERSHIELD_TEX_R or OVERSHIELD_TEX)
        if indicator.ReapplyGlowColor then indicator:ReapplyGlowColor() end
        ApplyShieldGlowAnchor(indicator, t.reverseFill)
        indicator.glow:Show()
        if indicator.glow.SetAlphaFromBoolean then
            indicator.glow:SetAlphaFromBoolean(isClamped, 1, 0)
        else
            indicator.glow:Hide()
        end
    else
        indicator.glow:Hide()
    end

    indicator:Show()
end

local function CheckHealAbsorb(button)
    local unit = button.unit or button:GetAttribute("unit")
    if not unit then return end
    local indicator = button.indicators and button.indicators.healAbsorb
    if not indicator then return end
    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then indicator:Hide() return end

    -- See CheckShieldOverlay -- same live re-measure, same reason.
    AnchorInsideHealth(indicator)

    if button._sfFakeHealthMax then
        -- Designer preview: synthetic demo heal-absorb (the player's own
        -- live value is usually 0 while designing).
        local health = button._sfFakeHealth or button._sfFakeHealthMax
        indicator.bar:SetMinMaxValues(0, health)
        indicator.bar:SetValue(health * 0.2)
        if t.showOverAbsorbGlow then indicator.glow:Show() else indicator.glow:Hide() end
        indicator:Show()
        return
    end

    -- UnitHealth/UnitGetTotalHealAbsorbs can be "secret numbers" in combat.
    -- Feed them straight into SetMinMaxValues/SetValue without any Lua-side
    -- arithmetic/comparison (matches CheckShieldOverlay/EllesmereUIRaidFrames
    -- above). There's no confirmed secret-safe "fully capped" boolean for
    -- heal absorb (unlike GetDamageAbsorbs' isClamped for shields), so the
    -- glow instead just tracks the bar's own fill -- see the factory, where
    -- its texture is anchored to the StatusBar's fill texture rather than
    -- the full wrapper, collapsing to nothing whenever the bar itself does.
    local health = UnitHealth(unit) or 0
    local healAbsorbs = (UnitGetTotalHealAbsorbs and UnitGetTotalHealAbsorbs(unit)) or 0

    indicator.bar:SetMinMaxValues(0, health)
    indicator.bar:SetValue(healAbsorbs)

    if t.showOverAbsorbGlow then indicator.glow:Show() else indicator.glow:Hide() end

    indicator:Show()
end

-- Aura-based checkers (externals, defensives, debuffs, ccIndicator, dispels,
-- missingBuffs) all scan C_UnitAuras. A single unified scan in Custom_Dispatch
-- handles custom indicators; for built-ins we do a focused scan here.

-- Preview-only fallback: real cooldown/aura data is usually empty while
-- designing (no active combat), which would otherwise leave the preview
-- blank. Populates slot 1 with a representative icon so sizing/position/
-- orientation can still be judged. Gated on preview buttons (the Designer's
-- mock frame and the group preview window's) -- never runs for a real party
-- member's frame.
local function ShowPreviewFallbackIcon(button, indicator, icon)
    local IndicatorsModule = SquizzFrames.Indicators
    if not IndicatorsModule or not IndicatorsModule.IsPreviewButton(button) or not icon then return false end
    -- Mock a >1 stack count so the stack-count text actually renders in the
    -- preview -- it's real user-facing text (font/position adjustable like
    -- any other indicator element), but a nil count here meant it could
    -- never be seen/positioned while designing. SetShowStack's own gate
    -- still applies on top of this, so it correctly stays hidden here too
    -- when the user has that setting turned off.
    indicator:SetCooldown(1, 0, 0, nil, icon, 3)
    return true
end

local function ScanAurasForCooldownGrid(button, indicatorName, spellIDs, maxSlots, auraFilter, castByMe)
    local unit = button.unit or button:GetAttribute("unit")
    if not unit then return end
    local indicator = button.indicators and button.indicators[indicatorName]
    if not indicator then return end
    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then indicator:Hide() return end

    if not maxSlots then maxSlots = t.num or 5 end

    -- The preview button's unit is the REAL "player" (see GetPreviewButton),
    -- so C_UnitAuras calls here would scan REAL aura data -- which can be
    -- secret mid-combat/in a group. That's not just unsafe for THIS
    -- function (already guarded via F.IsValueNonSecret below); a secret
    -- touched anywhere during the same CheckAll(button) pass can taint the
    -- rest of that call, corrupting unrelated frame-geometry reads later in
    -- the SAME pass (confirmed: this was the actual cause of the Designer's
    -- drag-highlight throwing "attempt to compare/perform arithmetic on a
    -- secret number, while execution tainted by 'SquizzFrames'" even though
    -- the geometry code itself has nothing to do with auras). The preview
    -- never needs real aura data anyway -- skip the scan entirely and go
    -- straight to the mockup fallback icon.
    local IndicatorsModule = SquizzFrames.Indicators
    if IndicatorsModule and IndicatorsModule.IsPreviewButton(button) then
        if ShowPreviewFallbackIcon(button, indicator, spellIDs[1] and F.GetSpellIcon(spellIDs[1])) then
            indicator:Show()
        else
            indicator:Hide()
        end
        return
    end

    -- Build a set of wanted spell IDs for quick lookup.
    local wantSet = {}
    for _, id in ipairs(spellIDs) do wantSet[id] = true end

    local shown = 0
    -- C_UnitAuras.GetAuraDataBySpellId does not exist on this client
    -- (confirmed via debug print while chasing an unrelated Drinking-status
    -- bug) -- every call here silently no-opped, so External/Defensive
    -- Cooldowns never actually showed anything live. Scan by index instead
    -- (same API CheckDebuffs already uses successfully) and bucket matches
    -- by spellId, then still emit them in spellIDs' original priority order
    -- below so the visible ordering doesn't change from before.
    -- castByMe is folded into the FILTER STRING ("|PLAYER", a real Blizzard
    -- aura-filter token) rather than read back off info.sourceUnit after the
    -- fact -- comparing a possibly-secret field to a literal ("player") is
    -- exactly the class of bug that broke Healer HoTs in combat (see
    -- CheckHealerHots' comment): the comparison throws instead of returning
    -- false, and since nothing here catches it, the throw aborts every
    -- OTHER check still queued after this one in the same event/CheckAll
    -- pass. Filtering server-side never touches the secret value at all.
    local scanFilter = auraFilter .. (castByMe and "|PLAYER" or "")

    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local found = {}
        local i = 1
        while i <= 40 do
            local ok, info = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, scanFilter)
            if not ok then
                -- This slot's data is secret and the call threw -- skip just
                -- this one index and keep scanning; breaking here would cut
                -- off every aura after the first secret one mid-list (this
                -- exact bug caused Missing Buffs to falsely show everything
                -- absent in combat -- see CheckMissingBuffs for the full fix).
                i = i + 1
            elseif not info then
                break -- genuinely past the last aura
            else
                i = i + 1
                -- info.spellId itself commonly goes secret in combat (a buff
                -- cast by someone other than the unit -- confirmed via a live
                -- error report: "attempted to index a table that cannot be
                -- indexed with secret keys" on wantSet[info.spellId] below).
                -- F.IsValueNonSecret MUST gate every indexing use of it, same
                -- fix CheckMissingBuffs' presentSet already applies -- a raw
                -- `info.spellId and wantSet[info.spellId]` truthy-checks fine
                -- but then hard-errors on the actual table index, and since
                -- nothing here catches it, that error aborted every OTHER
                -- Check queued after this one in the same event/CheckAll pass.
                if F.IsValueNonSecret(info.spellId) and wantSet[info.spellId] and F.IsValueNonSecret(info.isHelpful) and not found[info.spellId] then
                    found[info.spellId] = info
                end
            end
        end
        for _, spellId in ipairs(spellIDs) do
            if shown >= maxSlots then break end
            local info = found[spellId]
            if info then
                local start, duration = 0, 0
                if F.IsValueNonSecret(info.expirationTime) and F.IsValueNonSecret(info.duration) then
                    duration = info.duration or 0
                    start = (info.expirationTime or 0) - duration
                end
                indicator:SetCooldown(shown + 1, start, duration, nil, info.icon, info.applications, nil, unit, info.auraInstanceID)
                shown = shown + 1
            end
        end
    end
    for i = shown + 1, maxSlots do
        indicator:ClearCooldown(i)
    end
    if shown > 0 then
        indicator:Show()
    elseif ShowPreviewFallbackIcon(button, indicator, spellIDs[1] and F.GetSpellIcon(spellIDs[1])) then
        indicator:Show()
    else
        indicator:Hide()
    end
end

-- Legacy (pre-12.1) fallback for External/Defensive Cooldowns using
-- Blizzard's own EXTERNAL_DEFENSIVE/BIG_DEFENSIVE aura filter
-- classifications via C_UnitAuras.IsAuraFilteredOutByInstanceID -- the same
-- technique this file's CC_DEBUFF_FILTER/IsAuraCC already uses for Crowd
-- Control -- instead of matching a curated spell-ID list, which was the
-- actual reason these went blank in combat (confirmed via a live error
-- report + this session's earlier ScanAurasForCooldownGrid fix: info.spellId
-- itself routinely goes secret in combat, and there is no safe way to test
-- an unknown secret value against a known list). The filter check only ever
-- touches auraInstanceID (routinely readable, per Custom_Dispatch.lua's own
-- comment) and returns a plain boolean -- the actual (secret) classification
-- is resolved entirely engine-side and never exposed to Lua.
--
-- BIG_DEFENSIVE covers BOTH self-cast defensives AND externals cast by
-- others; EXTERNAL_DEFENSIVE covers only the externals. Defensive Cooldowns
-- (self-cast) is therefore BIG_DEFENSIVE minus EXTERNAL_DEFENSIVE -- an aura
-- can never count as both, so nothing double-shows across the two
-- indicators. Confirmed via Cell (Indicators/Built-in.lua + RaidFrames/
-- UnitButton.lua's HandleBuff) and EllesmereUIRaidFrames (UpdateDefensives)
-- -- both reviewed directly from their local installs, both use exactly
-- this as their own pre-12.1 fallback (EllesmereUI's real gate is
-- ns.RFC_OwnsDefensives, the AuraContainer path -- this function is what it
-- falls back to below that), and the user directly confirmed Cell's version
-- keeps working in combat where this addon's old curated-list scan didn't.
--
-- wantSet (the effective curated+custom-minus-hidden spell list, same as
-- before the filter-based rewrite) and Blizzard's classification are two
-- INDEPENDENT paths to a match, gated purely on whether info.spellId is
-- readable -- never combined as a narrowing AND. Blizzard's own
-- classification has confirmed gaps: EllesmereUIRaidFrames' own comment
-- notes EXTERNAL_DEFENSIVE omits Blessing of Freedom, and user reports
-- confirmed more here (Pain Suppression showing on Cell but not here despite
-- a correct curated spellID; same for Protective Light on Defensive
-- Cooldowns) -- an earlier version of this function trusted the
-- classification FIRST and only let wantSet narrow a positive match, which
-- meant a classification gap could never be rescued by the user's own
-- (verified-correct) list even when spellId was perfectly readable. Trusting
-- wantSet directly whenever spellId is readable restores exact pre-rewrite
-- behavior for every curated/custom entry, gap or not; Blizzard's
-- classification only takes over once spellId goes secret (typical
-- mid-combat), where it's the sole secret-safe signal left -- a
-- classification gap can still cause a miss THERE specifically, but that's
-- a narrower problem than "nothing shows in combat at all".
local function ScanAurasForDefensiveFilter(button, indicatorName, wantExternal, wantSet)
    local unit = button.unit or button:GetAttribute("unit")
    if not unit then return end
    local indicator = button.indicators and button.indicators[indicatorName]
    if not indicator then return end
    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then indicator:Hide() return end

    -- An empty effective list (e.g. "Use Default Spells" off with no custom
    -- additions) means the user explicitly wants NOTHING shown -- respect
    -- that even in combat, rather than falling back to Blizzard's
    -- classification alone (which would otherwise ignore this and show
    -- every externally-classified aura anyway once spellId goes secret).
    if not next(wantSet) then indicator:Hide() return end

    local maxSlots = t.num or 5

    -- Same preview-taint reasoning as ScanAurasForCooldownGrid above: the
    -- preview button's unit is the REAL "player", so scanning it here reads
    -- REAL (possibly secret) data that can taint the rest of the same
    -- CheckAll(button) pass.
    local IndicatorsModule = SquizzFrames.Indicators
    if IndicatorsModule and IndicatorsModule.IsPreviewButton(button) then
        local firstIcon
        for id in pairs(wantSet) do firstIcon = F.GetSpellIcon(id); if firstIcon then break end end
        if ShowPreviewFallbackIcon(button, indicator, firstIcon) then
            indicator:Show()
        else
            indicator:Hide()
        end
        return
    end

    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex and C_UnitAuras.IsAuraFilteredOutByInstanceID) then
        indicator:Hide()
        return
    end

    local shown = 0
    local i = 1
    while i <= 40 do
        -- Same secret-slot handling as every other scan in this file: skip
        -- just this index on failure, don't break the whole scan.
        local ok, info = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
        if not ok then
            i = i + 1
        elseif not info then
            break -- genuinely past the last aura
        else
            i = i + 1
            if shown < maxSlots then
                local iid = info.auraInstanceID
                if F.IsValueNonSecret(iid) then
                    local matched
                    if F.IsValueNonSecret(info.spellId) then
                        -- spellId readable -- trust the user's own curated/
                        -- custom/hidden list directly, exactly like before
                        -- this function existed (see header comment: this is
                        -- what lets Pain Suppression/Protective Light-style
                        -- classification gaps still show correctly whenever
                        -- it's actually possible to check the real spell ID).
                        matched = wantSet[info.spellId] or false
                    else
                        -- spellId secret (typical mid-combat) -- the only
                        -- secret-safe signal left is Blizzard's own
                        -- classification.
                        local isExternal = not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, iid, "HELPFUL|EXTERNAL_DEFENSIVE")
                        if wantExternal then
                            -- EXTERNAL_DEFENSIVE alone misses offensive/utility
                            -- externals that aren't damage-reduction focused
                            -- (Power Infusion, a haste buff -- confirmed via
                            -- user report: shows correctly in combat on Cell
                            -- but not here). Cell's own fallback (reviewed
                            -- directly from its local install) adds a third,
                            -- broader "HELPFUL|RAID" tier and defaults
                            -- anything that passes it to "external" (its own
                            -- further disambiguation against "defensive" only
                            -- covers 3 hardcoded Paladin cooldown-variant
                            -- spell IDs via a recent-self-cast memory this
                            -- addon doesn't track -- an acceptable narrower
                            -- gap than missing Power Infusion entirely).
                            -- Scoped to External Cooldowns only -- Defensive
                            -- Cooldowns keeps the narrower, more reliably-
                            -- tagged BIG_DEFENSIVE classification so it
                            -- doesn't fill up with unrelated raid buffs.
                            if not isExternal then
                                isExternal = not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, iid, "HELPFUL|RAID")
                            end
                            matched = isExternal
                        else
                            local isBigDef = not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, iid, "HELPFUL|BIG_DEFENSIVE")
                            matched = isBigDef and not isExternal
                        end
                    end
                    if matched then
                        shown = shown + 1
                        indicator:SetCooldownFromAura(shown, unit, iid, info.icon, info.applications, nil)
                    end
                end
            end
        end
    end
    for j = shown + 1, maxSlots do
        indicator:ClearCooldown(j)
    end
    if shown > 0 then
        indicator:Show()
    else
        indicator:Hide()
    end
end

local function CheckExternalCooldowns(button)
    local indicator = button.indicators and button.indicators.externalCooldowns
    if not indicator then return end
    -- AuraContainer-backed wrapper (AuraEngineIndicators.lua) updates itself
    -- via the engine's own UNIT_AURA handling -- it has no ClearCooldown/
    -- SetCooldown methods, so running the legacy scan against it throws
    -- "attempt to call a nil value". Only fall through to the legacy scan
    -- for the pre-12.1 CreateCooldownGrid fallback, which lacks RefreshSpellList.
    if indicator.RefreshSpellList then return end

    local t = indicator._sfTable or indicator.configs
    -- Re-synced every check pass -- see CheckMissingBuffs' identical comment
    -- on showIconBorder (cheap; SetShowStack is just a per-slot flag flip).
    if indicator.SetShowStack then
        indicator:SetShowStack(t and t.showStack)
    end
    local spellIDs = t and F.GetEffectiveSpellList(t.useBuiltInExternals, externalCooldowns, t.customExternals, t.hiddenBuiltInExternals) or externalCooldowns
    local wantSet = {}
    for _, id in ipairs(spellIDs) do wantSet[id] = true end
    ScanAurasForDefensiveFilter(button, "externalCooldowns", true, wantSet)
end

local function CheckDefensiveCooldowns(button)
    local indicator = button.indicators and button.indicators.defensiveCooldowns
    if not indicator then return end
    -- See CheckExternalCooldowns above.
    if indicator.RefreshSpellList then return end

    local t = indicator._sfTable or indicator.configs
    -- Re-synced every check pass -- see CheckExternalCooldowns above.
    if indicator.SetShowStack then
        indicator:SetShowStack(t and t.showStack)
    end
    local spellIDs = t and F.GetEffectiveSpellList(t.useBuiltInDefensives, defensiveCooldowns, t.customDefensives, t.hiddenBuiltInDefensives) or defensiveCooldowns
    local wantSet = {}
    for _, id in ipairs(spellIDs) do wantSet[id] = true end
    ScanAurasForDefensiveFilter(button, "defensiveCooldowns", false, wantSet)
end

-- Healer HoTs' curated list is class-keyed (SquizzFrames.defaults.healerSpells)
-- and only the VIEWING PLAYER's own class is relevant (a Priest can never
-- cast a Druid HoT) -- mirrors AuraEngineIndicators.lua's identical
-- GetPlayerClassHealerSpells (that file is inert pre-12.1, so this can't just
-- call into it -- computed fresh here too; cheap, ~10-12 entries).
local function GetPlayerClassHealerSpellsLegacy()
    local playerClass = F.GetClassFile and F.GetClassFile("player")
    local classTable = SquizzFrames.defaults and SquizzFrames.defaults.healerSpells
    local spellSet = (playerClass and classTable and classTable[playerClass]) or {}
    return F.FlattenSpellTable({ spellSet })
end

-- Legacy (pre-12.1) fallback for Healer HoTs -- AuraEngineIndicators.lua's
-- CreateHealerHotsIndicator/AuraEngine.lua are both inert on pre-12.1
-- clients, so Indicators.lua's I.CreateIndicator falls through to
-- BuiltIn.CreateBuiltInIndicator's plain CreateCooldownGrid for this
-- indicator there. Same scan shape as CheckExternalCooldowns/
-- CheckDefensiveCooldowns, plus the castBy=="me" source filter (see
-- ScanAurasForCooldownGrid's castByMe param).
local function CheckHealerHots(button)
    local indicator = button.indicators and button.indicators.healerHots
    if not indicator then return end
    -- See CheckExternalCooldowns above -- only fall through for the legacy
    -- CreateCooldownGrid fallback, which lacks RefreshSpellList.
    if indicator.RefreshSpellList then return end

    local t = indicator._sfTable or indicator.configs
    local baseList = GetPlayerClassHealerSpellsLegacy()
    local spellIDs = t and F.GetEffectiveSpellList(t.useBuiltInHots, baseList, nil, t.hiddenBuiltInHots) or baseList
    ScanAurasForCooldownGrid(button, "healerHots", spellIDs, nil, "HELPFUL", t and t.castBy == "me")
end

-- Crowd-control aura filter (Blizzard's own CROWD_CONTROL aura filter tag,
-- same one EllesmereUIRaidFrames uses for its CC glow -- see ns._ccDebuffFilter
-- in that addon). "Big Debuff Priority" delegates entirely to this instead of
-- a hand-maintained spell list: Blizzard updates which debuffs count as CC
-- every patch/dungeon/raid tier, so this stays accurate for free.
local CC_DEBUFF_FILTER = "HARMFUL|" ..
    ((AuraUtil and AuraUtil.AuraFilters and AuraUtil.AuraFilters.CrowdControl) or "CROWD_CONTROL")

local function IsAuraCC(unit, auraInstanceID)
    if not auraInstanceID or not F.IsValueNonSecret(auraInstanceID) then return false end
    if not C_UnitAuras or not C_UnitAuras.IsAuraFilteredOutByInstanceID then return false end
    local ok, filteredOut = pcall(C_UnitAuras.IsAuraFilteredOutByInstanceID, unit, auraInstanceID, CC_DEBUFF_FILTER)
    return ok and not filteredOut
end

local function CheckDebuffs(button)
    local indicator = button.indicators and button.indicators.debuffs
    if not indicator then return end
    -- AuraContainer-backed wrapper (AuraEngineIndicators.lua) updates itself
    -- via the engine's own presence-driven Show/Hide -- it has no
    -- SetCooldown/ClearCooldown, so running the legacy scan against it
    -- throws "attempt to call a nil value". Only fall through to the legacy
    -- scan for the pre-12.1 CreateCooldownGrid fallback, which lacks
    -- RefreshFilters. See CheckExternalCooldowns for the identical guard.
    if indicator.RefreshFilters then return end

    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then indicator:Hide() return end

    -- Re-synced every check pass -- see CheckMissingBuffs' identical comment.
    if indicator.SetShowBorder then
        indicator:SetShowBorder(t.showIconBorder ~= false)
    end
    if indicator.SetShowStack then
        indicator:SetShowStack(t.showStack)
    end

    local unit = button.unit or button:GetAttribute("unit")
    if not unit then return end

    -- Same reasoning as ScanAurasForCooldownGrid above: the preview button's
    -- unit is the REAL "player", so this scan reads REAL (possibly secret)
    -- aura data even while "designing" -- and a secret touched here can
    -- taint the rest of the same CheckAll(button) pass, corrupting
    -- unrelated frame-geometry reads later in it (the Designer's
    -- drag-highlight). Skip straight to the mockup fallback for the preview.
    local IndicatorsModule = SquizzFrames.Indicators
    if IndicatorsModule and IndicatorsModule.IsPreviewButton(button) then
        if ShowPreviewFallbackIcon(button, indicator, [[Interface\Icons\INV_Misc_QuestionMark]]) then
            indicator:Show()
        else
            indicator:Hide()
        end
        return
    end

    local maxSlots = t.num or 3

    -- "Dispellable By Me" delegates to Blizzard's own RAID_PLAYER_DISPELLABLE
    -- filter token (same approach Dispels already uses in AuraEngineIndicators)
    -- instead of reading the (secret-prone) dispel type ourselves.
    local filter = "HARMFUL" .. (t.dispellableByMe and "|RAID_PLAYER_DISPELLABLE" or "")

    local blacklistSet
    if t.debuffBlacklist and #t.debuffBlacklist > 0 then
        blacklistSet = {}
        for _, id in ipairs(t.debuffBlacklist) do blacklistSet[id] = true end
    end

    -- Collect every matching debuff first (rather than stopping at maxSlots)
    -- so CC-priority sorting below can pick the right ones when there are
    -- more debuffs active than slots to show them in.
    local collected = {}
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local i = 1
        while i <= 40 do
            -- GetAuraDataByIndex can throw if THIS SPECIFIC slot's data is
            -- secret while our call stack is tainted (e.g. mid-combat) --
            -- skip just that index and keep scanning, don't break the whole
            -- loop (a `break` here previously cut off every debuff after the
            -- first secret one mid-list -- the exact bug that caused Missing
            -- Buffs to falsely show everything absent in combat).
            local ok, info = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, filter)
            if not ok then
                i = i + 1
            elseif not info then
                break -- genuinely past the last aura
            else
                i = i + 1
                -- info.spellId must be secret-checked before indexing
                -- blacklistSet with it -- see ScanAurasForCooldownGrid's
                -- identical fix/comment (live error report: "attempted to
                -- index a table that cannot be indexed with secret keys").
                if F.IsValueNonSecret(info.isHelpful)
                    and not (blacklistSet and F.IsValueNonSecret(info.spellId) and blacklistSet[info.spellId]) then
                    local start, duration = 0, 0
                    if F.IsValueNonSecret(info.expirationTime) and F.IsValueNonSecret(info.duration) then
                        duration = info.duration or 0
                        start = (info.expirationTime or 0) - duration
                    end
                    local isBig = t.bigDebuffCC and IsAuraCC(unit, info.auraInstanceID)
                    collected[#collected + 1] = {
                        start = start, duration = duration, dispelName = info.dispelName,
                        icon = info.icon, count = info.applications, isBig = isBig,
                        auraInstanceID = info.auraInstanceID,
                    }
                end
            end
        end
    end

    -- Stable-sort CC/"big" debuffs to the front so they claim the visible
    -- slots first when there isn't room for everything.
    if t.bigDebuffCC then
        local ordered, big, normal = {}, {}, {}
        for _, e in ipairs(collected) do
            if e.isBig then big[#big + 1] = e else normal[#normal + 1] = e end
        end
        for _, e in ipairs(big) do ordered[#ordered + 1] = e end
        for _, e in ipairs(normal) do ordered[#ordered + 1] = e end
        collected = ordered
    end

    local shown = 0
    for _, e in ipairs(collected) do
        if shown >= maxSlots then break end
        -- SetCooldownFromAura (C_UnitAuras.GetAuraDuration + a
        -- LuaDurationObject, per its own comment above) keeps the swipe
        -- animating through combat -- the plain start/duration path used
        -- here before requires expirationTime/duration themselves to be
        -- non-secret, and just goes blank the moment they aren't (the exact
        -- "swipe not displaying in combat" report). auraInstanceID is
        -- routinely readable even when duration/expirationTime aren't (same
        -- reasoning as isBig's IsAuraCC call just above), so this covers the
        -- normal case; SetCooldown is still the fallback for the rare miss.
        if indicator.SetCooldownFromAura and e.auraInstanceID then
            indicator:SetCooldownFromAura(shown + 1, unit, e.auraInstanceID, e.icon, e.count, e.isBig)
        else
            indicator:SetCooldown(shown + 1, e.start, e.duration, e.dispelName, e.icon, e.count, e.isBig, unit, e.auraInstanceID)
        end
        shown = shown + 1
    end
    for j = shown + 1, maxSlots do
        indicator:ClearCooldown(j)
    end
    if shown > 0 then
        indicator:Show()
    -- Debuffs has no curated spell list to draw a representative icon from
    -- (it shows whatever's really on the unit) -- generic placeholder instead.
    elseif ShowPreviewFallbackIcon(button, indicator, [[Interface\Icons\INV_Misc_QuestionMark]]) then
        indicator:Show()
    else
        indicator:Hide()
    end
end

-- CC Indicator: was "Raid Debuffs" -- a stub that never populated its own
-- indicator at all (it delegated to CheckDebuffs, which reads/writes
-- button.indicators.debuffs, a completely different object; enabling this
-- indicator had zero visible effect). Rebuilt as a real CC-only tracker: the
-- scan filter is CC_DEBUFF_FILTER itself (defined above IsAuraCC), so
-- C_UnitAuras.GetAuraDataByIndex enumerates ONLY crowd-control-tagged
-- debuffs directly -- no separate curated spell list, no post-hoc
-- filtering, and it stays accurate for free as Blizzard updates which
-- effects count as CC each patch/dungeon/raid tier.
local function CheckCCIndicator(button)
    local indicator = button.indicators and button.indicators.ccIndicator
    if not indicator then return end
    -- AuraContainer-backed wrapper (AuraEngineIndicators.lua) updates itself
    -- via the engine's own presence-driven Show/Hide -- it has no
    -- SetCooldown/ClearCooldown, so running the legacy scan against it
    -- throws "attempt to call a nil value". SetDurationMode only exists on
    -- the AuraEngine wrapper (unlike SetShowBorder, which both variants now
    -- have) so it's the distinguishing marker here -- see
    -- CheckExternalCooldowns for the identical guard pattern.
    if indicator.SetDurationMode then return end

    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then indicator:Hide() return end

    -- Re-synced every check pass -- see CheckMissingBuffs' identical comment.
    if indicator.SetShowBorder then
        indicator:SetShowBorder(t.showIconBorder ~= false)
    end
    if indicator.SetShowStack then
        indicator:SetShowStack(t.showStack)
    end

    local unit = button.unit or button:GetAttribute("unit")
    if not unit then return end

    -- Same reasoning as CheckDebuffs: the preview button's unit is the REAL
    -- "player", so a real scan here could taint the rest of the same
    -- CheckAll(button) pass.
    local IndicatorsModule = SquizzFrames.Indicators
    if IndicatorsModule and IndicatorsModule.IsPreviewButton(button) then
        if ShowPreviewFallbackIcon(button, indicator, [[Interface\Icons\Spell_Frost_ChainsOfIce]]) then
            indicator:Show()
        else
            indicator:Hide()
        end
        return
    end

    local maxSlots = t.num or 1
    local shown = 0
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local i = 1
        while i <= 40 do
            -- Same secret-slot handling as CheckDebuffs/CheckMissingBuffs:
            -- skip just this index on failure, don't break the whole scan.
            local ok, info = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, CC_DEBUFF_FILTER)
            if not ok then
                i = i + 1
            elseif not info then
                break -- genuinely past the last aura
            else
                i = i + 1
                if F.IsValueNonSecret(info.isHelpful) and shown < maxSlots then
                    -- See CheckDebuffs' identical fix/comment: SetCooldownFromAura
                    -- keeps the swipe animating through combat instead of going
                    -- blank the moment expirationTime/duration go secret.
                    if indicator.SetCooldownFromAura and info.auraInstanceID then
                        indicator:SetCooldownFromAura(shown + 1, unit, info.auraInstanceID, info.icon, info.applications, nil)
                    else
                        local start, duration = 0, 0
                        if F.IsValueNonSecret(info.expirationTime) and F.IsValueNonSecret(info.duration) then
                            duration = info.duration or 0
                            start = (info.expirationTime or 0) - duration
                        end
                        indicator:SetCooldown(shown + 1, start, duration, info.dispelName, info.icon, info.applications, nil, unit, info.auraInstanceID)
                    end
                    shown = shown + 1
                end
            end
        end
    end
    for j = shown + 1, maxSlots do
        indicator:ClearCooldown(j)
    end
    if shown > 0 then
        indicator:Show()
    else
        indicator:Hide()
    end
end

-- Dispels: on 12.1 this is rebuilt on AuraEngine (12.1 AuraContainer) in
-- AuraEngineIndicators.lua, mirroring EllesmereUI's architecture: per-type
-- health-bar overlay/icon slots instead of a manual C_UnitAuras scan, so it
-- stays accurate through combat secrecy without ever reading the (secret)
-- dispel type string (see AEI.CreateDispelsIndicator). AuraEngineIndicators.lua
-- is entirely inert pre-12.1, so this is the legacy fallback Indicators.lua's
-- I.CreateIndicator drops back to on those clients.
--
-- Midnight 12.0.0+'s secret-value system applies on 12.0.7 too (see
-- Custom_Dispatch.lua's file header) -- info.dispelName routinely goes secret
-- in combat, and comparing a secret value to a STRING LITERAL (this
-- function's first version: `def.token == info.dispelName`) throws instead of
-- returning false, exactly like indexing a table with a secret key (see
-- ScanAurasForCooldownGrid's identical fix above). Comparing to `nil` is the
-- one safe operation: a typed/dispellable debuff always has a non-nil
-- dispelName even while its actual VALUE is secret. So this can detect
-- "some dispellable debuff is present" safely, but not WHICH type, by reading
-- dispelName directly.
--
-- The type IS still resolvable without ever reading it, via Blizzard's own
-- C_UnitAuras.GetAuraDispelTypeColor(unit, auraInstanceID, curve): it resolves
-- the aura's dispel-type index internally against a Lua-built color curve and
-- hands back the matching color -- so the secret type never has to leave
-- C code. This is the exact technique EllesmereUIRaidFrames' own pre-12.1
-- dispel code uses (reviewed directly from that addon's local install, which
-- runs this same code path on THIS client version and works). Blizzard's
-- dispel-type enum: 1 Magic, 2 Curse, 3 Disease, 4 Poison, 11 Bleed.
local DISPEL_LEGACY_TYPES = {
    { idx = 1,  colorKey = "Magic",   atlas = "RaidFrame-Icon-DebuffMagic",   fallback = {0.20, 0.60, 1.00} },
    { idx = 2,  colorKey = "Curse",   atlas = "RaidFrame-Icon-DebuffCurse",   fallback = {0.60, 0.00, 1.00} },
    { idx = 3,  colorKey = "Disease", atlas = "RaidFrame-Icon-DebuffDisease", fallback = {0.60, 0.40, 0.00} },
    { idx = 4,  colorKey = "Poison",  atlas = "RaidFrame-Icon-DebuffPoison",  fallback = {0.00, 0.60, 0.00} },
    { idx = 11, colorKey = "Bleed",   atlas = "RaidFrame-Icon-DebuffBleed",   fallback = {0.75, 0.15, 0.15} },
}

-- Per-type icon-visibility curves: white at alpha 1 for exactly ONE dispel
-- index, alpha 0 everywhere else. Evaluating each type's own curve against
-- the same aura and feeding the (possibly secret) result straight into that
-- type's OWN texture's SetVertexColor reveals only the matching icon --
-- never by testing/branching on which type it secretly is, just by piping 5
-- independent alphas into 5 independent setters. Fixed/shared (doesn't depend
-- on user color settings) -- built once per index and cached.
local dispelIconCurves = {}
local function GetDispelIconCurve(idx)
    local c = dispelIconCurves[idx]
    if c then return c end
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve) then return nil end
    c = C_CurveUtil.CreateColorCurve()
    c:SetType(Enum.LuaCurveType.Step)
    for _, def in ipairs(DISPEL_LEGACY_TYPES) do
        c:AddPoint(def.idx, CreateColor(1, 1, 1, def.idx == idx and 1 or 0))
    end
    dispelIconCurves[idx] = c
    return c
end

-- Per-indicator color curve: maps dispel-type index -> that type's configured
-- color, alpha premultiplied by (enabled ? overlayOpacity : 0) so a
-- user-disabled type just resolves to a transparent color instead of needing
-- a second (unsafe) enabled-check on the result. Rebuilt only when colors/
-- opacity/enabled-types actually change (the Set* methods below), not on
-- every scan.
-- A SECOND curve is built alongside, identical except its alpha is scaled by
-- the gradient's weak-end percentage. It exists because the gradient modes'
-- weak-end underlay (see ApplyDispelOverlayColor) can't just compute its own
-- alpha from the profile: "type disabled" is encoded HERE, as alpha 0 on the
-- resolved type, and which type resolved is exactly the secret this whole
-- curve mechanism exists to avoid asking about. An underlay painted from
-- profile numbers alone would therefore still tint for a type the user had
-- switched off. Routing it through its own curve inherits the alpha-0
-- encoding for free -- all the arithmetic happens here, on plain profile
-- values, at rebuild time rather than on a resolved (secret) result.
local function RebuildDispelColorCurve(indicator)
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve) then
        indicator._dispelColorCurve = nil
        indicator._dispelWeakColorCurve = nil
        return
    end
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    local weakCurve = C_CurveUtil.CreateColorCurve()
    weakCurve:SetType(Enum.LuaCurveType.Step)
    local opacity = (indicator._dispelOverlayOpacity or 40) / 100
    local weakOpacity = opacity * ((indicator._dispelGradientWeakAlpha or 50) / 100)
    local colors = indicator._dispelColors or {}
    local enabled = indicator._dispelTypesEnabled or {}
    for _, def in ipairs(DISPEL_LEGACY_TYPES) do
        local col = colors[def.colorKey] or def.fallback
        local isEnabled = enabled[def.colorKey] ~= false
        local r, g, b = col[1] or 1, col[2] or 1, col[3] or 1
        curve:AddPoint(def.idx, CreateColor(r, g, b, isEnabled and opacity or 0))
        weakCurve:AddPoint(def.idx, CreateColor(r, g, b, isEnabled and weakOpacity or 0))
    end
    indicator._dispelColorCurve = curve
    indicator._dispelWeakColorCurve = weakCurve
end

-- Paints the overlay/gradient texture for a resolved (r,g,b,a) -- a may be a
-- SECRET value from the curve lookup; it flows straight into the setters
-- below and is never read/compared, matching CLAUDE.md's "Secret Numbers"
-- pattern (arithmetic/comparison taints, passing through to a C-level setter
-- doesn't).
-- wr/wg/wb/wa are the weak-end colour for the gradient modes' underlay,
-- resolved through _dispelWeakColorCurve by the caller (and equally secret).
-- nil means "no underlay" -- the ramp just fades to fully transparent.
local function ApplyDispelOverlayColor(indicator, health, mode, r, g, b, a, wr, wg, wb, wa)
    if mode == "full" then
        indicator.gradientOverlay:Hide()
        indicator.overlay:ClearAllPoints()
        indicator.overlay:SetAllPoints(health)
        indicator.overlay:SetColorTexture(r, g, b, a)
        indicator.overlay:Show()
    elseif mode == "gradient" or mode == "gradientTop" then
        indicator.gradientOverlay:ClearAllPoints()
        indicator.overlay:ClearAllPoints()
        -- EXTENT: strong edge pinned flush to the health bar, weak edge moved
        -- by the height slider (100% = the whole bar). health:GetHeight() is
        -- unavoidable -- no fractional anchors exist -- but unlike the
        -- AuraEngine path this needs no resize hook: ApplyDispelOverlayColor
        -- re-runs on every CheckDispels (i.e. every UNIT_AURA that resolves a
        -- dispellable debuff), so it re-measures constantly on its own. A
        -- height of 0/nil falls back to full-bar coverage rather than
        -- rendering nothing.
        local barH = health:GetHeight() or 0
        local h = barH > 0
            and (barH * ((indicator._dispelGradientHeight or 50) / 100))
            or nil
        if mode == "gradientTop" then
            indicator.gradientOverlay:SetPoint("TOPLEFT", health, "TOPLEFT", 0, 0)
            indicator.gradientOverlay:SetPoint("TOPRIGHT", health, "TOPRIGHT", 0, 0)
            if h then indicator.gradientOverlay:SetHeight(h)
            else indicator.gradientOverlay:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", 0, 0) end
        else
            indicator.gradientOverlay:SetPoint("BOTTOMLEFT", health, "BOTTOMLEFT", 0, 0)
            indicator.gradientOverlay:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", 0, 0)
            if h then indicator.gradientOverlay:SetHeight(h)
            else indicator.gradientOverlay:SetPoint("TOPRIGHT", health, "TOPRIGHT", 0, 0) end
        end
        -- Pre-baked vertical gradient (solid at the top, fading to
        -- transparent at the bottom) tinted via SetVertexColor -- secret-
        -- tolerant (unlike SetGradient/CreateColor, which reject a secret
        -- color component outright: "bad argument #2 to 'SetGradient'",
        -- confirmed via a live error report -- routine mid-combat, since
        -- r/g/b/a here come from a curve lookup keyed on the often-secret
        -- dispel type). Renders a real gradient every tick, combat or not,
        -- with no degraded/fallback case needed. Same technique
        -- EllesmereUIRaidFrames' own working "gradient" mode uses.
        indicator.gradientOverlay:SetTexture([[Interface\AddOns\SquizzFrames\Media\Textures\gradient-tb.tga]])
        -- gradient-tb.tga is baked solid-at-TOP fading to transparent at the
        -- bottom, which IS "gradientTop". "gradient" (strongest at the
        -- bottom) flips it vertically via SetTexCoord's top/bottom coords
        -- rather than shipping a second, mirrored copy of the asset. Set
        -- every time, not just on the flipped branch -- this texture object
        -- is reused across mode changes, so the unflipped case has to
        -- actively reset the coords rather than assume the default.
        if mode == "gradient" then
            indicator.gradientOverlay:SetTexCoord(0, 1, 1, 0)
        else
            indicator.gradientOverlay:SetTexCoord(0, 1, 0, 1)
        end
        indicator.gradientOverlay:SetVertexColor(r, g, b, a)
        indicator.gradientOverlay:Show()

        -- WEAK-END ALPHA on this path is an APPROXIMATION, not the exact
        -- two-stop ramp the AuraEngine path gets from SetGradient. The baked
        -- texture always fades to fully transparent, and the only knob is the
        -- single alpha multiplier in SetVertexColor -- rescaling the ramp to
        -- stop at a floor would mean dividing by `a`, which is often SECRET
        -- here (curve lookup keyed on the dispel type) and would taint.
        --
        -- Instead the flat `overlay` texture is reused (it's unused in
        -- gradient mode anyway) as an UNDERLAY at the weak-end colour, with
        -- the fading ramp composited on top by the GPU. Compositing is what
        -- avoids the taint: no Lua arithmetic touches any resolved colour
        -- component, both just pass through to C-level setters.
        --
        -- Caveat: alpha compositing isn't additive, so the strong end reads
        -- slightly MORE opaque than the opacity slider alone would give
        -- (combined = weak + a - weak*a). Visually it's the intended ramp;
        -- numerically it isn't exact. 12.1 clients don't hit this path.
        if wa ~= nil then
            -- Explicit sublevels rather than relying on creation order, so the
            -- flat underlay is guaranteed to sit beneath the ramp.
            indicator.overlay:SetDrawLayer("ARTWORK", 0)
            indicator.gradientOverlay:SetDrawLayer("ARTWORK", 1)
            indicator.overlay:SetAllPoints(indicator.gradientOverlay)
            indicator.overlay:SetColorTexture(wr, wg, wb, wa)
            indicator.overlay:Show()
        else
            indicator.overlay:Hide()
        end
    else -- "fill": only the currently-filled portion of the health bar.
        indicator.gradientOverlay:Hide()
        indicator.overlay:ClearAllPoints()
        local fillTex = health.GetStatusBarTexture and health:GetStatusBarTexture()
        indicator.overlay:SetPoint("TOPLEFT", health, "TOPLEFT", 0, 0)
        if fillTex then
            indicator.overlay:SetPoint("BOTTOMRIGHT", fillTex, "BOTTOMRIGHT", 0, 0)
        else
            indicator.overlay:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", 0, 0)
        end
        indicator.overlay:SetColorTexture(r, g, b, a)
        indicator.overlay:Show()
    end
end

-- GetAuraDispelTypeColor's returned Color object may not always expose
-- GetRGBA (EllesmereUIRaidFrames' own equivalent code defensively checks for
-- it too) -- fall back to GetRGB + a plain alpha of 1 rather than assuming.
local function DispelColorRGBA(col)
    if col.GetRGBA then return col:GetRGBA() end
    local r, g, b = col:GetRGB()
    return r, g, b, 1
end

-- Forward-declared: CreateDispelsIndicatorLegacy's Set* methods call this
-- directly so live options-panel edits (color/overlay-mode/opacity/type
-- toggles) reflect immediately instead of waiting for the next UNIT_AURA.
local CheckDispels

-- Wrapper frame doubles as the shared dispel-type icon's settings-dispatch
-- handle (position/size/frameLevel -- generic HandleIndicators code, same as
-- every other built-in). The overlay is unrelated to the wrapper's own
-- position/size -- it always spans the health bar, matching the AuraEngine
-- version and the Dispels default's own comment in Layout_Defaults.lua.
function CreateDispelsIndicatorLegacy(button, t)
    local wrapper = CreateFrame("Frame", button:GetName() .. "DispelsLegacy", button)
    wrapper:Hide()
    wrapper._sfType = "builtin"
    wrapper._sfLegacyDispel = true

    -- One icon texture PER dispel type, all stacked in the same spot -- see
    -- GetDispelIconCurve's comment for why only one ends up visible.
    wrapper.iconTextures = {}
    for _, def in ipairs(DISPEL_LEGACY_TYPES) do
        local tex = wrapper:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints(wrapper)
        tex:SetAtlas(def.atlas)
        tex:Hide()
        wrapper.iconTextures[def.idx] = tex
    end

    wrapper.overlay = button:CreateTexture(nil, "ARTWORK")
    wrapper.overlay:Hide()
    -- "Gradient" mode tints this with a pre-baked gradient-shaped texture
    -- (solid at one edge, fading to transparent at the other -- see
    -- ApplyDispelOverlayColor) rather than building the fade via
    -- CreateColor/SetGradient. SetGradient's own argument validation rejects
    -- a secret color component outright ("bad argument #2 to 'SetGradient'",
    -- confirmed via a live error report) -- routine mid-combat, since r/g/b/a
    -- here come from a curve lookup keyed on the (often secret) dispel type.
    -- SetVertexColor (used to tint the pre-baked texture instead) IS
    -- secret-tolerant, so this renders a real gradient on every tick,
    -- combat or not, with no fallback/degraded case needed at all. Confirmed
    -- via EllesmereUIRaidFrames' own working "gradient" mode, which uses this
    -- exact technique (a baked gradient-tb.tga tinted via SetVertexColor) --
    -- NOT Blizzard's native dispel-indicator-overlay container, which Ellesmere
    -- only ever uses as an invisible fallback for privated auras (and which
    -- this addon tried mirroring for the VISIBLE gradient in an earlier
    -- version -- it drew Blizzard's own dispel-debuff icon in a fixed corner
    -- position no matter what, unrelated to and uncoverable by this addon's
    -- own (user-liked) dispel type icons, so it's been dropped).
    wrapper.gradientOverlay = button:CreateTexture(nil, "ARTWORK")
    wrapper.gradientOverlay:Hide()

    wrapper._dispelShowAll = (t.dispelShowAll ~= false)
    wrapper._dispelTypesEnabled = t.dispelTypesEnabled or {}
    wrapper._dispelColors = t.dispelColors or {}
    wrapper._dispelOverlay = t.dispelOverlay or "fill"
    wrapper._dispelOverlayOpacity = t.dispelOverlayOpacity or 40
    wrapper._dispelGradientWeakAlpha = t.dispelGradientWeakAlpha or 50
    wrapper._dispelGradientHeight = t.dispelGradientHeight or 50
    wrapper._showDispelIcons = t.showDispelIcons == true
    RebuildDispelColorCurve(wrapper)

    function wrapper:SetDispelShowAll(v)
        wrapper._dispelShowAll = (v ~= false)
        CheckDispels(button)
    end
    function wrapper:SetDispelTypes(tbl)
        wrapper._dispelTypesEnabled = tbl or {}
        RebuildDispelColorCurve(wrapper)
        CheckDispels(button)
    end
    function wrapper:SetDispelColors(tbl)
        wrapper._dispelColors = tbl or {}
        RebuildDispelColorCurve(wrapper)
        CheckDispels(button)
    end
    function wrapper:SetDispelOverlay(mode)
        wrapper._dispelOverlay = mode
        CheckDispels(button)
    end
    function wrapper:SetDispelOverlayOpacity(v)
        wrapper._dispelOverlayOpacity = v
        RebuildDispelColorCurve(wrapper)
        CheckDispels(button)
    end
    -- Weak alpha is baked into _dispelWeakColorCurve, so it must rebuild.
    function wrapper:SetDispelGradientWeakAlpha(v)
        wrapper._dispelGradientWeakAlpha = v
        RebuildDispelColorCurve(wrapper)
        CheckDispels(button)
    end
    -- Height is pure geometry, applied at paint time -- no curve involved.
    function wrapper:SetDispelGradientHeight(v)
        wrapper._dispelGradientHeight = v
        CheckDispels(button)
    end
    function wrapper:SetShowDispelIcons(v)
        wrapper._showDispelIcons = (v == true)
        CheckDispels(button)
    end

    return wrapper
end

local function HideDispelVisuals(indicator)
    indicator.overlay:Hide()
    indicator.gradientOverlay:Hide()
    for _, tex in pairs(indicator.iconTextures) do tex:Hide() end
end

function CheckDispels(button)
    local indicator = button.indicators and button.indicators.dispels
    if not indicator then return end
    -- AuraEngine-backed wrapper (AuraEngineIndicators.lua) updates its own
    -- per-type slots directly via the engine -- only fall through to the
    -- legacy scan for the CreateDispelsIndicatorLegacy fallback above,
    -- marked by _sfLegacyDispel (the AuraEngine wrapper never sets it).
    if not indicator._sfLegacyDispel then return end

    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then
        HideDispelVisuals(indicator)
        return
    end

    local health = button.healthBar or button
    local unit = button.unit or button:GetAttribute("unit")
    if not unit then return end

    local mode = indicator._dispelOverlay or "fill"
    local IndicatorsModule = SquizzFrames.Indicators
    local isPreview = IndicatorsModule and IndicatorsModule.IsPreviewButton(button)

    -- Same reasoning as ScanAurasForCooldownGrid/CheckDebuffs: the preview
    -- button's unit is the REAL "player", so scanning it here could taint the
    -- rest of the same CheckAll(button) pass with real (possibly in-group)
    -- secret data. Show a static Magic-type mockup instead of scanning.
    if isPreview then
        HideDispelVisuals(indicator)
        if (indicator._dispelTypesEnabled.Magic) ~= false and mode ~= "none" then
            local color = indicator._dispelColors.Magic or DISPEL_LEGACY_TYPES[1].fallback
            local r, g, b = color[1] or 1, color[2] or 1, color[3] or 1
            local opacity = (indicator._dispelOverlayOpacity or 40) / 100
            -- No curve lookup on the preview -- nothing here is secret, so the
            -- weak end is just computed directly.
            local weakPct = indicator._dispelGradientWeakAlpha or 50
            ApplyDispelOverlayColor(indicator, health, mode, r, g, b, opacity,
                r, g, b, weakPct > 0 and (opacity * (weakPct / 100)) or nil)
            if indicator._showDispelIcons and indicator.iconTextures[1] then
                indicator.iconTextures[1]:Show()
            end
        end
        return
    end

    local filter = "HARMFUL" .. (indicator._dispelShowAll == false and "|RAID_PLAYER_DISPELLABLE" or "")
    local found
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local i = 1
        while i <= 40 do
            -- Same secret-slot handling as CheckDebuffs/CheckCCIndicator:
            -- skip just this index on failure, don't break the whole scan.
            local ok, info = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, filter)
            if not ok then
                i = i + 1
            elseif not info then
                break -- genuinely past the last aura
            else
                i = i + 1
                -- info.dispelName ~= nil is the ONE secret-safe comparison
                -- here (see this section's header comment) -- first match
                -- wins, same as EllesmereUI's own legacy scan (no priority
                -- sort, since sorting would require reading/comparing the
                -- secret type itself, which is exactly what broke this).
                if F.IsValueNonSecret(info.isHelpful) and info.dispelName ~= nil then
                    found = info
                    break
                end
            end
        end
    end

    if not found then
        indicator.overlay:Hide()
        indicator.gradientOverlay:Hide()
        for _, tex in pairs(indicator.iconTextures) do tex:Hide() end
        return
    end

    local iid = found.auraInstanceID

    if mode ~= "none" then
        local applied = false
        local curve = indicator._dispelColorCurve
        if curve and C_UnitAuras.GetAuraDispelTypeColor then
            local col = C_UnitAuras.GetAuraDispelTypeColor(unit, iid, curve)
            if col then
                local r, g, b, a = DispelColorRGBA(col)
                -- Second lookup against the weak-end curve (same aura, same
                -- resolved-but-unread type) for the gradient underlay. Skipped
                -- entirely outside the gradient modes, and when the weak end
                -- is set to 0 -- both cases want no underlay at all.
                local wr, wg, wb, wa
                local weakCurve = indicator._dispelWeakColorCurve
                if weakCurve and (mode == "gradient" or mode == "gradientTop")
                    and (indicator._dispelGradientWeakAlpha or 50) > 0 then
                    local wcol = C_UnitAuras.GetAuraDispelTypeColor(unit, iid, weakCurve)
                    if wcol then wr, wg, wb, wa = DispelColorRGBA(wcol) end
                end
                ApplyDispelOverlayColor(indicator, health, mode, r, g, b, a, wr, wg, wb, wa)
                applied = true
            end
        end
        if not applied then
            -- Curve API unavailable, or the resolved type had no curve point
            -- (an untyped/exotic dispel index) -- fall back to a flat,
            -- non-type-specific color from the first enabled type so
            -- something still shows rather than silently nothing.
            local anyColor
            for _, def in ipairs(DISPEL_LEGACY_TYPES) do
                if (indicator._dispelTypesEnabled[def.colorKey]) ~= false then
                    anyColor = indicator._dispelColors[def.colorKey] or def.fallback
                    break
                end
            end
            if anyColor then
                local r, g, b = anyColor[1] or 1, anyColor[2] or 1, anyColor[3] or 1
                local opacity = (indicator._dispelOverlayOpacity or 40) / 100
                -- Curve unavailable, so nothing here is secret either.
                local weakPct = indicator._dispelGradientWeakAlpha or 50
                ApplyDispelOverlayColor(indicator, health, mode, r, g, b, opacity,
                    r, g, b, weakPct > 0 and (opacity * (weakPct / 100)) or nil)
            else
                indicator.overlay:Hide()
                indicator.gradientOverlay:Hide()
            end
        end
    else
        indicator.overlay:Hide()
        indicator.gradientOverlay:Hide()
    end

    if indicator._showDispelIcons and C_UnitAuras.GetAuraDispelTypeColor then
        for _, def in ipairs(DISPEL_LEGACY_TYPES) do
            local tex = indicator.iconTextures[def.idx]
            local iconCurve = GetDispelIconCurve(def.idx)
            if tex and iconCurve then
                local col = C_UnitAuras.GetAuraDispelTypeColor(unit, iid, iconCurve)
                if col then
                    tex:SetVertexColor(DispelColorRGBA(col))
                    tex:Show()
                else
                    tex:Hide()
                end
            elseif tex then
                tex:Hide()
            end
        end
    else
        for _, tex in pairs(indicator.iconTextures) do tex:Hide() end
    end
end

local function CheckMissingBuffs(button)
    local indicator = button.indicators and button.indicators.missingBuffs
    if not indicator then return end
    local t = indicator._sfTable or indicator.configs
    if not t or not t.enabled then indicator:Hide() return end

    -- Re-synced every check pass (cheap -- SetShowBorder is just a per-slot
    -- SetShown loop) rather than only on the setting's own change event, so
    -- it stays correct across profile switches/reloads too. Defaults ON
    -- ("~= false") unless explicitly disabled via the checkbox.
    if indicator.SetShowBorder then
        indicator:SetShowBorder(t.showIconBorder ~= false)
    end

    local unit = button.unit or button:GetAttribute("unit")
    if not unit then return end

    -- Same reasoning as ScanAurasForCooldownGrid/CheckDebuffs: the preview
    -- button's unit is the REAL "player", so a real scan here could taint
    -- the rest of the same CheckAll(button) pass. Fill every slot up to the
    -- configured max with a representative "missing" icon (cycling through
    -- the curated raid buffs for variety, same as the num/orientation
    -- preview fix applied elsewhere) instead of scanning -- previously only
    -- populated slot 1, so the preview never reflected the actual max-icons
    -- setting.
    local IndicatorsModule = SquizzFrames.Indicators
    if IndicatorsModule and IndicatorsModule.IsPreviewButton(button) then
        local maxSlots = t.num or 5
        local n = #raidBuffs
        local shown = 0
        if n > 0 then
            for i = 1, math.min(maxSlots, 10) do
                local icon = F.GetSpellIcon(raidBuffs[((i - 1) % n) + 1])
                if icon then
                    indicator:SetCooldown(i, 0, 0, nil, icon, nil)
                    shown = shown + 1
                end
            end
        end
        for i = shown + 1, 10 do
            indicator:ClearCooldown(i)
        end
        if shown > 0 then
            indicator:Show()
        else
            indicator:Hide()
        end
        return
    end

    local tracked = F.GetEffectiveSpellList(t.useBuiltInMissingBuffs, raidBuffs, t.customMissingBuffs, t.hiddenBuiltInMissingBuffs)
    local maxSlots = t.num or 5
    if #tracked == 0 then indicator:Hide() return end

    -- Only flag a curated buff as "missing" if a class that can actually
    -- provide it is present in the group -- e.g. don't show "missing Arcane
    -- Intellect" when there's no Mage around to cast it. Custom user-added
    -- spell IDs have no known provider class (raidBuffClass has no entry for
    -- them), so they're never filtered by this -- always shown if missing.
    local groupClasses = GetGroupClasses()

    -- Build the set of buffs currently present. A buff cast by someone OTHER
    -- than the unit itself commonly goes secret once in combat (confirmed
    -- via debug log: readable out of combat, secret in combat) -- when that
    -- happens we can't tell which tracked buffs are actually present this
    -- pass, so recomputing anyway would misreport EVERY tracked buff as
    -- missing at once (confirmed via user report: entering combat flashes
    -- "all missing", clearing again on leaving combat). Bail out and leave
    -- the indicator showing its last known-good state instead -- a stale
    -- but likely-still-correct read beats a guaranteed-wrong one.
    local presentSet = {}
    local sawSecretSpell = false
    local i = 1
    while i <= 40 do
        -- Same fix as CheckDebuffs/ScanAurasForCooldownGrid: a `pcall`
        -- failure means THIS slot's data is secret, not that we've reached
        -- the end of the aura list -- breaking here was the actual bug
        -- (not the freeze-on-secret strategy below), since it silently
        -- dropped every aura after the first secret one on the whole unit,
        -- making nearly every combat scan look like "everything's secret"
        -- even when only one unrelated aura actually was.
        local ok, info = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
        if not ok then
            sawSecretSpell = true
            i = i + 1
        elseif not info then
            break -- genuinely past the last aura
        else
            i = i + 1
            if info.spellId then
                if F.IsValueNonSecret(info.spellId) then
                    presentSet[info.spellId] = true
                else
                    sawSecretSpell = true
                end
            end
        end
    end
    if sawSecretSpell then return end

    -- Curated buffs are grouped by provider class (raidBuffClass) so a
    -- multi-variant buff like Blessing of the Bronze -- 26 different aura
    -- IDs depending on which class receives it -- counts as present if ANY
    -- ONE of its variants is found, rather than treating each variant as
    -- its own separately-tracked buff (which would otherwise flag the other
    -- 25 class-specific variants as "missing" on every single unit, since
    -- only one variant can ever apply to any given recipient). Custom
    -- user-added spell IDs have no known provider class and stay
    -- independent, one slot each.
    local classIds, classOrder, standalone = {}, {}, {}
    for _, id in ipairs(tracked) do
        local cls = raidBuffClass[id]
        if cls then
            if not classIds[cls] then
                classIds[cls] = {}
                classOrder[#classOrder + 1] = cls
            end
            table.insert(classIds[cls], id)
        else
            standalone[#standalone + 1] = id
        end
    end

    local shown = 0
    for _, cls in ipairs(classOrder) do
        if shown >= maxSlots then break end
        if groupClasses[cls] then
            local ids = classIds[cls]
            table.sort(ids) -- deterministic representative icon across reloads
            local anyPresent = false
            for _, id in ipairs(ids) do
                if IsBuffPresent(id, presentSet) then anyPresent = true break end
            end
            if not anyPresent then
                indicator:SetCooldown(shown + 1, 0, 0, nil, F.GetSpellIcon(ids[1]), nil)
                shown = shown + 1
            end
        end
    end
    for _, id in ipairs(standalone) do
        if shown >= maxSlots then break end
        if not IsBuffPresent(id, presentSet) then
            indicator:SetCooldown(shown + 1, 0, 0, nil, F.GetSpellIcon(id), nil)
            shown = shown + 1
        end
    end
    for j = shown + 1, maxSlots do
        indicator:ClearCooldown(j)
    end
    if shown > 0 then
        indicator:Show()
    else
        indicator:Hide()
    end
end

-- ------------------------------------------------------------------
-- CheckAll: run every built-in's Check (used after HandleIndicators rebuilds)
-- ------------------------------------------------------------------
function BU.CheckAll(button)
    if not button then return end
    CheckNameText(button)
    CheckStatusIcon(button)
    BU.CheckRoleIcon(button)
    CheckLeaderIcon(button)
    CheckPlayerRaidIcon(button)
    CheckAggroBlink(button)
    CheckAggroBorder(button)
    CheckTargetHighlight(button)
    CheckHoverHighlight(button)
    CheckShieldBar(button)
    CheckShieldOverlay(button)
    CheckHealAbsorb(button)
    CheckExternalCooldowns(button)
    CheckDefensiveCooldowns(button)
    CheckHealerHots(button)
    CheckDispels(button)
    CheckDebuffs(button)
    CheckCCIndicator(button)
    CheckMissingBuffs(button)
    CheckHealthText(button)
    CheckPowerText(button)
end

-- ------------------------------------------------------------------
-- HandleEvent: dispatch a game event to the right Check function(s)
-- ------------------------------------------------------------------
local eventMap = {
    -- "UNIT_FLAGS" isn't a real WoW event (silently never fires); the actual
    -- AFK/DND toggle event is PLAYER_FLAGS_CHANGED(unit).
    PLAYER_FLAGS_CHANGED     = { CheckStatusIcon },
    UNIT_CONNECTION          = { CheckStatusIcon, CheckNameText },
    GROUP_ROSTER_UPDATE      = { CheckLeaderIcon, CheckLeaderIcon, BU.CheckRoleIcon, CheckAggroBlink, CheckAggroBorder, CheckNameText, CheckTargetHighlight },
    -- The actual "a unit's assigned role changed" event -- GROUP_ROSTER_UPDATE
    -- only fires on membership changes (someone joining/leaving), not on an
    -- in-place role reassignment (role-check UI, LFG role swap, manually
    -- changing spec/role mid-group), so without this the role icon only ever
    -- updates by coincidence, whenever the roster itself happens to change.
    -- No unit payload -- OnEvent's "not unit" branch pushes it to every
    -- wired button, matching GROUP_ROSTER_UPDATE/PLAYER_TARGET_CHANGED above.
    PLAYER_ROLES_ASSIGNED    = { BU.CheckRoleIcon },
    -- ...and the spec change itself, because F.GetRoleKey now falls back to
    -- the player's SPEC role whenever no group role is assigned. Solo, there
    -- is no group to reassign roles in, so neither of the two events above
    -- ever fires -- swapping Holy to Retribution would leave the old icon up
    -- until something unrelated re-checked the button.
    --
    -- No unit payload, so OnEvent's "not unit" branch broadcasts it to every
    -- wired button; only the player's own resolves to a different role.
    ACTIVE_PLAYER_SPECIALIZATION_CHANGED = { BU.CheckRoleIcon },
    UNIT_THREAT_SITUATION_UPDATE = { CheckAggroBlink, CheckAggroBorder },
    -- No unit payload -- OnEvent's "not unit" branch pushes this to every
    -- wired button, so both the old and new target's buttons get re-checked.
    PLAYER_TARGET_CHANGED    = { CheckTargetHighlight },
    UNIT_HEALTH              = { CheckShieldBar, CheckHealthText, CheckShieldOverlay, CheckHealAbsorb },
    UNIT_ABSORB_AMOUNT_CHANGED = { CheckShieldBar, CheckShieldOverlay },
    UNIT_HEAL_ABSORB_AMOUNT_CHANGED = { CheckHealAbsorb },
    UNIT_POWER_UPDATE        = { CheckPowerText },
    UNIT_MAXPOWER            = { CheckPowerText },
    UNIT_AURA                = { CheckExternalCooldowns, CheckDefensiveCooldowns, CheckHealerHots, CheckDispels, CheckDebuffs, CheckCCIndicator, CheckMissingBuffs },
    RAID_TARGET_UPDATE       = { CheckPlayerRaidIcon },
    UNIT_NAME_UPDATE         = { CheckNameText },
    READY_CHECK              = { StartReadyCheck },
    READY_CHECK_CONFIRM      = { ConfirmReadyCheck },
    READY_CHECK_FINISHED     = { FinishReadyCheck },
    -- CheckMissingBuffs freezes at its last known-good state whenever the
    -- scan hits a secret spellId (common in combat for buffs cast by other
    -- players) rather than misreport everything as missing -- re-run it the
    -- moment combat ends so it doesn't just sit stale until some unrelated
    -- UNIT_AURA event happens to fire next.
    PLAYER_REGEN_ENABLED     = { CheckMissingBuffs },
}

function BU.HandleEvent(button, event)
    if not button or not event then return end
    local checks = eventMap[event]
    if not checks then return end
    for _, fn in ipairs(checks) do
        fn(button)
    end
end

SquizzFrames.modules = SquizzFrames.modules or {}
SquizzFrames.modules["BuiltIn_Update"] = BU
