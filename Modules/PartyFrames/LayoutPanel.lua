--[[ SquizzFrames Layout options page

    A pure shell over profile.layout and profile.appearance -- every control
    reads and writes those trees and then fires "LayoutChanged", which
    PartyFrames.lua turns into a layout pass. Nothing here touches frames
    directly, the same discipline the other panels follow.

    Named LayoutPanel rather than PartyFramesPanel because "Layout" is what the
    page is called in the nav and what anyone looking for it will search for --
    the other panels happen to share a name with their module, this one does
    not. It configures the party/raid frames, hence living in their folder.

    EXTRACTED FROM OptionsFrame.lua (2026-09-10), following Pet Frames. This
    page's BuildLayoutFields was the function that hit Lua's 60-UPVALUE ceiling
    when the health gradient controls were added, and its ~80 accessors were
    the second-largest contributor to the file's 200-ACTIVE-LOCAL ceiling.
    Either failure stops the WHOLE options panel loading. See CLAUDE.md's
    "OptionsFrame.lua is at TWO Lua ceilings".

    A separate file is the real fix rather than collapsing accessors into
    tables: each Lua file is its own main function, so this page now has a
    fresh 200-local and 60-upvalue budget of its own.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local L = SquizzFrames.L
local F = SquizzFrames.F
local W = SquizzFrames.Widgets

local Panel = {}
SquizzFrames.LayoutPanel = Panel

-- Re-declared rather than imported: these panels reach the profile directly
-- instead of sharing a file-local with OptionsFrame, which is what makes each
-- one independent rather than a second file with the same coupling.
local function GetProfile()
    return SquizzFrames.db and SquizzFrames.db.profile
end

-- Layout page state. These moved here with the page: OptionsFrame declared
-- them but only ShowPage read activeLayoutKey, and that now goes through
-- Panel.IsRaidTab() below -- mirroring how the Indicators page already
-- publishes IsRaidTab() for the same shared group-preview logic.
local growthDirDropdown   -- dropdown widget (container) for growth direction
local groupGrowthDropdown -- raid-only: direction the subgroup BLOCKS grow in

-- Which layout sub-table the page's widgets currently read/write: "main"
-- (Party) or "raid" (Raid). Independent of the player's REAL current group
-- state -- lets raid layout be configured without being in a raid.
local activeLayoutKey = "main"
local rebuildLayoutFields -- forward declaration; set by Panel.Build

-- Read by OptionsFrame's ShowPage to point the shared group preview at the
-- right mode. Same contract as IndicatorsPanel.IsRaidTab.
function Panel.IsRaidTab()
    return activeLayoutKey == "raid"
end

-- Every accessor below reads/writes p.layout[activeLayoutKey] instead of a
-- hardcoded p.layout.main, so the same widgets serve both the Party ("main")
-- and Raid ("raid") tabs -- switching activeLayoutKey + calling
-- rebuildLayoutFields() is what actually changes which values are shown.
local function GetActiveLayoutTable()
    local p = GetProfile()
    return p and p.layout and p.layout[activeLayoutKey]
end

local function GetWidth()
    local l = GetActiveLayoutTable()
    return l and l.width or (activeLayoutKey == "raid" and 70 or 100)
end

local function SetWidth(val)
    local l = GetActiveLayoutTable()
    if l then
        l.width = val
        SquizzFrames:Fire("LayoutChanged")
    end
end

local function GetHeight()
    local l = GetActiveLayoutTable()
    return l and l.height or (activeLayoutKey == "raid" and 24 or 40)
end

local function SetHeight(val)
    local l = GetActiveLayoutTable()
    if l then
        l.height = val
        SquizzFrames:Fire("LayoutChanged")
    end
end

local function GetPowerHeight()
    local l = GetActiveLayoutTable()
    return l and l.powerHeight or (activeLayoutKey == "raid" and 3 or 4)
end

local function SetPowerHeight(val)
    local l = GetActiveLayoutTable()
    if l then
        l.powerHeight = val
        SquizzFrames:Fire("LayoutChanged")
    end
end

local function GetOrientation()
    local l = GetActiveLayoutTable()
    return l and l.orientation or "vertical"
end

-- Growth direction dropdown items, filtered by orientation. Horizontal shows
-- Left/Right/Center, vertical shows Up/Down/Center. Available identically
-- for Party and Raid -- for raid, Center growth centers the unit axis
-- within each subgroup (see LayoutRaidGroupHeaders in
-- PartyFrames.lua); group placement itself is unaffected. Defined at file
-- scope so SetOrientation (also file scope) can call it to refresh the
-- dropdown.
local function GetDirectionItems(orientation)
    if orientation == "horizontal" then
        return {
            {value = "RIGHT",    text = L["Right"] or "Right"},
            {value = "LEFT",     text = L["Left"] or "Left"},
            {value = "CENTER_H", text = L["Center (Horizontal)"] or "Center (Horizontal)"},
        }
    else
        return {
            {value = "DOWN",     text = L["Down"] or "Down"},
            {value = "UP",       text = L["Up"] or "Up"},
            {value = "CENTER_V", text = L["Center (Vertical)"] or "Center (Vertical)"},
        }
    end
end

-- Forward declaration. SetOrientation and SetGrowthDirection both call this,
-- and both are defined BEFORE it -- without this the name resolved to a nil
-- global at those two call sites, so changing Orientation on the Layout tab
-- threw "attempt to call a nil value".
local RefreshGroupGrowthDropdown

local function SetOrientation(val)
    local l = GetActiveLayoutTable()
    if l then
        l.orientation = val
        -- If the current growth direction is invalid for the new
        -- orientation, reset it to a valid default so the layout doesn't
        -- break. CENTER_H/CENTER_V are valid for both Party and Raid.
        local gd = l.growthDirection
        local isRaid = (activeLayoutKey == "raid")
        if val == "horizontal" then
            if gd ~= "LEFT" and gd ~= "RIGHT" and gd ~= "CENTER_H" then
                l.growthDirection = "RIGHT"
            end
        else
            if gd ~= "UP" and gd ~= "DOWN" and gd ~= "CENTER_V" then
                l.growthDirection = "DOWN"
            end
        end
        -- Refresh the growth direction dropdown so it shows the correct
        -- options for the new orientation (Up/Down/Center vs Left/Right/Center).
        if growthDirDropdown and growthDirDropdown.dropdown
           and growthDirDropdown.dropdown.RefreshItems then
            local newVal = l.growthDirection
            growthDirDropdown.dropdown:RefreshItems(GetDirectionItems(val))
            -- Sync displayed value to the reset growth direction
            growthDirDropdown.dropdown.selectedValue = newVal
        end
        -- Orientation flips the axis the raid's group blocks sit on, so the
        -- Group Growth dropdown has to swap its Right/Left pair for Down/Up
        -- (or back) and carry the stored value across with it.
        RefreshGroupGrowthDropdown()
        -- Re-anchor to the corner that matches the (possibly reset) growth
        -- direction so the block grows from the correct edge. ONLY when
        -- editing the tab that matches the player's REAL current group
        -- state -- ReanchorContainer reads the container's actual on-screen
        -- position and saves it into GetActiveLayout(), which always
        -- follows real IsInRaid(), NOT this options panel's activeLayoutKey.
        -- Calling it while editing the OTHER (non-live) tab would read the
        -- real container's current position (reflecting whichever mode is
        -- actually rendering) and stomp THAT mode's saved anchor with it --
        -- confirmed bug: editing the Raid tab's Orientation/Growth Direction
        -- while actually solo/partied was silently overwriting the Party
        -- anchor with the container's current (real, party-mode) position.
        if isRaid == IsInRaid() then
            local partyModule = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
            if partyModule and partyModule.ReanchorContainer then
                partyModule:ReanchorContainer()
            end
        end
        SquizzFrames:Fire("LayoutChanged")
    end
end

-- ---------------------------------------------------------------------
-- Raid-only: which way the subgroup BLOCKS grow (the level above growth
-- direction, which is about units inside one block).
-- ---------------------------------------------------------------------

-- The blocks sit on whichever axis the units DON'T, so the pair on offer
-- follows orientation -- and the CENTER growth directions, which pin the unit
-- axis regardless of orientation and therefore flip this too. The rule itself
-- lives in PartyFrames (RaidGroupsAlongX) so this can't drift from the code
-- that actually does the placing.
local function RaidGroupsAlongX(layout)
    local partyModule = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    if partyModule and partyModule.RaidGroupsAlongX then
        return partyModule.RaidGroupsAlongX(layout)
    end
    return (layout and layout.orientation) ~= "horizontal"
end

-- Same intent, other axis -- so flipping orientation keeps a user's choice of
-- "centred" (or "backwards") instead of silently resetting it to the default.
local GROUP_GROWTH_ACROSS = {
    RIGHT = "DOWN", LEFT = "UP", CENTER_H = "CENTER_V",
    DOWN = "RIGHT", UP = "LEFT", CENTER_V = "CENTER_H",
}

-- Coerce a stored value onto the axis the blocks are currently on.
local function NormalizeGroupGrowth(layout, val)
    local alongX = RaidGroupsAlongX(layout)
    local valid = alongX
        and { RIGHT = true, LEFT = true, CENTER_H = true }
        or  { DOWN = true, UP = true, CENTER_V = true }
    if valid[val] then return val end
    local across = GROUP_GROWTH_ACROSS[val]
    if valid[across] then return across end
    return alongX and "RIGHT" or "DOWN"
end

local function GetGroupDirectionItems(layout)
    if RaidGroupsAlongX(layout) then
        return {
            {value = "RIGHT",    text = L["Right"] or "Right"},
            {value = "LEFT",     text = L["Left"] or "Left"},
            {value = "CENTER_H", text = L["Center (Horizontal)"] or "Center (Horizontal)"},
        }
    end
    return {
        {value = "DOWN",     text = L["Down"] or "Down"},
        {value = "UP",       text = L["Up"] or "Up"},
        {value = "CENTER_V", text = L["Center (Vertical)"] or "Center (Vertical)"},
    }
end

local function GetGroupGrowthDirection()
    local l = GetActiveLayoutTable()
    if not l then return "RIGHT" end
    return NormalizeGroupGrowth(l, l.groupGrowthDirection)
end

local function SetGroupGrowthDirection(val)
    local l = GetActiveLayoutTable()
    if not l then return end
    l.groupGrowthDirection = NormalizeGroupGrowth(l, val)
    SquizzFrames:Fire("LayoutChanged")
end

-- Re-point the Group Growth dropdown at the axis the blocks are now on, and
-- carry the stored value across with it. Called from both SetOrientation and
-- SetGrowthDirection, either of which can flip that axis.
function RefreshGroupGrowthDropdown()
    local l = GetActiveLayoutTable()
    if not l or not groupGrowthDropdown or not groupGrowthDropdown.dropdown
       or not groupGrowthDropdown.dropdown.RefreshItems then
        return
    end
    local newVal = NormalizeGroupGrowth(l, l.groupGrowthDirection)
    l.groupGrowthDirection = newVal
    groupGrowthDropdown.dropdown:RefreshItems(GetGroupDirectionItems(l))
    groupGrowthDropdown.dropdown.selectedValue = newVal
end

local function GetGrowthDirection()
    local l = GetActiveLayoutTable()
    return l and l.growthDirection or "DOWN"
end

local function SetGrowthDirection(val)
    local l = GetActiveLayoutTable()
    if l then
        -- Reject growth directions that don't match the current orientation.
        -- CENTER_H/CENTER_V are valid for both Party and Raid now.
        local ori = l.orientation or "vertical"
        local isRaid = (activeLayoutKey == "raid")
        if ori == "horizontal" then
            if val ~= "LEFT" and val ~= "RIGHT" and val ~= "CENTER_H" then
                val = "RIGHT"
            end
        else
            if val ~= "UP" and val ~= "DOWN" and val ~= "CENTER_V" then
                val = "DOWN"
            end
        end
        l.growthDirection = val
        -- CENTER_H/CENTER_V pin the unit axis regardless of orientation, so
        -- picking (or leaving) one can flip which axis the raid's group blocks
        -- sit on -- same refresh SetOrientation does.
        RefreshGroupGrowthDropdown()
        -- Re-anchor to the corner that matches the new growth direction --
        -- ONLY when editing the tab that matches real IsInRaid() (see the
        -- matching comment in SetOrientation for why: ReanchorContainer
        -- always targets whichever mode is REALLY active, so calling it
        -- while editing the other tab would stomp that mode's saved anchor
        -- with the container's current, unrelated on-screen position).
        if isRaid == IsInRaid() then
            local partyModule = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
            if partyModule and partyModule.ReanchorContainer then
                partyModule:ReanchorContainer()
            end
        end
        SquizzFrames:Fire("LayoutChanged")
    end
end

-- Screen anchor point. Operates on activeLayoutKey, so the Party and Raid
-- tabs each set their own -- they're independent layouts with independent
-- positions. Unlike Orientation/Growth Direction above, this is safe to
-- change from the non-live tab: PartyFrames:SetLayoutAnchorPoint writes to
-- the layout it was HANDED (by key) rather than to GetActiveLayout(), so it
-- can't stomp the other mode's anchor.
local ANCHOR_POINT_ITEMS = {
    {value = "CENTER",      text = L["Center"] or "Center"},
    {value = "TOP",         text = L["Top"] or "Top"},
    {value = "BOTTOM",      text = L["Bottom"] or "Bottom"},
    {value = "LEFT",        text = L["Left"] or "Left"},
    {value = "RIGHT",       text = L["Right"] or "Right"},
    {value = "TOPLEFT",     text = L["Top Left"] or "Top Left"},
    {value = "TOPRIGHT",    text = L["Top Right"] or "Top Right"},
    {value = "BOTTOMLEFT",  text = L["Bottom Left"] or "Bottom Left"},
    {value = "BOTTOMRIGHT", text = L["Bottom Right"] or "Bottom Right"},
}

local function GetAnchorPointOpt()
    local l = GetActiveLayoutTable()
    return (l and l.anchorPoint) or "CENTER"
end

local function SetAnchorPointOpt(val)
    local partyModule = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    if partyModule and partyModule.SetLayoutAnchorPoint then
        -- Converts the saved offsets so the frames stay put rather than
        -- teleporting; also fires LayoutChanged itself.
        partyModule:SetLayoutAnchorPoint(activeLayoutKey, val)
    end
end

local function GetSpacing()
    local l = GetActiveLayoutTable()
    return l and l.spacingY or 0
end

local function SetSpacing(val)
    local l = GetActiveLayoutTable()
    if l then
        l.spacingY = val
        SquizzFrames:Fire("LayoutChanged")
    end
end

local function GetGroupSpacing()
    local l = GetActiveLayoutTable()
    return l and l.groupSpacing or 6
end

local function SetGroupSpacing(val)
    local l = GetActiveLayoutTable()
    if l then
        l.groupSpacing = val
        SquizzFrames:Fire("LayoutChanged")
    end
end

-- Raid Size: expected raid size for PREVIEW purposes only (see
-- PartyFrames:SetPreviewMode) -- always targets layout.raid directly since
-- it's a raid-only concept, regardless of which tab is active.
local function GetRaidSize()
    local p = GetProfile()
    local l = p and p.layout and p.layout.raid
    return l and l.raidSize or 40
end

local function SetRaidSize(val)
    local p = GetProfile()
    local l = p and p.layout and p.layout.raid
    if l then l.raidSize = val end
    local partyModule = SquizzFrames.modules and SquizzFrames.modules["PartyFrames"]
    if partyModule and partyModule.RefreshPreviewMode then
        partyModule:RefreshPreviewMode()
    end
end

local function GetHideSelf()
    local l = GetActiveLayoutTable()
    return l and l.hideSelf
end

local function SetHideSelf(checked)
    local l = GetActiveLayoutTable()
    if l then
        l.hideSelf = checked
        SquizzFrames:Fire("LayoutChanged")
    end
end

local function GetSortByRole()
    local l = GetActiveLayoutTable()
    return l and l.sortByRole
end

local function SetSortByRole(checked)
    local l = GetActiveLayoutTable()
    if l then
        l.sortByRole = checked
        SquizzFrames:Fire("LayoutChanged")
        -- Show/hide the role-priority dropdowns below.
        if rebuildLayoutFields then rebuildLayoutFields() end
    end
end

-- Bundled into a single table (rather than separate top-level locals) so
-- BuildLayoutFields only picks up ONE new upvalue referencing this instead
-- of several -- that function already sits close to Lua's 60-upvalue-per-
-- function ceiling (it hosts every Layout-tab accessor), and a handful of
-- extra individual locals was enough to tip it over (silent runtime
-- LUA_WARNING "function ... has more than 60 upvalues").
local RoleOrderUI = {
    DEFAULT = {"TANK", "HEALER", "DAMAGER"},
    ITEMS = {
        {value = "TANK", text = L["Tank"] or "Tank"},
        {value = "HEALER", text = L["Healer"] or "Healer"},
        {value = "DAMAGER", text = L["DPS"] or "DPS"},
    },
}

function RoleOrderUI.Get()
    local l = GetActiveLayoutTable()
    return (l and l.roleOrder) or RoleOrderUI.DEFAULT
end

-- Set the role in priority slot `index` (1/2/3). Swaps with whichever slot
-- currently holds the newly-picked role, so the list always stays a valid
-- 3-way permutation instead of allowing duplicates/gaps.
function RoleOrderUI.SetPriority(index, newRole)
    local l = GetActiveLayoutTable()
    if not l then return end
    if not l.roleOrder then
        l.roleOrder = {RoleOrderUI.DEFAULT[1], RoleOrderUI.DEFAULT[2], RoleOrderUI.DEFAULT[3]}
    end
    local order = l.roleOrder
    local oldRole = order[index]
    if oldRole == newRole then return end
    for i, r in ipairs(order) do
        if r == newRole then
            order[i] = oldRole
            break
        end
    end
    order[index] = newRole
    SquizzFrames:Fire("LayoutChanged")
    if rebuildLayoutFields then rebuildLayoutFields() end
end

local function GetScale()
    local p = GetProfile()
    return p and p.appearance and p.appearance.general and p.appearance.general.scale or 1.0
end

local function SetScale(val)
    local p = GetProfile()
    if p and p.appearance and p.appearance.general then
        p.appearance.general.scale = val
        SquizzFrames:Fire("ScaleChanged")
    end
end

local function GetOutOfRange()
    local p = GetProfile()
    return p and p.appearance and p.appearance.general and p.appearance.general.outOfRangeAlpha or 0.3
end

local function SetOutOfRange(val)
    local p = GetProfile()
    if p and p.appearance and p.appearance.general then
        p.appearance.general.outOfRangeAlpha = val
        SquizzFrames:Fire("LayoutChanged")
    end
end

local function GetBarTexture()
    local p = GetProfile()
    return p and p.appearance and p.appearance.general and p.appearance.general.texture or "Blizzard"
end

local function SetBarTexture(val)
    local p = GetProfile()
    if p and p.appearance and p.appearance.general then
        p.appearance.general.texture = val
        SquizzFrames:Fire("LayoutChanged")
    end
end

-- Fixed list matching EllesmereUIRaidFrames' own curated health/power bar
-- texture set exactly (name-for-name, same order) -- NOT a full enumeration
-- of every statusbar texture registered with LSM by any addon. Ellesmere's
-- own texture picker actually works this same way: its 19 built-ins are a
-- hardcoded list (see EllesmereUIRaidFrames.lua's InitHealthBarTextures),
-- with SharedMedia entries only appended after -- this dropdown intentionally
-- mirrors just the curated 19, not the SharedMedia tail, so it doesn't fill
-- up with unrelated textures every other installed addon happens to register.
-- All 19 are registered under these exact names in Media/Media.lua.
local ELLESMERE_BAR_TEXTURE_ORDER = {
    "None", "Melli (ElvUI)", "Atrocity", "Fade", "Fade Right",
    "Thin Line Top", "Thin Line Bottom", "Beautiful", "Plating", "Divide",
    "Glass", "Gradient Right", "Gradient Left", "Gradient Up", "Gradient Down",
    "Matte", "Sheer", "Blinkii Diamonds", "Kringel Window",
}

local function GetBarTextureItems()
    local items = {}
    for _, name in ipairs(ELLESMERE_BAR_TEXTURE_ORDER) do
        items[#items + 1] = { value = name, text = name }
    end
    return items
end

-- Health/power custom colors are stored in TWO places: fullColor/powerColor
-- (the LIVE render mode -- "class_color" or "custom_color" -- read by
-- PartyFrames.lua's UpdateHealth/UpdatePower) and a separate, persistent
-- customColor field that always remembers the last custom color regardless
-- of which mode is active. Without the separate field, toggling "Use Class
-- Colors" off used to hard-reset to a fixed default every time (confirmed
-- bug: any previously-picked custom color was discarded the moment class
-- color was turned on, since fullColor got overwritten to {"class_color",
-- "any"} with nothing preserving the prior custom values for when it was
-- turned off again).
-- Health gradient accessors. One shared setting under appearance.healthBar, so
-- party, raid and pet bars move together -- nobody wants their party frames
-- green-to-red while their raid frames stay class-coloured.
--
-- Every write goes through LayoutChanged rather than poking frames, matching
-- how the rest of this page behaves.
-- WRAPPED IN A do BLOCK, and that is load-bearing twice over. Lua allows a
-- function 200 active LOCALS and 60 UPVALUES, and this file is at both
-- ceilings; exceeding either fails the WHOLE file to load and takes the
-- options panel with it. Locals declared inside a closed block are released at
-- its end, so only `Grad` survives into the main chunk -- six names become
-- one. Do the same for anything added here later.
local Grad
do
local function GradCfg()
    local p = GetProfile()
    if not (p and p.appearance) then return nil end
    p.appearance.healthBar = p.appearance.healthBar or {}
    p.appearance.healthBar.gradient = p.appearance.healthBar.gradient or {}
    return p.appearance.healthBar.gradient
end

-- Deliberately does NOT materialise the table: opening the page should not
-- write to the profile.
local function GradRead(field, fallback)
    local p = GetProfile()
    local g = p and p.appearance and p.appearance.healthBar
        and p.appearance.healthBar.gradient
    local v = g and g[field]
    if v == nil then return fallback end
    return v
end

local function GradWrite(field, v)
    local g = GradCfg()
    if not g then return end
    g[field] = v
    SquizzFrames:Fire("LayoutChanged")
end

local function GradColorGetter(field, dr, dg, db)
    return function()
        local c = GradRead(field, nil)
        if type(c) ~= "table" then return dr, dg, db, 1 end
        return c[1] or dr, c[2] or dg, c[3] or db, c[4] or 1
    end
end

local function GradColorSetter(field)
    return function(r, g, b, a) GradWrite(field, {r, g, b, a or 1}) end
end

-- ONE table, not twelve locals, and that is a hard requirement rather than
-- tidiness: BuildLayoutFields references these, and twelve separate accessors
-- pushed it past the 60-UPVALUE ceiling. A table costs one upvalue however
-- many fields it carries.
Grad = {
    getEnabled  = function() return GradRead("enabled", false) == true end,
    setEnabled  = function(v) GradWrite("enabled", v) end,
    getStyle    = function() return GradRead("style", "smooth") end,
    setStyle    = function(v) GradWrite("style", v) end,
    getMidpoint = function() return GradRead("midpoint", 0.5) end,
    setMidpoint = function(v) GradWrite("midpoint", v) end,
    getHigh = GradColorGetter("high", 0.10, 0.85, 0.10),
    setHigh = GradColorSetter("high"),
    getMid  = GradColorGetter("mid", 0.95, 0.80, 0.15),
    setMid  = GradColorSetter("mid"),
    getLow  = GradColorGetter("low", 0.85, 0.15, 0.15),
    setLow  = GradColorSetter("low"),
}
end

local function GetHealthClassColor()
    local p = GetProfile()
    return p and p.appearance and p.appearance.healthBar and p.appearance.healthBar.fullColor and p.appearance.healthBar.fullColor[1] == "class_color"
end

local function SetHealthClassColor(checked)
    local p = GetProfile()
    if p and p.appearance and p.appearance.healthBar then
        local hb = p.appearance.healthBar
        if checked then
            hb.fullColor = {"class_color", "any"}
        else
            local c = hb.customColor or {0.2, 0.8, 0.2, 1}
            hb.fullColor = {"custom_color", c[1], c[2], c[3], c[4]}
        end
        SquizzFrames:Fire("LayoutChanged")
    end
end

-- Power bar color is a 3-way mode (class_color / custom_color /
-- blizzard_default -- Blizzard's own stock per-power-type color, mana=blue/
-- rage=red/etc, PartyFrames.lua's UpdatePower already falls through to
-- PowerBarColor for anything that isn't the first two). Health bar stays a
-- plain class-color-vs-custom checkbox (see cb3 above) since health has no
-- equivalent "stock color by type" concept to offer a third mode for.
local POWER_COLOR_MODES = {
    {value = "class_color", text = L["Class Color"] or "Class Color"},
    {value = "custom_color", text = L["Custom Color"] or "Custom Color"},
    {value = "blizzard_default", text = L["Default Blizzard Color"] or "Default Blizzard Color"},
}

local function GetPowerColorMode()
    local p = GetProfile()
    local pb = p and p.appearance and p.appearance.powerBar
    return (pb and pb.powerColor and pb.powerColor[1]) or "custom_color"
end

local function SetPowerColorMode(mode)
    local p = GetProfile()
    local pb = p and p.appearance and p.appearance.powerBar
    if not pb then return end
    if mode == "class_color" then
        pb.powerColor = {"class_color", "any"}
    elseif mode == "blizzard_default" then
        pb.powerColor = {"blizzard_default"}
    else
        local c = pb.customColor or {0.0863, 0.0706, 1, 1} -- #1612FF
        pb.powerColor = {"custom_color", c[1], c[2], c[3], c[4]}
    end
    SquizzFrames:Fire("LayoutChanged")
end

-- Custom (non-class-color) health/power bar colors -- always editable
-- regardless of whether Use Class Colors is currently checked (matches the
-- common pattern of showing both controls). Reads/writes the persistent
-- customColor field; only pushes into the LIVE fullColor/powerColor (and
-- fires a re-render) when custom mode is actually active -- picking a color
-- while class color is checked just updates what custom mode WOULD show
-- next, without silently switching the live mode out from under the
-- checkbox (confirmed bug: it used to always overwrite fullColor to
-- custom_color immediately, regardless of what the checkbox displayed).
local function GetHealthCustomColor()
    local p = GetProfile()
    local hb = p and p.appearance and p.appearance.healthBar
    local c = hb and hb.customColor
    if c then return c[1] or 0.2, c[2] or 0.8, c[3] or 0.2, c[4] or 1 end
    return 0.2, 0.8, 0.2, 1
end

local function SetHealthCustomColor(r, g, b, a)
    local p = GetProfile()
    local hb = p and p.appearance and p.appearance.healthBar
    if hb then
        hb.customColor = {r, g, b, a}
        if hb.fullColor and hb.fullColor[1] ~= "class_color" then
            hb.fullColor = {"custom_color", r, g, b, a}
            SquizzFrames:Fire("LayoutChanged")
        end
    end
end

local function GetPowerCustomColor()
    local p = GetProfile()
    local pb = p and p.appearance and p.appearance.powerBar
    local c = pb and pb.customColor
    if c then return c[1] or 0.0863, c[2] or 0.0706, c[3] or 1, c[4] or 1 end
    return 0.0863, 0.0706, 1, 1 -- #1612FF
end

local function SetPowerCustomColor(r, g, b, a)
    local p = GetProfile()
    local pb = p and p.appearance and p.appearance.powerBar
    if pb then
        pb.customColor = {r, g, b, a}
        if pb.powerColor and pb.powerColor[1] ~= "class_color" then
            pb.powerColor = {"custom_color", r, g, b, a}
            SquizzFrames:Fire("LayoutChanged")
        end
    end
end

-----------------------------------------------------------------------
-- Target Highlight / Hover Highlight -- moved here from the Indicators tab
-- (excluded from IndicatorsPanel.lua's list) since they're simple, always-
-- relevant frame borders that belong with the rest of the frame's
-- appearance settings, matching EllesmereUIRaidFrames' own grouping (their
-- Frame Display section has both target and hover border settings
-- together). Storage is still a normal indicator entry in
-- profile.layout.indicators -- BuiltIn_Update.lua's CheckTargetHighlight/
-- CheckHoverHighlight read it exactly the same way regardless of which
-- options tab edits it. Live updates go through the same
-- SquizzFrames:Fire("UpdateIndicators", ...) message the Indicators tab's
-- own widgets use (Indicators.lua's UpdateIndicators handler applies it to
-- every wired button and updates the stored table).
-----------------------------------------------------------------------

local function FindIndicatorEntry(name)
    local p = GetProfile()
    local list = p and p.layout and p.layout.indicators
    if not list then return nil end
    for _, t in ipairs(list) do
        if t.indicatorName == name then return t end
    end
    return nil
end

-- Target/Hover Highlight and Frame Border are deliberately universal --
-- Party's own list (via FindIndicatorEntry above) is the source of truth
-- for reads, but every WRITE below also mirrors the same value onto Raid's
-- matching entry, so the two never drift apart even though only ONE UI
-- surface (this page, not the per-Party/Raid Designer) ever edits them. The
-- accompanying SquizzFrames:Fire calls omit isRaidContext (nil), which
-- Indicators.lua's CollectAndApply treats as unfiltered -- it reaches every
-- real button regardless of that button's own current party/raid state,
-- same as this whole system behaved before the party/raid split existed.
local function FindIndicatorEntryRaid(name)
    local p = GetProfile()
    local list = p and p.layout and p.layout.indicatorsRaid
    if not list then return nil end
    for _, t in ipairs(list) do
        if t.indicatorName == name then return t end
    end
    return nil
end

local function GetIndicatorEnabled(name)
    local t = FindIndicatorEntry(name)
    return t and t.enabled
end

local function SetIndicatorEnabled(name, checked)
    local t = FindIndicatorEntry(name)
    if t then
        t.enabled = checked
        local tRaid = FindIndicatorEntryRaid(name)
        if tRaid then tRaid.enabled = checked end
        SquizzFrames:Fire("UpdateIndicators", name, "enabled", checked)
    end
end

local function GetIndicatorThickness(name)
    local t = FindIndicatorEntry(name)
    return t and t.thickness or 2
end

local function SetIndicatorThickness(name, val)
    local t = FindIndicatorEntry(name)
    if t then
        t.thickness = val
        local tRaid = FindIndicatorEntryRaid(name)
        if tRaid then tRaid.thickness = val end
        SquizzFrames:Fire("UpdateIndicators", name, "thickness", val)
    end
end

-- F.ColorRGB only recognizes the tagged {"custom_color", r,g,b,a} shape
-- (matches how CreateSetting_ColorAlpha's widget always stores it) -- see
-- Layout_Defaults.lua's comment on targetHighlight's color field.
local function GetIndicatorColor(name)
    local t = FindIndicatorEntry(name)
    return F.ColorRGB(t and t.color)
end

local function SetIndicatorColor(name, r, g, b, a)
    local t = FindIndicatorEntry(name)
    if t then
        t.color = {"custom_color", r, g, b, a}
        local tRaid = FindIndicatorEntryRaid(name)
        if tRaid then tRaid.color = {"custom_color", r, g, b, a} end
        SquizzFrames:Fire("UpdateIndicators", name, "color", t.color)
    end
end

local function GetTargetHighlightEnabled() return GetIndicatorEnabled("targetHighlight") end
local function SetTargetHighlightEnabled(v) SetIndicatorEnabled("targetHighlight", v) end
local function GetTargetHighlightThickness() return GetIndicatorThickness("targetHighlight") end
local function SetTargetHighlightThickness(v) SetIndicatorThickness("targetHighlight", v) end
local function GetTargetHighlightColor() return GetIndicatorColor("targetHighlight") end
local function SetTargetHighlightColor(r, g, b, a) SetIndicatorColor("targetHighlight", r, g, b, a) end

local function GetHoverHighlightEnabled() return GetIndicatorEnabled("hoverHighlight") end
local function SetHoverHighlightEnabled(v) SetIndicatorEnabled("hoverHighlight", v) end
local function GetHoverHighlightThickness() return GetIndicatorThickness("hoverHighlight") end
local function SetHoverHighlightThickness(v) SetIndicatorThickness("hoverHighlight", v) end
local function GetHoverHighlightColor() return GetIndicatorColor("hoverHighlight") end
local function SetHoverHighlightColor(r, g, b, a) SetIndicatorColor("hoverHighlight", r, g, b, a) end

local function GetFrameBorderEnabled() return GetIndicatorEnabled("frameBorder") end
local function SetFrameBorderEnabled(v) SetIndicatorEnabled("frameBorder", v) end
local function GetFrameBorderThickness() return GetIndicatorThickness("frameBorder") end
local function SetFrameBorderThickness(v) SetIndicatorThickness("frameBorder", v) end
local function GetFrameBorderColor() return GetIndicatorColor("frameBorder") end
local function SetFrameBorderColor(r, g, b, a) SetIndicatorColor("frameBorder", r, g, b, a) end

-- Builds (or rebuilds) the actual field widgets for whichever layout is
-- currently selected (activeLayoutKey). Called once at page creation and
-- again every time the Party/Raid toggle is clicked -- old widgets are
-- discarded and recreated rather than trying to refresh each one in place,
-- since a handful of small widgets is cheap to rebuild and this avoids
-- needing a bespoke refresh path on every widget type (sliders, dropdowns,
-- checkboxes).
-- Border sections (Frame Border + Target/Hover Highlight), split out of
-- BuildLayoutFields (2026-08-07).
--
-- NOT cosmetic: Lua caps a function at 60 UPVALUES (distinct enclosing-scope
-- locals it references), and BuildLayoutFields references one Get/Set
-- closure pair per control, so it sat just under the cap and adding the
-- Copy Between Modes section pushed it over -- "function at line 1083 has
-- more than 60 upvalues". These three sections alone account for 18 of
-- them, so moving them here buys back plenty of headroom for future
-- settings. If that warning ever returns, extract another section the same
-- way rather than trying to shave individual references.
--
-- Takes and returns yOffset so the caller's vertical flow is unchanged.
local function BuildBorderSections(fieldsHost, yOffset)
    -- Section: Frame Border -- static decorative border around the whole
    -- button (matches EllesmereUIRaidFrames' general Border Style/Size).
    -- Backed by the "frameBorder" built-in indicator; moved here rather than
    -- the Indicators tab since it's an always-relevant appearance setting.
    W.CreateTitledPane(fieldsHost, L["Frame Border"] or "Frame Border", yOffset)
    yOffset = yOffset - 35

    local cbFB = W.CreateStyledCheckbox(fieldsHost, L["Enabled"] or "Enabled", GetFrameBorderEnabled, SetFrameBorderEnabled)
    cbFB:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    local sliderFB = W.CreateStyledSlider(fieldsHost, 200, 1, 6, 1, L["Border Size"] or "Border Size", GetFrameBorderThickness, SetFrameBorderThickness)
    sliderFB:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 65

    local colorFB = W.CreateColorPicker(fieldsHost, L["Border Color"] or "Border Color", GetFrameBorderColor, SetFrameBorderColor)
    colorFB:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 30

    -- Section: Target / Hover Highlight -- moved here from the Indicators
    -- tab (see the comment above FindIndicatorEntry) -- backed by the
    -- targetHighlight/hoverHighlight built-in indicators. Hover always takes
    -- visual priority over target (see BuiltIn_Update.lua's
    -- CheckTargetHighlight), matching EllesmereUIRaidFrames' own behavior.
    W.CreateTitledPane(fieldsHost, L["Target Highlight"] or "Target Highlight", yOffset)
    yOffset = yOffset - 35

    local cbTH = W.CreateStyledCheckbox(fieldsHost, L["Enabled"] or "Enabled", GetTargetHighlightEnabled, SetTargetHighlightEnabled)
    cbTH:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    local sliderTH = W.CreateStyledSlider(fieldsHost, 200, 1, 6, 1, L["Border Size"] or "Border Size", GetTargetHighlightThickness, SetTargetHighlightThickness)
    sliderTH:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 65

    local colorTH = W.CreateColorPicker(fieldsHost, L["Border Color"] or "Border Color", GetTargetHighlightColor, SetTargetHighlightColor)
    colorTH:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 30

    W.CreateTitledPane(fieldsHost, L["Hover Highlight"] or "Hover Highlight", yOffset)
    yOffset = yOffset - 35

    local cbHH = W.CreateStyledCheckbox(fieldsHost, L["Enabled"] or "Enabled", GetHoverHighlightEnabled, SetHoverHighlightEnabled)
    cbHH:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    local sliderHH = W.CreateStyledSlider(fieldsHost, 200, 1, 6, 1, L["Border Size"] or "Border Size", GetHoverHighlightThickness, SetHoverHighlightThickness)
    sliderHH:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 65

    local colorHH = W.CreateColorPicker(fieldsHost, L["Border Color"] or "Border Color", GetHoverHighlightColor, SetHoverHighlightColor)
    colorHH:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 30

    return yOffset
end

local function BuildLayoutFields(frame)
    if frame.fieldsHost then
        frame.fieldsHost:Hide()
        frame.fieldsHost:SetParent(nil)
        frame.fieldsHost = nil
    end

    local fieldsHost = CreateFrame("Frame", nil, frame)
    fieldsHost:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -34)
    fieldsHost:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    frame.fieldsHost = fieldsHost

    local isRaid = (activeLayoutKey == "raid")
    local yOffset = -10

    -- Section: Copy Between Modes. Party and Raid keep fully separate
    -- settings for layout, indicators AND pet frames, so configuring the
    -- second mode from scratch is a lot of clicking -- this is the one-shot
    -- way across. Two-click arm/confirm (the same pattern the Profiles
    -- page's Delete uses) since it overwrites the other mode wholesale.
    W.CreateTitledPane(fieldsHost, L["Copy Between Modes"] or "Copy Between Modes", yOffset)
    yOffset = yOffset - 35

    do
        local copyDesc = fieldsHost:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        copyDesc:SetPoint("TOPLEFT", 15, yOffset)
        copyDesc:SetWidth(420)
        copyDesc:SetJustifyH("LEFT")
        copyDesc:SetText(L["Copies sizing, layout, indicators and pet frames to the other mode. Each mode keeps its own on-screen position."]
            or "Copies sizing, layout, indicators and pet frames to the other mode. Each mode keeps its own on-screen position.")
        yOffset = yOffset - 30

        -- Direction is fixed by which tab you're on, so there's no way to
        -- get it backwards: you always copy FROM what you're looking at.
        local dir = isRaid and "raidToParty" or "partyToRaid"
        local label = isRaid and (L["Copy Raid to Party..."] or "Copy Raid to Party...")
            or (L["Copy Party to Raid..."] or "Copy Party to Raid...")
        local armed = false
        local copyBtn
        copyBtn = W.CreateStyledButton(fieldsHost, label, "accent-hover", {200, 22}, function()
            local db = SquizzFrames.db
            if not db or not db.CopyBetweenModes then return end
            if not armed then
                armed = true
                copyBtn.fontString:SetText(L["Click again to confirm"] or "Click again to confirm")
                return
            end
            db:CopyBetweenModes(dir)
            armed = false
            copyBtn.fontString:SetText(label)
        end)
        copyBtn:SetPoint("TOPLEFT", 15, yOffset)
        yOffset = yOffset - 40
    end

    -- Section: Sizing
    W.CreateTitledPane(fieldsHost, L["Sizing"] or "Sizing", yOffset)
    yOffset = yOffset - 35

    local slider1 = W.CreateStyledSlider(fieldsHost, 200, 40, 200, 1, L["Width"] or "Width", GetWidth, SetWidth)
    slider1:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 65

    local slider2 = W.CreateStyledSlider(fieldsHost, 200, 20, 100, 1, L["Height"] or "Height", GetHeight, SetHeight)
    slider2:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 65

    local slider3 = W.CreateStyledSlider(fieldsHost, 200, 2, 20, 1, L["Power Bar Height"] or "Power Bar Height", GetPowerHeight, SetPowerHeight)
    slider3:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 65

    -- Section: Layout Options
    W.CreateTitledPane(fieldsHost, L["Layout Options"] or "Layout Options", yOffset)
    yOffset = yOffset - 35

    local slider4 = W.CreateStyledSlider(fieldsHost, 200, 0, 20, 1, L["Spacing"] or "Spacing", GetSpacing, SetSpacing)
    slider4:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 65

    -- Raid-only: gap between subgroup blocks (distinct from Spacing, which is
    -- the gap between units WITHIN one subgroup).
    if isRaid then
        local slider4b = W.CreateStyledSlider(fieldsHost, 200, 0, 40, 1, L["Group Spacing"] or "Group Spacing", GetGroupSpacing, SetGroupSpacing)
        slider4b:SetPoint("TOPLEFT", 15, yOffset - 20)
        yOffset = yOffset - 65
    end

    local dd1 = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Orientation"] or "Orientation", {
        {value = "vertical",   text = L["Vertical"] or "Vertical"},
        {value = "horizontal", text = L["Horizontal"] or "Horizontal"},
    }, GetOrientation, SetOrientation)
    dd1:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 70

    -- Growth direction dropdown. Items are filtered by orientation: horizontal
    -- shows Left/Right/Center, vertical shows Up/Down/Center -- same options
    -- for both Party and Raid. The dropdown is refreshed whenever
    -- orientation changes (SetOrientation).
    local dd = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Growth Direction"] or "Growth Direction",
        GetDirectionItems(GetOrientation()), GetGrowthDirection, SetGrowthDirection)
    growthDirDropdown = dd
    dd:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 70

    -- Raid-only: which way the subgroup BLOCKS grow. Sits directly under
    -- Growth Direction because the two read as a pair -- that one is units
    -- within a group, this one is the groups themselves. Its options follow
    -- whichever axis the blocks are on (see GetGroupDirectionItems), and the
    -- Center entry straddles the anchor so the raid fills out both ways
    -- instead of running off one side.
    if isRaid then
        local ddGroup = W.CreateStyledDropdown(fieldsHost, 200, 40,
            L["Group Growth"] or "Group Growth",
            GetGroupDirectionItems(GetActiveLayoutTable()),
            GetGroupGrowthDirection, SetGroupGrowthDirection)
        groupGrowthDropdown = ddGroup
        ddGroup:SetPoint("TOPLEFT", 15, yOffset - 20)
        yOffset = yOffset - 70
    else
        -- Party has no group blocks; make sure a stale widget from the Raid
        -- tab's last build can't be refreshed behind this page's back.
        groupGrowthDropdown = nil
    end

    -- Screen anchor point (independent per Party/Raid tab). Changing it
    -- re-expresses the saved position against the new point, so the frames
    -- don't move -- see PartyFrames:SetLayoutAnchorPoint.
    local ddAnchor = W.CreateStyledDropdown(fieldsHost, 200, 40,
        L["Anchor Point"] or "Anchor Point",
        ANCHOR_POINT_ITEMS, GetAnchorPointOpt, SetAnchorPointOpt)
    ddAnchor:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 70

    -- Section: Visibility
    W.CreateTitledPane(fieldsHost, L["Visibility"] or "Visibility", yOffset)
    yOffset = yOffset - 35

    local cb1 = W.CreateStyledCheckbox(fieldsHost, L["Hide Self"] or "Hide Self", GetHideSelf, SetHideSelf)
    cb1:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    local cb2 = W.CreateStyledCheckbox(fieldsHost, L["Sort By Role"] or "Sort By Role", GetSortByRole, SetSortByRole)
    cb2:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    if GetSortByRole() then
        local roleOrderLabel = fieldsHost:CreateFontString(nil, "OVERLAY")
        roleOrderLabel:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        roleOrderLabel:SetPoint("TOPLEFT", 30, yOffset)
        roleOrderLabel:SetTextColor(0.7, 0.7, 0.7, 1)
        roleOrderLabel:SetText(L["Role Priority (top = first)"] or "Role Priority (top = first)")
        yOffset = yOffset - 20

        local priorityLabels = {L["1st"] or "1st", L["2nd"] or "2nd", L["3rd"] or "3rd"}
        for i = 1, 3 do
            local ddRole = W.CreateStyledDropdown(fieldsHost, 110, 40, priorityLabels[i], RoleOrderUI.ITEMS,
                function() return (RoleOrderUI.Get())[i] end,
                function(val) RoleOrderUI.SetPriority(i, val) end)
            ddRole:SetPoint("TOPLEFT", 30 + (i - 1) * 125, yOffset - 20)
        end
        yOffset = yOffset - 65
    end

    -- Raid-only: how many units the layout preview mocks up (doesn't affect
    -- real display, which always shows the real roster).
    if isRaid then
        local ddRaidSize = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Raid Size"] or "Raid Size", {
            {value = 10, text = "10"},
            {value = 20, text = "20"},
            {value = 30, text = "30"},
            {value = 40, text = "40"},
        }, GetRaidSize, SetRaidSize)
        ddRaidSize:SetPoint("TOPLEFT", 15, yOffset - 20)
        yOffset = yOffset - 70
    end

    -- Section: Appearance (merged in from the former standalone Appearance
    -- tab -- layout and appearance go hand in hand, and these settings apply
    -- globally regardless of which mode/tab is selected above).
    W.CreateTitledPane(fieldsHost, L["Appearance"] or "Appearance", yOffset)
    yOffset = yOffset - 35

    local slider5 = W.CreateStyledSlider(fieldsHost, 200, 0.5, 2.0, 0.05, L["Scale"] or "Scale", GetScale, SetScale)
    slider5:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 65

    local slider6 = W.CreateStyledSlider(fieldsHost, 200, 0, 1, 0.05, L["Out of Range Alpha"] or "Out of Range Alpha", GetOutOfRange, SetOutOfRange)
    slider6:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 65

    local textureDropdown = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Bar Texture"] or "Bar Texture",
        GetBarTextureItems(), GetBarTexture, SetBarTexture, "statusbar")
    textureDropdown:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 70

    -- HEALTH GRADIENT, above the flat-colour controls because it OVERRIDES
    -- them. Below, and you would be looking at two live-looking colour
    -- controls the bars are ignoring.
    W.CreateTitledPane(fieldsHost, L["Health Gradient"] or "Health Gradient", yOffset)
    yOffset = yOffset - 35

    local cbGrad = W.CreateStyledCheckbox(fieldsHost,
        L["Color by Health"] or "Color by Health",
        Grad.getEnabled, Grad.setEnabled)
    cbGrad:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 24

    local gradNote = fieldsHost:CreateFontString(nil, "OVERLAY")
    gradNote:SetFontObject("GameFontDisableSmall")
    gradNote:SetPoint("TOPLEFT", 32, yOffset)
    gradNote:SetPoint("RIGHT", fieldsHost, "RIGHT", -20, 0)
    gradNote:SetJustifyH("LEFT")
    gradNote:SetText(L["HealthGradientPartyNote"]
        or "Colours party, raid and pet health bars by how hurt someone is instead of by their class. Overrides the colours below while it is on.")
    yOffset = yOffset - 40

    local ddGradStyle = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Style"] or "Style", {
        {value = "smooth", text = L["Smooth blend"] or "Smooth blend"},
        {value = "bands",  text = L["Hard bands"] or "Hard bands"},
    }, Grad.getStyle, Grad.setStyle)
    ddGradStyle:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 70

    local cpGradHigh = W.CreateColorPicker(fieldsHost, L["Full Health"] or "Full Health",
        Grad.getHigh, Grad.setHigh)
    cpGradHigh:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 30

    local cpGradMid = W.CreateColorPicker(fieldsHost, L["Midpoint"] or "Midpoint",
        Grad.getMid, Grad.setMid)
    cpGradMid:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 30

    local cpGradLow = W.CreateColorPicker(fieldsHost, L["Empty"] or "Empty",
        Grad.getLow, Grad.setLow)
    cpGradLow:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 34

    local sGradMid = W.CreateStyledSlider(fieldsHost, 200, 0.05, 0.95, 0.05,
        L["Midpoint At"] or "Midpoint At", Grad.getMidpoint, Grad.setMidpoint)
    sGradMid:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 70

    W.CreateTitledPane(fieldsHost, L["Health Bar Colors"] or "Health Bar Colors", yOffset)
    yOffset = yOffset - 35

    local cb3 = W.CreateStyledCheckbox(fieldsHost, L["Use Class Colors"] or "Use Class Colors", GetHealthClassColor, SetHealthClassColor)
    cb3:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 25

    -- Custom color swatch -- takes effect whenever "Use Class Colors" above
    -- is unchecked.
    local healthColorPicker = W.CreateColorPicker(fieldsHost, L["Custom Color"] or "Custom Color",
        GetHealthCustomColor, SetHealthCustomColor)
    healthColorPicker:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 30

    W.CreateTitledPane(fieldsHost, L["Power Bar Colors"] or "Power Bar Colors", yOffset)
    yOffset = yOffset - 35

    local ddPowerColorMode = W.CreateStyledDropdown(fieldsHost, 200, 40, L["Color Mode"] or "Color Mode",
        POWER_COLOR_MODES, GetPowerColorMode, SetPowerColorMode)
    ddPowerColorMode:SetPoint("TOPLEFT", 15, yOffset - 20)
    yOffset = yOffset - 70

    -- Editable regardless of the mode above -- only takes visual effect once
    -- "Custom Color" is selected (see SetPowerCustomColor's own comment).
    local powerColorPicker = W.CreateColorPicker(fieldsHost, L["Custom Color"] or "Custom Color",
        GetPowerCustomColor, SetPowerCustomColor)
    powerColorPicker:SetPoint("TOPLEFT", 15, yOffset)
    yOffset = yOffset - 30

    -- Frame Border + Target/Hover Highlight live in BuildBorderSections
    -- above -- see its comment (Lua's 60-upvalue-per-function cap).
    yOffset = BuildBorderSections(fieldsHost, yOffset)
end


-- Entry point. The frame is created and registered by OptionsFrame's shim.
function Panel.Build(frame)

    -- Party / Raid toggle -- switches which layout sub-table (profile.layout
    -- .main / .raid) the fields below read and write. Independent of the
    -- player's real current group state, so raid layout can be configured
    -- without actually being in a raid.
    local toggleButtons = {}
    local function RefreshToggleVisual()
        local accent = F.GetAccentColor()
        for key, btn in pairs(toggleButtons) do
            if key == activeLayoutKey then
                btn:SetBackdropColor(accent.r, accent.g, accent.b, 0.55)
            else
                btn:SetBackdropColor(0.115, 0.115, 0.115, 1)
            end
        end
    end

    local function MakeToggleButton(key, label, xOff)
        local btn = CreateFrame("Button", nil, frame, "BackdropTemplate")
        btn:SetSize(90, 22)
        btn:SetPoint("TOPLEFT", frame, "TOPLEFT", xOff, -6)
        W.StylizeFrame(btn, {0.115, 0.115, 0.115, 1}, {0, 0, 0, 0})
        local text = btn:CreateFontString(nil, "OVERLAY")
        text:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        text:SetPoint("CENTER")
        text:SetText(label)
        btn:SetScript("OnClick", function()
            if activeLayoutKey == key then return end
            activeLayoutKey = key
            RefreshToggleVisual()
            if rebuildLayoutFields then rebuildLayoutFields() end
            -- Live preview follows whichever tab is being edited (matches
            -- EllesmereUIRaidFrames' own preview, which resolves from the
            -- currently-open tab, not real group state) -- rebuild it for
            -- the new tab if it's currently showing. No-op when closed.
            local GroupPreview = SquizzFrames.GroupPreview
            if GroupPreview and GroupPreview.SetRaidMode then
                GroupPreview.SetRaidMode(key == "raid")
            end
        end)
        toggleButtons[key] = btn
        return btn
    end

    MakeToggleButton("main", L["Party"] or "Party", 15)
    MakeToggleButton("raid", L["Raid"] or "Raid", 110)
    RefreshToggleVisual()

    -- Preview button -- opens the shared full-group preview window
    -- (GroupPreview.lua), the same one the Indicators tab uses, showing a
    -- full 5-man party or 20-man raid at the configured sizes.
    --
    -- This replaced PartyFrames:SetPreviewMode's older in-world mockup, which
    -- drew stand-in buttons at the frames' real screen position and could be
    -- dragged to set it. Positioning now lives in EDIT MODE, which drags the
    -- real container (so its anchors are correct by construction) and has its
    -- own Party/Raid switch for adjusting either layout. The old preview
    -- system is left intact in PartyFrames.lua but is no longer reachable
    -- from this panel.
    local previewBtn = CreateFrame("Button", nil, frame, "BackdropTemplate")
    previewBtn:SetSize(110, 22)
    previewBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -15, -6)
    W.StylizeFrame(previewBtn, {0.115, 0.115, 0.115, 1}, {0, 0, 0, 0})
    local previewText = previewBtn:CreateFontString(nil, "OVERLAY")
    previewText:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    previewText:SetPoint("CENTER")
    previewText:SetText(L["Show Preview"] or "Show Preview")

    local function RefreshPreviewButtonVisual()
        local GroupPreview = SquizzFrames.GroupPreview
        local active = GroupPreview and GroupPreview.IsShown and GroupPreview.IsShown()
        local accent = F.GetAccentColor()
        if active then
            previewBtn:SetBackdropColor(accent.r, accent.g, accent.b, 0.55)
            previewText:SetText(L["Hide Preview"] or "Hide Preview")
        else
            previewBtn:SetBackdropColor(0.115, 0.115, 0.115, 1)
            previewText:SetText(L["Show Preview"] or "Show Preview")
        end
    end

    previewBtn:SetScript("OnClick", function()
        local GroupPreview = SquizzFrames.GroupPreview
        if not (GroupPreview and GroupPreview.Toggle) then return end
        -- Sync to the tab being edited before showing, so opening it never
        -- flashes the other group type first.
        GroupPreview.SetRaidMode(activeLayoutKey == "raid")
        GroupPreview.Toggle()
    end)
    RefreshPreviewButtonVisual()

    -- Driven by the message rather than set inline, so this stays correct when
    -- the window is closed from somewhere else -- its own X, the Indicators
    -- tab's toggle, or the options panel hiding.
    F.NewMessageOwner():RegisterMessage("GroupPreviewToggled", RefreshPreviewButtonVisual)

    rebuildLayoutFields = function() BuildLayoutFields(frame) end
    rebuildLayoutFields()

    -- Re-sync every slider/dropdown/checkbox's displayed value whenever the
    -- active profile changes (switch/copy/reset) -- BuildLayoutFields was
    -- already rebuild-safe (the Party/Raid toggle already calls it), it
    -- just wasn't wired to this message before.
    F.NewMessageOwner():RegisterMessage("ProfileChanged", function() rebuildLayoutFields() end)
end
