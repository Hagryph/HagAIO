local S = dofile("Test/support.lua")

local function setup()
    _G.HagAIODB = nil
    _G.HagAIOCharDB = nil
    -- identity serializer stub (round-trips via a registry)
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
    it("Snapshot deep-copies config but excludes the profiles map", function()
        local pr, sv = setup()
        local g = sv:Global()
        g.module_Foo = { x = 1 }
        g.modules = { Foo = true }
        g.profiles = { existing = {} }
        local snap = pr:Snapshot()
        assert.are.equal(1, snap.module_Foo.x)
        assert.is_true(snap.modules.Foo)
        assert.is_nil(snap.profiles)
        snap.module_Foo.x = 99            -- deep copy: live config untouched
        assert.are.equal(1, g.module_Foo.x)
    end)

    it("Save / List / Get / Has / Delete", function()
        local pr, sv = setup()
        sv:Global().module_Foo = { x = 1 }
        assert.is_true((pr:Save("A")))
        assert.are.equal("A", pr:List()[1])
        assert.is_true(pr:Has("A"))
        assert.are.equal(1, pr:Get("A").module_Foo.x)
        assert.is_true((pr:Delete("A")))
        assert.is_false(pr:Has("A"))
    end)

    it("_ApplyData overwrites live config in place, keeping table identity", function()
        local pr, sv = setup()
        local g = sv:Global()
        g.module_Foo = { x = 1, keep = 2 }
        local liveRef = g.module_Foo
        pr:_ApplyData({ module_Foo = { x = 9 } })
        assert.are.equal(liveRef, g.module_Foo)   -- same table, cleared + copied
        assert.are.equal(9, g.module_Foo.x)
        assert.is_nil(g.module_Foo.keep)          -- dropped
    end)

    it("_ApplyData preserves the profiles map", function()
        local pr, sv = setup()
        local g = sv:Global()
        g.profiles = { saved = { module_Foo = { x = 1 } } }
        pr:_ApplyData({ module_Bar = { y = 1 } })
        assert.is_true(g.profiles.saved ~= nil)
        assert.are.equal(1, g.module_Bar.y)
    end)

    it("Export then Import round-trips a profile", function()
        local pr, sv = setup()
        sv:Global().module_Foo = { x = 7 }
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

    it("Save with an existing name overwrites it (single entry)", function()
        local pr, sv = setup()
        sv:Global().module_Foo = { x = 1 }
        pr:Save("A")
        sv:Global().module_Foo.x = 2
        pr:Save("A")
        assert.are.equal(1, #pr:List())
        assert.are.equal(2, pr:Get("A").module_Foo.x)
    end)

    it("List is sorted", function()
        local pr = setup()
        pr:Save("Beta"); pr:Save("Gamma"); pr:Save("Alpha")
        local l = pr:List()
        assert.are.equal("Alpha", l[1])
        assert.are.equal("Beta", l[2])
        assert.are.equal("Gamma", l[3])
    end)

    it("the global profile is exclusive and clears when deleted", function()
        local pr = setup()
        pr:Save("A"); pr:Save("B")
        pr:SetGlobal("A")
        assert.is_true(pr:IsGlobal("A"))
        pr:SetGlobal("B")               -- exclusive: A no longer global
        assert.is_false(pr:IsGlobal("A"))
        assert.is_true(pr:IsGlobal("B"))
        pr:Delete("B")
        assert.is_nil(pr:GetGlobal())   -- dangling global cleared
    end)

    it("ApplyGlobalForFreshChar applies the global once, then no-ops", function()
        local pr, sv = setup()
        sv:Global().module_Foo = { x = 1 }
        pr:Save("A")
        sv:Global().module_Foo.x = 2     -- diverge the live config
        pr:SetGlobal("A")
        assert.are.equal("A", pr:ApplyGlobalForFreshChar())
        assert.are.equal(1, sv:Global().module_Foo.x)   -- global re-applied
        assert.is_nil(pr:ApplyGlobalForFreshChar())     -- char already has a profile
    end)
end)
