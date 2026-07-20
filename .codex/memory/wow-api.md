# WoW patch, API, and Secret Values memory

Read this before patch-sensitive WoW work. Reverify all details against the current client/API docs;
these notes include tested historical findings, not permanent API guarantees.

## Patch state and verification rule

- HagAIO targets retail World of Warcraft: Midnight, 12.0.x.
- Historical Claude snapshot (2026-06-05): repo targeted 12.0.5 / Interface 120005 and expected 12.0.7.
- Verified while porting on 2026-07-20: Blizzard says Revelations is live; the Warcraft Wiki API
  changes page records 12.0.7 / Interface 120007 and next patch 12.1.0. The tracked `.toc` remains the
  repository source of truth until deliberately bumped with an API audit.
- Before using or reviewing any WoW API, verify the current function, signature, security tags, and
  patch changes on current Warcraft Wiki/Blizzard sources. APIs frequently move into `C_*`, disappear,
  or change return/security behavior.
- Known Midnight migrations include `C_AddOns.GetAddOnMetadata`, the modern Settings registration API,
  and removal of `UNIT_HEALTH_FREQUENT` (use `UNIT_HEALTH`). EventBus registration is pcall-guarded so
  an unknown event cannot abort a module, but this is not permission to use stale names.

Current reference links:

- https://warcraft.wiki.gg/wiki/Patch_12.0.7/API_changes
- https://worldofwarcraft.blizzard.com/news/24244888

## Secret Values: general rules

- Midnight restricts combat/unit data so addons may display some values without learning or branching
  on them. Arithmetic, comparison, conditionals, conversion, and some calls reject or propagate secrets.
- Inspect with `issecretvalue`, `C_Secrets.ShouldUnit*BeSecret`, and
  `FrameScriptObject:HasSecretValues` where current docs support them.
- Never invoke a Blizzard function from tainted addon execution merely to force a refresh if its body
  compares secret data. A secure post-hook is safe only because Blizzard ran its body first. `pcall`
  does not make taint/secret violations safe.
- Layout reads inside a Blizzard unit-frame update can flush pending layout and taint a secret-health
  comparison. Defer layout reads to the next frame and filter hooks to the actual unit frame.

## Secret-safe visual sinks

- Frame geometry (anchors, offsets, size/minimum-width aspects) cannot consume secrets directly.
- `StatusBar:SetValue(secretNumber)` accepts a secret and lets the engine compute fill geometry. Set
  min/max/width using plain data, then pass the secret only to SetValue.
- `SetAlphaFromBoolean` and `SetVertexColorFromBoolean` can render secret booleans.
- FontString text and appropriate StatusBar/Cooldown duration APIs may accept secrets according to
  their current security tags; verify before use.
- `tonumber(secret)` throws. A secret string can be displayed but cannot be converted to a number or
  boolean for addon logic.
- `ColorCurveObject:Evaluate(secret)` throws from addon/tainted code despite the accessor-like tag.
  Curves work on secret data only when a Blizzard accessor evaluates them untainted.

## Health color curves

The sanctioned health-color route is to pass a curve into `UnitHealthPercent`, then feed the returned
secret color directly into a texture:

```lua
local curve = C_CurveUtil.CreateColorCurve()
curve:SetType(Enum.LuaCurveType.Linear)
curve:AddPoint(0.0, CreateColor(1, 0, 0, 1))
curve:AddPoint(0.3, CreateColor(1, 1, 0, 1))
curve:AddPoint(0.7, CreateColor(0, 1, 0, 1))
local color = UnitHealthPercent(unit, true, curve)
bar:GetStatusBarTexture():SetVertexColor(color:GetRGB())
```

Tested constraints:

- Use `GetStatusBarTexture():SetVertexColor`; `SetStatusBarColor` historically ignored secret colors.
- The default health-bar atlas is green, and vertex tint multiplies it. Swap once to a flat
  `Interface\TargetingFrame\UI-StatusBar`/white texture for unrestricted hue, preserving/restoring the
  original atlas on disable.
- Recolor from `UNIT_HEALTH`, plus applicable max-health/target-change events. The
  `UnitFrameHealthBar_Update` hook is for discovering the visible bar, not health-change cadence.
- `PlayerFrame.healthbar` aliases can be hidden. The statusbar passed to Blizzard's update hook is the
  reliable visible object; capture it after checking `statusbar.unitFrame`.
- Do not call `UnitFrameHealthBar_Update` yourself. Apply the resulting visual directly.

## Arbitrary secret numbers and the Brewmaster orb marker

- There is no generic untainted curve evaluator for arbitrary secret numbers.
- Confirmed historical source: `C_Spell.GetSpellCastCount(322101)` returns the absorbable Expel Harm
  sphere count and becomes a secret number under restrictions. Reverify on the active patch.
- The working marker uses a flat-texture StatusBar. Compute its min/max/width and base offset with
  plain cached values, then call `SetValue(secretCount)`. The fill edge represents
  `baseHeal + count * orbHeal` without Lua reading the count.
- A separate 1px base-heal line remains visible; the translucent orb fill extends from it. Gate the
  feature on the appropriate Gift/Spirit talent and poll because sphere count lacks a dedicated event.
- Earlier dead ends must not be resurrected: moving a line with secret geometry, a custom font-glyph
  encoder, color-ladder position substitutes, and per-rung `ColorCurve:Evaluate(secret)`.
- `UnitHealthMax` may also be secret. Cache a non-secret max-HP snapshot out of restricted execution
  and use that scalar for geometry.

## Cooldowns

- `C_Spell.GetSpellCooldown` duration fields may be secret while booleans such as active/enabled/GCD
  remain plain. Verify the current structure/security tags.
- Historically, addon-tainted `Cooldown:SetCooldown(start, duration)` rejected secret arguments.
  Prefer sanctioned duration-object sinks where current APIs allow them, or react using plain
  cooldown booleans and spellcast/cooldown events.

## Range checks

- `IsSpellInRange` can be nil for self/no-target spells; `CheckInteractDistance` is forbidden in
  combat; `UnitInRange` only covers party/raid semantics.
- The established combat-safe fixed-yardage technique is `C_Item.IsItemInRange(itemID, unit)` with a
  harm item for that bracket after requesting item data; ownership is not required. Revalidate the
  item table/current API before adding a bracket. Historical 8yd reference item: Burning Torch 33278.
- `C_Spell.GetSpellInfo` exposes range metadata for spells where applicable.

## Spell formulas

- Inspect SimulationCraft's `midnight` branch, normally `engine/class_modules/<class>/`, for the exact
  formula before implementing spell damage/healing/scaling/procs/thresholds.
- A plateau is visible as a threshold/min clamp; linear missing-health behavior continues to zero;
  usability gates live in the action condition rather than the magnitude formula.
- Historical example: Brewmaster Strength of Spirit and Niuzao's Resolve used a pure missing-health
  linear multiplier without a tooltip-implied plateau. Always reverify current source.

## Local addon references

- Installed AddOns live under
  `C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\<AddonName>` (or the configured
  override). Read actual source/globals/frames/data/license before integrating.
- If the preferred reference is absent, ask the user to install the exact addon and pause that part of
  the work. Do not replace primary-source inspection with a web summary.
- Historical Brewmaster reference: Brewmaster Utilities by renanthera. Revalidate before reuse.
