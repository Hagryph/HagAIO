local addonName, ns = ...
local Class = ns.Class

-- Services/Profiles.lua
-- Named config profiles + copy-paste sharing, built on the SavedVars layer. A
-- profile is a deep snapshot of the account config (module enable states + every
-- module/submodule settings namespace + the schema version), stored under
-- HagAIODB.profiles[name]. Export runs it through ns.Serializer into a share
-- string; Import decodes + migrates a (possibly older) string back to a profile.
-- Loading a profile overwrites the live config in place and is finalised with a
-- /reload -- the standard, side-effect-free way to switch a full config. The UI
-- (Settings window -> Profiles page) drives all of this; this service is pure logic.

local Profiles = Class.new("Profiles", ns.Service)

local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, val in pairs(v) do t[k] = deepcopy(val) end
    return t
end

local function clear(t)
    for k in pairs(t) do t[k] = nil end
end

function Profiles:OnInitialize() end

-- The stored profiles map (account-wide), created on first use.
function Profiles:_Store()
    local g = ns.SavedVars:Global()
    g.profiles = g.profiles or {}
    return g.profiles
end

-- A deep copy of the current account config (everything except the profiles map).
function Profiles:Snapshot()
    local snap, g = {}, ns.SavedVars:Global()
    for k, v in pairs(g) do
        if k ~= "profiles" then snap[k] = deepcopy(v) end
    end
    return snap
end

function Profiles:List()
    local out = {}
    for name in pairs(self:_Store()) do out[#out + 1] = name end
    table.sort(out)
    return out
end

function Profiles:Has(name) return self:_Store()[name] ~= nil end
function Profiles:Get(name) return self:_Store()[name] end

function Profiles:Save(name)
    if type(name) ~= "string" or name == "" then return false, "a profile name is required" end
    self:_Store()[name] = self:Snapshot()
    return true
end

function Profiles:Delete(name)
    local store = self:_Store()
    if store[name] == nil then return false, "no profile named '" .. tostring(name) .. "'" end
    store[name] = nil
    return true
end

-- Overwrite the live account config IN PLACE from a snapshot (migrated to the
-- current schema first), preserving the profiles map. Top-level tables are cleared +
-- copied rather than replaced, so a module's already-bound db reference stays valid.
function Profiles:_ApplyData(snap)
    if type(snap) ~= "table" then return false, "empty profile" end
    snap = ns.SavedVars:MigrateTable(deepcopy(snap))
    local g = ns.SavedVars:Global()
    for k in pairs(g) do
        if k ~= "profiles" and snap[k] == nil then g[k] = nil end  -- drop keys the profile omits
    end
    for k, v in pairs(snap) do
        if k ~= "profiles" then
            if type(v) == "table" and type(g[k]) == "table" then
                clear(g[k])
                for kk, vv in pairs(v) do g[k][kk] = deepcopy(vv) end
            else
                g[k] = deepcopy(v)
            end
        end
    end
    return true
end

-- Load a saved profile into the live config (persists immediately; /reload applies).
function Profiles:LoadProfile(name)
    local snap = self:Get(name)
    if not snap then return false, "no profile named '" .. tostring(name) .. "'" end
    return self:_ApplyData(snap)
end

-- name (or nil = the live config) -> share string.
function Profiles:Export(name)
    local snap = name and self:Get(name) or self:Snapshot()
    if not snap then return nil, "no profile named '" .. tostring(name) .. "'" end
    return ns.Serializer:Encode(snap)
end

-- share string -> saved under `name` (decoded + migrated). Does NOT apply; the user
-- then loads it. Returns (true, name) or (false, reason).
function Profiles:Import(str, name)
    local value, err = ns.Serializer:Decode(str)
    if not value then return false, err end
    if type(value) ~= "table" then return false, "that string isn't a profile" end
    ns.SavedVars:MigrateTable(value)
    if not name or name == "" then name = "Imported" end
    self:_Store()[name] = value
    return true, name
end

ns.ServiceManager:Register(Profiles:New("Profiles", { deps = { "SavedVars", "Serializer" } }))
