local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt

-- UI/Widgets/Typography.lua
-- TYPOGRAPHY PLATE -- text-as-art for a tile face, the third face kind beside an image
-- (Widgets.Texture) and composed map art (Widgets.MapArt). Nothing is shipped or generated: the
-- plate is assembled at render time from three regions it owns --
--   * a two-stop vertical gradient (SetGradient over the stock white texel; flat fill fallback),
--   * the text set LARGE in the fantasy serif (Morpheus, the quest-title font),
--   * a thin rule in the same light colour.
--   :Render(frame, w, h, spec) -- anchor into `frame` and paint:
--     spec.text   the plate's text (required)
--     spec.style  a ZoneStyle value type: { bg top, bg2 bottom, fg type }, each an ns.Color
--     spec.font   font path override (default Morpheus)
--     spec.scale  type size as a fraction of the box height (default 0.2)
-- opts: layer ("BACKGROUND"), sublevel (0) -- for the gradient; the type always sits on OVERLAY.
local TypographyW = ns.Class.new("Typography", FrameWidget)
function TypographyW:Initialize(parent, opts)
    opts = opts or {}
    local f = CreateFrame("Frame", nil, unwrap(parent))
    local p = self:_p()
    p.bg = f:CreateTexture(nil, opts.layer or "BACKGROUND", nil, opts.sublevel or 0)
    p.bg:SetAllPoints(f)
    p.fs = f:CreateFontString(nil, "OVERLAY")
    p.fs:SetPoint("CENTER", f, "CENTER", 0, 4)
    p.fs:SetJustifyH("CENTER")
    p.rule = f:CreateTexture(nil, "OVERLAY")
    p.rule:SetHeight(1)
    p.rule:SetPoint("TOP", p.fs, "BOTTOM", 0, -5)
    self:_Attach(f)
end

function TypographyW:Render(frame, w, h, spec)
    spec = spec or {}
    local p = self:_p()
    local f = self:_Frame()
    if not spec.text or not w or not h then self:Hide(); return self end
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", unwrap(frame), "TOPLEFT", 0, 0)
    f:SetPoint("BOTTOMRIGHT", unwrap(frame), "BOTTOMRIGHT", 0, 0)
    -- spec.style is a ZoneStyle value type (bg/bg2/fg ns.Colors); read each colour via its accessor,
    -- with ns.Color fallbacks when no style is supplied. Unpack spreads r,g,b(,a) into the WoW setters.
    local Color = ns.Color
    local s = spec.style
    local bg  = s and s:Bg()  or Color:New(0.08, 0.10, 0.14)
    local bg2 = s and s:Bg2() or (s and s:Bg()) or Color:New(0.04, 0.05, 0.08)
    local br, bgc, bb = bg:Unpack()
    if p.bg.SetGradient and CreateColor then
        local b2r, b2g, b2b = bg2:Unpack()
        p.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
        p.bg:SetGradient("VERTICAL",                            -- bottom -> top
            CreateColor(b2r, b2g, b2b, 1), CreateColor(br, bgc, bb, 1))
    else
        p.bg:SetColorTexture(br, bgc, bb, 1)
    end
    local fg = s and s:Fg() or Color:New(0.85, 0.80, 0.65)
    local fr, fgc, fb = fg:Unpack()
    p.fs:SetFont(spec.font or "Fonts\\MORPHEUS.TTF", math.max(13, math.floor(h * (spec.scale or 0.2))), "")
    p.fs:SetWidth(w - 16)
    p.fs:SetWordWrap(true)
    p.fs:SetText(spec.text)
    p.fs:SetTextColor(fr, fgc, fb)
    p.rule:SetColorTexture(fr, fgc, fb, 0.8)
    p.rule:SetWidth(math.floor(w * 0.3))
    f:Show()
    return self
end
Widgets.Typography = TypographyW
