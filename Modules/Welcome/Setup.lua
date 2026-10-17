--[[ SquizzFrames Setup.lua -- first-run setup (2.0 phase 4)

    Four short steps, as in Squizzumables' UI/Setup.lua: your role, a
    suggested set of extras for it, placing the frames, and picking a theme. A
    new install gets it in place of the old welcome note and popup; anyone else
    can run it from the update note's Run Setup button or with /sf setup. Every
    step can be skipped, and so can the whole thing.

    The suggested set is SUGGESTED, never forced (user decisions 2026-10-16):
    it arrives pre-ticked for the role, every role sees every option, and the
    player ticks what they want. The healer preset is offered here (design
    doc). Unit frames and the Tank Tracker also start ticked if they are
    already on, so re-running setup never switches off something in use.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end
local F = SquizzFrames.F
local W = SquizzFrames.Widgets

local Setup = {}
SquizzFrames.Setup = Setup

local WIDTH, HEIGHT = 520, 380
local TEXT_W = WIDTH - 44
local STEPS = 4

local ROLES = {
    { key = "HEALER",  label = "Healer" },
    { key = "TANK",    label = "Tank" },
    { key = "DAMAGER", label = "Damage" },
}
local ROLE_NAME = { HEALER = "healer", TANK = "tank", DAMAGER = "damage dealer" }

-- What each role gets pre-ticked. A healer gets the healer preset and the
-- Tank Tracker (watching the tanks is the job); a tank the Tank Tracker for
-- the other tank; a damage dealer neither. Unit frames are nobody's default:
-- party and raid frames are what SquizzFrames is for, and replacing the
-- player and target frames is a bigger change than a setup step should make
-- on its own.
local SUGGESTED = {
    HEALER  = { healer = true,  tankTracker = true,  unitFrames = false },
    TANK    = { healer = false, tankTracker = true,  unitFrames = false },
    DAMAGER = { healer = false, tankTracker = false, unitFrames = false },
}

local frame
local state = { step = 1 }

local function Profile()
    return SquizzFrames.db and SquizzFrames.db.profile
end

local function IsOn(key)
    local p = Profile()
    return (p and p[key] and p[key].enabled) == true
end

local function Accent()
    -- F.GetAccentColor returns a colour TABLE ({r, g, b, colorStr}).
    local c = F and F.GetAccentColor and F.GetAccentColor()
    if type(c) == "table" and c.r then return c.r, c.g, c.b end
    return 0.2, 0.8, 0.6
end

local function Text(parent, y, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
    fs:SetWidth(TEXT_W)
    fs:SetJustifyH("LEFT")
    fs:SetSpacing(3)
    return fs
end

local function Dim(fs)
    fs:SetTextColor(W.C4(W.palette.GREY_TEXT))
    return fs
end

-- ----------------------------------------------------------------------------
-- Applying the picks
-- ----------------------------------------------------------------------------

local function ApplyPicks()
    local p = Profile()
    local picks = state.picks
    if not (p and picks) then return end
    -- Turning frames on builds secure frames, which waits for combat to end.
    if InCombatLockdown() then
        local wait = CreateFrame("Frame")
        wait:RegisterEvent("PLAYER_REGEN_ENABLED")
        wait:SetScript("OnEvent", function(self)
            self:UnregisterAllEvents()
            ApplyPicks()
        end)
        return
    end

    if picks.healer and SquizzFrames.ApplyHealerPreset then
        SquizzFrames.ApplyHealerPreset()
    end
    p.tankTracker = p.tankTracker or {}
    if p.tankTracker.enabled ~= picks.tankTracker then
        p.tankTracker.enabled = picks.tankTracker
        SquizzFrames:Fire("TankTrackerChanged")
    end
    p.unitFrames = p.unitFrames or {}
    if p.unitFrames.enabled ~= picks.unitFrames then
        p.unitFrames.enabled = picks.unitFrames
        SquizzFrames:Fire("UnitFramesChanged")
    end
end

local function Finish()
    if SquizzFramesDB then SquizzFramesDB.setupDone = true end
    if SquizzFrames.editMode and SquizzFrames.SetEditModeEnabled then
        SquizzFrames.SetEditModeEnabled(false)
    end
    frame:Hide()
end

-- ----------------------------------------------------------------------------
-- The steps
-- ----------------------------------------------------------------------------

local Render   -- defined below; the steps redraw through it

local function BuildRoleStep(page)
    local head = Text(page, 0, "GameFontNormalLarge")
    head:SetText("Which role do you play?")
    page.note = Dim(Text(page, -30))
    page.note:SetText("Pick the role you play most. It decides what the next step suggests; "
        .. "your party and raid frames work the same whatever you pick.")

    page.buttons = {}
    for i, role in ipairs(ROLES) do
        local b = W.CreateStyledButton(page, role.label, "accent-hover", {140, 30}, function()
            state.role = role.key
            state.picks = nil   -- a new role brings its own suggestions
            Render()
        end)
        b:SetPoint("TOPLEFT", page, "TOPLEFT", (i - 1) * 156, -96)
        b.roleLabel = role.label
        page.buttons[role.key] = b
    end

    page.refresh = function()
        local ar, ag, ab = Accent()
        for key, b in pairs(page.buttons) do
            local fs = b.fontString   -- the styled button's own label
            if key == state.role then
                b:SetText("> " .. b.roleLabel .. " <")
                if fs then fs:SetTextColor(ar, ag, ab) end
            else
                b:SetText(b.roleLabel)
                if fs then fs:SetTextColor(W.C4(W.palette.TEXT)) end
            end
        end
    end
end

local function BuildSetStep(page)
    page.head = Text(page, 0, "GameFontNormalLarge")
    page.note = Dim(Text(page, -30))

    local function Check(y, label, field)
        local cb = W.CreateStyledCheckbox(page, label, nil, function(v)
            state.picks[field] = v and true or false
        end)
        cb:SetPoint("TOPLEFT", page, "TOPLEFT", 0, y)
        return cb
    end
    page.healer      = Check(-86,  "Healer preset: HoTs, dispels, defensives, shields and aggro on each frame", "healer")
    page.tankTracker = Check(-116, "Tank Tracker: each tank's debuffs and defensives, in their own frames", "tankTracker")
    page.unitFrames  = Check(-146, "Unit frames: SquizzFrames' own player, target, focus and boss frames", "unitFrames")

    local presetNote = Dim(Text(page, -180, "GameFontHighlightSmall"))
    presetNote:SetText("The healer preset changes your indicator settings, so leave it unticked if you "
        .. "have set them up yourself.")

    local function Set(cb, v)
        cb:SetChecked(v)
        -- The styled checkbox redraws its switch from GetChecked() on enable.
        local onEnable = cb:GetScript("OnEnable")
        if onEnable then onEnable(cb) end
    end

    page.refresh = function()
        if not state.picks then
            local s = SUGGESTED[state.role]
            state.picks = {
                healer = s.healer,
                tankTracker = s.tankTracker or IsOn("tankTracker"),
                unitFrames = s.unitFrames or IsOn("unitFrames"),
            }
        end
        page.head:SetText("Suggested for a " .. ROLE_NAME[state.role])
        page.note:SetText("Ticked for your role -- tick or untick anything you like. All of it can be "
            .. "changed later in the settings.")
        Set(page.healer, state.picks.healer)
        Set(page.tankTracker, state.picks.tankTracker)
        Set(page.unitFrames, state.picks.unitFrames)
    end
end

local function BuildPlaceStep(page)
    local head = Text(page, 0, "GameFontNormalLarge")
    head:SetText("Put things where you want them")
    local note = Dim(Text(page, -30))
    note:SetText("Edit Mode shows a full party or raid, so you can place the frames before you are in a "
        .. "group, along with everything else SquizzFrames draws. Drag them into place; click one to "
        .. "select it and nudge it with the arrow keys. The game's own Edit Mode (Esc > Edit Mode) "
        .. "turns it on too.")

    local b = W.CreateStyledButton(page, "Edit Mode", "accent-hover", {160, 28}, function()
        if SquizzFrames.SetEditModeEnabled then
            SquizzFrames.SetEditModeEnabled(not SquizzFrames.editMode)
        end
        page.refresh()
    end)
    b:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -124)
    page.refresh = function()
        b:SetText(SquizzFrames.editMode and "Done Editing" or "Edit Mode")
    end
end

local function BuildReadyStep(page)
    local head = Text(page, 0, "GameFontNormalLarge")
    head:SetText("You're set")
    local note = Dim(Text(page, -30))
    note:SetText("Everything is under /sf, with a search box at the top. Click Casting lets you cast "
        .. "straight from the frames, and Indicators decides what each frame shows.\n\n"
        .. "Last thing: pick a look. The theme changes the settings window here and in Squizzumables.")

    local b = W.CreateStyledButton(page, "Choose a Theme", "accent-hover", {160, 28}, function()
        Finish()
        if SquizzFrames.OpenOptionsPage then SquizzFrames.OpenOptionsPage("general") end -- theme is at its top
    end)
    b:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -132)
    page.refresh = function() end
end

-- ----------------------------------------------------------------------------
-- The window
-- ----------------------------------------------------------------------------

local function Build()
    -- Only a COMPLETE build counts: an error part-way must not leave a
    -- half-built window that every later /sf setup trips over.
    if frame and frame.built then return frame end
    if frame then frame:Hide() end

    frame = CreateFrame("Frame", "SquizzFramesSetup", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    W.StylizeFrame(frame, W.palette.DARK_BG, W.palette.POPUP_BORDER)
    -- Shares the login notes queue with the other Squizz addons, so it never
    -- draws through another addon's update note (Welcome.lua).
    local Welcome = SquizzFrames.Welcome
    if Welcome and Welcome.NotesHidden then frame:HookScript("OnHide", Welcome.NotesHidden) end

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, -16)
    title:SetText("SquizzFrames setup")
    title:SetTextColor(Accent())
    frame.title = title

    frame.stepLabel = Dim(frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
    frame.stepLabel:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -22, -20)

    frame.pages = {}
    local builders = { BuildRoleStep, BuildSetStep, BuildPlaceStep, BuildReadyStep }
    for i, build in ipairs(builders) do
        local page = CreateFrame("Frame", nil, frame)
        page:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, -56)
        page:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -22, 56)
        page:Hide()
        build(page)
        frame.pages[i] = page
    end

    local skip = W.CreateStyledButton(frame, "Skip Setup", "accent-hover", {110, 26}, Finish)
    skip:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 22, 16)
    skip:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Skip Setup", 1, 1, 1)
        GameTooltip:AddLine("Close setup and keep the settings as they are. /sf setup runs it again.",
            nil, nil, nil, true)
        GameTooltip:Show()
    end)
    skip:HookScript("OnLeave", function() GameTooltip:Hide() end)

    local nextBtn = W.CreateStyledButton(frame, "Next", "accent-hover", {100, 26}, function()
        if state.step == 2 then ApplyPicks() end
        if state.step >= STEPS then Finish() return end
        state.step = state.step + 1
        Render()
    end)
    nextBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -22, 16)
    frame.nextBtn = nextBtn

    local backBtn = W.CreateStyledButton(frame, "Back", "accent-hover", {90, 26}, function()
        state.step = math.max(1, state.step - 1)
        Render()
    end)
    backBtn:SetPoint("RIGHT", nextBtn, "LEFT", -8, 0)
    frame.backBtn = backBtn

    frame.built = true
    return frame
end

Render = function()
    for i, page in ipairs(frame.pages) do
        page:SetShown(i == state.step)
        if i == state.step and page.refresh then page.refresh() end
    end
    frame.stepLabel:SetText(("Step %d of %d"):format(state.step, STEPS))
    frame.backBtn:SetShown(state.step > 1)
    frame.nextBtn:SetText(state.step >= STEPS and "Finish" or "Next")
end

-- Keep the Edit Mode button's wording right when Edit Mode is turned off
-- elsewhere (combat, the options window, Blizzard's Edit Mode closing).
if F and F.NewMessageOwner then
    F.NewMessageOwner():RegisterMessage("EditModeChanged", function()
        if frame and frame:IsShown() and state.step == 3 then Render() end
    end)
end

--- Open setup from the start. `queued`: the automatic first-run showing, which
--- waits behind another Squizz addon's note rather than drawing over it.
function Setup.Show(queued)
    Build()
    state.step = 1
    state.role = (F and F.GetPlayerSpecRole and F.GetPlayerSpecRole()) or "DAMAGER"
    state.picks = nil
    Render()
    local Welcome = SquizzFrames.Welcome
    if queued and Welcome and Welcome.PresentNotes then
        Welcome.PresentNotes(frame, true)
    else
        frame:Show()
        frame:Raise()
    end
end

SquizzFrames.ShowSetup = Setup.Show
