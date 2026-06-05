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
  EventBus.lua             Singleton pub/sub over game events + custom messages
  SavedVars.lua            Default-merged, namespaced saved-variable manager
  Module.lua               Abstract base class for feature modules (lifecycle hooks)
  ModuleManager.lua        Singleton registry: binds db, runs lifecycle, enable/disable
  SlashCommand.lua         /hagaio (/hag) router with sub-commands
  Config.lua               Options panel via the modern Settings API
Bootstrap.lua              Startup orchestrator (ADDON_LOADED → PLAYER_LOGIN)
deploy.ps1                 Mirror the addon into the live WoW AddOns folder
```

### Adding a feature module

```lua
local addonName, ns = ...
local MyFeature = ns.Class.new("MyFeature", ns.Module)

function MyFeature:OnInitialize()
    -- self:GetDB() is bound and ready here
end

function MyFeature:OnEnable()  -- register events, create frames … end
function MyFeature:OnDisable() -- tear them down … end

ns.ModuleManager.Get():Register(MyFeature:New("MyFeature", {
    title = "My Feature",
    defaultEnabled = true,
    dbDefaults = { foo = 1 },
}))
```

Add the file to `HagAIO.toc` after the `Core/` block.

## Usage

| Command | Effect |
|---|---|
| `/hag` | Open the options panel |
| `/hag modules` | List feature modules and their on/off state |
| `/hag help` | List all commands |

## Deploy to the game

```powershell
./deploy.ps1
```

Mirrors the addon into `…\_retail_\Interface\AddOns\HagAIO`, then `/reload` in-game.
Override the target with `-AddonsPath` or the `WOW_ADDONS_PATH` environment variable.
