local S = dofile("Test/support.lua")

local function build()
    local ns = S.newNs()
    local module
    ns.ModuleManager = {
        Register = function(_, value) module = value; return value end,
    }
    S.load(ns, "Lib/Color.lua")
    S.load(ns, "Lib/ColorCurve.lua")
    S.load(ns, "Core/Module.lua")
    S.load(ns, "Modules/Skins.lua")
    S.load(ns, "Modules/Skins/HealthBarSkin.lua")
    return ns, module
end

describe("Skin lifecycle", function()
    it("is abstract and guards Load/Unload transitions", function()
        local ns, owner = build()
        assert.has_error(function() ns.Skin:New(owner) end)

        local calls = {}
        local TestSkin = ns.Class.new("TestSkin", ns.Skin, {
            statics = { key = "test", label = "Test", settings = {} },
        })
        function TestSkin:OnLoad() calls[#calls + 1] = "load" end
        function TestSkin:OnUnload() calls[#calls + 1] = "unload" end

        local skin = TestSkin:New(owner)
        assert.is_true(skin:Load())
        assert.is_false(skin:Load())
        assert.is_true(skin:IsLoaded())
        assert.is_true(skin:Unload())
        assert.is_false(skin:Unload())
        assert.is_false(skin:IsLoaded())
        assert.are.equal("load", calls[1])
        assert.are.equal("unload", calls[2])
        assert.are.equal(2, #calls)
    end)

    it("rolls a failed load back through OnUnload", function()
        local ns, owner = build()
        local cleaned = false
        local BrokenSkin = ns.Class.new("BrokenSkin", ns.Skin, {
            statics = { key = "broken", label = "Broken", settings = {} },
        })
        function BrokenSkin:OnLoad() error("load failed") end
        function BrokenSkin:OnUnload() cleaned = true end

        local skin = BrokenSkin:New(owner)
        assert.has_error(function() skin:Load() end)
        assert.is_true(cleaned)
        assert.is_false(skin:IsLoaded())
    end)
end)

describe("Skins settings schema", function()
    it("builds shared health-bar options for every registered skin", function()
        local ns, module = build()
        local TestSkin = ns.Class.new("TestSkin", ns.HealthBarSkin, {
            statics = {
                key = "test",
                label = "Test Skin",
                default = true,
                settings = {
                    { type = "toggle", key = "effect", label = "Effect", default = true },
                },
            },
        })
        function TestSkin:CreateHealthBarView() end
        module:RegisterHealthBarSkin(TestSkin:New(module))

        local schema = module:GetSettings()
        assert.are.equal("HealthBar Skin", schema[1].text)
        assert.are.equal("dropdown", schema[2].type)
        assert.are.equal("test", schema[2].default)
        assert.are.equal("none", schema[2].options[1].value)
        assert.are.equal("No Skin", schema[2].options[1].text)
        assert.are.equal("test", schema[2].options[2].value)
        assert.are.equal("healthBarPlayer", schema[3].key)
        assert.is_true(schema[3].default)
        assert.are.equal("none", schema[3].visibleWhen.notEquals)
        assert.are.equal("healthBarTarget", schema[4].key)
        assert.are.equal("healthBarFocus", schema[5].key)
        assert.are.equal("healthBarPet", schema[6].key)
        assert.are.equal("healthBarNameplates", schema[7].key)
        assert.is_false(schema[7].default)
        for i = 3, 12 do assert.are.equal("none", schema[i].visibleWhen.notEquals) end
        assert.are.equal("Health Colors", schema[8].text)
        assert.are.equal("none", schema[8].visibleWhen.notEquals)
        assert.are.equal("endColor", schema[9].key)
        assert.are.equal("midColor", schema[10].key)
        assert.are.equal("startColor", schema[11].key)
        assert.are.equal("note", schema[12].type)
        assert.are.equal("toggle", schema[13].type)
        assert.is_nil(schema[13].dependsOn)
        assert.are.equal("healthBarSkin", schema[13].visibleWhen.key)
        assert.are.equal("test", schema[13].visibleWhen.equals)
    end)
end)
