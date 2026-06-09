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
    it("GetSettings resolves the registered spec for the current spec without it being loaded", function()
        local ns, mod = setup()
        local specSettings = { { type = "toggle", key = "x", label = "X", default = true } }
        mod:_RegisterSpec("none", { GetSettings = function() return specSettings end })
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
        mod:_RegisterSpec("none", { GetSettings = function() return { { type = "note", text = "registry" } } end })
        mod:_p().activeSub = { GetSettings = function() return { { type = "note", text = "loaded" } } end }
        assert.are.equal("loaded", mod:GetSettings()[1].text)
    end)
end)
