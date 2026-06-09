local S = dofile("Test/support.lua")

local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor", "DatabaseManager" }

-- a manager backed by a mock SavedVariables library (plain tables for slots)
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

local accountsSpec = { tables = { users = { columns = {
    { name = "id", type = "integer", primaryKey = true, autoIncrement = true },
    { name = "name", type = "text", nullable = false },
} } } }

local function postsSpec(onDelete)
    return { tables = { posts = { columns = {
        { name = "id", type = "integer", primaryKey = true, autoIncrement = true },
        { name = "user_id", type = "integer", nullable = (onDelete == "set_null"),
          references = { db = "Accounts", table = "users", column = "id", onDelete = onDelete } },
        { name = "title", type = "text" },
    } } } }
end

describe("DatabaseManager", function()
    it("registers, publishes at ns.DB.<name>, and lists databases", function()
        local mgr, ns = newManager()
        local acc = mgr:Register("Accounts", ns.DB.Schema.new("Accounts", accountsSpec))
        assert.is_true(mgr:Has("Accounts"))
        assert.are.equal(acc, ns.DB.Accounts)
        assert.are.equal(acc, mgr:Get("Accounts"))
    end)

    it("enforces a cross-database foreign key on insert", function()
        local mgr, ns = newManager()
        mgr:Register("Accounts", ns.DB.Schema.new("Accounts", accountsSpec))
        mgr:Register("Posts", ns.DB.Schema.new("Posts", postsSpec("cascade")))
        ns.DB.Accounts:Insert("users", { name = "Ann" })          -- id 1
        assert.is_false(pcall(function() ns.DB.Posts:Insert("posts", { user_id = 99, title = "x" }) end))
        local p = ns.DB.Posts:Insert("posts", { user_id = 1, title = "hello" })
        assert.are.equal(1, p.user_id)
    end)

    it("cascades a delete ACROSS databases", function()
        local mgr, ns = newManager()
        mgr:Register("Accounts", ns.DB.Schema.new("Accounts", accountsSpec))
        mgr:Register("Posts", ns.DB.Schema.new("Posts", postsSpec("cascade")))
        ns.DB.Accounts:Insert("users", { name = "Ann" })
        ns.DB.Posts:Insert("posts", { user_id = 1, title = "a" })
        ns.DB.Posts:Insert("posts", { user_id = 1, title = "b" })
        assert.are.equal(2, ns.DB.Posts:Store():Count("posts"))
        ns.DB.Accounts:Delete("users", function(u) return u.id == 1 end)
        assert.are.equal(0, ns.DB.Posts:Store():Count("posts"))   -- cross-DB cascade
    end)

    it("SET NULL across databases nulls the child FK", function()
        local mgr, ns = newManager()
        mgr:Register("Accounts", ns.DB.Schema.new("Accounts", accountsSpec))
        mgr:Register("Posts", ns.DB.Schema.new("Posts", postsSpec("set_null")))
        ns.DB.Accounts:Insert("users", { name = "Ann" })
        ns.DB.Posts:Insert("posts", { user_id = 1, title = "a" })
        ns.DB.Accounts:Delete("users", function(u) return u.id == 1 end)
        assert.are.equal(1, ns.DB.Posts:Store():Count("posts"))
        assert.is_nil(rawget(ns.DB.Posts:Store():Rows("posts")[1], "user_id"))
    end)

    it("resolves cross-DB links regardless of registration order", function()
        local mgr, ns = newManager()
        -- register the child (Posts) BEFORE the parent (Accounts)
        mgr:Register("Posts", ns.DB.Schema.new("Posts", postsSpec("cascade")))
        mgr:Register("Accounts", ns.DB.Schema.new("Accounts", accountsSpec))
        ns.DB.Accounts:Insert("users", { name = "Ann" })
        ns.DB.Posts:Insert("posts", { user_id = 1, title = "ok" })
        ns.DB.Accounts:Delete("users", function(u) return u.id == 1 end)
        assert.are.equal(0, ns.DB.Posts:Store():Count("posts"))
    end)

    it("runs a database's own version migrations on an older slot", function()
        local mgr, ns, slots = newManager()
        -- pre-seed a legacy slot at schema v1
        slots["db_Legacy"] = { _schema = 1, _meta = { autoIds = { t = 1 } },
                               tables = { t = { { id = 1, name = "old" } } } }
        local schema = ns.DB.Schema.new("Legacy", {
            version = 2,
            migrations = { [2] = function(db)
                for _, r in ipairs(db:Store():Rows("t")) do r.tag = "migrated" end
            end },
            tables = { t = { columns = {
                { name = "id",   type = "integer", primaryKey = true, autoIncrement = true },
                { name = "name", type = "text" },
                { name = "tag",  type = "text" },          -- added in v2
            } } },
        })
        local db = mgr:Register("Legacy", schema)
        assert.are.equal(2, db:Store():Version())
        assert.are.equal("migrated", db:Store():Rows("t")[1].tag)
    end)

    it("stamps a fresh database at the current version without migrating", function()
        local mgr, ns = newManager()
        local ran = false
        local schema = ns.DB.Schema.new("Fresh", {
            version = 3,
            migrations = { [2] = function() ran = true end, [3] = function() ran = true end },
            tables = { t = { columns = { { name = "id", type = "integer", primaryKey = true } } } },
        })
        local db = mgr:Register("Fresh", schema)
        assert.are.equal(3, db:Store():Version())
        assert.is_false(ran)
    end)
end)
