--[[
    The indicators' curated spell lists on WoW Forever, replacing the retail
    ones from Indicator_Defaults.lua. Read from the game's own data tables for
    build 1.60.1.70790 (wago.tools DB2 exports).

    Aura filters match exact spell IDs and every rank is its own ID, so each
    rank is listed. The Built-in Spells checklist folds them into one row per
    spell name.

    Unlike Party Cooldowns, an ID nobody has costs nothing here: the filter just
    never matches. So spells that may be Season of Discovery leftovers (Pain
    Suppression, Dispersion, Beacon of Light) are listed too.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames or not SquizzFrames.IS_FOREVER then return end

local defaults = SquizzFrames.defaults
if not defaults then return end

-- { 1, 2 } -> { [1] = true, [2] = true }, the shape the class-keyed lists use.
local function Set(...)
    local set = {}
    for _, ids in ipairs({ ... }) do
        for _, id in ipairs(ids) do set[id] = true end
    end
    return set
end

defaults.healerSpells = {
    DRUID = Set(
        {774, 1058, 1430, 2090, 2091, 3627, 8910, 9839, 9840, 9841, 25299, 28716}, -- Rejuvenation
        {417057, 417058, 417059, 417060, 417061, 417062, 417063, 417064, 417065, 417066, 417068}, -- Rejuvenation
        {8936, 8938, 8939, 8940, 8941, 9750, 9856, 9857, 9858, 28744},             -- Regrowth
        {436937, 436938, 436939, 436940, 436942, 436943, 436944, 436945, 436946},  -- Regrowth
        {408124, 409824},                                                          -- Lifebloom
        {408120, 409810, 1238214, 1238215}                                         -- Wild Growth
    ),
    PALADIN = Set(
        {409906},                                                                  -- Beacon of Light
        {53601, 58597, 412018, 412019, 415703, 440651}                             -- Sacred Shield
    ),
    PRIEST = Set(
        {139, 6074, 6075, 6076, 6077, 6078, 10927, 10928, 10929, 25315, 28807},    -- Renew
        {425268, 425269, 425270, 425271, 425272, 425273, 425274, 425275, 425276, 425277}, -- Renew
        {27606, 1236151, 1289450},                                                 -- Renew
        {17, 592, 600, 3747, 6065, 6066, 10898, 10899, 10900, 10901, 27607, 1236154}, -- Power Word: Shield
        {401877, 1240848, 1240849},                                                -- Prayer of Mending
        {14892, 14893}                                                             -- Inspiration
    ),
    SHAMAN = Set(
        {408521, 409954, 1239242, 1239243},                                        -- Riptide
        {974, 408514, 409947},                                                     -- Earth Shield
        {16177},                                                                   -- Ancestral Fortitude
        {29206}                                                                    -- Healing Way
    ),
}

defaults.externalCooldowns = {
    DRUID = Set(
        {29166, 456195}                                                            -- Innervate
    ),
    PALADIN = Set(
        {1022, 5599, 10278, 442948},                                               -- Blessing of Protection
        {6940, 20729},                                                             -- Blessing of Sacrifice
        {1044},                                                                    -- Blessing of Freedom
        {407804}                                                                   -- Divine Sacrifice
    ),
    PRIEST = Set(
        {10060},                                                                   -- Power Infusion
        {6346, 459699},                                                            -- Fear Ward
        {402004, 402839},                                                          -- Pain Suppression
        {425205, 425207}                                                           -- Power Word: Barrier
    ),
    WARRIOR = Set(
        {426490, 426492}                                                           -- Rallying Cry
    ),
}

defaults.defensiveCooldowns = {
    DRUID = Set(
        {22812, 428713},                                                           -- Barkskin
        {22842, 428708},                                                           -- Frenzied Regeneration
        {408024, 408025, 409809}                                                   -- Survival Instincts
    ),
    HUNTER = Set(
        {19263}                                                                    -- Deterrence
    ),
    MAGE = Set(
        {11958, 27619},                                                            -- Ice Block
        {11426, 13031, 13032, 13033, 1213278}                                      -- Ice Barrier
    ),
    PALADIN = Set(
        {642, 1020},                                                               -- Divine Shield
        {498, 5573, 458312, 458371},                                               -- Divine Protection
        {1311015}                                                                  -- Templar's Bulwark
    ),
    PRIEST = Set(
        {425294, 425307},                                                          -- Dispersion
        {586, 9578, 9579, 9592, 10941, 10942}                                      -- Fade
    ),
    ROGUE = Set(
        {5277, 15087},                                                             -- Evasion
        {11327, 11329, 457437, 1285372}                                            -- Vanish
    ),
    WARLOCK = Set(
        {6229, 11739, 11740, 28610}                                                -- Shadow Ward
    ),
    WARRIOR = Set(
        {871, 15062, 29061, 1277424},                                              -- Shield Wall
        {12976},                                                                   -- Last Stand
        {20230},                                                                   -- Retaliation
        {402913, 403359}                                                           -- Enraged Regeneration
    ),
}

-- One row per buff. A higher rank or the group version counts as the buff
-- through raidBuffVariants, so the first rank's ID is the one listed.
defaults.raidBuffs = {
    PRIEST = Set({1243}),  -- Power Word: Fortitude
    MAGE = Set({1459}),    -- Arcane Intellect
    WARRIOR = Set({6673}), -- Battle Shout
    DRUID = Set({1126}),   -- Mark of the Wild
}
defaults.raidBuffVariants = {
    [1243] = {1244, 1245, 2791, 10937, 10938, 21562, 21564},                       -- and Prayer of Fortitude
    [1459] = {1460, 1461, 10156, 10157, 23028},                                    -- and Arcane Brilliance
    [6673] = {5242, 6192, 11549, 11550, 11551, 25289},
    [1126] = {5232, 5234, 6756, 8907, 9884, 9885, 1291335, 1310503, 21849, 21850}, -- and Gift of the Wild
}

defaults.drinks = {
    167152,                                                                        -- Refreshment
    430, 431, 432, 1133, 1135, 1137, 10250, 22734, 24355, 25696, 26261, 26402, 26473, 26475, 29007, 446714, 468767, -- Drink
    433, 434, 435, 1127, 1129, 1131, 2639, 5004, 5005, 5006, 5007, 6410, 7737, 10256, 10257, -- Food
    18229, 18230, 18231, 18232, 18233, 18234, 22731, 24005, 24707, 24800, 24869, 25660, 25695, -- Food
    25700, 25702, 25886, 25888, 26260, 26401, 26472, 26474, 28616, 29008, 29073, 446713, 470362, -- Food
    470369, 1225769, 1225771, 1225772, 1225774, 1226808,                           -- Food
}

defaults.curatedDebuffBlacklist = {
    470085, 1243845, -- Sated
}

-- Nothing reads these three; retail's IDs would only mislead.
defaults.aoeHealings = {}
defaults.crowdControls = {}
defaults.tankActiveMitigations = {}
