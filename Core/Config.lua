local addonName, ns = ...
local Class = ns.Class

-- Core/Config.lua
-- Singleton options panel, registered through the modern Settings API
-- (Settings.RegisterCanvasLayoutCategory). The panel renders a live, toggleable
-- list of registered feature modules; with the core-only build it simply shows
-- an empty state until modules are added.

local Config = Class.new("Config")
local instance

function Config:Initialize()
    local p = self:_p()
    p.built = false
    p.panel = nil
    p.category = nil
    p.rows = {}        -- transient widgets rebuilt on each Refresh
end

function Config:Build()
    local p = self:_p()
    if p.built then return end

    local panel = CreateFrame("Frame")
    panel.name = "HagAIO"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("HagAIO")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    subtitle:SetText(("All-in-One toolkit  |cff888888v%s|r"):format(tostring(ns.version)))

    local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hint:SetPoint("BOTTOMLEFT", 16, 16)
    hint:SetText("Type |cff33ff99/hag|r for commands.")

    p.panel = panel
    p.anchor = subtitle

    local category = Settings.RegisterCanvasLayoutCategory(panel, "HagAIO")
    Settings.RegisterAddOnCategory(category)
    p.category = category

    panel:SetScript("OnShow", function() self:Refresh() end)
    p.built = true
end

-- Rebuild the module list. Cheap and only runs while the panel is visible.
function Config:Refresh()
    local p = self:_p()
    if not p.panel then return end

    for _, widget in ipairs(p.rows) do widget:Hide() end
    wipe(p.rows)

    local mm = ns.ModuleManager.Get()
    if mm:Count() == 0 then
        local empty = p.panel:CreateFontString(nil, "ARTWORK", "GameFontDisable")
        empty:SetPoint("TOPLEFT", p.anchor, "BOTTOMLEFT", 0, -18)
        empty:SetText("No feature modules registered yet.")
        p.rows[#p.rows + 1] = empty
        return
    end

    local anchor = p.anchor
    for module in mm:Iterate() do
        local cb = CreateFrame("CheckButton", nil, p.panel, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -12)
        cb:SetChecked(module:IsEnabled())
        cb:SetScript("OnClick", function(btn)
            if btn:GetChecked() then module:Enable() else module:Disable() end
        end)

        local label = p.panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        label:SetText(module:GetTitle())

        p.rows[#p.rows + 1] = cb
        p.rows[#p.rows + 1] = label
        anchor = cb
    end
end

function Config:Open()
    self:Build()
    local p = self:_p()
    if Settings and Settings.OpenToCategory and p.category then
        Settings.OpenToCategory(p.category:GetID())
    end
end

function Config.Get()
    if not instance then instance = Config:New() end
    return instance
end

ns.Config = Config
