local addonName, ns = ...

-- Lib/ColorCurve.lua
-- Pure colour-curve construction -- no WoW API, no state. HealthBarSkin uses it so the
-- "three settings endpoints (low/mid/full colours) -> ColorCurve points" mapping is unit-testable.
--   * HealthPoints(lo, mid, hi) returns the ordered list of { pos, r, g, b } the health-bar curve
--     is built from: low colour pinned at 0% AND 30% (so it holds flat at/below 30%), mid at 55%,
--     full at 100%. Each colour is { r, g, b }. Pure: the caller does the C_CurveUtil /
--     CreateColor / AddPoint API calls and feeds the raw colour tables in.

local ColorCurve = {}

-- The health-bar colour curve points: low colour at/below 30%, mid at ~55%, full at 100%.
-- Returns an ordered list of { pos = <0..1>, r, g, b }; the caller adds each as a curve point.
function ColorCurve.HealthPoints(lo, mid, hi)
    return {
        { pos = 0.00, lo[1], lo[2], lo[3] },
        { pos = 0.30, lo[1], lo[2], lo[3] },
        { pos = 0.55, mid[1], mid[2], mid[3] },
        { pos = 1.00, hi[1], hi[2], hi[3] },
    }
end

ns.LibManager:RegisterValue("ColorCurve", ColorCurve)
