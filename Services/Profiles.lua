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

-- Account-wide keys that are NOT part of a profile's captured config: the profiles
-- map itself and the global-profile pointer. Excluded from snapshot + apply so
-- loading a profile never rewrites them.
local META_KEYS = { profiles = true, globalProfile = true }

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
        if not META_KEYS[k] then snap[k] = deepcopy(v) end
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

-- ---- global profile -------------------------------------------------------
-- One profile (account-wide) may be flagged GLOBAL: a character that has never
-- loaded a profile gets it applied automatically on login. The flag is exclusive --
-- setting it replaces any previous one -- and may be cleared (nil = no global, so a
-- fresh character just starts from defaults).
function Profiles:GetGlobal()
    return ns.SavedVars:Global().globalProfile
end

function Profiles:IsGlobal(name)
    return name ~= nil and self:GetGlobal() == name
end

-- Mark `name` as the global profile, or pass nil to clear it (no global profile).
function Profiles:SetGlobal(name)
    local g = ns.SavedVars:Global()
    if name == nil then
        g.globalProfile = nil
        return true
    end
    if not self:Has(name) then return false, "no profile named '" .. tostring(name) .. "'" end
    g.globalProfile = name
    return true
end

-- Per-character record of the last profile applied here (account-wide profiles, but
-- which one a given character uses is per character). nil = this character has never
-- loaded a profile.
function Profiles:_CharState()
    return ns.SavedVars:Namespace("profiles", { loaded = false }, true)
end

function Profiles:GetLoaded() return self:_CharState().loaded or nil end

function Profiles:Save(name)
    if type(name) ~= "string" or name == "" then return false, "a profile name is required" end
    self:_Store()[name] = self:Snapshot()
    return true
end

function Profiles:Delete(name)
    local store = self:_Store()
    if store[name] == nil then return false, "no profile named '" .. tostring(name) .. "'" end
    store[name] = nil
    if self:IsGlobal(name) then self:SetGlobal(nil) end  -- don't leave a dangling global
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
        if not META_KEYS[k] and snap[k] == nil then g[k] = nil end  -- drop keys the profile omits
    end
    for k, v in pairs(snap) do
        if not META_KEYS[k] then
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
-- Records it as this character's loaded profile so the global profile won't override
-- it on future logins.
function Profiles:LoadProfile(name)
    local snap = self:Get(name)
    if not snap then return false, "no profile named '" .. tostring(name) .. "'" end
    local ok, err = self:_ApplyData(snap)
    if ok then self:_CharState().loaded = name end
    return ok, err
end

-- On login, if this character has never loaded a profile, apply the account's global
-- profile (if one is set + still exists). Call AFTER SavedVars load/migrate/defaults
-- and BEFORE modules bind their namespaces, so the fresh config takes effect without a
-- /reload. Returns the applied profile name, or nil if nothing was applied.
function Profiles:ApplyGlobalForFreshChar()
    local cs = self:_CharState()
    if cs.loaded then return nil end          -- this character already uses a profile
    local name = self:GetGlobal()
    if not name or not self:Has(name) then return nil end
    if self:_ApplyData(self:Get(name)) then
        cs.loaded = name
        return name
    end
    return nil
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
