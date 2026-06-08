local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt
local Changeable = _wb.Changeable

-- UI/Widgets/Slider.lua
-- Themed horizontal slider with a track, an accent fill, a draggable thumb, and a live numeric
-- readout (right of an optional label). The widget is a container Frame -- anchor it like any other.
--   opts: min, max, step, width (track px, 160), label (string), format (readout fmt, "%.2f")
-- Methods: :SetValue(v) :GetValue() :SetOnChange(fn)  fn(newValue) on user drag  :SetEnabled(bool)
local SliderW = ns.Class.new("Slider", FrameWidget, { mixins = { Changeable } })
function SliderW:Initialize(parent, opts)
    opts = opts or {}
    local minV, maxV = opts.min or 0, opts.max or 1
    local step  = opts.step or 0.01
    local width = opts.width or 160
    local fmt   = opts.format or "%.2f"

    local f = CreateFrame("Frame", nil, unwrap(parent))
    f:SetSize(width, 34)

    if opts.label then
        local label = Widgets.Text:New(f, opts.label, "text", "GameFontHighlightSmall")
        label:SetPoint("TOPLEFT", 0, 0)
    end
    local readout = Widgets.Text:New(f, "", "accent", "GameFontHighlightSmall")
    readout:SetPoint("TOPRIGHT", 0, 0)

    local slider = CreateFrame("Slider", nil, f)
    slider:SetOrientation("HORIZONTAL")
    slider:SetPoint("TOPLEFT", 0, -16)
    slider:SetSize(width, 16)
    slider:SetMinMaxValues(minV, maxV)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)

    local track = f:CreateTexture(nil, "ARTWORK")
    track:SetColorTexture(Theme.Unpack("panel2"))
    track:SetHeight(4)
    track:SetPoint("LEFT", slider, "LEFT", 0, 0)
    track:SetPoint("RIGHT", slider, "RIGHT", 0, 0)
    local fill = f:CreateTexture(nil, "OVERLAY")
    fill:SetColorTexture(Theme.Unpack("accent"))
    fill:SetHeight(4)
    fill:SetPoint("LEFT", track, "LEFT", 0, 0)

    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(Theme.Unpack("accent"))
    thumb:SetSize(10, 16)
    slider:SetThumbTexture(thumb)

    local p = self:_p()
    p.slider, p.enabled, p.suppress = slider, true, false
    local function render(v)
        readout:SetText(fmt:format(v))
        local frac = (maxV > minV) and ((v - minV) / (maxV - minV)) or 0
        fill:SetWidth(math.max(0.01, width * math.max(0, math.min(1, frac))))
    end
    p.render = render
    slider:SetScript("OnValueChanged", function(_, v)
        render(v)
        if p.onChange and p.enabled and not p.suppress then p.onChange(v) end
        if not p.suppress then self:_fireChange(v) end   -- emit a change (skip programmatic SetValue)
    end)
    self:_attach(f)
    render(minV)
end
function SliderW:SetValue(v)    local p = self:_p(); p.suppress = true; p.slider:SetValue(v); p.suppress = false; p.render(p.slider:GetValue()); self:_fireChange(p.slider:GetValue()); return self end
function SliderW:GetValue()     return self:_p().slider:GetValue() end
function SliderW:SetOnChange(fn) self:_p().onChange = fn; return self end
function SliderW:SetEnabled(on)
    local p = self:_p(); p.enabled = on and true or false
    p.slider:EnableMouse(p.enabled); self:_frame():SetAlpha(p.enabled and 1 or 0.5)
    return self
end
Widgets.Slider = SliderW
