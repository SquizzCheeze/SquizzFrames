# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**SquizzFrames** is a World of Warcraft (Mainline/Retail, API 12.0.7+) unit frame addon for party frames. It uses the **Ace3** framework and follows patterns from **Cell** and **DandersFrames** for secure frame handling, indicator systems, and click-casting.

- **AddOn Name**: SquizzFrames
- **SavedVariables**: `SquizzFramesDB` (AceDB-3.0 profiles)
- **Slash Command**: `/sf` ( `/squizz` is taken by Squizzumables)
- **Key Bindings**: Click-casting via secure attributes
- **Runtime 12.1 branch**: the addon ships live on 12.0.7 but already carries a backported, feature-flagged 12.1 AuraContainer code path (`SquizzFrames.IS_121`) alongside the legacy one — see [12.1 AuraEngine Subsystem](#7-121-auraengine-subsystem-auraenginelua-auraengineindicatorslua) below before touching anything aura-related.

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
├── HideBlizzard.lua         # Hides default Blizzard party/raid frames
└── Modules/
    ├── LoadModules.xml      # Loads PartyFrames, Indicators (incl. AuraEngine), ClickCasting, Options
    ├── PartyFrames/         # Secure group header + unit buttons (party1-4 + player)
    │   ├── PartyFrames.lua  # Layout, anchoring, growth, edit mode, sizing
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
    ├── Nicknames/           # Display-name replacement (private list + group-synced)
    │   ├── Nicknames.lua       # Storage, secret-safe resolution cache, AceComm-free addon-message sync, /sf nick
    │   └── NicknamesPanel.lua  # Options page ("nicknames" nav entry); pure shell over the module's public API
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
- **Container auto-sizes** to visible buttons via `SizeContainerToButtons()` — no empty draggable strip
- **Edit mode** uses a non-secure **mover frame** (`mover:SetAllPoints(container)`) on top — secure buttons swallow clicks, so drag must be on a separate frame

### 4. Indicator System (Indicators.lua)
- Mirrors **Cell's** indicator architecture
- **Built-in indicators** (17 defaults): nameText, healthText, powerText, statusText, statusIcon, roleIcon, leaderIcon, playerRaidIcon, aggroBlink, aggroBorder, shieldBar, externalCooldowns, defensiveCooldowns, debuffs, ccIndicator, dispels, missingBuffs
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
- **No API calls on an AuraContainer-managed button outside `initializeFrame`/`extraInit`, full stop**, once its aura is secret (12.1 PTR5 change). This is broader than just Show/Hide — covers `SetFrameStrata`, `SetFrameLevel`, `SetDurationBar`, etc. Every `slotButton:Set*` call in this codebase happens inside an `extraInit`/`initializeFrame` callback for exactly this reason.
- **No `SetScript`/`HookScript` on a group/slot button** — breaks the engine's own secret-aspect Show/Hide wiring.
- **Can't read a slot/group button's `IsShown()`** — it's secret too. Never build telemetry/debugging around polling button state.
- **Addons cannot reparent aura buttons** (12.1 PTR6 ban). Custom bar/color indicators create their visuals as children of the *same* slot button they're registered on (`ApplyCustomBarSlotStyle`/`ApplyCustomColorSlotStyle`) — never move them elsewhere.
- **`AddAuraSlot` locks onto its first matched instance** and doesn't reliably notice a reapplication/refresh. Fixed by a periodic (1.5s) `container:UpdateAllAuras()` per registered slot-based wrapper (`slotRefreshTicker`/`RegisterSlotRefresh` in `AuraEngineIndicators.lua`) — combat-legal, unlike a full container recreate.
- **`CustomAuraButtonTemplate` must exist, by that exact name, as an empty virtual template** (`AuraButtonTemplate.xml`). Blizzard's internal container code hardcodes an implicit inherit of a template literally named that, but never shipped one — omit it and `AddAuraGroup`/`AddAuraSlot` fails with "Couldn't find inherited node". XML `<Layers>` children do NOT attach to `type="AuraButton"` nodes on this build — all region creation happens in Lua via `initializeFrame`, not XML.
- **Group/slot `layout.elementWidth/elementHeight` only feeds the engine's flow-anchoring math**, not the button's actual rendered size — you must `button:SetSize(...)` yourself in the initializer.
- **`SetGradient` permanently breaks plain `SetAlpha`/`SetColorTexture` alpha on that same texture object** afterward (confirmed by debugging — not documented). Dispels' gradient overlay mode uses a dedicated second texture (`d.gradientOverlay`) rather than reusing `d.overlay`, so full/fill mode's plain alpha stays reliable regardless of gradient mode ever having run.
- A PTR5 upstream bug: `SetDurationText`'s `textColorCurve` option can hard-error and abort the WHOLE button batch if the engine's C binding argument count doesn't match. `AE.SetDurationTextSafe` tries with the curve, falls back to without it on failure — self-heals once Blizzard fixes it upstream.

**Preview/Designer limitations** — the options panel's live preview button can't get real aura data into an AuraContainer (it's driven entirely by the C-side engine bound to a real unit; there's no way to inject fake `AuraData`):
- Every migrated indicator instead renders a **fallback row of static icon frames** (`CreateFallbackIconRow` in `AuraEngineIndicators.lua`) sized/laid out to match the real container, using representative spell icons pulled from the indicator's own effective spell list where one exists (healerHots, cooldowns), or generic placeholders (debuffs, CC).
- The preview's container is either **never created at all** (healerHots/cooldowns/debuffs/CC — `isPreview` skips `AE.RequestContainer` entirely) or **bound to a deliberately-invalid unit token** (dispels — `"squizzframespreviewfake"`) — both approaches were needed because a first attempt (binding to the preview button's real `"player"` unit) leaked real casts into the preview while it was open.

**Boss "Private Aura" debuffs are handled by the engine itself.** They used to need a separate indicator built on `C_UnitAuras.AddPrivateAuraAnchor` (an older, unrelated API that Blizzard has always hidden from addon aura scanning). On 12.1 the AuraContainer engine registers for them natively (`AuraContainerPrivateMixin` / `C_UnitAurasPrivate.AddPrivateAuraUpdateCallback`), so that indicator was removed on 2026-08-13 — module, defaults, settings and profile entries. Don't re-add it; if boss private auras ever stop appearing, the fault is in the container binding, not in a missing anchor indicator.

**Dev/debug harness**: `/sfauratest` (`AuraEngine.lua`) creates a real, throwaway `AddAuraGroup` above the player's own button filtered to the healer spell list, to prove the pipeline end-to-end (including in combat) independent of any real indicator. Marked in-code as a temporary Phase 0 harness — fine to leave, but don't build new functionality on top of it.

---

## Development Workflow

### Testing In-Game
There is **no automated test suite**. Development is done by:
1. Editing `.lua` files in the AddOns folder
2. `/reload` in-game (or log out/in for TOC/XML changes)
3. Using `/sf` to open options panel
4. Checking chat for debug prints (prefixed `|cff33cc99[SquizzFrames]|r`)

### Releasing
Tagging is what publishes — pushes to `main` never reach CurseForge.

1. Close the top `CHANGELOG.txt` section (date the heading) and bump `## Version:` in `SquizzFrames.toc`. **Both are manual** — the TOC keeps a literal version rather than `@project-version@` so the live dev folder doesn't show a placeholder in the in-game addon list.
2. `git tag -a v1.7 -m "V1.7"` && `git push origin v1.7`
3. `.github/workflows/release.yml` (BigWigsMods/packager) builds the zip, uploads it to CurseForge (project ID read from `## X-Curse-Project-ID` in the TOC) and attaches it to a GitHub release.

Dry run: Actions tab → "Package and release" → Run workflow with `dry_run` ticked. Builds and uploads nothing, leaving the zip as an artifact. Requires the `CF_API_TOKEN` repo secret; `GITHUB_TOKEN` is automatic. `.pkgmeta` controls what's excluded from the zip and feeds `CHANGELOG.txt` in as the release notes (whole file, not just the newest section).

### Common Commands
| Command | Action |
|---------|--------|
| `/sf` | Open options panel |
| `/sf lock` / `/sf unlock` | Toggle frame lock |
| `/sf reset` | Reset profile + reload UI |
| `/sf healer` | Apply healer preset |
| `/sfhealers` | Bulk-import healer spells into a custom indicator (`Defaults/Indicator_Defaults.lua`) |
| `/sf nick` | Nickname management (see `Modules/Nicknames/Nicknames.lua`); `/sf nick` alone prints usage |
| `/sf nick test` | Solo self-check of the nickname sync pipeline (wire round-trip via whisper-to-self, receive path, sanitizer); `test clean` removes its entries |
| `/sfdrinktest` | Dev/debug helper (`PartyFrames.lua`) |
| `/sfauratest` | 12.1-only: spawns a throwaway AuraEngine test group above the player button (see AuraEngine section above) |
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
`AEI.CreateHealerHotsIndicator`, `AEI.CreateExternalCooldownsIndicator`, `AEI.CreateDefensiveCooldownsIndicator`, `AEI.CreateDebuffsIndicator`, `AEI.CreateCCIndicator`, `AEI.CreateDispelsIndicator`, `AEI.CreateCustomColorIndicator`, `AEI.CreateCustomBarIndicator` — each returns a plain wrapper `Frame` that `Indicators.lua`'s generic position/size/frameLevel/alpha dispatch treats identically to every other indicator; the real `AuraContainer` is a child of the wrapper.


### Nicknames/Nicknames.lua
Replaces the name drawn by the `nameText` indicator. Four layers, resolved highest-first: private `custom[full]` → `custom[base]` → synced `[full]` → `[base]`. **Private always beats remote** — that ordering is what makes accepting broadcast strings tolerable.

- **The contract**: `N:Resolve(unit)` returns a **plain Lua string or nil, never a secret**. `nil` means "couldn't resolve" (disabled / no entry / name currently secret) and the caller falls through to its pre-existing, secret-safe path. The two never blend — see the header comment for why `nickname or name` is a crash, not a convenience.
- **Resolution cache** (`resolveCache`) is keyed by **unit token, not button** — the secure header reassigns tokens across buttons on every re-sort, so per-button caching goes stale silently under `sortByRole`. Wiped on `GROUP_ROSTER_UPDATE`/`PLAYER_ENTERING_WORLD`; per-unit invalidation on `UNIT_NAME_UPDATE`. A secret read is never cached (it's transient).
- **Storage is account-wide** at the SavedVariables root (`sv.nicknames`), next to `sv.autoSwitch` — nicknames describe people, not layouts, so they must survive a profile switch. Your own nickname is keyed per-character.
- ⚠️ **`sv.nicknames.mine` is keyed by `F.PlayerFullName()` (`Name-NormalizedRealm`), NOT `ProfileStore.CHAR_KEY`** (`Name - Realm With Spaces`). Two deliberately separate keyspaces: the wire format must match `CHAT_MSG_ADDON`'s `sender`. Mixing them makes every same-realm lookup miss, silently.
- **Sync** uses raw `C_ChatInfo.SendAddonMessage` on prefix `SQF_NICK` (16-char limit — the obvious `SQUIZZFRAMES_NICK` is 17 and would never register). Ownership comes from `sender`, never from the payload, so nobody can set a nickname for someone else.
- **All inbound and outbound strings go through `Sanitize`**, which strips `|T`/`|A`/`|H`/`|c`/`|r` escapes and caps length. Non-optional: `|T` renders an arbitrary texture inside a FontString and `|H` a clickable link, so an unsanitized remote nickname lets any group member draw on your frames. Cell does not do this.
- Refresh reuses the existing `_sfNameUpdater` closure that `CheckNameText` stores on the indicator — no new plumbing.
- `NicknamesPanel.lua` is a **pure shell over the module's public API** (`SetMyNickname`/`SetMineAccountWide`/`SetSyncEnabled`/`SetCustomNickname`/`SetBlacklisted`/`SetEnabled`) — no control writes the SV tables directly, so the panel and `/sf nick` can't drift and every write passes through `Sanitize` exactly once. Registered as the `nicknames` entry in `OptionsFrame.lua`'s `NAV_ITEMS` + `pageHeights`, rebuilt on `OnShow` since the slash commands can change the same data behind its back.

### Indicators/BuiltIn_Update.lua
- Legacy built-in check/update functions, including the manual-scan versions of `healerHots`/`dispels`/`externalCooldowns`/`defensiveCooldowns`/`debuffs`/`ccIndicator` that AuraEngine now supersedes on 12.1 (still load-bearing on pre-12.1 clients — see AuraEngine section above)

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

### Secure Frame Script Hooking
- **DO NOT** use `button:SetScript("OnEnter", fn)` or XML `<OnEnter>` on secure buttons — it **replaces** the secure `_onenter` wrap, breaking click-casting.
- **USE** `button:HookScript("OnEnter", fn)` — runs alongside the secure wrap.
- The same rule applies, more strictly, to 12.1 AuraContainer-managed buttons: **no `SetScript`/`HookScript` at all**, not even hooked — see the AuraEngine section above.

### Secret Numbers (Tainted Values)
- `UnitHealth`, `UnitHealthMax`, `UnitPower`, `UnitGetTotalAbsorbs` can return "secret numbers" (tainted).
- **Arithmetic on them taints** → use `SetMinMaxValues`/`SetValue`/`SetFormattedText` directly (C-level handles secrets).
- For preview/fake data: `pcall(UnitHealth, "player")` + `pcall(function() return val + 0 end)` to sanitize.
- On 12.1, **aura data is secret too** while auras are secret (combat/encounters) — this is the whole reason the AuraEngine subsystem exists; see section 7 above. Don't try to extend the `pcall`-sanitize pattern to auras — there is no safe manual read, only the managed AuraContainer API.

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

- **Target**: WoW 12.1 — `## Interface: 120100, 120007`. 12.1 is live on retail; 12.0.7 is still listed as a secondary supported interface version since all the legacy code paths remain intact.
- **12.1 code paths**: rather than a separate branch/release, 12.1-only code paths live in this codebase gated at runtime by `SquizzFrames.IS_121` (`Utils.lua`, build number `>= 120100`) rather than by TOC/`.toc`-version branching. This covers the AuraEngine subsystem (section 7), and the click-casting proxy transport fix. These are **active** on a 12.1 client and inert on 12.0.7.
- Uses modern APIs: `C_AddOns.GetAddOnMetadata`, `C_Spell.GetSpellName`, `C_Spell.GetSpellInfo`, `C_UnitAuras`, `C_Item.IsUsableItem`
- Fallback globals provided in Utils/Core for older API compat

---

## Memory/Performance Notes

- **No periodic OnUpdate loops** for the legacy pipeline — event-driven via AceEvent + secure header
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
