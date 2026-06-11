local addonName, ns = ...
local Class = ns.Class

-- Core/DB/ColumnResolver.lua
-- Resolves column references against the set of row-sources active in a query (the FROM table plus
-- every JOIN, each under an alias). A reference is either qualified ("alias.col") or bare ("col"):
--   * qualified -> that exact source; errors if the alias isn't active or lacks the column.
--   * bare      -> the single source that has the column; errors if more than one does (ambiguous)
--                  -- which is why a self-join's two sides MUST be aliased and referenced qualified.
-- A composite row is a map alias -> stored-row (or nil for the unmatched side of an outer join);
-- reading a column from a nil/absent source yields DB.NULL.

ns.DB = ns.DB or {}
local DB = ns.DB

local ColumnResolver = Class.new("DBColumnResolver")

-- sources = ordered list of { alias = <string>, table = <DBTable> }
function ColumnResolver:Initialize(sources)
    local p = self:_p()
    p.byAlias = {}            -- alias -> DBTable
    p.aliasOrder = {}
    p.colToAliases = {}       -- bare col -> { alias, ... }
    p.memo = {}               -- ref -> { alias, col }: Resolve runs per row per predicate leaf, and a
                              -- resolver lives for ONE query, so successes can never go stale
    for _, s in ipairs(sources) do
        if p.byAlias[s.alias] then error(("DB: duplicate source alias '%s'"):format(s.alias), 0) end
        p.byAlias[s.alias] = s.table
        p.aliasOrder[#p.aliasOrder + 1] = s.alias
        for _, c in ipairs(s.table:ColumnNames()) do
            local list = p.colToAliases[c]
            if not list then list = {}; p.colToAliases[c] = list end
            list[#list + 1] = s.alias
        end
    end
end

-- Split "alias.col" / "col"; returns alias (or nil) and column.
local function split(ref)
    local a, c = ref:match("^([%w_]+)%.([%w_]+)$")
    if a then return a, c end
    return nil, ref
end

-- Resolve a reference to (alias, column). Raises on unknown/ambiguous. Memoized (see Initialize).
function ColumnResolver:Resolve(ref)
    local p = self:_p()
    local hit = p.memo[ref]
    if hit then return hit[1], hit[2] end
    local alias, col = split(ref)
    if alias then
        local tbl = p.byAlias[alias]
        if not tbl then error(("DB: unknown source '%s' in '%s'"):format(alias, ref), 0) end
        if not tbl:HasColumn(col) then error(("DB: '%s' has no column '%s'"):format(alias, col), 0) end
    else
        local list = p.colToAliases[col]
        if not list then error(("DB: unknown column '%s'"):format(col), 0) end
        if #list > 1 then error(("DB: ambiguous column '%s' (in %s)"):format(col, table.concat(list, ", ")), 0) end
        alias = list[1]
    end
    p.memo[ref] = { alias, col }
    return alias, col
end

-- The value of `ref` in a composite row (DB.NULL if the source is unmatched or the field absent).
function ColumnResolver:Value(compRow, ref)
    local alias, col = self:Resolve(ref)
    local src = compRow[alias]
    if src == nil then return DB.NULL end
    local v = src[col]
    if v == nil then return DB.NULL end
    return v
end

-- Expand a "*" or "alias.*" projection into a list of { ref, out } (out = the bare column name).
function ColumnResolver:ExpandStar(ref)
    local p = self:_p()
    local out = {}
    if ref == "*" then
        for _, alias in ipairs(p.aliasOrder) do
            for _, c in ipairs(p.byAlias[alias]:ColumnNames()) do out[#out + 1] = { ref = alias .. "." .. c, out = c } end
        end
    else
        local alias = ref:match("^([%w_]+)%.%*$")
        if not alias or not p.byAlias[alias] then error(("DB: bad star projection '%s'"):format(ref), 0) end
        for _, c in ipairs(p.byAlias[alias]:ColumnNames()) do out[#out + 1] = { ref = alias .. "." .. c, out = c } end
    end
    return out
end

DB.ColumnResolver = ColumnResolver
