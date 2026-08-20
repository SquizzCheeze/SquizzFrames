--[[ SquizzFrames Utils.lua - Helper Functions ]]

-- WoW 12.x API compat
local GetAddOnMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
local ClassColorMap = {}
for classFile, color in pairs(RAID_CLASS_COLORS) do
    ClassColorMap[classFile] = {color.r, color.g, color.b}
end

-- SquizzFrames namespace
local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then
    SquizzFrames = {}
    _G["SquizzFrames"] = SquizzFrames
end

local F = SquizzFrames.funcs or {}
SquizzFrames.funcs = F
SquizzFrames.F = F

-- 12.1+ build detection. Shared across modules (ClickCasting's menu-proxy
-- transport, AuraEngine's container API) that need to branch on whether
-- they're running on a pre-12.1 or 12.1+ client.
SquizzFrames.IS_121 = (select(4, GetBuildInfo()) or 0) >= 120100

-----------------------------------------------------------------------
-- Specialization API compat
-----------------------------------------------------------------------
-- The bare GetSpecialization/GetSpecializationInfo/GetNumSpecializations/
-- GetSpecializationInfoByID globals are GONE on 12.1 -- moved into
-- C_SpecializationInfo (and, for the by-specID lookups, into new plain
-- globals with different names). Confirmed against Blizzard's own API
-- documentation, and by Blizzard_Deprecated's 12.1 files NOT re-aliasing
-- them the way they do for e.g. GetInspectSpecialization.
--
-- This broke profile auto-switching silently rather than loudly (user report
-- 2026-08-13, "profiles are not auto swapping when specs change"): every
-- call site was already existence-guarded, so a nil global degraded to
-- "specID 0" instead of erroring, and Core.lua's HandleSpecProfileSwitch
-- early-returns on specID 0. No error, no switch, no clue.
--
-- Resolved once here rather than re-guarded at each call site, so there's a
-- single place to look when Blizzard moves them again. The `or` fallbacks
-- keep pre-12.1 clients working, matching how the rest of the addon handles
-- version splits.
local C_SI = C_SpecializationInfo
local GetSpecialization_ = (C_SI and C_SI.GetSpecialization) or GetSpecialization
local GetSpecializationInfo_ = (C_SI and C_SI.GetSpecializationInfo) or GetSpecializationInfo

-- The player's globally-unique spec ID (e.g. 257 = Holy Priest), or 0.
--
-- GetSpecialization alone returns only the LOCAL spec slot (1-4), which is
-- meaningless as a lookup key across classes -- Priest slot 1 and Druid slot
-- 1 would collide. GetSpecializationInfo resolves that slot to the real ID,
-- which is what db.autoSwitch.map and the click-cast spell lists key on.
function F.GetPlayerSpecID()
    if not (GetSpecialization_ and GetSpecializationInfo_) then return 0 end
    local slot = GetSpecialization_()
    if not slot then return 0 end
    return GetSpecializationInfo_(slot) or 0
end

-- Display name for a spec ID. GetSpecializationInfoByID's replacement is a
-- plain global with a new name (GetSpecializationNameForSpecID, declared in
-- the SpecializationShared system, which has no Namespace -- so it is NOT
-- under C_SpecializationInfo). Returns nil if unavailable; callers already
-- treat the name as optional.
function F.GetSpecName(specID)
    if not specID or specID == 0 then return nil end
    if GetSpecializationNameForSpecID then
        return GetSpecializationNameForSpecID(specID)
    end
    if GetSpecializationInfoForSpecID then
        return select(2, GetSpecializationInfoForSpecID(specID))
    end
    if GetSpecializationInfoByID then -- pre-12.1
        return select(2, GetSpecializationInfoByID(specID))
    end
    return nil
end

-- Every spec of the player's own class, as { {id=, name=}, ... }.
--
-- GetNumSpecializations has no drop-in replacement -- the nearest is
-- C_SpecializationInfo.GetNumSpecializationsForClassID, which needs a class
-- ID, and UnitClass is declared SecretWhenUnitIdentityRestricted. Walking
-- the slots until one comes back empty avoids needing the class ID at all.
-- MAX is 4 (Druid); the loop stops early for everyone else, and a future
-- 5-spec class would only need this constant raised.
function F.GetPlayerSpecList()
    local list = {}
    if not GetSpecializationInfo_ then return list end
    for slot = 1, 4 do
        local id, name = GetSpecializationInfo_(slot)
        if not id or id == 0 then break end
        list[#list + 1] = { id = id, name = name or ("Spec " .. slot) }
    end
    return list
end

-- Role texture packs (atlas-based or separate files) - shared globally
local ROLE_TEXTURE_PACKS = {
    ["blizzard"] = {
        label = "Blizzard",
        atlas = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Blizzard_ROLES.tga",
        preview = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Preview_Blizzard.tga",
        coords = {
            TANK    = {0, 0.296875, 0.328125, 0.625},
            HEALER  = {0.3125, 0.609375, 0.015625, 0.3125},
            DAMAGER = {0.3125, 0.609375, 0.328125, 0.625},
        },
    },
    ["blizzard2"] = {
        label = "Blizzard 2",
        atlas = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Blizzard2_ROLES.tga",
        preview = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Preview_Blizzard2.tga",
        coords = {
            TANK    = {0, 0.296875, 0.328125, 0.625},
            HEALER  = {0.3125, 0.609375, 0.015625, 0.3125},
            DAMAGER = {0.3125, 0.609375, 0.328125, 0.625},
        },
    },
    ["blizzard3"] = {
        label = "Blizzard 3 (Separate)",
        files = {
            TANK    = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Blizzard3_TANK.tga",
            HEALER  = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Blizzard3_HEALER.tga",
            DAMAGER = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Blizzard3_DAMAGER.tga",
        },
        preview = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Preview_Blizzard3.tga",
    },
    ["blizzard4"] = {
        label = "Blizzard 4 (Separate)",
        files = {
            TANK    = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Blizzard4_TANK.tga",
            HEALER  = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Blizzard4_HEALER.tga",
            DAMAGER = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Blizzard4_DAMAGER.tga",
        },
        preview = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Preview_Blizzard4.tga",
    },
    -- "default" used to be a Default_ROLES.tga atlas pack, but that file was
    -- never actually shipped in Media/Roles (confirmed -- only
    -- Default_TANK/HEALER/DAMAGER.tga and Default2_ROLES.tga exist), so it
    -- silently rendered broken/blank icons. Removed and replaced by what was
    -- "default_separate" (the files-based pack, which DOES have real files)
    -- renamed to the "default" key -- this also self-heals any saved
    -- profile that had roleTexture="default" (now resolves to the working
    -- pack) or roleTexture="default_separate" (falls through to the
    -- GetRoleTexture*/CreateSetting_RoleTexture "default" fallback, which is
    -- this same pack under its new key) -- no migration code needed.
    ["default"] = {
        label = "Default",
        files = {
            TANK    = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Default_TANK.tga",
            HEALER  = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Default_HEALER.tga",
            DAMAGER = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Default_DAMAGER.tga",
        },
        preview = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Preview_Default.tga",
    },
    ["default2"] = {
        label = "Default 2",
        atlas = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Default2_ROLES.tga",
        preview = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Preview_Default2.tga",
        coords = {
            TANK    = {0, 0.296875, 0.328125, 0.625},
            HEALER  = {0.3125, 0.609375, 0.015625, 0.3125},
            DAMAGER = {0.3125, 0.609375, 0.328125, 0.625},
        },
    },
    ["ffxiv"] = {
        label = "FFXIV",
        files = {
            TANK    = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\FFXIV_TANK.tga",
            HEALER  = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\FFXIV_HEALER.tga",
            DAMAGER = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\FFXIV_DAMAGER.tga",
        },
        preview = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Preview_FFXIV.tga",
    },
    ["mattui"] = {
        label = "MattUI",
        atlas = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\MattUI_ROLES.tga",
        preview = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Preview_MattUI.tga",
        coords = {
            TANK    = {0, 0.296875, 0.328125, 0.625},
            HEALER  = {0.3125, 0.609375, 0.015625, 0.3125},
            DAMAGER = {0.3125, 0.609375, 0.328125, 0.625},
        },
    },
    ["miirgui"] = {
        label = "MiirGui",
        files = {
            TANK    = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\MiirGui_TANK.tga",
            HEALER  = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\MiirGui_HEALER.tga",
            DAMAGER = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\MiirGui_DAMAGER.tga",
        },
        preview = "Interface\\AddOns\\SquizzFrames\\Media\\Roles\\Preview_MiirGui.tga",
    },
}

-- Expose globally so IndicatorWidgets.lua can also access it
SquizzFrames.ROLE_TEXTURE_PACKS = ROLE_TEXTURE_PACKS
_G.ROLE_TEXTURE_PACKS = ROLE_TEXTURE_PACKS

local L = SquizzFrames.L or setmetatable({}, {__index = function(_, k) return k end})

-- Color helpers
function F.ColorRGB(colorTable, alpha)
    if not colorTable then return 1, 1, 1, alpha or 1 end
    local ctype = colorTable[1]
    if ctype == "class_color" then
        local class = colorTable[2]
        local c = ClassColorMap[class] or {1, 1, 1}
        return c[1], c[2], c[3], alpha or 1
    elseif ctype == "custom_color" then
        return colorTable[2], colorTable[3], colorTable[4], alpha or colorTable[5] or 1
    end
    return 1, 1, 1, alpha or 1
end

-----------------------------------------------------------------------
-- Font dropdown items
-----------------------------------------------------------------------
-- Every font picker in the addon builds its list from here, so they all offer
-- the same set -- LibSharedMedia's full font registry, which means fonts
-- registered by other addons show up too.
--
-- LEGACY ENTRIES are appended deliberately. Font faces are stored in profiles
-- as the dropdown's own value string, and these three were the ONLY choices
-- the indicator pickers offered before 2026-08-14. Two are raw content paths
-- rather than LSM keys, and "Friz QT__" is a name LibSharedMedia has never
-- known -- it happens to render correctly only because F.ResolveFontFile falls
-- back to Friz Quadrata for anything it can't resolve. It is also the shipped
-- default in Layout_Defaults, so it's in essentially every profile.
--
-- Dropping them would leave those profiles selecting a value not present in
-- the list, which the dropdown renders as blank text -- looking exactly like
-- the setting had been lost. Keeping them costs three rows at the bottom.
local FONT_LEGACY_ITEMS = {
    { text = "Friz QT__ (legacy)",       value = "Friz QT__" },
    { text = "FRIZQT__.TTF (legacy)",    value = [[Fonts\FRIZQT__.TTF]] },
    { text = "ARIALN.TTF (legacy)",      value = [[Fonts\ARIALN.TTF]] },
}

function F.GetFontDropdownItems()
    local items, seen = {}, {}
    local LSM = LibStub and LibStub:GetLibrary("LibSharedMedia-3.0", true)
    if LSM then
        for name in pairs(LSM:HashTable("font")) do
            if not seen[name] then
                seen[name] = true
                items[#items + 1] = { text = name, value = name }
            end
        end
        table.sort(items, function(a, b) return a.text < b.text end)
    end
    for _, entry in ipairs(FONT_LEGACY_ITEMS) do
        if not seen[entry.value] then
            seen[entry.value] = true
            items[#items + 1] = { text = entry.text, value = entry.value }
        end
    end
    return items
end

function F.ColorRGBTable(colorTable, alpha)
    local r, g, b, a = F.ColorRGB(colorTable, alpha)
    return {r, g, b, a}
end

function F.ColorHex(colorTable, alpha)
    local r, g, b = F.ColorRGB(colorTable, alpha or 1)
    return string.format("|c%02x%02x%02x%02x", (a or 1) * 255, r * 255, g * 255, b * 255)
end

-- Number formatting
function F.ShortNumber(n)
    if not n then return "0" end
    if n >= 1e9 then
        return string.format("%.1fB", n / 1e9)
    elseif n >= 1e6 then
        return string.format("%.1fM", n / 1e6)
    elseif n >= 1e3 then
        return string.format("%.1fK", n / 1e3)
    end
    return tostring(n)
end

function F.FormatNumber(n)
    if not n then return "0" end
    local formatted = tostring(n)
    while true do
        formatted, k = gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
        if k == 0 then break end
    end
    return formatted
end

-- Unit helpers
function F.UnitFullName(unit, hideRealm)
    if not unit then return "" end
    local name, realm = UnitName(unit)
    if not name then return "" end
    -- Name itself secret (12.1 identity restrictions): no string operation on
    -- it is legal, so hideRealm could never be honored here -- the value was
    -- returned verbatim, realm suffix and all, and the "Hide Realm Name"
    -- setting silently stopped working for the whole fight.
    --
    -- Ambiguate is the exception: it accepts a secret and returns one, doing
    -- the split C-side where the secrecy rules don't apply, and its result
    -- stays SetText-safe. (Confirmed in use on 12.1 by DPSReport.lua:625-629,
    -- which relies on exactly this for combat-log names.) Never compare or
    -- concatenate what comes back -- pass it straight through.
    if not F.IsValueNonSecret(name) then
        return Ambiguate(name, hideRealm and "short" or "none")
    end
    -- UnitName can return a secret realm string for non-player units in
    -- combat (Patch 12.0.0+ secret-value system -- confirmed via
    -- warcraft.wiki.gg/wiki/Secret_Values). `realm ~= ""` is a comparison
    -- against a literal, which throws on a secret value the same way
    -- `count > 1`/`dispelName == "Magic"` did elsewhere in this codebase --
    -- F.IsValueNonSecret must gate it. When realm comes back secret, fall
    -- back to just the bare name rather than risk the crash.
    if not hideRealm and realm and F.IsValueNonSecret(realm) and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

function F.GetClassFile(unit)
    if not unit then return nil end
    local _, classFile = UnitClass(unit)
    return classFile
end

function F.GetClassColor(unit)
    local classFile = F.GetClassFile(unit or "player")
    -- UnitClass's classFile return went secret-when-identity-restricted in
    -- Patch 12.1.0 (confirmed via warcraft.wiki.gg/wiki/Patch_12.1.0/API_changes)
    -- -- not an issue on 12.0.7, but indexing RAID_CLASS_COLORS with a secret
    -- key on 12.1 would hard-error the same way wantSet[info.spellId] did
    -- elsewhere in this codebase. F.IsValueNonSecret must gate it.
    local c = (RAID_CLASS_COLORS and F.IsValueNonSecret(classFile) and RAID_CLASS_COLORS[classFile])
        or {r = 1, g = 1, b = 1, colorStr = "ffffffff"}
    return {r = c.r, g = c.g, b = c.b, colorStr = c.colorStr or "ffffffff"}
end

-- Blizzard's stock color for a unit's CURRENT power type (mana blue, rage
-- red, etc). Returns a {r,g,b} table, never nil.
--
-- Exists so the PowerBarColor table index is gated in exactly one place
-- (2026-08-07): UnitPowerType joins the secret-when-identity-restricted set
-- in 12.1, and indexing a table with a secret key hard-errors -- the same
-- class of bug F.GetClassColor above already guards against, and which
-- previously appeared unguarded at five separate call sites
-- (PartyFrames/PetFrames/BuiltIn_Update).
function F.GetPowerColor(unit)
    local fallback = {r = 1, g = 1, b = 1}
    if not unit or not PowerBarColor then return fallback end
    local powerType = UnitPowerType(unit)
    if not F.IsValueNonSecret(powerType) then return fallback end
    local c = PowerBarColor[powerType]
    if not c or c.r == nil then return fallback end
    return {r = c.r, g = c.g, b = c.b}
end

-- Look up a spell name from a spell ID. Returns nil if unknown.
-- C_Spell.GetSpellName is the modern (retail) API.
function F.GetSpellInfo(spellId)
    if not spellId then return nil end
    if C_Spell and C_Spell.GetSpellName then
        return C_Spell.GetSpellName(spellId)
    end
    return nil
end

-- Get the spell icon texture string for a spell ID. Returns nil if unknown.
-- Uses C_Spell.GetSpellInfo (retail) which returns an iconID.
function F.GetSpellIcon(spellId)
    if not spellId then return nil end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellId)
        if info and info.iconID then
            return info.iconID
        end
    end
    -- Fallback: the generic "spell_frost_frost02" question-mark icon.
    return [[Interface\Icons\INV_Misc_QuestionMark]]
end

-- Hardcoded click-cast spell list, adapted from Cell's
-- Defaults/ClickCasting_DefaultSpells.lua (defaultSpells table). We don't
-- scan the spellbook — this curated list is the same one Cell shows, keyed
-- by class + spec. Each entry is either a spell ID (number) or a string
-- "ID|SINGLECHAR" where the char is a class/spec flag we ignore here.

local CLICK_CAST_SPELLS = {
    ["DEATHKNIGHT"] = { common = { 61999, 47541 } },
    ["DEMONHUNTER"] = { common = {} },
    ["DRUID"] = {
        common = { 1126, 20484, 50769, 8936, "774C", "102401C", "29166C", "48438C", "474750C" },
        [102] = { "2782C", "305497P" },
        [103] = { "2782C", "391888S", "305497P" },
        [104] = { "2782C" },
        [105] = { 212040, 88423, "33763S", "102342S", "18562S", "102693H", "305497P", "474149P", "473991P" },
    },
    ["EVOKER"] = {
        common = { 364342, 361227, 361469, 355913, "360995C", "374251C", "369459C", "370665C", "406732C", "378441P" },
        [1467] = { "365585C" },
        [1468] = { 361178, 360823, "364343S", "366155S", "357170S" },
        [1473] = { "365585C", "360827S", "409311S", "408233S", "412710S" },
    },
    ["HUNTER"] = {
        common = { "34477C", 53271, "248518P", "53480P" },
        [253] = { 90361 },
        [255] = { "212640P" },
    },
    ["MAGE"] = { common = { 1459, 130, "475C" } },
    ["MONK"] = {
        common = { 115178, 116670, "115175C", "115098C", "116841C" },
        [268] = { "218164C" },
        [269] = { "218164C" },
        [270] = { 212051, 115450, "124682S", "115151S", "116849S", "124081S", "399491S" },
    },
    ["PALADIN"] = {
        common = { 7328, 391054, 19750, 85673, 304971, "633C", "1044C", "6940C", "1022C" },
        [65] = { 212056, 4987, 53563, "20473S", "82326S", "223306S", "114165S", "183998S", "156910S", "200025S", "432459H", "156322H", "148039P" },
        [66] = { "213644C", "204018S", "228049P", "432459H" },
        [70] = { "213644C", "210256P", "156322H" },
    },
    ["PRIEST"] = {
        common = { 21562, 2006, 1706, 17, 2061, 2096, "73325C", "10060C" },
        [256] = { 212036, 527, 47540, 472433, "200829S", "194509S", "33206S", "47536S", "62618S" }, -- 472433: Evangelism (reworked 2026)
        [257] = { 212036, 527, 2060, "33076S", "2050S", "34861S", "596S", "47788S", "204883S", "64843S", "200183S", "289666P", "213610P", "197268P" },
        [258] = { "213634C" },
    },
    ["ROGUE"] = { common = { "57934C", "36554C" } },
    ["SHAMAN"] = {
        common = { 462854, 2008, 546, "1064C", "974C", "51490C" },
        [262] = { "51886C" },
        [263] = { "51886C" },
        [264] = { 212048, 77130, "61295S", "77472S", "73685S" },
    },
    ["WARLOCK"] = { common = { 20707, 89808, 5697 } },
    ["WARRIOR"] = { common = { "3411C" }, [73] = { "213871P" } },
}

local function Copy(t)
    local c = {}
    for _, v in ipairs(t) do c[#c + 1] = v end
    return c
end

-- Build the click-cast spell dropdown list for the current player.
-- Returns { {id, name}, ... } sorted alphabetically.
function F.GetClickCastingSpellsList()
    local class = select(2, UnitClass("player"))  -- e.g. "DRUID"
    -- Was existence-guarded against the deprecated globals, which by 12.1 had
    -- actually been REMOVED -- so this silently degraded to specID 0 and
    -- quietly dropped every spec-specific spell from the click-cast list.
    -- F.GetPlayerSpecID resolves the C_SpecializationInfo replacements; 0 is
    -- still tolerated below (class-common spells only).
    local specID = F.GetPlayerSpecID()

    local byClass = CLICK_CAST_SPELLS[class]
    if not byClass then return {} end

    local raw = byClass.common and Copy(byClass.common) or {}
    if specID ~= 0 and byClass[specID] then
        for _, v in ipairs(byClass[specID]) do raw[#raw + 1] = v end
    end

    local spells = {}
    for _, v in ipairs(raw) do
        local id = type(v) == "number" and v or tonumber((tostring(v):match("^(%d+)")))
        if id then
            local name = F.GetSpellInfo(id)
            if name and name ~= "" then
                spells[#spells + 1] = {id = id, name = name}
            end
        end
    end

    table.sort(spells, function(a, b) return a.name < b.name end)
    return spells
end

-- Get the click-cast item list the way Cell does: equipped items in slots
-- 1-17 that are usable. Returns { {id, name}, ... }.
function F.GetClickCastingItemsFromCell()
    local items = {}
    local seen = {}
    for slot = 1, 17 do
        local itemId = GetInventoryItemID("player", slot)
        if itemId and C_Item.IsUsableItem(itemId) and not seen[itemId] then
            seen[itemId] = true
            local link = GetInventoryItemLink("player", slot)
            local name = link and link:gsub("[%[%]]", "") or ""
            tinsert(items, {id = itemId, name = name})
        end
    end
    table.sort(items, function(a, b) return a.name < b.name end)
    return items
end

function F.GetAccentColor()
    local prof = SquizzFrames.db and SquizzFrames.db.profile
    if prof and prof.appearance and prof.appearance.general and prof.appearance.general.accentColor then
        local ac = prof.appearance.general.accentColor
        if ac[1] == "class_color" then
            return F.GetClassColor("player")
        elseif ac[1] == "custom_color" then
            return {r = ac[2] or 0, g = ac[3] or 0.48, b = ac[4] or 0.65, colorStr = string.format("ff%02x%02x%02x", (ac[2] or 0) * 255, (ac[3] or 0.48) * 255, (ac[4] or 0.65) * 255)}
        end
    end
    return F.GetClassColor("player")
end

function F.ColorRGBToHex(r, g, b, a)
    a = a or 1
    return string.format("|c%02x%02x%02x%02x", a * 255, r * 255, g * 255, b * 255)
end

-- Debuff-type color table (Cell uses the same RGB values). Indexed by the
-- debuff type string returned from C_UnitAuras (e.g. "Magic", "Curse"). Returns
-- an {r,g,b} table; unknown/missing types default to the grey "none" color.
local DEBUFF_TYPE_COLORS = {
    ["Magic"]   = {0.20, 0.60, 1.00},
    ["Curse"]   = {0.60, 0.00, 1.00},
    ["Disease"] = {0.60, 0.40, 0.00},
    ["Poison"]  = {0.00, 0.60, 0.00},
    [""]        = {0.80, 0.00, 0.00},  -- none/other → red border (Cell's default)
}
function F.GetDebuffTypeColor(debuffType)
    return DEBUFF_TYPE_COLORS[debuffType] or DEBUFF_TYPE_COLORS[""]
end

-- Shared 1px (or `size`) icon/region border: 4 edge textures, children of
-- `host`, offset outward from its own bounds so they never overlap host's
-- own content (icon, cooldown swipe, etc). Cached on host._sfBorder so
-- repeated calls (e.g. a live color/size change) reuse the same textures
-- instead of leaking new ones. This is the exact signature AuraEngine.lua's
-- ApplyStyleToRegions already calls (F.CreateBorder(d.borderHost, r,g,b,a,
-- size)) -- it was referenced there defensively (`if b and F.CreateBorder`)
-- before this existed, so every AuraEngine group-based indicator's border
-- support activates automatically now that it's implemented.
function F.CreateBorder(host, r, g, b, a, size)
    size = size or 1
    local border = host._sfBorder
    if not border then
        border = {
            top = host:CreateTexture(nil, "OVERLAY"),
            bottom = host:CreateTexture(nil, "OVERLAY"),
            left = host:CreateTexture(nil, "OVERLAY"),
            right = host:CreateTexture(nil, "OVERLAY"),
        }
        host._sfBorder = border
    end
    for _, tex in pairs(border) do
        tex:SetColorTexture(r or 0, g or 0, b or 0, a or 1)
    end
    border.top:ClearAllPoints()
    border.top:SetPoint("TOPLEFT", host, "TOPLEFT", -size, size)
    border.top:SetPoint("TOPRIGHT", host, "TOPRIGHT", size, size)
    border.top:SetHeight(size)
    border.bottom:ClearAllPoints()
    border.bottom:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", -size, -size)
    border.bottom:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", size, -size)
    border.bottom:SetHeight(size)
    border.left:ClearAllPoints()
    border.left:SetPoint("TOPLEFT", host, "TOPLEFT", -size, size)
    border.left:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", -size, -size)
    border.left:SetWidth(size)
    border.right:ClearAllPoints()
    border.right:SetPoint("TOPRIGHT", host, "TOPRIGHT", size, size)
    border.right:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", size, -size)
    border.right:SetWidth(size)
    return border
end

-- Toggle a border created by F.CreateBorder without changing its color/size.
function F.SetBorderShown(host, show)
    local border = host._sfBorder
    if not border then return end
    for _, tex in pairs(border) do tex:SetShown(show) end
end

-- Normalize a custom indicator's `auras` list (array of spell IDs and/or spell
-- names) into a spell-ID-keyed lookup for fast UNIT_AURA scanning. Numeric IDs
-- and "12345"-shaped strings become number keys; anything else becomes a
-- lowercase name key for the trackByName match path. Returns a table keyed by
-- spellID (number) or spellName (string) → true.
function F.ConvertSpellTable(auras)
    local lookup = {}
    if not auras then return lookup end
    for _, v in ipairs(auras) do
        if type(v) == "number" then
            lookup[v] = true
        elseif type(v) == "string" then
            local id = tonumber(v:match("^(%d+)$"))
            if id then
                lookup[id] = true
            else
                lookup[v:lower()] = true
            end
        end
    end
    return lookup
end

-- Flatten a class-keyed curated spell table (Defaults/Indicator_Defaults.lua's
-- externalCooldowns/defensiveCooldowns/aoeHealings/crowdControls shape --
-- {GROUP = {[spellID] = true/false, ...}, ...}) into a plain array of every
-- top-level numeric spell ID. Shared by BuiltIn_Update.lua's legacy scan and
-- AuraEngineIndicators.lua's AuraContainer-backed version so both cover the
-- exact same spell set.
function F.FlattenSpellTable(classTable)
    local flat = {}
    for _, spells in pairs(classTable) do
        for id, _ in pairs(spells) do
            if type(id) == "number" then
                flat[#flat + 1] = id
            end
        end
    end
    return flat
end

-- Merge a curated built-in spell-ID list with a user's custom additions for
-- indicators like externalCooldowns/defensiveCooldowns. `useBuiltIn == false`
-- drops the curated list entirely; `customList` is the raw indicator-config
-- array (spell IDs, per CreateSetting_Auras) appended on top. `hiddenList` is
-- a flat spell-ID array the user has chosen to hide from the curated list
-- (per-spell "hide" toggle in the Built-in Spells checklist -- see
-- IndicatorWidgets.lua's CreateSetting_BuiltInsForKind -- never removes
-- anything from the curated table itself, just filters it out of what gets
-- scanned). Returns a flat array of spell IDs.
function F.GetEffectiveSpellList(useBuiltIn, baseList, customList, hiddenList)
    if useBuiltIn == false then baseList = nil end
    local hiddenSet
    if hiddenList and hiddenList[1] then
        hiddenSet = {}
        for _, id in ipairs(hiddenList) do hiddenSet[id] = true end
    end
    if not customList or not customList[1] then
        if not hiddenSet or not baseList then return baseList or {} end
        local list = {}
        for _, id in ipairs(baseList) do
            if not hiddenSet[id] then list[#list + 1] = id end
        end
        return list
    end
    local list = {}
    if baseList then
        for _, id in ipairs(baseList) do
            if not hiddenSet or not hiddenSet[id] then list[#list + 1] = id end
        end
    end
    for _, v in ipairs(customList) do
        local id = tonumber(v)
        if id then list[#list + 1] = id end
    end
    return list
end

-- True when a value is present AND definitely readable (not secret/tainted).
-- Uses issecretvalue(), the native API already proven correct elsewhere in
-- this codebase (PartyFrames.lua's `not issecretvalue(UnitIsAFK(unit))`,
-- BuiltIn_Update.lua's raid-marker-index gating). The previous version of
-- this function did `val ~= ""`, which doesn't check secrecy at all -- for a
-- value that genuinely IS secret, that comparison itself throws (WoW's
-- secret-value system intercepts comparisons against mismatched types too,
-- same as the `true < 999` auraOrder bug found earlier this session) --
-- uncaught, since every call site is deep inside CD.Scan's loop body, not
-- wrapped in the pcall that only covers the GetAuraDataByIndex call itself.
-- That silently aborted the whole scan mid-pass before it ever reached
-- CD.ShowCustomIndicators, which is why custom indicators kept failing in
-- combat even after the break-vs-continue loop fix (that fix was correct,
-- it just couldn't matter while this gate was throwing before ever getting
-- there).
function F.IsValueNonSecret(val)
    if val == nil then return false end
    if issecretvalue and issecretvalue(val) then return false end
    if type(val) == "table" then
        for _ in pairs(val) do return true end
        return false
    end
    return true
end

-----------------------------------------------------------------------
-- Frame-level tiers (layering scheme)
-----------------------------------------------------------------------
-- One documented place defining how everything on a unit button stacks,
-- adopted 2026-08-07 from EllesmereUIRaidFrames' approach (its own scheme
-- lives in a single commented constants block; DandersFrames by contrast
-- layers ad hoc, and its own design notes blame that for re-applying
-- strata/level on every UNIT_AURA, which resets mouse propagation and
-- breaks click-casting in combat).
--
-- Two rules make this work:
--   1. Levels are always applied RELATIVE to the owning frame
--      (owner:GetFrameLevel() + tier), never as absolutes. Indicators.lua's
--      generic dispatch already does exactly this.
--   2. STRATA is reserved for top-level containers only. Everything inside
--      a unit button orders itself purely by frame level, so nothing has to
--      fight the container's strata or Blizzard's own frames.
--
-- IMPORTANT COMPATIBILITY CONSTRAINT: every value below is the number that
-- was already shipping as that indicator's default `frameLevel`, and those
-- values live in users' saved profiles. These constants NAME the existing
-- scheme; they must not renumber it, or every existing profile would
-- silently re-layer on update.
F.LAYER = {
    AGGRO_BORDER  = 3,   -- static aggro border, sits under other borders
    FRAME_BORDER  = 4,   -- decorative always-on button border
    ICON          = 5,   -- role/raid icons, shield bar, debuff grid
    BAR_OVERLAY   = 6,   -- shield + heal-absorb overlays ON the health bar
    AGGRO_BLINK   = 7,   -- pulsing aggro border (above the static one)
    TARGET        = 8,   -- target highlight border
    HOVER         = 9,   -- hover highlight border (above target, by design)
    AURA          = 10,  -- cooldown/HoT/missing-buff aura icon grids
    DISPEL        = 15,  -- dispel overlay/icon, above the aura grids
    TEXT          = 20,  -- name/health/power text, CC indicator
    STATUS_TEXT   = 30,  -- AFK/Dead/Offline status text
    STATUS_ICON   = 35,  -- status + ready-check icons, topmost
}

-- User-facing tier presets for the Frame Level control. Ordered low to
-- high; the options dropdown shows these names instead of a bare number
-- (EllesmereUI does the same -- a named tier is far more meaningful to a
-- user than "17"). Any stored value that doesn't match a preset is still
-- valid and displays as "Custom (N)", so hand-tuned profiles are preserved.
F.LAYER_PRESETS = {
    { value = F.LAYER.ICON,        text = "Behind Borders" },
    { value = F.LAYER.AURA,        text = "Behind Text" },
    { value = F.LAYER.DISPEL,      text = "Medium" },
    { value = F.LAYER.TEXT,        text = "High" },
    { value = F.LAYER.STATUS_ICON, text = "Highest" },
}

-- Is this unit token the player themselves?
--
-- Not just `unit == "player"`: the secure header can hand a button any token,
-- and vehicle/possess states alias the player onto another one. UnitIsUnit is
-- declared secret when unit comparison is restricted (rated PvP maps), and a
-- boolean test on a secret throws -- so the comparison is gated behind
-- CanCompareUnitTokens and the result re-checked, falling back to "no" rather
-- than risking the error. Lifted out of PartyFrames.lua (range fading) on
-- 2026-08-13 when F.GetRoleKey needed the same test.
--
-- C_Secrets.CanCompareUnitTokens is the sanctioned pre-check and its own
-- return is NOT secret -- the same guard oUF uses (ElvUI_Libraries/.../oUF/
-- init.lua), with oUF's belt-and-braces issecretvalue check kept too, since
-- the pre-check only promises the comparison is permitted.
local CanCompareUnitTokens = C_Secrets and C_Secrets.CanCompareUnitTokens
function F.IsPlayerUnit(unit)
    if unit == "player" then return true end
    if not unit then return false end
    if CanCompareUnitTokens and not CanCompareUnitTokens(unit, "player") then
        return false
    end
    local isPlayer = UnitIsUnit(unit, "player")
    if issecretvalue and issecretvalue(isPlayer) then return false end
    return isPlayer
end

-- The role the player's CURRENT SPEC implies -- "TANK"/"HEALER"/"DAMAGER", or
-- nil if there's no spec yet (low-level characters) or the API is unavailable.
--
-- role is the 5th return of GetSpecializationInfo, confirmed against
-- Blizzard's own SpecializationInfoDocumentation on the 12.1 source rather
-- than assumed -- and reached through the same resolved locals as
-- F.GetPlayerSpecID, so the "these globals moved into C_SpecializationInfo"
-- fix stays in one place.
--
-- Nothing about this is unit-based, so unlike UnitGroupRolesAssigned it is
-- never secret and works identically in and out of combat.
function F.GetPlayerSpecRole()
    if not (GetSpecialization_ and GetSpecializationInfo_) then return nil end
    local slot = GetSpecialization_()
    -- 0 is a real return (no spec chosen yet), and the argument is declared a
    -- luaIndex -- passing 0 is not a valid index.
    if not slot or slot == 0 then return nil end
    local role = select(5, GetSpecializationInfo_(slot))
    if role == "TANK" or role == "HEALER" or role == "DAMAGER" then
        return role
    end
    return nil
end

-- Normalizes a unit's role to exactly "TANK"/"HEALER"/"DAMAGER".
--
-- Single gated choke point (2026-08-07) for UnitGroupRolesAssigned, which
-- joins the secret-when-identity-restricted set in 12.1 -- comparing a
-- secret against a string literal ("TANK") throws, the same failure mode
-- documented for UnitIsAFK elsewhere in this file.
--
-- ASSIGNED role first, then the player's own SPEC role as a fallback.
-- UnitGroupRolesAssigned reports the GROUP's assignment and nothing else, so
-- it answers "NONE" for everyone whenever no assignment exists -- which
-- includes every moment you are solo. Collapsing that to DAMAGER meant a Holy
-- Paladin questing alone wore a DPS icon (user report 2026-08-13). For the
-- player we can do better than Blizzard's own frames do (CompactUnitFrame
-- simply hides the icon on "NONE"): the spec role is authoritative, always
-- readable, and is what the user actually means by "my role".
--
-- Other units keep normalizing to DAMAGER, unchanged: their spec isn't
-- readable without inspection, so there's nothing better to answer with.
function F.GetRoleKey(unit)
    if not unit then return "DAMAGER" end
    local role = UnitGroupRolesAssigned(unit)
    if F.IsValueNonSecret(role) then
        if role == "TANK" then return "TANK" end
        if role == "HEALER" then return "HEALER" end
        if role == "DAMAGER" then return "DAMAGER" end
    end
    -- Assigned role is "NONE", nil, or secret -- i.e. genuinely unknown.
    if F.IsPlayerUnit(unit) then
        local specRole = F.GetPlayerSpecRole()
        if specRole then return specRole end
    end
    return "DAMAGER"
end

function F.GetRoleTexture(unit, roleTexture)
    local roleKey = F.GetRoleKey(unit)

    roleTexture = roleTexture or "default"
    local pack = ROLE_TEXTURE_PACKS and ROLE_TEXTURE_PACKS[roleTexture]

    if not pack then
        pack = ROLE_TEXTURE_PACKS["default"]
    end

    if pack.atlas then
        -- Atlas-based: return texture path + tex coords
        return pack.atlas, unpack(pack.coords[roleKey])
    elseif pack.files then
        -- Separate files: return single texture path
        return pack.files[roleKey]
    end

    -- Fallback
    return [[Interface\AddOns\SquizzFrames\Media\Textures\DPS.tga]]
end

function F.GetRoleTextureByRole(roleTexture, roleKey)
    roleTexture = roleTexture or "default"
    -- roleKey comes straight from the caller (unlike F.GetRoleTexture above,
    -- which derives and normalizes it itself from UnitGroupRolesAssigned).
    -- UnitGroupRolesAssigned can return "NONE" for a unit with no assigned
    -- role -- e.g. the Designer preview's fake unit -- which texture packs
    -- don't define coords/files for, so normalize any non-TANK/HEALER value
    -- to "DAMAGER" here too rather than letting it through to unpack(nil).
    if roleKey ~= "TANK" and roleKey ~= "HEALER" then
        roleKey = "DAMAGER"
    end
    local pack = ROLE_TEXTURE_PACKS and ROLE_TEXTURE_PACKS[roleTexture]

    if not pack then
        pack = ROLE_TEXTURE_PACKS["default"]
    end

    if pack.atlas then
        -- Atlas-based: return texture path + tex coords
        return pack.atlas, unpack(pack.coords[roleKey])
    elseif pack.files then
        -- Separate files: return single texture path
        return pack.files[roleKey]
    end

    -- Fallback
    return [[Interface\AddOns\SquizzFrames\Media\Textures\DPS.tga]]
end

-- Returns a fresh, private AceEvent-embedded table to use as a message
-- registration OWNER (2026-08-07).
--
-- CallbackHandler keys registrations by (owner, message) -- so two
-- registrations for the SAME message on the SAME owner table collide, and
-- the second SILENTLY REPLACES the first. Core.lua documents this for
-- modules ("register on yourself, not the addon root"), but non-module code
-- and per-page options code had no equivalent, and six different call sites
-- had all registered "ProfileChanged" on the shared SquizzFrames root --
-- meaning five of them were dead and most options pages showed stale values
-- after a profile switch (confirmed by grep; fixed by giving each site its
-- own owner via this helper).
--
-- Call ONCE per registration site and keep the result alive (a fresh owner
-- per invocation of a repeatedly-called function would leak registrations).
function F.NewMessageOwner()
    local owner = {}
    LibStub("AceEvent-3.0"):Embed(owner)
    return owner
end

-- Table helpers
function F.CopyTable(orig)
    if type(orig) ~= "table" then return {} end
    local copy = {}
    for k, v in pairs(orig) do
        if type(v) == "table" then
            copy[k] = F.CopyTable(v)
        else
            copy[k] = v
        end
    end
    return copy
end

function F.MergeTable(base, override)
    if not base then base = {} end
    if not override then return base end
    local result = F.CopyTable(base)
    for k, v in pairs(override) do
        if type(v) == "table" and type(result[k]) == "table" then
            result[k] = F.MergeTable(result[k], v)
        else
            result[k] = v
        end
    end
    return result
end

-- Scale
function F.Scale(value)
    local scale = SquizzFrames and SquizzFrames.db and SquizzFrames.db.profile and SquizzFrames.db.profile.appearance and SquizzFrames.db.profile.appearance.scale or 1
    return value * scale * (UIParent:GetEffectiveScale() or 1)
end

function F.GetRecommendedScale()
    local _, screenHeight = GetPhysicalScreenSize()
    return 768 / screenHeight / (UIParent:GetEffectiveScale() or 1)
end

-- Slash handler
function F.SlashHandler(msg)
    if not msg then msg = "" end
    local cmd = msg:match("^%s*(%S+)")
    cmd = cmd or ""
    cmd = cmd:lower()
    if cmd == "" or cmd == "options" then
        if SquizzFrames.ToggleOptions then
            SquizzFrames:ToggleOptions()
        else
            local name = SquizzFrames.options and SquizzFrames.options.name or "SquizzFrames"
            Settings.OpenToCategory(name)
        end
    elseif cmd == "lock" or cmd == "unlock" or cmd == "toggle" then
        if SquizzFrames.locked then
            SquizzFrames.locked = false
            SquizzFrames:Fire("LockChanged", false)
            SquizzFrames.Print(L["Unlock Frames"])
        else
            SquizzFrames.locked = true
            SquizzFrames:Fire("LockChanged", true)
            SquizzFrames.Print(L["Lock Frames"])
        end
    elseif cmd == "reset" then
        if SquizzFrames.db then
            -- ResetProfile defers itself until combat ends (ProfileStore's
            -- GuardedCall), so reloading immediately would destroy the
            -- queued reset and silently do nothing at all. Bug fix
            -- 2026-08-07: refuse in combat and say why, rather than
            -- pretending it worked.
            if InCombatLockdown() then
                SquizzFrames.Print("Can't reset while in combat -- try again once you're out.")
            else
                SquizzFrames.db:ResetProfile()
                ReloadUI()
            end
        end
    elseif cmd == "nick" or cmd == "nickname" then
        -- Everything after the subcommand is passed through verbatim --
        -- nicknames may contain spaces, so this must not be tokenized here.
        local rest = msg:match("^%s*%S+%s+(.-)%s*$") or ""
        local Nicknames = SquizzFrames.Nicknames
        if Nicknames and Nicknames.HandleSlash then
            Nicknames:HandleSlash(rest)
        else
            SquizzFrames:Print("Nicknames module isn't loaded.")
        end
    elseif cmd == "healer" then
        if SquizzFrames.ApplyHealerPreset then
            SquizzFrames.ApplyHealerPreset()
        else
            SquizzFrames.Print("Healer preset not available yet.")
        end
    end
end
