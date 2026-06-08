local addonName, ns = ...
local Class = ns.Class
local W = ns.UI.Widgets

-- Modules/Dev.lua
-- Developer settings module. ALWAYS ON (mandatory, no enable toggle) and registered ONLY on a
-- whitelisted developer character (ns.IsDevChar) -- normal users never see it.
--
-- For now it live-tunes the Dashboard's scene art: a Zoom slider and X/Y offset sliders, separately
-- for Dungeon and Raid tiles. The values are PER SESSION -- they drive Dashboard:SetArtTune (which
-- re-renders immediately) but are NOT saved; every reload they re-seed from the code defaults
-- (the EJ_BG_* constants in Dashboard). Find good numbers here, then bake them into the constants.

local Dev = Class.new("Dev", ns.Module)

-- The tunable rows shown in each group, mapped to Dashboard art-tune fields.
local ROWS = {
    { field = "zoom", label = "Zoom",     min = 0.20, max = 2.00, step = 0.01 },
    { field = "panX", label = "Offset X", min = -0.50, max = 0.50, step = 0.01 },
    { field = "panY", label = "Offset Y", min = -0.50, max = 0.50, step = 0.01 },
}
local ROW_H, GROUP_GAP = 40, 14

-- Custom settings page (the shared schema renderer has no slider/group controls -- see SettingsWindow).
function Dev:BuildSettingsPage(sf)
    local content = sf.content
    local width = sf:GetWidth()
    if not width or width < 1 then width = 420 end
    content:SetWidth(width)

    local dash = ns.ModuleManager:GetModule("Dashboard")

    local intro = W.Text(content,
        "Live-tune the Dashboard scene art. Values are per session and reset to the code defaults on reload.",
        "textDim", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", 4, -2)
    intro:SetWidth(width - 12); intro:SetJustifyH("LEFT")
    local y = -(intro:GetStringHeight() + 14)

    -- One titled group (Dungeon / Raid) of the three sliders, anchored at the running y.
    local function buildGroup(kind, title)
        local g = W.SettingsGroup(content, title)
        g:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
        g:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, y)
        local gc = g:GetContent()
        local sliderW = (width - 20) - 4                 -- group content (PAD 10 each side) minus a hair
        local tune = dash and dash:GetArtTune(kind)

        local sy = 0
        for _, r in ipairs(ROWS) do
            local s = W.Slider(gc, { label = r.label, min = r.min, max = r.max, step = r.step, width = sliderW })
            s:SetPoint("TOPLEFT", gc, "TOPLEFT", 0, sy)
            s:SetValue(tune and tune[r.field] or r.min)
            s:SetOnChange(function(v) if dash then dash:SetArtTune(kind, r.field, v) end end)
            sy = sy - ROW_H
        end
        g:SetContentHeight(-sy - 6)                      -- rows height (drop the trailing gap)
        y = y - (g:GetHeight() + GROUP_GAP)
    end

    buildGroup("dungeon", "Dungeon")
    buildGroup("raid", "Raid")

    content:SetHeight(math.max(30, -y + 8))
end

-- Registered (always-on) ONLY on a whitelisted dev character. The `not ns.IsDevChar` arm keeps the
-- headless test harness -- which doesn't load Core/Namespace.lua -- able to load this file.
if (not ns.IsDevChar) or ns.IsDevChar() then
    ns.ModuleManager:Register(Dev:New("Dev", {
        title = "Dev",
        description = "Developer tooling for this character. Live-tunes the Dashboard scene art.",
        alwaysOn = true,
        color = ns.Theme.hex.red,
    }))
end
