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
    local unitframes, castbar = pendingApply.unitframes, pendingApply.castbar
    local pet = pendingApply.pet
    pendingApply.party, pendingApply.raid = nil, nil
    pendingApply.unitframes, pendingApply.castbar = nil, nil
    pendingApply.pet = nil
    if party ~= nil then SquizzFrames:HideBlizzardParty() end
    if raid ~= nil then SquizzFrames:HideBlizzardRaid() end
    -- Every DeferIfInCombat key MUST be drained here. A key set by
    -- DeferIfInCombat but missing from this function is deferred forever, with
    -- no error -- the work simply never happens.
    if unitframes ~= nil then SquizzFrames:HideBlizzardUnitFrames() end
    if castbar ~= nil then SquizzFrames:HideBlizzardCastBar() end
    if pet ~= nil then SquizzFrames:HideBlizzardPetFrame() end
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

-- THE master switch (2026-09-05). One setting for every Blizzard frame this
-- addon replaces, replacing the old general.hideBlizzardParty +
-- general.hideBlizzardRaid + unitFrames.hideBlizzard +
-- unitFrames.hideBlizzardCastBar quartet -- see MigrateHideBlizzardSwitches
-- in Core.lua for the collapse and why.
--
-- Turning it on is safe because it is only ever half the answer: every
-- Should* reader below ANDs it with "and do we actually draw a replacement
-- for this particular frame". Anything of ours that is switched off falls
-- back to Blizzard's own frame rather than leaving that unit blank. That
-- also means Blizzard's ARENA frames are untouched -- we don't draw arena
-- frames yet, so there is nothing to fall back FROM.
--
-- Read live at HOOK-FIRE time, not once at hook-install time: WoW hooks
-- can't be removed once added, so a single permanent HookScript has to
-- re-check the setting on every fire to honour a later change.
local function ShouldHideBlizzard()
    local p = SquizzFrames.db and SquizzFrames.db.profile
    local v = p and p.general and p.general.hideBlizzardFrames
    if v == nil then return true end -- matches the DB default (Appearance_Defaults.lua)
    return v ~= false
end

-- Party and raid frames are drawn unconditionally -- there is no "enable
-- party frames" setting to fall back on, they are the addon -- so for these
-- two the master switch IS the whole answer.
local function ShouldHideParty()
    return ShouldHideBlizzard()
end

local function ShouldHideRaid()
    return ShouldHideBlizzard()
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

-- Blizzard's standalone unit frames, hidden only while OUR UnitFrames module
-- is enabled AND the master switch is on AND the matching frame of ours is
-- itself enabled (that last check is in HideBlizzardUnitFrames' loop).
--
-- Reversible reparent-hide, exactly like the party/raid path above -- never
-- UnregisterAllEvents, which is what made the old Hide Party/Raid checkbox a
-- one-way trip (see the hideblizzard-toggle-bugfix history).
--
-- PetFrame is not in this list, but not because it is exempt any more --
-- it needs the extra rescue step in HideBlizzardPetFrame below, which this
-- plain loop has no room for.
local BLIZZARD_UNIT_FRAMES = {
    player = "PlayerFrame",
    target = "TargetFrame",
    focus  = "FocusFrame",
    -- TargetFrameToT/FocusFrameToT are CHILDREN of the two frames above, so
    -- they disappear with their parent -- listing them separately would
    -- reparent them out from under a frame that may not be hidden.
}

local function ShouldHideBlizzardUnitFrames()
    if not ShouldHideBlizzard() then return false end
    local p = SquizzFrames.db and SquizzFrames.db.profile
    local uf = p and p.unitFrames
    return (uf and uf.enabled == true) or false
end

-- Blizzard's PLAYER cast bar. Gated on the master switch AND on our own
-- player cast bar being enabled -- hiding Blizzard's while we draw nothing in
-- its place would leave you with no cast bar at all, which is exactly the
-- fallback rule the master switch relies on to be safe.
--
-- PlayerCastingBarFrame is the modern global; CastingBarFrame is the legacy
-- name kept as an alias on some builds. Both are reparent-hidden if present,
-- and hiding one that is already the same object is harmless.
--
-- PetCastingBarFrame is deliberately NOT touched: nothing in this addon draws
-- a replacement for it yet, so hiding it would just lose information.
--
-- Boss frames are not in this table either -- they share one settings entry
-- rather than having one each, so they get their own block below.
local BLIZZARD_CASTBARS = {"PlayerCastingBarFrame", "CastingBarFrame"}

function SquizzFrames:HideBlizzardCastBar()
    if DeferIfInCombat("castbar") then return end
    local p = SquizzFrames.db and SquizzFrames.db.profile
    local uf = p and p.unitFrames
    local playerCast = uf and uf.frames and uf.frames.player and uf.frames.player.castBar
    local hide = ShouldHideBlizzard() and uf and uf.enabled == true
        and playerCast and playerCast.enabled == true

    local seen = {}
    for _, name in ipairs(BLIZZARD_CASTBARS) do
        local frame = _G[name]
        if frame and not seen[frame] then
            seen[frame] = true
            if hide then HideFrame(frame) else ShowFrame(frame) end
        end
    end
end

function SquizzFrames:HideBlizzardUnitFrames()
    if DeferIfInCombat("unitframes") then return end
    local hide = ShouldHideBlizzardUnitFrames()
    local p = SquizzFrames.db and SquizzFrames.db.profile
    local uf = p and p.unitFrames
    for unit, globalName in pairs(BLIZZARD_UNIT_FRAMES) do
        local frame = _G[globalName]
        if frame then
            -- Per-frame: hiding Blizzard's target frame while OUR target frame
            -- is switched off would leave that unit with no frame at all.
            local ours = hide and uf and uf.frames and uf.frames[unit]
            if ours and ours.enabled ~= false then
                HideFrame(frame)
            else
                ShowFrame(frame)
            end
        end
    end

    -- Boss frames, handled separately because their settings do NOT live in
    -- uf.frames -- all five share the single uf.boss table (see
    -- UnitFrames_Defaults.lua), so the loop above cannot reach them.
    local bossOn = hide and uf and uf.boss and uf.boss.enabled == true

    -- Modern retail groups all five under one container, so hiding it covers
    -- the lot; the individual globals are the fallback for a build that has
    -- no container. Doing BOTH would reparent the children out from under a
    -- container that is itself hidden, which the show path then cannot undo
    -- cleanly -- hence the either/or.
    local container = _G["BossTargetFrameContainer"]
    if container then
        if bossOn then HideFrame(container) else ShowFrame(container) end
    else
        for i = 1, (_G.MAX_BOSS_FRAMES or 5) do
            local bf = _G["Boss" .. i .. "TargetFrame"]
            if bf then
                if bossOn then HideFrame(bf) else ShowFrame(bf) end
            end
        end
    end
end

-- Blizzard's pet frame, gated on the master switch AND on the PetFrames
-- module's standalone player's-own-pet frame being enabled.
--
-- This one needs a step the others don't. PetFrame is a DESCENDANT of
-- PlayerFrame on modern retail (via PlayerFrame's bottom managed-frames
-- container), so reparent-hiding PlayerFrame takes the pet frame down with
-- it whether we meant to or not -- which would break the fallback promise
-- for anyone who turns our player frame on but leaves our pet frame off.
--
-- So when we want to KEEP Blizzard's pet frame while hiding PlayerFrame, we
-- rescue it out to UIParent first. Its anchor points are untouched by
-- SetParent and PlayerFrame keeps its own position while hidden (it is
-- reparented, not moved), so the rescued frame renders in exactly the place
-- it always did. Restoring puts it back under its recorded original parent.
--
-- PetCastingBarFrame is still deliberately untouched -- nothing in this addon
-- draws a replacement for it, so hiding it would only lose information.
local function PlayerPetFrameEnabled()
    local p = SquizzFrames.db and SquizzFrames.db.profile
    local pf = p and p.petFrames and p.petFrames.player
    return (pf and pf.enabled) == true
end

function SquizzFrames:HideBlizzardPetFrame()
    if DeferIfInCombat("pet") then return end
    local frame = _G["PetFrame"]
    if not frame then return end

    if ShouldHideBlizzard() and PlayerPetFrameEnabled() then
        HideFrame(frame)
        return
    end

    -- Keeping it. Does it need rescuing out from under a PlayerFrame we are
    -- about to hide (or have already hidden)?
    local p = SquizzFrames.db and SquizzFrames.db.profile
    local uf = p and p.unitFrames
    local ourPlayer = uf and uf.frames and uf.frames.player
    local playerHidden = ShouldHideBlizzardUnitFrames()
        and ourPlayer and ourPlayer.enabled ~= false

    -- Never Show() a frame we didn't hide. PetFrame is under a unit watch, so
    -- Blizzard alone decides whether it belongs on screen -- forcing it
    -- visible would put an empty pet frame up for anyone with no pet, until
    -- the watch next corrected us. _sfOriginalParent is only ever set by us,
    -- so its presence is the record of "we touched this".
    local touchedByUs = frame._sfOriginalParent ~= nil

    if playerHidden then
        if InCombatLockdown() then return end
        local hiddenByUs = frame:GetParent() == hiddenParent
        if not touchedByUs then
            frame._sfOriginalParent = frame:GetParent() or UIParent
        end
        if frame:GetParent() ~= UIParent then
            frame:SetParent(UIParent)
        end
        if hiddenByUs then frame:Show() end
    elseif touchedByUs then
        ShowFrame(frame)
    end
end

function SquizzFrames:HideBlizzard()
    SquizzFrames:HideBlizzardParty()
    SquizzFrames:HideBlizzardRaid()
    SquizzFrames:HideBlizzardUnitFrames()
    SquizzFrames:HideBlizzardCastBar()
    -- AFTER HideBlizzardUnitFrames: the rescue branch above reads whether
    -- PlayerFrame is being hidden, so it has to run once that is settled.
    SquizzFrames:HideBlizzardPetFrame()
end

-- Re-apply on group-type and profile changes (bug fix 2026-08-07). Nothing
-- in this file listened for either before, so:
--   * Joining a raid left Blizzard's raid frames visible -- the only
--     unconditional call is Core.lua's OnEnable+0.5s pass, which typically
--     runs while solo (before Blizzard_CompactRaidFrames has even loaded,
--     which is also why the hook-install latch above had to be fixed).
--   * Switching to a profile with a different hideBlizzardFrames value did
--     nothing until a /reload.
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
-- With one master switch, "which Blizzard frame should be visible" is now a
-- question about OUR settings, so anything that changes them has to re-ask
-- it. Owning that here rather than at each options panel keeps the answer in
-- one place -- the panels previously called HideBlizzardUnitFrames and
-- HideBlizzardCastBar by hand and would have needed a third call for pets.
messageOwner:RegisterMessage("UnitFramesChanged", function()
    if SquizzFrames.HideBlizzard then SquizzFrames:HideBlizzard() end
end)
messageOwner:RegisterMessage("PetFramesChanged", function()
    if SquizzFrames.HideBlizzard then SquizzFrames:HideBlizzard() end
end)
