local S = dofile("Test/support.lua")

local function newCache()
    local clock = S.newClock()
    _G.GetTime = clock.GetTime   -- Cache captures GetTime at load, so set it first
    _G.C_Timer = clock.C_Timer
    local ns = S.newNs()
    S.load(ns, "Services/Cache.lua")
    local c = ns._captured["Cache"]
    c:OnInitialize()
    return c, clock
end

describe("Cache", function()
    it("Set / Get returns a hit flag and misses unknown keys", function()
        local c = newCache()
        local s = c:Store("t")
        s:Set("k", 42)
        local v, hit = s:Get("k")
        assert.are.equal(42, v)
        assert.is_true(hit)
        local v2, hit2 = s:Get("nope")
        assert.is_nil(v2)
        assert.is_false(hit2)
    end)

    it("GetOrCompute computes once, then serves from cache", function()
        local c = newCache()
        local s = c:Store("t")
        local calls = 0
        local f = function() calls = calls + 1; return 7 end
        assert.are.equal(7, s:GetOrCompute("k", f))
        assert.are.equal(7, s:GetOrCompute("k", f))
        assert.are.equal(1, calls)
    end)

    it("caches a stored nil distinctly from a miss", function()
        local c = newCache()
        local s = c:Store("t")
        s:Set("k", nil)
        local v, hit = s:Get("k")
        assert.is_nil(v)
        assert.is_true(hit)
    end)

    it("LRU evicts the least-recently-used entry", function()
        local c = newCache()
        local s = c:Store("lru", { max = 2 })
        s:Set("a", 1)
        s:Set("b", 2)
        assert.is_true(select(2, s:Get("a")))   -- touch a -> b becomes LRU
        s:Set("c", 3)                            -- over capacity -> evict b
        assert.is_true(select(2, s:Get("a")))
        assert.is_false(select(2, s:Get("b")))
        assert.is_true(select(2, s:Get("c")))
    end)

    it("TTL expires entries by the clock", function()
        local c, clock = newCache()
        local s = c:Store("ttl", { ttl = 10 })
        s:Set("k", 1)
        clock.now = 5
        assert.is_true(select(2, s:Get("k")))
        clock.now = 11
        assert.is_false(select(2, s:Get("k")))
    end)

    it("Invalidate and Clear drop entries", function()
        local c = newCache()
        local s = c:Store("t")
        s:Set("k", 1)
        s:Invalidate("k")
        assert.is_false(select(2, s:Get("k")))
        s:Set("a", 1)
        s:Set("b", 2)
        s:Clear()
        assert.is_false(select(2, s:Get("a")))
    end)

    it("Stats tracks hits and misses", function()
        local c = newCache()
        local s = c:Store("t")
        s:Set("k", 1)
        s:Get("k")      -- hit
        s:Get("x")      -- miss
        local st = s:Stats()
        assert.are.equal(1, st.hits)
        assert.are.equal(1, st.misses)
    end)

    it("ttl = 0 is valid same-tick but expires once the clock advances", function()
        local c, clock = newCache()
        local s = c:Store("z", { ttl = 0 })
        s:Set("k", 1)
        assert.is_true(select(2, s:Get("k")))   -- now == expiry, not yet expired
        clock.now = clock.now + 1
        assert.is_false(select(2, s:Get("k")))
    end)

    it("max = 0 stores nothing (the just-added entry is evicted)", function()
        local c = newCache()
        local s = c:Store("z0", { max = 0 })
        s:Set("k", 1)
        assert.is_false(select(2, s:Get("k")))
    end)
end)
