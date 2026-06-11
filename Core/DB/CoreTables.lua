local addonName, ns = ...

-- Core/DB/CoreTables.lua
-- The central "predefined tables" location: common reference data that belongs to the addon as a
-- whole rather than any one feature, contributed into the single shared database (see
-- DatabaseManager). Defining them here once means every module/service can JOIN to them instead of
-- each keeping its own copy -- the whole reason for one shared database.
--
-- These illustrate all three scopes:
--   * faction       -- LOCAL: rebuilt from code every session, fixed reference rows (seeded).
--   * zone          -- LOCAL: rebuilt at runtime from the world map (populated by its owner; the
--                      table is defined here, the rows are filled when the map is available).
--   * flight_master -- GLOBAL: account-wide, accumulated as flight masters are discovered (the Misc
--                      module fills it when a taxi map is opened). It JOINS to faction -- a global
--                      table referencing a local one, which is exactly the shared-reference win.

ns.DB = ns.DB or {}

-- Scopes are given as bare strings ("local"/"global"/"char") -- the schema validates them against
-- ns.DB.Scope at build time. Using strings (not the enum) keeps this plain data file free of any
-- load-order dependency on Types.lua (the .toc loads Core/DB/* alphabetically).
ns.DB.CoreTables = {
    -- ---- settings / profiles (plain tables; the cascade lives in Lib/SettingsTables.lua) ----------
    -- The profile REGISTRY: one row per named config profile, account-wide. `is_global` marks the
    -- single exclusive profile auto-applied to a character that has loaded none. Every per-namespace
    -- profile table (p_*, profile_module_enable, profile_editmode) FKs back to `name` with cascade
    -- delete, so removing a profile row removes all of its values.
    profile = {
        scope = "global",
        columns = {
            { name = "name",      type = "text",    primaryKey = true },
            { name = "is_global", type = "boolean" },
        },
    },

    -- This character's loaded-profile pointer (the cascade's middle layer), a single row (id = 1).
    config = {
        scope = "char",
        columns = {
            { name = "id",             type = "integer", primaryKey = true },
            { name = "loaded_profile", type = "text" },     -- nil = no profile loaded
        },
    },

    -- Module enable-state. `module_enable` is THIS character's overrides (absent = inherit profile/
    -- default); `profile_module_enable` is the enable-state captured inside each profile.
    module_enable = {
        scope = "char",
        columns = {
            { name = "name",    type = "text", primaryKey = true },   -- module name
            { name = "enabled", type = "boolean" },
        },
    },
    profile_module_enable = {
        scope = "global",
        columns = {
            { name = "profile", type = "text", references = { table = "profile", column = "name", onDelete = "cascade" } },
            { name = "name",    type = "text" },                       -- module name
            { name = "enabled", type = "boolean" },
        },
        primaryKey = { "profile", "name" },
    },

    -- EditMode frame layout (per-frame { point, x, y }), cascaded like settings: `editmode` is this
    -- character's overrides; `profile_editmode` is the layout captured inside each profile.
    editmode = {
        scope = "char",
        columns = {
            { name = "key",   type = "text", primaryKey = true },      -- frame registration key
            { name = "point", type = "text" },
            { name = "x",     type = "number" },
            { name = "y",     type = "number" },
        },
    },
    profile_editmode = {
        scope = "global",
        columns = {
            { name = "profile", type = "text", references = { table = "profile", column = "name", onDelete = "cascade" } },
            { name = "key",     type = "text" },
            { name = "point",   type = "text" },
            { name = "x",       type = "number" },
            { name = "y",       type = "number" },
        },
        primaryKey = { "profile", "key" },
    },

    -- Logger preferences (account-wide), a single row (id = 1). Logger is a core singleton, not a
    -- DatabaseOwner, so it reaches this through ns.DatabaseManager:Shared().
    logger = {
        scope = "global",
        columns = {
            { name = "id",        type = "integer", primaryKey = true },
            { name = "min_level", type = "integer" },
            { name = "echo",      type = "boolean" },
            { name = "keep",      type = "integer" },
        },
    },

    -- Quests, account-wide reference data shared by every feature that knows something about a quest.
    -- Keyed by quest_id; each writer fills only what it knows and upserts (omitted columns are kept):
    --   * Questing records a quest's time limit  -> `time`  (a quest is "timed" IFF time is non-null)
    --   * Dashboard records a turn-in's title     -> `title`
    -- so dashboard_quest can reference quest_id and never duplicate the title, and the timed-quest
    -- registry is simply "the quest rows whose time is set".
    quest = {
        scope = "global",
        columns = {
            { name = "quest_id",    type = "integer", primaryKey = true },
            { name = "title",       type = "text" },    -- display title (Dashboard); nil until seen
            { name = "time",        type = "number" },  -- time limit in seconds (Questing); nil = not timed
            -- AUTO-DISCOVERED at turn-in (Dashboard:_RecordQuest): where the quest lives, so the
            -- dashboard's quest pages can group by expansion -> zone without any curated list.
            { name = "zone_map_id", type = "integer" }, -- uiMapID (quest's map, or the player's at turn-in)
            { name = "zone_name",   type = "text" },    -- display zone name for that map
            { name = "expansion",   type = "text" },    -- expansion display name (EXPANSION_NAME<n>)
        },
    },

    -- Mythic+ keystone reference: map id -> display name. LOCAL (rebuilt each session from
    -- C_ChallengeMode.GetMapUIInfo). The Dashboard module fills it (_SetKeystone / _SeedKeystones) and
    -- dashboard_char.ks_mapid references it. Defined here, not in Dashboard, so the reference table
    -- isn't tied to one module's load -- any feature can join to it.
    keystone = {
        scope = "local",
        columns = {
            { name = "mapid", type = "integer", primaryKey = true },
            { name = "name",  type = "text" },
        },
    },

    -- Alliance / Horde / Neutral, fixed by id. In memory only (rebuilt each session from this seed).
    faction = {
        scope = "local",
        columns = {
            { name = "tag",  type = "text", primaryKey = true },   -- UnitFactionGroup value (the PK)
            { name = "name", type = "text", nullable = false },
        },
        seed = function(db)
            db:InsertAll("faction", {            -- batch insert (one call), not row-by-row
                { tag = "Alliance", name = "Alliance" },
                { tag = "Horde",    name = "Horde" },
                { tag = "Neutral",  name = "Neutral" },
            })
        end,
    },

    -- Map zones, discovered from the world map (the LocalTables service inserts each zone name as
    -- flight masters are discovered). GLOBAL/account-wide: a zone is only learned when a character
    -- with that flight point opens its taxi map, so we can't cheaply rediscover every zone each
    -- session -- persist what we've seen instead of rebuilding from nothing.
    zone = {
        scope = "global",
        columns = {
            { name = "name", type = "text", primaryKey = true },   -- zone name (the PK), e.g. "Elwynn Forest"
        },
    },

    -- Flight masters, discovered (with their zone + map coords) by the LocalTables service whenever a
    -- taxi map opens. JOINS to the faction (local) and zone (global) tables. Keyed by node_id -- the canonical
    -- C_TaxiMap nodeID, GLOBALLY UNIQUE per physical flight point -- so there is exactly one row per
    -- node. A neutral flight point has ONE nodeID seen by BOTH factions, so when the rival faction
    -- discovers an existing node its faction is flipped to "Neutral" (see LocalTables._DiscoverMaster).
    -- A master is only created once its zone is known (zone is NOT NULL); recording looks masters up.
    flight_master = {
        scope = "global",
        columns = {
            { name = "node_id", type = "integer", primaryKey = true },  -- canonical C_TaxiMap nodeID (the PK; unique per point)
            { name = "faction", type = "text", nullable = false, references = { table = "faction", column = "tag" } },
            { name = "zone",    type = "text", nullable = false, references = { table = "zone", column = "name", onDelete = "cascade" } },
            { name = "name",    type = "text", nullable = false },       -- flight master name only (e.g. "Stormwind")
            { name = "x",       type = "number" },                       -- node position on the continent map
            { name = "y",       type = "number" },
        },
        indices = { { columns = { "faction" } }, { columns = { "name" } } },
    },
}
