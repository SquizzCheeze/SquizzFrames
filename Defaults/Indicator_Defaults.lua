--[[ SquizzFrames Indicator Defaults ]]
local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local defaults = SquizzFrames.defaults
if not defaults then
    defaults = { profile = {} }
    SquizzFrames.defaults = defaults
end
if not defaults.profile then
    defaults.profile = {}
end

-- ============================================================
-- SPELL LISTS (mirrored from Cell's Indicator_DefaultSpells.lua)
-- Updated for The War Within (12.0/12.1)
-- ============================================================

-- Healer spells: active healing auras (HoTs, shields, beacons, etc.)
-- These are the "healer" spells that Cell creates via its first-run popup.
-- Used for a custom "Healers" indicator tracking YOUR healing auras on party,
-- AND as the curated source for the built-in Healer HoTs indicator's
-- "Built-in Spells" checklist (IndicatorWidgets.lua's CreateSetting_BuiltInHots).
-- Class-keyed (matches aoeHealings/crowdControls' shape) rather than a flat
-- array -- needed both to group the checklist by class and to filter it down
-- to just the VIEWING PLAYER's own class (a Priest can never cast a Druid
-- HoT, so showing all 6 healer classes' spells was pure noise). Flatten with
-- F.FlattenSpellTable wherever a plain spell-ID array is needed (e.g. the
-- "Add Healer Spells" bulk-import button, /sfhealers).
defaults.healerSpells = {
    DRUID = {
        [8936] = true,     -- Regrowth
        [774] = true,      -- Rejuvenation
        [155777] = true,   -- Rejuvenation (Germination)
        [33763] = true,    -- Lifebloom
        [188550] = true,   -- Lifebloom (duplicate ID for different ranks)
        [48438] = true,    -- Wild Growth
        [102351] = true,   -- Cenarion Ward
        [102352] = true,   -- Cenarion Ward
        [391891] = true,   -- Adaptive Swarm
        [145205] = true,   -- Efflorescence
        [383193] = true,   -- Grove Tending
        [439530] = true,   -- Symbiotic Blooms
    },
    EVOKER = {
        [363502] = true,   -- Dream Flight
        [370889] = true,   -- Twin Guardian
        [364343] = true,   -- Echo
        [355941] = true,   -- Dream Breath
        [376788] = true,   -- Dream Breath (Echo)
        [366155] = true,   -- Reversion
        [367364] = true,   -- Reversion (Echo)
        [373862] = true,   -- Temporal Anomaly
        [378001] = true,   -- Dream Projection (PvP)
        [373267] = true,   -- Lifebind
        [395296] = true,   -- Ebon Might (self)
        [395152] = true,   -- Ebon Might
        [360827] = true,   -- Blistering Scales
        [410089] = true,   -- Prescience
        [406732] = true,   -- Spatial Paradox (self)
        [406789] = true,   -- Spatial Paradox
        [445740] = true,   -- Enkindle
        [409895] = true,   -- Spiritbloom (Reverberations)
        [410263] = true,   -- Inferno's Blessing
        [410686] = true,   -- Symbiotic Bloom
        [413984] = true,   -- Shifting Sands
    },
    MONK = {
        [119611] = true,   -- Renewing Mist
        [124682] = true,   -- Enveloping Mist
        [325209] = true,   -- Enveloping Breath
        [406139] = true,   -- Chi Cocoon from Yu'lon
        [406220] = true,   -- Chi Cocoon from Chi-Ji
        [450769] = true,   -- Aspect of Harmony
        [450805] = true,   -- Purified Spirit
        [467281] = true,   -- Healing Elixir
        [115175] = true,   -- Soothing Mist
    },
    PALADIN = {
        [53563] = true,    -- Beacon of Light
        [223306] = true,   -- Bestow Faith
        [148039] = true,   -- Barrier of Faith
        [156910] = true,   -- Beacon of Faith
        [200025] = true,   -- Beacon of Virtue
        [287280] = true,   -- Glimmer of Light
        [156322] = true,   -- Eternal Flame
        [431381] = true,   -- Dawnlight
        [388013] = true,   -- Blessing of Spring
        [388007] = true,   -- Blessing of Summer
        [388010] = true,   -- Blessing of Autumn
        [388011] = true,   -- Blessing of Winter
        [200654] = true,   -- Tyr's Deliverance
        [1244893] = true,  -- Beacon of the Savior
    },
    PRIEST = {
        -- [139] = true,   -- Renew (removed in 12.0)
        -- [200829] = true, -- Plea: NOT an aura, no buff placed on target
        [41635] = true,    -- Prayer of Mending
        [17] = true,       -- Power Word: Shield
        [194384] = true,   -- Atonement
        [77489] = true,    -- Echo of Light
        [372847] = true,   -- Blessed Bolt
        [1253593] = true,  -- Void Shield
    },
    SHAMAN = {
        [974] = true,      -- Earth Shield
        [383648] = true,   -- Earth Shield (talent)
        [61295] = true,    -- Riptide
        [382024] = true,   -- Earthliving Weapon
        [375986] = true,   -- Primordial Wave
        [444490] = true,   -- Hydrobubble
        -- [73920] = true, -- Healing Rain (not a unit buff)
    },
}

-- AoE Healing spells (cooldown-based AoE heals)
-- Tracked separately from healerSpells for "AoE Healings" indicator
defaults.aoeHealings = {
    DRUID = {
        [740] = true,        -- Tranquility
        [145205] = true,     -- Efflorescence
    },
    EVOKER = {
        [355916] = true,     -- Emerald Blossom
        [361361] = true,     -- Fluttering Seedlings
        [363534] = true,     -- Rewind
        [367230] = true,     -- Spiritbloom
        [370984] = true,     -- Emerald Communion
        [371441] = true,     -- Life-Giver's Flame
        [371879] = true,     -- Cycle of Life
        [377509] = false,    -- Dream Projection (PvP)
    },
    MONK = {
        [115098] = true,     -- Chi Wave
        [123986] = true,     -- Chi Burst
        [115310] = true,     -- Revival
        [322118] = true,     -- Invoke Yu'lon
        [388193] = true,     -- Jadefire Stomp
        [443028] = true,     -- Celestial Conduit
        [343819] = false,    -- Gust of Mists
    },
    PALADIN = {
        [85222] = true,      -- Light of Dawn
        [119952] = true,     -- Arcing Light
        [114165] = true,     -- Holy Prism
        [200654] = true,     -- Tyr's Deliverance
        [216371] = true,     -- Avenging Crusader
    },
    PRIEST = {
        [120517] = true,     -- Halo
        [34861] = true,      -- Holy Word: Sanctify
        [596] = true,        -- Prayer of Healing
        [64843] = true,      -- Divine Hymn
        [204883] = true,     -- Circle of Healing
        [281265] = true,     -- Holy Nova
        [15290] = true,      -- Vampiric Embrace
        [372787] = true,     -- Divine Word: Sanctuary
    },
    SHAMAN = {
        [1064] = true,       -- Chain Heal
        [73920] = true,      -- Healing Rain
        [108280] = true,     -- Healing Tide Totem
        [52042] = true,      -- Healing Stream Totem
        [197995] = true,     -- Wellspring
        [114911] = true,     -- Ancestral Guidance
        [382311] = true,     -- Ancestral Awakening
        [207778] = true,     -- Downpour
        [114083] = true,     -- Restorative Mists
    },
}

-- External cooldowns (defensives/utility cast ON others)
defaults.externalCooldowns = {
    DEATHKNIGHT = {
        [51052] = true,      -- Anti-Magic Zone
    },
    DEMONHUNTER = {
        [196718] = true,     -- Darkness
    },
    DRUID = {
        [102342] = true,     -- Ironbark
    },
    EVOKER = {
        [374227] = true,     -- Zephyr
        [357170] = true,     -- Time Dilation
        [363534] = true,     -- Rewind
        [360995] = true,     -- Verdant Embrace
        [378441] = true,     -- Time Stop (PvP)
        [374348] = true,     -- Renewing Blaze
    },
    MAGE = {
        [198158] = true,     -- Mass Invisibility
        [414660] = {         -- Mass Barrier (sub-spells)
            [414661] = false, -- Ice Barrier
            [414662] = false, -- Blazing Barrier
            [414663] = false, -- Prismatic Barrier
        },
    },
    MONK = {
        [116849] = true,     -- Life Cocoon
        [202248] = false,    -- Guided Meditation
        [116841] = true,     -- Tiger's Lust
    },
    PALADIN = {
        [1022] = true,       -- Blessing of Protection
        [6940] = true,       -- Blessing of Sacrifice
        [204018] = true,     -- Blessing of Spellwarding
        [1044] = true,       -- Blessing of Freedom
        [31821] = true,      -- Aura Mastery
        [210256] = true,     -- Blessing of Sanctuary
        [228050] = false,    -- Divine Shield (Forgotten Queen's Guard)
    },
    PRIEST = {
        [33206] = true,      -- Pain Suppression
        [47788] = true,      -- Guardian Spirit
        [10060] = true,      -- Power Infusion
        [62618] = true,      -- Power Word: Barrier
        [213610] = true,     -- Holy Ward
        [197268] = true,     -- Ray of Hope
    },
    ROGUE = {
        [114018] = true,     -- Shroud of Concealment
    },
    SHAMAN = {
        [98008] = true,      -- Spirit Link Totem
        [201633] = true,     -- Earthen Wall Totem
        [8178] = true,       -- Grounding Totem
        [383018] = true,     -- Stoneskin Totem
    },
    WARRIOR = {
        [97462] = true,      -- Rallying Cry
        [3411] = true,       -- Intervene
        [213871] = true,     -- Bodyguard
    },
}

-- Personal defensive cooldowns (self-cast)
defaults.defensiveCooldowns = {
    DEATHKNIGHT = {
        [48707] = true,      -- Anti-Magic Shell
        [48792] = true,      -- Icebound Fortitude
        [49028] = true,      -- Dancing Rune Weapon
        [55233] = true,      -- Vampiric Blood
        [49039] = false,     -- Lichborne
        [194679] = true,     -- Rune Tap
    },
    DEMONHUNTER = {
        [196555] = true,     -- Netherwalk
        [198589] = true,     -- Blur
        [187827] = false,    -- Metamorphosis
    },
    DRUID = {
        [22812] = true,      -- Barkskin
        [61336] = true,      -- Survival Instincts
        [200851] = true,     -- Rage of the Sleeper
        [102558] = true,     -- Incarnation: Guardian of Ursoc
        [22842] = true,      -- Frenzied Regeneration
    },
    EVOKER = {
        [363916] = true,     -- Obsidian Scales
        [374348] = true,     -- Renewing Blaze
        [370960] = true,     -- Emerald Communion
        [431872] = false,    -- Temporality (Chronowarden)
        [377088] = false,    -- Rush of Vitality
    },
    HUNTER = {
        [186265] = true,     -- Aspect of the Turtle
        [264735] = true,     -- Survival of the Fittest
    },
    MAGE = {
        [45438] = true,      -- Ice Block
        [414658] = true,     -- Ice Cold
        [113862] = false,    -- Greater Invisibility
        [55342] = false,     -- Mirror Image
        [342246] = true,     -- Alter Time
    },
    MONK = {
        [115176] = false,    -- Zen Meditation
        [115203] = true,     -- Fortifying Brew
        [122278] = true,     -- Dampen Harm
        [122783] = true,     -- Diffuse Magic
        [125174] = true,     -- Touch of Karma
        [443113] = true,     -- Strength of the Black Ox
    },
    PALADIN = {
        [498] = true,        -- Divine Protection
        [642] = true,        -- Divine Shield
        [31850] = true,      -- Ardent Defender
        [86659] = true,      -- Guardian of Ancient Kings
        [212641] = true,     -- Guardian of Ancient Kings (talent)
        [205191] = true,     -- Eye for an Eye
        [389539] = true,     -- Sentinel
        [184662] = true,     -- Shield of Vengeance
    },
    PRIEST = {
        [47585] = true,      -- Dispersion
        [19236] = true,      -- Desperate Prayer
        [586] = true,        -- Fade
        [193065] = true,     -- Protective Light
        [27827] = true,      -- Spirit of Redemption
    },
    ROGUE = {
        [1966] = true,       -- Feint
        [5277] = true,       -- Evasion
        [31224] = false,     -- Cloak of Shadows
    },
    SHAMAN = {
        [108271] = true,     -- Astral Shift
        [409293] = true,     -- Burrow (PvP)
        [114893] = true,     -- Stone Bulwark
    },
    WARLOCK = {
        [104773] = true,     -- Unending Resolve
        [212295] = true,     -- Nether Ward (PvP)
        [108416] = true,     -- Dark Pact
    },
    WARRIOR = {
        [871] = true,        -- Shield Wall
        [12975] = true,      -- Last Stand
        [23920] = true,      -- Spell Reflection
        [118038] = true,     -- Die by the Sword
        [184364] = true,     -- Enraged Regeneration
    },
}

-- Tank Active Mitigation buffs
defaults.tankActiveMitigations = {
    -- Death Knight
    195181, -- Bone Shield
    -- Demon Hunter
    203819, -- Demon Spikes
    -- Druid
    192081, -- Ironfur
    -- Monk
    215479, -- Shuffle
    -- Paladin
    132403, -- Shield of the Righteous
    -- Warrior
    132404, -- Shield Block
}

-- Crowd Controls (for "Crowd Controls" indicator)
defaults.crowdControls = {
    DEATHKNIGHT = {
        [47476] = true,      -- Strangulate (PvP)
        [91800] = true,      -- Gnaw
        [207167] = true,     -- Blinding Sleet
        [210128] = true,     -- Reanimation
        [221562] = true,     -- Asphyxiate
        [287254] = false,    -- Dead of Winter
        [377048] = true,     -- Absolute Zero
    },
    DEMONHUNTER = {
        [179057] = true,     -- Chaos Nova
        [205630] = true,     -- Illidan's Grasp
        [204490] = true,     -- Sigil of Silence
        [207684] = true,     -- Sigil of Misery
        [211881] = true,     -- Fel Eruption
        [217832] = true,     -- Imprison
    },
    DRUID = {
        [99] = true,         -- Incapacitating Roar
        [2637] = true,       -- Hibernate
        [5211] = true,       -- Mighty Bash
        [22570] = true,      -- Maim
        [33786] = true,      -- Cyclone
        [81261] = true,      -- Solar Beam
        [127797] = true,     -- Ursol's Vortex
        [163505] = false,    -- Rake
        [209749] = true,     -- Faerie Swarm
        [202244] = true,     -- Overrun
        [410065] = false,    -- Reactive Resin
    },
    EVOKER = {
        [360806] = true,     -- Sleep Walk
        [372245] = true,     -- Terror of the Skies
        [408544] = true,     -- Seismic Slam
    },
    HUNTER = {
        [1513] = true,       -- Scare Beast
        [3355] = true,       -- Freezing Trap
        [24394] = true,      -- Intimidation
        [117526] = true,     -- Binding Shot
        [213691] = true,     -- Scatter Shot
        [357021] = false,    -- Consecutive Concussion
        [407032] = true,     -- Sticky Tar Bomb
    },
    MAGE = {
        [118] = true,        -- Polymorph
        [31661] = true,      -- Dragon's Breath
        [82691] = true,      -- Ring of Frost
        [383121] = true,     -- Mass Polymorph
        [389831] = false,    -- Snowdrift
    },
    MONK = {
        [115078] = true,     -- Paralysis
        [119381] = true,     -- Leg Sweep
        [198909] = true,     -- Song of Chi-Ji
        [202274] = true,     -- Hot Trub
        [202346] = true,     -- Double Barrel
        [233759] = true,     -- Grapple Weapon (PvP)
    },
    PALADIN = {
        [853] = true,        -- Hammer of Justice
        [10326] = true,      -- Turn Evil
        [20066] = true,      -- Repentance
        [105421] = true,     -- Blinding Light
        [234299] = true,     -- Fist of Justice
        [255941] = false,    -- Wake of Ashes
    },
    PRIEST = {
        [605] = true,        -- Mind Control
        [8122] = true,       -- Psychic Scream
        [9484] = true,       -- Shackle Undead
        [15487] = true,      -- Silence
        [64044] = true,      -- Psychic Horror
        [88625] = true,      -- Holy Word: Chastise
    },
    ROGUE = {
        [408] = true,        -- Kidney Shot
        [1776] = true,       -- Gouge
        [1833] = true,       -- Cheap Shot
        [2094] = true,       -- Blind
        [6770] = true,       -- Sap
        [207777] = true,     -- Dismantle (PvP)
        [212183] = true,     -- Smoke Bomb
    },
    SHAMAN = {
        [51514] = true,      -- Hex
        [77505] = true,      -- Earthquake
        [118345] = true,     -- Pulverize
        [118905] = true,     -- Static Charge
        [197214] = true,     -- Sundering
        [305485] = true,     -- Lightning Lasso
    },
    WARLOCK = {
        [710] = true,        -- Banish
        [5484] = true,       -- Howl of Terror
        [5782] = true,       -- Fear
        [6358] = true,       -- Seduction
        [6789] = true,       -- Mortal Coil
        [22703] = true,      -- Infernal Awakening
        [30283] = true,      -- Shadowfury
        [89766] = true,      -- Axe Toss
        [196364] = false,    -- Unstable Affliction
        [213688] = true,     -- Fel Cleave
    },
    WARRIOR = {
        [5246] = true,       -- Intimidating Shout
        [132168] = true,     -- Shockwave
        [132169] = true,     -- Storm Bolt
        [236077] = true,     -- Disarm (PvP)
    },
    UNCATEGORIZED = {
        [20549] = true,      -- War Stomp
        [107079] = true,     -- Quaking Palm
        [255723] = true,     -- Bull Rush
        [287712] = true,     -- Haymaker
    },
}

-- Raid utility buffs (for the "Missing Buffs" indicator -- shows the icon of
-- any one of these NOT currently present on the unit, i.e. inverted from
-- every other curated list here). One entry per class/spec-line that
-- provides a raid-wide utility buff in current Retail (post-consolidation --
-- e.g. Fortitude/Inspiring Presence/etc merged into single spells over past
-- expansions). Class-keyed to match every other curated table's shape (the
-- "Built-in Spells" checklist widget -- IndicatorWidgets.lua's
-- CreateSetting_BuiltInsForKind -- expects this shape generically).
-- Monk (Mystic Touch) and Demon Hunter (Chaos Brand) were removed -- both
-- are debuffs applied to the ENEMY target, not buffs cast on party members,
-- so they never belonged in a "missing buff on this unit" list to begin
-- with. Verified against Squizzumables' own BH.defaults.classBuffs
-- (Squizzumables_Config.lua) rather than general knowledge, since that
-- addon's own list is kept current per-expansion (see its CLAUDE.md).
defaults.raidBuffs = {
    PRIEST = { [21562] = true },   -- Power Word: Fortitude
    MAGE = { [1459] = true },      -- Arcane Intellect
    WARRIOR = { [6673] = true },   -- Battle Shout
    DRUID = { [1126] = true },     -- Mark of the Wild
    SHAMAN = { [462854] = true },  -- Skyfury
    -- Blessing of the Bronze: cast as 364342, but the AURA applied to the
    -- RECIPIENT is one of 26 different spell IDs depending on the
    -- recipient's own class (it grants THEIR class-specific movement
    -- ability) -- e.g. a Priest recipient gets 381753 (Leap of Faith), a
    -- Rogue recipient gets 381754 (Sprint), etc. Only the single cast-spell
    -- ID is listed here (one blanket checkbox in the Built-in Spells
    -- checklist, matching every other curated buff) -- the 26 recipient
    -- variants live in defaults.raidBuffVariants below and are checked
    -- internally by CheckMissingBuffs, never shown as separate UI entries.
    EVOKER = { [364342] = true }, -- Blessing of the Bronze
}

-- Alternate aura IDs for a curated raidBuffs entry that can show up as a
-- DIFFERENT spell ID than the one listed above, depending on context (e.g.
-- Blessing of the Bronze's per-recipient-class variants). Keyed by the
-- primary ID shown in the options checklist; CheckMissingBuffs treats
-- presence of ANY listed variant as presence of the primary buff, without
-- ever surfacing the variants as their own separately-hideable checklist
-- entries. Sourced from Squizzumables' BH.defaults.classBuffs
-- (Squizzumables_Config.lua).
defaults.raidBuffVariants = {
    [364342] = { -- Blessing of the Bronze
        381748, -- Evoker (Hover)
        381732, -- Death Knight (Death's Advance)
        381746, -- Druid (Dash/Tiger Dash)
        381749, -- Hunter (Aspect of the Cheetah)
        381750, -- Mage (Blink/Shimmer)
        381751, -- Monk (Roll/Chi Torpedo)
        381752, -- Paladin (Divine Steed)
        381753, -- Priest (Leap of Faith)
        381754, -- Rogue (Sprint)
        381756, -- Shaman (Gust of Wind/Spirit Walk)
        381741, -- Demon Hunter (Fel Rush/Infernal Strike)
        381757, -- Warlock (Demonic Circle: Teleport)
        381758, -- Warrior (Heroic Leap)
        432649, -- Death Knight (variant)
        432655, -- Demon Hunter (variant)
        432658, -- Druid (variant)
        432659, -- Evoker (variant)
        432660, -- Hunter (variant)
        432661, -- Mage (variant)
        432662, -- Monk (variant)
        432663, -- Paladin (variant)
        432664, -- Priest (variant)
        432665, -- Rogue (variant)
        432652, -- Shaman (variant)
        432667, -- Warlock (variant)
        432668, -- Warrior (variant)
    },
}

-- Drinking detection
defaults.drinks = {
    170906,  -- Food & Drink
    167152,  -- Refreshment
    430,     -- Drink
    43182,   -- Drink
    172786,  -- Drink
    308433,  -- Food & Drink
    369162,  -- Drink
    456574,  -- Cinder Nectar
    461063,  -- Quiet Contemplation (Earthen)
    1277461, -- Drink (12.x current client -- confirmed via in-game spell inspector)
    1232065, -- Food & Drink (confirmed via user-provided tooltip screenshot,
             -- another same-named variant Blizzard apparently assigns a
             -- different spellId depending on which food/drink item was used)
}

-- Curated Debuff Blacklist starter set for the Debuffs indicator's blacklist
-- checklist (Modules/Indicators/IndicatorWidgets.lua's CreateSetting_DebuffBlacklist).
-- Deliberately small and conservative: these are the Bloodlust/Heroism-family
-- "Sated"/"Exhaustion" debuffs, verified against EllesmereUIRaidFrames'
-- SATED_DEBUFFS table (same PTR client) rather than guessed -- they're
-- near-universal raid/M+ clutter (every lust cast leaves one on everyone) and
-- the spell IDs are stable across expansions. Anything else a user wants
-- blacklisted can be added by spell ID directly in the panel.
defaults.curatedDebuffBlacklist = {
    57723,   -- Exhaustion (Heroism)
    57724,   -- Sated (Bloodlust)
    80354,   -- Temporal Displacement (Time Warp)
    95809,   -- Insanity (Ancient Hysteria)
    160455,  -- Fatigued (Netherwinds)
    264689,  -- Fatigued (Primal Rage)
    390435,  -- Exhaustion (Fury of the Aspects)
    428628,  -- Exhaustion (variant)
}

-- ============================================================
-- CUSTOM INDICATOR FACTORY
-- ============================================================
-- A factory that mirrors Cell's I.GetDefaultCustomIndicatorTable but uses
-- SquizzFrames font/style conventions (no "Cell" fonts, no ElvUI textures).
-- Returns a fresh indicator table for a custom indicator of the given type.
function SquizzFrames.GetDefaultCustomIndicatorTable(name, indicatorName, type, auraType)
    local t = {}
    local defaultFont = {{"Friz QT__", 11, "OUTLINE", false, "TOPRIGHT", 2, 1, {1, 1, 1}},
                        {"Friz QT__", 11, "OUTLINE", false, "BOTTOMRIGHT", 2, -1, {1, 1, 1}}}

    if type == "icon" then
        t = {
            name = name, indicatorName = indicatorName, type = type,
            enabled = true, auraType = auraType, auras = {},
            position = {"TOPRIGHT", "button", "TOPRIGHT", 0, 3}, frameLevel = 5,
            size = {13, 13},
            font = defaultFont,
            showStack = true, showDuration = false, showAnimation = true,
            glowOptions = {"None", {0.95, 0.95, 0.32, 1}},
        }
    elseif type == "text" then
        t = {
            name = name, indicatorName = indicatorName, type = type,
            enabled = true, auraType = auraType, auras = {},
            position = {"TOPRIGHT", "button", "TOPRIGHT", 0, 3}, frameLevel = 5,
            font = {"Friz QT__", 12, "OUTLINE", false},
            colors = {{0, 1, 0, 1}, {false, 0.5, {1, 1, 0, 1}}, {false, 3, {1, 0, 0, 1}}},
            duration = {true, false, 0},
            stack = {true, false},
        }
    elseif type == "bar" then
        t = {
            name = name, indicatorName = indicatorName, type = type,
            enabled = true, auraType = auraType, auras = {},
            position = {"BOTTOMRIGHT", "button", "TOPRIGHT", 0, -1}, frameLevel = 5,
            size = {18, 4},
            colors = {{0, 1, 0, 1}, {false, 0.5, {1, 1, 0, 1}}, {false, 3, {1, 0, 0, 1}}, {0, 0, 0, 1}, {0.07, 0.07, 0.07, 0.9}},
            orientation = "horizontal",
            font = {{"Friz QT__", 11, "OUTLINE", false, "LEFT", 1, 0, {1, 1, 1}},
                    {"Friz QT__", 11, "OUTLINE", false, "RIGHT", -1, 0, {1, 1, 1}}},
            showStack = false, showDuration = false,
            maxValue = {false, 10, true},
            glowOptions = {"None", {0.95, 0.95, 0.32, 1}},
        }
    elseif type == "bars" then
        t = {
            name = name, indicatorName = indicatorName, type = type,
            enabled = true, auraType = auraType, auras = {},
            position = {"TOPRIGHT", "button", "TOPRIGHT", 0, 0}, frameLevel = 5,
            size = {18, 4}, num = 3, numPerLine = 3,
            orientation = "top-to-bottom", spacing = {-1, -1},
            font = defaultFont,
            showStack = false, showDuration = false,
            maxValue = {false, 10, true},
            glowOptions = {"None", {0.95, 0.95, 0.32, 1}},
        }
    elseif type == "rect" then
        t = {
            name = name, indicatorName = indicatorName, type = type,
            enabled = true, auraType = auraType, auras = {},
            position = {"TOPRIGHT", "button", "TOPRIGHT", 0, 2}, frameLevel = 5,
            size = {11, 4},
            colors = {{0, 1, 0, 1}, {false, 0.5, {1, 1, 0, 1}}, {false, 3, {1, 0, 0, 1}}, {0, 0, 0, 1}},
            font = {{"Friz QT__", 11, "OUTLINE", false, "LEFT", 1, 0, {1, 1, 1}},
                    {"Friz QT__", 11, "OUTLINE", false, "RIGHT", -1, 0, {1, 1, 1}}},
            showStack = false, showDuration = false,
            glowOptions = {"None", {0.95, 0.95, 0.32, 1}},
        }
    elseif type == "icons" then
        t = {
            name = name, indicatorName = indicatorName, type = type,
            enabled = true, auraType = auraType, auras = {},
            position = {"TOPRIGHT", "button", "TOPRIGHT", 0, 3}, frameLevel = 5,
            size = {13, 13}, num = 5, numPerLine = 5,
            orientation = "right-to-left", spacing = {0, 0},
            font = defaultFont,
            showStack = true, showDuration = false, showAnimation = true,
            glowOptions = {"None", {0.95, 0.95, 0.32, 1}},
        }
    elseif type == "color" then
        t = {
            name = name, indicatorName = indicatorName, type = type,
            enabled = true, auraType = auraType, auras = {},
            anchor = "healthbar-current", frameLevel = 1,
            -- Single highlight color applied to the anchor target while the
            -- top-priority tracked aura is active (see CreateColorOverlay /
            -- entry.color in Custom_Dispatch.lua). Matches the "customColors"
            -- token's {{r,g,b,a}} shape -- the old default here stored an
            -- unrelated Cell HP-gradient shape under the wrong field (t.colors)
            -- that nothing ever read.
            customColors = {{0, 1, 0, 1}},
            -- Switch to a second colour once the aura drops below the
            -- threshold. Off by default. Only the AuraEngine-backed path
            -- (12.1, non-trackByName, health-bar anchors) can honour it -- the
            -- legacy scan has no secret-safe way to test remaining time.
            expiringEnabled = false,
            expiringThreshold = 5,
            expiringColor = {"custom_color", 1, 0, 0, 1},
        }
    elseif type == "texture" then
        t = {
            name = name, indicatorName = indicatorName, type = type,
            enabled = true, auraType = auraType, auras = {},
            position = {"TOP", "button", "TOP", 0, 0}, size = {16, 16}, frameLevel = 10,
            texture = {"Interface\\AddOns\\SquizzFrames\\Media\\Textures\\circle.tga", 0, {1, 1, 1, 1}},
            fadeOut = true,
        }
    elseif type == "glow" then
        t = {
            name = name, indicatorName = indicatorName, type = type,
            enabled = true, auraType = auraType, auras = {},
            frameLevel = 1,
            glowOptions = {"Pixel", {0.95, 0.95, 0.32, 1}, 9, 0.25, 8, 2},
            fadeOut = true,
        }
    elseif type == "overlay" then
        t = {
            name = name, indicatorName = indicatorName, type = type,
            enabled = true, auraType = auraType, auras = {},
            smooth = false, frameLevel = 1,
            colors = {{0, 0.61, 1, 0.55}, {false, 0.5, {1, 1, 0, 0.5}}, {false, 3, {1, 0, 0, 0.5}}},
            orientation = "horizontal",
        }
    elseif type == "block" then
        t = {
            name = name, indicatorName = indicatorName, type = type,
            enabled = true, auraType = auraType, auras = {},
            position = {"TOPRIGHT", "button", "TOPRIGHT", 0, 3}, frameLevel = 5,
            size = {10, 10},
            colors = {"duration", {0, 1, 0, 1}, {false, 0.5, {1, 1, 0, 1}}, {false, 3, {1, 0, 0, 1}}, {0, 0, 0, 1}},
            font = defaultFont,
            showStack = false, showDuration = false,
            glowOptions = {"None", {0.95, 0.95, 0.32, 1}},
        }
    elseif type == "blocks" then
        t = {
            name = name, indicatorName = indicatorName, type = type,
            enabled = true, auraType = auraType, auras = {},
            position = {"TOPRIGHT", "button", "TOPRIGHT", 0, 3}, frameLevel = 5,
            size = {10, 10}, num = 5, numPerLine = 5,
            orientation = "right-to-left", spacing = {-1, -1},
            font = defaultFont,
            showStack = false, showDuration = false,
            glowOptions = {"None", {0.95, 0.95, 0.32, 1}},
        }
    elseif type == "border" then
        t = {
            name = name, indicatorName = indicatorName, type = type,
            enabled = true, auraType = auraType, auras = {},
            thickness = 2, frameLevel = 10,
            fadeOut = true,
        }
    end

    if auraType == "buff" then
        t.castBy = "me"
        t.trackByName = false
    else
        t.castBy = "anyone"
    end

    return t
end

-- ------------------------------------------------------------------
-- Convenience: Create a "Healers" custom indicator (icons type)
-- Mirrors Cell's first-run popup that creates a Healers indicator.
-- Call this from options or chat command: /sf healers
-- ------------------------------------------------------------------
function SquizzFrames.CreateHealersIndicator()
    local db = SquizzFrames.db and SquizzFrames.db.profile
    if not db or not db.layout or not db.layout.indicators or not db.layout.indicatorsRaid then
        print("|cffff0009[SquizzFrames]|r DB not ready")
        return
    end

    -- Unique name checked against BOTH lists -- created in both (see below),
    -- so a name only unique in one could still collide in the other.
    local indicatorName
    local maxNum = 0
    for _, list in ipairs({ db.layout.indicators, db.layout.indicatorsRaid }) do
        for _, t in ipairs(list) do
            if t.type ~= "built-in" then
                local n = tonumber(t.indicatorName:match("indicator(%d+)"))
                if n and n > maxNum then maxNum = n end
            end
        end
    end
    indicatorName = "indicator" .. (maxNum + 1)

    -- Use healerSpells (active healing auras/HoTs/shields) -- class-keyed,
    -- flatten to the plain spell-ID array a custom indicator's auras list expects.
    local healerSpellsTable = SquizzFrames.defaults and SquizzFrames.defaults.healerSpells or {}
    local healerSpells = SquizzFrames.F.FlattenSpellTable(healerSpellsTable)

    -- Created in BOTH Party and Raid (matches /sf healer's own preset, which
    -- configures both) -- a healer cares about tracking their own heals on
    -- raid frames at least as much as party's. Independent table per list
    -- (F.CopyTable), not the same object twice -- editing one context's copy
    -- later must never silently edit the other's.
    for _, isRaid in ipairs({ false, true }) do
        local newTable = SquizzFrames.GetDefaultCustomIndicatorTable("Healers", indicatorName, "icons", "buff")
        newTable.auras = SquizzFrames.F.CopyTable(healerSpells)
        newTable.castBy = "me"  -- track only MY heals
        newTable.trackByName = false

        -- Fire update to rebuild indicators on all buttons. FindOrCreateIndicatorSlot
        -- (Indicators.lua) inserts this into the profile's indicator list itself —
        -- inserting here too would duplicate the entry.
        SquizzFrames:Fire("UpdateIndicators", indicatorName, "create", newTable, nil, isRaid)
    end
    print("|cff33cc99[SquizzFrames]|r Created 'Healers' indicator (" .. indicatorName .. ") with " .. #healerSpells .. " spells (Party + Raid)")
end

-- Slash command for quick creation
SLASH_SQUIZZHEALERS1 = "/sfhealers"
SlashCmdList["SQUIZZHEALERS"] = function()
    SquizzFrames.CreateHealersIndicator()
end