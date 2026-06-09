local S = dofile("Test/support.lua")

local function newStorageNs()
    local ns = S.newNs()
    S.load(ns, "Core/DB/Types.lua")
    S.load(ns, "Core/DB/Schema.lua")
    S.load(ns, "Core/DB/RowStore.lua")
    S.load(ns, "Core/DB/IndexManager.lua")
    return ns
end

local function schema(ns)
    return ns.DB.Schema.new("Flight", {
        tables = {
            routes = {
                columns = {
                    { name = "id",      type = "integer", primaryKey = true, autoIncrement = true },
                    { name = "faction", type = "text",    nullable = false },
                    { name = "src",     type = "integer", nullable = false },
                    { name = "dst",     type = "integer", nullable = false },
                    { name = "quality", type = "integer" },
                },
                unique  = { { "faction", "src", "dst" } },
                indices = { { columns = { "faction" } } },
            },
        },
    })
end

describe("DB.RowStore", function()
    it("seeds the slot shape and a table array for each schema table", function()
        local ns = newStorageNs()
        local slot = {}
        local rs = ns.DB.RowStore:New(schema(ns), { [ns.DB.Scope.GLOBAL] = slot })
        assert.is_true(type(slot.tables) == "table")
        assert.is_true(type(slot.tables.routes) == "table")
        assert.is_true(type(slot._meta.autoIds) == "table")
        assert.are.equal(0, rs:Count("routes"))
    end)

    it("hands out monotonic auto ids persisted in _meta", function()
        local ns = newStorageNs()
        local slot = {}
        local rs = ns.DB.RowStore:New(schema(ns), { [ns.DB.Scope.GLOBAL] = slot })
        assert.are.equal(1, rs:NextId("routes"))
        assert.are.equal(2, rs:NextId("routes"))
        assert.are.equal(2, slot._meta.autoIds.routes)
        -- a new RowStore over the same slot continues the sequence (no id reuse across reload)
        local rs2 = ns.DB.RowStore:New(schema(ns), { [ns.DB.Scope.GLOBAL] = slot })
        assert.are.equal(3, rs2:NextId("routes"))
    end)

    it("NoteId keeps the high-water mark ahead of manual ids", function()
        local ns = newStorageNs()
        local rs = ns.DB.RowStore:New(schema(ns), {})
        rs:NoteId("routes", 50)
        assert.are.equal(51, rs:NextId("routes"))
    end)

    it("appends and removes rows by identity", function()
        local ns = newStorageNs()
        local rs = ns.DB.RowStore:New(schema(ns), {})
        local r = rs:Append("routes", { id = 1, faction = "Horde", src = 1, dst = 2 })
        assert.are.equal(1, rs:Count("routes"))
        assert.is_true(rs:RemoveRow("routes", r))
        assert.are.equal(0, rs:Count("routes"))
        assert.is_false(rs:RemoveRow("routes", r))
    end)
end)

describe("DB.IndexManager", function()
    local function seeded(ns)
        local slot = {}
        local rs = ns.DB.RowStore:New(schema(ns), { [ns.DB.Scope.GLOBAL] = slot })
        rs:Append("routes", { id = 1, faction = "Horde",    src = 1, dst = 2, quality = 2 })
        rs:Append("routes", { id = 2, faction = "Alliance", src = 1, dst = 3 })           -- quality NULL (absent)
        rs:Append("routes", { id = 3, faction = "Horde",    src = 5, dst = 9, quality = 2 })
        local ix = ns.DB.IndexManager:New(schema(ns), rs)
        return rs, ix, slot
    end

    it("rebuilds PK / unique / column maps from existing rows", function()
        local ns = newStorageNs()
        local rs, ix = seeded(ns)
        assert.is_true(ix:FindByPrimaryKey("routes", { id = 2 }) ~= nil)
        assert.is_nil(ix:FindByPrimaryKey("routes", { id = 99 }))
        -- indexed column lookup (faction is a declared index)
        assert.are.equal(2, #ix:FindByColumn("routes", "faction", "Horde"))
        assert.are.equal(1, #ix:FindByColumn("routes", "faction", "Alliance"))
        assert.are.equal(0, #ix:FindByColumn("routes", "faction", "Neutral"))
    end)

    it("detects a composite UNIQUE violation but allows a distinct key", function()
        local ns = newStorageNs()
        local rs, ix = seeded(ns)
        local dup = { id = 9, faction = "Horde", src = 1, dst = 2 }      -- same (faction,src,dst) as id=1
        assert.is_true(ix:UniqueViolation("routes", dup) ~= nil)
        local ok = { id = 9, faction = "Horde", src = 2, dst = 2 }
        assert.is_nil(ix:UniqueViolation("routes", ok))
    end)

    it("excludes the row being updated from its own uniqueness check", function()
        local ns = newStorageNs()
        local rs, ix = seeded(ns)
        local existing = ix:FindByPrimaryKey("routes", { id = 1 })
        assert.is_nil(ix:UniqueViolation("routes", existing, existing))
    end)

    it("maintains maps on insert and delete", function()
        local ns = newStorageNs()
        local rs, ix = seeded(ns)
        local r = rs:Append("routes", { id = 4, faction = "Horde", src = 7, dst = 8 })
        ix:OnInsert("routes", r)
        assert.are.equal(3, #ix:FindByColumn("routes", "faction", "Horde"))
        ix:OnDelete("routes", r)
        assert.are.equal(2, #ix:FindByColumn("routes", "faction", "Horde"))
        assert.is_nil(ix:FindByPrimaryKey("routes", { id = 4 }))
    end)

    it("does not index NULL key columns (many NULLs allowed)", function()
        local ns = newStorageNs()
        local rs, ix = seeded(ns)
        -- quality is NULL on id=2; a column lookup on quality isn't indexed -> nil (scan fallback)
        assert.is_nil(ix:FindByColumn("routes", "quality", 2))
        assert.is_false(ix:HasColumnIndex("routes", "quality"))
    end)

    it("round-trips: a fresh IndexManager over the same slot answers identically", function()
        local ns = newStorageNs()
        local _, _, slot = seeded(ns)
        local rs2 = ns.DB.RowStore:New(schema(ns), { [ns.DB.Scope.GLOBAL] = slot })
        local ix2 = ns.DB.IndexManager:New(schema(ns), rs2)
        assert.is_true(ix2:FindByPrimaryKey("routes", { id = 3 }) ~= nil)
        assert.are.equal(2, #ix2:FindByColumn("routes", "faction", "Horde"))
    end)
end)
