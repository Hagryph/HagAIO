#!/usr/bin/env lua
-- Test/run.lua
-- Minimal, dependency-free test runner with a busted-compatible surface
-- (describe / it / assert.are.equal / assert.is_true / ...). Run from the repo root:
--   luajit Test/run.lua        (LuaJIT = Lua 5.1, matching WoW)   or   lua Test/run.lua
-- Exits non-zero on any failure, so CI can gate on it.

-- Specs are DISCOVERED from disk (every Test/*_spec.lua), so a new spec runs the
-- moment it exists -- no list to keep in sync. We shell out for the directory listing
-- (stock Lua has no readdir): `dir /b` on Windows, `ls` elsewhere. Names are sorted so
-- the run order is deterministic across platforms.
local function discoverSpecs()
    local onWindows = package.config:sub(1, 1) == "\\"
    local cmd = onWindows and 'dir /b "Test\\*_spec.lua"' or 'ls -1 Test/*_spec.lua 2>/dev/null'
    local pipe = assert(io.popen(cmd), "could not list Test/*_spec.lua")
    local names = {}
    for line in pipe:lines() do
        local name = line:match("([%w_]+)_spec%.lua")  -- handles both bare names and paths
        if name then names[#names + 1] = name end
    end
    pipe:close()
    table.sort(names)
    assert(#names > 0, "no Test/*_spec.lua files found (run from the repo root)")
    return names
end

local SPECS = discoverSpecs()

local results = { pass = 0, fail = 0, failures = {} }
local stack = {}

function describe(name, fn)
    stack[#stack + 1] = name
    fn()
    stack[#stack] = nil
end

function it(name, fn)
    local label = table.concat(stack, " ") .. " > " .. name
    local ok, err = pcall(fn)
    if ok then
        results.pass = results.pass + 1
        io.write(".")
    else
        results.fail = results.fail + 1
        results.failures[#results.failures + 1] = { label = label, err = err }
        io.write("F")
    end
end

-- busted-style assertions. `assert` is a callable table, so `assert(cond[, msg])`
-- still behaves like the stock global (support.lua / the services rely on that).
local function fail(msg) error(msg, 3) end
local A = {
    are     = { equal = function(e, a) if e ~= a then fail(("expected %s, got %s"):format(tostring(e), tostring(a))) end end },
    are_not = { equal = function(e, a) if e == a then fail("expected values to differ, both " .. tostring(e)) end end },
}
function A.is_true(v)  if v ~= true  then fail("expected true, got "  .. tostring(v)) end end
function A.is_false(v) if v ~= false then fail("expected false, got " .. tostring(v)) end end
function A.is_nil(v)   if v ~= nil   then fail("expected nil, got "   .. tostring(v)) end end
function A.near(e, a, tol)
    tol = tol or 1e-9
    if type(a) ~= "number" or math.abs(e - a) > tol then
        fail(("expected ~%s (+/-%s), got %s"):format(tostring(e), tostring(tol), tostring(a)))
    end
end
setmetatable(A, { __call = function(_, v, msg) if not v then fail(msg or "assertion failed") end return v end })
assert = A

for _, name in ipairs(SPECS) do
    dofile("Test/" .. name .. "_spec.lua")
end

io.write("\n\n")
for _, f in ipairs(results.failures) do
    io.write(("FAIL: %s\n      %s\n"):format(f.label, tostring(f.err)))
end
io.write(("%d passed, %d failed\n"):format(results.pass, results.fail))
os.exit(results.fail == 0 and 0 or 1)
