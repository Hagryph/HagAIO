local S = dofile("Test/support.lua")

-- Locks Services/MinimapIcon.lua: the standalone draggable minimap button backed by a single
-- account-wide `minimap` row (id = 1). Exercised against a LIVE in-memory database wired through a
-- DatabaseManager stub. What this pins:
--   * IsShown() DEFAULTS TO FALSE with no saved row -- the deliberate INVERSE of Compartment
--     (which defaults shown). The asymmetry is the contract, so it is asserted explicitly.
--   * _Angle() precedence: a live drag-cache angle (in _p().angle) beats the saved-row angle, which
--     beats DEFAULT_ANGLE (225); and the ns.DB.isNull guard means a NULL saved angle falls through
--     to the default rather than handing back the sentinel.
--   * _Set is a singleton UPSERT: the first call inserts id = 1, every later call updates that one
--     row in place (never a second row).
--   * _OnClick routes the three mouse buttons per its matrix, with the Dashboard on/off state
--     swapping which target left/middle hit.

local DEFAULT_ANGLE = 225

local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor" }

-- The service's own `tables` spec, copied verbatim from its ServiceManager:Register opts.
local MINIMAP_TABLES = {
    minimap = { scope = "global", columns = {
        { name = "id",    type = "integer", primaryKey = true },
        { name = "shown", type = "boolean" },
        { name = "angle", type = "number" },
    } },
}

-- Fresh ns with the DB engine, a live `minimap` DB wired through a DatabaseManager stub, and the
-- MinimapIcon service captured. Returns (icon, db, ns).
local function setup()
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    local schema = ns.DB.Schema.new("M", { tables = MINIMAP_TABLES })
    local db = ns.DB.Database:New("M", schema, {})
    ns.DatabaseManager = { Shared = function() return db end, Contribute = function() end }
    S.load(ns, "Services/MinimapIcon.lua")
    return ns._captured["MinimapIcon"], db, ns
end

describe("MinimapIcon", function()
    describe("IsShown -- defaults FALSE (the inverse of Compartment)", function()
        it("is FALSE with no saved row (Compartment would default TRUE here)", function()
            local mi = setup()
            assert.is_false(mi:IsShown())   -- absent row -> hidden; the asymmetry is the whole point
        end)

        it("tracks the saved shown flag once a row exists", function()
            local mi = setup()
            mi:SetShown(true)
            assert.is_true(mi:IsShown())
            mi:SetShown(false)
            assert.is_false(mi:IsShown())   -- an explicit false row reads back false, not the default
        end)

        it("only true == shown -- a non-true stored value still reads FALSE", function()
            local mi, db = setup()
            db:Insert("minimap", { id = 1, shown = false })
            assert.is_false(mi:IsShown())
        end)
    end)

    describe("_Angle -- drag cache > saved row > DEFAULT_ANGLE", function()
        it("returns DEFAULT_ANGLE (225) when there is no row at all", function()
            local mi = setup()
            assert.are.equal(DEFAULT_ANGLE, mi:_Angle())
        end)

        it("returns the saved angle when a row carries one", function()
            local mi, db = setup()
            db:Insert("minimap", { id = 1, shown = true, angle = 90 })
            assert.are.equal(90, mi:_Angle())
        end)

        it("a live drag-cache angle wins over the saved-row angle", function()
            local mi, db = setup()
            db:Insert("minimap", { id = 1, shown = true, angle = 90 })
            mi:_p().angle = 17           -- mid-drag cache, not yet persisted
            assert.are.equal(17, mi:_Angle())
            mi:_p().angle = nil          -- drag released: saved value is authoritative again
            assert.are.equal(90, mi:_Angle())
        end)

        it("a NULL saved angle falls through to DEFAULT_ANGLE (the isNull guard)", function()
            local mi, db, ns = setup()
            -- angle absent -> projects back as DB.NULL, which the isNull guard rejects.
            db:Insert("minimap", { id = 1, shown = true })
            local r = mi:_Row()
            assert(r ~= nil)                     -- the singleton row exists...
            assert.is_true(ns.DB.isNull(r.angle)) -- ...but its saved angle really is the NULL sentinel
            assert.are.equal(DEFAULT_ANGLE, mi:_Angle())
        end)
    end)

    describe("_Set -- singleton UPSERT (one row, id = 1)", function()
        it("the first _Set inserts id = 1; a later _Set updates that same row in place", function()
            local mi, db = setup()
            mi:_Set({ shown = true, angle = 10 })
            mi:_Set({ angle = 200 })             -- merge: shown stays, angle changes
            local rows = db:Select("id", "shown", "angle"):From("minimap"):Run()
            assert.are.equal(1, #rows)           -- never a second row
            assert.are.equal(1, rows[1].id)
            assert.is_true(rows[1].shown)        -- untouched key survives the partial update
            assert.are.equal(200, rows[1].angle) -- updated in place
        end)

        it("SetShown persists through _Set without disturbing a previously saved angle", function()
            local mi, db = setup()
            mi:_Set({ angle = 42 })
            mi:SetShown(true)                    -- routes through _Set({ shown = true })
            local r = mi:_Row()
            assert.is_true(r.shown == true)
            assert.are.equal(42, r.angle)        -- the angle from the earlier row is preserved
            assert.are.equal(1, #db:Select("id"):From("minimap"):Run())
        end)
    end)

    describe("_OnClick -- the mouse-button matrix", function()
        -- Stub the three things _OnClick can reach; drive Dashboard on/off by re-stubbing GetModule.
        local function wire(ns, dashboardOn)
            local hits = { menu = nil, settings = 0, dashboard = 0 }
            ns.ModuleManager = {
                OpenContextMenu = function(_, frame) hits.menu = frame end,
                GetModule = function(_, name)
                    if name ~= "Dashboard" then return nil end
                    return {
                        IsEnabled = function() return dashboardOn end,
                        Toggle    = function() hits.dashboard = hits.dashboard + 1 end,
                    }
                end,
            }
            ns.UI.SettingsWindow = { Toggle = function() hits.settings = hits.settings + 1 end }
            return hits
        end

        it("RightButton always opens the module context menu, anchored on the button frame", function()
            local mi, _, ns = setup()
            local hits = wire(ns, false)
            local fakeButton = {}
            mi:_p().button = fakeButton
            mi:_OnClick("RightButton")
            assert.are.equal(fakeButton, hits.menu)
            assert.are.equal(0, hits.settings)
            assert.are.equal(0, hits.dashboard)
        end)

        it("LeftButton opens settings when Dashboard is OFF", function()
            local mi, _, ns = setup()
            local hits = wire(ns, false)
            mi:_OnClick("LeftButton")
            assert.are.equal(1, hits.settings)
            assert.are.equal(0, hits.dashboard)
        end)

        it("LeftButton opens the Dashboard (not settings) when it is ON", function()
            local mi, _, ns = setup()
            local hits = wire(ns, true)
            mi:_OnClick("LeftButton")
            assert.are.equal(1, hits.dashboard)
            assert.are.equal(0, hits.settings)
        end)

        it("MiddleButton opens settings ONLY while Dashboard owns left-click", function()
            local mi, _, ns = setup()
            local hits = wire(ns, true)
            mi:_OnClick("MiddleButton")
            assert.are.equal(1, hits.settings)   -- Dashboard on: middle takes over settings
            assert.are.equal(0, hits.dashboard)
        end)

        it("MiddleButton is a no-op when Dashboard is OFF", function()
            local mi, _, ns = setup()
            local hits = wire(ns, false)
            mi:_OnClick("MiddleButton")
            assert.are.equal(0, hits.settings)   -- nothing owns left-click -> middle does nothing
            assert.are.equal(0, hits.dashboard)
            assert.is_nil(hits.menu)
        end)
    end)
end)
