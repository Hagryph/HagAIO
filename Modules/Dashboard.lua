local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme
local W = ns.UI.Widgets
local Ledger = ns.ResetLedger
local clock = ns.Format.Clock   -- "3h 04m" duration formatter (Lib/Format.lua)

-- Modules/Dashboard.lua
-- Account-wide, cross-character RESET dashboard. Every character snapshots its own reset-timer
-- state (Great Vault, M+ keystone + rating, raid/dungeon lockouts, weekly/daily quest turn-ins,
-- item level) into a shared account-wide saved table keyed by "Name-Realm"; a themed window
-- with a LEFT CATEGORY TREE + a character header then shows ALL characters as rows, the selected
-- category's items as columns. No addon-to-addon comms (cross-character state travels purely via
-- SavedVariables), so the 12.0 encounter comms throttle never applies. Secret Great-Vault
-- progress (M+/raid) is read through ns.Secrets and stored only when non-secret.
--
-- Pure shaping (store key, reset-rollover, progress/keystone formatting) lives in the unit-tested
-- ns.ResetLedger (Lib/ResetLedger.lua). Data approach (verified by reading SavedInstances /
-- AlterEgo / Altoholic source): lockouts come dynamically from GetSavedInstanceInfo (every
-- instance the character is locked to, incl. legacy raids), and weekly/daily quests are RECORDED
-- as they're turned in (QUEST_TURNED_IN) and classified by frequency -- no curated ID tables.

local Dashboard = Class.new("Dashboard", ns.Module)

local RAIL_W = 178            -- left category-tree / character-header rail
local AVATAR = 46            -- character portrait size

-- ===========================================================================
-- Category descriptors. Each yields the COLUMNS for the selected dataset; a column's cell(entry)
-- is PURE (reads only a stored snapshot) so it renders the current character and every alt the
-- same way. `indent` draws it as a sub-item in the tree.
-- ===========================================================================
local function vaultDone(e)
    local v = e.vault
    if not (v and v.slots and #v.slots > 0) then return "-" end
    local done = 0
    for _, s in ipairs(v.slots) do
        local _, isDone = Ledger:Progress(s.progress, s.threshold)
        if isDone then done = done + 1 end
    end
    return done .. "/" .. #v.slots
end

-- A lockout column-set built from the union of every character's saved instances matching
-- `predicate(lockout)`; each cell shows that character's boss progress for the instance.
local function lockoutColumns(chars, predicate)
    local seen, cols = {}, {}
    for _, e in pairs(chars) do
        for _, lk in ipairs(e.lockouts or {}) do
            local key = lk.name .. "|" .. (lk.diff or "")
            if predicate(lk) and not seen[key] then
                seen[key] = true
                local name, diff = lk.name, lk.diff
                cols[#cols + 1] = { label = diff and (name .. " (" .. diff .. ")") or name,
                    width = 110, cell = function(entry)
                        for _, l in ipairs(entry.lockouts or {}) do
                            if l.name == name and l.diff == diff then
                                return (l.progress or 0) .. "/" .. (l.total or "?")
                            end
                        end
                        return "-"
                    end }
            end
        end
    end
    table.sort(cols, function(a, b) return a.label < b.label end)
    return cols
end

-- A quest column-set from the union of recorded weekly/daily turn-ins of the given `freq`.
local function questColumns(chars, freq)
    local seen, cols = {}, {}
    for _, e in pairs(chars) do
        local recorded = e.quests and e.quests[freq]
        if recorded then
            for id, title in pairs(recorded) do
                if not seen[id] then
                    seen[id] = true
                    local qid = id
                    cols[#cols + 1] = { label = title or ("Quest " .. id), width = 120, cell = function(entry)
                        local r = entry.quests and entry.quests[freq]
                        return (r and r[qid]) and "done" or "-"
                    end }
                end
            end
        end
    end
    table.sort(cols, function(a, b) return a.label < b.label end)
    return cols
end

local CATEGORIES = {
    { key = "mplus", label = "Mythic+", columns = function()
        return {
            { label = "Keystone", width = 150, cell = function(e)
                local k = e.keystone; return Ledger:KeystoneText(k and k.name, k and k.level) end },
            { label = "Rating", width = 64, cell = function(e) return e.rating and tostring(e.rating) or "-" end },
            { label = "Vault",  width = 64, cell = vaultDone },
        }
    end },
    { key = "lockouts", label = "Lockouts", header = true },
    { key = "raids",    label = "Raids",    indent = true,
      columns = function(chars) return lockoutColumns(chars, function(lk) return lk.isRaid end) end },
    { key = "dungeons", label = "Dungeons", indent = true,
      columns = function(chars) return lockoutColumns(chars, function(lk) return not lk.isRaid end) end },
    { key = "weekly", label = "Weekly Quests",
      columns = function(chars) return questColumns(chars, "weekly") end },
    { key = "daily",  label = "Daily Quests",
      columns = function(chars) return questColumns(chars, "daily") end },
}

-- ---- lifecycle ------------------------------------------------------------
function Dashboard:OnInitialize()
    local p = self:_p()
    p.built = false
    p.shown = false
    p.category = "mplus"
end

function Dashboard:OnEnable()
    -- Targeted collectors keep each fire cheap (the never-debounce rule): a bag update only
    -- re-reads the keystone, a quest turn-in only records that quest.
    self:On("PLAYER_ENTERING_WORLD",      function() self:_Snapshot() end)
    self:On("PLAYER_LOGOUT",              function() self:_Snapshot() end)
    self:On("WEEKLY_REWARDS_UPDATE",      function() self:_CollectVault();    self:_RenderIfShown() end)
    self:On("CHALLENGE_MODE_COMPLETED",   function() self:_CollectKeystone(); self:_RenderIfShown() end)
    self:On("CHALLENGE_MODE_MAPS_UPDATE", function() self:_CollectKeystone(); self:_RenderIfShown() end)
    self:On("BAG_UPDATE_DELAYED",         function() self:_CollectKeystone(); self:_RenderIfShown() end)
    self:On("UPDATE_INSTANCE_INFO",       function() self:_CollectLockouts(); self:_RenderIfShown() end)
    self:On("BOSS_KILL",                  function() self:_CollectLockouts() end)
    self:On("QUEST_TURNED_IN",            function(_, questID) self:_RecordQuest(questID) end)
    self:_Snapshot()
    if RequestRaidInfo then RequestRaidInfo() end   -- async -> UPDATE_INSTANCE_INFO fills lockouts
end

-- A settings change (a category toggled on/off) re-renders so the nav tree reflects it.
function Dashboard:OnSettingChanged()
    self:_RenderIfShown()
end

function Dashboard:OnDisable()
    self:Hide()
end

-- ---- account-wide store ---------------------------------------------------
function Dashboard:_Chars()
    return ns.SavedVars:Namespace("dashboard", { chars = {} }).chars
end

function Dashboard:_SelfKey()
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
    return Ledger:CharKey(UnitName("player"), realm)
end

function Dashboard:_SelfEntry()
    local chars = self:_Chars()
    local key = self:_SelfKey()
    local e = chars[key]
    if not e then e = {}; chars[key] = e end
    e.lastSeen = (GetServerTime and GetServerTime()) or time()
    return e
end

-- ---- collectors (each guarded so a missing API is a no-op, never an error) -
function Dashboard:_CollectInfo()
    local e = self:_SelfEntry()
    e.name  = UnitName("player")
    e.realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
    local _, classFile = UnitClass("player")
    e.class = classFile
    e.level = UnitLevel("player")
    if GetAverageItemLevel then
        local _, equipped = GetAverageItemLevel()
        e.ilvl = equipped and math.floor(equipped + 0.5) or e.ilvl
    end
end

function Dashboard:_CollectKeystone()
    local e = self:_SelfEntry()
    local mapID = C_MythicPlus and C_MythicPlus.GetOwnedKeystoneMapID and C_MythicPlus.GetOwnedKeystoneMapID()
    local level = C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel and C_MythicPlus.GetOwnedKeystoneLevel()
    if mapID and level and level > 0 then
        local name = C_ChallengeMode and C_ChallengeMode.GetMapUIInfo and C_ChallengeMode.GetMapUIInfo(mapID)
        e.keystone = { mapID = mapID, level = level, name = name }
    else
        e.keystone = nil
    end
    local summary = C_PlayerInfo and C_PlayerInfo.GetPlayerMythicPlusRatingSummary
        and C_PlayerInfo.GetPlayerMythicPlusRatingSummary("player")
    if summary and summary.currentSeasonScore then e.rating = summary.currentSeasonScore end
end

function Dashboard:_CollectVault()
    local e = self:_SelfEntry()
    local acts = C_WeeklyRewards and C_WeeklyRewards.GetActivities and C_WeeklyRewards.GetActivities()
    if not acts then return end
    local slots = {}
    for _, a in ipairs(acts) do
        -- progress/threshold can be secret in restricted content -- store only a plain number
        -- (ns.Secrets:Number returns nil for a secret), so a cross-char cell never computes on one.
        local prog = ns.Secrets and ns.Secrets:Number(a.progress) or a.progress
        local thr  = ns.Secrets and ns.Secrets:Number(a.threshold) or a.threshold
        slots[#slots + 1] = { type = a.type, level = a.level, progress = prog, threshold = thr }
    end
    e.vault = { slots = slots }
end

-- All saved instances the character is locked to (raids AND dungeons, every difficulty, current
-- AND legacy). GetSavedInstanceInfo returns ONLY active locks, so "which difficulty has a lockout"
-- needs no curated table -- if it's locked it's here (with its difficulty + boss count), if not it
-- isn't. We capture the difficulty name so a multi-difficulty lock (e.g. LFR + Heroic of one raid)
-- shows as separate entries.
function Dashboard:_CollectLockouts()
    local e = self:_SelfEntry()
    local n = (GetNumSavedInstances and GetNumSavedInstances()) or 0
    local locks = {}
    for i = 1, n do
        local name, _, reset, _, locked, _, _, isRaid, _, diff, numEnc, prog = GetSavedInstanceInfo(i)
        if locked and reset and reset > 0 then
            locks[#locks + 1] = { name = name, diff = diff, total = numEnc, progress = prog,
                isRaid = isRaid, reset = reset }
        end
    end
    e.lockouts = locks
end

-- Record a turned-in quest under its reset frequency (daily/weekly), so the dashboard shows
-- which alt did which recurring quest this reset. Non-recurring quests are ignored.
function Dashboard:_RecordQuest(questID)
    if not questID then return end
    local freq
    local info = C_QuestLog and C_QuestLog.GetQuestInfo  -- title fallback; frequency below
    local f = C_QuestLog and C_QuestLog.GetQuestFrequency and C_QuestLog.GetQuestFrequency(questID)
    if f == (Enum and Enum.QuestFrequency and Enum.QuestFrequency.Daily) then freq = "daily"
    elseif f == (Enum and Enum.QuestFrequency and Enum.QuestFrequency.Weekly) then freq = "weekly" end
    if not freq then return end
    local e = self:_SelfEntry()
    e.quests = e.quests or {}
    e.quests[freq] = e.quests[freq] or {}
    local title = (C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID))
        or (info and info(questID)) or ("Quest " .. questID)
    e.quests[freq][questID] = title
    self:_RenderIfShown()
end

function Dashboard:_Snapshot()
    self:_CollectInfo()
    self:_CollectKeystone()
    self:_CollectVault()
    self:_CollectLockouts()
    self:_RenderIfShown()
end

-- ---- expansion mapping (Encounter Journal) --------------------------------
-- Map a raid NAME -> its expansion by walking the Encounter Journal tiers (one tier per
-- expansion). Built lazily and cached on first success; name-matching is locale-consistent
-- within a client. A raid the journal doesn't list (or before the journal data loads) resolves
-- to "Other". The reference addons hand-curate this; we derive it dynamically instead.
function Dashboard:_ExpansionMap()
    local p = self:_p()
    if p.ejMap then return p.ejMap end
    if not (EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex and EJ_GetTierInfo) then return nil end
    if C_AddOns and C_AddOns.LoadAddOn then pcall(C_AddOns.LoadAddOn, "Blizzard_EncounterJournal") end
    local map, found = {}, false
    local prev = EJ_GetCurrentTier and EJ_GetCurrentTier()
    local function walk(tier, tierName, isRaid)
        EJ_SelectTier(tier)
        local i = 1
        while true do
            local instID, name = EJ_GetInstanceByIndex(i, isRaid)
            if not instID then break end
            if name and tierName then map[name] = tierName; found = true end
            i = i + 1
        end
    end
    for tier = 1, EJ_GetNumTiers() do
        local tierName = EJ_GetTierInfo(tier)
        walk(tier, tierName, true)    -- raids
        walk(tier, tierName, false)   -- dungeons -> same name->expansion map
    end
    if prev then pcall(EJ_SelectTier, prev) end   -- restore the journal's selected tier
    if found then
        p.ejMap = map
        p.currentExpansion = EJ_GetTierInfo(EJ_GetNumTiers())   -- newest tier = current expansion
    end
    return p.ejMap
end

-- The expansion an instance (raid OR dungeon) belongs to (cache read only; "Other" until built).
function Dashboard:_InstanceExpansion(name)
    local m = self:_p().ejMap
    return (m and m[name]) or "Other"
end

-- Distinct expansions among locked instances of one kind (raids if wantRaid, else dungeons),
-- the current expansion first then A-Z. Only expansions you actually hold a lock in appear.
function Dashboard:_SavedExpansions(wantRaid)
    local set = {}
    for _, e in pairs(self:_Chars()) do
        for _, lk in ipairs(e.lockouts or {}) do
            if (lk.isRaid and true or false) == wantRaid then
                set[self:_InstanceExpansion(lk.name)] = true
            end
        end
    end
    local list, cur = {}, self:_p().currentExpansion
    for exp in pairs(set) do list[#list + 1] = exp end
    table.sort(list, function(a, b)
        if (a == cur) ~= (b == cur) then return a == cur end
        return a < b
    end)
    return list
end

-- ===========================================================================
-- Window: left rail (avatar + char header + a 1-column nav GRID) | content (reset header +
-- title + an N-column data GRID). BOTH panels are ns.UI.Widgets.Grid instances, so the sidebar
-- items, section headers and the data columns all align through ONE layout engine -- no
-- hand-computed offsets, so headers and cells can't drift apart.
-- ===========================================================================
local NAME_COL = 150   -- the sticky character-name column (shared by the data grid)

function Dashboard:_Build()
    local p = self:_p()
    if p.built then return end

    local f = W.Window(100, { name = "HagAIODashboard", width = 860, height = 520,
        strata = "HIGH", title = "Dashboard", onClose = function() self:Hide() end,
        autoClose = true,
        onAutoShow = function() self:Show() end,
        onAutoHide = function() self:Hide() end })
    f:SetScript("OnHide", function() self:_p().shown = false end)
    p.frame = f

    -- left rail: character card + category nav grid
    local rail = W.Panel(f.body, "bg0", "border")
    rail:SetWidth(RAIL_W)
    rail:SetPoint("TOPLEFT", 0, 0)
    rail:SetPoint("BOTTOMLEFT", 0, 0)

    -- character card: avatar (portrait on the bordered frame's ARTWORK layer, above its
    -- backdrop so the fill never hides it) + name / level-ilvl / rating.
    local avFrame = CreateFrame("Frame", nil, rail, "BackdropTemplate")
    avFrame:SetSize(AVATAR, AVATAR)
    avFrame:SetPoint("TOPLEFT", 14, -14)
    W.Style(avFrame, "panel2", "borderStrong")
    local av = avFrame:CreateTexture(nil, "ARTWORK")
    av:SetPoint("TOPLEFT", 2, -2)
    av:SetPoint("BOTTOMRIGHT", -2, 2)
    av:SetTexCoord(0.08, 0.92, 0.08, 0.92)   -- trim the portrait's baked-in ring
    p.avatar = av

    local hName = W.Text(rail, "", "text", "GameFontNormal")
    hName:SetPoint("TOPLEFT", avFrame, "TOPRIGHT", 10, -1)
    hName:SetWidth(RAIL_W - AVATAR - 30); hName:SetJustifyH("LEFT"); hName:SetWordWrap(false)
    local hInfo = W.Text(rail, "", "textDim", "GameFontHighlightSmall")
    hInfo:SetPoint("TOPLEFT", hName, "BOTTOMLEFT", 0, -5)
    local hRating = W.Text(rail, "", "accent", "GameFontHighlightSmall")
    hRating:SetPoint("TOPLEFT", hInfo, "BOTTOMLEFT", 0, -3)
    p.hName, p.hInfo, p.hRating = hName, hInfo, hRating

    local div = W.Divider(rail)
    div:SetPoint("TOPLEFT", avFrame, "BOTTOMLEFT", 0, -14)
    div:SetPoint("RIGHT", rail, "RIGHT", -12, 0)

    -- the category tree is a Navigation widget; selecting a category re-renders the data grid
    local nav = W.Nav(rail, {
        items = self:_NavItems(),
        cellPad = 7,   -- 3px bar + 4px gap, so the label clears the active bar
        onSelect = function(key) p.category = key; self:_Render() end,
    })
    nav:SetPoint("TOPLEFT", div, "BOTTOMLEFT", 6, -10)
    nav:SetPoint("BOTTOMRIGHT", rail, "BOTTOMRIGHT", -6, 8)
    p.nav = nav

    -- content: reset header + category title + the data grid
    local content = W.Panel(f.body, "panel", "border")
    content:SetPoint("TOPLEFT", rail, "TOPRIGHT", 1, 0)
    content:SetPoint("BOTTOMRIGHT", f.body, "BOTTOMRIGHT", 0, 0)

    local resetHdr = W.Text(content, "", "textDim", "GameFontHighlightSmall")
    resetHdr:SetPoint("TOPLEFT", 16, -12); resetHdr:SetPoint("RIGHT", content, "RIGHT", -16, 0)
    resetHdr:SetJustifyH("LEFT")
    p.resetHdr = resetHdr

    local catTitle = W.Text(content, "", "text", "GameFontNormalLarge")
    catTitle:SetPoint("TOPLEFT", resetHdr, "BOTTOMLEFT", 0, -10)
    p.catTitle = catTitle

    local grid = W.Grid(content, { name = "HagAIODashboardGrid", header = true, striped = true })
    grid:SetPoint("TOPLEFT", catTitle, "BOTTOMLEFT", 0, -12)
    grid:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -10, 12)
    p.grid = grid

    p.built = true
    p.nav:Select(p.category)   -- highlight the default category + render it via onSelect
end

-- Is a category enabled in the settings? Dynamic "raid:<exp>" keys follow the Raids toggle.
function Dashboard:_CategoryVisible(key)
    if key:match("^raid:") then return self:GetSetting("show_raids") ~= false end
    return self:GetSetting("show_" .. key) ~= false
end

-- The navigation items: a section header per group, a selectable (indented) item otherwise.
-- Categories the player has hidden in the settings are skipped, and a section header with no
-- visible items beneath it is dropped.
function Dashboard:_NavItems()
    local items = {}
    for _, cat in ipairs(CATEGORIES) do
        if cat.header then
            items[#items + 1] = { section = cat.label }
        elseif self:_CategoryVisible(cat.key) then
            items[#items + 1] = { key = cat.key, label = cat.label, indent = cat.indent and 1 or 0 }
            -- a deeper sub-node per expansion you hold a lock in (current first), for Raids/Dungeons
            if cat.key == "raids" then
                for _, exp in ipairs(self:_SavedExpansions(true)) do
                    items[#items + 1] = { key = "raid:" .. exp, label = exp, indent = 2 }
                end
            elseif cat.key == "dungeons" then
                for _, exp in ipairs(self:_SavedExpansions(false)) do
                    items[#items + 1] = { key = "dungeon:" .. exp, label = exp, indent = 2 }
                end
            end
        end
    end
    local out = {}
    for i, it in ipairs(items) do
        if it.section then
            local nxt = items[i + 1]
            if nxt and not nxt.section then out[#out + 1] = it end  -- keep only non-empty sections
        else
            out[#out + 1] = it
        end
    end
    return out
end

-- Resolve a nav key to (title, columns(chars)). Dynamic "raid:<exp>" / "dungeon:<exp>" keys filter
-- the lockouts to one expansion of that kind; everything else is a static CATEGORIES entry.
function Dashboard:_ResolveCategory(key)
    local rexp = key and key:match("^raid:(.+)$")
    if rexp then
        return rexp .. " Raids", function(chars)
            return lockoutColumns(chars, function(lk)
                return lk.isRaid and self:_InstanceExpansion(lk.name) == rexp end)
        end
    end
    local dexp = key and key:match("^dungeon:(.+)$")
    if dexp then
        return dexp .. " Dungeons", function(chars)
            return lockoutColumns(chars, function(lk)
                return not lk.isRaid and self:_InstanceExpansion(lk.name) == dexp end)
        end
    end
    for _, c in ipairs(CATEGORIES) do
        if c.key == key then return c.label, c.columns end
    end
    return CATEGORIES[1].label, CATEGORIES[1].columns
end

-- Sorted character keys: the current character first, then alphabetical.
function Dashboard:_SortedChars()
    local chars = self:_Chars()
    local selfKey = self:_SelfKey()
    local keys = {}
    for k in pairs(chars) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if (a == selfKey) ~= (b == selfKey) then return a == selfKey end
        return a < b
    end)
    return keys, chars
end

function Dashboard:_Render()
    local p = self:_p()
    if not p.built then return end
    self:_UpdateHeader()
    self:_UpdateCountdown()
    self:_ExpansionMap()                 -- build the raid->expansion map (no-op once cached)

    local items = self:_NavItems()
    -- keep the selection valid: if the active category was hidden, fall back to the first one
    local valid
    for _, it in ipairs(items) do if it.key == p.category then valid = true; break end end
    if not valid then
        for _, it in ipairs(items) do if it.key then p.category = it.key; break end end
    end
    p.nav:SetItems(items)
    p.nav:Select(p.category, true)       -- reflect the (possibly changed) active selection silently

    local keys, chars = self:_SortedChars()
    local label, columnsFn = self:_ResolveCategory(p.category)
    p.catTitle:SetText(label)
    local cols = (columnsFn and columnsFn(chars)) or {}

    -- one sticky Character column + one column per category item; the grid aligns header+cells
    local columns = { { width = NAME_COL, label = "Character" } }
    for _, c in ipairs(cols) do columns[#columns + 1] = { width = c.width, label = c.label } end
    p.grid:SetColumns(columns)

    -- one row per character: cell 1 = class-coloured name, then a value per item column
    local rows = {}
    for _, key in ipairs(keys) do
        local e = chars[key]
        local cells = { e.name or key }
        for _, c in ipairs(cols) do cells[#cells + 1] = c.cell(e) or "-" end
        local cc = e.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.class]
        local nameColor = cc and { cc.r, cc.g, cc.b } or "text"
        rows[#rows + 1] = { cells = cells, cellColor = function(ci)
            if ci == 1 then return nameColor end
            return cells[ci] == "-" and "textFaint" or "text"
        end }
    end
    p.grid:SetRows(rows)
end

function Dashboard:_UpdateHeader()
    local p = self:_p()
    local chars = self:_Chars()
    local e = chars[self:_SelfKey()]
    if not e then return end
    p.hName:SetText(e.name or "?")
    local cc = e.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.class]
    if cc then p.hName:SetTextColor(cc.r, cc.g, cc.b) end
    p.hInfo:SetText(("Level %s   iLvl %s"):format(tostring(e.level or "-"), tostring(e.ilvl or "-")))
    p.hRating:SetText(e.rating and ("Mythic+ " .. e.rating) or "")
    if SetPortraitTexture and p.avatar then
        SetPortraitTexture(p.avatar, "player")   -- the viewing character's portrait
    end
end

function Dashboard:_RenderIfShown()
    if self:_p().shown then self:_Render() end
end

function Dashboard:_UpdateCountdown()
    local p = self:_p()
    if not p.resetHdr then return end
    local weekly = C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset and C_DateAndTime.GetSecondsUntilWeeklyReset()
    local daily  = C_DateAndTime and C_DateAndTime.GetSecondsUntilDailyReset  and C_DateAndTime.GetSecondsUntilDailyReset()
    p.resetHdr:SetText(("Weekly reset in |cff%s%s|r      Daily reset in |cff%s%s|r")
        :format(Theme.hex.accent, clock(weekly), Theme.hex.accent, clock(daily)))
end

-- ---- show / hide ----------------------------------------------------------
function Dashboard:Show()
    self:_Build()
    local p = self:_p()
    p.shown = true
    p.frame:Show()
    self:_Render()
    if p.ticker then p.ticker:Cancel() end
    p.ticker = C_Timer.NewTicker(1, function() if p.shown then self:_UpdateCountdown() end end)
    C_Timer.After(0, function() self:_Render() end)   -- re-measure once on screen
end

function Dashboard:Hide()
    local p = self:_p()
    p.shown = false
    if p.ticker then p.ticker:Cancel(); p.ticker = nil end
    if p.frame then p.frame:Hide() end
end

function Dashboard:Toggle()
    if self:_p().shown then self:Hide() else self:Show() end
end

-- ---- registration ---------------------------------------------------------
ns.ModuleManager:Register(Dashboard:New("Dashboard", {
    title = "Dashboard",
    description = "A cross-character view of weekly/daily resets: Great Vault, M+ keystone, lockouts and recurring quests.",
    defaultEnabled = false,
    color = ns.Theme.hex.accent,
    deps = { "SavedVars", "SlashCommand", "Secrets" },
    commands = {
        dashboard = { handler = "Toggle", help = "open the cross-character Dashboard" },
    },
    settings = {
        { type = "header", text = "Categories" },
        { type = "toggle", key = "show_mplus",    label = "Mythic+",       default = true },
        { type = "toggle", key = "show_raids",    label = "Raids",         default = true },
        { type = "toggle", key = "show_dungeons", label = "Dungeons",      default = true },
        { type = "toggle", key = "show_weekly",   label = "Weekly Quests", default = true },
        { type = "toggle", key = "show_daily",    label = "Daily Quests",  default = true },
        { type = "note", text = "Choose which categories appear in the Dashboard. Open it with /hag dashboard." },
    },
}))
