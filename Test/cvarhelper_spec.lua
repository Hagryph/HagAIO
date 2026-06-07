local S = dofile("Test/support.lua")

local function helper()
    local ns = S.newNs()
    S.load(ns, "Services/CVarHelper.lua")
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
end)
