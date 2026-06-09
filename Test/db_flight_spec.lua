local S = dofile("Test/support.lua")

-- Proves the Flight feature's normalised model against the engine. flight_master is keyed by the
-- canonical node_id (one row per physical flight point); a flight_route references two masters by
-- id and carries no faction (derived from the masters); flight_hop references intermediate masters.
-- Mirrors the split between the LocalTables discovery (creates masters, keyed by node_id, flips a
-- node seen by both factions to Neutral) and Misc recording (looks masters up by name + faction).

local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor", "CoreTables", "DatabaseManager" }

local DIRECT, FLY = 2, 1

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

local nextNode = 0
local function built()
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    ns.SavedVars = { IsLoaded = function() return true end, DataSlot = function() return {} end }
    local mgr = ns._captured["DatabaseManager"]
    mgr:OnInitialize()
    mgr:Contribute(FLIGHT_TABLES)
    local db = mgr:Build()
    db:Insert("zone", { id = 1, name = "Z" })           -- a zone for masters (flight_master.zone NOT NULL)
    return db
end

-- discovery: create a master under `faction` with a fresh canonical node_id + zone
local function seed(db, faction, name)
    nextNode = nextNode + 1
    return db:Insert("flight_master", { node_id = nextNode, faction = faction, name = name, zone = "Z" }).id
end
-- recording: look a master up by name, valid for the player (their faction or Neutral)
local function masterId(db, faction, name)
    local r = db:Select("id"):From("flight_master")
        :Where("name", "=", name):AndWhere("faction", "in", { faction, "Neutral" }):Limit(1):Run()
    return r[1] and r[1].id or nil
end
local function idOrSeed(db, faction, name) return masterId(db, faction, name) or seed(db, faction, name) end

local function row(db, sid, did)
    return db:Select("id", "t", "quality"):From("flight_route"):Where("src", "=", sid):AndWhere("dst", "=", did):Limit(1):Run()[1]
end
local function setHops(db, faction, rid, via)
    db:Delete("flight_hop", function(h) return h.route_id == rid end)
    if via then for i, n in ipairs(via) do db:Insert("flight_hop", { route_id = rid, ordinal = i, master = idOrSeed(db, faction, n) }) end end
end
local function store(db, faction, a, b, secs, via)
    local sid, did = idOrSeed(db, faction, a), idOrSeed(db, faction, b)
    local x = row(db, sid, did)
    if not x then setHops(db, faction, db:Insert("flight_route", { src = sid, dst = did, t = secs, quality = DIRECT }).id, via); return true end
    if x.quality < DIRECT then
        db:Update("flight_route", { t = secs, quality = DIRECT }, function(r) return r.id == x.id end); setHops(db, faction, x.id, via); return true
    elseif math.abs(secs - x.t) >= 5 then
        db:Update("flight_route", { t = secs }, function(r) return r.id == x.id end); setHops(db, faction, x.id, via); return true
    end
    return false
end
local function storeIfNew(db, faction, a, b, secs)
    local sid, did = idOrSeed(db, faction, a), idOrSeed(db, faction, b)
    if row(db, sid, did) then return false end
    db:Insert("flight_route", { src = sid, dst = did, t = secs, quality = FLY }); return true
end
local function hopNames(db, rid)
    local r = db:Select("master"):From("flight_hop"):Where("route_id", "=", rid):OrderBy("ordinal", "asc"):Run()
    local out = {}
    for i, x in ipairs(r) do out[i] = db:Select("name"):From("flight_master"):Where("id", "=", x.master):Run()[1].name end
    return out
end

describe("Flight DB model (flight_master keyed by node_id)", function()
    it("records a DIRECT leg, storing intermediates as flight_master refs", function()
        local db = built()
        store(db, "Horde", "A", "C", 120, { "B" })
        local r = row(db, masterId(db, "Horde", "A"), masterId(db, "Horde", "C"))
        assert.are.equal(DIRECT, r.quality); assert.are.equal(120, r.t)
        local v = hopNames(db, r.id)
        assert.are.equal(1, #v); assert.are.equal("B", v[1])
    end)

    it("reuses a master across routes (one row per node)", function()
        local db = built()
        store(db, "Horde", "A", "B", 50)
        store(db, "Horde", "A", "C", 60)
        assert.are.equal(1, #db:Select("id"):From("flight_master"):Where("name", "=", "A"):Run())
    end)

    it("node_id is unique (one row per physical flight point)", function()
        local db = built()
        db:Insert("flight_master", { node_id = 5, faction = "Alliance", name = "A", zone = "Z" })
        assert.is_false(pcall(function()
            db:Insert("flight_master", { node_id = 5, faction = "Horde", name = "B", zone = "Z" })
        end))
    end)

    it("a node seen by both factions becomes Neutral and is usable by either", function()
        local db = built()
        db:Insert("flight_master", { node_id = 50, faction = "Alliance", name = "Booty Bay", zone = "Z" })
        -- discovery rule: the rival faction rediscovers the same node_id -> flip to Neutral
        local r = db:Select("id", "faction"):From("flight_master"):Where("node_id", "=", 50):Run()[1]
        if r.faction ~= "Horde" and r.faction ~= "Neutral" then
            db:Update("flight_master", { faction = "Neutral" }, function(x) return x.id == r.id end)
        end
        assert.are.equal("Neutral", db:Select("faction"):From("flight_master"):Where("node_id", "=", 50):Run()[1].faction)
        assert.is_true(masterId(db, "Horde", "Booty Bay") ~= nil)
        assert.is_true(masterId(db, "Alliance", "Booty Bay") ~= nil)
    end)

    it("storeIfNew only fills an empty direction; DIRECT then replaces a FLY entry", function()
        local db = built()
        assert.is_true(storeIfNew(db, "Horde", "A", "B", 52))
        assert.is_false(storeIfNew(db, "Horde", "A", "B", 99))
        assert.is_true(store(db, "Horde", "A", "B", 50))
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

    it("enforces master/faction/zone foreign keys", function()
        local db = built()
        assert.is_false(pcall(function() db:Insert("flight_route", { src = 999, dst = 1000, t = 1, quality = DIRECT }) end))
        assert.is_false(pcall(function() db:Insert("flight_master", { node_id = 9, faction = "Pandaren", name = "X", zone = "Z" }) end))
        assert.is_false(pcall(function() db:Insert("flight_master", { node_id = 9, faction = "Horde", name = "X", zone = "Nowhere" }) end))
    end)

    it("derives a faction's records by joining flight_route.src to its master", function()
        local db = built()
        store(db, "Horde", "A", "D", 300, { "B", "C" })
        store(db, "Alliance", "X", "Y", 10)
        local rows = db:Select("flight_route.id", "flight_route.src", "flight_route.dst")
            :From("flight_route")
            :InnerJoin("flight_master", { on = { "flight_route.src", "flight_master.id" } })
            :Where("flight_master.faction", "in", { "Horde", "Neutral" }):Run()
        assert.are.equal(1, #rows)
        local seq = { db:Select("name"):From("flight_master"):Where("id", "=", rows[1].src):Run()[1].name }
        for _, n in ipairs(hopNames(db, rows[1].id)) do seq[#seq + 1] = n end
        seq[#seq + 1] = db:Select("name"):From("flight_master"):Where("id", "=", rows[1].dst):Run()[1].name
        assert.are.equal(4, #seq)
        assert.are.equal("A", seq[1]); assert.are.equal("D", seq[4])
    end)
end)
