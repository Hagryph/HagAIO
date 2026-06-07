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

CI (`.github/workflows/lint.yml`) runs four lint gates + the test suite. Reproduce them
all in one command:

```
npm run check        # lint + tests (everything CI runs)
npm run lint         # just the four lint gates
npm test             # just the Lua suite
```

Individual gates are also exposed: `npm run depcheck`, `npm run deadcode`. There are no
dependencies to install — the tools are plain Node ESM. The test runner auto-finds
`luajit` (or `lua`).

| Gate | Checks |
|---|---|
| `depcheck` | Every `ns.<Service/Module>` a file uses is declared as a dependency, and every defined service/module/lib/submodule self-registers |
| `deadcode` | No unused file-local declarations or uncalled private methods |
| `test` | `lua Test/run.lua` — the spec suite |

The `.toc`, the `Core/Namespace.lua` slot block, and the `README.md` regions are
**generated at deploy** (see below), so there are no checks for them — `deploy.ps1` keeps
them in step.

## Waiver / convention comments

The lint gates are heuristic (Lua is dynamic), so each has an in-file escape hatch for
deliberate exceptions:

- **`-- depcheck-allow: A, B`** — waive specific undeclared-dependency references (e.g. an
  intentional/cyclic access). Place the comment anywhere in the file.
- **`-- depcheck-allow: noregister`** — waive the self-registration rule for a file that
  defines a service/module/submodule/lib but deliberately doesn't register it in the same
  file.
- **`-- deadcode-allow: name1, name2`** — keep a public method or local the scan thinks is
  unused (public API, dynamic dispatch the scan can't see).
- **`EXEMPT` foundation list** (in `tools/depcheck.mjs`) — the core singletons / base
  classes / statics whose own `ns.*` accesses aren't linted, because they're always
  available. These are exactly the files that register neither a service nor a module;
  the list is kept explicit because the exemption is a deliberate choice. Repo-relative
  paths (e.g. `Core/Class.lua` is exempt; `Modules/Class.lua` the feature module is not).

## What's generated (don't hand-edit)

Generation is **all done at deploy** by PowerShell scripts in `tools/autogen/`, driven by
`deploy.ps1`. The shared ordering/description helpers live in `tools/autogen/Common.ps1`
(one source for the load order). Edit the source, not the generated output:

- **`HagAIO.toc`** (`Toc.ps1`) — only the **header** is tracked (Interface, saved vars,
  version tags). The Lua **file list** is filled from disk and written into the *deployed*
  AddOn folder; a new `*.lua` needs no manifest edit. Load order: a pinned Core foundation
  (+ `UI\Widgets`), then folder-then-name for the rest, with `Core\Init.lua` before the
  modules.
- **`Core/Namespace.lua` slot block** (`NamespaceSlots.ps1`) — the `ns.*` slot
  documentation. The repo source keeps **only** a `-- @AUTOGEN:slots` marker; the block is
  injected into the *deployed* `Namespace.lua` (Core framework slots + discovered
  services/libs, descriptions from each file's header). Nothing to maintain by hand.
- **`README.md`** (`Readme.ps1`) — the `AUTOGEN:filetree` source tree and the
  `AUTOGEN:version` "Target version" table (from `HagAIO.toc`: `## Interface` + the
  `# expansion:` / `# next-patch:` tags). Unlike the two above, this is regenerated **in
  the repo** (the README is a committed GitHub doc). To bump the patch: edit the tags in
  `HagAIO.toc`, then deploy.

## Before you push

1. `npm run check` — depcheck + deadcode + tests green.
2. `./deploy.ps1` — mirror into the live AddOns folder; this also regenerates the `.toc`,
   the deployed namespace block, and the repo `README.md`.
3. Commit (`Area: summary` subject) and push to `main`.
