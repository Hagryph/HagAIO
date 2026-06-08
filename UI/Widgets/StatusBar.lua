local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt

-- UI/Widgets/StatusBar.lua
-- A bare StatusBar widget for HUD fills. Unlike ProgressBar it does NO clamping/maths on the value --
-- so a SECRET value (e.g. a spell cast count) flows straight to the engine untouched (you can't offset
-- or scale a secret yourself; bake offsets into MinMax with plain numbers instead). opts: texture
-- (flat WHITE8X8), desaturate (tint a flat fill cleanly). Methods: :SetValue(raw) :SetMinMaxValues
-- :SetStatusBarColor (+ base layout).
local StatusBarW = ns.Class.new("StatusBar", FrameWidget)
function StatusBarW:Initialize(parent, opts)
    opts = opts or {}
    local sb = CreateFrame("StatusBar", nil, unwrap(parent))
    sb:SetStatusBarTexture(opts.texture or "Interface\\Buttons\\WHITE8X8")
    if opts.desaturate then
        local tex = sb:GetStatusBarTexture()
        if tex and tex.SetDesaturated then tex:SetDesaturated(true) end
    end
    self:_attach(sb)
end
function StatusBarW:SetValue(v)            self:_frame():SetValue(v);             return self end   -- RAW: secret-safe
function StatusBarW:SetMinMaxValues(a, b)  self:_frame():SetMinMaxValues(a, b);   return self end
function StatusBarW:SetStatusBarColor(...) self:_frame():SetStatusBarColor(...);  return self end
Widgets.StatusBar = StatusBarW
