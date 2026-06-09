local addonName, ns = ...

-- Core/DB/CoreTables.lua
-- The central "predefined tables" location: common reference data that belongs to the addon as a
-- whole rather than any one feature, contributed into the single shared database (see
-- DatabaseManager). Defining them here once means every module/service can JOIN to them instead of
-- each keeping its own copy -- the whole reason for one shared database.
--
-- These illustrate all three scopes:
--   * faction       -- LOCAL: rebuilt from code every session, fixed reference rows (seeded).
--   * zone          -- LOCAL: rebuilt at runtime from the world map (populated by its owner; the
--                      table is defined here, the rows are filled when the map is available).
--   * flight_master -- GLOBAL: account-wide, accumulated as flight masters are discovered (the Misc
--                      module fills it when a taxi map is opened). It JOINS to faction -- a global
--                      table referencing a local one, which is exactly the shared-reference win.

ns.DB = ns.DB or {}

-- Scopes are given as bare strings ("local"/"global"/"char") -- the schema validates them against
-- ns.DB.Scope at build time. Using strings (not the enum) keeps this plain data file free of any
-- load-order dependency on Types.lua (the .toc loads Core/DB/* alphabetically).
ns.DB.CoreTables = {
    -- Alliance / Horde / Neutral, fixed by id. In memory only (rebuilt each session from this seed).
    faction = {
        scope = "local",
        columns = {
            { name = "id",   type = "integer", primaryKey = true },
            { name = "tag",  type = "text", nullable = false },   -- UnitFactionGroup value
            { name = "name", type = "text", nullable = false },
        },
        unique = { { "tag" } },
        seed = function(db)
            db:InsertAll("faction", {            -- batch insert (one call), not row-by-row
                { id = 1, tag = "Alliance", name = "Alliance" },
                { id = 2, tag = "Horde",    name = "Horde" },
                { id = 3, tag = "Neutral",  name = "Neutral" },
            })
        end,
    },

    -- Map zones, rebuilt at runtime from the world map (no seed here -- the owner populates it once
    -- the map API is available). LOCAL: cheap to regenerate, never worth persisting.
    zone = {
        scope = "local",
        columns = {
            { name = "id",   type = "integer", primaryKey = true },   -- UiMapID
            { name = "name", type = "text", nullable = false },
        },
        unique = { { "name" } },
    },

    -- Flight masters, discovered (with their zone + map coords) by the LocalTables service whenever a
    -- taxi map opens. JOINS to the (local) faction and zone tables. Keyed by node_id -- the canonical
    -- C_TaxiMap nodeID, GLOBALLY UNIQUE per physical flight point -- so there is exactly one row per
    -- node. A neutral flight point has ONE nodeID seen by BOTH factions, so when the rival faction
    -- discovers an existing node its faction is flipped to "Neutral" (see LocalTables._DiscoverMaster).
    -- A master is only created once its zone is known (zone is NOT NULL); recording looks masters up.
    flight_master = {
        scope = "global",
        columns = {
            { name = "id",      type = "integer", primaryKey = true, autoIncrement = true },
            { name = "node_id", type = "integer", nullable = false },   -- canonical C_TaxiMap nodeID (unique per point)
            { name = "faction", type = "text", nullable = false, references = { table = "faction", column = "tag" } },
            { name = "zone",    type = "text", nullable = false, references = { table = "zone", column = "name" } },
            { name = "name",    type = "text", nullable = false },      -- flight master name only (e.g. "Stormwind")
            { name = "x",       type = "number" },                      -- node position on the continent map
            { name = "y",       type = "number" },
        },
        unique  = { { "node_id" } },
        indices = { { columns = { "faction" } }, { columns = { "name" } } },
    },
}
