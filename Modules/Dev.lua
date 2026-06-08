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
-- (the EJ_LORE_* constants in Dashboard). Find good numbers here, then bake them into the constants.

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
    local content = sf.content                     -- the framework's scroll area; we just fill it
    local width = content:GetWidth()
    if not width or width < 1 then width = 420 end

    local dash = ns.ModuleManager:GetModule("Dashboard")

    -- Live icon hold-count: lets us watch the TextureService pool be reused. Healthy reuse = `owned`
    -- plateaus while grids/pages re-render; `idle` rises as tiles are released, `in use` tracks what's
    -- on screen, `originals` falls once nothing references a source image. Ticks while the page shows.
    local stat = W.Text(content, "", "textFaint", "GameFontHighlightSmall")
    stat:SetPoint("TOPLEFT", 4, -2)
    local acc = 0
    content:SetScript("OnUpdate", function(_, dt)
        acc = acc + (dt or 0)
        if acc < 0.5 then return end
        acc = 0
        if ns.TextureService and ns.TextureService.Stats then
            local s = ns.TextureService:Stats()
            stat:SetText(("Icons  owned %d  \194\183  idle %d  \194\183  in use %d  \194\183  originals %d")
                :format(s.owned, s.idle, s.inUse, s.originals))
        end
    end)

    local intro = W.Text(content,
        "Live-tune the Dashboard scene art. Values are per session and reset to the code defaults on reload.",
        "textDim", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", stat, "BOTTOMLEFT", 0, -8)
    intro:SetWidth(width - 12); intro:SetJustifyH("LEFT")

    local groups = {}
    -- Position the groups top-to-bottom from their CURRENT heights (so collapsing one reflows the rest)
    -- and size the scroll child to fit. Run on build and on every group's collapse toggle.
    local function relayout()
        local y = -(stat:GetStringHeight() + 8 + intro:GetStringHeight() + 14)
        for _, g in ipairs(groups) do
            g:ClearAllPoints()
            g:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
            g:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, y)
            y = y - (g:GetHeight() + GROUP_GAP)
        end
        content:SetHeight(math.max(30, -y + 8))
    end

    -- A collapsible group (Dungeon / Raid) of the three sliders. `extra(gc, sy)` (optional) adds
    -- controls under the sliders and returns the new running sy.
    local function buildGroup(kind, title, extra)
        local g = W.SettingsGroup(content, title)
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
        if extra then sy = extra(gc, sy) end
        g:SetContentHeight(-sy - 6)                      -- rows height (drop the trailing gap)
        g:SetOnToggle(function() relayout() end)         -- reflow + resize when collapsed/expanded
        groups[#groups + 1] = g
    end

    -- Dungeon group gets a "next image" stepper: the Current Season tile cycles through every season
    -- dungeon's splash so each can be inspected (and tuned) in turn. The label shows which is showing.
    buildGroup("dungeon", "Dungeon", function(gc, sy)
        local btn = W.Button(gc, "Next dungeon image  >")
        btn:SetPoint("TOPLEFT", gc, "TOPLEFT", 0, sy)
        local nameFS = W.Text(gc, "", "accent", "GameFontHighlightSmall")
        nameFS:SetPoint("LEFT", btn, "RIGHT", 12, 0)
        nameFS:SetPoint("RIGHT", gc, "RIGHT", 0, 0); nameFS:SetJustifyH("LEFT"); nameFS:SetWordWrap(false)
        local function refresh() nameFS:SetText((dash and dash:CurrentSeasonDungeon()) or "open the Dashboard's Dungeons view") end
        refresh()
        btn:SetOnClick(function() if dash then dash:NextSeasonDungeon() end; refresh() end)
        return sy - 32
    end)
    buildGroup("raid", "Raid")

    -- Advanced Quest Info: live-tune the timed-quest banner's vertical position on the quest
    -- window (per session -- bake the chosen value into Questing's BANNER_Y once it looks right).
    local quest = ns.ModuleManager:GetModule("Questing")
    if quest and quest.SetBannerY then
        local g = W.SettingsGroup(content, "Advanced Quest Info")
        local gc = g:GetContent()
        local s = W.Slider(gc, { label = "Banner Y", min = -60, max = 10, step = 1, width = (width - 20) - 4 })
        s:SetPoint("TOPLEFT", gc, "TOPLEFT", 0, 0)
        s:SetValue(quest:GetBannerY())
        s:SetOnChange(function(v) quest:SetBannerY(v) end)
        g:SetContentHeight(ROW_H - 6)
        g:SetOnToggle(function() relayout() end)
        groups[#groups + 1] = g
    end

    relayout()
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
