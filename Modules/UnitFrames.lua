local addonName, ns = ...
local Class = ns.Class

-- Modules/UnitFrames.lua
-- Colours the player & target health bars by remaining health: green at full,
-- through yellow, to red when low.
--
-- Built from the official ColorCurveObject example (warcraft.wiki.gg): a colour
-- curve evaluated by UnitHealthPercent yields a (secret) colour we apply to the
-- health-bar fill. Two practical notes:
--   * The default fill is a GREEN atlas, and a plain colour MULTIPLIES it, so the
--     hue can't change. We DON'T swap the texture for a flat one -- doing that drops
--     the atlas's built-in trim, so a plain texture fills past the frame art (the
--     fill shifts and paints over the border). Instead we DESATURATE the atlas in
--     place (stripping its green to greyscale) and tint that, which keeps Blizzard's
--     exact texture shape + inset, so the border stays intact.
--   * Updates are driven by UNIT_HEALTH (per the example). We also hook
--     UnitFrameHealthBar_Update only to learn the real bar object for each unit
--     (a frame-path resolver returns a hidden alias, not the visible bar).

local UnitFrames = Class.new("UnitFrames", ns.Module)

-- gradient endpoints (also the settings defaults)
local DEF_START = { 0.90, 0.15, 0.15 }  -- low health  (red)
local DEF_MID   = { 0.95, 0.82, 0.15 }  -- mid health  (yellow)
local DEF_END   = { 0.20, 0.80, 0.20 }  -- full health (green)

local function apiAvailable()
    return C_CurveUtil and C_CurveUtil.CreateColorCurve and UnitHealthPercent and CreateColor
end

-- Recolour the fill IN PLACE, never replacing the texture (that broke geometry):
--   * desaturate the atlas so its baked-in green doesn't multiply our tint away
--     (lets red/yellow actually show), and
--   * tint via SetStatusBarColor (falls back to the fill texture's vertex colour).
-- Keeping the atlas preserves its trim/mask, so the fill stays inside the border.
local function paint(bar, r, g, b)
    local tex = bar:GetStatusBarTexture()
    if not tex then return end
    if tex.SetDesaturated then tex:SetDesaturated(true) end
    if bar.SetStatusBarColor then bar:SetStatusBarColor(r, g, b) else tex:SetVertexColor(r, g, b) end
end

local function restore(bar)
    local tex = bar:GetStatusBarTexture()
    if tex and tex.SetDesaturated then tex:SetDesaturated(false) end
    if bar.SetStatusBarColor then bar:SetStatusBarColor(1, 1, 1) elseif tex then tex:SetVertexColor(1, 1, 1) end
end

-- The hook is global and can't be removed; install once per session.
local installed = false

-- ---- lifecycle ------------------------------------------------------------
function UnitFrames:OnInitialize()
    local p = self:_p()
    p.curve = nil
    p.bars = {}      -- unit -> the real StatusBar (learned from the hook)
end

function UnitFrames:OnEnable()
    if not apiAvailable() then
        self:LogWarn("health-bar colouring isn't supported on this client build")
        return
    end
    local p = self:_p()
    p.curve = self:_BuildCurve()

    -- Learn the real bar object per unit, and recolour after Blizzard's update.
    if not installed and type(UnitFrameHealthBar_Update) == "function" then
        local module = self
        hooksecurefunc("UnitFrameHealthBar_Update", function(statusbar, unit)
            if unit == "player" or unit == "target" then
                module:_p().bars[unit] = statusbar
                module:_Color(unit)
            end
        end)
        installed = true
    end

    -- Drive recolouring on health changes (the example's UNIT_HEALTH approach). Filtered
    -- to player/target at REGISTRATION (RegisterUnitEvent) so these high-churn events
    -- never dispatch for the dozens of other units in a raid. Auto-released on disable.
    local units = { "player", "target" }
    self:OnUnit("UNIT_HEALTH",    units, function(_, u) self:_Color(u) end)
    self:OnUnit("UNIT_MAXHEALTH", units, function(_, u) self:_Color(u) end)
    self:On("PLAYER_TARGET_CHANGED", function() self:_Color("target") end)

    self:_Color("player")
    self:_Color("target")
end

function UnitFrames:OnDisable()
    local p = self:_p()
    for _, bar in pairs(p.bars) do restore(bar) end
end

-- ---- colouring ------------------------------------------------------------
-- Build the colour curve from the configured colours: low colour at/below 30%,
-- mid at ~55%, full colour at 100%.
function UnitFrames:_BuildCurve()
    local lo  = self:GetSetting("startColor") or DEF_START
    local mid = self:GetSetting("midColor")   or DEF_MID
    local hi  = self:GetSetting("endColor")   or DEF_END
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Linear)
    curve:AddPoint(0.00, CreateColor(lo[1], lo[2], lo[3]))
    curve:AddPoint(0.30, CreateColor(lo[1], lo[2], lo[3]))
    curve:AddPoint(0.55, CreateColor(mid[1], mid[2], mid[3]))
    curve:AddPoint(1.00, CreateColor(hi[1], hi[2], hi[3]))
    return curve
end

function UnitFrames:_Color(unit)
    if unit ~= "player" and unit ~= "target" then return end
    if not self:IsEnabled() or not self:GetSetting(unit) then return end
    if unit == "target" and not UnitExists("target") then return end
    local p = self:_p()
    local bar = p.bars[unit]
    if not (bar and bar.GetStatusBarTexture and p.curve) then return end

    local color = UnitHealthPercent(unit, true, p.curve)  -- holds secret values
    if color then paint(bar, color:GetRGB()) end
end

-- Settings reactions are declared via `settingsWatch` (see registration below):
-- a colour change rebuilds the curve; ANY change then re-applies to the live bars.
function UnitFrames:_RebuildCurve()
    self:_p().curve = self:_BuildCurve()
end

function UnitFrames:_ApplyColors()
    local p = self:_p()
    for unit, bar in pairs(p.bars) do
        if self:GetSetting(unit) then self:_Color(unit) else restore(bar) end
    end
end

-- ---- registration ---------------------------------------------------------
ns.ModuleManager:Register(UnitFrames:New("UnitFrames", {
    title = "Unit Frames",
    description = "Colours the player and target health bars by how much health is left.",
    defaultEnabled = false,
    color = ns.Theme.hex.green,
    -- Rebuild the curve when a colour changes; re-apply to the bars on any change.
    settingsWatch = {
        startColor = "_RebuildCurve", midColor = "_RebuildCurve", endColor = "_RebuildCurve",
        ["*"] = "_ApplyColors",
    },
    settings = {
        { type = "header", text = "Health bar tint" },
        { type = "toggle", key = "player", label = "Tint player health bar", default = true },
        { type = "toggle", key = "target", label = "Tint target health bar", default = true },

        { type = "header", text = "Colours" },
        { type = "color", key = "endColor",   label = "Full health", default = DEF_END,   dependsOn = { "player", "target" } },
        { type = "color", key = "midColor",   label = "Mid health",  default = DEF_MID,   dependsOn = { "player", "target" } },
        { type = "color", key = "startColor", label = "Low health",  default = DEF_START, dependsOn = { "player", "target" } },
        { type = "note", text = "Health fades from Full at 100% through Mid to Low at 30% and below." },
    },
}))
