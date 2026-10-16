--[[ SquizzFrames PartyRange.lua -- out-of-range fading for party/raid frames.
    Moved out of PartyFrames.lua unchanged in 2.0 (phase 2 code split).
    PartyFrames.lua keeps forwarders under the same four names
    (RebuildRangeChecker, UpdateRangeAlpha, ResetRangeAlpha,
    RefreshRangePolling) that call through PartyFrames.range, published at
    the end of this file. ]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F
local RC = LibStub and LibStub:GetLibrary("LibRangeCheck-3.0", true)
---@class AceModule
local PartyFrames = SquizzFrames:GetModule("PartyFrames")

local shared = PartyFrames.shared
local GetProfile = shared.GetProfile
local SyncStatusTextAlpha = shared.SyncStatusTextAlpha
local unitButtons = shared.unitButtons -- same table for good: only ever wiped

local rangeTicker -- out-of-range alpha poll, started in OnEnable's init()
-- Assigned by the `function Name()` definitions below.
local RebuildRangeChecker, UpdateRangeAlpha, ResetRangeAlpha, RefreshRangePolling

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
-- Is there anything the range poll could actually change?
--
-- Solo with no pet the answer is no, and it used to poll anyway from login to
-- logout (the ticker was only ever cancelled in OnDisable). Two subjects
-- exist:
--   * group members -- the whole point of the feature;
--   * a visible pet button -- the one thing that can be out of range while
--     ungrouped. UNIT_IN_RANGE_UPDATE can't cover it on its own: it's a unit
--     event Blizzard registers per displayed unit, and nothing fires on plain
--     movement out of combat (see the registration site's own comment).
-- Your own frame is never dimmed -- UpdateRangeAlpha forces IsPlayerUnit to
-- full alpha -- so a lone player is polling to write alpha 1 over alpha 1.
local function RangePollNeeded()
    if IsInGroup() then return true end
    local PetFrames = SquizzFrames.modules and SquizzFrames.modules["PetFrames"]
    return (PetFrames and PetFrames.HasVisibleButtons and PetFrames.HasVisibleButtons()) or false
end

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
        SyncStatusTextAlpha(button)
    end)
end

-- Start or stop the 0.5s poll to match what there is to poll. Cheap and
-- idempotent, so it can be called from anything that changes the answer --
-- roster changes, a pet appearing, the Fade Out of Range setting.
--
-- Stopping resets alpha: whatever dimming was last applied has to be undone,
-- not frozen in place, since nothing will re-evaluate it (same reasoning as
-- OnDisable's own cancel).
-- UNIT_IN_RANGE_UPDATE handler, hoisted to file scope so RefreshRangePolling
-- can register and unregister it.
--
-- Debounced to one pass per frame: the event is synchronous and per-unit, so a
-- group crossing the boundary together (everyone running out of an ability, a
-- party-wide teleport) delivers a burst of them in a single frame.
--
-- The PAYLOAD IS IGNORED ENTIRELY -- both the unit token and the isInRange
-- flag. Blizzard's API documentation declares this event SecretPayloads
-- (confirmed in UnitDocumentation.lua), so reading either is a taint risk for
-- no benefit; it's used purely as a "something moved" ping and every button is
-- then re-evaluated through the normal path.
local rangeEventPending = false
local function FlushRangeEvent()
    rangeEventPending = false
    UpdateRangeAlpha()
end
local function OnRangeEvent()
    if rangeEventPending then return end
    rangeEventPending = true
    C_Timer.After(0, FlushRangeEvent)
end

function RefreshRangePolling()
    -- The Fade Out of Range checkbox (profile.general.fadeOut) was WRITTEN by
    -- the options page and read by nothing -- range fading ran regardless of
    -- it. Honoured here, which is also the cheapest possible reading of "off":
    -- the poll doesn't run at all. Defaults to on when the key is absent, so
    -- an existing profile behaves exactly as it did.
    local prof = GetProfile()
    local fadeEnabled = (not prof or not prof.general or prof.general.fadeOut ~= false)
    if not RC or not fadeEnabled or not RangePollNeeded() then
        if rangeTicker then
            rangeTicker:Cancel()
            rangeTicker = nil
            ResetRangeAlpha()
        end
        -- Drop the event too, not just the ticker. Blizzard's own
        -- CompactUnitFrame registers UNIT_IN_RANGE_UPDATE only while a frame
        -- is visible, with the note that "C++ does extra work to send these
        -- events while any frame is registered for them" -- so staying
        -- registered while we have nothing to do with it makes the client pay
        -- for a ping we'd throw away. AceEvent releases the underlying WoW
        -- registration once its last handler for an event goes.
        --
        -- Deliberately NOT per-unit (RegisterUnitEvent): unit tokens get
        -- reassigned across buttons by the secure header on every re-sort, so
        -- a per-token registration needs its own re-wiring lifecycle, and
        -- getting it wrong fails silently -- the 0.5s poll would mask it, and
        -- the fade would just quietly stop being immediate.
        PartyFrames:UnregisterEvent("UNIT_IN_RANGE_UPDATE")
        return
    end
    if not rangeTicker then
        rangeTicker = C_Timer.NewTicker(0.5, UpdateRangeAlpha)
        -- Same owner + event, so re-registering is a replace, not a stack.
        PartyFrames:RegisterEvent("UNIT_IN_RANGE_UPDATE", OnRangeEvent)
        -- Catch up immediately rather than showing a stale alpha for up to
        -- half a second after (re)starting.
        UpdateRangeAlpha()
    end
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
    local general = prof and prof.appearance and prof.appearance.general
    local outOfRangeAlpha = (general and general.outOfRangeAlpha) or 0.3
    -- "Don't Fade Dead Players" (user request 2026-10-04): a corpse keeps full
    -- opacity at any distance. UnitIsDeadOrGhost is a plain boolean here (the
    -- combat branch below already tests it the same way).
    local keepDead = general and general.keepDeadUndimmed
    ForEachRangeButton(function(unit, button)
        SyncStatusTextAlpha(button)
        if UnitExists(unit) then
            -- Never dim the player's own frame -- you're never "out of range"
            -- of yourself. IsPlayerUnit catches both the literal "player"
            -- unit and any vehicle-mapped alias that still refers to the
            -- player, without tripping over a secret comparison result.
            if IsPlayerUnit(unit) or (keepDead and UnitIsDeadOrGhost(unit)) then
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

PartyFrames.range = {
    RebuildRangeChecker = RebuildRangeChecker,
    UpdateRangeAlpha = UpdateRangeAlpha,
    ResetRangeAlpha = ResetRangeAlpha,
    RefreshRangePolling = RefreshRangePolling,
    -- OnDisable: stop the poll, and undo whatever dimming was last applied
    -- instead of freezing it in place. A no-op when nothing was polling.
    StopPolling = function()
        if rangeTicker then
            rangeTicker:Cancel()
            rangeTicker = nil
            ResetRangeAlpha()
        end
    end,
}
