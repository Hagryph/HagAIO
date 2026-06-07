local S = dofile("Test/support.lua")

local function graph()
    local ns = S.newNs()
    S.load(ns, "Core/DependencyGraph.lua")
    return ns.DependencyGraph:New()
end

describe("DependencyGraph", function()
    it("a root is online while its subject is active", function()
        local g = graph()
        local on = false
        g:Add("a", function() return on end)
        assert.is_false(g:IsOnline("a"))
        on = true
        assert.is_true(g:IsOnline("a"))
    end)

    it("a node is offline until its dependency is online", function()
        local g = graph()
        local aOn = false
        g:Add("a", function() return aOn end)
        g:Add("b", function() return true end, "a")
        assert.is_false(g:IsOnline("b"))
        aOn = true
        assert.is_true(g:IsOnline("b"))
    end)

    it("topological order puts dependencies first", function()
        local g = graph()
        g:Add("a", function() return true end)
        g:Add("b", function() return true end, "a")
        local order, ia, ib = g:TopologicalOrder()
        for i, id in ipairs(order) do
            if id == "a" then ia = i elseif id == "b" then ib = i end
        end
        assert.is_true(ia < ib)
    end)

    it("caches the topological order until structure changes", function()
        local g = graph()
        g:Add("a", function() return true end)
        local first = g:TopologicalOrder()
        assert.are.equal(first, g:TopologicalOrder())  -- same table = cached
        g:Add("b", function() return true end)
        assert.are_not.equal(first, g:TopologicalOrder())  -- Add invalidated it
    end)

    it("Validate flags a cycle", function()
        local g = graph()
        g:Add("a", function() return true end, "b")
        g:Add("b", function() return true end, "a")
        local ok, issues = g:Validate()
        assert.is_false(ok)
        assert.is_true(#issues > 0)
    end)

    it("Validate flags a dangling reference", function()
        local g = graph()
        g:Add("a", function() return true end, "missing")
        local ok = g:Validate()
        assert.is_false(ok)
    end)

    it("ANY / ALL / AtLeast conditions compose", function()
        local g = graph()
        local x, y, z = false, false, false
        g:Add("x", function() return x end)
        g:Add("y", function() return y end)
        g:Add("z", function() return z end)
        g:Add("any", function() return true end, g:Any("x", "y", "z"))
        g:Add("all", function() return true end, g:All("x", "y", "z"))
        g:Add("two", function() return true end, g:AtLeast(2, "x", "y", "z"))

        assert.is_false(g:IsOnline("any"))
        x = true
        assert.is_true(g:IsOnline("any"))
        assert.is_false(g:IsOnline("two"))
        y = true
        assert.is_true(g:IsOnline("two"))
        assert.is_false(g:IsOnline("all"))
        z = true
        assert.is_true(g:IsOnline("all"))
    end)

    it("a cycle resolves to offline instead of recursing forever", function()
        local g = graph()
        g:Add("a", function() return true end, "b")
        g:Add("b", function() return true end, "a")
        assert.is_false(g:IsOnline("a"))  -- defensively false, no stack overflow
    end)

    it("rejects a subject that is neither a function nor implements the method", function()
        local g = graph()
        assert.is_false(pcall(function() g:Add("bad", {}) end))   -- {} has no :IsActive()
        assert.is_true(pcall(function() g:Add("ok", function() return true end) end))
    end)
end)
