# SquizzFrames

Party, raid, pet and unit frames for World of Warcraft Retail, built for patch 12.1.

Built around healing, where the frames are the game. Aura indicators run on Blizzard's own aura
system (AuraContainer), so they keep working in combat, when aura data is hidden from addons.

**[Download on CurseForge](https://www.curseforge.com/projects/1649203)** ·
[Changelog](CHANGELOG.txt)

---

## Features

**Party and raid frames**
- Separate party and raid layouts: size, spacing, position, growth direction (including centred)
  and opacity
- Raid frames laid out per group, with role sorting applied *within* each group
- Health colours by class, or by how hurt someone is (green through amber to red)
- Range fading, aggro, ready check, summon, drinking and phasing status, plus the game's ping
  markers on your frames
- Pet frames, attached to their owner or as a free group

**Indicators**
- HoTs can light up in gold during their refresh (pandemic) window, so you know when a recast
  won't waste time, in combat too
- Built-in indicators for HoTs, external and defensive cooldowns, debuffs (with a filter), crowd
  control, dispels (health-bar overlay and type icons), shields, heal absorbs, missing raid buffs,
  role, leader, raid marker, target and hover highlights, and more
- Custom indicators driven by your own spell lists
- Place any indicator anywhere with one anchor point and an offset, in a live preview
- One-click Healer preset

**Unit frames**
- Player, target, target of target, focus, focus target, boss and arena frames
- Arena frames show each opponent's spec, class and role before the gates open, and each
  enemy's trinket, crowd control and diminishing returns during the match (Blizzard's own icons,
  moved beside your frames)
- Cast bars, 2D/3D portraits, buff and debuff rows, absorb overlays, dispel overlays and icons,
  hover/target/aggro highlights, combat and leader icons, borders, and configurable text
- Attach unit frames and cast bars to Squizzumables' cooldown groups or Blizzard's Cooldown
  Manager rows, optionally matching their height

**Resource bar**
- A movable power bar plus your class resource points, together or placed separately
- Points as bars, shapes (round, star, heart, runes and more) or Blizzard's own class art, with
  rainbow colours and borders that follow the shape

**Tank tracker**
- A frame per tank showing their incoming debuffs above and their defensives below

**Click-casting**
- Bind spells, items, macros, target/focus and menus to any mouse button, key or mouse wheel,
  with any modifier
- Optionally extends the same bindings to Blizzard's player, target, focus and boss frames
- A heal aimed at a player who just died does nothing, instead of the game casting it on you

**Nicknames**
- Show a short nickname in place of a long character name: a private list only you see, plus an
  optional nickname shared with other SquizzFrames users in your group
- Your own entries always win, and incoming names are sanitised

**Everything else**
- Edit Mode alignment grid in your class colour, with snapping to the screen centre, edges and
  other frames, shared with Squizzumables
- Profiles that switch automatically by specialization and situation
- Hides the Blizzard frames it replaces, with one switch

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
| `/sf notes` | Show this version's release notes again |
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
own license — plus LibSquizzGrid-1.0, shared with Squizzumables.

## Support

If you enjoy using SquizzFrames, consider supporting development on
[Ko-fi](https://ko-fi.com/squizz) ❤️

## More addons by Squizz

- **[Squizzumables](https://www.curseforge.com/projects/1483099)** — one-click reminders for food, flasks, oils and class buffs, plus raid tools and a restyled Cooldown Manager
- **[Squizzcap](https://www.curseforge.com/projects/1713974)** — what killed you, how hard it hit and how fast you went down, with every death of a key saved to look back on
- **[SquizzTalents](https://www.curseforge.com/projects/1705647)** — all your talent builds in one list, with a reminder when your build doesn't match the content
- **[DPS Report](https://www.curseforge.com/projects/1504877)** — a lightweight damage meter with spell breakdowns and an end-of-key MVP summary
- **[Avatar Continued](https://www.curseforge.com/projects/1533608)** — your character model on screen as part of your UI
- **[KSLBestDungeon](https://www.curseforge.com/projects/1599575)** — ranks Mythic+ dungeons by how many of your KeystoneLoot favorites drop there

## License

[MIT](LICENSE).
