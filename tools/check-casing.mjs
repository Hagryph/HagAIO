#!/usr/bin/env node
// tools/check-casing.mjs — naming-casing gate for the OOP framework's three conventions:
//   node tools/check-casing.mjs            # report violations, exit 1 if any
//
//   (A) private INSTANCE methods are _PascalCase. Flag a `function X:_lowercase(` definition (or a
//       mixin/table method field `_lowercase = function(self, ...)`). The framework primitives
//       :_p() and :_statics() are grandfathered.
//   (B) STATIC (dot-call) methods split by role: camelCase for OOP MACHINERY (ns.Class.new,
//       ns.Enum.names, the DB-engine internals, ...), PascalCase for DOMAIN API (Contributions.Wire,
//       Format.Clock, ns.Monk.RegisterSpec, ...). Flag a camelCase static DEFINITION whose owner
//       table is not in the machinery allowlist -- the distinction is semantic, so the allowlist is
//       the source of truth.
//   (C) an underscore-prefixed PRIVATE FIELD (p._x reached through :_p()) is BASE/MIXIN-owned only:
//       a base + its subclass share one :_p() table per instance, so the prefix is what stops a leaf
//       from clobbering inherited state. Flag p._field in any file that is not a base/mixin owner --
//       a leaf must name its own private fields plain camelCase.
//
// Scope: every .lua under Core / Lib / Services / UI / Modules. A deliberate exception is silenced
// with `-- hag-lint-disable casing` (file) or `-- hag-lint-disable-next-line casing` (the line above),
// via the shared parser in tools/lib/annotations.mjs.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { parseAnnotations } from "./lib/annotations.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SCAN = ["Core", "Lib", "Services", "UI", "Modules"];
const RULE = "casing";

// (A) framework primitives that are intentionally lower-case after the underscore.
const METHOD_EXEMPT = new Set(["_p", "_statics"]);
// (B) owner tables whose STATIC methods legitimately stay camelCase -- the OOP-primitive factories.
// The whole DB engine (Core/DB/*) is machinery too -- its internal .new/helpers are exempted by path
// below, so individual DB class names (Schema, QueryPlan, Aggregate, WhereClause, ...) need not be listed.
const MACHINERY = new Set(["Class", "Type", "Enum", "Mixin", "Interface", "Delegate"]);
// (C) the base classes + mixins that OWN underscore-prefixed private fields (subclasses inherit them).
const FIELD_ALLOW = new Set([
  "Core/Component.lua", "Core/DatabaseOwner.lua", "Core/Submodule.lua",
  "UI/Widgets/Widgets.lua", "UI/Widgets/Grid.lua",
]);

// Blank Lua comments + string literals (keep newlines) so a name inside a comment/string isn't flagged.
function strip(src) {
  src = src.replace(/--\[\[[\s\S]*?\]\]/g, (m) => m.replace(/[^\n]/g, " "));
  src = src.replace(/\[\[[\s\S]*?\]\]/g, (m) => m.replace(/[^\n]/g, " "));
  src = src
    .split("\n")
    .map((ln) => { const i = ln.indexOf("--"); return i === -1 ? ln : ln.slice(0, i) + " ".repeat(ln.length - i); })
    .join("\n");
  return src.replace(/"(?:\\.|[^"\n])*"|'(?:\\.|[^'\n])*'/g, (m) => '"' + " ".repeat(Math.max(0, m.length - 2)) + '"');
}

function* luaFiles(dir) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) yield* luaFiles(full);
    else if (name.endsWith(".lua")) yield full;
  }
}

const violations = [];
for (const sub of SCAN) {
  const base = join(ROOT, sub);
  try { statSync(base); } catch { continue; }
  for (const full of luaFiles(base)) {
    const rel = relative(ROOT, full).replace(/\\/g, "/");
    const raw = readFileSync(full, "utf8");
    const ann = parseAnnotations(raw);
    const src = strip(raw);
    const lineAt = (idx) => src.slice(0, idx).split("\n").length;
    const flag = (idx, msg) => {
      const line = lineAt(idx);
      if (!(ann.lineDisabled(RULE, line) || ann.fileDisabled(RULE))) violations.push({ rel, line, msg });
    };

    // (A) private instance methods -> _PascalCase
    for (const m of src.matchAll(/function\s+[\w.]+:\s*(_[a-z]\w*)\s*\(/g)) {
      if (!METHOD_EXEMPT.has(m[1])) flag(m.index, `private method ':${m[1]}' must be _PascalCase`);
    }
    for (const m of src.matchAll(/(?:^|[,{]\s*)(_[a-z]\w*)\s*=\s*function\s*\(\s*self\b/gm)) {
      if (!METHOD_EXEMPT.has(m[1])) flag(m.index, `private method field '${m[1]}' must be _PascalCase`);
    }

    // (B) domain-API statics -> PascalCase (the OOP-primitive factories + the whole DB engine are machinery)
    if (!rel.startsWith("Core/DB/")) {
      for (const m of src.matchAll(/function\s+([\w.]+)\.([a-z]\w*)\s*\(/g)) {
        const owner = m[1].split(".").pop();
        if (owner !== "_G" && !MACHINERY.has(owner)) {
          flag(m.index, `static '${m[1]}.${m[2]}' is domain API -- must be PascalCase (not camelCase)`);
        }
      }
    }

    // (C) underscore private fields -> base/mixin-owned files only
    if (!FIELD_ALLOW.has(rel)) {
      for (const m of src.matchAll(/(?:\bp|:_p\(\))\s*\.\s*(_[a-z]\w*)/g)) {
        flag(m.index, `private field 'p.${m[1]}' -- the _ prefix is base/mixin-owned only; a leaf uses plain camelCase`);
      }
    }
  }
}

violations.sort((a, b) => a.rel.localeCompare(b.rel) || a.line - b.line);
let cur = null;
for (const v of violations) {
  if (v.rel !== cur) { cur = v.rel; console.log(`\n${cur}`); }
  console.log(`  ${v.line}: ${v.msg}`);
}

console.log("\n=== casing lint (private-method / static / private-field) ===");
console.log(`  TOTAL: ${violations.length}`);
process.exit(violations.length ? 1 : 0);
