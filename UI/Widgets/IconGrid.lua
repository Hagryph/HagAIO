local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt

-- UI/Widgets/IconGrid.lua
-- Auto-sizing ICON GRID -- Encounter-Journal-style tiles laid out a FIXED number per row, each
-- tile auto-sized to fill the available width. A tile is a button: the image on top, a solid
-- titlebar across the bottom holding the centred name, a themed border that lights to accent on
-- hover/selection, and an optional small badge in the image's top-right corner. Tiles scroll
-- under the shared themed scrollbar (Widgets.ScrollArea) and re-size on resize.
--   opts: name (scrollbar frame name), perRow (3), aspect (image height/width, 0.5),
--         gap (12), titleHeight (22)
-- A tile in :SetTiles is { texture=path|fileID, atlas=bool, label=string, labelKey=paletteKey,
--   mapID=uiMapID (zone map art composed by Widgets.MapArt; overrides texture),
--   typo={ text=string, style={ bg={r,g,b}, bg2={r,g,b}, fg={r,g,b} } } (a TYPOGRAPHY tile:
--     a two-stop gradient plate + the text in the fantasy serif + a thin rule, all hand-built --
--     used instead of an image),
--   badge=string, badgeKey=paletteKey, selected=bool, onClick=function(tile),
--   texCoord={l,r,t,b} (a fixed base crop, e.g. the EJ buttonImage1 banner region),
--   cover=bool + aspect=number (the image's px w/h; auto cover-fits the whole image to the tile),
--   contain=bool (centre a square icon at the image's height instead of filling),
--   zoom=number + panX/panY=number (apply to ANY mode: zoom is the fraction of the region shown --
--     1.0 as-is, <1 zooms in, >1 zooms out; pan re-centres the window in texcoord units).
--   All crop/fit/zoom maths lives in the tile's Texture widget; the tile just describes the intent. }
-- Methods: :SetTiles(list)  :Refresh()  :ScrollTop()
local IconGridW = ns.Class.new("IconGrid", FrameWidget)
function IconGridW:Initialize(parent, opts)
    opts = opts or {}
    local PER_ROW = opts.perRow or 3   -- the default; callers can override per refresh via :SetPerRow
    local ASPECT  = opts.aspect or 0.552    -- image h/w; matches the Encounter Journal tile (174x96)
    local GAP     = opts.gap or 12
    local TITLE_H = opts.titleHeight or 22
    local g = CreateFrame("Frame", nil, unwrap(parent))

    local sa = Widgets.ScrollArea:New(g, opts.name)
    sa:SetAllPoints()
    local content = unwrap(sa:Content())
    local p = self:_p()
    p.scrollArea = sa
    p.scrollContent = content   -- the inline detail frame parents here (scrolls with the tiles)

    local tiles = {}
    local function getTile(i)
        local t = tiles[i]
        if not t then
            t = CreateFrame("Button", nil, content)            -- container only
            -- image holder: a bordered frame that the texture always FILLS (the image follows this
            -- frame, never a manual size). The border (BORDER layer) draws over the image (BACKGROUND).
            local band = CreateFrame("Frame", nil, t, "BackdropTemplate")
            style(band, "panel2", "border")
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
        -- One Texture widget per tile, filling the band on its BACKGROUND layer (so the band border
        -- draws over it). It owns its texture; hiding the tile hides + frees that VRAM (see refresh).
        if not t.img then t.img = Widgets.Texture:New(t.band, { layer = "BACKGROUND", sublevel = 1 }) end
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
        -- expand-in-place: the first tile flagged `expanded` opens a full-width detail frame right
        -- after its ROW; every row below shifts down by the detail's height so nothing overlaps.
        local exRow
        for i, d in ipairs(data) do if d.expanded then exRow = math.floor((i - 1) / cols); break end end
        local dh = (exRow ~= nil and p._detailFrame and p._detailHeight and p._detailHeight > 0)
            and p._detailHeight or 0
        if dh == 0 then exRow = nil end
        for i, d in ipairs(data) do
            local t = getTile(i)
            local col, rowi = (i - 1) % cols, math.floor((i - 1) / cols)
            local yoff = (exRow ~= nil and rowi > exRow) and (dh + GAP) or 0   -- rows below the detail
            t:SetSize(tw, th)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", content, "TOPLEFT", col * (tw + GAP), -(rowi * (th + GAP) + yoff))
            -- Describe WHAT this tile's image should look like; the Texture widget owns the crop/fit/
            -- anchor maths. Box size (tw x ih) is passed in because the holder's anchored size isn't
            -- resolved yet at refresh time.
            if d.mapID then
                -- zone tiles: the map painting only exists as a tile grid -- MapArt composes it
                if not t.map then t.map = Widgets.MapArt:New(t.band, { layer = "BACKGROUND", sublevel = 1 }) end
                t.map:Render(t.band, tw, ih, d.mapID, d.zoom)
                t.img:Hide()
            else
                if t.map then t.map:Hide() end
                local mode = d.contain and "contain" or (d.cover and "cover") or "banner"
                t.img:Render(t.band, tw, ih, {
                    texture = d.texture, atlas = d.atlas, mode = mode,
                    aspect = d.aspect, coord = d.texCoord,
                    zoom = d.zoom, panX = d.panX, panY = d.panY,
                })
            end
            -- TYPOGRAPHY tile: a hand-built two-stop gradient plate + the name set LARGE in the
            -- fantasy serif (Morpheus, the quest-title font) + a thin rule in the style's colour.
            if d.typo then
                if not t.typoFS then
                    t.typoBG = t.band:CreateTexture(nil, "BACKGROUND", nil, 2)
                    t.typoBG:SetAllPoints(t.band)
                    t.typoFS = t.band:CreateFontString(nil, "OVERLAY")
                    t.typoFS:SetPoint("CENTER", t.band, "CENTER", 0, 4)
                    t.typoFS:SetJustifyH("CENTER")
                    t.typoRule = t.band:CreateTexture(nil, "OVERLAY")
                    t.typoRule:SetHeight(1)
                    t.typoRule:SetPoint("TOP", t.typoFS, "BOTTOM", 0, -5)
                end
                local s = d.typo.style or {}
                local bg, bg2 = s.bg or { 0.08, 0.10, 0.14 }, s.bg2 or s.bg or { 0.04, 0.05, 0.08 }
                if t.typoBG.SetGradient and CreateColor then
                    t.typoBG:SetTexture("Interface\\Buttons\\WHITE8X8")
                    t.typoBG:SetGradient("VERTICAL",                       -- bottom -> top
                        CreateColor(bg2[1], bg2[2], bg2[3], 1), CreateColor(bg[1], bg[2], bg[3], 1))
                else
                    t.typoBG:SetColorTexture(bg[1], bg[2], bg[3], 1)
                end
                local c = s.fg or { 0.85, 0.80, 0.65 }
                t.typoFS:SetFont("Fonts\\MORPHEUS.TTF", math.max(13, math.floor(ih * 0.2)), "")
                t.typoFS:SetWidth(tw - 16); t.typoFS:SetWordWrap(true)
                t.typoFS:SetText(d.typo.text or d.label or "")
                t.typoFS:SetTextColor(c[1], c[2], c[3])
                t.typoRule:SetColorTexture(c[1], c[2], c[3], 0.8)
                t.typoRule:SetWidth(math.floor(tw * 0.3))
                t.typoBG:Show(); t.typoFS:Show(); t.typoRule:Show()
            elseif t.typoFS then
                t.typoBG:Hide(); t.typoFS:Hide(); t.typoRule:Hide()
            end
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
        -- surplus tiles (the list shrank, e.g. an entry was removed): hide them. Hiding the tile hides
        -- its texture too, so WoW frees that VRAM; the tile + image widget are kept for reuse.
        for i = #data + 1, #tiles do tiles[i]:Hide() end
        -- the inline detail frame, anchored full-width directly under the expanded tile's row
        if p._detailFrame then
            if exRow ~= nil then
                p._detailFrame:ClearAllPoints()
                p._detailFrame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((exRow + 1) * (th + GAP)))
                p._detailFrame:SetWidth(w)
                p._detailFrame:SetHeight(dh)
                p._detailFrame:Show()
            else
                p._detailFrame:Hide()
            end
        end
        local rows = math.max(1, math.ceil(#data / cols))
        content:SetHeight(rows * th + (rows - 1) * GAP + (exRow ~= nil and (dh + GAP) or 0))
        sa:Update()
    end

    p.tiles, p.indexOf, p.refresh = tiles, indexOf, refresh
    self:_attach(g)
end
function IconGridW:SetTiles(list) local p = self:_p(); p._tiles = list or {}; p.refresh(); return self end
function IconGridW:ScrollTop()    self:_p().scrollArea:ScrollTop(); return self end
-- The scroll content -- parent the inline detail frame here so it scrolls with the tiles.
function IconGridW:DetailParent()  return self:_p().scrollContent end
-- Register the inline detail frame + its height (px). It opens after the tile flagged `expanded`
-- (see SetTiles); pass height 0 / no expanded tile to keep it closed. Re-lays out on the next refresh.
function IconGridW:SetDetail(frame, height)
    local p = self:_p()
    local f = frame and unwrap(frame) or nil
    if p._detailFrame and p._detailFrame ~= f then p._detailFrame:Hide() end   -- a replaced/cleared panel stays hidden
    p._detailFrame = f
    p._detailHeight = height or 0
    if f then f:SetParent(p.scrollContent) end
    return self
end
-- Override how many tiles per row (re-lays out on the next Refresh; nil restores the default).
function IconGridW:SetPerRow(n)   self:_p()._perRow = (n and n >= 1) and math.floor(n) or nil; return self end
function IconGridW:Refresh()      self:_p().refresh(); return self end
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
