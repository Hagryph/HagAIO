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

-- Raid difficulty -> short tag + rank (highest rank wins when a char is locked at several). enUS
-- names; an unknown locale falls back to the first letter, so it degrades, never breaks.
local DIFF = {
    ["Looking For Raid"] = { abbr = "LFR", rank = 1 }, ["Raid Finder"] = { abbr = "LFR", rank = 1 },
    Normal = { abbr = "N", rank = 2 }, Heroic = { abbr = "H", rank = 3 }, Mythic = { abbr = "M", rank = 4 },
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

-- The Home nav entry, labelled "Overview". Selecting it shows the overview -- an icon grid of every
-- category. Re-clicking the already-active category also returns here (see the nav onReselect).
local HOME_LABEL = "Overview"

-- The current M+ season dungeon entry's label. Also used to DEDUPE the dungeon overview: the journal
-- exposes the current dungeons under a "Current Season" pseudo-tier, so a per-expansion tile carrying
-- this same label would just duplicate this entry (with no expansion logo) -- we drop it. (enUS, like
-- the rest of this module's journal labels.)
local SEASON_LABEL = "Current Season"

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
    { key = "quests", label = "Quests", header = true },
    { key = "weekly", label = "Weekly", indent = true,
      columns = function(chars) return questColumns(chars, "weekly") end },
    { key = "daily",  label = "Daily",  indent = true,
      columns = function(chars) return questColumns(chars, "daily") end },
}

-- ---- lifecycle ------------------------------------------------------------
function Dashboard:OnInitialize()
    local p = self:_p()
    p.built = false
    p.shown = false
    p.category = "home"   -- open on the overview (an icon grid of every category)
end

function Dashboard:OnEnable()
    -- Targeted collectors keep each fire cheap (the never-debounce rule): a bag update only
    -- re-reads the keystone, a quest turn-in only records that quest.
    -- The full snapshot scans several APIs and writes many DB rows, so it is DEFERRED past the loading
    -- screen (see _ScheduleRefresh): running it inline on PLAYER_ENTERING_WORLD / at enable stretched
    -- the load bar. The targeted collectors below stay inline -- each fire is cheap (the never-debounce
    -- rule): a bag update only re-reads the keystone, a quest turn-in only records that quest.
    self:On("PLAYER_ENTERING_WORLD",      function() self:_ScheduleRefresh() end)
    self:On("PLAYER_LOGOUT",              function() self:_Snapshot() end)   -- inline: must finish before logout
    self:On("WEEKLY_REWARDS_UPDATE",      function() self:_CollectVault();    self:_RenderIfShown() end)
    self:On("CHALLENGE_MODE_COMPLETED",   function() self:_CollectKeystone(); self:_RenderIfShown() end)
    self:On("CHALLENGE_MODE_MAPS_UPDATE", function() self:_CollectKeystone(); self:_RenderIfShown() end)
    self:On("BAG_UPDATE_DELAYED",         function() self:_CollectKeystone(); self:_RenderIfShown() end)
    self:On("UPDATE_INSTANCE_INFO",       function() self:_CollectLockouts(); self:_RenderIfShown() end)
    self:On("BOSS_KILL",                  function() self:_CollectLockouts() end)
    self:On("QUEST_TURNED_IN",            function(_, questID) self:_RecordQuest(questID) end)
    self:_ScheduleRefresh()                         -- deferred; builds the catalog + snapshots
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
    if self:_CharRow(key) then db:Update("dashboard_char", changes, function(x) return x.char_key == key end)
    else changes.char_key = key; db:Insert("dashboard_char", changes) end
end

-- Replace ALL of the viewing character's rows in a child table (dashboard_vault / dashboard_lockout)
-- with `rows` (each a column map already carrying the rest of its PK -- vault an `ordinal`, lockout an
-- `instance_key`). Delete-then-insert mirrors the old whole-substructure replacement.
function Dashboard:_ReplaceSelfChildren(tname, rows)
    local db = self:DB(); if not db then return end
    local key = self:_SelfKey()
    db:Delete(tname, function(x) return x.char_key == key end)
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
    local ksName, qTitle, inst = {}, {}, self:_Instances()
    for _, k in ipairs(db:Select("*"):From("keystone"):Run()) do ksName[k.mapid] = denull(k.name) end
    for _, q in ipairs(db:Select("quest_id", "title"):From("quest"):Run()) do qTitle[q.quest_id] = denull(q.title) end

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
            doc.quests[q.freq][q.quest_id] = qTitle[q.quest_id] or ("Quest " .. q.quest_id)
        end
    end
    return chars
end

-- Upsert the local keystone name table (map id -> display name); the keystone names are reference
-- data, rebuilt each session, that dashboard_char's ks_mapid FK points at.
function Dashboard:_SetKeystone(mapid, name)
    local db = self:DB(); if not (db and mapid) then return end
    if db:Select("mapid"):From("keystone"):Where("mapid", "=", mapid):Limit(1):Run()[1] then
        db:Update("keystone", { name = name }, function(x) return x.mapid == mapid end)
    else db:Insert("keystone", { mapid = mapid, name = name }) end
end

-- Ensure the local keystone table has a name for every map id any character holds, so an alt's
-- keystone (its map id persists on dashboard_char, but the local name table is rebuilt each session)
-- still renders a name. Cheap: GetMapUIInfo resolves any map id offline.
function Dashboard:_SeedKeystones()
    local db = self:DB(); if not db then return end
    if not (C_ChallengeMode and C_ChallengeMode.GetMapUIInfo) then return end
    for _, c in ipairs(db:Select("ks_mapid"):From("dashboard_char"):Run()) do
        local mapid = denull(c.ks_mapid)
        if mapid and not db:Select("mapid"):From("keystone"):Where("mapid", "=", mapid):Limit(1):Run()[1] then
            self:_SetKeystone(mapid, C_ChallengeMode.GetMapUIInfo(mapid))
        end
    end
end

-- Reconstruct the instance registry keyed by "name|difficulty". Read-only; the writers below mutate
-- dashboard_instance directly (the old code mutated this returned table in place).
function Dashboard:_Instances()
    local db = self:DB(); if not db then return {} end
    local out = {}
    for _, r in ipairs(db:Select("*"):From("dashboard_instance"):Run()) do
        out[r.key] = { name = denull(r.name), diff = denull(r.diff), isRaid = denull(r.is_raid),
            diffID = denull(r.diff_id), total = denull(r.total), expansion = denull(r.expansion) }
    end
    return out
end

-- Upsert one dashboard_instance row (key = "name|difficulty"), merging `changes` (omitted keys keep
-- their stored value -- so a later sighting with a nil diffID/total never clobbers a known one).
function Dashboard:_SetInstance(key, changes)
    local db = self:DB(); if not db then return end
    local exists = db:Select("key"):From("dashboard_instance"):Where("key", "=", key):Limit(1):Run()[1]
    if exists then db:Update("dashboard_instance", changes, function(x) return x.key == key end)
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
function Dashboard:_CollectLockouts()
    self:_SetSelf({})   -- ensure the char row (FK target) + last_seen, as the old _SelfEntry() did
    local n = (GetNumSavedInstances and GetNumSavedInstances()) or 0
    local locks, seen = {}, {}
    for i = 1, n do
        local name, _, reset, diffID, locked, _, _, isRaid, _, diff, numEnc, prog = GetSavedInstanceInfo(i)
        if locked and reset and reset > 0 then
            -- Use the difficulty's CANONICAL name (from its id) so a lock matches the seeded catalog
            -- row for the same instance+difficulty instead of forking a duplicate registry entry.
            local diffName = (diffID and GetDifficultyInfo and GetDifficultyInfo(diffID)) or diff
            local instKey = name .. "|" .. (diffName or "")
            -- remember the instance forever in the self-curating registry FIRST (the lock's FK target);
            -- omitted keys keep their stored value, so a sighting with a nil diffID/total never clobbers one
            local changes = { name = name, diff = diffName, is_raid = isRaid and true or false }
            if diffID then changes.diff_id = diffID end   -- the difficulty ID (locale-proof; drives the prune)
            if numEnc then changes.total = numEnc end
            local exp = self:_InstanceExpansion(name)
            if exp ~= "Other" then changes.expansion = exp end   -- fill the tier once the journal map is ready
            self:_SetInstance(instKey, changes)
            if not seen[instKey] then   -- one lock row per instance (the PK is char + instance_key)
                seen[instKey] = true
                locks[#locks + 1] = { instance_key = instKey, total = numEnc,
                    progress = plainNum(prog), reset = reset }
            end
        end
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
        -- record the title on the shared `quest` table (the FK target), preserving any `time` Questing
        -- learned; the per-character row then just references the quest id under its frequency
        if db:Select("quest_id"):From("quest"):Where("quest_id", "=", questID):Limit(1):Run()[1] then
            db:Update("quest", { title = title }, function(x) return x.quest_id == questID end)
        else db:Insert("quest", { quest_id = questID, title = title }) end
        local key = self:_SelfKey()
        local exists = db:Select("quest_id"):From("dashboard_quest")
            :Where("char_key", "=", key):AndWhere("freq", "=", freq):AndWhere("quest_id", "=", questID):Limit(1):Run()[1]
        if not exists then db:Insert("dashboard_quest", { char_key = key, freq = freq, quest_id = questID }) end
    end
    self:_RenderIfShown()
end

-- Refresh AFTER the world is on screen, never during the loading screen. C_Timer callbacks don't fire
-- while a loading screen is up, so a pass scheduled on PLAYER_LOGIN / at enable runs on the first real
-- frame once the world has loaded -- exactly where the data should load. Coalesced: rapid re-fires
-- (every PLAYER_ENTERING_WORLD on a zone/instance change) collapse into ONE pending pass. Each pass
-- (re)builds the instance catalog (once the journal is available) and snapshots this character.
function Dashboard:_ScheduleRefresh()
    local p = self:_p()
    if p.refreshPending then return end
    p.refreshPending = true
    C_Timer.After(0, function()
        p.refreshPending = false
        if not self:IsEnabled() then return end   -- skip if disabled before the frame ran
        self:_BuildCatalog()
        self:_Snapshot()
    end)
end

-- Populate dashboard_instance with the full catalog the dashboard shows -- every raid (one row per
-- difficulty) and the latest expansion's + current season's dungeons -- and drop rows whose instance
-- or difficulty no longer exists. The heavy raid/dungeon seed + prune run ONCE per session (the
-- journal catalog is static within a client); the small season pool re-seeds each pass since it can
-- finalise a moment after login. No-op until the Encounter Journal has loaded (retried next refresh).
function Dashboard:_BuildCatalog()
    local p = self:_p()
    self:_ExpansionMap()                 -- walk the journal once (cached); the seed/prune source
    if not p.ejMap then return end       -- journal not ready yet -- try again on the next refresh
    if not p.seededCatalog then
        self:_SeedInstances()            -- all raids (per difficulty) + latest-expansion dungeons
        self:_BackfillExpansions()       -- fix lockout rows recorded before the journal was ready
        self:_PruneInstances()           -- drop instances/difficulties Blizzard has removed
        p.seededCatalog = true
    end
    self:_SeedSeasonDungeons()           -- current M+ season pool (cheap + idempotent)
end

-- Fill the expansion on any dashboard_instance row recorded (by a lockout sighting) before the
-- journal map was ready, so it groups under the right tier instead of "Other".
function Dashboard:_BackfillExpansions()
    local map, db = self:_p().ejMap, self:DB()
    if not (map and db) then return end
    for _, r in ipairs(db:Select("key", "name", "expansion"):From("dashboard_instance"):Run()) do
        local exp = denull(r.expansion)
        if (not exp or exp == "Other") and map[r.name] then
            local k = r.key
            db:Update("dashboard_instance", { expansion = map[r.name] }, function(x) return x.key == k end)
        end
    end
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
    local map, raidsByTier, dungeonsByTier, tierOrder, found = {}, {}, {}, {}, false
    local tierLevel = {}   -- tier name -> expansionLevel (EJ tier index 1 = Classic = expansion 0)
    local image = {}       -- instance name -> EJ buttonImage1 (compact tile art; banner fallback)
    local lore = {}        -- instance name -> EJ loreImage (the big right-side splash; preferred art)
    local prev = EJ_GetCurrentTier and EJ_GetCurrentTier()
    local function walk(tier, tierName, isRaid, sink)
        EJ_SelectTier(tier)
        local i = 1
        while true do
            local instID, name, _, _, buttonImage, loreImage = EJ_GetInstanceByIndex(i, isRaid)
            if not instID then break end
            if name == "Keystone Dungeons" then name = nil end   -- dungeon meta-entry, never a real instance
            -- The RAID list carries a world-boss "meta" entry named after the expansion itself
            -- (e.g. "Pandaria", "Draenor", "Midnight") rather than after a real raid -- it has no
            -- weekly lockout, so drop it. The label matches the tier (exactly, or as its trailing
            -- word for long tier names like "Mists of Pandaria" -> "Pandaria").
            if isRaid and name and tierName
               and (name == tierName or tierName:match("(%S+)%s*$") == name) then
                name = nil
            end
            if name and tierName then
                -- map keeps the OLDEST tier (the home expansion); art keeps the NEWEST tier. Two
                -- instances can share a name (a legacy dungeon AND a reworked current-season version,
                -- e.g. Magister's Terrace) -- tiers are walked newest-first, so the first art we see is
                -- the current version's, which is the one the M+ season uses.
                map[name] = tierName; found = true
                if buttonImage and not image[name] then image[name] = buttonImage end
                if loreImage  and not lore[name]  then lore[name]  = loreImage  end
                if sink then sink[#sink + 1] = name end
            end
            i = i + 1
        end
    end
    for tier = EJ_GetNumTiers(), 1, -1 do   -- newest tier first
        local tierName = EJ_GetTierInfo(tier)
        -- "World Raids" is a cross-expansion world-boss bucket, not a real expansion -- drop it so it
        -- doesn't sit among the expansion tiles (Midnight, Pandaria, ...). (enUS, like the other labels.)
        if tierName == "World Raids" then tierName = nil end
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
    if prev then pcall(EJ_SelectTier, prev) end   -- restore the journal's selected tier
    if found then
        p.ejMap = map
        p.ejRaidsByTier = raidsByTier         -- tier -> { all raid names } (every raid has a weekly lock)
        p.ejDungeonsByTier = dungeonsByTier   -- tier -> { all dungeon names }
        p.ejTierOrder = tierOrder             -- tiers with raids, newest first
        p.ejTierLevel = tierLevel             -- tier name -> expansionLevel (for native logos)
        p.ejImage = image                     -- instance name -> EJ tile art (buttonImage1; banner fallback)
        p.ejLore = lore                       -- instance name -> EJ splash (loreImage; preferred art)
        -- The CURRENT raid tier is the expansion that actually OWNS the newest raids, derived from the
        -- raids themselves -- not merely the newest journal tier that lists some. A new tier can
        -- re-list the prior expansion's raids before its own ship (a "Midnight" tier showing TWW
        -- raids); until a raid whose HOME is the new expansion exists, the current tier is still the
        -- prior one. map[] holds each raid's oldest/home tier, so take the newest home across them.
        local curTier, curLvl
        for _, names in pairs(raidsByTier) do
            for _, nm in ipairs(names) do
                local home = map[nm]
                local l = home and tierLevel[home]
                if l and (not curLvl or l > curLvl) then curTier, curLvl = home, l end
            end
        end
        p.currentExpansion = curTier or tierOrder[1] or EJ_GetTierInfo(EJ_GetNumTiers())
    end
    return p.ejMap
end

-- The expansion an instance (raid OR dungeon) belongs to (cache read only; "Other" until built).
function Dashboard:_InstanceExpansion(name)
    local m = self:_p().ejMap
    return (m and m[name]) or "Other"
end

-- The native expansion logo texture for a tier (the icon WoW ships per expansion), or nil. Used
-- for the overview's icon tiles. GetExpansionDisplayInfo(expansionLevel) -> { logo, banner }.
function Dashboard:_ExpansionLogo(tierName)
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
    if r and #r > 0 then return self:_InstanceArt(r[#r], "raid") end
end

function Dashboard:_LatestDungeonArt()
    local p = self:_p()
    local d = p.ejDungeonsByTier and p.currentExpansion and p.ejDungeonsByTier[p.currentExpansion]
    if d and #d > 0 then return self:_InstanceArt(d[#d], "dungeon") end
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

-- Insert a catalog row only if it's MISSING. The catalog is static reference data, so an existing
-- row never needs rewriting (its expansion is corrected by _BackfillExpansions, its lock state lives
-- on dashboard_lockout) -- a plain existence check avoids ~200 redundant updates on every re-seed.
function Dashboard:_SeedInstance(key, fields)
    local db = self:DB(); if not db then return end
    if db:Select("key"):From("dashboard_instance"):Where("key", "=", key):Limit(1):Run()[1] then return end
    fields.key = key
    db:Insert("dashboard_instance", fields)
end

-- Seed the instance CATALOG into dashboard_instance from the Encounter Journal: every raid (one row
-- per difficulty) and every dungeon of the latest expansion (Mythic 0). The current M+ season pool is
-- seeded separately (_SeedSeasonDungeons). Insert-if-missing; needs the journal map (caller guards).
function Dashboard:_SeedInstances()
    if not (GetDifficultyInfo and self:_p().ejMap) then return end
    for tier, names in pairs(self:_p().ejRaidsByTier or {}) do
        for _, name in ipairs(names) do
            for _, id in ipairs(RAID_DIFF_IDS) do
                local diffName = GetDifficultyInfo(id)
                if diffName then
                    self:_SeedInstance(name .. "|" .. diffName,
                        { name = name, diff = diffName, diff_id = id, is_raid = true, expansion = tier })
                end
            end
        end
    end
    local cur = self:_CurrentExpansionTier()
    for _, name in ipairs((self:_p().ejDungeonsByTier or {})[cur] or {}) do
        self:_SeedInstance(name .. "|" .. M0,
            { name = name, diff = M0, diff_id = M0_ID, is_raid = false, expansion = cur })
    end
end

-- Drop catalog rows whose INSTANCE or DIFFICULTY no longer exists: the difficulty id no longer
-- resolves (GetDifficultyInfo), or the instance name is gone from the Encounter Journal catalog
-- (raids + dungeons across every tier). Only runs once the journal is loaded (else the existence set
-- would be empty and wipe everything); a deleted instance cascades to every character's lockout row.
function Dashboard:_PruneInstances()
    if not (GetDifficultyInfo and self:_p().ejMap) then return end
    local exists = {}
    for _, names in pairs(self:_p().ejRaidsByTier or {})    do for _, n in ipairs(names) do exists[n] = true end end
    for _, names in pairs(self:_p().ejDungeonsByTier or {}) do for _, n in ipairs(names) do exists[n] = true end end
    if not next(exists) then return end   -- journal somehow empty -- never prune against nothing
    local db = self:DB(); if not db then return end
    -- predicate runs on the RAW stored row (absent field = nil, not the NULL sentinel)
    db:Delete("dashboard_instance", function(r)
        if r.diff_id and not GetDifficultyInfo(r.diff_id) then return true end   -- difficulty retired
        return not exists[r.name]                                               -- instance gone from the catalog
    end)
end

-- Sort the current M+ season's dungeons into the registry under their HOME expansion (Mythic 0), so a
-- season dungeon from a PAST expansion (e.g. Magister's Terrace) makes that expansion appear as a tile
-- and renders under it -- not only under Current Season. Idempotent; needs the journal map for the
-- home lookup (skips a dungeon whose expansion isn't known yet); _PruneInstances removes these again
-- if the dungeon's difficulty is ever retired.
function Dashboard:_SeedSeasonDungeons()
    local s = self:_SeasonDungeons()
    if not s then return end
    for _, name in ipairs(s.list) do
        local exp = self:_InstanceExpansion(name)
        if exp ~= "Other" then
            self:_SetInstance(name .. "|" .. M0,
                { name = name, diff = M0, diff_id = M0_ID, is_raid = false, expansion = exp })
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

-- Is a category enabled in the settings? Dynamic "raid:<exp>" keys follow the Raids toggle.
function Dashboard:_CategoryVisible(key)
    if key:match("^raid:") then return self:GetSetting("show_raids") ~= false end
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
    local items = { { key = "home", label = HOME_LABEL } }   -- "Overview" Home entry, above everything
    for _, c in ipairs(CATEGORIES) do
        if c.header then
            items[#items + 1] = { section = c.label }
        elseif self:_CategoryVisible(c.key) then
            items[#items + 1] = { key = c.key, label = c.label, indent = c.indent and 1 or 0 }
            -- a deeper sub-node per expansion, only while this category is open (collapsible tree)
            if c.key == "raids" and raidsOpen then
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
    local logo = self:_ExpansionLogo(p.currentExpansion)
    local raidArt = self:_LatestRaidArt()
    local dunArt = self:_SeasonDungeonArt() or self:_LatestDungeonArt()
    local defs = {
        { key = "mplus",    label = "Mythic+",       contain = true,
          texture = "Interface\\Icons\\Achievement_ChallengeMode_Gold" },
        { key = "raids",    label = "Raids",         art = raidArt, fallback = logo },
        { key = "dungeons", label = "Dungeons",      art = dunArt,  fallback = logo },
        { key = "weekly",   label = "Weekly Quests", contain = true,
          texture = "Interface\\Icons\\Achievement_Quests_Completed_06" },
        { key = "daily",    label = "Daily Quests",  contain = true,
          texture = "Interface\\Icons\\INV_Misc_PocketWatch_01" },
    }
    local tiles = {}
    for _, d in ipairs(defs) do
        if self:_CategoryVisible(d.key) then
            local tile = { label = d.label, contain = d.contain,
                texture = d.texture or d.fallback, onClick = go(d.key) }
            if d.art then applyArt(tile, d.art) end
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
        for _, exp in ipairs(self:_RaidExpansions()) do
            tile(exp, exp, "raid:" .. exp)
            -- the current tier's tile shows the latest raid's picture, not the expansion logo
            if exp == p.currentExpansion then
                local art = self:_LatestRaidArt()
                if art then applyArt(tiles[#tiles], art) end
            end
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
    self:_ExpansionMap()                 -- build the raid->expansion map (no-op once cached); for tile art
    self:_SeedKeystones()                -- fill local keystone names for every alt's stored map id
    -- (the instance catalog -- seed, expansion backfill, prune -- is built on the deferred refresh pass)

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
    if p.category == "home" or p.category == "raids" or p.category == "dungeons" then
        p.grid:Hide()
        local page = self:_IconPage(p.category)
        for _, g in pairs(p.iconPages) do g:SetShown(g == page) end
        if p.category == "home" then
            p.catTitle:SetText("Overview")
            page:SetTiles(self:_CategoryTiles())
        else
            p.catTitle:SetText(label)
            page:SetTiles(self:_OverviewTiles(p.category))
        end
        page:ScrollTop()
        return
    end
    p.catTitle:SetText(label)
    for _, g in pairs(p.iconPages) do g:Hide() end   -- data grid view: hide every icon page
    p.grid:Show()

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
    deps = { "SlashCommand", "Secrets" },   -- DatabaseManager is added automatically (see `tables`)
    -- Account-wide cross-character snapshots, stored relationally (no nested blobs, no duplicated
    -- reference data). Vault/lockout/quest cascade-delete with their character; a lockout references
    -- the account-wide dashboard_instance registry (its name/difficulty), a quest references the
    -- shared `quest` table (its title), and a keystone references the local keystone name table.
    tables = {
        -- keystone map id -> display name. LOCAL: pure reference data, rebuilt each session from
        -- C_ChallengeMode.GetMapUIInfo (see _SetKeystone / _SeedKeystones); dashboard_char points at it.
        keystone = { scope = "local", columns = {
            { name = "mapid", type = "integer", primaryKey = true },
            { name = "name",  type = "text" },
        } },
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
        dashboard_quest = { scope = "global",
            columns = {
                { name = "char_key", type = "text", nullable = false,
                    references = { table = "dashboard_char", column = "char_key", onDelete = "cascade" } },
                { name = "freq",     type = "text",    nullable = false },    -- "daily" | "weekly"
                { name = "quest_id", type = "integer", nullable = false,
                    references = { table = "quest", column = "quest_id", onDelete = "cascade" } },
            },
            primaryKey = { "char_key", "freq", "quest_id" } },
        dashboard_instance = { scope = "global", columns = {
            { name = "key",       type = "text", primaryKey = true },         -- "name|difficulty"
            { name = "name",      type = "text" },
            { name = "diff",      type = "text" },
            { name = "is_raid",   type = "boolean" },
            { name = "diff_id",   type = "integer" },                         -- locale-proof difficulty id (drives the prune)
            { name = "total",     type = "integer" },
            { name = "expansion", type = "text" },                           -- journal tier name once known
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
        { type = "toggle", key = "show_weekly",   label = "Weekly Quests", default = true },
        { type = "toggle", key = "show_daily",    label = "Daily Quests",  default = true },
        { type = "note", text = "Choose which categories appear in the Dashboard. Open it with /hag dashboard." },
    },
}))
