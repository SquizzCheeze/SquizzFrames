--[[ SquizzFrames UnitFrames Auras (Phase 3)

    Buff and debuff rows for the standalone unit frames, built on the 12.1
    AuraEngine rather than on a manual aura scan.

    WHY AuraEngine AND NOT A SCAN: on 12.1 aura data is fully secret while
    auras are secret (combat/encounters). A manual C_UnitAuras scan does not
    get flaky then -- it permanently stops seeing anything applied after combat
    started, for the rest of the fight. Blizzard's managed AuraContainer is the
    only sanctioned route, and AuraEngine.lua already wraps it. See CLAUDE.md
    section 7 before touching anything here.

    EASIER HERE THAN ON THE PARTY FRAMES. The nastiest bug in the party aura
    code is that a container binds its unit at creation while the secure header
    silently reassigns button tokens on every re-sort, so a frame ends up
    showing another player's auras. These frames have FIXED tokens for the
    session -- "target" is always "target" -- so that whole class cannot occur
    and there is no rebinding machinery here at all.

    POSITIONING follows EllesmereUIUnitFrames' vocabulary, which is a good fit
    and worth being compatible with in feel: a named anchor
    (topleft/topright/bottomleft/bottomright/left/right, or none to disable)
    places the row against a corner or side of the frame, anchored by its
    OPPOSITE point so icons flow away from the frame rather than over it.
    Growth follows from the anchor unless overridden.

    STYLE KEYS ARE PER UNIT AND PER KIND. AuraEngine styles live in one global
    table keyed by string, and a style carries the icon size. The party
    indicators can share one key per indicator type because every button reads
    the same settings; here each frame sizes its own auras, so a shared key
    would make the last frame laid out win for everybody.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local Auras = {}
SquizzFrames.UnitFrameAuras = Auras

-- Anchor vocabulary, matching EllesmereUI's so the two read alike.
-- [anchor] = { ourPoint, theirPoint, defaultGrowth }
local ANCHOR_POINTS = {
    topleft     = {"BOTTOMLEFT",  "TOPLEFT",     "RIGHT"},
    topright    = {"BOTTOMRIGHT", "TOPRIGHT",    "LEFT"},
    bottomleft  = {"TOPLEFT",     "BOTTOMLEFT",  "RIGHT"},
    bottomright = {"TOPRIGHT",    "BOTTOMRIGHT", "LEFT"},
    left        = {"RIGHT",       "LEFT",        "LEFT"},
    right       = {"LEFT",        "RIGHT",       "RIGHT"},
}

Auras.ANCHOR_ITEMS = {
    {value = "none",        text = "Off"},
    {value = "topleft",     text = "Above, left"},
    {value = "topright",    text = "Above, right"},
    {value = "bottomleft",  text = "Below, left"},
    {value = "bottomright", text = "Below, right"},
    {value = "left",        text = "Left of frame"},
    {value = "right",       text = "Right of frame"},
}

Auras.GROWTH_ITEMS = {
    {value = "auto",  text = "Auto (from anchor)"},
    {value = "RIGHT", text = "Right"},
    {value = "LEFT",  text = "Left"},
    {value = "UP",    text = "Up"},
    {value = "DOWN",  text = "Down"},
}

-- Growth token -> the flow-layout triple AuraEngine wants. The container is
-- anchored at the corner content grows AWAY from, so a row never creeps back
-- over the frame it belongs to.
local function ResolveFlow(growth)
    if growth == "LEFT" then
        return "HORIZONTAL", "LEFT", "DOWN", "TOPRIGHT"
    elseif growth == "UP" then
        return "VERTICAL", "RIGHT", "UP", "BOTTOMLEFT"
    elseif growth == "DOWN" then
        return "VERTICAL", "RIGHT", "DOWN", "TOPLEFT"
    end
    return "HORIZONTAL", "RIGHT", "DOWN", "TOPLEFT" -- RIGHT
end

local function EffectiveGrowth(cfg)
    local growth = cfg.growth or "auto"
    if growth ~= "auto" then return growth end
    local a = ANCHOR_POINTS[cfg.anchor or "none"]
    return a and a[3] or "RIGHT"
end

local function StyleKey(unit, kind)
    return "sfUF_" .. kind .. "_" .. unit
end

local function GroupKey(kind)
    return "sfUF" .. kind
end

-- Filter tokens for the group. AE.Filter canonicalises ORDER -- required, not
-- cosmetic: the engine batches aura parsing per container by exact
-- byte-identical filter string, so two equivalent-but-differently-ordered
-- lists silently fail to share a scan.
local function FilterTokens(kind, cfg)
    local tokens = { (kind == "buffs") and "HELPFUL" or "HARMFUL" }
    if cfg.onlyMine then tokens[#tokens + 1] = "PLAYER" end
    return tokens
end

local function BuildStyle(unit, kind, cfg)
    local AE = SquizzFrames.AuraEngine
    local key = StyleKey(unit, kind)
    local size = cfg.size or 20

    AE.styles[key] = AE.styles[key] or {}
    local style = AE.styles[key]
    -- EVERYTHING is re-applied on every build rather than folded into an
    -- `or { ... }` initialiser: that table is created once and reused for the
    -- style's lifetime, so anything set only inside it could never respond to
    -- a settings change. This is a mistake worth not repeating -- the party
    -- indicators' own styles carry a comment about it.
    style.width, style.height = size, size

    -- Text placement. The engine reads these directly (AuraEngine.lua's
    -- region setup), so the defaults live in UnitFrames_Defaults.lua and are
    -- merely forwarded here.
    style.durationPoint = cfg.durationPoint or "TOP"
    style.durationRelPoint = cfg.durationRelPoint or "BOTTOM"
    style.durationX = cfg.durationX or 0
    style.durationY = cfg.durationY or -2
    -- stackPoint is used for BOTH the text's point and the icon's -- the
    -- engine does not take a separate relative point for stacks.
    style.stackPoint = cfg.stackPoint or "BOTTOMRIGHT"
    style.stackX = cfg.stackX or 1
    style.stackY = cfg.stackY or -1
    style.showDuration = (cfg.showDuration ~= false)
    style.showStack = (cfg.showStack ~= false)
    style.border = (cfg.showBorder ~= false) and { 0, 0, 0, 1, size = 1 } or nil
    if cfg.font and AE.ApplyFontSettings then
        AE.ApplyFontSettings(style, cfg.font)
    end
    return key
end

local function BuildSpec(unit, kind, cfg)
    local size = cfg.size or 20
    local axis, growthH, growthV = ResolveFlow(EffectiveGrowth(cfg))
    return {
        layout = {
            axis = axis,
            anchorPoint = (growthH == "RIGHT") and "LEFT" or "RIGHT",
            growthH = growthH,
            growthV = growthV,
        },
        groups = {
            {
                key = GroupKey(kind),
                filter = FilterTokens(kind, cfg),
                maxFrameCount = cfg.num or 8,
                style = BuildStyle(unit, kind, cfg),
                layout = { elementWidth = size, elementHeight = size },
            },
        },
    }
end

-----------------------------------------------------------------------
-- Refresh
-----------------------------------------------------------------------

-- container:UpdateAllAuras() forces a full re-parse. Two things need it, and
-- both were missing here (user report + screenshot, 2026-09-06: seven copies
-- of one Hunter's Mark on the target frame, one more per recast).
--
--   1. REAPPLICATION. The engine can hold a stale matched instance and not
--      notice the aura being refreshed, so a recast reads as an additional
--      aura rather than the same one. AuraEngineIndicators.lua hit this first
--      and fixed it exactly this way for its slot-based indicators; the same
--      remedy applies to the group-based rows here.
--
--   2. THE UNIT BEHIND THE TOKEN CHANGING. "target" is a stable STRING whose
--      meaning changes every time you target something else. The container is
--      bound to the token and only re-parses on that unit's UNIT_AURA, which
--      is not what fires when you switch targets -- so the row kept showing
--      the previous target's auras.
--
-- UpdateAllAuras and nothing else: AE.RebindUnit is the wrong tool for both.
-- It early-outs when the token is unchanged (which it always is here), and it
-- defers to end of combat because SetUnit's combat legality on a live
-- container is unverified -- see its comment. UpdateAllAuras carries no such
-- doubt; the slot ticker has been running it in combat since August.
local refreshRegistry = {}  -- [wrapper] = container
local refreshTicker = CreateFrame("Frame")
refreshTicker:Hide()
local refreshElapsed = 0
refreshTicker:SetScript("OnUpdate", function(_, dt)
    refreshElapsed = refreshElapsed + dt
    if refreshElapsed < 1 then return end
    refreshElapsed = 0
    local any = false
    for wrapper, container in pairs(refreshRegistry) do
        if not wrapper:IsShown() then
            refreshRegistry[wrapper] = nil -- self-prune hidden/disabled rows
        else
            any = true
            pcall(container.UpdateAllAuras, container)
        end
    end
    if not any then refreshTicker:Hide() end
end)

local function RegisterRefresh(wrapper, container)
    refreshRegistry[wrapper] = container
    refreshTicker:Show()
end

-- Immediate re-parse for every row on `unit`. Called the moment a token is
-- repointed (target/focus changed), rather than waiting up to a second for the
-- ticker -- a target frame showing the last target's debuffs is the kind of
-- wrong that gets acted on.
function Auras.ForceRefresh(unit)
    for wrapper, container in pairs(refreshRegistry) do
        if wrapper._sfUnit == unit then
            pcall(container.UpdateAllAuras, container)
        end
    end
end

-- One wrapper per frame per kind. The real AuraContainer becomes a child of it
-- once the engine hands one over, which can be deferred to the end of combat
-- (container creation hard-errors in combat by Blizzard design), so nothing
-- here may assume _container exists.
function Auras.Create(parent, unit, kind)
    local wrapper = CreateFrame("Frame", nil, parent)
    wrapper:SetSize(1, 1)
    wrapper._sfUnit = unit
    wrapper._sfKind = kind
    wrapper:Hide()
    return wrapper
end

function Auras.ApplySettings(wrapper, parent, t, kind)
    if not wrapper or not parent or not t then return end
    local AE = SquizzFrames.AuraEngine
    local cfg = t[kind]
    local anchor = cfg and cfg.anchor or "none"

    if not AE or not cfg or anchor == "none" then
        wrapper:Hide()
        if wrapper._container then wrapper._container:Hide() end
        return
    end

    local unit = wrapper._sfUnit
    local size = cfg.size or 20
    local num = cfg.num or 8
    local a = ANCHOR_POINTS[anchor] or ANCHOR_POINTS.topleft

    -- The wrapper is only a positioning handle; the container inside it does
    -- the flowing, so the wrapper just needs to be big enough not to clip.
    wrapper:ClearAllPoints()
    wrapper:SetPoint(a[1], parent, a[2], cfg.offsetX or 0, cfg.offsetY or 0)
    wrapper:SetSize(math.max(1, size * num), math.max(1, size))
    wrapper:Show()

    local styleKey = BuildStyle(unit, kind, cfg)
    local groupKey = GroupKey(kind)
    local container = wrapper._container

    if not container then
        -- Requested, not created: AE.RequestContainer fulfils immediately out
        -- of combat and queues until PLAYER_REGEN_ENABLED otherwise. Deferred
        -- until the row is actually switched on, so a profile that never uses
        -- auras never pays for ten frames' worth of containers.
        AE.RequestContainer(wrapper, unit, BuildSpec(unit, kind, cfg), function(c)
            wrapper._container = c
            Auras.ApplyLayout(wrapper, cfg)
            c:SetShown(wrapper:IsShown())
            RegisterRefresh(wrapper, c)
        end)
        return
    end

    -- Re-registered on every settings pass, not only at creation: the ticker
    -- self-prunes hidden wrappers, so a row switched off and back on would
    -- otherwise never refresh again.
    RegisterRefresh(wrapper, container)

    -- Live container: push the changed settings rather than rebuilding it.
    -- Containers are permanent (WoW never destroys frames) and each carries a
    -- batch of pre-created buttons, so churning them is expensive and visible.
    pcall(container.SetAuraGroupFilterString, container, groupKey,
        AE.Filter(unpack(FilterTokens(kind, cfg))))
    pcall(container.SetAuraGroupMaxFrameCount, container, groupKey, num)
    pcall(container.SetAuraGroupLayout, container, groupKey,
        { elementWidth = size, elementHeight = size })
    AE.RestyleSoon(styleKey)
    Auras.ApplyLayout(wrapper, cfg)
    container:SetShown(true)
end

-- Re-point a live container at the current growth. Separate from
-- ApplySettings so the container callback can call it too -- the layout in the
-- spec was resolved when the container was REQUESTED, which may be a combat
-- drop earlier than when it actually arrives.
function Auras.ApplyLayout(wrapper, cfg)
    local container = wrapper and wrapper._container
    if not container then return end
    local AE = SquizzFrames.AuraEngine
    local axis, growthH, growthV, corner = ResolveFlow(EffectiveGrowth(cfg))
    local flowAxis = AE.FlowAxis and AE.FlowAxis(axis)
    if flowAxis and container.SetFlowLayoutAxis then
        pcall(container.SetFlowLayoutAxis, container, flowAxis)
    end
    if container.SetFlowLayoutAnchorPoint then
        container:SetFlowLayoutAnchorPoint((growthH == "RIGHT") and "LEFT" or "RIGHT")
    end
    if container.SetFlowLayoutGrowthDirection and AE.FlowDir then
        container:SetFlowLayoutGrowthDirection(AE.FlowDir(growthH), AE.FlowDir(growthV))
    end
    container:ClearAllPoints()
    container:SetPoint(corner, wrapper, corner, 0, 0)
end
