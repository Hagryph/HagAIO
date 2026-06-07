local addonName, ns = ...
local Class = ns.Class

-- Services/Memoize.lua
-- Memoization service: wrap a PURE function so repeat calls with the same arguments
-- return a cached result instead of recomputing. Sibling to the Cache service --
-- Cache is a key->value store you write to; Memoize decorates a function and manages
-- the cache for you, keyed by the call's arguments.
--
-- Sturdy by construction (see PiL 17.1, kikito/memoize.lua, lua-users CurriedMemoization):
--   * Argument TRIE -- one nesting level per argument, compared by value equality
--     (table keys), never by a fragile tostring() key.
--   * nil / NaN arguments are usable: nil can't be a table key and NaN can't either,
--     so each maps to a private sentinel.
--   * Arity-correct: f(1) and f(1, nil) are DIFFERENT calls (they reach different
--     trie depths), so trailing nils don't collide.
--   * Multiple return values, including embedded nils, are preserved exactly
--     ({ n = select("#", ...), ... } + unpack(r, 1, r.n)).
--   * Optional weak storage (weak = "k") lets the GC reclaim cached branches once the
--     argument objects keying them are gone -- the standard fix for an unbounded memo.
--
--   local slow = function(a, b) ... end
--   local fast = ns.Memoize:Wrap(slow)                 -- anonymous
--   local fast = ns.Memoize:Function("dist", slow)     -- named (clear/stats by name)
--   ns.Memoize:Stats("dist")  ns.Memoize:Invalidate("dist", a, b)  ns.Memoize:Clear("dist")
--
-- ONLY memoize pure functions (output depends solely on arguments, no side effects).
-- For results that should expire or be bounded by size/recency, use ns.Cache instead.

local Memoize = Class.new("Memoize", ns.Service)

local unpack = unpack or table.unpack

-- Private sentinels: values that cannot themselves be table keys.
local NIL = {}   -- stands in for a nil argument
local NAN = {}   -- stands in for a NaN argument (NaN ~= NaN, and isn't a valid key)

local function keyOf(v)
    if v == nil then return NIL end
    if v ~= v then return NAN end   -- only NaN is unequal to itself
    return v
end

-- Capture all return values + their count in one table (handles embedded/trailing nils).
local function pack(...) return { n = select("#", ...), ... } end

-- Build a standalone memoized wrapper around fn, plus a control handle.
local function build(fn, opts)
    opts = opts or {}
    local mt = opts.weak and { __mode = opts.weak } or nil  -- usually "k": reclaim by argument
    local root = { children = setmetatable({}, mt) }
    local stats = { calls = 0, hits = 0, misses = 0 }

    -- Descend the trie to the node for this argument tuple. create=false stops at the
    -- first gap and returns nil (used by invalidate); create=true builds the path.
    local function nodeFor(create, ...)
        local node = root
        local argc = select("#", ...)
        for i = 1, argc do
            local k = keyOf((select(i, ...)))
            local children = node.children
            if not children then
                if not create then return nil end
                children = setmetatable({}, mt)
                node.children = children
            end
            local child = children[k]
            if child == nil then
                if not create then return nil end
                child = {}
                children[k] = child
            end
            node = child
        end
        return node
    end

    local wrapped = function(...)
        stats.calls = stats.calls + 1
        local node = nodeFor(true, ...)
        local r = node.results
        if r then
            stats.hits = stats.hits + 1
            return unpack(r, 1, r.n)
        end
        stats.misses = stats.misses + 1
        r = pack(fn(...))
        node.results = r
        return unpack(r, 1, r.n)
    end

    local control = {
        stats = function()
            return { calls = stats.calls, hits = stats.hits, misses = stats.misses }
        end,
        clear = function()
            root.children = setmetatable({}, mt)
            root.results = nil
            stats.calls, stats.hits, stats.misses = 0, 0, 0
        end,
        -- Forget the cached result for one specific argument tuple (next call recomputes).
        invalidate = function(...)
            local node = nodeFor(false, ...)
            if node then node.results = nil end
        end,
    }
    return wrapped, control
end

function Memoize:OnInitialize()
    self:_p().entries = {}   -- name -> { fn, control }
end

-- Wrap an anonymous function. Returns (memoizedFn, control), where control has
-- :stats() / :clear() / :invalidate(...) as plain functions. opts = { weak = "k"|"v"|"kv" }.
function Memoize:Wrap(fn, opts)
    assert(type(fn) == "function", "Memoize:Wrap expects a function")
    return build(fn, opts)
end

-- Named, idempotent registration: the first call for a name wins, later calls return
-- the same memoized function, so any caller can fetch a shared memo by name and the
-- service can clear/inspect it. The control handle is kept internally.
function Memoize:Function(name, fn, opts)
    local p = self:_p()
    p.entries = p.entries or {}
    local e = p.entries[name]
    if not e then
        local wrapped, control = build(fn, opts)
        e = { fn = wrapped, control = control }
        p.entries[name] = e
    end
    return e.fn
end

function Memoize:Has(name)
    local p = self:_p()
    return (p.entries and p.entries[name]) and true or false
end

-- { calls, hits, misses } for a named memo, or nil if unknown.
function Memoize:Stats(name)
    local e = self:_p().entries[name]
    return e and e.control.stats() or nil
end

function Memoize:Clear(name)
    local e = self:_p().entries[name]
    if e then e.control.clear() end
end

function Memoize:Invalidate(name, ...)
    local e = self:_p().entries[name]
    if e then e.control.invalidate(...) end
end

function Memoize:ClearAll()
    local p = self:_p()
    if not p.entries then return end
    for _, e in pairs(p.entries) do e.control.clear() end
end

ns.ServiceManager:Register(Memoize:New("Memoize"))
