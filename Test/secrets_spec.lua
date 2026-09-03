local S = dofile("Test/support.lua")

local RESTRICTION_TYPES = {
    Combat = 0,
    Encounter = 1,
    ChallengeMode = 2,
    PvPMatch = 3,
    Map = 4,
}

-- Ordinary service tests tag a table as secret. setupWithSecretVM below additionally
-- instruments equality-with-nil so the headless runtime models WoW's forbidden operation.
local function setup(activeRestriction)
    _G.issecretvalue = function(v) return type(v) == "table" and v.__secret == true end
    _G.Enum = { AddOnRestrictionType = RESTRICTION_TYPES }
    _G.C_Secrets = { HasSecretRestrictions = function() return true end }
    _G.C_RestrictedActions = {
        IsAddOnRestrictionActive = function(restrictionType)
            return activeRestriction ~= nil
                and restrictionType == RESTRICTION_TYPES[activeRestriction]
        end,
    }
    local ns = S.newNs()
    S.load(ns, "Services/Secrets.lua")
    local s = ns._captured["Secrets"]; s:OnInitialize()
    return s
end

-- LuaJIT cannot manufacture Blizzard Secret Values. Instrument the production source's
-- nil comparisons with a VM model that throws when its operand is the secret sentinel.
-- With the old `v == nil or self:Is(v)` ordering, Number/Text fail this model exactly as
-- they fail in WoW; with secrecy classified first, short-circuiting avoids the operation.
local function setupWithSecretVM()
    local f = assert(io.open("Services/Secrets.lua", "rb"))
    local source = f:read("*a"); f:close()
    local secret = { __secret = true }
    local function compareNil(v)
        if rawequal(v, secret) then error("attempt to compare a secret value", 2) end
        return v == nil
    end
    _G.__HagAIOTestCompareSecretWithNil = compareNil
    source = source:gsub("v == nil", "__HagAIOTestCompareSecretWithNil(v)")

    _G.issecretvalue = function(v) return rawequal(v, secret) end
    _G.Enum = { AddOnRestrictionType = RESTRICTION_TYPES }
    _G.C_Secrets = { HasSecretRestrictions = function() return true end }
    _G.C_RestrictedActions = { IsAddOnRestrictionActive = function() return false end }
    local ns = S.newNs()
    assert((loadstring or load)(source, "@Services/Secrets.lua"))("HagAIO", ns)
    local s = ns._captured["Secrets"]; s:OnInitialize()
    return s, secret, compareNil
end

describe("Secrets", function()
    it("Is detects secret values", function()
        local s = setup()
        assert.is_true(s:Is({ __secret = true }))
        assert.is_false(s:Is(5))
        assert.is_false(s:Is("x"))
        assert.is_false(s:Is(nil))
    end)

    it("Number: secret -> nil, numeric string -> number, number -> number", function()
        local s = setup()
        assert.is_nil(s:Number({ __secret = true }))
        assert.are.equal(123, s:Number("123"))
        assert.are.equal(5, s:Number(5))
        assert.is_nil(s:Number(nil))
        assert.is_nil(s:Number("abc"))
    end)

    it("Number classifies a secret before the VM can reject a nil comparison", function()
        local s, secret, compareNil = setupWithSecretVM()
        assert.has_error(function() compareNil(secret) end, "attempt to compare a secret value")
        assert.is_nil(s:Number(secret))
        _G.__HagAIOTestCompareSecretWithNil = nil
    end)

    it("Restricted reflects every active combat-data restriction scope", function()
        for name in pairs(RESTRICTION_TYPES) do
            assert.is_true(setup(name):Restricted(), name)
        end
    end)

    it("Restricted ignores the build-wide capability switch when no scope is active", function()
        assert.is_false(setup():Restricted())
    end)

    it("Restricted is false when the live restriction-state API is absent", function()
        local s = setup("Combat")
        _G.C_RestrictedActions = nil
        assert.is_false(s:Restricted())
    end)

    it("Text paints a secret value without erroring; nil clears", function()
        local s = setup()
        local fs = { text = "?", SetText = function(self, t) self.text = t end }
        assert.is_true(s:Text(fs, { __secret = true }))   -- no prefix: SetText(secret), no concat
        assert.is_false(s:Text(fs, nil))                  -- nil -> cleared, returns false
        assert.are.equal("", fs.text)
    end)

    it("Text classifies a secret before the VM can reject a nil comparison", function()
        local s, secret, compareNil = setupWithSecretVM()
        local fs = { SetText = function(self, value) self.text = value end }
        assert.has_error(function() compareNil(secret) end, "attempt to compare a secret value")
        assert.is_true(s:Text(fs, secret))
        assert.is_true(rawequal(secret, fs.text))
        _G.__HagAIOTestCompareSecretWithNil = nil
    end)

    it("Text writes a plain value, with an optional prefix", function()
        local s = setup()
        local fs = { text = "?", SetText = function(self, t) self.text = t end }
        assert.is_true(s:Text(fs, "5"))
        assert.are.equal("5", fs.text)
        assert.is_true(s:Text(fs, "5", "HP "))
        assert.are.equal("HP 5", fs.text)
    end)

    it("Text returns false for a nil FontString", function()
        assert.is_false((setup()):Text(nil, "5"))
    end)

    it("Text treats an empty prefix like no prefix (no concat)", function()
        local s = setup()
        local fs = { SetText = function(self, t) self.text = t end }
        assert.is_true(s:Text(fs, "5", ""))
        assert.are.equal("5", fs.text)   -- "" prefix is not prepended
    end)

    it("pre-12.0 (no issecretvalue / C_Secrets): Is and Restricted are false, Number still works", function()
        local s = setup()
        _G.issecretvalue = nil
        _G.C_Secrets = nil
        _G.C_RestrictedActions = nil
        _G.Enum = nil
        assert.is_false(s:Is({ __secret = true }))   -- no API -> nothing reads as secret
        assert.is_false(s:Restricted())
        assert.are.equal(42, s:Number("42"))         -- non-secret path still converts
    end)
end)
