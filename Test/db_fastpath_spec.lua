local S = dofile("Test/support.lua")

-- Locks the query-engine fast paths added for the frame-budgeted Worker: index-narrowed equality
-- scans, LIMIT enforcement during the scan, { col = value } map predicates on Update/Delete, the
-- per-table generation counter, and the chunked (MaybeYield) executor restarting cleanly when the
-- table mutates underneath a query that yielded mid-scan.

local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager", "Database",
                   "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan", "QueryBuilder", "QueryExecutor" }

local function newDbNs()
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    return ns
end

local function spec()
    return {
        tables = {
            routes = {
                columns = {
                    { name = "id",      type = "integer", primaryKey = true, autoIncrement = true },
                    { name = "faction", type = "text",    nullable = false },
                    { name = "t",       type = "number",  nullable = false },
                },
                indices = { { columns = { "faction" } } },
            },
        },
    }
end

local function seeded(ns)
    local db = ns.DB.Database:New("Flight", ns.DB.Schema.new("Flight", spec()), {})
    db:Insert("routes", { faction = "Horde",    t = 30 })   -- 1
    db:Insert("routes", { faction = "Horde",    t = 90 })   -- 2
    db:Insert("routes", { faction = "Alliance", t = 45 })   -- 3
    db:Insert("routes", { faction = "Horde",    t = 30 })   -- 4
    return db
end

describe("DB fast path: index-narrowed equality", function()
    it("equality on the PK returns the same rows as a scan", function()
        local db = seeded(newDbNs())
        local rows = db:Select("*"):From("routes"):Where("id", "=", 3):Run()
        assert.are.equal(1, #rows)
        assert.are.equal("Alliance", rows[1].faction)
    end)

    it("equality on a declared index column matches all bucket rows", function()
        local db = seeded(newDbNs())
        local rows = db:Select("id"):From("routes"):Where("faction", "=", "Horde"):Run()
        assert.are.equal(3, #rows)
    end)

    it("a second AND'ed condition still filters within the index bucket", function()
        local db = seeded(newDbNs())
        local rows = db:Select("id"):From("routes"):Where("faction", "=", "Horde"):AndWhere("t", "=", 30):Run()
        assert.are.equal(2, #rows)
    end)

    it("a top-level OR disables index narrowing without losing rows", function()
        local db = seeded(newDbNs())
        local rows = db:Select("id"):From("routes"):Where("faction", "=", "Alliance"):OrWhere("t", "=", 90):Run()
        assert.are.equal(2, #rows)   -- row 3 (Alliance) + row 2 (t=90): the OR side must not be dropped
    end)

    it("IndexableEqs lists top-level AND'ed leaves and refuses ORs", function()
        local ns = newDbNs()
        local w = ns.DB.WhereClause:New():Where("a", "=", 1):AndWhere("b", "<", 2):AndWhere("c", "=", "x")
        local eqs = w:IndexableEqs()
        assert.are.equal(2, #eqs)
        assert.are.equal("a", eqs[1].col)
        assert.are.equal("c", eqs[2].col)
        assert.is_nil(ns.DB.WhereClause:New():Where("a", "=", 1):OrWhere("b", "=", 2):IndexableEqs())
    end)
end)

describe("DB fast path: LIMIT enforcement", function()
    it("Limit caps the result during the scan", function()
        local db = seeded(newDbNs())
        local rows = db:Select("id"):From("routes"):Where("faction", "=", "Horde"):Limit(2):Run()
        assert.are.equal(2, #rows)
    end)

    it("Limit + Offset still slice correctly on the capped scan", function()
        local db = seeded(newDbNs())
        local rows = db:Select("id"):From("routes"):Limit(2):Offset(1):Run()
        assert.are.equal(2, #rows)
        assert.are.equal(2, rows[1].id)   -- storage order, rows 2 and 3
        assert.are.equal(3, rows[2].id)
    end)

    it("Limit with ORDER BY is applied AFTER the sort (no early exit)", function()
        local db = seeded(newDbNs())
        local rows = db:Select("id", "t"):From("routes"):OrderBy("t", "desc"):Limit(1):Run()
        assert.are.equal(90, rows[1].t)   -- the global max, not just the first stored row
    end)

    it("Limit rejects non-numbers (typo guard)", function()
        local db = seeded(newDbNs())
        assert.has_error(function() db:Select("id"):From("routes"):Limit("1") end)
    end)
end)

describe("DB map predicates: Update / Delete", function()
    it("Update with a { col = value } map hits only the matching rows", function()
        local db = seeded(newDbNs())
        assert.are.equal(1, db:Update("routes", { t = 99 }, { id = 3 }))
        assert.are.equal(99, db:Select("t"):From("routes"):Where("id", "=", 3):Run()[1].t)
        assert.are.equal(30, db:Select("t"):From("routes"):Where("id", "=", 1):Run()[1].t)
    end)

    it("a multi-column map ANDs its equalities (indexed column narrows, the rest filter)", function()
        local db = seeded(newDbNs())
        assert.are.equal(2, db:Update("routes", { t = 11 }, { faction = "Horde", t = 30 }))
        assert.are.equal(90, db:Select("t"):From("routes"):Where("id", "=", 2):Run()[1].t)
    end)

    it("Delete with a map removes exactly the bucket's matches", function()
        local db = seeded(newDbNs())
        assert.are.equal(3, db:Delete("routes", { faction = "Horde" }))
        assert.are.equal(1, #db:Select("*"):From("routes"):Run())
    end)

    it("function predicates keep working unchanged", function()
        local db = seeded(newDbNs())
        assert.are.equal(2, db:Update("routes", { t = 1 }, function(r) return r.t == 30 end))
    end)
end)

describe("DB generation counter", function()
    it("bumps on insert / update / delete, and not on reads", function()
        local db = seeded(newDbNs())
        local store = db:Store()
        local g0 = store:Generation("routes")
        db:Select("*"):From("routes"):Run()
        assert.are.equal(g0, store:Generation("routes"))
        db:Insert("routes", { faction = "Horde", t = 5 })
        local g1 = store:Generation("routes")
        assert(g1 > g0, "insert must bump the generation")
        db:Update("routes", { t = 6 }, { t = 5 })
        local g2 = store:Generation("routes")
        assert(g2 > g1, "update must bump the generation")
        db:Delete("routes", { t = 6 })
        assert(store:Generation("routes") > g2, "delete must bump the generation")
    end)
end)

-- End-to-end: a query running INSIDE a Worker job yields at a chunk boundary (the budget is forced
-- to be always spent), another job mutates the table while the query is suspended, and the scan
-- detects the generation change and RESTARTS -- finishing with a consistent, duplicate-free result.
describe("DB chunked execution under the Worker", function()
    it("a mid-scan mutation restarts the scan instead of corrupting it", function()
        S.stubFrames()
        local ns = S.newNs()
        local clock = S.newClock()
        _G.C_Timer = clock.C_Timer
        _G.GetTime = clock.GetTime
        S.load(ns, "Services/EventBus.lua")
        S.load(ns, "Services/Scheduler.lua")
        S.load(ns, "Services/Worker.lua")
        for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
        ns._captured["EventBus"]:OnInitialize()
        local worker = ns._captured["Worker"]; worker:OnInitialize()
        local ms = 0
        _G.debugprofilestop = function() ms = ms + 2; return ms end   -- every clock read advances past the
                                                                      -- 2ms budget: a chunk point ALWAYS yields
        local db = ns.DB.Database:New("Flight", ns.DB.Schema.new("Flight", spec()), {})
        for i = 1, 100 do db:Insert("routes", { faction = "Horde", t = i }) end

        local result
        worker:Queue(function()
            result = db:Select("id"):From("routes"):Run()   -- 100 rows: offers a yield at row 64
        end, { label = "big select" })
        worker:_Pump()                                       -- job 1 starts, yields mid-scan
        assert.is_nil(result)                                -- suspended, not finished
        worker:Queue(function() db:Insert("routes", { faction = "Horde", t = 999 }) end, { label = "mutate" })
        for _ = 1, 20 do worker:_Pump() end                  -- mutation lands; the select restarts + finishes

        assert(result ~= nil, "chunked select never completed")
        assert.are.equal(101, #result)                       -- restarted scan sees a consistent table
        local seen = {}
        for _, r in ipairs(result) do
            assert.is_nil(seen[r.id])                        -- no duplicated rows from the aborted pass
            seen[r.id] = true
        end
    end)
end)
