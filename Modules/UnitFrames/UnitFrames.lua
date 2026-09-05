--[[ SquizzFrames UnitFrames Module

    Standalone single-unit frames: player, target, targettarget, focus,
    focustarget. Cast bars live in CastBar.lua (a separate file: the
    UNIT_SPELLCAST_* subsystem and its secret-value handling are involved
    enough to stand on their own). Boss frames, portraits, auras and arena
    frames are still to come.

    WHY THIS IS A SEPARATE MODULE FROM PartyFrames:
    PartyFrames is built entirely around SecureGroupHeaderTemplate, which does
    unit assignment, RegisterUnitWatch, sorting and roster reaction for free.
    None of that applies to a frame whose unit token is fixed for the session,
    so sharing that file would have meant threading "am I a header child?"
    through 4,000 lines. The trade is that this module owns the whole
    lifecycle itself.

    The upside of fixed tokens: the single nastiest bug class in the party code
    -- an AuraContainer bound to the unit a button had at creation while the
    header silently reassigns tokens on every re-sort -- cannot happen here.
    "target" is always "target".

    SECRET NUMBERS ARE THE HARD PART. UnitHealth/UnitPower and friends return
    secret values in combat on 12.1. Every rule below was learned the painful
    way in BuiltIn_Update.lua's CheckHealthText -- read that comment before
    touching FormatToken:
      * NO Lua arithmetic on a health/power read. Not +, not /, not comparison.
      * Percentages come from UnitHealthPercent/UnitPowerPercent (C-level,
        secret-safe), NEVER from cur/max*100.
      * AbbreviateNumbers' RETURN STRING inherits the taint, so it may be
        concatenated and nil-checked but never compared (`s ~= ""` throws).
        Presence is tracked with plain booleans instead.
      * Bars are safe: SetMinMaxValues/SetValue take secrets at the C level.
    This is also why there is no "health deficit" text token -- max minus
    current is arithmetic on a secret, and there is no C-level API for it.
    Offering a token that breaks in combat is worse than not offering it.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F
---@class AceModule
local UnitFrames = SquizzFrames:NewModule("UnitFrames", "AceEvent-3.0")

-- Local state
local frames = {}          -- [unitToken] = frame
local movers = {}          -- [unitToken] = non-secure drag frame
local castBars = {}        -- [unitToken] = cast bar (CastBar.lua)
-- Forward declaration: CreateFrames and the cast bar movers both call this,
-- and both are defined above it. Without the declaration here they would
-- capture a nil global instead of the local.
local ApplyLayout
local initialized = false
local applyingLayout = false
local applyRetryFrame
local totPoller
local anchorRetries = 0    -- see the cast bar anchor retry in ApplyLayout

-- Every unit this module spawns, in creation order. The token IS the settings
-- key (profile.unitFrames.frames[token]) and the frame's "unit" attribute --
-- one string, no mapping table to keep in sync.
local UNITS = {"player", "target", "targettarget", "focus", "focustarget"}

-- Boss frames. Read from the global rather than hardcoded to 5: it is
-- Blizzard's own count and has changed before.
local BOSS_COUNT = _G.MAX_BOSS_FRAMES or 5
local BOSS_UNITS = {}
for i = 1, BOSS_COUNT do BOSS_UNITS[i] = "boss" .. i end

-- Everything this module spawns. Boss frames differ from the five singles in
-- exactly two ways -- they SHARE one settings table, and they stack -- so they
-- ride the same creation, update, click-cast and edit-mode paths and only
-- diverge where those two facts matter.
local ALL_UNITS = {}
for _, u in ipairs(UNITS) do ALL_UNITS[#ALL_UNITS + 1] = u end
for _, u in ipairs(BOSS_UNITS) do ALL_UNITS[#ALL_UNITS + 1] = u end

local function IsBossUnit(unit)
    return unit and unit:match("^boss%d+$") ~= nil
end

-- 1-based position of a boss frame in the stack, or nil.
local function BossIndex(unit)
    local n = unit and unit:match("^boss(%d+)$")
    return n and tonumber(n) or nil
end

-- Where boss frame `idx` sits relative to the stack's anchor (boss1), in raw
-- pixels. Computed from the index rather than by chaining each frame to the
-- previous one, so an encounter that drops a middle boss cannot collapse the
-- spacing of the ones after it.
--
-- Shared by ApplyLayout and the edit-mode drag. It used to live inline in
-- ApplyLayout only, which is why dragging boss1 moved boss1 alone and the
-- rest of the stack did not catch up until the next layout pass (a reload).
local function BossOffset(t, idx)
    if not t or not idx or idx <= 1 then return 0, 0 end
    local w = t.width or 170
    local h = t.height or 34
    local step = t.spacing or 26
    local dir = t.growthDirection or "DOWN"
    local n = idx - 1
    if dir == "UP" then return 0, n * (h + step) end
    if dir == "RIGHT" then return n * (w + step), 0 end
    if dir == "LEFT" then return -n * (w + step), 0 end
    return 0, -n * (h + step) -- DOWN
end

local portraits = {}       -- [unitToken] = portrait holder (Portrait.lua)
local auraRows = {}        -- [unitToken] = {buffs = wrapper, debuffs = wrapper}

-- Which units need a target-of-target style refresh. UNIT_TARGET does fire for
-- "target"/"focus" when their target changes, but it is not reliable for every
-- transition (Blizzard's own CompactUnitFrame.lua carries a "PLEEEEEASE FIX ME"
-- comment about exactly this gap and falls back to an OnUpdate), so these get
-- a cheap backstop poll on top -- see EnsureTotPoller.
local DERIVED_UNITS = {targettarget = "target", focustarget = "focus"}

local function GetProfile()
    return SquizzFrames.db and SquizzFrames.db.profile
end

local function GetConfig()
    local prof = GetProfile()
    return prof and prof.unitFrames
end

-- Boss frames all read ONE shared table (cfg.boss), which is what makes the
-- stack look uniform without five sets of controls to keep in sync.
local function GetFrameConfig(unit)
    local cfg = GetConfig()
    if not cfg then return nil end
    if IsBossUnit(unit) then return cfg.boss end
    return cfg.frames and cfg.frames[unit]
end

-- The health/power bar texture is the SHARED Appearance setting
-- (profile.appearance.general.texture), not a per-frame one: PartyFrames owns
-- the LSM resolution and exposes it publicly for exactly this reuse, which is
-- how PetFrames gets it too. One dropdown on the Appearance tab therefore
-- drives party, pet and unit frames together, and they cannot drift apart.
--
-- Falls back to the stock Blizzard bar if PartyFrames somehow isn't loaded --
-- the same fallback string its own GetBarTexture uses.
local function GetBarTexture()
    local PartyFrames = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    return (PartyFrames and PartyFrames.GetBarTexture and PartyFrames.GetBarTexture())
        or [[Interface\TargetingFrame\UI-StatusBar]]
end

local function ModuleEnabled()
    local cfg = GetConfig()
    return (cfg and cfg.enabled) == true
end

local function FrameEnabled(unit)
    if not ModuleEnabled() then return false end
    local t = GetFrameConfig(unit)
    return (t and t.enabled) ~= false
end

-- Player <-> target mirroring (opt-in, see UnitFrames_Defaults.lua). The map
-- is symmetric so the same code serves a drag of either frame.
--
-- Declared AFTER FrameEnabled, which MirrorPartnerFor calls: as a `local
-- function` above it, that name would resolve to a nil global instead and
-- error the moment somebody dragged a frame.
local MIRROR_PARTNER = {player = "target", target = "player"}

local function MirrorEnabled()
    local cfg = GetConfig()
    return (cfg and cfg.mirrorPlayerTarget) == true
end

-- The partner unit whose position should follow `unit`, or nil. Requires the
-- partner frame to be ENABLED too: mirroring onto a frame nobody can see would
-- silently rewrite its saved position, so turning it back on later would land
-- it somewhere the user never put it.
local function MirrorPartnerFor(unit)
    if not MirrorEnabled() then return nil end
    local partner = MIRROR_PARTNER[unit]
    if not partner then return nil end
    if not FrameEnabled(unit) or not FrameEnabled(partner) then return nil end
    return partner
end

-----------------------------------------------------------------------
-- Colour
-----------------------------------------------------------------------

-- Reaction colouring for NPCs, class colouring for players. Deliberately in
-- that order of preference and with no "colour NPCs by class" option: an NPC
-- has no class, and UnitClass on one returns something meaningless.
--
-- UnitClass/UnitReaction are on the 12.1 secret-value list when the unit's
-- identity is secret, so every read is nil-guarded and falls through to the
-- custom colour rather than being trusted. A secret classFile used as a table
-- key into RAID_CLASS_COLORS is exactly the kind of indexing that throws.
local function ResolveHealthColor(unit, t)
    local r, g, b = 0.2, 0.6, 0.2
    local custom = t and t.healthCustomColor
    if custom then r, g, b = custom[1] or r, custom[2] or g, custom[3] or b end

    if not unit or not UnitExists(unit) then return r, g, b end

    -- type() IS NOT A SECRET CHECK. A secret string still reports "string",
    -- so `type(classFile) == "string"` happily lets a secret through and the
    -- RAID_CLASS_COLORS lookup then dies with "attempted to index a table that
    -- cannot be indexed with secret keys". F.IsValueNonSecret is the only
    -- correct guard, and F.GetClassColor already applies it -- it exists so
    -- this table index is gated in exactly ONE place. Use it, don't re-roll it.
    if t and t.healthClassColor and UnitIsPlayer(unit) then
        if F.IsValueNonSecret(F.GetClassFile(unit)) then
            local c = F.GetClassColor(unit)
            if c then return c.r, c.g, c.b end
        end
        -- Class is secret (12.1 identity restriction). Fall through to the
        -- user's configured colour rather than F.GetClassColor's white, which
        -- would read as a bug rather than as "unknown".
        return r, g, b
    end

    if t and t.healthReactionColor and not UnitIsPlayer(unit) then
        local reaction = UnitReaction(unit, "player")
        -- Same trap on the numeric side: `reaction >= 5` on a secret number
        -- throws just as hard as the table index above.
        if F.IsValueNonSecret(reaction) and type(reaction) == "number" then
            if reaction >= 5 then return 0.2, 0.65, 0.2      -- friendly
            elseif reaction == 4 then return 0.85, 0.8, 0.2  -- neutral
            else return 0.75, 0.2, 0.2 end                   -- hostile
        end
    end

    return r, g, b
end

-----------------------------------------------------------------------
-- Text tokens
-----------------------------------------------------------------------

-- Render one content token to a string, or nil when it has nothing to show.
--
-- EVERY branch here obeys the secret-number rules in this file's header.
-- Returning nil (rather than "") for "nothing" matters: the caller cannot
-- compare the returned string against "" without risking a secret-string
-- comparison error, so absence has to be signalled out of band.
local function FormatToken(unit, token)
    if not token or token == "none" then return nil end
    if not unit or not UnitExists(unit) then return nil end

    if token == "name" then
        -- Nicknames, exactly as the party nameText indicator does. N:Resolve
        -- returns a plain string or nil and the two never blend -- see
        -- Nicknames.lua's header for why `nickname or name` is a crash.
        --
        -- Resolve is unit-agnostic (it matches on name/realm, not on token),
        -- so this works for "player" too: a nickname you have set for yourself
        -- shows on your own frame. Purely cosmetic and local -- nothing about
        -- this changes what anybody else sees.
        local t = GetFrameConfig(unit)
        if not t or t.useNicknames ~= false then
            -- COLON call. N:Resolve(unit) is N.Resolve(N, unit); writing
            -- N.Resolve(unit) passes the token as `self`, leaves `unit` nil,
            -- and the function's own nil-guard then returns nil every single
            -- time -- a nickname that silently never appears.
            local N = SquizzFrames.modules and SquizzFrames.modules["Nicknames"]
            if N and N.Resolve then
                local nick = N:Resolve(unit)
                if nick then return nick end
            end
        end
        return UnitName(unit)

    elseif token == "health" then
        local cur = UnitHealth(unit, true)
        if cur and AbbreviateNumbers then return AbbreviateNumbers(cur) end

    elseif token == "healthPercent" then
        if UnitHealthPercent and CurveConstants then
            local pct = UnitHealthPercent(unit, true, CurveConstants.ScaleTo100)
            if pct then return string.format("%.0f%%", pct) end
        end

    elseif token == "healthBoth" or token == "healthMax" then
        local hasCur, curStr = false, nil
        local cur = UnitHealth(unit, true)
        if cur and AbbreviateNumbers then curStr = AbbreviateNumbers(cur); hasCur = true end

        if token == "healthMax" then
            local hasMax, maxStr = false, nil
            local max = UnitHealthMax(unit, true)
            if max and AbbreviateNumbers then maxStr = AbbreviateNumbers(max); hasMax = true end
            if hasCur and hasMax then return curStr .. " / " .. maxStr end
            if hasCur then return curStr end
            if hasMax then return maxStr end
        else
            local hasPct, pctStr = false, nil
            if UnitHealthPercent and CurveConstants then
                local pct = UnitHealthPercent(unit, true, CurveConstants.ScaleTo100)
                if pct then pctStr = string.format("%.0f%%", pct); hasPct = true end
            end
            if hasCur and hasPct then return curStr .. "  " .. pctStr end
            if hasCur then return curStr end
            if hasPct then return pctStr end
        end

    elseif token == "power" then
        local pType = UnitPowerType(unit)
        local cur = UnitPower(unit, pType)
        if cur and AbbreviateNumbers then return AbbreviateNumbers(cur) end

    elseif token == "powerPercent" then
        -- NOTE the pType second argument: UnitPowerPercent's signature is
        -- (unit, powerType, unmodified, curve), NOT UnitHealthPercent's
        -- (unit, unmodified, curve). Copying the health call shape here gives
        -- a silently wrong reading rather than an error.
        if UnitPowerPercent and CurveConstants then
            local pType = UnitPowerType(unit)
            local pct = UnitPowerPercent(unit, pType, true, CurveConstants.ScaleTo100)
            if pct then return string.format("%.0f%%", pct) end
        end

    elseif token == "level" or token == "levelClass" then
        -- Every read below is gated with F.IsValueNonSecret before it is
        -- COMPARED. type() does not detect secrets (see ResolveHealthColor),
        -- and `level < 0` / `classification == "elite"` on a secret throws the
        -- same way a secret table key does. Concatenation is safe, comparison
        -- is not -- which is why the class name needs no guard but the
        -- classification does.
        local level = UnitLevel(unit)
        local levelStr
        if F.IsValueNonSecret(level) and type(level) == "number" then
            -- -1 is Blizzard's "level is above what you can determine".
            levelStr = (level < 0) and "??" or tostring(level)
        end
        if token == "level" then return levelStr end

        local suffix
        if UnitIsPlayer(unit) then
            -- Only ever concatenated, never compared, so a secret class name
            -- flows through harmlessly and renders C-side.
            local className = UnitClass(unit)
            if className then suffix = className end
        else
            local classification = UnitClassification(unit)
            if F.IsValueNonSecret(classification) then
                if classification == "elite" or classification == "worldboss" then
                    suffix = "Elite"
                elseif classification == "rareelite" or classification == "rare" then
                    suffix = "Rare"
                end
            end
        end
        if levelStr and suffix then return levelStr .. " " .. suffix end
        return levelStr or suffix
    end

    return nil
end

-----------------------------------------------------------------------
-- Element updates
-----------------------------------------------------------------------

local function UpdateHealth(frame)
    local unit = frame.unit
    if not unit or not UnitExists(unit) then return end
    local bar = frame.healthBar
    if not bar then return end

    -- Straight to the C level, no arithmetic -- these two calls are the whole
    -- reason a health BAR works in combat while health TEXT needed a rewrite.
    bar:SetMinMaxValues(0, UnitHealthMax(unit) or 1)
    bar:SetValue(UnitHealth(unit) or 0)

    local t = GetFrameConfig(unit)
    local r, g, b = ResolveHealthColor(unit, t)
    bar:SetStatusBarColor(r, g, b, 1)

    -- Disconnected/dead get a flat grey so a stale bar can't read as a live
    -- one. A plain truthiness test is safe on a secret value even if this one
    -- ever joins the restricted set (it is COMPARISON and table-indexing that
    -- throw, not `if x then`), so this needs no IsValueNonSecret guard.
    if not UnitIsConnected(unit) then
        bar:SetStatusBarColor(0.4, 0.4, 0.4, 1)
    end
end

local function UpdatePower(frame)
    local unit = frame.unit
    if not unit or not UnitExists(unit) then return end
    local bar = frame.powerBar
    if not bar then return end

    local t = GetFrameConfig(unit)
    if not t or (t.powerHeight or 0) <= 0 then
        bar:Hide()
        return
    end
    bar:Show()

    local pType = UnitPowerType(unit)
    bar:SetMinMaxValues(0, UnitPowerMax(unit, pType) or 1)
    bar:SetValue(UnitPower(unit, pType) or 0)

    -- Power colour: class_color > custom_color > Blizzard's stock per-power-
    -- type colour (mana blue, rage red, ...). The same resolution the party
    -- frames use, reading the SAME appearance setting, so one control drives
    -- both and they cannot drift. Anything that isn't "class_color"/
    -- "custom_color" -- including a nil powerColor on a fresh profile -- falls
    -- through to the per-power-type branch, so "blizzard_default" needs no
    -- explicit case of its own.
    --
    -- F.GetPowerColor returns a KEYED table {r=,g=,b=}, NOT an array. Indexing
    -- it as colors[1] yields nil silently, and every power bar then comes out
    -- the same hardcoded fallback regardless of the unit's actual power type.
    local prof = GetProfile()
    local col = prof and prof.appearance and prof.appearance.powerBar
        and prof.appearance.powerBar.powerColor
    if col and col[1] == "class_color" then
        local cc = F.GetClassColor(unit)
        if cc then bar:SetStatusBarColor(cc.r, cc.g, cc.b, 0.8) end
    elseif col and col[1] == "custom_color" then
        bar:SetStatusBarColor(col[2] or 1, col[3] or 1, col[4] or 1, 0.8)
    else
        local colors = F.GetPowerColor and F.GetPowerColor(unit)
        if colors then bar:SetStatusBarColor(colors.r, colors.g, colors.b, 0.8) end
    end
end

-- Text elements. The settings live at t.texts[element]; the FontString lives
-- at frame[element .. "Text"] (nameText/healthText/powerText/levelText, from
-- UnitFrameButton.xml's parentKeys). One derived name rather than two parallel
-- key sets to keep in step.
-- Read from the defaults file (loaded earlier, per the .toc) rather than
-- redeclared, so the renderer, the options page and the migration all walk one
-- list. The literal is only a guard against load order changing under us.
local TEXT_ELEMENTS = SquizzFrames.UNITFRAME_TEXT_ELEMENTS
    or {"name", "health", "power", "level"}

local function TextFontString(frame, element)
    return frame[element .. "Text"]
end

-- justifyH follows the anchor, so a right-anchored readout grows leftward from
-- its corner instead of running off the frame. Without this a wide value like
-- "1.2M / 1.4M" anchored RIGHT still laid out left-justified from the anchor
-- point and overflowed the frame's edge.
local function TextJustify(anchor)
    if not anchor then return "CENTER" end
    if anchor:find("LEFT") then return "LEFT" end
    if anchor:find("RIGHT") then return "RIGHT" end
    return "CENTER"
end

-- How far to push a readout clear of an INSIDE portrait. Only elements on the
-- portrait's own side move; everything else keeps its configured offset.
local function TextInsetShift(anchor, inset, portraitSide)
    if not inset or inset <= 0 or not anchor or not portraitSide then return 0 end
    if portraitSide == "LEFT" and anchor:find("LEFT") then return inset end
    if portraitSide == "RIGHT" and anchor:find("RIGHT") then return -inset end
    return 0
end

-- Resolved colour for one element. classColor borrows the health bar's own
-- resolution (class for players, reaction for NPCs) and defaults OFF -- see
-- DefaultText in UnitFrames_Defaults.lua for why.
local function TextColor(unit, t, elem)
    if elem.classColor and unit and UnitExists(unit) then
        local r, g, b = ResolveHealthColor(unit, t)
        return r, g, b, 1
    end
    local c = elem.color
    if c then return c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1 end
    return 1, 1, 1, 1
end

local function UpdateTextElement(frame, element)
    local fs = TextFontString(frame, element)
    if not fs then return end
    local unit = frame.unit
    local t = GetFrameConfig(unit)
    local elem = t and t.texts and t.texts[element]
    if not elem or not elem.enabled then
        fs:SetText("")
        return
    end

    local text = FormatToken(unit, elem.format)
    if not text then
        fs:SetText("")
        return
    end
    fs:SetText(text)
    fs:SetTextColor(TextColor(unit, t, elem))
end

local function UpdateTexts(frame)
    for _, element in ipairs(TEXT_ELEMENTS) do
        UpdateTextElement(frame, element)
    end
end

local function UpdateFrame(frame)
    if not frame or not frame.unit then return end
    if not UnitExists(frame.unit) then return end
    UpdateHealth(frame)
    UpdatePower(frame)
    UpdateTexts(frame)

    local P = SquizzFrames.UnitFramePortrait
    local holder = portraits[frame.unit]
    if P and holder then
        P.Update(holder, frame.unit, GetFrameConfig(frame.unit))
    end
end

local function UpdateAll()
    for _, frame in pairs(frames) do
        UpdateFrame(frame)
    end
end

-----------------------------------------------------------------------
-- Frame creation
-----------------------------------------------------------------------

-- OnLoad for the XML template. Mirrors PetButton.lua's own OnLoad -- see that
-- file for the fuller commentary on each step; the reasoning is identical.
function SquizzFramesUnitFrame_OnLoad(self)
    local name = self:GetName()
    if name then _G[name] = self end

    self:SetFrameStrata("MEDIUM")

    -- Hover ping support (EllesmereUIRaidFrames-derived recipe, same as
    -- UnitButton.lua and PetButton.lua). Without it a mouseover ping falls
    -- through these frames to the 3D world.
    if PingableType_UnitFrameMixin then
        Mixin(self, PingableType_UnitFrameMixin)
        self:SetAttribute("ping-receiver", true)
        self.GetTargetPingGUID = function(btn)
            local u = btn.unit or btn:GetAttribute("unit")
            if u and UnitExists(u) then return UnitGUID(u) end
        end
    end

    self.healthBar = self.healthBar or (name and _G[name .. "HealthBar"])
    self.powerBar  = self.powerBar  or (name and _G[name .. "PowerBar"])
    self.nameText   = self.nameText   or (name and _G[name .. "NameText"])
    self.healthText = self.healthText or (name and _G[name .. "HealthText"])
    self.powerText  = self.powerText  or (name and _G[name .. "PowerText"])
    self.levelText  = self.levelText  or (name and _G[name .. "LevelText"])

    if self.healthBar then
        self.healthBar:SetMinMaxValues(0, 1)
        self.healthBar:SetValue(0)
        if not self.healthBackdrop then
            local backdrop = self.healthBar:CreateTexture(nil, "BACKGROUND", nil, -1)
            backdrop:SetAllPoints(self)
            backdrop:SetColorTexture(0, 0, 0, 0.6)
            self.healthBackdrop = backdrop
        end
    end
    if self.powerBar then
        self.powerBar:SetMinMaxValues(0, 1)
        self.powerBar:SetValue(0)
        if not self.powerBackdrop then
            local backdrop = self.powerBar:CreateTexture(nil, "BACKGROUND", nil, -1)
            backdrop:SetAllPoints(self.powerBar)
            backdrop:SetColorTexture(0, 0, 0, 1)
            self.powerBackdrop = backdrop
        end
    end

    -- Click-casting: installs the secure hover snippets. The actual
    -- typeN/spellN values are written by ClickCasting:ApplyToAll once
    -- CollectButtons picks this frame up via UnitFrames:IterateButtons.
    local cc = SquizzFrames.modules and SquizzFrames.modules["ClickCasting"]
    if cc and cc.SetBindingClicks then
        cc.SetBindingClicks(self)
    end

    -- HookScript, never SetScript -- see the template's Scripts comment.
    self:HookScript("OnEnter", function(btn)
        btn._sfHovered = true
        local prof = GetProfile()
        if prof and prof.tooltipsEnabled == false then return end
        local u = btn.unit or btn:GetAttribute("unit")
        if u and UnitExists(u) then
            GameTooltip_SetDefaultAnchor(GameTooltip, btn)
            GameTooltip:SetUnit(u)
            GameTooltip:Show()
        end
    end)
    self:HookScript("OnLeave", function(btn)
        btn._sfHovered = false
        if GameTooltip then GameTooltip:Hide() end
    end)
end

-- One-time, out-of-combat creation of every unit frame. Unit tokens are fixed
-- for the session, so the "unit" attribute is set exactly once here and never
-- rewritten -- the same guarantee PetFrames relies on, and the reason this
-- module is immune to the AuraContainer rebinding problem.
local function CreateFrames()
    if next(frames) then return end
    for _, unit in ipairs(ALL_UNITS) do
        local frameName = "SquizzFramesUnitFrame" .. unit:gsub("^%l", string.upper)
        local frame = CreateFrame("Button", frameName, UIParent, "SquizzFramesUnitFrameTemplate")
        frame:SetAttribute("unit", unit)
        frame.unit = unit
        -- Same reason PetFrames does this: a Button only answers LeftButtonUp
        -- by default, so every right/middle/extra-button click-cast binding
        -- would silently do nothing. Must be out of combat.
        frame:RegisterForClicks("AnyUp")
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        frame:Hide()
        frames[unit] = frame

        -- Portrait and cast bar are both created for every unit even when
        -- disabled: they are plain (non-secure) frames, so they cost nothing
        -- while hidden, and creating them lazily would mean creating a frame
        -- mid-combat the first time somebody enabled one.
        local P = SquizzFrames.UnitFramePortrait
        if P and P.Create then
            portraits[unit] = P.Create(frame, unit)
            -- PlayerModel widgets DROP their model while hidden, and these
            -- frames hide constantly (no target, loading screens, a boss
            -- despawning). Nothing else fires on the way back -- the unit
            -- token and its GUID are both unchanged -- so the re-show itself
            -- has to be the trigger, or a 3D portrait comes back empty and
            -- stays that way. 2D textures survive Hide/Show and do not need
            -- this, but re-running the whole update is cheap and keeps one
            -- path. HookScript, never SetScript: these are secure frames.
            frame:HookScript("OnShow", function(f) UpdateFrame(f) end)
        end

        -- The frame going away must take its cast bar with it. The bar is
        -- parented to UIParent rather than to the frame (so it is not
        -- combat-protected), which means it does NOT inherit the hide -- a
        -- boss frame vanishing at the end of an encounter otherwise left its
        -- cast bar floating on screen.
        --
        -- Aura rows need no equivalent: their wrappers ARE children of the
        -- frame, so they hide with it.
        frame:HookScript("OnHide", function(f)
            local CBmod = SquizzFrames.UnitFrameCastBar
            local bar = f.unit and castBars[f.unit]
            if CBmod and bar then CBmod.StopCast(bar, f.unit) end
        end)

        -- Aura rows. The WRAPPERS are cheap and made up front; the real
        -- AuraContainers are requested lazily by Auras.ApplySettings only for
        -- rows actually switched on, so a profile with no auras never pays for
        -- twenty containers' worth of pre-created buttons.
        local A = SquizzFrames.UnitFrameAuras
        if A and A.Create then
            auraRows[unit] = {
                buffs = A.Create(frame, unit, "buffs"),
                debuffs = A.Create(frame, unit, "debuffs"),
            }
        end

        local CB = SquizzFrames.UnitFrameCastBar
        if CB and CB.Create then
            castBars[unit] = CB.Create(frame, unit)
            CB.CreateMover(castBars[unit], unit,
                function()
                    local t = GetFrameConfig(unit)
                    return t and t.castBar
                end,
                function() ApplyLayout() end)
        end
    end
end

-----------------------------------------------------------------------
-- Movers (edit mode)
-----------------------------------------------------------------------

-- A separate non-secure frame on top of each unit frame. Secure buttons
-- swallow mouse input, so the drag handler cannot live on the frame itself --
-- the same reason PartyFrames and PetFrames both use a dedicated mover.
local function CreateMover(unit)
    if movers[unit] then return movers[unit] end
    local frame = frames[unit]
    if not frame then return nil end

    local mover = CreateFrame("Frame", "SquizzFramesUnitFrameMover" .. unit, UIParent, "BackdropTemplate")
    mover:SetAllPoints(frame)
    mover:SetFrameStrata("DIALOG")
    mover:EnableMouse(true)
    mover:SetMovable(true)
    mover:Hide()

    local border = mover:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints(mover)
    border:SetColorTexture(0.33, 0.77, 0.99, 0.25)
    mover.border = border

    local label = mover:CreateFontString(nil, "OVERLAY")
    label:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    label:SetPoint("CENTER")
    label:SetText(unit)
    mover.label = label

    local dragging, dragX, dragY = false, 0, 0
    local StopDrag

    -- Deliberately NOT RegisterForDrag: Blizzard's drag detection waits for the
    -- cursor to clear a threshold first, which reads as the frame refusing to
    -- move. Start on the press, exactly as the other two movers do.
    local function StartDrag(self)
        if dragging then return end
        dragging = true
        local t = GetFrameConfig(unit)
        local uiScale = UIParent:GetEffectiveScale()
        local startX, startY = GetCursorPosition()
        startX, startY = startX / uiScale, startY / uiScale
        local sw, sh = GetScreenWidth(), GetScreenHeight()
        local offX = (sw / 2 + ((t and t.anchorX) or 0)) - startX
        local offY = (sh / 2 + ((t and t.anchorY) or 0)) - startY
        dragX = (t and t.anchorX) or 0
        dragY = (t and t.anchorY) or 0

        self:SetScript("OnUpdate", function(f)
            -- Self-heal for a mouse-up we never saw (cursor left the screen),
            -- which would otherwise glue the frame to the cursor.
            if not IsMouseButtonDown("LeftButton") then StopDrag(f) return end
            local cx, cy = GetCursorPosition()
            local s = UIParent:GetEffectiveScale()
            cx, cy = cx / s, cy / s
            local w, h = GetScreenWidth(), GetScreenHeight()
            dragX = (cx + offX) - w / 2
            dragY = (cy + offY) - h / 2
            local unitFrame = frames[unit]
            if unitFrame then
                -- Positioning a SECURE frame is combat-protected. Dragging only
                -- happens in edit mode, but a fight can start mid-drag.
                if InCombatLockdown() then StopDrag(f) return end
                local fs = unitFrame:GetScale() or 1
                unitFrame:ClearAllPoints()
                unitFrame:SetPoint("CENTER", UIParent, "CENTER", dragX / fs, dragY / fs)

                -- Boss stack: dragging boss1 carries 2..N with it. Without
                -- this only the dragged frame moved and the rest stayed put
                -- until the next full layout pass, which in practice meant a
                -- reload -- they were never actually mispositioned, they just
                -- had not been told yet.
                if BossIndex(unit) then
                    local bt = GetFrameConfig(unit)
                    for _, bu in ipairs(BOSS_UNITS) do
                        local bf = frames[bu]
                        if bf and bu ~= unit then
                            local bdx, bdy = BossOffset(bt, BossIndex(bu))
                            local bs = bf:GetScale() or 1
                            bf:ClearAllPoints()
                            bf:SetPoint("CENTER", UIParent, "CENTER",
                                (dragX + bdx) / bs, (dragY + bdy) / bs)
                        end
                    end
                end

                -- Mirrored partner moves LIVE alongside the drag, not just on
                -- release: watching only one frame move and then seeing the
                -- other jump at the end makes the feature feel broken.
                local partner = MirrorPartnerFor(unit)
                local partnerFrame = partner and frames[partner]
                if partnerFrame then
                    local ps = partnerFrame:GetScale() or 1
                    partnerFrame:ClearAllPoints()
                    partnerFrame:SetPoint("CENTER", UIParent, "CENTER",
                        -dragX / ps, dragY / ps)
                    local pm = movers[partner]
                    if pm then pm:SetAllPoints(partnerFrame) end
                end
            end
        end)
    end

    function StopDrag(self)
        if not dragging then return end
        dragging = false
        self:SetScript("OnUpdate", nil)
        local t = GetFrameConfig(unit)
        if t then
            t.anchorX = dragX
            t.anchorY = dragY
        end

        -- Save the partner too. ApplyLayout normalises target from player
        -- whenever mirroring is on, so writing only the dragged frame would
        -- work when you drag the player and silently snap back when you drag
        -- the target.
        local partner = MirrorPartnerFor(unit)
        local pt = partner and GetFrameConfig(partner)
        if pt then
            pt.anchorX = -dragX
            pt.anchorY = dragY
        end
    end

    mover:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then StartDrag(self) end
    end)
    mover:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then StopDrag(self) end
    end)
    mover:SetScript("OnHide", function(self) StopDrag(self) end)

    movers[unit] = mover
    return mover
end

function UnitFrames:SetEditMode(enabled)
    local CB = SquizzFrames.UnitFrameCastBar
    for _, unit in ipairs(ALL_UNITS) do
        local mover = movers[unit] or (frames[unit] and CreateMover(unit))
        if mover then
            if enabled and FrameEnabled(unit) then
                -- SetAllPoints works on a HIDDEN frame -- it still has a valid
                -- rect -- which is what lets boss frames be positioned outside
                -- an encounter, when the units do not exist and the frames are
                -- therefore invisible.
                mover:SetAllPoints(frames[unit])
                -- Only the FIRST boss frame is draggable. The rest are placed
                -- by index off the shared anchor, so dragging one would apply
                -- boss1's maths to a frame that is not at boss1's position and
                -- make the whole stack jump. They stay as previews so you can
                -- still see where the stack lands.
                local idx = BossIndex(unit)
                mover:EnableMouse(idx == nil or idx == 1)
                mover:Show()
            else
                mover:Hide()
            end
        end
        -- Detached cast bars get their own handle. CastBar.SetEditMode does
        -- the free/enabled check itself, so a frame-anchored bar (which has no
        -- position of its own) never grows a handle that does nothing.
        local bar = castBars[unit]
        if CB and bar then
            local t = GetFrameConfig(unit)
            CB.SetEditMode(bar, enabled and FrameEnabled(unit), t and t.castBar)
        end
    end
end

-----------------------------------------------------------------------
-- Layout
-----------------------------------------------------------------------

-- Font + per-slot anchoring. Declared before ApplyLayout (its only caller) so
-- it stays a file-local: as a global it would resolve fine at call time but
-- would also be reachable, and overwritable, from every other addon.
-- `inset` is the width an INSIDE portrait occupies, and `portraitSide` which
-- edge it sits on. Text on that side is pushed clear of it; text on the other
-- side is untouched. Both are 0/ignored when there is no inside portrait.
local function ApplyFrameFont(frame, t, inset, portraitSide)
    local fontFile = (F.ResolveFontFile and F.ResolveFontFile(t.font and t.font[1]))
        or "Fonts\\FRIZQT__.TTF"
    local outline = (t.font and t.font[3]) or "OUTLINE"
    inset = inset or 0

    for _, element in ipairs(TEXT_ELEMENTS) do
        local fs = TextFontString(frame, element)
        local cfg = t.texts and t.texts[element]
        if fs and cfg then
            fs:SetFont(fontFile, cfg.size or 12, outline)
            local anchor = cfg.anchor or "CENTER"
            fs:SetJustifyH(TextJustify(anchor))
            fs:ClearAllPoints()
            -- Anchored to the HEALTH bar, not the whole frame: with a power
            -- bar present, centring on the frame would sit the text
            -- noticeably low. This keeps text optically centred on the health
            -- bar regardless of the power bar's height.
            local anchorTo = frame.healthBar or frame
            local x = (cfg.x or 0) + TextInsetShift(anchor, inset, portraitSide)
            fs:SetPoint(anchor, anchorTo, anchor, x, cfg.y or 0)
        end
    end
end

-- Combat-guarded exactly like PartyFrames' ApplyLayout and PetFrames'
-- ApplyPetLayout: these are secure frames carrying a "unit" attribute, so
-- SetPoint/SetSize on them is protected once combat starts, and a
-- schedule-time-only check misses combat beginning before a deferred call runs.
function ApplyLayout()
    if applyingLayout then return end
    if InCombatLockdown() then
        if not applyRetryFrame then
            applyRetryFrame = CreateFrame("Frame")
            applyRetryFrame:SetScript("OnEvent", function(self)
                self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                ApplyLayout()
            end)
        end
        applyRetryFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    if not next(frames) then return end
    applyingLayout = true

    local prof = GetProfile()
    local scale = (prof and prof.appearance and prof.appearance.general
                   and prof.appearance.general.scale) or 1.0

    -- Normalise the mirrored pair BEFORE placing anything, with player as the
    -- authority. This is what makes ticking the option take effect
    -- immediately: without it the target would keep whatever asymmetric
    -- position it already had until the next time somebody dragged one of
    -- them. Dragging the TARGET still works, because StopDrag writes both
    -- anchors, so player already holds the mirrored value by the time this
    -- runs.
    if MirrorPartnerFor("player") then
        local pt = GetFrameConfig("player")
        local tt = GetFrameConfig("target")
        if pt and tt then
            tt.anchorX = -(pt.anchorX or 0)
            tt.anchorY = pt.anchorY or 0
        end
    end

    for _, unit in ipairs(ALL_UNITS) do
        local frame = frames[unit]
        local t = GetFrameConfig(unit)
        if frame and t then
            if not FrameEnabled(unit) then
                UnregisterUnitWatch(frame)
                frame:Hide()
            else
                local w = t.width or 180
                local h = t.height or 46
                local ph = t.powerHeight or 0
                local gap = (ph > 0) and (t.powerGap or 1) or 0

                -- Bar texture is applied here rather than in UpdateHealth/
                -- UpdatePower: it changes only on a settings edit, and both of
                -- those run on every health tick.
                local barTexture = GetBarTexture()
                if frame.healthBar then frame.healthBar:SetStatusBarTexture(barTexture) end
                if frame.powerBar then frame.powerBar:SetStatusBarTexture(barTexture) end

                frame:SetScale(scale)
                frame:SetSize(w, h)
                frame:ClearAllPoints()

                -- The stack: anchorX/anchorY place boss1 and every later frame
                -- steps off it (BossOffset). Returns 0,0 for everything else.
                local dx, dy = BossOffset(t, BossIndex(unit))
                frame:SetPoint("CENTER", UIParent, "CENTER",
                    ((t.anchorX or 0) + dx) / scale, ((t.anchorY or 0) + dy) / scale)

                -- The health bar is anchored TOP-LEFT/RIGHT in XML and given
                -- its height here, so the power bar (anchored to the bottom)
                -- and the gap between them come out of the frame's total
                -- height rather than overflowing it.
                if frame.healthBar then
                    frame.healthBar:SetHeight(math.max(1, h - ph - gap))
                end
                if frame.powerBar then
                    if ph > 0 then
                        frame.powerBar:SetHeight(ph)
                        frame.powerBar:Show()
                    else
                        frame.powerBar:Hide()
                    end
                end

                -- Portrait before the font pass: an INSIDE portrait eats into
                -- the space the text has, and ApplyFrameFont needs that inset.
                local P = SquizzFrames.UnitFramePortrait
                local inset = 0
                if P and portraits[unit] then
                    inset = P.ApplySettings(portraits[unit], frame, t) or 0
                end

                local pside = (t.portrait and t.portrait.side) or "LEFT"
                ApplyFrameFont(frame, t, inset, pside)

                -- Aura rows. Requested here rather than at creation so a
                -- container only exists for a row that is actually on.
                local A = SquizzFrames.UnitFrameAuras
                local rows = auraRows[unit]
                if A and rows then
                    A.ApplySettings(rows.buffs, frame, t, "buffs")
                    A.ApplySettings(rows.debuffs, frame, t, "debuffs")
                end

                RegisterUnitWatch(frame)
            end

            -- Cast bar settings are applied for DISABLED frames too, so its
            -- own enabled=false path runs and hides a bar left over from
            -- before the frame was switched off.
            local CB = SquizzFrames.UnitFrameCastBar
            local bar = castBars[unit]
            if CB and bar then
                if FrameEnabled(unit) then
                    CB.ApplySettings(bar, frame, t, GetBarTexture())
                    -- Re-derive immediately: enabling a bar mid-cast, or a
                    -- settings change during one, should show the cast in
                    -- progress rather than waiting for the next one.
                    if t.castBar and t.castBar.enabled then
                        CB.StartCast(bar, unit)
                    end
                else
                    CB.ApplySettings(bar, frame, {castBar = {enabled = false}})
                end
            end
        end
    end

    applyingLayout = false

    -- A cast bar asked to anchor to a frame that does not exist yet -- the
    -- Cooldown Manager viewers are load-on-demand, so the global is genuinely
    -- nil until Blizzard_CooldownViewer loads. Retry a few times rather than
    -- leaving the bar on its fallback for the session; the counter stops this
    -- becoming a permanent 2s poll when the target simply never appears.
    local CBmod = SquizzFrames.UnitFrameCastBar
    if CBmod and CBmod.anchorRetryWanted then
        CBmod.anchorRetryWanted = false
        anchorRetries = (anchorRetries or 0) + 1
        if anchorRetries <= 5 then
            C_Timer.After(2, function() ApplyLayout() end)
        end
    end

    if SquizzFrames.editMode then
        UnitFrames:SetEditMode(true)
    end

    UpdateAll()
end

-----------------------------------------------------------------------
-- Derived-unit polling (target of target / focus target)
-----------------------------------------------------------------------

-- UNIT_TARGET covers most transitions, but not all of them, and there is no
-- event at all for "my target's target's health changed while the token stayed
-- the same". A 0.25s poll is what Blizzard itself falls back to. Self-stopping:
-- the ticker only exists while at least one derived frame is enabled and shown,
-- so the common case (both disabled) costs nothing.
local function EnsureTotPoller()
    local wanted = false
    for unit in pairs(DERIVED_UNITS) do
        local frame = frames[unit]
        if FrameEnabled(unit) and frame and frame:IsShown() then wanted = true break end
    end

    if not wanted then
        if totPoller then
            totPoller:Cancel()
            totPoller = nil
        end
        return
    end
    if totPoller then return end

    totPoller = C_Timer.NewTicker(0.25, function()
        local stillWanted = false
        for unit in pairs(DERIVED_UNITS) do
            local frame = frames[unit]
            if FrameEnabled(unit) and frame and frame:IsShown() then
                stillWanted = true
                UpdateFrame(frame)
            end
        end
        if not stillWanted and totPoller then
            totPoller:Cancel()
            totPoller = nil
        end
    end)
end

-----------------------------------------------------------------------
-- Public API (ClickCasting + Indicators reach the module through these,
-- matching PartyFrames'/PetFrames' own accessors exactly so the consumers
-- need no special-casing)
-----------------------------------------------------------------------

function UnitFrames:IterateButtons(func)
    for _, frame in pairs(frames) do
        func(frame)
    end
end

function UnitFrames.FindButtonByUnit(unit)
    return frames[unit]
end

function UnitFrames.ApplyLayout()
    ApplyLayout()
end

-- Re-render every frame's text slots. Called by Nicknames.RefreshAllNames --
-- these frames are outside the indicator system, so they have no
-- _sfNameUpdater closure for it to invoke; re-running the text pass is the
-- equivalent.
function UnitFrames.RefreshTexts()
    for _, frame in pairs(frames) do
        if frame.unit and UnitExists(frame.unit) then
            UpdateTexts(frame)
        end
    end
end

-- Exposed for the options-page preview (Preview.lua) so it renders text and
-- colours through the EXACT code the real frames use. A preview with its own
-- copy of the formatting rules is a preview that lies the moment either side
-- changes -- and this one has already had to encode a pile of secret-value
-- handling that would be miserable to duplicate.
UnitFrames.FormatToken = function(unit, token) return FormatToken(unit, token) end
UnitFrames.ResolveHealthColor = function(unit, t) return ResolveHealthColor(unit, t) end

-- Text-element rendering, likewise shared with the preview. The anchor,
-- justification, portrait-inset and colour rules all have to match the real
-- frame exactly or the preview stops being a preview -- it's the same reason
-- FormatToken is exported rather than reimplemented.
UnitFrames.TEXT_ELEMENTS = TEXT_ELEMENTS
UnitFrames.TextJustify = TextJustify
UnitFrames.TextInsetShift = TextInsetShift
UnitFrames.TextColor = function(unit, t, elem) return TextColor(unit, t, elem) end

function UnitFrames.HasVisibleFrames()
    for _, frame in pairs(frames) do
        if frame:IsShown() then return true end
    end
    return false
end

-----------------------------------------------------------------------
-- Lifecycle
-----------------------------------------------------------------------

function UnitFrames:OnInitialize()
    -- Registered on SELF, never on the SquizzFrames root: CallbackHandler keys
    -- by (owner, message) and keeps exactly one handler per pair, so
    -- registering these on the addon object would silently replace
    -- PartyFrames'/PetFrames' handlers for the same messages. This bit the
    -- project twice already -- see CLAUDE.md's "Event/Message Owner Collisions".
    self:RegisterMessage("UnitFramesChanged", function()
        ApplyLayout()
        EnsureTotPoller()
    end)
    self:RegisterMessage("ProfileChanged", function()
        ApplyLayout()
        EnsureTotPoller()
    end)
    -- The shared Appearance settings (bar texture above all) fire
    -- LayoutChanged, not UnitFramesChanged -- that dropdown predates this
    -- module and belongs to the party layout. Without this the texture only
    -- took effect on the next reload, which reads as "the setting is ignored".
    -- PetFrames listens for the same message for the same reason.
    self:RegisterMessage("LayoutChanged", function()
        ApplyLayout()
    end)
    self:RegisterMessage("EditModeChanged", function(_, enabled)
        self:SetEditMode(enabled)
    end)
    self:RegisterMessage("LockChanged", function(_, isLocked)
        if isLocked and SquizzFrames.editMode then self:SetEditMode(false) end
    end)
end

function UnitFrames:OnEnable()
    local function init()
        if initialized then
            ApplyLayout()
            EnsureTotPoller()
            return
        end

        CreateFrames()
        ApplyLayout()
        UpdateAll()
        initialized = true

        -- Click-casting: same deterministic first apply PetFrames does, rather
        -- than waiting on an unrelated event to trigger the cascade.
        local cc = SquizzFrames.modules and SquizzFrames.modules["ClickCasting"]
        if cc and cc.ApplyToAll then cc:ApplyToAll() end

        local function onUnitEvent(_, unit)
            local frame = unit and frames[unit]
            if frame then UpdateFrame(frame) end
        end
        self:RegisterEvent("UNIT_HEALTH", onUnitEvent)
        self:RegisterEvent("UNIT_MAXHEALTH", onUnitEvent)
        self:RegisterEvent("UNIT_POWER_UPDATE", onUnitEvent)
        self:RegisterEvent("UNIT_MAXPOWER", onUnitEvent)
        self:RegisterEvent("UNIT_DISPLAYPOWER", onUnitEvent)
        self:RegisterEvent("UNIT_CONNECTION", onUnitEvent)
        self:RegisterEvent("UNIT_NAME_UPDATE", onUnitEvent)
        self:RegisterEvent("UNIT_LEVEL", onUnitEvent)
        self:RegisterEvent("UNIT_FACTION", onUnitEvent)

        -- Token reassignment. RegisterUnitWatch handles the SHOW/HIDE of these
        -- frames on its own; what it does not do is refresh the contents when
        -- the token now points at somebody else, which is exactly what these
        -- three events mean.
        -- A token pointing at somebody new means the cast bar must be
        -- re-derived from scratch, not just left alone: the previous unit's
        -- cast has to clear, and the new one's cast (already in progress, so
        -- no START event is coming) has to appear.
        local function RederiveCast(unit)
            local CB = SquizzFrames.UnitFrameCastBar
            local bar = castBars[unit]
            if not (CB and bar and FrameEnabled(unit)) then return end
            local t = GetFrameConfig(unit)
            if t and t.castBar and t.castBar.enabled then
                CB.StartCast(bar, unit)
            end
        end

        self:RegisterEvent("PLAYER_TARGET_CHANGED", function()
            local f = frames.target;       if f then UpdateFrame(f) end
            local d = frames.targettarget; if d then UpdateFrame(d) end
            RederiveCast("target")
            RederiveCast("targettarget")
            EnsureTotPoller()
        end)
        self:RegisterEvent("PLAYER_FOCUS_CHANGED", function()
            local f = frames.focus;       if f then UpdateFrame(f) end
            local d = frames.focustarget; if d then UpdateFrame(d) end
            RederiveCast("focus")
            RederiveCast("focustarget")
            EnsureTotPoller()
        end)
        -- Fires on the OWNER token when that unit's target changes, which is
        -- the derived frames' primary (if imperfect) signal -- see
        -- EnsureTotPoller for why a poll backs it up.
        self:RegisterEvent("UNIT_TARGET", function(_, unit)
            for derived, owner in pairs(DERIVED_UNITS) do
                if unit == owner then
                    local f = frames[derived]
                    if f then UpdateFrame(f) end
                end
            end
        end)

        -- Vehicle transitions rewrite which unit the frame's secure attribute
        -- resolves to (toggleForVehicle), so the visible contents change
        -- without any unit event firing for them.
        self:RegisterEvent("UNIT_ENTERED_VEHICLE", onUnitEvent)
        self:RegisterEvent("UNIT_EXITED_VEHICLE", onUnitEvent)

        -- Portraits. UNIT_PORTRAIT_UPDATE covers the 2D texture going stale;
        -- UNIT_MODEL_CHANGED is what a 3D portrait needs when the unit's model
        -- is swapped (shapeshift, transformation) under an unchanged token.
        self:RegisterEvent("UNIT_PORTRAIT_UPDATE", onUnitEvent)
        self:RegisterEvent("UNIT_MODEL_CHANGED", onUnitEvent)
        -- No unit argument: it means "portrait art that was not resolvable
        -- before now is". Without it, a portrait that failed the availability
        -- gate (unit not yet streamed) keeps its question-mark fallback until
        -- some unrelated event happens to refresh the frame.
        self:RegisterEvent("PORTRAITS_UPDATED", function()
            for _, frame in pairs(frames) do
                if frame.unit and UnitExists(frame.unit) then UpdateFrame(frame) end
            end
        end)

        -- Boss frames. RegisterUnitWatch drives show/hide off UnitExists, but
        -- it does not refresh CONTENTS when an encounter swaps which NPC is
        -- behind bossN -- that is what these two are for.
        -- UNIT_TARGETABLE_CHANGED additionally fires for a boss phasing out
        -- and back in mid-encounter, where the token never stops existing.
        local function RefreshBossFrames()
            for _, unit in ipairs(BOSS_UNITS) do
                local f = frames[unit]
                if f and FrameEnabled(unit) then UpdateFrame(f) end
            end
        end
        self:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT", RefreshBossFrames)
        self:RegisterEvent("UNIT_TARGETABLE_CHANGED", function(_, unit)
            if IsBossUnit(unit) then
                local f = frames[unit]
                if f then UpdateFrame(f) end
            end
        end)

        -- Cast bars. One handler for the whole UNIT_SPELLCAST_* family,
        -- dispatched by unit and delegated to CastBar's own event mapping so
        -- the event-to-action table lives next to the functions it drives.
        --
        -- arg2 is the castID/castGUID on every one of these events; CastBar
        -- uses it to ignore a stale stop for a cast that already ended.
        local CB = SquizzFrames.UnitFrameCastBar
        if CB then
            -- Deliberately does NOT forward the event's cast identifier: its
            -- argument position differs per event in this family, so there is
            -- no single arg to pass. CastBar re-derives from the API instead
            -- -- see the comment above CastBar.StopCast.
            local function onCastEvent(event, unit)
                local bar = unit and castBars[unit]
                if not bar then return end
                if not FrameEnabled(unit) then return end
                local t = GetFrameConfig(unit)
                if not (t and t.castBar and t.castBar.enabled) then return end
                CB.HandleEvent(bar, unit, event)
            end
            for _, event in ipairs(CB.EVENTS) do
                self:RegisterEvent(event, onCastEvent)
            end

            -- A frame tracked for width matching (the CDM viewers above all)
            -- resizes itself as its contents change, so re-run the layout when
            -- it does. Coalesced through ApplyLayout, which is idempotent.
            CB.SetMatchResizeCallback(function()
                if not applyingLayout then ApplyLayout() end
            end)
        end

        EnsureTotPoller()

        if SquizzFrames.editMode then self:SetEditMode(true) end
    end

    if InCombatLockdown() then
        local waiter = CreateFrame("Frame")
        waiter:RegisterEvent("PLAYER_REGEN_ENABLED")
        waiter:SetScript("OnEvent", function(self)
            self:UnregisterEvent("PLAYER_REGEN_ENABLED")
            init()
        end)
    else
        init()
    end
end

function UnitFrames:OnDisable()
    for _, frame in pairs(frames) do
        UnregisterUnitWatch(frame)
        frame:Hide()
    end
    if totPoller then totPoller:Cancel(); totPoller = nil end
    initialized = false
end

SquizzFrames.modules = SquizzFrames.modules or {}
SquizzFrames.modules["UnitFrames"] = UnitFrames
