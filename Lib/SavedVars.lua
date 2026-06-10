local addonName, ns = ...
local Class = ns.Class

-- Lib/SavedVars.lua
-- A pure-storage LIBRARY (see Core/Lib.lua): it binds the addon's two saved-variable globals
-- (HagAIODB account-wide, HagAIOCharDB per-character) and hands out named SLOTS carved from them.
-- That is its entire job -- it has no settings, no profiles, no cascade and no schema knowledge.
--
-- It is the single owner of the raw saved-variable globals: every other part of the addon persists
-- through the shared Database, which takes its backing slots from here. Being a Lib it is published
-- the instant its file loads (ns.SavedVars) and sits outside the service dependency graph, so the
-- Database reaches it directly and never declares it as a dependency.

local SavedVars = Class.new("SavedVars", ns.Lib)

-- Bind the saved-variable globals. Call once they exist (after ADDON_LOADED); idempotent.
function SavedVars:Load()
    local p = self:_p()
    HagAIODB = HagAIODB or {}
    HagAIOCharDB = HagAIOCharDB or {}
    p.global = HagAIODB
    p.char = HagAIOCharDB
    p.loaded = true
end

function SavedVars:IsLoaded() return self:_p().loaded == true end

-- A named storage SLOT: an empty sub-table the caller owns, drawn from the account-wide store
-- (perChar = false/nil) or this character's store (perChar = true). Seeded once, returned as-is
-- afterwards so saved data is never clobbered.
function SavedVars:DataSlot(name, perChar)
    local p = self:_p()
    assert(p.loaded, "SavedVars:DataSlot called before Load()")
    local root = perChar and p.char or p.global
    root[name] = root[name] or {}
    return root[name]
end

ns.LibManager:Register(SavedVars:New("SavedVars"))
