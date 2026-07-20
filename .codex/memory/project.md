# HagAIO durable project memory

This file consolidates the durable content from Claude's curated project memories. Dated facts are
historical context, not a substitute for reading the current repository or official sources.

## User and project

- The user is a system architect and senior developer with a major in consumer psychology. Work at
  architecture altitude and use behavioral/UX reasoning where relevant.
- HagAIO is a public all-in-one retail World of Warcraft addon (`Hagryph/HagAIO`) with an OOP Lua
  framework, managers/registries, services, modules/submodules, a themed widget/UI layer, a shared
  relational DB, and a headless test suite.
- Work in the main checkout, never a generated Claude worktree. Generated files and deployment are
  path-relative, so a worktree produces the deliverable in the wrong place.

## Runtime and validation

- The target runtime is LuaJIT 2.1 / Lua 5.1 semantics, matching WoW. Local binary:
  `C:\Users\Yannis\AppData\Local\Programs\LuaJIT\bin\luajit.exe`.
- Run the complete project gate from the repo root with `node tools/check.mjs`. The direct Lua suite
  is `luajit Test/run.lua`. Never fall back to syntax-only checking after Lua changes.
- Repository tooling is authoritative for load order, dependency checks, dead-code advisories,
  widget/frame rules, persistence boundaries, generated schema, and test discovery. Read the current
  scripts rather than relying on old command lists or historical pass counts.
- WoW's Lua runtime provides `math.atan2`; do not rewrite working `atan2` calls as a portability fix.

## OOP structure target

The standing design target is "make everything a class that can be." A no-instance surface is still
classable and should normally be a class with static methods/private statics. Reserve a plain static
table for genuinely boot-critical or function-bag cases that cannot sensibly use the class system.

Recognized structures:

1. Classes: `ns.Class.new(name, parent, opts)`.
2. Private instance attributes: weak side-table state reached only via `:_p()` and exposed through
   methods, never public instance fields.
3. Static/abstract members: dot methods for statics; `opts.statics` plus `:_statics()` /
   `ns.Class.statics()` for private class state; `opts.abstract` and `ns.Class.abstract()` for
   non-instantiable bases/required overrides.
4. Inheritance: parent passed to `Class.new`; super calls use the class where the method is defined,
   e.g. `Derived.super.Method(self, ...)`.
5. Value types: `ns.Type.new(name, fields, defaults)` for small immutable, content-compared objects.
6. Singletons: enforced by class semantics and constructed exactly once at the owning file's
   registration/bootstrap point; never reintroduce lazy `.Get()` creation.
7. Namespace: every addon file begins with `local addonName, ns = ...`; published surfaces hang off
   `ns` through the appropriate manager/publish mechanism.
8. Static helper tables: only where a class/value object is genuinely inappropriate.
9. Enums: frozen, typo-safe `ns.Enum.new`; use `names/has/nameOf/each` for inspection.
10. Mixins: `ns.Mixin.new`, applied through `opts.mixins` or `applyTo`.
11. Interfaces: `ns.Interface.new`, normally enforced with `opts.implements`.
12. Events/delegates: `ns.Delegate` for object-local multicast state; EventBus for app-wide channels.

All attributes remain private. Constants owned by a class belong in private statics behind accessors.
Free functions owned by a surface become private instance methods or static dot methods.

## Construction and lifecycle

- Each service/module/submodule/lib/UI window constructs and registers itself at its own file tail.
  This locality is deliberate: the definition and participation point stay together.
- Do not centralize class construction into `Core/Init.lua` or defer it to `StartAll`. Live lib/module
  instances are needed during file load and before the table-contribution sweep. Construction must be
  dependency-free; dependency-ordered behavior belongs in lifecycle hooks such as `OnInitialize`.
- Core manager/bootstrap self-instantiation and Init's load-order guard are intentional.

## Value types and persistence boundary

- `ns.Type` instances keep their fields in Class's weak private side table; the visible table is
  empty. Passing one to the DB/serializer produces an empty object and silent data loss. Pairs-based
  structural equality also cannot compare the hidden values.
- Rich values such as `ns.Color` live from `Component:GetSetting`/`SetSetting` outward. DB rows,
  SettingsTables, Profiles, serializer, exports, and saved variables use plain scalars/triples.
- Color defaults may be authored as `ns.Color`, but must be decomposed at the settings boundary.
  Decline refactors that push `ns.Color` or another `ns.Type` through persistence.

## Worker, DB, and events

- Worker has a 2ms pump budget. The overshoot report names the worst job step; inspect that label first.
- Long Worker loops call `ns.Worker:MaybeYield()`. It yields only from the active job coroutine when
  budget is exhausted and is a cheap no-op elsewhere.
- QueryExecutor self-partitions row scans and guards yields against table mutation. Module callers do
  not need redundant yields around ordinary queries.
- Preserve indexed query shapes: top-level AND equality on PK/unique/index/FK plus LIMIT can probe an
  index. Top-level OR disables narrowing. Prefer map predicates for keyed Update/Delete operations.
- Route deferrable catalogs, snapshots, backfills, periodic maintenance, and large row/item loops
  through Worker. Keep combat/real-time logic, watched timers, direct UI feedback, and protected-event
  work immediate and O(small). Litmus test: if being three frames late is wrong, keep it immediate.
- Never debounce/throttle WoW game events. Every fire may carry the state transition that matters.
  Make hot handlers cheap through reverse indexes/precomputed state instead of dropping fires.
- If Worker work hitches, add finer chunk points or fix Worker behavior. Do not add login calm periods
  or arbitrary delay windows. `DEBUG_FORCE_STALE` in Versioning is intentional developer tooling.

## UI and copy

- Visual language comes from the LoL Game Helper dark-blue theme. Canonical desktop palette/patterns:
  `C:\Users\Yannis\Desktop\Desktop\projects\LoL Game Helper\app\src\renderer\src\theme.css`.
- HagAIO uses near-black blue backgrounds, restrained cyan `#4ab3e6`, crisp thin borders, subdued
  secondary text, and signal green/amber/red. Use `ns.UI.Widgets`, BackdropTemplate, and WHITE8X8;
  do not invent a parallel styling path.
- Active navigation uses an accent left bar, soft accent tint, and accent text. WoW lacks CSS rounded
  corners and true letter spacing; use rectangular panels and small uppercase/dim labels.
- Displayed strings must use plain player language and ASCII-safe glyphs. Explain what a feature does,
  not APIs or mechanisms. Technical detail belongs in comments.

## Research and integrations

- Research current best practices and current external facts before acting. WoW APIs and UI security
  rules are especially volatile; never trust an old memory as current documentation.
- For another addon integration, read its installed `.lua`/`.toc` source under the retail AddOns
  directory. Inspect globals, public functions, data/SavedVariables shape, frames, and license.
- If the best reference addon is not installed, pause and ask the user to install the exact addon.
  Local source is the primary implementation reference; web docs can supplement signatures.
- ATT historical notes: `_G.AllTheThings`/`ATTC`, `app.SearchForField`, `app.GetLinkReference`, and
  `app.Windows[*].Container.rows`; lazy row metatables require `rawget`-aware iteration. Revalidate
  against the installed version before use.
- For browser/download work, use Codex browser control or a purpose-built connector when available,
  while still respecting approval boundaries for risky or irreversible actions.

## Spell mechanics

- Before modeling damage, healing, scaling, procs, thresholds, or plateaus, inspect the exact current
  formula in SimulationCraft (`simulationcraft/simc`, `midnight`, class module source). Tooltips are
  ambiguous and locale-dependent.
- Distinguish linear-to-zero, plateau (`min`/threshold clamp), and usability gates. Model applicable
  health scaling through the existing Scaling service and apply it secret-safely.

## Delivery workflow

- After source changes, run `deploy.ps1` to mirror runtime files into
  `C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\HagAIO`. Deployment can delete
  stale target files because it mirrors; surface failures. Deployment does not reload the game.
- After each completed in-scope turn, commit intentionally with an `Area: summary` message and push
  `origin/main`. The public repo uses direct-to-main workflow by standing user preference.
- Never sweep unrelated/user-owned changes into a commit. When working in another repository, do not
  touch or checkpoint HagAIO's independent dirty state.
- If authentication/network prevents push, report it and ask how to proceed.
