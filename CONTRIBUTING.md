# Contributing to HagAIO

HagAIO is an OOP Lua addon for World of Warcraft (Midnight, 12.0.x). This file collects
the build/tooling conventions that live across the `tools/` headers so they're in one
place. For the architecture overview and the "add a module / submodule" recipes, see
[README.md](README.md).

## Layout

| Dir | What |
|---|---|
| `Core/` | Framework: class system, base classes, registries, the initializer |
| `Services/` | Long-lived service singletons (self-register with `ServiceManager`) |
| `Lib/` | Pure-logic helpers, no WoW API (self-register with `LibManager`) |
| `Modules/` | Toggleable features (self-register with `ModuleManager`) |
| `UI/` | Widget factory + themed windows |
| `Test/` | Headless spec suite (Lua 5.1 / LuaJIT) |
| `tools/` | Lint gates + generators (Node, zero npm deps) |
| `Dev/` | Local scratch space — git-ignored, excluded from deploy |

## Running the checks locally

CI (`.github/workflows/lint.yml`) runs the lint gates, the test suite, and two
generated-doc freshness checks. The gate list lives in **one place** —
`tools/check.mjs` — and CI runs that file directly (`node tools/check.mjs --lint`), so
a new gate added there reaches CI automatically. Reproduce everything in one command:

```
npm run check        # lint + tests (the same gates CI runs)
npm run lint         # just the lint gates
npm test             # just the Lua suite
```

Individual gates are also exposed: `npm run depcheck`, `npm run deadcode`. There are no
dependencies to install — the tools are plain Node ESM. The test runner auto-finds
`luajit` (or `lua`).

| Gate | Checks |
|---|---|
| `depcheck` | Every `ns.<Service/Module>` a file uses is declared as a dependency, and every defined service/module/lib/submodule self-registers |
| `deadcode` | No unused file-local declarations or uncalled private methods |
| `frames` | Nothing touches a raw frame/texture outside the Widgets layer |
| `widgets` | Every widget is defined the same way (one per file, named, registered) |
| `savedvars` | The persistence boundary holds (saved variables only via the SavedVars/DB layer) |
| `worker` | Worker stepper jobs contain no loops of their own (the Worker owns the loop) |
| `annotations` | Self-test for the shared lint-suppression parser (`tools/lib/annotations.mjs`) |
| `test` | `lua Test/run.lua` — the spec suite |

The deployed artifacts (`.toc`, the `Core/Namespace.lua` slot block) are generated at
deploy (see below). The **committed** docs (`README.md` regions, `DATABASE_SCHEMA.md`)
are regenerable anywhere via `./tools/autogen.ps1` — and CI regenerates them and fails
when they're stale, so a schema/file-layout change can't merge with drifted docs.

## Waiver / convention comments

The lint gates are heuristic (Lua is dynamic), so each has an in-file escape hatch for
deliberate exceptions. All of them are parsed by **one** shared parser
(`tools/lib/annotations.mjs`, self-tested by the `annotations` gate), in two scopes —
ESLint-style:

- **File-scoped, with allow-names** — `-- hag-lint-disable <rule>: name1, name2` (placed
  anywhere in the file). Used by:
  - `deadcode` — keep a public method/local the scan thinks is unused (public API, dynamic
    dispatch it can't see).
  - `depcheck` — waive specific undeclared-dependency references; the special name
    `noregister` waives the self-registration rule for a file that defines a
    service/module/submodule/lib but deliberately doesn't register it in the same file.
- **Line-scoped** (for the per-line gates `raw-frame`, `raw-texture`, `widget-call-form`,
  `mini-event-bus`, `worker-loop`):
  - `-- hag-lint-disable-next-line <rule>` — silence the rule on the **next** line.
  - `-- hag-lint-disable-line <rule>` — silence it on **this** line (trailing comment).
  - `-- hag-lint-disable <rule>` — silence it for the **whole file**.

  `<rule>` is the lint's rule id, or `*` / `all` for every rule. The structural-boundary
  gates (`savedvars`, `widgets`) deliberately have **no** escape hatch — those boundaries
  are absolute.
- **`EXEMPT` foundation set** (derived in `tools/depcheck.mjs` from
  `tools/load-order.json`) — the core singletons / base classes / statics whose own
  `ns.*` accesses aren't linted, because they're always available. These are exactly the
  manifest's pinned head (plus `Core/Init.lua`): the files that register neither a
  service nor a module. Repo-relative paths (e.g. `Core/Class.lua` is exempt;
  `Modules/Class.lua` the feature module is not).

## The load-order manifest

`tools/load-order.json` is the single machine-readable source for the addon's load order
and foundation file set. Four consumers read it: `tools/autogen/Common.ps1` (the `.toc`
file list + README tree), `tools/depcheck.mjs` (the `EXEMPT` set), `tools/gen_schema.lua`
and `Test/support.lua` (their headless framework loads). Adding a new Core base class
means adding it to the manifest **once** — every consumer picks it up. The one
intentional duplicate is `Core/Init.lua`'s runtime fail-fast list (the game client can't
read repo files); keep it in step when a new manager joins the pinned head.

## What's generated (don't hand-edit)

Deployed-artifact generation is done at deploy by PowerShell scripts in `tools/autogen/`,
driven by `deploy.ps1`; the committed repo docs are also regenerable standalone via
`./tools/autogen.ps1` (no WoW install needed). Edit the source, not the generated output:

- **`HagAIO.toc`** (`Toc.ps1`) — only the **header** is tracked (Interface, saved vars,
  version tags). The Lua **file list** is filled from disk and written into the *deployed*
  AddOn folder; a new `*.lua` needs no manifest edit. Load order: a pinned Core foundation
  (+ `UI\Widgets`), then folder-then-name for the rest, with `Core\Init.lua` before the
  modules.
- **`Core/Namespace.lua` slot block** (`NamespaceSlots.ps1`) — the `ns.*` slot
  documentation. The repo source keeps **only** a `-- @AUTOGEN:slots` marker; the block is
  injected into the *deployed* `Namespace.lua` (Core framework slots + discovered
  services/libs, descriptions from each file's header). Nothing to maintain by hand.
- **Dev-character whitelist** (`DevChars.ps1`) — `ns.DEV_WHITELIST` ships **empty** in the
  repo and in release zips. Your own dev characters go in the git-ignored
  `Dev/devchars.txt` (one `Name-Realm` per line); deploy injects them into the *deployed*
  `Namespace.lua` at its `-- @AUTOGEN:devchars` marker. No personal data is committed.
- **`README.md`** (`Readme.ps1`) — the `AUTOGEN:filetree` source tree and the
  `AUTOGEN:version` "Target version" table (from `HagAIO.toc`: `## Interface` + the
  `# expansion:` / `# next-patch:` tags). Unlike the two above, this is regenerated **in
  the repo** (the README is a committed GitHub doc). To bump the patch: edit the tags in
  `HagAIO.toc`, then run `./tools/autogen.ps1` (or deploy).
- **`DATABASE_SCHEMA.md` + `diagram/DB`** (`tools/gen_schema.lua`) — the full table
  reference, derived by loading the real engine + every module headless. Regenerated by
  `./tools/autogen.ps1` and on deploy; CI fails when it's stale.

## Packaging a release

`./tools/package.ps1` builds `dist/HagAIO-v<version>.zip` — the same staged artifact
deploy mirrors into the live folder (full generated `.toc` + namespace slot block), with
`HagAIO/` as the archive root so it extracts straight into `Interface\AddOns`. It is
**manual only** (never run by deploy); the version comes from `HagAIO.toc`'s
`## Version:` line.

## Before you push

1. `npm run check` — every lint gate + tests green.
2. `./deploy.ps1` — mirror into the live AddOns folder; this also regenerates the `.toc`,
   the deployed namespace block, and the repo docs (`README.md`, `DATABASE_SCHEMA.md`).
   Without a WoW install, `./tools/autogen.ps1` refreshes the repo docs on their own.
3. Commit (`Area: summary` subject) and push to `main`.

`./deploy.ps1` stages all repository changes and creates a local commit after deployment succeeds.
Pass `-CommitMessage "Area: summary"` to override its default `Deploy: update addon` message. A
clean worktree is skipped, and the script never pushes.
