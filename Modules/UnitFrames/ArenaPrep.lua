--[[
    SquizzFrames - Arena pre-match view

    Before the gates open the opponents do not exist as units yet, so the
    arena frames (secure, shown by RegisterUnitWatch) are hidden. The game
    does know each opponent's SPEC by then, and Blizzard's own arena frames
    show it; hiding those (HideBlizzard.lua) hides that preview too, so this
    draws our own: spec icon, spec and class name, role, on a class-coloured
    bar, in the exact spot of each arena frame.

    Plain frames on UIParent, laid over the secure frames' rects (a secure
    frame's rect is valid while hidden) -- never children of them, which
    would hide with them, and never the other way round, which would make
    the secure frames protected.

    Shown under the same rule as Blizzard's (CompactArenaFrame.lua,
    ArenaPreMatchFramesContainerMixin:UpdateShownState): in an arena match
    that has neither engaged nor finished. That also covers the pause
    between Solo Shuffle rounds.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local ArenaPrep = {}
SquizzFrames.UnitFrameArenaPrep = ArenaPrep

local COUNT = _G.MAX_ARENA_ENEMIES or 5
local FONT = "Fonts\\FRIZQT__.TTF"
local ROLE_TEXTURE = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"

local prepFrames = {}

local function IsSecret(v)
    return issecretvalue and issecretvalue(v) or false
end

local function ArenaConfig()
    local p = SquizzFrames.db and SquizzFrames.db.profile
    local uf = p and p.unitFrames
    if not (uf and uf.enabled ~= false and uf.arena and uf.arena.enabled == true) then return nil end
    return uf.arena
end

-- Blizzard's exact test, so ours shows and hides with theirs.
local function InPreMatch()
    if not (C_PvP and C_PvP.IsMatchConsideredArena and C_PvP.IsMatchConsideredArena()) then return false end
    if not (C_PvP.IsMatchActive() or C_PvP.IsMatchComplete()) then return false end
    if C_PvP.IsMatchComplete() then return false end
    return C_PvP.GetActiveMatchState() ~= Enum.PvPMatchState.Engaged
end

-- specName, className, icon, role, classFile for opponent i, or nil.
local function OpponentSpec(i)
    if not GetArenaOpponentSpec then return nil end
    local specID, gender = GetArenaOpponentSpec(i)
    if not specID or IsSecret(specID) or specID <= 0 then return nil end
    local _, specName, _, icon, role, classFile, className = GetSpecializationInfoByID(specID, gender)
    if not specName or IsSecret(specName) then return nil end
    return specName, className, icon, role, classFile
end

local function BarTexture()
    local PartyFrames = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    return (PartyFrames and PartyFrames.GetBarTexture and PartyFrames.GetBarTexture())
        or "Interface\\TargetingFrame\\UI-StatusBar"
end

local function CreatePrepFrame(i)
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("MEDIUM")
    f:Hide()

    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0, 0, 0, 0.6)

    f.bar = f:CreateTexture(nil, "BORDER")
    f.bar:SetPoint("TOPLEFT", 1, -1)
    f.bar:SetPoint("BOTTOMRIGHT", -1, 1)

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetPoint("TOPLEFT", 1, -1)
    f.icon:SetPoint("BOTTOMLEFT", 1, 1)
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    f.role = f:CreateTexture(nil, "OVERLAY")
    f.role:SetTexture(ROLE_TEXTURE)
    f.role:SetSize(14, 14)
    f.role:SetPoint("RIGHT", -4, 0)

    f.spec = f:CreateFontString(nil, "OVERLAY")
    f.spec:SetFont(FONT, 12, "OUTLINE")
    f.spec:SetJustifyH("LEFT")
    f.spec:SetWordWrap(false)

    f.class = f:CreateFontString(nil, "OVERLAY")
    f.class:SetFont(FONT, 10, "OUTLINE")
    f.class:SetJustifyH("LEFT")
    f.class:SetWordWrap(false)
    f.class:SetTextColor(0.85, 0.85, 0.85, 1)

    prepFrames[i] = f
    return f
end

local function PaintFrame(f, i, anchor)
    local specName, className, icon, role, classFile = OpponentSpec(i)
    if not specName then f:Hide() return end

    -- Same scale as the real frame, so the text sizes match it too.
    f:SetScale(anchor:GetScale() or 1)
    f:ClearAllPoints()
    f:SetAllPoints(anchor)

    local h = anchor:GetHeight() or 34
    f.icon:SetWidth(math.max(1, h - 2))
    f.icon:SetTexture(icon)

    f.bar:SetTexture(BarTexture())
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c then f.bar:SetVertexColor(c.r, c.g, c.b, 0.85) else f.bar:SetVertexColor(0.5, 0.5, 0.5, 0.85) end

    if role == "TANK" or role == "HEALER" or role == "DAMAGER" then
        f.role:SetTexCoord(GetTexCoordsForOldRoleSmallCircle(role))
        f.role:Show()
    else
        f.role:Hide()
    end

    -- Spec on top, class under it, both starting past the icon; one line
    -- when the frame is too short for two.
    local left = h + 4
    f.spec:ClearAllPoints()
    f.class:ClearAllPoints()
    f.spec:SetText(specName)
    f.class:SetText(className or "")
    if h >= 28 then
        f.spec:SetPoint("TOPLEFT", left, -4)
        f.spec:SetPoint("RIGHT", -22, 0)
        f.class:SetPoint("BOTTOMLEFT", left, 4)
        f.class:SetPoint("RIGHT", -22, 0)
        f.class:Show()
    else
        f.spec:SetPoint("LEFT", left, 0)
        f.spec:SetPoint("RIGHT", -22, 0)
        f.class:Hide()
    end
    f:Show()
end

function ArenaPrep.Refresh()
    local show = ArenaConfig() ~= nil and InPreMatch()
    local UF = SquizzFrames.modules and SquizzFrames.modules["UnitFrames"]
    for i = 1, COUNT do
        local f = prepFrames[i]
        local anchor = show and UF and UF.FindButtonByUnit and UF.FindButtonByUnit("arena" .. i)
        if anchor then
            PaintFrame(f or CreatePrepFrame(i), i, anchor)
        elseif f then
            f:Hide()
        end
    end
end

-- A plain event frame of its own: registering on the addon root would share
-- CallbackHandler's (owner, event) slot with Core (see CLAUDE.md).
local events = CreateFrame("Frame")
for _, e in ipairs({
    "PLAYER_ENTERING_WORLD", "ARENA_PREP_OPPONENT_SPECIALIZATIONS",
    "PVP_MATCH_STATE_CHANGED", "PVP_MATCH_ACTIVE", "PVP_MATCH_COMPLETE",
    "ARENA_OPPONENT_UPDATE",
}) do
    events:RegisterEvent(e)
end
events:SetScript("OnEvent", function() ArenaPrep.Refresh() end)

-- Follow the frames. Position and size need nothing (SetAllPoints tracks the
-- real frame live); the Arena tab's switch, scale and height do. The panel
-- announces changes with UnitFramesChanged, which UnitFrames.lua answers
-- with its own LOCAL ApplyLayout -- so the public wrapper is hooked as well
-- for callers that use it, and the message is answered one frame later so
-- that layout has already run. Own message owner (F.NewMessageOwner), never
-- the addon root, for the (owner, message) reason above.
local function RefreshSoon() C_Timer.After(0, ArenaPrep.Refresh) end
SquizzFrames.F.NewMessageOwner():RegisterMessage("UnitFramesChanged", RefreshSoon)
local UF = SquizzFrames.modules and SquizzFrames.modules["UnitFrames"]
if UF and UF.ApplyLayout then
    hooksecurefunc(UF, "ApplyLayout", RefreshSoon)
end
