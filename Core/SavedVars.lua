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
    p.char.modules = p.char.modules or {}      -- per-character enable state
    p.loaded = true
end

function SavedVars:IsLoaded()
    return self:_p().loaded
end

-- Pick the global or per-character root table.
function SavedVars:_Root(perChar)
    local p = self:_p()
    return perChar and p.char or p.global
end

-- Per-module sub-table, seeded with `defaults`. Pass perChar=true to store it
-- per character instead of account-wide.
function SavedVars:Namespace(key, defaults, perChar)
    local p = self:_p()
    assert(p.loaded, "SavedVars:Namespace called before Load()")
    local root = self:_Root(perChar)
    root[key] = applyDefaults(root[key] or {}, defaults or {})
    return root[key]
end

function SavedVars:GetModuleState(name, perChar)
    return self:_Root(perChar).modules[name]
end

function SavedVars:SetModuleState(name, enabled, perChar)
    self:_Root(perChar).modules[name] = enabled and true or false
end

function SavedVars.Get()
    if not instance then instance = SavedVars:New() end
    return instance
end

ns.SavedVars = SavedVars
