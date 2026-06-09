local addonName, ns = ...
local Class = ns.Class

-- Services/Profiles.lua
-- Named config profiles + copy-paste sharing, built on the SavedVars cascade. A profile records
-- ONLY what it changed from the code defaults (the same diff a character's override layer stores),
-- and lives in the account-wide saved table (HagAIODB.profiles[name]) so it's shared across all
-- your characters. It is NEVER deep-copied onto a character: each character records which profile
-- it has LOADED (SavedVars char.loadedProfile), and that profile is resolved LIVE as the middle
-- layer of the cascade (override -> profile -> default). So editing a profile updates every
-- character using it, and a setting a profile didn't touch falls through to the code default.
--
--   Save(name)    snapshot this character's current effective config (as diffs) into a profile.
--   LoadProfile   wipe this character's overrides and point it at the profile -> everything then
--                 resolves to the profile (and code defaults). Finalised with a /reload.
--   global profile  one profile may be flagged global; a character that has loaded none gets it
--                   pointed-to automatically on login (it then fills every value it set).
-- Export runs a profile's diffs through ns.Serializer into a share string; Import decodes (and
-- migrates) one back into the profiles map. The UI (Settings -> Profiles) drives all of this.

local Profiles = Class.new("Profiles", ns.Service)

-- The stored profiles map (account-wide), created on first use.
function Profiles:_Store()
    local g = ns.SavedVars:Global()
    g.profiles = g.profiles or {}
    return g.profiles
end

function Profiles:List()
    local out = {}
    for name in pairs(self:_Store()) do out[#out + 1] = name end
    table.sort(out)
    return out
end

function Profiles:Has(name) return self:_Store()[name] ~= nil end
function Profiles:Get(name) return self:_Store()[name] end

-- This character's current effective config captured as diffs-from-default (see SavedVars).
function Profiles:Snapshot() return ns.SavedVars:SnapshotDiffs() end

-- ---- global profile -------------------------------------------------------
-- One profile (account-wide) may be flagged GLOBAL: a character that has never loaded a profile
-- gets it auto-applied on login. The flag is exclusive and may be cleared (nil = no global).
function Profiles:GetGlobal() return ns.SavedVars:Global().globalProfile end
function Profiles:IsGlobal(name) return name ~= nil and self:GetGlobal() == name end
function Profiles:SetGlobal(name)
    local g = ns.SavedVars:Global()
    if name == nil then g.globalProfile = nil; return true end
    if not self:Has(name) then return false, "no profile named '" .. tostring(name) .. "'" end
    g.globalProfile = name
    return true
end

-- Which profile THIS character has loaded (nil = none -> pure code defaults under its overrides).
function Profiles:GetLoaded() return ns.SavedVars:LoadedProfile() end

function Profiles:Save(name)
    if type(name) ~= "string" or name == "" then return false, "a profile name is required" end
    self:_Store()[name] = self:Snapshot()
    return true
end

function Profiles:Delete(name)
    local store = self:_Store()
    if store[name] == nil then return false, "no profile named '" .. tostring(name) .. "'" end
    store[name] = nil
    if self:IsGlobal(name) then self:SetGlobal(nil) end          -- don't leave a dangling global
    if ns.SavedVars:LoadedProfile() == name then                  -- this char was on it -> fall to defaults
        ns.SavedVars:SetLoadedProfile(nil)
    end
    return true
end

-- Load a profile into THIS character: wipe its override layer and point it at the profile, so
-- everything resolves to the profile (and code defaults beneath it). Persists immediately; a
-- /reload re-applies it to already-built frames. Other characters are unaffected.
function Profiles:LoadProfile(name)
    if not self:Has(name) then return false, "no profile named '" .. tostring(name) .. "'" end
    ns.SavedVars:ClearOverrides()
    ns.SavedVars:SetLoadedProfile(name)
    ns.SavedVars:Rematerialize()   -- live config now resolves to the profile (+ defaults)
    return true
end

-- On login, if this character has loaded no profile, point it at the account's global profile
-- (if set + still exists). It then fills every value the global profile set, while anything it
-- didn't set falls through to code defaults -- exactly like a normal loaded profile, but without
-- wiping any overrides the character already has. Returns the applied name, or nil.
function Profiles:ApplyGlobalForFreshChar()
    if ns.SavedVars:LoadedProfile() then return nil end   -- this character already uses a profile
    local name = self:GetGlobal()
    if not name or not self:Has(name) then return nil end
    ns.SavedVars:SetLoadedProfile(name)
    return name
end

-- name (or nil = this character's current config) -> share string.
function Profiles:Export(name)
    local data = name and self:Get(name) or self:Snapshot()
    if not data then return nil, "no profile named '" .. tostring(name) .. "'" end
    return ns.Serializer:Encode(data)
end

-- A profile is a map of namespace -> diff table (e.g. module_Questing = { autoAccept = true }).
-- Require at least one string-keyed table entry so a decoded blob of garbage is rejected before
-- it can be stored.
local function looksLikeProfile(t)
    if type(t) ~= "table" then return false end
    for k, v in pairs(t) do
        if type(k) == "string" and type(v) == "table" then return true end
    end
    return false
end

-- share string -> saved under `name` (decoded + migrated). Does NOT load it; the user then loads
-- it. Returns (true, name) or (false, reason).
function Profiles:Import(str, name)
    local value, err = ns.Serializer:Decode(str)
    if not value then return false, err end
    if not looksLikeProfile(value) then return false, "that string isn't a profile" end
    ns.SavedVars:MigrateTable(value)
    if not name or name == "" then name = "Imported" end
    self:_Store()[name] = value
    return true, name
end

ns.ServiceManager:Register(Profiles:New("Profiles", { deps = { "SavedVars", "Serializer" } }))
