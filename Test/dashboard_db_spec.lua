local S = dofile("Test/support.lua")

-- Locks the relational model the Dashboard module's DAO relies on (Modules/Dashboard.lua). The
-- snapshot is normalised across flat tables: dashboard_char + cascading vault/lockout/quest children,
-- with reference data factored OUT -- a lockout references the dashboard_instance registry (name/diff),
-- a quest references the shared `quest` table (title), a keystone map id references the local keystone
-- name table. We exercise the schema guarantees the reconstruct/upsert/replace helpers depend on
-- (composite PKs, cascading deletes from both parents, NULL-as-sentinel projection) at the engine
-- level, without loading the WoW-coupled module.
local DB_FILES = { "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor" }
local function newDbNs()
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    return ns
end

-- The Dashboard tables + the shared/reference tables they point at, mirroring the schemas in
-- Modules/Dashboard.lua and Core/DB/CoreTables.lua (scope is irrelevant here -- the engine routes by
-- the backing slots, and none are passed, so everything is in-memory).
local function spec()
    local charFk = { table = "dashboard_char", column = "char_key", onDelete = "cascade" }
    return { tables = {
        keystone = { columns = {
            { name = "mapid", type = "integer", primaryKey = true }, { name = "name", type = "text" },
        } },
        quest = { columns = {
            { name = "quest_id", type = "integer", primaryKey = true },
            { name = "title",    type = "text" }, { name = "time", type = "number" },
        } },
        dashboard_char = { columns = {
            { name = "char_key", type = "text", primaryKey = true },
            { name = "name", type = "text" }, { name = "class", type = "text" }, { name = "level", type = "integer" },
            { name = "ks_mapid", type = "integer",
                references = { table = "keystone", column = "mapid", onDelete = "cascade" } },
            { name = "ks_level", type = "integer" },
        } },
        expansion = { columns = {
            { name = "name", type = "text", primaryKey = true },
            { name = "level", type = "integer" }, { name = "logo", type = "integer" },
        } },
        dashboard_instance = { columns = {
            { name = "key", type = "text", primaryKey = true }, { name = "instance_id", type = "integer" },
            { name = "name", type = "text" },
            { name = "diff", type = "text" }, { name = "is_raid", type = "boolean" }, { name = "diff_id", type = "integer" },
            { name = "expansion", type = "text",
                references = { table = "expansion", column = "name", onDelete = "cascade" } },
            { name = "current_season", type = "boolean", default = false },
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
                { name = "char_key",     type = "text", nullable = false, references = charFk },
                { name = "instance_key", type = "text", nullable = false,
                    references = { table = "dashboard_instance", column = "key", onDelete = "cascade" } },
                { name = "progress", type = "integer" }, { name = "total", type = "integer" }, { name = "reset", type = "integer" },
            },
            primaryKey = { "char_key", "instance_key" } },
        dashboard_quest = {
            columns = {
                { name = "char_key", type = "text", nullable = false, references = charFk },
                { name = "freq",     type = "text", nullable = false },
                { name = "quest_id", type = "integer", nullable = false,
                    references = { table = "quest", column = "quest_id", onDelete = "cascade" } },
            },
            primaryKey = { "char_key", "freq", "quest_id" } },
    } }
end

local function newDb(ns) return ns.DB.Database:New("Dash", ns.DB.Schema.new("Dash", spec()), {}) end

local KEY, IKEY = "Alt-Realm", "Raid|Heroic"
local function seed(db)   -- reference rows first, then the character + its children
    db:Insert("keystone", { mapid = 501, name = "The Dawnbreaker" })
    db:Insert("quest", { quest_id = 42, title = "Weekly Quest" })
    db:Insert("expansion", { name = "Midnight", level = 11, logo = 12345 })
    db:Insert("dashboard_instance", { key = IKEY, name = "Raid", diff = "Heroic", is_raid = true, diff_id = 16,
        expansion = "Midnight", current_season = true })
    db:Insert("dashboard_char", { char_key = KEY, name = "Alt", class = "MAGE", level = 80, ks_mapid = 501, ks_level = 12 })
    db:InsertAll("dashboard_vault", {
        { char_key = KEY, ordinal = 1, progress = 1, threshold = 4 },
        { char_key = KEY, ordinal = 2, progress = 3, threshold = 4 },
    })
    db:Insert("dashboard_lockout", { char_key = KEY, instance_key = IKEY, progress = 2, total = 8, reset = 999 })
    db:Insert("dashboard_quest", { char_key = KEY, freq = "weekly", quest_id = 42 })
end

describe("Dashboard DB schema", function()
    it("cascade-deletes a character's vault/lockout/quest rows with the character", function()
        local db = newDb(newDbNs())
        seed(db)
        assert.are.equal(2, #db:Select("*"):From("dashboard_vault"):Run())
        db:Delete("dashboard_char", function(x) return x.char_key == KEY end)
        assert.are.equal(0, #db:Select("*"):From("dashboard_vault"):Run())
        assert.are.equal(0, #db:Select("*"):From("dashboard_lockout"):Run())
        assert.are.equal(0, #db:Select("*"):From("dashboard_quest"):Run())
        -- reference rows are untouched (they outlive any one character)
        assert.are.equal(1, #db:Select("*"):From("quest"):Run())
        assert.are.equal(1, #db:Select("*"):From("keystone"):Run())
    end)

    it("cascades the reference deletes: a quest removes its per-char rows; a keystone removes the char", function()
        local db = newDb(newDbNs())
        seed(db)
        db:Delete("quest", function(x) return x.quest_id == 42 end)
        assert.are.equal(0, #db:Select("*"):From("dashboard_quest"):Run())   -- the per-char quest row followed it
        assert.are.equal(1, #db:Select("*"):From("dashboard_char"):Run())    -- the character itself stays
        -- a keystone delete cascades to the whole character (ks_mapid is its FK) -- inert in practice,
        -- since the local keystone table is upsert-only and never deletes rows at runtime
        db:Delete("keystone", function(x) return x.mapid == 501 end)
        assert.are.equal(0, #db:Select("*"):From("dashboard_char"):Run())
        assert.are.equal(0, #db:Select("*"):From("dashboard_vault"):Run())   -- and its children, transitively
    end)

    it("cascade-deletes a character's lock when its instance is pruned", function()
        local db = newDb(newDbNs())
        seed(db)
        db:Delete("dashboard_instance", function(x) return x.key == IKEY end)
        assert.are.equal(0, #db:Select("*"):From("dashboard_lockout"):Run())   -- lock followed the instance
        assert.are.equal(1, #db:Select("*"):From("dashboard_char"):Run())      -- the character stays
    end)

    it("rejects a lock / quest whose referenced instance / quest id does not exist", function()
        local db = newDb(newDbNs())
        seed(db)
        assert.is_false(pcall(function()
            db:Insert("dashboard_lockout", { char_key = KEY, instance_key = "Ghost|Mythic", progress = 1 })
        end))
        assert.is_false(pcall(function()
            db:Insert("dashboard_quest", { char_key = KEY, freq = "daily", quest_id = 999 })
        end))
    end)

    it("rejects a duplicate composite PK (same char_key + ordinal)", function()
        local db = newDb(newDbNs())
        seed(db)
        assert.is_false(pcall(function()
            db:Insert("dashboard_vault", { char_key = KEY, ordinal = 1, progress = 9, threshold = 9 })
        end))
    end)

    it("projects an absent nullable column as the NULL sentinel (denull -> nil)", function()
        local ns = newDbNs()
        local db = newDb(ns)
        seed(db)
        db:Insert("dashboard_vault", { char_key = KEY, ordinal = 3, progress = ns.DB.NULL, threshold = 4 })
        local row = db:Select("*"):From("dashboard_vault"):Where("ordinal", "=", 3):Run()[1]
        assert.is_true(ns.DB.isNull(row.progress))   -- sentinel, not Lua nil -- so the DAO must denull
        assert.are.equal(4, row.threshold)
    end)

    it("resolves the normalised references back (keystone name, instance, quest title)", function()
        local db = newDb(newDbNs())
        seed(db)
        local ks = db:Select("name"):From("keystone"):Where("mapid", "=", 501):Run()[1]
        assert.are.equal("The Dawnbreaker", ks.name)
        local inst = db:Select("name", "diff"):From("dashboard_instance"):Where("key", "=", IKEY):Run()[1]
        assert.are.equal("Raid", inst.name)
        local q = db:Select("title"):From("quest"):Where("quest_id", "=", 42):Run()[1]
        assert.are.equal("Weekly Quest", q.title)
    end)

    it("cascade-deletes an expansion's instances (and their locks) when the expansion is removed", function()
        local db = newDb(newDbNs())
        seed(db)
        db:Delete("expansion", function(x) return x.name == "Midnight" end)
        assert.are.equal(0, #db:Select("*"):From("dashboard_instance"):Run())   -- the raid followed its expansion
        assert.are.equal(0, #db:Select("*"):From("dashboard_lockout"):Run())    -- and the lock followed the raid
        assert.are.equal(1, #db:Select("*"):From("dashboard_char"):Run())       -- the character stays
    end)

    it("rejects an instance whose expansion is not registered, but allows a null expansion", function()
        local db = newDb(newDbNs())
        seed(db)
        assert.is_false(pcall(function()
            db:Insert("dashboard_instance", { key = "Ghost|Mythic", name = "Ghost", is_raid = true, expansion = "Nowhere" })
        end))
        assert.is_true(pcall(function()   -- an unmapped instance (expansion absent) is fine -- the FK is optional
            db:Insert("dashboard_instance", { key = "Unmapped|Mythic", name = "Unmapped", is_raid = true })
        end))
    end)

    it("defaults current_season to false when omitted", function()
        local db = newDb(newDbNs())
        seed(db)
        db:Insert("dashboard_instance", { key = "Old|Heroic", name = "Old", is_raid = true, expansion = "Midnight" })
        local row = db:Select("current_season"):From("dashboard_instance"):Where("key", "=", "Old|Heroic"):Run()[1]
        assert.is_false(row.current_season)
    end)

    it("a Questing time-upsert and a Dashboard title-upsert share one quest row", function()
        local db = newDb(newDbNs())
        db:Insert("quest", { quest_id = 7, time = 600 })                                  -- Questing learns the limit
        db:Update("quest", { title = "Heroic Cache" }, function(x) return x.quest_id == 7 end)  -- Dashboard adds a title
        local r = db:Select("*"):From("quest"):Run()[1]
        assert.are.equal(600, r.time)            -- preserved
        assert.are.equal("Heroic Cache", r.title)
    end)
end)
