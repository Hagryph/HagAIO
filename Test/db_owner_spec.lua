local S = dofile("Test/support.lua")

local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor", "DatabaseManager" }

local FOO = { tables = { t = { columns = {
    { name = "id", type = "integer", primaryKey = true, autoIncrement = true },
    { name = "v",  type = "integer" },
} } } }

-- a namespace with the DB engine + manager, and a controllable mock SavedVariables
local function setup(loaded)
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    local slots = {}
    ns.SavedVars = {
        _loaded = loaded ~= false,
        IsLoaded = function(self) return self._loaded end,
        DataSlot = function(_, name) slots[name] = slots[name] or {}; return slots[name] end,
    }
    local mgr = ns._captured["DatabaseManager"]
    mgr:OnInitialize()
    return ns, mgr
end

describe("DatabaseOwner mixin", function()
    it("a Service can declare a database and reach it via self:DB", function()
        local ns = setup(true)
        local Svc = ns.Class.new("SvcA", ns.Service)
        local s = Svc:New("SvcA", { databases = { Foo = { schema = FOO } } })
        s:_RegisterDatabases()
        local db = s:DB("Foo")
        assert.is_true(db ~= nil)
        db:Insert("t", { v = 5 })
        assert.are.equal(1, db:Store():Count("t"))
        assert.are.equal(db, ns.DB.Foo)        -- published at ns.DB.<name>
    end)

    it("auto-adds the DatabaseManager dependency when databases are declared", function()
        local ns = setup(true)
        local Svc = ns.Class.new("SvcB", ns.Service)
        local s = Svc:New("SvcB", { deps = { "EventBus" }, databases = { Foo = { schema = FOO } } })
        local deps = s:GetDeps()
        local found = false
        for _, d in ipairs(deps) do if d == "DatabaseManager" then found = true end end
        assert.is_true(found)
    end)

    it("does not touch the caller's deps table (AddDep returns a new list)", function()
        local ns = setup(true)
        local userDeps = { "EventBus" }
        local Svc = ns.Class.new("SvcC", ns.Service)
        Svc:New("SvcC", { deps = userDeps, databases = { Foo = { schema = FOO } } })
        assert.are.equal(1, #userDeps)         -- unchanged
    end)

    it("defers a declaration made before SavedVars load, then ResolvePending registers it", function()
        local ns, mgr = setup(false)           -- saved vars NOT loaded yet
        local Svc = ns.Class.new("SvcD", ns.Service)
        local s = Svc:New("SvcD", { databases = { Bar = { schema = FOO } } })
        s:_RegisterDatabases()
        assert.is_nil(s:DB("Bar"))             -- deferred
        ns.SavedVars._loaded = true
        mgr:ResolvePending()
        assert.is_true(s:DB("Bar") ~= nil)     -- now live
    end)

    it("OwnedDatabases lists what was declared", function()
        local ns = setup(true)
        local Svc = ns.Class.new("SvcE", ns.Service)
        local s = Svc:New("SvcE", { databases = { Foo = { schema = FOO }, Baz = { schema = FOO } } })
        local owned = s:OwnedDatabases()
        assert.are.equal(2, #owned)
        assert.are.equal("Baz", owned[1])      -- sorted
        assert.are.equal("Foo", owned[2])
    end)
end)
