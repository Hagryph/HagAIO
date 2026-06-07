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
end)
