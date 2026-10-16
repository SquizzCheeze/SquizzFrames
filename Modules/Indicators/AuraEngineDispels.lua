--[[ SquizzFrames AuraEngineDispels.lua -- the Dispels overlay (tint, border,
    pulse and animated border) and the separate Dispel Icons indicator, both
    on AuraEngine. Moved out of AuraEngineIndicators.lua unchanged in 2.0
    (phase 2 code split). Everything public is still on AEI
    (SquizzFrames.AuraEngineIndicators): CreateDispelsIndicator,
    CreateDispelIconsIndicator, PreviewDispelOverlay, DISPEL_TYPES,
    HealthBottomInset, FrameBorderInset, AnchorHealthFillOverlay. ]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local AEI = SquizzFrames.AuraEngineIndicators
if not AEI then return end

local F = SquizzFrames.F
local ExtractSize = AEI.shared.ExtractSize

------------------------------------------------------------------------
-- Dispels: per-type health-bar overlay/border/icon via AuraContainer slots.
-- Mirrors EllesmereUI's 12.1 architecture (EUI_RaidFrames_AuraContainers.lua,
-- reviewed directly from the local PTR install) rather than a manual
-- C_UnitAuras scan: one bare (noRegions) slot per dispel type, each filtered
-- via candidateFilters.includeDispelTypes so WHICH type is present is known
-- by WHICH slot has content -- the engine does the type-matching internally,
-- so the (secret-in-combat) dispel type string is never read by us at all.
------------------------------------------------------------------------

-- `level` (1-5) staggers each type's slot frame level just above the health
-- bar, mirroring EllesmereUI's own proven AuraContainer dispel implementation
-- (EUI_RaidFrames_AuraContainers.lua: health:GetFrameLevel() + 1 + def.level).
-- This only works because UnitButton.lua's OnLoad now guarantees the button
-- itself sits at frame level 20+ -- Ellesmere's host frame apparently has a
-- similarly generous budget built in, but SquizzFrames's own template only
-- left a 2-level gap (button~3, health=1) until that bump was added, which
-- is what made the first attempt at this exact formula fail on some slots.
-- Array order also doubles as RefreshFallbackVisuals's "first enabled type"
-- priority order on the Designer preview.
local DISPEL_TYPES = {
    { key = "magic",   token = "Magic",   colorKey = "Magic",   atlas = "RaidFrame-Icon-DebuffMagic",   fallback = { 0.20, 0.60, 1.00 }, level = 5 },
    { key = "curse",   token = "Curse",   colorKey = "Curse",   atlas = "RaidFrame-Icon-DebuffCurse",   fallback = { 0.60, 0.00, 1.00 }, level = 4 },
    { key = "disease", token = "Disease", colorKey = "Disease", atlas = "RaidFrame-Icon-DebuffDisease", fallback = { 0.60, 0.40, 0.00 }, level = 3 },
    { key = "poison",  token = "Poison",  colorKey = "Poison",  atlas = "RaidFrame-Icon-DebuffPoison",  fallback = { 0.00, 0.60, 0.00 }, level = 2 },
    { key = "bleed",   token = "Bleed",   colorKey = "Bleed",   atlas = "RaidFrame-Icon-DebuffBleed",   fallback = { 0.75, 0.15, 0.15 }, level = 1 },
}
local DISPEL_STYLE_PREFIX = "dispels_"

-- "Show All" scans every dispellable debuff regardless of who can dispel it;
-- "Dispellable By Me" delegates to Blizzard's own RAID_PLAYER_DISPELLABLE
-- filter token so "can THIS player dispel it" never requires reading the
-- (secret) dispel type ourselves either.
local function DispelFilterTokens(t)
    if t.dispelShowAll == false then
        return { "HARMFUL", "RAID_PLAYER_DISPELLABLE" }
    end
    return { "HARMFUL" }
end

-- Renders one dispel-type slot's visuals (health-bar overlay + optional
-- icon) from its style. Guarded on d.health because MakeInitializer's
-- noRegions branch runs style.applyExtra (this function, via
-- ApplyStyleToRegions) BEFORE the per-slot extraInit callback below has a
-- chance to stash the health-bar reference on d -- extraInit calls this
-- again immediately after setting it, so the guard just skips that one
-- premature first call rather than erroring.
-- "Full" mode's thick opaque border thickness, in pixels. Always alpha=1
-- regardless of the overlay opacity slider -- only the fill inside it is
-- adjustable -- so the dispel type stays clearly readable even at low
-- overlay opacity.
local DISPEL_FULL_BORDER_THICKNESS = 6

-- "Full" mode's fill caps out at 40% opacity even with the slider at 100%
-- (a full-button solid tint reads as overwhelming at true 100%, unlike
-- "fill"/"gradient" which only tint part of the health bar) -- the slider
-- still scales 0-100% linearly, just onto a 0%-40% effective range.
local DISPEL_FULL_MAX_OPACITY = 0.4

-- Fallbacks for the two gradient shape settings, used when a profile predates
-- them (dispelGradientWeakAlpha / dispelGradientHeight in Layout_Defaults.lua,
-- both surfaced as sliders in the Dispels settings panel).
--
-- The weak end stops at a PERCENTAGE of the opacity slider rather than at
-- true 0: fading fully out left most of the covered area barely visible even
-- with opacity maxed, with only a thin band at the strong edge ever reaching
-- the slider's actual alpha (bug fix 2026-07-30, user report: "barely
-- noticeable... set to 100 opacity"). 0 = true fade-out, 100 = flat tint with
-- no visible ramp at all.
local DISPEL_GRADIENT_WEAK_ALPHA_DEFAULT = 50
-- Percentage of the health bar's height the ramp spans, measured from the
-- strong (pinned) edge. 100 (the whole bar) as of 2026-09-11, user request --
-- a half-height ramp leaves the far end of the bar untinted, which reads as
-- the overlay being broken rather than as a deliberate fade.
local DISPEL_GRADIENT_HEIGHT_DEFAULT = 100

-- The health bar spans the FULL button height (UnitButton.xml anchors it
-- TOPLEFT *and* BOTTOMLEFT to the button), and the power bar is a short strip
-- anchored to the button's bottom at a HIGHER frame level, drawn on top of
-- health's lower edge. So anything anchored flush to health's bottom visually
-- covers the power bar -- confirmed by user report/screenshot 2026-08-12,
-- where a Magic dispel overlay swallowed the power bar entirely.
--
-- Returns how far up from health's bottom edge to stop. Reads the power bar
-- live rather than the profile's powerHeight so it stays correct when the bar
-- is hidden (inset 0 = use the whole bar).
local function HealthBottomInset(health)
    local parent = health and health.GetParent and health:GetParent()
    local power = parent and parent.powerBar
    if power and power.IsShown and power:IsShown() then
        return power:GetHeight() or 0
    end
    return 0
end

-- Same idea as HealthBottomInset, for the OTHER three edges: how far in from
-- health's top/left/right to stop so the Frame Border indicator stays visible.
--
-- The health bar spans the full button rect (see HealthBottomInset above) and
-- frameBorder draws its four textures flush to the button's own edges
-- (CreateBorderIndicator in BuiltIn_Update.lua anchors them at 0,0 and grows
-- inward by thickness). So a dispel overlay anchored flush to health simply
-- paints over the border -- user report 2026-08-13, "it is showing above the
-- border". Insetting by the border's thickness makes the overlay start where
-- the border ends.
--
-- Only frameBorder, deliberately: it's the always-on decorative chrome, so a
-- fixed inset reads as correct framing. aggroBorder/targetHighlight/
-- hoverHighlight are transient STATE borders -- insetting for those would make
-- the overlay visibly shrink and grow as you gain aggro or mouse over a frame.
-- They're also drawn above the overlay anyway, so they don't have this problem.
--
-- Read live off the button's own indicator frame rather than the profile, for
-- the same reason HealthBottomInset reads the power bar live: it stays correct
-- for the Designer preview button (which carries its own indicator set) and
-- when the indicator is disabled, with no second source of truth to keep in
-- sync. The border frame is a plain Frame, so IsShown() is readable on it --
-- unlike the AuraContainer slot buttons this styles.
local function FrameBorderInset(health)
    local parent = health and health.GetParent and health:GetParent()
    local border = parent and parent.indicators and parent.indicators.frameBorder
    if border and border.IsShown and border:IsShown() then
        local top = border._textures and border._textures.top
        if top and top.GetHeight then
            return top:GetHeight() or 0
        end
    end
    return 0
end

-- Exported for BuiltIn_Update.lua's Shield Overlay and Heal Absorb, which pin
-- themselves across the health bar exactly the way this overlay does and so
-- want exactly the same two insets. Exported rather than duplicated: both
-- functions encode a fact about the BUTTON's layout (health spans the full
-- rect, power bar and frame border are drawn on top of its edges), not
-- anything about dispels, and a second copy would be one more thing to keep in
-- step. Consumers resolve them off SquizzFrames.AuraEngineIndicators at call
-- time and fall back to a zero inset, since this whole file is inert pre-12.1.
AEI.HealthBottomInset = HealthBottomInset
AEI.FrameBorderInset = FrameBorderInset

-- Pin a REGION OR FRAME across the FILLED portion of the health bar, with both
-- insets applied. Shared by the custom "color" indicator (its live slot
-- overlay, its expiring-colour clip window, and its preview stand-in) and
-- structurally identical to the Dispels overlay's own "fill" mode -- see the
-- comment on that branch in ApplyDispelSlotStyle for why the border inset is
-- applied to the fill-tracking edge as well.
--
-- Everything it anchors therefore agrees on where the fill ends, which is the
-- point: the expiring wash is a fixed-size `|T` that can't track the fill
-- itself, so it relies on a clip window pinned by this same function.
--
-- Anchors are relative, so once set they follow the bar on their own; only the
-- numeric offsets can go stale, and neither depends on the bar's SIZE. That's
-- why this needs no OnSizeChanged hook, unlike dispels' gradient modes (which
-- derive an absolute height and so must re-measure on every resize).
local function AnchorHealthFillOverlay(tex, health)
    if not tex or not health then return end
    local bottomInset = HealthBottomInset(health)
    local bi = FrameBorderInset(health)
    local fillTex = health.GetStatusBarTexture and health:GetStatusBarTexture()
    tex:ClearAllPoints()
    tex:SetPoint("TOPLEFT", health, "TOPLEFT", bi, -bi)
    tex:SetPoint("BOTTOMRIGHT", fillTex or health, "BOTTOMRIGHT", -bi, bottomInset)
end
AEI.AnchorHealthFillOverlay = AnchorHealthFillOverlay

------------------------------------------------------------------------
-- Pulse and Animated Border (12.1.5, user request 2026-10-14)
--
-- Blizzard's raid frames got both in 12.1.5, but theirs are drawn by the
-- client off a secure attribute (dispel-indicator-overlay-animation /
-- dispel-indicator-animated-border) -- nothing in Lua draws them, so there is
-- nothing to borrow or reskin. These are our own, on the sanctioned route:
-- CustomAuraButton:AddAuraShownAnimation (Blizzard_CustomAuraButton.lua). The
-- engine Play()s a registered group when the slot's aura becomes visible and
-- Stop()s it when it goes, so it runs off the secret aura with no Lua reading
-- anything -- in combat included.
--
-- Three rules from AuraContainerUtil.InitializeInboundAnimationGroup shape
-- everything here:
--   * Registration is a button API call, so it happens in extraInit or never.
--     The animations therefore ALWAYS exist (on 12.1.5) and the settings only
--     switch their visible effect -- registering on demand would need a new
--     container, and containers are permanent.
--   * The group, its animations and their targets must all descend from the
--     slot button.
--   * Every animation TARGET gets secret Alpha/VertexColor/TexCoords aspects
--     and may no longer have them removed. So a target is never a region we
--     style afterwards: the pulse animates a bare host FRAME the overlay
--     textures live in (d.texHost), and the ants animate bare mover frames
--     whose dash textures -- recoloured on every restyle -- are their children.
------------------------------------------------------------------------
-- dash.tga is 2048 x 4 with the dashes drawn in (4 px on, 4 off: 256 periods;
-- .tools\make-dash.ps1). Each strip is 1024 units and shows a SLICE of it, so
-- the slice width sets the on-screen period: the whole image is 256 periods on
-- the strip (period 4, "Short"), half is 128 (8, "Medium"), a quarter 64 (16,
-- "Long"). The first version repeated a 16 px tile with REPEAT wrap and
-- rendered nothing in game (2026-10-14: strips shown, sized, coloured,
-- invisible) -- without the wrap, texcoords past 1 stretch the tile's
-- transparent last column -- so the image must cover the strip outright.
--
-- The strips slide SLIDE units and snap back. Seamless only if SLIDE is a
-- whole number of periods, so it is 16, a multiple of all three; and since the
-- slide is part of the registered animation it can never change, every dash
-- length must divide it. An edge longer than STRIP - SLIDE (1008) ends in a gap.
local DISPEL_ANTS_TEXTURE = [[Interface\AddOns\SquizzFrames\Media\Textures\dash.tga]]
local DISPEL_ANTS_IMAGE_PERIODS = 256 -- periods drawn in dash.tga
local DISPEL_ANTS_STRIP = 1024     -- each edge's dash strip, clipped to the edge
local DISPEL_ANTS_SLIDE = 16       -- slide per loop; a multiple of every period
local DISPEL_ANTS_MAX_THICKNESS = 8 -- the strips' fixed size; the dashes are sized inside
-- Defaults, and the choices the options offer. Period = one dash + one gap.
local DISPEL_ANTS_PERIODS = { short = 4, medium = 8, long = 16 }
local DISPEL_ANTS_DEFAULT_DASH = "medium"
local DISPEL_ANTS_DEFAULT_THICKNESS = 2
local DISPEL_ANTS_DEFAULT_SPEED = 16 -- UI units per second
local DISPEL_PULSE_MIN_ALPHA = 0.25
local DISPEL_PULSE_DURATION = 0.6  -- one way; BOUNCE makes a full pulse twice this

-- Build the pulse host and the ants on `owner` (a live slot button, or a
-- preview's plain host frame). `start(group)` hands each animation group over:
-- AddAuraShownAnimation on a live slot, Play() on a preview, which has no aura
-- to drive it. Returns false if `start` refused a group -- the frames still
-- exist then, and the overlay simply draws without animation.
local function BuildDispelAnimations(owner, d, start)
    if d.pulseHost then return true end

    -- Pulse: the overlay's textures are created in this frame (d.texHost,
    -- read by ApplyDispelSlotStyle) and the Alpha animation fades the frame.
    -- Off is a 1 -> 1 fade; SetDispelPulse only moves the far end.
    local pulseHost = CreateFrame("Frame", nil, owner)
    pulseHost:SetAllPoints(owner)
    d.pulseHost = pulseHost
    d.texHost = pulseHost
    local pulse = pulseHost:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(1)
    fade:SetDuration(DISPEL_PULSE_DURATION)
    fade:SetSmoothing("IN_OUT")
    d.pulseFade = fade

    -- Ants: one clip frame over the health bar (re-anchored by every restyle,
    -- it is not a target) holding four long strips, each sliding along its
    -- edge and snapping back, which reads as a continuous clockwise crawl.
    -- The strips (the animation TARGETS) are fixed here, at the maximum
    -- thickness; everything adjustable -- thickness, dash length, colour --
    -- lives on the dash texture inside each, which is not a target.
    --
    -- The clip is NEVER hidden: hiding a frame stops the animations under it
    -- and showing it again does not restart them, so a border switched on
    -- after the group was played sat frozen (the preview did exactly that).
    -- "Off" hides the dash textures instead; the strips keep sliding unseen.
    local clip = CreateFrame("Frame", nil, owner)
    clip:SetClipsChildren(true)
    clip:SetFrameLevel(pulseHost:GetFrameLevel() + 1)
    clip:SetAllPoints(owner)
    d.antsClip = clip
    d.antsEdges = {}
    d.antsSlides = {}
    local ants = clip:CreateAnimationGroup()
    ants:SetLooping("REPEAT")
    local S, TH, L = DISPEL_ANTS_SLIDE, DISPEL_ANTS_MAX_THICKNESS, DISPEL_ANTS_STRIP
    -- Each strip starts one slide back and slides forward. `side` is the edge
    -- of the strip the dashes hug, so a thin border sits on the frame's edge.
    local edges = {
        { point = "TOPLEFT",     x = -S, y = 0,  dx = S,  dy = 0,  side = "TOP" },                    -- crawls right
        { point = "TOPRIGHT",    x = 0,  y = S,  dx = 0,  dy = -S, side = "RIGHT", vertical = true }, -- crawls down
        { point = "BOTTOMRIGHT", x = S,  y = 0,  dx = -S, dy = 0,  side = "BOTTOM" },                 -- crawls left
        { point = "BOTTOMLEFT",  x = 0,  y = -S, dx = 0,  dy = S,  side = "LEFT", vertical = true },  -- crawls up
    }
    local ALONG = {
        TOP = { "TOPLEFT", "TOPRIGHT" }, BOTTOM = { "BOTTOMLEFT", "BOTTOMRIGHT" },
        LEFT = { "TOPLEFT", "BOTTOMLEFT" }, RIGHT = { "TOPRIGHT", "BOTTOMRIGHT" },
    }
    for _, e in ipairs(edges) do
        local mover = CreateFrame("Frame", nil, clip)
        if e.vertical then mover:SetSize(TH, L) else mover:SetSize(L, TH) end
        mover:SetPoint(e.point, clip, e.point, e.x, e.y)
        local tex = mover:CreateTexture(nil, "OVERLAY")
        tex:SetTexture(DISPEL_ANTS_TEXTURE)
        local along = ALONG[e.side]
        tex:SetPoint(along[1], mover, along[1])
        tex:SetPoint(along[2], mover, along[2])
        d.antsEdges[#d.antsEdges + 1] = { tex = tex, vertical = e.vertical }
        local slide = ants:CreateAnimation("Translation")
        slide:SetTarget(mover)
        slide:SetOffset(e.dx, e.dy)
        slide:SetDuration(S / DISPEL_ANTS_DEFAULT_SPEED)
        d.antsSlides[#d.antsSlides + 1] = slide
    end

    local ok = pcall(start, pulse) and pcall(start, ants)
    d.animsLive = ok
    return ok
end

-- A preview's `start` for BuildDispelAnimations: no aura drives a preview, so
-- play the group now and again whenever the preview is shown -- a preview is
-- often built while the options window is still closed, and a hidden frame's
-- animations stop rather than wait.
local function PreviewAnimationStart(owner)
    return function(group)
        group:Play()
        owner:HookScript("OnShow", function() group:Play() end)
    end
end

local function HideDispelAnts(d)
    if not d.antsEdges then return end
    for _, e in ipairs(d.antsEdges) do e.tex:Hide() end
end

-- How far an indicator's own pieces can sit above its wrapper: an aura row is
-- wrapper -> container -> icon -> cooldown -> border -> pandemic -> text
-- (AuraEngine.lua's initializer), six steps. Placing the ants only at the
-- wrapper's level left the icons' borders and stack text over them (user
-- screenshot 2026-10-14).
local INDICATOR_DEPTH = 7

-- The ants' frame level. `ref` is the Dispels wrapper, or for a caller with no
-- wrapper the button itself (+ LAYER.DISPEL). The tier is the Dispels
-- indicator's Border Frame Level (dispelAntsFrameLevel) when set, else its own
-- Frame Level -- separate because a user who has tuned their layers needs
-- Dispels itself left where it is (user request 2026-10-14). The ants then go
-- above the whole depth of every sibling indicator whose Frame Level is at or
-- BELOW that tier, and under everything set higher. Measured from the real
-- frames rather than computed from the tiers, because the preview's levels are
-- flattened by the options window raising itself.
local function AntsFrameLevel(ref, isWrapper)
    if not isWrapper then
        return (ref:GetFrameLevel() or 0) + F.LAYER.DISPEL
    end
    local tbl = ref._sfTable or {}
    local button = ref:GetParent()
    local own = tbl.dispelAntsFrameLevel or tbl.frameLevel
    local level = ref:GetFrameLevel() or 0
    if tbl.dispelAntsFrameLevel and button and button.GetFrameLevel then
        level = (button:GetFrameLevel() or 0) + tbl.dispelAntsFrameLevel
    end
    if own and button and button.indicators then
        for _, ind in pairs(button.indicators) do
            pcall(function()
                local it = ind ~= ref and ind._sfTable
                if it and it.frameLevel and it.frameLevel <= own then
                    level = math.max(level, ind:GetFrameLevel() + INDICATOR_DEPTH)
                end
            end)
        end
    end
    return level
end

-- Switch the pulse and ants to match the style. Out of combat only, like every
-- restyle. The fade and the slides are registered animations, and nothing in
-- Blizzard's rules forbids moving a fade's alpha or a slide's duration -- but
-- that is read from the source, not proven on a live frame, so both are
-- guarded: a refusal leaves that animation as it was rather than aborting the
-- rest of the restyle. Everything else here (clip, dash textures) is not a
-- target and is ours to change freely.
local function ApplyDispelAnimationStyle(d, style, health, bi, bottomInset)
    if d.pulseFade then
        pcall(d.pulseFade.SetToAlpha, d.pulseFade, style.pulse and DISPEL_PULSE_MIN_ALPHA or 1)
    end
    local clip = d.antsClip
    if not clip then return end
    -- Show/hide the dashes, never the clip -- see BuildDispelAnimations.
    if not style.ants then
        HideDispelAnts(d)
        return
    end
    -- Tier: the Dispels indicator's OWN (its Frame Level setting, default
    -- LAYER.DISPEL), not the slot's. The slot sits low on purpose -- the tint
    -- belongs under everything -- and that left the ants beneath the Shield
    -- Overlay and Heal Absorb, which span the whole bar: invisible on the
    -- preview, which fakes both, and on any shielded unit (2026-10-14, proven
    -- with /sfants top). d.levelRef is the indicator wrapper; a caller without
    -- one (the unit frames' preview) falls back to the button + DISPEL.
    -- Re-read every restyle, since the secure header re-levels buttons.
    local ref = d.levelRef or health:GetParent()
    if ref and ref.GetFrameLevel then
        clip:SetFrameStrata(ref:GetFrameStrata())
        clip:SetFrameLevel(AntsFrameLevel(ref, d.levelRef ~= nil))
    end
    -- "Full" draws an opaque border in the SAME colour exactly where the
    -- ants would run, which hid them completely; step inside it there.
    local inset = bi
    if style.mode == "full" then inset = bi + DISPEL_FULL_BORDER_THICKNESS end
    clip:ClearAllPoints()
    clip:SetPoint("TOPLEFT", health, "TOPLEFT", inset, -inset)
    clip:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", -inset, bottomInset + (inset - bi))

    -- Colour: the border's own when Custom Border Colour is on, else the
    -- dispel type's.
    local c = style.antsColor or style.color or { 1, 1, 1 }
    local a = c[4] or 1
    -- Dash length: the slice of dash.tga shown across the strip.
    local period = DISPEL_ANTS_PERIODS[style.antsDash or DISPEL_ANTS_DEFAULT_DASH]
        or DISPEL_ANTS_PERIODS[DISPEL_ANTS_DEFAULT_DASH]
    local span = (DISPEL_ANTS_STRIP / period) / DISPEL_ANTS_IMAGE_PERIODS
    local th = math.max(1, math.min(DISPEL_ANTS_MAX_THICKNESS,
        style.antsThickness or DISPEL_ANTS_DEFAULT_THICKNESS))
    for _, e in ipairs(d.antsEdges) do
        local tex = e.tex
        if e.vertical then
            tex:SetWidth(th)
            -- Run the image's length down the strip (UL, LL, UR, LR).
            tex:SetTexCoord(0, 0, span, 0, 0, 1, span, 1)
        else
            tex:SetHeight(th)
            tex:SetTexCoord(0, span, 0, 1)
        end
        tex:SetVertexColor(c[1], c[2], c[3], a)
        tex:Show()
    end
    -- Speed: one slide is DISPEL_ANTS_SLIDE units, so its duration sets it.
    local speed = math.max(1, style.antsSpeed or DISPEL_ANTS_DEFAULT_SPEED)
    for _, slide in ipairs(d.antsSlides) do
        pcall(slide.SetDuration, slide, DISPEL_ANTS_SLIDE / speed)
    end
end

local function ApplyDispelSlotStyle(button, d, style)
    if not d.health then return end
    local health = d.health
    -- Textures go in the pulse host when there is one (BuildDispelAnimations),
    -- so the pulse fades the whole overlay, full-mode border included.
    local host = d.texHost or button
    local bottomInset = HealthBottomInset(health)
    -- Top/left/right border inset, applied as anchor offsets below: +x moves
    -- right and +y moves up, so left is +bi, right is -bi, top is -bi.
    --
    -- Scoped to those three edges only (as requested). The BOTTOM edge keeps
    -- using bottomInset alone: with a power bar shown -- the default -- the
    -- overlay already stops well above the button's bottom border, so there's
    -- nothing to correct. With the power bar hidden (bottomInset == 0) the
    -- bottom border IS still overlapped; see the note where bottomInset is
    -- used, and widen it there if that turns out to matter.
    local bi = FrameBorderInset(health)

    if not d.overlay then
        d.overlay = host:CreateTexture(nil, "ARTWORK")
    end
    -- Gradient mode gets its OWN separate texture rather than sharing
    -- d.overlay with full/fill: once SetGradient has ever been called on a
    -- texture object, that texture seems to permanently stop respecting a
    -- plain SetAlpha/SetColorTexture alpha afterward (confirmed by
    -- debugging -- SetAlpha(0.4) followed immediately by GetAlpha()
    -- reported 1, even though the RGB channel came through correctly).
    -- Never calling SetGradient on d.overlay at all sidesteps that
    -- entirely, so full/fill's plain color+alpha via SetColorTexture stays
    -- reliable regardless of how many times gradient mode has run before.
    if not d.gradientOverlay then
        d.gradientOverlay = host:CreateTexture(nil, "ARTWORK")
        -- SetGradient only tints vertex colors on an EXISTING texture
        -- resource -- it doesn't assign one itself. Without this, a
        -- freshly created texture has no underlying resource for the first
        -- SetGradient call to tint, and renders as nothing at all.
        d.gradientOverlay:SetColorTexture(1, 1, 1, 1)
    end
    local tex = d.overlay
    local gradTex = d.gradientOverlay
    tex:ClearAllPoints()
    gradTex:ClearAllPoints()
    local mode = style.mode or "fill"
    local color = style.color or { 1, 1, 1 }
    local alpha = style.opacity or 1
    if mode == "none" then
        tex:Hide()
        gradTex:Hide()
    elseif mode == "full" then
        gradTex:Hide()
        -- Not SetAllPoints(health): stop short of the power bar, and of the
        -- Frame Border on the other three edges (see FrameBorderInset).
        tex:SetPoint("TOPLEFT", health, "TOPLEFT", bi, -bi)
        tex:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", -bi, bottomInset)
        tex:SetColorTexture(color[1], color[2], color[3], alpha * DISPEL_FULL_MAX_OPACITY)
        tex:Show()
    elseif mode == "gradient" or mode == "gradientTop" then
        tex:Hide()
        -- EXTENT: the STRONG edge is pinned flush to the health bar; the weak
        -- edge is the one the height slider moves. At 100% the ramp spans the
        -- whole bar; below that it shrinks toward the pinned edge, leaving the
        -- rest of the bar untinted.
        --
        -- Reading health's height is unavoidable here -- the frame API has no
        -- fractional anchor, so a percentage of a parent's height can only be
        -- expressed as an absolute number. If it isn't usable yet (styles can
        -- be applied before the bar has been laid out) fall back to anchoring
        -- the far edge too, i.e. full-bar coverage, rather than rendering a
        -- zero-height nothing. AE.RestyleSoon is re-fired on the health bar's
        -- OnSizeChanged (see CreateDispelsIndicator) so this re-measures
        -- whenever the frame is actually resized.
        -- Height percentage applies to the bar MINUS the power-bar strip, so
        -- 100% means "up to the power bar", not "over it".
        -- Border inset comes off the measured height too, not just the anchors
        -- -- otherwise a 100% ramp would still be a full-bar-height texture
        -- pushed down by the top inset, and would overhang the bottom.
        local barH = (health:GetHeight() or 0) - bottomInset - bi
        local h = barH > 0
            and (barH * ((style.gradientHeight or DISPEL_GRADIENT_HEIGHT_DEFAULT) / 100))
            or nil
        if mode == "gradientTop" then
            gradTex:SetPoint("TOPLEFT", health, "TOPLEFT", bi, -bi)
            gradTex:SetPoint("TOPRIGHT", health, "TOPRIGHT", -bi, -bi)
            if h then gradTex:SetHeight(h)
            else gradTex:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", -bi, bottomInset) end
        else
            gradTex:SetPoint("BOTTOMLEFT", health, "BOTTOMLEFT", bi, bottomInset)
            gradTex:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", -bi, bottomInset)
            if h then gradTex:SetHeight(h)
            else gradTex:SetPoint("TOPRIGHT", health, "TOPRIGHT", -bi, -bi) end
        end
        -- ALPHA: the opacity slider is the STRONG end; the weak end is a
        -- percentage OF that (rather than an independent absolute alpha) so
        -- the two can never invert and the opacity slider still reads as one
        -- overall intensity control. See DISPEL_GRADIENT_WEAK_ALPHA_DEFAULT.
        local minAlpha = alpha * ((style.gradientWeakAlpha or DISPEL_GRADIENT_WEAK_ALPHA_DEFAULT) / 100)
        -- "gradient" = strongest at the BOTTOM (the default look);
        -- "gradientTop" = the same ramp flipped, strongest at the TOP.
        local bottomAlpha, topAlpha = alpha, minAlpha
        if mode == "gradientTop" then
            bottomAlpha, topAlpha = minAlpha, alpha
        end
        -- SetGradient(orientation, minColor, maxColor): for "VERTICAL" this
        -- should put minColor at the bottom and maxColor at the top. UNTESTED
        -- against a real client -- if both modes render upside down (i.e.
        -- "Strong Bottom" is strong at the top), swap the two CreateColor
        -- lines below; that fixes both directions at once.
        gradTex:SetGradient("VERTICAL",
            CreateColor(color[1], color[2], color[3], bottomAlpha), -- bottom
            CreateColor(color[1], color[2], color[3], topAlpha))    -- top
        gradTex:Show()
    else -- "fill": only the currently-filled portion of the health bar, so it
        -- visually tracks current health like a tinted health-bar overlay.
        gradTex:Hide()
        local fillTex = health.GetStatusBarTexture and health:GetStatusBarTexture()
        tex:SetPoint("TOPLEFT", health, "TOPLEFT", bi, -bi)
        if fillTex then
            -- The status bar texture inherits health's full height, so it
            -- needs the same power-bar inset.
            --
            -- The border inset applies on this edge too, even though it tracks
            -- the FILL rather than the bar: at full health the fill's right
            -- edge is the bar's right edge, which is exactly where the border
            -- sits. The cost is that at partial health the tint stops ~bi short
            -- of the fill's leading edge -- a 1-2px sliver, versus this one
            -- mode visibly disagreeing with the other three about where the
            -- frame ends.
            tex:SetPoint("BOTTOMRIGHT", fillTex, "BOTTOMRIGHT", -bi, bottomInset)
        else
            tex:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", -bi, bottomInset)
        end
        tex:SetColorTexture(color[1], color[2], color[3], alpha)
        tex:Show()
    end

    -- "Full" mode gets a thick, always-opaque border around the health bar
    -- in the same per-type color as the fill, so the dispel type reads
    -- clearly even when the fill's own opacity is turned down low.
    if mode == "full" then
        if not d.border then
            d.border = {
                top = host:CreateTexture(nil, "OVERLAY"),
                bottom = host:CreateTexture(nil, "OVERLAY"),
                left = host:CreateTexture(nil, "OVERLAY"),
                right = host:CreateTexture(nil, "OVERLAY"),
            }
        end
        local b = d.border
        local t2 = DISPEL_FULL_BORDER_THICKNESS
        -- Same top/left/right border inset as the fill above -- this is the
        -- edge the user actually sees in "full" mode, since it's drawn opaque
        -- at full strength right where the Frame Border lives.
        b.top:ClearAllPoints()
        b.top:SetPoint("TOPLEFT", health, "TOPLEFT", bi, -bi)
        b.top:SetPoint("TOPRIGHT", health, "TOPRIGHT", -bi, -bi)
        b.top:SetHeight(t2)
        -- Same power-bar inset as the fill above, so the border frames the
        -- health bar rather than boxing in the power bar too.
        b.bottom:ClearAllPoints()
        b.bottom:SetPoint("BOTTOMLEFT", health, "BOTTOMLEFT", bi, bottomInset)
        b.bottom:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", -bi, bottomInset)
        b.bottom:SetHeight(t2)
        b.left:ClearAllPoints()
        b.left:SetPoint("TOPLEFT", health, "TOPLEFT", bi, -bi)
        b.left:SetPoint("BOTTOMLEFT", health, "BOTTOMLEFT", bi, bottomInset)
        b.left:SetWidth(t2)
        b.right:ClearAllPoints()
        b.right:SetPoint("TOPRIGHT", health, "TOPRIGHT", -bi, -bi)
        b.right:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", -bi, bottomInset)
        b.right:SetWidth(t2)
        for _, edge in pairs(b) do
            edge:SetColorTexture(color[1], color[2], color[3], 1)
            edge:Show()
        end
    elseif d.border then
        for _, edge in pairs(d.border) do edge:Hide() end
    end
    ApplyDispelAnimationStyle(d, style, health, bi, bottomInset)
    -- No icon here. The dispel-type symbols are their own indicator now
    -- (AEI.CreateDispelIconsIndicator) -- this slot draws the health-bar
    -- overlay and nothing else.
end

-- The border's own colour as {r, g, b, a}, or nil to use the type's.
local function AntsColorFromSetting(t)
    if t.dispelAntsCustomColor ~= true then return nil end
    local c = t.dispelAntsColor
    if c and c[1] == "custom_color" and #c >= 4 then
        return { c[2], c[3], c[4], c[5] or 1 }
    end
    return { 1, 1, 1, 1 }
end

local function BuildDispelStyleForType(t, def)
    local userColor = t.dispelColors and t.dispelColors[def.colorKey]
    local color = userColor or def.fallback
    local typeEnabled = not t.dispelTypesEnabled or t.dispelTypesEnabled[def.colorKey] ~= false
    return {
        noRegions = true,
        color = color,
        mode = typeEnabled and (t.dispelOverlay or "fill") or "none",
        opacity = (t.dispelOverlayOpacity or 40) / 100,
        -- Gradient-mode shape only; ignored by none/fill/full.
        gradientWeakAlpha = t.dispelGradientWeakAlpha or DISPEL_GRADIENT_WEAK_ALPHA_DEFAULT,
        gradientHeight = t.dispelGradientHeight or DISPEL_GRADIENT_HEIGHT_DEFAULT,
        -- 12.1.5 animations (BuildDispelAnimations). Independent of the
        -- overlay mode, so "None" plus the border gives Blizzard's ants alone.
        pulse = typeEnabled and t.dispelPulse == true,
        ants = typeEnabled and t.dispelAnts == true,
        -- Border look (ApplyDispelAnimationStyle). antsColor nil = the type's
        -- colour. dispelAntsColor is stored {"custom_color", r, g, b, a} like
        -- every other indicator colour.
        antsColor = AntsColorFromSetting(t),
        antsDash = t.dispelAntsDash,
        antsThickness = t.dispelAntsThickness,
        antsSpeed = t.dispelAntsSpeed,
        applyExtra = ApplyDispelSlotStyle,
    }
end

-- The dispel-type table itself, for a preview that has to draw the symbols
-- without an AuraContainer to get them from. Read-only by convention.
AEI.DISPEL_TYPES = DISPEL_TYPES

-- Preview-only: paint the dispel overlay for the first ENABLED type onto a
-- plain mock frame, with no AuraContainer and no real aura behind it.
--
-- Exported because the unit frames' 1:1 preview (UnitFrames/Preview.lua) needs
-- exactly what CreateDispelsIndicator's own isPreview branch does, on a mock
-- it owns rather than one this file builds. Sharing the real
-- ApplyDispelSlotStyle/BuildDispelStyleForType pair is the whole point: a
-- preview carrying its own copy of the painting rules starts lying the first
-- time the real one changes, and those rules already encode the power-bar and
-- border insets, the full-mode opacity cap and the SetGradient workaround.
--
-- WHICH type is showing is not a preview-able question -- it's secret at
-- runtime (see the IsShown-polling this replaced) -- so it always draws the
-- first enabled one, unconditionally. `ctx` is a table the CALLER keeps: the
-- textures are cached on it across calls, exactly as the live slot's are.
--
-- Returns the def it drew, or nil if it drew nothing.
function AEI.PreviewDispelOverlay(host, ctx, t)
    if not (host and ctx and t) then return nil end
    -- Before the first paint, so the textures are created inside the pulse
    -- host. No aura drives a preview, so the groups are simply played.
    if not ctx.pulseHost then
        BuildDispelAnimations(host, ctx, PreviewAnimationStart(host))
    end
    if t.enabled ~= false then
        for _, def in ipairs(DISPEL_TYPES) do
            local on = not t.dispelTypesEnabled or t.dispelTypesEnabled[def.colorKey] ~= false
            if on then
                ApplyDispelSlotStyle(host, ctx, BuildDispelStyleForType(t, def))
                return def
            end
        end
    end
    -- Disabled, or every type switched off.
    if ctx.overlay then ctx.overlay:Hide() end
    if ctx.gradientOverlay then ctx.gradientOverlay:Hide() end
    if ctx.border then
        for _, edge in pairs(ctx.border) do edge:Hide() end
    end
    HideDispelAnts(ctx)
    return nil
end

function AEI.CreateDispelsIndicator(button, t)
    if not button then return nil end
    local AE = SquizzFrames.AuraEngine
    if not AE then return nil end
    local health = button.healthBar or button

    -- AE.styles is ONE global table keyed by style name, so every dispel
    -- indicator built from the same keys shares one set of styles: the last
    -- one to rebuild wins, for all of them. That's correct for party/raid,
    -- where every button genuinely does share one settings table -- but the
    -- unit frames configure dispels PER FRAME, and without a namespace their
    -- overlay silently rendered the party list's mode and opacity instead of
    -- their own (user report 2026-09-10: "gradient selected but the live
    -- frame just tints with health", i.e. the party default "fill").
    -- `t._sfStyleNS` lets such a caller claim its own keys; absent (the party
    -- path) the keys are byte-identical to before.
    local ns = t._sfStyleNS or ""
    local function StyleKey(def) return DISPEL_STYLE_PREFIX .. ns .. def.key end

    -- No frame-level bump needed: health/power bar are children whose frame
    -- level DYNAMICALLY TRACKS the button's own level (confirmed by
    -- debugging -- raising the button's level shifted health/power's
    -- reported levels by the exact same amount), and the button's natural
    -- level already sits reliably above both for every party slot uniformly
    -- (not per-slot-varying as first suspected). So there's nothing to fix
    -- up front here -- extraInit below just reads button:GetFrameLevel()
    -- live, each time, right before placing the overlay one level below it.

    -- The wrapper is the generic settings-dispatch handle for Indicators.lua
    -- (Enabled/frameLevel -- driven entirely by the same generic code every
    -- other built-in uses). It never renders anything itself, and it has no
    -- meaningful position or size: the overlay always spans the health bar.
    -- Those settings used to exist here only to place the dispel-type symbol,
    -- which is now its own Dispel Icons indicator.
    local wrapper = CreateFrame("Frame", nil, button)
    wrapper._sfType = "builtin"
    local iw, ih = ExtractSize(t)
    wrapper:SetSize(iw, ih)

    -- Preview-only: AuraContainer slots are bound to a REAL unit via
    -- Blizzard's C-side engine, so a fake aura can't be injected the way
    -- BuiltIn_Update/Custom_Dispatch fake data for their own frames (same
    -- constraint Healer HoTs' fallback icon works around). The preview
    -- unit never carries a real dispellable debuff, so none of the 5 real
    -- per-type slots below would ever show there -- fallbackCtx reuses
    -- ApplyDispelSlotStyle itself (overlay + border + icon, whichever the
    -- current style calls for) unconditionally on a dedicated fallbackHost
    -- frame (plain, non-secret) instead of a real slotButton, so the
    -- Designer shows exactly what the live overlay/border/icon would look
    -- like. This is
    -- NOT "which type is active" -- that question is itself secret (see the
    -- removed IsShown-polling this replaced, which crashed with "attempt to
    -- perform boolean test on a secret boolean value") -- it just always
    -- shows the first enabled type, unconditionally.
    local IndicatorsModule = SquizzFrames.Indicators
    local isPreview = IndicatorsModule and IndicatorsModule.IsPreviewButton(button)
    local fallbackCtx
    local fallbackHost
    if isPreview then
        -- The Designer preview button is a hand-built mockup (see
        -- IndicatorsPanel.lua's BuildPreviewCanvas), NOT the real
        -- UnitButton.xml template -- it has no BACKGROUND/LOW/MEDIUM strata
        -- split at all; health bar, role icon, text etc are ALL at the
        -- default "MEDIUM" strata, ordered purely by frame level (health/
        -- power bar default to previewButton's level + 1; other indicators
        -- get previewButton's level + their own configured frameLevel,
        -- typically 5+). Forcing "LOW" strata here (the live-button fix)
        -- dropped the fallback into a tier that doesn't exist in that
        -- scheme, below the opaque health-bar mockup entirely -- invisible.
        -- A dedicated frame pinned to health's own level + 1 sits reliably
        -- above health/power bar and below every other indicator's own
        -- (higher) frameLevel on THIS preview's generous gap, without
        -- touching wrapper's own user-adjustable frameLevel (still used
        -- for the icon's position/level setting).
        fallbackHost = CreateFrame("Frame", nil, wrapper)
        fallbackHost:SetFrameLevel(health:GetFrameLevel() + 1)
        fallbackCtx = { health = health, levelRef = wrapper }
        BuildDispelAnimations(fallbackHost, fallbackCtx, PreviewAnimationStart(fallbackHost))
        wrapper._sfPreviewCtx = fallbackCtx   -- for /sfants
    end

    local function RefreshFallbackVisuals()
        if not fallbackCtx then return end
        for _, def in ipairs(DISPEL_TYPES) do
            local enabled = not t.dispelTypesEnabled or t.dispelTypesEnabled[def.colorKey] ~= false
            if enabled then
                local style = AE.styles[StyleKey(def)]
                if style then ApplyDispelSlotStyle(fallbackHost, fallbackCtx, style) end
                return
            end
        end
        -- No enabled type at all -- hide everything.
        if fallbackCtx.overlay then fallbackCtx.overlay:Hide() end
        if fallbackCtx.border then
            for _, edge in pairs(fallbackCtx.border) do edge:Hide() end
        end
        HideDispelAnts(fallbackCtx)
    end

    local function RebuildStyles()
        for _, def in ipairs(DISPEL_TYPES) do
            local key = StyleKey(def)
            AE.styles[key] = BuildDispelStyleForType(t, def)
            AE.RestyleSoon(key)
        end
        RefreshFallbackVisuals()
    end

    -- Push whatever currently governs the icon GROUP at the live container.
    -- Deliberately separate from RebuildStyles above, which only drives the
    -- per-type overlay SLOTS: the group is configured through the container
    -- API rather than through AE.styles, so a style rebuild alone leaves it
    -- stale. Declared here, above every setter that calls it, so it resolves
    -- as an upvalue rather than a nil global.
    -- Re-run the geometry without rebuilding the style tables: the style
    -- describes colors/mode/opacity, none of which change when the Frame
    -- Border does -- only the insets ApplyDispelSlotStyle measures at apply
    -- time (FrameBorderInset). Exposed on the wrapper because the preview's
    -- fallback host is driven by this closure, not by the engine's restyler,
    -- so an outside caller can't reach it through AE.RestyleSoon alone.
    function wrapper:RefreshBorderInset()
        for _, def in ipairs(DISPEL_TYPES) do
            AE.RestyleSoon(StyleKey(def))
        end
        RefreshFallbackVisuals()
    end

    -- The ants take their level from this wrapper and its siblings
    -- (AntsFrameLevel), but the generic Frame Level dispatch only moves the
    -- wrapper itself; re-place them after it. Next frame, because a rebuild
    -- levels the indicators one by one and the siblings may not be done yet.
    hooksecurefunc(wrapper, "SetFrameLevel", function()
        C_Timer.After(0, function() wrapper:RefreshBorderInset() end)
    end)

    function wrapper:SetDispelShowAll(val)
        t.dispelShowAll = val
        local container = wrapper._container
        if container then
            local filterStr = AE.Filter(unpack(DispelFilterTokens(t)))
            for _, def in ipairs(DISPEL_TYPES) do
                container:SetAuraSlotFilterString(def.key, filterStr)
            end
        end
    end

    function wrapper:SetDispelTypes(enabledMap)
        t.dispelTypesEnabled = enabledMap
        RebuildStyles()
    end

    function wrapper:SetDispelColors(colors)
        t.dispelColors = colors
        RebuildStyles()
    end

    function wrapper:SetDispelOverlay(mode)
        t.dispelOverlay = mode
        RebuildStyles()
    end

    function wrapper:SetDispelOverlayOpacity(opacity)
        t.dispelOverlayOpacity = opacity
        RebuildStyles()
    end

    function wrapper:SetDispelGradientWeakAlpha(v)
        t.dispelGradientWeakAlpha = v
        RebuildStyles()
    end

    function wrapper:SetDispelGradientHeight(v)
        t.dispelGradientHeight = v
        RebuildStyles()
    end

    function wrapper:SetDispelPulse(v)
        t.dispelPulse = v
        RebuildStyles()
    end

    function wrapper:SetDispelAnts(v)
        t.dispelAnts = v
        RebuildStyles()
    end

    -- The border's look: dispelAntsCustomColor / dispelAntsColor /
    -- dispelAntsDash / dispelAntsThickness / dispelAntsSpeed. All read into
    -- the style by BuildDispelStyleForType, so one setter covers them.
    function wrapper:SetDispelAntsOption(key, v)
        t[key] = v
        RebuildStyles()
    end

    -- Read at restyle by AntsFrameLevel; only the placement needs redoing.
    function wrapper:SetDispelAntsFrameLevel(v)
        t.dispelAntsFrameLevel = v
        wrapper:RefreshBorderInset()
    end

    -- NO "player" fallback: a unit-less button must not build a container bound
        -- to the player's own auras (see OnPartyButtonsWired). AE.RequestContainer
        -- asserts on a nil unit, so callers guard before reaching it.
        local unit = button.unit or button:GetAttribute("unit")
    if isPreview then
        -- The Designer preview button's unit is "player" -- a REAL, valid
        -- unit -- so other indicators can preview using the user's actual
        -- name/health/etc. But that means this AuraContainer would ALSO
        -- bind to REAL aura data, and if the player genuinely has an active
        -- dispellable debuff while testing, its real slot renders
        -- alongside (and visually conflicts with) RefreshFallbackVisuals'
        -- always-on mockup -- different type, different styling, same
        -- spot. A deliberately invalid unit token means no real aura data
        -- can ever match here, so only the fallback ever renders on preview.
        unit = "squizzframespreviewfake"
    end
    local slots = {}
    for _, def in ipairs(DISPEL_TYPES) do
        local styleKey = StyleKey(def)
        AE.styles[styleKey] = BuildDispelStyleForType(t, def)
        slots[#slots + 1] = {
            key = def.key,
            filter = DispelFilterTokens(t),
            candidateFilters = { includeDispelTypes = { [def.token] = true } },
            style = styleKey,
            extraInit = function(slotButton, d)
                d.health = health
                d.levelRef = wrapper   -- the ants' tier (ApplyDispelAnimationStyle)

                -- Frame STRATA, not frame level, is what actually guarantees
                -- this renders above the health bar and below the button's
                -- own content (nameText/roleIcon/etc): health/power bar are
                -- pinned to "LOW" strata specifically so indicators like
                -- this one can sit in "MEDIUM" -- strictly between that and
                -- the button's own "HIGH" strata -- with zero dependency on
                -- the button's actual frame level, which the secure group
                -- header reassigns unpredictably (see UnitButton.xml's
                -- comment on healthBar/powerBar). "MEDIUM" as of 2026-07-31
                -- (final): the button stays at "HIGH" strata to reliably
                -- beat nameplates (a frame-LEVEL-based alternative was tried
                -- and confirmed unreliable -- nameplates re-raise their own
                -- level constantly), so this whole 3-tier scheme stays
                -- shifted up one level from its pre-2026-07-30 values. The
                -- frame level here only staggers the 5 types relative to
                -- EACH OTHER within that shared strata.
                slotButton:SetFrameStrata("MEDIUM")
                slotButton:SetFrameLevel(1 + def.level)
                -- Pulse/ants, registered now or never (see
                -- BuildDispelAnimations). Before the style is applied, so the
                -- overlay's textures are created inside the pulse host.
                if slotButton.AddAuraShownAnimation then
                    BuildDispelAnimations(slotButton, d, function(group)
                        slotButton:AddAuraShownAnimation(group)
                    end)
                end
                ApplyDispelSlotStyle(slotButton, d, AE.styles[styleKey])
            end,
        }
    end

    AE.RequestContainer(wrapper, unit, {
        -- Overlay only. Every slot pins its own textures to `health` directly
        -- (see ApplyDispelSlotStyle), so the container's own rect is never
        -- drawn from -- the icons that used to need it now live in their own
        -- Dispel Icons indicator.
        point = { "CENTER", health, "CENTER" },
        slots = slots,
    }, function(container)
        wrapper._container = container
    end)

    -- The gradient modes' extent is an ABSOLUTE height derived from the health
    -- bar's own height (see ApplyDispelSlotStyle -- there's no fractional
    -- anchor to express it declaratively), so unlike every other mode it does
    -- NOT follow the bar when the bar is resized. Re-firing the restyle on
    -- OnSizeChanged re-measures it, whatever caused the resize (layout
    -- sliders, orientation flip, profile switch) -- cheaper and far more
    -- reliable than trying to find every code path that can resize a button.
    --
    -- Hooked on the health bar, NOT on any AuraContainer slot button (script
    -- handlers on those are forbidden -- CLAUDE.md section 7), and flagged so
    -- the repeated HandleIndicators rebuilds a single roster sync triggers
    -- don't stack duplicate hooks. RestyleSoon is already combat-safe (it
    -- just stops ticking until combat ends).
    if health and health.HookScript and not health._sfDispelGradientResizeHooked then
        health._sfDispelGradientResizeHooked = true
        health:HookScript("OnSizeChanged", function()
            for _, def in ipairs(DISPEL_TYPES) do
                AE.RestyleSoon(StyleKey(def))
            end
        end)
    end

    RefreshFallbackVisuals()

    return wrapper
end

------------------------------------------------------------------------
-- Dispel Icons -- its own indicator, separate from the Dispels overlay.
--
-- Split out on 2026-08-13 (user request). They were one indicator because the
-- icons rode along on the overlay's per-type slots, which is also why they
-- stacked; now that they're aura GROUPS they need their own position, size and
-- frame level, and the overlay -- which always covers the health bar and has
-- no geometry of its own -- was the wrong place to configure them from.
--
-- One group per dispel type, each capped at ONE frame. That cap is the dedupe:
-- three Magic debuffs produce a single Magic symbol. The container flows its
-- groups relative to each other (RebuildLayoutGroups sorts by layoutIndex) and
-- an empty group contributes nothing, so whichever types are actually up close
-- ranks with no gaps -- all decided C-side, which matters because the dispel
-- type of any given aura is secret. The group's own filter is what makes the
-- symbol knowable: a group filtered to exactly one dispel type can only ever
-- hold that type.
------------------------------------------------------------------------
local DISPEL_ICONS_STYLE_PREFIX = "dispelIcons_"

local function DispelIconsGroupKey(def) return "dispelIcons_" .. def.key end

-- Per-type filter. Absent map (or absent entry) means enabled: profiles
-- predating the setting showed every type, and the widget renders an absent
-- entry as ticked, so the two agree.
--
-- This is deliberately expressed as a FRAME CAP rather than a filter change:
-- the group's candidate filter is what makes its symbol knowable (a group
-- filtered to one dispel type can only ever hold that type), so it must not be
-- touched. A cap of 0 parks the group -- it stays declared, contributes
-- nothing to the flow, and can be raised again live. The key set stays fixed,
-- which matters because adding or removing a group key is structural and would
-- mean recreating the container.
local function DispelIconTypeEnabled(cfg, def)
    local map = cfg and cfg.dispelTypesEnabled
    if not map then return true end
    return map[def.colorKey] ~= false
end

-- Resolve one orientation token into everything the flow layout needs.
--
-- Three separate things, which is why the other indicators' one-line
-- `(token == "left-to-right") and "RIGHT" or "LEFT"` isn't enough here:
--   axis    -- row or column. Blizzard defaults to Horizontal, so a vertical
--              stack goes nowhere without setting it (see AE.FlowAxis).
--   growthH -- which way along a row; growthV, which way down a column.
--   corner  -- the CONTAINER's own anchor on the wrapper. The container
--              auto-sizes to its content, so this is the edge that stays put
--              as icons appear: anchor top-left and it always grows right and
--              down regardless of the growth directions above.
-- "horizontal"/"vertical" are accepted as aliases for the two default
-- directions, since the shared Orientation dropdown offers them.
local function ResolveOrientation(orientation, growth)
    if orientation == "vertical" then
        if growth == "down-to-up" then
            return "VERTICAL", "RIGHT", "UP", "BOTTOMLEFT"
        end
        return "VERTICAL", "RIGHT", "DOWN", "TOPLEFT"
    end
    if growth == "right-to-left" then
        return "HORIZONTAL", "LEFT", "DOWN", "TOPRIGHT"
    end
    return "HORIZONTAL", "RIGHT", "DOWN", "TOPLEFT"
end

-- Deliberately bare by default: these are Blizzard's dispel-type atlases,
-- already shaped artwork on transparency, so the usual icon furniture fights
-- them. Both are opt-in from the settings panel.
--   showSwipe  -- the Cooldown frame draws the radial sweep AND the dim fill
--                 behind it, which is what reads as a "background".
--   showBorder -- F.CreateBorder draws OUTSIDE the button rect, so on a symbol
--                 it looks like a box floating around the art.
local function BuildDispelIconsStyle(t, def)
    local w, h = ExtractSize(t)
    return {
        -- ALWAYS carries the atlas, even in spell-icon mode: whether the
        -- overlay region gets created at all is decided once, when the button
        -- is built, so a style that might ever show a symbol has to declare
        -- one up front. showIconAtlas is what actually switches the modes.
        iconAtlas = def.atlas,
        showIconAtlas = (t.useSpellIcons ~= true),
        width = w, height = h,
        hideSwipe = (t.showSwipe ~= true),
        border = (t.showIconBorder == true) and { 0, 0, 0, 1, size = 1 } or nil,
        -- No duration or stack text: this indicator exposes no font settings,
        -- so there would be no way to style or move them.
        showDuration = false,
        showStack = false,
    }
end

function AEI.CreateDispelIconsIndicator(button, t)
    if not button then return nil end
    local AE = SquizzFrames.AuraEngine
    if not AE then return nil end

    local wrapper = CreateFrame("Frame", nil, button)
    wrapper._sfType = "builtin"
    local w, h = ExtractSize(t)
    wrapper:SetSize(w, h)

    -- Own style keys for a caller that doesn't share the party list's
    -- settings -- see the identical note in CreateDispelsIndicator.
    local ns = t._sfStyleNS or ""
    local function StyleKey(def) return DISPEL_ICONS_STYLE_PREFIX .. ns .. def.key end

    -- Explicit tier for callers outside the party indicator system (the unit
    -- frames), which have no generic frameLevel dispatch to place the wrapper
    -- for them. Set BEFORE the container is requested: extraInit below reads
    -- the wrapper's strata/level when the engine creates its buttons, and
    -- 12.1 forbids re-tiering a managed button after that window.
    if t._sfStrata then wrapper:SetFrameStrata(t._sfStrata) end
    if t._sfLevel then wrapper:SetFrameLevel(t._sfLevel) end

    -- ALWAYS read settings through this, never the captured `t`.
    --
    -- The wrapper is created ONCE, against whichever indicator list was active
    -- at the time, and then reused -- built-ins are never torn down between
    -- rebuilds. Party and Raid are separate lists with separate tables, so on
    -- the Designer preview the closure's `t` goes stale the moment you switch
    -- tabs: it keeps describing the OTHER context. HandleIndicators re-points
    -- wrapper.configs at the current table on every rebuild, so that is the
    -- only reference that tracks the switch.
    --
    -- Symptom when this was read from `t` directly: dispel icon size updated
    -- on the group preview (fresh buttons, fresh closures) but not on the
    -- Designer preview, and only on the Raid tab -- Party happened to be the
    -- context the wrapper was born in (user report 2026-08-13).
    local function Cfg() return wrapper.configs or t end

    local IndicatorsModule = SquizzFrames.Indicators
    local isPreview = IndicatorsModule and IndicatorsModule.IsPreviewButton(button)

    -- Preview mock: the container is driven by the C-side engine against a real
    -- unit, so no fake aura can be injected. A static row of type symbols
    -- stands in, sized and laid out like the real groups.
    local previewIcons
    if isPreview then
        previewIcons = {}
        for i, def in ipairs(DISPEL_TYPES) do
            local f = CreateFrame("Frame", nil, wrapper)
            f.tex = f:CreateTexture(nil, "ARTWORK")
            f.tex:SetAllPoints()
            f.def = def
            previewIcons[i] = f
        end
    end

    -- Which artwork the mock icons wear. In spell-icon mode the real ones show
    -- whatever debuff happens to be up, which the preview can't know (no aura
    -- data reaches it), so a generic placeholder stands in -- same convention
    -- the Debuffs preview already uses. The point of the preview is placement
    -- and size, and a question mark still reads as "a spell icon goes here",
    -- which is the one thing that differs between the two modes.
    local function ApplyPreviewArt(f)
        if Cfg().useSpellIcons == true then
            f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            f.tex:SetTexture([[Interface\Icons\INV_Misc_QuestionMark]])
        else
            f.tex:SetTexCoord(0, 1, 0, 1)
            f.tex:SetAtlas(f.def.atlas)
        end
    end

    local function RefreshPreview()
        if not previewIcons then return end
        local iw, ih = ExtractSize(Cfg())
        local axis, growthH, growthV, corner = ResolveOrientation(Cfg().orientation, Cfg().growthDirection)
        local vertical = (axis == "VERTICAL")
        local shown = 0
        local prev
        for i, f in ipairs(previewIcons) do
            -- Only mock a couple: the point is to show placement and size, and
            -- five symbols at once is not a state anyone actually sees. A type
            -- that's been filtered off is skipped entirely, so switching one off
            -- visibly drops it out of the preview row.
            if shown < 2 and DispelIconTypeEnabled(Cfg(), DISPEL_TYPES[i]) then
                ApplyPreviewArt(f)
                f:ClearAllPoints()
                f:SetSize(iw, ih)
                if not prev then
                    f:SetPoint(corner, wrapper, corner, 0, 0)
                elseif vertical then
                    -- Stack along the column, in the configured direction.
                    if growthV == "UP" then
                        f:SetPoint("BOTTOMLEFT", prev, "TOPLEFT", 0, 1)
                    else
                        f:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -1)
                    end
                elseif growthH == "LEFT" then
                    f:SetPoint("TOPRIGHT", prev, "TOPLEFT", -1, 0)
                else
                    f:SetPoint("TOPLEFT", prev, "TOPRIGHT", 1, 0)
                end
                f:Show()
                prev = f
                shown = shown + 1
            else
                f:Hide()
            end
        end
    end

    local groups = {}
    for i, def in ipairs(DISPEL_TYPES) do
        local styleKey = StyleKey(def)
        AE.styles[styleKey] = BuildDispelIconsStyle(t, def)
        groups[#groups + 1] = {
            key = DispelIconsGroupKey(def),
            filter = DispelFilterTokens(t),
            candidateFilters = { includeDispelTypes = { [def.token] = true } },
            maxFrameCount = DispelIconTypeEnabled(t, def) and 1 or 0,
            style = styleKey,
            -- layoutIndex fixes left-to-right order so icons don't reshuffle as
            -- debuffs come and go; DISPEL_TYPES order is the overlay's own
            -- priority order.
            layout = { elementWidth = w, elementHeight = h,
                       elementSpacing = 1, groupSpacing = 1, layoutIndex = i },
            -- Strata/level set HERE because initializeFrame is the only window
            -- where touching an engine-managed button is legal. Taking the
            -- wrapper's tier keeps these above the health-bar overlay (pinned
            -- to "MEDIUM") AND above the other button content that shares the
            -- button's own strata -- aggroBorder, roleIcon and friends. Read
            -- once, at creation: re-tiering later would mean SetFrameLevel on a
            -- managed button outside this window, which 12.1 forbids.
            extraInit = function(iconButton)
                iconButton:SetFrameStrata(wrapper:GetFrameStrata() or "HIGH")
                iconButton:SetFrameLevel((wrapper:GetFrameLevel() or 0) + 1)
            end,
        }
    end

    local function RefreshGroups()
        local container = wrapper._container
        local iw, ih = ExtractSize(Cfg())
        local filterStr = AE.Filter(unpack(DispelFilterTokens(Cfg())))
        for i, def in ipairs(DISPEL_TYPES) do
            local styleKey = StyleKey(def)
            AE.styles[styleKey] = BuildDispelIconsStyle(Cfg(), def)
            AE.RestyleSoon(styleKey)
            if container then
                local key = DispelIconsGroupKey(def)
                pcall(container.SetAuraGroupFilterString, container, key, filterStr)
                -- Live mutator, and a cheap one: it only marks the container
                -- dirty, and the dirty flags coalesce into one pass on the next
                -- OnUpdate however many groups get pushed here.
                pcall(container.SetAuraGroupMaxFrameCount, container, key,
                    DispelIconTypeEnabled(Cfg(), def) and 1 or 0)
                pcall(container.SetAuraGroupLayout, container, key,
                    { elementWidth = iw, elementHeight = ih,
                      elementSpacing = 1, groupSpacing = 1, layoutIndex = i })
            end
        end
        RefreshPreview()
    end

    local nativeSetSize = wrapper.SetSize
    function wrapper:SetSize(width, height)
        nativeSetSize(self, width, height)
        RefreshGroups()
    end

    function wrapper:SetDispelShowAll(val)
        Cfg().dispelShowAll = val
        RefreshGroups()
    end

    function wrapper:SetDispelTypes(map)
        Cfg().dispelTypesEnabled = map
        RefreshGroups()
    end

    -- Symbol-per-dispel-type vs the actual debuff's own icon. A pure restyle
    -- (AE.RestyleSoon via RefreshGroups) rather than a container rebuild --
    -- see AE.MakeInitializer's d.iconAtlas note for why that's possible.
    function wrapper:SetUseSpellIcons(val)
        Cfg().useSpellIcons = val
        RefreshGroups()
    end

    function wrapper:SetShowSwipe(val)
        Cfg().showSwipe = val
        RefreshGroups()
    end

    function wrapper:SetShowBorder(val)
        Cfg().showIconBorder = val
        RefreshGroups()
    end

    -- Both halves arrive together from the coupled Orientation/Growth widget
    -- (see CreateSetting_GrowthOrientation) -- applying one without the other
    -- would briefly lay out along the new axis in the old axis's direction.
    function wrapper:SetGrowthOrientation(orientation, growth)
        Cfg().orientation = orientation
        Cfg().growthDirection = growth
        local axis, growthH, growthV, corner = ResolveOrientation(orientation, growth)
        local container = wrapper._container
        if container then
            local flowAxis = AE.FlowAxis and AE.FlowAxis(axis)
            if flowAxis and container.SetFlowLayoutAxis then
                pcall(container.SetFlowLayoutAxis, container, flowAxis)
            end
            -- Anchor point is the OPPOSITE edge to the growth direction, so
            -- content flows away from a fixed edge rather than off it.
            container:SetFlowLayoutAnchorPoint((growthH == "RIGHT") and "LEFT" or "RIGHT")
            container:SetFlowLayoutGrowthDirection(AE.FlowDir(growthH), AE.FlowDir(growthV))
            -- ...and re-pin the container itself: it auto-sizes to its content,
            -- so which corner is nailed down decides which way the block
            -- visually grows, independently of the flow's own direction.
            container:ClearAllPoints()
            container:SetPoint(corner, wrapper, corner, 0, 0)
        end
        RefreshPreview()
    end

    if isPreview then
        RefreshPreview()
    else
        -- NO "player" fallback: a unit-less button must not build a container bound
        -- to the player's own auras (see OnPartyButtonsWired). AE.RequestContainer
        -- asserts on a nil unit, so callers guard before reaching it.
        local unit = button.unit or button:GetAttribute("unit")
        local axis, growthH, growthV, corner = ResolveOrientation(Cfg().orientation, Cfg().growthDirection)
        AE.RequestContainer(wrapper, unit, {
            point = { corner, wrapper, corner },
            layout = {
                axis = axis,
                anchorPoint = (growthH == "RIGHT") and "LEFT" or "RIGHT",
                growthH = growthH,
                growthV = growthV,
            },
            groups = groups,
        }, function(container)
            wrapper._container = container
        end)
    end

    return wrapper
end

