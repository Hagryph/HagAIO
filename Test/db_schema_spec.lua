local S = dofile("Test/support.lua")

local function newSchemaNs()
    local ns = S.newNs()
    S.load(ns, "Core/DB/Types.lua")
    S.load(ns, "Core/DB/Schema.lua")
    return ns
end

-- A small valid two-table schema reused across cases.
local function flightSpec()
    return {
        version = 1,
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
                unique  = { { "faction", "src", "dst" } },
                indices = { { columns = { "faction" } } },
            },
            route_hops = {
                columns = {
                    { name = "route_id", type = "integer",
                      references = { table = "routes", column = "id", onDelete = "cascade" } },
                    { name = "ordinal",  type = "integer" },
                    { name = "node",     type = "integer" },
                },
                primaryKey = { "route_id", "ordinal" },
            },
        },
    }
end

describe("DB.Types", function()
    it("NULL is a unique read-only sentinel", function()
        local ns = newSchemaNs()
        assert.is_true(ns.DB.isNull(ns.DB.NULL))
        assert.is_false(ns.DB.isNull(nil))
        assert.is_false(ns.DB.isNull(0))
        local ok = pcall(function() ns.DB.NULL.x = 1 end)
        assert.is_false(ok)
    end)

    it("checkType enforces each column type", function()
        local ns = newSchemaNs()
        local DB = ns.DB
        assert.is_true(DB.checkType("integer", 5))
        assert.is_false(DB.checkType("integer", 5.5))
        assert.is_true(DB.checkType("number", 5.5))
        assert.is_true(DB.checkType("text", "hi"))
        assert.is_false(DB.checkType("text", 1))
        assert.is_true(DB.checkType("boolean", false))
    end)

    it("rejects an unknown / table column type (no blob columns)", function()
        local ns = newSchemaNs()
        assert.is_nil(ns.DB.normalizeType("table"))
        assert.is_nil(ns.DB.normalizeType("blob"))
        assert.are.equal("integer", ns.DB.normalizeType("integer"))
    end)
end)

describe("DB.Schema", function()
    it("builds tables, columns, PK, unique, indices, FKs", function()
        local ns = newSchemaNs()
        local s = ns.DB.Schema.new("Flight", flightSpec())
        assert.are.equal(1, s:Version())
        local routes = s:Table("routes")
        assert.are.equal("integer", routes:Column("id"):Type())
        assert.is_true(routes:Column("id"):IsAuto())
        assert.is_true(routes:Column("id"):IsPrimaryKey())
        assert.is_false(routes:Column("faction"):IsNullable())
        assert.is_true(routes:Column("quality"):IsNullable())          -- nullable by default
        assert.are.equal(1, #routes:PrimaryKey())
        assert.are.equal("id", routes:PrimaryKey()[1])

        local hops = s:Table("route_hops")
        assert.are.equal(2, #hops:PrimaryKey())                        -- composite PK
        assert.is_false(hops:Column("route_id"):IsNullable())          -- composite-PK member forced NOT NULL
        local fk = hops:ForeignKeys()[1]
        assert.are.equal("route_id", fk.column)
        assert.are.equal("routes", fk.table)
        assert.are.equal("id", fk.refColumn)
        assert.are.equal("cascade", fk.onDelete)
    end)

    it("defaults an FK column reference to the target's primary key", function()
        local ns = newSchemaNs()
        local s = ns.DB.Schema.new("X", {
            tables = {
                a = { columns = { { name = "id", type = "integer", primaryKey = true } } },
                b = { columns = {
                    { name = "id", type = "integer", primaryKey = true },
                    { name = "a_id", type = "integer", references = { table = "a" } },   -- no column -> a.id
                } },
            },
        })
        assert.are.equal("id", s:Table("b"):ForeignKeys()[1].refColumn)
    end)

    it("rejects autoIncrement on a non-integer / non-PK column", function()
        local ns = newSchemaNs()
        assert.is_false(pcall(ns.DB.Schema.new, "X", {
            tables = { a = { columns = { { name = "x", type = "text", primaryKey = true, autoIncrement = true } } } },
        }))
        assert.is_false(pcall(ns.DB.Schema.new, "X", {
            tables = { a = { columns = {
                { name = "id", type = "integer", primaryKey = true },
                { name = "n", type = "integer", autoIncrement = true },     -- not the PK
            } } },
        }))
    end)

    it("rejects ON DELETE SET NULL on a NOT NULL column", function()
        local ns = newSchemaNs()
        assert.is_false(pcall(ns.DB.Schema.new, "X", {
            tables = {
                a = { columns = { { name = "id", type = "integer", primaryKey = true } } },
                b = { columns = {
                    { name = "id", type = "integer", primaryKey = true },
                    { name = "a_id", type = "integer", nullable = false,
                      references = { table = "a", onDelete = "set_null" } },
                } },
            },
        }))
    end)

    it("rejects an FK to an unknown table and to a non-key column", function()
        local ns = newSchemaNs()
        assert.is_false(pcall(ns.DB.Schema.new, "X", {
            tables = { b = { columns = {
                { name = "id", type = "integer", primaryKey = true },
                { name = "a_id", type = "integer", references = { table = "ghost" } },
            } } },
        }))
        assert.is_false(pcall(ns.DB.Schema.new, "X", {
            tables = {
                a = { columns = {
                    { name = "id", type = "integer", primaryKey = true },
                    { name = "label", type = "text" },                       -- not PK/unique
                } },
                b = { columns = {
                    { name = "id", type = "integer", primaryKey = true },
                    { name = "a_label", type = "text", references = { table = "a", column = "label" } },
                } },
            },
        }))
    end)

    it("validates and stores triggers + views", function()
        local ns = newSchemaNs()
        local fired = {}
        local spec = flightSpec()
        spec.triggers = { { table = "routes", time = "after", event = "delete",
                            action = function() fired[#fired + 1] = true end } }
        spec.views = { fast = { build = function(db) return db end } }
        local s = ns.DB.Schema.new("Flight", spec)
        assert.are.equal(1, #s:Triggers())
        assert.are.equal("after", s:Triggers()[1].time)
        assert.is_true(s:Views().fast ~= nil)
    end)

    it("rejects an unknown trigger event and a view colliding with a table", function()
        local ns = newSchemaNs()
        local spec = flightSpec()
        spec.triggers = { { table = "routes", event = "explode", action = function() end } }
        assert.is_false(pcall(ns.DB.Schema.new, "Flight", spec))

        local spec2 = flightSpec()
        spec2.views = { routes = { build = function() end } }     -- name collides with a table
        assert.is_false(pcall(ns.DB.Schema.new, "Flight", spec2))
    end)
end)
