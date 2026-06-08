local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt

-- UI/Widgets/Panel.lua
-- A bordered, themed container Frame. Opt-in colour methods (:SetBackdropColor/Border) let the
-- panels that change tint on hover/state drive their own look.
local PanelW = ns.Class.new("Panel", FrameWidget)
function PanelW:Initialize(parent, bgKey, borderKey)
    local f = CreateFrame("Frame", nil, unwrap(parent), "BackdropTemplate")
    style(f, bgKey or "panel", borderKey or "border")
    self:_attach(f)
end
function PanelW:SetBackdropColor(...)       self:_frame():SetBackdropColor(...);       return self end
function PanelW:SetBackdropBorderColor(...) self:_frame():SetBackdropBorderColor(...); return self end
Widgets.Panel = PanelW   -- construct with Widgets.Panel:New(parent, ...)
