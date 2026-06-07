local S = dofile("Test/support.lua")

-- An identity-ish C_EncodingUtil stub: CBOR round-trips any value through a registry;
-- compress/base64 are identity (we test the framing + error handling here, not
-- Blizzard's actual codecs).
local function newSerializer()
    local store, n = {}, 0
    _G.C_EncodingUtil = {
        SerializeCBOR = function(v) n = n + 1; local id = "c" .. n; store[id] = v; return id end,
        DeserializeCBOR = function(s) if store[s] == nil then error("bad cbor") end; return store[s] end,
        CompressString = function(s) return s end,
        DecompressString = function(s) return s end,
        EncodeBase64 = function(s) return s end,
        DecodeBase64 = function(s) return s end,
    }
    local ns = S.newNs()
    S.load(ns, "Services/Serializer.lua")
    local sz = ns._captured["Serializer"]
    sz:OnInitialize()
    return sz
end

describe("Serializer", function()
    it("round-trips a value through Encode / Decode", function()
        local sz = newSerializer()
        local original = { a = 1, b = "x", nested = { 1, 2, 3 } }
        local str = sz:Encode(original)
        assert.is_true(type(str) == "string")
        assert.are.equal(original, sz:Decode(str))
    end)

    it("rejects a string without the version prefix", function()
        local sz = newSerializer()
        local v, err = sz:Decode("not-a-hagaio-string")
        assert.is_nil(v)
        assert.is_true(type(err) == "string")
    end)

    it("tolerates whitespace from a line-wrapped paste", function()
        local sz = newSerializer()
        local str = sz:Encode({ ok = true })
        local wrapped = str:sub(1, 4) .. "\n   " .. str:sub(5)
        assert.is_true(sz:Decode(wrapped) ~= nil)
    end)

    it("fails cleanly on a corrupt body instead of erroring", function()
        local sz = newSerializer()
        local v, err = sz:Decode("HAGAIO1!nonexistent")
        assert.is_nil(v)
        assert.is_true(type(err) == "string")
    end)

    it("Decode of a non-string returns nil", function()
        local sz = newSerializer()
        assert.is_nil((sz:Decode(nil)))
    end)

    it("reports unavailable when C_EncodingUtil is missing", function()
        local sz = newSerializer()
        _G.C_EncodingUtil = nil
        assert.is_false(sz:IsAvailable())
        assert.is_nil((sz:Encode({})))
    end)

    it("round-trips an empty table", function()
        local sz = newSerializer()
        local t = {}
        assert.are.equal(t, sz:Decode(sz:Encode(t)))
    end)

    it("fails cleanly on an empty / too-short body", function()
        local sz = newSerializer()
        local v, err = sz:Decode("HAGAIO1!")   -- prefix only, no body
        assert.is_nil(v)
        assert.is_true(type(err) == "string")
    end)
end)
