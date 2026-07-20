local S = dofile("Test/support.lua")

-- The Class module surfaces the CURRENT spec's settings on its page. They must resolve from the
-- registered spec even while the module is disabled (its spec submodule -- and thus activeSub --
-- isn't loaded), so a player can see/configure spec options without enabling the module first.
local function setup()
    _G.UnitClass = function() return "Monk", "MONK" end
    _G.GetSpecialization = nil   -- -> CurrentSpecKey() == "none"
    local ns = S.newNs()
    ns.ModuleManager = {
        Register = function(_, m) ns._captured[m:GetName()] = m; return m end,
        GetModule = function() return nil end,
    }
    S.load(ns, "Core/Module.lua")     -- ns.Module (Class module's base) isn't auto-loaded
    S.load(ns, "Modules/Class.lua")
    return ns, ns._captured["Class"]
end

describe("Class module spec settings", function()
    it("keeps each spec schema in its declaring subclass's private static store", function()
        local ns = setup()
        local A = ns.Class.new("SpecA", ns.ClassSpec, {
            statics = { settings = { { type = "note", text = "A" } } },
        })
        local B = ns.Class.new("SpecB", ns.ClassSpec, {
            statics = { settings = { { type = "note", text = "B" } } },
        })
        local a, b = A:New({}), B:New({})
        assert.are.equal("A", a:GetSettings()[1].text)
        assert.are.equal("B", b:GetSettings()[1].text)
        assert.is_nil(A.settings)
        assert.is_nil(B.settings)
    end)

    it("GetSettings resolves the registered spec for the current spec without it being loaded", function()
        local ns, mod = setup()
        local specSettings = { { type = "toggle", key = "x", label = "X", default = true } }
        mod:RegisterSpec("none", { GetSettings = function() return specSettings end })
        assert.is_nil(mod:_p().activeSub)                 -- nothing loaded
        local s = mod:GetSettings()
        assert.are.equal("x", s[1].key)                   -- the spec's option still shows
    end)

    it("falls back to a placeholder note when no spec matches the current spec", function()
        local ns, mod = setup()
        local s = mod:GetSettings()
        assert.are.equal("note", s[1].type)
    end)

    it("prefers the loaded activeSub over the registry", function()
        local ns, mod = setup()
        mod:RegisterSpec("none", { GetSettings = function() return { { type = "note", text = "registry" } } end })
        mod:SetActiveSpec({ GetSettings = function() return { { type = "note", text = "loaded" } } end })
        assert.are.equal("loaded", mod:GetSettings()[1].text)
    end)

    it("caches the current spec until the spec-change refresh", function()
        local current = 2
        local _, mod = setup()
        _G.GetSpecialization = function() return current end
        _G.GetNumSpecializations = function() return 3 end

        mod:_RefreshCurrentSpec()
        assert.are.equal(2, mod:CurrentSpecKey())
        current = 1
        assert.are.equal(2, mod:CurrentSpecKey())
        mod:_RefreshCurrentSpec()
        assert.are.equal(1, mod:CurrentSpecKey())
    end)

    it("publishes class and spec through the shared player cache", function()
        local ns, mod = setup()
        _G.GetSpecialization = function() return 1 end
        _G.GetNumSpecializations = function() return 3 end

        ns.Player.Refresh()
        assert.are.equal("MONK", ns.Player.class)
        assert.are.equal(1, ns.Player.spec)
        assert.are.equal(ns.Player.spec, mod:CurrentSpecKey())
        assert.is_nil(mod:_p().currentSpec)
        assert.is_nil(mod:_p().class)
    end)
end)
