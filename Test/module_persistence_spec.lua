local S = dofile("Test/support.lua")

-- Locks the persistence model:
--   * a module's SETTINGS + ENABLE state are a per-character OVERRIDE/diff layer (cascade over the
--     loaded profile + code defaults), stored only when they differ from that baseline, and
--   * its declarative dbSchema/dbDefaults DATA lives ACCOUNT-WIDE (or per-char with dataPerChar).
local function setup()
    _G.HagAIODB = nil
    _G.HagAIOCharDB = nil
    local ns = S.newNs()
    S.load(ns, "Services/SavedVars.lua")
    S.load(ns, "Core/Module.lua")
    local sv = ns._captured["SavedVars"]; sv:OnInitialize(); sv:Load()

    local M = ns.Class.new("PersistTestModule", ns.Module)
    local m = M:New("Foo", {
        settings = { { type = "toggle", key = "opt", label = "Opt", default = true } },  -- per-character config
        dbSchema = { flights = {} },                                                       -- account-wide data
    })
    m:_BindDB()
    return ns, sv, m
end

describe("Module persistence cascade", function()
    it("settings resolve to the code default until the character overrides them", function()
        local ns, sv, m = setup()
        assert.are.equal(true, m:GetSetting("opt"))            -- default layer
        assert.is_nil(sv:Char().overrides.module_Foo)          -- nothing stored yet
        m:SetSetting("opt", false)
        assert.are.equal(false, sv:Char().overrides.module_Foo.opt)  -- stored as a diff
        assert.are.equal(false, m:GetSetting("opt"))
        m:SetSetting("opt", true)                              -- back to the default
        assert.is_nil(sv:Char().overrides.module_Foo)          -- override dropped
    end)

    it("enable state cascades per character (registered defaultEnabled is the baseline)", function()
        local ns, sv, m = setup()
        assert.is_true(sv:GetModuleState("Foo"))               -- module default-enabled
        sv:SetModuleState("Foo", true)                         -- equals default -> no override
        assert.is_nil(sv:Char().overrides.modules)
        sv:SetModuleState("Foo", false)
        assert.is_false(sv:GetModuleState("Foo"))
        assert.is_false(sv:Char().overrides.modules.Foo)
    end)

    it("GetDB returns the account-wide data store (where flight routes live)", function()
        local ns, sv, m = setup()
        m:GetDB().flights.RouteA = 42
        assert.are.equal(42, sv:Global().module_Foo.flights.RouteA)
    end)

    it("dataPerChar=true stores the data namespace per character", function()
        local ns, sv = setup()
        local M = ns.Class.new("PerCharDataModule", ns.Module)
        local m = M:New("Bar", {
            settings = { { type = "toggle", key = "opt", label = "Opt", default = true } },
            dbSchema = { items = {} },
            dataPerChar = true,
        })
        m:_BindDB()
        m:GetDB().items.X = 1
        assert.are.equal(1, sv:Char().module_Bar.items.X)   -- data -> char DB
        assert.is_nil(sv:Global().module_Bar)               -- nothing in the account DB
    end)
end)
