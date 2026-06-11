local addonName, ns = ...

-- Core/VersioningOwner.lua
-- Mixin: bind a Module / Service to ONE data-version DOMAIN so it never has to repeat the domain
-- string. A thin, instance-scoped facade over the shared ns.Versioning service (Services/Versioning.lua):
-- set the domain once with SetVersionDomain (typically in OnInitialize), then ask IsVersionCurrent() /
-- StampVersion() / SavedVersion() without naming the domain again.
--
--   local Dash = ns.Class.new("Dashboard", ns.Module, { mixins = { ns.VersioningOwner } })
--   function Dash:OnInitialize() self:SetVersionDomain("dashboard_catalog") end
--   ...
--   if self:IsVersionCurrent() then ...reconstruct from saved rows...
--   else ...rebuild from the game...; self:StampVersion() end
--
-- The owner must DECLARE "Versioning" as a service dependency (deps = { ..., "Versioning" }) so the
-- service is initialised first -- depcheck enforces this automatically for any class that mixes this in.
-- Every method degrades to a safe no-op / nil when the service is absent (e.g. the headless harness).

-- The bound domain, asserting it was set -- a version call before SetVersionDomain is a programming error.
local function domainOf(self)
    local d = self:_p().versionDomain
    assert(d, "VersioningOwner: call self:SetVersionDomain(domain) before any version method")
    return d
end

ns.VersioningOwner = ns.Mixin.new("VersioningOwner", {
    -- Bind this instance to its data-version domain (its key in the shared data_version registry).
    -- Set it once -- typically in OnInitialize, before the first IsVersionCurrent/StampVersion call.
    SetVersionDomain = function(self, domain)
        assert(type(domain) == "string" and domain ~= "", "SetVersionDomain: domain must be a non-empty string")
        self:_p().versionDomain = domain
    end,

    -- The bound domain, or nil if SetVersionDomain hasn't run yet.
    VersionDomain = function(self) return self:_p().versionDomain end,

    -- True iff this domain's saved data was stamped under the RUNNING client build (its cache is valid
    -- for this patch). False when never stamped, stamped under a different build, or the service is absent.
    IsVersionCurrent = function(self)
        return ns.Versioning ~= nil and ns.Versioning:IsCurrent(domainOf(self))
    end,

    -- Record (upsert) that this domain's data was just rebuilt under the running client.
    StampVersion = function(self)
        if ns.Versioning then ns.Versioning:Stamp(domainOf(self)) end
    end,

    -- This domain's saved stamp: { build, patch }, or nil if never stamped / the service is absent.
    SavedVersion = function(self)
        return ns.Versioning and ns.Versioning:Get(domainOf(self)) or nil
    end,
})
