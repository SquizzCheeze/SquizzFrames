--[[ SquizzFrames Media Registration ]]
local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local LSM = LibStub and LibStub:GetLibrary("LibSharedMedia-3.0", true)
if not LSM then return end

-- Register statusbar textures
LSM:Register("statusbar", "Blizzard", [[Interface\TargetingFrame\UI-StatusBar]])
LSM:Register("statusbar", "Solid", [[Interface\Buttons\WHITE8X8]])
LSM:Register("statusbar", "Minimalist", [[Interface\AddOns\SquizzFrames\Media\Textures\Minimalist.tga]])
LSM:Register("statusbar", "Gradient", [[Interface\AddOns\SquizzFrames\Media\Textures\Gradient.tga]])
-- Shield/absorb overlay pattern, registered under LSM (rather than only
-- hardcoded into Shield Overlay's texture) so it's selectable from the same
-- generic statusbar dropdown used for Shield Overlay/Heal Absorb's own
-- texture picker -- see IndicatorWidgets.lua's CreateSetting_BarTexture.
LSM:Register("statusbar", "Shield", [[Interface\AddOns\SquizzFrames\Media\shield]])
-- Striped absorb/shield patterns, for further differentiating Shield
-- Overlay/Heal Absorb from each other (or picking a density that reads well
-- at the party frame's health bar height).
LSM:Register("statusbar", "Sparse Stripes", [[Interface\AddOns\SquizzFrames\Media\Sparse_Stripes.tga]])
LSM:Register("statusbar", "Soft Stripes", [[Interface\AddOns\SquizzFrames\Media\Soft_Stripes.tga]])
LSM:Register("statusbar", "Soft Stripes Wide", [[Interface\AddOns\SquizzFrames\Media\Soft_Stripes_Wide.tga]])
LSM:Register("statusbar", "Medium Stripes", [[Interface\AddOns\SquizzFrames\Media\Medium_Stripes.tga]])
LSM:Register("statusbar", "Dense Stripes", [[Interface\AddOns\SquizzFrames\Media\Dense_Stripes.tga]])
LSM:Register("statusbar", "Very Dense Stripes", [[Interface\AddOns\SquizzFrames\Media\Very_Dense_Stripes.tga]])

-- Health/power bar texture set matching EllesmereUIRaidFrames' own curated
-- list exactly (name-for-name, same 19 entries including "None" -- see
-- EllesmereUIRaidFrames.lua's InitHealthBarTextures/healthBarTextureOrder).
-- Registered under their own names so OptionsFrame.lua's Bar Texture
-- dropdown can present a fixed, ordered list matching Ellesmere's, without
-- pulling in every other addon's SharedMedia registrations too.
LSM:Register("statusbar", "None", [[Interface\Buttons\WHITE8X8]])
LSM:Register("statusbar", "Melli (ElvUI)", [[Interface\AddOns\SquizzFrames\Media\Textures\melli.tga]])
LSM:Register("statusbar", "Atrocity", [[Interface\AddOns\SquizzFrames\Media\Textures\atrocity.tga]])
LSM:Register("statusbar", "Fade", [[Interface\AddOns\SquizzFrames\Media\Textures\fade.tga]])
LSM:Register("statusbar", "Fade Right", [[Interface\AddOns\SquizzFrames\Media\Textures\fade-right.tga]])
LSM:Register("statusbar", "Thin Line Top", [[Interface\AddOns\SquizzFrames\Media\Textures\thin-line-top.tga]])
LSM:Register("statusbar", "Thin Line Bottom", [[Interface\AddOns\SquizzFrames\Media\Textures\thin-line-bottom.tga]])
LSM:Register("statusbar", "Beautiful", [[Interface\AddOns\SquizzFrames\Media\Textures\beautiful.tga]])
LSM:Register("statusbar", "Plating", [[Interface\AddOns\SquizzFrames\Media\Textures\plating.tga]])
LSM:Register("statusbar", "Divide", [[Interface\AddOns\SquizzFrames\Media\Textures\divide.tga]])
LSM:Register("statusbar", "Glass", [[Interface\AddOns\SquizzFrames\Media\Textures\glass.tga]])
LSM:Register("statusbar", "Gradient Right", [[Interface\AddOns\SquizzFrames\Media\Textures\gradient-lr.tga]])
LSM:Register("statusbar", "Gradient Left", [[Interface\AddOns\SquizzFrames\Media\Textures\gradient-rl.tga]])
LSM:Register("statusbar", "Gradient Up", [[Interface\AddOns\SquizzFrames\Media\Textures\gradient-bt.tga]])
LSM:Register("statusbar", "Gradient Down", [[Interface\AddOns\SquizzFrames\Media\Textures\gradient-tb.tga]])
LSM:Register("statusbar", "Matte", [[Interface\AddOns\SquizzFrames\Media\Textures\matte.tga]])
LSM:Register("statusbar", "Sheer", [[Interface\AddOns\SquizzFrames\Media\Textures\sheer.tga]])
LSM:Register("statusbar", "Blinkii Diamonds", [[Interface\AddOns\SquizzFrames\Media\Textures\blinkii-diamonds.tga]])
LSM:Register("statusbar", "Kringel Window", [[Interface\AddOns\SquizzFrames\Media\Textures\kringel-window.tga]])

-- Register borders
LSM:Register("border", "Default", [[Interface\Tooltips\UI-Tooltip-Border]])

-- Register fonts
LSM:Register("font", "Friz Quadrata", [[Fonts\FRIZQT__.TTF]])
LSM:Register("font", "Arial Narrow", [[Fonts\ARIALN.TTF]])
LSM:Register("font", "Skurri", [[Fonts\skurri.TTF]])

-- Register sounds
LSM:Register("sound", "Raid Warning", [[Sound\RaidWarning.wav]])
