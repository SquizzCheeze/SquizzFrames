--[[ SquizzFrames Click-Casting Defaults ]]
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

-- Click-cast bindings. Each entry: { bindKey, modifier, type, action }
-- bindKey:   "Left","Right","Middle","Button4","Button5","ScrollUp","ScrollDown"
-- modifier:  "","shift-","ctrl-","alt-","shift-ctrl-","shift-alt-","ctrl-alt-","shift-ctrl-alt-"
-- type:      "spell","macro","item","target","focus","assist","menu"
-- action:    spellID (number) | macrotext (string) | itemID (number|string)
--            | nil for target/focus/assist/menu
profile.clickCasting = {
    {bindKey = "Left", modifier = "", type = "target", action = nil},
    {bindKey = "Right", modifier = "", type = "menu", action = nil},
}

-- Smart Resurrection: "disabled" | "normal" | "combat" | "normalcombat".
-- Only applies to the unmodified Left-click binding when it's a Spell type.
profile.smartResurrection = "disabled"

-- Apply the bindings above to unit frames SquizzFrames doesn't own, so
-- click-casting works on units with no SquizzFrames frame -- most usefully
-- dungeon and raid bosses. Covers Blizzard's frames (player, pet, target,
-- target-of-target, focus and the boss frames) and EllesmereUI's party/raid/
-- boss/extra frames when that addon is present.
--
-- Defaults ON, which is safe precisely because the DEFAULT bindings above are
-- Left = target and Right = menu -- exactly what those frames already do. It
-- only becomes a visible change once the user binds something of their own,
-- which is the point.
profile.clickCastBlizzardFrames = true

defaults.profile = profile
