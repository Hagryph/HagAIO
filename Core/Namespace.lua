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

-- Registry slots (ns.<Name>) documenting the shape of the namespace. GENERATED at deploy
-- by tools/autogen/NamespaceSlots.ps1 and injected below this marker into the DEPLOYED
-- copy; the repo source keeps only the marker so it stays free of the derived block.
-- @AUTOGEN:slots

-- NOTE on lifecycle: a few core singletons self-instantiate at file load
-- (Logger, ServiceManager, ModuleManager) so they're available immediately. Every
-- SERVICE slot (EventBus, SavedVars, SlashCommand, Hooks, ActionBars, Range,
-- Cooldowns, Secrets, Scaling, Dev, EditMode, Compartment, MinimapIcon, and the
-- UI.* windows) is filled with its sole INSTANCE by the ServiceManager during
-- StartAll(), in dependency order. There is no `.Get()` accessor — call sites use
-- e.g. `ns.EventBus` directly. DependencyGraph stays a CLASS (instantiated per use).

-- Logger: a small static table so prints stay consistent and namespaced. Colours come
-- from the shared Theme (one palette), built at CALL time -- Theme.lua loads AFTER this
-- file, so we can't capture it at load. (A nil-guard keeps the very-early path safe.)
local Log = {}
local function paint(key, text)
    return ns.Theme and ns.Theme.Colorize(key, text) or text
end

function Log.Print(...)
    print(paint("accent", "HagAIO") .. ":", ...)
end

function Log.Warn(...)
    print(paint("accent", "HagAIO") .. " " .. paint("amber", "warning") .. ":", ...)
end

function Log.Error(...)
    print(paint("accent", "HagAIO") .. " " .. paint("red", "error") .. ":", ...)
end

ns.Log = Log
