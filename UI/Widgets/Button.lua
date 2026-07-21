local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt

-- UI/Widgets/Button.lua
-- A themed PUSH button: a filled secondary action by default, or a cyan-tonal
-- primary action with opts.primary=true. The shared treatment makes actions
-- read as controls rather than empty outlined rectangles.
-- Auto-sizes to the text (override with opts.width / opts.height). Methods: :SetText(s)
-- :SetOnClick(fn) :SetEnabled(bool).
local ButtonW = ns.Class.new("Button", FrameWidget)
function ButtonW:Initialize(parent, text, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, unwrap(parent), "BackdropTemplate")
    style(b, opts.primary and "accentSoft" or "surfaceRaised", opts.primary and "accentDim" or "border")
    b:SetHeight(opts.height or 30)
    local topLight = b:CreateTexture(nil, "BORDER")
    topLight:SetPoint("TOPLEFT", 1, -1); topLight:SetPoint("TOPRIGHT", -1, -1); topLight:SetHeight(1)
    topLight:SetColorTexture(Theme.Unpack(opts.primary and "accent" or "highlight"))
    local underline = b:CreateTexture(nil, "ARTWORK")
    underline:SetPoint("BOTTOMLEFT", 1, 1); underline:SetPoint("BOTTOMRIGHT", -1, 1); underline:SetHeight(1)
    underline:SetColorTexture(Theme.Unpack("accent", 0))
    local fs = Widgets.Text:New(b, text, "text", "GameFontHighlight")
    fs:SetPoint("CENTER")
    local function fit() b:SetWidth(opts.width or math.max(opts.minWidth or 76, fs:GetStringWidth() + 28)) end
    fit()
    local p = self:_p()
    p.label, p.fit, p.enabled, p.primary, p.underline = fs, fit, true, opts.primary == true, underline
    local function render(hover)
        local active = hover and p.enabled
        local background = p.primary and (active and "controlHover" or "accentSoft")
            or (active and "controlHover" or "surfaceRaised")
        b:SetBackdropColor(Theme.Unpack(background))
        b:SetBackdropBorderColor(Theme.Unpack(active and "accent" or (p.primary and "accentDim" or "border")))
        fs:SetTextColor(Theme.Unpack(p.enabled and (p.primary or active) and "accent" or (p.enabled and "textDim" or "textFaint")))
        p.underline:SetColorTexture(Theme.Unpack("accent", active and 1 or 0))
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
