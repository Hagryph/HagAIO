local addonName, ns = ...
local Class = ns.Class

-- Modules/Misc.lua
-- Miscellaneous helpers, each its own SUBMODULE of this thin parent module -- the codebase's
-- module-with-submodules shape (a top-level <Name>.lua plus a same-named <Name>/ folder, like
-- Class and Dashboard). The parent owns ONLY the shared flight DB tables (a submodule can't
-- contribute tables); each feature lives in its own file under Modules/Misc/:
--   * FlightTimers.lua — time each flight path; an ALWAYS-ON recorder (builds the DB even while the
--     module is off) plus a load-gated countdown / map-hover display.
--   * SellJunk.lua — sell grey items at a vendor, automatically or via a button.
-- The module is OFF by default, so nothing displays and no junk sells by default, but the always-on
-- flight recorder (FlightTimers:OnInitialize) still builds the database.

-- The flight tables the PARENT module contributes to the ONE shared database (account-wide / GLOBAL
-- scope). A recorded route is one `flight_route` row referencing two `flight_master` nodes by id
-- (src, dst) with its measured time + quality tier -- it carries NO faction of its own; the faction
-- is the masters' (a route is valid for you when both masters are your faction or Neutral). The
-- booked intermediate nodes it spanned live RELATIONALLY as ordered `flight_hop` rows (each an FK to
-- a flight_master, cascade-deleted with the route) -- never a blob. `flight_master` itself is a
-- central CoreTable. The FlightTimers submodule owns the small query methods (_Flight*/_Master*)
-- over self:DB() -- the shared database these tables are contributed to.
local FLIGHT_TABLES = {
    flight_route = {
        scope = "global",
        columns = {
            { name = "id",  type = "integer", primaryKey = true, autoIncrement = true },
            -- src/dst are flight_master node ids; if a master is deleted, its routes go with it.
            { name = "src", type = "integer", nullable = false, references = { table = "flight_master", onDelete = "cascade" } },
            { name = "dst", type = "integer", nullable = false, references = { table = "flight_master", onDelete = "cascade" } },
            { name = "t",       type = "number",  nullable = false },
            { name = "quality", type = "integer", nullable = false },
        },
        unique  = { { "src", "dst" } },
        indices = { { columns = { "src" } } },
    },
    flight_hop = {
        scope = "global",
        columns = {
            { name = "route_id", type = "integer", references = { table = "flight_route", onDelete = "cascade" } },
            { name = "ordinal",  type = "integer" },
            -- the intermediate flight_master node id; deleting that master removes the hop.
            { name = "master",   type = "integer", nullable = false, references = { table = "flight_master", onDelete = "cascade" } },
        },
        primaryKey = { "route_id", "ordinal" },
    },
}

local Misc = Class.new("Misc", ns.Module)

ns.ModuleManager:Register(Misc:New("Misc", {
    title = "Miscellaneous",
    description = "Flight-path timers and selling junk.",
    defaultEnabled = false,
    color = ns.Theme.hex.grey,  -- distinct tag (accent=Core, green=UnitFrames, purple=Class, gold=Questing, red=CVars)
    -- The parent is thin: no service deps of its own (DatabaseManager is auto-added by `tables`); the
    -- flight recorder's EventBus dep lives on the FlightTimers submodule that actually uses it.
    tables = FLIGHT_TABLES,   -- flight_route + flight_hop contributed to the shared database (GLOBAL)
}))
