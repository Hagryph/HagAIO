local addonName, ns = ...
local Class = ns.Class

-- Modules/UnitFrames.lua
-- Colours the player & target health bars by remaining health: green at full,
-- through yellow, to red when low.
--
-- Built from the official ColorCurveObject example (warcraft.wiki.gg): a colour
-- curve evaluated by UnitHealthPercent yields a (secret) colour we apply with
-- GetStatusBarTexture():SetVertexColor. Two practical notes the example implies:
--   * The default bar's fill is a GREEN atlas, and vertex colour MULTIPLIES it,
--     so hue can't change. We swap it for the example's flat texture, which
--     tints to any colour at full brightness.
--   * Updates are driven by UNIT_HEALTH (per the example). We also hook
--     UnitFrameHealthBar_Update only to learn the real bar object for each unit
--     (a frame-path resolver returns a hidden alias, not the visible bar).

local UnitFrames = Class.new("UnitFrames", ns.Module)

local FLAT = "Interface\\TargetingFrame\\UI-StatusBar"

local function buildCurve()
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Linear)
    curve:AddPoint(0.0, CreateColor(0.95, 0.13, 0.13))  -- 0%   red
    curve:AddPoint(0.5, CreateColor(0.95, 0.82, 0.15))  -- 50%  yellow
    curve:AddPoint(1.0, CreateColor(0.10, 0.85, 0.10))  -- 100% green
    return curve
end

local function apiAvailable()
    return C_CurveUtil and C_CurveUtil.CreateColorCurve and UnitHealthPercent and CreateColor
end

-- Swap the fill for a flat, tintable texture once (remembering the original so
-- we can restore it on disable).
local function ensureFlat(bar)
    if bar.__hagFlat then return end
    local tex = bar:GetStatusBarTexture()
    bar.__hagOrigAtlas = tex and tex.GetAtlas and tex:GetAtlas() or nil
    bar:SetStatusBarTexture(FLAT)
    bar.__hagFlat = true
end

local function restore(bar)
    if not bar.__hagFlat then return end
    local tex = bar:GetStatusBarTexture()
    if tex then
        tex:SetVertexColor(1, 1, 1)
        if bar.__hagOrigAtlas and tex.SetAtlas then tex:SetAtlas(bar.__hagOrigAtlas) end
    end
    bar.__hagFlat = nil
end

-- The hook is global and can't be removed; install once per session.
local installed = false

-- ---- lifecycle ------------------------------------------------------------
function UnitFrames:OnInitialize()
    local p = self:_p()
    p.curve = nil
    p.bars = {}      -- unit -> the real StatusBar (learned from the hook)
    p.tokens = {}
end

function UnitFrames:OnEnable()
    if not apiAvailable() then
        self:LogWarn("health-bar colouring isn't supported on this client build")
        return
    end
    local p = self:_p()
    p.curve = buildCurve()

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

    -- Drive recolouring on health changes (the example's UNIT_HEALTH approach).
    local bus = ns.EventBus.Get()
    p.tokens["UNIT_HEALTH"]            = bus:On("UNIT_HEALTH",           function(_, u) self:_Color(u) end)
    p.tokens["UNIT_MAXHEALTH"]        = bus:On("UNIT_MAXHEALTH",        function(_, u) self:_Color(u) end)
    p.tokens["PLAYER_TARGET_CHANGED"] = bus:On("PLAYER_TARGET_CHANGED", function() self:_Color("target") end)

    self:_Color("player")
    self:_Color("target")
end

function UnitFrames:OnDisable()
    local p = self:_p()
    local bus = ns.EventBus.Get()
    for event, token in pairs(p.tokens) do bus:Off(event, token) end
    wipe(p.tokens)
    for _, bar in pairs(p.bars) do restore(bar) end
end

-- ---- colouring ------------------------------------------------------------
function UnitFrames:_Color(unit)
    if unit ~= "player" and unit ~= "target" then return end
    if not self:IsEnabled() or not self:GetSetting(unit) then return end
    if unit == "target" and not UnitExists("target") then return end
    local p = self:_p()
    local bar = p.bars[unit]
    if not (bar and bar.GetStatusBarTexture and p.curve) then return end

    ensureFlat(bar)
    local color = UnitHealthPercent(unit, true, p.curve)  -- holds secret values
    if color then
        bar:GetStatusBarTexture():SetVertexColor(color:GetRGB())
    end
end

function UnitFrames:OnSettingChanged(key)
    local p = self:_p()
    for unit, bar in pairs(p.bars) do
        if self:GetSetting(unit) then self:_Color(unit) else restore(bar) end
    end
end

-- ---- registration ---------------------------------------------------------
ns.ModuleManager.Get():Register(UnitFrames:New("UnitFrames", {
    title = "Unit Frames",
    description = "Colours the player and target health bars by how much health is left.",
    defaultEnabled = true,
    color = ns.Theme.hex.win,
    settings = {
        { type = "header", text = "Health bar tint" },
        { type = "toggle", key = "player", label = "Tint player health bar", default = true },
        { type = "toggle", key = "target", label = "Tint target health bar", default = true },
        { type = "note", text = "Full health is green, fading through yellow to bright red as health drops." },
    },
}))
