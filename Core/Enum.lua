local addonName, ns = ...

-- Core/Enum.lua
-- ENUM factory -- a sibling of ns.Class for FROZEN constant tables. ns.Enum.new(name, members)
-- returns a READ-ONLY table: reading a member gives its value; reading an UNKNOWN member, or
-- writing ANY member, raises -- so a typo'd member fails loudly instead of silently being nil.
-- The frozen table exposes only its members, so iteration / reverse-lookup go through the
-- ns.Enum.* helpers below.
--   local Quality = ns.Enum.new("Quality", { DIRECT = 1, FLY = 2 })
--   Quality.DIRECT             -- 1
--   Quality.WALK               -- error: enum 'Quality' has no member 'WALK'
--   ns.Enum.nameOf(Quality, 2) -- "FLY"

local Enum = {}

-- frozen enum -> { name, values, names (ordered), byValue }. Weak so enums can be GC'd.
local meta = setmetatable({}, { __mode = "k" })

function Enum.new(name, members)
    assert(type(name) == "string", "Enum.new: name must be a string")
    assert(type(members) == "table", "Enum.new: members must be a table")
    local values, names, byValue = {}, {}, {}
    for k, v in pairs(members) do
        assert(type(k) == "string", "Enum.new: member keys must be strings")
        values[k] = v
        names[#names + 1] = k
        byValue[v] = k
    end
    table.sort(names)   -- deterministic order for names()/each()

    local frozen = setmetatable({}, {
        __index = function(_, k)
            local v = values[k]
            if v == nil then
                error(("enum '%s' has no member '%s'"):format(name, tostring(k)), 2)
            end
            return v
        end,
        __newindex = function(_, k)
            error(("enum '%s' is read-only (cannot set '%s')"):format(name, tostring(k)), 2)
        end,
        __metatable = false,   -- lock the metatable against tampering
        __tostring = function() return "Enum(" .. name .. ")" end,
    })
    meta[frozen] = { name = name, values = values, names = names, byValue = byValue }
    return frozen
end

local function info(e)
    local m = meta[e]
    assert(m, "ns.Enum.*: argument is not an enum (made by ns.Enum.new)")
    return m
end

-- Ordered list of member keys (a fresh copy; mutating it can't unfreeze the enum).
function Enum.names(e)
    local out = {}
    for i, k in ipairs(info(e).names) do out[i] = k end
    return out
end

-- Is `value` one of the enum's values?
function Enum.has(e, value) return info(e).byValue[value] ~= nil end

-- The member KEY for a value (reverse lookup), or nil.
function Enum.nameOf(e, value) return info(e).byValue[value] end

-- Iterate members in key order, calling fn(key, value).
function Enum.each(e, fn)
    local m = info(e)
    for _, k in ipairs(m.names) do fn(k, m.values[k]) end
end

ns.Enum = Enum
