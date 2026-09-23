--[[ SquizzFrames UnitFrames Preview

    A 1:1 mock of the frame currently being edited, drawn on the Unit Frames
    options page so a size or colour change can be judged without closing the
    panel and going to find a target.

    1:1 MEANS 1:1. No scaling, no "representative" proportions -- the mock is
    built at the exact configured width and height so what you see in the panel
    is the size you get on screen. That is the whole point; a preview at 80%
    would be worse than none, because you would trust it.

    RENDERS THROUGH THE REAL CODE. Text comes from UnitFrames.FormatToken and
    bar colour from UnitFrames.ResolveHealthColor -- the same functions the
    live frames use, exported for exactly this. A preview carrying its own copy
    of the formatting rules is a preview that starts lying the first time
    either side changes, and those rules encode a pile of hard-won
    secret-value handling that would be miserable to duplicate correctly.

    It renders the PLAYER regardless of which unit tab is selected: a target
    frame's preview has to show something, and your own character is the one
    unit guaranteed to exist and be readable. The same choice the Indicators
    preview makes (its mock button is hardcoded to "player" too).

    NOT SECURE, and never can be. The real frames are SecureUnitButtonTemplate
    because they take click-casting; this is a plain Frame that only has to
    look right. Nothing here should ever gain a "unit" attribute.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F

local Preview = {}
SquizzFrames.UnitFramePreview = Preview

local PLACEHOLDER_ICON = [[Interface\Icons\INV_Misc_QuestionMark]]

-- The mock health bar's fill, as a plain fraction. Named rather than inline
-- because the gradient preview evaluates the colour curve at exactly this
-- value, and the two must agree -- a bar drawn at 72% carrying the colour for
-- 100% would be a preview that lies.
local PREVIEW_HEALTH = 0.72

-- Build the mock once; Refresh re-dresses it. Rebuilding per settings change
-- would churn a dozen frames on every slider tick.
function Preview.Create(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(180, 46)

    local bg = p:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(p)
    bg:SetColorTexture(0, 0, 0, 0.6)
    p.bg = bg

    local health = CreateFrame("StatusBar", nil, p)
    health:SetPoint("TOPLEFT")
    health:SetPoint("TOPRIGHT")
    health:SetMinMaxValues(0, 1)
    health:SetValue(PREVIEW_HEALTH)
    p.healthBar = health

    -- Absorb overlays, pinned to the health bar the same way the real ones
    -- are. Driven by a fixed fraction rather than live values: the player's
    -- own absorb is almost always 0 while designing, and a bar that renders
    -- as nothing is indistinguishable from one that is broken.
    -- One level ABOVE the health bar, matching Absorbs.Create exactly. At the
    -- health bar's own level this happened to render correctly here while the
    -- real frame rendered underneath the fill -- same code, opposite result,
    -- because same-level parent-vs-child draw order is not defined. A preview
    -- that is right for a reason the real frame is wrong for is worse than no
    -- preview.
    local function MakeOverlay(fraction)
        local bar = CreateFrame("StatusBar", nil, health)
        bar:SetFrameLevel((health:GetFrameLevel() or 1) + 1)
        bar:SetAllPoints(health)
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(fraction)
        bar:Hide()
        return bar
    end
    p.shieldBar = MakeOverlay(0.3)
    p.healAbsorb = MakeOverlay(0.2)

    local power = CreateFrame("StatusBar", nil, p)
    power:SetPoint("BOTTOMLEFT")
    power:SetPoint("BOTTOMRIGHT")
    power:SetMinMaxValues(0, 1)
    power:SetValue(0.55)
    p.powerBar = power

    -- Text sits on its own host above the bars. Same reasoning as the
    -- Indicators mock: StatusBar children default to parent level + 1, so
    -- FontStrings owned directly by the frame would render UNDER the bars.
    local textHost = CreateFrame("Frame", nil, p)
    textHost:SetAllPoints(p)
    textHost:SetFrameLevel(p:GetFrameLevel() + 5)

    -- One FontString per text ELEMENT, keyed the same way the real frame's
    -- XML parentKeys are (nameText/healthText/...), so Refresh below can walk
    -- UF.TEXT_ELEMENTS and derive both sides of the pairing.
    -- The shared element list, NOT UnitFrames' export: this runs at panel
    -- build time, which can be before the module object is reachable, and
    -- reading a bare `UF` here resolved to a nil global and silently fell
    -- through to a hardcoded copy.
    for _, element in ipairs(SquizzFrames.UNITFRAME_TEXT_ELEMENTS
        or {"name", "health", "power", "level"}) do
        local fs = textHost:CreateFontString(nil, "OVERLAY")
        fs:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
        p[element .. "Text"] = fs
    end

    -- State icons. Always drawn at full strength when enabled, regardless of
    -- whether you are actually in combat or actually the leader -- the point
    -- of the preview is to place them, and one that only appears mid-pull
    -- cannot be positioned.
    local iconHost = CreateFrame("Frame", nil, p)
    iconHost:SetAllPoints(p)
    iconHost:SetFrameLevel(p:GetFrameLevel() + 7)
    p.icons = {}
    for _, key in ipairs({"combatIcon", "leaderIcon"}) do
        local tex = iconHost:CreateTexture(nil, "OVERLAY")
        tex:SetSize(16, 16)
        tex:Hide()
        p.icons[key] = tex
    end
    p.icons.combatIcon:SetTexture("Interface\\CharacterFrame\\UI-StateIcon")
    p.icons.combatIcon:SetTexCoord(0.5, 1.0, 0.0, 0.49)
    p.icons.leaderIcon:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")

    -- Portrait
    local portrait = CreateFrame("Frame", nil, p)
    portrait:SetFrameLevel(p:GetFrameLevel() + 6)
    local ptex = portrait:CreateTexture(nil, "ARTWORK")
    ptex:SetAllPoints(portrait)
    portrait.texture = ptex
    portrait:Hide()
    p.portrait = portrait

    -- Cast bar
    local cast = CreateFrame("StatusBar", nil, p)
    cast:SetMinMaxValues(0, 1)
    cast:SetValue(0.6)
    local castBg = cast:CreateTexture(nil, "BACKGROUND")
    castBg:SetAllPoints(cast)
    castBg:SetColorTexture(0, 0, 0, 0.6)
    local castIcon = cast:CreateTexture(nil, "OVERLAY", nil, 3)
    castIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    cast.icon = castIcon
    local castName = cast:CreateFontString(nil, "OVERLAY")
    castName:SetDrawLayer("OVERLAY", 4)
    castName:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    castName:SetJustifyH("LEFT")
    cast.spellName = castName
    local castTime = cast:CreateFontString(nil, "OVERLAY")
    castTime:SetDrawLayer("OVERLAY", 4)
    castTime:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    castTime:SetJustifyH("RIGHT")
    cast.timeText = castTime
    cast:Hide()
    p.castBar = cast

    -- Aura rows. Static mock icons, not AuraContainers: the engine renders
    -- C-side from a real unit's real auras and there is no way to feed it
    -- fake ones, which is the same limitation the Indicators preview hit and
    -- solved the same way. Each icon carries mock duration and stack text so
    -- those can be positioned here too -- see RefreshAuraRow.
    --
    -- Their own host, above the bars: the rows hang OUTSIDE the frame for most
    -- anchors, but "left"/"right" and a negative offset can put them over it,
    -- and text that disappears under the health bar while you are dragging it
    -- is worse than no preview.
    local auraHost = CreateFrame("Frame", nil, p)
    auraHost:SetAllPoints(p)
    auraHost:SetFrameLevel(p:GetFrameLevel() + 7)
    p.auraHost = auraHost
    p.auraIcons = { buffs = {}, debuffs = {} }

    -- Dispels. Same constraint as the aura rows -- no fake aura can reach an
    -- AuraContainer -- but the OVERLAY is painted by a plain function over the
    -- health bar, so the preview runs the real one (AEI.PreviewDispelOverlay)
    -- on this host instead of imitating it. `dispelCtx` is the per-slot cache
    -- that function keeps its textures on, exactly as a live slot button does.
    --
    -- Above the absorb overlays (health + 1) and below the text host (p + 5),
    -- which is the order the live frame draws them in.
    local dispelHost = CreateFrame("Frame", nil, p)
    dispelHost:SetAllPoints(p)
    dispelHost:SetFrameLevel((health:GetFrameLevel() or 1) + 2)
    p.dispelHost = dispelHost
    p.dispelCtx = { health = health }

    -- The type symbols are a separate indicator on the live frame, and static
    -- art here. Two of them: which types are up is secret at runtime and
    -- unknowable in a preview, and five at once is not a state anyone sees --
    -- the same call the party Designer's own dispel-icon mock makes.
    local dispelIconHost = CreateFrame("Frame", nil, p)
    dispelIconHost:SetAllPoints(p)
    dispelIconHost:SetFrameLevel(p:GetFrameLevel() + 8)
    p.dispelIcons = {}
    for i = 1, 2 do
        local tex = dispelIconHost:CreateTexture(nil, "OVERLAY")
        tex:Hide()
        p.dispelIcons[i] = tex
    end

    return p
end

local function BarTexture()
    local PartyFrames = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    return (PartyFrames and PartyFrames.GetBarTexture and PartyFrames.GetBarTexture())
        or [[Interface\TargetingFrame\UI-StatusBar]]
end

-- Lay out one aura row's placeholder icons, mirroring Auras.lua's anchor
-- vocabulary so the preview lands where the real row will.
local ANCHOR_POINTS = {
    topleft     = {"BOTTOMLEFT",  "TOPLEFT",     "RIGHT"},
    topright    = {"BOTTOMRIGHT", "TOPRIGHT",    "LEFT"},
    bottomleft  = {"TOPLEFT",     "BOTTOMLEFT",  "RIGHT"},
    bottomright = {"TOPRIGHT",    "BOTTOMRIGHT", "LEFT"},
    left        = {"RIGHT",       "LEFT",        "LEFT"},
    right       = {"LEFT",        "RIGHT",       "RIGHT"},
}

local function RefreshAuraRow(p, kind, cfg)
    local pool = p.auraIcons[kind]
    local anchor = cfg and cfg.anchor or "none"
    if anchor == "none" then
        for _, f in ipairs(pool) do f:Hide() end
        return
    end

    local a = ANCHOR_POINTS[anchor] or ANCHOR_POINTS.topleft
    local size = cfg.size or 20
    local growth = cfg.growth or "auto"
    if growth == "auto" then growth = a[3] end
    -- Capped at 8 on screen however many the row allows: the panel is not as
    -- wide as the game, and a preview that runs off the edge misinforms more
    -- than it shows.
    local shown = math.min(cfg.num or 8, 8)

    -- The duration and stack text are styled from the row's real style fields
    -- (user request 2026-09-11: "hard to visualise them when trying to adjust
    -- their positions"). Built through Auras.StyleFields rather than read from
    -- AE.styles, because a row that is disabled or has never been anchored has
    -- no registered style yet -- and the whole point is to see the setting you
    -- are editing right now, not the one that last went live.
    local AEI = SquizzFrames.AuraEngineIndicators
    local A = SquizzFrames.UnitFrameAuras
    local style = (A and A.StyleFields) and A.StyleFields(cfg) or nil

    for i = 1, shown do
        local f = pool[i]
        if not f then
            -- A frame per icon, not a bare texture: the text has to anchor to
            -- the icon itself (the engine anchors it to the button), and a
            -- texture is not an anchor target for a FontString's own point.
            f = CreateFrame("Frame", nil, p.auraHost or p)
            f.tex = f:CreateTexture(nil, "ARTWORK")
            f.tex:SetAllPoints()
            f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            f.tex:SetTexture(PLACEHOLDER_ICON)
            f.duration = f:CreateFontString(nil, "OVERLAY")
            f.stack = f:CreateFontString(nil, "OVERLAY")
            pool[i] = f
        end
        f:SetSize(size, size)
        f:ClearAllPoints()
        local step = (i - 1) * (size + 1)
        local dx, dy = 0, 0
        if growth == "LEFT" then dx = -step
        elseif growth == "UP" then dy = step
        elseif growth == "DOWN" then dy = -step
        else dx = step end
        f:SetPoint(a[1], p, a[2],
            (cfg.offsetX or 0) + dx, (cfg.offsetY or 0) + dy)

        if AEI and style then
            AEI.ApplyMockDurationText(f.duration, f, style, nil)
            AEI.ApplyMockStackText(f.stack, f, style, cfg.showStack)
        else
            f.duration:Hide()
            f.stack:Hide()
        end
        f:Show()
    end
    for i = shown + 1, #pool do pool[i]:Hide() end
end

-- Dispel overlay + type symbols. The overlay goes through the REAL painter
-- (see Create), translated by the REAL settings translation
-- (Dispels.BuildSettings) -- neither is reimplemented here, which matters
-- doubly for the opacity, whose scale differs between our config and the
-- party indicator's and has been got wrong once already.
local function RefreshDispels(p, t)
    local AEI = SquizzFrames.AuraEngineIndicators
    local DP = SquizzFrames.UnitFrameDispels
    local c = t.dispels

    if AEI and AEI.PreviewDispelOverlay and DP and DP.BuildSettings and p.dispelHost then
        -- "preview" as the unit: BuildSettings only uses it to name an
        -- AE.styles namespace, and nothing here ever registers a style.
        AEI.PreviewDispelOverlay(p.dispelHost, p.dispelCtx, DP.BuildSettings(t, "preview"))
    end

    local icons = p.dispelIcons
    if not icons then return end
    if not (c and c.enabled and c.showIcons and AEI and AEI.DISPEL_TYPES) then
        for _, tex in ipairs(icons) do tex:Hide() end
        return
    end

    -- Whichever types are enabled, in the same priority order the live groups
    -- flow in -- so switching one off visibly drops it out of the row.
    local size = c.iconSize or 16
    local shown = 0
    for _, def in ipairs(AEI.DISPEL_TYPES) do
        local on = not c.typesEnabled or c.typesEnabled[def.colorKey] ~= false
        if on and shown < #icons then
            shown = shown + 1
            local tex = icons[shown]
            tex:SetSize(size, size)
            tex:ClearAllPoints()
            -- Matches PlaceIcons + the live flow: the wrapper sits at the
            -- health bar's top-right corner and the row grows RIGHT from
            -- there, so the first symbol is the anchored one.
            tex:SetPoint("TOPRIGHT", p.healthBar, "TOPRIGHT",
                (c.iconX or 0) + (shown - 1) * (size + 1), c.iconY or 0)
            if c.useSpellIcons then
                tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                tex:SetTexture(PLACEHOLDER_ICON)
            else
                tex:SetTexCoord(0, 1, 0, 1)
                tex:SetAtlas(def.atlas)
            end
            tex:Show()
        end
    end
    for i = shown + 1, #icons do icons[i]:Hide() end
end

-- Re-dress the mock for a settings table. Called on every rebuild of the
-- options page, so it tracks edits as they are made.
function Preview.Refresh(p, t)
    if not p or not t then return end
    local UF = SquizzFrames.modules and SquizzFrames.modules["UnitFrames"]
    local unit = "player"

    local w = t.width or 180
    local h = t.height or 46
    local ph = t.powerHeight or 0
    local gap = (ph > 0) and (t.powerGap or 1) or 0
    p:SetSize(w, h)

    local tex = BarTexture()
    p.healthBar:SetStatusBarTexture(tex)
    p.healthBar:SetHeight(math.max(1, h - ph - gap))
    local bd = t.healthBackdropColor or {0, 0, 0, 0.6}
    p.bg:SetColorTexture(bd[1] or 0, bd[2] or 0, bd[3] or 0, bd[4] or 0.6)

    -- Border, on the same shared factory the real frame uses. Created lazily
    -- for the same load-order reason: BuiltIn_Update.lua loads after this file.
    local bcfg = t.border
    if not p.border then
        local BU = SquizzFrames.modules and SquizzFrames.modules["BuiltIn_Update"]
        if BU and BU.CreateBorderIndicator then
            p.border = BU.CreateBorderIndicator(p, "PreviewBorder")
            p.border:SetFrameLevel(p:GetFrameLevel() + 5)
        end
    end
    if p.border then
        if bcfg and bcfg.enabled then
            local pad = bcfg.padding or 0
            p.border:ClearAllPoints()
            p.border:SetPoint("TOPLEFT", p, "TOPLEFT", -pad, pad)
            p.border:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", pad, -pad)
            p.border:SetThickness(bcfg.thickness or 1)
            local bc = bcfg.color or {0, 0, 0, 1}
            p.border:SetColor(bc[1] or 0, bc[2] or 0, bc[3] or 0, bc[4] or 1)
            p.border:Show()
        else
            p.border:Hide()
        end
    end

    -- Health colour. The gradient is evaluated DIRECTLY here, which the real
    -- frame cannot do: Evaluate is AllowedWhenUntainted, so an addon may not
    -- hand it a secret -- but this mock's health is the hardcoded 0.72 below,
    -- which is a plain number. Same curve, same colours, so what you see here
    -- is what the bar does at 72%.
    local gr, gg, gb
    if F.EvaluateHealthGradient then
        gr, gg, gb = F.EvaluateHealthGradient(t.healthGradient, PREVIEW_HEALTH)
    end
    if gr then
        p.healthBar:SetStatusBarColor(gr, gg, gb, 1)
    elseif UF and UF.ResolveHealthColor then
        local r, g, b = UF.ResolveHealthColor(unit, t)
        p.healthBar:SetStatusBarColor(r, g, b, 1)
    end

    -- Absorb overlays. Fixed fractions, real colours -- see Create.
    local function DressOverlay(bar, cfg, defaultAlpha)
        if not bar then return end
        if not cfg or not cfg.enabled then bar:Hide() return end
        bar:SetStatusBarTexture(tex)
        bar:SetReverseFill(cfg.reverseFill == true)
        local c = cfg.color
        bar:SetStatusBarColor(c and c[1] or 1, c and c[2] or 1, c and c[3] or 1,
                              c and c[4] or defaultAlpha)
        bar:Show()
    end
    DressOverlay(p.shieldBar, t.shieldBar, 0.55)
    DressOverlay(p.healAbsorb, t.healAbsorb, 0.55)

    -- State icons
    for _, key in ipairs({"combatIcon", "leaderIcon"}) do
        local icon = p.icons and p.icons[key]
        local cfg = t[key]
        if icon then
            if not cfg or not cfg.enabled then
                icon:Hide()
            else
                local size = cfg.size or 16
                icon:SetSize(size, size)
                icon:ClearAllPoints()
                local anchor = cfg.anchor or "TOPRIGHT"
                icon:SetPoint(anchor, p, anchor, cfg.x or 0, cfg.y or 0)
                local c = cfg.color
                icon:SetVertexColor(c and c[1] or 1, c and c[2] or 1, c and c[3] or 1)
                icon:SetAlpha(c and c[4] or 1)
                icon:Show()
            end
        end
    end

    if ph > 0 then
        p.powerBar:SetStatusBarTexture(tex)
        p.powerBar:SetHeight(ph)
        local colors = F.GetPowerColor and F.GetPowerColor(unit)
        if colors then p.powerBar:SetStatusBarColor(colors.r, colors.g, colors.b, 0.8) end
        p.powerBar:Show()
    else
        p.powerBar:Hide()
    end

    -- Portrait
    local pcfg = t.portrait
    local inset = 0
    if pcfg and pcfg.enabled then
        local size = (pcfg.size and pcfg.size > 0) and pcfg.size or h
        p.portrait:SetSize(size, size)
        p.portrait:ClearAllPoints()
        local side = pcfg.side or "LEFT"
        local ox, oy = pcfg.offsetX or 0, pcfg.offsetY or 0
        if pcfg.inside then
            p.portrait:SetPoint(side, p, side, (side == "LEFT" and ox or -ox), oy)
            inset = size + 2
        else
            local opposite = (side == "LEFT") and "RIGHT" or "LEFT"
            p.portrait:SetPoint(opposite, p, side,
                (side == "LEFT" and -ox - 2 or ox + 2), oy)
        end
        -- Always the flat portrait here, whatever style is configured: a live
        -- PlayerModel inside a scrolling options panel is a lot of cost for a
        -- thumbnail, and on 12.1 it would not render for most units anyway.
        p.portrait.texture:SetTexCoord(0, 1, 0, 1)
        SetPortraitTexture(p.portrait.texture, unit)
        if (pcfg.shape or "square") == "square" then
            p.portrait.texture:SetTexCoord(0.15, 0.85, 0.15, 0.85)
        end
        p.portrait:Show()
    else
        p.portrait:Hide()
    end

    -- Text elements, through the real formatter AND the real anchor/justify/
    -- inset/colour helpers -- see UnitFrames.lua's export block for why none
    -- of this is reimplemented here.
    local fontFile = (F.ResolveFontFile and F.ResolveFontFile(t.font and t.font[1]))
        or "Fonts\\FRIZQT__.TTF"
    local outline = (t.font and t.font[3]) or "OUTLINE"
    local pside = (pcfg and pcfg.side) or "LEFT"
    for _, element in ipairs((UF and UF.TEXT_ELEMENTS) or {}) do
        local fs = p[element .. "Text"]
        local cfg = t.texts and t.texts[element]
        if fs then
            if not cfg or not cfg.enabled then
                fs:SetText("")
            else
                local anchor = cfg.anchor or "CENTER"
                fs:SetFont(fontFile, cfg.size or 12, outline)
                fs:SetJustifyH(UF.TextJustify(anchor))
                fs:ClearAllPoints()
                local x = (cfg.x or 0) + UF.TextInsetShift(anchor, inset, pside)
                fs:SetPoint(anchor, p.healthBar, anchor, x, cfg.y or 0)
                fs:SetText(UF.FormatToken(unit, cfg.format) or "")
                fs:SetTextColor(UF.TextColor(unit, t, cfg))
            end
        end
    end

    -- Highlights, on the same shared code the real frames use. Everything
    -- enabled draws at full strength here regardless of hover/target/threat
    -- state -- see Highlights.Preview for why.
    local HL = SquizzFrames.UnitFrameHighlights
    if HL then HL.Preview(p, t) end

    -- Cast bar
    local cb = t.castBar
    if cb and cb.enabled then
        local cw = (cb.widthMode == "custom" and cb.width and cb.width > 0) and cb.width or w
        local ch = cb.height or 16
        p.castBar:SetSize(cw, ch)
        p.castBar:ClearAllPoints()
        -- Attached and anchor modes both preview against the frame: the real
        -- anchor target is elsewhere on screen and cannot be represented here.
        if (cb.positionMode or "frame") == "frame" and (cb.anchor or "BOTTOM") == "TOP" then
            p.castBar:SetPoint("BOTTOM", p, "TOP", cb.offsetX or 0, (cb.offsetY or 0) + 2)
        else
            p.castBar:SetPoint("TOP", p, "BOTTOM", cb.offsetX or 0, (cb.offsetY or 0) - 2)
        end
        p.castBar:SetStatusBarTexture(tex)
        -- Through CastBar.ApplyColor, not a copy: the copy that stood here
        -- ignored "Class Color the Bar", so with it ticked the preview
        -- followed the Bar Color picker while the real bar stayed class
        -- coloured -- which reads as the live bar not updating (2026-09-23).
        local CBC = SquizzFrames.UnitFrameCastBar
        if CBC and CBC.ApplyColor then
            CBC.ApplyColor(p.castBar, cb, unit)
        else
            local c = cb.color or {0.9, 0.7, 0.1, 1}
            p.castBar:SetStatusBarColor(c[1], c[2], c[3], c[4] or 1)
        end

        local iconInset = 0
        if cb.showIcon then
            local isz = math.max(1, ch - 2)
            p.castBar.icon:SetSize(isz, isz)
            p.castBar.icon:ClearAllPoints()
            p.castBar.icon:SetPoint("LEFT", p.castBar, "LEFT", 1, 0)
            p.castBar.icon:SetTexture(PLACEHOLDER_ICON)
            p.castBar.icon:Show()
            iconInset = isz + 3
        else
            p.castBar.icon:Hide()
        end
        -- Through CastBar's own styler, not a second copy of the fallback
        -- chain -- see its comment. Note it takes the FACE, not the resolved
        -- file: it resolves internally.
        local CB = SquizzFrames.UnitFrameCastBar
        if CB and CB.ApplyTextStyle then
            local face = t.font and t.font[1]
            CB.ApplyTextStyle(p.castBar.spellName, cb.nameText, face, cb.fontSize or 11, outline)
            CB.ApplyTextStyle(p.castBar.timeText, cb.timeText, face, cb.fontSize or 11, outline)
        else
            p.castBar.spellName:SetFont(fontFile, cb.fontSize or 11, outline)
            p.castBar.timeText:SetFont(fontFile, cb.fontSize or 11, outline)
        end
        local nx = (cb.nameText and cb.nameText.x) or 0
        local ny = (cb.nameText and cb.nameText.y) or 0
        local tx = (cb.timeText and cb.timeText.x) or 0
        local ty = (cb.timeText and cb.timeText.y) or 0
        p.castBar.spellName:ClearAllPoints()
        p.castBar.spellName:SetPoint("LEFT", p.castBar, "LEFT", 3 + iconInset + nx, ny)
        p.castBar.timeText:ClearAllPoints()
        p.castBar.timeText:SetPoint("RIGHT", p.castBar, "RIGHT", -3 + tx, ty)
        p.castBar.spellName:SetText(cb.showName ~= false and "Cast Bar" or "")
        p.castBar.timeText:SetText(cb.showTime ~= false and "1.4" or "")
        if CB and CB.ApplyBorder then CB.ApplyBorder(p.castBar, cb.border) end
        p.castBar:Show()
    else
        p.castBar:Hide()
    end

    RefreshAuraRow(p, "buffs", t.buffs)
    RefreshAuraRow(p, "debuffs", t.debuffs)

    -- LAST, and deliberately: the overlay measures the health bar's height and
    -- reads whether the power bar is shown, both of which are decided above.
    RefreshDispels(p, t)
end
