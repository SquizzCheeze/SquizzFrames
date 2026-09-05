--[[ SquizzFrames Appearance Defaults ]]
local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local defaults = SquizzFrames.defaults or {profile = {}}
SquizzFrames.defaults = defaults

local profile = defaults.profile or {}

profile.general = {
    -- ONE switch for every Blizzard frame this addon replaces: party, raid,
    -- player/target/focus/boss, the player cast bar and the pet frame
    -- (2026-09-05, replacing the old hideBlizzardParty/hideBlizzardRaid pair
    -- plus unitFrames.hideBlizzard/.hideBlizzardCastBar -- see
    -- MigrateHideBlizzardSwitches in Core.lua).
    --
    -- It is safe to leave on because it never hides a frame we aren't
    -- actually drawing a replacement for: HideBlizzard.lua gates each piece
    -- on its own module/frame being enabled, so anything switched off here
    -- falls back to Blizzard's own frame rather than leaving you with
    -- nothing. That is also why arena frames are unaffected for now -- we
    -- don't draw them yet, so Blizzard's stay.
    hideBlizzardFrames = true,
    locked = false,
    fadeOut = true,
}

profile.appearance = {
    general = {
        scale = 1.0,
        -- NOTE: not actually read anywhere (CreatePartyContainer/
        -- CreateHeader/UnitButton_OnLoad hardcode strata directly, not via
        -- this field). 2026-08-01: testing plain "MEDIUM" (see
        -- PartyFrames.lua's CreatePartyContainer for the full history/why --
        -- was "HIGH" 2026-07-30/31 to beat nameplates, which needed a
        -- separate ApplyBlizzardPanelVisibility fade to stop also covering
        -- Blizzard's own panels; now mirroring DandersFrames/
        -- EllesmereUIRaidFrames, neither of which elevates strata at all).
        -- Kept here only so a future options-panel Strata control has a
        -- sane starting value to write into once one exists.
        strata = "MEDIUM",
        texture = "Blizzard",
        outOfRangeAlpha = 0.3,
        barAnimation = "Smooth",
        useGameFont = false,
        optionsFontSizeOffset = 0,
        accentColor = {"class_color"},
        colorThresholds = {40, 70, 90},
    },
    healthBar = {
        fullColor = {"class_color", "any"},
        lossColor = {"class_color_dark", "any"},
        deathColor = {"custom_color", 0.4, 0.4, 0.4, 1},
    },
    powerBar = {
        -- #1612FF
        powerColor = {"custom_color", 0.0863, 0.0706, 1, 1},
        powerBackgroundMultiplier = 0.3,
    },
    -- Pet Frames health bar color (2026-08-05). Single shared setting, not
    -- split per party/raid pet layout -- matches healthBar/powerBar above,
    -- which are appearance-wide too, not duplicated under profile.layout
    -- .main/.raid. "owner_class_color" is the pet-specific analog of
    -- healthBar's "class_color" -- pets have no class of their own, so this
    -- resolves via PetFrames.lua's GetOwnerUnitForPet + F.GetClassColor
    -- instead of the pet's own (nonexistent) class.
    petHealthBar = {
        fullColor = {"owner_class_color", "any"},
        customColor = {0.2, 0.8, 0.2, 1},
    },
    text = {
        nameColor = {"class_color", "any"},
        nameFont = {size = 12, font = "FONTS\\FRIZQT__.TTF", flags = "OUTLINE"},
        statusFont = {size = 10, font = "FONTS\\FRIZQT__.TTF", flags = "OUTLINE"},
    },
}

defaults.profile = profile
