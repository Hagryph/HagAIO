local S = dofile("Test/support.lua")

-- Locks the CVars persistence model (Modules/CVars.lua): cvar_tracked holds every tracked CVar with a
-- category_id FK into cvar_category, so "what belongs where" lives in the database. A CVar the code
-- stops managing is REASSIGNED to the Custom category (not dropped), so a configured value survives.
local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor" }
local function newDbNs()
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    return ns
end

local function spec()
    return { tables = {
        cvar_category = {
            columns = {
                { name = "id",   type = "integer", primaryKey = true, autoIncrement = true },
                { name = "name", type = "text", nullable = false },
            },
            unique = { { "name" } } },
        cvar_tracked = { columns = {
            { name = "name",        type = "text", primaryKey = true },
            { name = "type",        type = "text" },
            { name = "category_id", type = "integer", references = { table = "cvar_category", column = "id" } },
        } },
    } }
end
local function newDb(ns) return ns.DB.Database:New("CVar", ns.DB.Schema.new("CVar", spec()), {}) end

describe("CVars DB schema", function()
    it("auto-assigns category ids and keeps category names unique", function()
        local db = newDb(newDbNs())
        local cam = db:Insert("cvar_category", { name = "Camera" })
        assert.are.equal(1, cam.id)
        assert.are.equal(2, db:Insert("cvar_category", { name = "Custom" }).id)
        assert.is_false(pcall(function() db:Insert("cvar_category", { name = "Camera" }) end))  -- unique name
    end)

    it("rejects a tracked CVar whose category does not exist", function()
        local db = newDb(newDbNs())
        assert.is_false(pcall(function()
            db:Insert("cvar_tracked", { name = "cameraYawMoveSpeed", type = "number", category_id = 99 })
        end))
    end)

    it("reassigns a code-dropped CVar to Custom instead of losing it", function()
        local ns = newDbNs()
        local db = newDb(ns)
        local cam = db:Insert("cvar_category", { name = "Camera" }).id
        local custom = db:Insert("cvar_category", { name = "Custom" }).id
        db:Insert("cvar_tracked", { name = "cameraYawMoveSpeed", type = "number", category_id = cam })
        -- the code no longer manages it -> move it under Custom (a plain category_id update)
        db:Update("cvar_tracked", { category_id = custom }, function(x) return x.name == "cameraYawMoveSpeed" end)
        local r = db:Select("category_id"):From("cvar_tracked"):Where("name", "=", "cameraYawMoveSpeed"):Run()[1]
        assert.are.equal(custom, r.category_id)              -- regrouped, still present
        assert.are.equal(1, #db:Select("name"):From("cvar_tracked"):Run())
    end)

    it("a category groups its tracked CVars (the UI category source)", function()
        local db = newDb(newDbNs())
        local np = db:Insert("cvar_category", { name = "Nameplates" }).id
        db:InsertAll("cvar_tracked", {
            { name = "nameplateShowFriends", type = "boolean", category_id = np },
            { name = "nameplateShowEnemies", type = "boolean", category_id = np },
        })
        local rows = db:Select("name"):From("cvar_tracked"):Where("category_id", "=", np):Run()
        assert.are.equal(2, #rows)
    end)
end)
