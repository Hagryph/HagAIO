local addonName, ns = ...
local sqrt, huge = math.sqrt, math.huge
local rad, deg = math.rad, math.deg
local cos, sin, atan2 = math.cos, math.sin, math.atan2

-- Lib/Vector2D.lua
-- A pure 2D vector value-TYPE (ns.Type) -- no WoW API. Unlike the singleton libs in this
-- folder you INSTANTIATE it (ns.Vector2D:New(x, y)); it carries the usual 2D math (add /
-- sub / scale / length / distance) plus Nearest(), which finds the closest vector in a list.
-- Callers still do their own coordinate-space filtering (e.g. same continent) before handing
-- in candidates.
--
--   local here = ns.Vector2D:New(px, py)
--   local closest, dist, i = here:Nearest(candidateVectors, 40)

-- ns.Type gives New(x, y), the :X()/:Y() accessors, value-equality and a readable tostring;
-- x/y default to 0 and live in the private :_p() table (immutable -- no setters).
local Vector2D = ns.Type.new("Vector2D", { "x", "y" }, { x = 0, y = 0 })

function Vector2D:Unpack() local p = self:_p(); return p.x, p.y end

-- Arithmetic -- each returns a NEW vector (instances are treated as immutable).
function Vector2D:Add(o)   return Vector2D:New(self:_p().x + o:X(), self:_p().y + o:Y()) end
function Vector2D:Sub(o)   return Vector2D:New(self:_p().x - o:X(), self:_p().y - o:Y()) end
function Vector2D:Scale(k) return Vector2D:New(self:_p().x * k, self:_p().y * k) end

function Vector2D:LengthSq() local p = self:_p(); return p.x * p.x + p.y * p.y end
function Vector2D:Length()   return sqrt(self:LengthSq()) end

-- Squared distance (cheap; use for comparisons to skip the sqrt).
function Vector2D:Dist2(o)
    local p = self:_p()
    local dx, dy = p.x - o:X(), p.y - o:Y()
    return dx * dx + dy * dy
end
function Vector2D:Dist(o) return sqrt(self:Dist2(o)) end

-- Nearest of `vectors` to this one. `maxDist` (optional) caps the match INCLUSIVELY; on a
-- distance tie the FIRST candidate wins (strict <). Returns (vector, distance, index), or
-- nil if none qualify. nil entries in the list are skipped.
function Vector2D:Nearest(vectors, maxDist)
    local cap = maxDist and (maxDist * maxDist) or huge
    local best, bestD2, bestI = nil, huge, nil
    for i = 1, #vectors do
        local v = vectors[i]
        if v then
            local d2 = self:Dist2(v)
            if d2 <= cap and d2 < bestD2 then best, bestD2, bestI = v, d2, i end
        end
    end
    if not best then return nil end
    return best, sqrt(bestD2), bestI
end

-- Polar -> Cartesian on a ring. Given a radius and an angle in DEGREES (measured from the
-- centre, 0 = +x, counter-clockwise), return the (x, y) offset of the point on the ring.
-- Pure form of the minimap-icon rim placement.
function Vector2D.OnRing(radius, angleDeg)
    local a = rad(angleDeg)
    return radius * cos(a), radius * sin(a)
end

-- Cartesian delta -> angle in DEGREES. Given a vector (dx, dy) from the centre to a point,
-- return its angle measured the same way OnRing uses. Pure form of the drag-to-angle math
-- (keeps math.atan2, which WoW's Lua retains).
function Vector2D.AngleOf(dx, dy)
    return deg(atan2(dy, dx))
end

ns.LibManager:RegisterValue("Vector2D", Vector2D)
