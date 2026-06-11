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
local RAID_DIFF_CANDIDATES = { 7, 17, 3, 4, 9, 148, 14, 5, 6, 15, 16 }
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

-- The raid list's world-boss / world-event meta entries aren't real raids but carry no lockout. The
-- name==tier check in _ExpansionMap catches the ones named after the expansion; these are named after
-- the CONTINENT (Dragon Isles / Khaz Algar / Broken Isles) or a world EVENT (Legion's "Invasion
-- Points"), so map each to its tier to drop it too. (enUS, like the other journal labels.)
local WORLD_RAID_ALIASES = {
    ["Dragon Isles"]    = "Dragonflight",
    ["Khaz Algar"]      = "The War Within",
    ["Broken Isles"]    = "Legion",
    ["Invasion Points"] = "Legion",
}

-- The Encounter Journal crops its instance buttonImage1 art to this region (the rest is padding);
-- see Blizzard_EncounterJournal.xml "EncounterInstanceButtonTemplate" bgImage TexCoords. We reuse
-- it so our instance tiles fill the same way the journal's do (only used for the low-def banner
-- fallback, when an instance has no full-bleed scene).
local EJ_TILE_TC = { 0, 0.68359375, 0, 0.7421875 }
-- The banner crop lands on the art region but still carries a little padding, so we zoom in a touch
-- (zoom = fraction of the region shown; 0.8 = 20% in) to eat it. See Widgets.Texture for the model.
local EJ_TILE_ZOOM = 0.8
-- The instance SPLASH (loreImage) -- the big scene the journal shows on the RIGHT when you open an
-- instance. It's a 1024x1024 (square) file with the art in the top-left ~76% x 66%; the right and
-- bottom are transparent padding (the journal crops to {0,0.7617,0,0.65625}). The cover-fit treats
-- the whole square file, then we zoom in and pan UP-LEFT onto the art region. Zoom = fraction of the
-- fitted region shown (1.0 = as-is, <1 = zoom in, >1 = zoom out); pan is in texcoord units (- = up/left).
local EJ_LORE_ASPECT = 1
local EJ_LORE_ZOOM   = 0.65
local EJ_LORE_PAN_X  = -0.12
local EJ_LORE_PAN_Y  = -0.23

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
    { key = "questhdr", label = "Quests",   header = true },
    -- recorded weekly/daily turn-ins, grouped expansion -> zone (auto-discovered at turn-in);
    -- "quest:<exp>" sub-keys (added in _NavItems while open) show that expansion's zone tiles,
    -- each zone expanding its quest x character matrix inline -- the dungeon-page pattern.
    { key = "quests", label = "All Expansions", indent = true },
}

-- ---- lifecycle ------------------------------------------------------------
function Dashboard:OnInitialize()
    local p = self:_p()
    p.built = false
    p.shown = false
    p.category = "home"   -- open on the overview (an icon grid of every category)
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
    self:WorkOn("PLAYER_ENTERING_WORLD",  function() self:_RefreshNow() end, { label = "Dashboard refresh" })
    self:On("PLAYER_LOGOUT",              function() self:_Snapshot() end)   -- inline: must finish before logout
    self:On("WEEKLY_REWARDS_UPDATE",      function() self:_CollectVault();    self:_RenderIfShown() end)
    self:On("CHALLENGE_MODE_COMPLETED",   function() self:_CollectKeystone(); self:_RenderIfShown() end)
    self:On("CHALLENGE_MODE_MAPS_UPDATE", function() self:_CollectKeystone(); self:_RenderIfShown() end)
    self:On("BAG_UPDATE_DELAYED",         function() self:_CollectKeystone(); self:_RenderIfShown() end)
    self:On("UPDATE_INSTANCE_INFO",       function() self:_CollectLockouts(); self:_RenderIfShown() end)
    self:On("BOSS_KILL",                  function() self:_CollectLockouts() end)
    self:On("QUEST_TURNED_IN",            function(_, questID) self:_RecordQuest(questID) end)
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

-- Only a plain number is allowed into the typed columns: ns.Secrets:Number returns nil for a SECRET
-- value (restricted content), so a secret is stored as NULL rather than smuggled in as a non-scalar.
local function plainNum(v)
    if ns.Secrets then return ns.Secrets:Number(v) end   -- nil for a secret
    return v
end

function Dashboard:_SelfKey()
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
    return Ledger:CharKey(UnitName("player"), realm)
end

-- The raw dashboard_char row for a key (or nil).
function Dashboard:_CharRow(key)
    local db = self:DB(); if not db then return nil end
    return db:Select("*"):From("dashboard_char"):Where("char_key", "=", key):Limit(1):Run()[1]
end

-- Upsert the viewing character's dashboard_char row, merging `changes` and stamping last_seen. Ensures
-- the row EXISTS first, so the child tables' FKs (vault/lockout/quest -> char) always resolve. This is
-- the relational stand-in for the old _SelfEntry() (which lazily created the nested entry + lastSeen).
function Dashboard:_SetSelf(changes)
    local db = self:DB(); if not db then return end
    local key = self:_SelfKey()
    changes = changes or {}
    changes.last_seen = (GetServerTime and GetServerTime()) or time()
    if self:_CharRow(key) then db:Update("dashboard_char", changes, { char_key = key })   -- PK map: index lookup
    else changes.char_key = key; db:Insert("dashboard_char", changes) end
end

-- Replace ALL of the viewing character's rows in a child table (dashboard_vault / dashboard_lockout)
-- with `rows` (each a column map already carrying the rest of its PK -- vault an `ordinal`, lockout an
-- `instance_key`). Delete-then-insert mirrors the old whole-substructure replacement.
function Dashboard:_ReplaceSelfChildren(tname, rows)
    local db = self:DB(); if not db then return end
    local key = self:_SelfKey()
    db:Delete(tname, { char_key = key })   -- PK-member map: index lookup, no scan
    if #rows == 0 then return end
    for _, r in ipairs(rows) do r.char_key = key end
    db:InsertAll(tname, rows)
end

-- Reconstruct every character's snapshot as a document keyed by char_key (one query per table; the
-- children + reference rows are bucketed in memory). The reference tables resolve the normalised
-- foreign keys back into the document fields the renderers read (keystone name, lockout instance
-- name/difficulty, quest title). Mirrors the old chars[key] = { ... nested ... } map exactly.
function Dashboard:_Chars()
    local db = self:DB(); if not db then return {} end
    local ksName, inst = {}, self:_Instances()
    for _, k in ipairs(db:Select("*"):From("keystone"):Run()) do ksName[k.mapid] = denull(k.name) end

    local chars = {}
    for _, c in ipairs(db:Select("*"):From("dashboard_char"):Run()) do
        local doc = {
            name = denull(c.name), realm = denull(c.realm), class = denull(c.class),
            level = denull(c.level), ilvl = denull(c.ilvl),
            lastSeen = denull(c.last_seen), rating = denull(c.rating),
            lockouts = {}, vault = { slots = {} }, quests = {},
        }
        local mapid = denull(c.ks_mapid)
        if mapid then doc.keystone = { mapID = mapid, level = denull(c.ks_level), name = ksName[mapid] } end
        chars[c.char_key] = doc
    end
    for _, v in ipairs(db:Select("*"):From("dashboard_vault"):Run()) do
        local doc = chars[v.char_key]
        if doc then
            local s = doc.vault.slots
            s[#s + 1] = { type = denull(v.type), level = denull(v.level),
                progress = denull(v.progress), threshold = denull(v.threshold) }
        end
    end
    for _, l in ipairs(db:Select("*"):From("dashboard_lockout"):Run()) do
        local doc, ref = chars[l.char_key], inst[l.instance_key]
        if doc and ref then
            local lk = doc.lockouts
            lk[#lk + 1] = { name = ref.name, diff = ref.diff, isRaid = ref.isRaid,
                total = denull(l.total), progress = denull(l.progress), reset = denull(l.reset) }
        end
    end
    for _, q in ipairs(db:Select("*"):From("dashboard_quest"):Run()) do
        local doc = chars[q.char_key]
        if doc then
            doc.quests[q.freq] = doc.quests[q.freq] or {}
            -- the LAST turn-in moment (0 = legacy row, never counts as done); titles live on `quest`
            doc.quests[q.freq][q.quest_id] = denull(q.done_at) or 0
        end
    end
    return chars
end

-- Upsert the local keystone name table (map id -> display name); the keystone names are reference
-- data, rebuilt each session, that dashboard_char's ks_mapid FK points at.
function Dashboard:_SetKeystone(mapid, name)
    local db = self:DB(); if not (db and mapid) then return end
    if db:Select("mapid"):From("keystone"):Where("mapid", "=", mapid):Limit(1):Run()[1] then
        db:Update("keystone", { name = name }, { mapid = mapid })
    else db:Insert("keystone", { mapid = mapid, name = name }) end
end

-- Ensure the local keystone table has a name for every map id any character holds, so an alt's
-- keystone (its map id persists on dashboard_char, but the local name table is rebuilt each session)
-- still renders a name. Cheap: GetMapUIInfo resolves any map id offline.
function Dashboard:_SeedKeystones()
    ns.Worker:Mark("seed keystones")
    local db = self:DB(); if not db then return end
    if not (C_ChallengeMode and C_ChallengeMode.GetMapUIInfo) then return end
    for _, c in ipairs(db:Select("ks_mapid"):From("dashboard_char"):Run()) do
        local mapid = denull(c.ks_mapid)
        if mapid and not db:Select("mapid"):From("keystone"):Where("mapid", "=", mapid):Limit(1):Run()[1] then
            self:_SetKeystone(mapid, C_ChallengeMode.GetMapUIInfo(mapid))
        end
        ns.Worker:MaybeYield()
    end
end

-- Reconstruct the instance registry keyed by "name|difficulty". Read-only; the writers below mutate
-- dashboard_instance directly (the old code mutated this returned table in place).
function Dashboard:_Instances()
    local db = self:DB(); if not db then return {} end
    local out = {}
    for _, r in ipairs(db:Select("*"):From("dashboard_instance"):Run()) do
        out[r.key] = { id = denull(r.instance_id), name = denull(r.name), diff = denull(r.diff),
            isRaid = denull(r.is_raid), diffID = denull(r.diff_id), total = denull(r.total),
            expansion = denull(r.expansion), season = denull(r.current_season) and true or false }
    end
    return out
end

-- Upsert one dashboard_instance row (key = "name|difficulty"), merging `changes` (omitted keys keep
-- their stored value -- so a later sighting with a nil diffID/total never clobbers a known one).
function Dashboard:_SetInstance(key, changes)
    local db = self:DB(); if not db then return end
    local exists = db:Select("key"):From("dashboard_instance"):Where("key", "=", key):Limit(1):Run()[1]
    if exists then db:Update("dashboard_instance", changes, { key = key })
    else changes.key = key; db:Insert("dashboard_instance", changes) end
end

-- ---- collectors (each guarded so a missing API is a no-op, never an error) -
function Dashboard:_CollectInfo()
    local changes = {
        name  = UnitName("player"),
        realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName(),
        level = UnitLevel("player"),
    }
    local _, classFile = UnitClass("player")
    changes.class = classFile
    if GetAverageItemLevel then
        local _, equipped = GetAverageItemLevel()
        if equipped then changes.ilvl = math.floor(equipped + 0.5) end   -- else keep the stored ilvl
    end
    self:_SetSelf(changes)
end

function Dashboard:_CollectKeystone()
    local changes = {}
    local mapID = C_MythicPlus and C_MythicPlus.GetOwnedKeystoneMapID and C_MythicPlus.GetOwnedKeystoneMapID()
    local level = C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel and C_MythicPlus.GetOwnedKeystoneLevel()
    if mapID and level and level > 0 then
        local name = C_ChallengeMode and C_ChallengeMode.GetMapUIInfo and C_ChallengeMode.GetMapUIInfo(mapID)
        self:_SetKeystone(mapID, name)   -- the FK target must exist before ks_mapid points at it
        changes.ks_mapid, changes.ks_level = mapID, level
    else
        changes.ks_mapid, changes.ks_level = ns.DB.NULL, ns.DB.NULL   -- clear
    end
    local summary = C_PlayerInfo and C_PlayerInfo.GetPlayerMythicPlusRatingSummary
        and C_PlayerInfo.GetPlayerMythicPlusRatingSummary("player")
    if summary and summary.currentSeasonScore then changes.rating = summary.currentSeasonScore end
    self:_SetSelf(changes)
end

function Dashboard:_CollectVault()
    self:_SetSelf({})   -- ensure the char row (FK target) + last_seen, as the old _SelfEntry() did
    local acts = C_WeeklyRewards and C_WeeklyRewards.GetActivities and C_WeeklyRewards.GetActivities()
    if not acts then return end
    local slots = {}
    for i, a in ipairs(acts) do
        -- progress/threshold can be secret in restricted content -- store only a plain number, so a
        -- cross-char cell never computes on a secret (see plainNum; a secret is stored as NULL).
        slots[#slots + 1] = { ordinal = i, type = a.type, level = a.level,
            progress = plainNum(a.progress), threshold = plainNum(a.threshold) }
    end
    self:_ReplaceSelfChildren("dashboard_vault", slots)
end

-- All saved instances the character is locked to (raids AND dungeons, every difficulty, current
-- AND legacy). GetSavedInstanceInfo returns ONLY active locks, so "which difficulty has a lockout"
-- needs no curated table -- if it's locked it's here (with its difficulty + boss count), if not it
-- isn't. We capture the difficulty name so a multi-difficulty lock (e.g. LFR + Heroic of one raid)
-- shows as separate entries.
-- Map a saved-instance (name, difficulty id) to its catalog row KEY. Built from the seeded catalog,
-- so a lock resolves to the exact journal instance + difficulty (two same-named instances differ by
-- difficulty). A lock with no matching catalog row (e.g. an unseeded legacy dungeon) is skipped.
function Dashboard:_LockKeyMap()
    local db = self:DB(); local out = {}
    if not db then return out end
    for _, r in ipairs(db:Select("key", "name", "diff_id"):From("dashboard_instance"):Run()) do
        local nm, did = denull(r.name), denull(r.diff_id)
        if nm and did then out[nm] = out[nm] or {}; out[nm][did] = r.key end
        ns.Worker:MaybeYield()
    end
    return out
end

function Dashboard:_CollectLockouts()
    self:_SetSelf({})   -- ensure the char row (FK target) + last_seen, as the old _SelfEntry() did
    local p = self:_p()
    local key2 = self:_LockKeyMap()
    local n = (GetNumSavedInstances and GetNumSavedInstances()) or 0
    local locks, seen = {}, {}
    for i = 1, n do
        local name, _, reset, diffID, locked, _, _, _, _, _, numEnc, prog = GetSavedInstanceInfo(i)
        if locked and reset and reset > 0 and name and diffID then
            local instKey = key2[name] and key2[name][diffID]   -- the catalog row for this instance+difficulty
            if not instKey then
                -- SELF-CURATE: a lock for an instance/difficulty the seeded catalog doesn't cover (e.g. a
                -- dungeon at a non-M0 difficulty, or one outside the current expansion / season). Register
                -- it under its journal id so the lock still has a row and is gathered as you play.
                local id = self:_IdForName(name)
                local rec = id and p.ejInst and p.ejInst[id]
                local diffName = GetDifficultyInfo and GetDifficultyInfo(diffID)
                if rec and diffName then
                    instKey = id .. "|" .. diffID
                    self:_SetInstance(instKey, { instance_id = id, name = rec.name, diff = diffName,
                        diff_id = diffID, is_raid = rec.isRaid, expansion = rec.tier })
                    key2[name] = key2[name] or {}; key2[name][diffID] = instKey
                end
            end
            if instKey and not seen[instKey] then          -- one lock row per instance (PK is char + instance_key)
                seen[instKey] = true
                locks[#locks + 1] = { instance_key = instKey, total = numEnc,
                    progress = plainNum(prog), reset = reset }
            end
        end
        ns.Worker:MaybeYield()                             -- per saved instance: chunk to the pump budget
    end
    self:_ReplaceSelfChildren("dashboard_lockout", locks)
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
    local title = (C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID))
        or (info and info(questID)) or ("Quest " .. questID)
    self:_SetSelf({})   -- ensure the char row exists (FK target for dashboard_quest) + last_seen
    local db = self:DB()
    if db then
        -- record the title + AUTO-DISCOVERED home (zone + expansion) on the shared `quest` table (the
        -- FK target), preserving any `time` Questing learned; the per-character row then references
        -- the quest id under its frequency with the turn-in moment (reset-aware doneness).
        local changes = { title = title }
        local mapID = C_QuestLog and C_QuestLog.GetQuestUiMapID and C_QuestLog.GetQuestUiMapID(questID)
        if not mapID or mapID == 0 then     -- quest carries no map -> the player's zone at turn-in
            mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
        end
        if mapID and mapID > 0 then
            changes.zone_map_id = mapID
            local mi = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
            if mi and mi.name then changes.zone_name = mi.name end
        end
        local lvl = GetQuestExpansion and GetQuestExpansion(questID)
        local expName = lvl and _G["EXPANSION_NAME" .. lvl]   -- localized, matches the EJ tier names
        if expName then changes.expansion = expName end
        if db:Select("quest_id"):From("quest"):Where("quest_id", "=", questID):Limit(1):Run()[1] then
            db:Update("quest", changes, { quest_id = questID })
        else changes.quest_id = questID; db:Insert("quest", changes) end
        local key = self:_SelfKey()
        local now = (GetServerTime and GetServerTime()) or time()
        local exists = db:Select("quest_id"):From("dashboard_quest")
            :Where("char_key", "=", key):AndWhere("freq", "=", freq):AndWhere("quest_id", "=", questID):Limit(1):Run()[1]
        if exists then db:Update("dashboard_quest", { done_at = now }, { char_key = key, freq = freq, quest_id = questID })
        else db:Insert("dashboard_quest", { char_key = key, freq = freq, quest_id = questID, done_at = now }) end
    end
    self:_RenderIfShown()
end

-- The heavy, deferrable pass: (re)build the instance catalog (once the journal is available) and
-- snapshot this character. Runs THROUGH the Worker (see OnEnable: self:Queue / self:WorkOn), which
-- drives it inside a frame-budgeted coroutine -- the row loops here call ns.Worker:MaybeYield() (and
-- the DB executor chunks itself) so the cost spreads across frames and never stalls a render.
function Dashboard:_RefreshNow()
    self:_BuildCatalog()
    self:_BuildZoneCatalog()            -- the full zone registry (versioned: a real sweep once per patch)
    self:_Snapshot()                    -- ends with _RenderIfShown; no second render here
end

-- Populate dashboard_instance with the full catalog the dashboard shows -- every raid (one row per
-- difficulty) and the latest expansion's + current season's dungeons -- and drop rows whose instance
-- or difficulty no longer exists. The whole catalog (journal walk, seed, prune, season, keystone) is
-- static within a client, so it builds exactly ONCE per session. The only reason a pass can repeat is
-- readiness: the journal must have loaded AND the M+ season pool must have finalised (it can lag login
-- a moment); until both are ready `catalogBuilt` stays false and a later trigger retries. After that
-- it's a cheap no-op -- zone changes never rebuild it.
function Dashboard:_BuildCatalog()
    local p = self:_p()
    if p.catalogBuilt then return end    -- built once per session
    self:_ExpansionMap()                 -- reconstruct from the DB cache, OR walk the journal (new patch)
    if not p.ejInst then return end      -- journal not ready yet -- retry on the next trigger
    -- The heavy raid/dungeon seed + prune only run on the WALK path (a new patch / first run). A
    -- same-patch login reconstructs the maps from the catalog, which is already correct -- nothing to seed.
    if not p.seededCatalog and not p.ejReconstructed then
        self:_SeedInstances()            -- one row per (journal instance, difficulty) + its art / order
        self:_PruneInstances()           -- drop instances/difficulties Blizzard removed + legacy name-keyed rows
        p.seededCatalog = true
    end
    self:_SeedSeasonDungeons()           -- current M+ season pool (cheap; the M+ rotation is live, not journal)
    self:_MarkSeasonFlags()              -- refresh current_season after the prune has cleared orphans
    self:_SeedKeystones()                -- fill local keystone names for every alt's stored map id
    if self:_SeasonDungeons() then
        p.catalogBuilt = true                                  -- done once the M+ season pool is available
        self:StampVersion()                                    -- next same-build login reconstructs, no re-walk
    end
end

function Dashboard:_Snapshot()
    ns.Worker:Mark("collect info");     self:_CollectInfo()
    ns.Worker:Mark("collect keystone"); self:_CollectKeystone()
    ns.Worker:Mark("collect vault");    self:_CollectVault()
    ns.Worker:Mark("collect lockouts"); self:_CollectLockouts()
    ns.Worker:Mark("render");           self:_RenderIfShown()
end


-- Rebuild the runtime journal maps (p.ejInst / ejByName / ejImage / ejLore / ejRaidsByTier / ... ) from
-- the PERSISTED catalog instead of walking the Encounter Journal -- no LoadAddOn, no EJ_* calls. Used on
-- a normal login: the catalog is static within a patch, so once it's saved we just read it back. On an
-- empty or pre-art catalog it bails WITHOUT setting p.ejInst (returns false) -- the caller commits to the
-- cache with no re-walk, so an incomplete cache renders nothing (a visible failure, not a silent re-walk).
function Dashboard:_ReconstructFromDB()
    local p = self:_p()
    ns.Worker:Mark("reconstruct catalog")
    local db = self:DB(); if not db then return false end
    local rows = db:Select("*"):From("dashboard_instance"):Run()
    if #rows == 0 then return false end
    local inst, byName, image, lore, raidDiffs = {}, {}, {}, {}, {}
    local raidsByTier, dungeonsByTier, season, seasonList, ordOf = {}, {}, {}, {}, {}
    local haveArt = false
    for _, r in ipairs(rows) do
        local id = denull(r.instance_id)
        if id then
            local name, isRaid, tier = denull(r.name), denull(r.is_raid) and true or false, denull(r.expansion)
            if not inst[id] then
                inst[id] = { id = id, name = name, tier = tier, isRaid = isRaid }
                byName[name] = byName[name] or {}; byName[name][#byName[name] + 1] = id
                ordOf[id] = denull(r.ord) or 0
                local li, bi = denull(r.lore_id), denull(r.button_id)
                if li and name then lore[name] = li; haveArt = true end
                if bi and name then image[name] = bi end
                if tier then
                    local b = isRaid and raidsByTier or dungeonsByTier
                    b[tier] = b[tier] or {}; b[tier][#b[tier] + 1] = id
                end
                if isRaid and denull(r.current_season) then season[id] = true; seasonList[#seasonList + 1] = id end
            end
            local did = denull(r.diff_id)
            if isRaid and did then raidDiffs[id] = raidDiffs[id] or {}; raidDiffs[id][#raidDiffs[id] + 1] = did end
        end
        ns.Worker:MaybeYield()                  -- whole-catalog walk: chunk to the pump budget
    end
    if not haveArt then return false end                       -- pre-art catalog -> re-walk to fill it in
    local byOrd = function(a, b) return (ordOf[a] or 0) < (ordOf[b] or 0) end
    for _, list in pairs(raidsByTier)    do table.sort(list, byOrd) end
    for _, list in pairs(dungeonsByTier) do table.sort(list, byOrd) end
    table.sort(seasonList, byOrd)
    local tierLevel, tierOrder = {}, {}
    for _, e in ipairs(db:Select("name", "level"):From("expansion"):Run()) do
        local nm = denull(e.name); if nm then tierLevel[nm] = denull(e.level) end
    end
    for nm in pairs(tierLevel) do tierOrder[#tierOrder + 1] = nm end
    table.sort(tierOrder, function(a, b) return (tierLevel[a] or -1) > (tierLevel[b] or -1) end)
    p.ejInst, p.ejByName, p.ejImage, p.ejLore = inst, byName, image, lore
    p.ejRaidsByTier, p.ejDungeonsByTier, p.ejRaidDiffs = raidsByTier, dungeonsByTier, raidDiffs
    p.ejSeasonRaids, p.ejSeasonRaidList = season, seasonList
    p.ejTierLevel, p.ejTierOrder = tierLevel, tierOrder
    -- current expansion = the tier owning the newest raids (highest level among raid-having tiers),
    -- recomputed from the rebuilt maps exactly as the walk does -- so it need not be persisted.
    local curTier, curLvl
    for tier in pairs(raidsByTier) do
        local l = tierLevel[tier]
        if l and (not curLvl or l > curLvl) then curTier, curLvl = tier, l end
    end
    p.currentExpansion = curTier or tierOrder[1]
    p.ejReconstructed = true
    return true
end

-- ---- expansion mapping (Encounter Journal) --------------------------------
-- Map a raid NAME -> its expansion by walking the Encounter Journal tiers (one tier per
-- expansion). Built lazily and cached on first success; name-matching is locale-consistent
-- within a client. A raid the journal doesn't list (or before the journal data loads) resolves
-- to "Other". The reference addons hand-curate this; we derive it dynamically instead.
function Dashboard:_ExpansionMap()
    local p = self:_p()
    if p.ejInst then return p.ejInst end
    -- CACHE PATH: this patch's catalog is already saved -> rebuild the maps from the DB and COMMIT to it.
    -- No fallback to a re-walk: if the saved catalog is empty/incomplete the dashboard renders nothing,
    -- which surfaces a broken cache instead of silently masking it with an expensive re-walk. The walk
    -- below runs only on the FIRST build ever / after a NEW patch (no stamp, or stamp.build mismatched).
    if self:IsVersionCurrent() then
        self:_ReconstructFromDB()
        return p.ejInst
    end
    p.ejReconstructed = false
    if not (EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex and EJ_GetTierInfo) then return nil end
    ns.Worker:Mark("load Blizzard_EncounterJournal")   -- synchronous addon load: the one unavoidable big step
    if C_AddOns and C_AddOns.LoadAddOn then pcall(C_AddOns.LoadAddOn, "Blizzard_EncounterJournal") end
    ns.Worker:MaybeYield()                             -- the load likely spent the budget: fresh pump for the walk
    ns.Worker:Mark("journal walk")
    -- Instances are tracked by their EJ journal INSTANCE ID, not their name -- two distinct journal
    -- instances can share a name (e.g. a Burning Crusade dungeon and a reworked current-season one),
    -- and only the id keeps them apart with their own home expansion. Art stays keyed by NAME (a shared
    -- picture for same-named instances is harmless; the journal exposes art per name).
    local inst, byName = {}, {}            -- id -> { id, name, tier(home), isRaid } ; name -> { ids, newest first }
    local raidsByTier, dungeonsByTier, tierOrder, found = {}, {}, {}, false
    local tierLevel = {}   -- tier name -> expansionLevel (EJ tier index 1 = Classic = expansion 0)
    local image, lore = {}, {}             -- instance NAME -> EJ buttonImage1 / loreImage
    local prev = EJ_GetCurrentTier and EJ_GetCurrentTier()
    local function walk(tier, tierName, isRaid, sink, isSeason)
        EJ_SelectTier(tier)                   -- can load tier data (a hitchy C call) ...
        ns.Worker:MaybeYield()                -- ... so offer the frame back before iterating it
        local i = 1
        while true do
            local instID, name, _, _, buttonImage, loreImage = EJ_GetInstanceByIndex(i, isRaid)
            if not instID then break end
            if name == "Keystone Dungeons" then name = nil end   -- dungeon meta-entry, never a real instance
            -- Drop the RAID list's world-boss "meta" entry (no weekly lockout). On a normal tier it's
            -- named after the expansion (e.g. "Pandaria", "Draenor", "Midnight") -- matched exactly,
            -- by trailing word for long names ("Mists of Pandaria" -> "Pandaria"), or by continent /
            -- world-event alias (WORLD_RAID_ALIASES). On the "Current Season" tier it's named after the
            -- LIVE expansion instead, so match that there.
            if isRaid and name then
                if isSeason then
                    local cur = self:_CurrentExpansionName()
                    if cur and (name == cur or WORLD_RAID_ALIASES[name] == cur) then name = nil end
                elseif tierName and (name == tierName or tierName:match("(%S+)%s*$") == name
                                     or WORLD_RAID_ALIASES[name] == tierName) then
                    name = nil
                end
            end
            if name then
                if buttonImage and not image[name] then image[name] = buttonImage end
                if loreImage  and not lore[name]  then lore[name]  = loreImage  end
                local rec = inst[instID]
                if not rec then
                    rec = { id = instID, name = name, isRaid = isRaid and true or false }
                    inst[instID] = rec
                    byName[name] = byName[name] or {}
                    byName[name][#byName[name] + 1] = instID         -- walked newest-first => newest id first
                end
                if not isSeason and tierName then
                    rec.tier = tierName; found = true                -- last write wins => OLDEST tier = home
                end
                if sink then sink[#sink + 1] = instID end
            end
            i = i + 1
            ns.Worker:MaybeYield()                -- spread the walk across frames (Worker-budgeted build)
        end
    end
    local seasonRaidList = {}                 -- ids of raids on the journal's "Current Season" page
    for tier = EJ_GetNumTiers(), 1, -1 do   -- newest tier first
        local tierName = EJ_GetTierInfo(tier)
        -- "World Raids" is a cross-expansion world-boss bucket, not a real expansion -- drop it.
        if tierName == "World Raids" then tierName = nil end
        if tierName == SEASON_LABEL then
            -- The "Current Season" tier is a journal PAGE, not an expansion: record which raids are in
            -- the live season (its world-boss entry dropped) but skip the tier/expansion bookkeeping --
            -- those raids keep their real home expansion (set when their own tier is walked) plus a flag.
            walk(tier, tierName, true, seasonRaidList, true)
            tierName = nil
        end
        if tierName then
            tierLevel[tierName] = tier - 1   -- EJ tier 1 == Classic == expansion level 0
            local raids, dungeons = {}, {}
            walk(tier, tierName, true, raids)
            walk(tier, tierName, false, dungeons)
            if #raids > 0 then
                raidsByTier[tierName] = raids
                tierOrder[#tierOrder + 1] = tierName
            end
            if #dungeons > 0 then dungeonsByTier[tierName] = dungeons end
        end
    end
    -- Which difficulties each raid ACTUALLY offers (the journal's truth, keyed by instance id) -- so
    -- seeding skips an LFR / Mythic a raid never had, and legacy raids get their 10/25/40-player ids.
    -- The per-raid EJ_SelectInstance probe is the heaviest step and its result only changes across
    -- PATCHES. We only ever reach this WALK path on a first run / a new patch (a same-patch login
    -- reconstructs from the DB above and never gets here), so probe every raid -- the result is then
    -- persisted and reused until the next patch.
    local raidDiffs = {}
    ns.Worker:Mark("raid difficulty probe")
    if EJ_SelectInstance and EJ_IsValidInstanceDifficulty then
        for id, rec in pairs(inst) do
            if rec.isRaid then
                pcall(EJ_SelectInstance, id)
                local ids = {}
                for _, d in ipairs(RAID_DIFF_CANDIDATES) do if EJ_IsValidInstanceDifficulty(d) then ids[#ids + 1] = d end end
                if #ids > 0 then raidDiffs[id] = ids end
                ns.Worker:MaybeYield()
            end
        end
    end
    if prev then pcall(EJ_SelectTier, prev) end   -- restore the journal's selected tier
    if found then
        p.ejInst = inst                       -- id -> { id, name, tier, isRaid } (the identity record)
        p.ejByName = byName                   -- name -> { ids, newest first } (resolve season/lockout names)
        p.ejRaidsByTier = raidsByTier         -- tier -> { instance ids } (journal order)
        p.ejDungeonsByTier = dungeonsByTier   -- tier -> { instance ids }
        p.ejTierOrder = tierOrder             -- tiers with raids, newest first
        p.ejTierLevel = tierLevel             -- tier name -> expansionLevel (for native logos)
        p.ejImage = image                     -- instance NAME -> EJ tile art (buttonImage1; banner fallback)
        p.ejLore = lore                       -- instance NAME -> EJ splash (loreImage; preferred art)
        -- journal order per instance (index within its tier), persisted so reconstruction can re-sort tiles
        local ord = {}
        for _, ids in pairs(raidsByTier)    do for i2, id2 in ipairs(ids) do ord[id2] = i2 end end
        for _, ids in pairs(dungeonsByTier) do for i2, id2 in ipairs(ids) do ord[id2] = i2 end end
        p.ejOrd = ord
        p.ejSeasonRaidList = seasonRaidList   -- season raid ids, newest tier first (tile order)
        local seasonSet = {}
        for _, id in ipairs(seasonRaidList) do seasonSet[id] = true end
        p.ejSeasonRaids = seasonSet           -- instance id -> true for the live season's raids
        p.ejRaidDiffs = raidDiffs             -- instance id -> { difficulty ids it actually offers }
        self:_SeedExpansions()                -- materialise the expansion FK targets now the tier levels are known
        -- The CURRENT raid tier is the expansion that OWNS the newest raids -- the newest home tier
        -- across all raids (a new tier can re-list the prior expansion's raids before its own ship).
        local curTier, curLvl
        for _, rec in pairs(inst) do
            if rec.isRaid and rec.tier then
                local l = tierLevel[rec.tier]
                if l and (not curLvl or l > curLvl) then curTier, curLvl = rec.tier, l end
            end
        end
        p.currentExpansion = curTier or tierOrder[1] or EJ_GetTierInfo(EJ_GetNumTiers())
    end
    return p.ejInst
end

-- Newest journal instance id recorded for a name (instances are stored newest-tier-first), or nil.
function Dashboard:_IdForName(name)
    local b = self:_p().ejByName
    local ids = name and b and b[name]
    return ids and ids[1] or nil
end

-- The home expansion of the (newest) journal instance with this name; "Other" until the map is built.
function Dashboard:_InstanceExpansion(name)
    local id = self:_IdForName(name)
    local rec = id and self:_p().ejInst and self:_p().ejInst[id]
    return (rec and rec.tier) or "Other"
end

-- Seed the expansion registry from the journal tier levels: one row per tier with the banner logo
-- (a fileID from GetExpansionDisplayInfo) the tiles display. Insert-if-missing; runs the moment the
-- map is built so the dashboard_instance.expansion FK target always exists before any instance seeds.
function Dashboard:_SeedExpansions()
    local db = self:DB(); if not db then return end
    for name, level in pairs(self:_p().ejTierLevel or {}) do
        if not db:Select("name"):From("expansion"):Where("name", "=", name):Limit(1):Run()[1] then
            local info = GetExpansionDisplayInfo and GetExpansionDisplayInfo(level)
            local logo = info and info.logo
            db:Insert("expansion", { name = name, level = level,
                logo = (type(logo) == "number") and logo or ns.DB.NULL })
        end
    end
end

-- The native expansion banner texture for a tier (the icon WoW ships per expansion), or nil. Reads
-- the stored fileID from the expansion table (the registry the tiles are driven from); falls back to
-- the live GetExpansionDisplayInfo(expansionLevel) before the registry is seeded.
function Dashboard:_ExpansionLogo(tierName)
    local db = self:DB()
    if db then
        local r = db:Select("logo"):From("expansion"):Where("name", "=", tierName):Limit(1):Run()[1]
        local logo = r and denull(r.logo)
        if logo then return logo end
    end
    local lvl = self:_p().ejTierLevel and self:_p().ejTierLevel[tierName]
    if not (lvl and GetExpansionDisplayInfo) then return nil end
    local info = GetExpansionDisplayInfo(lvl)
    return info and info.logo or nil
end

-- The CURRENT expansion's level. LE_EXPANSION_LEVEL_CURRENT is deprecated in Midnight, so prefer the
-- live getters (the displayable client max), falling back through to the old constant.
local function currentExpacLevel()
    if GetClientDisplayExpansionLevel then return GetClientDisplayExpansionLevel() end
    if GetExpansionLevel then return GetExpansionLevel() end
    return LE_EXPANSION_LEVEL_CURRENT
end

-- The current expansion's display name (e.g. "The War Within"), from the game's expansion strings, or
-- nil. EXPANSION_NAME<level> is the localized name Blizzard also uses for the journal's tier label.
function Dashboard:_CurrentExpansionName()
    local lvl = currentExpacLevel()
    local n = lvl and _G["EXPANSION_NAME" .. lvl]
    return (n and n ~= "") and n or nil
end

-- The current expansion's emblem texture (the same picture the raid tiles use), or nil.
function Dashboard:_CurrentExpansionLogo()
    local lvl = currentExpacLevel()
    local info = lvl and GetExpansionDisplayInfo and GetExpansionDisplayInfo(lvl)
    return info and info.logo or nil
end

-- The Encounter Journal DUNGEON tier for the current EXPANSION -- i.e. every dungeon released in it,
-- which is a SUPERSET of (and distinct from) the "Current Season" M+ subset. Found by the expansion's
-- name (the journal names that tier after the expansion); if the name doesn't line up, fall back to
-- the dungeon tier whose journal level matches the current expansion level. nil if none is found.
function Dashboard:_CurrentExpansionTier()
    local p = self:_p()
    local dbt = p.ejDungeonsByTier
    if not dbt then return nil end
    local name = self:_CurrentExpansionName()
    if name and dbt[name] then return name end
    local lvl = currentExpacLevel()
    if lvl and p.ejTierLevel then
        for tierName in pairs(dbt) do
            if tierName ~= SEASON_LABEL and p.ejTierLevel[tierName] == lvl then return tierName end
        end
    end
    return nil
end

-- An art descriptor for an instance tile. Prefer the big SPLASH (loreImage) -- the scene the journal
-- shows on the right when you open the instance -- cover-fitted + zoomed/panned onto its art region.
-- The low-def buttonImage1 banner is only a fallback (cropped + zoomed) for an instance with no splash.
-- Per-kind ("raid"/"dungeon") cover zoom + pan for the splash, seeded from the code defaults. These
-- are RUNTIME (per session): the Dev module live-tunes them via SetArtTune; they reset to the
-- EJ_LORE_* defaults every load. On a normal character nothing changes them, so the art is identical.
function Dashboard:_ArtTune(kind)
    local p = self:_p()
    if not p.artTune then
        p.artTune = {
            raid    = { zoom = EJ_LORE_ZOOM, panX = EJ_LORE_PAN_X, panY = EJ_LORE_PAN_Y },
            dungeon = { zoom = EJ_LORE_ZOOM, panX = EJ_LORE_PAN_X, panY = EJ_LORE_PAN_Y },
        }
    end
    return p.artTune[kind] or p.artTune.dungeon
end

-- Read / live-update the splash art tuning for a kind. SetArtTune re-renders if the Dashboard is open
-- so a Dev slider drag is reflected immediately. field is "zoom" | "panX" | "panY".
function Dashboard:GetArtTune(kind) return self:_ArtTune(kind) end
function Dashboard:SetArtTune(kind, field, value)
    self:_ArtTune(kind)[field] = value
    self:_RenderIfShown()
end

function Dashboard:_InstanceArt(name, kind)
    local p = self:_p()
    if not name then return nil end
    if p.ejLore and p.ejLore[name] then
        local t = self:_ArtTune(kind or "dungeon")
        return { texture = p.ejLore[name], cover = true, aspect = EJ_LORE_ASPECT,
                 zoom = t.zoom, panX = t.panX, panY = t.panY }
    end
    if p.ejImage and p.ejImage[name] then return { texture = p.ejImage[name], texCoord = EJ_TILE_TC, zoom = EJ_TILE_ZOOM } end
    return nil
end

-- The last (newest) raid / dungeon in the current expansion's catalog -- the picture used for the
-- current-tier tile, so it shows the real instance art instead of the generic expansion logo.
function Dashboard:_LatestRaidArt()
    local p = self:_p()
    local r = p.ejRaidsByTier and p.currentExpansion and p.ejRaidsByTier[p.currentExpansion]
    local rec = r and r[#r] and p.ejInst and p.ejInst[r[#r]]
    if rec then return self:_InstanceArt(rec.name, "raid") end
end

function Dashboard:_LatestDungeonArt()
    local p = self:_p()
    local d = p.ejDungeonsByTier and p.currentExpansion and p.ejDungeonsByTier[p.currentExpansion]
    local rec = d and d[#d] and p.ejInst and p.ejInst[d[#d]]
    if rec then return self:_InstanceArt(rec.name, "dungeon") end
end

-- Season dungeons that actually have art, in season order -- the pool the Current Season tile draws
-- from (and the Dev "next dungeon" button steps through). Cached once the journal map is ready.
function Dashboard:_SeasonArtPool()
    local p = self:_p()
    if p.seasonPool then return p.seasonPool end
    local s = self:_SeasonDungeons()
    if not s then return nil end
    local cand = {}
    for _, name in ipairs(s.list) do
        if (p.ejLore and p.ejLore[name]) or (p.ejImage and p.ejImage[name]) then cand[#cand + 1] = name end
    end
    if #cand == 0 then return nil end
    p.seasonPool = cand
    return cand
end

-- A current-season dungeon's art for the Current Season tile. Starts on a RANDOM one, then sticks to
-- whatever the Dev "next dungeon" button last stepped to (p.seasonIdx).
function Dashboard:_SeasonDungeonArt()
    local p = self:_p()
    local pool = self:_SeasonArtPool()
    if not pool then return nil end
    if not p.seasonIdx then p.seasonIdx = math.random(#pool) end
    return self:_InstanceArt(pool[p.seasonIdx], "dungeon")
end

-- Dev tooling: step the Current Season tile to the NEXT season dungeon's image (wraps), so every
-- dungeon's splash can be inspected/tuned. Returns the now-showing dungeon name, or nil if no pool.
function Dashboard:NextSeasonDungeon()
    local pool = self:_SeasonArtPool()
    if not pool then return nil end
    local p = self:_p()
    p.seasonIdx = ((p.seasonIdx or 0) % #pool) + 1
    self:_RenderIfShown()
    return pool[p.seasonIdx]
end

-- The dungeon name currently shown on the Current Season tile (for the Dev panel's readout), or nil.
function Dashboard:CurrentSeasonDungeon()
    local pool = self:_SeasonArtPool()
    if not (pool and self:_p().seasonIdx) then return nil end
    return pool[self:_p().seasonIdx]
end

-- Distinct expansions in the registry for one kind (raids if wantRaid, else dungeons), ordered by
-- EXPANSION RELEASE DATE -- newest first, like the raid list -- via the journal tier level. Tiers with
-- no known level (e.g. "Other") sort last, then alphabetically. Persists: an expansion stays listed
-- once anything in it is known.
function Dashboard:_KnownExpansions(wantRaid)
    local set = {}
    for _, r in pairs(self:_Instances()) do
        if r.isRaid == wantRaid then set[r.expansion or "Other"] = true end
    end
    local lvl = self:_p().ejTierLevel or {}
    local list = {}
    for exp in pairs(set) do list[#list + 1] = exp end
    table.sort(list, function(a, b)
        local la, lb = lvl[a], lvl[b]
        if la and lb then if la ~= lb then return la > lb end return a < b end
        if la ~= lb then return la ~= nil end   -- a known-level tier sorts before an unknown one
        return a < b
    end)
    return list
end

-- ---- raids: the FULL catalog (every raid has a weekly lockout, so show them all) -----------
-- Raid tiers, newest first -- now read from the seeded dashboard_instance catalog (not the live
-- journal), so the nav reflects exactly what's in the table.
function Dashboard:_RaidExpansions()
    return self:_KnownExpansions(true)
end

-- Distinct instances in a catalog group, as { id, name } descriptors, NEWEST FIRST. `pred(entry)`
-- selects the rows; `orderList` (journal order of instance ids, oldest->newest) positions them
-- reversed, any leftover sorted by name after. Keyed by journal id, so two same-named instances stay
-- separate. Sourced from the seeded catalog, so it reflects exactly what's stored.
function Dashboard:_InstanceList(pred, orderList)
    local nameById = {}
    for _, r in pairs(self:_Instances()) do
        if r.id and pred(r) then nameById[r.id] = r.name end
    end
    local out, seen = {}, {}
    if orderList then
        for i = #orderList, 1, -1 do
            local id = orderList[i]
            if nameById[id] and not seen[id] then out[#out + 1] = { id = id, name = nameById[id] }; seen[id] = true end
        end
    end
    local rest = {}
    for id in pairs(nameById) do if not seen[id] then rest[#rest + 1] = id end end
    table.sort(rest, function(a, b) return (nameById[a] or "") < (nameById[b] or "") end)
    for _, id in ipairs(rest) do out[#out + 1] = { id = id, name = nameById[id] } end
    return out
end

-- Raids / dungeons in one expansion (by FK), newest first -- each drives its tile grid. A season
-- instance keeps its home expansion, so it lists under both its expansion AND Current Season.
function Dashboard:_RaidsInExpansion(exp)
    return self:_InstanceList(function(r) return r.isRaid and (r.expansion or "Other") == exp end,
        self:_p().ejRaidsByTier and self:_p().ejRaidsByTier[exp])
end
function Dashboard:_DungeonsInExpansion(exp)
    return self:_InstanceList(function(r) return (not r.isRaid) and (r.expansion or "Other") == exp end,
        self:_p().ejDungeonsByTier and self:_p().ejDungeonsByTier[exp])
end
-- Whether a catalog raid is in the live season. Prefers the journal set built this session (by id),
-- falling back to the stored flag.
function Dashboard:_IsSeasonRaid(r)
    if not r.isRaid then return false end
    local season = self:_p().ejSeasonRaids
    if season and next(season) and r.id then return season[r.id] and true or false end
    return r.season and true or false
end
function Dashboard:_SeasonRaidNames()
    return self:_InstanceList(function(r) return self:_IsSeasonRaid(r) end, self:_p().ejSeasonRaidList)
end
function Dashboard:_HasSeasonRaids() return self:_SeasonRaidNames()[1] ~= nil end
-- The live Mythic+ season's dungeons -- catalog dungeons whose name is in the C_ChallengeMode rotation
-- (or carry the stored flag). Each is a distinct journal instance, so the season pick is locked to it.
function Dashboard:_SeasonDungeonNames()
    local s = self:_SeasonDungeons(); local set = s and s.set
    return self:_InstanceList(function(r) return (not r.isRaid) and ((set and set[r.name]) or r.season) end)
end

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
            texture = logoTier and self:_ExpansionLogo(logoTier) or nil,
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
        local art = self:_InstanceArt(name, artKind)
        if art then applyArt(tile, art) end
        tiles[#tiles + 1] = tile
    end
    return tiles
end

-- Difficulty columns for ONE instance (by journal id): a column per difficulty present, ordered by
-- rank, each cell the character's lock progress ("6/8") or "-". Raids span LFR/N/H/M; dungeons M0.
function Dashboard:_InstanceDifficultyColumns(id)
    local cols = {}
    for _, r in pairs(self:_Instances()) do
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
-- expanding its quest x character matrix inline. Everything self-curates from _RecordQuest --
-- there is no curated quest/zone/expansion list anywhere.

-- Quests whose expansion was never discovered (legacy rows) bucket under this label.
local QUEST_OTHER = "Other"

-- The data-version domain of the ZONE CATALOG (the full uiMapID sweep below): rebuilt once per
-- patch, reconstructed from the persisted `zone` rows on a same-build login -- exactly like the
-- instance catalog. (Not via the VersioningOwner mixin -- that binds this module's ONE domain to
-- the instance catalog -- so this asks ns.Versioning directly.)
local ZONE_DOMAIN = "zone_catalog"


-- ---- zone typography styles -------------------------------------------------------------------
-- A zone WITHOUT its own loading screen renders as a TYPOGRAPHY tile: a two-stop gradient plate +
-- the zone name in the fantasy serif, coloured to evoke the place. Resolution order (_ZoneStyle):
--   1. ZONE_STYLE   -- hand-curated for the RECOGNISABLE zones (each researched: Elwynn's sunlit
--                      canopy, Durotar's red dust, Crystalsong's violet crystal, ...)
--   2. BIOME_STYLE  -- keyword inference from the name (Desert/Frost/Marsh/... -> biome palette)
--   3. expansion tint (EXP_STYLE) on the neutral plate
-- A style is { bg = {r,g,b} top, bg2 = {r,g,b} bottom, fg = {r,g,b} type } -- backgrounds stay
-- dark so tiles sit in the theme; the HUE carries the zone, the type colour carries the light.
local function zs(bg, bg2, fg) return { bg = bg, bg2 = bg2, fg = fg } end

local ZONE_STYLE = {
    -- Eastern Kingdoms / Kalimdor classics
    ["Elwynn Forest"]       = zs({0.10,0.18,0.08}, {0.04,0.09,0.03}, {0.95,0.85,0.55}),  -- sunlit canopy gold on green
    ["Westfall"]            = zs({0.24,0.18,0.08}, {0.12,0.08,0.03}, {0.95,0.82,0.50}),  -- wheat under harvest light
    ["Duskwood"]            = zs({0.05,0.07,0.05}, {0.01,0.02,0.01}, {0.70,0.78,0.62}),  -- lantern-pale in black forest
    ["Deadwind Pass"]       = zs({0.10,0.08,0.09}, {0.03,0.02,0.03}, {0.62,0.58,0.66}),  -- ashen storm over Karazhan
    ["Stranglethorn Vale"]  = zs({0.06,0.16,0.08}, {0.02,0.07,0.03}, {0.65,0.92,0.55}),  -- dense jungle leaf-light
    ["Durotar"]             = zs({0.26,0.10,0.05}, {0.12,0.04,0.02}, {0.95,0.70,0.45}),  -- red dust and dry sun
    ["Mulgore"]             = zs({0.20,0.16,0.06}, {0.08,0.08,0.03}, {0.95,0.85,0.60}),  -- golden plains
    ["The Barrens"]         = zs({0.22,0.16,0.08}, {0.10,0.07,0.03}, {0.92,0.78,0.52}),  -- savanna tan
    ["Tirisfal Glades"]     = zs({0.08,0.10,0.07}, {0.03,0.04,0.02}, {0.68,0.80,0.58}),  -- sickly forsaken green
    ["Ashenvale"]           = zs({0.06,0.10,0.14}, {0.02,0.04,0.07}, {0.70,0.85,0.95}),  -- moonlit silver-blue
    ["Felwood"]             = zs({0.08,0.12,0.04}, {0.03,0.05,0.01}, {0.60,0.95,0.35}),  -- corrupted fel glow
    ["Winterspring"]        = zs({0.14,0.18,0.26}, {0.06,0.08,0.14}, {0.92,0.96,1.00}),  -- snowfield night
    ["Tanaris"]             = zs({0.28,0.20,0.08}, {0.14,0.09,0.03}, {1.00,0.88,0.55}),  -- open desert glare
    ["Un'Goro Crater"]      = zs({0.07,0.15,0.06}, {0.03,0.06,0.02}, {0.70,0.95,0.50}),  -- primordial jungle
    ["Silithus"]            = zs({0.18,0.13,0.08}, {0.06,0.04,0.03}, {0.90,0.70,0.45}),  -- dusk sand, silithid dark
    -- Outland
    ["Hellfire Peninsula"]  = zs({0.24,0.07,0.04}, {0.10,0.02,0.01}, {1.00,0.55,0.30}),  -- fel-scorched red rock
    ["Zangarmarsh"]         = zs({0.04,0.13,0.14}, {0.01,0.05,0.06}, {0.55,0.95,0.90}),  -- giant mushroom glow
    ["Nagrand"]             = zs({0.09,0.16,0.09}, {0.03,0.07,0.04}, {0.75,0.95,0.70}),  -- floating-isle grassland
    ["Netherstorm"]         = zs({0.12,0.07,0.16}, {0.05,0.02,0.08}, {0.85,0.60,1.00}),  -- shattered arcane sky
    ["Shadowmoon Valley"]   = zs({0.08,0.06,0.12}, {0.03,0.02,0.06}, {0.75,0.70,0.95}),  -- night-violet moonglow
    -- Northrend
    ["Howling Fjord"]       = zs({0.06,0.13,0.13}, {0.02,0.05,0.06}, {0.65,0.92,0.88}),  -- deep teal fjord
    ["Grizzly Hills"]       = zs({0.18,0.12,0.05}, {0.08,0.05,0.02}, {0.95,0.70,0.40}),  -- autumn timber amber
    ["Dragonblight"]        = zs({0.16,0.19,0.23}, {0.07,0.09,0.12}, {0.90,0.94,1.00}),  -- bone-white snowfield
    ["Crystalsong Forest"]  = zs({0.11,0.08,0.18}, {0.04,0.03,0.09}, {0.85,0.75,1.00}),  -- violet crystal trees
    ["Icecrown"]            = zs({0.08,0.11,0.17}, {0.02,0.04,0.08}, {0.80,0.92,1.00}),  -- cold steel and saronite
    ["The Storm Peaks"]     = zs({0.08,0.10,0.16}, {0.03,0.04,0.08}, {0.85,0.90,1.00}),  -- titan night-blue
    ["Sholazar Basin"]      = zs({0.08,0.16,0.07}, {0.03,0.07,0.02}, {0.75,0.98,0.55}),  -- lifebloom jungle
    -- Cataclysm
    ["Mount Hyjal"]         = zs({0.10,0.14,0.06}, {0.05,0.05,0.02}, {1.00,0.65,0.35}),  -- green crown, ember edge
    ["Uldum"]               = zs({0.26,0.20,0.10}, {0.11,0.08,0.04}, {0.55,0.80,1.00}),  -- gold sand, lapis accents
    ["Deepholm"]            = zs({0.10,0.09,0.12}, {0.04,0.03,0.05}, {0.80,0.65,1.00}),  -- amethyst stone heart
    ["Twilight Highlands"]  = zs({0.12,0.09,0.13}, {0.05,0.03,0.06}, {0.85,0.70,0.95}),  -- twilight dragon dusk
    -- Pandaria
    ["The Jade Forest"]     = zs({0.06,0.15,0.10}, {0.02,0.06,0.04}, {0.60,0.95,0.75}),  -- jade mist
    ["Valley of the Four Winds"] = zs({0.18,0.16,0.06}, {0.08,0.07,0.02}, {0.98,0.88,0.55}), -- golden grain
    ["Kun-Lai Summit"]      = zs({0.15,0.18,0.22}, {0.06,0.08,0.11}, {0.95,0.97,1.00}),  -- white summit air
    ["Dread Wastes"]        = zs({0.08,0.11,0.06}, {0.03,0.04,0.02}, {0.70,0.90,0.50}),  -- mantid amber-green
    -- Draenor
    ["Frostfire Ridge"]     = zs({0.16,0.10,0.10}, {0.06,0.03,0.04}, {1.00,0.60,0.35}),  -- lava through snow
    ["Talador"]             = zs({0.18,0.14,0.07}, {0.08,0.06,0.03}, {0.98,0.85,0.55}),  -- autumn gold arakkoa light
    ["Spires of Arak"]      = zs({0.12,0.08,0.12}, {0.05,0.03,0.05}, {0.95,0.75,0.45}),  -- dusk cliffs, amber sky
    ["Gorgrond"]            = zs({0.10,0.13,0.06}, {0.04,0.05,0.02}, {0.75,0.90,0.50}),  -- overgrowth vs iron
    -- Legion
    ["Azsuna"]              = zs({0.06,0.11,0.16}, {0.02,0.04,0.08}, {0.55,0.85,1.00}),  -- azure ley-ruins
    ["Val'sharah"]          = zs({0.07,0.14,0.08}, {0.02,0.06,0.03}, {0.65,0.95,0.65}),  -- emerald dream edge
    ["Highmountain"]        = zs({0.14,0.11,0.07}, {0.06,0.04,0.02}, {0.90,0.75,0.50}),  -- tauren stone and pine
    ["Stormheim"]           = zs({0.10,0.12,0.14}, {0.04,0.05,0.06}, {0.78,0.88,0.95}),  -- vrykul storm cliffs
    ["Suramar"]             = zs({0.12,0.06,0.16}, {0.05,0.02,0.08}, {0.95,0.60,1.00}),  -- nightborne arcwine glow
    -- Battle for Azeroth
    ["Tiragarde Sound"]     = zs({0.07,0.10,0.14}, {0.02,0.04,0.06}, {0.90,0.80,0.55}),  -- harbour brass on navy
    ["Drustvar"]            = zs({0.10,0.11,0.11}, {0.04,0.04,0.04}, {0.88,0.90,0.92}),  -- witch-fog and bone
    ["Stormsong Valley"]    = zs({0.08,0.13,0.11}, {0.03,0.05,0.04}, {0.70,0.92,0.85}),  -- tidesage green-blue
    ["Zuldazar"]            = zs({0.14,0.12,0.04}, {0.06,0.05,0.02}, {0.98,0.85,0.45}),  -- golden troll empire
    ["Nazmir"]              = zs({0.07,0.10,0.08}, {0.02,0.04,0.03}, {0.60,0.85,0.70}),  -- blood-swamp mist
    ["Vol'dun"]             = zs({0.24,0.17,0.09}, {0.11,0.07,0.03}, {0.98,0.82,0.55}),  -- exile desert
    ["Nazjatar"]            = zs({0.04,0.09,0.14}, {0.01,0.03,0.06}, {0.50,0.90,0.95}),  -- abyssal naga deep
    -- Shadowlands
    ["Bastion"]             = zs({0.14,0.16,0.20}, {0.06,0.07,0.10}, {0.95,0.90,0.70}),  -- kyrian white-gold
    ["Maldraxxus"]          = zs({0.08,0.11,0.05}, {0.03,0.04,0.01}, {0.70,0.95,0.40}),  -- necropolis bile-green
    ["Ardenweald"]          = zs({0.05,0.08,0.15}, {0.02,0.03,0.07}, {0.60,0.80,1.00}),  -- star-lit faerie blue
    ["Revendreth"]          = zs({0.12,0.05,0.06}, {0.05,0.01,0.02}, {0.95,0.45,0.45}),  -- venthyr crimson gothic
    ["Zereth Mortis"]       = zs({0.15,0.15,0.13}, {0.07,0.07,0.06}, {0.95,0.92,0.75}),  -- progenitor pearl-gold
    -- Dragonflight
    ["The Waking Shores"]   = zs({0.18,0.08,0.05}, {0.08,0.03,0.02}, {1.00,0.60,0.35}),  -- volcanic dragonfire
    ["Ohn'ahran Plains"]    = zs({0.10,0.15,0.08}, {0.04,0.06,0.03}, {0.80,0.95,0.65}),  -- windswept centaur grass
    ["The Azure Span"]      = zs({0.07,0.11,0.16}, {0.02,0.04,0.08}, {0.60,0.85,1.00}),  -- blue frost-forest
    ["Thaldraszus"]         = zs({0.14,0.11,0.07}, {0.06,0.04,0.02}, {0.95,0.78,0.45}),  -- bronze titan stone
    ["The Emerald Dream"]   = zs({0.06,0.14,0.07}, {0.02,0.06,0.02}, {0.60,1.00,0.60}),  -- vivid dream green
    -- The War Within
    ["Isle of Dorn"]        = zs({0.13,0.14,0.08}, {0.05,0.06,0.03}, {0.95,0.85,0.55}),  -- mediterranean earthen gold
    ["The Ringing Deeps"]   = zs({0.09,0.07,0.05}, {0.03,0.02,0.01}, {1.00,0.70,0.35}),  -- machine-amber in the dark
    ["Hallowfall"]          = zs({0.10,0.13,0.18}, {0.04,0.05,0.09}, {1.00,0.85,0.55}),  -- Beledar's light in cavern dusk
    ["Azj-Kahet"]           = zs({0.09,0.06,0.11}, {0.03,0.02,0.05}, {0.80,0.60,0.95}),  -- web-violet nerubian dark
    -- Midnight
    ["Eversong Woods"]      = zs({0.16,0.11,0.05}, {0.07,0.04,0.02}, {1.00,0.80,0.45}),  -- radiant autumn-spring gold
    ["Zul'Aman"]            = zs({0.07,0.13,0.07}, {0.02,0.05,0.02}, {0.85,0.95,0.55}),  -- amani rainforest
    ["Harandar"]            = zs({0.06,0.10,0.12}, {0.02,0.04,0.05}, {0.55,0.95,0.85}),  -- bioluminescent fungal roots
    ["Voidstorm"]           = zs({0.09,0.05,0.13}, {0.03,0.01,0.06}, {0.80,0.50,1.00}),  -- void gorges and pylons
    ["Naigtal"]             = zs({0.08,0.06,0.12}, {0.03,0.02,0.05}, {0.70,0.60,1.00}),  -- fungal-arcane haze
    ["Val"]                 = zs({0.12,0.14,0.18}, {0.05,0.06,0.08}, {0.85,0.92,1.00}),  -- frozen legion wasteland
}

-- Biome inference for everything not curated: the FIRST keyword hit (checked in order, darkest
-- moods before generic terrain so "Deadwood Forest" reads dark, not forest) picks the palette.
local BIOME_STYLE = {
    dark     = zs({0.07,0.07,0.08}, {0.02,0.02,0.03}, {0.72,0.74,0.70}),
    volcanic = zs({0.20,0.08,0.04}, {0.09,0.03,0.01}, {1.00,0.60,0.32}),
    snow     = zs({0.13,0.16,0.22}, {0.05,0.07,0.11}, {0.92,0.96,1.00}),
    desert   = zs({0.25,0.18,0.08}, {0.11,0.08,0.03}, {0.98,0.84,0.52}),
    swamp    = zs({0.07,0.11,0.08}, {0.02,0.04,0.03}, {0.62,0.88,0.70}),
    jungle   = zs({0.06,0.14,0.07}, {0.02,0.06,0.02}, {0.68,0.95,0.50}),
    forest   = zs({0.08,0.14,0.07}, {0.03,0.06,0.02}, {0.85,0.92,0.60}),
    coast    = zs({0.06,0.10,0.15}, {0.02,0.04,0.07}, {0.60,0.88,0.95}),
    mountain = zs({0.13,0.11,0.08}, {0.05,0.04,0.03}, {0.88,0.78,0.58}),
    plains   = zs({0.15,0.14,0.06}, {0.06,0.06,0.02}, {0.95,0.88,0.58}),
    arcane   = zs({0.10,0.06,0.15}, {0.04,0.02,0.07}, {0.85,0.65,1.00}),
}
local BIOME_WORDS = {
    { "dark",     { "shadow", "dusk", "dark", "dread", "dead", "grim", "blight", "plague", "maw" } },
    { "volcanic", { "fire", "molten", "burning", "cinder", "searing", "lava", "crater", "scorch" } },
    { "snow",     { "frost", "ice", "winter", "snow", "glacier", "tundra", "chill" } },
    { "desert",   { "desert", "sand", "dune", "waste", "scarab", "sun" } },
    { "swamp",    { "marsh", "swamp", "bog", "mire", "fen" } },
    { "jungle",   { "jungle", "wilds", "basin", "thorn" } },
    { "forest",   { "forest", "wood", "grove", "glade", "vale" } },
    { "coast",    { "isle", "island", "shore", "coast", "bay", "sea", "tide", "reef", "depth", "sound" } },
    { "mountain", { "mount", "peak", "ridge", "highland", "cliff", "summit", "crag", "spire" } },
    { "plains",   { "plain", "steppe", "field", "meadow", "prairie" } },
    { "arcane",   { "crystal", "arcane", "moon", "star", "storm", "void", "nether" } },
}

-- The neutral plate the expansion tint colours when neither curation nor biome matches.
local PLATE_BG, PLATE_BG2 = { 0.08, 0.10, 0.14 }, { 0.04, 0.05, 0.08 }

-- Typography palette: each expansion's signature colour -- the zone plate's LAST-RESORT tint when
-- neither curation nor biome matches (keyed by expansion level == EJ tier level).
local EXP_STYLE = {
    [0]  = { 0.85, 0.71, 0.38 },   -- Classic: aged gold / parchment
    [1]  = { 0.55, 0.85, 0.35 },   -- Burning Crusade: fel green
    [2]  = { 0.55, 0.78, 0.95 },   -- Wrath: glacial blue
    [3]  = { 0.95, 0.45, 0.15 },   -- Cataclysm: molten orange
    [4]  = { 0.35, 0.80, 0.55 },   -- Mists: jade
    [5]  = { 0.80, 0.50, 0.25 },   -- Draenor: savage bronze
    [6]  = { 0.45, 0.90, 0.30 },   -- Legion: fel
    [7]  = { 0.30, 0.55, 0.90 },   -- Battle for Azeroth: war-sea navy
    [8]  = { 0.78, 0.86, 1.00 },   -- Shadowlands: pale anima
    [9]  = { 0.90, 0.65, 0.30 },   -- Dragonflight: dragon bronze
    [10] = { 0.95, 0.75, 0.40 },   -- The War Within: earthen gold
    [11] = { 0.70, 0.45, 0.95 },   -- Midnight: void violet
}
local EXP_STYLE_DEFAULT = { 0.85, 0.80, 0.65 }

-- ONE pass per patch: sweep every uiMapID for zone-type maps and upsert the full zone registry --
-- name, uiMapID, world map instance id (GetWorldPosFromMapPos). Runs inside the Worker job
-- (MaybeYield per id); rows are added/updated only (flight_master FKs zone names).
function Dashboard:_BuildZoneCatalog()
    local p = self:_p()
    if p.zoneCatalogBuilt then return end
    if not (C_Map and C_Map.GetMapInfo) then return end
    if ns.Versioning and ns.Versioning:IsCurrent(ZONE_DOMAIN) then p.zoneCatalogBuilt = true; return end
    local db = self:DB(); if not db then return end
    ns.Worker:Mark("zone catalog")
    local zoneType = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
    local centre = CreateVector2D and CreateVector2D(0.5, 0.5)
    for id = 1, 3200 do
        local mi = C_Map.GetMapInfo(id)
        if mi and mi.mapType == zoneType and mi.name and mi.name ~= "" then
            local mapID
            if centre and C_Map.GetWorldPosFromMapPos then
                local instance = C_Map.GetWorldPosFromMapPos(id, centre)
                if instance and instance >= 0 then mapID = instance end
            end
            local fields = { ui_map_id = id, map_id = mapID }
            if db:Select("name"):From("zone"):Where("name", "=", mi.name):Limit(1):Run()[1] then
                db:Update("zone", fields, { name = mi.name })
            else
                fields.name = mi.name
                db:Insert("zone", fields)
            end
        end
        ns.Worker:MaybeYield()
    end
    p.zoneCatalogBuilt = true
    if ns.Versioning then ns.Versioning:Stamp(ZONE_DOMAIN) end
end

-- Resolve a zone's typography style: curated -> biome keywords -> the expansion tint on the
-- neutral plate (see the style tables above).
function Dashboard:_ZoneStyle(name, expId)
    local s = ZONE_STYLE[name]
    if s then return s end
    local lower = tostring(name or ""):lower()
    for _, entry in ipairs(BIOME_WORDS) do
        for _, word in ipairs(entry[2]) do
            if lower:find(word, 1, true) then return BIOME_STYLE[entry[1]] end
        end
    end
    return { bg = PLATE_BG, bg2 = PLATE_BG2, fg = EXP_STYLE[expId] or EXP_STYLE_DEFAULT }
end


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

-- ALL recorded quests of one expansion: { id, title, freq, zone }, grouped by zone, weekly before
-- daily, title-sorted -- the tile order of the quest page.
function Dashboard:_QuestsInExpansion(exp)
    local db = self:DB(); if not db then return {} end
    local qb = questExpFilter(db:Select("quest.quest_id", "quest.title", "dashboard_quest.freq", "quest.zone_name")
        :From("dashboard_quest")
        :InnerJoin("quest", { on = { "dashboard_quest.quest_id", "quest.quest_id" } }):Distinct(), exp)
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

-- Render a quest expansion's page: ONE TYPOGRAPHY TILE PER QUEST (title in the serif, styled by
-- its zone; the zone names the titlebar, Weekly/Daily badges the corner), the clicked quest's
-- per-character state opening inline -- the raids/dungeons interaction, applied to quests.
function Dashboard:_ShowQuestPage(page, exp)
    local p = self:_p()
    p.expandedQuest = p.expandedQuest or {}
    local quests = self:_QuestsInExpansion(exp)
    local want, exQ = p.expandedQuest[p.category]
    for _, q in ipairs(quests) do if q.id == want then exQ = q; break end end
    p.expandedQuest[p.category] = exQ and exQ.id or nil   -- drop a stale id
    if exQ then page:SetDetail(self:_QuestDetailGrid(page), self:_FillQuestDetail(page, exQ))
    else page:SetDetail(nil, 0) end
    local lvl = (p.ejTierLevel or {})[exp]
    local tiles = {}
    for _, q in ipairs(quests) do
        local on = exQ and (q.id == exQ.id) or false
        tiles[#tiles + 1] = {
            key = q.id, label = q.zone or "Unknown Zone", selected = on, expanded = on,
            badge = (q.freq == "weekly") and "Weekly" or "Daily",
            badgeKey = (q.freq == "weekly") and "accent" or "green",
            typo = { text = q.title or ("Quest " .. tostring(q.id)),
                     style = self:_ZoneStyle(q.zone, lvl), scale = 0.16 },   -- titles run long: smaller type
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
            key = exp, label = exp, texture = self:_ExpansionLogo(exp),
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
            self:_SetKeystone(mapid, C_ChallengeMode.GetMapUIInfo and C_ChallengeMode.GetMapUIInfo(mapid))
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

-- The newest season raid's splash, for the Current Season overview tile (else nil).
function Dashboard:_LatestSeasonRaidArt()
    local list = self:_SeasonRaidNames()
    if list[1] then return self:_InstanceArt(list[1].name, "raid") end
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

-- ---- dungeons: the CURRENT M+ SEASON (always shown with Mythic 0) --------------------------
-- The current M+ season's dungeon lineup -- can include legacy-expansion dungeons, and they ALL
-- carry a Mythic 0 lockout while in season. From C_ChallengeMode.GetMapTable(); cached + a set.
function Dashboard:_SeasonDungeons()
    local p = self:_p()
    if p.season then return p.season end
    if not (C_ChallengeMode and C_ChallengeMode.GetMapTable and C_ChallengeMode.GetMapUIInfo) then return nil end
    local ids = C_ChallengeMode.GetMapTable()
    if not ids or #ids == 0 then return nil end
    local list, set = {}, {}
    for _, mapID in ipairs(ids) do
        local name = C_ChallengeMode.GetMapUIInfo(mapID)
        if name and name ~= "Keystone Dungeons" then list[#list + 1] = name; set[name] = true end
    end
    table.sort(list)
    p.season = { list = list, set = set }
    return p.season
end

-- The expansion the Current Season belongs to, derived from the dungeons IN the season: the NEWEST
-- expansion represented among them. A season can fold in legacy dungeons, so we take the highest tier
-- level present rather than assuming the live expansion. Returns a tier NAME (for the logo/grouping),
-- or nil before the journal map is ready (or if none of the season's dungeons are mapped yet).
function Dashboard:_SeasonExpansionTier()
    local s = self:_SeasonDungeons()
    local lvl = self:_p().ejTierLevel
    if not (s and lvl) then return nil end
    local bestTier, bestLvl
    for _, name in ipairs(s.list) do
        local tier = self:_InstanceExpansion(name)   -- "Other" (no level) if unmapped
        local l = lvl[tier]
        if l and (not bestLvl or l > bestLvl) then bestTier, bestLvl = tier, l end
    end
    return bestTier
end

-- One column per current-season dungeon; cell = the character's Mythic 0 lock ("x/y") or "-".
function Dashboard:_SeasonColumns()
    local s = self:_SeasonDungeons()
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

-- The modern flexible RAID difficulties (ids), used to seed one catalog row per raid per difficulty.
-- Resolved to LOCALE names via GetDifficultyInfo so a row's `diff` matches a lockout's difficulty
-- name (which is likewise derived from its id in _CollectLockouts).
local RAID_DIFF_IDS = { 17, 14, 15, 16 }   -- Raid Finder, Normal, Heroic, Mythic

-- Upsert a catalog row (insert if missing, else update the given fields). Seeding only runs on the
-- WALK path -- a first run or a new patch -- so refreshing existing rows (art / order / expansion /
-- difficulty) here keeps the persisted catalog current when the journal changes. (A same-patch login
-- reconstructs from the DB and never seeds.) Lock state lives on dashboard_lockout, untouched.
function Dashboard:_SeedInstance(key, fields)
    local db = self:DB(); if not db then return end
    if db:Select("key"):From("dashboard_instance"):Where("key", "=", key):Limit(1):Run()[1] then
        db:Update("dashboard_instance", fields, { key = key })
    else
        fields.key = key
        db:Insert("dashboard_instance", fields)
    end
end

-- Seed the instance CATALOG into dashboard_instance from the Encounter Journal: every raid (one row
-- per difficulty) and every dungeon of the latest expansion (Mythic 0). The current M+ season pool is
-- seeded separately (_SeedSeasonDungeons). Insert-if-missing; needs the journal map (caller guards).
function Dashboard:_SeedInstances()
    local p = self:_p()
    ns.Worker:Mark("seed instances")
    if not (GetDifficultyInfo and p.ejInst) then return end
    self:_SeedExpansions()                                   -- the FK target rows, before any instance
    local season, raidDiffs = p.ejSeasonRaids or {}, p.ejRaidDiffs or {}
    -- one row per (raid instance, difficulty it offers); keyed by journal id so two same-named raids
    -- stay distinct, each under its own home expansion.
    local lore, image, ord = p.ejLore or {}, p.ejImage or {}, p.ejOrd or {}
    for id, rec in pairs(p.ejInst) do
        if rec.isRaid then
            local cs = season[id] and true or false
            for _, did in ipairs(raidDiffs[id] or RAID_DIFF_IDS) do   -- only the difficulties this raid offers
                local diffName = GetDifficultyInfo(did)
                if diffName then
                    self:_SeedInstance(id .. "|" .. did,
                        { instance_id = id, name = rec.name, diff = diffName, diff_id = did,
                          is_raid = true, expansion = rec.tier, current_season = cs,
                          lore_id = lore[rec.name], button_id = image[rec.name], ord = ord[id] })
                end
            end
            ns.Worker:MaybeYield()                               -- spread the inserts across frames
        end
    end
    -- every dungeon of the current expansion (Mythic 0), keyed by journal id
    local cur = self:_CurrentExpansionTier()
    for _, id in ipairs((p.ejDungeonsByTier or {})[cur] or {}) do
        local rec = p.ejInst[id]
        if rec then
            self:_SeedInstance(id .. "|" .. M0_ID,
                { instance_id = id, name = rec.name, diff = M0, diff_id = M0_ID, is_raid = false,
                  expansion = cur, current_season = self:_IsSeasonDungeon(rec.name),
                  lore_id = lore[rec.name], button_id = image[rec.name], ord = ord[id] })
        end
        ns.Worker:MaybeYield()
    end
end

-- True if a dungeon is in the live Mythic+ season rotation (the addon's "Current Season" set).
function Dashboard:_IsSeasonDungeon(name)
    local s = self:_SeasonDungeons()
    return (s and s.set[name]) and true or false
end

-- Refresh the current_season flag on the catalog each pass (the season set can finalise after login,
-- and pre-existing rows seeded before the flag existed default to false). Updates ONLY rows whose
-- expansion is null or a known registry entry, so a stray orphan (e.g. a not-yet-pruned legacy row)
-- can't trip the FK recheck Update runs; the `~=` guards skip rows already in the right state.
function Dashboard:_MarkSeasonFlags()
    ns.Worker:Mark("season flags")
    local db = self:DB(); if not db then return end
    local valid = {}
    for _, e in ipairs(db:Select("name"):From("expansion"):Run()) do valid[denull(e.name)] = true end
    local function safe(r) local e = denull(r.expansion); return e == nil or valid[e] end
    local sr = self:_p().ejSeasonRaids or {}                  -- season RAIDS by journal id
    local sd = self:_SeasonDungeons(); local sdset = (sd and sd.set) or {}   -- season DUNGEONS by name (M+ rotation)
    db:Update("dashboard_instance", { current_season = true },
        function(r) return safe(r) and r.is_raid == true and sr[denull(r.instance_id)] and r.current_season ~= true end)
    ns.Worker:MaybeYield()                       -- each pass scans the catalog: chunk between them
    db:Update("dashboard_instance", { current_season = false },
        function(r) return safe(r) and r.is_raid == true and not sr[denull(r.instance_id)] and r.current_season ~= false end)
    ns.Worker:MaybeYield()
    db:Update("dashboard_instance", { current_season = true },
        function(r) return safe(r) and r.is_raid ~= true and sdset[denull(r.name)] and r.current_season ~= true end)
    ns.Worker:MaybeYield()
    db:Update("dashboard_instance", { current_season = false },
        function(r) return safe(r) and r.is_raid ~= true and not sdset[denull(r.name)] and r.current_season ~= false end)
end

-- Drop catalog rows whose INSTANCE or DIFFICULTY no longer exists: the difficulty id no longer
-- resolves (GetDifficultyInfo), or the instance name is gone from the Encounter Journal catalog
-- (raids + dungeons across every tier). Only runs once the journal is loaded (else the existence set
-- would be empty and wipe everything); a deleted instance cascades to every character's lockout row.
function Dashboard:_PruneInstances()
    local p = self:_p()
    ns.Worker:Mark("prune instances")
    if not (GetDifficultyInfo and p.ejInst) then return end
    local exists = {}
    for id in pairs(p.ejInst) do exists[id] = true end
    if not next(exists) then return end   -- journal somehow empty -- never prune against nothing
    -- which difficulty ids each raid offers (clears rows over-seeded before per-raid difficulties existed)
    local validDiff = {}
    for id, ids in pairs(p.ejRaidDiffs or {}) do
        local s = {}; for _, d in ipairs(ids) do s[d] = true end; validDiff[id] = s
    end
    local db = self:DB(); if not db then return end
    -- predicate runs on the RAW stored row (absent field = nil, not the NULL sentinel)
    db:Delete("dashboard_instance", function(r)
        if r.instance_id == nil then return true end                            -- legacy name-keyed row (pre-id)
        if r.diff_id and not GetDifficultyInfo(r.diff_id) then return true end   -- difficulty retired
        if not exists[r.instance_id] then return true end                       -- instance gone from the journal
        local vd = r.is_raid and validDiff[r.instance_id]
        return (vd and r.diff_id and not vd[r.diff_id]) and true or false        -- a difficulty this raid never had
    end)
end

-- Sort the current M+ season's dungeons into the registry under their HOME expansion (Mythic 0), so a
-- season dungeon from a PAST expansion (e.g. Magister's Terrace) makes that expansion appear as a tile
-- and renders under it -- not only under Current Season. Idempotent; needs the journal map for the
-- home lookup (skips a dungeon whose expansion isn't known yet); _PruneInstances removes these again
-- if the dungeon's difficulty is ever retired.
function Dashboard:_SeedSeasonDungeons()
    ns.Worker:Mark("seed season dungeons")
    local s = self:_SeasonDungeons()
    if not s then return end
    local p = self:_p()
    local lore, image, ord = p.ejLore or {}, p.ejImage or {}, p.ejOrd or {}
    for _, name in ipairs(s.list) do
        ns.Worker:MaybeYield()
        local id = self:_IdForName(name)              -- the newest journal instance of this name (locks identity)
        local rec = id and p.ejInst and p.ejInst[id]
        if rec and rec.tier then
            self:_SetInstance(id .. "|" .. M0_ID,
                { instance_id = id, name = rec.name, diff = M0, diff_id = M0_ID, is_raid = false,
                  expansion = rec.tier, current_season = true,   -- in the season pool by definition
                  lore_id = lore[rec.name], button_id = image[rec.name], ord = ord[id] })
        end
    end
end

-- Columns from the seeded instance catalog, filtered by predicate(registryEntry). Each cell is the
-- character's CURRENT lock for that instance+difficulty (boss progress) or "-" when not locked.
-- Ordered by instance name, then by difficulty RANK (LFR < Normal < Heroic < Mythic) so a raid's
-- difficulty columns read in ascending order rather than alphabetically.
function Dashboard:_LockoutColumns(predicate)
    local cols = {}
    for _, r in pairs(self:_Instances()) do
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
                if self:_HasSeasonRaids() then
                    items[#items + 1] = { key = "raid:current", label = SEASON_LABEL, indent = 2 }
                end
                for _, exp in ipairs(self:_RaidExpansions()) do      -- all raid tiers (full catalog)
                    items[#items + 1] = { key = "raid:" .. exp, label = exp, indent = 2 }
                end
            elseif c.key == "dungeons" and dungeonsOpen then
                if self:_SeasonDungeons() then
                    items[#items + 1] = { key = "dungeon:current", label = SEASON_LABEL, indent = 2 }
                end
                -- Current Expansion (all its dungeons), auto-named; then the remaining expansions
                local curTier = self:_CurrentExpansionTier()
                if curTier then
                    items[#items + 1] = { key = "dungeon:" .. curTier, label = self:_CurrentExpansionName() or curTier, indent = 2 }
                end
                for _, exp in ipairs(self:_KnownExpansions(false)) do
                    if exp ~= SEASON_LABEL and exp ~= curTier then
                        items[#items + 1] = { key = "dungeon:" .. exp, label = exp, indent = 2 }
                    end
                end
            elseif c.key == "quests" and questsOpen then
                -- one node per expansion that has RECORDED quests (self-curating, newest first)
                for _, exp in ipairs(self:_QuestExpansions()) do
                    items[#items + 1] = { key = "quest:" .. exp, label = exp, indent = 2 }
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
    -- quest pages are icon pages too (expansion overview / per-expansion zone grid)
    if key == "quests" then return "Quests", function() return {} end end
    local qexp = key and key:match("^quest:(.+)$")
    if qexp then return qexp .. " Quests", function() return {} end end
    local rexp = key and key:match("^raid:(.+)$")
    if rexp then
        return rexp .. " Raids", function() return self:_CatalogColumns(rexp, true) end
    end
    local dexp = key and key:match("^dungeon:(.+)$")
    if dexp == "current" then
        return SEASON_LABEL, function() return self:_SeasonColumns() end
    elseif dexp and dexp == self:_CurrentExpansionTier() then
        -- the current expansion: every dungeon released in it (the full journal catalog)
        return (self:_CurrentExpansionName() or dexp) .. " Dungeons",
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
    local logo = self:_ExpansionLogo(p.currentExpansion)
    local raidArt = self:_LatestRaidArt()
    local dunArt = self:_SeasonDungeonArt() or self:_LatestDungeonArt()
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
            texture = self:_ExpansionLogo(logoTier),
            label = label,
            onClick = function() p.nav:Select(navKey) end,
        }
    end
    if key == "raids" then
        -- Current Season first (the live season's raids, by flag -- distinct from any one expansion),
        -- pictured with the newest season raid's scene; then one tile per expansion.
        if self:_HasSeasonRaids() then
            tiles[#tiles + 1] = {
                texture = self:_ExpansionLogo(p.currentExpansion),
                label = SEASON_LABEL,
                onClick = function() p.nav:Select("raid:current") end,
            }
            local art = self:_LatestSeasonRaidArt()
            if art then applyArt(tiles[#tiles], art) end
        end
        -- every expansion shows its BANNER (the latest-raid picture is the Current Season tile's job now)
        for _, exp in ipairs(self:_RaidExpansions()) do
            tile(exp, exp, "raid:" .. exp)
        end
    elseif key == "dungeons" then
        local curTier = self:_CurrentExpansionTier()
        if self:_SeasonDungeons() then
            -- The Current Season's title stays "Current Season"; its expansion/logo is derived from
            -- the dungeons in it -- the newest expansion represented (a season can fold in legacy
            -- dungeons). Falls back to the current expansion / newest raid tier before the map loads.
            local seasonTier = self:_SeasonExpansionTier() or curTier or p.currentExpansion
            tile(SEASON_LABEL, seasonTier, "dungeon:current")
            -- Current Season shows a random season-dungeon scene, distinct from the expansion logo
            local art = self:_SeasonDungeonArt()
            if art then applyArt(tiles[#tiles], art) end
        end
        -- Current Expansion: every dungeon released in it (a superset of the M+ season). Auto-named
        -- and pictured from the live expansion -- the emblem, like the raid tiles use.
        if curTier then
            tiles[#tiles + 1] = {
                texture = self:_CurrentExpansionLogo() or self:_ExpansionLogo(curTier),
                label = self:_CurrentExpansionName() or curTier,
                onClick = function() p.nav:Select("dungeon:" .. curTier) end,
            }
        end
        -- one tile per remaining expansion (skip the "Current Season" pseudo-tier and the current one)
        for _, exp in ipairs(self:_KnownExpansions(false)) do
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

    -- the Home/Raids/Dungeons overviews are journal-style icon grids, not the data grid. Each is its
    -- OWN cached page: switching between them just shows one and hides the rest -- the tiles and their
    -- textures stay loaded and aren't re-edited (each tile's Texture widget memoises unchanged art).
    -- a "raid:<group>" / "dungeon:<group>" key is itself an icon grid -- the raids / dungeons of that
    -- group as tiles, each with its own art, the lockouts opening inline -- one level below the overview.
    local raidExp = p.category:match("^raid:([^|]+)$")
    local dunGrp  = p.category:match("^dungeon:([^|]+)$")
    local questExp = p.category:match("^quest:(.+)$")
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
            self:_ShowInstancePage(page, self:_SeasonRaidNames(), p.currentExpansion, true)
        elseif raidExp then
            p.catTitle:SetText(raidExp .. " Raids")
            self:_ShowInstancePage(page, self:_RaidsInExpansion(raidExp), raidExp, true)
        elseif dunGrp == "current" then
            p.catTitle:SetText(SEASON_LABEL)
            self:_ShowInstancePage(page, self:_SeasonDungeonNames(), self:_SeasonExpansionTier() or p.currentExpansion, false)
        elseif dunGrp then
            local cur = self:_CurrentExpansionTier()
            p.catTitle:SetText(((dunGrp == cur and (self:_CurrentExpansionName() or dunGrp)) or dunGrp) .. " Dungeons")
            self:_ShowInstancePage(page, self:_DungeonsInExpansion(dunGrp), dunGrp, false)
        elseif p.category == "quests" then
            p.catTitle:SetText("Quests")
            page:SetTiles(self:_QuestExpansionTiles())
        elseif questExp then
            p.catTitle:SetText(questExp .. " Quests")
            self:_ShowQuestPage(page, questExp)
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
    local chars = self:_Chars()
    local e = chars[self:_SelfKey()]
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
    deps = { "SlashCommand", "Secrets", "Worker", "Versioning" },   -- DatabaseManager is added automatically (see `tables`)
    -- Account-wide cross-character snapshots, stored relationally (no nested blobs, no duplicated
    -- reference data). Vault/lockout/quest cascade-delete with their character; a lockout references
    -- the account-wide dashboard_instance registry (its name/difficulty), a quest references the
    -- shared `quest` table (its title), and a keystone references the local keystone name table.
    tables = {
        -- The `keystone` reference table (map id -> display name) that dashboard_char.ks_mapid points
        -- at is defined CENTRALLY in Core/DB/CoreTables.lua, alongside faction/quest -- it's plain
        -- account-agnostic reference data, not owned by this module. Dashboard still fills it
        -- (_SetKeystone / _SeedKeystones via self:DB()).
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
