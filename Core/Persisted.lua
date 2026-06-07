local addonName, ns = ...

-- Core/Persisted.lua
-- ns.Persisted -- a MIXIN (ns.Mixin) for objects that own a lazily-resolved, CACHED SavedVars
-- namespace. Replaces the repeated "if not p.store then p.store = ns.SavedVars:Namespace(...)"
-- boilerplate (and the bug where some callers re-called :Namespace on every access). Declare
-- the binding once with self:_BindStore(name, defaults[, perChar]); self:_Store() then resolves
-- it the first time SavedVariables are loaded and caches the handle.
--   ns.Class.new("Foo", ns.Service, { mixins = { ns.Persisted } })
--   function Foo:OnInitialize() self:_BindStore("foo", { shown = false }) end
--   ... self:_Store().shown ...

ns.Persisted = ns.Mixin.new("Persisted", {
    -- Declare where this object persists. `defaults` may be a table, or a FUNCTION returning
    -- one (deferred -- e.g. when defaults depend on state not ready at bind time).
    _BindStore = function(self, name, defaults, perChar)
        local p = self:_p()
        p._storeName, p._storeDefaults, p._storePerChar = name, defaults, perChar
    end,

    -- The cached SavedVars namespace handle, resolved once SavedVariables are loaded
    -- (nil before then). Resolved at most once.
    _Store = function(self)
        local p = self:_p()
        if not p._store and ns.SavedVars and ns.SavedVars:IsLoaded() then
            local d = p._storeDefaults
            if type(d) == "function" then d = d() end
            p._store = ns.SavedVars:Namespace(p._storeName, d, p._storePerChar)
        end
        return p._store
    end,
})
