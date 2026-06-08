local addonName, ns = ...
local Class = ns.Class

-- Services/TextureService.lua
-- Owns the addon's reusable TEXTURE WIDGETS (ns.UI.Widgets.Texture) AND all of their cropping /
-- fitting / filling maths. A Service, not a Lib, on purpose: a Lib is stateless and would hand out
-- textures nobody keeps a reference to, so once a transient frame let go of one it could be
-- garbage-collected mid-use. This Service is a long-lived singleton that holds a STRONG reference to
-- every texture it ever creates (p.owned), so their lifetime is the addon's -- they are never
-- collected out from under a caller. It also pools idle textures (p.pool) so re-rendering grids
-- reuses textures instead of churning new ones.
--
-- The widgets themselves are DUMB passthroughs that do zero maths. Callers describe WHAT they want
-- (an image fitted into a box) and this Service computes the texcoords / size / anchors and drives
-- the widget's setters:
--
--   local img = ns.TextureService:Acquire(parentFrame, { layer = "BACKGROUND", sublevel = 1 })
--   ns.TextureService:Render(img, box, box:GetWidth(), box:GetHeight(), {
--       texture = fileID, mode = "cover", bounds = artRect, fileAspect = 2 })   -- fills, crisp, no padding
--   ns.TextureService:Release(img)             -- back to the pool, parked on the holder, kept alive

local TextureService = Class.new("TextureService", ns.Service)

-- ---- crop maths (the single home for all texture fitting) ------------------

-- Is this string a registered atlas (vs a file path / fileID)?
local function isAtlas(image)
    return type(image) == "string" and C_Texture and C_Texture.GetAtlasInfo
        and C_Texture.GetAtlasInfo(image) ~= nil
end

-- Shrink a base crop {l,r,t,b} toward its centre by `zoom` (WeakAuras icon zoom: 1 - 0.5*zoom), so
-- zoom>0 eats residual source padding and lets the art fill the box. Returns l, r, t, b.
local function zoomed(b, zoom)
    local l, r, t, btm = b[1], b[2], b[3], b[4]
    local cx, cy = (l + r) / 2, (t + btm) / 2
    local k = 1 - 0.5 * (zoom or 0)
    local hx, hy = (r - l) / 2 * k, (btm - t) / 2 * k
    return cx - hx, cx + hx, cy - hy, cy + hy
end

-- Cover-crop maths: crop a texture's transparent padding out (spec.bounds = the real art rect
-- {l,r,t,b}; default the whole file), then fit that art to a w x h box by cropping the overflow on
-- ONE axis and showing the other edge-to-edge -- fills the box with no padding and no distortion.
-- spec.fileAspect (file px w/h) maps texcoord steps to pixels so the fit isn't distorted; spec.offset
-- (box pixels, +down/right) nudges the centred crop window along the cropped axis. Returns {l,r,t,b}.
local function coverCrop(w, h, spec)
    local b = spec.bounds or { 0, 1, 0, 1 }
    local l, r, t0, b0 = b[1], b[2], b[3], b[4]
    local tcW, tcH = r - l, b0 - t0
    local ratio = (w / h) / (spec.fileAspect or 1)     -- target window tcW:tcH
    local off = spec.offset or 0
    if tcW / tcH >= ratio then          -- art wider than box -> crop sides, full height
        local cw = tcH * ratio
        local x0 = math.max(l, math.min(r - cw, l + (tcW - cw) / 2 + (cw / w) * off))
        return { x0, x0 + cw, t0, b0 }
    else                                -- art taller than box -> crop top/bottom, full width
        local ch = tcW / ratio
        local y0 = math.max(t0, math.min(b0 - ch, t0 + (tcH - ch) / 2 + (ch / h) * off))
        return { l, r, y0, y0 + ch }
    end
end

-- Push an image (+ optional base crop + zoom) onto a dumb widget. Atlases carry their own coords, so
-- base/zoom are ignored for them; file textures get the (zoomed) base crop applied.
local function applyImage(tw, image, base, zoom, forceAtlas)
    if forceAtlas or isAtlas(image) then
        tw:SetAtlas(image)
    else
        tw:SetTexture(image)
        tw:SetCoords(zoomed(base or { 0, 1, 0, 1 }, zoom))
    end
end

-- ---- lifecycle ------------------------------------------------------------

function TextureService:OnInitialize()
    local p = self:_p()
    -- a hidden, never-shown frame that parks released textures so the C-side objects stay valid
    p.holder = CreateFrame("Frame", nil, UIParent)
    p.holder:Hide()
    p.pool  = {}   -- idle texture widgets, ready to hand back out
    p.owned = {}   -- every widget ever created -> strong refs, so none are garbage-collected
end

-- Hand out a texture widget parented to `parent`. Reuses an idle one when available; otherwise creates
-- one and records it for its lifetime.
function TextureService:Acquire(parent, opts)
    local p = self:_p()
    parent = parent or p.holder
    local tw = table.remove(p.pool)
    if tw then
        tw:SetParent(parent)
        if opts and opts.layer then tw:SetDrawLayer(opts.layer, opts.sublevel or 0) end
        tw:Show()
        return tw
    end
    tw = ns.UI.Widgets.Texture(parent, opts)
    p.owned[#p.owned + 1] = tw   -- keep it alive for the addon's lifetime
    return tw
end

-- ---- anchoring ------------------------------------------------------------

-- Anchor a widget flush inside `frame` (edge-to-edge, optional inset) so it follows the frame's size.
function TextureService:AnchorFill(tw, frame, inset)
    inset = inset or 0
    tw:ClearAllPoints()
    tw:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset)
    tw:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
    return tw
end

-- ---- rendering (callers do nothing manually) ------------------------------

-- Render `spec.texture` into holder `frame`, sized w x h, owning ALL crop/fit maths. spec.mode:
--   "contain"          -> centre a square (side h) icon, no crop (no aspect distortion);
--   "cover"            -> crop padding (spec.bounds) then fit the art to the box aspect, undistorted
--                         (spec.fileAspect, spec.offset);
--   "banner"/default   -> fixed crop spec.coord ({l,r,t,b}).
-- spec.zoom shrinks the chosen crop toward its centre on top of any mode. spec.atlas forces atlas mode.
-- w/h are passed in (not read from the frame) because anchored frames don't report their size yet at
-- build/refresh time. Hides the widget when spec.texture is nil. Returns the widget.
function TextureService:Render(tw, frame, w, h, spec)
    spec = spec or {}
    if not spec.texture then tw:Hide(); return tw end
    if spec.mode == "contain" then
        tw:ClearAllPoints()
        tw:SetSize(h, h)
        tw:SetPoint("CENTER", frame, "CENTER", 0, 0)
        applyImage(tw, spec.texture, nil, spec.zoom, spec.atlas)
    else
        self:AnchorFill(tw, frame)
        local base = (spec.mode == "cover") and coverCrop(w, h, spec) or spec.coord
        applyImage(tw, spec.texture, base, spec.zoom, spec.atlas)
    end
    tw:Show()
    return tw
end

-- Convenience: acquire a texture, anchor it to FILL `frame` flush, set its image (+ optional crop),
-- and return it. Callers just hand over a frame + image.
--   ns.TextureService:Fill(box, fileID, coord)
function TextureService:Fill(frame, image, coord, opts)
    local tw = self:Acquire(frame, opts)
    self:AnchorFill(tw, frame)
    if image then applyImage(tw, image, coord, 0, opts and opts.atlas) end
    tw:Show()
    return tw
end

-- Return a widget to the pool: cleared, hidden, and parked on the holder (still strongly held).
function TextureService:Release(tw)
    if not tw then return end
    local p = self:_p()
    tw:Reset()
    tw:SetParent(p.holder)
    p.pool[#p.pool + 1] = tw
end

ns.ServiceManager:Register(TextureService:New("TextureService"))
