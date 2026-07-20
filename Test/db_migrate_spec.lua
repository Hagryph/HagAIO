local S = dofile("Test/support.lua")

-- Locks the load-time COLUMN auto-migration (Database:_Reconcile, run inside _Conform): persisted rows
-- are brought up to the current schema before the conformance checks -- a column dropped from the
-- schema is removed from the row, a newly-added column is filled from its default, and a row still
-- missing a NOT-NULL column with no default is dropped.
local function newDbNs()
    local ns = S.newNs()
for _, f in ipairs({ "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager", "Database" }) do
        S.load(ns, "Core/DB/" .. f .. ".lua")
    end
    return ns
end

local function spec()
    return { tables = { t = {
        columns = {
            { name = "id",      type = "integer", primaryKey = true, autoIncrement = true },
            { name = "faction", type = "text",    nullable = false },   -- NOT NULL, no default
            { name = "qty",     type = "integer", default = 5 },        -- newly-added, defaulted
            { name = "name",    type = "text" },
        },
    } } }
end

-- Build a Database whose GLOBAL backing is pre-seeded with `rows` (as if loaded from saved vars).
local function build(ns, rows)
    local slot = { tables = { t = rows } }
    local db = ns.DB.Database:New("T", ns.DB.Schema.new("T", spec()),
        { [ns.DB.Scope.GLOBAL] = slot })
    return db, slot.tables.t
end

describe("DB column auto-migration on load", function()
    it("drops a column that no longer exists in the schema", function()
        local ns = newDbNs()
        local _, rows = build(ns, { { id = 1, faction = "Horde", qty = 2, name = "A", oldCol = 99 } })
        assert.are.equal(1, #rows)
        assert.is_nil(rows[1].oldCol)        -- stale column removed from the persisted row
        assert.are.equal("Horde", rows[1].faction)
    end)

    it("backfills a newly-added column from its default", function()
        local ns = newDbNs()
        local _, rows = build(ns, { { id = 1, faction = "Alliance", name = "B" } })   -- no qty
        assert.are.equal(5, rows[1].qty)     -- filled from the column default
    end)

    it("still drops a row missing a NOT-NULL column with no default", function()
        local ns = newDbNs()
        local _, rows = build(ns, {
            { id = 1, faction = "Horde", name = "ok" },
            { id = 2, name = "bad" },          -- missing faction (NOT NULL, no default)
        })
        assert.are.equal(1, #rows)
        assert.are.equal("ok", rows[1].name)
    end)
end)
