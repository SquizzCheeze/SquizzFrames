--[[
    Party Cooldowns: the spell table on WoW Forever, replacing the retail one.

    Same fields as PartyCooldownsData.lua, read from the game's own data tables
    for build 1.60.1.70790 (wago.tools DB2 exports). What is different here:
      * ranks     a spell has one cast ID per rank, listed in `casts`, and each
                  rank is its own aura ID, so `buffs` lists them all. Ranks of
                  one spell share a cooldown category
      * minLevel  characters level up here, so a spell can be out of a member's
                  reach. The level comes from SpellLevels, for the lowest rank.
                  Your own row also checks the spell book (`learned`). Talent
                  spells use 10, the first talent level: a member with no
                  talents reads the same as one we could not read, so without
                  it they would show on every low-level member of the class
      * specs     Forever has one specialization per class, so no entry uses
                  `specs` or `specMods`
      * whole     a talent has two ranks in TraitNodeEntry but one amount, and
                  that amount cannot be per rank: Endurance's -60% would be
                  -120% at rank 2. `whole` applies it once from the first rank.
                  So a member with one point may show too short a cooldown
                  (UNVERIFIED in game; /sfcdcheck compares yours to the tooltip)

    Item set bonuses and the leftover "S03 - Tuning" passives are not used. The
    second would put Shield Wall (900s) at -600s, so it is plainly not live.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames or not SquizzFrames.IS_FOREVER then return end

local DATA = SquizzFrames.PartyCooldownsData
if not DATA then return end

local SPELLS = {
    -- DRUID
    { key = 22812,  class = "DRUID", cat = "personal", who = "self", cd = 60,  minLevel = 44 },  -- Barkskin
    { key = 22842,  class = "DRUID", cat = "personal", who = "self", cd = 180, minLevel = 36 },  -- Frenzied Regeneration
    { key = 29166,  class = "DRUID", cat = "external", who = "any",  cd = 360, minLevel = 40 },  -- Innervate
    { key = 740,    class = "DRUID", cat = "group",    who = "self", cd = 300, minLevel = 30,
      casts = {8918, 9862, 9863}, buffs = {740, 8918, 9862, 9863},
      mods = { {17123, "pct", -60, whole = true} } },                                            -- Tranquility

    -- HUNTER
    { key = 19263,  class = "HUNTER", cat = "personal", who = "self", cd = 300, talent = true, minLevel = 10,
      mods = { {1310496, "pct", -40, whole = true} } },                                          -- Deterrence

    -- MAGE
    { key = 11958,  class = "MAGE", cat = "personal", who = "self", cd = 300, talent = true, minLevel = 10 },   -- Ice Block
    { key = 11426,  class = "MAGE", cat = "personal", who = "self", cd = 30,  talent = true, minLevel = 10,
      casts = {13031, 13032, 13033}, buffs = {11426, 13031, 13032, 13033} },                     -- Ice Barrier

    -- PALADIN
    { key = 642,    class = "PALADIN", cat = "personal", who = "self", cd = 300, minLevel = 34,
      casts = {1020}, buffs = {642, 1020},
      mods = { {1224697, "flat", -60, whole = true} } },                                         -- Divine Shield
    { key = 498,    class = "PALADIN", cat = "personal", who = "self", cd = 300, minLevel = 6,
      casts = {5573}, buffs = {498, 5573},
      mods = { {1224697, "flat", -60, whole = true} } },                                         -- Divine Protection
    { key = 1311015, class = "PALADIN", cat = "personal", who = "self", cd = 300, talent = true, minLevel = 10,
      mods = { {1224697, "flat", -60, whole = true} } },                                         -- Templar's Bulwark
    { key = 1022,   class = "PALADIN", cat = "external", who = "any", cd = 300, minLevel = 10,
      casts = {5599, 10278}, buffs = {1022, 5599, 10278},
      mods = { {20174, "flat", -60, whole = true} } },                                           -- Blessing of Protection
    { key = 1044,   class = "PALADIN", cat = "external", who = "any", cd = 20, minLevel = 18 },  -- Blessing of Freedom

    -- PRIEST
    { key = 6346,   class = "PRIEST", cat = "external", who = "any", cd = 180, minLevel = 20 },  -- Fear Ward
    { key = 10060,  class = "PRIEST", cat = "external", who = "any", cd = 180, talent = true, minLevel = 10 },  -- Power Infusion

    -- ROGUE
    { key = 5277,   class = "ROGUE", cat = "personal", who = "self", cd = 300, minLevel = 8,
      mods = { {13742, "pct", -60, whole = true} } },                                            -- Evasion
    { key = 2983,   class = "ROGUE", cat = "personal", who = "self", cd = 300, minLevel = 10,
      casts = {8696, 11305}, buffs = {2983, 8696, 11305},
      mods = { {13742, "pct", -60, whole = true} } },                                            -- Sprint
    -- The cast leaves its aura through a triggered spell, one per rank.
    { key = 1856,   class = "ROGUE", cat = "personal", who = "self", cd = 300, minLevel = 22,
      casts = {1857}, buffs = {11327, 11329},
      mods = { {13981, "flat", -90, whole = true} } },                                           -- Vanish

    -- WARLOCK
    { key = 6229,   class = "WARLOCK", cat = "personal", who = "self", cd = 30, minLevel = 32,
      casts = {11739, 11740, 28610}, buffs = {6229, 11739, 11740, 28610} },                      -- Shadow Ward

    -- WARRIOR
    { key = 871,    class = "WARRIOR", cat = "personal", who = "self", cd = 900, minLevel = 28,
      mods = { {12312, "flat", -660, whole = true} } },                                          -- Shield Wall
    { key = 12975,  class = "WARRIOR", cat = "personal", who = "self", cd = 180, talent = true, minLevel = 10,
      buffs = {12976} },                                                                         -- Last Stand
    { key = 20230,  class = "WARRIOR", cat = "personal", who = "self", cd = 900, minLevel = 20 }, -- Retaliation
}

-- Only spells that the talent trees or plain class training can be shown to
-- give are in the table above. These are in the game's data with cooldowns, but
-- are not talents, and nothing found says how a player gets them (they look
-- like Season of Discovery runes). An icon for them would sit on every member
-- of the class, so /sfcdcheck names any you do know instead: that is the
-- evidence for moving one up.
DATA.unconfirmed = {
    DRUID   = {408024},                 -- Survival Instincts
    MAGE    = {425121, 425124},         -- Icy Veins, Arcane Surge
    PALADIN = {407788, 407804},         -- Avenging Wrath, Divine Sacrifice
    PRIEST  = {402004, 425207, 425294}, -- Pain Suppression, Power Word: Barrier, Dispersion
    WARLOCK = {426195},                 -- Vengeance
    WARRIOR = {402913, 426490},         -- Enraged Regeneration, Rallying Cry
}

for _, def in ipairs(SPELLS) do def.learned = true end

-- POTIONS. Healing potions and Healthstones have separate 2-minute categories
-- (4 and 1153) and leave no buff, so yours only, from the item cooldown. Combat
-- potions have no entry yet: this content has no short list of them or a shared
-- buff picked out to watch.
SPELLS[#SPELLS + 1] = { key = 439, label = "Health Potion", class = "ANY", cat = "potion", who = "self", cd = 120,
    ownOnly = true,
    items = {118, 858, 929, 1710, 3928, 13446, 18839, 223913, 223914, 241650} }
SPELLS[#SPELLS + 1] = { key = 6262, label = "Healthstone", class = "ANY", cat = "potion", who = "self", cd = 120,
    ownOnly = true,
    items = {5512, 19004, 19005, 5511, 19006, 19007, 5509, 19008, 19009, 5510, 19010, 19011, 9421, 19012, 19013} }

DATA.Prepare(SPELLS)
DATA.spells = SPELLS
DATA.BUILD = "1.60.1.70790"
