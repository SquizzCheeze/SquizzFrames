--[[ SquizzFrames Options.lua - AceConfig options table (fallback for /sf) ]]
-- Primary UI is the custom frame in OptionsFrame.lua; this AceConfig table
-- is only registered for the /sf slash command as a fallback.
-- NOTE: /squizz is NOT registered — it belongs to Squizzumables.

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local L = SquizzFrames.L
local LibStub = LibStub

-- LSM for font/statusbar lists
local LSM = LibStub and LibStub:GetLibrary("LibSharedMedia-3.0", true)

local function GetLSMList(mediaType)
    local list = {}
    if LSM then
        local lsmList = LSM:List(mediaType)
        for _, key in ipairs(lsmList) do
            list[key] = LSM:Fetch(mediaType, key)
        end
    end
    return list
end

-- Build options table
SquizzFrames.options = {
    name = "SquizzFrames",
    handler = SquizzFrames,
    type = "group",
    childGroups = "tab",
    args = {
        general = {
            name = L["General"],
            type = "group",
            order = 1,
            args = {
                hideBlizzardParty = {
                    name = L["Hide Blizzard Party"],
                    desc = "Hide the default Blizzard party frames",
                    type = "toggle",
                    width = "full",
                    order = 1,
                    get = function()
                        return SquizzFrames.db.profile.general.hideBlizzardParty
                    end,
                    set = function(_, val)
                        SquizzFrames.db.profile.general.hideBlizzardParty = val
                        if SquizzFrames.HideBlizzard then
                            SquizzFrames:HideBlizzard()
                        end
                    end,
                },
                hideBlizzardRaid = {
                    name = L["Hide Blizzard Raid"],
                    desc = "Hide the default Blizzard raid frames",
                    type = "toggle",
                    width = "full",
                    order = 2,
                    get = function()
                        return SquizzFrames.db.profile.general.hideBlizzardRaid
                    end,
                    set = function(_, val)
                        SquizzFrames.db.profile.general.hideBlizzardRaid = val
                        if SquizzFrames.HideBlizzard then
                            SquizzFrames:HideBlizzard()
                        end
                    end,
                },
                locked = {
                    name = L["Lock Frames"],
                    desc = "Lock or unlock frame movement",
                    type = "toggle",
                    width = "full",
                    order = 3,
                    get = function()
                        return SquizzFrames.locked
                    end,
                    set = function(_, val)
                        SquizzFrames.locked = val
                        SquizzFrames:Fire("LockChanged", val)
                    end,
                },
            },
        },
        layout = {
            name = L["Layout"],
            type = "group",
            order = 2,
            args = {
                orientation = {
                    name = L["Orientation"],
                    type = "select",
                    width = 1.2,
                    order = 1,
                    values = {
                        vertical = L["Vertical"],
                        horizontal = L["Horizontal"],
                    },
                    get = function()
                        return SquizzFrames.db.profile.layout.main.orientation
                    end,
                    set = function(_, val)
                        SquizzFrames.db.profile.layout.main.orientation = val
                        SquizzFrames:UpdateLayout()
                    end,
                },
                width = {
                    name = L["Width"],
                    type = "range",
                    width = 1.2,
                    order = 2,
                    min = 50,
                    max = 300,
                    step = 1,
                    get = function()
                        return SquizzFrames.db.profile.layout.main.width
                    end,
                    set = function(_, val)
                        SquizzFrames.db.profile.layout.main.width = val
                        SquizzFrames:UpdateLayout()
                    end,
                },
                height = {
                    name = L["Height"],
                    type = "range",
                    width = 1.2,
                    order = 3,
                    min = 20,
                    max = 100,
                    step = 1,
                    get = function()
                        return SquizzFrames.db.profile.layout.main.height
                    end,
                    set = function(_, val)
                        SquizzFrames.db.profile.layout.main.height = val
                        SquizzFrames:UpdateLayout()
                    end,
                },
                powerHeight = {
                    name = L["Power Bar Height"],
                    type = "range",
                    width = 1.2,
                    order = 4,
                    min = 2,
                    max = 20,
                    step = 1,
                    get = function()
                        return SquizzFrames.db.profile.layout.main.powerHeight
                    end,
                    set = function(_, val)
                        SquizzFrames.db.profile.layout.main.powerHeight = val
                        SquizzFrames:UpdateLayout()
                    end,
                },
                spacingY = {
                    name = L["Spacing"],
                    type = "range",
                    width = 1.2,
                    order = 5,
                    min = -10,
                    max = 50,
                    step = 1,
                    get = function()
                        return SquizzFrames.db.profile.layout.main.spacingY
                    end,
                    set = function(_, val)
                        SquizzFrames.db.profile.layout.main.spacingY = val
                        SquizzFrames:UpdateLayout()
                    end,
                },
                growthDirection = {
                    name = L["Growth Direction"],
                    type = "select",
                    width = 1.2,
                    order = 6,
                    values = {
                        DOWN = L["Down"],
                        UP = L["Up"],
                        RIGHT = L["Right"] or "Right",
                        LEFT = L["Left"] or "Left",
                        CENTER_H = L["Center (Horizontal)"] or "Center (Horizontal)",
                        CENTER_V = L["Center (Vertical)"] or "Center (Vertical)",
                    },
                    get = function()
                        return SquizzFrames.db.profile.layout.main.growthDirection or "DOWN"
                    end,
                    set = function(_, val)
                        SquizzFrames.db.profile.layout.main.growthDirection = val
                        SquizzFrames:UpdateLayout()
                    end,
                },
                sortByRole = {
                    name = L["Sort By Role"],
                    type = "toggle",
                    width = "full",
                    order = 8,
                    get = function()
                        return SquizzFrames.db.profile.layout.main.sortByRole
                    end,
                    set = function(_, val)
                        SquizzFrames.db.profile.layout.main.sortByRole = val
                        SquizzFrames:UpdateLayout()
                    end,
                },
                hideSelf = {
                    name = "Hide Self",
                    desc = "Hide your own frame when not in a group",
                    type = "toggle",
                    width = "full",
                    order = 9,
                    get = function()
                        return SquizzFrames.db.profile.layout.main.hideSelf
                    end,
                    set = function(_, val)
                        SquizzFrames.db.profile.layout.main.hideSelf = val
                        SquizzFrames:UpdateLayout()
                    end,
                },
            },
        },
        appearance = {
            name = L["Appearance"],
            type = "group",
            order = 3,
            args = {
                scale = {
                    name = L["Scale"],
                    type = "range",
                    width = 1.2,
                    order = 1,
                    min = 0.5,
                    max = 2.0,
                    step = 0.05,
                    get = function()
                        return SquizzFrames.db.profile.appearance.general.scale
                    end,
                    set = function(_, val)
                        SquizzFrames.db.profile.appearance.general.scale = val
                        SquizzFrames:UpdateScale()
                    end,
                },
                outOfRangeAlpha = {
                    name = L["Out of Range Alpha"],
                    type = "range",
                    width = 1.2,
                    order = 2,
                    min = 0,
                    max = 1,
                    step = 0.05,
                    get = function()
                        return SquizzFrames.db.profile.appearance.general.outOfRangeAlpha
                    end,
                    set = function(_, val)
                        SquizzFrames.db.profile.appearance.general.outOfRangeAlpha = val
                        SquizzFrames:Fire("AlphaChanged", val)
                    end,
                },
                texture = {
                    name = L["Status Bar Texture"],
                    type = "select",
                    width = 1.5,
                    order = 3,
                    dialogControl = "LSM30_Statusbar",
                    values = function()
                        return GetLSMList("statusbar")
                    end,
                    get = function()
                        return SquizzFrames.db.profile.appearance.general.texture
                    end,
                    set = function(_, val)
                        SquizzFrames.db.profile.appearance.general.texture = val
                        SquizzFrames:Fire("TextureChanged", val)
                    end,
                },
            },
        },
    },
}
