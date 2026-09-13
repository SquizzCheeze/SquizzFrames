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

-- IS THIS A FRESH INSTALL? Captured HERE, at file-load time, and it has to be.
--
-- SavedVariables are restored before an addon's Lua runs, and Core's
-- OnInitialize does not fire until ADDON_LOADED -- after every file has
-- executed. So at this exact moment SquizzFramesDB is either nil (never played)
-- or the player's real saved table, and nothing has touched it yet.
--
-- Checking later does not work: ProfileStore:Init unconditionally creates
-- sv.profiles / sv.charProfileKeys / sv.autoSwitch, so by the time this module
-- runs its version check every install looks identical. Squizzumables gets away
-- with a later check because it tests its own settings table, which is only
-- written once the user saves something; this addon has no equivalent key that
-- stays absent.
local hadSavedVariables = SquizzFramesDB ~= nil

-- Highlights per version, newest first, keyed by the .toc Version string.
-- ADD A NEW ENTRY AS PART OF RELEASING -- see CLAUDE.md's Releasing section.
-- A version with no entry still shows the update frame, just without bullets.
local RELEASE_NOTES = {
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

local function Show(titleText, bodyText)
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

    f:Show()
end

-- The greeting for someone who has never run the addon.
--
-- No setup questions: the shipped defaults are the sensible starting point and
-- everything is off by default anyway, so this explains what is there and
-- points at the options rather than interrogating a new player.
local function ShowFirstRun()
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
     .. "Use Edit Mode, in the title bar of the options, to drag anything into place.")
end

-- The note after updating.
local function ShowUpdated(version)
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
    Show("SquizzFrames updated", body)
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
        -- a version that predates this file. hadSavedVariables is the only
        -- thing that can still tell them apart -- see its comment.
        if hadSavedVariables then
            ShowUpdated(version)
        else
            ShowFirstRun()
        end
    elseif seen ~= version then
        ShowUpdated(version)
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
