local S = dofile("Test/support.lua")

local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor", "CoreTables", "DatabaseManager" }

-- A minimal movable-frame stub: fixed centre/size, tracks shown state + SetPoint calls.
local function makeFrame(spec)
    spec = spec or {}
    local f = { _cx = spec.cx or 0, _cy = spec.cy or 0, _w = spec.w or 100, _h = spec.h or 40,
                _shown = spec.shown ~= false, points = {} }
    function f:GetCenter() return self._cx, self._cy end
    function f:GetWidth() return self._w end
    function f:GetHeight() return self._h end
    function f:IsShown() return self._shown end
    function f:ClearAllPoints() self.points = {} end
    function f:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function f:SetMovable() end
    function f:SetClampedToScreen() end
    function f:RegisterForDrag() end
    function f:SetScript() end
    function f:EnableMouse() end
    function f:Show() self._shown = true end
    function f:Hide() self._shown = false end
    return f
end

-- opts: ux/uy (UIParent centre), uLeft/uTop (for TOPLEFT save), grid (EditModeManagerFrame.Grid).
-- EditMode now reads/writes positions through the database (the `editmode` table); build one so the
-- spec can inspect what was stored.
local function newEM(opts)
    opts = opts or {}
    _G.UIParent = {
        GetCenter = function() return opts.ux or 0, opts.uy or 0 end,
        GetLeft   = function() return opts.uLeft or 0 end,
        GetTop    = function() return opts.uTop or 0 end,
    }
    _G.EditModeManagerFrame = opts.grid and { Grid = opts.grid } or nil
    _G.EventRegistry = nil   -- skip the edit-mode hook wiring
    _G.HagAIODB = nil
    _G.HagAIOCharDB = nil
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    S.load(ns, "Lib/SettingsTables.lua")
    local slots = {}
    ns.SavedVars = { IsLoaded = function() return true end,
                     DataSlot = function(_, name) slots[name] = slots[name] or {}; return slots[name] end }
    local mgr = ns._captured["DatabaseManager"]; mgr:OnInitialize(); mgr:Build()
    S.load(ns, "Services/EditMode.lua")
    local em = ns._captured["EditMode"]; em:OnInitialize()
    return em, mgr:Shared()
end

local function pos(db, key)
    return db:Select("point", "x", "y"):From("editmode"):Where("key", "=", key):Run()[1]
end

describe("EditMode:_GridSnap", function()
    it("returns the point unchanged when no grid is shown", function()
        local x, y = (newEM()):_GridSnap(123, 456)
        assert.are.equal(123, x); assert.are.equal(456, y)
    end)

    it("snaps to the nearest grid line (round, from the grid centre)", function()
        local grid = { IsShown = function() return true end, gridSpacing = 50,
                       GetCenter = function() return 0, 0 end }
        local x, y = (newEM({ grid = grid })):_GridSnap(63, 88)
        assert.are.equal(50, x)    -- round(63/50)=1 -> 50
        assert.are.equal(100, y)   -- round(88/50)=2 -> 100
    end)
end)

describe("EditMode:_ElementSnap", function()
    it("snaps to the UIParent centre within the SNAP threshold", function()
        local x, y = (newEM({ ux = 0, uy = 0 })):_ElementSnap({}, 7, 50, 20, 10)
        assert.are.equal(0, x)     -- |7-0| <= 10 -> snap to centre
        assert.are.equal(50, y)    -- |50-0| > 10 -> unchanged
    end)

    it("leaves the point alone beyond the SNAP threshold", function()
        local x, y = (newEM({ ux = 0, uy = 0 })):_ElementSnap({}, 15, 50, 20, 10)
        assert.are.equal(15, x); assert.are.equal(50, y)
    end)

    it("aligns the centre-x with a nearby shown frame", function()
        local em = newEM({ ux = 9999, uy = 9999 })   -- screen centre out of range
        local neighbour = makeFrame({ cx = 100, cy = 200, w = 40, h = 40 })
        em:Register(neighbour, { key = "n", default = { point = "CENTER", x = 0, y = 0 } })
        local moving = { frame = makeFrame({ cx = 95, cy = 200 }) }
        local x, y = em:_ElementSnap(moving, 95, 200, 20, 20)
        assert.are.equal(100, x)   -- snapped to the neighbour's centre x (d=5 <= SNAP)
        assert.are.equal(200, y)   -- centre y already aligned
    end)
end)

describe("EditMode:_SnapAndSave", function()
    it("stores a CENTER offset by default", function()
        local em, db = newEM({ ux = 0, uy = 0 })
        local reg = { frame = makeFrame({ cx = 30, cy = 40, w = 100, h = 20 }),
                      key = "k", default = { point = "CENTER", x = 0, y = 0 } }
        em:_SnapAndSave(reg)
        local p = pos(db, "k")
        assert.are.equal("CENTER", p.point)
        assert.are.equal(30, p.x)   -- cx - ux
        assert.are.equal(40, p.y)   -- cy - uy
    end)

    it("stores a TOPLEFT offset when reg.anchor is TOPLEFT", function()
        local em, db = newEM({ ux = 0, uy = 0, uLeft = 0, uTop = 500 })
        -- frame centre (30,40), size 100x20 -> half-width 50, half-height 10
        local reg = { frame = makeFrame({ cx = 30, cy = 40, w = 100, h = 20 }),
                      key = "t", anchor = "TOPLEFT", default = {} }
        em:_SnapAndSave(reg)
        local p = pos(db, "t")
        assert.are.equal("TOPLEFT", p.point)
        assert.are.equal(-20, p.x)    -- (cx-hw) - UIParent:GetLeft() = (30-50)-0
        assert.are.equal(-450, p.y)   -- (cy+hh) - UIParent:GetTop()  = (40+10)-500
    end)

    it("calls reg.onMoved after saving", function()
        local em = newEM({ ux = 0, uy = 0 })
        local moved = false
        local reg = { frame = makeFrame({ cx = 0, cy = 0 }), key = "m",
                      default = {}, onMoved = function() moved = true end }
        em:_SnapAndSave(reg)
        assert.is_true(moved)
    end)
end)

describe("EditMode:Unregister", function()
    it("drops the frame so it no longer shows when Edit Mode is entered", function()
        local em = newEM()
        local f = makeFrame({ shown = false })
        em:Register(f, { key = "k", default = { point = "CENTER", x = 0, y = 0 } })
        em:Unregister(f)
        em:_OnEnter()                  -- enter edit mode: only registered frames show
        assert.is_false(f:IsShown())
    end)

    it("is a no-op for a frame that was never registered", function()
        local em = newEM()
        em:Unregister(makeFrame())     -- must not error
    end)
end)
