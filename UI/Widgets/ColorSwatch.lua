local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt
local Changeable = _wb.Changeable

-- UI/Widgets/ColorSwatch.lua
-- Colour swatch button + HagAIO colour dialog. The modal stays entirely inside the shared widget
-- language: raised surface, live preview, RGB sliders, hexadecimal input and explicit Apply/Cancel.
-- Live edits apply immediately (matching Blizzard's picker); Cancel restores the opening colour.
-- Methods: :SetColor(r,g,b) :GetColor() :SetOnChange(fn) :SetDefault :SetEnabled.
local ColorSwatchW = ns.Class.new("ColorSwatch", FrameWidget, {
    mixins = { Changeable },
    statics = { popupSerial = 0 },
})
local S = ns.Class.statics(ColorSwatchW)
function ColorSwatchW:Initialize(parent)
    local btn = CreateFrame("Button", nil, unwrap(parent), "BackdropTemplate")
    btn:SetSize(30, 20)
    style(btn, "control", "borderStrong")

    local sw = btn:CreateTexture(nil, "ARTWORK")
    sw:SetPoint("TOPLEFT", 3, -3)
    sw:SetPoint("BOTTOMRIGHT", -3, 3)
    sw:SetColorTexture(1, 1, 1)

    local p = self:_p()
    p.r, p.g, p.b, p.enabled = 1, 1, 1, true
    local function set(r, g, b) p.r, p.g, p.b = r, g, b; sw:SetColorTexture(r, g, b); self:_FireChange({ r, g, b }) end
    p.set = set

    -- One modal per swatch keeps lifecycle ownership simple: when the swatch is disposed its hidden
    -- UIParent popup is reparented beneath it and the normal widget cascade tears everything down.
    S.popupSerial = S.popupSerial + 1
    local blockerName = "HagAIOColorPickerPopup" .. S.popupSerial
    local blocker = CreateFrame("Button", blockerName, UIParent)
    -- Insert at the top of the global Escape stack so this modal consumes Escape
    -- before the settings window's own UISpecialFrames entry.
    table.insert(UISpecialFrames, 1, blockerName)
    blocker:SetAllPoints(UIParent)
    blocker:SetFrameStrata("DIALOG")
    blocker:EnableMouse(true)
    blocker:Hide()
    local shade = blocker:CreateTexture(nil, "BACKGROUND")
    shade:SetAllPoints(); shade:SetColorTexture(0.015, 0.020, 0.030, 0.72)

    local dialog = Widgets.Panel:New(blocker, "surface", "borderStrong", { shadow = true, accent = true })
    dialog:SetSize(360, 324)
    dialog:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    dialog:SetFrameLevel(blocker:GetFrameLevel() + 10)
    dialog:EnableMouse(true) -- consume clicks inside the panel so only the shaded outside area cancels

    local title = Widgets.Text:New(dialog, "CHOOSE COLOUR", "text", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 20, -16)
    local note = Widgets.Text:New(dialog, "Changes preview immediately.", "textDim", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)

    local preview = Widgets.Panel:New(dialog, "control", "borderStrong")
    preview:SetSize(58, 34)
    preview:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -20, -18)
    local previewFill = Widgets.Fill:New(preview, { layer = "ARTWORK" })
    previewFill:SetPoint("TOPLEFT", 3, -3); previewFill:SetPoint("BOTTOMRIGHT", -3, 3)

    local red = Widgets.Slider:New(dialog, { label = "Red", min = 0, max = 255, step = 1, width = 320, format = "%d" })
    red:SetPoint("TOPLEFT", 20, -68)
    local green = Widgets.Slider:New(dialog, { label = "Green", min = 0, max = 255, step = 1, width = 320, format = "%d" })
    green:SetPoint("TOPLEFT", 20, -112)
    local blue = Widgets.Slider:New(dialog, { label = "Blue", min = 0, max = 255, step = 1, width = 320, format = "%d" })
    blue:SetPoint("TOPLEFT", 20, -156)

    local hexLabel = Widgets.Text:New(dialog, "Hex", "textDim", "GameFontHighlightSmall")
    hexLabel:SetPoint("TOPLEFT", 20, -207)
    local hex = Widgets.Input:New(dialog, 112)
    hex:SetPoint("TOPLEFT", 20, -224)
    hex:SetHint("#4AB3E6")

    local cancel = Widgets.Button:New(dialog, "Cancel", { width = 78 })
    cancel:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -112, 18)
    local apply = Widgets.Button:New(dialog, "Apply", { width = 78 })
    apply:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -20, 18)

    local function byte(v) return math.max(0, math.min(255, math.floor((v or 0) + 0.5))) end
    local function hexText(r, g, b)
        return ("#%02X%02X%02X"):format(byte(r * 255), byte(g * 255), byte(b * 255))
    end
    local function paintPicker(r, g, b, notify)
        p.pickerSync = true
        red:SetValue(byte(r * 255)); green:SetValue(byte(g * 255)); blue:SetValue(byte(b * 255))
        hex:SetValue(hexText(r, g, b))
        p.pickerSync = false
        previewFill:SetColorTexture(r, g, b)
        set(r, g, b)
        if notify and p.onChange then p.onChange(r, g, b) end
    end
    local function sliderChanged()
        if p.pickerSync then return end
        local r, g, b = red:GetValue() / 255, green:GetValue() / 255, blue:GetValue() / 255
        hex:SetValue(hexText(r, g, b))
        previewFill:SetColorTexture(r, g, b)
        set(r, g, b)
        if p.onChange then p.onChange(r, g, b) end
    end
    red:SetOnChange(sliderChanged); green:SetOnChange(sliderChanged); blue:SetOnChange(sliderChanged)

    hex:SetOnChange(function(value)
        local digits = tostring(value or ""):match("^#?(%x%x%x%x%x%x)$")
        if not digits then hex:SetValue(hexText(p.r, p.g, p.b)); return end
        local r = tonumber(digits:sub(1, 2), 16) / 255
        local g = tonumber(digits:sub(3, 4), 16) / 255
        local b = tonumber(digits:sub(5, 6), 16) / 255
        paintPicker(r, g, b, true)
    end)

    local function close(accepted)
        p.accepted = accepted == true
        blocker:Hide()
    end
    local function cancelPicker() close(false) end
    blocker:HookScript("OnHide", function()
        if not p.pickerOpen then return end
        if not p.accepted and p.openR then
            set(p.openR, p.openG, p.openB)
            if p.onChange then p.onChange(p.openR, p.openG, p.openB) end
        end
        p.pickerOpen = false
        p.accepted = false
    end)
    local function open()
        p.openR, p.openG, p.openB = p.r, p.g, p.b
        p.pickerOpen, p.accepted = true, false
        paintPicker(p.r, p.g, p.b, false)
        blocker:Show()
    end
    blocker:SetScript("OnClick", cancelPicker)
    cancel:SetOnClick(cancelPicker)
    apply:SetOnClick(function() close(true) end)
    p.blocker, p.blockerName, p.closePicker, p.openPicker = blocker, blockerName, cancelPicker, open

    btn:SetScript("OnEnter", function() if p.enabled then btn:SetBackdropBorderColor(Theme.Unpack("accent")) end end)
    btn:SetScript("OnLeave", function() btn:SetBackdropBorderColor(Theme.Unpack("borderStrong")) end)
    btn:SetScript("OnClick", function()
        if not p.enabled then return end
        p.openPicker()
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
    self:_Attach(btn)
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
    if not p.enabled and p.closePicker then p.closePicker() end
    self:_Frame():SetAlpha(p.enabled and 1 or 0.4)     -- dims the swatch + its Reset child
    p.reset:SetShown(p.enabled and p.dr ~= nil)        -- and hides Reset while greyed out
    return self
end
function ColorSwatchW:Dispose()
    local p = self:_p()
    if p.closePicker then p.closePicker() end
    if p.blockerName then
        for i = #UISpecialFrames, 1, -1 do
            if UISpecialFrames[i] == p.blockerName then table.remove(UISpecialFrames, i) end
        end
    end
    if p.blocker then p.blocker:SetParent(self:_Frame()) end
    ColorSwatchW.super.Dispose(self)
end
Widgets.ColorSwatch = ColorSwatchW
