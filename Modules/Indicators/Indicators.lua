--[[ SquizzFrames Indicators.lua - Indicator runtime ]]
--
-- Mirrors (a slice of) Cell's indicator system:
--   * A registry of built-in and custom indicators, each stored on the unit
--     button at button.indicators[name].
--   * A central SquizzFrames:Fire("UpdateIndicators", indicatorName, setting,
--     value, value2) callback that re-applies a changed setting to every
--     button (and the preview button) in real time.
--   * Per-built-in update functions (BuiltIn_Update.lua) driven by a small set
--     of unit events.
--   * A custom-indicator aura scanner + per-type dispatcher
--     (Custom_Dispatch.lua) for all Cell custom indicator types.
--
-- Indicators are NOT secure frames — they never touch protected attributes —
-- so they're free to reposition, recolor, and redraw at any time, including in
-- combat.

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F
local defaults = SquizzFrames.defaults and SquizzFrames.defaults.profile

local I = SquizzFrames:NewModule("Indicators", "AceEvent-3.0")

-- Built-in indicator update module (loaded just after this file).
local BuiltIn -- assigned in OnInitialize once module is available

-- Party and Raid each have their own fully independent indicator array
-- (profile.layout.indicators / profile.layout.indicatorsRaid), mirroring how
-- profile.layout itself already splits main/raid -- so every built-in and
-- custom indicator's enabled/position/size/style/etc. can diverge between
-- the two. Real buttons are always homogeneous at any given moment (the
-- whole party/raid header switches which unit type it shows via a single
-- global IsInRaid(), never a mix), so "which list applies" is a single
-- context decision per call, not something that needs figuring out
-- per-button beyond knowing whether that button IS the preview button.
--
-- I.previewIsRaidTab tracks which tab the Designer (IndicatorsPanel.lua) is
-- currently editing -- independent of the player's REAL group state, so
-- Raid can be configured/previewed without actually being in a raid (same
-- pattern as PartyFrames.lua's previewIsRaidTab for the Layout tab).
I.previewIsRaidTab = false

-- True if `button` is ANY mock preview button (no real unit behind it), as
-- opposed to a live party/raid frame.
--
-- This used to be an identity test against the Designer's single preview
-- button, repeated in ~12 places. It's what makes an aura indicator render
-- static DUMMY icons instead of trying to read real aura data -- and on 12.1
-- it's also what stops AuraEngine creating a real AuraContainer (see the
-- isPreview branches in AuraEngineIndicators.lua). The group preview window
-- adds up to 20 more mock buttons that need exactly that treatment, so the
-- test is now a flag any preview button can carry rather than a comparison
-- against one specific frame.
--
-- Note this deliberately does NOT mean "the Designer's button". Designer-only
-- concerns (the highlight border, indicator dragging, the scale slider) still
-- reference I.previewButton directly.
function I.IsPreviewButton(button)
    return (button and button._sfIsPreviewButton) == true
end

-- True if `button` should read/write the RAID indicator list right now.
-- Preview buttons carry their own context (_sfPreviewIsRaid) so the Designer
-- button and the group preview window can sit on different tabs without
-- fighting over one global; every real button follows the actual current
-- group state (IsInRaid()), since real buttons are always uniformly one or
-- the other.
--
-- Every indicator-list read funnels through here (Custom_Dispatch.lua's
-- GetContext calls it), so this is the single switch point for preview
-- context -- same role GetActiveLayout plays in PartyFrames.lua.
function I.IsRaidContext(button)
    if I.IsPreviewButton(button) then
        return not not button._sfPreviewIsRaid
    end
    return not not IsInRaid()
end

-- Returns profile.layout.indicatorsRaid or profile.layout.indicators.
function I.GetIndicatorsList(isRaid)
    local layout = SquizzFrames.db and SquizzFrames.db.profile and SquizzFrames.db.profile.layout
    if not layout then return {} end
    return (isRaid and layout.indicatorsRaid or layout.indicators) or {}
end

-- Sets which tab the Designer preview follows (see I.previewIsRaidTab's
-- comment). Just a state setter -- callers (IndicatorsPanel.lua's Party/Raid
-- toggle) are responsible for rebuilding the preview/list UI afterward, same
-- as every other Designer state change.
function I.SetPreviewIndicatorMode(isRaid)
    I.previewIsRaidTab = not not isRaid
    -- Keep the Designer button's own per-button context in sync (see
    -- I.IsRaidContext). I.previewIsRaidTab remains the Designer's tab state
    -- for the panel's own use.
    if I.previewButton then
        I.previewButton._sfPreviewIsRaid = I.previewIsRaidTab
    end
end

-- Per-frame "ready" flag: set false while HandleIndicators rebuilds a button,
-- true once built. The custom dispatcher skips buttons that aren't ready yet.
-- Keyed by button → true/nil.
local readyButtons = {}

-- currentEnabled(bitset-free): enabled built-ins by indicatorName.
local enabledBuiltIns = {}

-- Forward declaration: assigned near LayoutDashes/ShowPreviewHighlight
-- (further down, where previewHighlight/highlightedName are declared).
-- ApplySettingToOne calls this after any setting that changes an
-- indicator's own pixel dimensions (size/thickness/height/spacing), so the
-- marching-ants selection border in the preview re-measures immediately
-- instead of waiting up to one OnUpdate tick for its own live GetWidth()/
-- GetHeight() read of the (TOPLEFT/BOTTOMRIGHT-anchored) indicator to
-- reflect the change.
local RefreshHighlightSize

-- -----------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------

-- Indicator table for a given indicatorName, scanning the given list (one of
-- I.GetIndicatorsList's results -- see its comment for why callers must pick
-- the right one explicitly rather than this scanning a single shared list).
local function FindIndicatorByName(list, name)
    for _, t in ipairs(list) do
        if t.indicatorName == name then
            return t
        end
    end
    return nil
end

-- Valid WoW anchor points. Cell's position tables occasionally carry values
-- like "justify" (Cell-specific alignment shorthand) that WoW's SetPoint does
-- not understand; anything not in this set is treated as "CENTER".
local VALID_POINTS = {
    TOPLEFT = true, TOPRIGHT = true, TOP = true,
    BOTTOMLEFT = true, BOTTOMRIGHT = true, BOTTOM = true,
    LEFT = true, CENTER = true, RIGHT = true,
}

-- Resolve a Cell-style position entry's relativeTo to an actual frame.
-- Cell uses 0 or nil as a shorthand for the button itself; "healthBar" maps to
-- the button's health bar (falling back to the button if no bar exists).
local function ResolveRelative(button, relativeTo)
    if relativeTo == "healthBar" then
        return button.healthBar or button
    end
    if relativeTo == 0 or relativeTo == nil or relativeTo == "button" then
        return button
    end
    -- Already a frame (or something anchorable); pass through.
    return relativeTo
end

-- Sanitize a point string to a valid WoW anchor. Defaults any Cell-ism
-- (e.g. "justify") to "CENTER".
local function ResolvePoint(point)
    if type(point) == "string" and VALID_POINTS[point:upper()] then
        return point
    end
    return "CENTER"
end

-- Resolve a stored font file string to a path WoW's SetFont accepts.
-- Stored values are sometimes bare names ("Friz QT__") that aren't valid font
-- paths. If the string already looks like a WoW content path (Fonts\... or
-- Interface\...) use it as-is; otherwise look it up in LibSharedMedia and use
-- the registered path. Falls back to the Blizzard Friz Quadrata font if
-- nothing resolves, so SetFont never gets an invalid asset.
local LSM = LibStub and LibStub:GetLibrary("LibSharedMedia-3.0", true)
local FALLBACK_FONT = [[Fonts\FRIZQT__.TTF]]

local function ResolveFontFile(fontFile)
    if not fontFile then return FALLBACK_FONT end
    if type(fontFile) ~= "string" then return FALLBACK_FONT end
    -- Already a resolvable WoW content path.
    if fontFile:match("^[Ff]onts\\") or fontFile:match("^[Ii]nterface\\") then
        return fontFile
    end
    -- Try LibSharedMedia lookup by registered key.
    if LSM then
        local lsmPath = LSM:HashTable("font")[fontFile]
        if lsmPath then return lsmPath end
    end
    -- Unknown name — fall back to Blizzard's default UI font.
    return FALLBACK_FONT
end

-- Published on the shared helper table so it is genuinely THE font resolver
-- rather than one of several.
--
-- AuraEngine.lua's ResolveFont has always probed F.ResolveFontFile first and
-- fallen back to returning the raw string. That fallback was harmless only
-- because nothing ever put a real font NAME into an AuraEngine style -- the
-- fields were always nil, so it returned the Friz Quadrata default. The moment
-- AE.ApplyFontSettings started feeding it the user's actual setting, the raw
-- string went straight to SetFont, and LibSharedMedia keys like "Friz QT__"
-- are not file paths: "Invalid font asset (Friz QT__): file not found",
-- thrown from inside initializeFrame, which aborts the engine's whole
-- CreateFrameBatch and takes the AddAuraGroup down with it.
F.ResolveFontFile = ResolveFontFile

-- Reposition an indicator frame from its indicator table's position entry. The
-- position table is {point, relativeTo, relativePoint, x, y}. Cell's relativeTo
-- values can be 0/nil/"button"/"healthBar"; its relativePoint values can be the
-- Cell-ism "justify". ResolveRelative and ResolvePoint normalize both.
local function ApplyPosition(button, name, t)
    local indicator = button.indicators and button.indicators[name]
    if not indicator or not t.position then return end
    local point = ResolvePoint(t.position[1])
    local relativeTo = ResolveRelative(button, t.position[2])
    local relativePoint = ResolvePoint(t.position[3])
    indicator:ClearAllPoints()
    indicator:SetPoint(point, relativeTo, relativePoint, t.position[4], t.position[5])
end

-- -----------------------------------------------------------------
-- Core: create / update indicators on a single button
-- -----------------------------------------------------------------

-- Create (or fetch) an indicator frame for the given indicator table, then
-- apply that table's current settings to it. Recreated on HandleIndicators if
-- the indicator's type/shape changed; otherwise the existing frame is reused.
function I.CreateIndicator(button, t)
    if not button or not t then return nil end
    local name = t.indicatorName
    local indicator = button.indicators and button.indicators[name]

    if name == "healerHots" then
        -- AuraContainer-backed (see AuraEngineIndicators.lua) so it stays
        -- accurate through combat secrecy on 12.1. Falls back to the legacy
        -- icon-grid scan (BuiltIn_Update.lua's CheckHealerHots) on pre-12.1
        -- clients, where AuraEngineIndicators.lua's functions don't exist at
        -- all -- that scan has no secrecy problem to begin with since aura
        -- fields aren't secret pre-12.1.
        if not indicator or indicator._sfType ~= "builtin" then
            if indicator then indicator:Hide() end
            local AEI = SquizzFrames.AuraEngineIndicators
            indicator = (AEI and AEI.CreateHealerHotsIndicator and AEI.CreateHealerHotsIndicator(button, t))
                or BuiltIn.CreateBuiltInIndicator(button, t)
        end
    elseif name == "dispels" then
        -- AuraContainer-backed (see AuraEngineIndicators.lua). Falls back to
        -- the legacy health-bar-overlay scan (BuiltIn_Update.lua's
        -- CheckDispels) on pre-12.1 clients -- same reasoning as healerHots
        -- above.
        if not indicator or indicator._sfType ~= "builtin" then
            if indicator then indicator:Hide() end
            local AEI = SquizzFrames.AuraEngineIndicators
            indicator = (AEI and AEI.CreateDispelsIndicator and AEI.CreateDispelsIndicator(button, t))
                or BuiltIn.CreateBuiltInIndicator(button, t)
        end
    elseif name == "dispelIcons" then
        -- The dispel-type SYMBOLS, split out of the Dispels overlay so they can
        -- carry their own position/size/frame level (see
        -- AEI.CreateDispelIconsIndicator). No legacy fallback: this is one aura
        -- group per dispel type, which has no pre-12.1 equivalent -- the old
        -- scan-based path drew a single icon on the overlay indicator instead.
        if not indicator or indicator._sfType ~= "builtin" then
            if indicator then indicator:Hide() end
            local AEI = SquizzFrames.AuraEngineIndicators
            indicator = AEI and AEI.CreateDispelIconsIndicator and AEI.CreateDispelIconsIndicator(button, t)
        end
    elseif name == "externalCooldowns" or name == "defensiveCooldowns" then
        -- AuraContainer-backed (see AuraEngineIndicators.lua) so this stays
        -- accurate through combat secrecy, same fix as Dispels/Healer HoTs --
        -- the legacy manual C_UnitAuras scan (BuiltIn_Update.lua) stopped
        -- returning data mid-combat. Falls back to the legacy grid on
        -- pre-12.1 clients where AuraEngineIndicators.lua's functions don't
        -- exist at all.
        if not indicator or indicator._sfType ~= "builtin" then
            if indicator then indicator:Hide() end
            local AEI = SquizzFrames.AuraEngineIndicators
            local createFn = AEI and (name == "externalCooldowns" and AEI.CreateExternalCooldownsIndicator or AEI.CreateDefensiveCooldownsIndicator)
            indicator = createFn and createFn(button, t) or BuiltIn.CreateBuiltInIndicator(button, t)
        end
    elseif name == "debuffs" or name == "ccIndicator" then
        -- AuraContainer-backed (see AuraEngineIndicators.lua) -- the legacy
        -- manual scan (BuiltIn_Update.lua) permanently stops seeing any
        -- aura first applied to the unit mid-combat, same class of bug
        -- already fixed for every other aura-based indicator here. Falls
        -- back to the legacy grid on pre-12.1 clients.
        if not indicator or indicator._sfType ~= "builtin" then
            if indicator then indicator:Hide() end
            local AEI = SquizzFrames.AuraEngineIndicators
            local createFn = AEI and (name == "debuffs" and AEI.CreateDebuffsIndicator or AEI.CreateCCIndicator)
            indicator = createFn and createFn(button, t) or BuiltIn.CreateBuiltInIndicator(button, t)
        end
    elseif t.type == "built-in" then
        if not indicator or indicator._sfType ~= "builtin" then
            if indicator then indicator:Hide() end
            indicator = BuiltIn.CreateBuiltInIndicator(button, t)
        end
    elseif t.type == "color" and not t.trackByName and (t.anchor or "healthbar-current") ~= "unitButton"
        and SquizzFrames.IS_121 then
        if not indicator or indicator._sfType ~= "custom" then
            if indicator then indicator:Hide() end
            local AEI = SquizzFrames.AuraEngineIndicators
            indicator = AEI and AEI.CreateCustomColorIndicator and AEI.CreateCustomColorIndicator(button, t)
            if not indicator then
                indicator = I.CreateCustomIndicatorFrame(button, t)
            end
        end
    elseif t.type == "bar" and not t.trackByName and SquizzFrames.IS_121 then
        if not indicator or indicator._sfType ~= "custom" then
            if indicator then indicator:Hide() end
            local AEI = SquizzFrames.AuraEngineIndicators
            indicator = AEI and AEI.CreateCustomBarIndicator and AEI.CreateCustomBarIndicator(button, t)
            if not indicator then
                indicator = I.CreateCustomIndicatorFrame(button, t)
            end
        end
    else
        if not indicator or indicator._sfType ~= "custom" then
            if indicator then indicator:Hide() end
            indicator = I.CreateCustomIndicatorFrame(button, t)
        end
    end

    if not indicator then return nil end
    indicator._sfBuiltIn = (t.type == "built-in")
    button.indicators[name] = indicator

    -- Apply enabled state.
    indicator._sfTable = t
    if t.enabled then
        indicator:Show()
    else
        indicator:Hide()
    end
    indicator.configs = t
    return indicator
end

-- Wipe all custom indicators off a button and drop them from the registry.
-- (Built-ins persist across HandleIndicators calls since they have stable
-- frames on the button.)
--
-- AuraContainer-backed custom indicators (ind._sfAuraEngineBacked, e.g.
-- AuraEngineIndicators.lua's CreateCustomColorIndicator) are the ONE
-- exception -- they're explicitly NOT wiped here, and instead reused as-is
-- via HandleIndicators' normal `button.indicators[name] or I.CreateIndicator`
-- check. Confirmed via live debug logging: PartyButtonsWired/PartyButtonWired
-- (and therefore HandleIndicators) fire MULTIPLE TIMES in a single /reload as
-- party roster data streams in from the server -- entirely normal, and
-- harmless for a plain Frame/StatusBar (recreating one is instant). But
-- destroying and recreating an AuraContainer is NOT instant -- the engine
-- needs time to bind the container to the unit and process its first real
-- aura pass, and repeated teardown before that completes meant the overlay
-- NEVER got a stable window to ever show real data, even out of combat.
function I.RemoveAllCustomIndicators(button)
    if not button or not button.indicators then return end
    for name, ind in pairs(button.indicators) do
        if ind and ind._sfBuiltIn == false and type(name) == "string" and name:match("^indicator%d+$")
            and not ind._sfAuraEngineBacked then
            ind:Hide()
            if ind.SetParent then ind:SetParent(nil) end
            button.indicators[name] = nil
        end
    end
end

-- Full rebuild of every indicator on a button from its OWN current context's
-- indicator list (see I.GetIndicatorsList's comment). Mirrors Cell's
-- HandleIndicators. Sets _indicatorsReady false during the
-- rebuild so the aura scanner won't touch half-built frames.
function I.HandleIndicators(button)
    if not button then return end
    button._indicatorsReady = false
    if not button.indicators then
        button.indicators = {}
    end

    -- Defensive/fire cooldown badges rebuild lazily: if the button was waiting
    -- for indicator frames to exist, create them now.
    -- (No-op for now — placeholders live in BuiltIn_Update.)

    -- Wipe custom indicators before recreating (their frame type may change).
    I.RemoveAllCustomIndicators(button)

    -- "Show All" preview override (IndicatorsPanel.lua's checkbox): iterate
    -- shallow copies with enabled forced true, rather than mutating the
    -- real shared list entries (which real buttons in the same context also
    -- read) or
    -- teaching every individual Check* function in BuiltIn_Update.lua about
    -- this override separately -- they all independently re-read t.enabled
    -- from indicator._sfTable/configs, which gets set to whatever `t` this
    -- loop assigns below, so a forced-enabled copy cascades correctly
    -- through BU.CheckAll (called at the end of this function) without
    -- touching any of those functions.
    -- Resolved fresh every call from this button's OWN current context (real
    -- buttons: actual group state; preview: whichever Designer tab is open)
    -- -- see I.IsRaidContext's comment. HandleIndicators fires repeatedly as
    -- rosters stream in and party<->raid transitions happen, so this must
    -- never rely on a stale cached list from an earlier call.
    local sourceList = I.GetIndicatorsList(I.IsRaidContext(button))
    local listToApply = sourceList
    if button._sfShowAllIndicators then
        listToApply = {}
        for i, t in ipairs(sourceList) do
            if t.enabled then
                listToApply[i] = t
            else
                local copy = {}
                for k, v in pairs(t) do copy[k] = v end
                copy.enabled = true
                listToApply[i] = copy
            end
        end
    end

    for _, t in ipairs(listToApply) do
        local indicator = button.indicators[t.indicatorName] or I.CreateIndicator(button, t)
        if not indicator then
            -- skip — indicator couldn't be created (e.g. missing built-in fn)
        else
            indicator.configs = t
            indicator._sfTable = t

            -- enabled
            if t.enabled then indicator:Show() else indicator:Hide() end

            -- position
            if t.position then
                ApplyPosition(button, t.indicatorName, t)
            end

            -- frameLevel (relative to the indicator's parent frameLevel)
            if t.frameLevel and indicator.SetFrameLevel then
                local lvl = (indicator:GetParent() and indicator:GetParent():GetFrameLevel() or 0) + t.frameLevel
                indicator:SetFrameLevel(lvl)
            end

            -- size
            if t.size and indicator.SetSize then
                -- Cell stores size as {w, h}, but debuffs uses {{normalW,normalH},
                -- {bigW,bigH}} -- the second pair drives CheckDebuffs' CC-priority
                -- big-icon sizing via SetBigSize (see CreateCooldownGrid).
                local sz = t.size
                if type(sz[1]) == "table" then
                    if indicator.SetBigSize and sz[2] then
                        indicator:SetBigSize(sz[2][1], sz[2][2])
                    end
                    sz = sz[1]
                end
                indicator:SetSize(sz[1], sz[2])
            end

            -- thickness (border types)
            if t.thickness and indicator.SetThickness then
                indicator:SetThickness(t.thickness)
            end

            -- alpha / global alpha
            if t.alpha then
                indicator:SetAlpha(t.alpha)
            end

            -- height (status bar / shield bar)
            if t.height then
                if indicator.SetHeight then
                    indicator:SetHeight(t.height)
                elseif indicator.SetSize then
                    indicator:SetSize(indicator:GetWidth() or t.size and t.size[1] or 4, t.height)
                end
            end

            -- orientation (icons/bars types)
            if t.orientation and indicator.SetOrientation then
                indicator:SetOrientation(t.orientation)
            end

            -- num (max aura/icon count -- AuraEngine-backed indicators only;
            -- other grid types re-read t.num directly on their next scan)
            if t.num and indicator.SetNum then
                indicator:SetNum(t.num)
            end

            -- castBy (aura source filter -- AuraEngine-backed indicators only)
            if t.castBy and indicator.SetCastBy then
                indicator:SetCastBy(t.castBy)
            end

            -- duration visibility (icon/icons types' countdown numbers)
            if t.durationVisibility and indicator.SetDurationMode then
                indicator:SetDurationMode(t.durationVisibility)
            end

            -- Stack count text on/off. Called unconditionally (not gated on
            -- t.showStack being truthy) since false is itself a meaningful
            -- value here (explicitly hidden) -- SetShowStack's own
            -- `~= false` check already treats unset/nil as "shown" (default).
            if indicator.SetShowStack then
                indicator:SetShowStack(t.showStack)
            end

            -- Duration text X/Y offset -- LEGACY. Healer HoTs was the only
            -- indicator that ever exposed this, and it now uses the full
            -- font1/font2 blocks instead, which carry anchor + X/Y + size +
            -- colour for both the stack and duration text. Skipped whenever
            -- the indicator understands a font table, so a durationOffset
            -- left over in an existing profile can't quietly override the
            -- offsets the font widget is now showing the user.
            if t.durationOffset and indicator.SetDurationOffset
                and not indicator.SetFontTable then
                indicator:SetDurationOffset(t.durationOffset)
            end

            -- Dispels (AuraEngine-backed indicator only)
            if indicator.SetDispelShowAll then indicator:SetDispelShowAll(t.dispelShowAll) end
            -- Dispel Icons' two appearance toggles. Both default OFF (these
            -- are shaped symbol atlases, not icon art), so they're applied
            -- as-is rather than with the usual `~= false` "unset means on".
            if indicator.SetShowSwipe then indicator:SetShowSwipe(t.showSwipe == true) end
            -- Same "unset means off" reading: the dispel-type symbol is the
            -- default look, the real spell icon is the opt-in.
            if indicator.SetUseSpellIcons then indicator:SetUseSpellIcons(t.useSpellIcons == true) end
            if indicator.SetGrowthOrientation then
                indicator:SetGrowthOrientation(t.orientation or "horizontal",
                    t.growthDirection or "left-to-right")
            end
            if indicator.SetShowBorder and t.indicatorName == "dispelIcons" then
                indicator:SetShowBorder(t.showIconBorder == true)
            end
            if t.dispelTypesEnabled and indicator.SetDispelTypes then
                indicator:SetDispelTypes(t.dispelTypesEnabled)
            end
            if t.dispelColors and indicator.SetDispelColors then
                indicator:SetDispelColors(t.dispelColors)
            end
            if t.dispelOverlay and indicator.SetDispelOverlay then
                indicator:SetDispelOverlay(t.dispelOverlay)
            end
            if t.dispelOverlayOpacity and indicator.SetDispelOverlayOpacity then
                indicator:SetDispelOverlayOpacity(t.dispelOverlayOpacity)
            end
            if t.dispelGradientHeight and indicator.SetDispelGradientHeight then
                indicator:SetDispelGradientHeight(t.dispelGradientHeight)
            end
            if t.dispelGradientWeakAlpha and indicator.SetDispelGradientWeakAlpha then
                indicator:SetDispelGradientWeakAlpha(t.dispelGradientWeakAlpha)
            end
            if indicator.SetShowDispelIcons then indicator:SetShowDispelIcons(t.showDispelIcons) end

            -- font
            -- SetFontTable takes the WHOLE font table and is preferred wherever
            -- an indicator implements it (currently the AuraEngine-backed
            -- ones). The SetFont path below can only carry file/size/flags, so
            -- it silently drops the anchor, X/Y offsets and colour that the
            -- Font widget also writes -- which is why the duration text
            -- ignored its sliders entirely. See AE.ApplyFontSettings.
            if t.font and indicator.SetFontTable then
                indicator:SetFontTable(t.font)
            elseif t.font and indicator.SetFont then
                -- t.font = {fontPath, height, flags[, extraBool]}. WoW's SetFont
                -- takes (file, height, flags); valid flags are "OUTLINE",
                -- "THICKOUTLINE", "MONOCHROME" (and combos). "NONE" is NOT a
                -- valid flag string, so a stored "NONE" (or nil) is translated to
                -- nil here. Pass only the first three slots so a trailing truthy
                -- doesn't corrupt the flags argument.
                local flags = t.font[3]
                if not flags or flags == "NONE" then flags = nil end
                indicator:SetFont(ResolveFontFile(t.font[1]), t.font[2] or 10, flags)
            end

            -- color (simple)
            if t.color and indicator.SetColor then
                -- Alpha was dropped here (only r,g,b captured) -- every
                -- rebuild (e.g. on /reload) re-applied color at full opacity
                -- regardless of the saved alpha, since SetColor's `a or 1`
                -- default kicked in whenever the 4th arg was never passed.
                local r, g, b, a = F.ColorRGB(t.color)
                indicator:SetColor(r, g, b, a)
            end

            -- glowColor (Shield Overlay's overshield glow / Heal Absorb's
            -- over-absorb glow). Applied unconditionally rather than gated on
            -- `t.glowColor` being set: the setter's own 1,1,1,1 default is the
            -- untinted look, so an unset profile still gets reset correctly
            -- after the user clears a tint.
            if indicator.SetGlowColor then
                local r, g, b, a = F.ColorRGB(t.glowColor or {"custom_color", 1, 1, 1, 1})
                indicator:SetGlowColor(r, g, b, a)
            end

            -- barTexture (Shield Overlay / Heal Absorb fill texture, an LSM
            -- statusbar name -- see IndicatorWidgets.lua's CreateSetting_BarTexture)
            if t.barTexture and indicator.SetTexture then
                indicator:SetTexture(t.barTexture)
            end

            -- colors (multi-slot: debuffs bar, etc.)
            if t.colors and indicator.SetColors then
                indicator.SetColors(t.colors)
            end

            -- numPerLine / spacing (grid types)
            if t.numPerLine and indicator.SetNumPerLine then
                indicator:SetNumPerLine(t.numPerLine)
            end
            if t.spacing and indicator.SetSpacing then
                indicator:SetSpacing(t.spacing)
            end

            -- orientation variants / castBy / trackByName handled by Custom_Dispatch,
            -- which reads the indicator table directly.

            -- externalCooldowns/defensiveCooldowns' AuraContainer candidate
            -- filters (curated + custom - hidden) -- unconditional so a
            -- REUSED indicator (e.g. after a profile switch, where
            -- I.CreateIndicator's "already exists" branch skips the fresh
            -- BuildCooldownSpec below) still picks up the new profile's
            -- spell-list settings instead of keeping the previous profile's.
            if indicator.RefreshSpellList then
                indicator:RefreshSpellList(t)
            end

            -- built-in specific post-creation wiring.
            if t.type == "built-in" and BuiltIn and BuiltIn.SetupIndicator then
                BuiltIn.SetupIndicator(button, t)
            end
        end -- else (indicator existed)
    end

    -- Hide any BUILT-IN indicator frame that isn't in the list we just
    -- applied (bug fix 2026-08-07). Custom indicators are fully torn down by
    -- I.RemoveAllCustomIndicators above, but built-ins are deliberately
    -- persistent (their frames are reused across rebuilds by name), and the
    -- loop above only ever iterates the INCOMING list -- so a built-in that
    -- was shown under the previous list and is absent/disabled in this one
    -- kept its frame visible forever. That's exactly what a party <-> raid
    -- switch does: layout.indicators and layout.indicatorsRaid are separate
    -- lists, so anything enabled in Party but not in Raid stayed stuck on
    -- screen after switching to Raid (and vice versa).
    do
        local applied = {}
        for _, t in ipairs(listToApply) do
            if t.indicatorName then applied[t.indicatorName] = true end
        end
        for name, indicator in pairs(button.indicators) do
            if not applied[name] and indicator and indicator.Hide
                and indicator._sfBuiltIn ~= false then
                indicator:Hide()
            end
        end

        -- ...and the same for AuraEngine-backed CUSTOM indicators, which fall
        -- through every other cleanup path (bug fix 2026-08-13, user report
        -- "when i clear a custom indicator it remains in the preview").
        --
        -- Three separate mechanisms each decline to handle these, and between
        -- them they leave a hole:
        --   * RemoveAllCustomIndicators deliberately SKIPS them, so their live
        --     AuraContainer survives the repeated rebuilds one roster sync
        --     triggers (tearing it down mid-bind is what that skip exists to
        --     prevent).
        --   * the built-in sweep just above ignores them -- it is explicitly
        --     gated on _sfBuiltIn ~= false.
        --   * ApplySettingToOne's "delete" branch DOES tear them down, but it
        --     only ever runs on real party buttons and the single Designer
        --     preview button. The group preview window's mock buttons are
        --     refreshed purely by rebuilding, so nothing told them.
        -- Net effect: delete a custom colour/bar indicator and it stayed
        -- painted on the group preview until a reload.
        --
        -- Torn down rather than merely hidden: the wrapper owns a real
        -- AuraContainer bound to a unit, and this indicator is gone for good
        -- (it isn't in the list any more), so leaving it alive would keep an
        -- orphaned container parsing auras for nothing.
        for name, indicator in pairs(button.indicators) do
            if not applied[name] and indicator and indicator._sfAuraEngineBacked then
                if indicator.Hide then indicator:Hide() end
                if indicator.SetParent then indicator:SetParent(nil) end
                button.indicators[name] = nil
            end
        end
    end

    -- Re-point AuraEngine containers at this button's current unit.
    --
    -- Every other indicator on the button reads button.unit live, per update,
    -- so it follows the secure header's unit reassignments for free. An
    -- AuraContainer can't -- it's bound C-side, once, when it's created --
    -- which meant AuraEngine-backed indicators silently kept displaying the
    -- unit the button used to hold. Doing it here covers every reassignment
    -- path at once, since HandleIndicators is what PartyButtonsWired /
    -- PartyButtonWired / ReapplyToAll all funnel into right after wiring.
    -- Cheap when nothing changed (AE.RebindUnit early-outs on an unchanged
    -- token), and nil on pre-12.1 where AEI never populates.
    local AEI = SquizzFrames.AuraEngineIndicators
    if AEI and AEI.SyncContainerUnits then
        AEI.SyncContainerUnits(button)
    end

    -- Re-measure the Dispels overlay's Frame Border inset now that the whole
    -- list is built. Needed because frameBorder sits LATER in the indicator
    -- list than dispels, so when dispels was created its FrameBorderInset
    -- lookup found no border frame yet and measured 0. Live buttons would
    -- self-correct anyway (their slot buttons are created asynchronously by
    -- the engine, well after this), but the Designer preview's fallback host
    -- is painted synchronously during creation and would otherwise keep the
    -- zero inset until some later setting change.
    local dispels = button.indicators.dispels
    if dispels and dispels.RefreshBorderInset then
        dispels:RefreshBorderInset()
    end

    button._indicatorsReady = true

    -- After a full rebuild, run an immediate pass of each built-in's check so
    -- existing auras/threat/shields show without waiting for the next event.
    if BuiltIn then
        BuiltIn.CheckAll(button)
    end
end

-- -----------------------------------------------------------------
-- Apply a single Indicator-Settings change to one button. Called by the
-- central UpdateIndicators handler for every button.
-- -----------------------------------------------------------------
local function ApplySettingToOne(button, name, setting, value, value2)
    if not button or not button.indicators then return end
    local indicator = button.indicators[name]
    -- This button's OWN current context (see I.IsRaidContext's comment) --
    -- NOT whatever context the change originated from. For a real button
    -- outside the affected context, CollectAndApply below never calls this
    -- at all; for the preview button, its context always matches whichever
    -- Designer tab fired the change, by construction.
    local t = FindIndicatorByName(I.GetIndicatorsList(I.IsRaidContext(button)), name)

    -- Cross-indicator dependency: every health-bar overlay insets its edges by
    -- the Frame Border's live thickness (FrameBorderInset in
    -- AuraEngineIndicators.lua) so it stops at the border instead of painting
    -- over it -- the Dispels overlay, custom "color" indicators, Shield Overlay
    -- and Heal Absorb. Nothing else re-measures that, so toggling or resizing
    -- the border has to re-fire them here; otherwise each keeps its old inset
    -- until some unrelated restyle happens to run.
    --
    -- Placed BEFORE the dispatch below rather than after it because several
    -- branches (notably "enabled") return early and would skip a trailing
    -- hook. Ordering is still correct: RefreshBorderInsets only QUEUES a
    -- restyle (AE.RestyleSoon), which drains on a later frame -- long after
    -- this call has applied the new thickness/visibility synchronously.
    if name == "frameBorder" and (setting == "thickness" or setting == "enabled") then
        local AEI = SquizzFrames.AuraEngineIndicators
        if AEI and AEI.RefreshBorderInsets then
            AEI.RefreshBorderInsets()
        end
        -- Shield Overlay and Heal Absorb inset off the same border (they pin
        -- across the health bar the same way Dispels does), but they're plain
        -- frames rather than AuraContainer slots, so they re-anchor directly
        -- and per-button rather than going through the restyle queue.
        if BuiltIn and BuiltIn.RefreshOverlayInsets then
            BuiltIn.RefreshOverlayInsets(button)
        end
    end

    if setting == "delete" then
        -- UpdateIndicators already removed this indicator from the list
        -- (so `t` above is nil) before calling here. Nothing else ever tears
        -- down this button's frame: a full HandleIndicators rebuild wouldn't
        -- touch it either, since RemoveAllCustomIndicators deliberately
        -- skips AuraEngine-backed customs (bar/color) to avoid destroying
        -- containers on routine re-wires. Explicitly hide + detach here,
        -- same cleanup RemoveAllCustomIndicators does for plain customs.
        if indicator then
            indicator:Hide()
            if indicator.SetParent then indicator:SetParent(nil) end
        end
        button.indicators[name] = nil
        return
    end

    if setting == "enabled" then
        if t then t.enabled = value end
        if indicator then
            if value then indicator:Show() else indicator:Hide() end
            -- Show() above is unconditional, but plenty of built-ins are only
            -- CORRECTLY visible some of the time (aggroBlink/aggroBorder
            -- during aggro, statusIcon when AFK/dead, shieldBar when a
            -- shield is up, cooldown/debuff icons only while active, etc).
            -- Re-running the built-in Check pass immediately corrects that,
            -- instead of leaving it shown-for-everyone until some unrelated
            -- event (entering combat, a status change) happens to fire next.
            if value and t and t.type == "built-in" and BuiltIn and BuiltIn.CheckAll then
                BuiltIn.CheckAll(button)
            end
        elseif value then
            -- indicator frame doesn't exist yet — create it
            if t then
                button.indicators[name] = I.CreateIndicator(button, t)
            end
        end
        return
    end

    if not indicator then
        if t then indicator = I.CreateIndicator(button, t) end
    end
    if not indicator then return end

    -- update the stored table so future rebuilds / previews pick it up
    if t and value ~= nil then
        if setting:match("^checkbutton") then
            t[value] = value2
        else
            t[setting] = value
        end
    end

    if setting == "position" then
        ApplyPosition(button, name, t or indicator.configs)
        -- Re-run text updater for text indicators since justification depends on anchor point
        if (name == "nameText" or name == "healthText" or name == "powerText") and indicator and indicator._sfNameUpdater then
            indicator._sfNameUpdater()
        end
        -- Dragging statusText in the preview only moves the text (the block
        -- above); its background needs an explicit re-sync so the gradient
        -- direction/width track the new position immediately instead of
        -- waiting for the next full rebuild.
        if name == "statusText" and BuiltIn and BuiltIn.SyncStatusTextBackground then
            BuiltIn.SyncStatusTextBackground(button)
        end
    elseif setting == "statusPosition" then
        -- "Position" dropdown -- a one-time jump to a corner of the health
        -- bar, not a second position system; see BU.ApplyStatusPosition's
        -- comment for why it only runs here (on explicit change) rather
        -- than on every rebuild.
        if BuiltIn and BuiltIn.ApplyStatusPosition then
            BuiltIn.ApplyStatusPosition(button, t or indicator.configs)
        end
    elseif setting == "size" then
        if indicator.SetSize then
            -- Flat {w, h}, or debuffs' nested {{normalW,normalH},{bigW,bigH}}
            -- from the size-normal-big widget -- see HandleIndicators' matching
            -- unwrap for the initial-build path.
            local sz = value
            if type(sz[1]) == "table" then
                if indicator.SetBigSize and sz[2] then
                    indicator:SetBigSize(sz[2][1], sz[2][2])
                end
                sz = sz[1]
            end
            indicator:SetSize(sz[1], sz[2])
        end
        if RefreshHighlightSize then RefreshHighlightSize(name) end
    elseif setting == "frameLevel" then
        if indicator.SetFrameLevel then
            local lvl = (indicator:GetParent() and indicator:GetParent():GetFrameLevel() or 0) + value
            indicator:SetFrameLevel(lvl)
        end
    elseif setting == "barTexture" and indicator.SetTexture then
        indicator:SetTexture(value)
    elseif setting == "thickness" and indicator.SetThickness then
        indicator:SetThickness(value)
        if RefreshHighlightSize then RefreshHighlightSize(name) end
    elseif setting == "alpha" then
        indicator:SetAlpha(value)
    elseif setting == "height" then
        if indicator.SetHeight then indicator:SetHeight(value)
        elseif indicator.SetSize then indicator:SetSize(indicator:GetWidth() or 4, value) end
        if RefreshHighlightSize then RefreshHighlightSize(name) end
    elseif setting == "orientation" and indicator.SetOrientation then
        indicator:SetOrientation(value)
    elseif setting == "num" then
        if indicator.SetNum then
            indicator:SetNum(value)
        elseif BuiltIn and BuiltIn.CheckAll then
            -- Legacy CreateCooldownGrid indicators (missingBuffs) have no
            -- SetNum -- t.num above is already updated, but nothing ever
            -- re-ran the check pass that reads it, so the grid silently
            -- kept showing whatever it last rendered (e.g. all 10 physical
            -- slots) until some unrelated event happened to fire next.
            -- Same silent-no-op class as onlyShowOvershields/debuffBlacklist
            -- below.
            BuiltIn.CheckAll(indicator:GetParent())
        end
    elseif setting == "showIconBorder" and indicator.SetShowBorder then
        indicator:SetShowBorder(value ~= false)
    elseif setting == "growthOrientation" and indicator.SetGrowthOrientation then
        -- value = orientation, value2 = growth direction. Paired deliberately;
        -- see CreateSetting_GrowthOrientation.
        indicator:SetGrowthOrientation(value, value2)
    elseif setting == "showSwipe" and indicator.SetShowSwipe then
        -- Dispel Icons only. Unlike showIconBorder above this defaults OFF,
        -- so it's passed through as-is rather than `~= false`.
        indicator:SetShowSwipe(value == true)
    elseif setting == "useSpellIcons" and indicator.SetUseSpellIcons then
        -- Dispel Icons only, and defaults OFF like showSwipe above.
        indicator:SetUseSpellIcons(value == true)
    elseif setting == "castBy" then
        if indicator.SetCastBy then
            indicator:SetCastBy(value)
        elseif BuiltIn and BuiltIn.CheckAll then
            -- Legacy CreateCooldownGrid fallback (healerHots on pre-12.1) has
            -- no SetCastBy -- t.castBy above is already updated, but nothing
            -- re-ran the check pass that reads it. Same silent-no-op class as
            -- "num"'s identical fallback just above.
            BuiltIn.CheckAll(indicator:GetParent())
        end
    elseif setting == "durationVisibility" and indicator.SetDurationMode then
        indicator:SetDurationMode(value)
    elseif setting == "showStack" and indicator.SetShowStack then
        indicator:SetShowStack(value)
    elseif setting == "durationOffset" and indicator.SetDurationOffset then
        indicator:SetDurationOffset(value)
    elseif setting == "dispelShowAll" and indicator.SetDispelShowAll then
        indicator:SetDispelShowAll(value)
    elseif setting == "dispelTypesEnabled" and indicator.SetDispelTypes then
        indicator:SetDispelTypes(value)
    elseif setting == "dispelColors" and indicator.SetDispelColors then
        indicator:SetDispelColors(value)
    elseif setting == "dispelOverlay" and indicator.SetDispelOverlay then
        indicator:SetDispelOverlay(value)
    elseif setting == "dispelOverlayOpacity" and indicator.SetDispelOverlayOpacity then
        indicator:SetDispelOverlayOpacity(value)
    elseif setting == "dispelGradientHeight" and indicator.SetDispelGradientHeight then
        indicator:SetDispelGradientHeight(value)
    elseif setting == "dispelGradientWeakAlpha" and indicator.SetDispelGradientWeakAlpha then
        indicator:SetDispelGradientWeakAlpha(value)
    elseif setting == "showDispelIcons" and indicator.SetShowDispelIcons then
        indicator:SetShowDispelIcons(value)
    elseif setting == "showCountdownNumbers" and indicator.SetShowCountdownNumbers then
        indicator:SetShowCountdownNumbers(value)
    elseif setting == "showCooldownSwipe" and indicator.SetShowCooldownSwipe then
        indicator:SetShowCooldownSwipe(value)
    elseif setting == "durationPosition" and indicator.SetDurationPosition then
        indicator:SetDurationPosition(value)
    elseif setting == "textScale" and indicator.SetTextScale then
        indicator:SetTextScale(value)
    elseif setting == "font" and indicator.SetFontTable then
        -- Lossless path -- see HandleIndicators' matching branch for why this
        -- has to come first for AuraEngine-backed indicators.
        indicator:SetFontTable(value)
    elseif setting == "font" and indicator.SetFont then
        -- value is the same {fontPath, height, flags[, extraBool]} table shape
        -- as in HandleIndicators; apply the same NONE→nil translation and
        -- font-file resolution.
        local flags = value[3]
        if not flags or flags == "NONE" then flags = nil end
        indicator:SetFont(ResolveFontFile(value[1]), value[2] or 10, flags)
    elseif setting == "color" then
        -- For nameText/healthText/powerText, the indicator color format is
        -- class_color/custom_color/power_color which F.ColorRGB doesn't handle.
        -- Instead of trying to apply it directly, re-run the built-in Check
        -- function which knows how to read the color table and apply it.
        if name == "nameText" and indicator and indicator._sfNameUpdater then
            indicator._sfNameUpdater()
        elseif (name == "healthText" or name == "powerText") and indicator then
            -- CheckHealthText/CheckPowerText read their settings from the
            -- indicator's OWN table (indicator._sfTable/.configs), which is
            -- not always the same object the options panel just wrote to:
            -- HandleIndicators hands the preview button a forced-enabled
            -- SHALLOW COPY when "Show All Indicators" is on, and the
            -- preview's list context can differ from the tab that fired the
            -- change. Mirror the new value across first so the re-check
            -- can't read a stale color (bug fix 2026-08-07: class color
            -- updated instantly on live frames but not in the Designer
            -- preview -- live buttons masked it because an incoming
            -- UNIT_HEALTH re-runs the same check against fresh data a
            -- moment later, while the preview is driven only by this call).
            local ownTable = indicator._sfTable or indicator.configs
            if ownTable and ownTable ~= t then
                ownTable.color = value
            end
            if BuiltIn and BuiltIn.CheckAll then
                BuiltIn.CheckAll(indicator:GetParent())
            end
        else
            local r, g, b, a = F.ColorRGB(value)
            if indicator.SetColor then indicator:SetColor(r, g, b, a)
            elseif indicator.SetVertexColor then indicator:SetVertexColor(r, g, b, a or 1) end
        end
    elseif setting == "expiringColor" and indicator.SetExpiringColor then
        -- Single payload table {enabled, threshold, color} -- see the panel
        -- binding for why all three travel together rather than as positional
        -- args plus a lookup off `t`.
        if type(value) == "table" then
            indicator:SetExpiringColor(value)
        end
    elseif setting == "glowColor" and indicator.SetGlowColor then
        local r, g, b, a = F.ColorRGB(value or {"custom_color", 1, 1, 1, 1})
        indicator:SetGlowColor(r, g, b, a)
        -- Keep the indicator's OWN table in step, same staleness fix as the
        -- "color" branch above: the preview button carries its own copy, and
        -- nothing else re-reads this until the next rebuild.
        local ownTable = indicator._sfTable or indicator.configs
        if ownTable and ownTable ~= t then
            ownTable.glowColor = value
        end
    elseif setting == "colors" and indicator.SetColors then
        indicator.SetColors(value)
    elseif setting == "numPerLine" and indicator.SetNumPerLine then
        indicator:SetNumPerLine(value)
    elseif setting == "spacing" and indicator.SetSpacing then
        indicator:SetSpacing(value)
        if RefreshHighlightSize then RefreshHighlightSize(name) end
    elseif setting == "auras" or setting == "customColors" or setting == "blockColors" or setting == "overlayColors" or setting == "anchor" then
        -- Custom-indicator aura list or per-type color list changed.
        -- Custom_Dispatch's per-indicator "entry" (built by UpdateIndicatorTable)
        -- caches these at rebuild time -- e.g. the "color" type's entry.color is
        -- read from t.customColors there, not re-read live -- so a live color
        -- pick needs the same rebuild "auras" already triggers.
        local CustomDispatch = SquizzFrames.modules and SquizzFrames.modules["Custom_Dispatch"]
        if CustomDispatch then
            CustomDispatch:Rebuild()
            -- Re-scan this button immediately so an already-active aura's
            -- indicator reflects the change now, not on the next UNIT_AURA.
            if CustomDispatch.Scan and button._indicatorsReady then
                CustomDispatch.Scan(button)
            end
        end
        -- AuraContainer-backed custom indicators (e.g. CreateCustomColorIndicator)
        -- aren't touched by Custom_Dispatch at all -- re-derive their own
        -- candidate filters/style directly.
        if indicator.RefreshSpellList then indicator:RefreshSpellList(t) end
        if setting == "customColors" and indicator.SetColor then indicator:SetColor() end
    elseif setting == "showUnfiltered" then
        -- Whether a spell-list indicator hides itself for units the identity
        -- gate won't let us filter (AEI.IdentityGateState). The checkbutton
        -- write path above already stored it on t; RefreshCandidateFilters is
        -- what re-runs the visibility decision. Called with no argument so it
        -- pushes regardless of whether the GATE moved -- the SETTING moved.
        if indicator.RefreshCandidateFilters then
            indicator:RefreshCandidateFilters()
        end
    elseif setting == "textWidth" or setting == "showGroupNumber" or setting == "hideRealmName" or setting == "vehicleNamePosition"
        or setting == "showPercentage" or setting == "showCurrent" or setting == "showMax" then
        -- nameText/healthText/powerText-specific settings — re-run the text updater so the
        -- FontString reflects the new width/group-number/vehicle position/display-mode.
        -- showPercentage/showCurrent/showMax previously weren't in this list at all: the
        -- checkbutton write path above already stores the new value on t, but without this
        -- branch nothing ever re-ran CheckHealthText/CheckPowerText to actually reflect it —
        -- toggling the checkbox silently updated the DB and visibly did nothing until some
        -- unrelated event (e.g. a health change) happened to refresh the text next.
        if (name == "nameText" or name == "healthText" or name == "powerText") and indicator and indicator._sfNameUpdater then
            indicator._sfNameUpdater()
        end
    elseif setting == "roleTexture" then
        -- roleIcon indicator - refresh the role texture
        if name == "roleIcon" and BuiltIn and BuiltIn.CheckRoleIcon then
            BuiltIn.CheckRoleIcon(indicator:GetParent())
        end
    elseif setting == "useBuiltInExternals" or setting == "customExternals"
        or setting == "useBuiltInDefensives" or setting == "customDefensives"
        or setting == "useBuiltInMissingBuffs" or setting == "customMissingBuffs"
        or setting == "useBuiltInHots"
        or setting == "hiddenBuiltInExternals" or setting == "hiddenBuiltInDefensives"
        or setting == "hiddenBuiltInAoEHealings" or setting == "hiddenBuiltInCrowdControls"
        or setting == "hiddenBuiltInMissingBuffs" or setting == "hiddenBuiltInHots" then
        -- Spell list changed — push it live immediately so the change is
        -- visible without waiting for the next UNIT_AURA event.
        -- hiddenBuiltIn* is the per-spell "hide" checklist (Built-in Spells
        -- panel) filtered out in F.GetEffectiveSpellList. The AuraContainer-
        -- backed externalCooldowns/defensiveCooldowns (AuraEngineIndicators.lua)
        -- expose RefreshSpellList to re-derive candidateFilters; the legacy
        -- grid fallback has no such method and just gets a full re-scan.
        if indicator.RefreshSpellList then
            indicator:RefreshSpellList(t)
        elseif BuiltIn and BuiltIn.CheckAll then
            BuiltIn.CheckAll(indicator:GetParent())
        end
    elseif setting == "onlyShowOvershields" then
        -- The checkbutton write path above already stored the new value on
        -- t; CheckShieldBar reads it for its "only visible while
        -- clamped/overshielding" alpha logic, but nothing re-ran that check
        -- until now — same silent-no-op class as showPercentage/showCurrent.
        if BuiltIn and BuiltIn.CheckAll then
            BuiltIn.CheckAll(indicator:GetParent())
        end
    elseif setting == "reverseFill" or setting == "showOvershieldGlow" or setting == "showOverAbsorbGlow" then
        -- Same silent-no-op class as onlyShowOvershields: the checkbutton
        -- write path stores the new value on t, and CheckShieldOverlay/
        -- CheckHealAbsorb read it fresh every pass, but nothing re-ran that
        -- pass until now — visible as "the Shield Overlay / Heal Absorb
        -- preview doesn't update when I toggle a setting" (confirmed via user
        -- report), since the preview button never receives the real
        -- UNIT_HEALTH/UNIT_ABSORB_AMOUNT_CHANGED events that would otherwise
        -- eventually pick the change up on a live button.
        if BuiltIn and BuiltIn.CheckAll then
            BuiltIn.CheckAll(indicator:GetParent())
        end
    elseif setting == "debuffBlacklist" or setting == "bigDebuffCC" or setting == "dispellableByMe"
        or setting == "hideCCDebuffs" then
        -- Debuffs-specific filtering settings (bigDebuffCC is legacy-only,
        -- dropped from the AuraEngine version -- see CreateDebuffsIndicator's
        -- comment -- but harmless to still check for here since nothing
        -- writes it anymore). AuraEngine-backed indicator.RefreshFilters
        -- pushes the change live; the legacy CheckDebuffs reads all three
        -- fresh every pass but nothing else re-ran it immediately -- same
        -- silent-no-op class as onlyShowOvershields.
        if indicator.RefreshFilters then
            indicator:RefreshFilters(t)
        elseif BuiltIn and BuiltIn.CheckAll then
            BuiltIn.CheckAll(indicator:GetParent())
        end
    elseif setting == "showBackground" then
        -- statusText's background texture (see CreateBuiltInIndicator) --
        -- gated by whether the text itself is currently shown so toggling
        -- this on doesn't reveal an empty box while there's no status to
        -- display (PartyFrames.lua's UpdateStatus re-syncs this same way on
        -- every status change).
        if indicator._sfBG then
            indicator._sfBG:SetShown(not not value and indicator:IsShown())
        end
    end
end

-- -----------------------------------------------------------------
-- Central UpdateIndicators handler
-- -----------------------------------------------------------------
-- Signature: Fire("UpdateIndicators", indicatorName, setting, value, value2,
-- isRaidContext). Special case: indicatorName == nil means "refresh
-- everything" (e.g. after a layout or profile switch). "create" setting adds
-- a new indicator.
--
-- isRaidContext says WHICH indicator list (Party/Raid) this change targets:
-- true/false when the change came from the Designer (IndicatorsPanel.lua
-- always fires based on whichever tab it currently has open), or
-- nil/omitted for a handful of settings that are deliberately shared/
-- universal across both (Target Highlight, Hover Highlight, Frame Border --
-- edited from the Appearance/General tabs, which have no Party/Raid concept
-- at all; see OptionsFrame.lua's comment on FindIndicatorEntry). A nil
-- context is NOT filtered below -- it reaches every real button regardless
-- of that button's own current party/raid state, same as this whole system
-- behaved before the party/raid split existed.

-- Coalesces preview rebuilds to at most one per frame. A slider drag (X
-- Offset, size, ...) fires an update per value change, and a full rebuild
-- per tick would churn every indicator frame on the preview button. Batching
-- to the next frame keeps it visually instant while doing the work once.
local previewRebuildQueued = false
local function QueuePreviewRebuild()
    if previewRebuildQueued then return end
    previewRebuildQueued = true
    C_Timer.After(0, function()
        previewRebuildQueued = false
        if I.previewButton and I.BuildPreview then I.BuildPreview() end
        -- The full-group preview window mirrors the same settings, so it has
        -- to follow every rebuild. Its own QueueRebuild is a no-op while the
        -- window is closed, and coalesces on its own timer (20 buttons is a
        -- lot more work than the Designer's one, so it deliberately doesn't
        -- share this next-frame budget).
        local GroupPreview = SquizzFrames.GroupPreview
        if GroupPreview and GroupPreview.QueueRebuild then
            GroupPreview.QueueRebuild()
        end
    end)
end

-- Walk every known button (party buttons + preview) and apply the change.
-- Defined before UpdateIndicators so the forward reference resolves.
local function CollectAndApply(indicatorName, setting, value, value2, isRaidContext)
    local PartyFrames = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    if PartyFrames and PartyFrames.IterateButtons then
        PartyFrames:IterateButtons(function(button)
            -- A real button only needs refreshing if this change actually
            -- touched the list IT reads from right now -- pushing a
            -- Raid-tab change onto a button currently showing Party data
            -- would look up the wrong (unrelated) indicator entry for its
            -- OWN context and silently no-op at best.
            if button and button.indicators and (isRaidContext == nil or isRaidContext == I.IsRaidContext(button)) then
                ApplySettingToOne(button, indicatorName, setting, value, value2)
            end
        end)
    end
    -- Preview button: always apply. Its own context (I.previewIsRaidTab)
    -- matches whichever tab fired this change by construction when the
    -- change came from the Designer, and a nil/universal context is
    -- unfiltered by design (see this section's header comment).
    if I.previewButton and I.previewButton.indicators then
        ApplySettingToOne(I.previewButton, indicatorName, setting, value, value2)
        -- ...then re-run the preview's own full rebuild (2026-08-07).
        --
        -- ApplySettingToOne is a per-setting fast path, and several settings
        -- route through a built-in Check function that re-reads state from
        -- the indicator's own cached settings table rather than from the
        -- value passed in. On a REAL button that self-corrects within
        -- moments -- UNIT_HEALTH and friends keep firing and re-run the same
        -- checks against fresh data -- but the preview is event-less: this
        -- call is the ONLY thing that ever updates it, so anything the fast
        -- path misses stays stale until an unrelated action rebuilds it.
        -- Confirmed via user report: toggling Health Text's class color
        -- updated live frames instantly but not the preview, and switching
        -- to any other indicator (which rebuilds) then showed it correctly.
        --
        -- BuildPreview (not just HandleIndicators): it re-reads every
        -- setting from the profile AND re-feeds the fake aura data that
        -- custom indicators need. HandleIndicators on its own recreates
        -- custom indicator frames without CustomDispatch.InitPreview, which
        -- would leave them blank. This is exactly the path an indicator
        -- switch already takes -- the one confirmed to render correctly.
        -- Queued (see QueuePreviewRebuild) so a slider drag rebuilds once
        -- per frame rather than once per value change.
        QueuePreviewRebuild()
    end
end
local function UpdateIndicators(_, indicatorName, setting, value, value2, isRaidContext)
    if not SquizzFrames.db or not SquizzFrames.db.profile then return end
    -- "create"/"delete" always specify an explicit list (never universal --
    -- there's no such thing as a universal NEW indicator); default false/
    -- Party only as a defensive fallback if a caller ever omits it.
    local list = I.GetIndicatorsList(isRaidContext or false)

    if setting == "create" then
        -- value is the new indicator table
        if not value then return end
        FindOrCreateIndicatorSlot(value, isRaidContext or false)
    elseif setting == "delete" then
        -- Remove the indicator from the working list; the panel already
        -- removed it from the profile.
        for i, t in ipairs(list) do
            if t.indicatorName == indicatorName then
                table.remove(list, i)
                break
            end
        end
    end

    -- Rebuild custom indicator lookup tables for new/deleted indicators.
    if SquizzFrames.modules and SquizzFrames.modules["Custom_Dispatch"] then
        SquizzFrames.modules["Custom_Dispatch"]:Rebuild()
    end

    -- recompute enabled built-ins (bookkeeping only -- see its declaration)
    for k in pairs(enabledBuiltIns) do enabledBuiltIns[k] = nil end
    for _, t in ipairs(I.GetIndicatorsList(false)) do
        if t.enabled then enabledBuiltIns[t.indicatorName] = true end
    end
    for _, t in ipairs(I.GetIndicatorsList(true)) do
        if t.enabled then enabledBuiltIns[t.indicatorName] = true end
    end

    -- Update real unit buttons + preview.
    CollectAndApply(indicatorName, setting, value, value2, isRaidContext)
end

-- Add a freshly-created indicator table to the correct (Party/Raid) list --
-- the options panel handles the actual profile write; this just mirrors
-- into the runtime list on a Create.
function FindOrCreateIndicatorSlot(t, isRaid)
    local list = I.GetIndicatorsList(isRaid)
    for _, existing in ipairs(list) do
        if existing.indicatorName == t.indicatorName then return end
    end
    list[#list + 1] = t
end

-- -----------------------------------------------------------------
-- Wiring: attach to party buttons as they're created.
-- -----------------------------------------------------------------
-- Message handlers: AceMessage passes the message name as the first arg, then
-- the payload. Use (_, header) to swallow the name.
local function OnPartyButtonsWired(_, header)
    -- header is the SecureGroupHeader; its children are the unit buttons.
    if type(header) ~= "table" then return end
    for _, button in ipairs(header) do
        -- SKIP CHILDREN WITH NO UNIT.
        --
        -- The secure header keeps every child it has ever created -- up to 40
        -- once it has been configured for raid -- and only assigns unit
        -- attributes to as many as the current group needs. The rest are real,
        -- unit-less frames, and building indicators on one is pure waste.
        --
        -- It was also actively harmful: the AuraEngine factories resolve their
        -- unit as `button.unit or button:GetAttribute("unit") or "player"`, so
        -- a unit-less child fell through to "player" and built a live
        -- AuraContainer bound to the player's own auras. Each container
        -- permanently strands a 10-button batch (WoW never destroys frames),
        -- and it happened for EVERY aura indicator -- a runtime dump showed 36
        -- healerHots containers on "player" against one per real party member.
        --
        -- Nothing is lost by waiting: WireUpAllButtons fires PartyButtonsWired
        -- again whenever the header assigns units, so a child that gains one
        -- later gets its indicators built then, with the right unit.
        local unit = button and (button.unit or (button.GetAttribute and button:GetAttribute("unit")))
        if button and button ~= UIParent and unit then
            I.HandleIndicators(button)
            readyButtons[button] = true
        end
    end
end

local function OnPartyButtonWiredSingle(_, button)
    if not button or type(button) ~= "table" then return end
    I.HandleIndicators(button)
    readyButtons[button] = true
end

-- -----------------------------------------------------------------
-- Module lifecycle
-- -----------------------------------------------------------------
function I:OnInitialize()
    BuiltIn = SquizzFrames.modules and SquizzFrames.modules["BuiltIn_Update"]
    self:RegisterMessage("PartyButtonsWired", OnPartyButtonsWired)
    self:RegisterMessage("PartyButtonWired", OnPartyButtonWiredSingle)
    self:RegisterMessage("UpdateIndicators", UpdateIndicators)
    self:RegisterMessage("ProfileChanged", "OnProfileChanged")
    -- Party <-> raid switch (bug fix 2026-08-07). Party and Raid have
    -- SEPARATE indicator lists (layout.indicators vs layout.indicatorsRaid,
    -- selected per-button by I.IsRaidContext), but this module never
    -- listened for the transition -- it only rebuilt parasitically, IF and
    -- WHEN PartyFrames happened to fire PartyButtonsWired. Registering
    -- directly makes the rebuild deterministic. ReapplyToAll is the same
    -- full-rebuild path a profile switch already uses, so it needs no new
    -- logic of its own.
    self:RegisterMessage("GroupTypeChanged", function() I:ReapplyToAll() end)
end

-- Bookkeeping only (see enabledBuiltIns' declaration -- nothing currently
-- reads it) -- merges both Party and Raid lists' enabled built-ins.
local function RecomputeEnabledBuiltIns()
    for k in pairs(enabledBuiltIns) do enabledBuiltIns[k] = nil end
    for _, t in ipairs(I.GetIndicatorsList(false)) do
        if t.enabled then enabledBuiltIns[t.indicatorName] = true end
    end
    for _, t in ipairs(I.GetIndicatorsList(true)) do
        if t.enabled then enabledBuiltIns[t.indicatorName] = true end
    end
end

function I:OnProfileChanged()
    RecomputeEnabledBuiltIns()
    if SquizzFrames.modules and SquizzFrames.modules["Custom_Dispatch"] then
        SquizzFrames.modules["Custom_Dispatch"]:Rebuild()
    end
    I:ReapplyToAll()
end

function I:OnEnable()
    RecomputeEnabledBuiltIns()

    HookEventSafe("UNIT_AURA")
    HookEventSafe("PLAYER_FLAGS_CHANGED")
    HookEventSafe("UNIT_CONNECTION")
    HookEventSafe("GROUP_ROSTER_UPDATE")
    HookEventSafe("PLAYER_ROLES_ASSIGNED")
    HookEventSafe("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
    HookEventSafe("UNIT_ENTERED_VEHICLE")
    HookEventSafe("UNIT_EXITED_VEHICLE")
    HookEventSafe("UNIT_HEALTH")
    HookEventSafe("UNIT_ABSORB_AMOUNT_CHANGED")
    HookEventSafe("UNIT_HEAL_ABSORB_AMOUNT_CHANGED")
    HookEventSafe("UNIT_THREAT_SITUATION_UPDATE")
    HookEventSafe("PLAYER_TARGET_CHANGED")
    HookEventSafe("READY_CHECK")
    HookEventSafe("READY_CHECK_CONFIRM")
    HookEventSafe("READY_CHECK_FINISHED")
    HookEventSafe("RAID_TARGET_UPDATE")
    HookEventSafe("PLAYER_REGEN_ENABLED")
    HookEventSafe("UNIT_NAME_UPDATE")
    HookEventSafe("UNIT_POWER_UPDATE")
    HookEventSafe("UNIT_MAXPOWER")
    -- Identity-gate only (see IDENTITY_GATE_EVENTS below). PLAYER_FLAGS_CHANGED,
    -- GROUP_ROSTER_UPDATE and the two vehicle events are in that set too, but
    -- are already registered above for their own reasons.
    HookEventSafe("PLAYER_ENTERING_WORLD")
    HookEventSafe("ZONE_CHANGED_NEW_AREA")
    HookEventSafe("UNIT_FACTION")
    HookEventSafe("CINEMATIC_STOP")
    HookEventSafe("PLAY_MOVIE")
    HookEventSafe("STOP_MOVIE")

    I:ReapplyToAll()
end

-- Event bucket: schedule a lightweight per-button pass slightly after the
-- event so rapid bursts coalesce.
local function ScheduleButtonUpdate(button, event)
    if not button or not button:IsShown() then return end
    if BuiltIn then
        BuiltIn.HandleEvent(button, event)
    end
    -- Aura events also feed the custom-indicator dispatcher.
    if event == "UNIT_AURA" then
        local CustomDispatch = SquizzFrames.modules and SquizzFrames.modules["Custom_Dispatch"]
        if CustomDispatch and button._indicatorsReady then
            CustomDispatch.Scan(button)
        end
    end
end

-- Events after which Blizzard's UnitCanAssist identity gate may read
-- differently than it did when a container's candidate filters were last
-- pushed. See AEI.RefreshIdentityGatedFilters.
local IDENTITY_GATE_EVENTS = {
    UNIT_ENTERED_VEHICLE = true,   -- the button's own unit token can change
    UNIT_EXITED_VEHICLE = true,
    PLAYER_ENTERING_WORLD = true,  -- instance <-> open world: the cross-faction flip
    ZONE_CHANGED_NEW_AREA = true,
    GROUP_ROSTER_UPDATE = true,    -- a cross-faction member joining/leaving
    PLAYER_FLAGS_CHANGED = true,   -- PvP flagging changes assistability
    -- The cinematic signal. Cutscenes flip assistability for EVERY unit --
    -- the local player included -- and the fail-open parse PERSISTS after the
    -- cutscene ends; 12.1 forces one on first login. UNIT_FLAGS notably does
    -- NOT fire for this transition, so UNIT_FACTION is the only edge that
    -- catches it (confirmed independently by DandersFrames and EllesmereUI).
    UNIT_FACTION = true,
    -- Belt-and-braces for the cutscene END. UNIT_FACTION usually fires again
    -- on the faction restore, but the addon-cancelled skip path is reported
    -- not to be reliable about it, and a missed recovery edge means the
    -- unfiltered pool stays for the rest of the session.
    CINEMATIC_STOP = true,
    PLAY_MOVIE = true,
    STOP_MOVIE = true,
}
-- The subset that exists ONLY to move the gate and must not fall through to
-- the generic per-button dispatch below.
local IDENTITY_GATE_ONLY_EVENTS = {
    UNIT_ENTERED_VEHICLE = true,
    UNIT_EXITED_VEHICLE = true,
    PLAYER_ENTERING_WORLD = true,
    ZONE_CHANGED_NEW_AREA = true,
    -- No unit payload at all (PLAY_MOVIE's first arg is a movieID), so these
    -- MUST be listed here -- the generic dispatch's "no unit -> broadcast"
    -- branch would otherwise read that first argument as a unit token. Same
    -- trap PLAYER_ENTERING_WORLD's isInitialLogin boolean sets.
    CINEMATIC_STOP = true,
    PLAY_MOVIE = true,
    STOP_MOVIE = true,
}

-- Coalesce the refresh to one pass per frame. UNIT_FACTION in particular fires
-- for every unit the client tracks, nameplates included, so a pull can produce
-- a burst of them; without this each one would walk five buttons calling
-- UnitCanAssist. The zero-delay timer is also what defers past the secure
-- header's own unit reassignment (see the call site).
local gateRefreshPending = false
local function ScheduleIdentityGateRefresh()
    if gateRefreshPending then return end
    gateRefreshPending = true
    C_Timer.After(0, function()
        gateRefreshPending = false
        local AEI = SquizzFrames.AuraEngineIndicators
        if AEI and AEI.RefreshIdentityGatedFilters then
            AEI.RefreshIdentityGatedFilters()
        end
    end)
end

-- Event handler. AceEvent dispatches registered events here as a method on
-- the module (self). unit is the event's first arg for unit-specific events.
function I:OnEvent(event, unit)
    -- READY_CHECK's first payload arg is initiatorName (a character name
    -- string, ALWAYS non-nil) and READY_CHECK_FINISHED's is preempted (a
    -- boolean -- true is non-nil/truthy too). Neither is ever a unit token,
    -- but the generic "not unit -> broadcast" branch below can't tell the
    -- difference and would instead try to look up a button literally named
    -- after the initiator (or "true"), silently reaching no one. Both are
    -- always broadcasts by nature (a ready check has no single "unit" of
    -- its own), so force that here rather than teaching every payload-args
    -- event apart below.
    if event == "READY_CHECK" or event == "READY_CHECK_FINISHED" then
        unit = nil
    end

    -- Anything that can move Blizzard's identity gate, which silently switches
    -- off spell-ID filtering on the three spell-list aura indicators -- see
    -- AEI.RefreshIdentityGatedFilters for the whole mechanism.
    --
    -- Not just vehicles: UnitCanAssist is legitimately false for a
    -- cross-faction group member in the open world and true for that same
    -- player inside a dungeon, so the gate also flips on every instance
    -- transition. Roster and PvP-flag changes can move it for the same reason.
    -- Blanket-firing on all of them is affordable because the refresh
    -- short-circuits when the reading hasn't actually changed.
    --
    -- Handled here rather than through the per-built-in event table because
    -- it isn't a "re-check this indicator" job: it re-measures the gate and
    -- re-pushes container filters, which is AuraEngine's business, not
    -- BuiltIn_Update's.
    --
    -- Deferred a frame: the button carries toggleForVehicle, so the secure
    -- header's own unit swap is triggered by the vehicle events and there's no
    -- ordering guarantee we run after it; the same goes for the header's
    -- re-sort on a roster change. Measuring the gate against the pre-swap
    -- token would just re-cache the wrong answer.
    if IDENTITY_GATE_EVENTS[event] then
        ScheduleIdentityGateRefresh()
        -- Vehicle transitions, and the two zone events, have no other job here
        -- -- and PLAYER_ENTERING_WORLD's first payload arg is isInitialLogin,
        -- a boolean the generic "no unit -> broadcast" branch below would
        -- happily treat as a unit token (same trap as READY_CHECK above).
        -- The rest (roster, flags, faction) still need their normal dispatch.
        if IDENTITY_GATE_ONLY_EVENTS[event] then return end
    end
    if not unit then
        -- global events: push to every button
        local PartyFrames = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
        if PartyFrames and PartyFrames.IterateButtons then
            PartyFrames:IterateButtons(function(b)
                ScheduleButtonUpdate(b, event)
            end)
        end
        if I.previewButton then ScheduleButtonUpdate(I.previewButton, event) end
        return
    end
    local PartyFrames = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    if PartyFrames and PartyFrames.FindButtonByUnit then
        local button = PartyFrames.FindButtonByUnit(unit)
        if button then
            ScheduleButtonUpdate(button, event)
        end
    end
end

-- Register an event with the module's AceEvent handler (idempotent).
local hookedEvents = {}
function HookEventSafe(event)
    if hookedEvents[event] then return end
    hookedEvents[event] = true
    I:RegisterEvent(event, "OnEvent")
end
function UnhookEventSafe(event)
    if not hookedEvents[event] then return end
    hookedEvents[event] = false
end

function I:ReapplyToAll()
    local PartyFrames = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    if PartyFrames and PartyFrames.IterateButtons then
        PartyFrames:IterateButtons(function(b)
            I.HandleIndicators(b)
            readyButtons[b] = true
        end)
    end
end

-- -----------------------------------------------------------------
-- Public surface used by the options panel.
-- -----------------------------------------------------------------

-- Build / return the preview button. Lazily created; anchored onto UIParent.
function I.GetPreviewButton()
    if I.previewButton then return I.previewButton end
    local button = CreateFrame("Button", "SquizzFramesIndicatorPreviewButton", UIParent, "SquizzFramesUnitButtonTemplate")
    button:SetSize(100, 40)
    button:SetPoint("CENTER", 220, 0)
    button:Show()
    button.unit = "player"
    button.indicators = {}
    -- fake a stable "displayedUnit" for the custom dispatcher.
    button.states = { displayedUnit = "player" }
    button._indicatorsReady = false
    -- Health/power bars need explicit width (template only anchors left side)
    if button.healthBar then
        button.healthBar:SetWidth(100)
    end
    if button.powerBar then
        button.powerBar:SetWidth(100)
    end
    -- Resolve FontString children from template (parentKey doesn't work for
    -- FontStrings in <Layers>; they need _G lookup like in UnitButton.lua).
    local n = button:GetName()
    if n then
        button.nameText   = button.nameText   or _G[n .. "Name"]
        button.statusText = button.statusText or _G[n .. "Status"]
        button.healthText = button.healthText or _G[n .. "HealthText"]
        button.roleIcon   = button.roleIcon   or _G[n .. "RoleIcon"]
        button.raidIcon   = button.raidIcon   or _G[n .. "RaidIcon"]
        button.healthBackdrop = button.healthBackdrop or _G[n .. "HealthBackdrop"]
    end
    -- Set button frameLevel high so nameText (FontString child) renders above healthBar (frameLevel=1 from XML)
    button:SetFrameLevel(10)
    I.SetPreviewButton(button)
    return button
end

-- Rebuild all indicators on the preview button and give it fake data so the
-- preview visibly reflects the current settings.
function I.BuildPreview()
    local pb = I.GetPreviewButton()
    -- InitPreviewData FIRST. HandleIndicators internally runs its own
    -- BuiltIn.CheckAll(pb) pass as its last step -- if that ran before
    -- _sfFakeHealth/_sfFakeHealthMax exist, CheckHealthText (and
    -- CheckPowerText) would see them as nil and fall through to their LIVE
    -- branch for this one pass, touching real UnitHealth/AbbreviateNumbers/
    -- UnitHealthPercent for "player". That's enough to permanently taint
    -- the healthText FontString's geometry (confirmed: this is why its
    -- marching-ants border never animated even after the fake-data branch
    -- itself was made fully safe -- the FIRST pass never reached that fixed
    -- code, it used the live branch instead). nameText survived the same
    -- ordering bug only because its own live-branch fallback, UnitFullName,
    -- never touches a secret-capable API. InitPreviewData's own CheckAll
    -- call (at its end) is a harmless no-op here since indicators don't
    -- exist yet -- HandleIndicators creates them and re-checks right after,
    -- by which point the fake data is already in place.
    I.InitPreviewData(pb)
    I.HandleIndicators(pb)
    -- CustomDispatch.InitPreview must run AFTER HandleIndicators, not before
    -- (InitPreviewData used to call it directly, before HandleIndicators had
    -- created any indicator frames yet). InitPreview only feeds fake aura
    -- data to indicators it finds in button.indicators -- for a BRAND NEW
    -- custom indicator, that table entry doesn't exist until HandleIndicators
    -- creates it, so the very first BuildPreview after adding a custom
    -- indicator (e.g. right after adding its first tracked aura) silently
    -- skipped it, leaving it permanently blank (0-value bar / empty icon)
    -- until some unrelated change happened to trigger a second full rebuild.
    local CustomDispatch = SquizzFrames.modules and SquizzFrames.modules["Custom_Dispatch"]
    if CustomDispatch then
        CustomDispatch.InitPreview(pb)
    end
    I.UpdatePreviewAppearance(pb)
end

-- Update the preview button's health/power bar appearance to match settings
function I.UpdatePreviewAppearance(pb)
    if not pb or not pb.healthBar or not pb.powerBar then return end
    local db = SquizzFrames.db and SquizzFrames.db.profile
    local appearance = db and db.appearance
    if not appearance then return end

    -- Get statusbar texture from LSM
    local LSM = LibStub and LibStub:GetLibrary("LibSharedMedia-3.0", true)
    local texture = LSM and LSM:Fetch("statusbar", appearance.general and appearance.general.texture or "Blizzard")
    if not texture then texture = [[Interface\TargetingFrame\UI-StatusBar]] end

    -- Apply to health bar
    pb.healthBar:SetStatusBarTexture(texture)

    -- Apply to power bar
    pb.powerBar:SetStatusBarTexture(texture)

    -- Get health bar color (class_color for players)
    local healthColor = appearance.healthBar and appearance.healthBar.fullColor
    if healthColor and healthColor[1] == "class_color" then
        local classFile = F.GetClassFile("player")
        local c = classFile and RAID_CLASS_COLORS[classFile]
        if c then
            pb.healthBar:SetStatusBarColor(c.r, c.g, c.b, 1)
        end
    elseif healthColor and healthColor[1] == "custom_color" and #healthColor >= 3 then
        pb.healthBar:SetStatusBarColor(healthColor[2], healthColor[3], healthColor[4] or 1, healthColor[5] or 1)
    end

    -- Get power bar color -- class_color / custom_color / blizzard_default
    -- (PowerBarColor's stock per-power-type color, e.g. mana=blue), mirroring
    -- PartyFrames.lua's UpdatePower _sfFakeName branch. Preview has no real
    -- unit, so class color uses the fake class the Designer already mocks
    -- (F.GetClassFile("player")), and blizzard_default uses the player's
    -- actual current power type (a reasonable representative preview -- the
    -- alternative, hardcoding "MANA", would look wrong for e.g. a Rogue).
    local powerColor = appearance.powerBar and appearance.powerBar.powerColor
    if powerColor and powerColor[1] == "class_color" then
        local classFile = F.GetClassFile("player")
        local c = classFile and RAID_CLASS_COLORS[classFile]
        if c then
            pb.powerBar:SetStatusBarColor(c.r, c.g, c.b, 0.8)
        end
    elseif powerColor and powerColor[1] == "custom_color" and #powerColor >= 3 then
        pb.powerBar:SetStatusBarColor(powerColor[2], powerColor[3], powerColor[4] or 1, powerColor[5] or 1)
    else
        local powerType = UnitPowerType("player")
        local colors = PowerBarColor[powerType] or {r = 1, g = 1, b = 1}
        pb.powerBar:SetStatusBarColor(colors.r, colors.g, colors.b, 0.8)
    end
end

-- Populate the preview button with fake unit data so indicators can render
-- something meaningful even though preview isn't a real unit.
function I.InitPreviewData(pb)
    if not pb then return end
    -- Fake class/role/unit info.
    pb._sfFakeClass = F.GetClassFile("player") or "DRUID"
    -- F.GetRoleKey instead of `UnitGroupRolesAssigned(...) or "HEALER"` --
    -- avoids a truthiness test on a potentially-secret return (12.1) and
    -- always yields a valid TANK/HEALER/DAMAGER key.
    pb._sfFakeRole = F.GetRoleKey("player")
    pb._sfFakeThreat = 0
    pb._sfFakeTarget = true
    pb._sfFakeLeader = true
    pb._sfFakeRaidIcon = 1
    pb._sfFakeReady = "ready"
    pb._sfFakeConnection = true
    pb._sfFakeFlags = 0
    -- Fake health/power data: hardcoded, never derived from a real UnitHealth/
    -- UnitPower call. The preview's whole point is a guaranteed-safe mockup
    -- that always renders regardless of game state -- reading the player's
    -- REAL health here (even "just for a fake number") defeats that the
    -- moment the player's own health happens to be a secret number (e.g. in
    -- group/instance content). The previous "pcall(function() return val + 0
    -- end)" sanitize attempt silently failed in exactly that case, leaving
    -- _sfFakeHealth nil, which made CheckHealthText fall through to its LIVE
    -- (real button.unit) branch even for the preview button -- tainting the
    -- whole indicator-update pass for that button, including unrelated
    -- frame-geometry reads later in the same pass (e.g. the preview
    -- highlight's f:GetWidth() in ShowPreviewHighlight/LayoutDashes, which
    -- started throwing "attempt to compare a secret number value").
    -- Static demo numbers side-step this category of bug entirely.
    pb._sfFakeHealth = 75000
    pb._sfFakeHealthMax = 100000
    pb._sfFakePower = 65000
    pb._sfFakePowerMax = 100000
    -- Fake name for nameText indicator
    pb._sfFakeName = UnitName("player") or "PlayerName"
    -- Fake status (connected, not AFK, not dead)
    pb._sfFakeIsConnected = true
    pb._sfFakeIsAFK = false
    pb._sfFakeIsDead = false
    pb._sfFakeIsGhost = false
    pb._sfFakeAssistant = false
    -- Shield/heal-absorb built-ins (shieldBar/shieldOverlay/healAbsorb) derive
    -- their own synthetic demo values from _sfFakeHealth/_sfFakeHealthMax
    -- directly (see BuiltIn_Update.lua) rather than reading a fake absorb
    -- value here -- the player's own live absorb is usually 0 while
    -- designing, which would render as an empty/invisible bar.

    -- Run a check pass so built-ins that can render with fake data do so.
    if BuiltIn then
        BuiltIn.CheckAll(pb)
    end
    -- Custom indicators' fake-aura preview data (CustomDispatch.InitPreview)
    -- is applied later, in BuildPreview -- AFTER HandleIndicators has had a
    -- chance to create indicator frames that don't exist yet. See BuildPreview's
    -- comment for why calling it here (before those frames exist) doesn't work.
end

-- Record a preview button reference for the options panel.
function I.SetPreviewButton(button)
    I.previewButton = button
    if button then
        -- Marks it as a mock button for every preview-rendering branch (see
        -- I.IsPreviewButton), and seeds its per-button raid context from the
        -- Designer's current tab.
        button._sfIsPreviewButton = true
        button._sfPreviewIsRaid = I.previewIsRaidTab
    end
end

SquizzFrames.Indicators = I

-- -----------------------------------------------------------------
-- Preview Highlight Border (Cell-style animated border around selected indicator)
-- -----------------------------------------------------------------
local previewHighlight

-- Name of the indicator the highlight/drag proxy currently wraps. Also used
-- as the anchor payload for dragging (position table, resolved anchor
-- frame/points) so OnDragStart doesn't need to re-derive it.
local highlightedName
local dragState

-- Snapping: while dragging, the indicator's own left/center/right and
-- top/center/bottom (in screen coordinates) are compared against these
-- "lines" collected from the unit button, health bar, and every other
-- visible indicator on the preview -- close enough within SNAP_PX snaps
-- exactly onto it.
local SNAP_PX = 7

local function GatherSnapLines(pb, skipIndicator)
    local xs, ys = {}, {}
    local function AddLines(f)
        if not f or not f.GetLeft then return end
        local l, r, top, bottom = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
        if l and r then
            xs[#xs + 1] = l
            xs[#xs + 1] = (l + r) / 2
            xs[#xs + 1] = r
        end
        if top and bottom then
            ys[#ys + 1] = top
            ys[#ys + 1] = (top + bottom) / 2
            ys[#ys + 1] = bottom
        end
    end
    AddLines(pb)
    if pb.healthBar then AddLines(pb.healthBar) end
    if pb.indicators then
        for _, ind in pairs(pb.indicators) do
            if ind ~= skipIndicator and ind.IsShown and ind:IsShown() then
                AddLines(ind)
            end
        end
    end
    return xs, ys
end

-- Returns the correction (line - refValue) for whichever (refValue, line)
-- pair is closest within `threshold`, or nil if nothing is close enough.
local function BestSnapDelta(refValues, lines, threshold)
    local bestDelta, bestDist
    for _, ref in ipairs(refValues) do
        for _, line in ipairs(lines) do
            local dist = math.abs(line - ref)
            if dist <= threshold and (not bestDist or dist < bestDist) then
                bestDist = dist
                bestDelta = line - ref
            end
        end
    end
    return bestDelta
end

-- Marching-ants dashed border: small gold squares that crawl clockwise
-- around the perimeter (not just pulsing in place). Solid class-color/accent
-- borders can visually disappear against a similarly-colored health bar
-- (e.g. a green class color against a green health bar), so this is
-- hardcoded gold rather than accent-colored, and dashed/dotted rather than
-- solid so it reads as a selection marquee regardless of what's under it.
-- Each dash also gets a 1px black outline: a single fixed color can still
-- lose contrast against SOME background (gold-on-bright-green, say), but a
-- dark outline reads on top of literally anything behind it, the same way
-- image editors' marquee/selection borders guarantee visibility.
local DASH_LEN = 4
local DASH_GAP = 3
local DASH_PERIOD = DASH_LEN + DASH_GAP
local DASH_THICK = 2
local DASH_OUTLINE = 1
local DASH_COLOR = { 1, 0.82, 0 }
local MARCH_SPEED = 24 -- perimeter pixels/second, clockwise

-- Clamps a long-edge segment [start, start+len] to fit within [0, edgeLen],
-- shrinking it from whichever side crosses the boundary. Without this, a
-- dash (or its outline, padded further out) whose start lands close to a
-- corner renders past that corner into the perpendicular edge's space --
-- exactly the overshoot this is fixing.
local function ClampSegment(start, len, edgeLen)
    local finish = start + len
    if start < 0 then start = 0 end
    if finish > edgeLen then finish = edgeLen end
    return start, math.max(finish - start, 0)
end

-- Positions one dash's fill + outline pair at clockwise perimeter distance
-- `d`: 0 is the top-left corner, increasing rightward along the top edge,
-- then down the right, then leftward along the bottom, then up the left,
-- wrapping at the total perimeter (2w + 2h). Anchoring each edge from the
-- corner it travels AWAY from keeps every offset a plain positive count up
-- to that edge's own length, rather than juggling signs per edge. The
-- outline is padded DASH_OUTLINE px outward on every side of the fill (and
-- clamped the same as the fill, so the outline's padding can't push it past
-- a corner either).
local function PlaceDashAtPerimeter(fill, outline, parent, d, w, h)
    local perimeter = 2 * (w + h)
    d = d % perimeter
    local pad = DASH_OUTLINE
    if d < w then
        local fs, fl = ClampSegment(d, DASH_LEN, w)
        fill:SetPoint("TOPLEFT", parent, "TOPLEFT", fs, 0)
        fill:SetSize(fl, DASH_THICK)
        local os, ol = ClampSegment(d - pad, DASH_LEN + 2 * pad, w)
        outline:SetPoint("TOPLEFT", parent, "TOPLEFT", os, pad)
        outline:SetSize(ol, DASH_THICK + 2 * pad)
    elseif d < w + h then
        local y = d - w
        local fs, fl = ClampSegment(y, DASH_LEN, h)
        fill:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -fs)
        fill:SetSize(DASH_THICK, fl)
        local os, ol = ClampSegment(y - pad, DASH_LEN + 2 * pad, h)
        outline:SetPoint("TOPRIGHT", parent, "TOPRIGHT", pad, -os)
        outline:SetSize(DASH_THICK + 2 * pad, ol)
    elseif d < 2 * w + h then
        local x = d - w - h
        local fs, fl = ClampSegment(x, DASH_LEN, w)
        fill:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -fs, 0)
        fill:SetSize(fl, DASH_THICK)
        local os, ol = ClampSegment(x - pad, DASH_LEN + 2 * pad, w)
        outline:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -os, -pad)
        outline:SetSize(ol, DASH_THICK + 2 * pad)
    else
        local y = d - 2 * w - h
        local fs, fl = ClampSegment(y, DASH_LEN, h)
        fill:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, fs)
        fill:SetSize(DASH_THICK, fl)
        local os, ol = ClampSegment(y - pad, DASH_LEN + 2 * pad, h)
        outline:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", -pad, os)
        outline:SetSize(DASH_THICK + 2 * pad, ol)
    end
end

-- Recomputes dash positions for the highlight's CURRENT size, offset by
-- `phase` (0..DASH_PERIOD) along the perimeter. Called every frame the
-- highlight is shown (phase advancing each time) so the dashes appear to
-- travel continuously clockwise, not just sit in a fixed pattern. Reuses a
-- growing pool of fill+outline texture pairs rather than recreating them
-- each call.
local function LayoutDashes(f, phase)
    local w, h = f:GetWidth(), f:GetHeight()
    if not w or w <= 0 or not h or h <= 0 then return end
    f.dashes = f.dashes or {}
    local pool = f.dashes
    local perimeter = 2 * (w + h)
    local count = math.max(1, math.floor(perimeter / DASH_PERIOD))
    phase = phase or 0

    for i = 0, count - 1 do
        local idx = i + 1
        local pair = pool[idx]
        if not pair then
            local outline = f:CreateTexture(nil, "ARTWORK")
            outline:SetColorTexture(0, 0, 0, 0.9)
            local fill = f:CreateTexture(nil, "OVERLAY")
            fill:SetColorTexture(DASH_COLOR[1], DASH_COLOR[2], DASH_COLOR[3], 1)
            pair = { fill = fill, outline = outline }
            pool[idx] = pair
        end
        pair.fill:ClearAllPoints()
        pair.outline:ClearAllPoints()
        PlaceDashAtPerimeter(pair.fill, pair.outline, f, i * DASH_PERIOD + phase, w, h)
        pair.fill:Show()
        pair.outline:Show()
    end

    for i = count + 1, #pool do
        pool[i].fill:Hide()
        pool[i].outline:Hide()
    end
end

-- Sizes/positions the highlight EXPLICITLY from the indicator's own current
-- GetWidth()/GetHeight(), rather than two opposing-corner anchors
-- (TOPLEFT+BOTTOMRIGHT) computed FROM the indicator. The dual-anchor form
-- looked correct on paper -- WoW anchors are live, not snapshotted -- but in
-- practice never picked up later SetSize() calls on the indicator (e.g. the
-- Size widget's Width/Height sliders): the border stayed frozen at whatever
-- size the indicator was when first selected. Reading the indicator's real
-- dimensions directly and applying them to the highlight with a single
-- CENTER anchor sidesteps whatever anchor-recompute quirk that relied on.
local function SyncHighlightGeometry(highlight, indicator)
    local w, h = indicator:GetWidth(), indicator:GetHeight()
    highlight:ClearAllPoints()
    if w and w > 0 and h and h > 0 then
        highlight:SetSize(w + 4, h + 4)
        highlight:SetPoint("CENTER", indicator, "CENTER", 0, 0)
    else
        -- Indicator hasn't resolved a real size yet (e.g. very first paint) --
        -- fall back to the old dual-anchor form so the highlight still shows
        -- SOMETHING roughly right rather than nothing.
        highlight:SetPoint("TOPLEFT", indicator, "TOPLEFT", -2, 2)
        highlight:SetPoint("BOTTOMRIGHT", indicator, "BOTTOMRIGHT", 2, -2)
    end
end

-- See the forward declaration's comment near the top of the file. Deferred
-- through C_Timer.After(0, ...), same reasoning as ShowPreviewHighlight's
-- own deferred read: f:GetWidth()/GetHeight() (and here, indicator's own
-- geometry) can come back secret if execution was tainted earlier in the
-- same call stack, and a fresh timer callback starts a clean one.
RefreshHighlightSize = function(name)
    if not previewHighlight or highlightedName ~= name then return end
    local pb = I.GetPreviewButton()
    local indicator = pb and pb.indicators and pb.indicators[name]
    if not indicator then return end
    C_Timer.After(0, function()
        if highlightedName ~= name or not previewHighlight or not previewHighlight:IsShown() then return end
        SyncHighlightGeometry(previewHighlight, indicator)
        LayoutDashes(previewHighlight, previewHighlight._marchPhase)
    end)
end

local function CreatePreviewHighlight(parentButton)
    if previewHighlight then return previewHighlight end
    -- Parented to the preview button (NOT UIParent) so it inherits normal
    -- ancestor-visibility: when the Designer page hides (e.g. switching to
    -- the Built-in/Custom tab), this hides along with it automatically,
    -- instead of floating on screen as a stray box until something remembers
    -- to call HidePreviewHighlight explicitly. SetFrameStrata below still
    -- lets it render above everything on the button regardless of parent.
    local f = CreateFrame("Frame", "SquizzFramesPreviewHighlight", parentButton or UIParent)
    f:SetFrameStrata("TOOLTIP")
    f:Hide()
    f._marchPhase = 0

    -- The highlight border doubles as the drag handle: it's the one frame
    -- that's ALWAYS mouse-interactive regardless of whether the underlying
    -- indicator is a Frame or a plain FontString/Texture region (FontStrings
    -- can't EnableMouse/RegisterForDrag themselves, so dragging the indicator
    -- directly isn't an option for nameText/healthText/statusText/etc).
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")

    f:SetScript("OnDragStart", function(self)
        if not highlightedName then return end
        local t = FindIndicatorByName(I.GetIndicatorsList(I.previewIsRaidTab), highlightedName)
        local pb = I.GetPreviewButton()
        local indicator = pb and pb.indicators and pb.indicators[highlightedName]
        if not t or not t.position or not indicator then return end

        local startCursorX, startCursorY = GetCursorPosition()
        dragState = {
            name = highlightedName,
            indicator = indicator,
            point = ResolvePoint(t.position[1]),
            relativeTo = ResolveRelative(pb, t.position[2]),
            relativePoint = ResolvePoint(t.position[3]),
            startX = t.position[4] or 0,
            startY = t.position[5] or 0,
            startCursorX = startCursorX,
            startCursorY = startCursorY,
            scale = indicator.GetEffectiveScale and indicator:GetEffectiveScale() or 1,
        }
    end)

    -- Persists the dragged position and clears dragState. Shared by the real
    -- OnDragStop below AND the defensive "mouse button isn't actually down
    -- anymore" check in OnUpdate -- some indicators (observed with External
    -- Cooldowns, a grid of individually mouse-enabled cooldown icons) can
    -- apparently swallow the mouse-up before it reaches this frame despite
    -- its TOOLTIP strata, so OnDragStop never fires and dragState is left
    -- stuck forever, permanently gluing the indicator to the cursor (it only
    -- LOOKS like it stops when the Designer closes, because OnUpdate can't
    -- run on a hidden frame -- reopening immediately resumes it, since
    -- dragState was never actually cleared). Checking IsMouseButtonDown
    -- every frame means a stuck drag self-heals within one tick regardless
    -- of why the real drag-stop event didn't arrive.
    local function FinishDrag()
        if not dragState then return end
        local t = FindIndicatorByName(I.GetIndicatorsList(I.previewIsRaidTab), dragState.name)
        if t and t.position then
            -- Keep whatever anchor point was already selected for this
            -- indicator (dragState.point/relativePoint, captured at
            -- OnDragStart and never changed mid-drag -- OnUpdate's own
            -- SetPoint call below uses these same fixed values throughout)
            -- -- just update the offset to wherever it was actually dropped.
            -- An earlier version of this re-anchored to whichever corner the
            -- indicator ended up nearest, meant to keep it tracking the
            -- right/bottom edge across button resizes -- but per explicit
            -- user report, that corner-recompute could pick a DIFFERENT
            -- point than the one selected, making the indicator visibly
            -- "snap" to an unwanted spot the moment the drag ended. If you
            -- want an indicator anchored to a specific edge/corner, set that
            -- anchor point explicitly (position dropdown) before dragging --
            -- dragging then only ever adjusts the offset from it.
            local point, relativePoint = dragState.point, dragState.relativePoint
            local offX = math.floor((dragState.finalX or dragState.startX) + 0.5)
            local offY = math.floor((dragState.finalY or dragState.startY) + 0.5)

            local newPosition = { point, t.position[2], relativePoint, offX, offY }
            SquizzFrames:Fire("UpdateIndicators", dragState.name, "position", newPosition, nil, I.previewIsRaidTab)
            if I.OnPreviewPositionDragged then I.OnPreviewPositionDragged(dragState.name, newPosition) end
        end
        dragState = nil
    end

    f:SetScript("OnUpdate", function(self, elapsed)
        -- Marching ants: always advances, whether or not a drag is in
        -- progress, so the border keeps crawling clockwise the whole time
        -- the highlight is shown.
        self._marchPhase = (self._marchPhase or 0) + MARCH_SPEED * elapsed
        if self._marchPhase >= DASH_PERIOD then
            self._marchPhase = self._marchPhase % DASH_PERIOD
        end

        if dragState and not IsMouseButtonDown("LeftButton") then
            FinishDrag()
        end

        if dragState then
            local curX, curY = GetCursorPosition()
            local scale = dragState.scale or 1
            local newX = dragState.startX + (curX - dragState.startCursorX) / scale
            local newY = dragState.startY + (curY - dragState.startCursorY) / scale

            local indicator = dragState.indicator
            indicator:ClearAllPoints()
            indicator:SetPoint(dragState.point, dragState.relativeTo, dragState.relativePoint, newX, newY)

            -- Snap: measure the indicator's freshly-positioned rect and nudge
            -- it onto the nearest button/health-bar/other-indicator line, if
            -- close. GetLeft/GetRight/GetTop/GetBottom on a frame anchored
            -- (even indirectly) to something touched while execution was
            -- tainted (e.g. a real unit's aura/health data read elsewhere)
            -- can themselves come back as secret numbers -- arithmetic on
            -- them (the averaging below) then throws and would silently
            -- kill the rest of this OnUpdate tick, including the position
            -- write further down, which is why dragging looked like it
            -- "snapped back" and never saved. pcall this block so a bad
            -- tick just skips snapping instead of aborting the whole drag.
            local pb = I.GetPreviewButton()
            if pb then
                pcall(function()
                    local l, r, top, bottom = indicator:GetLeft(), indicator:GetRight(), indicator:GetTop(), indicator:GetBottom()
                    if l and r and top and bottom then
                        local xs, ys = GatherSnapLines(pb, indicator)
                        local dx = BestSnapDelta({ l, (l + r) / 2, r }, xs, SNAP_PX)
                        local dy = BestSnapDelta({ top, (top + bottom) / 2, bottom }, ys, SNAP_PX)
                        if dx or dy then
                            newX = newX + (dx or 0) / scale
                            newY = newY + (dy or 0) / scale
                            indicator:ClearAllPoints()
                            indicator:SetPoint(dragState.point, dragState.relativeTo, dragState.relativePoint, newX, newY)
                        end
                    end
                end)
            end

            dragState.finalX, dragState.finalY = newX, newY

            SyncHighlightGeometry(self, indicator)
        end

        -- Same reasoning as above: f:GetWidth()/GetHeight() can come back
        -- secret if anchored (even indirectly) to something touched while
        -- tainted. pcall so a bad tick just skips this frame's dash layout
        -- (marching ants pause for a tick) instead of throwing every single
        -- frame and never animating at all.
        pcall(LayoutDashes, self, self._marchPhase)
    end)

    f:SetScript("OnDragStop", FinishDrag)

    previewHighlight = f
    return f
end

-- Show animated border around the named indicator on the preview button
function I.ShowPreviewHighlight(indicatorName)
    local pb = I.GetPreviewButton()
    if not pb or not pb.indicators then return end
    local indicator = pb.indicators[indicatorName]
    if not indicator then
        I.HidePreviewHighlight()
        return
    end
    highlightedName = indicatorName
    local highlight = CreatePreviewHighlight(pb)
    -- Defer the geometry read (SyncHighlightGeometry/LayoutDashes call
    -- f:GetWidth()/GetHeight()) by one frame. WoW's secret/taint system is
    -- scoped to the call stack, not wall-clock time -- if ANYTHING earlier
    -- in the SAME event-handling pass touched a secret value (e.g. a real
    -- party button's aura scan running in the same tick), the rest of that
    -- call stack can inherit a "tainted execution" marker, and frame
    -- geometry reads made while inside it can come back as secret even
    -- though they have nothing to do with auras/health -- confirmed: this is
    -- what was throwing "attempt to compare/perform arithmetic on a secret
    -- number, while execution tainted by 'SquizzFrames'" here. A fresh
    -- C_Timer callback starts a new, untainted call stack.
    C_Timer.After(0, function()
        if highlightedName ~= indicatorName then return end
        SyncHighlightGeometry(highlight, indicator)
        LayoutDashes(highlight)
        highlight:Show()
    end)
end

function I.HidePreviewHighlight()
    highlightedName = nil
    if previewHighlight then
        previewHighlight:Hide()
    end
end
