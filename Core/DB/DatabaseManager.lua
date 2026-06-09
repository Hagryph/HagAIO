local addonName, ns = ...
local Class = ns.Class

-- Core/DB/DatabaseManager.lua
-- The registry service that turns a Schema into a live Database. A service or module registers its
-- database by name + schema; the manager resolves a persistence slot from the SavedVariables
-- library, constructs the Database, runs that database's OWN version migrations, and publishes it
-- at ns.DB.<Name> so call sites reach it as e.g. ns.DB.Flight:Select(...):Run().
--
-- Cross-database links are first-class: a column may reference another database's table
-- (references = { db = "Other", table = "...", column = "..." }). The manager injects two
-- resolvers into each Database so those links work regardless of registration order (resolved
-- lazily):
--   * crossResolver(dbName)  -> the target Database, for FK parent-exists checks,
--   * crossChildren(table)   -> the inbound cross-DB child refs, for cascading deletes.
-- It keeps a reverse foreign-key registry ("who references me") to drive that cross-DB cascade.

ns.DB = ns.DB or {}
local DB = ns.DB

local DatabaseManager = Class.new("DatabaseManager", ns.Service)

function DatabaseManager:OnInitialize()
    local p = self:_p()
    p.dbs = {}            -- name -> Database
    p.reverseFK = {}      -- "parentDb\1parentTable" -> list of { childDb, childTable, childCol, refCol, onDelete }
end

local function rk(dbName, table) return dbName .. "\1" .. table end

-- Register a database. opts = { perChar = bool }. Returns the live Database (also at ns.DB.<name>).
function DatabaseManager:Register(name, schema, opts)
    opts = opts or {}
    local p = self:_p()
    assert(ns.SavedVars and ns.SavedVars:IsLoaded(), "DatabaseManager:Register before SavedVars are loaded")
    assert(not p.dbs[name], ("database '%s' already registered"):format(tostring(name)))
    assert(ns.DB[name] == nil, ("database name '%s' collides with a DB engine symbol"):format(tostring(name)))

    local slot = ns.SavedVars:DataSlot("db_" .. name, opts.perChar)
    local mgr = self
    local crossResolver  = function(dbName) return p.dbs[dbName] end
    local crossChildren  = function(tname) return mgr:_CrossChildren(name, tname) end

    local db = DB.Database:New(name, schema, slot, { crossResolver = crossResolver, crossChildren = crossChildren })
    p.dbs[name] = db
    self:_IndexCrossFKs(name, schema)
    self:_Migrate(db, schema)

    ns.DB[name] = db
    return db
end

function DatabaseManager:Get(name)   return self:_p().dbs[name] end
function DatabaseManager:Has(name)   return self:_p().dbs[name] ~= nil end
function DatabaseManager:Names()
    local out = {}; for n in pairs(self:_p().dbs) do out[#out + 1] = n end; table.sort(out); return out
end

-- record this schema's cross-DB foreign keys in the reverse registry (parent -> children)
function DatabaseManager:_IndexCrossFKs(name, schema)
    local p = self:_p()
    for _, tname in ipairs(schema:TableNames()) do
        for _, fk in ipairs(schema:Table(tname):ForeignKeys()) do
            if fk.db ~= nil then
                local key = rk(fk.db, fk.table)
                p.reverseFK[key] = p.reverseFK[key] or {}
                table.insert(p.reverseFK[key], {
                    childDb = name, childTable = tname, childCol = fk.column,
                    refCol = fk.refColumn, onDelete = fk.onDelete,
                })
            end
        end
    end
end

-- inbound cross-DB child refs of parentDb.parentTable, resolved to live target databases (lazy, so
-- the child DB may have registered before or after the parent)
function DatabaseManager:_CrossChildren(parentDb, parentTable)
    local p = self:_p()
    local out = {}
    for _, e in ipairs(p.reverseFK[rk(parentDb, parentTable)] or {}) do
        local childDb = p.dbs[e.childDb]
        if childDb then
            local refCol = e.refCol or p.dbs[parentDb]:Schema():Table(parentTable):PrimaryKey()[1]
            out[#out + 1] = { targetDb = childDb, childTable = e.childTable, childCol = e.childCol,
                              refCol = refCol, onDelete = e.onDelete }
        end
    end
    return out
end

-- run a database's own schema-version migrations (stored _schema -> schema:Version())
function DatabaseManager:_Migrate(db, schema)
    local from = db:Store():Version() or schema:Version()
    local target = schema:Version()
    if from >= target then
        db:Store():SetVersion(target)
        return
    end
    for v = from + 1, target do
        local fn = schema:Migrations()[v]
        if fn then
            local ok, err = pcall(fn, db)
            if not ok then
                ns.Logger:Core():Error(("db '%s' migration to v%d failed: %s"):format(db:Name(), v, tostring(err)))
                error(err, 0)
            end
            ns.Logger:Core():Info(("db '%s' migrated to v%d"):format(db:Name(), v))
        end
        db:Store():SetVersion(v)
    end
    db:RebuildIndexes()      -- a migration may have bulk-edited rows
end

ns.ServiceManager:Register(DatabaseManager:New("DatabaseManager", { deps = { "SavedVars" } }))
