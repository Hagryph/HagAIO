local S = dofile("Test/support.lua")

-- Proves the Flight feature's NORMALISED relational model against the engine: a flight_route
-- references two flight_master nodes by id (no faction of its own -- the faction is the masters');
-- the booked intermediate nodes are flight_hop rows, each an FK to a flight_master. Mirrors the DAO
-- in Modules/Misc.lua so the SQL design that backs flight recording is locked by tests.

local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor", "CoreTables", "DatabaseManager" }

local DIRECT, FLY = 2, 1

-- the flight tables Misc contributes (flight_master/faction/zone come from CoreTables)
local FLIGHT_TABLES = {
    flight_route = {
        scope = "global",
        columns = {
            { name = "id",  type = "integer", primaryKey = true, autoIncrement = true },
            { name = "src", type = "integer", nullable = false, references = { table = "flight_master" } },
            { name = "dst", type = "integer", nullable = false, references = { table = "flight_master" } },
            { name = "t",       type = "number",  nullable = false },
            { name = "quality", type = "integer", nullable = false },
        },
        unique = { { "src", "dst" } },
    },
    flight_hop = {
        scope = "global",
        columns = {
            { name = "route_id", type = "integer", references = { table = "flight_route", onDelete = "cascade" } },
            { name = "ordinal",  type = "integer" },
            { name = "master",   type = "integer", nullable = false, references = { table = "flight_master" } },
        },
        primaryKey = { "route_id", "ordinal" },
    },
}

local function built()
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    ns.SavedVars = { IsLoaded = function() return true end, DataSlot = function() return {} end }
    local mgr = ns._captured["DatabaseManager"]
    mgr:OnInitialize()
    mgr:Contribute(FLIGHT_TABLES)
    return mgr:Build(), ns
end

-- a small DAO mirroring Misc's _Master*/_Flight* (translate node names <-> master ids)
local function masterId(db, faction, name, create)
    local r = db:Select("id"):From("flight_master"):Where("faction", "=", faction):AndWhere("name", "=", name):Limit(1):Run()
    if r[1] then return r[1].id end
    if not create then return nil end
    return db:Insert("flight_master", { faction = faction, name = name }).id
end
local function row(db, sid, did)
    return db:Select("id", "t", "quality"):From("flight_route"):Where("src", "=", sid):AndWhere("dst", "=", did):Limit(1):Run()[1]
end
local function setHops(db, rid, faction, via)
    db:Delete("flight_hop", function(h) return h.route_id == rid end)
    if via then for i, n in ipairs(via) do db:Insert("flight_hop", { route_id = rid, ordinal = i, master = masterId(db, faction, n, true) }) end end
end
local function store(db, faction, a, b, secs, via)
    local sid, did = masterId(db, faction, a, true), masterId(db, faction, b, true)
    local x = row(db, sid, did)
    if not x then setHops(db, db:Insert("flight_route", { src = sid, dst = did, t = secs, quality = DIRECT }).id, faction, via); return true end
    if x.quality < DIRECT then
        db:Update("flight_route", { t = secs, quality = DIRECT }, function(r) return r.id == x.id end); setHops(db, x.id, faction, via); return true
    elseif math.abs(secs - x.t) >= 5 then
        db:Update("flight_route", { t = secs }, function(r) return r.id == x.id end); setHops(db, x.id, faction, via); return true
    end
    return false
end
local function storeIfNew(db, faction, a, b, secs)
    local sid, did = masterId(db, faction, a, true), masterId(db, faction, b, true)
    if row(db, sid, did) then return false end
    db:Insert("flight_route", { src = sid, dst = did, t = secs, quality = FLY }); return true
end
local function hopNames(db, rid)
    local r = db:Select("master"):From("flight_hop"):Where("route_id", "=", rid):OrderBy("ordinal", "asc"):Run()
    local out = {}
    for i, x in ipairs(r) do out[i] = db:Select("name"):From("flight_master"):Where("id", "=", x.master):Run()[1].name end
    return out
end

describe("Flight DB model (flight_master / flight_route / flight_hop)", function()
    it("records a DIRECT leg, storing intermediates as flight_master refs", function()
        local db = built()
        store(db, "Horde", "A", "C", 120, { "B" })
        local r = row(db, masterId(db, "Horde", "A"), masterId(db, "Horde", "C"))
        assert.are.equal(DIRECT, r.quality)
        assert.are.equal(120, r.t)
        local v = hopNames(db, r.id)
        assert.are.equal(1, #v); assert.are.equal("B", v[1])
    end)

    it("a master is reused across routes (getOrCreate by faction + name)", function()
        local db = built()
        store(db, "Horde", "A", "B", 50)
        store(db, "Horde", "A", "C", 60)
        -- only one master 'A' exists for Horde
        assert.are.equal(1, #db:Select("id"):From("flight_master"):Where("faction", "=", "Horde"):AndWhere("name", "=", "A"):Run())
    end)

    it("storeIfNew only fills an empty direction; DIRECT then replaces a FLY entry", function()
        local db = built()
        assert.is_true(storeIfNew(db, "Horde", "A", "B", 52))
        assert.is_false(storeIfNew(db, "Horde", "A", "B", 99))
        assert.is_true(store(db, "Horde", "A", "B", 50))                  -- DIRECT wins despite 2s
        local r = row(db, masterId(db, "Horde", "A"), masterId(db, "Horde", "B"))
        assert.are.equal(DIRECT, r.quality); assert.are.equal(50, r.t)
    end)

    it("DIRECT-over-DIRECT only updates on a >= 5s change", function()
        local db = built()
        store(db, "Horde", "A", "B", 100)
        local sid, did = masterId(db, "Horde", "A"), masterId(db, "Horde", "B")
        assert.is_false(store(db, "Horde", "A", "B", 103))
        assert.are.equal(100, row(db, sid, did).t)
        assert.is_true(store(db, "Horde", "A", "B", 108))
        assert.are.equal(108, row(db, sid, did).t)
    end)

    it("deleting a route cascades its hops", function()
        local db = built()
        store(db, "Horde", "A", "C", 120, { "B" })
        local r = row(db, masterId(db, "Horde", "A"), masterId(db, "Horde", "C"))
        assert.are.equal(1, db:Store():Count("flight_hop"))
        db:Delete("flight_route", function(x) return x.id == r.id end)
        assert.are.equal(0, db:Store():Count("flight_hop"))
    end)

    it("enforces the master FKs and the master.faction FK to the faction table", function()
        local db = built()
        -- a route src must be an existing flight_master
        assert.is_false(pcall(function() db:Insert("flight_route", { src = 999, dst = 1000, t = 1, quality = DIRECT }) end))
        -- a master's faction must be a real faction tag
        assert.is_false(pcall(function() db:Insert("flight_master", { faction = "Pandaren", name = "X" }) end))
    end)

    it("derives a faction's records by joining flight_route.src to its master", function()
        local db = built()
        store(db, "Horde", "A", "D", 300, { "B", "C" })
        store(db, "Alliance", "X", "Y", 10)
        local rows = db:Select("flight_route.id", "flight_route.src", "flight_route.dst")
            :From("flight_route")
            :InnerJoin("flight_master", { on = { "flight_route.src", "flight_master.id" } })
            :Where("flight_master.faction", "=", "Horde"):Run()
        assert.are.equal(1, #rows)
        local seq = { db:Select("name"):From("flight_master"):Where("id", "=", rows[1].src):Run()[1].name }
        for _, n in ipairs(hopNames(db, rows[1].id)) do seq[#seq + 1] = n end
        seq[#seq + 1] = db:Select("name"):From("flight_master"):Where("id", "=", rows[1].dst):Run()[1].name
        assert.are.equal(4, #seq)
        assert.are.equal("A", seq[1]); assert.are.equal("B", seq[2]); assert.are.equal("C", seq[3]); assert.are.equal("D", seq[4])
    end)
end)
