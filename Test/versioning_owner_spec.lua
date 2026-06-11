local S = dofile("Test/support.lua")

-- Locks the ns.VersioningOwner mixin (Core/VersioningOwner.lua): binding a Module/Service to ONE
-- data-version domain, then delegating IsVersionCurrent / StampVersion / SavedVersion to the shared
-- ns.Versioning service WITHOUT repeating the domain. We mix it onto a throwaway class and stub
-- ns.Versioning so the delegation (and the domain it forwards) is observable.

local function newOwner()
    local ns = S.newNs()
    local calls = {}
    ns.Versioning = {
        current = false,
        saved = nil,
        IsCurrent = function(self, domain) calls[#calls + 1] = { "IsCurrent", domain }; return self.current end,
        Stamp     = function(self, domain) calls[#calls + 1] = { "Stamp", domain } end,
        Get       = function(self, domain) calls[#calls + 1] = { "Get", domain }; return self.saved end,
    }
    local Owner = ns.Class.new("Owner", nil, { mixins = { ns.VersioningOwner } })
    local o = Owner:New()                       -- _p() comes from Class
    return o, ns, calls
end

describe("VersioningOwner", function()
    it("forwards the bound domain to the service on every call", function()
        local o, ns, calls = newOwner()
        o:SetVersionDomain("dashboard_catalog")
        assert.are.equal("dashboard_catalog", o:VersionDomain())

        ns.Versioning.current = true
        assert.is_true(o:IsVersionCurrent())
        o:StampVersion()
        ns.Versioning.saved = { build = 120005, patch = "12.0.5" }
        assert.are.equal(120005, o:SavedVersion().build)

        assert.are.equal("IsCurrent", calls[1][1]); assert.are.equal("dashboard_catalog", calls[1][2])
        assert.are.equal("Stamp",     calls[2][1]); assert.are.equal("dashboard_catalog", calls[2][2])
        assert.are.equal("Get",       calls[3][1]); assert.are.equal("dashboard_catalog", calls[3][2])
    end)

    it("errors if a version method is used before the domain is set", function()
        local o = newOwner()
        assert.has_error(function() o:IsVersionCurrent() end)
        assert.has_error(function() o:StampVersion() end)
    end)

    it("rejects an empty or non-string domain", function()
        local o = newOwner()
        assert.has_error(function() o:SetVersionDomain("") end)
        assert.has_error(function() o:SetVersionDomain(nil) end)
    end)

    it("degrades to a safe no-op / nil when the service is absent", function()
        local o, ns = newOwner()
        ns.Versioning = nil
        o:SetVersionDomain("dashboard_catalog")
        assert.is_false(o:IsVersionCurrent())   -- no service -> not current
        assert.is_nil(o:SavedVersion())         -- no service -> nil
        o:StampVersion()                        -- no service -> no error
    end)
end)
