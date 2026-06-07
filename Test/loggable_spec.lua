local S = dofile("Test/support.lua")

-- ns.Loggable is the single home for the logging surface; Component and Service both
-- inherit it (newNs loads Loggable -> Component -> Service, mirroring the .toc).
describe("Loggable mixin", function()
    it("is the single source of the Log* methods for Component and Service", function()
        local ns = S.newNs()
        -- Same function object resolves through both class chains -> one definition.
        assert.are.equal(ns.Loggable.LogInfo, ns.Component.LogInfo)
        assert.are.equal(ns.Loggable.LogInfo, ns.Service.LogInfo)
        assert.are.equal(ns.Loggable._AttachLogger, ns.Service._AttachLogger)
    end)

    it("_AttachLogger gives the instance a channel via GetLog", function()
        local ns = S.newNs()
        local C = ns.Class.new("C", ns.Component)
        local c = C:New()
        assert.is_nil(c:GetLog())          -- none until attached
        c:_p().name = "C"
        c:_AttachLogger()
        assert(c:GetLog() ~= nil)          -- the stubbed Logger channel
    end)

    it("Log* helpers are nil-safe without a channel", function()
        local ns = S.newNs()
        local c = ns.Class.new("C", ns.Component):New()
        assert.is_true(pcall(function() c:LogInfo("x"); c:LogError("y"); c:LogEchoInfo("z") end))
    end)

    it("a Service inherits the same logging surface", function()
        local ns = S.newNs()
        local Svc = ns.Class.new("Svc", ns.Service)
        local s = Svc:New("Svc")
        s:_AttachLogger()
        assert(s:GetLog() ~= nil)
        assert.is_true(pcall(function() s:LogSuccess("ok") end))
    end)
end)
