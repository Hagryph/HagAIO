local S = dofile("Test/support.lua")

-- Locks the relational model the Dashboard module's DAO relies on (Modules/Dashboard.lua): the five
-- flat tables that replaced the old nested chars/instances saved-var blob. We exercise the SCHEMA +
-- engine guarantees the reconstruct/upsert/replace helpers depend on -- composite PKs, cascading
-- child deletes, and NULL-as-sentinel projection -- without loading the WoW-coupled module itself.
local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor" }
local function newDbNs()
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    return ns
end

-- The Dashboard tables, mirroring the `tables` opt in Modules/Dashboard.lua (scope is irrelevant
-- here -- the engine routes by the backing slots passed to the Database).
local function spec()
    local charFk = { table = "dashboard_char", column = "char_key", onDelete = "cascade" }
    return { tables = {
        dashboard_char = { columns = {
            { name = "char_key",  type = "text", primaryKey = true },
            { name = "name",      type = "text" }, { name = "class", type = "text" },
            { name = "level",     type = "integer" }, { name = "ilvl", type = "integer" },
            { name = "last_seen", type = "integer" }, { name = "rating", type = "number" },
            { name = "ks_mapid",  type = "integer" }, { name = "ks_level", type = "integer" },
            { name = "ks_name",   type = "text" },
        } },
        dashboard_vault = {
            columns = {
                { name = "char_key", type = "text", nullable = false, references = charFk },
                { name = "ordinal",  type = "integer", nullable = false },
                { name = "progress", type = "integer" }, { name = "threshold", type = "integer" },
            },
            primaryKey = { "char_key", "ordinal" } },
        dashboard_lockout = {
            columns = {
                { name = "char_key", type = "text", nullable = false, references = charFk },
                { name = "ordinal",  type = "integer", nullable = false },
                { name = "name",     type = "text" }, { name = "diff", type = "text" },
                { name = "is_raid",  type = "boolean" },
            },
            primaryKey = { "char_key", "ordinal" } },
        dashboard_quest = {
            columns = {
                { name = "char_key", type = "text", nullable = false, references = charFk },
                { name = "freq",     type = "text", nullable = false },
                { name = "quest_id", type = "integer", nullable = false },
                { name = "title",    type = "text" },
            },
            primaryKey = { "char_key", "freq", "quest_id" } },
        dashboard_instance = { columns = {
            { name = "key",     type = "text", primaryKey = true },
            { name = "name",    type = "text" }, { name = "is_raid", type = "boolean" },
            { name = "diff_id", type = "integer" }, { name = "expansion", type = "text" },
        } },
    } }
end

local function newDb(ns)
    return ns.DB.Database:New("Dash", ns.DB.Schema.new("Dash", spec()), {})
end

local KEY = "Alt-Realm"
local function seedChar(db)
    db:Insert("dashboard_char", { char_key = KEY, name = "Alt", class = "MAGE", level = 80 })
end

describe("Dashboard DB schema", function()
    it("cascade-deletes a character's vault/lockout/quest rows with the character", function()
        local ns = newDb(newDbNs())
        local db = ns
        seedChar(db)
        db:InsertAll("dashboard_vault", {
            { char_key = KEY, ordinal = 1, progress = 1, threshold = 4 },
            { char_key = KEY, ordinal = 2, progress = 3, threshold = 4 },
        })
        db:Insert("dashboard_lockout", { char_key = KEY, ordinal = 1, name = "Raid", diff = "Heroic", is_raid = true })
        db:Insert("dashboard_quest",   { char_key = KEY, freq = "weekly", quest_id = 42, title = "Q" })

        assert.are.equal(2, #db:Select("*"):From("dashboard_vault"):Run())
        db:Delete("dashboard_char", function(x) return x.char_key == KEY end)
        assert.are.equal(0, #db:Select("*"):From("dashboard_vault"):Run())
        assert.are.equal(0, #db:Select("*"):From("dashboard_lockout"):Run())
        assert.are.equal(0, #db:Select("*"):From("dashboard_quest"):Run())
    end)

    it("rejects a duplicate composite PK (same char_key + ordinal)", function()
        local db = newDb(newDbNs())
        seedChar(db)
        db:Insert("dashboard_vault", { char_key = KEY, ordinal = 1, progress = 1, threshold = 4 })
        assert.is_false(pcall(function()
            db:Insert("dashboard_vault", { char_key = KEY, ordinal = 1, progress = 9, threshold = 9 })
        end))
    end)

    it("projects an absent nullable column as the NULL sentinel (denull -> nil)", function()
        local ns = newDbNs()
        local db = newDb(ns)
        seedChar(db)
        db:Insert("dashboard_vault", { char_key = KEY, ordinal = 1, progress = ns.DB.NULL, threshold = 4 })
        local row = db:Select("*"):From("dashboard_vault"):Run()[1]
        assert.is_true(ns.DB.isNull(row.progress))   -- sentinel, not Lua nil -- so the DAO must denull
        assert.are.equal(4, row.threshold)
    end)

    it("upsert keeps a prior instance field when a later sighting omits it", function()
        local db = newDb(newDbNs())
        local key = "Dungeon|Mythic"
        db:Insert("dashboard_instance", { key = key, name = "Dungeon", is_raid = false, diff_id = 23 })
        -- a later sighting without diff_id updates only what it provides
        db:Update("dashboard_instance", { expansion = "Midnight" }, function(x) return x.key == key end)
        local r = db:Select("*"):From("dashboard_instance"):Run()[1]
        assert.are.equal(23, r.diff_id)          -- preserved
        assert.are.equal("Midnight", r.expansion)
        assert.is_false(r.is_raid)               -- boolean false survives round-trip
    end)

    it("delete-then-insert replaces a character's children (the snapshot refresh)", function()
        local db = newDb(newDbNs())
        seedChar(db)
        db:InsertAll("dashboard_lockout", {
            { char_key = KEY, ordinal = 1, name = "A", diff = "Normal", is_raid = true },
            { char_key = KEY, ordinal = 2, name = "B", diff = "Heroic", is_raid = true },
        })
        db:Delete("dashboard_lockout", function(x) return x.char_key == KEY end)
        db:Insert("dashboard_lockout", { char_key = KEY, ordinal = 1, name = "C", diff = "Mythic", is_raid = true })
        local rows = db:Select("*"):From("dashboard_lockout"):Run()
        assert.are.equal(1, #rows)
        assert.are.equal("C", rows[1].name)
    end)
end)
