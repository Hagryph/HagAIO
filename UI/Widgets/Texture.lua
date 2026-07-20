local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt

-- UI/Widgets/Texture.lua
-- ---- crop / fit / zoom maths (the single home, owned by the Texture widget) ------------------------
-- Is this string a registered atlas (vs a file path / fileID)?
local function isAtlas(image)
    return type(image) == "string" and C_Texture and C_Texture.GetAtlasInfo
        and C_Texture.GetAtlasInfo(image) ~= nil
end
-- Cover-fit the WHOLE image (texcoords 0..1) to a w x h box, centred, no distortion: crop the overflow
-- on ONE axis from the box/image aspect difference, the other axis edge-to-edge. `aspect` = image px w/h.
local function coverFit(w, h, aspect)
    local ratio = (w / h) / (aspect or 1)
    if ratio <= 1 then local cw = ratio;     return { (1 - cw) / 2, (1 + cw) / 2, 0, 1 }
    else               local ch = 1 / ratio; return { 0, 1, (1 - ch) / 2, (1 + ch) / 2 } end
end
-- Apply zoom (fraction of the region shown; <1 zooms in) + pan (texcoord units) to a base {l,r,t,b}.
local function zoomPan(b, zoom, panX, panY)
    zoom = zoom or 1
    local cx, cy = (b[1] + b[2]) / 2 + (panX or 0), (b[3] + b[4]) / 2 + (panY or 0)
    local hw, hh = (b[2] - b[1]) / 2 * zoom, (b[4] - b[3]) / 2 * zoom
    return cx - hw, cx + hw, cy - hh, cy + hh
end

-- TEXTURE WIDGET -- owns ONE WoW texture and ALL of the crop/fit/zoom maths (moved here from the old
-- TextureService). :Render(frame, w, h, spec) anchors it into `frame` and paints `spec.texture`:
--   spec.mode "contain" (centre a square side h) | "cover" (cover-fit by spec.aspect = image px w/h) |
--   "banner"/default (a fixed base crop spec.coord); spec.zoom + spec.panX/panY zoom/pan ANY mode;
--   spec.atlas forces atlas mode. A nil texture hides it. Repaints are memoised (skip if the image +
--   crop are unchanged). Hiding is enough to free VRAM -- WoW streams a texture's pixels only while it
--   renders, so a hidden texture isn't pinned (no SetTexture(nil) needed); the kept reference reloads
--   on the next :Render/:Show.  opts: layer ("ARTWORK"), sublevel (0).
local TextureW = ns.Class.new("Texture", Widget)
function TextureW:Initialize(parent, opts)
    opts = opts or {}
    local tex = unwrap(parent):CreateTexture(nil, opts.layer or "ARTWORK", nil, opts.sublevel or 0)
    if tex.SetSnapToPixelGrid then tex:SetSnapToPixelGrid(false) end      -- WeakAuras texel-crisp fix
    if tex.SetTexelSnappingBias then tex:SetTexelSnappingBias(0) end
    self:_Attach(tex)
end
function TextureW:Render(frame, w, h, spec)
    spec = spec or {}
    local tex = self:_Frame()
    if not spec.texture then return self:Hide() end
    frame = unwrap(frame)
    local base
    if spec.mode == "contain" then
        -- centre a square side h; for an ATLAS, fit to its native aspect inside the h x h box (so a
        -- non-square atlas icon isn't stretched), scaling the longer side to h.
        local iw, ih = h, h
        if (spec.atlas or isAtlas(spec.texture)) and C_Texture and C_Texture.GetAtlasInfo then
            local info = C_Texture.GetAtlasInfo(spec.texture)
            if info and (info.width or 0) > 0 and (info.height or 0) > 0 then
                local s = h / math.max(info.width, info.height)
                iw, ih = info.width * s, info.height * s
            end
        end
        tex:ClearAllPoints(); tex:SetSize(iw, ih); tex:SetPoint("CENTER", frame, "CENTER", 0, 0)
        base = { 0, 1, 0, 1 }
    else
        tex:ClearAllPoints()
        tex:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        tex:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        base = (spec.mode == "cover") and coverFit(w, h, spec.aspect) or (spec.coord or { 0, 1, 0, 1 })
    end
    local isA = spec.atlas or isAtlas(spec.texture)
    local l, r, t, b = zoomPan(base, spec.zoom, spec.panX, spec.panY)
    local sig = tostring(spec.texture) .. (isA and "@" or "") .. "|"
        .. string.format("%.4f,%.4f,%.4f,%.4f", l, r, t, b)
    local p = self:_p()
    if p.sig ~= sig then                          -- memo: only re-load when the image or crop changed
        p.sig = sig
        if isA then tex:SetAtlas(spec.texture, false)   -- atlas carries its own coords
        else tex:SetTexture(spec.texture); tex:SetTexCoord(l, r, t, b) end
    end
    tex:Show()
    return self
end
-- (No :Hide override -- base Widget:Hide just hides the region; WoW frees the VRAM while it's not
-- rendered, and the kept image reference means the next :Render/:Show brings it back instantly.)
Widgets.Texture = TextureW
