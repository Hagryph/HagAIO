local addonName, ns = ...
local Class = ns.Class

-- Core/SavedVars.lua
-- Singleton wrapper around the global + per-character saved-variable tables
-- declared in the .toc. Hands modules a namespaced, default-merged sub-table
-- so persistence is uniform and collision-free.

local SavedVars = Class.new("SavedVars")
local instance

-- Recursively seed missing keys from `defaults` without clobbering saved data.
local function applyDefaults(target, defaults)
    if type(defaults) ~= "table" then return target end
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            target[k] = applyDefaults(target[k] or {}, v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
    return target
end

function SavedVars:Initialize()
    self:_p().loaded = false
end

-- Bind the global tables. Call once SavedVariables are available
-- (i.e. after our ADDON_LOADED fires).
function SavedVars:Load()
    local p = self:_p()
    HagAIODB = HagAIODB or {}
    HagAIOCharDB = HagAIOCharDB or {}
    p.global = HagAIODB
    p.char = HagAIOCharDB
    p.global.modules = p.global.modules or {}  -- name -> bool enable state
    p.loaded = true
end

function SavedVars:IsLoaded()
    return self:_p().loaded
end

-- Per-module global sub-table, seeded with `defaults`.
function SavedVars:Namespace(key, defaults)
    local p = self:_p()
    assert(p.loaded, "SavedVars:Namespace called before Load()")
    p.global[key] = applyDefaults(p.global[key] or {}, defaults or {})
    return p.global[key]
end

function SavedVars:GetModuleState(name)
    return self:_p().global.modules[name]
end

function SavedVars:SetModuleState(name, enabled)
    self:_p().global.modules[name] = enabled and true or false
end

function SavedVars.Get()
    if not instance then instance = SavedVars:New() end
    return instance
end

ns.SavedVars = SavedVars
