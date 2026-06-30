local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt
local Changeable = _wb.Changeable

-- UI/Widgets/Segmented.lua
-- Segmented selector (LoL "view-switch"): a row of option buttons, active one
-- accent-highlighted. options = { { value = v, text = "..." }, ... }.
-- Methods: :SetValue(v) :GetValue() :SetOnChange(fn) :SetEnabled(bool).
local SegmentedW = ns.Class.new("Segmented", FrameWidget, { mixins = { Changeable } })
function SegmentedW:Initialize(parent, options)
    local c = CreateFrame("Frame", nil, unwrap(parent), "BackdropTemplate")
    style(c, "panel2", "border")
    c:SetHeight(24)

    local p = self:_p()
    p.btns, p.enabled = {}, true
    local function render()
        for _, e in ipairs(p.btns) do
            if e.value == p.value then
                e.bg:Show(); e.fs:SetTextColor(Theme.Unpack("accent"))
            else
                e.bg:Hide(); e.fs:SetTextColor(Theme.Unpack("textDim"))
            end
        end
    end
    p.render = render

    local x = 2
    for _, opt in ipairs(options) do
        local b = CreateFrame("Button", nil, c)
        local fs = Widgets.Text:New(b, opt.text, "textDim", "GameFontNormalSmall")
        fs:SetPoint("CENTER")
        local w = math.max(46, fs:GetStringWidth() + 18)
        b:SetSize(w, 20)
        b:SetPoint("LEFT", x, 0)

        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(Theme.Unpack("accentSoft"))
        bg:Hide()

        p.btns[#p.btns + 1] = { bg = bg, fs = fs, value = opt.value }
        b:SetScript("OnClick", function()
            if not p.enabled then return end
            p.value = opt.value; render()
            if p.onChange then p.onChange(p.value) end
            self:_FireChange(p.value)   -- dependents re-evaluate their EnableWhen condition
        end)
        b:SetScript("OnEnter", function() if p.enabled and opt.value ~= p.value then fs:SetTextColor(Theme.Unpack("text")) end end)
        b:SetScript("OnLeave", render)
        x = x + w + 2
    end
    c:SetWidth(x)

    self:_Attach(c)
    render()
end
function SegmentedW:SetValue(v)     local p = self:_p(); p.value = v; p.render(); self:_FireChange(p.value); return self end
function SegmentedW:GetValue()      return self:_p().value end
function SegmentedW:SetOnChange(fn) self:_p().onChange = fn; return self end
function SegmentedW:SetEnabled(on)
    local p = self:_p(); p.enabled = on and true or false
    self:_Frame():SetAlpha(p.enabled and 1 or 0.4); p.render(); return self
end
Widgets.Segmented = SegmentedW
