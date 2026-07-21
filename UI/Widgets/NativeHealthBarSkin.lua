local addonName, ns = ...
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt

-- UI/Widgets/NativeHealthBarSkin.lua
-- A view over Blizzard's existing StatusBar. It does not replace, move, hide,
-- or otherwise own a unit frame; it forwards the secret-safe health colour to
-- Blizzard's existing fill texture.
local NativeHealthBarSkinW = ns.Class.new("NativeHealthBarSkin", Widget)

function NativeHealthBarSkinW:Initialize(bar)
    self:_Attach(bar)
    local p = self:_p()
    p.bar = bar
    p.unit = nil
    p.curve = nil
    p.applied = false
end

function NativeHealthBarSkinW:SetUnit(unit)
    self:_p().unit = unit
end

function NativeHealthBarSkinW:SetHealthColorCurve(curve)
    self:_p().curve = curve
end

function NativeHealthBarSkinW:Apply()
    local p = self:_p()
    p.applied = true
    self:UpdateHealth()
end

function NativeHealthBarSkinW:Restore()
    local p = self:_p()
    if not p.applied then return end
    p.applied = false

    local texture = p.bar:GetStatusBarTexture()
    if texture then texture:SetVertexColor(1, 1, 1, 1) end
end

function NativeHealthBarSkinW:UpdateHealth()
    local p = self:_p()
    if not (p.applied and p.unit and p.curve and UnitHealthPercent) then return end
    local color = UnitHealthPercent(p.unit, true, p.curve)
    if color then
        local texture = p.bar:GetStatusBarTexture()
        if texture then texture:SetVertexColor(color:GetRGB()) end
    end
end

Widgets.NativeHealthBarSkin = NativeHealthBarSkinW
