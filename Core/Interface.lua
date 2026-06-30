local addonName, ns = ...

-- Core/Interface.lua
-- INTERFACE factory -- a sibling of ns.Class for CONTRACTS: a named list of method names a
-- class must provide. Unlike a mixin it carries no implementation; it only VERIFIES that a
-- class implements every required method (a missing one raises a clear, named error).
--   local IDrawable = ns.Interface.new("IDrawable", { "Draw", "Bounds" })
--   local Box = ns.Class.new("Box", nil, { implements = { IDrawable } })  -- checked at first :New()
--   ns.Interface.assertClass(Box, IDrawable)                              -- or check explicitly
--   if ns.Interface.isImplementedBy(Box, IDrawable) then ... end          -- non-throwing

local Interface = {}

function Interface.new(name, methodNames)
    assert(type(name) == "string", "Interface.new: name must be a string")
    assert(type(methodNames) == "table", "Interface.new: methodNames must be a list")
    local iface = {}
    for i, m in ipairs(methodNames) do
        assert(type(m) == "string", "Interface.new: method names must be strings")
        iface[i] = m
    end
    iface.__name = name   -- a string key, so ipairs() skips it -> never read as a requirement
    return iface
end

-- Raise unless `class` provides every method the interface requires.
function Interface.assertClass(class, iface)
    for _, m in ipairs(iface) do
        if type(class[m]) ~= "function" then
            error(("Interface.assertClass: class '%s' is missing method '%s' required by interface '%s'"):format(
                (class and class.__name) or "?", m, iface.__name or "?"), 2)
        end
    end
    return true
end

-- Non-throwing conformance check.
function Interface.isImplementedBy(class, iface)
    for _, m in ipairs(iface) do
        if type(class[m]) ~= "function" then return false end
    end
    return true
end

ns.Interface = Interface
