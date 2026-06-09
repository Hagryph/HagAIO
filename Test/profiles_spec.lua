local S = dofile("Test/support.lua")

local function setup()
    _G.HagAIODB = nil
    _G.HagAIOCharDB = nil
    local store, n = {}, 0
    _G.C_EncodingUtil = {
        SerializeCBOR = function(v) n = n + 1; local id = "c" .. n; store[id] = v; return id end,
        DeserializeCBOR = function(s) return store[s] end,
        CompressString = function(s) return s end,
        DecompressString = function(s) return s end,
        EncodeBase64 = function(s) return s end,
        DecodeBase64 = function(s) return s end,
    }
    local ns = S.newNs()
    ns.SlashCommand = { Register = function() end }
    ns.UI.CopyWindow = { Show = function() end }
    ns.ModuleManager = { Iterate = function() return function() return nil end end }
    S.load(ns, "Services/SavedVars.lua")
    S.load(ns, "Services/Serializer.lua")
    S.load(ns, "Services/Profiles.lua")
    local sv = ns._captured["SavedVars"]; sv:OnInitialize(); sv:Load()
    ns._captured["Serializer"]:OnInitialize()
    local pr = ns._captured["Profiles"]; pr:OnInitialize()
    return pr, sv
end

describe("Profiles", function()
    it("Save snapshots the live config as diffs from default", function()
        local pr, sv = setup()
        sv:SettingsView("module_Foo", { x = 1, y = 2 })
        sv:SetSetting("module_Foo", "x", 9)
        assert.is_true((pr:Save("A")))
        local p = pr:Get("A")
        assert.are.equal(9, p.module_Foo.x)
        assert.is_nil(p.module_Foo.y)              -- unchanged from default -> not stored
    end)

    it("List / Has / Get / Delete", function()
        local pr, sv = setup()
        sv:SettingsView("module_Foo", { x = 1 })
        pr:Save("A")
        assert.are.equal("A", pr:List()[1])
        assert.is_true(pr:Has("A"))
        assert.is_true((pr:Delete("A")))
        assert.is_false(pr:Has("A"))
    end)

    it("LoadProfile wipes overrides and resolves the live config to the profile", function()
        local pr, sv = setup()
        sv:Global().profiles.A = { module_Foo = { x = 5 } }
        sv:SettingsView("module_Foo", { x = 1, y = 2 })
        sv:SetSetting("module_Foo", "y", 8)            -- a live override
        assert.is_true((pr:LoadProfile("A")))
        assert.are.equal("A", sv:LoadedProfile())
        assert.are.equal(5, sv:GetSetting("module_Foo", "x"))  -- from the profile
        assert.are.equal(2, sv:GetSetting("module_Foo", "y"))  -- override wiped -> default
    end)

    it("ApplyGlobalForFreshChar points an unconfigured char at the global (before bind)", function()
        local pr, sv = setup()
        sv:Global().profiles.G = { module_Foo = { x = 7 } }
        pr:SetGlobal("G")
        assert.are.equal("G", pr:ApplyGlobalForFreshChar())    -- sets the pointer
        sv:SettingsView("module_Foo", { x = 1, y = 2 })         -- then bind -> materialise
        assert.are.equal(7, sv:GetSetting("module_Foo", "x"))   -- from the global profile
        assert.is_nil(pr:ApplyGlobalForFreshChar())             -- already pointed at one
    end)

    it("auto-applying the global fills unset vars but keeps stored overrides", function()
        local pr, sv = setup()
        sv:Char().overrides.module_Foo = { y = 4 }     -- stored from a prior session
        sv:Global().profiles.G = { module_Foo = { x = 7 } }
        pr:SetGlobal("G")
        pr:ApplyGlobalForFreshChar()
        sv:SettingsView("module_Foo", { x = 1, y = 2 })
        assert.are.equal(7, sv:GetSetting("module_Foo", "x"))  -- from the global profile
        assert.are.equal(4, sv:GetSetting("module_Foo", "y"))  -- override preserved
    end)

    it("Export then Import round-trips a profile", function()
        local pr, sv = setup()
        sv:SettingsView("module_Foo", { x = 1 })
        sv:SetSetting("module_Foo", "x", 7)
        pr:Save("A")
        local str = pr:Export("A")
        assert.is_true(type(str) == "string")
        pr:Delete("A")
        local ok, name = pr:Import(str, "B")
        assert.is_true(ok)
        assert.are.equal("B", name)
        assert.are.equal(7, pr:Get("B").module_Foo.x)
    end)

    it("Import rejects a bad string", function()
        local pr = setup()
        local ok, err = pr:Import("garbage", "X")
        assert.is_false(ok)
        assert.is_true(type(err) == "string")
    end)

    it("the global profile is exclusive and clears when deleted", function()
        local pr, sv = setup()
        sv:SettingsView("module_Foo", { x = 1 })
        pr:Save("A"); pr:Save("B")
        pr:SetGlobal("A")
        assert.is_true(pr:IsGlobal("A"))
        pr:SetGlobal("B")
        assert.is_false(pr:IsGlobal("A"))
        assert.is_true(pr:IsGlobal("B"))
        pr:Delete("B")
        assert.is_nil(pr:GetGlobal())
    end)

    it("Deleting the profile this character has loaded clears its loaded pointer", function()
        local pr, sv = setup()
        sv:SettingsView("module_Foo", { x = 1 })
        pr:Save("A")
        pr:LoadProfile("A")
        assert.are.equal("A", sv:LoadedProfile())
        pr:Delete("A")
        assert.is_nil(sv:LoadedProfile())
    end)
end)
