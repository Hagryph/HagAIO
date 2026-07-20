local S = dofile("Test/support.lua")

local DB_FILES = { "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor", "CoreTables", "DatabaseManager" }

local FOO = { columns = {
    { name = "id", type = "integer", primaryKey = true, autoIncrement = true },
    { name = "v",  type = "integer" },
} }

local function setup()
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    local slots = {}
    ns.SavedVars = {
        IsLoaded = function() return true end,
        DataSlot = function(_, name) slots[name] = slots[name] or {}; return slots[name] end,
    }
    local mgr = ns._captured["DatabaseManager"]
    mgr:OnInitialize()
    return ns, mgr
end

describe("DatabaseOwner mixin: table contribution", function()
    it("a Service contributes tables and reaches the shared DB via self:DB() after Build", function()
        local ns, mgr = setup()
        local Svc = ns.Class.new("SvcA", ns.Service)
        local s = Svc:New("SvcA", { tables = { foo = FOO } })
        s:_ContributeTables()
        assert.is_nil(s:DB())                  -- not built yet
        local db = mgr:Build()
        assert.are.equal(db, s:DB())
        s:DB():Insert("foo", { v = 5 })
        assert.are.equal(1, s:DB():Store():Count("foo"))
    end)

    it("auto-adds the DatabaseManager dependency when tables are declared", function()
        local ns = setup()
        local Svc = ns.Class.new("SvcB", ns.Service)
        local s = Svc:New("SvcB", { deps = { "EventBus" }, tables = { foo = FOO } })
        local found = false
        for _, d in ipairs(s:GetDeps()) do if d == "DatabaseManager" then found = true end end
        assert.is_true(found)
    end)

    it("does not touch the caller's deps table (AddDep returns a new list)", function()
        local ns = setup()
        local userDeps = { "EventBus" }
        local Svc = ns.Class.new("SvcC", ns.Service)
        Svc:New("SvcC", { deps = userDeps, tables = { foo = FOO } })
        assert.are.equal(1, #userDeps)
    end)

    it("OwnedTables lists the contributed table names", function()
        local ns = setup()
        local Svc = ns.Class.new("SvcD", ns.Service)
        local s = Svc:New("SvcD", { tables = { foo = FOO, bar = FOO } })
        local owned = s:OwnedTables()
        assert.are.equal(2, #owned)
        assert.are.equal("bar", owned[1])
        assert.are.equal("foo", owned[2])
    end)

    it("an owner overriding _CollectTables contributes the dynamic set; the latch stays in the base", function()
        local ns, mgr = setup()
        -- The Class module pattern: build the table set dynamically by overriding ONLY the hook,
        -- never re-copying the once-only latch (which now lives solely in the base _ContributeTables).
        local Dyn = ns.Class.new("Dyn", ns.Service)
        local calls = 0
        function Dyn:_CollectTables()
            calls = calls + 1
            return { gamma = FOO }   -- not from opts.tables / _DeclareTables -- computed here
        end
        local s = Dyn:New("Dyn")
        s:_ContributeTables()
        s:_ContributeTables()                    -- idempotent: the base latch blocks a second contribution
        assert.are.equal(1, calls)               -- the hook ran exactly once
        local db = mgr:Build()
        db:Insert("gamma", { v = 1 })
        assert.are.equal(1, db:Store():Count("gamma"))
    end)

    it("multiple owners contribute into the one shared schema", function()
        local ns, mgr = setup()
        local A = ns.Class.new("OwnA", ns.Service):New("OwnA", { tables = { alpha = FOO } })
        local B = ns.Class.new("OwnB", ns.Service):New("OwnB", { tables = { beta = FOO } })
        A:_ContributeTables(); B:_ContributeTables()
        local db = mgr:Build()
        db:Insert("alpha", { v = 1 }); db:Insert("beta", { v = 2 })
        assert.are.equal(1, db:Store():Count("alpha"))
        assert.are.equal(1, db:Store():Count("beta"))
    end)
end)
