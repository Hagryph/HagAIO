local addonName, ns = ...
local Class = ns.Class

-- Services/TextureService.lua
-- Owns the addon's reusable TEXTURE WIDGETS (ns.UI.Widgets.Texture). A Service, not a Lib, on
-- purpose: a Lib is stateless and would hand out textures nobody keeps a reference to, so once a
-- transient frame let go of one it could be garbage-collected mid-use. This Service is a
-- long-lived singleton that holds a STRONG reference to every texture it ever creates (p.owned),
-- so their lifetime is the addon's -- they are never collected out from under a caller. It also
-- pools idle textures (p.pool) so re-rendering grids reuses textures instead of churning new ones.
--
--   local img = ns.TextureService:Acquire(parentFrame, { layer = "BACKGROUND", sublevel = 1 })
--   img:SetImage(fileID, coord):Fill(box)      -- crisp, fills its region (WeakAuras texel trick)
--   ns.TextureService:Release(img)             -- back to the pool, parked on the holder, kept alive

local TextureService = Class.new("TextureService", ns.Service)

function TextureService:OnInitialize()
    local p = self:_p()
    -- a hidden, never-shown frame that parks released textures so the C-side objects stay valid
    p.holder = CreateFrame("Frame", nil, UIParent)
    p.holder:Hide()
    p.pool  = {}   -- idle texture widgets, ready to hand back out
    p.owned = {}   -- every widget ever created -> strong refs, so none are garbage-collected
end

-- Hand out a texture widget parented to `parent` (WeakAuras-style fill settings already applied).
-- Reuses an idle one when available; otherwise creates one and records it for its lifetime.
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

-- Return a widget to the pool: cleared, hidden, and parked on the holder (still strongly held).
function TextureService:Release(tw)
    if not tw then return end
    local p = self:_p()
    tw:Reset()
    tw:SetParent(p.holder)
    p.pool[#p.pool + 1] = tw
end

ns.ServiceManager:Register(TextureService:New("TextureService"))
