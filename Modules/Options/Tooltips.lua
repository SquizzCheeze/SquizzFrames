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
    ["Reduce Motion"] = "Turns off the fades and pops: the pages of this window, setup and the update "
        .. "note appear and disappear instantly instead.",
    ["Follow Blizzard's Edit Mode"] = "Opening Blizzard's Edit Mode (Esc > Edit Mode) turns on "
        .. "SquizzFrames' Edit Mode too, and closing it turns it off again.",
    ["Frame Opacity|Party Frames"] = "How see-through the party frames are, on top of any range fade.",
    ["Frame Opacity|Raid Frames"] = "How see-through the raid frames are, on top of any range fade.",
    ["Frame Opacity|Unit Frames"] = "How see-through the player, target, focus, boss and arena frames are.",
    ["Frame Opacity|Pet Frames"] = "How see-through the pet frames are, on top of any range fade.",
    ["Frame Opacity|Tank Tracker"] = "How see-through the Tank Tracker is.",

    -- Party and Raid ----------------------------------------------------------
    ["Frame Border|Enabled"] = "A border around every party and raid frame.",
    ["Target Highlight|Enabled"] = "Outlines the frame of whoever you have targeted.",
    ["Hover Highlight|Enabled"] = "Outlines the frame under your mouse.",
    ["Border Size"] = "How thick the border is, in pixels.",
    ["layout|Sizing|Width"] = "How wide each frame is.",
    ["layout|Sizing|Height"] = "How tall each frame is.",
    ["Power Bar Height"] = "Height of the power bar (mana, energy, rage...) along the bottom of each frame.",
    ["Layout Options|Spacing"] = "The gap between frames, in pixels.",
    ["Group Spacing"] = "The gap between raid groups, in pixels.",
    ["Layout Options|Orientation"] = "Vertical stacks the frames in a column; horizontal puts them side by side.",
    ["Layout Options|Growth Direction"] = "Which way the frames are added as the group fills up. Centre keeps "
        .. "them centred on their position.",
    ["Group Growth"] = "Which way the raid groups are laid out from each other.",
    ["Layout Options|Anchor Point"] = "The point of the screen the frames' position is measured from. Pick "
        .. "the corner or edge they should grow away from.",
    ["Hide Self"] = "Leaves your own frame out of the party frames.",
    ["Sort By Role"] = "Orders the group by role (tanks, healers, damage by default, or the order set "
        .. "just below) instead of by group order.",
    ["1st"] = "The role sorted first.",
    ["2nd"] = "The role sorted second.",
    ["3rd"] = "The role sorted third.",
    ["Raid Size"] = "How many frames the raid preview and Edit Mode show. It does not change the real raid.",
    ["Appearance|Scale"] = "The overall size of the party and raid frames.",
    ["Out of Range Alpha"] = "How faded an out-of-range player's frame is, with Fade Out of Range on "
        .. "(General page).",
    ["Don't Fade Dead Players"] = "Keeps dead and ghost players at full brightness even when they are out of range.",
    ["Bar Texture"] = "The texture of the health and power bars.",
    ["Color by Health"] = "Colours the health bar by how much health is left, using the colours below, "
        .. "instead of a fixed colour.",
    ["Health Gradient|Style"] = "How the health colours blend into each other.",
    ["Full Health"] = "The colour at full health.",
    ["Midpoint"] = "The colour at the midpoint below.",
    ["Empty"] = "The colour at almost no health.",
    ["Midpoint At"] = "The health percentage the midpoint colour sits at.",
    ["Use Class Colors"] = "Each health bar takes the player's class colour.",
    ["Health Bar Colors|Custom Color"] = "The health bar colour when class colours are off.",
    ["Power Bar Colors|Color Mode"] = "Colour power bars by power type (mana blue, rage red...) or with "
        .. "one colour of your own.",
    ["Power Bar Colors|Custom Color"] = "The power bar colour in custom mode.",

    -- Pet Frames ----------------------------------------------------------------
    ["Enable Pet Frames"] = "Frames for your party's and raid's pets.",
    ["Enable My Pet Frame"] = "A separate frame for your own pet, placed wherever you like.",
    ["Match Owner Width"] = "Each pet frame is as wide as its owner's frame.",
    ["Match Owner Height"] = "Each pet frame is as tall as its owner's frame.",
    ["Show Name"] = "Shows the name on the frame.",
    ["Use Owner's Class Color"] = "Pet health bars take their owner's class colour.",
    ["Anchor Side"] = "Which side of its owner's frame each pet sits on.",

    -- Nicknames -------------------------------------------------------------------
    ["Enable nicknames"] = "Shows nicknames in place of players' names on your party and raid frames.",
    ["Use this nickname on all my characters"] = "Your nickname is the same on every character on this account.",
    ["Share nicknames with your group"] = "Sends your nickname to group members who use SquizzFrames, and "
        .. "shows theirs.",
    ["Use my private list"] = "Uses the nicknames you have set for other players. Yours always win over "
        .. "ones they share.",

    -- Click Casting -----------------------------------------------------------------
    ["Other addons' frames (Blizzard, EllesmereUI)"] = "Your click-cast bindings also work on Blizzard's "
        .. "and EllesmereUI's unit frames.",

    -- Profiles --------------------------------------------------------------------
    ["Switch Profile|Profile"] = "The profile this character uses.",
    ["Source Profile"] = "The profile to copy settings from, into the current one.",
    ["Delete Profile|Profile"] = "The profile to delete. The one in use cannot be deleted.",
    ["Switch profile by specialization and situation"] = "Changes profile on its own by your specialization "
        .. "and whether you are solo, in a party or in a raid.",

    -- Tank Tracker -----------------------------------------------------------------
    ["Enable Tank Tracker"] = "A frame for each tank in your group, with the debuffs on them above and "
        .. "the defensives they have up below.",
    ["Include Yourself"] = "Tracks you too when you are a tank.",
    ["Only While Tank Spec"] = "Only shows the tracker while you are in a tank specialization yourself.",
    ["Max Frames"] = "The most tanks shown at once.",
    ["Class Color Health"] = "Health bars take each tank's class colour.",
    ["Icon Borders"] = "A thin border around each icon.",
    ["Max Per Row"] = "How many icons fit in a row before a new row starts.",
    ["Rows"] = "The most rows of icons shown.",
    ["Show Duration"] = "Shows the time left on each icon.",
    ["Show Stacks"] = "Shows the stack count on each icon.",
    ["Debuffs|Filter"] = "Which debuffs to show. Encounter debuffs shows what the fight applies, without "
        .. "long-lasting things like food and flasks.",

    -- Unit Frames ------------------------------------------------------------------------
    ["Enable Unit Frames"] = "SquizzFrames' own player, target, target of target, focus, boss and arena frames.",
    ["Mirror Player and Target"] = "Moving the player or target frame moves the other to the matching "
        .. "spot on the other side of the screen.",
    ["Use Nicknames"] = "Shows your nickname on your own player frame.",
    ["Show Portrait"] = "Shows a portrait of the unit on its frame.",
    ["Inside the Frame"] = "Puts the portrait inside the frame instead of beside it.",
    ["Enable Cast Bar"] = "A cast bar for this frame.",
    ["Uninterruptible Tint"] = "The cast bar's colour when the cast cannot be interrupted.",
    ["Class Color the Bar"] = "The cast bar takes the unit's class colour.",
    ["Reaction Color (NPCs)"] = "NPC health bars are coloured by how they feel about you: red hostile, "
        .. "yellow neutral, green friendly.",
    ["Class Color (players)"] = "Player health bars take their class colour.",
    ["Mine Only"] = "Only shows the auras you cast.",
    ["Show Cooldown Swipe"] = "The clock-style sweep showing how much time is left on each icon.",
    ["Max Icons"] = "The most auras shown in the row.",
    ["Only Show Overshields"] = "Hides the shield until it is bigger than the health that is missing, "
        .. "the point at which more healing would be wasted.",
    ["Show All Types"] = "Shows every dispellable debuff type, not only the ones you can remove.",
    ["Pulse Overlay"] = "The dispel tint pulses while a dispellable debuff is up.",
    ["Animated Border"] = "A moving dashed border while a dispellable debuff is up.",
    ["Show Dispel Icon"] = "Shows the icon for the debuff's type (Magic, Curse, Poison, Disease).",
    ["Show Blizzard's trinket, CC and DR icons"] = "Shows Blizzard's own enemy trinket, crowd control and "
        .. "diminishing returns icons beside your arena frames. Addons cannot read those, so they are borrowed.",
    ["Match Height of Attached Frame"] = "When attached to a cooldown group, the frame takes that group's height.",
    ["Attach To"] = "Fixes this to another frame, such as a cooldown group, so it moves with it.",
    ["Match Width Of"] = "Takes the width of another frame, such as a cooldown group.",
    ["Power Bar Height (0 = off)"] = "Height of the power bar under the health bar. 0 hides it.",
    ["Fill From Right"] = "The bar fills from right to left.",
    ["Enable Resource Bar"] = "A bar for your power (mana, energy, rage...) and your class resource "
        .. "(combo points, holy power, runes...).",
    ["Move Points Separately"] = "Places the class resource points as their own frame instead of with the power bar.",
    ["Points Above Bar"] = "Puts the class resource points above the power bar instead of below it.",
    ["Rainbow Speed"] = "How fast the rainbow colours cycle.",

    -- Indicators ----------------------------------------------------------------------
    ["Use Default Spells"] = "Includes the built-in spell list. Untick spells below to leave them out.",
    ["Prioritize Crowd Control Debuffs"] = "Shows crowd control debuffs first.",
    ["Cast By"] = "Whose auras to show: yours, anyone's, or other players'.",
    ["Overlay Style"] = "How the dispel tint covers the health bar.",
    ["Overlay Opacity"] = "How strong the dispel tint is.",
    ["Expiring Color"] = "Switches to a second colour when the aura is about to run out.",
    ["Frame Level"] = "Drawing order: an indicator with a higher level sits on top of one with a lower level.",
    ["Max Length (0 = no limit)"] = "Cuts the text to this many letters.",

    -- General-purpose names ------------------------------------------------------------
    -- Settings found on many pages under the same name. Each says what it does
    -- wherever it appears; a page that needs more gets a "section|label" key
    -- above, which wins. (Matches Squizzumables, which tooltips these too.)
    ["Enabled"] = "Turns this on or off.",
    ["Show"] = "Shows or hides this.",
    ["Width"] = "How wide this is, in pixels.",
    ["Height"] = "How tall this is, in pixels.",
    ["Size"] = "How big this is.",
    ["Scale"] = "Overall size, as a multiple of normal.",
    ["Opacity"] = "How see-through this is: lower is more transparent.",
    ["Alpha"] = "How see-through this is: lower is more transparent.",
    ["Spacing"] = "The gap between items, in pixels.",
    ["Spacing X"] = "The gap between items side by side, in pixels.",
    ["Spacing Y"] = "The gap between rows, in pixels.",
    ["Padding"] = "Space between the edge and what is inside it, in pixels.",
    ["Gap"] = "The space between this and what it sits next to, in pixels.",
    ["Thickness"] = "How thick the line is, in pixels.",
    ["Border Thickness"] = "How thick the border is, in pixels.",
    ["Border"] = "Draws a border around it.",
    ["Icon Border"] = "Draws a thin border around each icon.",
    ["Show Icon Border"] = "Draws a thin border around each icon.",
    ["Color"] = "The colour used.",
    ["Text Color"] = "The colour of the text.",
    ["Custom Color"] = "The colour used when you pick your own instead of class or power colours.",
    ["Bar Color"] = "The colour of the bar.",
    ["Background"] = "The colour behind the bar, where it is empty.",
    ["Empty Color"] = "The colour of the empty part of the bar.",
    ["Tint"] = "The colour laid over it.",
    ["Border Colour"] = "The colour of the border.",
    ["Custom Border Colour"] = "Uses a colour of your own for the border instead of the default.",
    ["Use Class Color"] = "Uses the class colour instead of a fixed colour.",
    ["Class Color"] = "Uses the class colour instead of a fixed colour.",
    ["Font"] = "The typeface of the text.",
    ["Outline"] = "An outline around the letters, so the text stays readable on any background.",
    ["Shadow"] = "A drop shadow behind the letters.",
    ["Format"] = "What the text shows: for example current value, percentage, or both.",
    ["Anchor"] = "Which point this is attached at. Offset X and Y then move it from there.",
    ["Anchor Point"] = "Which point this is attached at. The offsets then move it from there.",
    ["Relative To"] = "What this is attached to.",
    ["Relative Point"] = "The point of what it is attached to that it lines up with.",
    ["Anchor To"] = "What this is attached to.",
    ["Position"] = "Where this sits.",
    ["Side"] = "Which side it sits on.",
    ["Offset X"] = "Moves it left (negative) or right (positive), in pixels.",
    ["Offset Y"] = "Moves it down (negative) or up (positive), in pixels.",
    ["X Offset"] = "Moves it left (negative) or right (positive), in pixels.",
    ["Y Offset"] = "Moves it down (negative) or up (positive), in pixels.",
    ["Orientation"] = "Which way it runs: horizontal or vertical.",
    ["Growth"] = "Which way new icons are added.",
    ["Growth Direction"] = "Which way new items are added.",
    ["Style"] = "How it looks.",
    ["Shape"] = "The shape it is drawn in.",
    ["Texture"] = "The texture it is drawn with.",
    ["Icon Size"] = "How big each icon is, in pixels.",
    ["Show Icon"] = "Shows the spell's icon.",
    ["Show Text"] = "Shows the text.",
    ["Show Spell Name"] = "Shows the name of the spell being cast.",
    ["Show Cast Time"] = "Shows how long is left on the cast.",
    ["Show Stack"] = "Shows the stack count.",
    ["Per Line"] = "How many fit in a row before a new row starts.",
    ["Max Displayed"] = "The most shown at once.",
    ["Filter"] = "Which ones to show.",
    ["Glow"] = "Makes it glow so it stands out.",
    ["Highlight"] = "How it is highlighted.",
    ["Fill Direction"] = "Which way the bar fills.",
    ["Bar Width"] = "How wide the bar is, in pixels.",
    ["Bar Height"] = "How tall the bar is, in pixels.",
    ["Duration Anchor"] = "Where the time-left text sits on the icon.",
    ["Duration Offset X"] = "Moves the time-left text left or right, in pixels.",
    ["Duration Offset Y"] = "Moves the time-left text down or up, in pixels.",
    ["Duration X Offset"] = "Moves the time-left text left or right, in pixels.",
    ["Duration Y Offset"] = "Moves the time-left text down or up, in pixels.",
    ["Stack Anchor"] = "Where the stack count sits on the icon.",
    ["Stack Offset X"] = "Moves the stack count left or right, in pixels.",
    ["Stack Offset Y"] = "Moves the stack count down or up, in pixels.",
    ["Model Zoom"] = "How close the 3D portrait is zoomed in.",
    ["Gradient Height"] = "How far up the health bar the gradient reaches.",
    ["Gradient Fade"] = "How quickly the gradient fades out.",
    ["Fade To %"] = "How faint the gradient gets at its far end.",
    ["Fade To (%)"] = "How faint it gets when it fades.",
    ["Fade Time (sec)"] = "How long the fade takes, in seconds.",
    ["Pulse"] = "Pulses so it catches the eye.",
    ["Pulse Speed"] = "How fast it pulses.",
    ["Border Speed"] = "How fast the animated border moves.",
    ["Dash Length"] = "How long each dash of the animated border is.",
    ["Icons Side"] = "Which side of the frame the icons sit on.",
    ["Icons Scale"] = "How big the icons are, as a multiple of normal.",
    ["Point Style"] = "How the class resource points are drawn: bars, shapes or Blizzard's own art.",
    ["Use Debuff Icon"] = "Uses the debuff's own icon.",
    ["Resource Points"] = "Shows your class resource (combo points, holy power, runes...).",
    ["Power Bar"] = "Shows your power bar (mana, energy, rage...).",
    ["Size (0 = match height)"] = "How big it is. 0 makes it as tall as the frame.",
    ["Size (Big)"] = "The size of the bigger icons.",
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
