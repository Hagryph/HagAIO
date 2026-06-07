local addonName, ns = ...
local Class = ns.Class

-- Services/Serializer.lua
-- Turns a Lua value into a compact, copy-pasteable share string and back, using
-- the built-in 12.0 C_EncodingUtil (added 11.1.5) -- NO external libraries
-- (LibSerialize/LibDeflate). Pipeline: SerializeCBOR -> CompressString(Deflate) ->
-- EncodeBase64, prefixed with a version tag so we can evolve the format. Every
-- Blizzard call is pcall-guarded; a bad string fails cleanly to (nil, reason)
-- rather than erroring, so import of a corrupt/foreign string is safe.
--
--   local str = ns.Serializer:Encode(profileTable)
--   local tbl, err = ns.Serializer:Decode(str)

local Serializer = Class.new("Serializer", ns.Service)

-- Format version lives in the prefix; bump if the pipeline changes. Decode only
-- accepts a string it recognises.
local PREFIX = "HAGAIO1!"

-- Enum values (with documented numeric fallbacks if Enum isn't populated yet).
local C_METHOD = (Enum and Enum.CompressionMethod and Enum.CompressionMethod.Deflate) or 0
local C_LEVEL  = (Enum and Enum.CompressionLevel and Enum.CompressionLevel.OptimizeForSize) or 2
local B64      = (Enum and Enum.Base64Variant and Enum.Base64Variant.Standard) or 0

function Serializer:OnInitialize() end

-- True if this client has the native encoding API.
function Serializer:IsAvailable()
    return C_EncodingUtil ~= nil and type(C_EncodingUtil.SerializeCBOR) == "function"
end

-- value -> share string, or (nil, reason).
function Serializer:Encode(value)
    if not self:IsAvailable() then return nil, "this client has no serialization API" end
    local ok, cbor = pcall(C_EncodingUtil.SerializeCBOR, value, { ignoreSerializationErrors = true })
    if not ok or type(cbor) ~= "string" then return nil, "could not serialize" end
    local ok2, comp = pcall(C_EncodingUtil.CompressString, cbor, C_METHOD, C_LEVEL)
    if not ok2 or type(comp) ~= "string" then return nil, "could not compress" end
    local ok3, b64 = pcall(C_EncodingUtil.EncodeBase64, comp, B64)
    if not ok3 or type(b64) ~= "string" then return nil, "could not encode" end
    return PREFIX .. b64
end

-- share string -> value, or (nil, reason). Whitespace (line wraps from pasting) is
-- stripped first; a wrong/missing prefix or any decode failure is reported, never thrown.
function Serializer:Decode(str)
    if type(str) ~= "string" then return nil, "nothing to import" end
    if not self:IsAvailable() then return nil, "this client has no serialization API" end
    str = str:gsub("%s", "")
    if str:sub(1, #PREFIX) ~= PREFIX then
        return nil, "unrecognised string (wrong format or version)"
    end
    local body = str:sub(#PREFIX + 1)
    local ok, comp = pcall(C_EncodingUtil.DecodeBase64, body, B64)
    if not ok or type(comp) ~= "string" then return nil, "invalid characters" end
    local ok2, cbor = pcall(C_EncodingUtil.DecompressString, comp, C_METHOD)
    if not ok2 or type(cbor) ~= "string" then return nil, "could not decompress" end
    local ok3, value = pcall(C_EncodingUtil.DeserializeCBOR, cbor)
    if not ok3 then return nil, "could not deserialize" end
    return value
end

ns.ServiceManager:Register(Serializer:New("Serializer"))
