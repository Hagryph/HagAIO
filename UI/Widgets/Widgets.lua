local addonName, ns = ...
local Theme = ns.Theme

-- UI/Widgets/Widgets.lua
-- Base of the Widget layer: the factory table, the base class hierarchy, the generic Container and the
-- shared private helpers (unwrap/style/adopt). Loads first (pinned) so widgets + consumers
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
    if type(x) == "table" and x.IsInstanceOf and x:IsInstanceOf(Widget) then return x:_Frame() end
    return x
end

-- region/frame -> the Widget that owns it (weak both ways). Lets :Dispose walk the frame tree and find
-- the widgets nested under it, however they were parented, so teardown can cascade.
local widgetOf = setmetatable({}, { __mode = "kv" })

-- Subclasses call this once, from :Initialize, with the region they created (after unwrapping their
-- own parent via `unwrap`). Stores it privately; everything below drives it through :_Frame().
function Widget:_Attach(frame) self:_p().frame = frame; widgetOf[frame] = self; return frame end

-- PROTECTED: the private region, for subclasses building their own exposing methods. Not for callers
-- (the lint forbids :_Frame() outside this module) -- it is the single seam other widgets unwrap through.
function Widget:_Frame() return self:_p().frame end

-- ---- general layout / sizing / visibility (every widget) -------------------------------------------
function Widget:SetPoint(point, a, b, c, d)
    local f = self:_p().frame
    -- Explicit nils anchor to the SCREEN, not the parent -- so pass only the args we actually have.
    if a == nil then f:SetPoint(point)                                            -- SetPoint(point) -> parent's same point
    elseif type(a) == "number" then f:SetPoint(point, a, b)                        -- SetPoint(point, x, y) -> parent + offset
    else f:SetPoint(point, unwrap(a), b, c, d) end                                -- SetPoint(point, rel, relPoint, x, y)
    return self
end
function Widget:SetAllPoints(rel)
    -- NO-ARG must stay no-arg: frame:SetAllPoints(nil) does NOT default to the parent the way
    -- frame:SetAllPoints() does, so a page that did widget:SetAllPoints() would end up unanchored.
    if rel == nil then self:_p().frame:SetAllPoints() else self:_p().frame:SetAllPoints(unwrap(rel)) end
    return self
end
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
-- a hand-rolled callback list. The widget OBJECT ITSELF is its EventBus message (its private event), so
-- a subscriber watches exactly that widget and gets it back as the argument (plus its new value) -- no
-- string identity to decode. :OnChange(fn) subscribes (fn gets (self, value)); :_FireChange(value)
-- Emits after a user OR programmatic change. The subscription is cleaned up by the BUS when the widget
-- retires its event on :Dispose (EventBus:Delete) -- nobody unsubscribes by hand. Mixed into
-- Toggle/Segmented/Input/Slider/ColorSwatch.
local Changeable = ns.Mixin.new("Changeable", {
    OnChange = function(self, fn) return ns.EventBus and ns.EventBus:Subscribe(self, fn) end,
    _FireChange = function(self, value) if ns.EventBus then ns.EventBus:Emit(self, value) end end,
})

-- REGISTRABLE mixin: lets a widget register ITSELF with EditMode (which then positions/moves it). The
-- widget hands EditMode its OWN private frame, so callers never touch a raw frame to make something
-- movable. opts is the EditMode descriptor (key/label/default/onEnter/...). Mixed into widgets that
-- can be placed in Edit Mode (Window, Panel). Register/Unregister are IDEMPOTENT and reversible, so a
-- module can register the frame only while it (and its setting) is enabled, and unregister when it's
-- disabled -- pass the same opts each time; nothing happens if the state is already what's asked.
local Registrable = ns.Mixin.new("Registrable", {
    RegisterEditMode = function(self, opts)
        local p = self:_p()
        if ns.EditMode and not p._editRegistered then
            ns.EditMode:Register(self:_Frame(), opts)
            p._editRegistered = true
        end
        return self
    end,
    UnregisterEditMode = function(self)
        local p = self:_p()
        if ns.EditMode and p._editRegistered then
            ns.EditMode:Unregister(self:_Frame())
            p._editRegistered = false
        end
        return self
    end,
})

-- Grey this widget out unless `predicate()` holds. Re-checked when one of the given `sources` (a
-- Changeable widget or a list) changes -- subscribe to each source's own event, so it reacts to just
-- its dependencies, never a global broadcast -- and once now for the initial state. When this widget's
-- own enabled state flips it emits a change too, so a dependency CHAIN cascades (the graph is acyclic,
-- so no loop). No-op without :SetEnabled. Returns self.
function Widget:EnableWhen(sources, predicate)
    if not (self.SetEnabled and type(predicate) == "function") then return self end
    local list = (type(sources) == "table" and sources.IsInstanceOf) and { sources } or (sources or {})
    local last
    local function reeval()
        local ok, on = pcall(predicate)
        if not ok then return end
        on = on and true or false
        if on ~= last then
            last = on
            self:SetEnabled(on)
            if self._FireChange then self:_FireChange() end   -- cascade to widgets depending on me
        end
    end
    for _, src in ipairs(list) do
        if src.OnChange then src:OnChange(function() reeval() end) end   -- watch each source's event
    end
    reeval()
    return self
end

-- Walk a frame's whole subtree (through raw frames too) Disposing every Widget found under it.
local function disposeChildren(frame)
    if not (frame and frame.GetChildren) then return end
    for _, child in ipairs({ frame:GetChildren() }) do
        local w = widgetOf[child]
        if w then w:Dispose() else disposeChildren(child) end
    end
end

-- Tear this widget down: recursively Dispose every child widget under it (so a whole subtree cleans up
-- in one call), then RETIRE its event via EventBus:Delete -- the bus drops everyone who subscribed to
-- this widget (no hand unsubscribing), and fires its OnDelete callbacks -- then hide its frame.
-- Idempotent. Call it when you discard a widget subtree (e.g. a settings page on rebuild).
function Widget:Dispose()
    local p = self:_p()
    if p._disposed then return end
    p._disposed = true
    disposeChildren(p.frame)
    if ns.EventBus then ns.EventBus:Delete(self) end   -- bus clears all subscribers of my event
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
function FrameWidget:EnableMouseMotion(b)  local f = self:_p().frame; if f.EnableMouseMotion then f:EnableMouseMotion(b) else f:EnableMouse(b) end; return self end
function FrameWidget:SetClipsChildren(b)   local f = self:_p().frame; if f.SetClipsChildren then f:SetClipsChildren(b) end; return self end
function FrameWidget:GetFrameLevel()       return self:_p().frame:GetFrameLevel() end
function FrameWidget:SetClampedToScreen(b) self:_p().frame:SetClampedToScreen(b);   return self end
-- GameTooltip ownership stays mediated by the widget so the frame never leaks: the widget
-- hands its own frame to a tooltip as anchor/owner, and answers whether it still owns it.
function FrameWidget:SetTooltipOwner(tt, anchor) tt:SetOwner(self:_p().frame, anchor); return self end
function FrameWidget:OwnsTooltip(tt)             return tt:IsOwned(self:_p().frame) end

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
function TextWidget:SetShadowColor(...)  self:_p().frame:SetShadowColor(...);       return self end
function TextWidget:SetShadowOffset(...) self:_p().frame:SetShadowOffset(...);      return self end
function TextWidget:SetDrawLayer(...)    self:_p().frame:SetDrawLayer(...);         return self end
function TextWidget:SetFontObject(f)    self:_p().frame:SetFontObject(f);          return self end
function TextWidget:SetFont(...)        self:_p().frame:SetFont(...);              return self end

-- ---- TextureWidget: a widget backed by a Texture -- adds fill/colour/coords.
local TextureWidget = ns.Class.new("TextureWidget", Widget, { abstract = true })
function TextureWidget:SetColorTexture(...) self:_p().frame:SetColorTexture(...);   return self end
function TextureWidget:SetTexture(...)      self:_p().frame:SetTexture(...);        return self end
function TextureWidget:SetTexCoord(...)     self:_p().frame:SetTexCoord(...);       return self end
function TextureWidget:SetVertexColor(...)  self:_p().frame:SetVertexColor(...);    return self end
function TextureWidget:SetDrawLayer(...)    self:_p().frame:SetDrawLayer(...);      return self end
function TextureWidget:SetAtlas(...)        self:_p().frame:SetAtlas(...);          return self end
function TextureWidget:SetDesaturated(b)    self:_p().frame:SetDesaturated(b);      return self end

-- A plain (unstyled) container Frame -- the generic surface other widgets expose as their content /
-- body region, and the only way a caller gets a parentable area without a raw frame leaking. Pass a
-- parent to create one under it, or an existing raw region (template = "__adopt__") to wrap in place.
local ContainerW = ns.Class.new("Container", FrameWidget, { mixins = { Registrable } })
function ContainerW:Initialize(parent, template)
    if template == "__adopt__" then self:_Attach(parent)   -- internal: wrap an already-created region
    else self:_Attach(CreateFrame("Frame", nil, unwrap(parent))) end
end
Widgets.Container = ContainerW
local function adopt(region) return ContainerW:New(region, "__adopt__") end   -- wrap an existing raw region

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
    Container = ContainerW, unwrap = unwrap, style = style, adopt = adopt,
    Changeable = Changeable, Registrable = Registrable,
}
