-----------------------------------------------------------------------
-- Nicknames
-----------------------------------------------------------------------
-- Replaces the name shown by the nameText indicator with a nickname.
--
-- Four independent layers, resolved in this order (highest wins):
--   1. custom[full]   -- private, set by you, "Name-Realm" key
--   2. custom[base]   -- private, set by you, bare "Name" key
--   3. synced[full]   -- received over addon comms from other SquizzFrames users
--   4. synced[base]
-- ...falling through to nil, which means "no nickname" and leaves the caller
-- on its existing name path untouched.
--
-- PRIVATE ALWAYS BEATS REMOTE. That ordering is the whole reason the synced
-- layer is tolerable: whatever a stranger broadcasts, a local entry (or the
-- blacklist) overrides it, so you are never stuck with someone else's string
-- on your own frames.
--
-- ---------------------------------------------------------------------
-- The 12.1 secrecy rule this module is built around
-- ---------------------------------------------------------------------
-- A nickname system is "map an identity to a string", and identity is exactly
-- what Patch 12.1 made secret. Two ways that bites:
--
--   1. `map[name]` where `name` is secret HARD-ERRORS. Indexing a table with
--      a secret key is the same crash class already guarded at ~40 sites in
--      this addon (F.GetClassColor, F.GetPowerColor, wantSet[info.spellId]).
--   2. CheckNameText survives secrecy today only because it never TOUCHES the
--      value -- `indicator:SetText(name)` hands it straight to C, which
--      handles secrets natively (see the comment at PetFrames.lua:127). Any
--      `nickname or name` / `"[" .. n .. "] " .. name` / string compare on a
--      secret reintroduces the crash.
--
-- So the contract for Resolve() is absolute:
--
--      Resolve(unit) returns a PLAIN LUA STRING or NIL. Never a secret.
--
-- nil means "couldn't resolve" and the caller falls back to its existing,
-- byte-identical, secret-safe path. The two never blend.
--
-- Everything else here follows from that: resolution happens when the roster
-- is readable and lands in a cache; in combat we only ever read the cache.
-----------------------------------------------------------------------

local SquizzFrames = _G["SquizzFrames"]
local F = SquizzFrames.funcs

local N = SquizzFrames:NewModule("Nicknames", "AceEvent-3.0")

-- REQUIRED, not decoration. AceAddon's NewModule files the module under
-- `self.modules[name]` and `self.orderedModules` ONLY -- it never sets
-- `self[name]` (AceAddon-3.0.lua:263). So `SquizzFrames.Nicknames` is nil
-- until something assigns it, and every cross-module lookup
-- (BuiltIn_Update's CheckNameText hook, Utils' `/sf nick` dispatch) silently
-- takes its "module not loaded" branch even though the module loaded fine.
-- Same convention as Indicators.lua:1703.
SquizzFrames.Nicknames = N

-- Addon message prefix. HARD LIMIT 16 characters --
-- C_ChatInfo.RegisterAddonMessagePrefix rejects anything longer (as does
-- AceComm), so the obvious "SQUIZZFRAMES_NICK" (17) would silently never
-- register and the whole sync layer would go dead with no error.
local COMM_PREFIX = "SQF_NICK"

-- Wire protocol version, sent as the first field. Lets a future format change
-- be ignored by old clients instead of being parsed as garbage.
local COMM_VERSION = "1"

-- Sentinel meaning "I have no nickname, drop whatever you had for me".
-- A bare empty payload can't be used: SendAddonMessage refuses empty strings.
local CLEAR_TOKEN = "\0"

local MAX_NICK_LEN = 20

-----------------------------------------------------------------------
-- Runtime state
-----------------------------------------------------------------------

-- Nicknames received from other players. Dual-keyed by BOTH "Name-Realm" and
-- bare "Name" -- necessary because CHAT_MSG_ADDON's `sender` is always the
-- full "Name-Realm" form, while UnitName(unit) yields a BARE name for
-- same-realm players. Without the second key, same-realm group members (the
-- common case) would never match.
local synced = {}

-- unitToken -> nickname string, or `false` for a resolved miss.
--
-- Keyed by UNIT TOKEN, deliberately, not by button: the secure header
-- reassigns unit tokens across buttons on every re-sort, so anything cached
-- per-button goes stale silently under sortByRole. A unit token's meaning
-- only changes when the ROSTER changes, which is exactly when we wipe.
local resolveCache = {}

local playerFullName        -- "Name-NormalizedRealm", set in OnEnable
local playerRealm           -- GetNormalizedRealmName(), cached alongside it
local broadcastTimer        -- debounce handle for GROUP_ROSTER_UPDATE

-----------------------------------------------------------------------
-- Storage (account-wide, at the SavedVariables root)
-----------------------------------------------------------------------
-- Nicknames describe PEOPLE, not layouts -- a nickname must not vanish when
-- you switch to your Resto profile. So this lives next to sv.autoSwitch /
-- sv.charProfileKeys rather than in db.profile.
--
-- `mine` is keyed per-character (you want a different nickname on your alt),
-- using the comms-form name, NOT ProfileStore.CHAR_KEY -- see PlayerFullName.
local function GetDB()
    local db = SquizzFrames.db
    local sv = db and db.sv
    if not sv then return nil end

    local n = sv.nicknames
    if not n then
        n = {}
        sv.nicknames = n
    end
    if n.enabled == nil then n.enabled = true end
    if n.sync == nil then n.sync = true end
    if n.customEnabled == nil then n.customEnabled = true end
    n.custom = n.custom or {}
    n.blacklist = n.blacklist or {}
    -- Your own nickname, stored TWO ways, independently and simultaneously:
    --   n.mine[playerFullName]  per-character
    --   n.mineShared            one value for the whole account
    -- mineAccountWide only selects which one is read. Keeping both means
    -- flipping the toggle back and forth never destroys the other value --
    -- a character-specific nickname survives a stint on account-wide, and
    -- vice versa. Defaults to per-character: the conservative reading, since
    -- an account-wide default would silently rename every alt the first time
    -- someone set a nickname anywhere.
    n.mine = n.mine or {}
    if n.mineAccountWide == nil then n.mineAccountWide = false end
    return n
end
N.GetDB = GetDB

-----------------------------------------------------------------------
-- Name helpers
-----------------------------------------------------------------------

-- "Name-NormalizedRealm" for the player.
--
-- DELIBERATELY NOT ProfileStore.CHAR_KEY. That one is
-- `UnitName("player") .. " - " .. GetRealmName()` -- spaced separator and an
-- UN-normalized realm ("Twisting Nether"). CHAT_MSG_ADDON's `sender` is
-- "Name-TwistingNether". Reusing CHAR_KEY as a wire key means our own
-- broadcasts never match our own entry and every same-realm lookup misses,
-- silently. Two different keyspaces, kept apart on purpose.
local function PlayerFullName()
    local name = UnitName("player")
    if not name or not F.IsValueNonSecret(name) then return nil end
    local realm = GetNormalizedRealmName()
    if not realm or realm == "" then return name end
    return name .. "-" .. realm
end
N.PlayerFullName = PlayerFullName

-- Resolve and cache both forms together, so they can never disagree.
local function CachePlayerIdentity()
    playerFullName = PlayerFullName()
    local realm = GetNormalizedRealmName()
    playerRealm = (realm and realm ~= "") and realm or nil
end

-- Bare "Name" from a "Name-Realm" key. Caller must have already established
-- that `full` is a plain string.
local function BaseName(full)
    return full:match("^([^%-]+)") or full
end

-- UTF-8-safe truncation to `maxChars` CHARACTERS.
--
-- A plain str:sub(1, n) counts BYTES and will happily cut a multi-byte
-- character in half, producing a mojibake tail -- and non-Latin realm names
-- make that the normal case, not an edge case. Continuation bytes are
-- 0b10xxxxxx (128..191); anything else starts a new character.
-- (str:len() rather than #str purely to keep the language server from
-- narrowing the parameter to a table off the # operator -- identical at runtime.)
local function TruncateChars(str, maxChars)
    local chars = 0
    for i = 1, str:len() do
        local b = str:byte(i)
        if b < 128 or b >= 192 then
            if chars >= maxChars then return str:sub(1, i - 1) end
            chars = chars + 1
        end
    end
    return str
end

-- Scrub a nickname before it is ever stored or displayed.
--
-- This is the security half of the sync layer, and it is the one thing the
-- reference implementations do NOT do -- Cell assigns the received message
-- straight into its table and on into SetText (Comm/Nicknames.lua:244),
-- filtering only for profanity. Profanity is not the problem: |T draws an
-- arbitrary texture inside a FontString and |H creates a clickable hyperlink,
-- so an unsanitized remote nickname lets anyone in your group paint icons and
-- links onto your unit frames. Strip the markup, cap the length, done.
--
-- Applied to LOCAL entries too, not just received ones -- a custom nickname
-- typed with a stray "|" is a rendering bug either way.
local function Sanitize(str)
    if type(str) ~= "string" then return nil end

    -- Order matters: each specific pattern below consumes its own PAYLOAD (the
    -- hex after |c, the path inside |T..|t, the link data AND anchor text
    -- inside |H..|h..|h). Only once those are gone does the catch-all sweep up
    -- whatever escapes remain.
    str = str:gsub("|c%x%x%x%x%x%x%x%x", "")    -- |cAARRGGBB
    str = str:gsub("|c[nN][%w_]+:", "")          -- |cnCOLOR_NAME:
    str = str:gsub("|T.-|t", "")                 -- texture
    str = str:gsub("|A.-|a", "")                 -- atlas
    str = str:gsub("|K.-|k", "")                 -- battle.net kstring
    -- Hyperlinks go completely, anchor text included. A nickname is a plain
    -- label; the display text of an injected link is not somebody's name.
    str = str:gsub("|H.-|h.-|h", "")

    -- Catch-all for orphaned two-character codes: |r, |n, and the closing half
    -- (|t, |h, |a, |k) of any sequence whose opener didn't match above.
    --
    -- This MUST consume the following character as well. Stripping only the
    -- pipe leaves the letter behind as visible junk -- which is exactly how
    -- "...|hclickme|h" first came out as "clickmeh" (caught by /sf nick test).
    -- Restricted to %a rather than "." so a pipe sitting in front of a
    -- multi-byte UTF-8 character can't eat half of it.
    str = str:gsub("||", "")
    str = str:gsub("|%a", "")
    str = str:gsub("|", "")

    -- Newlines and other control characters.
    str = str:gsub("%c", "")

    str = str:match("^%s*(.-)%s*$") or ""
    if str == "" then return nil end
    return TruncateChars(str, MAX_NICK_LEN)
end
N.Sanitize = Sanitize

-----------------------------------------------------------------------
-- Resolution
-----------------------------------------------------------------------

-- Look the two keyspaces up in priority order. Both arguments must already be
-- confirmed plain (non-secret) strings -- this function indexes with them.
local function Lookup(full, base)
    local n = GetDB()
    if not n then return nil end

    if n.customEnabled then
        local c = n.custom
        local hit = (full and c[full]) or (base and c[base])
        if hit then return hit end
    end

    -- NOT gated on n.sync. The sync flag governs the WIRE (whether we send
    -- and accept messages), not this table -- and our own nickname is seeded
    -- into it locally. Gating the read here would mean turning sync off also
    -- blanked your own name on your own frame, which is not what the setting
    -- says. Disabling sync instead purges everyone else's entries at the
    -- source, in SetSyncEnabled, so there is nothing left here to hide.
    local hit = (full and synced[full]) or (base and synced[base])
    if hit then return hit end

    return nil
end

-- THE public entry point. Returns a plain string, or nil.
--
-- nil covers three distinct cases, all of which the caller handles the same
-- way (fall through to its own name path):
--   * nicknames disabled
--   * no nickname on file for this player
--   * the unit's name is currently SECRET, so we cannot look anything up
--
-- That last case is why the cache exists. Out of combat the name reads plain
-- and the answer is memoised; once identity goes secret mid-fight we can no
-- longer even compute the key, so we serve the cached answer instead of
-- crashing or blanking the frame.
function N:Resolve(unit)
    if not unit then return nil end

    local n = GetDB()
    if not n or not n.enabled then return nil end

    local cached = resolveCache[unit]
    if cached ~= nil then
        -- `false` is the memoised "no nickname" answer; distinct from nil,
        -- which means "not yet resolved".
        return cached or nil
    end

    local name, realm = UnitName(unit)
    if not name or not F.IsValueNonSecret(name) then
        -- Secret. Do NOT cache -- this is a transient condition and caching
        -- it would pin the miss for the rest of the fight, past the point
        -- where the name becomes readable again.
        return nil
    end

    -- UnitName returns an EMPTY realm for same-realm players, so "no realm"
    -- means "my realm" rather than "unknown" -- fill it in, otherwise every
    -- same-realm player would only ever match on the bare-name key. realm can
    -- also go secret independently of name, so gate it separately rather than
    -- assuming the two travel together.
    local full
    if realm and F.IsValueNonSecret(realm) and realm ~= "" then
        full = name .. "-" .. realm
    elseif playerRealm then
        full = name .. "-" .. playerRealm
    end

    local nick = Lookup(full, name)
    resolveCache[unit] = nick or false
    return nick
end

-----------------------------------------------------------------------
-- Refresh
-----------------------------------------------------------------------

-- PartyFrames is reached through AceAddon's own accessor, NOT as
-- `SquizzFrames.PartyFrames` -- that field does not exist. Only a few modules
-- (Indicators, AuraEngine, GroupPreview) explicitly publish themselves onto
-- the addon object; PartyFrames never does, so the attribute read silently
-- yields nil and every refresh would no-op. GetModule's second argument
-- suppresses the error if it's somehow absent.
local partyFramesModule
local function GetPartyFrames()
    if not partyFramesModule then
        partyFramesModule = SquizzFrames:GetModule("PartyFrames", true)
    end
    return partyFramesModule
end

-- Cell's entire update mechanism is `b.indicators.nameText:UpdateName()`.
-- This addon already has the exact equivalent: CheckNameText stores a
-- rebuild closure on the indicator as `_sfNameUpdater` (BuiltIn_Update.lua),
-- and Indicators.lua already calls it from three places. So a nickname change
-- needs no new plumbing at all -- wipe the cache, re-run the closure.
local function RefreshAllNames()
    wipe(resolveCache)

    local PartyFrames = GetPartyFrames()
    if not PartyFrames or not PartyFrames.IterateButtons then return end

    PartyFrames:IterateButtons(function(button)
        local indicator = button.indicators and button.indicators.nameText
        -- _sfNameUpdater only exists once CheckNameText has run at least once
        -- for this button; before that there is nothing to refresh anyway.
        if indicator and indicator._sfNameUpdater then
            indicator._sfNameUpdater()
        end
    end)
end
N.RefreshAllNames = RefreshAllNames

-----------------------------------------------------------------------
-- Comms
-----------------------------------------------------------------------

-- Put our own nickname into the synced table under both keys, so the ordinary
-- resolution path finds it for our own frame -- no "is this me?" special case
-- inside Resolve, and no waiting on a round trip we never make to ourselves.
-- Both reference implementations seed themselves the same way.
local function SeedOwnNickname()
    if not playerFullName then return end
    -- Via the accessor, never n.mine[...] directly -- which of the two stores
    -- is live depends on n.mineAccountWide.
    local mine = N:GetMyNickname()
    synced[playerFullName] = mine
    synced[BaseName(playerFullName)] = mine
end

local function GetSendChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

local function BroadcastNickname()
    local n = GetDB()
    if not n or not n.sync then return end
    if not playerFullName then return end

    local channel = GetSendChannel()
    if not channel then return end

    local nick = N:GetMyNickname()
    local payload = (nick and nick ~= "") and nick or CLEAR_TOKEN
    C_ChatInfo.SendAddonMessage(COMM_PREFIX, COMM_VERSION .. ":" .. payload, channel)
end
N.BroadcastNickname = BroadcastNickname

-- Re-broadcast on roster change so anyone who just joined learns our name.
--
-- Jittered, not immediate. Cell avoids the storm with a two-message
-- check/reply handshake (one player asks, everyone answers once); this is the
-- cheaper middle ground -- every client still broadcasts, but spread out so
-- 40 raiders don't all fire inside the same frame and trip the addon-message
-- throttle. The raid window is wider precisely because that's where the
-- message count is 8x the party case. If throttling ever shows up in a real
-- 40-man, escalating to Cell's full handshake is the next step.
local function ScheduleBroadcast()
    local n = GetDB()
    if not n or not n.sync then return end
    if not GetSendChannel() then return end

    if broadcastTimer then
        broadcastTimer:Cancel()
        broadcastTimer = nil
    end
    local window = IsInRaid() and 8 or 3
    broadcastTimer = C_Timer.NewTimer(1 + random() * window, function()
        broadcastTimer = nil
        BroadcastNickname()
    end)
end

-- Set by the self-test harness below while a whisper-to-self is in flight.
local wireTestTimer

function N:OnAddonMessage(_, prefix, text, _, sender)
    if prefix ~= COMM_PREFIX then return end
    if not text or not sender then return end

    -- Reported before any of the gates below, so the wire result is honest
    -- even with sync disabled or the payload malformed: this is asking "did
    -- the message come back at all", nothing more.
    if wireTestTimer then
        wireTestTimer:Cancel()
        wireTestTimer = nil
        SquizzFrames:Print("  wire:     |cff00ff00OK|r - round-tripped from " .. tostring(sender))
    end

    local n = GetDB()
    if not n or not n.sync then return end

    local version, payload = text:match("^(%d+):(.*)$")
    if version ~= COMM_VERSION or not payload or payload == "" then return end

    -- `sender` is the authority on WHO this nickname belongs to, and it comes
    -- from the server, not the payload.
    --
    -- This is a deliberate divergence from DPSReport, which puts the owning
    -- character key INSIDE the message ("NICK:<charKey>:<nick>",
    -- DPSReport.lua:686) and trusts it. That lets any group member set a
    -- nickname for a DIFFERENT player -- impersonation, not just self-naming.
    -- Taking it from `sender` makes that structurally impossible.
    local full = sender
    if not full:find("-", 1, true) and playerRealm then
        full = full .. "-" .. playerRealm
    end

    -- Never let a remote message overwrite our own entry.
    if full == playerFullName then return end

    local base = BaseName(full)

    if payload == CLEAR_TOKEN or n.blacklist[full] or n.blacklist[base] then
        synced[full] = nil
        synced[base] = nil
    else
        local clean = Sanitize(payload)
        if not clean then return end
        synced[full] = clean
        -- Dual-key: same-realm party members resolve by bare name.
        synced[base] = clean
    end

    RefreshAllNames()
end

-----------------------------------------------------------------------
-- Public API (used by the slash commands, and by the options panel later)
-----------------------------------------------------------------------

-- Our own nickname. `nick` nil/empty clears it.
function N:SetMyNickname(nick)
    local n = GetDB()
    if not n or not playerFullName then return nil end

    local clean = nick and Sanitize(nick) or nil
    if n.mineAccountWide then
        n.mineShared = clean
    else
        n.mine[playerFullName] = clean
    end

    SeedOwnNickname()
    RefreshAllNames()
    BroadcastNickname()
    return clean
end

function N:GetMyNickname()
    local n = GetDB()
    if not n then return nil end
    if n.mineAccountWide then return n.mineShared end
    if not playerFullName then return nil end
    return n.mine[playerFullName]
end

-- Switch between one nickname for the whole account and one per character.
function N:SetMineAccountWide(enabled)
    local n = GetDB()
    if not n then return end
    n.mineAccountWide = enabled and true or false

    -- Turning it ON with nothing stored account-wide yet adopts THIS
    -- character's nickname, so the setting doesn't read as "my nickname just
    -- disappeared". Only seeds when empty -- it never overwrites a shared
    -- nickname that was already set.
    if n.mineAccountWide and not n.mineShared and playerFullName then
        n.mineShared = n.mine[playerFullName]
    end

    SeedOwnNickname()
    RefreshAllNames()
    BroadcastNickname()
end

-- A private, local-only nickname for someone else. `nick` nil/empty removes.
function N:SetCustomNickname(playerName, nick)
    local n = GetDB()
    if not n or type(playerName) ~= "string" then return nil end

    local key = playerName:match("^%s*(.-)%s*$")
    if key == "" then return nil end

    local clean = nick and Sanitize(nick) or nil
    n.custom[key] = clean
    RefreshAllNames()
    return clean
end

function N:SetBlacklisted(playerName, blocked)
    local n = GetDB()
    if not n or type(playerName) ~= "string" then return end

    local key = playerName:match("^%s*(.-)%s*$")
    if key == "" then return end

    n.blacklist[key] = blocked or nil
    if blocked then
        -- Drop anything already received from them, under both keys.
        synced[key] = nil
        synced[BaseName(key)] = nil
    end
    RefreshAllNames()
end

function N:SetSyncEnabled(enabled)
    local n = GetDB()
    if not n then return end

    n.sync = enabled and true or false
    if n.sync then
        ScheduleBroadcast()
    else
        -- Drop everything received, then re-seed our own (which is local, not
        -- received, and stays visible on our own frame -- see Lookup). Then
        -- tell the group to drop ours, so we stop showing under a nickname on
        -- their frames too.
        wipe(synced)
        SeedOwnNickname()
        local channel = GetSendChannel()
        if channel then
            C_ChatInfo.SendAddonMessage(COMM_PREFIX, COMM_VERSION .. ":" .. CLEAR_TOKEN, channel)
        end
    end
    RefreshAllNames()
end

function N:SetEnabled(enabled)
    local n = GetDB()
    if not n then return end
    n.enabled = enabled and true or false
    RefreshAllNames()
end

-----------------------------------------------------------------------
-- Self-test harness
-----------------------------------------------------------------------
-- The sync half normally needs a second person running the addon. Solo, these
-- checks cover everything except another client's SEND side:
--
--   WIRE     SendAddonMessage over "WHISPER" targeted at yourself is a real
--            server round trip -- it leaves the client and comes back as
--            CHAT_MSG_ADDON -- so it proves prefix registration and delivery
--            for real, not by simulation. (Same technique LibSerialize's own
--            usage example uses, Libs/LibSerialize/LibSerialize.lua:71.)
--   RECEIVE  Feeds a synthetic message through the REAL OnAddonMessage with a
--            fake sender, exercising parse -> sanitize -> dual-key -> refresh
--            along the identical path an actual remote message takes.
--   SANITIZE Runs a hostile payload (colour + texture + hyperlink escapes)
--            through the scrubber and shows what survives.
--
-- Rendering is NOT covered here -- solo there is no other unit to draw on.
-- Verify that separately with `/sf nick me <name>`, which needs no second
-- client at all.
--
-- Marked as a dev harness, same status as /sfauratest: fine to leave in,
-- don't build features on top of it.

local TEST_SENDER = "Testdummy-Testrealm"

local function RunSelfTest()
    local n = GetDB()
    if not n then
        SquizzFrames:Print("Nicknames aren't ready yet.")
        return
    end

    SquizzFrames:Print("Nickname self-test:")
    print("  identity: " .. (playerFullName or "|cffff5555unresolved|r"))

    -- SANITIZE. Asserts against an EXPECTED value rather than just printing
    -- whatever came out -- the first version reported "OK -> 'Bobclickmeh'",
    -- which was a real escaping bug wearing a pass label.
    local hostile = "|cffff0000|TInterface\\Icons\\INV_Misc_QuestionMark:16|tBob|r|Hplayer:x|hclickme|h"
    local scrubbed = Sanitize(hostile)
    print("  sanitize: " .. (scrubbed == "Bob"
        and "|cff00ff00OK|r -> 'Bob' |cff808080(from colour+texture+hyperlink escapes)|r"
        or ("|cffff5555FAILED|r -> '" .. tostring(scrubbed) .. "', expected 'Bob'")))

    -- RECEIVE
    if not n.sync then
        print("  receive:  |cff808080skipped - sync is off (/sf nick sync on)|r")
    else
        N:OnAddonMessage(nil, COMM_PREFIX, COMM_VERSION .. ":Dummy", "PARTY", TEST_SENDER)
        local got = synced[TEST_SENDER]
        local alsoBareKey = synced[BaseName(TEST_SENDER)] == "Dummy"
        print("  receive:  " .. (got == "Dummy" and alsoBareKey
            and ("|cff00ff00OK|r stored 'Dummy' for " .. TEST_SENDER .. " (both keys)")
            or ("|cffff5555FAILED|r -> full='" .. tostring(got)
                .. "' bare='" .. tostring(synced[BaseName(TEST_SENDER)]) .. "'")))
    end

    -- WIRE
    local target = UnitName("player")
    if not target or not F.IsValueNonSecret(target) then
        print("  wire:     |cff808080skipped - own name unreadable right now|r")
        return
    end
    if wireTestTimer then wireTestTimer:Cancel() end
    wireTestTimer = C_Timer.NewTimer(5, function()
        wireTestTimer = nil
        SquizzFrames:Print("  wire:     |cffff5555FAILED|r - no round trip within 5s.")
    end)
    C_ChatInfo.SendAddonMessage(COMM_PREFIX, COMM_VERSION .. ":wirecheck", "WHISPER", target)
    print("  wire:     sent to self, awaiting round trip...")
end

local function ClearSelfTest()
    synced[TEST_SENDER] = nil
    synced[BaseName(TEST_SENDER)] = nil
    RefreshAllNames()
    SquizzFrames:Print("Self-test entries cleared.")
end

-----------------------------------------------------------------------
-- Slash commands
-----------------------------------------------------------------------
-- Full functionality ahead of the options panel. Dispatched from
-- F.SlashHandler (Utils.lua) as `/sf nick ...`.

local function PrintUsage()
    SquizzFrames:Print("Nicknames:")
    print("  |cffffd100/sf nick me <nickname>|r - set your own (shared with the group)")
    print("  |cffffd100/sf nick me clear|r - remove your own")
    print("  |cffffd100/sf nick account on|off|r - share your nickname across all characters")
    print("  |cffffd100/sf nick set <Name-Realm> <nickname>|r - private, only you see it")
    print("  |cffffd100/sf nick clear <Name-Realm>|r - remove a private nickname")
    print("  |cffffd100/sf nick block|unblock <Name-Realm>|r - ignore what they broadcast")
    print("  |cffffd100/sf nick list|r - show everything on file")
    print("  |cffffd100/sf nick sync on|off|r - share and receive nicknames")
    print("  |cffffd100/sf nick on|off|r - master toggle")
    print("  |cffffd100/sf nick test|r - solo self-check of the sync pipeline")
end

function N:HandleSlash(rest)
    local n = GetDB()
    if not n then
        SquizzFrames:Print("Nicknames aren't ready yet -- try again in a moment.")
        return
    end

    rest = rest or ""
    local sub, args = rest:match("^(%S*)%s*(.-)$")
    sub = (sub or ""):lower()

    if sub == "" or sub == "help" then
        PrintUsage()

    elseif sub == "on" or sub == "off" then
        self:SetEnabled(sub == "on")
        SquizzFrames:Print("Nicknames " .. (n.enabled and "enabled." or "disabled."))

    elseif sub == "sync" then
        local val = args:lower()
        if val ~= "on" and val ~= "off" then
            SquizzFrames:Print("Usage: /sf nick sync on|off")
            return
        end
        self:SetSyncEnabled(val == "on")
        SquizzFrames:Print("Nickname sync " .. (n.sync and "enabled." or "disabled."))

    elseif sub == "me" then
        if args == "" then
            local mine = self:GetMyNickname()
            SquizzFrames:Print(mine and ("Your nickname: " .. mine) or "You have no nickname set.")
            return
        end
        if args:lower() == "clear" then
            self:SetMyNickname(nil)
            SquizzFrames:Print("Your nickname has been cleared.")
            return
        end
        local clean = self:SetMyNickname(args)
        if clean then
            SquizzFrames:Print("Your nickname is now: " .. clean)
        else
            SquizzFrames:Print("That nickname isn't usable -- try plain text.")
        end

    elseif sub == "set" then
        -- "Name-Realm nickname": the player key is the first whitespace-
        -- delimited token, everything after is the nickname (which may
        -- contain spaces).
        local who, nick = args:match("^(%S+)%s+(.+)$")
        if not who then
            SquizzFrames:Print("Usage: /sf nick set <Name-Realm> <nickname>")
            return
        end
        local clean = self:SetCustomNickname(who, nick)
        if clean then
            SquizzFrames:Print(who .. " will show as: " .. clean)
        else
            SquizzFrames:Print("That nickname isn't usable -- try plain text.")
        end

    elseif sub == "clear" then
        if args == "" then
            SquizzFrames:Print("Usage: /sf nick clear <Name-Realm>")
            return
        end
        self:SetCustomNickname(args, nil)
        SquizzFrames:Print("Cleared private nickname for " .. args .. ".")

    elseif sub == "block" or sub == "unblock" then
        if args == "" then
            SquizzFrames:Print("Usage: /sf nick " .. sub .. " <Name-Realm>")
            return
        end
        self:SetBlacklisted(args, sub == "block")
        SquizzFrames:Print(args .. (sub == "block"
            and " is blocked -- their broadcast nickname will be ignored."
            or " is no longer blocked."))

    elseif sub == "account" then
        local val = args:lower()
        if val ~= "on" and val ~= "off" then
            SquizzFrames:Print("Usage: /sf nick account on|off")
            print("  |cff808080on = one nickname for every character on the account|r")
            print("  |cff808080off = a separate nickname per character (default)|r")
            return
        end
        self:SetMineAccountWide(val == "on")
        local mine = self:GetMyNickname()
        SquizzFrames:Print(n.mineAccountWide
            and ("Your nickname is now account-wide: " .. (mine or "|cff808080(none set)|r"))
            or ("Your nickname is now per-character: " .. (mine or "|cff808080(none set)|r")))

    elseif sub == "test" then
        if args:lower() == "clean" then
            ClearSelfTest()
        else
            RunSelfTest()
        end

    elseif sub == "list" then
        SquizzFrames:Print(("Nicknames: %s | sync: %s | private list: %s"):format(
            n.enabled and "on" or "off",
            n.sync and "on" or "off",
            n.customEnabled and "on" or "off"))

        local mine = self:GetMyNickname()
        print("  |cff33cc99Yours:|r " .. (mine or "|cff808080(none)|r")
            .. " |cff808080(" .. (n.mineAccountWide and "account-wide" or "this character only") .. ")|r")

        local any = false
        for who, nick in pairs(n.custom) do
            if not any then print("  |cff33cc99Private:|r") any = true end
            print("    " .. who .. " -> " .. nick)
        end
        if not any then print("  |cff33cc99Private:|r |cff808080(none)|r") end

        -- Only the full "Name-Realm" keys, so the bare-name duplicates each
        -- entry is dual-keyed under don't get listed twice.
        any = false
        for who, nick in pairs(synced) do
            if who:find("-", 1, true) then
                if not any then print("  |cff33cc99Received:|r") any = true end
                print("    " .. who .. " -> " .. nick)
            end
        end
        if not any then print("  |cff33cc99Received:|r |cff808080(none)|r") end

        any = false
        for who in pairs(n.blacklist) do
            if not any then print("  |cff33cc99Blocked:|r") any = true end
            print("    " .. who)
        end

    else
        PrintUsage()
    end
end

-----------------------------------------------------------------------
-- Lifecycle
-----------------------------------------------------------------------

function N:OnEnable()
    GetDB()

    CachePlayerIdentity()
    SeedOwnNickname()

    C_ChatInfo.RegisterAddonMessagePrefix(COMM_PREFIX)
    self:RegisterEvent("CHAT_MSG_ADDON", "OnAddonMessage")

    -- Both invalidate the unit-token cache: a roster change repoints tokens at
    -- different players, and UNIT_NAME_UPDATE means a name we already resolved
    -- (or failed to resolve) has changed underneath us.
    --
    -- These REFRESH rather than merely wiping, and that matters: BuiltIn_Update
    -- registers CheckNameText for both of these same events, and AceEvent makes
    -- no ordering guarantee between two owners on one event. A bare wipe that
    -- landed AFTER CheckNameText would leave the frame showing the previous
    -- occupant's nickname until something else happened to fire. Refreshing
    -- makes the order irrelevant -- worst case CheckNameText runs twice.
    self:RegisterEvent("GROUP_ROSTER_UPDATE", function()
        RefreshAllNames()
        ScheduleBroadcast()
    end)

    -- Per-unit, because UNIT_NAME_UPDATE arrives in bursts (one per unit, for
    -- units we mostly don't care about -- see the note at PartyFrames.lua:2427).
    -- A full RefreshAllNames per burst event would be wasted work.
    self:RegisterEvent("UNIT_NAME_UPDATE", function(_, unit)
        if not unit then return end
        resolveCache[unit] = nil

        local PartyFrames = GetPartyFrames()
        local button = PartyFrames and PartyFrames.FindButtonByUnit
            and PartyFrames.FindButtonByUnit(unit)
        local indicator = button and button.indicators and button.indicators.nameText
        if indicator and indicator._sfNameUpdater then
            indicator._sfNameUpdater()
        end
    end)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        wipe(resolveCache)
        -- playerFullName can be unresolvable at the very first OnEnable (a
        -- secret name during a loading screen), and every lookup for our own
        -- character silently misses while it is nil -- so retry until it takes.
        if not playerFullName then
            CachePlayerIdentity()
            SeedOwnNickname()
        end
        ScheduleBroadcast()
        RefreshAllNames()
    end)
end
