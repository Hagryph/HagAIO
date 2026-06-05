local addonName, ns = ...
local Class = ns.Class

-- Modules/UnitFrames.lua
-- Tints the player & target health bars by remaining health: green at full,
-- through yellow, to bright red when low.
--
-- Approach (matches how unit-frame colour addons do it): hook Blizzard's own
-- per-update handler UnitFrameHealthBar_Update ONCE. It already runs on every
-- health change and sets the bar colour, so we just re-set ours right after —
-- no extra event registration, no polling. Colour comes from the Secret-Values-
-- safe colour curve (the engine evaluates the secret health for us).

local UnitFrames = Class.new("UnitFrames", ns.Module)

-- green (full) -> yellow (half) -> bright red (low)
local GREEN  = { 0.10, 0.85, 0.10 }
local YELLOW = { 0.95, 0.82, 0.15 }
local RED    = { 0.95, 0.13, 0.13 }

local function mix(a, b, u)
    return a[1] + (b[1] - a[1]) * u,
           a[2] + (b[2] - a[2]) * u,
           a[3] + (b[3] - a[3]) * u
end

local function colorAt(t)  -- t: 1 -> green, 0.5 -> yellow, 0 -> red
    local r, g, b
    if t >= 0.5 then
        r, g, b = mix(YELLOW, GREEN, (t - 0.5) / 0.5)
    else
        r, g, b = mix(RED, YELLOW, t / 0.5)
    end
    return CreateColor(r, g, b, 1)
end

local function resolveBar(unit)
    local f = (unit == "player") and PlayerFrame or (unit == "target") and TargetFrame
    if not f then return nil end
    if f.healthbar then return f.healthbar end
    if f.healthBar then return f.healthBar end
    return _G[(unit == "player") and "PlayerFrameHealthBar" or "TargetFrameHealthBar"]
end

local function apiAvailable()
    return C_CurveUtil and C_CurveUtil.CreateColorCurve and UnitHealthPercent and CreateColor
end

-- The hook is global and can't be removed, so install it once per session;
-- it stays inert while the module is disabled.
local installed = false

-- ---- lifecycle ------------------------------------------------------------
function UnitFrames:OnInitialize()
    self:_p().curve = nil
end

function UnitFrames:OnEnable()
    if not apiAvailable() then
        self:LogWarn("health-bar colouring isn't supported on this client build")
        return
    end
    self:_BuildCurve()

    if not installed then
        if type(UnitFrameHealthBar_Update) ~= "function" then
            self:LogWarn("couldn't hook the unit-frame health bar update")
            return
        end
        local module = self
        hooksecurefunc("UnitFrameHealthBar_Update", function(statusbar, unit)
            module:_Tint(statusbar, unit)
        end)
        installed = true
    end

    ns.SlashCommand.Get():Register("uf", function() self:_Diag() end, "diagnose health-bar tint")

    self:_ApplyNow()
end

function UnitFrames:OnDisable()
    self:_RestoreNow()
end

-- ---- colouring ------------------------------------------------------------
function UnitFrames:_BuildCurve()
    local p = self:_p()
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType((Enum.LuaCurveType and Enum.LuaCurveType.Linear) or Enum.LuaCurveType.Step)
    curve:AddPoint(0.0, colorAt(0.0))
    curve:AddPoint(0.5, colorAt(0.5))
    curve:AddPoint(1.0, colorAt(1.0))
    p.curve = curve
end

-- Called by the hook after every Blizzard health-bar update. We only act on the
-- player/target bars (other frames pass through untouched).
function UnitFrames:_Tint(statusbar, unit)
    if unit ~= "player" and unit ~= "target" then return end
    local p = self:_p()
    p.fires = (p.fires or 0) + 1
    if not self:IsEnabled() then return end
    if not self:GetSetting(unit) then return end
    local curve = p.curve
    if not (curve and statusbar and statusbar.GetStatusBarTexture) then return end
    local tex = statusbar:GetStatusBarTexture()
    if not tex then return end
    -- The colour holds secret values. SetVertexColor accepts secrets;
    -- SetStatusBarColor silently ignores them — so tint the fill texture.
    local color = UnitHealthPercent(unit, true, curve)
    if color then
        p.applied = (p.applied or 0) + 1
        tex:SetVertexColor(color:GetRGB())
    end
end

-- /hag uf — report state and force the player/target bars BLUE so we can see
-- whether the frames we colour are the ones on screen.
function UnitFrames:_Diag()
    self:LogInfo(("api:%s  installed:%s  enabled:%s")
        :format(apiAvailable() and "ok" or "MISSING", tostring(installed), tostring(self:IsEnabled())))
    for _, unit in ipairs({ "player", "target" }) do
        local bar = resolveBar(unit)
        local name = bar and (bar.GetName and bar:GetName() or "anon") or "NOT FOUND"
        self:LogInfo(("%s bar: %s"):format(unit, tostring(name)))
        if bar and bar.GetStatusBarTexture then
            local tex = bar:GetStatusBarTexture()
            if tex then tex:SetVertexColor(0, 0.4, 1) end  -- force blue
        end
    end
    local color = apiAvailable() and self:_p().curve and UnitHealthPercent("player", true, self:_p().curve)
    self:LogInfo(("UnitHealthPercent(player): %s"):format(color and "got colour" or "nil"))
    self:LogInfo(("hook fired %d times, colour applied %d times"):format(self:_p().fires or 0, self:_p().applied or 0))
    self:LogWarn("forced player/target bars BLUE — if you DON'T see blue, the on-screen bars belong to another addon")
end

-- Apply our tint to the current player/target bars directly. We must NOT call
-- Blizzard's UnitFrameHealthBar_Update ourselves — doing so taints its
-- execution and its internal secret-health comparison then errors. Setting the
-- colour directly involves no comparisons, so it's taint-free.
function UnitFrames:_ApplyNow()
    for _, unit in ipairs({ "player", "target" }) do
        if UnitExists(unit) then
            local bar = resolveBar(unit)
            if bar then self:_Tint(bar, unit) end
        end
    end
end

-- Restore Blizzard's default green directly (taint-free). The next natural
-- unit-frame update reasserts Blizzard's own colouring fully.
function UnitFrames:_RestoreNow()
    for _, unit in ipairs({ "player", "target" }) do
        local bar = resolveBar(unit)
        if bar and bar.SetStatusBarColor then bar:SetStatusBarColor(0, 1, 0) end
    end
end

function UnitFrames:OnSettingChanged()
    for _, unit in ipairs({ "player", "target" }) do
        local bar = UnitExists(unit) and resolveBar(unit) or nil
        if bar and bar.SetStatusBarColor then
            if self:GetSetting(unit) then
                self:_Tint(bar, unit)
            else
                bar:SetStatusBarColor(0, 1, 0)
            end
        end
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
