local addonName, ns = ...
local Class = ns.Class

-- Services/Geometry.lua
-- Pure 2D geometry helpers -- no WoW API. Distances and a point->many-points "nearest"
-- solver, reusable by anything that needs proximity (flight-path landing detection,
-- frame snapping, ...). Callers do their own coordinate-space filtering (e.g. same
-- continent) before handing in a flat list of candidate points.

local Geometry = Class.new("Geometry", ns.Lib)

-- Squared distance (cheap; use for comparisons to avoid sqrt).
function Geometry:Dist2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return dx * dx + dy * dy
end

-- True Euclidean distance.
function Geometry:Dist(ax, ay, bx, by)
    return math.sqrt(self:Dist2(ax, ay, bx, by))
end

-- Nearest of `points` to (x, y). Each point is a table with numeric `x`, `y` (any other
-- fields are ignored and the point is returned untouched). `maxDist`, if given, caps the
-- match (inclusive). Returns (point, distance), or (nil, nil) if none qualify. Points
-- with a missing x/y are skipped.
function Geometry:Nearest(x, y, points, maxDist)
    local best, bestD2 = nil, maxDist and (maxDist * maxDist) or math.huge
    for i = 1, #points do
        local pt = points[i]
        if pt and pt.x and pt.y then
            local d2 = self:Dist2(x, y, pt.x, pt.y)
            if d2 <= bestD2 then best, bestD2 = pt, d2 end
        end
    end
    if not best then return nil end
    return best, math.sqrt(bestD2)
end

ns.LibManager:Register(Geometry:New("Geometry"))
