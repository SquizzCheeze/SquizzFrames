--[[ SquizzFrames PetButton.lua - Secure pet unit button setup ]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F

-- Tooltip + hover/target highlight (2026-08-05: now real border indicators,
-- reusing BuiltIn_Update.lua's CheckHoverHighlight/CheckTargetHighlight
-- as-is -- see OnLoad below for how button.indicators is minimally
-- populated to satisfy them without pulling in the full indicator system).
-- Same _sfHovered + recheck pattern as UnitButton.lua's RecheckHighlights/
-- UnitButton_OnEnter/OnLeave.
local function RecheckHighlights(self)
    local BU = SquizzFrames.modules and SquizzFrames.modules["BuiltIn_Update"]
    if not BU then return end
    if BU.CheckHoverHighlight then BU.CheckHoverHighlight(self) end
    if BU.CheckTargetHighlight then BU.CheckTargetHighlight(self) end
end

-- Border indicators (hover highlight, target highlight, frame border).
--
-- Reuses BuiltIn_Update.lua's CreateBorderIndicator factory and its
-- CheckHoverHighlight/CheckTargetHighlight functions as-is rather than
-- duplicating that logic. Those Check functions only need
-- button.indicators[name] to exist with a table exposing .enabled via
-- _sfTable, so this populates just the keys they need -- pet buttons don't
-- carry the full indicator system.
--
-- All three read the user's LIVE settings. They're universal indicators (see
-- OptionsFrame.lua's comment above FindIndicatorEntryRaid): the Party list is
-- the source of truth and every write mirrors onto Raid, so reading Party's
-- entry is correct in either mode. Hover/target used to be hardcoded
-- white/2px, which meant pet frames visibly ignored border colours the main
-- frames honoured.
--
-- Split out of OnLoad (2026-08-09) so it can be re-run when the user changes
-- a border setting -- see PetFrames.lua's RefreshBorders.
function SquizzFrames.PetButton_ApplyBorders(button)
    if not button then return end
    local BU = SquizzFrames.modules and SquizzFrames.modules["BuiltIn_Update"]
    if not (BU and BU.CreateBorderIndicator) then return end

    button.indicators = button.indicators or {}

    local function BorderSettings(name)
        local p = SquizzFrames.db and SquizzFrames.db.profile
        local list = p and p.layout and p.layout.indicators
        if list then
            for _, t in ipairs(list) do
                if t.indicatorName == name then return t end
            end
        end
        return nil
    end

    local function EnsureBorder(key, frameSuffix, indicatorName)
        local ind = button.indicators[key]
        if not ind then
            ind = BU.CreateBorderIndicator(button, frameSuffix)
            button.indicators[key] = ind
        end
        local t = BorderSettings(indicatorName)
        -- F.ColorRGB, not raw indexing: the stored format is
        -- {mode, r, g, b, a} (e.g. {"custom_color", 0, 0, 0, 1}), so the
        -- colour components start at index 2 with the mode string at index 1.
        -- It also resolves "class_color" entries correctly.
        local r, g, b, a = F.ColorRGB(t and t.color)
        ind:SetColor(r, g, b, a)
        if ind.SetThickness then ind:SetThickness((t and t.thickness) or 2) end
        ind._sfTable = {enabled = (t == nil) or (t.enabled ~= false)}
        return ind, t
    end

    EnsureBorder("hoverHighlight", "HoverHighlight", "hoverHighlight")
    EnsureBorder("targetHighlight", "TargetHighlight", "targetHighlight")

    -- Static decorative border around the whole button. Unlike the two above
    -- it has no Check function driving visibility -- it's simply on or off
    -- per the setting, so show/hide it directly here.
    local frameBorder, fbSettings = EnsureBorder("frameBorder", "FrameBorder", "frameBorder")
    if frameBorder then
        if fbSettings and fbSettings.enabled then
            frameBorder:Show()
        else
            frameBorder:Hide()
        end
    end

    -- Re-run the hover/target checks so a settings change takes effect
    -- immediately instead of waiting for the next mouseover/target swap.
    if BU.CheckHoverHighlight then BU.CheckHoverHighlight(button) end
    if BU.CheckTargetHighlight then BU.CheckTargetHighlight(button) end
end

local function PetButton_OnEnter(self)
    self._sfHovered = true
    RecheckHighlights(self)
    if not (SquizzFrames.db and SquizzFrames.db.profile and SquizzFrames.db.profile.tooltipsEnabled == false) then
        local unit = self.unit or self:GetAttribute("unit")
        if unit then
            GameTooltip_SetDefaultAnchor(GameTooltip, self)
            GameTooltip:SetUnit(unit)
            GameTooltip:Show()
        end
    end
end

local function PetButton_OnLeave(self)
    self._sfHovered = false
    RecheckHighlights(self)
    if GameTooltip then
        GameTooltip:Hide()
    end
end

-- OnLoad for pet button template. Trimmed mirror of UnitButton.lua's
-- SquizzFramesUnitButton_OnLoad -- see that file for the fuller version this
-- is based on (the full indicator/aura system and raid icon are still
-- deliberately absent here; click-casting and hover/target highlight were
-- added 2026-08-05).
function SquizzFramesPetButton_OnLoad(self)
    local name = self:GetName()
    _G[name] = self

    -- Pet buttons are always parented directly to UIParent (never
    -- reparented between Attached/Floating modes -- both modes position via
    -- plain SetPoint only, see PetFrames.lua for why), so there's no
    -- meaningful container strata to inherit the way UnitButton.lua's
    -- OnLoad copies from its actual header/container chain. Hardcode the
    -- same flat MEDIUM every other SquizzFrames frame uses instead.
    self:SetFrameStrata("MEDIUM")

    -- Hover ping support, same recipe as UnitButton.lua's OnLoad (see its
    -- comment for the full "why" -- EllesmereUIRaidFrames-derived fix for
    -- mouseover pings otherwise falling through to the 3D world). Safe here
    -- too: OnLoad only ever fires during out-of-combat pet button creation.
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

    -- Resolve children by _G name lookup as fallback, same convention as
    -- UnitButton.lua (parentKey may not populate reliably for dynamically
    -- created frames).
    self.healthBar = self.healthBar or _G[name .. "HealthBar"]
    self.powerBar  = self.powerBar  or _G[name .. "PowerBar"]
    self.nameText  = self.nameText  or _G[name .. "Name"]

    if self.healthBar then
        self.healthBar:SetMinMaxValues(0, 1)
        self.healthBar:SetValue(0)
    end
    if self.powerBar then
        self.powerBar:SetMinMaxValues(0, 1)
        self.powerBar:SetValue(0)
    end

    -- Dark backdrop behind the bars for contrast, same technique as
    -- UnitButton.lua's healthBackdrop (parented to healthBar so it's grouped
    -- into its strata, but sized to cover the whole button).
    if self.healthBar and not self.healthBackdrop then
        local backdrop = self.healthBar:CreateTexture(nil, "BACKGROUND", nil, -1)
        backdrop:SetAllPoints(self)
        backdrop:SetColorTexture(0, 0, 0, 0.5)
        self.healthBackdrop = backdrop
    end

    -- Power bar background + inset border, mirroring UnitButton.lua's own
    -- powerBackdrop/powerBorder block verbatim (2026-08-09 -- pet frames had
    -- the health backdrop but never got this one, so the power bar rendered
    -- straight onto whatever was behind the frame).
    --
    -- Solid black at full opacity, and the border is drawn INSET rather than
    -- via F.CreateBorder: on a bar this thin, a 1px outside border top and
    -- bottom would add ~40% to its height and read as one thick black band.
    -- See UnitButton.lua's comment for the full reasoning and the Cell
    -- comparison that settled it.
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

    -- Old always-present ADD-mode highlight texture: kept in the template
    -- but never shown anymore, same as UnitButton.xml's own "highlight" --
    -- replaced below by the real border indicators.
    if self.highlight then
        self.highlight:Hide()
    end

    SquizzFrames.PetButton_ApplyBorders(self)

    -- Click-casting (2026-08-05): installs the secure hover snippets
    -- (_onenter/_onleave/_onmousedown -- needs SecureHandlerMouseUpDownTemplate,
    -- see PetButton.xml) that refresh keyboard/wheel binds and the "menu"
    -- attribute. The actual typeN/spellN attribute values get written
    -- separately by ClickCasting:ApplyToAll, once PetFrames.lua's
    -- CollectButtons-equivalent wiring includes this button (see
    -- ClickCasting.lua's CollectButtons and PetFrames.lua's IterateButtons).
    local cc = SquizzFrames.modules and SquizzFrames.modules["ClickCasting"]
    if cc and cc.SetBindingClicks then
        cc.SetBindingClicks(self)
    end

    -- HookScript, not SetScript/XML <OnEnter> -- see PetButton.xml's Scripts
    -- comment for why (SecureHandlerEnterLeaveTemplate's secure snippet
    -- would otherwise be dropped).
    self:HookScript("OnEnter", PetButton_OnEnter)
    self:HookScript("OnLeave", PetButton_OnLeave)
end
