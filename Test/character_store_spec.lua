local S = dofile("Test/support.lua")

-- Exercises ns.CharacterStore (Modules/Dashboard/CharacterStore.lua) -- the Dashboard's per-character
-- DATA layer, extracted out of the module so it is unit-testable behind a fake owner. The highest-value
-- check is Chars(): it reconstructs the document shape the whole dashboard UI trusts from the five flat
-- tables, and was previously only covered indirectly. We drive it against a real in-memory DB engine
-- (the same one dashboard_db_spec builds) with a fake owner whose :DB() returns it.

local DB_FILES = { "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor" }

-- The dashboard tables CharacterStore fronts (the columns it reads/writes; FK enforcement is
-- dashboard_db_spec's job, so references are omitted here to keep seeding order-free).
local function spec()
    return { tables = {
        keystone = { columns = {
            { name = "mapid", type = "integer", primaryKey = true }, { name = "name", type = "text" },
        } },
        dashboard_char = { columns = {
            { name = "char_key", type = "text", primaryKey = true },
            { name = "name", type = "text" }, { name = "realm", type = "text" }, { name = "class", type = "text" },
            { name = "level", type = "integer" }, { name = "ilvl", type = "integer" },
            { name = "ks_mapid", type = "integer" }, { name = "ks_level", type = "integer" },
            { name = "rating", type = "integer" }, { name = "last_seen", type = "number" },
        } },
        dashboard_instance = { columns = {
            { name = "key", type = "text", primaryKey = true }, { name = "instance_id", type = "integer" },
            { name = "name", type = "text" }, { name = "diff", type = "text" }, { name = "is_raid", type = "boolean" },
            { name = "diff_id", type = "integer" }, { name = "total", type = "integer" },
            { name = "expansion", type = "text" }, { name = "current_season", type = "boolean", default = false },
        } },
        dashboard_vault = {
            columns = {
                { name = "char_key", type = "text", nullable = false }, { name = "ordinal", type = "integer", nullable = false },
                { name = "type", type = "integer" }, { name = "level", type = "integer" },
                { name = "progress", type = "integer" }, { name = "threshold", type = "integer" },
            }, primaryKey = { "char_key", "ordinal" } },
        dashboard_lockout = {
            columns = {
                { name = "char_key", type = "text", nullable = false }, { name = "instance_key", type = "text", nullable = false },
                { name = "progress", type = "integer" }, { name = "total", type = "integer" }, { name = "reset", type = "integer" },
            }, primaryKey = { "char_key", "instance_key" } },
        dashboard_quest = {
            columns = {
                { name = "char_key", type = "text", nullable = false }, { name = "freq", type = "text", nullable = false },
                { name = "quest_id", type = "integer", nullable = false }, { name = "done_at", type = "number" },
            }, primaryKey = { "char_key", "freq", "quest_id" } },
    } }
end

-- A fresh CharacterStore over a real in-memory DB, behind a fake owner.
local function rig()
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    ns.ResetLedger = { CharKey = function(_, n, r) return (n or "?") .. "-" .. (r or "?") end }
    ns.Worker = { Mark = function() end, MaybeYield = function() end }   -- no chunking in the test
    S.load(ns, "Lib/DashboardData.lua")   -- PlainNum remains a dashboard-specific shaping helper
    S.load(ns, "Modules/Dashboard/CharacterStore.lua")
    local db = ns.DB.Database:New("Dash", ns.DB.Schema.new("Dash", spec()), {})
    local owner = { DB = function() return db end }   -- the LIVE db handle the collaborator fetches per call
    return ns.CharacterStore:New(owner), db, ns
end

describe("CharacterStore", function()
    it("fetches the DB live through the owner (never caches a pre-login nil)", function()
        local ns = S.newNs()
        for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
        ns.ResetLedger = { CharKey = function(_, n, r) return n .. "-" .. r end }
        ns.Worker = { Mark = function() end, MaybeYield = function() end }
        S.load(ns, "Lib/DashboardData.lua")
        S.load(ns, "Modules/Dashboard/CharacterStore.lua")
        local db = nil
        local owner = { DB = function() return db end }   -- nil at construction, set later (mimics pre-login)
        local cs = ns.CharacterStore:New(owner)
        assert.is_nil(next(cs:Chars()))                   -- no DB yet -> empty, no error
        db = ns.DB.Database:New("Dash", ns.DB.Schema.new("Dash", spec()), {})
        cs:SetKeystone(1, "Now Live")                     -- the same store now sees the built DB
        assert.are.equal("Now Live", db:Select("name"):From("keystone"):Where("mapid", "=", 1):Run()[1].name)
    end)

    it("Chars() reconstructs the per-character document shape from the flat tables", function()
        local cs, db = rig()
        db:Insert("keystone", { mapid = 501, name = "The Dawnbreaker" })
        db:Insert("dashboard_instance", { key = "Raid|Heroic", instance_id = 100, name = "Raid", diff = "Heroic",
            is_raid = true, diff_id = 16, total = 8, expansion = "Midnight", current_season = true })
        db:Insert("dashboard_char", { char_key = "Alt-Realm", name = "Alt", realm = "Realm", class = "MAGE",
            level = 80, ilvl = 600, ks_mapid = 501, ks_level = 12, rating = 2500, last_seen = 1000 })
        db:InsertAll("dashboard_vault", {
            { char_key = "Alt-Realm", ordinal = 1, type = 1, level = 5, progress = 1, threshold = 4 },
            { char_key = "Alt-Realm", ordinal = 2, type = 1, level = 6, progress = 3, threshold = 4 },
        })
        db:Insert("dashboard_lockout", { char_key = "Alt-Realm", instance_key = "Raid|Heroic", progress = 2, total = 8, reset = 999 })
        db:Insert("dashboard_quest", { char_key = "Alt-Realm", freq = "weekly", quest_id = 42, done_at = 555 })

        local doc = cs:Chars()["Alt-Realm"]
        assert(doc)                                      -- the character reconstructed
        assert.are.equal("Alt", doc.name)
        assert.are.equal("MAGE", doc.class)
        assert.are.equal(80, doc.level)
        assert.are.equal(600, doc.ilvl)
        assert.are.equal(2500, doc.rating)
        -- keystone flattened onto the char row, its name resolved from the reference table
        assert.are.equal(501, doc.keystone.mapID)
        assert.are.equal(12, doc.keystone.level)
        assert.are.equal("The Dawnbreaker", doc.keystone.name)
        -- vault slots bucketed under the char
        assert.are.equal(2, #doc.vault.slots)
        assert.are.equal(4, doc.vault.slots[1].threshold)
        -- lockout resolved against the dashboard_instance registry (name/diff/isRaid come from the ref)
        assert.are.equal(1, #doc.lockouts)
        assert.are.equal("Raid", doc.lockouts[1].name)
        assert.are.equal("Heroic", doc.lockouts[1].diff)
        assert.is_true(doc.lockouts[1].isRaid)
        assert.are.equal(2, doc.lockouts[1].progress)
        -- quest under its frequency, carrying the turn-in moment
        assert.are.equal(555, doc.quests.weekly[42])
    end)

    it("Chars() drops a lockout whose instance registry row is gone", function()
        local cs, db = rig()
        db:Insert("dashboard_char", { char_key = "K", name = "K", realm = "R" })
        -- a lock pointing at an instance key with NO dashboard_instance row -> not reconstructable
        db:Insert("dashboard_lockout", { char_key = "K", instance_key = "Ghost|Mythic", progress = 1, total = 1, reset = 1 })
        assert.are.equal(0, #cs:Chars()["K"].lockouts)
    end)

    it("Chars() is cached and a writer (SetKeystone) invalidates it", function()
        local cs, db = rig()
        db:Insert("keystone", { mapid = 5, name = "Old" })
        db:Insert("dashboard_char", { char_key = "A-R", name = "A", realm = "R", ks_mapid = 5, ks_level = 10 })
        local first = cs:Chars()
        assert.are.equal("Old", first["A-R"].keystone.name)
        assert.are.equal(first, cs:Chars())                 -- cache hit: the SAME table, no rebuild
        cs:SetKeystone(5, "New")                            -- a writer must invalidate
        local second = cs:Chars()
        assert.are_not.equal(first, second)                 -- rebuilt
        assert.are.equal("New", second["A-R"].keystone.name)
    end)

    it("InvalidateChars() forces a rebuild (for the catalog/Dev DIRECT writes that bypass the store)", function()
        local cs, db = rig()
        db:Insert("dashboard_char", { char_key = "A-R", name = "A", realm = "R" })
        assert.are.equal("A", cs:Chars()["A-R"].name)       -- populate the cache
        db:Update("dashboard_char", { name = "Renamed" }, { char_key = "A-R" })   -- a DIRECT write, not via the store
        assert.are.equal("A", cs:Chars()["A-R"].name)       -- still served stale from the cache
        cs:InvalidateChars()
        assert.are.equal("Renamed", cs:Chars()["A-R"].name) -- now rebuilt
    end)

    it("SelfKey() composes the viewing character's Name-Realm key", function()
        local cs = rig()
        _G.UnitName = function() return "Hero" end
        _G.GetNormalizedRealmName = function() return "MyRealm" end
        assert.are.equal("Hero-MyRealm", cs:SelfKey())
        _G.UnitName, _G.GetNormalizedRealmName = nil, nil
    end)

    it("Instances() collapses NULL columns to nil and folds current_season to a bool", function()
        local cs, db, ns = rig()
        db:Insert("dashboard_instance", { key = "X|Y", instance_id = 5, name = "X", diff = "Y", is_raid = false,
            diff_id = ns.DB.NULL, total = ns.DB.NULL, expansion = "Exp" })   -- current_season omitted -> default false
        local inst = cs:Instances()["X|Y"]
        assert.are.equal("X", inst.name)
        assert.is_nil(inst.diffID)        -- NULL sentinel -> nil
        assert.is_nil(inst.total)
        assert.is_false(inst.season)      -- defaulted false -> false (never nil)
    end)

    it("SetInstance() upserts, MERGING so an omitted column keeps its stored value", function()
        local cs, db = rig()
        cs:SetInstance("K", { instance_id = 1, name = "N", diff = "D", is_raid = true, diff_id = 16 })
        cs:SetInstance("K", { total = 9 })   -- a later sighting that knows only the boss count
        local r = db:Select("*"):From("dashboard_instance"):Where("key", "=", "K"):Run()[1]
        assert.are.equal("N", r.name)        -- not clobbered by the merge update
        assert.are.equal(9, r.total)
        assert.are.equal(1, #db:Select("key"):From("dashboard_instance"):Run())   -- one row, not two
    end)

    it("SetKeystone() upserts the reference name table (one row per map id)", function()
        local cs, db = rig()
        cs:SetKeystone(700, "First")
        cs:SetKeystone(700, "Renamed")
        local rows = db:Select("*"):From("keystone"):Where("mapid", "=", 700):Run()
        assert.are.equal(1, #rows)
        assert.are.equal("Renamed", rows[1].name)
    end)
end)
