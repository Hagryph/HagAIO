local addonName, ns = ...
local Theme = ns.Theme

-- UI/Widgets.lua
-- Static factory of themed building blocks (the LoL "dark + blue" language in
-- WoW frame form). Everything funnels through here so the look stays
-- consistent and the SettingsWindow reads declaratively.

ns.UI = ns.UI or {}
local Widgets = {}

-- ===========================================================================
-- BASE WIDGET CLASS -- every widget inherits this. It OWNS a private WoW frame (kept in :_p(), never
-- handed out) and defines only the GENERAL capabilities every widget needs to be placed in a layout:
-- anchoring, sizing and visibility. Anything frame-specific (scale, colour, text, a portrait, ...) is
-- NOT here -- a subclass that wants such a power defines its own method exposing exactly it, so each
-- widget controls its own surface and a raw frame is never reachable from outside this module.
--
-- Cross-widget anchoring: SetPoint/SetParent/SetAllPoints accept either a raw region or another
-- Widget; `unwrap` resolves a Widget to its private frame so WoW still receives a real region.
local Widget = ns.Class.new("Widget", nil, { abstract = true })
ns.UI.Widget = Widget

-- Resolve a value that MIGHT be a Widget to the underlying WoW region; pass anything else through.
local function unwrap(x)
    if type(x) == "table" and x.IsInstanceOf and x:IsInstanceOf(Widget) then return x:_frame() end
    return x
end

-- Subclasses call this once, from :Initialize, with the region they created (after unwrapping their
-- own parent via `unwrap`). Stores it privately; everything below drives it through :_frame().
function Widget:_attach(frame) self:_p().frame = frame; return frame end

-- PROTECTED: the private region, for subclasses building their own exposing methods. Not for callers
-- (the lint forbids :_frame() outside this module) -- it is the single seam other widgets unwrap through.
function Widget:_frame() return self:_p().frame end

-- ---- general layout / sizing / visibility (every widget) -------------------------------------------
function Widget:SetPoint(point, a, b, c, d)
    local f = self:_p().frame
    if type(a) == "number" or a == nil then f:SetPoint(point, a, b)               -- SetPoint(point [, x, y])
    else f:SetPoint(point, unwrap(a), b, c, d) end                                -- SetPoint(point, rel, relPoint, x, y)
    return self
end
function Widget:SetAllPoints(rel)  self:_p().frame:SetAllPoints(unwrap(rel)); return self end
function Widget:ClearAllPoints()   self:_p().frame:ClearAllPoints();         return self end
function Widget:SetParent(p)       self:_p().frame:SetParent(unwrap(p));     return self end
function Widget:SetSize(w, h)      self:_p().frame:SetSize(w, h);            return self end
function Widget:SetWidth(w)        self:_p().frame:SetWidth(w);              return self end
function Widget:SetHeight(h)       self:_p().frame:SetHeight(h);             return self end
function Widget:GetWidth()         return self:_p().frame:GetWidth()  end
function Widget:GetHeight()        return self:_p().frame:GetHeight() end
function Widget:Show()             self:_p().frame:Show();                   return self end
function Widget:Hide()             self:_p().frame:Hide();                   return self end
function Widget:SetShown(b)        self:_p().frame:SetShown(b);              return self end
function Widget:IsShown()          return self:_p().frame:IsShown() end
function Widget:SetAlpha(a)        self:_p().frame:SetAlpha(a);             return self end

-- ---- FrameWidget: a widget backed by a real Frame/Button/etc. -- adds the general FRAME powers
-- (event wiring, mouse, strata). Visual extras (scale, colour) stay opt-in: a subclass that wants
-- one defines its own method. Interactive widgets (Button, Toggle, Window, ...) extend this.
local FrameWidget = ns.Class.new("FrameWidget", Widget, { abstract = true })
function FrameWidget:SetScript(s, fn)      self:_p().frame:SetScript(s, fn);        return self end
function FrameWidget:HookScript(s, fn)     self:_p().frame:HookScript(s, fn);       return self end
function FrameWidget:EnableMouse(b)        self:_p().frame:EnableMouse(b);          return self end
function FrameWidget:EnableMouseWheel(b)   self:_p().frame:EnableMouseWheel(b);     return self end
function FrameWidget:RegisterForDrag(...)  self:_p().frame:RegisterForDrag(...);    return self end
function FrameWidget:SetFrameStrata(s)     self:_p().frame:SetFrameStrata(s);       return self end
function FrameWidget:SetFrameLevel(l)      self:_p().frame:SetFrameLevel(l);        return self end

-- ---- TextWidget: a widget backed by a FontString -- adds text content/justify/colour/measurement.
local TextWidget = ns.Class.new("TextWidget", Widget, { abstract = true })
function TextWidget:SetText(s)          self:_p().frame:SetText(s);                 return self end
function TextWidget:GetText()           return self:_p().frame:GetText() end
function TextWidget:SetTextColor(...)   self:_p().frame:SetTextColor(...);          return self end
function TextWidget:SetJustifyH(j)      self:_p().frame:SetJustifyH(j);             return self end
function TextWidget:SetJustifyV(j)      self:_p().frame:SetJustifyV(j);             return self end
function TextWidget:SetWordWrap(b)      self:_p().frame:SetWordWrap(b);             return self end
function TextWidget:SetSpacing(n)       self:_p().frame:SetSpacing(n);              return self end
function TextWidget:GetStringWidth()    return self:_p().frame:GetStringWidth()  end
function TextWidget:GetStringHeight()   return self:_p().frame:GetStringHeight() end

-- ---- TextureWidget: a widget backed by a Texture -- adds fill/colour/coords.
local TextureWidget = ns.Class.new("TextureWidget", Widget, { abstract = true })
function TextureWidget:SetColorTexture(...) self:_p().frame:SetColorTexture(...);   return self end
function TextureWidget:SetTexture(...)      self:_p().frame:SetTexture(...);        return self end
function TextureWidget:SetTexCoord(...)     self:_p().frame:SetTexCoord(...);       return self end
function TextureWidget:SetVertexColor(...)  self:_p().frame:SetVertexColor(...);    return self end
function TextureWidget:SetDrawLayer(...)    self:_p().frame:SetDrawLayer(...);      return self end

-- A plain (unstyled) container Frame -- the generic surface other widgets expose as their content /
-- body region, and the only way a caller gets a parentable area without a raw frame leaking. Pass a
-- parent to create one under it, or an existing raw region (template = "__adopt__") to wrap in place.
local ContainerW = ns.Class.new("Container", FrameWidget)
function ContainerW:Initialize(parent, template)
    if template == "__adopt__" then self:_attach(parent)   -- internal: wrap an already-created region
    else self:_attach(CreateFrame("Frame", nil, unwrap(parent))) end
end
Widgets.Container = ContainerW
local function adopt(region) return ContainerW:New(region, "__adopt__") end   -- wrap an existing raw region

-- Frame levels claimed by Widgets.Window, PER STRATA (a level only governs draw order among
-- frames in the SAME strata), so two windows in one strata never share a level and z-fight. A
-- requested level that's taken steps DOWN to the highest free level below it and warns with the
-- level it actually used. Windows are persistent singletons, so claims are never released.
local usedLevels = {}   -- strata -> { level -> true }
local function claimLevel(strata, requested)
    local taken = usedLevels[strata]
    if not taken then taken = {}; usedLevels[strata] = taken end
    local level = requested
    while level > 0 and taken[level] do level = level - 1 end
    if level ~= requested then
        ns.Logger:Core():Warn(("window level %d (strata %s) is already in use; using %d instead")
            :format(requested, strata, level))
    end
    taken[level] = true
    return level
end

-- Shared "needs a /reload to apply" flag, appended to an option's label so the
-- marker looks the same everywhere it's used.
Widgets.RELOAD_FLAG = "  |cff" .. Theme.hex.amber .. "(reload)|r"
function Widgets.FlagReload(label) return label .. Widgets.RELOAD_FLAG end

-- Apply a solid themed backdrop + colours to a BackdropTemplate frame.
function Widgets.Style(frame, bgKey, borderKey, edgeSize)
    frame:SetBackdrop(Theme.Backdrop(edgeSize or 1))
    frame:SetBackdropColor(Theme.Unpack(bgKey or "panel"))
    frame:SetBackdropBorderColor(Theme.Unpack(borderKey or "border"))
    return frame
end

-- A bordered, themed container Frame. Opt-in colour methods (:SetBackdropColor/Border) let the
-- panels that change tint on hover/state drive their own look.
local PanelW = ns.Class.new("Panel", FrameWidget)
function PanelW:Initialize(parent, bgKey, borderKey)
    local f = CreateFrame("Frame", nil, unwrap(parent), "BackdropTemplate")
    Widgets.Style(f, bgKey or "panel", borderKey or "border")
    self:_attach(f)
end
function PanelW:SetBackdropColor(...)       self:_frame():SetBackdropColor(...);       return self end
function PanelW:SetBackdropBorderColor(...) self:_frame():SetBackdropBorderColor(...); return self end
Widgets.Panel = PanelW   -- construct with Widgets.Panel:New(parent, ...)

-- 1px horizontal hairline (anchor + width set by caller).
local DividerW = ns.Class.new("Divider", TextureWidget)
function DividerW:Initialize(parent)
    local t = unwrap(parent):CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(Theme.Unpack("border"))
    t:SetHeight(1)
    self:_attach(t)
end
Widgets.Divider = DividerW

-- A framed portrait/avatar: a themed bordered box whose texture fills it (inset by the border),
-- with the portrait's baked-in ring trimmed. The single place unit/character portraits are built,
-- so no surface hand-rolls its own frame+texture. Sized square to `size` if given; anchor like any
-- widget. Methods: :SetPortrait(unit) (live unit portrait) :SetTexture(file) (an explicit image).
local AvatarW = ns.Class.new("Avatar", FrameWidget)
function AvatarW:Initialize(parent, size)
    local f = CreateFrame("Frame", nil, unwrap(parent), "BackdropTemplate")
    Widgets.Style(f, "panel2", "borderStrong")
    if size then f:SetSize(size, size) end
    local tex = f:CreateTexture(nil, "ARTWORK")   -- above the backdrop fill so it's never hidden
    tex:SetPoint("TOPLEFT", 2, -2)
    tex:SetPoint("BOTTOMRIGHT", -2, 2)
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)        -- trim the portrait's baked-in ring
    self:_attach(f)
    self:_p().tex = tex
end
function AvatarW:SetPortrait(unit) if SetPortraitTexture then SetPortraitTexture(self:_p().tex, unit) end; return self end
function AvatarW:SetTexture(file)  self:_p().tex:SetTexture(file); return self end
Widgets.Avatar = AvatarW

local TextW = ns.Class.new("Text", TextWidget)
function TextW:Initialize(parent, text, key, template)
    local fs = unwrap(parent):CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
    fs:SetText(text or "")
    fs:SetTextColor(Theme.Unpack(key or "text"))
    self:_attach(fs)
end
Widgets.Text = TextW

-- Uppercase, dim, lightly spaced section label (LoL's letter-spaced caps).
local SectionLabelW = ns.Class.new("SectionLabel", TextWidget)
function SectionLabelW:Initialize(parent, text)
    local fs = unwrap(parent):CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    fs:SetText(string.upper(text or ""))
    fs:SetTextColor(Theme.Unpack("textFaint"))
    fs:SetSpacing(2)
    self:_attach(fs)
end
Widgets.SectionLabel = SectionLabelW

-- Inline accent text button (Clear / links). :SetText / :SetTextColor recolour the label,
-- :SetOnClick wires the click (:SetScript is also available from FrameWidget).
local TextButtonW = ns.Class.new("TextButton", FrameWidget)
function TextButtonW:Initialize(parent, text)
    local b = CreateFrame("Button", nil, unwrap(parent))
    local fs = TextW:New(b, text, "accent", "GameFontNormalSmall")
    fs:SetPoint("CENTER")
    b:SetSize(math.max(40, fs:GetStringWidth() + 12), 20)
    b:SetScript("OnEnter", function() fs:SetTextColor(Theme.Unpack("text")) end)
    b:SetScript("OnLeave", function() fs:SetTextColor(Theme.Unpack("accent")) end)
    self:_attach(b)
    self:_p().label = fs
end
function TextButtonW:SetText(s)        self:_p().label:SetText(s);        return self end
function TextButtonW:SetTextColor(...) self:_p().label:SetTextColor(...); return self end
function TextButtonW:SetOnClick(fn)    self:_frame():SetScript("OnClick", fn); return self end
Widgets.TextButton = TextButtonW

-- A themed PUSH button: a bordered box with a centred label that lights to accent on hover.
-- Auto-sizes to the text (override with opts.width / opts.height). Methods: :SetText(s)
-- :SetOnClick(fn) :SetEnabled(bool).
local ButtonW = ns.Class.new("Button", FrameWidget)
function ButtonW:Initialize(parent, text, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, unwrap(parent), "BackdropTemplate")
    Widgets.Style(b, "panel2", "borderStrong")
    b:SetHeight(opts.height or 24)
    local fs = TextW:New(b, text, "text", "GameFontHighlight")
    fs:SetPoint("CENTER")
    local function fit() b:SetWidth(opts.width or math.max(opts.minWidth or 70, fs:GetStringWidth() + 24)) end
    fit()
    local p = self:_p()
    p.label, p.fit, p.enabled = fs, fit, true
    b:SetScript("OnEnter", function() if p.enabled then b:SetBackdropBorderColor(Theme.Unpack("accent")) end end)
    b:SetScript("OnLeave", function() b:SetBackdropBorderColor(Theme.Unpack("borderStrong")) end)
    b:SetScript("OnClick", function() if p.enabled and p.onClick then p.onClick() end end)
    self:_attach(b)
end
function ButtonW:SetText(s)     local p = self:_p(); p.label:SetText(s); p.fit(); return self end
function ButtonW:SetOnClick(fn) self:_p().onClick = fn; return self end
function ButtonW:SetEnabled(on)
    local p = self:_p(); p.enabled = on and true or false
    p.label:SetTextColor(Theme.Unpack(p.enabled and "text" or "textFaint"))
    self:_frame():SetAlpha(p.enabled and 1 or 0.6)
    return self
end
Widgets.Button = ButtonW

-- Themed checkbox. Methods: :SetChecked(bool) :GetChecked() :SetOnToggle(fn) :SetEnabled(bool).
local ToggleW = ns.Class.new("Toggle", FrameWidget)
function ToggleW:Initialize(parent, labelText)
    local rawParent = unwrap(parent)
    local btn = CreateFrame("Button", nil, rawParent)
    btn:SetSize(18, 18)

    local box = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    box:SetAllPoints()
    Widgets.Style(box, "panel2", "borderStrong")

    local check = box:CreateTexture(nil, "OVERLAY")
    check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    check:SetPoint("CENTER")
    check:SetSize(20, 20)
    check:Hide()

    local label
    if labelText then
        label = TextW:New(rawParent, labelText, "text", "GameFontHighlight")
        label:SetPoint("LEFT", btn, "RIGHT", 8, 0)
    end

    local p = self:_p()
    p.state, p.enabled = false, true
    local function render()
        if not p.enabled then  -- greyed out: dim, show state faintly, ignore input
            box:SetBackdropColor(Theme.Unpack("panel2", 0.5))
            box:SetBackdropBorderColor(Theme.Unpack("border"))
            check:SetVertexColor(0.5, 0.5, 0.5)
            check:SetShown(p.state)
            if label then label:SetTextColor(Theme.Unpack("textFaint")) end
            return
        end
        check:SetVertexColor(1, 1, 1)
        if label then label:SetTextColor(Theme.Unpack("text")) end
        if p.state then
            box:SetBackdropColor(Theme.Unpack("accent", 0.85))
            box:SetBackdropBorderColor(Theme.Unpack("accent"))
            check:Show()
        else
            box:SetBackdropColor(Theme.Unpack("panel2"))
            box:SetBackdropBorderColor(Theme.Unpack("borderStrong"))
            check:Hide()
        end
    end
    p.render = render

    btn:SetScript("OnEnter", function()
        if p.enabled and not p.state then box:SetBackdropBorderColor(Theme.Unpack("accent")) end
    end)
    btn:SetScript("OnLeave", render)
    btn:SetScript("OnClick", function()
        if not p.enabled then return end
        p.state = not p.state
        render()
        if p.onToggle then p.onToggle(p.state) end
    end)

    self:_attach(btn)
    render()
end
function ToggleW:SetChecked(v)   local p = self:_p(); p.state = v and true or false; p.render(); return self end
function ToggleW:GetChecked()    return self:_p().state end
function ToggleW:SetOnToggle(fn) self:_p().onToggle = fn; return self end
function ToggleW:SetEnabled(on)  local p = self:_p(); p.enabled = on and true or false; p.render(); return self end
Widgets.Toggle = ToggleW

-- Left-rail navigation item with active accent bar + tint. Methods:
-- :SetActive(bool). Use :SetScript("OnClick", ...) (from FrameWidget) to handle selection.
local NavItemW = ns.Class.new("NavItem", FrameWidget)
function NavItemW:Initialize(parent, text)
    local b = CreateFrame("Button", nil, unwrap(parent), "BackdropTemplate")
    b:SetHeight(34)
    b:SetBackdrop(Theme.Backdrop(1))
    b:SetBackdropColor(0, 0, 0, 0)
    b:SetBackdropBorderColor(0, 0, 0, 0)

    local bar = b:CreateTexture(nil, "OVERLAY")
    bar:SetColorTexture(Theme.Unpack("accent"))
    bar:SetPoint("TOPLEFT")
    bar:SetPoint("BOTTOMLEFT")
    bar:SetWidth(3)
    bar:Hide()

    local fs = b:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetPoint("LEFT", 14, 0)
    fs:SetText(text)
    fs:SetTextColor(Theme.Unpack("textDim"))

    local p = self:_p()
    p.active = false
    local function render()
        if p.active then
            b:SetBackdropColor(Theme.Unpack("accentSoft"))
            fs:SetTextColor(Theme.Unpack("accent"))
            bar:Show()
        else
            b:SetBackdropColor(0, 0, 0, 0)
            fs:SetTextColor(Theme.Unpack("textDim"))
            bar:Hide()
        end
    end
    p.render = render
    b:SetScript("OnEnter", function()
        if not p.active then
            b:SetBackdropColor(Theme.Unpack("panel2"))
            fs:SetTextColor(Theme.Unpack("text"))
        end
    end)
    b:SetScript("OnLeave", render)

    self:_attach(b)
    render()
end
function NavItemW:SetActive(v) local p = self:_p(); p.active = v and true or false; p.render(); return self end
Widgets.NavItem = NavItemW

-- Segmented selector (LoL "view-switch"): a row of option buttons, active one
-- accent-highlighted. options = { { value = v, text = "..." }, ... }.
-- Methods: :SetValue(v) :GetValue() :SetOnChange(fn) :SetEnabled(bool).
local SegmentedW = ns.Class.new("Segmented", FrameWidget)
function SegmentedW:Initialize(parent, options)
    local c = CreateFrame("Frame", nil, unwrap(parent), "BackdropTemplate")
    Widgets.Style(c, "panel2", "border")
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
        local fs = TextW:New(b, opt.text, "textDim", "GameFontNormalSmall")
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
        end)
        b:SetScript("OnEnter", function() if p.enabled and opt.value ~= p.value then fs:SetTextColor(Theme.Unpack("text")) end end)
        b:SetScript("OnLeave", render)
        x = x + w + 2
    end
    c:SetWidth(x)

    self:_attach(c)
    render()
end
function SegmentedW:SetValue(v)     local p = self:_p(); p.value = v; p.render(); return self end
function SegmentedW:GetValue()      return self:_p().value end
function SegmentedW:SetOnChange(fn) self:_p().onChange = fn; return self end
function SegmentedW:SetEnabled(on)
    local p = self:_p(); p.enabled = on and true or false
    self:_frame():SetAlpha(p.enabled and 1 or 0.4); p.render(); return self
end
Widgets.Segmented = SegmentedW

-- Colour swatch button: shows the current colour, opens the Blizzard colour
-- picker on click. Methods: :SetColor(r,g,b) :GetColor() :SetOnChange(fn) :SetDefault :SetEnabled.
local ColorSwatchW = ns.Class.new("ColorSwatch", FrameWidget)
function ColorSwatchW:Initialize(parent)
    local btn = CreateFrame("Button", nil, unwrap(parent), "BackdropTemplate")
    btn:SetSize(26, 16)
    Widgets.Style(btn, "panel2", "borderStrong")

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
    local reset = TextButtonW:New(btn, "Reset")
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

-- Dependency group: lets a settings page grey out controls whose parent option is off.
-- Add(control, predicate) registers any widget that supports :SetEnabled(bool); Refresh()
-- re-evaluates every predicate and enables/disables accordingly. Call Refresh() after a
-- parent control changes (and once after building). Controls without :SetEnabled are
-- ignored, so notes/labels can be skipped safely.
function Widgets.DependencyGroup()
    local entries = {}
    local group = {}
    function group:Add(control, predicate)
        if control and control.SetEnabled and type(predicate) == "function" then
            entries[#entries + 1] = { control = control, predicate = predicate }
        end
    end
    function group:Refresh()
        for _, e in ipairs(entries) do
            e.control:SetEnabled(e.predicate() and true or false)
        end
    end
    return group
end

-- Collapsible section ("accordion"): a clickable header with a +/- chevron that
-- shows or hides a content frame full of sub-widgets. Lets a long settings page
-- compress to a short stack of category headers; expand only what you need.
-- Parent children into :GetContent(), then call :SetContentHeight(h) so the
-- section knows how tall its expanded body is. :SetOnToggle(fn) fires on every
-- expand/collapse so the page can re-stack the sections below it.
-- Methods: :GetContent() :SetContentHeight(h) :SetExpanded(b) :IsExpanded()
--          :SetOnToggle(fn)   (read current total height with :GetHeight()).
local CollapsibleSectionW = ns.Class.new("CollapsibleSection", FrameWidget)
function CollapsibleSectionW:Initialize(parent, titleText)
    local HEADER, GAP = 26, 4
    local sec = CreateFrame("Frame", nil, unwrap(parent))
    sec:SetHeight(HEADER)

    local header = CreateFrame("Button", nil, sec, "BackdropTemplate")
    header:SetHeight(HEADER)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT")
    Widgets.Style(header, "panel2", "border")

    local chevron = TextW:New(header, "+", "accent", "GameFontNormalLarge")
    chevron:SetPoint("LEFT", 10, 0)
    local label = TextW:New(header, titleText, "text", "GameFontNormal")
    label:SetPoint("LEFT", chevron, "RIGHT", 8, 0)

    local content = ContainerW:New(sec)
    content:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -GAP)
    content:SetPoint("RIGHT", sec, "RIGHT", 0, 0)
    content:SetHeight(1)
    content:Hide()

    local p = self:_p()
    p.content, p.contentH, p.expanded = content, 0, false
    local function apply()
        chevron:SetText(p.expanded and "-" or "+")
        content:SetShown(p.expanded)
        sec:SetHeight(p.expanded and (HEADER + GAP + p.contentH) or HEADER)
    end
    p.apply = apply

    header:SetScript("OnEnter", function() header:SetBackdropBorderColor(Theme.Unpack("accent")) end)
    header:SetScript("OnLeave", function() header:SetBackdropBorderColor(Theme.Unpack("border")) end)
    header:SetScript("OnClick", function()
        p.expanded = not p.expanded
        apply()
        if p.onToggle then p.onToggle(p.expanded) end
    end)
    p.label = label
    self:_attach(sec)
    apply()
end
function CollapsibleSectionW:GetContent()        return self:_p().content end
function CollapsibleSectionW:SetContentHeight(h) local p = self:_p(); p.contentH = math.max(0, h or 0); p.apply(); return self end
function CollapsibleSectionW:SetExpanded(v)      local p = self:_p(); p.expanded = v and true or false; p.apply(); return self end
function CollapsibleSectionW:IsExpanded()        return self:_p().expanded end
function CollapsibleSectionW:SetOnToggle(fn)     self:_p().onToggle = fn; return self end
function CollapsibleSectionW:SetTitle(t)         self:_p().label:SetText(t); return self end
Widgets.CollapsibleSection = CollapsibleSectionW

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
    Widgets.Style(box, "panel2", "borderStrong")
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

-- Themed horizontal slider with a track, an accent fill, a draggable thumb, and a live numeric
-- readout (right of an optional label). The widget is a container Frame -- anchor it like any other.
--   opts: min, max, step, width (track px, 160), label (string), format (readout fmt, "%.2f")
-- Methods: :SetValue(v) :GetValue() :SetOnChange(fn)  fn(newValue) on user drag  :SetEnabled(bool)
local SliderW = ns.Class.new("Slider", FrameWidget)
function SliderW:Initialize(parent, opts)
    opts = opts or {}
    local minV, maxV = opts.min or 0, opts.max or 1
    local step  = opts.step or 0.01
    local width = opts.width or 160
    local fmt   = opts.format or "%.2f"

    local f = CreateFrame("Frame", nil, unwrap(parent))
    f:SetSize(width, 34)

    if opts.label then
        local label = TextW:New(f, opts.label, "text", "GameFontHighlightSmall")
        label:SetPoint("TOPLEFT", 0, 0)
    end
    local readout = TextW:New(f, "", "accent", "GameFontHighlightSmall")
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
    end)
    self:_attach(f)
    render(minV)
end
function SliderW:SetValue(v)    local p = self:_p(); p.suppress = true; p.slider:SetValue(v); p.suppress = false; p.render(p.slider:GetValue()); return self end
function SliderW:GetValue()     return self:_p().slider:GetValue() end
function SliderW:SetOnChange(fn) self:_p().onChange = fn; return self end
function SliderW:SetEnabled(on)
    local p = self:_p(); p.enabled = on and true or false
    p.slider:EnableMouse(p.enabled); self:_frame():SetAlpha(p.enabled and 1 or 0.5)
    return self
end
Widgets.Slider = SliderW

-- A titled settings GROUP: a bordered panel with a clickable header strip (chevron + `title`) and a
-- content area below it that callers fill. COLLAPSIBLE -- clicking the header toggles the body (the
-- group shrinks to just its header when collapsed). Returns the container Frame; anchor it like any
-- widget. Methods: :GetContent() (parent your controls into it), :SetContentHeight(h) (the expanded
-- body height), :SetExpanded(bool), :IsExpanded(), :SetOnToggle(fn) fn(expanded), :SetTitle(s).
local SettingsGroupW = ns.Class.new("SettingsGroup", FrameWidget)
function SettingsGroupW:Initialize(parent, title)
    local HEADER, PAD = 24, 10
    local g = CreateFrame("Frame", nil, unwrap(parent), "BackdropTemplate")
    Widgets.Style(g, "panel2", "border")

    local header = CreateFrame("Button", nil, g)
    header:SetPoint("TOPLEFT", 1, -1); header:SetPoint("TOPRIGHT", -1, -1); header:SetHeight(HEADER)
    local strip = header:CreateTexture(nil, "ARTWORK"); strip:SetAllPoints(); strip:SetColorTexture(Theme.Unpack("bg1"))
    local chevron = TextW:New(header, "-", "accent", "GameFontNormal")
    chevron:SetPoint("LEFT", 8, 0)
    local label = TextW:New(header, title, "text", "GameFontNormal")
    label:SetPoint("LEFT", chevron, "RIGHT", 6, 0)

    local content = ContainerW:New(g)
    content:SetPoint("TOPLEFT", g, "TOPLEFT", PAD, -(HEADER + PAD))
    content:SetPoint("TOPRIGHT", g, "TOPRIGHT", -PAD, -(HEADER + PAD))
    content:SetHeight(1)

    local p = self:_p()
    p.content, p.contentH, p.expanded, p.label = content, 0, true, label
    local function apply()
        chevron:SetText(p.expanded and "-" or "+")
        content:SetShown(p.expanded)
        g:SetHeight(p.expanded and (HEADER + PAD + math.max(0, p.contentH) + PAD) or HEADER)
    end
    p.apply = apply
    header:SetScript("OnEnter", function() g:SetBackdropBorderColor(Theme.Unpack("accent")) end)
    header:SetScript("OnLeave", function() g:SetBackdropBorderColor(Theme.Unpack("border")) end)
    header:SetScript("OnClick", function()
        p.expanded = not p.expanded; apply()
        if p.onToggle then p.onToggle(p.expanded) end
    end)
    self:_attach(g)
    apply()
end
function SettingsGroupW:GetContent()        return self:_p().content end
function SettingsGroupW:SetContentHeight(h) local p = self:_p(); p.contentH = math.max(0, h or 0); p.apply(); return self end
function SettingsGroupW:SetTitle(t)         self:_p().label:SetText(t); return self end
function SettingsGroupW:SetExpanded(v)      local p = self:_p(); p.expanded = v and true or false; p.apply(); return self end
function SettingsGroupW:IsExpanded()        return self:_p().expanded end
function SettingsGroupW:SetOnToggle(fn)     self:_p().onToggle = fn; return self end
Widgets.SettingsGroup = SettingsGroupW

-- (Widgets.ScrollFrame -- the Blizzard-template scroll frame -- was removed: every scrollable surface
-- now uses Widgets.ScrollArea, our themed scrollbar. Pages/modules never define their own scroll.)

-- Themed window CHROME factory: a movable, ESC-closable frame with a draggable title bar
-- (title + optional subtitle + a red-on-hover close X). The shared shell behind every
-- HagAIO window (settings, copy-out, the reset dashboard) so none of them re-build the
-- frame, drag handlers and close button by hand. Fill the returned frame's `.body` (the
-- region under the bar) or anchor your own content to `.bar`.
--   Widgets.Window(level, opts): `level` is a REQUIRED positional frame level -- within a strata
--   a higher level draws on top, so windows stack deterministically; levels are unique per
--   strata (a taken one steps down + warns; gap them so nested children never interleave).
--   opts: name      global frame name -> ESC closes it (UISpecialFrames); omit for none
--         width/height/point/strata   geometry (defaults 560x440, CENTER, "HIGH")
--         title     bar title text;  titleKey palette key (default "accent")
--         subtitle  faint text right of the title (e.g. a version);  barHeight (default 38)
--         onClose   fn(frame) for the X (default frame:Hide())
--         autoClose true -> hide while in COMBAT or Edit Mode, reopen after (a manual X/Esc
--                   close cancels the reopen). onAutoShow/onAutoHide(frame) override the
--                   reopen/hide for windows with custom show logic (default frame:Show/Hide).
-- Construct with Widgets.Window:New(level, opts). Exposes :Body() / :Bar() / :Title() (widgets) and
-- :SetWindowTitle(text); the close X and auto-close wiring are internal. onClose / onAutoShow /
-- onAutoHide callbacks receive the Window widget.
local WindowW = ns.Class.new("Window", FrameWidget)
function WindowW:Initialize(level, opts)
    opts = opts or {}
    assert(type(level) == "number", "Widgets.Window: a frame level (first argument) is required")
    local f = CreateFrame("Frame", opts.name, UIParent, "BackdropTemplate")
    f:SetSize(opts.width or 560, opts.height or 440)
    f:SetPoint(opts.point or "CENTER")
    Widgets.Style(f, "bg1", "borderStrong")
    local strata = opts.strata or "HIGH"
    f:SetFrameStrata(strata)
    f:SetFrameLevel(claimLevel(strata, level))
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:Hide()
    if opts.name then tinsert(UISpecialFrames, opts.name) end  -- ESC closes
    self:_attach(f)
    local p = self:_p()

    local H = opts.barHeight or 38
    local bar = PanelW:New(f, "bg0", "border")
    bar:SetHeight(H)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function() f:StartMoving() end)
    bar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    p.bar = bar

    local title = TextW:New(bar, opts.title or "", opts.titleKey or "accent", "GameFontNormalLarge")
    title:SetPoint("LEFT", 16, 0)
    p.title = title
    if opts.subtitle then
        local sub = TextW:New(bar, opts.subtitle, "textFaint", "GameFontNormalSmall")
        sub:SetPoint("LEFT", title, "RIGHT", 8, -1)
        p.subtitle = sub
    end

    local close = CreateFrame("Button", nil, unwrap(bar))
    close:SetSize(H, H)
    close:SetPoint("RIGHT", 0, 0)
    local x = TextW:New(close, "X", "textDim", "GameFontNormalLarge")
    x:SetPoint("CENTER")
    close:SetScript("OnEnter", function() x:SetTextColor(Theme.Unpack("red")) end)
    close:SetScript("OnLeave", function() x:SetTextColor(Theme.Unpack("textDim")) end)
    close:SetScript("OnClick", function() if opts.onClose then opts.onClose(self) else f:Hide() end end)
    p.closeBtn = close

    -- The content region under the bar (callers parent their layout into :Body(), or anchor to :Bar()).
    local body = ContainerW:New(f)
    body:SetPoint("TOPLEFT", unwrap(bar), "BOTTOMLEFT", 0, -1)
    body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    p.body = body

    -- Auto-close while fighting OR in Edit Mode, reopening after if it was open. Combat events
    -- go through ns.EventBus (its driver frame is always shown -- a HIDDEN window's own OnEvent
    -- wouldn't fire, so it could never hear "combat ended"); Edit Mode uses EventRegistry.
    -- __autoReopen marks "reopen me later"; the OnHide hook clears it on a manual X/Esc close.
    if opts.autoClose then
        local function suspend()
            if not f:IsShown() then return end
            f.__autoReopen, f.__autoHiding = true, true
            if opts.onAutoHide then opts.onAutoHide(self) else f:Hide() end
        end
        local function resume()
            if not f.__autoReopen then return end
            f.__autoReopen = false
            -- defer a frame: on EditMode.Exit the manager can still report active, so a
            -- re-checking show would defer again and never reopen.
            C_Timer.After(0, function()
                if opts.onAutoShow then opts.onAutoShow(self) else f:Show() end
            end)
        end
        local bus = ns.EventBus
        if bus then
            bus:On("PLAYER_REGEN_DISABLED", suspend)
            bus:On("PLAYER_REGEN_ENABLED", resume)
        end
        if EventRegistry then
            EventRegistry:RegisterCallback("EditMode.Enter", suspend, f)
            EventRegistry:RegisterCallback("EditMode.Exit", resume, f)
        end
        f:HookScript("OnHide", function()
            if f.__autoHiding then f.__autoHiding = false else f.__autoReopen = false end
        end)
    end
end
function WindowW:Body()  return self:_p().body end
function WindowW:Bar()   return self:_p().bar end
function WindowW:Title() return self:_p().title end
function WindowW:SetWindowTitle(t) self:_p().title:SetText(t or ""); return self end
Widgets.Window = WindowW

-- A vertically scrollable area with a CUSTOM themed scrollbar (no Blizzard template, so no grey
-- arrows). Mouse-wheel + draggable thumb; the thumb auto-sizes to the content/viewport ratio and
-- hides when everything fits. Fill `.content` (the scroll child, auto-matched to the viewport
-- width so only the vertical axis scrolls), then call :Update() after its height changes.
local ScrollAreaW = ns.Class.new("ScrollArea", FrameWidget)
function ScrollAreaW:Initialize(parent, name)
    local BAR = 5
    local sa = CreateFrame("Frame", nil, unwrap(parent))

    local sf = CreateFrame("ScrollFrame", name, sa)
    sf:SetPoint("TOPLEFT", 0, 0)
    sf:SetPoint("BOTTOMRIGHT", -(BAR + 3), 0)
    if sf.SetClipsChildren then sf:SetClipsChildren(true) end   -- keep over-tall content inside the viewport
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(1, 1)
    sf:SetScrollChild(content)

    local track = sa:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(Theme.Unpack("panel2", 0.6))
    track:SetWidth(BAR)
    track:SetPoint("TOPRIGHT"); track:SetPoint("BOTTOMRIGHT")

    local thumb = CreateFrame("Frame", nil, sa)
    thumb:SetWidth(BAR)
    local thumbTex = thumb:CreateTexture(nil, "ARTWORK"); thumbTex:SetAllPoints()
    thumbTex:SetColorTexture(Theme.Unpack("borderStrong"))

    local function maxScroll() return math.max(0, (content:GetHeight() or 0) - (sf:GetHeight() or 0)) end
    local function update()
        local vh, ch = sf:GetHeight() or 1, content:GetHeight() or 1
        local m = math.max(0, ch - vh)
        if sf:GetVerticalScroll() > m then sf:SetVerticalScroll(m) end   -- clamp when content shrank
        if ch <= vh + 1 then track:Hide(); thumb:Hide(); return end
        track:Show(); thumb:Show()
        local th = math.max(20, vh * vh / ch)
        thumb:SetHeight(th)
        local y = (m > 0) and -((vh - th) * (sf:GetVerticalScroll() / m)) or 0
        thumb:ClearAllPoints(); thumb:SetPoint("TOPRIGHT", sa, "TOPRIGHT", 0, y)
    end
    local function set(v)
        sf:SetVerticalScroll(math.max(0, math.min(maxScroll(), v)))
        update()
    end

    sf:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w); update() end)
    content:SetScript("OnSizeChanged", function() update() end)   -- also track the content's own height
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(_, d) set(sf:GetVerticalScroll() - d * 32) end)

    thumb:EnableMouse(true)
    thumb:SetScript("OnEnter", function() thumbTex:SetColorTexture(Theme.Unpack("accent")) end)
    thumb:SetScript("OnLeave", function() thumbTex:SetColorTexture(Theme.Unpack("borderStrong")) end)
    thumb:RegisterForDrag("LeftButton")
    thumb:SetScript("OnDragStart", function()
        local _, cy0 = GetCursorPosition()
        local s0 = sf:GetVerticalScroll()
        thumb:SetScript("OnUpdate", function()
            local _, cy = GetCursorPosition()
            local travel = (sf:GetHeight() or 0) - thumb:GetHeight()
            if travel > 0 then
                set(s0 + ((cy0 - cy) / UIParent:GetEffectiveScale() / travel) * maxScroll())
            end
        end)
    end)
    thumb:SetScript("OnDragStop", function() thumb:SetScript("OnUpdate", nil) end)

    local p = self:_p()
    p.sf, p.content, p.contentW, p.update = sf, content, adopt(content), update
    self:_attach(sa)
end
function ScrollAreaW:Update()    self:_p().update(); return self end
function ScrollAreaW:ScrollTop() local p = self:_p(); p.sf:SetVerticalScroll(0); p.update(); return self end
function ScrollAreaW:Content()   return self:_p().contentW end   -- the scroll child, as a widget
Widgets.ScrollArea = ScrollAreaW

-- Column-aligned GRID -- the one row/column layout engine. Define columns ONCE (width +
-- header label + justify); the optional sticky header AND every data row derive their cell
-- x-positions from the SAME column spec, so alignment is structural, never hand-offset. The
-- same primitive drives a single-column selectable list (a sidebar/nav) and an N-column data
-- table, so the sidebar items, section headers and the main grid all align through one code path.
--   opts: columns = { { width=number|nil(flex), label=string, justify="LEFT"/"CENTER"/"RIGHT" }, ... }
--         header   build a sticky column-label row;  striped  alternate row tints
--         scroll   default true -> rows scroll under the header; false -> laid out in place
--         name     frame name (REQUIRED when scroll, for the scrollbar);  rowHeight (22)
--         indentStep (12)  pixels per row.indent level on the first column
-- A row passed to :SetRows is one of:
--   { cells = { "..", .. }, color=paletteKey, cellColor=function(colIndex)->key|{r,g,b},
--     onClick=fn, active=bool, indent=number,
--     controls=function(rowFrame, columnXs) ... end }  -- a data / nav row; controls lets the
--       caller place persistent widgets (checkboxes/buttons) at columnXs[i] (cache them on
--       rowFrame, re-bind each call) so an interactive table still aligns through the grid
--   { section = "Label" }                          -- a full-width section header row
-- Methods: :SetColumns(cols)  :SetRows(rows)  :Refresh()  (.header is the header frame).
local GridW = ns.Class.new("Grid", FrameWidget)
function GridW:Initialize(parent, opts)
    opts = opts or {}
    local g = CreateFrame("Frame", nil, unwrap(parent))
    -- clip everything (the sticky header's columns + the scrolled rows) to the grid's own bounds, so a
    -- table wider/taller than its area is cut at the edge instead of spilling over the rest of the UI.
    if g.SetClipsChildren then g:SetClipsChildren(true) end
    local p = self:_p()
    p.columns = opts.columns or {}
    local rowH       = opts.rowHeight or 22
    local indentStep = opts.indentStep or 12
    local pad        = opts.cellPad or 4   -- left text padding (raise it to clear an active bar)
    local rows = {}

    -- x offset of each column from the grid's left; a width=nil column flexes to fill `width`.
    local function colX(width)
        local fixed = 0
        for _, c in ipairs(p.columns) do fixed = fixed + (c.width or 0) end
        local xs, x = {}, 0
        for i, c in ipairs(p.columns) do
            xs[i] = x
            x = x + (c.width or math.max(40, width - fixed))
        end
        return xs
    end

    local header, headerDiv
    if opts.header then
        header = CreateFrame("Frame", nil, g)
        header:SetPoint("TOPLEFT"); header:SetPoint("TOPRIGHT")
        header:SetHeight(opts.headerHeight or 18)
        header.cells = {}
        headerDiv = DividerW:New(g)
        headerDiv:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
        headerDiv:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -2)
    end
    p.header = header

    local content
    if opts.scroll ~= false then
        local sa = ScrollAreaW:New(g, opts.name)   -- custom themed scrollbar
        sa:SetPoint("TOPLEFT", header and headerDiv or g, header and "BOTTOMLEFT" or "TOPLEFT", 0, header and -6 or 0)
        sa:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", 0, 0)
        p.scrollArea, content = sa, unwrap(sa:Content())
    else
        content = CreateFrame("Frame", nil, g)
        content:SetPoint("TOPLEFT", header and unwrap(headerDiv) or g, header and "BOTTOMLEFT" or "TOPLEFT", 0, header and -6 or 0)
        content:SetPoint("TOPRIGHT")
    end
    p.content = content

    local function bodyWidth()
        local w = content:GetWidth()
        if not w or w < 1 then w = g:GetWidth() or 200 end
        return w
    end

    local function getRow(i)
        local r = rows[i]
        if r then return r end
        r = CreateFrame("Button", nil, content)
        r:SetHeight(rowH)
        r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints()
        r.bar = r:CreateTexture(nil, "OVERLAY")
        r.bar:SetPoint("TOPLEFT"); r.bar:SetPoint("BOTTOMLEFT"); r.bar:SetWidth(3)  -- flush to the row bg
        r.bar:SetColorTexture(Theme.Unpack("accent")); r.bar:Hide()
        r.cells = {}
        r.sectionFS = SectionLabelW:New(r, ""); r.sectionFS:SetPoint("LEFT", pad, 0); r.sectionFS:Hide()
        rows[i] = r
        return r
    end

    local function setColor(fs, key)
        if type(key) == "table" then fs:SetTextColor(key[1], key[2], key[3]) else fs:SetTextColor(Theme.Unpack(key)) end
    end

    local function refresh()
        local width = bodyWidth()   -- the ScrollArea keeps content width = viewport (no manual set)
        local xs = colX(width)

        if header then
            for ci, c in ipairs(p.columns) do
                local fs = header.cells[ci]
                if not fs then fs = SectionLabelW:New(header, ""); header.cells[ci] = fs end
                fs:ClearAllPoints(); fs:SetPoint("LEFT", xs[ci] + pad, 0)
                fs:SetWidth(math.max(10, (c.width or (width - xs[ci])) - pad - 2))
                fs:SetJustifyH(c.justify or "LEFT"); fs:SetText(c.label or ""); fs:SetWordWrap(false); fs:Show()
            end
            for ci = #p.columns + 1, #header.cells do header.cells[ci]:Hide() end
        end

        local data, y = p._data or {}, 0
        for i, rd in ipairs(data) do
            local r = getRow(i)
            for ci = #r.cells + 1, #p.columns do
                r.cells[ci] = TextW:New(r, "", "text", "GameFontHighlightSmall")
            end
            r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, y); r:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            r:SetScript("OnClick", nil); r:SetScript("OnEnter", nil); r:SetScript("OnLeave", nil); r:EnableMouse(false)
            r.bar:Hide(); r.sectionFS:Hide(); r.bg:SetColorTexture(0, 0, 0, 0)
            for _, fs in ipairs(r.cells) do fs:Hide() end

            if rd.section then
                r.sectionFS:SetText(rd.section); r.sectionFS:Show()
            else
                local indent = (rd.indent or 0) * indentStep
                for ci, c in ipairs(p.columns) do
                    local fs, extra = r.cells[ci], (ci == 1) and (rd.indent or 0) * indentStep or 0
                    fs:ClearAllPoints(); fs:SetPoint("LEFT", xs[ci] + pad + extra, 0)
                    fs:SetWidth(math.max(10, (c.width or (width - xs[ci])) - pad - 2 - extra))
                    fs:SetJustifyH(c.justify or "LEFT"); fs:SetWordWrap(false)
                    fs:SetText((rd.cells and rd.cells[ci]) or "")
                    setColor(fs, (rd.cellColor and rd.cellColor(ci)) or rd.color or "text")
                    fs:Show()
                end
                if rd.onClick then
                    r:EnableMouse(true)
                    r:SetScript("OnClick", function() rd.onClick(rd) end)
                    local function paint(hover)
                        if rd.active then r.bg:SetColorTexture(Theme.Unpack("accentSoft"))
                        elseif hover then r.bg:SetColorTexture(Theme.Unpack("panel2"))
                        else r.bg:SetColorTexture(0, 0, 0, 0) end
                    end
                    r.bar:SetShown(rd.active and true or false)
                    if rd.active then r.cells[1]:SetTextColor(Theme.Unpack("accent")) end
                    r:SetScript("OnEnter", function() paint(true) end)
                    r:SetScript("OnLeave", function() paint(false) end)
                    paint(false)
                elseif opts.striped and (i % 2 == 0) then
                    r.bg:SetColorTexture(Theme.Unpack("panel2", 0.45))
                end
                -- custom per-row widgets (checkboxes/buttons) positioned at the column x's: the row
                -- caches them on first call and re-binds them to this row's data. The first arg is a
                -- raw row region (allowlisted: an internal grid surface) and `xs` the column offsets.
                if rd.controls then rd.controls(r, xs) end
            end
            r:Show()
            y = y - rowH
        end
        for i = #data + 1, #rows do rows[i]:Hide() end
        content:SetHeight(math.max(1, -y))
        if p.scrollArea then p.scrollArea:Update() end   -- resize/position the custom scrollbar
    end
    p.refresh = refresh
    self:_attach(g)
end
function GridW:SetColumns(cols) local p = self:_p(); p.columns = cols or {}; p.refresh(); return self end
function GridW:SetRows(data)    local p = self:_p(); p._data = data; p.refresh(); return self end
function GridW:Refresh()        self:_p().refresh(); return self end
function GridW:ScrollTop()      local p = self:_p(); if p.scrollArea then p.scrollArea:ScrollTop() end; return self end
Widgets.Grid = GridW

-- A vertical NAVIGATION list: section labels + selectable items (optionally indented as
-- sub-items), with a single active selection (accent highlight + bar) and an onSelect callback.
-- Built ON Widgets.Grid (a 1-column grid) so it shares the one aligned layout + theming -- the
-- sidebar/tree any window needs, without each re-deriving row positioning or active state.
--   opts: items = { { key="x", label="X", indent=number } | { section="Group" }, ... }
--         onSelect = function(key)   rowHeight (30)   scroll (default false; name required if true)
--   methods: :SetItems(items)  :Select(key[, silent])  :GetSelected()
local NavW = ns.Class.new("Nav", GridW)
function NavW:Initialize(parent, opts)
    opts = opts or {}
    NavW.super.Initialize(self, parent, {
        columns = { {} }, scroll = opts.scroll or false, name = opts.name,
        rowHeight = opts.rowHeight or 30, cellPad = opts.cellPad,
    })
    local p = self:_p()
    p.items = opts.items or {}
    p.onSelect = opts.onSelect
    p.onReselect = opts.onReselect   -- fired when the user CLICKS the already-active item (optional)
    self:_rebuild()
end
function NavW:_rebuild()
    local p = self:_p()
    local rows = {}
    for _, it in ipairs(p.items) do
        if it.section then
            rows[#rows + 1] = { section = it.section }
        else
            local key = it.key
            rows[#rows + 1] = {
                cells = { it.label }, indent = it.indent or 0,
                active = (key == p.selected),
                -- re-clicking the active item routes to onReselect (only on a real click, never on
                -- a programmatic Select), so callers can e.g. toggle back to a home/overview view.
                onClick = function()
                    if key == p.selected and p.onReselect then p.onReselect(key)
                    else self:Select(key) end
                end,
            }
        end
    end
    self:SetRows(rows)
end
function NavW:SetItems(items) self:_p().items = items or {}; self:_rebuild(); return self end
function NavW:GetSelected()   return self:_p().selected end
-- Select a key: re-highlight and (unless silent) fire onSelect. No-op styling for an
-- unknown key, so callers can clear the selection with nil.
function NavW:Select(key, silent)
    local p = self:_p()
    p.selected = key
    self:_rebuild()
    if not silent and p.onSelect then p.onSelect(key) end
    return self
end
Widgets.Nav = NavW

-- TEXTURE WIDGET -- a DUMB thin wrapper over a WoW Texture. It does NO maths and makes NO layout
-- decisions: it only applies the WeakAuras texel-crisp fix (SetSnapToPixelGrid(false) +
-- SetTexelSnappingBias(0), so the art isn't biased inward and snapped into a faint margin) and exposes
-- plain passthrough setters. ALL cropping, fitting and filling lives in ns.TextureService, which drives
-- these setters -- so the crop maths has a single home. Widgets are pooled and kept alive by that
-- Service (a long-lived singleton) so they aren't garbage-collected.
--   opts: layer ("ARTWORK"), sublevel (0)
-- Setters (each returns self): :SetTexture :SetAtlas :SetCoords(l,r,t,b) :SetParent :ClearAllPoints
--   :SetPoint :SetSize :SetDrawLayer :SetVertexColor :Show :Hide :Reset
-- Inherits TextureWidget for SetTexture/SetVertexColor/SetDrawLayer + base layout; adds the
-- atlas/coords/reset helpers TextureService drives. Construct with Widgets.Texture:New(parent, opts).
local TextureW = ns.Class.new("Texture", TextureWidget)
function TextureW:Initialize(parent, opts)
    opts = opts or {}
    local tex = unwrap(parent):CreateTexture(nil, opts.layer or "ARTWORK", nil, opts.sublevel or 0)
    if tex.SetSnapToPixelGrid then tex:SetSnapToPixelGrid(false) end
    if tex.SetTexelSnappingBias then tex:SetTexelSnappingBias(0) end
    self:_attach(tex)
end
function TextureW:SetAtlas(atlas)       self:_frame():SetAtlas(atlas, false); return self end  -- atlas carries its own coords
function TextureW:SetCoords(l, r, t, b) self:_frame():SetTexCoord(l, r, t, b); return self end
function TextureW:Reset()
    local tex = self:_frame()
    tex:Hide(); tex:ClearAllPoints(); tex:SetTexture(nil); tex:SetTexCoord(0, 1, 0, 1)
    return self
end
Widgets.Texture = TextureW

-- Auto-sizing ICON GRID -- Encounter-Journal-style tiles laid out a FIXED number per row, each
-- tile auto-sized to fill the available width. A tile is a button: the image on top, a solid
-- titlebar across the bottom holding the centred name, a themed border that lights to accent on
-- hover/selection, and an optional small badge in the image's top-right corner. Tiles scroll
-- under the shared themed scrollbar (Widgets.ScrollArea) and re-size on resize.
--   opts: name (scrollbar frame name), perRow (3), aspect (image height/width, 0.5),
--         gap (12), titleHeight (22)
-- A tile in :SetTiles is { texture=path|fileID, atlas=bool, label=string, labelKey=paletteKey,
--   badge=string, badgeKey=paletteKey, selected=bool, onClick=function(tile),
--   texCoord={l,r,t,b} (a fixed base crop, e.g. the EJ buttonImage1 banner region),
--   cover=bool + aspect=number (the image's px w/h; auto cover-fits the whole image to the tile),
--   contain=bool (centre a square icon at the image's height instead of filling),
--   zoom=number + panX/panY=number (apply to ANY mode: zoom is the fraction of the region shown --
--     1.0 as-is, <1 zooms in, >1 zooms out; pan re-centres the window in texcoord units).
--   All crop/fit/zoom maths lives in ns.TextureService; the tile just describes the intent. }
-- Methods: :SetTiles(list)  :Refresh()  :ScrollTop()
local IconGridW = ns.Class.new("IconGrid", FrameWidget)
function IconGridW:Initialize(parent, opts)
    opts = opts or {}
    local PER_ROW = opts.perRow or 3   -- the default; callers can override per refresh via :SetPerRow
    local ASPECT  = opts.aspect or 0.552    -- image h/w; matches the Encounter Journal tile (174x96)
    local GAP     = opts.gap or 12
    local TITLE_H = opts.titleHeight or 22
    local g = CreateFrame("Frame", nil, unwrap(parent))

    local sa = ScrollAreaW:New(g, opts.name)
    sa:SetAllPoints()
    local content = unwrap(sa:Content())
    local p = self:_p()
    p.scrollArea = sa

    local tiles = {}
    local function getTile(i)
        local t = tiles[i]
        if not t then
            t = CreateFrame("Button", nil, content)            -- container only
            -- image holder: a bordered frame that the texture always FILLS (the image follows this
            -- frame, never a manual size). The border (BORDER layer) draws over the image (BACKGROUND).
            local band = CreateFrame("Frame", nil, t, "BackdropTemplate")
            Widgets.Style(band, "panel2", "border")
            band:SetPoint("TOPLEFT", t, "TOPLEFT", 0, 0)
            band:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", 0, TITLE_H)
            t.band = band
            local tb = t:CreateTexture(nil, "ARTWORK")         -- titlebar strip below the image
            tb:SetColorTexture(Theme.Unpack("bg1"))
            tb:SetPoint("TOPLEFT", band, "BOTTOMLEFT", 0, 0); tb:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", 0, 0)
            t.titlebar = tb
            local label = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            label:SetPoint("LEFT", tb, "LEFT", 6, 0); label:SetPoint("RIGHT", tb, "RIGHT", -6, 0)
            label:SetJustifyH("CENTER"); label:SetWordWrap(false)
            t.label = label
            local badge = band:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            badge:SetPoint("TOPRIGHT", band, "TOPRIGHT", -5, -5); badge:SetJustifyH("RIGHT")
            t.badge = badge
            tiles[i] = t
        end
        -- (Re)acquire the pooled image widget. Released tiles (see :ReleaseAll) drop theirs so the
        -- source texture can be collected; this hands a fresh one back filling the band on its
        -- BACKGROUND layer (so the band border draws over it). Kept alive by the TextureService.
        if not t.img then
            t.img = (ns.TextureService and ns.TextureService:Acquire(t.band, { layer = "BACKGROUND", sublevel = 1 }))
                or TextureW:New(t.band, { layer = "BACKGROUND", sublevel = 1 })
        end
        return t
    end

    -- ---- entry CRUD: add / remove / replace single tiles without rebuilding the whole list. A tile
    -- may carry an optional `key`; ops take either a 1-based index (number) or that key (string).
    -- Removing shrinks the list, so the freed trailing tile's texture is released by refresh.
    local function indexOf(ref)
        local list = p._tiles
        if not list then return nil end
        if type(ref) == "number" then return list[ref] and ref or nil end
        for i, t in ipairs(list) do if t.key == ref then return i end end
        return nil
    end

    local function refresh()
        local w = content:GetWidth(); if not w or w < 1 then w = g:GetWidth() or 400 end
        local cols = p._perRow or PER_ROW
        local tw = math.floor((w - (cols - 1) * GAP) / cols)   -- auto-sized tile width
        if tw < 1 then tw = 1 end
        local ih = math.floor(tw * ASPECT)                     -- image height
        local th = ih + TITLE_H                                 -- full tile height
        local data = p._tiles or {}
        for i, d in ipairs(data) do
            local t = getTile(i)
            local col, rowi = (i - 1) % cols, math.floor((i - 1) / cols)
            t:SetSize(tw, th)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", content, "TOPLEFT", col * (tw + GAP), -(rowi * (th + GAP)))
            -- Describe WHAT this tile's image should look like; the TextureService owns every bit of
            -- the crop/fit/anchor maths (the widget is a dumb passthrough). Box size (tw x ih) is
            -- passed in because the holder's anchored size isn't resolved yet at refresh time.
            local mode = d.contain and "contain" or (d.cover and "cover") or "banner"
            ns.TextureService:Render(t.img, t.band, tw, ih, {
                texture = d.texture, atlas = d.atlas, mode = mode,
                aspect = d.aspect, coord = d.texCoord,
                zoom = d.zoom, panX = d.panX, panY = d.panY,
            })
            t.label:SetText(d.label or "")
            t.label:SetTextColor(Theme.Unpack(d.labelKey or "text"))
            t.badge:SetText(d.badge or "")
            if d.badge then t.badge:SetTextColor(Theme.Unpack(d.badgeKey or "accent")) end
            local function paint() t.band:SetBackdropBorderColor(Theme.Unpack(d.selected and "accent" or "border")) end
            t:SetScript("OnEnter", function() t.band:SetBackdropBorderColor(Theme.Unpack("accent")) end)
            t:SetScript("OnLeave", paint)
            t:SetScript("OnClick", d.onClick and function() d.onClick(d) end or nil)
            paint()
            t:Show()
        end
        -- surplus tiles (the list shrank, e.g. an entry was removed): hide them AND release their
        -- pooled image, so a deleted entry's texture is let go rather than left pinned. getTile
        -- re-acquires one if the grid grows again.
        for i = #data + 1, #tiles do
            local t = tiles[i]
            if t.img and ns.TextureService then ns.TextureService:Release(t.img); t.img = nil end
            t:Hide()
        end
        local rows = math.max(1, math.ceil(#data / cols))
        content:SetHeight(rows * th + (rows - 1) * GAP)
        sa:Update()
    end

    p.tiles, p.indexOf, p.refresh = tiles, indexOf, refresh
    self:_attach(g)
end
function IconGridW:SetTiles(list) local p = self:_p(); p._tiles = list or {}; p.refresh(); return self end
function IconGridW:ScrollTop()    self:_p().scrollArea:ScrollTop(); return self end
-- Override how many tiles per row (re-lays out on the next Refresh; nil restores the default).
function IconGridW:SetPerRow(n)   self:_p()._perRow = (n and n >= 1) and math.floor(n) or nil; return self end
function IconGridW:Refresh()      self:_p().refresh(); return self end
-- Release every tile's pooled image back to the TextureService (dropping the strong link that pins
-- its source texture, so an original can be collected once nothing else shows it). Tile frames are
-- kept for reuse; getTile re-acquires a fresh image on the next Refresh. Call when the owning module
-- is disabled so a grid's textures don't stay pinned for the addon's lifetime.
function IconGridW:ReleaseAll()
    local p = self:_p()
    for _, t in ipairs(p.tiles) do
        if t.img and ns.TextureService then ns.TextureService:Release(t.img); t.img = nil end
        t:Hide()
    end
    return self
end
function IconGridW:GetTiles() return self:_p()._tiles or {} end
function IconGridW:GetTile(ref) local p = self:_p(); local i = p.indexOf(ref); return i and p._tiles[i] or nil, i end
function IconGridW:AddTile(tile)
    local p = self:_p(); p._tiles = p._tiles or {}
    p._tiles[#p._tiles + 1] = tile; p.refresh(); return tile
end
function IconGridW:RemoveTile(ref)
    local p = self:_p(); local i = p.indexOf(ref); if not i then return nil end
    local removed = table.remove(p._tiles, i); p.refresh(); return removed
end
function IconGridW:ReplaceTile(ref, tile)
    local p = self:_p(); local i = p.indexOf(ref); if not i then return nil end
    p._tiles[i] = tile; p.refresh(); return tile
end
Widgets.IconGrid = IconGridW

-- Shared HagAIO icon tooltip (addon-compartment + minimap buttons): an accent title plus
-- a list of { text, key } lines coloured from the Theme palette (key defaults to "textDim").
-- Keeps the two icon services from each hand-rolling the same block + magic RGBs.
function Widgets.IconTooltip(owner, lines)
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:AddLine(Theme.Colorize("accent", "HagAIO"))
    for _, ln in ipairs(lines) do
        local r, g, b = Theme.Unpack(ln.key or "textDim")
        GameTooltip:AddLine(ln.text, r, g, b)
    end
    GameTooltip:Show()
end

ns.UI.Widgets = Widgets
