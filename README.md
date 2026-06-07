# HagAIO

**All-in-One toolkit for World of Warcraft** — a modular addon framework with a growing
set of feature modules, targeting the current retail client (**Midnight**, patch 12.0.x).

A small OOP core (services, modules, submodules, all wired through one dependency graph)
that feature modules plug into, plus a themed settings window and activity log they share.

## Target version

| | |
|---|---|
| Expansion | Midnight |
| `.toc` Interface | `120005` (patch 12.0.5, current live) |
| Next patch | 12.0.7 *Revelations* — 2026-06-16 → bump Interface to `120007` |

> The Midnight 12.0 API introduced **Secret Values** and migrated several globals into
> `C_*` namespaces (e.g. `GetAddOnMetadata` → `C_AddOns.GetAddOnMetadata`). Always verify
> against the current API docs before using a function — see
> [warcraft.wiki.gg](https://warcraft.wiki.gg/wiki/World_of_Warcraft_API).

## Features

Everything is a toggleable module on the settings window's **Modules** page (most default
off). Modules hide when a required addon is missing and grey out when a prerequisite
module is disabled.

- **Task List** — a movable, see-through objective tracker styled like Blizzard's quest
  tracker (centered blue-black header bars, grows downward, hides in combat, Edit Mode
  movable). Tasks are **one-time / daily / weekly** (daily & weekly reset with the server)
  and complete **manually** (tick them) or **automatically** (a condition re-checked on
  declared events — e.g. a boss kill). Add/remove tasks in its settings; other modules
  register tasks through `ns.Tasks`.
- **Collections** — right-click an **uncollected** mount, pet, toy or heirloom in the
  Blizzard journals to **Track** it in the Task List (auto-completes when you collect it).
  The **All The Things** integration is an addon-gated *submodule*: when ATT is installed,
  Ctrl+Right-Click an item in its window to track it.
- **CVars** — force console variables on every character. A curated, typed list grouped in
  collapsible categories (toggles / number / text / pick-one), plus **custom CVars** (type
  auto-detected) and a per-character **Global** toggle. Also driven by `/hag cvar`.
- **Questing** — XP-per-hour and session stats on the XP-bar tooltip, with optional
  auto-accept / auto-turn-in.
- **Unit Frames** — tint the player/target health bars by remaining health %.
- **Class → Monk (Brewmaster)** — an Expel Harm heal-threshold marker on the health bar
  (orb-aware, secret-value safe), a Tiger Palm missing-energy bar, and an AoE helper that
  greys Tiger Palm vs Spinning Crane Kick at a breakpoint computed live from their tooltip
  damage (with a configurable bias since Tiger Palm also reduces brew cooldowns).
- **Misc** — flight-path timers (learns each leg as you fly, skips nodes you don't pass
  near, and estimates unflown routes by composing learned legs) and a sell-junk button /
  auto-sell at vendors.
- **Dev** — dump every console variable into a copy window for capture each patch
  (`/hag dev cvars`; needs the `-console` launch flag).

## Architecture

Everything lives inside an OOP structure — no loose top-level logic (the lone exception is
`Initializer:New():Run()` in `Core/Init.lua`). Encapsulation is real: each instance's
fields live in a private side-table reached only through the inherited `:_p()` accessor.

Three layers, one dependency core:

- **Services** (`ns.Service` / `ns.ServiceManager`) — long-lived singletons. Each declares
  its service dependencies; the ServiceManager topologically orders them via the
  `DependencyGraph` and runs `OnInitialize` so a service starts only after its deps. One
  `StartAll()` boots the whole layer; `.toc` order is irrelevant.
- **Modules** (`ns.Module` / `ns.ModuleManager`) — toggleable features. They declare
  service `deps`, `addonDeps` (hidden unless that addon is loaded) and `moduleDeps` (greyed
  unless that module is enabled) — all evaluated through the same graph.
- **Submodules** (`ns.Submodule` / `ns.SubmoduleManager`) — condition-gated, infinitely
  nestable pieces of a module/submodule. They declare a parent, service/module/submodule/
  addon deps, a `condition` (plain Lua function) and the `events` that re-evaluate it. The
  SubmoduleManager loads/unloads them from `graph:IsOnline`, and a loaded submodule's
  settings appear under its parent's page automatically.

`DependencyGraph` is the shared engine for all of the above (AND/OR/at-least conditions,
cycle/dangling detection, topological order, online/active/satisfied queries) — and also
backs the `dependsOn` greying of individual settings controls.

<!-- AUTOGEN:filetree — regenerate with `node tools/gen_readme.mjs` (CI runs --check) -->
```
HagAIO.toc                 Load manifest (file order, saved vars, Interface version)
Core/
  Namespace.lua            Root namespace module
  Class.lua                Minimal metatable-based OOP system with true per-instance encapsulation
  Theme.lua                Static design system ported from the LoL Game Helper desktop app's
  DependencyGraph.lua      A generic dependency forest
  Logger.lua               Central logging service
  Registry.lua             Shared base for the three lifecycle registries (Module / Service / Submodule
  Loggable.lua             The shared LOGGING surface, in one place
  Component.lua            Shared base for the two things that have an on/off lifecycle plus a settings page:
  Service.lua              Abstract base for every framework SERVICE -- the long-lived singletons the
  ServiceManager.lua       Registry that owns the lifecycle of every Service
  Module.lua               Abstract base class for every feature module
  ModuleManager.lua        Registry that owns the lifecycle of every feature Module: it initialises them
  Submodule.lua            A SUBMODULE is a piece of a Module (or of another submodule -- nesting is
  SubmoduleManager.lua     Registry that owns the lifecycle of every Submodule
  Lib.lua                  Base for a LIB: a pure-logic helper (no WoW API, no state, no dependencies) published
  LibManager.lua           Registry for the LIB tier (pure-logic helpers; see Core/Lib.lua)
  Init.lua                 The single Core initializer
Lib/
  FlightGraph.lua          Pure route-cost calculations over a generic weighted graph -- no WoW API, no flight
  Geometry.lua             Pure 2D geometry helpers -- no WoW API
  SpellTooltipParser.lua   Pure parsers for the numbers embedded in a spell's description text
  CVarHelper.lua           Pure helpers for reasoning about console-variable VALUES -- no WoW API
Services/
  Cache.lua                Central caching service
  Memoize.lua              Memoization service: wrap a PURE function so repeat calls with the same arguments
  Scheduler.lua            Thin, cancellable wrapper over C_Timer
  Serializer.lua           Turns a Lua value into a compact, copy-pasteable share string and back, using
  Profiles.lua             Named config profiles + copy-paste sharing, built on the SavedVars layer
  EventBus.lua             Singleton pub/sub layer over a hidden driver frame
  SavedVars.lua            Singleton wrapper around the global + per-character saved-variable tables
  SlashCommand.lua         Singleton slash-command router for /hagaio (alias /hag)
  Hooks.lua                Removable secure-hook service
  ActionBars.lua           Service for locating action buttons by what they cast and annotating them
  Range.lua                Range service: "is this enemy within N yards?" and "how many enemies within N
  Cooldowns.lua            Watch a spell's cooldown WITHOUT reading secret values
  Secrets.lua              Thin, allocation-free helpers around 12.0 Secret Values, so modules don't each
  Scaling.lua              Models WoW "up to X% more" health-based scaling (damage OR healing) as a clamped linear
  Dev.lua                  Developer-only service (not surfaced in normal use)
  EditMode.lua             Standalone framework letting any module register a frame to be positioned via
  Compartment.lua          Registers HagAIO into the Addon Compartment — the button hub on the minimap
  MinimapIcon.lua          A standalone minimap button (NOT LibDBIcon — no external libraries)
UI/
  Widgets.lua              Static factory of themed building blocks (the LoL "dark + blue" language in
  CopyWindow.lua           A themed, reusable "copy this text out of the game" window
  SettingsWindow.lua       The unique, themed settings menu (replaces the default Blizzard options
Modules/
  Questing.lua             Everything around levelling through quests, in one module:
  UnitFrames.lua           Colours the player & target health bars by remaining health: green at full,
  Class.lua                Generic class-helper module
  Class/Monk.lua           Monk class file: adds the Monk behaviour as methods on the shared ns.ClassModule
  Misc.lua                 Miscellaneous helpers:
  CVars.lua                Force chosen console variables on every character
  Tasklist.lua             A lightweight objective tracker
  Collection.lua           Adds a "Track in Task List" right-click menu to UNCOLLECTED entries across all
  Collection/ATT.lua       All The Things integration as a SUBMODULE of the Collection module
Dev/                       Scratch space (excluded from deploy)
deploy.ps1                 Mirror the addon into the live WoW AddOns folder
```
<!-- /AUTOGEN:filetree -->

### Logging

Every module/service gets a colour-coded logging channel. Each report goes to the chat
frame *and* the in-game **activity log** (`/hag log`), tinted by level:

```lua
self:LogInfo("scanned", count, "items")   -- white
self:LogSuccess("ready")                   -- green
self:LogWarn("nothing to do")              -- amber
self:LogError("missing data")              -- red
self:LogDebug("verbose detail")            -- grey (hidden below INFO threshold)
```

Format: `HagAIO  hh:mm:ss  [Module]  message`. Chat echo and the level threshold are
togglable on the Log page and persist.

### Settings window

A custom themed window (not the default Blizzard panel) — near-black blue-tinted panels, a
cyan `#4ab3e6` accent, a left nav rail and live pages. Movable, ESC-closable. Open with
`/hag`. Each module's settings schema auto-generates its page (open via the row's
`Settings >`), and a module may instead provide a fully custom page via `BuildSettingsPage`.

### Adding a feature module

```lua
local addonName, ns = ...
local MyFeature = ns.Class.new("MyFeature", ns.Module)

function MyFeature:OnInitialize()        -- self:GetDB() / self:LogInfo(...) ready here
end
function MyFeature:OnEnable()  end
function MyFeature:OnDisable() end
function MyFeature:OnShutdown() end       -- optional cleanup on /reload or logout

ns.ModuleManager:Register(MyFeature:New("MyFeature", {
    title = "My Feature",
    description = "One short line shown on the Modules page.",
    defaultEnabled = true,
    color = "4ab3e6",                     -- log tag colour (optional)
    deps = { "EventBus" },                -- services that must be loaded
    addonDeps = { "AllTheThings" },       -- optional: hide unless this addon is loaded
    moduleDeps = { "Tasklist" },          -- optional: grey unless this module is enabled
    settings = {                          -- auto-generates this module's settings page
        { type = "header", text = "Options" },
        { type = "toggle", key = "foo", label = "Enable foo", default = true, desc = "..." },
        { type = "select", key = "mode", label = "Mode", default = "a",
          options = { { value = "a", text = "A" }, { value = "b", text = "B" } } },
        { type = "color", key = "tint", label = "Tint", default = { 1, 0, 0 } },
    },
}))

-- read/write settings (bound to saved vars):  self:GetSetting("foo")
-- react to changes:  function MyFeature:OnSettingChanged(key, value) ... end
```

Add the file to `HagAIO.toc` in the `Modules/` block. For a condition-gated piece (e.g. a
spec- or addon-specific feature), register a **submodule** instead:

```lua
ns.SubmoduleManager:Register(ns.Submodule:New("MyBit", {
    parent = { module = "MyFeature" },    -- or { submodule = "OtherBit" } (nestable)
    addonDeps = { "SomeAddon" },
    condition = function() return SomeCheck() end,
    events = { "PLAYER_SPECIALIZATION_CHANGED" },   -- re-evaluate the condition (or nil)
    settings = { ... },                    -- shown under the parent's page while loaded
    onLoad = function(host) end,
    onUnload = function(host) end,
}))
```

## Usage

| Command | Effect |
|---|---|
| `/hag` | Toggle the settings window |
| `/hag log` | Open the activity log |
| `/hag modules` | List feature modules and their on/off state |
| `/hag help` | List all commands |
| `/hag cvar dump\|set\|get\|clear\|list` | Console-variable tools |
| `/hag dev cvars` | Dump every CVar into the copy window (needs `-console`) |

### Minimap (addon compartment)

HagAIO adds a button to the **addon compartment** — the icon hub on the minimap (not the
standalone LibDBIcon button). **Left-click opens the settings window**; right-click opens a
module quick-toggle menu. A standalone draggable minimap button is also available (General
page, default off).

### Icon

`Media/icon.tga` is the addon + compartment icon: an "AiO" wordmark (cyan→navy gradient on
a blue-black panel with an accent ring), generated by `tools/gen_icon.py` (Pillow).
Regenerate with `python tools/gen_icon.py`.

## Deploy to the game

```powershell
./deploy.ps1
```

Mirrors the addon into `…\_retail_\Interface\AddOns\HagAIO`, then `/reload` in-game.
Override the target with `-AddonsPath` or the `WOW_ADDONS_PATH` environment variable.
