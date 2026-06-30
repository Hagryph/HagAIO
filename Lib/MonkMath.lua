local addonName, ns = ...

-- Lib/MonkMath.lua
-- Pure combat arithmetic for the Monk module -- no WoW API, no state. Extracted from
-- Monk.lua so the numbers that decide on-screen behaviour are unit-testable:
--   * AoEThreshold  -- the SCK-beats-Tiger-Palm target count (the AoE-helper breakpoint).
--   * OrbFill       -- the StatusBar min/max/width that bake the base heal into a secret-
--                      count fill so its fraction is the true heal-to point.
--   * SumEnergyCosts-- combined non-secret energy cost across spells (Tiger Palm + Keg Smash).
--   * CostPoint     -- the cost point in pixels from a bar's left edge.

local MonkMath = {}

local floor, max = math.floor, math.max

-- Smallest target count N where Spinning Crane Kick (hits all N) out-damages Tiger Palm by
-- the bias factor: sck*N > tp*bias  ->  N = floor(tp*bias / sck) + 1. Returns nil when the
-- damages aren't both known (caller falls back to the conventional 3).
function MonkMath.AoEThreshold(tp, sck, bias)
    if not (tp and sck and sck > 0) then return nil end
    return max(1, floor((tp * bias) / sck) + 1)
end

-- StatusBar geometry for the orb-aware Expel Harm heal fill. The bar's VALUE is the secret
-- Gift-of-the-Ox sphere count, which we can't offset/scale ourselves -- so we bake the base
-- heal into min/max with plain math. Returns (min, max, spanPx) such that the StatusBar
-- fraction (count - min)/(max - min) equals the true heal fraction
-- (baseHeal + count*orbHeal)/(baseHeal + orbMax*orbHeal), and spanPx is the full-span width
-- in pixels. The 1e-9 floor guards a divide-by-zero if orbHeal is ever 0.
function MonkMath.OrbFill(baseHeal, orbHeal, orbMax, maxHP, width)
    local min  = -baseHeal / max(orbHeal, 1e-9)
    local span = (baseHeal + orbMax * orbHeal) / maxHP * width
    return min, orbMax, span
end

-- Sum the non-secret ENERGY cost across several spells. `costsPerSpell` is a list of the
-- cost-entry arrays C_Spell.GetSpellPowerCost returns (one per spell); each entry is
-- { type = powerType, cost = n }. Skips other power types and any secret cost (isSecret(v),
-- optional). Pure: the caller does the API reads and hands the raw data in.
function MonkMath.SumEnergyCosts(costsPerSpell, energyType, isSecret)
    local total = 0
    for _, costs in ipairs(costsPerSpell or {}) do
        for _, c in ipairs(costs or {}) do
            if c.type == energyType and c.cost and not (isSecret and isSecret(c.cost)) then
                total = total + c.cost
            end
        end
    end
    return total
end

-- The cost point in pixels from a bar's left edge: where `cost` sits on a `maxE`-wide bar
-- rendered `barW` pixels wide.
function MonkMath.CostPoint(cost, maxE, barW)
    return (cost / maxE) * barW
end

-- Grace of the Crane raises all healing taken by a flat % the Expel Harm tooltip doesn't fold
-- in. Turn the parsed percent (or the 4% default when it can't be read) into a multiplier:
-- 1 + pct/100. The caller does the talent gate + description read and hands the parsed pct in
-- (nil -> the 4% default).
function MonkMath.HealingTakenMultiplier(pct)
    pct = pct or 4
    return 1 + pct / 100
end

-- Round a parsed tooltip heal by the healing-taken multiplier: floor(heal * mult + 0.5).
-- Returns nil when the heal wasn't parsed, so the caller falls back. (Used for the base
-- Expel Harm heal.)
function MonkMath.RoundHeal(heal, mult)
    if not heal then return nil end
    return floor(heal * mult + 0.5)
end

-- Round a parsed per-sphere heal by the healing-taken multiplier: floor(n * mult + 0.5).
-- Returns 0 when the heal wasn't parsed (no sphere talent / unreadable), matching the
-- orb-heal "0 otherwise" contract.
function MonkMath.RoundOrbHeal(n, mult)
    if not n then return 0 end
    return floor(n * mult + 0.5)
end

-- Accept a parsed tooltip hit damage only if it's a usable, NON-SECRET positive number:
-- reject nil, <= 0, and any secret value (isSecret(v), optional) -- a secret must NOT be
-- parsed into the breakpoint math. Returns the value, or nil for the caller to fall back.
function MonkMath.AcceptHitDamage(v, isSecret)
    if not v or v <= 0 or (isSecret and isSecret(v)) then return nil end
    return v
end

ns.LibManager:RegisterValue("MonkMath", MonkMath)
