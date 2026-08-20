--[[ SquizzFrames HideBlizzard - Hide/show default party/raid frames
    Reparent technique adapted from Cell (by Dandre) and ElvUI. ]]
-- Reparent to a hidden frame (kept reversible -- see ShowFrame) rather than
-- destructively unregistering events, which cannot be undone: WoW has no API
-- to read back which events a frame had registered, so a frame that had
-- UnregisterAllEvents() called on it can never be fully restored to working
-- order without a /reload. Since this needs to be a live, two-way toggle
-- (bug fix 2026-07-29: the options checkbox previously only ever hid frames,
-- never restored them), events are left alone and only the parent/visibility
-- state is touched, which IS fully reversible.

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

-- Hidden parent frame for reparenting
local hiddenParent = CreateFrame("Frame", nil, UIParent)
hiddenParent:SetAllPoints()
hiddenParent:Hide()

-- Combat safety (bug fix 2026-08-07, shipping bug on live). Every frame this
-- file touches (PartyFrame, CompactPartyFrame, CompactRaidFrameContainer,
-- CompactRaidFrameManager, PartyMemberFrameN) is a PROTECTED Blizzard frame:
-- Hide()/Show()/SetParent() on them all throw ADDON_ACTION_BLOCKED in
-- combat. This file previously had NO InCombatLockdown() guard anywhere,
-- while its permanent OnShow hooks fire exactly when Blizzard re-shows those
-- frames -- which routinely happens mid-combat (joining a raid during a
-- pull, roster updates) -- and the options checkboxes can be toggled in
-- combat too.
--
-- Deferred work is stored as a SET of pending operations rather than a
-- queue of closures, so repeated toggles during one fight collapse to the
-- final intent instead of replaying every intermediate state at combat end.
local pendingApply = {}
local combatRetryFrame

local function FlushPending()
    local party, raid = pendingApply.party, pendingApply.raid
    pendingApply.party, pendingApply.raid = nil, nil
    if party ~= nil then SquizzFrames:HideBlizzardParty() end
    if raid ~= nil then SquizzFrames:HideBlizzardRaid() end
end

-- Returns true if the caller should BAIL (work was deferred to combat end).
local function DeferIfInCombat(which)
    if not InCombatLockdown() then return false end
    pendingApply[which] = true
    if not combatRetryFrame then
        combatRetryFrame = CreateFrame("Frame")
        combatRetryFrame:SetScript("OnEvent", function(self)
            self:UnregisterEvent("PLAYER_REGEN_ENABLED")
            FlushPending()
        end)
    end
    combatRetryFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    return true
end

local function HideFrame(frame)
    if not frame then return end
    if InCombatLockdown() then return end
    if frame._sfOriginalParent == nil then
        frame._sfOriginalParent = frame:GetParent() or UIParent
    end
    frame:Hide()
    frame:SetParent(hiddenParent)
end

local function ShowFrame(frame)
    if not frame then return end
    if InCombatLockdown() then return end
    frame:SetParent(frame._sfOriginalParent or UIParent)
    frame:Show()
end

-- Live setting readers -- checked at HOOK-FIRE time (not just once at hook-
-- install time), so a single permanently-installed HookScript (WoW hooks
-- can't be removed once added) can still honor a setting that changes later.
local function ShouldHideParty()
    local p = SquizzFrames.db and SquizzFrames.db.profile
    local v = p and p.general and p.general.hideBlizzardParty
    if v == nil then return true end -- matches the DB default (Appearance_Defaults.lua)
    return v
end

local function ShouldHideRaid()
    local p = SquizzFrames.db and SquizzFrames.db.profile
    local v = p and p.general and p.general.hideBlizzardRaid
    if v == nil then return true end
    return v
end

-- PartyFrame's own OnShow (12.x pool-based frame) is neutralized while
-- hidden, since it otherwise re-anchors/re-shows pool member frames under
-- itself on every roster change, fighting the per-member HideFrame calls
-- below. Captured/restored via GetScript/SetScript (both fully reversible,
-- unlike UnregisterAllEvents) rather than permanently nil-ing it out.
local function SetPartyFrameOnShowNeutralized(neutralize)
    if not PartyFrame then return end
    if neutralize then
        if PartyFrame._sfOriginalOnShow == nil then
            PartyFrame._sfOriginalOnShow = PartyFrame:GetScript("OnShow") or false
        end
        PartyFrame:SetScript("OnShow", nil)
    else
        if PartyFrame._sfOriginalOnShow ~= nil then
            PartyFrame:SetScript("OnShow", PartyFrame._sfOriginalOnShow or nil)
        end
    end
end

-- Latch is set only once the hook is ACTUALLY installed (bug fix
-- 2026-08-07). Previously `xHooksInstalled = true` ran BEFORE the
-- `if <frame>` existence checks, so the very first call -- which happens at
-- OnEnable+0.5s, typically while solo with Blizzard_CompactRaidFrames not
-- yet loaded -- permanently latched "installed" without installing
-- anything. The hooks then never got another chance, so Blizzard's frames
-- reappeared on joining a group and never got re-hidden. Now an
-- unsuccessful attempt leaves the latch clear, and ApplyX re-attempts on
-- every call (including the new GroupTypeChanged/ProfileChanged paths).
local partyHooksInstalled = false
local function InstallPartyHooks()
    if partyHooksInstalled then return end

    -- CompactPartyFrame (raid-style party frames) -- hook is permanent (WoW
    -- API limitation), so it re-checks the live setting every time instead
    -- of unconditionally re-hiding.
    if CompactPartyFrame then
        CompactPartyFrame:HookScript("OnShow", function(frame)
            -- Blizzard can re-show this mid-combat; SetParent would throw.
            if ShouldHideParty() and not InCombatLockdown() then
                frame:SetParent(hiddenParent)
            end
        end)
        partyHooksInstalled = true
    end
end

local function ApplyPartyFrames(hide)
    InstallPartyHooks()

    -- 12.x: PartyFrame uses a pool of PartyMemberFrame
    if PartyFrame then
        SetPartyFrameOnShowNeutralized(hide)
        if PartyFrame.PartyMemberFramePool then
            -- Re-enumerated fresh (not cached) so roster changes since the
            -- last hide/show are picked up correctly in either direction.
            for frame in PartyFrame.PartyMemberFramePool:EnumerateActive() do
                if hide then HideFrame(frame) else ShowFrame(frame) end
            end
        end
        if hide then HideFrame(PartyFrame) else ShowFrame(PartyFrame) end
    end

    -- CompactPartyFrame (raid-style party frames)
    if CompactPartyFrame then
        if hide then HideFrame(CompactPartyFrame) else ShowFrame(CompactPartyFrame) end
    end

    -- Fallback: legacy party frames
    for i = 1, 4 do
        local frame = _G["PartyMemberFrame" .. i]
        if frame then
            if hide then HideFrame(frame) else ShowFrame(frame) end
        end
        local compact = _G["CompactPartyMemberFrame" .. i]
        if compact then
            if hide then HideFrame(compact) else ShowFrame(compact) end
        end
    end

    if PartyMemberBackground then
        if hide then HideFrame(PartyMemberBackground) else ShowFrame(PartyMemberBackground) end
    end
end

-- Tracked per-frame, not with one shared latch: CompactRaidFrameContainer
-- and CompactRaidFrameManager come from Blizzard_CompactRaidFrames and can
-- become available at different times, so a single flag would let whichever
-- one existed first permanently suppress the other's hook.
local containerHookInstalled = false
local managerHookInstalled = false
local function InstallRaidHooks()
    if not containerHookInstalled and CompactRaidFrameContainer then
        CompactRaidFrameContainer:HookScript("OnShow", function(frame)
            if ShouldHideRaid() and not InCombatLockdown() then
                frame:SetParent(hiddenParent)
            end
        end)
        containerHookInstalled = true
    end

    if not managerHookInstalled and CompactRaidFrameManager then
        CompactRaidFrameManager:HookScript("OnShow", function(frame)
            if ShouldHideRaid() and not InCombatLockdown() then
                frame:SetParent(hiddenParent)
            end
        end)
        managerHookInstalled = true
    end
end

local function ApplyRaidFrames(hide)
    InstallRaidHooks()

    if CompactRaidFrameContainer then
        if hide then HideFrame(CompactRaidFrameContainer) else ShowFrame(CompactRaidFrameContainer) end
    end

    if CompactRaidFrameManager then
        if hide then HideFrame(CompactRaidFrameManager) else ShowFrame(CompactRaidFrameManager) end
    end
end

function SquizzFrames:HideBlizzardParty()
    if DeferIfInCombat("party") then return end
    ApplyPartyFrames(ShouldHideParty())
end

function SquizzFrames:HideBlizzardRaid()
    if DeferIfInCombat("raid") then return end
    ApplyRaidFrames(ShouldHideRaid())
end

function SquizzFrames:HideBlizzard()
    SquizzFrames:HideBlizzardParty()
    SquizzFrames:HideBlizzardRaid()
end

-- Re-apply on group-type and profile changes (bug fix 2026-08-07). Nothing
-- in this file listened for either before, so:
--   * Joining a raid left Blizzard's raid frames visible -- the only
--     unconditional call is Core.lua's OnEnable+0.5s pass, which typically
--     runs while solo (before Blizzard_CompactRaidFrames has even loaded,
--     which is also why the hook-install latch above had to be fixed).
--   * Switching to a profile with different hideBlizzardParty/Raid values
--     did nothing until a /reload.
-- Raw events go on a private frame so this file stays independent of module
-- load order (it's a root-level file, not a module).
local hideBlizzardEventFrame = CreateFrame("Frame")
hideBlizzardEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
hideBlizzardEventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
hideBlizzardEventFrame:SetScript("OnEvent", function()
    if SquizzFrames.HideBlizzard then SquizzFrames:HideBlizzard() end
end)

-- AceEvent MESSAGES must be registered on a table that is OURS ALONE --
-- CallbackHandler keys by (owner, message), so registering on the shared
-- SquizzFrames root would silently replace another file's handler for the
-- same message. See F.NewMessageOwner's comment in Utils.lua.
local messageOwner = SquizzFrames.F.NewMessageOwner()
messageOwner:RegisterMessage("GroupTypeChanged", function()
    if SquizzFrames.HideBlizzard then SquizzFrames:HideBlizzard() end
end)
messageOwner:RegisterMessage("ProfileChanged", function()
    if SquizzFrames.HideBlizzard then SquizzFrames:HideBlizzard() end
end)
