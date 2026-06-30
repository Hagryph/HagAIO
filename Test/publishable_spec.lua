local S = dofile("Test/support.lua")

-- ns.Publishable (Core/Contributions.lua) -- the single _Publish mixed into Module, Service and Lib.
-- Drives off p.publishAs (the key, or nil = don't publish) and p.ui (route into ns.UI.<key>).

describe("ns.Publishable (_Publish)", function()
    it("a Service always publishes under its name; ui routes into ns.UI", function()
        local ns = S.newNs()                                  -- loads Contributions + Service
        local Svc = ns.Class.new("PubSvc", ns.Service):New("PubSvc")
        Svc:_Publish()
        assert.are.equal(Svc, ns.PubSvc)

        local Win = ns.Class.new("PubWin", ns.Service):New("PubWin", { ui = true })
        Win:_Publish()
        assert.are.equal(Win, ns.UI.PubWin)                   -- ui -> ns.UI.<name>
        assert.is_nil(ns.PubWin)                              -- ...and NOT ns.<name>
    end)

    it("a Module publishes ns.<alias> ONLY when publishAs is set", function()
        local ns = S.newNs()
        S.load(ns, "Core/Module.lua")                         -- Component + SettingsTables already loaded
        local Aliased = ns.Class.new("PubModA", ns.Module):New("PubModA", { publishAs = "Dash" })
        Aliased:_Publish()
        assert.are.equal(Aliased, ns.Dash)                    -- reachable at its alias

        local Plain = ns.Class.new("PubModB", ns.Module):New("PubModB")   -- no alias
        Plain:_Publish()
        assert.is_nil(ns.PubModB)                             -- a module with no alias publishes nothing
    end)

    it("a Lib always publishes under its name", function()
        local ns = S.newNs()
        local L = ns.Class.new("PubLib", ns.Lib):New("PubLib")
        L:_Publish()
        assert.are.equal(L, ns.PubLib)
    end)
end)
