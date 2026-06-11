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
    local content = sf:Content()                     -- the framework's scroll area; we just fill it
    local width = content:GetWidth()
    if not width or width < 1 then width = 420 end

    local dash = ns.ModuleManager:GetModule("Dashboard")

    local intro = W.Text:New(content,
        "Live-tune the Dashboard scene art. Values are per session and reset to the code defaults on reload.",
        "textDim", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", 4, -2)
    intro:SetWidth(width - 12); intro:SetJustifyH("LEFT")

    local groups = {}
    -- Position the groups top-to-bottom from their CURRENT heights (so collapsing one reflows the rest)
    -- and size the scroll child to fit. Run on build and on every group's collapse toggle.
    local function relayout()
        local y = -(intro:GetStringHeight() + 14)
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
        local g = W.SettingsGroup:New(content, title)
        local gc = g:GetContent()
        local sliderW = (width - 20) - 4                 -- group content (PAD 10 each side) minus a hair
        local tune = dash and dash:GetArtTune(kind)

        local sy = 0
        for _, r in ipairs(ROWS) do
            local s = W.Slider:New(gc, { label = r.label, min = r.min, max = r.max, step = r.step, width = sliderW })
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
        local btn = W.Button:New(gc, "Next dungeon image  >")
        btn:SetPoint("TOPLEFT", gc, "TOPLEFT", 0, sy)
        local nameFS = W.Text:New(gc, "", "accent", "GameFontHighlightSmall")
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
        local g = W.SettingsGroup:New(content, "Advanced Quest Info")
        local gc = g:GetContent()
        local s = W.Slider:New(gc, { label = "Banner Y", min = -60, max = 10, step = 1, width = (width - 20) - 4 })
        s:SetPoint("TOPLEFT", gc, "TOPLEFT", 0, 0)
        s:SetValue(quest:GetBannerY())
        s:SetOnChange(function(v) quest:SetBannerY(v) end)
        g:SetContentHeight(ROW_H - 6)
        g:SetOnToggle(function() relayout() end)
        groups[#groups + 1] = g
    end

    relayout()
end

-- The "Debug" General-page toggle: surfaces DEBUG log lines in chat. The state is persisted
-- PER CHARACTER (the module's own settings store) and applied to the Logger's runtime flag --
-- the flag itself stays session-only, the Dev module just remembers your choice and re-applies
-- it. Default ON. Because the Dev module exists ONLY on a whitelisted dev character, this toggle
-- (its generalToggle) only ever shows up there.
function Dev:_DebugOn()
    local on = self:GetSetting("debug")
    if on == nil then on = true end
    return on
end
function Dev:_GetDebug() return self:_DebugOn() end
function Dev:_SetDebug(on)
    self:SetSetting("debug", on and true or false)
    ns.Logger:SetDebug(on)
end
function Dev:OnInitialize()
    ns.Logger:SetDebug(self:_DebugOn())  -- apply the saved (default-on) choice for this character
end

-- ---- hitch watchdog ---------------------------------------------------------------------------
-- For the first WATCH_SECS after enable, measure EVERY frame (a 0-interval ticker fires once per
-- frame) and keep the slow ones -- each with the Worker's share of that frame (ns.Worker:
-- FramePumpMs) and the Lua allocation delta across it -- then log ONE report and stop. This splits
-- "our deferred work is stalling frames" from "something else is" (allocation/GC churn shows as big
-- KB deltas; asset streaming / other addons show as slow frames with a tiny worker share).
local WATCH_SECS = 30          -- observation window after module enable
local WATCH_TOP  = 10          -- worst frames to report
local HITCH_MS   = 25          -- a frame slower than this (40 FPS) counts as a hitch

function Dev:OnEnable()
    self:_StartHitchWatch()
end

-- ---- MemWatch: leak vs. GC churn ----------------------------------------------------------------
-- The addon-list memory number climbs CONTINUOUSLY between GC cycles by design (it counts garbage
-- not yet collected), so "it keeps growing" alone never proves a leak. MemWatch measures the only
-- number that does: every MEM_INTERVAL it forces a FULL collection and samples what survives -- the
-- retained baseline. A leak = the baseline climbing sample after sample; a flat baseline = normal
-- churn. Dev-character tool (the forced collect costs a frame); toggle with /hag mem.
local MEM_INTERVAL = 60   -- seconds between samples

function Dev:ToggleMemWatch()
    local p = self:_p()
    if p.mem then
        if not p.mem.ticker:IsCancelled() then p.mem.ticker:Cancel() end
        p.mem = nil
        self:LogWarn("MemWatch off")
        return
    end
    p.mem = {}
    p.mem.ticker = self:Every(MEM_INTERVAL, function() self:_MemSample() end)
    self:LogWarn(("MemWatch on: forced-GC retained sample every %ds (expect a brief hitch per sample)")
        :format(MEM_INTERVAL))
    self:_MemSample()
end

function Dev:_MemSample()
    local m = self:_p().mem
    if not m then return end
    collectgarbage("collect")                 -- settle the heap: whatever remains is RETAINED
    local heapKb = collectgarbage("count")
    local ourKb
    if UpdateAddOnMemoryUsage and GetAddOnMemoryUsage then
        UpdateAddOnMemoryUsage()
        ourKb = GetAddOnMemoryUsage(addonName)
    end
    local dOur  = (ourKb and m.ourKb) and (ourKb - m.ourKb) or 0
    local dHeap = m.heapKb and (heapKb - m.heapKb) or 0
    self:LogWarn(("MemWatch: retained %s MB HagAIO (%+.0f KB), %.1f MB total Lua (%+.0f KB)")
        :format(ourKb and ("%.2f"):format(ourKb / 1024) or "?", dOur, heapKb / 1024, dHeap))
    m.ourKb, m.heapKb = ourKb, heapKb
end

function Dev:_StartHitchWatch()
    local p = self:_p()
    if p.watch then return end
    if ResetCPUUsage and GetCVar and GetCVar("scriptProfile") == "1" then ResetCPUUsage() end
    p.watch = { worst = {}, frames = 0, t0 = GetTime(), last = GetTime(),
                kb = collectgarbage("count"), kbTotal = 0, mem0 = self:_AddonMemSnapshot() }
    p.watch.ticker = self:Every(0, function() self:_HitchFrame() end)
end

-- Per-addon RETAINED Lua memory (KB by addon index). UpdateAddOnMemoryUsage is expensive, so this
-- runs exactly twice: at watch start and at report. Retained-memory growth names which addon is
-- building big structures during startup; pure churn (allocated then collected) won't show here --
-- that needs scriptProfile CPU attribution (reported too, when the CVar is on).
function Dev:_AddonMemSnapshot()
    if not (UpdateAddOnMemoryUsage and GetAddOnMemoryUsage) then return nil end
    local num = (C_AddOns and C_AddOns.GetNumAddOns and C_AddOns.GetNumAddOns())
        or (GetNumAddOns and GetNumAddOns()) or 0
    if num == 0 then return nil end
    UpdateAddOnMemoryUsage()
    local snap = {}
    for i = 1, num do snap[i] = GetAddOnMemoryUsage(i) or 0 end
    return snap
end

local function addonName(i)
    local name = C_AddOns and C_AddOns.GetAddOnInfo and C_AddOns.GetAddOnInfo(i)
    return tostring(name or ("addon #" .. i))
end

function Dev:_HitchFrame()
    local w = self:_p().watch
    if not w then return end
    local now = GetTime()
    local kb = collectgarbage("count")
    local dt = (now - w.last) * 1000          -- duration of the frame that just ended
    local dkb = kb - w.kb                     -- alloc (+) / collection (-) across that frame
    w.frames = w.frames + 1
    if dkb > 0 then w.kbTotal = w.kbTotal + dkb end
    if dt >= HITCH_MS and w.frames > 1 then   -- frame 1 has no real dt yet
        local worker = (ns.Worker and ns.Worker.FramePumpMs) and ns.Worker:FramePumpMs(w.last) or 0
        w.worst[#w.worst + 1] = { ms = dt, at = w.last - w.t0, worker = worker, kb = dkb }
    end
    w.last, w.kb = now, kb
    if now - w.t0 >= WATCH_SECS then self:_ReportHitches() end
end

function Dev:_ReportHitches()
    local p = self:_p()
    local w = p.watch
    if not w then return end
    if w.ticker and not w.ticker:IsCancelled() then w.ticker:Cancel() end
    p.watch = nil
    local secs = GetTime() - w.t0
    self:LogWarn(("HitchWatch: %d frames in %.0fs (avg %.0f fps), %.1f MB Lua allocated. Frames over %dms: %d")
        :format(w.frames, secs, w.frames / secs, w.kbTotal / 1024, HITCH_MS, #w.worst))
    table.sort(w.worst, function(a, b) return a.ms > b.ms end)
    for i = 1, math.min(WATCH_TOP, #w.worst) do
        local e = w.worst[i]
        self:LogWarn(("  %2d. %6.1f ms at +%4.1fs  (worker %5.2f ms, %s%.0f KB)")
            :format(i, e.ms, e.at, e.worker, e.kb >= 0 and "+" or "", e.kb))
    end
    self:_ReportAddonShares(w.mem0)
end

-- Attribution: which ADDON grew its retained Lua memory over the watch window (top 8), and -- when
-- the scriptProfile CVar is on -- which addon burned the most CPU. Without scriptProfile only the
-- memory view exists; churn-heavy addons need the CPU view, so hint at it once.
function Dev:_ReportAddonShares(mem0)
    local mem1 = self:_AddonMemSnapshot()
    if mem0 and mem1 then
        local deltas = {}
        for i = 1, #mem1 do
            local d = mem1[i] - (mem0[i] or 0)
            if d > 256 then deltas[#deltas + 1] = { i = i, d = d } end   -- ignore < 256 KB noise
        end
        table.sort(deltas, function(a, b) return a.d > b.d end)
        if #deltas > 0 then
            self:LogWarn("  Retained Lua memory growth by addon:")
            for k = 1, math.min(8, #deltas) do
                local e = deltas[k]
                self:LogWarn(("    +%7.1f MB  %s"):format(e.d / 1024, addonName(e.i)))
            end
        end
    end
    if GetCVar and GetCVar("scriptProfile") == "1" and UpdateAddOnCPUUsage and GetAddOnCPUUsage then
        UpdateAddOnCPUUsage()
        local num = (C_AddOns and C_AddOns.GetNumAddOns and C_AddOns.GetNumAddOns())
            or (GetNumAddOns and GetNumAddOns()) or 0
        local cpu = {}
        for i = 1, num do
            local ms = GetAddOnCPUUsage(i) or 0
            if ms > 10 then cpu[#cpu + 1] = { i = i, ms = ms } end
        end
        table.sort(cpu, function(a, b) return a.ms > b.ms end)
        if #cpu > 0 then
            self:LogWarn("  Addon CPU since watch start (scriptProfile):")
            for k = 1, math.min(8, #cpu) do
                self:LogWarn(("    %8.0f ms  %s"):format(cpu[k].ms, addonName(cpu[k].i)))
            end
        end
    else
        self:LogWarn("  (for per-addon CPU attribution: /console scriptProfile 1 + reload; set it back to 0 after)")
    end
end

-- Registered (always-on) ONLY on a whitelisted dev character. The `not ns.IsDevChar` arm keeps the
-- headless test harness -- which doesn't load Core/Namespace.lua -- able to load this file.
if (not ns.IsDevChar) or ns.IsDevChar() then
    ns.ModuleManager:Register(Dev:New("Dev", {
        title = "Dev",
        description = "Developer tooling for this character. Live-tunes the Dashboard scene art.",
        alwaysOn = true,
        color = ns.Theme.hex.red,
        deps = { "SettingsWindow", "Worker", "SlashCommand" },  -- General-page toggle; HitchWatch; /hag mem
        commands = {
            mem = { handler = "ToggleMemWatch", help = "toggle the memory watch (one sample per minute)" },
        },
        settings = { { type = "toggle", key = "debug", label = "Debug", default = true } },  -- per-char; seeds default ON
        generalToggles = {
            { section = "Developer", label = "Debug", desc = "Show debug messages in chat.",
              get = "_GetDebug", set = "_SetDebug", visibleDeps = { "Dev" } },  -- only with the Dev service
        },
    }))
end
