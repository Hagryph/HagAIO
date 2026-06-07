local S = dofile("Test/support.lua")

local function helper()
    local ns = S.newNs()
    S.load(ns, "Lib/CVarHelper.lua")
    return ns._captured["CVarHelper"]
end

describe("CVarHelper:InferType", function()
    it("treats '0'/'1' as boolean", function()
        local h = helper()
        assert.are.equal("boolean", h:InferType("0"))
        assert.are.equal("boolean", h:InferType("1"))
    end)

    it("treats other numerics as number", function()
        local h = helper()
        assert.are.equal("number", h:InferType("12"))
        assert.are.equal("number", h:InferType("1.5"))
        assert.are.equal("number", h:InferType("-3"))
    end)

    it("treats non-numeric / nil as string", function()
        local h = helper()
        assert.are.equal("string", h:InferType("auto"))
        assert.are.equal("string", h:InferType(nil))
    end)

    it("boundaries: '' is string, '01' is number (not boolean)", function()
        local h = helper()
        assert.are.equal("string", h:InferType(""))    -- tonumber("") == nil
        assert.are.equal("number", h:InferType("01"))   -- not exactly "0"/"1"; tonumber -> 1
    end)
end)

describe("CVarHelper:DetectType", function()
    it("a curated known entry wins, returning its type AND options", function()
        local h = helper()
        local known = { type = "select", options = { "a", "b" } }
        local t, opts = h:DetectType(known, "whatever")
        assert.are.equal("select", t)
        assert.are.equal("b", opts[2])
    end)

    it("falls back to value inference when there's no known entry", function()
        local h = helper()
        local t, opts = h:DetectType(nil, "1")
        assert.are.equal("boolean", t)
        assert.is_nil(opts)                              -- inferred types have no options
    end)
end)
