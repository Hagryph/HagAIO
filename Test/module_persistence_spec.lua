local S = dofile("Test/support.lua")

-- Locks the persistence split (the reason profiles + a global profile make sense):
--   * a module's SETTINGS (schema values) + ENABLE state live PER CHARACTER, and
--   * its declarative dbSchema/dbDefaults DATA lives ACCOUNT-WIDE.
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
        dbSchema = { flights = {} },                                       -- account-wide data
    })
    m:_BindDB()
    return ns, sv, m
end

describe("Module persistence split", function()
    it("seeds settings defaults into the per-character root, not the account root", function()
        local ns, sv, m = setup()
        assert.are.equal(true, sv:Char().module_Foo.opt)   -- settings default -> char DB
        assert.is_nil(sv:Global().module_Foo.opt)          -- not in the account DB
    end)

    it("seeds dbSchema data into the account root, not the per-character root", function()
        local ns, sv, m = setup()
        assert.are.equal("table", type(sv:Global().module_Foo.flights))  -- data default -> account DB
        assert.is_nil(sv:Char().module_Foo.flights)        -- not in the char DB
    end)

    it("GetSetting/SetSetting read+write the per-character settings store", function()
        local ns, sv, m = setup()
        assert.are.equal(true, m:GetSetting("opt"))
        m:SetSetting("opt", false)
        assert.are.equal(false, sv:Char().module_Foo.opt)  -- written to char DB
    end)

    it("GetDB returns the account-wide data store (where flight routes live)", function()
        local ns, sv, m = setup()
        m:GetDB().flights.RouteA = 42
        assert.are.equal(42, sv:Global().module_Foo.flights.RouteA)
        assert.is_nil(rawget(sv:Char().module_Foo, "flights"))
    end)

    it("dataPerChar=true stores the data namespace per character (e.g. the task list)", function()
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
