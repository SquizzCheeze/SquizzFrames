# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**SquizzFrames** is a World of Warcraft (Mainline/Retail, API 12.1) unit frame addon. It began as party frames and now also covers raid frames, pet frames, standalone unit frames (player/target/ToT/focus/focustarget/boss), a resource bar, a tank tracker and nicknames. It uses the **Ace3** framework and follows patterns from **DandersFrames** and **EllesmereUI** for secure frame handling, indicator systems and click-casting.

⚠️ **Do not use Cell as a reference.** It is cited historically throughout this file for the shape of the indicator system, which is still accurate, but its code is outdated for 12.1 and following it will lead you wrong on anything aura-related. Prefer, in order: Blizzard's own source (`Gethe/wow-ui-source` — **check the branch**, `ptr` and `ptr2` are different patches), then DandersFrames, then EllesmereUI.

- **AddOn Name**: SquizzFrames
- **SavedVariables**: `SquizzFramesDB` (AceDB-3.0 profiles)
- **Slash Command**: `/sf` ( `/squizz` is taken by Squizzumables)
- **Key Bindings**: Click-casting via secure attributes
- **Runtime 12.1 branch**: the addon ships on 12.1 and runs its feature-flagged 12.1 AuraContainer code path (`SquizzFrames.IS_121`); the legacy pre-12.1 path is still present but unreachable — see [12.1 AuraEngine Subsystem](#7-121-auraengine-subsystem-auraenginelua-auraengineindicatorslua) below before touching anything aura-related.

---

## Architecture

### Core Structure

```
SquizzFrames/
├── Core.lua                 # Addon bootstrap, Ace3 lifecycle, DB, module registry
├── Utils.lua                # Shared helpers (colors, numbers, spells, click-cast spells, SquizzFrames.IS_121 build-gate flag)
├── SquizzFrames.toc         # Load order: Libs → Core → Utils → Defaults → Media → HideBlizzard → Options → Modules → Compat
├── Libs/                    # Embedded libraries (Ace3, LibSharedMedia, LibCustomGlow, LibDeflate, LibSerialize, LibRangeCheck)
├── Media/                   # Fonts, textures, icons, flipbooks
├── Defaults/                # Layout, Appearance, Indicator, ClickCasting defaults (DB-side data)
├── Locales/                 # enUS.lua (AceLocale-3.0)
├── Compat/
│   └── BlizziCompat.lua     # Optional integration: registers SquizzFrames with BliZzi_Interrupts' unit-frame resolver
├── HideBlizzard.lua         # One master switch (general.hideBlizzardFrames) hiding every Blizzard frame we replace, gated per-frame on ours being enabled
└── Modules/
    ├── LoadModules.xml      # Loads PartyFrames, Indicators (incl. AuraEngine), ClickCasting, Options
    ├── PartyFrames/         # Secure group header + unit buttons (party1-4 + player)
    │   ├── PartyFrames.lua  # Layout, anchoring, growth, edit mode, sizing
    │   ├── LayoutPanel.lua  # The "layout" options page; split out of OptionsFrame 2026-09-10 (publishes IsRaidTab for the shared group preview)
    │   ├── UnitButton.lua   # Secure button OnLoad, click-casting hooks
    │   └── UnitButton.xml   # SecureUnitButtonTemplate + health/power bars, texts, icons
    ├── Indicators/          # Cell-style indicator system (built-in + custom) + 12.1 AuraEngine
    │   ├── Indicators.lua        # Registry, runtime, ApplySettingToOne, preview, built-in-vs-AuraEngine dispatch
    │   ├── AuraEngine.lua         # 12.1 ONLY: shared AuraContainer/AddAuraGroup/AddAuraSlot engine (styles, combat-safe container creation, restyle scheduler)
    │   ├── AuraEngineIndicators.lua # 12.1 ONLY: healerHots/externalCooldowns/defensiveCooldowns/debuffs/ccIndicator/dispels + custom color/bar, built on AuraEngine
    │   ├── AuraButtonTemplate.xml # Empty virtual "CustomAuraButtonTemplate" — must exist by this exact name for AuraContainer buttons to create at all
    │   ├── BuiltIn_Update.lua    # Legacy built-in update functions (healthText, manual aura scan for debuffs/dispels/etc — still the pre-12.1 fallback)
    │   ├── IndicatorDefaults.lua  # Module-side re-export accessor for Defaults/Indicator_Defaults.lua (NOT the same file — see Data Structures)
    │   ├── IndicatorWidgets.lua   # Custom indicator frame factories (legacy scan-based) + shared setting widgets
    │   ├── Custom_Dispatch.lua    # Legacy aura scanner + per-type dispatch (still used for trackByName customs, text/icon customs, and all customs pre-12.1)
    │   └── IndicatorsPanel.lua    # Options UI for indicators
    ├── Welcome/            # First-run greeting + per-version release notes; RELEASE_NOTES table is a manual per-release step (see Releasing)
    ├── TankTracker/         # Per-tank frame: incoming debuffs above, defensives below; own AuraEngine rows, plain (non-secure) frames. Debuff filter defaults to the duration-bounded `encounter` preset, NOT the boss/role flags — see section 7 on why flag presets render empty rows in untagged encounters
    │   ├── TankTracker.lua      # Engine: tank discovery (secret-safe, fail-closed on identity), stacking, aura rows, mover
    │   ├── TankTrackerPreview.lua # 1:1 options mock; IS a real tank frame (CreateTankFrame/DressFrame/PlaceRow/StyleFields), only the icons are static
    │   └── TankTrackerPanel.lua # Options page ("tankTracker" nav entry); General/Debuffs/Defensives sub-tabs + pinned preview; shell over profile.tankTracker
    ├── Nicknames/           # Display-name replacement (private list + group-synced)
    │   ├── Nicknames.lua       # Storage, secret-safe resolution cache, AceComm-free addon-message sync, /sf nick
    │   └── NicknamesPanel.lua  # Options page ("nicknames" nav entry); pure shell over the module's public API
    ├── UnitFrames/          # Standalone single-unit frames (player/target/ToT/focus/focustarget/boss) — cast bars, portraits, auras, icons and absorbs all present; arena still to come
    │   ├── UnitFrames.lua      # Engine: fixed-token frames, health/power/4 text elements (name/health/power/level), movers, derived-unit poll
    │   ├── CastBar.lua         # Per-frame cast bar; loaded BEFORE UnitFrames.lua, which reads SquizzFrames.UnitFrameCastBar. Border via CastBar.ApplyBorder (BU.CreateBorderIndicator, created on first use, shared with Preview.lua)
    │   ├── Portrait.lua        # 2D/3D portraits
    │   ├── Auras.lua           # Buff/debuff rows on AuraEngine; style keys are PER UNIT AND KIND (see AE.styles namespacing below)
    │   ├── Icons.lua           # Combat + leader state icons (anchor/offset/size/tint), secret-safe booleans
    │   ├── Absorbs.lua         # Shield + heal-absorb health-bar overlays; values go straight to SetValue, never touched in Lua
    │   ├── Highlights.lua     # Hover/target/aggro borders; borrows BuiltIn_Update's factory + Check functions, own per-frame settings, renders in the preview
    │   ├── Dispels.lua        # Dispel overlay AND the separate dispel-icons indicator; REUSES the party AEI factories with a translated settings table (see AE.styles namespacing below)
    │   ├── ResourceBar.lua     # Standalone movable player power bar + secondary-resource point row, one bar or two separately placed frames (detachPoints/pointsLayout; the rows may attach to each other but never both ways); point styles bars / shape masks (Media/Shapes, generated by .tools/make-shapes.ps1) / Blizzard class atlases, plus rainbow colours and per-point borders (pixel edges on bars, `<shape>-border<1-4>.png` ring images on shapes); NOT gated on unitFrames.enabled
    │   ├── Preview.lua         # The options page's 1:1 mock frame — renders through the REAL formatters/painters, never a second copy of them
    │   ├── UnitFrameButton.xml # SquizzFramesUnitFrameTemplate
    │   └── UnitFramesPanel.lua # Options page ("unitFrames" nav entry); shell over profile.unitFrames
    ├── PetFrames/           # Party/raid pet frames (attached to the owner's button, or a free-floating group), plus the standalone player's-own-pet frame
    │   └── PetFramesPanel.lua  # Options page ("petFrames" nav entry); split out of OptionsFrame 2026-09-10 to escape its Lua ceilings
    │   ├── PetFrames.lua       # Layout/anchoring/edit mode, roster + unit events, RefreshBorders
    │   └── PetButton.lua       # Secure pet button OnLoad + PetButton_ApplyBorders
    ├── ClickCasting/        # Cell-style click-casting on SecureActionButtonTemplate
    │   ├── ClickCasting.lua   # Binding parser, attribute writer, proxy for 12.0.7 click-gate + separate 12.1 macro-transport proxy
    │   └── ClickCastingPanel.lua # Options UI
    └── Options/
        ├── Options.lua      # AceConfig fallback table (for /sf)
        ├── OptionsFrame.lua # Custom options panel (tabbed: General, Layout, Appearance, Click Casting, Indicators)
        └── Widgets.lua      # Custom styled widgets (sliders, dropdowns, checkboxes, buttons)
```

### Load Order (from `.toc`)

1. **Libs/LoadLibs.xml** — LibStub → CallbackHandler → Ace3 (Addon, Event, Timer, DB, Config, Hook, Comm, Console, Locale, GUI) → LibSharedMedia, LibCustomGlow, LibRangeCheck, LibDeflate, LibSerialize
2. **Locales/LoadLocales.xml** — enUS
3. **Core.lua** — Addon object, DB, module registry, slash commands
4. **Utils.lua** — Shared helpers, sets `SquizzFrames.IS_121`
5. **Defaults/LoadDefaults.xml** — Layout, Appearance, Indicator, ClickCasting defaults
6. **Media/LoadMedia.xml** — Fonts, textures
7. **HideBlizzard.lua** — Hide default frames
8. **Modules/Options/Options.lua** — AceConfig table (fallback)
9. **Modules/Options/Widgets.lua** — Custom widgets
10. **Modules/Options/OptionsFrame.lua** — Custom options panel
11. **Modules/LoadModules.xml** — Loads PartyFrames, Indicators (`Indicators.lua` → `IndicatorDefaults.lua` → `AuraEngine.lua` → `AuraEngineIndicators.lua` → `BuiltIn_Update.lua` → `Custom_Dispatch.lua` → `IndicatorWidgets.lua` → `IndicatorsPanel.lua`), ClickCasting modules, Nicknames (after Indicators — it refreshes names through `nameText`'s `_sfNameUpdater`)
12. **Compat/BlizziCompat.lua** — Optional third-party integration, patches itself in on `PLAYER_LOGIN` if `BliZzi_Interrupts` is present

---

## Key Architectural Patterns

### 1. Module System (AceAddon-3.0)
```lua
-- In Core.lua
local SquizzFrames = LibStub("AceAddon-3.0"):NewAddon("SquizzFrames", "AceEvent-3.0", "AceTimer-3.0", "AceHook-3.0", "AceComm-3.0", "AceConsole-3.0")
_G["SquizzFrames"] = SquizzFrames

-- Modules register via:
local MyModule = SquizzFrames:NewModule("ModuleName", "AceEvent-3.0")

-- Cross-module messaging (CallbackHandler):
SquizzFrames:Fire("MessageName", arg1, arg2)  -- broadcasts to ALL modules registered for it
self:RegisterMessage("MessageName", function(_, arg1, arg2) ... end)
```
**Critical**: Each module registers messages on **itself** (`self:RegisterMessage`), NOT on the addon root. Otherwise multiple modules listening to the same message would collide (same `self` = SquizzFrames).

### 2. Secure Frames & Combat Lockdown
- Unit buttons use `SecureUnitButtonTemplate` + `SecureGroupHeaderTemplate`
- **All secure attribute changes** (layout, click-casting, indicators on secure frames) must happen **out of combat**
- `InCombatLockdown()` guards + `C_Timer.After(0.5, retry)` pattern throughout
- `PLAYER_REGEN_ENABLED` used to flush deferred work
- 12.1 AuraEngine has its own parallel combat-safe patterns: `AE.RequestContainer` queues container creation until `PLAYER_REGEN_ENABLED` (container creation itself hard-errors in combat by Blizzard design), and `AE.RestyleSoon`'s time-sliced restyler simply stops ticking (not errors) while `InCombatLockdown()` and resumes on its own after combat

### 3. Layout System (PartyFrames.lua)
- **Single container** (`SquizzFramesPartyFrame`) anchored `CENTER→CENTER` to `UIParent` with saved `anchorX/anchorY` (pixels from screen center, scaled by UI scale)
- **Secure header** (`SquizzFramesPartyHeader`) anchored `CENTER→CENTER` inside container — drives **party/solo only**
- **Raid uses eight headers instead**, `SquizzFramesRaidGroupHeader1..8`, one per subgroup (`groupFilter="1".."8"`). A `SecureGroupHeaderTemplate` allows exactly one `groupBy`, and with `groupBy` set the within-bucket order can only be name or raid index (`sortMethod="NAMELIST"` is ignored in that branch — read from Blizzard's `SecureGroupHeaders.lua`), so a single header can give subgroup columns **or** role sorting, never both. Narrowing each header to one subgroup first makes `groupBy="ASSIGNEDROLE"` sort *within* the group. Same structure DandersFrames uses. Key functions: `CreateRaidGroupHeaders` (creation, must be out of combat), `LayoutRaidGroupHeaders` (attributes + block placement — replaces the old `columnAnchorPoint`/`columnSpacing`/`maxColumns` approach), `HideRaidGroupHeaders`, `CensusRaidGroups` (roster-based populated-group census + slot assignment), `ActiveHeaders`/`ForEachHeaderButton` (every button walk goes through these — never `ipairs(header)` directly)
- `PartyButtonsWired` fires **once per active header** (8× in a raid); listeners that walk `ipairs(header)` therefore work unchanged, but anything caching the payload must keep a set (see `ClickCasting.lua`'s `headerFrames`)
- Attribute writes only take effect while a header `IsVisible()` — `SecureGroupHeader_OnAttributeChanged` early-returns otherwise, and `OnShow` is wired straight to `SecureGroupHeader_Update`. **Always set attributes first, `Show()` last**
- **Growth directions**: `DOWN`, `UP`, `RIGHT`, `LEFT`, `CENTER_H`, `CENTER_V`
- **Raid has a second, independent direction**: `layout.raid.groupGrowthDirection` places the subgroup BLOCKS (`growthDirection` only ever describes units *within* one block). It takes the same tokens, restricted to whichever axis the blocks sit on — that axis is the perpendicular of the unit axis, and `PartyFrames.RaidGroupsAlongX(layout)` is the single source of truth for it (the Layout tab's Group Growth dropdown calls it so its offered options can't drift from `LayoutRaidGroupHeaders`' placement). A `CENTER_*` value straddles the container's anchor point instead of growing from it, measured on the **populated** group count so empty groups don't push the block off-centre. Any value belonging to the other axis is treated as the default direction, so flipping orientation can never produce a broken layout; the options panel maps it across (`GROUP_GROWTH_ACROSS`) to preserve intent.
- **Container auto-sizes** to visible buttons via `SizeContainerToButtons()` — no empty draggable strip
- **Edit mode** uses a non-secure **mover frame** (`mover:SetAllPoints(container)`) on top — secure buttons swallow clicks, so drag must be on a separate frame

### 4. Indicator System (Indicators.lua)
- Mirrors **Cell's** indicator architecture
- **Built-in indicators** (26 defaults, `IndicatorDefaults.BUILT_IN_COUNT`): nameText, healthText, powerText, statusText, statusIcon, roleIcon, leaderIcon, playerRaidIcon, aggroBlink, aggroBorder, shieldBar, externalCooldowns, defensiveCooldowns, debuffs, ccIndicator, dispels, missingBuffs, healerHots, shieldOverlay, healAbsorb, targetHighlight, hoverHighlight, frameBorder, dispelIcons, phasedIcon, pingMarker
  - Adding one means four places, not one: an entry in `Defaults/Layout_Defaults.lua` (both `indicatorIndices` and `profile.layout.indicators`), a bump to `BUILT_IN_COUNT` plus name/settings entries in `Modules/Indicators/IndicatorDefaults.lua`, a category in `IndicatorsPanel.lua`'s `INDICATOR_CATEGORY`, and the create/check wiring in `BuiltIn_Update.lua`. Existing profiles pick it up automatically — `Core.lua`'s `MigrateMissingBuiltIns` adds any default entry the profile lacks, matched **by name**, for both the party and raid lists.
  - ⚠️ **A `Check*` function must be AUTHORITATIVE — decide show AND hide, every pass.** `HandleIndicators`' generic apply loop does `if t.enabled then indicator:Show() else indicator:Hide() end` (`Indicators.lua:461`) on **every** rebuild, and `ApplySettingToOne`'s "enabled" branch does the same. A Check that only hides under particular conditions therefore lets any rebuild resurrect whatever the indicator last drew. `pingMarker` shipped that way for a day: its textures kept the atlas from the last real ping, so a roster sync re-showed a ping nobody had sent, and nothing could clear it because the expiry had already nil'd the very fields the hide conditions tested — `/reload` only. Every other built-in survives that line by deciding outright. If an indicator can hold visual state, blank it on hide too, so a stray `Show()` can only ever produce an empty frame.
- **Custom indicators** created by user via options; stored in `profile.layout.indicators` array
- **Runtime**: `indicatorList` = current profile's indicator array
- **Per-button**: `button.indicators[name]` = frame; `button._indicatorsReady` flag guards custom dispatcher
- **Central callback**: `SquizzFrames:Fire("UpdateIndicators", indicatorName, setting, value, value2)` → applies to all buttons + preview
- **Aura scanning, two parallel pipelines**:
  - **Legacy** (all clients, and 12.1 fallback for anything not migrated): `Custom_Dispatch.lua` scans `UNIT_AURA` via manual `C_UnitAuras.GetAuraDataByIndex` iteration; dispatches by type (icons, bars, icons+counter, text). **Broken in combat on 12.1+**: aura data is fully secret while auras are secret, so a scan started mid-combat permanently never sees anything applied after combat started (not intermittent — see the AuraEngine section below).
  - **AuraEngine** (12.1 only, `SquizzFrames.IS_121` gate): `AuraEngineIndicators.lua` builds indicators on Blizzard's managed `AuraContainer` API instead, which renders C-side without ever exposing secret aura data to Lua. `HandleIndicators` in `Indicators.lua` picks per-indicator at creation time (see next section) — there's no global on/off switch, some indicators/custom types stay on the legacy path even on 12.1.

### 5. Click Casting (ClickCasting.lua)
- Bindings stored in `profile.clickCasting` as `{bindKey, modifier, type, action}`
- Written as **secure attributes** on each unit button:
  - Mouse buttons: `type1`, `macrotext1`, `spell1`, `item1` ... `type5`
  - Keyboard/wheel: `type-E`, `macrotext-E` (virtual click via `SetBindingClick`)
- **12.0.7 click-gate workaround**: `target`/`menu`/`togglemenu` on non-Left/Right or with modifiers are **gated** (silently fail). Solution: route through a **click proxy** button (`SecureActionButtonTemplate`, `useparent-unit=true`) via `click` + `clickbutton` attributes
- **12.1 proxy transport changes**: a separate Blizzard bug (`SecureTemplates.lua` checks forbidden aspects on the mouse-button *string* instead of the delegate frame, and throws) breaks the 12.0.7 `clickbutton`-attribute proxy transport on 12.1. `RouteProxyAction` branches on `SquizzFrames.IS_121`: pre-12.1 keeps the `clickbutton`-attribute transport; 12.1+ instead sets `macrotext = "/click " .. proxyName"` (requires the proxy to have a **global name**, unlike the anonymous pre-12.1 proxy) — mirrors EllesmereUI's `EllesmereUI_Kick.lua` fix for the same bug.
- **Secure hover snippet** (`_onenter`/`_onleave`/`_onmousedown`) installs `SetBindingClick` for keyboard/wheel keys on hover

### 6. Profile Management (AceDB-3.0)
- `SquizzFramesDB` with `profile`, `char`, `global`
- Profile callbacks: `OnProfileChanged`, `OnProfileCopied`, `OnProfileReset` → `RefreshProfile()` migrates layout/indicators from defaults if missing
- **Healer preset**: `SquizzFrames.ApplyHealerPreset()` enables/configures key healer indicators

#### A profile is a DEEP COPY of the defaults, not an AceDB metatable overlay

This is the single most important thing to know before changing any default
value, and it is the opposite of how stock AceDB-3.0 behaves. `ProfileStore`'s
`DeepFillDefaults` (plus the backfills in `Core.lua`'s `EnsurePetFramesDefaults`)
**materialise the whole tree into the saved profile**. There is no live link
back to `SquizzFrames.defaults` afterwards.

So: **changing a default in `Defaults/` reaches nobody who has already run the
addon.** Their saved table already holds the old value. A fresh install picks it
up; everyone else sees no change at all, reports "it didn't work", and is right.

If the user asks to *change a default* and means it to be visible, it takes two
edits, not one:

1. the default itself (and every code-side `or <fallback>` that shadows it —
   there are usually three or four: the defaults table, the module's own
   fallback, and each options panel's getter fallback. Grep the key name and
   fix every hit, or the panel will display one value while the frame renders
   another)
2. a migration in `Core.lua` that rewrites **only the exact old default**, so a
   deliberately-chosen value is never stamped on

**Migrations that move a default need a ONE-SHOT FLAG, not value detection.**
The older migrations in that file (`MigrateDispelsShape`, `MigrateAccentColorDefault`
…) safely re-run on every profile load because the shape they detect is
unreachable once converted. A *default move* is not like that: the old value
usually stays perfectly choosable from the same slider, so a value-detecting
migration would silently undo the user's choice on the next reload — the
"setting won't stick" bug this project keeps re-inventing. See
`MigrateUnitFrameAuraDuration` (`unitFrames.auraDurationCentred`) and
`MigrateDispelGradientHeight` (`profile.dispelGradientHeightFull`), both
2026-09-11, for the pattern.

⚠ **Two ways to get the flag itself wrong**, both silent:

- **Checking it without ever setting it.** The guard reads fine and the
  migration simply re-runs on every profile load forever. It usually *looks*
  harmless because the body is nil-guarded, which is exactly why it survives
  review — the flag is doing nothing at all.
- **Setting it inside the `listKey` loop.** `RefreshProfile` runs the
  indicator migrations once per list (`indicators`, then the raid list), so a
  flag set on the first pass makes the second pass return early and the RAID
  list never migrates. Set it *after* the loop closes. `MigrateIndicatorTextFormat`
  (`profile.indicatorTextFormats`, 2026-09-17) is the worked example, and both
  mistakes were made writing it.

Also: a migration that converts one field to another should leave the OLD field
alone unless it is genuinely unreadable afterwards. Converting
`showPercentage`/`showCurrent`/`showMax` to a single `textFormat` token only
writes the new key — the booleans stay, costing nothing and leaving a way back
if the mapping turns out wrong for somebody.

**Every indicator and unit-frame element defaults to an X/Y offset of 0,0**
(user decision, V1.31/V1.32, 2026-09-24). Keep new defaults at 0,0 on their
anchor — the user asked for this outright after finding a dozen that sat a few
pixels off. Two migrations moved existing profiles, and they are the
reference for a *default move that must avoid stamping on user choices*:

- `MigrateIndicatorOffsetsZero` (`profile.indicatorOffsetsZeroed`) — walks both
  lists ITSELF and runs after the `listKey` loop, so the flag cannot cut the
  raid list. It matches the **whole five-field position tuple** against a table
  of old defaults (`OLD_INDICATOR_OFFSETS`, plus the Healer preset's placements
  as alternates; customs by template `type`), so an indicator the user moved —
  or merely re-anchored — is never touched.
- `MigrateUnitFrameOffsetsZero` (`unitFrames.offsetsZeroed`) — the same for the
  unit frames' texts (anchor + x), aura row `offsetY` and stack `stackX/Y`,
  across `frames` and `boss`.

Both also needed the **code-side fallbacks** changed (`Auras.lua`'s
`cfg.stackX or 1`, the panel getters) — the "grep the key and fix every hit"
rule above, which is easy to forget when the default only moves a pixel.

### 7. 12.1 AuraEngine Subsystem (AuraEngine.lua / AuraEngineIndicators.lua)

**Why this exists**: on 12.1, `UNIT_AURA` payloads and `AuraData` structs are **fully secret while auras are secret** (i.e. during combat/encounters) — this is an official Blizzard change, not a bug. A manual `C_UnitAuras.GetAuraDataByIndex` scan (the legacy pipeline) doesn't get flaky in combat, it **permanently** stops seeing anything applied after combat started, for the rest of the encounter. `SecureAuraHeaderTemplate` itself was removed from Mainline in 12.1. The only sanctioned fix is Blizzard's managed `AuraContainer` API, which renders aura icons/cooldowns/text C-side without ever exposing the secret data to addon Lua at all.

**Backport strategy — read this before touching any aura-related indicator**: this was ported in as an *additive*, feature-flagged branch, not a replacement. Everything AuraEngine-related is gated behind `SquizzFrames.IS_121` (`Utils.lua`, `(select(4, GetBuildInfo()) or 0) >= 120100`) and goes fully inert (`if not SquizzFrames.IS_121 then return end`) on a pre-12.1 client.

**As of 2026-08-12 the pre-12.1 fallbacks are DEAD CODE** (per user instruction): 12.0.7 is no longer available, so no client can reach them, and they would no longer work if one did. Leave them in place — they're inert and harmless, and removing them is pointless churn — but **do not spend effort keeping them correct**: don't mirror new features into them and don't bugfix them. This applies ONLY to the `IS_121`-gated fallback branches. The legacy `Custom_Dispatch.lua`/`BuiltIn_Update.lua` code that is still the only path on 12.1 for indicator types AuraEngine doesn't cover (`trackByName` customs, `unitButton`-anchor color customs, `icon`/`icons`/`text`/`texture` customs) is live, load-bearing code and does still matter.

**What's migrated to AuraEngine on 12.1 today** (decided per-indicator in `Indicators.lua`'s `HandleIndicators`, not a global switch):
- Built-ins: `healerHots`, `dispels`, `externalCooldowns`, `defensiveCooldowns`, `debuffs`, `ccIndicator`
- Custom indicator types: `color` (only when NOT `trackByName` and anchor mode isn't `unitButton`) and `bar` (only when NOT `trackByName`)
- **Stays on legacy always**: `trackByName` customs (AuraContainer candidate filters are spellID-based, not name-based), `unitButton`-anchor color customs, and every other custom indicator type (`icon`, `icons`, `text`, `texture`, etc.)
- Every migrated indicator's factory lives in `AuraEngineIndicators.lua`; `Indicators.lua` tries the AuraEngine factory first (`indicator._sfType` check) and falls back to the legacy `BuiltIn.CreateBuiltInIndicator`/`I.CreateCustomIndicatorFrame` if AuraEngine isn't available or returns nil

**Core engine pieces (`AuraEngine.lua`)**:
- `AE.CreateContainer(parent, unitToken, spec)` — builds a real `AuraContainer` frame (`CreateFrame("AuraContainer", nil, parent, "CustomAuraContainerTemplate")`), declares groups (`AddAuraGroup`, multi-icon grids) and slots (`AddAuraSlot`, exactly-one-always-present overlays like dispel types or a single tracked spell), then `SetUnit` **last** (setting it before groups/slots are declared leaves `UNIT_AURA` unregistered). Asserts `not InCombatLockdown()` — never call directly from anywhere that might run in combat.
- `AE.RequestContainer(parent, unitToken, spec, callback)` — the actual call site everywhere else uses; fulfills immediately out of combat, otherwise queues until `PLAYER_REGEN_ENABLED`.
- `AE.styles[styleKey]` + `AE.MakeInitializer(styleKey, extra)` — a style is a plain table describing how a button should look; `MakeInitializer` returns the `initializeFrame` callback the engine calls **once per button, at creation time** (buttons are pre-created in batches of 10). This is the ONLY place region creation + `SetIcon`/`SetDurationCooldown`/`SetApplicationCount`/`SetDurationText` registration may happen — see the PTR5 rule below.
- `AE.RestyleSoon(styleKey)` — settings changes (size, colors, border, duration visibility) don't touch buttons synchronously; they queue the style key and a time-sliced `OnUpdate` restyler applies `ApplyStyleToRegions` to up to 200 buttons/frame, pausing entirely (not skipping/erroring) during combat.
- `style.noRegions = true` ("bare" styles) — used by dispels, custom color, and custom bar indicators, which don't want icon/cooldown/stack/duration regions at all, just a presence-driven host frame; all visuals are built by `style.applyExtra` instead.
- `AE.Filter(...)` — canonicalizes filter token order (base polarity first, then alphabetical, negated tokens sort by bare name). **Required**, not cosmetic: the engine batches aura parsing per container by *exact byte-identical filter string*, so two groups with equivalent-but-differently-ordered tokens silently don't share a scan.

**Hard rules learned building this (violate these and you get silent failures or "attempt to access forbidden object" errors, not compile errors)**:
- **`AE.styles` is ONE GLOBAL TABLE keyed by string, so a style key is a shared namespace — last write wins, for everybody using that key.** That is correct for a party/raid indicator, where every button genuinely reads one settings table. It is wrong the moment a *second owner with different settings* builds on the same keys, and the symptom points nowhere near the cause: the settings apply, then something unrelated rebuilds and silently overwrites them. The unit frames' Dispels shared `dispels_<type>` with the party indicator, so picking Gradient on a unit frame rendered the party list's `fill` at the party list's opacity, and only after the next party rebuild (user report 2026-09-10). Fixes in place: `Auras.lua` keys per unit AND kind; `AEI.CreateDispelsIndicator`/`CreateDispelIconsIndicator` take `t._sfStyleNS` and the unit frames pass `"uf_<unit>_"`. **Any new caller of a shared AEI factory must claim a namespace**, and an absent one must keep the original keys byte-identical so the party path is untouched.
- **No API calls on an AuraContainer-managed button outside `initializeFrame`/`extraInit`, full stop**, once its aura is secret (12.1 PTR5 change). This is broader than just Show/Hide — covers `SetFrameStrata`, `SetFrameLevel`, `SetDurationBar`, etc. Every `slotButton:Set*` call in this codebase happens inside an `extraInit`/`initializeFrame` callback for exactly this reason.
- **No `SetScript`/`HookScript` on a group/slot button** — breaks the engine's own secret-aspect Show/Hide wiring.
- **Can't read a slot/group button's `IsShown()`** — and it is worse than "secret". The *call itself* is refused: `kid:IsShown()` raises `Attempt to access forbidden object from code tainted by an AddOn`, so guarding it with a secret-probe (`IsSecret(v)` on the result) cannot help — nothing is ever returned to probe. Even `c[methodName]` on a container carrying a forbidden aspect can raise, so the table index has to sit *inside* the `pcall`, not before it. Never build telemetry/debugging around polling button state. (Learned the hard way porting a co-tank tracker into Squizzumables, 2026-09-08: four separate diagnostic crashes, each one a "fix" for the previous misdiagnosis.)
- **A diagnostic that touches this API must be defensive end to end**, because its failures land on the user mid-fight. Wrap the whole dump in a `pcall`, print a terminator line so a truncated report is obvious (silence in a loop is indistinguishable from the loop never running), and remember `string.format("%s", …)` does **not** coerce a boolean in Lua 5.1 — `IsVisible()` returns one and it raises `string expected, got boolean`. Also note a `print` of a string that has become secret emits **nothing at all** rather than erroring, so output can vanish without a traceback.
- **Addons cannot reparent aura buttons** (12.1 PTR6 ban). Custom bar/color indicators create their visuals as children of the *same* slot button they're registered on (`ApplyCustomBarSlotStyle`/`ApplyCustomColorSlotStyle`) — never move them elsewhere.
- **`AddAuraSlot` locks onto its first matched instance** and doesn't reliably notice a reapplication/refresh. Fixed by a periodic (1.5s) `container:UpdateAllAuras()` per registered slot-based wrapper (`slotRefreshTicker`/`RegisterSlotRefresh` in `AuraEngineIndicators.lua`) — combat-legal, unlike a full container recreate.
- **`CustomAuraButtonTemplate` must exist, by that exact name, as an empty virtual template** (`AuraButtonTemplate.xml`). Blizzard's internal container code hardcodes an implicit inherit of a template literally named that, but never shipped one — omit it and `AddAuraGroup`/`AddAuraSlot` fails with "Couldn't find inherited node". XML `<Layers>` children do NOT attach to `type="AuraButton"` nodes on this build — all region creation happens in Lua via `initializeFrame`, not XML.
- **Group/slot `layout.elementWidth/elementHeight` only feeds the engine's flow-anchoring math**, not the button's actual rendered size — you must `button:SetSize(...)` yourself in the initializer. **This is the single most expensive thing on this list to get wrong**, because every symptom points somewhere else: the group attaches, `AddAuraGroup` returns cleanly, the frame pool fills with buttons, candidate filters match, the container reports `visible=true` with its flow layout fully applied — and nothing appears, because the buttons are zero-sized. A co-tank tracker built in Squizzumables (2026-09-08) died on exactly this and was abandoned after a session of chasing container sizing, `UpdateAllAuras`, flow-layout configuration and filter semantics, none of which were the fault. If icons do not render and everything looks correct, check the button size in the initializer first.
- **Spell-ID candidate filters are silently SKIPPED for a harmful aura on an assistable unit** — not applied and not rejected. `AuraContainerUtil.CanApplyIdentityCandidateFilters` returns true only for `auraData.isHelpful and UnitIsPlayerControlledOrGroupMember(unitToken)`, so a HARMFUL group with an `includeSpellIDs` whitelist shows **everything** while looking like it filters. The helpful side of this asymmetry is documented above under `NoiseFloorMaxDuration`; this is the other half. Use `maxDuration` or the boss/priority flags for debuff filtering, never a spell-ID list.
  - **The gate covers ONLY `includeSpellIDs`/`excludeSpellIDs`** (read the function: the identity test wraps just those two). Every other key — `isBossAura`, `isBossOrRoleAura`, `isRoleAura`, `isPriorityAura`, `maxDuration`, `include/excludeDispelTypes`, `canApplyAura`, `isFromPlayerOrPlayerPet`, `isStealable`, `nameplateShow*`, `processedAuraType` — is evaluated unconditionally and *does* work on party members' debuffs. Don't over-apply the gate when diagnosing.
  - **The one exemption is `NeverSecret`.** `C_Secrets.GetSpellAuraSecrecy(spellID)` returns `Enum.SecrecyLevel`: **NeverSecret = 0, AlwaysSecret = 1, ContextuallySecret = 2**. Only 0 lets a spell-ID filter through, which is why the Sated/Exhaustion blacklist works and why blacklisting Monk Stagger cannot: Stagger measures 2 (confirmed in game 2026-09-19).
- **Candidate filters are ANDed, never ORed** — every key is an independent early `return false` in `DoesAuraPassCandidateFilters`. Putting two flags in one table INTERSECTS them (narrower than either), which reads as a union and is the opposite. A real union needs **two groups**, the second negating the first (`{isPriorityAura = true, isBossOrRoleAura = false}`) so they are mutually exclusive by construction and need no Lua-side dedup — the same shape `DEF_GROUPS` uses for defensives. Groups are **add-only**, so declare the second permanently at `maxFrameCount = 0` and flip the cap live; and remember `maxFrameCount` is a *static per-group* cap, so two groups cannot share one budget — split it, or accept 2× the stated icon count.
- **`isBossOrRoleAura`/`isPriorityAura` are flags BLIZZARD AUTHORS PER AURA, and plenty of encounters carry neither.** A flag-based filter then renders an **empty row**, silently, and nothing on our side can help. The Lost Explorers (Venomous Abyss) is the worked example: Steady Strikes (1291930) and Shredding Shards (1295858) measure `priority=false` and carry no boss or role tag, so *every* flag preset misses them — which is why the tank tracker's default is now the duration-bounded `encounter` preset instead. `isRaid` is not a rescue: it is not a candidate-filter key at all (only the `RAID` filter-string token) and for a debuff it means "dispellable by the player", so undispellable encounter debuffs fail it too.
- **Two flags ARE queryable from a spell ID alone** — no aura, no group, no encounter: `C_Spell.IsPriorityAura(id)` and `C_UnitAuras.AuraIsBigDefensive(id)` (this is how Blizzard's own `AuraUtil` resolves them), plus `C_Secrets.GetSpellAuraSecrecy(id)`. `isBossAura` and the three role flags have **no** by-ID query — they exist only on a live `AuraData`, which is fully secret in combat, so they can only be established empirically by watching what a filter actually shows. See `/sfspell` and `/sfauras`.
- **`SetGradient` permanently breaks plain `SetAlpha`/`SetColorTexture` alpha on that same texture object** afterward (confirmed by debugging — not documented). Dispels' gradient overlay mode uses a dedicated second texture (`d.gradientOverlay`) rather than reusing `d.overlay`, so full/fill mode's plain alpha stays reliable regardless of gradient mode ever having run.
- A PTR5 upstream bug: `SetDurationText`'s `textColorCurve` option can hard-error and abort the WHOLE button batch if the engine's C binding argument count doesn't match. `AE.SetDurationTextSafe` tries with the curve, falls back to without it on failure — self-heals once Blizzard fixes it upstream.

**Preview/Designer limitations** — the options panel's live preview button can't get real aura data into an AuraContainer (it's driven entirely by the C-side engine bound to a real unit; there's no way to inject fake `AuraData`):
- Every migrated indicator instead renders a **fallback row of static icon frames** (`CreateFallbackIconRow` in `AuraEngineIndicators.lua`) sized/laid out to match the real container, using representative spell icons pulled from the indicator's own effective spell list where one exists (healerHots, cooldowns), or generic placeholders (debuffs, CC).
- The preview's container is either **never created at all** (healerHots/cooldowns/debuffs/CC — `isPreview` skips `AE.RequestContainer` entirely) or **bound to a deliberately-invalid unit token** (dispels — `"squizzframespreviewfake"`) — both approaches were needed because a first attempt (binding to the preview button's real `"player"` unit) leaked real casts into the preview while it was open.
- **Duration and stack text are mocked too**, not just the icons — both are engine-drawn on a real button, so neither appears in a preview by default, and a user cannot place text they cannot see (asked for twice: party 2026-08-13, unit frames 2026-09-11). `AEI.ApplyMockDurationText`/`ApplyMockStackText` style them from the same `style.duration*`/`style.stack*` fields `ApplyStyleToRegions` reads. **The same constraint applies to any new preview**: `UnitFrames/Preview.lua` is a separate mock with the same problem, and calls the same two helpers rather than growing its own copy.

**Boss "Private Aura" debuffs are handled by the engine itself.** They used to need a separate indicator built on `C_UnitAuras.AddPrivateAuraAnchor` (an older, unrelated API that Blizzard has always hidden from addon aura scanning). On 12.1 the AuraContainer engine registers for them natively (`AuraContainerPrivateMixin` / `C_UnitAurasPrivate.AddPrivateAuraUpdateCallback`), so that indicator was removed on 2026-08-13 — module, defaults, settings and profile entries. Don't re-add it; if boss private auras ever stop appearing, the fault is in the container binding, not in a missing anchor indicator.

**Dev/debug harness**: `/sfauratest` (`AuraEngine.lua`) creates a real, throwaway `AddAuraGroup` above the player's own button filtered to the healer spell list, to prove the pipeline end-to-end (including in combat) independent of any real indicator. Marked in-code as a temporary Phase 0 harness — fine to leave, but don't build new functionality on top of it.

**Coming in 12.1.5** (researched 2026-09-08 against `Gethe/wow-ui-source` branch **`ptr2`**, build 69594 — that is the branch to check for this, not `live`). Two breaking changes and several additions, all in this subsystem:

- **Breaking, and the one that reached our code: `includeSpellIDs` now REJECTS rather than being skipped.** Re-verified 2026-09-16 against `ptr2` build **69848** (the notes below were build 69594). `AuraContainerUtil.DoesAuraPassCandidateFilters` gained an `elseif candidateFilters.includeSpellIDs ~= nil then return false` branch: where identity filtering is not permitted, a whitelist used to be discarded (everything showed) and now rejects everything (nothing shows). That would have inverted `showUnfiltered`, which depended on the discard (it promised the raw pool and would have delivered an empty row), **but that option was REMOVED in V1.24 instead of fixed** — it had been inert since the 69465 hotfix made the gate read OPEN for every token we bind, so the hide it opted out of no longer happens. `SquizzFrames.IS_1215` (`Utils.lua`, build >= 120105) exists but currently has no consumer. If a future 12.1.5 gate is ever written against `IdentityGateState`, do NOT assume "12.1.0 discards the whitelist anyway, so it is safe unconditionally": that heuristic is ours and Blizzard's test is per-aura and mostly OPEN, so dropping a whitelist on a SHUT reading would trade a correctly filtered list for the raw pool on live. Blizzard also now registers `UNIT_FLAGS`/`UNIT_FACTION` itself for spell-ID filters (`AppendCandidateFilterUnitEvents`), which makes our own identity-gate refresh largely redundant on 12.1.5. `SetAuraBorder`/`GetAuraBorder`/`ClearAuraBorder` are GONE from `CustomAuraButton` (we never called them); two new animation triggers exist, `AddAuraShownAnimation` and `AddAuraAssignedAnimation`.
- **Breaking: `AddDispelTypeTexture` and `AddPandemicRegion` no longer return an index.** The matching `RemoveDispelTypeTexture` / `RemovePandemicRegion` now take a **region reference** instead of an index, and **adding the same region twice raises an error** rather than being ignored. Anything that captures the return value or removes by index needs updating; code that only adds, and adds a fresh region each time, is unaffected.
- **Breaking: `SetCooldown`/`Clear` cannot be called from tainted code when the cooldown frame itself is protected.** Hooks are unaffected; only direct calls on a protected frame. Cooldowns created by us on our own frames are fine.
- **Pandemic animations**: `AddPandemicEnterAnimation` / `AddPandemicActiveAnimation` / `AddPandemicLeaveAnimation`, each with a `Remove*` and a `Clear*Animations`. *Enter* is one-shot, *Active* is for looping, *Leave* fires on exit. Blizzard drives them, so they work on secret auras — the obvious win for anything tracking refreshable debuffs. Two **new forbidden aspects** come with them: `QueryAnimationProgress` (cannot ask whether an animation is running or how far along) and `AddAnimations` (cannot add or reparent animations), plus the existing `ChangeAnimationTarget`. Hand the group over and never inspect it afterwards.
- **`SetCasterName(fontString, options)`** on `CustomAuraButton` — who applied the aura, colourised by reaction or class. Aura tooltips can show it too, gated on the new `tooltipShowAuraCasterNames` CVar.
- **`SetApplicationBar(statusBar, options)` gains `minApplications`** — hide the bar until N stacks.
- **`SetAuraGroupEnabled(groupKey, enabled)`**, `SetAuraSlotEnabled(slotKey, enabled)` and `SetItemEnchantmentEnabled(slot, enabled)` on `CustomAuraContainerSharedMixin` — a live enable/disable, which is the sanctioned answer to "groups are add-only, a disabled group is `maxFrameCount` 0". Worth revisiting that rule when this ships.
- The container now refreshes on **`UNIT_FLAGS` and `UNIT_FACTION`** (both in `FullAuraRefreshEvents`).
- `SetEditModePreviewEnabled` is listed in Blizzard's own notes but I could **not** confirm it in the `ptr2` source — treat as unverified. (`SetUnit` likewise did not appear in the file I read and obviously does exist, so absence there is not evidence.)

---

## Development Workflow

### Testing In-Game
There is **no automated test suite**. Development is done by:
1. Editing `.lua` files in the AddOns folder
2. `/reload` in-game (or log out/in for TOC/XML changes)
3. Using `/sf` to open options panel
4. Checking chat for debug prints (prefixed `|cff33cc99[SquizzFrames]|r`)

### Static checks — there IS tooling, and it is not luac

"No build step" does not mean "nothing can be checked before a reload". There is no Lua
interpreter here, which is easy to mistake for *no verification at all* — that mistake was made
for a whole session on 2026-09-19, and two releases were shipped with "not syntax-checked"
disclaimers that were simply wrong. Both of these run in seconds:

**1. The `wowlua_ls` CLI is the real gate.** It has the WoW API stubbed in, so it catches
undefined globals and undefined fields, not just parse errors:

```sh
"$HOME/.vscode/extensions/tradeskillmaster.wowlua-ls-<ver>/server/win32-x64/wowlua_ls.exe" \
    check "C:/World of Warcraft/_retail_/Interface/AddOns/SquizzFrames"
```

Take the highest installed version. 94 files / ~78k lines in ~3s. **Baseline as of 2026-09-19:
160 warnings, every one pre-existing in `UnitFrames.lua` and `Utils.lua`.** That baseline is the
point — a new warning in a file you actually touched is signal, and `grep`ing the output down to
your changed files turns a wall of noise into a yes/no answer.

**2. Squizzumables' `.claude/` scripts are path-agnostic** and catch corruption classes a type
checker passes happily (mangled escapes, truncated strings, block imbalance). SquizzFrames has
none of its own — run them from that folder against these files:

```sh
perl .claude/check-backslashes.pl <files>   # lone backslashes: "Fonts\FRIZQT__.TTF"
perl .claude/check-strings.pl     <files>   # unterminated strings / mangled escapes
awk  -f .claude/check-balance.awk <file>    # per-function block balance
```

Three invocation traps, all hit first time out:

- **Quote every path.** "World of Warcraft" contains spaces; unquoted, the scripts die with
  `cannot open C:/World` — which looks like the check failing rather than the command being wrong.
- **`check-balance.awk` must be run ONE FILE PER INVOCATION.** Given several files it carries
  state across the boundaries and reports phantom `UNBALANCED` functions attributed to the *wrong
  file* — alarming, and entirely an artefact. Per-file, this codebase is clean.
- **`check-backslashes.pl` flags every `[[...]]` long-bracket literal** (`[[Interface\Icons\...]]`),
  where a single backslash is correct. ~57 of those here; they are all expected.

### Releasing
Tagging is what publishes — pushes to `main` never reach CurseForge.

**The top `CHANGELOG.txt` section stays OPEN (undated, no TOC bump) until the
user says to ship.** Work lands on `main` under that open heading, possibly
across several commits and days; closing it is step 2 below and part of
tagging, not part of finishing a change. Adding the `RELEASE_NOTES` entry early
is fine and saves a step — it's keyed by version string, so it does nothing
until the TOC says that version.

1. Add a `RELEASE_NOTES["<version>"]` entry in `Modules/Welcome/Welcome.lua` --
   a few player-facing highlights, NOT a copy of the changelog. An addon
   cannot read its own text files at runtime, so anything shown in game has to
   be duplicated in Lua; a handful of lines per release is worth keeping in
   step by hand. A missing entry is not fatal (the window still appears,
   without bullets) which is exactly why it is easy to forget.
2. Close the top `CHANGELOG.txt` section (date the heading) and bump `## Version:` in `SquizzFrames.toc`. **Both are manual** — the TOC keeps a literal version rather than `@project-version@` so the live dev folder doesn't show a placeholder in the in-game addon list.
3. `git tag -a v1.7 -m "V1.7"` && `git push origin v1.7`
4. `.github/workflows/release.yml` (BigWigsMods/packager) builds the zip, uploads it to CurseForge (project ID read from `## X-Curse-Project-ID` in the TOC) and attaches it to a GitHub release.

**Tags are listed newest-first by date, always.** This repo sets `tag.sort = -creatordate` locally (`git config tag.sort -creatordate`), so plain `git tag` is already correct — don't reintroduce the raw alphabetical listing by passing something else. Versions went past `1.9` into `1.10`, which sorts *before* `1.9` as plain text: an alphabetical listing shows the newest release buried in the middle, which reads as "the tag didn't push". Nothing in the release path itself is affected (`git describe` walks the commit graph, CurseForge orders by upload) — it's the human read of `git tag` that misleads. Re-run the config in a fresh clone; it's local, not committed.

Dry run: Actions tab → "Package and release" → Run workflow with `dry_run` ticked. Builds and uploads nothing, leaving the zip as an artifact. Requires the `CF_API_TOKEN` repo secret; `GITHUB_TOKEN` is automatic. `.pkgmeta` controls what's excluded from the zip and feeds `CHANGELOG.txt` in as the release notes (whole file, not just the newest section).

**Three failure modes that a green checkmark won't show you** — all learned the hard way on Squizzumables (its `CLAUDE.md` "Releasing" section is the original writeup; this toolchain is shared, so check there before debugging packaging here):
- **The tag must be annotated (`-a`).** `git describe` ignores lightweight tags, so the packager falls back to the commit hash and ships an *alpha* build named after it instead of a version.
- **`actions/upload-artifact` skips hidden paths by default** and the packager builds into `.release/`, so the dry-run artifact needs `include-hidden-files: true`. Without it the upload finds nothing while the packaging step stays green.
- **`release.sh` skips a missing token silently and still exits 0.** The tell is the credential line it prints near the top: `CurseForge ID: 1649203 [token set]` — that suffix is `${cf_token:+ [token set]}`, so **no suffix means the token is empty**. A green run that makes a GitHub release but nothing on CurseForge is this. A misnamed secret is not an error in Actions; it interpolates to an empty string, which is why the workflow has a dry-run-only step printing both secrets' lengths.

### OptionsFrame.lua is at TWO Lua ceilings

This file is large enough to sit against both of Lua's per-function limits.
Neither fails gracefully: the WHOLE file fails to load and the entire options
panel disappears, and the reported line number is nowhere near the cause.

**60 UPVALUES** (locals captured from an enclosing scope), hit by
`BuildLayoutFields`:

```
OptionsFrame.lua:1724: function at line 1463 has more than 60 upvalues
```

**200 ACTIVE LOCALS** in the main chunk, hit by the file as a whole:

```
OptionsFrame.lua:3096: main function has more than 200 local variables
```

Adding a feature to a page normally means a getter AND a setter per control,
which walks straight into both. Two mitigations, and use them from the start
rather than after the file stops loading:

1. **Group accessors into ONE table.** A table costs one upvalue however many
   fields it carries. See the `Grad` table (health gradient).
2. **Wrap the helpers in a `do ... end` block.** Locals declared in a closed
   block are RELEASED at its end, so they stop counting against the 200. The
   gradient block does this: six names become one surviving `Grad`.

**The real fix is to move a page into its OWN FILE**, because each Lua file is
its own main function and therefore gets its own 200-local budget. Five pages
already work this way (Click Casting, Indicators, Unit Frames, Tank Tracker,
Nicknames) -- OptionsFrame keeps only a ~12-line shim that creates the frame
and calls `Panel.Build`.

Pet Frames and Layout were extracted the same way on 2026-09-10:
**202 -> 147 -> 59 main-chunk locals**, and the file went 3167 -> 1373 lines.
Both ceilings now have comfortable headroom.

Only **Profiles** (~470 lines) and **General** (~75) are still inline, and
neither is near a limit. The pattern for extracting one: the block is usually
contiguous, needs only W/L/F plus a locally re-declared `GetProfile`, and any
state OptionsFrame still reads should be published as a small function on the
panel (see `LayoutPanel.IsRaidTab`, which mirrors `IndicatorsPanel.IsRaidTab`).

### Do not write code containing backslashes with sed/perl

Inserting Lua through `perl -0pi -e` mangles backslashes. A font path written
as `Fonts\FRIZQT__.TTF` in the one-liner arrived in the source with a single
backslash, which Lua then read as an invalid escape and silently stripped,
yielding a bad path and a runtime *"invalid font asset"*. It does not fail at
load, so it surfaces only when that line actually runs.

**The commit that added this very section is the proof.** It was written with a
shell one-liner, and the backslash in its own example text ate the rest of the
edit: a lowercased copy of the ENTIRE document was spliced into the middle of
the file, 300 lines of it, and the section's closing sentence was cut off
mid-word. It was committed that way (`22696ee`) and sat corrupted until
2026-09-12. Nothing warned; the file is Markdown, so nothing could.

Use the Edit/Write tool for any content containing a backslash, `%`, or `$` --
source or prose. The same care applies to XML comments (below); both of the
bugs that produced these two sections came from shelling out to edit text.

### XML edits

A prose `--` inside an `<!-- -->` comment is illegal XML and kills the WHOLE
file, usually surfacing as an unrelated-looking Lua error. It has bitten this
project three times. After ANY edit to a `.xml` file, including one made with
`sed`/`perl`, run:

```sh
sh .tools/check-xml.sh
```

### Common Commands
| Command | Action |
|---------|--------|
| `/sf` | Open options panel |
| `/sf lock` / `/sf unlock` | Toggle frame lock |
| `/sf reset` | Reset profile + reload UI |
| `/sf healer` | Apply healer preset |
| `/sf notes` | Re-open the current release notes (`/sf changelog` also works) |
| `/sfhealers` | Bulk-import healer spells into a custom indicator (`Defaults/Indicator_Defaults.lua`) |
| `/sf nick` | Nickname management (see `Modules/Nicknames/Nicknames.lua`); `/sf nick` alone prints usage |
| `/sf nick test` | Solo self-check of the nickname sync pipeline (wire round-trip via whisper-to-self, receive path, sanitizer); `test clean` removes its entries |
| `/sfdrinktest` | Dev/debug helper (`PartyFrames.lua`) |
| `/sfauratest` | 12.1-only: spawns a throwaway AuraEngine test group above the player button (see AuraEngine section above) |
| `/sfspell [id ...]` | Aura flags **from a spell ID alone** — solo, no group, no aura needed (`TankTracker.lua`). Prints name, `IsPriorityAura`, `GetSpellAuraSecrecy` (+NeverSecret), `AuraIsBigDefensive`. Defaults to the Lost Explorers debuffs + the three Stagger IDs. The printed NAME is the check that an ID is the applied aura and not the cast |
| `/sfauras [unit] [help]` | The per-aura flags `/sfspell` cannot reach — `isRaid`, `isBossAura`, the three role flags, dispel type (`TankTracker.lua`). **Out of combat only**: `AuraData` is fully secret in combat and every field reads back secret, which the header states explicitly |
| `/reload` | Reload UI (required after TOC/XML changes) |

### Debug Prints
Search for `print("|cff33cc99[SquizzFrames]|r` — these are scattered through Core, PartyFrames, Indicators for migration/state debugging. They're intentional and helpful during development.

---

## Important Files to Understand

### Core.lua
- `OnInitialize()`: DB setup, defaults migration, slash commands, options registration
- `OnEnable()`: Event registration, module enable, `SquizzFrames_Ready` fire
- `Fire(event, ...)`: Cross-module messaging
- `RefreshProfile()`: Migrates layout/indicator data on profile switch
- `QueueDuringCombat(func)`: Defers secure operations until `PLAYER_REGEN_ENABLED`

### Utils.lua
- `SquizzFrames.IS_121`: build-number gate (`>= 120100`) checked by `AuraEngine.lua`, `AuraEngineIndicators.lua`, `ClickCasting.lua`, and `Indicators.lua`'s dispatch — the single source of truth for "am I on a 12.1+ client"

### PartyFrames/PartyFrames.lua
- `CreatePartyContainer()`: Container + mover frame
- `CreateHeader()`: SecureGroupHeaderTemplate config (party/solo)
- `CreateRaidGroupHeaders()` / `LayoutRaidGroupHeaders()` / `HideRaidGroupHeaders()`: the eight per-subgroup raid headers (see Layout System above)
- `ApplyLayout()`: Reconfigures header attributes (point, growth, spacing, sort)
- `WireUpAllButtons()`: Populates `unitButtons[unit] = button`, fires `PartyButtonsWired` once per active header
- `OnRosterOrFlagChanged()`: Repositions center-growth buttons on roster change
- `SetEditMode(enabled)`: Shows/hides edit border + mover

### PartyFrames/UnitButton.lua
- `SquizzFramesUnitButton_OnLoad()`: Resolves child frames via `_G[name.."HealthBar"]` fallback, installs click-casting snippets via `ClickCasting.SetBindingClicks()`, hooks `OnEnter/OnLeave` with `HookScript` (NOT `SetScript` — secure `_onenter` wrap would be replaced)

### Indicators/Indicators.lua
- `HandleIndicators(button)`: Full rebuild from `indicatorList` — wipes customs, creates/updates built-ins, sets `_indicatorsReady = true`. Per-indicator picks AuraEngine vs legacy factory (see AuraEngine section above) rather than a global switch.
- `ApplySettingToOne(button, name, setting, value, value2)`: Single-setting apply (used by `UpdateIndicators` callback) — dispatches to AuraEngine-specific setters (`SetNum`, `SetCastBy`, `SetDurationOffset`, `SetDispelShowAll`, `RefreshSpellList`, `RefreshFilters`, etc.) when the indicator frame exposes them
- `GetPreviewButton()` / `BuildPreview()` / `InitPreviewData()`: Options panel preview
- `I.RemoveAllCustomIndicators`: deliberately **skips** any indicator with `ind._sfAuraEngineBacked` set — AuraEngine-backed customs (color/bar) keep their live `AuraContainer` across the repeated `HandleIndicators` calls a single roster sync routinely triggers, instead of being torn down and rebuilt before the engine finishes binding them

### Indicators/AuraEngine.lua
See the [12.1 AuraEngine Subsystem](#7-121-auraengine-subsystem-auraenginelua-auraengineindicatorslua) section above for the full picture. Key entry points: `AE.CreateContainer`/`AE.RequestContainer`, `AE.MakeInitializer`, `AE.styles`, `AE.RestyleSoon`, `AE.Filter`.

### Indicators/AuraEngineIndicators.lua
`AEI.CreateHealerHotsIndicator`, `AEI.CreateExternalCooldownsIndicator`, `AEI.CreateDefensiveCooldownsIndicator`, `AEI.CreateDebuffsIndicator`, `AEI.CreateCCIndicator`, `AEI.CreateDispelsIndicator`, `AEI.CreateDispelIconsIndicator`, `AEI.CreateCustomColorIndicator`, `AEI.CreateCustomBarIndicator` — each returns a plain wrapper `Frame` that `Indicators.lua`'s generic position/size/frameLevel/alpha dispatch treats identically to every other indicator; the real `AuraContainer` is a child of the wrapper.

**The Dispels overlay and the Dispel Icons are TWO indicators**, split on 2026-08-13. `CreateDispelsIndicator` draws the health-bar tint and nothing else — it has no icon code left, so passing it a `showDispelIcons`-style setting reaches nothing at all (silently; that is why the unit frames showed no dispel icon for a month). Anything wanting symbols must build `CreateDispelIconsIndicator` as a second wrapper and place it itself.

**Exports for callers outside the party indicator system** (the unit frames use all of these — see `Modules/UnitFrames/`):
- `t._sfStyleNS` on both dispel factories — the `AE.styles` namespace, see the hard-rules list in section 7
- `t._sfStrata` / `t._sfLevel` on `CreateDispelIconsIndicator` — the wrapper's tier, which **must be set before the container is requested**, since `extraInit` reads it at button-creation time and 12.1 forbids re-tiering afterwards
- `AEI.ApplyMockDurationText` / `AEI.ApplyMockStackText` — style one mock FontString exactly as `ApplyStyleToRegions` styles the engine-drawn one. They take a style **table, not a key**, so a preview can render settings for a row whose live style does not exist yet. `CreateFallbackIconRow` and `UnitFrames/Preview.lua` both go through them; there is deliberately only one copy of this styling.
- `AEI.PreviewDispelOverlay(host, ctx, t)` / `AEI.DISPEL_TYPES` — paint the dispel overlay for the first enabled type onto a plain mock frame, reusing the real `ApplyDispelSlotStyle`. *Which* type is live is secret and is not a preview-able question.

### UnitFrames/Preview.lua
The 1:1 mock on the Unit Frames options page. Two rules, both load-bearing:

- **It renders through the real code, never a second copy.** Text via `UnitFrames.FormatToken`, bar colour via `ResolveHealthColor`, the cast bar colour via `CastBar.ApplyColor` (a hand-rolled copy ignored "Class Color the Bar", so the preview followed the Bar Color picker while the real bar stayed class-coloured — read as "the cast bar colour doesn't update live", V1.30), the dispel overlay via `AEI.PreviewDispelOverlay`, the aura duration/stack text via the `ApplyMock*Text` pair, and the settings translation via `Dispels.BuildSettings` / `Auras.StyleFields`. A preview carrying its own copy of any of these starts lying the first time the real one changes — and the unit frames' dispel opacity is a live example of why (0-1 here, a percentage on the party indicator; the one hand-rolled translation got it wrong by 100×).
- **It cannot show real aura data**, same constraint as the party Designer: an `AuraContainer` is driven C-side from a real unit and no fake `AuraData` can be injected. Aura rows, dispel icons and duration/stack text are all static mocks laid out to match the real thing.

Things that only exist in the mock (`Preview.Create`) need their own host frame and level — it is a hand-built frame, NOT `UnitFrameButton.xml`, so nothing about its strata/level layering is inherited from the live template.


### Attaching frames (UnitFrames.lua, CastBar.lua, ResourceBar.lua)

Every attach/match target goes through `CastBar.ResolveTarget(key)` and every
dropdown through `CastBar.Targets(kind)` (`"unit"` / `"resource"` / `"cast"`).
A key is a global frame name or `"sqz:<group>"`, a Squizzumables cooldown group
resolved through its public `Squizzumables_GetCDMGroupFrame` (and listed by
`Squizzumables_GetCDMGroupNames` where that exists). Squizzumables PROXIES the
CDM, so for its users Blizzard's `EssentialCooldownViewer` is the wrong frame,
and with its "Hide Blizzard's Cooldown Manager" option it sits at -10000.

- **Cast bar and resource bar anchor LIVE** (`SetPoint` on the target). They
  are plain frames, so that is safe. A cast bar may also ride the resource bar's
  two frames; the resource bar's own list excludes them so it cannot ride
  itself. A cast bar on a hidden resource frame falls back under its unit frame,
  and `ResourceBar.onApplied` re-places it whenever that visibility may change.
- ⚠ **Unit frames are PLACED, not anchored.** They are secure, and anchoring a
  secure frame to another frame makes that frame protected in combat. Squizzumables
  toggles its group containers' visibility mid-fight, so a live anchor would turn
  that into blocked actions blamed on Squizzumables. `PlaceAttached` measures the
  target's edge and places against UIParent instead, and a 0.25s out-of-combat
  watcher (`WatchAttached`, running only while some frame is attached) re-places
  whenever the target's rect changes. Unit frames accept cooldown targets only
  (`CastBar.IsCooldownTarget`).
- ⚠ **Squizzumables groups can anchor to OUR frames** (its `anchorTo = "frame:<name>"`), so loops
  now span two addons' settings. Every attach checks the target's live anchor chain first
  (`CastBar.DependsOn`) and backs off if it leads back to the frame being placed. For the unit
  frames this is not about WoW's cycle error (a placement cannot cycle) but a drift loop: player
  frame on Utility + Utility under the player cast bar would have the watcher chasing its own
  movement down the screen. `UsableAttachTarget` refuses it.

### Nicknames/Nicknames.lua
Replaces the name drawn by the `nameText` indicator. Four layers, resolved highest-first: private `custom[full]` → `custom[base]` → synced `[full]` → `[base]`. **Private always beats remote** — that ordering is what makes accepting broadcast strings tolerable.

- **The contract**: `N:Resolve(unit)` returns a **plain Lua string or nil, never a secret**. `nil` means "couldn't resolve" (disabled / no entry / name currently secret) and the caller falls through to its pre-existing, secret-safe path. The two never blend — see the header comment for why `nickname or name` is a crash, not a convenience.
- **Resolution cache** (`resolveCache`) is keyed by **unit token, not button** — the secure header reassigns tokens across buttons on every re-sort, so per-button caching goes stale silently under `sortByRole`. Wiped on `GROUP_ROSTER_UPDATE`/`PLAYER_ENTERING_WORLD`; per-unit invalidation on `UNIT_NAME_UPDATE`. A secret read is never cached (it's transient).
- ⚠️ **VOLATILE TOKENS ARE NEVER CACHED** (`IsVolatileToken`: `target`, `focus`, `mouseover`, `boss`, `arena`, `nameplate`, `softenemy/friend/interact`, matched by prefix so `targettarget`/`focustarget` follow). The cache's premise — "a token's meaning only changes when the roster does" — holds for group tokens and is **false** for anything repointed by a mouse click. It shipped assuming otherwise and produced this: in a Mythic+, a group member's frames showed **one player's nickname as every target's name for the whole dungeon**, coming right only when the key ended (user report 2026-09-11). Resolve one target that has a nickname on file, memoise it under the key `"target"`, and every later target reads that entry; no roster change happens inside a key, so nothing cleared it until the zone change fired `PLAYER_ENTERING_WORLD`. Not cached is strictly safer than cached-and-wrong: the fallback is the real name, while the failure mode was confidently showing somebody else's.
- **On the standalone unit frames, nicknames are PLAYER-FRAME ONLY**, enforced in `UnitFrames.lua`'s `FormatToken` (`unit == "player"`), not merely by scoping the checkbox. `Resolve` matches on name/realm and knows nothing about tokens, so it answered just as happily for `target` and `boss1`; the option existed on every frame's table defaulting to on, with a control only on the player frame — on by default, invisible, unswitchable. `useNicknames` is set on the player default alone and `Core.lua`'s `MigrateUnitFrameNicknames` purges it elsewhere. Party/raid frames are unaffected: they resolve through the `nameText` indicator, which is the module's actual purpose.
- **Storage is account-wide** at the SavedVariables root (`sv.nicknames`), next to `sv.autoSwitch` — nicknames describe people, not layouts, so they must survive a profile switch. Your own nickname is keyed per-character.
- ⚠️ **`sv.nicknames.mine` is keyed by `F.PlayerFullName()` (`Name-NormalizedRealm`), NOT `ProfileStore.CHAR_KEY`** (`Name - Realm With Spaces`). Two deliberately separate keyspaces: the wire format must match `CHAT_MSG_ADDON`'s `sender`. Mixing them makes every same-realm lookup miss, silently.
- **Sync** uses raw `C_ChatInfo.SendAddonMessage` on prefix `SQF_NICK` (16-char limit — the obvious `SQUIZZFRAMES_NICK` is 17 and would never register). Ownership comes from `sender`, never from the payload, so nobody can set a nickname for someone else.
- **All inbound and outbound strings go through `Sanitize`**, which strips `|T`/`|A`/`|H`/`|c`/`|r` escapes and caps length. Non-optional: `|T` renders an arbitrary texture inside a FontString and `|H` a clickable link, so an unsanitized remote nickname lets any group member draw on your frames. Cell does not do this.
- Refresh reuses the existing `_sfNameUpdater` closure that `CheckNameText` stores on the indicator — no new plumbing.
- `NicknamesPanel.lua` is a **pure shell over the module's public API** (`SetMyNickname`/`SetMineAccountWide`/`SetSyncEnabled`/`SetCustomNickname`/`SetBlacklisted`/`SetEnabled`) — no control writes the SV tables directly, so the panel and `/sf nick` can't drift and every write passes through `Sanitize` exactly once. Registered as the `nicknames` entry in `OptionsFrame.lua`'s `NAV_ITEMS` + `pageHeights`, rebuilt on `OnShow` since the slash commands can change the same data behind its back.

### Indicators/BuiltIn_Update.lua
- Legacy built-in check/update functions, including the manual-scan versions of `healerHots`/`dispels`/`externalCooldowns`/`defensiveCooldowns`/`debuffs`/`ccIndicator` that AuraEngine now supersedes on 12.1 (still load-bearing on pre-12.1 clients — see AuraEngine section above)
- **Shared with pet buttons** (which are outside the indicator system entirely): `BU.CreateBorderIndicator`, `BU.CreateBlinkMarker`, `BU.AttachBlinkBehaviour`, and the `BU.Check*` functions for hover/target highlight and both aggro indicators. `PetButton_ApplyBorders` builds those frames by hand and fakes the one field the Check functions need (`indicator._sfTable = {enabled = ...}`). Settings come from the **Party** indicator list entry in every case — these are "universal" indicators, so a pet matches whatever its owner's frame is set to and there's no second set of options. Nothing re-runs a Check for a pet button automatically: `PetFrames.lua` registers the driving events itself (`PLAYER_TARGET_CHANGED`, `UNIT_THREAT_SITUATION_UPDATE`) and filters `UpdateIndicators` down to the five indicators pet buttons actually build.

**The three text readouts mirror the UNIT FRAMES' text model** (2026-09-17), not
Cell's. `nameText`/`healthText`/`powerText` differ from every other indicator:

- **One format token** (`t.textFormat`) instead of the old
  `showPercentage`/`showCurrent`/`showMax` trio, drawn from the same vocabulary
  the unit frames use (`SquizzFrames.UNITFRAME_TEXT_FORMATS` in
  `UnitFrames_Defaults.lua`). Keep the two lists in step — `powerMax` was added
  to the unit frames so a party readout set to current/max had somewhere to map.
- **One anchor point** (`position-single` token). Storage is still the five-field
  `{point, relativeTo, relativePoint, x, y}` with `relativePoint` written equal
  to `point`, so `ApplyPosition`, the Designer's drag handler and every other
  indicator are untouched, and a profile holding a mismatched pair keeps
  rendering until that dropdown is next used.
- **`maxLength`** (characters, 0 = unlimited) instead of the
  percentage/length/unlimited `textWidth` table. The old widget and its binding
  still exist but are unreachable — see the dormant-scaffolding note under
  *New Indicator SETTING*.

⚠ **`ApplyTextGeometry` sets an explicit pixel width and is NOT a user setting.**
A FontString left to size itself from secret-derived text reports nothing usable
through `GetWidth()`/`GetHeight()`, and that is what the Designer's
drag-highlight and marching-ants read — without the explicit width these three
indicators cannot be dragged at all. Visible length is limited by `CapLength` on
the string, never by clipping the FontString.

### Indicators/Custom_Dispatch.lua
- `Scan(button)`: Iterates auras via `C_UnitAuras.GetAuraDataByIndex`, matches against custom indicator `auras` lookup, calls type-specific `Update` (icons, bars, text)
- Indicator types: `icon`, `bar`, `iconcounter`, `text`, `icons`, `texture`
- Still the only path for `trackByName` customs and `unitButton`-anchor color customs even on 12.1 (see AuraEngine section above for why)

### ClickCasting/ClickCasting.lua
- `GetAttributeKey(modifier, bindKey)`: Normalizes `shift-ctrl-alt-` prefix + `typeN` / `type-KEY`
- `IsGatedAction(bindKey, actionType)`: Detects 12.0.7 click-gate conditions
- `RouteProxyAction(frame, typeAttr, clickbuttonAttr, realAction)`: Sets up click proxy — branches on `SquizzFrames.IS_121` for a second, unrelated 12.1 macro-transport bug (see Click Casting section above)
- `ApplyClickCastings(button)`: Clears old, writes new bindings from profile
- `SetBindingClicks(button)`: Installs secure hover snippet

### Compat/BlizziCompat.lua
- Optional integration with the third-party `BliZzi_Interrupts` addon, which maintains its own hardcoded list of supported party-frame addons and has no public "register a new provider" API. This file monkey-patches `BIT.UnitFrames`'s 4 public functions (`GetPartyFrame`, `GetPartyContainer`, `GetAvailableProviders`, `CountFrameAddons`) from outside Blizzi's own addon folder, so it survives Blizzi's own updates as long as that public surface stays stable, and is a complete no-op if Blizzi isn't installed. Patches itself in on `PLAYER_LOGIN` (both addons' relative load order is unguaranteed).

---

## Data Structures

### Profile Layout (`db.profile.layout.main`)
```lua
{
    width = 100,
    height = 40,
    powerHeight = 4,
    orientation = "vertical",        -- "vertical" | "horizontal"
    growthDirection = "DOWN",        -- "DOWN"|"UP"|"RIGHT"|"LEFT"|"CENTER_H"|"CENTER_V"
    anchorX = 0,                     -- pixels from UIParent center (scaled)
    anchorY = -200,
    spacingY = 0,
    sortByRole = true,
    hideSelf = false,
}
```

### Indicator Entry (in `db.profile.layout.indicators`)
```lua
{
    name = "Name Text",
    indicatorName = "nameText",      -- unique key
    type = "built-in",               -- "built-in" | "custom"
    enabled = true,
    position = {"CENTER", "healthBar", "CENTER", 0, 0},  -- {point, relTo, relPoint, x, y}
    frameLevel = 20,
    -- type-specific fields:
    font = {"Friz QT__", 13, "NONE", true},
    color = {"custom_color", 1, 1, 1, 1},
    textWidth = {"percentage", 0.75},
    -- custom indicators add: auras = {spellID, ...}, trackByName = true, etc.
    -- AuraEngine-relevant fields (built-ins + migrated custom types): num, castBy,
    -- durationVisibility, durationOffset, showIconBorder, dispelShowAll,
    -- dispelTypesEnabled, dispelColors, dispelOverlay, dispelOverlayOpacity,
    -- showDispelIcons, debuffBlacklist, dispellableByMe
}
```

### Click Casting Binding (`db.profile.clickCasting[i]`)
```lua
{
    bindKey = "Left",           -- "Left","Right","Middle","Button4","Button5","E","SCROLLUP",...
    modifier = "shift-ctrl-",   -- normalized ALT-CTRL-SHIFT-META order
    type = "spell",             -- "spell"|"macro"|"item"|"general"|"target"|"focus"|"assist"|"menu"
    action = 20484,             -- spellID, macro text, itemID, or "target"/"focus"/"menu"/"togglemenu"
}
```

### Two "Indicator Defaults" files — do not confuse them
- `Defaults/Indicator_Defaults.lua` — the actual DB-side data: spell-ID lists (`SquizzFrames.defaults.healerSpells`, `.externalCooldowns`, `.defensiveCooldowns`, etc, class-keyed where relevant), `SquizzFrames.GetDefaultCustomIndicatorTable`, and the `/sfhealers` slash command. Loaded early (`Defaults/LoadDefaults.xml`, step 5).
- `Modules/Indicators/IndicatorDefaults.lua` — a thin **re-export accessor** around the above (`IndicatorDefaults.GetDefaultCustomIndicatorTable`, `.GetExternalCooldowns`, `.GetDefensiveCooldowns`, `BUILT_IN_COUNT`), for convenience use by the runtime modules and options panel. Loaded later, inside `Modules/LoadModules.xml`. Edit spell lists in the `Defaults/` file; edit the re-export surface in the `Modules/Indicators/` one.

---

## Key Conventions & Gotchas

### Event/Message Owner Collisions
CallbackHandler keys registrations by **(owner, event)** and keeps exactly **one** handler per pair — a second registration silently REPLACES the first. This applies to `RegisterEvent` as much as `RegisterMessage`. Inside a module, always use `self:RegisterEvent(...)` (the module object is its own owner); `SquizzFrames:RegisterEvent(...)` from within a module puts it on the same owner Core uses and will fight `Core.lua`'s `OnEnable` registrations. Modules are enabled *after* the addon, so the module wins and Core's handler goes dead — with no error. Bit twice on 2026-08-27 (`GROUP_ROSTER_UPDATE`, `PLAYER_ENTERING_WORLD`, both in `PartyFrames.lua`'s `init()`): joining a raid drew the party frames under the raid frames, and zone-in stopped re-resolving spec/group for profile auto-switching. To audit: diff the event names in `Core.lua`'s `self:RegisterEvent` calls against every `SquizzFrames:RegisterEvent` elsewhere.

### Secure Frame Script Hooking
- **DO NOT** use `button:SetScript("OnEnter", fn)` or XML `<OnEnter>` on secure buttons — it **replaces** the secure `_onenter` wrap, breaking click-casting.
- **USE** `button:HookScript("OnEnter", fn)` — runs alongside the secure wrap.
- The same rule applies, more strictly, to 12.1 AuraContainer-managed buttons: **no `SetScript`/`HookScript` at all**, not even hooked — see the AuraEngine section above.

### Secret Numbers (Tainted Values)
- `UnitHealth`, `UnitHealthMax`, `UnitPower`, `UnitGetTotalAbsorbs` can return "secret numbers" (tainted).
- **Arithmetic on them taints** → use `SetMinMaxValues`/`SetValue`/`SetFormattedText` directly (C-level handles secrets).
- For preview/fake data: `pcall(UnitHealth, "player")` + `pcall(function() return val + 0 end)` to sanitize.
- On 12.1, **aura data is secret too** while auras are secret (combat/encounters) — this is the whole reason the AuraEngine subsystem exists; see section 7 above. Don't try to extend the `pcall`-sanitize pattern to auras — there is no safe manual read, only the managed AuraContainer API.

### Secret STRINGS (not just numbers)

A string can be secret too, and the rules are narrower than for numbers.
`AbbreviateNumbers()`'s return inherits the taint of what it was handed, and
`UnitName`/`F.UnitFullName` pass a secret straight through so `SetText` can
consume it C-side.

What is safe on a secret string, confirmed in `BuiltIn_Update.lua`'s text
builders:

- **nil-checks** (`if s then`) — safe.
- **concatenation** (`a .. " / " .. b`) — safe.
- **handing it to a widget setter** (`SetText`, `SetValue`, `SetMinMaxValues`) — safe.

What throws:

- **comparison**, including `s ~= ""` — "attempt to compare a secret string
  value". This is why the text builders track presence with plain booleans set
  from nil-checks instead of testing the string.
- **measurement or slicing** (`#s`, `s:sub()`, `strlenutf8`) — same class.

**Do not "sanitise" a secret you only need to pass along.** `Secrets.SafeString`
and friends return `nil` for a secret by design, so laundering a value that was
only ever going to be handed to a setter destroys it. Squizzumables hit exactly
this: a mirrored buff bar's fill worked while its countdown stayed blank,
because the text was passed through `SafeString` first. The fix is to go from
getter to setter **in one expression** — `dest:SetText(src:GetText())` — so the
value never lands in Lua at all.

**Where an operation genuinely is needed, gate it and degrade.** `CapLength`
(character cap on text indicators) skips truncation entirely when
`F.IsValueNonSecret` fails, and `CheckNameText` skips the group-number prefix
the same way. The in-code comment states the principle: *losing the group number
beats losing the name*.

### Frame Opacity (General page, V1.30)

Five blanket sliders — party, raid, unit frames, pet frames, tank tracker —
stored as `opacity` (0-1) on `layout.main`, `layout.raid`, `unitFrames`,
`petFrames` and `tankTracker`. A `FrameOpacityChanged` message re-applies alpha
only, with no relayout. The rule that shaped it: **range fading writes the
BUTTONS' own alpha** (`UpdateRangeAlpha`, party and pet buttons alike), so the
blanket alpha must sit one level up or the two overwrite each other. A parent's
alpha multiplies into its children's, so they compose.

- Party/raid: on `SquizzFramesPartyFrame`, picked per active layout, applied at
  the top of `ApplyLayout` — ahead of its combat guard, because `SetAlpha` is not
  protected and a mid-fight party-to-raid switch should take the raid value.
- Pets: pet buttons are **parented to `SquizzFramesPetOpacity`**, a full-screen,
  mouse-transparent holder that is sized once before any secure child exists and
  never moved or hidden afterwards. Not a container in the "never reparent a pet
  button under a container" sense — nothing ever positions against it.
- Unit frames: each frame AND its cast bar (a separate UIParent child).
- Tank tracker: each real frame; the options preview is left opaque.

### Colour picker alpha is NOT inverted on Retail

`Widgets.lua`'s `CreateColorPicker` carried a `1 - x` on the picker's alpha from
the old `OpacitySliderFrame` API, which made the 10.2.5+ picker's transparency
slider run backwards (fixed V1.30). On Mainline, `GetColorAlpha()` and
`info.opacity` are plain alpha — AceGUI's own ColorPicker only inverts when
`WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE`, which is the confirmation. Cancel now
restores from the values captured at open, not the picker's `previousValues`.

### Text colour on nameText/healthText/powerText

`color-class` / `color-power` checkboxes plus a `textColor` swatch (V1.30) all
write the one `t.color`; each resyncs the others (`SyncTextColorWidgets`). The
custom colour is remembered separately in `t.customTextColor`, so ticking Class
and back restores it rather than resetting to white, which is what the
checkboxes used to do.

### Font Resolution
- Stored font names may be LSM keys (`"Friz QT__"`) or paths (`Fonts\FRIZQT__.TTF`).
- Use `ResolveFontFile(fontFile)` in Utils/Indicators — checks path prefix, then LSM hash table, falls back to `Fonts\FRIZQT__.TTF`.

### Anchor Point Resolution
- `relativeTo` in position tables can be: `"button"` (or `0`/`nil`), `"healthBar"`, or a frame.
- `ResolveRelative(button, relativeTo)` normalizes this.
- `relativePoint` can be Cell's `"justify"` → `ResolvePoint` sanitizes to valid WoW anchors.

### Scale & Position
- Container scale = `profile.appearance.general.scale` (default 1.0)
- Saved `anchorX/anchorY` are **raw screen pixels from center** (not divided by scale)
- On apply: `SetPoint("CENTER", UIParent, "CENTER", anchorX/scale, anchorY/scale)`
- Drag calculates offset in UIParent coords, saves raw pixels, reapplies with scale compensation.

### Event Bucketing
- Indicators uses `ScheduleButtonUpdate(button, event)` → `BuiltIn.HandleEvent` + `CustomDispatch.Scan` (for `UNIT_AURA`)
- Multiple rapid events coalesce via per-button timer (not shown but pattern is standard)
- AuraEngine-backed indicators don't participate in this at all — they have no `UNIT_AURA` handler of their own; the engine drives them directly once a container/group/slot exists

---

## Adding New Features

### New Built-in Indicator (legacy/pre-12.1-compatible)
1. Add default config to `Defaults/Indicator_Defaults.lua` (in `profile.layout.indicators`)
2. Add `indicatorIndices` entry in `Defaults/Layout_Defaults.lua`
3. Implement `CreateXxxIndicator(button, t)` in `Indicators/IndicatorWidgets.lua`
4. Add `SetupXxxIndicator(button, t)` + `CheckXxxIndicator(button)` in `Indicators/BuiltIn_Update.lua`
5. Register events in `Indicators:OnEnable()` if needed

### New AuraEngine-backed Built-in (12.1, combat-reliable aura tracking)
Only needed if the indicator tracks live aura presence/duration and must stay accurate in combat (the exact problem AuraEngine solves — see section 7). If it doesn't touch auras, use the plain path above instead.
1. Implement `AEI.CreateXxxIndicator(button, t)` in `AuraEngineIndicators.lua`, following an existing example close to what you need: `CreateDebuffsIndicator`/`CreateCCIndicator` for a plain icon grid, `CreateDispelsIndicator` for a health-bar overlay driven by bare (`noRegions`) slots, `CreateCustomColorIndicator`/`CreateCustomBarIndicator` for single-slot presence-driven visuals
2. Register a style in `AE.styles` and build the `initializeFrame` via `AE.MakeInitializer` (or a bare `applyExtra` function for `noRegions` styles) — do all region creation/registration there, nothing later
3. Wire it into `Indicators.lua`'s `HandleIndicators` dispatch with a legacy fallback (`AEI.CreateXxxIndicator(button, t) or BuiltIn.CreateBuiltInIndicator(button, t)`), and into `ApplySettingToOne` for any settings the wrapper exposes setters for
4. Add a Designer-preview fallback (`CreateFallbackIconRow` for icon-grid types, or a plain texture for overlay types) — the real container never gets real data in preview, see section 7
5. Re-read the "hard rules" list in section 7 before writing any code that touches a slot/group button outside `initializeFrame`/`extraInit`

### New Custom Indicator Type
1. Add factory in `IndicatorWidgets.lua` → `CreateCustomIndicatorFrame`
2. Add dispatcher case in `Custom_Dispatch.lua` → `DispatchIndicatorUpdate`
3. Add options UI in `IndicatorsPanel.lua`
4. If it's aura-presence-driven (like `color`/`bar`) and combat reliability matters, consider an AuraEngine-backed variant too — see `Indicators.lua`'s existing `type == "color"`/`type == "bar"` branches for the pattern (legacy factory stays the fallback for `trackByName` and pre-12.1)

### New Indicator SETTING (a control on an existing indicator)

Adding a control is **five places, not one**, and missing any of them fails
silently rather than erroring — the control simply never appears, or appears and
does nothing, or the page mis-sizes and clips its last row.

1. **`IndicatorDefaults.lua`** — add the token to that indicator's settings list.
   This is the only thing that makes the control exist.
2. **`IndicatorWidgets.lua`** — write `CreateSetting_Xxx(parent)` and register it
   in the `builders` table, **or** add a branch to the dispatcher in
   `SquizzFrames.CreateIndicatorSettings` if the token carries a parameter.
3. **`IndicatorsPanel.lua`'s `names` loop** — only if the token carries a
   parameter (see below).
4. **`IndicatorsPanel.lua`'s binding block** — `SetDBValue` to populate from the
   DB, `SetFunc` to write back and `FireUpdate`. Without this the widget renders
   and is inert.
5. **`IndicatorsPanel.lua`'s `TOKEN_HEIGHTS`** — see the raw-token rule below.

And if the setting has to apply live, **`Indicators.lua`'s `ApplySettingToOne`**
needs a branch too. Several settings shipped storing correctly and doing nothing
visible until an unrelated event happened to refresh the indicator —
`showPercentage`/`showCurrent`/`showMax` sat like that, and the in-code comment
there records it.

**There is NO generic `token:param` splitter.** Every parameterised token
(`num:5`, `checkbutton:showGroupNumber`, `font1:stackFont`, `textFormat:health`)
has its own explicit `token:match("^…")` branch in BOTH the dispatcher and the
`names` loop, and the parameter is recovered again in the binding block
(`token:match("^checkbutton%d*:(.+)")`). Adding a parameterised token without
touching all three leaves it falling through to `CreateSetting_Tips`, which
renders the raw token string as a label.

**`TOKEN_HEIGHTS` is keyed by the RAW token**, not the normalised name. So
`textFormat:health` and `textFormat:power` each need their own entry; a bare
`textFormat` key is dead. The file's own comment records the cost of getting
this wrong: `font1`/`font2` had bare keys while real lists always carry
`:stackFont`/`:durationFont`, so eleven indicator panels silently undercounted
by 43px and clipped their bottom row.

**`settingWidgets` keys are a SHARED NAMESPACE — one cached frame per key.**
Two builders using the same key share one frame, so the second indicator to
render wins and the first shows the other's values. `CreateSetting_PowerFormat`
is a live example of the trap: it is `= CreateSetting_HealthFormat`, so both
cache under `"healthFormat"`. Give every widget its own key
(`"position-single"` is distinct from `"position"` and `"position_noHCenter"`
for exactly this reason), and pass per-instance data in at bind time through
`SetDBValue(key, value)` the way the checkbutton and textFormat widgets do —
the builder dispatch passes no arguments, so a shared widget cannot know which
indicator it is serving at construction.

**Dormant scaffolding is easy to create and hard to notice.** A widget can be
written, registered in `builders`, given a `TOKEN_HEIGHTS` entry AND bound in
the panel while being referenced by *no* settings list — it is then completely
unreachable. `healthFormat`/`powerFormat` are in that state today. Before
writing a new widget, grep `IndicatorDefaults.lua` for the token; you may be
re-inventing something already half-built.

### New Module
1. Create `Modules/MyModule/MyModule.lua` with `SquizzFrames:NewModule("MyModule", "AceEvent-3.0")`
2. Add to `Modules/LoadModules.xml`
3. Register messages on `self` (not `SquizzFrames`)

---

## External Dependencies (Embedded)

| Library | Purpose |
|---------|---------|
| Ace3 (Addon, Event, Timer, DB, Config, Hook, Comm, Console, Locale, GUI) | Core framework |
| LibStub | Library loader |
| CallbackHandler-1.0 | Event/callback bus |
| LibSharedMedia-3.0 | Fonts, textures, sounds, borders |
| LibCustomGlow-1.0 | Button glow effects (proc, action bar style) |
| LibDeflate | Compression (for serialization) |
| LibSerialize | Table serialization |
| LibRangeCheck-3.0 | Unit range checking (out-of-range alpha) |

---

## Version Compatibility

- **Target**: WoW 12.1 — `## Interface: 120100`. 12.0.7 was dropped from the TOC on 2026-08-21: that client no longer exists, so listing it only advertised support the addon could not actually deliver (and made CurseForge tag every upload as 12.0.7-compatible). The pre-12.1 code paths are still in the tree but unreachable — see the dead-code note in section 7.
- **12.1 code paths**: rather than a separate branch/release, 12.1-only code paths live in this codebase gated at runtime by `SquizzFrames.IS_121` (`Utils.lua`, build number `>= 120100`) rather than by TOC/`.toc`-version branching. This covers the AuraEngine subsystem (section 7), and the click-casting proxy transport fix. These are **active** on a 12.1 client and inert on 12.0.7.
- Uses modern APIs: `C_AddOns.GetAddOnMetadata`, `C_Spell.GetSpellName`, `C_Spell.GetSpellInfo`, `C_UnitAuras`, `C_Item.IsUsableItem`
- Fallback globals provided in Utils/Core for older API compat

---

## Memory/Performance Notes

- **No periodic OnUpdate loops** for the legacy pipeline — event-driven via AceEvent + secure header. The one deliberate exception is the Phased Icon's 1s `C_Timer` ticker (`BuiltIn_Update.lua`), which exists because `UnitPhaseReason` is blind past ~250 yards and no event fires when that changes — it self-cancels as soon as a pass finds no enabled `phasedIcon`, and `CheckPhasedIcon` re-arms it. The second is the unit-frame attach watcher (`UnitFrames.lua`, 0.25s, hidden unless a frame is attached to a cooldown group, idle in combat); see *Attaching frames*
- **Indicator updates** batched per-button via `ScheduleButtonUpdate`
- **Secure header** manages child visibility via `RegisterUnitWatch` (no manual show/hide needed for roster changes)
- **Custom aura scanner** iterates `C_UnitAuras.GetAuraDataByIndex` — efficient for party frames (max 5 units × ~40 auras)
- AuraEngine (12.1) has two of its own lightweight `OnUpdate` drivers, both self-hiding when idle: the restyle scheduler (`AE.RestyleSoon`'s ticker, budgeted 200 buttons/frame) and the slot-refresh ticker (`AuraEngineIndicators.lua`'s `slotRefreshTicker`, one `container:UpdateAllAuras()` per registered slot-wrapper every 1.5s, self-pruning hidden wrappers)

---

## Useful Search Patterns

| Pattern | Finds |
|---------|-------|
| `InCombatLockdown` | Combat-safe guards |
| `Fire\(` | Cross-module messages |
| `RegisterMessage` | Module message handlers |
| `SetAttribute` / `GetAttribute` | Secure frame attributes |
| `HookScript` | Safe script hooking on secure frames |
| `pcall.*UnitHealth` | Secret number handling |
| `indicatorList` / `indicatorIndices` | Indicator registry |
| `clickCasting` | Click-casting bindings |
| `SizeContainerToButtons` | Layout sizing logic |
| `growthDirection` / `orientation` | Layout direction handling |
| `IS_121` | Every 12.1-vs-pre-12.1 branch point (AuraEngine, click-casting proxy) |
| `AddAuraGroup` / `AddAuraSlot` | AuraContainer group/slot declarations |
| `initializeFrame` / `extraInit` | AuraEngine button-creation callbacks — the only place button API calls are legal once secret |
| `_sfAuraEngineBacked` | Marks a custom indicator whose live container must survive repeated `HandleIndicators` rebuilds |
| `AE\.` | AuraEngine.lua's public API surface (`AE.CreateContainer`, `AE.RequestContainer`, `AE.styles`, `AE.RestyleSoon`, `AE.Filter`) |
| `_sfStyleNS` | Callers claiming their own `AE.styles` namespace, so two owners' settings can't overwrite each other |
| `^local function Migrate` | Every profile migration in `Core.lua`; read these before changing any shipped default |
| `ApplyMock` | The shared preview text stylers — anything mocking engine-drawn duration/stack text |
| `IsVolatileToken` | The unit tokens whose meaning changes during play; never memoise anything against one |
