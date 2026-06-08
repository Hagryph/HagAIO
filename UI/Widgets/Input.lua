local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt

-- UI/Widgets/Input.lua
-- Themed single-line EditBox. `numeric` only affects which characters look valid
-- to us; we never SetNumeric (that would block decimals/negatives many CVars
-- need) -- callers validate on change. Commits on Enter or focus-loss; Esc
-- reverts. Methods: :SetValue(v) :GetValue() :SetOnChange(fn) :SetEnabled(b).
local InputW = ns.Class.new("Input", FrameWidget)
function InputW:Initialize(parent, width)
    local box = CreateFrame("EditBox", nil, unwrap(parent), "BackdropTemplate")
    box:SetAutoFocus(false)
    box:SetHeight(20)
    box:SetWidth(width or 90)
    style(box, "panel2", "borderStrong")
    box:SetFontObject("GameFontHighlightSmall")
    box:SetTextInsets(6, 6, 0, 0)
    box:SetTextColor(Theme.Unpack("text"))
    box:SetMaxLetters(0)

    local p = self:_p()
    p.value, p.enabled = "", true
    local function commit()
        local v = box:GetText()
        if v == p.value then return end
        p.value = v
        if p.onChange then p.onChange(v) end
    end
    box:SetScript("OnEnterPressed",    function(s) s:ClearFocus() end)  -- triggers focus-lost commit
    box:SetScript("OnEscapePressed",   function(s) s:SetText(p.value); s:ClearFocus() end)
    box:SetScript("OnEditFocusGained", function() box:SetBackdropBorderColor(Theme.Unpack("accent")) end)
    box:SetScript("OnEditFocusLost",   function() box:SetBackdropBorderColor(Theme.Unpack("borderStrong")); commit() end)
    self:_attach(box)
end
function InputW:SetValue(v)     local p = self:_p(); p.value = tostring(v == nil and "" or v); self:_frame():SetText(p.value); return self end
function InputW:GetValue()      return self:_frame():GetText() end
function InputW:SetOnChange(fn) self:_p().onChange = fn; return self end
function InputW:SetEnabled(on)
    local p, box = self:_p(), self:_frame()
    p.enabled = on and true or false
    box:EnableMouse(p.enabled); box:EnableKeyboard(p.enabled); box:SetAlpha(p.enabled and 1 or 0.4)
    return self
end
Widgets.Input = InputW
