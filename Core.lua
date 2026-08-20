--[[ SquizzFrames Core.lua - Addon Bootstrap ]]

-- WoW 12.x API compat
local GetAddOnMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
local LibStub = LibStub

local addonName = "SquizzFrames"

-- Create addon object
local SquizzFrames = LibStub("AceAddon-3.0"):NewAddon(addonName, "AceEvent-3.0", "AceTimer-3.0", "AceHook-3.0", "AceComm-3.0", "AceConsole-3.0")
_G["SquizzFrames"] = SquizzFrames

-- Expose namespace tables
SquizzFrames.frames = {}
SquizzFrames.vars = {}
SquizzFrames.modules = {}
SquizzFrames.funcs = {}
SquizzFrames.F = SquizzFrames.funcs
local rawL = LibStub("AceLocale-3.0"):GetLocale(addonName, true) or {}
SquizzFrames.L = setmetatable(rawL, {__index = function(_, k) return k end})

-- Local references (these point to the same table as the namespace entries)
local F = SquizzFrames.funcs
local L = SquizzFrames.L

-- Runtime state
local inCombat = false
local enteringWorld = false

-- Module registration
function SquizzFrames:RegisterModule(name, module)
    self.modules[name] = module
    if module.SetParent then
        module:SetParent(self)
    end
end

-- Append any built-in indicator present in defaults but missing from an
-- already-populated profile's indicators array -- e.g. a newly added
-- built-in shipped in a later addon version. AceDB's default merging only
-- fills in missing KEYS; it never appends missing entries into an array
-- that already exists, so an existing profile's layout.indicators never
-- picks up new built-ins on its own.
--
-- CRITICAL: profile.layout.indicators is a SPARSE array in practice --
-- AceDB only ever writes a real table at a given slot once the user changes
-- one of THAT indicator's settings; every untouched built-in sits as a
-- literal hole until then. The previous version of this function walked it
-- with ipairs() to build a "have" set, then blindly table.insert()'d
-- missing entries (i.e. appended at "#profile.layout.indicators + 1").
-- Both ipairs() and # are explicitly undefined behavior on a table with
-- holes in Lua -- in practice this meant: if a LATER slot (e.g.
-- shieldOverlay at slot 19, added mid-development) happened to already be a
-- real table while an EARLIER slot (e.g. healthText at slot 2) was still a
-- hole, ipairs could stop short, "have" would incorrectly omit slots it
-- already had, and table.insert's blind append (using whatever border #
-- happened to land on for a holey table -- itself unpredictable) could
-- write a missing built-in's data into or near an unrelated existing slot.
-- This is very likely why a user hit Health Text's settings panel showing
-- Shield Overlay's fields after both had been touched this session.
--
-- Fix: every built-in has a permanently stable slot number in
-- indicatorIndices (Defaults/Layout_Defaults.lua). Place each one via
-- direct indexed assignment to ITS OWN slot -- never an append -- so the
-- array can never drift out of alignment regardless of which slots happen
-- to be holes at migration time.
local function MigrateMissingBuiltIns(profile, listKey)
    listKey = listKey or "indicators"
    if not profile or not profile.layout or not profile.layout[listKey] then return end
    local defaultsProfile = SquizzFrames.defaults and SquizzFrames.defaults.profile
    local defIndicators = defaultsProfile and defaultsProfile.layout and defaultsProfile.layout[listKey]
    local indicatorIndices = defaultsProfile and defaultsProfile.indicatorIndices
    if not defIndicators or not indicatorIndices then return end

    -- Build a "have" set by NAME, not by assumed slot. A profile's indicators
    -- array can drift out of alignment with indicatorIndices (e.g. a custom
    -- indicator ends up occupying the exact array position a NEW built-in was
    -- assigned, because custom indicators are appended via #list+1, which is
    -- itself undefined on a table with holes -- see FindOrCreateIndicatorSlot
    -- in Indicators.lua). Checking only "is my assumed slot nil" would then
    -- find it non-nil (occupied by that unrelated custom indicator) and
    -- silently skip adding the new built-in entirely -- confirmed via a real
    -- user's SavedVariables: "targetHighlight" never appeared anywhere in
    -- their profile after this indicator shipped, despite slot 21 legitimately
    -- being taken by one of their own custom indicators.
    -- pairs() (not ipairs()) is required here too -- ipairs stops at the first
    -- hole, which would miss any indicator sitting after a gap.
    local haveByName = {}
    for _, ind in pairs(profile.layout[listKey]) do
        if type(ind) == "table" and ind.indicatorName then
            haveByName[ind.indicatorName] = true
        end
    end

    for _, defInd in ipairs(defIndicators) do
        local name = defInd.indicatorName
        local slot = name and indicatorIndices[name]
        if name and slot and not haveByName[name] then
            local copy = F.CopyTable and F.CopyTable(defInd) or defInd
            local existing = profile.layout[listKey][slot]
            if not existing then
                profile.layout[listKey][slot] = copy
                print("|cff33cc99[SquizzFrames]|r Migration: added missing built-in indicator '" .. name .. "' at slot " .. slot .. " (" .. listKey .. ")")
            else
                -- Assumed slot is occupied by something else entirely (drifted
                -- array) -- append rather than clobbering whatever's actually
                -- there.
                table.insert(profile.layout[listKey], copy)
                print("|cff33cc99[SquizzFrames]|r Migration: added missing built-in indicator '" .. name .. "' (slot " .. slot .. " occupied, appended instead, " .. listKey .. ")")
            end
        end
    end

    -- Merge any new indicatorIndices keys too (bookkeeping only).
    if profile.indicatorIndices then
        for k, v in pairs(indicatorIndices) do
            if profile.indicatorIndices[k] == nil then
                profile.indicatorIndices[k] = v
            end
        end
    end
end

-- One-time correction: the shipped default for accentColor used to be a
-- hardcoded blue custom_color ({"custom_color", 0, 0.48, 0.65, 1}) instead of
-- class_color, so every profile created before that default was fixed is
-- sitting on that stale blue value. Only overwrite it when it still matches
-- that exact old default byte-for-byte -- if the value differs at all, the
-- user picked a custom color on purpose and it must be left alone.
local function MigrateAccentColorDefault(profile)
    local ac = profile and profile.appearance and profile.appearance.general and profile.appearance.general.accentColor
    if not ac then return end
    if ac[1] == "custom_color" and ac[2] == 0 and ac[3] == 0.48 and ac[4] == 0.65 then
        profile.appearance.general.accentColor = {"class_color"}
        print("|cff33cc99[SquizzFrames]|r Migration: accentColor was still on the old blue default, switched to class_color")
    end
end

-- One-time correction: Dispels was rebuilt from a manual aura scan (icon
-- grid: filters/highlightType/iconStyle/orientation/size/position) onto
-- AuraEngine (per-dispel-type AuraContainer overlay: dispelShowAll/
-- dispelTypeColors/dispelOverlay/etc), then again from 5 independently
-- fixed-corner icons (dispelIconSize/dispelIconPosition/dispelIconOffsetX/Y)
-- onto a single shared, draggable icon using the ordinary size/position
-- fields. None of these shapes share enough to merge cleanly, so an existing
-- profile's "dispels" entry needs replacing wholesale -- detected by either
-- missing dispelShowAll (pre-AuraEngine shape) or carrying the old
-- per-icon-corner fields without the current size/position pair
-- (intermediate AuraEngine shape). Only the user's enabled/disabled choice
-- is preserved.
local function MigrateDispelsShape(profile, listKey)
    listKey = listKey or "indicators"
    if not profile or not profile.layout or not profile.layout[listKey] then return end
    local defIndicators = SquizzFrames.defaults and SquizzFrames.defaults.profile
        and SquizzFrames.defaults.profile.layout and SquizzFrames.defaults.profile.layout[listKey]
    if not defIndicators then return end

    local defDispels
    for _, defInd in ipairs(defIndicators) do
        if defInd.indicatorName == "dispels" then defDispels = defInd; break end
    end
    if not defDispels then return end

    for i, ind in ipairs(profile.layout[listKey]) do
        if ind.indicatorName == "dispels"
            and (ind.dispelShowAll == nil or (ind.dispelIconSize ~= nil and ind.position == nil)) then
            local wasEnabled = ind.enabled
            local copy = F.CopyTable and F.CopyTable(defDispels) or defDispels
            if wasEnabled ~= nil then copy.enabled = wasEnabled end
            profile.layout[listKey][i] = copy
            print("|cff33cc99[SquizzFrames]|r Migration: rebuilt 'Dispels' indicator on the new AuraEngine format (" .. listKey .. ")")
            break
        end
    end
end

-- One-time correction: Aggro (blink) was rebuilt from an 11x11 icon-sized
-- frame (position/size, wrapped in LibCustomGlow's PixelGlow marching-pixel
-- effect) into a full-button pulsing red border matching aggroBorder's own
-- shape (no position/size, just optional thickness) -- an existing
-- profile's old position/size fields would otherwise conflict with the
-- border's own fixed 4-edge anchoring the next time the generic
-- position-apply path runs. Detected by the old shape's hallmark
-- (position field present); only enabled/frameLevel are preserved.
-- Drop the Private Auras indicator from existing profiles (removed 2026-08-13).
--
-- Boss private auras are rendered by the 12.1 AuraContainer engine itself
-- (AuraContainerPrivateMixin / C_UnitAurasPrivate), so the standalone
-- AddPrivateAuraAnchor indicator is redundant on this client. Its module,
-- defaults and settings are gone.
--
-- Saved profiles keep whatever array they were written with, so without this
-- the stale entry would linger: I.CreateIndicator returns nil for it (nothing
-- claims the name any more) and the settings panel would list a row with no
-- display name and no settings behind it.
local function MigrateRemovedPrivateAuras(profile, listKey)
    listKey = listKey or "indicators"
    if not profile or not profile.layout or not profile.layout[listKey] then return end
    local list = profile.layout[listKey]
    for i = #list, 1, -1 do
        if list[i] and list[i].indicatorName == "privateAuras" then
            table.remove(list, i)
        end
    end
    if profile.indicatorIndices then
        profile.indicatorIndices.privateAuras = nil
    end
end

-- Carry the old Dispels icon settings onto the new Dispel Icons indicator
-- (split 2026-08-13).
--
-- MigrateMissingBuiltIns adds the new entry from defaults, but a fresh default
-- would silently discard the placement and on/off state the user already had:
-- the overlay indicator used to own `showDispelIcons` plus a size/position that
-- existed ONLY to place its single dispel symbol. Those map one-to-one onto the
-- new indicator, so hand them over and then drop them from the overlay, which
-- has no geometry of its own any more.
--
-- Keyed off the old fields still being present, so this runs exactly once.
local function MigrateDispelIconsSplit(profile, listKey)
    listKey = listKey or "indicators"
    if not profile or not profile.layout or not profile.layout[listKey] then return end
    local list = profile.layout[listKey]

    local old, new
    for _, ind in ipairs(list) do
        if ind.indicatorName == "dispels" then old = ind
        elseif ind.indicatorName == "dispelIcons" then new = ind end
    end
    if not old then return end
    -- Nothing left to hand over -- already migrated.
    if old.showDispelIcons == nil and old.size == nil and old.position == nil then return end

    if new then
        if old.showDispelIcons ~= nil then new.enabled = old.showDispelIcons end
        if old.size then new.size = F.CopyTable(old.size) end
        if old.position then new.position = F.CopyTable(old.position) end
        if old.dispelShowAll ~= nil then new.dispelShowAll = old.dispelShowAll end
    end

    old.showDispelIcons = nil
    old.size = nil
    old.position = nil
end

local function MigrateAggroBlinkShape(profile, listKey)
    listKey = listKey or "indicators"
    if not profile or not profile.layout or not profile.layout[listKey] then return end
    local defIndicators = SquizzFrames.defaults and SquizzFrames.defaults.profile
        and SquizzFrames.defaults.profile.layout and SquizzFrames.defaults.profile.layout[listKey]
    if not defIndicators then return end

    local defBlink
    for _, defInd in ipairs(defIndicators) do
        if defInd.indicatorName == "aggroBlink" then defBlink = defInd; break end
    end
    if not defBlink then return end

    for i, ind in ipairs(profile.layout[listKey]) do
        if ind.indicatorName == "aggroBlink" and ind.position ~= nil then
            local wasEnabled = ind.enabled
            local copy = F.CopyTable and F.CopyTable(defBlink) or defBlink
            if wasEnabled ~= nil then copy.enabled = wasEnabled end
            profile.layout[listKey][i] = copy
            print("|cff33cc99[SquizzFrames]|r Migration: rebuilt 'Aggro (blink)' indicator as a full-button border (" .. listKey .. ")")
            break
        end
    end
end

-- Backfills profile.petFrames.main/.raid for profiles saved before pet
-- frames existed -- same missing-subtable pattern as profile.layout.raid's
-- own backfill (see the OnInitialize/RefreshProfile call sites below), and
-- the same shared-function reasoning as EnsureIndicatorLists just below.
local function EnsurePetFramesDefaults(profile)
    if not profile.petFrames then
        profile.petFrames = SquizzFrames.defaults.profile.petFrames
            and F.CopyTable(SquizzFrames.defaults.profile.petFrames) or {}
        return
    end
    if not profile.petFrames.main then
        profile.petFrames.main = SquizzFrames.defaults.profile.petFrames
            and SquizzFrames.defaults.profile.petFrames.main
            and F.CopyTable(SquizzFrames.defaults.profile.petFrames.main) or {}
    end
    if not profile.petFrames.raid then
        profile.petFrames.raid = SquizzFrames.defaults.profile.petFrames
            and SquizzFrames.defaults.profile.petFrames.raid
            and F.CopyTable(SquizzFrames.defaults.profile.petFrames.raid) or {}
    end
    -- profile.appearance.petHealthBar (2026-08-05): profile.appearance
    -- itself has existed since before pet frames and is never wholesale-
    -- backfilled (AceDB's own default-table fallback provides it at
    -- profile-creation time), so a NEW nested key added to it needs the
    -- same explicit backfill treatment as every other addition in this
    -- function -- without it, an existing user's profile.appearance table
    -- is real but missing .petHealthBar, and the options page's setters
    -- guard on that table existing before writing, so the Pet Health Bar
    -- Color controls would silently no-op instead of erroring.
    if profile.appearance and not profile.appearance.petHealthBar then
        profile.appearance.petHealthBar = SquizzFrames.defaults.profile.appearance
            and SquizzFrames.defaults.profile.appearance.petHealthBar
            and F.CopyTable(SquizzFrames.defaults.profile.appearance.petHealthBar) or {}
    end
end

-- Ensures both profile.layout.indicators (Party) and profile.layout
-- .indicatorsRaid (Raid) exist, are structurally sound, and have every
-- built-in/one-time-shape migration applied -- the single shared entry point
-- both OnInitialize and RefreshProfile call, since the two used to run this
-- exact sequence independently and byte-for-byte identically (now doubly
-- true with a second list to keep in sync -- one shared function is much
-- safer to get right than four duplicated call sites).
local function EnsureIndicatorLists(profile)
    if not profile.layout.indicators then
        profile.layout.indicators = SquizzFrames.defaults.profile.layout
            and F.CopyTable(SquizzFrames.defaults.profile.layout.indicators) or {}
    end
    if not profile.layout.indicatorsRaid then
        -- Prefer cloning the user's OWN (possibly already-customized) party
        -- list over the stock raid defaults -- an existing profile upgrading
        -- into this feature should see Raid start out looking exactly like
        -- Party already does, not silently reset to a generic default the
        -- first time this key appears. A brand-new profile has nothing to
        -- clone yet, so it falls back to the stock raid defaults instead
        -- (functionally identical to Party's own defaults at that point).
        if #profile.layout.indicators > 0 then
            profile.layout.indicatorsRaid = F.CopyTable(profile.layout.indicators)
        else
            profile.layout.indicatorsRaid = SquizzFrames.defaults.profile.layout
                and F.CopyTable(SquizzFrames.defaults.profile.layout.indicatorsRaid) or {}
        end
    end
    if not profile.indicatorIndices then
        profile.indicatorIndices = SquizzFrames.defaults.profile.indicatorIndices
            and F.CopyTable(SquizzFrames.defaults.profile.indicatorIndices) or {}
    end

    for _, listKey in ipairs({"indicators", "indicatorsRaid"}) do
        -- Fix: if indicators exist but have wrong structure (missing
        -- indicatorName), rebuild from defaults. Handles old saved variable
        -- formats.
        local indicators = profile.layout[listKey]
        local needsRebuild = false
        if indicators and #indicators > 0 then
            for _, ind in ipairs(indicators) do
                if not ind.indicatorName or not ind.name or not ind.type then
                    needsRebuild = true
                    break
                end
            end
        end
        if needsRebuild then
            local defList = SquizzFrames.defaults.profile.layout and SquizzFrames.defaults.profile.layout[listKey]
            profile.layout[listKey] = defList and F.CopyTable(defList) or {}
        end

        MigrateMissingBuiltIns(profile, listKey)
        MigrateDispelsShape(profile, listKey)
        MigrateAggroBlinkShape(profile, listKey)
        MigrateRemovedPrivateAuras(profile, listKey)
        -- AFTER MigrateMissingBuiltIns above, which is what actually creates
        -- the new dispelIcons entry for an existing profile -- this only moves
        -- the old settings onto it.
        MigrateDispelIconsSplit(profile, listKey)
    end
    MigrateAccentColorDefault(profile)
end

-- Print with addon prefix
function SquizzFrames:Print(msg)
    print("|cff33cc99[SquizzFrames]|r " .. tostring(msg))
end

-- Callback dispatch: send a message over AceEvent's message bus.
-- AceEvent uses a single global CallbackHandler for all embed targets, keyed by
-- the owner table passed as `self` to RegisterMessage. So every module must
-- register on ITSELF (self:RegisterMessage) rather than on the addon root —
-- otherwise two modules registering the same message would collide (same
-- `self` = SquizzFrames, second overwrites the first).
-- A single SendMessage here reaches every handler regardless of which object it
-- was registered on, so no per-module broadcast loop is needed.
function SquizzFrames:Fire(event, ...)
    self:SendMessage(event, ...)
end

-- Get current group type: "solo", "party", "raid"
local function GetGroupType()
    if IsInRaid() then
        return "raid"
    elseif IsInGroup() then
        return "party"
    else
        return "solo"
    end
end

-- Get current spec ID (globally unique, e.g. 257 for Holy Priest -- NOT the
-- local 1-4 slot, which collides across classes and is useless as the
-- db.autoSwitch.map key below).
--
-- Delegates to Utils.lua's F.GetPlayerSpecID, which owns the
-- C_SpecializationInfo compat: the bare GetSpecialization/
-- GetSpecializationInfo globals are gone on 12.1, and because the guard
-- here was existence-checked rather than version-checked, their removal
-- silently pinned this to 0 and switched auto-switching off without an
-- error. Resolved at CALL time, not load time -- Core.lua loads before
-- Utils.lua, but nothing calls this until PLAYER_ENTERING_WORLD.
local function GetCurrentSpec()
    local F = SquizzFrames.F
    return (F and F.GetPlayerSpecID and F.GetPlayerSpecID()) or 0
end

-- Spec x situation profile auto-switching (2026-08-06, replaces the old
-- spec-only AceDB-backed version): db.autoSwitch.map[specID] = {solo=,
-- party=, raid=} maps a globally-unique specID + current situation
-- ("solo"/"party"/"raid", same values GetGroupType() already returns) to a
-- profile name. Lives in the account-wide SavedVariable (ProfileStore.lua),
-- NOT inside profile.* -- the mapping has to survive the very SetProfile
-- call it's driving. Opt-in via db.autoSwitch.enabled (OptionsFrame.lua's
-- Profiles page).
--
-- Fires "SpecProfileNeeded" (rather than showing a dialog here) when the
-- current spec+situation has no mapping yet or its mapped profile was
-- deleted -- Core.lua stays UI-agnostic; OptionsFrame.lua listens and
-- prompts the user to pick or create the profile for that spec+situation,
-- per explicit user request ("ask me each time") rather than silently
-- auto-creating one. This preserves that exact UX from before, just with a
-- situation dimension added.
local function HandleSpecProfileSwitch(specID, situation)
    local db = SquizzFrames.db
    if not db or not db.autoSwitch or not db.autoSwitch.enabled then return end
    if not specID or specID == 0 or not situation then return end

    local situations = db.autoSwitch.map[specID]
    local mapped = situations and situations[situation]
    if mapped then
        local exists = false
        for _, name in ipairs(db:GetProfiles()) do
            if name == mapped then exists = true; break end
        end
        if exists then
            if db:GetCurrentProfile() ~= mapped then
                -- isAutomatic=true: don't overwrite the character's manual
                -- profile choice, and don't silently discard unsaved draft
                -- edits -- see DB:SetProfile in ProfileStore.lua.
                db:SetProfile(mapped, true)
            end
            return
        end
        -- Mapped profile was deleted since -- forget the stale mapping and
        -- fall through to asking again below.
        situations[situation] = nil
    end

    -- F.GetSpecName owns the by-specID lookup compat -- GetSpecializationInfoByID
    -- is gone on 12.1, replaced by a differently-named plain global.
    local F = SquizzFrames.F
    local specName = F and F.GetSpecName and F.GetSpecName(specID)
    SquizzFrames:Fire("SpecProfileNeeded", specID, specName, situation)
end

-- Update group type and fire callback if changed. Now ALSO drives auto-
-- switch (2026-08-06) -- the situation axis needs group-composition
-- changes to re-evaluate the mapping, not just spec changes, or it would
-- never actually do anything. Previously only UpdateSpec called
-- HandleSpecProfileSwitch.
-- skipAutoSwitch: resolve + broadcast the change, but DON'T evaluate the
-- spec x situation auto-switch. Used by RefreshSituation below, which needs
-- both values settled before evaluating -- see its comment.
local function UpdateGroupType(force, skipAutoSwitch)
    local current = SquizzFrames.vars.groupType or "none"
    local new = GetGroupType()
    if force or current ~= new then
        SquizzFrames.vars.groupType = new
        SquizzFrames:Fire("GroupTypeChanged", new)
        if not skipAutoSwitch then
            HandleSpecProfileSwitch(SquizzFrames.vars.playerSpecID, new)
        end
    end
end

-- Update spec and fire callback if changed
local function UpdateSpec(force, skipAutoSwitch)
    local current = SquizzFrames.vars.playerSpecID or 0
    local new = GetCurrentSpec()
    if force or current ~= new then
        SquizzFrames.vars.playerSpecID = new
        SquizzFrames:Fire("SpecChanged", new)
        if not skipAutoSwitch then
            HandleSpecProfileSwitch(new, SquizzFrames.vars.groupType)
        end
    end
end

-- Resolve spec AND group type, then evaluate auto-switch exactly once with
-- both settled (2026-08-07).
--
-- Auto-switch keys on the PAIR (spec, situation), so evaluating it while
-- either half is still at its startup placeholder looks up a mapping that
-- can't exist and wrongly reports "this spec/situation has no profile":
--   * group type before spec -> playerSpecID is still 0, so
--     HandleSpecProfileSwitch early-returns and the first evaluation is a
--     silent no-op.
--   * spec before group type -> groupType is still "none", so the lookup
--     misses and it fires "SpecProfileNeeded", popping the pick-a-profile
--     dialog on every login (and, if the user confirms, switching profiles
--     mid-frame-setup).
-- Neither order is correct on its own, which is why this exists.
local function RefreshSituation(force)
    UpdateSpec(force, true)
    UpdateGroupType(force, true)
    HandleSpecProfileSwitch(SquizzFrames.vars.playerSpecID, SquizzFrames.vars.groupType)
end

-- Enable all registered modules
local function EnableAllModules()
    for name, module in pairs(SquizzFrames.modules) do
        if module.Enable then
            local ok, err = pcall(module.Enable, module)
            if not ok then
                SquizzFrames:Print("Error enabling " .. name .. ": " .. tostring(err))
            end
        end
    end
end

-----------------------------------------------------------------------
-- Ace3 lifecycle: OnInitialize fires at ADDON_LOADED
-----------------------------------------------------------------------
function SquizzFrames:OnInitialize()
    -- Ensure defaults exist even if Defaults files didn't run
    self.defaults = self.defaults or { profile = {} }
    if not self.defaults.profile.general then
        self.defaults.profile.general = {
            hideBlizzardParty = true,
            hideBlizzardRaid = true,
            locked = false,
            fadeOut = true,
        }
    end
    if not self.defaults.profile.layout then
        self.defaults.profile.layout = {
            main = {
                width = 100, height = 40, powerHeight = 4,
                orientation = "vertical",  -- "vertical" or "horizontal"
                growthDirection = "DOWN",  -- "DOWN"/"UP" for vertical, "RIGHT"/"LEFT" for horizontal
                anchorX = 0, anchorY = -200,  -- CENTER→CENTER offset from UIParent center
                hideSelf = false, spacingY = 0,
            },
            raid = {
                width = 70, height = 24, powerHeight = 3,
                orientation = "vertical", growthDirection = "DOWN",
                anchorX = 0, anchorY = 200,
                hideSelf = false, spacingY = 0, groupSpacing = 6,
            },
        }
    end
    if not self.defaults.profile.appearance then
        self.defaults.profile.appearance = {
            general = { scale = 1.0, strata = "MEDIUM", texture = "Blizzard", outOfRangeAlpha = 0.3 },
            healthBar = {},
            powerBar = {},
            text = {},
        }
    end

    -- Initialize the profile store (ProfileStore.lua -- replaces AceDB-3.0
    -- entirely, 2026-08-06). Handles migration from the old AceDB-shaped
    -- SavedVariables, per-character profile resolution/creation, and the
    -- one-time seed-from-Default logic internally -- see that file for the
    -- full writeup. No 3rd-argument/forced-shared-profile equivalent here
    -- either: every brand-new character gets their own profile from the
    -- very first login, same reasoning as before (shared profiles meant
    -- click-casting bindings set up on one character silently applied to a
    -- totally different one the moment it logged in).
    self.db = SquizzFrames.ProfileStore:Init()

    -- Ensure layout.indicators/indicatorsRaid exist in the loaded profile
    -- (migrates old profiles) -- see EnsureIndicatorLists' comment.
    if self.db and self.db.profile then
        if not self.db.profile.layout then
            self.db.profile.layout = self.defaults.profile.layout and F.CopyTable(self.defaults.profile.layout) or {}
        end
        -- Backfill raid layout for profiles saved before raid support existed
        -- -- same missing-subtable pattern as the indicator lists below.
        if not self.db.profile.layout.raid then
            self.db.profile.layout.raid = self.defaults.profile.layout and self.defaults.profile.layout.raid
                and F.CopyTable(self.defaults.profile.layout.raid) or {}
        end
        EnsurePetFramesDefaults(self.db.profile)
        EnsureIndicatorLists(self.db.profile)
    end

    -- No profile-changed callback registration needed here anymore --
    -- ProfileStore.lua's SetProfile/CopyProfile/RenameProfile/ResetProfile
    -- all call SquizzFrames:RefreshProfile() directly at the end of each
    -- guarded action, same net effect as the old AceDB RegisterCallback
    -- trio without the callback-registry indirection.

    -- Healer preset: enable and configure key healer indicators
    -- Applies the preset to one indicator list (Party or Raid) -- called
    -- once per list below so /sf healer configures both frame types the
    -- same way in one shot, rather than leaving Raid on whatever it had
    -- before (a healer cares about raid frame indicators at least as much
    -- as party's).
    local function ApplyHealerPresetTo(indicators)
        if not indicators then return end

        -- Helper to find indicator by name
        local function FindInd(name)
            for _, ind in ipairs(indicators) do
                if ind.indicatorName == name then return ind end
            end
        end

        -- Enable and configure key healer indicators
        local nameText = FindInd("nameText")
        if nameText then nameText.enabled = true end

        local healthText = FindInd("healthText")
        if healthText then
            healthText.enabled = true
            healthText.color = {"class_color"}
            healthText.showPercentage = true
            healthText.showCurrent = false
            healthText.showMax = false
        end

        local powerText = FindInd("powerText")
        if powerText then
            powerText.enabled = true
            powerText.color = {"power_color"}
            powerText.showPercentage = true
            powerText.showCurrent = false
            powerText.showMax = false
        end

        local externalCooldowns = FindInd("externalCooldowns")
        if externalCooldowns then
            externalCooldowns.enabled = true
            externalCooldowns.builtInExternals = true
            externalCooldowns.num = 3
            externalCooldowns.size = {14, 22}
            externalCooldowns.position = {"RIGHT", "button", "RIGHT", 4, 5}
        end

        local defensiveCooldowns = FindInd("defensiveCooldowns")
        if defensiveCooldowns then
            defensiveCooldowns.enabled = true
            defensiveCooldowns.builtInDefensives = true
            defensiveCooldowns.num = 3
            defensiveCooldowns.size = {14, 22}
            defensiveCooldowns.position = {"LEFT", "button", "LEFT", -4, 5}
        end

        local debuffs = FindInd("debuffs")
        if debuffs then
            debuffs.enabled = true
            debuffs.dispellableByMe = true
            debuffs.num = 5
            debuffs.size = {16, 16}
            debuffs.position = {"BOTTOMLEFT", "button", "BOTTOMLEFT", 2, 4}
        end

        local ccIndicator = FindInd("ccIndicator")
        if ccIndicator then
            ccIndicator.enabled = true
            ccIndicator.num = 1
            ccIndicator.size = {26, 26}
            ccIndicator.position = {"CENTER", "button", "CENTER", 0, 4}
        end

        local dispels = FindInd("dispels")
        if dispels then
            dispels.enabled = true
            dispels.filters = {dispellableByMe = true, Curse = true, Disease = true, Magic = true, Poison = true, Bleed = true}
            dispels.size = {14, 14}
            dispels.position = {"BOTTOMRIGHT", "button", "BOTTOMRIGHT", -2, 4}
        end

        local aggroBlink = FindInd("aggroBlink")
        if aggroBlink then
            aggroBlink.enabled = true
            aggroBlink.size = {14, 14}
        end

        local shieldBar = FindInd("shieldBar")
        if shieldBar then
            shieldBar.enabled = true
            shieldBar.height = 4
            shieldBar.color = {0.2, 0.8, 1, 1}
            shieldBar.onlyShowOvershields = false
        end
    end

    local function ApplyHealerPreset()
        if not SquizzFrames.db or not SquizzFrames.db.profile then return end
        local layout = SquizzFrames.db.profile.layout
        if not layout then return end
        ApplyHealerPresetTo(layout.indicators)
        ApplyHealerPresetTo(layout.indicatorsRaid)

        -- Force update all buttons
        if SquizzFrames.Indicators then
            SquizzFrames.Indicators:ReapplyToAll()
        end
        SquizzFrames:Print("Healer preset applied. Reload UI if indicators don't update immediately.")
    end

    SquizzFrames.ApplyHealerPreset = ApplyHealerPreset

    -- Initialize runtime vars
    SquizzFrames.vars.playerName = UnitName("player")
    SquizzFrames.vars.playerClass = select(2, UnitClass("player"))
    SquizzFrames.vars.playerGUID = UnitGUID("player")
    SquizzFrames.vars.groupType = "none"
    SquizzFrames.vars.playerSpecID = 0
    SquizzFrames.locked = false
    SquizzFrames.editMode = false

    -- Register slash commands (only /sf; /squizz conflicts with Squizzumables)
    self:RegisterChatCommand("sf", F.SlashHandler or function() end)

    -- Register options
    if self.options then
        LibStub("AceConfig-3.0"):RegisterOptionsTable(addonName, self.options)
        self.optionsTable = LibStub("AceConfigDialog-3.0"):AddToBlizOptions(addonName, addonName)
    end

    -- Initial state
    SquizzFrames.vars.groupType = GetGroupType()
    SquizzFrames.vars.playerSpecID = GetCurrentSpec()

    SquizzFrames:Print(L["addon loaded"])
end

-----------------------------------------------------------------------
-- Ace3 lifecycle: OnEnable fires after OnInitialize
-----------------------------------------------------------------------
function SquizzFrames:OnEnable()
    -- Core events
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnPlayerEnteringWorld")
    self:RegisterEvent("GROUP_ROSTER_UPDATE", "OnGroupRosterUpdate")
    -- Both spec events, deliberately.
    --
    -- PLAYER_SPECIALIZATION_CHANGED carries a unitTarget payload and fires
    -- for ANY unit, including party members respeccing -- so it's noisy for
    -- our purposes, and when it does fire for the player it can arrive
    -- before the new spec has actually settled, in which case GetSpecialization
    -- still reports the old one and UpdateSpec sees no change.
    -- ACTIVE_PLAYER_SPECIALIZATION_CHANGED has no payload and means exactly
    -- "the player's own active spec changed", which is the precise trigger.
    --
    -- Registering both is harmless: UpdateSpec compares against the cached
    -- value and no-ops when nothing actually changed, so the redundant one
    -- costs a comparison. DandersFrames handles the same pair the same way.
    self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", "OnSpecChanged")
    self:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED", "OnSpecChanged")

    -- Hide Blizzard frames (deferred slightly to ensure UI is ready)
    C_Timer.After(0.5, function()
        if SquizzFrames.HideBlizzard then
            SquizzFrames:HideBlizzard()
        end
    end)

    -- Enable all modules
    EnableAllModules()

    -- Fire ready callback
    self:Fire("SquizzFrames_Ready")
end

-- Combat deferral for secure frame creation
local deferred = {}
local function QueueDuringCombat(func)
    if InCombatLockdown() then
        tinsert(deferred, func)
    else
        func()
    end
end

-- Setup combat deferral frame
local combatFrame = CreateFrame("Frame")
combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatFrame:SetScript("OnEvent", function()
    for _, func in ipairs(deferred) do
        pcall(func)
    end
    wipe(deferred)
end)

-----------------------------------------------------------------------
-- Event handlers
-----------------------------------------------------------------------
function SquizzFrames:OnPlayerEnteringWorld(isInitial, isReload)
    enteringWorld = true
    -- Both values, then ONE auto-switch evaluation -- see RefreshSituation.
    -- At login neither is known yet, so evaluating after only one of them is
    -- resolved either no-ops silently or spuriously prompts for a profile.
    RefreshSituation(true)
end

function SquizzFrames:OnGroupRosterUpdate()
    UpdateGroupType()
end

function SquizzFrames:OnSpecChanged()
    UpdateSpec()
end

-----------------------------------------------------------------------
-- Profile refresh
-----------------------------------------------------------------------
-- The old "Default profile protection" hack (a snapshot-capture-and-
-- restore-at-PLAYER_LOGOUT fake draft/commit model bolted onto AceDB) is
-- gone -- ProfileStore.lua's DB:CommitDraft()/PROTECTED table replace it
-- with a real draft (db.profile is simply never linked into the
-- SavedVariable while on a protected profile, so unsaved edits can't reach
-- disk by accident, no PLAYER_LOGOUT hook needed at all).
function SquizzFrames:RefreshProfile()
    -- Migrate layout/indicatorIndices from defaults if missing in new profile.
    if self.db and self.db.profile then
        if not self.db.profile.layout then
            self.db.profile.layout = self.defaults.profile.layout and F.CopyTable(self.defaults.profile.layout) or {}
        end
        -- Backfill raid layout for profiles saved before raid support existed
        -- -- same missing-subtable pattern as the indicator lists below.
        if not self.db.profile.layout.raid then
            self.db.profile.layout.raid = self.defaults.profile.layout and self.defaults.profile.layout.raid
                and F.CopyTable(self.defaults.profile.layout.raid) or {}
        end
        EnsurePetFramesDefaults(self.db.profile)
        EnsureIndicatorLists(self.db.profile)
    end
    self:Fire("ProfileChanged")
end

-- Open options panel
-- OptionsFrame.lua overrides this with the custom frame if loaded.
function SquizzFrames:ToggleOptions()
    if self.optionsTable then
        -- optionsTable is the AceGUIContainer-BlizOptionsGroup frame
        -- which has the .categoryID from AddToBlizOptions
        local categoryID = self.optionsTable.categoryID or self.optionsTable:GetID()
        if Settings and Settings.OpenToCategory and categoryID then
            Settings.OpenToCategory(categoryID)
        end
    end
end

-- Update frame layout (triggered by options changes)
function SquizzFrames:UpdateLayout()
    self:Fire("LayoutChanged")
end

function SquizzFrames:UpdateScale()
    self:Fire("ScaleChanged")
end
