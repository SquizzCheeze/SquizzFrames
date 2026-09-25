--[[ SquizzFrames Tank Tracker Preview

    A 1:1 mock of one tank frame, drawn on the Tank Tracker options page so a
    size, offset or text change can be judged without standing next to a tank
    mid-pull -- the only time the real thing has anything on it.

    The same rules as UnitFrames/Preview.lua, for the same reasons:

      * 1:1 MEANS 1:1. Built at the configured width, height and scale.

      * IT IS THE REAL FRAME, NOT A LOOKALIKE. TankTracker.CreateTankFrame
        builds it, DressFrame styles it, PlaceRow positions its icon rows,
        HealthColor and SetNameText colour and label it, and StyleFields
        produces the text style its mock icons are drawn from. Nothing about
        how a tank frame looks is reimplemented here.

      * IT CANNOT SHOW REAL AURAS. An AuraContainer renders C-side from a real
        unit and no fake AuraData can reach it, so the icon rows are static
        mock icons laid out where the container would put them -- with mock
        duration and stack text styled by AEI.ApplyMock*Text, the one shared
        copy of how engine-drawn text looks.

    Always the PLAYER, for the reason the unit frame preview gives: the one unit
    guaranteed to exist and be readable while you are designing.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F

local Preview = {}
SquizzFrames.TankTrackerPreview = Preview

local PLACEHOLDER_ICON = [[Interface\Icons\INV_Misc_QuestionMark]]

-- Plain fraction for the mock bar. Health is a secret on the real frame and
-- never touched in Lua; this one is a constant and can be.
local PREVIEW_HEALTH = 0.72

-- Clearance below the pane's caption, in PANE pixels (divided by the mock's
-- scale at use, since SetPoint offsets are in the mock's own space).
local TOP_PAD = 34

-- Representative icons, so a row reads as "several different debuffs" rather
-- than one question mark repeated. Resolved through C_Spell at draw time; an
-- ID that has since been removed just falls back to the placeholder.
local SAMPLE_SPELLS = {
    debuff = {589, 348, 172, 980, 8921, 1079, 703, 1943},
    def    = {871, 33206, 6940, 102342, 47788, 116849, 1022, 48707},
}

local function SpellIcon(kind, i)
    local ids = SAMPLE_SPELLS[kind]
    local id = ids[((i - 1) % #ids) + 1]
    local tex = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(id)
    return tex or PLACEHOLDER_ICON
end

-- Build once; Refresh re-dresses. Nil when the module is missing, which the
-- panel treats as "no preview" rather than an error.
function Preview.Create(parent)
    local TT = SquizzFrames.TankTracker
    if not (TT and TT.CreateTankFrame) then return nil end
    local p = TT.CreateTankFrame(nil, parent)
    p.mockIcons = { debuff = {}, def = {} }
    return p
end

-- One mock icon, created on first use. Parented to the row's WRAPPER, exactly
-- where the live container sits, so it inherits the same placement and level.
-- A Frame rather than a bare texture: the text anchors to the icon, as the
-- engine anchors it to the button.
local function MockIcon(p, kind, i)
    local pool = p.mockIcons[kind]
    local f = pool[i]
    if f then return f end
    f = CreateFrame("Frame", nil, p.rows[kind])
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.tex:SetTexture(SpellIcon(kind, i))
    if F.CreateBorder then F.CreateBorder(f, 0, 0, 0, 1, 1) end
    f.duration = f:CreateFontString(nil, "OVERLAY")
    f.stack = f:CreateFontString(nil, "OVERLAY")
    pool[i] = f
    return f
end

-- Lay out one row. Returns PlaceRow's geometry when the row is shown, nil when
-- it is not, so Refresh can size the composite.
local function RefreshRow(p, kind, cfg)
    local TT = SquizzFrames.TankTracker
    local AEI = SquizzFrames.AuraEngineIndicators
    local row = (kind == "def") and cfg.defensives or cfg.debuffs
    local wrapper = p.rows[kind]
    local pool = p.mockIcons[kind]

    if not (row and row.enabled) then
        wrapper:Hide()
        return nil
    end

    local point, relPoint, ox, oy, ww, wh = TT.PlaceRow(p, kind, row)
    wrapper:Show()

    local size = row.size or 32
    local spacing = row.spacing or 2
    local num = math.max(1, row.num or 4)
    -- How many lines the live row can actually fill, which is a different sum
    -- for each row and must track BuildSpec's capacity exactly or the mock
    -- lies about the real frame.
    --   debuffs    -- one group holding perRow x Rows, so Rows lines.
    --   defensives -- two groups (big + external) of perRow each, flowing on
    --                 after one another, so at most 2 lines however high Rows
    --                 goes.
    -- Both capped by Rows so the mock never claims more space than PlaceRow
    -- reserves on the wrapper.
    local maxRows = math.max(1, row.maxRows or 1)
    local capacityLines = (kind == "def") and 2 or maxRows
    local lines = math.min(capacityLines, maxRows)
    local shown = num * lines
    -- With every line full the growth setting would be invisible -- a full
    -- grid looks the same whichever corner it fills from. Leave the LAST line
    -- half-filled so you can see where the first icon goes and which way new
    -- lines stack.
    if lines > 1 then shown = shown - math.floor(num / 2) end

    -- A throwaway style built from the settings being edited right now, not
    -- AE.styles: the live style only exists once a tank has been seen, and
    -- the point is to see the value on the slider.
    local style = TT.StyleFields(cfg, row, {})

    -- The container is pinned to the wrapper corner its growth runs away from
    -- and wraps every `num` -- see ApplyRow and BuildSpec. TT.RowFlow is the
    -- one place that corner is decided, so the mock cannot disagree with it.
    local growthH, growthV, corner = TT.RowFlow(row)
    local sx = (growthH == "LEFT") and -1 or 1
    local sy = (growthV == "UP") and 1 or -1

    for i = 1, shown do
        local f = MockIcon(p, kind, i)
        f:SetSize(size, size)
        f:ClearAllPoints()
        local col = (i - 1) % num
        local line = math.floor((i - 1) / num)
        f:SetPoint(corner, wrapper, corner,
            sx * col * (size + spacing), sy * line * (size + spacing))
        if F.SetBorderShown then F.SetBorderShown(f, style.border ~= nil) end
        if AEI and AEI.ApplyMockDurationText then
            AEI.ApplyMockDurationText(f.duration, f, style, nil)
            AEI.ApplyMockStackText(f.stack, f, style, row.showStack)
        end
        f:Show()
    end
    for i = shown + 1, #pool do pool[i]:Hide() end

    return point, relPoint, ox, oy, ww, wh
end

-- Where `point` sits on a w*h box, measured from the box's bottom-left.
local function PointXY(point, w, h)
    local x = point:find("LEFT") and 0 or (point:find("RIGHT") and w or w / 2)
    local y = point:find("TOP") and h or (point:find("BOTTOM") and 0 or h / 2)
    return x, y
end

function Preview.Refresh(p, cfg)
    local TT = SquizzFrames.TankTracker
    if not (p and cfg and TT and TT.DressFrame) then return end

    local scale = cfg.scale or 1
    p:SetScale(scale)
    TT.DressFrame(p, cfg)
    p.health:SetMinMaxValues(0, 1)
    p.health:SetValue(PREVIEW_HEALTH)
    p.health:SetStatusBarColor(TT.HealthColor("player", cfg))
    TT.SetNameText(p, "player", cfg)

    -- Bounding box of the frame plus both rows, in the mock's own units with
    -- the bar's bottom-left as origin. Rows hang above and below by default
    -- and can be offset anywhere, so centring the BAR would push a tall debuff
    -- row out of the top of the pane.
    local w, h = cfg.width or 150, cfg.height or 20
    local minX, maxX, minY, maxY = 0, w, 0, h
    for _, kind in ipairs({"debuff", "def"}) do
        local point, relPoint, ox, oy, ww, wh = RefreshRow(p, kind, cfg)
        if point then
            local fx, fy = PointXY(relPoint, w, h)
            local wx, wy = PointXY(point, ww, wh)
            local left, bottom = fx + ox - wx, fy + oy - wy
            minX = math.min(minX, left)
            maxX = math.max(maxX, left + ww)
            minY = math.min(minY, bottom)
            maxY = math.max(maxY, bottom + wh)
        end
    end

    -- Centre the box horizontally under the caption, top-align it vertically.
    local pane = p:GetParent()
    p:ClearAllPoints()
    p:SetPoint("BOTTOMLEFT", pane, "TOP",
        -(maxX - minX) / 2 - minX, -TOP_PAD / scale - maxY)
    p:Show()
end
