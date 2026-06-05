# HagAIO

**All-in-One toolkit for World of Warcraft** — a modular addon framework targeting the
current retail client (**Midnight**, patch 12.0.x).

This repository currently ships the **core framework** only: an OOP module system that
feature modules (combat tools, bag sort, map pins, unit frames, …) plug into. No
end-user features are bundled yet — the foundation is here to build them on.

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

## Architecture

Everything lives inside an OOP structure — there is no loose top-level logic (the lone
exception is the single `Bootstrap.Get():Run()` entry point). Encapsulation is real:
each instance's fields are held in a private side-table reached only through the
inherited `:_p()` accessor.

```
HagAIO.toc                 Load manifest (file order, saved vars, Interface version)
Core/
  Namespace.lua            Shared addon table + namespaced logger
  Class.lua                Metatable OOP system (private fields, inheritance, singletons)
  Theme.lua                Design system — LoL "dark + blue" palette (hex + rgb)
  EventBus.lua             Singleton pub/sub over game events + custom messages
  SavedVars.lua            Default-merged, namespaced saved-variable manager
  Logger.lua               Logging service: per-module channels, history, chat echo
  Module.lua               Abstract base class for feature modules (lifecycle + logging)
  ModuleManager.lua        Singleton registry: binds db/logger, runs lifecycle
  SlashCommand.lua         /hagaio (/hag) router with sub-commands
UI/
  Widgets.lua              Themed factory (panels, toggles, nav items, scroll)
  SettingsWindow.lua       Custom dark+blue settings menu (Modules / Log / About)
Modules/
  Questing.lua             XP/hour tooltip + auto-accept/turn-in quests
  UnitFrames.lua           Player/target health-bar tint by HP% (colour curves)
  Class.lua                Per-class helpers (Monk: Expel Harm threshold marker)
  Misc.lua                 Miscellaneous: flight-path timers, sell junk
Bootstrap.lua              Startup orchestrator (ADDON_LOADED → PLAYER_LOGIN)
deploy.ps1                 Mirror the addon into the live WoW AddOns folder
```

### Logging

Every module gets a colour-coded logging channel automatically. Each report is
written to the chat frame *and* recorded in the in-game **activity log**
(`/hag log`), tinted by level:

```lua
self:LogInfo("scanned", count, "items")   -- white
self:LogSuccess("ready")                   -- green
self:LogWarn("nothing to do")              -- amber
self:LogError("missing data")              -- red
self:LogDebug("verbose detail")            -- grey (hidden below INFO threshold)
```

Format: `HagAIO  hh:mm:ss  [Module]  message`. Chat echo and the level
threshold are togglable in the Log page and persist.

### Settings window

A custom themed window (not the default Blizzard panel) ported from the LoL
Game Helper's design — near-black blue-tinted panels, a cyan `#4ab3e6` accent,
a left nav rail, and live pages. Movable, ESC-closable. Open with `/hag`.

### Adding a feature module

```lua
local addonName, ns = ...
local MyFeature = ns.Class.new("MyFeature", ns.Module)

function MyFeature:OnInitialize()
    -- self:GetDB() and self:LogInfo(...) are ready here
end

function MyFeature:OnEnable()  self:LogInfo("watching") end
function MyFeature:OnDisable() end

ns.ModuleManager.Get():Register(MyFeature:New("MyFeature", {
    title = "My Feature",
    description = "One short line shown on the Modules page.",
    defaultEnabled = true,
    color = "4ab3e6",         -- log tag colour (optional)
    settings = {              -- auto-generates this module's settings page
        { type = "header", text = "Options" },
        { type = "toggle", key = "foo", label = "Enable foo", default = true,
          desc = "Optional helper line." },
        { type = "select", key = "mode", label = "Mode", default = "a",
          options = { { value = "a", text = "A" }, { value = "b", text = "B" } } },
        { type = "color", key = "tint", label = "Tint", default = { 1, 0, 0 } },
    },
}))

-- read/write settings (bound to saved vars):  self:GetSetting("foo")
-- react to changes:  function MyFeature:OnSettingChanged(key, value) ... end
```

Add the file to `HagAIO.toc` after the `Modules/` block. It appears on the
settings window's **Modules** page (name + short description + toggle), and its
**settings schema auto-generates a dedicated settings page** (open via the row's
`Settings >` button).

## Usage

| Command | Effect |
|---|---|
| `/hag` | Toggle the settings window |
| `/hag log` | Open the activity log |
| `/hag modules` | List feature modules and their on/off state |
| `/hag help` | List all commands |

### Minimap (addon compartment)

HagAIO adds a button to the **addon compartment** — the icon hub on the minimap
that collects many addons (not the standalone LibDBIcon button). **Left-click
opens the settings window**; right-click jumps to the activity log.

### Icon

`Media/icon.tga` is the addon + compartment icon: an "AiO" wordmark (Segoe UI
Bold, cyan→navy gradient on a blue-black panel with an accent ring), generated
by `tools/gen_icon.py` (Pillow). Regenerate with `python tools/gen_icon.py`.

## Deploy to the game

```powershell
./deploy.ps1
```

Mirrors the addon into `…\_retail_\Interface\AddOns\HagAIO`, then `/reload` in-game.
Override the target with `-AddonsPath` or the `WOW_ADDONS_PATH` environment variable.
