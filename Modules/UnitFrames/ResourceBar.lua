--[[ SquizzFrames Resource Bar

    A standalone, movable bar for the PLAYER's resources:

      * the primary power bar (mana, rage, energy, fury, insanity, ...)
      * a row of points for the class's secondary resource, where it has one
        (Holy Power, Combo Points, Chi, Soul Shards, Arcane Charges, Essence,
        Runes)

    Deliberately independent of profile.unitFrames.enabled. It reads its
    settings out of that tree (they belong to the same options page), but
    wanting a Holy Power display is not the same as wanting a replacement
    player frame, and making one require the other would be a hidden
    dependency with no error message.

    -------------------------------------------------------------------
    TWO FRAMES, ONE OR TWO POSITIONS
    -------------------------------------------------------------------
    The power bar is SquizzFramesResourceBar and the point row is its own
    frame, SquizzFramesResourcePoints. Both are parented to UIParent.

      detachPoints = false  (the default, and how every profile started)
          One bar. The point row is placed INSIDE the bar's rect, above or
          below the power row per pointsAbove; the bar has one position, one
          width, one mover ("Resources"), and the backdrop and border wrap
          both rows together.

      detachPoints = true
          Two bars. Each has its own position (free / anchored to a frame /
          attached to the OTHER bar), the points have their own width, each
          gets its own mover, backdrop and border. Settings for the points
          live in cfg.pointsLayout.

    The two rows may not BOTH be attached to each other -- that is an anchor
    loop, which WoW rejects with "Cannot anchor to a region dependent on it".
    The options page never offers it, and ApplySettings breaks it anyway (the
    points fall back to free) in case a profile arrives that way.

    Turning detach on must not move anything on screen: ResourceBar.SeedDetach
    attaches the points to the power bar on the side they already occupy and
    shifts the power bar's own placement by exactly the amount its rect
    shrinks. See that function.

    -------------------------------------------------------------------
    THE POINT ROW, AND WHY IT IS BUILT OUT OF STATUS BARS
    -------------------------------------------------------------------
    A row of discrete points looks like it wants `for i = 1, max do
    pip:SetShown(current >= i) end`. That comparison is the exact thing that
    throws on 12.1: UnitPower can return a SECRET NUMBER, and comparing a
    secret is an error, not a wrong answer (see CLAUDE.md's "Secret Numbers").

    So each point is a StatusBar with its own one-unit range:

        pip:SetMinMaxValues(i - 1, i)
        pip:SetValue(current)

    i-1 and i are plain numbers; `current` is handed straight to SetValue,
    which clamps C-side without Lua ever reading it. A point whose index is
    below the current value clamps to full, one above it clamps to empty, and
    nothing is ever compared. It is the same "feed it raw, let C decide"
    discipline Absorbs.lua uses, applied to a different shape.

    The point COUNT still needs a real number, since it decides how many
    frames to lay out -- that one goes through F.IsValueNonSecret with a
    per-resource fallback, and keeps the previous count rather than collapsing
    to zero when it cannot be read.

    -------------------------------------------------------------------
    POINT STYLES
    -------------------------------------------------------------------
    Every style is still that StatusBar, so all of them stay secret-safe:

      bars      the plain look: the bar texture, the row's width shared out
      shape     the same fill cut to a shape by a MASK over both the fill and
                the empty background (Media/Shapes, drawn by
                .tools/make-shapes.ps1 -- round, star, heart, potion, ...)
      blizzard  the game's own art for this resource: the lit atlas is the
                fill, the unlit atlas is the background. A resource with no
                art, or an atlas that has gone missing, falls back to a round
                shape rather than drawing nothing.

    Shapes and art keep their proportions instead of stretching, so their row
    is as wide as its points; while attached to the power bar it is centred in
    the bar and shrunk to fit. pointFill "auto" fills bars left to right and
    shapes/art bottom to top, which is what reads as a bottle or orb filling.

    Rainbow colours are assigned by a point's POSITION in the row, never by
    the power value, so they are as secret-safe as any other colour. The
    animated one is a throttled OnUpdate that only recolours, and only while
    the row is visible.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end
local F = SquizzFrames.F

local ResourceBar = {}
SquizzFrames.ResourceBar = ResourceBar

-- Hard ceiling on pre-created point frames. Six covers every current
-- secondary resource (Runes and Essence are the widest at 6); Rogues can
-- reach 7 combo points with talents, so the cap sits a little above that.
local MAX_POINTS = 10

-- Fallback screen positions (raw pixels from UIParent centre) when nothing is
-- saved. The points default a little above the power bar's default so a
-- freshly detached-and-freed row is not dropped on top of it.
local DEFAULT_BAR_Y = -260
local DEFAULT_POINTS_Y = -236

-----------------------------------------------------------------------
-- Which secondary resource, for whom
-----------------------------------------------------------------------

-- There is no API that answers "what is this spec's secondary resource", so
-- this is a table. Class-wide entries first; the spec-gated ones below are
-- the classes where only SOME specs have the resource, and listing them by
-- class would put an always-empty row on the other two specs.
--
-- Both gates have to pass to draw anything: the class/spec has to be listed
-- here AND UnitPowerMax has to currently be above zero. The second gate is
-- what makes a Feral druid's combo points appear in cat form and vanish out
-- of it without this file knowing anything about shapeshifting.
local CLASS_RESOURCE = {
    PALADIN     = "HolyPower",
    ROGUE       = "ComboPoints",
    WARLOCK     = "SoulShards",
    DEATHKNIGHT = "Runes",
    EVOKER      = "Essence",
}

-- Keyed by specialization ID (F.GetPlayerSpecID).
local SPEC_RESOURCE = {
    [62]  = "ArcaneCharges",  -- Arcane Mage
    [269] = "Chi",            -- Windwalker Monk
    [103] = "ComboPoints",    -- Feral Druid
    [104] = "ComboPoints",    -- Guardian Druid
}

-- Fallback maximums, used only when UnitPowerMax comes back unreadable.
local RESOURCE_FALLBACK_MAX = {
    HolyPower = 5, ComboPoints = 5, SoulShards = 5, Chi = 5,
    ArcaneCharges = 4, Essence = 6, Runes = 6,
}

-- "Automatic" point colours. Chosen to match what each resource looks like in
-- the default UI rather than invented, so a Paladin's Holy Power reads as
-- Holy Power at a glance.
local RESOURCE_COLOR = {
    HolyPower     = {0.95, 0.90, 0.60},
    ComboPoints   = {0.90, 0.25, 0.20},
    SoulShards    = {0.58, 0.51, 0.79},
    Chi           = {0.40, 0.85, 0.75},
    ArcaneCharges = {0.35, 0.55, 0.95},
    Essence       = {0.30, 0.72, 0.78},
    Runes         = {0.35, 0.55, 0.85},
}

-- The player's class file. "player" is never identity-restricted to itself,
-- but this goes through the same guard as everywhere else rather than being
-- the one place that assumes -- the assumption is what would need revisiting
-- if Blizzard ever widened the restriction, and a guard costs nothing.
local function PlayerClass()
    local classFile = F and F.GetClassFile and F.GetClassFile("player")
    if classFile and F.IsValueNonSecret and F.IsValueNonSecret(classFile) then
        return classFile
    end
    return nil
end

-- Returns resourceName, powerTypeEnum, max -- or nil when this character has
-- no secondary resource to show right now.
function ResourceBar.ResolveSecondary()
    local specID = F and F.GetPlayerSpecID and F.GetPlayerSpecID() or 0
    local name = SPEC_RESOURCE[specID]
    if not name then
        local classFile = PlayerClass()
        name = classFile and CLASS_RESOURCE[classFile] or nil
    end
    if not name then return nil end

    local powerType = Enum and Enum.PowerType and Enum.PowerType[name]
    if powerType == nil then return nil end

    local max = UnitPowerMax("player", powerType)
    if not (F and F.IsValueNonSecret and F.IsValueNonSecret(max)) or type(max) ~= "number" then
        max = RESOURCE_FALLBACK_MAX[name] or 5
    end
    -- The live gate. A Feral druid out of cat form, or any spec that has lost
    -- its resource to a talent change, reports 0 here and gets no row.
    if max <= 0 then return nil end
    if max > MAX_POINTS then max = MAX_POINTS end
    return name, powerType, max
end

-----------------------------------------------------------------------
-- Point styles
-----------------------------------------------------------------------

-- Shape masks, drawn by .tools/make-shapes.ps1. Display order for the options
-- page, which reads this list. A new shape is one line here plus its image.
local SHAPE_DIR = "Interface\\AddOns\\SquizzFrames\\Media\\Shapes\\"
ResourceBar.SHAPES = {
    {value = "round",      text = "Round",       file = "circle"},
    {value = "diamond",    text = "Diamond",     file = "diamond"},
    {value = "hexagon",    text = "Hexagon",     file = "hexagon"},
    {value = "star",       text = "Star",        file = "star"},
    {value = "heart",      text = "Heart",       file = "heart"},
    {value = "shield",     text = "Shield",      file = "shield"},
    {value = "potion",     text = "Potion",      file = "potion"},
    {value = "bottle",     text = "Bottle",      file = "bottle"},
    {value = "nailpolish", text = "Nail Polish", file = "nailpolish"},
    -- The Holy Power runes, as our OWN silhouettes rather than Blizzard's art.
    -- Theirs is an already-coloured texture and SetStatusBarColor is a vertex
    -- tint, which multiplies -- so a class colour over their gold comes out as
    -- colour x gold rather than the colour (see ColorPoints). A white
    -- silhouette has nothing to multiply against, so it takes any colour
    -- exactly. Supplied art, not drawn by the generator: see .tools/art.
    --
    -- `cycle` marks a shape that is really a SET: point 1 draws holyrune1,
    -- point 2 holyrune2 and so on, wrapping past the last, which is how
    -- Blizzard's own bar reads (and exactly what BlizzardArt does for the
    -- atlas path). One entry rather than five, because five points wearing one
    -- repeated glyph is not a look anyone asked for.
    {value = "holyrune",   text = "Holy Power Runes", file = "holyrune", cycle = 5},
}
local SHAPE_FILE = {}
-- Each shape's border rings, missing only the thickness and extension:
-- "<file>-border<1-4>.png", from the same script. See StylePipBorder.
local SHAPE_BORDER = {}
-- [value] = how many variants a cycling set has. Only cycling shapes appear.
local SHAPE_CYCLE = {}
for _, s in ipairs(ResourceBar.SHAPES) do
    if s.cycle then
        -- A set registers its VARIANTS ("holyrune1".."holyrune5"), not its own
        -- value: the set name is never a file. Keying them this way also means
        -- a profile still holding a single variant from before the set existed
        -- keeps working, and simply draws that one glyph on every point.
        SHAPE_CYCLE[s.value] = s.cycle
        for n = 1, s.cycle do
            SHAPE_FILE[s.value .. n] = SHAPE_DIR .. s.file .. n .. ".png"
            SHAPE_BORDER[s.value .. n] = SHAPE_DIR .. s.file .. n .. "-border"
        end
    else
        SHAPE_FILE[s.value] = SHAPE_DIR .. s.file .. ".png"
        SHAPE_BORDER[s.value] = SHAPE_DIR .. s.file .. "-border"
    end
end

-- Which shape a given POINT wears. A cycling set steps through its variants in
-- order and wraps (Blizzard wraps the same way, see BlizzardArt); every other
-- shape ignores the index entirely, so all the existing callers are unchanged
-- in behaviour whether or not they pass one.
local function ShapeForIndex(shape, index)
    local n = SHAPE_CYCLE[shape]
    if not n then return shape end
    return shape .. (((index or 1) - 1) % n + 1)
end

-- Death Knight rune art is per spec. Blizzard's RuneFrame keys it by spec
-- index; spec IDs here, since that is what F.GetPlayerSpecID hands back.
local RUNE_SPEC = { [250] = "Blood", [251] = "Frost", [252] = "Unholy" }

local function AtlasExists(atlas)
    return atlas ~= nil and C_Texture ~= nil and C_Texture.GetAtlasInfo ~= nil
        and C_Texture.GetAtlasInfo(atlas) ~= nil
end

-- The game's own art for point `index`: the lit atlas (drawn as the fill), the
-- unlit one (the empty background), and whether that unlit art is really the
-- lit art dimmed. Names are from Blizzard_UnitFrame's class resource bars as of
-- 12.1.0; AtlasExists guards against renames.
local function BlizzardArt(resource, index)
    if resource == "HolyPower" then
        -- Five different rune designs, one per slot. The empty rune is the lit
        -- one dimmed: the plain "uf-holypower-rune%d" is a solid black glyph
        -- Blizzard's own bar never shows (PaladinPowerBarRune.useBackground is
        -- false -- the empty look there is the rune holder behind them), and
        -- on its own it read as a black blob (user screenshot 2026-09-14).
        local n = ((index - 1) % 5) + 1
        local lit = ("uf-holypower-rune%d-active"):format(n)
        return lit, lit, true
    elseif resource == "ComboPoints" then
        if PlayerClass() == "DRUID" then
            return "UF-DruidCP-Icon", "UF-DruidCP-BG-Active"
        end
        return "uf-roguecp-icon-red", "uf-roguecp-bg"
    elseif resource == "Chi" then
        return "uf-chi-icon", "uf-chi-bg"
    elseif resource == "ArcaneCharges" then
        return "UF-Arcane-Icon", "UF-Arcane-BG"
    elseif resource == "SoulShards" then
        return "UF-SoulShard-Icon", "UF-SoulShard-Holder"
    elseif resource == "Essence" then
        return "UF-Essence-Icon", "UF-Essence-BG"
    elseif resource == "Runes" then
        local specID = F and F.GetPlayerSpecID and F.GetPlayerSpecID() or 0
        return ("UF-DKRunes-%s-SkullActive"):format(RUNE_SPEC[specID] or "Blood"),
               "UF-DKRunes-SkullDis"
    end
    return nil, nil
end

-- The style actually drawn, and its shape. Blizzard art with no art to use
-- (no resource, or the atlas has gone missing) draws round shapes instead of
-- invisible points.
local function EffectiveStyle(cfg, resource)
    local style = cfg.pointStyle or "bars"
    if style == "blizzard" then
        if not (resource and AtlasExists((BlizzardArt(resource, 1)))) then
            return "shape", "round"
        end
        return "blizzard", nil
    elseif style == "shape" then
        local shape = cfg.pointShape
        -- A set's own value is not a file, so it has to be accepted on its
        -- presence in SHAPE_CYCLE or it would fall back to round.
        return "shape", (SHAPE_FILE[shape] or SHAPE_CYCLE[shape]) and shape or "round"
    end
    return "bars", nil
end
ResourceBar.EffectiveStyle = EffectiveStyle

-----------------------------------------------------------------------
-- Config
-----------------------------------------------------------------------

local function GetConfig()
    local prof = SquizzFrames.db and SquizzFrames.db.profile
    local uf = prof and prof.unitFrames
    return uf and uf.resourceBar
end
ResourceBar.GetConfig = GetConfig

-- The detached point row's own placement. `create` materialises the table
-- (the movers need somewhere to write); reads never do.
local function PointsLayout(cfg, create)
    if not cfg then return nil end
    if create and not cfg.pointsLayout then cfg.pointsLayout = {} end
    return cfg.pointsLayout or {}
end

-----------------------------------------------------------------------
-- Creation
-----------------------------------------------------------------------

-- Backdrop + border for one frame. Shared by the bar and the point row, which
-- each draw their own when detached.
local function AddFrameDecor(frame)
    -- Solid backdrop behind EVERYTHING, on the frame itself rather than on any
    -- of its children -- a BACKGROUND-layer texture on the parent renders
    -- below every child frame, which is exactly what is wanted.
    --
    -- This is what makes the point row countable. The points are separate
    -- frames with `pointSpacing` between them, so without a backdrop the gaps
    -- are TRANSPARENT and you are reading charges against whatever the game
    -- world happens to be showing through them (user report + screenshot). A
    -- solid fill turns each gap into a dark gutter, and the row reads as
    -- discrete pips instead of a smear.
    local backdrop = frame:CreateTexture(nil, "BACKGROUND")
    backdrop:SetColorTexture(0, 0, 0, 0.8)
    frame.backdrop = backdrop

    -- Reuses BuiltIn_Update.lua's CreateBorderIndicator, the same factory the
    -- pet buttons borrow rather than rolling their own -- it is exported for
    -- exactly this. Resolved at RUNTIME, not load time: that file loads after
    -- this one (see LoadModules.xml), and Create only ever runs from
    -- OnEnable, long after everything is in memory.
    local BU = SquizzFrames.modules and SquizzFrames.modules["BuiltIn_Update"]
    if BU and BU.CreateBorderIndicator then
        local border = BU.CreateBorderIndicator(frame, "Border")
        -- +4: above the bars and points (the point frames sit at +1/+2), below
        -- the text host at +5 so the power text still reads over it.
        border:SetFrameLevel(frame:GetFrameLevel() + 4)
        frame.border = border
    end
end

-- Parented to UIParent, never to a unit frame. Two reasons, both learned
-- elsewhere in this module: a child of a secure frame inherits its combat
-- protection, and a child of a frame that hides (no target, loading screen)
-- disappears with it -- which is how boss cast bars used to strand themselves
-- on screen. This bar's visibility is its own business.
function ResourceBar.Create()
    if ResourceBar.bar then return ResourceBar.bar end

    local bar = CreateFrame("Frame", "SquizzFramesResourceBar", UIParent)
    bar:SetSize(220, 16)
    bar:SetFrameStrata("MEDIUM")
    bar:Hide()

    local power = CreateFrame("StatusBar", nil, bar)
    power:SetMinMaxValues(0, 1)
    power:SetValue(0)
    bar.power = power

    local bg = power:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(power)
    bg:SetColorTexture(0, 0, 0, 0.6)
    bar.powerBg = bg

    -- Text host above the bar, for the same reason Preview.lua has one: a
    -- FontString owned by the bar frame would render UNDER the StatusBar
    -- child sitting on top of it.
    local textHost = CreateFrame("Frame", nil, bar)
    textHost:SetAllPoints(bar)
    textHost:SetFrameLevel(bar:GetFrameLevel() + 5)

    local text = textHost:CreateFontString(nil, "OVERLAY")
    text:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    bar.powerText = text

    -- The point row's own frame, parented to UIParent rather than to the bar
    -- so that, once detached, hiding the power bar (showPower off) does not
    -- take the points with it. One level above the bar, so while ATTACHED the
    -- bar's backdrop sits under the points and its border over them.
    local pointsFrame = CreateFrame("Frame", "SquizzFramesResourcePoints", UIParent)
    pointsFrame:SetSize(220, 8)
    pointsFrame:SetFrameStrata("MEDIUM")
    pointsFrame:SetFrameLevel(bar:GetFrameLevel() + 1)
    pointsFrame:Hide()
    bar.pointsFrame = pointsFrame
    ResourceBar.pointsFrame = pointsFrame

    -- Points are all created up front rather than on demand: a spec change
    -- can happen in combat, and creating frames then is the thing this
    -- codebase keeps arranging to avoid.
    bar.points = {}
    for i = 1, MAX_POINTS do
        local pip = CreateFrame("StatusBar", nil, pointsFrame)
        pip:SetMinMaxValues(i - 1, i)
        pip:SetValue(0)
        local pipBg = pip:CreateTexture(nil, "BACKGROUND")
        pipBg:SetAllPoints(pip)
        pipBg:SetColorTexture(0.22, 0.22, 0.22, 1)
        pip._sfBg = pipBg
        pip:Hide()
        bar.points[i] = pip
    end

    -- Decor LAST on the bar so its border draws above the power bar, and on
    -- the point row for when it is detached.
    AddFrameDecor(bar)
    AddFrameDecor(pointsFrame)

    ResourceBar.bar = bar
    return bar
end

-----------------------------------------------------------------------
-- Colours
-----------------------------------------------------------------------

local function ResolveColor(mode, custom, autoR, autoG, autoB)
    if mode == "class" then
        local c = F and F.GetClassColor and F.GetClassColor("player")
        if c then return c.r, c.g, c.b end
    elseif mode == "custom" and custom then
        return custom[1] or 1, custom[2] or 1, custom[3] or 1
    end
    return autoR or 1, autoG or 1, autoB or 1
end

-- Fully saturated hue (0-1, wrapping) to RGB.
local function HueToRGB(h)
    h = h % 1
    local i = math.floor(h * 6)
    local f = h * 6 - i
    if i == 0 then return 1, f, 0
    elseif i == 1 then return 1 - f, 1, 0
    elseif i == 2 then return 0, 1, f
    elseif i == 3 then return 0, 1 - f, 1
    elseif i == 4 then return f, 0, 1
    end
    return 1, 0, 1 - f
end

-- Colours every visible point: the fill by pointColorMode, the empty
-- background by pointEmptyColor (or left untinted for Blizzard art, whose
-- unlit atlas is its own empty look). Separate from Update because the
-- animated rainbow recolours without touching any values.
function ResourceBar.ColorPoints()
    local bar = ResourceBar.bar
    local cfg = GetConfig()
    if not bar or not cfg then return end
    local count = bar._sfPointCount or 0
    if count <= 0 then return end

    local style = bar._sfPointStyle or "bars"
    local mode = cfg.pointColorMode or "auto"
    local rainbow = (mode == "rainbow" or mode == "rainbowAnimated")

    local r, g, b = 1, 1, 1
    if not rainbow then
        if style == "blizzard" and mode == "auto" then
            -- "Automatic" on Blizzard art means the art's own colours.
            r, g, b = 1, 1, 1
        else
            local name = ResourceBar.ResolveSecondary()
            local auto = RESOURCE_COLOR[name] or {1, 1, 1}
            r, g, b = ResolveColor(mode, cfg.pointColor, auto[1], auto[2], auto[3])
        end
    end

    local offset = 0
    if mode == "rainbowAnimated" then
        offset = (GetTime() * (cfg.rainbowSpeed or 0.25)) % 1
    end

    local ec = cfg.pointEmptyColor or {0.22, 0.22, 0.22, 1}
    for i = 1, count do
        local pip = bar.points[i]
        if rainbow then
            -- Spread round the colour wheel by POSITION, so five points read
            -- red, yellow, green, blue, violet.
            r, g, b = HueToRGB((i - 1) / count + offset)
        end
        pip:SetStatusBarColor(r, g, b, 1)
        if style == "blizzard" then
            -- A dimmed-lit empty point (see BlizzardArt) is desaturated
            -- already; this darkens it so full and empty are unmistakable.
            if pip._sfBgDim then
                pip._sfBg:SetVertexColor(0.45, 0.45, 0.45, 0.9)
            else
                pip._sfBg:SetVertexColor(1, 1, 1, 1)
            end
        else
            pip._sfBg:SetColorTexture(ec[1] or 0.15, ec[2] or 0.15,
                                      ec[3] or 0.15, ec[4] or 0.8)
        end
    end
end

-- Drives the animated rainbow. Shown by ApplySettings only while that mode is
-- on and there are points; throttled to ~30 updates a second, and a no-op
-- while the row is not visible (loading screens, a hidden UI).
local rainbowDriver = CreateFrame("Frame")
rainbowDriver:Hide()
local rainbowElapsed = 0
rainbowDriver:SetScript("OnUpdate", function(_, elapsed)
    rainbowElapsed = rainbowElapsed + elapsed
    if rainbowElapsed < 0.03 then return end
    rainbowElapsed = 0
    local bar = ResourceBar.bar
    if bar and bar.pointsFrame and bar.pointsFrame:IsVisible() then
        ResourceBar.ColorPoints()
    end
end)

-----------------------------------------------------------------------
-- Layout helpers
-----------------------------------------------------------------------

-- Places `frame` from a position table (the bar's cfg, or cfg.pointsLayout).
--
--   mode "anchor"   rides a frame from CastBar.MATCH_TARGETS
--   mode "partner"  rides `partner` -- the other resource frame
--   anything else   free, at anchorX/anchorY
--
-- An anchor target that has not loaded yet flags the shared retry rather than
-- stranding the frame for the session -- ApplyLayout reads the flag right
-- after calling us -- and falls through to the free position meanwhile, so
-- the frame is at least somewhere findable.
local function PlaceFrame(frame, pos, mode, partner, scale, defaultY)
    frame:ClearAllPoints()
    local CB = SquizzFrames.UnitFrameCastBar

    local target
    if mode == "anchor" then
        target = CB and CB.ResolveTarget(pos.attachTo)
        if not (target and target.GetObjectType) then
            target = nil
            if CB then CB.anchorRetryWanted = true end
        elseif CB.DependsOn and CB.DependsOn(target, frame) then
            -- A Squizzumables group anchored to this very frame: attaching
            -- back would be a cycle, so stay free instead.
            target = nil
        end
    elseif mode == "partner" then
        target = partner
    end

    if target and CB and CB.AttachPoints then
        local pts = CB.AttachPoints(pos.attachSide or "BOTTOM")
        frame:SetPoint(pts[1], target, pts[2], pos.offsetX or 0, pos.offsetY or 0)
        return
    end

    frame:SetPoint("CENTER", UIParent, "CENTER",
        (pos.anchorX or 0) / scale, (pos.anchorY or defaultY) / scale)
end

-- WIDTH for the bar. "match" tracks another frame's width live -- the same
-- feature the cast bar has, sharing its implementation (CastBar.MatchedWidth)
-- rather than a second copy: the CDM viewers are load-on-demand, they resize
-- themselves as your tracked cooldowns change, and the resize hook must be
-- installed exactly once per frame. Three chances to get it subtly wrong
-- twice.
local function ResolveBarWidth(cfg)
    local CB = SquizzFrames.UnitFrameCastBar
    local w = cfg.width or 220
    if cfg.widthMode == "match" and CB and CB.MatchedWidth then
        w = CB.MatchedWidth(cfg.matchFrame) or w
    end
    return w
end

-- WIDTH for the detached point row: the bar's own width by default, or its
-- own custom / matched width. "points" (Fit to Points) has no width of its
-- own -- a shape/art row sizes itself to its points in ApplySettings -- so it
-- answers the bar's width, which is what a bar-style row falls back to.
local function ResolvePointsWidth(layout, barWidth)
    local mode = layout.widthMode or "power"
    if mode == "custom" then
        return layout.width or barWidth
    elseif mode == "match" then
        local CB = SquizzFrames.UnitFrameCastBar
        return (CB and CB.MatchedWidth and CB.MatchedWidth(layout.matchFrame)) or barWidth
    end
    return barWidth
end

-- Effective position modes, with the anchor loop broken. The bar can only
-- ride the points while detached, and if both are set to ride each other the
-- POINTS give way and go free.
local function EffectiveModes(cfg)
    local detached = cfg.detachPoints == true
    local barMode = cfg.positionMode or "free"
    if barMode == "points" and not detached then barMode = "free" end

    local pointsMode = (PointsLayout(cfg).positionMode) or "power"
    if barMode == "points" and pointsMode == "power" then pointsMode = "free" end
    return barMode, pointsMode
end
ResourceBar.EffectiveModes = EffectiveModes

local function ApplyBackdrop(frame, bgCfg)
    if not frame.backdrop then return end
    -- Defaults to ON (`~= false`, not `== true`): the transparent gaps it
    -- fixes are a defect rather than a style, so a profile that has never
    -- heard of this key should still get the readable version.
    if not bgCfg or bgCfg.enabled ~= false then
        local pad = (bgCfg and bgCfg.padding) or 0
        local c = (bgCfg and bgCfg.color) or {0, 0, 0, 0.8}
        frame.backdrop:ClearAllPoints()
        frame.backdrop:SetPoint("TOPLEFT", frame, "TOPLEFT", -pad, pad)
        frame.backdrop:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", pad, -pad)
        frame.backdrop:SetColorTexture(c[1] or 0, c[2] or 0, c[3] or 0, c[4] or 0.8)
        frame.backdrop:Show()
    else
        frame.backdrop:Hide()
    end
end

-- `padding` pushes the border outward from the frame's edge -- at 0 it sits on
-- the edge itself, drawing over the outermost pixel of the bars the way the
-- party frame border does.
--
-- `on` overrides b.enabled -- the detached point row passes its own switch.
local function ApplyBorder(frame, b, on)
    if not frame.border then return end
    if on == nil then on = b and b.enabled end
    if b and on then
        local pad = b.padding or 0
        frame.border:ClearAllPoints()
        frame.border:SetPoint("TOPLEFT", frame, "TOPLEFT", -pad, pad)
        frame.border:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", pad, -pad)
        frame.border:SetThickness(b.thickness or 1)
        local c = b.color or {0, 0, 0, 1}
        frame.border:SetColor(c[1] or 0, c[2] or 0, c[3] or 0, c[4] or 1)
        frame.border:Show()
    else
        frame.border:Hide()
    end
end

-- Detached, the point row's border has its own switch, border.pointsEnabled.
-- Unset, it follows the power bar's (border.enabled) -- which is what the one
-- switch meant before there were two, so a profile that had the border on
-- keeps it on both. Deliberately not in the defaults: a default would be
-- materialised into every profile and stop it following.
function ResourceBar.PointsBorderOn(b)
    if not b then return false end
    if b.pointsEnabled == nil then return b.enabled == true end
    return b.pointsEnabled == true
end

local function HideDecor(frame)
    if frame.backdrop then frame.backdrop:Hide() end
    if frame.border then frame.border:Hide() end
end

-- Size of one point, the distance from one point's left edge to the next, and
-- the width of the whole row.
--
-- Bars share `availWidth` out between them, so the row is exactly that wide
-- (the original look), whatever `mode` says. Shapes and art keep their
-- proportions -- square for shapes; for Blizzard art `aspect` is the widest
-- piece of art over the tallest, so every point's art fits its slot (see
-- ArtMetrics) -- and `mode` decides how they use the width:
--
--   "spread"    first point on the left edge, last on the right, evenly
--               spaced, so the row lines up with the power bar or matched
--               frame exactly as bars do
--   "pack"      side by side `spacing` apart, centred in `availWidth`
--   "packFree"  side by side, and the row is as wide as its points -- the
--               detached Fit to Points row, which sizes its frame to them
--
-- Either way a row that cannot fit `availWidth` at its Size shrinks to fit
-- (not "packFree", which has no width to fit). A single point is centred.
local function PointGeometry(style, count, height, spacing, availWidth, mode, aspect)
    if count <= 0 then return 0, 0, 0, 0 end
    if style == "bars" then
        local w = math.max(1, (availWidth - spacing * (count - 1)) / count)
        return w, height, w + spacing, availWidth
    end

    aspect = aspect or 1
    local h = height
    local w = h * aspect
    local total = count * w + spacing * (count - 1)
    if mode ~= "packFree" and total > availWidth then
        w = math.max(1, (availWidth - spacing * (count - 1)) / count)
        h = w / aspect
        total = count * w + spacing * (count - 1)
    end

    if mode == "spread" and count > 1 then
        return w, h, (availWidth - w) / (count - 1), availWidth
    end
    return w, h, w + spacing, total
end

-- Dresses one point for its style. The mask ALWAYS comes off first, so
-- switching styles never leaves a shape cut into a bar, and it is removed
-- rather than hidden: a hidden mask still clips on some builds (learned in
-- Squizzumables' Shapes.SetMask, where icons stayed round after switching the
-- option off).
--
-- `art` is this point's ArtMetrics entry and `scale` the row's, for Blizzard
-- art only: the point itself is already sized to its lit art, and the empty
-- art gets its OWN atlas size, centred, exactly as Blizzard's bars place it
-- (the sockets are bigger than the icon that sits in them).
local function StylePip(pip, style, shape, art, scale, barTexture, vertical, index)
    if pip._sfMask and pip._sfMaskOn then
        pip:GetStatusBarTexture():RemoveMaskTexture(pip._sfMask)
        pip._sfBg:RemoveMaskTexture(pip._sfMask)
        pip._sfMask:Hide()
        pip._sfMaskOn = false
    end

    local bg = pip._sfBg
    bg:ClearAllPoints()
    if style == "blizzard" and art then
        pip:SetStatusBarTexture(art.lit)
        bg:SetAtlas(art.unlit)
        bg:SetDesaturated(art.dim == true)
        bg:SetPoint("CENTER", pip, "CENTER", 0, 0)
        bg:SetSize(art.bgW * scale, art.bgH * scale)
        pip._sfBgDim = art.dim == true
    else
        pip:SetStatusBarTexture(barTexture)
        bg:SetDesaturated(false)
        bg:SetAllPoints(pip)
        -- Undo any atlas texcoords left behind by the Blizzard style; the
        -- empty colour itself is painted by ColorPoints.
        bg:SetTexCoord(0, 1, 0, 1)
        pip._sfBgDim = false
    end

    if style == "shape" then
        if not pip._sfMask then
            pip._sfMask = pip:CreateMaskTexture()
            pip._sfMask:SetAllPoints(pip)
        end
        local key = ShapeForIndex(shape, index)
        pip._sfMask:SetTexture(SHAPE_FILE[key] or SHAPE_FILE.round,
                               "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        pip._sfMask:Show()
        -- Added AFTER SetStatusBarTexture, to whichever texture object that
        -- left in place, so the removal above always finds it again.
        pip:GetStatusBarTexture():AddMaskTexture(pip._sfMask)
        pip._sfBg:AddMaskTexture(pip._sfMask)
        pip._sfMaskOn = true
    end

    -- Art stays upright however the bar fills.
    pip:SetOrientation(vertical and "VERTICAL" or "HORIZONTAL")
    pip:SetRotatesTexture(false)
end

-- The point border (cfg.pointBorder): an outline on each point, drawn just
-- INSIDE its edge on the OVERLAY layer, so it sits over the fill and the point
-- keeps its size and spacing.
--
--   bars   four edge textures, `thickness` pixels
--   shape  a ring image that follows the shape (make-shapes.ps1 draws four
--          thicknesses). It scales with the point, as the mask does, so its
--          thickness grows with Size.
--
-- Blizzard art has its own edges and never gets one. Both kinds are created on
-- first use and only hidden afterwards, so switching style leaves nothing
-- behind.
local function StylePipBorder(pip, style, shape, bc, index)
    local on = bc and bc.enabled and style ~= "blizzard"
    local c = (bc and bc.color) or {0, 0, 0, 1}
    local r, g, b, a = c[1] or 0, c[2] or 0, c[3] or 0, c[4] or 1
    local thick = math.max(1, math.min(4, math.floor((bc and bc.thickness) or 2)))

    if on and style == "shape" then
        if not pip._sfRing then
            pip._sfRing = pip:CreateTexture(nil, "OVERLAY")
            pip._sfRing:SetAllPoints(pip)
        end
        -- Resolved the SAME way as the mask, so a cycling set's ring always
        -- matches the glyph it is drawn around rather than a different one.
        local key = ShapeForIndex(shape, index)
        pip._sfRing:SetTexture((SHAPE_BORDER[key] or SHAPE_BORDER.round) .. thick .. ".png")
        pip._sfRing:SetVertexColor(r, g, b, a)
        pip._sfRing:Show()
    elseif pip._sfRing then
        pip._sfRing:Hide()
    end

    if on and style == "bars" then
        local e = pip._sfEdges
        if not e then
            e = {}
            e.top    = pip:CreateTexture(nil, "OVERLAY")
            e.bottom = pip:CreateTexture(nil, "OVERLAY")
            e.left   = pip:CreateTexture(nil, "OVERLAY")
            e.right  = pip:CreateTexture(nil, "OVERLAY")
            e.top:SetPoint("TOPLEFT");        e.top:SetPoint("TOPRIGHT")
            e.bottom:SetPoint("BOTTOMLEFT");  e.bottom:SetPoint("BOTTOMRIGHT")
            e.left:SetPoint("TOPLEFT");       e.left:SetPoint("BOTTOMLEFT")
            e.right:SetPoint("TOPRIGHT");     e.right:SetPoint("BOTTOMRIGHT")
            pip._sfEdges = e
        end
        e.top:SetHeight(thick)
        e.bottom:SetHeight(thick)
        e.left:SetWidth(thick)
        e.right:SetWidth(thick)
        for _, tex in pairs(e) do
            tex:SetColorTexture(r, g, b, a)
            tex:Show()
        end
    elseif pip._sfEdges then
        for _, tex in pairs(pip._sfEdges) do tex:Hide() end
    end
end

-- An atlas's own pixel size, or a square stand-in.
local function AtlasSize(atlas)
    local info = atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas)
    if info and info.width and info.height and info.width > 0 and info.height > 0 then
        return info.width, info.height
    end
    return 16, 16
end

-- Blizzard art for every point in the row, with each piece's atlas size, and
-- the largest width and height across all of it.
--
-- Blizzard's own bars size each texture to its atlas (useAtlasSize) and centre
-- it, and the art depends on that: the five holy power runes are five
-- different sizes, and a socket is bigger than the icon sitting in it. The
-- first version stretched everything to one box -- rune 1's proportions --
-- which squashed the other runes and left the empty art peeking out from
-- under the lit art as a dark edge (user screenshot 2026-09-14). So the row
-- gets ONE scale, from the tallest piece, and every texture keeps its own size
-- times that.
local function ArtMetrics(resource, count)
    local art, maxW, maxH = {}, 1, 1
    for i = 1, count do
        local lit, unlit, dim = BlizzardArt(resource, i)
        if not AtlasExists(lit) then
            lit, unlit, dim = BlizzardArt(resource, 1)
        end
        if not AtlasExists(unlit) then
            unlit, dim = lit, true
        end
        local litW, litH = AtlasSize(lit)
        local bgW, bgH = AtlasSize(unlit)
        art[i] = {lit = lit, unlit = unlit, dim = dim,
                  litW = litW, litH = litH, bgW = bgW, bgH = bgH}
        maxW = math.max(maxW, litW, bgW)
        maxH = math.max(maxH, litH, bgH)
    end
    return art, maxW, maxH
end

-- Lays out and dresses the points across `pointsFrame`, for however many the
-- current spec actually has. `mode` is PointGeometry's. Returns the row's
-- width, which a detached Fit to Points row sizes its frame to.
local function LayoutPoints(bar, cfg, count, availWidth, height, mode, barTexture)
    local pointsFrame = bar.pointsFrame
    local resource = (count > 0) and ResourceBar.ResolveSecondary() or nil
    local style, shape = EffectiveStyle(cfg, resource)
    bar._sfPointStyle = style

    if count <= 0 then
        for i = 1, MAX_POINTS do bar.points[i]:Hide() end
        return 0
    end

    local fill = cfg.pointFill or "auto"
    local vertical = (fill == "vertical") or (fill == "auto" and style ~= "bars")
    local spacing = cfg.pointSpacing or 2
    -- Blizzard art: every point gets a slot as wide as the widest art, and
    -- the art sits centred in it at the row's one scale.
    local art, aspect, artH
    if style == "blizzard" then
        local artW
        art, artW, artH = ArtMetrics(resource, count)
        aspect = artW / artH
    end

    local w, h, step, total = PointGeometry(style, count, height, spacing, availWidth, mode, aspect)
    local scale = art and (h / artH) or 1

    -- Centred in the width it was given (bars and a spread row fill it
    -- exactly, so this is 0 for them), and vertically in the row when fitting
    -- shrank the points.
    local x0 = (mode ~= "packFree") and math.max(0, (availWidth - total) / 2) or 0
    local y0 = -math.max(0, (height - h) / 2)

    for i = 1, MAX_POINTS do
        local pip = bar.points[i]
        if i <= count then
            pip:ClearAllPoints()
            if art then
                local a = art[i]
                pip:SetSize(a.litW * scale, a.litH * scale)
                pip:SetPoint("CENTER", pointsFrame, "TOPLEFT",
                             x0 + (i - 1) * step + w / 2, y0 - h / 2)
            else
                pip:SetSize(w, h)
                pip:SetPoint("TOPLEFT", pointsFrame, "TOPLEFT", x0 + (i - 1) * step, y0)
            end
            StylePip(pip, style, shape, art and art[i], scale, barTexture, vertical, i)
            StylePipBorder(pip, style, shape, cfg.pointBorder, i)
            pip:Show()
        else
            pip:Hide()
        end
    end
    return total
end

-----------------------------------------------------------------------
-- Settings
-----------------------------------------------------------------------

function ResourceBar.ApplySettings(cfg, barTexture)
    local bar = ResourceBar.bar
    if not bar then return end
    local pointsFrame = bar.pointsFrame

    -- Remembered for Refresh, which has no way to resolve it itself -- see
    -- that function's comment.
    if barTexture then ResourceBar.barTexture = barTexture end

    if not cfg or not cfg.enabled then
        bar:Hide()
        pointsFrame:Hide()
        rainbowDriver:Hide()
        if ResourceBar.onApplied then ResourceBar.onApplied() end
        return
    end

    local scale = cfg.scale or 1
    bar:SetScale(scale)
    pointsFrame:SetScale(scale)

    local detached = cfg.detachPoints == true
    local layout = PointsLayout(cfg)
    local w = ResolveBarWidth(cfg)

    local powerH = cfg.showPower == false and 0 or (cfg.powerHeight or 16)
    local pointH = cfg.showPoints == false and 0 or (cfg.pointHeight or 8)

    local _, _, max = ResourceBar.ResolveSecondary()
    bar._sfPointCount = (pointH > 0 and max) or 0
    local count = bar._sfPointCount

    local barMode, pointsMode = EffectiveModes(cfg)
    local power = bar.power
    power:ClearAllPoints()

    -- Fit to Points packs a shape/art row rather than spreading it across the
    -- width; bars have nothing to pack and ignore it (PointGeometry).
    local packPoints = layout.widthMode == "points"

    local pointsW, pointMode
    if not detached then
        -- ONE BAR: the point row lives inside the bar's rect, so its width is
        -- the bar's -- packed and centred in it, or spread across it.
        pointsW = w
        pointMode = packPoints and "pack" or "spread"
        local gap = (powerH > 0 and pointH > 0) and (cfg.gap or 2) or 0
        bar:SetSize(w, math.max(1, powerH + pointH + gap))
        PlaceFrame(bar, cfg, barMode, nil, scale, DEFAULT_BAR_Y)

        if powerH > 0 then
            -- pointsAbove decides which of the two rows owns the top edge.
            if cfg.pointsAbove and pointH > 0 then
                power:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
            else
                power:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
            end
        end

        pointsFrame:ClearAllPoints()
        pointsFrame:SetSize(w, math.max(1, pointH))
        if cfg.pointsAbove then
            pointsFrame:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
        else
            pointsFrame:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
        end

        -- Backdrop and border wrap the WHOLE bar, power row and point row
        -- together, rather than one box per row: two boxes with a gap between
        -- them is a different look, and the one people ask for is the outline.
        -- Set the row gap to 0 if you want the outline tight.
        ApplyBackdrop(bar, cfg.background)
        ApplyBorder(bar, cfg.border)
        HideDecor(pointsFrame)
    else
        -- TWO BARS, each placed on its own.
        pointsW = ResolvePointsWidth(layout, w)
        pointMode = packPoints and "packFree" or "spread"
        bar:SetSize(w, math.max(1, powerH))
        pointsFrame:SetSize(pointsW, math.max(1, pointH))

        PlaceFrame(bar, cfg, barMode == "points" and "partner" or barMode,
                   pointsFrame, scale, DEFAULT_BAR_Y)
        PlaceFrame(pointsFrame, layout, pointsMode == "power" and "partner" or pointsMode,
                   bar, scale, DEFAULT_POINTS_Y)

        if powerH > 0 then
            power:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
        end

        ApplyBackdrop(bar, cfg.background)
        ApplyBorder(bar, cfg.border)
        ApplyBackdrop(pointsFrame, cfg.background)
        ApplyBorder(pointsFrame, cfg.border, ResourceBar.PointsBorderOn(cfg.border))
    end

    -- Power bar
    if powerH > 0 then
        power:SetHeight(powerH)
        power:SetWidth(w)
        power:SetStatusBarTexture(barTexture)
        power:Show()
    else
        power:Hide()
    end

    -- Power text
    local text = bar.powerText
    local fontFile = (F and F.ResolveFontFile and F.ResolveFontFile(cfg.font and cfg.font[1]))
        or "Fonts\\FRIZQT__.TTF"
    text:SetFont(fontFile, cfg.fontSize or 12, (cfg.font and cfg.font[3]) or "OUTLINE")
    text:ClearAllPoints()
    if cfg.showPowerText ~= false and powerH > 0 then
        local anchor = cfg.textAnchor or "CENTER"
        text:SetPoint(anchor, power, anchor, cfg.textX or 0, cfg.textY or 0)
        local tc = cfg.textColor
        text:SetTextColor(tc and tc[1] or 1, tc and tc[2] or 1, tc and tc[3] or 1,
                          tc and tc[4] or 1)
        text:Show()
    else
        text:Hide()
    end

    -- Point row, across the width resolved above. Only a detached Fit to
    -- Points row of shapes or art has no width of its own, and sizes its
    -- frame to its points.
    local rowWidth = LayoutPoints(bar, cfg, count, pointsW, pointH, pointMode, barTexture)
    if pointMode == "packFree" and count > 0 and bar._sfPointStyle ~= "bars" then
        pointsFrame:SetWidth(math.max(1, rowWidth))
    end

    -- Visibility. Attached, the bar is the whole display and always shows;
    -- detached, a row with nothing to draw hides rather than leaving an empty
    -- box on screen.
    if detached then
        bar:SetShown(powerH > 0)
    else
        bar:Show()
    end
    pointsFrame:SetShown(count > 0)

    rainbowDriver:SetShown(count > 0 and cfg.pointColorMode == "rainbowAnimated")

    ResourceBar.Update()

    -- Cast bars can ride either of our frames, and both may just have been
    -- shown or hidden (spec swap, form change, a settings edit). Set by
    -- UnitFrames.lua; the cast bars are plain frames, so this is combat-safe.
    if ResourceBar.onApplied then ResourceBar.onApplied() end
end

-- Called by the options page as detach is switched ON, before the change is
-- applied, so that nothing moves on screen.
--
-- The points start attached to the power bar on the side they already occupy,
-- `gap` apart, at the same width -- visually identical to the single bar. The
-- bar's rect then shrinks to the power row alone, so the bar's own placement
-- is shifted by exactly how far that row's centre moves:
--
--   free, or anchored by a side/centre point  the rect's centre stays put,
--                                             so shift by the row's offset
--                                             from that centre
--   anchored by its TOP edge                  the top stays put
--   anchored by its BOTTOM edge               the bottom stays put
--
-- Re-seeds every time detach is turned on, deliberately: "starts where it is
-- now" is the promise, and an old detached layout could be anywhere.
function ResourceBar.SeedDetach(cfg)
    if not cfg then return end
    local layout = PointsLayout(cfg, true)
    local CB = SquizzFrames.UnitFrameCastBar

    -- A stale "ride the points" from an earlier detach would loop with the
    -- points riding the bar below.
    if cfg.positionMode == "points" then cfg.positionMode = "free" end

    local powerH = cfg.showPower == false and 0 or (cfg.powerHeight or 16)
    local pointH = cfg.showPoints == false and 0 or (cfg.pointHeight or 8)
    local gap = (powerH > 0 and pointH > 0) and (cfg.gap or 2) or 0

    -- Fit to Points means the same thing on both sides of the switch, so it
    -- survives; any other width starts as the bar's, which is what it was.
    if layout.widthMode ~= "points" then layout.widthMode = "power" end

    if powerH == 0 then
        -- Only the point row is on screen, so it IS the bar: hand it the
        -- bar's placement outright.
        layout.positionMode = (cfg.positionMode == "anchor") and "anchor" or "free"
        layout.attachTo = cfg.attachTo
        layout.attachSide = cfg.attachSide
        layout.offsetX = cfg.offsetX or 0
        layout.offsetY = cfg.offsetY or 0
        layout.anchorX = cfg.anchorX or 0
        layout.anchorY = cfg.anchorY or DEFAULT_BAR_Y
        return
    end

    layout.positionMode = "power"
    layout.attachSide = cfg.pointsAbove and "TOP" or "BOTTOM"
    layout.offsetX = 0
    layout.offsetY = cfg.pointsAbove and gap or -gap

    if pointH == 0 then return end

    local shrink = gap + pointH
    local rowOffset = cfg.pointsAbove and -shrink / 2 or shrink / 2
    local adjust = rowOffset
    if cfg.positionMode == "anchor" and CB and CB.AttachPoints then
        local ours = CB.AttachPoints(cfg.attachSide or "BOTTOM")[1]
        if ours:find("TOP") then
            adjust = rowOffset - shrink / 2
        elseif ours:find("BOTTOM") then
            adjust = rowOffset + shrink / 2
        end
        -- Anchor offsets are in the bar's own scaled space.
        cfg.offsetY = (cfg.offsetY or 0) + adjust
    else
        -- Free positions are raw UIParent pixels, divided by scale at apply.
        cfg.anchorY = (cfg.anchorY or DEFAULT_BAR_Y) + adjust * (cfg.scale or 1)
    end
end

-- Called by the options page when a row is switched to "free", so it starts
-- where it currently is instead of jumping to an old saved position.
--
-- GetCenter reports the frame's OWN scaled space, not UIParent's (see the
-- coordinate-space-mixing note): convert through the effective scales before
-- expressing it as UIParent pixels from centre.
function ResourceBar.SeedFreePosition(frame, pos)
    if not (frame and pos and frame:IsVisible()) then return end
    local cx, cy = frame:GetCenter()
    if not cx then return end
    local ratio = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    pos.anchorX = cx * ratio - UIParent:GetWidth() / 2
    pos.anchorY = cy * ratio - UIParent:GetHeight() / 2
end

-----------------------------------------------------------------------
-- Values
-----------------------------------------------------------------------

function ResourceBar.Update()
    local bar = ResourceBar.bar
    local cfg = GetConfig()
    if not bar or not cfg or not cfg.enabled then return end

    -- Primary power. Raw values straight into SetMinMaxValues/SetValue, never
    -- touched in Lua -- same rule as UnitFrames' own power bar.
    if cfg.showPower ~= false then
        local pType = UnitPowerType("player")
        bar.power:SetMinMaxValues(0, UnitPowerMax("player", pType) or 1)
        bar.power:SetValue(UnitPower("player", pType) or 0)

        local autoR, autoG, autoB = 0.2, 0.4, 0.8
        local pc = F and F.GetPowerColor and F.GetPowerColor("player")
        if pc then autoR, autoG, autoB = pc.r, pc.g, pc.b end
        bar.power:SetStatusBarColor(
            ResolveColor(cfg.powerColorMode or "auto", cfg.powerColor,
                         autoR, autoG, autoB))
    end

    -- Power text, rendered through UnitFrames' own FormatToken so the secret
    -- handling lives in exactly one place. It returns nil for "nothing to
    -- show", which is why the result cannot simply be compared against "".
    if cfg.showPowerText ~= false then
        local UF = SquizzFrames.modules and SquizzFrames.modules["UnitFrames"]
        local token = cfg.textFormat or "power"
        local str = UF and UF.FormatToken and UF.FormatToken("player", token)
        bar.powerText:SetText(str or "")
    end

    -- Point row -- see this file's header for why this is SetValue and not a
    -- comparison.
    local count = bar._sfPointCount or 0
    if count > 0 then
        local _, powerType = ResourceBar.ResolveSecondary()
        if powerType then
            local current = UnitPower("player", powerType)
            for i = 1, count do
                bar.points[i]:SetValue(current or 0)
            end
        end
        ResourceBar.ColorPoints()
    end
end

-- The point COUNT can change without any power event: a spec swap, a talent
-- that adds a combo point, shifting into cat form. Those all need the layout
-- redone, not just the values refreshed, so they route here rather than to
-- Update.
--
-- The bar texture is whatever ApplySettings was last handed, cached rather
-- than re-resolved. Both of the addon's GetBarTexture functions are
-- file-locals (PartyFrames.lua and UnitFrames.lua each have their own), so
-- reaching for one from here resolves to nil and quietly falls back to the
-- stock Blizzard texture -- meaning any spec change would drop the user's
-- chosen texture until the next options edit. ApplyLayout is the only caller
-- that knows the answer, so this remembers what it said.
function ResourceBar.Refresh()
    ResourceBar.ApplySettings(GetConfig(),
        ResourceBar.barTexture or "Interface\\TargetingFrame\\UI-StatusBar")
end

-----------------------------------------------------------------------
-- Movers
-----------------------------------------------------------------------

-- Same drag maths as CastBar.CreateMover: cursor position converted into
-- UIParent's coordinate space, saved as raw pixels from screen centre and
-- divided by scale at apply time. See CLAUDE.md's "Scale & Position" note and
-- the coordinate-space-mixing memory -- GetCenter and friends report a
-- frame's OWN scaled space, which is exact at scale 1.0 and drifts silently
-- everywhere else.
--
-- `getPos` returns the table the position is saved into (the bar's cfg, or
-- cfg.pointsLayout), resolved at drag time so a profile switch is honoured.
local function MakeMover(frame, globalName, getPos, defaultY)
    local mover = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate")
    mover:SetFrameStrata("DIALOG")
    mover:EnableMouse(true)
    mover:Hide()

    -- Kept as fields: SetEditMode recolours and relabels them, so an attached
    -- row's preview handle reads differently from a draggable one.
    local tex = mover:CreateTexture(nil, "BACKGROUND")
    tex:SetAllPoints(mover)
    tex:SetColorTexture(0.99, 0.6, 0.2, 0.3)
    mover._sfTex = tex

    local label = mover:CreateFontString(nil, "OVERLAY")
    label:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    label:SetPoint("CENTER")
    mover._sfLabel = label

    local dragging, dragX, dragY = false, 0, 0
    local StopDrag

    local function StartDrag(self)
        if dragging then return end
        dragging = true
        local pos = getPos()
        local startX = (pos and pos.anchorX) or 0
        local startY = (pos and pos.anchorY) or defaultY
        local uiScale = UIParent:GetEffectiveScale()
        local sx, sy = GetCursorPosition()
        sx, sy = sx / uiScale, sy / uiScale
        local sw, sh = GetScreenWidth(), GetScreenHeight()
        local offX = (sw / 2 + startX) - sx
        local offY = (sh / 2 + startY) - sy
        dragX, dragY = startX, startY

        self:SetScript("OnUpdate", function(f)
            if not IsMouseButtonDown("LeftButton") then StopDrag(f) return end
            local cx, cy = GetCursorPosition()
            local s = UIParent:GetEffectiveScale()
            cx, cy = cx / s, cy / s
            local sw2, sh2 = GetScreenWidth(), GetScreenHeight()
            dragX = (cx + offX) - sw2 / 2
            dragY = (cy + offY) - sh2 / 2
            local bs = frame:GetScale() or 1
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", UIParent, "CENTER", dragX / bs, dragY / bs)
            f:ClearAllPoints()
            f:SetPoint("CENTER", UIParent, "CENTER", dragX / bs, dragY / bs)
        end)
    end

    function StopDrag(self)
        if not dragging then return end
        dragging = false
        self:SetScript("OnUpdate", nil)
        local pos = getPos()
        if pos then
            pos.anchorX = dragX
            pos.anchorY = dragY
        end
        SquizzFrames:Fire("UnitFramesChanged")
    end

    mover:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then StartDrag(self) end
    end)
    mover:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then StopDrag(self) end
    end)
    mover:SetScript("OnHide", function(self) StopDrag(self) end)

    return mover
end

function ResourceBar.CreateMover()
    local bar = ResourceBar.bar
    if not bar then return nil end

    if not bar._sfMover then
        bar._sfMover = MakeMover(bar, "SquizzFramesResourceBarMover",
            function() return GetConfig() end, DEFAULT_BAR_Y)
    end

    local pointsFrame = bar.pointsFrame
    if pointsFrame and not pointsFrame._sfMover then
        pointsFrame._sfMover = MakeMover(pointsFrame, "SquizzFramesResourcePointsMover",
            function() return PointsLayout(GetConfig(), true) end, DEFAULT_POINTS_Y)
    end

    return bar._sfMover
end

-- A handle is shown for every visible row, and what changes is whether it can
-- be dragged:
--
--   free       draggable, orange
--   attached   preview only, grey, mouse DISABLED
--
-- Same arrangement as CastBar.SetEditMode, for the same reason: an attached
-- row has no position of its own to drag, and a handle that silently does
-- nothing is worse than a handle that looks inert. Mouse is disabled rather
-- than the scripts removed so clicks fall through to whatever mover is
-- underneath -- the frame it is attached TO, most obviously.
--
-- SetAllPoints tracks the row wherever it goes, including while the frame it
-- is attached to is itself being dragged in the same Edit Mode session.
local function ShowMover(mover, frame, draggable, text)
    mover:SetScale(frame:GetScale() or 1)
    mover:EnableMouse(draggable)
    mover:ClearAllPoints()
    mover:SetAllPoints(frame)
    if draggable then
        mover._sfTex:SetColorTexture(0.99, 0.6, 0.2, 0.3)
        mover._sfLabel:SetText(text)
    else
        mover._sfTex:SetColorTexture(0.45, 0.45, 0.5, 0.30)
        mover._sfLabel:SetText(text .. " (attached)")
    end
    mover:Show()
end

function ResourceBar.SetEditMode(enabled)
    local bar = ResourceBar.bar
    if not bar then return end
    ResourceBar.CreateMover()
    local barMover = bar._sfMover
    local pointsFrame = bar.pointsFrame
    local pointsMover = pointsFrame and pointsFrame._sfMover
    if not barMover then return end

    local cfg = GetConfig()
    if not (enabled and cfg and cfg.enabled) then
        barMover:Hide()
        if pointsMover then pointsMover:Hide() end
        return
    end

    local detached = cfg.detachPoints == true
    local barMode, pointsMode = EffectiveModes(cfg)

    if bar:IsShown() then
        ShowMover(barMover, bar, barMode == "free",
            detached and "Power Bar" or "Resources")
    else
        barMover:Hide()
    end

    if pointsMover then
        if detached and pointsFrame:IsShown() then
            ShowMover(pointsMover, pointsFrame, pointsMode == "free", "Resource Points")
        else
            pointsMover:Hide()
        end
    end
end

-----------------------------------------------------------------------
-- Events
-----------------------------------------------------------------------

-- A PRIVATE frame, not the UnitFrames module object. This bar is deliberately
-- usable with profile.unitFrames.enabled off (see the header), so it cannot
-- depend on that module's registrations -- and CallbackHandler keys by
-- (owner, event), so borrowing them would silently replace whichever
-- handler registered second. See CLAUDE.md's "Event/Message Owner Collisions".
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
eventFrame:RegisterUnitEvent("UNIT_MAXPOWER", "player")
eventFrame:RegisterUnitEvent("UNIT_DISPLAYPOWER", "player")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
-- Everything that can change WHICH resource is shown, or how many points it
-- has, goes to Refresh (a relayout) rather than Update (values only).
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
eventFrame:RegisterEvent("ACTIVE_COMBAT_CONFIG_CHANGED")
eventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")

-- Spec and talent changes get a DELAYED second pass on top of the immediate
-- one. Two different things go stale on these events and they settle at
-- different times: the point count (ours, readable straight away) and the
-- width of a matched Cooldown Manager row (Blizzard's, which relayouts on
-- these same events -- read it in the same frame and you get the width it is
-- about to stop having).
--
-- The immediate pass is kept rather than replaced by the delay, so the point
-- row is right instantly on a spec change and only the width settles late.
local RELAYOUT_LATE = {
    PLAYER_SPECIALIZATION_CHANGED = true,
    ACTIVE_PLAYER_SPECIALIZATION_CHANGED = true,
    PLAYER_TALENT_UPDATE = true,
    TRAIT_CONFIG_UPDATED = true,
    ACTIVE_COMBAT_CONFIG_CHANGED = true,
}

eventFrame:SetScript("OnEvent", function(_, event)
    if not ResourceBar.bar then return end
    if event == "UNIT_POWER_UPDATE" then
        ResourceBar.Update()
        return
    end
    -- UNIT_MAXPOWER and UNIT_DISPLAYPOWER change the bar's RANGE, and the
    -- rest can change the point count, so all of them relayout.
    ResourceBar.Refresh()
    if RELAYOUT_LATE[event] then
        C_Timer.After(0.3, function() ResourceBar.Refresh() end)
        C_Timer.After(1.0, function() ResourceBar.Refresh() end)
    end
end)
