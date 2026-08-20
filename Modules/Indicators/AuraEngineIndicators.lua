--[[ SquizzFrames AuraEngineIndicators.lua - Built-in indicators backed by AuraEngine ]]
--
-- Bridges AuraEngine (12.1 AuraContainer) into the ordinary built-in
-- indicator lifecycle (I.CreateIndicator / HandleIndicators / ApplySettingToOne
-- in Indicators.lua), so these indicators are driven by the exact same
-- position/size/frameLevel/alpha/enabled settings code as every other
-- built-in, without special-casing that generic code per indicator.
--
-- The trick: I.CreateIndicator returns a plain "wrapper" Frame, not the
-- AuraContainer itself. The container is a CHILD of the wrapper, anchored to
-- fill it. Generic Frame methods (SetPoint/ClearAllPoints/Show/Hide/SetAlpha)
-- just work because they're plain Frame behavior and children inherit
-- visibility/alpha from their parent. Settings that don't map to a Frame
-- method (size => per-icon dimensions, orientation => growth direction, num
-- => max icon count, castBy => aura source filter) are handled by SetSize /
-- SetOrientation / SetNum / SetCastBy methods defined directly on the
-- wrapper, which Indicators.lua's generic dispatch already calls whenever
-- they exist (mirroring the existing SetNumPerLine/SetOrientation pattern).
--
-- Container creation is deferred via AE.RequestContainer, so this is safe to
-- call from HandleIndicators even mid-combat (the wrapper shows up empty
-- until PLAYER_REGEN_ENABLED, then the real container attaches).

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local AEI = {}
SquizzFrames.AuraEngineIndicators = AEI

if not SquizzFrames.IS_121 then return end

local F = SquizzFrames.F

local GROUP_KEY = "healerHots"
local STYLE_KEY = "healerHots"

-- healerSpells is class-keyed (Defaults/Indicator_Defaults.lua) -- only the
-- VIEWING PLAYER's own class group is relevant here (a Priest can never cast
-- a Druid HoT), flattened to a plain spell-ID array. Computed fresh each call
-- rather than cached forever like the old flat-list version: it's cheap
-- (~10-12 entries) and needs to stay correct if this ever runs for something
-- other than "player" in the future.
local function GetPlayerClassHealerSpells()
    local playerClass = F.GetClassFile and F.GetClassFile("player")
    local classTable = SquizzFrames.defaults and SquizzFrames.defaults.healerSpells
    local spellSet = (playerClass and classTable and classTable[playerClass]) or {}
    return F.FlattenSpellTable({ spellSet })
end

-- Preview-only: pick up to `count` DISTINCT spells from the indicator's own
-- effective spell list (respecting the Use Default Spells toggle + per-spell
-- hide list) so the fallback row shows real variety instead of one icon
-- repeated across every slot.
local function PickRepresentativeHealerSpells(t, count)
    local baseList = GetPlayerClassHealerSpells()
    local effective = F.GetEffectiveSpellList(t.useBuiltInHots, baseList, nil, t.hiddenBuiltInHots)
    local icons = {}
    for i = 1, math.min(count, #effective) do
        icons[i] = F.GetSpellIcon(effective[i]) or [[Interface\Icons\INV_Misc_QuestionMark]]
    end
    if #icons == 0 then
        icons[1] = [[Interface\Icons\INV_Misc_QuestionMark]]
    end
    return icons
end

-- "Built-in Spells" checklist support -- t.useBuiltInHots (Use Default
-- Spells toggle) + t.hiddenBuiltInHots (per-spell hide list from
-- IndicatorWidgets.lua's CreateSetting_BuiltInHots) filter the player's own
-- class list the same way externalCooldowns/defensiveCooldowns already do
-- via F.GetEffectiveSpellList (see BuildCooldownCandidateFilters below).
-- Seconds. Everything these three indicators legitimately track is SHORT:
-- HoTs run 15-18s (Renew, Rejuvenation, Lifebloom, Riptide, Atonement) and
-- externals/defensives 5-30s (Blessing of Protection 10s, Pain Suppression
-- 8s, Ironbark 12s, Anti-Magic Shell 5s, Fortifying Brew 15s). The noise is
-- all long or permanent: food, flasks, Arcane Intellect, Mark of the Wild,
-- Blessing of the Bronze, weapon enchants.
--
-- This exists because maxDuration is one of the candidate filters evaluated
-- OUTSIDE Blizzard's CanApplyIdentityCandidateFilters gate, so unlike
-- includeSpellIDs it still works while UnitCanAssist is broken on 12.1 (see
-- HealerFilterTokens' comment). It also implicitly drops permanent auras
-- (duration == 0) per Blizzard's own implementation. Raise it if a genuinely
-- long tracked buff goes missing; it is a noise floor, not a precise filter,
-- and becomes redundant (though harmless) once spell-ID filtering works again.
local AURA_MAX_DURATION = 60

-- The noise floor is a WORKAROUND, so only apply it where it's actually
-- needed -- it has a serious side effect.
--
-- Blizzard's filter (AuraContainerUtil.DoesAuraPassCandidateFilters) reads:
--     -- Max duration filters implicitly always filter out permanent auras.
--     if auraData.duration > maxDuration or auraData.duration == 0 then
-- so maxDuration doesn't merely cap long auras, it rejects PERMANENT ones
-- outright. That silently hid Beacon of Light and Beacon of Faith from Healer
-- HoTs -- both tracked, both permanent (user report 2026-08-13). Raising the
-- cap can't fix it; 0 is excluded at any value.
--
-- It exists only because includeSpellIDs is gated behind
-- CanApplyIdentityCandidateFilters, which for a HELPFUL aura requires
-- UnitCanAssist("player", unit). When that's false our spell list is silently
-- discarded and something has to stop the indicator showing every buff the
-- player has cast (food, flasks, Arcane Intellect, weapon enchants).
--
-- So: gate open -> spell-ID filtering works, no cap needed, permanents show.
-- Gate shut -> keep the cap, because the alternative is a flood. Measured per
-- unit rather than assumed either way: a runtime dump showed canAssist=true for
-- the player and false for unresolved party slots on the same client, so this
-- genuinely varies and a static choice would be wrong somewhere.
-- Read a boolean-ish unit API without ever branching on a raw secret.
-- Returns true / false, or nil meaning UNREADABLE (call refused, or the answer
-- came back secret). Callers must treat nil as its own case: a plain `if` on
-- it silently takes the false branch, which is how "unknown" turns into a
-- confident wrong answer.
local function ReadFlag(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, val = pcall(fn, ...)
    if not ok then return nil end
    if not F.IsValueNonSecret(val) then return nil end
    return val and true or false
end

-- Tri-state, deliberately. "Is the gate shut?" cannot be a boolean, because
-- the two consumers need opposite answers when we don't know:
--   * the noise floor filters unless the gate is definitely OPEN, so an
--     unreadable answer keeps the floor (over-filtering beats a flood);
--   * the hide decision only acts on a definite SHUT, so an unreadable answer
--     shows (a wrongly-hidden row is worse than one garbage frame -- the rule
--     both reference addons state explicitly).
-- Collapsing these into one boolean gets one of them backwards.
local GATE_OPEN, GATE_SHUT, GATE_UNKNOWN = "open", "shut", "unknown"

-- Will Blizzard's CanApplyIdentityCandidateFilters actually apply
-- includeSpellIDs/excludeSpellIDs to this unit's HELPFUL auras?
--
-- Widened 2026-08-17 from a bare UnitCanAssist to the signal set both
-- DandersFrames and EllesmereUIRaidFrames converged on independently.
-- UnitCanAssist alone misses several windows where the gate is shut:
--   * VEHICLES -- it only flips once the seated state LANDS, so boarding shows
--     a visible flash of unfiltered icons. UnitUsingVehicle is true through the
--     boarding and exiting transitions too, which closes that gap. A better
--     signal, not another event. Self only: another player in a vehicle is
--     still assistable and still filters normally.
--   * CINEMATICS -- they fire UNIT_FACTION and make even the LOCAL PLAYER
--     non-assistable, and the fail-open parse persists afterwards. 12.1 forces
--     one on first login.
--   * DEAD / GHOST / DISCONNECTED -- ghost auras stream, so there is a real
--     pool to fail open. Both reference addons had to walk back an earlier
--     "no data, so no problem" assumption here.
--   * VISIBILITY / PHASE -- instance-scoped, NOT range. UnitIsVisible stays
--     true for a same-instance member far outside 40yd and goes false only
--     across instances or phases, so gating on it does not punish distance.
local function ComputeIdentityGateState(unit)
    if not unit then return GATE_UNKNOWN end

    -- UnitIsUnit rather than `unit == "player"`: in raid layouts your own
    -- token is raidN, so a string compare misses your own frame entirely.
    -- It reads secret on rated-PvP maps, in which case this falls through to
    -- the general branch below, which is correct anyway.
    if ReadFlag(UnitIsUnit, unit, "player") == true then
        local vehicleProbe = UnitUsingVehicle or UnitInVehicle
        if ReadFlag(vehicleProbe, "player") == true then return GATE_SHUT end
        -- Cleanly-false only. An unreadable self-assist keeps the historical
        -- self-exemption rather than shutting the gate on your own frame.
        if ReadFlag(UnitCanAssist, "player", "player") == false then return GATE_SHUT end
        return GATE_OPEN
    end

    -- ONE primary signal decides open-vs-unknown; the rest can only ever veto.
    --
    -- This asymmetry is load-bearing. Several of the secondary APIs go SECRET
    -- in combat on 12.1, so treating "unreadable" as evidence made the probe
    -- degrade to UNKNOWN precisely when it was needed most -- and since the
    -- noise floor keyed off "not definitely open", a clean UnitCanAssist=true
    -- was silently downgraded into a 60s cap that dropped every long tracked
    -- buff. Earth Shield (10 min) and Beacon vanishing in combat, reported
    -- 2026-08-18, was exactly this. An unreadable secondary now means "no
    -- opinion", not "maybe bad".
    local assist = ReadFlag(UnitCanAssist, "player", unit)
    if assist == false then return GATE_SHUT end

    -- Vetoes: only a DEFINITE negative shuts the gate. nil is ignored.
    if ReadFlag(UnitIsConnected, unit) == false then return GATE_SHUT end
    if ReadFlag(UnitIsVisible, unit) == false then return GATE_SHUT end
    if ReadFlag(UnitIsDeadOrGhost, unit) == true then return GATE_SHUT end

    -- UnitPhaseReason returns an enum or NIL, and nil means "same phase" --
    -- a meaningful answer, not a missing one. ReadFlag's nil-is-unreadable
    -- convention would invert that, so it is read directly. A readable,
    -- non-nil reason is a definite veto; a secret one is ignored like any
    -- other unreadable secondary.
    local okPhase, phase = pcall(UnitPhaseReason, unit)
    if okPhase and phase ~= nil and F.IsValueNonSecret(phase) then
        return GATE_SHUT
    end

    -- Only the PRIMARY signal being unreadable leaves us genuinely unsure.
    if assist == nil then return GATE_UNKNOWN end
    return GATE_OPEN
end

-- Per-frame memo, keyed by unit.
--
-- The probe went from one pcall to as many as seven when it was widened, and a
-- single identity-gate sweep asks about the same unit once PER INDICATOR --
-- three gate-backed indicators x 40 raid members is 120 calls where 40 would
-- do, all inside one frame, on exactly the roster-change path that was already
-- the most expensive thing this module does.
--
-- GetTime() is frame-resolution in WoW: it returns the same value for every
-- call within a frame, which makes it the frame identity we need without
-- hooking OnUpdate. The gate cannot meaningfully change mid-frame anyway.
local gateStateCache, gateStateStamp = {}, -1

local function IdentityGateState(unit)
    if not unit then return GATE_UNKNOWN end
    local now = GetTime()
    if now ~= gateStateStamp then
        wipe(gateStateCache)
        gateStateStamp = now
    end
    local cached = gateStateCache[unit]
    if cached == nil then
        cached = ComputeIdentityGateState(unit)
        gateStateCache[unit] = cached
    end
    return cached
end
AEI.IdentityGateState = IdentityGateState

-- The floor is a BLUNT instrument: it rejects anything longer than 60s, which
-- includes plenty of legitimately tracked buffs -- Earth Shield is 10 minutes,
-- Beacon of Light has no duration at all. So it is applied only where we
-- positively KNOW spell filtering has been discarded, never on a maybe.
--
-- That is a change of direction from the first V1.5 pass, which floored on
-- anything short of a definite OPEN. Two things make "definite SHUT only"
-- correct now:
--   1. A definite SHUT already HIDES the indicator (ApplyGateVisibility), so
--      this floor now only renders anything when the user has ticked Show
--      Unfiltered Auras -- i.e. asked to see the pool anyway.
--   2. Flooring an UNKNOWN was the worse of both outcomes: the pool is shown
--      regardless (the hide never fires on UNKNOWN), just with every long
--      tracked buff stripped out of it.
--
-- t.showUnfiltered switches it off too, and must: that option is worded as
-- "show me the pool anyway", so leaving a duration cap on it would deliver a
-- pool that is neither filtered NOR complete -- the tracked long buffs stripped
-- out and all the short noise kept, which is the worst of both and the exact
-- opposite of what the label promises.
local function NoiseFloorMaxDuration(unit, t)
    if t and t.showUnfiltered then return nil end
    return IdentityGateState(unit) == GATE_SHUT and AURA_MAX_DURATION or nil
end

-- The unit an indicator wrapper is showing. The wrapper is always a child of
-- the unit button, so this stays correct across the secure header's unit
-- reassignments without caching anything.
local function WrapperUnit(wrapper)
    local button = wrapper and wrapper.GetParent and wrapper:GetParent()
    if not button then return nil end
    return button.unit or (button.GetAttribute and button:GetAttribute("unit"))
end

-- Has the identity gate reading for this wrapper's CURRENT unit changed since
-- the last time we pushed candidate filters for it?
--
-- Re-pushing is not free: Blizzard's SetAuraGroupCandidateFilters has no
-- equality guard of its own -- it stores, then immediately re-parses every
-- aura on the unit. That cost is the whole reason the gate refresh was
-- originally narrowed to vehicle transitions only. Caching the last reading
-- here inverts that trade: a blunt refresh on ANY state change that might
-- move the gate costs one UnitCanAssist call per indicator when nothing
-- actually moved, and only re-parses when it did.
--
-- Keyed on the unit as well as the reading, because the secure header
-- reassigns button units and "same answer, different unit" still has to push.
local function GateReadingMoved(wrapper)
    local unit = WrapperUnit(wrapper)
    -- Measured once and cached on the wrapper: the tri-state drives the hide
    -- decision (ApplyGateVisibility) as well as the floor, and probing twice
    -- per refresh would double the unit-API calls for no benefit.
    local state = IdentityGateState(unit)
    wrapper._gateState = state

    -- Keyed on the FILTER VALUE this state would push, not on the state name.
    --
    -- The question this answers is "would re-pushing change anything", and the
    -- answer is no whenever the derived maxDuration is unchanged. OPEN and
    -- UNKNOWN both yield no floor, so flapping between them must NOT count as
    -- a move: every false "moved" is a SetAuraGroupCandidateFilters, and that
    -- runs an immediate UpdateAllAuras with no equality guard of Blizzard's
    -- own -- ~120 full re-parses in one frame on a 40-man with three
    -- gate-backed indicators. Keying on the state name (briefly, 2026-08-18)
    -- made exactly that happen on every OPEN<->UNKNOWN flicker.
    --
    -- Derived through NoiseFloorMaxDuration rather than recomputed here, so
    -- the key cannot drift from what actually gets pushed -- it also accounts
    -- for showUnfiltered suppressing the floor.
    local gate = NoiseFloorMaxDuration(unit, wrapper._t)
    if wrapper._gateMeasured and wrapper._gateUnit == unit and wrapper._gateValue == gate then
        return false
    end
    wrapper._gateMeasured, wrapper._gateUnit, wrapper._gateValue = true, unit, gate
    return true
end

-- ---------------------------------------------------------------------
-- Gate-driven visibility (V1.5)
-- ---------------------------------------------------------------------
-- With the gate shut, a spell-list indicator cannot tell Pain Suppression from
-- a random proc -- so what it renders is not merely noisy, it ASSERTS an
-- external cooldown that may not exist. Both reference addons answer this the
-- same way: stop drawing rather than draw something false.
--
-- RENDER-SIDE ONLY. This hides the plain wrapper Frame this addon owns; it
-- never touches the AuraContainer, its buttons, or any secure state, so it is
-- combat-safe and obeys the AuraEngine "no API calls on managed buttons" rule.
--
-- Acts on GATE_SHUT only, never GATE_UNKNOWN -- see IdentityGateState.
-- shouldHide(wrapper) -> boolean; nil means "hide whenever the gate is SHUT".
--
-- Not every indicator loses its filtering to the same signal, so this is asked
-- per wrapper rather than assumed. An indicator narrowing by spell list fails
-- open on the assist gate; one narrowing by the PLAYER token does not, but has
-- its own failure mode on visibility. Answering "is the gate shut" for both
-- would hide the second one in cases where it is still filtering perfectly.
local function InstallGateVisibility(wrapper, shouldHide)
    wrapper._gateShouldHide = shouldHide

    -- Composition: a settings apply or a HandleIndicators rebuild will call
    -- Show() on this wrapper without knowing about the gate. Re-assert here
    -- rather than trying to find every such caller.
    wrapper:HookScript("OnShow", function(self)
        if self._gateHidden then self:Hide() end
    end)

    function wrapper:SetGateHidden(hidden)
        hidden = hidden and true or nil
        if self._gateHidden == hidden then return end
        self._gateHidden = hidden
        if hidden then
            self:Hide()
        elseif self._t and self._t.enabled then
            -- Only the gate's own hide is being lifted; an indicator the user
            -- disabled stays hidden.
            self:Show()
        end
    end
end

local function ApplyGateVisibility(wrapper)
    if not wrapper.SetGateHidden then return end
    -- User opted out: keep the unfiltered pool visible.
    local t = wrapper._t
    if t and t.showUnfiltered then
        wrapper:SetGateHidden(false)
        return
    end
    local shouldHide = wrapper._gateShouldHide
    if shouldHide then
        wrapper:SetGateHidden(shouldHide(wrapper) == true)
        return
    end
    wrapper:SetGateHidden(wrapper._gateState == GATE_SHUT)
end

-- Seed the gate reading and hide decision for the state a container is BORN
-- into. The initial candidate filters come from the AddAuraGroup declaration,
-- not from RefreshCandidateFilters, so without this a container created while
-- the gate is already shut renders its unfiltered pool until some later event
-- happens to move the gate. Measure-only: deliberately NOT a filter push,
-- which would be an immediate redundant re-parse.
--
-- No-ops on wrappers with no gate visibility installed (debuffs, CC) -- those
-- are HARMFUL pools, and Blizzard's gate only tests auraData.isHelpful.
-- Declared after ApplyGateVisibility because it calls it: a local referenced
-- before its declaration compiles as a nil GLOBAL, with no error until it runs.
local function SeedGateState(wrapper)
    if not wrapper.SetGateHidden then return end
    GateReadingMoved(wrapper)
    ApplyGateVisibility(wrapper)
end

local function BuildCandidateFilters(t, unit)
    local baseList = GetPlayerClassHealerSpells()
    local effective = F.GetEffectiveSpellList(t.useBuiltInHots, baseList, nil, t.hiddenBuiltInHots)
    local set = {}
    for _, id in ipairs(effective) do set[id] = true end
    local filters = { includeSpellIDs = set, maxDuration = NoiseFloorMaxDuration(unit, t) }
    -- NOTE: castBy is deliberately NOT expressed here -- see
    -- HealerFilterTokens below. This used to set
    -- `filters.isFromPlayerOrPlayerPet = true` for castBy == "me", which is
    -- WRONG: that boolean matches auras cast by ANY player, not just you.
    -- (Confirmed from EllesmereUI's own AuraContainer implementation, which
    -- carries a verified note: "the isFromPlayerOrPlayerPet candidate boolean
    -- matches auras cast by ANY player (verified: same-spec allies' buffs
    -- pass it), so own-cast filtering rides the PLAYER filter token
    -- instead.")
    return filters
end

-- Own-cast filtering belongs in the FILTER STRING, not candidateFilters.
-- Two reasons, both important:
--   1. Correctness -- "PLAYER" means strictly the local player's casts,
--      whereas isFromPlayerOrPlayerPet means any player's (see above).
--   2. Resilience -- filter-string tokens are evaluated OUTSIDE Blizzard's
--      CanApplyIdentityCandidateFilters gate, so they keep working even
--      while includeSpellIDs is being silently discarded. On live 12.1 that
--      is not hypothetical: UnitCanAssist("player","player") returns a real
--      non-secret `false`, which closes that gate for every helpful aura and
--      drops the spell-list filtering entirely. "PLAYER" is what still
--      narrows this indicator to something usable meanwhile.
-- "others" has no inverse token, so it falls back to "anyone" rather than
-- silently misfiltering.
local function HealerFilterTokens(t)
    if t and t.castBy == "me" then
        return { "HELPFUL", "PLAYER" }
    end
    return { "HELPFUL" }
end

-- The container auto-sizes to fit its content (growing wider as more icons
-- appear), so ITS OWN frame anchor -- not just the internal aura-flow
-- direction -- has to match the orientation too: which edge stays fixed as
-- that rect grows determines which way it visually grows. Anchoring the
-- container to the wrapper's TOPLEFT unconditionally (regardless of
-- orientation) always grows the rect rightward from a fixed left edge,
-- which is exactly what left-to-right looks like even when set to
-- right-to-left.
local function ContainerAnchorCorner(orientation)
    return (orientation == "left-to-right") and "TOPLEFT" or "TOPRIGHT"
end

local function ExtractSize(t)
    local sz = t.size or { 16, 16 }
    if type(sz[1]) == "table" then sz = sz[1] end
    return sz[1] or 16, sz[2] or 16
end

-- Preview-only: a row of `count` static icon frames, children of `wrapper`,
-- laid out the same corner/direction ContainerAnchorCorner would grow the
-- real AuraContainer in. Shared by healerHots and the cooldown kinds since
-- both need the exact same "show N dummy icons matching the max-icons
-- setting" mockup. `iconPaths` is an array of texture paths, one per slot
-- (cycled if shorter than `count`) -- distinct icons per slot rather than
-- the same one repeated, so e.g. Healer HoTs' preview reads as "3 different
-- HoTs" rather than "the same PW:S 3 times".
-- Returns the icon array, a Reposition() closure that re-lays-out/shows-
-- hides them against wrapper._orientation/_w/_h/_num (call after any of
-- those change), an ApplyIcons(newIconPaths) closure to swap textures (call
-- after the effective spell list changes, e.g. RefreshSpellList), and a
-- SetBorderShown(show) closure so the preview reflects the icon-border
-- checkbox too, not just live frames.
local FALLBACK_ICON_GAP = 1
-- Sample number drawn in the preview's duration text when no threshold is
-- configured. Two digits so the text block is roughly its real worst-case
-- width, which is what matters when judging placement.
local FALLBACK_DURATION_SAMPLE = "12"
local function CreateFallbackIconRow(wrapper, count, iconPaths, defaultW, defaultH, styleKey)
    local icons = {}
    local function ApplyIcons(paths)
        local n = #paths
        for i, f in ipairs(icons) do
            f.tex:SetTexture(n > 0 and paths[((i - 1) % n) + 1] or [[Interface\Icons\INV_Misc_QuestionMark]])
        end
    end
    for i = 1, count do
        local f = CreateFrame("Frame", nil, wrapper)
        f:SetFrameLevel(wrapper:GetFrameLevel())
        f.tex = f:CreateTexture(nil, "ARTWORK")
        f.tex:SetAllPoints()
        f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        F.CreateBorder(f, 0, 0, 0, 1, 1)
        F.SetBorderShown(f, false)
        -- Preview duration text (user request 2026-08-13, "can we get the
        -- duration text to show on the preview so we can see where we are
        -- moving it"). The real duration text is drawn by the engine on
        -- container-managed buttons, which the preview never has -- so, like
        -- the icons themselves, it has to be mocked up here.
        f.duration = f:CreateFontString(nil, "OVERLAY")
        f.duration:Hide()
        f.stack = f:CreateFontString(nil, "OVERLAY")
        f.stack:Hide()
        icons[i] = f
    end
    ApplyIcons(iconPaths)
    local function SetBorderShown(show)
        for _, f in ipairs(icons) do F.SetBorderShown(f, show) end
    end
    -- Restyle + reposition the mock duration text from the SAME style fields
    -- the live engine path reads (see ApplyStyleToRegions in AuraEngine.lua),
    -- so the preview tracks font/colour/offset changes rather than drifting
    -- from what the real icons will look like.
    local function RefreshDuration(mode)
        local AE = SquizzFrames.AuraEngine
        if not AE then return end
        local style = (styleKey and AE.styles[styleKey]) or {}
        -- A threshold mode only ever renders at or below that many seconds, so
        -- preview it with that exact number -- it doubles as a reminder of
        -- which threshold is active.
        local threshold = tonumber(mode)
        local text = threshold and tostring(threshold) or FALLBACK_DURATION_SAMPLE
        local shown = (mode ~= "never") and (style.showDuration ~= false)
        for _, f in ipairs(icons) do
            local fs = f.duration
            fs:SetFont(AE.ResolveFont(style.durationFont), style.durationFontSize or 11,
                style.durationFontFlags or "OUTLINE")
            local c = style.durationColor
            if c then fs:SetTextColor(c[1], c[2], c[3], c[4] or 1) end
            fs:ClearAllPoints()
            fs:SetPoint(style.durationPoint or "TOP", f, style.durationRelPoint or "BOTTOM",
                style.durationX or 0, style.durationY or -2)
            fs:SetText(text)
            fs:SetShown(shown)
        end
    end

    -- Stack-count text, same deal as the duration text above: styled from the
    -- SAME style.stack* fields ApplyStyleToRegions reads, so the preview and
    -- the real icons agree on font, anchor, offset and colour.
    --
    -- "2" as the sample: on a live frame the engine only writes a count when
    -- there is actually more than one application, so a single digit is the
    -- honest common case and is the right width to judge placement against.
    local function RefreshStacks(show)
        local AE = SquizzFrames.AuraEngine
        if not AE then return end
        local style = (styleKey and AE.styles[styleKey]) or {}
        for _, f in ipairs(icons) do
            local fs = f.stack
            fs:SetFont(AE.ResolveFont(style.stackFont), style.stackFontSize or 12,
                style.stackFontFlags or "OUTLINE")
            local c = style.stackColor
            if c then fs:SetTextColor(c[1], c[2], c[3], c[4] or 1) end
            fs:ClearAllPoints()
            fs:SetPoint(style.stackPoint or "BOTTOMRIGHT", f,
                style.stackRelPoint or style.stackPoint or "BOTTOMRIGHT",
                style.stackX or 1, style.stackY or -1)
            fs:SetText("2")
            fs:SetShown(show ~= false and style.showStack ~= false)
        end
    end
    local function Reposition()
        local corner = ContainerAnchorCorner(wrapper._orientation)
        local iw = wrapper._w or defaultW
        local ih = wrapper._h or defaultH
        local growRight = (wrapper._orientation == "left-to-right")
        local shown = math.min(wrapper._num or count, count)
        local prev
        for i, f in ipairs(icons) do
            if i <= shown then
                f:ClearAllPoints()
                f:SetSize(iw, ih)
                if not prev then
                    f:SetPoint(corner, wrapper, corner, 0, 0)
                elseif growRight then
                    f:SetPoint("TOPLEFT", prev, "TOPRIGHT", FALLBACK_ICON_GAP, 0)
                else
                    f:SetPoint("TOPRIGHT", prev, "TOPLEFT", -FALLBACK_ICON_GAP, 0)
                end
                f:Show()
                prev = f
            else
                f:Hide()
            end
        end
    end
    return icons, Reposition, ApplyIcons, SetBorderShown, RefreshDuration, RefreshStacks
end

-- Shared implementation of the "Show Duration" dropdown for every
-- AuraEngine-backed indicator (all four had an identical copy of this).
--
--   "never"        -- hide the duration FontString outright.
--   a NUMBER (5/3) -- show the countdown only once it drops BELOW that many
--                     seconds.
--   anything else  -- always on.
--
-- The threshold is handed to the style's own duration formatter rather than
-- evaluated here. That's not a stylistic choice: the remaining duration is a
-- secret value, so Lua cannot compare it against a threshold at all. Pushing
-- it into the formatter moves the comparison engine-side, which is the only
-- place it can legally happen -- see ThresholdDurationBreakpoints in
-- AuraEngine.lua. Before this, every threshold option fell through to
-- always-on and the text simply never went away (user report 2026-08-13).
--
-- "onHover" still falls through to always-on: it would need a script handler
-- on the aura button to detect the hover, and script handlers on
-- engine-managed buttons are forbidden outright (CLAUDE.md section 7). The
-- legacy scan-based path never implemented it either.
local function ApplyDurationMode(styleKey, mode)
    local AE = SquizzFrames.AuraEngine
    local style = AE and AE.styles[styleKey]
    if not style then return end
    local threshold = tonumber(mode)
    style.showDuration = (mode ~= "never")
    style.durationThreshold = threshold
    AE.SetDurationThreshold(styleKey, threshold)
    AE.RestyleSoon(styleKey)
end

local function BuildSpec(button, t)
    local AE = SquizzFrames.AuraEngine
    local w, h = ExtractSize(t)
    -- Which unit this container will bind to -- NoiseFloorMaxDuration needs it
    -- to decide whether the spell-list filter will actually be honoured here.
    local specUnit = button and (button.unit or button:GetAttribute("unit"))

    AE.styles[STYLE_KEY] = AE.styles[STYLE_KEY] or {
        width = w, height = h,
        showDuration = (t.durationVisibility ~= "never"),
        stackPoint = "BOTTOMRIGHT", stackX = 1, stackY = -1,
        durationPoint = "TOP", durationRelPoint = "BOTTOM", durationY = -2,
        -- F.CreateBorder(host, r,g,b,a,size) shape -- see AuraEngine.lua's
        -- ApplyStyleToRegions borderHost block (`local b = style.border`).
        border = (t.showIconBorder ~= false) and { 0, 0, 0, 1, size = 1 } or nil,
    }
    -- Font settings (typeface, size, outline, anchor, X/Y offset, colour
    -- for BOTH the stack and duration text) are re-applied on every
    -- build, not folded into the `or {}` above: that table is only
    -- created once and then reused for the lifetime of the style, so
    -- anything set inside it can never respond to a settings change.
    AE.ApplyFontSettings(AE.styles[STYLE_KEY], t.font)

    local growthH = (t.orientation == "left-to-right") and "RIGHT" or "LEFT"

    return {
        layout = {
            anchorPoint = (growthH == "RIGHT") and "LEFT" or "RIGHT",
            growthH = growthH,
            growthV = "DOWN",
        },
        groups = {
            {
                key = GROUP_KEY,
                filter = HealerFilterTokens(t),
                maxFrameCount = t.num or 5,
                candidateFilters = BuildCandidateFilters(t, specUnit),
                style = STYLE_KEY,
                layout = { elementWidth = w, elementHeight = h },
            },
        },
    }
end

-- Create (or fetch) the wrapper for this button/indicator table. The wrapper
-- is what Indicators.lua treats as "the indicator" -- it never touches the
-- AuraContainer directly.
function AEI.CreateHealerHotsIndicator(button, t)
    if not button then return nil end

    local AE = SquizzFrames.AuraEngine
    if not AE then return nil end

    local wrapper = CreateFrame("Frame", nil, button)
    wrapper._sfType = "builtin"
    wrapper._num = t.num or 5
    wrapper._castBy = t.castBy or "anyone"
    wrapper._orientation = t.orientation or "right-to-left"
    wrapper._t = t

    -- Healer HoTs fails open on a DIFFERENT signal depending on how it is
    -- narrowing, so neither "always hide when shut" nor "never hide" is right:
    --
    --   castBy == "me"  -> narrows via the PLAYER filter TOKEN, which is
    --      evaluated outside the assist gate and keeps filtering fine for a
    --      cross-faction unit. But source-relative pools fail open when the
    --      engine cannot attribute a caster -- i.e. UnitIsVisible false,
    --      across instances or phases -- and "only my buffs" then passes every
    --      caster's. That breaks in isolation while UnitCanAssist stays TRUE,
    --      so the assist gate never catches it.
    --   castBy ~= "me" -> narrows via the spell list, which is exactly what
    --      the assist gate discards. Ordinary gate rules apply.
    InstallGateVisibility(wrapper, function(w)
        if w._t and w._t.castBy == "me" then
            return ReadFlag(UnitIsVisible, WrapperUnit(w)) == false
        end
        return w._gateState == GATE_SHUT
    end)

    -- Capture the NATIVE SetSize before overriding it below, so the override
    -- can still resize the wrapper frame itself instead of just silently
    -- swallowing the call. Without this the wrapper's own rect stays frozen
    -- at its initial size forever -- everything anchored relative to it (the
    -- preview drag/highlight border, snap-line gathering) never follows a
    -- live Size setting change even though the container/fallback icons
    -- resize correctly.
    local nativeSetSize = wrapper.SetSize
    local w, h = ExtractSize(t)
    nativeSetSize(wrapper, w, h)

    -- Preview-only fallback: AuraContainer is driven entirely by Blizzard's
    -- C-side engine bound to a real unit, so fake aura data can't be
    -- injected into it the way BuiltIn_Update/Custom_Dispatch fake data for
    -- their own frames. A row of t.num static icons stands in instead, so
    -- the preview communicates the max-icons setting rather than just one
    -- representative icon (see CreateFallbackIconRow). The container itself
    -- is bound to a deliberately-invalid unit below (isPreview branch) so it
    -- can never show real data over/instead of these -- it used to be bound
    -- to the preview button's real "player" unit, so casting a real HoT
    -- while the preview was open replaced the static mockup with real data.
    local IndicatorsModule = SquizzFrames.Indicators
    local isPreview = IndicatorsModule and IndicatorsModule.IsPreviewButton(button)

    -- Build the spec NOW, before the preview fallback below, and reuse it for
    -- the container further down.
    --
    -- Build*Spec is what creates and refreshes AE.styles[<key>] -- including
    -- the font settings, via AE.ApplyFontSettings -- and the preview's mock
    -- duration/stack text reads that same style so it can match the real
    -- icons. It used to be evaluated only inside the `if not isPreview`
    -- container branch below, so with no live container yet (designing solo,
    -- or party frames hidden) the style did not exist at all: the preview fell
    -- back to hardcoded defaults, and font edits were silently dropped because
    -- ApplyFontSettings early-returns on a nil style. Only the CONTAINER is
    -- preview-skipped now, which is all that branch was ever really about.
    local spec = BuildSpec(button, t)

    local RepositionFallback, ApplyFallbackIcons, SetFallbackBorderShown, RefreshFallbackDuration, RefreshFallbackStacks
    if isPreview then
        _, RepositionFallback, ApplyFallbackIcons, SetFallbackBorderShown, RefreshFallbackDuration, RefreshFallbackStacks =
            CreateFallbackIconRow(
                wrapper, t.num or 5, PickRepresentativeHealerSpells(t, t.num or 5), w, h, STYLE_KEY)
        RepositionFallback()
        SetFallbackBorderShown(t.showIconBorder ~= false)
        RefreshFallbackDuration(t.durationVisibility or "always")
        RefreshFallbackStacks(t.showStack)
    end

    function wrapper:SetSize(width, height)
        nativeSetSize(self, width, height)
        wrapper._w, wrapper._h = width, height
        local container = wrapper._container
        if container then
            container:SetAuraGroupLayout(GROUP_KEY, { elementWidth = width, elementHeight = height })
            local style = AE.styles[STYLE_KEY]
            if style then
                style.width, style.height = width, height
                AE.RestyleSoon(STYLE_KEY)
            end
        end
        if RepositionFallback then RepositionFallback() end
    end

    function wrapper:SetOrientation(token)
        wrapper._orientation = token
        local container = wrapper._container
        if container then
            local growthH = (token == "left-to-right") and "RIGHT" or "LEFT"
            container:SetFlowLayoutAnchorPoint((growthH == "RIGHT") and "LEFT" or "RIGHT")
            container:SetFlowLayoutGrowthDirection(AE.FlowDir(growthH), AE.FlowDir("DOWN"))
            container:ClearAllPoints()
            container:SetPoint(ContainerAnchorCorner(token), wrapper, ContainerAnchorCorner(token), 0, 0)
        end
        if RepositionFallback then RepositionFallback() end
    end

    function wrapper:SetNum(n)
        wrapper._num = n
        local container = wrapper._container
        if container then
            container:SetAuraGroupMaxFrameCount(GROUP_KEY, n)
        end
        if RepositionFallback then RepositionFallback() end
    end

    function wrapper:SetCastBy(mode)
        wrapper._castBy = mode
        wrapper._t.castBy = mode
        local container = wrapper._container
        if container then
            -- The FILTER STRING is what carries castBy now (see
            -- HealerFilterTokens), so this has to update too -- refreshing
            -- only the candidate filters would silently do nothing.
            -- pcall'd to match RefreshFilters' handling of the same call.
            pcall(container.SetAuraGroupFilterString, container, GROUP_KEY,
                AE.Filter(unpack(HealerFilterTokens(wrapper._t))))
            container:SetAuraGroupCandidateFilters(GROUP_KEY, BuildCandidateFilters(wrapper._t, WrapperUnit(wrapper)))
        end
    end

    -- Re-derives the candidate filter set live. Called by Indicators.lua's
    -- ApplySettingToOne whenever the "Built-in Spells" checklist changes
    -- (Use Default Spells toggle or a per-spell hide/show) -- same mechanism
    -- externalCooldowns/defensiveCooldowns already use (see
    -- BuildCooldownCandidateFilters/RefreshSpellList below).
    function wrapper:RefreshSpellList(newT)
        wrapper._t = newT or wrapper._t
        wrapper:RefreshCandidateFilters()
        if ApplyFallbackIcons then
            ApplyFallbackIcons(PickRepresentativeHealerSpells(wrapper._t, wrapper._num or 5))
        end
    end

    -- Re-push the candidate filters WITHOUT any setting having changed --
    -- see AEI.RefreshIdentityGatedFilters for why that's a thing at all.
    -- The point is BuildCandidateFilters re-running NoiseFloorMaxDuration
    -- against the wrapper's current unit, so a gate that has opened or shut
    -- since creation is measured again rather than assumed.
    --
    -- onlyIfGateMoved: skip the push (and its full re-parse) when the gate
    -- reads the same as last time. Used by the blanket state-change refresh;
    -- a real settings change calls this with no argument and always pushes.
    function wrapper:RefreshCandidateFilters(onlyIfGateMoved)
        local container = wrapper._container
        if not container then return end
        -- Called unconditionally so the cached reading stays honest on the
        -- settings-change path too, not just the guarded one.
        local moved = GateReadingMoved(wrapper)
        -- Before the short-circuit: the visibility decision also has to follow
        -- a SETTINGS change (the Show Unfiltered toggle), which moves nothing.
        ApplyGateVisibility(wrapper)
        if onlyIfGateMoved and not moved then return end
        container:SetAuraGroupCandidateFilters(GROUP_KEY, BuildCandidateFilters(wrapper._t, WrapperUnit(wrapper)))
    end

    -- Healer HoTs uses the Always/Never-only dropdown, so no threshold ever
    -- reaches here -- but it goes through the same shared helper as the rest
    -- so there's one implementation to maintain.
    function wrapper:SetDurationMode(mode)
        ApplyDurationMode(STYLE_KEY, mode)
        if RefreshFallbackDuration then RefreshFallbackDuration(mode) end
    end

    -- Full font settings for the stack and duration text: typeface,
    -- size, outline, ANCHOR and X/Y OFFSET, colour. Preferred over the
    -- generic SetFont dispatch in Indicators.lua, which only forwards
    -- (file, size, flags) and silently drops the rest -- see
    -- AE.ApplyFontSettings.
    function wrapper:SetFontTable(fontTable)
        AE.ApplyFontSettings(AE.styles[STYLE_KEY], fontTable)
        AE.RestyleSoon(STYLE_KEY)
        if RefreshFallbackDuration then
            RefreshFallbackDuration(t.durationVisibility or "always")
        end
        if RefreshFallbackStacks then RefreshFallbackStacks(t.showStack) end
    end

    -- Master on/off for the stack-count text. The style field is read by
    -- ApplyStyleToRegions; without a setter here the checkbox reached
    -- nothing and stacks were always on.
    function wrapper:SetShowStack(show)
        local style = AE.styles[STYLE_KEY]
        if not style then return end
        style.showStack = (show ~= false)
        AE.RestyleSoon(STYLE_KEY)
        if RefreshFallbackStacks then RefreshFallbackStacks(show) end
    end
    -- X/Y offset for the duration text, relative to its default anchor
    -- (TOP of the text, BOTTOM of the icon). Shared style, so this moves the
    -- duration text on every button using this style, same as every other
    -- setting here.
    function wrapper:SetDurationOffset(offset)
        local style = AE.styles[STYLE_KEY]
        if not style then return end
        style.durationX = offset[1] or 0
        style.durationY = offset[2] or -2
        AE.RestyleSoon(STYLE_KEY)
        -- The preview's duration text is a separate mock FontString, not an
        -- engine-managed region, so RestyleSoon doesn't reach it -- and this
        -- slider is precisely the one you want to watch while dragging.
        if RefreshFallbackDuration then
            RefreshFallbackDuration(t.durationVisibility or "always")
        end
    end

    -- Combat-safely deferred like every other RestyleSoon call here -- see
    -- AuraEngine.lua's InCombatLockdown guard on the restyler's OnUpdate.
    -- Also toggles the preview's own fallback row directly, since that's a
    -- separate set of frames (not styled via AE.styles at all).
    function wrapper:SetShowBorder(show)
        local style = AE.styles[STYLE_KEY]
        if style then
            style.border = show and { 0, 0, 0, 1, size = 1 } or nil
            AE.RestyleSoon(STYLE_KEY)
        end
        if SetFallbackBorderShown then SetFallbackBorderShown(show) end
    end

    -- Preview never gets a real AuraContainer at all -- a deliberately
    -- invalid unit token was tried here first (matching CreateDispelsIndicator's
    -- trick) on the assumption that SetUnit() with a garbage string is
    -- inert, but real casts still showed up in the preview while it was
    -- open, so that assumption doesn't hold for this (AddAuraGroup-based)
    -- container. Skipping RequestContainer entirely removes any possibility
    -- of real data reaching it, regardless of how SetUnit actually handles
    -- an invalid token -- wrapper._container simply stays nil, which every
    -- setter above already treats as a no-op guard.
    if not isPreview then
        -- NO "player" fallback: a unit-less button must not build a container bound
        -- to the player's own auras (see OnPartyButtonsWired). AE.RequestContainer
        -- asserts on a nil unit, so callers guard before reaching it.
        local unit = button.unit or button:GetAttribute("unit")
        AE.RequestContainer(wrapper, unit, spec, function(container)
            wrapper._container = container
            local corner = ContainerAnchorCorner(wrapper._orientation)
            container:ClearAllPoints()
            container:SetPoint(corner, wrapper, corner, 0, 0)
            container:SetShown(wrapper:IsShown())
            SeedGateState(wrapper)
        end)
    end

    return wrapper
end

-- ------------------------------------------------------------------
-- External / Defensive Cooldowns
-- ------------------------------------------------------------------
-- The legacy versions (BuiltIn_Update.lua's ScanAurasForCooldownGrid, via
-- C_UnitAuras.GetAuraDataByIndex) stop returning data mid-combat -- exactly
-- the secret-value problem Dispels/Healer HoTs already solved by moving to
-- AuraContainer instead of a manual scan. Same fix here: a dynamic
-- includeSpellIDs candidate filter (curated + custom - hidden, from
-- F.GetEffectiveSpellList) instead of a static set like healerHots'.
local COOLDOWN_KINDS = {
    externalCooldowns = {
        groupKey = "externalCooldowns", styleKey = "externalCooldowns",
        curated = "externalCooldowns", useField = "useBuiltInExternals",
        customField = "customExternals", hiddenField = "hiddenBuiltInExternals",
    },
    defensiveCooldowns = {
        groupKey = "defensiveCooldowns", styleKey = "defensiveCooldowns",
        curated = "defensiveCooldowns", useField = "useBuiltInDefensives",
        customField = "customDefensives", hiddenField = "hiddenBuiltInDefensives",
    },
}

local flattenedCuratedCache = {}
local function GetFlattenedCurated(curatedName)
    local flat = flattenedCuratedCache[curatedName]
    if flat then return flat end
    flat = F.FlattenSpellTable(SquizzFrames.defaults and SquizzFrames.defaults[curatedName] or {})
    flattenedCuratedCache[curatedName] = flat
    return flat
end

local function BuildCooldownCandidateFilters(kind, t, unit)
    local baseList = GetFlattenedCurated(kind.curated)
    local effective = F.GetEffectiveSpellList(t[kind.useField], baseList, t[kind.customField], t[kind.hiddenField])
    local set = {}
    for _, id in ipairs(effective) do set[id] = true end
    -- Conditional noise floor -- see NoiseFloorMaxDuration. Kept in step with
    -- Healer HoTs deliberately: the same permanent-aura exclusion applies here
    -- (Paladin's seasonal Blessings, for one), and having the two disagree is
    -- how you get "it works on one indicator but not the other".
    return { includeSpellIDs = set, maxDuration = NoiseFloorMaxDuration(unit, t) }
end

-- Preview-only: same reasoning as PickRepresentativeHealerSpells -- up to
-- `count` DISTINCT spells from this kind's own effective spell list, so the
-- fallback row shows real variety instead of one icon repeated.
local function PickRepresentativeCooldownIcons(kind, t, count)
    local baseList = GetFlattenedCurated(kind.curated)
    local effective = F.GetEffectiveSpellList(t[kind.useField], baseList, t[kind.customField], t[kind.hiddenField])
    local icons = {}
    for i = 1, math.min(count, #effective) do
        icons[i] = F.GetSpellIcon(effective[i]) or [[Interface\Icons\INV_Misc_QuestionMark]]
    end
    if #icons == 0 then
        icons[1] = [[Interface\Icons\INV_Misc_QuestionMark]]
    end
    return icons
end

local function BuildCooldownSpec(kind, t, specUnit)
    local AE = SquizzFrames.AuraEngine
    local w, h = ExtractSize(t)

    AE.styles[kind.styleKey] = AE.styles[kind.styleKey] or {
        width = w, height = h,
        showDuration = (t.durationVisibility ~= "never"),
        stackPoint = "BOTTOMRIGHT", stackX = 1, stackY = -1,
        durationPoint = "TOP", durationRelPoint = "BOTTOM", durationY = -2,
        border = (t.showIconBorder ~= false) and { 0, 0, 0, 1, size = 1 } or nil,
    }
    -- Font settings (typeface, size, outline, anchor, X/Y offset, colour
    -- for BOTH the stack and duration text) are re-applied on every
    -- build, not folded into the `or {}` above: that table is only
    -- created once and then reused for the lifetime of the style, so
    -- anything set inside it can never respond to a settings change.
    AE.ApplyFontSettings(AE.styles[kind.styleKey], t.font)

    local growthH = (t.orientation == "left-to-right") and "RIGHT" or "LEFT"

    return {
        layout = {
            anchorPoint = (growthH == "RIGHT") and "LEFT" or "RIGHT",
            growthH = growthH,
            growthV = "DOWN",
        },
        groups = {
            {
                key = kind.groupKey,
                filter = { "HELPFUL" },
                maxFrameCount = t.num or 5,
                candidateFilters = BuildCooldownCandidateFilters(kind, t, specUnit),
                style = kind.styleKey,
                layout = { elementWidth = w, elementHeight = h },
            },
        },
    }
end

local function CreateCooldownIndicator(kind, button, t)
    if not button then return nil end

    local AE = SquizzFrames.AuraEngine
    if not AE then return nil end

    local wrapper = CreateFrame("Frame", nil, button)
    wrapper._sfType = "builtin"
    wrapper._num = t.num or 5
    wrapper._orientation = t.orientation or "right-to-left"
    wrapper._t = t

    -- Always vulnerable: both cooldown indicators track OTHER players' casts,
    -- so there is no own-cast token to fall back on -- the spell list is all
    -- they have, and it is the thing the gate discards.
    InstallGateVisibility(wrapper)

    local nativeSetSize = wrapper.SetSize
    local w, h = ExtractSize(t)
    nativeSetSize(wrapper, w, h)

    -- Preview-only fallback -- same reasoning/mechanism as healerHots' (see
    -- its comment above CreateFallbackIconRow's call): a row of t.num static
    -- icons, and the container below bound to a fake unit so it can never
    -- show real data instead of them.
    local IndicatorsModule = SquizzFrames.Indicators
    local isPreview = IndicatorsModule and IndicatorsModule.IsPreviewButton(button)

    -- Spec built here, not inside the container branch below -- it is what
    -- creates/refreshes AE.styles[<key>] (fonts included), which the
    -- preview's mock duration/stack text reads. See CreateHealerHotsIndicator
    -- for the full reasoning; only the CONTAINER is preview-skipped.
    local spec = BuildCooldownSpec(kind, t, button and (button.unit or button:GetAttribute("unit")))
    local RepositionFallback, ApplyFallbackIcons, SetFallbackBorderShown, RefreshFallbackDuration, RefreshFallbackStacks
    if isPreview then
        _, RepositionFallback, ApplyFallbackIcons, SetFallbackBorderShown, RefreshFallbackDuration, RefreshFallbackStacks =
            CreateFallbackIconRow(
                wrapper, t.num or 5, PickRepresentativeCooldownIcons(kind, t, t.num or 5), w, h,
                kind.styleKey)
        RepositionFallback()
        SetFallbackBorderShown(t.showIconBorder ~= false)
        RefreshFallbackDuration(t.durationVisibility or "always")
        RefreshFallbackStacks(t.showStack)
    end

    function wrapper:SetSize(width, height)
        nativeSetSize(self, width, height)
        wrapper._w, wrapper._h = width, height
        local container = wrapper._container
        if container then
            container:SetAuraGroupLayout(kind.groupKey, { elementWidth = width, elementHeight = height })
            local style = AE.styles[kind.styleKey]
            if style then
                style.width, style.height = width, height
                AE.RestyleSoon(kind.styleKey)
            end
        end
        if RepositionFallback then RepositionFallback() end
    end

    function wrapper:SetOrientation(token)
        wrapper._orientation = token
        local container = wrapper._container
        if container then
            local growthH = (token == "left-to-right") and "RIGHT" or "LEFT"
            container:SetFlowLayoutAnchorPoint((growthH == "RIGHT") and "LEFT" or "RIGHT")
            container:SetFlowLayoutGrowthDirection(AE.FlowDir(growthH), AE.FlowDir("DOWN"))
            container:ClearAllPoints()
            container:SetPoint(ContainerAnchorCorner(token), wrapper, ContainerAnchorCorner(token), 0, 0)
        end
        if RepositionFallback then RepositionFallback() end
    end

    function wrapper:SetNum(n)
        wrapper._num = n
        local container = wrapper._container
        if container then
            container:SetAuraGroupMaxFrameCount(kind.groupKey, n)
        end
        if RepositionFallback then RepositionFallback() end
    end

    -- Re-derives includeSpellIDs from useBuiltIn/custom/hidden and pushes it
    -- live. Called by Indicators.lua's ApplySettingToOne whenever any of
    -- those three settings changes (Use Default Spells toggle, custom spell
    -- add/remove, or a Built-in Spells checklist hide/show).
    function wrapper:RefreshSpellList(newT)
        wrapper._t = newT or wrapper._t
        wrapper:RefreshCandidateFilters()
        if ApplyFallbackIcons then
            ApplyFallbackIcons(PickRepresentativeCooldownIcons(kind, wrapper._t, wrapper._num or 5))
        end
    end

    -- See the identically-named method on the Healer HoTs wrapper (including
    -- the onlyIfGateMoved contract), and AEI.RefreshIdentityGatedFilters for
    -- the reason it exists.
    function wrapper:RefreshCandidateFilters(onlyIfGateMoved)
        local container = wrapper._container
        if not container then return end
        local moved = GateReadingMoved(wrapper)
        ApplyGateVisibility(wrapper)
        if onlyIfGateMoved and not moved then return end
        container:SetAuraGroupCandidateFilters(kind.groupKey, BuildCooldownCandidateFilters(kind, wrapper._t, WrapperUnit(wrapper)))
    end

    function wrapper:SetDurationMode(mode)
        ApplyDurationMode(kind.styleKey, mode)
        if RefreshFallbackDuration then RefreshFallbackDuration(mode) end
    end

    -- Full font settings for the stack and duration text: typeface,
    -- size, outline, ANCHOR and X/Y OFFSET, colour. Preferred over the
    -- generic SetFont dispatch in Indicators.lua, which only forwards
    -- (file, size, flags) and silently drops the rest -- see
    -- AE.ApplyFontSettings.
    function wrapper:SetFontTable(fontTable)
        AE.ApplyFontSettings(AE.styles[kind.styleKey], fontTable)
        AE.RestyleSoon(kind.styleKey)
        if RefreshFallbackDuration then
            RefreshFallbackDuration(t.durationVisibility or "always")
        end
        if RefreshFallbackStacks then RefreshFallbackStacks(t.showStack) end
    end

    -- Master on/off for the stack-count text. The style field is read by
    -- ApplyStyleToRegions; without a setter here the checkbox reached
    -- nothing and stacks were always on.
    function wrapper:SetShowStack(show)
        local style = AE.styles[kind.styleKey]
        if not style then return end
        style.showStack = (show ~= false)
        AE.RestyleSoon(kind.styleKey)
        if RefreshFallbackStacks then RefreshFallbackStacks(show) end
    end
    -- Combat-safely deferred (see AuraEngine.lua's InCombatLockdown guard on
    -- the restyler). Also toggles the preview's own fallback row directly,
    -- since that's a separate set of frames, not styled via AE.styles.
    function wrapper:SetShowBorder(show)
        local style = AE.styles[kind.styleKey]
        if style then
            style.border = show and { 0, 0, 0, 1, size = 1 } or nil
            AE.RestyleSoon(kind.styleKey)
        end
        if SetFallbackBorderShown then SetFallbackBorderShown(show) end
    end

    -- Preview never gets a real AuraContainer -- see the identical comment
    -- in CreateHealerHotsIndicator (a fake unit token was tried first, but
    -- real casts still leaked through while the preview was open).
    if not isPreview then
        -- NO "player" fallback: a unit-less button must not build a container bound
        -- to the player's own auras (see OnPartyButtonsWired). AE.RequestContainer
        -- asserts on a nil unit, so callers guard before reaching it.
        local unit = button.unit or button:GetAttribute("unit")
        AE.RequestContainer(wrapper, unit, spec, function(container)
            wrapper._container = container
            local corner = ContainerAnchorCorner(wrapper._orientation)
            container:ClearAllPoints()
            container:SetPoint(corner, wrapper, corner, 0, 0)
            container:SetShown(wrapper:IsShown())
            SeedGateState(wrapper)
        end)
    end

    return wrapper
end

function AEI.CreateExternalCooldownsIndicator(button, t)
    return CreateCooldownIndicator(COOLDOWN_KINDS.externalCooldowns, button, t)
end

function AEI.CreateDefensiveCooldownsIndicator(button, t)
    return CreateCooldownIndicator(COOLDOWN_KINDS.defensiveCooldowns, button, t)
end

------------------------------------------------------------------------
-- Debuffs: any active harmful aura, unrestricted (no curated spell-ID list
-- -- unlike healerHots/cooldowns, this shows whatever's actually on the
-- unit). Migrated off the legacy manual C_UnitAuras scan (BuiltIn_Update.lua's
-- CheckDebuffs) for the same combat-secrecy reason as everything else here:
-- an aura first applied to a unit mid-combat is PERMANENTLY unreadable to
-- that scan for the rest of the encounter.
--
-- Two features from the legacy version are NOT reproduced here (documented
-- losses, not oversights):
--   - "Big Debuff Priority" (bigDebuffCC): CC-tagged debuffs got a bigger
--     icon and sorted to the front. AddAuraGroup's own sort options
--     (sortMethod/sortDirection) don't expose an "is this CC" criterion, and
--     a group can't mix two icon sizes for its own members. Dropped, along
--     with its checkbutton.
--   - debuffBlacklist exclusion uses candidateFilters.excludeSpellIDs --
--     the official 12.1.0 API changes docs mention "include/exclude maps
--     for spell IDs" existing but don't spell out the exact field name
--     anywhere I could confirm; this is a best-effort guess based on the
--     includeSpellIDs/includeDispelTypes naming convention already proven
--     elsewhere in this file. Verify in-game that blacklisted spells are
--     actually excluded; if the field name is wrong it likely just gets
--     silently ignored (blacklist has no effect) rather than erroring.
------------------------------------------------------------------------
local DEBUFFS_GROUP_KEY = "debuffs"
local DEBUFFS_STYLE_KEY = "debuffs"

-- "Show All" scans every harmful aura; "Dispellable By Me" delegates to
-- Blizzard's own RAID_PLAYER_DISPELLABLE filter token -- same proven
-- approach as DispelFilterTokens below.
-- t.hideCCDebuffs excludes anything Blizzard tags CROWD_CONTROL, via the "!"
-- negation prefix (a real aura filter token -- see AE.Filter's TokenSortKey
-- handling). Intended to pair with the CC Indicator, which matches exactly
-- that tag: with both on, a CC debuff shows in one place instead of two.
-- Filter-string level rather than a candidateFilter on purpose -- it costs
-- nothing and, unlike include/excludeSpellIDs, filter-string tokens are NOT
-- subject to Blizzard's CanApplyIdentityCandidateFilters gate (the thing
-- that makes spell-ID filters silently lapse on debuffs applied to party
-- members, and during cutscenes -- see AuraEngine.lua's cutscene recovery).
local function DebuffFilterTokens(t)
    local tokens = { "HARMFUL" }
    if t.dispellableByMe then
        tokens[#tokens + 1] = "RAID_PLAYER_DISPELLABLE"
    end
    if t.hideCCDebuffs then
        tokens[#tokens + 1] = "!CROWD_CONTROL"
    end
    return tokens
end

local function BuildDebuffCandidateFilters(t)
    local filters = {}
    if t.debuffBlacklist and t.debuffBlacklist[1] then
        local set = {}
        for _, id in ipairs(t.debuffBlacklist) do set[id] = true end
        filters.excludeSpellIDs = set
    end
    return filters
end

local function BuildDebuffSpec(t)
    local AE = SquizzFrames.AuraEngine
    local w, h = ExtractSize(t)

    AE.styles[DEBUFFS_STYLE_KEY] = AE.styles[DEBUFFS_STYLE_KEY] or {
        width = w, height = h,
        showDuration = (t.durationVisibility ~= "never"),
        stackPoint = "BOTTOMRIGHT", stackX = 1, stackY = -1,
        durationPoint = "TOP", durationRelPoint = "BOTTOM", durationY = -2,
        border = (t.showIconBorder ~= false) and { 0, 0, 0, 1, size = 1 } or nil,
    }
    -- Font settings (typeface, size, outline, anchor, X/Y offset, colour
    -- for BOTH the stack and duration text) are re-applied on every
    -- build, not folded into the `or {}` above: that table is only
    -- created once and then reused for the lifetime of the style, so
    -- anything set inside it can never respond to a settings change.
    AE.ApplyFontSettings(AE.styles[DEBUFFS_STYLE_KEY], t.font)

    local growthH = (t.orientation == "left-to-right") and "RIGHT" or "LEFT"

    return {
        layout = {
            anchorPoint = (growthH == "RIGHT") and "LEFT" or "RIGHT",
            growthH = growthH,
            growthV = "DOWN",
        },
        groups = {
            {
                key = DEBUFFS_GROUP_KEY,
                filter = DebuffFilterTokens(t),
                maxFrameCount = t.num or 10,
                candidateFilters = BuildDebuffCandidateFilters(t),
                style = DEBUFFS_STYLE_KEY,
                layout = { elementWidth = w, elementHeight = h },
            },
        },
    }
end

function AEI.CreateDebuffsIndicator(button, t)
    if not button then return nil end
    local AE = SquizzFrames.AuraEngine
    if not AE then return nil end

    local wrapper = CreateFrame("Frame", nil, button)
    wrapper._sfType = "builtin"
    wrapper._num = t.num or 10
    wrapper._orientation = t.orientation or "left-to-right"
    wrapper._t = t

    local nativeSetSize = wrapper.SetSize
    local w, h = ExtractSize(t)
    nativeSetSize(wrapper, w, h)

    -- Preview: debuffs has no curated spell list to draw representative
    -- icons from (it shows whatever's really active on the unit) -- a row
    -- of the same generic placeholder icon stands in instead, same
    -- reasoning the legacy scan's own preview fallback already used.
    local IndicatorsModule = SquizzFrames.Indicators
    local isPreview = IndicatorsModule and IndicatorsModule.IsPreviewButton(button)

    -- Spec built here, not inside the container branch below -- it is what
    -- creates/refreshes AE.styles[<key>] (fonts included), which the
    -- preview's mock duration/stack text reads. See CreateHealerHotsIndicator
    -- for the full reasoning; only the CONTAINER is preview-skipped.
    local spec = BuildDebuffSpec(t)
    local RepositionFallback, SetFallbackBorderShown, RefreshFallbackDuration, RefreshFallbackStacks
    if isPreview then
        local placeholders = {}
        for i = 1, (t.num or 10) do placeholders[i] = [[Interface\Icons\INV_Misc_QuestionMark]] end
        _, RepositionFallback, _, SetFallbackBorderShown, RefreshFallbackDuration, RefreshFallbackStacks =
            CreateFallbackIconRow(wrapper, t.num or 10, placeholders, w, h, DEBUFFS_STYLE_KEY)
        RepositionFallback()
        SetFallbackBorderShown(t.showIconBorder ~= false)
        RefreshFallbackDuration(t.durationVisibility or "always")
        RefreshFallbackStacks(t.showStack)
    end

    function wrapper:SetSize(width, height)
        nativeSetSize(self, width, height)
        wrapper._w, wrapper._h = width, height
        local container = wrapper._container
        if container then
            container:SetAuraGroupLayout(DEBUFFS_GROUP_KEY, { elementWidth = width, elementHeight = height })
            local style = AE.styles[DEBUFFS_STYLE_KEY]
            if style then
                style.width, style.height = width, height
                AE.RestyleSoon(DEBUFFS_STYLE_KEY)
            end
        end
        if RepositionFallback then RepositionFallback() end
    end

    function wrapper:SetOrientation(token)
        wrapper._orientation = token
        local container = wrapper._container
        if container then
            local growthH = (token == "left-to-right") and "RIGHT" or "LEFT"
            container:SetFlowLayoutAnchorPoint((growthH == "RIGHT") and "LEFT" or "RIGHT")
            container:SetFlowLayoutGrowthDirection(AE.FlowDir(growthH), AE.FlowDir("DOWN"))
            container:ClearAllPoints()
            container:SetPoint(ContainerAnchorCorner(token), wrapper, ContainerAnchorCorner(token), 0, 0)
        end
        if RepositionFallback then RepositionFallback() end
    end

    function wrapper:SetNum(n)
        wrapper._num = n
        local container = wrapper._container
        if container then
            container:SetAuraGroupMaxFrameCount(DEBUFFS_GROUP_KEY, n)
        end
        if RepositionFallback then RepositionFallback() end
    end

    function wrapper:SetDurationMode(mode)
        ApplyDurationMode(DEBUFFS_STYLE_KEY, mode)
        if RefreshFallbackDuration then RefreshFallbackDuration(mode) end
    end

    -- Full font settings for the stack and duration text: typeface,
    -- size, outline, ANCHOR and X/Y OFFSET, colour. Preferred over the
    -- generic SetFont dispatch in Indicators.lua, which only forwards
    -- (file, size, flags) and silently drops the rest -- see
    -- AE.ApplyFontSettings.
    function wrapper:SetFontTable(fontTable)
        AE.ApplyFontSettings(AE.styles[DEBUFFS_STYLE_KEY], fontTable)
        AE.RestyleSoon(DEBUFFS_STYLE_KEY)
        if RefreshFallbackDuration then
            RefreshFallbackDuration(t.durationVisibility or "always")
        end
        if RefreshFallbackStacks then RefreshFallbackStacks(t.showStack) end
    end

    -- Master on/off for the stack-count text. The style field is read by
    -- ApplyStyleToRegions; without a setter here the checkbox reached
    -- nothing and stacks were always on.
    function wrapper:SetShowStack(show)
        local style = AE.styles[DEBUFFS_STYLE_KEY]
        if not style then return end
        style.showStack = (show ~= false)
        AE.RestyleSoon(DEBUFFS_STYLE_KEY)
        if RefreshFallbackStacks then RefreshFallbackStacks(show) end
    end
    function wrapper:SetShowBorder(show)
        local style = AE.styles[DEBUFFS_STYLE_KEY]
        if style then
            style.border = show and { 0, 0, 0, 1, size = 1 } or nil
            AE.RestyleSoon(DEBUFFS_STYLE_KEY)
        end
        if SetFallbackBorderShown then SetFallbackBorderShown(show) end
    end

    -- Called by Indicators.lua whenever dispellableByMe/debuffBlacklist
    -- changes -- see the "RefreshFilters" case added to ApplySettingToOne.
    function wrapper:RefreshFilters(newT)
        wrapper._t = newT or wrapper._t
        local container = wrapper._container
        if container then
            pcall(container.SetAuraGroupFilterString, container, DEBUFFS_GROUP_KEY, AE.Filter(unpack(DebuffFilterTokens(wrapper._t))))
            container:SetAuraGroupCandidateFilters(DEBUFFS_GROUP_KEY, BuildDebuffCandidateFilters(wrapper._t))
        end
    end

    if not isPreview then
        -- NO "player" fallback: a unit-less button must not build a container bound
        -- to the player's own auras (see OnPartyButtonsWired). AE.RequestContainer
        -- asserts on a nil unit, so callers guard before reaching it.
        local unit = button.unit or button:GetAttribute("unit")
        AE.RequestContainer(wrapper, unit, spec, function(container)
            wrapper._container = container
            local corner = ContainerAnchorCorner(wrapper._orientation)
            container:ClearAllPoints()
            container:SetPoint(corner, wrapper, corner, 0, 0)
            container:SetShown(wrapper:IsShown())
            SeedGateState(wrapper)
        end)
    end

    return wrapper
end

------------------------------------------------------------------------
-- CC Indicator: a single group matching CROWD_CONTROL-tagged debuffs --
-- Blizzard's native filter tag, the same one CheckDebuffs' IsAuraCC already
-- uses for "big debuff priority".
--
-- HISTORY (2026-08-12, user request: "remove the dispellable ones and just
-- make only the CC ones show up"): this used to declare a SECOND group
-- filtered "HARMFUL|RAID_PLAYER_DISPELLABLE|!CROWD_CONTROL", as a broader
-- "most CC is dispellable" heuristic to catch CC-like effects Blizzard
-- doesn't officially tag (e.g. a 100% snare that's functionally a root). In
-- practice it pulled in too much noise. If it's ever wanted back, it should
-- return as a user-facing toggle rather than unconditionally -- the "!"
-- negation prefix that kept the two groups mutually exclusive BY
-- CONSTRUCTION (so no aura could match both, and no Lua-side dedup was
-- needed) is a real aura filter token, see AE.Filter's TokenSortKey.
--
-- Side effect of dropping it: t.num now means "max icons total" rather than
-- "max per category", so the indicator can no longer show up to 2x num at
-- once when both categories were simultaneously active.
-- Migrated for the identical combat-secrecy reason as Debuffs above.
------------------------------------------------------------------------
local CC_GROUP_KEY_TAGGED = "ccIndicator_cc"
local CC_STYLE_KEY = "ccIndicator"
local CC_FILTER_TOKENS_TAGGED = { "HARMFUL", "CROWD_CONTROL" }
local CC_PREVIEW_ICON = [[Interface\Icons\Spell_Frost_ChainsOfIce]]

local function BuildCCSpec(t)
    local AE = SquizzFrames.AuraEngine
    local w, h = ExtractSize(t)

    AE.styles[CC_STYLE_KEY] = AE.styles[CC_STYLE_KEY] or {
        width = w, height = h,
        showDuration = (t.durationVisibility ~= "never"),
        stackPoint = "BOTTOMRIGHT", stackX = 1, stackY = -1,
        durationPoint = "TOP", durationRelPoint = "BOTTOM", durationY = -2,
        border = (t.showIconBorder ~= false) and { 0, 0, 0, 1, size = 1 } or nil,
    }
    -- Font settings (typeface, size, outline, anchor, X/Y offset, colour
    -- for BOTH the stack and duration text) are re-applied on every
    -- build, not folded into the `or {}` above: that table is only
    -- created once and then reused for the lifetime of the style, so
    -- anything set inside it can never respond to a settings change.
    AE.ApplyFontSettings(AE.styles[CC_STYLE_KEY], t.font)

    local growthH = (t.orientation == "left-to-right") and "RIGHT" or "LEFT"

    return {
        layout = {
            anchorPoint = (growthH == "RIGHT") and "LEFT" or "RIGHT",
            growthH = growthH,
            growthV = "DOWN",
        },
        groups = {
            {
                key = CC_GROUP_KEY_TAGGED,
                filter = CC_FILTER_TOKENS_TAGGED,
                maxFrameCount = t.num or 1,
                style = CC_STYLE_KEY,
                layout = { elementWidth = w, elementHeight = h },
            },
        },
    }
end

function AEI.CreateCCIndicator(button, t)
    if not button then return nil end
    local AE = SquizzFrames.AuraEngine
    if not AE then return nil end

    local wrapper = CreateFrame("Frame", nil, button)
    wrapper._sfType = "builtin"
    wrapper._num = t.num or 1
    wrapper._orientation = t.orientation or "left-to-right"
    wrapper._t = t

    local nativeSetSize = wrapper.SetSize
    local w, h = ExtractSize(t)
    nativeSetSize(wrapper, w, h)

    local IndicatorsModule = SquizzFrames.Indicators
    local isPreview = IndicatorsModule and IndicatorsModule.IsPreviewButton(button)

    -- Spec built here, not inside the container branch below -- it is what
    -- creates/refreshes AE.styles[<key>] (fonts included), which the
    -- preview's mock duration/stack text reads. See CreateHealerHotsIndicator
    -- for the full reasoning; only the CONTAINER is preview-skipped.
    local spec = BuildCCSpec(t)
    local RepositionFallback, SetFallbackBorderShown, RefreshFallbackDuration, RefreshFallbackStacks
    if isPreview then
        local placeholders = {}
        for i = 1, (t.num or 1) do placeholders[i] = CC_PREVIEW_ICON end
        _, RepositionFallback, _, SetFallbackBorderShown, RefreshFallbackDuration, RefreshFallbackStacks =
            CreateFallbackIconRow(wrapper, t.num or 1, placeholders, w, h, CC_STYLE_KEY)
        RepositionFallback()
        SetFallbackBorderShown(t.showIconBorder ~= false)
        RefreshFallbackDuration(t.durationVisibility or "always")
        RefreshFallbackStacks(t.showStack)
    end

    function wrapper:SetSize(width, height)
        nativeSetSize(self, width, height)
        wrapper._w, wrapper._h = width, height
        local container = wrapper._container
        if container then
            container:SetAuraGroupLayout(CC_GROUP_KEY_TAGGED, { elementWidth = width, elementHeight = height })
            local style = AE.styles[CC_STYLE_KEY]
            if style then
                style.width, style.height = width, height
                AE.RestyleSoon(CC_STYLE_KEY)
            end
        end
        if RepositionFallback then RepositionFallback() end
    end

    function wrapper:SetOrientation(token)
        wrapper._orientation = token
        local container = wrapper._container
        if container then
            local growthH = (token == "left-to-right") and "RIGHT" or "LEFT"
            container:SetFlowLayoutAnchorPoint((growthH == "RIGHT") and "LEFT" or "RIGHT")
            container:SetFlowLayoutGrowthDirection(AE.FlowDir(growthH), AE.FlowDir("DOWN"))
            container:ClearAllPoints()
            container:SetPoint(ContainerAnchorCorner(token), wrapper, ContainerAnchorCorner(token), 0, 0)
        end
        if RepositionFallback then RepositionFallback() end
    end

    function wrapper:SetNum(n)
        wrapper._num = n
        local container = wrapper._container
        if container then
            container:SetAuraGroupMaxFrameCount(CC_GROUP_KEY_TAGGED, n)
        end
        if RepositionFallback then RepositionFallback() end
    end

    function wrapper:SetDurationMode(mode)
        ApplyDurationMode(CC_STYLE_KEY, mode)
        if RefreshFallbackDuration then RefreshFallbackDuration(mode) end
    end

    -- Full font settings for the stack and duration text: typeface,
    -- size, outline, ANCHOR and X/Y OFFSET, colour. Preferred over the
    -- generic SetFont dispatch in Indicators.lua, which only forwards
    -- (file, size, flags) and silently drops the rest -- see
    -- AE.ApplyFontSettings.
    function wrapper:SetFontTable(fontTable)
        AE.ApplyFontSettings(AE.styles[CC_STYLE_KEY], fontTable)
        AE.RestyleSoon(CC_STYLE_KEY)
        if RefreshFallbackDuration then
            RefreshFallbackDuration(t.durationVisibility or "always")
        end
        if RefreshFallbackStacks then RefreshFallbackStacks(t.showStack) end
    end

    -- Master on/off for the stack-count text. The style field is read by
    -- ApplyStyleToRegions; without a setter here the checkbox reached
    -- nothing and stacks were always on.
    function wrapper:SetShowStack(show)
        local style = AE.styles[CC_STYLE_KEY]
        if not style then return end
        style.showStack = (show ~= false)
        AE.RestyleSoon(CC_STYLE_KEY)
        if RefreshFallbackStacks then RefreshFallbackStacks(show) end
    end
    function wrapper:SetShowBorder(show)
        local style = AE.styles[CC_STYLE_KEY]
        if style then
            style.border = show and { 0, 0, 0, 1, size = 1 } or nil
            AE.RestyleSoon(CC_STYLE_KEY)
        end
        if SetFallbackBorderShown then SetFallbackBorderShown(show) end
    end

    if not isPreview then
        -- NO "player" fallback: a unit-less button must not build a container bound
        -- to the player's own auras (see OnPartyButtonsWired). AE.RequestContainer
        -- asserts on a nil unit, so callers guard before reaching it.
        local unit = button.unit or button:GetAttribute("unit")
        AE.RequestContainer(wrapper, unit, spec, function(container)
            wrapper._container = container
            local corner = ContainerAnchorCorner(wrapper._orientation)
            container:ClearAllPoints()
            container:SetPoint(corner, wrapper, corner, 0, 0)
            container:SetShown(wrapper:IsShown())
            SeedGateState(wrapper)
        end)
    end

    return wrapper
end

------------------------------------------------------------------------
-- Dispels: per-type health-bar overlay/border/icon via AuraContainer slots.
-- Mirrors EllesmereUI's 12.1 architecture (EUI_RaidFrames_AuraContainers.lua,
-- reviewed directly from the local PTR install) rather than a manual
-- C_UnitAuras scan: one bare (noRegions) slot per dispel type, each filtered
-- via candidateFilters.includeDispelTypes so WHICH type is present is known
-- by WHICH slot has content -- the engine does the type-matching internally,
-- so the (secret-in-combat) dispel type string is never read by us at all.
------------------------------------------------------------------------

-- `level` (1-5) staggers each type's slot frame level just above the health
-- bar, mirroring EllesmereUI's own proven AuraContainer dispel implementation
-- (EUI_RaidFrames_AuraContainers.lua: health:GetFrameLevel() + 1 + def.level).
-- This only works because UnitButton.lua's OnLoad now guarantees the button
-- itself sits at frame level 20+ -- Ellesmere's host frame apparently has a
-- similarly generous budget built in, but SquizzFrames's own template only
-- left a 2-level gap (button~3, health=1) until that bump was added, which
-- is what made the first attempt at this exact formula fail on some slots.
-- Array order also doubles as RefreshFallbackVisuals's "first enabled type"
-- priority order on the Designer preview.
local DISPEL_TYPES = {
    { key = "magic",   token = "Magic",   colorKey = "Magic",   atlas = "RaidFrame-Icon-DebuffMagic",   fallback = { 0.20, 0.60, 1.00 }, level = 5 },
    { key = "curse",   token = "Curse",   colorKey = "Curse",   atlas = "RaidFrame-Icon-DebuffCurse",   fallback = { 0.60, 0.00, 1.00 }, level = 4 },
    { key = "disease", token = "Disease", colorKey = "Disease", atlas = "RaidFrame-Icon-DebuffDisease", fallback = { 0.60, 0.40, 0.00 }, level = 3 },
    { key = "poison",  token = "Poison",  colorKey = "Poison",  atlas = "RaidFrame-Icon-DebuffPoison",  fallback = { 0.00, 0.60, 0.00 }, level = 2 },
    { key = "bleed",   token = "Bleed",   colorKey = "Bleed",   atlas = "RaidFrame-Icon-DebuffBleed",   fallback = { 0.75, 0.15, 0.15 }, level = 1 },
}
local DISPEL_STYLE_PREFIX = "dispels_"

-- "Show All" scans every dispellable debuff regardless of who can dispel it;
-- "Dispellable By Me" delegates to Blizzard's own RAID_PLAYER_DISPELLABLE
-- filter token so "can THIS player dispel it" never requires reading the
-- (secret) dispel type ourselves either.
local function DispelFilterTokens(t)
    if t.dispelShowAll == false then
        return { "HARMFUL", "RAID_PLAYER_DISPELLABLE" }
    end
    return { "HARMFUL" }
end

-- Renders one dispel-type slot's visuals (health-bar overlay + optional
-- icon) from its style. Guarded on d.health because MakeInitializer's
-- noRegions branch runs style.applyExtra (this function, via
-- ApplyStyleToRegions) BEFORE the per-slot extraInit callback below has a
-- chance to stash the health-bar reference on d -- extraInit calls this
-- again immediately after setting it, so the guard just skips that one
-- premature first call rather than erroring.
-- "Full" mode's thick opaque border thickness, in pixels. Always alpha=1
-- regardless of the overlay opacity slider -- only the fill inside it is
-- adjustable -- so the dispel type stays clearly readable even at low
-- overlay opacity.
local DISPEL_FULL_BORDER_THICKNESS = 6

-- "Full" mode's fill caps out at 40% opacity even with the slider at 100%
-- (a full-button solid tint reads as overwhelming at true 100%, unlike
-- "fill"/"gradient" which only tint part of the health bar) -- the slider
-- still scales 0-100% linearly, just onto a 0%-40% effective range.
local DISPEL_FULL_MAX_OPACITY = 0.4

-- Fallbacks for the two gradient shape settings, used when a profile predates
-- them (dispelGradientWeakAlpha / dispelGradientHeight in Layout_Defaults.lua,
-- both surfaced as sliders in the Dispels settings panel).
--
-- The weak end stops at a PERCENTAGE of the opacity slider rather than at
-- true 0: fading fully out left most of the covered area barely visible even
-- with opacity maxed, with only a thin band at the strong edge ever reaching
-- the slider's actual alpha (bug fix 2026-07-30, user report: "barely
-- noticeable... set to 100 opacity"). 0 = true fade-out, 100 = flat tint with
-- no visible ramp at all.
-- Shared by the dispel icon's layering below and by the custom color/bar
-- indicators' StrataAboveHealth further down. Declared up here because Lua
-- upvalues are only visible to code declared AFTER them, and the dispel icon
-- (the earlier of the two users) needs it.
local STRATA_ORDER = {
    BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4,
    DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8,
}

local DISPEL_GRADIENT_WEAK_ALPHA_DEFAULT = 50
-- Percentage of the health bar's height the ramp spans, measured from the
-- strong (pinned) edge.
local DISPEL_GRADIENT_HEIGHT_DEFAULT = 50

-- The health bar spans the FULL button height (UnitButton.xml anchors it
-- TOPLEFT *and* BOTTOMLEFT to the button), and the power bar is a short strip
-- anchored to the button's bottom at a HIGHER frame level, drawn on top of
-- health's lower edge. So anything anchored flush to health's bottom visually
-- covers the power bar -- confirmed by user report/screenshot 2026-08-12,
-- where a Magic dispel overlay swallowed the power bar entirely.
--
-- Returns how far up from health's bottom edge to stop. Reads the power bar
-- live rather than the profile's powerHeight so it stays correct when the bar
-- is hidden (inset 0 = use the whole bar).
local function HealthBottomInset(health)
    local parent = health and health.GetParent and health:GetParent()
    local power = parent and parent.powerBar
    if power and power.IsShown and power:IsShown() then
        return power:GetHeight() or 0
    end
    return 0
end

-- Same idea as HealthBottomInset, for the OTHER three edges: how far in from
-- health's top/left/right to stop so the Frame Border indicator stays visible.
--
-- The health bar spans the full button rect (see HealthBottomInset above) and
-- frameBorder draws its four textures flush to the button's own edges
-- (CreateBorderIndicator in BuiltIn_Update.lua anchors them at 0,0 and grows
-- inward by thickness). So a dispel overlay anchored flush to health simply
-- paints over the border -- user report 2026-08-13, "it is showing above the
-- border". Insetting by the border's thickness makes the overlay start where
-- the border ends.
--
-- Only frameBorder, deliberately: it's the always-on decorative chrome, so a
-- fixed inset reads as correct framing. aggroBorder/targetHighlight/
-- hoverHighlight are transient STATE borders -- insetting for those would make
-- the overlay visibly shrink and grow as you gain aggro or mouse over a frame.
-- They're also drawn above the overlay anyway, so they don't have this problem.
--
-- Read live off the button's own indicator frame rather than the profile, for
-- the same reason HealthBottomInset reads the power bar live: it stays correct
-- for the Designer preview button (which carries its own indicator set) and
-- when the indicator is disabled, with no second source of truth to keep in
-- sync. The border frame is a plain Frame, so IsShown() is readable on it --
-- unlike the AuraContainer slot buttons this styles.
local function FrameBorderInset(health)
    local parent = health and health.GetParent and health:GetParent()
    local border = parent and parent.indicators and parent.indicators.frameBorder
    if border and border.IsShown and border:IsShown() then
        local top = border._textures and border._textures.top
        if top and top.GetHeight then
            return top:GetHeight() or 0
        end
    end
    return 0
end

-- Exported for BuiltIn_Update.lua's Shield Overlay and Heal Absorb, which pin
-- themselves across the health bar exactly the way this overlay does and so
-- want exactly the same two insets. Exported rather than duplicated: both
-- functions encode a fact about the BUTTON's layout (health spans the full
-- rect, power bar and frame border are drawn on top of its edges), not
-- anything about dispels, and a second copy would be one more thing to keep in
-- step. Consumers resolve them off SquizzFrames.AuraEngineIndicators at call
-- time and fall back to a zero inset, since this whole file is inert pre-12.1.
AEI.HealthBottomInset = HealthBottomInset
AEI.FrameBorderInset = FrameBorderInset

-- Pin a REGION OR FRAME across the FILLED portion of the health bar, with both
-- insets applied. Shared by the custom "color" indicator (its live slot
-- overlay, its expiring-colour clip window, and its preview stand-in) and
-- structurally identical to the Dispels overlay's own "fill" mode -- see the
-- comment on that branch in ApplyDispelSlotStyle for why the border inset is
-- applied to the fill-tracking edge as well.
--
-- Everything it anchors therefore agrees on where the fill ends, which is the
-- point: the expiring wash is a fixed-size `|T` that can't track the fill
-- itself, so it relies on a clip window pinned by this same function.
--
-- Anchors are relative, so once set they follow the bar on their own; only the
-- numeric offsets can go stale, and neither depends on the bar's SIZE. That's
-- why this needs no OnSizeChanged hook, unlike dispels' gradient modes (which
-- derive an absolute height and so must re-measure on every resize).
local function AnchorHealthFillOverlay(tex, health)
    if not tex or not health then return end
    local bottomInset = HealthBottomInset(health)
    local bi = FrameBorderInset(health)
    local fillTex = health.GetStatusBarTexture and health:GetStatusBarTexture()
    tex:ClearAllPoints()
    tex:SetPoint("TOPLEFT", health, "TOPLEFT", bi, -bi)
    tex:SetPoint("BOTTOMRIGHT", fillTex or health, "BOTTOMRIGHT", -bi, bottomInset)
end
AEI.AnchorHealthFillOverlay = AnchorHealthFillOverlay

local function ApplyDispelSlotStyle(button, d, style)
    if not d.health then return end
    local health = d.health
    local bottomInset = HealthBottomInset(health)
    -- Top/left/right border inset, applied as anchor offsets below: +x moves
    -- right and +y moves up, so left is +bi, right is -bi, top is -bi.
    --
    -- Scoped to those three edges only (as requested). The BOTTOM edge keeps
    -- using bottomInset alone: with a power bar shown -- the default -- the
    -- overlay already stops well above the button's bottom border, so there's
    -- nothing to correct. With the power bar hidden (bottomInset == 0) the
    -- bottom border IS still overlapped; see the note where bottomInset is
    -- used, and widen it there if that turns out to matter.
    local bi = FrameBorderInset(health)

    if not d.overlay then
        d.overlay = button:CreateTexture(nil, "ARTWORK")
    end
    -- Gradient mode gets its OWN separate texture rather than sharing
    -- d.overlay with full/fill: once SetGradient has ever been called on a
    -- texture object, that texture seems to permanently stop respecting a
    -- plain SetAlpha/SetColorTexture alpha afterward (confirmed by
    -- debugging -- SetAlpha(0.4) followed immediately by GetAlpha()
    -- reported 1, even though the RGB channel came through correctly).
    -- Never calling SetGradient on d.overlay at all sidesteps that
    -- entirely, so full/fill's plain color+alpha via SetColorTexture stays
    -- reliable regardless of how many times gradient mode has run before.
    if not d.gradientOverlay then
        d.gradientOverlay = button:CreateTexture(nil, "ARTWORK")
        -- SetGradient only tints vertex colors on an EXISTING texture
        -- resource -- it doesn't assign one itself. Without this, a
        -- freshly created texture has no underlying resource for the first
        -- SetGradient call to tint, and renders as nothing at all.
        d.gradientOverlay:SetColorTexture(1, 1, 1, 1)
    end
    local tex = d.overlay
    local gradTex = d.gradientOverlay
    tex:ClearAllPoints()
    gradTex:ClearAllPoints()
    local mode = style.mode or "fill"
    local color = style.color or { 1, 1, 1 }
    local alpha = style.opacity or 1
    if mode == "none" then
        tex:Hide()
        gradTex:Hide()
    elseif mode == "full" then
        gradTex:Hide()
        -- Not SetAllPoints(health): stop short of the power bar, and of the
        -- Frame Border on the other three edges (see FrameBorderInset).
        tex:SetPoint("TOPLEFT", health, "TOPLEFT", bi, -bi)
        tex:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", -bi, bottomInset)
        tex:SetColorTexture(color[1], color[2], color[3], alpha * DISPEL_FULL_MAX_OPACITY)
        tex:Show()
    elseif mode == "gradient" or mode == "gradientTop" then
        tex:Hide()
        -- EXTENT: the STRONG edge is pinned flush to the health bar; the weak
        -- edge is the one the height slider moves. At 100% the ramp spans the
        -- whole bar; below that it shrinks toward the pinned edge, leaving the
        -- rest of the bar untinted.
        --
        -- Reading health's height is unavoidable here -- the frame API has no
        -- fractional anchor, so a percentage of a parent's height can only be
        -- expressed as an absolute number. If it isn't usable yet (styles can
        -- be applied before the bar has been laid out) fall back to anchoring
        -- the far edge too, i.e. full-bar coverage, rather than rendering a
        -- zero-height nothing. AE.RestyleSoon is re-fired on the health bar's
        -- OnSizeChanged (see CreateDispelsIndicator) so this re-measures
        -- whenever the frame is actually resized.
        -- Height percentage applies to the bar MINUS the power-bar strip, so
        -- 100% means "up to the power bar", not "over it".
        -- Border inset comes off the measured height too, not just the anchors
        -- -- otherwise a 100% ramp would still be a full-bar-height texture
        -- pushed down by the top inset, and would overhang the bottom.
        local barH = (health:GetHeight() or 0) - bottomInset - bi
        local h = barH > 0
            and (barH * ((style.gradientHeight or DISPEL_GRADIENT_HEIGHT_DEFAULT) / 100))
            or nil
        if mode == "gradientTop" then
            gradTex:SetPoint("TOPLEFT", health, "TOPLEFT", bi, -bi)
            gradTex:SetPoint("TOPRIGHT", health, "TOPRIGHT", -bi, -bi)
            if h then gradTex:SetHeight(h)
            else gradTex:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", -bi, bottomInset) end
        else
            gradTex:SetPoint("BOTTOMLEFT", health, "BOTTOMLEFT", bi, bottomInset)
            gradTex:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", -bi, bottomInset)
            if h then gradTex:SetHeight(h)
            else gradTex:SetPoint("TOPRIGHT", health, "TOPRIGHT", -bi, -bi) end
        end
        -- ALPHA: the opacity slider is the STRONG end; the weak end is a
        -- percentage OF that (rather than an independent absolute alpha) so
        -- the two can never invert and the opacity slider still reads as one
        -- overall intensity control. See DISPEL_GRADIENT_WEAK_ALPHA_DEFAULT.
        local minAlpha = alpha * ((style.gradientWeakAlpha or DISPEL_GRADIENT_WEAK_ALPHA_DEFAULT) / 100)
        -- "gradient" = strongest at the BOTTOM (the default look);
        -- "gradientTop" = the same ramp flipped, strongest at the TOP.
        local bottomAlpha, topAlpha = alpha, minAlpha
        if mode == "gradientTop" then
            bottomAlpha, topAlpha = minAlpha, alpha
        end
        -- SetGradient(orientation, minColor, maxColor): for "VERTICAL" this
        -- should put minColor at the bottom and maxColor at the top. UNTESTED
        -- against a real client -- if both modes render upside down (i.e.
        -- "Strong Bottom" is strong at the top), swap the two CreateColor
        -- lines below; that fixes both directions at once.
        gradTex:SetGradient("VERTICAL",
            CreateColor(color[1], color[2], color[3], bottomAlpha), -- bottom
            CreateColor(color[1], color[2], color[3], topAlpha))    -- top
        gradTex:Show()
    else -- "fill": only the currently-filled portion of the health bar, so it
        -- visually tracks current health like a tinted health-bar overlay.
        gradTex:Hide()
        local fillTex = health.GetStatusBarTexture and health:GetStatusBarTexture()
        tex:SetPoint("TOPLEFT", health, "TOPLEFT", bi, -bi)
        if fillTex then
            -- The status bar texture inherits health's full height, so it
            -- needs the same power-bar inset.
            --
            -- The border inset applies on this edge too, even though it tracks
            -- the FILL rather than the bar: at full health the fill's right
            -- edge is the bar's right edge, which is exactly where the border
            -- sits. The cost is that at partial health the tint stops ~bi short
            -- of the fill's leading edge -- a 1-2px sliver, versus this one
            -- mode visibly disagreeing with the other three about where the
            -- frame ends.
            tex:SetPoint("BOTTOMRIGHT", fillTex, "BOTTOMRIGHT", -bi, bottomInset)
        else
            tex:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", -bi, bottomInset)
        end
        tex:SetColorTexture(color[1], color[2], color[3], alpha)
        tex:Show()
    end

    -- "Full" mode gets a thick, always-opaque border around the health bar
    -- in the same per-type color as the fill, so the dispel type reads
    -- clearly even when the fill's own opacity is turned down low.
    if mode == "full" then
        if not d.border then
            d.border = {
                top = button:CreateTexture(nil, "OVERLAY"),
                bottom = button:CreateTexture(nil, "OVERLAY"),
                left = button:CreateTexture(nil, "OVERLAY"),
                right = button:CreateTexture(nil, "OVERLAY"),
            }
        end
        local b = d.border
        local t2 = DISPEL_FULL_BORDER_THICKNESS
        -- Same top/left/right border inset as the fill above -- this is the
        -- edge the user actually sees in "full" mode, since it's drawn opaque
        -- at full strength right where the Frame Border lives.
        b.top:ClearAllPoints()
        b.top:SetPoint("TOPLEFT", health, "TOPLEFT", bi, -bi)
        b.top:SetPoint("TOPRIGHT", health, "TOPRIGHT", -bi, -bi)
        b.top:SetHeight(t2)
        -- Same power-bar inset as the fill above, so the border frames the
        -- health bar rather than boxing in the power bar too.
        b.bottom:ClearAllPoints()
        b.bottom:SetPoint("BOTTOMLEFT", health, "BOTTOMLEFT", bi, bottomInset)
        b.bottom:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", -bi, bottomInset)
        b.bottom:SetHeight(t2)
        b.left:ClearAllPoints()
        b.left:SetPoint("TOPLEFT", health, "TOPLEFT", bi, -bi)
        b.left:SetPoint("BOTTOMLEFT", health, "BOTTOMLEFT", bi, bottomInset)
        b.left:SetWidth(t2)
        b.right:ClearAllPoints()
        b.right:SetPoint("TOPRIGHT", health, "TOPRIGHT", -bi, -bi)
        b.right:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", -bi, bottomInset)
        b.right:SetWidth(t2)
        for _, edge in pairs(b) do
            edge:SetColorTexture(color[1], color[2], color[3], 1)
            edge:Show()
        end
    elseif d.border then
        for _, edge in pairs(d.border) do edge:Hide() end
    end
    -- No icon here. The dispel-type symbols are their own indicator now
    -- (AEI.CreateDispelIconsIndicator) -- this slot draws the health-bar
    -- overlay and nothing else.
end

local function BuildDispelStyleForType(t, def)
    local userColor = t.dispelColors and t.dispelColors[def.colorKey]
    local color = userColor or def.fallback
    local typeEnabled = not t.dispelTypesEnabled or t.dispelTypesEnabled[def.colorKey] ~= false
    return {
        noRegions = true,
        color = color,
        mode = typeEnabled and (t.dispelOverlay or "fill") or "none",
        opacity = (t.dispelOverlayOpacity or 40) / 100,
        -- Gradient-mode shape only; ignored by none/fill/full.
        gradientWeakAlpha = t.dispelGradientWeakAlpha or DISPEL_GRADIENT_WEAK_ALPHA_DEFAULT,
        gradientHeight = t.dispelGradientHeight or DISPEL_GRADIENT_HEIGHT_DEFAULT,
        applyExtra = ApplyDispelSlotStyle,
    }
end

function AEI.CreateDispelsIndicator(button, t)
    if not button then return nil end
    local AE = SquizzFrames.AuraEngine
    if not AE then return nil end
    local health = button.healthBar or button

    -- No frame-level bump needed: health/power bar are children whose frame
    -- level DYNAMICALLY TRACKS the button's own level (confirmed by
    -- debugging -- raising the button's level shifted health/power's
    -- reported levels by the exact same amount), and the button's natural
    -- level already sits reliably above both for every party slot uniformly
    -- (not per-slot-varying as first suspected). So there's nothing to fix
    -- up front here -- extraInit below just reads button:GetFrameLevel()
    -- live, each time, right before placing the overlay one level below it.

    -- The wrapper is the generic settings-dispatch handle for Indicators.lua
    -- (Enabled/frameLevel -- driven entirely by the same generic code every
    -- other built-in uses). It never renders anything itself, and it has no
    -- meaningful position or size: the overlay always spans the health bar.
    -- Those settings used to exist here only to place the dispel-type symbol,
    -- which is now its own Dispel Icons indicator.
    local wrapper = CreateFrame("Frame", nil, button)
    wrapper._sfType = "builtin"
    local iw, ih = ExtractSize(t)
    wrapper:SetSize(iw, ih)

    -- Preview-only: AuraContainer slots are bound to a REAL unit via
    -- Blizzard's C-side engine, so a fake aura can't be injected the way
    -- BuiltIn_Update/Custom_Dispatch fake data for their own frames (same
    -- constraint Healer HoTs' fallback icon works around). The preview
    -- unit never carries a real dispellable debuff, so none of the 5 real
    -- per-type slots below would ever show there -- fallbackCtx reuses
    -- ApplyDispelSlotStyle itself (overlay + border + icon, whichever the
    -- current style calls for) unconditionally on a dedicated fallbackHost
    -- frame (plain, non-secret) instead of a real slotButton, so the
    -- Designer shows exactly what the live overlay/border/icon would look
    -- like. This is
    -- NOT "which type is active" -- that question is itself secret (see the
    -- removed IsShown-polling this replaced, which crashed with "attempt to
    -- perform boolean test on a secret boolean value") -- it just always
    -- shows the first enabled type, unconditionally.
    local IndicatorsModule = SquizzFrames.Indicators
    local isPreview = IndicatorsModule and IndicatorsModule.IsPreviewButton(button)
    local fallbackCtx
    local fallbackHost
    if isPreview then
        -- The Designer preview button is a hand-built mockup (see
        -- IndicatorsPanel.lua's BuildPreviewCanvas), NOT the real
        -- UnitButton.xml template -- it has no BACKGROUND/LOW/MEDIUM strata
        -- split at all; health bar, role icon, text etc are ALL at the
        -- default "MEDIUM" strata, ordered purely by frame level (health/
        -- power bar default to previewButton's level + 1; other indicators
        -- get previewButton's level + their own configured frameLevel,
        -- typically 5+). Forcing "LOW" strata here (the live-button fix)
        -- dropped the fallback into a tier that doesn't exist in that
        -- scheme, below the opaque health-bar mockup entirely -- invisible.
        -- A dedicated frame pinned to health's own level + 1 sits reliably
        -- above health/power bar and below every other indicator's own
        -- (higher) frameLevel on THIS preview's generous gap, without
        -- touching wrapper's own user-adjustable frameLevel (still used
        -- for the icon's position/level setting).
        fallbackHost = CreateFrame("Frame", nil, wrapper)
        fallbackHost:SetFrameLevel(health:GetFrameLevel() + 1)
        fallbackCtx = { health = health }
    end

    local function RefreshFallbackVisuals()
        if not fallbackCtx then return end
        for _, def in ipairs(DISPEL_TYPES) do
            local enabled = not t.dispelTypesEnabled or t.dispelTypesEnabled[def.colorKey] ~= false
            if enabled then
                local style = AE.styles[DISPEL_STYLE_PREFIX .. def.key]
                if style then ApplyDispelSlotStyle(fallbackHost, fallbackCtx, style) end
                return
            end
        end
        -- No enabled type at all -- hide everything.
        if fallbackCtx.overlay then fallbackCtx.overlay:Hide() end
        if fallbackCtx.border then
            for _, edge in pairs(fallbackCtx.border) do edge:Hide() end
        end

    end

    local function RebuildStyles()
        for _, def in ipairs(DISPEL_TYPES) do
            local key = DISPEL_STYLE_PREFIX .. def.key
            AE.styles[key] = BuildDispelStyleForType(t, def)
            AE.RestyleSoon(key)
        end
        RefreshFallbackVisuals()
    end

    -- Push whatever currently governs the icon GROUP at the live container.
    -- Deliberately separate from RebuildStyles above, which only drives the
    -- per-type overlay SLOTS: the group is configured through the container
    -- API rather than through AE.styles, so a style rebuild alone leaves it
    -- stale. Declared here, above every setter that calls it, so it resolves
    -- as an upvalue rather than a nil global.
    -- Re-run the geometry without rebuilding the style tables: the style
    -- describes colors/mode/opacity, none of which change when the Frame
    -- Border does -- only the insets ApplyDispelSlotStyle measures at apply
    -- time (FrameBorderInset). Exposed on the wrapper because the preview's
    -- fallback host is driven by this closure, not by the engine's restyler,
    -- so an outside caller can't reach it through AE.RestyleSoon alone.
    function wrapper:RefreshBorderInset()
        for _, def in ipairs(DISPEL_TYPES) do
            AE.RestyleSoon(DISPEL_STYLE_PREFIX .. def.key)
        end
        RefreshFallbackVisuals()
    end

    function wrapper:SetDispelShowAll(val)
        t.dispelShowAll = val
        local container = wrapper._container
        if container then
            local filterStr = AE.Filter(unpack(DispelFilterTokens(t)))
            for _, def in ipairs(DISPEL_TYPES) do
                container:SetAuraSlotFilterString(def.key, filterStr)
            end
        end
    end

    function wrapper:SetDispelTypes(enabledMap)
        t.dispelTypesEnabled = enabledMap
        RebuildStyles()
    end

    function wrapper:SetDispelColors(colors)
        t.dispelColors = colors
        RebuildStyles()
    end

    function wrapper:SetDispelOverlay(mode)
        t.dispelOverlay = mode
        RebuildStyles()
    end

    function wrapper:SetDispelOverlayOpacity(opacity)
        t.dispelOverlayOpacity = opacity
        RebuildStyles()
    end

    function wrapper:SetDispelGradientWeakAlpha(v)
        t.dispelGradientWeakAlpha = v
        RebuildStyles()
    end

    function wrapper:SetDispelGradientHeight(v)
        t.dispelGradientHeight = v
        RebuildStyles()
    end

    -- NO "player" fallback: a unit-less button must not build a container bound
        -- to the player's own auras (see OnPartyButtonsWired). AE.RequestContainer
        -- asserts on a nil unit, so callers guard before reaching it.
        local unit = button.unit or button:GetAttribute("unit")
    if isPreview then
        -- The Designer preview button's unit is "player" -- a REAL, valid
        -- unit -- so other indicators can preview using the user's actual
        -- name/health/etc. But that means this AuraContainer would ALSO
        -- bind to REAL aura data, and if the player genuinely has an active
        -- dispellable debuff while testing, its real slot renders
        -- alongside (and visually conflicts with) RefreshFallbackVisuals'
        -- always-on mockup -- different type, different styling, same
        -- spot. A deliberately invalid unit token means no real aura data
        -- can ever match here, so only the fallback ever renders on preview.
        unit = "squizzframespreviewfake"
    end
    local slots = {}
    for _, def in ipairs(DISPEL_TYPES) do
        local styleKey = DISPEL_STYLE_PREFIX .. def.key
        AE.styles[styleKey] = BuildDispelStyleForType(t, def)
        slots[#slots + 1] = {
            key = def.key,
            filter = DispelFilterTokens(t),
            candidateFilters = { includeDispelTypes = { [def.token] = true } },
            style = styleKey,
            extraInit = function(slotButton, d)
                d.health = health

                -- Frame STRATA, not frame level, is what actually guarantees
                -- this renders above the health bar and below the button's
                -- own content (nameText/roleIcon/etc): health/power bar are
                -- pinned to "LOW" strata specifically so indicators like
                -- this one can sit in "MEDIUM" -- strictly between that and
                -- the button's own "HIGH" strata -- with zero dependency on
                -- the button's actual frame level, which the secure group
                -- header reassigns unpredictably (see UnitButton.xml's
                -- comment on healthBar/powerBar). "MEDIUM" as of 2026-07-31
                -- (final): the button stays at "HIGH" strata to reliably
                -- beat nameplates (a frame-LEVEL-based alternative was tried
                -- and confirmed unreliable -- nameplates re-raise their own
                -- level constantly), so this whole 3-tier scheme stays
                -- shifted up one level from its pre-2026-07-30 values. The
                -- frame level here only staggers the 5 types relative to
                -- EACH OTHER within that shared strata.
                slotButton:SetFrameStrata("MEDIUM")
                slotButton:SetFrameLevel(1 + def.level)
                ApplyDispelSlotStyle(slotButton, d, AE.styles[styleKey])
            end,
        }
    end

    AE.RequestContainer(wrapper, unit, {
        -- Overlay only. Every slot pins its own textures to `health` directly
        -- (see ApplyDispelSlotStyle), so the container's own rect is never
        -- drawn from -- the icons that used to need it now live in their own
        -- Dispel Icons indicator.
        point = { "CENTER", health, "CENTER" },
        slots = slots,
    }, function(container)
        wrapper._container = container
    end)

    -- The gradient modes' extent is an ABSOLUTE height derived from the health
    -- bar's own height (see ApplyDispelSlotStyle -- there's no fractional
    -- anchor to express it declaratively), so unlike every other mode it does
    -- NOT follow the bar when the bar is resized. Re-firing the restyle on
    -- OnSizeChanged re-measures it, whatever caused the resize (layout
    -- sliders, orientation flip, profile switch) -- cheaper and far more
    -- reliable than trying to find every code path that can resize a button.
    --
    -- Hooked on the health bar, NOT on any AuraContainer slot button (script
    -- handlers on those are forbidden -- CLAUDE.md section 7), and flagged so
    -- the repeated HandleIndicators rebuilds a single roster sync triggers
    -- don't stack duplicate hooks. RestyleSoon is already combat-safe (it
    -- just stops ticking until combat ends).
    if health and health.HookScript and not health._sfDispelGradientResizeHooked then
        health._sfDispelGradientResizeHooked = true
        health:HookScript("OnSizeChanged", function()
            for _, def in ipairs(DISPEL_TYPES) do
                AE.RestyleSoon(DISPEL_STYLE_PREFIX .. def.key)
            end
        end)
    end

    RefreshFallbackVisuals()

    return wrapper
end

------------------------------------------------------------------------
-- Dispel Icons -- its own indicator, separate from the Dispels overlay.
--
-- Split out on 2026-08-13 (user request). They were one indicator because the
-- icons rode along on the overlay's per-type slots, which is also why they
-- stacked; now that they're aura GROUPS they need their own position, size and
-- frame level, and the overlay -- which always covers the health bar and has
-- no geometry of its own -- was the wrong place to configure them from.
--
-- One group per dispel type, each capped at ONE frame. That cap is the dedupe:
-- three Magic debuffs produce a single Magic symbol. The container flows its
-- groups relative to each other (RebuildLayoutGroups sorts by layoutIndex) and
-- an empty group contributes nothing, so whichever types are actually up close
-- ranks with no gaps -- all decided C-side, which matters because the dispel
-- type of any given aura is secret. The group's own filter is what makes the
-- symbol knowable: a group filtered to exactly one dispel type can only ever
-- hold that type.
------------------------------------------------------------------------
local DISPEL_ICONS_STYLE_PREFIX = "dispelIcons_"

local function DispelIconsGroupKey(def) return "dispelIcons_" .. def.key end

-- Per-type filter. Absent map (or absent entry) means enabled: profiles
-- predating the setting showed every type, and the widget renders an absent
-- entry as ticked, so the two agree.
--
-- This is deliberately expressed as a FRAME CAP rather than a filter change:
-- the group's candidate filter is what makes its symbol knowable (a group
-- filtered to one dispel type can only ever hold that type), so it must not be
-- touched. A cap of 0 parks the group -- it stays declared, contributes
-- nothing to the flow, and can be raised again live. The key set stays fixed,
-- which matters because adding or removing a group key is structural and would
-- mean recreating the container.
local function DispelIconTypeEnabled(cfg, def)
    local map = cfg and cfg.dispelTypesEnabled
    if not map then return true end
    return map[def.colorKey] ~= false
end

-- Resolve one orientation token into everything the flow layout needs.
--
-- Three separate things, which is why the other indicators' one-line
-- `(token == "left-to-right") and "RIGHT" or "LEFT"` isn't enough here:
--   axis    -- row or column. Blizzard defaults to Horizontal, so a vertical
--              stack goes nowhere without setting it (see AE.FlowAxis).
--   growthH -- which way along a row; growthV, which way down a column.
--   corner  -- the CONTAINER's own anchor on the wrapper. The container
--              auto-sizes to its content, so this is the edge that stays put
--              as icons appear: anchor top-left and it always grows right and
--              down regardless of the growth directions above.
-- "horizontal"/"vertical" are accepted as aliases for the two default
-- directions, since the shared Orientation dropdown offers them.
local function ResolveOrientation(orientation, growth)
    if orientation == "vertical" then
        if growth == "down-to-up" then
            return "VERTICAL", "RIGHT", "UP", "BOTTOMLEFT"
        end
        return "VERTICAL", "RIGHT", "DOWN", "TOPLEFT"
    end
    if growth == "right-to-left" then
        return "HORIZONTAL", "LEFT", "DOWN", "TOPRIGHT"
    end
    return "HORIZONTAL", "RIGHT", "DOWN", "TOPLEFT"
end

-- Deliberately bare by default: these are Blizzard's dispel-type atlases,
-- already shaped artwork on transparency, so the usual icon furniture fights
-- them. Both are opt-in from the settings panel.
--   showSwipe  -- the Cooldown frame draws the radial sweep AND the dim fill
--                 behind it, which is what reads as a "background".
--   showBorder -- F.CreateBorder draws OUTSIDE the button rect, so on a symbol
--                 it looks like a box floating around the art.
local function BuildDispelIconsStyle(t, def)
    local w, h = ExtractSize(t)
    return {
        -- ALWAYS carries the atlas, even in spell-icon mode: whether the
        -- overlay region gets created at all is decided once, when the button
        -- is built, so a style that might ever show a symbol has to declare
        -- one up front. showIconAtlas is what actually switches the modes.
        iconAtlas = def.atlas,
        showIconAtlas = (t.useSpellIcons ~= true),
        width = w, height = h,
        hideSwipe = (t.showSwipe ~= true),
        border = (t.showIconBorder == true) and { 0, 0, 0, 1, size = 1 } or nil,
        -- No duration or stack text: this indicator exposes no font settings,
        -- so there would be no way to style or move them.
        showDuration = false,
        showStack = false,
    }
end

function AEI.CreateDispelIconsIndicator(button, t)
    if not button then return nil end
    local AE = SquizzFrames.AuraEngine
    if not AE then return nil end

    local wrapper = CreateFrame("Frame", nil, button)
    wrapper._sfType = "builtin"
    local w, h = ExtractSize(t)
    wrapper:SetSize(w, h)

    -- ALWAYS read settings through this, never the captured `t`.
    --
    -- The wrapper is created ONCE, against whichever indicator list was active
    -- at the time, and then reused -- built-ins are never torn down between
    -- rebuilds. Party and Raid are separate lists with separate tables, so on
    -- the Designer preview the closure's `t` goes stale the moment you switch
    -- tabs: it keeps describing the OTHER context. HandleIndicators re-points
    -- wrapper.configs at the current table on every rebuild, so that is the
    -- only reference that tracks the switch.
    --
    -- Symptom when this was read from `t` directly: dispel icon size updated
    -- on the group preview (fresh buttons, fresh closures) but not on the
    -- Designer preview, and only on the Raid tab -- Party happened to be the
    -- context the wrapper was born in (user report 2026-08-13).
    local function Cfg() return wrapper.configs or t end

    local IndicatorsModule = SquizzFrames.Indicators
    local isPreview = IndicatorsModule and IndicatorsModule.IsPreviewButton(button)

    -- Preview mock: the container is driven by the C-side engine against a real
    -- unit, so no fake aura can be injected. A static row of type symbols
    -- stands in, sized and laid out like the real groups.
    local previewIcons
    if isPreview then
        previewIcons = {}
        for i, def in ipairs(DISPEL_TYPES) do
            local f = CreateFrame("Frame", nil, wrapper)
            f.tex = f:CreateTexture(nil, "ARTWORK")
            f.tex:SetAllPoints()
            f.def = def
            previewIcons[i] = f
        end
    end

    -- Which artwork the mock icons wear. In spell-icon mode the real ones show
    -- whatever debuff happens to be up, which the preview can't know (no aura
    -- data reaches it), so a generic placeholder stands in -- same convention
    -- the Debuffs preview already uses. The point of the preview is placement
    -- and size, and a question mark still reads as "a spell icon goes here",
    -- which is the one thing that differs between the two modes.
    local function ApplyPreviewArt(f)
        if Cfg().useSpellIcons == true then
            f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            f.tex:SetTexture([[Interface\Icons\INV_Misc_QuestionMark]])
        else
            f.tex:SetTexCoord(0, 1, 0, 1)
            f.tex:SetAtlas(f.def.atlas)
        end
    end

    local function RefreshPreview()
        if not previewIcons then return end
        local iw, ih = ExtractSize(Cfg())
        local axis, growthH, growthV, corner = ResolveOrientation(Cfg().orientation, Cfg().growthDirection)
        local vertical = (axis == "VERTICAL")
        local shown = 0
        local prev
        for i, f in ipairs(previewIcons) do
            -- Only mock a couple: the point is to show placement and size, and
            -- five symbols at once is not a state anyone actually sees. A type
            -- that's been filtered off is skipped entirely, so switching one off
            -- visibly drops it out of the preview row.
            if shown < 2 and DispelIconTypeEnabled(Cfg(), DISPEL_TYPES[i]) then
                ApplyPreviewArt(f)
                f:ClearAllPoints()
                f:SetSize(iw, ih)
                if not prev then
                    f:SetPoint(corner, wrapper, corner, 0, 0)
                elseif vertical then
                    -- Stack along the column, in the configured direction.
                    if growthV == "UP" then
                        f:SetPoint("BOTTOMLEFT", prev, "TOPLEFT", 0, 1)
                    else
                        f:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -1)
                    end
                elseif growthH == "LEFT" then
                    f:SetPoint("TOPRIGHT", prev, "TOPLEFT", -1, 0)
                else
                    f:SetPoint("TOPLEFT", prev, "TOPRIGHT", 1, 0)
                end
                f:Show()
                prev = f
                shown = shown + 1
            else
                f:Hide()
            end
        end
    end

    local groups = {}
    for i, def in ipairs(DISPEL_TYPES) do
        local styleKey = DISPEL_ICONS_STYLE_PREFIX .. def.key
        AE.styles[styleKey] = BuildDispelIconsStyle(t, def)
        groups[#groups + 1] = {
            key = DispelIconsGroupKey(def),
            filter = DispelFilterTokens(t),
            candidateFilters = { includeDispelTypes = { [def.token] = true } },
            maxFrameCount = DispelIconTypeEnabled(t, def) and 1 or 0,
            style = styleKey,
            -- layoutIndex fixes left-to-right order so icons don't reshuffle as
            -- debuffs come and go; DISPEL_TYPES order is the overlay's own
            -- priority order.
            layout = { elementWidth = w, elementHeight = h,
                       elementSpacing = 1, groupSpacing = 1, layoutIndex = i },
            -- Strata/level set HERE because initializeFrame is the only window
            -- where touching an engine-managed button is legal. Taking the
            -- wrapper's tier keeps these above the health-bar overlay (pinned
            -- to "MEDIUM") AND above the other button content that shares the
            -- button's own strata -- aggroBorder, roleIcon and friends. Read
            -- once, at creation: re-tiering later would mean SetFrameLevel on a
            -- managed button outside this window, which 12.1 forbids.
            extraInit = function(iconButton)
                iconButton:SetFrameStrata(wrapper:GetFrameStrata() or "HIGH")
                iconButton:SetFrameLevel((wrapper:GetFrameLevel() or 0) + 1)
            end,
        }
    end

    local function RefreshGroups()
        local container = wrapper._container
        local iw, ih = ExtractSize(Cfg())
        local filterStr = AE.Filter(unpack(DispelFilterTokens(Cfg())))
        for i, def in ipairs(DISPEL_TYPES) do
            local styleKey = DISPEL_ICONS_STYLE_PREFIX .. def.key
            AE.styles[styleKey] = BuildDispelIconsStyle(Cfg(), def)
            AE.RestyleSoon(styleKey)
            if container then
                local key = DispelIconsGroupKey(def)
                pcall(container.SetAuraGroupFilterString, container, key, filterStr)
                -- Live mutator, and a cheap one: it only marks the container
                -- dirty, and the dirty flags coalesce into one pass on the next
                -- OnUpdate however many groups get pushed here.
                pcall(container.SetAuraGroupMaxFrameCount, container, key,
                    DispelIconTypeEnabled(Cfg(), def) and 1 or 0)
                pcall(container.SetAuraGroupLayout, container, key,
                    { elementWidth = iw, elementHeight = ih,
                      elementSpacing = 1, groupSpacing = 1, layoutIndex = i })
            end
        end
        RefreshPreview()
    end

    local nativeSetSize = wrapper.SetSize
    function wrapper:SetSize(width, height)
        nativeSetSize(self, width, height)
        RefreshGroups()
    end

    function wrapper:SetDispelShowAll(val)
        Cfg().dispelShowAll = val
        RefreshGroups()
    end

    function wrapper:SetDispelTypes(map)
        Cfg().dispelTypesEnabled = map
        RefreshGroups()
    end

    -- Symbol-per-dispel-type vs the actual debuff's own icon. A pure restyle
    -- (AE.RestyleSoon via RefreshGroups) rather than a container rebuild --
    -- see AE.MakeInitializer's d.iconAtlas note for why that's possible.
    function wrapper:SetUseSpellIcons(val)
        Cfg().useSpellIcons = val
        RefreshGroups()
    end

    function wrapper:SetShowSwipe(val)
        Cfg().showSwipe = val
        RefreshGroups()
    end

    function wrapper:SetShowBorder(val)
        Cfg().showIconBorder = val
        RefreshGroups()
    end

    -- Both halves arrive together from the coupled Orientation/Growth widget
    -- (see CreateSetting_GrowthOrientation) -- applying one without the other
    -- would briefly lay out along the new axis in the old axis's direction.
    function wrapper:SetGrowthOrientation(orientation, growth)
        Cfg().orientation = orientation
        Cfg().growthDirection = growth
        local axis, growthH, growthV, corner = ResolveOrientation(orientation, growth)
        local container = wrapper._container
        if container then
            local flowAxis = AE.FlowAxis and AE.FlowAxis(axis)
            if flowAxis and container.SetFlowLayoutAxis then
                pcall(container.SetFlowLayoutAxis, container, flowAxis)
            end
            -- Anchor point is the OPPOSITE edge to the growth direction, so
            -- content flows away from a fixed edge rather than off it.
            container:SetFlowLayoutAnchorPoint((growthH == "RIGHT") and "LEFT" or "RIGHT")
            container:SetFlowLayoutGrowthDirection(AE.FlowDir(growthH), AE.FlowDir(growthV))
            -- ...and re-pin the container itself: it auto-sizes to its content,
            -- so which corner is nailed down decides which way the block
            -- visually grows, independently of the flow's own direction.
            container:ClearAllPoints()
            container:SetPoint(corner, wrapper, corner, 0, 0)
        end
        RefreshPreview()
    end

    if isPreview then
        RefreshPreview()
    else
        -- NO "player" fallback: a unit-less button must not build a container bound
        -- to the player's own auras (see OnPartyButtonsWired). AE.RequestContainer
        -- asserts on a nil unit, so callers guard before reaching it.
        local unit = button.unit or button:GetAttribute("unit")
        local axis, growthH, growthV, corner = ResolveOrientation(Cfg().orientation, Cfg().growthDirection)
        AE.RequestContainer(wrapper, unit, {
            point = { corner, wrapper, corner },
            layout = {
                axis = axis,
                anchorPoint = (growthH == "RIGHT") and "LEFT" or "RIGHT",
                growthH = growthH,
                growthV = growthV,
            },
            groups = groups,
        }, function(container)
            wrapper._container = container
        end)
    end

    return wrapper
end

------------------------------------------------------------------------
-- Custom "color" indicator: health-bar fill tint via a single bare
-- AuraContainer slot, filtered by the user's own configured spell-ID list
-- (t.auras) -- mirrors dispels' exact fill-overlay painting technique
-- rather than the legacy manual C_UnitAuras scan (Custom_Dispatch.lua's
-- CreateColorOverlay), which stopped reliably detecting presence in combat
-- for the same secret-value reasons dispels itself was migrated off of.
-- Scoped to the "fill" anchor modes only (healthbar-current/loss/entire --
-- CreateColorOverlay already treats all three identically) and to spellID
-- matching only (trackByName indicators stay on the legacy scan, since
-- AuraContainer's candidate filters are spellID-based, not name-based) --
-- Indicators.lua's I.CreateIndicator falls back to the legacy
-- CreateColorOverlay for both of those cases and for "unitButton" (border)
-- anchor mode.
------------------------------------------------------------------------
local CUSTOM_COLOR_STYLE_PREFIX = "customColor_"

-- One tier above the health bar's own strata ("LOW" as of 2026-07-31, final
-- -- see UnitButton.xml's comment on healthBar for the full nameplate-strata
-- fix history), or higher if health's strata is already higher (the preview
-- button boosts its own health bar to "DIALOG" to render above the options
-- window).
local function StrataAboveHealth(health)
    local hStrata = health:GetFrameStrata()
    if (STRATA_ORDER[hStrata] or 1) > STRATA_ORDER.MEDIUM then
        return hStrata
    end
    return "MEDIUM"
end

-- Guarded on d.health: AE.MakeInitializer's noRegions branch runs
-- style.applyExtra once before extraInit stashes the health-bar reference
-- on d, then extraInit calls this again right after -- skip that first
-- premature call rather than erroring.
--
-- Overlay texture is a plain white base, colored via SetVertexColor (never
-- SetColorTexture, which would multiply against a threshold-recolor tint
-- instead of cleanly replacing it).
local function ApplyCustomColorSlotStyle(button, d, style)
    if not d.health then return end
    local health = d.health
    if not d.overlay then
        d.overlay = button:CreateTexture(nil, "ARTWORK")
        d.overlay:SetColorTexture(1, 1, 1, 1)
    end
    local tex = d.overlay
    -- Re-measured on every restyle, which is what makes the Frame Border and
    -- power-bar insets follow their settings live.
    AnchorHealthFillOverlay(tex, health)
    local color = style.color or { 0, 1, 0, 1 }
    tex:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
    tex:Show()

    -- Expiring colour: a second wash that the ENGINE reveals once the aura
    -- drops below the threshold. d.expiryText is a FontString whose entire
    -- content is a `|T` rectangle (see AE.BuildExpiryArtEscape) -- the only way
    -- a secret duration can drive a colour. Created and registered in ExtraInit;
    -- everything here is plain region work, legal on any restyle.
    -- Resolved here, NOT captured from an enclosing scope: this function is a
    -- file-level local, so a bare `AE` is a nil GLOBAL. Every other function in
    -- this file resolves it the same way for the same reason. Getting this
    -- wrong is not a quiet nil-index either -- the error surfaces inside the
    -- engine's CreateFrameBatch and takes the whole AddAuraSlot down with it
    -- (442 errors on one roster sync, live 2026-08-14).
    local AE = SquizzFrames.AuraEngine
    if d.expiryText and AE then
        if style.expiringColor then
            local bi = FrameBorderInset(health)
            local bottomInset = HealthBottomInset(health)
            local w = math.max(1, math.floor((health:GetWidth() or 0) - bi * 2))
            local h = math.max(1, math.floor((health:GetHeight() or 0) - bottomInset - bi))

            -- FILL TRACKING. The `|T` is a fixed pixel size and cannot follow
            -- the health fill, so instead the art is drawn at FULL bar width and
            -- a clipping window in front of it is anchored to the fill texture --
            -- the exact anchors the base tint uses (AnchorHealthFillOverlay), so
            -- the two edges can never disagree. All of it is plain anchoring;
            -- nothing reads a health value, secret or otherwise.
            if d.expiryClip then
                AnchorHealthFillOverlay(d.expiryClip, health)
                -- Anchored to the HEALTH BAR, not to the clip window: the art
                -- has to stay nailed to the bar's left edge while the window
                -- shrinks around it. Anchoring it to the window would drag the
                -- art along with the fill and reveal the same slice every time.
                --
                -- y centres the art on the drawable band (bar minus the power
                -- bar at the bottom and the border at the top), which is not the
                -- bar's own centre whenever those two insets differ.
                pcall(d.expiryText.ClearAllPoints, d.expiryText)
                pcall(d.expiryText.SetPoint, d.expiryText, "LEFT", health, "LEFT",
                    bi, (bottomInset - bi) / 2)
            end

            -- Font size == the art's height, matching DandersFrames' working
            -- implementation (`size = h` in its BuildDurationSpec). It has to be
            -- at least the art height or the line box clips it, and making it
            -- exactly equal keeps the two in lockstep as the bar resizes.
            local face = AE.ResolveFont(nil)
            pcall(d.expiryText.SetFont, d.expiryText, face, math.max(1, h), nil)
            AE.SetExpiryArt(style.expiryStyleKey or "",
                style.expiringThreshold or 5,
                AE.BuildExpiryArtEscape(w, h, style.expiringColor, face, h))
            -- pcall'd, NOT dropped. SetDurationText stamps SecretAspect.Alpha
            -- (and Text, and VertexColor) on this FontString, so once the aura
            -- is secret this is a forbidden write. In practice it rarely fires
            -- while secret -- the restyler pauses for the whole of combat -- but
            -- "rarely" isn't never: auras stay secret through an encounter past
            -- the end of a lockdown, which is exactly when the restyler resumes.
            -- Degrading means the alpha lands whenever it legally can and is
            -- skipped when it can't, instead of erroring inside a restyle pass.
            pcall(d.expiryText.SetAlpha, d.expiryText, style.expiringColor[4] or 1)
        else
            -- Blank art rather than Hide(): see the note above on why this
            -- function must not touch the FontString's secret aspects.
            AE.SetExpiryArt(style.expiryStyleKey or "", style.expiringThreshold or 5, "")
        end
    end
end

-- No "expiring soon" recolor -- color is presence + normal color only.
--
-- The old note here said this was impossible because the duration colour curve
-- is text-only. Half right: that curve does only ever drive a FontString
-- (re-confirmed 2026-08-14 against shipped 12.1 source). But a threshold CAN
-- drive a graphic -- the formatter's per-band format string accepts a |T inline
-- texture escape, so the "text" it renders can be the art. See the
-- duration-threshold-driven-visuals memory, which also covers
-- AddPandemicRegion, before deciding this can't be done.
--
-- What actually blocks THIS indicator is geometry, not capability: it paints a
-- health-bar-wide overlay while both mechanisms render inside the aura button's
-- own rect. Workable, but unproven.

local function BuildCustomColorFilters(t)
    local spellSet = F.ConvertSpellTable(t.auras)
    local set = {}
    for id in pairs(spellSet) do
        if type(id) == "number" then set[id] = true end
    end
    return { includeSpellIDs = set }
end

-- Periodic full refresh -- shared by every AddAuraSlot-with-includeSpellIDs
-- indicator (color, bar, ...). container:UpdateAllAuras() forces the slot
-- to re-scan for a fresh match, recovering from AddAuraSlot locking onto a
-- stale matched instance and never picking up a reapplication/refresh.
local slotRefreshRegistry = {} -- [wrapper] = container
local slotRefreshTicker = CreateFrame("Frame")
slotRefreshTicker:Hide()
local slotRefreshElapsed = 0
slotRefreshTicker:SetScript("OnUpdate", function(_, dt)
    slotRefreshElapsed = slotRefreshElapsed + dt
    if slotRefreshElapsed < 1.5 then return end
    slotRefreshElapsed = 0
    local any = false
    for wrapper, container in pairs(slotRefreshRegistry) do
        if not wrapper:IsShown() then
            slotRefreshRegistry[wrapper] = nil -- self-prune hidden/recycled wrappers
        else
            any = true
            pcall(container.UpdateAllAuras, container)
        end
    end
    if not any then slotRefreshTicker:Hide() end
end)

-- Register a wrapper/container pair for the periodic refresh above. Call
-- once per RequestContainer callback right after stashing wrapper._container.
local function RegisterSlotRefresh(wrapper, container)
    slotRefreshRegistry[wrapper] = container
    slotRefreshTicker:Show()
end

function AEI.CreateCustomColorIndicator(button, t)
    if not button then return nil end
    local AE = SquizzFrames.AuraEngine
    if not AE then return nil end
    local health = button.healthBar or button

    local wrapper = CreateFrame("Frame", nil, button)
    wrapper._sfType = "custom"
    wrapper._sfBuiltIn = false
    -- See Indicators.lua's I.RemoveAllCustomIndicators -- this marker keeps
    -- this wrapper (and its AuraContainer) alive across the repeated
    -- HandleIndicators calls that a single /reload's party roster sync
    -- routinely triggers, instead of being torn down and recreated before
    -- the engine ever finishes binding it.
    wrapper._sfAuraEngineBacked = true
    wrapper._t = t

    -- Preview-only fallback: the AuraContainer is driven by the C-side
    -- engine bound to a real unit, so fake aura data can't be injected for
    -- the options panel preview. A plain texture at the same anchor, one
    -- level below the real slot, shows through when nothing real matches.
    local fallbackTex
    local IndicatorsModule = SquizzFrames.Indicators
    if IndicatorsModule and IndicatorsModule.IsPreviewButton(button) then
        -- Parented to wrapper (not button) so Hide()'ing wrapper -- what
        -- ApplySettingToOne's "enabled"/"delete" handling actually calls --
        -- cascade-hides this too. It used to be parented to button, which
        -- left it visible after disabling/deleting the indicator in preview.
        local fallbackHost = CreateFrame("Frame", nil, wrapper)
        fallbackHost:SetFrameStrata(StrataAboveHealth(health))
        fallbackHost:SetFrameLevel(health:GetFrameLevel() + 1)
        fallbackTex = fallbackHost:CreateTexture(nil, "ARTWORK")
        fallbackTex:SetColorTexture(1, 1, 1, 1)
        -- Same insets as the live overlay, so the preview shows the real
        -- geometry rather than a flush rectangle the live frame never draws.
        AnchorHealthFillOverlay(fallbackTex, health)
    end

    local styleKey = CUSTOM_COLOR_STYLE_PREFIX .. t.indicatorName
    local function RebuildStyle()
        local ct = wrapper._t.customColors and wrapper._t.customColors[1]
        local color = ct and {ct[1] or 0, ct[2] or 1, ct[3] or 0, ct[4] or 1} or {0, 1, 0, 1}
        -- Expiring colour, opt-in. Stored in the {"custom_color", r,g,b,a}
        -- shape every other colour setting uses.
        -- type-checked, not just `or`-defaulted: an earlier build could write a
        -- boolean here and it may already be saved in a profile, and
        -- `true or {default}` is `true`, which F.ColorRGB then indexes.
        local ec = nil
        if wrapper._t.expiringEnabled then
            local stored = wrapper._t.expiringColor
            if type(stored) ~= "table" then stored = {"custom_color", 1, 0, 0, 1} end
            local r, g, b, a = F.ColorRGB(stored)
            ec = { r, g, b, a }
        end
        AE.styles[styleKey] = {
            noRegions = true,
            color = color,
            expiringColor = ec,
            expiringThreshold = wrapper._t.expiringThreshold or 5,
            -- The art formatter is cached under its own key so it can't collide
            -- with this style's ordinary duration-text formatter.
            expiryStyleKey = styleKey .. "#expiry",
            applyExtra = ApplyCustomColorSlotStyle,
        }
        if fallbackTex then
            fallbackTex:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
        end
        AE.RestyleSoon(styleKey)
    end
    RebuildStyle()

    -- Re-measure the Frame Border / power-bar insets without rebuilding the
    -- style: the colour hasn't changed, only the geometry ApplyCustomColorSlot
    -- Style measures at apply time. Same contract as the Dispels wrapper's
    -- method of the same name -- AEI.RefreshBorderInsets finds either by duck
    -- typing, so a new overlay indicator joins in just by defining it.
    function wrapper:RefreshBorderInset()
        AE.RestyleSoon(styleKey)
        -- The preview stand-in isn't driven by the engine's restyler, so it
        -- has to be re-anchored by hand.
        if fallbackTex then AnchorHealthFillOverlay(fallbackTex, health) end
    end

    -- Re-derives the candidate filter set live -- called by Indicators.lua's
    -- ApplySettingToOne whenever this indicator's tracked aura list changes
    -- (same mechanism externalCooldowns/defensiveCooldowns/healerHots use).
    function wrapper:RefreshSpellList(newT)
        wrapper._t = newT or wrapper._t
        local container = wrapper._container
        if container then
            -- pcall: unconfirmed whether SetAuraSlotCandidateFilters can be
            -- patched live everywhere; degrades to "takes effect next /reload".
            pcall(container.SetAuraSlotCandidateFilters, container, t.indicatorName, BuildCustomColorFilters(wrapper._t))
        end
        RebuildStyle()
    end

    function wrapper:SetColor()
        RebuildStyle()
    end

    -- Threshold/colour/enabled all arrive together from the one widget.
    -- RebuildStyle re-stamps the style and queues a restyle; the restyle is
    -- what re-runs ApplyCustomColorSlotStyle, which is where the formatter's
    -- bands actually get rewritten (AE.SetExpiryArt).
    function wrapper:SetExpiringColor(payload)
        if type(payload) ~= "table" then return end
        wrapper._t.expiringEnabled = payload.enabled
        wrapper._t.expiringThreshold = payload.threshold
        -- Only accept a real colour table. A previous build routed this through
        -- the positional dispatch and could land a BOOLEAN here, which then
        -- reached F.ColorRGB and errored -- and, worse, persisted into the
        -- profile, so the guard in RebuildStyle has to survive that too.
        if type(payload.color) == "table" then
            wrapper._t.expiringColor = payload.color
        end
        RebuildStyle()
    end

    -- No-op: presence/color both come from the engine-driven slot button.
    -- Kept so ShowCustomIndicators' "does this indicator have
    -- SetAuraInstanceID" check routes here instead of a nonexistent SetCooldown.
    function wrapper:SetAuraInstanceID() end

    -- Shared per-slot extraInit -- also reused below by the periodic
    -- re-declaration ticker, so a forced rebind styles the button exactly
    -- the same way the initial AddAuraSlot call did.
    local function ExtraInit(slotButton, d)
        d.health = health
        wrapper._d = d
        -- "MEDIUM" as of 2026-07-31 (final) -- see the identical note on
        -- Dispels' slotButton:SetFrameStrata call above.
        slotButton:SetFrameStrata("MEDIUM")
        slotButton:SetFrameLevel(1)

        -- Expiring-colour carrier. A FontString rather than a texture because
        -- the only threshold-vs-secret-duration comparison we're allowed is the
        -- formatter's, and a formatter emits TEXT -- so the wash is a `|T`
        -- inline texture inside this string. SetDurationText may only be called
        -- here (the PTR5 initializeFrame rule), which is why the FontString is
        -- created unconditionally even when the option is off: turning it on
        -- later just fills the art in, with no button API call needed.
        if not d.expiryText then
            -- Clipping window for the expiring wash, so it tracks the health
            -- fill instead of being a fixed-width block. Anchored in
            -- ApplyCustomColorSlotStyle; here we only build it.
            --
            -- A child FRAME of the slot button, with the FontString on IT rather
            -- than on the button. Legal: SetDurationText's validation requires
            -- only "a direct child or indirect descendent of owner"
            -- (AuraContainerUtil.ValidateInboundScriptObject), and this is a
            -- descendant. It is emphatically NOT reparenting an aura button,
            -- which is the thing 12.1 bans.
            --
            -- DisableUntrustedLayoutScriptsTemplate when the build has it:
            -- AddAuraGroup/AddAuraSlot stamp ForbiddenAspect.
            -- UntrustedLayoutScriptExecution on the container, and SetPoint
            -- refuses a dependent that lacks it ("Anchoring disallowed as
            -- dependent object would inherit forbidden aspects" -- DandersFrames
            -- hit this in the field on 68914). Aspects are never granted
            -- implicitly, and the template is Blizzard's own sanctioned opt-in.
            -- Cost is that this frame may never run layout scripts, which it
            -- doesn't need. Probed so older builds keep a plain frame.
            local aspectTmpl = C_XMLUtil and C_XMLUtil.GetTemplateInfo
                and C_XMLUtil.GetTemplateInfo("DisableUntrustedLayoutScriptsTemplate")
                and "DisableUntrustedLayoutScriptsTemplate" or nil
            d.expiryClip = CreateFrame("Frame", nil, slotButton, aspectTmpl)
            d.expiryClip:SetClipsChildren(true)
            -- Above the base tint (a texture on the button itself), so the
            -- expiring colour reads as replacing it rather than blending under.
            d.expiryClip:SetFrameLevel((slotButton:GetFrameLevel() or 1) + 1)

            d.expiryText = d.expiryClip:CreateFontString(nil, "OVERLAY")
            -- The string never contains glyphs, only the |T escape -- but
            -- SetFont must still be called or the engine's first SetText hard
            -- errors inside the button batch (and that aborts the WHOLE batch,
            -- not just this button).
            --
            -- Placeholder size only -- ApplyCustomColorSlotStyle re-sets this to
            -- the art's own height on every restyle, and runs immediately below.
            -- SetFont must still happen before the engine's first SetText or it
            -- hard errors inside the button batch.
            d.expiryText:SetFont(AE.ResolveFont(nil), 12, nil)
            -- Alpha is set HERE as well as on restyle, because this is the one
            -- window where it is always legal -- SetDurationText below stamps
            -- SecretAspect.Alpha on this string, after which the restyle-path
            -- write can be refused. Seeding it now means the saved opacity is
            -- always correct at least from creation.
            local ec = wrapper._t and wrapper._t.expiringColor
            if type(ec) == "table" then
                local _, _, _, a = F.ColorRGB(ec)
                d.expiryText:SetAlpha(a or 1)
            end
            -- Placeholder anchor; ApplyCustomColorSlotStyle re-points this to
            -- the health bar's LEFT edge, which is what makes the clip window
            -- reveal a growing slice rather than dragging the art along.
            d.expiryText:SetPoint("LEFT", health, "LEFT", 0, 0)
            AE.SetDurationTextSafe(slotButton, d.expiryText, {
                textFormatter = AE.GetExpiryArtFormatter(
                    styleKey .. "#expiry",
                    (wrapper._t and wrapper._t.expiringThreshold) or 5,
                    ""),
            })
        end

        ApplyCustomColorSlotStyle(slotButton, d, AE.styles[styleKey])
    end

    -- NO "player" fallback: a unit-less button must not build a container bound
        -- to the player's own auras (see OnPartyButtonsWired). AE.RequestContainer
        -- asserts on a nil unit, so callers guard before reaching it.
        local unit = button.unit or button:GetAttribute("unit")
    -- AddAuraSlot (one per spell, includeSpellIDs candidateFilters), NOT
    -- AddAuraGroup -- groups are for multi-icon grids where several auras
    -- can show at once; a slot is exactly one frame, always present,
    -- visibility toggled internally by the engine. Hardcoded strata/level
    -- (not derived from health:GetFrameLevel()) since the secure group
    -- header reassigns frame levels unpredictably; level 1 keeps this
    -- below dispels' own levels (2-6).
    AE.RequestContainer(wrapper, unit, {
        point = { "CENTER", health, "CENTER" },
        slots = {
            {
                key = t.indicatorName,
                filter = { t.auraType == "debuff" and "HARMFUL" or "HELPFUL" },
                candidateFilters = BuildCustomColorFilters(t),
                style = styleKey,
                -- NOTE: do NOT attach any script handler (HookScript/
                -- SetScript) to this button -- the engine's AddSecretAspect
                -- wiring (drives presence Show/Hide) requires exclusive
                -- control and throws if anything else registers one.
                extraInit = ExtraInit,
            },
        },
    }, function(container)
        wrapper._container = container
        RegisterSlotRefresh(wrapper, container)
    end)

    return wrapper
end

------------------------------------------------------------------------
-- Custom "bar" indicator: the visible StatusBar is a child of the actual
-- AddAuraSlot slot button, so Show/Hide is engine-driven like color's
-- overlay. Duration fill uses native SetDurationBar, bound on the same
-- slot button the bar is parented to (matching Ellesmere's BmBarInit).
------------------------------------------------------------------------
local CUSTOM_BAR_STYLE_PREFIX = "customBar_"

-- Guarded on d.wrapper for the same premature-first-call reason as
-- ApplyCustomColorSlotStyle's d.health guard.
local function ApplyCustomBarSlotStyle(slotButton, d, style)
    if not d.wrapper then return end
    if not d.bar then
        local bar = CreateFrame("StatusBar", nil, slotButton)
        bar.tex = bar:CreateTexture(nil, "ARTWORK")
        bar.tex:SetColorTexture(1, 1, 1, 1)
        bar:SetStatusBarTexture(bar.tex)
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(1)
        d.bar = bar

        local opts = {}
        if Enum.StatusBarInterpolation then opts.interpolation = Enum.StatusBarInterpolation.Immediate end
        if Enum.StatusBarTimerDirection then opts.direction = Enum.StatusBarTimerDirection.RemainingTime end
        pcall(slotButton.SetDurationBar, slotButton, bar, opts)
    end
    d.bar:ClearAllPoints()
    d.bar:SetAllPoints(d.wrapper)
    local color = style.color or { 0, 1, 0, 1 }
    d.bar.tex:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
    d.bar:Show()
end

function AEI.CreateCustomBarIndicator(button, t)
    if not button then return nil end
    local AE = SquizzFrames.AuraEngine
    if not AE then return nil end
    local health = button.healthBar or button

    -- Plain positioning frame -- what Indicators.lua treats as "the
    -- indicator" for position/size/enabled; the actual bar anchors to it.
    local wrapper = CreateFrame("Frame", nil, button)
    wrapper._sfType = "custom"
    wrapper._sfBuiltIn = false
    wrapper._sfAuraEngineBacked = true
    wrapper._t = t
    wrapper:SetSize(18, 4)

    -- Preview-only fallback: same reasoning as CreateCustomColorIndicator's
    -- fallbackTex -- the AuraContainer is driven by the C-side engine bound
    -- to a real unit, so it never gets real aura data on the preview button,
    -- and without this the bar simply never renders there. A plain texture
    -- filling wrapper (same rect the real bar anchors to via SetAllPoints)
    -- stands in for the duration fill.
    local fallbackTex
    local IndicatorsModule = SquizzFrames.Indicators
    if IndicatorsModule and IndicatorsModule.IsPreviewButton(button) then
        fallbackTex = wrapper:CreateTexture(nil, "ARTWORK")
        fallbackTex:SetColorTexture(1, 1, 1, 1)
        fallbackTex:SetAllPoints(wrapper)
    end

    local styleKey = CUSTOM_BAR_STYLE_PREFIX .. t.indicatorName
    local function RebuildStyle()
        local ct = wrapper._t.colors and wrapper._t.colors[1]
        local color = ct and { ct[1] or 0, ct[2] or 1, ct[3] or 0, ct[4] or 1 } or { 0, 1, 0, 1 }
        AE.styles[styleKey] = {
            noRegions = true,
            color = color,
            applyExtra = ApplyCustomBarSlotStyle,
        }
        if fallbackTex then
            fallbackTex:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
        end
        AE.RestyleSoon(styleKey)
    end
    RebuildStyle()

    -- Dispatched by Indicators.lua's ApplySettingToOne for the "colors"
    -- setting (`indicator.SetColors(value)`, called WITHOUT a colon --
    -- plain function, not a method).
    wrapper.SetColors = function(value)
        wrapper._t.colors = value
        RebuildStyle()
    end

    function wrapper:RefreshSpellList(newT)
        wrapper._t = newT or wrapper._t
        local container = wrapper._container
        if container then
            pcall(container.SetAuraSlotCandidateFilters, container, t.indicatorName, BuildCustomColorFilters(wrapper._t))
        end
        RebuildStyle()
    end

    -- No-op: presence/fill both come from the engine-driven slot button.
    -- Kept so ShowCustomIndicators' "does this indicator have
    -- SetAuraInstanceID" check routes here instead of a nonexistent SetCooldown.
    function wrapper:SetAuraInstanceID() end

    -- NO "player" fallback: a unit-less button must not build a container bound
        -- to the player's own auras (see OnPartyButtonsWired). AE.RequestContainer
        -- asserts on a nil unit, so callers guard before reaching it.
        local unit = button.unit or button:GetAttribute("unit")
    local function ExtraInit(slotButton, d)
        d.wrapper = wrapper
        wrapper._d = d
        slotButton:SetFrameStrata(StrataAboveHealth(health))
        slotButton:SetFrameLevel(2)
        ApplyCustomBarSlotStyle(slotButton, d, AE.styles[styleKey])
    end

    AE.RequestContainer(wrapper, unit, {
        point = { "CENTER", wrapper, "CENTER" },
        slots = {
            {
                key = t.indicatorName,
                filter = { t.auraType == "debuff" and "HARMFUL" or "HELPFUL" },
                candidateFilters = BuildCustomColorFilters(t),
                style = styleKey,
                -- NOTE: do NOT attach any script handler to slotButton
                -- itself -- see CreateCustomColorIndicator's identical note.
                extraInit = ExtraInit,
            },
        },
    }, function(container)
        wrapper._container = container
        RegisterSlotRefresh(wrapper, container)
    end)

    return wrapper
end

------------------------------------------------------------------------
-- Re-point every AuraEngine-backed indicator on `button` at the button's
-- CURRENT unit.
--
-- Each Create*Indicator above reads button.unit once, at creation, and hands
-- it to AE.RequestContainer. The secure group header then reassigns unit
-- tokens across its children on every roster change and every re-sort, and
-- nothing was updating the containers to match -- so an indicator would keep
-- showing the unit it was FIRST built for. See AE.RebindUnit for the full
-- write-up; that function is also where the no-op/combat handling lives, so
-- this can be called unconditionally and as often as convenient.
--
-- Preview buttons are deliberately excluded: their containers are either
-- absent entirely or bound to the invalid "squizzframespreviewfake" token on
-- purpose (see CreateDispelsIndicator), and re-pointing them at the preview
-- button's real "player" unit is precisely the real-data leak those branches
-- exist to prevent.
------------------------------------------------------------------------
function AEI.SyncContainerUnits(button)
    if not button or not button.indicators then return end
    local AE = SquizzFrames.AuraEngine
    if not AE or not AE.RebindUnit then return end
    local IndicatorsModule = SquizzFrames.Indicators
    if IndicatorsModule and IndicatorsModule.IsPreviewButton(button) then return end

    local unit = button.unit or button:GetAttribute("unit")
    if not unit then return end

    for _, indicator in pairs(button.indicators) do
        -- _container is set from the RequestContainer callback, so it's nil
        -- for non-AuraEngine indicators and for AuraEngine ones still waiting
        -- on a combat-deferred creation. The latter need nothing here: they
        -- get created with whatever unit is current when the queue drains.
        if type(indicator) == "table" and indicator._container then
            AE.RebindUnit(indicator._container, unit)
        end
    end
end

-- Re-measure every Dispels indicator's Frame Border inset. Called from
-- Indicators.lua's ApplySettingToOne when the frameBorder indicator's
-- thickness or enabled state changes -- see FrameBorderInset for why the two
-- are coupled, and wrapper:RefreshBorderInset for what this actually re-runs.
function AEI.RefreshBorderInsets()
    -- Duck-typed across EVERY indicator on the button rather than a fixed list.
    -- Custom "color" indicators are keyed by user-chosen names, so they can't be
    -- looked up by a known key at all -- and any future health-bar overlay opts
    -- in just by defining RefreshBorderInset.
    local function Poke(btn)
        if not btn or not btn.indicators then return end
        for _, ind in pairs(btn.indicators) do
            if type(ind) == "table" and ind.RefreshBorderInset then
                ind:RefreshBorderInset()
            end
        end
    end
    local PartyFrames = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    if PartyFrames and PartyFrames.IterateButtons then
        PartyFrames:IterateButtons(Poke)
    end
    -- The Designer preview isn't in IterateButtons, and it's the one place the
    -- user is actually looking while dragging the border-size slider.
    local IndicatorsModule = SquizzFrames.Indicators
    if IndicatorsModule and IndicatorsModule.previewButton then
        Poke(IndicatorsModule.previewButton)
    end
end

------------------------------------------------------------------------
-- Re-measure Blizzard's identity gate for the three spell-list indicators.
--
-- Blizzard only honours includeSpellIDs for a HELPFUL aura while
-- UnitCanAssist("player", unitToken) is true, and it tests that PER AURA, at
-- parse time (Blizzard_AuraContainerUtil.lua):
--
--     if auraData.isHelpful and not UnitCanAssist("player", unitToken) then
--         return false;      -- ...and the caller then skips includeSpellIDs
--
-- Our only backstop when that gate is shut is the 60s maxDuration noise floor
-- (see NoiseFloorMaxDuration) -- but that was measured ONCE, when the
-- container was built, and candidate filters were otherwise only ever
-- re-pushed on a settings change. So the two filters failed together: a
-- container built while the gate was open carries no noise floor, and if the
-- gate later shuts, NOTHING narrows the group and every helpful buff on the
-- unit appears. Reported 2026-08-13 while controlling a vehicle-like NPC,
-- with untracked scenario buffs (Void-Touched Orbs, Dance of the Wind)
-- showing up across Healer HoTs and both Cooldown indicators at once.
--
-- Units are re-synced first, deliberately: with toggleForVehicle set on the
-- button, entering a vehicle can change which token the button represents,
-- and the gate must be measured against the token the container is ACTUALLY
-- bound to. Doing it in this order also means we don't have to know which of
-- the two effects caused any given report -- both are corrected.
--
-- VEHICLES ARE NOT THE ONLY THING THAT MOVES THE GATE. UnitCanAssist is
-- genuinely false for a CROSS-FACTION group member in the open world -- you
-- can't heal or buff them out there -- and genuinely true for the same player
-- once you're both inside a dungeon. So the gate flips on every instance
-- transition, and that is not a Blizzard bug, it's the designed behaviour of
-- the identity restriction. Reported 2026-08-15: cross-faction party members
-- showed their entire buff list on Healer HoTs and both Cooldown indicators
-- in the open world while behaving correctly in dungeons -- the containers
-- had been built inside an instance with the gate OPEN (so no noise floor)
-- and nothing re-measured on the way out.
--
-- Hence this is now driven by the broader IDENTITY_GATE_EVENTS list in
-- Indicators.lua (zone/instance change, roster change, PvP-flag change,
-- vehicle transitions) rather than vehicles alone. Blanket-calling it is
-- affordable because RefreshCandidateFilters(true) short-circuits on an
-- unchanged reading -- see GateReadingMoved. Without that guard this would be
-- five buttons x three indicators x a full aura re-parse each, every time.
------------------------------------------------------------------------
local IDENTITY_GATED_INDICATORS = { "healerHots", "externalCooldowns", "defensiveCooldowns" }

function AEI.RefreshIdentityGatedFilters()
    local function Poke(btn)
        if not btn or not btn.indicators then return end
        AEI.SyncContainerUnits(btn)
        for _, name in ipairs(IDENTITY_GATED_INDICATORS) do
            local ind = btn.indicators[name]
            if ind and ind.RefreshCandidateFilters then
                ind:RefreshCandidateFilters(true)
            end
        end
    end
    local PartyFrames = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    if PartyFrames and PartyFrames.IterateButtons then
        PartyFrames:IterateButtons(Poke)
    end
    -- Preview deliberately excluded, same reason SyncContainerUnits excludes
    -- it: its containers are absent or bound to a fake token on purpose.
end

-- Sync every real button. Used for the post-combat container drain below,
-- where the trigger is engine-side rather than per-button.
function AEI.SyncAllContainerUnits()
    local PartyFrames = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    if PartyFrames and PartyFrames.IterateButtons then
        PartyFrames:IterateButtons(AEI.SyncContainerUnits)
    end
end

do
    local AE = SquizzFrames.AuraEngine
    if AE and AE.OnContainersDrained then
        AE.OnContainersDrained(AEI.SyncAllContainerUnits)
    end
end
