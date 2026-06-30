local S = dofile("Test/support.lua")

-- Build a fresh namespace with the Submodule framework loaded. newNs already has Class,
-- Component, Service and the stubs; we add Registry + DependencyGraph + Submodule(Manager).
-- Submodules here use a bare condition (no parent / deps / events), so neither
-- ModuleManager nor EventBus is needed and Reevaluate can be driven directly.
local function setup()
    local ns = S.newNs()
    S.load(ns, "Core/Registry.lua")
    S.load(ns, "Core/DependencyGraph.lua")
    S.load(ns, "Core/Submodule.lua")
    S.load(ns, "Core/SubmoduleManager.lua")
    return ns
end

describe("SubmoduleManager", function()
    it("registers without loading until Reevaluate runs", function()
        local ns = setup()
        local sub = ns.Submodule:New("X", { condition = function() return true end })
        ns.SubmoduleManager:Register(sub)
        assert.is_false(sub:IsLoaded())   -- not started, not evaluated
        assert.are.equal(1, ns.SubmoduleManager:Count())
    end)

    it("loads / unloads as the condition flips", function()
        local ns = setup()
        local on, log = true, {}
        local sub = ns.Submodule:New("X", {
            condition = function() return on end,
            onLoad   = function() log[#log + 1] = "load" end,
            onUnload = function() log[#log + 1] = "unload" end,
        })
        ns.SubmoduleManager:Register(sub)

        ns.SubmoduleManager:Reevaluate()
        assert.is_true(sub:IsLoaded())
        on = false
        ns.SubmoduleManager:Reevaluate()
        assert.is_false(sub:IsLoaded())

        assert.are.equal("load", log[1])
        assert.are.equal("unload", log[2])
    end)

    it("is idempotent: re-evaluating an unchanged set neither re-loads nor re-unloads", function()
        local ns = setup()
        local count = 0
        local sub = ns.Submodule:New("X", {
            condition = function() return true end,
            onLoad   = function() count = count + 1 end,
        })
        ns.SubmoduleManager:Register(sub)
        ns.SubmoduleManager:Reevaluate()
        ns.SubmoduleManager:Reevaluate()
        ns.SubmoduleManager:Reevaluate()
        assert.are.equal(1, count)   -- loaded once, not on every sweep
    end)

    it("runs each submodule's always-on OnInitialize ONCE at StartAll, even if it never loads", function()
        local ns = setup()
        ns.EventBus = { On = function() end, Subscribe = function() return 1 end }   -- StartAll subscribes
        local inits = 0
        -- subclass form (OnInitialize override) that DOES load; closure form (onInitialize opt) that does NOT
        local Sub = ns.Class.new("WithInit", ns.Submodule)
        function Sub:OnInitialize() inits = inits + 1 end
        local a = Sub:New("A", { condition = function() return true end })
        local b = ns.Submodule:New("B", { condition = function() return false end,
                                          onInitialize = function() inits = inits + 1 end })
        ns.SubmoduleManager:Register(a); ns.SubmoduleManager:Register(b)

        ns.SubmoduleManager:StartAll()
        assert.are.equal(2, inits)          -- BOTH initialized -- the never-loading one too (always-on recorder)
        assert.is_true(a:IsLoaded())        -- A's condition held -> loaded
        assert.is_false(b:IsLoaded())       -- B never loaded, but was still initialized

        ns.SubmoduleManager:StartAll()      -- idempotent (StartAll's start latch + _Init's per-sub latch)
        assert.are.equal(2, inits)
    end)

    it("is a Worker OWNER: load/unload flips IsEnabled and broadcasts HagAIO_OwnerState", function()
        local ns = setup()
        -- Capture HagAIO_OwnerState (the message the Worker binds to). The submodule's enabled-state
        -- contract lives on ns.Component now, so loading/unloading MUST emit it -- the bug was a
        -- submodule that emitted nothing, leaving its Worker jobs believing it was always enabled.
        local ownerStates = {}
        ns.EventBus = { Emit = function(_, msg, owner, on)
            if msg == "HagAIO_OwnerState" then ownerStates[#ownerStates + 1] = on end
        end }
        local on = true
        local sub = ns.Submodule:New("X", { condition = function() return on end })
        ns.SubmoduleManager:Register(sub)
        assert.is_false(sub:IsEnabled())              -- Component's owner query, before load
        assert.is_false(sub:IsLoaded())               -- the submodule-domain alias agrees

        ns.SubmoduleManager:Reevaluate()
        assert.is_true(sub:IsEnabled())               -- loaded -> the Worker would gate work ON
        assert.is_true(sub:IsLoaded())

        on = false
        ns.SubmoduleManager:Reevaluate()
        assert.is_false(sub:IsEnabled())              -- unloaded -> gated OFF

        assert.are.equal(2, #ownerStates)             -- emitted on BOTH load and unload
        assert.is_true(ownerStates[1])
        assert.is_false(ownerStates[2])
    end)

    it("IsLoaded reflects a sub's loaded state by name (unknown -> false)", function()
        local ns = setup()
        local mgr = ns.SubmoduleManager
        local x = ns.Submodule:New("x", { condition = function() return true end })
        mgr:Register(x)
        assert.is_false(mgr:IsLoaded("x"))
        assert.is_false(mgr:IsLoaded("nope"))   -- unknown name
        x:_Load()
        assert.is_true(mgr:IsLoaded("x"))
    end)

    it("ConfigurableChildrenOf returns subs whose condition holds, ignoring the parent's enable state", function()
        local ns = setup()
        -- the parent module Foo is DISABLED, yet configurable children must still surface
        ns.ModuleManager = { GetModule = function() return { IsEnabled = function() return false end } end }
        local mgr = ns.SubmoduleManager
        local a = ns.Submodule:New("a", { parent = { module = "Foo" }, condition = function() return true end })
        local b = ns.Submodule:New("b", { parent = { module = "Foo" }, condition = function() return false end })
        local c = ns.Submodule:New("c", { parent = { module = "Bar" }, condition = function() return true end })
        mgr:Register(a); mgr:Register(b); mgr:Register(c)
        local kids = mgr:ConfigurableChildrenOf("Foo")
        assert.are.equal(1, #kids)
        assert.are.equal("a", kids[1]:GetName())   -- condition true, shown despite Foo disabled
    end)

    it("ConfigurableChildrenOf still respects non-parent availability deps (e.g. a required addon)", function()
        local ns = setup()
        ns.ModuleManager = { GetModule = function() return { IsEnabled = function() return false end } end }
        _G.C_AddOns = { IsAddOnLoaded = function() return false end }
        local mgr = ns.SubmoduleManager
        local c = ns.Submodule:New("c", { parent = { module = "Foo" }, addonDeps = { "ATT" },
                                          condition = function() return true end })
        mgr:Register(c)
        assert.are.equal(0, #mgr:ConfigurableChildrenOf("Foo"))   -- addon missing -> not configurable
        _G.C_AddOns = nil
    end)

    it("handles re-entrant Reevaluate from an onLoad callback (guard + dirty re-sweep)", function()
        local ns = setup()
        local mgr = ns.SubmoduleManager
        local flags = { A = true, B = false }
        local loadCount = { A = 0, B = 0 }

        local A = ns.Submodule:New("A", {
            condition = function() return flags.A end,
            onLoad = function()
                loadCount.A = loadCount.A + 1
                flags.B = true       -- make B eligible...
                mgr:Reevaluate()      -- ...and re-enter mid-sweep (guard -> dirty -> re-sweep)
            end,
        })
        local B = ns.Submodule:New("B", {
            condition = function() return flags.B end,
            onLoad = function() loadCount.B = loadCount.B + 1 end,
        })
        mgr:Register(A)
        mgr:Register(B)

        mgr:Reevaluate()
        assert.is_true(A:IsLoaded())
        assert.is_true(B:IsLoaded())     -- the dirty re-sweep picked B up
        assert.are.equal(1, loadCount.A) -- the re-entrant call didn't re-load A
        assert.are.equal(1, loadCount.B)
    end)
end)
