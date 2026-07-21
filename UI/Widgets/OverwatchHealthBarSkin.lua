local addonName, ns = ...
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt

-- UI/Widgets/OverwatchHealthBarSkin.lua
-- Ports the construction model from Overwatch Nameplate v1.0.1 (Wago 8jzI_7A9R):
-- ten adjacent StatusBars, each rendered through a slanted fragment texture. They
-- replace Blizzard's fill instead of drawing marks over it. Midnight health remains
-- secret-safe: ten curves map the same health percentage into each fragment and the
-- engine crops every StatusBar without Lua reading or comparing the value.
local OverwatchHealthBarSkinW = ns.Class.new("OverwatchHealthBarSkin", FrameWidget, {
    statics = {
        segmentCount = 10,
        texture = "Interface\\AddOns\\HagAIO\\Media\\overwatch-segment",
    },
})
local S = ns.Class.statics(OverwatchHealthBarSkinW)

local function createSegmentCurve(index)
    local first = (index - 1) / S.segmentCount
    local last = index / S.segmentCount
    local curve = C_CurveUtil.CreateCurve()
    curve:SetType(Enum.LuaCurveType.Linear)
    curve:AddPoint(0, 0)
    if first > 0 then curve:AddPoint(first, 0) end
    curve:AddPoint(last, 1)
    if last < 1 then curve:AddPoint(1, 1) end
    return curve
end

function OverwatchHealthBarSkinW:Initialize(bar)
    local rawBar = unwrap(bar)
    local controller = CreateFrame("Frame", nil, rawBar)
    controller:SetAllPoints(rawBar)
    controller:SetFrameLevel(rawBar:GetFrameLevel())
    controller:EnableMouse(false)
    self:_Attach(controller)

    local p = self:_p()
    p.bar = rawBar
    p.controller = controller
    p.sourceFill = rawBar.GetStatusBarTexture and rawBar:GetStatusBarTexture()
    p.segments = {}
    p.applied = false
    p.animated = true
    p.disposed = false

    for i = 1, S.segmentCount do
        local segmentBar = CreateFrame("StatusBar", nil, controller)
        segmentBar:SetFrameLevel(rawBar:GetFrameLevel())
        segmentBar:EnableMouse(false)
        segmentBar:SetMinMaxValues(0, 1)
        segmentBar:SetStatusBarTexture(S.texture)
        segmentBar:SetValue(0)

        local fill = segmentBar:GetStatusBarTexture()
        fill:SetDrawLayer("ARTWORK", 0)

        local background = segmentBar:CreateTexture(nil, "BACKGROUND", nil, 0)
        background:SetAllPoints(segmentBar)
        background:SetTexture(S.texture)
        background:SetVertexColor(0.1, 0.1, 0.1, 0.55)

        p.segments[i] = {
            bar = segmentBar,
            fill = fill,
            background = background,
            curve = createSegmentCurve(i),
        }
    end

    -- Unit Frames and Blizzard both color the original texture. Mirror every tint
    -- directly into the fragment textures; secret color channels are only forwarded
    -- to another sanctioned texture sink and are never inspected here.
    if p.sourceFill and hooksecurefunc then
        hooksecurefunc(p.sourceFill, "SetVertexColor", function(_, ...)
            if not p.disposed then self:_SetColor(...) end
        end)
    end
    if rawBar.SetStatusBarColor and hooksecurefunc then
        hooksecurefunc(rawBar, "SetStatusBarColor", function(_, ...)
            if not p.disposed then self:_SetColor(...) end
        end)
    end

    controller:HookScript("OnSizeChanged", function(_, width, height)
        self:_Layout(width, height)
    end)
    self:_Layout(controller:GetWidth(), controller:GetHeight())
    controller:Hide()
end

function OverwatchHealthBarSkinW:_SetColor(r, g, b)
    -- The source texture is hidden while the skin is active, so its alpha is zero.
    -- Preserve only its health RGB and keep every replacement fragment opaque.
    for _, segment in ipairs(self:_p().segments) do
        segment.fill:SetVertexColor(r, g, b, 1)
    end
end

function OverwatchHealthBarSkinW:_SyncColor()
    local p = self:_p()
    if p.bar.GetStatusBarColor then
        self:_SetColor(p.bar:GetStatusBarColor())
    elseif p.sourceFill then
        self:_SetColor(p.sourceFill:GetVertexColor())
    end
end

function OverwatchHealthBarSkinW:_Layout(width, height)
    if width == nil or height == nil then return end
    if issecretvalue and (issecretvalue(width) or issecretvalue(height)) then return end
    if width <= 0 or height <= 0 then return end
    local p = self:_p()
    local segmentWidth = width / S.segmentCount
    for i, segment in ipairs(p.segments) do
        segment.bar:ClearAllPoints()
        segment.bar:SetSize(segmentWidth, height)
        segment.bar:SetPoint("LEFT", p.controller, "LEFT", (i - 1) * segmentWidth, 0)
    end
end

function OverwatchHealthBarSkinW:UpdateHealth()
    local p = self:_p()
    if not (p.applied and UnitHealthPercent) then return self end

    local interpolation = Enum.StatusBarInterpolation
    for _, segment in ipairs(p.segments) do
        local value = UnitHealthPercent("player", true, segment.curve)
        if p.animated and interpolation then
            segment.bar:SetValue(value, interpolation.ExponentialEaseOut)
        else
            segment.bar:SetValue(value)
        end
    end

    self:_SyncColor()
    if p.sourceFill then p.sourceFill:SetAlpha(0) end
    return self
end

function OverwatchHealthBarSkinW:Apply()
    local p = self:_p()
    if p.applied then
        self:UpdateHealth()
        return self
    end
    p.applied = true
    p.controller:Show()
    if p.sourceFill then p.sourceFill:SetAlpha(0) end
    self:UpdateHealth()
    return self
end

function OverwatchHealthBarSkinW:SetAnimated(animated)
    local p = self:_p()
    p.animated = animated and true or false
    if p.applied then self:UpdateHealth() end
    return self
end

function OverwatchHealthBarSkinW:Restore()
    local p = self:_p()
    p.applied = false
    p.controller:Hide()
    if p.sourceFill then p.sourceFill:SetAlpha(1) end
    return self
end

function OverwatchHealthBarSkinW:Dispose()
    local p = self:_p()
    if p.disposed then return end
    p.disposed = true
    self:Restore()
    OverwatchHealthBarSkinW.super.Dispose(self)
end

Widgets.OverwatchHealthBarSkin = OverwatchHealthBarSkinW
