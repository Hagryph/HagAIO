local addonName, ns = ...

-- Core/DatabaseOwner.lua
-- Mixin shared by ns.Module and ns.Service so either can OWN one or more SQL databases declaratively
-- -- the same way they declare settings, events or commands. A `databases` opt maps a name to a
-- schema spec (+ optional perChar); the framework registers them with the DatabaseManager at init
-- and exposes the live handle via self:DB(name). Each owner then writes its OWN private query
-- methods (small DAOs) over self:DB(name) for the queries it runs often -- the engine is the
-- substrate, the owner keeps the fast, intention-revealing accessors next to the feature.
--
--   databases = { Flight = { schema = FLIGHT_SCHEMA, perChar = false } }
--   ...
--   function MyModule:_BestTime(faction, a, b)            -- a private, often-used query
--       local r = self:DB("Flight"):Select("t"):From("routes")
--           :Where("faction","=",faction):AndWhere("src","=",a):AndWhere("dst","=",b):Limit(1):Run()
--       return r[1] and r[1].t or nil
--   end
--
-- Modules init on PLAYER_LOGIN (saved vars already loaded), so their databases register
-- immediately and self:DB works inside OnInitialize. Services init earlier, before ADDON_LOADED,
-- so theirs are DEFERRED and registered on ResolvePending -- a service should reach self:DB after
-- login, not during OnInitialize.

ns.DatabaseOwner = ns.Mixin.new("DatabaseOwner", {
    -- Capture the declared database specs (called from the owner's Initialize). Shape:
    --   { Name = { schema = <spec table>, perChar = bool }, ... }
    _DeclareDatabases = function(self, databases)
        self:_p().databases = databases or {}
    end,

    -- Register every declared database with the manager (called from the owner's _Init).
    _RegisterDatabases = function(self)
        local dbs = self:_p().databases
        if not dbs or not ns.DatabaseManager then return end
        for name, d in pairs(dbs) do
            ns.DatabaseManager:Declare(name, d.schema, { perChar = d.perChar })
        end
    end,

    -- The live Database registered under `name` (or nil if not yet registered).
    DB = function(self, name)
        return ns.DatabaseManager and ns.DatabaseManager:Get(name) or nil
    end,

    -- Names of the databases this owner declared.
    OwnedDatabases = function(self)
        local out, dbs = {}, self:_p().databases or {}
        for name in pairs(dbs) do out[#out + 1] = name end
        table.sort(out)
        return out
    end,
})

-- Append `name` to a dependency list without duplicates, returning a NEW list (never mutates the
-- caller's opts table). Used by Module/Service to auto-add the DatabaseManager dep when databases
-- are declared.
function ns.AddDep(deps, name)
    for _, d in ipairs(deps) do if d == name then return deps end end
    local out = {}
    for i, d in ipairs(deps) do out[i] = d end
    out[#out + 1] = name
    return out
end
