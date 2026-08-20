--[[ =========================================================================
    SquizzFrames ClickCasting Module
    Cell-style click casting built on SecureActionButtonTemplate attributes.

    Each binding is a row { bindKey, modifier, type, action } stored in
    profile.clickCasting. On apply we write WoW secure attributes directly
    onto every unit button:
        type1 / macrotext1 / spell1 / item1 / ...   (LeftButton)
        shift-type2 / shift-macrotext2 / ...          (Shift+RightButton)
        type-SCROLLUP / ...                           (mouse wheel)
    WoW's SecureActionButton engine then routes clicks to those actions.

    Spells are written as /cast [@mouseover] macros (not native "spell"
    type) so we can add [nodead]/[dead] conditions and support resurrection
    spells that auto-target dead units.
-------------------------------------------------------------------------- ]]

local SquizzFrames = _G["SquizzFrames"]
if not SquizzFrames then return end

local F = SquizzFrames.F

---@class AceModule
local ClickCasting = SquizzFrames:NewModule("ClickCasting", "AceEvent-3.0")

-- Local state
--
-- A SET of headers, not one (2026-08-20): raid mode is driven by eight
-- subgroup headers instead of a single one, and PartyFrames fires
-- PartyButtonsWired once per header. Keeping only the last one to arrive left
-- seven raid groups with no click-casting at all. Stale headers are harmless
-- here -- a header the current mode isn't using has hidden, unit-less children,
-- and re-writing their attributes costs nothing.
local headerFrames = {}
local applyPending = false  -- coalesces the burst of PartyButtonsWired fires

-----------------------------------------------------------------------
-- Constants
-----------------------------------------------------------------------

-- Mouse button → SecureActionButton "typeN" index
local MOUSE_KEY_IDS = {
    Left = 1,
    Right = 2,
    Middle = 3,
    Button4 = 4,
    Button5 = 5,
}

-- Known resurrection spell IDs (retail TWW). Used to pick the
-- [@mouseover,dead] condition instead of [nodead], and to exclude a
-- directly-bound res spell from Smart Resurrection's own fallback (nothing
-- to smart-fallback to if the bound spell is already a res). Extended with
-- the mass/spec-tier variants Smart Resurrection can cast, so a direct bind
-- of any of them also gets correct dead/nodead treatment.
local RESURRECTION_SPELLS = {
    [2008] = true,     -- Ancestral Spirit (shaman)
    [20484] = true,    -- Rebirth (druid)
    [2006] = true,     -- Resurrection (priest)
    [61999] = true,    -- Raise Ally (death knight)
    [20707] = true,    -- Soulstone (warlock)
    [7328] = true,     -- Redemption (paladin)
    [361227] = true,   -- Return (evoker)
    [50769] = true,    -- Revive (druid, restoration)
    [212040] = true,   -- Revitalize (druid, restoration mass)
    [361178] = true,   -- Mass Return (evoker, preservation)
    [115178] = true,   -- Resuscitate (monk)
    [212051] = true,   -- Reawaken (monk, mistweaver mass)
    [391054] = true,   -- Intercession (paladin, combat res)
    [212056] = true,   -- Absolution (paladin, holy mass)
    [212036] = true,   -- Mass Resurrection (priest, holy/disc mass)
    [212048] = true,   -- Ancestral Vision (shaman, restoration mass)
}

-- Smart Resurrection: normal (out-of-combat) resurrection per class, split
-- by spec tier using native [spec:N]/[nospec:N] macro conditionals -- the
-- healer spec ("spec:N") gets its mass-res version, every other spec
-- ("nospec:N") gets the single-target one. Classes without any normal-res
-- option (Death Knight, Warlock) are absent -- their only res is combat-only
-- (see COMBAT_RESURRECTION). Ported from Cell's own curated, community-
-- vetted list (Utilities/ClickCasting_DefaultSpells.lua, normalResurrection).
local NORMAL_RESURRECTION = {
    ["DRUID"]   = { ["nospec:4"] = 50769,  ["spec:4"] = 212040 },
    ["EVOKER"]  = { ["nospec:2"] = 361227, ["spec:2"] = 361178 },
    ["MONK"]    = { ["nospec:2"] = 115178, ["spec:2"] = 212051 },
    ["PALADIN"] = { ["nospec:1"] = 7328,   ["spec:1"] = 212056 },
    ["PRIEST"]  = { ["spec:3"] = 2006,     ["nospec:3"] = 212036 },
    ["SHAMAN"]  = { ["nospec:3"] = 2008,   ["spec:3"] = 212048 },
}

-- Smart Resurrection: combat ("battle") resurrection per class -- only
-- these four classes have one, single-target only (no mass battle-res
-- exists in retail). Same source as NORMAL_RESURRECTION above.
local COMBAT_RESURRECTION = {
    ["DEATHKNIGHT"] = 61999,  -- Raise Ally
    ["DRUID"]       = 20484,  -- Rebirth
    ["PALADIN"]     = 391054, -- Intercession
    ["WARLOCK"]     = 20707,  -- Soulstone
}

-- Build the ";[...] Spell" fallback segments for Smart Resurrection, based
-- on the profile's smartResurrection mode ("normal", "combat", or
-- "normalcombat" -- prefix/suffix matched so all 3 share one code path,
-- mirroring Cell's own strfind("^normal") / strfind("combat$") checks).
local function BuildSmartResMacroSegments(mode)
    local segments = {}
    if mode == "disabled" or not mode then return segments end
    local class = select(2, UnitClass("player"))

    if mode:match("^normal") then
        local tiers = NORMAL_RESURRECTION[class]
        if tiers then
            for cond, spellId in pairs(tiers) do
                local name = F.GetSpellInfo(spellId)
                if name then
                    tinsert(segments, "[@mouseover,dead,nocombat," .. cond .. "] " .. name)
                end
            end
        end
    end

    if mode:match("combat$") then
        local combatSpellId = COMBAT_RESURRECTION[class]
        local name = combatSpellId and F.GetSpellInfo(combatSpellId)
        if name then
            tinsert(segments, "[@mouseover,dead,combat] " .. name)
        end
    end

    return segments
end

-----------------------------------------------------------------------
-- Attribute key encoding (mirrors Cell's GetAttributeKey)
-----------------------------------------------------------------------

-- Normalize modifier to canonical ALT-CTRL-SHIFT order.
local function NormalizeModifier(modifier)
    if not modifier or modifier == "" then return "" end
    local parts = {}
    for m in modifier:gmatch("([^-]+)%-") do
        parts[strupper(m)] = true
    end
    local result = ""
    if parts.ALT then result = result .. "alt-" end
    if parts.CTRL then result = result .. "ctrl-" end
    if parts.SHIFT then result = result .. "shift-" end
    if parts.META then result = result .. "meta-" end
    return result
end

-- Build the secure attribute key for a given bind + modifier.
-- e.g. ("Left", "shift-")  → "shift-type1"
--      ("ScrollUp", "ctrl-") → "ctrl-type-SCROLLUP"
local function GetAttributeKey(modifier, bindKey)
    if not bindKey or bindKey == "" then return "" end
    modifier = NormalizeModifier(modifier)
    local id = MOUSE_KEY_IDS[bindKey]
    if id then
        return modifier .. "type" .. id
    end
    -- Mouse wheel or keyboard key
    return modifier .. "type-" .. strupper(bindKey)
end

-----------------------------------------------------------------------
-- Click-gate workaround (12.0.7)
-----------------------------------------------------------------------
-- 12.0.7 gates "target", "menu", "togglemenu" actions on unit buttons
-- (SecureUnitButton_OnClick checks C_ClickBindings.GetBindingType and
-- drops non-default clicks). Macrotext with [@mouseover] bypasses the gate.
--
-- Gated target: use macrotext "/target [@mouseover,exists]" - WORKS
-- Gated menu: macrotext "/togglemenu" does NOT work in secure context
-- (UnitFrameDropDown unavailable). Both go through the click proxy below
-- instead, which sidesteps the gate entirely by never being a unit button.
--
-- "Gated" covers KEYBOARD and MOUSE WHEEL binds too, not just mouse buttons
-- -- the gate is on the clicked button NAME, and ours are invented. See
-- IsGatedAction.

-- Decide if an action is gated for a given bind key.
local function IsGatedAction(bindKey, actionType)
    if not bindKey or bindKey == "" then return false end
    if actionType ~= "target" and actionType ~= "togglemenu"
      and actionType ~= "menu" then
        return false
    end
    -- Parse modifier prefix and the keyboard/wheel key from bindKey.
    local modifier, _, key = strmatch(bindKey, "^(.*)type(-*)(.+)$")
    if not modifier then return false end
    local hasModifier = modifier and modifier ~= ""
    local buttonNum = tonumber(key)
    -- KEYBOARD / WHEEL (no numeric button): ALWAYS gated, modifier or not.
    --
    -- This used to return false here, on the belief that only physical mouse
    -- buttons are gated. Blizzard's SecureUnitButton_OnClick says otherwise --
    -- it gates on the BUTTON STRING it was clicked with, whatever that is:
    --
    --     local bindingType = C_ClickBindings.GetBindingType(button, modifiers)
    --     local expectBinding = type == "target" or type == "menu"
    --                        or type == "togglemenu"
    --     if expectBinding and bindingType == Enum.ClickBindingType.None then
    --         return
    --     end
    --
    -- Our keyboard bindings fire a VIRTUAL click whose button name is our own
    -- invention ("kb3"), so GetBindingType can only ever answer None -- the
    -- gate shuts every time and the click silently does nothing. Confirmed by
    -- user report 2026-08-14: a plain "Y" bound to menu did nothing, with or
    -- without a modifier, while spells on the same keys worked (they never
    -- reach the expectBinding test at all).
    if not buttonNum then return true end
    if actionType == "target" then
        -- gated when a modifier is held OR the button isn't Left (1)
        return hasModifier or buttonNum ~= 1
    else -- togglemenu / menu
        -- gated when a modifier is held OR the button isn't Right (2)
        return hasModifier or buttonNum ~= 2
    end
end

-- Profile accessor
local function GetProfile()
    return SquizzFrames.db and SquizzFrames.db.profile
end

-----------------------------------------------------------------------
-- Gated-action proxy (12.0.7+)
-----------------------------------------------------------------------
-- A raw "target" or "togglemenu" on a unit button is gated unless the click
-- matches the default (unmodified Left/Right) binding. For menu, re-opening
-- it from insecure Lua taints its protected items (Set Focus -> FocusUnit,
-- Follow, etc.), so the only fix is a SECURE click through a hidden proxy
-- button whose own (ungated) SecureActionButton_OnClick performs the real
-- action. "useparent-unit" makes the proxy resolve the unit from the parent
-- button, so it works for header-managed party buttons whose unit changes.
--
-- Target USED to go through a "/target [@mouseover,exists]" macro instead
-- (macrotext isn't gated) -- that worked for units the mouse can physically
-- resolve, but silently failed to target a party member who's out of range
-- or in a different instance/phase (confirmed via user report: the
-- UNGATED default Left-click target binding, which uses the native "target"
-- attribute type directly with no mouseover/macro involved, targeted them
-- fine). Routing target through this SAME proxy (matching Cell's own
-- ClickCastings.lua RouteProxyAction, which treats target and menu
-- identically) reuses that native unit-token-based path instead, so it
-- doesn't depend on mouseover/exists resolving at all.
--
-- 12.1 additionally broke the "click" + "clickbutton" transport outright
-- (a Blizzard typo in SecureTemplates.lua checks forbidden aspects on the
-- mouse-button STRING instead of the delegate, and throws). Confirmed via
-- EllesmereUI's click-casting module (EllesmereUI_Kick.lua), which works
-- around it with a "/click <ProxyGlobalName>" macro transport instead --
-- that calls SecureActionButton_OnClick directly, bypassing the buggy
-- code path. This mirrors that fix.
local IS_121 = SquizzFrames.IS_121

local actionProxies = setmetatable({}, { __mode = "k" })
local actionProxyCounter = 0
local function GetActionProxy(button)
    if not button then return end
    local proxy = actionProxies[button]
    if proxy then return proxy end
    local proxyName
    if IS_121 then
        -- 12.1's macro transport references the proxy by name ("/click
        -- <name>"), so it needs a global name. 12.0's clickbutton transport
        -- references the frame object directly, so it stays anonymous.
        actionProxyCounter = actionProxyCounter + 1
        proxyName = "SquizzFramesActionProxy" .. actionProxyCounter
    end
    proxy = CreateFrame("Button", proxyName, button, "SecureActionButtonTemplate")
    proxy:SetSize(1, 1)
    proxy:SetAlpha(0)
    proxy:EnableMouse(false) -- never catches real mouse; only /click or clickbutton reaches it
    proxy:RegisterForClicks("AnyUp")
    proxy:SetAttribute("useparent-unit", true)
    -- Act on the up-click regardless of the "cast on key down" CVar -- without
    -- this, SecureActionButton_OnClick's clickAction gate can skip the action
    -- when ActionButtonUseKeyDown is on.
    proxy:SetAttribute("useOnKeyDown", false)
    actionProxies[button] = proxy
    return proxy
end

-- Route ONE gated attrKey (e.g. "shift-type1", "type3") through the proxy,
-- carrying whichever native action it needs ("target" or "togglemenu") under
-- that EXACT same suffix -- the secure resolver looks up the proxy's action
-- by the same derived button+modifier suffix as the original click, so this
-- must match attrKey precisely (a bare "type1..5" fallback, which a prior
-- version of this used, never covers a MODIFIED gated binding like
-- Shift+Left-click). Mirrors Cell's RouteProxyAction.
-- Mouse-button suffix (typeN) -> the button name "/click" needs.
-- 12.1 macro transport only; see RouteProxyAction.
local PROXY_CLICK_BUTTON = {
    [1] = "LeftButton",
    [2] = "RightButton",
    [3] = "MiddleButton",
    [4] = "Button4",
    [5] = "Button5",
}

-- modifierAgnostic: keyboard/wheel bindings only. Their attribute suffix is a
-- row index ("type-kb3") with NO modifier prefix, because the modifier is
-- carried by the physical key handed to SetBindingClick instead (see
-- ApplyClickCastings' keyboard branch for why that had to change).
--
-- The proxy doesn't know that. SecureButton_GetModifiedAttribute derives its
-- prefix from the modifiers PHYSICALLY HELD at click time, so with Alt down it
-- looks for "alt-type-kb3" and finds nothing. Blizzard's lookup chain is
--     <prefix><name><suffix> -> <prefix><name>* -> *<name><suffix> -> ...
-- so writing the WILDCARD-PREFIX form "*type-kb3" answers every modifier state
-- with one attribute -- which is correct here precisely because the modifier
-- has already been accounted for upstream.
--
-- Mouse bindings keep the exact key: their attrKey carries the modifier and
-- the real physical click carries the same one, so they match as-is.
local function RouteProxyAction(button, attrKey, realAction, modifierAgnostic)
    local proxy = GetActionProxy(button)
    proxy:SetAttribute(modifierAgnostic and ("*" .. attrKey) or attrKey, realAction)
    local clickbuttonKey = attrKey:gsub("type", "clickbutton", 1)
    local macrotextKey = attrKey:gsub("type", "macrotext", 1)
    if IS_121 then
        -- "/click <frame>" with NO button argument clicks with LeftButton.
        -- The proxy's own SecureActionButton_OnClick then derives which
        -- attribute to run from the button it actually received plus the
        -- modifiers still physically held -- i.e. "<mods->type1" -- so a
        -- binding on any button other than Left looked up an attribute we
        -- never set, and silently did nothing.
        --
        -- That's why modified TARGET worked but modified MENU didn't on the
        -- PTR (bug report 2026-08-11): target is conventionally Left (type1),
        -- which happened to match the LeftButton default, while menu is
        -- conventionally Right (type2), which never did. Same latent break
        -- for a target bound to any non-Left button.
        --
        -- Passing the matching button name makes the proxy resolve the exact
        -- attrKey we set on it. 12.1-only by construction (this whole branch
        -- is IS_121); 12.0.7 keeps the clickbutton transport untouched, which
        -- never had the problem because it forwards the real button itself.
        local buttonNum = tonumber(attrKey:match("type(%d)$"))
        local clickButton = buttonNum and PROXY_CLICK_BUTTON[buttonNum]
        if not clickButton then
            -- KEYBOARD / WHEEL: the suffix is a name, not a number
            -- ("type-kb3" -> "kb3", "ctrl-type-SCROLLUP" -> "SCROLLUP"), and
            -- it's passed through to /click verbatim. The proxy then derives
            -- its attribute from that same name, so it finds the exact key we
            -- set above. Without this the macro carried no button at all,
            -- which means LeftButton -- the proxy looked up "type1", which we
            -- never set, and the binding silently did nothing.
            clickButton = attrKey:match("type%-(.+)$")
        end
        local macro = "/click " .. proxy:GetName()
        if clickButton then
            macro = macro .. " " .. clickButton
        end
        button:SetAttribute(attrKey, "macro")
        button:SetAttribute(macrotextKey, macro)
        button:SetAttribute(clickbuttonKey, nil)
    else
        button:SetAttribute(attrKey, "click")
        button:SetAttribute(clickbuttonKey, proxy)
        button:SetAttribute(macrotextKey, nil)
    end
end

-- Clear every override binding we set on a frame for keyboard/wheel keys.
-- WoW's ClearOverrideBindings(owner) wipes ALL override bindings for that owner.
local function WipeOverrideBindings(frame)
    if not frame then return end
    if InCombatLockdown() then return end
    ClearOverrideBindings(frame)
    frame.cellOverrideKeys = nil
end

-- Remove all click-cast attributes from a button so we start clean.
-- Also clears tracked keyboard/wheel attributes (type-E, macrotext-E, etc.)
-- that were set by the previous ApplyClickCastings call.
local function ClearClickCastings(button)
    if not button then return end
    local mods = {"", "shift-", "ctrl-", "alt-", "shift-ctrl-", "shift-alt-", "ctrl-alt-", "shift-ctrl-alt-"}
    -- Mouse buttons: typeN / macrotextN / spellN / itemN / clickbuttonN
    for _, k in ipairs({"type", "macrotext", "spell", "item", "clickbutton"}) do
        for _, mod in ipairs(mods) do
            for i = 1, 5 do
                button:SetAttribute(mod .. k .. i, nil)
            end
        end
    end
    -- Also clear plain clickbuttonN (no modifier)
    for i = 1, 5 do
        button:SetAttribute("clickbutton" .. i, nil)
    end
    -- WILDCARD ("*type1") forms. We never write these ourselves, so this is a
    -- no-op on our own buttons -- it exists for frames we take over from
    -- another addon. EllesmereUI, for one, sets *type1 = "target" on its boss
    -- frames, and the wildcard is consulted when no exact modifier match
    -- exists: without clearing it, holding a modifier we haven't bound would
    -- silently fall through to THEIR action instead of doing nothing, so a
    -- half-bound modifier set would behave inconsistently between our frames
    -- and theirs.
    for _, k in ipairs({"type", "macrotext", "spell", "item", "clickbutton"}) do
        for i = 1, 5 do
            button:SetAttribute("*" .. k .. i, nil)
        end
        button:SetAttribute("*" .. k .. "*", nil)
    end
    -- Mouse wheel: type-SCROLLUP / type-SCROLLDOWN (and modifier variants)
    for _, mod in ipairs(mods) do
        button:SetAttribute(mod .. "type-SCROLLUP", nil)
        button:SetAttribute(mod .. "type-SCROLLDOWN", nil)
        button:SetAttribute(mod .. "macrotext-SCROLLUP", nil)
        button:SetAttribute(mod .. "macrotext-SCROLLDOWN", nil)
    end
    -- Keyboard keys: clear tracked attributes from the previous apply, along
    -- with the value attribute that went with each one.
    --
    -- The suffix is the binding's ROW INDEX ("type-kb3"), so it gets reused
    -- when bindings are reordered or deleted. Clearing only the type left the
    -- old row's value attribute behind under a suffix the next row would
    -- claim -- inert while the two disagree (the engine reads `type` first),
    -- but only by luck. Now that gated keyboard actions write a macrotext
    -- here too, clear the lot.
    if button.squizzKeyboardAttrs then
        for _, attr in ipairs(button.squizzKeyboardAttrs) do
            button:SetAttribute(attr, nil)
            for _, k in ipairs({"macrotext", "spell", "item", "clickbutton"}) do
                button:SetAttribute((attr:gsub("type", k, 1)), nil)
            end
        end
        button.squizzKeyboardAttrs = nil
    end
    -- Also clear plain clickbuttonN (no modifier)
    for i = 1, 5 do
        button:SetAttribute("clickbutton" .. i, nil)
    end
    -- Clear any override bindings we set for keyboard/wheel keys.
    WipeOverrideBindings(button)

    -- Blizzard's own "menu" attribute (bug fix 2026-07-31, user report:
    -- plain right-click kept opening the menu even after rebinding it to a
    -- spell). ApplyClickCastings sets this via button:SetAttribute("menu",
    -- attrKey) whenever a non-gated "menu" binding is applied (see
    -- WriteBinding/the bindType == "menu" branch below), so
    -- SecureUnitButtonTemplate's own click routing knows which attribute
    -- key represents "the menu trigger" for this button. It was never
    -- cleared here: if a binding was EVER "menu" for a given key (even a
    -- stock default before the user customized it), rebinding that key to
    -- something else later left this attribute pointing at the old key,
    -- and Blizzard's click handling kept honoring it regardless of what
    -- typeN/spellN were subsequently set to.
    button:SetAttribute("menu", nil)
end

-- Set a binding's attribute. Gated actions (target/menu with a modifier or
-- non-default button) route through the ungated proxy (see
-- GetActionProxy/RouteProxyAction above); everything else sets the native
-- attribute directly.
local function SetByGatedAction(button, attrKey, action, modifierAgnostic)
    local realAction = action
    if action == "menu" then realAction = "togglemenu" end

    if IsGatedAction(attrKey, realAction) then
        RouteProxyAction(button, attrKey, realAction, modifierAgnostic)
    else
        button:SetAttribute(attrKey, realAction)
    end
end

-- Write a single binding's attribute to a target frame (either a unit
-- button for mouse buttons, or a per-key global child for keyboard/wheel).
-- For keyboard/wheel (globalChild=true), the frame has no real unit token, so
-- every action that needs a unit target is written as macrotext with
-- [@mouseover] conditions.
-- For unit buttons (globalChild=false), write direct attributes -- the secure
-- engine uses the button's unit automatically.
local function WriteBinding(target, attrKey, bindType, action, globalChild)
    local function SetMacrotext(...)
        target:SetAttribute(attrKey, "macro")
        local macrotextKey = attrKey:gsub("type", "macrotext", 1)
        target:SetAttribute(macrotextKey, ...)
    end

    if bindType == "spell" then
        local spellId = tonumber(action)
        local spellName = spellId and F.GetSpellInfo(spellId) or action
        if spellName then
            local isRes = spellId and RESURRECTION_SPELLS[spellId]
            if globalChild then
                if isRes then
                    SetMacrotext("/stopmacro [nodead]\n/cast [@mouseover,dead,help] " .. spellName)
                else
                    SetMacrotext("/cast [@mouseover,exists] " .. spellName)
                end
            else
                -- Unit button has real unit token: use native spell type,
                -- UNLESS Smart Resurrection is enabled AND this is the
                -- unmodified Left-click binding AND the bound spell isn't
                -- itself already a res (nothing to smart-fallback to then).
                -- "Left click is always the smart key" per design -- other
                -- bindings are untouched.
                local smartSegments
                if attrKey == "type1" and not isRes then
                    local prof = GetProfile()
                    local mode = prof and prof.smartResurrection
                    if mode and mode ~= "disabled" then
                        smartSegments = BuildSmartResMacroSegments(mode)
                    end
                end

                if smartSegments and #smartSegments > 0 then
                    target:SetAttribute(attrKey, "macro")
                    local macrotextKey = attrKey:gsub("type", "macrotext", 1)
                    target:SetAttribute(macrotextKey,
                        "/cast [@mouseover,nodead] " .. spellName .. ";" .. table.concat(smartSegments, ";"))
                else
                    target:SetAttribute(attrKey, "spell")
                    local spellKey = attrKey:gsub("type", "spell", 1)
                    target:SetAttribute(spellKey, spellName)
                end
            end
        end
    elseif bindType == "macro" then
        if globalChild then
            SetMacrotext(action or "")
        else
            -- Unit button: native macro type
            target:SetAttribute(attrKey, "macro")
            local macrotextKey = attrKey:gsub("type", "macrotext", 1)
            target:SetAttribute(macrotextKey, action or "")
        end
    elseif bindType == "item" then
        local itemId = tonumber(action)
        if itemId then
            if globalChild then
                -- /use with [@mouseover] so items target the hovered unit.
                SetMacrotext("/use [@mouseover,exists] item:" .. itemId)
            else
                target:SetAttribute(attrKey, "item")
                local itemKey = attrKey:gsub("type", "item", 1)
                target:SetAttribute(itemKey, itemId)
            end
        end
    elseif bindType == "general" or bindType == "target" or bindType == "focus"
      or bindType == "assist" or bindType == "menu" then
        local actionName = bindType == "general" and action or bindType
        if globalChild then
            -- Convert to macrotext targeting @mouseover (child has no unit).
            if actionName == "target" then
                SetMacrotext("/target [@mouseover,exists]")
            elseif actionName == "focus" then
                SetMacrotext("/focus [@mouseover,exists]")
            elseif actionName == "assist" then
                SetMacrotext("/assist [@mouseover,exists]")
            elseif actionName == "menu" or actionName == "togglemenu" then
                -- NOTE: this branch is currently unreachable -- nothing passes
                -- globalChild = true any more. Left in place because the rest
                -- of the globalChild handling is still a coherent unit.
                --
                -- It also used to carry the claim that keyboard/wheel virtual
                -- clicks aren't gated. They are; see IsGatedAction. Anything
                -- reviving this path must route menu through the proxy rather
                -- than setting the attribute directly.
                target:SetAttribute(attrKey, "togglemenu")
            end
        else
            -- On a unit button with a real unit token, set the attribute
            -- directly so the secure engine uses the button's unit.
            target:SetAttribute(attrKey, actionName)
        end
    end
end

-- Apply all bindings from profile.clickCasting to a single button. BOTH mouse
-- and keyboard/wheel bindings are written directly onto the unit button here.
-- The per-button secure hover snippet (SetBindingClicks) then wires each
-- keyboard/wheel key to a virtual click on this button so the bound action
-- fires on the unit the button represents.
local function ApplyClickCastings(button)
    if not button then return end
    ClearClickCastings(button)

    local prof = GetProfile()
    local bindings = prof and prof.clickCasting
    if not bindings or #bindings == 0 then return end

    for idx, b in ipairs(bindings) do
        -- Skip invalid bindings (nil bindKey, etc.)
        if not b.bindKey or b.bindKey == "" then
            -- Optionally log this for debugging
            -- print("|cffff0009[SquizzFrames]|r Skipping invalid click-casting binding: missing bindKey")
        else
            local attrKey = GetAttributeKey(b.modifier, b.bindKey)
            local bindType = b.type
            local action = b.action

            -- Mouse-button binding. target/menu are gated on the unit button
            -- (12.0.7 click gate), so route those through the proxy; everything
            -- else (spells, macros, items, focus, assist) is written directly.
            -- UNCHANGED (2026-08-06) -- do not touch: confirmed working,
            -- including with modifiers, for Left/Right/Middle.
            if not attrKey:match("type%-") then
                if bindType == "general" and (action == "target" or action == "menu") then
                    local isGated = IsGatedAction(attrKey, action)
                    SetByGatedAction(button, attrKey, action)
                    -- Only set menu attribute for NON-gated menu actions.
                    -- Gated actions use macrotext which works in combat too.
                    if action == "menu" and not isGated then
                        button:SetAttribute("menu", attrKey)
                    end
                elseif bindType == "target" or bindType == "menu" then
                    local isGated = IsGatedAction(attrKey, bindType)
                    SetByGatedAction(button, attrKey, bindType)
                    if bindType == "menu" and not isGated then
                        button:SetAttribute("menu", attrKey)
                    end
                else
                    WriteBinding(button, attrKey, bindType, action)
                end
            else
                -- Keyboard / wheel binding (2026-08-06 rewrite -- see
                -- GetBindingSnippet's comment for the full "why"). Uses a
                -- PLAIN, modifier-independent attribute suffix ("kb"..idx,
                -- unique per binding row) instead of the modifier-prefixed
                -- attrKey computed above (e.g. "shift-type-E") -- confirmed
                -- via a live user report that modified keyboard/wheel binds
                -- never fired (100% reproducible, every spell, no
                -- conflicting Blizzard keybind) while unmodified ones and
                -- ALL mouse-button binds (incl. modified Left/Right/Middle)
                -- worked fine. Cross-checked against EllesmereUIRaidFrames'
                -- own click-cast module (EUI_RaidFrames_ClickCast.lua's
                -- SetKeyAttr/suffix = "eui_"..idx), which uses this exact
                -- same plain-suffix-per-binding pattern for keyboard binds
                -- and never relies on a modifier-prefixed attribute for
                -- them -- only the PHYSICAL key passed to SetBindingClick
                -- (GetBindingSnippet) carries the modifier. attrKey is still
                -- computed above and used to detect mouse-button vs
                -- keyboard/wheel (the classification itself is unaffected).
                local plainAttrKey = "type-kb" .. idx
                button.squizzKeyboardAttrs = button.squizzKeyboardAttrs or {}
                tinsert(button.squizzKeyboardAttrs, plainAttrKey)

                -- target/menu need the SAME proxy the mouse branch uses.
                -- Writing them straight onto the unit button (what this did
                -- until 2026-08-14) can't work: SecureUnitButton_OnClick gates
                -- those three action types on C_ClickBindings.GetBindingType
                -- of the clicked button name, and our virtual click's name is
                -- one we invented, so the answer is always None and the gate
                -- always shuts. See IsGatedAction for the quoted source.
                --
                -- The proxy is a plain SecureActionButton, not a unit button,
                -- so SecureUnitButton_OnClick -- and therefore the gate -- is
                -- never in the path at all.
                local kbAction = (bindType == "general") and action or bindType
                if kbAction == "target" or kbAction == "menu" or kbAction == "togglemenu" then
                    SetByGatedAction(button, plainAttrKey, kbAction, true)
                    -- Deliberately NOT setting button:SetAttribute("menu", ...)
                    -- here, unlike the mouse branch: that attribute names the
                    -- click the DEFAULT unit-menu path should answer to, and
                    -- this binding never travels that path.
                else
                    WriteBinding(button, plainAttrKey, bindType, action, false)
                end
            end
        end
    end
end

-----------------------------------------------------------------------
-- Secure hover snippets + combat-state driver
-----------------------------------------------------------------------
-- Mouse-button bindings (type1..type5) are written directly to each unit
-- button. Keyboard/wheel bindings are ALSO written onto the unit button
-- (as type-<key> / macrotext-<key> attributes). The secure hover snippet
-- maps each bound keyboard/wheel key to a virtual click on the button with
-- button name = <key>, so the engine reads type-<key>. This is Cell's
-- approach: the binding fires on whichever unit button you're hovering.

local wrapFrame  -- SecureHandlerStateTemplate, created lazily

-- Build the SetBindingClick snippet for keyboard/wheel bindings. Each line
-- maps a physical key (modifier included, e.g. "SHIFT-E"/"MOUSEWHEELUP") to
-- a virtual click on the button that the snippet is wrapping, using a
-- PLAIN, modifier-independent virtual click name unique per binding row
-- ("kb"..idx -- must match ApplyClickCastings' own "type-kb"..idx exactly).
--
-- 2026-08-06 rewrite: previously used the bare key (e.g. "E") as the
-- virtual click name for EVERY modifier variant of that key, relying on
-- WoW's secure engine to re-derive the modifier-prefixed attribute
-- (shift-type-E vs type-E) from live modifier state AT the moment a
-- SIMULATED/virtual click fires. Confirmed via a live user report this
-- does NOT happen reliably for virtual clicks the way it does for a REAL
-- mouse click (100% reproducible across every spell/modifier on keyboard
-- and wheel binds specifically, while modified Left/Right/Middle clicks --
-- real physical clicks, going through ApplyClickCastings' untouched
-- mouse-button branch -- all worked correctly, and no conflicting Blizzard
-- keybind was involved). Cross-checked against EllesmereUIRaidFrames' own
-- working click-cast module, which never relies on that re-derivation
-- either -- it uses a plain per-binding-index suffix
-- (EUI_RaidFrames_ClickCast.lua's SetKeyAttr, suffix = "eui_"..idx) for
-- exactly this reason. The 3rd arg (self) tells the secure engine WHICH
-- button's attributes to resolve the action from -- without it the binding
-- doesn't route to the unit button and the action bar wins.
local function GetBindingSnippet()
    local prof = GetProfile()
    local bindings = prof and prof.clickCasting
    if not bindings then return "" end
    local lines = {}
    for idx, b in ipairs(bindings) do
        -- Skip invalid bindings (nil bindKey, etc.)
        if b.bindKey and b.bindKey ~= "" then
            local attrKey = GetAttributeKey(b.modifier, b.bindKey)
            local modifier, key = strmatch(attrKey, "^(.*)type%-(.+)$")
            if key then
                local m = (modifier or ""):upper()
                local phys
                if key == "SCROLLUP" then phys = "MOUSEWHEELUP"
                elseif key == "SCROLLDOWN" then phys = "MOUSEWHEELDOWN"
                else phys = key
                end
                local physKey = m .. phys
                local suffix = "kb" .. idx
                lines[#lines + 1] = [[self:SetBindingClick(true, "]] .. physKey .. [[", self, "]] .. suffix .. [[")]]
            end
        end
    end
    return table.concat(lines, "\n")
end

-- Install secure hover snippets on a unit button. Called from
-- UnitButton.lua's OnLoad and re-run whenever bindings change.
--
-- Uses the button's "_onenter" / "_onleave" / "_onmousedown" secure
-- attributes (from SecureHandlerEnterLeaveTemplate etc.) so the binding
-- snippet runs on every hover. This requires that no insecure SetScript
-- OnEnter / OnLeave handler is set on the button — XML <OnEnter> or
-- SetScript("OnEnter") replaces the secure wrap and silently drops
-- "_onenter". The tooltip logic must use HookScript instead, which adds
-- a handler alongside the secure wrap. (This is Cell's approach.)
function ClickCasting.SetBindingClicks(button)
    if not button then return end
    button:SetAttribute("snippet", GetBindingSnippet())
    button:SetAttribute("_onenter", [[
        self:ClearBindings()
        self:Run(self:GetAttribute("snippet"))
        local menuKey = self:GetAttribute("menu")
        if menuKey then
            if PlayerInCombat() then
                self:SetAttribute(menuKey, nil)
            else
                self:SetAttribute(menuKey, "togglemenu")
            end
        end
    ]])
    button:SetAttribute("_onleave", [[
        self:ClearBindings()
    ]])
    button:SetAttribute("_onmousedown", [[
        self:ClearBindings()
        self:Run(self:GetAttribute("snippet"))
    ]])
end

-- Combat-state driver: toggles the menu key between nil (in combat) and
-- "togglemenu" (out of combat) on the currently-hovered button. This is
-- Cell's "togglemenu_nocombat" behavior.
local function EnsureWrapFrame()
    if wrapFrame then return wrapFrame end
    wrapFrame = CreateFrame("Frame", "SquizzWrapFrame", nil, "SecureHandlerStateTemplate")
    wrapFrame:SetAttribute("_onstate-combatstate", [[
        if mouseoverbutton then
            local menuKey = mouseoverbutton:GetAttribute("menu")
            if menuKey then
                if newstate == "true" then
                    mouseoverbutton:SetAttribute(menuKey, nil)
                else
                    mouseoverbutton:SetAttribute(menuKey, "togglemenu")
                end
            end
        end
    ]])
    RegisterStateDriver(wrapFrame, "combatstate", "[combat] true; false")
    return wrapFrame
end

-----------------------------------------------------------------------
-- Apply to all buttons
-----------------------------------------------------------------------

-- Collect all buttons from the secure header.
-----------------------------------------------------------------------
-- Blizzard unit frames (click-casting on frames we don't own)
-----------------------------------------------------------------------
-- Units with no SquizzFrames frame of their own -- bosses above all, but also
-- your own player frame, target, focus and their target-of-targets. All of
-- these are real global Buttons inheriting SecureUnitButtonTemplate, so they
-- accept exactly the same type1/spell1/macrotext1 attribute writes our own
-- buttons do, and SecureUnitButton_OnClick dispatches them identically.
--
-- Boss frames are included unconditionally rather than created on demand:
-- Boss1TargetFrame..Boss5TargetFrame are defined up front in Blizzard's
-- TargetFrame.xml and merely shown/hidden per encounter, so they can be
-- configured out of combat long before a pull. Arena frames are deliberately
-- NOT here -- those are created lazily when an arena loads, so they'd need
-- their own creation hook rather than a static name lookup.
local BLIZZARD_FRAME_NAMES = {
    "PlayerFrame",
    "PetFrame",
    "TargetFrame",
    "TargetFrameToT",
    "FocusFrame",
    "FocusFrameToT",
    "Boss1TargetFrame",
    "Boss2TargetFrame",
    "Boss3TargetFrame",
    "Boss4TargetFrame",
    "Boss5TargetFrame",
}

-- EllesmereUI (EllesmereUIRaidFrames) exposes every frame under a stable
-- global name, so it needs no cooperation from that addon and is a complete
-- no-op when it isn't installed.
--
-- Its group frames live under SecureGroupHeaderTemplate headers configured
-- with template="SecureUnitButtonTemplate" -- the same arrangement as our own
-- party header -- so the buttons are reached by walking the header's children
-- rather than by name. Its standalone frames ARE individually named.
local ELLESMERE_HEADER_NAMES = {
    "ERFPartyHeader",
    "ERFFlatHeader",      -- raid, "merge groups" mode
    "ERFGroupHeader1", "ERFGroupHeader2", "ERFGroupHeader3", "ERFGroupHeader4",
    "ERFGroupHeader5", "ERFGroupHeader6", "ERFGroupHeader7", "ERFGroupHeader8",
}
local ELLESMERE_FRAME_NAMES = {
    -- EllesmereUIRaidFrames (party/raid).
    "ERFPartySelfButton",
    "ERFFriendlyBoss1", "ERFFriendlyBoss2", "ERFFriendlyBoss3",
    "ERFFriendlyBoss4", "ERFFriendlyBoss5",
    -- EllesmereUIUnitFrames (player/target/focus/pet/boss). A SEPARATE addon
    -- from the raid frames above, with its own naming.
    --
    -- These are NOT reskins of Blizzard's frames -- EllesmereUIUnitFrames
    -- actively disables and reparents PlayerFrame/TargetFrame/FocusFrame/
    -- PetFrame and the whole BossTargetFrameContainer (its ns.UF_HideBlizzard),
    -- then spawns its own secure unit buttons. So covering Blizzard's globals
    -- does nothing for anyone running it: the frames on screen are these, and
    -- the Blizzard ones are hidden (user report 2026-08-13, "click castings
    -- are not working on ellesmeres target or player frame").
    "EllesmereUIUnitFrames_Player",
    "EllesmereUIUnitFrames_Pet",
    "EllesmereUIUnitFrames_Target",
    "EllesmereUIUnitFrames_TargetTarget",
    "EllesmereUIUnitFrames_Focus",
    "EllesmereUIUnitFrames_FocusTarget",
    "EllesmereUIUnitFrames_Boss1", "EllesmereUIUnitFrames_Boss2",
    "EllesmereUIUnitFrames_Boss3", "EllesmereUIUnitFrames_Boss4",
    "EllesmereUIUnitFrames_Boss5",
}
-- ERFExtraFrameN is created on demand and its count is user-configurable
-- (minimum 5, no fixed maximum), so it's probed rather than listed. Stops at
-- the first gap, which is safe because they're created contiguously.
local ELLESMERE_EXTRA_FRAME_MAX = 40

-- A frame is only usable if it can take secure attributes AND actually
-- resolves to a unit -- writing spell1 onto something with no "unit"
-- attribute produces a binding that silently does nothing. Re-checked on
-- every apply rather than cached: a frame can gain its unit attribute after
-- login, and another addon may have replaced the global entirely.
local function IsUsableExternalFrame(frame)
    if type(frame) ~= "table" then return false end
    if type(frame.SetAttribute) ~= "function" then return false end
    if type(frame.GetAttribute) ~= "function" then return false end
    local ok, unit = pcall(frame.GetAttribute, frame, "unit")
    return ok and unit ~= nil
end

local externalWrapped = {}

-- Install the hover snippet on a frame we don't own.
--
-- Our own buttons inherit SecureHandlerEnterLeaveTemplate, which is what makes
-- the "_onenter"/"_onleave" ATTRIBUTES that SetBindingClicks writes actually
-- run. Blizzard's unit frames do NOT: SecureUnitButtonTemplate inherits only
-- SecureFrameTemplate (checked against Blizzard's SecureTemplates.xml), so
-- those attributes would sit there inert and every keyboard/mouse-wheel
-- binding would silently do nothing on these frames while mouse buttons
-- worked fine -- a confusing half-working state.
--
-- SecureHandlerWrapScript installs the same wrapper at runtime on any frame,
-- which is how Cell and DandersFrames drive their own foreign-frame bindings.
-- Wrapped exactly once per frame (wrapping is additive -- calling it twice
-- stacks a second copy of the snippet on every mouse-over).
local function WrapExternalHover(frame)
    if externalWrapped[frame] then return end
    if type(SecureHandlerWrapScript) ~= "function" then return end
    -- Marked BEFORE wrapping, and never retried on failure. Wrapping is
    -- additive, so a retry after a partial failure would stack a duplicate
    -- OnEnter snippet that runs on every single mouseover, forever.
    externalWrapped[frame] = true
    -- pcall'd individually: this runs deep inside ApplyToAll, which is called
    -- from module init paths (PetFrames' init, among others). An error here
    -- doesn't just skip the wrap -- it unwinds the whole caller. That is
    -- exactly what an unsupported script type did on first attempt: it took
    -- out PetFrames' initialisation as collateral.
    local function Wrap(script, body)
        pcall(SecureHandlerWrapScript, frame, script, frame, body)
    end
    -- Bodies are kept IDENTICAL to the _onenter/_onleave attributes
    -- SetBindingClicks writes -- `self` is the frame in both cases,
    -- so the snippet text carries over verbatim. That includes the menu key's
    -- in-combat suppression: without it, right-click-to-open-menu would behave
    -- differently on a boss frame than on a party frame, which is exactly the
    -- kind of inconsistency that gets reported as "click-casting is flaky".
    Wrap("OnEnter", [[
        self:ClearBindings()
        self:Run(self:GetAttribute("snippet"))
        local menuKey = self:GetAttribute("menu")
        if menuKey then
            if PlayerInCombat() then
                self:SetAttribute(menuKey, nil)
            else
                self:SetAttribute(menuKey, "togglemenu")
            end
        end
    ]])
    Wrap("OnLeave", [[
        self:ClearBindings()
    ]])
    -- NO OnMouseDown COUNTERPART. SetBindingClicks installs an "_onmousedown"
    -- attribute on our own buttons (a re-run of the snippet), but
    -- SecureHandlerWrapScript's supported script list is fixed and does not
    -- include OnMouseDown -- it hard-errors with "Unsupported script type"
    -- (checked against LOCAL_Wrap_Handlers in Blizzard's SecureHandlers.lua:
    -- OnClick, OnDoubleClick, PreClick, PostClick, OnEnter, OnLeave, OnShow,
    -- OnHide, OnDragStart, OnReceiveDrag, OnMouseWheel, OnAttributeChanged).
    --
    -- Dropped rather than approximated: OnEnter already installs the bindings
    -- on hover, which is what actually makes keyboard and wheel binds work.
    -- PreClick is the nearest supported hook if a gap ever shows up here.
end

-- Walk a SecureGroupHeaderTemplate's children. ipairs(header) is how our own
-- CollectButtons reads our party header, but a foreign header may not expose
-- its children as an array part, so the "childN" attributes -- which the
-- header maintains itself, and which are the documented contract -- are used
-- as the fallback.
local function CollectHeaderChildren(header, out)
    if type(header) ~= "table" then return end
    local found = false
    for _, child in ipairs(header) do
        if IsUsableExternalFrame(child) then
            tinsert(out, child)
            found = true
        end
    end
    if found or type(header.GetAttribute) ~= "function" then return end
    for i = 1, 40 do
        local ok, child = pcall(header.GetAttribute, header, "child" .. i)
        if not ok or not child then break end
        if IsUsableExternalFrame(child) then tinsert(out, child) end
    end
end

function ClickCasting.CollectBlizzardFrames()
    local frames = {}
    local prof = GetProfile()
    if not prof or prof.clickCastBlizzardFrames == false then return frames end

    for _, name in ipairs(BLIZZARD_FRAME_NAMES) do
        local frame = _G[name]
        if IsUsableExternalFrame(frame) then
            tinsert(frames, frame)
        end
    end

    -- EllesmereUI. Every lookup below is a plain global read, so this whole
    -- block costs nothing and adds nothing when that addon isn't loaded.
    for _, name in ipairs(ELLESMERE_FRAME_NAMES) do
        local frame = _G[name]
        if IsUsableExternalFrame(frame) then
            tinsert(frames, frame)
        end
    end
    for i = 1, ELLESMERE_EXTRA_FRAME_MAX do
        local frame = _G["ERFExtraFrame" .. i]
        if not frame then break end
        if IsUsableExternalFrame(frame) then tinsert(frames, frame) end
    end
    for _, name in ipairs(ELLESMERE_HEADER_NAMES) do
        CollectHeaderChildren(_G[name], frames)
    end

    return frames
end

local function CollectButtons()
    local buttons = {}
    for _, h in ipairs(headerFrames) do
        for _, button in ipairs(h) do
            if button then
                tinsert(buttons, button)
            end
        end
    end
    -- Pet buttons (2026-08-05): not header children (PetFrames.lua creates
    -- them individually, not via a SecureGroupHeaderTemplate -- see that
    -- file's own comment for why), so they're pulled in separately via the
    -- same IterateButtons accessor pattern PartyFrames.lua exposes.
    local PetFrames = SquizzFrames.modules and SquizzFrames.modules["PetFrames"]
    if PetFrames and PetFrames.IterateButtons then
        PetFrames:IterateButtons(function(button)
            tinsert(buttons, button)
        end)
    end
    return buttons
end

function ClickCasting:ApplyToAll()
    if InCombatLockdown() then
        -- Can't modify secure attributes in combat; defer until we're out.
        local self2 = self
        C_Timer.After(0.5, function() self2:ApplyToAll() end)
        return
    end
    -- Ensure the combat-state driver exists (creates the wrapFrame).
    EnsureWrapFrame()

    -- Blizzard's own unit frames, when enabled. Handled before the loop below
    -- so they get the identical binding treatment, differing only in how the
    -- hover snippet is installed (see WrapExternalHover) and in needing
    -- RegisterForClicks: Blizzard registers those frames for LeftButtonUp/
    -- RightButtonUp only, so Middle/Button4/Button5 bindings would never fire
    -- on them otherwise. "AnyUp" matches what WireUpButton does for our own
    -- buttons, and is only reachable out of combat (guarded above).
    local external = ClickCasting.CollectBlizzardFrames()
    for _, frame in ipairs(external) do
        WrapExternalHover(frame)
        if frame.RegisterForClicks then
            pcall(frame.RegisterForClicks, frame, "AnyUp")
        end
    end

    local buttons = CollectButtons()
    for _, frame in ipairs(external) do
        tinsert(buttons, frame)
    end

    for _, button in ipairs(buttons) do
        -- Install/refresh the secure hover snippets (keyboard/wheel binds
        -- via SetBindingClick on enter) then apply the binding attributes.
        -- Both mouse-button and keyboard/wheel binds go on the unit button.
        self.SetBindingClicks(button)
        ApplyClickCastings(button)
    end
end

-----------------------------------------------------------------------
-- Ace3 lifecycle
-----------------------------------------------------------------------

function ClickCasting:OnInitialize()
    -- When PartyFrames finishes wiring buttons, apply our bindings.
    self:RegisterMessage("PartyButtonsWired", function(_, header)
        if type(header) == "table" then
            local known = false
            for _, h in ipairs(headerFrames) do
                if h == header then known = true break end
            end
            if not known then tinsert(headerFrames, header) end
        end
        -- Defer slightly so the header has valid rects, and coalesce: raid
        -- fires this eight times in a row (once per subgroup header) and
        -- ApplyToAll already rewrites every button we know about, so eight
        -- passes would do the same work eight times.
        if not applyPending then
            applyPending = true
            C_Timer.After(0, function()
                applyPending = false
                self:ApplyToAll()
            end)
        end
    end)

    -- Re-apply when layout/profile changes (button list may have changed)
    self:RegisterMessage("LayoutChanged", function()
        C_Timer.After(0, function() self:ApplyToAll() end)
    end)
    self:RegisterMessage("ProfileChanged", function()
        C_Timer.After(0, function() self:ApplyToAll() end)
    end)

    -- On login / reload / zoning the secure header may not have valid
    -- children at the moment PartyButtonsWired first fires, or the buttons
    -- may not yet be clickable. Re-apply at increasing delays so bindings
    -- land even on the slowest first-login frames. Without this, click-
    -- casting appears "dead" until the user clicks once.
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        C_Timer.After(0.5, function() self:ApplyToAll() end)
        C_Timer.After(1.5, function() self:ApplyToAll() end)
        C_Timer.After(3.0, function() self:ApplyToAll() end)
    end)

    -- Re-apply when leaving combat in case a deferred apply was blocked by
    -- InCombatLockdown during the initial spawn.
    self:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        self:ApplyToAll()
    end)

    -- Roster changes, for the FOREIGN frames specifically. Our own buttons are
    -- already covered by PartyButtonsWired above, but another addon's frames
    -- are created and re-assigned on its schedule, not ours -- a raid growing
    -- spawns new EllesmereUI header children that have never seen our
    -- bindings. PartyButtonsWired usually covers this too, but only while our
    -- own party frames are actually running; this keeps foreign frames correct
    -- even for someone using SquizzFrames purely as a click-casting layer.
    -- Delayed so the owning addon has finished creating them first.
    self:RegisterEvent("GROUP_ROSTER_UPDATE", function()
        C_Timer.After(0.5, function() self:ApplyToAll() end)
    end)
end

function ClickCasting:OnEnable()
    -- If PartyFrames already fired before we loaded, apply now.
    if headerFrames[1] then
        self:ApplyToAll()
    end
end

-----------------------------------------------------------------------
-- Public API (used by the options panel)
-----------------------------------------------------------------------

-- Add a binding and re-apply.
function ClickCasting:AddBinding(bindKey, modifier, bindType, action)
    local prof = GetProfile()
    if not prof then return end
    prof.clickCasting = prof.clickCasting or {}
    tinsert(prof.clickCasting, {
        bindKey = bindKey,
        modifier = modifier or "",
        type = bindType,
        action = action,
    })
    self:ApplyToAll()
end

-- Remove a binding by index and re-apply.
function ClickCasting:RemoveBinding(index)
    local prof = GetProfile()
    if not prof or not prof.clickCasting then return end
    if prof.clickCasting[index] then
        tremove(prof.clickCasting, index)
        self:ApplyToAll()
    end
end

-- Update a binding by index and re-apply.
function ClickCasting:UpdateBinding(index, bindKey, modifier, bindType, action)
    local prof = GetProfile()
    if not prof or not prof.clickCasting or not prof.clickCasting[index] then return end
    prof.clickCasting[index] = {
        bindKey = bindKey,
        modifier = modifier or "",
        type = bindType,
        action = action,
    }
    self:ApplyToAll()
end

-- Get the full binding list (for the options panel).
function ClickCasting:GetBindings()
    local prof = GetProfile()
    return prof and prof.clickCasting or {}
end