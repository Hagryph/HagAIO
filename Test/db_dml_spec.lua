local S = dofile("Test/support.lua")

local function newDmlNs()
    local ns = S.newNs()
    for _, f in ipairs({ "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager", "Database" }) do
        S.load(ns, "Core/DB/" .. f .. ".lua")
    end
    return ns
end

-- routes + three child tables, one per ON DELETE action.
local function spec()
    return {
        tables = {
            routes = {
                columns = {
                    { name = "id",      type = "integer", primaryKey = true, autoIncrement = true },
                    { name = "faction", type = "text",    nullable = false },
                    { name = "src",     type = "integer", nullable = false },
                    { name = "dst",     type = "integer", nullable = false },
                    { name = "quality", type = "integer" },
                    { name = "label",   type = "text", default = "?" },
                },
                unique = { { "faction", "src", "dst" } },
            },
            hops = {
                columns = {
                    { name = "route_id", type = "integer", references = { table = "routes", onDelete = "cascade" } },
                    { name = "ordinal",  type = "integer" },
                    { name = "node",     type = "integer" },
                },
                primaryKey = { "route_id", "ordinal" },
            },
            tags = {
                columns = {
                    { name = "id",       type = "integer", primaryKey = true, autoIncrement = true },
                    { name = "route_id", type = "integer", references = { table = "routes", onDelete = "restrict" } },
                    { name = "label",    type = "text" },
                },
            },
            notes = {
                columns = {
                    { name = "id",       type = "integer", primaryKey = true, autoIncrement = true },
                    { name = "route_id", type = "integer", nullable = true,
                      references = { table = "routes", onDelete = "set_null" } },
                    { name = "body",     type = "text" },
                },
            },
        },
    }
end

local function newDb(ns, slot)
    -- the optional `slot` is bound as the GLOBAL backing (so tests can inspect what was persisted)
    return ns.DB.Database:New("Flight", ns.DB.Schema.new("Flight", spec()), slot and { [ns.DB.Scope.GLOBAL] = slot } or {})
end

describe("DB DML: insert", function()
    it("assigns an auto id, fills defaults, persists into the slot", function()
        local ns = newDmlNs()
        local slot = {}
        local db = newDb(ns, slot)
        local r = db:Insert("routes", { faction = "Horde", src = 1, dst = 2 })
        assert.are.equal(1, r.id)
        assert.are.equal("?", r.label)                 -- default filled
        assert.are.equal(2, db:Insert("routes", { faction = "Horde", src = 2, dst = 3 }).id)
        assert.are.equal(2, #slot.tables.routes)       -- written through to the slot table
    end)

    it("stores an explicit NULL as an absent field (not the sentinel)", function()
        local ns = newDmlNs()
        local db = newDb(ns)
        local r = db:Insert("routes", { faction = "Horde", src = 1, dst = 2, quality = ns.DB.NULL })
        assert.is_nil(rawget(r, "quality"))
    end)

    it("rejects NOT NULL, wrong type, unknown column, duplicate unique key", function()
        local ns = newDmlNs()
        local db = newDb(ns)
        assert.is_false(pcall(function() db:Insert("routes", { src = 1, dst = 2 }) end))               -- faction NOT NULL
        assert.is_false(pcall(function() db:Insert("routes", { faction = 5, src = 1, dst = 2 }) end))  -- faction type
        assert.is_false(pcall(function() db:Insert("routes", { faction = "H", src = 1, dst = 2, bogus = 1 }) end))
        db:Insert("routes", { faction = "Horde", src = 1, dst = 2 })
        assert.is_false(pcall(function() db:Insert("routes", { faction = "Horde", src = 1, dst = 2 }) end))
    end)

    it("enforces foreign keys (parent must exist; NULL FK allowed)", function()
        local ns = newDmlNs()
        local db = newDb(ns)
        db:Insert("routes", { faction = "Horde", src = 1, dst = 2 })   -- id 1
        assert.is_false(pcall(function() db:Insert("hops", { route_id = 99, ordinal = 1, node = 7 }) end))
        local h = db:Insert("hops", { route_id = 1, ordinal = 1, node = 7 })
        assert.are.equal(1, h.route_id)
        db:Insert("notes", { route_id = ns.DB.NULL, body = "free note" })   -- NULL optional FK ok
    end)

    it("keeps auto ids ahead of a manually supplied id", function()
        local ns = newDmlNs()
        local db = newDb(ns)
        db:Insert("routes", { id = 10, faction = "Horde", src = 1, dst = 2 })
        assert.are.equal(11, db:Insert("routes", { faction = "Alliance", src = 1, dst = 2 }).id)
    end)
end)

describe("DB DML: update", function()
    it("updates matching rows, revalidates, returns a count", function()
        local ns = newDmlNs()
        local db = newDb(ns)
        db:Insert("routes", { faction = "Horde", src = 1, dst = 2, quality = 1 })
        db:Insert("routes", { faction = "Horde", src = 5, dst = 9, quality = 1 })
        local n = db:Update("routes", { quality = 2 }, function(r) return r.faction == "Horde" end)
        assert.are.equal(2, n)
        for _, r in ipairs(db:Store():Rows("routes")) do assert.are.equal(2, r.quality) end
    end)

    it("can NULL a nullable column and rejects a type error", function()
        local ns = newDmlNs()
        local db = newDb(ns)
        local r = db:Insert("routes", { faction = "Horde", src = 1, dst = 2, quality = 3 })
        db:Update("routes", { quality = ns.DB.NULL }, function(x) return x.id == r.id end)
        assert.is_nil(rawget(r, "quality"))
        assert.is_false(pcall(function() db:Update("routes", { src = "x" }, nil) end))
    end)

    it("rejects an update that would collide with another row's unique key", function()
        local ns = newDmlNs()
        local db = newDb(ns)
        db:Insert("routes", { faction = "Horde", src = 1, dst = 2 })
        local b = db:Insert("routes", { faction = "Horde", src = 5, dst = 9 })
        assert.is_false(pcall(function()
            db:Update("routes", { src = 1, dst = 2 }, function(x) return x.id == b.id end)
        end))
    end)
end)

describe("DB DML: delete + cascade", function()
    local function seeded(ns)
        local db = newDb(ns)
        db:Insert("routes", { faction = "Horde", src = 1, dst = 2 })   -- id 1
        db:Insert("hops", { route_id = 1, ordinal = 1, node = 7 })
        db:Insert("hops", { route_id = 1, ordinal = 2, node = 8 })
        db:Insert("notes", { route_id = 1, body = "n" })
        return db
    end

    it("CASCADE removes child rows", function()
        local ns = newDmlNs()
        local db = seeded(ns)
        assert.are.equal(2, db:Store():Count("hops"))
        db:Delete("routes", function(r) return r.id == 1 end)
        assert.are.equal(0, db:Store():Count("routes"))
        assert.are.equal(0, db:Store():Count("hops"))           -- cascaded
    end)

    it("RESTRICT blocks the delete while a child exists", function()
        local ns = newDmlNs()
        local db = seeded(ns)
        db:Insert("tags", { route_id = 1, label = "x" })
        assert.is_false(pcall(function() db:Delete("routes", function(r) return r.id == 1 end) end))
        assert.are.equal(1, db:Store():Count("routes"))         -- still there
    end)

    it("SET NULL nulls the child FK instead of deleting it", function()
        local ns = newDmlNs()
        local db = seeded(ns)
        -- remove the cascading hops first so only the set-null note remains attached
        db:Delete("hops", function(h) return true end)
        db:Delete("routes", function(r) return r.id == 1 end)
        assert.are.equal(1, db:Store():Count("notes"))          -- note survives
        assert.is_nil(rawget(db:Store():Rows("notes")[1], "route_id"))   -- FK nulled
    end)
end)
