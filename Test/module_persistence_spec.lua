local S = dofile("Test/support.lua")

-- Locks the persistence model: a module's SETTINGS are ordinary database rows now. Each module
-- auto-contributes a settings-table pair from its schema; GetSetting/SetSetting resolve + persist the
-- override -> profile -> default cascade against those tables (see Lib/SettingsTables.lua). Enable-state
-- lives in the central module_enable tables. A module's account-wide DATA goes through the shared
-- Database too (declarative `tables` + self:DB()); that path is covered by the db_* specs.
local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor", "CoreTables", "DatabaseManager" }

local function setup()
    _G.HagAIODB = nil
    _G.HagAIOCharDB = nil
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    S.load(ns, "Lib/SettingsTables.lua")
    S.load(ns, "Core/Module.lua")
    local slots = {}
    ns.SavedVars = { IsLoaded = function() return true end,
                     DataSlot = function(_, name) slots[name] = slots[name] or {}; return slots[name] end }
    local mgr = ns._captured["DatabaseManager"]; mgr:OnInitialize()

    local M = ns.Class.new("PersistTestModule", ns.Module)
    local m = M:New("Foo", {
        settings = { { type = "toggle", key = "opt", label = "Opt", default = true } },  -- per-character config
    })
    m:_ContributeTables()   -- contribute the auto-derived settings tables, then build
    mgr:Build()
    return ns, m, mgr:Shared()
end

describe("Module persistence", function()
    it("auto-contributes a settings table pair from its schema", function()
        local _, _, db = setup()
        assert.is_true(db:Schema():HasTable("o_module_Foo"))   -- this char's overrides
        assert.is_true(db:Schema():HasTable("p_module_Foo"))   -- per-profile values
    end)

    it("settings resolve to the code default; a change persists to the database", function()
        local _, m, db = setup()
        assert.are.equal(true, m:GetSetting("opt"))            -- default (no row yet)
        m:SetSetting("opt", false)
        assert.are.equal(false, m:GetSetting("opt"))           -- read back from the override row
        assert.are.equal(1, db:Store():Count("o_module_Foo"))  -- persisted as a row
    end)

    it("enable-state defaults to the registered defaultEnabled (cascade over module_enable)", function()
        local ns, m, db = setup()
        assert.is_true(ns.SettingsTables:GetModuleEnabled(db, "Foo", m:IsDefaultEnabled()))
    end)
end)
