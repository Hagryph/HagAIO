local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt

-- UI/Widgets/ColorSwatch.lua
-- Colour swatch button: shows the current colour, opens the Blizzard colour
-- picker on click. Methods: :SetColor(r,g,b) :GetColor() :SetOnChange(fn) :SetDefault :SetEnabled.
local ColorSwatchW = ns.Class.new("ColorSwatch", FrameWidget)
function ColorSwatchW:Initialize(parent)
    local btn = CreateFrame("Button", nil, unwrap(parent), "BackdropTemplate")
    btn:SetSize(26, 16)
    style(btn, "panel2", "borderStrong")

    local sw = btn:CreateTexture(nil, "ARTWORK")
    sw:SetPoint("TOPLEFT", 2, -2)
    sw:SetPoint("BOTTOMRIGHT", -2, 2)
    sw:SetColorTexture(1, 1, 1)

    local p = self:_p()
    p.r, p.g, p.b, p.enabled = 1, 1, 1, true
    local function set(r, g, b) p.r, p.g, p.b = r, g, b; sw:SetColorTexture(r, g, b) end
    p.set = set

    btn:SetScript("OnEnter", function() if p.enabled then btn:SetBackdropBorderColor(Theme.Unpack("accent")) end end)
    btn:SetScript("OnLeave", function() btn:SetBackdropBorderColor(Theme.Unpack("borderStrong")) end)
    btn:SetScript("OnClick", function()
        if not p.enabled then return end
        local prevR, prevG, prevB = p.r, p.g, p.b
        local info = {
            hasOpacity = false,
            r = p.r, g = p.g, b = p.b,
            swatchFunc = function()
                local r, g, b = ColorPickerFrame:GetColorRGB()
                set(r, g, b)
                if p.onChange then p.onChange(r, g, b) end
            end,
            cancelFunc = function()
                set(prevR, prevG, prevB)
                if p.onChange then p.onChange(prevR, prevG, prevB) end
            end,
        }
        if ColorPickerFrame.SetupColorPickerAndShow then
            ColorPickerFrame:SetupColorPickerAndShow(info)
        else  -- legacy fallback
            ColorPickerFrame.func = info.swatchFunc
            ColorPickerFrame.cancelFunc = info.cancelFunc
            ColorPickerFrame.hasOpacity = false
            ColorPickerFrame:SetColorRGB(p.r, p.g, p.b)
            ColorPickerFrame:Show()
        end
    end)

    -- Inline reset: a small button left of the swatch that restores the default colour.
    -- Hidden until SetDefault gives it one. Fires onChange so the setting persists + applies.
    local reset = Widgets.TextButton:New(btn, "Reset")
    reset:SetPoint("RIGHT", btn, "LEFT", -8, 0)
    reset:Hide()
    reset:SetScript("OnClick", function()
        if not p.enabled or not p.dr then return end
        set(p.dr, p.dg, p.db)
        if p.onChange then p.onChange(p.dr, p.dg, p.db) end
    end)
    p.reset = reset
    self:_attach(btn)
end
function ColorSwatchW:SetColor(r, g, b) self:_p().set(r, g, b); return self end
function ColorSwatchW:GetColor()        local p = self:_p(); return p.r, p.g, p.b end
function ColorSwatchW:SetOnChange(fn)   self:_p().onChange = fn; return self end
function ColorSwatchW:SetDefault(r, g, b)
    local p = self:_p(); p.dr, p.dg, p.db = r, g, b
    p.reset:SetShown(p.enabled and r ~= nil); return self
end
function ColorSwatchW:SetEnabled(on)
    local p = self:_p(); p.enabled = on and true or false
    self:_frame():SetAlpha(p.enabled and 1 or 0.4)     -- dims the swatch + its Reset child
    p.reset:SetShown(p.enabled and p.dr ~= nil)        -- and hides Reset while greyed out
    return self
end
Widgets.ColorSwatch = ColorSwatchW
