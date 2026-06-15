local addonName, ns = ...
local Class = ns.Class

-- Services/Cache.lua
-- Central caching service. Hands out named "stores" -- each a small key->value
-- cache with a chosen eviction POLICY -- so call sites stop hand-rolling their own
-- ad-hoc cache tables (Range item lookups, the settings-page cache, the maxHP
-- snapshot, ...). One service owns them all, can clear everything at once, and
-- reports hit/miss stats for tuning.
--
-- Three policies, mixable:
--   weak = "k" | "v" | "kv"   GC reclaims entries no longer referenced elsewhere
--                             (pure memoisation; can't hold nil; no ttl/max).
--   ttl  = <seconds>          entries expire <seconds> after they were written
--                             (uses GetTime(), WoW's frame-coherent clock).
--   max  = <count>            bounded LRU: the least-recently-used entry is
--                             evicted once the store grows past <count>.
-- ttl and max compose (an LRU with per-entry expiry). weak is standalone: LRU
-- needs strong references to track recency, so weak+max is rejected.
--
--   local s = ns.Cache:Store("flightPaths", { max = 64, ttl = 300 })
--   local path = s:GetOrCompute(key, function() return expensiveSolve(key) end)
--   s:Invalidate(key)                 -- drop one
--   ns.Cache:ClearAll()              -- drop everything (e.g. on /reload prep)
--
-- For multi-argument pure functions, Memoize wraps the function directly using an
-- argument trie (caches nil + multiple return values correctly):
--   local dist = ns.Cache:Memoize(function(ax, ay, bx, by) return slowDist(...) end)

local GetTime = GetTime

-- ===========================================================================
-- Store: one cache with a policy. Two internal shapes:
--   * weak  -> a single weak table; the GC does all the eviction.
--   * managed (default, and whenever ttl/max are set) -> a hash map of nodes,
--     plus a doubly-linked recency list when `max` is set for O(1) LRU eviction.
-- Stored values may be nil; presence is decided by node existence, never truthiness.
-- ===========================================================================
local Store = Class.new("CacheStore")

function Store:Initialize(name, opts)
    opts = opts or {}
    local p = self:_p()
    p.id   = name                  -- this store's id (the CLASS name is __name = "CacheStore")
    p.ttl  = opts.ttl              -- seconds, or nil
    p.max  = opts.max              -- LRU capacity, or nil
    p.weak = opts.weak             -- "k"/"v"/"kv", or nil
    p.hits, p.misses = 0, 0

    if p.weak and (p.ttl or p.max) then
        -- LRU recency + GC reclamation can't both own an entry's lifetime; the
        -- managed policy wins and we drop the weak request rather than silently
        -- behaving oddly.
        ns.Logger:Core():Warn(("cache '%s': weak ignored (ttl/max set)"):format(tostring(name)))
        p.weak = nil
    end

    if p.weak then
        p.data = setmetatable({}, { __mode = p.weak })
    else
        p.map = {}                 -- key -> node { key, value, expiry, prev, next }
        p.count = 0
        p.head, p.tail = nil, nil  -- head = most-recently-used (only used when max set)
        p.nextSweep = nil          -- ttl: next time _Sweep does a full expired-node walk
    end
end

function Store:GetId() return self:_p().id end

-- ---- doubly-linked recency list (LRU); no-ops unless `max` is set ----------
function Store:_Detach(node)
    local p = self:_p()
    local prev, nxt = node.prev, node.next
    if prev then prev.next = nxt else p.head = nxt end
    if nxt then nxt.prev = prev else p.tail = prev end
    node.prev, node.next = nil, nil
end

function Store:_PushFront(node)
    local p = self:_p()
    node.prev, node.next = nil, p.head
    if p.head then p.head.prev = node end
    p.head = node
    if not p.tail then p.tail = node end
end

function Store:_Touch(node)
    if self:_p().head == node then return end
    self:_Detach(node)
    self:_PushFront(node)
end

-- Remove a node from both the map and the recency list.
function Store:_Remove(node)
    local p = self:_p()
    if p.max then self:_Detach(node) end
    p.map[node.key] = nil
    p.count = p.count - 1
end

-- Drop every EXPIRED node (ttl stores only). Without this a ttl-only store (no `max` bound) keeps
-- expired-but-unread nodes forever -- Get only evicts a node when its OWN key is read again -- and
-- its count drifts above the live size. TIME-GATED: a full walk runs at most once per ttl window,
-- so steady-state reads/writes stay O(1) between sweeps; `force` (Stats) sweeps unconditionally so
-- the reported count is exact. Removing the CURRENT key mid-`pairs` is the one mutation Lua allows.
function Store:_Sweep(force)
    local p = self:_p()
    if not p.ttl then return end                      -- nothing expires (weak/max-only/plain stores)
    local now = GetTime()
    if not force and p.nextSweep and now < p.nextSweep then return end
    p.nextSweep = now + p.ttl
    for _, node in pairs(p.map) do
        if node.expiry and now > node.expiry then self:_Remove(node) end
    end
end

-- Look up a value. Returns (value, true) on a hit (value may itself be nil) or
-- (nil, false) on a miss. Expired/evicted entries count as misses.
function Store:Get(key)
    local p = self:_p()
    if p.weak then
        local v = p.data[key]
        if v ~= nil then p.hits = p.hits + 1; return v, true end
        p.misses = p.misses + 1; return nil, false
    end
    self:_Sweep()                              -- reclaim other keys' expired nodes (time-gated)
    local node = p.map[key]
    if not node then p.misses = p.misses + 1; return nil, false end
    if node.expiry and GetTime() > node.expiry then
        self:_Remove(node); p.misses = p.misses + 1; return nil, false
    end
    if p.max then self:_Touch(node) end
    p.hits = p.hits + 1
    return node.value, true
end

-- Store a value (overwrites). Returns the value for convenient chaining.
function Store:Set(key, value)
    local p = self:_p()
    if p.weak then
        -- A weak store can't hold nil (there is nothing for the GC to track), so
        -- writing nil is a delete.
        p.data[key] = value
        return value
    end
    self:_Sweep()                              -- reclaim expired nodes before growing (time-gated)
    local node = p.map[key]
    if node then
        node.value = value
        if p.ttl then node.expiry = GetTime() + p.ttl end
        if p.max then self:_Touch(node) end
        return value
    end
    node = { key = key, value = value }
    if p.ttl then node.expiry = GetTime() + p.ttl end
    p.map[key] = node
    p.count = p.count + 1
    if p.max then
        self:_PushFront(node)
        if p.count > p.max and p.tail then self:_Remove(p.tail) end
    end
    return value
end

-- Return the cached value for `key`, or compute it with producer(...), store it,
-- and return it. The single most-used entry point.
function Store:GetOrCompute(key, producer, ...)
    local v, hit = self:Get(key)
    if hit then return v end
    v = producer(...)
    return self:Set(key, v)
end

function Store:Invalidate(key)
    local p = self:_p()
    if p.weak then p.data[key] = nil; return end
    self:_Sweep()                              -- opportunistic: reclaim other expired nodes too
    local node = p.map[key]
    if node then self:_Remove(node) end
end

function Store:Clear()
    local p = self:_p()
    if p.weak then
        p.data = setmetatable({}, { __mode = p.weak })
    else
        p.map = {}
        p.count = 0
        p.head, p.tail = nil, nil
        p.nextSweep = nil
    end
    p.hits, p.misses = 0, 0
end

-- { hits, misses, count } -- count is omitted for weak stores (the GC owns it). Forces a full
-- expiry sweep first, so `count` is the LIVE (non-expired) size, never inflated by dead nodes.
function Store:Stats()
    local p = self:_p()
    if not p.weak then self:_Sweep(true) end
    return { hits = p.hits, misses = p.misses, count = p.weak and nil or p.count }
end

-- ===========================================================================
-- Cache service: owns the named stores and a Memoize helper.
-- ===========================================================================
local Cache = Class.new("Cache", ns.Service)

function Cache:OnInitialize()
    self:_p().stores = {}
end

-- Get (creating on first use) the named store. Idempotent by name; the policy
-- from the first call wins, so any caller can fetch a shared store by name.
function Cache:Store(name, opts)
    local p = self:_p()
    p.stores = p.stores or {}
    if not p.stores[name] then
        p.stores[name] = Store:New(name, opts)
    end
    return p.stores[name]
end

function Cache:HasStore(name)
    local p = self:_p()
    return (p.stores and p.stores[name]) and true or false
end

-- Wrap a pure function so repeat calls with the same arguments are cached.
-- Convenience passthrough to the dedicated Memoize service (the single source of
-- truth for argument-trie memoisation); returns just the wrapped function. `weak`
-- ("k"/"v"/"kv") makes the cache reclaimable by the GC. For clear/stats/invalidate
-- control or named memos, use ns.Memoize directly.
function Cache:Memoize(fn, weak)
    return (ns.Memoize:Wrap(fn, { weak = weak }))
end

-- Drop every entry in every store (e.g. when wiping derived state). Does not
-- destroy the stores themselves, so existing handles stay valid.
function Cache:ClearAll()
    local p = self:_p()
    if not p.stores then return end
    for _, s in pairs(p.stores) do s:Clear() end
end

ns.CacheStore = Store
-- Depends on Memoize because Cache:Memoize delegates to it (single source of truth).
ns.ServiceManager:Register(Cache:New("Cache", { deps = { "Memoize" } }))
