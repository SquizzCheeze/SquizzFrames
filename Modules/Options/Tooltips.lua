--[[ SquizzFrames Tooltips.lua -- hover text for the options window's settings (2.0)

    One table, so every setting's explanation lives in one place instead of at
    hundreds of call sites. The shared controls in Widgets.lua (checkbox,
    slider, dropdown, colour picker) look their tooltip up here as they are
    built, show it on hover, and hand it to the window's search, which then
    matches tooltip text too -- as Squizzumables' settings do.

    Keys, most specific first:
        "<page key>|<section>|<label>"   one setting on one page
        "<section>|<label>"              a label that means different things
                                         in different sections
        "<label>"                        a label that means the same everywhere
    <section> is the titled pane the control sits under (as search shows it);
    <page key> is the options page ("general", "layout", "unitFrames", ...).

    Write for a player: what it does and when you would want it, in a line or
    two. No tooltip for a setting whose name already says everything.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local TIPS = {
    -- General ---------------------------------------------------------------
    ["Theme|Preset"] = "The look of this window and Squizzumables', shared by both addons. "
        .. "Class Colour uses your class colour as the accent.",
    ["Hide Blizzard Frames"] = "Hides Blizzard's own frames wherever SquizzFrames draws its own: party, "
        .. "raid, player, target, focus, boss, pet and the cast bar. Anything of ours you switch off "
        .. "keeps Blizzard's.",
    ["Lock Frames"] = "Stops the frames being dragged. Edit Mode still moves them.",
    ["Fade Out of Range"] = "Dims party and raid members who are too far away to heal or help. "
        .. "Their status text and status icon stay readable.",
    ["Follow Blizzard's Edit Mode"] = "Opening Blizzard's Edit Mode (Esc > Edit Mode) turns on "
        .. "SquizzFrames' Edit Mode too, and closing it turns it off again.",
    ["Frame Opacity|Party Frames"] = "How see-through the party frames are, on top of any range fade.",
    ["Frame Opacity|Raid Frames"] = "How see-through the raid frames are, on top of any range fade.",
    ["Frame Opacity|Unit Frames"] = "How see-through the player, target, focus, boss and arena frames are.",
    ["Frame Opacity|Pet Frames"] = "How see-through the pet frames are, on top of any range fade.",
    ["Frame Opacity|Tank Tracker"] = "How see-through the Tank Tracker is.",
}

--- The tooltip for a setting, or nil. `section` and `pageKey` may be nil.
function SquizzFrames.TooltipFor(label, section, pageKey)
    if type(label) ~= "string" then return nil end
    if section and pageKey then
        local t = TIPS[pageKey .. "|" .. section .. "|" .. label]
        if t then return t end
    end
    if section then
        local t = TIPS[section .. "|" .. label]
        if t then return t end
    end
    return TIPS[label]
end
