--[[ SquizzFrames AuraEngineCustom.lua -- the AuraEngine-backed custom
    indicators: "color" (health-bar tint) and "bar", each a single bare
    AuraContainer slot filtered by the indicator's own spell list. Moved out
    of AuraEngineIndicators.lua unchanged in 2.0 (phase 2 code split).
    Public API is still on AEI (SquizzFrames.AuraEngineIndicators):
    CreateCustomColorIndicator, CreateCustomBarIndicator.

    The three health-bar helpers below are published by AuraEngineDispels.lua
    and only called at runtime, after it has loaded. ]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local AEI = SquizzFrames.AuraEngineIndicators
if not AEI then return end

local F = SquizzFrames.F

local function HealthBottomInset(...) return AEI.HealthBottomInset(...) end
local function FrameBorderInset(...) return AEI.FrameBorderInset(...) end
local function AnchorHealthFillOverlay(...) return AEI.AnchorHealthFillOverlay(...) end

-- Used by the custom color/bar indicators' StrataAboveHealth further down.
local STRATA_ORDER = {
    BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4,
    DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8,
}

------------------------------------------------------------------------
-- Custom "color" indicator: health-bar fill tint via a single bare
-- AuraContainer slot, filtered by the user's own configured spell-ID list
-- (t.auras) -- mirrors dispels' exact fill-overlay painting technique
-- rather than the legacy manual C_UnitAuras scan (Custom_Dispatch.lua's
-- CreateColorOverlay), which stopped reliably detecting presence in combat
-- for the same secret-value reasons dispels itself was migrated off of.
-- Scoped to the "fill" anchor modes only (healthbar-current/loss/entire --
-- CreateColorOverlay already treats all three identically) and to spellID
-- matching only (trackByName indicators stay on the legacy scan, since
-- AuraContainer's candidate filters are spellID-based, not name-based) --
-- Indicators.lua's I.CreateIndicator falls back to the legacy
-- CreateColorOverlay for both of those cases and for "unitButton" (border)
-- anchor mode.
------------------------------------------------------------------------
local CUSTOM_COLOR_STYLE_PREFIX = "customColor_"

-- One tier above the health bar's own strata ("LOW" as of 2026-07-31, final
-- -- see UnitButton.xml's comment on healthBar for the full nameplate-strata
-- fix history), or higher if health's strata is already higher (the preview
-- button boosts its own health bar to "DIALOG" to render above the options
-- window).
local function StrataAboveHealth(health)
    local hStrata = health:GetFrameStrata()
    if (STRATA_ORDER[hStrata] or 1) > STRATA_ORDER.MEDIUM then
        return hStrata
    end
    return "MEDIUM"
end

-- Guarded on d.health: AE.MakeInitializer's noRegions branch runs
-- style.applyExtra once before extraInit stashes the health-bar reference
-- on d, then extraInit calls this again right after -- skip that first
-- premature call rather than erroring.
--
-- Overlay texture is a plain white base, colored via SetVertexColor (never
-- SetColorTexture, which would multiply against a threshold-recolor tint
-- instead of cleanly replacing it).
local function ApplyCustomColorSlotStyle(button, d, style)
    if not d.health then return end
    local health = d.health
    if not d.overlay then
        d.overlay = button:CreateTexture(nil, "ARTWORK")
        d.overlay:SetColorTexture(1, 1, 1, 1)
    end
    local tex = d.overlay
    -- Re-measured on every restyle, which is what makes the Frame Border and
    -- power-bar insets follow their settings live.
    AnchorHealthFillOverlay(tex, health)
    local color = style.color or { 0, 1, 0, 1 }
    tex:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
    tex:Show()

    -- Expiring colour: a second wash that the ENGINE reveals once the aura
    -- drops below the threshold. d.expiryText is a FontString whose entire
    -- content is a `|T` rectangle (see AE.BuildExpiryArtEscape) -- the only way
    -- a secret duration can drive a colour. Created and registered in ExtraInit;
    -- everything here is plain region work, legal on any restyle.
    -- Resolved here, NOT captured from an enclosing scope: this function is a
    -- file-level local, so a bare `AE` is a nil GLOBAL. Every other function in
    -- this file resolves it the same way for the same reason. Getting this
    -- wrong is not a quiet nil-index either -- the error surfaces inside the
    -- engine's CreateFrameBatch and takes the whole AddAuraSlot down with it
    -- (442 errors on one roster sync, live 2026-08-14).
    local AE = SquizzFrames.AuraEngine
    if d.expiryText and AE then
        if style.expiringColor then
            local bi = FrameBorderInset(health)
            local bottomInset = HealthBottomInset(health)
            local w = math.max(1, math.floor((health:GetWidth() or 0) - bi * 2))
            local h = math.max(1, math.floor((health:GetHeight() or 0) - bottomInset - bi))

            -- FILL TRACKING. The `|T` is a fixed pixel size and cannot follow
            -- the health fill, so instead the art is drawn at FULL bar width and
            -- a clipping window in front of it is anchored to the fill texture --
            -- the exact anchors the base tint uses (AnchorHealthFillOverlay), so
            -- the two edges can never disagree. All of it is plain anchoring;
            -- nothing reads a health value, secret or otherwise.
            if d.expiryClip then
                AnchorHealthFillOverlay(d.expiryClip, health)
                -- Anchored to the HEALTH BAR, not to the clip window: the art
                -- has to stay nailed to the bar's left edge while the window
                -- shrinks around it. Anchoring it to the window would drag the
                -- art along with the fill and reveal the same slice every time.
                --
                -- y centres the art on the drawable band (bar minus the power
                -- bar at the bottom and the border at the top), which is not the
                -- bar's own centre whenever those two insets differ.
                pcall(d.expiryText.ClearAllPoints, d.expiryText)
                pcall(d.expiryText.SetPoint, d.expiryText, "LEFT", health, "LEFT",
                    bi, (bottomInset - bi) / 2)
            end

            -- Font size == the art's height, matching DandersFrames' working
            -- implementation (`size = h` in its BuildDurationSpec). It has to be
            -- at least the art height or the line box clips it, and making it
            -- exactly equal keeps the two in lockstep as the bar resizes.
            local face = AE.ResolveFont(nil)
            pcall(d.expiryText.SetFont, d.expiryText, face, math.max(1, h), nil)
            AE.SetExpiryArt(style.expiryStyleKey or "",
                style.expiringThreshold or 5,
                AE.BuildExpiryArtEscape(w, h, style.expiringColor, face, h))
            -- pcall'd, NOT dropped. SetDurationText stamps SecretAspect.Alpha
            -- (and Text, and VertexColor) on this FontString, so once the aura
            -- is secret this is a forbidden write. In practice it rarely fires
            -- while secret -- the restyler pauses for the whole of combat -- but
            -- "rarely" isn't never: auras stay secret through an encounter past
            -- the end of a lockdown, which is exactly when the restyler resumes.
            -- Degrading means the alpha lands whenever it legally can and is
            -- skipped when it can't, instead of erroring inside a restyle pass.
            pcall(d.expiryText.SetAlpha, d.expiryText, style.expiringColor[4] or 1)
        else
            -- Blank art rather than Hide(): see the note above on why this
            -- function must not touch the FontString's secret aspects.
            AE.SetExpiryArt(style.expiryStyleKey or "", style.expiringThreshold or 5, "")
        end
    end
end

-- No "expiring soon" recolor -- color is presence + normal color only.
--
-- The old note here said this was impossible because the duration colour curve
-- is text-only. Half right: that curve does only ever drive a FontString
-- (re-confirmed 2026-08-14 against shipped 12.1 source). But a threshold CAN
-- drive a graphic -- the formatter's per-band format string accepts a |T inline
-- texture escape, so the "text" it renders can be the art. See the
-- duration-threshold-driven-visuals memory, which also covers
-- AddPandemicRegion, before deciding this can't be done.
--
-- What actually blocks THIS indicator is geometry, not capability: it paints a
-- health-bar-wide overlay while both mechanisms render inside the aura button's
-- own rect. Workable, but unproven.

local function BuildCustomColorFilters(t)
    local spellSet = F.ConvertSpellTable(t.auras)
    local set = {}
    for id in pairs(spellSet) do
        if type(id) == "number" then set[id] = true end
    end
    return { includeSpellIDs = set }
end

-- Periodic full refresh -- shared by every AddAuraSlot-with-includeSpellIDs
-- indicator (color, bar, ...). container:UpdateAllAuras() forces the slot
-- to re-scan for a fresh match, recovering from AddAuraSlot locking onto a
-- stale matched instance and never picking up a reapplication/refresh.
-- Spread over the 1.5s rather than all in one frame -- see AE.NewRefreshCycle.
-- Created on first use: AuraEngine.lua has loaded by then, and a module that
-- never registers anything never gets a driver frame.
local slotRefreshCycle

-- Register a wrapper/container pair for the periodic refresh above. Call
-- once per RequestContainer callback right after stashing wrapper._container.
local function RegisterSlotRefresh(wrapper, container)
    local AE = SquizzFrames.AuraEngine
    if not (AE and AE.NewRefreshCycle) then return end
    slotRefreshCycle = slotRefreshCycle or AE.NewRefreshCycle(1.5)
    slotRefreshCycle.Register(wrapper, container)
end

function AEI.CreateCustomColorIndicator(button, t)
    if not button then return nil end
    local AE = SquizzFrames.AuraEngine
    if not AE then return nil end
    local health = button.healthBar or button

    local wrapper = CreateFrame("Frame", nil, button)
    wrapper._sfType = "custom"
    wrapper._sfBuiltIn = false
    -- See Indicators.lua's I.RemoveAllCustomIndicators -- this marker keeps
    -- this wrapper (and its AuraContainer) alive across the repeated
    -- HandleIndicators calls that a single /reload's party roster sync
    -- routinely triggers, instead of being torn down and recreated before
    -- the engine ever finishes binding it.
    wrapper._sfAuraEngineBacked = true
    wrapper._t = t

    -- Preview-only fallback: the AuraContainer is driven by the C-side
    -- engine bound to a real unit, so fake aura data can't be injected for
    -- the options panel preview. A plain texture at the same anchor, one
    -- level below the real slot, shows through when nothing real matches.
    local fallbackTex
    local IndicatorsModule = SquizzFrames.Indicators
    if IndicatorsModule and IndicatorsModule.IsPreviewButton(button) then
        -- Parented to wrapper (not button) so Hide()'ing wrapper -- what
        -- ApplySettingToOne's "enabled"/"delete" handling actually calls --
        -- cascade-hides this too. It used to be parented to button, which
        -- left it visible after disabling/deleting the indicator in preview.
        local fallbackHost = CreateFrame("Frame", nil, wrapper)
        fallbackHost:SetFrameStrata(StrataAboveHealth(health))
        fallbackHost:SetFrameLevel(health:GetFrameLevel() + 1)
        fallbackTex = fallbackHost:CreateTexture(nil, "ARTWORK")
        fallbackTex:SetColorTexture(1, 1, 1, 1)
        -- Same insets as the live overlay, so the preview shows the real
        -- geometry rather than a flush rectangle the live frame never draws.
        AnchorHealthFillOverlay(fallbackTex, health)
    end

    local styleKey = CUSTOM_COLOR_STYLE_PREFIX .. t.indicatorName
    local function RebuildStyle()
        local ct = wrapper._t.customColors and wrapper._t.customColors[1]
        local color = ct and {ct[1] or 0, ct[2] or 1, ct[3] or 0, ct[4] or 1} or {0, 1, 0, 1}
        -- Expiring colour, opt-in. Stored in the {"custom_color", r,g,b,a}
        -- shape every other colour setting uses.
        -- type-checked, not just `or`-defaulted: an earlier build could write a
        -- boolean here and it may already be saved in a profile, and
        -- `true or {default}` is `true`, which F.ColorRGB then indexes.
        local ec = nil
        if wrapper._t.expiringEnabled then
            local stored = wrapper._t.expiringColor
            if type(stored) ~= "table" then stored = {"custom_color", 1, 0, 0, 1} end
            local r, g, b, a = F.ColorRGB(stored)
            ec = { r, g, b, a }
        end
        AE.styles[styleKey] = {
            noRegions = true,
            color = color,
            expiringColor = ec,
            expiringThreshold = wrapper._t.expiringThreshold or 5,
            -- The art formatter is cached under its own key so it can't collide
            -- with this style's ordinary duration-text formatter.
            expiryStyleKey = styleKey .. "#expiry",
            applyExtra = ApplyCustomColorSlotStyle,
        }
        if fallbackTex then
            fallbackTex:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
        end
        AE.RestyleSoon(styleKey)
    end
    RebuildStyle()

    -- Re-measure the Frame Border / power-bar insets without rebuilding the
    -- style: the colour hasn't changed, only the geometry ApplyCustomColorSlot
    -- Style measures at apply time. Same contract as the Dispels wrapper's
    -- method of the same name -- AEI.RefreshBorderInsets finds either by duck
    -- typing, so a new overlay indicator joins in just by defining it.
    function wrapper:RefreshBorderInset()
        AE.RestyleSoon(styleKey)
        -- The preview stand-in isn't driven by the engine's restyler, so it
        -- has to be re-anchored by hand.
        if fallbackTex then AnchorHealthFillOverlay(fallbackTex, health) end
    end

    -- Re-derives the candidate filter set live -- called by Indicators.lua's
    -- ApplySettingToOne whenever this indicator's tracked aura list changes
    -- (same mechanism externalCooldowns/defensiveCooldowns/healerHots use).
    function wrapper:RefreshSpellList(newT)
        wrapper._t = newT or wrapper._t
        local container = wrapper._container
        if container then
            -- pcall: unconfirmed whether SetAuraSlotCandidateFilters can be
            -- patched live everywhere; degrades to "takes effect next /reload".
            pcall(container.SetAuraSlotCandidateFilters, container, t.indicatorName, BuildCustomColorFilters(wrapper._t))
        end
        RebuildStyle()
    end

    function wrapper:SetColor()
        RebuildStyle()
    end

    -- Threshold/colour/enabled all arrive together from the one widget.
    -- RebuildStyle re-stamps the style and queues a restyle; the restyle is
    -- what re-runs ApplyCustomColorSlotStyle, which is where the formatter's
    -- bands actually get rewritten (AE.SetExpiryArt).
    function wrapper:SetExpiringColor(payload)
        if type(payload) ~= "table" then return end
        wrapper._t.expiringEnabled = payload.enabled
        wrapper._t.expiringThreshold = payload.threshold
        -- Only accept a real colour table. A previous build routed this through
        -- the positional dispatch and could land a BOOLEAN here, which then
        -- reached F.ColorRGB and errored -- and, worse, persisted into the
        -- profile, so the guard in RebuildStyle has to survive that too.
        if type(payload.color) == "table" then
            wrapper._t.expiringColor = payload.color
        end
        RebuildStyle()
    end

    -- No-op: presence/color both come from the engine-driven slot button.
    -- Kept so ShowCustomIndicators' "does this indicator have
    -- SetAuraInstanceID" check routes here instead of a nonexistent SetCooldown.
    function wrapper:SetAuraInstanceID() end

    -- Shared per-slot extraInit -- also reused below by the periodic
    -- re-declaration ticker, so a forced rebind styles the button exactly
    -- the same way the initial AddAuraSlot call did.
    local function ExtraInit(slotButton, d)
        d.health = health
        wrapper._d = d
        -- "MEDIUM" as of 2026-07-31 (final) -- see the identical note on
        -- Dispels' slotButton:SetFrameStrata call above.
        slotButton:SetFrameStrata("MEDIUM")
        slotButton:SetFrameLevel(1)

        -- Expiring-colour carrier. A FontString rather than a texture because
        -- the only threshold-vs-secret-duration comparison we're allowed is the
        -- formatter's, and a formatter emits TEXT -- so the wash is a `|T`
        -- inline texture inside this string. SetDurationText may only be called
        -- here (the PTR5 initializeFrame rule), which is why the FontString is
        -- created unconditionally even when the option is off: turning it on
        -- later just fills the art in, with no button API call needed.
        if not d.expiryText then
            -- Clipping window for the expiring wash, so it tracks the health
            -- fill instead of being a fixed-width block. Anchored in
            -- ApplyCustomColorSlotStyle; here we only build it.
            --
            -- A child FRAME of the slot button, with the FontString on IT rather
            -- than on the button. Legal: SetDurationText's validation requires
            -- only "a direct child or indirect descendent of owner"
            -- (AuraContainerUtil.ValidateInboundScriptObject), and this is a
            -- descendant. It is emphatically NOT reparenting an aura button,
            -- which is the thing 12.1 bans.
            --
            -- DisableUntrustedLayoutScriptsTemplate when the build has it:
            -- AddAuraGroup/AddAuraSlot stamp ForbiddenAspect.
            -- UntrustedLayoutScriptExecution on the container, and SetPoint
            -- refuses a dependent that lacks it ("Anchoring disallowed as
            -- dependent object would inherit forbidden aspects" -- DandersFrames
            -- hit this in the field on 68914). Aspects are never granted
            -- implicitly, and the template is Blizzard's own sanctioned opt-in.
            -- Cost is that this frame may never run layout scripts, which it
            -- doesn't need. Probed so older builds keep a plain frame.
            local aspectTmpl = C_XMLUtil and C_XMLUtil.GetTemplateInfo
                and C_XMLUtil.GetTemplateInfo("DisableUntrustedLayoutScriptsTemplate")
                and "DisableUntrustedLayoutScriptsTemplate" or nil
            d.expiryClip = CreateFrame("Frame", nil, slotButton, aspectTmpl)
            d.expiryClip:SetClipsChildren(true)
            -- Above the base tint (a texture on the button itself), so the
            -- expiring colour reads as replacing it rather than blending under.
            d.expiryClip:SetFrameLevel((slotButton:GetFrameLevel() or 1) + 1)

            d.expiryText = d.expiryClip:CreateFontString(nil, "OVERLAY")
            -- The string never contains glyphs, only the |T escape -- but
            -- SetFont must still be called or the engine's first SetText hard
            -- errors inside the button batch (and that aborts the WHOLE batch,
            -- not just this button).
            --
            -- Placeholder size only -- ApplyCustomColorSlotStyle re-sets this to
            -- the art's own height on every restyle, and runs immediately below.
            -- SetFont must still happen before the engine's first SetText or it
            -- hard errors inside the button batch.
            d.expiryText:SetFont(AE.ResolveFont(nil), 12, nil)
            -- Alpha is set HERE as well as on restyle, because this is the one
            -- window where it is always legal -- SetDurationText below stamps
            -- SecretAspect.Alpha on this string, after which the restyle-path
            -- write can be refused. Seeding it now means the saved opacity is
            -- always correct at least from creation.
            local ec = wrapper._t and wrapper._t.expiringColor
            if type(ec) == "table" then
                local _, _, _, a = F.ColorRGB(ec)
                d.expiryText:SetAlpha(a or 1)
            end
            -- Placeholder anchor; ApplyCustomColorSlotStyle re-points this to
            -- the health bar's LEFT edge, which is what makes the clip window
            -- reveal a growing slice rather than dragging the art along.
            d.expiryText:SetPoint("LEFT", health, "LEFT", 0, 0)
            AE.SetDurationTextSafe(slotButton, d.expiryText, {
                textFormatter = AE.GetExpiryArtFormatter(
                    styleKey .. "#expiry",
                    (wrapper._t and wrapper._t.expiringThreshold) or 5,
                    ""),
            })
        end

        ApplyCustomColorSlotStyle(slotButton, d, AE.styles[styleKey])
    end

    -- NO "player" fallback: a unit-less button must not build a container bound
        -- to the player's own auras (see OnPartyButtonsWired). AE.RequestContainer
        -- asserts on a nil unit, so callers guard before reaching it.
        local unit = button.unit or button:GetAttribute("unit")
    -- AddAuraSlot (one per spell, includeSpellIDs candidateFilters), NOT
    -- AddAuraGroup -- groups are for multi-icon grids where several auras
    -- can show at once; a slot is exactly one frame, always present,
    -- visibility toggled internally by the engine. Hardcoded strata/level
    -- (not derived from health:GetFrameLevel()) since the secure group
    -- header reassigns frame levels unpredictably; level 1 keeps this
    -- below dispels' own levels (2-6).
    AE.RequestContainer(wrapper, unit, {
        point = { "CENTER", health, "CENTER" },
        slots = {
            {
                key = t.indicatorName,
                filter = { t.auraType == "debuff" and "HARMFUL" or "HELPFUL" },
                candidateFilters = BuildCustomColorFilters(t),
                style = styleKey,
                -- NOTE: do NOT attach any script handler (HookScript/
                -- SetScript) to this button -- the engine's AddSecretAspect
                -- wiring (drives presence Show/Hide) requires exclusive
                -- control and throws if anything else registers one.
                extraInit = ExtraInit,
            },
        },
    }, function(container)
        wrapper._container = container
        RegisterSlotRefresh(wrapper, container)
    end)

    return wrapper
end

------------------------------------------------------------------------
-- Custom "bar" indicator: the visible StatusBar is a child of the actual
-- AddAuraSlot slot button, so Show/Hide is engine-driven like color's
-- overlay. Duration fill uses native SetDurationBar, bound on the same
-- slot button the bar is parented to (matching Ellesmere's BmBarInit).
------------------------------------------------------------------------
local CUSTOM_BAR_STYLE_PREFIX = "customBar_"

-- Guarded on d.wrapper for the same premature-first-call reason as
-- ApplyCustomColorSlotStyle's d.health guard.
local function ApplyCustomBarSlotStyle(slotButton, d, style)
    if not d.wrapper then return end
    if not d.bar then
        local bar = CreateFrame("StatusBar", nil, slotButton)
        bar.tex = bar:CreateTexture(nil, "ARTWORK")
        bar.tex:SetColorTexture(1, 1, 1, 1)
        bar:SetStatusBarTexture(bar.tex)
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(1)
        d.bar = bar

        local opts = {}
        if Enum.StatusBarInterpolation then opts.interpolation = Enum.StatusBarInterpolation.Immediate end
        if Enum.StatusBarTimerDirection then opts.direction = Enum.StatusBarTimerDirection.RemainingTime end
        pcall(slotButton.SetDurationBar, slotButton, bar, opts)
    end
    d.bar:ClearAllPoints()
    d.bar:SetAllPoints(d.wrapper)
    -- Bar Orientation is a FILL direction here, not a grid growth direction:
    -- which axis the bar drains along and from which end. Applied here (the
    -- style's applyExtra) rather than from the wrapper's setter, because this
    -- is the engine's own restyle window -- the only place it is legal to
    -- touch a slot button's regions. See CLAUDE.md section 7.
    local token = style.orientation
    local vertical = (token == "top-to-bottom" or token == "bottom-to-top" or token == "vertical")
    d.bar:SetOrientation(vertical and "VERTICAL" or "HORIZONTAL")
    -- A StatusBar fills left->right and bottom->top by default, so exactly the
    -- other two tokens need the fill reversed.
    if d.bar.SetReverseFill then
        d.bar:SetReverseFill(token == "right-to-left" or token == "top-to-bottom")
    end
    local color = style.color or { 0, 1, 0, 1 }
    d.bar.tex:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
    d.bar:Show()
end

function AEI.CreateCustomBarIndicator(button, t)
    if not button then return nil end
    local AE = SquizzFrames.AuraEngine
    if not AE then return nil end
    local health = button.healthBar or button

    -- Plain positioning frame -- what Indicators.lua treats as "the
    -- indicator" for position/size/enabled; the actual bar anchors to it.
    local wrapper = CreateFrame("Frame", nil, button)
    wrapper._sfType = "custom"
    wrapper._sfBuiltIn = false
    wrapper._sfAuraEngineBacked = true
    wrapper._t = t
    wrapper:SetSize(18, 4)

    -- Preview-only fallback: same reasoning as CreateCustomColorIndicator's
    -- fallbackTex -- the AuraContainer is driven by the C-side engine bound
    -- to a real unit, so it never gets real aura data on the preview button,
    -- and without this the bar simply never renders there. A plain texture
    -- filling wrapper (same rect the real bar anchors to via SetAllPoints)
    -- stands in for the duration fill.
    local fallbackTex
    local IndicatorsModule = SquizzFrames.Indicators
    if IndicatorsModule and IndicatorsModule.IsPreviewButton(button) then
        fallbackTex = wrapper:CreateTexture(nil, "ARTWORK")
        fallbackTex:SetColorTexture(1, 1, 1, 1)
        fallbackTex:SetAllPoints(wrapper)
    end

    local styleKey = CUSTOM_BAR_STYLE_PREFIX .. t.indicatorName
    local function RebuildStyle()
        local ct = wrapper._t.colors and wrapper._t.colors[1]
        local color = ct and { ct[1] or 0, ct[2] or 1, ct[3] or 0, ct[4] or 1 } or { 0, 1, 0, 1 }
        AE.styles[styleKey] = {
            noRegions = true,
            color = color,
            orientation = wrapper._t.orientation,
            applyExtra = ApplyCustomBarSlotStyle,
        }
        if fallbackTex then
            fallbackTex:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
        end
        AE.RestyleSoon(styleKey)
    end
    RebuildStyle()

    -- Dispatched by Indicators.lua's ApplySettingToOne for the "colors"
    -- setting (`indicator.SetColors(value)`, called WITHOUT a colon --
    -- plain function, not a method).
    wrapper.SetColors = function(value)
        wrapper._t.colors = value
        RebuildStyle()
    end

    -- The Bar Orientation dropdown wrote t.orientation and nothing read it --
    -- custom bars had no SetOrientation at all, so Indicators.lua's
    -- `indicator.SetOrientation and ...` dispatch skipped it silently and the
    -- control did nothing. The style carries it now; restyling re-applies it
    -- to every live slot button.
    function wrapper:SetOrientation(token)
        wrapper._t.orientation = token
        RebuildStyle()
    end

    function wrapper:RefreshSpellList(newT)
        wrapper._t = newT or wrapper._t
        local container = wrapper._container
        if container then
            pcall(container.SetAuraSlotCandidateFilters, container, t.indicatorName, BuildCustomColorFilters(wrapper._t))
        end
        RebuildStyle()
    end

    -- No-op: presence/fill both come from the engine-driven slot button.
    -- Kept so ShowCustomIndicators' "does this indicator have
    -- SetAuraInstanceID" check routes here instead of a nonexistent SetCooldown.
    function wrapper:SetAuraInstanceID() end

    -- NO "player" fallback: a unit-less button must not build a container bound
        -- to the player's own auras (see OnPartyButtonsWired). AE.RequestContainer
        -- asserts on a nil unit, so callers guard before reaching it.
        local unit = button.unit or button:GetAttribute("unit")
    local function ExtraInit(slotButton, d)
        d.wrapper = wrapper
        wrapper._d = d
        slotButton:SetFrameStrata(StrataAboveHealth(health))
        slotButton:SetFrameLevel(2)
        ApplyCustomBarSlotStyle(slotButton, d, AE.styles[styleKey])
    end

    AE.RequestContainer(wrapper, unit, {
        point = { "CENTER", wrapper, "CENTER" },
        slots = {
            {
                key = t.indicatorName,
                filter = { t.auraType == "debuff" and "HARMFUL" or "HELPFUL" },
                candidateFilters = BuildCustomColorFilters(t),
                style = styleKey,
                -- NOTE: do NOT attach any script handler to slotButton
                -- itself -- see CreateCustomColorIndicator's identical note.
                extraInit = ExtraInit,
            },
        },
    }, function(container)
        wrapper._container = container
        RegisterSlotRefresh(wrapper, container)
    end)

    return wrapper
end
