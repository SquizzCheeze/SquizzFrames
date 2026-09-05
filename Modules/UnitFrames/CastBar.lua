--[[ SquizzFrames UnitFrames CastBar (Phase 2)

    Cast bars for the standalone unit frames. Nothing in this addon had ever
    touched UNIT_SPELLCAST_* before, so this is a genuinely new subsystem
    rather than a variation on something existing.

    WHY THIS DOES NOT LOOK LIKE A CLASSIC CAST BAR.
    The familiar implementation is an OnUpdate computing
        (GetTime() - startTime) / (endTime - startTime)
    and that is unusable on 12.1 for two separate reasons:

      1. startTime/endTime are only readable for the PLAYER. For any other
         unit they come back secret, and that division throws.
      2. notInterruptible is ALSO secret, so `if notInterruptible then` throws
         just as hard.

    The sanctioned replacement is the engine-side StatusBar timer: hand the bar
    a duration OBJECT from UnitCastingDuration/UnitChannelDuration/
    UnitEmpoweredChannelDuration and let it animate C-side, where secrets are
    fine. We never compute progress in Lua at all.

    For the interruptible state, the trick is SetAlphaFromBoolean: it CONSUMES
    a secret boolean without reading it, so a tint texture can be shown or
    hidden by a value we are not allowed to look at. There is no way to branch
    on it, which is why the uninterruptible look is a stacked tint layer rather
    than a different SetStatusBarColor call.

    ONE MORE TRAP, learned from EllesmereUIUnitFrames' own hard-won comment:
    once a secret has driven any part of a bar's render state, reading an alpha
    BACK off that bar returns a secret too, and comparing it throws mid-pass --
    leaving the bar unanchored at screen centre. So this file never reads an
    alpha it wrote; it tracks its own state in plain booleans.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F

local CastBar = {}
SquizzFrames.UnitFrameCastBar = CastBar

local FALLBACK_ICON = 136243 -- Interface\Icons\INV_Misc_QuestionMark

-----------------------------------------------------------------------
-- Width matching
-----------------------------------------------------------------------

-- Frames a cast bar can track the width of. A CURATED list of globals rather
-- than a free-text frame name: a typo would silently resolve to "no match"
-- with nothing on screen to explain why.
--
-- The Cooldown Manager viewers are the point of this feature -- lining a cast
-- bar up with the Essential Cooldowns row is the layout most people are
-- actually after. They live in Blizzard_CooldownViewer, which is load-on-
-- demand, so the global can be nil when we first look; resolution is lazy and
-- retried rather than cached at startup.
CastBar.MATCH_TARGETS = {
    {value = "EssentialCooldownViewer", text = "Essential Cooldowns (CDM)"},
    {value = "UtilityCooldownViewer",   text = "Utility Cooldowns (CDM)"},
    {value = "BuffIconCooldownViewer",  text = "Tracked Buffs - Icons (CDM)"},
    {value = "BuffBarCooldownViewer",   text = "Tracked Buffs - Bars (CDM)"},
    {value = "SquizzFramesUnitFramePlayer", text = "Player Frame"},
    {value = "SquizzFramesUnitFrameTarget", text = "Target Frame"},
    {value = "SquizzFramesUnitFrameFocus",  text = "Focus Frame"},
    {value = "SquizzFramesPartyFrame",      text = "Party/Raid Frames"},
}

-- Frames we've already hooked for live resizing, so the hook is installed
-- exactly once each. WoW hooks cannot be removed, and HookScript is additive,
-- so a second install would stack a duplicate handler forever.
local hookedMatchFrames = {}
local matchResizeCallback

-- Called by UnitFrames.lua so a size change on a tracked frame re-runs the
-- layout. Set once at module init.
function CastBar.SetMatchResizeCallback(fn)
    matchResizeCallback = fn
end

local function EnsureMatchHook(frame)
    if not frame or hookedMatchFrames[frame] then return end
    hookedMatchFrames[frame] = true
    -- The CDM viewers resize themselves as cooldowns come and go, so a
    -- one-shot read at login would go stale the first time your spec's
    -- tracked list changed. OnSizeChanged is non-secure and safe to hook.
    frame:HookScript("OnSizeChanged", function()
        if matchResizeCallback then matchResizeCallback() end
    end)
end

-- Which side of the anchor target the bar sits on, expressed as the pair of
-- points SetPoint needs. Offered as one dropdown instead of two (our point and
-- their point) because the two-dropdown form invites nonsensical combinations
-- and nobody actually wants most of them.
CastBar.ATTACH_SIDES = {
    {value = "BOTTOM", text = "Below"},
    {value = "TOP",    text = "Above"},
    {value = "LEFT",   text = "Left of"},
    {value = "RIGHT",  text = "Right of"},
    {value = "CENTER", text = "Centered on"},
}

-- [side] = {our point, their point}
local ATTACH_POINTS = {
    BOTTOM = {"TOP", "BOTTOM"},
    TOP    = {"BOTTOM", "TOP"},
    LEFT   = {"RIGHT", "LEFT"},
    RIGHT  = {"LEFT", "RIGHT"},
    CENTER = {"CENTER", "CENTER"},
}

-- Set when an "anchor" mode bar asked for a frame that does not exist yet --
-- the Cooldown Manager viewers live in a load-on-demand addon, so the global
-- is genuinely nil until it loads. UnitFrames.lua polls this to schedule a
-- retry rather than leaving the bar stranded on its fallback forever.
CastBar.anchorRetryWanted = false

-- Resolve the configured width, or nil to fall back to the caller's default.
local function ResolveWidth(cfg, frameWidth)
    local mode = cfg.widthMode or "frame"
    if mode == "custom" then
        return (cfg.width and cfg.width > 0) and cfg.width or frameWidth
    elseif mode == "match" then
        local target = cfg.matchFrame and _G[cfg.matchFrame]
        if target and target.GetWidth then
            EnsureMatchHook(target)
            local w = target:GetWidth()
            -- A viewer that exists but has never laid out reports 0; falling
            -- back beats rendering a zero-width bar the user cannot find.
            if w and w > 1 then return w end
        end
        return frameWidth
    end
    return frameWidth
end

-- Every cast event we care about, and what it means. Registered by
-- UnitFrames.lua against this table so the two can't drift.
CastBar.EVENTS = {
    "UNIT_SPELLCAST_START",
    "UNIT_SPELLCAST_STOP",
    "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_SPELLCAST_DELAYED",
    "UNIT_SPELLCAST_CHANNEL_START",
    "UNIT_SPELLCAST_CHANNEL_UPDATE",
    "UNIT_SPELLCAST_CHANNEL_STOP",
    "UNIT_SPELLCAST_EMPOWER_START",
    "UNIT_SPELLCAST_EMPOWER_UPDATE",
    "UNIT_SPELLCAST_EMPOWER_STOP",
    "UNIT_SPELLCAST_INTERRUPTIBLE",
    "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
}

local START_EVENTS = {
    UNIT_SPELLCAST_START = true,
    UNIT_SPELLCAST_CHANNEL_START = true,
    UNIT_SPELLCAST_EMPOWER_START = true,
}
local UPDATE_EVENTS = {
    UNIT_SPELLCAST_DELAYED = true,
    UNIT_SPELLCAST_CHANNEL_UPDATE = true,
    UNIT_SPELLCAST_EMPOWER_UPDATE = true,
}
local STOP_EVENTS = {
    UNIT_SPELLCAST_STOP = true,
    UNIT_SPELLCAST_CHANNEL_STOP = true,
    UNIT_SPELLCAST_EMPOWER_STOP = true,
    UNIT_SPELLCAST_FAILED = true,
    UNIT_SPELLCAST_INTERRUPTED = true,
}

-----------------------------------------------------------------------
-- Construction
-----------------------------------------------------------------------

-- Built once per unit frame, hidden until a cast starts. Deliberately NOT a
-- child of the secure unit button: it is a plain frame parented to UIParent
-- and anchored to the button, so nothing here is combat-protected and a cast
-- bar can appear, resize and re-anchor mid-fight. (A child of a secure frame
-- would inherit its protection for show/hide purposes.)
function CastBar.Create(parent, unit)
    local bar = CreateFrame("StatusBar", "SquizzFramesCastBar" .. unit, UIParent)
    bar:SetFrameStrata("MEDIUM")
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:Hide()
    bar._sfUnit = unit
    bar._sfParent = parent

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(bar)
    bg:SetColorTexture(0, 0, 0, 0.6)
    bar.bg = bg

    -- DRAW ORDER MATTERS HERE, and getting it wrong is not obvious until a
    -- cast is halfway done. A StatusBar's fill texture sits on ARTWORK, so
    -- anything else on ARTWORK is progressively covered as the bar advances --
    -- which is exactly how the icon ended up disappearing mid-cast. Everything
    -- that must stay readable therefore goes on OVERLAY, with explicit
    -- sublevels rather than relying on creation order.
    --
    --   BACKGROUND        bg
    --   ARTWORK           the status bar fill (Blizzard's, not ours)
    --   OVERLAY sub 1     uninterruptible tint (over the fill)
    --   OVERLAY sub 3     icon (over the tint, so it stays legible)
    --   OVERLAY sub 4     spell name / cast time

    -- Uninterruptible tint. A full-bar overlay whose ALPHA is driven straight
    -- from the secret notInterruptible flag via SetAlphaFromBoolean -- we can
    -- never learn its value, only hand it to the engine.
    local shield = bar:CreateTexture(nil, "OVERLAY", nil, 1)
    shield:SetAllPoints(bar)
    shield:SetColorTexture(0.6, 0.6, 0.6, 0.55)
    shield:SetAlpha(0)
    bar.shieldTint = shield

    local icon = bar:CreateTexture(nil, "OVERLAY", nil, 3)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    bar.icon = icon

    local name = bar:CreateFontString(nil, "OVERLAY")
    name:SetDrawLayer("OVERLAY", 4)
    name:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    name:SetJustifyH("LEFT")
    bar.spellName = name

    local time = bar:CreateFontString(nil, "OVERLAY")
    time:SetDrawLayer("OVERLAY", 4)
    time:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    time:SetJustifyH("RIGHT")
    bar.timeText = time

    -- Plain-boolean mirror of what we last drove the tint with. NEVER read
    -- shield:GetAlpha() to answer this -- see the file header.
    bar._shieldOn = false

    bar:SetScript("OnUpdate", function(self)
        if not self._sfActive then
            self:Hide()
            return
        end
        -- SELF-HEAL FOR A UNIT THAT WENT AWAY.
        --
        -- This bar is parented to UIParent, not to its unit frame -- see
        -- Create -- so the frame hiding does NOT take it with it. When a boss
        -- despawns or you leave the instance the token simply stops existing
        -- and no UNIT_SPELLCAST_STOP is ever sent, which left a boss cast bar
        -- frozen on screen mid-cast for the rest of the session.
        local u = self._sfUnit
        if not u or not UnitExists(u) then
            self._sfActive = false
            self._sfCastID = nil
            self:Hide()
            return
        end
        if not self._sfShowTime then return end
        -- The duration object is the ONLY sanctioned way to get remaining
        -- time; SetFormattedText takes it straight and formats C-side, so a
        -- secret remaining time renders without ever being read in Lua.
        local getDuration = self.GetTimerDuration
        local duration = getDuration and getDuration(self)
        if duration and duration.GetRemainingDuration then
            self.timeText:SetFormattedText("%.1f", duration:GetRemainingDuration())
        end
    end)

    return bar
end

-----------------------------------------------------------------------
-- Layout / settings
-----------------------------------------------------------------------

-- Positioned relative to the unit frame it belongs to. Called from
-- UnitFrames.lua's ApplyLayout, so it inherits that function's combat guard
-- even though nothing here strictly needs one.
function CastBar.ApplySettings(bar, parent, t, barTexture)
    if not bar or not parent or not t then return end
    local cfg = t.castBar
    if not cfg or not cfg.enabled then
        bar._sfActive = false
        bar:Hide()
        return
    end

    local w = ResolveWidth(cfg, t.width or 180)
    local h = cfg.height or 16
    bar:SetSize(w, h)
    bar:SetScale(parent:GetScale() or 1)

    CastBar.ApplyPosition(bar, parent, cfg)

    if barTexture then bar:SetStatusBarTexture(barTexture) end
    CastBar.ApplyColor(bar, cfg)

    local sc = cfg.uninterruptibleColor or {0.6, 0.6, 0.6, 0.55}
    bar.shieldTint:SetColorTexture(sc[1] or 0.6, sc[2] or 0.6, sc[3] or 0.6, sc[4] or 0.55)

    -- Icon sits INSIDE the bar against its left edge, so the configured width
    -- is the whole thing -- matching it to another frame (a CDM row) lines the
    -- outer edges up exactly, which it would not if the icon hung off the
    -- side and added to the total.
    local iconInset = 0
    if cfg.showIcon then
        local size = math.max(1, h - 2)
        bar.icon:SetSize(size, size)
        bar.icon:ClearAllPoints()
        bar.icon:SetPoint("LEFT", bar, "LEFT", 1, 0)
        bar.icon:Show()
        iconInset = size + 3
    else
        bar.icon:Hide()
    end

    local fontFile = (F.ResolveFontFile and F.ResolveFontFile(t.font and t.font[1]))
        or "Fonts\\FRIZQT__.TTF"
    local fontSize = cfg.fontSize or 11
    local outline = (t.font and t.font[3]) or "OUTLINE"
    bar.spellName:SetFont(fontFile, fontSize, outline)
    bar.timeText:SetFont(fontFile, fontSize, outline)

    -- Spell name starts clear of the icon rather than under it.
    bar.spellName:ClearAllPoints()
    bar.spellName:SetPoint("LEFT", bar, "LEFT", 3 + iconInset, 0)
    bar.timeText:ClearAllPoints()
    bar.timeText:SetPoint("RIGHT", bar, "RIGHT", -3, 0)

    -- Width-capped so a long spell name can't run under the timer. The icon
    -- eats into the space available for it, hence the inset here too.
    bar.spellName:SetWidth(math.max(10, w - 40 - iconInset))

    -- Stashed so StartCast can re-resolve the colour per cast without having
    -- to reach back into the profile itself.
    bar._sfCfg = cfg
    bar._sfShowName = cfg.showName ~= false
    bar._sfShowTime = cfg.showTime ~= false
    if not bar._sfShowName then bar.spellName:SetText("") end
    if not bar._sfShowTime then bar.timeText:SetText("") end
end

-- Position the bar per its mode. Split out of ApplySettings so the anchor
-- retry path can re-run just this.
--
-- The "anchor" mode is the whole point of the feature: SetPoint against a live
-- frame makes WoW's own anchor chain track it, so moving the target (dragging
-- a CDM row, moving another unit frame) carries the cast bar along with no
-- code of ours involved at all.
function CastBar.ApplyPosition(bar, parent, cfg)
    if not bar or not cfg then return end
    local mode = cfg.positionMode or "frame"
    local ox, oy = cfg.offsetX or 0, cfg.offsetY or 0

    bar:ClearAllPoints()

    if mode == "free" then
        -- Own screen position. Same convention as every other saved position
        -- in the addon: raw pixels from UIParent centre, divided by scale at
        -- apply time.
        local scale = bar:GetScale() or 1
        bar:SetPoint("CENTER", UIParent, "CENTER",
            (cfg.anchorX or 0) / scale, (cfg.anchorY or -300) / scale)
        return
    end

    if mode == "anchor" then
        local target = cfg.attachTo and _G[cfg.attachTo]
        local points = ATTACH_POINTS[cfg.attachSide or "BOTTOM"] or ATTACH_POINTS.BOTTOM
        if target and target.GetObjectType then
            bar:SetPoint(points[1], target, points[2], ox, oy)
            return
        end
        -- Target not loaded yet (Blizzard_CooldownViewer is load-on-demand).
        -- Fall through to frame anchoring so the bar is at least somewhere
        -- sensible, and flag a retry rather than being stuck there.
        CastBar.anchorRetryWanted = true
    end

    -- "frame" mode, and the fallback for an unresolved anchor target.
    if not parent then return end
    if (cfg.anchor or "BOTTOM") == "TOP" then
        bar:SetPoint("BOTTOM", parent, "TOP", ox, oy + 2)
    else
        bar:SetPoint("TOP", parent, "BOTTOM", ox, oy - 2)
    end
end

-- Bar colour: class colour of the CASTING unit when asked for, otherwise the
-- configured colour. Split out of ApplySettings because it also has to run at
-- cast START -- the unit behind a token changes constantly, so a class colour
-- resolved once at layout time would be whoever you were targeting then.
--
-- Class is secret when the unit's identity is restricted, so this takes the
-- same route as UnitFrames' own health colouring: F.IsValueNonSecret gate,
-- then F.GetClassColor, and fall back to the configured colour rather than to
-- GetClassColor's white. type() is NOT a secret check.
function CastBar.ApplyColor(bar, cfg, unit)
    if not bar or not cfg then return end
    local c = cfg.color or {0.9, 0.7, 0.1, 1}
    local r, g, b, a = c[1] or 0.9, c[2] or 0.7, c[3] or 0.1, c[4] or 1

    unit = unit or bar._sfUnit
    if cfg.classColor and unit and UnitExists(unit) and UnitIsPlayer(unit) then
        if F.IsValueNonSecret(F.GetClassFile(unit)) then
            local cc = F.GetClassColor(unit)
            if cc then r, g, b = cc.r, cc.g, cc.b end
        end
    end
    bar:SetStatusBarColor(r, g, b, a)
end

-----------------------------------------------------------------------
-- Mover ("free" position mode only)
-----------------------------------------------------------------------

-- A separate non-secure frame on top of the bar. Unlike the unit frames the
-- bar itself isn't secure, but it IS hidden whenever nothing is casting --
-- which would make it undraggable exactly when you want to place it. So the
-- mover is an independent frame sized to the bar's rect, shown in Edit Mode
-- whether or not a cast is in progress, and it drags the SETTINGS rather than
-- the (possibly hidden) bar.
function CastBar.CreateMover(bar, unit, getConfig, onMoved)
    if bar._sfMover then return bar._sfMover end

    local mover = CreateFrame("Frame", "SquizzFramesCastBarMover" .. unit, UIParent, "BackdropTemplate")
    mover:SetFrameStrata("DIALOG")
    mover:EnableMouse(true)
    mover:Hide()

    -- Kept as fields: SetEditMode recolours and relabels them per position
    -- mode, so a preview handle reads differently from a draggable one.
    local tex = mover:CreateTexture(nil, "BACKGROUND")
    tex:SetAllPoints(mover)
    tex:SetColorTexture(0.99, 0.6, 0.2, 0.3)
    mover._sfTex = tex

    local label = mover:CreateFontString(nil, "OVERLAY")
    label:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    label:SetPoint("CENTER")
    label:SetText(unit .. " cast")
    mover._sfLabel = label

    local dragging, dragX, dragY = false, 0, 0
    local StopDrag

    local function StartDrag(self)
        if dragging then return end
        dragging = true
        local cfg = getConfig()
        local uiScale = UIParent:GetEffectiveScale()
        local sx, sy = GetCursorPosition()
        sx, sy = sx / uiScale, sy / uiScale
        local sw, sh = GetScreenWidth(), GetScreenHeight()
        local offX = (sw / 2 + ((cfg and cfg.anchorX) or 0)) - sx
        local offY = (sh / 2 + ((cfg and cfg.anchorY) or 0)) - sy
        dragX = (cfg and cfg.anchorX) or 0
        dragY = (cfg and cfg.anchorY) or 0

        self:SetScript("OnUpdate", function(f)
            if not IsMouseButtonDown("LeftButton") then StopDrag(f) return end
            local cx, cy = GetCursorPosition()
            local s = UIParent:GetEffectiveScale()
            cx, cy = cx / s, cy / s
            local w, h = GetScreenWidth(), GetScreenHeight()
            dragX = (cx + offX) - w / 2
            dragY = (cy + offY) - h / 2
            local bs = bar:GetScale() or 1
            bar:ClearAllPoints()
            bar:SetPoint("CENTER", UIParent, "CENTER", dragX / bs, dragY / bs)
            f:ClearAllPoints()
            f:SetPoint("CENTER", UIParent, "CENTER", dragX / bs, dragY / bs)
        end)
    end

    function StopDrag(self)
        if not dragging then return end
        dragging = false
        self:SetScript("OnUpdate", nil)
        local cfg = getConfig()
        if cfg then
            cfg.anchorX = dragX
            cfg.anchorY = dragY
        end
        if onMoved then onMoved() end
    end

    mover:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then StartDrag(self) end
    end)
    mover:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then StopDrag(self) end
    end)
    mover:SetScript("OnHide", function(self) StopDrag(self) end)

    bar._sfMover = mover
    return mover
end

-- Edit-mode visibility. Only "free" bars get a mover: one riding a frame has no
-- position of its own to drag, and showing a handle that does nothing is worse
-- than showing none.
-- Edit-mode visibility.
--
-- The bar itself is hidden whenever nothing is casting, which made an attached
-- bar impossible to place: you could not see where it was going to be without
-- starting a cast. So in Edit Mode the handle is shown for EVERY mode, and
-- what changes is whether it can be dragged:
--
--   free            draggable, orange, positioned from its saved anchorX/Y
--   frame / anchor  preview only, grey, mouse DISABLED and pinned to the bar
--
-- Pinning the preview with SetAllPoints(bar) works even though the bar is
-- hidden -- a hidden frame still has a valid rect -- and it means the preview
-- tracks whatever the bar is anchored to for free, including a unit frame
-- being dragged around underneath it in the same Edit Mode session.
--
-- Mouse is disabled rather than the drag scripts being removed: it lets clicks
-- fall through to the unit frame's own mover underneath, which would otherwise
-- be unreachable wherever the two overlap.
function CastBar.SetEditMode(bar, enabled, cfg)
    local mover = bar and bar._sfMover
    if not mover then return end
    if not (enabled and cfg and cfg.enabled) then
        mover:Hide()
        return
    end

    local free = (cfg.positionMode or "frame") == "free"
    mover:SetScale(bar:GetScale() or 1)
    mover:EnableMouse(free)
    mover:SetSize(bar:GetWidth(), bar:GetHeight())
    mover:ClearAllPoints()

    if free then
        local s = bar:GetScale() or 1
        mover:SetPoint("CENTER", UIParent, "CENTER",
            (cfg.anchorX or 0) / s, (cfg.anchorY or -300) / s)
        mover._sfTex:SetColorTexture(0.99, 0.6, 0.2, 0.3)
        mover._sfLabel:SetText(bar._sfUnit .. " cast")
    else
        mover:SetAllPoints(bar)
        -- Visually distinct so it is obvious at a glance which handles can
        -- actually be dragged and which are just showing you a position.
        mover._sfTex:SetColorTexture(0.45, 0.45, 0.5, 0.30)
        mover._sfLabel:SetText(bar._sfUnit .. " cast (attached)")
    end

    mover:Show()
end

-----------------------------------------------------------------------
-- Cast state
-----------------------------------------------------------------------

local function ClearCast(bar)
    bar._sfActive = false
    bar._sfCastID = nil
    bar:Hide()
end

-- Drive the uninterruptible tint from a value we are forbidden to read.
-- `flag` may be a secret boolean straight out of UnitCastingInfo.
local function ApplyShield(bar, flag)
    local tex = bar.shieldTint
    if not tex then return end
    if tex.SetAlphaFromBoolean then
        -- The whole point: consumes the secret without reading it.
        tex:SetAlphaFromBoolean(flag)
        bar._shieldOn = true -- "an alpha we no longer own" -- see header
    else
        -- Pre-12.1 / API missing. `flag` is a plain boolean on such a client,
        -- so a normal branch is safe there and only there.
        tex:SetAlpha(flag and 1 or 0)
        bar._shieldOn = flag and true or false
    end
end

-- Full (re)derivation of whatever the unit is casting right now. Every start
-- event and every identity repaint (target swap, frame show) lands here.
function CastBar.StartCast(bar, unit)
    if not bar or not unit or not UnitExists(unit) then
        if bar then ClearCast(bar) end
        return
    end

    local direction = Enum and Enum.StatusBarTimerDirection
        and Enum.StatusBarTimerDirection.ElapsedTime
    local duration, name, text, texture, notInterruptible, castID
    local _ -- file-local throwaway; without it these become GLOBAL writes

    -- NOTE the return shapes differ between the two calls -- casting has an
    -- extra slot before notInterruptible that channelling does not. Getting
    -- this wrong silently reads the wrong field rather than erroring.
    name, text, texture, _, _, _, _, notInterruptible, _, castID = UnitCastingInfo(unit)
    if name then
        duration = UnitCastingDuration and UnitCastingDuration(unit)
    else
        local isEmpowered
        name, text, texture, _, _, _, notInterruptible, _, isEmpowered, _, castID =
            UnitChannelInfo(unit)
        if isEmpowered then
            duration = UnitEmpoweredChannelDuration and UnitEmpoweredChannelDuration(unit)
        else
            duration = UnitChannelDuration and UnitChannelDuration(unit)
            direction = Enum and Enum.StatusBarTimerDirection
                and Enum.StatusBarTimerDirection.RemainingTime
        end
    end

    if not name then
        ClearCast(bar)
        return
    end

    bar._sfActive = true
    bar._sfCastID = castID

    if bar.SetTimerDuration and duration then
        -- Engine-side animation. This is what makes the bar work at all for a
        -- non-player unit, whose cast clock we are not allowed to read.
        bar:SetTimerDuration(duration, true, direction)
    end

    bar.icon:SetTexture(texture or FALLBACK_ICON)
    if bar._sfShowName then bar.spellName:SetText(text or name) end
    if bar._sfShowTime then bar.timeText:SetText("") end
    ApplyShield(bar, notInterruptible)

    -- Re-resolved per cast, not once at layout: with class colouring on, the
    -- unit behind "target" changes constantly, so a colour picked at layout
    -- time would be whoever you happened to be targeting then.
    if bar._sfCfg then CastBar.ApplyColor(bar, bar._sfCfg, unit) end

    bar:Show()
end

-- Re-derive timing only, for delay/channel-update/empower-update. Guarded on
-- castID so a stale event for a cast that already ended can't revive the bar.
function CastBar.UpdateCast(bar, unit)
    if not bar or not bar._sfActive then return end
    CastBar.StartCast(bar, unit)
end

-- DO NOT reintroduce a castID guard here.
--
-- The cast identifier's ARGUMENT POSITION is different for every event in this
-- family: UNIT_SPELLCAST_STOP and _FAILED carry it first, _CHANNEL_STOP and
-- _INTERRUPTED carry interruptedBy first and the id second, and _EMPOWER_STOP
-- carries empowerComplete AND interruptedBy before it. A single "arg2 is the
-- castID" read is therefore wrong for three of the five, the comparison
-- against the stored id fails, and the stop is discarded -- which is exactly
-- how the bar ended up stuck on screen after a cast finished.
--
-- Re-deriving from UnitCastingInfo/UnitChannelInfo instead is immune to that
-- entirely: StartCast shows whatever the unit is casting NOW, and clears the
-- bar when the answer is nothing. It also self-corrects the case the castID
-- guard existed for -- a stale stop arriving after a new cast has begun finds
-- the new cast still in progress and simply re-shows it.
function CastBar.StopCast(bar, unit)
    if not bar then return end
    CastBar.StartCast(bar, unit)
end

function CastBar.SetInterruptible(bar, interruptible)
    if not bar or not bar._sfActive then return end
    -- These two events carry the state in the EVENT NAME, so unlike the
    -- UnitCastingInfo field this really is a plain boolean.
    ApplyShield(bar, not interruptible)
end

-- One entry point for UnitFrames.lua's dispatcher, so the event-name-to-action
-- mapping lives here next to the functions rather than being duplicated there.
function CastBar.HandleEvent(bar, unit, event)
    if not bar then return end
    if START_EVENTS[event] then
        CastBar.StartCast(bar, unit)
    elseif UPDATE_EVENTS[event] then
        CastBar.UpdateCast(bar, unit)
    elseif STOP_EVENTS[event] then
        CastBar.StopCast(bar, unit)
    elseif event == "UNIT_SPELLCAST_INTERRUPTIBLE" then
        CastBar.SetInterruptible(bar, true)
    elseif event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
        CastBar.SetInterruptible(bar, false)
    else
        -- Pseudo-event (target swap, frame shown): full re-derive.
        CastBar.StartCast(bar, unit)
    end
end
