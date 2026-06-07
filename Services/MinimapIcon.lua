local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme

-- Services/MinimapIcon.lua
-- A standalone minimap button (NOT LibDBIcon — no external libraries). A round
-- icon pinned to the minimap edge at a saved angle and draggable around the rim.
-- Default OFF. Left-click toggles the settings window; right-click opens the log.

local MinimapIcon = Class.new("MinimapIcon", ns.Service)

local DEFAULT_ANGLE = 225   -- degrees, measured from the minimap centre

function MinimapIcon:OnInitialize()
    ns.EventBus:On("PLAYER_LOGIN", function() self:Refresh() end)  -- self-apply on login
    -- Our General-page toggle is declared on registration (see below) and contributed
    -- by the Service base -- a push (icons -> window) with no cycle.
end

function MinimapIcon:_Store()
    return ns.SavedVars:Namespace("minimap", { shown = false, angle = DEFAULT_ANGLE })
end

function MinimapIcon:IsShown()
    return self:_Store().shown == true
end

-- Place the button on the minimap rim at the saved angle.
function MinimapIcon:_Reposition()
    local p = self:_p()
    if not (p.button and Minimap) then return end
    local rad = math.rad(self:_Store().angle or DEFAULT_ANGLE)
    local r = (Minimap:GetWidth() / 2) + 5
    p.button:ClearAllPoints()
    p.button:SetPoint("CENTER", Minimap, "CENTER", r * math.cos(rad), r * math.sin(rad))
end

function MinimapIcon:_Build()
    local p = self:_p()
    if p.button or not Minimap then return end

    local b = CreateFrame("Button", nil, Minimap)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:SetSize(31, 31)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")

    -- round icon (square art clipped by a circular mask)
    local icon = b:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture(ns.ICON)
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

    -- drag around the rim
    b:SetScript("OnDragStart", function() b:SetScript("OnUpdate", function() self:_DragUpdate() end) end)
    b:SetScript("OnDragStop",  function() b:SetScript("OnUpdate", nil) end)

    b:SetScript("OnClick", function(_, btn) self:_OnClick(btn) end)
    b:SetScript("OnEnter", function() self:_OnEnter(b) end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    p.button = b
    self:_Reposition()
end

function MinimapIcon:_DragUpdate()
    if not Minimap then return end
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local px, py = GetCursorPosition()
    px, py = px / scale, py / scale
    self:_Store().angle = math.deg(math.atan2(py - my, px - mx))
    self:_Reposition()
end

function MinimapIcon:_OnClick(btn)
    if btn == "RightButton" then
        ns.ModuleManager:OpenContextMenu(self:_p().button)
    else
        ns.UI.SettingsWindow:Toggle()
    end
end

function MinimapIcon:_OnEnter(b)
    GameTooltip:SetOwner(b, "ANCHOR_LEFT")
    GameTooltip:AddLine(Theme.Colorize("accent", "HagAIO"))
    GameTooltip:AddLine("Left-click: open settings", 0.85, 0.87, 0.91)
    GameTooltip:AddLine("Right-click: enable/disable modules", 0.55, 0.58, 0.64)
    GameTooltip:AddLine("Drag: move around the minimap", 0.55, 0.58, 0.64)
    GameTooltip:Show()
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
    self:_Store().shown = on and true or false
    self:Refresh()
end

ns.ServiceManager:Register(MinimapIcon:New("MinimapIcon", {
    deps = { "EventBus", "SavedVars", "SettingsWindow" },
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
