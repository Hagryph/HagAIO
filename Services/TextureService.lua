local addonName, ns = ...
local Class = ns.Class

-- Services/TextureService.lua
-- Owns the addon's reusable TEXTURE WIDGETS (ns.UI.Widgets.Texture) AND all of their cropping /
-- fitting / zooming / filling maths. A Service, not a Lib, on purpose: a Lib is stateless and would
-- hand out textures nobody keeps a reference to, so once a transient frame let go of one it could be
-- garbage-collected mid-use. This Service is a long-lived singleton; the widgets themselves are DUMB
-- passthroughs that do zero maths -- callers describe WHAT they want and the Service computes the
-- texcoords / size / anchors and drives the widget's setters.
--
-- PATH vs EDIT vs LINK -- three distinct things:
--   * PATH -- an image's identity is just its fileID/path string. Passed by value; holds nothing.
--   * EDIT -- a pooled widget that loads the PATH itself and crops/zooms it (see _Paint / Render). It
--     holds its own texture and frees it on Release (Reset -> SetTexture(nil)); the engine's own cache
--     dedupes the GPU upload across edits sharing a path. Edits are pooled (p.pool) + strongly kept
--     (p.owned, bounded by PEAK concurrent use) so grids reuse the widget objects across images.
--   * LINK -- a per-IMAGE refcount (p.links): how many edits currently display that image. _Paint
--     acquires the new image's link and drops the previous one, so an image stays "held" while ANY
--     edit (on any cached page) shows it, and goes "idle" the moment the last one replaces/releases it
--     -- the link is then reused if the image returns. A link holds nothing but the count (no second
--     texture); it's what makes a REPLACED image visibly move the hold counts (see Stats).
--
--   local img = ns.TextureService:Acquire(parentFrame, { layer = "BACKGROUND", sublevel = 1 })
--   ns.TextureService:Render(img, box, box:GetWidth(), box:GetHeight(),
--       { texture = fileID, mode = "cover", aspect = 2, zoom = 0.74, panX = -0.16 })
--   ns.TextureService:Release(img)             -- back to the pool, parked on the holder, kept alive
--
-- ZOOM (all textures): zoom is the FRACTION of the (fitted) region shown -- 1.0 keeps it as-is, < 1
-- zooms IN (e.g. 0.4 shows 40%, a 60% zoom-in), > 1 zooms OUT (1.5 shows 150%). Pan (panX/panY, in
-- texcoord units) re-centres the visible window (- x shifts it left).

local TextureService = Class.new("TextureService", ns.Service)

-- ---- crop / fit / zoom maths (the single home for all texture fitting) -----

-- Is this string a registered atlas (vs a file path / fileID)?
local function isAtlas(image)
    return type(image) == "string" and C_Texture and C_Texture.GetAtlasInfo
        and C_Texture.GetAtlasInfo(image) ~= nil
end

-- Cover-fit the WHOLE image (texcoords 0..1) to a w x h box, centred, with no distortion: crop the
-- overflow on ONE axis from the aspect difference between the box and the image, showing the other
-- axis edge-to-edge. `aspect` is the image's px width/height. Returns the base crop {l,r,t,b}.
local function coverFit(w, h, aspect)
    local ratio = (w / h) / (aspect or 1)        -- target texcoord window tcW:tcH within the unit image
    if ratio <= 1 then                           -- box narrower than image -> crop sides, full height
        local cw = ratio
        return { (1 - cw) / 2, (1 + cw) / 2, 0, 1 }
    else                                         -- box wider than image -> crop top/bottom, full width
        local ch = 1 / ratio
        return { 0, 1, (1 - ch) / 2, (1 + ch) / 2 }
    end
end

-- Apply zoom + pan to a base crop {l,r,t,b}: scale the window by `zoom` (fraction shown) about its
-- centre, then shift the centre by (panX, panY) texcoord units. Returns l, r, t, b.
local function zoomPan(b, zoom, panX, panY)
    zoom = zoom or 1
    local cx = (b[1] + b[2]) / 2 + (panX or 0)
    local cy = (b[3] + b[4]) / 2 + (panY or 0)
    local hw = (b[2] - b[1]) / 2 * zoom
    local hh = (b[4] - b[3]) / 2 * zoom
    return cx - hw, cx + hw, cy - hh, cy + hh
end

-- ---- the private texture EDIT ---------------------------------------------
-- The pooled texture controller. The raw WoW Texture is captured in a closure and never returned --
-- TextureService is the ONE place a texture is CREATED (the frame-access lint forbids CreateTexture
-- everywhere else). The Widgets.Texture WIDGET doesn't make its own texture: it HOLDS one of these
-- edits (acquired here) and releases it on hide/unload, so a texture is always service-owned/pooled.
local function newEdit(parent, opts)
    opts = opts or {}
    local tex = parent:CreateTexture(nil, opts.layer or "ARTWORK", nil, opts.sublevel or 0)
    if tex.SetSnapToPixelGrid then tex:SetSnapToPixelGrid(false) end       -- WeakAuras texel-crisp fix
    if tex.SetTexelSnappingBias then tex:SetTexelSnappingBias(0) end
    local e = {}
    function e:SetTexture(file)      tex:SetTexture(file);       return self end
    function e:SetAtlas(atlas)       tex:SetAtlas(atlas, false); return self end  -- atlas carries its own coords
    function e:SetCoords(l, r, t, b) tex:SetTexCoord(l, r, t, b); return self end
    function e:SetParent(pp)         tex:SetParent(pp);          return self end
    function e:ClearAllPoints()      tex:ClearAllPoints();       return self end
    function e:SetPoint(...)         tex:SetPoint(...);          return self end
    function e:SetSize(...)          tex:SetSize(...);           return self end
    function e:SetDrawLayer(...)     tex:SetDrawLayer(...);      return self end
    function e:SetVertexColor(...)   tex:SetVertexColor(...);    return self end
    function e:Show()                tex:Show();                 return self end
    function e:Hide()                tex:Hide();                 return self end
    function e:Reset()
        tex:Hide(); tex:ClearAllPoints(); tex:SetTexture(nil); tex:SetTexCoord(0, 1, 0, 1)
        return self
    end
    return e
end

-- ---- lifecycle ------------------------------------------------------------

function TextureService:OnInitialize()
    local p = self:_p()
    -- a hidden, never-shown frame that parks released edits so the C-side objects stay valid
    p.holder = CreateFrame("Frame", nil, UIParent)
    p.holder:Hide()
    p.pool  = {}   -- idle edit widgets, ready to hand back out
    p.owned = {}   -- every edit widget ever created -> strong refs, so none are garbage-collected
    p.links = {}   -- image-key -> { refs }: how many edits currently show that image (refcount)
end

-- The LINK record for an image (created on first sight, then kept for reuse). A link counts how many
-- edits currently display that image (refs). Acquiring/releasing links happens in _Paint / Release;
-- it's what lets the service KEEP an image alive while ANY edit (on any cached page) still shows it,
-- and drop it to idle the moment the last one stops -- without ever loading a second copy (the edits
-- load the path themselves; a link holds nothing but the count).
function TextureService:_LinkFor(image, atlas)
    local p = self:_p()
    local key = (atlas and "@" or "") .. tostring(image)
    local l = p.links[key]
    if not l then l = { refs = 0 }; p.links[key] = l end
    return l
end

-- Live hold counts (e.g. the Dev readout). The headline three are per-IMAGE, so a REPLACED image
-- shows up: `owned` = distinct images ever shown, `inUse` = images held by >=1 edit right now,
-- `idle` = images shown before but currently by none (their link is kept, reused if the image
-- returns). `widgets`/`widgetsIdle` are the separate edit-widget pool (reused across images).
function TextureService:Stats()
    local p = self:_p()
    local total, held = 0, 0
    for _, l in pairs(p.links) do
        total = total + 1
        if l.refs > 0 then held = held + 1 end
    end
    return { owned = total, inUse = held, idle = total - held, widgets = #p.owned, widgetsIdle = #p.pool }
end

-- Hand out an EDIT widget parented to `parent`. Reuses an idle one when available; otherwise creates
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
    tw = (self.__newEdit or newEdit)(parent, opts)   -- __newEdit: test seam; production uses newEdit
    p.owned[#p.owned + 1] = tw   -- keep it alive for the addon's lifetime
    return tw
end

-- ---- painting -------------------------------------------------------------

-- Anchor an edit widget flush inside `frame` (edge-to-edge, optional inset) so it follows its size.
function TextureService:AnchorFill(tw, frame, inset)
    inset = inset or 0
    tw:ClearAllPoints()
    tw:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset)
    tw:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
    return tw
end

-- Load the PATH (`image`) onto the edit `tw` and crop it to {l,r,t,b}. The edit references no
-- "original" -- it loads the image itself, so it holds its own texture and frees it on Release; the
-- engine's texture cache dedupes the actual GPU upload across edits sharing a path. Atlases carry
-- their own coords, so the crop is ignored for them.
--
-- MEMOISED: every paint stamps the edit with a signature of exactly what was applied (image + atlas +
-- the four crop coords). If the next paint asks for the same image with the same edits, we already
-- have that picture on this widget and do nothing -- so re-showing an unchanged grid/page is free and
-- never re-loads a texture. Release/Reset clear the stamp so a recycled widget always repaints.
function TextureService:_Paint(tw, image, atlas, l, r, t, b)
    local isA = atlas or isAtlas(image)
    local sig = tostring(image) .. (isA and "@" or "") .. "|"
        .. string.format("%.4f,%.4f,%.4f,%.4f", l or 0, r or 1, t or 0, b or 1)
    if tw._paintSig == sig then return tw end   -- same image + same edits already on this widget
    tw._paintSig = sig
    -- Refcount the IMAGE: hold the new one, drop the previous. When the image actually changes (not
    -- just the crop), the old image's link loses a ref -- if no other edit/cached page still shows it
    -- it goes idle, while the new image gets (or reuses) its own link. Never overwrites a link record.
    local link = self:_LinkFor(image, isA)
    if tw._link ~= link then
        if tw._link then tw._link.refs = tw._link.refs - 1 end
        link.refs = link.refs + 1
        tw._link = link
    end
    if isA then
        tw:SetAtlas(image)
    else
        tw:SetTexture(image)
        tw:SetCoords(l or 0, r or 1, t or 0, b or 1)
    end
    return tw
end

-- ---- rendering (callers do nothing manually) ------------------------------

-- Render `spec.texture` into holder `frame`, sized w x h, owning ALL crop/fit/zoom maths. spec.mode:
--   "contain"        -> centre a square (side h) icon, no fit-crop;
--   "cover"          -> auto cover-fit the whole image to the box by aspect (spec.aspect = image px w/h);
--   "banner"/default -> a fixed base crop spec.coord ({l,r,t,b}).
-- spec.zoom (fraction shown, default 1) + spec.panX/panY (texcoord units) then zoom/pan the result --
-- for EVERY mode. spec.atlas forces atlas mode. w/h are passed in (not read from the frame) because
-- anchored frames don't report their size yet at build/refresh time. Hides on a nil texture.
function TextureService:Render(tw, frame, w, h, spec)
    spec = spec or {}
    if not spec.texture then
        tw:Hide(); tw._paintSig = nil
        if tw._link then tw._link.refs = tw._link.refs - 1; tw._link = nil end   -- drop the image link
        return tw
    end
    local base
    if spec.mode == "contain" then
        tw:ClearAllPoints()
        tw:SetSize(h, h)
        tw:SetPoint("CENTER", frame, "CENTER", 0, 0)
        base = { 0, 1, 0, 1 }
    else
        self:AnchorFill(tw, frame)
        base = (spec.mode == "cover") and coverFit(w, h, spec.aspect) or (spec.coord or { 0, 1, 0, 1 })
    end
    self:_Paint(tw, spec.texture, spec.atlas, zoomPan(base, spec.zoom, spec.panX, spec.panY))
    tw:Show()
    return tw
end

-- Convenience: acquire an edit, anchor it to FILL `frame` flush, paint the image (+ optional base crop
-- and zoom/pan), and return it.
--   ns.TextureService:Fill(box, fileID)
function TextureService:Fill(frame, image, coord, opts)
    local tw = self:Acquire(frame, opts)
    self:AnchorFill(tw, frame)
    if image then
        opts = opts or {}
        self:_Paint(tw, image, opts.atlas, zoomPan(coord or { 0, 1, 0, 1 }, opts.zoom, opts.panX, opts.panY))
    end
    tw:Show()
    return tw
end

-- Return an edit widget to the pool: cleared, hidden, unlinked from its original, and parked on the
-- holder (still strongly held).
function TextureService:Release(tw)
    if not tw then return end
    local p = self:_p()
    if tw._link then tw._link.refs = tw._link.refs - 1; tw._link = nil end   -- drop the image link
    tw._paintSig = nil               -- a recycled widget must repaint, not be skipped by the memo
    tw:Reset()                       -- Reset -> SetTexture(nil) frees this edit's texture file
    tw:SetParent(p.holder)
    p.pool[#p.pool + 1] = tw
end

ns.ServiceManager:Register(TextureService:New("TextureService"))
