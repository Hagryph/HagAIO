local addonName, ns = ...
local Class = ns.Class

-- Core/DB/Schema.lua
-- The schema DSL: immutable Column / Table / Schema objects built from a declarative spec
-- (the same authoring style as a module's settings/events opts). A Schema fully describes one
-- database -- its tables, columns + types, primary/foreign keys, unique & nullable constraints,
-- auto-increment ids, indices, views and triggers -- plus its OWN version + migrations. It is
-- validated at construction (a bad spec raises immediately, loudly) and never mutated after.
--
--   local s = ns.DB.Schema.new("Flight", {
--     version = 1,
--     migrations = { [1] = function(db) ... end },
--     tables = {
--       routes = {
--         columns = {
--           { name = "id",      type = "integer", primaryKey = true, autoIncrement = true },
--           { name = "faction", type = "text",    nullable = false },
--           { name = "src",     type = "integer", nullable = false },
--           { name = "dst",     type = "integer", nullable = false },
--           { name = "t",       type = "number",  nullable = false },
--           { name = "quality", type = "integer" },                       -- nullable by default
--         },
--         unique  = { { "faction", "src", "dst" } },
--         indices = { { columns = { "faction" } } },
--       },
--       route_hops = {
--         columns = {
--           { name = "route_id", type = "integer",
--             references = { table = "routes", column = "id", onDelete = "cascade" } },
--           { name = "ordinal",  type = "integer" },
--           { name = "node",     type = "integer" },
--         },
--         primaryKey = { "route_id", "ordinal" },                          -- composite PK
--       },
--     },
--     triggers = { { table = "routes", time = "after", event = "delete", action = function(ctx) ... end } },
--     views    = { fast = { build = function(db) return db:Select("*"):From("routes"):Where("t","<",60) end } },
--   })

ns.DB = ns.DB or {}
local DB = ns.DB

local function fail(msg) error("DB schema: " .. msg, 3) end

-- ===========================================================================
-- Column
-- ===========================================================================
local Column = Class.new("DBColumn")

-- spec = { name, type, nullable, unique, default, autoIncrement, primaryKey, references }
-- `compositePKMember` (resolved by the Table BEFORE construction) is true when this column belongs
-- to a table-level composite primary key, so the column is built already NOT NULL and never mutated.
function Column:Initialize(spec, tableName, compositePKMember)
    assert(type(spec) == "table", "column spec must be a table")
    local p = self:_p()
    local where = ("table '%s'"):format(tostring(tableName))

    p.name = spec.name
    if type(p.name) ~= "string" or p.name == "" then fail(where .. ": every column needs a string name") end

    p.type = DB.normalizeType(spec.type)
    if not p.type then fail(("%s.%s: unknown column type %s"):format(where, p.name, tostring(spec.type))) end

    p.primaryKey = spec.primaryKey and true or false
    -- A single-column primary key is implicitly NOT NULL and UNIQUE; a COMPOSITE-PK member is
    -- implicitly NOT NULL (but not individually unique -- only the combination is).
    if p.primaryKey then
        p.nullable = false
        p.unique = true
    else
        p.nullable = (spec.nullable ~= false) and not compositePKMember   -- NOT NULL if explicit, or a composite-PK member
        p.unique = spec.unique and true or false
    end

    p.auto = spec.autoIncrement and true or false
    if p.auto then
        if p.type ~= "integer" then fail(("%s.%s: autoIncrement requires an integer column"):format(where, p.name)) end
        if not p.primaryKey then fail(("%s.%s: autoIncrement requires the column to be primaryKey"):format(where, p.name)) end
    end

    p.hasDefault = (spec.default ~= nil)
    p.default = spec.default

    -- Foreign-key reference (resolved against the target table at Schema build).
    if spec.references then
        local r = spec.references
        assert(type(r) == "table", ("%s.%s: references must be a table"):format(where, p.name))
        local onDelete = r.onDelete or DB.OnDelete.NO_ACTION
        if not ns.Enum.has(DB.OnDelete, onDelete) then
            fail(("%s.%s: unknown onDelete '%s'"):format(where, p.name, tostring(onDelete)))
        end
        if onDelete == DB.OnDelete.SET_NULL and not p.nullable then
            fail(("%s.%s: onDelete set_null needs a nullable column"):format(where, p.name))
        end
        p.ref = {
            table    = r.table,
            column   = r.column,                      -- nil = the referenced table's primary key
            onDelete = onDelete,
        }
        assert(type(p.ref.table) == "string", ("%s.%s: references.table must be a string"):format(where, p.name))
    end
end

function Column:Name()         return self:_p().name end
function Column:Type()         return self:_p().type end
function Column:IsNullable()   return self:_p().nullable end
function Column:IsUnique()     return self:_p().unique end
function Column:IsPrimaryKey() return self:_p().primaryKey end
function Column:IsAuto()       return self:_p().auto end
function Column:HasDefault()   return self:_p().hasDefault end
function Column:Default()      return self:_p().default end
function Column:Ref()          return self:_p().ref end        -- { db, table, column, onDelete } or nil

-- ===========================================================================
-- Table
-- ===========================================================================
local Table = Class.new("DBTable")

local function asNameList(v) return (type(v) == "table") and v or { v } end

function Table:Initialize(name, spec)
    assert(type(spec) == "table", ("table '%s' spec must be a table"):format(tostring(name)))
    local p = self:_p()
    p.name = name
    p.scope = spec.scope or DB.Scope.GLOBAL          -- where rows live (default: account-wide)
    if not ns.Enum.has(DB.Scope, p.scope) then fail(("table '%s': unknown scope '%s'"):format(name, tostring(p.scope))) end
    p.seed = spec.seed                                -- optional seed(db) run once when the table is empty
    if p.seed ~= nil then assert(type(p.seed) == "function", ("table '%s': seed must be a function"):format(name)) end
    p.order = {}          -- ordered column names
    p.cols = {}           -- name -> Column
    p.fks = {}            -- list of { column, db, table, column=refCol, onDelete }
    p.uniques = {}        -- list of { colName, ... }
    p.indices = {}        -- list of { name, columns = {...}, unique }
    p.pk = {}             -- list of pk column names

    assert(type(spec.columns) == "table" and #spec.columns > 0,
        ("table '%s' needs a non-empty columns list"):format(tostring(name)))

    -- Resolve composite-PK membership BEFORE constructing any column, so a member is built already
    -- NOT NULL -- a column is validated once, at construction, and never mutated afterwards.
    local compositePK = {}
    if spec.primaryKey then
        for _, cn in ipairs(asNameList(spec.primaryKey)) do compositePK[cn] = true end
    end

    for _, cspec in ipairs(spec.columns) do
        local col = Column:New(cspec, name, compositePK[cspec.name] == true)
        local cn = col:Name()
        if p.cols[cn] then fail(("table '%s': duplicate column '%s'"):format(name, cn)) end
        p.cols[cn] = col
        p.order[#p.order + 1] = cn
        if col:IsPrimaryKey() then p.pk[#p.pk + 1] = cn end
        if col:IsUnique() and not col:IsPrimaryKey() then p.uniques[#p.uniques + 1] = { cn } end
        if col:Ref() then
            local r = col:Ref()
            p.fks[#p.fks + 1] = { column = cn, table = r.table, refColumn = r.column, onDelete = r.onDelete }
        end
    end

    -- Composite primary key (table-level). Mutually exclusive with single-column primaryKey shorthand.
    -- NOT NULL was already applied at construction (compositePK above); here we just record the PK list.
    if spec.primaryKey then
        if #p.pk > 0 then fail(("table '%s': declare the primary key once (column flag OR table list)"):format(name)) end
        for _, cn in ipairs(asNameList(spec.primaryKey)) do
            if not p.cols[cn] then fail(("table '%s': primary key column '%s' does not exist"):format(name, cn)) end
            p.pk[#p.pk + 1] = cn
        end
    end

    -- Table-level UNIQUE(col, ...) constraints.
    for _, u in ipairs(spec.unique or {}) do
        local cols = asNameList(u)
        for _, cn in ipairs(cols) do
            if not p.cols[cn] then fail(("table '%s': unique column '%s' does not exist"):format(name, cn)) end
        end
        p.uniques[#p.uniques + 1] = cols
    end

    -- Secondary indices (declared; rebuilt in memory on load).
    for i, idx in ipairs(spec.indices or {}) do
        local cols = asNameList(idx.columns or idx)
        for _, cn in ipairs(cols) do
            if not p.cols[cn] then fail(("table '%s': index column '%s' does not exist"):format(name, cn)) end
        end
        p.indices[#p.indices + 1] = { name = idx.name or (name .. "_idx" .. i), columns = cols, unique = idx.unique and true or false }
    end
end

function Table:Name()         return self:_p().name end
function Table:Scope()        return self:_p().scope end
function Table:Seed()         return self:_p().seed end
function Table:ColumnNames()  return self:_p().order end
function Table:Column(n)      return self:_p().cols[n] end
function Table:HasColumn(n)   return self:_p().cols[n] ~= nil end
function Table:PrimaryKey()   return self:_p().pk end             -- list (may be empty)
function Table:Uniques()      return self:_p().uniques end        -- list of column-name lists
function Table:Indices()      return self:_p().indices end
function Table:ForeignKeys()  return self:_p().fks end
function Table:Columns()
    local p, out = self:_p(), {}
    for i, cn in ipairs(p.order) do out[i] = p.cols[cn] end
    return out
end

-- ===========================================================================
-- Schema
-- ===========================================================================
local Schema = Class.new("DBSchema")

function Schema:Initialize(name, spec)
    assert(type(name) == "string", "Schema.new: name must be a string")
    spec = spec or {}
    local p = self:_p()
    p.name = name
    p.version = spec.version or 1
    assert(type(p.version) == "number" and p.version >= 1, "Schema: version must be a number >= 1")
    p.migrations = spec.migrations or {}
    p.tables = {}         -- name -> Table
    p.tableOrder = {}
    p.views = {}          -- name -> view spec
    p.triggers = {}       -- list of normalized triggers

    assert(type(spec.tables) == "table", ("Schema '%s' needs a tables map"):format(name))
    for tname, tspec in pairs(spec.tables) do
        p.tables[tname] = Table:New(tname, tspec)
        p.tableOrder[#p.tableOrder + 1] = tname
    end
    table.sort(p.tableOrder)

    self:_ValidateForeignKeys()
    self:_BuildTriggers(spec.triggers or {})
    self:_BuildViews(spec.views or {})
end

-- Every foreign key must point at an existing table + a PK/unique column (a nil reference column
-- resolves to the target's primary key).
function Schema:_ValidateForeignKeys()
    local p = self:_p()
    for tname, tbl in pairs(p.tables) do
        for _, fk in ipairs(tbl:ForeignKeys()) do
            local target = p.tables[fk.table]
            if not target then
                fail(("table '%s' FK '%s' references unknown table '%s'"):format(tname, fk.column, fk.table))
            end
            local refCol = fk.refColumn
            if refCol == nil then
                local pk = target:PrimaryKey()
                if #pk ~= 1 then
                    fail(("table '%s' FK '%s' must name a column of '%s' (its PK is composite/absent)")
                        :format(tname, fk.column, fk.table))
                end
                refCol = pk[1]
                fk.refColumn = refCol
            end
            if not target:HasColumn(refCol) then
                fail(("table '%s' FK '%s' references unknown column '%s.%s'"):format(tname, fk.column, fk.table, refCol))
            end
            if not self:_IsReferenceable(target, refCol) then
                fail(("table '%s' FK '%s' must reference a PK or UNIQUE column ('%s.%s' is neither)")
                    :format(tname, fk.column, fk.table, refCol))
            end
        end
    end
end

-- A column can be a FK target if it's the (single) PK or covered by a single-column UNIQUE.
function Schema:_IsReferenceable(target, colName)
    local pk = target:PrimaryKey()
    if #pk == 1 and pk[1] == colName then return true end
    for _, u in ipairs(target:Uniques()) do
        if #u == 1 and u[1] == colName then return true end
    end
    return false
end

function Schema:_BuildTriggers(list)
    local p = self:_p()
    for _, t in ipairs(list) do
        assert(type(t) == "table", "trigger spec must be a table")
        local time  = t.time  or DB.TriggerTime.AFTER
        local event = t.event
        local level = t.level or DB.TriggerLevel.ROW
        if not ns.Enum.has(DB.TriggerTime, time)   then fail(("trigger: unknown time '%s'"):format(tostring(time))) end
        if not ns.Enum.has(DB.TriggerEvent, event) then fail(("trigger: unknown event '%s'"):format(tostring(event))) end
        if not ns.Enum.has(DB.TriggerLevel, level) then fail(("trigger: unknown level '%s'"):format(tostring(level))) end
        if not p.tables[t.table] then fail(("trigger references unknown table '%s'"):format(tostring(t.table))) end
        assert(type(t.action) == "function", "trigger: action must be a function")
        p.triggers[#p.triggers + 1] = {
            table = t.table, time = time, event = event, level = level,
            when = t.when, action = t.action, name = t.name,
        }
    end
end

function Schema:_BuildViews(views)
    local p = self:_p()
    for vname, v in pairs(views) do
        assert(type(v) == "table", ("view '%s' spec must be a table"):format(tostring(vname)))
        assert(type(v.build) == "function", ("view '%s' needs a build(db) function"):format(tostring(vname)))
        if p.tables[vname] then fail(("view '%s' collides with a table of the same name"):format(vname)) end
        p.views[vname] = { name = vname, build = v.build, insteadOf = v.insteadOf }
    end
end

function Schema:Name()        return self:_p().name end
function Schema:Version()      return self:_p().version end
function Schema:Migrations()   return self:_p().migrations end
function Schema:Table(n)       return self:_p().tables[n] end
function Schema:HasTable(n)    return self:_p().tables[n] ~= nil end
function Schema:TableNames()   return self:_p().tableOrder end
function Schema:Triggers()     return self:_p().triggers end
function Schema:Views()        return self:_p().views end

-- ---- public factory -------------------------------------------------------
DB.Column = Column
DB.Table = Table
DB.Schema = Schema
function DB.Schema.new(name, spec) return Schema:New(name, spec) end
