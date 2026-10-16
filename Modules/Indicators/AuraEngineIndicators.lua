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
-- ⚠ EFFECTIVELY RETIRED as of client build 69465 (2026-08-24): Blizzard's gate
-- no longer shuts for helpful auras on any token we bind, so
-- NoiseFloorMaxDuration below can't return a cap any more. Everything from
-- here to SeedGateState is inert on a current client and kept only as the
-- fallback if that hotfix is reverted -- see ComputeIdentityGateState's own
-- note for what changed and why it's neutralised there rather than deleted.
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

    -- HOTFIXED BY BLIZZARD, build 69465 (2026-08-24), eight builds after 12.1
    -- shipped. Confirmed from client source, not patch notes:
    -- Blizzard_AuraContainer/Blizzard_AuraContainerUtil.lua's
    -- CanApplyIdentityCandidateFilters gained an early-out ABOVE the
    -- UnitCanAssist tests it previously led with --
    --
    --     -- Filtering helpful spells on the active player / any group members
    --     -- (or their pets) is always allowed. In some edge cases like with
    --     -- Mind Control, the UnitCanAssist checks below can return false for
    --     -- group members.
    --     if auraData.isHelpful and UnitIsPlayerControlledOrGroupMember(unitToken) then
    --         return true;
    --     end
    --
    -- UnitIsPlayerControlledOrGroupMember is new in the same build and covers
    -- exactly player/pet/vehicle/partyN/partypetN/raidN/raidpetN -- i.e. every
    -- token this addon's frames can ever bind. So for HELPFUL auras the gate
    -- this whole subsystem exists to work around can no longer shut for us.
    --
    -- Neutralised HERE, at the single point the gate is read, rather than by
    -- deleting the machinery below. Three reasons: the noise floor and the
    -- hide decision both derive from this one reading, so one early-out
    -- retires both; Healer HoTs' castBy == "me" hide keys off UnitIsVisible
    -- rather than the gate and is preserved untouched by construction; and if
    -- the hotfix is ever reverted, restoring the old behaviour is deleting
    -- this block rather than rebuilding ~150 lines from git history.
    --
    -- Guarded on the API existing so a client older than 69465 still falls
    -- through to the original probe.
    if UnitIsPlayerControlledOrGroupMember
        and ReadFlag(UnitIsPlayerControlledOrGroupMember, unit) == true then
        return GATE_OPEN
    end

    -- UnitIsUnit rather than `unit == "player"`: in raid layouts your own
    -- token is raidN, so a string compare misses your own frame entirely.
    -- It reads secret on rated-PvP maps, in which case this falls through to
    -- the general branch below, which is correct anyway.
    if ReadFlag(UnitIsUnit, unit, "player") == true then
        local vehicleProbe = UnitUsingVehicle or UnitInVehicle
        if ReadFlag(vehicleProbe, "player") == true then return GATE_SHUT end
        -- Cleanly-false only. An unreadable self-assist keeps the historical
        -- self-exemption rather than shutting the gate on your own frame.
        --
        -- The two trailing args (canAssistImmunePC, canAssistUninteractable)
        -- are new in 69465 and both default to FALSE. The engine passes them
        -- TRUE in its own gate test, with the note "ignore immune/
        -- uninteractable restrictions otherwise filters won't be applied when
        -- the player is in a vehicle, teleporting, etc." -- so measuring
        -- without them asks a different question than the one being answered
        -- on the other side. Harmless on an older client: extra args to a
        -- two-arg API are ignored.
        if ReadFlag(UnitCanAssist, "player", "player", true, true) == false then return GATE_SHUT end
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
    -- Same two new args as the self branch above, for the same reason.
    local assist = ReadFlag(UnitCanAssist, "player", unit, true, true)
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
--   1. A definite SHUT usually HIDES the indicator (ApplyGateVisibility), so
--      the floor mostly has nothing left to render. Not always, though, and
--      that is why it stays: Healer HoTs with castBy == "me" installs its own
--      hide test keyed on UnitIsVisible rather than the gate, so that wrapper
--      can be perfectly visible while the gate reads SHUT -- and the floor is
--      the only thing keeping its pool readable.
--   2. Flooring an UNKNOWN was the worse of both outcomes: the pool is shown
--      regardless (the hide never fires on UNKNOWN), just with every long
--      tracked buff stripped out of it.
local function NoiseFloorMaxDuration(unit)
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
    -- the key cannot drift from what actually gets pushed.
    local gate = NoiseFloorMaxDuration(unit)
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
    local filters = { includeSpellIDs = set, maxDuration = NoiseFloorMaxDuration(unit) }
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
-- Resolve one of the shared Orientation dropdown's six tokens into everything
-- the flow layout needs. The four AuraGroup indicators (Healer HoTs, External
-- /Defensive Cooldowns, Debuffs, CC) each used to inline
-- `(token == "left-to-right") and "RIGHT" or "LEFT"`, which only ever
-- described a horizontal row: the vertical tokens fell through to the
-- right-to-left branch and produced a leftward ROW, so picking Vertical
-- appeared to do nothing (or worse, silently flipped the row).
--
--   axis    -- row vs column. Blizzard's flow layout defaults to Horizontal,
--              so a column needs SetFlowLayoutAxis; nothing else implies it.
--   growthH -- which way along a row. growthV -- which way down a column.
--   corner  -- the CONTAINER's own anchor on the wrapper. It auto-sizes to
--              its content, so this is the edge that stays put as icons
--              appear, and it has to agree with the growth direction or the
--              block grows the opposite way to the icons inside it.
--
-- Same four-value shape (and the same conventions) as ResolveOrientation
-- further down, which does this for Dispel Icons' two-dropdown
-- orientation+growth pair. This one takes the single combined token instead.
local function ResolveFlow(orientation)
    if orientation == "top-to-bottom" or orientation == "vertical" then
        return "VERTICAL", "RIGHT", "DOWN", "TOPLEFT"
    elseif orientation == "bottom-to-top" then
        return "VERTICAL", "RIGHT", "UP", "BOTTOMLEFT"
    elseif orientation == "right-to-left" then
        return "HORIZONTAL", "LEFT", "DOWN", "TOPRIGHT"
    end
    -- "left-to-right", "horizontal", and anything unrecognised.
    return "HORIZONTAL", "RIGHT", "DOWN", "TOPLEFT"
end

-- Flow layout table for a container spec, from one orientation token.
local function FlowLayout(orientation)
    local axis, growthH, growthV = ResolveFlow(orientation)
    return {
        axis = axis,
        -- Anchor point is the OPPOSITE edge to the growth direction, so
        -- content flows away from a fixed edge rather than off it.
        anchorPoint = (growthH == "RIGHT") and "LEFT" or "RIGHT",
        growthH = growthH,
        growthV = growthV,
    }
end

-- Re-point a live container at a new orientation. Shared by all four
-- AuraGroup indicators' SetOrientation.
local function ApplyFlowToContainer(container, orientation, wrapper)
    if not container then return end
    local AE = SquizzFrames.AuraEngine
    local axis, growthH, growthV, corner = ResolveFlow(orientation)
    local flowAxis = AE and AE.FlowAxis and AE.FlowAxis(axis)
    if flowAxis and container.SetFlowLayoutAxis then
        pcall(container.SetFlowLayoutAxis, container, flowAxis)
    end
    container:SetFlowLayoutAnchorPoint((growthH == "RIGHT") and "LEFT" or "RIGHT")
    container:SetFlowLayoutGrowthDirection(AE.FlowDir(growthH), AE.FlowDir(growthV))
    container:ClearAllPoints()
    container:SetPoint(corner, wrapper, corner, 0, 0)
end

local function ExtractSize(t)
    local sz = t.size or { 16, 16 }
    if type(sz[1]) == "table" then sz = sz[1] end
    return sz[1] or 16, sz[2] or 16
end

-- Preview-only: a row of `count` static icon frames, children of `wrapper`,
-- laid out on the same corner/axis/direction ResolveFlow gives the
-- real AuraContainer. Shared by healerHots and the cooldown kinds since
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

-- Style ONE mock duration FontString from a style table, exactly as
-- ApplyStyleToRegions (AuraEngine.lua) styles the real engine-drawn one.
--
-- Takes a style TABLE rather than a style key on purpose: the unit frames'
-- options preview has to render settings for a row whose live style may not
-- exist yet (the frame can be disabled, or the row never anchored), so it
-- builds a throwaway table from the config being edited and passes that. The
-- party fallback row hands in AE.styles[...] and gets identical treatment.
--
-- `mode` is the Show Duration value: "never", a number of seconds (threshold
-- modes, previewed with that exact number, which doubles as a reminder of
-- which threshold is on), or anything else for always.
function AEI.ApplyMockDurationText(fs, host, style, mode)
    local AE = SquizzFrames.AuraEngine
    if not (fs and host and AE) then return end
    style = style or {}
    local threshold = tonumber(mode)
    fs:SetFont(AE.ResolveFont(style.durationFont), style.durationFontSize or 11,
        style.durationFontFlags or "OUTLINE")
    local c = style.durationColor
    if c then fs:SetTextColor(c[1], c[2], c[3], c[4] or 1) end
    fs:ClearAllPoints()
    fs:SetPoint(style.durationPoint or "TOP", host, style.durationRelPoint or "BOTTOM",
        style.durationX or 0, style.durationY or -2)
    fs:SetText(threshold and tostring(threshold) or FALLBACK_DURATION_SAMPLE)
    fs:SetShown(mode ~= "never" and style.showDuration ~= false)
end

-- The stack-count half of the same job.
--
-- "2" as the sample: on a live frame the engine only writes a count when there
-- is actually more than one application, so a single digit is the honest
-- common case and the right width to judge placement against.
function AEI.ApplyMockStackText(fs, host, style, show)
    local AE = SquizzFrames.AuraEngine
    if not (fs and host and AE) then return end
    style = style or {}
    fs:SetFont(AE.ResolveFont(style.stackFont), style.stackFontSize or 12,
        style.stackFontFlags or "OUTLINE")
    local c = style.stackColor
    if c then fs:SetTextColor(c[1], c[2], c[3], c[4] or 1) end
    fs:ClearAllPoints()
    fs:SetPoint(style.stackPoint or "BOTTOMRIGHT", host,
        style.stackRelPoint or style.stackPoint or "BOTTOMRIGHT",
        style.stackX or 1, style.stackY or -1)
    fs:SetText("2")
    fs:SetShown(show ~= false and style.showStack ~= false)
end
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
    -- Both of these style the mock text from the SAME style fields the live
    -- engine path reads (see ApplyStyleToRegions in AuraEngine.lua), so the
    -- preview tracks font/colour/offset changes rather than drifting from what
    -- the real icons will look like -- one shared implementation, which the
    -- unit frames' own 1:1 preview calls too.
    local function RefreshDuration(mode)
        local AE = SquizzFrames.AuraEngine
        local style = (AE and styleKey and AE.styles[styleKey]) or {}
        for _, f in ipairs(icons) do
            AEI.ApplyMockDurationText(f.duration, f, style, mode)
        end
    end

    local function RefreshStacks(show)
        local AE = SquizzFrames.AuraEngine
        local style = (AE and styleKey and AE.styles[styleKey]) or {}
        for _, f in ipairs(icons) do
            AEI.ApplyMockStackText(f.stack, f, style, show)
        end
    end
    local function Reposition()
        -- Mirrors the real container's flow: same axis, same growth direction,
        -- same fixed corner. The preview is the only place a vertical stack
        -- can be judged before there are real auras to look at, so it has to
        -- follow all four tokens, not just the horizontal pair.
        local axis, growthH, growthV, corner = ResolveFlow(wrapper._orientation)
        local vertical = (axis == "VERTICAL")
        local iw = wrapper._w or defaultW
        local ih = wrapper._h or defaultH
        local shown = math.min(wrapper._num or count, count)
        local prev
        for i, f in ipairs(icons) do
            if i <= shown then
                f:ClearAllPoints()
                f:SetSize(iw, ih)
                if not prev then
                    f:SetPoint(corner, wrapper, corner, 0, 0)
                elseif vertical then
                    if growthV == "UP" then
                        f:SetPoint("BOTTOMLEFT", prev, "TOPLEFT", 0, FALLBACK_ICON_GAP)
                    else
                        f:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -FALLBACK_ICON_GAP)
                    end
                elseif growthH == "RIGHT" then
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

-- t.pandemicColor ({"custom_color", r, g, b, a}, from the Highlight Color
-- widget) as the plain {r, g, b, a} AE.MakeInitializer/ApplyStyleToRegions
-- read; unset means the default gold.
local function PandemicColor(colorTable)
    if type(colorTable) == "table" and colorTable[1] == "custom_color" and #colorTable >= 5 then
        return { colorTable[2], colorTable[3], colorTable[4], colorTable[5] }
    end
    return { 1, 0.82, 0.2, 1 }
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
        -- Buttons get the refresh-window highlight regions at creation
        -- (AE.MakeInitializer); showPandemic below switches them live.
        pandemic = true,
    }
    -- Font settings (typeface, size, outline, anchor, X/Y offset, colour
    -- for BOTH the stack and duration text) are re-applied on every
    -- build, not folded into the `or {}` above: that table is only
    -- created once and then reused for the lifetime of the style, so
    -- anything set inside it can never respond to a settings change.
    AE.ApplyFontSettings(AE.styles[STYLE_KEY], t.font)
    AE.styles[STYLE_KEY].showPandemic = (t.showPandemic == true) -- opt-in: an unset profile field must read as unticked
    AE.styles[STYLE_KEY].pandemicColor = PandemicColor(t.pandemicColor)

    return {
        layout = FlowLayout(t.orientation),
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
        ApplyFlowToContainer(wrapper._container, token, wrapper)
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
        -- Before the short-circuit, so the visibility decision is re-run even
        -- when the gate reading has not moved. No setting drives it any more
        -- (the Show Unfiltered toggle did, until V1.24 removed it), so this is
        -- now defensive rather than load-bearing -- cheap, and it keeps the
        -- hide correct for any future caller that refreshes without a move.
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
    -- The refresh-window (pandemic) highlight's on/off. Only the host frame
    -- is toggled (see AE.MakeInitializer), so no rebuild is needed.
    function wrapper:SetShowPandemic(show)
        local style = AE.styles[STYLE_KEY]
        if not style then return end
        style.showPandemic = (show == true)
        AE.RestyleSoon(STYLE_KEY)
    end
    function wrapper:SetPandemicColor(colorTable)
        local style = AE.styles[STYLE_KEY]
        if not style then return end
        style.pandemicColor = PandemicColor(colorTable)
        AE.RestyleSoon(STYLE_KEY)
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
            -- Re-assert the whole flow (axis, growth, anchored corner), not
            -- just the corner: the spec's layout was resolved when the
            -- container was REQUESTED, which can be several seconds and a
            -- combat drop earlier than this callback.
            ApplyFlowToContainer(container, wrapper._orientation, wrapper)
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
    return { includeSpellIDs = set, maxDuration = NoiseFloorMaxDuration(unit) }
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

    return {
        layout = FlowLayout(t.orientation),
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
        ApplyFlowToContainer(wrapper._container, token, wrapper)
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
            -- Re-assert the whole flow (axis, growth, anchored corner), not
            -- just the corner: the spec's layout was resolved when the
            -- container was REQUESTED, which can be several seconds and a
            -- combat drop earlier than this callback.
            ApplyFlowToContainer(container, wrapper._orientation, wrapper)
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

-- Preset narrowing for the Debuffs indicator's Filter dropdown.
--
-- CANDIDATE filters, not filter-string tokens, and necessarily so: IMPORTANT
-- is flagged on HELPFUL auras, so "HARMFUL|IMPORTANT" is an empty set. These
-- are the harmful equivalents, and unlike include/excludeSpellIDs they are NOT
-- gated by CanApplyIdentityCandidateFilters, so they keep working on debuffs
-- applied to party members.
--
-- Both depend on Blizzard having FLAGGED the aura, which is their weakness:
-- either can render an empty row in content the game never tagged. That is not
-- hypothetical -- the tank tracker's equivalent boss_role preset showed nothing
-- at all for the Lost Explorers (2026-09-19). Hence "all" is the default and
-- these are opt-in.
local DEBUFF_FILTER_CANDIDATES = {
    important = { isPriorityAura = true },
    boss_role = { isBossOrRoleAura = true },
    -- "both" is a UNION, and a union cannot live in one group: candidate
    -- filters are ANDed (every key is an independent early reject in
    -- DoesAuraPassCandidateFilters), so pairing the two flags here would
    -- INTERSECT them -- narrower than either, the opposite of the intent.
    -- The primary group therefore takes boss/role and a second group takes
    -- the priority half; see DEBUFF_UNION_SECOND.
    both      = { isBossOrRoleAura = true },
}

-- The union's second group: priority auras that are NOT boss/role. The
-- negation makes the two groups mutually exclusive BY CONSTRUCTION, so no aura
-- can match both and no Lua-side dedup is needed -- the same trick the CC
-- indicator's removed second group used with the "!" filter token.
local DEBUFF_UNION_SECOND = { isPriorityAura = true, isBossOrRoleAura = false }

-- Second group key. Declared for the life of the container whether the union
-- is selected or not: groups are ADD-ONLY, so one not declared at creation can
-- never appear when the dropdown changes later. A cap of 0 is how a declared
-- group is held inert (SetAuraGroupEnabled is 12.1.5 and not live yet).
local DEBUFFS_GROUP_KEY_PRIORITY = "debuffs_priority"

-- Icon capacity for the two groups.
--
-- A fixed split, because maxFrameCount is a STATIC per-group cap -- the engine
-- gives a group no way to borrow slots another group left unused, so a true
-- "first come, first served up to N total" is not expressible. Boss/role takes
-- the larger half so the more important category wins the odd icon.
--
-- The trade-off is under-fill: with no priority debuffs up, the row shows at
-- most the boss/role half rather than the full number. The alternative was
-- giving both groups the full cap and rendering up to 2x what the slider says,
-- which is how the CC indicator behaved before its second group was dropped.
local function DebuffGroupCaps(t)
    local num = t.num or 10
    if (t.debuffFilter or "all") ~= "both" then return num, 0 end
    local second = math.floor(num / 2)
    return num - second, second
end

local function BuildDebuffCandidateFilters(t)
    local filters = {}
    local preset = DEBUFF_FILTER_CANDIDATES[t.debuffFilter or "all"]
    if preset then
        -- Copied in rather than referenced: the blacklist below writes into
        -- this same table, and the preset tables are shared module state.
        for k, v in pairs(preset) do filters[k] = v end
    end
    if t.debuffBlacklist and t.debuffBlacklist[1] then
        local set = {}
        for _, id in ipairs(t.debuffBlacklist) do set[id] = true end
        filters.excludeSpellIDs = set
    end
    return filters
end

-- Candidate filters for the union's SECOND group. nil when the union is not
-- selected, which leaves that group matching nothing worth showing -- its cap
-- is 0 in that case anyway (see DebuffGroupCaps).
--
-- Carries the blacklist too: a user who excluded a spell means it everywhere,
-- not just in whichever group happens to catch it first.
local function BuildDebuffUnionFilters(t)
    if (t.debuffFilter or "all") ~= "both" then return nil end
    local filters = {}
    for k, v in pairs(DEBUFF_UNION_SECOND) do filters[k] = v end
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

    local primaryCap, secondCap = DebuffGroupCaps(t)

    return {
        layout = FlowLayout(t.orientation),
        groups = {
            {
                key = DEBUFFS_GROUP_KEY,
                filter = DebuffFilterTokens(t),
                maxFrameCount = primaryCap,
                candidateFilters = BuildDebuffCandidateFilters(t),
                style = DEBUFFS_STYLE_KEY,
                layout = { elementWidth = w, elementHeight = h },
            },
            -- Always declared, capped at 0 unless the union is selected -- see
            -- DEBUFFS_GROUP_KEY_PRIORITY on why this cannot be added later.
            {
                key = DEBUFFS_GROUP_KEY_PRIORITY,
                filter = DebuffFilterTokens(t),
                maxFrameCount = secondCap,
                candidateFilters = BuildDebuffUnionFilters(t),
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
            -- BOTH groups. Sizing only the primary one leaves the union's
            -- priority half at the old element size, i.e. a row of icons that
            -- do not match each other.
            local elements = { elementWidth = width, elementHeight = height }
            container:SetAuraGroupLayout(DEBUFFS_GROUP_KEY, elements)
            pcall(container.SetAuraGroupLayout, container, DEBUFFS_GROUP_KEY_PRIORITY, elements)
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
        ApplyFlowToContainer(wrapper._container, token, wrapper)
        if RepositionFallback then RepositionFallback() end
    end

    function wrapper:SetNum(n)
        wrapper._num = n
        -- Written back onto the settings table BEFORE the split is computed:
        -- DebuffGroupCaps reads t.num, so without this the caps would be
        -- derived from the previous number and the new one would not take.
        if wrapper._t then wrapper._t.num = n end
        local container = wrapper._container
        if container then
            -- Through DebuffGroupCaps, not the raw n. Assigning n straight to
            -- the primary group would hand it the WHOLE budget and leave the
            -- union's second group on a stale cap -- so "max 3" could render
            -- more than 3, which is the one promise this number makes.
            local primaryCap, secondCap = DebuffGroupCaps(wrapper._t or {})
            container:SetAuraGroupMaxFrameCount(DEBUFFS_GROUP_KEY, primaryCap)
            pcall(container.SetAuraGroupMaxFrameCount, container, DEBUFFS_GROUP_KEY_PRIORITY, secondCap)
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
            local filterString = AE.Filter(unpack(DebuffFilterTokens(wrapper._t)))
            local primaryCap, secondCap = DebuffGroupCaps(wrapper._t)

            pcall(container.SetAuraGroupFilterString, container, DEBUFFS_GROUP_KEY, filterString)
            container:SetAuraGroupCandidateFilters(DEBUFFS_GROUP_KEY, BuildDebuffCandidateFilters(wrapper._t))
            pcall(container.SetAuraGroupMaxFrameCount, container, DEBUFFS_GROUP_KEY, primaryCap)

            -- BOTH groups, every time. Pushing only the first is the silent
            -- failure this whole subsystem is prone to: the union's second
            -- group would keep whatever cap and filters it was created with,
            -- so switching the dropdown would half-apply.
            pcall(container.SetAuraGroupFilterString, container, DEBUFFS_GROUP_KEY_PRIORITY, filterString)
            pcall(container.SetAuraGroupCandidateFilters, container, DEBUFFS_GROUP_KEY_PRIORITY, BuildDebuffUnionFilters(wrapper._t))
            pcall(container.SetAuraGroupMaxFrameCount, container, DEBUFFS_GROUP_KEY_PRIORITY, secondCap)
        end
    end

    if not isPreview then
        -- NO "player" fallback: a unit-less button must not build a container bound
        -- to the player's own auras (see OnPartyButtonsWired). AE.RequestContainer
        -- asserts on a nil unit, so callers guard before reaching it.
        local unit = button.unit or button:GetAttribute("unit")
        AE.RequestContainer(wrapper, unit, spec, function(container)
            wrapper._container = container
            -- Re-assert the whole flow (axis, growth, anchored corner), not
            -- just the corner: the spec's layout was resolved when the
            -- container was REQUESTED, which can be several seconds and a
            -- combat drop earlier than this callback.
            ApplyFlowToContainer(container, wrapper._orientation, wrapper)
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

    return {
        layout = FlowLayout(t.orientation),
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
        ApplyFlowToContainer(wrapper._container, token, wrapper)
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
            -- Re-assert the whole flow (axis, growth, anchored corner), not
            -- just the corner: the spec's layout was resolved when the
            -- container was REQUESTED, which can be several seconds and a
            -- combat drop earlier than this callback.
            ApplyFlowToContainer(container, wrapper._orientation, wrapper)
            container:SetShown(wrapper:IsShown())
            SeedGateState(wrapper)
        end)
    end

    return wrapper
end

------------------------------------------------------------------------
-- Dispels and Dispel Icons live in AuraEngineDispels.lua, and the custom
-- color/bar indicators in AuraEngineCustom.lua (both moved in 2.0). Both
-- load right after this file.
------------------------------------------------------------------------
AEI.shared = { ExtractSize = ExtractSize } -- private helpers the split-out files read at load

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
-- ⚠ The gate half of this is INERT as of build 69465 (2026-08-24) -- helpful
-- filtering is now always permitted on group tokens, so the reading can't
-- move. What this function still does, and what it is now kept for, is the
-- SyncContainerUnits call: the secure header reassigns unit tokens across
-- buttons on the very same events, and re-binding the containers to match is
-- unrelated to the gate and still load-bearing.
--
-- Historically: Blizzard only honoured includeSpellIDs for a HELPFUL aura
-- while UnitCanAssist("player", unitToken) was true, tested PER AURA, at
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

-----------------------------------------------------------------------
-- /sfants -- state of the Dispels Animated Border on the Designer preview
-- (added 2026-10-14, while the dashes rendered nowhere). Preview frames are
-- plain and non-secret, so everything here is safe to read; it never touches
-- a live slot button.
-----------------------------------------------------------------------
-- Arguments are throwaway experiments on the PREVIEW only, undone by a
-- /reload: "top" lifts the ants to TOOLTIP strata, "noclip" turns the clip
-- off, "solid" swaps the dash image for solid red. Any combination.
SLASH_SQUIZZANTS1 = "/sfants"
SlashCmdList["SQUIZZANTS"] = function(msg)
    local P = "|cff33cc99[SquizzFrames]|r "
    msg = (msg or ""):lower()
    local ok, err = pcall(function()
        local I = SquizzFrames.Indicators
        local pb = I and I.GetPreviewButton and I.GetPreviewButton()
        local w = pb and pb.indicators and pb.indicators.dispels
        local d = w and w._sfPreviewCtx
        if not d then
            print(P .. "ants: no Dispels preview -- open /sf > Indicators > Dispels first")
            return
        end
        local t = w._sfTable or {}
        print(P .. "ants: dispelAnts=" .. tostring(t.dispelAnts) .. " overlay=" .. tostring(t.dispelOverlay))
        local c = d.antsClip
        if not c then print(P .. "ants: no clip frame was built") return end
        print(P .. ("ants clip: shown=%s visible=%s size=%s x %s strata=%s level=%s"):format(
            tostring(c:IsShown()), tostring(c:IsVisible()), tostring(c:GetWidth()), tostring(c:GetHeight()),
            tostring(c:GetFrameStrata()), tostring(c:GetFrameLevel())))
        for i, e in ipairs(d.antsEdges or {}) do
            local tex = e.tex
            local m = tex:GetParent()
            local r, g, b, a = tex:GetVertexColor()
            print(P .. ("ants strip %d: shown=%s visible=%s file=%s colour=%.2f,%.2f,%.2f,%.2f strip=%s x %s"):format(
                i, tostring(tex:IsShown()), tostring(tex:IsVisible()), tostring(tex:GetTexture()),
                r or -1, g or -1, b or -1, a or -1, tostring(m:GetWidth()), tostring(m:GetHeight())))
        end
        local h = d.health
        print(P .. ("ants health bar: %s x %s, level=%s"):format(
            tostring(h and h:GetWidth()), tostring(h and h:GetHeight()), tostring(h and h:GetFrameLevel())))

        -- Anything on the preview drawn ABOVE the ants: same strata at a
        -- higher level, or a higher strata outright.
        local STRATA = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5,
            FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }
        local cs, cl = STRATA[c:GetFrameStrata()] or 0, c:GetFrameLevel()
        local above = 0
        -- Per indicator in its own pcall: not every entry is a plain Frame (one
        -- had GetFrameLevel but no GetFrameStrata and killed the whole report).
        for name, ind in pairs(pb.indicators) do
            pcall(function()
                if not (ind.IsVisible and ind:IsVisible()) then return end
                local st = ind:GetFrameStrata()
                local s, l = STRATA[st] or 0, ind:GetFrameLevel()
                if s > cs or (s == cs and l >= cl) then
                    above = above + 1
                    print(P .. ("ants: above them -> %s (%s %s)"):format(
                        tostring(name), tostring(st), tostring(l)))
                end
            end)
        end
        print(P .. "ants: " .. above .. " visible indicator(s) drawn above the ants")

        if msg:find("top") then
            c:SetFrameStrata("TOOLTIP")
            print(P .. "ants: TEST lifted to TOOLTIP strata")
        end
        if msg:find("noclip") then
            c:SetClipsChildren(false)
            print(P .. "ants: TEST clipping off (strips will overhang the frame)")
        end
        if msg:find("solid") then
            for _, e in ipairs(d.antsEdges or {}) do e.tex:SetColorTexture(1, 0, 0, 1) end
            print(P .. "ants: TEST solid red strips")
        end
    end)
    if not ok then print(P .. "ants: error " .. tostring(err)) end
    print(P .. "ants: end of report")
end
