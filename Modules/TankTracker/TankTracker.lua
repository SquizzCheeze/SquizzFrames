--[[ SquizzFrames Tank Tracker

    A compact frame per tank in the group: the tank's incoming boss/role
    debuffs above a thin health bar, their active defensives below it.

    Layout modelled on CoTankTracker (by zerbi). Implementation is our own, on
    AuraEngine rather than oUF -- see Defaults/TankTracker_Defaults.lua for the
    two undocumented 12.1 engine behaviours reading that addon taught us.

    ------------------------------------------------------------------
    SECRET VALUES DECIDE THE SHAPE OF THIS FILE
    ------------------------------------------------------------------
    On 12.1 UnitGroupRolesAssigned, UnitIsUnit and the aura APIs all return
    SECRET values when a unit's identity is restricted. A secret is not nil: it
    survives `if x then` but throws on comparison, arithmetic or table-key use.

    Two rules follow, and they point in opposite directions on purpose:

      * IDENTITY reads FAIL CLOSED. If we cannot prove a unit is not the
        player, we skip it -- otherwise you appear as your own co-tank.
      * CONNECTION reads FAIL OPEN. An unreadable connection state must never
        drop a tank off the display.

    ------------------------------------------------------------------
    FRAMES ARE PLAIN, NOT SECURE
    ------------------------------------------------------------------
    These are display-only: no click-casting, no unit attribute, no
    RegisterUnitWatch. That is a deliberate trade. A secure frame would let you
    click a co-tank, but it would also drag in combat lockdown on every size
    and position change, and the roster churn this thing responds to happens
    mid-pull constantly. Show/hide and resize freely instead.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local TankTracker = SquizzFrames:NewModule("TankTracker", "AceEvent-3.0")
local F = SquizzFrames.F

local frames = {}          -- [index] = frame
local mover                -- drag handle, shown in edit mode
local initialized = false

-----------------------------------------------------------------------
-- Secret-safe reads
-----------------------------------------------------------------------

-- Returns the value, or nil when it is secret. Every caller decides for itself
-- what nil means -- see the fail-closed / fail-open split in the header.
local function Plain(v)
    if F and F.IsValueNonSecret then
        if not F.IsValueNonSecret(v) then return nil end
        return v
    end
    return v
end

-- true / false / nil-when-unknowable.
--
-- C_Secrets.CanCompareUnitTokens is the engine's own "is this comparison
-- permitted" gate (confirmed in Blizzard's 12.1.5 source as
-- C_Secrets.CanCompareUnitTokens). It is guarded rather than assumed: it does
-- not exist on every build this addon runs on, and without it UnitIsUnit can
-- hand back a secret that throws the moment it is compared.
--
-- GUID equality is the fallback, the same technique PetFrames.lua uses to find
-- the player's own pet among the raid pet tokens -- UnitGUID on a group token
-- is a plain string where UnitIsUnit is not.
local function IsSameUnit(unitA, unitB)
    if C_Secrets and C_Secrets.CanCompareUnitTokens then
        if not Plain(C_Secrets.CanCompareUnitTokens(unitA, unitB)) then
            local ga, gb = Plain(UnitGUID(unitA)), Plain(UnitGUID(unitB))
            if ga and gb then return ga == gb end
            return nil
        end
    end
    local same = Plain(UnitIsUnit(unitA, unitB))
    if same ~= nil then return same end
    local ga, gb = Plain(UnitGUID(unitA)), Plain(UnitGUID(unitB))
    if ga and gb then return ga == gb end
    return nil
end

local function IsTank(unit)
    return Plain(UnitGroupRolesAssigned(unit)) == "TANK"
end

local function PlayerIsTank()
    if PlayerUtil and PlayerUtil.IsPlayerEffectivelyTank then
        local v = Plain(PlayerUtil.IsPlayerEffectivelyTank())
        if v ~= nil then return v == true end
    end
    return IsTank("player")
end

-----------------------------------------------------------------------
-- Settings
-----------------------------------------------------------------------

local function GetProfile()
    return SquizzFrames.db and SquizzFrames.db.profile
end

local function GetConfig()
    local p = GetProfile()
    return p and p.tankTracker
end

local function Enabled()
    local cfg = GetConfig()
    if not (cfg and cfg.enabled) then return false end
    if cfg.requireTankSpec and not PlayerIsTank() then return false end
    return true
end

local function GetBarTexture()
    local p = GetProfile()
    -- appearance.general.TEXTURE, not barTexture -- same key PartyFrames.lua
    -- reads, so one control drives every bar in the addon.
    local key = (p and p.appearance and p.appearance.general
        and p.appearance.general.texture) or "Blizzard"
    local LSM = LibStub and LibStub:GetLibrary("LibSharedMedia-3.0", true)
    if LSM and key then
        return LSM:Fetch("statusbar", key) or "Interface\\TargetingFrame\\UI-StatusBar"
    end
    return "Interface\\TargetingFrame\\UI-StatusBar"
end

-----------------------------------------------------------------------
-- Which units
-----------------------------------------------------------------------

-- Ordered list of unit tokens to show, longest-lived first (player, then raid
-- order). Reuses the caller's table -- this runs on roster churn.
--
-- Group tokens only: "party1..4"/"raid1..40". Deliberately NOT the party
-- header's buttons -- those reassign tokens on every re-sort, and this list is
-- rebuilt from scratch on the events that matter instead.
local function CollectTanks(out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end

    local cfg = GetConfig()
    if not cfg then return out end

    -- The player first, so their own frame keeps the top slot rather than
    -- jumping around as the raid re-orders underneath.
    if cfg.includeSelf ~= false and PlayerIsTank() then
        out[#out + 1] = "player"
    end

    local n = GetNumGroupMembers() or 0
    local prefix = IsInRaid() and "raid" or "party"
    -- A party has GetNumGroupMembers() including you, but party1..N excludes
    -- you -- so the loop bound is one short for a raid and correct for a
    -- party only by accident. Walk the full count either way and let
    -- UnitExists reject the overshoot.
    for i = 1, n do
        local unit = prefix .. i
        if UnitExists(unit) then
            -- FAIL CLOSED: nil (unknowable) is not false, so an
            -- uncomparable unit is skipped rather than risking the player
            -- appearing as their own co-tank.
            local isSelf = IsSameUnit(unit, "player")
            -- FAIL OPEN: only an explicit false drops the unit.
            local connected = Plain(UnitIsConnected(unit)) ~= false
            if isSelf == false and connected and IsTank(unit) then
                out[#out + 1] = unit
            end
        end
    end

    local maxFrames = cfg.maxFrames or 4
    for i = #out, maxFrames + 1, -1 do out[i] = nil end
    return out
end

-----------------------------------------------------------------------
-- Aura rows
-----------------------------------------------------------------------

-- See Defaults/TankTracker_Defaults.lua for why this bound exists at all. It
-- is a WORKAROUND for the list query ignoring classification tokens, not a
-- design choice -- remove it once that is fixed and the filter strings narrow
-- the groups on their own.
local DEFENSIVE_MAX_DURATION = 60
local DEFENSIVE_CANDIDATES = { maxDuration = DEFENSIVE_MAX_DURATION }

-- Two groups, not one. An aura carrying BOTH flags would otherwise render
-- twice, so the external group negates the big one.
local DEF_GROUPS = {
    { key = "sfttBigDef", filter = {"HELPFUL", "BIG_DEFENSIVE"} },
    { key = "sfttExtDef", filter = {"HELPFUL", "EXTERNAL_DEFENSIVE", "!BIG_DEFENSIVE"} },
}

local DEBUFF_FILTER_TOKENS = {
    all            = {"HARMFUL"},
    raid           = {"HARMFUL", "RAID"},
    important      = {"HARMFUL"},
    raid_important = {"HARMFUL", "RAID"},
    boss_role      = {"HARMFUL"},
    encounter      = {"HARMFUL"},
    both           = {"HARMFUL"},
}

-- The half that actually does the filtering. isPriorityAura is the curated
-- priority-debuff list Blizzard's own raid frames use; isBossOrRoleAura is
-- boss auras plus role auras, which is where 12.1 delivers tank mechanics.
--
-- Both are FLAGS BLIZZARD AUTHORS PER AURA, and that is their weakness: an
-- encounter whose debuffs carry neither is invisible under either preset, with
-- nothing on our side able to help (user report 2026-09-19 -- see point 3 of
-- the header note in TankTracker_Defaults.lua).
--
-- Note also that candidate filters are ANDed, not ORed: every key in one of
-- these tables is an independent early reject in Blizzard's
-- DoesAuraPassCandidateFilters, so pairing two flags here NARROWS the result
-- rather than widening it. A union would need two groups, the way DEF_GROUPS
-- above splits the defensives.
--
-- `encounter` therefore does no flag narrowing at all, just a duration bound --
-- the same trick DEFENSIVE_MAX_DURATION uses above. maxDuration is evaluated
-- on both the list-query and UNIT_AURA paths, and implicitly drops permanent
-- auras too (Blizzard rejects duration == 0), which removes precisely the
-- noise a tank does not care about: food, flasks, auras, forms.
local DEBUFF_MAX_DURATION = 300
local DEBUFF_CANDIDATES = {
    important      = { isPriorityAura = true },
    raid_important = { isPriorityAura = true },
    boss_role      = { isBossOrRoleAura = true },
    encounter      = { maxDuration = DEBUFF_MAX_DURATION },
    -- Union. Its primary group is boss/role; the priority half rides in a
    -- SECOND group (DEBUFF_UNION_SECOND) because these tables are ANDed -- see
    -- the note above. Same shape the defensives row has always used.
    both           = { isBossOrRoleAura = true },
}

-- Priority auras that are NOT boss/role, so the union's two groups are
-- mutually exclusive by construction and nothing renders twice.
local DEBUFF_UNION_SECOND = { isPriorityAura = true, isBossOrRoleAura = false }

local function StyleKey(index, kind)
    return "sfTT_" .. kind .. "_" .. index
end

-- Per-text fallbacks for a row that predates a field. A real profile carries
-- every one of these; the face and outline are the exception, and fall
-- through to the frame-wide `font` instead -- see TankTracker_Defaults.lua.
local TEXT_FALLBACK = {
    duration = { size = 11, anchor = "CENTER",      x = 0, y = 0 },
    stack    = { size = 11, anchor = "BOTTOMRIGHT", x = 1, y = -1 },
}
local WHITE = {1, 1, 1, 1}

-- The EFFECTIVE settings of one icon text, `prefix` being "duration" or
-- "stack". The one place these fallbacks live: StyleFields (and so the live
-- engine), the options preview and the panel's getters all read through it,
-- so the three cannot disagree about what an unset field means.
function TankTracker.TextSettings(cfg, row, prefix)
    local fb = TEXT_FALLBACK[prefix] or TEXT_FALLBACK.duration
    local font = cfg and cfg.font
    row = row or {}
    return {
        face    = row[prefix .. "Font"] or (font and font[1]) or "Friz QT__",
        outline = row[prefix .. "Outline"] or (font and font[3]) or "OUTLINE",
        size    = row[prefix .. "Size"] or fb.size,
        anchor  = row[prefix .. "Anchor"] or fb.anchor,
        x       = row[prefix .. "X"] or fb.x,
        y       = row[prefix .. "Y"] or fb.y,
        color   = row[prefix .. "Color"] or WHITE,
    }
end

-- One text's settings as ApplyFontSettings' eight-row slot:
-- {name, size, outline, shadow, anchor, xOffset, yOffset, color}.
--
-- "NONE" goes in as "", not "NONE". ApplyFontSlot turns "NONE" into nil, and
-- both the engine's region setup and the mock text then read nil as
-- `or "OUTLINE"` -- so choosing no outline silently produced an outline. An
-- empty string is a valid no-flags argument to SetFont and survives the `or`.
local function FontSlot(ts)
    local flags = ts.outline
    if flags == "NONE" then flags = "" end
    return {ts.face, ts.size, flags, nil, ts.anchor, ts.x, ts.y, ts.color}
end

-- Fill in a row's style FIELDS, independent of where the table lives. Public
-- for the options preview, which draws its mock icons' duration and stack
-- text from exactly these numbers -- same arrangement as Auras.StyleFields,
-- for the same reason: a second copy of this mapping is how a preview starts
-- lying about where the text lands.
function TankTracker.StyleFields(cfg, row, into)
    local AE = SquizzFrames.AuraEngine
    local style = into or {}
    local size = row.size or 32

    -- Re-applied in full every time, never folded into an `or {...}`
    -- initialiser: that table is created once and reused for the style's
    -- lifetime, so anything set only inside it could never respond to a
    -- settings change. Same note as UnitFrames/Auras.lua.
    style.width, style.height = size, size
    style.showDuration = row.showDuration ~= false
    style.showStack = row.showStack ~= false
    style.border = (row.showBorder ~= false) and {0, 0, 0, 1, size = 1} or nil

    -- AE.ApplyFontSettings owns EVERY text field -- face, size, outline,
    -- anchor, both offsets and colour, for both texts. Nothing here sets
    -- style.durationPoint/stackX/etc by hand; doing so would be overwritten on
    -- the next pass anyway.
    --
    -- THE SHAPE MATTERS AND FAILS SILENTLY IF WRONG. It wants
    -- {stackSlot, durationSlot}, each an eight-row tuple (see FontSlot).
    -- Passing a flat {face, size, flags} instead puts a STRING in slot 1,
    -- which ApplyFontSettings treats as the plain-text-indicator shape and
    -- returns from immediately -- no error, no text styling at all. That was
    -- this module's original bug: the duration size slider had never worked,
    -- not merely stopped updating.
    --
    -- Anchor semantics, per ApplyFontSlot: one point is used for BOTH sides of
    -- SetPoint, so "BOTTOMRIGHT" reads as "pin the text's bottom-right to the
    -- icon's bottom-right".
    if AE and AE.ApplyFontSettings then
        AE.ApplyFontSettings(style, {
            FontSlot(TankTracker.TextSettings(cfg, row, "stack")),
            FontSlot(TankTracker.TextSettings(cfg, row, "duration")),
        })
    end
    return style
end

local function BuildStyle(index, kind, row, cfg)
    local AE = SquizzFrames.AuraEngine
    local key = StyleKey(index, kind)
    AE.styles[key] = AE.styles[key] or {}
    TankTracker.StyleFields(cfg, row, AE.styles[key])
    return key
end

local A = nil  -- resolved lazily: UnitFrameAuras owns the anchor vocabulary

local function AnchorModule()
    A = A or SquizzFrames.UnitFrameAuras
    return A
end

local function BuildSpec(index, kind, row, cfg)
    local size = row.size or 32
    local style = BuildStyle(index, kind, row, cfg)
    local perRow = math.max(1, row.num or 4)
    local rows = math.max(1, row.maxRows or 1)
    local layout = {
        elementWidth = size,
        elementHeight = size,
        elementSpacing = row.spacing or 2,
    }

    local groups = {}
    if kind == "def" then
        for i, g in ipairs(DEF_GROUPS) do
            groups[i] = {
                key = g.key,
                filter = g.filter,
                candidateFilters = DEFENSIVE_CANDIDATES,
                maxFrameCount = perRow,
                style = style,
                layout = layout,
            }
        end
    else
        local preset = cfg.debuffFilter or "encounter"
        -- Capacity is per-row x rows. The debuff row has exactly ONE group, so
        -- capping it at `perRow` made the Rows slider dead on this row: the
        -- group could never hold more icons than one line fits, so there was
        -- never anything to wrap onto a second line. The defensives row got
        -- two lines "for free" only because it declares two groups.
        --
        -- The union splits that capacity rather than doubling it: maxFrameCount
        -- is a static per-group cap, so boss/role takes the larger half and the
        -- priority-only group the rest. Under-fills when one half is empty,
        -- which is the honest trade for the row never exceeding its own number.
        local cap = perRow * rows
        local secondCap = 0
        if preset == "both" then
            secondCap = math.floor(cap / 2)
            cap = cap - secondCap
        end
        local tokens = DEBUFF_FILTER_TOKENS[preset] or DEBUFF_FILTER_TOKENS.all
        groups[1] = {
            key = "sfttDebuff",
            filter = tokens,
            candidateFilters = DEBUFF_CANDIDATES[preset],
            maxFrameCount = cap,
            style = style,
            layout = layout,
        }
        -- Declared even when the union is off (cap 0): groups are add-only, so
        -- one absent at creation could never appear on a later filter change.
        groups[2] = {
            key = "sfttDebuffPriority",
            filter = tokens,
            candidateFilters = (preset == "both") and DEBUFF_UNION_SECOND or nil,
            maxFrameCount = secondCap,
            style = style,
            layout = layout,
        }
    end

    return {
        layout = {
            axis = "HORIZONTAL",
            -- `rowWidth`, NOT `maximumLineSize`. AE.ApplyContainerLayout reads
            -- exactly one key for the wrap width and it is rowWidth; the
            -- engine method it forwards to is what is called
            -- SetFlowLayoutMaximumLineSize, and that method name got written
            -- here as the field name. Nothing read it, so the container was
            -- left at its default unlimited line size and NO tank tracker row
            -- ever wrapped -- on live or in the preview. Silent because a spec
            -- carrying an unknown key is not an error (user report
            -- 2026-09-17: "the preview is not wrapping the icons").
            rowWidth = perRow * (size + (row.spacing or 2)),
        },
        groups = groups,
    }
end

-----------------------------------------------------------------------
-- Frame construction
-----------------------------------------------------------------------

local function CreateRow(frame, kind)
    local wrapper = CreateFrame("Frame", nil, frame)
    wrapper:SetSize(1, 1)
    wrapper._sfKind = kind
    return wrapper
end

-- `index` nil builds an anonymous frame under `parent` -- the options preview,
-- which is the same frame rather than a lookalike so the two cannot drift.
local function CreateTankFrame(index, parent)
    local f = CreateFrame("Frame", index and ("SquizzFramesTankTracker" .. index) or nil,
        parent or UIParent)
    f:SetSize(150, 20)
    -- Real frames only. An explicit strata is NOT inherited from the parent,
    -- so forcing MEDIUM on the preview drew it underneath the DIALOG-strata
    -- options window -- the pane showed as an empty black box. Left unset, a
    -- parented frame takes its parent's strata and sits one level above it.
    if not parent then f:SetFrameStrata("MEDIUM") end
    f:Hide()

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetColorTexture(0, 0, 0, 0.6)
    f.bg = bg

    local health = CreateFrame("StatusBar", nil, f)
    health:SetAllPoints(f)
    health:SetMinMaxValues(0, 1)
    health:SetValue(1)
    f.health = health

    -- Name on its own host above the bar, for the reason documented on the
    -- unit frames: a FontString owned by the frame renders UNDER a StatusBar
    -- child sitting on top of it.
    local textHost = CreateFrame("Frame", nil, f)
    textHost:SetAllPoints(f)
    textHost:SetFrameLevel(f:GetFrameLevel() + 5)
    local name = textHost:CreateFontString(nil, "OVERLAY")
    name:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    name:SetPoint("LEFT", f, "LEFT", 3, 0)
    name:SetPoint("RIGHT", f, "RIGHT", -3, 0)
    name:SetJustifyH("LEFT")
    f.nameText = name

    local border = CreateFrame("Frame", nil, f, "BackdropTemplate")
    border:SetAllPoints(f)
    border:SetFrameLevel(f:GetFrameLevel() + 4)
    local BU = SquizzFrames.modules and SquizzFrames.modules["BuiltIn_Update"]
    if BU and BU.CreateBorderIndicator then
        f.border = BU.CreateBorderIndicator(f, "Border")
        f.border:SetFrameLevel(f:GetFrameLevel() + 4)
    end
    border:Hide()

    f.rows = {
        debuff = CreateRow(f, "debuff"),
        def = CreateRow(f, "def"),
    }
    f._sfIndex = index
    return f
end
TankTracker.CreateTankFrame = CreateTankFrame

local function NameJustify(anchor)
    if anchor:find("LEFT") then return "LEFT" end
    if anchor:find("RIGHT") then return "RIGHT" end
    return "CENTER"
end

-- Everything about a frame's look that does not depend on a live unit: size,
-- bar texture, backdrop, name font and placement, border. Shared by
-- ApplyLayout and the options preview. Scale and screen position are NOT
-- here -- the preview has its own pane to sit in.
function TankTracker.DressFrame(frame, cfg)
    local width = cfg.width or 150
    frame:SetSize(width, cfg.height or 20)

    frame.health:SetStatusBarTexture(GetBarTexture())
    local bd = cfg.backdropColor or {0, 0, 0, 0.6}
    frame.bg:SetColorTexture(bd[1] or 0, bd[2] or 0, bd[3] or 0, bd[4] or 0.6)

    local fs = frame.nameText
    local fontFile = (F.ResolveFontFile and F.ResolveFontFile(cfg.font and cfg.font[1]))
        or "Fonts\\FRIZQT__.TTF"
    local flags = cfg.font and cfg.font[3]
    if not flags or flags == "NONE" then flags = "" end
    fs:SetFont(fontFile, cfg.nameFontSize or 12, flags)
    local nc = cfg.nameColor or {1, 1, 1, 1}
    fs:SetTextColor(nc[1] or 1, nc[2] or 1, nc[3] or 1, nc[4] or 1)

    -- One point for both sides, as on the unit frames. The width stays pinned
    -- to the bar minus a 3px margin each side, so a long name still truncates
    -- instead of running off the frame -- which is what the old LEFT+RIGHT
    -- two-point anchor did, and LEFT/3/0 (the defaults) reproduces it exactly.
    local anchor = cfg.nameAnchor or "LEFT"
    fs:ClearAllPoints()
    fs:SetPoint(anchor, frame, anchor, cfg.nameX or 3, cfg.nameY or 0)
    fs:SetWidth(math.max(1, width - 6))
    fs:SetJustifyH(NameJustify(anchor))
    fs:SetWordWrap(false)

    if frame.border then
        if cfg.showBorder then
            local bc = cfg.borderColor or {0, 0, 0, 1}
            frame.border:SetThickness(cfg.borderThickness or 1)
            frame.border:SetColor(bc[1] or 0, bc[2] or 0, bc[3] or 0, bc[4] or 1)
            frame.border:Show()
        else
            frame.border:Hide()
        end
    end
end

-----------------------------------------------------------------------
-- Aura container binding
-----------------------------------------------------------------------

-- Position and size one row's wrapper. Shared with the options preview, which
-- lays its mock icons out inside the same wrapper. Returns the geometry it
-- used (wrapper point, frame point, offsets, wrapper size) so the preview can
-- measure the whole composite without re-deriving the anchor vocabulary.
function TankTracker.PlaceRow(frame, kind, row)
    local wrapper = frame.rows[kind]
    local Amod = AnchorModule()
    local size = row.size or 32
    local spacing = row.spacing or 2
    local num = math.max(1, row.num or 4)
    local rows = math.max(1, row.maxRows or 1)

    local point, relPoint = "BOTTOMLEFT", "TOPLEFT"
    local pts = Amod and Amod.ANCHOR_POINTS and Amod.ANCHOR_POINTS[row.anchor or "topleft"]
    if pts then point, relPoint = pts[1], pts[2] end
    local ox, oy = row.offsetX or 0, row.offsetY or 0
    local ww = math.max(1, num * (size + spacing))
    local wh = math.max(1, rows * (size + spacing))

    wrapper:ClearAllPoints()
    wrapper:SetPoint(point, frame, relPoint, ox, oy)
    wrapper:SetSize(ww, wh)
    return point, relPoint, ox, oy, ww, wh
end

-- Containers are bound to a token at creation and their unit is NOT live (see
-- AE.RebindUnit's comment). A tank frame's token DOES change -- raid3 leaves,
-- everyone shifts up -- so unlike the unit frames this needs real rebinding.
local function ApplyRow(frame, kind, unit)
    local AE = SquizzFrames.AuraEngine
    local cfg = GetConfig()
    if not (AE and cfg) then return end

    local row = (kind == "def") and cfg.defensives or cfg.debuffs
    local wrapper = frame.rows[kind]
    if not (row and wrapper) then return end

    if not row.enabled or not unit then
        wrapper:Hide()
        if wrapper._container then wrapper._container:Hide() end
        return
    end

    TankTracker.PlaceRow(frame, kind, row)
    wrapper:Show()

    -- Rebuilt on EVERY pass, before the container branch below -- not only
    -- when a container is created. BuildStyle used to be reachable solely
    -- through BuildSpec, which runs once at RequestContainer time, so the
    -- style table kept its original values forever and RestyleSoon dutifully
    -- re-applied the settings you had when the row first appeared. Any text
    -- slider looked dead. UnitFrames/Auras.lua calls it unconditionally at the
    -- top of its own ApplySettings for exactly this reason.
    local styleKey = BuildStyle(frame._sfIndex, kind, row, cfg)

    local container = wrapper._container
    if not container then
        AE.RequestContainer(wrapper, unit, BuildSpec(frame._sfIndex, kind, row, cfg),
            function(c)
                wrapper._container = c
                c:ClearAllPoints()
                c:SetPoint("TOPLEFT", wrapper, "TOPLEFT", 0, 0)
                c:SetShown(wrapper:IsShown())
                TankTracker.RegisterRefresh(wrapper, c)
            end)
        return
    end

    -- Live container: re-point at this frame's CURRENT unit, then push the
    -- settings. RebindUnit no-ops when the token is unchanged, so this is
    -- cheap on a plain settings pass.
    if AE.RebindUnit then AE.RebindUnit(container, unit) end

    -- PUSH THE GROUPS. This was missing entirely (user report: "do i need to
    -- reload every time i change which debuffs are shown?" -- yes, you did).
    -- Nothing here updated the filter, the candidate filters, the icon count
    -- or the layout on a container that already existed, so every one of those
    -- settings was frozen at whatever it was when the row first appeared.
    --
    -- Rebuilt from BuildSpec rather than a second hand-written list, so the
    -- create path and the update path cannot describe different groups -- and
    -- so the two-group defensive row is covered without special-casing.
    local spec = BuildSpec(frame._sfIndex, kind, row, cfg)
    if AE.UpdateGroup then
        for _, g in ipairs(spec.groups) do
            AE.UpdateGroup(container, g)
        end
    end

    AE.RestyleSoon(styleKey)
    container:ClearAllPoints()
    container:SetPoint("TOPLEFT", wrapper, "TOPLEFT", 0, 0)
    container:SetShown(true)
    TankTracker.RegisterRefresh(wrapper, container)
end

-- Periodic full re-parse, the same remedy UnitFrames/Auras.lua needs and for
-- the same two reasons: the engine can hold a stale matched instance through a
-- reapplication, and a token whose unit changed does not re-parse on its own.
local refreshRegistry = {}
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
            refreshRegistry[wrapper] = nil
        else
            any = true
            pcall(container.UpdateAllAuras, container)
        end
    end
    if not any then refreshTicker:Hide() end
end)

function TankTracker.RegisterRefresh(wrapper, container)
    refreshRegistry[wrapper] = container
    refreshTicker:Show()
end

-----------------------------------------------------------------------
-- Health
-----------------------------------------------------------------------

-- Bar colour for a unit. Shared with the options preview.
function TankTracker.HealthColor(unit, cfg)
    local r, g, b = 0.2, 0.6, 0.2
    local custom = cfg.healthCustomColor
    if custom then r, g, b = custom[1] or r, custom[2] or g, custom[3] or b end
    if cfg.healthClassColor and F.IsValueNonSecret(F.GetClassFile(unit)) then
        local c = F.GetClassColor(unit)
        if c then r, g, b = c.r, c.g, c.b end
    end
    return r, g, b, 1
end

local function UpdateHealth(frame)
    local unit = frame._sfUnit
    if not unit or not UnitExists(unit) then return end
    local cfg = GetConfig()
    if not cfg then return end

    -- Raw straight into SetMinMaxValues/SetValue, never touched in Lua -- the
    -- rule this whole addon runs on for health.
    frame.health:SetMinMaxValues(0, UnitHealthMax(unit) or 1)
    frame.health:SetValue(UnitHealth(unit) or 0)

    frame.health:SetStatusBarColor(TankTracker.HealthColor(unit, cfg))
    TankTracker.SetNameText(frame, unit, cfg)
end

-- The name on the bar, nickname-aware. Shared with the options preview.
function TankTracker.SetNameText(frame, unit, cfg)
    if cfg.showName then
        local N = SquizzFrames.modules and SquizzFrames.modules["Nicknames"]
        local nick = N and N.Resolve and N:Resolve(unit)
        -- Nicknames' contract: a plain string or nil, and the two NEVER blend.
        -- `nick or UnitName(unit)` is a crash, not a convenience.
        if nick then
            frame.nameText:SetText(nick)
        else
            frame.nameText:SetText(UnitName(unit))
        end
        frame.nameText:Show()
    else
        frame.nameText:Hide()
    end
end

-----------------------------------------------------------------------
-- Layout
-----------------------------------------------------------------------

local function StackOffset(cfg, index)
    local n = index - 1
    local dir = cfg.growthDirection or "DOWN"
    local step = cfg.spacing or 80
    if dir == "UP" then return 0, n * step end
    if dir == "LEFT" then return -n * step, 0 end
    if dir == "RIGHT" then return n * step, 0 end
    return 0, -n * step
end

local tankList = {}

function TankTracker.ApplyLayout()
    local cfg = GetConfig()
    if not cfg then return end

    local on = Enabled()
    local units = on and CollectTanks(tankList) or {}
    local scale = cfg.scale or 1

    for i = 1, (cfg.maxFrames or 4) do
        local frame = frames[i]
        if not frame then
            frame = CreateTankFrame(i)
            frames[i] = frame
        end

        local unit = units[i]
        frame._sfUnit = unit

        if not unit then
            frame:Hide()
            -- Rows hide with the frame (their wrappers are children), but the
            -- container has to be told or it keeps rendering the last tank.
            for _, kind in ipairs({"debuff", "def"}) do
                local w = frame.rows[kind]
                if w and w._container then w._container:Hide() end
            end
        else
            frame:SetScale(scale)
            frame:SetAlpha(cfg.opacity or 1)
            TankTracker.DressFrame(frame, cfg)
            frame:ClearAllPoints()
            local dx, dy = StackOffset(cfg, i)
            frame:SetPoint("CENTER", UIParent, "CENTER",
                ((cfg.anchorX or 0) + dx) / scale, ((cfg.anchorY or 0) + dy) / scale)

            ApplyRow(frame, "debuff", unit)
            ApplyRow(frame, "def", unit)
            frame:Show()
            UpdateHealth(frame)
        end
    end

    -- Frames beyond maxFrames, left over from a higher previous setting.
    for i = (cfg.maxFrames or 4) + 1, #frames do
        if frames[i] then frames[i]:Hide() end
    end

    TankTracker.SetEditMode(SquizzFrames.editMode)
end

-----------------------------------------------------------------------
-- Mover
-----------------------------------------------------------------------

function TankTracker.CreateMover()
    if mover then return mover end
    mover = CreateFrame("Frame", "SquizzFramesTankTrackerMover", UIParent, "BackdropTemplate")
    mover:SetFrameStrata("DIALOG")
    mover:EnableMouse(true)
    mover:Hide()

    local tex = mover:CreateTexture(nil, "BACKGROUND")
    tex:SetAllPoints(mover)
    tex:SetColorTexture(0.99, 0.6, 0.2, 0.3)

    local label = mover:CreateFontString(nil, "OVERLAY")
    label:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    label:SetPoint("CENTER")
    label:SetText("Tank Tracker")

    -- Same drag maths as every other mover in the addon: cursor position in
    -- UIParent's space, saved as raw pixels from screen centre, divided by
    -- scale at apply time. See the coordinate-space-mixing note in CLAUDE.md.
    local dragging, dragX, dragY = false, 0, 0
    local StopDrag

    local function StartDrag(self)
        if dragging then return end
        dragging = true
        local cfg = GetConfig()
        local uiScale = UIParent:GetEffectiveScale()
        local sx, sy = GetCursorPosition()
        sx, sy = sx / uiScale, sy / uiScale
        local sw, sh = GetScreenWidth(), GetScreenHeight()
        local offX = (sw / 2 + ((cfg and cfg.anchorX) or 0)) - sx
        local offY = (sh / 2 + ((cfg and cfg.anchorY) or 0)) - sy
        dragX = (cfg and cfg.anchorX) or 0
        dragY = (cfg and cfg.anchorY) or 0

        self:SetScript("OnUpdate", function(fr)
            if not IsMouseButtonDown("LeftButton") then StopDrag(fr) return end
            local cx, cy = GetCursorPosition()
            local s = UIParent:GetEffectiveScale()
            cx, cy = cx / s, cy / s
            local w2, h2 = GetScreenWidth(), GetScreenHeight()
            dragX = (cx + offX) - w2 / 2
            dragY = (cy + offY) - h2 / 2
            fr:ClearAllPoints()
            fr:SetPoint("CENTER", UIParent, "CENTER", dragX, dragY)
        end)
    end

    function StopDrag(self)
        if not dragging then return end
        dragging = false
        self:SetScript("OnUpdate", nil)
        local cfg = GetConfig()
        if cfg then
            cfg.anchorX = dragX
            cfg.anchorY = dragY
        end
        SquizzFrames:Fire("TankTrackerChanged")
    end

    mover:SetScript("OnMouseDown", function(self, b) if b == "LeftButton" then StartDrag(self) end end)
    mover:SetScript("OnMouseUp", function(self, b) if b == "LeftButton" then StopDrag(self) end end)
    mover:SetScript("OnHide", function(self) StopDrag(self) end)
    return mover
end

-- The handle is shown whenever the tracker is ENABLED, even with no tanks to
-- display. Otherwise the frame could only be positioned while standing next to
-- another tank, which is exactly when you are least able to fiddle with it.
function TankTracker.SetEditMode(enabled)
    local m = mover or TankTracker.CreateMover()
    local cfg = GetConfig()
    if not (enabled and cfg and cfg.enabled) then
        m:Hide()
        return
    end
    local scale = cfg.scale or 1
    m:SetScale(scale)
    m:SetSize(cfg.width or 150, cfg.height or 20)
    m:ClearAllPoints()
    m:SetPoint("CENTER", UIParent, "CENTER",
        (cfg.anchorX or 0) / scale, (cfg.anchorY or 0) / scale)
    m:Show()
end

-----------------------------------------------------------------------
-- Lifecycle
-----------------------------------------------------------------------

function TankTracker:OnEnable()
    if initialized then return end
    initialized = true
    TankTracker.CreateMover()

    -- Roster / role churn rebuilds WHICH units are shown.
    local function Relayout() TankTracker.ApplyLayout() end
    self:RegisterEvent("GROUP_ROSTER_UPDATE", Relayout)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", Relayout)
    self:RegisterEvent("PLAYER_ROLES_ASSIGNED", Relayout)
    self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", Relayout)
    self:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED", Relayout)

    -- Health only: cheaper than a full relayout, and these fire constantly.
    local function OnUnitEvent(_, unit)
        for _, frame in pairs(frames) do
            if frame._sfUnit == unit and frame:IsShown() then UpdateHealth(frame) end
        end
    end
    self:RegisterEvent("UNIT_HEALTH", OnUnitEvent)
    self:RegisterEvent("UNIT_MAXHEALTH", OnUnitEvent)
    self:RegisterEvent("UNIT_NAME_UPDATE", OnUnitEvent)
    self:RegisterEvent("UNIT_CONNECTION", Relayout)

    self:RegisterMessage("TankTrackerChanged", Relayout)
    self:RegisterMessage("ProfileChanged", Relayout)
    -- Blanket opacity slider: alpha only, so no full relayout per drag tick.
    self:RegisterMessage("FrameOpacityChanged", function()
        local cfg = GetConfig()
        local a = (cfg and cfg.opacity) or 1
        for _, frame in pairs(frames) do frame:SetAlpha(a) end
    end)
    -- "EditModeChanged", not "LockChanged": OptionsFrame.lua sets
    -- SquizzFrames.editMode and fires that one. Lock is a separate concept.
    self:RegisterMessage("EditModeChanged", function(_, enabled)
        TankTracker.SetEditMode(enabled)
    end)

    C_Timer.After(0.5, Relayout)
end

-- Both registries. NewModule does NOT put the module on the addon object (see
-- the acemodule-not-exposed note), and SquizzFrames.modules is the table other
-- files reach through -- BuiltIn_Update.lua registers itself the same way.
SquizzFrames.TankTracker = TankTracker
SquizzFrames.modules = SquizzFrames.modules or {}
SquizzFrames.modules["TankTracker"] = TankTracker

-----------------------------------------------------------------------
-- TEMPORARY DIAGNOSTIC: /sfspell [spellID ...]
-----------------------------------------------------------------------
-- Reads the aura flags that decide which debuff FILTER can see a spell --
-- from the spell ID alone, with no aura present, solo, out of any group.
--
-- That is the whole point of it: the flags we need are otherwise only
-- observable on a live AuraData during the encounter, and they are published
-- nowhere (Wowhead omits them, wago.tools renders client-side, the wikis
-- document the field names but never per-spell values).
--
-- Three of them ARE queryable by ID, because Blizzard's own AuraUtil resolves
-- them that way (Blizzard_FrameXMLUtil/AuraUtil.lua):
--
--   C_Spell.IsPriorityAura(id)          -> isPriorityAura. The ONLY open
--                                          question for the "Priority + Boss
--                                          & role" union: boss/role is already
--                                          known false for these debuffs,
--                                          since the boss_role preset shows
--                                          nothing in that fight.
--   C_Secrets.GetSpellAuraSecrecy(id)   -> NeverSecret decides whether a
--                                          spell-ID blacklist can EVER work on
--                                          it. Sated/Exhaustion are NeverSecret
--                                          and filter fine; Stagger evidently
--                                          is not, which is why blacklisting it
--                                          silently did nothing.
--   C_UnitAuras.AuraIsBigDefensive(id)  -> free, same shape, used by the
--                                          defensives row.
--
-- isBossAura and isTankRoleAura have NO by-ID query -- they exist only on a
-- live AuraData -- so they are deliberately absent here rather than faked.
--
-- Both of the first two are UNDOCUMENTED (seen only in Blizzard's own code),
-- so every call is pcall'd and reports "unavailable" rather than assuming.
-- The resolved NAME is printed for each ID on purpose: it is the check that
-- the ID is the applied AURA and not the cast, which is exactly the trap
-- Shredding Shards sets (1295854 is the 3.5s channel; 1295858 is the debuff).
--
-- Temporary. Delete once the filter question is settled.
local SPELL_DIAG_DEFAULTS = {
    1291930,  -- Steady Strikes (First Mate Nama) -- may be the cast, not the aura
    1295854,  -- Shredding Shards -- the 3.5s CHANNEL, here only for contrast
    1295858,  -- Shredding Shards -- the applied debuff, the one that matters
    124275,   -- Light Stagger
    124274,   -- Moderate Stagger
    124273,   -- Heavy Stagger
}

local function SpellDiagLine(id)
    local name
    local okN, n = pcall(function()
        return C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
    end)
    if okN and type(n) == "string" then name = n end

    local priority = "unavailable"
    local okP, p = pcall(function()
        return C_Spell and C_Spell.IsPriorityAura and C_Spell.IsPriorityAura(id)
    end)
    if okP then priority = tostring(p) end

    local secrecy, never = "unavailable", "?"
    local okS, s = pcall(function()
        return C_Secrets and C_Secrets.GetSpellAuraSecrecy and C_Secrets.GetSpellAuraSecrecy(id)
    end)
    if okS then
        secrecy = tostring(s)
        local okE, isNever = pcall(function()
            return Enum and Enum.SecrecyLevel and s == Enum.SecrecyLevel.NeverSecret
        end)
        if okE then never = tostring(isNever) end
    end

    local bigDef = "unavailable"
    local okB, b = pcall(function()
        return C_UnitAuras and C_UnitAuras.AuraIsBigDefensive and C_UnitAuras.AuraIsBigDefensive(id)
    end)
    if okB then bigDef = tostring(b) end

    -- tostring on every value, never "%s" on a raw boolean: in Lua 5.1 that
    -- raises "string expected, got boolean" and would take the whole dump out.
    print(string.format("  %s  %s", tostring(id), name or "|cffff0009UNKNOWN SPELL|r"))
    print(string.format("      priority=%s  secrecy=%s (NeverSecret=%s)  bigDefensive=%s",
        priority, secrecy, never, bigDef))
end

SLASH_SQUIZZSPELLDIAG1 = "/sfspell"
SlashCmdList["SQUIZZSPELLDIAG"] = function(msg)
    local PREFIX = "|cff33cc99[SquizzFrames]|r "
    local ok, err = pcall(function()
        local ids = {}
        for token in tostring(msg or ""):gmatch("%d+") do
            ids[#ids + 1] = tonumber(token)
        end
        if #ids == 0 then
            for _, id in ipairs(SPELL_DIAG_DEFAULTS) do ids[#ids + 1] = id end
        end
        print(PREFIX .. "spell flag dump (" .. tostring(#ids) .. " spells):")
        for _, id in ipairs(ids) do
            SpellDiagLine(id)
        end
    end)
    if not ok then
        print(PREFIX .. "dump FAILED: " .. tostring(err))
    end
    -- Terminator: silence in a loop is indistinguishable from the loop never
    -- having run, so the report always ends with a line proving it did.
    print(PREFIX .. "end of spell flag dump")
end

-----------------------------------------------------------------------
-- TEMPORARY DIAGNOSTIC: /sfauras [unit] [help]
-----------------------------------------------------------------------
-- Dumps the aura flags that exist ONLY on a live AuraData -- isRaid,
-- isBossAura and the three role flags -- for whatever is currently on a unit
-- (default "player"; pass target/focus/party1/... and "help" for buffs).
--
-- Separate from /sfspell because these are per-aura-INSTANCE, not per-spell:
-- no by-ID query exists for them, so they can only be read off a real aura.
-- isRaid in particular has no C_Spell equivalent -- the wiki defines it only
-- as "meets the conditions of the RAID aura filter".
--
-- MUST BE RUN OUT OF COMBAT. On 12.1 AuraData is fully secret while auras are
-- secret, so in combat every field here reads back secret. That is the entire
-- reason the AuraEngine subsystem exists -- it is not a fault in this command,
-- and the header below says so explicitly when it happens.
--
-- SOLO USE, which is the point of it: put a debuff on yourself that you can
-- get without a group -- self-cast Bloodlust/Time Warp leaves Sated for ten
-- minutes, and any world mob's poison or bleed works -- then read how isRaid
-- tracks the dispel type. That relationship is what says whether an
-- UNDISPELLABLE raid debuff could ever pass a RAID filter, and it can be
-- established without setting foot in the raid.
--
-- Temporary. Delete alongside /sfspell.
local function AuraDiagValue(v)
    if v == nil then return "nil" end
    if F and F.IsValueNonSecret and not F.IsValueNonSecret(v) then
        return "|cffff0009secret|r"
    end
    return tostring(v)
end

SLASH_SQUIZZAURADIAG1 = "/sfauras"
SlashCmdList["SQUIZZAURADIAG"] = function(msg)
    local PREFIX = "|cff33cc99[SquizzFrames]|r "
    local ok, err = pcall(function()
        local text = tostring(msg or ""):lower()
        local wantHelpful = text:find("help") ~= nil
        local unit = text:match("(party%d)") or text:match("(raid%d+)")
            or (text:find("target") and "target") or (text:find("focus") and "focus")
            or "player"
        local filter = wantHelpful and "HELPFUL" or "HARMFUL"

        print(string.format("%saura dump: unit=%s filter=%s", PREFIX, unit, filter))
        if not UnitExists(unit) then
            print("  that unit does not exist")
            return
        end

        -- Stated up front, because it changes how every line below reads.
        local secretNow = "?"
        local okS, s = pcall(function()
            return C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret()
        end)
        if okS then secretNow = tostring(s) end
        print("  auras secret right now: " .. secretNow
            .. (secretNow == "true" and "  <- run this OUT OF COMBAT, fields will be unreadable" or ""))

        local i, found = 1, 0
        while true do
            local a = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)
            if not a then break end
            found = found + 1
            print(string.format("  [%d] %s  %s", i,
                AuraDiagValue(a.spellId), AuraDiagValue(a.name)))
            -- isRaid FIRST: it is the whole reason this command exists.
            print(string.format("      isRaid=%s  dispel=%s  boss=%s  tankRole=%s  healRole=%s  dpsRole=%s",
                AuraDiagValue(a.isRaid), AuraDiagValue(a.dispelName),
                AuraDiagValue(a.isBossAura), AuraDiagValue(a.isTankRoleAura),
                AuraDiagValue(a.isHealerRoleAura), AuraDiagValue(a.isDPSRoleAura)))
            print(string.format("      dur=%s  fromPlayerOrPet=%s  canApply=%s  npPersonal=%s  npAll=%s",
                AuraDiagValue(a.duration), AuraDiagValue(a.isFromPlayerOrPlayerPet),
                AuraDiagValue(a.canApplyAura), AuraDiagValue(a.nameplateShowPersonal),
                AuraDiagValue(a.nameplateShowAll)))
            i = i + 1
            if i > 60 then break end
        end
        print(string.format("  (%d auras)", found))
    end)

    if not ok then
        print(PREFIX .. "dump FAILED: " .. tostring(err))
    end
    print(PREFIX .. "end of aura dump")
end
