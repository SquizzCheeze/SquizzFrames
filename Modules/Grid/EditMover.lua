--[[ SquizzFrames EditMover.lua -- the 2.0 mover look (phase 3, step 5)

    One look and one set of behaviours for every frame SquizzFrames lets you
    place, the same as Squizzumables' UI/EditMode.lua (user decision: the
    movers conform to Squizzumables'). A copy rather than a shared library for
    now; it can become one when Squizzumables moves onto the shared window.

    What a frame gets while Edit Mode is on:
      * a box in the theme's accent: a faint fill and an edge, its name above
      * hover lights the box up
      * a click selects it: thicker, brighter edge, the name turns white
      * the selected frame nudges with the arrow keys, 1px or 10px with Shift
      * selecting a frame shows its settings in the options window, if that is
        open (through the window's search, which knows every setting's page)

    Dragging is untouched: each mover keeps its own drag handling, and the box
    takes no mouse at all -- it only draws, and listens through HookScript.

    Usage:
      SquizzFrames.EditMover.Show(frame, label, {
          find  = "Party Frames",          -- a search term for its settings
          nudge = function(dx, dy) ... end, -- move by dx, dy (UI units) and save
      })
      SquizzFrames.EditMover.Hide(frame)
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local EditMover = {}
SquizzFrames.EditMover = EditMover

local EDGE = "Interface\\BUTTONS\\WHITE8X8"

local selected          -- the frame the arrow keys move
local keys              -- the keyboard catcher, made on first select

local LOOK = {
    idle     = { fill = 0.06, edge = 0.55, size = 1 },
    hover    = { fill = 0.14, edge = 0.95, size = 1 },
    selected = { fill = 0.20, edge = 1.00, size = 2 },
}

local function Accent()
    local a = SquizzFrames.F and SquizzFrames.F.GetAccentColor and SquizzFrames.F.GetAccentColor()
    if a then return a.r, a.g, a.b end
    return 0.78, 0.65, 0.30
end

local function Paint(frame)
    local m = frame.sfMover
    if not m then return end
    local state = (frame == selected and "selected") or (m.hover and "hover") or "idle"
    local look = LOOK[state]
    local r, g, b = Accent()
    if m.edgeSize ~= look.size then
        m.edgeSize = look.size
        m.box:SetBackdrop({ bgFile = EDGE, edgeFile = EDGE, edgeSize = look.size })
    end
    m.box:SetBackdropColor(r, g, b, look.fill)
    m.box:SetBackdropBorderColor(r, g, b, look.edge)
    if state == "selected" then
        m.label:SetTextColor(1, 1, 1)
    else
        m.label:SetTextColor(r, g, b)
    end
end

local function Keys()
    if keys then return keys end
    keys = CreateFrame("Frame", nil, UIParent)
    keys:Hide()
    keys:SetScript("OnKeyDown", function(self, key)
        local frame = selected
        local m = frame and frame.sfMover
        local step = IsShiftKeyDown() and 10 or 1
        local dx, dy = 0, 0
        if key == "LEFT" then dx = -step
        elseif key == "RIGHT" then dx = step
        elseif key == "UP" then dy = step
        elseif key == "DOWN" then dy = -step
        end
        -- Arrow keys stop here while something is selected; every other key
        -- goes on to the game. Not touched in combat, where this is not
        -- allowed -- and Edit Mode turns itself off in combat anyway.
        local handled = (dx ~= 0 or dy ~= 0) and m and m.opts.nudge
        if not InCombatLockdown() then self:SetPropagateKeyboardInput(not handled) end
        if handled then m.opts.nudge(dx, dy) end
    end)
    return keys
end

-- Show the setting `term` names in the options window, if it is open: the
-- window's search knows the page (and section) of every setting.
local function ShowSettings(term)
    local Shell = LibStub and LibStub("LibSquizzShell-1.0", true)
    local win = Shell and Shell.windows and Shell.windows["SquizzFramesOptionsFrame"]
    if not (win and win.frame:IsShown() and win.Search) then return end
    local hit = win:Search(term)[1]
    if not hit then return end
    win:ShowPage(hit.addon .. ":" .. hit.page)
    if hit.onSelect then hit.onSelect(win) end
end

--- Select `frame` (nil clears it). Shows its settings when the window is open.
function EditMover.Select(frame)
    local old = selected
    selected = frame
    if old and old ~= frame then Paint(old) end
    if frame then Paint(frame) end

    local k = Keys()
    if frame and not InCombatLockdown() then
        k:EnableKeyboard(true)
        k:Show()
    else
        k:EnableKeyboard(false)
        k:Hide()
    end

    local m = frame and frame.sfMover
    if m and m.opts.find then ShowSettings(m.opts.find) end
end

function EditMover.Selected() return selected end

--- Give `frame` its mover box and name. `opts` as in the header.
function EditMover.Show(frame, label, opts)
    if not frame then return end
    local m = frame.sfMover
    if not m then
        m = {}
        frame.sfMover = m

        local box = CreateFrame("Frame", nil, frame, "BackdropTemplate")
        box:SetAllPoints(frame)
        box:EnableMouse(false)
        m.box = box

        -- Its own frame, HIGH at the top of its levels, so the name sits above
        -- overlapping boxes but under the options window (DIALOG). It ignores
        -- the frame's scale and takes the UI's, so a scaled frame does not get
        -- a scaled name.
        local holder = CreateFrame("Frame", nil, frame)
        holder:SetFrameStrata("HIGH")
        holder:SetFrameLevel(9000)
        holder:SetIgnoreParentScale(true)
        holder:SetScale(UIParent:GetEffectiveScale())
        holder:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 3)
        holder:SetSize(260, 14)
        local fs = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, 0)
        fs:SetJustifyH("LEFT")
        m.holder, m.label = holder, fs

        -- Hooked once, and inert whenever the box is not showing.
        frame:HookScript("OnEnter", function(self)
            local mm = self.sfMover
            if mm and mm.active then mm.hover = true; Paint(self) end
        end)
        frame:HookScript("OnLeave", function(self)
            local mm = self.sfMover
            if mm and mm.active then mm.hover = false; Paint(self) end
        end)
        frame:HookScript("OnMouseDown", function(self, button)
            local mm = self.sfMover
            if mm and mm.active and button == "LeftButton" then EditMover.Select(self) end
        end)
    end
    m.opts = opts or {}
    m.active = true
    m.edgeSize = nil
    m.box:SetFrameLevel(frame:GetFrameLevel() + 20)
    m.label:SetText(label or "")
    m.box:Show()
    m.holder:SetScale(UIParent:GetEffectiveScale())
    m.holder:Show()
    Paint(frame)
end

--- Change the name shown above a frame's box.
function EditMover.SetLabel(frame, label)
    local m = frame and frame.sfMover
    if m then m.label:SetText(label or "") end
end

--- Take the box away. Deselects the frame if it was selected.
function EditMover.Hide(frame)
    local m = frame and frame.sfMover
    if not m then return end
    m.active, m.hover = false, false
    m.box:Hide()
    m.holder:Hide()
    if selected == frame then EditMover.Select(nil) end
end
