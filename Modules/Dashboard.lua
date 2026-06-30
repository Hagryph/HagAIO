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

local Dashboard = Class.new("Dashboard", ns.Module, { mixins = { ns.VersioningOwner } })

local RAIL_W = 178            -- left category-tree / character-header rail
local AVATAR = 46            -- character portrait size

-- Raid difficulty -> short tag + rank (highest rank wins when a char is locked at several). enUS
-- names; an unknown locale falls back to the first letter, so it degrades, never breaks.
local DIFF = {
    ["Looking For Raid"] = { abbr = "LFR", rank = 1 }, ["Raid Finder"] = { abbr = "LFR", rank = 1 },
    Normal = { abbr = "N", rank = 2 }, Heroic = { abbr = "H", rank = 3 }, Mythic = { abbr = "M", rank = 4 },
}

-- Raid difficulty ids CHECKED PER RAID against the journal (EJ_IsValidInstanceDifficulty), so a raid
-- is seeded ONLY the difficulties it actually offers -- not every raid has LFR or Mythic, and legacy
-- raids use 10/25/40-player ids. DIFF_META (abbr + sort rank for the inline columns) is keyed by ID,
-- so it's locale-proof; an unlisted id falls back to its GetDifficultyInfo name and sorts last.
-- The journal catalog -- instances, difficulties, art -- only changes across patches, so both the
-- per-raid difficulty probe and the whole journal walk are gated on the client build via the shared
-- ns.Versioning service: a same-build login reconstructs the catalog from the DB instead of re-walking.
local CATALOG_DOMAIN = "dashboard_catalog"   -- our key in the general data-version registry
local DIFF_META = {
    [7]  = { abbr = "LFR", rank = 1 }, [17] = { abbr = "LFR", rank = 1 },
    [3]  = { abbr = "10",  rank = 2 }, [4]  = { abbr = "25",  rank = 2 }, [9] = { abbr = "40", rank = 2 },
    [148] = { abbr = "20", rank = 2 }, [14] = { abbr = "N",   rank = 2 },
    [5]  = { abbr = "10H", rank = 3 }, [6]  = { abbr = "25H", rank = 3 }, [15] = { abbr = "H", rank = 3 },
    [16] = { abbr = "M",   rank = 4 },
    [23] = { abbr = "M0",  rank = 5 },   -- dungeon Mythic 0
}

-- Mythic 0 dungeon difficulty (id 23). M0 is the localized NAME (matches a saved M0 lock's difficulty
-- name); M0_ID is the locale-proof difficulty id (stamped on seeded season-dungeon entries).
local M0_ID = 23
local M0 = (GetDifficultyInfo and GetDifficultyInfo(M0_ID)) or "Mythic"

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

-- The Home nav entry, labelled "Overview". Selecting it shows the overview -- an icon grid of every
-- category. Re-clicking the already-active category also returns here (see the nav onReselect).
local HOME_LABEL = "Overview"

-- The current M+ season dungeon entry's label. Also used to DEDUPE the dungeon overview: the journal
-- exposes the current dungeons under a "Current Season" pseudo-tier, so a per-expansion tile carrying
-- this same label would just duplicate this entry (with no expansion logo) -- we drop it. (enUS, like
-- the rest of this module's journal labels.)
local SEASON_LABEL = "Current Season"

-- Copy an art descriptor ({texture, cover, texCoord, zoom, aspect, panX, panY} from _InstanceArt)
-- onto a tile.
local function applyArt(tile, art)
    tile.texture, tile.cover, tile.texCoord, tile.zoom =
        art.texture, art.cover, art.texCoord, art.zoom
    tile.aspect, tile.panX, tile.panY = art.aspect, art.panX, art.panY
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
    { key = "raids",    label = "Raids",    indent = true },   -- lockout columns resolved per-key below
    { key = "dungeons", label = "Dungeons", indent = true },
    -- Recorded weekly/daily turn-ins, drilling expansion -> zone -> quests (all auto-discovered
    -- at turn-in). TOP-LEVEL entry: the page is the expansion overview; "quest:<exp>" sub-keys
    -- (added in _NavItems while open) show that expansion's ZONE tiles, and a zone opens its
    -- quest tiles ("quest:<exp>|<zone>", page-only -- the nav stops at the expansion).
    { key = "quests", label = "Quests" },
}

-- ---- lifecycle ------------------------------------------------------------
function Dashboard:OnInitialize()
    local p = self:_p()
    p.built = false
    p.shown = false
    p.category = "home"   -- open on the overview (an icon grid of every category)
    p.charStore = ns.CharacterStore:New(self)   -- the per-character data layer (collaborator over self:DB())
    p.catalog = ns.ExpansionCatalog:New(self, p.charStore)   -- the instance/zone catalog layer (also over self:DB())
    p.charStore:SetCatalog(p.catalog)   -- the self-curating lockout path resolves names via the catalog
    self:SetVersionDomain(CATALOG_DOMAIN)   -- bind versioning (ns.VersioningOwner) to our catalog domain
end

function Dashboard:OnEnable()
    -- Targeted collectors keep each fire cheap (the never-debounce rule): a bag update only
    -- re-reads the keystone, a quest turn-in only records that quest.
    -- The full catalog build + snapshot scans hundreds of APIs and writes many DB rows, so it runs
    -- through the frame-budgeted Worker (see _RefreshNow below). The targeted collectors below stay
    -- inline -- each fire is cheap (the never-debounce rule): a bag update only re-reads the keystone,
    -- a quest turn-in only records that quest.
    -- Catalog build + snapshot is the heavy, deferrable work -> it runs THROUGH the frame-budgeted
    -- Worker (Services/Worker.lua): once at enable, then re-run on each zone change (coalesced by the
    -- Worker, so rapid PLAYER_ENTERING_WORLD fires don't pile up). The Worker spreads it across frames.
    local cs = self:_p().charStore   -- per-character data layer (built in OnInitialize); the renders stay on self
    self:WorkOn("PLAYER_ENTERING_WORLD",  function() self:_RefreshNow() end, { label = "Dashboard refresh" })
    self:On("PLAYER_LOGOUT",              function() cs:Snapshot(); self:_RenderIfShown() end)   -- inline: must finish before logout
    self:On("WEEKLY_REWARDS_UPDATE",      function() cs:CollectVault();    self:_RenderIfShown() end)
    self:On("CHALLENGE_MODE_COMPLETED",   function() cs:CollectKeystone(); self:_RenderIfShown() end)
    self:On("CHALLENGE_MODE_MAPS_UPDATE", function() cs:CollectKeystone(); self:_RenderIfShown() end)
    self:On("BAG_UPDATE_DELAYED",         function() cs:CollectKeystone(); self:_RenderIfShown() end)
    self:On("UPDATE_INSTANCE_INFO",       function() cs:CollectLockouts(); self:_RenderIfShown() end)
    self:On("BOSS_KILL",                  function() cs:CollectLockouts() end)
    self:On("QUEST_TURNED_IN",            function(_, questID) cs:RecordQuest(questID); self:_RenderIfShown() end)
    self:Queue(function() self:_RefreshNow() end, { label = "Dashboard initial build" })  -- deferred via Worker
    if RequestRaidInfo then RequestRaidInfo() end   -- async -> UPDATE_INSTANCE_INFO fills lockouts
end

-- A settings change (a category toggled on/off) re-renders so the nav tree reflects it.
function Dashboard:OnSettingChanged()
    self:_RenderIfShown()
end

function Dashboard:OnDisable()
    self:Hide()   -- hiding the window hides every page's tiles + textures, so WoW frees their VRAM
end

-- ---- account-wide store (the shared relational Database) -------------------
-- Per-character snapshots and a SELF-CURATING instance registry (every instance ever locked, so the
-- dashboard keeps showing a dungeon/raid after its lockout expires) live in the shared Database (see
-- ns.DatabaseOwner / self:DB()) across five flat tables -- never a nested saved-var blob:
--   dashboard_char     one row per character (scalars + the flattened keystone)
--   dashboard_vault    the character's Great-Vault slots          (child, cascades on char delete)
--   dashboard_lockout  the character's current raid/dungeon locks (child, cascades)
--   dashboard_quest    recorded weekly/daily quest turn-ins        (child, cascades)
--   dashboard_instance the "name|difficulty" registry (account-wide, not per character)
-- The reader helpers RECONSTRUCT the document shape the renderers expect ({ vault = { slots = {} },
-- lockouts = {}, quests = { freq = { id = title } }, keystone = {} }) from these tables, so the
-- rendering stays document-oriented while storage is purely relational.

-- A projected column is the DB.NULL sentinel (not Lua nil) when absent; collapse it to nil so the
-- reconstructed documents read exactly like the old plain-Lua snapshots (l.progress or 0, etc.).
local function denull(v) if v == nil or ns.DB.isNull(v) then return nil end return v end

-- The heavy, deferrable pass: (re)build the instance catalog (once the journal is available) and
-- snapshot this character. Runs THROUGH the Worker (see OnEnable: self:Queue / self:WorkOn), which
-- drives it inside a frame-budgeted coroutine -- the row loops here call ns.Worker:MaybeYield() (and
-- the DB executor chunks itself) so the cost spreads across frames and never stalls a render.
function Dashboard:_RefreshNow()
    self:_p().catalog:_BuildCatalog()
    self:_p().catalog:_BuildZoneCatalog()            -- the full zone registry (versioned: a real sweep once per patch)
    self:_p().charStore:Snapshot()      -- snapshot this character into the store...
    self:_RenderIfShown()               -- ...then render (Snapshot no longer renders on its own)
end

-- ---- Dev-module-facing catalog API (thin forwarders) ----------------------
-- The Dev module live-tunes the instance splash art + steps the Current Season tile through the
-- season dungeons. That state lives on the ExpansionCatalog collaborator now; these forward to it
-- and re-render here (the catalog no longer touches the UI), so the Dev panel API is unchanged.
function Dashboard:GetArtTune(kind) return self:_p().catalog:GetArtTune(kind) end
function Dashboard:SetArtTune(kind, field, value)
    self:_p().catalog:SetArtTune(kind, field, value)
    self:_RenderIfShown()
end
function Dashboard:NextSeasonDungeon()
    local d = self:_p().catalog:NextSeasonDungeon()
    self:_RenderIfShown()
    return d
end
function Dashboard:CurrentSeasonDungeon() return self:_p().catalog:CurrentSeasonDungeon() end

-- One icon tile per instance { id, name }: its journal art (by name), labelled with its name. Clicking
-- a tile EXPANDS it in place (no navigation): the lockout table for that instance (identified by its
-- journal id) opens inline under its row; clicking it again (or another) toggles. Falls back to
-- `logoTier`'s banner until the art has loaded. `artKind` is "raid" | "dungeon".
function Dashboard:_InstanceTilesFor(list, logoTier, expandedId, artKind)
    local p = self:_p()
    local tiles = {}
    for _, d in ipairs(list) do
        local id, name = d.id, d.name
        local on = (id == expandedId)
        local tile = {
            texture = logoTier and self:_p().catalog:_ExpansionLogo(logoTier) or nil,
            label = name, selected = on, expanded = on,
            onClick = function()
                p.expandedInstance = p.expandedInstance or {}
                local cat = p.category
                -- toggle: reselecting the open tile clears it (an explicit if -- `x and nil or y`
                -- would never yield nil and so could never collapse).
                if p.expandedInstance[cat] == id then p.expandedInstance[cat] = nil
                else p.expandedInstance[cat] = id end
                self:_Render()
            end,
        }
        local art = self:_p().catalog:_InstanceArt(name, artKind)
        if art then applyArt(tile, art) end
        tiles[#tiles + 1] = tile
    end
    return tiles
end

-- Difficulty columns for ONE instance (by journal id): a column per difficulty present, ordered by
-- rank, each cell the character's lock progress ("6/8") or "-". Raids span LFR/N/H/M; dungeons M0.
function Dashboard:_InstanceDifficultyColumns(id)
    local cols = {}
    for _, r in pairs(self:_p().charStore:Instances()) do
        if r.id == id then
            local name, diff, total, meta = r.name, r.diff, r.total, DIFF_META[r.diffID]
            cols[#cols + 1] = { label = (meta and meta.abbr) or diff or "?",
                _rank = (meta and meta.rank) or 99, _id = r.diffID or 0, width = 92,
                cell = function(e)
                    for _, l in ipairs(e.lockouts or {}) do
                        if l.name == name and l.diff == diff then return (l.progress or 0) .. "/" .. (l.total or total or "?") end
                    end
                    return "-"
                end }
        end
    end
    table.sort(cols, function(a, b) if a._rank ~= b._rank then return a._rank < b._rank end return a._id < b._id end)
    return cols
end

-- The per-page inline detail Grid (rows = characters, cols = an instance's difficulties), created
-- lazily inside the icon page's scroll content. Cached per page; reused as the expanded item changes.
function Dashboard:_InstanceDetailGrid(page)
    local p = self:_p()
    p.detailGrids = p.detailGrids or {}
    if p.detailGrids[page] then return p.detailGrids[page] end
    local g = W.Grid:New(page:DetailParent(), { header = true, scroll = false, striped = true, rowHeight = 20 })
    p.detailGrids[page] = g
    return g
end

-- Fill the page's detail Grid with instance `id`'s per-character lockouts; returns the px height needed.
function Dashboard:_FillInstanceDetail(page, id)
    local g = self:_InstanceDetailGrid(page)
    local columns, rows = self:_BuildLockoutGrid(self:_InstanceDifficultyColumns(id))
    g:SetColumns(columns)
    g:SetRows(rows)
    return g:NaturalHeight() + 4        -- the grid knows its own chrome; just add a little air
end

-- Render an expandable instance icon page (a raid or dungeon group): the tiles, plus the clicked
-- item's lockout table opening inline. Keeps "<kind> -> Expansion" the deepest the nav ever goes.
-- `list` is { id, name } descriptors; the expanded item is tracked by its journal id.
function Dashboard:_ShowInstancePage(page, list, logoTier, isRaid)
    local p = self:_p()
    p.expandedInstance = p.expandedInstance or {}
    local want, expanded = p.expandedInstance[p.category]
    for _, d in ipairs(list) do if d.id == want then expanded = d.id; break end end
    p.expandedInstance[p.category] = expanded                   -- drop a stale id (no longer listed)
    if expanded then page:SetDetail(self:_InstanceDetailGrid(page), self:_FillInstanceDetail(page, expanded))
    else page:SetDetail(nil, 0) end
    page:SetTiles(self:_InstanceTilesFor(list, logoTier, expanded, isRaid and "raid" or "dungeon"))
end

-- ---- quests: recorded weekly/daily turn-ins, grouped expansion -> zone (all auto-discovered) ----
-- The dungeon-page pattern applied to quests: nav node per EXPANSION (only ones with recorded
-- quests), each opening an icon page of ZONE tiles (real map art via Widgets.MapArt), each zone
-- expanding its quest x character matrix inline. Everything self-curates from CharacterStore:RecordQuest --
-- there is no curated quest/zone/expansion list anywhere.

-- Quests whose expansion was never discovered (legacy rows) bucket under this label.
local QUEST_OTHER = "Other"

local function questExpFilter(qb, exp)
    if exp == QUEST_OTHER then return qb:Where("quest.expansion", "is null") end
    return qb:Where("quest.expansion", "=", exp)
end

-- Expansions with at least one RECORDED quest, newest first (by the expansion registry's level;
-- unknown names alphabetical after), the "Other" bucket last.
function Dashboard:_QuestExpansions()
    local db = self:DB(); if not db then return {} end
    local rows = db:Select("quest.expansion"):From("dashboard_quest")
        :InnerJoin("quest", { on = { "dashboard_quest.quest_id", "quest.quest_id" } })
        :Distinct():Run()
    local names, other = {}, false
    for _, r in ipairs(rows) do
        local e = denull(r.expansion)
        if e then names[#names + 1] = e else other = true end
    end
    local lvl = {}
    for _, e in ipairs(db:Select("name", "level"):From("expansion"):Run()) do
        local n = denull(e.name); if n then lvl[n] = denull(e.level) end
    end
    table.sort(names, function(a, b)
        local la, lb = lvl[a], lvl[b]
        if (la ~= nil) ~= (lb ~= nil) then return la ~= nil end
        if la and lb and la ~= lb then return la > lb end
        return a < b
    end)
    if other then names[#names + 1] = QUEST_OTHER end
    return names
end

-- The zones with recorded quests in `exp`: { key, mapID, name }, name-sorted -- the expansion
-- page's tile list. A legacy row with no discovered zone buckets under "Unknown Zone".
function Dashboard:_QuestZones(exp)
    local db = self:DB(); if not db then return {} end
    local qb = questExpFilter(db:Select("quest.zone_map_id", "quest.zone_name"):From("dashboard_quest")
        :InnerJoin("quest", { on = { "dashboard_quest.quest_id", "quest.quest_id" } }):Distinct(), exp)
    local zones, seen = {}, {}
    for _, r in ipairs(qb:Run()) do
        local mapID, name = denull(r.zone_map_id), denull(r.zone_name)
        local key = mapID and tostring(mapID) or "none"
        if not seen[key] then
            seen[key] = true
            zones[#zones + 1] = { key = key, mapID = mapID, name = name or "Unknown Zone" }
        end
    end
    table.sort(zones, function(a, b) return a.name < b.name end)
    return zones
end

-- Resolve a zone-page key ("<uiMapID>" / "none") back to its zone descriptor, or nil if stale.
function Dashboard:_QuestZoneByKey(exp, key)
    for _, z in ipairs(self:_QuestZones(exp)) do
        if z.key == key then return z end
    end
end

-- ALL recorded quests of one expansion (optionally ONE zone of it): { id, title, freq, zone },
-- grouped by zone, weekly before daily, title-sorted -- the tile order of the quest page.
function Dashboard:_QuestsInExpansion(exp, zone)
    local db = self:DB(); if not db then return {} end
    local qb = questExpFilter(db:Select("quest.quest_id", "quest.title", "dashboard_quest.freq", "quest.zone_name")
        :From("dashboard_quest")
        :InnerJoin("quest", { on = { "dashboard_quest.quest_id", "quest.quest_id" } }):Distinct(), exp)
    if zone then
        if zone.mapID then qb:AndWhere("quest.zone_map_id", "=", zone.mapID)
        else qb:AndWhere("quest.zone_map_id", "is null") end
    end
    local out = {}
    for _, r in ipairs(qb:Run()) do
        out[#out + 1] = { id = denull(r.quest_id), title = denull(r.title),
            freq = denull(r.freq) or "weekly", zone = denull(r.zone_name) }
    end
    table.sort(out, function(a, b)
        if (a.zone or "~") ~= (b.zone or "~") then return (a.zone or "~") < (b.zone or "~") end
        if a.freq ~= b.freq then return a.freq == "weekly" end
        return (a.title or "") < (b.title or "")
    end)
    return out
end

-- Reset-aware doneness: a turn-in only counts while its done_at falls inside the CURRENT reset
-- window (daily/weekly), computed from the server clock + the next-reset countdowns. A legacy row
-- without done_at never counts (it re-earns its check on the next turn-in).
function Dashboard:_QuestDone(doneAt, freq)
    if not doneAt or doneAt == 0 then return false end
    local now = (GetServerTime and GetServerTime()) or time()
    local untilNext
    if freq == "daily" then
        untilNext = C_DateAndTime and C_DateAndTime.GetSecondsUntilDailyReset and C_DateAndTime.GetSecondsUntilDailyReset()
    else
        untilNext = C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset and C_DateAndTime.GetSecondsUntilWeeklyReset()
    end
    if not untilNext then return true end                 -- no reset info: trust the recorded state
    local period = (freq == "daily") and 86400 or 604800
    return doneAt >= ((now + untilNext) - period)         -- after the LAST reset = inside this window
end

-- "x ago" for the detail's Completed column (coarse on purpose: it answers "this reset?").
local function timeAgo(secs)
    if secs < 3600 then return "<1h ago" end
    if secs < 86400 then return math.floor(secs / 3600) .. "h ago" end
    return math.floor(secs / 86400) .. "d ago"
end

-- The per-page inline quest detail Grid (rows = characters), mirroring _InstanceDetailGrid.
function Dashboard:_QuestDetailGrid(page)
    local p = self:_p()
    p.questDetailGrids = p.questDetailGrids or {}
    if p.questDetailGrids[page] then return p.questDetailGrids[page] end
    local g = W.Grid:New(page:DetailParent(), { header = true, scroll = false, striped = true, rowHeight = 22 })
    p.questDetailGrids[page] = g
    return g
end

-- Fill the page's detail Grid with ONE quest's per-character state (the raid-detail shape:
-- Character | done this window (check/dash) | when); returns the px height needed.
function Dashboard:_FillQuestDetail(page, q)
    local g = self:_QuestDetailGrid(page)
    local keys, chars = self:_SortedChars()
    local columns = {
        { width = NAME_COL, label = "Character" },
        { width = 90,  label = (q.freq == "weekly") and "Weekly" or "Daily", justify = "CENTER" },
        { width = 110, label = "Completed", justify = "CENTER" },
    }
    local now = (GetServerTime and GetServerTime()) or time()
    local rows = {}
    for _, key in ipairs(keys) do
        local e = chars[key]
        local rec = e.quests and e.quests[q.freq]
        local doneAt = rec and rec[q.id]
        local done = self:_QuestDone(doneAt, q.freq)
        local cc = e.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.class]
        local nameColor = cc and { cc.r, cc.g, cc.b } or "text"
        rows[#rows + 1] = {
            cells = { e.name or key, done, done and timeAgo(math.max(0, now - doneAt)) or "-" },
            cellColor = function(ci) if ci == 1 then return nameColor end end,
        }
    end
    g:SetColumns(columns)
    g:SetRows(rows)
    return g:NaturalHeight() + 4
end

-- Render a quest EXPANSION's page: its zone overview -- one typography tile per zone, opening
-- that zone's quest page ("quest:<exp>|<zone>", a page-only drill; the nav stays on the expansion).
function Dashboard:_ShowQuestZonesPage(page, exp)
    local p = self:_p()
    local lvl = self:_p().catalog:TierLevel(exp)
    local tiles = {}
    for _, z in ipairs(self:_QuestZones(exp)) do
        tiles[#tiles + 1] = {
            key = z.key, label = z.name,
            typo = { text = z.name, style = self:_p().catalog:_ZoneStyle(z.name, lvl) },
            onClick = function()
                p.category = "quest:" .. exp .. "|" .. z.key
                self:_Render()
            end,
        }
    end
    page:SetTiles(tiles)
end

-- Render a ZONE's quest page: ONE TYPOGRAPHY TILE PER QUEST (title in the serif, styled by its
-- zone; the zone names the titlebar, Weekly/Daily badges the corner), the clicked quest's
-- per-character state opening inline -- the raids/dungeons interaction, applied to quests.
function Dashboard:_ShowQuestPage(page, exp, zone)
    local p = self:_p()
    p.expandedQuest = p.expandedQuest or {}
    local quests = self:_QuestsInExpansion(exp, zone)
    local want, exQ = p.expandedQuest[p.category]
    for _, q in ipairs(quests) do if q.id == want then exQ = q; break end end
    p.expandedQuest[p.category] = exQ and exQ.id or nil   -- drop a stale id
    if exQ then page:SetDetail(self:_QuestDetailGrid(page), self:_FillQuestDetail(page, exQ))
    else page:SetDetail(nil, 0) end
    local lvl = self:_p().catalog:TierLevel(exp)
    local tiles = {}
    for _, q in ipairs(quests) do
        local on = exQ and (q.id == exQ.id) or false
        tiles[#tiles + 1] = {
            key = q.id, label = q.zone or "Unknown Zone", selected = on, expanded = on,
            badge = (q.freq == "weekly") and "Weekly" or "Daily",
            badgeKey = (q.freq == "weekly") and "accent" or "green",
            typo = { text = q.title or ("Quest " .. tostring(q.id)),
                     style = self:_p().catalog:_ZoneStyle(q.zone, lvl), scale = 0.16 },   -- titles run long: smaller type
            onClick = function()
                if p.expandedQuest[p.category] == q.id then p.expandedQuest[p.category] = nil
                else p.expandedQuest[p.category] = q.id end
                self:_Render()
            end,
        }
    end
    page:SetTiles(tiles)
end

-- The "Quests" overview: one tile per expansion with recorded quests (its logo), drilling into
-- that expansion's zone page.
function Dashboard:_QuestExpansionTiles()
    local p = self:_p()
    local tiles = {}
    for _, exp in ipairs(self:_QuestExpansions()) do
        tiles[#tiles + 1] = {
            key = exp, label = exp, texture = self:_p().catalog:_ExpansionLogo(exp),
            onClick = function() p.nav:Select("quest:" .. exp) end,
        }
    end
    return tiles
end

-- ---- dev tooling: random test data (buttons on the Dev settings page) --------------------------
-- Fill every dashboard page with RANDOM characters / keystones / vaults / lockouts / quests so the
-- layouts can be eyeballed fully populated without grinding alts. Test rows are MARKED (characters
-- on realm DEV_REALM, quest ids >= DEV_QUEST_BASE) so DevClearTestData removes exactly them and
-- never touches real data. Lockouts reference the REAL seeded catalog (all expansions) and quest
-- zones come from REAL zone maps, so tiles render their actual art.
local DEV_REALM = "DevTest"
local DEV_QUEST_BASE = 900000
local DEV_NAMES = { "Aravel", "Borgrim", "Cynthra", "Dorel", "Eryndis", "Fenwick", "Gormak",
                    "Hesperia", "Ilthane", "Jorvana", "Kaelis", "Lunara" }
local DEV_CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE",
                      "WARLOCK", "MONK", "DRUID", "DEMONHUNTER", "DEATHKNIGHT", "EVOKER" }
local DEV_Q1 = { "Bounty", "Tribute", "Patrol", "Offering", "Harvest", "Errand", "Trial", "Rally", "Procession", "Vigil" }
local DEV_Q2 = { "of the Depths", "at Dawn", "for the Flame", "of Renown", "in the Mists",
                 "of the Vault", "for the Archives", "of Embers", "at the Crossing", "of the Hollow" }

-- Real zones for test quests: the zone REGISTRY when the catalog has built (every zone, ids +
-- art resolution included), else a live scan of zone maps with world-map art.
function Dashboard:_DevZonePool()
    local p = self:_p()
    if p.devZones then return p.devZones end
    local out = {}
    local db = self:DB()
    if db then
        for _, r in ipairs(db:Select("ui_map_id", "name"):From("zone"):Run()) do
            local id = denull(r.ui_map_id)
            if id then out[#out + 1] = { mapID = id, name = denull(r.name) or ("Zone " .. id) } end
        end
    end
    if #out == 0 and C_Map and C_Map.GetMapInfo and C_Map.GetMapArtLayerTextures then
        local zoneType = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
        for id = 1, 2600 do
            local mi = C_Map.GetMapInfo(id)
            if mi and mi.mapType == zoneType and mi.name then
                local files = C_Map.GetMapArtLayerTextures(id, 1)
                if files and #files > 0 then out[#out + 1] = { mapID = id, name = mi.name } end
            end
        end
    end
    if #out == 0 then out[1] = { mapID = nil, name = "Testlands" } end
    p.devZones = out
    return out
end

function Dashboard:DevSeedTestData()
    local db = self:DB(); if not db then return end
    local now = (GetServerTime and GetServerTime()) or time()
    -- expansion pool: the real registry when the catalog has run, else the client's expansion names
    local exps = {}
    for _, e in ipairs(db:Select("name"):From("expansion"):Run()) do exps[#exps + 1] = denull(e.name) end
    if #exps == 0 then
        for i = 0, 12 do local n = _G["EXPANSION_NAME" .. i]; if n then exps[#exps + 1] = n end end
    end
    local ksIds = (C_ChallengeMode and C_ChallengeMode.GetMapTable and C_ChallengeMode.GetMapTable()) or {}
    local instRows = db:Select("key"):From("dashboard_instance"):Run()
    -- characters (fresh each seed: cascade-drop, then insert)
    local charKeys = {}
    for i = 1, math.random(6, 10) do
        local name = DEV_NAMES[math.random(#DEV_NAMES)] .. i
        local key = name .. "-" .. DEV_REALM
        charKeys[#charKeys + 1] = key
        db:Delete("dashboard_char", { char_key = key })
        local fields = { char_key = key, name = name, realm = DEV_REALM,
            class = DEV_CLASSES[math.random(#DEV_CLASSES)], level = math.random(60, 80),
            ilvl = math.random(380, 680), rating = math.random(0, 3500),
            last_seen = now - math.random(0, 6 * 86400) }
        if #ksIds > 0 and math.random() < 0.8 then
            local mapid = ksIds[math.random(#ksIds)]
            self:_p().charStore:SetKeystone(mapid, C_ChallengeMode.GetMapUIInfo and C_ChallengeMode.GetMapUIInfo(mapid))
            fields.ks_mapid, fields.ks_level = mapid, math.random(2, 20)
        end
        db:Insert("dashboard_char", fields)
        for ord = 1, 9 do                                     -- vault slots, most filled
            if math.random() < 0.8 then
                local thr = math.random(1, 8)
                db:Insert("dashboard_vault", { char_key = key, ordinal = ord,
                    type = math.ceil(ord / 3), level = math.random(2, 20),
                    progress = math.random(0, thr + 2), threshold = thr })
            end
        end
        for _, r in ipairs(instRows) do                       -- a random fifth of the real catalog locked
            if math.random() < 0.2 then
                local total = math.random(4, 12)
                db:Insert("dashboard_lockout", { char_key = key, instance_key = denull(r.key),
                    total = total, progress = math.random(0, total),
                    reset = now + math.random(3600, 6 * 86400) })
            end
        end
    end
    -- quests: a handful of zones, a few quests each, random expansion/freq; done_at scattered so
    -- the matrix shows a believable mix of checks, dashes, and stale (pre-reset) turn-ins
    local pool = self:_DevZonePool()
    local qid = DEV_QUEST_BASE
    for _ = 1, math.min(8, #pool) do
        local z = pool[math.random(#pool)]
        for _ = 1, math.random(2, 5) do
            qid = qid + 1
            local freq = (math.random() < 0.5) and "weekly" or "daily"
            db:Delete("quest", { quest_id = qid })
            db:Insert("quest", { quest_id = qid,
                title = DEV_Q1[math.random(#DEV_Q1)] .. " " .. DEV_Q2[math.random(#DEV_Q2)],
                zone_map_id = z.mapID, zone_name = z.name,
                expansion = exps[math.random(math.max(1, #exps))] })
            local period = (freq == "daily") and 86400 or 604800
            for _, key in ipairs(charKeys) do
                if math.random() < 0.7 then
                    db:Insert("dashboard_quest", { char_key = key, freq = freq, quest_id = qid,
                        done_at = now - math.random(0, math.floor(period * 1.5)) })
                end
            end
        end
    end
    self:_RenderIfShown()
end

-- Remove exactly the marked test rows (children cascade with their character / quest).
function Dashboard:DevClearTestData()
    local db = self:DB(); if not db then return end
    db:Delete("dashboard_char", function(r) return r.realm == DEV_REALM end)
    db:Delete("quest", function(r) return (r.quest_id or 0) >= DEV_QUEST_BASE end)
    self:_RenderIfShown()
end

-- Columns for one expansion's catalog (raids if isRaid, else dungeons; defaults to the current
-- expansion) -- sourced from the seeded dashboard_instance table. With raids seeded one row per
-- difficulty, this yields a column per (instance, difficulty); the cell is that character's lock.
function Dashboard:_CatalogColumns(tierName, isRaid)
    tierName = tierName or self:_p().currentExpansion
    return self:_LockoutColumns(function(r)
        return (r.isRaid and true or false) == isRaid and (r.expansion or "Other") == tierName
    end)
end

-- One column per current-season dungeon; cell = the character's Mythic 0 lock ("x/y") or "-".
function Dashboard:_SeasonColumns()
    local s = self:_p().catalog:_SeasonDungeons()
    if not s then return {} end
    local cols = {}
    for _, name in ipairs(s.list) do
        local dname = name
        cols[#cols + 1] = { label = dname, width = 130, cell = function(e)
            for _, l in ipairs(e.lockouts or {}) do
                if l.name == dname and l.diff == M0 then return (l.progress or 0) .. "/" .. (l.total or "?") end
            end
            return "-"
        end }
    end
    return cols
end

-- Columns from the seeded instance catalog, filtered by predicate(registryEntry). Each cell is the
-- character's CURRENT lock for that instance+difficulty (boss progress) or "-" when not locked.
-- Ordered by instance name, then by difficulty RANK (LFR < Normal < Heroic < Mythic) so a raid's
-- difficulty columns read in ascending order rather than alphabetically.
function Dashboard:_LockoutColumns(predicate)
    local cols = {}
    for _, r in pairs(self:_p().charStore:Instances()) do
        if predicate(r) then
            local name, diff, total = r.name, r.diff, r.total
            cols[#cols + 1] = { label = diff and (name .. " (" .. diff .. ")") or name,
                _name = name, _rank = (DIFF[diff] and DIFF[diff].rank) or 0,
                width = 110, cell = function(e)
                    for _, l in ipairs(e.lockouts or {}) do
                        if l.name == name and l.diff == diff then
                            return (l.progress or 0) .. "/" .. (l.total or total or "?")
                        end
                    end
                    return "-"
                end }
        end
    end
    table.sort(cols, function(a, b)
        if a._name ~= b._name then return a._name < b._name end
        return a._rank < b._rank
    end)
    return cols
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

    local f = W.Window:New(100, { name = "HagAIODashboard", width = 860, height = 520,
        strata = "HIGH", title = "Dashboard", onClose = function() self:Hide() end,
        autoClose = true,
        onAutoShow = function() self:Show() end,
        onAutoHide = function() self:Hide() end })
    -- Hiding the window (X / Esc / combat auto-hide / toggle) hides every page's tiles + textures, so
    -- WoW frees their VRAM on its own; reopening shows them again (reloads instantly). No manual release.
    f:SetScript("OnHide", function() self:_p().shown = false end)
    p.frame = f

    -- left rail: character card + category nav grid
    local rail = W.Panel:New(f:Body(), "bg0", "border")
    rail:SetWidth(RAIL_W)
    rail:SetPoint("TOPLEFT", 0, 0)
    rail:SetPoint("BOTTOMLEFT", 0, 0)

    -- character card: avatar (framed portrait widget) + name / level-ilvl / rating.
    local avFrame = W.Avatar:New(rail, AVATAR)
    avFrame:SetPoint("TOPLEFT", 14, -14)
    p.avatar = avFrame

    local hName = W.Text:New(rail, "", "text", "GameFontNormal")
    hName:SetPoint("TOPLEFT", avFrame, "TOPRIGHT", 10, -1)
    hName:SetWidth(RAIL_W - AVATAR - 30); hName:SetJustifyH("LEFT"); hName:SetWordWrap(false)
    local hInfo = W.Text:New(rail, "", "textDim", "GameFontHighlightSmall")
    hInfo:SetPoint("TOPLEFT", hName, "BOTTOMLEFT", 0, -5)
    local hRating = W.Text:New(rail, "", "accent", "GameFontHighlightSmall")
    hRating:SetPoint("TOPLEFT", hInfo, "BOTTOMLEFT", 0, -3)
    p.hName, p.hInfo, p.hRating = hName, hInfo, hRating

    local div = W.Divider:New(rail)
    div:SetPoint("TOPLEFT", avFrame, "BOTTOMLEFT", 0, -14)
    div:SetPoint("RIGHT", rail, "RIGHT", -12, 0)

    -- the category tree is a Navigation widget; selecting a category re-renders the data grid
    local nav = W.Nav:New(rail, {
        items = self:_NavItems(),
        scroll = true, name = "HagAIODashboardNav",   -- themed scrollbar; bounded to the rail
        cellPad = 7,   -- 3px bar + 4px gap, so the label clears the active bar
        onSelect = function(key)
            p.category = key
            self:_Render()
            if p.grid then p.grid:ScrollTop() end   -- a new category starts at the top
        end,
        -- clicking the already-selected category returns to the Overview (Home)
        onReselect = function() p.nav:Select("home") end,
    })
    nav:SetPoint("TOPLEFT", div, "BOTTOMLEFT", 6, -10)
    nav:SetPoint("BOTTOMRIGHT", rail, "BOTTOMRIGHT", -6, 8)
    p.nav = nav

    -- content: reset header + category title + the data grid
    local content = W.Panel:New(f:Body(), "panel", "border")
    content:SetPoint("TOPLEFT", rail, "TOPRIGHT", 1, 0)
    content:SetPoint("BOTTOMRIGHT", f:Body(), "BOTTOMRIGHT", 0, 0)
    p.contentPanel = content   -- the icon-grid PAGES (see _IconPage) anchor over the data-grid area

    local resetHdr = W.Text:New(content, "", "textDim", "GameFontHighlightSmall")
    resetHdr:SetPoint("TOPLEFT", 16, -12); resetHdr:SetPoint("RIGHT", content, "RIGHT", -16, 0)
    resetHdr:SetJustifyH("LEFT")
    p.resetHdr = resetHdr

    local catTitle = W.Text:New(content, "", "text", "GameFontNormalLarge")
    catTitle:SetPoint("TOPLEFT", resetHdr, "BOTTOMLEFT", 0, -10)
    p.catTitle = catTitle

    local grid = W.Grid:New(content, { name = "HagAIODashboardGrid", header = true, striped = true })
    grid:SetPoint("TOPLEFT", catTitle, "BOTTOMLEFT", 0, -12)
    grid:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -10, 12)
    p.grid = grid

    -- the overviews are journal-style icon grids shown over the same area as the data grid. Each
    -- overview (home / raids / dungeons) is its OWN cached page (see _IconPage), built lazily.
    p.iconPages = {}

    p.built = true
    p.nav:Select(p.category)   -- highlight the default category + render it via onSelect
end

-- Is a category enabled in the settings? Dynamic "raid:<exp>"/"quest:<exp>" keys follow their toggle.
function Dashboard:_CategoryVisible(key)
    if key:match("^raid:") then return self:GetSetting("show_raids") ~= false end
    if key == "quests" or key:match("^quest:") then return self:GetSetting("show_quests") ~= false end
    return self:GetSetting("show_" .. key) ~= false
end

-- The navigation items: a section header per group, a selectable (indented) item otherwise.
-- Categories the player has hidden in the settings are skipped, and a section header with no
-- visible items beneath it is dropped.
function Dashboard:_NavItems()
    local cat = self:_p().category or ""
    -- expansion sub-nodes stay COLLAPSED until that category (or one of its sub-keys) is active
    local raidsOpen = cat == "raids" or cat:match("^raid:") ~= nil
    local dungeonsOpen = cat == "dungeons" or cat:match("^dungeon:") ~= nil
    local questsOpen = cat == "quests" or cat:match("^quest:") ~= nil
    local items = { { key = "home", label = HOME_LABEL } }   -- "Overview" Home entry, above everything
    for _, c in ipairs(CATEGORIES) do
        if c.header then
            items[#items + 1] = { section = c.label }
        elseif self:_CategoryVisible(c.key) then
            items[#items + 1] = { key = c.key, label = c.label, indent = c.indent and 1 or 0 }
            -- a deeper sub-node per expansion, only while this category is open (collapsible tree)
            if c.key == "raids" and raidsOpen then
                -- Current Season first (the live season's raids), then one node per expansion. The nav
                -- stops here: a raid's lockouts open INLINE on its tile, not as a deeper nav level.
                if self:_p().catalog:_HasSeasonRaids() then
                    items[#items + 1] = { key = "raid:current", label = SEASON_LABEL, indent = 2 }
                end
                for _, exp in ipairs(self:_p().catalog:_RaidExpansions()) do      -- all raid tiers (full catalog)
                    items[#items + 1] = { key = "raid:" .. exp, label = exp, indent = 2 }
                end
            elseif c.key == "dungeons" and dungeonsOpen then
                if self:_p().catalog:_SeasonDungeons() then
                    items[#items + 1] = { key = "dungeon:current", label = SEASON_LABEL, indent = 2 }
                end
                -- Current Expansion (all its dungeons), auto-named; then the remaining expansions
                local curTier = self:_p().catalog:_CurrentExpansionTier()
                if curTier then
                    items[#items + 1] = { key = "dungeon:" .. curTier, label = self:_p().catalog:_CurrentExpansionName() or curTier, indent = 2 }
                end
                for _, exp in ipairs(self:_p().catalog:_KnownExpansions(false)) do
                    if exp ~= SEASON_LABEL and exp ~= curTier then
                        items[#items + 1] = { key = "dungeon:" .. exp, label = exp, indent = 2 }
                    end
                end
            elseif c.key == "quests" and questsOpen then
                -- one node per expansion that has RECORDED quests (self-curating, newest first)
                for _, exp in ipairs(self:_QuestExpansions()) do
                    items[#items + 1] = { key = "quest:" .. exp, label = exp, indent = 1 }
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

-- Resolve a nav key to (title, columns()). "raids"/"dungeons" show every known instance of that
-- kind; "raid:<exp>"/"dungeon:<exp>" filter to one expansion; the rest are static CATEGORIES.
function Dashboard:_ResolveCategory(key)
    if key == "raids" then
        return "Raids", function() return self:_CatalogColumns(nil, true) end       -- current tier
    elseif key == "dungeons" then
        return "Dungeons", function() return self:_CatalogColumns(nil, false) end    -- current expansion
    end
    -- a single raid drilled into from its expansion's tile grid: every difficulty of just that raid
    -- "raid:current" / "raid:<exp>" are icon pages (resolved in _Render); the label here is only a
    -- fallback. Lockouts open inline on a raid tile, so there's no per-raid columns key any more.
    if key == "raid:current" then return SEASON_LABEL, function() return {} end end
    -- quest pages are icon pages too (expansion overview / zone grid / a zone's quests)
    if key == "quests" then return "Quests", function() return {} end end
    local qexp = key and key:match("^quest:([^|]+)")
    if qexp then return qexp .. " Quests", function() return {} end end
    local rexp = key and key:match("^raid:(.+)$")
    if rexp then
        return rexp .. " Raids", function() return self:_CatalogColumns(rexp, true) end
    end
    local dexp = key and key:match("^dungeon:(.+)$")
    if dexp == "current" then
        return SEASON_LABEL, function() return self:_SeasonColumns() end
    elseif dexp and dexp == self:_p().catalog:_CurrentExpansionTier() then
        -- the current expansion: every dungeon released in it (the full journal catalog)
        return (self:_p().catalog:_CurrentExpansionName() or dexp) .. " Dungeons",
            function() return self:_CatalogColumns(dexp, false) end
    elseif dexp then
        -- every dungeon of this expansion, INCLUDING any in the current M+ season (they also appear
        -- under Current Season -- a season dungeon legitimately shows under both).
        return dexp .. " Dungeons", function()
            return self:_LockoutColumns(function(r)
                return not r.isRaid and (r.expansion or "Other") == dexp
            end)
        end
    end
    for _, c in ipairs(CATEGORIES) do
        if c.key == key then return c.label, c.columns end
    end
    return CATEGORIES[1].label, CATEGORIES[1].columns
end

-- Sorted character keys: the current character first, then alphabetical.
function Dashboard:_SortedChars()
    local chars = self:_p().charStore:Chars()
    local selfKey = self:_p().charStore:SelfKey()
    local keys = {}
    for k in pairs(chars) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if (a == selfKey) ~= (b == selfKey) then return a == selfKey end
        return a < b
    end)
    return keys, chars
end

-- The Home overview tiles: one per top-level category (image + name), 3 per row. Raids/Dungeons
-- use the latest instance art; the quest/keystone categories use a contained native icon. Hidden
-- categories (settings) are skipped. Clicking a tile selects that category in the nav.
function Dashboard:_CategoryTiles()
    local p = self:_p()
    local function go(key) return function() p.nav:Select(key) end end
    -- First atlas in the list that actually EXISTS on this client. Atlases are transparent + drawn from
    -- high-res sheets, so they stay crisp blown up to a big tile (unlike the 64x64 Interface\Icons).
    -- nil if none resolve -> the tile falls back to the category's native icon (no regression).
    local function atlas(...)
        if not (C_Texture and C_Texture.GetAtlasInfo) then return nil end
        for _, a in ipairs({ ... }) do if C_Texture.GetAtlasInfo(a) then return a end end
    end
    local logo = self:_p().catalog:_ExpansionLogo(self:_p().catalog:CurrentExpansion())
    local raidArt = self:_p().catalog:_LatestRaidArt()
    local dunArt = self:_p().catalog:_SeasonDungeonArt() or self:_p().catalog:_LatestDungeonArt()
    local defs = {
        { key = "mplus",    label = "Mythic+",       contain = true,
          atlas = atlas("Mythic-Plus-Logo", "ChallengeMode-icon-Chest", "questlog-questtypeicon-Dungeon",
                        "Dungeon-Banner", "GreatVault-32x32"),
          texture = "Interface\\Icons\\Achievement_ChallengeMode_Gold" },
        { key = "raids",    label = "Raids",         art = raidArt, fallback = logo },
        { key = "dungeons", label = "Dungeons",      art = dunArt,  fallback = logo },
        -- custom high-res transparent art (tools/gen_quest_icons.py): a "!" with revolving arrows --
        -- crisp at any tile size, unlike the atlases. One tile: quests group by expansion -> zone inside.
        { key = "quests",   label = "Quests", contain = true,
          texture = "Interface\\AddOns\\HagAIO\\Media\\quest-weekly" },
    }
    local tiles = {}
    for _, d in ipairs(defs) do
        if self:_CategoryVisible(d.key) then
            local tile = { label = d.label, contain = d.contain, onClick = go(d.key) }
            if d.atlas then tile.texture, tile.atlas = d.atlas, true   -- transparent high-res atlas (contain)
            elseif d.art then applyArt(tile, d.art)                    -- raids/dungeons: the instance scene
            else tile.texture = d.texture or d.fallback end            -- native icon fallback
            tiles[#tiles + 1] = tile
        end
    end
    return tiles
end

-- The overview's icon tiles: one per expansion (native logo + name), clicking drills into that
-- expansion's data grid. "raids" lists every raid tier; "dungeons" lists Current Season, the
-- current expansion, then the legacy expansions we hold dungeon records for.
function Dashboard:_OverviewTiles(key)
    local p = self:_p()
    local tiles = {}
    local function tile(label, logoTier, navKey)
        tiles[#tiles + 1] = {
            texture = self:_p().catalog:_ExpansionLogo(logoTier),
            label = label,
            onClick = function() p.nav:Select(navKey) end,
        }
    end
    if key == "raids" then
        -- Current Season first (the live season's raids, by flag -- distinct from any one expansion),
        -- pictured with the newest season raid's scene; then one tile per expansion.
        if self:_p().catalog:_HasSeasonRaids() then
            tiles[#tiles + 1] = {
                texture = self:_p().catalog:_ExpansionLogo(self:_p().catalog:CurrentExpansion()),
                label = SEASON_LABEL,
                onClick = function() p.nav:Select("raid:current") end,
            }
            local art = self:_p().catalog:_LatestSeasonRaidArt()
            if art then applyArt(tiles[#tiles], art) end
        end
        -- every expansion shows its BANNER (the latest-raid picture is the Current Season tile's job now)
        for _, exp in ipairs(self:_p().catalog:_RaidExpansions()) do
            tile(exp, exp, "raid:" .. exp)
        end
    elseif key == "dungeons" then
        local curTier = self:_p().catalog:_CurrentExpansionTier()
        if self:_p().catalog:_SeasonDungeons() then
            -- The Current Season's title stays "Current Season"; its expansion/logo is derived from
            -- the dungeons in it -- the newest expansion represented (a season can fold in legacy
            -- dungeons). Falls back to the current expansion / newest raid tier before the map loads.
            local seasonTier = self:_p().catalog:_SeasonExpansionTier() or curTier or self:_p().catalog:CurrentExpansion()
            tile(SEASON_LABEL, seasonTier, "dungeon:current")
            -- Current Season shows a random season-dungeon scene, distinct from the expansion logo
            local art = self:_p().catalog:_SeasonDungeonArt()
            if art then applyArt(tiles[#tiles], art) end
        end
        -- Current Expansion: every dungeon released in it (a superset of the M+ season). Auto-named
        -- and pictured from the live expansion -- the emblem, like the raid tiles use.
        if curTier then
            tiles[#tiles + 1] = {
                texture = self:_p().catalog:_CurrentExpansionLogo() or self:_p().catalog:_ExpansionLogo(curTier),
                label = self:_p().catalog:_CurrentExpansionName() or curTier,
                onClick = function() p.nav:Select("dungeon:" .. curTier) end,
            }
        end
        -- one tile per remaining expansion (skip the "Current Season" pseudo-tier and the current one)
        for _, exp in ipairs(self:_p().catalog:_KnownExpansions(false)) do
            if exp ~= SEASON_LABEL and exp ~= curTier then tile(exp, exp, "dungeon:" .. exp) end
        end
    end
    return tiles
end

-- Lazily create + cache the icon-grid PAGE for an overview key. home / raids / dungeons each get their
-- OWN grid (anchored over the data-grid area, hidden until shown), so switching between overviews is a
-- show/hide -- the page's tiles + textures persist and are reused as a whole. Home packs 3 per row,
-- the instance overviews 4. Hiding the window hides each page's tiles + textures, so WoW frees the VRAM.
function Dashboard:_IconPage(key)
    local p = self:_p()
    local g = p.iconPages[key]
    if g then return g end
    g = W.IconGrid:New(p.contentPanel, { name = "HagAIODashboardIcons_" .. key, perRow = (key == "home") and 3 or 4 })
    g:SetPoint("TOPLEFT", p.catTitle, "BOTTOMLEFT", 0, -12)
    g:SetPoint("BOTTOMRIGHT", p.contentPanel, "BOTTOMRIGHT", -10, 12)
    g:Hide()
    p.iconPages[key] = g
    return g
end

-- Delete an overview page: hide it (frees its textures' VRAM) and forget it (rebuilt lazily if shown).
function Dashboard:DeletePage(key)
    local p = self:_p()
    local g = p.iconPages and p.iconPages[key]
    if not g then return end
    g:Hide()
    p.iconPages[key] = nil
end

function Dashboard:_Render()
    local p = self:_p()
    if not p.built then return end
    self:_UpdateHeader()
    self:_UpdateCountdown()
    -- NOTHING heavy here: _Render runs on every open and every in-page expand toggle, so the Encounter
    -- Journal walk (_ExpansionMap) + catalog seed + keystone fill all live on the DEFERRED refresh pass
    -- (_BuildCatalog, queued by C_Timer after the loading screen). Render off whatever's cached; when the
    -- deferred build finishes it snapshots and re-renders, so the tiles fill in a frame later.

    local items = self:_NavItems()
    -- keep the selection valid: if the active category was hidden, fall back to the first one.
    -- A page-only drill key ("<navKey>|<sub>") is valid while its PARENT nav key is.
    local navKey = p.category:match("^(.-)|") or p.category
    local valid
    for _, it in ipairs(items) do if it.key == navKey then valid = true; break end end
    if not valid then
        for _, it in ipairs(items) do if it.key then p.category = it.key; navKey = it.key; break end end
    end
    p.nav:SetItems(items)
    p.nav:Select(navKey, true)           -- highlight the parent for a drill key; silent

    local keys, chars = self:_SortedChars()
    local label, columnsFn = self:_ResolveCategory(p.category)

    -- the Home/Raids/Dungeons overviews are journal-style icon grids, not the data grid. Each is its
    -- OWN cached page: switching between them just shows one and hides the rest -- the tiles and their
    -- textures stay loaded and aren't re-edited (each tile's Texture widget memoises unchanged art).
    -- a "raid:<group>" / "dungeon:<group>" key is itself an icon grid -- the raids / dungeons of that
    -- group as tiles, each with its own art, the lockouts opening inline -- one level below the overview.
    local raidExp = p.category:match("^raid:([^|]+)$")
    local dunGrp  = p.category:match("^dungeon:([^|]+)$")
    local questExp, questZone = p.category:match("^quest:([^|]+)|(.+)$")
    if not questExp then questExp = p.category:match("^quest:([^|]+)$") end
    if p.category == "home" or p.category == "raids" or p.category == "dungeons"
        or p.category == "quests" or raidExp or dunGrp or questExp then
        p.grid:Hide()
        local page = self:_IconPage(p.category)
        for _, g in pairs(p.iconPages) do g:SetShown(g == page) end
        if p.category == "home" then
            p.catTitle:SetText("Overview")
            page:SetTiles(self:_CategoryTiles())
        elseif raidExp == "current" then
            p.catTitle:SetText(SEASON_LABEL)
            self:_ShowInstancePage(page, self:_p().catalog:_SeasonRaidNames(), self:_p().catalog:CurrentExpansion(), true)
        elseif raidExp then
            p.catTitle:SetText(raidExp .. " Raids")
            self:_ShowInstancePage(page, self:_p().catalog:_RaidsInExpansion(raidExp), raidExp, true)
        elseif dunGrp == "current" then
            p.catTitle:SetText(SEASON_LABEL)
            self:_ShowInstancePage(page, self:_p().catalog:_SeasonDungeonNames(), self:_p().catalog:_SeasonExpansionTier() or self:_p().catalog:CurrentExpansion(), false)
        elseif dunGrp then
            local cur = self:_p().catalog:_CurrentExpansionTier()
            p.catTitle:SetText(((dunGrp == cur and (self:_p().catalog:_CurrentExpansionName() or dunGrp)) or dunGrp) .. " Dungeons")
            self:_ShowInstancePage(page, self:_p().catalog:_DungeonsInExpansion(dunGrp), dunGrp, false)
        elseif p.category == "quests" then
            p.catTitle:SetText("Quests")
            page:SetTiles(self:_QuestExpansionTiles())
        elseif questExp and questZone then
            local zone = self:_QuestZoneByKey(questExp, questZone)
            if zone then
                p.catTitle:SetText(zone.name .. "  -  " .. questExp)
                self:_ShowQuestPage(page, questExp, zone)
            else                                       -- stale zone key -> back to the zone overview
                p.category = "quest:" .. questExp
                p.catTitle:SetText(questExp .. " Quests")
                self:_ShowQuestZonesPage(page, questExp)
            end
        elseif questExp then
            p.catTitle:SetText(questExp .. " Quests")
            self:_ShowQuestZonesPage(page, questExp)
        else
            p.catTitle:SetText(label)
            page:SetTiles(self:_OverviewTiles(p.category))
        end
        if p.lastIconCategory ~= p.category then page:ScrollTop() end   -- keep scroll on an in-page expand toggle
        p.lastIconCategory = p.category
        return
    end
    p.lastIconCategory = nil
    p.catTitle:SetText(label)
    for _, g in pairs(p.iconPages) do g:Hide() end   -- data grid view: hide every icon page
    p.grid:Show()

    local cols = (columnsFn and columnsFn(chars)) or {}
    local columns, rows = self:_BuildLockoutGrid(cols)
    p.grid:SetColumns(columns)
    p.grid:SetRows(rows)
end

-- Build (columns, rows) for a character-lockout grid: a sticky Character column + one per `cols`
-- entry; one row per character (class-coloured name, then each column's cell, "-" tinted faint).
-- Shared by the main data grid and the inline raid-detail panel so they read identically.
function Dashboard:_BuildLockoutGrid(cols)
    local columns = { { width = NAME_COL, label = "Character" } }
    for _, c in ipairs(cols) do
        columns[#columns + 1] = { width = c.width, label = c.label, justify = "CENTER" }   -- values under centred headers
    end
    local keys, chars = self:_SortedChars()
    local rows = {}
    for _, key in ipairs(keys) do
        local e = chars[key]
        local cells = { e.name or key }
        for _, c in ipairs(cols) do cells[#cells + 1] = c.cell(e) or "-" end
        local cc = e.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.class]
        local nameColor = cc and { cc.r, cc.g, cc.b } or "text"
        rows[#rows + 1] = { cells = cells, cellColor = function(ci)
            if ci == 1 then return nameColor end
            return self:_ProgressColor(cells[ci])
        end }
    end
    return columns, rows
end

-- Colour a lockout cell by what it MEANS, so state reads before words: "-" recedes (no lock),
-- a full clear ("8/8") is green, a partial lock amber, an untouched lock ("0/8") dim.
-- Non-progress values (keystone names, ratings) stay plain text.
function Dashboard:_ProgressColor(s)
    if s == "-" or s == nil or s == "" then return "textFaint" end
    local cur, tot = tostring(s):match("^(%d+)%s*/%s*(%d+)$")
    if not cur then return "text" end
    cur, tot = tonumber(cur), tonumber(tot)
    if tot and tot > 0 and cur >= tot then return "green" end
    if cur and cur > 0 then return "amber" end
    return "textDim"
end

function Dashboard:_UpdateHeader()
    local p = self:_p()
    local chars = self:_p().charStore:Chars()
    local e = chars[self:_p().charStore:SelfKey()]
    if not e then return end
    p.hName:SetText(e.name or "?")
    local cc = e.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.class]
    if cc then p.hName:SetTextColor(cc.r, cc.g, cc.b) end
    p.hInfo:SetText(("Level %s   iLvl %s"):format(tostring(e.level or "-"), tostring(e.ilvl or "-")))
    p.hRating:SetText(e.rating and ("Mythic+ " .. e.rating) or "")
    if p.avatar then p.avatar:SetPortrait("player") end   -- the viewing character's portrait
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
    self:_Render()                                     -- cheap paint off the cached catalog; no refresh --
                                                       -- the catalog is built once at login and the live
                                                       -- character's data is kept current by events
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
    -- Secrets / Worker are accessed by the collaborators, not textually in this file after the
    -- data-layer + catalog extractions: Secrets by the CharacterStore (its vault/lockout plainNum
    -- guard), Worker by the ExpansionCatalog (ns.Worker:Mark/:MaybeYield through the build). This file
    -- still drives both via self:Queue / self:WorkOn (the Worker-backed Module scheduling API), so the
    -- load-order deps are required even though depcheck can't see the use.
    -- hag-lint-disable depcheck: Secrets, Worker
    deps = { "SlashCommand", "Secrets", "Worker", "Versioning" },   -- DatabaseManager is added automatically (see `tables`)
    -- Account-wide cross-character snapshots, stored relationally (no nested blobs, no duplicated
    -- reference data). Vault/lockout/quest cascade-delete with their character; a lockout references
    -- the account-wide dashboard_instance registry (its name/difficulty), a quest references the
    -- shared `quest` table (its title), and a keystone references the local keystone name table.
    tables = {
        -- The `keystone` reference table (map id -> display name) that dashboard_char.ks_mapid points
        -- at is defined CENTRALLY in Core/DB/CoreTables.lua, alongside faction/quest -- it's plain
        -- account-agnostic reference data, not owned by this module. The CharacterStore still fills it
        -- (CharacterStore:SetKeystone / :SeedKeystones via self:DB()).
        dashboard_char = { scope = "global", columns = {
            { name = "char_key",  type = "text",    primaryKey = true },   -- "Name-Realm"
            { name = "name",      type = "text" },
            { name = "realm",     type = "text" },
            { name = "class",     type = "text" },                         -- class file (e.g. "MAGE")
            { name = "level",     type = "integer" },
            { name = "ilvl",      type = "integer" },
            { name = "last_seen", type = "integer" },                      -- server epoch seconds
            { name = "rating",    type = "number" },                       -- current-season M+ score
            { name = "ks_mapid",  type = "integer",                        -- owned keystone map (name via keystone)
                references = { table = "keystone", column = "mapid", onDelete = "cascade" } },
            { name = "ks_level",  type = "integer" },                      -- this character's keystone level
        } },
        dashboard_vault = { scope = "global",
            columns = {
                { name = "char_key",  type = "text", nullable = false,
                    references = { table = "dashboard_char", column = "char_key", onDelete = "cascade" } },
                { name = "ordinal",   type = "integer", nullable = false },   -- slot order within the character
                { name = "type",      type = "integer" },                     -- activity type
                { name = "level",     type = "integer" },
                { name = "progress",  type = "integer" },                     -- plain number only (secrets stored NULL)
                { name = "threshold", type = "integer" },
            },
            primaryKey = { "char_key", "ordinal" } },
        -- One row per (character, instance) lock. name/difficulty/is_raid live on dashboard_instance;
        -- this carries only the per-character lock state. Cascades from BOTH the character and the
        -- instance (a pruned instance drops its locks).
        dashboard_lockout = { scope = "global",
            columns = {
                { name = "char_key",     type = "text", nullable = false,
                    references = { table = "dashboard_char", column = "char_key", onDelete = "cascade" } },
                { name = "instance_key", type = "text", nullable = false,
                    references = { table = "dashboard_instance", column = "key", onDelete = "cascade" } },
                { name = "progress",     type = "integer" },                  -- bosses killed (plain number only)
                { name = "total",        type = "integer" },                  -- boss count
                { name = "reset",        type = "integer" },                  -- lockout reset epoch
            },
            primaryKey = { "char_key", "instance_key" } },
        -- One row per (character, freq, quest). The title lives on the shared `quest` table.
        -- `done_at` (server epoch of the LAST turn-in) is what makes "done" reset-aware: a cell only
        -- counts as done while done_at falls inside the current daily/weekly window (_QuestDone).
        dashboard_quest = { scope = "global",
            columns = {
                { name = "char_key", type = "text", nullable = false,
                    references = { table = "dashboard_char", column = "char_key", onDelete = "cascade" } },
                { name = "freq",     type = "text",    nullable = false },    -- "daily" | "weekly"
                { name = "quest_id", type = "integer", nullable = false,
                    references = { table = "quest", column = "quest_id", onDelete = "cascade" } },
                { name = "done_at",  type = "integer" },                      -- server epoch of last turn-in
            },
            primaryKey = { "char_key", "freq", "quest_id" } },
        -- Account-wide expansion registry (one row per Encounter Journal tier, e.g. "Midnight",
        -- "The War Within"). The "Current Season" tier is NOT an expansion -- it's a flag on the
        -- instances (current_season), not a row here. Each row carries the banner logo (a fileID
        -- from GetExpansionDisplayInfo) the tiles display. dashboard_instance.expansion references it
        -- and cascade-deletes with it, so retiring an expansion drops its raids/dungeons.
        expansion = { scope = "global", columns = {
            { name = "name",  type = "text", primaryKey = true },             -- journal tier name
            { name = "level", type = "integer" },                            -- expansion level (logo lookup + ordering)
            { name = "logo",  type = "integer" },                            -- banner fileID (GetExpansionDisplayInfo)
        } },
        -- The catalog's build/patch stamp is NOT stored here -- it lives in the shared `data_version`
        -- registry owned by ns.Versioning (keyed by domain "dashboard_catalog"). The whole Encounter
        -- Journal catalog is static within a PATCH, so once saved we reconstruct the runtime maps from
        -- dashboard_instance on login and only re-walk the journal when ns.Versioning reports a new build.
        dashboard_instance = { scope = "global", columns = {
            { name = "key",         type = "text", primaryKey = true },       -- "instanceID|difficultyID"
            { name = "instance_id", type = "integer" },                       -- EJ journal instance id (the identity; same name can repeat)
            { name = "lore_id",     type = "integer" },                       -- EJ loreImage fileID (splash art) -- persisted so the journal need not be re-walked
            { name = "button_id",   type = "integer" },                       -- EJ buttonImage1 fileID (banner art)
            { name = "ord",         type = "integer" },                       -- journal order within its tier (tile ordering)
            { name = "name",      type = "text" },
            { name = "diff",      type = "text" },
            { name = "is_raid",   type = "boolean" },
            { name = "diff_id",   type = "integer" },                         -- locale-proof difficulty id (drives the prune)
            { name = "total",     type = "integer" },
            { name = "expansion", type = "text",                              -- home expansion (FK; null until the journal map is known)
                references = { table = "expansion", column = "name", onDelete = "cascade" } },
            { name = "current_season", type = "boolean", default = false },   -- in the live raid / M+ season
        } },
    },
    commands = {
        dashboard = { handler = "Toggle", help = "open the cross-character Dashboard" },
    },
    settings = {
        { type = "header", text = "Categories" },
        { type = "toggle", key = "show_mplus",    label = "Mythic+",       default = true },
        { type = "toggle", key = "show_raids",    label = "Raids",         default = true },
        { type = "toggle", key = "show_dungeons", label = "Dungeons",      default = true },
        { type = "toggle", key = "show_quests",   label = "Quests",        default = true },
        { type = "note", text = "Choose which categories appear in the Dashboard. Open it with /hag dashboard." },
    },
}))
