--[[ SquizzFrames AuraEngine.lua - Shared engine for 12.1 AuraContainer-based indicators ]]
--
-- Centralizes every AddAuraGroup / AddAuraSlot / button-setter call behind
-- one API so no other module ever touches the raw container API directly.
-- This is what lets aura indicators work DURING COMBAT: 12.1's secret-aura
-- system blocks Lua from reading aura fields directly once auras go secret
-- (see the "Secret Numbers" section in CLAUDE.md), but a container-managed
-- AuraButton is drawn C-side and never exposes secret data to us at all.
--
-- Key discovery (session 2026-07-10, reverse-engineered from EllesmereUI's
-- EllesmereUI_AuraKit.lua -- a different addon on this same PTR build that
-- has this working): AuraButtons are intentionally BARE. You create your own
-- Icon texture / Cooldown frame / FontStrings as children, fully STYLE them,
-- and only THEN register them with the engine via SetIcon / SetDurationCooldown
-- / SetApplicationCount / SetDurationText. The engine then drives them
-- directly every update. Registering an unstyled region (e.g. a FontString
-- with no font set) hard-errors inside the engine, so styling must always
-- happen before registration.
--
-- 12.1 ONLY: on a pre-12.1 client this whole file is inert. Callers must
-- check SquizzFrames.IS_121 before using AuraEngine.

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end
if not SquizzFrames.IS_121 then return end

local F = SquizzFrames.F
local InCombatLockdown = InCombatLockdown
local CreateFrame = CreateFrame

local AE = {}
SquizzFrames.AuraEngine = AE
SquizzFrames.modules = SquizzFrames.modules or {}
SquizzFrames.modules["AuraEngine"] = AE

-----------------------------------------------------------------------
-- Filter string canonicalization
-----------------------------------------------------------------------
-- The engine batches aura parsing per container by EXACT filter string --
-- two groups only share one scan if their strings are byte-identical. Every
-- filter in SquizzFrames must be built through AE.Filter so token order is
-- always canonical: base polarity first (HELPFUL/HARMFUL), then the
-- remaining tokens sorted alphabetically (negated tokens sort by their bare
-- name, directly after the positive form).
local filterCache = {}

local function TokenSortKey(token)
    if token:sub(1, 1) == "!" then
        return token:sub(2) .. "!"
    end
    return token
end

function AE.Filter(...)
    local key = table.concat({ ... }, "|")
    local cached = filterCache[key]
    if cached then return cached end

    local base, rest = nil, {}
    for i = 1, select("#", ...) do
        local token = select(i, ...)
        if token == "HELPFUL" or token == "HARMFUL" then
            base = token
        else
            rest[#rest + 1] = token
        end
    end
    table.sort(rest, function(a, b) return TokenSortKey(a) < TokenSortKey(b) end)

    local out
    if base and #rest > 0 then
        out = base .. "|" .. table.concat(rest, "|")
    else
        out = base or table.concat(rest, "|")
    end
    filterCache[key] = out
    return out
end

-----------------------------------------------------------------------
-- Duration text formatter
-----------------------------------------------------------------------
-- SetDurationText takes a NumericFormatter object evaluated engine-side
-- against the (possibly secret) remaining duration -- durations are never
-- exposed to us as a raw number, the engine formats them into text itself.
local durationFormatter

-- Breakpoints for the standard "show the remaining time" display.
--
-- `threshold` is the MINIMUM input value a rule applies to, so these read as
-- ascending bands: seconds under a minute, rounded UP so it never reads 0
-- while time remains; then floored minutes/hours/days above that.
--
-- DELIBERATELY UNITLESS -- "2", not "2m" (user request 2026-08-13, "i do not
-- want the m or s showing on the numbers"). The unit letters are simply
-- dropped from the format strings; the div components stay, so a 2-minute
-- debuff still reads "2" rather than "120". The trade-off is that "2" is
-- ambiguous between 2 seconds and 2 minutes -- accepted, since these are small
-- aura icons where anything above a minute is rare and the exact value matters
-- far less than at the low end.
--
-- Note this only governs the NumericRuleFormatter path.
-- BuildSecondsDurationFormatter below is a fallback for builds without it, and
-- cannot produce bare numbers at all -- its Abbreviation.None means full words
-- ("5 Seconds"), not "no suffix", so OneLetter ("5s") stays the least-bad
-- option there.
-- EVERY breakpoint must carry a TOP-LEVEL `step` and `rounding`, even when the
-- real rounding happens inside a `components` entry. `rounding` is declared
-- Nilable = false in NumericRuleFormatBreakpoint, and the marshaller rejects
-- the whole table without it -- which is exactly what went wrong here: the
-- minute/hour/day bands only had rounding inside their components, so
-- SetBreakpoints threw, the pcall swallowed it, BuildRuleDurationFormatter
-- returned nil, and everything silently fell through to the SecondsFormatter
-- (whose OneLetter abbreviation is where the "s" suffix came from). Confirmed
-- against DandersFrames' working formatter, which sets step+rounding on every
-- band without exception.
local function StandardDurationBreakpoints()
    local Up = Enum.NumericRuleFormatRounding.Up
    local Down = Enum.NumericRuleFormatRounding.Down
    return {
        { threshold = 0,     step = 1, rounding = Up,   min = 1, format = "%d" },
        { threshold = 60,    step = 1, rounding = Down, min = 1, format = "%d",
            components = { { div = 60,    rounding = Down } } },
        { threshold = 3600,  step = 1, rounding = Down, min = 1, format = "%d",
            components = { { div = 3600,  rounding = Down } } },
        { threshold = 86400, step = 1, rounding = Down, min = 1, format = "%d",
            components = { { div = 86400, rounding = Down } } },
    }
end

-- Breakpoints that show the remaining time ONLY below `threshold` seconds.
--
-- This is how the "< 5s Remaining" / "< 3s Remaining" options are actually
-- implemented, and it's the whole reason they can work at all. The remaining
-- duration is a SECRET value -- Lua never sees the number, so we can't compare
-- it against a threshold ourselves (which is why these options previously did
-- nothing and the text just stayed on permanently). But the formatter is
-- evaluated ENGINE-SIDE against that secret, so expressing the threshold as a
-- breakpoint rule pushes the comparison to the one place that can legally make
-- it.
--
-- The trick is the empty format string on the upper band: Blizzard's
-- NumericRuleFormatBreakpoint documentation states a format "can include
-- AT-MOST one numeric format specifier", so zero specifiers is legal and
-- renders as an empty string. Above the threshold the text is therefore blank
-- while the FontString itself stays registered and shown -- no per-button API
-- calls, which would be illegal outside initializeFrame anyway.
--
-- No minute/hour/day bands are needed: everything at or above the threshold is
-- blank by definition, and any threshold we offer is far below 60.
local function ThresholdDurationBreakpoints(threshold)
    local Up = Enum.NumericRuleFormatRounding.Up
    local Down = Enum.NumericRuleFormatRounding.Down
    return {
        { threshold = 0,         step = 1, rounding = Up,   min = 1, format = "%d" },
        { threshold = threshold, step = 1, rounding = Down, format = "" },
    }
end

-- Emitted one at a time via AddBreakpoint, ascending, after clearing -- the
-- shape both DandersFrames and EllesmereUI use successfully on this build.
-- SetBreakpoints is documented and ought to be equivalent, but this path is
-- the one with proof behind it, and getting this wrong fails silently.
local function ApplyDurationBreakpoints(formatter, threshold)
    local bp = threshold and ThresholdDurationBreakpoints(threshold) or StandardDurationBreakpoints()
    return pcall(function()
        if formatter.ClearBreakpoints then formatter:ClearBreakpoints() end
        for i = 1, #bp do
            formatter:AddBreakpoint(bp[i])
        end
    end)
end

local function BuildRuleDurationFormatter(threshold)
    if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter
        and Enum.NumericRuleFormatRounding) then
        return nil
    end
    local formatter = C_StringUtil.CreateNumericRuleFormatter()
    if not ApplyDurationBreakpoints(formatter, threshold) then return nil end
    return formatter
end

-- Fallback if the rule formatter is unavailable/rejected on this build.
local function BuildSecondsDurationFormatter()
    if not (C_StringUtil and C_StringUtil.CreateSecondsFormatter) then return nil end
    local formatter = C_StringUtil.CreateSecondsFormatter()
    formatter:SetDefaultAbbreviation(Enum.SecondsFormatterAbbreviation.OneLetter)
    formatter:SetMinInterval(Enum.SecondsFormatterInterval.Seconds)
    if C_CurveUtil and C_CurveUtil.CreateCurve then
        local curve = C_CurveUtil.CreateCurve()
        curve:AddPoint(61, Enum.SecondsFormatterInterval.Minutes)
        curve:AddPoint(3601, Enum.SecondsFormatterInterval.Hours)
        curve:AddPoint(86401, Enum.SecondsFormatterInterval.Days)
        formatter:SetMaxIntervalCurve(curve)
    end
    formatter:SetDesiredUnitCount(1)
    if formatter.SetStripIntervalWhitespace and Enum.SecondsFormatterIntervalWhitespace then
        formatter:SetStripIntervalWhitespace(Enum.SecondsFormatterIntervalWhitespace.Strip)
    end
    return formatter
end

-- PER-STYLE formatter instances.
--
-- These used to be one shared singleton, which was fine while every indicator
-- formatted durations identically. Now that a style can carry its own
-- threshold, sharing would mean setting "< 5s" on Debuffs silently blanked the
-- duration text on Cooldowns and CC too.
--
-- The formatter is a userdata object WE own, not part of the button, so
-- mutating its breakpoints later is legal even though the button-side
-- SetDurationText registration may only happen inside initializeFrame (the
-- 12.1 PTR5 rule -- see CLAUDE.md section 7). The engine holds a reference and
-- re-evaluates it on each update, so a live breakpoint change takes effect
-- without recreating the container. That's what makes the dropdown apply
-- instantly instead of needing a /reload.
local styleFormatters = {}

function AE.GetDurationFormatter(styleKey, threshold)
    if not styleKey then
        -- Legacy/unkeyed callers: one shared always-on formatter, as before.
        if not durationFormatter then
            durationFormatter = BuildRuleDurationFormatter() or BuildSecondsDurationFormatter()
        end
        return durationFormatter
    end
    local f = styleFormatters[styleKey]
    if not f then
        -- BuildSecondsDurationFormatter is the fallback for builds where the
        -- rule formatter is unavailable. It has no breakpoint concept, so a
        -- threshold simply can't be expressed there and the text stays
        -- always-on -- the same degradation as before this feature existed.
        f = BuildRuleDurationFormatter(threshold) or BuildSecondsDurationFormatter()
        styleFormatters[styleKey] = f
    end
    return f
end

-----------------------------------------------------------------------
-- Threshold-driven ART (not text)
-----------------------------------------------------------------------
-- The same engine-side breakpoint trick as ThresholdDurationBreakpoints, but
-- the format string emits a `|T` INLINE TEXTURE ESCAPE instead of digits. The
-- FontString therefore renders a coloured rectangle below the threshold and
-- nothing above it -- which is how a SECRET duration can drive a colour at all.
--
-- Why this is the only route: SetDurationText's own `textColor` curve binds to
-- a DurationTextBinding whose sole output is a FontString, and the duration BAR
-- options carry only `interpolation`/`direction` -- no colour anywhere (checked
-- against shipped 12.1 source 2026-08-14). Reading the colour back out is
-- blocked too: GetFormattedTextColor is ConditionalSecret. So the graphic has
-- to BE the text.
--
-- Escape syntax and the proof it works are lifted from DandersFrames'
-- Features/Auras.lua borderEscapeHex, which is marked verified in game:
--   |Tpath:HEIGHT:WIDTH:offX:offY:texW:texH:l:r:t:b:R:G:B|t
-- Note HEIGHT comes before WIDTH, and the trailing vertex-colour args are
-- 0-255. A solid mask fills any rectangle cleanly, so a non-square size is fine
-- here (it would distort a frame/border texture, which we don't use).
-- Our own 128x128 solid white, not Blizzard's 8x8 WHITE8X8: DandersFrames'
-- working implementation uses a real 64px sheet with matching texW/texH, and an
-- 8px source was one of two unexplained differences when the first attempt
-- rendered ~6x oversized (live 2026-08-14).
local EXPIRY_MASK = [[Interface\AddOns\SquizzFrames\Media\white]]
local EXPIRY_MASK_TEXSIZE = 128

local function To255(x)
    return math.max(0, math.min(255, math.floor((tonumber(x) or 1) * 255 + 0.5)))
end

local function EscapeAt(w, h, color)
    local ts = EXPIRY_MASK_TEXSIZE
    color = color or { 1, 0, 0 }
    return "|T" .. EXPIRY_MASK .. ":" .. h .. ":" .. w .. ":0:0:" .. ts .. ":" .. ts
        .. ":0:" .. ts .. ":0:" .. ts .. ":"
        .. To255(color[1]) .. ":" .. To255(color[2]) .. ":" .. To255(color[3]) .. "|t"
end

-- Scratch FontString used only to MEASURE an escape. Never shown, never
-- engine-managed, and its text is one we set ourselves -- so nothing here
-- touches a secret and GetStringWidth is a plain readable number.
local calibFS
local function MeasureEscapeWidth(escape, fontFile, fontSize)
    if not calibFS then
        local host = CreateFrame("Frame", nil, UIParent)
        host:Hide()
        calibFS = host:CreateFontString(nil, "ARTWORK")
    end
    calibFS:SetFont(fontFile or [[Fonts\FRIZQT__.TTF]], math.max(1, fontSize or 12), nil)
    calibFS:SetText(escape)
    return calibFS:GetStringWidth()
end

--- Build the `|T` escape for a solid `width` x `height` rectangle in `color`.
---
--- SELF-CALIBRATING. The first attempt hardcoded DandersFrames' 0.75 ratio and
--- came out roughly 6x too wide and 10x too tall -- non-uniform, so not a simple
--- scale factor, which means the mapping from escape numbers to rendered pixels
--- isn't something worth deriving by reading docs. Instead: emit the escape at
--- the nominal size, measure what it actually renders to, and re-emit corrected.
---
--- One pass converges because the mapping is linear in the requested numbers.
--- Measuring WIDTH only and applying the ratio to both axes is deliberate: for a
--- lone inline texture GetStringWidth is exactly the texture's width, whereas
--- GetStringHeight returns the LINE box (max of font height and art height), so
--- it would measure the font whenever the font is the taller of the two.
---
--- DEFERRED OPTIMISATION (decided 2026-08-14: not worth it yet). The measure
--- pass runs on every restyle, but the result is fully determined by
--- width/height/colour/font -- so memoising the finished escape on those four
--- inputs would make repeat restyles free. Deliberately left out while the cost
--- is one SetText plus one GetStringWidth on a hidden FontString; do it only if
--- restyle cost ever actually shows up.
function AE.BuildExpiryArtEscape(width, height, color, fontFile, fontSize)
    local targetW = math.max(1, math.floor(tonumber(width) or 1))
    local targetH = math.max(1, math.floor(tonumber(height) or 1))

    local escape = EscapeAt(targetW, targetH, color)
    local measured = MeasureEscapeWidth(escape, fontFile, fontSize or targetH)
    if measured and measured > 0 then
        local scale = targetW / measured
        -- Clamped: a wild measurement (0-size frame, font not yet loaded) must
        -- not turn into an absurd escape. Outside this range, keep nominal.
        if scale > 0.02 and scale < 50 then
            escape = EscapeAt(
                math.max(1, math.floor(targetW * scale + 0.5)),
                math.max(1, math.floor(targetH * scale + 0.5)),
                color)
        end
    end
    return escape
end

local function ApplyArtBreakpoints(formatter, threshold, escape)
    local Down = Enum.NumericRuleFormatRounding.Down
    return pcall(function()
        if formatter.ClearBreakpoints then formatter:ClearBreakpoints() end
        -- Below the threshold: the art. Above: blank -- exactly how the text
        -- thresholds do it, and for the same reason.
        formatter:AddBreakpoint({ threshold = 0, step = 1, rounding = Down, min = 1, format = escape })
        formatter:AddBreakpoint({ threshold = threshold, step = 1, rounding = Down, format = "" })
    end)
end

-- Per-style art formatters, cached separately from the text ones so one style
-- could carry both. Same ownership rule: the formatter is OUR userdata, so its
-- breakpoints stay mutable after the button-side SetDurationText registration
-- has been frozen inside initializeFrame.
local artFormatters = {}

function AE.GetExpiryArtFormatter(styleKey, threshold, escape)
    if not styleKey then return nil end
    local f = artFormatters[styleKey]
    if not f then
        if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter
            and Enum.NumericRuleFormatRounding) then
            return nil
        end
        f = C_StringUtil.CreateNumericRuleFormatter()
        if not ApplyArtBreakpoints(f, threshold or 5, escape or "") then return nil end
        artFormatters[styleKey] = f
    end
    return f
end

-- Re-point an existing art formatter at a new threshold/colour/size. Returns
-- true when there's nothing to do yet (the formatter picks the values up when
-- the first button of this style initializes).
function AE.SetExpiryArt(styleKey, threshold, escape)
    local f = artFormatters[styleKey]
    if not f then return true end
    if not f.AddBreakpoint then return false end
    return ApplyArtBreakpoints(f, threshold or 5, escape or "")
end

-- Change an existing style's duration threshold in place. nil = always show.
-- Returns false if this build's formatter can't express thresholds.
function AE.SetDurationThreshold(styleKey, threshold)
    local f = styleFormatters[styleKey]
    if not f then
        -- Not built yet -- GetDurationFormatter will pick the threshold up
        -- when the first button of this style is initialized.
        return true
    end
    if not f.SetBreakpoints then return false end
    return ApplyDurationBreakpoints(f, threshold)
end

-----------------------------------------------------------------------
-- Styles & button registry
-----------------------------------------------------------------------
-- A style describes how a button is decorated. Buttons are Blizzard-owned
-- AuraButton frames pre-created by the engine in batches of 10; regions we
-- create are children of the button (a hard engine rule). Per-button state
-- lives in an external weak-keyed table, never written onto the button.
AE.styles = {}

-- button -> { icon, cooldown, stack, duration, borderHost, textCarrier, styleKey }
local buttonData = setmetatable({}, { __mode = "k" })
-- styleKey -> weak-keyed set of buttons using that style (for restyling)
local styleButtons = {}

local function GetStyleSet(styleKey)
    local set = styleButtons[styleKey]
    if not set then
        set = setmetatable({}, { __mode = "k" })
        styleButtons[styleKey] = set
    end
    return set
end

-- Font names in settings are LibSharedMedia KEYS ("Friz QT__"), not file
-- paths, and SetFont hard-errors on a key: "Invalid font asset (Friz QT__):
-- file not found". Inside initializeFrame that error aborts the engine's whole
-- CreateFrameBatch and takes the AddAuraGroup with it, so this must never hand
-- back an unresolved name.
--
-- Indicators.lua owns the real resolver (LSM lookup + path detection) and
-- publishes it as F.ResolveFontFile. The local fallback below is deliberately
-- STRICTER than "return whatever we were given": it accepts a value only if it
-- already looks like a WoW content path, and otherwise yields Friz Quadrata.
-- The old permissive fallback was invisible for as long as nothing put a real
-- font name into a style, then crashed the moment AE.ApplyFontSettings started
-- forwarding the user's actual setting.
local FALLBACK_FONT = [[Fonts\FRIZQT__.TTF]]
local function ResolveFont(fontFile)
    if F.ResolveFontFile then return F.ResolveFontFile(fontFile) end
    if type(fontFile) == "string"
        and (fontFile:match("^[Ff]onts\\") or fontFile:match("^[Ii]nterface\\")) then
        return fontFile
    end
    return FALLBACK_FONT
end
-- Exposed so AuraEngineIndicators' Designer-preview mockups resolve fonts
-- exactly the way the live engine-driven regions do, rather than each
-- reimplementing the fallback and drifting apart.
AE.ResolveFont = ResolveFont

-- The raw styling pass. NEVER call this directly -- go through
-- ApplyStyleToRegions below, which is the one that cannot throw.
local function ApplyStyleToRegionsUnsafe(button, style)
    local d = buttonData[button]
    if not d then return end

    -- Bare/noRegions styles (dispels, custom color/bar) manage 100% of
    -- their own regions via applyExtra/extraInit -- the standard icon/
    -- cooldown/stack/duration/borderHost block below exists only for
    -- MakeInitializer's own non-bare regions. Running it here anyway used
    -- to accidentally reach into a bare style's own same-named field
    -- (dispels' ApplyDispelSlotStyle stores its icon texture under d.icon
    -- too) and call SetTexCoord/SetSize on it from a LATER restyle pass --
    -- outside the initializeFrame window, which 12.1 PTR5 forbids once the
    -- button is secret ("Attempt to access forbidden object" taint).
    if style.noRegions then
        if style.applyExtra then style.applyExtra(button, d, style) end
        return
    end

    -- The engine's flow layout only ANCHORS group buttons; physical size is
    -- entirely ours to set (group layout elementWidth/Height only feeds the
    -- flow math). An unsized button renders nothing.
    local w = style.width or 24
    local h = style.height or style.width or 24
    if d.appliedW ~= w or d.appliedH ~= h then
        d.appliedW, d.appliedH = w, h
        button:SetSize(w, h)
    end

    -- style.iconAtlas: a FIXED symbol drawn over the aura's own icon. Used
    -- where the group itself already identifies what it's showing -- dispel
    -- icons declares one group per dispel type, so every icon in a given group
    -- is that type by construction, and a type symbol is often more useful
    -- than five copies of whatever debuff happens to be applied.
    --
    -- style.showIconAtlas is the runtime switch (see MakeInitializer for why
    -- the atlas is an overlay rather than a replacement). The aura's own icon is
    -- faded out rather than hidden underneath it: these atlases are shaped
    -- artwork on transparency, so the spell icon would otherwise show through
    -- around the symbol. Alpha is ours -- the engine only repaints the
    -- texture, it doesn't touch alpha -- whereas Hide() would fight it.
    local showAtlas = style.iconAtlas ~= nil and style.showIconAtlas ~= false
    if d.icon then
        if style.texCoord then
            d.icon:SetTexCoord(style.texCoord[1], style.texCoord[2], style.texCoord[3], style.texCoord[4])
        else
            d.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        d.icon:SetAlpha(showAtlas and 0 or 1)
    end
    if d.iconAtlas then
        if showAtlas then
            d.iconAtlas:SetTexCoord(0, 1, 0, 1)
            d.iconAtlas:SetAtlas(style.iconAtlas)
            d.iconAtlas:Show()
        else
            d.iconAtlas:Hide()
        end
    end

    if d.cooldown then
        local drawSwipe = (style.hideSwipe ~= true)
        d.cooldown:SetReverse(style.cooldownReverse ~= false)
        d.cooldown:SetDrawEdge(drawSwipe and (style.cooldownDrawEdge == true) or false)
        d.cooldown:SetHideCountdownNumbers(true) -- duration text comes from SetDurationText, not the swipe
        -- Turn the ART off, not just the frame. Hiding alone wasn't enough:
        -- the cooldown is registered with the engine via SetDurationCooldown,
        -- and the engine shows/hides it as part of displaying the aura -- so a
        -- SetShown(false) here was simply undone on the next update and the
        -- swipe came back (user report 2026-08-13, "still showing the swipe
        -- even with it unchecked"). SetDrawSwipe/SetDrawBling are draw flags
        -- the engine doesn't touch, so they hold.
        if d.cooldown.SetDrawSwipe then d.cooldown:SetDrawSwipe(drawSwipe) end
        if d.cooldown.SetDrawBling then d.cooldown:SetDrawBling(drawSwipe) end
        d.cooldown:SetShown(drawSwipe)
    end

    -- Indicators with their own text pipeline (fonts, anchors, outline
    -- rules) set noDefaultFonts and style stack/duration themselves inside
    -- style.applyExtra instead.
    if d.stack and not style.noDefaultFonts then
        d.stack:SetFont(ResolveFont(style.stackFont), style.stackFontSize or 12, style.stackFontFlags or "OUTLINE")
        d.stack:ClearAllPoints()
        d.stack:SetPoint(style.stackPoint or "BOTTOMRIGHT", button, style.stackPoint or "BOTTOMRIGHT",
            style.stackX or 1, style.stackY or -1)
        if style.stackColor then
            local c = style.stackColor
            d.stack:SetTextColor(c[1], c[2], c[3], c[4] or 1)
        end
    end
    if d.stack then
        -- Same split as the duration text below: the engine keeps writing the
        -- count either way, visibility is ours. This was missing entirely, so
        -- the "Show Stacks" checkbox had nothing to act on and stacks were
        -- permanently on for every AuraEngine-backed indicator.
        d.stack:SetShown(style.showStack ~= false)
    end

    if d.duration then
        if not style.noDefaultFonts then
            d.duration:SetFont(ResolveFont(style.durationFont), style.durationFontSize or 11, style.durationFontFlags or "OUTLINE")
            d.duration:ClearAllPoints()
            d.duration:SetPoint(style.durationPoint or "TOP", button, style.durationRelPoint or "BOTTOM",
                style.durationX or 0, style.durationY or -2)
            if style.durationColor then
                local c = style.durationColor
                d.duration:SetTextColor(c[1], c[2], c[3], c[4] or 1)
            end
        end
        -- The engine keeps writing the text either way; visibility is ours.
        d.duration:SetShown(style.showDuration ~= false)
    end

    if d.borderHost then
        local b = style.border
        if b and F.CreateBorder then
            F.CreateBorder(d.borderHost, b[1] or 0, b[2] or 0, b[3] or 0, b[4] or 1, b.size or 1)
            d.borderHost:Show()
        else
            d.borderHost:Hide()
        end
    end

    if style.applyExtra then
        style.applyExtra(button, d, style)
    end
end

-- Public entry point: the styling above, made unable to throw.
--
-- Returns false, and ONLY false, when the button could not be styled and the
-- restyle must be retried later. Normal completion returns nil, so callers
-- test `== false` rather than falsiness.
--
-- WHY A pcall AND NOT JUST A PREDICATE
--
-- The first attempt guarded on button:IsForbidden() -- the documented test,
-- asked of the obvious object. It did not hold: a follow-up report still threw
-- from d.icon:SetTexCoord, where d.icon is a Texture WE created on that button
-- and IsForbidden() had just answered false. Forbidden-ness reaches a button's
-- children, and the boundary is not observable from the button alone.
--
-- Worse, the taint driving it need not be ours. That report was tagged
-- `Lua Taint: ElvUI_Libraries` -- our code running inside an execution path
-- another addon had already tainted. We cannot enumerate every object that
-- might be forbidden, and we certainly cannot control who taints the call
-- path, so no predicate we can write is sound.
--
-- Attempting the work and treating failure as "retry later" is the only guard
-- that actually holds. The cheap predicate stays as a pre-filter for the
-- common case; the pcall is what makes it correct.
local function ApplyStyleToRegions(button, style)
    if not button then return false end
    if button.IsForbidden and button:IsForbidden() then return false end
    if not pcall(ApplyStyleToRegionsUnsafe, button, style) then return false end
end

-- Map an indicator's `t.font` table onto a style's stack/duration text fields.
--
-- The options panel's Font widget is EIGHT rows, not just a typeface picker:
--   { name, size, outline, shadow, anchor, xOffset, yOffset, color }
-- and indicators using AuraEngine carry two of them -- t.font[1] is the stack
-- font ("font1:stackFont"), t.font[2] the duration font ("font2:durationFont").
--
-- None of it reached these styles before (fixed 2026-08-13, user report "the
-- duration text is not moving when i adjust the sliders"): the generic
-- dispatch in Indicators.lua only ever calls indicator:SetFont(file, size,
-- flags), which drops the anchor, both offsets and the colour on the floor --
-- and no AuraEngine wrapper implemented SetFont in the first place, so even
-- the typeface and size never arrived. Every field below was running on the
-- style's hardcoded defaults no matter what the sliders said.
--
-- ANCHOR SEMANTICS: a single anchor point is used for BOTH sides of SetPoint
-- (the text's own point and the icon's), matching how the stack text has
-- always behaved -- "BOTTOMRIGHT" means "pin the text's bottom-right to the
-- icon's bottom-right", which is what the dropdown reads as. The duration
-- text's legacy default is the odd one out (TOP anchored to the icon's BOTTOM,
-- i.e. below the icon) and is preserved when no anchor is configured.
local function ApplyFontSlot(style, slot, prefix, defaultPoint)
    if type(slot) ~= "table" then return end
    if slot[1] then style[prefix .. "Font"] = slot[1] end
    -- Guarded the same way as the font path: SetFont errors on a size of 0,
    -- and that error lands inside initializeFrame where it would abort the
    -- engine's whole button batch. The slider's range is 5-50, so this only
    -- catches a corrupt or hand-edited SavedVariables -- which is exactly the
    -- case that would otherwise be a mystery crash on login.
    local size = tonumber(slot[2])
    if size and size > 0 then style[prefix .. "FontSize"] = size end
    -- The widget writes "NONE" for no outline; SetFont wants nil.
    local flags = slot[3]
    if flags == "NONE" then flags = nil end
    style[prefix .. "FontFlags"] = flags
    if slot[5] then
        style[prefix .. "Point"] = slot[5]
        style[prefix .. "RelPoint"] = slot[5]
    elseif defaultPoint then
        style[prefix .. "Point"] = defaultPoint
    end
    style[prefix .. "X"] = tonumber(slot[6]) or 0
    style[prefix .. "Y"] = tonumber(slot[7]) or 0
    if type(slot[8]) == "table" then style[prefix .. "Color"] = slot[8] end
end

function AE.ApplyFontSettings(style, fontTable)
    if not style or type(fontTable) ~= "table" then return end
    -- Flat single-tuple shape (a string in slot 1) belongs to the plain text
    -- indicators, which don't use this engine -- ignore rather than
    -- misinterpreting it as the stack slot.
    if type(fontTable[1]) == "string" then return end
    ApplyFontSlot(style, fontTable[1], "stack", "BOTTOMRIGHT")
    ApplyFontSlot(style, fontTable[2], "duration")
end

-- Colour-curve option in the current SetDurationText schema. The engine
-- recolours against a named duration property; RemainingDuration is enum value
-- ZERO, so it must be resolved with an explicit nil check -- `and/or` would
-- silently discard a legitimate 0.
function AE.DurationTextColor(curve)
    if not curve then return nil end
    local prop = Enum and Enum.DurationTextBindingProperty
        and Enum.DurationTextBindingProperty.RemainingDuration
    if prop == nil then prop = 0 end
    return { curve = curve, property = prop }
end

-- Register a duration-text binding, degrading rather than throwing.
--
-- An uncaught error inside SetDurationText aborts the engine's WHOLE
-- CreateFrameBatch -- killing the AddAuraGroup/AddAuraSlot that triggered it,
-- not just this one call -- so every attempt is pcall'd and we step down:
-- full options, then without the colour binding, then bare. Matches
-- EllesmereUI's AuraKit.SetDurationTextSafe, which is where this pattern (and
-- the schema below) was verified against a working implementation.
--
-- Returns (registered, full).
function AE.SetDurationTextSafe(button, fontString, durationOpts)
    if pcall(button.SetDurationText, button, fontString, durationOpts) then
        return true, true
    end
    if durationOpts.textColor ~= nil then
        durationOpts.textColor = nil
        if pcall(button.SetDurationText, button, fontString, durationOpts) then
            return true, false
        end
    end
    if pcall(button.SetDurationText, button, fontString, {}) then
        return true, false
    end
    return false, false
end

-- Returns the initializeFrame callback for a style. This runs ONCE per
-- created button -- buttons are pre-created in engine batches of 10, so it
-- fires at group/slot-declare time, not per shown aura. All region creation
-- and engine registration happens here.
function AE.MakeInitializer(styleKey, extra)
    return function(button)
        local style = AE.styles[styleKey] or {}
        local d = {}
        buttonData[button] = d
        d.styleKey = styleKey

        if style.noRegions then
            -- Bare mode: no standard visual regions at all. The button is a
            -- pure presence-driven host (the engine still drives its Show/
            -- Hide); the indicator builds whatever it wants in applyExtra/
            -- extra (used by color- or glow-style custom indicators that
            -- react to an aura's presence rather than showing an icon).
            ApplyStyleToRegions(button, style)
            GetStyleSet(styleKey)[button] = true
            if extra then extra(button, d, style) end
            return
        end

        -- Create every region first, style them, and only THEN register
        -- them with the button: each Set* registration immediately runs the
        -- engine's UpdateAuraDisplay, which SetText()s our font strings --
        -- an unstyled FontString has no font assigned and hard-errors
        -- inside the engine.
        d.icon = button:CreateTexture(nil, "ARTWORK")
        d.icon:SetAllPoints(button)

        -- style.iconAtlas: a fixed symbol drawn OVER the aura's own icon,
        -- rather than in place of it. Created here (button:CreateTexture is a
        -- button API call, so the initializer is the only legal window) and
        -- merely shown/hidden by ApplyStyleToRegions afterwards -- which is
        -- what lets an indicator offer a live "use spell icons" toggle.
        --
        -- Replacing the icon outright was the obvious implementation and is a
        -- dead end: the swap hinges on whether button:SetIcon was registered,
        -- and that can only happen HERE. A style whose atlas came and went
        -- would need its buttons rebuilt, i.e. a new container -- and every
        -- container ever built is permanent (WoW never frees frames), so a
        -- checkbox would strand a batch each time it was ticked.
        --
        -- Presence of style.iconAtlas at CREATION time is what decides whether
        -- this region exists at all, so a style that might ever show an atlas
        -- must always carry one; showIconAtlas is the runtime switch.
        if style.iconAtlas then
            d.iconAtlas = button:CreateTexture(nil, "ARTWORK", nil, 1)
            d.iconAtlas:SetAllPoints(button)
        end

        -- CooldownFrameTemplate supplies the swipe/edge textures; a bare
        -- Cooldown frame renders no swipe at all.
        d.cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
        d.cooldown:SetAllPoints(button)

        -- Level order above the swipe: border first (as close to the icon
        -- as possible), then the text carrier, so duration/stack text never
        -- renders behind the border.
        d.borderHost = CreateFrame("Frame", nil, button)
        d.borderHost:SetAllPoints(button)
        d.borderHost:SetFrameLevel(d.cooldown:GetFrameLevel() + 1)

        d.textCarrier = CreateFrame("Frame", nil, button)
        d.textCarrier:SetAllPoints(button)
        d.textCarrier:SetFrameLevel(d.borderHost:GetFrameLevel() + 1)
        d.stack = d.textCarrier:CreateFontString(nil, "OVERLAY")
        d.duration = d.textCarrier:CreateFontString(nil, "OVERLAY")

        ApplyStyleToRegions(button, style)

        -- SetIcon binds the texture to the AURA's own icon and the engine keeps
        -- it updated. ALWAYS registered, even for atlas styles: the atlas is a
        -- separate texture layered on top (see d.iconAtlas above), so the
        -- engine can keep repainting this one underneath and the mode becomes
        -- a live toggle instead of a rebuild.
        button:SetIcon(d.icon)
        button:SetDurationCooldown(d.cooldown)
        button:SetApplicationCount(d.stack, {})

        -- SCHEMA (build 68914): the option keys are `textFormatter` and
        -- `textColor` -- NOT `formatter`/`textColorCurve`, which is what this
        -- passed until 2026-08-13. Wrong keys don't error, they're silently
        -- ignored, so the engine quietly fell back to its own default duration
        -- formatting. That is why the text showed a unit suffix ("30s"),
        -- ignored the unitless format, and ignored the "< 5s"/"< 3s"
        -- thresholds entirely -- our formatter was never consulted at all.
        -- Verified against EllesmereUI's AuraKit.BuildDurationTextOpts, which
        -- documents the same rename.
        local durationOpts = { textFormatter = AE.GetDurationFormatter(styleKey, style.durationThreshold) }
        if style.durationColorCurve then
            durationOpts.textColor = AE.DurationTextColor(style.durationColorCurve)
        end
        AE.SetDurationTextSafe(button, d.duration, durationOpts)

        if style.cancelButtons then
            button:SetCancelAuraButtons(style.cancelButtons)
        end

        GetStyleSet(styleKey)[button] = true
        if extra then extra(button, d, style) end
    end
end

-- Re-applies a style to every registered button (settings changed).
-- Not currently called anywhere (AE.RestyleSoon is used everywhere instead),
-- but guarded the same way for any future direct caller -- see the
-- InCombatLockdown() comment on the restyler's OnUpdate handler below.
function AE.Restyle(styleKey)
    if InCombatLockdown() then return end
    local style = AE.styles[styleKey]
    local set = styleButtons[styleKey]
    if not style or not set then return end
    local deferred = false
    for button in pairs(set) do
        if ApplyStyleToRegions(button, style) == false then deferred = true end
    end
    -- Same retry contract as the budgeted restyler: buttons that were
    -- forbidden this pass still carry the old style, so hand the key to the
    -- queue rather than losing the change. Called through the AE table so it
    -- resolves at call time -- RestyleSoon is defined below this function.
    if deferred and AE.RestyleSoon then AE.RestyleSoon(styleKey) end
end

-- Deferred, time-sliced restyle. Group frame pools can be large (engine
-- count-obfuscation batches), so one style flip could cover many buttons --
-- a synchronous restyle across every indicator could freeze the client on a
-- settings change. Queues the key and re-decorates a bounded number of
-- buttons per frame; re-queuing a key already in flight re-processes it with
-- the latest style (resolved at apply time).
local RESTYLE_BUDGET = 200 -- buttons per frame
local restyleQueue = {}
local restyleWork
local restyler = CreateFrame("Frame")
restyler:Hide()

-- A pass that hit forbidden buttons has not finished its job -- those buttons
-- still carry the old style. Retry the whole key rather than dropping it.
--
-- On a TIMER, deliberately, not by re-queueing for the next frame: auras can
-- stay secret for a whole encounter, and an immediate re-queue would spin this
-- OnUpdate at full rate for the duration. One second is far below any rate a
-- style change needs to land at, and the retry is nearly free anyway now that
-- forbidden buttons cost one IsForbidden call instead of an error.
-- Declared before the OnUpdate closure below, which captures it as an upvalue:
-- a local defined after that closure compiles inside it as a nil global.
local restyleRetryPending = {}
local function DeferRestyle(key)
    if restyleRetryPending[key] then return end
    restyleRetryPending[key] = true
    C_Timer.After(1, function()
        restyleRetryPending[key] = nil
        restyleQueue[key] = true
        restyler:Show()
    end)
end

restyler:SetScript("OnUpdate", function(self)
    -- style.applyExtra (dispels/custom color/bar's Apply*SlotStyle) touches
    -- the slot button directly -- legal inside the sanctioned initializeFrame
    -- window, but this restyle pass runs OUTSIDE it, and 12.1 PTR5 forbids
    -- addon code from touching an AuraButton at all once its aura is secret
    -- (roughly: while in combat/an encounter). Leave the queue/work untouched
    -- and keep ticking every frame -- resumes on its own the moment combat
    -- ends, same deferral pattern as AE.RequestContainer's regenListener.
    if InCombatLockdown() then return end
    local budget = RESTYLE_BUDGET
    while budget > 0 do
        if not restyleWork then
            local key = next(restyleQueue)
            if not key then
                self:Hide()
                return
            end
            restyleQueue[key] = nil
            local set = styleButtons[key]
            if AE.styles[key] and set then
                local buttons = {}
                for b in pairs(set) do buttons[#buttons + 1] = b end
                restyleWork = { key = key, buttons = buttons, index = 1 }
            end
        end
        if restyleWork then
            local w = restyleWork
            local style = AE.styles[w.key]
            local n = #w.buttons
            while budget > 0 and w.index <= n do
                -- `== false` specifically: that is the "couldn't touch it"
                -- signal. Normal completion returns nil, which must not be
                -- read as a skip.
                if style and ApplyStyleToRegions(w.buttons[w.index], style) == false then
                    w.deferred = true
                end
                w.index = w.index + 1
                budget = budget - 1
            end
            if w.index > n then
                if w.deferred then DeferRestyle(w.key) end
                restyleWork = nil
            end
        end
    end
end)

function AE.RestyleSoon(styleKey)
    restyleQueue[styleKey] = true
    restyler:Show()
end

-----------------------------------------------------------------------
-- Container creation
-----------------------------------------------------------------------
-- spec = {
--   point = {anchorPoint, relFrame, relPoint, x, y},
--   layout = { anchorPoint, growthH, growthV, padding = {l,r,t,b}, rowWidth },
--   groups = { { key, filter = {tokens...}, maxFrameCount, sortMethod,
--                sortDirection, candidateFilters, style, extraInit,
--                layout = { elementWidth, elementHeight, elementSpacing,
--                           lineSpacing, groupSpacing, groupLineSpacing,
--                           forceNewLine, layoutIndex } }, ... },
--   slots  = { { key, filter = {tokens...}, candidateFilters, sortMethod,
--                sortDirection, style, extraInit }, ... },
-- }
-- Groups are ADD-ONLY on a container: declare everything up front; a
-- disabled group is maxFrameCount 0, never a removed one.
local containerData = setmetatable({}, { __mode = "k" })

local FLOWDIR
local function FlowDir(token)
    if not FLOWDIR then
        FLOWDIR = {
            RIGHT = AnchorUtil.FlowDirection.Right,
            LEFT = AnchorUtil.FlowDirection.Left,
            UP = AnchorUtil.FlowDirection.Up,
            DOWN = AnchorUtil.FlowDirection.Down,
        }
    end
    return token and FLOWDIR[token]
end
AE.FlowDir = FlowDir

-- NOTE: these are container-level FLOW layout methods (AuraContainerFlowLayoutSharedMixin,
-- confirmed against real PTR source Interface/AddOns/Blizzard_AuraContainer/
-- Blizzard_AuraContainerFlowLayout.lua), NOT "AuraLayout*"-prefixed as earlier
-- reverse-engineering assumed -- that naming never shipped. Renamed 2026-07-28
-- after this exact mismatch threw "attempt to call a nil value" in-game.
-- Which axis the flow runs along BEFORE it wraps. Separate from growth
-- direction: axis picks row-vs-column, growth picks which way along it.
-- Blizzard's flow layout defaults to Horizontal (AnchorUtil.lua), which is why
-- everything worked without ever setting it -- but a vertical stack needs it.
function AE.FlowAxis(token)
    local E = AnchorUtil and AnchorUtil.FlowLayoutAxis
    if not E then return nil end
    return (token == "VERTICAL") and E.Vertical or E.Horizontal
end

function AE.ApplyContainerLayout(container, layout)
    if not layout then return end
    if layout.axis and container.SetFlowLayoutAxis then
        local axis = AE.FlowAxis(layout.axis)
        if axis then container:SetFlowLayoutAxis(axis) end
    end
    if layout.anchorPoint then container:SetFlowLayoutAnchorPoint(layout.anchorPoint) end
    if layout.growthH and layout.growthV then
        container:SetFlowLayoutGrowthDirection(FlowDir(layout.growthH), FlowDir(layout.growthV))
    end
    if layout.padding then
        local p = layout.padding
        container:SetFlowLayoutPadding(p[1] or 0, p[2] or 0, p[3] or 0, p[4] or 0)
    end
    container:SetFlowLayoutMaximumLineSize(layout.rowWidth) -- nil resets to unlimited (math.huge)
end

function AE.CreateContainer(parent, unitToken, spec)
    assert(not InCombatLockdown(), "AuraEngine: containers cannot be created in combat; use AE.RequestContainer")

    local container = CreateFrame("AuraContainer", nil, parent, "CustomAuraContainerTemplate")

    -- Anchor and a provisional size up front: the engine drains its parse
    -- and layout phases from an OnUpdate armed in run-when-visible mode, so
    -- the container needs a renderable rect from the very first dirty mark.
    -- The engine replaces the size on every real layout pass.
    if spec.point then
        container:SetPoint(unpack(spec.point))
    end
    container:SetSize(1, 1)

    AE.ApplyContainerLayout(container, spec.layout)

    local slotFrames = {}

    if spec.groups then
        for i = 1, #spec.groups do
            local g = spec.groups[i]
            container:AddAuraGroup(g.key, AE.Filter(unpack(g.filter)), {
                maxFrameCount = g.maxFrameCount,
                sortMethod = g.sortMethod,
                sortDirection = g.sortDirection,
                candidateFilters = g.candidateFilters,
                initializeFrame = AE.MakeInitializer(g.style, g.extraInit),
                layout = g.layout,
            })
        end
    end

    if spec.slots then
        for i = 1, #spec.slots do
            local s = spec.slots[i]
            slotFrames[s.key] = container:AddAuraSlot(s.key, AE.Filter(unpack(s.filter)), {
                candidateFilters = s.candidateFilters,
                sortMethod = s.sortMethod,
                sortDirection = s.sortDirection,
                initializeFrame = AE.MakeInitializer(s.style, s.extraInit),
            })
        end
    end

    -- Unit LAST: unit assignment re-evaluates event registration, which is
    -- gated on the container already having groups/slots declared. Setting
    -- the unit before declaring content leaves UNIT_AURA unregistered.
    container:SetUnit(unitToken)
    container:UpdateAllAuras()

    containerData[container] = { spec = spec, slotFrames = slotFrames, unit = unitToken }

    return container, slotFrames
end

-- Re-point an ALREADY-created container at a different unit token.
--
-- A button's unit is not stable: SecureGroupHeaderTemplate reassigns unit
-- attributes to its children whenever the roster or the sort changes, so the
-- frame that was party1 a moment ago is party3 now. A container's unit, by
-- contrast, is captured exactly once (CreateContainer's SetUnit above) and
-- never revisited -- so every AuraEngine-backed indicator kept rendering the
-- PREVIOUSLY assigned unit's auras on a button that had since moved to
-- someone else. Most visible with sortByRole enabled, where a role change
-- reshuffles tokens across buttons that all stay put on screen: dispel
-- overlays land on the wrong party member (user report 2026-08-12), and the
-- same applies to healerHots/debuffs/CC/cooldowns.
--
-- No ordering constraint here, unlike creation: the groups/slots are already
-- declared, so SetUnit is just re-pointing them (the "unit LAST" rule above
-- exists only because unit assignment evaluates event registration against
-- whatever content is declared AT THAT MOMENT). UpdateAllAuras then forces an
-- immediate re-parse so the new unit's existing auras appear without waiting
-- for its next UNIT_AURA.
local pendingRebinds = {}
local rebindListener

local function ApplyRebind(container, unitToken)
    container:SetUnit(unitToken)
    container:UpdateAllAuras()
end

function AE.RebindUnit(container, unitToken)
    if not container or not unitToken then return end
    local data = containerData[container]
    -- Cheap no-op guard: HandleIndicators re-runs constantly (rosters stream
    -- in over several frames), and re-binding an unchanged unit would force a
    -- pointless full re-parse every time.
    if data and data.unit == unitToken then return end
    if data then data.unit = unitToken end

    -- Deferred in combat for the same reason creation is: this reaches into
    -- the same C-side container plumbing, and SetUnit's combat legality on an
    -- existing container is unverified -- not worth finding out mid-fight.
    --
    -- Note this is NOT because the header holds still: SecureGroupHeaders.lua
    -- has no InCombatLockdown check at all (checked against Blizzard's source
    -- in Blizzard_RestrictedAddOnEnvironment), and being privileged code it
    -- can and does re-sort and rewrite child unit attributes mid-combat. So a
    -- re-sort during a fight does leave these bindings stale until it ends.
    -- That's deliberate and consistent rather than a gap: WireUpAllButtons is
    -- itself combat-gated, so button.unit -- and therefore name text, health,
    -- and every legacy indicator -- is equally stale for that same window.
    -- Re-pointing only the aura containers mid-fight would produce a frame
    -- showing one player's name over another player's debuffs, which is worse
    -- than being uniformly one sort behind.
    --
    -- pendingRebinds is keyed BY CONTAINER, so repeated unit changes during
    -- one fight collapse to the final token rather than replaying.
    if InCombatLockdown() then
        pendingRebinds[container] = unitToken
        if not rebindListener then
            rebindListener = CreateFrame("Frame")
            rebindListener:RegisterEvent("PLAYER_REGEN_ENABLED")
            rebindListener:SetScript("OnEvent", function()
                local queue = pendingRebinds
                pendingRebinds = {}
                for c, u in pairs(queue) do
                    ApplyRebind(c, u)
                end
            end)
        end
        return
    end

    -- A rebind queued earlier in this same combat is now superseded.
    pendingRebinds[container] = nil
    ApplyRebind(container, unitToken)
end

-- Combat-safe wrapper: fulfills immediately out of combat, otherwise queues
-- until PLAYER_REGEN_ENABLED.
local pending = {}
local regenListener
local drainListeners = {}

function AE.RequestContainer(parent, unitToken, spec, callback)
    -- No unit, no container. A container is bound to a unit for life, and
    -- there is nothing sensible to bind to yet -- building one anyway is how
    -- unit-less secure-header children ended up with live containers on the
    -- PLAYER (see OnPartyButtonsWired in Indicators.lua). Every container is
    -- permanent (WoW never destroys frames) plus a 10-button batch, so the
    -- cost of guessing wrong here is paid for the whole session.
    --
    -- Returning quietly rather than asserting: callers legitimately reach this
    -- during the window before the header has assigned units, and they get
    -- called again once it has.
    if not unitToken then return end
    if not InCombatLockdown() then
        local container, slotFrames = AE.CreateContainer(parent, unitToken, spec)
        if callback then callback(container, slotFrames) end
        return
    end

    pending[#pending + 1] = { parent = parent, unit = unitToken, spec = spec, callback = callback }

    if not regenListener then
        regenListener = CreateFrame("Frame")
        regenListener:RegisterEvent("PLAYER_REGEN_ENABLED")
        regenListener:SetScript("OnEvent", function()
            local queue = pending
            pending = {}
            for i = 1, #queue do
                local q = queue[i]
                local container, slotFrames = AE.CreateContainer(q.parent, q.unit, q.spec)
                if q.callback then q.callback(container, slotFrames) end
            end
            -- q.unit was captured when the request was QUEUED -- i.e. before
            -- this combat -- so anything that reassigned unit tokens meanwhile
            -- leaves these fresh containers bound to the wrong unit. The
            -- re-wire that fixes that (WireUpAllButtons -> HandleIndicators ->
            -- AEI.SyncContainerUnits) also runs off PLAYER_REGEN_ENABLED, from
            -- a DIFFERENT frame, so which of the two goes first is undefined --
            -- and if it goes first it finds _container still nil and skips.
            -- Notifying explicitly here makes the outcome order-independent.
            if #queue > 0 then
                for j = 1, #drainListeners do
                    drainListeners[j]()
                end
            end
        end)
    end
end

-- Register a function to run right after a batch of combat-deferred
-- containers is created. See the drain loop above for why this exists.
function AE.OnContainersDrained(fn)
    drainListeners[#drainListeners + 1] = fn
end

function AE.GetContainerData(container)
    return containerData[container]
end

-----------------------------------------------------------------------
-- Cutscene / loading-screen recovery
-----------------------------------------------------------------------
-- Ordinary hygiene: re-parse every container after a cutscene, movie or
-- loading screen, since unit tokens are unresolvable while those are up and
-- a group only re-parses when something tells it to (the periodic 1.5s
-- UpdateAllAuras ticker in AuraEngineIndicators.lua covers only SLOT-based
-- indicators, never AddAuraGroup ones).
--
-- HISTORY -- read this before attributing any filtering bug to it: this was
-- originally added on the theory that a cutscene was the ROOT CAUSE of
-- "healerHots/externalCooldowns/defensiveCooldowns all show every buff".
-- That theory was WRONG. The real cause is a live 12.1 Blizzard bug --
-- UnitCanAssist("player","player") returns a genuine, non-secret FALSE
-- (confirmed in-game by /dump, with UnitIsFriend correctly returning true).
-- Blizzard's AuraContainerUtil.CanApplyIdentityCandidateFilters gates
-- includeSpellIDs/excludeSpellIDs behind that call for helpful auras, so the
-- spell-ID filters are skipped ALWAYS, not just during cutscenes, and no
-- amount of re-parsing fixes it. Kept because a post-cutscene refresh is
-- defensible on its own merits, NOT because it addresses that bug.
--
-- Safe in combat: UpdateAllAuras is a CONTAINER method, not a button method,
-- so it's outside the initializeFrame restriction -- the slot-refresh ticker
-- already depends on that being true.
function AE.RefreshAllContainers()
    for container in pairs(containerData) do
        if container.UpdateAllAuras then
            pcall(container.UpdateAllAuras, container)
        end
    end
end

local recoveryFrame = CreateFrame("Frame")
-- CINEMATIC_STOP = in-engine cutscenes, STOP_MOVIE = pre-rendered movies,
-- PLAYER_ENTERING_WORLD = loading screens (same unit-token unavailability).
recoveryFrame:RegisterEvent("CINEMATIC_STOP")
recoveryFrame:RegisterEvent("STOP_MOVIE")
recoveryFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
recoveryFrame:SetScript("OnEvent", function()
    -- Twice, deliberately: unit tokens aren't necessarily resolvable the
    -- instant the event fires, and a re-parse that runs while UnitCanAssist
    -- is still false would just re-cache the same unfiltered result. The
    -- second pass is the safety net; both are cheap no-ops when the current
    -- parse is already correct.
    C_Timer.After(0.5, AE.RefreshAllContainers)
    C_Timer.After(3.0, AE.RefreshAllContainers)
end)

-----------------------------------------------------------------------
-- Restriction probe
-----------------------------------------------------------------------
-- There is no official "are auras secret right now" query. Best-effort
-- helper for any surviving spellID-lookup paths that want to know whether
-- silent-absence semantics are in effect. Never treat it as a data source.
--
-- 2026-08-07: the original implementation (`local ok = pcall(...); return
-- not ok`) was a DEAD probe -- it assumed restriction manifests as a thrown
-- error, but 12.1's documented behavior is SILENT ABSENCE: the call
-- succeeds and simply returns nil. So `ok` was always true and this always
-- returned false, i.e. "never restricted", regardless of actual state.
--
-- Detecting absence instead: the player virtually always has at least one
-- helpful aura in real play, but "no buffs at all" is a legitimate state,
-- so a nil result alone can't distinguish "restricted" from "genuinely
-- unbuffed" -- which is precisely why this can only ever be a HINT. Kept
-- deliberately conservative: only report restricted when the call both
-- survives AND yields nothing while the client is on a build where aura
-- secrecy exists at all.
function AE.AurasRestricted()
    if not SquizzFrames.IS_121 then return false end
    local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, "player", 1, "HELPFUL")
    if not ok then return true end
    return data == nil
end

-----------------------------------------------------------------------
-- PHASE 0 VALIDATION HARNESS (temporary)
-----------------------------------------------------------------------
-- /sfauratest creates a real AuraGroup on the player's actual unit button,
-- filtered to the healerSpells list, so the whole pipeline can be proven
-- end-to-end in-game (including in combat) before anything else is wired
-- onto this engine. Remove once Phase 2 migrates the real indicators over.
SLASH_SQUIZZAURATEST1 = "/sfauratest"
SlashCmdList["SQUIZZAURATEST"] = function()
    local PartyFrames = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    local button = PartyFrames and PartyFrames.FindButtonByUnit and PartyFrames.FindButtonByUnit("player")
    if not button then
        print("|cffff0009[SquizzFrames]|r AuraEngine test: player button not found")
        return
    end
    if InCombatLockdown() then
        print("|cffff0009[SquizzFrames]|r AuraEngine test: can't create in combat (this is a one-time setup call, not the combat-safety test itself)")
        return
    end

    AE.styles["auratest"] = {
        width = 28,
        height = 28,
        showDuration = true,
    }

    -- healerSpells is class-keyed (see Defaults/Indicator_Defaults.lua) -- flatten it.
    local healerSpells = SquizzFrames.F.FlattenSpellTable(SquizzFrames.defaults and SquizzFrames.defaults.healerSpells or {})
    local includeSpellIDs = {}
    for _, id in ipairs(healerSpells) do
        if type(id) == "number" then includeSpellIDs[id] = true end
    end

    local container = AE.CreateContainer(button, "player", {
        point = { "CENTER", button, "CENTER", 0, 40 },
        layout = { rowWidth = 200 },
        groups = {
            {
                key = "test",
                filter = { "HELPFUL" },
                maxFrameCount = 8,
                candidateFilters = { includeSpellIDs = includeSpellIDs },
                style = "auratest",
            },
        },
    })
    container:Show()
    print("|cff33cc99[SquizzFrames]|r AuraEngine test container created above your player frame (" .. #healerSpells .. " healer spells filtered). Cast a HoT on yourself to test -- try it both in and out of combat.")
end
