local addonName, ns = ...
local Class = ns.Class

-- Services/MinimapIcon.lua
-- A standalone minimap button (NOT LibDBIcon — no external libraries). A round
-- icon pinned to the minimap edge at a saved angle and draggable around the rim.
-- Default OFF. Left-click toggles the settings window; right-click opens the log.

local MinimapIcon = Class.new("MinimapIcon", ns.Service)

local DEFAULT_ANGLE = 225   -- degrees, measured from the minimap centre

-- The Dashboard module IFF it's enabled. When it is, LEFT-click opens it and settings move to
-- MIDDLE-click; when it's off, the icon keeps the default LEFT-click = settings (and middle does
-- nothing). Resolved lazily so the icon never hard-depends on the optional module.
-- hag-lint-disable depcheck: Dashboard
local function activeDashboard()
    local m = ns.ModuleManager and ns.ModuleManager:GetModule("Dashboard")
    return (m and m:IsEnabled()) and m or nil
end

function MinimapIcon:OnInitialize()
    ns.EventBus:On("PLAYER_LOGIN", function() self:Refresh() end)  -- self-apply on login
    -- Our General-page toggle is declared on registration (see below) and contributed
    -- by the Service base -- a push (icons -> window) with no cycle.
end

-- The single config row (account-wide), or nil before the database is built.
function MinimapIcon:_Row()
    local db = self:DB(); if not db then return nil end
    return db:Select("shown", "angle"):From("minimap"):Where("id", "=", 1):Limit(1):Run()[1]
end

-- Upsert the singleton row, merging `changes`.
function MinimapIcon:_Set(changes)
    local db = self:DB(); if not db then return end
    if self:_Row() then db:Update("minimap", changes, function(x) return x.id == 1 end)
    else changes.id = 1; db:Insert("minimap", changes) end
end

function MinimapIcon:IsShown()
    local r = self:_Row()
    return r and r.shown == true or false
end

-- The current rim angle: the in-progress drag value (cached) wins, else the saved one, else default.
function MinimapIcon:_Angle()
    local p = self:_p()
    if p.angle then return p.angle end
    local r = self:_Row()
    return (r and r.angle and not ns.DB.isNull(r.angle)) and r.angle or DEFAULT_ANGLE
end

-- Place the button on the minimap rim at the current angle.
function MinimapIcon:_Reposition()
    local p = self:_p()
    if not (p.button and Minimap) then return end
    local r = (Minimap:GetWidth() / 2) + 5
    local x, y = ns.Vector2D.OnRing(r, self:_Angle())
    p.button:ClearAllPoints()
    p.button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

function MinimapIcon:_Build()
    local p = self:_p()
    if p.button or not Minimap then return end

    local b = CreateFrame("Button", nil, Minimap)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:SetSize(31, 31)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
    b:RegisterForDrag("LeftButton")

    -- round icon (square art clipped by a circular mask)
    local icon = b:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture(ns.Meta.ICON)
    icon:SetSize(19, 19)
    icon:SetPoint("TOPLEFT", 6, -6)
    local mask = b:CreateMaskTexture()
    mask:SetAllPoints(icon)
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
        "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    icon:AddMaskTexture(mask)

    -- the standard minimap-button ring on top
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- drag around the rim (angle is cached in memory during the drag, persisted once on release)
    b:SetScript("OnDragStart", function() b:SetScript("OnUpdate", function() self:_DragUpdate() end) end)
    b:SetScript("OnDragStop",  function()
        b:SetScript("OnUpdate", nil)
        if self:_p().angle then self:_Set({ angle = self:_p().angle }) end
    end)

    b:SetScript("OnClick", function(_, btn) self:_OnClick(btn) end)
    b:SetScript("OnEnter", function() self:_OnEnter(b) end)
    b:SetScript("OnLeave", function() ns.UI.Widgets.Tooltip:Hide() end)

    p.button = b
    self:_Reposition()
end

function MinimapIcon:_DragUpdate()
    if not Minimap then return end
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local px, py = GetCursorPosition()
    px, py = px / scale, py / scale
    self:_p().angle = ns.Vector2D.AngleOf(px - mx, py - my)   -- cached; persisted on drag stop
    self:_Reposition()
end

function MinimapIcon:_OnClick(btn)
    if btn == "RightButton" then
        ns.ModuleManager:OpenContextMenu(self:_p().button)
    elseif btn == "MiddleButton" then
        if activeDashboard() then ns.UI.SettingsWindow:Toggle() end  -- settings only while Dashboard owns left-click
    else  -- LeftButton: Dashboard if it's on, otherwise settings
        local m = activeDashboard()
        if m then m:Toggle() else ns.UI.SettingsWindow:Toggle() end
    end
end

function MinimapIcon:_OnEnter(b)
    local lines = {}
    if activeDashboard() then
        lines[#lines + 1] = { text = "Left-click: Dashboard", key = "text" }
        lines[#lines + 1] = { text = "Middle-click: open settings" }
    else
        lines[#lines + 1] = { text = "Left-click: open settings", key = "text" }
    end
    lines[#lines + 1] = { text = "Right-click: enable/disable modules" }
    lines[#lines + 1] = { text = "Drag: move around the minimap" }
    ns.UI.Widgets.Tooltip:Show(b, lines)
end

-- Show/hide per the saved setting (builds lazily on first show).
function MinimapIcon:Refresh()
    local p = self:_p()
    if self:IsShown() then
        self:_Build()
        if p.button then p.button:Show() end
    elseif p.button then
        p.button:Hide()
    end
end

function MinimapIcon:SetShown(on)
    self:_Set({ shown = on and true or false })
    self:Refresh()
end

ns.ServiceManager:Register(MinimapIcon:New("MinimapIcon", {
    deps = { "EventBus", "SettingsWindow" },
    tables = { minimap = { scope = "global", columns = {
        { name = "id",    type = "integer", primaryKey = true },   -- singleton row (id = 1)
        { name = "shown", type = "boolean" },
        { name = "angle", type = "number" },
    } } },
    generalToggles = {
        {
            section = "Icons",
            label = "Minimap icon",
            desc = "Adds a draggable button on the minimap edge.",
            get = "IsShown",
            set = "SetShown",
        },
    },
}))
