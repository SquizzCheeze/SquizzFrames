--[[ SquizzFrames Pet Frames Defaults ]]
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

local profile = defaults.profile

-- Named "main"/"raid" (not "party"/"raid") to match profile.layout.main/.raid
-- exactly -- lets GetActivePetLayout(prof) in PetFrames.lua be a one-line
-- copy of PartyFrames.lua's own GetActiveLayout(prof). anchorX/anchorY carry
-- the same meaning as profile.layout.main's own fields (Floating container's
-- CENTER->CENTER screen offset), which is why CreatePetGroupContainer can
-- closely mirror CreatePartyContainer.
-- Pet name text. Its own sub-table per mode (like every other pet setting) so
-- party and raid can diverge -- a raid pet frame is far smaller and usually
-- wants a smaller font, or none at all.
--
-- font mirrors the party Name Text indicator's own shape,
-- {face, size, flags, shadow}, so F.ResolveFontFile and the same outline
-- vocabulary apply unchanged. anchorPoint/offsetX/offsetY replace the XML's
-- fixed two-point TOPLEFT+TOPRIGHT anchoring; see ApplyPetNameText.
local function DefaultPetNameText(size)
    return {
        enabled = true,
        font = {"Friz QT__", size, "OUTLINE", true},
        color = {"custom_color", 1, 1, 1, 1},
        anchorPoint = "TOPLEFT",
        offsetX = 2,
        offsetY = -1,
    }
end

profile.petFrames = {
    main = {
        enabled = false,
        mode = "attached",       -- "attached" | "floating"
        width = 60,
        height = 24,
        -- Take the owner frame's width/height instead of the sliders above,
        -- independently of each other. Only meaningful in attached mode -- a
        -- floating pet group has no single owner to match (see ResolvePetSize
        -- in PetFrames.lua).
        matchOwnerWidth = false,
        matchOwnerHeight = false,
        nameText = DefaultPetNameText(10),
        anchorSide = "RIGHT",     -- LEFT | RIGHT | TOP | BOTTOM (attached mode)
        offsetX = 4,
        offsetY = 0,
        anchorX = 0,              -- floating container CENTER->CENTER offset
        anchorY = -260,
        orientation = "vertical",
        growthDirection = "DOWN",
        spacingY = 2,
    },
    raid = {
        enabled = false,
        mode = "attached",
        width = 40,
        height = 16,
        matchOwnerWidth = false,
        matchOwnerHeight = false,
        nameText = DefaultPetNameText(9),
        anchorSide = "RIGHT",
        offsetX = 2,
        offsetY = 0,
        anchorX = 0,
        anchorY = 260,
        orientation = "vertical",
        growthDirection = "DOWN",
        spacingY = 2,
    },
}
