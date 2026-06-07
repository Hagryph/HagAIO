local S = dofile("Test/support.lua")

local function setup()
    local ns = S.newNs()
    S.load(ns, "Services/Range.lua")
    local r = ns._captured["Range"]; r:OnInitialize()
    return r
end

describe("Range", function()
    it("_ItemFor requests uncached items, resolves once cached, then memoises", function()
        local r = setup()
        local loaded, requested = {}, {}
        _G.C_Item = {
            GetItemInfo = function(id) return loaded[id] and "Item" or nil end,
            RequestLoadItemDataByID = function(id) requested[id] = true end,
        }
        assert.is_nil(r:_ItemFor(8))       -- none cached -> nil, but requests
        assert.is_true(requested[33278])    -- first candidate for 8yd
        loaded[33278] = true
        assert.are.equal(33278, r:_ItemFor(8))
        loaded[33278] = nil                 -- memoised: stays resolved
        assert.are.equal(33278, r:_ItemFor(8))
    end)

    it("_ItemFor returns nil for an unknown yardage", function()
        local r = setup()
        _G.C_Item = { GetItemInfo = function() return nil end }
        assert.is_nil(r:_ItemFor(999))
    end)

    it("UnitInRange is tri-state (true / false / nil)", function()
        local r = setup()
        local inrange = true
        _G.C_Item = {
            GetItemInfo = function() return "Item" end,
            IsItemInRange = function() return inrange end,
        }
        assert.is_true(r:UnitInRange("target", 8))
        inrange = false
        assert.is_false(r:UnitInRange("target", 8))

        local r2 = setup()
        _G.C_Item = { GetItemInfo = function() return nil end }  -- no resolvable item
        assert.is_nil(r2:UnitInRange("target", 8))
    end)

    it("CountEnemies counts attackable, alive enemies in range", function()
        local r = setup()
        _G.C_Item = {
            GetItemInfo = function() return "Item" end,
            IsItemInRange = function(_, u) return u ~= "p3" end,  -- p3 out of range
        }
        _G.C_NamePlate = { GetNamePlates = function() return {
            { namePlateUnitToken = "p1" }, { namePlateUnitToken = "p2" },
            { namePlateUnitToken = "p3" }, { namePlateUnitToken = "dead" },
            { namePlateUnitToken = "friend" },
        } end }
        _G.UnitCanAttack = function(_, u) return u ~= "friend" end
        _G.UnitIsDead = function(u) return u == "dead" end
        assert.are.equal(2, r:CountEnemies(8))   -- p1,p2 (p3 out, dead/friend filtered)
    end)

    it("CountEnemies uses the spell fallback when the item is undetermined", function()
        local r = setup()
        _G.C_Item = {
            GetItemInfo = function() return "Item" end,
            IsItemInRange = function() return nil end,    -- item can't tell
        }
        _G.C_Spell = { IsSpellInRange = function(_, u) return u == "p1" end }
        _G.C_NamePlate = { GetNamePlates = function() return {
            { namePlateUnitToken = "p1" }, { namePlateUnitToken = "p2" },
        } end }
        _G.UnitCanAttack = function() return true end
        _G.UnitIsDead = function() return false end
        assert.are.equal(1, r:CountEnemies(8, 12345))   -- only p1 via spell fallback
    end)
end)
