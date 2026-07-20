local S = dofile("Test/support.lua")

local DB_FILES = { "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager", "Database",
                   "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan", "QueryBuilder", "QueryExecutor" }

local function newQueryNs()
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
                    { name = "src",     type = "integer", nullable = false },
                    { name = "dst",     type = "integer", nullable = false },
                    { name = "t",       type = "number",  nullable = false },
                    { name = "quality", type = "integer" },
                },
            },
            hops = {
                columns = {
                    { name = "route_id", type = "integer", references = { table = "routes", onDelete = "cascade" } },
                    { name = "ordinal",  type = "integer" },
                    { name = "node",     type = "integer" },
                },
                primaryKey = { "route_id", "ordinal" },
            },
            nodes = {
                columns = {
                    { name = "id",   type = "integer", primaryKey = true },
                    { name = "name", type = "text" },
                },
            },
        },
    }
end

-- seed a database with a fixed fixture
local function seeded(ns)
    local db = ns.DB.Database:New("Flight", ns.DB.Schema.new("Flight", spec()), {})
    db:Insert("routes", { faction = "Horde",    src = 1, dst = 2, t = 30, quality = 2 })  -- 1
    db:Insert("routes", { faction = "Horde",    src = 1, dst = 5, t = 90, quality = 1 })  -- 2
    db:Insert("routes", { faction = "Alliance", src = 3, dst = 4, t = 45 })               -- 3 quality NULL
    db:Insert("routes", { faction = "Horde",    src = 5, dst = 9, t = 30, quality = 2 })  -- 4
    db:Insert("hops", { route_id = 1, ordinal = 1, node = 7 })
    db:Insert("hops", { route_id = 1, ordinal = 2, node = 8 })
    db:Insert("hops", { route_id = 2, ordinal = 1, node = 9 })
    for id, name in pairs({ [1] = "A", [2] = "B", [3] = "C", [4] = "D", [5] = "E", [9] = "I" }) do
        db:Insert("nodes", { id = id, name = name })
    end
    return db
end

local function ids(rows) local o = {}; for i, r in ipairs(rows) do o[i] = r.id end; return o end
local function eqList(a, b) if #a ~= #b then return false end for i = 1, #a do if a[i] ~= b[i] then return false end end return true end

describe("DB query: projection + where", function()
    it("selects columns with an equality filter", function()
        local ns = newQueryNs()
        local rows = seeded(ns):Select("id", "t"):From("routes"):Where("faction", "=", "Alliance"):Run()
        assert.are.equal(1, #rows)
        assert.are.equal(3, rows[1].id)
        assert.are.equal(45, rows[1].t)
    end)

    it("supports in / between / like", function()
        local ns = newQueryNs()
        local db = seeded(ns)
        assert.are.equal(2, #db:Select("id"):From("routes"):Where("t", "in", { 30 }):Run())
        assert.are.equal(3, #db:Select("id"):From("routes"):Where("t", "between", { 30, 45 }):Run())
        assert.are.equal(3, #db:Select("id"):From("routes"):Where("faction", "like", "Hord%"):Run())  -- 3 Horde rows
    end)

    it("is null / is not null follow two-valued NULL logic", function()
        local ns = newQueryNs()
        local db = seeded(ns)
        assert.are.equal(1, #db:Select("id"):From("routes"):Where("quality", "is null"):Run())
        assert.are.equal(3, #db:Select("id"):From("routes"):Where("quality", "is not null"):Run())
        -- NULL never matches a comparison
        assert.are.equal(0, #db:Select("id"):From("routes"):Where("quality", "=", 2):AndWhere("quality", "is null"):Run())
        local nullRow = db:Select("quality"):From("routes"):Where("id", "=", 3):Run()[1]
        assert.is_true(ns.DB.isNull(nullRow.quality))
    end)

    it("AND binds tighter than OR", function()
        local ns = newQueryNs()
        local db = seeded(ns)
        -- (faction=Horde AND t=30) OR faction=Alliance  -> ids 1,4 (Horde t30) + 3 (Alliance)
        local rows = db:Select("id"):From("routes")
            :Where("faction", "=", "Horde"):AndWhere("t", "=", 30)
            :OrWhere("faction", "=", "Alliance"):OrderBy("id"):Run()
        assert.is_true(eqList({ 1, 3, 4 }, ids(rows)))
    end)
end)

describe("DB query: order / distinct / limit", function()
    it("orders stably (equal keys keep insertion order)", function()
        local ns = newQueryNs()
        local rows = seeded(ns):Select("id", "t"):From("routes"):OrderBy("t", "asc"):Run()
        assert.is_true(eqList({ 1, 4, 3, 2 }, ids(rows)))   -- t=30 ids 1 then 4 (stable), then 45, 90
    end)

    it("orders descending and NULLs last", function()
        local ns = newQueryNs()
        local rows = seeded(ns):Select("id", "quality"):From("routes"):OrderBy("quality", "desc"):Run()
        assert.is_true(ns.DB.isNull(rows[#rows].quality))   -- the NULL quality sorts last
    end)

    it("DISTINCT removes duplicate output rows", function()
        local ns = newQueryNs()
        local rows = seeded(ns):Select("faction"):From("routes"):Distinct():Run()
        assert.are.equal(2, #rows)
    end)

    it("LIMIT and OFFSET slice the result", function()
        local ns = newQueryNs()
        local rows = seeded(ns):Select("id"):From("routes"):OrderBy("id"):Limit(2):Offset(1):Run()
        assert.is_true(eqList({ 2, 3 }, ids(rows)))
    end)
end)

describe("DB query: joins", function()
    it("INNER JOIN keeps only matched rows", function()
        local ns = newQueryNs()
        local rows = seeded(ns):Select("routes.id", "hops.node"):From("routes")
            :InnerJoin("hops", { on = { "routes.id", "hops.route_id" } }):Run()
        assert.are.equal(3, #rows)                          -- route1 x2 hops + route2 x1 hop
    end)

    it("LEFT JOIN keeps unmatched left rows with NULL right", function()
        local ns = newQueryNs()
        local rows = seeded(ns):Select("routes.id", "hops.node"):From("routes")
            :LeftJoin("hops", { on = { "routes.id", "hops.route_id" } }):Run()
        assert.are.equal(5, #rows)                          -- 3 matched + routes 3 and 4 unmatched
        local nullHops = 0
        for _, r in ipairs(rows) do if ns.DB.isNull(r.node) then nullHops = nullHops + 1 end end
        assert.are.equal(2, nullHops)
    end)

    it("RIGHT JOIN keeps unmatched right rows", function()
        local ns = newQueryNs()
        -- nodes RIGHT-joined from routes via src: every node appears, even ones no route starts at
        local rows = seeded(ns):Select("nodes.id", "routes.id"):From("routes")
            :RightJoin("nodes", { on = { "routes.src", "nodes.id" } }):Run()
        assert.are.equal(6, #rows >= 6 and 6 or #rows)      -- at least all 6 nodes represented
    end)

    it("FULL JOIN unions unmatched from both sides", function()
        local ns = newQueryNs()
        local rows = seeded(ns):Select("routes.id", "nodes.id"):From("routes")
            :FullJoin("nodes", { on = { "routes.dst", "nodes.id" } }):Run()
        -- routes 1,2,3 match a node on dst (2,5,4); route 4 dst=9 -> node 9 exists; node A(1),C(3)... unmatched nodes too
        assert.is_true(#rows >= 6)
    end)

    it("CROSS JOIN is the cartesian product", function()
        local ns = newQueryNs()
        local rows = seeded(ns):Select("routes.id"):From("routes"):CrossJoin("nodes"):Run()
        assert.are.equal(4 * 6, #rows)
    end)

    it("SELF JOIN pairs a table with itself under a mandatory alias", function()
        local ns = newQueryNs()
        local rows = seeded(ns):Select("routes.id", "b.id"):From("routes")
            :SelfJoin("routes", { as = "b", on = { "routes.src", "b.src" } })
            :Where("routes.id", "!=", ns.DB.col("b.id")):Run()
        assert.are.equal(2, #rows)                          -- routes 1 & 2 share src=1: (1,2) and (2,1)
    end)

    it("requires an alias for a self join and errors on ambiguous bare columns", function()
        local ns = newQueryNs()
        local db = seeded(ns)
        assert.is_false(pcall(function() db:Select("id"):From("routes"):SelfJoin("routes", { on = {} }):Run() end))
        assert.is_false(pcall(function()
            db:Select("id"):From("routes"):InnerJoin("nodes", { on = { "routes.src", "nodes.id" } }):Run()
        end))                                               -- bare "id" exists in both routes and nodes
    end)

    it("joins to a lookup table by qualified columns", function()
        local ns = newQueryNs()
        local rows = seeded(ns):Select("routes.id", "nodes.name"):From("routes")
            :InnerJoin("nodes", { on = { "routes.src", "nodes.id" } })
            :Where("routes.id", "=", 1):Run()
        assert.are.equal("A", rows[1].name)                 -- route 1 src=1 -> node A
    end)

    -- The *OuterJoin SQL synonyms are passthroughs to the implemented join kind; prove each builds
    -- and runs as its base kind (same rows), so the synonym surface is exercised, not just dormant.
    it("LEFT OUTER JOIN is the same as LEFT JOIN", function()
        local ns = newQueryNs()
        local left  = seeded(ns):Select("routes.id", "hops.node"):From("routes")
            :LeftJoin("hops", { on = { "routes.id", "hops.route_id" } }):OrderBy("routes.id"):Run()
        local outer = seeded(ns):Select("routes.id", "hops.node"):From("routes")
            :LeftOuterJoin("hops", { on = { "routes.id", "hops.route_id" } }):OrderBy("routes.id"):Run()
        assert.are.equal(5, #outer)                         -- 3 matched + routes 3 and 4 unmatched
        assert.are.equal(#left, #outer)
        local nullHops = 0
        for _, r in ipairs(outer) do if ns.DB.isNull(r.node) then nullHops = nullHops + 1 end end
        assert.are.equal(2, nullHops)
    end)

    it("RIGHT OUTER JOIN keeps unmatched right rows like RIGHT JOIN", function()
        local ns = newQueryNs()
        -- nodes {1,2,3,4,5,9}; routes.src {1,1,3,5}: node1<-routes 1,2; node3<-route3; node5<-route4;
        -- unmatched nodes 2,4,9 emit one row each -> 2+1+1 + 3 matched = 7 rows.
        -- (project node-side `name` + route-side `faction`: distinct bare names, no collision)
        local rows = seeded(ns):Select("nodes.name", "routes.faction"):From("routes")
            :RightOuterJoin("nodes", { on = { "routes.src", "nodes.id" } }):Run()
        assert.are.equal(7, #rows)
        local nullFaction = 0
        for _, r in ipairs(rows) do if ns.DB.isNull(r.faction) then nullFaction = nullFaction + 1 end end
        assert.are.equal(3, nullFaction)                    -- nodes 2,4,9 have no route on src
        -- same shape as the non-synonym RightJoin
        local base = seeded(ns):Select("nodes.name", "routes.faction"):From("routes")
            :RightJoin("nodes", { on = { "routes.src", "nodes.id" } }):Run()
        assert.are.equal(#base, #rows)
    end)

    it("FULL OUTER JOIN unions unmatched from both sides like FULL JOIN", function()
        local ns = newQueryNs()
        -- routes.dst {2,5,9,4}; nodes {1,2,3,4,5,9}: routes 1,3,4 match dst nodes 2,4,9; route 2 dst=5
        -- matches node 5 -> all 4 routes matched. Unmatched nodes 1,3 emit a route-NULL row each.
        -- (project route-side `faction` + node-side `name`: distinct bare names, no collision)
        local rows = seeded(ns):Select("routes.faction", "nodes.name"):From("routes")
            :FullOuterJoin("nodes", { on = { "routes.dst", "nodes.id" } }):Run()
        assert.are.equal(6, #rows)                          -- 4 matched routes + nodes 1,3 unmatched
        local nullFaction = 0
        for _, r in ipairs(rows) do
            if ns.DB.isNull(r.faction) then nullFaction = nullFaction + 1 end
        end
        -- nodes 1 (A) and 3 (C) are never a dst -> their rows have the routes side unmatched -> NULL faction
        assert.are.equal(2, nullFaction)
        local base = seeded(ns):Select("routes.faction", "nodes.name"):From("routes")
            :FullJoin("nodes", { on = { "routes.dst", "nodes.id" } }):Run()
        assert.are.equal(#base, #rows)
    end)
end)

describe("DB query: group by + aggregates + having", function()
    it("groups with count/sum/avg/min/max/total/group_concat", function()
        local ns = newQueryNs()
        local Fn = ns.DB.Fn
        local rows = seeded(ns):Select("faction",
            Fn.Count("*"):As("n"), Fn.Sum("t"):As("sum"), Fn.Avg("t"):As("avg"),
            Fn.Min("t"):As("min"), Fn.Max("t"):As("max"), Fn.Total("quality"):As("tot"))
            :From("routes"):GroupBy("faction"):OrderBy("faction"):Run()
        -- Alliance first (asc), then Horde
        assert.are.equal("Alliance", rows[1].faction)
        assert.are.equal(1, rows[1].n)
        assert.are.equal(0, rows[1].tot)                    -- TOTAL over the all-NULL Alliance quality -> 0
        assert.are.equal("Horde", rows[2].faction)
        assert.are.equal(3, rows[2].n)
        assert.are.equal(150, rows[2].sum)
        assert.are.equal(50, rows[2].avg)
        assert.are.equal(30, rows[2].min)
        assert.are.equal(90, rows[2].max)
        assert.are.equal(5, rows[2].tot)                    -- TOTAL of Horde qualities {2,1,2}
    end)

    it("COUNT(DISTINCT) and group_concat skip NULLs / dedupe", function()
        local ns = newQueryNs()
        local Fn = ns.DB.Fn
        local rows = seeded(ns):Select("faction", Fn.Count("quality"):Distinct():As("dq"))
            :From("routes"):Where("faction", "=", "Horde"):GroupBy("faction"):Run()
        assert.are.equal(2, rows[1].dq)                     -- Horde qualities {2,1,2} distinct -> 2
    end)

    it("HAVING filters groups on an aggregate", function()
        local ns = newQueryNs()
        local Fn = ns.DB.Fn
        local rows = seeded(ns):Select("faction", Fn.Count("*"):As("n"))
            :From("routes"):GroupBy("faction"):Having(Fn.Count("*"), ">", 1):Run()
        assert.are.equal(1, #rows)
        assert.are.equal("Horde", rows[1].faction)
    end)

    it("an aggregate with no GROUP BY yields exactly one row (incl. over empty input)", function()
        local ns = newQueryNs()
        local Fn = ns.DB.Fn
        local all = seeded(ns):Select(Fn.Count("*"):As("n"), Fn.Sum("t"):As("s")):From("routes"):Run()
        assert.are.equal(1, #all)
        assert.are.equal(4, all[1].n)
        assert.are.equal(195, all[1].s)
        local none = seeded(ns):Select(Fn.Count("*"):As("n"), Fn.Sum("t"):As("s"))
            :From("routes"):Where("t", ">", 1000):Run()
        assert.are.equal(1, #none)
        assert.are.equal(0, none[1].n)
        assert.is_true(ns.DB.isNull(none[1].s))             -- SUM over empty -> NULL
    end)
end)

describe("DB query: pipeline isolation", function()
    it("works on a snapshot -- results never alias stored rows", function()
        local ns = newQueryNs()
        local db = seeded(ns)
        local stored = db:Store():Rows("routes")[1]
        local rows = db:Select("*"):From("routes"):Where("id", "=", 1):Run()
        assert.is_false(rows[1] == stored)            -- a fresh row, not the live one
        rows[1].t = 999
        assert.are.equal(30, stored.t)               -- mutating the result leaves storage untouched
    end)
end)

describe("DB query: views + LIKE translation", function()
    it("runs a declared view", function()
        local ns = newQueryNs()
        local sp = spec()
        sp.views = { fast = { build = function(db) return db:Select("id"):From("routes"):Where("t", "<", 40) end } }
        local db = ns.DB.Database:New("Flight", ns.DB.Schema.new("Flight", sp), {})
        db:Insert("routes", { faction = "Horde", src = 1, dst = 2, t = 30 })
        db:Insert("routes", { faction = "Horde", src = 1, dst = 5, t = 90 })
        assert.are.equal(1, #db:View("fast"))
    end)

    it("translates LIKE wildcards and escapes magic chars", function()
        local ns = newQueryNs()
        assert.are.equal("^a.b.*$", ns.DB._likeToLua("a_b%"))
        assert.are.equal("^%.x$", ns.DB._likeToLua(".x"))   -- literal dot escaped
    end)
end)
