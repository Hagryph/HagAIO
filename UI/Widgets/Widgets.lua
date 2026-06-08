local addonName, ns = ...
local Theme = ns.Theme

-- UI/Widgets/Widgets.lua
-- Base of the Widget layer: the factory table, the base class hierarchy, the generic Container and the
-- shared private helpers (unwrap/style/claimLevel/adopt). Loads first (pinned) so widgets + consumers
-- can reference ns.UI.Widgets / ns.UI._wb. Each concrete widget lives in its own UI/Widgets/<Name>.lua.
-- Static factory of themed building blocks (the LoL "dark + blue" language in
-- WoW frame form). Everything funnels through here so the look stays
-- consistent and the SettingsWindow reads declaratively.

ns.UI = ns.UI or {}
local Widgets = {}
ns.UI.Widgets = Widgets

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

-- region/frame -> the Widget that owns it (weak both ways). Lets :Dispose walk the frame tree and find
-- the widgets nested under it, however they were parented, so teardown can cascade.
local widgetOf = setmetatable({}, { __mode = "kv" })

-- Subclasses call this once, from :Initialize, with the region they created (after unwrapping their
-- own parent via `unwrap`). Stores it privately; everything below drives it through :_frame().
function Widget:_attach(frame) self:_p().frame = frame; widgetOf[frame] = self; return frame end

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

-- ---- reactive enable/disable (declarative grey-out) ------------------------------------------------
-- CHANGEABLE mixin: makes an interactive widget an OBSERVABLE change source -- through ns.EventBus, NOT
-- a hand-rolled callback list. There is ONE shared message, "Widget.Changed", and the changing widget
-- ITSELF is the argument (plus its new value) -- so a subscriber gets the real widget back and can read
-- it, instead of decoding identity from a message name. :OnChange(fn) is the convenience that filters
-- that message to THIS widget (fn gets (self, value)); the widget Emits via :_fireChange(value) after a
-- user OR programmatic state change. Mixed into Toggle/Segmented/Input/Slider/ColorSwatch.
local CHANGED = "Widget.Changed"
local Changeable = ns.Mixin.new("Changeable", {
    OnChange = function(self, fn)
        if not ns.EventBus then return end
        return self:_track(ns.EventBus:Subscribe(CHANGED, function(_, widget, value)
            if widget == self then fn(widget, value) end
        end))
    end,
    _fireChange = function(self, value)
        if ns.EventBus then ns.EventBus:Emit(CHANGED, self, value) end
    end,
})

-- Grey this widget out unless `predicate()` holds. Re-checked when one of the given `sources` (a
-- Changeable widget or a list) changes -- subscribe ONCE to "Widget.Changed" and act only when the
-- changed widget is one we watch, so it reacts to its dependencies, not a global broadcast -- and once
-- now for the initial state. When this widget's own enabled state flips it emits a change too, so a
-- dependency CHAIN cascades (the graph is acyclic, so no loop). No-op without :SetEnabled. Returns self.
function Widget:EnableWhen(sources, predicate)
    if not (self.SetEnabled and type(predicate) == "function") then return self end
    local list = (type(sources) == "table" and sources.IsInstanceOf) and { sources } or (sources or {})
    local watch = {}
    for _, s in ipairs(list) do watch[s] = true end
    local last
    local function reeval()
        local ok, on = pcall(predicate)
        if not ok then return end
        on = on and true or false
        if on ~= last then
            last = on
            self:SetEnabled(on)
            if self._fireChange then self:_fireChange() end   -- cascade to widgets depending on me
        end
    end
    if next(watch) and ns.EventBus then
        self:_track(ns.EventBus:Subscribe(CHANGED, function(_, widget) if watch[widget] then reeval() end end))
    end
    reeval()
    return self
end

-- Record an EventBus token so :Dispose drops the subscription. Returns the token (pass-through).
function Widget:_track(token)
    if token == nil then return token end
    local p = self:_p()
    p._tokens = p._tokens or {}
    p._tokens[#p._tokens + 1] = token
    return token
end

-- Walk a frame's whole subtree (through raw frames too) Disposing every Widget found under it.
local function disposeChildren(frame)
    if not (frame and frame.GetChildren) then return end
    for _, child in ipairs({ frame:GetChildren() }) do
        local w = widgetOf[child]
        if w then w:Dispose() else disposeChildren(child) end
    end
end

-- Tear this widget down: drop its EventBus subscriptions, recursively Dispose every child widget under
-- it (so a whole subtree cleans up in one call), then hide its frame. Idempotent. Call it when you
-- discard a widget subtree (e.g. a settings page on rebuild) so nothing leaks subscriptions.
function Widget:Dispose()
    local p = self:_p()
    if p._disposed then return end
    p._disposed = true
    if p._tokens and ns.EventBus then
        for i = 1, #p._tokens do ns.EventBus:Unsubscribe(CHANGED, p._tokens[i]) end
        p._tokens = nil
    end
    disposeChildren(p.frame)
    if p.frame and p.frame.Hide then p.frame:Hide() end
end

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

-- Apply a solid themed backdrop + colours to a BackdropTemplate frame. PRIVATE: a widget's own
-- builder uses it on the raw frame it just created; callers never hold a frame to style.
local function style(frame, bgKey, borderKey, edgeSize)
    frame:SetBackdrop(Theme.Backdrop(edgeSize or 1))
    frame:SetBackdropColor(Theme.Unpack(bgKey or "panel"))
    frame:SetBackdropBorderColor(Theme.Unpack(borderKey or "border"))
    return frame
end

-- Shared private base layer for the per-widget files (NOT public API).
ns.UI._wb = {
    Widget = Widget, FrameWidget = FrameWidget, TextWidget = TextWidget, TextureWidget = TextureWidget,
    Container = ContainerW, unwrap = unwrap, style = style, claimLevel = claimLevel, adopt = adopt,
    Changeable = Changeable,
}
