local S = dofile("Test/support.lua")

-- Locks Services/Compartment.lua: the addon-compartment registration service.
-- Exercised against a LIVE in-memory database (the singleton `compartment` row drives IsShown),
-- with _G.AddonCompartmentFrame stubbed so registration is observable + controllable. Pins:
--   * IsShown defaults to TRUE with no saved row (and follows the stored boolean once set);
--   * SetShown(true) upserts + returns false (icon adds immediately, no reload); SetShown(false)
--     AFTER a successful Register() returns true (compartment API has no unregister -> /reload);
--   * Register() is idempotent (one RegisterAddon call) AND a safe no-op when the compartment
--     frame is absent (old client);
--   * OnClick routes Left/Right/Middle to the correct action per the service's matrix.

local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor" }

-- Fresh ns with the DB engine, a live `compartment` DB wired through a DatabaseManager stub, and
-- the Compartment service. The DB starts EMPTY (no row) so IsShown's default path is the baseline.
local function setup()
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    local schema = ns.DB.Schema.new("C", { tables = {
        compartment = { scope = "global", columns = {
            { name = "id",    type = "integer", primaryKey = true },
            { name = "shown", type = "boolean" },
        } },
    } })
    local db = ns.DB.Database:New("C", schema, {})
    ns.DatabaseManager = { Shared = function() return db end, Contribute = function() end }
    -- EventBus is a dep but OnInitialize only uses it to defer Register to PLAYER_LOGIN; the specs
    -- drive Register/OnClick directly, so a record-only On is all that's needed.
    ns.EventBus = { On = function() end }
    S.load(ns, "Services/Compartment.lua")
    local c = ns._captured["Compartment"]
    c:OnInitialize()                      -- as on login: seeds registered = false
    return c, db, ns
end

-- A controllable AddonCompartmentFrame: counts RegisterAddon calls and keeps the last opts so the
-- registered func/funcOnEnter can be invoked. Installed as the global; pass present=false to model
-- a client with no compartment (the global stays nil).
local function stubCompartment(present)
    if present == false then _G.AddonCompartmentFrame = nil; return nil end
    local frame = { calls = 0, opts = nil }
    function frame:RegisterAddon(opts) self.calls = self.calls + 1; self.opts = opts end
    _G.AddonCompartmentFrame = frame
    return frame
end

describe("Compartment", function()
    describe("IsShown / the singleton config row", function()
        it("defaults to TRUE when there is no saved row", function()
            local c = setup()
            assert.is_true(c:IsShown())
        end)

        it("follows the stored boolean once a row exists (false hides, true shows)", function()
            local c, db = setup()
            db:Insert("compartment", { id = 1, shown = false })
            assert.is_false(c:IsShown())
            db:Update("compartment", { shown = true }, function(x) return x.id == 1 end)
            assert.is_true(c:IsShown())
        end)
    end)

    describe("SetShown: upsert + reload-needed contract", function()
        it("SetShown(true) upserts the row and returns false (icon adds now, no reload)", function()
            local c, db = setup()
            stubCompartment()
            assert.is_false(c:SetShown(true))                 -- adding takes effect immediately
            local rows = db:Select("shown"):From("compartment"):Where("id", "=", 1):Run()
            assert.are.equal(1, #rows)                        -- exactly one singleton row
            assert.is_true(rows[1].shown)                     -- persisted as shown
        end)

        it("a second SetShown UPDATES the same row, never inserts a duplicate", function()
            local c, db = setup()
            stubCompartment()
            c:SetShown(true)
            c:SetShown(false)
            local rows = db:Select("id"):From("compartment"):Where("id", "=", 1):Run()
            assert.are.equal(1, #rows)                        -- upsert, not insert-twice
        end)

        it("SetShown(false) BEFORE any Register returns false (nothing was added to remove)", function()
            local c = setup()
            stubCompartment()
            assert.is_false(c:SetShown(false))                -- never registered this session -> no reload
        end)

        it("SetShown(false) AFTER a successful Register returns true (reload required to remove)", function()
            local c, db = setup()
            stubCompartment()
            c:Register()                                      -- button is now live this session
            assert.is_true(c:SetShown(false))                 -- compartment has no unregister -> /reload
            local rows = db:Select("shown"):From("compartment"):Where("id", "=", 1):Run()
            assert.is_false(rows[1].shown)                    -- but the setting IS persisted off
        end)
    end)

    describe("Register: idempotent + safe without the compartment", function()
        it("registers the addon-compartment entry exactly once across repeated calls", function()
            local c = setup()
            local frame = stubCompartment()
            c:Register()
            c:Register()
            c:Register()
            assert.are.equal(1, frame.calls)                  -- the registered latch holds
            assert.are.equal("HagAIO", frame.opts.text)       -- and it registered OUR entry
        end)

        it("honours the visibility setting -- does not register while hidden", function()
            local c, db = setup()
            local frame = stubCompartment()
            db:Insert("compartment", { id = 1, shown = false })
            c:Register()
            assert.are.equal(0, frame.calls)                  -- IsShown() == false short-circuits
        end)

        it("is a safe no-op when _G.AddonCompartmentFrame is absent (old client)", function()
            local c = setup()
            stubCompartment(false)                            -- no compartment global
            assert.is_true(pcall(function() c:Register() end)) -- no error, just skips
            -- and because it never registered, a later hide needs no reload:
            stubCompartment(false)
            assert.is_false(c:SetShown(false))
        end)
    end)

    describe("OnClick: routes mouse buttons to the right action", function()
        -- Spy targets: capture which action fired without pulling in the real UI / ModuleManager.
        local function wire(ns)
            local calls = { settingsToggle = 0, contextMenu = 0, contextOwner = nil }
            ns.UI.SettingsWindow = { Toggle = function() calls.settingsToggle = calls.settingsToggle + 1 end }
            ns.ModuleManager = {
                OpenContextMenu = function(_, owner) calls.contextMenu = calls.contextMenu + 1; calls.contextOwner = owner end,
                GetModule = function() return nil end,   -- no Dashboard module -> left-click = settings
            }
            return calls
        end

        it("LeftButton opens the settings window (no Dashboard active)", function()
            local c, _, ns = setup()
            local calls = wire(ns)
            c:OnClick("LeftButton")
            assert.are.equal(1, calls.settingsToggle)
            assert.are.equal(0, calls.contextMenu)
        end)

        it("RightButton opens the module context menu on the passed owner", function()
            local c, _, ns = setup()
            local calls = wire(ns)
            local owner = { tag = "owner-frame" }
            c:OnClick("RightButton", owner)
            assert.are.equal(1, calls.contextMenu)
            assert.are.equal(owner, calls.contextOwner)       -- routed to the clicked frame
            assert.are.equal(0, calls.settingsToggle)
        end)

        it("MiddleButton does NOTHING while no Dashboard owns left-click", function()
            local c, _, ns = setup()
            local calls = wire(ns)
            c:OnClick("MiddleButton")
            assert.are.equal(0, calls.settingsToggle)         -- middle is a no-op without Dashboard
            assert.are.equal(0, calls.contextMenu)
        end)

        it("an unknown button name falls through to the LEFT action (settings)", function()
            local c, _, ns = setup()
            local calls = wire(ns)
            c:OnClick("Button4")                              -- not Right/Middle -> the else branch
            assert.are.equal(1, calls.settingsToggle)
            assert.are.equal(0, calls.contextMenu)
        end)
    end)
end)
