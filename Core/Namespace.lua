local addonName, ns = ...

-- Core/Namespace.lua
-- Root namespace module. Establishes the shared fields every other file
-- relies on, and exposes a namespaced logging facility. This is the addon's
-- module table (the Lua equivalent of a package-level namespace object); all
-- other concerns hang off `ns`.

ns.name = addonName

-- Read our own version through the current (Midnight 12.0+) addon API.
-- GetAddOnMetadata was deprecated in favour of C_AddOns.GetAddOnMetadata.
ns.version = (C_AddOns and C_AddOns.GetAddOnMetadata
    and C_AddOns.GetAddOnMetadata(addonName, "Version")) or "0.0.0"

-- Shared icon texture path (Media/icon.tga). Used by the addon-compartment
-- button; also set as ## IconTexture in the .toc for the addon list.
ns.ICON = "Interface\\AddOns\\HagAIO\\Media\\icon"

-- Registry slots, populated by their respective Core files. Declared here so
-- the shape of the namespace is documented in one place.
ns.Class = nil          -- OOP class factory          (Core/Class.lua)
ns.Object = nil         -- root base class             (Core/Class.lua)
ns.Theme = nil          -- design system (LoL palette) (Core/Theme.lua)
ns.Registry = nil       -- shared base for lifecycle managers (Core/Registry.lua)
ns.Loggable = nil       -- shared logging mixin        (Core/Loggable.lua)
ns.Lib = nil            -- pure-logic helper base       (Core/Lib.lua)
ns.LibManager = nil     -- lib registry (publishes; no graph) (Core/LibManager.lua)
ns.Service = nil        -- abstract service base       (Core/Service.lua)
ns.ServiceManager = nil -- service registry + ordering (Core/ServiceManager.lua)
ns.Submodule = nil      -- condition-gated submodule base (Core/Submodule.lua)
ns.SubmoduleManager = nil -- submodule registry + loader (Core/SubmoduleManager.lua)
ns.EventBus = nil       -- event/message singleton     (Services/EventBus.lua)
ns.SavedVars = nil      -- saved-variable manager      (Services/SavedVars.lua)
ns.Logger = nil         -- logging service singleton   (Core/Logger.lua)
ns.Component = nil      -- lifecycle+settings base     (Core/Component.lua)
ns.Module = nil         -- abstract feature base       (Core/Module.lua)
ns.ModuleManager = nil  -- module registry singleton   (Core/ModuleManager.lua)
ns.SlashCommand = nil   -- slash command router        (Services/SlashCommand.lua)
ns.Compartment = nil    -- addon-compartment button    (Services/Compartment.lua)
ns.MinimapIcon = nil    -- standalone minimap button    (Services/MinimapIcon.lua)
ns.Hooks = nil          -- removable secure-hook service (Services/Hooks.lua)
ns.ActionBars = nil     -- find/annotate action buttons (Services/ActionBars.lua)
ns.Range = nil          -- enemies-in-range by yardage    (Services/Range.lua)
ns.Cooldowns = nil      -- secret-safe cooldown watcher (Services/Cooldowns.lua)
ns.Secrets = nil        -- 12.0 Secret Value helpers    (Services/Secrets.lua)
ns.Scaling = nil        -- health-based scaling formulas (Services/Scaling.lua)
ns.Cache = nil          -- named caches (weak/ttl/lru)  (Services/Cache.lua)
ns.Memoize = nil        -- pure-function memoisation    (Services/Memoize.lua)
ns.Scheduler = nil      -- cancellable C_Timer wrapper  (Services/Scheduler.lua)
ns.Serializer = nil     -- CBOR/deflate/base64 strings  (Services/Serializer.lua)
ns.Profiles = nil       -- named config profiles+share  (Services/Profiles.lua)
ns.FlightGraph = nil    -- LIB: flight-route path costs  (Lib/FlightGraph.lua)
ns.Geometry = nil       -- LIB: 2D distance / nearest    (Lib/Geometry.lua)
ns.SpellTooltipParser = nil -- LIB: spell-desc number parse (Lib/SpellTooltipParser.lua)
ns.CVarHelper = nil     -- LIB: CVar type inference      (Lib/CVarHelper.lua)
ns.DependencyGraph = nil -- generic dependency forest   (Core/DependencyGraph.lua)
ns.Dev = nil            -- developer tools (CVar dump)  (Services/Dev.lua)
ns.EditMode = nil       -- Edit Mode framework         (Services/EditMode.lua)
ns.UI = nil             -- UI namespace (widgets+windows) (UI/*.lua)
ns.Initializer = nil    -- startup orchestrator        (Core/Init.lua)

-- NOTE on lifecycle: a few core singletons self-instantiate at file load
-- (Logger, ServiceManager, ModuleManager) so they're available immediately. Every
-- SERVICE slot (EventBus, SavedVars, SlashCommand, Hooks, ActionBars, Range,
-- Cooldowns, Secrets, Scaling, Dev, EditMode, Compartment, MinimapIcon, and the
-- UI.* windows) is filled with its sole INSTANCE by the ServiceManager during
-- StartAll(), in dependency order. There is no `.Get()` accessor — call sites use
-- e.g. `ns.EventBus` directly. DependencyGraph stays a CLASS (instantiated per use).

-- Logger: a small static table so prints stay consistent and namespaced.
local Log = {}
local PREFIX = "|cff33ff99HagAIO|r"

function Log.Print(...)
    print(PREFIX .. ":", ...)
end

function Log.Warn(...)
    print(PREFIX .. " |cffffcc00warning|r:", ...)
end

function Log.Error(...)
    print(PREFIX .. " |cffff5555error|r:", ...)
end

ns.Log = Log
