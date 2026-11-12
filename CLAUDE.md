# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Blizzard UI source

Blizzard's UI source is at C:\dev\wow-ui-source. Search it to verify any API, event or mixin before using it. That clone is the `live` (retail) branch; for WoW Forever use C:\dev\wow-ui-source-forever (`forever` branch) instead.

## Project Overview

**SquizzFrames** is a World of Warcraft (Mainline/Retail, API 12.1.5, plus a WoW Forever port) unit frame addon. It began as party frames and now also covers raid frames, pet frames, standalone unit frames (player/target/ToT/focus/focustarget/boss/arena), a resource bar, a tank tracker, party cooldowns and nicknames. It uses the **Ace3** framework and follows patterns from **DandersFrames** and **EllesmereUI** for secure frame handling, indicator systems and click-casting.

⚠️ **Do not use Cell as a reference.** It is cited historically throughout this file for the shape of the indicator system, which is still accurate, but its code is outdated for 12.1 and following it will lead you wrong on anything aura-related. Prefer, in order: Blizzard's own source (`Gethe/wow-ui-source` — **check the branch**, `ptr` and `ptr2` are different patches), then DandersFrames, then EllesmereUI.

- **AddOn Name**: SquizzFrames
- **SavedVariables**: `SquizzFramesDB` (our own `ProfileStore.lua` profiles; AceDB-3.0 is still embedded and loaded by `Libs/LoadLibs.xml` but no code calls it)
- **Slash Command**: `/sf` (`/squizz` is registered by LibSquizzShell and opens the combined window, see *Options window*)
- **Key Bindings**: Click-casting via secure attributes
- **12.1 AuraContainer path is the only path**: the `SquizzFrames.IS_121` / `IS_1215` gates and the pre-12.1 fallbacks they selected were deleted in 2.0. See [12.1 AuraEngine Subsystem](#7-121-auraengine-subsystem-auraenginelua-auraengineindicatorslua) below before touching anything aura-related.

---

## Architecture

### Core Structure

```
SquizzFrames/
├── Core.lua                 # Addon bootstrap, Ace3 lifecycle, DB, module registry
├── Utils.lua                # Shared helpers (colors, numbers, spells, click-cast spells, F.SlashHandler, the SquizzFrames.IS_FOREVER client flag)
├── ProfileStore.lua         # Profile storage (replaced AceDB-3.0 on 2026-08-06): flat SavedVariables table, DeepFillDefaults, the "Default" draft/Save model, one-time MigrateFromAceDB. See section 6
├── SquizzFrames.toc         # Load order: Libs → Locales → Core → Utils → ProfileStore → Defaults → Media → HideBlizzard → Options → Modules → Compat
├── Libs/                    # Embedded libraries (Ace3, LibSharedMedia, LibCustomGlow, LibDeflate, LibSerialize, LibRangeCheck) + our own LibSquizzGrid-1.0 (Edit Mode grid/snapping), LibSquizzTheme-1.0 (the theme) and LibSquizzShell-1.0 (the options window), each a copy shared with Squizzumables
├── Media/                   # Fonts, textures, icons, flipbooks
├── Defaults/                # DB-side data: Appearance, Layout, PetFrames, UnitFrames, ClickCasting, TankTracker and Indicator defaults, plus Indicator_Spells_Forever.lua (the Forever spell lists)
├── Locales/                 # enUS.lua (AceLocale-3.0)
├── Compat/
│   ├── BlizziCompat.lua     # Optional integration: registers SquizzFrames with BliZzi_Interrupts' unit-frame resolver
│   └── ForeverCheck.lua     # TEMPORARY /sf forevercheck diagnostic for the Forever port: prints which APIs the running client really has, keeps reports in SquizzFramesDB.foreverCheck. Delete once the port is finished
├── HideBlizzard.lua         # One master switch (general.hideBlizzardFrames) hiding every Blizzard frame we replace, gated per-frame on ours being enabled
├── .tools/                  # check-xml.sh (after any XML edit), check-keys.sh + keys.pl (no 1.x setting silently dropped, see Releasing), make-shapes.ps1 / make-dash.ps1 (generate Media art)
└── Modules/
    ├── LoadModules.xml      # Loads EVERY module below except Options/, whose files the .toc loads directly (they must exist before the panels here)
    ├── PartyFrames/         # Secure group header + unit buttons (party1-4 + player)
    │   ├── PartyFrames.lua  # Layout, anchoring, growth, edit mode, sizing. Publishes PartyFrames.shared (private helpers for the split-out files; anything assigned after load goes over as a GETTER, e.g. GetPartyFrame)
    │   ├── PartyButtons.lua # Per-button health/power/role/status text + AFK/Dead timers, /sfdrinktest; moved out in 2.0. Publishes PartyFrames.buttons; same-named FORWARDERS stay in PartyFrames.lua (UpdateHealth/Power/Status, UpdateButtonAll, UpdateAllButtons, Sync[All]StatusTextAlpha)
    │   ├── PartyPreview.lua # The Layout page's mock party/raid grid (SetPreviewMode etc.); moved out in 2.0
    │   ├── PartyRange.lua   # Out-of-range fading (range poll, checker, alpha); moved out in 2.0. Publishes PartyFrames.range; PartyFrames.lua keeps same-named FORWARDERS (RebuildRangeChecker/UpdateRangeAlpha/ResetRangeAlpha/RefreshRangePolling) so call sites and event registrations are unchanged
    │   ├── LayoutPanel.lua  # The "layout" options page; split out of OptionsFrame 2026-09-10 (publishes IsRaidTab for the shared group preview)
    │   ├── UnitButton.lua   # Secure button OnLoad, click-casting hooks
    │   └── UnitButton.xml   # SecureUnitButtonTemplate + health/power bars, texts, icons
    ├── Indicators/          # Cell-style indicator system (built-in + custom) + 12.1 AuraEngine
    │   ├── Indicators.lua        # Registry, runtime, ApplySettingToOne, preview, built-in-vs-AuraEngine dispatch
    │   ├── AuraEngine.lua         # 12.1 ONLY: shared AuraContainer/AddAuraGroup/AddAuraSlot engine (styles, combat-safe container creation, restyle scheduler)
    │   ├── AuraEngineIndicators.lua # healerHots/externalCooldowns/defensiveCooldowns/debuffs/ccIndicator + custom color/bar, built on AuraEngine. Publishes AEI.shared (ExtractSize) for the split-out file
    │   ├── AuraEngineDispels.lua # Dispels overlay (+ pulse/ants animations) and Dispel Icons; moved out of AuraEngineIndicators.lua in 2.0. Loads right after it and publishes HealthBottomInset/FrameBorderInset/AnchorHealthFillOverlay on AEI
    │   ├── AuraEngineCustom.lua # AuraEngine-backed custom "color" and "bar" indicators (CreateCustomColorIndicator/CreateCustomBarIndicator, slot refresh cycle); moved out of AuraEngineIndicators.lua in 2.0. Loads after AuraEngineDispels.lua; reaches its three health-bar helpers through same-named forwarders to AEI.*
    │   ├── AuraButtonTemplate.xml # Empty virtual "CustomAuraButtonTemplate" — must exist by this exact name for AuraContainer buttons to create at all
    │   ├── BuiltIn_Update.lua    # Built-in create/check/update functions for everything that is not AuraEngine-backed (texts, icons, highlights, borders, missingBuffs...). The scan-based versions of the six AuraEngine built-ins were deleted in 2.0
    │   ├── IndicatorDefaults.lua  # Module-side re-export accessor for Defaults/Indicator_Defaults.lua (NOT the same file — see Data Structures)
    │   ├── IndicatorWidgetsBase.lua # Setting-widget building blocks (SF_Create* wrappers, settingWidgets cache, anchorPoints, CreateLabel/LayoutDropdownRow); moved out of IndicatorWidgets.lua in 2.0. Loads right before it and publishes SquizzFrames.IndicatorWidgetsBase, which IndicatorWidgets.lua imports under the same local names
    │   ├── IndicatorWidgetsSpells.lua # Spell-list settings (CreateSetting_Auras, DebuffBlacklist, BigDebuffCC, the BuiltIn* checklists); moved out in 2.0. Loads between Base and IndicatorWidgets.lua, publishes SquizzFrames.IndicatorWidgetsSpells, imported under the same names
    │   ├── IndicatorWidgetsDispels.lua # Dispels settings (type toggles/colours, overlay, opacity, gradient, ants) + the shared filter checklist (DispelFilters/TargetCounterFilters/RoleFilters) and TextScale; moved out in 2.0, same import arrangement (SquizzFrames.IndicatorWidgetsDispels)
    │   ├── IndicatorWidgets.lua   # Custom indicator frame factories (legacy scan-based) + shared setting widgets
    │   ├── Custom_Dispatch.lua    # Legacy aura scanner + per-type dispatch (still used for trackByName customs and text/icon customs)
    │   ├── IndicatorsPanel.lua    # Options UI for indicators
    │   └── GroupPreview.lua       # Read-only window showing a whole mock party (5) or raid (20) at the profile's real sizes, to judge indicator spacing; consumes IndicatorsPanel's CreateMockUnitButton, so it loads after it
    ├── Grid/
    │   ├── SnapGrid.lua     # Connects SquizzFrames to LibSquizzGrid: storage, EditModeChanged hook, SnapTarget/SnapDelta/SnapClear helpers every mover calls. Loaded FIRST in LoadModules.xml
    │   └── EditMover.lua    # The 2.0 mover look, same as Squizzumables' (a copy, not a library): accent box + name, hover, click-to-select, arrow-key nudge. SquizzFrames.EditMover.Show/Hide/SetLabel/Select
    ├── Welcome/            # First-run setup + per-version release notes
    │   ├── Welcome.lua         # The update note; RELEASE_NOTES table is a manual per-release step (see Releasing). Must read SquizzFramesDB BEFORE Core's OnInitialize creates the profile tree (hadSavedVariables)
    │   └── Setup.lua           # Four-step first-run setup (role, suggested extras, placing frames, theme); /sf setup re-runs it. The suggested set is pre-ticked, never forced
    ├── PartyCooldowns/      # Each group member's defensive/external/group cooldowns as icons on their party frame. Party and solo only, never raid. See *PartyCooldowns/PartyCooldowns.lua* under Important Files
    │   ├── PartyCooldownsData.lua         # Retail spell table, read from the live build's DB2 exports (cd, buffs, talent, mods, specMods)
    │   ├── PartyCooldownsData_Forever.lua # The Forever table, swapped in under IS_FOREVER
    │   ├── PartyCooldowns.lua             # Engine: sensor containers, secret start-time latch, icons, talent inspection, /sfcdcheck
    │   └── PartyCooldownsPanel.lua        # Options page ("partyCooldowns" page key); sub-tabs + preview; shell over profile.partyCooldowns through PC.Get
    ├── TankTracker/         # Per-tank frame: incoming debuffs above, defensives below; own AuraEngine rows, plain (non-secure) frames. Debuff filter defaults to the duration-bounded `encounter` preset, NOT the boss/role flags — see section 7 on why flag presets render empty rows in untagged encounters
    │   ├── TankTracker.lua      # Engine: tank discovery (secret-safe, fail-closed on identity), stacking, aura rows, mover
    │   ├── TankTrackerPreview.lua # 1:1 options mock; IS a real tank frame (CreateTankFrame/DressFrame/PlaceRow/StyleFields), only the icons are static
    │   └── TankTrackerPanel.lua # Options page ("tankTracker" page key); General/Debuffs/Defensives sub-tabs + pinned preview; shell over profile.tankTracker
    ├── Nicknames/           # Display-name replacement (private list + group-synced)
    │   ├── Nicknames.lua       # Storage, secret-safe resolution cache, AceComm-free addon-message sync, /sf nick
    │   └── NicknamesPanel.lua  # Options page ("nicknames" page key); pure shell over the module's public API
    ├── UnitFrames/          # Standalone single-unit frames (player/target/ToT/focus/focustarget) plus two STACKS, boss1-5 and arena1-5 (V1.37) — cast bars, portraits, auras, icons and absorbs all present. A stack shares ONE settings table (unitFrames.boss / .arena) and is placed off its first frame: STACK_UNITS / StackKey / StackIndex / StackOffset in UnitFrames.lua, STACK_TABS in the panel. A third stack is a new STACK_UNITS entry + defaults table + tab, not new code paths. Arena's pre-match view (spec before the gates) is `ArenaPrep.lua`: plain UIParent frames SetAllPoints'd over the hidden secure arena frames, shown by Blizzard's own rule (arena match neither engaged nor complete) — needed because hiding Blizzard's CompactArenaFrame hides its pre-match frames too. Enemy trinkets / CC / DRs are UNREADABLE to addons (GetArenaCrowdControlInfo secret when LoC is restricted; the DR event is SecretPayloads), so ArenaPrep BORROWS Blizzard's CcRemoverFrame / DebuffFrame / SpellDiminishStatusTray and anchors them beside our frames: HideBlizzard ADOPTS CompactArenaFrame (alpha 0, member buttons mouse-off, never reparented) instead of hiding it while `arena.borrowBlizzard` is on, and PlacePieces re-runs after Blizzard's UpdateLayout (which re-anchors the trinket/debuff every pass). ignoreParentAlpha does the rest: Blizzard set it on the trinket/debuff/cast bar, we set it on the DR tray and clear it on Blizzard's cast bar (ours is drawn)
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
    │   ├── ArenaPrep.lua       # Arena pre-match view + the borrowed Blizzard trinket/CC/DR pieces (described above). Loads after UnitFrames.lua: uses its FindButtonByUnit and hooks ApplyLayout
    │   ├── UnitFrameButton.xml # SquizzFramesUnitFrameTemplate
    │   ├── UnitFramesPanel.lua # Options page ("unitFrames" page key); shell over profile.unitFrames. Publishes Panel.shared (AnchorItems/Changed/GetConfig/SubTabs) for the split-out section files
    │   └── UnitFramesResourcePanel.lua # The page's Resources section (resource bar General/Power/Resource sub-tabs); moved out in 2.0. Loads right after the page; publishes Panel.SecResource behind a same-named forwarder, reaches rebuildFields through Panel.Rebuild
    ├── PetFrames/           # Party/raid pet frames (attached to the owner's button, or a free-floating group), plus the standalone player's-own-pet frame
    │   ├── PetFrames.lua       # Layout/anchoring/edit mode, roster + unit events, RefreshBorders
    │   ├── PetButton.xml       # The secure pet button template
    │   ├── PetButton.lua       # Secure pet button OnLoad + PetButton_ApplyBorders
    │   └── PetFramesPanel.lua  # Options page ("petFrames" page key); split out of OptionsFrame 2026-09-10 to escape its Lua ceilings
    ├── ClickCasting/        # Cell-style click-casting on SecureActionButtonTemplate
    │   ├── ClickCasting.lua   # Binding parser, attribute writer, click proxy for gated actions (reached by a "/click <proxy>" macro)
    │   └── ClickCastingPanel.lua # Options UI
    └── Options/             # Loaded by the .toc, NOT by LoadModules.xml, in this order
        ├── Options.lua      # AceConfig fallback table (for /sf)
        ├── Tooltips.lua     # ONE table of hover text for every setting, keyed "<page key>|<section>|<label>", "<section>|<label>" or "<label>". Widgets.lua looks a control's tip up as it is built and hands it to search
        ├── Motion.lua       # SquizzFrames.Motion: short fades/pops for our own PLAIN frames (never a secure frame); General > Reduce Motion (general.reduceMotion) makes them instant
        ├── Widgets.lua      # Custom styled widgets (sliders, dropdowns, checkboxes, buttons)
        ├── ProfileTransfer.lua # Import/export strings (see section 6)
        └── OptionsFrame.lua # Registers the pages with LibSquizzShell (the window itself, shared with Squizzumables) and builds General + Profiles; Edit Mode toggle state
```

### Load Order (from `.toc`)

1. **Libs/LoadLibs.xml** — LibStub → CallbackHandler → Ace3 (Addon, Event, Timer, DB, **GUI, then Config**, Hook, Comm, Console, Locale) → LibSquizzGrid, LibSquizzTheme, LibSquizzShell → LibSharedMedia, LibCustomGlow, LibRangeCheck, LibDeflate, LibSerialize. AceGUI before AceConfig is deliberate: AceConfigDialog's main chunk calls `LibStub("AceGUI-3.0")` at load (the file's comment has the story)
2. **Locales/LoadLocales.xml** — enUS
3. **Core.lua** — Addon object, DB, module registry, slash commands
4. **Utils.lua** — Shared helpers, sets `SquizzFrames.IS_FOREVER`
5. **ProfileStore.lua** — Profile storage (`ProfileStore:Init` runs later, from Core's `OnInitialize`)
6. **Defaults/LoadDefaults.xml** — Appearance, Layout, PetFrames, UnitFrames, ClickCasting, TankTracker, Indicator defaults, `Indicator_Spells_Forever.lua`
7. **Media/LoadMedia.xml** — Fonts, textures
8. **HideBlizzard.lua** — Hide default frames
9. **Modules/Options/** — `Options.lua` (AceConfig fallback table) → `Tooltips.lua` → `Motion.lua` → `Widgets.lua` → `ProfileTransfer.lua` → `OptionsFrame.lua`
10. **Modules/LoadModules.xml** — every module, in this order: Grid (`SnapGrid.lua` first, then `EditMover.lua`), PartyFrames, PetFrames, UnitFrames (`CastBar.lua` … `UnitFrames.lua` → `ArenaPrep.lua` → the two panel files), ClickCasting, Indicators (`Indicators.lua` → `IndicatorDefaults.lua` → `AuraEngine.lua` → `AuraEngineIndicators.lua` → `AuraEngineDispels.lua` → `AuraEngineCustom.lua` → `BuiltIn_Update.lua` → `Custom_Dispatch.lua` → `IndicatorWidgetsBase.lua` → `IndicatorWidgetsSpells.lua` → `IndicatorWidgetsDispels.lua` → `IndicatorWidgets.lua` → `IndicatorsPanel.lua` → `GroupPreview.lua`), Nicknames (after Indicators — it refreshes names through `nameText`'s `_sfNameUpdater`), Welcome, TankTracker, PartyCooldowns (data files before the engine)
11. **Compat/BlizziCompat.lua** — Optional third-party integration, patches itself in on `PLAYER_LOGIN` if `BliZzi_Interrupts` is present
12. **Compat/ForeverCheck.lua** — Temporary Forever-port diagnostic

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
- 12.1 AuraEngine has its own parallel combat-safe patterns: `AE.RequestContainer` creates containers immediately, combat included (legal since 12.1 PTR 7, build 68914; it queued them to `PLAYER_REGEN_ENABLED` until 2026-11-01, which left mid-fight joiners without aura indicators), and `AE.RestyleSoon`'s time-sliced restyler simply stops ticking (not errors) while `InCombatLockdown()` and resumes on its own after combat

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
  - ⚠️ **A `Check*` function must be AUTHORITATIVE — decide show AND hide, every pass.** `HandleIndicators`' generic apply loop does `if t.enabled then indicator:Show() else indicator:Hide() end` (`Indicators.lua:517`) on **every** rebuild, and `ApplySettingToOne`'s "enabled" branch does the same. A Check that only hides under particular conditions therefore lets any rebuild resurrect whatever the indicator last drew. `pingMarker` shipped that way for a day: its textures kept the atlas from the last real ping, so a roster sync re-showed a ping nobody had sent, and nothing could clear it because the expiry had already nil'd the very fields the hide conditions tested — `/reload` only. Every other built-in survives that line by deciding outright. If an indicator can hold visual state, blank it on hide too, so a stray `Show()` can only ever produce an empty frame.
- **Custom indicators** created by user via options; stored in `profile.layout.indicators` array
- **Runtime**: `indicatorList` = current profile's indicator array
- **Per-button**: `button.indicators[name]` = frame; `button._indicatorsReady` flag guards custom dispatcher
- **Central callback**: `SquizzFrames:Fire("UpdateIndicators", indicatorName, setting, value, value2)` → applies to all buttons + preview
- **Aura scanning, two parallel pipelines**:
  - **Legacy** (only for the custom types AuraEngine does not cover): `Custom_Dispatch.lua` scans `UNIT_AURA` via manual `C_UnitAuras.GetAuraDataByIndex` iteration; dispatches by type (icons, bars, icons+counter, text). **Broken in combat on 12.1+**: aura data is fully secret while auras are secret, so a scan started mid-combat permanently never sees anything applied after combat started (not intermittent — see the AuraEngine section below).
  - **AuraEngine** (unconditional since 2.0, no gate): `AuraEngineIndicators.lua`, `AuraEngineDispels.lua` and `AuraEngineCustom.lua` build indicators on Blizzard's managed `AuraContainer` API instead, which renders C-side without ever exposing secret aura data to Lua. `HandleIndicators` in `Indicators.lua` picks per-indicator at creation time (see next section) — there's no global on/off switch, some indicators/custom types stay on the legacy path even on 12.1.

### 5. Click Casting (ClickCasting.lua)
- Bindings stored in `profile.clickCasting` as `{bindKey, modifier, type, action}`
- Written as **secure attributes** on each unit button:
  - Mouse buttons: `type1`, `macrotext1`, `spell1`, `item1` ... `type5`
  - Keyboard/wheel: `type-E`, `macrotext-E` (virtual click via `SetBindingClick`)
- **Click-gate workaround** (gate dates from 12.0.7): `target`/`menu`/`togglemenu` on non-Left/Right or with modifiers are **gated** (silently fail). Solution: route through a **click proxy** button (`SecureActionButtonTemplate`, `useparent-unit=true`)
- **Proxy transport is a macro, and only a macro**: a Blizzard bug (`SecureTemplates.lua` checks forbidden aspects on the mouse-button *string* instead of the delegate frame, and throws) broke the old `click` + `clickbutton`-attribute transport on 12.1. `RouteProxyAction` sets `macrotext = "/click " .. proxyName` (so the proxy must have a **global name**) — mirrors EllesmereUI's `EllesmereUI_Kick.lua` fix for the same bug. The `clickbutton` transport and the `IS_121` branch that chose between them were deleted in 2.0; the only `clickbutton` writes left are the ones clearing stale attributes.
- **Secure hover snippet** (`_onenter`/`_onleave`/`_onmousedown`) installs `SetBindingClick` for keyboard/wheel keys on hover

### 6. Profile Management (ProfileStore.lua)
- **Not AceDB.** `ProfileStore.lua` replaced AceDB-3.0 entirely on 2026-08-06 (verified 2026-11-12: nothing calls `LibStub("AceDB-3.0")`; the library is still embedded and loaded, and the only code touching its shape is the one-time `ProfileStore:MigrateFromAceDB`). No `char`/`global`/realm/class namespaces and no metatables.
- `SquizzFramesDB` is one flat table: `profiles[name]`, `charProfileKeys` (which profile each character uses), `autoSwitch`, `schemaVersion`, plus account-wide roots other modules own (`nicknames`, `snapGrid`, `sharedTheme`, `debugMigrations`, `foreverCheck`).
- `SquizzFrames.db.profile` is still the path every file reads and writes; a switch is a plain `db.profile = <table>` reassignment, so never cache that table in a file-scope local. API on `SquizzFrames.db`: `GetProfiles`, `GetCurrentProfile`, `SetProfile`, `CopyProfile`, `DeleteProfile`, `RenameProfile`, `ResetProfile`, `ImportProfile`, `CommitDraft`, `DraftIsDirty`, `CopyBetweenModes`, `SaveCurrentAsDefault`.
- Every mutation goes through `GuardedCall`, which queues it to `PLAYER_REGEN_ENABLED` in combat (a switch re-lays-out secure frames). That is why `/sf reset` refuses in combat instead of reloading over a queued reset.
- A switch/copy/reset/import calls `SquizzFrames:RefreshProfile()` (`Core.lua`), which runs the migrations and then fires `"ProfileChanged"`; there are no AceDB `OnProfileChanged/Copied/Reset` callbacks.
- **"Default" is a DRAFT** (`ProfileStore.PROTECTED = { Default = true }`): edits apply live, but nothing reaches disk until `db:CommitDraft()` — the Profiles page's Save button. Unsaved changes to Default are lost on a profile switch, reload or logout, by design: it is the template every new character and profile seeds from. Every other profile saves as you go.
- **Healer preset**: `SquizzFrames.ApplyHealerPreset()` enables/configures key healer indicators
- **Import/export strings** (`Modules/Options/ProfileTransfer.lua`, V2.2): `!SQF1!` + LibSerialize → LibDeflate → print encoding. Bump `FORMAT` only for a change an older reader cannot handle; a new or changed setting needs a migration instead, because imports run through `RefreshProfile`. An import is untrusted data: it only ever creates a new profile (`DB:ImportProfile`), click-cast macros (`macro` and `custom` bindings) are removed unless the user opts in, and a string from the other client (retail/Forever) loses spell IDs that don't exist here. A new profile field holding macro text or executable-like data must join that cleaning.

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

⚠ **An offset can also hide in the CODE, with no stored default at all**, and
the grep above cannot find it. The cast bar's "On This Frame" mode placed the
bar at `oy - 2` / `oy + 2`, so Offset Y 0 was really 2px off; it survived both
0,0 migrations and was only noticed in V1.34 (user report 2026-09-26). Removed
from `CastBar.ApplyPosition` and `Preview.lua`, with `MigrateCastBarGap`
(`unitFrames.castBarGapRemoved`) folding the 2px into any non-zero offset so
those bars stay put. When checking "is 0 really 0", read the SetPoint call,
not just the defaults table.

### 7. 12.1 AuraEngine Subsystem (AuraEngine.lua / AuraEngineIndicators.lua)

**Why this exists**: on 12.1, `UNIT_AURA` payloads and `AuraData` structs are **fully secret while auras are secret** (i.e. during combat/encounters) — this is an official Blizzard change, not a bug. A manual `C_UnitAuras.GetAuraDataByIndex` scan (the legacy pipeline) doesn't get flaky in combat, it **permanently** stops seeing anything applied after combat started, for the rest of the encounter. `SecureAuraHeaderTemplate` itself was removed from Mainline in 12.1. The only sanctioned fix is Blizzard's managed `AuraContainer` API, which renders aura icons/cooldowns/text C-side without ever exposing the secret data to addon Lua at all.

**The pre-12.1 fallbacks are GONE (deleted in 2.0, user decision 2026-10-16).** This was ported in as an additive branch gated on `SquizzFrames.IS_121`; with retail at 120105 only, the flag, `IS_1215`, the scan-based `healerHots`/`dispels`/`externalCooldowns`/`defensiveCooldowns`/`debuffs`/`ccIndicator` (their `Check*`, `CreateDispelsIndicatorLegacy`, `ScanAurasFor*`) and the 12.0.7 click-casting `clickbutton` transport were all removed. Text below that says "falls back to legacy on pre-12.1" describes code that no longer exists. `Indicators.lua` still writes `AEI.CreateX(button, t) or BuiltIn.CreateBuiltInIndicator(button, t)`; the second half now returns nil for those names. The legacy `Custom_Dispatch.lua`/`BuiltIn_Update.lua` code that is still the only path on 12.1 for indicator types AuraEngine doesn't cover (`trackByName` customs, `unitButton`-anchor color customs, `icon`/`icons`/`text`/`rect`/`glow`/`border` customs) is live, load-bearing code and does still matter.

**What's migrated to AuraEngine on 12.1 today** (decided per-indicator in `Indicators.lua`'s `HandleIndicators`, not a global switch):
- Built-ins: `healerHots`, `dispels`, `externalCooldowns`, `defensiveCooldowns`, `debuffs`, `ccIndicator`
- Custom indicator types: `color` (only when NOT `trackByName` and anchor mode isn't `unitButton`) and `bar` (only when NOT `trackByName`)
- **Stays on legacy always**: `trackByName` customs (AuraContainer candidate filters are spellID-based, not name-based), `unitButton`-anchor color customs, and every other custom indicator type (`icon`, `icons`, `text`, `rect`, `glow`, `border`). `texture`, `overlay`, `block`, `blocks` and `bars` were removed in 2.0 (stand-ins that drew as another type); `MigrateRetiredCustomTypes` in `Core.lua` converts saved ones to what they drew
- The factories are split over three files, all publishing on `AEI`: `AuraEngineIndicators.lua` (healerHots, the two cooldown rows, debuffs, CC), `AuraEngineDispels.lua` (Dispels, Dispel Icons) and `AuraEngineCustom.lua` (custom color/bar). `Indicators.lua` tries the AuraEngine factory first (`indicator._sfType` check) and falls back to `BuiltIn.CreateBuiltInIndicator`/`I.CreateCustomIndicatorFrame` if it returns nil

**Core engine pieces (`AuraEngine.lua`)**:
- `AE.CreateContainer(parent, unitToken, spec)` — builds a real `AuraContainer` frame (`CreateFrame("AuraContainer", nil, parent, "CustomAuraContainerTemplate")`), declares groups (`AddAuraGroup`, multi-icon grids) and slots (`AddAuraSlot`, exactly-one-always-present overlays like dispel types or a single tracked spell), then `SetUnit` **last** (setting it before groups/slots are declared leaves `UNIT_AURA` unregistered). It has no combat check of its own (creating a container in combat is legal since 12.1 PTR 7), and no nil-unit check either — go through `AE.RequestContainer`.
- `AE.RequestContainer(parent, unitToken, spec, callback)` — the actual call site everywhere else uses; skips a nil unit, otherwise creates immediately, in combat too.
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
- **`AddAuraSlot` locks onto its first matched instance** and doesn't reliably notice a reapplication/refresh. Fixed by a periodic (1.5s) `container:UpdateAllAuras()` per registered slot-based wrapper (`RegisterSlotRefresh` in `AuraEngineCustom.lua`, running on an `AE.NewRefreshCycle`) — combat-legal, unlike a full container recreate.
- **`CustomAuraButtonTemplate` must exist, by that exact name, as an empty virtual template** (`AuraButtonTemplate.xml`). Blizzard's internal container code hardcodes an implicit inherit of a template literally named that, but never shipped one — omit it and `AddAuraGroup`/`AddAuraSlot` fails with "Couldn't find inherited node". XML `<Layers>` children do NOT attach to `type="AuraButton"` nodes on this build — all region creation happens in Lua via `initializeFrame`, not XML.
- **Group/slot `layout.elementWidth/elementHeight` only feeds the engine's flow-anchoring math**, not the button's actual rendered size — you must `button:SetSize(...)` yourself in the initializer. **This is the single most expensive thing on this list to get wrong**, because every symptom points somewhere else: the group attaches, `AddAuraGroup` returns cleanly, the frame pool fills with buttons, candidate filters match, the container reports `visible=true` with its flow layout fully applied — and nothing appears, because the buttons are zero-sized. A co-tank tracker built in Squizzumables (2026-09-08) died on exactly this and was abandoned after a session of chasing container sizing, `UpdateAllAuras`, flow-layout configuration and filter semantics, none of which were the fault. If icons do not render and everything looks correct, check the button size in the initializer first.
- **Spell-ID candidate filters are silently SKIPPED for a harmful aura on an assistable unit** — not applied and not rejected. `AuraContainerUtil.CanApplyIdentityCandidateFilters` returns true only for `auraData.isHelpful and UnitIsPlayerControlledOrGroupMember(unitToken)`, so a HARMFUL group with an `includeSpellIDs` whitelist shows **everything** while looking like it filters. The helpful side of this asymmetry is handled in code by `NoiseFloorMaxDuration` (`AuraEngineIndicators.lua`, read its comment); this is the other half. On 12.1.5 a whitelist where the gate is shut REJECTS everything instead (see *12.1.5 changes* below). Use `maxDuration` or the boss/priority flags for debuff filtering, never a spell-ID list.
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

**12.1.5 changes (LIVE; this is the client we ship on).** Researched on `ptr2` in September 2026, then re-checked 2026-11-12 against the local `live` clone (`C:\dev\wow-ui-source`, build 12.1.5.70783, `Interface/AddOns/Blizzard_AuraContainer/`): every API named below is present there. Three breaking changes and several additions, all in this subsystem:

- **Breaking, and the one that reached our code: `includeSpellIDs` REJECTS rather than being skipped.** `AuraContainerUtil.DoesAuraPassCandidateFilters` has an `elseif candidateFilters.includeSpellIDs ~= nil then return false` branch: where identity filtering is not permitted, a whitelist used to be discarded on 12.1.0 (everything showed) and now rejects everything (nothing shows). That would have inverted `showUnfiltered`, which depended on the discard (it promised the raw pool and would have delivered an empty row), **but that option was REMOVED in V1.24 instead of fixed** — it had been inert since the 69465 hotfix made the gate read OPEN for every token we bind, so the hide it opted out of no longer happens. If a gate is ever written against `IdentityGateState`, do NOT assume a whitelist is safe to drop on a SHUT reading: that heuristic is ours and Blizzard's test is per-aura and mostly OPEN, so dropping it would trade a correctly filtered list for the raw pool. Blizzard registers `UNIT_FLAGS`/`UNIT_FACTION` itself for spell-ID filters (`AppendCandidateFilterUnitEvents`), which makes our own identity-gate refresh largely redundant. `SetAuraBorder`/`GetAuraBorder`/`ClearAuraBorder` are GONE from `CustomAuraButton` (we never called them); there are two animation triggers, `AddAuraShownAnimation` and `AddAuraAssignedAnimation`.
- **Breaking: `AddDispelTypeTexture` and `AddPandemicRegion` do not return an index.** The matching `RemoveDispelTypeTexture` / `RemovePandemicRegion` take a **region reference**, and **adding the same region twice raises an error** rather than being ignored. Never capture a return value or remove by index; code that only adds, and adds a fresh region each time, is fine (ours does).
- **Breaking: `SetCooldown`/`Clear` cannot be called from tainted code when the cooldown frame itself is protected.** Hooks are unaffected; only direct calls on a protected frame. Cooldowns created by us on our own frames are fine.
- **IN USE since V1.39 — Dispels' Pulse Overlay / Animated Border** (`BuildDispelAnimations` in `AuraEngineDispels.lua`), on `AddAuraShownAnimation` (engine plays on show, stops on hide). Blizzard's own 12.1.5 dispel ants/pulse are client-drawn off a secure attribute, with nothing in Lua to borrow. Rules from `AuraContainerUtil.InitializeInboundAnimationGroup` that shaped it: register in `extraInit` or never, so the groups ALWAYS exist and settings only change their effect (pulse = moving the fade's `SetToAlpha`, ants = showing the clip frame); group, animations and targets must descend from the slot button; and every **target** gets secret Alpha/VertexColor/TexCoords aspects with removal forbidden, so a target is never a region we restyle — the pulse animates a bare host frame holding the overlay textures (`d.texHost`), the ants bare mover frames whose dash textures are children. CONFIRMED in game 2026-10-14, live frames in combat included. `/sfants` dumps the animated border's state on the Designer preview.
- **Pandemic animations**: `AddPandemicEnterAnimation` / `AddPandemicActiveAnimation` / `AddPandemicLeaveAnimation`, each with a `Remove*` and a `Clear*Animations`. *Enter* is one-shot, *Active* is for looping, *Leave* fires on exit. Blizzard drives them, so they work on secret auras. **IN USE**: for a style with `style.pandemic` set, `AE.MakeInitializer` builds four edge textures, registers each with `AddPandemicRegion` and adds an `AddPandemicActiveAnimation` group (`AuraEngine.lua`); the edges' host frame is the setting's live on/off switch. Two **forbidden aspects** come with them: `QueryAnimationProgress` (cannot ask whether an animation is running or how far along) and `AddAnimations` (cannot add or reparent animations), plus the existing `ChangeAnimationTarget`. Hand the group over and never inspect it afterwards.
- **`SetCasterName(fontString, options)`** on `CustomAuraButton` — who applied the aura, colourised by reaction or class. Not used by us. (Blizzard's notes also named a `tooltipShowAuraCasterNames` CVar; the name appears nowhere in the live UI source, so treat it as unverified.)
- **`SetApplicationBar(statusBar, options)` takes `minApplications`** — hide the bar until N stacks. Not used by us.
- **`SetAuraGroupEnabled(groupKey, enabled)`**, `SetAuraSlotEnabled(slotKey, enabled)` and `SetItemEnchantmentEnabled(slot, enabled)` on the custom and managed containers — a live enable/disable, which is the sanctioned answer to "groups are add-only, a disabled group is `maxFrameCount` 0". **Not used by us yet**: the debuff rows (`AuraEngineIndicators.lua`) and the unit-frame aura rows (`UnitFrames/Auras.lua`) still hold a group inert at `maxFrameCount = 0`, and their comments still say this API "is 12.1.5 and not live yet". It is live; switching over is open work, not a blocker.
- The container refreshes on **`UNIT_FLAGS` and `UNIT_FACTION`** (both in `FullAuraRefreshEvents`).
- `SetEditModePreviewEnabled(enabled)` exists, but on `ManagedAuraContainerSharedMixin` (Blizzard's managed containers), not on the custom container we build — so it is no help for our previews.

---

## Development Workflow

### Testing In-Game
There is **no automated test suite**. Development is done by:
1. Editing `.lua` files in the AddOns folder
2. `/reload` in-game -- enough for everything on retail, TOC/XML changes, new files and new SavedVariables included (user-confirmed repeatedly; never tell them to restart or relog)
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

Take the highest installed version (0.36.0 on 2026-11-12). 119 files / ~87k lines in about a second.
**Baseline as of 2026-11-12 (V2.3, clean tree): 607 warnings**, all pre-existing (207 on 2026-09-29 at
v1.37, 160 on 2026-09-19). 487 of the 607 are `undefined-field`, 378 of those "on class
`SquizzFrames`" — the checker does not follow fields assigned to the addon object from other files,
so every `SquizzFrames.Xxx` module handle counts — led by `UnitFrames.lua` (90); the remaining 120
are mostly `type-mismatch` (54), `undefined-global` (16) and the `secret-*` family (37). The count only means something
against a baseline: compare before and after your change (`git stash` / check / `git stash pop` gives
it). A new file that writes into the global `SquizzFrames` instead of declaring
`local SquizzFrames = _G["SquizzFrames"]` jumps it by hundreds (ArenaPrep.lua did: 207 -> 608). That baseline is the
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

**3. `.tools/check-keys.sh [tag]`** (default `v1.40`, ~2 minutes) is the 1.x key check from the 2.0
design doc: no setting a 1.x profile holds may be silently dropped. It takes every key in that
tag's `Defaults/*.lua` (via `.tools/keys.pl`) and lists keys no longer named in the current code,
keys whose reader was deleted while the default stayed, and per-indicator setting tokens that are
gone. Anything it lists must be explained (a migration converts it, or it belonged to something
deliberately removed). Run it before shipping anything that removes or renames settings.

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
its own main function and therefore gets its own 200-local budget. Eight pages
work this way (Layout, Unit Frames, Pet Frames, Indicators, Nicknames, Tank
Tracker, Party Cooldowns, Click Casting) -- OptionsFrame keeps only a short
shim per page that calls `Panel.Build`, and registers them all with the shell.

Pet Frames and Layout were extracted the same way on 2026-09-10:
**202 -> 147 -> 59 main-chunk locals**, and the file went 3167 -> 1373 lines
(1202 as of V2.3). Both ceilings now have comfortable headroom.

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
| `/squizz` | The combined window (registered by LibSquizzShell, see *Options window*) |
| `/sf lock` / `/sf unlock` | Toggle frame lock (`/sf toggle` is the same; all three toggle) |
| `/sf reset` | Reset profile + reload UI; refuses in combat |
| `/sf healer` | Apply healer preset |
| `/sf setup` | Re-run the first-run setup (`Modules/Welcome/Setup.lua`) |
| `/sf notes` | Re-open the current release notes (`/sf changelog` also works) |
| `/sf debug` | Toggle the profile-migration narration (`SquizzFramesDB.debugMigrations`, account-wide); `/reload` to see the login pass |
| `/sf forevercheck` | Temporary Forever-port diagnostic (`Compat/ForeverCheck.lua`): which APIs the running client really has |
| `/rl` | `ReloadUI()`, claimed at `PLAYER_LOGIN` only if no other addon has it (`SquizzFrames.ClaimReloadSlash`, `Utils.lua`) |
| `/sfhealers` | Bulk-import healer spells into a custom indicator (`Defaults/Indicator_Defaults.lua`) |
| `/sf nick` | Nickname management (see `Modules/Nicknames/Nicknames.lua`); `/sf nick` alone prints usage |
| `/sf nick test` | Solo self-check of the nickname sync pipeline (wire round-trip via whisper-to-self, receive path, sanitizer); `test clean` removes its entries |
| `/sfdrinktest [unit]` | Temporary dev/debug helper (`PartyButtons.lua`, default `party1`) |
| `/sfrosterdiag` | Temporary diagnostic (`PartyFrames.lua`): header children vs. units, for a group member whose button never returns |
| `/sfants [top] [noclip] [solid]` | State of the Dispels Animated Border on the Designer preview (`AuraEngineIndicators.lua`); the arguments are throwaway experiments on the preview, undone by a `/reload` |
| `/sfcdcheck` | Party Cooldowns: our computed cooldown for each of YOUR tracked spells against the game's tooltip (`PartyCooldowns.lua`) |
| `/sfauratest` | Spawns a throwaway AuraEngine test group above the player button (see AuraEngine section above) |
| `/sfspell [id ...]` | Aura flags **from a spell ID alone** — solo, no group, no aura needed (`TankTracker.lua`). Prints name, `IsPriorityAura`, `GetSpellAuraSecrecy` (+NeverSecret), `AuraIsBigDefensive`. Defaults to the Lost Explorers debuffs + the three Stagger IDs. The printed NAME is the check that an ID is the applied aura and not the cast |
| `/sfauras [unit] [help]` | The per-aura flags `/sfspell` cannot reach — `isRaid`, `isBossAura`, the three role flags, dispel type (`TankTracker.lua`). **Out of combat only**: `AuraData` is fully secret in combat and every field reads back secret, which the header states explicitly |
| `/reload` | Reload UI -- picks up every change, TOC/XML and new files included |

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
- `SquizzFrames.IS_FOREVER`: true on WoW Forever (interface number 16000-19999). The only client flag left: `IS_121` / `IS_1215` were removed in 2.0, since every client we load on runs the 12.1 engine. Retail is the unbranched path; only what Forever genuinely does differently goes behind this flag
- `F.SlashHandler(msg)`: every `/sf` subcommand
- `F.GetAccentColor`: the theme accent (see *Theme*)
- `SquizzFrames.ClaimReloadSlash(key)`: the polite `/rl`

### ProfileStore.lua
See section 6. `ProfileStore:Init()` runs from Core's `OnInitialize`; `ProfileStore.CHAR_KEY` (`Name - Realm With Spaces`) is computed there, not at file load.

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

### Indicators/AuraEngineIndicators.lua, AuraEngineDispels.lua, AuraEngineCustom.lua
One `AEI` table over three files since 2.0: the first five factories below are in `AuraEngineIndicators.lua`, the two Dispel ones (plus `BuildDispelAnimations`, `ApplyDispelSlotStyle`, `PreviewDispelOverlay`) in `AuraEngineDispels.lua`, and the two Custom ones (plus `RegisterSlotRefresh`) in `AuraEngineCustom.lua`.

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

⚠ **An enemy's class is hidden on arena tokens during the match**, so Class Color health on `arena1-5` fell through to green while the pre-match view (which works from the spec) was right (fixed V1.37, user-confirmed). `ResolveHealthColor` takes the class from `GetArenaOpponentSpec(i)` → `GetSpecializationInfoByID` (6th return, classFile) before the `UnitIsPlayer`/`UnitClass` branch. Any other per-class decision on an arena token needs the same route.

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

### Theme (Libs/LibSquizzTheme-1.0) -- shared with Squizzumables, 2.0 phase 1

Same arrangement as LibSquizzGrid below: **a byte-identical copy in each addon,
change both and bump `MINOR`.** ⚠ Since 2026-10-18 there is a THIRD copy of
this and of LibSquizzShell, in `AddOns\RoleRoulette\Libs` (it uses the shared
window and theme): change all three. It holds Squizzumables' five presets and named
palette, and ONE account-wide choice (user decision: one theme covers both
addons). A library cannot own SavedVariables, so each addon attaches its SV
ROOT (`LST:Attach(root, seed, priority)`) and the choice is written into every
attached root as `sharedTheme = {preset, at, seed}`: a real pick (`at` > 0)
beats any seed and the newest pick wins; with no pick, the highest seed wins.
Our seed is `class_colour` at priority 1 (`Core.lua`, right after
`ProfileStore:Init`) -- the 1.x accent had no control, so every profile was on
`class_color`; Squizzumables seeds its profile's choice at priority 2, so with
both installed its look carries over. What reads it here:
`F.GetAccentColor` (`Utils.lua`; every accent read in our UI goes through it),
the Theme dropdown at the top of the General page, the shell window itself
(drawn in the theme), and since phase 3 the controls' whole palette:
`SquizzFrames.Widgets_RefreshPalette` (`Widgets.lua`) fills it IN PLACE from
the theme, and OptionsFrame calls it before any page is built. Our pages are
still coloured once at build, so a pick shows after a /reload (the dropdown
offers one); Squizzumables repaints its own accent live. The old
`appearance.general.accentColor` is now only a fallback for a missing library.

### Options window (Libs/LibSquizzShell-1.0) -- 2.0 phase 3

**The combined `/squizz` window (MINOR 2, 2026-10-17)** is NOT a third window
holding both addons' pages: pages pin furniture to the window that built them
(Unit Frames, Tank Tracker) and some are singletons (the Indicators Designer),
so a page cannot live in two windows. Instead each addon registers an opener
(`Shell:RegisterOpener(id, {open = fn(pageId, show) -> win, slash = fn(msg)})`
-- ours is at the end of OptionsFrame.lua, Squizzumables' replaced its own
`/squizz`), and `/squizz` (registered by the LIBRARY) sets `lib.combined`:
each window's sidebar then lists the other addons as one row, search covers
them, and picking one hands over (`lib:HandOff`) to that addon's window at the
same rect -- one window on screen at a time. Closing a window (not a hand-off,
not the combat hide) ends combined mode, so `/sf` and `/sq` open standalone.

The window is a library SHARED with Squizzumables since 2026-10-17, and with
RoleRoulette since 2026-10-18: a byte-identical copy in each addon -- ⚠ change
all three and bump `MINOR` (it is MINOR 5 in all three as of 2026-11-12; Theme
is MINOR 1, Grid MINOR 2). Squizzumables registers its pages as "fill" pages
with its own search (`spec.search`), own preview headings (`previewTitle =
false`) and a build order (`BuildAllPages(order)`). Addons and windows are separate:
`Shell:RegisterAddon(id, {title, groups = {{label, pages = {...}}}})` registers
pages; `Shell:CreateWindow({name, addons = {...}, buttons, onHide, onShowPage})`
shows one or more addons. A page is built ONCE (`build(host)`, lazily, on first
show) and reparented into whichever window shows it. Our window registers nine
pages in four sidebar groups: Frames (Party and Raid, Unit Frames, Pet Frames),
On the frames (Indicators, Nicknames), Tools (Tank Tracker, Party Cooldowns,
Click Casting) and General (General, Profiles); scroll-page heights are in
OptionsFrame.lua's `pageHeights`.
Pages are `layout = "scroll"` (shared scroll frame, at least `height` tall) or
`"fill"` (whole content area, own scrolling -- Indicators). Optional `onShow`
(Click Casting's list rebuild) and `onResize` (Unit Frames' strip re-wrap).
Search covers page labels, every control Widgets.lua builds (checkbox, slider,
dropdown, colour picker -- each calls `Shell:IndexControl`, and `CreateTitledPane`
calls `Shell:IndexSection` to name the section; the owning page is found by
walking parents, so rebuilds re-point entries instead of duplicating them;
windows build every page hidden on first open so unvisited pages are found),
except on pages registered `autoIndex = false`. A page that builds ONE section at
a time (Unit Frames) calls `Shell:SetIndexScope(frame, key, label, scope)` before
each section and gives `select(scope)` + `indexAll()` in its page spec; the
window calls indexAll once on first open (see `UnitFramesPanel.IndexAll` for
how to keep that cheap -- every build leaks frames), and a result calls
select before scrolling. Tank Tracker and Party Cooldowns do the same per tab. Indicators keeps
`autoIndex = false` (an indicator's settings exist only while it is selected) and
instead gives `search(add)`, asked on EVERY search, listing each indicator in
both lists live (customs come and go); `setLayoutKey` clicks the Party/Raid
toggle before `SelectIndicator`. Plus whatever `Shell:AddSearchEntry(addonId,
{label, tip, page, path, onSelect})` adds -- step 3 of phase 3 fills that per
page. Preview column: a page spec's `preview(column)` is built ONCE into the
window's right-hand column (`opts.previewWidth`, 250) and shown only with that
page; the page area (`win.main`, the parent of the scroll frame and fill host)
stops short of it, so furniture a page pins by walking up to it (Unit Frames,
Tank Tracker) stops at the column too. Unit Frames, Indicators, Tank Tracker
and Party Cooldowns use it (`Panel.BuildPreview`). Hover text for every
control comes from the one table in `Modules/Options/Tooltips.lua` (keys
`"<page key>|<section>|<label>"`, `"<section>|<label>"` or `"<label>"`, most
specific first) and is searched too -- add an entry there for a new setting
whose name does not already say everything. The window keeps the global name `SquizzFramesOptionsFrame`
(GroupPreview anchors to it and hooks its OnHide) and
`SquizzFrames.OptionsScrollToTop` still exists (Unit Frames, Tank Tracker).

### Edit Mode grid and snapping (Libs/LibSquizzGrid-1.0, Modules/Grid/SnapGrid.lua)

A LibStub library shared with Squizzumables: **a copy lives in each addon and
LibStub runs whichever loads first at the highest MINOR.** ⚠ So any change must
be made to BOTH copies byte-identically AND bump `MINOR` — otherwise the two
addons silently run whichever copy loaded first, and a fix in one appears to do
nothing. The library's header documents what it draws and snaps to.

- Settings: `SquizzFramesDB.snapGrid` (account-wide, SV root). Snap OFF by
  default; grid always the player's class colour (user decisions 2026-09-26).
  Toggled by toolbar buttons only, no modifier key.
- Grid + toolbar follow `EditModeChanged`; snapping only happens while some
  addon is in its move mode (`AnyOwner`), so drags elsewhere are untouched.
- **Every mover snaps the same way**: place the frame from the cursor, call
  `SquizzFrames.SnapDelta(frame)` (UIParent units), add the delta to the drag
  offset and re-place. Offsets here are all UIParent units, so this is
  anchor-agnostic. Movers register with `SquizzFrames.SnapTarget(mover)` and
  clear guides with `SnapClear()` in their stop handler. A new mover needs all
  three.
- **Every mover also wears the shared look** (`Modules/Grid/EditMover.lua`,
  2.0): `SquizzFrames.EditMover.Show(frame, label, {find = <search term for
  its settings>, nudge = function(dx, dy) ... end})` when Edit Mode turns on,
  `EditMover.Hide(frame)` when it turns off. It draws the accent box and name,
  handles hover/select and the arrow-key nudge (1px, 10px with Shift), and
  takes no mouse itself, so each mover keeps its own drag handling. So a new
  mover is four things: the three snap calls plus `EditMover.Show`/`Hide` with
  a `nudge` that moves and saves the same position the drag does.
- `matchAttachHeight` (unit frames, not boss): `MatchedAttachHeight` feeds
  ApplyLayout's `h`, because the health bar is sized off it; the attach watcher
  runs a full ApplyLayout (not a re-place) when such a frame's target changes.

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
- `NicknamesPanel.lua` is a **pure shell over the module's public API** (`SetMyNickname`/`SetMineAccountWide`/`SetSyncEnabled`/`SetCustomNickname`/`SetBlacklisted`/`SetEnabled`) — no control writes the SV tables directly, so the panel and `/sf nick` can't drift and every write passes through `Sanitize` exactly once. Registered as the `nicknames` page in `OptionsFrame.lua`'s `Shell:RegisterAddon` call (+ `pageHeights`), rebuilt on `OnShow` since the slash commands can change the same data behind its back.

### Indicators/BuiltIn_Update.lua
- Built-in create/check/update functions for every built-in that is NOT AuraEngine-backed. The manual-scan versions of `healerHots`/`dispels`/`externalCooldowns`/`defensiveCooldowns`/`debuffs`/`ccIndicator` were deleted in 2.0; comments here and in neighbouring files still name them (`CheckDebuffs`, `ScanAurasForCooldownGrid`...) as history, but the functions are gone
- **Shared with pet buttons** (which are outside the indicator system entirely): `BU.CreateBorderIndicator`, `BU.CreateBlinkMarker`, `BU.AttachBlinkBehaviour`, and the `BU.Check*` functions for hover/target highlight and both aggro indicators. `PetButton_ApplyBorders` builds those frames by hand and fakes the one field the Check functions need (`indicator._sfTable = {enabled = ...}`). Settings come from the **Party** indicator list entry in every case — these are "universal" indicators, so a pet matches whatever its owner's frame is set to and there's no second set of options. Nothing re-runs a Check for a pet button automatically: `PetFrames.lua` registers the driving events itself (`PLAYER_TARGET_CHANGED`, `UNIT_THREAT_SITUATION_UPDATE`) and filters `UpdateIndicators` down to the five indicators pet buttons actually build.

**The three text readouts mirror the UNIT FRAMES' text model** (2026-09-17), not
Cell's. `nameText`/`healthText`/`powerText` differ from every other indicator:

- **One format token** (`t.textFormat`) instead of the old
  `showPercentage`/`showCurrent`/`showMax` trio, drawn from the same vocabulary
  the unit frames use (`SquizzFrames.UNITFRAME_TEXT_FORMATS` in
  `UnitFrames_Defaults.lua`). Keep the two lists in step — `powerMax` was added
  to the unit frames so a party readout set to current/max had somewhere to map.
- **One anchor point** (`position-single` token) — since V1.35 this is EVERY
  indicator's position control, not just the texts; `MigrateIndicatorAnchorsSingle`
  converted mismatched pairs exactly where the frame is `t.size`, and the widget
  preserves any it could not until a new anchor is picked. Storage is still the five-field
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
- Indicator types: `icon`, `icons`, `text`, `bar`, `rect`, `color`, `glow`, `border` (`CUSTOM_TYPES_ALL`). Only Icon, Bar and Color are offered in the Create dropdown; the other five are unverified, and all legacy-scan types are expected to go blind in combat on 12.1
- Still the only path for `trackByName` customs and `unitButton`-anchor color customs even on 12.1 (see AuraEngine section above for why)

### ClickCasting/ClickCasting.lua
- `GetAttributeKey(modifier, bindKey)`: Normalizes `shift-ctrl-alt-` prefix + `typeN` / `type-KEY`
- `IsGatedAction(bindKey, actionType)`: Detects the click-gate conditions
- `RouteProxyAction(...)`: Sets up the click proxy and points the button at it with a `/click <proxy>` macro; no client branch (see Click Casting section above)
- `ApplyClickCastings(button)`: Clears old, writes new bindings from profile
- `SetBindingClicks(button)`: Installs secure hover snippet

### PartyCooldowns/PartyCooldowns.lua
Each group member's defensive, external and group-wide cooldowns as a row of icons on their party frame. **Party and solo only, never in a raid** (user decision 2026-10-27). Off by default. The file header is the full writeup; the shape of it:

- **Why it needs a trick at all**: a party member's casts are secret in instances, so there is nothing to read. Measured in game with a probe (`/sfcdprobe`, removed before 2.1, in git history).
- **SENSOR**: one hidden `AuraContainer` per (unit, cooldown), one group filtered to the buff the cooldown leaves, `maxFrameCount` 1 and a 50000px element width. With the buff up the container grows across the screen, so `container:IsMouseOver(huge, -huge, 0, 0)` says "buff up". The answer is ALWAYS secret (out of combat too) and is never compared or branched on in Lua.
- **LATCH**: `C_CurveUtil.EvaluateColorValueFromBoolean(bool, a, b)` picks a or b engine-side. On a reading that is up now and was not last time it stores "now" as a number, otherwise keeps the old one — a secret start time nobody ever reads. Only 254 steps fit, so each timer has two slots reset in turn (`NewTracker`).
- **DRAW**: a `StatusBar` takes that secret start in `SetValue` with plain min/max of `[now - cd, now]`, so its fill is the share of the cooldown left. Countdown numbers ride the same value (`NewIcon`).
- **Limits, by design of the technique**: only cooldowns that leave a buff can be seen (no interrupts); an external shows on everyone in the group who could have cast it; the sensor reads through the cursor, so with the cursor outside the game window a cast can be missed or picked up late; charges are counted up to two. Your own row reads the game's exact cooldowns instead.
- **Cooldown lengths follow talents**: yours from your loadout, a party member's from inspecting them out of combat, one at a time. Until then spec is guessed from role where the class allows one answer.
- **Data**: `PartyCooldownsData.lua` is read from the live build's DB2 exports (wago.tools), not from another addon; `PartyCooldownsData_Forever.lua` replaces it under `IS_FOREVER`. `/sfcdcheck` compares our computed cooldown for each of your tracked spells with the game's tooltip.
- **Settings**: `profile.partyCooldowns`, with the defaults in the module ONLY (`DEFAULTS`), not in `Defaults/`. The panel reads through `PC.Get`, so it cannot show one value while the icons use another, and nothing is written until the user changes something. So the deep-copy rule in section 6 does not apply here: changing one of these defaults DOES reach existing users who never touched that setting.
- `SquizzFrames.PartyCooldowns` is set by hand, because `NewModule` does not put a module on the addon object.
- It runs a 0.1s display-and-read pass while enabled, the one module here that polls that fast.

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
    maxLength = 0,                   -- the three text readouts: characters, 0 = unlimited (replaced the old textWidth table)
    -- healthText/powerText also carry textFormat, one token (see BuiltIn_Update section)
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

### Status text timer, dead-player range fade, out-of-range joiner names (V1.38)

- **`statusText`'s `showTimer` was dormant scaffolding** (see *New Indicator SETTING*): checkbox, default
  `true`, saved -- and read by nothing, so AFK/Dead never counted (user report 2026-10-04). Now
  `PartyButtons.lua`'s `StatusTimer` (it was `TimedStatusText` in `PartyFrames.lua` before the 2.0 split) times each status from when it is FIRST SEEN (the game reports no
  start time; a /reload restarts it), keyed by GUID in `statusSince` -- never by unit token or button,
  which the secure header reshuffles on every re-sort. A 1s `statusTicker` re-runs `UpdateStatus` only for
  buttons flagged `_sfStatusTimed` and cancels itself when none are.
- **Timer on Other Side** (`timerOpposite`, `checkbutton3`, default off): the timer is a second
  FontString, `statusText._sfTimer`, on the health bar's opposite edge from the label's anchor
  (`StatusTimerString`), label x offset mirrored. It copies the label's font/colour/shadow/alpha on
  every update instead of being wired into the indicator font system, so it needs no settings of
  its own -- and every place that hides `statusText` must hide `_sfTimer` too. It lives on the
  label's `_sfLevelFrame`, never `fs:GetParent()`: GiveRegionRealFrameLevel overrides GetParent
  to answer the BUTTON, so a sibling made there sits under the shield overlay (hit 2026-10-05).
- **Don't Fade Dead Players** (`appearance.general.keepDeadUndimmed`, Layout page, default off):
  `UpdateRangeAlpha` gives a dead/ghost unit alpha 1 the same way it does the player's own frame.
- **Status Text AND Status Icon ignore range fade** (`SyncStatusTextAlpha`, user requests 2026-10-04 / 2026-10-17; the icon is `button.indicators.statusIcon`): the FontString and its `_sfBG`
  `SetIgnoreParentAlpha(true)` and take `partyFrame:GetEffectiveAlpha()` -- the CONTAINER's alpha, so the
  blanket Frame Opacity still applies (ignoring all alpha would leave text floating over faded-out
  frames). Re-synced wherever either alpha changes: the range poll, ResetRangeAlpha and
  `PartyFrames.ApplyOpacity`. Unconditional, no setting. (The old Blizzard-panel fade, disabled since
  2026-08-01, was deleted in 2.0.)
- **Out-of-range joiners showed someone else's name, or none** (user report 2026-10-04, nicknames on; both
  happened, "randomly"). Two causes, two fixes:
  - *Another member's name*: the header handed a button a new unit AFTER the 0.3/1/2s roster passes, so
    nothing re-wired and `button.unit` kept its old token -- a real member, hence a real (wrong) name and
    health. Only `UNIT_NAME_UPDATE` (fires on coming into range) re-wired. Now a 1s out-of-combat
    watchdog in `OnEnable` (`self._sfUnitWatchdog`) runs `HeaderUnitsChanged` -> `ReapplyRosterLayout`.
    Deliberately POLLED, not a `HookScript("OnAttributeChanged")` on the secure children: that would run
    our code inside the header's secure update (taint risk).
  - *Blank*: the name genuinely isn't known yet out of range (`UnitName` empty or `UNKNOWNOBJECT`).
    `CheckNameText` now retries itself each second, one pending retry per button, up to 60.
  UNTESTED in game when written.

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
- Use `F.ResolveFontFile(fontFile)` (defined in `Indicators.lua`, exported on `F`) — checks path prefix, then LSM hash table, falls back to `Fonts\FRIZQT__.TTF`.

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

### New Built-in Indicator (not aura-driven)
See also the "four places" note in section 4 (`BUILT_IN_COUNT`, `INDICATOR_CATEGORY`).
1. Add default config to `Defaults/Layout_Defaults.lua` (in `profile.layout.indicators`)
2. Add `indicatorIndices` entry in the same file
3. Implement `CreateXxxIndicator(button, t)` in `Indicators/IndicatorWidgets.lua`
4. Add `SetupXxxIndicator(button, t)` + `CheckXxxIndicator(button)` in `Indicators/BuiltIn_Update.lua`
5. Register events in `Indicators:OnEnable()` if needed

### New AuraEngine-backed Built-in (12.1, combat-reliable aura tracking)
Only needed if the indicator tracks live aura presence/duration and must stay accurate in combat (the exact problem AuraEngine solves — see section 7). If it doesn't touch auras, use the plain path above instead.
1. Implement `AEI.CreateXxxIndicator(button, t)` in `AuraEngineIndicators.lua` (or a new file loaded after it, the way Dispels and Custom are), following an existing example close to what you need: `CreateDebuffsIndicator`/`CreateCCIndicator` for a plain icon grid, `CreateDispelsIndicator` for a health-bar overlay driven by bare (`noRegions`) slots, `CreateCustomColorIndicator`/`CreateCustomBarIndicator` for single-slot presence-driven visuals
2. Register a style in `AE.styles` and build the `initializeFrame` via `AE.MakeInitializer` (or a bare `applyExtra` function for `noRegions` styles) — do all region creation/registration there, nothing later
3. Wire it into `Indicators.lua`'s `HandleIndicators` dispatch in the existing shape (`AEI.CreateXxxIndicator(button, t) or BuiltIn.CreateBuiltInIndicator(button, t)`; there is no legacy version to write, the second half just returns nil), and into `ApplySettingToOne` for any settings the wrapper exposes setters for
4. Add a Designer-preview fallback (`CreateFallbackIconRow` for icon-grid types, or a plain texture for overlay types) — the real container never gets real data in preview, see section 7
5. Re-read the "hard rules" list in section 7 before writing any code that touches a slot/group button outside `initializeFrame`/`extraInit`

### New Custom Indicator Type
1. Add factory in `IndicatorWidgets.lua` → `CreateCustomIndicatorFrame`
2. Add dispatcher case in `Custom_Dispatch.lua` → `DispatchIndicatorUpdate`
3. Add options UI in `IndicatorsPanel.lua`
4. If it's aura-presence-driven (like `color`/`bar`) and combat reliability matters, consider an AuraEngine-backed variant too — see `Indicators.lua`'s existing `type == "color"`/`type == "bar"` branches for the pattern (legacy factory stays the path for `trackByName`)

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

Hover text is a sixth, optional place: indicator setting widgets look their
tooltip up by label in `Modules/Options/Tooltips.lua`
(`IndicatorWidgetsBase.lua`), the same table every other page uses. No entry
means no tooltip, silently.

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
| Ace3 (Addon, Event, Timer, DB, Config, Hook, Comm, Console, Locale, GUI) | Core framework. AceDB-3.0 is embedded and loaded but unused since ProfileStore replaced it |
| LibStub | Library loader |
| CallbackHandler-1.0 | Event/callback bus |
| LibSharedMedia-3.0 | Fonts, textures, sounds, borders |
| LibCustomGlow-1.0 | Button glow effects (proc, action bar style) |
| LibDeflate | Compression (for serialization) |
| LibSerialize | Table serialization |
| LibRangeCheck-3.0 | Unit range checking (out-of-range alpha) |
| LibSquizzGrid-1.0 | **Our own**, shared with Squizzumables: Edit Mode grid + snapping. Change both copies identically and bump `MINOR` (see *Edit Mode grid and snapping*) |
| LibSquizzTheme-1.0 | **Our own**, shared with Squizzumables and RoleRoulette: palette, presets and the one account-wide theme choice. Change all three copies identically and bump `MINOR` (see *Theme*) |
| LibSquizzShell-1.0 | **Our own**, shared with Squizzumables and RoleRoulette: the options window (title bar, search, grouped sidebar, page hosting, preview column) and `/squizz`. Change all three copies identically and bump `MINOR` (see *Options window*) |

---

## Version Compatibility

- **WoW Forever** (`SquizzFrames.IS_FOREVER`, Interface `16001`, port in progress): retail stays the unbranched path. Party Cooldowns swaps in its own table from `PartyCooldownsData_Forever.lua`, read from build 1.60.1.70790's DB2 tables; `minLevel`, `learned` and a mod's `whole` exist only on that table, so retail never reaches them. The indicator lists are replaced by `Defaults/Indicator_Spells_Forever.lua` (every rank, since aura filters match exact IDs; an ID nobody has costs nothing there, unlike a Party Cooldowns row), and `Utils.lua`/`ClickCasting.lua` swap the click-cast and Smart Resurrection tables under an `IS_FOREVER` check. Bindings cast by name, so they get your highest rank. Forever has no `Ping_Frame_*` atlases (checked in UiTextureAtlasMember: 0 rows, retail 24), so `LightPingMarker` uses `Ping_Marker_Icon_*` there (CONFIRMED in game solo, 2026-11-05); a missing atlas fails silently, so check the DB2 table when a texture draws nothing. Untested in a group as of 2026-11-05. Hunter pet happiness (V2.3) is Forever-only: `C_PetInfo.GetPetHappiness()` + `UNIT_HAPPINESS` (retail has neither, so the event is registered behind `IS_FOREVER`), drawn on your own pet's button only (`UpdatePetHappiness` in `PetFrames.lua`, settings in each pet layout's `happiness` table), copied from Blizzard's Forever `PetHappiness.lua`. **Surnames (V2.3):** on Forever `UnitName`'s second return is the character's SURNAME, not a realm (Blizzard's `Blizzard_FrameXMLUtil/Camelot/NameUtil.lua`), so `F.UnitFullName`'s `hideRealm` hides surnames there; Name Text's checkbox reads "Hide Surname" on Forever and a shown surname is joined with `Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR`. Unit frames, Tank Tracker and pets use the first return only. Anything keyed by "Name-Realm" collides for same-first-name characters on Forever (DPSReport hit this; see its `charDataKey`) -- the Nicknames module's keys have the same exposure, unaddressed.
- **Target**: WoW 12.1.5 on retail, plus WoW Forever — `## Interface: 120105, 16001`. For retail it is 120105 only (user decision 2026-10-16, all seven addons: there is no way back to 12.1.0, and every update from here is a 12.1.5+ fix or addition, so 120100 was dropped from the TOC and must not come back); `16001` was added for the Forever port on 2026-11-05. Before that it was `120100`. 12.0.7 was dropped from the TOC on 2026-08-21: that client no longer exists, so listing it only advertised support the addon could not actually deliver (and made CurseForge tag every upload as 12.0.7-compatible).
- **No client-version gates**: the 12.1 code paths (the AuraEngine subsystem in section 7, the click-casting macro transport) used to be gated at runtime by `SquizzFrames.IS_121`. That flag, `IS_1215` and the pre-12.1 branches they selected were deleted in 2.0 (user decision 2026-10-16), so those paths now run unconditionally. `IS_FOREVER` is the only client flag.
- Uses modern APIs: `C_AddOns.GetAddOnMetadata`, `C_Spell.GetSpellName`, `C_Spell.GetSpellInfo`, `C_UnitAuras`, `C_Item.IsUsableItem`
- Fallback globals provided in Utils/Core for older API compat

---

## Memory/Performance Notes

- **No periodic OnUpdate loops** for the legacy pipeline — event-driven via AceEvent + secure header. The one deliberate exception is the Phased Icon's 1s `C_Timer` ticker (`BuiltIn_Update.lua`), which exists because `UnitPhaseReason` is blind past ~250 yards and no event fires when that changes — it self-cancels as soon as a pass finds no enabled `phasedIcon`, and `CheckPhasedIcon` re-arms it. The second is the unit-frame attach watcher (`UnitFrames.lua`, 0.25s, hidden unless a frame is attached to a cooldown group, idle in combat); see *Attaching frames*
- **Indicator updates** batched per-button via `ScheduleButtonUpdate`
- **Secure header** manages child visibility via `RegisterUnitWatch` (no manual show/hide needed for roster changes)
- **Custom aura scanner** iterates `C_UnitAuras.GetAuraDataByIndex` — efficient for party frames (max 5 units × ~40 auras)
- AuraEngine (12.1) has two kinds of lightweight `OnUpdate` driver, all self-hiding when idle: the restyle scheduler (`AE.RestyleSoon`'s ticker, budgeted 200 buttons/frame) and `AE.NewRefreshCycle(interval)`, the periodic `container:UpdateAllAuras()` shared by the custom colour/bar slots (1.5s), the unit-frame aura rows (1s) and the tank tracker (1s). A cycle refreshes each registered container once per interval but deals them out a few per frame; the three separate tickers it replaced (2026-09-26) re-parsed everything in one frame, a regular hitch in a raid. Use it for any new periodic re-parse rather than another private ticker
- ⚠ **`CD.Scan` returns immediately unless the button's context holds a legacy custom** (`HasLegacyCustoms` in `Custom_Dispatch.lua`: an entry without `engineDriven`). It runs on every `UNIT_AURA` of every button and walks up to 80 aura slots, allocating an `AuraData` per slot, and on 12.1 with no legacy customs it fed nothing -- the single largest avoidable Lua cost found in the 2026-09-26 performance review. Anything new that scans auras per event needs the same "is there anything to feed" gate
- FIXED V1.37: `I.RemoveAllCustomIndicators` used to orphan each LEGACY custom indicator's frame (`SetParent(nil)`) on every rebuild and a new one was created, and WoW never frees a frame, so raid re-sorts grew memory. It now PARKS them in `button._sfCustomPool` and `AcquireCustomFrame` hands them back. The key is the indicator's own settings TABLE, then type and slot count (`PoolShape`) -- not type alone, as first planned: the colour overlay closes over its `t` (for `t.anchor`) and grids bake their slot count in, so a frame is only safe to reuse for the table and shape it was built for. `HandleIndicators` now ends with a custom `Scan`, because a reused frame can still hold the previous unit's aura after a re-sort

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
| `IS_FOREVER` | Every retail-vs-Forever branch point (`IS_121` is gone; a hit for it is a stale comment) |
| `AddAuraGroup` / `AddAuraSlot` | AuraContainer group/slot declarations |
| `initializeFrame` / `extraInit` | AuraEngine button-creation callbacks — the only place button API calls are legal once secret |
| `_sfAuraEngineBacked` | Marks a custom indicator whose live container must survive repeated `HandleIndicators` rebuilds |
| `AE\.` | AuraEngine.lua's public API surface (`AE.CreateContainer`, `AE.RequestContainer`, `AE.styles`, `AE.RestyleSoon`, `AE.Filter`) |
| `_sfStyleNS` | Callers claiming their own `AE.styles` namespace, so two owners' settings can't overwrite each other |
| `^local function Migrate` | Every profile migration in `Core.lua`; read these before changing any shipped default |
| `ApplyMock` | The shared preview text stylers — anything mocking engine-drawn duration/stack text |
| `IsVolatileToken` | The unit tokens whose meaning changes during play; never memoise anything against one |
