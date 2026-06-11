local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt

-- UI/Widgets/MapArt.lua
-- ZONE MAP ART, composed by hand. WoW exposes a zone's world-map painting only as a GRID of tile
-- textures (C_Map.GetMapArtLayerTextures), never as one image -- so this widget owns a clipped
-- holder frame plus one texture per map tile and lays the full layer out COVER-FIT (scaled so the
-- art fills the w x h box, centred, overflow clipped). That turns any uiMapID into tile art with
-- the same visual weight as the Encounter Journal splashes the instance tiles use.
--   :Render(frame, w, h, mapID, zoom)  -- anchor into `frame` and paint mapID's art; zoom > 1
--                                         crops further in (1 = exact cover). nil mapID hides.
-- Re-renders are memoised by (map, box) signature; hiding frees the tiles' VRAM like any texture.
local MapArtW = ns.Class.new("MapArt", FrameWidget)
function MapArtW:Initialize(parent, opts)
    opts = opts or {}
    local f = CreateFrame("Frame", nil, unwrap(parent))
    if f.SetClipsChildren then f:SetClipsChildren(true) end   -- cover-fit overflow is cropped, not spilled
    local p = self:_p()
    p.texes = {}
    p.layer = opts.layer or "ARTWORK"
    p.sublevel = opts.sublevel or 0
    self:_attach(f)
end

function MapArtW:Render(frame, w, h, mapID, zoom)
    local p = self:_p()
    local f = self:_frame()
    if not (mapID and w and h and w > 0 and h > 0
            and C_Map and C_Map.GetMapArtLayers and C_Map.GetMapArtLayerTextures) then
        self:Hide(); return self
    end
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", unwrap(frame), "TOPLEFT", 0, 0)
    f:SetPoint("BOTTOMRIGHT", unwrap(frame), "BOTTOMRIGHT", 0, 0)
    local sig = ("%s|%dx%d|%.2f"):format(tostring(mapID), w, h, zoom or 1)
    if p.sig ~= sig then
        local layers = C_Map.GetMapArtLayers(mapID)
        local L = layers and layers[1]
        local files = L and C_Map.GetMapArtLayerTextures(mapID, 1)
        if not (L and files and #files > 0 and L.tileWidth > 0 and L.tileHeight > 0) then
            self:Hide(); return self
        end
        p.sig = sig
        local cols = math.ceil(L.layerWidth / L.tileWidth)
        -- cover-fit the whole layer to the box, centred; zoom > 1 enlarges (crops further in)
        local scale = math.max(w / L.layerWidth, h / L.layerHeight) * (zoom or 1)
        local ox = (w - L.layerWidth * scale) / 2
        local oy = (h - L.layerHeight * scale) / 2
        local tw, th = L.tileWidth * scale, L.tileHeight * scale
        for i = 1, #files do
            local tex = p.texes[i]
            if not tex then tex = f:CreateTexture(nil, p.layer, nil, p.sublevel); p.texes[i] = tex end
            local c, r = (i - 1) % cols, math.floor((i - 1) / cols)
            -- the LAST column/row tiles paint past the layer's real edge (tile-size padding, often
            -- black garbage) -- crop each to its valid fraction so no junk can land in view
            local fx = math.min(1, L.layerWidth / L.tileWidth - c)
            local fy = math.min(1, L.layerHeight / L.tileHeight - r)
            tex:SetTexture(files[i])
            tex:SetTexCoord(0, fx, 0, fy)
            tex:SetSize(tw * fx, th * fy)
            tex:ClearAllPoints()
            tex:SetPoint("TOPLEFT", f, "TOPLEFT", ox + c * tw, -(oy + r * th))
            tex:Show()
        end
        for i = #files + 1, #p.texes do p.texes[i]:Hide() end
    end
    f:Show()
    return self
end
-- Dim the whole composition (e.g. behind a typography plate). 1 = full.
function MapArtW:SetAlpha(a)
    self:_frame():SetAlpha(a or 1)
    return self
end
Widgets.MapArt = MapArtW
