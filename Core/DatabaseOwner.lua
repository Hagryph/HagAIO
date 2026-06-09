local addonName, ns = ...

-- Core/DatabaseOwner.lua
-- Mixin shared by ns.Component (so Module + Submodule inherit it) and ns.Service, letting any of
-- them CONTRIBUTE tables to the ONE shared database -- declaratively, like settings or events. A
-- `tables` opt maps a table name to its schema spec (with an optional `scope` -- LOCAL/GLOBAL/CHAR
-- -- and `seed(db)`); the framework hands them to the DatabaseManager, which aggregates every
-- owner's tables (plus the central ns.DB.CoreTables) into a single schema. The owner then writes
-- its OWN private query methods (small DAOs) over self:DB() -- the engine is the substrate, the
-- owner keeps the fast, intention-revealing accessors next to the feature.
--
--   tables = { flight_route = { scope = "global", columns = {...}, unique = {...} },
--              flight_hop   = { scope = "global", columns = {...}, primaryKey = {...} } }
--   ...
--   function MyModule:_BestTime(faction, a, b)            -- a private, often-used query
--       local r = self:DB():Select("t"):From("flight_route")
--           :Where("faction","=",faction):AndWhere("src","=",a):AndWhere("dst","=",b):Limit(1):Run()
--       return r[1] and r[1].t or nil
--   end
--
-- self:DB() is the single shared database -- nil until it is BUILT (Init.lua builds it on
-- PLAYER_LOGIN, after all owners have contributed and saved variables exist). Contribute during
-- init; query during gameplay.

ns.DatabaseOwner = ns.Mixin.new("DatabaseOwner", {
    -- Capture the declared table specs (called from the owner's Initialize). Shape:
    --   { name = <table spec with optional scope/seed>, ... }
    _DeclareTables = function(self, tables)
        self:_p().dbTables = tables or {}
    end,

    -- Hand the declared tables to the manager to aggregate into the shared schema. Idempotent:
    -- it's called both in the ADDON_LOADED pre-build sweep and again from the owner's _Init, but the
    -- tables are contributed exactly once (before the database is built).
    _ContributeTables = function(self)
        local p = self:_p()
        if p._dbContributed then return end
        p._dbContributed = true
        if p.dbTables and next(p.dbTables) and ns.DatabaseManager then
            ns.DatabaseManager:Contribute(p.dbTables)
        end
    end,

    -- The single shared Database (nil until built).
    DB = function(self)
        return ns.DatabaseManager and ns.DatabaseManager:Shared() or nil
    end,

    -- Names of the tables this owner contributes.
    OwnedTables = function(self)
        local out, t = {}, self:_p().dbTables or {}
        for name in pairs(t) do out[#out + 1] = name end
        table.sort(out)
        return out
    end,
})

-- Append `name` to a dependency list without duplicates, returning a NEW list (never mutates the
-- caller's opts table). Used by Module/Service to auto-add the DatabaseManager dep when tables are
-- declared.
function ns.AddDep(deps, name)
    for _, d in ipairs(deps) do if d == name then return deps end end
    local out = {}
    for i, d in ipairs(deps) do out[i] = d end
    out[#out + 1] = name
    return out
end
