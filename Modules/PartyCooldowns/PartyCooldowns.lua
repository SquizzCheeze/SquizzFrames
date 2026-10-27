--[[
    Party Cooldowns: each group member's defensive, external and group-wide
    cooldowns as a row of icons on their party frame. Party and solo only,
    never in a raid (user decision 2026-10-27).

    How a cooldown is seen at all, when a party member's casts are secret in
    instances (measured with /sfcdprobe, 2026-10-27):

      SENSOR  One hidden AuraContainer per (unit, cooldown), one group,
              filtered to the buff the cooldown leaves, maxFrameCount 1 and a
              50000px element width. With the buff up the container grows
              across the screen, so container:IsMouseOver(huge, -huge, 0, 0)
              says "buff up". The answer is ALWAYS secret (out of combat too)
              and is never compared or branched on in Lua.
      LATCH   C_CurveUtil.EvaluateColorValueFromBoolean(bool, a, b) picks a or
              b engine-side. On a reading that is up now and was not up last
              time, it stores "now" as a number (code / 255), otherwise keeps
              the old one -- a secret start time nobody ever reads.
      DRAW    A StatusBar takes that secret start in SetValue, with plain
              min/max of [now - cd, now], so its fill is the share of the
              cooldown left. The shade over the icon is that bar.

    The stored time only has 254 steps, so each timer has two slots that take
    turns: every P seconds (P >= the cooldown) the older slot is wiped and new
    casts go into it. A cast always outlives its own slot's window, so nothing
    running is ever lost. Step size is fixed per spell from the longest
    cooldown any talent can give it.

    Cooldown lengths follow talents: yours from your active loadout, a party
    member's from inspecting them out of combat (one at a time, the way
    Blizzard's inspect frame does it). Until someone is inspected, their spec
    is guessed from their role where the class allows only one answer, and
    talent-only cooldowns are shown in case they have them.

    Known limits, by design of the technique:
      * only cooldowns that leave a buff can be seen (no interrupts)
      * an external goes to whoever in the group can cast it; two members who
        both can will both show it
      * the sensor reads through the cursor: with the cursor outside the game
        window a cast can be missed, or picked up late
      * charges: a timer shows the recharge of the LAST use; how many charges
        are left is not tracked yet
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local PC = SquizzFrames:NewModule("PartyCooldowns", "AceEvent-3.0")
-- NewModule does not put the module on the addon object (see
-- acemodule-not-exposed-on-addon-object); the panel finds it here.
SquizzFrames.PartyCooldowns = PC

local EvalBool = C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean
local WHITE = "Interface\\Buttons\\WHITE8X8"

local TOKENS = { "player", "party1", "party2", "party3", "party4" }
local CODES = 254
local HUGE = 50000
local TICK = 0.1          -- display and read pass
local READS = 3           -- reads after a UNIT_AURA (the container lays out a frame or two later)
local SAFETY = 1          -- every unit is read at least this often regardless
local INSPECT_TIMEOUT = 4
local INSPECT_AGAIN = 300 -- re-inspect a member after this many seconds

------------------------------------------------------------------------
-- Settings (profile.partyCooldowns). Defaults live here only; the panel
-- reads through PC.Get so it can never show one value while the icons use
-- another. Nothing is written until the user changes something.
------------------------------------------------------------------------
local DEFAULTS = {
    enabled = false,
    showSelf = true,
    personal = true,
    external = true,
    group = true,
    side = "BOTTOM",      -- BOTTOM / TOP / LEFT / RIGHT of the party frame
    align = "START",      -- START / CENTER / END along that side
    offsetX = 0,
    offsetY = 0,
    size = 24,
    spacing = 2,
    maxIcons = 8,
    showBorder = true,
    glow = true,          -- gold edge while the buff is up
    shade = 0.7,          -- darkness of the cooldown shade
}
PC.DEFAULTS = DEFAULTS

local function Cfg()
    local p = SquizzFrames.db and SquizzFrames.db.profile
    return p and p.partyCooldowns
end

function PC.Get(key)
    local c = Cfg()
    local v = c and c[key]
    if v == nil then return DEFAULTS[key] end
    return v
end

function PC.Set(key, value)
    local p = SquizzFrames.db and SquizzFrames.db.profile
    if not p then return end
    p.partyCooldowns = p.partyCooldowns or {}
    p.partyCooldowns[key] = value
    SquizzFrames:Fire("PartyCooldownsChanged")
end

local function IsSecret(v)
    return issecretvalue and issecretvalue(v) or false
end

local function Plain(v)
    if v == nil or IsSecret(v) then return nil end
    return v
end

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
local members = {}    -- [token] = { guid, class, spec, ranks }
local known = {}      -- [guid] = { spec, ranks, at }  (inspect / own talents)
local trackers = {}   -- [guid][def.key] = timer, kept across re-sorts
local rows = {}       -- [token] = row frame holding that member's icons
local sensors = {}    -- [token][def.key] = { c, lit, prev, fresh }
local reads = {}      -- [token] = reads still owed
local pendingSensors = false
local testMode = false
local sensorHost
local driver

local function Active()
    if not EvalBool then return false end
    if IsInRaid() then return false end
    return PC.Get("enabled") or testMode
end

------------------------------------------------------------------------
-- Sensors
------------------------------------------------------------------------
local function InitSensorButton(button)
    -- initializeFrame is the only window where calls on an aura button are
    -- always legal (CLAUDE.md section 7). Tiny, and blind to the mouse: only
    -- the layout stride makes the container grow.
    pcall(button.SetSize, button, 1, 1)
    pcall(button.SetMouseClickEnabled, button, false)
    pcall(button.SetMouseMotionEnabled, button, false)
end

local function NewSensor(token, def)
    if not sensorHost then
        sensorHost = CreateFrame("Frame", nil, UIParent)
        sensorHost:SetSize(1, 1)
        sensorHost:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    end
    local ok, c = pcall(CreateFrame, "AuraContainer", nil, sensorHost, "CustomAuraContainerTemplate")
    if not ok or not c then return nil end
    -- Just off the left edge: empty, it is a sliver no cursor reaches.
    c:SetSize(1, 1)
    c:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -20, 0)
    pcall(c.EnableMouse, c, false)
    local okG = pcall(c.AddAuraGroup, c, "cd", "HELPFUL", {
        maxFrameCount = 1,
        candidateFilters = { includeSpellIDs = def.buffSet },
        initializeFrame = InitSensorButton,
        layout = { elementWidth = HUGE, elementHeight = 1, elementSpacing = 0, lineSpacing = 0 },
    })
    if not okG then return nil end
    -- Unit LAST: earlier leaves UNIT_AURA unregistered (CLAUDE.md section 7).
    c:SetUnit(token)
    pcall(c.UpdateAllAuras, c)
    return { c = c, lit = false, prev = false, on = true }
end

-- The sensor for (token, def), built if needed. Containers are only built out
-- of combat; a need found in combat is remembered and met on PLAYER_REGEN_ENABLED.
local function Sensor(token, def)
    sensors[token] = sensors[token] or {}
    local s = sensors[token][def.key]
    if s then
        if not s.on then
            s.on = true
            pcall(s.c.SetEnabled, s.c, true)
            pcall(s.c.UpdateAllAuras, s.c)
            -- A buff already up must not read as a fresh cast.
            local ok, v = pcall(s.c.IsMouseOver, s.c, 1e5, -1e5, 0, 0)
            if ok then s.lit, s.prev = v, v end
        end
        s.used = true
        return s
    end
    if InCombatLockdown() then
        pendingSensors = true
        return nil
    end
    s = NewSensor(token, def)
    if not s then return nil end
    -- Same rule for a brand-new sensor: whatever is up now is not a cast.
    local ok, v = pcall(s.c.IsMouseOver, s.c, 1e5, -1e5, 0, 0)
    if ok then s.lit, s.prev = v, v end
    s.used = true
    sensors[token][def.key] = s
    return s
end

local function ParkUnusedSensors()
    for _, list in pairs(sensors) do
        for _, s in pairs(list) do
            if not s.used and s.on then
                s.on = false
                pcall(s.c.SetEnabled, s.c, false)
            end
            s.used = nil
        end
    end
end

local function ReadToken(token)
    local list = sensors[token]
    if not list then return end
    for _, s in pairs(list) do
        if s.on then
            local ok, v = pcall(s.c.IsMouseOver, s.c, 1e5, -1e5, 0, 0)
            if ok then
                s.prev, s.lit, s.fresh = s.lit, v, true
            end
        end
    end
end

------------------------------------------------------------------------
-- Talents and specs
------------------------------------------------------------------------
-- spellID -> rank for every talent node taken in a trait config. Works on the
-- player's active config and on the inspect config (-1) alike.
local function ReadTraits(configID)
    if not (C_Traits and configID) then return nil end
    local ok, ranks = pcall(function()
        local info = C_Traits.GetConfigInfo(configID)
        if not info or not info.treeIDs then return nil end
        local out = {}
        for _, treeID in ipairs(info.treeIDs) do
            for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
                local n = C_Traits.GetNodeInfo(configID, nodeID)
                if n and n.activeEntry and (n.activeRank or 0) > 0 then
                    local e = C_Traits.GetEntryInfo(configID, n.activeEntry.entryID)
                    local d = e and e.definitionID and C_Traits.GetDefinitionInfo(e.definitionID)
                    if d and d.spellID then out[d.spellID] = n.activeRank end
                end
            end
        end
        return out
    end)
    if ok and ranks and next(ranks) then return ranks end
    return nil
end

local function ReadOwn()
    local guid = Plain(UnitGUID("player"))
    if not guid then return end
    local configID = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
    known[guid] = {
        spec = SquizzFrames.F.GetPlayerSpecID(),
        ranks = ReadTraits(configID),
        at = GetTime(),
    }
end

-- Where a class has exactly one spec for a role, the role tells the spec.
local ROLE_SPEC = {
    HEALER = { DRUID = 105, MONK = 270, PALADIN = 65, SHAMAN = 264, EVOKER = 1468 },
    TANK = { DEATHKNIGHT = 250, DEMONHUNTER = 581, DRUID = 104, MONK = 268, PALADIN = 66, WARRIOR = 73 },
}

local function GuessSpec(token, class)
    local ok, role = pcall(UnitGroupRolesAssigned, token)
    role = ok and Plain(role)
    local t = role and ROLE_SPEC[role]
    return t and t[class] or nil
end

-- Inspect queue: one member at a time, out of combat, never while the
-- player has Blizzard's inspect window open (it owns the inspect then).
local inspectQueue, inspecting = {}, nil

local function QueueInspect(token)
    for _, t in ipairs(inspectQueue) do if t == token then return end end
    inspectQueue[#inspectQueue + 1] = token
end

local function InspectNext()
    if inspecting and GetTime() - inspecting.at < INSPECT_TIMEOUT then return end
    inspecting = nil
    if InCombatLockdown() or #inspectQueue == 0 then return end
    if InspectFrame and InspectFrame:IsShown() then return end
    local token = table.remove(inspectQueue, 1)
    local guid = Plain(UnitGUID(token))
    if not guid or not UnitIsConnected(token) or not CanInspect(token) then return end
    inspecting = { token = token, guid = guid, at = GetTime() }
    NotifyInspect(token)
end

local function OnInspectReady(guid)
    if not inspecting or IsSecret(guid) or inspecting.guid ~= guid then return end
    local token = inspecting.token
    inspecting = nil
    local spec
    if C_SpecializationInfo and C_SpecializationInfo.GetInspectSpecialization then
        local ok, s = pcall(C_SpecializationInfo.GetInspectSpecialization, token)
        spec = ok and Plain(s)
    end
    local ranks = ReadTraits(Constants and Constants.TraitConsts and Constants.TraitConsts.INSPECT_TRAIT_CONFIG_ID or -1)
    if spec and spec > 0 then
        known[guid] = { spec = spec, ranks = ranks, at = GetTime() }
    end
    if ClearInspectPlayer then pcall(ClearInspectPlayer) end
    PC:Rebuild()
end

------------------------------------------------------------------------
-- Which cooldowns a member gets, and how long they are
------------------------------------------------------------------------
local CAT_KEY = { personal = "personal", external = "external", group = "group" }

local function Wanted(def, m)
    if def.class ~= m.class then return false end
    if not PC.Get(CAT_KEY[def.cat]) then return false end
    if def.specSet then
        if not m.spec then return false end
        if not def.specSet[m.spec] then return false end
    end
    -- Talent cast: hidden only when the talents are known and lack it.
    if def.talent and m.ranks then
        local have = (m.ranks[def.key] or 0) > 0
        for _, id in ipairs(def.casts or {}) do
            if (m.ranks[id] or 0) > 0 then have = true end
        end
        if not have then return false end
    end
    return true
end

-- Base, then spec passive, then talents: flat amounts add, percentages add
-- together and scale the result (how the game stacks SPELLMOD_COOLDOWN).
local function EffectiveCD(def, ranks, spec)
    local flat, pct, charges = 0, 0, def.charges or 1
    local function add(kind, amount)
        if kind == "flat" then flat = flat + amount
        elseif kind == "pct" then pct = pct + amount
        elseif kind == "chg" then charges = charges + amount end
    end
    for _, mod in ipairs((spec and def.specMods and def.specMods[spec]) or {}) do
        add(mod[1], mod[2])
    end
    for _, mod in ipairs(def.mods or {}) do
        local r = ranks and ranks[mod[1]] or 0
        if r > 0 then add(mod[2], mod[3] * r) end
    end
    return math.max(1, (def.cd + flat) * (1 + pct / 100)), charges
end
PC.EffectiveCD = EffectiveCD

local function NewTracker(def)
    local now = GetTime()
    local u = math.max(1, math.ceil(2 * def.maxCd / CODES))
    return {
        def = def,
        u = u,
        P = math.floor(CODES / 2) * u,
        cur = 1,
        slots = {
            { epoch = now, stamp = 0, shown = 0 },
            { epoch = now, stamp = 0, shown = 0 },
        },
        glow = 0,
        watch = {},
    }
end

------------------------------------------------------------------------
-- Timers
------------------------------------------------------------------------
local function Roll(t, now)
    if now - t.slots[t.cur].epoch < t.P then return end
    t.cur = 3 - t.cur
    local sl = t.slots[t.cur]
    sl.epoch, sl.stamp, sl.shown = now, 0, 0
end

-- One fresh reading from one sensor: on a rising edge, stamp now.
local function Latch(t, s, now)
    Roll(t, now)
    local sl = t.slots[t.cur]
    -- Nearest step, not floor: halves the worst error (a 360s cooldown
    -- steps in 3s, so +-1.5s).
    local v = math.floor((now - sl.epoch) / t.u + 0.5) / 255
    local ok, stamp, shown = pcall(function()
        return EvalBool(s.lit, EvalBool(s.prev, sl.stamp, v), sl.stamp),
               EvalBool(s.lit, EvalBool(s.prev, sl.shown, 1), sl.shown)
    end)
    if ok then sl.stamp, sl.shown = stamp, shown end
end

local function Glow(t)
    local ok, g = pcall(function()
        local v = 0
        for _, s in ipairs(t.watch) do v = EvalBool(s.lit, 1, v) end
        return v
    end)
    if ok then t.glow = g end
end

------------------------------------------------------------------------
-- Icons
------------------------------------------------------------------------
local function Edges(parent, layer, thickness, r, g, b, a)
    local list = {}
    local function edge(p1, p2, horizontal)
        local tex = parent:CreateTexture(nil, layer)
        tex:SetColorTexture(r, g, b, a)
        tex:SetPoint(p1, parent, p1, 0, 0)
        tex:SetPoint(p2, parent, p2, 0, 0)
        if horizontal then tex:SetHeight(thickness) else tex:SetWidth(thickness) end
        list[#list + 1] = tex
    end
    edge("TOPLEFT", "TOPRIGHT", true)
    edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
    edge("TOPLEFT", "BOTTOMLEFT", false)
    edge("TOPRIGHT", "BOTTOMRIGHT", false)
    return list
end

local function NewIcon(row)
    local f = CreateFrame("Frame", nil, row)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetAllPoints()
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.bars = {}
    for k = 1, 2 do
        local bar = CreateFrame("StatusBar", nil, f)
        bar:SetAllPoints(f)
        bar:SetStatusBarTexture(WHITE)
        bar:SetOrientation("VERTICAL")
        bar:SetReverseFill(true) -- the shade drains from the top down
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0)
        bar:SetAlpha(0)
        f.bars[k] = bar
    end
    local top = CreateFrame("Frame", nil, f)
    top:SetAllPoints(f)
    top:SetFrameLevel(f:GetFrameLevel() + 3)
    f.border = Edges(top, "OVERLAY", 1, 0, 0, 0, 1)
    f.glowFrame = CreateFrame("Frame", nil, top)
    f.glowFrame:SetAllPoints(f)
    f.glowFrame:SetAlpha(0)
    Edges(f.glowFrame, "OVERLAY", 2, 1, 0.82, 0.1, 1)
    return f
end

local function Row(token)
    local row = rows[token]
    if not row then
        row = CreateFrame("Frame", nil, UIParent)
        row:SetSize(1, 1)
        row.icons = {}
        rows[token] = row
    end
    return row
end

local function StyleIcon(f, t)
    local size = PC.Get("size")
    f:SetSize(size, size)
    f.icon:SetTexture(C_Spell.GetSpellTexture(t.def.key))
    local shade = PC.Get("shade")
    for k = 1, 2 do
        f.bars[k]:SetStatusBarColor(0, 0, 0, shade)
    end
    local border = PC.Get("showBorder")
    for _, e in ipairs(f.border) do e:SetShown(border) end
    f.glowFrame:SetShown(PC.Get("glow"))
end

-- Point pairs for icon i (0-based) of n along the chosen side.
local function Place(f, button, i, n)
    local side, align = PC.Get("side"), PC.Get("align")
    local step = PC.Get("size") + PC.Get("spacing")
    local ox, oy = PC.Get("offsetX"), PC.Get("offsetY")
    f:ClearAllPoints()
    if side == "TOP" or side == "BOTTOM" then
        local v, rv = "TOP", "BOTTOM"
        if side == "TOP" then v, rv = "BOTTOM", "TOP" end
        if align == "CENTER" then
            f:SetPoint(v, button, rv, ox + i * step - (n - 1) * step / 2, oy)
        elseif align == "END" then
            f:SetPoint(v .. "RIGHT", button, rv .. "RIGHT", ox - i * step, oy)
        else
            f:SetPoint(v .. "LEFT", button, rv .. "LEFT", ox + i * step, oy)
        end
    else
        -- LEFT / RIGHT: the row runs outward from that edge.
        local h, rh, dir = "RIGHT", "LEFT", -1
        if side == "RIGHT" then h, rh, dir = "LEFT", "RIGHT", 1 end
        local v = (align == "CENTER" and "") or (align == "END" and "BOTTOM") or "TOP"
        f:SetPoint(v .. h, button, v .. rh, ox + dir * i * step, oy)
    end
end

------------------------------------------------------------------------
-- Rebuild: members -> trackers -> icons
------------------------------------------------------------------------
local function PartyButton(token)
    local PF = SquizzFrames:GetModule("PartyFrames", true)
    return PF and PF.FindButtonByUnit and PF.FindButtonByUnit(token)
end

local function HideAll()
    for _, row in pairs(rows) do
        row:Hide()
        for _, f in ipairs(row.icons) do f:Hide() end
    end
    if driver then driver:Hide() end
end

local function ReadMembers()
    wipe(members)
    for _, token in ipairs(TOKENS) do
        if UnitExists(token) and (token ~= "player" or PC.Get("showSelf")) then
            local guid = Plain(UnitGUID(token))
            local _, class = UnitClass(token)
            class = Plain(class)
            if guid and class then
                local k = known[guid]
                local spec = (k and k.spec) or GuessSpec(token, class)
                members[token] = { guid = guid, class = class, spec = spec, ranks = k and k.ranks }
                if token ~= "player" and (not k or GetTime() - k.at > INSPECT_AGAIN) then
                    QueueInspect(token)
                end
            end
        end
    end
end

function PC:Rebuild()
    if not Active() then
        HideAll()
        ParkUnusedSensors() -- nothing marked used: parks them all
        return
    end
    ReadOwn()
    ReadMembers()

    local DATA = SquizzFrames.PartyCooldownsData
    local spells = DATA and DATA.spells or {}
    local maxIcons = PC.Get("maxIcons")

    -- Each member's list, in table order: personal, then external, then group.
    local order = { personal = 1, external = 2, group = 3 }
    for _, token in ipairs(TOKENS) do
        local row = Row(token)
        local m = members[token]
        local button = PartyButton(token)
        local list, own = {}, nil
        if m and button then
            for _, def in ipairs(spells) do
                if Wanted(def, m) then list[#list + 1] = def end
            end
            table.sort(list, function(a, b)
                if order[a.cat] ~= order[b.cat] then return order[a.cat] < order[b.cat] end
                return a.key < b.key
            end)
            trackers[m.guid] = trackers[m.guid] or {}
            own = trackers[m.guid]
        end
        local shown = math.min(#list, maxIcons)
        for i = 1, shown do
            local def = list[i]
            local t = own[def.key]
            if not t then
                t = NewTracker(def)
                own[def.key] = t
            end
            t.cd, t.charges = EffectiveCD(def, m.ranks, m.spec)
            -- Who to watch: the caster, or for an external / zone everyone.
            wipe(t.watch)
            if def.who == "self" then
                local s = Sensor(token, def)
                if s then t.watch[1] = s end
            else
                for _, other in ipairs(TOKENS) do
                    if UnitExists(other) then
                        local s = Sensor(other, def)
                        if s then t.watch[#t.watch + 1] = s end
                    end
                end
            end
            local f = row.icons[i] or NewIcon(row)
            row.icons[i] = f
            f.tracker = t
            StyleIcon(f, t)
            Place(f, button, i - 1, shown)
            f:Show()
        end
        for i = shown + 1, #row.icons do
            row.icons[i]:Hide()
            row.icons[i].tracker = nil
        end
        if button and shown > 0 then
            row:SetParent(button)
            row:SetFrameStrata(button:GetFrameStrata())
            row:SetFrameLevel(button:GetFrameLevel() + 30)
            row:ClearAllPoints()
            row:SetAllPoints(button)
            row:Show()
        else
            row:Hide()
        end
    end
    ParkUnusedSensors()
    if driver then driver:Show() end
    InspectNext()
end

------------------------------------------------------------------------
-- The pass: read owed sensors, latch, draw
------------------------------------------------------------------------
local elapsedSum, safetySum = 0, 0

local function Pass()
    local now = GetTime()
    for _, token in ipairs(TOKENS) do
        if (reads[token] or 0) > 0 then
            reads[token] = reads[token] - 1
            ReadToken(token)
        end
    end

    for _, token in ipairs(TOKENS) do
        local row = rows[token]
        if row and row:IsShown() then
            for _, f in ipairs(row.icons) do
                local t = f.tracker
                if t and f:IsShown() then
                    if testMode then
                        -- Plain values: each icon at a different point of its cooldown.
                        local frac = ((now / t.cd) + (f.testPhase or 0)) % 1.4
                        for k = 1, 2 do
                            local bar = f.bars[k]
                            bar:SetMinMaxValues(0, 1)
                            bar:SetValue(k == 1 and math.max(0, 1 - frac) or 0)
                            bar:SetAlpha(k == 1 and 1 or 0)
                        end
                        f.glowFrame:SetAlpha((frac < 0.1) and 1 or 0)
                    else
                        local any = false
                        for _, s in ipairs(t.watch) do
                            if s.fresh then
                                Latch(t, s, now)
                                any = true
                            end
                        end
                        if any then Glow(t) end
                        Roll(t, now)
                        local span = t.cd / t.u / 255
                        for k = 1, 2 do
                            local sl, bar = t.slots[k], f.bars[k]
                            local nv = (now - sl.epoch) / t.u / 255
                            pcall(function()
                                bar:SetMinMaxValues(nv - span, nv)
                                bar:SetValue(sl.stamp)
                                bar:SetAlpha(sl.shown)
                            end)
                        end
                        pcall(f.glowFrame.SetAlpha, f.glowFrame, t.glow)
                    end
                end
            end
        end
    end

    -- Every reading has now been offered to every timer watching it.
    for _, list in pairs(sensors) do
        for _, s in pairs(list) do s.fresh = nil end
    end
end

local function EnsureDriver()
    if driver then return end
    driver = CreateFrame("Frame")
    driver:Hide()
    driver:SetScript("OnUpdate", function(_, elapsed)
        elapsedSum = elapsedSum + elapsed
        safetySum = safetySum + elapsed
        if elapsedSum < TICK then return end
        elapsedSum = 0
        if safetySum >= SAFETY then
            safetySum = 0
            for _, token in ipairs(TOKENS) do
                if (reads[token] or 0) < 1 then reads[token] = 1 end
            end
        end
        Pass()
    end)
end

------------------------------------------------------------------------
-- Test icons (the options page): plain fake timers, nothing secret.
------------------------------------------------------------------------
function PC.SetTestMode(on)
    testMode = on and true or false
    PC:Rebuild()
    if testMode then
        for _, row in pairs(rows) do
            for i, f in ipairs(row.icons) do f.testPhase = i * 0.37 end
        end
    end
end

function PC.IsTestMode() return testMode end

------------------------------------------------------------------------
-- /sfcdcheck: our cooldown for each of YOUR tracked spells against the
-- game's own tooltip, which includes every modifier that applies to you.
-- The quick way to catch a wrong base value or a missing spec passive.
------------------------------------------------------------------------
local function TooltipSeconds(spellID)
    if not (C_TooltipInfo and C_TooltipInfo.GetSpellByID) then return nil end
    local ok, data = pcall(C_TooltipInfo.GetSpellByID, spellID)
    if not ok or not data or not data.lines then return nil end
    for _, line in ipairs(data.lines) do
        for _, text in ipairs({ line.leftText, line.rightText }) do
            if text and not IsSecret(text) then
                local n, unit = text:match("([%d%.]+) (%a+) [Cc]ooldown")
                if not n then n, unit = text:match("([%d%.]+) (%a+) [Rr]echarge") end
                n = tonumber(n)
                if n and unit then
                    unit = unit:lower()
                    -- Second value: how far off the tooltip's own rounding
                    -- can be. Minutes show one decimal ("1.3 min" is 75s),
                    -- so up to 3s either way.
                    if unit:find("^min") then return n * 60, 3 end
                    if unit:find("^sec") then return n, 0.5 end
                    if unit:find("^h") then return n * 3600, 180 end
                end
            end
        end
    end
    return nil
end

local function KnowsSpell(id)
    if not (C_SpellBook and C_SpellBook.IsSpellKnown) then return false end
    local ok, v = pcall(C_SpellBook.IsSpellKnown, id)
    return ok and v and true or false
end

SLASH_SQUIZZCDCHECK1 = "/sfcdcheck"
SlashCmdList["SQUIZZCDCHECK"] = function()
    local P = "|cff33cc99[SquizzFrames]|r "
    ReadOwn()
    local guid = Plain(UnitGUID("player"))
    local k = guid and known[guid] or {}
    local _, class = UnitClass("player")
    local DATA = SquizzFrames.PartyCooldownsData
    print(P .. string.format("Party Cooldowns check, spec %s, talents %s:",
        tostring(k.spec), k.ranks and "read" or "|cffff5555NOT read|r"))
    local checked, bad = 0, 0
    for _, def in ipairs(DATA and DATA.spells or {}) do
        if def.class == class then
            local id = def.key
            if not KnowsSpell(id) then
                for _, alt in ipairs(def.casts or {}) do
                    if KnowsSpell(alt) then id = alt end
                end
            end
            local name = C_Spell.GetSpellName(id) or tostring(id)
            if KnowsSpell(id) then
                local ours, charges = EffectiveCD(def, k.ranks, k.spec)
                local theirs, slack = TooltipSeconds(id)
                checked = checked + 1
                if not theirs then
                    print(string.format("   %s: ours %ds, tooltip shows no cooldown we can read", name, ours))
                elseif math.abs(theirs - ours) <= slack + 0.01 then
                    print(string.format("   |cff33ff33OK|r %s: %ds%s", name, ours, charges > 1 and (" (" .. charges .. " charges)") or ""))
                else
                    bad = bad + 1
                    print(string.format("   |cffff5555MISMATCH|r %s: ours %ds, tooltip %ds", name, ours, theirs))
                end
            end
        end
    end
    print(P .. string.format("%d checked, %d mismatched. Spells you do not know are skipped.", checked, bad))
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local rebuildQueued = false
local function QueueRebuild()
    if rebuildQueued then return end
    rebuildQueued = true
    C_Timer.After(0.2, function()
        rebuildQueued = false
        PC:Rebuild()
    end)
end
PC.QueueRebuild = QueueRebuild

function PC:OnEnable()
    EnsureDriver()

    -- UNIT_AURA per token on its own frame: RegisterUnitEvent filters it
    -- C-side, so other units' aura churn never reaches Lua.
    for _, token in ipairs(TOKENS) do
        local f = CreateFrame("Frame")
        f:RegisterUnitEvent("UNIT_AURA", token)
        f:SetScript("OnEvent", function() reads[token] = READS end)
    end

    self:RegisterEvent("GROUP_ROSTER_UPDATE", QueueRebuild)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", QueueRebuild)
    self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", function(_, unit)
        local guid = unit and Plain(UnitGUID(unit))
        if guid and unit ~= "player" then known[guid] = nil end
        QueueRebuild()
    end)
    self:RegisterEvent("TRAIT_CONFIG_UPDATED", QueueRebuild)
    self:RegisterEvent("INSPECT_READY", function(_, guid) OnInspectReady(guid) end)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        if pendingSensors then
            pendingSensors = false
            QueueRebuild()
        end
        InspectNext()
    end)
    self:RegisterMessage("PartyCooldownsChanged", QueueRebuild)
    self:RegisterMessage("ProfileChanged", QueueRebuild)
    -- The party frames re-wire their buttons on roster and sort changes.
    self:RegisterMessage("PartyButtonsWired", QueueRebuild)

    -- Inspect replies can be slow or never come; keep the queue moving.
    C_Timer.NewTicker(2, InspectNext)
    QueueRebuild()
end
