--[[ SquizzFrames UnitButton.lua - Secure unit button setup ]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F

-- Tooltip + highlight for a button. Hooked via HookScript from OnLoad, NOT
-- wired as XML <OnEnter>/<OnLeave>. This frame uses
-- SecureHandlerEnterLeaveTemplate, whose "_onenter" attribute is silently
-- dropped if an insecure OnEnter script handler is set on the frame — that's
-- the mechanism the click-cast binding snippet relies on, so we must use
-- HookScript (which adds alongside the wrap) rather than SetScript or XML, the
-- same approach Cell uses.
-- Hover now drives the Hover Highlight BORDER indicator (BuiltIn_Update.lua)
-- instead of the old always-full-overlay $parentHighlight texture -- matches
-- EllesmereUIRaidFrames' own look (a border, not a wash), and lets hover take
-- visual priority over Target Highlight (same priority Ellesmere uses)
-- instead of the two stacking. The old `self.highlight` texture stays in the
-- template but is simply never shown anymore.
local function RecheckHighlights(self)
    local BU = SquizzFrames.modules and SquizzFrames.modules["BuiltIn_Update"]
    if not BU then return end
    if BU.CheckHoverHighlight then BU.CheckHoverHighlight(self) end
    if BU.CheckTargetHighlight then BU.CheckTargetHighlight(self) end
end

local function UnitButton_OnEnter(self)
    self._sfHovered = true
    RecheckHighlights(self)
    if not (SquizzFrames.db and SquizzFrames.db.profile and SquizzFrames.db.profile.tooltipsEnabled == false) then
        local unit = self.unit or self:GetAttribute("unit")
        if unit then
            -- GameTooltip_SetDefaultAnchor (Blizzard's own helper, used by
            -- the default UI's own unit frames/action bars/etc.) positions
            -- the tooltip according to the player's own Interface Options ->
            -- Tooltip Settings preference (cursor-follow vs. a fixed screen
            -- corner) instead of a hardcoded ANCHOR_RIGHT off the button --
            -- so this now shows up wherever every other tooltip in the game
            -- does for that player, not a fixed spot specific to this addon.
            GameTooltip_SetDefaultAnchor(GameTooltip, self)
            GameTooltip:SetUnit(unit)
            GameTooltip:Show()
        end
    end
end

local function UnitButton_OnLeave(self)
    self._sfHovered = false
    RecheckHighlights(self)
    if GameTooltip then
        GameTooltip:Hide()
    end
end

-- OnLoad for unit button template
function SquizzFramesUnitButton_OnLoad(self)
    -- Store reference in global scope for secure template lookups
    local name = self:GetName()
    _G[name] = self

    -- Strata isn't inherited from parent in WoW -- every frame independently
    -- defaults to MEDIUM unless told otherwise, same strata nameplates use.
    -- Match the header's (which matches the container's -- see
    -- PartyFrames.lua's CreatePartyContainer comment for the full nameplate-
    -- strata fix history) so buttons don't render underneath nameplates. A
    -- frame-LEVEL-based alternative was tried and confirmed unreliable
    -- (2026-07-31 user report) -- nameplates re-raise their own level
    -- constantly via a "toplevel" mechanic whenever interacted with, so
    -- level is a losing fight; strata (a different tier entirely) isn't
    -- subject to that.
    local parent = self:GetParent()
    if parent then
        self:SetFrameStrata(parent:GetFrameStrata())
    end

    -- Hover ping support (bug fix 2026-07-30, user report: pinging a party
    -- member's frame did nothing). Without this, a mouseover ping falls
    -- through our frame to the 3D world behind it -- WoW's ping system only
    -- targets a unit when the moused-over frame is explicitly flagged as a
    -- ping receiver, it's not automatic for a custom secure unit button.
    -- Recipe (confirmed working via EllesmereUIRaidFrames' own identical
    -- implementation): mix in the pingable-unit type, set the secure
    -- "ping-receiver" attribute, and resolve the target GUID live from this
    -- button's own "unit" attribute (same source every other update path
    -- reads) so it always tracks the current occupant after roster
    -- changes/sorts. Returning nil when there's no unit lets the ping
    -- correctly fall through to the world. The GUID must be handed to the
    -- ping system raw, never compared/stringified (may be a secret value).
    -- Safe to set up here in OnLoad: this button is our own secure template,
    -- and OnLoad only ever fires during the out-of-combat initial 40-button
    -- pre-creation (see CreateHeader), never mid-combat.
    if PingableType_UnitFrameMixin then
        Mixin(self, PingableType_UnitFrameMixin)
        self:SetAttribute("ping-receiver", true)
        self.GetTargetPingGUID = function(btn)
            local u = btn.unit or btn:GetAttribute("unit")
            if u and UnitExists(u) then
                return UnitGUID(u)
            end
        end
    end

    -- Resolve children by _G name lookup as fallback (parentKey may not
    -- populate for dynamically-created SecureGroupHeaderTemplate children).
    self.healthBar      = self.healthBar      or _G[name .. "HealthBar"]
    self.powerBar       = self.powerBar       or _G[name .. "PowerBar"]
    self.nameText       = self.nameText       or _G[name .. "Name"]
    self.statusText     = self.statusText     or _G[name .. "Status"]
    self.healthText     = self.healthText     or _G[name .. "HealthText"]
    self.roleIcon       = self.roleIcon       or _G[name .. "RoleIcon"]
    self.raidIcon       = self.raidIcon       or _G[name .. "RaidIcon"]

    -- StatusBars handle their own fill via SetMinMaxValues/SetValue at C level.
    -- Just ensure they start empty.
    if self.healthBar then
        self.healthBar:SetMinMaxValues(0, 1)
        self.healthBar:SetValue(0)
    end
    if self.powerBar then
        self.powerBar:SetMinMaxValues(0, 1)
        self.powerBar:SetValue(0)
    end

    -- Dark backdrop behind the bars for contrast. Created here (rather than
    -- as a Layer region in UnitButton.xml) and parented to healthBar
    -- specifically so it's grouped into health bar's BACKGROUND strata (see
    -- UnitButton.xml) -- keeping it behind the bar fill regardless of frame
    -- level. It still covers the whole button (anchored to `self`, not to
    -- healthBar's own rect) to match the original full-button backdrop.
    if self.healthBar and not self.healthBackdrop then
        local backdrop = self.healthBar:CreateTexture(nil, "BACKGROUND", nil, -1)
        backdrop:SetAllPoints(self)
        backdrop:SetColorTexture(0, 0, 0, 0.5)
        self.healthBackdrop = backdrop
    end

    -- Power bar background + border, scoped to just its own rect (unlike
    -- healthBackdrop above, which already covers the whole button) so it
    -- reads as a distinct element from the health bar above it. Solid black
    -- (full opacity) -- there's no user-facing option to adjust this, and a
    -- translucent fill let whatever's behind the frame show through.
    --
    -- The border is drawn INSET (inside the bar's own 5px rect, not added
    -- outside it) rather than via F.CreateBorder, which draws OUTSIDE its
    -- host -- on an element this thin, a 1px-out top+bottom border adds 2px
    -- to a 5px bar (a ~40% height increase), reading as one thick black
    -- band rather than a thin outline. Confirmed via user report + Cell
    -- comparison screenshot: Cell doesn't even use a dedicated border
    -- texture on its power bar at all -- it insets the bar slightly from
    -- the button edge and lets the button's OWN thin outer border show
    -- through the gap. An inset overlay is the closer match without
    -- restructuring the anchor layout to add that gap.
    if self.powerBar and not self.powerBackdrop then
        local backdrop = self.powerBar:CreateTexture(nil, "BACKGROUND", nil, -1)
        backdrop:SetAllPoints(self.powerBar)
        backdrop:SetColorTexture(0, 0, 0, 1)
        self.powerBackdrop = backdrop

        local border = {
            top = self.powerBar:CreateTexture(nil, "OVERLAY"),
            bottom = self.powerBar:CreateTexture(nil, "OVERLAY"),
            left = self.powerBar:CreateTexture(nil, "OVERLAY"),
            right = self.powerBar:CreateTexture(nil, "OVERLAY"),
        }
        for _, tex in pairs(border) do
            tex:SetColorTexture(0, 0, 0, 1)
        end
        border.top:SetPoint("TOPLEFT", self.powerBar, "TOPLEFT", 0, 0)
        border.top:SetPoint("TOPRIGHT", self.powerBar, "TOPRIGHT", 0, 0)
        border.top:SetHeight(1)
        border.bottom:SetPoint("BOTTOMLEFT", self.powerBar, "BOTTOMLEFT", 0, 0)
        border.bottom:SetPoint("BOTTOMRIGHT", self.powerBar, "BOTTOMRIGHT", 0, 0)
        border.bottom:SetHeight(1)
        border.left:SetPoint("TOPLEFT", self.powerBar, "TOPLEFT", 0, 0)
        border.left:SetPoint("BOTTOMLEFT", self.powerBar, "BOTTOMLEFT", 0, 0)
        border.left:SetWidth(1)
        border.right:SetPoint("TOPRIGHT", self.powerBar, "TOPRIGHT", 0, 0)
        border.right:SetPoint("BOTTOMRIGHT", self.powerBar, "BOTTOMRIGHT", 0, 0)
        border.right:SetWidth(1)
        self.powerBorder = border
    end

    -- Hide selection by default
    if self.selection then
        self.selection:Hide()
    end

    -- Hide highlight overlay; it shows on mouseover via OnEnter/OnLeave
    if self.highlight then
        self.highlight:Hide()
    end

    -- Install click-casting secure hover snippets (_onenter / _onleave /
    -- _onmousedown) so keyboard/wheel binds refresh on hover and the menu
    -- attribute toggles correctly in combat. The ClickCasting module sets the
    -- "snippet" attribute from the current binding set.
    local cc = SquizzFrames.modules and SquizzFrames.modules["ClickCasting"]
    if cc and cc.SetBindingClicks then
        cc.SetBindingClicks(self)
    end

    -- Hook (not replace) the tooltip/highlight scripts. HookScript runs
    -- alongside the secure "_onenter" wrap; XML <OnEnter> or SetScript would
    -- replace it and break click-casting.
    self:HookScript("OnEnter", UnitButton_OnEnter)
    self:HookScript("OnLeave", UnitButton_OnLeave)
end
