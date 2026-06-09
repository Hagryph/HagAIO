local addonName, ns = ...
local Class = ns.Class

-- Services/EditMode.lua
-- Standalone framework letting any module register a frame to be positioned via
-- Blizzard's Edit Mode. While Edit Mode is active the registered frames become
-- draggable; on release they snap to the Edit Mode grid (when it's shown) and to
-- each other / the screen centre. Positions persist account-wide.
--
-- Usage:
--   ns.EditMode:Register(frame, {
--       key = "flightTimer",                         -- unique persistence key
--       label = "Flight Timer",                      -- shown in Edit Mode (opt)
--       default = { point = "CENTER", x = 0, y = 0 },
--       active  = function() return module:IsEnabled() end,   -- show in edit? (opt)
--       onEnter = function(frame) ... end,           -- fill a preview (opt)
--       onExit  = function(frame) ... end,           -- restore (opt)
--   })

local EditMode = Class.new("EditMode", ns.Service)

local SNAP = 10  -- snap threshold in pixels
local function round(n) return math.floor(n + 0.5) end

function EditMode:OnInitialize()
    local p = self:_p()
    p.regs = {}
    p.editing = false
    p.hooked = false
end

function EditMode:IsEditing() return self:_p().editing end

-- Frame layout is per-character config (a cascade namespace, keyed by frame key -> {point,x,y}):
-- this char's override ?? the loaded profile ?? nil (then the frame's coded default). So layouts
-- differ per character and travel in that character's profile, storing only what was moved.
function EditMode:_Positions()
    return ns.SavedVars:SettingsView("editmode", {})
end

-- Anchor a registered frame from its saved (or default) CENTER offset.
function EditMode:Apply(reg)
    local pos = self:_Positions()[reg.key] or reg.default
    local point = pos.point or "CENTER"
    reg.frame:ClearAllPoints()
    reg.frame:SetPoint(point, UIParent, point, pos.x or 0, pos.y or 0)
end

function EditMode:Register(frame, opts)
    local p = self:_p()
    local reg = {
        frame   = frame,
        key     = opts.key,
        label   = opts.label,
        anchor  = opts.anchor,   -- "TOPLEFT" persists a top-left offset (else CENTER); read in _SnapAndSave
        default = opts.default or { point = "CENTER", x = 0, y = 0 },
        active  = opts.active,
        onEnter = opts.onEnter,
        onExit  = opts.onExit,
        onMoved = opts.onMoved,
    }
    p.regs[#p.regs + 1] = reg

    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function() if p.editing then frame:StartMoving() end end)
    frame:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        self:_SnapAndSave(reg)
    end)

    self:Apply(reg)
    self:_EnsureHooks()
    return reg
end

-- ---- snapping -------------------------------------------------------------
function EditMode:_GridSnap(cx, cy)
    local grid = EditModeManagerFrame and EditModeManagerFrame.Grid
    if not (grid and grid.IsShown and grid:IsShown() and grid.gridSpacing and grid.gridSpacing > 0) then
        return cx, cy
    end
    local gx, gy = grid:GetCenter()
    if not gx then return cx, cy end
    local s = grid.gridSpacing
    return gx + round((cx - gx) / s) * s, gy + round((cy - gy) / s) * s
end

function EditMode:_ElementSnap(reg, cx, cy, hw, hh)
    local p = self:_p()
    local bestX, bestDX = cx, SNAP + 1
    local bestY, bestDY = cy, SNAP + 1
    local function tryX(mine, other)
        local d = math.abs(mine - other)
        if d < bestDX then bestDX = d; bestX = cx + (other - mine) end
    end
    local function tryY(mine, other)
        local d = math.abs(mine - other)
        if d < bestDY then bestDY = d; bestY = cy + (other - mine) end
    end
    local myL, myR, myT, myB = cx - hw, cx + hw, cy + hh, cy - hh

    local ux, uy = UIParent:GetCenter()
    if ux then tryX(cx, ux); tryY(cy, uy) end

    for _, other in ipairs(p.regs) do
        if other ~= reg and other.frame:IsShown() then
            local ocx, ocy = other.frame:GetCenter()
            if ocx then
                local ohw, ohh = other.frame:GetWidth() / 2, other.frame:GetHeight() / 2
                local oL, oR, oT, oB = ocx - ohw, ocx + ohw, ocy + ohh, ocy - ohh
                tryX(cx, ocx); tryX(myL, oL); tryX(myR, oR); tryX(myL, oR); tryX(myR, oL)
                tryY(cy, ocy); tryY(myB, oB); tryY(myT, oT); tryY(myB, oT); tryY(myT, oB)
            end
        end
    end

    if bestDX <= SNAP then cx = bestX end
    if bestDY <= SNAP then cy = bestY end
    return cx, cy
end

function EditMode:_SnapAndSave(reg)
    local f = reg.frame
    local cx, cy = f:GetCenter()
    if not cx then return end
    local hw, hh = f:GetWidth() / 2, f:GetHeight() / 2

    cx, cy = self:_GridSnap(cx, cy)
    cx, cy = self:_ElementSnap(reg, cx, cy, hw, hh)

    -- Most frames store a CENTER offset (resize grows both ways). A frame can opt
    -- into a TOPLEFT anchor (reg.anchor) so its top-left stays put and it grows
    -- downward/rightward on resize -- used by the Task List.
    if reg.anchor == "TOPLEFT" then
        self:_Positions()[reg.key] = {
            point = "TOPLEFT",
            x = (cx - hw) - UIParent:GetLeft(),
            y = (cy + hh) - UIParent:GetTop(),
        }
    else
        local ux, uy = UIParent:GetCenter()
        self:_Positions()[reg.key] = { point = "CENTER", x = cx - ux, y = cy - uy }
    end
    self:Apply(reg)
    if reg.onMoved then reg.onMoved() end
end

-- ---- edit mode hooks ------------------------------------------------------
function EditMode:_EnsureHooks()
    local p = self:_p()
    if p.hooked or not EventRegistry then return end
    p.hooked = true
    EventRegistry:RegisterCallback("EditMode.Enter", function() self:_OnEnter() end, self)
    EventRegistry:RegisterCallback("EditMode.Exit",  function() self:_OnExit() end, self)
end

function EditMode:_OnEnter()
    local p = self:_p()
    p.editing = true
    for _, reg in ipairs(p.regs) do
        reg.wasShown = reg.frame:IsShown()
        if (not reg.active) or reg.active() then
            reg.frame:EnableMouse(true)
            reg.frame:Show()
            if reg.onEnter then reg.onEnter(reg.frame) end
        end
    end
end

function EditMode:_OnExit()
    local p = self:_p()
    p.editing = false
    for _, reg in ipairs(p.regs) do
        reg.frame:EnableMouse(false)
        if reg.onExit then reg.onExit(reg.frame) end
        if not reg.wasShown then reg.frame:Hide() end
    end
end

ns.ServiceManager:Register(EditMode:New("EditMode", { deps = { "SavedVars" } }))
