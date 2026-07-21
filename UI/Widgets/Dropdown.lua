local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt
local Changeable = _wb.Changeable

-- UI/Widgets/Dropdown.lua
-- Native retail dropdown backed by Blizzard's current Menu system. Options are
-- { { value = value, text = "Player-facing label" }, ... }.
-- Methods: :SetValue(v) :GetValue() :SetOnChange(fn) :SetEnabled(bool).
local DropdownW = ns.Class.new("Dropdown", FrameWidget, { mixins = { Changeable } })
function DropdownW:Initialize(parent, options, defaultText)
    local dropdown = CreateFrame("DropdownButton", nil, unwrap(parent), "WowStyle1DropdownTemplate")
    dropdown:SetSize(220, 24)
    dropdown:SetDefaultText(defaultText or "Select")

    local p = self:_p()
    p.options = options or {}
    p.enabled = true
    dropdown:SetupMenu(function(_, root)
        for _, option in ipairs(p.options) do
            root:CreateRadio(option.text,
                function(value) return p.value == value end,
                function(value)
                    if not p.enabled then return end
                    p.value = value
                    if p.onChange then p.onChange(value) end
                    self:_FireChange(value)
                end,
                option.value)
        end
    end)

    self:_Attach(dropdown)
end
function DropdownW:SetValue(value)
    local p = self:_p()
    p.value = value
    local dropdown = self:_Frame()
    if dropdown.GenerateMenu then dropdown:GenerateMenu() end
    self:_FireChange(value)
    return self
end
function DropdownW:GetValue() return self:_p().value end
function DropdownW:SetOnChange(fn) self:_p().onChange = fn; return self end
function DropdownW:SetEnabled(on)
    local p, dropdown = self:_p(), self:_Frame()
    p.enabled = on and true or false
    dropdown:SetEnabled(p.enabled)
    dropdown:SetAlpha(p.enabled and 1 or 0.4)
    return self
end
Widgets.Dropdown = DropdownW
