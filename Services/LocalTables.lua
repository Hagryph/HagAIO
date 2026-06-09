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
    -- Discover all flight masters (+ their zones) whenever a taxi map opens.
    ns.EventBus:On("TAXIMAP_OPENED", function() self:_DiscoverNodes() end)
end

-- The zone NAME at a map position, seeding the local `zone` table from the world map; nil if unknown.
function LocalTables:_ZoneAt(mapID, position)
    if not (C_Map and C_Map.GetMapInfoAtPosition and position) then return nil end
    local x, y
    if position.GetXY then x, y = position:GetXY() else x, y = position.x, position.y end
    if not (x and y) then return nil end
    local info = C_Map.GetMapInfoAtPosition(mapID, x, y)
    if not (info and info.name and info.mapID) then return nil end
    local db = self:DB()
    if db and #db:Select("id"):From("zone"):Where("id", "=", info.mapID):Limit(1):Run() == 0 then
        pcall(function() db:Insert("zone", { id = info.mapID, name = info.name }) end)
    end
    return info.name
end

-- Insert or enrich the flight_master for (faction, name): set its canonical nodeID + zone. `zone` is
-- required (NOT NULL) -- a node whose zone is unknown is skipped (retried next time the map opens).
function LocalTables:_DiscoverMaster(faction, name, nodeID, zone)
    local db = self:DB(); if not db or not zone then return end
    local row = db:Select("id", "node_id", "zone"):From("flight_master")
        :Where("faction", "=", faction):AndWhere("name", "=", name):Limit(1):Run()[1]
    if not row then
        db:Insert("flight_master", { faction = faction, name = name, node_id = nodeID, zone = zone })
        return
    end
    local changes = {}
    if nodeID and row.node_id ~= nodeID then changes.node_id = nodeID end
    if zone and row.zone ~= zone then changes.zone = zone end
    if next(changes) then db:Update("flight_master", changes, function(x) return x.id == row.id end) end
end

-- Discover every node on the open taxi map (all flight masters on the continent). Faction can't be
-- read per node from the API, so it's the player's (you only see your own + neutral nodes).
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
            local zone = self:_ZoneAt(mapID, n.position)
            pcall(function() self:_DiscoverMaster(faction, name, n.nodeID, zone) end)
        end
    end
end

ns.ServiceManager:Register(LocalTables:New("LocalTables", { deps = { "EventBus" } }))
