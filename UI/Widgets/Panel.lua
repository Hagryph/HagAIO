local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt
local Registrable = _wb.Registrable

-- UI/Widgets/Panel.lua
-- A bordered, themed container Frame. Opt-in colour methods (:SetBackdropColor/Border) let the
-- panels that change tint on hover/state drive their own look. Registrable -> :RegisterEditMode.
local PanelW = ns.Class.new("Panel", FrameWidget, { mixins = { Registrable } })
function PanelW:Initialize(parent, bgKey, borderKey)
    local f = CreateFrame("Frame", nil, unwrap(parent), "BackdropTemplate")
    style(f, bgKey or "panel", borderKey or "border")
    self:_Attach(f)
end
function PanelW:SetBackdropColor(...)       self:_Frame():SetBackdropColor(...);       return self end
function PanelW:SetBackdropBorderColor(...) self:_Frame():SetBackdropBorderColor(...); return self end
Widgets.Panel = PanelW   -- construct with Widgets.Panel:New(parent, ...)
