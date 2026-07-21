local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt

-- UI/Widgets/Divider.lua
-- 1px horizontal hairline (anchor + width set by caller).
local DividerW = ns.Class.new("Divider", TextureWidget)
function DividerW:Initialize(parent)
    local t = unwrap(parent):CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(Theme.Unpack("borderStrong", 0.28))
    t:SetHeight(1)
    self:_Attach(t)
end
Widgets.Divider = DividerW
