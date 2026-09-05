--[[ SquizzFrames UnitFrames Absorbs

    Damage-absorb (shield) and heal-absorb overlays for the standalone unit
    frames, mirroring the party frames' shieldBar and healAbsorb indicators.

    THE WHOLE FILE IS SHAPED BY ONE RULE. UnitGetTotalAbsorbs,
    UnitGetTotalHealAbsorbs, UnitHealth and UnitHealthMax can all return
    SECRET NUMBERS, and any Lua-side arithmetic or comparison on a secret
    throws -- which is precisely when a shield most needs drawing. So:

      * values go STRAIGHT into SetMinMaxValues/SetValue, which are
        secret-safe at the C level. Never scaled, clamped or compared here.
      * "is the shield overcapping" comes from a UnitHealPredictionCalculator
        and is applied with SetAlphaFromBoolean, never `if isClamped then`.

    That is not a guess: it is the arrangement BuiltIn_Update.lua already runs
    for the party frames' equivalent indicators, itself confirmed against
    EllesmereUIRaidFrames on the same client. The pcall-sanitize trick used
    elsewhere in this addon for display numbers is WRONG here -- it drops the
    value to nil exactly when it is genuinely secret, hiding the bar mid-fight.

    A StatusBar is required rather than a plain Texture for the same reason: a
    texture would need SetWidth(absorb / max * barWidth), and that division is
    the arithmetic that throws.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local Absorbs = {}
SquizzFrames.UnitFrameAbsorbs = Absorbs

-- Settings live at t.shieldBar and t.healAbsorb.
Absorbs.ELEMENTS = {"shieldBar", "healAbsorb"}

-----------------------------------------------------------------------
-- Heal prediction calculator
-----------------------------------------------------------------------

-- One per unit frame, shared by both bars, cached on the holder.
-- `false` means "unavailable on this client", which is deliberately distinct
-- from nil ("not tried yet") so a missing API is not re-probed every tick.
--
-- Same construction as BuiltIn_Update.lua's GetHealPredCalc -- see its
-- comment for why the calculator exists at all rather than comparing
-- health + absorbs > maxHealth by hand.
local function GetCalc(holder)
    if holder._sfCalc ~= nil then return holder._sfCalc end
    local calc = false
    if CreateUnitHealPredictionCalculator then
        local ok, c = pcall(CreateUnitHealPredictionCalculator)
        if ok and c then
            calc = c
            if calc.SetMaximumHealthMode and Enum.UnitMaximumHealthMode then
                calc:SetMaximumHealthMode(Enum.UnitMaximumHealthMode.WithAbsorbs)
            end
            if calc.SetDamageAbsorbClampMode and Enum.UnitDamageAbsorbClampMode then
                calc:SetDamageAbsorbClampMode(Enum.UnitDamageAbsorbClampMode.MissingHealth)
            end
        end
    end
    holder._sfCalc = calc
    return calc
end

-- maxHealth (plain) and isClamped (POSSIBLY SECRET -- never compare it).
local function ReadPrediction(holder, unit)
    local calc = GetCalc(holder)
    local maxHealth, isClamped
    if calc and UnitGetDetailedHealPrediction then
        UnitGetDetailedHealPrediction(unit, nil, calc)
        if calc.SetMaximumHealthMode and Enum.UnitMaximumHealthMode then
            calc:SetMaximumHealthMode(Enum.UnitMaximumHealthMode.Default)
        end
        if calc.GetMaximumHealth then maxHealth = calc:GetMaximumHealth() end
        if calc.GetDamageAbsorbs then
            local _, clamped = calc:GetDamageAbsorbs()
            isClamped = clamped
        end
    end
    if not maxHealth then maxHealth = UnitHealthMax(unit) or 0 end
    return maxHealth, isClamped
end

-----------------------------------------------------------------------
-- Creation
-----------------------------------------------------------------------

-- FRAME LEVEL, the one thing here worth checking on screen. Both bars are
-- children of the HEALTH BAR and pinned to its level rather than raised above
-- it. The unit frame's text is drawn as regions on the Button itself, which
-- sits at a higher frame level than the health bar (that is why the text
-- renders over the bar at all -- see UnitFrameButton.xml, where healthBar is
-- frameLevel 1). Anything that climbs above the health bar's level would
-- therefore paint over the name and health text instead of under them.
function Absorbs.Create(parent, unit)
    local host = parent.healthBar or parent
    local holder = {unit = unit, host = host}

    local function MakeBar()
        local bar = CreateFrame("StatusBar", nil, host)
        bar:SetFrameLevel(host:GetFrameLevel() or 1)
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0)
        bar:Hide()
        return bar
    end

    holder.shieldBar = MakeBar()
    holder.healAbsorb = MakeBar()
    return holder
end

-----------------------------------------------------------------------
-- Settings
-----------------------------------------------------------------------

local function ApplyOne(bar, host, cfg, barTexture, reverse)
    if not bar then return end
    if not cfg or not cfg.enabled then
        bar:Hide()
        return
    end
    bar:SetStatusBarTexture(barTexture)
    bar:ClearAllPoints()
    bar:SetAllPoints(host)
    -- Reverse fill grows from the opposite edge. Heal absorb defaults to it
    -- because it represents healing that WON'T land -- it reads correctly
    -- eating inward from the health bar's leading edge.
    bar:SetReverseFill(cfg.reverseFill == true or (reverse and cfg.reverseFill ~= false))
    local c = cfg.color
    bar:SetStatusBarColor(c and c[1] or 1, c and c[2] or 1, c and c[3] or 1,
                          c and c[4] or 0.6)
    bar:Show()
end

function Absorbs.ApplySettings(holder, frame, t, barTexture)
    if not holder or not frame then return end
    local host = frame.healthBar or frame
    holder.host = host
    ApplyOne(holder.shieldBar, host, t and t.shieldBar, barTexture, false)
    ApplyOne(holder.healAbsorb, host, t and t.healAbsorb, barTexture, true)
end

-----------------------------------------------------------------------
-- Values
-----------------------------------------------------------------------

function Absorbs.Update(holder, unit, t)
    if not holder or not unit or not UnitExists(unit) then return end

    local maxHealth, isClamped

    local shield = holder.shieldBar
    local shieldCfg = t and t.shieldBar
    if shield then
        if not shieldCfg or not shieldCfg.enabled then
            shield:Hide()
        else
            maxHealth, isClamped = ReadPrediction(holder, unit)
            -- Raw straight through. No arithmetic, no comparison, no
            -- sanitising -- see this file's header.
            shield:SetMinMaxValues(0, maxHealth)
            shield:SetValue((UnitGetTotalAbsorbs and UnitGetTotalAbsorbs(unit)) or 0)
            if shieldCfg.onlyShowOvershields then
                -- isClamped is itself possibly secret, so this is the ONE
                -- legal way to branch on it.
                if shield.SetAlphaFromBoolean then
                    shield:SetAlphaFromBoolean(isClamped, 1, 0)
                else
                    shield:SetAlpha(0)
                end
            else
                shield:SetAlpha(1)
            end
            shield:Show()
        end
    end

    local heal = holder.healAbsorb
    local healCfg = t and t.healAbsorb
    if heal then
        if not healCfg or not healCfg.enabled then
            heal:Hide()
        else
            -- Scaled against CURRENT health, not max: a heal absorb eats into
            -- the filled portion of the bar, so measuring it against the full
            -- bar would draw it far too short on a wounded unit. Mirrors the
            -- party healAbsorb indicator.
            heal:SetMinMaxValues(0, UnitHealth(unit) or 0)
            heal:SetValue((UnitGetTotalHealAbsorbs and UnitGetTotalHealAbsorbs(unit)) or 0)
            heal:SetAlpha(1)
            heal:Show()
        end
    end
end
