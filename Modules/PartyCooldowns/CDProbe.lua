--[[
    /sfcdprobe -- proves, in game, the pieces a party-cooldown indicator would
    rest on, before any of it is built. Dev harness, same status as /sfauratest.

    The idea (researched 2026-10-27, see the kiraui-party-cds-technique memory):
    a party member's cast IDs are secret in instances, but the BUFF a cooldown
    puts on its caster can still be watched by an AuraContainer, which runs
    C-side. Three questions this answers:

      1. SENSOR. One hidden AuraContainer per unit, one group filtered to the
         watched buffs, maxFrameCount 1 and an enormous element width. When a
         buff is up the container grows across the screen, so
         container:IsMouseOver(huge, -huge, 0, 0) answers "a buff is up"
         without ever touching the aura button (that call is refused). Does it
         flip, and does the answer come back secret in combat?
      2. LATCH. C_CurveUtil.EvaluateColorValueFromBoolean(bool, a, b) picks a
         or b engine-side. Used to remember WHEN the buff appeared, as a
         number in 0..1 (seconds since the probe's epoch / 255), without ever
         reading it. Does a value survive the round trip exactly?
      3. DRAW. A StatusBar takes the secret stamp in SetValue, with plain
         min/max set to [now - cd, now]: its fill is then the share of the
         cooldown left. Does that draw, in combat, without errors?

    Out of combat every reading is plain, so it is also checked against the
    unit's real buffs (C_UnitAuras), which proves the sensor is RIGHT, not
    just that it changes.

    Results are kept in SquizzFramesDB.cdProbe (saved on /reload), so a run in
    a key can be read back afterwards without copying chat.
--]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local P = "|cff33cc99[SquizzFrames]|r "
local UNITS = { "player", "party1", "party2", "party3", "party4" }
local POLL = 0.2
local STEP = 1          -- seconds per stamp code
local CODES = 254       -- usable codes; 255 is kept for "never"
local HUGE = 50000      -- element width: wide enough to cover any screen
local LOG_MAX = 60

-- Defensive / major-cooldown buffs that land on the CASTER. Names are printed
-- at start, which is the check that each ID is the buff and not the cast.
local DEFAULT_BUFFS = {
    116680, 120954, 122783, 122278, -- Monk: Thunder Focus Tea, Fortifying Brew, Diffuse Magic, Dampen Harm
    45438,                          -- Mage: Ice Block
    22812, 61336,                   -- Druid: Barkskin, Survival Instincts
    642, 498,                       -- Paladin: Divine Shield, Divine Protection
    48792, 48707,                   -- Death Knight: Icebound Fortitude, Anti-Magic Shell
    186265,                         -- Hunter: Aspect of the Turtle
    212800,                         -- Demon Hunter: Blur
    363916,                         -- Evoker: Obsidian Scales
    104773,                         -- Warlock: Unending Resolve
    108271,                         -- Shaman: Astral Shift
    118038, 871,                    -- Warrior: Die by the Sword, Shield Wall
    31224, 5277,                    -- Rogue: Cloak of Shadows, Evasion
    47585, 19236,                   -- Priest: Dispersion, Desperate Prayer
}

local EvalBool = C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean

local function IsSecret(v)
    return issecretvalue and issecretvalue(v) or false
end

local probe = {
    running = false,
    ids = nil,          -- [spellID] = true
    cd = 30,            -- demo cooldown the bars count down
    epoch = 0,
    sensors = {},       -- [unit] = container
    rows = {},          -- [unit] = row widgets
    state = {},         -- [unit] = { prev = bool|secret, stamp = number|secret }
}

------------------------------------------------------------------------
-- Results (SquizzFramesDB.cdProbe)
------------------------------------------------------------------------
local function Results()
    SquizzFramesDB = SquizzFramesDB or {}
    local r = SquizzFramesDB.cdProbe
    if type(r) ~= "table" then
        r = {}
        SquizzFramesDB.cdProbe = r
    end
    return r
end

local function NewCounters()
    return {
        reads = 0, readsInCombat = 0, secret = 0, secretInCombat = 0,
        lit = 0, unlit = 0, sensorErrors = 0, evalErrors = 0, drawErrors = 0,
        checked = 0, agree = 0, disagree = 0, flips = 0,
        widthReadable = 0, widthSecret = 0,
    }
end

local function Log(text, echo)
    local r = Results()
    r.log = r.log or {}
    local line = string.format("%s %s", date("%H:%M:%S"), text)
    table.insert(r.log, line)
    while #r.log > LOG_MAX do table.remove(r.log, 1) end
    if echo then print(P .. text) end
end

local function Count(unit, key)
    local c = Results().counters
    if not c then return end
    c.all[key] = (c.all[key] or 0) + 1
    c[unit][key] = (c[unit][key] or 0) + 1
end

------------------------------------------------------------------------
-- Sensor
------------------------------------------------------------------------
local host

local function InitSensorButton(button)
    -- Inside initializeFrame: the only window where a call on an aura button
    -- is always legal. The real button is tiny and ignores the mouse; only
    -- the layout stride (HUGE) makes the container grow.
    pcall(button.SetSize, button, 1, 1)
    pcall(button.SetMouseClickEnabled, button, false)
    pcall(button.SetMouseMotionEnabled, button, false)
end

local function BuildSensor(unit)
    if not host then
        host = CreateFrame("Frame", nil, UIParent)
        host:SetSize(1, 1)
        host:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    end
    local ok, c = pcall(CreateFrame, "AuraContainer", nil, host, "CustomAuraContainerTemplate")
    if not ok or not c then return nil, "CreateFrame refused the AuraContainer: " .. tostring(c) end
    -- Parked just off the left edge: empty, it is a 1px sliver nobody's
    -- cursor can reach; with a buff up it is HUGE wide and covers the screen.
    c:SetSize(1, 1)
    c:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -20, 0)
    pcall(c.EnableMouse, c, false)
    local okG, err = pcall(c.AddAuraGroup, c, "cd", "HELPFUL", {
        maxFrameCount = 1,
        candidateFilters = { includeSpellIDs = probe.ids },
        initializeFrame = InitSensorButton,
        layout = { elementWidth = HUGE, elementHeight = 1, elementSpacing = 0, lineSpacing = 0 },
    })
    if not okG then return nil, "AddAuraGroup failed: " .. tostring(err) end
    -- Unit LAST (CLAUDE.md section 7): earlier leaves UNIT_AURA unregistered.
    c:SetUnit(unit)
    pcall(c.UpdateAllAuras, c)
    return c
end

-- ok, reading. The reading is true/false or a secret boolean, so the caller
-- branches on the plain `ok` and never compares the reading itself.
local function ReadSensor(c)
    return pcall(c.IsMouseOver, c, 1e5, -1e5, 0, 0)
end

-- Ground truth, out of combat only: does the unit really have a watched buff?
local function TruthOf(unit)
    if InCombatLockdown() then return nil end
    for i = 1, 40 do
        local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
        if not ok or type(a) ~= "table" then return false end
        local id = a.spellId
        if IsSecret(id) then return nil end
        if id and probe.ids[id] then return true end
    end
    return false
end

------------------------------------------------------------------------
-- Latch + draw
------------------------------------------------------------------------
local function NowCode()
    local code = math.floor((GetTime() - probe.epoch) / STEP)
    if code > CODES then return nil end
    return code
end

-- The round-trip check: plain values in, are they handed back exactly?
local function DoorCheck()
    if not EvalBool then return "missing", "C_CurveUtil.EvaluateColorValueFromBoolean does not exist" end
    local worst = 0
    for _, k in ipairs({ 0, 1, 2, 47, 128, 200, 253, 254, 255 }) do
        local want = k / 255
        local ok, a = pcall(EvalBool, true, want, 0)
        if not ok then return "error", tostring(a) end
        local ok2, b = pcall(EvalBool, false, 0, want)
        if not ok2 then return "error", tostring(b) end
        if IsSecret(a) or IsSecret(b) then return "hidden", "results came back secret (cannot be checked here)" end
        if type(a) ~= "number" or type(b) ~= "number" then return "error", "result was not a number" end
        worst = math.max(worst, math.abs(a - want), math.abs(b - want))
    end
    if worst == 0 then return "exact", "every value came back exact" end
    if worst * 255 < 0.5 then return "close", string.format("off by at most %.2e, below half a step", worst) end
    return "coarse", string.format("off by %.2e, more than half a step: timers would drift", worst)
end

local function Draw(unit, st, lit)
    local row = probe.rows[unit]
    if not row then return end
    local okL, litValue = pcall(EvalBool, lit, 1, 0)
    local okD, err = pcall(function()
        row.lit:SetValue(okL and litValue or 0)
        local nowValue = (GetTime() - probe.epoch) / STEP / 255
        local span = probe.cd / STEP / 255
        -- Fill = (stamp - (now - cd)) / cd: the share of the cooldown left.
        -- A stamp older than now - cd sits below min and draws empty.
        row.bar:SetMinMaxValues(nowValue - span, nowValue)
        row.bar:SetValue(st.stamp)
    end)
    if not okL then Count(unit, "evalErrors") end
    if not okD then
        Count(unit, "drawErrors")
        Results().lastDrawError = tostring(err)
    end
    if not IsSecret(st.stamp) then
        local left = probe.cd - ((GetTime() - probe.epoch) - st.stamp * 255 * STEP)
        row.time:SetText(left > 0 and string.format("%.0f", left) or "")
    else
        row.time:SetText("|cff888888?|r")
    end
end

local function Poll()
    local code = NowCode()
    if not code then
        -- The 0..254 range is spent. Start a fresh epoch; a cooldown running
        -- across the boundary is lost, which a real indicator avoids by
        -- alternating two latches. Acceptable for a probe.
        probe.epoch = GetTime() - probe.cd - STEP
        for _, st in pairs(probe.state) do st.stamp, st.prev = 0, false end
        Log("stamp range spent: started a new epoch (running timers reset)")
        code = NowCode()
    end
    local nowValue = code / 255
    local inCombat = InCombatLockdown()

    for _, unit in ipairs(UNITS) do
        local c, st = probe.sensors[unit], probe.state[unit]
        local row = probe.rows[unit]
        if row then
            local okN, name = pcall(UnitName, unit)
            row.name:SetText(okN and name or unit)
        end
        if c and st and UnitExists(unit) then
            if row then
                local truth = TruthOf(unit)
                if truth == true then
                    row.truth:SetColorTexture(0.2, 0.5, 1, 1)
                elseif truth == false then
                    row.truth:SetColorTexture(0.25, 0.25, 0.25, 1)
                else
                    row.truth:SetColorTexture(0.12, 0.12, 0.12, 1) -- unknown (combat)
                end
            end
            local okR, lit = ReadSensor(c)
            if not okR then
                Count(unit, "sensorErrors")
                Results().lastSensorError = tostring(lit)
            else
                Count(unit, "reads")
                if inCombat then Count(unit, "readsInCombat") end
                local secret = IsSecret(lit)
                if secret then
                    Count(unit, "secret")
                    if inCombat then Count(unit, "secretInCombat") end
                else
                    Count(unit, lit and "lit" or "unlit")
                    if not IsSecret(st.prev) and st.prev ~= nil and st.prev ~= lit then
                        Count(unit, "flips")
                        Log(string.format("%s: sensor %s%s", unit, lit and "ON" or "off", inCombat and " (in combat)" or ""), true)
                    end
                    local truth = TruthOf(unit)
                    if truth ~= nil then
                        Count(unit, "checked")
                        if truth == (lit and true or false) then
                            Count(unit, "agree")
                        else
                            Count(unit, "disagree")
                            Log(string.format("%s: MISMATCH sensor=%s real buffs=%s", unit, tostring(lit), tostring(truth)))
                        end
                    end
                end
                -- Width: a second, independent reading of the same growth.
                local okW, w = pcall(c.GetWidth, c)
                if okW then Count(unit, IsSecret(w) and "widthSecret" or "widthReadable") end

                -- Latch: lit now and not lit last poll -> stamp now; else keep.
                if EvalBool then
                    local okS, stamp = pcall(function()
                        return EvalBool(lit, EvalBool(st.prev, st.stamp, nowValue), st.stamp)
                    end)
                    if okS then
                        st.stamp = stamp
                    else
                        Count(unit, "evalErrors")
                        Results().lastEvalError = tostring(stamp)
                    end
                end
                st.prev = lit
                Draw(unit, st, lit)
            end
        elseif row then
            row.time:SetText("")
        end
    end
end

------------------------------------------------------------------------
-- Panel
------------------------------------------------------------------------
local panel

local function BuildPanel()
    if panel then return panel end
    panel = CreateFrame("Frame", "SquizzFramesCDProbe", UIParent, "BackdropTemplate")
    panel:SetSize(260, 34 + #UNITS * 20)
    panel:SetPoint("CENTER", UIParent, "CENTER", 0, 220)
    panel:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    panel:SetBackdropColor(0, 0, 0, 0.75)
    panel:SetBackdropBorderColor(0.2, 0.8, 0.6, 1)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 8, -7)
    panel.title = title

    for i, unit in ipairs(UNITS) do
        local y = -24 - (i - 1) * 20
        local row = {}
        row.name = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("TOPLEFT", 8, y - 2)
        row.name:SetWidth(80)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)

        -- "Buff up" light: fills when the sensor reads on.
        row.lit = CreateFrame("StatusBar", nil, panel)
        row.lit:SetSize(14, 14)
        row.lit:SetPoint("TOPLEFT", 92, y)
        row.lit:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        row.lit:SetStatusBarColor(0.2, 1, 0.4)
        row.lit:SetMinMaxValues(0, 1)
        row.lit:SetValue(0)
        local litBg = row.lit:CreateTexture(nil, "BACKGROUND")
        litBg:SetAllPoints()
        litBg:SetColorTexture(0.25, 0.25, 0.25, 1)

        -- Ground truth square, read the plain way (out of combat only): the
        -- sensor reading turned out to be secret even out of combat, so it
        -- cannot be compared in Lua. Blue beside green is the comparison.
        row.truth = panel:CreateTexture(nil, "ARTWORK")
        row.truth:SetSize(14, 14)
        row.truth:SetPoint("TOPLEFT", 110, y)
        row.truth:SetColorTexture(0.25, 0.25, 0.25, 1)

        -- Cooldown bar, drawn from the latched (possibly secret) stamp.
        row.bar = CreateFrame("StatusBar", nil, panel)
        row.bar:SetSize(100, 14)
        row.bar:SetPoint("TOPLEFT", 128, y)
        row.bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        row.bar:SetStatusBarColor(0.9, 0.6, 0.1)
        row.bar:SetMinMaxValues(0, 1)
        row.bar:SetValue(0)
        local barBg = row.bar:CreateTexture(nil, "BACKGROUND")
        barBg:SetAllPoints()
        barBg:SetColorTexture(0.25, 0.25, 0.25, 1)

        row.time = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.time:SetPoint("LEFT", row.bar, "RIGHT", 4, 0)

        probe.rows[unit] = row
    end
    return panel
end

------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------
local function SpellLabel(id)
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
    local secrecy = "?"
    if C_Secrets and C_Secrets.GetSpellAuraSecrecy then
        local ok, s = pcall(C_Secrets.GetSpellAuraSecrecy, id)
        if ok and not IsSecret(s) then secrecy = tostring(s) end
    end
    return string.format("%d %s (aura secrecy %s)", id, name or "|cffff5555unknown ID|r", secrecy)
end

local ticker

local function Start(ids)
    if InCombatLockdown() then
        print(P .. "CD probe: start it out of combat (the sensors are built once, then work in combat).")
        return
    end
    if not EvalBool then
        print(P .. "CD probe: |cffff5555C_CurveUtil.EvaluateColorValueFromBoolean is missing on this client|r - the technique cannot work here.")
        return
    end

    local list = (ids and #ids > 0) and ids or DEFAULT_BUFFS
    probe.ids = {}
    for _, id in ipairs(list) do probe.ids[id] = true end

    local r = Results()
    local build = select(2, GetBuildInfo())
    r.started, r.build, r.cd = date("%Y-%m-%d %H:%M:%S"), build, probe.cd
    r.ids = list
    r.counters = { all = NewCounters() }
    for _, unit in ipairs(UNITS) do r.counters[unit] = NewCounters() end
    r.log = {}
    r.lastSensorError, r.lastEvalError, r.lastDrawError = nil, nil, nil

    local door, doorWhy = DoorCheck()
    r.door, r.doorDetail = door, doorWhy
    print(P .. "CD probe: value round trip: |cffffff00" .. door .. "|r - " .. doorWhy)

    print(P .. "CD probe: watching these buffs on you and your party:")
    for _, id in ipairs(list) do print("   " .. SpellLabel(id)) end

    probe.epoch = GetTime() - probe.cd - STEP -- code 0 is already "long ago"
    for _, unit in ipairs(UNITS) do
        local c = probe.sensors[unit]
        if c then
            -- Re-aim an existing sensor rather than leak another container.
            pcall(c.SetAuraGroupCandidateFilters, c, "cd", { includeSpellIDs = probe.ids })
            pcall(c.SetEnabled, c, true)
            pcall(c.UpdateAllAuras, c)
        else
            local err
            c, err = BuildSensor(unit)
            if not c then
                Log(unit .. ": " .. err, true)
            end
            probe.sensors[unit] = c
        end
        probe.state[unit] = { prev = false, stamp = 0 }
    end

    BuildPanel()
    panel.title:SetText(string.format("SquizzFrames CD probe (demo cooldown %ds)", probe.cd))
    panel:Show()
    if ticker then ticker:Cancel() end
    ticker = C_Timer.NewTicker(POLL, Poll)
    probe.running = true
    Log("started", false)
    print(P .. "CD probe running. Pop one of the buffs above (out of combat first, then in combat, then in a key). " ..
        "Keep the cursor over the game window: the sensor reads through it. |cffffff00/sfcdprobe report|r for results, |cffffff00/sfcdprobe stop|r to end.")
end

local function Stop()
    if ticker then ticker:Cancel(); ticker = nil end
    for _, c in pairs(probe.sensors) do pcall(c.SetEnabled, c, false) end
    if panel then panel:Hide() end
    probe.running = false
    Log("stopped", false)
    print(P .. "CD probe stopped. Results stay in SquizzFramesDB.cdProbe; /reload to save them to disk.")
end

local function Report()
    local r = Results()
    if not r.counters then
        print(P .. "CD probe: no run recorded yet. /sfcdprobe start")
        return
    end
    print(P .. string.format("CD probe results (started %s, build %s, value round trip: %s)", r.started or "?", r.build or "?", r.door or "?"))
    local order = { "all" }
    for _, unit in ipairs(UNITS) do order[#order + 1] = unit end
    for _, key in ipairs(order) do
        local c = r.counters[key]
        if c and c.reads > 0 or key == "all" then
            print(string.format("   %-7s reads %d (%d in combat) | secret %d (%d in combat) | on %d off %d flips %d | vs real buffs: %d agree, %d disagree | errors: sensor %d, select %d, draw %d",
                key, c.reads, c.readsInCombat, c.secret, c.secretInCombat, c.lit, c.unlit, c.flips,
                c.agree, c.disagree, c.sensorErrors, c.evalErrors, c.drawErrors))
        end
    end
    if r.lastSensorError then print("   last sensor error: " .. r.lastSensorError) end
    if r.lastEvalError then print("   last select error: " .. r.lastEvalError) end
    if r.lastDrawError then print("   last draw error: " .. r.lastDrawError) end
end

-- /sfcdprobe precision: how much a number survives the engine-side select.
-- The timers store time in 254 steps of k/255 because that much was proven
-- (the round trip came back "close"). If values come back with full float
-- precision, and outside 0..1, a timer could keep one epoch for hours and
-- remember several casts -- which is what counting charges needs.
local function PrecisionCheck()
    if not EvalBool then
        print(P .. "precision: the select function is missing on this client")
        return
    end
    local r = Results()
    r.precision = {}
    local tests = {
        { "fine step 1/65536",     1 / 65536 },
        { "12345/65536",           12345 / 65536 },
        { "65535/65536",           65535 / 65536 },
        { "1/1000000",             1 / 1000000 },
        { "0.123456789",           0.123456789 },
        { "above one: 1.5",        1.5 },
        { "above one: 2",          2 },
        { "large: 1000.25",        1000.25 },
        { "large: 86400.5",        86400.5 },
        { "negative: -0.5",        -0.5 },
    }
    print(P .. "precision of the engine-side select (sent -> got, difference):")
    for _, t in ipairs(tests) do
        local label, want = tostring(t[1]), tonumber(t[2]) or 0
        local ok, got = pcall(EvalBool, true, want, 0)
        local line
        if not ok then
            line = string.format("   %-22s refused: %s", label, tostring(got))
        elseif IsSecret(got) then
            line = string.format("   %-22s came back secret (cannot be checked)", label)
        elseif type(got) ~= "number" then
            line = string.format("   %-22s came back as a %s", label, type(got))
        else
            line = string.format("   %-22s %.9g -> %.9g (diff %.3g)", label, want, got, got - want)
        end
        print(line)
        r.precision[#r.precision + 1] = line
    end
    print("--- end")
end

-- /sfcdprobe secrecy: can a party member's potion or Healthstone be seen
-- from their cast? Healing potions and Healthstones leave no buff, so the
-- buff sensor is blind to them; the only other route is the spell ID in
-- UNIT_SPELLCAST_SUCCEEDED, which in instances is hidden unless Blizzard
-- marks the spell NeverSecret (0). Every class interrupt measured 2
-- (ContextuallySecret) on 2026-10-06.
local SECRECY_SPELLS = {
    { 1234768, "Silvermoon Health Potion" },
    { 1295247, "Concentrated Silvermoon Health Potion" },
    { 6262,    "Healthstone" },
    { 452930,  "Demonic Healthstone" },
    { 1236616, "Light's Potential (combat potion)" },
    { 1236994, "Potion of Recklessness (combat potion)" },
}
local SECRECY_NAMES = { [0] = "NeverSecret - visible everywhere", [1] = "AlwaysSecret",
                        [2] = "ContextuallySecret - hidden in instances" }

local function SecrecyCheck()
    local r = Results()
    r.secrecy = {}
    local get = C_Secrets and C_Secrets.GetSpellCastSecrecy
    if not get then
        print(P .. "secrecy: C_Secrets.GetSpellCastSecrecy is missing on this client")
        return
    end
    print(P .. "cast secrecy (0 = a party member's cast is readable even in keys):")
    for _, s in ipairs(SECRECY_SPELLS) do
        local ok, v = pcall(get, s[1])
        local text
        if not ok then
            text = "refused: " .. tostring(v)
        elseif IsSecret(v) then
            text = "came back secret"
        else
            text = tostring(v) .. " (" .. (SECRECY_NAMES[v] or "?") .. ")"
        end
        local line = string.format("   %d %s: %s", s[1], s[2], text)
        print(line)
        r.secrecy[#r.secrecy + 1] = line
    end
    print("--- end")
end

SLASH_SQUIZZCDPROBE1 = "/sfcdprobe"
SlashCmdList["SQUIZZCDPROBE"] = function(msg)
    local args = {}
    for word in (msg or ""):gmatch("%S+") do args[#args + 1] = word end
    local cmd = (args[1] or ""):lower()

    if cmd == "precision" then
        PrecisionCheck()
    elseif cmd == "secrecy" then
        SecrecyCheck()
    elseif cmd == "stop" then
        Stop()
    elseif cmd == "report" then
        Report()
    elseif cmd == "cd" then
        local n = tonumber(args[2])
        if n and n >= 5 and n <= 180 then
            probe.cd = n
            print(P .. string.format("CD probe: demo cooldown set to %ds (applies from the next start).", n))
        else
            print(P .. "CD probe: /sfcdprobe cd <5-180>")
        end
    elseif cmd == "start" or cmd == "" then
        local ids = {}
        for i = 2, #args do
            local id = tonumber(args[i])
            if id then ids[#ids + 1] = id end
        end
        Start(ids)
    else
        print(P .. "CD probe: /sfcdprobe [start [buffID ...]] | report | stop | cd <seconds>")
    end
end
