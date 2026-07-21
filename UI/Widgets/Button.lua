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
    style(b, "control", "borderStrong")
    b:SetHeight(opts.height or 28)
    local fs = Widgets.Text:New(b, text, "text", "GameFontHighlight")
    fs:SetPoint("CENTER")
    local function fit() b:SetWidth(opts.width or math.max(opts.minWidth or 76, fs:GetStringWidth() + 28)) end
    fit()
    local p = self:_p()
    p.label, p.fit, p.enabled = fs, fit, true
    local function render(hover)
        b:SetBackdropColor(Theme.Unpack(hover and p.enabled and "controlHover" or "control"))
        b:SetBackdropBorderColor(Theme.Unpack(hover and p.enabled and "accent" or "borderStrong"))
        fs:SetTextColor(Theme.Unpack(p.enabled and (hover and "accent" or "text") or "textFaint"))
    end
    p.render = render
    b:SetScript("OnEnter", function() render(true) end)
    b:SetScript("OnLeave", function() render(false) end)
    b:SetScript("OnClick", function() if p.enabled and p.onClick then p.onClick() end end)
    self:_Attach(b)
end
function ButtonW:SetText(s)     local p = self:_p(); p.label:SetText(s); p.fit(); return self end
function ButtonW:SetOnClick(fn) self:_p().onClick = fn; return self end
function ButtonW:SetEnabled(on)
    local p = self:_p(); p.enabled = on and true or false
    self:_Frame():SetAlpha(p.enabled and 1 or 0.6)
    p.render(false)
    return self
end
Widgets.Button = ButtonW
