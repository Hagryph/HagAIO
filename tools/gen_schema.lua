-- tools/gen_schema.lua
-- Auto-generates DATABASE_SCHEMA.md from the ONE shared database: every table contributed anywhere
-- in the code (the central ns.DB.CoreTables plus each module/service's `tables` opt), with its
-- columns, types, keys, constraints, indices and scope. Run on deploy:
--     luajit tools/gen_schema.lua        (from the repo root)
-- It loads the real engine and every Service/Module headless in a permissive sandbox, then builds
-- the actual schema and renders it -- so the doc is always derived from the code, never by hand.

local WIN = package.config:sub(1, 1) == "\\"

-- Parse tools/load-order.json -- the shared load-order manifest (one source of truth with
-- tools/autogen/Common.ps1, tools/depcheck.mjs and Test/support.lua). The file is strictly
-- arrays/objects of plain strings with no colons/brackets inside the strings, so a
-- syntactic translation to a Lua literal is safe -- no JSON library needed headless.
local function loadOrderManifest()
    local f = assert(io.open("tools/load-order.json", "rb"), "tools/load-order.json not found (run from the repo root)")
    local s = f:read("*a"); f:close()
    s = s:gsub("%[", "{"):gsub("%]", "}"):gsub('("[^"\n]-")%s*:', "[%1]=")
    return assert((loadstring or load)("return " .. s))()
end

local function loadInto(path, ns)
    local chunk, err = loadfile(path)
    if not chunk then return false, err end
    return pcall(chunk, "HagAIO", ns)
end

-- repo-relative display path for a Services/Modules/Lib/Core file (dir /b /s gives absolute paths)
local function rel(p)
    p = p:gsub("\\", "/")
    return p:match("/(Services/.+)$") or p:match("/(Modules/.+)$") or p:match("/(Lib/.+)$") or p:match("/(Core/.+)$") or p
end

local function listLua(dir)
    local cmd = WIN and ('dir /b /s "' .. dir .. '\\*.lua" 2>nul') or ('find "' .. dir .. '" -name "*.lua" 2>/dev/null')
    local out, p = {}, io.popen(cmd)
    if p then for line in p:lines() do out[#out + 1] = line end p:close() end
    -- Match the in-game .toc load order (tools/autogen/Common.ps1): sort by folder, and within a folder
    -- the ENTRY file (Foo/Foo.lua) loads FIRST -- so a split feature like Class/Monk loads Monk.lua (which
    -- defines ns.Monk.RegisterSpec) before its Base/Brewmaster siblings call it. Plain alpha order would
    -- load Base/Brewmaster first, when RegisterSpec is still an inert sandbox stub -> specs never register.
    local function norm(s) return (s:gsub("\\", "/")) end
    local function parent(s) return (norm(s):gsub("/[^/]*$", "")) end
    local function leaf(s) return norm(s):match("[^/]+$") end
    local function isEntry(s) local d = parent(s); return leaf(s) == ((d:match("[^/]+$") or "") .. ".lua") end
    table.sort(out, function(a, b)
        local pa, pb = parent(a), parent(b)
        if pa ~= pb then return pa < pb end
        local ea, eb = isEntry(a), isEntry(b)
        if ea ~= eb then return ea end          -- entry file first within its folder
        return leaf(a) < leaf(b)
    end)
    return out
end

-- ===========================================================================
-- 1) the framework (loaded for real) + the minimal stubs its constructors touch
-- ===========================================================================
local ns = { UI = {} }
ns.Theme = { hex = setmetatable({}, { __index = function() return "ffffff" end }) }
ns.Log = { Print = function() end, Warn = function() end, Error = function() end }
local noop = function() end
ns.Logger = { Core = function() return { Debug = noop, Info = noop, Success = noop, Warn = noop, Error = noop } end,
              Register = function() return {} end }

local currentSource = "framework"
-- Contributions are DEFERRED to a single sweep after every file has loaded (mirrors Init.lua's
-- ADDON_LOADED sweep), so a contributor that depends on later-loaded files -- e.g. the Class module
-- deriving a settings table per spec registered by Modules/Class/<Class>/* -- sees them. Each item
-- records the source file it registered under, for table attribution.
local deferred = {}
local function reg(_, item)
    if item then
        if item._Publish then pcall(function() item:_Publish() end) end
        if item._ContributeTables then deferred[#deferred + 1] = { item = item, source = currentSource } end
    end
    return item
end
-- ModuleManager keeps a real name map so GetModule resolves a registered module. Module entry files
-- assert on it (e.g. a class submodule requires its parent Class module) and would otherwise error +
-- be skipped headless, hiding their tables. Services/Submodules just publish + contribute.
local registeredModules = {}
ns.ServiceManager   = { Register = reg, IsLoaded = function() return true end }
ns.ModuleManager    = {
    Register  = function(self, item) if item then registeredModules[item:GetName()] = item end; return reg(self, item) end,
    GetModule = function(_, name) return registeredModules[name] end,
}
ns.SubmoduleManager = { Register = reg }
ns.LibManager       = {
    Register      = function(_, item) if item and item._Publish then pcall(function() item:_Publish() end) end; return item end,
    RegisterValue = function(_, name, value) ns[name] = value; return value end,
}
-- Dev-gated registrations (Services/Dev, Modules/Dev) defer through this in-game; headless we
-- resolve immediately AS a dev character so their contributed tables stay in the documented schema.
ns.WhenDevCharKnown = function(fn) fn(true) end

-- The framework files, in manifest order (tools/load-order.json), minus what this rig
-- stubs above or doesn't need headless -- so a new Core base class added to the manifest
-- is loaded here automatically. Lib/Helpers.lua rides along: pure helpers (DeepCopy)
-- used across the framework, loaded before any feature file.
local SKIP_FRAMEWORK = {
    ["Core/Namespace.lua"] = true,        -- WoW-API bound (dev identity); nothing here needs it
    ["Core/DB/Types.lua"] = true,         -- loaded with the rest of the DB engine (DBFILES below)
    ["Lib/Color.lua"] = true,             -- loaded with the rest of Lib/ in the sandbox scan
    ["UI/Theme.lua"] = true,              -- stubbed above
    ["Core/DependencyGraph.lua"] = true,  -- manager machinery; managers are stubbed
    ["Core/Logger.lua"] = true,           -- stubbed above
    ["Core/Registry.lua"] = true,         -- manager base; managers are stubbed
    ["Core/ServiceManager.lua"] = true,   -- stubbed above
    ["Core/ModuleManager.lua"] = true,    -- stubbed above
    ["Core/SubmoduleManager.lua"] = true, -- stubbed above
    ["Core/LibManager.lua"] = true,       -- stubbed above
    ["UI/Widgets/Widgets.lua"] = true,    -- UI; the sandbox stub covers widget access
}
local FRAMEWORK = {}
for _, f in ipairs(loadOrderManifest().pinnedHead) do
    if not SKIP_FRAMEWORK[f] then FRAMEWORK[#FRAMEWORK + 1] = f end
end
FRAMEWORK[#FRAMEWORK + 1] = "Lib/Helpers.lua"
for _, f in ipairs(FRAMEWORK) do
    local ok, err = loadInto(f, ns)
    if not ok then io.stderr:write("gen_schema: framework load failed " .. f .. ": " .. tostring(err) .. "\n"); os.exit(1) end
end

-- ===========================================================================
-- 2) the DB engine + central tables
-- ===========================================================================
local DBFILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                  "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                  "QueryBuilder", "QueryExecutor", "CoreTables", "DatabaseManager" }
for _, f in ipairs(DBFILES) do
    local ok, err = loadInto("Core/DB/" .. f .. ".lua", ns)
    if not ok then io.stderr:write("gen_schema: DB load failed " .. f .. ": " .. tostring(err) .. "\n"); os.exit(1) end
end

local mgr = ns.DatabaseManager
-- attribute each table to the file that contributed it (wrap the single add choke point)
local source = {}
local origAdd = mgr._Add
mgr._Add = function(self, name, spec) source[name] = currentSource; return origAdd(self, name, spec) end

currentSource = "Core/DB/CoreTables.lua"
mgr:OnInitialize()   -- seeds the central CoreTables

-- ===========================================================================
-- 3) permissive sandbox so feature files load headless, then scan Lib + Services + Modules
-- ===========================================================================
local stub
stub = setmetatable({}, { __index = function() return stub end, __call = function() return stub end,
                          __concat = function() return "" end })
setmetatable(ns, { __index = function() return stub end })
setmetatable(_G, { __index = function() return stub end })

-- The Class module derives a settings-table pair per registered spec, but a spec registers only for
-- the player's class (Monk's gate is UnitClass=="MONK"). Headless there is no character, so pin a
-- representative class so those per-spec tables are introspected + documented. Extend this as more
-- classes gain spec modules (only the player's class registers specs at runtime, so this can show one
-- class's spec tables at a time).
_G.UnitClass = function() return "Monk", "MONK" end

for _, path in ipairs(listLua("Lib")) do currentSource = rel(path); loadInto(path, ns) end

local scanned, skipped = {}, {}
for _, dir in ipairs({ "Services", "Modules" }) do
    for _, path in ipairs(listLua(dir)) do
        currentSource = rel(path)
        local ok, err = loadInto(path, ns)
        if ok then scanned[#scanned + 1] = currentSource else skipped[#skipped + 1] = { currentSource, err } end
    end
end

-- Now that every file has loaded, contribute each owner's tables (under its own source), so
-- contributors that depend on later-loaded files (the Class module's per-spec settings tables) are seen.
for _, d in ipairs(deferred) do
    currentSource = d.source
    pcall(function() d.item:_ContributeTables() end)
end

-- ===========================================================================
-- 4) build the real shared database and introspect its schema
-- ===========================================================================
ns.SavedVars = { IsLoaded = function() return true end, DataSlot = function() return {} end }
local ok, err = pcall(function() mgr:Build() end)
if not ok then io.stderr:write("gen_schema: build failed: " .. tostring(err) .. "\n"); os.exit(1) end
local schema = mgr:Shared():Schema()

-- ===========================================================================
-- 5) render markdown
-- ===========================================================================
local b = {}
local function w(s) b[#b + 1] = s end

w("# HagAIO Database Schema\n\n")
w("_Auto-generated by `tools/gen_schema.lua` on deploy — do not edit by hand._\n\n")
w("The addon uses **one shared database**. Every service or module contributes the tables it needs; ")
w("common reference tables are defined centrally in `Core/DB/CoreTables.lua`. Each table declares a **scope**:\n\n")
w("- **local** — in-memory, rebuilt from code each session (reference data; never persisted)\n")
w("- **global** — account-wide saved variables (shared across characters)\n")
w("- **char** — this character's saved variables\n")

-- Build the Mermaid ER diagram once: every table as an entity (+PK/FK), one edge per foreign key.
-- Reused for the inline GitHub block below AND the standalone interactive diagram/DB/index.html.
local mer = { "erDiagram\n" }
local function mw(s) mer[#mer + 1] = s end
for _, tname in ipairs(schema:TableNames()) do
    for _, fk in ipairs(schema:Table(tname):ForeignKeys()) do
        mw(("    %s ||--o{ %s : \"%s\"\n"):format(fk.table, tname, fk.column))   -- parent has-many child
    end
end
for _, tname in ipairs(schema:TableNames()) do
    local t = schema:Table(tname)
    local pkset, fkset = {}, {}
    for _, c in ipairs(t:PrimaryKey()) do pkset[c] = true end
    for _, fk in ipairs(t:ForeignKeys()) do fkset[fk.column] = true end
    mw(("    %s {\n"):format(tname))
    for _, col in ipairs(t:Columns()) do
        local n = col:Name()
        local key = pkset[n] and "PK" or (fkset[n] and "FK" or "")
        mw(("        %s %s%s\n"):format(col:Type(), n, key ~= "" and (" " .. key) or ""))
    end
    mw("    }\n")
end
local mermaid = table.concat(mer)

w("\n## Entity-relationship diagram\n\n")
w("Open **[diagram/DB/index.html](diagram/DB/index.html)** in a browser for an interactive (zoom/pan) view.\n")

w("\n## Tables\n\n")
w("| Table | Scope | Columns | Primary key | Defined in |\n|---|---|---|---|---|\n")
for _, tname in ipairs(schema:TableNames()) do
    local t = schema:Table(tname)
    local pk = table.concat(t:PrimaryKey(), ", ")
    w(("| [`%s`](#%s) | `%s` | %d | %s | `%s` |\n")
        :format(tname, tname, t:Scope(), #t:ColumnNames(), pk ~= "" and pk or "—", source[tname] or "—"))
end

for _, tname in ipairs(schema:TableNames()) do
    local t = schema:Table(tname)
    local fkByCol = {}
    for _, fk in ipairs(t:ForeignKeys()) do fkByCol[fk.column] = fk end
    local pkset = {}; for _, c in ipairs(t:PrimaryKey()) do pkset[c] = true end
    local uniqSingle, uniqComposite = {}, {}
    for _, u in ipairs(t:Uniques()) do
        if #u == 1 then uniqSingle[u[1]] = true else uniqComposite[#uniqComposite + 1] = u end
    end

    w(("\n---\n\n### `%s`  ·  scope `%s`\n\n"):format(tname, t:Scope()))
    if source[tname] then w(("*Defined in `%s`.*\n\n"):format(source[tname])) end
    w("| Column | Type | Null | Key | Default | References |\n|---|---|---|---|---|---|\n")
    for _, col in ipairs(t:Columns()) do
        local name = col:Name()
        local keys = {}
        if pkset[name]       then keys[#keys + 1] = col:IsAuto() and "PK auto" or "PK" end
        if uniqSingle[name]  then keys[#keys + 1] = "unique" end
        local refs, fk = "", fkByCol[name]
        if fk then
            local od = (fk.onDelete and fk.onDelete ~= "no_action") and (" on delete " .. fk.onDelete) or ""
            refs = ("→ `%s.%s`%s"):format(fk.table, fk.refColumn, od)
        end
        local def = col:HasDefault() and ("`" .. tostring(col:Default()) .. "`") or ""
        w(("| `%s` | %s | %s | %s | %s | %s |\n")
            :format(name, col:Type(), col:IsNullable() and "yes" or "no", table.concat(keys, ", "), def, refs))
    end
    if #t:PrimaryKey() > 1 then w(("\n**Primary key:** (%s)\n"):format(table.concat(t:PrimaryKey(), ", "))) end
    for _, u in ipairs(uniqComposite) do w(("\n**Unique:** (%s)\n"):format(table.concat(u, ", "))) end
    if #t:Indices() > 0 then
        local parts = {}
        for _, ix in ipairs(t:Indices()) do parts[#parts + 1] = "(" .. table.concat(ix.columns, ", ") .. ")" end
        w(("\n**Indexes:** %s\n"):format(table.concat(parts, ", ")))
    end
end

if #skipped > 0 then
    w("\n---\n\n_These files could not be introspected headless and were skipped (their tables, if any, are not shown):_\n\n")
    table.sort(skipped, function(a, b) return a[1] < b[1] end)
    for _, s in ipairs(skipped) do w(("- `%s`\n"):format(s[1])) end
end

local out = assert(io.open("DATABASE_SCHEMA.md", "w"))
out:write(table.concat(b))
out:close()

-- ===========================================================================
-- 6) standalone interactive diagram: diagram/DB/index.html (self-contained, renders the same
--    Mermaid ER diagram via the Mermaid CDN, with dark theme + zoom/pan). Open it in a browser.
-- ===========================================================================
os.execute(WIN and 'if not exist "diagram\\DB" mkdir "diagram\\DB"' or 'mkdir -p diagram/DB')
local HTML = [[<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>HagAIO — Database ER diagram</title>
<style>
  :root { --bg:#0e1726; --panel:#0b1220; --ink:#cdd6e4; --muted:#7e8aa0; --accent:#3b82f6; }
  html,body { margin:0; height:100%; background:var(--bg); color:var(--ink);
              font-family:system-ui,'Segoe UI',Roboto,sans-serif; }
  header { position:fixed; inset:0 0 auto 0; height:48px; box-sizing:border-box; display:flex;
           gap:12px; align-items:center; padding:0 16px; background:var(--panel);
           border-bottom:1px solid #1e2a3f; z-index:5; }
  header h1 { font-size:15px; margin:0; font-weight:600; }
  header .sub { color:var(--muted); font-size:12px; }
  .toolbar { margin-left:auto; display:flex; gap:6px; }
  button { background:#16233a; color:var(--ink); border:1px solid #26344e; border-radius:6px;
           padding:6px 11px; cursor:pointer; font-size:13px; }
  button:hover { border-color:var(--accent); }
  #viewport { position:fixed; inset:48px 0 0 0; overflow:auto; }
  #stage { transform-origin:0 0; padding:24px; width:max-content; }
  .mermaid { background:transparent; }
</style>
</head>
<body>
<header>
  <h1>HagAIO Database</h1>
  <span class="sub">entity-relationship diagram &middot; auto-generated by tools/gen_schema.lua</span>
  <div class="toolbar">
    <button onclick="zoom(1.2)" title="Zoom in">+</button>
    <button onclick="zoom(1/1.2)" title="Zoom out">&minus;</button>
    <button onclick="reset()" title="Reset">Reset</button>
  </div>
</header>
<div id="viewport"><div id="stage"><pre class="mermaid">__MERMAID__</pre></div></div>
<script type="module">
  import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
  mermaid.initialize({ startOnLoad:true, theme:'dark', er:{ useMaxWidth:false } });
</script>
<script>
  let scale = 1;
  const stage = document.getElementById('stage');
  function apply(){ stage.style.transform = 'scale(' + scale + ')'; }
  function zoom(f){ scale = Math.min(4, Math.max(0.2, scale * f)); apply(); }
  function reset(){ scale = 1; apply(); }
  document.getElementById('viewport').addEventListener('wheel', function(e){
    if (e.ctrlKey || e.metaKey) { e.preventDefault(); zoom(e.deltaY < 0 ? 1.1 : 1/1.1); }
  }, { passive:false });
</script>
</body>
</html>
]]
local hf = assert(io.open("diagram/DB/index.html", "w"))
hf:write((HTML:gsub("__MERMAID__", function() return mermaid end)))   -- function form: no %-escaping of the body
hf:close()

print(("gen_schema: wrote DATABASE_SCHEMA.md + diagram/DB/index.html (%d tables; %d files scanned%s)")
    :format(#schema:TableNames(), #scanned, #skipped > 0 and (", " .. #skipped .. " skipped") or ""))
