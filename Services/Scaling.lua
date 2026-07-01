local addonName, ns = ...
local Class = ns.Class

-- Services/Scaling.lua
-- Models WoW "up to X% more" health-based scaling (damage OR healing) as a clamped linear
-- ramp with an optional PLATEAU. Mirrors SimulationCraft's missing_health_percentage_t:
--   multiplier = 1 + bonus * t,   t = clamp((highPct - hp) / (highPct - lowPct), 0, 1)
-- For the common pure form (Strength of Spirit, Niuzao's Resolve) highPct=100, lowPct=0,
-- so t is just the missing-health fraction and it scales linearly to ×(1+bonus) at 0%
-- health -- NO plateau (SimC only does max(hp,0) to avoid negatives). Execute-style spells
-- DO plateau: set lowPct to the "maximized at" threshold (e.g. 35) so the bonus caps there
-- and stays flat below it. Some spells ramp the OTHER way (more on high-health targets) --
-- that's direction = "current".
--
-- ALWAYS source the exact bonus / window / plateau from SimulationCraft's class module, not
-- the tooltip wording (it's ambiguous and locale-dependent). See [[feedback_check-simcraft]].
--
-- A spec is an immutable value type: ns.ScalingSpec:New(bonus, highPct, lowPct, direction).
--   bonus     : max fractional bonus (0.80 = +80%)
--   highPct   : health% where the ramp begins (no-bonus side);  default 100
--   lowPct    : health% where the bonus maxes / plateaus;        default 0
--   direction : "missing" (more as HP drops, default) | "current" (more as HP rises)
-- e.g. ns.ScalingSpec:New(0.80) is the pure missing form; nils fall back to the defaults.
--
-- Live HP is a SECRET in restricted content, so you usually can't evaluate at the real
-- health there: use :Band() / :ValueAtFull() / :ValueAtEmpty() for the plain-Lua endpoints
-- and let the engine place the exact point (StatusBar:SetValue / ColorCurve). See
-- [[reference_secret-value-ui]].

local Scaling = Class.new("Scaling", ns.Service)

-- Ramp direction: which end of the health window carries the max bonus.
local ScalingDirection = ns.Enum.new("ScalingDirection", { CURRENT = "current", MISSING = "missing" })

-- A spec is an immutable value type: nils fall back to the defaults at construction, so the
-- endpoints read straight off the accessors (bonus stays nil-able -> treated as 0).
local ScalingSpec = ns.Type.new("ScalingSpec", { "bonus", "highPct", "lowPct", "direction" },
    { highPct = 100, lowPct = 0, direction = ScalingDirection.MISSING })
ns.ScalingSpec = ScalingSpec

local function clamp01(t)
    if t < 0 then return 0 elseif t > 1 then return 1 end
    return t
end

-- Interpolation fraction t in [0,1] at health percent hp (0..100). 0 = no bonus,
-- 1 = full bonus (the plateau). Direction picks which end of the window is the max.
function Scaling:Fraction(spec, hp)
    local hi, lo, dir = spec:HighPct(), spec:LowPct(), spec:Direction()
    if hi == lo then  -- degenerate window -> a hard step at the threshold
        if dir == ScalingDirection.CURRENT then return hp >= hi and 1 or 0 end
        return hp <= hi and 1 or 0
    end
    if dir == ScalingDirection.CURRENT then
        return clamp01((hp - lo) / (hi - lo))   -- more as health rises
    end
    return clamp01((hi - hp) / (hi - lo))        -- more as health drops (the SimC missing form)
end

-- Multiplier (1 + bonus*t) at health percent hp.
function Scaling:Multiplier(spec, hp)
    return 1 + (spec:Bonus() or 0) * self:Fraction(spec, hp)
end

-- base * multiplier at health percent hp.
function Scaling:Value(spec, base, hp)
    return (base or 0) * self:Multiplier(spec, hp)
end

-- Endpoints respecting direction: the value at full (100%) and empty (0%) health. Both are
-- plain numbers (no live HP needed), so a marker can span from one to the other.
function Scaling:ValueAtFull(spec, base)  return self:Value(spec, base, 100) end
function Scaling:ValueAtEmpty(spec, base) return self:Value(spec, base, 0) end

-- The value range across the whole health axis, sorted: minValue, maxValue (= base and
-- base*(1+bonus)). Independent of which end is full -- handy for a heal/damage BAND.
function Scaling:Band(spec, base)
    base = base or 0
    local peak = base * (1 + (spec:Bonus() or 0))
    if base <= peak then return base, peak end
    return peak, base
end

-- The multiplier range: minMult, maxMult (1 and 1+bonus).
function Scaling:MultiplierBand(spec)
    local b = spec:Bonus() or 0
    if b >= 0 then return 1, 1 + b end
    return 1 + b, 1
end

ns.ServiceManager:Register(Scaling:New("Scaling"))
