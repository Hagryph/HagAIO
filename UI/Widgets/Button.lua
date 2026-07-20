local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt

-- UI/Widgets/Button.lua
-- A themed PUSH button: a bordered box with a centred label that lights to accent on hover.
-- Auto-sizes to the text (override with opts.width / opts.height). Methods: :SetText(s)
-- :SetOnClick(fn) :SetEnabled(bool).
local ButtonW = ns.Class.new("Button", FrameWidget)
function ButtonW:Initialize(parent, text, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, unwrap(parent), "BackdropTemplate")
    style(b, "panel2", "borderStrong")
    b:SetHeight(opts.height or 24)
    local fs = Widgets.Text:New(b, text, "text", "GameFontHighlight")
    fs:SetPoint("CENTER")
    local function fit() b:SetWidth(opts.width or math.max(opts.minWidth or 70, fs:GetStringWidth() + 24)) end
    fit()
    local p = self:_p()
    p.label, p.fit, p.enabled = fs, fit, true
    b:SetScript("OnEnter", function() if p.enabled then b:SetBackdropBorderColor(Theme.Unpack("accent")) end end)
    b:SetScript("OnLeave", function() b:SetBackdropBorderColor(Theme.Unpack("borderStrong")) end)
    b:SetScript("OnClick", function() if p.enabled and p.onClick then p.onClick() end end)
    self:_Attach(b)
end
function ButtonW:SetText(s)     local p = self:_p(); p.label:SetText(s); p.fit(); return self end
function ButtonW:SetOnClick(fn) self:_p().onClick = fn; return self end
function ButtonW:SetEnabled(on)
    local p = self:_p(); p.enabled = on and true or false
    p.label:SetTextColor(Theme.Unpack(p.enabled and "text" or "textFaint"))
    self:_Frame():SetAlpha(p.enabled and 1 or 0.6)
    return self
end
Widgets.Button = ButtonW
