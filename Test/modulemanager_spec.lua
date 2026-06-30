local S = dofile("Test/support.lua")

-- Locks Core/ModuleManager.lua + the Module enable lifecycle against the REAL manager stack
-- (Registry + DependencyGraph + ModuleManager + Module) over a real in-memory database built from
-- CoreTables. The rig deliberately stubs those managers, so this spec loads the real ones. It pins:
--   * enable-state PERSISTENCE through the central module_enable table -- a saved disable/enable is
--     honoured on the next StartAll, and Enable/Disable diff-on-write against the registered default
--     (no override row when the effective state already equals the default);
--   * DEPENDENCY-ORDERED enable -- a module with a module-dep enables only while that dep is on, is
--     refused otherwise, and is disabled in cascade when the dep goes off;
--   * alwaysOn modules ignore the persisted state and can't be disabled.

local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor", "CoreTables", "DatabaseManager" }

-- Fresh ns with a real shared database (CoreTables -> module_enable/profile/config exist) and the real
-- manager machinery loaded (the rig skips it). Returns (ns, db, manager).
local function rig()
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    ns.SavedVars = { IsLoaded = function() return true end, DataSlot = function() return {} end }
    local dbm = ns._captured["DatabaseManager"]; dbm:OnInitialize()
    local db = dbm:Build()
    ns.DatabaseManager = dbm                       -- self:DB() == ns.DatabaseManager:Shared()
    S.load(ns, "Core/Registry.lua")
    S.load(ns, "Core/DependencyGraph.lua")
    S.load(ns, "Core/ModuleManager.lua")           -- self-instantiates ns.ModuleManager
    S.load(ns, "Core/Module.lua")
    return ns, db, ns.ModuleManager
end

-- A minimal feature module: no settings + no tables, so _Init contributes nothing to the already-built
-- DB. opts = { defaultEnabled, alwaysOn, moduleDeps }.
local function addModule(ns, mgr, name, opts)
    local M = ns.Class.new(name, ns.Module)
    local m = M:New(name, opts)
    mgr:Register(m)
    return m
end

-- This character's module_enable override row, or nil (absent = inherit profile/default).
local function override(db, name)
    return db:Select("name", "enabled"):From("module_enable"):Where("name", "=", name):Limit(1):Run()[1]
end

describe("ModuleManager: enable-state persistence", function()
    it("a default-enabled module with no saved state starts ENABLED, writing no override row", function()
        local ns, db, mgr = rig()
        local a = addModule(ns, mgr, "A", { defaultEnabled = true })
        mgr:StartAll()
        assert.is_true(a:IsEnabled())
        assert.is_nil(override(db, "A"))   -- effective == default true -> nothing to persist
    end)

    it("a default-disabled module with no saved state starts DISABLED", function()
        local ns, _, mgr = rig()
        local b = addModule(ns, mgr, "B", { defaultEnabled = false })
        mgr:StartAll()
        assert.is_false(b:IsEnabled())
    end)

    it("a saved DISABLE is honoured on the next start (persistence round-trip)", function()
        local ns, db, mgr = rig()
        db:Insert("module_enable", { name = "A", enabled = false })   -- a previous session turned it off
        local a = addModule(ns, mgr, "A", { defaultEnabled = true })
        mgr:StartAll()
        assert.is_false(a:IsEnabled())     -- read the persisted disable, NOT the registered default
    end)

    it("a saved ENABLE is honoured for a default-OFF module", function()
        local ns, db, mgr = rig()
        db:Insert("module_enable", { name = "B", enabled = true })    -- a previous session turned it on
        local b = addModule(ns, mgr, "B", { defaultEnabled = false })
        mgr:StartAll()
        assert.is_true(b:IsEnabled())
    end)

    it("Disable() persists the override; re-Enable() back to the default CLEARS it (diff-on-write)", function()
        local ns, db, mgr = rig()
        local a = addModule(ns, mgr, "A", { defaultEnabled = true })
        mgr:StartAll()
        assert.is_true(a:IsEnabled())
        a:Disable()
        local r = override(db, "A")
        assert(r ~= nil); assert.is_false(r.enabled)   -- a disable differs from default true -> stored
        a:Enable()
        assert.is_true(a:IsEnabled())
        assert.is_nil(override(db, "A"))               -- effective back to default -> override removed
    end)

    it("Toggle round-trips the effective state through the database", function()
        local ns, db, mgr = rig()
        local a = addModule(ns, mgr, "A", { defaultEnabled = true })
        mgr:StartAll()
        a:Toggle()                                     -- -> off
        assert.is_false(a:IsEnabled())
        assert.is_false(override(db, "A").enabled)
        a:Toggle()                                     -- -> on (== default)
        assert.is_true(a:IsEnabled())
        assert.is_nil(override(db, "A"))
    end)

    it("an alwaysOn module enables despite a saved disable, and ignores Disable()", function()
        local ns, db, mgr = rig()
        db:Insert("module_enable", { name = "M", enabled = false })   -- would disable a normal module
        local m = addModule(ns, mgr, "M", { alwaysOn = true })
        mgr:StartAll()
        assert.is_true(m:IsEnabled())                  -- mandatory: persisted state ignored
        m:Disable()
        assert.is_true(m:IsEnabled())                  -- can't be turned off
    end)
end)

describe("ModuleManager: dependency-ordered enable", function()
    it("StartAll enables a dependent once its module-dep is on (registration order)", function()
        local ns, _, mgr = rig()
        local a = addModule(ns, mgr, "A", { defaultEnabled = true })
        local b = addModule(ns, mgr, "B", { defaultEnabled = true, moduleDeps = { "A" } })
        mgr:StartAll()                                 -- A first (no deps), then B (its dep A is on)
        assert.is_true(a:IsEnabled())
        assert.is_true(b:IsEnabled())
    end)

    it("a dependent is REFUSED enable while its dep is off, then allowed once the dep is on", function()
        local ns, db, mgr = rig()
        db:Insert("module_enable", { name = "A", enabled = false })   -- A starts disabled
        local a = addModule(ns, mgr, "A", { defaultEnabled = true })
        local b = addModule(ns, mgr, "B", { defaultEnabled = true, moduleDeps = { "A" } })
        mgr:StartAll()
        assert.is_false(a:IsEnabled())
        assert.is_false(b:IsEnabled())                 -- dep unmet -> B stays off even though default true
        a:Enable()
        b:Enable()
        assert.is_true(b:IsEnabled())                  -- dep now met -> B may enable
    end)

    it("disabling a dep CASCADES: its dependents are disabled too", function()
        local ns, _, mgr = rig()
        local a = addModule(ns, mgr, "A", { defaultEnabled = true })
        local b = addModule(ns, mgr, "B", { defaultEnabled = true, moduleDeps = { "A" } })
        mgr:StartAll()
        assert.is_true(b:IsEnabled())
        a:Disable()                                    -- DisableDependents("A") -> B
        assert.is_false(a:IsEnabled())
        assert.is_false(b:IsEnabled())                 -- cascade: a dependent can't outlive its dep
    end)
end)
