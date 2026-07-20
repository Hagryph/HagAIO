local S = dofile("Test/support.lua")

-- Test/localtables_spec.lua
-- Locks Services/LocalTables.lua: the reference-data discovery service that seeds the shared
-- database's flight_master + zone tables from the live taxi map. Runs against a REAL in-memory
-- database (CoreTables schema, faction seeded, FKs enforced) wired through a DatabaseManager stub,
-- with C_Map / C_TaxiMap / GetTaxiMapID / UnitFactionGroup stubbed so each discovery pass is driven
-- explicitly. What it pins:
--   * _DiscoverMaster: a brand-new node INSERTS one row; a cross-faction rediscovery flips the row
--     to "Neutral"; an already-Neutral row is NOT written again (the no-redundant-write guard);
--     zone + name enrichment fills those columns.
--   * an UNRESOLVED zone is SKIPPED (never inserted with a bad zone -- zone is NOT NULL) and the
--     node is RETRIED on a later pass once its zone resolves.
--   * _ZoneAt seeds the zone lookup row exactly once.
--   * _DiscoverNodes bails on an unknown faction (no rows written).

local DB_FILES = { "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor", "CoreTables", "DatabaseManager" }

-- Fresh ns with the DB engine + CoreTables, a built shared database wired through the real
-- DatabaseManager (so faction rows are seeded and the flight_master/zone FK constraints are live),
-- the FlightResolver lib (NodeName normalisation), and the LocalTables service. Returns
-- (service, db, ns).
local function setup()
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    S.load(ns, "Lib/FlightResolver.lua")
    ns.SavedVars = { IsLoaded = function() return true end, DataSlot = function() return {} end }
    local mgr = ns._captured["DatabaseManager"]; mgr:OnInitialize()
    local db = mgr:Build()                       -- seeds the faction table (Alliance/Horde/Neutral)
    ns.DatabaseManager = mgr                     -- self:DB() == ns.DatabaseManager:Shared()
    S.load(ns, "Services/LocalTables.lua")
    return ns._captured["LocalTables"], db, ns
end

-- One flight_master row for a node, or nil.
local function master(db, nodeID)
    return db:Select("node_id", "faction", "zone", "name", "x", "y")
        :From("flight_master"):Where("node_id", "=", nodeID):Limit(1):Run()[1]
end

-- How many flight_master rows exist for a node (0 or 1 -- node_id is the PK).
local function masterCount(db, nodeID)
    return #db:Select("node_id"):From("flight_master"):Where("node_id", "=", nodeID):Run()
end

describe("LocalTables:_DiscoverMaster", function()
    it("a brand-new flight master INSERTS one row with its faction/zone/name/coords", function()
        local lt, db = setup()
        db:Insert("zone", { name = "Elwynn Forest" })   -- zone must exist (FK)
        lt:_DiscoverMaster("Alliance", "Stormwind", 101, "Elwynn Forest", 0.5, 0.6)
        local r = master(db, 101)
        assert(r ~= nil)
        assert.are.equal("Alliance", r.faction)
        assert.are.equal("Elwynn Forest", r.zone)
        assert.are.equal("Stormwind", r.name)
        assert.are.equal(0.5, r.x)
        assert.are.equal(0.6, r.y)
        assert.are.equal(1, masterCount(db, 101))
    end)

    it("a cross-faction REdiscovery flips the row's faction to Neutral (one row, in place)", function()
        local lt, db = setup()
        db:Insert("zone", { name = "Z" })
        lt:_DiscoverMaster("Alliance", "Dock", 202, "Z")          -- Alliance sees it first
        assert.are.equal("Alliance", master(db, 202).faction)
        lt:_DiscoverMaster("Horde", "Dock", 202, "Z")             -- Horde sees the SAME node_id
        assert.are.equal("Neutral", master(db, 202).faction)      -- shared -> Neutral
        assert.are.equal(1, masterCount(db, 202))                 -- still exactly one row, flipped in place
    end)

    it("an ALREADY-Neutral row is NOT flipped/written again on a third faction's pass", function()
        local lt, db = setup()
        db:Insert("zone", { name = "Z" })
        lt:_DiscoverMaster("Alliance", "Dock", 303, "Z")
        lt:_DiscoverMaster("Horde", "Dock", 303, "Z")             -- now Neutral
        assert.are.equal("Neutral", master(db, 303).faction)

        -- Trip the engine: a second Update would error here, proving _DiscoverMaster issued none.
        local origUpdate = db.Update
        local updated = false
        db.Update = function(self, ...) updated = true; return origUpdate(self, ...) end
        lt:_DiscoverMaster("Alliance", "Dock", 303, "Z")          -- already Neutral, same zone+name
        db.Update = origUpdate
        assert.is_false(updated)                                  -- no redundant write
        assert.are.equal("Neutral", master(db, 303).faction)      -- unchanged
    end)

    it("zone + name enrichment fills those columns on a later, better-resolved pass", function()
        local lt, db = setup()
        db:Insert("zone", { name = "Old Town" })
        db:Insert("zone", { name = "New Town" })
        lt:_DiscoverMaster("Horde", "Outpost", 404, "Old Town")
        assert.are.equal("Old Town", master(db, 404).zone)
        assert.are.equal("Outpost", master(db, 404).name)
        -- A later pass resolves a different zone + a refined name: both columns are enriched.
        lt:_DiscoverMaster("Horde", "Outpost Keep", 404, "New Town")
        local r = master(db, 404)
        assert.are.equal("New Town", r.zone)
        assert.are.equal("Outpost Keep", r.name)
        assert.are.equal("Horde", r.faction)                      -- same faction -> not flipped
        assert.are.equal(1, masterCount(db, 404))
    end)

    it("an UNRESOLVED zone (nil) is SKIPPED -- never inserted with a bad zone", function()
        local lt, db = setup()
        lt:_DiscoverMaster("Alliance", "Ghost", 505, nil)         -- zone could not be resolved
        assert.is_nil(master(db, 505))                            -- no row written (zone is NOT NULL)
        assert.are.equal(0, masterCount(db, 505))
    end)

    it("a node skipped for a missing zone is RETRIED and INSERTED once its zone resolves", function()
        local lt, db = setup()
        lt:_DiscoverMaster("Alliance", "Ghost", 606, nil)         -- first pass: zone unknown, skipped
        assert.is_nil(master(db, 606))
        db:Insert("zone", { name = "Resolved" })
        lt:_DiscoverMaster("Alliance", "Ghost", 606, "Resolved")  -- later pass: zone now known
        local r = master(db, 606)
        assert(r ~= nil)
        assert.are.equal("Resolved", r.zone)
        assert.are.equal("Alliance", r.faction)
    end)
end)

describe("LocalTables:_ZoneAt", function()
    it("seeds the zone lookup row exactly once for a resolved position", function()
        local lt, db = setup()
        _G.C_Map = { GetMapInfoAtPosition = function() return { name = "Westfall" } end }
        local zoneRows = function()
            return #db:Select("name"):From("zone"):Where("name", "=", "Westfall"):Run()
        end
        assert.are.equal(0, zoneRows())
        local name, x, y = lt:_ZoneAt(84, { x = 0.1, y = 0.2 })
        assert.are.equal("Westfall", name)
        assert.are.equal(0.1, x)
        assert.are.equal(0.2, y)
        assert.are.equal(1, zoneRows())                           -- inserted once
        lt:_ZoneAt(84, { x = 0.3, y = 0.4 })                      -- same zone name, second call
        assert.are.equal(1, zoneRows())                           -- NOT inserted again
    end)

    it("returns nil (and seeds nothing) when the position can't be resolved to a zone", function()
        local lt, db = setup()
        _G.C_Map = { GetMapInfoAtPosition = function() return nil end }
        assert.is_nil(lt:_ZoneAt(84, { x = 0.1, y = 0.2 }))
        assert.are.equal(0, #db:Select("name"):From("zone"):Run())
    end)
end)

describe("LocalTables:_DiscoverNodes", function()
    it("bails on an unknown faction -- no flight_master rows written", function()
        local lt, db = setup()
        _G.UnitFactionGroup = function() return nil end           -- e.g. a neutral pandaren pre-choice
        local taxiCalled = false
        _G.GetTaxiMapID = function() return 1 end
        _G.C_TaxiMap = { GetAllTaxiNodes = function() taxiCalled = true; return {} end }
        lt:_DiscoverNodes()
        assert.is_false(taxiCalled)                               -- bailed before touching the taxi API
        assert.are.equal(0, #db:Select("node_id"):From("flight_master"):Run())
    end)

    it("a known faction drives a full discovery pass that inserts the map's nodes", function()
        local lt, db = setup()
        _G.UnitFactionGroup = function() return "Horde" end
        _G.GetTaxiMapID = function() return 1 end
        _G.C_Map = { GetMapInfoAtPosition = function() return { name = "Durotar" } end }
        _G.C_TaxiMap = {
            GetAllTaxiNodes = function()
                return {
                    { name = "Orgrimmar, Durotar", nodeID = 701, position = { x = 0.55, y = 0.45 } },
                    { name = "Razor Hill, Durotar", nodeID = 702, position = { x = 0.52, y = 0.68 } },
                }
            end,
        }
        lt:_DiscoverNodes()
        local a, b = master(db, 701), master(db, 702)
        assert(a ~= nil and b ~= nil)
        assert.are.equal("Horde", a.faction)
        assert.are.equal("Durotar", a.zone)
        assert.are.equal("Orgrimmar", a.name)                     -- NodeName stripped the ", Durotar"
        assert.are.equal("Razor Hill", b.name)
    end)
end)
