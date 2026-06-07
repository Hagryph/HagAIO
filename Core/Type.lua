local addonName, ns = ...

-- Core/Type.lua
-- VALUE-TYPE factory -- a sibling of ns.Class for immutable value objects (e.g. Vector2D).
-- A Type is a Class with VALUE semantics:
--   * the constructor stores the declared fields (positional), filling nils from optional
--     `defaults`;
--   * a read accessor is generated per field (field "x" -> instance:X());
--   * instances compare by VALUE -- structural __eq over the fields -- and print readably;
--   * instances are immutable by construction: fields live in the private :_p() table and
--     no setters are generated, so nothing outside the type can change them.
-- Add behaviour with `function T:Method(...)` exactly like a class.
--   local Vector2D = ns.Type.new("Vector2D", { "x", "y" }, { x = 0, y = 0 })
--   function Vector2D:Dist2(o) ... end

local Type = {}

local function capitalise(s) return s:sub(1, 1):upper() .. s:sub(2) end

function Type.new(name, fields, defaults)
    assert(type(name) == "string", "Type.new: name must be a string")
    assert(type(fields) == "table" and #fields > 0, "Type.new: fields must be a non-empty list")
    local T = ns.Class.new(name)   -- reuse the class machinery (Object, :_p(), ancestry, :New)

    -- Constructor: positional args -> private fields, falling back to defaults for nils.
    function T:Initialize(...)
        local p = self:_p()
        for i = 1, #fields do
            local v = select(i, ...)
            if v == nil and defaults then v = defaults[fields[i]] end
            p[fields[i]] = v
        end
    end

    -- A read accessor per field: field "x" -> T:X().
    for _, f in ipairs(fields) do
        T[capitalise(f)] = function(self) return self:_p()[f] end
    end

    -- Value equality over the declared fields (only between two instances of THIS type).
    T.__eq = function(a, b)
        if getmetatable(a) ~= getmetatable(b) then return false end
        local pa, pb = a:_p(), b:_p()
        for i = 1, #fields do
            if pa[fields[i]] ~= pb[fields[i]] then return false end
        end
        return true
    end

    -- Readable representation: "Vector2D(3, 4)".
    T.__tostring = function(self)
        local p, vals = self:_p(), {}
        for i = 1, #fields do vals[i] = tostring(p[fields[i]]) end
        return name .. "(" .. table.concat(vals, ", ") .. ")"
    end

    return T
end

ns.Type = Type
