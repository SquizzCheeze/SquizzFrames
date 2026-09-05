--[[ SquizzFrames UnitFrames Icons

    Small state icons on the standalone unit frames:

      "combat"  the crossed-swords in-combat marker (Player frame only -- see
                the note on the options page below)
      "leader"  the group leader crown, falling back to the assistant badge

    Both share one shape -- enabled / anchor / offsetX / offsetY / size /
    color -- so one factory serves them and a third icon costs a table entry
    rather than a file.

    SECRET VALUES. UnitIsGroupLeader, UnitIsGroupAssistant and
    UnitAffectingCombat all belong to the class of unit APIs that return
    SECRET booleans once a unit's identity is restricted (12.1). A secret
    boolean passes `if x then` harmlessly but throws the moment it is
    compared, so every read here goes through one of two paths:

      * plain branching, when F.IsValueNonSecret says the value is readable
      * SetAlphaFromBoolean, which consumes the boolean C-side without ever
        exposing it to Lua

    See the range-checks-in-combat note in Utils.lua for the same pattern on
    UnitInRange, and CLAUDE.md's "Secret Numbers" section for why type() is
    not a substitute for F.IsValueNonSecret.
]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end
local F = SquizzFrames.F

local Icons = {}
SquizzFrames.UnitFrameIcons = Icons

-- Settings key per icon is <element>Icon on the frame's config table, so
-- "combat" reads t.combatIcon. Kept derivable rather than listed twice.
Icons.ELEMENTS = {"combat", "leader"}

local function SettingsKey(element)
    return element .. "Icon"
end
Icons.SettingsKey = SettingsKey

-- The in-combat swords. Blizzard's own PlayerFrame draws this from
-- UI-StateIcon, a four-quadrant sheet: the attack/combat quadrant is the
-- right half, the rest ("zzz") is the left. These texcoords are lifted from
-- PlayerFrame.xml's PlayerAttackIcon and have been stable across many
-- expansions -- there is no atlas name for it that this build guarantees.
local COMBAT_TEXTURE = "Interface\\CharacterFrame\\UI-StateIcon"
local COMBAT_TEXCOORD = {0.5, 1.0, 0.0, 0.49}

-- Same two files the party frames' leaderIcon indicator uses
-- (BuiltIn_Update.lua's CheckLeaderIcon), deliberately: one look for the same
-- concept across both frame types.
local LEADER_TEXTURE = "Interface\\GroupFrame\\UI-Group-LeaderIcon"
local ASSISTANT_TEXTURE = "Interface\\GroupFrame\\UI-Group-AssistantIcon"

-----------------------------------------------------------------------
-- Creation
-----------------------------------------------------------------------

-- One holder frame per unit frame, carrying a Texture per element.
--
-- Parented ABOVE the health bar's level so an icon sitting over the bar is
-- visible, and below the portrait's (+3) so an icon anchored into a portrait
-- corner does not cover the face.
function Icons.Create(parent, unit)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetFrameStrata(parent:GetFrameStrata() or "MEDIUM")
    holder:SetFrameLevel((parent:GetFrameLevel() or 1) + 2)
    holder:SetAllPoints(parent)

    holder.textures = {}
    for _, element in ipairs(Icons.ELEMENTS) do
        local tex = holder:CreateTexture(nil, "OVERLAY")
        tex:SetSize(16, 16)
        tex:Hide()
        if element == "combat" then
            tex:SetTexture(COMBAT_TEXTURE)
            tex:SetTexCoord(unpack(COMBAT_TEXCOORD))
        end
        holder.textures[element] = tex
    end

    holder.unit = unit
    return holder
end

-----------------------------------------------------------------------
-- Settings
-----------------------------------------------------------------------

-- Anchor/size/colour. Split from Update (which handles STATE) because these
-- change only on a settings edit while Update runs on every combat and roster
-- event -- the same division Portrait.lua and CastBar.lua use.
function Icons.ApplySettings(holder, frame, t)
    if not holder or not frame then return end
    holder:ClearAllPoints()
    holder:SetAllPoints(frame)

    for _, element in ipairs(Icons.ELEMENTS) do
        local tex = holder.textures and holder.textures[element]
        local cfg = t and t[SettingsKey(element)]
        if tex then
            if not cfg or not cfg.enabled then
                tex:Hide()
            else
                local size = cfg.size or 16
                tex:SetSize(size, size)
                tex:ClearAllPoints()
                local anchor = cfg.anchor or "TOPRIGHT"
                -- Anchored to the whole FRAME, not the health bar: these are
                -- frame furniture rather than readouts of the bar's value, and
                -- a corner icon that shifts when the power bar's height
                -- changes reads as a bug.
                tex:SetPoint(anchor, frame, anchor, cfg.x or 0, cfg.y or 0)
                local c = cfg.color
                if c then
                    -- Vertex colour TINTS the existing art rather than
                    -- replacing it, which is the only thing a texture-based
                    -- icon can offer. White (the default) leaves it alone.
                    tex:SetVertexColor(c[1] or 1, c[2] or 1, c[3] or 1)
                    tex:SetAlpha(c[4] or 1)
                else
                    tex:SetVertexColor(1, 1, 1)
                    tex:SetAlpha(1)
                end
                -- Shown/hidden by state in Update; ApplySettings only decides
                -- whether it is eligible to show at all.
                tex:Show()
            end
        end
    end
end

-----------------------------------------------------------------------
-- State
-----------------------------------------------------------------------

-- Show/hide by live state, secret-safely.
--
-- ShowFromBoolean does not exist; SetAlphaFromBoolean is the one C-side
-- consumer of a possibly-secret boolean available here, so the icon is kept
-- SHOWN and driven to alpha 0/1 rather than being Show()n and Hide()n. That
-- also avoids a Show/Hide on every combat transition, which on a secure
-- frame's child would be one more thing to have to combat-guard.
local function ApplyBool(tex, value)
    if F and F.IsValueNonSecret and F.IsValueNonSecret(value) then
        tex:SetAlpha(value and (tex._sfAlpha or 1) or 0)
        return
    end
    if tex.SetAlphaFromBoolean then
        tex:SetAlphaFromBoolean(value, tex._sfAlpha or 1, 0)
    else
        -- No secret-safe path on this client. `if value then` is legal on a
        -- secret (it is comparison and table-indexing that throw), so this
        -- degrades to a correct-but-unguarded read rather than an error.
        tex:SetAlpha(value and (tex._sfAlpha or 1) or 0)
    end
end

function Icons.Update(holder, unit, t)
    if not holder or not unit then return end

    local combat = holder.textures and holder.textures.combat
    local combatCfg = t and t.combatIcon
    if combat then
        if not combatCfg or not combatCfg.enabled or not UnitExists(unit) then
            combat:SetAlpha(0)
        else
            combat._sfAlpha = (combatCfg.color and combatCfg.color[4]) or 1
            ApplyBool(combat, UnitAffectingCombat(unit))
        end
    end

    local leader = holder.textures and holder.textures.leader
    local leaderCfg = t and t.leaderIcon
    if leader then
        if not leaderCfg or not leaderCfg.enabled or not UnitExists(unit) then
            leader:SetAlpha(0)
        else
            leader._sfAlpha = (leaderCfg.color and leaderCfg.color[4]) or 1
            local isLeader = UnitIsGroupLeader(unit)
            if F and F.IsValueNonSecret and F.IsValueNonSecret(isLeader) then
                -- Readable: the full three-way (crown / badge / nothing).
                if isLeader then
                    leader:SetTexture(LEADER_TEXTURE)
                    leader:SetAlpha(leader._sfAlpha)
                elseif UnitIsGroupAssistant(unit) then
                    leader:SetTexture(ASSISTANT_TEXTURE)
                    leader:SetAlpha(leader._sfAlpha)
                else
                    leader:SetAlpha(0)
                end
            else
                -- Secret: the assistant distinction needs a comparison we
                -- cannot make, so this degrades to leader-or-nothing rather
                -- than throwing. An assistant simply shows no icon until the
                -- identity gate reopens.
                leader:SetTexture(LEADER_TEXTURE)
                ApplyBool(leader, isLeader)
            end
        end
    end
end
