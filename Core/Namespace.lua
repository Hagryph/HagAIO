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

-- Registry slots, populated by their respective Core files. Declared here so
-- the shape of the namespace is documented in one place.
ns.Class = nil          -- OOP class factory          (Core/Class.lua)
ns.Object = nil         -- root base class             (Core/Class.lua)
ns.Theme = nil          -- design system (LoL palette) (Core/Theme.lua)
ns.EventBus = nil       -- event/message singleton     (Core/EventBus.lua)
ns.SavedVars = nil      -- saved-variable manager      (Core/SavedVars.lua)
ns.Logger = nil         -- logging service singleton   (Core/Logger.lua)
ns.Module = nil         -- abstract feature base       (Core/Module.lua)
ns.ModuleManager = nil  -- module registry singleton   (Core/ModuleManager.lua)
ns.SlashCommand = nil   -- slash command router        (Core/SlashCommand.lua)
ns.UI = nil             -- UI namespace (widgets+window) (UI/*.lua)
ns.Bootstrap = nil      -- startup orchestrator        (Bootstrap.lua)

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
