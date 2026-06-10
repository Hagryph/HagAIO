local addonName, ns = ...
local Class = ns.Class

-- Services/LocalTables.lua
-- Populates the shared database's general REFERENCE tables from the game world -- the data that is
-- the same for everyone and re-derived each session rather than recorded by a feature. Today that is
-- flight-master DISCOVERY: whenever a taxi map is opened, every flight master on that continent (and
-- its zone) is seeded into the flight_master + zone tables (defined centrally in Core/DB/CoreTables).
--
-- This lives in its OWN service rather than the Misc flight module because the reference data belongs
-- to the addon as a whole -- Misc only records flight TIMES on top of what is discovered here, and
-- looks masters up (it never creates them). C_TaxiMap.GetAllTaxiNodes gives every node on the open
-- map; the node's zone comes from its position via C_Map.GetMapInfoAtPosition. A master is only
-- created once its zone is known (flight_master.zone is NOT NULL), so a node whose zone can't be
-- resolved is simply retried the next time the map opens.

local LocalTables = Class.new("LocalTables", ns.Service)

local function playerFaction() return UnitFactionGroup("player") or "?" end

function LocalTables:OnInitialize()
    -- Discover all flight masters (+ their zones) whenever a taxi map opens (deferred -- see below).
    ns.EventBus:On("TAXIMAP_OPENED", function() self:_ScheduleDiscover() end)
end

-- Discovery scans every node on the open map and writes the flight_master/zone tables -- enough work
-- to hitch the frame the taxi map opens. Defer it (C_Timer.After) so the map opens instantly and the
-- nodes are read on the next frame; the map stays open, so GetTaxiMapID is still valid. Coalesced so
-- one pass runs per open, not one per stacked fire.
function LocalTables:_ScheduleDiscover()
    local p = self:_p()
    if p.discoverPending then return end
    p.discoverPending = true
    C_Timer.After(0, function()
        p.discoverPending = false
        self:_DiscoverNodes()
    end)
end

-- The zone NAME (and map x,y) at a position, seeding the local `zone` table from the world map.
-- Returns (zoneName, x, y); nil if the zone can't be resolved.
function LocalTables:_ZoneAt(mapID, position)
    if not (C_Map and C_Map.GetMapInfoAtPosition and position) then return nil end
    local x, y
    if position.GetXY then x, y = position:GetXY() else x, y = position.x, position.y end
    if not (x and y) then return nil end
    local info = C_Map.GetMapInfoAtPosition(mapID, x, y)
    if not (info and info.name) then return nil end
    local db = self:DB()
    if db and #db:Select("name"):From("zone"):Where("name", "=", info.name):Limit(1):Run() == 0 then
        pcall(function() db:Insert("zone", { name = info.name }) end)
    end
    return info.name, x, y
end

-- Insert or enrich the flight_master for this canonical nodeID. The node is keyed by node_id (one
-- row per physical flight point). If a row already exists under a DIFFERENT faction, BOTH factions
-- can see this point, so it's NEUTRAL -- flip it. `zone` is required (NOT NULL); a node whose zone
-- is unknown is skipped (retried next time the map opens).
function LocalTables:_DiscoverMaster(faction, name, nodeID, zone, x, y)
    local db = self:DB(); if not db or not zone or not nodeID then return end
    local row = db:Select("faction", "zone", "name"):From("flight_master")
        :Where("node_id", "=", nodeID):Limit(1):Run()[1]
    if not row then
        db:Insert("flight_master", { node_id = nodeID, faction = faction, zone = zone, name = name, x = x, y = y })
        return
    end
    local changes = {}
    if row.faction ~= faction and row.faction ~= "Neutral" then changes.faction = "Neutral" end  -- seen by both factions
    if zone and row.zone ~= zone then changes.zone = zone end
    if name and row.name ~= name then changes.name = name end
    if next(changes) then db:Update("flight_master", changes, function(r) return r.node_id == nodeID end) end
end

-- Discover every node on the open taxi map (all flight masters on the continent). Faction can't be
-- read per node from the API, so it starts as the player's; cross-faction rediscovery flips it to
-- Neutral above.
function LocalTables:_DiscoverNodes()
    local db = self:DB(); if not db then return end
    local faction = playerFaction()
    if faction ~= "Alliance" and faction ~= "Horde" and faction ~= "Neutral" then return end
    if not (C_TaxiMap and C_TaxiMap.GetAllTaxiNodes and GetTaxiMapID) then return end
    local mapID = GetTaxiMapID()
    if not mapID then return end
    local nodes = C_TaxiMap.GetAllTaxiNodes(mapID)
    if not nodes then return end
    for _, n in ipairs(nodes) do
        if n.name and n.nodeID then
            local name = ns.FlightResolver:NodeName(n.name)
            local zone, x, y = self:_ZoneAt(mapID, n.position)
            pcall(function() self:_DiscoverMaster(faction, name, n.nodeID, zone, x, y) end)
        end
    end
end

ns.ServiceManager:Register(LocalTables:New("LocalTables", { deps = { "EventBus" } }))
