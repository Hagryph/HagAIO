local addonName, ns = ...

-- Core/Mixin.lua
-- TRAIT / MIXIN factory -- a sibling of ns.Class for SHARING method implementations across
-- otherwise-unrelated classes. A mixin is a named bag of methods; merging it into a class
-- copies those methods onto the class table, so instances get them through the normal
-- __index lookup (no inheritance relationship needed).
--   local Disposable = ns.Mixin.new("Disposable", {
--       Dispose = function(self) self:_p().disposed = true end,
--   })
--   local Foo = ns.Class.new("Foo", nil, { mixins = { Disposable } })   -- merge at creation
--   ns.Mixin.applyTo(Bar, Disposable)                                   -- or merge explicitly

local Mixin = {}

-- mixin method-table -> name (weak so a mixin can be GC'd).
local names = setmetatable({}, { __mode = "k" })

function Mixin.new(name, methods)
    assert(type(name) == "string", "Mixin.new: name must be a string")
    assert(type(methods) == "table", "Mixin.new: methods must be a table")
    names[methods] = name
    return methods   -- the mixin IS its (clean) method table, ready to merge
end

-- Copy a mixin's methods onto `class`. A method defined on the class AFTER this call
-- overrides the mixin's (plain Lua assignment); between two mixins, the last applied wins.
function Mixin.applyTo(class, mixin)
    for k, v in pairs(mixin) do class[k] = v end
    return class
end

function Mixin.nameOf(mixin) return names[mixin] end

ns.Mixin = Mixin
