# SquizzFrames

Party and raid frames for World of Warcraft Retail, built for patch 12.1.

Compact unit frames with a Cell-style indicator system, click-casting, and
nicknames — designed around healing, where the frames are the game.

**[Download on CurseForge](https://www.curseforge.com/projects/1649203)** ·
[Changelog](CHANGELOG.txt)

---

## Features

**Frames**
- Party and raid layouts with independent size, spacing, position and profile
- Raid frames are laid out per subgroup, with role sorting applied *within* each
  group rather than rearranging the whole raid
- Growth in any direction, including centred growth on either axis
- Pet frames, drag-to-move edit mode, and a live layout preview
- Range fading, aggro highlighting, ready-check and summon status, drinking
  status

**Indicators**
- Built-in indicators for HoTs, external and defensive cooldowns, debuffs, CC,
  dispels, shields, and more, each positionable anywhere on the button
- Custom indicators driven by your own spell lists
- On 12.1 the aura indicators run on Blizzard's managed AuraContainer API, so
  they keep working during combat, when aura data is otherwise hidden from
  addons

**Click-casting**
- Bind spells, items, macros, target/focus and menus to any mouse button, key
  or modifier combination
- Optionally extends the same bindings to Blizzard's player, target, focus and
  boss frames

**Nicknames**
- Show a short nickname in place of a long cross-realm character name
- A private list only you see, plus an optional shared nickname sent to other
  SquizzFrames users in your group
- Your own entries always win, and incoming names are sanitised

## Installing

Install from [CurseForge](https://www.curseforge.com/projects/1649203), or
manually: download this repository and drop the `SquizzFrames` folder into

```
World of Warcraft\_retail_\Interface\AddOns\
```

Requires WoW Retail 12.1 (interface 120100). All libraries are bundled — there
is nothing else to install.

## Commands

| Command | What it does |
|---------|--------------|
| `/sf` | Open the options panel |
| `/sf lock` / `/sf unlock` | Lock or unlock the frames for dragging |
| `/sf healer` | Apply the healer preset |
| `/sf nick` | Nickname management (run alone for usage) |
| `/sf reset` | Reset the profile and reload the UI |

`/squizz` is not used — that belongs to another addon.

## Bugs and requests

Please open an [issue](../../issues). A copy of the error text (BugSack or
similar) and what you were doing at the time is enormously helpful, especially
for anything that only happens in combat.

## Credits

Secure frame and indicator techniques were learned from **Cell**,
**DandersFrames** and **EllesmereUIRaidFrames**, and from Blizzard's own
FrameXML source. All code here is written for SquizzFrames.

Bundled libraries: Ace3, LibStub, CallbackHandler-1.0, LibSharedMedia-3.0,
LibCustomGlow-1.0, LibRangeCheck-3.0, LibDeflate, LibSerialize — each under its
own license.

## License

[MIT](LICENSE).
