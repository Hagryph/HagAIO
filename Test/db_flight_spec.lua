local S = dofile("Test/support.lua")

-- Proves the Flight model against the engine. flight_master is keyed by node_id (its PK, the
-- canonical C_TaxiMap nodeID -- one row per physical flight point). flight_route references two
-- masters by node id (src, dst, ON DELETE CASCADE) and carries no faction; flight_hop references an
-- intermediate master (ON DELETE CASCADE). Mirrors LocalTables discovery (creates masters by
-- node_id; flips a node seen by both factions to Neutral) and Misc recording (looks masters up).

local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor", "CoreTables", "DatabaseManager" }

local DIRECT, FLY = 2, 1

local FLIGHT_TABLES = {
    flight_route = {
        scope = "global",
        columns = {
            { name = "id",  type = "integer", primaryKey = true, autoIncrement = true },
            { name = "src", type = "integer", nullable = false, references = { table = "flight_master", onDelete = "cascade" } },
            { name = "dst", type = "integer", nullable = false, references = { table = "flight_master", onDelete = "cascade" } },
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
            { name = "master",   type = "integer", nullable = false, references = { table = "flight_master", onDelete = "cascade" } },
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
    db:Insert("zone", { name = "Z" })                   -- a zone for masters (flight_master.zone NOT NULL)
    return db
end

-- discovery: create a master under `faction` with a fresh node_id (its PK) + zone; returns node_id
local function seed(db, faction, name)
    nextNode = nextNode + 1
    db:Insert("flight_master", { node_id = nextNode, faction = faction, name = name, zone = "Z" })
    return nextNode
end
-- recording: look a master's node id up by name, valid for the player (their faction or Neutral)
local function masterId(db, faction, name)
    local r = db:Select("node_id"):From("flight_master")
        :Where("name", "=", name):AndWhere("faction", "in", { faction, "Neutral" }):Limit(1):Run()
    return r[1] and r[1].node_id or nil
end
local function idOrSeed(db, faction, name) return masterId(db, faction, name) or seed(db, faction, name) end

local function route(db, sid, did)
    return db:Select("id", "t", "quality"):From("flight_route"):Where("src", "=", sid):AndWhere("dst", "=", did):Limit(1):Run()[1]
end
local function setHops(db, faction, rid, via)
    db:Delete("flight_hop", function(h) return h.route_id == rid end)
    if via then for i, n in ipairs(via) do db:Insert("flight_hop", { route_id = rid, ordinal = i, master = idOrSeed(db, faction, n) }) end end
end
local function store(db, faction, a, b, secs, via)
    local sid, did = idOrSeed(db, faction, a), idOrSeed(db, faction, b)
    local x = route(db, sid, did)
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
    if route(db, sid, did) then return false end
    db:Insert("flight_route", { src = sid, dst = did, t = secs, quality = FLY }); return true
end
local function nameOf(db, nodeId) return db:Select("name"):From("flight_master"):Where("node_id", "=", nodeId):Run()[1].name end
local function hopNames(db, rid)
    local r = db:Select("master"):From("flight_hop"):Where("route_id", "=", rid):OrderBy("ordinal", "asc"):Run()
    local out = {}
    for i, x in ipairs(r) do out[i] = nameOf(db, x.master) end
    return out
end

describe("Flight DB model (flight_master keyed by node_id)", function()
    it("records a DIRECT leg, storing intermediates as flight_master refs", function()
        local db = built()
        store(db, "Horde", "A", "C", 120, { "B" })
        local r = route(db, masterId(db, "Horde", "A"), masterId(db, "Horde", "C"))
        assert.are.equal(DIRECT, r.quality); assert.are.equal(120, r.t)
        local v = hopNames(db, r.id)
        assert.are.equal(1, #v); assert.are.equal("B", v[1])
    end)

    it("reuses a master across routes (one row per node)", function()
        local db = built()
        store(db, "Horde", "A", "B", 50)
        store(db, "Horde", "A", "C", 60)
        assert.are.equal(1, #db:Select("node_id"):From("flight_master"):Where("name", "=", "A"):Run())
    end)

    it("rejects a duplicate node_id (PRIMARY KEY) insert", function()
        local db = built()
        db:Insert("flight_master", { node_id = 5, faction = "Alliance", name = "A", zone = "Z" })
        local ok, err = pcall(function()
            db:Insert("flight_master", { node_id = 5, faction = "Horde", name = "B", zone = "Z" })
        end)
        assert.is_false(ok)
        assert.is_true(tostring(err):find("PRIMARY KEY") ~= nil)
    end)

    it("a node seen by both factions becomes Neutral and is usable by either", function()
        local db = built()
        db:Insert("flight_master", { node_id = 50, faction = "Alliance", name = "Booty Bay", zone = "Z" })
        local r = db:Select("faction"):From("flight_master"):Where("node_id", "=", 50):Run()[1]
        if r.faction ~= "Horde" and r.faction ~= "Neutral" then
            db:Update("flight_master", { faction = "Neutral" }, function(x) return x.node_id == 50 end)
        end
        assert.are.equal("Neutral", db:Select("faction"):From("flight_master"):Where("node_id", "=", 50):Run()[1].faction)
        assert.is_true(masterId(db, "Horde", "Booty Bay") ~= nil)
        assert.is_true(masterId(db, "Alliance", "Booty Bay") ~= nil)
    end)

    it("DIRECT-over-DIRECT only updates on a >= 5s change; FLY is replaced by DIRECT", function()
        local db = built()
        assert.is_true(storeIfNew(db, "Horde", "A", "B", 52))
        assert.is_true(store(db, "Horde", "A", "B", 50))           -- DIRECT replaces FLY
        local sid, did = masterId(db, "Horde", "A"), masterId(db, "Horde", "B")
        assert.are.equal(DIRECT, route(db, sid, did).quality)
        assert.is_false(store(db, "Horde", "A", "B", 53))          -- +3s ignored
        assert.are.equal(50, route(db, sid, did).t)
        assert.is_true(store(db, "Horde", "A", "B", 58))           -- +8s applied
        assert.are.equal(58, route(db, sid, did).t)
    end)

    it("deleting a master CASCADES its routes (src/dst) and their hops", function()
        local db = built()
        store(db, "Horde", "A", "C", 120, { "B" })
        store(db, "Horde", "C", "A", 118)
        assert.are.equal(2, db:Store():Count("flight_route"))
        local aId = masterId(db, "Horde", "A")
        db:Delete("flight_master", function(m) return m.node_id == aId end)   -- A is an endpoint of both
        assert.are.equal(0, db:Store():Count("flight_route"))
        assert.are.equal(0, db:Store():Count("flight_hop"))
    end)

    it("enforces master/faction/zone foreign keys", function()
        local db = built()
        assert.is_false(pcall(function() db:Insert("flight_route", { src = 999, dst = 1000, t = 1, quality = DIRECT }) end))
        assert.is_false(pcall(function() db:Insert("flight_master", { node_id = 9, faction = "Pandaren", name = "X", zone = "Z" }) end))
        assert.is_false(pcall(function() db:Insert("flight_master", { node_id = 9, faction = "Horde", name = "X", zone = "Nowhere" }) end))
    end)

    it("a faction's records require EVERY stop (src, hops, dst) to be that faction or Neutral", function()
        local db = built()
        store(db, "Horde", "A", "D", 300, { "B", "C" })    -- fully Horde: usable
        store(db, "Alliance", "X", "Y", 10)                 -- fully Alliance: dropped for Horde
        -- Mirrors Misc:_FlightRecords: one master map, then validate every stop of each route --
        -- a record with ANY off-faction (or unknown) stop is dropped whole.
        local function records(faction)
            local master = {}
            for _, m in ipairs(db:Select("node_id", "name", "faction"):From("flight_master"):Run()) do
                master[m.node_id] = { name = m.name, usable = (m.faction == faction or m.faction == "Neutral") }
            end
            local function stop(id) local m = master[id]; if m and m.usable then return m.name end end
            local out = {}
            for _, row in ipairs(db:Select("id", "src", "dst"):From("flight_route"):Run()) do
                local seq, ok = { stop(row.src) }, nil
                ok = seq[1] ~= nil
                if ok then
                    for _, h in ipairs(db:Select("master"):From("flight_hop")
                            :Where("route_id", "=", row.id):OrderBy("ordinal", "asc"):Run()) do
                        local n = stop(h.master)
                        if not n then ok = false; break end
                        seq[#seq + 1] = n
                    end
                end
                if ok then seq[#seq + 1] = stop(row.dst); ok = seq[#seq] ~= nil end
                if ok then out[#out + 1] = seq end
            end
            return out
        end
        local horde = records("Horde")
        assert.are.equal(1, #horde)
        assert.are.equal(4, #horde[1])
        assert.are.equal("A", horde[1][1]); assert.are.equal("D", horde[1][4])
        -- an off-faction HOP poisons the whole record: B flips to Alliance -> A->D is dropped
        db:Update("flight_master", { faction = "Alliance" }, function(m) return m.name == "B" end)
        assert.are.equal(0, #records("Horde"))
        -- ...but a NEUTRAL hop keeps the record flyable
        db:Update("flight_master", { faction = "Neutral" }, function(m) return m.name == "B" end)
        assert.are.equal(1, #records("Horde"))
    end)
end)
