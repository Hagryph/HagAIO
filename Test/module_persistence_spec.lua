local S = dofile("Test/support.lua")

-- Locks the persistence model: a module's SETTINGS + ENABLE state are held in the live config for
-- the session and written back to this character as DIFFS on Flush (logout). A module's account-wide
-- DATA no longer lives in a private saved-var namespace -- it goes through the shared Database
-- (declarative `tables` + self:DB()); that path is covered by the db_* specs.
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
    })
    m:_BindDB()
    return ns, sv, m
end

describe("Module persistence", function()
    it("settings resolve to the code default; a change is written back as a diff on flush", function()
        local ns, sv, m = setup()
        assert.are.equal(true, m:GetSetting("opt"))            -- default (materialised)
        m:SetSetting("opt", false)
        assert.are.equal(false, m:GetSetting("opt"))           -- live
        assert.is_nil(sv:Char().overrides.module_Foo)          -- not persisted yet
        sv:Flush()
        assert.are.equal(false, sv:Char().overrides.module_Foo.opt)  -- diff written
    end)

    it("enable state cascades (registered defaultEnabled is the baseline)", function()
        local ns, sv, m = setup()
        assert.is_true(sv:GetModuleState("Foo"))               -- module default-enabled
        sv:SetModuleState("Foo", false); sv:Flush()
        assert.is_false(sv:GetModuleState("Foo"))
        assert.is_false(sv:Char().overrides.modules.Foo)
    end)
end)
