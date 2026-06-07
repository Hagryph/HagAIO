local S = dofile("Test/support.lua")

local function newMemo()
    local ns = S.newNs()
    S.load(ns, "Services/Memoize.lua")
    local m = ns._captured["Memoize"]
    m:OnInitialize()
    return m
end

describe("Memoize", function()
    it("caches by argument value", function()
        local m = newMemo()
        local calls = 0
        local f = m:Wrap(function(a, b) calls = calls + 1; return a + b end)
        assert.are.equal(3, f(1, 2))
        assert.are.equal(3, f(1, 2))
        assert.are.equal(1, calls)
        assert.are.equal(5, f(2, 3))
        assert.are.equal(2, calls)
    end)

    it("distinguishes f(1) from f(1, nil) by arity", function()
        local m = newMemo()
        local calls = 0
        local f = m:Wrap(function(...) calls = calls + 1; return select("#", ...) end)
        assert.are.equal(1, f(1))
        assert.are.equal(2, f(1, nil))
        assert.are.equal(2, calls)
    end)

    it("uses nil and NaN arguments as cache keys", function()
        local m = newMemo()
        local calls = 0
        local f = m:Wrap(function() calls = calls + 1; return calls end)
        f(nil); f(nil)
        local nan = 0 / 0
        f(nan); f(nan)
        assert.are.equal(2, calls)   -- nil cached once, NaN cached once
    end)

    it("preserves multiple return values including an embedded nil", function()
        local m = newMemo()
        local f = m:Wrap(function() return 1, nil, 3 end)
        local a, b, c = f()
        assert.are.equal(1, a)
        assert.is_nil(b)
        assert.are.equal(3, c)
        assert.are.equal(3, select("#", f()))
    end)

    it("named Function + Invalidate forces a recompute", function()
        local m = newMemo()
        local calls = 0
        local f = m:Function("dist", function(x) calls = calls + 1; return calls end)
        f(5); f(5)
        assert.are.equal(1, calls)
        m:Invalidate("dist", 5)
        f(5)
        assert.are.equal(2, calls)
        assert.is_true(m:Has("dist"))
    end)

    it("Stats counts calls, hits and misses", function()
        local m = newMemo()
        local f = m:Function("s", function(x) return x end)
        f(1); f(1); f(2)
        local st = m:Stats("s")
        assert.are.equal(3, st.calls)
        assert.are.equal(1, st.hits)
        assert.are.equal(2, st.misses)
    end)

    it("caches longer / trailing-nil arg tuples distinctly", function()
        local m = newMemo()
        local calls = 0
        local f = m:Wrap(function(...) calls = calls + 1; return select("#", ...) end)
        assert.are.equal(3, f(1, 2, 3))
        assert.are.equal(3, f(1, 2, 3)); assert.are.equal(1, calls)  -- cached
        assert.are.equal(3, f(1, nil, 3)); assert.are.equal(2, calls) -- distinct middle nil
        assert.are.equal(2, f(1, nil)); assert.are.equal(3, calls)    -- distinct trailing nil
    end)

    it("a weak-keyed memo still caches while the key is referenced", function()
        local m = newMemo()
        local calls = 0
        local f = m:Wrap(function(t) calls = calls + 1; return calls end, { weak = "k" })
        local key = {}
        f(key); f(key)
        assert.are.equal(1, calls)
    end)

    it("a weak-valued memo reclaims unreferenced entries on GC, then recomputes", function()
        local m = newMemo()
        local calls = 0
        -- weak VALUES: the cached node is reachable only weakly once the call returns,
        -- so a full GC collects it and the next identical call recomputes.
        local f = m:Wrap(function(x) calls = calls + 1; return x end, { weak = "v" })
        f(1); f(1)
        assert.are.equal(1, calls)   -- cached (no GC yet)
        collectgarbage("collect")    -- reclaim the unreferenced cache node
        f(1)
        assert.are.equal(2, calls)   -- entry was reclaimed -> recomputed
    end)
end)
