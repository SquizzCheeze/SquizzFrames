--[[ SquizzFrames Welcome / release notes

    The first-run greeting and the "what changed" note after an update.

    One frame serves both: they differ only in their heading and their body, and
    both are "say this once, then never again".

    Ported from Squizzumables' Core/Welcome.lua, which solved this first. Its
    hard-won details are carried over deliberately and noted where they matter
    -- the scrolling body, the three-way first-run/update/nothing decision, and
    reading the seen-version straight off the SavedVariable root.

    WHY THE NOTES ARE DUPLICATED HERE rather than read from CHANGELOG.txt: an
    addon cannot read its own text files at runtime. Anything shown in game has
    to live in Lua, and duplicating a 900-line changelog would guarantee the
    copy rots. A handful of lines per release is worth keeping in step by hand;
    the full history stays in CHANGELOG.txt for anyone who wants it.

    So this is a HIGHLIGHT list, not a changelog. Keep it to what a player
    would notice.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local addonName = "SquizzFrames"
local W = SquizzFrames.Widgets

local Welcome = {}
SquizzFrames.Welcome = Welcome

-- Highlights per version, newest first, keyed by the .toc Version string.
-- ADD A NEW ENTRY AS PART OF RELEASING -- see CLAUDE.md's Releasing section.
-- A version with no entry still shows the update frame, just without bullets.
local RELEASE_NOTES = {
    ["1.28"] = {
        "Ping Marker: when a group member is pinged, the marker the game draws on its own raid frames now appears on yours too. It follows your \"show pings on raid frames\" setting, and sits under Alerts in the Designer with its own position and size.",
        "Debuffs has a new Filter -- Everything, Priority debuffs, Boss & role mechanics, or both -- on the party/raid indicator and on the unit frames' debuff row. It sits alongside Hide Crowd Control rather than replacing it.",
        "Everything stays the default on purpose: the narrower filters rely on the game having flagged a debuff, and show nothing at all in an encounter it has not flagged.",
        "Tank Tracker now defaults to a new \"Encounter debuffs\" filter, which shows what a fight actually applies instead of relying on the game's boss and role tagging. The old default showed an empty row in encounters that were never tagged - The Lost Explorers being the fight that found it. A filter you picked yourself is kept.",
    },
    ["1.27"] = {
        "Name, Health and Power Text now offer the same settings as the unit frames' text: a single Anchor Point instead of two dropdowns, and one Format choice instead of the Show Percentage / Show Current / Show Max tickboxes. Your current settings carry across and nothing moves.",
        "Text Width is replaced by Max Length, measured in characters, with a \"...\" on anything longer.",
        "Power Text can show current / max, on the unit frames as well.",
        "Fixed text anchored to a corner lining itself up as though it were centred - a name anchored top-right looked like it was sitting top-left.",
    },
    ["1.26"] = {
        "The five Holy Power runes are available as a resource point shape. Point Style \"Shape\", then \"Holy Power Runes\" - the row lays all five out in order like the game's own bar, and they take any colour you pick exactly.",
        "Boss frames with aura rows above or below now make room for them, instead of the auras running into the next boss frame. Spacing is a minimum now: the gap opens up on its own to fit the rows.",
    },
    ["1.25"] = {
        "Font dropdowns show each font in its own typeface, so you can see what you are picking before you apply it.",
        "Open dropdown lists now follow the page when you scroll, instead of staying behind and floating away from their dropdown.",
        "Tank Tracker icon rows wrap onto a second line properly. The Rows setting never actually did anything before - on your frames or in the preview.",
        "The Tank Tracker's Max Icons slider is now called Max Per Row, which is what it always did. A row holds that many times Rows. Your settings are unchanged.",
    },
    ["1.24"] = {
        "Fixed the addon failing to start for anyone running few enough other addons, with a \"Cannot find a library instance of AceConfigDialog-3.0\" error.",
        "/rl now reloads your interface, the same as /reload. It is only claimed if no other addon already provides it.",
        "Supports patch 12.1.5 as well as 12.1.0.",
        "Removed the Show Unfiltered Auras option - a game hotfix in August made the situation it existed for stop happening, so it no longer did anything.",
    },
    ["1.23"] = {
        "With the resource points moved separately, the power bar and the points each have their own border switch.",
        "Unit frame cast bars can have a border.",
        "Fixed the frame rate hitching whenever someone joined or left the group - the frames no longer rebuild themselves when nothing about them has changed.",
        "Indicators you have switched off are no longer built at all, which cuts a large chunk of memory on joining a raid.",
    },
    ["1.22"] = {
        "The resource bar's power bar and resource points can now be moved separately: tick Move Points Separately on the Unit Frames page, then drag each one, attach it to another frame, or attach them to each other.",
        "Resource points can be shapes (round, star, heart, potion, bottle, nail polish and more) or Blizzard's own class art, and can be coloured rainbow, still or animated.",
        "Resource points have their own width settings, including Match a Frame, and the resource bar options are split into General, Power and Resource tabs.",
        "Each resource point can have its own border that follows its shape.",
        "When SquizzFrames updates at the same time as Squizzumables or Avatar Continued, their update notes now appear one after another instead of on top of each other.",
    },
    ["1.21"] = {
        "The Tank Tracker options page has a live, actual-size preview of a tank frame, with mock debuff and defensive icons showing their duration and stack text, so you can see changes as you make them.",
        "Tank Tracker settings are split into General, Debuffs and Defensives tabs.",
        "The tank name can be anchored anywhere on the bar, and the duration and stack text on each icon row have their own font, outline, size, colour, anchor and offsets.",
    },
    ["1.20"] = {
        "The unit frame preview now shows duration and stack text on its mock aura icons, so you can place them without going to find something with a debuff on it.",
        "Unit frame aura duration text sits in the middle of its icon by default, rather than under it.",
        "The dispel gradient overlay spans the whole health bar by default rather than half of it. Both default changes carry across once; anything you had set yourself is left alone.",
    },
    ["1.19"] = {
        "Every target could show the same person's nickname for a whole dungeon. Nickname lookups were remembered against the unit token, and \"target\" means something different every time you click - so the first target with a nickname became the name on every target after it, until the run ended.",
        "Nicknames now apply to your own frame only. The checkbox was only ever on the player frame, but target, focus and boss frames were quietly using them too.",
    },
    ["1.18"] = {
        "Unit frames can have a border, with its own thickness, padding and colour.",
        "Unit frame text has a font and outline picker. The setting was always there, it just had no control.",
        "Tank Tracker settings apply immediately instead of needing a reload. Changing which debuffs are shown did nothing to a row already on screen, which is also why co-tank debuff rows could come up empty.",
        "Dispel overlay and dispel icon on the unit frames, with per-type colours.",
        "Hover, target and aggro highlights on the unit frames, with their own colour and thickness per frame, separate from the party and raid indicators.",
        "Health bars can colour by how hurt someone is - green at full, through amber, to red - as a smooth blend or hard bands. Party, raid and pet frames share one switch; unit frames have their own per frame.",
        "This window is new: a short note about what changed, once per update.",
    },
    ["1.17"] = {
        "Tank Tracker duration and stack text now have an anchor and offset sliders, and the size sliders work.",
    },
    ["1.16"] = {
        "The cast bar's spell name and cast timer each have their own font, size, outline, colour and offsets.",
    },
    ["1.15"] = {
        "Right-clicking a party or raid member no longer gives a pet menu with no Remove from Group, for anyone out of range, zoned away or offline.",
        "Shield and heal-absorb overlays were drawing underneath the health bar, so they were invisible.",
        "Cast bars and the resource bar now follow a Cooldown Manager row across spec, talent and loadout changes.",
        "Buff and debuff rows on target/focus/boss frames no longer pile up duplicates or keep the previous target's auras.",
    },
    ["1.14"] = {
        "Unit Frames: player, target, target of target, focus, focus target and boss frames, each with health, power, four text readouts, portraits, cast bars, auras, absorbs and icons.",
        "A Resource Bar for your power plus your class's secondary resource - Holy Power, Combo Points, Chi, Soul Shards, Arcane Charges, Essence or Runes.",
        "Your own pet can have its own standalone frame, kept in one place in every group state.",
        "One Hide Blizzard Frames switch now covers party, raid, player, target, focus, boss, pet and the cast bar.",
    },
}

local function CurrentVersion()
    return (C_AddOns and C_AddOns.GetAddOnMetadata
        and C_AddOns.GetAddOnMetadata(addonName, "Version")) or "?"
end

local frame

-- ONE UPDATE NOTE AT A TIME, across all of the Squizz addons.
--
-- SquizzFrames, Squizzumables and Avatar Continued each carry a copy of this
-- window, and the copies were identical: same size, same spot, same DIALOG
-- strata, same frame level. Frames that tie on strata and level have no defined
-- draw order, so when two of them updated at the same login their notes drew
-- through each other and flickered as the order flipped.
--
-- The queue lives in _G and is created by whichever addon loads first. Notes
-- that come due at login wait behind one already on screen and appear when it
-- closes; notes opened by hand (/sf notes) show straight away, on top.
--
-- KEEP THIS BLOCK IDENTICAL IN ALL THREE ADDONS. They share the table, so its
-- shape is an interface between them.
local NotesQueue = _G.SquizzNotesQueue or { pending = {} }
_G.SquizzNotesQueue = NotesQueue

local function PresentNotes(f, queued)
    local active = NotesQueue.active
    if queued and active and active ~= f and active:IsShown() then
        for _, waiting in ipairs(NotesQueue.pending) do
            if waiting == f then return end
        end
        table.insert(NotesQueue.pending, f)
        return
    end
    NotesQueue.active = f
    f:Show()
    f:Raise()
end

local function OnNotesHidden(f)
    if NotesQueue.active ~= f then return end
    NotesQueue.active = nil
    local nextFrame = table.remove(NotesQueue.pending, 1)
    if nextFrame then
        PresentNotes(nextFrame, false)
    end
end

-- Narrower than the frame by the scroll bar's gutter, so a long note is not
-- drawn underneath it.
local BODY_WIDTH = 404

local function BuildFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "SquizzFramesWelcome", UIParent, "BackdropTemplate")
    frame:SetSize(460, 320)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    -- Clicking a notes window brings it in front of any other one, and closing
    -- it lets the next queued note through (see NotesQueue).
    frame:SetToplevel(true)
    frame:HookScript("OnHide", OnNotesHidden)
    if W and W.StylizeFrame then
        W.StylizeFrame(frame, {0.09, 0.09, 0.09, 0.96}, {0, 0, 0, 1})
    end

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -16)
    frame.title = title

    -- THE NOTES SCROLL, and that is not optional.
    --
    -- Squizzumables shipped this as one FontString on a fixed-height frame,
    -- which silently relied on every release having few enough bullets to fit.
    -- The release with eight ran under the buttons and off the bottom, and the
    -- last three were unreachable. Nothing warns you: the text simply draws
    -- outside its parent.
    --
    -- Bounded between the title and the buttons rather than sized to the text,
    -- so however long a future release's notes are, the frame stays put and the
    -- buttons stay reachable.
    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -26, 52)
    frame.scroll = scroll

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(BODY_WIDTH, 1)
    scroll:SetScrollChild(content)
    frame.content = content

    local body = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    body:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    body:SetWidth(BODY_WIDTH)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetSpacing(4)
    body:SetTextColor(0.78, 0.78, 0.78, 1)
    frame.body = body

    if W and W.CreateStyledButton then
        local settingsBtn = W.CreateStyledButton(frame, "Open Settings", "accent-hover",
            {130, 26}, function()
                frame:Hide()
                if SquizzFrames.ToggleOptions then SquizzFrames:ToggleOptions() end
            end)
        settingsBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 18, 16)

        local closeBtn = W.CreateStyledButton(frame, "Close", "accent-hover",
            {90, 26}, function() frame:Hide() end)
        closeBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -18, 16)
    end

    return frame
end

-- queued: true for the automatic login note, which waits its turn behind
-- another addon's note; false/nil when opened by hand.
local function Show(titleText, bodyText, queued)
    local f = BuildFrame()
    f.title:SetText(titleText)
    f.body:SetText(bodyText)

    -- Size the scroll child to the text, AFTER SetText so the height is the
    -- wrapped height rather than the pre-layout one. Without this the child
    -- keeps its placeholder height of 1, the scroll frame decides there is
    -- nothing to scroll, and you get the overflow bug this replaced.
    f.content:SetHeight(math.max(1, f.body:GetStringHeight() + 4))

    -- Back to the top: the frame is reused, so re-opening through /sf notes
    -- would otherwise restore wherever the last read was left.
    f.scroll:SetVerticalScroll(0)

    PresentNotes(f, queued)
end

-- The greeting for someone who has never run the addon.
--
-- No setup questions: the shipped defaults are the sensible starting point and
-- everything is off by default anyway, so this explains what is there and
-- points at the options rather than interrogating a new player.
local function ShowFirstRun(queued)
    Show("Welcome to SquizzFrames",
        "SquizzFrames replaces your party and raid frames, and can replace your player, "
     .. "target, focus, boss and pet frames too.\n\n"
     .. "Your party and raid frames are already running. Everything else is OFF until you "
     .. "turn it on, so nothing has moved that you did not ask to move.\n\n"
     .. "Type /sf to open the options. Worth a look first:\n\n"
     .. "- Layout, for size, spacing and where the frames sit\n"
     .. "- Indicators, for HoTs, cooldowns, debuffs and dispels on each frame\n"
     .. "- Click Casting, to cast straight from the frames\n"
     .. "- Unit Frames, if you want the player/target/focus frames as well\n\n"
     .. "Use Edit Mode, in the title bar of the options, to drag anything into place.", queued)
end

-- The note after updating.
local function ShowUpdated(version, queued)
    local notes = RELEASE_NOTES[version]
    local body = "SquizzFrames has been updated to " .. version .. ".\n\n"
    if notes then
        for _, line in ipairs(notes) do
            body = body .. "- " .. line .. "\n"
        end
        body = body .. "\nThe full changelog is in CHANGELOG.txt in the addon folder."
    else
        body = body .. "See CHANGELOG.txt in the addon folder for what changed."
    end
    Show("SquizzFrames updated", body, queued)
end

-- Decide which, if either, to show.
--
-- Reads its key STRAIGHT OFF SquizzFramesDB, never through the profile. That
-- matters more here than it did in Squizzumables: this addon has full profile
-- support, so a profile switch or a /sf reset would otherwise be able to
-- re-greet somebody who has been using it for months.
local function CheckVersion()
    if not SquizzFramesDB then return end
    local version = CurrentVersion()
    local seen = SquizzFramesDB.lastSeenVersion

    if seen == nil then
        -- No record at all: either a genuinely new install, or an upgrade from
        -- a version that predates this file. SquizzFrames.hadSavedVariables,
        -- taken at the top of Core.lua's OnInitialize, is the only thing that
        -- can still tell them apart.
        --
        -- It cannot be taken any earlier or later. At file load the
        -- SavedVariables have not been loaded yet, so it is always nil (this
        -- file used to check there, and greeted upgraders as new players).
        -- After ProfileStore:Init it always exists, because Init creates it
        -- along with sv.profiles, sv.charProfileKeys and sv.autoSwitch.
        -- Squizzumables avoids needing this by testing its own settings table,
        -- which is only written once the user saves something; this addon has
        -- no equivalent key that stays absent.
        if SquizzFrames.hadSavedVariables then
            ShowUpdated(version, true)
        else
            ShowFirstRun(true)
        end
    elseif seen ~= version then
        ShowUpdated(version, true)
    end

    SquizzFramesDB.lastSeenVersion = version
end

-- After PLAYER_LOGIN so the SavedVariables exist, and on a delay so it does not
-- land in the middle of the loading screen.
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    C_Timer.After(4, CheckVersion)
end)

-- /sf notes re-opens the current release notes on demand.
Welcome.ShowReleaseNotes = function() ShowUpdated(CurrentVersion()) end
Welcome.ShowFirstRun = ShowFirstRun
