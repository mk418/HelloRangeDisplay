# HelloRangeDisplay

A lean estimated-range readout for WoW Classic Era. Shows roughly how far away
your target is, in the colour that tells you whether you can cast at it.

Written as a replacement for
[RangeDisplay](https://www.curseforge.com/wow/addons/range-display), which
stopped working when patch 1.15.9 moved Classic Era onto the modern UI codebase
and retired the `LEARNED_SPELL_IN_TAB` event its range-check library registers on
load.

> **Heads up** — this is a personal work in progress. I build and evolve it as I
> play using it, so features land when I need them and design choices reflect my
> play style.

## What it shows

```
        20 - 30
```

A bracket, not a number. Nothing in the game will tell an addon how far away a
unit is, so the range is inferred from the questions your character *can* ask —
"is that within 30 yards" — using your spells, cached item ranges and interact
distances. The two numbers are the tightest pair of answers available; the real
distance is somewhere between them.

Colour is the part you actually read, and it says what you can *do*, not how many
yards away something is:

| Colour | Meaning |
| --- | --- |
| Amber | Too close — inside the minimum range of your longest attack |
| Green | Comfortably in range |
| Gold | At the edge of your range |
| Red | Out of reach — the cast will fail |

There are no threshold settings, because the thresholds come from your own
spellbook. A mage is green out to 26 yards and gold to 35; a hunter gets amber
under 5 where their shots won't fire; a warrior is green only in melee, because
that's where a warrior needs to be. Talents that extend your range move the bands
with them, and so does every level you gain. The options panel shows where they
landed for your character.

Readouts are available for your **target** and your **mouseover** (which can
follow the cursor like a tooltip, and works on raid frames — so a healer can
check range on someone without giving up their target).

## Commands

| Command | Effect |
| --- | --- |
| `/hrd` | Show / hide the readouts |
| `/hrd config` | Open the options panel |
| `/hrd lock` · `/hrd unlock` | Lock the frames (locked also means click-through) |
| `/hrd resetpos` | Move the frames back to their default positions |
| `/hrd reset` | Reset every setting (asks first) |
| `/hrd scan` | Dump every range check the addon found, and what it reads right now |
| `/hrd dump` | Record a diagnostic snapshot to saved variables (needs a `/reload` to hit disk) |

Unlock the frames to drag them; they show a labelled backdrop and a sample
reading so you can place them without hunting for a target first.

## Caveats

- Only works on Classic Era, no support for other game versions.
- **Every number is an estimate.** The precision you get depends on your class
  and on how many item ranges your client has cached — a mage with six spells and
  six cached buckets gets tight brackets, a fresh warrior gets `8 - 28`. `/hrd
  scan` shows exactly what's available on your character.
- **Interact distances are measured, not documented.** They vary with your race's
  hitbox; only Tauren and Undead overrides are known, so other races get the
  defaults.
- Spell ranges are read from the client, so talents that extend them are handled
  automatically — but a spell you can't currently cast may still report as out of
  range and slightly widen the bracket. See `DESIGN.md`.

## Testing

`Tests.lua` runs the range engine outside the game against a stubbed API:

```sh
lua Tests.lua .
```

892 checks across eight simulated characters, including the invariant that the
reported bracket always contains the true distance.

## License

Released under the [MIT License](LICENSE).

Item range data adapted from
[LibRangeCheck-3.0](https://github.com/WoWUIDev/LibRangeCheck-3.0) (MIT,
© 2023 The WoWUIDev Community).
