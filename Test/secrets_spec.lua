local S = dofile("Test/support.lua")

-- A secret value is modelled as a table tagged { __secret = true }.
local function setup(restricted)
    _G.issecretvalue = function(v) return type(v) == "table" and v.__secret == true end
    _G.C_Secrets = { HasSecretRestrictions = function() return restricted and true or false end }
    local ns = S.newNs()
    S.load(ns, "Services/Secrets.lua")
    local s = ns._captured["Secrets"]; s:OnInitialize()
    return s
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

    it("Restricted reflects C_Secrets.HasSecretRestrictions", function()
        assert.is_true(setup(true):Restricted())
        assert.is_false(setup(false):Restricted())
    end)

    it("Text paints a secret value without erroring; nil clears", function()
        local s = setup()
        local fs = { text = "?", SetText = function(self, t) self.text = t end }
        assert.is_true(s:Text(fs, { __secret = true }))   -- no prefix: SetText(secret), no concat
        assert.is_false(s:Text(fs, nil))                  -- nil -> cleared, returns false
        assert.are.equal("", fs.text)
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
        assert.is_false(s:Is({ __secret = true }))   -- no API -> nothing reads as secret
        assert.is_false(s:Restricted())
        assert.are.equal(42, s:Number("42"))         -- non-secret path still converts
    end)
end)
