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

-- class -> its private STATIC table (shared class-level state). The same private-side-table
-- pattern as instance attributes, but keyed by class. C# semantics: a static is owned by the
-- class that DECLARES it (opts.statics) and SHARED by every subclass; a subclass that
-- re-declares gets its own. So lookup resolves UP the parent chain to the nearest declarer.
local statics = setmetatable({}, { __mode = "k" })

local function classOf(arg)
    if type(arg) == "table" then
        if rawget(arg, "__ancestors") then return arg end       -- arg is a class table
        local mt = getmetatable(arg)
        if mt and rawget(mt, "__ancestors") then return mt end   -- arg is an instance
    end
    error("statics: argument must be a class or an instance", 3)
end

local function sharedStatics(arg)
    local cls = classOf(arg)
    local c = cls
    while c do
        local s = statics[c]
        if s then return s end          -- nearest declaring class wins (shared with subclasses)
        c = rawget(c, "__parent")
    end
    statics[cls] = {}                   -- none declared in the chain: anchor a fresh store here
    return statics[cls]
end

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
-- Each class carries the SET of itself + every ancestor, so IsInstanceOf is a
-- single hash lookup instead of walking the __parent chain on every call.
Object.__ancestors = { [Object] = true }

-- Protected accessor to this instance's private field table.
function Object:_p()
    return private[self]
end

-- Protected accessor to this class's private STATIC table -- the shared, class-level
-- counterpart of :_p(). Resolves to the declaring class, so subclasses share it (C#).
function Object:_statics()
    return sharedStatics(self)
end

function Object:GetClassName()
    return getmetatable(self).__name
end

function Object:IsInstanceOf(class)
    local mt = getmetatable(self)
    local ancestors = mt and rawget(mt, "__ancestors")
    if ancestors then return ancestors[class] == true end
    -- Fallback for any metatable built without an ancestry set (defensive).
    while mt do
        if mt == class then return true end
        mt = rawget(mt, "__parent")
    end
    return false
end

-- Class factory (a static namespace table).
local Class = {}

-- Create a new class `name`, optionally inheriting from `parent` (defaults to Object).
-- `opts` (all optional) turns on the richer constructs:
--   abstract = true          -- the class itself can't be :New()'d (only subclasses can)
--   statics  = { ... }       -- PRIVATE static attributes (shared class-level state), kept in
--                               a private side table and reached via self:_statics() /
--                               ns.Class.statics(cls). Owned by THIS class and shared by its
--                               subclasses (C#); a subclass re-declaring gets its own.
--   mixins   = { M1, M2 }    -- trait method tables (ns.Mixin) merged in; your own methods win
--   implements = { I1 }      -- interfaces (ns.Interface) verified at each concrete class's
--                               first :New() -- subclasses inherit (and re-verify) the contract
function Class.new(name, parent, opts)
    parent = parent or Object
    local class = setmetatable({}, { __index = parent })
    class.__index = class
    class.__name = name
    class.__parent = parent
    class.super = parent   -- public alias for super-calls: Sub.super.Method(self, ...)
    -- Ancestry = this class + everything the parent already counts as. Built once
    -- at class-creation, so IsInstanceOf never walks the chain at call time.
    local ancestors = { [class] = true }
    for a in pairs(parent.__ancestors or { [parent] = true }) do ancestors[a] = true end
    class.__ancestors = ancestors

    if opts then
        -- Traits/mixins first, so a `function C:Method` defined afterwards overrides them.
        if opts.mixins then
            for _, mixin in ipairs(opts.mixins) do
                for k, v in pairs(mixin) do class[k] = v end
            end
        end
        if opts.statics then
            local store = {}
            for k, v in pairs(opts.statics) do store[k] = v end
            statics[class] = store   -- anchor the private static store at THIS declaring class
        end
        if opts.abstract then class.__abstract = true end
        if opts.implements then class.__implements = opts.implements end
    end

    -- True when any class in the parent chain declared `implements` -- a subclass must
    -- honour every ancestor's interface contracts, so it needs the checking constructor too.
    local inheritsContracts = false
    do
        local c = parent
        while c do
            if rawget(c, "__implements") then inheritsContracts = true; break end
            c = rawget(c, "__parent")
        end
    end

    -- Classes that opt into abstract/implements -- or INHERIT an interface contract -- get a
    -- checking constructor; every other class keeps the minimal fast path (no per-New
    -- overhead -- protects hot value types).
    if (opts and (opts.abstract or opts.implements)) or inheritsContracts then
        function class:New(...)
            if rawget(self, "__abstract") then
                error(("cannot instantiate abstract class '%s'"):format(self.__name), 2)
            end
            -- Verify every contract in the ancestry ONCE per concrete class, at its first
            -- :New() (when every method is defined). The declarer's __implements is kept --
            -- each subclass verifies against ITS OWN method set (an abstract base can't be
            -- instantiated, so its contract is only ever checkable here, on a subclass).
            if not rawget(self, "__implChecked") then
                local c = self
                while c do
                    for _, iface in ipairs(rawget(c, "__implements") or {}) do
                        for _, m in ipairs(iface) do
                            if type(self[m]) ~= "function" then
                                error(("class '%s' is missing method '%s' required by interface '%s'"):format(
                                    self.__name, m, iface.__name or "?"), 2)
                            end
                        end
                    end
                    c = rawget(c, "__parent")
                end
                self.__implChecked = true   -- latched only after the contracts verified
            end
            return makeInstance(self, ...)
        end
    else
        function class:New(...)
            return makeInstance(self, ...)
        end
    end

    return class
end

-- Accessor for a class's PRIVATE static table from outside an instance method -- e.g. from a
-- static (dot) method, or any code holding the class. Same store as self:_statics(); resolves
-- to the declaring class so subclasses share it (C#). Lazily creates one if undeclared.
--   function Counter.Reset() ns.Class.statics(Counter).total = 0 end
function Class.statics(classOrInstance)
    return sharedStatics(classOrInstance)
end

-- Abstract-method marker. Assign the result to a base-class method that EVERY
-- concrete subclass MUST override; reaching the base version (a forgotten override)
-- raises a clear, class-named error instead of silently no-oping.
--   MyBase.DoThing = Class.abstract("DoThing")
function Class.abstract(name)
    return function(self)
        error(("%s: abstract method '%s' must be overridden by the subclass"):format(
            (type(self) == "table" and self.GetClassName and self:GetClassName()) or "?", name), 2)
    end
end

-- Super-calls use the `class.super` field set above (the parent CLASS). Always name the
-- class the method is DEFINED on -- NOT self -- so super resolves relative to where it's
-- written, never the instance's most-derived class (which would self-recurse in a deep
-- hierarchy). It reaches the parent via the normal __index chain, so an inserted
-- intermediate class is picked up automatically rather than silently bypassed:
--   function Sub:OnSettingChanged(k, v)
--       Sub.super.OnSettingChanged(self, k, v)   -- run the inherited behaviour (dot + self)
--       ... -- then this class's extra work
--   end

ns.Class = Class
ns.Object = Object
