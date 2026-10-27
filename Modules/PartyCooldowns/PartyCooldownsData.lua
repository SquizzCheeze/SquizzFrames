--[[
    Party Cooldowns: the spell table.

    Taken from the game's own data tables for the LIVE build (12.1.5.70575,
    wago.tools DB2 exports), not from any other addon:
      * cd        SpellCooldowns RecoveryTime / CategoryRecoveryTime, or the
                  charge category's ChargeRecoveryTime for a charge spell
      * buffs     the aura the cast puts on someone (SpellEffect: APPLY_AURA on
                  the caster, or the triggered/area aura for the indirect ones
                  such as Fortifying Brew 115203 -> 120954, Blur -> 212800)
      * talent    the cast is granted by a talent node (TraitDefinition), so
                  it is hidden for anyone whose talents are known and lack it
      * mods      talents whose effects change the cooldown, found by spell
                  family mask (SPELLMOD_COOLDOWN 11, auras 107 flat / 108 %)
                  or by charge category (453 flat / 454 % recharge, 411 +max
                  charges, 341 flat category cooldown). PvP talents excluded.
                  { talentSpellID, "flat" seconds | "pct" percent | "chg" }.
                  For a charge spell only the recharge modifiers count: the
                  game keeps those separate (Honed Reflexes carries both, a
                  plain -10% and a -10% recharge), and counting both would
                  double it.
      * specMods  the same kind of modifier carried by a SPEC PASSIVE
                  (SpecializationSpells), applied to everyone in that spec:
                  { [specID] = { {"flat"|"pct"|"chg", amount}, ... } }.
                  Fortifying Brew is the big one: 6 min in the table, 2 min
                  for Mistweaver and Windwalker (user-confirmed in game,
                  2026-10-27). Modifiers from anything else that is neither a
                  current talent nor a spec passive are deliberately NOT used:
                  the data still holds dozens from old expansions (legendaries,
                  conduits, set bonuses, retired ranks such as a second
                  "Fortifying Brew" -4 min nothing grants any more), and
                  applying them would be wrong. /sfcdcheck compares the result
                  with your own tooltips.
    Hand-chosen: which spells are worth showing, the category, the specs a
    talent-free cast belongs to, and `who`:
      * "self"  the buff lands on the caster, so only the caster's own unit
                is watched
      * "any"   an external or a zone: the buff can land on anyone, so every
                group member is watched and the cooldown goes to whoever in
                the group can cast it

    Only cooldowns that leave a buff can be tracked in combat -- see the
    kiraui-party-cds-technique notes. Interrupts and most damage cooldowns
    leave none.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

-- key = the cast's spell ID (also the icon and the talent check).
-- casts lists alternative cast IDs that share the cooldown (Ice Cold).
local SPELLS = {
    -- DEATH KNIGHT
    { key = 48707,  class = "DEATHKNIGHT", cat = "personal", who = "self", cd = 60,  talent = true,
      mods = { {205727, "flat", -20}, {457574, "flat", 20} } },                 -- Anti-Magic Shell
    { key = 48792,  class = "DEATHKNIGHT", cat = "personal", who = "self", cd = 120, talent = true,
      mods = { {373926, "flat", -60} } },                                        -- Icebound Fortitude
    { key = 49039,  class = "DEATHKNIGHT", cat = "personal", who = "self", cd = 120,
      mods = { {437122, "flat", -30}, {389682, "flat", -30} } },                 -- Lichborne
    { key = 55233,  class = "DEATHKNIGHT", cat = "personal", who = "self", cd = 90,  talent = true,
      specs = {250} },                                                           -- Vampiric Blood
    { key = 51052,  class = "DEATHKNIGHT", cat = "group", who = "any", cd = 240, talent = true,
      buffs = {145629}, mods = { {374383, "flat", -60} } },                      -- Anti-Magic Zone

    -- DEMON HUNTER
    { key = 198589, class = "DEMONHUNTER", cat = "personal", who = "self", cd = 60, charges = 1,
      buffs = {212800}, specs = {577, 1480}, mods = { {1266307, "chg", 1} } },   -- Blur
    { key = 187827, class = "DEMONHUNTER", cat = "personal", who = "self", cd = 120, charges = 1,
      specs = {581} },                                                           -- Metamorphosis (Vengeance)
    { key = 196718, class = "DEMONHUNTER", cat = "group", who = "any", cd = 300, talent = true,
      buffs = {209426}, mods = { {389783, "flat", -120} } },                     -- Darkness

    -- DRUID
    { key = 22812,  class = "DRUID", cat = "personal", who = "self", cd = 60,
      mods = { {203965, "pct", -12} },
      specMods = { [104] = { {"flat", -15} } } },                                -- Barkskin
    { key = 61336,  class = "DRUID", cat = "personal", who = "self", cd = 180, charges = 1, talent = true,
      specs = {103, 104}, mods = { {203965, "pct", -12} },
      specMods = { [104] = { {"chg", 1} } } },                                   -- Survival Instincts
    { key = 102342, class = "DRUID", cat = "external", who = "any", cd = 90, talent = true,
      specs = {105}, mods = { {382552, "flat", -20} } },                         -- Ironbark

    -- EVOKER
    { key = 363916, class = "EVOKER", cat = "personal", who = "self", cd = 90, charges = 1, talent = true,
      mods = { {375406, "chg", 1}, {412713, "pct", -10} } },                     -- Obsidian Scales
    { key = 357170, class = "EVOKER", cat = "external", who = "any", cd = 60, charges = 1, talent = true,
      specs = {1468}, mods = { {376204, "chg", 1}, {376204, "flat", -10} } },    -- Time Dilation
    { key = 374227, class = "EVOKER", cat = "group", who = "any", cd = 120, talent = true },  -- Zephyr

    -- HUNTER
    { key = 186265, class = "HUNTER", cat = "personal", who = "self", cd = 180,
      mods = { {266921, "flat", -15}, {1258485, "flat", -30} } },                -- Aspect of the Turtle
    { key = 264735, class = "HUNTER", cat = "personal", who = "self", cd = 90, charges = 1, talent = true,
      mods = { {459450, "chg", 1} } },                                           -- Survival of the Fittest

    -- MAGE
    { key = 45438,  class = "MAGE", cat = "personal", who = "self", cd = 240, charges = 1, talent = true,
      casts = {414658}, buffs = {45438, 414658},
      mods = { {382424, "flat", -30}, {1244110, "chg", 1}, {1244110, "flat", -30},
               {1265517, "flat", -30} } },                                       -- Ice Block / Ice Cold
    { key = 342245, class = "MAGE", cat = "personal", who = "self", cd = 60, talent = true,
      buffs = {342246} },                                                        -- Alter Time
    { key = 110959, class = "MAGE", cat = "personal", who = "self", cd = 120, talent = true,
      buffs = {110960}, mods = { {210476, "flat", -60} } },                      -- Greater Invisibility
    { key = 55342,  class = "MAGE", cat = "personal", who = "self", cd = 120, talent = true,
      mods = { {1244025, "flat", -30} } },                                       -- Mirror Image

    -- MONK
    { key = 115203, class = "MONK", cat = "personal", who = "self", cd = 360,
      buffs = {120954}, mods = { {388813, "flat", -30} },
      specMods = { [269] = { {"flat", -240} }, [270] = { {"flat", -240} } } },   -- Fortifying Brew
    { key = 122783, class = "MONK", cat = "personal", who = "self", cd = 90,  talent = true }, -- Diffuse Magic
    { key = 122278, class = "MONK", cat = "personal", who = "self", cd = 120, talent = true }, -- Dampen Harm
    { key = 115176, class = "MONK", cat = "personal", who = "self", cd = 300, talent = true,
      specs = {268}, mods = { {387035, "pct", -25} } },                          -- Zen Meditation
    { key = 322507, class = "MONK", cat = "personal", who = "self", cd = 90, charges = 1, talent = true,
      specs = {268}, mods = { {325093, "pct", -20}, {450892, "chg", 1} } },      -- Celestial Brew
    { key = 116849, class = "MONK", cat = "external", who = "any", cd = 120, charges = 1, talent = true,
      specs = {270}, mods = { {202424, "flat", -45} } },                         -- Life Cocoon
    { key = 116841, class = "MONK", cat = "external", who = "any", cd = 30, talent = true }, -- Tiger's Lust

    -- PALADIN
    { key = 642,    class = "PALADIN", cat = "personal", who = "self", cd = 300,
      mods = { {114154, "pct", -30}, {378425, "pct", -15} } },                   -- Divine Shield
    { key = 498,    class = "PALADIN", cat = "personal", who = "self", cd = 60,
      specs = {65, 70}, mods = { {114154, "pct", -30} },
      specMods = { [70] = { {"flat", 30} } } },                                  -- Divine Protection
    { key = 31850,  class = "PALADIN", cat = "personal", who = "self", cd = 90, talent = true,
      specs = {66}, mods = { {114154, "pct", -30} } },                           -- Ardent Defender
    { key = 86659,  class = "PALADIN", cat = "personal", who = "self", cd = 180, charges = 1, talent = true,
      specs = {66}, mods = { {1246481, "chg", 1} } },                            -- Guardian of Ancient Kings
    { key = 1022,   class = "PALADIN", cat = "external", who = "any", cd = 300, charges = 1, talent = true,
      mods = { {378425, "pct", -15}, {384909, "flat", -60} } },                  -- Blessing of Protection
    { key = 204018, class = "PALADIN", cat = "external", who = "any", cd = 300, charges = 1, talent = true,
      specs = {66}, mods = { {378425, "pct", -15}, {384909, "flat", -60} } },    -- Blessing of Spellwarding
    { key = 6940,   class = "PALADIN", cat = "external", who = "any", cd = 120, talent = true,
      mods = { {384820, "flat", -60} } },                                        -- Blessing of Sacrifice

    -- PRIEST
    { key = 47585,  class = "PRIEST", cat = "personal", who = "self", cd = 120,
      specs = {258}, mods = { {288733, "flat", -30} } },                         -- Dispersion
    { key = 19236,  class = "PRIEST", cat = "personal", who = "self", cd = 90, talent = true,
      mods = { {238100, "flat", -20} } },                                        -- Desperate Prayer
    { key = 33206,  class = "PRIEST", cat = "external", who = "any", cd = 180, charges = 1, talent = true,
      specs = {256}, mods = { {373035, "chg", 1} } },                            -- Pain Suppression
    { key = 47788,  class = "PRIEST", cat = "external", who = "any", cd = 180, talent = true,
      specs = {257} },                                                           -- Guardian Spirit
    { key = 62618,  class = "PRIEST", cat = "group", who = "any", cd = 180, talent = true,
      buffs = {81782}, specs = {256} },                                          -- Power Word: Barrier

    -- ROGUE
    { key = 31224,  class = "ROGUE", cat = "personal", who = "self", cd = 120, talent = true }, -- Cloak of Shadows
    { key = 5277,   class = "ROGUE", cat = "personal", who = "self", cd = 120, talent = true }, -- Evasion

    -- SHAMAN
    { key = 108271, class = "SHAMAN", cat = "personal", who = "self", cd = 120, talent = true,
      mods = { {381647, "flat", -30} } },                                        -- Astral Shift

    -- WARLOCK
    { key = 104773, class = "WARLOCK", cat = "personal", who = "self", cd = 180,
      mods = { {386659, "flat", -45} } },                                        -- Unending Resolve
    { key = 108416, class = "WARLOCK", cat = "personal", who = "self", cd = 60, talent = true }, -- Dark Pact

    -- WARRIOR
    { key = 871,    class = "WARRIOR", cat = "personal", who = "self", cd = 180, charges = 1, talent = true,
      specs = {73}, mods = { {391271, "pct", -10}, {397103, "flat", -60}, {397103, "chg", 1} } }, -- Shield Wall
    { key = 12975,  class = "WARRIOR", cat = "personal", who = "self", cd = 180, talent = true,
      specs = {73} },                                                            -- Last Stand
    { key = 118038, class = "WARRIOR", cat = "personal", who = "self", cd = 120, talent = true,
      specs = {71}, mods = { {383338, "flat", -30}, {391271, "pct", -10} } },    -- Die by the Sword
    { key = 184364, class = "WARRIOR", cat = "personal", who = "self", cd = 120, talent = true,
      specs = {72}, mods = { {391271, "pct", -10} } },                           -- Enraged Regeneration
    { key = 97462,  class = "WARRIOR", cat = "group", who = "self", cd = 180, talent = true,
      buffs = {97463} },                                                         -- Rallying Cry
}

-- Fill in the derived fields once: buff set for the sensor filter, spec set,
-- and the longest cooldown any talent can produce (the timer's step size is
-- fixed from it, so a talent change never re-scales a running timer).
for _, def in ipairs(SPELLS) do
    def.buffs = def.buffs or { def.key }
    def.buffSet = {}
    for _, id in ipairs(def.buffs) do def.buffSet[id] = true end
    if def.specs then
        def.specSet = {}
        for _, s in ipairs(def.specs) do def.specSet[s] = true end
    end
    local longest = def.cd
    for _, m in ipairs(def.mods or {}) do
        if m[2] == "flat" and m[3] > 0 then longest = longest + m[3] end
    end
    local specUp = 0
    for _, list in pairs(def.specMods or {}) do
        for _, m in ipairs(list) do
            if m[1] == "flat" and m[2] > specUp then specUp = m[2] end
        end
    end
    longest = longest + specUp
    def.maxCd = longest
end

SquizzFrames.PartyCooldownsData = {
    spells = SPELLS,
    BUILD = "12.1.5.70575",
}
