local addonName, ns = ...

-- Core/Class.lua
-- Minimal metatable-based OOP system with true per-instance encapsulation.
--
-- Lua has no native classes/visibility, so we emulate them: each instance's
-- private state lives in a weak-keyed side table reachable only through the
-- inherited :_p() accessor. Subclasses therefore touch their data via
-- getters/setters rather than public instance fields, satisfying the
-- "all attributes private" rule. Inheritance is a standard __index chain.

-- instance -> private field table. Weak keys so instances can be GC'd.
local private = setmetatable({}, { __mode = "k" })

local function makeInstance(class, ...)
    local instance = setmetatable({}, class)
    private[instance] = {}
    -- Constructor convention: every class may define :Initialize(...).
    if instance.Initialize then
        instance:Initialize(...)
    end
    return instance
end

-- Root base class that every class inherits from.
local Object = {}
Object.__index = Object
Object.__name = "Object"

-- Protected accessor to this instance's private field table.
function Object:_p()
    return private[self]
end

function Object:GetClassName()
    return getmetatable(self).__name
end

function Object:IsInstanceOf(class)
    local mt = getmetatable(self)
    while mt do
        if mt == class then return true end
        mt = rawget(mt, "__parent")
    end
    return false
end

-- Class factory (a static namespace table).
local Class = {}

-- Create a new class `name`, optionally inheriting from `parent`
-- (defaults to Object).
function Class.new(name, parent)
    parent = parent or Object
    local class = setmetatable({}, { __index = parent })
    class.__index = class
    class.__name = name
    class.__parent = parent

    -- Instantiation entry point: MyClass:New(...).
    function class:New(...)
        return makeInstance(self, ...)
    end

    return class
end

ns.Class = Class
ns.Object = Object
