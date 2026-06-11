local addonName, ns = ...
local Class = ns.Class

-- Services/Versioning.lua
-- General data-version registry -- a SHARED facility, not a per-module table. The game CLIENT only
-- changes across patches, yet some reference data is expensive to derive from the game API (e.g. the
-- Dashboard's whole Encounter Journal catalog). A module saves that data to its own tables ONCE, stamps
-- the client build it belongs to here, and on a later login asks IsCurrent(domain): while the saved
-- build still matches the running client it reconstructs from its own rows instead of rebuilding; on a
-- new patch it rebuilds and re-stamps. One typed row per domain in `data_version`.
--
--   if ns.Versioning:IsCurrent("dashboard_catalog") then ...reconstruct from saved rows...
--   else ...rebuild from the game...; ns.Versioning:Stamp("dashboard_catalog") end
--   ns.Versioning:Get("dashboard_catalog")   -> { build = 120005, patch = "12.0.5" } or nil
--   ns.Versioning:Build()  ns.Versioning:Patch()   -- the running client's .toc build / patch string

local Versioning = Class.new("Versioning", ns.Service)

local function isNull(v) return v == nil or (ns.DB and ns.DB.isNull and ns.DB.isNull(v)) end

-- The running client's .toc interface build (e.g. 120005) and human patch string (e.g. "12.0.5").
function Versioning:Build() return (GetBuildInfo and tonumber((select(4, GetBuildInfo())))) or 0 end
function Versioning:Patch() return tostring((GetBuildInfo and (GetBuildInfo())) or "") end

-- The saved stamp for a domain: { build, patch }, or nil if it was never stamped.
function Versioning:Get(domain)
    local db = self:DB(); if not db then return nil end
    local r = db:Select("build", "patch"):From("data_version"):Where("domain", "=", domain):Limit(1):Run()[1]
    if not r then return nil end
    return { build = not isNull(r.build) and r.build or nil, patch = not isNull(r.patch) and r.patch or nil }
end

-- True iff `domain` was last stamped under the CURRENTLY running client build -- i.e. its cached data is
-- still valid for this patch. False when never stamped or stamped under a different build (a new patch).
function Versioning:IsCurrent(domain)
    local r = self:Get(domain)
    return r ~= nil and r.build == self:Build()
end

-- Record (upsert) that `domain`'s data was just rebuilt under the running client.
function Versioning:Stamp(domain)
    local db = self:DB(); if not db then return end
    local fields = { build = self:Build(), patch = self:Patch() }
    if db:Select("domain"):From("data_version"):Where("domain", "=", domain):Limit(1):Run()[1] then
        db:Update("data_version", fields, function(x) return x.domain == domain end)
    else fields.domain = domain; db:Insert("data_version", fields) end
end

ns.ServiceManager:Register(Versioning:New("Versioning", {
    tables = {
        -- One typed row per cached dataset that is only rebuilt when the game client changes. `domain`
        -- is the caller's opaque key (e.g. "dashboard_catalog"); `build` is the .toc interface number
        -- the data was saved under, compared against the live client to decide reconstruct-vs-rebuild.
        data_version = { scope = "global", columns = {
            { name = "domain", type = "text",    primaryKey = true },   -- caller's dataset key
            { name = "build",  type = "integer" },                      -- client .toc build it was saved under
            { name = "patch",  type = "text" },                         -- patch version string, e.g. "12.0.5"
        } },
    },
}))
