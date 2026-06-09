local S = dofile("Test/support.lua")

local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor", "CoreTables", "DatabaseManager" }

-- a manager backed by a mock SavedVariables library (separate plain tables per slot)
local function newManager()
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    local slots = {}
    ns.SavedVars = {
        IsLoaded = function() return true end,
        DataSlot = function(_, name) slots[name] = slots[name] or {}; return slots[name] end,
    }
    local mgr = ns._captured["DatabaseManager"]
    mgr:OnInitialize()
    return mgr, ns, slots
end

describe("DatabaseManager: one shared database", function()
    it("builds a single database from contributed tables + the central CoreTables", function()
        local mgr, ns = newManager()
        mgr:Contribute({ widget = { columns = { { name = "id", type = "integer", primaryKey = true } } } })
        local db = mgr:Build()
        assert.is_true(db ~= nil)
        assert.are.equal(db, mgr:Shared())
        assert.are.equal(db, ns.DB.shared)
        assert.is_true(mgr:HasTable("widget"))
        assert.is_true(mgr:HasTable("faction"))      -- predefined
    end)

    it("rejects a duplicate table name across owners", function()
        local mgr = newManager()
        mgr:Contribute({ thing = { columns = { { name = "id", type = "integer", primaryKey = true } } } })
        assert.is_false(pcall(function()
            mgr:Contribute({ thing = { columns = { { name = "id", type = "integer", primaryKey = true } } } })
        end))
    end)

    it("refuses contributions after the database is built", function()
        local mgr = newManager()
        mgr:Build()
        assert.is_false(pcall(function()
            mgr:Contribute({ late = { columns = { { name = "id", type = "integer", primaryKey = true } } } })
        end))
    end)

    it("seeds the LOCAL faction reference table", function()
        local mgr = newManager()
        local db = mgr:Build()
        local rows = db:Select("id", "tag"):From("faction"):OrderBy("id"):Run()
        assert.are.equal(3, #rows)
        assert.are.equal("Alliance", rows[1].tag)
        assert.are.equal("Horde", rows[2].tag)
        assert.are.equal("Neutral", rows[3].tag)
    end)
end)

describe("DatabaseManager: per-table scope routing", function()
    local function scopedDb()
        local mgr, ns, slots = newManager()
        mgr:Contribute({
            mem  = { scope = "local",  columns = { { name = "id", type = "integer", primaryKey = true }, { name = "v", type = "integer" } } },
            acct = { scope = "global", columns = { { name = "id", type = "integer", primaryKey = true, autoIncrement = true } } },
            mine = { scope = "char",   columns = { { name = "id", type = "integer", primaryKey = true, autoIncrement = true } } },
        })
        return mgr:Build(), slots
    end

    it("writes each table into the backing for its scope", function()
        local db, slots = scopedDb()
        db:Insert("mem",  { id = 1, v = 9 })
        db:Insert("acct", {})
        db:Insert("mine", {})
        assert.is_true(slots.db_global.tables.acct ~= nil and #slots.db_global.tables.acct == 1)
        assert.is_true(slots.db_char.tables.mine ~= nil and #slots.db_char.tables.mine == 1)
        -- the LOCAL table is in-memory only: it never appears in a persisted slot
        assert.is_nil(slots.db_global.tables.mem)
        assert.is_nil(slots.db_char.tables.mem)
    end)

    it("a LOCAL table is rebuilt empty each session (not persisted)", function()
        local db, slots = scopedDb()
        db:Insert("mem", { id = 1, v = 9 })
        assert.are.equal(1, db:Store():Count("mem"))
        -- nothing about `mem` is in either persisted slot
        for _, s in pairs({ slots.db_global, slots.db_char }) do
            assert.is_nil(s.tables.mem)
        end
    end)

    it("a GLOBAL table can FK-join a LOCAL reference table (flight_master -> faction)", function()
        local mgr = newManager()
        local db = mgr:Build()
        db:Insert("zone", { id = 1, name = "Durotar" })
        db:Insert("flight_master", { faction = "Horde", name = "Orgrimmar", zone = "Durotar" })
        -- inserting with an unknown faction tag violates the cross-scope FK
        assert.is_false(pcall(function()
            db:Insert("flight_master", { faction = "Pandaren", name = "Y", zone = "Durotar" })
        end))
        local joined = db:Select("flight_master.name", "faction.id"):From("flight_master")
            :InnerJoin("faction", { on = { "flight_master.faction", "faction.tag" } }):Run()
        assert.are.equal("Orgrimmar", joined[1].name)   -- the flight node
        assert.are.equal(2, joined[1].id)               -- joined Horde faction id
    end)
end)
