local addonName, ns = ...
local Class = ns.Class

-- Core/DependencyGraph.lua
-- A generic dependency forest. Each node wraps a "subject" -- any object that exposes a
-- boolean predicate (default :IsActive()) -- plus a CONDITION describing which other nodes
-- it depends on. Conditions compose freely: All / Any / AtLeast, nested arbitrarily, each
-- operand a node id or another condition. Nodes need not form a single tree: a graph is a
-- FOREST (disconnected nodes are fine) and is queried as a whole.
--
-- Three states per node:
--   IsActive(id)     -- the subject's own predicate (intrinsic on/off)
--   IsSatisfied(id)  -- the node's condition is met by its parents (roots: always true)
--   IsOnline(id)     -- IsActive AND IsSatisfied, recursively (each parent must be Online)
--
-- Validate() reports circular dependencies and dangling references up front; the
-- evaluators also guard against cycles defensively (a cycle resolves to false rather than
-- recursing forever), so a mis-wired graph degrades instead of crashing.
--
-- Subjects may be any object implementing the configured method, OR a plain function
-- returning a boolean -- so callers can point a node at a real class (subject:IsActive())
-- or at a closure (e.g. a live setting read). Build conditions imperatively with the
-- :All/:Any/:AtLeast/:Ref builders, or declaratively from a spec table via :Parse.
--
--   local g = ns.DependencyGraph:New()                 -- default method "IsActive"
--   g:Add("autoAccept", autoAcceptToggle)
--   g:Add("acceptGrey", acceptGreyToggle, "autoAccept")             -- single parent
--   g:Add("colours",    swatch, g:Any("player", "target"))         -- OR
--   g:Add("combo",      x, g:AtLeast(2, "a", "b", "c"))            -- count
--   g:Add("complex",    y, g:All("a", g:Any("b", "c")))           -- nested AND/OR
--   g:IsOnline("acceptGrey")   g:Validate()   print(g:Report())

local DependencyGraph = Class.new("DependencyGraph")

local DEFAULT_METHOD = "IsActive"

function DependencyGraph:Initialize(opts)
    local p = self:_p()
    p.method = (opts and opts.method) or DEFAULT_METHOD
    p.nodes = {}    -- id -> { id, subject, condition }
    p.order = {}    -- insertion order (stable iteration / reporting)
end

-- ---- condition builders (pure; ignore self, but read nicely as g:All(...)) ------------
-- Operands may be node-id strings or nested condition tables; normalise to conditions.
local function norm(op)
    if type(op) == "string" then return { kind = "ref", id = op } end
    return op
end
local function normList(list)
    local ops = {}
    for _, op in ipairs(list) do ops[#ops + 1] = norm(op) end
    return ops
end

function DependencyGraph:Ref(id)        return { kind = "ref", id = id } end
function DependencyGraph:All(...)        return { kind = "all",  ops = normList({ ... }) } end
function DependencyGraph:Any(...)        return { kind = "any",  ops = normList({ ... }) } end
function DependencyGraph:AtLeast(n, ...) return { kind = "atleast", n = n, ops = normList({ ... }) } end

-- Declarative spec -> condition. Accepts:
--   "key"                         -> depends on that node
--   { "a", "b" }                  -> ANY (a bare list reads as OR, backward-compatible)
--   { all = { ... } }             -> ALL
--   { any = { ... } }             -> ANY
--   { atLeast = N, of = { ... } } -> at least N of the listed
-- Lists may themselves contain specs, so AND/OR/count nest arbitrarily.
function DependencyGraph:Parse(spec)
    if spec == nil then return nil end
    if type(spec) == "string" then return self:Ref(spec) end
    if type(spec) == "table" then
        if spec.all then     return { kind = "all", ops = self:_ParseList(spec.all) } end
        if spec.any then     return { kind = "any", ops = self:_ParseList(spec.any) } end
        if spec.atLeast then return { kind = "atleast", n = spec.atLeast, ops = self:_ParseList(spec.of or {}) } end
        return { kind = "any", ops = self:_ParseList(spec) }  -- bare list = OR
    end
    return nil
end
function DependencyGraph:_ParseList(list)
    local ops = {}
    for _, item in ipairs(list) do ops[#ops + 1] = self:Parse(item) end
    return ops
end

-- ---- building -------------------------------------------------------------------------
-- Add a node. `subject` implements the graph's method (or is a function); `condition` is a
-- condition table, an id string (single parent), a declarative spec, or nil (a root).
function DependencyGraph:Add(id, subject, condition)
    local p = self:_p()
    assert(type(id) == "string" and id ~= "", "DependencyGraph: node id must be a non-empty string")
    assert(not p.nodes[id], "DependencyGraph: duplicate node id '" .. id .. "'")
    if condition ~= nil and (type(condition) == "string" or condition.kind == nil) then
        condition = self:Parse(condition)  -- accept "key" / declarative specs as well as built conditions
    end
    p.nodes[id] = { id = id, subject = subject, condition = condition }
    p.order[#p.order + 1] = id
    return self
end

function DependencyGraph:Has(id) return self:_p().nodes[id] ~= nil end

-- ---- evaluation -----------------------------------------------------------------------
function DependencyGraph:_Active(node)
    local subject = node.subject
    if type(subject) == "function" then return subject() and true or false end
    local method = self:_p().method
    if type(subject) == "table" and type(subject[method]) == "function" then
        return subject[method](subject) and true or false
    end
    return false
end

-- A condition is true when its operands resolve true. Refs resolve to the referenced
-- node's ONLINE state (active + own deps met). `visiting` guards against cycles.
function DependencyGraph:_Eval(cond, visiting)
    if not cond then return true end  -- no condition = root, always satisfied
    local k = cond.kind
    if k == "ref" then
        return self:_Online(cond.id, visiting)
    elseif k == "all" then
        for _, op in ipairs(cond.ops) do if not self:_Eval(op, visiting) then return false end end
        return true
    elseif k == "any" then
        for _, op in ipairs(cond.ops) do if self:_Eval(op, visiting) then return true end end
        return false
    elseif k == "atleast" then
        local c = 0
        for _, op in ipairs(cond.ops) do if self:_Eval(op, visiting) then c = c + 1 end end
        return c >= (cond.n or 1)
    end
    return false
end

function DependencyGraph:_Online(id, visiting)
    local node = self:_p().nodes[id]
    if not node then return false end       -- dangling reference -> never online
    if visiting[id] then return false end   -- cycle -> defensively false (Validate reports it)
    visiting[id] = true
    local online = self:_Active(node) and self:_Eval(node.condition, visiting)
    visiting[id] = nil
    return online
end

-- The subject's own predicate, ignoring dependencies.
function DependencyGraph:IsActive(id)
    local node = self:_p().nodes[id]
    return node ~= nil and self:_Active(node) or false
end

-- Whether the node's dependency condition is met (parents online). Roots are always
-- satisfied. This is what the UI greys on -- a control is interactive when satisfied.
function DependencyGraph:IsSatisfied(id)
    local node = self:_p().nodes[id]
    if not node then return false end
    return self:_Eval(node.condition, { [id] = true })  -- seed self so a self-cycle resolves false
end

-- Active AND satisfied, all the way up the tree.
function DependencyGraph:IsOnline(id)
    return self:_Online(id, {})
end

-- Ids of every node currently online (a "what's up" snapshot).
function DependencyGraph:OnlineNodes()
    local out = {}
    for _, id in ipairs(self:_p().order) do
        if self:IsOnline(id) then out[#out + 1] = id end
    end
    return out
end

-- ---- validation -----------------------------------------------------------------------
local function refsOf(cond, out)
    if not cond then return out end
    if cond.kind == "ref" then
        out[#out + 1] = cond.id
    else
        for _, op in ipairs(cond.ops or {}) do refsOf(op, out) end
    end
    return out
end

-- Returns ok, issues[] : flags dangling references and circular dependencies (with the
-- offending path). Cheap; call once after building a graph.
function DependencyGraph:Validate()
    local p = self:_p()
    local issues = {}

    for _, id in ipairs(p.order) do
        for _, ref in ipairs(refsOf(p.nodes[id].condition, {})) do
            if not p.nodes[ref] then
                issues[#issues + 1] = ("node '%s' depends on missing node '%s'"):format(id, ref)
            end
        end
    end

    -- DFS 3-colouring: a GREY node reached again is a back-edge (cycle).
    local WHITE, GREY, BLACK = 0, 1, 2
    local colour, stack = {}, {}
    for _, id in ipairs(p.order) do colour[id] = WHITE end
    local function dfs(id)
        colour[id] = GREY
        stack[#stack + 1] = id
        for _, ref in ipairs(refsOf(p.nodes[id].condition, {})) do
            if p.nodes[ref] then
                if colour[ref] == GREY then
                    local from = 1
                    for i, n in ipairs(stack) do if n == ref then from = i; break end end
                    local cyc = {}
                    for i = from, #stack do cyc[#cyc + 1] = stack[i] end
                    cyc[#cyc + 1] = ref
                    issues[#issues + 1] = "circular dependency: " .. table.concat(cyc, " -> ")
                elseif colour[ref] == WHITE then
                    dfs(ref)
                end
            end
        end
        stack[#stack] = nil
        colour[id] = BLACK
    end
    for _, id in ipairs(p.order) do
        if colour[id] == WHITE then dfs(id) end
    end

    return #issues == 0, issues
end

-- ---- ordering -------------------------------------------------------------------------
-- A load order: every node appears AFTER all nodes it references (its dependencies), so
-- initialising in this order guarantees each node's dependencies are already up. Cycles
-- are broken (the offending back-edge is skipped -- call Validate() to surface them).
-- DFS post-order over each node's refs; stable in insertion order.
function DependencyGraph:TopologicalOrder()
    local p = self:_p()
    local order, state = {}, {}   -- state: nil | "visiting" | "done"
    local function visit(id)
        if not p.nodes[id] or state[id] == "done" or state[id] == "visiting" then return end
        state[id] = "visiting"
        for _, ref in ipairs(refsOf(p.nodes[id].condition, {})) do
            visit(ref)
        end
        state[id] = "done"
        order[#order + 1] = id
    end
    for _, id in ipairs(p.order) do visit(id) end
    return order
end

-- ---- explanation ----------------------------------------------------------------------
function DependencyGraph:_DescribeCond(cond)
    if not cond then return "(no dependencies)" end
    if cond.kind == "ref" then
        return ("%s[%s]"):format(cond.id, self:IsOnline(cond.id) and "on" or "off")
    end
    local parts = {}
    for _, op in ipairs(cond.ops) do parts[#parts + 1] = self:_DescribeCond(op) end
    if cond.kind == "all"     then return "ALL(" .. table.concat(parts, ", ") .. ")" end
    if cond.kind == "any"     then return "ANY(" .. table.concat(parts, ", ") .. ")" end
    if cond.kind == "atleast" then return ("ATLEAST %d of (%s)"):format(cond.n or 1, table.concat(parts, ", ")) end
    return "?"
end

-- One node, human-readable: status + (if blocked) the unmet condition with each ref's state.
function DependencyGraph:Explain(id)
    local node = self:_p().nodes[id]
    if not node then return ("'%s': no such node"):format(id) end
    local active    = self:_Active(node)
    local satisfied = self:IsSatisfied(id)
    local line = ("'%s': %s (active=%s, satisfied=%s)"):format(
        id, (active and satisfied) and "ONLINE" or "offline", tostring(active), tostring(satisfied))
    if node.condition then
        line = line .. "\n  depends on: " .. self:_DescribeCond(node.condition)
    end
    return line
end

-- Every node's status, one per line (for a debug dump).
function DependencyGraph:Report()
    local lines = {}
    for _, id in ipairs(self:_p().order) do
        lines[#lines + 1] = self:Explain(id)
    end
    return table.concat(lines, "\n")
end

ns.DependencyGraph = DependencyGraph
