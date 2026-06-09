local S = dofile("Test/support.lua")

local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor" }

local function newTrigNs()
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    return ns
end

-- build a db whose schema carries `triggers`
local function mk(ns, triggers)
    local schema = ns.DB.Schema.new("T", {
        tables = {
            items = {
                columns = {
                    { name = "id",   type = "integer", primaryKey = true, autoIncrement = true },
                    { name = "name", type = "text", nullable = false },
                    { name = "qty",  type = "integer", default = 0 },
                },
            },
            shadow = {
                columns = {
                    { name = "id",   type = "integer", primaryKey = true, autoIncrement = true },
                    { name = "name", type = "text" },
                },
            },
        },
        triggers = triggers,
    })
    return ns.DB.Database:New("T", schema, {})
end

describe("DB triggers", function()
    it("AFTER INSERT sees ctx.new", function()
        local ns = newTrigNs()
        local seen
        local db = mk(ns, { { table = "items", time = "after", event = "insert",
            action = function(ctx) seen = ctx.new.name end } })
        db:Insert("items", { name = "sword" })
        assert.are.equal("sword", seen)
    end)

    it("BEFORE INSERT can normalise ctx.new", function()
        local ns = newTrigNs()
        local db = mk(ns, { { table = "items", time = "before", event = "insert",
            action = function(ctx) ctx.new.qty = 99 end } })
        local r = db:Insert("items", { name = "x" })
        assert.are.equal(99, r.qty)
    end)

    it("BEFORE INSERT can veto by returning false", function()
        local ns = newTrigNs()
        local db = mk(ns, { { table = "items", time = "before", event = "insert",
            action = function(ctx) if ctx.new.name == "bad" then return false end end } })
        assert.is_nil(db:Insert("items", { name = "bad" }))
        assert.are.equal(0, db:Store():Count("items"))
        db:Insert("items", { name = "ok" })
        assert.are.equal(1, db:Store():Count("items"))
    end)

    it("RecheckTypes blocks a BEFORE trigger that writes a bad type", function()
        local ns = newTrigNs()
        local db = mk(ns, { { table = "items", time = "before", event = "insert",
            action = function(ctx) ctx.new.qty = "not a number" end } })
        assert.is_false(pcall(function() db:Insert("items", { name = "x" }) end))
    end)

    it("BEFORE UPDATE sees old and new", function()
        local ns = newTrigNs()
        local oldv, newv
        local db = mk(ns, { { table = "items", time = "before", event = "update",
            action = function(ctx) oldv, newv = ctx.old.qty, ctx.new.qty end } })
        local r = db:Insert("items", { name = "x", qty = 1 })
        db:Update("items", { qty = 5 }, function(row) return row.id == r.id end)
        assert.are.equal(1, oldv)
        assert.are.equal(5, newv)
    end)

    it("AFTER DELETE sees old", function()
        local ns = newTrigNs()
        local goneName
        local db = mk(ns, { { table = "items", time = "after", event = "delete",
            action = function(ctx) goneName = ctx.old.name end } })
        local r = db:Insert("items", { name = "doomed" })
        db:Delete("items", function(row) return row.id == r.id end)
        assert.are.equal("doomed", goneName)
    end)

    it("a WHEN predicate gates the action", function()
        local ns = newTrigNs()
        local fires = 0
        local db = mk(ns, { { table = "items", time = "after", event = "insert",
            when = function(ctx) return ctx.new.qty > 10 end,
            action = function() fires = fires + 1 end } })
        db:Insert("items", { name = "a", qty = 5 })
        db:Insert("items", { name = "b", qty = 20 })
        assert.are.equal(1, fires)
    end)

    it("INSTEAD OF INSERT replaces the base write", function()
        local ns = newTrigNs()
        local db = mk(ns, { { table = "items", time = "instead_of", event = "insert",
            action = function(ctx) ctx.db:Insert("shadow", { name = ctx.new.name }) end } })
        db:Insert("items", { name = "redirected" })
        assert.are.equal(0, db:Store():Count("items"))     -- base insert skipped
        assert.are.equal(1, db:Store():Count("shadow"))    -- trigger wrote here instead
    end)

    it("a re-entrancy guard stops a trigger recursing into its own event", function()
        local ns = newTrigNs()
        local db = mk(ns, { { table = "items", time = "after", event = "insert",
            action = function(ctx) ctx.db:Insert("items", { name = "child" }) end } })
        db:Insert("items", { name = "parent" })
        assert.are.equal(2, db:Store():Count("items"))     -- parent + one child, no infinite loop
    end)

    it("FOR EACH STATEMENT fires once per statement", function()
        local ns = newTrigNs()
        local stmtFires, rowFires = 0, 0
        local db = mk(ns, {
            { table = "items", time = "after", event = "update", level = "statement",
              action = function() stmtFires = stmtFires + 1 end },
            { table = "items", time = "after", event = "update", level = "row",
              action = function() rowFires = rowFires + 1 end },
        })
        db:Insert("items", { name = "a" }); db:Insert("items", { name = "b" }); db:Insert("items", { name = "c" })
        db:Update("items", { qty = 1 }, nil)
        assert.are.equal(1, stmtFires)                     -- once for the whole UPDATE
        assert.are.equal(3, rowFires)                      -- once per row
    end)
end)
