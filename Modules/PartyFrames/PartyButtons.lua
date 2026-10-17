--[[ SquizzFrames PartyButtons.lua -- per-button updates for party/raid frames:
    health, power, role, status text (and its AFK/Dead timers), plus
    /sfdrinktest. Moved out of PartyFrames.lua unchanged in 2.0 (phase 2
    code split). PartyFrames.lua keeps same-named forwarders that call
    through PartyFrames.buttons, published at the end of this file. ]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F
local L = SquizzFrames.L
---@class AceModule
local PartyFrames = SquizzFrames:GetModule("PartyFrames")

local shared = PartyFrames.shared
local GetProfile = shared.GetProfile
local GetBarTexture = shared.GetBarTexture
local ForEachHeaderButton = shared.ForEachHeaderButton
local unitButtons = shared.unitButtons -- same table for good: only ever wiped
-- A getter, not a value: the container is created after this file loads.
local GetPartyFrame = shared.GetPartyFrame

-----------------------------------------------------------------------
-- Button update functions
-----------------------------------------------------------------------

local function UpdateHealth(button)
    if not button or not button.unit then return end
    local unit = button.unit

    -- Layout preview: fake a full, class-colored bar for slots with no real
    -- unit (see PartyFrames:SetPreviewMode) -- skips the UnitExists gate
    -- entirely since there's no real unit to check.
    if button._sfFakeName then
        button.nameText:SetAlpha(1)
        if button.healthBar then
            local maxHP = button._sfFakeHealthMax or 100
            button.healthBar:SetMinMaxValues(0, maxHP)
            button.healthBar:SetValue(button._sfFakeHealth or maxHP)
            button.healthBar:SetStatusBarTexture(GetBarTexture())
            local prof = GetProfile()
            local grad = prof and prof.appearance and prof.appearance.healthBar
                and prof.appearance.healthBar.gradient
            -- The mock evaluates the curve DIRECTLY, which the live path may
            -- not: Evaluate is AllowedWhenUntainted, so an addon cannot hand
            -- it a secret -- but these are fake numbers, so the fraction is
            -- plain. Same curve and colours, so the preview shows what a real
            -- bar does at that health.
            local gr, gg, gb
            if F.EvaluateHealthGradient then
                gr, gg, gb = F.EvaluateHealthGradient(grad,
                    (button._sfFakeHealth or maxHP) / math.max(1, maxHP))
            end
            local useClass = prof and prof.appearance and prof.appearance.healthBar
                and prof.appearance.healthBar.fullColor
                and prof.appearance.healthBar.fullColor[1] == "class_color"
            local col = prof and prof.appearance and prof.appearance.healthBar
                and prof.appearance.healthBar.fullColor
            if gr then
                button.healthBar:SetStatusBarColor(gr, gg, gb, 1)
            elseif useClass and button._sfFakeClass then
                local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[button._sfFakeClass]
                if cc then button.healthBar:SetStatusBarColor(cc.r, cc.g, cc.b, 1) end
            else
                local r = col and col[2] or 0.2
                local g = col and col[3] or 0.8
                local b = col and col[4] or 0.2
                button.healthBar:SetStatusBarColor(r, g, b, 1)
            end
        end
        return
    end

    if not UnitExists(unit) then return end

    -- Check offline/dead/ghost states
    local isDead = UnitIsDead(unit)
    local isGhost = UnitIsGhost(unit)
    local isConnected = UnitIsConnected(unit)

    if not isConnected or isDead or isGhost then
        -- statusText itself (text + background sync) is UpdateStatus' job --
        -- UpdateButtonAll always calls UpdateHealth immediately before
        -- UpdateStatus, so setting it here was always overwritten a moment
        -- later. Duplicating it left the background texture unsynced on this
        -- path and was the same "two functions writing the same widget"
        -- footgun already fixed once this session for nameText.
        if button.healthBar then
            button.healthBar:SetMinMaxValues(0, 1)
            button.healthBar:SetValue(0)
        end
        if button.powerBar then
            button.powerBar:SetMinMaxValues(0, 1)
            button.powerBar:SetValue(0)
        end
        button.nameText:SetAlpha(0.5)
        return
    end

    -- Normal state
    button.nameText:SetAlpha(1)

    -- Health bar: StatusBar handles secret values at C level.
    -- Pass raw UnitHealth/UnitHealthMax to SetMinMaxValues/SetValue.
    if button.healthBar then
        button.healthBar:SetMinMaxValues(0, UnitHealthMax(unit) or 1)
        button.healthBar:SetValue(UnitHealth(unit) or 0)
        button.healthBar:SetStatusBarTexture(GetBarTexture())

        local prof = GetProfile()
        local grad = prof and prof.appearance and prof.appearance.healthBar
            and prof.appearance.healthBar.gradient
        -- Gradient first; it returns false when off or unavailable on this
        -- build, so the flat colour below stays the fallback rather than
        -- something that has to be kept in step.
        if not (F.ApplyHealthGradient and F.ApplyHealthGradient(button.healthBar, unit, grad)) then
            local useClass = prof and prof.appearance and prof.appearance.healthBar
                and prof.appearance.healthBar.fullColor
                and prof.appearance.healthBar.fullColor[1] == "class_color"
            if useClass then
                local cc = F.GetClassColor(unit)
                button.healthBar:SetStatusBarColor(cc.r, cc.g, cc.b, 1)
            else
                local col = prof and prof.appearance and prof.appearance.healthBar
                    and prof.appearance.healthBar.fullColor
                local r = col and col[2] or 0.2
                local g = col and col[3] or 0.8
                local b = col and col[4] or 0.2
                button.healthBar:SetStatusBarColor(r, g, b, 1)
            end
        end
    end

    -- Health text is NOT touched here -- it's a fully Indicators-owned
    -- built-in (CheckHealthText in BuiltIn_Update.lua, with its own color/
    -- current/max/percentage/textWidth settings), which also listens to
    -- UNIT_HEALTH. This function used to unconditionally overwrite
    -- button.healthText with a hardcoded "current / max" format on every
    -- single health tick, stomping whatever CheckHealthText had just
    -- rendered a moment earlier -- every Health Text setting looked like it
    -- did nothing because this reasserted the hardcoded format right after.
end

local function UpdatePower(button)
    if not button or not button.unit then return end
    local unit = button.unit

    -- Layout preview: fake a full power bar for slots with no real unit.
    if button._sfFakeName then
        if button.powerBar then
            button.powerBar:SetMinMaxValues(0, 100)
            button.powerBar:SetValue(100)
            button.powerBar:SetStatusBarTexture(GetBarTexture())
            button.powerBar:Show()
            local prof = GetProfile()
            local col = prof and prof.appearance and prof.appearance.powerBar and prof.appearance.powerBar.powerColor
            if col and col[1] == "class_color" and button._sfFakeClass then
                local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[button._sfFakeClass]
                if cc then button.powerBar:SetStatusBarColor(cc.r, cc.g, cc.b, 0.8) end
            elseif col and col[1] == "custom_color" then
                button.powerBar:SetStatusBarColor(col[2] or 1, col[3] or 1, col[4] or 1, 0.8)
            else
                local colors = PowerBarColor["MANA"] or {r = 1, g = 1, b = 1}
                button.powerBar:SetStatusBarColor(colors.r, colors.g, colors.b, 0.8)
            end
        end
        return
    end

    if not UnitExists(unit) then return end
    local isConnected = UnitIsConnected(unit)
    if not isConnected or UnitIsDead(unit) or UnitIsGhost(unit) then
        if button.powerBar then
            button.powerBar:SetMinMaxValues(0, 1)
            button.powerBar:SetValue(0)
            button.powerBar:Hide()
        end
        return
    end

    -- Power bar: StatusBar handles secret values at C level.
    -- Pass raw UnitPowerMax/UnitPower to SetMinMaxValues/SetValue.
    if not button.powerBar then return end

    -- Arena opponents: UnitPowerMax/UnitPower can return secrets.
    -- C-level SetMinMaxValues/SetValue handles them without taint.
    button.powerBar:SetMinMaxValues(0, UnitPowerMax(unit) or 1)
    button.powerBar:SetValue(UnitPower(unit) or 0)
    button.powerBar:SetStatusBarTexture(GetBarTexture())
    button.powerBar:Show()

    -- Power color: class_color > custom_color > Blizzard's stock per-power-
    -- type color (mana=blue/rage=red/etc, PowerBarColor). The options panel
    -- writes powerColor[1] == "blizzard_default" explicitly for the third
    -- mode, but anything that isn't "class_color"/"custom_color" (including
    -- a missing/nil powerColor on a fresh profile) falls through to this
    -- same else branch, so no separate check is needed for it.
    local prof = GetProfile()
    local col = prof and prof.appearance and prof.appearance.powerBar and prof.appearance.powerBar.powerColor
    if col and col[1] == "class_color" then
        local cc = F.GetClassColor(unit)
        button.powerBar:SetStatusBarColor(cc.r, cc.g, cc.b, 0.8)
    elseif col and col[1] == "custom_color" then
        button.powerBar:SetStatusBarColor(col[2] or 1, col[3] or 1, col[4] or 1, 0.8)
    else
        local colors = F.GetPowerColor(unit)
        button.powerBar:SetStatusBarColor(colors.r, colors.g, colors.b, 0.8)
    end
end

-- Name text is fully Indicators-owned (CheckNameText in BuiltIn_Update.lua,
-- with its own color/textWidth/showGroupNumber settings), which also
-- listens to the same roster/name events. There used to be an UpdateName()
-- here that unconditionally did button.nameText:SetText(name) on every
-- UNIT_HEALTH tick (via UpdateButtonAll below) -- same stomping bug as
-- UpdateHealth's old healthText block, just for Name Text instead.

local function UpdateRole(button)
    if not button or not button.unit then return end
    local unit = button.unit
    if not UnitExists(unit) then return end

    -- F.GetRoleKey gates UnitGroupRolesAssigned against a secret return
    -- (12.1), falls back to the player's own SPEC role when no group role is
    -- assigned (solo), and normalizes anything still unknown to DAMAGER.
    local roleKey = F.GetRoleKey(unit)
    button.roleIcon:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES")
    if roleKey == "TANK" then
        button.roleIcon:SetTexCoord(0, 0.296875, 0.328125, 0.625)
    elseif roleKey == "HEALER" then
        button.roleIcon:SetTexCoord(0.3125, 0.609375, 0.015625, 0.3125)
    else
        button.roleIcon:SetTexCoord(0.3125, 0.609375, 0.328125, 0.625)
    end
    button.roleIcon:Show()
end

-- Incoming-summon status text (Pending/Accepted/Declined). Ellesmere consumes
-- C_IncomingSummon.HasIncomingSummon/IncomingSummonStatus with a plain `if`
-- test, no issecretvalue() guard -- unlike UnitIsAFK, this API isn't secret
-- on this client. Enum.SummonStatus falls back to raw 1/2/3 defensively, same
-- as Ellesmere, in case the enum table isn't populated.
local SUMMON_STATUS_PENDING  = Enum.SummonStatus and Enum.SummonStatus.Pending or 1
local SUMMON_STATUS_ACCEPTED = Enum.SummonStatus and Enum.SummonStatus.Accepted or 2
local SUMMON_STATUS_DECLINED = Enum.SummonStatus and Enum.SummonStatus.Declined or 3

local function GetSummonStatusText(unit)
    if not C_IncomingSummon or not C_IncomingSummon.HasIncomingSummon then return nil end
    if not C_IncomingSummon.HasIncomingSummon(unit) then return nil end
    local status = C_IncomingSummon.IncomingSummonStatus(unit)
    if status == SUMMON_STATUS_PENDING then return L["Pending"]
    elseif status == SUMMON_STATUS_ACCEPTED then return L["Accepted"]
    elseif status == SUMMON_STATUS_DECLINED then return L["Declined"]
    end
    return nil
end

-- Drinking/eating detection: SquizzFrames.defaults.drinks is a curated
-- Food & Drink spell-ID list (see Defaults/Indicator_Defaults.lua) that
-- already existed but was never consumed anywhere. C_UnitAuras.GetAuraData
-- BySpellId does not exist on this client (confirmed via debug print --
-- BuiltIn_Update.lua's ScanAurasForCooldownGrid, used by External/Defensive
-- Cooldowns, relies on the same missing API and is silently broken too) --
-- use the by-index scan CheckDebuffs already uses successfully instead.
-- TEMPORARY diagnostic (/sfdrinktest <unit>, default "party1") -- chasing a
-- user report that Drinking status works in town but silently fails inside a
-- Mythic+ dungeon specifically (confirmed correct at the same moment in Cell,
-- so it's not a blanket Blizzard restriction -- something in THIS scan is
-- either not finding the aura at all, or finding it with a secret spellId
-- that F.IsValueNonSecret's guard (added earlier this session for the
-- crash fix) then silently treats as "not a match" rather than "drinking").
-- Remove once the real cause is confirmed.
SLASH_SQUIZZDRINKTEST1 = "/sfdrinktest"
SlashCmdList["SQUIZZDRINKTEST"] = function(msg)
    local unit = (msg and msg ~= "" and msg) or "party1"
    if not UnitExists(unit) then
        print("|cffff0009[SquizzFrames]|r drink test: unit '" .. unit .. "' doesn't exist")
        return
    end
    local drinks = SquizzFrames.defaults and SquizzFrames.defaults.drinks or {}
    local drinkSet = {}
    for _, id in ipairs(drinks) do drinkSet[id] = true end
    local i, scanned, secretCount = 1, 0, 0
    print("|cff33cc99[SquizzFrames]|r drink test: scanning " .. unit .. "...")
    while i <= 40 do
        local ok, info = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
        if not ok then
            secretCount = secretCount + 1
            i = i + 1
        elseif not info then
            break
        else
            scanned = scanned + 1
            local idReadable = F.IsValueNonSecret(info.spellId)
            local nameReadable = F.IsValueNonSecret(info.name)
            local isMatch = idReadable and drinkSet[info.spellId]
            print(string.format("  #%d spellId=%s name=%s match=%s",
                i, idReadable and tostring(info.spellId) or "<secret>",
                nameReadable and tostring(info.name) or "<secret>",
                tostring(isMatch)))
            i = i + 1
        end
    end
    print("|cff33cc99[SquizzFrames]|r drink test: " .. scanned .. " auras readable, "
        .. secretCount .. " slots threw/secret, result=" .. tostring(IsUnitDrinking and IsUnitDrinking(unit)))
end

function IsUnitDrinking(unit)
    local drinks = SquizzFrames.defaults and SquizzFrames.defaults.drinks
    if not drinks or #drinks == 0 then return false end
    if not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then return false end
    local drinkSet = {}
    for _, id in ipairs(drinks) do drinkSet[id] = true end
    local i = 1
    while i <= 40 do
        local ok, info = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
        if not ok then
            -- Same break-vs-continue distinction as Custom_Dispatch.lua's
            -- Scan -- a single secret slot mid-combat isn't "past the last
            -- aura", skip just this index instead of giving up the whole scan.
            i = i + 1
        elseif not info then
            break
        else
            i = i + 1
            -- info.spellId commonly goes secret in combat -- indexing
            -- drinkSet with a secret key hard-errors ("attempted to index a
            -- table that cannot be indexed with secret keys", confirmed via
            -- a live error report) rather than just returning nil, and
            -- nothing here catches it -- must gate with F.IsValueNonSecret
            -- before ever using it as a table key (same fix BuiltIn_Update
            -- .lua's ScanAurasForCooldownGrid/CheckDebuffs needed).
            if F.IsValueNonSecret(info.spellId) and drinkSet[info.spellId] then return true end
        end
    end
    return false
end

-- Status timer: Status Text's "Show Timer" (on by default) had a checkbox and
-- a saved setting but nothing read it, so AFK/Dead never counted (user report
-- 2026-10-04). The game says nothing about WHEN a status began, so each one is
-- timed from the moment we first see it -- a /reload restarts the count.
--
-- Keyed by GUID, not unit token or button: the secure header reassigns tokens
-- and buttons on every re-sort, and a timer must follow the PERSON. The token
-- is the fallback if a GUID ever reads secret.
local statusSince = {}          -- key -> { kind = "DEAD"|"GHOST"|"OFFLINE"|"AFK", t = GetTime() }
local statusTicker              -- 1s, only while some button shows a timed status
local EnsureStatusTicker        -- forward: defined after UpdateStatus

-- Never secret: the GUID is returned only once F.IsValueNonSecret has passed
-- it, and the unit token is our own plain string.
---@return string
local function StatusKey(unit)
    local guid = UnitGUID(unit)
    if guid and F.IsValueNonSecret(guid) then return guid end
    return unit
end

-- The "m:ss" since the status began, or nil when Show Timer is off.
local function StatusTimer(button, unit, kind)
    local key = StatusKey(unit)
    local rec = statusSince[key]
    if not rec or rec.kind ~= kind then
        rec = { kind = kind, t = GetTime() }
        statusSince[key] = rec
    end
    local t = button.statusText.configs or button.statusText._sfTable
    if t and t.showTimer == false then
        button._sfStatusTimed = nil
        return nil
    end
    button._sfStatusTimed = true
    EnsureStatusTicker()
    local secs = math.floor(GetTime() - rec.t)
    return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
end

-- "Timer on Other Side" (timerOpposite, user request 2026-10-05): the timer
-- gets a FontString of its own on the health bar's opposite edge, level with
-- the label -- label at LEFT puts the timer at RIGHT, TOPLEFT at TOPRIGHT,
-- BOTTOM (centred) at BOTTOMRIGHT -- with the label's x offset mirrored. Font,
-- colour and shadow are copied from the label on every update, so it follows
-- whatever the indicator's font settings make of the label without any wiring
-- of its own.
local function StatusTimerString(button)
    local fs = button.statusText
    -- On the label's level frame (BuiltIn_Update's GiveRegionRealFrameLevel),
    -- so Frame Level lifts the timer too. NOT fs:GetParent(): that is
    -- overridden to answer the button, which put the timer at the button's
    -- level, under the shield overlay. Re-checked each time, since the level
    -- frame can arrive after the timer was made.
    local host = fs._sfLevelFrame or button
    local tm = fs._sfTimer
    if not tm then
        tm = host:CreateFontString(nil, fs:GetDrawLayer() or "ARTWORK")
        fs._sfTimer = tm
    elseif tm:GetParent() ~= host then
        tm:SetParent(host)
    end
    local t = fs.configs or fs._sfTable
    local p = t and t.position or {}
    local point = type(p[1]) == "string" and p[1] or "CENTER"
    local vert = point:match("^TOP") and "TOP" or (point:match("^BOTTOM") and "BOTTOM" or "")
    local tp = vert .. (point:find("RIGHT") and "LEFT" or "RIGHT")
    local bar = button.healthBar or button
    tm:ClearAllPoints()
    tm:SetPoint(tp, bar, tp, -(tonumber(p[4]) or 0), tonumber(p[5]) or 0)

    local font, size, flags = fs:GetFont()
    if font then tm:SetFont(font, size, flags or "") end
    tm:SetTextColor(fs:GetTextColor())
    tm:SetShadowColor(fs:GetShadowColor())
    tm:SetShadowOffset(fs:GetShadowOffset())
    if tm.SetIgnoreParentAlpha then
        tm:SetIgnoreParentAlpha(fs:IsIgnoringParentAlpha())
        tm:SetAlpha(fs:GetAlpha())
    end
    return tm
end

-- Show a status: the label, with its timer (if any) either inline ("AFK 1:23")
-- or on the other side of the bar.
local function ShowStatus(button, label, timer)
    local fs = button.statusText
    local t = fs.configs or fs._sfTable
    if timer and t and t.timerOpposite then
        fs:SetText(label)
        fs:Show()
        local tm = StatusTimerString(button)
        tm:SetText(timer)
        tm:Show()
        return
    end
    fs:SetText(timer and (label .. " " .. timer) or label)
    fs:Show()
    if fs._sfTimer then fs._sfTimer:Hide() end
end

local function UpdateStatus(button)
    if not button or not button.unit then return end
    local unit = button.unit

    -- Layout preview: no status text for fake slots (nothing to report).
    if button._sfFakeName then
        button.statusText:Hide()
        if button.statusText._sfTimer then button.statusText._sfTimer:Hide() end
        return
    end

    if not UnitExists(unit) then return end

    -- UnitIsAFK can return a secret boolean for group units on this client
    -- (UnitIsConnected/UnitIsDead/UnitIsGhost don't -- confirmed against
    -- EllesmereUIRaidFrames, same PTR client) -- issecretvalue() must gate
    -- it before any boolean test, or this throws "attempt to perform
    -- boolean test on a secret boolean value" the moment it's true.
    local isAFK = not issecretvalue(UnitIsAFK(unit)) and UnitIsAFK(unit)

    if isAFK then
        ShowStatus(button, L["AFK"], StatusTimer(button, unit, "AFK"))
    elseif not UnitIsConnected(unit) or UnitIsDead(unit) or UnitIsGhost(unit) then
        local isGhost = UnitIsGhost(unit)
        local isDead = UnitIsDead(unit)
        local kind = isGhost and "GHOST" or (isDead and "DEAD" or "OFFLINE")
        local label = isGhost and L["Ghost"] or (isDead and L["Dead"] or L["Offline"])
        ShowStatus(button, label, StatusTimer(button, unit, kind))
    else
        -- No timed status any more: forget when it began, so the next one
        -- starts from 0:00 rather than from the last.
        statusSince[StatusKey(unit)] = nil
        button._sfStatusTimed = nil
        if button.statusText._sfTimer then button.statusText._sfTimer:Hide() end
        local summonText = GetSummonStatusText(unit)
        if summonText then
            button.statusText:SetText(summonText)
            button.statusText:Show()
        elseif IsUnitDrinking(unit) then
            button.statusText:SetText(L["Drinking"])
            button.statusText:Show()
        else
            button.statusText:Hide()
        end
    end

    -- Keep the "Show Background" texture (see BuiltIn_Update.lua's
    -- CreateBuiltInIndicator statusText branch) in sync with the text's own
    -- show/hide -- never show an empty background box when there's no
    -- status to display.
    local bg = button.statusText._sfBG
    if bg then
        local t = button.statusText.configs or button.statusText._sfTable
        bg:SetShown(t and t.showBackground and button.statusText:IsShown())
    end
end

-- Status Text at full opacity however far its button has faded for range
-- (user request 2026-10-04): AFK/Dead/Offline is exactly what you need to read
-- on a faded frame. It IGNORES its parents' alpha and takes the CONTAINER's
-- instead, so it still follows the blanket Frame Opacity -- ignoring all alpha
-- would leave the text floating over frames that had faded out. Called from
-- the range poll, the range reset and ApplyOpacity: every place either alpha
-- changes.
local function SyncStatusTextAlpha(button)
    if not button then return end
    local partyFrame = GetPartyFrame()
    local a = partyFrame and partyFrame:GetEffectiveAlpha() or 1

    -- The Status Icon (ready check, AFK, dead, offline, summon...) gets the
    -- same treatment (user request 2026-10-17): it is the other thing you
    -- need to read on a faded frame. It has no opacity setting of its own to
    -- overwrite. A rebuilt indicator picks this up on the next range poll.
    local icon = button.indicators and button.indicators.statusIcon
    if icon and icon.SetIgnoreParentAlpha then
        icon:SetIgnoreParentAlpha(true)
        icon:SetAlpha(a)
    end

    local fs = button.statusText
    if not (fs and fs.SetIgnoreParentAlpha) then return end
    fs:SetIgnoreParentAlpha(true)
    fs:SetAlpha(a)
    local bg = fs._sfBG
    if bg and bg.SetIgnoreParentAlpha then
        bg:SetIgnoreParentAlpha(true)
        bg:SetAlpha(a)
    end
    local tm = fs._sfTimer
    if tm then
        tm:SetIgnoreParentAlpha(true)
        tm:SetAlpha(a)
    end
end

local function SyncAllStatusTextAlpha()
    for _, button in pairs(unitButtons) do SyncStatusTextAlpha(button) end
end

-- Recount the visible timers once a second; stops itself when none are left.
local function TickStatusTimers()
    local any = false
    ForEachHeaderButton(function(button)
        if button._sfStatusTimed then
            any = true
            UpdateStatus(button)
        end
    end)
    if not any and statusTicker then
        statusTicker:Cancel()
        statusTicker = nil
    end
end

EnsureStatusTicker = function()
    if not statusTicker then statusTicker = C_Timer.NewTicker(1, TickStatusTimers) end
end

local function UpdateButtonAll(button)
    if not button then return end
    UpdateHealth(button)
    UpdatePower(button)
    UpdateStatus(button)
end

local function UpdateAllButtons()
    -- The secure header manages per-child visibility based on whether each
    -- unit exists (driven by showSolo/showParty/showRaid attributes).
    -- We only need to update the visual content of wired buttons here.
    for unit, button in pairs(unitButtons) do
        if UnitExists(unit) then
            UpdateButtonAll(button)
        end
    end
end

PartyFrames.buttons = {
    UpdateHealth = UpdateHealth,
    UpdatePower = UpdatePower,
    UpdateStatus = UpdateStatus,
    UpdateButtonAll = UpdateButtonAll,
    UpdateAllButtons = UpdateAllButtons,
    SyncStatusTextAlpha = SyncStatusTextAlpha,
    SyncAllStatusTextAlpha = SyncAllStatusTextAlpha,
}
