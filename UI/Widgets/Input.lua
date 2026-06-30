local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt
local Changeable = _wb.Changeable

-- UI/Widgets/Input.lua
-- Themed single-line EditBox. `numeric` only affects which characters look valid
-- to us; we never SetNumeric (that would block decimals/negatives many CVars
-- need) -- callers validate on change. Commits on Enter or focus-loss; Esc
-- reverts. Methods: :SetValue(v) :GetValue() :SetOnChange(fn) :SetEnabled(b)
-- :SetHint(text) (faint placeholder shown while empty + unfocused).
local InputW = ns.Class.new("Input", FrameWidget, { mixins = { Changeable } })
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
        self:_FireChange(p.value)   -- dependents re-evaluate their EnableWhen condition
    end
    box:SetScript("OnEnterPressed",    function(s) s:ClearFocus() end)  -- triggers focus-lost commit
    box:SetScript("OnEscapePressed",   function(s) s:SetText(p.value); s:ClearFocus() end)
    box:SetScript("OnEditFocusGained", function() box:SetBackdropBorderColor(Theme.Unpack("accent")); self:_UpdateHint() end)
    box:SetScript("OnEditFocusLost",   function() box:SetBackdropBorderColor(Theme.Unpack("borderStrong")); commit(); self:_UpdateHint() end)
    box:SetScript("OnTextChanged",     function() self:_UpdateHint() end)
    self:_Attach(box)
end
function InputW:SetValue(v)     local p = self:_p(); p.value = tostring(v == nil and "" or v); self:_Frame():SetText(p.value); self:_FireChange(p.value); self:_UpdateHint(); return self end
function InputW:GetValue()      return self:_Frame():GetText() end
function InputW:SetOnChange(fn) self:_p().onChange = fn; return self end

-- A faint placeholder shown ONLY while the box is empty and not being edited (cleared the moment the
-- player types or focuses in), styled with the theme's faint text colour and the input's own font so
-- it reads as a prompt, not a value. Created lazily on first SetHint.
function InputW:SetHint(text)
    local p, box = self:_p(), self:_Frame()
    if not p.hint then
        local fs = box:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", box, "LEFT", 8, 0)     -- match the 6px text inset (+ a hair)
        fs:SetPoint("RIGHT", box, "RIGHT", -6, 0)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        fs:SetTextColor(Theme.Unpack("textFaint"))
        p.hint = fs
    end
    p.hint:SetText(text or "")
    self:_UpdateHint()
    return self
end

-- Show the hint only when the field is empty and unfocused.
function InputW:_UpdateHint()
    local p, box = self:_p(), self:_Frame()
    if not p.hint then return end
    p.hint:SetShown((box:GetText() or "") == "" and not box:HasFocus())
end
function InputW:SetEnabled(on)
    local p, box = self:_p(), self:_Frame()
    p.enabled = on and true or false
    box:EnableMouse(p.enabled); box:EnableKeyboard(p.enabled); box:SetAlpha(p.enabled and 1 or 0.4)
    return self
end
Widgets.Input = InputW
