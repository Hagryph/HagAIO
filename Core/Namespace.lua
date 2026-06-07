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
ns.Service = nil        -- abstract service base       (Core/Service.lua)
ns.ServiceManager = nil -- service registry + ordering (Core/ServiceManager.lua)
ns.Submodule = nil      -- condition-gated submodule base (Core/Submodule.lua)
ns.SubmoduleManager = nil -- submodule registry + loader (Core/SubmoduleManager.lua)
ns.EventBus = nil       -- event/message singleton     (Core/EventBus.lua)
ns.SavedVars = nil      -- saved-variable manager      (Core/SavedVars.lua)
ns.Logger = nil         -- logging service singleton   (Core/Logger.lua)
ns.Module = nil         -- abstract feature base       (Core/Module.lua)
ns.ModuleManager = nil  -- module registry singleton   (Core/ModuleManager.lua)
ns.SlashCommand = nil   -- slash command router        (Core/SlashCommand.lua)
ns.Compartment = nil    -- addon-compartment button    (Core/Compartment.lua)
ns.MinimapIcon = nil    -- standalone minimap button    (Core/MinimapIcon.lua)
ns.Hooks = nil          -- removable secure-hook service (Core/Hooks.lua)
ns.ActionBars = nil     -- find/annotate action buttons (Core/ActionBars.lua)
ns.Range = nil          -- enemies-in-range by yardage    (Core/Range.lua)
ns.Cooldowns = nil      -- secret-safe cooldown watcher (Core/Cooldowns.lua)
ns.Secrets = nil        -- 12.0 Secret Value helpers    (Core/Secrets.lua)
ns.Scaling = nil        -- health-based scaling formulas (Core/Scaling.lua)
ns.DependencyGraph = nil -- generic dependency forest   (Core/DependencyGraph.lua)
ns.Dev = nil            -- developer tools (CVar dump)  (Core/Dev.lua)
ns.EditMode = nil       -- Edit Mode framework         (Core/EditMode.lua)
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
