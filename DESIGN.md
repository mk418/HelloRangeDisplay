# HelloRangeDisplay — Design Document

An estimated-range readout for World of Warcraft Classic Era. Replaces
RangeDisplay, which broke on patch 1.15.9.

---

## Why this exists

RangeDisplay tells you roughly how far away your target is, which is the
difference between casting and eating a "target out of range" for the third time
in a pull. It stopped working on 1.15.9, and the failure is in its dependency,
not in RangeDisplay itself:

```
Frame:RegisterEvent(): Attempt to register unknown event "LEARNED_SPELL_IN_TAB"
[LibRangeCheck-3.0.lua]:4598: in function '?'
[LibRangeCheck-3.0.lua]:4664: in main chunk
```

1.15.9 moved Era onto the shared modern UI codebase, which retired
`LEARNED_SPELL_IN_TAB`. LibRangeCheck-3.0 registers it unconditionally for
everything that isn't Midnight or TBC, and does so in `lib:activate()` — the last
statement of the file. The error aborts the main chunk, so the library's
`OnUpdate` and `OnEvent` handlers are never installed, it never initialises, and
every `rc:GetRange()` call returns nothing. RangeDisplay wraps that call in
`pcall` and renders an empty string, so it fails silently rather than loudly.

That is a one-line fix upstream. Rewriting instead buys the removal of ten
bundled libraries totalling 7,703 lines (LibStub, CallbackHandler,
LibRangeCheck-3.0, four Ace3 modules, LibSharedMedia, LibDualSpec,
LibDataBroker), a separate load-on-demand options addon carrying an AceConfig
tree and nine locales, and a range-check library whose 3,600 lines of static
tables cover every expansion at once — Era uses a fraction of them.

---

## Design philosophy

1. **Answer one question well.** How far away is that, roughly. Colour it so the
   answer is readable without being read.
2. **Never lie about precision.** There is no API that returns a distance. Every
   number here is a bracket boundary, the display always shows both edges, and
   when the character owns no test that applies to a unit it shows nothing rather
   than a confident wrong number.
3. **Read the game, don't hard-code it.** No spell yardage appears anywhere in
   this addon. Ranges come from the client at build time, so talents that move
   them (Destructive Reach, Hawk Eye, Nature's Reach) are handled for free, and
   so is every rune and season the data tables never heard of.
4. **Event-driven, with one honest exception.** Nothing tells an addon that a
   unit moved, so range genuinely has to be polled. That poll is the only CPU
   this addon spends, and it stops entirely when no readout is on screen.
5. **No libraries.** Family rule: they're a future-patch breakage surface — which
   is, precisely and literally, why this addon exists.

---

## Current scope

- **Range readout** for target and mouseover: `18 - 20`, collapsing to `35 +`
  once you're past everything you can reach.
- **Colour bands derived from your own spell ranges** — amber / green / gold /
  red, meaning too close, in range, at the edge, out of reach. Nothing to
  configure.
- **Cursor-anchored mouseover readout**, so it reads like a tooltip.
- Draggable, lockable, scalable frames; locked frames are click-through.

## Out of scope

- **Focus and arena units.** Neither exists in Classic Era. RangeDisplay carries
  `focus` plus `arena1`–`arena5` and gates them on project ID; that gating was
  most of its unit-handling code.
- **A pet readout.** RangeDisplay has one, defaulted off. The only question it
  answers is "is my pet still inside Mend Pet / Health Funnel range", which is a
  hunter and warlock question and nobody else's. The pet *checker list* is kept —
  your pet can be your target or your mouseover, and `PET_ONLY_SPELLS` has to
  exist regardless to keep those spells out of the friendly list.
- **An out-of-reach alert sound.** Built, auditioned against every candidate the
  client has, and cut: red already says it, at the moment it changes, on the
  thing you're already looking at. A second channel for information the display
  carries anyway isn't worth a setting, a checkbox and a media picker — which is
  the road that ends at bundling three `.ogg` files, as RangeDisplay does.
- **Custom fonts, textures, backdrops, sounds.** These are what LibSharedMedia
  and half the options tree were for. The readout inherits Blizzard's outlined
  number font and scales.
- **Per-unit everything.** RangeDisplay gives every unit its own copy of all 40-odd
  settings, six colour sections included. Here the units share one set of bands
  and one scale, and own only their position and their on/off switch.
- **Configurable colour thresholds.** RangeDisplay gives every unit six colour
  sections with an editable yardage each. Those numbers are the same for every
  character, which means they are wrong for most of them: 30 yards is a
  comfortable cast for a mage and a failed pull for a warrior. Deriving them from
  the spellbook is both more accurate and less to explain. See below.
- **Custom colours, per-section text formats, profiles, dual spec, LDB launcher.**

---

## File structure

```
HelloRangeDisplay/
├── HelloRangeDisplay.toc
├── Ranges.lua      -- static data: item range buckets, interact distances, and
│                      the spell classification hints
├── RangeCheck.lua  -- the engine: builds the checker lists and resolves a unit
│                      to a bracket
├── Core.lua        -- saved variables, the unit registry, events, slash commands
├── Display.lua     -- the readout frames, their colours and the poll
├── Options.lua     -- canvas options panel
└── Tests.lua       -- offline harness; not in the TOC, never loaded by the game
```

---

## How range estimation works

### The bracket

There is no "distance to unit" API. What the client does offer is a pile of
yes/no questions — *is this unit within 30 yards* — via spells, items and
interact distances. Collect every one the character can ask, sort by range, and
binary-search for the boundary between the yesses and the noes. Two adjacent
checkers bound the answer: `20 - 30`.

The list is sorted descending and the search moves toward shorter ranges on a
yes, so it costs `log2(n)` checker calls — about four — per unit per poll.

### Where the checkers come from

**Spells.** The spellbook is walked on `SPELLS_CHANGED`. Every non-passive entry
with a range becomes a candidate, and its name, minimum and maximum range come
from the client. Two consequences worth stating plainly:

- No spell yardage is hard-coded anywhere in this addon. A warlock with
  Destructive Reach gets 36-yard checkers because the client says 36.
- Ranks are resolved by name, keeping the longest-ranged rank known. That makes
  the result independent of the "show all spell ranks" setting, which otherwise
  puts rank 1 first in the spellbook and would silently pin every caster to
  their level-1 ranges.

**Classification.** A checker is only valid against units the spell can actually
target, so each spell has to be sorted into harmful or helpful. `C_Spell.IsSpellHarmful`
/ `IsSpellHelpful` are used when present, with the legacy `IsHarmfulSpell` /
`IsHelpfulSpell` globals as a fallback and the hint tables in `Ranges.lua` as the
floor. A spell the client calls *both* or *neither* is left to the hints rather
than guessed at. `/hrd scan` prints which source was used.

This is the one place the addon does better than the library it replaces:
LibRangeCheck ships a hand-maintained list of spell IDs per class per expansion,
and every Season of Discovery rune that changes a range needs a library update
(403677 and 426320 are in there for exactly that reason). Auto-discovery covers
those the day they ship. The hint tables remain as a safety net for a client that
won't classify.

**Items.** `C_Item.IsItemInRange` works on any item whose data the client has
cached, owned or not. Each bucket in `Ranges.lua` lists a few alternates and the
first one to cache wins; item data is requested once at login and the lists
rebuild as the answers arrive. IDs and ranges are lifted from LibRangeCheck-3.0
(MIT, © 2023 The WoWUIDev Community) and trimmed to Era.

**Interact distances.** `CheckInteractDistance` indices 3 (duel, ~8y) and 4
(follow, ~28y), adjusted for Tauren and Undead because the distances depend on
the player's hitbox. These are measured, not documented, and coarse, so they are
only used by a character with no cached item buckets at all. Indices 1 and 2 need
a same-faction player and would quietly stop working on exactly the units you
most want a range for.

### The lists

Six of them, because a checker is only meaningful against the right kind of unit:

| List | Used for | Contents |
| --- | --- | --- |
| `harm` | anything you can attack | harmful spells, harm items, interact |
| `friend` | living friendly units | helpful spells, friend items, interact |
| `friendRestricted` | the same, in combat | helpful spells only |
| `pet` | your own pet, when it's your target or mouseover | friendly list plus Mend Pet / Health Funnel |
| `res` | corpses you can resurrect | resurrection spells, interact |
| `misc` | everything else | interact only |

### Checkers that can only ever answer "no"

This is the failure mode that shapes half the engine, and it's worth being
explicit about because it is invisible when it happens.

`IsSpellInRange` returns `nil` — not `false` — when a spell cannot target the
unit at all, and the search reads that as "out of range". One such checker sitting
in the middle of a list makes the binary search believe the unit is beyond it, so
a party member standing next to you reads as `30 - 45`. Nothing errors; the number
is just wrong.

The client calls resurrection spells and pet spells *helpful*, so plain
auto-classification drops both straight into the friendly list, where neither can
ever return true. Both are pulled out by name — `RES_SPELLS` and
`PET_ONLY_SPELLS` in `Ranges.lua` — and given their own lists, where they're the
right answer rather than the wrong one. Corpses are also routed before the
friendly branch in `GetRange`, because a dead unit is still "assistable" and every
heal answers `nil` on one.

The lists are a lower bound. A spell that can't currently be cast for a reason the
targeting check doesn't know about — wand Shoot with no wand equipped is the
likely one — could still be stuck. `/hrd scan` prints every checker in every list
so a suspicious reading can be traced to the checker that caused it.

### The colour bands

The bracket says how far; the colour says what you can do about it. Since the
engine already knows every range this character can check, the thresholds are
derived rather than configured — three numbers per list, computed at rebuild:

| | Meaning |
| --- | --- |
| `deadZone` | below this your longest attack won't fire — amber |
| `comfortMax` | you're well inside your range — green |
| `reachMax` | past this nothing you know reaches — red |

Between `comfortMax` and `reachMax` is the warning band, gold: still castable,
one step from not being.

`reachMax` is the longest **spell** range in the list, **capped at 40 yards**.
The cap matters. Nothing in vanilla attacks past 40, so anything longer is
utility — Hunter's Mark reaches 100 — and while that makes an excellent range
checker it is a terrible statement of how far a hunter can fight. Item and
interact checkers are excluded for the same reason: a cached 40-yard item bucket
is a distance you can *measure*, not one you can *cast at*.

`deadZone` is the minimum range of the spell that set `reachMax`, so a hunter
gets amber under 5 yards and a mage gets none. Where two spells reach equally
far, the one that also works up close wins — if anything covers the near ground
there's no dead zone to warn about.

**Melee characters are banded against melee.** `comfortMax` becomes melee range
rather than three quarters of `reachMax`: green means *in melee*, and the whole
span out to Throw or Taunt is the approach. A warrior at 20 yards is not in a
good place, however far Throw reaches, and colouring that green would be a lie.
Only the harm list does this — a paladin heals at 40 yards like anybody else,
they just don't fight there.

Whether a character is melee is decided per character, not per class, by three
checks in `RC:MeleePrimary`, cheapest first:

1. **Class.** Warrior, Rogue and Paladin fight in melee however they're specced —
   there is no ranged attack anywhere in the vanilla paladin kit, Holy included.
2. **Shapeshift form**, for druids. `GetShapeshiftFormID` returns a numeric form
   constant, so no names are involved. Cat, Bear and Dire Bear are melee;
   caster, travel, aquatic and moonkin are not.
3. **Talent tab**, for shamans. `GetTalentTabInfo`'s *fifth* return is
   `pointsSpent` in Classic Era, and tab indices come from the game's own data
   and are identical in every locale — only the tab name is translated. The tab
   with the most points wins; Enhancement is tab 2. A character who has spent
   nothing stays a caster.

Form beats talents where both could apply, and deliberately so: a feral druid
standing in caster form is casting, and a balance druid who just shifted to bear
is not. Talent points get both of those backwards.

Form changes fire `UPDATE_SHAPESHIFT_FORM`, which recomputes the bands only —
`RC:UpdateBands`, three numbers — rather than rebuilding the lists. A druid
shifts several times a fight; walking the spellbook and re-testing every item
bucket each time would not be acceptable. The call early-outs when the answer
hasn't changed, so a stance-dancing warrior pays almost nothing. Respecs come
through `CHARACTER_POINTS_CHANGED`, which does a full rebuild, because talents
move spell ranges as well as bands.

**Dual spec exists in Classic Era**, on Season of Discovery and Anniversary
realms — LibDualSpec gates itself on `C_Seasons.GetActiveSeason()` being 2, 11 or
12 — so two more things are needed:

- `GetTalentTabInfo` is passed `GetActiveTalentGroup()` as its fourth argument.
  Without it the points read can describe the spec you are *not* in, and an
  Enhancement shaman sitting in their second spec bands as a caster.
- `ACTIVE_TALENT_GROUP_CHANGED` triggers a full rebuild, since a swap moves spell
  ranges as well as bands. `CHARACTER_POINTS_CHANGED` does not fire on a swap.

That event only exists where dual spec does, so it is registered through
`RegisterIfValid`, which asks `C_EventUtils.IsEventValid` first and falls back to
a `pcall`. Registering an event the client has never heard of throws — one
unguarded `LEARNED_SPELL_IN_TAB` in a library's last statement is the entire
reason this addon exists, and the current upstream LibRangeCheck now guards that
same call the same way.

Brackets are compared at their **far** edge, so one straddling a boundary takes
the more cautious colour. Being warned a yard early beats being told you're fine
and eating "out of range".

The restricted in-combat lists inherit the bands of their unrestricted
counterparts. The bands describe the character, not the list, so losing item
checkers to the combat restriction must not move them.

### Minimum ranges

A spell with a minimum range answers "no" both when the unit is too far and when
it's too close. That is not a monotone test, and dropping it into a sorted list
sends the binary search into the wrong half — a hunter standing in melee would
read as "35+".

Each such spell is paired with any shorter checker that reaches at least its
minimum, giving "in range, **or** nearer than my minimum", which is monotone
again. A spell with no available partner is dropped rather than allowed to
distort the result. This is the same fix LibRangeCheck uses.

### The in-combat restriction

The client refuses `IsItemInRange` and `CheckInteractDistance` against units you
can't attack while you're in combat. Without a separate spell-only list for
friendly units, every friendly readout would jump to maximum range the moment you
were pulled into combat — which is the moment a healer actually needs it.

### Melee

A spell whose data reports range 0 is a melee ability. The distance at which the
client reports one in range depends on both combatants' hitboxes, so it isn't a
constant; `MELEE_RANGE = 2` follows LibRangeCheck's measured figure and matches
what RangeDisplay users have been reading for years.

---

## API notes for 1.15.9

- `LEARNED_SPELL_IN_TAB` no longer exists. `SPELLS_CHANGED` covers everything it
  did and is what the rebuild listens to, alongside `CHARACTER_POINTS_CHANGED`
  for talent changes that move spell ranges.
- The spellbook is enumerated through `C_SpellBook.GetNumSpellBookSkillLines` /
  `GetSpellBookSkillLineInfo` / `GetSpellBookItemInfo`, with the legacy
  `GetNumSpellTabs` / `GetSpellTabInfo` / `GetSpellBookItemInfo` chain kept only
  for pre-1.15.9 clients.
- `C_Spell.IsSpellInRange` takes a spell ID; the legacy global took a name. Both
  paths exist, chosen once at load time rather than per call.
- **`C_Spell.GetSpellInfo` reports `maxRange` 0 for every spell on 1.15.9.** It
  returns a table with the right fields, and the range ones are simply zero;
  the legacy global still returns the truth, positionally, with `minRange` and
  `maxRange` at 5 and 6. Confirmed by dump on a live shaman: Lightning Bolt,
  Earth Shock and Purge all came back `0-0`, which collapsed every caster to a
  2-yard melee character and painted the readout red past two yards. Both calls
  are now asked and the larger answer wins, so a genuinely melee spell still
  reads 0 and the addon survives the legacy global's eventual removal.
  LibRangeCheck never hit this because its shim is `_G.GetSpellInfo or <modern
  fallback>` — the global exists, so it never reaches the modern call.
  Root cause unknown; possibly spell data that `C_Spell.RequestLoadSpellData`
  would populate.
- **Passives must be filtered explicitly.** `C_SpellBook.GetSpellBookItemInfo`'s
  `isPassive` did not exclude an Orc shaman's Axe Specialization, which reached
  the friendly list as a 2-yard checker permanently stuck on "no".
  `C_Spell.IsSpellPassive` (or the legacy `IsPassiveSpell`) does the job.
  `SpellHasRange` then separates a real melee ability from anything else
  reporting range 0.
- Options registration must not override `category.ID` with a string;
  `Settings.OpenToCategory` feeds it to `C_SettingsUtil.OpenSettingsPanel`, which
  requires the auto-assigned numeric ID.
- `InterfaceOptionsCheckButtonTemplate` survives only inside
  `DeprecatedTemplates.xml`, so the panel inherits `UICheckButtonTemplate`.
- Fonts are inherited font objects (`NumberFontNormalHuge`), never `SetFont` with
  a path — family rule. Size comes from the scale slider.

---

## Boot sequence

1. **File load.** `Ranges.lua` defines the static tables. `RangeCheck.lua`
   resolves the API surface once and creates empty lists. `Core.lua` creates the
   event frame and registers `PLAYER_LOGIN` only. `Display.lua` and `Options.lua`
   build their frames. Nothing touches `HelloRangeDisplayDB` — it isn't populated
   yet.
2. **`PLAYER_LOGIN`.** Register the gameplay events, request item data, build the
   checker lists, apply settings to the frames.
3. **`SPELLS_CHANGED` / `CHARACTER_POINTS_CHANGED` / `GET_ITEM_INFO_RECEIVED`.**
   Coalesced into one rebuild a second — the last of these arrives a few hundred
   times in a row as the server answers the opening item request.
4. **Poll.** Ten times a second, while at least one readout is on screen.

---

## Testing

`Tests.lua` runs the engine outside the game under plain `lua`, against a stubbed
API: `lua Tests.lua .` from the addon root. It builds four characters (a mage with
spells and items, a hunter whose every attack has a minimum range, a warrior with
nothing cached and no classifier, a priest with a corpse in front of it) and
checks both specific brackets and the invariant that matters — *the reported
bracket contains the true distance* — at every half-yard from 0 to 60.

892 checks. It caught four real bugs: the resurrection and pet-spell poisoning
described above, a ground-targeted Rogue spell in the hint tables, and — once
`/hrd dump` brought real client data back out — the `C_Spell.GetSpellInfo` range
collapse and the passive-spell leak. The last two are reproduced directly from a
live dump, which is why scenario 7 stubs the modern call returning zeros.

---

## Known issues / TODO

- **The interact distances are measured, not documented,** and only two races'
  overrides are known. A Gnome or a Troll gets the default 8/28.
- **Hunter, Rogue and Warrior get no friendly readout while in combat.** None of
  the three has a helpful spell it can cast on another unit, so their friendly
  list is items and interact distances only — and both of those are refused
  against non-attackable units in combat, leaving nothing. The readout goes blank
  rather than wrong, which is the right failure, but it is a gap.
  `UnitInRange` would fill it: it's a 40-yard check that works in combat and for
  every class. It only answers for party and raid members though, and returns a
  flat "no" for anyone else, so it can't just be dropped into the list — it needs
  a group-only list of its own, gated on `UnitPlayerOrPetInParty`. Not built yet;
  the three classes affected are the three least likely to be watching a friendly
  unit's range.
- **Dual-spec reading is still unverified.** `GetTalentTabInfo`'s fifth return
  being `pointsSpent` is now confirmed on a live client, and so is Enhancement
  being tab 2 — a level 18 shaman with 9 points there banded as melee correctly.
  What is *not* confirmed is that passing `GetActiveTalentGroup()` picks the
  right group, because that needs a character with two specs and the test realm
  has one (`GetNumTalentGroups` returned 1, `C_Seasons.GetActiveSeason` returned
  nothing — dual spec lives on Season of Discovery and Anniversary realms).
- **A spell that can't currently be cast may still be stuck on "no"** (see above).
  Wand `Shoot` with no wand equipped is the suspected remaining case; the two
  confirmed ones, passives and corpse/pet-only spells, are handled.
- **No resurrection-range readout distinct from the normal one.** A corpse gets a
  bracket from the res list, but the display doesn't say "res range" anywhere.
- Mage and Shaman gladiator gloves modify spell ranges on later expansions, which
  is why LibRangeCheck watches `UNIT_INVENTORY_CHANGED` for those classes. No Era
  item does this, so the event isn't registered.
- No CurseForge project ID yet, so `.github/workflows/release.yml` will publish a
  GitHub Release but skip the CurseForge upload.
