--[[ SquizzFrames Custom_Dispatch.lua - Custom indicator aura scanner + dispatcher ]]
--
-- Implements the runtime side of Cell-style custom indicators. Mirrors Cell's
-- Indicators/Custom.lua:
--   * enabledIndicators & customIndicators tables for fast aura dispatch.
--   * UpdateIndicatorTable(t) — rebuilds a custom indicator's aura lookup.
--   * CreateCustomIndicatorFrame(button, t) — creates the frame for a type
--     (icon, icons, text, bar, bars, rect, color, texture, glow, overlay,
--     block, blocks, border).
--   * Scan(button) — called on UNIT_AURA; feeds found auras to the dispatcher.
--   * Show(button, auraType) — sorts found auras and calls SetCooldown.
--   * Reset(button, auraType) — clears found auras and hides indicators.
--   * Rebuild() — rebuilds all lookup tables from the current profile.
--   * InitPreview(button) — push fake aura data to the preview button.
--
-- Midnight 12.0.0+ secret-value safety: uses F.IsValueNonSecret() to guard
-- against using secret spellId/expirationTime/etc as table keys or in
-- arithmetic. FontString:SetText and Texture:SetTexture accept secrets safely.

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F

local CD = SquizzFrames:NewModule("Custom_Dispatch", "AceEvent-3.0")

-- LCG for glow indicators (optional).
local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)

-- ------------------------------------------------------------------
-- Registry
-- ------------------------------------------------------------------
-- Namespaced by context ("main"/"raid") -- Party and Raid each have their
-- own independent indicator array now (see Indicators.lua's
-- I.GetIndicatorsList comment), so a custom indicator of the same name can
-- exist in BOTH with entirely different tracked auras/settings. Every
-- function below that reads these resolves its own context via GetContext
-- (button) first, same pattern as Indicators.lua's I.IsRaidContext.
local enabledIndicators = { main = {}, raid = {} }
local customIndicators = {
    main = { ["buff"] = {}, ["debuff"] = {} },
    raid = { ["buff"] = {}, ["debuff"] = {} },
}

-- Resolves which context's registry a given button should read/write --
-- real buttons follow the actual current group state, the preview button
-- follows whichever Designer tab is open. Delegates to Indicators.lua's
-- I.IsRaidContext so there's exactly one implementation of this decision.
local function GetContext(button)
    local IndicatorsModule = SquizzFrames.modules and SquizzFrames.modules["Indicators"]
    local isRaid = IndicatorsModule and IndicatorsModule.IsRaidContext and IndicatorsModule.IsRaidContext(button)
    return isRaid and "raid" or "main"
end

-- Learned real durations, spellId -> seconds. Blizzard's secret-value system
-- never exposes the LIVE remaining-time number to Lua once a value goes
-- secret (routinely happens mid-combat) -- but the spell's own duration is
-- effectively constant, so once we've read it successfully even ONCE (out
-- of combat, or any live read that happens to be non-secret), we can keep
-- animating a bar smoothly afterward using our OWN GetTime()-based clock
-- (never secret) instead of needing Blizzard's number again. See
-- UpdateIndicator's fallback and CD.ShowCustomIndicators' cache-clear.
local spellDurationCache = {}


-- Consecutive scan-pass misses required before a "color" type single-slot
-- indicator is actually treated as absent -- see ResetCustomIndicators/
-- UpdateIndicator/ShowCustomIndicators. Confirmed live: the manual per-pass
-- C_UnitAuras.GetAuraDataByIndex walk intermittently fails to find a
-- genuinely still-active aura in combat (scan ordering volatility, not a
-- secret-value issue), so treating a single miss as "gone" caused the
-- overlay to instantly clear seconds into combat despite the buff staying
-- up. 3 passes is a few UNIT_AURA events' worth of grace, not a perceptible
-- delay on genuine expiry.
local MISS_STREAK_THRESHOLD = 3

-- ------------------------------------------------------------------
-- UpdateIndicatorTable: rebuild the aura lookup for one custom indicator.
-- Mirrors Cell's I.UpdateIndicatorTable.
-- ------------------------------------------------------------------
function CD.UpdateIndicatorTable(t, context)
    context = context or "main"
    local indicatorName = t.indicatorName
    local auraType = t.auraType
    if not indicatorName or not auraType then return end

    -- "color" type indicators that meet AuraEngineIndicators.lua's
    -- CreateCustomColorIndicator criteria are STILL registered here, even
    -- though their actual show/hide is driven entirely by that
    -- AuraContainer-backed wrapper (never by this module) -- the scan below
    -- is the only place auraInstanceID is ever readable in this codebase
    -- (bare/noRegions AuraContainer slots never expose per-aura data to
    -- Lua, by design), and CreateCustomColorIndicator's threshold-recolor
    -- feature needs it. ShowCustomIndicators checks which method the
    -- indicator frame actually has (SetCooldown vs SetAuraInstanceID) and
    -- calls the right one -- see its comment.

    if t.enabled then
        enabledIndicators[context][indicatorName] = true
    else
        enabledIndicators[context][indicatorName] = nil
    end

    local entry = {}
    entry.name = t.name
    entry.type = t.type
    entry.castBy = t.castBy
    entry.auras = F.ConvertSpellTable(t.auras)

    -- Priority-order lookup (spell/name key -> 1-based position in t.auras),
    -- separate from entry.auras above -- that's a boolean presence SET
    -- (F.ConvertSpellTable always stores `true`), not an order value. Both
    -- UpdateIndicator's single-slot "keep the top-priority aura" logic and
    -- the multi-slot sort comparator used to read entry.auras[spell] AS a
    -- priority number, which is always the boolean `true` for any matched
    -- spell -- comparing that against a real number ("true < 999") throws
    -- "attempt to compare boolean with number" the instant a single-slot
    -- custom indicator (bar/text/rect/color/glow/border) actually matches.
    entry.auraOrder = {}
    if t.auras then
        for idx, v in ipairs(t.auras) do
            local key = v
            if type(v) == "string" then
                local id = tonumber(v:match("^(%d+)$"))
                key = id or v:lower()
            end
            if key and entry.auraOrder[key] == nil then
                entry.auraOrder[key] = idx
            end
        end
    end

    if t.type == "icon" or t.type == "icons" then
        entry.found = {}
        entry.num = t.num or 1
    elseif t.type == "bars" or t.type == "blocks" then
        entry.found = {}
        entry.num = t.num or 1
    elseif t.type == "border" then
        entry.top = {}
        entry.topOrder = {}
        -- Locally-tracked "when did we first see this active" per unit,
        -- keyed separately from entry.top since that gets wiped every scan
        -- pass (see CD.ResetCustomIndicators) -- this persists across passes
        -- until CD.ShowCustomIndicators confirms the aura is genuinely gone.
        entry.localStart = {}
    else
        entry.top = {}
        entry.topOrder = {}
        entry.localStart = {}
    end

    -- Raw ordered aura list (entry.auras above is a lookup SET, unordered --
    -- this is what InitPreview uses to grab "the first configured spell" for
    -- a representative preview icon). Previously only stored for buff-type
    -- indicators; debuff-type custom indicators need it too.
    entry._auras = F.CopyTable(t.auras) or {}
    if auraType == "buff" then
        entry.trackByName = t.trackByName
    end

    -- "color" type: single highlight color (from the customColors picker,
    -- {{r,g,b,a}}) applied to the health bar/button while the top-priority
    -- tracked aura is active. anchor picks which part gets colored (see
    -- CreateColorOverlay below).
    if t.type == "color" then
        local ct = t.customColors and t.customColors[1]
        entry.color = ct and {ct[1] or 0, ct[2] or 1, ct[3] or 0, ct[4] or 1} or nil
        entry.anchor = t.anchor or "healthbar-current"
    end

    -- Marks an entry whose indicator frame is AuraEngineIndicators.lua-backed
    -- (presence driven by the engine, never by this legacy scan). Mirrors
    -- Indicators.lua's I.CreateIndicator routing condition per type --
    -- trackByName/non-12.1 clients stay legacy and need the ordinary
    -- hide/show cycle below. CD.ResetCustomIndicators/ShowCustomIndicators
    -- must never unconditionally :Hide() an engine-backed wrapper -- nothing
    -- calls :Show() on it again since presence comes from the engine, not
    -- Show()/Hide() in this file.
    if t.type == "color" and not t.trackByName and (t.anchor or "healthbar-current") ~= "unitButton"
        and SquizzFrames.IS_121 then
        entry.engineDriven = true
    elseif t.type == "bar" and not t.trackByName and SquizzFrames.IS_121 then
        entry.engineDriven = true
    end

    customIndicators[context][auraType][indicatorName] = entry
end

-- ------------------------------------------------------------------
-- Rebuild: recompute all lookup tables from the profile.
-- ------------------------------------------------------------------
-- Rebuilds ONE context's lookup tables from its own indicator list.
local function RebuildContext(context, isRaid)
    wipe(enabledIndicators[context])
    wipe(customIndicators[context].buff)
    wipe(customIndicators[context].debuff)

    local IndicatorsModule = SquizzFrames.modules and SquizzFrames.modules["Indicators"]
    local list = IndicatorsModule and IndicatorsModule.GetIndicatorsList and IndicatorsModule.GetIndicatorsList(isRaid)
    if not list then return end

    -- Skip built-ins: they start at index 1 through the constant 15.
    for i = 16, #list do
        local t = list[i]
        if t and t.type ~= "built-in" then
            CD.UpdateIndicatorTable(t, context)
        end
    end
end

function CD:Rebuild()
    RebuildContext("main", false)
    RebuildContext("raid", true)
end

-- ------------------------------------------------------------------
-- Custom indicator frame creation by type
-- ------------------------------------------------------------------
-- Simplified versions of Cell's Base.lua types. Each returns a frame that
-- responds to SetCooldown / Show / Hide and is stored on button.indicators.

local function CreateIconFrame(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(13, 13)
    f:Hide()
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetAllPoints()
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.cooldown = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
    f.cooldown:SetAllPoints()
    f.cooldown:SetDrawEdge(true)
    f.stack = f:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    f.stack:SetPoint("BOTTOMRIGHT", 1, -1)
    f.stack:Hide()
    f._durationMode = "always"
    f._showStack = true
    function f:SetDurationMode(mode)
        self._durationMode = mode
        self.cooldown:SetHideCountdownNumbers(mode == "never")
    end

    -- Stack + duration font settings, from the options panel's two font
    -- blocks ({name, size, outline, shadow, anchor, xOffset, yOffset, color};
    -- slot 1 = stack, slot 2 = duration -- same shape AE.ApplyFontSettings
    -- consumes for the engine-backed indicators).
    --
    -- Neither had any effect before (user report 2026-08-13, "the font size is
    -- still too big" with the size slider already at its minimum). The stack
    -- FontString was created from the NumberFontNormal font object and never
    -- re-fonted, and the duration isn't our FontString at all -- it's the
    -- Cooldown frame's built-in countdown numbers, which use Blizzard's own
    -- font and scale with the cooldown's size, ignoring everything the panel
    -- offered.
    --
    -- The countdown goes through SetCountdownFont, which takes the NAME of a
    -- Font OBJECT (not a path/size), so one is created per frame and
    -- re-pointed in place. GetCountdownFontString is used only for the colour,
    -- which SetCountdownFont doesn't carry -- deliberately not for the font
    -- itself, since Blizzard owns that FontString and reapplies its own font
    -- object to it.
    --
    -- The countdown's ANCHOR and OFFSET are not applied: that FontString is
    -- positioned by the Cooldown frame itself, and moving it just gets
    -- overwritten. Size, outline and colour are the parts that stick.
    -- Indicators.lua owns the real resolver (LSM key -> path, with a Friz
    -- Quadrata fallback) and publishes it on F. Never pass a raw setting
    -- straight to SetFont: font names here are LibSharedMedia KEYS like
    -- "Friz QT__", and SetFont hard-errors on one.
    local function ResolveFont(name)
        if F.ResolveFontFile then return F.ResolveFontFile(name) end
        if type(name) == "string"
            and (name:match("^[Ff]onts\\") or name:match("^[Ii]nterface\\")) then
            return name
        end
        return [[Fonts\FRIZQT__.TTF]]
    end
    local countdownFontIndex = 0
    function f:SetFontTable(fontTable)
        if type(fontTable) ~= "table" or type(fontTable[1]) == "string" then return end

        local s = fontTable[1]
        if type(s) == "table" then
            local flags = s[3]
            if flags == "NONE" then flags = nil end
            local size = tonumber(s[2])
            if size and size > 0 then
                self.stack:SetFont(ResolveFont(s[1]), size, flags)
            end
            self.stack:ClearAllPoints()
            local point = s[5] or "BOTTOMRIGHT"
            self.stack:SetPoint(point, self, point, tonumber(s[6]) or 1, tonumber(s[7]) or -1)
            if type(s[8]) == "table" then
                self.stack:SetTextColor(s[8][1] or 1, s[8][2] or 1, s[8][3] or 1, s[8][4] or 1)
            end
        end

        local d = fontTable[2]
        if type(d) == "table" then
            local flags = d[3]
            if flags == "NONE" then flags = nil end
            local size = tonumber(d[2])
            if size and size > 0 and self.cooldown.SetCountdownFont then
                if not self._countdownFont then
                    countdownFontIndex = countdownFontIndex + 1
                    self._countdownFont = CreateFont(
                        "SquizzFramesCustomCountdownFont" .. countdownFontIndex .. "_" .. tostring(self):gsub("[^%w]", ""))
                end
                self._countdownFont:SetFont(ResolveFont(d[1]), size, flags)
                self.cooldown:SetCountdownFont(self._countdownFont:GetName())
            end
            if type(d[8]) == "table" and self.cooldown.GetCountdownFontString then
                local cs = self.cooldown:GetCountdownFontString()
                if cs then cs:SetTextColor(d[8][1] or 1, d[8][2] or 1, d[8][3] or 1, d[8][4] or 1) end
            end
        end
    end
    -- Master on/off for the stack-count text, independent of the >1/secret
    -- gating below -- see BuiltIn_Update.lua's identical CreateCooldownGrid
    -- method for the full reasoning.
    function f:SetShowStack(show)
        self._showStack = (show ~= false)
    end
    function f:SetCooldown(start, duration, debuffType, icon, count, refreshing, color, unit, auraInstanceID, spellId)
        if icon then self.icon:SetTexture(icon) end
        -- Prefer the secret-safe duration-object swipe (C_UnitAuras.GetAuraDuration
        -- + SetCooldownFromDurationObject) whenever we have unit+auraInstanceID --
        -- same fix/reasoning as BuiltIn_Update.lua's SetCooldownFromAura. The
        -- plain start/duration path below requires those to be non-secret and
        -- just goes blank the moment they aren't (the "swipe not displaying in
        -- combat" report, same bug, this file's custom debuff indicators).
        local applied = false
        if unit and auraInstanceID and C_UnitAuras and C_UnitAuras.GetAuraDuration and self.cooldown.SetCooldownFromDurationObject then
            local durObj = C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
            if durObj then
                self.cooldown:SetCooldownFromDurationObject(durObj)
                if durObj.IsZero and self.cooldown.SetAlphaFromBoolean then
                    self.cooldown:SetAlphaFromBoolean(durObj:IsZero(), 0, 1)
                else
                    self.cooldown:SetAlpha(1)
                end
                applied = true
            end
        end
        if applied then
            -- swipe already set from the duration object above
        elseif start and duration and duration > 0 then
            self.cooldown:SetCooldown(start, duration)
        else
            self.cooldown:Clear()
        end
        -- count (info.applications, via UpdateIndicator/entry.top) routinely
        -- goes secret in combat -- comparing it to 1 directly throws
        -- ("attempt to compare... a secret number value", confirmed via a
        -- live error report on the equivalent BuiltIn_Update.lua code) rather
        -- than returning false.
        --
        -- C_UnitAuras.GetAuraApplicationDisplayCount(unit, auraInstanceID,
        -- minCount, maxCount) resolves this the same way
        -- BuiltIn_Update.lua's ApplySlotVisuals now does: Blizzard does the
        -- >=threshold comparison entirely engine-side and hands back
        -- ready-to-display text or nil, so the secret count is never
        -- read/compared in Lua at all. Confirmed via EllesmereUIRaidFrames'
        -- own working stack-count code (same call, same 2/99 thresholds),
        -- per explicit user request to match its approach. Falls back to a
        -- plain non-secret comparison when unit/auraInstanceID aren't
        -- available (e.g. preview/mock data) or the API doesn't exist.
        local showStack, stackText = false, nil
        if self._showStack then
            if unit and auraInstanceID and C_UnitAuras.GetAuraApplicationDisplayCount then
                stackText = C_UnitAuras.GetAuraApplicationDisplayCount(unit, auraInstanceID, 2, 99)
                showStack = stackText ~= nil
            elseif count and F.IsValueNonSecret(count) then
                showStack = count > 1
            end
        end
        if not showStack then
            self.stack:Hide()
        else
            if stackText then
                self.stack:SetText(stackText)
            else
                self.stack:SetFormattedText("%d", count)
            end
            self.stack:Show()
        end
        self:Show()
    end
    return f
end

local function CreateTextFrame(parent)
    local f = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f:Hide()
    function f:SetCooldown(start, duration, debuffType, icon, count, refreshing, color)
        local text = ""
        -- Same secret-count issue as CreateIconFrame above, but this
        -- function CONCATENATES count into a combined string (unlike a
        -- standalone SetText(count) call) -- `..`/`~=` on a value derived
        -- from a secret number taints/throws same as direct comparison, so
        -- there's no safe way to fold a secret count into this text at all.
        -- Skip it when secret (undercounts info) rather than risk the crash.
        if count and F.IsValueNonSecret(count) and count > 0 then
            text = tostring(count)
        end
        if duration and duration > 0 then
            text = (text ~= "" and text .. " " or "") .. format("%.0f", duration)
        end
        self:SetText(text)
        if color then
            self:SetTextColor(color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1)
        end
        self:Show()
    end
    return f
end

local function CreateBarFrame(parent)
    local f = CreateFrame("StatusBar", nil, parent)
    f:SetSize(18, 4)
    f:SetMinMaxValues(0, 1)
    f:SetValue(0)
    f:Hide()
    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetColorTexture(0, 1, 0, 1)
    tex:SetAllPoints()
    f:SetStatusBarTexture(tex)

    -- ShowCustomIndicators only calls SetCooldown when the aura SCAN
    -- re-runs (UNIT_AURA events), which can be many seconds apart -- without
    -- its own periodic driver the bar just snapshots whatever fraction was
    -- remaining at the last scan and sits there until the next one, instead
    -- of counting down smoothly. Scoped to just this one bar frame and only
    -- alive while it's actually tracking an active countdown (started fresh
    -- each SetCooldown call, cancelled on hide/expiry) -- not a global
    -- always-on OnUpdate loop.
    local ticker
    local function StopTicker()
        if ticker then ticker:Cancel(); ticker = nil end
    end
    f:SetScript("OnHide", StopTicker)

    function f:SetCooldown(start, duration, debuffType, icon, count, refreshing, color, unit, auraInstanceID)
        StopTicker()
        if color then tex:SetColorTexture(color[1] or 0, color[2] or 1, color[3] or 0, color[4] or 1) end

        -- Preferred: native GPU-side smooth drain via a Duration object from
        -- C_UnitAuras.GetAuraDuration -- an opaque handle the ENGINE
        -- animates internally, never exposing the actual remaining-time
        -- number to Lua at all (confirmed working pattern, reviewed
        -- directly from EllesmereUIRaidFrames' EUI_RaidFrames_BuffManager.lua
        -- installed on this same PTR client: ApplyBarDrain). This works even
        -- when duration/expirationTime themselves are secret, since it never
        -- reads them -- it hands the engine the auraInstanceID and lets IT
        -- compute/animate the fill, the same way Cooldown:SetCooldown
        -- animates a radial swipe without us ever seeing the raw duration.
        if unit and auraInstanceID and C_UnitAuras.GetAuraDuration and self.SetTimerDuration then
            local ok, durObj = pcall(C_UnitAuras.GetAuraDuration, unit, auraInstanceID)
            if ok and durObj then
                self:SetMinMaxValues(0, 1)
                local applied = pcall(self.SetTimerDuration, self, durObj,
                    Enum.StatusBarInterpolation.Immediate, Enum.StatusBarTimerDirection.RemainingTime)
                if applied then
                    self:Show()
                    return
                end
            end
        end

        if not duration or duration <= 0 then
            -- ShowCustomIndicators only ever calls SetCooldown once the aura
            -- was actually found present (see its `if top and top.start`
            -- guard) -- hiding here silently swallowed every buff with no
            -- expiration (most passive/permanent raid buffs, or any aura
            -- whose expirationTime read secret mid-scan and got zeroed by
            -- Scan's IsValueNonSecret fallback). Show a full, static bar
            -- instead of hiding: the buff IS active, it just has nothing to
            -- animate.
            self:SetValue(1)
            self:Show()
            return
        end
        local function Refresh()
            local remaining = (start + duration) - GetTime()
            if remaining <= 0 then
                self:SetValue(0)
                StopTicker()
                return
            end
            self:SetValue(remaining / duration)
        end
        Refresh()
        self:Show()
        ticker = C_Timer.NewTicker(0.1, Refresh)
    end
    return f
end

local function CreateRectFrame(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(11, 4)
    f:Hide()
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    f.tex:SetColorTexture(0, 1, 0, 1)
    function f:SetCooldown(start, duration, debuffType, icon, count, refreshing, color)
        if color then f.tex:SetColorTexture(color[1] or 0, color[2] or 1, color[3] or 0, color[4] or 1) end
        f:Show()
    end
    return f
end

local function CreateColorOverlay(parent, t)
    -- Colors the health bar or the whole unit button's border while the
    -- top-priority tracked aura is active. t.anchor picks the target.
    --
    -- Health-bar coloring is a SEPARATE overlay texture, never
    -- SetStatusBarColor on the real bar -- modeled on EllesmereUIRaidFrames'
    -- "Health Bar Color" indicator (same PTR client, confirmed working): a
    -- white texture anchored to the health bar's OWN fill texture region
    -- (health:GetStatusBarTexture()), tinted via SetVertexColor. WoW's
    -- C-level statusbar math already resizes that fill texture to reflect
    -- current/max health (secret-safe), so the overlay automatically tracks
    -- "filled portion only" without ever computing a width from health
    -- values in Lua. An earlier version called SetStatusBarColor directly on
    -- the real bar instead -- that replaced the bar's TRUE color (e.g. a
    -- low-health warning tint) while the aura was active and only knew how
    -- to restore class color on Hide, silently wrong for any other coloring
    -- mode. This overlay never touches the real bar at all, so there's
    -- nothing to restore -- Hide just hides the overlay.
    --
    -- "healthbar-current", "healthbar-loss" and "healthbar-entire" all
    -- still tint the same fill region -- isolating just the "missing
    -- health" sliver would need secret-unsafe arithmetic on current/max
    -- health, same constraint Ellesmere itself works around by anchoring to
    -- the fill texture rather than computing a width by hand.
    local f = CreateFrame("Frame", nil, parent)
    f:Hide()
    -- Native Hide, captured before f:Hide is overridden below -- there is no
    -- global "Frame" mixin table to call Hide() through (that throws
    -- "attempt to index global 'Frame' (a nil value)" the moment this
    -- overlay is ever hidden, e.g. RemoveAllCustomIndicators wiping customs
    -- before a rebuild).
    local FrameHide = f.Hide

    -- Health-bar overlay texture, built lazily once the health bar exists.
    --
    -- Anchored through AEI.AnchorHealthFillOverlay rather than a plain
    -- SetAllPoints, so it stops short of the power bar and the Frame Border
    -- exactly like the Dispels overlay and the AuraEngine-backed version of
    -- this same indicator. Resolved at call time off the module table: this
    -- file loads after AuraEngineIndicators.lua, which is inert pre-12.1 --
    -- the SetAllPoints fallback below is that (dead) client's behaviour.
    --
    -- Re-anchored on every call, not just at creation: the insets change with
    -- settings this indicator never hears about (border thickness/enabled,
    -- power bar height), and SetCooldown calls this on every aura update, so
    -- re-measuring here is both free and self-correcting.
    local healthOverlay
    local function EnsureHealthOverlay()
        local health = parent.healthBar
        if not health then return nil end
        if not healthOverlay then
            healthOverlay = health:CreateTexture(nil, "ARTWORK", nil, 2)
            healthOverlay:SetColorTexture(1, 1, 1, 1)
            healthOverlay:Hide()
        end
        local AEI = SquizzFrames.AuraEngineIndicators
        if AEI and AEI.AnchorHealthFillOverlay then
            AEI.AnchorHealthFillOverlay(healthOverlay, health)
        else
            local fillTex = health.GetStatusBarTexture and health:GetStatusBarTexture()
            healthOverlay:SetAllPoints(fillTex or health)
        end
        return healthOverlay
    end

    -- Border built lazily -- only unit-button-anchored color indicators pay
    -- for it.
    local border
    local function EnsureBorder()
        if border then return border end
        border = CreateFrame("Frame", nil, parent)
        border:SetPoint("TOPLEFT", parent, "TOPLEFT", -1, 1)
        border:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 1, -1)
        border:Hide()
        local top    = border:CreateTexture(nil, "OVERLAY")
        local bottom = border:CreateTexture(nil, "OVERLAY")
        local left   = border:CreateTexture(nil, "OVERLAY")
        local right  = border:CreateTexture(nil, "OVERLAY")
        top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT"); top:SetHeight(2)
        bottom:SetPoint("BOTTOMLEFT"); bottom:SetPoint("BOTTOMRIGHT"); bottom:SetHeight(2)
        left:SetPoint("TOPLEFT"); left:SetPoint("BOTTOMLEFT"); left:SetWidth(2)
        right:SetPoint("TOPRIGHT"); right:SetPoint("BOTTOMRIGHT"); right:SetWidth(2)
        border._edges = {top, bottom, left, right}
        return border
    end

    function f:SetCooldown(start, duration, debuffType, icon, count, refreshing, color)
        if not color then return end
        local anchor = t and t.anchor or "healthbar-current"
        if anchor == "unitButton" then
            local b = EnsureBorder()
            for _, edge in ipairs(b._edges) do
                edge:SetColorTexture(color[1] or 0, color[2] or 1, color[3] or 0, color[4] or 1)
            end
            b:Show()
        else
            local overlay = EnsureHealthOverlay()
            if overlay then
                if border then border:Hide() end
                overlay:SetVertexColor(color[1] or 0, color[2] or 1, color[3] or 0, color[4] or 1)
                overlay:Show()
            end
        end
        self:Show()
    end
    function f:Hide()
        FrameHide(self)
        if border then border:Hide() end
        if healthOverlay then healthOverlay:Hide() end
    end
    -- Same contract as the AuraEngine wrappers' method of the same name, so
    -- AEI.RefreshBorderInsets picks this up by duck typing when the Frame
    -- Border's thickness or enabled state changes. Only the health-bar overlay
    -- cares -- the unitButton-anchored border draws OUTSIDE the button and has
    -- no relationship to the frame border's own inset.
    function f:RefreshBorderInset()
        if healthOverlay then EnsureHealthOverlay() end
    end
    return f
end

local function CreateGlowFrame(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:Hide()
    local FrameHide = f.Hide
    function f:SetCooldown(start, duration, debuffType, icon, count, refreshing, color)
        if LCG then
            LCG.PixelGlow_Start(parent, color or {0.95, 0.95, 0.32, 1}, 9, 0.25, 8, 2)
        end
        self:Show()
    end
    function f:Hide(clear)
        FrameHide(self)
        if LCG then
            LCG.PixelGlow_Stop(parent)
        end
    end
    return f
end

local function CreateBorderFrame(parent)
    -- Reuse the border-4-texture approach from BuiltIn_Update.
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", 1, -1)
    f:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -1, 1)
    f:Hide()
    local top    = f:CreateTexture(nil, "BORDER")
    local bottom = f:CreateTexture(nil, "BORDER")
    local left   = f:CreateTexture(nil, "BORDER")
    local right  = f:CreateTexture(nil, "BORDER")
    top:SetPoint("TOPLEFT")
    top:SetPoint("TOPRIGHT")
    bottom:SetPoint("BOTTOMLEFT")
    bottom:SetPoint("BOTTOMRIGHT")
    left:SetPoint("TOPLEFT")
    left:SetPoint("BOTTOMLEFT")
    right:SetPoint("TOPRIGHT")
    right:SetPoint("BOTTOMRIGHT")
    top:SetHeight(2); bottom:SetHeight(2); left:SetWidth(2); right:SetWidth(2)
    local function SetAllColor(r, g, b, a)
        top:SetColorTexture(r, g, b, a)
        bottom:SetColorTexture(r, g, b, a)
        left:SetColorTexture(r, g, b, a)
        right:SetColorTexture(r, g, b, a)
    end
    SetAllColor(1, 0, 0, 1)
    function f:SetCooldown(start, duration, debuffType, icon, count, refreshing, color)
        if color then SetAllColor(color[1] or 1, color[2] or 0, color[3] or 0, color[4] or 1) end
        self:Show()
    end
    function f:SetThickness(thick)
        top:SetHeight(thick); bottom:SetHeight(thick)
        left:SetWidth(thick); right:SetWidth(thick)
    end
    return f
end

-- Grid of icon frames (for icons, bars, blocks types).
local function CreateGridFrame(parent, maxSlots)
    maxSlots = maxSlots or 10
    local f = CreateFrame("Frame", nil, parent)
    f:Hide()
    f._slots = {}
    for i = 1, maxSlots do
        f._slots[i] = CreateIconFrame(f)
    end
    -- Lay out horizontally left-to-right by default.
    for i, slot in ipairs(f._slots) do
        slot:ClearAllPoints()
        if i == 1 then
            slot:SetPoint("TOPLEFT", f, "TOPLEFT")
        else
            slot:SetPoint("TOPLEFT", f._slots[i-1], "TOPRIGHT", 1, 0)
        end
    end
    function f:SetCooldown(index, start, duration, debuffType, icon, count, refreshing, color, unit, auraInstanceID, spellId)
        local slot = self._slots[index]
        if slot then slot:SetCooldown(start, duration, debuffType, icon, count, refreshing, color, unit, auraInstanceID, spellId) end
    end
    function f:SetDurationMode(mode)
        for _, slot in ipairs(self._slots) do slot:SetDurationMode(mode) end
    end
    function f:SetShowStack(show)
        for _, slot in ipairs(self._slots) do slot:SetShowStack(show) end
    end
    -- Forwarded like the other per-slot settings above -- the grid itself
    -- draws nothing, every stack/duration string belongs to a slot.
    function f:SetFontTable(fontTable)
        for _, slot in ipairs(self._slots) do
            if slot.SetFontTable then slot:SetFontTable(fontTable) end
        end
    end
    function f:UpdateSize()
        -- Auto-size to contain visible slots.
        local shown = 0
        for _, slot in ipairs(self._slots) do
            if slot:IsShown() then shown = shown + 1 end
        end
        if shown > 0 then
            local w = self._slots[1]:GetWidth()
            local h = self._slots[1]:GetHeight()
            self:SetSize(w * shown + (shown - 1), h)
        end
    end
    return f
end

-- ------------------------------------------------------------------
-- CreateCustomIndicatorFrame: dispatch by type
-- ------------------------------------------------------------------
function CD.CreateCustomIndicatorFrame(button, t)
    if not button or not t then return nil end
    local indicatorName = t.indicatorName
    local indicatorType = t.type
    local parent = button -- most types parent to button
    local indicator

    if indicatorType == "icon" then
        indicator = CreateIconFrame(parent)
    elseif indicatorType == "icons" then
        indicator = CreateGridFrame(parent, (t.num or 5))
    elseif indicatorType == "text" then
        indicator = CreateTextFrame(parent)
    elseif indicatorType == "bar" then
        indicator = CreateBarFrame(parent)
    elseif indicatorType == "bars" then
        indicator = CreateGridFrame(parent, (t.num or 3))
    elseif indicatorType == "rect" then
        indicator = CreateRectFrame(parent)
    elseif indicatorType == "color" then
        indicator = CreateColorOverlay(parent, t)
    elseif indicatorType == "texture" then
        indicator = CreateIconFrame(parent) -- simplified: same as icon
    elseif indicatorType == "glow" then
        indicator = CreateGlowFrame(parent)
    elseif indicatorType == "overlay" then
        indicator = CreateBarFrame(parent) -- simplified: bar on healthBar
    elseif indicatorType == "block" then
        indicator = CreateRectFrame(parent) -- simplified: same as rect
    elseif indicatorType == "blocks" then
        indicator = CreateGridFrame(parent, (t.num or 5))
    elseif indicatorType == "border" then
        indicator = CreateBorderFrame(parent)
    else
        return nil
    end

    indicator._sfType = "custom"
    indicator._sfBuiltIn = false
    return indicator
end

-- Also expose via Indicators module for the HandleIndicators path.
local Indicators = SquizzFrames.modules and SquizzFrames.modules["Indicators"]
if Indicators then
    Indicators.CreateCustomIndicatorFrame = CD.CreateCustomIndicatorFrame
end

-- ------------------------------------------------------------------
-- Reset custom indicators for one button + auraType
-- ------------------------------------------------------------------
function CD.ResetCustomIndicators(button, auraType)
    local unit = button.unit or (button.states and button.states.displayedUnit)
    if not unit then return end
    local ctx = GetContext(button)

    for indicatorName, entry in pairs(customIndicators[ctx][auraType]) do
        if enabledIndicators[ctx][indicatorName] and button.indicators and button.indicators[indicatorName] then
            if entry.found then
                button.indicators[indicatorName]:Hide(true)
                if not entry.found[unit] then entry.found[unit] = {} end
                wipe(entry.found[unit])
            elseif entry.engineDriven then
                -- Engine-backed types (color, bar) -- presence comes from
                -- AuraEngineIndicators/the AuraContainer binding, never from
                -- Show()/Hide() here. Don't unconditionally hide/wipe every
                -- pass like the other single-slot types below; only mark
                -- "not yet confirmed found this scan" -- ShowCustomIndicators
                -- decides whether to actually hide after consecutive misses.
                entry.topOrder[unit] = 999
                entry.foundThisPass = entry.foundThisPass or {}
                entry.foundThisPass[unit] = false
            else
                button.indicators[indicatorName]:Hide(true)
                entry.topOrder[unit] = 999
                if not entry.top[unit] then entry.top[unit] = {} end
                wipe(entry.top[unit])
            end
        end
    end
end

-- ------------------------------------------------------------------
-- Update: record one aura in an indicator's found/top table
-- ------------------------------------------------------------------
local function UpdateIndicator(indicator, entry, unit, spell, start, duration, debuffType, icon, count, refreshing, realSpellId, auraInstanceID)
    if entry.found then
        -- Multi-slot (icons/bars/blocks/icon).
        if not entry.found[unit] then entry.found[unit] = {} end
        tinsert(entry.found[unit], { entry.auraOrder[spell] or 999, start, duration, debuffType, icon, count, refreshing, realSpellId, auraInstanceID })
    else
        -- Single-slot (text/bar/rect/color/glow/border): keep the top-priority aura.
        if not entry.top[unit] then entry.top[unit] = {} end
        if not entry.topOrder[unit] then entry.topOrder[unit] = 999 end
        local order = entry.auraOrder[spell] or 999
        if order < entry.topOrder[unit] then
            entry.topOrder[unit] = order

            if entry.color then
                entry.foundThisPass = entry.foundThisPass or {}
                entry.foundThisPass[unit] = true
                if entry.missStreak then entry.missStreak[unit] = 0 end
            end

            -- Fall back to a locally-tracked start time + the spell's last
            -- KNOWN real duration (spellDurationCache) when THIS read's
            -- live start/duration is unavailable (secret) -- both GetTime()
            -- and the cached duration are ordinary numbers that are never
            -- secret, so a bar-type indicator keeps animating smoothly
            -- through combat instead of freezing/going static the moment
            -- Blizzard hides the live number for this particular read.
            if entry.localStart then
                if duration > 0 and start > 0 then
                    -- Real live reading -- trust it, and (re)sync localStart
                    -- so a LATER secret-value gap picks up from the correct
                    -- remaining point instead of restarting from full.
                    entry.localStart[unit] = start
                else
                    local cached = realSpellId and spellDurationCache[realSpellId]
                    if cached then
                        if not entry.localStart[unit] then
                            entry.localStart[unit] = GetTime()
                        end
                        start = entry.localStart[unit]
                        duration = cached
                    end
                end
            end

            entry.top[unit].start = start
            entry.top[unit].duration = duration
            entry.top[unit].debuffType = debuffType
            entry.top[unit].texture = icon
            entry.top[unit].count = count
            entry.top[unit].refreshing = refreshing
            entry.top[unit].spellId = realSpellId
            entry.top[unit].unit = unit
            entry.top[unit].auraInstanceID = auraInstanceID
        end
    end
end

-- ------------------------------------------------------------------
-- Scan: feed UNIT_AURA data into custom indicators
-- ------------------------------------------------------------------
function CD.Scan(button)
    if not button or not button._indicatorsReady then return end
    local unit = button.unit or (button.states and button.states.displayedUnit)
    if not unit then return end
    local ctx = GetContext(button)

    -- Reset both aura types.
    CD.ResetCustomIndicators(button, "buff")
    CD.ResetCustomIndicators(button, "debuff")

    -- Walk all auras and feed matching ones.
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for auraType, filter in pairs({["buff"] = "HELPFUL", ["debuff"] = "HARMFUL"}) do
            local i = 1
            -- Bounded (matches BuiltIn_Update.lua's ScanAurasForCooldownGrid/
            -- CheckDebuffs/CheckMissingBuffs, the proven-working version of
            -- this exact fix) -- NOT `while true`. A secret slot now skips
            -- via `i = i + 1` instead of breaking, but GetAuraDataByIndex can
            -- apparently keep THROWING (never returning ok=true, info=nil)
            -- for every index past the real aura count on some units, rather
            -- than cleanly reporting "no more auras" -- an unbounded loop
            -- then never reaches its break condition at all ("script ran too
            -- long"). 40 matches the cap used everywhere else in this codebase.
            while i <= 40 do
                local ok, info = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, filter)
                if not ok then
                    -- This ONE slot's data is secret and threw (e.g. an
                    -- anti-sniping measure mid-combat) -- NOT the same thing
                    -- as genuinely running past the last aura. Conflating the
                    -- two here (the old `if not ok or not info then break
                    -- end`) silently truncated the ENTIRE scan the moment
                    -- combat produced a single secret slot, hiding every
                    -- custom indicator whose tracked aura happened to sit
                    -- past that index -- same break-vs-continue bug already
                    -- found and fixed in BuiltIn_Update.lua's
                    -- ScanAurasForCooldownGrid/CheckDebuffs/CheckMissingBuffs
                    -- earlier, just never applied here. Skip just this index
                    -- and keep scanning the rest.
                    i = i + 1
                elseif not info then
                    -- Genuinely past the last aura -- stop.
                    break
                else
                    i = i + 1
                    if F.IsValueNonSecret(info.isHelpful) then
                        local debuffType = nil
                        if info.isHarmful then
                            local raw = info.dispelName
                            debuffType = (raw and F.IsValueNonSecret(raw)) and raw or ""
                        end

                        local spell = info.spellId
                        local start = 0
                        local duration = info.duration or 0
                        if F.IsValueNonSecret(info.expirationTime) then
                            start = info.expirationTime - duration
                        else
                            start = 0
                            duration = 0
                        end

                        -- Learn this spell's real duration whenever we get a
                        -- fully-resolved live reading, so a LATER secret-value
                        -- gap (routine mid-combat) can still animate a bar
                        -- smoothly via GetTime() + this cached number instead
                        -- of going static -- see spellDurationCache's comment
                        -- and UpdateIndicator's fallback below.
                        if F.IsValueNonSecret(spell) and duration > 0 and start > 0 then
                            spellDurationCache[spell] = duration
                        end

                        local sourceUnit = info.sourceUnit

                        -- Feeds CreateBarFrame's preferred native
                        -- SetTimerDuration path (see its comment) --
                        -- auraInstanceID is routinely readable even when
                        -- duration/expirationTime themselves are secret, so
                        -- this alone is often enough for a smooth GPU-driven
                        -- bar even in combat.
                        local auraInstanceID = info.auraInstanceID
                        if not F.IsValueNonSecret(auraInstanceID) then auraInstanceID = nil end

                        for indicatorName, entry in pairs(customIndicators[ctx][auraType]) do
                            if enabledIndicators[ctx][indicatorName] and button.indicators[indicatorName] then
                                local matchKey = spell
                                if entry.trackByName and F.IsValueNonSecret(info.name) then
                                    matchKey = info.name:lower()
                                end

                                if matchKey and F.IsValueNonSecret(matchKey) and entry.auras[matchKey] then
                                    local castBy = entry.castBy
                                    local castOK = (castBy == "anyone")
                                    if not castOK and F.IsValueNonSecret(sourceUnit) then
                                        local byMe = (sourceUnit == "player" or sourceUnit == "pet")
                                        castOK = (castBy == "me" and byMe) or (castBy == "others" and not byMe)
                                    end
                                    if castOK then
                                        UpdateIndicator(
                                            button.indicators[indicatorName], entry, unit,
                                            matchKey, start, duration, debuffType,
                                            info.icon, info.applications, info.refreshing, spell,
                                            auraInstanceID
                                        )
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Show both types.
    CD.ShowCustomIndicators(button, "buff")
    CD.ShowCustomIndicators(button, "debuff")
end

-- ------------------------------------------------------------------
-- Show: sort found auras and call SetCooldown on the indicator frames
-- ------------------------------------------------------------------
local sort = table.sort
local function comparator(a, b)
    if a[1] and b[1] then return a[1] < b[1] else return a[2] <= b[2] end
end

function CD.ShowCustomIndicators(button, auraType)
    if not button or not button._indicatorsReady then return end
    local unit = button.unit or (button.states and button.states.displayedUnit)
    local ctx = GetContext(button)

    for indicatorName, entry in pairs(customIndicators[ctx][auraType]) do
        local indicator = button.indicators and button.indicators[indicatorName]
        if indicator and enabledIndicators[ctx][indicatorName] then
            if entry.found then
                local t = entry.found[unit]
                if t and t[1] then
                    sort(t, comparator)
                    -- Branch on the FRAME's shape, not on entry.found.
                    --
                    -- entry.found is set for "icon" as well as icons/bars/
                    -- blocks (see the type check in CD.Rebuild), but a single
                    -- "icon" gets a plain CreateIconFrame, whose SetCooldown
                    -- signature has NO leading slot index. Feeding it the
                    -- multi-slot call shifted every argument by one:
                    -- icon received debuffType, and count received the icon
                    -- file ID -- which is why a custom Icon rendered its icon
                    -- ID as the stack count ("135968" for Blessing of Freedom)
                    -- and drew the wrong texture. Reported 2026-08-13 with the
                    -- preview looking correct, and that's the tell: the
                    -- preview has always branched on ind._slots, i.e. on what
                    -- the frame actually is. Both paths use that test now, so
                    -- they can't disagree again.
                    if indicator._slots then
                        for i = 1, (entry.num or 5) do
                            if not t[i] then break end
                            indicator:SetCooldown(i, t[i][2], t[i][3], t[i][4], t[i][5], t[i][6], t[i][7], nil, unit, t[i][9], t[i][8])
                        end
                    else
                        -- Single-slot frame fed from the same sorted list:
                        -- show the highest-priority match only. Tuple order is
                        -- {order, start, duration, debuffType, icon, count,
                        -- refreshing, realSpellId, auraInstanceID} -- see
                        -- UpdateIndicator's tinsert.
                        local a = t[1]
                        indicator:SetCooldown(a[2], a[3], a[4], a[5], a[6], a[7], nil, unit, a[9], a[8])
                    end
                    indicator:Show()
                    if indicator.UpdateSize then indicator:UpdateSize() end
                end
            elseif indicator.SetAuraInstanceID then
                -- AuraContainer-backed single-slot indicator (color, bar) --
                -- presence/show-hide is driven by the engine, never by this
                -- legacy scan. Currently a no-op on both types; kept as a
                -- generic data feed (whole top table, not just
                -- auraInstanceID) for any future type that wants it.
                indicator:SetAuraInstanceID(unit, entry.top[unit])
            elseif entry.color then
                -- Debounced (see ResetCustomIndicators/UpdateIndicator) --
                -- a miss this pass doesn't mean the aura is actually gone,
                -- just that this one scan didn't catch it. Only treat it as
                -- truly absent after MISS_STREAK_THRESHOLD consecutive misses.
                local top = entry.top[unit]
                local found = entry.foundThisPass and entry.foundThisPass[unit]
                if found then
                    entry.missStreak = entry.missStreak or {}
                    entry.missStreak[unit] = 0
                    if top and top.start then
                        indicator:SetCooldown(top.start, top.duration, top.debuffType, top.texture, top.count, top.refreshing, entry.color, top.unit, top.auraInstanceID, top.spellId)
                    end
                else
                    entry.missStreak = entry.missStreak or {}
                    entry.missStreak[unit] = (entry.missStreak[unit] or 0) + 1
                    if entry.missStreak[unit] < MISS_STREAK_THRESHOLD then
                        -- Grace period -- keep showing the last known-good
                        -- data instead of flickering off from scan noise.
                        if top and top.start then
                            indicator:SetCooldown(top.start, top.duration, top.debuffType, top.texture, top.count, top.refreshing, entry.color, top.unit, top.auraInstanceID, top.spellId)
                        end
                    else
                        -- Confirmed gone -- actually clear now.
                        indicator:Hide(true)
                        if top then wipe(top) end
                        if entry.localStart then entry.localStart[unit] = nil end
                    end
                end
            else
                local top = entry.top[unit]
                if top and top.start then
                    -- Other single-slot types (text/bar/rect/glow/border) --
                    -- Trailing unit/auraInstanceID feed CreateBarFrame's
                    -- preferred native SetTimerDuration path; every other
                    -- single-slot type's SetCooldown just ignores the extras.
                    indicator:SetCooldown(top.start, top.duration, top.debuffType, top.texture, top.count, top.refreshing, entry.color, top.unit, top.auraInstanceID, top.spellId)
                elseif entry.localStart then
                    -- Confirmed absent THIS pass (CD.ResetCustomIndicators
                    -- wipes entry.top every scan; nothing re-populated it) --
                    -- clear the locally-tracked start time so a future
                    -- re-application begins a fresh countdown instead of
                    -- reusing a stale timestamp from the last time this
                    -- aura was up.
                    entry.localStart[unit] = nil
                end
            end
        end
    end
end

-- ------------------------------------------------------------------
-- InitPreview: push a representative-icon preview to the preview button.
-- Real UNIT_AURA events never reach the preview button (it isn't part of
-- PartyFrames' unit registry), so this is the only thing that ever
-- populates its custom indicators -- no risk of fighting with real data.
-- ------------------------------------------------------------------
function CD.InitPreview(button)
    if not button or not button.indicators then return end
    local ctx = GetContext(button)
    for _, auraType in ipairs({ "buff", "debuff" }) do
        for indicatorName, entry in pairs(customIndicators[ctx][auraType]) do
            local ind = enabledIndicators[ctx][indicatorName] and button.indicators[indicatorName]
            if ind then
                if not ind.SetCooldown then
                    -- AuraContainer-backed (e.g. CreateCustomColorIndicator) --
                    -- no SetCooldown to fake data into; its AuraContainer is
                    -- bound to the preview button's own REAL unit ("player"),
                    -- so it already shows correctly if the player genuinely
                    -- has the tracked buff active, and simply stays hidden
                    -- (not fake-populated) otherwise. Skip rather than crash.
                elseif ind._slots then
                    -- Representative icon from the indicator's own first
                    -- configured spell, falling back to a generic placeholder
                    -- if it's a name/string entry F.GetSpellIcon can't resolve.
                    local firstAura = entry._auras and entry._auras[1]
                    local icon = (type(firstAura) == "number" and F.GetSpellIcon(firstAura))
                        or [[Interface\Icons\INV_Misc_QuestionMark]]
                    -- Grid types (icons/bars/blocks): fill every configured
                    -- slot (up to entry.num, the indicator's max-icons
                    -- setting) with the same representative icon, so the
                    -- preview communicates "this many icons can show" instead
                    -- of always just one. Mirrors ShowCustomIndicators' live
                    -- loop (line ~836), fake data instead of real matches.
                    -- entry.num can exceed the slot count this frame was
                    -- actually created with (e.g. num raised after the frame
                    -- already existed, since grid frames don't resize their
                    -- slot count live) -- clamp to #ind._slots to stay in range.
                    local count = math.min(entry.num or 1, #ind._slots)
                    -- Mock a >1 stack count (3) so the stack-count text
                    -- actually renders here too -- a nil count meant it
                    -- could never be seen/positioned while designing.
                    for i = 1, count do
                        ind:SetCooldown(i, GetTime(), 13, nil, icon, 3)
                    end
                    ind:Show()
                    if ind.UpdateSize then ind:UpdateSize() end
                else
                    local firstAura = entry._auras and entry._auras[1]
                    local icon = (type(firstAura) == "number" and F.GetSpellIcon(firstAura))
                        or [[Interface\Icons\INV_Misc_QuestionMark]]
                    -- entry.color (only populated for the "color" type) needs
                    -- to reach the preview's SetCooldown too, or a "Color"
                    -- indicator silently shows nothing while designing.
                    -- count=3 (not 1) so the stack-count text -- if enabled --
                    -- is actually visible/positionable here too (count=1 is
                    -- deliberately never shown, same as live data).
                    ind:SetCooldown(GetTime(), 13, nil, icon, 3, false, entry.color)
                    ind:Show()
                end
            end
        end
    end
end

function CD:OnEnable()
    CD:Rebuild()
end

SquizzFrames.modules = SquizzFrames.modules or {}
SquizzFrames.modules["Custom_Dispatch"] = CD
