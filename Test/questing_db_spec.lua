local S = dofile("Test/support.lua")

-- Locks Questing's account-wide timed-quest registry against a LIVE in-memory database. The
-- shared `quest` table (Core/DB/CoreTables.lua) is keyed by quest_id; a quest counts as TIMED
-- only when its `time` column is set -- a row may also exist merely because Dashboard recorded
-- its title, which does NOT make it timed. We drive the real module methods:
--   _RememberTimed(id, secs)   -> upsert `time` onto the quest row (insert new / update existing)
--   _TimedSecondsStored(id)    -> the learned limit, or nil (NULL / absent / title-only all -> nil)
--   _TimedSeconds(id)          -> live in-log timer preferred, else the stored limit
-- The module reaches the database through self:DB() -> ns.DatabaseManager:Shared(), so a real
-- built DB plus the captured Questing instance exercises the actual query/upsert paths.

local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor", "CoreTables", "DatabaseManager" }

-- Build the engine + shared DB (CoreTables, incl. `quest`), then load the real Questing module
-- and capture the instance it registers. Returns (questing, db).
local function setup()
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    S.load(ns, "Lib/Format.lua")     -- Questing upvalues ns.Format.Clock / .Commafy at load
    S.load(ns, "Core/Module.lua")
    ns.SavedVars = { IsLoaded = function() return true end, DataSlot = function() return {} end }
    local mgr = ns._captured["DatabaseManager"]; mgr:OnInitialize()

    -- Questing registers via ns.ModuleManager:Register(self:New(...)) at load; capture the instance.
    local captured
    ns.ModuleManager = { Register = function(_, m) captured = m; return m end }
    S.load(ns, "Modules/Questing.lua")
    captured:_ContributeTables()     -- contribute the module's auto-derived settings tables...
    local db = mgr:Build()           -- ...then build the shared DB (now incl. the quest CoreTable)
    return captured, db
end

describe("Questing timed-quest registry (shared quest table)", function()
    it("_TimedSecondsStored is nil before anything is learned", function()
        local q = setup()
        assert.is_nil(q:_TimedSecondsStored(555))
    end)

    it("_RememberTimed inserts a new quest row carrying the time limit", function()
        local q, db = setup()
        q:_RememberTimed(101, 600)
        assert.are.equal(600, q:_TimedSecondsStored(101))
        assert.are.equal(1, db:Store():Count("quest"))   -- one row, freshly inserted
    end)

    it("_RememberTimed UPDATES an existing row (no duplicate), preserving its title", function()
        local q, db = setup()
        db:Insert("quest", { quest_id = 202, title = "Save the Pig" })  -- Dashboard saw it first
        assert.is_nil(q:_TimedSecondsStored(202))                        -- title alone is NOT timed
        q:_RememberTimed(202, 900)
        assert.are.equal(900, q:_TimedSecondsStored(202))
        assert.are.equal(1, db:Store():Count("quest"))                   -- still one row (upsert)
        local row = db:Select("title", "time"):From("quest"):Where("quest_id", "=", 202):Run()[1]
        assert.are.equal("Save the Pig", row.title)                      -- title kept across the upsert
        assert.are.equal(900, row.time)
    end)

    it("a re-learn overwrites the stored limit with the newer value", function()
        local q = setup()
        q:_RememberTimed(303, 300)
        q:_RememberTimed(303, 450)
        assert.are.equal(450, q:_TimedSecondsStored(303))
    end)

    it("a title-only row (NULL time) reads back as nil, not the NULL sentinel", function()
        local q, db = setup()
        db:Insert("quest", { quest_id = 404, title = "Just a turn-in" })
        assert.is_nil(q:_TimedSecondsStored(404))
    end)

    it("_RememberTimed is a no-op when the id or the seconds is missing", function()
        local q, db = setup()
        q:_RememberTimed(nil, 600)
        q:_RememberTimed(505, nil)
        assert.are.equal(0, db:Store():Count("quest"))
    end)

    it("_TimedSecondsStored returns nil for a nil questID", function()
        local q = setup()
        assert.is_nil(q:_TimedSecondsStored(nil))
    end)

    it("_TimedSeconds falls back to the stored limit when no live timer is readable", function()
        local q = setup()
        _G.C_QuestLog = nil                       -- no live in-log timer available headless
        q:_RememberTimed(606, 720)
        assert.are.equal(720, q:_TimedSeconds(606))
    end)

    it("_TimedSeconds prefers a live in-log timer over the stored limit", function()
        local q = setup()
        q:_RememberTimed(707, 720)                                   -- learned: 720s
        _G.C_QuestLog = { GetTimeAllowed = function(id) return id == 707 and 999 or 0 end }
        assert.are.equal(999, q:_TimedSeconds(707))                  -- live total wins
        _G.C_QuestLog = nil
    end)

    it("_TimedSeconds is nil for an entirely unknown quest", function()
        local q = setup()
        _G.C_QuestLog = nil
        assert.is_nil(q:_TimedSeconds(808))
    end)
end)
