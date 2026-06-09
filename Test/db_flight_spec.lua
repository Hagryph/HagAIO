local S = dofile("Test/support.lua")

-- Proves the Flight feature's relational model + quality-merge rules against the engine. It mirrors
-- the DAO in Modules/Misc.lua (_FlightStore/_FlightStoreIfNew/_FlightGet/_FlightRecords) over the
-- same routes + route_hops schema, so the SQL design that backs flight recording is locked by tests
-- even though the WoW-coupled module can't run headless.

local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor" }

local DIRECT, FLY = 2, 1

local SCHEMA = { tables = {
    routes = {
        columns = {
            { name = "id", type = "integer", primaryKey = true, autoIncrement = true },
            { name = "faction", type = "text", nullable = false },
            { name = "src", type = "text", nullable = false },
            { name = "dst", type = "text", nullable = false },
            { name = "t", type = "number", nullable = false },
            { name = "quality", type = "integer", nullable = false },
        },
        unique = { { "faction", "src", "dst" } },
        indices = { { columns = { "faction" } } },
    },
    route_hops = {
        columns = {
            { name = "route_id", type = "integer", references = { table = "routes", onDelete = "cascade" } },
            { name = "ordinal", type = "integer" },
            { name = "node", type = "text", nullable = false },
        },
        primaryKey = { "route_id", "ordinal" },
    },
} }

-- a tiny DAO matching Misc's _Flight* methods
local function newDb(ns) return ns.DB.Database:New("Flight", ns.DB.Schema.new("Flight", SCHEMA), {}) end
local function row(db, f, a, b)
    return db:Select("id", "t", "quality"):From("routes")
        :Where("faction", "=", f):AndWhere("src", "=", a):AndWhere("dst", "=", b):Limit(1):Run()[1]
end
local function setHops(db, id, via)
    db:Delete("route_hops", function(h) return h.route_id == id end)
    if via then for i, n in ipairs(via) do db:Insert("route_hops", { route_id = id, ordinal = i, node = n }) end end
end
local function hops(db, id)
    local r = db:Select("node"):From("route_hops"):Where("route_id", "=", id):OrderBy("ordinal", "asc"):Run()
    if #r == 0 then return nil end
    local v = {}; for i, x in ipairs(r) do v[i] = x.node end; return v
end
local function store(db, f, a, b, secs, via)        -- DIRECT write with quality merge
    local x = row(db, f, a, b)
    if not x then setHops(db, db:Insert("routes", { faction = f, src = a, dst = b, t = secs, quality = DIRECT }).id, via); return true end
    if x.quality < DIRECT then
        db:Update("routes", { t = secs, quality = DIRECT }, function(r) return r.id == x.id end); setHops(db, x.id, via); return true
    elseif math.abs(secs - x.t) >= 5 then
        db:Update("routes", { t = secs }, function(r) return r.id == x.id end); setHops(db, x.id, via); return true
    end
    return false
end
local function storeIfNew(db, f, a, b, secs, via)   -- FLY fill-only
    if row(db, f, a, b) then return false end
    setHops(db, db:Insert("routes", { faction = f, src = a, dst = b, t = secs, quality = FLY }).id, via); return true
end

local function newNs()
    local ns = S.newNs()
    for _, fn in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. fn .. ".lua") end
    return ns
end

describe("Flight DB model", function()
    it("records a DIRECT leg with relational hops", function()
        local ns = newNs(); local db = newDb(ns)
        store(db, "Horde", "A", "C", 120, { "B" })
        local r = row(db, "Horde", "A", "C")
        assert.are.equal(DIRECT, r.quality)
        assert.are.equal(120, r.t)
        local v = hops(db, r.id)
        assert.are.equal(1, #v); assert.are.equal("B", v[1])
    end)

    it("storeIfNew only fills an empty direction (FLY)", function()
        local ns = newNs(); local db = newDb(ns)
        assert.is_true(storeIfNew(db, "Horde", "A", "B", 50))
        assert.is_false(storeIfNew(db, "Horde", "A", "B", 99))   -- already present
        assert.are.equal(50, row(db, "Horde", "A", "B").t)
    end)

    it("a DIRECT measurement always replaces a FLY entry (even < 5s)", function()
        local ns = newNs(); local db = newDb(ns)
        storeIfNew(db, "Horde", "A", "B", 52)                    -- FLY 52
        assert.is_true(store(db, "Horde", "A", "B", 50))         -- DIRECT 50 wins despite 2s
        local r = row(db, "Horde", "A", "B")
        assert.are.equal(DIRECT, r.quality); assert.are.equal(50, r.t)
    end)

    it("DIRECT-over-DIRECT only updates when the time moved >= 5s", function()
        local ns = newNs(); local db = newDb(ns)
        store(db, "Horde", "A", "B", 100)
        assert.is_false(store(db, "Horde", "A", "B", 103))       -- +3s -> ignored
        assert.are.equal(100, row(db, "Horde", "A", "B").t)
        assert.is_true(store(db, "Horde", "A", "B", 108))        -- +8s -> updated
        assert.are.equal(108, row(db, "Horde", "A", "B").t)
    end)

    it("directions and factions are independent rows", function()
        local ns = newNs(); local db = newDb(ns)
        store(db, "Horde", "A", "B", 100)
        store(db, "Horde", "B", "A", 110)
        store(db, "Alliance", "A", "B", 120)
        assert.are.equal(100, row(db, "Horde", "A", "B").t)
        assert.are.equal(110, row(db, "Horde", "B", "A").t)
        assert.are.equal(120, row(db, "Alliance", "A", "B").t)
        assert.are.equal(3, db:Store():Count("routes"))
    end)

    it("deleting a route cascades its hops", function()
        local ns = newNs(); local db = newDb(ns)
        store(db, "Horde", "A", "C", 120, { "B" })
        local id = row(db, "Horde", "A", "C").id
        assert.are.equal(1, db:Store():Count("route_hops"))
        db:Delete("routes", function(r) return r.id == id end)
        assert.are.equal(0, db:Store():Count("route_hops"))
    end)

    it("reconstructs FlightGraph records (src, hops..., dst) for a faction", function()
        local ns = newNs(); local db = newDb(ns)
        store(db, "Horde", "A", "D", 300, { "B", "C" })
        store(db, "Alliance", "X", "Y", 10)
        local routes = db:Select("id", "src", "dst", "t", "quality"):From("routes"):Where("faction", "=", "Horde"):Run()
        assert.are.equal(1, #routes)
        local seq = { routes[1].src }
        for _, n in ipairs(hops(db, routes[1].id) or {}) do seq[#seq + 1] = n end
        seq[#seq + 1] = routes[1].dst
        assert.are.equal(4, #seq)
        assert.are.equal("A", seq[1]); assert.are.equal("B", seq[2]); assert.are.equal("C", seq[3]); assert.are.equal("D", seq[4])
    end)
end)
