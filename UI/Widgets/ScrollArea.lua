local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt

-- UI/Widgets/ScrollArea.lua
-- A vertically scrollable area with a CUSTOM themed scrollbar (no Blizzard template, so no grey
-- arrows). Mouse-wheel + draggable thumb; the thumb auto-sizes to the content/viewport ratio and
-- hides when everything fits. Fill `.content` (the scroll child, auto-matched to the viewport
-- width so only the vertical axis scrolls), then call :Update() after its height changes.
local ScrollAreaW = ns.Class.new("ScrollArea", FrameWidget)
function ScrollAreaW:Initialize(parent, name)
    local BAR = 6
    local sa = CreateFrame("Frame", nil, unwrap(parent))

    local sf = CreateFrame("ScrollFrame", name, sa)
    sf:SetPoint("TOPLEFT", 0, 0)
    sf:SetPoint("BOTTOMRIGHT", -(BAR + 3), 0)
    if sf.SetClipsChildren then sf:SetClipsChildren(true) end   -- keep over-tall content inside the viewport
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(1, 1)
    sf:SetScrollChild(content)

    local track = sa:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(Theme.Unpack("control", 0.45))
    track:SetWidth(BAR)
    track:SetPoint("TOPRIGHT"); track:SetPoint("BOTTOMRIGHT")

    local thumb = CreateFrame("Frame", nil, sa)
    thumb:SetWidth(BAR)
    local thumbTex = thumb:CreateTexture(nil, "ARTWORK"); thumbTex:SetAllPoints()
    thumbTex:SetColorTexture(Theme.Unpack("accentDim", 0.65))

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
    thumb:SetScript("OnLeave", function() thumbTex:SetColorTexture(Theme.Unpack("accentDim", 0.65)) end)
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
    p.sf, p.content, p.contentW, p.update, p.set = sf, content, adopt(content), update, set
    self:_Attach(sa)
end
function ScrollAreaW:Update()    self:_p().update(); return self end
function ScrollAreaW:ScrollTop() local p = self:_p(); p.sf:SetVerticalScroll(0); p.update(); return self end
function ScrollAreaW:GetScroll() return self:_p().sf:GetVerticalScroll() end           -- current vertical offset
function ScrollAreaW:SetScroll(v) self:_p().set(v); return self end                    -- clamped to the scrollable range
function ScrollAreaW:Content()   return self:_p().contentW end   -- the scroll child, as a widget
Widgets.ScrollArea = ScrollAreaW
