--[[ SquizzFrames ProfileStore.lua - Custom profile storage (replaces AceDB-3.0)

    Full replacement of the AceDB-3.0 profile engine, per explicit user
    request: the old system (per-character/global/realm/class scope matrix,
    most of it unused -- db.char was declared but never read or written
    anywhere) had grown overcomplicated. Cell, DandersFrames, and
    EllesmereUI were all checked directly (their real installed source) as
    inspiration -- all three independently dropped AceDB for a small custom
    store, which this mirrors: one flat SavedVariables table, no
    char/realm/class/faction namespaces, no metatable/__index machinery.

    SquizzFrames.db.profile stays a stable, transparent path for every
    other file in the addon -- confirmed (grepped and read every access
    site) that all 13 consumer files only ever read/write via
    SquizzFrames.db.profile.X inside function bodies, never caching the
    table into a file-scope local, so none of them need to change at all.
    Every switch/copy/rename/reset/commit here just does a plain
    `db.profile = <table>` field reassignment.

    See the design plan (session history) for the full architecture
    writeup and the "Default" draft/commit reasoning below. ]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F
local addonName = "SquizzFrames"
local svName = addonName .. "DB"

local ProfileStore = {}
SquizzFrames.ProfileStore = ProfileStore

-- Computed lazily inside Init() (called from Core:OnInitialize, fired at
-- ADDON_LOADED), not here at file-parse time -- matches the exact timing
-- the original AceDB-era code used for this same formula, rather than
-- assuming UnitName("player")/GetRealmName() are safe to call this early.
ProfileStore.CHAR_KEY = nil

-- Profiles that behave as a DRAFT rather than a live reference into the
-- SavedVariable: edits apply immediately in the UI (every widget reads/
-- writes db.profile like normal), but nothing reaches disk until
-- db:CommitDraft() runs. Only "Default" was ever asked to behave this way
-- (it's the template every new character/profile seeds from, and the
-- explicit user preference from an earlier session was to keep it a
-- deliberately stable baseline, not something that drifts from casual
-- edits). Hardcoded, not user-configurable -- a generalized "any profile
-- can be protected" system was considered and cut, nobody asked for it.
ProfileStore.PROTECTED = { Default = true }

-----------------------------------------------------------------------
-- Combat-safe mutation queue. Mirrors the InCombatLockdown() + one-shot
-- PLAYER_REGEN_ENABLED retry pattern already proven in PartyFrames.lua's
-- ApplyLayout / PetFrames.lua's ApplyPetLayout -- reused here, not
-- reinvented, since a profile switch fires "ProfileChanged", which every
-- module reacts to by re-laying-out secure-templated frames. Queues a LIST
-- (not just the latest call) so multiple actions attempted back-to-back
-- during the same combat all still run once combat ends, instead of the
-- second call's SetScript silently discarding the first.
-----------------------------------------------------------------------
local pendingActions = {}
local retryFrame

local function RunPendingActions()
    local actions = pendingActions
    pendingActions = {}
    for _, fn in ipairs(actions) do
        fn()
    end
end

local function GuardedCall(fn)
    if InCombatLockdown() then
        table.insert(pendingActions, fn)
        if not retryFrame then
            retryFrame = CreateFrame("Frame")
            retryFrame:SetScript("OnEvent", function(self)
                self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                RunPendingActions()
            end)
        end
        retryFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    fn()
end

-----------------------------------------------------------------------
-- Migration from the old AceDB-3.0 shape (one-time, idempotent)
-----------------------------------------------------------------------

-- Converts an AceDB-3.0-shaped SquizzFramesDB in place into the new
-- schema. Profile CONTENTS need no conversion at all (same sv.profiles
-- [name] = {...} shape AceDB itself used) -- only the container and the
-- spec-switch mapping (which gains a new situation dimension) change.
-- Idempotent via schemaVersion; safe to call on every login.
function ProfileStore:MigrateFromAceDB(sv)
    if sv.schemaVersion == 2 then return end

    local looksLikeOldAceDB = sv.profiles ~= nil or sv.profileKeys ~= nil or sv.global ~= nil
    if not looksLikeOldAceDB then
        sv.schemaVersion = 2
        return -- brand-new install, nothing to convert
    end

    -- Version FIRST, destroy old keys LAST (2026-08-07 data-loss fix).
    -- This used to nil sv.profileKeys near the top but only set
    -- schemaVersion at the very end, so ANY error in between left the SV
    -- un-versioned with profileKeys already gone. The next login would
    -- re-run migration, `sv.charProfileKeys = sv.profileKeys or {}` would
    -- now yield {}, and every character would silently land on a fresh
    -- profile with their real one orphaned. Stamping the version up front
    -- means a partial run can never destroy the character->profile mapping;
    -- worst case some cleanup is skipped, which is recoverable.
    sv.schemaVersion = 2

    sv.profiles = sv.profiles or {}

    sv.charProfileKeys = sv.profileKeys or {}
    sv.profileKeys = nil

    local oldGlobal = sv.global or {}
    local newMap = {}
    for specID, profileName in pairs(oldGlobal.specProfiles or {}) do
        -- Default the NEW situation dimension to whatever was mapped for
        -- every situation before -- no regression for existing users who
        -- already had spec auto-switch configured.
        newMap[specID] = { solo = profileName, party = profileName, raid = profileName }
    end
    sv.autoSwitch = { enabled = oldGlobal.specProfileSwitchingEnabled or false, map = newMap }
    sv.global = nil

    sv.perCharSeedDone = sv.perCharProfileSplit or {}
    sv.perCharProfileSplit = nil

    -- AceDB internal bookkeeping, meaningless without AceDB.
    sv.keys = nil
    sv.namespaces = nil

    SquizzFrames:Print("Migrated profile data to the new format.")
end

-----------------------------------------------------------------------
-- Active-profile application
-----------------------------------------------------------------------

-- True if t looks like an array (has a value at index 1) rather than a
-- plain string-keyed settings dict.
local function IsArrayLike(t)
    return t[1] ~= nil
end

-- Fills any key present in `defaults` but missing from `tbl`, recursing
-- into nested DICT-like sub-tables only -- never into array-like ones
-- (layout.indicators/indicatorsRaid, color/position tuples like
-- {"class_color","any"} or {0.2,0.8,0.2,1}, roleOrder, etc). Existing
-- values, at any depth, are never touched.
--
-- This replaces AceDB-3.0's own defaults-table metatable, which silently
-- supplied ANY missing key at ANY depth for the lifetime of a profile --
-- an existing profile could go its whole life never having, say,
-- appearance.healthBar.fullColor actually WRITTEN into it, relying
-- entirely on that live fallback every single read. ProfileStore has no
-- such live mechanism, so without this, any field a profile never
-- happened to have explicitly wouldn't just fall back to a sane default
-- the way it used to -- it would resolve to nil outright (confirmed via a
-- live user report: health bar colors silently stopped working after the
-- AceDB->ProfileStore migration, traced to exactly this gap). Arrays are
-- deliberately excluded -- EnsureIndicatorLists (Core.lua) already handles
-- layout.indicators/indicatorsRaid with careful NAME-based (not
-- positional) merging, for reasons documented in its own comment (a naive
-- positional array-fill previously caused real data corruption); this
-- function only ever fills a whole missing array field wholesale (the
-- `tbl[k] == nil` branch), never merges INTO an existing one.
local function DeepFillDefaults(tbl, defaults)
    for k, v in pairs(defaults) do
        if tbl[k] == nil then
            tbl[k] = (type(v) == "table") and F.CopyTable(v) or v
        elseif type(v) == "table" and type(tbl[k]) == "table"
            and not IsArrayLike(v) and not IsArrayLike(tbl[k]) then
            DeepFillDefaults(tbl[k], v)
        end
    end
end

-- Deep value comparison, used only to tell whether a draft has diverged
-- from what's actually saved (see DraftIsDirty). Order-insensitive and
-- structure-aware; intentionally simple since profile tables are plain data.
local function DeepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not DeepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- Points db.profile at the given profile -- a live reference for a normal
-- profile, or a fresh draft copy for a PROTECTED one (see PROTECTED's
-- comment). This is the ONE place db.profile ever gets reassigned.
local function ApplyActiveProfile(db, name)
    db._activeName = name
    if ProfileStore.PROTECTED[name] then
        db.profile = F.CopyTable(db.sv.profiles[name])
        -- Baseline for DraftIsDirty: what was saved at the moment this
        -- draft was handed out. Taken AFTER the copy but BEFORE
        -- DeepFillDefaults, then re-taken below, so backfilled defaults
        -- don't themselves count as "unsaved user edits".
        DeepFillDefaults(db.profile, SquizzFrames.defaults.profile)
        db._draftBaseline = F.CopyTable(db.profile)
        return
    end
    db.profile = db.sv.profiles[name]
    db._draftBaseline = nil
    DeepFillDefaults(db.profile, SquizzFrames.defaults.profile)
end

-----------------------------------------------------------------------
-- Public db object methods
-----------------------------------------------------------------------

local DB = {}
DB.__index = DB

function DB:GetProfiles()
    local names = {}
    for name in pairs(self.sv.profiles) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

function DB:GetCurrentProfile()
    return self._activeName
end

-- Creates the profile fresh (from registered defaults) if it doesn't exist
-- yet -- matches the options page's existing "New Profile" expectation
-- (typing a brand-new name and hitting Create just works).
--
-- `isAutomatic` (2026-08-07) marks a switch driven by the spec x situation
-- auto-switcher rather than a deliberate user action. Two things change:
--   1. It does NOT persist the choice into charProfileKeys. Previously an
--      automatic switch overwrote the character's manual selection (and so
--      what loaded at next login), meaning auto-switch and manual switching
--      fought each other: a manual pick was silently reverted at the next
--      GROUP_ROSTER_UPDATE, permanently.
--   2. It refuses to silently throw away unsaved edits to a PROTECTED
--      (draft-model) profile -- see the DraftIsDirty check. Joining a party
--      with auto-switch enabled used to discard all unsaved Default edits
--      with no warning.
function DB:SetProfile(name, isAutomatic)
    if not name or name == "" then return end
    local self_ = self
    GuardedCall(function()
        local sv = self_.sv
        if not sv.profiles[name] then
            sv.profiles[name] = F.CopyTable(SquizzFrames.defaults.profile)
        end
        if isAutomatic and self_:DraftIsDirty() then
            -- Keep the user's unsaved work and their current profile; just
            -- tell them why the automatic switch didn't happen.
            SquizzFrames:Print(("Auto-switch to '%s' skipped -- you have unsaved changes to '%s'. Save them (Profiles tab) or switch manually.")
                :format(name, tostring(self_._activeName)))
            return
        end
        if not isAutomatic then
            sv.charProfileKeys[ProfileStore.CHAR_KEY] = name
        end
        ApplyActiveProfile(self_, name)
        SquizzFrames:RefreshProfile()
    end)
end

-- Overwrites the CURRENT active profile's contents with sourceName's.
function DB:CopyProfile(sourceName)
    if not sourceName then return end
    local self_ = self
    GuardedCall(function()
        local src = self_.sv.profiles[sourceName]
        if not src then return end
        local name = self_._activeName
        if ProfileStore.PROTECTED[name] then
            self_.profile = F.CopyTable(src) -- stays a draft, not written to sv yet
        else
            self_.sv.profiles[name] = F.CopyTable(src)
            self_.profile = self_.sv.profiles[name]
        end
        SquizzFrames:RefreshProfile()
    end)
end

-- Refuses the active profile (can't delete what you're standing on) and
-- "Default" unconditionally, even if inactive -- Default is only
-- IMPLICITLY protected from deletion in the old UI (the delete dropdown
-- happens to exclude the active profile, but nothing stopped switching off
-- Default and deleting it outright), which would break the seed-new-
-- characters-from-Default path for every future alt. Explicit hardening,
-- not just a port of the old behavior.
function DB:DeleteProfile(name)
    if not name or name == "Default" or name == self._activeName then return end
    local self_ = self
    GuardedCall(function()
        local sv = self_.sv
        sv.profiles[name] = nil
        for _, situations in pairs(sv.autoSwitch.map) do
            for situation, profileName in pairs(situations) do
                if profileName == name then situations[situation] = nil end
            end
        end
        for charKey, profileName in pairs(sv.charProfileKeys) do
            if profileName == name then sv.charProfileKeys[charKey] = nil end
        end
        -- Refresh the Profiles page from INSIDE the guarded action, so the
        -- list reflects the deletion at the moment it actually happens
        -- (2026-08-07). The options page used to call its own Rebuild()
        -- immediately after this method returned -- but in combat the real
        -- mutation is queued to combat-end, so the UI rebuilt first and
        -- still listed the "deleted" profile. Unlike Copy/Rename/Reset this
        -- doesn't change the ACTIVE profile, so there's nothing for
        -- RefreshProfile to do and no "ProfileChanged" to fire.
        if SquizzFrames.OptionsFrame_RefreshProfilesPage then
            SquizzFrames.OptionsFrame_RefreshProfilesPage()
        end
    end)
end

-- New capability -- the old AceDB-backed UI had no rename, the pattern was
-- duplicate-under-new-name + delete-old. Blocked for "Default" (same
-- reasoning as DeleteProfile).
function DB:RenameProfile(oldName, newName)
    if not oldName or not newName or newName == "" or oldName == "Default" or oldName == newName then return end
    local self_ = self
    GuardedCall(function()
        local sv = self_.sv
        if not sv.profiles[oldName] or sv.profiles[newName] then return end -- source missing or name collision
        sv.profiles[newName] = sv.profiles[oldName]
        sv.profiles[oldName] = nil
        for _, situations in pairs(sv.autoSwitch.map) do
            for situation, profileName in pairs(situations) do
                if profileName == oldName then situations[situation] = newName end
            end
        end
        for charKey, profileName in pairs(sv.charProfileKeys) do
            if profileName == oldName then sv.charProfileKeys[charKey] = newName end
        end
        if self_._activeName == oldName then
            ApplyActiveProfile(self_, newName)
        end
        SquizzFrames:RefreshProfile()
    end)
end

-- Resets the CURRENT profile back to defaults, in place. Backs /sf reset
-- (Utils.lua), which calls this then immediately ReloadUI()s.
function DB:ResetProfile()
    local self_ = self
    GuardedCall(function()
        local name = self_._activeName
        self_.sv.profiles[name] = F.CopyTable(SquizzFrames.defaults.profile)
        ApplyActiveProfile(self_, name)
        SquizzFrames:RefreshProfile()
    end)
end

-- Writes the current draft (only meaningful while on a PROTECTED profile,
-- i.e. Default) into the SavedVariable in place. Replaces the old
-- CommitDefaultSnapshot/OnPlayerLogout hack entirely -- an uncommitted
-- draft here is just a plain Lua table never linked into SquizzFramesDB at
-- all, so it can't reach disk by accident; no PLAYER_LOGOUT hook needed.
-- Deliberately does NOT reassign db.profile to a new table afterward --
-- stays the SAME draft object, now freshly mirrored into sv.profiles
-- ["Default"] too, so future edits keep going through the same draft
-- model (Default always requires an explicit Save, not just the first
-- time).
function DB:CommitDraft()
    local self_ = self
    GuardedCall(function()
        local name = self_._activeName
        if not ProfileStore.PROTECTED[name] then return end
        self_.sv.profiles[name] = F.CopyTable(self_.profile)
        -- The draft is now identical to what's saved, so it's no longer
        -- dirty -- re-baseline rather than leaving DraftIsDirty reporting
        -- stale unsaved changes forever after a Save.
        self_._draftBaseline = F.CopyTable(self_.profile)
    end)
end

-- True when the active profile uses the draft model (PROTECTED, i.e.
-- Default) AND the draft has diverged from what's actually saved. Used to
-- stop an AUTOMATIC profile switch from silently throwing away unsaved
-- work; a deliberate manual switch is still allowed to discard it, matching
-- how the draft model is documented to behave.
function DB:DraftIsDirty()
    if not ProfileStore.PROTECTED[self._activeName] then return false end
    if not self._draftBaseline then return false end
    return not DeepEqual(self.profile, self._draftBaseline)
end

-- Copies every party-vs-raid-split setting group in ONE direction within
-- the current profile (2026-08-07). Party and Raid keep fully separate
-- settings for frame layout, the indicator list AND pet frames, so setting
-- up Raid from scratch after tuning Party (or vice versa) was a lot of
-- manual work. DandersFrames has the same feature for the same reason.
--
-- `direction` is "partyToRaid" or "raidToParty". Deep-copies so the two
-- sides stay genuinely independent afterwards -- sharing a table reference
-- here would make every later edit apply to both modes at once.
function DB:CopyBetweenModes(direction)
    if direction ~= "partyToRaid" and direction ~= "raidToParty" then return end
    local self_ = self
    GuardedCall(function()
        local p = self_.profile
        if not p then return end
        local toRaid = (direction == "partyToRaid")

        -- Frame layout (size/growth/spacing/sort). anchorX/anchorY are
        -- deliberately NOT copied: each mode's on-screen position is its
        -- own thing, and overwriting it would yank the frames somewhere
        -- unexpected -- which is not what "copy my settings over" means.
        if p.layout then
            local src = toRaid and p.layout.main or p.layout.raid
            local dstKey = toRaid and "raid" or "main"
            if src then
                local keepX = p.layout[dstKey] and p.layout[dstKey].anchorX
                local keepY = p.layout[dstKey] and p.layout[dstKey].anchorY
                local copy = F.CopyTable(src)
                copy.anchorX, copy.anchorY = keepX, keepY
                p.layout[dstKey] = copy
            end
            -- Indicator lists.
            local srcList = toRaid and p.layout.indicators or p.layout.indicatorsRaid
            if srcList then
                if toRaid then
                    p.layout.indicatorsRaid = F.CopyTable(srcList)
                else
                    p.layout.indicators = F.CopyTable(srcList)
                end
            end
        end

        -- Pet frames -- same anchor-preserving rule as the main layout.
        if p.petFrames then
            local src = toRaid and p.petFrames.main or p.petFrames.raid
            local dstKey = toRaid and "raid" or "main"
            if src then
                local keepX = p.petFrames[dstKey] and p.petFrames[dstKey].anchorX
                local keepY = p.petFrames[dstKey] and p.petFrames[dstKey].anchorY
                local copy = F.CopyTable(src)
                copy.anchorX, copy.anchorY = keepX, keepY
                p.petFrames[dstKey] = copy
            end
        end

        SquizzFrames:RefreshProfile()
        SquizzFrames:Print(toRaid and "Copied Party settings to Raid."
            or "Copied Raid settings to Party.")
    end)
end

-- The other direction: copies the CURRENT profile's content into
-- "Default", for use while NOT on Default (the options page only shows
-- this button in that case).
function DB:SaveCurrentAsDefault()
    local self_ = self
    GuardedCall(function()
        local current = self_._activeName
        local src = ProfileStore.PROTECTED[current] and self_.profile or self_.sv.profiles[current]
        if not src then return end
        self_.sv.profiles["Default"] = F.CopyTable(src)
        if current == "Default" then
            ApplyActiveProfile(self_, "Default")
        end
    end)
end

-----------------------------------------------------------------------
-- Init -- replaces LibStub("AceDB-3.0"):New(...). Called once from
-- Core:OnInitialize.
-----------------------------------------------------------------------
function ProfileStore:Init()
    self.CHAR_KEY = self.CHAR_KEY or (UnitName("player") .. " - " .. GetRealmName())

    local sv = _G[svName]
    if not sv then
        sv = {}
        _G[svName] = sv
    end

    self:MigrateFromAceDB(sv)

    sv.profiles = sv.profiles or {}
    sv.charProfileKeys = sv.charProfileKeys or {}
    sv.autoSwitch = sv.autoSwitch or { enabled = false, map = {} }
    sv.autoSwitch.map = sv.autoSwitch.map or {}
    sv.perCharSeedDone = sv.perCharSeedDone or {}

    if not sv.profiles["Default"] then
        sv.profiles["Default"] = F.CopyTable(SquizzFrames.defaults.profile)
    end

    local charKey = self.CHAR_KEY

    -- Resolve (or create) this character's active profile. Mirrors AceDB's
    -- own native per-character default ("profileKeys[charKey] or charKey")
    -- -- a brand-new character gets their OWN fresh profile from the very
    -- first login, named after their charKey, rather than everyone sharing
    -- one profile.
    -- createdFreshProfile records whether THIS call actually created a brand
    -- new, never-touched profile table. That's the only safe basis for the
    -- seed-from-Default step below -- see its comment. Detecting "untouched"
    -- after the fact isn't viable, since a fresh profile is a full copy of
    -- the defaults rather than an empty table.
    local createdFreshProfile = false
    local activeName = sv.charProfileKeys[charKey]
    if not activeName or not sv.profiles[activeName] then
        activeName = charKey
        if not sv.profiles[activeName] then
            sv.profiles[activeName] = F.CopyTable(SquizzFrames.defaults.profile)
            createdFreshProfile = true
        end
        sv.charProfileKeys[charKey] = activeName
    end

    -- One-time-per-character seed from Default (moved verbatim from
    -- Core.lua's old OnInitialize). Handles two cases the very first time
    -- THIS character is ever seen:
    --   1. Currently on the shared "Default" profile (old forced-sharing
    --      behavior, or deliberately picked before this existed) -- split
    --      out into their own profile, cloned from Default's CURRENT
    --      contents so nothing already set up is lost.
    --   2. A genuinely brand-new character -- already has their own fresh
    --      (blank) profile from the resolve step above, but Default's
    --      whole POINT is a customized template new characters start from
    --      -- seed it from Default's contents too.
    if not sv.perCharSeedDone[charKey] then
        sv.perCharSeedDone[charKey] = true
        local defaultHasContent = sv.profiles["Default"] and next(sv.profiles["Default"])
        if activeName == "Default" then
            activeName = charKey
            sv.profiles[activeName] = F.CopyTable(sv.profiles["Default"])
            sv.charProfileKeys[charKey] = activeName
        elseif defaultHasContent and createdFreshProfile then
            -- DATA-LOSS GUARD (2026-08-07): this branch exists to seed a
            -- BRAND-NEW character's profile from Default, but it used to
            -- fire on "haven't seeded this charKey yet" ALONE, with no check
            -- that the target profile was actually new -- so it silently
            -- overwrote fully customized profiles with Default's contents.
            -- That is reachable in practice: perCharSeedDone is inherited
            -- from the legacy perCharProfileSplit key, so any character that
            -- hadn't logged in since that older flag was introduced arrives
            -- here with real settings and no flag set. Now gated on having
            -- actually created the profile moments ago, so an existing
            -- profile is never touched.
            sv.profiles[activeName] = F.CopyTable(sv.profiles["Default"])
        end
    end

    local db = setmetatable({ sv = sv }, DB)
    -- Account-wide, never reassigned to a new table after this (only its
    -- .enabled/.map sub-fields mutate in place), so a one-time live
    -- reference here stays valid forever -- unlike db.profile, this never
    -- needs to be re-pointed by ApplyActiveProfile on a later switch.
    -- BUG FIX (2026-08-06, live user report: Auto-Switch checkbox existed
    -- but the spec/situation matrix never appeared): this field was never
    -- actually set on the returned db object at all -- OptionsFrame.lua's
    -- GetSpecSwitchEnabled/SetSpecSwitchEnabled both read/write db.autoSwitch
    -- directly, so every read saw nil and every write silently no-op'd via
    -- their own `if not db.autoSwitch then return end` guard.
    db.autoSwitch = sv.autoSwitch
    ApplyActiveProfile(db, activeName)
    return db
end
