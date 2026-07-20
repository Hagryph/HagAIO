local S = dofile("Test/support.lua")

-- Locks Services/Versioning.lua: the shared data-version registry (one typed row per domain in the
-- data_version table). Get / Stamp / IsCurrent are exercised against a LIVE in-memory database, with
-- GetBuildInfo stubbed so the "running client build" is controllable. Also pins the dev-skip
-- (DEBUG_FORCE_STALE) INTENDED behaviour: it forces the rebuild path only while the Logger debug flag is
-- on (dev characters), and is a no-op for every shipped user (debug off) -- so the cache works as designed.

local DB_FILES = { "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor" }

-- Fresh ns with the DB engine, a live data_version DB wired through a DatabaseManager stub, and the
-- Versioning service. GetBuildInfo reports (patch, build) as the running client.
local function setup(build, patch)
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    local schema = ns.DB.Schema.new("V", { tables = {
        data_version = { scope = "global", columns = {
            { name = "domain", type = "text",    primaryKey = true },
            { name = "build",  type = "integer" },
            { name = "patch",  type = "text" },
        } },
    } })
    local db = ns.DB.Database:New("V", schema, {})
    ns.DatabaseManager = { Shared = function() return db end, Contribute = function() end }
    _G.GetBuildInfo = function() return patch or "12.0.5", build or 120005, "Jun 30 2026", build or 120005 end
    S.load(ns, "Services/Versioning.lua")
    return ns._captured["Versioning"], db, ns
end

describe("Versioning", function()
    it("Build / Patch reflect the running client's GetBuildInfo (numeric toc vs human version)", function()
        local v = setup(120005, "12.0.5")
        assert.are.equal(120005, v:Build())
        assert.are.equal("12.0.5", v:Patch())
    end)

    it("Get returns nil before a domain is ever stamped", function()
        local v = setup()
        assert.is_nil(v:Get("dashboard_catalog"))
    end)

    it("Stamp records build + patch; Get reads them back", function()
        local v = setup(120005, "12.0.5")
        v:Stamp("dashboard_catalog")
        local r = v:Get("dashboard_catalog")
        assert.are.equal(120005, r.build)
        assert.are.equal("12.0.5", r.patch)
    end)

    it("Get collapses NULL / absent columns to nil (not the DB.NULL sentinel)", function()
        local v, db = setup()
        db:Insert("data_version", { domain = "partial" })   -- build + patch left absent (NULL)
        local r = v:Get("partial")
        assert(r ~= nil)                                     -- the row exists...
        assert.is_nil(r.build)                              -- ...but the NULL cells read back as plain nil
        assert.is_nil(r.patch)
    end)

    it("a second Stamp UPDATES the existing row, never inserts a duplicate", function()
        local v, db = setup(120005, "12.0.5")
        v:Stamp("d")
        v:Stamp("d")
        local rows = db:Select("domain"):From("data_version"):Where("domain", "=", "d"):Run()
        assert.are.equal(1, #rows)   -- one row per domain, upsert not insert-twice
    end)

    it("IsCurrent: false before stamp, true under the same build, false after a patch bumps the build", function()
        local v = setup(120005, "12.0.5")
        assert.is_false(v:IsCurrent("d"))           -- never stamped
        v:Stamp("d")
        assert.is_true(v:IsCurrent("d"))            -- stamped under the running build
        _G.GetBuildInfo = function() return "12.0.7", 120007, "x", 120007 end   -- a new patch ships
        assert.is_false(v:IsCurrent("d"))           -- stale -> the owner takes the rebuild path
    end)

    it("the debug flag forces stale (intended dev-skip), but only while it is on", function()
        local v, _, ns = setup(120005, "12.0.5")
        v:Stamp("d")
        assert.is_true(v:IsCurrent("d"))            -- debug off (every shipped user): cache honoured
        ns.Logger.GetDebug = function() return true end
        assert.is_false(v:IsCurrent("d"))           -- debug on (dev char): forced rebuild every login
        ns.Logger.GetDebug = function() return false end
        assert.is_true(v:IsCurrent("d"))            -- and back to normal
    end)
end)
